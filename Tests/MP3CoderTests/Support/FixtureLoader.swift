//
//  FixtureLoader.swift
//  MP3CoderTests
//
//  Created by Opus 4.7 on 4/27/26.
//

import Foundation

struct WAVAudio {
    var sampleRate: Int
    var channels: Int
    var samples: [Float]
}

func loadFixture(named name: String, withExtension fileExtension: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures") else {
        throw TestError.fixtureNotFound(name: "\(name).\(fileExtension)")
    }
    return try Data(contentsOf: url)
}

func loadWAVFixture(named name: String) throws -> WAVAudio {
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

func readLittleEndianUInt16(bytes: [UInt8], offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

func readLittleEndianUInt32(bytes: [UInt8], offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}
