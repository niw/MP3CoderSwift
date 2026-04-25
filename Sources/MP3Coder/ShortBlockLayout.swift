//
//  ShortBlockLayout.swift
//  MP3Coder
//
//  Created by GPT 5.5 and Opus 4.7 on 4/24/26.
//

import Foundation

/// Helpers for the short-block (block_type 2) spectral layout.
///
/// The encoder MDCT writes 18 coefficients per subband in `(subband, window, line)`
/// order: `subbandMajor[subband * 18 + window * 6 + line]`. The MP3 bitstream and the
/// decoder's `requantizeShort` instead expect a band-window-line interleaved layout,
/// where each short scale-factor band groups all three windows together.
///
/// `bitstreamReorderTable` maps a bitstream index to the matching encoder index, so a
/// reorder pass turns the encoder's natural output into the layout the decoder reads back.
enum ShortBlockLayout {
    /// `bitstreamReorderTable[bitstreamIndex]` = corresponding index in subband-major
    /// MDCT output. Built once per sample rate.
    static func bitstreamReorderTable(sampleRate: Int) -> [Int] {
        let shortBandBounds = MP3Constants.scaleFactorBandBoundariesShort(sampleRate: sampleRate)
        var reorder = [Int](repeating: 0, count: 576)
        var bitstreamIndex = 0
        for band in 0 ..< (shortBandBounds.count - 1) {
            let width = shortBandBounds[band + 1] - shortBandBounds[band]
            for windowIndex in 0 ..< 3 {
                for line in 0 ..< width {
                    let globalLine = shortBandBounds[band] + line
                    let subband = globalLine / 6
                    let spectralLine = globalLine % 6
                    let encoderIndex = subband * 18 + windowIndex * 6 + spectralLine
                    if bitstreamIndex < 576 {
                        reorder[bitstreamIndex] = encoderIndex
                    }
                    bitstreamIndex += 1
                }
            }
        }
        return reorder
    }

    /// `bandIndex[bitstreamIndex]` = short scale-factor band that owns this bitstream slot.
    /// Used by the quantizer to apply per-(window, band) scale factors.
    static func bitstreamBandTable(sampleRate: Int) -> [Int] {
        let shortBandBounds = MP3Constants.scaleFactorBandBoundariesShort(sampleRate: sampleRate)
        var bandTable = [Int](repeating: 0, count: 576)
        var bitstreamIndex = 0
        for band in 0 ..< (shortBandBounds.count - 1) {
            let width = shortBandBounds[band + 1] - shortBandBounds[band]
            for _ in 0 ..< 3 {
                for _ in 0 ..< width {
                    if bitstreamIndex < 576 {
                        bandTable[bitstreamIndex] = band
                    }
                    bitstreamIndex += 1
                }
            }
        }
        return bandTable
    }

    /// `windowIndex[bitstreamIndex]` = which short window (0..2) owns this bitstream slot.
    static func bitstreamWindowTable(sampleRate: Int) -> [Int] {
        let shortBandBounds = MP3Constants.scaleFactorBandBoundariesShort(sampleRate: sampleRate)
        var windowTable = [Int](repeating: 0, count: 576)
        var bitstreamIndex = 0
        for band in 0 ..< (shortBandBounds.count - 1) {
            let width = shortBandBounds[band + 1] - shortBandBounds[band]
            for windowIndex in 0 ..< 3 {
                for _ in 0 ..< width {
                    if bitstreamIndex < 576 {
                        windowTable[bitstreamIndex] = windowIndex
                    }
                    bitstreamIndex += 1
                }
            }
        }
        return windowTable
    }
}
