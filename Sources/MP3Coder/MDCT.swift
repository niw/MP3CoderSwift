//
//  MDCT.swift
//  MP3Coder
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import Foundation

/// MDCT window for long blocks: window[n] = sin(pi/36 * (n + 0.5)) for n=0..35
private let longWindow: [Double] = {
    var window = [Double](repeating: 0, count: 36)
    for sampleIndex in 0 ..< 36 {
        window[sampleIndex] = sin(Double.pi / 36.0 * (Double(sampleIndex) + 0.5))
    }
    return window
}()

/// Precomputed MDCT cosine table for 36-point long block
/// cosineTable[spectralLine][sample] = cos(pi/18 * (spectralLine + 0.5) * (sample + 9.5)) for spectralLine=0..17, sample=0..35
private let mdctCosineTable: [[Double]] = {
    var table = [[Double]](repeating: [Double](repeating: 0, count: 36), count: 18)
    for spectralLine in 0 ..< 18 {
        for sampleIndex in 0 ..< 36 {
            table[spectralLine][sampleIndex] = cos(Double.pi / 18.0 * (Double(spectralLine) + 0.5) * (Double(sampleIndex) + 9.5))
        }
    }
    return table
}()

/// Alias reduction coefficients for long blocks.
private let aliasReductionCosineSines: [Double] = [
    0.857492925712, 0.881741997318, 0.949628649103, 0.983314592492,
    0.995517816065, 0.999160558175, 0.999899195243, 0.999993155067,
]

private let aliasReductionCosineAntis: [Double] = [
    -0.5144957554270, -0.4717319685650, -0.3133774542040, -0.1819131996110,
    -0.0945741925262, -0.0409655828852, -0.0141985685725, -0.00369997467375,
]

/// MDCT processor that maintains overlap buffer for the overlap-add process
final class MDCTProcessor {
    /// Overlap from previous granule: `overlapBuffer[subband * 18 + index]` (already sign-flipped
    /// for odd subband/odd index).
    private var overlapBuffer: ContiguousArray<Double>
    /// Per-call scratch for the 36-sample windowed input.
    private var windowedScratch: ContiguousArray<Double>
    /// Flat Double accumulator for 576 spectral outputs (converted to Float on copy-out).
    private var spectralScratch: ContiguousArray<Double>

    init() {
        overlapBuffer = ContiguousArray(repeating: 0, count: 32 * 18)
        windowedScratch = ContiguousArray(repeating: 0, count: 36)
        spectralScratch = ContiguousArray(repeating: 0, count: 576)
    }

    /// Process one granule.
    /// - Parameters:
    ///   - subbandSamples: pointer to a 32×18 block indexed as `subband * 18 + sample`.
    ///   - output: pointer to 576 Float slots (subband * 18 + spectralLine) written with the spectral coefficients.
    func processGranule(
        subbandSamples: UnsafePointer<Double>,
        output: UnsafeMutablePointer<Float>
    ) {
        overlapBuffer.withUnsafeMutableBufferPointer { overlap in
            windowedScratch.withUnsafeMutableBufferPointer { windowed in
                spectralScratch.withUnsafeMutableBufferPointer { spectral in
                    longWindow.withUnsafeBufferPointer { windowBuffer in
                        mdctCosineFlat.withUnsafeBufferPointer { cosineBuffer in
                            let windowBase = windowBuffer.baseAddress!
                            let cosineBase = cosineBuffer.baseAddress!
                            let windowedReadRaw = UnsafeRawPointer(windowed.baseAddress!)
                            let cosineRaw = UnsafeRawPointer(cosineBase)

                            for subband in 0 ..< 32 {
                                let overlapBase = overlap.baseAddress!.advanced(by: subband * 18)
                                let inputBase = subbandSamples.advanced(by: subband * 18)
                                let flipOdd = (subband & 1) == 1

                                // Window the previous overlap into `windowed[0..17]`.
                                // Scalar — 18 is not a multiple of 4.
                                for index in 0 ..< 18 {
                                    windowed[index] = overlapBase[index] * windowBase[index]
                                }
                                // For odd subbands, flip sign on odd indices of the
                                // current samples; store transformed value back into
                                // overlapBase (becomes next granule's overlap) and also
                                // into `windowed[18..35]` after windowing.
                                if flipOdd {
                                    for index in 0 ..< 18 {
                                        let sampleValue = (index & 1) == 1 ? -inputBase[index] : inputBase[index]
                                        overlapBase[index] = sampleValue
                                        windowed[18 + index] = sampleValue * windowBase[18 + index]
                                    }
                                } else {
                                    for index in 0 ..< 18 {
                                        let sampleValue = inputBase[index]
                                        overlapBase[index] = sampleValue
                                        windowed[18 + index] = sampleValue * windowBase[18 + index]
                                    }
                                }

                                // MDCT: out[spectralLine] = sum_sample windowed[sample] * cos(spectralLine, sample).
                                // 36 / 4 = 9 SIMD4 lanes of Double per row.
                                let subbandOutput = spectral.baseAddress!.advanced(by: subband * 18)
                                for spectralLine in 0 ..< 18 {
                                    let rowRaw = cosineRaw.advanced(by: spectralLine * 36 * 8)
                                    var accumulator = rowRaw.load(as: SIMD4<Double>.self)
                                        * windowedReadRaw.load(as: SIMD4<Double>.self)
                                    for sampleIndex in stride(from: 4, to: 36, by: 4) {
                                        accumulator += rowRaw.load(fromByteOffset: sampleIndex * 8, as: SIMD4<Double>.self)
                                            * windowedReadRaw.load(fromByteOffset: sampleIndex * 8, as: SIMD4<Double>.self)
                                    }
                                    subbandOutput[spectralLine] = accumulator[0] + accumulator[1] + accumulator[2] + accumulator[3]
                                }
                            }

                            // Inverse of the decoder alias-reduction butterfly across subband edges.
                            aliasCosineSines.withUnsafeBufferPointer { cosineSinesBuffer in
                                aliasCosineAntis.withUnsafeBufferPointer { cosineAntisBuffer in
                                    let cosineSines = cosineSinesBuffer.baseAddress!
                                    let cosineAntis = cosineAntisBuffer.baseAddress!
                                    for subband in 1 ..< 32 {
                                        let leftBase = (subband - 1) * 18
                                        let rightBase = subband * 18
                                        for pairIndex in 0 ..< 8 {
                                            let leftIndex = leftBase + 17 - pairIndex
                                            let rightIndex = rightBase + pairIndex
                                            let leftValue = spectral[leftIndex]
                                            let rightValue = spectral[rightIndex]
                                            spectral[leftIndex] = leftValue * cosineSines[pairIndex] + rightValue * cosineAntis[pairIndex]
                                            spectral[rightIndex] = rightValue * cosineSines[pairIndex] - leftValue * cosineAntis[pairIndex]
                                        }
                                    }
                                }
                            }

                            // Copy-out to Float, 4 at a time.
                            let sourceRaw = UnsafeRawPointer(spectral.baseAddress!)
                            let destinationRaw = UnsafeMutableRawPointer(output)
                            for offset in stride(from: 0, to: 576, by: 4) {
                                let doubles = sourceRaw.load(fromByteOffset: offset * 8, as: SIMD4<Double>.self)
                                let floats = SIMD4<Float>(Float(doubles[0]), Float(doubles[1]), Float(doubles[2]), Float(doubles[3]))
                                destinationRaw.storeBytes(of: floats, toByteOffset: offset * 4, as: SIMD4<Float>.self)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Reset overlap buffers.
    func reset() {
        for index in 0 ..< overlapBuffer.count {
            overlapBuffer[index] = 0
        }
    }
}

/// Row-major 18×36 precomputed MDCT cosine table: `cosine[spectralLine * 36 + sampleIndex]`.
private let mdctCosineFlat: ContiguousArray<Double> = {
    var flat = ContiguousArray<Double>(repeating: 0, count: 18 * 36)
    for spectralLine in 0 ..< 18 {
        for sampleIndex in 0 ..< 36 {
            flat[spectralLine * 36 + sampleIndex] = mdctCosineTable[spectralLine][sampleIndex]
        }
    }
    return flat
}()

private let aliasCosineSines: ContiguousArray<Double> = ContiguousArray(aliasReductionCosineSines)
private let aliasCosineAntis: ContiguousArray<Double> = ContiguousArray(aliasReductionCosineAntis)
