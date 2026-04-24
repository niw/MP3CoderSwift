//
//  Resampler.swift
//  MP3CoderAVAudio
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import Foundation

/// Linear-interpolation resampler for PCM audio.
enum Resampler {
    /// Resample interleaved PCM from `sourceSampleRate` to `targetSampleRate`.
    static func resample(
        samples: [Float],
        channels: Int,
        from sourceSampleRate: Int,
        to targetSampleRate: Int
    ) -> [Float] {
        guard sourceSampleRate != targetSampleRate else {
            return samples
        }

        let sourceFrames = samples.count / channels
        let ratio = Double(sourceSampleRate) / Double(targetSampleRate)
        let targetFrames = Int((Double(sourceFrames) / ratio).rounded(.up))

        var output = [Float](repeating: 0, count: targetFrames * channels)

        for frame in 0 ..< targetFrames {
            let sourcePosition = Double(frame) * ratio
            let sourceLowerFrame = Int(sourcePosition)
            let sourceUpperFrame = min(sourceLowerFrame + 1, sourceFrames - 1)
            let fraction = Float(sourcePosition - Double(sourceLowerFrame))

            for channel in 0 ..< channels {
                let lowerSample = samples[sourceLowerFrame * channels + channel]
                let upperSample = samples[sourceUpperFrame * channels + channel]
                output[frame * channels + channel] = lowerSample + fraction * (upperSample - lowerSample)
            }
        }

        return output
    }

    /// Return the MPEG-1 supported sample rate nearest to `rate`.
    static func nearestSupportedRate(_ rate: Int) -> Int {
        let supported = [32000, 44100, 48000]
        if supported.contains(rate * 2) {
            return rate * 2
        }
        return supported.min(by: { abs($0 - rate) < abs($1 - rate) })!
    }
}
