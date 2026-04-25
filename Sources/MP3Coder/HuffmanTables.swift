//
//  HuffmanTables.swift
//  MP3Coder
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import Foundation

private struct PairHuffmanTable {
    var xlen: Int
    var linbits: Int
    var linmax: Int
    /// Total bits for the base symbol, including sign bits but excluding linbits.
    var lengths: [Int]
    /// Huffman code bits for the base symbol without sign bits or linbits.
    var codes: [Int]

    var maxBaseValue: Int {
        xlen - 1
    }
}

private struct QuadHuffmanTable {
    /// Total bits for the base symbol, including sign bits.
    var lengths: [Int]
    /// Huffman code bits shifted left by the number of sign bits for the pattern.
    var codes: [Int]
}

private func makePairTable(xlen: Int, linbits: Int = 0, lengths: [Int], codes: [Int]) -> PairHuffmanTable {
    PairHuffmanTable(
        xlen: xlen,
        linbits: linbits,
        linmax: linbits == 0 ? 0 : (1 << linbits) - 1,
        lengths: lengths,
        codes: codes
    )
}

private let pairTables: [Int: PairHuffmanTable] = {
    var tables: [Int: PairHuffmanTable] = [
        0: makePairTable(
            xlen: 1,
            lengths: [0],
            codes: [0]
        ),
        1: makePairTable(
            xlen: 2,
            lengths: [
                1, 4,
                3, 5,
            ],
            codes: [
                1, 1,
                1, 0,
            ]
        ),
        2: makePairTable(
            xlen: 3,
            lengths: [
                1, 4, 7,
                4, 5, 7,
                6, 7, 8,
            ],
            codes: [
                1, 2, 1,
                3, 1, 1,
                3, 2, 0,
            ]
        ),
        3: makePairTable(
            xlen: 3,
            lengths: [
                2, 3, 7,
                4, 4, 7,
                6, 7, 8,
            ],
            codes: [
                3, 2, 1,
                1, 1, 1,
                3, 2, 0,
            ]
        ),
        5: makePairTable(
            xlen: 4,
            lengths: [
                1, 4, 7, 8,
                4, 5, 8, 9,
                7, 8, 9, 10,
                8, 8, 9, 10,
            ],
            codes: [
                1, 2, 6, 5,
                3, 1, 4, 4,
                7, 5, 7, 1,
                6, 1, 1, 0,
            ]
        ),
        6: makePairTable(
            xlen: 4,
            lengths: [
                3, 4, 6, 8,
                4, 4, 6, 7,
                5, 6, 7, 8,
                7, 7, 8, 9,
            ],
            codes: [
                7, 3, 5, 1,
                6, 2, 3, 2,
                5, 4, 4, 1,
                3, 3, 2, 0,
            ]
        ),
        7: makePairTable(
            xlen: 6,
            lengths: [
                1, 4, 7, 9, 9, 10,
                4, 6, 8, 9, 9, 10,
                7, 7, 9, 10, 10, 11,
                8, 9, 10, 11, 11, 11,
                8, 9, 10, 11, 11, 12,
                9, 10, 11, 12, 12, 12,
            ],
            codes: [
                1, 2, 10, 19, 16, 10,
                3, 3, 7, 10, 5, 3,
                11, 4, 13, 17, 8, 4,
                12, 11, 18, 15, 11, 2,
                7, 6, 9, 14, 3, 1,
                6, 4, 5, 3, 2, 0,
            ]
        ),
        8: makePairTable(
            xlen: 6,
            lengths: [
                2, 4, 7, 9, 9, 10,
                4, 4, 6, 10, 10, 10,
                7, 6, 8, 10, 10, 11,
                9, 10, 10, 11, 11, 12,
                9, 9, 10, 11, 12, 12,
                10, 10, 11, 11, 13, 13,
            ],
            codes: [
                3, 4, 6, 18, 12, 5,
                5, 1, 2, 16, 9, 3,
                7, 3, 5, 14, 7, 3,
                19, 17, 15, 13, 10, 4,
                13, 5, 8, 11, 5, 1,
                12, 4, 4, 1, 1, 0,
            ]
        ),
        9: makePairTable(
            xlen: 6,
            lengths: [
                3, 4, 6, 7, 9, 10,
                4, 5, 6, 7, 8, 10,
                5, 6, 7, 8, 9, 10,
                7, 7, 8, 9, 9, 10,
                8, 8, 9, 9, 10, 11,
                9, 9, 10, 10, 11, 11,
            ],
            codes: [
                7, 5, 9, 14, 15, 7,
                6, 4, 5, 5, 6, 7,
                7, 6, 8, 8, 8, 5,
                15, 6, 9, 10, 5, 1,
                11, 7, 9, 6, 4, 1,
                14, 4, 6, 2, 6, 0,
            ]
        ),
        10: makePairTable(
            xlen: 8,
            lengths: [
                1, 4, 7, 9, 10, 10, 10, 11,
                4, 6, 8, 9, 10, 11, 10, 10,
                7, 8, 9, 10, 11, 12, 11, 11,
                8, 9, 10, 11, 12, 12, 11, 12,
                9, 10, 11, 12, 12, 12, 12, 12,
                10, 11, 12, 12, 13, 13, 12, 13,
                9, 10, 11, 12, 12, 12, 13, 13,
                10, 10, 11, 12, 12, 13, 13, 13,
            ],
            codes: [
                1, 2, 10, 23, 35, 30, 12, 17,
                3, 3, 8, 12, 18, 21, 12, 7,
                11, 9, 15, 21, 32, 40, 19, 6,
                14, 13, 22, 34, 46, 23, 18, 7,
                20, 19, 33, 47, 27, 22, 9, 3,
                31, 22, 41, 26, 21, 20, 5, 3,
                14, 13, 10, 11, 16, 6, 5, 1,
                9, 8, 7, 8, 4, 4, 2, 0,
            ]
        ),
        11: makePairTable(
            xlen: 8,
            lengths: [
                2, 4, 6, 8, 9, 10, 9, 10,
                4, 5, 6, 8, 10, 10, 9, 10,
                6, 7, 8, 9, 10, 11, 10, 10,
                8, 8, 9, 11, 10, 12, 10, 11,
                9, 10, 10, 11, 11, 12, 11, 12,
                9, 10, 11, 12, 12, 13, 12, 13,
                9, 9, 9, 10, 11, 12, 12, 12,
                9, 9, 10, 11, 12, 12, 12, 12,
            ],
            codes: [
                3, 4, 10, 24, 34, 33, 21, 15,
                5, 3, 4, 10, 32, 17, 11, 10,
                11, 7, 13, 18, 30, 31, 20, 5,
                25, 11, 19, 59, 27, 18, 12, 5,
                35, 33, 31, 58, 30, 16, 7, 5,
                28, 26, 32, 19, 17, 15, 8, 14,
                14, 12, 9, 13, 14, 9, 4, 1,
                11, 4, 6, 6, 6, 3, 2, 0,
            ]
        ),
        12: makePairTable(
            xlen: 8,
            lengths: [
                4, 4, 6, 8, 9, 10, 10, 10,
                4, 5, 6, 7, 9, 9, 10, 10,
                6, 6, 7, 8, 9, 10, 9, 10,
                7, 7, 8, 8, 9, 10, 10, 10,
                8, 8, 9, 9, 10, 10, 10, 11,
                9, 9, 10, 10, 10, 11, 10, 11,
                9, 9, 9, 10, 10, 11, 11, 12,
                10, 10, 10, 11, 11, 11, 11, 12,
            ],
            codes: [
                9, 6, 16, 33, 41, 39, 38, 26,
                7, 5, 6, 9, 23, 16, 26, 11,
                17, 7, 11, 14, 21, 30, 10, 7,
                17, 10, 15, 12, 18, 28, 14, 5,
                32, 13, 22, 19, 18, 16, 9, 5,
                40, 17, 31, 29, 17, 13, 4, 2,
                27, 12, 11, 15, 10, 7, 4, 1,
                27, 12, 8, 12, 6, 3, 1, 0,
            ]
        ),
        13: makePairTable(
            xlen: 16,
            lengths: [
                1, 5, 7, 8, 9, 10, 10, 11, 10, 11, 12, 12, 13, 13, 14, 14,
                4, 6, 8, 9, 10, 10, 11, 11, 11, 11, 12, 12, 13, 14, 14, 14,
                7, 8, 9, 10, 11, 11, 12, 12, 11, 12, 12, 13, 13, 14, 15, 15,
                8, 9, 10, 11, 11, 12, 12, 12, 12, 13, 13, 13, 13, 14, 15, 15,
                9, 9, 11, 11, 12, 12, 13, 13, 12, 13, 13, 14, 14, 15, 15, 16,
                10, 10, 11, 12, 12, 12, 13, 13, 13, 13, 14, 13, 15, 15, 16, 16,
                10, 11, 12, 12, 13, 13, 13, 13, 13, 14, 14, 14, 15, 15, 16, 16,
                11, 11, 12, 13, 13, 13, 14, 14, 14, 14, 15, 15, 15, 16, 18, 18,
                10, 10, 11, 12, 12, 13, 13, 14, 14, 14, 14, 15, 15, 16, 17, 17,
                11, 11, 12, 12, 13, 13, 13, 15, 14, 15, 15, 16, 16, 16, 18, 17,
                11, 12, 12, 13, 13, 14, 14, 15, 14, 15, 16, 15, 16, 17, 18, 19,
                12, 12, 12, 13, 14, 14, 14, 14, 15, 15, 15, 16, 17, 17, 17, 18,
                12, 13, 13, 14, 14, 15, 14, 15, 16, 16, 17, 17, 17, 18, 18, 18,
                13, 13, 14, 15, 15, 15, 16, 16, 16, 16, 16, 17, 18, 17, 18, 18,
                14, 14, 14, 15, 15, 15, 17, 16, 16, 19, 17, 17, 17, 19, 18, 18,
                13, 14, 15, 16, 16, 16, 17, 16, 17, 17, 18, 18, 21, 20, 21, 18,
            ],
            codes: [
                1, 5, 14, 21, 34, 51, 46, 71, 42, 52, 68, 52, 67, 44, 43, 19,
                3, 4, 12, 19, 31, 26, 44, 33, 31, 24, 32, 24, 31, 35, 22, 14,
                15, 13, 23, 36, 59, 49, 77, 65, 29, 40, 30, 40, 27, 33, 42, 16,
                22, 20, 37, 61, 56, 79, 73, 64, 43, 76, 56, 37, 26, 31, 25, 14,
                35, 16, 60, 57, 97, 75, 114, 91, 54, 73, 55, 41, 48, 53, 23, 24,
                58, 27, 50, 96, 76, 70, 93, 84, 77, 58, 79, 29, 74, 49, 41, 17,
                47, 45, 78, 74, 115, 94, 90, 79, 69, 83, 71, 50, 59, 38, 36, 15,
                72, 34, 56, 95, 92, 85, 91, 90, 86, 73, 77, 65, 51, 44, 43, 42,
                43, 20, 30, 44, 55, 78, 72, 87, 78, 61, 46, 54, 37, 30, 20, 16,
                53, 25, 41, 37, 44, 59, 54, 81, 66, 76, 57, 54, 37, 18, 39, 11,
                35, 33, 31, 57, 42, 82, 72, 80, 47, 58, 55, 21, 22, 26, 38, 22,
                53, 25, 23, 38, 70, 60, 51, 36, 55, 26, 34, 23, 27, 14, 9, 7,
                34, 32, 28, 39, 49, 75, 30, 52, 48, 40, 52, 28, 18, 17, 9, 5,
                45, 21, 34, 64, 56, 50, 49, 45, 31, 19, 12, 15, 10, 7, 6, 3,
                48, 23, 20, 39, 36, 35, 53, 21, 16, 23, 13, 10, 6, 1, 4, 2,
                16, 15, 17, 27, 25, 20, 29, 11, 17, 12, 16, 8, 1, 1, 0, 1,
            ]
        ),
        15: makePairTable(
            xlen: 16,
            lengths: [
                3, 5, 6, 8, 8, 9, 10, 10, 10, 11, 11, 12, 12, 12, 13, 14,
                5, 5, 7, 8, 9, 9, 10, 10, 10, 11, 11, 12, 12, 12, 13, 13,
                6, 7, 7, 8, 9, 9, 10, 10, 10, 11, 11, 12, 12, 13, 13, 13,
                7, 8, 8, 9, 9, 10, 10, 11, 11, 11, 12, 12, 12, 13, 13, 13,
                8, 8, 9, 9, 10, 10, 11, 11, 11, 11, 12, 12, 12, 13, 13, 13,
                9, 9, 9, 10, 10, 10, 11, 11, 11, 11, 12, 12, 13, 13, 13, 14,
                10, 9, 10, 10, 10, 11, 11, 11, 11, 12, 12, 12, 13, 13, 14, 14,
                10, 10, 10, 11, 11, 11, 11, 12, 12, 12, 12, 12, 13, 13, 13, 14,
                10, 10, 10, 11, 11, 11, 11, 12, 12, 12, 12, 13, 13, 14, 14, 14,
                10, 10, 11, 11, 11, 11, 12, 12, 12, 13, 13, 13, 13, 14, 14, 14,
                11, 11, 11, 11, 12, 12, 12, 12, 12, 13, 13, 13, 13, 14, 15, 14,
                11, 11, 11, 11, 12, 12, 12, 12, 13, 13, 13, 13, 14, 14, 14, 15,
                12, 12, 11, 12, 12, 12, 13, 13, 13, 13, 13, 13, 14, 14, 15, 15,
                12, 12, 12, 12, 12, 13, 13, 13, 13, 14, 14, 14, 14, 14, 15, 15,
                13, 13, 13, 13, 13, 13, 13, 13, 14, 14, 14, 14, 15, 15, 14, 15,
                13, 13, 13, 13, 13, 13, 13, 14, 14, 14, 14, 14, 15, 15, 15, 15,
            ],
            codes: [
                7, 12, 18, 53, 47, 76, 124, 108, 89, 123, 108, 119, 107, 81, 122, 63,
                13, 5, 16, 27, 46, 36, 61, 51, 42, 70, 52, 83, 65, 41, 59, 36,
                19, 17, 15, 24, 41, 34, 59, 48, 40, 64, 50, 78, 62, 80, 56, 33,
                29, 28, 25, 43, 39, 63, 55, 93, 76, 59, 93, 72, 54, 75, 50, 29,
                52, 22, 42, 40, 67, 57, 95, 79, 72, 57, 89, 69, 49, 66, 46, 27,
                77, 37, 35, 66, 58, 52, 91, 74, 62, 48, 79, 63, 90, 62, 40, 38,
                125, 32, 60, 56, 50, 92, 78, 65, 55, 87, 71, 51, 73, 51, 70, 30,
                109, 53, 49, 94, 88, 75, 66, 122, 91, 73, 56, 42, 64, 44, 21, 25,
                90, 43, 41, 77, 73, 63, 56, 92, 77, 66, 47, 67, 48, 53, 36, 20,
                71, 34, 67, 60, 58, 49, 88, 76, 67, 106, 71, 54, 38, 39, 23, 15,
                109, 53, 51, 47, 90, 82, 58, 57, 48, 72, 57, 41, 23, 27, 62, 9,
                86, 42, 40, 37, 70, 64, 52, 43, 70, 55, 42, 25, 29, 18, 11, 11,
                118, 68, 30, 55, 50, 46, 74, 65, 49, 39, 24, 16, 22, 13, 14, 7,
                91, 44, 39, 38, 34, 63, 52, 45, 31, 52, 28, 19, 14, 8, 9, 3,
                123, 60, 58, 53, 47, 43, 32, 22, 37, 24, 17, 12, 15, 10, 2, 1,
                71, 37, 34, 30, 28, 20, 17, 26, 21, 16, 10, 6, 8, 6, 2, 0,
            ]
        ),
        16: makePairTable(
            xlen: 16,
            linbits: 1,
            lengths: [
                1, 5, 7, 9, 10, 10, 11, 11, 12, 12, 12, 13, 13, 13, 14, 10,
                4, 6, 8, 9, 10, 11, 11, 11, 12, 12, 12, 13, 14, 13, 14, 10,
                7, 8, 9, 10, 11, 11, 12, 12, 13, 12, 13, 13, 13, 14, 14, 11,
                9, 9, 10, 11, 11, 12, 12, 12, 13, 13, 14, 14, 14, 15, 15, 12,
                10, 10, 11, 11, 12, 12, 13, 13, 13, 14, 14, 14, 15, 15, 15, 11,
                10, 10, 11, 11, 12, 13, 13, 14, 13, 14, 14, 15, 15, 15, 16, 12,
                11, 11, 11, 12, 13, 13, 13, 13, 14, 14, 14, 14, 15, 15, 16, 12,
                11, 11, 12, 12, 13, 13, 13, 14, 14, 15, 15, 15, 15, 17, 17, 12,
                11, 12, 12, 13, 13, 13, 14, 14, 15, 15, 15, 15, 16, 16, 16, 12,
                12, 12, 12, 13, 13, 14, 14, 15, 15, 15, 15, 16, 15, 16, 15, 13,
                12, 13, 12, 13, 14, 14, 14, 14, 15, 16, 16, 16, 17, 17, 16, 12,
                13, 13, 13, 13, 14, 14, 15, 16, 16, 16, 16, 16, 16, 15, 16, 13,
                13, 14, 14, 14, 14, 15, 15, 15, 15, 17, 16, 16, 16, 16, 18, 13,
                15, 14, 14, 14, 15, 15, 16, 16, 16, 18, 17, 17, 17, 19, 17, 13,
                14, 15, 13, 14, 16, 16, 15, 16, 16, 17, 18, 17, 19, 17, 16, 13,
                10, 10, 10, 11, 11, 12, 12, 12, 13, 13, 13, 13, 13, 13, 13, 10,
            ],
            codes: [
                1, 5, 14, 44, 74, 63, 110, 93, 172, 149, 138, 242, 225, 195, 376, 17,
                3, 4, 12, 20, 35, 62, 53, 47, 83, 75, 68, 119, 201, 107, 207, 9,
                15, 13, 23, 38, 67, 58, 103, 90, 161, 72, 127, 117, 110, 209, 206, 16,
                45, 21, 39, 69, 64, 114, 99, 87, 158, 140, 252, 212, 199, 387, 365, 26,
                75, 36, 68, 65, 115, 101, 179, 164, 155, 264, 246, 226, 395, 382, 362, 9,
                66, 30, 59, 56, 102, 185, 173, 265, 142, 253, 232, 400, 388, 378, 445, 16,
                111, 54, 52, 100, 184, 178, 160, 133, 257, 244, 228, 217, 385, 366, 715, 10,
                98, 48, 91, 88, 165, 157, 148, 261, 248, 407, 397, 372, 380, 889, 884, 8,
                85, 84, 81, 159, 156, 143, 260, 249, 427, 401, 392, 383, 727, 713, 708, 7,
                154, 76, 73, 141, 131, 256, 245, 426, 406, 394, 384, 735, 359, 710, 352, 11,
                139, 129, 67, 125, 247, 233, 229, 219, 393, 743, 737, 720, 885, 882, 439, 4,
                243, 120, 118, 115, 227, 223, 396, 746, 742, 736, 721, 712, 706, 223, 436, 6,
                202, 224, 222, 218, 216, 389, 386, 381, 364, 888, 443, 707, 440, 437, 1728, 4,
                747, 211, 210, 208, 370, 379, 734, 723, 714, 1735, 883, 877, 876, 3459, 865, 2,
                377, 369, 102, 187, 726, 722, 358, 711, 709, 866, 1734, 871, 3458, 870, 434, 0,
                12, 10, 7, 11, 10, 17, 11, 9, 13, 12, 10, 7, 5, 3, 1, 3,
            ]
        ),
        24: makePairTable(
            xlen: 16,
            linbits: 4,
            lengths: [
                4, 5, 7, 8, 9, 10, 10, 11, 11, 12, 12, 12, 12, 12, 13, 10,
                5, 6, 7, 8, 9, 10, 10, 11, 11, 11, 12, 12, 12, 12, 12, 10,
                7, 7, 8, 9, 9, 10, 10, 11, 11, 11, 11, 12, 12, 12, 13, 9,
                8, 8, 9, 9, 10, 10, 10, 11, 11, 11, 11, 12, 12, 12, 12, 9,
                9, 9, 9, 10, 10, 10, 10, 11, 11, 11, 12, 12, 12, 12, 13, 9,
                10, 9, 10, 10, 10, 10, 11, 11, 11, 11, 12, 12, 12, 12, 12, 9,
                10, 10, 10, 10, 10, 11, 11, 11, 11, 12, 12, 12, 12, 12, 13, 9,
                11, 10, 10, 10, 11, 11, 11, 11, 12, 12, 12, 12, 12, 13, 13, 10,
                11, 11, 11, 11, 11, 11, 11, 11, 11, 12, 12, 12, 12, 13, 13, 10,
                11, 11, 11, 11, 11, 11, 11, 12, 12, 12, 12, 12, 13, 13, 13, 10,
                12, 11, 11, 11, 11, 12, 12, 12, 12, 12, 12, 13, 13, 13, 13, 10,
                12, 12, 11, 11, 11, 12, 12, 12, 12, 12, 12, 13, 13, 13, 13, 10,
                12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 13, 13, 13, 13, 13, 10,
                12, 12, 12, 12, 12, 12, 12, 12, 13, 13, 13, 13, 13, 13, 13, 10,
                13, 12, 12, 12, 12, 12, 12, 13, 13, 13, 13, 13, 13, 13, 13, 10,
                9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 10, 10, 10, 10, 6,
            ],
            codes: [
                15, 13, 46, 80, 146, 262, 248, 434, 426, 669, 653, 649, 621, 517, 1032, 88,
                14, 12, 21, 38, 71, 130, 122, 216, 209, 198, 327, 345, 319, 297, 279, 42,
                47, 22, 41, 74, 68, 128, 120, 221, 207, 194, 182, 340, 315, 295, 541, 18,
                81, 39, 75, 70, 134, 125, 116, 220, 204, 190, 178, 325, 311, 293, 271, 16,
                147, 72, 69, 135, 127, 118, 112, 210, 200, 188, 352, 323, 306, 285, 540, 14,
                263, 66, 129, 126, 119, 114, 214, 202, 192, 180, 341, 317, 301, 281, 262, 12,
                249, 123, 121, 117, 113, 215, 206, 195, 185, 347, 330, 308, 291, 272, 520, 10,
                435, 115, 111, 109, 211, 203, 196, 187, 353, 332, 313, 298, 283, 531, 381, 17,
                427, 212, 208, 205, 201, 193, 186, 177, 169, 320, 303, 286, 268, 514, 377, 16,
                335, 199, 197, 191, 189, 181, 174, 333, 321, 305, 289, 275, 521, 379, 371, 11,
                668, 184, 183, 179, 175, 344, 331, 314, 304, 290, 277, 530, 383, 373, 366, 10,
                652, 346, 171, 168, 164, 318, 309, 299, 287, 276, 263, 513, 375, 368, 362, 6,
                648, 322, 316, 312, 307, 302, 292, 284, 269, 261, 512, 376, 370, 364, 359, 4,
                620, 300, 296, 294, 288, 282, 273, 266, 515, 380, 374, 369, 365, 361, 357, 2,
                1033, 280, 278, 274, 267, 264, 259, 382, 378, 372, 367, 363, 360, 358, 356, 0,
                43, 20, 19, 17, 15, 13, 11, 9, 7, 6, 4, 7, 5, 3, 1, 3,
            ]
        ),
    ]

    if let base16 = tables[16] {
        for (index, linbits) in zip(17 ... 23, [2, 3, 4, 6, 8, 10, 13]) {
            tables[index] = makePairTable(
                xlen: base16.xlen,
                linbits: linbits,
                lengths: base16.lengths,
                codes: base16.codes
            )
        }
    }

    if let base24 = tables[24] {
        for (index, linbits) in zip(25 ... 31, [5, 6, 7, 8, 9, 11, 13]) {
            tables[index] = makePairTable(
                xlen: base24.xlen,
                linbits: linbits,
                lengths: base24.lengths,
                codes: base24.codes
            )
        }
    }

    return tables
}()

/// Flat array indexed by table number (0..32). `nil` for undefined slots
/// (tableIndex=4 and 14 are reserved in the MP3 spec). Avoids a Dictionary
/// hash on every Huffman call in the rate-control inner loop.
private let pairTableArray: [PairHuffmanTable?] = {
    let maxIndex = pairTables.keys.max() ?? 0
    var arr = [PairHuffmanTable?](repeating: nil, count: maxIndex + 1)
    for (idx, table) in pairTables {
        arr[idx] = table
    }
    return arr
}()

/// Unwrapped pointer view: `nil` if table not defined, else fast pointer access.
/// Using a class wrapper would add a retain/release per call, so this stays as
/// an `[PairHuffmanTable?]` and is indexed directly in the hot path.
@inline(__always)
private func pairTable(_ tableIndex: Int) -> PairHuffmanTable? {
    if tableIndex < 0 || tableIndex >= pairTableArray.count {
        return nil
    }
    return pairTableArray[tableIndex]
}

// MARK: - Decoder lookup tables

/// Flat first-level prefix-lookup entry. `baseLen == 0` means the 10-bit prefix
/// doesn't point at any ≤10-bit code; the decoder falls back to `overflow` in
/// that case.
struct PairDecodeEntry {
    var baseX: UInt8
    var baseY: UInt8
    /// Bits consumed for the base symbol (excluding linbits and sign). 0 = invalid.
    var baseLen: UInt8
}

struct PairDecodeOverflow {
    var code: UInt32
    var baseLen: UInt8
    var baseX: UInt8
    var baseY: UInt8
}

struct PairDecodeTable {
    var lookup: ContiguousArray<PairDecodeEntry>
    var overflow: [PairDecodeOverflow]
    var peekBits: Int
    var linbits: Int
    var linmax: Int
}

/// Per-pair-table decoder lookup. Indexed by the same Huffman table number as `pairTableArray`.
let pairDecodeTables: [PairDecodeTable?] = {
    let peek = 10
    var result = [PairDecodeTable?](repeating: nil, count: pairTableArray.count)
    for (idx, tableOpt) in pairTableArray.enumerated() {
        guard let table = tableOpt, idx != 0 else {
            continue
        }
        var lookup = ContiguousArray<PairDecodeEntry>(
            repeating: PairDecodeEntry(baseX: 0, baseY: 0, baseLen: 0),
            count: 1 << peek
        )
        var overflow: [PairDecodeOverflow] = []
        for bx in 0 ..< table.xlen {
            for by in 0 ..< table.xlen {
                let entryIdx = bx * table.xlen + by
                let signBits = (bx == 0 ? 0 : 1) + (by == 0 ? 0 : 1)
                let baseLen = table.lengths[entryIdx] - signBits
                guard baseLen > 0 else {
                    continue
                }
                let code = table.codes[entryIdx]
                if baseLen <= peek {
                    let shift = peek - baseLen
                    let start = code << shift
                    let count = 1 << shift
                    let entry = PairDecodeEntry(baseX: UInt8(bx), baseY: UInt8(by), baseLen: UInt8(baseLen))
                    for off in 0 ..< count {
                        lookup[start + off] = entry
                    }
                } else {
                    overflow.append(PairDecodeOverflow(
                        code: UInt32(code),
                        baseLen: UInt8(baseLen),
                        baseX: UInt8(bx),
                        baseY: UInt8(by)
                    ))
                }
            }
        }
        overflow.sort { $0.baseLen < $1.baseLen }
        result[idx] = PairDecodeTable(
            lookup: lookup,
            overflow: overflow,
            peekBits: peek,
            linbits: table.linbits,
            linmax: table.linmax
        )
    }
    return result
}()

struct QuadDecodeEntry {
    var absV: UInt8
    var absW: UInt8
    var absX: UInt8
    var absY: UInt8
    var baseLen: UInt8
}

/// Two quad decoder tables (index 0 = quadTableA, 1 = quadTableB). Max base length
/// is 10 bits, so the 10-bit lookup is complete — no overflow list needed.
let quadDecodeTables: [ContiguousArray<QuadDecodeEntry>] = {
    let peek = 10
    var result: [ContiguousArray<QuadDecodeEntry>] = []
    for table in [quadTableA, quadTableB] {
        var lookup = ContiguousArray<QuadDecodeEntry>(
            repeating: QuadDecodeEntry(absV: 0, absW: 0, absX: 0, absY: 0, baseLen: 0),
            count: 1 << peek
        )
        for absV in 0 ... 1 {
            for absW in 0 ... 1 {
                for absX in 0 ... 1 {
                    for absY in 0 ... 1 {
                        let idx = (absV << 3) | (absW << 2) | (absX << 1) | absY
                        let signBits = absV + absW + absX + absY
                        let baseLen = table.lengths[idx] - signBits
                        guard baseLen > 0 else {
                            continue
                        }
                        let baseCode = table.codes[idx] >> signBits
                        let shift = peek - baseLen
                        let start = baseCode << shift
                        let count = 1 << shift
                        let entry = QuadDecodeEntry(
                            absV: UInt8(absV), absW: UInt8(absW),
                            absX: UInt8(absX), absY: UInt8(absY),
                            baseLen: UInt8(baseLen)
                        )
                        for off in 0 ..< count {
                            lookup[start + off] = entry
                        }
                    }
                }
            }
        }
        result.append(lookup)
    }
    return result
}()

private let quadTableA = QuadHuffmanTable(
    lengths: [
        1, 5, 5, 7,
        5, 8, 7, 9,
        5, 7, 7, 9,
        7, 9, 9, 10,
    ],
    codes: [
        1, 10, 8, 20,
        12, 20, 16, 32,
        14, 12, 24, 0,
        28, 16, 24, 16,
    ]
)

private let quadTableB = QuadHuffmanTable(
    lengths: [
        4, 5, 5, 6,
        5, 6, 6, 7,
        5, 6, 6, 7,
        6, 7, 7, 8,
    ],
    codes: [
        15, 28, 26, 48,
        22, 40, 36, 64,
        14, 24, 20, 32,
        12, 16, 8, 0,
    ]
)

private func pairIndex(firstValue: Int, secondValue: Int, width: Int) -> Int {
    firstValue * width + secondValue
}

private func pairSignBits(firstValue: Int, secondValue: Int) -> Int {
    (firstValue == 0 ? 0 : 1) + (secondValue == 0 ? 0 : 1)
}

private func quadIndex(first: Int, second: Int, third: Int, fourth: Int) -> Int {
    (first << 3) | (second << 2) | (third << 1) | fourth
}

private func quadSignBits(first: Int, second: Int, third: Int, fourth: Int) -> Int {
    (first == 0 ? 0 : 1) + (second == 0 ? 0 : 1) + (third == 0 ? 0 : 1) + (fourth == 0 ? 0 : 1)
}

/// Sentinel bit count indicating the value cannot be encoded with the given table.
/// Kept well under Int.max so accumulating a few of these doesn't overflow.
let huffmanOverflowBits: Int = .max / 4

/// Encode a pair (firstValue, secondValue) using pair table `tableIndex`.
///
/// Returns the code packed MSB-first into the low `bits` bits of a UInt64, plus the bit count.
/// The layout is: base Huffman code, optional linbits(first), optional sign(first),
/// optional linbits(second), optional sign(second).
@inline(__always)
func huffmanEncodePair(firstValue: Int, secondValue: Int, tableIndex: Int) -> (code: UInt64, bits: Int) {
    if tableIndex == 0 {
        return (0, 0)
    }
    guard let table = pairTable(tableIndex) else {
        return (0, 0)
    }

    let absoluteFirst = abs(firstValue)
    let absoluteSecond = abs(secondValue)

    var baseFirst = absoluteFirst
    var baseSecond = absoluteSecond
    var linbitsFirst = 0
    var linbitsSecond = 0

    if table.linbits > 0 {
        if absoluteFirst >= 15 {
            baseFirst = 15
            linbitsFirst = absoluteFirst - 15
        }
        if absoluteSecond >= 15 {
            baseSecond = 15
            linbitsSecond = absoluteSecond - 15
        }
        if linbitsFirst > table.linmax || linbitsSecond > table.linmax {
            return (0, huffmanOverflowBits)
        }
    } else if absoluteFirst > table.maxBaseValue || absoluteSecond > table.maxBaseValue {
        return (0, huffmanOverflowBits)
    }

    let tableOffset = pairIndex(firstValue: baseFirst, secondValue: baseSecond, width: table.xlen)
    if tableOffset >= table.lengths.count {
        return (0, huffmanOverflowBits)
    }

    let signBits = pairSignBits(firstValue: absoluteFirst, secondValue: absoluteSecond)
    let baseLength = table.lengths[tableOffset] - signBits
    if baseLength < 0 {
        return (0, huffmanOverflowBits)
    }

    var code = UInt64(table.codes[tableOffset])
    if baseLength < 64 {
        code &= (UInt64(1) << baseLength) - 1
    }
    var totalBits = baseLength

    if table.linbits > 0, baseFirst == 15 {
        code = (code << table.linbits) | UInt64(linbitsFirst)
        totalBits += table.linbits
    }
    if absoluteFirst > 0 {
        code = (code << 1) | (firstValue < 0 ? 1 : 0)
        totalBits += 1
    }
    if table.linbits > 0, baseSecond == 15 {
        code = (code << table.linbits) | UInt64(linbitsSecond)
        totalBits += table.linbits
    }
    if absoluteSecond > 0 {
        code = (code << 1) | (secondValue < 0 ? 1 : 0)
        totalBits += 1
    }

    return (code, totalBits)
}

func huffmanDecodePair(reader: BitstreamReader, tableIndex: Int) throws -> (firstValue: Int, secondValue: Int) {
    if tableIndex == 0 {
        return (0, 0)
    }
    guard tableIndex < pairDecodeTables.count, let decodeTable = pairDecodeTables[tableIndex] else {
        throw MP3DecoderError.unsupportedFeature("Huffman table \(tableIndex)")
    }

    // First-level lookup: peek peekBits, index into the prefix table.
    let peekedBits = try reader.peekBitsPadded(decodeTable.peekBits)
    let entry = decodeTable.lookup[peekedBits]

    var baseFirst: Int
    var baseSecond: Int
    if entry.baseLen != 0, reader.bitsRemaining >= Int(entry.baseLen) {
        baseFirst = Int(entry.baseX)
        baseSecond = Int(entry.baseY)
        reader.consumeBits(Int(entry.baseLen))
    } else {
        // No ≤ peekBits-length code matched — fall back to the overflow list.
        // Overflow entries are sorted by baseLen ascending.
        var matched = false
        var matchedFirst = 0
        var matchedSecond = 0
        for overflowEntry in decodeTable.overflow {
            if reader.bitsRemaining < Int(overflowEntry.baseLen) {
                continue
            }
            let candidate = try reader.peekBits(Int(overflowEntry.baseLen))
            if candidate == Int(overflowEntry.code) {
                reader.consumeBits(Int(overflowEntry.baseLen))
                matchedFirst = Int(overflowEntry.baseX)
                matchedSecond = Int(overflowEntry.baseY)
                matched = true
                break
            }
        }
        if !matched {
            throw MP3DecoderError.invalidBitstream("Invalid Huffman pair code")
        }
        baseFirst = matchedFirst
        baseSecond = matchedSecond
    }

    var firstValue = baseFirst
    var secondValue = baseSecond
    if decodeTable.linbits > 0, firstValue == 15 {
        firstValue += try reader.readBits(decodeTable.linbits)
    }
    if firstValue != 0, try reader.readBit() == 1 {
        firstValue = -firstValue
    }
    if decodeTable.linbits > 0, secondValue == 15 {
        secondValue += try reader.readBits(decodeTable.linbits)
    }
    if secondValue != 0, try reader.readBit() == 1 {
        secondValue = -secondValue
    }
    return (firstValue, secondValue)
}

@inline(__always)
func huffmanEncodeQuad(first: Int, second: Int, third: Int, fourth: Int, tableIndex: Int) -> (code: UInt64, bits: Int) {
    let absoluteFirst = min(abs(first), 1)
    let absoluteSecond = min(abs(second), 1)
    let absoluteThird = min(abs(third), 1)
    let absoluteFourth = min(abs(fourth), 1)

    let table = tableIndex == 0 ? quadTableA : quadTableB
    let tableOffset = quadIndex(first: absoluteFirst, second: absoluteSecond, third: absoluteThird, fourth: absoluteFourth)
    let signBits = quadSignBits(first: absoluteFirst, second: absoluteSecond, third: absoluteThird, fourth: absoluteFourth)
    let baseLength = table.lengths[tableOffset] - signBits
    var code = UInt64(table.codes[tableOffset] >> signBits)
    var totalBits = baseLength

    if absoluteFirst != 0 {
        code = (code << 1) | (first < 0 ? 1 : 0)
        totalBits += 1
    }
    if absoluteSecond != 0 {
        code = (code << 1) | (second < 0 ? 1 : 0)
        totalBits += 1
    }
    if absoluteThird != 0 {
        code = (code << 1) | (third < 0 ? 1 : 0)
        totalBits += 1
    }
    if absoluteFourth != 0 {
        code = (code << 1) | (fourth < 0 ? 1 : 0)
        totalBits += 1
    }
    return (code, totalBits)
}

func huffmanDecodeQuad(reader: BitstreamReader, tableIndex: Int) throws -> (first: Int, second: Int, third: Int, fourth: Int) {
    let lookup = quadDecodeTables[tableIndex == 0 ? 0 : 1]
    let peekedBits = try reader.peekBitsPadded(10)
    let entry = lookup[peekedBits]
    guard entry.baseLen != 0, reader.bitsRemaining >= Int(entry.baseLen) else {
        throw MP3DecoderError.invalidBitstream("Invalid Huffman count1 code")
    }
    reader.consumeBits(Int(entry.baseLen))

    var first = Int(entry.absV)
    var second = Int(entry.absW)
    var third = Int(entry.absX)
    var fourth = Int(entry.absY)
    if first != 0, try reader.readBit() == 1 {
        first = -first
    }
    if second != 0, try reader.readBit() == 1 {
        second = -second
    }
    if third != 0, try reader.readBit() == 1 {
        third = -third
    }
    if fourth != 0, try reader.readBit() == 1 {
        fourth = -fourth
    }
    return (first, second, third, fourth)
}

/// Pick the best Huffman table for values in `[start, end)` and also return its bit cost.
/// Walks the range once across all candidates via `huffmanPairBits`, so the subsequent
/// `countHuffmanBits` step in `Quantizer.countBits` is avoided.
func selectHuffmanTableAndBits(values: UnsafeBufferPointer<Int>, start: Int, end: Int) -> (tableIndex: Int, bits: Int) {
    let upperBound = min(end, values.count)
    guard start < upperBound else {
        return (0, 0)
    }

    var maxValue = 0
    for index in start ..< upperBound {
        let magnitude = abs(values[index])
        if magnitude > maxValue {
            maxValue = magnitude
        }
    }

    if maxValue == 0 {
        return (0, 0)
    }

    let candidates: [Int] = switch maxValue {
    case 1:
        [1]
    case 2:
        [2, 3]
    case 3:
        [5, 6]
    case 4 ... 5:
        [7, 8, 9]
    case 6 ... 7:
        [10, 11, 12]
    case 8 ... 15:
        [13, 15]
    default:
        // The ESC path is still not stable with this encoder's current quantizer/filterbank,
        // so keep large values inside the verified no-escape tables via rate control.
        [15]
    }

    switch candidates.count {
    case 1:
        let table = candidates[0]
        return (table, countHuffmanBits(values: values, start: start, end: end, tableIndex: table))
    case 2:
        let (firstBits, secondBits) = countHuffmanBits2(
            values: values, start: start, end: upperBound,
            firstTable: candidates[0], secondTable: candidates[1]
        )
        if firstBits <= secondBits {
            return (candidates[0], firstBits)
        }
        return (candidates[1], secondBits)
    case 3:
        let (firstBits, secondBits, thirdBits) = countHuffmanBits3(
            values: values, start: start, end: upperBound,
            firstTable: candidates[0], secondTable: candidates[1], thirdTable: candidates[2]
        )
        var bestTable = candidates[0]
        var bestBits = firstBits
        if secondBits < bestBits {
            bestBits = secondBits
            bestTable = candidates[1]
        }
        if thirdBits < bestBits {
            bestBits = thirdBits
            bestTable = candidates[2]
        }
        return (bestTable, bestBits)
    default:
        var bestTable = candidates[0]
        var bestBits = Int.max
        for candidate in candidates {
            let bits = countHuffmanBits(values: values, start: start, end: end, tableIndex: candidate)
            if bits < bestBits {
                bestBits = bits
                bestTable = candidate
            }
        }
        return (bestTable, bestBits)
    }
}

/// Fused two-table bit counting: walks `values` once and totals for `firstTable` and `secondTable`.
@inline(__always)
func countHuffmanBits2(
    values: UnsafeBufferPointer<Int>, start: Int, end: Int, firstTable: Int, secondTable: Int
) -> (Int, Int) {
    var totalFirst = 0
    var totalSecond = 0
    var pairIndex = start
    while pairIndex + 1 < end {
        let firstValue = values[pairIndex]
        let secondValue = values[pairIndex + 1]
        let firstCost = huffmanPairBits(firstValue: firstValue, secondValue: secondValue, tableIndex: firstTable)
        let secondCost = huffmanPairBits(firstValue: firstValue, secondValue: secondValue, tableIndex: secondTable)
        if firstCost >= huffmanOverflowBits {
            totalFirst = huffmanOverflowBits
        } else if totalFirst != huffmanOverflowBits {
            totalFirst += firstCost
        }
        if secondCost >= huffmanOverflowBits {
            totalSecond = huffmanOverflowBits
        } else if totalSecond != huffmanOverflowBits {
            totalSecond += secondCost
        }
        pairIndex += 2
    }
    return (totalFirst, totalSecond)
}

/// Fused three-table bit counting.
@inline(__always)
func countHuffmanBits3(
    values: UnsafeBufferPointer<Int>, start: Int, end: Int, firstTable: Int, secondTable: Int, thirdTable: Int
) -> (Int, Int, Int) {
    var totalFirst = 0
    var totalSecond = 0
    var totalThird = 0
    var pairIndex = start
    while pairIndex + 1 < end {
        let firstValue = values[pairIndex]
        let secondValue = values[pairIndex + 1]
        let firstCost = huffmanPairBits(firstValue: firstValue, secondValue: secondValue, tableIndex: firstTable)
        let secondCost = huffmanPairBits(firstValue: firstValue, secondValue: secondValue, tableIndex: secondTable)
        let thirdCost = huffmanPairBits(firstValue: firstValue, secondValue: secondValue, tableIndex: thirdTable)
        if firstCost >= huffmanOverflowBits {
            totalFirst = huffmanOverflowBits
        } else if totalFirst != huffmanOverflowBits {
            totalFirst += firstCost
        }
        if secondCost >= huffmanOverflowBits {
            totalSecond = huffmanOverflowBits
        } else if totalSecond != huffmanOverflowBits {
            totalSecond += secondCost
        }
        if thirdCost >= huffmanOverflowBits {
            totalThird = huffmanOverflowBits
        } else if totalThird != huffmanOverflowBits {
            totalThird += thirdCost
        }
        pairIndex += 2
    }
    return (totalFirst, totalSecond, totalThird)
}

/// Count the number of bits the pair (firstValue, secondValue) would take with the given table.
/// Returns `huffmanOverflowBits` if the pair cannot be encoded.
/// This is the hot path for the rate-control binary search: ~5× faster than
/// calling `huffmanEncodePair` and discarding the code.
@inline(__always)
func huffmanPairBits(firstValue: Int, secondValue: Int, tableIndex: Int) -> Int {
    if tableIndex == 0 {
        return 0
    }
    guard let table = pairTable(tableIndex) else {
        return 0
    }

    let absoluteFirst = abs(firstValue)
    let absoluteSecond = abs(secondValue)
    var baseFirst = absoluteFirst
    var baseSecond = absoluteSecond
    var totalBits = 0

    if table.linbits > 0 {
        if absoluteFirst >= 15 {
            baseFirst = 15
            let linExtraFirst = absoluteFirst - 15
            if linExtraFirst > table.linmax {
                return huffmanOverflowBits
            }
            totalBits += table.linbits
        }
        if absoluteSecond >= 15 {
            baseSecond = 15
            let linExtraSecond = absoluteSecond - 15
            if linExtraSecond > table.linmax {
                return huffmanOverflowBits
            }
            totalBits += table.linbits
        }
    } else if absoluteFirst > table.maxBaseValue || absoluteSecond > table.maxBaseValue {
        return huffmanOverflowBits
    }

    let tableOffset = baseFirst * table.xlen + baseSecond
    if tableOffset >= table.lengths.count {
        return huffmanOverflowBits
    }
    // lengths[] already includes sign-bit contributions.
    return totalBits + table.lengths[tableOffset]
}

func countHuffmanBits(values: UnsafeBufferPointer<Int>, start: Int, end: Int, tableIndex: Int) -> Int {
    if tableIndex == 0 {
        return 0
    }

    var total = 0
    var pairIndex = start
    while pairIndex + 1 < end {
        let bits = huffmanPairBits(firstValue: values[pairIndex], secondValue: values[pairIndex + 1], tableIndex: tableIndex)
        if bits >= huffmanOverflowBits {
            return huffmanOverflowBits
        }
        total += bits
        pairIndex += 2
    }
    return total
}

@inline(__always)
func countQuadBits(first: Int, second: Int, third: Int, fourth: Int, tableIndex: Int) -> Int {
    huffmanEncodeQuad(first: first, second: second, third: third, fourth: fourth, tableIndex: tableIndex).bits
}
