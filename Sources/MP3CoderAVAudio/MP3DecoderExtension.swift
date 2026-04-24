//
//  MP3DecoderExtension.swift
//  MP3CoderAVAudio
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import AVFoundation
import Foundation
import MP3Coder

extension MP3Decoder {
    /// Decode `data` (MP3) and write the result as a 16-bit PCM WAV file at
    /// `url`. The output's sample rate and channel count match the decoded
    /// stream.
    public static func decode(data: Data, to url: URL) throws {
        let buffer = try AVAudioPCMBuffer.decodingMP3Data(data)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: buffer.format.sampleRate,
            AVNumberOfChannelsKey: buffer.format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let outputFile = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: buffer.format.commonFormat,
            interleaved: buffer.format.isInterleaved
        )

        try outputFile.write(from: buffer)
    }
}
