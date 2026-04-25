//
//  Quantizer.swift
//  MP3Coder
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import Accelerate
import Foundation

/// Quantizes spectral values and manages the encoding bit budget.
///
/// The inner quantize step is vectorized via Accelerate using the identity
/// `x^0.75 = sqrt(x * sqrt(x))`, which turns a per-element `pow()` into two
/// `vvsqrtf` calls + one `vDSP_vmul` over 576 values.
final class Quantizer {
    let scaleFactorBandBounds: [Int]
    /// Per bitstream slot, which short window (0..2) owns it. Used by `outerLoopShort`
    /// to compute per-window energy and pre-scale by 2^(2*sg_w).
    private let shortWindowTable: [Int]
    /// Per bitstream slot, which short scale-factor band (0..11) owns it. Used by
    /// the short-block per-(window, band) scale factor optimization.
    private let shortBandTable: [Int]

    // MARK: - Scratch (all sized for 576 spectral lines)

    private var absoluteBuffer: ContiguousArray<Float>
    private var sqrtBuffer: ContiguousArray<Float>
    private var scaledBuffer: ContiguousArray<Float>
    private var quantizedInt32: ContiguousArray<Int32>
    private var quantizedScratch: ContiguousArray<Int>
    private var scaleFactorScratch: ContiguousArray<Float>
    private var originalDoubleScratch: ContiguousArray<Double>
    private var quantizedMagnitudeDoubleScratch: ContiguousArray<Double>
    private var cbrtDoubleScratch: ContiguousArray<Double>
    private var decodedDoubleScratch: ContiguousArray<Double>
    private var diffDoubleScratch: ContiguousArray<Double>
    private var distortionScratch: ContiguousArray<Float>
    /// Per-(window, band) energy scratch for short blocks (3 windows × 12 short bands).
    private var shortBandEnergyScratch: ContiguousArray<Double>
    /// Per-bitstream-slot scratch for the subblock-gain pre-scaled spectral.
    private var shortPreScaledScratch: ContiguousArray<Float>

    init(sampleRate: Int) {
        scaleFactorBandBounds = MP3Constants.scaleFactorBandBoundaries(sampleRate: sampleRate)
        shortWindowTable = ShortBlockLayout.bitstreamWindowTable(sampleRate: sampleRate)
        shortBandTable = ShortBlockLayout.bitstreamBandTable(sampleRate: sampleRate)
        absoluteBuffer = ContiguousArray(repeating: 0, count: 576)
        sqrtBuffer = ContiguousArray(repeating: 0, count: 576)
        scaledBuffer = ContiguousArray(repeating: 0, count: 576)
        quantizedInt32 = ContiguousArray(repeating: 0, count: 576)
        quantizedScratch = ContiguousArray(repeating: 0, count: 576)
        scaleFactorScratch = ContiguousArray(repeating: 0, count: 576)
        originalDoubleScratch = ContiguousArray(repeating: 0, count: 576)
        quantizedMagnitudeDoubleScratch = ContiguousArray(repeating: 0, count: 576)
        cbrtDoubleScratch = ContiguousArray(repeating: 0, count: 576)
        decodedDoubleScratch = ContiguousArray(repeating: 0, count: 576)
        diffDoubleScratch = ContiguousArray(repeating: 0, count: 576)
        distortionScratch = ContiguousArray(repeating: 0, count: max(1, scaleFactorBandBounds.count - 1))
        shortBandEnergyScratch = ContiguousArray(repeating: 0, count: 3 * 13)
        shortPreScaledScratch = ContiguousArray(repeating: 0, count: 576)
    }

    // MARK: - Vectorized quantize

    /// Quantize all 576 spectral values into `destination`.
    /// Formula: `quantized[i] = sign(x) * trunc(|x|^0.75 / 2^((g-210)/4) + 0.4054)`.
    func quantizeInto(spectral: UnsafePointer<Float>, globalGain: Int, destination: UnsafeMutablePointer<Int>) {
        let length: vDSP_Length = 576

        // 1) absoluteBuffer = |spectral|
        absoluteBuffer.withUnsafeMutableBufferPointer { absoluteBuffer in
            vDSP_vabs(spectral, 1, absoluteBuffer.baseAddress!, 1, length)

            // 2) sqrtBuffer = sqrt(|x|)
            sqrtBuffer.withUnsafeMutableBufferPointer { sqrtBuffer in
                var lengthInt32: Int32 = 576
                vvsqrtf(sqrtBuffer.baseAddress!, absoluteBuffer.baseAddress!, &lengthInt32)

                // 3) scaledBuffer = |x| * sqrt(|x|) = |x|^1.5
                scaledBuffer.withUnsafeMutableBufferPointer { scaledBuffer in
                    vDSP_vmul(absoluteBuffer.baseAddress!, 1, sqrtBuffer.baseAddress!, 1, scaledBuffer.baseAddress!, 1, length)

                    // 4) sqrtBuffer = sqrt(|x|^1.5) = |x|^0.75 (reuse sqrtBuffer as raised)
                    vvsqrtf(sqrtBuffer.baseAddress!, scaledBuffer.baseAddress!, &lengthInt32)

                    // 5) scaledBuffer = sqrtBuffer * inverseScale + 0.4054
                    var inverseScale = Float(pow(2.0, -Double(globalGain - 210) * 0.25))
                    var bias: Float = 0.4054
                    vDSP_vsmsa(sqrtBuffer.baseAddress!, 1, &inverseScale, &bias, scaledBuffer.baseAddress!, 1, length)

                    // 6) Clamp to a safe range so vDSP_vfix32 has defined behavior
                    //    even when `inverseScale` is astronomical (low global gains).
                    //    2^30 is well above any encodable Huffman magnitude.
                    var lowerBound: Float = 0
                    var upperBound: Float = 1_073_741_824 // 2^30
                    vDSP_vclip(scaledBuffer.baseAddress!, 1, &lowerBound, &upperBound, scaledBuffer.baseAddress!, 1, length)

                    // 7) Truncate to Int32
                    quantizedInt32.withUnsafeMutableBufferPointer { quantizedInt32 in
                        vDSP_vfix32(scaledBuffer.baseAddress!, 1, quantizedInt32.baseAddress!, 1, length)

                        // 8) Apply sign based on the original spectral value
                        let quantizedBase = quantizedInt32.baseAddress!
                        for index in 0 ..< 576 {
                            let magnitude = Int(quantizedBase[index])
                            destination[index] = spectral[index] < 0 ? -magnitude : magnitude
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bit counting

    /// Count the number of bits needed to Huffman-encode the quantized values
    /// and populate the region/table selections in `granuleInfo`.
    func countBits(quantized: UnsafeBufferPointer<Int>, granuleInfo: inout GranuleInfo) -> Int {
        let count = quantized.count

        // Last non-zero coefficient
        var lastNonZeroIndex = -1
        for index in stride(from: count - 1, through: 0, by: -1) {
            if quantized[index] != 0 {
                lastNonZeroIndex = index
                break
            }
        }

        if lastNonZeroIndex < 0 {
            granuleInfo.bigValues = 0
            granuleInfo.tableSelect = [0, 0, 0]
            granuleInfo.region0Count = 10
            granuleInfo.region1Count = 3
            granuleInfo.count1TableSelect = 0
            return 0
        }

        // count1 region: quads of -1,0,+1 up through `count1Start` (multiple of 4)
        var count1Start = lastNonZeroIndex + 1
        count1Start = ((count1Start + 3) / 4) * 4
        count1Start = min(count1Start, 576)

        // Find where big_values end (last value > 1), aligned to even
        var bigValuesEnd = 0
        for index in stride(from: count1Start - 1, through: 0, by: -1) {
            if abs(quantized[index]) > 1 {
                bigValuesEnd = index + 1
                break
            }
        }
        bigValuesEnd = ((bigValuesEnd + 1) / 2) * 2
        granuleInfo.bigValues = bigValuesEnd / 2

        // Region boundaries (SFB-aligned)
        let region0SfbCount = min(granuleInfo.region0Count + 1, scaleFactorBandBounds.count - 1)
        let region0End = min(scaleFactorBandBounds[region0SfbCount], bigValuesEnd)

        let region1SfbCount = min(region0SfbCount + granuleInfo.region1Count + 1, scaleFactorBandBounds.count - 1)
        let region1End = min(scaleFactorBandBounds[region1SfbCount], bigValuesEnd)

        let region0Selection = selectHuffmanTableAndBits(values: quantized, start: 0, end: region0End)
        let region1Selection = selectHuffmanTableAndBits(values: quantized, start: region0End, end: region1End)
        let region2Selection = selectHuffmanTableAndBits(values: quantized, start: region1End, end: bigValuesEnd)

        granuleInfo.tableSelect[0] = region0Selection.tableIndex
        granuleInfo.tableSelect[1] = region1Selection.tableIndex
        granuleInfo.tableSelect[2] = region2Selection.tableIndex

        var bits = region0Selection.bits + region1Selection.bits + region2Selection.bits

        // count1 quads: try both count1 tables, pick the smaller
        var quadIndex = bigValuesEnd
        var count1BitsTableA = 0
        var count1BitsTableB = 0
        while quadIndex + 3 < count1Start {
            let first = quantized[quadIndex]
            let second = quantized[quadIndex + 1]
            let third = quantized[quadIndex + 2]
            let fourth = quantized[quadIndex + 3]
            if abs(first) > 1 || abs(second) > 1 || abs(third) > 1 || abs(fourth) > 1 {
                break
            }
            count1BitsTableA += countQuadBits(first: first, second: second, third: third, fourth: fourth, tableIndex: 0)
            count1BitsTableB += countQuadBits(first: first, second: second, third: third, fourth: fourth, tableIndex: 1)
            quadIndex += 4
        }

        if count1BitsTableB < count1BitsTableA {
            granuleInfo.count1TableSelect = 1
            bits += count1BitsTableB
        } else {
            granuleInfo.count1TableSelect = 0
            bits += count1BitsTableA
        }

        return bits
    }

    // MARK: - Rate control

    /// Maximum amount the chosen `global_gain` is allowed to drop below the caller's
    /// hint. When the previous granule on this channel ran at gain G and the current
    /// granule's optimum is < G - this, we clamp upward to G - this. The cost is a
    /// few wasted bits on quieter granules; the win is a steady noise floor across
    /// frames, which removes the audible "fluttering" texture on smooth content.
    /// 4 ≈ 1 dB step in the decoder's gain-domain unit, well below audibility.
    private static let gainSmoothingMaxDelta = 4

    /// Inner loop: binary-search the minimum global_gain that fits within `targetBits`.
    /// Writes the winning gain's quantized values into `destination` and returns the Huffman
    /// bit count measured during the winning iteration, so callers never need to re-count.
    ///
    /// If `granuleInfo.globalGain` is non-zero on entry it's treated as a smoothing
    /// hint: the binary search warm-starts at the hint (faster convergence) and the
    /// chosen gain is clamped upward to no less than `hint - gainSmoothingMaxDelta`
    /// when the optimum sits below it. Pass 0 to opt out (full [0,255] search, no
    /// smoothing) — this is what the encoder does on the first granule and after
    /// any short/start/stop block.
    private func innerLoop(
        spectral: UnsafeBufferPointer<Float>,
        targetBits: Int,
        destination: UnsafeMutableBufferPointer<Int>,
        granuleInfo: inout GranuleInfo
    ) -> Int {
        let hint = granuleInfo.globalGain
        var lowerGain = 0
        var upperGain = 255
        var bestGain = 255
        var bestBits = 0
        var bestGranuleInfo = granuleInfo

        quantizedScratch.withUnsafeMutableBufferPointer { quantizedBuffer in
            // Warm-start: try the hint first, then narrow the search around it.
            // For consecutive long blocks on the same channel this typically converges
            // in 2–3 iterations instead of the full ~8.
            if hint > 0, hint < 256 {
                var hintCandidateInfo = granuleInfo
                quantizeInto(spectral: spectral.baseAddress!, globalGain: hint, destination: quantizedBuffer.baseAddress!)
                let hintBits = countBits(quantized: UnsafeBufferPointer(quantizedBuffer), granuleInfo: &hintCandidateInfo)
                if hintBits <= targetBits {
                    bestGain = hint
                    bestBits = hintBits
                    bestGranuleInfo = hintCandidateInfo
                    upperGain = hint - 1
                } else {
                    lowerGain = hint + 1
                }
            }

            while lowerGain <= upperGain {
                let midGain = (lowerGain + upperGain) / 2
                var candidateInfo = granuleInfo
                quantizeInto(spectral: spectral.baseAddress!, globalGain: midGain, destination: quantizedBuffer.baseAddress!)
                let bits = countBits(quantized: UnsafeBufferPointer(quantizedBuffer), granuleInfo: &candidateInfo)

                if bits <= targetBits {
                    bestGain = midGain
                    bestBits = bits
                    bestGranuleInfo = candidateInfo
                    upperGain = midGain - 1
                } else {
                    lowerGain = midGain + 1
                }
            }

            // Smoothing clamp: when the optimum dropped well below the hint, raise it
            // back toward the hint by at most `gainSmoothingMaxDelta`. We re-quantize at
            // the smoothed gain and re-count bits so part2_3_length stays accurate. The
            // smoothed gain is always ≥ bestGain (= fewer bits used), so the bit budget
            // stays satisfied for free.
            if hint > 0, bestGain < hint - Self.gainSmoothingMaxDelta {
                let smoothedGain = min(255, hint - Self.gainSmoothingMaxDelta)
                var candidateInfo = granuleInfo
                quantizeInto(spectral: spectral.baseAddress!, globalGain: smoothedGain, destination: quantizedBuffer.baseAddress!)
                let smoothedBits = countBits(quantized: UnsafeBufferPointer(quantizedBuffer), granuleInfo: &candidateInfo)
                if smoothedBits <= targetBits {
                    bestGain = smoothedGain
                    bestBits = smoothedBits
                    bestGranuleInfo = candidateInfo
                }
            }
        }

        // Produce bestGain's quantized values directly into the caller's buffer.
        quantizeInto(spectral: spectral.baseAddress!, globalGain: bestGain, destination: destination.baseAddress!)

        granuleInfo = bestGranuleInfo
        granuleInfo.globalGain = bestGain
        return bestBits
    }

    /// Quantize against the normal target first, then spend reservoir bits only when
    /// measured distortion still exceeds the psychoacoustic thresholds. Writes the final
    /// quantized values into `destination` and returns the Huffman bit count (excluding
    /// `granuleInfo.part2Length`).
    func outerLoop(
        spectral: UnsafeBufferPointer<Float>,
        thresholds: [Float],
        targetBits: Int,
        reservoirBits: Int = 0,
        destination: UnsafeMutableBufferPointer<Int>,
        granuleInfo: inout GranuleInfo
    ) -> Int {
        // First-cut short-block path: skip the long-block distortion-control loop and
        // let global_gain alone handle quantization. All short scale factors and
        // subblock_gains stay at zero, so part2Length = 0 and every available bit
        // goes to Huffman data. This is correct but suboptimal — per-(window, band)
        // scale factor optimization can be layered in later without changing callers.
        if granuleInfo.blockType == MDCTBlockType.shortBlocks.rawValue {
            return outerLoopShort(
                spectral: spectral,
                targetBits: targetBits + reservoirBits,
                destination: destination,
                granuleInfo: &granuleInfo
            )
        }

        let originalInfo = granuleInfo
        var workingInfo = granuleInfo
        let baseBits = distortionScratch.withUnsafeMutableBufferPointer { distortion in
            quantizeWithDistortionControl(
                spectral: spectral,
                thresholds: thresholds,
                targetBits: targetBits,
                destination: destination,
                distortion: distortion,
                granuleInfo: &workingInfo
            )
        }

        guard reservoirBits > 0 else {
            granuleInfo = workingInfo
            return baseBits
        }

        let pressure = distortionScratch.withUnsafeBufferPointer { distortion in
            maskingPressure(distortion: distortion, thresholds: thresholds)
        }
        let extraBits = reservoirBitsToSpend(availableBits: reservoirBits, maskingPressure: pressure)
        guard extraBits > 0 else {
            granuleInfo = workingInfo
            return baseBits
        }

        // If the base pass converged without bumping any scale factors, the reservoir
        // pass with a larger budget would only produce smaller quantized values and even
        // less distortion — running the full three-iteration distortion-control loop again
        // is guaranteed not to bump either, so a single innerLoop at the larger budget
        // suffices. That cuts the most expensive call path (countBits + Huffman scans
        // through the binary search) roughly in half for well-masked audio.
        if workingInfo.scaleFactors.allSatisfy({ $0 == 0 }) {
            var reservoirInfo = originalInfo
            reservoirInfo.scaleFactors = [Int](repeating: 0, count: scaleFactorBandBounds.count - 1)
            reservoirInfo.scaleFactorScale = false
            reservoirInfo.scaleFactorCompress = 0
            reservoirInfo.part2Length = 0
            let availableBits = max(0, targetBits + extraBits - reservoirInfo.part2Length)
            let reservoirHuffmanBits = innerLoop(
                spectral: spectral,
                targetBits: availableBits,
                destination: destination,
                granuleInfo: &reservoirInfo
            )
            granuleInfo = reservoirInfo
            return reservoirHuffmanBits
        }

        var reservoirInfo = originalInfo
        let reservoirHuffmanBits = distortionScratch.withUnsafeMutableBufferPointer { distortion in
            quantizeWithDistortionControl(
                spectral: spectral,
                thresholds: thresholds,
                targetBits: targetBits + extraBits,
                destination: destination,
                distortion: distortion,
                granuleInfo: &reservoirInfo
            )
        }
        granuleInfo = reservoirInfo
        return reservoirHuffmanBits
    }

    /// Short-block fast path: pick a `subblock_gain` per window so all three windows
    /// share the bit budget instead of the loud window starving the quiet ones, then
    /// run the inner-loop binary search on `global_gain`. Scale factors stay at zero
    /// for now; per-(window, band) scale factor optimization can layer on top.
    private func outerLoopShort(
        spectral: UnsafeBufferPointer<Float>,
        targetBits: Int,
        destination: UnsafeMutableBufferPointer<Int>,
        granuleInfo: inout GranuleInfo
    ) -> Int {
        var subblockGain: [Int] = [0, 0, 0]

        // Scan once for per-window peak magnitude.
        var windowPeak: [Double] = [0, 0, 0]
        shortWindowTable.withUnsafeBufferPointer { windowIndices in
            let windowBase = windowIndices.baseAddress!
            for index in 0 ..< 576 {
                let value = abs(Double(spectral[index]))
                let window = windowBase[index]
                if value > windowPeak[window] {
                    windowPeak[window] = value
                }
            }
        }
        let maxPeak = max(windowPeak[0], max(windowPeak[1], windowPeak[2]))

        // subblock_gain attenuates the decoder by 2^(-2*sg) per window, so the encoder
        // pre-multiplies by 2^(2*sg). For a window that's quieter than the loudest by
        // a factor R, choose sg = floor(log2(R) / 2) — the largest power-of-4 boost
        // that doesn't exceed the loud window's peak. Without this, a single-window
        // transient leaves the other windows quantized to all zeros (audible spectral
        // holes); with it, every window keeps real resolution.
        if maxPeak > 0 {
            for windowIndex in 0 ..< 3 {
                let peak = windowPeak[windowIndex]
                guard peak > 0 else {
                    continue
                }
                let ratio = maxPeak / peak
                if ratio <= 1 {
                    continue
                }
                let candidate = Int(floor(log2(ratio) / 2.0))
                subblockGain[windowIndex] = max(0, min(7, candidate))
            }
        }

        // Pre-scale spectral by 2^(2*sg) per window into the dedicated scratch.
        return shortPreScaledScratch.withUnsafeMutableBufferPointer { preScaled in
            shortWindowTable.withUnsafeBufferPointer { windowIndices in
                let windowBase = windowIndices.baseAddress!
                let factors = (0 ..< 3).map { Float(pow(2.0, Double(2 * subblockGain[$0]))) }
                for index in 0 ..< 576 {
                    preScaled[index] = spectral[index] * factors[windowBase[index]]
                }
            }

            granuleInfo.scaleFactors = Array(repeating: 0, count: scaleFactorBandBounds.count - 1)
            granuleInfo.scaleFactorsShort = Array(repeating: 0, count: 39)
            granuleInfo.scaleFactorScale = false
            granuleInfo.scaleFactorCompress = 0
            granuleInfo.part2Length = 0
            granuleInfo.preflag = false
            granuleInfo.subblockGain = subblockGain

            return innerLoop(
                spectral: UnsafeBufferPointer(preScaled),
                targetBits: max(0, targetBits),
                destination: destination,
                granuleInfo: &granuleInfo
            )
        }
    }

    /// ISO/IEC 11172-3 distortion-control loop. Each iteration quantizes at the current
    /// scale factors, measures actual per-band distortion against the psychoacoustic
    /// masking threshold, and amplifies only the bands whose noise still exceeds it.
    /// The loop converges when every band is masked or hit its per-region cap.
    ///
    /// Writes the final quantized values into `destination` (one write per iteration,
    /// last iteration wins), leaves the matching per-band distortion in `distortion`
    /// so the caller can reuse it for masking-pressure checks without a second
    /// cbrt/requantize pass, and returns the Huffman bit count.
    private func quantizeWithDistortionControl(
        spectral: UnsafeBufferPointer<Float>,
        thresholds: [Float],
        targetBits: Int,
        destination: UnsafeMutableBufferPointer<Int>,
        distortion: UnsafeMutableBufferPointer<Float>,
        granuleInfo: inout GranuleInfo
    ) -> Int {
        // Always scale=0 (0.5 dB SF step) for now. A scale=1 retry could help on
        // genuinely cap-limited granules but the all-or-nothing rerun roughly
        // doubles encode time on real-world music, so we leave it for a future
        // pass with a cheaper retry strategy (see TODO.md).
        distortionControlPass(
            spectral: spectral,
            thresholds: thresholds,
            targetBits: targetBits,
            scaleFactorScale: false,
            destination: destination,
            distortion: distortion,
            granuleInfo: &granuleInfo
        ).huffmanBits
    }

    private struct DistortionControlResult {
        var huffmanBits: Int
        var cappedBandStillAudible: Bool
    }

    /// One full distortion-control pass at a fixed `scaleFactorScale`. Returns the
    /// Huffman bit count plus a flag indicating whether any band ended capped with
    /// residual distortion (a future scale=1 retry hint that's not currently used).
    private func distortionControlPass(
        spectral: UnsafeBufferPointer<Float>,
        thresholds: [Float],
        targetBits: Int,
        scaleFactorScale: Bool,
        destination: UnsafeMutableBufferPointer<Int>,
        distortion: UnsafeMutableBufferPointer<Float>,
        granuleInfo: inout GranuleInfo
    ) -> DistortionControlResult {
        let bandCount = scaleFactorBandBounds.count - 1
        // SFBs 11–20 span many spectral lines, so each SF unit there costs lots of
        // Huffman bits; cap them tighter than the narrow low SFBs.
        let lowBandCap = 4
        let highBandCap = 2
        let maxIterations = 3
        // Hysteresis: only bump when noise is meaningfully above threshold (~3 dB),
        // so bands sitting on the boundary don't toggle frame-to-frame.
        let bumpMargin: Float = 2.0

        var scaleFactors = [Int](repeating: 0, count: bandCount)
        var resultInfo = granuleInfo
        var resultBits = 0

        for iteration in 0 ..< maxIterations {
            var workingInfo = granuleInfo
            workingInfo.scaleFactors = scaleFactors
            workingInfo.scaleFactorScale = scaleFactorScale
            workingInfo.scaleFactorCompress = chooseScaleFactorCompress(for: scaleFactors) ?? 0
            workingInfo.part2Length = scaleFactorBitCost(compress: workingInfo.scaleFactorCompress)

            let availableBits = max(0, targetBits - workingInfo.part2Length)

            let huffmanBits: Int = if scaleFactors.allSatisfy({ $0 == 0 }) {
                innerLoop(
                    spectral: spectral,
                    targetBits: availableBits,
                    destination: destination,
                    granuleInfo: &workingInfo
                )
            } else {
                scaleFactorScratch.withUnsafeMutableBufferPointer { scaledBuffer in
                    applyScaleFactors(
                        spectral: spectral,
                        scaleFactors: scaleFactors,
                        scaleFactorScale: workingInfo.scaleFactorScale,
                        destination: scaledBuffer
                    )
                    return innerLoop(
                        spectral: UnsafeBufferPointer(start: scaledBuffer.baseAddress!, count: spectral.count),
                        targetBits: availableBits,
                        destination: destination,
                        granuleInfo: &workingInfo
                    )
                }
            }
            resultInfo = workingInfo
            resultBits = huffmanBits

            perBandDistortion(
                originalSpectral: spectral,
                quantized: UnsafeBufferPointer(destination),
                globalGain: workingInfo.globalGain,
                scaleFactors: scaleFactors,
                scaleFactorScale: workingInfo.scaleFactorScale,
                distortion: distortion
            )

            if iteration == maxIterations - 1 {
                break
            }

            var anyBumped = false
            for band in 0 ..< bandCount {
                let cap = band < 11 ? lowBandCap : highBandCap
                guard scaleFactors[band] < cap else {
                    continue
                }
                let threshold = band < thresholds.count ? thresholds[band] : 0
                guard threshold > 0 else {
                    continue
                }
                if distortion[band] > threshold * bumpMargin {
                    scaleFactors[band] += 1
                    anyBumped = true
                }
            }

            if !anyBumped {
                break
            }
        }

        // Detect whether the granule is a genuine "needs more amplification range"
        // case worth paying the scale=1 retry cost for. We require ≥ 6 bands capped
        // with residual distortion ≥ 8× threshold (≈ 9 dB above masking) — i.e.
        // the granule is broadly distortion-limited at the SF cap, not just
        // marginal in a few places. Looser thresholds here easily double encoder
        // runtime for negligible quality gain because most music produces a few
        // capped bands as a matter of course.
        let retryBandThreshold = 6
        let retryDistortionMargin: Float = bumpMargin * 4
        var cappedAudibleBands = 0
        for band in 0 ..< bandCount {
            let cap = band < 11 ? lowBandCap : highBandCap
            guard scaleFactors[band] >= cap else {
                continue
            }
            let threshold = band < thresholds.count ? thresholds[band] : 0
            guard threshold > 0 else {
                continue
            }
            if distortion[band] > threshold * retryDistortionMargin {
                cappedAudibleBands += 1
                if cappedAudibleBands >= retryBandThreshold {
                    break
                }
            }
        }
        let cappedBandStillAudible = cappedAudibleBands >= retryBandThreshold

        granuleInfo = resultInfo
        return DistortionControlResult(huffmanBits: resultBits, cappedBandStillAudible: cappedBandStillAudible)
    }

    private func maskingPressure(
        distortion: UnsafeBufferPointer<Float>,
        thresholds: [Float]
    ) -> Float {
        var pressure: Float = 0
        for band in 0 ..< min(distortion.count, thresholds.count) {
            let threshold = thresholds[band]
            guard threshold > 0 else {
                continue
            }
            pressure = max(pressure, distortion[band] / threshold)
        }
        return pressure
    }

    private func reservoirBitsToSpend(availableBits: Int, maskingPressure: Float) -> Int {
        guard maskingPressure > 1.5 else {
            return 0
        }
        guard maskingPressure < 8 else {
            return availableBits
        }

        let start = log2(Float(1.5))
        let end = log2(Float(8.0))
        let fraction = (log2(maskingPressure) - start) / (end - start)
        return Int((Float(availableBits) * fraction).rounded())
    }

    /// Mirrors the decoder's requantize: `decoded = sign(q) * |q|^(4/3) * 2^((g-210)/4) * 2^(-sf * mult)`.
    /// Compares against the unscaled original, so distortion is in the audio (post-decode) domain
    /// and directly comparable to a band masking threshold expressed in the same units.
    private func perBandDistortion(
        originalSpectral: UnsafeBufferPointer<Float>,
        quantized: UnsafeBufferPointer<Int>,
        globalGain: Int,
        scaleFactors: [Int],
        scaleFactorScale: Bool,
        distortion: UnsafeMutableBufferPointer<Float>
    ) {
        let bandCount = scaleFactorBandBounds.count - 1
        for band in 0 ..< min(bandCount, distortion.count) {
            distortion[band] = 0
        }

        let sampleCount = min(576, originalSpectral.count, quantized.count)
        guard sampleCount > 0 else {
            return
        }

        var sampleCountInt32 = Int32(sampleCount)
        originalDoubleScratch.withUnsafeMutableBufferPointer { originalDouble in
            vDSP_vspdp(originalSpectral.baseAddress!, 1, originalDouble.baseAddress!, 1, vDSP_Length(sampleCount))
        }

        quantizedMagnitudeDoubleScratch.withUnsafeMutableBufferPointer { magnitudes in
            decodedDoubleScratch.withUnsafeMutableBufferPointer { decoded in
                let magnitudeBase = magnitudes.baseAddress!
                let decodedBase = decoded.baseAddress!
                for index in 0 ..< sampleCount {
                    magnitudeBase[index] = Double(abs(quantized[index]))
                }

                cbrtDoubleScratch.withUnsafeMutableBufferPointer { roots in
                    vvcbrt(roots.baseAddress!, magnitudeBase, &sampleCountInt32)
                    vDSP_vmulD(roots.baseAddress!, 1, magnitudeBase, 1, decodedBase, 1, vDSP_Length(sampleCount))
                    for index in 0 ..< sampleCount where quantized[index] < 0 {
                        decodedBase[index] = -decodedBase[index]
                    }
                }
            }
        }

        let gainScale = pow(2.0, Double(globalGain - 210) * 0.25)
        let multiplier = scaleFactorScale ? 1.0 : 0.5

        for band in 0 ..< bandCount {
            let bandStart = scaleFactorBandBounds[band]
            let bandEnd = min(scaleFactorBandBounds[band + 1], sampleCount)
            guard bandStart < bandEnd else {
                continue
            }

            let scaleFactor = band < scaleFactors.count ? scaleFactors[band] : 0
            var bandFactor = gainScale * pow(2.0, -Double(scaleFactor) * multiplier)
            let bandLength = vDSP_Length(bandEnd - bandStart)

            decodedDoubleScratch.withUnsafeMutableBufferPointer { decoded in
                originalDoubleScratch.withUnsafeBufferPointer { original in
                    diffDoubleScratch.withUnsafeMutableBufferPointer { diff in
                        let decodedBand = decoded.baseAddress! + bandStart
                        let originalBand = original.baseAddress! + bandStart
                        let diffBand = diff.baseAddress! + bandStart
                        vDSP_vsmulD(decodedBand, 1, &bandFactor, decodedBand, 1, bandLength)
                        vDSP_vsubD(decodedBand, 1, originalBand, 1, diffBand, 1, bandLength)
                        var bandDistortion = 0.0
                        vDSP_svesqD(diffBand, 1, &bandDistortion, bandLength)
                        distortion[band] = Float(bandDistortion)
                    }
                }
            }
        }
    }

    private func applyScaleFactors(
        spectral: UnsafeBufferPointer<Float>,
        scaleFactors: [Int],
        scaleFactorScale: Bool,
        destination: UnsafeMutableBufferPointer<Float>
    ) {
        let multiplier = scaleFactorScale ? 1.0 : 0.5
        let count = min(spectral.count, destination.count)
        destination.baseAddress!.update(from: spectral.baseAddress!, count: count)

        for band in 0 ..< min(scaleFactors.count, scaleFactorBandBounds.count - 1) {
            let bandStart = scaleFactorBandBounds[band]
            let bandEnd = min(scaleFactorBandBounds[band + 1], count)
            guard bandStart < bandEnd else {
                continue
            }

            var factor = Float(pow(2.0, multiplier * Double(scaleFactors[band])))
            if factor == 1 {
                continue
            }

            vDSP_vsmul(destination.baseAddress! + bandStart, 1, &factor, destination.baseAddress! + bandStart, 1, vDSP_Length(bandEnd - bandStart))
        }
    }

    private func chooseScaleFactorCompress(for scaleFactors: [Int]) -> Int? {
        let maxLow = scaleFactors.prefix(11).max() ?? 0
        let maxHigh = scaleFactors.dropFirst(11).prefix(10).max() ?? 0

        var bestCompress: Int?
        var bestBits = Int.max
        for compress in 0 ..< 16 {
            let (lowBitLength, highBitLength) = scaleFactorBitLengthPair(for: compress)
            let lowLimit = lowBitLength == 0 ? 0 : (1 << lowBitLength) - 1
            let highLimit = highBitLength == 0 ? 0 : (1 << highBitLength) - 1
            if maxLow > lowLimit || maxHigh > highLimit {
                continue
            }

            let bits = 11 * lowBitLength + 10 * highBitLength
            if bits < bestBits {
                bestBits = bits
                bestCompress = compress
            }
        }

        return bestCompress
    }

    private func scaleFactorBitCost(compress: Int) -> Int {
        let (lowBitLength, highBitLength) = scaleFactorBitLengthPair(for: compress)
        return 11 * lowBitLength + 10 * highBitLength
    }

    private func scaleFactorBitLengthPair(for compress: Int) -> (Int, Int) {
        let lowBitLengths = [0, 0, 0, 0, 3, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4]
        let highBitLengths = [0, 1, 2, 3, 0, 1, 2, 3, 1, 2, 3, 1, 2, 3, 2, 3]
        let index = max(0, min(compress, 15))
        return (lowBitLengths[index], highBitLengths[index])
    }
}
