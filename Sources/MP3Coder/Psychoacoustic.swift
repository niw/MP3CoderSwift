//
//  Psychoacoustic.swift
//  MP3Coder
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import Foundation

/// Lightweight psychoacoustic model. Per-SFB masking thresholds are derived from
/// (1) a frequency-dependent SNR target shaped by the absolute threshold of hearing,
/// and (2) a one-tap spreading function so a loud band raises its neighbours' tolerance.
struct PsychoacousticModel {
    var sampleRate: Int
    var scaleFactorBandBounds: [Int]
    private var snrTargetsDb: [Double]

    init(sampleRate: Int) {
        self.sampleRate = sampleRate
        let bounds = MP3Constants.scaleFactorBandBoundaries(sampleRate: sampleRate)
        scaleFactorBandBounds = bounds

        // SNR target per SFB: tightest near the ATH minimum (~3.5 kHz, where the ear
        // is most sensitive) and loosens as the absolute threshold rises at the
        // spectrum extremes. Only ATH *differences* are used so the curve doesn't
        // need an absolute SPL calibration.
        let bandCount = bounds.count - 1
        let athMinDb = -2.0
        let baseSnrDb = 30.0
        let athToSnrSlope = 0.5
        let minSnrDb = 6.0
        let nyquistDenominator = 1152.0
        var snrs = [Double](repeating: baseSnrDb, count: bandCount)
        for band in 0 ..< bandCount {
            let centerLine = (bounds[band] + bounds[band + 1]) / 2
            let centerFrequencyHz = Double(centerLine) * Double(sampleRate) / nyquistDenominator
            let athDb = Self.absoluteThresholdOfHearingDb(frequencyHz: centerFrequencyHz)
            snrs[band] = max(minSnrDb, baseSnrDb - (athDb - athMinDb) * athToSnrSlope)
        }
        snrTargetsDb = snrs
    }

    /// Returns one masking threshold per SFB. A band's quantization noise is
    /// considered audible when its post-decode distortion exceeds the returned value.
    func computeThresholds(spectral: [Float]) -> [Float] {
        let bandCount = scaleFactorBandBounds.count - 1

        var energies = [Double](repeating: 0, count: bandCount)
        for band in 0 ..< bandCount {
            let bandStart = scaleFactorBandBounds[band]
            let bandEnd = min(scaleFactorBandBounds[band + 1], spectral.count)
            var energy = 0.0
            for spectralIndex in bandStart ..< bandEnd {
                let sample = Double(spectral[spectralIndex])
                energy += sample * sample
            }
            energies[band] = energy
        }

        // Lightweight spreading function. Lower-frequency maskers spread upward more
        // strongly than higher-frequency maskers spread downward, and second-neighbour
        // bands still contribute weak masking.
        let lowerNeighbourSpread = pow(10.0, -8.0 / 10.0)
        let upperNeighbourSpread = pow(10.0, -14.0 / 10.0)
        let lowerSecondNeighbourSpread = pow(10.0, -18.0 / 10.0)
        let upperSecondNeighbourSpread = pow(10.0, -24.0 / 10.0)
        var thresholds = [Float](repeating: 0, count: bandCount)
        let absoluteFloor: Float = 1e-10
        for band in 0 ..< bandCount {
            var maskerEnergy = energies[band]
            if band > 0 {
                maskerEnergy = max(maskerEnergy, energies[band - 1] * lowerNeighbourSpread)
            }
            if band > 1 {
                maskerEnergy = max(maskerEnergy, energies[band - 2] * lowerSecondNeighbourSpread)
            }
            if band + 1 < bandCount {
                maskerEnergy = max(maskerEnergy, energies[band + 1] * upperNeighbourSpread)
            }
            if band + 2 < bandCount {
                maskerEnergy = max(maskerEnergy, energies[band + 2] * upperSecondNeighbourSpread)
            }
            let snrDb = band < snrTargetsDb.count ? snrTargetsDb[band] : 30.0
            let maskingRatio = pow(10.0, -snrDb / 10.0)
            thresholds[band] = max(Float(maskerEnergy * maskingRatio), absoluteFloor)
        }
        return thresholds
    }

    // Painter & Spanias, "Perceptual Coding of Digital Audio" (Proc. IEEE, 2000), eq. 3.
    private static func absoluteThresholdOfHearingDb(frequencyHz: Double) -> Double {
        let kHz = max(0.02, frequencyHz / 1000.0)
        return 3.64 * pow(kHz, -0.8)
            - 6.5 * exp(-0.6 * pow(kHz - 3.3, 2.0))
            + 0.001 * pow(kHz, 4.0)
    }
}
