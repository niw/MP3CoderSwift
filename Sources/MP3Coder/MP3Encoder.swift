//
//  MP3Encoder.swift
//  MP3Coder
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import Foundation

/// MPEG-1 Layer 3 (MP3) Encoder
public final class MP3Encoder {
    // MARK: - Configuration

    // Calibrates the hybrid analysis coefficients to the decoder's synthesis scale.
    private let spectralScale: Float = 0.0008
    let sampleRate: Int
    let channels: Int
    let bitrate: Int // kbps
    let bitrateIndex: Int
    let sampleRateIndex: Int

    // MARK: - Internal components

    private let filterBanks: [PolyphaseFilterBank]
    private let mdctProcessors: [MDCTProcessor]
    private let psychoModel: PsychoacousticModel
    private let quantizer: Quantizer

    // MARK: - State

    private var inputBuffer: ContiguousArray<Float> = []
    private var inputReadPos: Int = 0 // samples already consumed into frames

    // Bit reservoir state
    private var reservoir: Int = 0 // bits in reservoir
    private let maxReservoir: Int = 511 * 8 // MPEG1: 9-bit main_data_begin

    // Frame counter
    private var frameCount: Int = 0

    // MARK: - Scratch buffers (preallocated in init, reused every frame)

    /// Deinterleaved channel samples. Layout: ch * samplesPerFrame + sampleIndex.
    private var channelSamplesScratch: ContiguousArray<Float>
    /// Spectral coefficients per (granule, channel). Layout: (gr * channels + ch) * 576 + k.
    private var granuleSpectralScratch: ContiguousArray<Float>
    /// Quantized values per (granule, channel). Layout: (gr * channels + ch) * 576 + k.
    private var granuleQuantizedScratch: [ContiguousArray<Int>]
    /// Per-granule side info, preallocated as [2 * channels].
    private var granuleInfosScratch: [[GranuleInfo]]
    /// Main-data bit writer, reused across frames.
    private let mainDataWriter: BitstreamWriter
    /// Transposed subband samples for MDCT input. Layout: sb * 18 + s.
    private var subbandScratch: ContiguousArray<Double>
    /// 32-slot output buffer for each polyphase filterbank call.
    private var filterBankOutputScratch: ContiguousArray<Double>

    // MARK: - Computed properties

    var samplesPerFrame: Int {
        1152
    }

    /// Frame size in bytes (without padding)
    var frameSizeBytes: Int {
        (144 * bitrate * 1000) / sampleRate
    }

    /// Bits available per granule (per channel)
    var bitsPerGranule: Int {
        let frameBytes = frameSizeBytes
        let headerBytes = 4
        let sideInfoBytes = channels == 1 ? 17 : 32
        let dataBytes = frameBytes - headerBytes - sideInfoBytes
        // Two granules per frame, each encoded independently per channel.
        return (dataBytes * 8) / (2 * channels)
    }

    // MARK: - Init

    public init(sampleRate: Int, channels: Int, bitrate: Int) throws {
        guard let srIdx = MP3Constants.sampleRates.firstIndex(of: sampleRate) else {
            throw MP3EncoderError.unsupportedSampleRate(sampleRate)
        }
        guard let brIdx = MP3Constants.bitrateTable.firstIndex(of: bitrate) else {
            throw MP3EncoderError.unsupportedBitrate(bitrate)
        }
        guard channels == 1 || channels == 2 else {
            throw MP3EncoderError.unsupportedChannelCount(channels)
        }

        self.sampleRate = sampleRate
        self.channels = channels
        self.bitrate = bitrate
        bitrateIndex = brIdx
        sampleRateIndex = srIdx

        filterBanks = (0 ..< channels).map { _ in PolyphaseFilterBank() }
        mdctProcessors = (0 ..< channels).map { _ in MDCTProcessor() }
        psychoModel = PsychoacousticModel(sampleRate: sampleRate)
        quantizer = Quantizer(sampleRate: sampleRate)

        let spf = 1152
        channelSamplesScratch = ContiguousArray(repeating: 0, count: channels * spf)
        granuleSpectralScratch = ContiguousArray(repeating: 0, count: 2 * channels * 576)
        granuleQuantizedScratch = (0 ..< (2 * channels)).map { _ in
            ContiguousArray(repeating: 0, count: 576)
        }
        granuleInfosScratch = (0 ..< 2).map { _ in
            Array(repeating: GranuleInfo(), count: channels)
        }
        let frameBytes = (144 * bitrate * 1000) / sampleRate
        mainDataWriter = BitstreamWriter(reserveBytes: frameBytes)
        subbandScratch = ContiguousArray(repeating: 0, count: 32 * 18)
        filterBankOutputScratch = ContiguousArray(repeating: 0, count: 32)
    }

    // MARK: - Public API

    /// Encode PCM samples (interleaved if stereo)
    /// Returns encoded MP3 data (may be empty if not enough samples yet)
    public func encode(pcm: [Float]) -> Data {
        inputBuffer.append(contentsOf: pcm)
        return drainFrames()
    }

    /// Flush remaining samples (pads with zeros if needed)
    public func flush() -> Data {
        let remaining = inputBuffer.count - inputReadPos
        guard remaining > 0 else {
            return Data()
        }

        let fpS = samplesPerFrame * channels
        let needed = fpS - (remaining % fpS)
        if needed > 0, needed < fpS {
            inputBuffer.append(contentsOf: repeatElement(Float(0), count: needed))
        }
        return drainFrames()
    }

    private func drainFrames() -> Data {
        let fpS = samplesPerFrame * channels
        var output = Data()
        while inputReadPos + fpS <= inputBuffer.count {
            let frame = encodeFrame(sampleBase: inputReadPos)
            output.append(frame)
            inputReadPos += fpS
        }
        // Bound in-memory buffer growth without O(N) shifts every frame.
        if inputReadPos >= 1 << 20 {
            inputBuffer.removeFirst(inputReadPos)
            inputReadPos = 0
        }
        return output
    }

    // MARK: - Frame encoding

    private func encodeFrame(sampleBase: Int) -> Data {
        let samplesPerFrameCount = samplesPerFrame
        // Deinterleave into channelSamplesScratch[channel * samplesPerFrame + sampleIndex]
        channelSamplesScratch.withUnsafeMutableBufferPointer { channelBuffer in
            inputBuffer.withUnsafeBufferPointer { inputRegion in
                let inputBase = inputRegion.baseAddress! + sampleBase
                if channels == 1 {
                    for sampleIndex in 0 ..< samplesPerFrameCount {
                        channelBuffer[sampleIndex] = inputBase[sampleIndex]
                    }
                } else {
                    // Stereo interleaved L,R,L,R…
                    let leftOutput = channelBuffer.baseAddress!
                    let rightOutput = channelBuffer.baseAddress! + samplesPerFrameCount
                    for sampleIndex in 0 ..< samplesPerFrameCount {
                        leftOutput[sampleIndex] = inputBase[2 * sampleIndex]
                        rightOutput[sampleIndex] = inputBase[2 * sampleIndex + 1]
                    }
                }
            }
        }

        for granule in 0 ..< 2 {
            let granuleSampleOffset = granule * 576

            for channel in 0 ..< channels {
                // Step 1 & 2: Polyphase filter bank. Write each call's 32 subband values
                // directly into subbandScratch[subband * 18 + slot] via a strided scratch.
                let channelSampleBase = channel * samplesPerFrameCount
                channelSamplesScratch.withUnsafeBufferPointer { channelBuffer in
                    filterBankOutputScratch.withUnsafeMutableBufferPointer { filterBankOutput in
                        subbandScratch.withUnsafeMutableBufferPointer { subbandBuffer in
                            let channelBase = channelBuffer.baseAddress!
                            for slot in 0 ..< 18 {
                                let sampleOffset = channelSampleBase + granuleSampleOffset + slot * 32
                                filterBanks[channel].analyze(
                                    input: channelBase,
                                    inputOffset: sampleOffset,
                                    inputLength: channelBuffer.count,
                                    output: filterBankOutput.baseAddress!
                                )
                                for subband in 0 ..< 32 {
                                    subbandBuffer[subband * 18 + slot] = filterBankOutput[subband]
                                }
                            }
                        }
                    }
                }

                // Step 3: MDCT -> granuleSpectralScratch slice (written as Float).
                let spectralBase = (granule * channels + channel) * 576
                subbandScratch.withUnsafeBufferPointer { subbandBuffer in
                    granuleSpectralScratch.withUnsafeMutableBufferPointer { destination in
                        mdctProcessors[channel].processGranule(
                            subbandSamples: subbandBuffer.baseAddress!,
                            output: destination.baseAddress!.advanced(by: spectralBase)
                        )
                        // Apply encoder-side spectral calibration in place.
                        let outputSlice = destination.baseAddress!.advanced(by: spectralBase)
                        for spectralIndex in 0 ..< 576 {
                            outputSlice[spectralIndex] *= spectralScale
                        }
                    }
                }

                // Step 5 & 6: Quantization (still on the current [Float] scratch; Phase 1 vectorizes this).
                var granuleInfo = GranuleInfo()
                granuleInfo.region0Count = 10
                granuleInfo.region1Count = 3

                let spectralArray: [Float] = granuleSpectralScratch.withUnsafeBufferPointer { source in
                    Array(UnsafeBufferPointer(start: source.baseAddress!.advanced(by: spectralBase), count: 576))
                }
                let quantized = quantizer.outerLoop(spectral: spectralArray, targetBits: bitsPerGranule, granuleInfo: &granuleInfo)
                granuleQuantizedScratch[granule * channels + channel].withUnsafeMutableBufferPointer { destination in
                    quantized.withUnsafeBufferPointer { source in
                        destination.baseAddress!.update(from: source.baseAddress!, count: 576)
                    }
                }

                let huffmanBits = quantizer.countBits(quantized: quantized, granuleInfo: &granuleInfo)
                granuleInfo.part2_3_length = granuleInfo.part2Length + huffmanBits
                granuleInfosScratch[granule][channel] = granuleInfo
            }
        }

        return writeBitstream()
    }

    // MARK: - Bitstream writing

    private func writeBitstream() -> Data {
        let nominalFrameSize = frameSizeBytes
        let paddingBit = false
        let frameSize = paddingBit ? nominalFrameSize + 1 : nominalFrameSize

        let headerBytes = 4
        let sideInfoBytes = channels == 1 ? 17 : 32
        let mainDataBytes = frameSize - headerBytes - sideInfoBytes

        // Write main data (scale factors + Huffman)
        mainDataWriter.reset()
        for granule in 0 ..< 2 {
            for channel in 0 ..< channels {
                let granuleInfo = granuleInfosScratch[granule][channel]
                writeScaleFactors(writer: mainDataWriter, granuleInfo: granuleInfo)
                granuleQuantizedScratch[granule * channels + channel].withUnsafeBufferPointer { quantizedBuffer in
                    writeHuffman(writer: mainDataWriter, quantized: quantizedBuffer, granuleInfo: granuleInfo)
                }
            }
        }
        mainDataWriter.byteAlign()
        var mainDataRaw = mainDataWriter.toData()

        // The quantizer is responsible for staying within this budget. Truncating
        // would corrupt the Huffman stream and make following frame boundaries fail.
        if mainDataRaw.count > mainDataBytes {
            assertionFailure("MP3 main data exceeded frame payload: \(mainDataRaw.count) > \(mainDataBytes)")
            mainDataRaw = mainDataRaw.prefix(mainDataBytes)
        } else {
            let paddingCount = mainDataBytes - mainDataRaw.count
            if paddingCount > 0 {
                mainDataRaw.append(Data(repeating: 0, count: paddingCount))
            }
        }

        // Header + side info are exactly `headerBytes + sideInfoBytes` once byte-aligned;
        // build them in their own bitstream writer and concatenate the main data
        // directly as bytes — no per-byte bit-level round trip.
        let headerWriter = BitstreamWriter(reserveBytes: headerBytes + sideInfoBytes)
        writeHeader(writer: headerWriter, paddingBit: paddingBit)
        writeSideInfo(writer: headerWriter, granuleInfos: granuleInfosScratch)
        var frame = headerWriter.toData()
        frame.append(mainDataRaw)

        frameCount += 1
        return frame
    }

    // MARK: - Header writing

    private func writeHeader(writer: BitstreamWriter, paddingBit: Bool) {
        // Sync word: 12 bits all 1
        writer.writeBits(0xFFF, count: 12)

        // ID: 1 = MPEG1
        writer.writeBit(1)

        // Layer: 01 = Layer III
        writer.writeBits(0b01, count: 2)

        // Protection bit: 1 = no CRC
        writer.writeBit(1)

        // Bitrate index
        writer.writeBits(bitrateIndex, count: 4)

        // Sampling frequency index
        writer.writeBits(sampleRateIndex, count: 2)

        // Padding bit
        writer.writeBit(paddingBit ? 1 : 0)

        // Private bit
        writer.writeBit(0)

        // Mode: 3 = mono, 0 = stereo
        let mode: Int = channels == 1 ? 3 : 0
        writer.writeBits(mode, count: 2)

        // Mode extension: 0
        writer.writeBits(0, count: 2)

        // Copyright: 0
        writer.writeBit(0)

        // Original: 1
        writer.writeBit(1)

        // Emphasis: 0
        writer.writeBits(0, count: 2)
    }

    // MARK: - Side info writing

    private func writeSideInfo(writer: BitstreamWriter, granuleInfos: [[GranuleInfo]]) {
        // main_data_begin (9 bits): 0 = no reservoir
        writer.writeBits(0, count: 9)

        // private_bits: 5 for mono, 3 for stereo
        let privateBits = channels == 1 ? 5 : 3
        writer.writeBits(0, count: privateBits)

        // scfsi[ch][4]: scale factor selection info (4 bits per channel)
        for _ in 0 ..< channels {
            writer.writeBits(0, count: 4) // scfsi bands 0-3 all 0
        }

        // Per granule, per channel
        for granule in 0 ..< 2 {
            for channel in 0 ..< channels {
                let granuleInfo = granuleInfos[granule][channel]

                // part2_3_length (12 bits)
                writer.writeBits(min(granuleInfo.part2_3_length, 4095), count: 12)

                // big_values (9 bits)
                writer.writeBits(min(granuleInfo.bigValues, 288), count: 9)

                // global_gain (8 bits)
                writer.writeBits(granuleInfo.globalGain & 0xFF, count: 8)

                // scalefac_compress (4 bits)
                writer.writeBits(granuleInfo.scaleFactorCompress & 0xF, count: 4)

                // window_switching_flag (1 bit): 0 = normal long blocks
                writer.writeBit(0)

                // table_select[0], table_select[1], table_select[2] (5 bits each)
                writer.writeBits(granuleInfo.tableSelect[0] & 0x1F, count: 5)
                writer.writeBits(granuleInfo.tableSelect[1] & 0x1F, count: 5)
                writer.writeBits(granuleInfo.tableSelect[2] & 0x1F, count: 5)

                // region0_count (4 bits)
                writer.writeBits(granuleInfo.region0Count & 0xF, count: 4)

                // region1_count (3 bits)
                writer.writeBits(granuleInfo.region1Count & 0x7, count: 3)

                // preflag (1 bit)
                writer.writeBit(granuleInfo.preflag ? 1 : 0)

                // scalefac_scale (1 bit)
                writer.writeBit(granuleInfo.scaleFactorScale ? 1 : 0)

                // count1table_select (1 bit)
                writer.writeBit(granuleInfo.count1TableSelect & 1)
            }
        }
    }

    // MARK: - Scale factor writing

    private func writeScaleFactors(writer: BitstreamWriter, granuleInfo: GranuleInfo) {
        let lowBitLengths = [0, 0, 0, 0, 3, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4]
        let highBitLengths = [0, 1, 2, 3, 0, 1, 2, 3, 1, 2, 3, 1, 2, 3, 2, 3]

        let compressIndex = min(granuleInfo.scaleFactorCompress, 15)
        let lowBitLength = lowBitLengths[compressIndex]
        let highBitLength = highBitLengths[compressIndex]

        // Write scale factors for bands 0-10 with lowBitLength bits each
        if lowBitLength > 0 {
            for band in 0 ..< 11 {
                let scaleFactor = band < granuleInfo.scaleFactors.count ? granuleInfo.scaleFactors[band] : 0
                writer.writeBits(scaleFactor & ((1 << lowBitLength) - 1), count: lowBitLength)
            }
        }

        // Write scale factors for bands 11-20 with highBitLength bits each
        if highBitLength > 0 {
            for band in 11 ..< 21 {
                let scaleFactor = band < granuleInfo.scaleFactors.count ? granuleInfo.scaleFactors[band] : 0
                writer.writeBits(scaleFactor & ((1 << highBitLength) - 1), count: highBitLength)
            }
        }
    }

    // MARK: - Huffman data writing

    private func writeHuffman(writer: BitstreamWriter, quantized: UnsafeBufferPointer<Int>, granuleInfo: GranuleInfo) {
        let bigValuesEnd = granuleInfo.bigValues * 2

        let scaleFactorBandBounds = MP3Constants.scaleFactorBandBoundaries(sampleRate: sampleRate)
        let region0SfbCount = min(granuleInfo.region0Count + 1, scaleFactorBandBounds.count - 1)
        let region0End = min(scaleFactorBandBounds[region0SfbCount], bigValuesEnd)

        let region1SfbCount = min(region0SfbCount + granuleInfo.region1Count + 1, scaleFactorBandBounds.count - 1)
        let region1End = min(scaleFactorBandBounds[region1SfbCount], bigValuesEnd)

        writePairs(writer: writer, values: quantized, start: 0, end: region0End, tableIndex: granuleInfo.tableSelect[0])
        writePairs(writer: writer, values: quantized, start: region0End, end: region1End, tableIndex: granuleInfo.tableSelect[1])
        writePairs(writer: writer, values: quantized, start: region1End, end: bigValuesEnd, tableIndex: granuleInfo.tableSelect[2])

        // Mirror Quantizer.countBits() so part2_3_length matches the emitted quads.
        var lastNonZeroIndex = -1
        for index in stride(from: quantized.count - 1, through: 0, by: -1) {
            if quantized[index] != 0 {
                lastNonZeroIndex = index
                break
            }
        }
        var count1Start = lastNonZeroIndex + 1
        count1Start = ((count1Start + 3) / 4) * 4
        count1Start = min(count1Start, quantized.count)

        var quadIndex = bigValuesEnd
        while quadIndex + 3 < count1Start {
            let first = quantized[quadIndex]
            let second = quantized[quadIndex + 1]
            let third = quantized[quadIndex + 2]
            let fourth = quantized[quadIndex + 3]

            if abs(first) > 1 || abs(second) > 1 || abs(third) > 1 || abs(fourth) > 1 {
                break
            }

            let (code, bits) = huffmanEncodeQuad(first: first, second: second, third: third, fourth: fourth, tableIndex: granuleInfo.count1TableSelect)
            writer.writeBits(code, count: bits)
            quadIndex += 4
        }
    }

    private func writePairs(writer: BitstreamWriter, values: UnsafeBufferPointer<Int>, start: Int, end: Int, tableIndex: Int) {
        var pairIndex = start
        let limit = min(end, values.count) - 1
        while pairIndex < limit {
            let firstValue = values[pairIndex]
            let secondValue = values[pairIndex + 1]
            let (code, bits) = huffmanEncodePair(firstValue: firstValue, secondValue: secondValue, tableIndex: tableIndex)
            writer.writeBits(code, count: bits)
            pairIndex += 2
        }
    }
}
