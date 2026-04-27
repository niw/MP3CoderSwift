//
//  BitstreamWriter.swift
//  MP3Coder
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import Foundation

/// Writes bits MSB-first into a byte buffer using a 64-bit accumulator.
///
/// Invariant after every public call: `bitsInAccumulator < 8`. Callers may therefore
/// push up to 56 bits per `writeBits` call without losing data.
final class BitstreamWriter {
    private var output: ContiguousArray<UInt8>
    private var accumulator: UInt64 = 0
    private var bitsInAccumulator: Int = 0

    init(reserveBytes: Int = 0) {
        output = ContiguousArray<UInt8>()
        if reserveBytes > 0 {
            output.reserveCapacity(reserveBytes)
        }
    }

    /// Write the low `count` bits of `value` MSB-first. `count` must be in 0...56.
    @inline(__always)
    func writeBits(_ value: UInt64, count: Int) {
        guard count > 0 else {
            return
        }
        let masked = count >= 64 ? value : (value & ((UInt64(1) << count) - 1))
        accumulator = (accumulator << count) | masked
        bitsInAccumulator += count
        while bitsInAccumulator >= 8 {
            bitsInAccumulator -= 8
            output.append(UInt8(truncatingIfNeeded: accumulator >> bitsInAccumulator))
        }
    }

    @inline(__always)
    func writeBits(_ value: Int, count: Int) {
        writeBits(UInt64(bitPattern: Int64(value)), count: count)
    }

    @inline(__always)
    func writeBit(_ value: Int) {
        writeBits(UInt64(value & 1), count: 1)
    }

    /// Pad to byte boundary with zeros.
    func byteAlign() {
        if bitsInAccumulator > 0 {
            writeBits(UInt64(0), count: 8 - bitsInAccumulator)
        }
    }

    /// Finalize and return bytes. The trailing partial byte (if any) is MSB-aligned and zero-padded.
    func toData() -> Data {
        if bitsInAccumulator == 0 {
            return output.withUnsafeBufferPointer { Data($0) }
        }
        let trailingByte = UInt8(truncatingIfNeeded: (accumulator << (8 - bitsInAccumulator)) & 0xFF)
        var result = Data(capacity: output.count + 1)
        output.withUnsafeBufferPointer { result.append($0.baseAddress!, count: output.count) }
        result.append(trailingByte)
        return result
    }

    func reset() {
        output.removeAll(keepingCapacity: true)
        accumulator = 0
        bitsInAccumulator = 0
    }
}
