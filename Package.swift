// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MP3Coder",
    products: [
        .library(
            name: "MP3Coder",
            targets: [
                "MP3Coder"
            ]
        ),
        .library(
            name: "MP3CoderAVAudio",
            targets: [
                "MP3CoderAVAudio"
            ]
        ),
        .executable(
            name: "mp3coder",
            targets: [
                "MP3CoderCLI"
            ]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.1")
    ],
    targets: [
        .target(
            name: "MP3Coder",
        ),
        .target(
            name: "MP3CoderAVAudio",
            dependencies: [
                .target(name: "MP3Coder")
            ]
        ),
        .executableTarget(
            name: "MP3CoderCLI",
            dependencies: [
                .target(name: "MP3CoderAVAudio"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "MP3CoderTests",
            dependencies: [
                .target(name: "MP3Coder")
            ],
            resources: [
                .copy("Fixtures")
            ]
        )
    ],
    swiftLanguageModes: [
        .v6
    ]
)
