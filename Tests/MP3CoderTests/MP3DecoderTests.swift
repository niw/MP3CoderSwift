//
//  MP3DecoderTests.swift
//  MP3CoderTests
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import Foundation
@testable
import MP3Coder
import Testing

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
