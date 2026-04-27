//
//  AVAudioPCMBufferExtension.swift
//  MP3CoderAVAudio
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import AVFoundation
import Foundation
import MP3Coder

extension AVAudioPCMBuffer {
    /// Returns the MPEG-1 Layer 3 sample rate the encoder will use for input at
    /// the given source rate. If `sourceSampleRate` is already supported it is
    /// returned unchanged; otherwise the nearest supported rate is returned.
    public static func mp3EncodingSampleRate(for sourceSampleRate: Int) -> Int {
        Resampler.nearestSupportedRate(sourceSampleRate)
    }

    /// Encode this buffer (32-bit float, non-interleaved — i.e. the default
    /// format produced by `AVAudioFile.processingFormat`) to MP3 data.
    ///
    /// Resamples to the nearest MPEG-1 Layer 3 sample rate when needed.
    /// The optional `progress` closure is called with values in `0.0...1.0`.
    public func encodedMP3Data(
        bitrate: Int = 128,
        progress: ((Double) -> Void)? = nil
    ) throws -> Data {
        let sourceSampleRate = Int(format.sampleRate)
        let channels = Int(format.channelCount)
        let frameLength = Int(frameLength)

        guard let channelData = floatChannelData else {
            throw MP3CoderAVAudioError.unsupportedPCMFormat
        }

        // Interleave the deinterleaved channel buffers into a single [Float].
        var interleaved = [Float](repeating: 0, count: frameLength * channels)
        interleaved.withUnsafeMutableBufferPointer { destination in
            for channel in 0 ..< channels {
                let source = channelData[channel]
                for frame in 0 ..< frameLength {
                    destination[frame * channels + channel] = source[frame]
                }
            }
        }

        // Resample to a rate that MPEG-1 Layer 3 supports if necessary.
        let encodeSampleRate = Resampler.nearestSupportedRate(sourceSampleRate)
        let encodeSamples: [Float] = if encodeSampleRate != sourceSampleRate {
            Resampler.resample(
                samples: interleaved,
                channels: channels,
                from: sourceSampleRate,
                to: encodeSampleRate
            )
        } else {
            interleaved
        }

        let encoder = try MP3Encoder(
            sampleRate: encodeSampleRate,
            channels: channels,
            bitrate: bitrate
        )

        // 1-second chunks so progress callbacks fire reasonably often.
        let chunkSamples = channels * encodeSampleRate
        let totalSamples = encodeSamples.count
        var encoded = Data()
        var samplesProcessed = 0
        var chunkStart = 0

        while chunkStart < totalSamples {
            let chunkEnd = min(chunkStart + chunkSamples, totalSamples)
            let chunk = Array(encodeSamples[chunkStart ..< chunkEnd])
            encoded.append(encoder.encode(pcm: chunk))
            samplesProcessed += chunk.count
            chunkStart = chunkEnd

            if let progress {
                progress(Double(samplesProcessed) / Double(totalSamples))
            }
        }

        encoded.append(encoder.flush())

        if let progress {
            progress(1.0)
        }

        return encoded
    }

    /// Decode MP3 data into a new 32-bit float, non-interleaved
    /// `AVAudioPCMBuffer` (matching the default `AVAudioFile.processingFormat`).
    public static func decodingMP3Data(_ data: Data) throws -> AVAudioPCMBuffer {
        let decoded = try MP3Decoder().decode(data)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(decoded.sampleRate),
            channels: AVAudioChannelCount(decoded.channels),
            interleaved: false
        ) else {
            throw MP3CoderAVAudioError.audioBufferAllocationFailed
        }

        let channels = decoded.channels
        let frameLength = decoded.samples.count / channels
        let frameCount = AVAudioFrameCount(frameLength)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw MP3CoderAVAudioError.audioBufferAllocationFailed
        }
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData else {
            throw MP3CoderAVAudioError.unsupportedPCMFormat
        }

        // Deinterleave the encoder's interleaved samples into per-channel buffers.
        decoded.samples.withUnsafeBufferPointer { source in
            for channel in 0 ..< channels {
                let destination = channelData[channel]
                for frame in 0 ..< frameLength {
                    destination[frame] = source[frame * channels + channel]
                }
            }
        }

        return buffer
    }
}
