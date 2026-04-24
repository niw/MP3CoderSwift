//
//  BitstreamReader.swift
//  MP3Coder
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import Foundation

enum BitstreamReaderError: Error {
    case endOfData
}

/// MSB-first bit reader backed by a 64-bit accumulator.
///
/// `accumulator` always holds the next-to-read bits in its most-significant-bit side:
/// bit 63 is the next bit to read, bit `63 - bitsInAccumulator + 1` is the last valid bit.
/// The reader fetches one byte at a time from `bytes` into the low end (via a shift)
/// whenever `bitsInAccumulator <= 56` and more data is available.
///
/// Storage is non-owning. The caller must keep the underlying buffer alive for the lifetime
/// of the reader (e.g. by constructing the reader inside a `withUnsafeBufferPointer` block).
final class BitstreamReader {
    private let bytesPointer: UnsafePointer<UInt8>
    private let totalByteCount: Int
    private var byteIndex: Int = 0
    private var accumulator: UInt64 = 0
    private var bitsInAccumulator: Int = 0

    init(bytes: UnsafePointer<UInt8>, count: Int, bitPosition: Int = 0) {
        bytesPointer = bytes
        totalByteCount = count
        if bitPosition > 0 {
            try? seek(bitPosition: bitPosition)
        }
    }

    var totalBits: Int {
        totalByteCount * 8
    }

    var bitPosition: Int {
        byteIndex * 8 - bitsInAccumulator
    }

    var bitsRemaining: Int {
        totalBits - bitPosition
    }

    /// Fill `accumulator` with up to 56 bits from the byte stream (leaves at least 8 bits of headroom
    /// for the shift to avoid touching bit 64).
    @inline(__always)
    private func refill() {
        while bitsInAccumulator <= 56, byteIndex < totalByteCount {
            accumulator |= UInt64(bytesPointer[byteIndex]) << (56 - bitsInAccumulator)
            bitsInAccumulator += 8
            byteIndex += 1
        }
    }

    /// Peek at the next `count` bits without consuming them. `count` must be ≤ 57.
    @inline(__always)
    func peekBits(_ count: Int) throws -> Int {
        if bitsInAccumulator < count {
            refill()
            if bitsInAccumulator < count {
                throw BitstreamReaderError.endOfData
            }
        }
        return Int(accumulator >> (64 - count))
    }

    /// Consume `count` bits that have already been peeked. `count` must be ≤ bitsInAccumulator.
    @inline(__always)
    func consumeBits(_ count: Int) {
        accumulator <<= count
        bitsInAccumulator -= count
    }

    /// Read `count` bits, MSB-first. `count` must be ≤ 57.
    @inline(__always)
    func readBits(_ count: Int) throws -> Int {
        guard count >= 0 else {
            return 0
        }
        if count == 0 {
            return 0
        }
        let value = try peekBits(count)
        consumeBits(count)
        return value
    }

    @inline(__always)
    func readBit() throws -> Int {
        try readBits(1)
    }

    func skipBits(_ count: Int) throws {
        guard count >= 0 else {
            return
        }
        if count <= bitsInAccumulator {
            consumeBits(count)
            return
        }
        var remainingBits = count - bitsInAccumulator
        bitsInAccumulator = 0
        accumulator = 0
        let byteJump = remainingBits / 8
        if byteIndex + byteJump > totalByteCount {
            throw BitstreamReaderError.endOfData
        }
        byteIndex += byteJump
        remainingBits -= byteJump * 8
        if remainingBits > 0 {
            refill()
            if bitsInAccumulator < remainingBits {
                throw BitstreamReaderError.endOfData
            }
            consumeBits(remainingBits)
        }
    }

    func seek(bitPosition: Int) throws {
        guard bitPosition >= 0, bitPosition <= totalBits else {
            throw BitstreamReaderError.endOfData
        }
        byteIndex = bitPosition / 8
        bitsInAccumulator = 0
        accumulator = 0
        let bitOffset = bitPosition & 7
        if bitOffset > 0 {
            refill()
            if bitsInAccumulator < bitOffset {
                throw BitstreamReaderError.endOfData
            }
            consumeBits(bitOffset)
        }
    }
}
