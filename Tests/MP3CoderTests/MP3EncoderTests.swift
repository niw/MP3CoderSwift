//
//  MP3EncoderTests.swift
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
func `Encoder should produce structurally valid MP3 from Int16 sine wave`() throws {
    let sampleRate = 44100
    let encoder = try MP3Encoder(sampleRate: sampleRate, channels: 1, bitrate: 128)

    let sampleCount = sampleRate
    var pcmSamples = [Int16](repeating: 0, count: sampleCount)
    for sampleIndex in 0 ..< sampleCount {
        let value = sin(2.0 * Double.pi * 440.0 * Double(sampleIndex) / Double(sampleRate)) * 0.5
        pcmSamples[sampleIndex] = Int16(value * 32768.0)
    }

    var output = encoder.encode(pcm: pcmSamples)
    output.append(encoder.flush())

    #expect(output.count > 0, "Encoded output should be non-empty")

    let frames = try parseMP3Frames(output)
    #expect(!frames.isEmpty, "Bitstream should contain at least one parsed frame")
    for frame in frames {
        #expect(frame.version == .mpeg1)
        #expect(frame.layer == .layer3)
        #expect(frame.sampleRate == sampleRate)
        #expect(frame.bitrate == 128)
        #expect(frame.channelMode == .mono)
    }
    try assertMainDataReservoirIsConsistent(frames: frames)
}

@Test
func `Encoder should round-trip Int16 sine wave to the dominant frequency`() throws {
    let sampleRate = 44100
    let encoder = try MP3Encoder(sampleRate: sampleRate, channels: 1, bitrate: 128)

    let sampleCount = sampleRate
    var pcmSamples = [Int16](repeating: 0, count: sampleCount)
    for sampleIndex in 0 ..< sampleCount {
        let value = sin(2.0 * Double.pi * 440.0 * Double(sampleIndex) / Double(sampleRate)) * 0.5
        pcmSamples[sampleIndex] = Int16(value * 32768.0)
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
    #expect(abs(dominant - 440.0) < 30.0, "Dominant frequency should be ~440 Hz, got \(dominant)")
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
    let output = encoder.encode(pcm: [] as [Float])
    #expect(output.count == 0, "Empty input should produce no output")
}

@Test
func `Encoder should reject unsupported sample rate`() {
    #expect(throws: MP3EncoderError.unsupportedSampleRate(22050)) {
        try MP3Encoder(sampleRate: 22050, channels: 1, bitrate: 128)
    }
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
