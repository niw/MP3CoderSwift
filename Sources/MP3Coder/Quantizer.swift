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
    /// Per-band distortion scratch (all `perBandDistortion` work done in Float).
    /// The masking comparison has ~6 dB headroom so single precision is plenty.
    private var quantizedMagnitudeFloatScratch: ContiguousArray<Float>
    private var cbrtFloatScratch: ContiguousArray<Float>
    private var decodedFloatScratch: ContiguousArray<Float>
    private var diffFloatScratch: ContiguousArray<Float>
    private var distortionScratch: ContiguousArray<Float>
    /// Per-(window, band) energy scratch for short blocks (3 windows × 12 short bands).
    private var shortBandEnergyScratch: ContiguousArray<Double>
    /// Per-bitstream-slot scratch for the subblock-gain pre-scaled spectral.
    private var shortPreScaledScratch: ContiguousArray<Float>
    /// Cache of `|spectral|^0.75` populated once per `innerLoop` call. Steps 1–4
    /// of `quantizeInto` (vabs, vvsqrtf, vmul, vvsqrtf) only depend on the
    /// spectral input, not on `globalGain`, so the binary search reuses this
    /// across every probe instead of recomputing the four-stage Accelerate
    /// pipeline.
    private var absPow075Cache: ContiguousArray<Float>

    /// Pre-allocated zero arrays handed to `GranuleInfo.scaleFactors` /
    /// `scaleFactorsShort` instead of `Array(repeating: 0, …)` per granule.
    /// Array assignment shares the buffer — CoW only triggers when the caller
    /// mutates, which avoids one heap allocation per granule for the all-zero
    /// path that distortion control hits before any band gets bumped.
    private let zeroScaleFactorsLong: [Int]
    private let zeroScaleFactorsShort: [Int] = Array(repeating: 0, count: 39)
    /// Reused inside `distortionControlPass` for the local accumulator that
    /// previously allocated `[Int](repeating: 0, count: bandCount)` per call.
    private var distortionScaleFactorsScratch: [Int]

    /// Per-quantizer counter storage. Always tracked (single array store per
    /// bump), drained into a shared `MP3EncoderProfiler` between frames so
    /// concurrent quantizer instances never write to the profiler in flight.
    /// In production runs (no profiler attached) the increments are still
    /// effectively free — the storage stays warm in cache and never escapes.
    private var localCounters: [UInt64] = Array(
        repeating: 0,
        count: MP3EncoderProfiler.Counter.allCases.count
    )

    @inline(__always)
    private func bumpCounter(_ counter: MP3EncoderProfiler.Counter, by amount: UInt64 = 1) {
        localCounters[counter.rawValue] &+= amount
    }

    /// Returns the accumulated counter deltas since the last drain and resets
    /// local storage to zero. Called by the encoder once per frame after the
    /// per-channel parallel block completes — by that point every concurrent
    /// quantizer is quiescent so the read is race-free.
    func consumeLocalCounters() -> [UInt64] {
        let snapshot = localCounters
        for index in localCounters.indices {
            localCounters[index] = 0
        }
        return snapshot
    }

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
        quantizedMagnitudeFloatScratch = ContiguousArray(repeating: 0, count: 576)
        cbrtFloatScratch = ContiguousArray(repeating: 0, count: 576)
        decodedFloatScratch = ContiguousArray(repeating: 0, count: 576)
        diffFloatScratch = ContiguousArray(repeating: 0, count: 576)
        distortionScratch = ContiguousArray(repeating: 0, count: max(1, scaleFactorBandBounds.count - 1))
        shortBandEnergyScratch = ContiguousArray(repeating: 0, count: 3 * 13)
        shortPreScaledScratch = ContiguousArray(repeating: 0, count: 576)
        zeroScaleFactorsLong = Array(repeating: 0, count: max(1, scaleFactorBandBounds.count - 1))
        distortionScaleFactorsScratch = Array(repeating: 0, count: max(1, scaleFactorBandBounds.count - 1))
        absPow075Cache = ContiguousArray(repeating: 0, count: 576)
    }

    // MARK: - Vectorized quantize

    /// Quantize all 576 spectral values into `destination`.
    /// Formula: `quantized[i] = sign(x) * trunc(|x|^0.75 / 2^((g-210)/4) + 0.4054)`.
    ///
    /// One-shot path: prepares the gain-independent `|x|^0.75` cache, then
    /// finishes with `quantizeFromCachedAbsPow075`. Callers that probe the same
    /// spectral with multiple gains (the rate-control binary search) should
    /// hit `prepareAbsPow075Cache` once and `quantizeFromCachedAbsPow075` per
    /// probe to avoid redoing the four-stage Accelerate pipeline.
    func quantizeInto(
        spectral: UnsafeBufferPointer<Float>,
        globalGain: Int,
        destination: UnsafeMutableBufferPointer<Int>
    ) {
        prepareAbsPow075Cache(spectral: spectral)
        quantizeFromCachedAbsPow075(spectral: spectral, globalGain: globalGain, destination: destination)
    }

    /// Compute `|spectral|^0.75` once into `absPow075Cache`. Independent of
    /// `globalGain`, so a single call covers every binary-search probe.
    @inline(__always)
    private func prepareAbsPow075Cache(spectral: UnsafeBufferPointer<Float>) {
        let length: vDSP_Length = 576
        var lengthInt32: Int32 = 576
        let spectralBase = spectral.baseAddress!

        absoluteBuffer.withUnsafeMutableBufferPointer { absoluteBuffer in
            vDSP_vabs(spectralBase, 1, absoluteBuffer.baseAddress!, 1, length)

            sqrtBuffer.withUnsafeMutableBufferPointer { sqrtBuffer in
                vvsqrtf(sqrtBuffer.baseAddress!, absoluteBuffer.baseAddress!, &lengthInt32)

                scaledBuffer.withUnsafeMutableBufferPointer { scaledBuffer in
                    // scaledBuffer = |x| * sqrt(|x|) = |x|^1.5
                    vDSP_vmul(absoluteBuffer.baseAddress!, 1, sqrtBuffer.baseAddress!, 1, scaledBuffer.baseAddress!, 1, length)

                    absPow075Cache.withUnsafeMutableBufferPointer { cache in
                        // cache = sqrt(|x|^1.5) = |x|^0.75
                        vvsqrtf(cache.baseAddress!, scaledBuffer.baseAddress!, &lengthInt32)
                    }
                }
            }
        }
    }

    /// Apply `inverseScale + bias` and the truncate-with-sign step using the
    /// cached `|x|^0.75`. Caller must have populated the cache via
    /// `prepareAbsPow075Cache(spectral:)` (with the same spectral buffer used
    /// for the sign source here) before invoking this.
    @inline(__always)
    private func quantizeFromCachedAbsPow075(
        spectral: UnsafeBufferPointer<Float>,
        globalGain: Int,
        destination: UnsafeMutableBufferPointer<Int>
    ) {
        let length: vDSP_Length = 576
        let clampedGain = max(0, min(255, globalGain))
        var inverseScale = Self.encoderGainScale[clampedGain]
        var bias: Float = 0.4054
        var lowerBound: Float = 0
        var upperBound: Float = 1_073_741_824 // 2^30

        absPow075Cache.withUnsafeBufferPointer { cache in
            scaledBuffer.withUnsafeMutableBufferPointer { scaledBuffer in
                vDSP_vsmsa(cache.baseAddress!, 1, &inverseScale, &bias, scaledBuffer.baseAddress!, 1, length)
                vDSP_vclip(scaledBuffer.baseAddress!, 1, &lowerBound, &upperBound, scaledBuffer.baseAddress!, 1, length)

                quantizedInt32.withUnsafeMutableBufferPointer { quantizedInt32 in
                    vDSP_vfix32(scaledBuffer.baseAddress!, 1, quantizedInt32.baseAddress!, 1, length)
                    for index in 0 ..< 576 {
                        let magnitude = Int(quantizedInt32[index])
                        destination[index] = spectral[index] < 0 ? -magnitude : magnitude
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

        // Last non-zero coefficient. Reverse scan bails on the first non-zero
        // from the high-frequency end, which is typically a few iterations on
        // real music (high bins quantize to 0 first as gain rises). Tracking
        // this in the quantize step over all 576 elements turned out to be
        // slower than this early-exit scan.
        var lastNonZeroIndex = -1
        for index in stride(from: count - 1, through: 0, by: -1) {
            if quantized[index] != 0 {
                lastNonZeroIndex = index
                break
            }
        }

        if lastNonZeroIndex < 0 {
            granuleInfo.bigValues = 0
            granuleInfo.tableSelect[0] = 0
            granuleInfo.tableSelect[1] = 0
            granuleInfo.tableSelect[2] = 0
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

        // count1 quads: try both count1 tables, pick the smaller. The fused
        // helper computes the shared 4-bit index once and indexes both length
        // tables in lockstep — the per-quad work was previously two full
        // `huffmanEncodeQuad` calls (with code-building we throw away).
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
            let costs = countQuadBitsAB(first: first, second: second, third: third, fourth: fourth)
            count1BitsTableA += costs.tableA
            count1BitsTableB += costs.tableB
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
        bumpCounter(.innerLoopCalls)

        let hint = granuleInfo.globalGain
        // bits(gain) is monotone non-increasing in gain (higher gain → coarser
        // quantization → fewer Huffman bits). The minimum-gain-that-fits is
        // therefore the boundary in a sorted array, which we locate with a
        // hint-anchored step-doubling bracket instead of a fresh [0, 255]
        // binary search. Typical convergence drops from ~9 probes to 3-5.
        // Initialised to the legacy fallback (255, 0): if no gain in [0, 255]
        // fits the budget the search exits without updating these and the
        // final write at gain = 255 is what the original behaviour produced.
        var bestGain = 255
        var bestBits = 0
        var bestGranuleInfo = granuleInfo
        var bestFound = false

        // Compute |x|^0.75 once for this spectral input — every probe and the
        // smoothing fallback reuses it via `quantizeFromCachedAbsPow075`,
        // removing ~80% of the Accelerate work per probe.
        prepareAbsPow075Cache(spectral: spectral)

        quantizedScratch.withUnsafeMutableBufferPointer { quantizedBuffer in
            // Local probe helper. Returns (bits, info) at `gain`. The
            // destination is the shared scratch buffer; the caller is
            // responsible for re-running the chosen gain into the real
            // destination at the end.
            @inline(__always)
            func probe(_ gain: Int) -> (bits: Int, info: GranuleInfo) {
                bumpCounter(.innerLoopProbes)
                var info = granuleInfo
                quantizeFromCachedAbsPow075(spectral: spectral, globalGain: gain, destination: quantizedBuffer)
                let bits = countBits(quantized: UnsafeBufferPointer(quantizedBuffer), granuleInfo: &info)
                return (bits, info)
            }

            // Anchor: warm-start at the hint when one is provided, else at the
            // GranuleInfo default (210). The starting point only affects probe
            // count, never the chosen gain — bits(gain) is monotone so any
            // starting probe leads to the same boundary.
            let startGain = hint > 0 && hint < 256 ? hint : 210
            let (startBits, startInfo) = probe(startGain)

            if startBits <= targetBits {
                bestGain = startGain
                bestBits = startBits
                bestGranuleInfo = startInfo
                bestFound = true
                if hint > 0, hint < 256, startGain == hint {
                    bumpCounter(.innerLoopHintHits)
                }

                // Walk down with step doublings to bracket the optimum from
                // above. The largest gain that does NOT fit defines the lower
                // exclusive bound; the smallest gain that DOES fit (so far)
                // defines the upper inclusive bound.
                var lastLowMiss = -1
                var lastHighFit = startGain
                var step = 1
                var probeGain = startGain - step
                while probeGain >= 0 {
                    let (bits, info) = probe(probeGain)
                    if bits <= targetBits {
                        bestGain = probeGain
                        bestBits = bits
                        bestGranuleInfo = info
                        lastHighFit = probeGain
                        step <<= 1
                        probeGain = lastHighFit - step
                    } else {
                        lastLowMiss = probeGain
                        break
                    }
                }

                // Binary search the (lastLowMiss, lastHighFit) bracket for the
                // smallest gain that still fits. Skip if walk-down already hit
                // 0 without missing — then bestGain == 0 is already optimal.
                var lo = lastLowMiss + 1
                var hi = lastHighFit - 1
                while lo <= hi {
                    let midGain = (lo + hi) / 2
                    let (bits, info) = probe(midGain)
                    if bits <= targetBits {
                        bestGain = midGain
                        bestBits = bits
                        bestGranuleInfo = info
                        hi = midGain - 1
                    } else {
                        lo = midGain + 1
                    }
                }
            } else {
                // Optimum is above startGain. Walk up by step doublings until
                // a gain fits or we leave the [0, 255] range.
                var lastLowMiss = startGain
                var lastHighFit = -1
                var step = 1
                var probeGain = startGain + step
                while probeGain <= 255 {
                    let (bits, info) = probe(probeGain)
                    if bits <= targetBits {
                        lastHighFit = probeGain
                        bestGain = probeGain
                        bestBits = bits
                        bestGranuleInfo = info
                        bestFound = true
                        break
                    } else {
                        lastLowMiss = probeGain
                        step <<= 1
                        probeGain = lastLowMiss + step
                    }
                }

                if bestFound {
                    var lo = lastLowMiss + 1
                    var hi = lastHighFit - 1
                    while lo <= hi {
                        let midGain = (lo + hi) / 2
                        let (bits, info) = probe(midGain)
                        if bits <= targetBits {
                            bestGain = midGain
                            bestBits = bits
                            bestGranuleInfo = info
                            hi = midGain - 1
                        } else {
                            lo = midGain + 1
                        }
                    }
                }
            }

            // Smoothing clamp: when the optimum dropped well below the hint,
            // raise it back toward the hint by at most `gainSmoothingMaxDelta`.
            // The smoothed gain is always ≥ bestGain (fewer bits used), so the
            // bit budget stays satisfied for free; we still re-count bits so
            // `part2_3_length` reflects the emitted Huffman bytes.
            if bestFound, hint > 0, bestGain < hint - Self.gainSmoothingMaxDelta {
                let smoothedGain = min(255, hint - Self.gainSmoothingMaxDelta)
                let (smoothedBits, smoothedInfo) = probe(smoothedGain)
                if smoothedBits <= targetBits {
                    bestGain = smoothedGain
                    bestBits = smoothedBits
                    bestGranuleInfo = smoothedInfo
                    bumpCounter(.innerLoopSmoothingFires)
                }
            }
        }

        // Produce bestGain's quantized values directly into the caller's buffer.
        quantizeFromCachedAbsPow075(spectral: spectral, globalGain: bestGain, destination: destination)
        bumpCounter(.innerLoopProbes)

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
            bumpCounter(.outerLoopShortPasses)
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

        bumpCounter(.outerLoopReservoirPasses)

        // If the base pass converged without bumping any scale factors, the reservoir
        // pass with a larger budget would only produce smaller quantized values and even
        // less distortion — running the full three-iteration distortion-control loop again
        // is guaranteed not to bump either, so a single innerLoop at the larger budget
        // suffices. That cuts the most expensive call path (countBits + Huffman scans
        // through the binary search) roughly in half for well-masked audio.
        if workingInfo.scaleFactors.allSatisfy({ $0 == 0 }) {
            var reservoirInfo = originalInfo
            reservoirInfo.scaleFactors = zeroScaleFactorsLong
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
                let factor0 = Self.subblockPreScale[max(0, min(7, subblockGain[0]))]
                let factor1 = Self.subblockPreScale[max(0, min(7, subblockGain[1]))]
                let factor2 = Self.subblockPreScale[max(0, min(7, subblockGain[2]))]
                let factors = (factor0, factor1, factor2)
                for index in 0 ..< 576 {
                    let window = windowBase[index]
                    let factor = window == 0 ? factors.0 : (window == 1 ? factors.1 : factors.2)
                    preScaled[index] = spectral[index] * factor
                }
            }

            granuleInfo.scaleFactors = zeroScaleFactorsLong
            granuleInfo.scaleFactorsShort = zeroScaleFactorsShort
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

        // Reset the persistent scratch instead of allocating a fresh `[Int]`.
        // CoW still kicks in when the array gets shared into `workingInfo.scaleFactors`
        // and then bumped, but the initial 22-Int heap allocation is gone.
        for index in 0 ..< distortionScaleFactorsScratch.count {
            distortionScaleFactorsScratch[index] = 0
        }
        var scaleFactors = distortionScaleFactorsScratch
        var resultInfo = granuleInfo
        var resultBits = 0

        bumpCounter(.distortionPasses)

        for iteration in 0 ..< maxIterations {
            bumpCounter(.distortionIterations)
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

        quantizedMagnitudeFloatScratch.withUnsafeMutableBufferPointer { magnitudes in
            decodedFloatScratch.withUnsafeMutableBufferPointer { decoded in
                let magnitudeBase = magnitudes.baseAddress!
                let decodedBase = decoded.baseAddress!
                for index in 0 ..< sampleCount {
                    magnitudeBase[index] = Float(abs(quantized[index]))
                }

                cbrtFloatScratch.withUnsafeMutableBufferPointer { roots in
                    vvcbrtf(roots.baseAddress!, magnitudeBase, &sampleCountInt32)
                    // decoded = magnitude * cbrt(magnitude) = magnitude^(4/3)
                    vDSP_vmul(roots.baseAddress!, 1, magnitudeBase, 1, decodedBase, 1, vDSP_Length(sampleCount))
                    for index in 0 ..< sampleCount where quantized[index] < 0 {
                        decodedBase[index] = -decodedBase[index]
                    }
                }
            }
        }

        let clampedGain = max(0, min(255, globalGain))
        let gainScale = Float(Self.decoderGainScale[clampedGain])
        let multiplierTable = Self.scaleFactorDecodeMultiplier[scaleFactorScale ? 1 : 0]

        for band in 0 ..< bandCount {
            let bandStart = scaleFactorBandBounds[band]
            let bandEnd = min(scaleFactorBandBounds[band + 1], sampleCount)
            guard bandStart < bandEnd else {
                continue
            }

            let scaleFactor = band < scaleFactors.count ? max(0, min(15, scaleFactors[band])) : 0
            var bandFactor = gainScale * Float(multiplierTable[scaleFactor])
            let bandLength = vDSP_Length(bandEnd - bandStart)

            decodedFloatScratch.withUnsafeMutableBufferPointer { decoded in
                diffFloatScratch.withUnsafeMutableBufferPointer { diff in
                    let decodedBand = decoded.baseAddress! + bandStart
                    let originalBand = originalSpectral.baseAddress! + bandStart
                    let diffBand = diff.baseAddress! + bandStart
                    vDSP_vsmul(decodedBand, 1, &bandFactor, decodedBand, 1, bandLength)
                    vDSP_vsub(decodedBand, 1, originalBand, 1, diffBand, 1, bandLength)
                    var bandDistortion: Float = 0
                    vDSP_svesq(diffBand, 1, &bandDistortion, bandLength)
                    distortion[band] = bandDistortion
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
        let multiplierTable = Self.scaleFactorEncodeMultiplier[scaleFactorScale ? 1 : 0]
        let count = min(spectral.count, destination.count)
        destination.baseAddress!.update(from: spectral.baseAddress!, count: count)

        for band in 0 ..< min(scaleFactors.count, scaleFactorBandBounds.count - 1) {
            let bandStart = scaleFactorBandBounds[band]
            let bandEnd = min(scaleFactorBandBounds[band + 1], count)
            guard bandStart < bandEnd else {
                continue
            }

            let scaleFactor = max(0, min(15, scaleFactors[band]))
            var factor = multiplierTable[scaleFactor]
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

    // ISO 11172-3 Table B.6 (`scalefac_compress`): each index maps to a
    // (slen1, slen2) bit-length pair for low (sfb 0–10) and high (sfb 11–20)
    // long-block scale factors.
    private static let scaleFactorBitLengthsLow: [Int] = [0, 0, 0, 0, 3, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4]
    private static let scaleFactorBitLengthsHigh: [Int] = [0, 1, 2, 3, 0, 1, 2, 3, 1, 2, 3, 1, 2, 3, 2, 3]

    private func scaleFactorBitLengthPair(for compress: Int) -> (Int, Int) {
        let index = max(0, min(compress, 15))
        return (Self.scaleFactorBitLengthsLow[index], Self.scaleFactorBitLengthsHigh[index])
    }

    // MARK: - Precomputed pow(2, …) tables

    // Replaces per-call `pow(2.0, …)` invocations on small integer-domain
    // exponents. The Float-domain entries are computed via `Float(pow(2.0, …))`
    // so the encoder stays bit-equivalent with the previous inline path.

    /// Encoder-side per-`global_gain` scale: `2^(-(g-210)/4)` for g ∈ [0, 255].
    /// Used by `quantizeInto` once per binary-search probe (~10-20× per granule).
    private static let encoderGainScale: [Float] = (0 ..< 256).map { gain in
        Float(pow(2.0, -Double(gain - 210) * 0.25))
    }

    /// Decoder-direction per-`global_gain` scale: `2^((g-210)/4)`. Double-precision
    /// mirror of `encoderGainScale`, used by `perBandDistortion`.
    private static let decoderGainScale: [Double] = (0 ..< 256).map { gain in
        pow(2.0, Double(gain - 210) * 0.25)
    }

    /// Encoder-direction `2^(multiplier * sf)` with `multiplier ∈ {0.5, 1.0}`
    /// and `sf ∈ [0, 15]`. First index is `scaleFactorScale ? 1 : 0`.
    private static let scaleFactorEncodeMultiplier: [[Float]] = [
        (0 ..< 16).map { sf in Float(pow(2.0, 0.5 * Double(sf))) },
        (0 ..< 16).map { sf in Float(pow(2.0, 1.0 * Double(sf))) },
    ]

    /// Decoder-direction `2^(-multiplier * sf)` with the same axes as
    /// `scaleFactorEncodeMultiplier`. Double-precision so it can be folded
    /// into the perBandDistortion gain factor without a precision loss.
    private static let scaleFactorDecodeMultiplier: [[Double]] = [
        (0 ..< 16).map { sf in pow(2.0, -0.5 * Double(sf)) },
        (0 ..< 16).map { sf in pow(2.0, -1.0 * Double(sf)) },
    ]

    /// Short-block `subblock_gain` pre-scale: `2^(2 * sg)` for sg ∈ [0, 7].
    private static let subblockPreScale: [Float] = (0 ..< 8).map { sg in
        Float(pow(2.0, Double(2 * sg)))
    }
}
