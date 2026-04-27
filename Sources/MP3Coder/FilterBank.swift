//
//  FilterBank.swift
//  MP3Coder
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import Accelerate
import Foundation

/// ISO 11172-3 Annex B Table B.3 - 512-tap window prototype filter coefficients
private let prototypeFilter: [Double] = [
    0.000000000, -0.000015259, -0.000015259, -0.000015259,
    -0.000015259, -0.000015259, -0.000015259, -0.000030518,
    -0.000030518, -0.000030518, -0.000030518, -0.000045776,
    -0.000045776, -0.000061035, -0.000061035, -0.000076294,
    -0.000076294, -0.000091553, -0.000106812, -0.000106812,
    -0.000122070, -0.000137329, -0.000152588, -0.000167847,
    -0.000198364, -0.000213623, -0.000244141, -0.000259399,
    -0.000289917, -0.000320435, -0.000366211, -0.000396729,
    -0.000442505, -0.000473022, -0.000534058, -0.000579834,
    -0.000625610, -0.000686646, -0.000747681, -0.000808716,
    -0.000885010, -0.000961304, -0.001037598, -0.001113892,
    -0.001205444, -0.001296997, -0.001388550, -0.001480103,
    -0.001586914, -0.001693726, -0.001785278, -0.001907349,
    -0.002014160, -0.002120972, -0.002243042, -0.002349854,
    -0.002456665, -0.002578735, -0.002685547, -0.002792358,
    -0.002899170, -0.002990723, -0.003082275, -0.003173828,
    0.003250122, 0.003326416, 0.003387451, 0.003433228,
    0.003463745, 0.003479004, 0.003479004, 0.003463745,
    0.003417969, 0.003372192, 0.003280640, 0.003173828,
    0.003051758, 0.002883911, 0.002700806, 0.002487183,
    0.002227783, 0.001937866, 0.001617432, 0.001266479,
    0.000869751, 0.000442505, -0.000030518, -0.000549316,
    -0.001098633, -0.001693726, -0.002334595, -0.003005981,
    -0.003723145, -0.004486084, -0.005294800, -0.006118774,
    -0.007003784, -0.007919312, -0.008865356, -0.009841919,
    -0.010848999, -0.011886597, -0.012939453, -0.014022827,
    -0.015121460, -0.016235352, -0.017349243, -0.018463135,
    -0.019577026, -0.020690918, -0.021789551, -0.022857666,
    -0.023910522, -0.024932861, -0.025909424, -0.026840210,
    -0.027725220, -0.028533936, -0.029281616, -0.029937744,
    -0.030532837, -0.031005859, -0.031387329, -0.031661987,
    -0.031814575, -0.031845093, -0.031738281, -0.031478882,
    0.031082153, 0.030517578, 0.029785156, 0.028884888,
    0.027801514, 0.026535034, 0.025085449, 0.023422241,
    0.021575928, 0.019531250, 0.017257690, 0.014801025,
    0.012115479, 0.009231567, 0.006134033, 0.002822876,
    -0.000686646, -0.004394531, -0.008316040, -0.012420654,
    -0.016708374, -0.021179199, -0.025817871, -0.030609131,
    -0.035552979, -0.040634155, -0.045837402, -0.051132202,
    -0.056533813, -0.061996460, -0.067520142, -0.073059082,
    -0.078628540, -0.084182739, -0.089706421, -0.095169067,
    -0.100540161, -0.105819702, -0.110946655, -0.115921021,
    -0.120697021, -0.125259399, -0.129562378, -0.133590698,
    -0.137298584, -0.140670776, -0.143676758, -0.146255493,
    -0.148422241, -0.150115967, -0.151306152, -0.151962280,
    -0.152069092, -0.151596069, -0.150497437, -0.148773193,
    -0.146362305, -0.143264771, -0.139450073, -0.134887695,
    -0.129577637, -0.123474121, -0.116577148, -0.108856201,
    0.100311279, 0.090927124, 0.080688477, 0.069595337,
    0.057617188, 0.044784546, 0.031082153, 0.016510010,
    0.001068115, -0.015228271, -0.032379150, -0.050354004,
    -0.069168091, -0.088775635, -0.109161377, -0.130310059,
    -0.152206421, -0.174789429, -0.198059082, -0.221984863,
    -0.246505737, -0.271591187, -0.297210693, -0.323318481,
    -0.349868774, -0.376800537, -0.404083252, -0.431655884,
    -0.459472656, -0.487472534, -0.515609741, -0.543823242,
    -0.572036743, -0.600219727, -0.628295898, -0.656219482,
    -0.683914185, -0.711318970, -0.738372803, -0.765029907,
    -0.791213989, -0.816864014, -0.841949463, -0.866363525,
    -0.890090942, -0.913055420, -0.935195923, -0.956481934,
    -0.976852417, -0.996246338, -1.014617920, -1.031936646,
    -1.048156738, -1.063217163, -1.077117920, -1.089782715,
    -1.101211548, -1.111373901, -1.120223999, -1.127746582,
    -1.133926392, -1.138763428, -1.142211914, -1.144287109,
    1.144989014, 1.144287109, 1.142211914, 1.138763428,
    1.133926392, 1.127746582, 1.120223999, 1.111373901,
    1.101211548, 1.089782715, 1.077117920, 1.063217163,
    1.048156738, 1.031936646, 1.014617920, 0.996246338,
    0.976852417, 0.956481934, 0.935195923, 0.913055420,
    0.890090942, 0.866363525, 0.841949463, 0.816864014,
    0.791213989, 0.765029907, 0.738372803, 0.711318970,
    0.683914185, 0.656219482, 0.628295898, 0.600219727,
    0.572036743, 0.543823242, 0.515609741, 0.487472534,
    0.459472656, 0.431655884, 0.404083252, 0.376800537,
    0.349868774, 0.323318481, 0.297210693, 0.271591187,
    0.246505737, 0.221984863, 0.198059082, 0.174789429,
    0.152206421, 0.130310059, 0.109161377, 0.088775635,
    0.069168091, 0.050354004, 0.032379150, 0.015228271,
    -0.001068115, -0.016510010, -0.031082153, -0.044784546,
    -0.057617188, -0.069595337, -0.080688477, -0.090927124,
    0.100311279, 0.108856201, 0.116577148, 0.123474121,
    0.129577637, 0.134887695, 0.139450073, 0.143264771,
    0.146362305, 0.148773193, 0.150497437, 0.151596069,
    0.152069092, 0.151962280, 0.151306152, 0.150115967,
    0.148422241, 0.146255493, 0.143676758, 0.140670776,
    0.137298584, 0.133590698, 0.129562378, 0.125259399,
    0.120697021, 0.115921021, 0.110946655, 0.105819702,
    0.100540161, 0.095169067, 0.089706421, 0.084182739,
    0.078628540, 0.073059082, 0.067520142, 0.061996460,
    0.056533813, 0.051132202, 0.045837402, 0.040634155,
    0.035552979, 0.030609131, 0.025817871, 0.021179199,
    0.016708374, 0.012420654, 0.008316040, 0.004394531,
    0.000686646, -0.002822876, -0.006134033, -0.009231567,
    -0.012115479, -0.014801025, -0.017257690, -0.019531250,
    -0.021575928, -0.023422241, -0.025085449, -0.026535034,
    -0.027801514, -0.028884888, -0.029785156, -0.030517578,
    0.031082153, 0.031478882, 0.031738281, 0.031845093,
    0.031814575, 0.031661987, 0.031387329, 0.031005859,
    0.030532837, 0.029937744, 0.029281616, 0.028533936,
    0.027725220, 0.026840210, 0.025909424, 0.024932861,
    0.023910522, 0.022857666, 0.021789551, 0.020690918,
    0.019577026, 0.018463135, 0.017349243, 0.016235352,
    0.015121460, 0.014022827, 0.012939453, 0.011886597,
    0.010848999, 0.009841919, 0.008865356, 0.007919312,
    0.007003784, 0.006118774, 0.005294800, 0.004486084,
    0.003723145, 0.003005981, 0.002334595, 0.001693726,
    0.001098633, 0.000549316, 0.000030518, -0.000442505,
    -0.000869751, -0.001266479, -0.001617432, -0.001937866,
    -0.002227783, -0.002487183, -0.002700806, -0.002883911,
    -0.003051758, -0.003173828, -0.003280640, -0.003372192,
    -0.003417969, -0.003463745, -0.003479004, -0.003479004,
    -0.003463745, -0.003433228, -0.003387451, -0.003326416,
    0.003250122, 0.003173828, 0.003082275, 0.002990723,
    0.002899170, 0.002792358, 0.002685547, 0.002578735,
    0.002456665, 0.002349854, 0.002243042, 0.002120972,
    0.002014160, 0.001907349, 0.001785278, 0.001693726,
    0.001586914, 0.001480103, 0.001388550, 0.001296997,
    0.001205444, 0.001113892, 0.001037598, 0.000961304,
    0.000885010, 0.000808716, 0.000747681, 0.000686646,
    0.000625610, 0.000579834, 0.000534058, 0.000473022,
    0.000442505, 0.000396729, 0.000366211, 0.000320435,
    0.000289917, 0.000259399, 0.000244141, 0.000213623,
    0.000198364, 0.000167847, 0.000152588, 0.000137329,
    0.000122070, 0.000106812, 0.000106812, 0.000091553,
    0.000076294, 0.000076294, 0.000061035, 0.000061035,
    0.000045776, 0.000045776, 0.000030518, 0.000030518,
    0.000030518, 0.000030518, 0.000015259, 0.000015259,
    0.000015259, 0.000015259, 0.000015259, 0.000015259
]

/// Polyphase analysis filter bank per channel.
///
/// Maintains a 512-sample history in a mirrored 1024-slot ring buffer so that
/// a logical "shift by 32" each block is a single index bump rather than a
/// 480-element memmove. The mirror layer guarantees `history[head + k]` is
/// contiguous for k in 0..<512.
final class PolyphaseFilterBank {
    /// Mirrored history buffer, size = 2 * 512. Each sample is written at
    /// positions `position` and `position + 512` so that a contiguous view of the 512 most
    /// recent samples can be read starting at `head`.
    private var history: ContiguousArray<Double>
    /// Index in `history` of the newest sample (= logical index 0). Range 0..<512.
    private var head: Int = 0
    /// Scratch buffer for the 64 windowed values (reused across calls).
    private var windowedPartials: ContiguousArray<Double>

    init() {
        history = ContiguousArray(repeating: 0, count: 1024)
        windowedPartials = ContiguousArray(repeating: 0, count: 64)
    }

    /// Process one block of 32 input samples, produce 32 subband output values.
    /// - Parameters:
    ///   - input: input-sample buffer; samples past `input.count` read as 0.
    ///   - inputOffset: index of the first sample of this 32-sample block.
    ///   - output: destination for the 32 subband values.
    func analyze(
        input: UnsafeBufferPointer<Float>,
        inputOffset: Int,
        output: UnsafeMutableBufferPointer<Double>
    ) {
        // Advance the ring head (logical shift by 32) and stamp the new 32 samples
        // (reversed so the newest is at head) into both mirror slots.
        head = (head - 32) & 511
        let inputCount = input.count
        history.withUnsafeMutableBufferPointer { historyBuffer in
            let base = historyBuffer.baseAddress!
            if inputOffset >= 0, inputOffset + 32 <= inputCount {
                // Fast path: all 32 samples in bounds.
                for sampleOffset in 0 ..< 32 {
                    let sampleValue = Double(input[inputOffset + (31 - sampleOffset)])
                    let position = head + sampleOffset
                    base[position] = sampleValue
                    base[position + 512] = sampleValue
                }
            } else {
                for sampleOffset in 0 ..< 32 {
                    let sourceIndex = inputOffset + (31 - sampleOffset)
                    let sampleValue = (sourceIndex >= 0 && sourceIndex < inputCount) ? Double(input[sourceIndex]) : 0.0
                    let position = head + sampleOffset
                    base[position] = sampleValue
                    base[position + 512] = sampleValue
                }
            }
        }

        history.withUnsafeBufferPointer { historyBuffer in
            windowedPartials.withUnsafeMutableBufferPointer { partials in
                prototypeFilterFlat.withUnsafeBufferPointer { windowCoefficientsBuffer in
                    analysisMatrixFlat.withUnsafeBufferPointer { analysisMatrixBuffer in
                        let historyRaw = UnsafeRawPointer(historyBuffer.baseAddress!).advanced(by: head * 8)
                        let windowCoefficientsRaw = UnsafeRawPointer(windowCoefficientsBuffer.baseAddress!)
                        let partialsBase = partials.baseAddress!
                        let analysisMatrixBase = analysisMatrixBuffer.baseAddress!
                        let partialsReadRaw = UnsafeRawPointer(partialsBase)
                        let partialsWriteRaw = UnsafeMutableRawPointer(partialsBase)

                        // Windowing: partials[i] = sum_{tap=0..7} history[i + tap*64] * D[i + tap*64].
                        // Process 4 adjacent i values at a time using SIMD4<Double>.
                        var partialIndex = 0
                        while partialIndex < 64 {
                            var sum = historyRaw.load(fromByteOffset: partialIndex * 8, as: SIMD4<Double>.self)
                                * windowCoefficientsRaw.load(fromByteOffset: partialIndex * 8, as: SIMD4<Double>.self)
                            for tap in 1 ..< 8 {
                                let byteOffset = (partialIndex + tap * 64) * 8
                                sum += historyRaw.load(fromByteOffset: byteOffset, as: SIMD4<Double>.self)
                                    * windowCoefficientsRaw.load(fromByteOffset: byteOffset, as: SIMD4<Double>.self)
                            }
                            partialsWriteRaw.storeBytes(of: sum, toByteOffset: partialIndex * 8, as: SIMD4<Double>.self)
                            partialIndex += 4
                        }

                        // Analysis matrix: output[subband] = sum_tap M[subband][tap] * partials[tap] (32 × 64 · 64 × 1).
                        for subband in 0 ..< 32 {
                            let rowRaw = UnsafeRawPointer(analysisMatrixBase).advanced(by: subband * 64 * 8)
                            var accumulator = rowRaw.load(as: SIMD4<Double>.self)
                                * partialsReadRaw.load(as: SIMD4<Double>.self)
                            var tap = 4
                            while tap < 64 {
                                accumulator += rowRaw.load(fromByteOffset: tap * 8, as: SIMD4<Double>.self)
                                    * partialsReadRaw.load(fromByteOffset: tap * 8, as: SIMD4<Double>.self)
                                tap += 4
                            }
                            output[subband] = accumulator[0] + accumulator[1] + accumulator[2] + accumulator[3]
                        }
                    }
                }
            }
        }
    }
}

/// Flat copy of `D` for contiguous pointer access.
private let prototypeFilterFlat: ContiguousArray<Double> = ContiguousArray(prototypeFilter)

/// Flat row-major analysis matrix, 32 × 64 Doubles, for fast contiguous access.
/// Values are M[k][n] = cos(pi/64 * (2k+1) * (n-16)).
private let analysisMatrixFlat: ContiguousArray<Double> = {
    var flat = ContiguousArray<Double>(repeating: 0, count: 32 * 64)
    for subband in 0 ..< 32 {
        for tap in 0 ..< 64 {
            flat[subband * 64 + tap] = cos(Double.pi / 64.0 * Double(2 * subband + 1) * Double(tap - 16))
        }
    }
    return flat
}()

/// Row-major 64×32 synthesis cosine matrix:
/// `synthesisMatrix[row * 32 + subband] = cos(pi/64 * (2*subband+1) * (16+row))`.
/// Precomputed once at load time — the scalar decoder used to call `cos()` 2048× per synthesize
/// call, which was the #1 decoder hot spot.
private let synthesisMatrixFlat: ContiguousArray<Double> = {
    var flat = ContiguousArray<Double>(repeating: 0, count: 64 * 32)
    for row in 0 ..< 64 {
        for subband in 0 ..< 32 {
            flat[row * 32 + subband] = cos(Double.pi / 64.0 * Double(2 * subband + 1) * Double(16 + row))
        }
    }
    return flat
}()

/// Polyphase synthesis filter bank per channel.
///
/// The 1024-sample FIFO `v` is held in a mirrored 2048-slot ring buffer so the per-call
/// "slide by 64" is one head-bump instead of 960 memmoves. The synthesis cosine table is
/// precomputed.
final class SynthesisFilterBank {
    /// Mirrored ring buffer. Each sample is stored at `position` and `position + 1024`, so a 1024-wide
    /// contiguous read starting at `head` is always valid.
    private var synthesisFIFO: ContiguousArray<Double>
    /// Index in `synthesisFIFO` of the newest sample (logical index 0). Range 0..<1024.
    private var head: Int = 0
    /// Scratch for the 512-entry "U" array, reused across calls.
    private var shuffleScratch: ContiguousArray<Double>

    init() {
        synthesisFIFO = ContiguousArray(repeating: 0, count: 2048)
        shuffleScratch = ContiguousArray(repeating: 0, count: 512)
    }

    /// Compute 32 PCM samples from 32 subband values, writing into `output`.
    func synthesize(subband: UnsafeBufferPointer<Double>, output: UnsafeMutableBufferPointer<Float>) {
        head = (head - 64) & 1023

        synthesisFIFO.withUnsafeMutableBufferPointer { fifoBuffer in
            synthesisMatrixFlat.withUnsafeBufferPointer { matrixBuffer in
                let fifoBase = fifoBuffer.baseAddress!
                let matrixBase = matrixBuffer.baseAddress!
                let subbandRaw = UnsafeRawPointer(subband.baseAddress!)

                // fifo[head..head+63] (mirrored also at +1024): 64-vector produced from
                // 64×32 synthesis matrix · 32-vector, one row per matrixRow. SIMD4<Double>.
                for matrixRow in 0 ..< 64 {
                    let rowRaw = UnsafeRawPointer(matrixBase.advanced(by: matrixRow * 32))
                    var accumulator = rowRaw.load(as: SIMD4<Double>.self)
                        * subbandRaw.load(as: SIMD4<Double>.self)
                    for column in stride(from: 4, to: 32, by: 4) {
                        accumulator += rowRaw.load(fromByteOffset: column * 8, as: SIMD4<Double>.self)
                            * subbandRaw.load(fromByteOffset: column * 8, as: SIMD4<Double>.self)
                    }
                    let sum = accumulator[0] + accumulator[1] + accumulator[2] + accumulator[3]
                    let position = head + matrixRow
                    fifoBase[position] = sum
                    fifoBase[position + 1024] = sum
                }
            }

            shuffleScratch.withUnsafeMutableBufferPointer { shuffleBuffer in
                let shuffleBase = shuffleBuffer.baseAddress!
                let fifoView = fifoBuffer.baseAddress!.advanced(by: head)
                for block in 0 ..< 8 {
                    for indexInBlock in 0 ..< 32 {
                        shuffleBase[block * 64 + indexInBlock] = fifoView[block * 128 + indexInBlock]
                        shuffleBase[block * 64 + 32 + indexInBlock] = fifoView[block * 128 + 96 + indexInBlock]
                    }
                }

                prototypeFilterFlat.withUnsafeBufferPointer { windowBuffer in
                    let windowBase = windowBuffer.baseAddress!
                    // output[subband] = sum_{tap=0..15} shuffle[subband + tap*32] * D[subband + tap*32], clamped to [-1,1]
                    for outputIndex in 0 ..< 32 {
                        var sum = 0.0
                        for tap in 0 ..< 16 {
                            let offset = outputIndex + tap * 32
                            sum += shuffleBase[offset] * windowBase[offset]
                        }
                        output[outputIndex] = Float(max(-1.0, min(1.0, sum)))
                    }
                }
            }
        }
    }
}
