//
//  MDCT.swift
//  MP3Coder
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import Foundation

/// MP3 MDCT block types (ISO/IEC 11172-3 §2.4.3.4.10.3).
enum MDCTBlockType: Int {
    case long = 0
    case start = 1
    case shortBlocks = 2
    case stop = 3
}

/// Encoder-side window for long blocks (block_type 0).
private let longWindow: [Double] = {
    var window = [Double](repeating: 0, count: 36)
    for sampleIndex in 0 ..< 36 {
        window[sampleIndex] = sin(Double.pi / 36.0 * (Double(sampleIndex) + 0.5))
    }
    return window
}()

/// Start window (block_type 1): long-window first half, ones, short-window second half, zeros.
/// Mirrors the decoder's `decoderStartWindow` so MDCT/IMDCT cancel correctly.
private let startWindow: [Double] = {
    var window = [Double](repeating: 0, count: 36)
    for sampleIndex in 0 ..< 36 {
        switch sampleIndex {
        case 0 ..< 18:
            window[sampleIndex] = sin(Double.pi / 36.0 * (Double(sampleIndex) + 0.5))
        case 18 ..< 24:
            window[sampleIndex] = 1.0
        case 24 ..< 30:
            window[sampleIndex] = sin(Double.pi / 12.0 * (Double(sampleIndex - 18) + 0.5))
        default:
            window[sampleIndex] = 0.0
        }
    }
    return window
}()

/// Stop window (block_type 3): mirror of start. Zeros, short first half, ones, long second half.
private let stopWindow: [Double] = {
    var window = [Double](repeating: 0, count: 36)
    for sampleIndex in 0 ..< 36 {
        switch sampleIndex {
        case 0 ..< 6:
            window[sampleIndex] = 0.0
        case 6 ..< 12:
            window[sampleIndex] = sin(Double.pi / 12.0 * (Double(sampleIndex - 6) + 0.5))
        case 12 ..< 18:
            window[sampleIndex] = 1.0
        default:
            window[sampleIndex] = sin(Double.pi / 36.0 * (Double(sampleIndex) + 0.5))
        }
    }
    return window
}()

/// 12-sample short window applied to each of the three short MDCTs.
private let shortWindow: [Double] = {
    var window = [Double](repeating: 0, count: 12)
    for sampleIndex in 0 ..< 12 {
        window[sampleIndex] = sin(Double.pi / 12.0 * (Double(sampleIndex) + 0.5))
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

/// Precomputed short MDCT cosine table: 6 spectral lines × 12 samples per row.
/// cos(pi/6 * (spectralLine+0.5) * (sample+3.5))
private let mdctShortCosineFlat: ContiguousArray<Double> = {
    var flat = ContiguousArray<Double>(repeating: 0, count: 6 * 12)
    for spectralLine in 0 ..< 6 {
        for sampleIndex in 0 ..< 12 {
            flat[spectralLine * 12 + sampleIndex] = cos(Double.pi / 6.0 * (Double(spectralLine) + 0.5) * (Double(sampleIndex) + 3.5))
        }
    }
    return flat
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

/// MDCT processor that maintains overlap buffer for the overlap-add process.
///
/// Supports all four MP3 block types: 0 (long), 1 (start), 2 (short), 3 (stop).
/// The encoder selects per-granule block type; transitions between long and short
/// require start/stop blocks so the IMDCT overlap-add still cancels at the seams.
final class MDCTProcessor {
    /// Overlap from previous granule: `overlapBuffer[subband * 18 + index]` (already sign-flipped
    /// for odd subband/odd index).
    private var overlapBuffer: ContiguousArray<Double>
    /// Per-call scratch for the 36-sample windowed input.
    private var windowedScratch: ContiguousArray<Double>
    /// Flat Double accumulator for 576 spectral outputs (converted to Float on copy-out).
    private var spectralScratch: ContiguousArray<Double>
    /// Reusable 36-sample input buffer for the short-block path (overlap || current).
    private var shortInputScratch: ContiguousArray<Double>
    /// Reusable 12-sample windowed slice for each short MDCT window.
    private var shortWindowedScratch: ContiguousArray<Double>

    init() {
        overlapBuffer = ContiguousArray(repeating: 0, count: 32 * 18)
        windowedScratch = ContiguousArray(repeating: 0, count: 36)
        spectralScratch = ContiguousArray(repeating: 0, count: 576)
        shortInputScratch = ContiguousArray(repeating: 0, count: 36)
        shortWindowedScratch = ContiguousArray(repeating: 0, count: 12)
    }

    /// Process one granule.
    /// - Parameters:
    ///   - subbandSamples: 32×18 block indexed as `subband * 18 + sample` (576 doubles).
    ///   - blockType: long/start/short/stop. Determines window shape, MDCT layout, and whether
    ///     alias reduction is applied (only for long-style blocks).
    ///   - output: 576 Float slots written with the spectral coefficients in the
    ///     subband-major encoder layout (subband * 18 + spectralLine). Caller is responsible for
    ///     reordering short-block lines into bitstream layout.
    func processGranule(
        subbandSamples: UnsafeBufferPointer<Double>,
        blockType: MDCTBlockType,
        output: UnsafeMutableBufferPointer<Float>
    ) {
        if blockType == .shortBlocks {
            processShortGranule(subbandSamples: subbandSamples, output: output)
            return
        }

        let windowArray: [Double] = switch blockType {
        case .long:
            longWindow
        case .start:
            startWindow
        case .stop:
            stopWindow
        case .shortBlocks:
            longWindow // unreachable
        }

        let subbandSamplesBase = subbandSamples.baseAddress!
        let outputBase = output.baseAddress!

        overlapBuffer.withUnsafeMutableBufferPointer { overlap in
            windowedScratch.withUnsafeMutableBufferPointer { windowed in
                spectralScratch.withUnsafeMutableBufferPointer { spectral in
                    windowArray.withUnsafeBufferPointer { windowBuffer in
                        mdctCosineFlat.withUnsafeBufferPointer { cosineBuffer in
                            let windowBase = windowBuffer.baseAddress!
                            let cosineBase = cosineBuffer.baseAddress!
                            let windowedReadRaw = UnsafeRawPointer(windowed.baseAddress!)
                            let cosineRaw = UnsafeRawPointer(cosineBase)

                            for subband in 0 ..< 32 {
                                let overlapBase = overlap.baseAddress!.advanced(by: subband * 18)
                                let inputBase = subbandSamplesBase.advanced(by: subband * 18)
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
                            // Long/start/stop all use the long-block IMDCT path in the decoder, which
                            // applies alias reduction across all 32 subband edges, so the encoder must
                            // mirror that for any non-short block type.
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
                            let destinationRaw = UnsafeMutableRawPointer(outputBase)
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

    /// Short-block (block_type 2) MDCT: per subband, three 12-sample MDCTs at offsets 6, 12, 18
    /// of the full 36-sample input window. Each short MDCT produces 6 spectral lines, written
    /// in window-major order so subband layout is `[w0_l0..5, w1_l0..5, w2_l0..5]`.
    /// No alias-reduction butterfly is applied — the decoder skips it for pure short blocks.
    private func processShortGranule(
        subbandSamples: UnsafeBufferPointer<Double>,
        output: UnsafeMutableBufferPointer<Float>
    ) {
        let subbandSamplesBase = subbandSamples.baseAddress!
        let outputBase = output.baseAddress!

        overlapBuffer.withUnsafeMutableBufferPointer { overlap in
            spectralScratch.withUnsafeMutableBufferPointer { spectral in
                shortInputScratch.withUnsafeMutableBufferPointer { subbandWindowed in
                    shortWindowedScratch.withUnsafeMutableBufferPointer { windowedShort in
                        shortWindow.withUnsafeBufferPointer { shortWindowBuffer in
                            mdctShortCosineFlat.withUnsafeBufferPointer { cosineBuffer in
                                let shortWindowBase = shortWindowBuffer.baseAddress!
                                let cosineBase = cosineBuffer.baseAddress!

                                for subband in 0 ..< 32 {
                                    let overlapBase = overlap.baseAddress!.advanced(by: subband * 18)
                                    let inputBase = subbandSamplesBase.advanced(by: subband * 18)
                                    let flipOdd = (subband & 1) == 1

                                    // Build the 36-sample input from previous overlap (first 18) and current
                                    // samples (next 18), applying the odd-subband sign flip on the current
                                    // half just like the long path. Update the overlap buffer for the next granule.
                                    for index in 0 ..< 18 {
                                        subbandWindowed[index] = overlapBase[index]
                                    }
                                    if flipOdd {
                                        for index in 0 ..< 18 {
                                            let sampleValue = (index & 1) == 1 ? -inputBase[index] : inputBase[index]
                                            overlapBase[index] = sampleValue
                                            subbandWindowed[18 + index] = sampleValue
                                        }
                                    } else {
                                        for index in 0 ..< 18 {
                                            let sampleValue = inputBase[index]
                                            overlapBase[index] = sampleValue
                                            subbandWindowed[18 + index] = sampleValue
                                        }
                                    }

                                    // Three short MDCTs: each takes a 12-sample windowed slice starting at
                                    // offsets 6, 12, 18 of the 36-sample input.
                                    let subbandOutput = spectral.baseAddress!.advanced(by: subband * 18)
                                    for windowIndex in 0 ..< 3 {
                                        let inputOffset = 6 + windowIndex * 6
                                        for n in 0 ..< 12 {
                                            windowedShort[n] = subbandWindowed[inputOffset + n] * shortWindowBase[n]
                                        }
                                        for spectralLine in 0 ..< 6 {
                                            var accumulator = 0.0
                                            let rowBase = cosineBase.advanced(by: spectralLine * 12)
                                            for n in 0 ..< 12 {
                                                accumulator += windowedShort[n] * rowBase[n]
                                            }
                                            subbandOutput[windowIndex * 6 + spectralLine] = accumulator
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Copy-out to Float, 4 at a time.
                let sourceRaw = UnsafeRawPointer(spectral.baseAddress!)
                let destinationRaw = UnsafeMutableRawPointer(outputBase)
                for offset in stride(from: 0, to: 576, by: 4) {
                    let doubles = sourceRaw.load(fromByteOffset: offset * 8, as: SIMD4<Double>.self)
                    let floats = SIMD4<Float>(Float(doubles[0]), Float(doubles[1]), Float(doubles[2]), Float(doubles[3]))
                    destinationRaw.storeBytes(of: floats, toByteOffset: offset * 4, as: SIMD4<Float>.self)
                }
            }
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
