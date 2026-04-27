//
//  TransientDetector.swift
//  MP3Coder
//
//  Created by GPT 5.5 and Opus 4.7 on 4/24/26.
//

import Foundation

/// Per-channel transient detector used to drive short-block switching.
///
/// Heuristic: split a granule's PCM into three sub-windows (192 samples each at
/// 1152 samples-per-frame / 2 granules / 3 sub-windows) and look at the maximum
/// vs. minimum sub-window energy plus the energy jump from the previous granule.
/// A spike inside the granule signals an internal transient (drum hit, hi-hat),
/// while a jump from the previous granule signals a sharp onset across the seam.
final class TransientDetector {
    private var previousEnergy: Double = 0
    /// Linear ratio threshold (~+10 dB) tuned for music: low enough to catch drum
    /// onsets, high enough to ignore steady-state harmonic content. Used by both
    /// the in-line detector and the lookahead variant — the lookahead must fire
    /// in exactly the same situations the in-line detector would fire one granule
    /// later, otherwise transients sneak past the lookahead and land in the
    /// long-resolution part of a `.start` window (pre-echo). Going *below* the
    /// in-line threshold over-triggers on natural per-granule energy modulation
    /// (vibrato, AM, dynamic music) and produces audible scattering artifacts.
    private let ratioThreshold: Double = 10.0
    /// Floor below which energies are treated as silence (avoids divide-by-zero
    /// blowing the ratio up on near-silent input).
    private let energyFloor: Double = 1e-9

    /// Examine one granule's PCM (`pcm.count` is the granule length).
    /// Returns true if an internal sub-window spike or a frame-boundary jump
    /// exceeds the ratio threshold.
    func detectTransient(pcm: UnsafeBufferPointer<Float>) -> Bool {
        let subWindowCount = 3
        let subWindowSize = pcm.count / subWindowCount
        guard subWindowSize > 0 else {
            return false
        }

        var maxEnergy = 0.0
        var minEnergy = Double.greatestFiniteMagnitude
        for windowIndex in 0 ..< subWindowCount {
            var energy = 0.0
            let windowStart = windowIndex * subWindowSize
            for sampleIndex in 0 ..< subWindowSize {
                let sample = Double(pcm[windowStart + sampleIndex])
                energy += sample * sample
            }
            energy /= Double(subWindowSize)
            if energy > maxEnergy {
                maxEnergy = energy
            }
            if energy < minEnergy {
                minEnergy = energy
            }
        }

        // A steady-state signal that simply starts at sample 0 (e.g. a sine wave that
        // ramps in across the first granule) should NOT be flagged as a transient —
        // its sub-window energies stay roughly equal, so `minEnergy` is well above
        // the floor. We only flag "burst from silence" when the loud sub-window
        // actually sits next to a silent one (`minEnergy` below the floor), which is
        // the situation pre-echo masking can't paper over.
        let intraOnsetSpike = minEnergy <= energyFloor && maxEnergy > energyFloor
        let intraRatio = minEnergy > energyFloor ? maxEnergy / minEnergy : 0.0
        let interRatio = previousEnergy > energyFloor ? maxEnergy / previousEnergy : 0.0
        let isTransient = intraOnsetSpike
            || intraRatio > ratioThreshold
            || interRatio > ratioThreshold

        previousEnergy = maxEnergy
        return isTransient
    }

    /// Lookahead variant: peek one granule ahead without mutating detector state.
    ///
    /// Used by `MP3Encoder` to decide the *current* granule's block type when a
    /// transient lives in the *next* granule. Mirrors `detectTransient`'s
    /// criteria exactly — same three-sub-window energy analysis, same
    /// `intraOnsetSpike`/`intraRatio`/`interRatio` checks, same `ratioThreshold`
    /// — but reads `previousEnergy` instead of writing it. The point is
    /// symmetry: the lookahead must flag every granule the in-line detector
    /// would flag one call later. Anything weaker lets transients sneak past
    /// (→ pre-echo); anything stronger over-triggers on natural music dynamics
    /// (→ scattering artefacts from spurious short-block sequences).
    ///
    /// Accepts a strided view so the encoder can run this directly over
    /// interleaved input PCM without a deinterleave copy. `sampleCount` is the
    /// granule length in (post-stride) samples; the caller's buffer may extend
    /// further but only the first `sampleCount * stride` slots are read.
    func detectTransientLookahead(
        pcm: UnsafeBufferPointer<Float>,
        sampleCount: Int,
        stride sampleStride: Int = 1
    ) -> Bool {
        let subWindowCount = 3
        let subWindowSize = sampleCount / subWindowCount
        guard subWindowSize > 0 else {
            return false
        }

        var maxEnergy = 0.0
        var minEnergy = Double.greatestFiniteMagnitude
        for windowIndex in 0 ..< subWindowCount {
            var energy = 0.0
            let windowStart = windowIndex * subWindowSize * sampleStride
            for sampleIndex in 0 ..< subWindowSize {
                let sample = Double(pcm[windowStart + sampleIndex * sampleStride])
                energy += sample * sample
            }
            energy /= Double(subWindowSize)
            if energy > maxEnergy {
                maxEnergy = energy
            }
            if energy < minEnergy {
                minEnergy = energy
            }
        }

        let intraOnsetSpike = minEnergy <= energyFloor && maxEnergy > energyFloor
        let intraRatio = minEnergy > energyFloor ? maxEnergy / minEnergy : 0.0
        let interRatio = previousEnergy > energyFloor ? maxEnergy / previousEnergy : 0.0
        return intraOnsetSpike
            || intraRatio > ratioThreshold
            || interRatio > ratioThreshold
    }
}
