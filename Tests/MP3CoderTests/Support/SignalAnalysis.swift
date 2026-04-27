//
//  SignalAnalysis.swift
//  MP3CoderTests
//
//  Created by Opus 4.7 on 4/27/26.
//

import Foundation
import Testing

func dominantFrequency(
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

struct AlignedSegment {
    var correlation: Double
    var segment: [Float]
}

func bestAlignedSegment(
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
            best = AlignedSegment(correlation: normalizedCorrelation(reference, segment), segment: segment)
        }
    }

    return best
}

func normalizedCorrelation(_ firstSignal: [Float], _ secondSignal: [Float]) -> Double {
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

func rootMeanSquare(_ samples: [Float]) -> Double {
    guard !samples.isEmpty else {
        return 0
    }
    let energy = samples.reduce(0.0) { partialResult, sample in
        let value = Double(sample)
        return partialResult + value * value
    }
    return sqrt(energy / Double(samples.count))
}

func assertFiniteSignal(_ samples: [Float], label: String) {
    let allSamplesAreFinite = samples.allSatisfy(\.isFinite)
    #expect(!samples.isEmpty, "\(label) should not be empty")
    #expect(allSamplesAreFinite, "\(label) should contain only finite samples")
    #expect(samples.contains { abs($0) > 0.0001 }, "\(label) should not be silent")
}
