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

    init(sampleRate: Int) {
        scaleFactorBandBounds = MP3Constants.scaleFactorBandBoundaries(sampleRate: sampleRate)
        absoluteBuffer = ContiguousArray(repeating: 0, count: 576)
        sqrtBuffer = ContiguousArray(repeating: 0, count: 576)
        scaledBuffer = ContiguousArray(repeating: 0, count: 576)
        quantizedInt32 = ContiguousArray(repeating: 0, count: 576)
        quantizedScratch = ContiguousArray(repeating: 0, count: 576)
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

    func countBits(quantized: [Int], granuleInfo: inout GranuleInfo) -> Int {
        quantized.withUnsafeBufferPointer { buffer in
            countBits(quantized: buffer, granuleInfo: &granuleInfo)
        }
    }

    /// Scale factors are currently left neutral by this simplified encoder; see notes below.
    func computeScaleFactors(spectral: [Float]) -> (scaleFactors: [Int], scaleFactorScale: Bool, scaleFactorCompress: Int) {
        let bandCount = scaleFactorBandBounds.count - 1
        return (Array(repeating: 0, count: bandCount), false, 0)
    }

    // MARK: - Rate control

    /// Inner loop: binary-search the minimum global_gain that fits within `targetBits`.
    func innerLoop(spectral: [Float], targetBits: Int, granuleInfo: inout GranuleInfo) -> [Int] {
        spectral.withUnsafeBufferPointer { spectralBuffer in
            innerLoop(spectral: spectralBuffer, targetBits: targetBits, granuleInfo: &granuleInfo)
        }
    }

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

    func outerLoop(spectral: [Float], targetBits: Int, granuleInfo: inout GranuleInfo) -> [Int] {
        let scaleFactorResult = computeScaleFactors(spectral: spectral)
        granuleInfo.scaleFactors = scaleFactorResult.scaleFactors
        granuleInfo.scaleFactorScale = scaleFactorResult.scaleFactorScale
        granuleInfo.scaleFactorCompress = scaleFactorResult.scaleFactorCompress
        granuleInfo.part2Length = scaleFactorBits(granuleInfo: granuleInfo)

        // The simplified encoder leaves all scale factors at 0, which means
        // `applyScaleFactors` is a no-op; skip the needless copy in that case.
        let availableBits = max(0, targetBits - granuleInfo.part2Length)
        if granuleInfo.scaleFactors.allSatisfy({ $0 == 0 }) {
            return innerLoop(spectral: spectral, targetBits: availableBits, granuleInfo: &granuleInfo)
        }
        let scaledSpectral = applyScaleFactors(
            spectral: spectral,
            scaleFactors: granuleInfo.scaleFactors,
            scaleFactorScale: granuleInfo.scaleFactorScale
        )
        return innerLoop(spectral: scaledSpectral, targetBits: availableBits, granuleInfo: &granuleInfo)
    }

    func scaleFactorBits(granuleInfo: GranuleInfo) -> Int {
        scaleFactorBitCost(compress: granuleInfo.scaleFactorCompress)
    }

    private func applyScaleFactors(spectral: [Float], scaleFactors: [Int], scaleFactorScale: Bool) -> [Float] {
        let multiplier = scaleFactorScale ? 1.0 : 0.5
        var scaled = spectral

        for band in 0 ..< min(scaleFactors.count, scaleFactorBandBounds.count - 1) {
            let bandStart = scaleFactorBandBounds[band]
            let bandEnd = min(scaleFactorBandBounds[band + 1], scaled.count)
            guard bandStart < bandEnd else {
                continue
            }

            let factor = Float(pow(2.0, multiplier * Double(scaleFactors[band])))
            if factor == 1 {
                continue
            }

            for spectralIndex in bandStart ..< bandEnd {
                scaled[spectralIndex] *= factor
            }
        }

        return scaled
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
