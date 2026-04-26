//
//  MP3CoderCLI.swift
//  MP3CoderCLI
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import ArgumentParser

@main
struct MP3CoderCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        subcommands: [EncodeCommand.self, DecodeCommand.self]
    )
}
