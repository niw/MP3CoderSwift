//
//  MP3Types.swift
//  MP3Coder
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import Foundation

// MARK: - Constants

enum MP3Constants {
    // MPEG1 Layer3 bitrate table (kbps), index 1-14
    static let bitrateTable: [Int] = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]

    // Sample rate indices for MPEG1
    static let sampleRates: [Int] = [44100, 48000, 32000]

    // Scale factor band boundaries for MPEG1 long blocks at 44100 Hz
    static let scaleFactorBandsLong44100: [Int] = [0, 4, 8, 12, 16, 20, 24, 30, 36, 44, 52, 62, 74, 90, 110, 134, 162, 196, 238, 288, 342, 418, 576]

    // Scale factor band boundaries for MPEG1 long blocks at 48000 Hz (ISO 11172-3 Table B.8)
    static let scaleFactorBandsLong48000: [Int] = [0, 4, 8, 12, 16, 20, 24, 30, 36, 44, 54, 66, 82, 102, 126, 156, 194, 240, 296, 364, 448, 550, 576]

    // Scale factor band boundaries for MPEG1 long blocks at 32000 Hz (ISO 11172-3 Table B.8)
    static let scaleFactorBandsLong32000: [Int] = [0, 4, 8, 12, 16, 20, 24, 30, 36, 44, 54, 66, 82, 102, 126, 156, 194, 240, 296, 364, 448, 550, 576]

    // Scale factor band boundaries for MPEG1 short blocks at 44100 Hz
    static let scaleFactorBandsShort44100: [Int] = [0, 4, 8, 12, 16, 22, 30, 40, 52, 66, 84, 106, 136, 192]

    // Scale factor band boundaries for MPEG1 short blocks at 48000 Hz (ISO 11172-3 Table B.8)
    static let scaleFactorBandsShort48000: [Int] = [0, 4, 8, 12, 16, 22, 28, 38, 50, 64, 80, 100, 126, 192]

    // Scale factor band boundaries for MPEG1 short blocks at 32000 Hz (ISO 11172-3 Table B.8)
    static let scaleFactorBandsShort32000: [Int] = [0, 4, 8, 12, 16, 22, 30, 42, 58, 78, 104, 138, 180, 192]

    // Scale factor band widths used for region boundaries
    static func scaleFactorBandBoundaries(sampleRate: Int) -> [Int] {
        switch sampleRate {
        case 44100:
            scaleFactorBandsLong44100
        case 48000:
            scaleFactorBandsLong48000
        case 32000:
            scaleFactorBandsLong32000
        default:
            scaleFactorBandsLong44100
        }
    }

    static func scaleFactorBandBoundariesShort(sampleRate: Int) -> [Int] {
        switch sampleRate {
        case 44100:
            scaleFactorBandsShort44100
        case 48000:
            scaleFactorBandsShort48000
        case 32000:
            scaleFactorBandsShort32000
        default:
            scaleFactorBandsShort44100
        }
    }
}

// MARK: - Encoder errors

public enum MP3EncoderError: Error, Equatable, Sendable {
    case unsupportedSampleRate(Int)
    case unsupportedBitrate(Int)
    case unsupportedChannelCount(Int)
}

// MARK: - Channel mode

enum ChannelMode: UInt8 {
    case stereo = 0
    case jointStereo = 1
    case dualChannel = 2
    case mono = 3
}

// MARK: - Granule info (side information per granule per channel)

struct GranuleInfo {
    var part2_3_length: Int = 0 // bits used for scale factors + Huffman data
    var bigValues: Int = 0 // number of big_values pairs
    var globalGain: Int = 210 // global gain (0-255)
    var scaleFactorCompress: Int = 0 // index into scale factor compress table
    var windowSwitchingFlag: Bool = false
    var blockType: Int = 0 // 0=normal long
    var mixedBlockFlag: Bool = false
    var tableSelect: [Int] = [0, 0, 0] // Huffman table selection for 3 regions
    var subblockGain: [Int] = [0, 0, 0] // for short blocks
    var region0Count: Int = 10 // region boundary
    var region1Count: Int = 3 // region boundary
    var preflag: Bool = false
    var scaleFactorScale: Bool = false
    var count1TableSelect: Int = 0 // 0 or 1 (table A or B)
    var scaleFactors: [Int] = Array(repeating: 0, count: 22) // long block scale factors
    var scaleFactorsShort: [Int] = Array(repeating: 0, count: 39) // short block scale factors, indexed [window * 13 + band]
    var part2Length: Int = 0 // bits for scale factors
}

// MARK: - Frame header

struct MP3FrameHeader {
    var id: Int = 1 // MPEG1 = 1
    var layer: Int = 1 // Layer3 = 01 (layer field in header = 01 for layer3... wait, it's 01 for layer2, 11 for layer1)
    // Actually: layer bits: 11=Layer1, 10=Layer2, 01=Layer3
    var protectionBit: Bool = true // 1 = no CRC
    var bitrateIndex: Int = 9 // 128 kbps default
    var samplingFreqIndex: Int = 0 // 44100 Hz
    var paddingBit: Bool = false
    var privateBit: Bool = false
    var mode: ChannelMode = .mono
    var modeExtension: Int = 0
    var copyright: Bool = false
    var original: Bool = true
    var emphasis: Int = 0
}

// MARK: - MP3 Frame

struct MP3Frame {
    var header: MP3FrameHeader
    var sideInfo: [[GranuleInfo]] // [granule][channel]
    var spectralData: [[[Float]]] // [granule][channel][576]
    var quantized: [[[Int]]] // [granule][channel][576]
}
