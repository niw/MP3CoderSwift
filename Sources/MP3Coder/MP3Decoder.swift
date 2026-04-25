//
//  MP3Decoder.swift
//  MP3Coder
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import Accelerate
import Foundation

public struct MP3DecodedAudio: Sendable {
    public var sampleRate: Int
    public var channels: Int
    public var samples: [Float]
}

public enum MP3DecoderError: Error, Equatable, Sendable {
    case invalidBitstream(String)
    case unsupportedFeature(String)
}

private struct DecodedFrameHeader {
    var sampleRate: Int
    var channels: Int
    var bitrate: Int
    var frameSize: Int
    var hasCRC: Bool
    var mode: Int
    var modeExtension: Int
}

private struct DecoderGranuleInfo {
    var part2_3_length = 0
    var bigValues = 0
    var globalGain = 210
    var scaleFactorCompress = 0
    var windowSwitchingFlag = false
    var blockType = 0
    var mixedBlockFlag = false
    var tableSelect = [0, 0, 0]
    var subblockGain = [0, 0, 0]
    var region0Count = 0
    var region1Count = 0
    var preflag = false
    var scaleFactorScale = false
    var count1TableSelect = 0
    var scaleFactors = Array(repeating: 0, count: 22)
    var scaleFactorsShort = Array(repeating: 0, count: 39)
}

public final class MP3Decoder {
    private var hybridDecoders: [HybridSynthesisDecoder] = []
    private var mainDataReservoir: ContiguousArray<UInt8> = []
    /// Per-channel PCM scratch (reused, interleaved into `output`).
    private var pcmByChannel: [ContiguousArray<Float>] = []
    /// Per-channel spectral scratch (576 doubles), reused across granules.
    private var spectralByChannel: [ContiguousArray<Double>] = []
    /// Quantized integer scratch (576), reused across granules.
    private var quantizedScratch: ContiguousArray<Int> = ContiguousArray(repeating: 0, count: 576)
    /// Contiguous main-data buffer for the current frame: `reservoirSuffix || currentFrameMainData`.
    private var mainDataBuffer: ContiguousArray<UInt8> = ContiguousArray(repeating: 0, count: 4096)

    // Requantize scratch (all length 576):
    private var rqSignedDouble: ContiguousArray<Double> = ContiguousArray(repeating: 0, count: 576)
    private var rqCbrt: ContiguousArray<Double> = ContiguousArray(repeating: 0, count: 576)
    private var rqAbs: ContiguousArray<Double> = ContiguousArray(repeating: 0, count: 576)
    private var rqScale: ContiguousArray<Double> = ContiguousArray(repeating: 0, count: 576)

    public init() {
    }

    public func decode(_ data: Data) throws -> MP3DecodedAudio {
        mainDataReservoir.removeAll(keepingCapacity: true)
        var output = [Float]()
        var streamSampleRate: Int?
        var streamChannels: Int?

        try data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            guard let basePointer = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            let bytes = UnsafeBufferPointer(start: basePointer, count: rawBuffer.count)
            var offset = skipID3v2(bytes)

            while offset + 4 <= bytes.count {
                guard let syncOffset = findNextFrame(in: bytes, startingAt: offset) else {
                    break
                }
                offset = syncOffset

                let header = try parseHeader(bytes: bytes, offset: offset)
                guard offset + header.frameSize <= bytes.count else {
                    throw MP3DecoderError.invalidBitstream("Truncated frame")
                }
                if header.hasCRC {
                    throw MP3DecoderError.unsupportedFeature("CRC-protected frames")
                }
                if header.mode == 1, (header.modeExtension & 0b01) != 0 {
                    throw MP3DecoderError.unsupportedFeature("intensity stereo")
                }

                if streamSampleRate == nil {
                    streamSampleRate = header.sampleRate
                    streamChannels = header.channels
                    hybridDecoders = (0 ..< header.channels).map { _ in HybridSynthesisDecoder() }
                    spectralByChannel = (0 ..< header.channels).map { _ in
                        ContiguousArray(repeating: 0, count: 576)
                    }
                    pcmByChannel = (0 ..< header.channels).map { _ in
                        ContiguousArray(repeating: 0, count: 576)
                    }
                    let estimatedFrames = max(bytes.count / max(header.frameSize, 1), 1)
                    output.reserveCapacity(estimatedFrames * 1152 * header.channels)
                } else if streamSampleRate != header.sampleRate || streamChannels != header.channels {
                    throw MP3DecoderError.unsupportedFeature("sample-rate or channel-mode changes")
                }

                try decodeFrame(bytes: bytes, offset: offset, header: header, output: &output)
                offset += header.frameSize
            }
        }

        guard let sampleRate = streamSampleRate, let channels = streamChannels else {
            throw MP3DecoderError.invalidBitstream("No MPEG-1 Layer III frames found")
        }

        return MP3DecodedAudio(sampleRate: sampleRate, channels: channels, samples: output)
    }

    private func decodeFrame(
        bytes: UnsafeBufferPointer<UInt8>,
        offset: Int,
        header: DecodedFrameHeader,
        output: inout [Float]
    ) throws {
        let sideInfoSize = header.channels == 1 ? 17 : 32
        let sideInfoStart = offset + 4
        let mainDataStart = sideInfoStart + sideInfoSize
        let mainDataSize = header.frameSize - 4 - sideInfoSize

        let sourceBase = bytes.baseAddress!
        let sideReader = BitstreamReader(bytes: sourceBase + sideInfoStart, count: sideInfoSize)

        let mainDataBegin = try sideReader.readBits(9)
        guard mainDataBegin <= mainDataReservoir.count else {
            throw MP3DecoderError.invalidBitstream("main_data_begin (\(mainDataBegin)) exceeds available bit reservoir (\(mainDataReservoir.count))")
        }

        try sideReader.skipBits(header.channels == 1 ? 5 : 3)
        var scaleFactorSelectionInfo = [Int]()
        scaleFactorSelectionInfo.reserveCapacity(header.channels)
        for _ in 0 ..< header.channels {
            try scaleFactorSelectionInfo.append(sideReader.readBits(4))
        }

        var granules = [[DecoderGranuleInfo]](
            repeating: [DecoderGranuleInfo](repeating: DecoderGranuleInfo(), count: header.channels),
            count: 2
        )

        for granule in 0 ..< 2 {
            for channel in 0 ..< header.channels {
                var granuleInfo = DecoderGranuleInfo()
                granuleInfo.part2_3_length = try sideReader.readBits(12)
                granuleInfo.bigValues = try sideReader.readBits(9)
                granuleInfo.globalGain = try sideReader.readBits(8)
                granuleInfo.scaleFactorCompress = try sideReader.readBits(4)
                let windowSwitchingFlag = try sideReader.readBit()
                granuleInfo.windowSwitchingFlag = windowSwitchingFlag != 0
                if granuleInfo.windowSwitchingFlag {
                    granuleInfo.blockType = try sideReader.readBits(2)
                    guard granuleInfo.blockType != 0 else {
                        throw MP3DecoderError.invalidBitstream("Invalid switched block type 0")
                    }
                    granuleInfo.mixedBlockFlag = try sideReader.readBit() != 0
                    granuleInfo.tableSelect[0] = try sideReader.readBits(5)
                    granuleInfo.tableSelect[1] = try sideReader.readBits(5)
                    granuleInfo.tableSelect[2] = 0
                    for window in 0 ..< 3 {
                        granuleInfo.subblockGain[window] = try sideReader.readBits(3)
                    }
                    if granuleInfo.blockType == 2 {
                        granuleInfo.region0Count = granuleInfo.mixedBlockFlag ? 7 : 8
                        granuleInfo.region1Count = 20 - granuleInfo.region0Count
                    } else {
                        granuleInfo.region0Count = 7
                        granuleInfo.region1Count = 13
                    }
                } else {
                    granuleInfo.blockType = 0
                    granuleInfo.tableSelect[0] = try sideReader.readBits(5)
                    granuleInfo.tableSelect[1] = try sideReader.readBits(5)
                    granuleInfo.tableSelect[2] = try sideReader.readBits(5)
                    granuleInfo.region0Count = try sideReader.readBits(4)
                    granuleInfo.region1Count = try sideReader.readBits(3)
                }
                granuleInfo.preflag = try sideReader.readBit() != 0
                granuleInfo.scaleFactorScale = try sideReader.readBit() != 0
                granuleInfo.count1TableSelect = try sideReader.readBit()
                granules[granule][channel] = granuleInfo
            }
        }

        // Assemble `mainDataBegin` reservoir bytes followed by this frame's main_data into a single
        // contiguous scratch buffer so the main BitstreamReader sees one buffer with no allocation.
        let totalMainSize = mainDataBegin + mainDataSize
        if mainDataBuffer.count < totalMainSize {
            mainDataBuffer = ContiguousArray(repeating: 0, count: max(totalMainSize, mainDataBuffer.count * 2))
        }
        mainDataBuffer.withUnsafeMutableBufferPointer { destinationBuffer in
            let destination = destinationBuffer.baseAddress!
            if mainDataBegin > 0 {
                mainDataReservoir.withUnsafeBufferPointer { reservoirBuffer in
                    let source = reservoirBuffer.baseAddress! + (mainDataReservoir.count - mainDataBegin)
                    destination.update(from: source, count: mainDataBegin)
                }
            }
            (destination + mainDataBegin).update(from: sourceBase + mainDataStart, count: mainDataSize)
        }

        try mainDataBuffer.withUnsafeBufferPointer { mainBuffer in
            let mainReader = BitstreamReader(bytes: mainBuffer.baseAddress!, count: totalMainSize)
            var previousScaleFactors = [[Int]?](repeating: nil, count: header.channels)
            var granuleInfoByChannel = [DecoderGranuleInfo](repeating: DecoderGranuleInfo(), count: header.channels)

            for granule in 0 ..< 2 {
                for channel in 0 ..< header.channels {
                    let partStart = mainReader.bitPosition
                    var granuleInfo = granules[granule][channel]
                    do {
                        try readScaleFactors(
                            reader: mainReader,
                            granuleInfo: &granuleInfo,
                            scaleFactorSelectionInfo: granule == 1 ? scaleFactorSelectionInfo[channel] : 0,
                            previousScaleFactors: previousScaleFactors[channel]
                        )
                        previousScaleFactors[channel] = granuleInfo.scaleFactors
                        try readHuffmanData(
                            reader: mainReader,
                            granuleInfo: granuleInfo,
                            sampleRate: header.sampleRate,
                            partEnd: partStart + granuleInfo.part2_3_length,
                            values: &quantizedScratch
                        )
                    } catch BitstreamReaderError.endOfData {
                        throw MP3DecoderError.invalidBitstream("Truncated main data at frame offset \(offset), granule \(granule), channel \(channel)")
                    } catch MP3DecoderError.invalidBitstream(let reason) {
                        throw MP3DecoderError.invalidBitstream("\(reason) at frame offset \(offset), granule \(granule), channel \(channel)")
                    }
                    quantizedScratch.withUnsafeBufferPointer { quantizedBuffer in
                        spectralByChannel[channel].withUnsafeMutableBufferPointer { spectralBuffer in
                            requantize(
                                quantized: quantizedBuffer.baseAddress!,
                                granuleInfo: granuleInfo,
                                sampleRate: header.sampleRate,
                                output: spectralBuffer.baseAddress!
                            )
                        }
                    }
                    granuleInfoByChannel[channel] = granuleInfo
                    if mainReader.bitPosition < partStart + granuleInfo.part2_3_length {
                        try mainReader.seek(bitPosition: partStart + granuleInfo.part2_3_length)
                    }
                }

                if header.mode == 1, (header.modeExtension & 0b10) != 0, header.channels == 2 {
                    applyMidSideStereo()
                }

                for channel in 0 ..< header.channels {
                    spectralByChannel[channel].withUnsafeBufferPointer { spectralBuffer in
                        pcmByChannel[channel].withUnsafeMutableBufferPointer { pcmBuffer in
                            hybridDecoders[channel].processGranule(
                                spectral: spectralBuffer.baseAddress!,
                                blockType: granuleInfoByChannel[channel].blockType,
                                mixedBlockFlag: granuleInfoByChannel[channel].mixedBlockFlag,
                                output: pcmBuffer.baseAddress!
                            )
                        }
                    }
                }

                appendInterleavedGranule(channels: header.channels, output: &output)
            }
        }

        // Update reservoir to keep the last 511 bytes of main_data available for the next frame.
        appendCurrentMainDataToReservoir(source: sourceBase + mainDataStart, count: mainDataSize)
    }

    /// Append 576 PCM samples per channel to `output`, interleaved (LRLR…).
    private func appendInterleavedGranule(channels: Int, output: inout [Float]) {
        if channels == 1 {
            pcmByChannel[0].withUnsafeBufferPointer { buffer in
                output.append(contentsOf: UnsafeBufferPointer(start: buffer.baseAddress!, count: 576))
            }
            return
        }
        let writeStart = output.count
        output.append(contentsOf: repeatElement(0, count: 576 * channels))
        output.withUnsafeMutableBufferPointer { outputBuffer in
            let destination = outputBuffer.baseAddress! + writeStart
            for channel in 0 ..< channels {
                pcmByChannel[channel].withUnsafeBufferPointer { sourceBuffer in
                    let source = sourceBuffer.baseAddress!
                    for slot in 0 ..< 576 {
                        destination[slot * channels + channel] = source[slot]
                    }
                }
            }
        }
    }

    private func appendCurrentMainDataToReservoir(source: UnsafePointer<UInt8>, count: Int) {
        if count >= 511 {
            // Drop everything older than the last 511 bytes of this frame.
            mainDataReservoir.removeAll(keepingCapacity: true)
            mainDataReservoir.append(contentsOf: UnsafeBufferPointer(start: source + (count - 511), count: 511))
            return
        }
        mainDataReservoir.append(contentsOf: UnsafeBufferPointer(start: source, count: count))
        if mainDataReservoir.count > 511 {
            mainDataReservoir.removeFirst(mainDataReservoir.count - 511)
        }
    }

    private func readScaleFactors(
        reader: BitstreamReader,
        granuleInfo: inout DecoderGranuleInfo,
        scaleFactorSelectionInfo: Int,
        previousScaleFactors: [Int]?
    ) throws {
        let (lowBitLength, highBitLength) = scaleFactorBitLengthPair(for: granuleInfo.scaleFactorCompress)
        if granuleInfo.blockType == 2 {
            if granuleInfo.mixedBlockFlag {
                if lowBitLength > 0 {
                    for band in 0 ..< 8 {
                        granuleInfo.scaleFactors[band] = try reader.readBits(lowBitLength)
                    }
                    for band in 3 ..< 6 {
                        for window in 0 ..< 3 {
                            granuleInfo.scaleFactorsShort[window * 13 + band] = try reader.readBits(lowBitLength)
                        }
                    }
                }
                if highBitLength > 0 {
                    for band in 6 ..< 12 {
                        for window in 0 ..< 3 {
                            granuleInfo.scaleFactorsShort[window * 13 + band] = try reader.readBits(highBitLength)
                        }
                    }
                }
            } else {
                if lowBitLength > 0 {
                    for band in 0 ..< 6 {
                        for window in 0 ..< 3 {
                            granuleInfo.scaleFactorsShort[window * 13 + band] = try reader.readBits(lowBitLength)
                        }
                    }
                }
                if highBitLength > 0 {
                    for band in 6 ..< 12 {
                        for window in 0 ..< 3 {
                            granuleInfo.scaleFactorsShort[window * 13 + band] = try reader.readBits(highBitLength)
                        }
                    }
                }
            }
            return
        }

        if let previousScaleFactors {
            for band in 0 ..< min(granuleInfo.scaleFactors.count, previousScaleFactors.count) {
                granuleInfo.scaleFactors[band] = previousScaleFactors[band]
            }
        }

        if lowBitLength > 0 {
            for band in 0 ..< 11 {
                if shouldReadScaleFactorBand(band, scaleFactorSelectionInfo: scaleFactorSelectionInfo) {
                    granuleInfo.scaleFactors[band] = try reader.readBits(lowBitLength)
                }
            }
        }
        if highBitLength > 0 {
            for band in 11 ..< 21 {
                if shouldReadScaleFactorBand(band, scaleFactorSelectionInfo: scaleFactorSelectionInfo) {
                    granuleInfo.scaleFactors[band] = try reader.readBits(highBitLength)
                }
            }
        }
    }

    private func readHuffmanData(
        reader: BitstreamReader,
        granuleInfo: DecoderGranuleInfo,
        sampleRate: Int,
        partEnd: Int,
        values: inout ContiguousArray<Int>
    ) throws {
        values.withUnsafeMutableBufferPointer { buffer in
            let pointer = buffer.baseAddress!
            for index in 0 ..< 576 {
                pointer[index] = 0
            }
        }
        let bigValuesEnd = min(granuleInfo.bigValues * 2, 576)
        let scaleFactorBandBounds = MP3Constants.scaleFactorBandBoundaries(sampleRate: sampleRate)
        let region0End: Int
        let region1End: Int
        if granuleInfo.blockType == 2 {
            let region0ScaleFactorBandCount = min(granuleInfo.region0Count + 1, scaleFactorBandBounds.count - 1)
            region0End = min(scaleFactorBandBounds[region0ScaleFactorBandCount], bigValuesEnd)
            region1End = bigValuesEnd
        } else {
            let region0ScaleFactorBandCount = min(granuleInfo.region0Count + 1, scaleFactorBandBounds.count - 1)
            region0End = min(scaleFactorBandBounds[region0ScaleFactorBandCount], bigValuesEnd)
            let region1ScaleFactorBandCount = min(region0ScaleFactorBandCount + granuleInfo.region1Count + 1, scaleFactorBandBounds.count - 1)
            region1End = min(scaleFactorBandBounds[region1ScaleFactorBandCount], bigValuesEnd)
        }

        try readPairs(reader: reader, values: &values, start: 0, end: region0End, tableIndex: granuleInfo.tableSelect[0], partEnd: partEnd)
        try readPairs(reader: reader, values: &values, start: region0End, end: region1End, tableIndex: granuleInfo.tableSelect[1], partEnd: partEnd)
        try readPairs(reader: reader, values: &values, start: region1End, end: bigValuesEnd, tableIndex: granuleInfo.tableSelect[2], partEnd: partEnd)

        var index = bigValuesEnd
        while reader.bitPosition < partEnd, index + 3 < 576 {
            let quadStart = reader.bitPosition
            let quad = try huffmanDecodeQuad(reader: reader, tableIndex: granuleInfo.count1TableSelect)
            if reader.bitPosition > partEnd {
                try reader.seek(bitPosition: quadStart)
                break
            }
            values[index] = quad.first
            values[index + 1] = quad.second
            values[index + 2] = quad.third
            values[index + 3] = quad.fourth
            index += 4
        }

        guard reader.bitPosition <= partEnd else {
            throw MP3DecoderError.invalidBitstream("Huffman data overran part2_3_length")
        }
    }

    private func readPairs(reader: BitstreamReader, values: inout ContiguousArray<Int>, start: Int, end: Int, tableIndex: Int, partEnd: Int) throws {
        var index = start
        while index + 1 < end, reader.bitPosition < partEnd {
            let pairStart = reader.bitPosition
            let pair = try huffmanDecodePair(reader: reader, tableIndex: tableIndex)
            if reader.bitPosition > partEnd {
                try reader.seek(bitPosition: pairStart)
                break
            }
            values[index] = pair.firstValue
            values[index + 1] = pair.secondValue
            index += 2
        }
    }

    /// Vectorized requantize. Writes 576 doubles into `output`.
    ///
    /// `output[i] = sign(quantized) * |quantized|^(4/3) * 2^((globalGain-210)/4 - scaleFactor(band(i)) * multiplier)`
    ///
    /// Identity used: `cbrt(quantized) * |quantized|` == `sign(quantized) * |quantized|^(4/3)` (cbrt preserves sign, and
    /// `|quantized|^(1/3) * |quantized| = |quantized|^(4/3)`). `cbrt` is vectorized via `vvcbrt`, absolute value via
    /// `vDSP_vabsD`, and the final scale-and-multiply is two `vDSP_vmulD`s.
    private func requantize(
        quantized: UnsafePointer<Int>,
        granuleInfo: DecoderGranuleInfo,
        sampleRate: Int,
        output: UnsafeMutablePointer<Double>
    ) {
        if granuleInfo.blockType == 2 {
            requantizeShort(quantized: quantized, granuleInfo: granuleInfo, sampleRate: sampleRate, output: output)
            return
        }

        let scaleFactorBandBounds = MP3Constants.scaleFactorBandBoundaries(sampleRate: sampleRate)
        let scaleFactorMultiplier = granuleInfo.scaleFactorScale ? 1.0 : 0.5
        let gainScale = pow(2.0, (Double(granuleInfo.globalGain) - 210.0) / 4.0)

        // Build per-element `rqScale[i] = gainScale * 2^(-scaleFactor(band(i)) * multiplier)`.
        rqScale.withUnsafeMutableBufferPointer { scaleBuffer in
            let scale = scaleBuffer.baseAddress!
            var band = 0
            var currentFactor = gainScale * pow(2.0, -Double(granuleInfo.scaleFactors[0]) * scaleFactorMultiplier)
            for spectralIndex in 0 ..< 576 {
                if band + 1 < scaleFactorBandBounds.count, spectralIndex >= scaleFactorBandBounds[band + 1] {
                    band += 1
                    let scaleFactor = band < granuleInfo.scaleFactors.count ? granuleInfo.scaleFactors[band] : 0
                    let preemphasis = granuleInfo.preflag && band < decoderPreemphasis.count ? decoderPreemphasis[band] : 0
                    currentFactor = gainScale * pow(2.0, -Double(scaleFactor + preemphasis) * scaleFactorMultiplier)
                }
                scale[spectralIndex] = currentFactor
            }
        }

        rqSignedDouble.withUnsafeMutableBufferPointer { signedDoubleBuffer in
            let signedDouble = signedDoubleBuffer.baseAddress!
            for spectralIndex in 0 ..< 576 {
                signedDouble[spectralIndex] = Double(quantized[spectralIndex])
            }
        }

        rqSignedDouble.withUnsafeBufferPointer { signedDoubleBuffer in
            rqAbs.withUnsafeMutableBufferPointer { absoluteBuffer in
                rqCbrt.withUnsafeMutableBufferPointer { cbrtBuffer in
                    rqScale.withUnsafeBufferPointer { scaleBuffer in
                        let signedDouble = signedDoubleBuffer.baseAddress!
                        let absoluteValues = absoluteBuffer.baseAddress!
                        let cbrtValues = cbrtBuffer.baseAddress!
                        let scale = scaleBuffer.baseAddress!

                        vDSP_vabsD(signedDouble, 1, absoluteValues, 1, 576)
                        var length: Int32 = 576
                        vvcbrt(cbrtValues, signedDouble, &length)
                        vDSP_vmulD(cbrtValues, 1, absoluteValues, 1, output, 1, 576)
                        vDSP_vmulD(output, 1, scale, 1, output, 1, 576)
                    }
                }
            }
        }
    }

    private func requantizeShort(
        quantized: UnsafePointer<Int>,
        granuleInfo: DecoderGranuleInfo,
        sampleRate: Int,
        output: UnsafeMutablePointer<Double>
    ) {
        for index in 0 ..< 576 {
            output[index] = 0
        }
        let longBandBounds = MP3Constants.scaleFactorBandBoundaries(sampleRate: sampleRate)
        let shortBandBounds = MP3Constants.scaleFactorBandBoundariesShort(sampleRate: sampleRate)
        let scaleFactorMultiplier = granuleInfo.scaleFactorScale ? 1.0 : 0.5
        let globalScale = pow(2.0, (Double(granuleInfo.globalGain) - 210.0) / 4.0)

        var sourceIndex = 0
        if granuleInfo.mixedBlockFlag {
            let longLimit = min(longBandBounds[8], 576)
            var band = 0
            for spectralIndex in 0 ..< longLimit {
                if band + 1 < longBandBounds.count, spectralIndex >= longBandBounds[band + 1] {
                    band += 1
                }
                let scaleFactor = band < granuleInfo.scaleFactors.count ? granuleInfo.scaleFactors[band] : 0
                let scale = globalScale * pow(2.0, -Double(scaleFactor) * scaleFactorMultiplier)
                output[spectralIndex] = requantizedValue(quantized[spectralIndex]) * scale
            }
            sourceIndex = longLimit
        }

        let firstShortBand = granuleInfo.mixedBlockFlag ? 3 : 0
        for band in firstShortBand ..< 12 {
            let width = shortBandBounds[band + 1] - shortBandBounds[band]
            for window in 0 ..< 3 {
                let shortScaleFactor = granuleInfo.scaleFactorsShort[window * 13 + band]
                let scale = globalScale
                    * pow(2.0, -Double(shortScaleFactor) * scaleFactorMultiplier)
                    * pow(2.0, -2.0 * Double(granuleInfo.subblockGain[window]))
                for line in 0 ..< width {
                    guard sourceIndex < 576 else {
                        return
                    }
                    let destinationIndex = 3 * shortBandBounds[band] + window * width + line
                    if destinationIndex < 576 {
                        output[destinationIndex] = requantizedValue(quantized[sourceIndex]) * scale
                    }
                    sourceIndex += 1
                }
            }
        }
    }

    private func parseHeader(bytes: UnsafeBufferPointer<UInt8>, offset: Int) throws -> DecodedFrameHeader {
        guard offset + 4 <= bytes.count else {
            throw MP3DecoderError.invalidBitstream("Truncated frame header")
        }

        let header = (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])

        guard (header >> 20) == 0xFFF else {
            throw MP3DecoderError.invalidBitstream("Missing sync word")
        }
        guard ((header >> 19) & 1) == 1 else {
            throw MP3DecoderError.unsupportedFeature("MPEG-2/2.5")
        }
        guard ((header >> 17) & 0b11) == 0b01 else {
            throw MP3DecoderError.unsupportedFeature("non-Layer III")
        }

        let hasCRC = ((header >> 16) & 1) == 0
        let bitrateIndex = Int((header >> 12) & 0xF)
        let sampleRateIndex = Int((header >> 10) & 0x3)
        let padding = Int((header >> 9) & 1)
        let mode = Int((header >> 6) & 0x3)
        let modeExtension = Int((header >> 4) & 0x3)

        guard bitrateIndex > 0 && bitrateIndex < MP3Constants.bitrateTable.count else {
            throw MP3DecoderError.invalidBitstream("Invalid bitrate index")
        }
        guard sampleRateIndex < MP3Constants.sampleRates.count else {
            throw MP3DecoderError.invalidBitstream("Invalid sample-rate index")
        }

        let bitrate = MP3Constants.bitrateTable[bitrateIndex]
        let sampleRate = MP3Constants.sampleRates[sampleRateIndex]
        let channels = mode == 3 ? 1 : 2
        let frameSize = (144 * bitrate * 1000) / sampleRate + padding

        return DecodedFrameHeader(
            sampleRate: sampleRate,
            channels: channels,
            bitrate: bitrate,
            frameSize: frameSize,
            hasCRC: hasCRC,
            mode: mode,
            modeExtension: modeExtension
        )
    }

    private func findNextFrame(in bytes: UnsafeBufferPointer<UInt8>, startingAt offset: Int) -> Int? {
        guard offset + 1 < bytes.count else {
            return nil
        }
        var index = offset
        while index + 1 < bytes.count {
            if bytes[index] == 0xFF, (bytes[index + 1] & 0xF0) == 0xF0 {
                return index
            }
            index += 1
        }
        return nil
    }

    private func skipID3v2(_ bytes: UnsafeBufferPointer<UInt8>) -> Int {
        guard bytes.count >= 10,
              bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33
        else {
            return 0
        }
        let size = (Int(bytes[6] & 0x7F) << 21)
            | (Int(bytes[7] & 0x7F) << 14)
            | (Int(bytes[8] & 0x7F) << 7)
            | Int(bytes[9] & 0x7F)
        return min(bytes.count, 10 + size)
    }

    private func applyMidSideStereo() {
        guard spectralByChannel.count >= 2 else {
            return
        }
        let scale = 1.0 / sqrt(2.0)
        let count = min(spectralByChannel[0].count, spectralByChannel[1].count)
        for index in 0 ..< count {
            let middle = spectralByChannel[0][index]
            let side = spectralByChannel[1][index]
            spectralByChannel[0][index] = (middle + side) * scale
            spectralByChannel[1][index] = (middle - side) * scale
        }
    }
}

private final class HybridSynthesisDecoder {
    /// Flat `overlap[subband * 18 + index]` — previous IMDCT's second half per subband.
    private var overlap: ContiguousArray<Double>
    /// Working copy of the spectral line vector (alias reduction mutates).
    private var spectralScratch: ContiguousArray<Double>
    /// IMDCT output scratch (36 doubles per subband call).
    private var imdctScratch: ContiguousArray<Double>
    /// Flat `subbandTime[slot * 32 + subband]` — 18 time slots × 32 subbands.
    private var subbandTime: ContiguousArray<Double>
    private let synthesis = SynthesisFilterBank()

    init() {
        overlap = ContiguousArray(repeating: 0, count: 32 * 18)
        spectralScratch = ContiguousArray(repeating: 0, count: 576)
        imdctScratch = ContiguousArray(repeating: 0, count: 36)
        subbandTime = ContiguousArray(repeating: 0, count: 18 * 32)
    }

    /// Write 576 PCM samples (18 time slots × 32 subbands) into `output`.
    func processGranule(spectral input: UnsafePointer<Double>, blockType: Int, mixedBlockFlag: Bool, output: UnsafeMutablePointer<Float>) {
        spectralScratch.withUnsafeMutableBufferPointer { spectralBuffer in
            imdctScratch.withUnsafeMutableBufferPointer { imdctBuffer in
                subbandTime.withUnsafeMutableBufferPointer { subbandTimeBuffer in
                    overlap.withUnsafeMutableBufferPointer { overlapBuffer in
                        let spectralBase = spectralBuffer.baseAddress!
                        let imdctBase = imdctBuffer.baseAddress!
                        let subbandTimeBase = subbandTimeBuffer.baseAddress!
                        let overlapBase = overlapBuffer.baseAddress!

                        // Copy input → spectral scratch, then apply alias reduction in place.
                        spectralBase.update(from: input, count: 576)
                        if blockType == 2 {
                            if mixedBlockFlag {
                                applyAliasReduction(spectral: spectralBase, subbandLimit: 2)
                            }
                        } else {
                            applyAliasReduction(spectral: spectralBase, subbandLimit: 32)
                        }

                        // Per subband: IMDCT, overlap-add, sign-flip, shuffle into subbandTime.
                        for subband in 0 ..< 32 {
                            let subbandBlockType = mixedBlockFlag && subband < 2 ? 0 : blockType
                            if subbandBlockType == 2 {
                                imdctShortInto(input: spectralBase.advanced(by: subband * 18), output: imdctBase)
                            } else {
                                imdctLongInto(
                                    input: spectralBase.advanced(by: subband * 18),
                                    blockType: subbandBlockType,
                                    output: imdctBase
                                )
                            }
                            let overlapForSubband = overlapBase.advanced(by: subband * 18)
                            let flipOdd = (subband & 1) == 1
                            for sampleIndex in 0 ..< 18 {
                                var sample = imdctBase[sampleIndex] + overlapForSubband[sampleIndex]
                                if flipOdd, (sampleIndex & 1) == 1 {
                                    sample = -sample
                                }
                                subbandTimeBase[sampleIndex * 32 + subband] = sample
                                overlapForSubband[sampleIndex] = imdctBase[18 + sampleIndex]
                            }
                        }

                        for slot in 0 ..< 18 {
                            synthesis.synthesize(
                                subband: subbandTimeBase.advanced(by: slot * 32),
                                output: output.advanced(by: slot * 32)
                            )
                        }
                    }
                }
            }
        }
    }

    private func applyAliasReduction(spectral: UnsafeMutablePointer<Double>, subbandLimit: Int) {
        aliasCosineSinesFlat.withUnsafeBufferPointer { cosineSinesBuffer in
            aliasCosineAntisFlat.withUnsafeBufferPointer { cosineAntisBuffer in
                let cosineSines = cosineSinesBuffer.baseAddress!
                let cosineAntis = cosineAntisBuffer.baseAddress!
                for subband in 1 ..< subbandLimit {
                    let leftBase = (subband - 1) * 18
                    let rightBase = subband * 18
                    for pairIndex in 0 ..< 8 {
                        let leftIndex = leftBase + 17 - pairIndex
                        let rightIndex = rightBase + pairIndex
                        let leftValue = spectral[leftIndex]
                        let rightValue = spectral[rightIndex]
                        spectral[leftIndex] = leftValue * cosineSines[pairIndex] - rightValue * cosineAntis[pairIndex]
                        spectral[rightIndex] = rightValue * cosineSines[pairIndex] + leftValue * cosineAntis[pairIndex]
                    }
                }
            }
        }
    }
}

private let decoderLongWindow: ContiguousArray<Double> = {
    var window = ContiguousArray<Double>(repeating: 0, count: 36)
    for sampleIndex in 0 ..< 36 {
        window[sampleIndex] = sin(Double.pi / 36.0 * (Double(sampleIndex) + 0.5))
    }
    return window
}()

private let decoderStartWindow: ContiguousArray<Double> = {
    var window = ContiguousArray<Double>(repeating: 0, count: 36)
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

private let decoderStopWindow: ContiguousArray<Double> = {
    var window = ContiguousArray<Double>(repeating: 0, count: 36)
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

private let decoderShortWindow: ContiguousArray<Double> = {
    var window = ContiguousArray<Double>(repeating: 0, count: 12)
    for sampleIndex in 0 ..< 12 {
        window[sampleIndex] = sin(Double.pi / 12.0 * (Double(sampleIndex) + 0.5))
    }
    return window
}()

/// Row-major 36×18 IMDCT cosine table: `imdctCosFlat[sampleIndex * 18 + spectralLine]`.
/// Padded with 2 zeros per row (stride 20) so SIMD4 reads at spectralLine=16 stay in-bounds and the
/// extra lanes contribute 0 to the dot product.
private let decoderIMDCTCosineFlat: ContiguousArray<Double> = {
    let stride = 20
    var flat = ContiguousArray<Double>(repeating: 0, count: 36 * stride)
    for sampleIndex in 0 ..< 36 {
        for spectralLine in 0 ..< 18 {
            flat[sampleIndex * stride + spectralLine] = cos(Double.pi / 18.0 * (Double(spectralLine) + 0.5) * (Double(sampleIndex) + 9.5))
        }
    }
    return flat
}()

private let decoderShortIMDCTCosineFlat: ContiguousArray<Double> = {
    var flat = ContiguousArray<Double>(repeating: 0, count: 12 * 6)
    for sampleIndex in 0 ..< 12 {
        for spectralLine in 0 ..< 6 {
            flat[sampleIndex * 6 + spectralLine] = cos(Double.pi / 6.0 * (Double(spectralLine) + 0.5) * (Double(sampleIndex) + 3.5))
        }
    }
    return flat
}()

private let aliasCosineSinesFlat: ContiguousArray<Double> = [
    0.857492925712, 0.881741997318, 0.949628649103, 0.983314592492,
    0.995517816065, 0.999160558175, 0.999899195243, 0.999993155067,
]

private let aliasCosineAntisFlat: ContiguousArray<Double> = [
    -0.5144957554270, -0.4717319685650, -0.3133774542040, -0.1819131996110,
    -0.0945741925262, -0.0409655828852, -0.0141985685725, -0.00369997467375,
]

private let decoderPreemphasis = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 3, 2, 0]

@inline(__always)
private func requantizedValue(_ quantized: Int) -> Double {
    guard quantized != 0 else {
        return 0.0
    }
    let magnitude = Double(abs(quantized))
    let value = magnitude * cbrt(magnitude)
    return quantized < 0 ? -value : value
}

/// Long/start/stop IMDCT: writes 36 doubles to `output` from 18 spectral coefficients. Uses SIMD4<Double>
/// across the 18 (+ 2 zero-padding) cosine entries per row.
@inline(__always)
private func imdctLongInto(input: UnsafePointer<Double>, blockType: Int, output: UnsafeMutablePointer<Double>) {
    let stride = 20
    decoderIMDCTCosineFlat.withUnsafeBufferPointer { cosineBuffer in
        decoderWindow(for: blockType).withUnsafeBufferPointer { windowBuffer in
            let cosineBase = UnsafeRawPointer(cosineBuffer.baseAddress!)
            let windowBase = windowBuffer.baseAddress!
            let inputRaw = UnsafeRawPointer(input)

            for sampleIndex in 0 ..< 36 {
                let rowRaw = cosineBase.advanced(by: sampleIndex * stride * 8)
                var accumulator = rowRaw.load(as: SIMD4<Double>.self)
                    * inputRaw.load(as: SIMD4<Double>.self)
                accumulator += rowRaw.load(fromByteOffset: 4 * 8, as: SIMD4<Double>.self)
                    * inputRaw.load(fromByteOffset: 4 * 8, as: SIMD4<Double>.self)
                accumulator += rowRaw.load(fromByteOffset: 8 * 8, as: SIMD4<Double>.self)
                    * inputRaw.load(fromByteOffset: 8 * 8, as: SIMD4<Double>.self)
                accumulator += rowRaw.load(fromByteOffset: 12 * 8, as: SIMD4<Double>.self)
                    * inputRaw.load(fromByteOffset: 12 * 8, as: SIMD4<Double>.self)
                // Tail of 2 real values (indices 16,17); rely on zero-padding at 18,19.
                let cosineTail = rowRaw.load(fromByteOffset: 16 * 8, as: SIMD4<Double>.self)
                // For input tail we also need SIMD4; input is only 18 elements long. The
                // caller provides 18 valid doubles; the 2 trailing slots read past the end
                // of the valid region but are zeroed out against the padded cos row.
                let inputTail = SIMD4<Double>(input[16], input[17], 0, 0)
                accumulator += cosineTail * inputTail
                output[sampleIndex] = (accumulator[0] + accumulator[1] + accumulator[2] + accumulator[3]) * windowBase[sampleIndex]
            }
        }
    }
}

private func imdctShortInto(input: UnsafePointer<Double>, output: UnsafeMutablePointer<Double>) {
    for sampleIndex in 0 ..< 36 {
        output[sampleIndex] = 0.0
    }

    decoderShortIMDCTCosineFlat.withUnsafeBufferPointer { cosineBuffer in
        decoderShortWindow.withUnsafeBufferPointer { windowBuffer in
            let cosineBase = cosineBuffer.baseAddress!
            let windowBase = windowBuffer.baseAddress!
            for window in 0 ..< 3 {
                let inputBase = input.advanced(by: window * 6)
                for sampleIndex in 0 ..< 12 {
                    let cosineRow = cosineBase.advanced(by: sampleIndex * 6)
                    var accumulator = 0.0
                    for spectralLine in 0 ..< 6 {
                        accumulator += inputBase[spectralLine] * cosineRow[spectralLine]
                    }
                    output[6 + window * 6 + sampleIndex] += accumulator * windowBase[sampleIndex]
                }
            }
        }
    }
}

private func decoderWindow(for blockType: Int) -> ContiguousArray<Double> {
    switch blockType {
    case 1:
        decoderStartWindow
    case 3:
        decoderStopWindow
    default:
        decoderLongWindow
    }
}

private func scaleFactorBitLengthPair(for compress: Int) -> (Int, Int) {
    let lowBitLengths = [0, 0, 0, 0, 3, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4]
    let highBitLengths = [0, 1, 2, 3, 0, 1, 2, 3, 1, 2, 3, 1, 2, 3, 2, 3]
    let index = max(0, min(compress, 15))
    return (lowBitLengths[index], highBitLengths[index])
}

private func shouldReadScaleFactorBand(_ band: Int, scaleFactorSelectionInfo: Int) -> Bool {
    switch band {
    case 0 ... 5:
        (scaleFactorSelectionInfo & 0b1000) == 0
    case 6 ... 10:
        (scaleFactorSelectionInfo & 0b0100) == 0
    case 11 ... 15:
        (scaleFactorSelectionInfo & 0b0010) == 0
    case 16 ... 20:
        (scaleFactorSelectionInfo & 0b0001) == 0
    default:
        true
    }
}
