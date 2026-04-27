//
//  MP3CoderTests.swift
//  MP3CoderTests
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import Foundation
@testable
import MP3Coder
import Testing

@Test
func `Encoder should produce structurally valid MP3 from sine wave`() throws {
    let sampleRate = 44100
    let encoder = try MP3Encoder(sampleRate: sampleRate, channels: 1, bitrate: 128)

    let sampleCount = sampleRate
    var pcmSamples = [Float](repeating: 0, count: sampleCount)
    for sampleIndex in 0 ..< sampleCount {
        pcmSamples[sampleIndex] = Float(sin(2.0 * Double.pi * 440.0 * Double(sampleIndex) / Double(sampleRate))) * 0.5
    }

    var output = encoder.encode(pcm: pcmSamples)
    output.append(encoder.flush())

    #expect(output.count > 0, "Encoded output should be non-empty")

    let frames = try parseMP3Frames(output)
    #expect(!frames.isEmpty, "Bitstream should contain at least one parsed frame")
    for frame in frames {
        #expect(frame.version == .mpeg1, "Encoder must emit MPEG-1")
        #expect(frame.layer == .layer3, "Encoder must emit Layer III")
        #expect(frame.sampleRate == sampleRate)
        #expect(frame.bitrate == 128)
        #expect(frame.channelMode == .mono)
    }
    try assertMainDataReservoirIsConsistent(frames: frames)
}

@Test
func `Encoder should produce structurally valid MP3 from stereo sine wave`() throws {
    let sampleRate = 44100
    let channels = 2
    let encoder = try MP3Encoder(sampleRate: sampleRate, channels: channels, bitrate: 128)

    let stereoFrameCount = 22050
    var pcmSamples = [Float](repeating: 0, count: stereoFrameCount * channels)
    for frameIndex in 0 ..< stereoFrameCount {
        let sample = Float(sin(2.0 * Double.pi * 440.0 * Double(frameIndex) / Double(sampleRate))) * 0.5
        pcmSamples[frameIndex * 2] = sample
        pcmSamples[frameIndex * 2 + 1] = sample
    }

    var output = encoder.encode(pcm: pcmSamples)
    output.append(encoder.flush())

    #expect(output.count > 0, "Stereo encoded output should be non-empty")

    let frames = try parseMP3Frames(output)
    #expect(!frames.isEmpty, "Stereo bitstream should contain at least one parsed frame")
    for frame in frames {
        #expect(frame.channelMode != .mono, "Stereo encode must not emit mono frames")
        #expect(frame.sampleRate == sampleRate)
    }
    // Equivalent of "invalid new backstep": main_data_begin pointing past the
    // available bit reservoir, which means the encoder truncated or overran main data.
    try assertMainDataReservoirIsConsistent(frames: frames)
}

@Test
func `Encoder should use bit reservoir when frames have spare main data`() throws {
    let sampleRate = 44100
    let encoder = try MP3Encoder(sampleRate: sampleRate, channels: 1, bitrate: 128)

    let sampleCount = sampleRate
    var pcmSamples = [Float](repeating: 0, count: sampleCount)
    for sampleIndex in 0 ..< sampleCount {
        pcmSamples[sampleIndex] = Float(sin(2.0 * Double.pi * 440.0 * Double(sampleIndex) / Double(sampleRate))) * 0.5
    }

    var output = encoder.encode(pcm: pcmSamples)
    output.append(encoder.flush())

    let frames = try parseMP3Frames(output)
    #expect(frames.dropFirst().contains { $0.mainDataBegin > 0 }, "Encoder should carry main data through the reservoir")
    try assertMainDataReservoirIsConsistent(frames: frames)
}

@Test
func `Huffman count1 decoder should accept final short code at end of buffer`() throws {
    let (code, bits) = huffmanEncodeQuad(first: 0, second: 0, third: 0, fourth: 0, tableIndex: 0)
    #expect(bits < 10, "Regression setup should exercise padded count1 lookup")

    let writer = BitstreamWriter()
    writer.writeBits(code, count: bits)
    let encoded = writer.toData()

    try encoded.withUnsafeBytes { rawBuffer in
        let reader = BitstreamReader(bytes: rawBuffer.bindMemory(to: UInt8.self))
        let quad = try huffmanDecodeQuad(reader: reader, tableIndex: 0)
        #expect(quad.first == 0)
        #expect(quad.second == 0)
        #expect(quad.third == 0)
        #expect(quad.fourth == 0)
        #expect(reader.bitPosition == bits)
    }
}

@Test
func `Decoder should round-trip encoded sine wave`() throws {
    let sampleRate = 44100
    let encoder = try MP3Encoder(sampleRate: sampleRate, channels: 1, bitrate: 128)

    let sampleCount = sampleRate
    var pcmSamples = [Float](repeating: 0, count: sampleCount)
    for sampleIndex in 0 ..< sampleCount {
        pcmSamples[sampleIndex] = Float(sin(2.0 * Double.pi * 440.0 * Double(sampleIndex) / Double(sampleRate))) * 0.5
    }

    var encoded = encoder.encode(pcm: pcmSamples)
    encoded.append(encoder.flush())

    let decoded = try MP3Decoder().decode(encoded)
    #expect(decoded.sampleRate == sampleRate)
    #expect(decoded.channels == 1)

    let dominant = dominantFrequency(
        samples: decoded.samples,
        sampleRate: Double(decoded.sampleRate),
        start: min(2048, decoded.samples.count / 4),
        maxFrequency: 1000
    )
    let referenceWindow = Array(pcmSamples[2048 ..< (2048 + 4096)])
    let aligned = bestAlignedSegment(reference: referenceWindow, decoded: decoded.samples, searchLimit: 8192, step: 16)

    #expect(abs(dominant - 440.0) < 30.0, "Pure Swift decoder should preserve pitch")
    #expect(aligned != nil, "Pure Swift decoder should find a matching decoded segment")
    if let aligned {
        let referenceRootMeanSquare = rootMeanSquare(referenceWindow)
        let decodedRootMeanSquare = rootMeanSquare(aligned.segment)
        #expect(aligned.correlation > 0.9, "Pure Swift decoded sine should remain correlated with the source")
        #expect(decodedRootMeanSquare > referenceRootMeanSquare * 0.5 && decodedRootMeanSquare < referenceRootMeanSquare * 1.5, "Pure Swift decoded sine level should stay in range")
    }
}

@Test
func `Decoder should decode MP3 fixture matching WAV reference`() throws {
    let reference = try loadWAVFixture(named: "sine_440_mono")
    let data = try loadFixture(named: "sine_440_mono", withExtension: "mp3")
    let decoded = try MP3Decoder().decode(data)

    #expect(decoded.sampleRate == reference.sampleRate)
    #expect(decoded.channels == reference.channels)
    #expect(decoded.samples.count > reference.samples.count, "Decoded MP3 should include enough samples to align past encoder delay")

    let dominant = dominantFrequency(
        samples: decoded.samples,
        sampleRate: Double(decoded.sampleRate),
        start: min(2048, decoded.samples.count / 4),
        maxFrequency: 1000
    )
    #expect(abs(dominant - 440.0) < 10.0, "Decoded fixture sine should remain on pitch")

    let referenceWindow = Array(reference.samples[2048 ..< (2048 + 4096)])
    let aligned = bestAlignedSegment(reference: referenceWindow, decoded: decoded.samples, searchLimit: 12000, step: 16)

    #expect(aligned != nil, "Decoder should find the MP3 payload after encoder delay")
    if let aligned {
        let referenceRootMeanSquare = rootMeanSquare(referenceWindow)
        let decodedRootMeanSquare = rootMeanSquare(aligned.segment)
        #expect(aligned.correlation > 0.98, "Decoded MP3 should remain correlated with the WAV reference")
        #expect(decodedRootMeanSquare > referenceRootMeanSquare * 0.7 && decodedRootMeanSquare < referenceRootMeanSquare * 1.3, "Decoded MP3 level should stay close to the WAV reference")
    }
}

@Test
func `Encoder should encode WAV fixture so decoded output matches reference`() throws {
    let reference = try loadWAVFixture(named: "sine_440_mono")
    let encoder = try MP3Encoder(sampleRate: reference.sampleRate, channels: reference.channels, bitrate: 128)

    var encoded = encoder.encode(pcm: reference.samples)
    encoded.append(encoder.flush())
    #expect(encoded.count > 0, "Encoded WAV fixture should produce MP3 data")

    let frames = try parseMP3Frames(encoded)
    #expect(!frames.isEmpty, "Encoded WAV fixture should contain MP3 frames")
    for frame in frames {
        #expect(frame.version == .mpeg1)
        #expect(frame.layer == .layer3)
        #expect(frame.sampleRate == reference.sampleRate)
        #expect(frame.bitrate == 128)
        #expect(frame.channelMode == .mono)
    }
    try assertMainDataReservoirIsConsistent(frames: frames)

    let decoded = try MP3Decoder().decode(encoded)
    #expect(decoded.sampleRate == reference.sampleRate)
    #expect(decoded.channels == reference.channels)

    let referenceWindow = Array(reference.samples[2048 ..< (2048 + 4096)])
    let aligned = bestAlignedSegment(reference: referenceWindow, decoded: decoded.samples, searchLimit: 8192, step: 16)

    #expect(aligned != nil, "Encoded WAV fixture should decode to an alignable signal")
    if let aligned {
        let referenceRootMeanSquare = rootMeanSquare(referenceWindow)
        let decodedRootMeanSquare = rootMeanSquare(aligned.segment)
        #expect(aligned.correlation > 0.9, "Encoded WAV fixture should round-trip with the source waveform")
        #expect(decodedRootMeanSquare > referenceRootMeanSquare * 0.5 && decodedRootMeanSquare < referenceRootMeanSquare * 1.5, "Encoded WAV fixture level should stay in range")
    }
}

@Test
func `Decoder should decode music MP3 fixture with expected output shape`() throws {
    let reference = try loadWAVFixture(named: "music")
    let data = try loadFixture(named: "music", withExtension: "mp3")
    let decoded = try MP3Decoder().decode(data)

    #expect(decoded.sampleRate == reference.sampleRate)
    #expect(decoded.channels == reference.channels)
    #expect(decoded.samples.count >= reference.samples.count, "Decoded music should contain the full payload plus possible codec delay")
    assertFiniteSignal(decoded.samples, label: "Decoded music")

    let referenceRootMeanSquare = rootMeanSquare(reference.samples)
    let decodedRootMeanSquare = rootMeanSquare(decoded.samples)
    #expect(referenceRootMeanSquare > 0.05, "Music reference should not be silent")
    #expect(decodedRootMeanSquare > referenceRootMeanSquare * 0.4 && decodedRootMeanSquare < referenceRootMeanSquare * 2.0, "Decoded music level should stay in a realistic range")
}

@Test
func `Encoder should encode music WAV fixture segment so decoded output has expected shape`() throws {
    let reference = try loadWAVFixture(named: "music")
    let encoder = try MP3Encoder(sampleRate: reference.sampleRate, channels: reference.channels, bitrate: 128)
    let segmentSampleCount = min(reference.samples.count, reference.sampleRate * reference.channels * 2)
    let inputSegment = Array(reference.samples[0 ..< segmentSampleCount])

    var encoded = encoder.encode(pcm: inputSegment)
    encoded.append(encoder.flush())
    #expect(encoded.count > 0, "Encoded music segment should produce MP3 data")

    let frames = try parseMP3Frames(encoded)
    #expect(!frames.isEmpty, "Encoded music segment should contain MP3 frames")
    for frame in frames {
        #expect(frame.version == .mpeg1)
        #expect(frame.layer == .layer3)
        #expect(frame.sampleRate == reference.sampleRate)
        #expect(frame.bitrate == 128)
        #expect(frame.channelMode != .mono)
    }
    try assertMainDataReservoirIsConsistent(frames: frames)

    let decoded = try MP3Decoder().decode(encoded)
    #expect(decoded.sampleRate == reference.sampleRate)
    #expect(decoded.channels == reference.channels)
    #expect(decoded.samples.count >= inputSegment.count, "Decoded music segment should contain the encoded input plus possible padding")
    assertFiniteSignal(decoded.samples, label: "Decoded encoded music segment")

    let referenceRootMeanSquare = rootMeanSquare(inputSegment)
    let decodedRootMeanSquare = rootMeanSquare(decoded.samples)
    #expect(referenceRootMeanSquare > 0.05, "Music segment should not be silent")
    #expect(decodedRootMeanSquare > referenceRootMeanSquare * 0.3 && decodedRootMeanSquare < referenceRootMeanSquare * 2.5, "Encoded music segment level should stay in a realistic range")
}

@Test
func `Encoder should produce no output for empty input`() throws {
    let encoder = try MP3Encoder(sampleRate: 44100, channels: 1, bitrate: 128)
    let output = encoder.encode(pcm: [])
    #expect(output.count == 0, "Empty input should produce no output")
}

@Test
func `Encoder should reject unsupported sample rate`() {
    #expect(throws: MP3EncoderError.unsupportedSampleRate(22050)) {
        try MP3Encoder(sampleRate: 22050, channels: 1, bitrate: 128)
    }
}

@Test
func `Psychoacoustic model should tighten threshold for tonal vs noise at equal energy`() {
    // Build two spectral arrays with the same total energy in the same band:
    // one with all of it in a single bin (pure tone), one spread evenly
    // (white noise). The tonal version should produce a noticeably tighter
    // threshold for that band — that's the whole point of the SFM-driven SNR
    // boost.
    let model = PsychoacousticModel(sampleRate: 44100)
    let bandIndex = 8 // mid-band, well-defined boundaries
    let bounds = model.scaleFactorBandBounds
    let bandStart = bounds[bandIndex]
    let bandEnd = bounds[bandIndex + 1]
    let bandWidth = bandEnd - bandStart
    let bandEnergy: Float = 1.0 // arbitrary, only ratios matter

    var tonalSpectral = [Float](repeating: 0, count: 576)
    tonalSpectral[bandStart] = sqrt(bandEnergy)

    var noiseSpectral = [Float](repeating: 0, count: 576)
    let perLineMagnitude = sqrt(bandEnergy / Float(bandWidth))
    for index in bandStart ..< bandEnd {
        noiseSpectral[index] = perLineMagnitude
    }

    let tonalThresholds = tonalSpectral.withUnsafeBufferPointer { buffer in
        model.computeThresholds(spectral: buffer)
    }
    let noiseThresholds = noiseSpectral.withUnsafeBufferPointer { buffer in
        model.computeThresholds(spectral: buffer)
    }

    #expect(
        tonalThresholds[bandIndex] < noiseThresholds[bandIndex],
        "Tonal band should get a tighter (smaller) threshold than equal-energy noise"
    )
    // Boost should be substantial — at least 6 dB tighter (factor of 4 in energy
    // domain) even after the spreading function smears things slightly.
    let ratio = Double(noiseThresholds[bandIndex] / tonalThresholds[bandIndex])
    #expect(ratio > 4.0, "Tonal threshold should be at least ~6 dB tighter than noise; got ratio \(ratio)")
}

@Test
func `Encoder should select mid-side coding for correlated stereo`() throws {
    let sampleRate = 44100
    let channels = 2
    let encoder = try MP3Encoder(sampleRate: sampleRate, channels: channels, bitrate: 128)

    // L = R (perfect correlation): the side channel after the M/S transform is
    // identically zero, so the encoder should emit jointStereo + mode_extension
    // 0b10 (M/S on) for every frame.
    let stereoFrameCount = sampleRate
    var pcm = [Float](repeating: 0, count: stereoFrameCount * channels)
    for frameIndex in 0 ..< stereoFrameCount {
        let value = Float(sin(2.0 * Double.pi * 440.0 * Double(frameIndex) / Double(sampleRate))) * 0.5
        pcm[frameIndex * 2] = value
        pcm[frameIndex * 2 + 1] = value
    }

    var encoded = encoder.encode(pcm: pcm)
    encoded.append(encoder.flush())

    let frames = try parseMP3Frames(encoded)
    #expect(!frames.isEmpty)
    let allJointStereo = frames.allSatisfy { $0.channelMode == .jointStereo }
    let allMSExtension = frames.allSatisfy { $0.modeExtension & 0b10 != 0 }
    #expect(allJointStereo, "Identical L=R input should be encoded with jointStereo mode")
    #expect(allMSExtension, "M/S bit (0b10) should be set in mode_extension for correlated stereo")

    // Sanity: round-trip back to L=R audio.
    let decoded = try MP3Decoder().decode(encoded)
    #expect(decoded.channels == channels)
    let allFinite = decoded.samples.allSatisfy(\.isFinite)
    #expect(allFinite)
}

@Test
func `Encoder should stay in L slash R for uncorrelated stereo`() throws {
    let sampleRate = 44100
    let channels = 2
    let encoder = try MP3Encoder(sampleRate: sampleRate, channels: channels, bitrate: 128)

    // L = sine(440 Hz), R = sine(523 Hz, slightly out of phase): the two
    // channels are nearly orthogonal, so M and S have similar energy and the
    // encoder should fall back to plain stereo (mode 0, mode_extension 0).
    let stereoFrameCount = sampleRate
    var pcm = [Float](repeating: 0, count: stereoFrameCount * channels)
    for frameIndex in 0 ..< stereoFrameCount {
        let leftValue = Float(sin(2.0 * Double.pi * 440.0 * Double(frameIndex) / Double(sampleRate))) * 0.5
        let rightValue = Float(cos(2.0 * Double.pi * 523.0 * Double(frameIndex) / Double(sampleRate))) * 0.5
        pcm[frameIndex * 2] = leftValue
        pcm[frameIndex * 2 + 1] = rightValue
    }

    var encoded = encoder.encode(pcm: pcm)
    encoded.append(encoder.flush())

    let frames = try parseMP3Frames(encoded)
    #expect(!frames.isEmpty)
    let anyPlainStereo = frames.contains { $0.channelMode == .stereo }
    #expect(
        anyPlainStereo,
        "Uncorrelated L/R should produce at least some plain-stereo frames (mode 0)"
    )
}

@Test
func `Encoder should round-trip mid-side stereo`() throws {
    let sampleRate = 44100
    let channels = 2
    let encoder = try MP3Encoder(sampleRate: sampleRate, channels: channels, bitrate: 128)

    // L and R highly correlated but not identical (L slightly louder, R slightly
    // delayed): exercises the full M/S forward+inverse path through the codec.
    let stereoFrameCount = sampleRate
    var pcm = [Float](repeating: 0, count: stereoFrameCount * channels)
    for frameIndex in 0 ..< stereoFrameCount {
        let leftValue = Float(sin(2.0 * Double.pi * 440.0 * Double(frameIndex) / Double(sampleRate))) * 0.5
        let rightValue = Float(sin(2.0 * Double.pi * 440.0 * Double(frameIndex - 1) / Double(sampleRate))) * 0.45
        pcm[frameIndex * 2] = leftValue
        pcm[frameIndex * 2 + 1] = rightValue
    }

    var encoded = encoder.encode(pcm: pcm)
    encoded.append(encoder.flush())

    let decoded = try MP3Decoder().decode(encoded)
    #expect(decoded.channels == channels)
    #expect(decoded.samples.count >= pcm.count - 4096)

    // Compare each channel's RMS against the source RMS — the round-trip
    // shouldn't drift by more than the encoder's normal compression headroom.
    var leftReferenceEnergy = 0.0
    var rightReferenceEnergy = 0.0
    let referenceCount = min(pcm.count / 2, decoded.samples.count / 2)
    for index in 0 ..< referenceCount {
        let leftValue = Double(pcm[index * 2])
        let rightValue = Double(pcm[index * 2 + 1])
        leftReferenceEnergy += leftValue * leftValue
        rightReferenceEnergy += rightValue * rightValue
    }
    var leftDecodedEnergy = 0.0
    var rightDecodedEnergy = 0.0
    for index in 0 ..< referenceCount {
        let leftValue = Double(decoded.samples[index * 2])
        let rightValue = Double(decoded.samples[index * 2 + 1])
        leftDecodedEnergy += leftValue * leftValue
        rightDecodedEnergy += rightValue * rightValue
    }
    let leftRatio = leftDecodedEnergy / max(leftReferenceEnergy, 1e-12)
    let rightRatio = rightDecodedEnergy / max(rightReferenceEnergy, 1e-12)
    #expect(leftRatio > 0.25 && leftRatio < 4.0, "Left channel energy should round-trip in range, got \(leftRatio)")
    #expect(rightRatio > 0.25 && rightRatio < 4.0, "Right channel energy should round-trip in range, got \(rightRatio)")
}

@Test
func `Encoder should switch to short blocks for transient`() throws {
    let sampleRate = 44100
    let encoder = try MP3Encoder(sampleRate: sampleRate, channels: 1, bitrate: 128)

    // 0.6 s of silence, sharp 1.0 amplitude impulse burst (40 ms), 0.6 s of silence.
    // The impulse plus a bit of decay is what drives the transient detector
    // and forces a short-block group.
    let prePadSamples = sampleRate * 6 / 10
    let burstSamples = sampleRate * 4 / 100
    let postPadSamples = sampleRate * 6 / 10
    var pcm = [Float](repeating: 0, count: prePadSamples + burstSamples + postPadSamples)
    for sampleIndex in 0 ..< burstSamples {
        let phase = 2.0 * Double.pi * 4000.0 * Double(sampleIndex) / Double(sampleRate)
        let envelope = exp(-Double(sampleIndex) / Double(burstSamples / 4))
        pcm[prePadSamples + sampleIndex] = Float(sin(phase) * envelope)
    }

    var encoded = encoder.encode(pcm: pcm)
    encoded.append(encoder.flush())

    let frames = try parseMP3Frames(encoded)
    #expect(!frames.isEmpty)
    let blockTypeStats = try collectBlockTypeStats(frames: frames, data: encoded)

    #expect(
        blockTypeStats.shortBlockGranules > 0,
        "Encoder should emit at least one short-block granule for a transient signal"
    )
    #expect(
        blockTypeStats.startBlockGranules > 0,
        "Encoder should emit a start block before short blocks to satisfy MDCT overlap"
    )
    #expect(
        blockTypeStats.stopBlockGranules > 0,
        "Encoder should emit a stop block to transition back to long blocks"
    )

    // Sanity: the file must still round-trip cleanly through the decoder.
    let decoded = try MP3Decoder().decode(encoded)
    #expect(decoded.sampleRate == sampleRate)
    #expect(decoded.channels == 1)
    #expect(!decoded.samples.isEmpty)
    let allFinite = decoded.samples.allSatisfy(\.isFinite)
    #expect(allFinite)
}

@Test
func `Encoder should set subblock_gain for single-window impulse`() throws {
    let sampleRate = 44100
    let encoder = try MP3Encoder(sampleRate: sampleRate, channels: 1, bitrate: 128)

    // ~0.5 ms click sitting inside a single short window (a short window is ~8 ms of
    // audio post-filterbank). With one window much louder than the other two, the
    // encoder should pick a non-zero subblock_gain on at least one of the quiet
    // windows to keep them from being quantized to all zeros.
    let leadInSamples = sampleRate * 5 / 10
    let burstSamples = 24
    let trailingSamples = sampleRate * 5 / 10
    var pcm = [Float](repeating: 0, count: leadInSamples + burstSamples + trailingSamples)
    for sampleIndex in 0 ..< burstSamples {
        let phase = 2.0 * Double.pi * 6000.0 * Double(sampleIndex) / Double(sampleRate)
        pcm[leadInSamples + sampleIndex] = Float(sin(phase))
    }

    var encoded = encoder.encode(pcm: pcm)
    encoded.append(encoder.flush())

    let frames = try parseMP3Frames(encoded)
    let stats = try collectBlockTypeStats(frames: frames, data: encoded)
    #expect(stats.shortBlockGranules > 0, "Click should still trigger short blocks")
    let anySubblockGainSet = stats.maxSubblockGain.contains { $0 > 0 }
    #expect(
        anySubblockGainSet,
        "Quiet windows of a single-window click should pick up a non-zero subblock_gain"
    )

    // The bitstream must still round-trip cleanly.
    let decoded = try MP3Decoder().decode(encoded)
    #expect(decoded.sampleRate == sampleRate)
    let allFinite = decoded.samples.allSatisfy(\.isFinite)
    #expect(allFinite)
}

private struct BlockTypeStats {
    var longGranules = 0
    var startBlockGranules = 0
    var shortBlockGranules = 0
    var stopBlockGranules = 0
    /// Maximum non-zero subblock_gain seen across any short-block granule, per window.
    var maxSubblockGain: [Int] = [0, 0, 0]
}

/// Walk each frame's side info and count the per-(granule, channel) block types.
/// Mirrors just enough of the MPEG-1 Layer III side-info layout to drive the test.
private func collectBlockTypeStats(frames: [MP3Frame], data: Data) throws -> BlockTypeStats {
    var stats = BlockTypeStats()
    let bytes = [UInt8](data)
    for frame in frames {
        let sideInfoStart = frame.offset + 4 + (frame.hasCRC ? 2 : 0)
        let channels = frame.channelMode == .mono ? 1 : 2
        // main_data_begin (9) + private (5/3) + scfsi (4 * channels)
        var bitOffset = (sideInfoStart * 8) + 9 + (channels == 1 ? 5 : 3) + (4 * channels)

        for _ in 0 ..< 2 {
            for _ in 0 ..< channels {
                bitOffset += 12 + 9 + 8 + 4 // part2_3_length, big_values, global_gain, scalefac_compress
                let windowSwitchingFlag = (Int(bytes[bitOffset / 8]) >> (7 - (bitOffset % 8))) & 1
                bitOffset += 1
                if windowSwitchingFlag == 1 {
                    let blockType = readBitsBE(bytes: bytes, bitOffset: bitOffset, count: 2)
                    bitOffset += 2
                    bitOffset += 1 // mixed_block_flag
                    bitOffset += 5 + 5 // table_select[0..1]
                    for windowIndex in 0 ..< 3 {
                        let gain = readBitsBE(bytes: bytes, bitOffset: bitOffset, count: 3)
                        bitOffset += 3
                        if blockType == 2, gain > stats.maxSubblockGain[windowIndex] {
                            stats.maxSubblockGain[windowIndex] = gain
                        }
                    }
                    switch blockType {
                    case 1: stats.startBlockGranules += 1
                    case 2: stats.shortBlockGranules += 1
                    case 3: stats.stopBlockGranules += 1
                    default: break
                    }
                } else {
                    bitOffset += 5 + 5 + 5 + 4 + 3 // table_select × 3, region_count × 2
                    stats.longGranules += 1
                }
                bitOffset += 1 + 1 + 1 // preflag, scalefac_scale, count1table_select
            }
        }
    }
    return stats
}

private func readBitsBE(bytes: [UInt8], bitOffset: Int, count: Int) -> Int {
    var value = 0
    for index in 0 ..< count {
        let absoluteBit = bitOffset + index
        let bit = (Int(bytes[absoluteBit / 8]) >> (7 - (absoluteBit % 8))) & 1
        value = (value << 1) | bit
    }
    return value
}

// MARK: - Test errors

private enum TestError: Error, Equatable {
    case fixtureNotFound(name: String)
    case invalidHeader(reason: String)
    case truncatedFrame
    case unsupportedWAV(reason: String)
}

// MARK: - Fixture loading

private func loadFixture(named name: String, withExtension fileExtension: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures") else {
        throw TestError.fixtureNotFound(name: "\(name).\(fileExtension)")
    }
    return try Data(contentsOf: url)
}

private struct WAVAudio {
    var sampleRate: Int
    var channels: Int
    var samples: [Float]
}

private func loadWAVFixture(named name: String) throws -> WAVAudio {
    let data = try loadFixture(named: name, withExtension: "wav")
    let bytes = [UInt8](data)

    guard bytes.count >= 12,
          String(bytes: bytes[0 ..< 4], encoding: .ascii) == "RIFF",
          String(bytes: bytes[8 ..< 12], encoding: .ascii) == "WAVE"
    else {
        throw TestError.unsupportedWAV(reason: "Missing RIFF/WAVE header")
    }

    var cursor = 12
    var sampleRate: Int?
    var channels: Int?
    var bitsPerSample: Int?
    var dataStart: Int?
    var dataSize: Int?

    while cursor + 8 <= bytes.count {
        let chunkIdentifier = String(bytes: bytes[cursor ..< (cursor + 4)], encoding: .ascii) ?? ""
        let chunkSize = readLittleEndianUInt32(bytes: bytes, offset: cursor + 4)
        let chunkStart = cursor + 8
        let nextChunk = chunkStart + Int(chunkSize) + (Int(chunkSize) & 1)
        guard chunkStart + Int(chunkSize) <= bytes.count else {
            throw TestError.truncatedFrame
        }

        if chunkIdentifier == "fmt " {
            guard chunkSize >= 16 else {
                throw TestError.unsupportedWAV(reason: "Truncated format chunk")
            }
            let formatCode = readLittleEndianUInt16(bytes: bytes, offset: chunkStart)
            guard formatCode == 1 else {
                throw TestError.unsupportedWAV(reason: "Only PCM WAV fixtures are supported")
            }
            channels = Int(readLittleEndianUInt16(bytes: bytes, offset: chunkStart + 2))
            sampleRate = Int(readLittleEndianUInt32(bytes: bytes, offset: chunkStart + 4))
            bitsPerSample = Int(readLittleEndianUInt16(bytes: bytes, offset: chunkStart + 14))
        } else if chunkIdentifier == "data" {
            dataStart = chunkStart
            dataSize = Int(chunkSize)
        }

        cursor = nextChunk
    }

    guard let sampleRate, let channels, let bitsPerSample, let dataStart, let dataSize else {
        throw TestError.unsupportedWAV(reason: "Missing required format or data chunk")
    }
    guard channels > 0 else {
        throw TestError.unsupportedWAV(reason: "Invalid channel count")
    }
    guard bitsPerSample == 16 else {
        throw TestError.unsupportedWAV(reason: "Only 16-bit PCM WAV fixtures are supported")
    }

    let sampleCount = dataSize / 2
    var samples = [Float]()
    samples.reserveCapacity(sampleCount)
    for sampleIndex in 0 ..< sampleCount {
        let byteOffset = dataStart + sampleIndex * 2
        let unsignedValue = readLittleEndianUInt16(bytes: bytes, offset: byteOffset)
        let signedValue = Int16(bitPattern: unsignedValue)
        samples.append(Float(signedValue) / 32768.0)
    }

    return WAVAudio(sampleRate: sampleRate, channels: channels, samples: samples)
}

private func readLittleEndianUInt16(bytes: [UInt8], offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

private func readLittleEndianUInt32(bytes: [UInt8], offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

// MARK: - MP3 bitstream structural parser

// Just enough of the MPEG-1 Layer III frame header + side-info prefix to validate the
// encoder's output structurally, without decoding audio. Covers the same class of bugs
// used to flag (wrong sync, wrong header fields, "invalid new backstep").

private enum MPEGVersion {
    case mpeg1
    case mpeg2
    case mpeg25
    case reserved
}

private enum MPEGLayer {
    case layer1
    case layer2
    case layer3
    case reserved
}

private enum ChannelMode {
    case stereo
    case jointStereo
    case dualChannel
    case mono
}

private struct MP3Frame {
    var version: MPEGVersion
    var layer: MPEGLayer
    var sampleRate: Int
    var bitrate: Int // kbps
    var channelMode: ChannelMode
    var modeExtension: Int
    var frameSize: Int // total bytes including header (+ CRC + side info + main data + padding)
    var sideInfoSize: Int // bytes of side info (for MPEG-1: 17 mono, 32 stereo)
    var hasCRC: Bool
    var mainDataBegin: Int
    var offset: Int
}

private let mpeg1Layer3Bitrates: [Int] = [
    0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, -1
]
private let mpeg1SampleRates: [Int] = [44100, 48000, 32000, -1]

private func parseMP3Frames(_ data: Data) throws -> [MP3Frame] {
    let bytes = [UInt8](data)
    var cursor = skipID3v2(bytes)
    var frames: [MP3Frame] = []

    while cursor + 4 <= bytes.count {
        guard bytes[cursor] == 0xFF, bytes[cursor + 1] & 0xE0 == 0xE0 else {
            cursor += 1
            continue
        }
        let frame = try parseFrameHeader(bytes: bytes, offset: cursor)
        guard cursor + frame.frameSize <= bytes.count else {
            break
        }
        frames.append(frame)
        cursor += frame.frameSize
    }

    return frames
}

private func parseFrameHeader(bytes: [UInt8], offset: Int) throws -> MP3Frame {
    // MPEG audio frame header layout (bytes 1..3 after the 0xFF sync byte):
    //   byte 1: sync tail | version (2b) | layer (2b) | protection bit
    //   byte 2: bitrate index (4b) | sample-rate index (2b) | padding | private
    //   byte 3: channel mode (2b) | mode ext (2b) | copyright | original | emphasis (2b)
    let versionLayerByte = bytes[offset + 1]
    let bitrateRateByte = bytes[offset + 2]
    let modeByte = bytes[offset + 3]

    let versionBits = (versionLayerByte >> 3) & 0x03
    let version: MPEGVersion = switch versionBits {
    case 0:
        .mpeg25
    case 1:
        .reserved
    case 2:
        .mpeg2
    case 3:
        .mpeg1
    default:
        .reserved
    }

    let layerBits = (versionLayerByte >> 1) & 0x03
    let layer: MPEGLayer = switch layerBits {
    case 0:
        .reserved
    case 1:
        .layer3
    case 2:
        .layer2
    case 3:
        .layer1
    default:
        .reserved
    }

    let hasCRC = (versionLayerByte & 0x01) == 0

    let bitrateIndex = Int((bitrateRateByte >> 4) & 0x0F)
    guard version == .mpeg1, layer == .layer3 else {
        throw TestError.invalidHeader(reason: "Only MPEG-1 Layer III is supported")
    }
    let bitrate = mpeg1Layer3Bitrates[bitrateIndex]
    guard bitrate > 0 else {
        throw TestError.invalidHeader(reason: "Invalid bitrate index \(bitrateIndex)")
    }

    let sampleRateIndex = Int((bitrateRateByte >> 2) & 0x03)
    let sampleRate = mpeg1SampleRates[sampleRateIndex]
    guard sampleRate > 0 else {
        throw TestError.invalidHeader(reason: "Invalid sample-rate index \(sampleRateIndex)")
    }

    let padding = Int((bitrateRateByte >> 1) & 0x01)

    let channelMode: ChannelMode = switch (modeByte >> 6) & 0x03 {
    case 0:
        .stereo
    case 1:
        .jointStereo
    case 2:
        .dualChannel
    case 3:
        .mono
    default:
        .mono
    }
    let modeExtension = Int((modeByte >> 4) & 0x03)

    let frameSize = (144 * bitrate * 1000) / sampleRate + padding
    let sideInfoSize = channelMode == .mono ? 17 : 32

    let sideInfoStart = offset + 4 + (hasCRC ? 2 : 0)
    guard sideInfoStart + 2 <= bytes.count else {
        throw TestError.truncatedFrame
    }
    // main_data_begin is the top 9 bits of the side info.
    let mainDataBegin = (Int(bytes[sideInfoStart]) << 1) | Int(bytes[sideInfoStart + 1] >> 7)

    return MP3Frame(
        version: version,
        layer: layer,
        sampleRate: sampleRate,
        bitrate: bitrate,
        channelMode: channelMode,
        modeExtension: modeExtension,
        frameSize: frameSize,
        sideInfoSize: sideInfoSize,
        hasCRC: hasCRC,
        mainDataBegin: mainDataBegin,
        offset: offset
    )
}

private func skipID3v2(_ bytes: [UInt8]) -> Int {
    guard bytes.count >= 10,
          bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33
    else {
        return 0
    }
    let size = (Int(bytes[6] & 0x7F) << 21)
        | (Int(bytes[7] & 0x7F) << 14)
        | (Int(bytes[8] & 0x7F) << 7)
        | Int(bytes[9] & 0x7F)
    return 10 + size
}

/// For each frame, main_data_begin must not exceed the accumulated main-data bytes emitted
/// by previous frames. Violating this is the "invalid new backstep" condition.
private func assertMainDataReservoirIsConsistent(frames: [MP3Frame]) throws {
    var reservoirBytes = 0
    for (frameIndex, frame) in frames.enumerated() {
        #expect(
            frame.mainDataBegin <= reservoirBytes,
            "Frame \(frameIndex): main_data_begin (\(frame.mainDataBegin)) exceeds available reservoir (\(reservoirBytes))"
        )
        let crcSize = frame.hasCRC ? 2 : 0
        let mainDataSize = frame.frameSize - 4 - crcSize - frame.sideInfoSize
        // Consumed: mainDataBegin bytes are pulled from the previous reservoir.
        // Added: all of this frame's main_data bytes flow into the reservoir for future frames.
        reservoirBytes = max(0, reservoirBytes - frame.mainDataBegin) + mainDataSize
    }
}

// MARK: - Signal analysis helpers

private func dominantFrequency(
    samples: [Float],
    sampleRate: Double,
    start: Int,
    maxFrequency: Double
) -> Double {
    let windowSize = min(4096, max(0, samples.count - start))
    guard windowSize > 0 else {
        return 0
    }

    let slice = Array(samples[start ..< (start + windowSize)])
    let maxFrequencyBin = min(Int(maxFrequency * Double(windowSize) / sampleRate), windowSize / 2)

    var bestMagnitude = -Double.infinity
    var bestFrequencyBin = 0
    for frequencyBin in 1 ... maxFrequencyBin {
        var realComponent = 0.0
        var imaginaryComponent = 0.0
        for (sampleIndex, sample) in slice.enumerated() {
            let angle = 2.0 * Double.pi * Double(frequencyBin * sampleIndex) / Double(windowSize)
            realComponent += Double(sample) * cos(angle)
            imaginaryComponent -= Double(sample) * sin(angle)
        }
        let magnitude = realComponent * realComponent + imaginaryComponent * imaginaryComponent
        if magnitude > bestMagnitude {
            bestMagnitude = magnitude
            bestFrequencyBin = frequencyBin
        }
    }

    return Double(bestFrequencyBin) * sampleRate / Double(windowSize)
}

private struct AlignedSegment {
    var offset: Int
    var correlation: Double
    var segment: [Float]
}

private func bestAlignedSegment(
    reference: [Float],
    decoded: [Float],
    searchLimit: Int,
    step: Int
) -> AlignedSegment? {
    guard !reference.isEmpty, decoded.count >= reference.count else {
        return nil
    }

    let maxOffset = min(searchLimit, decoded.count - reference.count)
    var best: AlignedSegment?
    var bestScore = -Double.infinity

    for offset in stride(from: 0, through: maxOffset, by: max(1, step)) {
        let segment = Array(decoded[offset ..< (offset + reference.count)])
        let score = abs(normalizedCorrelation(reference, segment))
        if score > bestScore {
            bestScore = score
            best = AlignedSegment(offset: offset, correlation: normalizedCorrelation(reference, segment), segment: segment)
        }
    }

    return best
}

private func normalizedCorrelation(_ firstSignal: [Float], _ secondSignal: [Float]) -> Double {
    guard firstSignal.count == secondSignal.count, !firstSignal.isEmpty else {
        return 0
    }

    var dotProduct = 0.0
    var firstEnergy = 0.0
    var secondEnergy = 0.0
    for (firstSample, secondSample) in zip(firstSignal, secondSignal) {
        let firstValue = Double(firstSample)
        let secondValue = Double(secondSample)
        dotProduct += firstValue * secondValue
        firstEnergy += firstValue * firstValue
        secondEnergy += secondValue * secondValue
    }

    guard firstEnergy > 0, secondEnergy > 0 else {
        return 0
    }
    return dotProduct / sqrt(firstEnergy * secondEnergy)
}

private func rootMeanSquare(_ samples: [Float]) -> Double {
    guard !samples.isEmpty else {
        return 0
    }
    let energy = samples.reduce(0.0) { partialResult, sample in
        let value = Double(sample)
        return partialResult + value * value
    }
    return sqrt(energy / Double(samples.count))
}

private func assertFiniteSignal(_ samples: [Float], label: String) {
    let allSamplesAreFinite = samples.allSatisfy(\.isFinite)
    #expect(!samples.isEmpty, "\(label) should not be empty")
    #expect(allSamplesAreFinite, "\(label) should contain only finite samples")
    #expect(samples.contains { abs($0) > 0.0001 }, "\(label) should not be silent")
}
