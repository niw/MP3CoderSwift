//
//  EncodeCommand.swift
//  MP3CoderCLI
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import ArgumentParser
import Foundation
import MP3Coder
import MP3CoderAVAudio

struct EncodeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "encode",
        abstract: "Encode a WAV file to MP3"
    )

    @Argument(help: "Input WAV file")
    var input: String

    @Option(name: .shortAndLong, help: "Output MP3 file (default: input with .mp3 extension)")
    var output: String?

    @Option(name: .shortAndLong, help: "Bitrate in kbps: 32/40/48/56/64/80/96/112/128/160/192/224/256/320 (default: 128)")
    var bitrate: Int = 128

    mutating func run() throws {
        let inputURL = URL(fileURLWithPath: input)
        let outputURL: URL = if let outputPath = output {
            URL(fileURLWithPath: outputPath)
        } else {
            inputURL.deletingPathExtension().appendingPathExtension("mp3")
        }

        print("Encoding \(inputURL.lastPathComponent) to \(outputURL.lastPathComponent) at \(bitrate) kbps …")

        let encoded: Data
        do {
            encoded = try MP3Encoder.encode(url: inputURL, bitrate: bitrate) { progress in
                let percent = Int(progress * 100)
                let filledCellCount = percent / 5
                let progressBar = String(repeating: "█", count: filledCellCount) + String(repeating: "░", count: 20 - filledCellCount)
                print("\r\(progressBar) \(percent)%", terminator: "")
                fflush(stdout)
            }
        } catch MP3EncoderError.unsupportedBitrate(let unsupportedBitrate) {
            throw ValidationError("Unsupported bitrate \(unsupportedBitrate) kbps. Supported: 32/40/48/56/64/80/96/112/128/160/192/224/256/320")
        } catch MP3EncoderError.unsupportedChannelCount(let channelCount) {
            throw ValidationError("Unsupported channel count \(channelCount). Supported: 1 (mono), 2 (stereo)")
        } catch {
            throw ValidationError("Failed to encode: \(error)")
        }

        print("\r\(String(repeating: "█", count: 20)) 100%")

        do {
            try encoded.write(to: outputURL)
        } catch {
            throw ValidationError("Failed to write output file: \(error)")
        }
    }
}
