//
//  TestError.swift
//  MP3CoderTests
//
//  Created by Opus 4.7 on 4/27/26.
//

enum TestError: Error, Equatable {
    case fixtureNotFound(name: String)
    case invalidHeader(reason: String)
    case truncatedFrame
    case unsupportedWAV(reason: String)
}
