//
//  DecodeCommand.swift
//  MP3CoderCLI
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import ArgumentParser
import Foundation
import MP3Coder
import MP3CoderAVAudio

struct DecodeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "decode",
        abstract: "Decode an MP3 file to WAV"
    )

    @Argument(help: "Input MP3 file")
    var input: String

    @Option(name: .shortAndLong, help: "Output WAV file (default: input with .wav extension)")
    var output: String?

    mutating func run() throws {
        let inputURL = URL(fileURLWithPath: input)
        let outputURL: URL = if let output {
            URL(fileURLWithPath: output)
        } else {
            inputURL.deletingPathExtension().appendingPathExtension("wav")
        }

        print("Decoding \(inputURL.lastPathComponent) to \(outputURL.lastPathComponent) …")

        let data: Data
        do {
            data = try Data(contentsOf: inputURL)
        } catch {
            throw ValidationError("Failed to read MP3 file: \(error)")
        }

        do {
            try MP3Decoder.decode(data: data, to: outputURL)
        } catch {
            throw ValidationError("Failed to decode: \(error)")
        }
    }
}
