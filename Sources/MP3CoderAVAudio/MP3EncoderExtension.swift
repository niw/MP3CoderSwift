//
//  MP3EncoderExtension.swift
//  MP3CoderAVAudio
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import AVFoundation
import Foundation
import MP3Coder

extension MP3Encoder {
    /// Read the audio file at `url` (any format `AVAudioFile` can open) and
    /// encode it to MP3 data, resampling to the nearest MPEG-1 Layer 3 sample
    /// rate when needed. The optional `progress` closure is called with values
    /// in `0.0...1.0`.
    public static func encode(
        url: URL,
        bitrate: Int = 128,
        progress: ((Double) -> Void)? = nil
    ) throws -> Data {
        let audioFile = try AVAudioFile(forReading: url)
        let processingFormat = audioFile.processingFormat
        let frameCapacity = AVAudioFrameCount(audioFile.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCapacity) else {
            throw MP3CoderAVAudioError.audioBufferAllocationFailed
        }
        try audioFile.read(into: buffer)

        return try buffer.encodedMP3Data(bitrate: bitrate, progress: progress)
    }
}
