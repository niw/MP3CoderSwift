//
//  MP3CoderAVAudioError.swift
//  MP3CoderAVAudio
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

public enum MP3CoderAVAudioError: Error, Equatable, Sendable {
    /// The encoder requires a 32-bit float PCM buffer (the default for AVAudioFile.processingFormat).
    case unsupportedPCMFormat
    /// AVFoundation refused to create an AVAudioFormat or AVAudioPCMBuffer for the given parameters.
    case audioBufferAllocationFailed
}
