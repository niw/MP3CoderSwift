//
//  BenchCommand.swift
//  MP3CoderCLI
//
//  Created by GPT 5.5 and Opus 4.7 on 4/24/26.
//

import ArgumentParser
import AVFoundation
import Foundation
import MP3Coder
import MP3CoderAVAudio

struct BenchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench",
        abstract: "Benchmark the MP3 encoder against an input WAV"
    )

    @Argument(help: "Input WAV file")
    var input: String

    @Option(name: .shortAndLong, help: "Bitrate in kbps (default: 128)")
    var bitrate: Int = 128

    @Option(name: .shortAndLong, help: "Number of timed iterations (default: 5)")
    var iterations: Int = 5

    @Option(name: .long, help: "Warmup iterations to discard (default: 1)")
    var warmup: Int = 1

    mutating func run() throws {
        guard iterations > 0 else {
            throw ValidationError("iterations must be > 0")
        }
        guard warmup >= 0 else {
            throw ValidationError("warmup must be >= 0")
        }

        let inputURL = URL(fileURLWithPath: input)
        let prepared = try loadAndPrepare(url: inputURL)
        let audioSeconds = Double(prepared.samples.count / prepared.channels) / Double(prepared.sampleRate)

        print("Input:        \(inputURL.lastPathComponent)")
        print("Format:       \(prepared.channels) ch, \(prepared.sampleRate) Hz, \(String(format: "%.3f", audioSeconds))s")
        print("Bitrate:      \(bitrate) kbps")
        print("Iterations:   \(iterations) (\(warmup) warmup discarded)")
        print("")

        var iterationWalls: [Double] = []
        var bestProfiler: MP3EncoderProfiler?
        var bestSeconds = Double.infinity
        var encodedBytes = 0

        for iteration in 0 ..< (warmup + iterations) {
            let isWarmup = iteration < warmup
            let label = isWarmup ? "warmup \(iteration + 1)" : "iter   \(iteration - warmup + 1)"

            let profiler = MP3EncoderProfiler()
            let encoder = try MP3Encoder(
                sampleRate: prepared.sampleRate,
                channels: prepared.channels,
                bitrate: bitrate
            )
            encoder.profiler = profiler

            let start = DispatchTime.now()
            var output = encoder.encode(pcm: prepared.samples)
            output.append(encoder.flush())
            let end = DispatchTime.now()
            let seconds = Double(end.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000_000

            let realtimeRatio = seconds > 0 ? audioSeconds / seconds : 0
            print(String(format: "  %@: %.3fs wall (%.2fx realtime)", label, seconds, realtimeRatio))

            if !isWarmup {
                iterationWalls.append(seconds)
                encodedBytes = output.count
                if seconds < bestSeconds {
                    bestSeconds = seconds
                    bestProfiler = profiler
                }
            }
        }

        print("")
        print("Wall-clock summary:")
        let avg = iterationWalls.reduce(0, +) / Double(iterationWalls.count)
        let best = iterationWalls.min() ?? 0
        let worst = iterationWalls.max() ?? 0
        let avgRealtime = avg > 0 ? audioSeconds / avg : 0
        let bestRealtime = best > 0 ? audioSeconds / best : 0
        let worstRealtime = worst > 0 ? audioSeconds / worst : 0
        print(String(format: "  best:   %.3fs (%.2fx realtime)", best, bestRealtime))
        print(String(format: "  avg:    %.3fs (%.2fx realtime)", avg, avgRealtime))
        print(String(format: "  worst:  %.3fs (%.2fx realtime)", worst, worstRealtime))
        print(String(format: "  output: %d bytes", encodedBytes))
        print("")

        if let bestProfiler {
            print("Per-stage breakdown (best iteration):")
            print(bestProfiler.summary(sampleRate: prepared.sampleRate))
        }
    }

    // MARK: - PCM loading

    private struct PreparedPCM {
        var samples: [Float]
        var sampleRate: Int
        var channels: Int
    }

    private func loadAndPrepare(url: URL) throws -> PreparedPCM {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw ValidationError("Failed to open \(url.lastPathComponent): \(error)")
        }
        let processingFormat = audioFile.processingFormat
        let frameCapacity = AVAudioFrameCount(audioFile.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCapacity) else {
            throw ValidationError("Failed to allocate PCM buffer for \(url.lastPathComponent)")
        }
        do {
            try audioFile.read(into: buffer)
        } catch {
            throw ValidationError("Failed to read \(url.lastPathComponent): \(error)")
        }

        let sourceSampleRate = Int(processingFormat.sampleRate)
        let channels = Int(processingFormat.channelCount)
        let frameLength = Int(buffer.frameLength)

        guard let channelData = buffer.floatChannelData else {
            throw ValidationError("\(url.lastPathComponent) is not a 32-bit float PCM source")
        }

        var interleaved = [Float](repeating: 0, count: frameLength * channels)
        interleaved.withUnsafeMutableBufferPointer { destination in
            for channel in 0 ..< channels {
                let source = channelData[channel]
                for frame in 0 ..< frameLength {
                    destination[frame * channels + channel] = source[frame]
                }
            }
        }

        let encodeSampleRate = AVAudioPCMBuffer.mp3EncodingSampleRate(for: sourceSampleRate)
        let encodeSamples: [Float] = if encodeSampleRate == sourceSampleRate {
            interleaved
        } else {
            resampleLinear(
                samples: interleaved,
                channels: channels,
                from: sourceSampleRate,
                to: encodeSampleRate
            )
        }

        return PreparedPCM(samples: encodeSamples, sampleRate: encodeSampleRate, channels: channels)
    }

    // Mirror of MP3CoderAVAudio's internal `Resampler.resample`. Duplicated here
    // so the bench command can prepare PCM once outside the timed loop without
    // depending on the resampler being public.
    private func resampleLinear(
        samples: [Float],
        channels: Int,
        from sourceSampleRate: Int,
        to targetSampleRate: Int
    ) -> [Float] {
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
}
