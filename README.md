MP3CoderSwift
=============

A plain Swift MPEG-1 Layer 3 (MP3) encoder and decoder implementation.
All code is written with the assistance of coding agents based on the MP3
specification.


Usage
-----

In your `Package.swift` or in Xcode, add the `MP3CoderSwift` Swift package and
add the `MP3Coder` or `MP3CoderAVAudio` library to your target.

- `MP3Coder` provides plain MP3 encoding and decoding logic that can be
  used for raw sample buffers.

- `MP3CoderAVAudio` provides extensions to `AVAudioPCMBuffer` and also offers
  simple `encode(url:)` and `decode(data:url:)` methods for PCM (WAV) files.

```swift
let package = Package(
    // ...
    dependencies: [
        // Add Swift Package
        .package(url: "https://github.com/niw/MP3CoderSwift.git", branch: "master")
    ],
    // ...
    .target(
        // Add dependency
        dependencies: [
            .product(name: "MP3CoderAVAudio", package: "MP3CoderSwift")
        ]
    )
    // ...
)
```

Then encode to or decode from MP3 with the following code.

```swift
import MP3Coder
import MP3CoderAVAudio

// Encode to MP3
let inputURL = URL(fileURLWithPath: "/path/to/wav")
let mp3Data = try MP3Encoder.encode(url: inputURL)

// Decode from MP3
let outputURL = URL(fileURLWithPath: "/path/to/wav")
try MP3Decoder.decode(data: data, to: outputURL)
```


### Command line interface

There is a simple CLI command for testing.

Prepare a WAV file and use the following command.
Use the `release` configuration for testing because `debug` is really slow.

```shell
# Encode a WAV file
swift run -c release mp3coder-cli encode --output encoded.mp3 input.wav

# Decode an MP3 file
swift run -c release mp3coder-cli decode --output decoded.wav encoded.mp3
```
