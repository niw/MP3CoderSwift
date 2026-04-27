//
//  HuffmanTests.swift
//  MP3CoderTests
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

@testable
import MP3Coder
import Testing

@Test
func `Huffman count1 decoder should accept final short code at end of buffer`() throws {
    let (code, bits) = huffmanEncodeQuad(first: 0, second: 0, third: 0, fourth: 0, tableIndex: 0)
    #expect(bits < 10, "Regression setup should exercise padded count1 lookup")

    let writer = BitstreamWriter()
    writer.writeBits(code, count: bits)
    let encoded = writer.toData()

    try encoded.withUnsafeBytes { rawBuffer in
        let reader = BitstreamReader(bytes: rawBuffer.bindMemory(to: UInt8.self))
        let quad = try huffmanDecodeQuad(reader: reader, tableIndex: 0)
        #expect(quad.first == 0)
        #expect(quad.second == 0)
        #expect(quad.third == 0)
        #expect(quad.fourth == 0)
        #expect(reader.bitPosition == bits)
    }
}
