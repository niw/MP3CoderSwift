//
//  MP3FrameParser.swift
//  MP3CoderTests
//
//  Created by Opus 4.7 on 4/27/26.
//

import Foundation
import Testing

// Just enough of the MPEG-1 Layer III frame header + side-info prefix to validate the
// encoder's output structurally, without decoding audio. Covers the same class of bugs
// used to flag (wrong sync, wrong header fields, "invalid new backstep").

enum MPEGVersion {
    case mpeg1
    case mpeg2
    case mpeg25
    case reserved
}

enum MPEGLayer {
    case layer1
    case layer2
    case layer3
    case reserved
}

enum ChannelMode {
    case stereo
    case jointStereo
    case dualChannel
    case mono
}

struct MP3Frame {
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

let mpeg1Layer3Bitrates: [Int] = [
    0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, -1
]
let mpeg1SampleRates: [Int] = [44100, 48000, 32000, -1]

func parseMP3Frames(_ data: Data) throws -> [MP3Frame] {
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
func assertMainDataReservoirIsConsistent(frames: [MP3Frame]) throws {
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
