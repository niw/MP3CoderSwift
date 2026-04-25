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
///
/// `Sendable` because every member is a value type and `computeThresholds` is a
/// pure function (no internal mutation), so a single instance is safe to hand to
/// multiple concurrent quantizer workers.
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
    ///
    /// The SNR target per band is shaped by tonality: the ear needs noise to sit
    /// roughly 18–24 dB below a tone (TMN) but only ~5 dB below noise (NMT). We
    /// estimate tonality with the Spectral Flatness Measure (geometric mean over
    /// arithmetic mean of bin energies), then interpolate the band's SNR target
    /// between the noise-baseline and a tone-tightened value. This keeps tonal
    /// content (sustained pitches, harmonics) audibly clean while letting noise-like
    /// bands take coarser quantization.
    func computeThresholds(spectral: UnsafeBufferPointer<Float>) -> [Float] {
        let bandCount = scaleFactorBandBounds.count - 1

        var energies = [Double](repeating: 0, count: bandCount)
        // SFM in [0, 1] per band — 0 = pure tone, 1 = white noise. Bands with too
        // few lines or near-zero energy default to "noise" so they don't get a
        // tonality boost they don't deserve.
        var spectralFlatness = [Double](repeating: 1.0, count: bandCount)
        let energyFloor = 1e-30
        for band in 0 ..< bandCount {
            let bandStart = scaleFactorBandBounds[band]
            let bandEnd = min(scaleFactorBandBounds[band + 1], spectral.count)
            let lineCount = bandEnd - bandStart
            guard lineCount > 0 else {
                continue
            }
            var energy = 0.0
            var logSum = 0.0
            for spectralIndex in bandStart ..< bandEnd {
                let value = Double(spectral[spectralIndex])
                let lineEnergy = max(value * value, energyFloor)
                energy += lineEnergy
                logSum += log(lineEnergy)
            }
            energies[band] = energy
            if lineCount >= 2, energy > energyFloor * Double(lineCount) {
                let arithmeticMean = energy / Double(lineCount)
                let geometricMean = exp(logSum / Double(lineCount))
                spectralFlatness[band] = max(0.0, min(1.0, geometricMean / arithmeticMean))
            }
        }

        // Lightweight spreading function. Lower-frequency maskers spread upward more
        // strongly than higher-frequency maskers spread downward, and second-neighbour
        // bands still contribute weak masking.
        let lowerNeighbourSpread = pow(10.0, -8.0 / 10.0)
        let upperNeighbourSpread = pow(10.0, -14.0 / 10.0)
        let lowerSecondNeighbourSpread = pow(10.0, -18.0 / 10.0)
        let upperSecondNeighbourSpread = pow(10.0, -24.0 / 10.0)
        // SFM_dB at or below this is treated as a pure tone (full TMN boost). At
        // 0 dB (uniform spectrum) the band is treated as noise (no boost).
        let sfmDbForFullTone = -60.0
        // How much extra SNR a fully-tonal band gets vs. the noise baseline. ~15 dB
        // matches the gap between TMN (~24 dB) and NMT (~5–9 dB) used in ISO Psy
        // Model 2; a bit conservative to avoid over-spending bits on rare cases.
        let toneSnrBoostDb = 15.0
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
            let baselineSnrDb = band < snrTargetsDb.count ? snrTargetsDb[band] : 30.0
            // tonality alpha in [0, 1]: 0 for noise, 1 for pure tone.
            let sfm = spectralFlatness[band]
            let sfmDb = sfm > 0 ? 10.0 * log10(sfm) : sfmDbForFullTone
            let alpha = max(0.0, min(1.0, sfmDb / sfmDbForFullTone))
            let snrDb = baselineSnrDb + alpha * toneSnrBoostDb
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
