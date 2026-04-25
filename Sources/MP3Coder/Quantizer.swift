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

    init(sampleRate: Int) {
        scaleFactorBandBounds = MP3Constants.scaleFactorBandBoundaries(sampleRate: sampleRate)
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

    /// Inner loop: binary-search the minimum global_gain that fits within `targetBits`.
    func innerLoop(spectral: UnsafeBufferPointer<Float>, targetBits: Int, granuleInfo: inout GranuleInfo) -> [Int] {
        var lowerGain = 0
        var upperGain = 255
        var bestGain = 255
        var bestGranuleInfo = granuleInfo

        quantizedScratch.withUnsafeMutableBufferPointer { quantizedBuffer in
            while lowerGain <= upperGain {
                let midGain = (lowerGain + upperGain) / 2
                var candidateInfo = granuleInfo
                quantizeInto(spectral: spectral.baseAddress!, globalGain: midGain, destination: quantizedBuffer.baseAddress!)
                let bits = countBits(quantized: UnsafeBufferPointer(quantizedBuffer), granuleInfo: &candidateInfo)

                if bits <= targetBits {
                    bestGain = midGain
                    bestGranuleInfo = candidateInfo
                    upperGain = midGain - 1
                } else {
                    lowerGain = midGain + 1
                }
            }

            // Recompute the quantized values at bestGain (quantizedBuffer may currently hold the
            // last-tried gain's output rather than bestGain's output).
            quantizeInto(spectral: spectral.baseAddress!, globalGain: bestGain, destination: quantizedBuffer.baseAddress!)
        }

        granuleInfo = bestGranuleInfo
        granuleInfo.globalGain = bestGain
        return Array(quantizedScratch)
    }

    /// Quantize against the normal target first, then spend reservoir bits only when
    /// measured distortion still exceeds the psychoacoustic thresholds.
    func outerLoop(
        spectral: [Float],
        thresholds: [Float],
        targetBits: Int,
        reservoirBits: Int = 0,
        granuleInfo: inout GranuleInfo
    ) -> [Int] {
        var baseInfo = granuleInfo
        let baseQuantized = quantizeWithDistortionControl(
            spectral: spectral,
            thresholds: thresholds,
            targetBits: targetBits,
            granuleInfo: &baseInfo
        )

        guard reservoirBits > 0 else {
            granuleInfo = baseInfo
            return baseQuantized
        }

        let pressure = maskingPressure(
            spectral: spectral,
            quantized: baseQuantized,
            granuleInfo: baseInfo,
            thresholds: thresholds
        )
        let extraBits = reservoirBitsToSpend(availableBits: reservoirBits, maskingPressure: pressure)
        guard extraBits > 0 else {
            granuleInfo = baseInfo
            return baseQuantized
        }

        var reservoirInfo = granuleInfo
        let reservoirQuantized = quantizeWithDistortionControl(
            spectral: spectral,
            thresholds: thresholds,
            targetBits: targetBits + extraBits,
            granuleInfo: &reservoirInfo
        )
        granuleInfo = reservoirInfo
        return reservoirQuantized
    }

    /// ISO/IEC 11172-3 distortion-control loop. Each iteration quantizes at the current
    /// scale factors, measures actual per-band distortion against the psychoacoustic
    /// masking threshold, and amplifies only the bands whose noise still exceeds it.
    /// The loop converges when every band is masked or hit its per-region cap.
    private func quantizeWithDistortionControl(
        spectral: [Float],
        thresholds: [Float],
        targetBits: Int,
        granuleInfo: inout GranuleInfo
    ) -> [Int] {
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
        var resultQuantized: [Int] = []
        var resultInfo = granuleInfo

        for iteration in 0 ..< maxIterations {
            var workingInfo = granuleInfo
            workingInfo.scaleFactors = scaleFactors
            workingInfo.scaleFactorScale = false
            workingInfo.scaleFactorCompress = chooseScaleFactorCompress(for: scaleFactors) ?? 0
            workingInfo.part2Length = scaleFactorBitCost(compress: workingInfo.scaleFactorCompress)

            let availableBits = max(0, targetBits - workingInfo.part2Length)

            let quantized: [Int]
            if scaleFactors.allSatisfy({ $0 == 0 }) {
                quantized = spectral.withUnsafeBufferPointer { spectralBuffer in
                    innerLoop(spectral: spectralBuffer, targetBits: availableBits, granuleInfo: &workingInfo)
                }
            } else {
                quantized = spectral.withUnsafeBufferPointer { spectralBuffer in
                    scaleFactorScratch.withUnsafeMutableBufferPointer { scaledBuffer in
                        applyScaleFactors(
                            spectral: spectralBuffer,
                            scaleFactors: scaleFactors,
                            scaleFactorScale: workingInfo.scaleFactorScale,
                            destination: scaledBuffer
                        )
                        return innerLoop(
                            spectral: UnsafeBufferPointer(start: scaledBuffer.baseAddress!, count: spectralBuffer.count),
                            targetBits: availableBits,
                            granuleInfo: &workingInfo
                        )
                    }
                }
            }
            resultQuantized = quantized
            resultInfo = workingInfo

            if iteration == maxIterations - 1 {
                break
            }

            let distortion = perBandDistortion(
                originalSpectral: spectral,
                quantized: quantized,
                globalGain: workingInfo.globalGain,
                scaleFactors: scaleFactors,
                scaleFactorScale: workingInfo.scaleFactorScale
            )

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

        granuleInfo = resultInfo
        return resultQuantized
    }

    private func maskingPressure(
        spectral: [Float],
        quantized: [Int],
        granuleInfo: GranuleInfo,
        thresholds: [Float]
    ) -> Float {
        let distortion = perBandDistortion(
            originalSpectral: spectral,
            quantized: quantized,
            globalGain: granuleInfo.globalGain,
            scaleFactors: granuleInfo.scaleFactors,
            scaleFactorScale: granuleInfo.scaleFactorScale
        )

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
        originalSpectral: [Float],
        quantized: [Int],
        globalGain: Int,
        scaleFactors: [Int],
        scaleFactorScale: Bool
    ) -> [Float] {
        let bandCount = scaleFactorBandBounds.count - 1
        var distortion = [Float](repeating: 0, count: bandCount)

        let sampleCount = min(576, originalSpectral.count, quantized.count)
        guard sampleCount > 0 else {
            return distortion
        }

        var sampleCountInt32 = Int32(sampleCount)
        originalSpectral.withUnsafeBufferPointer { originalBuffer in
            originalDoubleScratch.withUnsafeMutableBufferPointer { originalDouble in
                vDSP_vspdp(originalBuffer.baseAddress!, 1, originalDouble.baseAddress!, 1, vDSP_Length(sampleCount))
            }
        }

        quantizedMagnitudeDoubleScratch.withUnsafeMutableBufferPointer { magnitudes in
            decodedDoubleScratch.withUnsafeMutableBufferPointer { decoded in
                let magnitudeBase = magnitudes.baseAddress!
                let decodedBase = decoded.baseAddress!
                for index in 0 ..< sampleCount {
                    let value = quantized[index]
                    magnitudeBase[index] = Double(abs(value))
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

        return distortion
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
