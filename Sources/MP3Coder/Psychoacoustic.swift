//
//  Psychoacoustic.swift
//  MP3Coder
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import Foundation

/// Simplified psychoacoustic model
/// Computes masking thresholds per scale factor band
struct PsychoacousticModel {
    var sampleRate: Int
    var scaleFactorBandBounds: [Int]

    init(sampleRate: Int) {
        self.sampleRate = sampleRate
        scaleFactorBandBounds = MP3Constants.scaleFactorBandBoundaries(sampleRate: sampleRate)
    }

    /// Compute masking thresholds for spectral data
    /// Returns threshold per scale factor band
    func computeThresholds(spectral: [Float]) -> [Float] {
        let bandCount = scaleFactorBandBounds.count - 1
        var thresholds = [Float](repeating: 0, count: bandCount)

        for band in 0 ..< bandCount {
            let bandStart = scaleFactorBandBounds[band]
            let bandEnd = scaleFactorBandBounds[band + 1]

            // Compute energy in this band
            var energy: Float = 0
            for spectralIndex in bandStart ..< min(bandEnd, spectral.count) {
                energy += spectral[spectralIndex] * spectral[spectralIndex]
            }

            // Simplified masking: threshold is energy * 10^(-SNR/10)
            // Use a constant 30dB SNR as simplified model
            let signalToNoiseRatio: Float = 30.0
            let maskingRatio: Float = pow(10.0, -signalToNoiseRatio / 10.0)
            thresholds[band] = energy * maskingRatio

            // Minimum threshold (absolute threshold of hearing, simplified)
            let minThreshold: Float = 1e-10
            thresholds[band] = max(thresholds[band], minThreshold)
        }

        return thresholds
    }

    /// Compute energy per scale factor band
    func bandEnergy(spectral: [Float]) -> [Float] {
        let bandCount = scaleFactorBandBounds.count - 1
        var energy = [Float](repeating: 0, count: bandCount)

        for band in 0 ..< bandCount {
            let bandStart = scaleFactorBandBounds[band]
            let bandEnd = min(scaleFactorBandBounds[band + 1], spectral.count)
            for spectralIndex in bandStart ..< bandEnd {
                energy[band] += spectral[spectralIndex] * spectral[spectralIndex]
            }
        }
        return energy
    }
}
