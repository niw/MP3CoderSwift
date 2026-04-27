//
//  PsychoacousticModelTests.swift
//  MP3CoderTests
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import Foundation
@testable
import MP3Coder
import Testing

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
