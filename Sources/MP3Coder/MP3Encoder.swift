//
//  MP3Encoder.swift
//  MP3Coder
//
//  Created by GPT 5.5 and Opus 4.7 on 4/23/26.
//

import Foundation

/// MPEG-1 Layer 3 (MP3) Encoder
public final class MP3Encoder {
    // MARK: - Configuration

    // Calibrates the hybrid analysis coefficients to the decoder's synthesis scale.
    private let spectralScale: Float = 0.0008
    let sampleRate: Int
    let channels: Int
    let bitrate: Int // kbps
    let bitrateIndex: Int
    let sampleRateIndex: Int

    // MARK: - Internal components

    private let filterBanks: [PolyphaseFilterBank]
    private let mdctProcessors: [MDCTProcessor]
    private let psychoModel: PsychoacousticModel
    private let quantizer: Quantizer
    private let transientDetectors: [TransientDetector]

    /// Maps a bitstream slot for short blocks to the matching encoder MDCT slot
    /// (subband-major). Built once per sample rate.
    private let shortReorderTable: [Int]
    /// Per bitstream slot: the short scale-factor band that owns it.
    private let shortBandTable: [Int]
    /// Per bitstream slot: which of the three short windows owns it.
    private let shortWindowTable: [Int]

    // MARK: - State

    private var inputBuffer: ContiguousArray<Float> = []
    private var inputReadPos: Int = 0 // samples already consumed into frames

    /// Block type emitted for each channel's most recent granule. Drives the
    /// long↔short transition state machine: the next granule must respect the
    /// previous one (e.g. a `.long` cannot be immediately followed by `.shortBlocks`,
    /// it must be a `.start` first).
    private var previousBlockType: [MDCTBlockType]

    /// Per-channel `global_gain` of the most recently emitted long-block granule
    /// (0 = no recent long block, no smoothing hint). The quantizer uses this to
    /// avoid letting consecutive long-block gains diverge by more than a small
    /// step, which suppresses frame-rate (~38 Hz) noise-floor modulation that
    /// otherwise sounds like a "fluttery" or "scratchy" texture on smooth content.
    private var previousLongBlockGain: [Int]

    // Bit reservoir state
    private var reservoir: Int = 0 // bits available from the previous frame's spare main-data bytes
    private let maxReservoir: Int = 511 * 8 // MPEG1: 9-bit main_data_begin
    private var pendingFrame: PendingMP3Frame?

    // MARK: - Scratch buffers (preallocated in init, reused every frame)

    /// Deinterleaved channel samples. Layout: ch * samplesPerFrame + sampleIndex.
    private var channelSamplesScratch: ContiguousArray<Float>
    /// Spectral coefficients per (granule, channel). Layout: (gr * channels + ch) * 576 + k.
    private var granuleSpectralScratch: ContiguousArray<Float>
    /// Pre-reorder subband-major MDCT output for short blocks (kept separate so we
    /// don't disturb `granuleSpectralScratch`, which holds the bitstream-order layout).
    private var shortReorderScratch: ContiguousArray<Float>
    /// Quantized values per (granule, channel). Layout: (gr * channels + ch) * 576 + k.
    private var granuleQuantizedScratch: [ContiguousArray<Int>]
    /// Per-granule side info, preallocated as [2 * channels].
    private var granuleInfosScratch: [[GranuleInfo]]
    /// Main-data bit writer, reused across frames.
    private let mainDataWriter: BitstreamWriter
    /// Transposed subband samples for MDCT input. Layout: sb * 18 + s.
    private var subbandScratch: ContiguousArray<Double>
    /// 32-slot output buffer for each polyphase filterbank call.
    private var filterBankOutputScratch: ContiguousArray<Double>

    // MARK: - Computed properties

    var samplesPerFrame: Int {
        1152
    }

    var samplesPerGranule: Int {
        576
    }

    /// Frame size in bytes (without padding)
    var frameSizeBytes: Int {
        (144 * bitrate * 1000) / sampleRate
    }

    private struct PendingMP3Frame {
        var granuleInfos: [[GranuleInfo]]
        var mainData: Data
        var mainDataBegin: Int
        var mainDataCapacity: Int
        var paddingBit: Bool
        /// Channel mode for the frame header (`stereo` (0), `jointStereo` (1), or `mono` (3)).
        var channelMode: Int
        /// Mode-extension bits, used by jointStereo to flag M/S (`0b10`) and intensity stereo
        /// (`0b01`). 0 for plain stereo or mono.
        var modeExtension: Int

        var availableReservoirBytes: Int {
            max(0, mainDataCapacity - max(0, mainData.count - mainDataBegin))
        }
    }

    // MARK: - Init

    public init(sampleRate: Int, channels: Int, bitrate: Int) throws {
        guard let srIdx = MP3Constants.sampleRates.firstIndex(of: sampleRate) else {
            throw MP3EncoderError.unsupportedSampleRate(sampleRate)
        }
        guard let brIdx = MP3Constants.bitrateTable.firstIndex(of: bitrate) else {
            throw MP3EncoderError.unsupportedBitrate(bitrate)
        }
        guard channels == 1 || channels == 2 else {
            throw MP3EncoderError.unsupportedChannelCount(channels)
        }

        self.sampleRate = sampleRate
        self.channels = channels
        self.bitrate = bitrate
        bitrateIndex = brIdx
        sampleRateIndex = srIdx

        filterBanks = (0 ..< channels).map { _ in PolyphaseFilterBank() }
        mdctProcessors = (0 ..< channels).map { _ in MDCTProcessor() }
        psychoModel = PsychoacousticModel(sampleRate: sampleRate)
        quantizer = Quantizer(sampleRate: sampleRate)
        transientDetectors = (0 ..< channels).map { _ in TransientDetector() }
        previousBlockType = Array(repeating: .long, count: channels)
        previousLongBlockGain = Array(repeating: 0, count: channels)

        shortReorderTable = ShortBlockLayout.bitstreamReorderTable(sampleRate: sampleRate)
        shortBandTable = ShortBlockLayout.bitstreamBandTable(sampleRate: sampleRate)
        shortWindowTable = ShortBlockLayout.bitstreamWindowTable(sampleRate: sampleRate)

        let spf = 1152
        channelSamplesScratch = ContiguousArray(repeating: 0, count: channels * spf)
        granuleSpectralScratch = ContiguousArray(repeating: 0, count: 2 * channels * 576)
        shortReorderScratch = ContiguousArray(repeating: 0, count: 576)
        granuleQuantizedScratch = (0 ..< (2 * channels)).map { _ in
            ContiguousArray(repeating: 0, count: 576)
        }
        granuleInfosScratch = (0 ..< 2).map { _ in
            Array(repeating: GranuleInfo(), count: channels)
        }
        let frameBytes = (144 * bitrate * 1000) / sampleRate
        mainDataWriter = BitstreamWriter(reserveBytes: frameBytes)
        subbandScratch = ContiguousArray(repeating: 0, count: 32 * 18)
        filterBankOutputScratch = ContiguousArray(repeating: 0, count: 32)
    }

    // MARK: - Public API

    /// Encode PCM samples (interleaved if stereo)
    /// Returns encoded MP3 data (may be empty if not enough samples yet)
    public func encode(pcm: [Float]) -> Data {
        inputBuffer.append(contentsOf: pcm)
        return drainFrames()
    }

    /// Flush remaining samples (pads with zeros if needed)
    public func flush() -> Data {
        let remaining = inputBuffer.count - inputReadPos
        var output = Data()

        if remaining > 0 {
            let fpS = samplesPerFrame * channels
            let needed = fpS - (remaining % fpS)
            if needed > 0, needed < fpS {
                inputBuffer.append(contentsOf: repeatElement(Float(0), count: needed))
            }
            output.append(drainFrames(allowFinal: true))
        } else {
            output.append(drainFrames(allowFinal: true))
        }

        if let pendingFrame {
            output.append(renderFrame(pendingFrame, futureMainDataPrefix: Data()))
            self.pendingFrame = nil
            reservoir = 0
        }

        return output
    }

    private func drainFrames(allowFinal: Bool = false) -> Data {
        let fpS = samplesPerFrame * channels
        // To pick a block type for the final granule of each frame we need the next
        // granule's PCM (transient lookahead). Hold off emitting the frame until
        // there's at least one extra granule in the buffer; `flush` then drains the
        // tail with `allowFinal = true` and falls back to no-lookahead behaviour.
        let lookaheadSamples = samplesPerGranule * channels
        var output = Data()
        while inputReadPos + fpS <= inputBuffer.count {
            let haveLookahead = inputReadPos + fpS + lookaheadSamples <= inputBuffer.count
            if !haveLookahead, !allowFinal {
                break
            }
            let frame = encodeFrame(sampleBase: inputReadPos, hasLookahead: haveLookahead)
            output.append(frame)
            inputReadPos += fpS
        }
        // Bound in-memory buffer growth without O(N) shifts every frame.
        if inputReadPos >= 1 << 20 {
            inputBuffer.removeFirst(inputReadPos)
            inputReadPos = 0
        }
        return output
    }

    // MARK: - Frame encoding

    private func encodeFrame(sampleBase: Int, hasLookahead: Bool) -> Data {
        let samplesPerFrameCount = samplesPerFrame
        // Deinterleave into channelSamplesScratch[channel * samplesPerFrame + sampleIndex]
        channelSamplesScratch.withUnsafeMutableBufferPointer { channelBuffer in
            inputBuffer.withUnsafeBufferPointer { inputRegion in
                let inputBase = inputRegion.baseAddress! + sampleBase
                if channels == 1 {
                    for sampleIndex in 0 ..< samplesPerFrameCount {
                        channelBuffer[sampleIndex] = inputBase[sampleIndex]
                    }
                } else {
                    // Stereo interleaved L,R,L,R…
                    let leftOutput = channelBuffer.baseAddress!
                    let rightOutput = channelBuffer.baseAddress! + samplesPerFrameCount
                    for sampleIndex in 0 ..< samplesPerFrameCount {
                        leftOutput[sampleIndex] = inputBase[2 * sampleIndex]
                        rightOutput[sampleIndex] = inputBase[2 * sampleIndex + 1]
                    }
                }
            }
        }

        // Per-(granule, channel) transient flag from PCM. Granule 0/1 of this frame
        // come from `channelSamplesScratch`; the lookahead needed for granule 1 lives
        // one granule past the frame's end in `inputBuffer`.
        var transientFlags: [[Bool]] = [
            Array(repeating: false, count: channels),
            Array(repeating: false, count: channels),
        ]
        var nextFrameTransient: [Bool] = Array(repeating: false, count: channels)

        channelSamplesScratch.withUnsafeBufferPointer { channelBuffer in
            let channelBase = channelBuffer.baseAddress!
            for channel in 0 ..< channels {
                let channelOffset = channel * samplesPerFrameCount
                for granule in 0 ..< 2 {
                    let granuleOffset = channelOffset + granule * samplesPerGranule
                    transientFlags[granule][channel] = transientDetectors[channel].detectTransient(
                        pcm: channelBase.advanced(by: granuleOffset),
                        samplesPerGranule: samplesPerGranule
                    )
                }
            }
        }

        if hasLookahead {
            // Peek (don't consume) one more granule to drive granule-1's lookahead.
            inputBuffer.withUnsafeBufferPointer { inputRegion in
                let lookaheadBase = inputRegion.baseAddress! + sampleBase + samplesPerFrameCount * channels
                if channels == 1 {
                    nextFrameTransient[0] = transientPreview(
                        pcm: lookaheadBase,
                        stride: 1,
                        channel: 0
                    )
                } else {
                    for channel in 0 ..< channels {
                        nextFrameTransient[channel] = transientPreview(
                            pcm: lookaheadBase + channel,
                            stride: 2,
                            channel: channel
                        )
                    }
                }
            }
        }

        let baseTargetBits = max(0, (mainDataBytesForCurrentFrame * 8) / (2 * channels))
        var reservoirBitsRemaining = min(reservoir, maxReservoir)

        // Resolve block types for the four (granule, channel) slots before MDCT, so
        // we can hand the right block type to each MDCT call.
        var blockTypes: [[MDCTBlockType]] = [
            Array(repeating: .long, count: channels),
            Array(repeating: .long, count: channels),
        ]
        for channel in 0 ..< channels {
            var prev = previousBlockType[channel]
            for granule in 0 ..< 2 {
                let curr = transientFlags[granule][channel]
                let next: Bool = if granule == 0 {
                    transientFlags[1][channel]
                } else {
                    nextFrameTransient[channel]
                }
                let blockType = nextBlockType(
                    previous: prev,
                    currentTransient: curr,
                    nextTransient: next
                )
                blockTypes[granule][channel] = blockType
                prev = blockType
            }
        }

        // Phase 1: filter bank + MDCT for every (granule, channel). We populate
        // `granuleSpectralScratch` with bitstream-order spectral lines and update
        // the per-channel block-type state, but defer quantization until after the
        // M/S decision below — that decision is per-frame and needs both channels'
        // spectral data.
        for granule in 0 ..< 2 {
            let granuleSampleOffset = granule * samplesPerGranule

            for channel in 0 ..< channels {
                let channelSampleBase = channel * samplesPerFrameCount
                channelSamplesScratch.withUnsafeBufferPointer { channelBuffer in
                    filterBankOutputScratch.withUnsafeMutableBufferPointer { filterBankOutput in
                        subbandScratch.withUnsafeMutableBufferPointer { subbandBuffer in
                            let channelBase = channelBuffer.baseAddress!
                            for slot in 0 ..< 18 {
                                let sampleOffset = channelSampleBase + granuleSampleOffset + slot * 32
                                filterBanks[channel].analyze(
                                    input: channelBase,
                                    inputOffset: sampleOffset,
                                    inputLength: channelBuffer.count,
                                    output: filterBankOutput.baseAddress!
                                )
                                for subband in 0 ..< 32 {
                                    subbandBuffer[subband * 18 + slot] = filterBankOutput[subband]
                                }
                            }
                        }
                    }
                }

                let blockType = blockTypes[granule][channel]
                let spectralBase = (granule * channels + channel) * 576

                if blockType == .shortBlocks {
                    subbandScratch.withUnsafeBufferPointer { subbandBuffer in
                        shortReorderScratch.withUnsafeMutableBufferPointer { reorderBuffer in
                            mdctProcessors[channel].processGranule(
                                subbandSamples: subbandBuffer.baseAddress!,
                                blockType: .shortBlocks,
                                output: reorderBuffer.baseAddress!
                            )
                            for index in 0 ..< 576 {
                                reorderBuffer[index] *= spectralScale
                            }
                            granuleSpectralScratch.withUnsafeMutableBufferPointer { destination in
                                let outputSlice = destination.baseAddress!.advanced(by: spectralBase)
                                shortReorderTable.withUnsafeBufferPointer { reorderIndices in
                                    let reorderBase = reorderIndices.baseAddress!
                                    for bitstreamIndex in 0 ..< 576 {
                                        outputSlice[bitstreamIndex] = reorderBuffer[reorderBase[bitstreamIndex]]
                                    }
                                }
                            }
                        }
                    }
                } else {
                    subbandScratch.withUnsafeBufferPointer { subbandBuffer in
                        granuleSpectralScratch.withUnsafeMutableBufferPointer { destination in
                            mdctProcessors[channel].processGranule(
                                subbandSamples: subbandBuffer.baseAddress!,
                                blockType: blockType,
                                output: destination.baseAddress!.advanced(by: spectralBase)
                            )
                            let outputSlice = destination.baseAddress!.advanced(by: spectralBase)
                            for spectralIndex in 0 ..< 576 {
                                outputSlice[spectralIndex] *= spectralScale
                            }
                        }
                    }
                }

                previousBlockType[channel] = blockType
            }
        }

        // Phase 2: pick L/R vs M/S for the whole frame, then transform spectral
        // in place if M/S wins. Decision aggregates across both granules so the
        // mode_extension header bit (which is per-frame) reflects the dominant
        // correlation. M/S only makes sense for stereo; both granules in the frame
        // must also share a block type since M/S is applied bin-for-bin and
        // requires matching MDCT layouts on the two channels.
        let useMidSide = decideMidSideStereo(blockTypes: blockTypes)
        if useMidSide {
            applyMidSideTransform()
        }

        // Phase 3: quantize each (granule, channel) using the (possibly transformed)
        // spectral data.
        for granule in 0 ..< 2 {
            for channel in 0 ..< channels {
                let blockType = blockTypes[granule][channel]
                let spectralBase = (granule * channels + channel) * 576

                var granuleInfo = GranuleInfo()
                granuleInfo.blockType = blockType.rawValue
                granuleInfo.windowSwitchingFlag = blockType != .long
                granuleInfo.mixedBlockFlag = false
                // Region splits for `window_switching_flag = 1` granules are *not*
                // carried in the bitstream — the decoder hardcodes them based on
                // block_type (see `MP3Decoder` side-info reader). The encoder must
                // use the matching values:
                //   • start / stop blocks: 7 / 13   (region 2 effectively empty)
                //   • pure short blocks:    8 / 12  (region 2 effectively empty)
                // For long blocks the bitstream carries region0/1_count so we keep
                // the prior 10 / 3 default. Mismatching these on start/stop blocks
                // misaligns every transient's Huffman bits with the decoder, which
                // shows up audibly as localized scratchy / scattaly noise around
                // each short-block group.
                switch blockType {
                case .shortBlocks:
                    granuleInfo.region0Count = 8
                    granuleInfo.region1Count = 12
                case .start, .stop:
                    granuleInfo.region0Count = 7
                    granuleInfo.region1Count = 13
                case .long:
                    granuleInfo.region0Count = 10
                    granuleInfo.region1Count = 3
                }

                // The quantizer treats `globalGain == 0` as "no smoothing hint";
                // overwriting the GranuleInfo struct default (210) ensures the
                // smoothing path only fires when we explicitly seed it below.
                granuleInfo.globalGain = 0
                // For consecutive long blocks on the same channel, seed the gain
                // with the previous granule's chosen value. The quantizer clamps
                // the new gain no further below it than `gainSmoothingMaxDelta`,
                // suppressing frame-rate noise-floor flutter on steady-state
                // content. Short/start/stop blocks have their own per-window gain
                // dynamics (subblock_gain), so we deliberately leave those
                // un-smoothed.
                if blockType == .long, previousLongBlockGain[channel] > 0 {
                    granuleInfo.globalGain = previousLongBlockGain[channel]
                }

                let huffmanBits = granuleSpectralScratch.withUnsafeBufferPointer { spectralSource in
                    let spectralSlice = UnsafeBufferPointer(
                        start: spectralSource.baseAddress!.advanced(by: spectralBase),
                        count: 576
                    )
                    let thresholds = psychoModel.computeThresholds(spectral: spectralSlice)
                    return granuleQuantizedScratch[granule * channels + channel].withUnsafeMutableBufferPointer { destination in
                        quantizer.outerLoop(
                            spectral: spectralSlice,
                            thresholds: thresholds,
                            targetBits: baseTargetBits,
                            reservoirBits: reservoirBitsRemaining,
                            destination: destination,
                            granuleInfo: &granuleInfo
                        )
                    }
                }

                granuleInfo.part2_3_length = granuleInfo.part2Length + huffmanBits
                reservoirBitsRemaining = max(0, reservoirBitsRemaining - max(0, granuleInfo.part2_3_length - baseTargetBits))
                granuleInfosScratch[granule][channel] = granuleInfo

                // Update the long-block gain hint for the next granule on this channel.
                // Reset to 0 (no hint) for non-long blocks so the next long block after a
                // short run starts fresh — the spectral content shape after a transient
                // is usually quite different from before it.
                if blockType == .long {
                    previousLongBlockGain[channel] = granuleInfo.globalGain
                } else {
                    previousLongBlockGain[channel] = 0
                }
            }
        }

        return writeBitstream(useMidSide: useMidSide)
    }

    /// Pick L/R vs M/S for the whole frame. M/S only fires for stereo when both
    /// granules share a block type (M/S is bin-for-bin and the two channels must
    /// have matching MDCT layouts) and the side-channel energy is small relative
    /// to the mid-channel — i.e. L and R are positively correlated, which is the
    /// typical case for music. The 0.5 ratio threshold is conservative.
    private func decideMidSideStereo(blockTypes: [[MDCTBlockType]]) -> Bool {
        guard channels == 2 else {
            return false
        }
        for granule in 0 ..< 2 {
            if blockTypes[granule][0] != blockTypes[granule][1] {
                return false
            }
        }

        var midEnergy: Double = 0
        var sideEnergy: Double = 0
        let inverseRoot2 = 1.0 / sqrt(2.0)
        granuleSpectralScratch.withUnsafeBufferPointer { source in
            let base = source.baseAddress!
            for granule in 0 ..< 2 {
                let leftBase = (granule * channels + 0) * 576
                let rightBase = (granule * channels + 1) * 576
                for index in 0 ..< 576 {
                    let leftValue = Double(base[leftBase + index])
                    let rightValue = Double(base[rightBase + index])
                    let midValue = (leftValue + rightValue) * inverseRoot2
                    let sideValue = (leftValue - rightValue) * inverseRoot2
                    midEnergy += midValue * midValue
                    sideEnergy += sideValue * sideValue
                }
            }
        }

        // Use M/S when |S| is at most half the magnitude of |M|, i.e. side energy
        // is at most a quarter of mid energy. Below that, M is clearly the
        // dominant carrier and M/S delivers a real bit-budget win. Above it,
        // L/R can be more efficient because S is no longer "the small channel".
        let total = midEnergy + sideEnergy
        guard total > 0 else {
            return false
        }
        return sideEnergy / total < 0.2
    }

    /// In-place L/R → M/S transform across both granules. Mirrors the decoder's
    /// `applyMidSideStereo` so a `mode = jointStereo, mode_extension = 0b10`
    /// frame round-trips back to the original L/R signal.
    private func applyMidSideTransform() {
        let inverseRoot2 = Float(1.0 / sqrt(2.0))
        granuleSpectralScratch.withUnsafeMutableBufferPointer { destination in
            let base = destination.baseAddress!
            for granule in 0 ..< 2 {
                let leftBase = (granule * channels + 0) * 576
                let rightBase = (granule * channels + 1) * 576
                for index in 0 ..< 576 {
                    let leftValue = base[leftBase + index]
                    let rightValue = base[rightBase + index]
                    base[leftBase + index] = (leftValue + rightValue) * inverseRoot2
                    base[rightBase + index] = (leftValue - rightValue) * inverseRoot2
                }
            }
        }
    }

    /// Block-type state machine for one granule (per channel).
    ///
    /// The encoder cannot transition directly between long and short blocks: the
    /// IMDCT relies on overlap-add windows that only cancel correctly across
    /// matching pairs (long↔long, start↔short, short↔stop, stop↔long). So when a
    /// transient is detected with one granule of lookahead we walk this 4-state
    /// machine to keep neighbours consistent.
    private func nextBlockType(
        previous: MDCTBlockType,
        currentTransient: Bool,
        nextTransient: Bool
    ) -> MDCTBlockType {
        switch previous {
        case .long, .stop:
            // Coming out of a long-style block. We can only switch to a `start`
            // window first; the transient itself is then captured by the short
            // block in the following granule.
            if currentTransient || nextTransient {
                return .start
            }
            return .long
        case .start:
            // A start block must always be followed by short blocks for the
            // window-overlap math to cancel correctly.
            return .shortBlocks
        case .shortBlocks:
            // Stay short while there is still transient activity in or just past
            // this granule; otherwise transition out via a stop block so the next
            // granule can return to long.
            if currentTransient || nextTransient {
                return .shortBlocks
            }
            return .stop
        }
    }

    /// Lightweight transient check used for the granule of lookahead past the end
    /// of the current frame. We don't update detector state here so the per-channel
    /// energy history stays aligned with the granules we actually encode.
    private func transientPreview(
        pcm: UnsafePointer<Float>,
        stride sampleStride: Int,
        channel _: Int
    ) -> Bool {
        // De-interleave into a per-channel scratch of the right length, then run
        // the same heuristic the detector uses without storing previous-energy state.
        let granuleSamples = samplesPerGranule
        var monoScratch = [Float](repeating: 0, count: granuleSamples)
        for index in 0 ..< granuleSamples {
            monoScratch[index] = pcm[index * sampleStride]
        }
        let subWindowSize = granuleSamples / 3
        guard subWindowSize > 0 else {
            return false
        }
        var maxEnergy = 0.0
        var minEnergy = Double.greatestFiniteMagnitude
        for windowIndex in 0 ..< 3 {
            var energy = 0.0
            let start = windowIndex * subWindowSize
            for sampleIndex in 0 ..< subWindowSize {
                let value = Double(monoScratch[start + sampleIndex])
                energy += value * value
            }
            energy /= Double(subWindowSize)
            if energy > maxEnergy {
                maxEnergy = energy
            }
            if energy < minEnergy {
                minEnergy = energy
            }
        }
        let intraRatio = minEnergy > 1e-9 ? maxEnergy / minEnergy : 0.0
        let intraOnsetSpike = minEnergy <= 1e-9 && maxEnergy > 1e-9
        return intraOnsetSpike || intraRatio > 10.0
    }

    // MARK: - Bitstream writing

    private func writeBitstream(useMidSide: Bool) -> Data {
        let nominalFrameSize = frameSizeBytes
        let paddingBit = false
        let frameSize = paddingBit ? nominalFrameSize + 1 : nominalFrameSize

        let headerBytes = 4
        let sideInfoBytes = channels == 1 ? 17 : 32
        let mainDataBytes = frameSize - headerBytes - sideInfoBytes

        // Write main data (scale factors + Huffman)
        mainDataWriter.reset()
        for granule in 0 ..< 2 {
            for channel in 0 ..< channels {
                let granuleInfo = granuleInfosScratch[granule][channel]
                writeScaleFactors(writer: mainDataWriter, granuleInfo: granuleInfo)
                granuleQuantizedScratch[granule * channels + channel].withUnsafeBufferPointer { quantizedBuffer in
                    writeHuffman(writer: mainDataWriter, quantized: quantizedBuffer, granuleInfo: granuleInfo)
                }
            }
        }
        mainDataWriter.byteAlign()
        let mainDataRaw = mainDataWriter.toData()

        // Channel mode: mono → 3 (mono), stereo + M/S → 1 (jointStereo) with
        // mode_extension bit 1 set (M/S on, intensity stereo off), stereo + L/R → 0
        // (plain stereo) with no extension bits.
        let channelMode: Int
        let modeExtension: Int
        if channels == 1 {
            channelMode = 3
            modeExtension = 0
        } else if useMidSide {
            channelMode = 1
            modeExtension = 0b10
        } else {
            channelMode = 0
            modeExtension = 0
        }

        var currentFrame = PendingMP3Frame(
            granuleInfos: granuleInfosScratch,
            mainData: mainDataRaw,
            mainDataBegin: 0,
            mainDataCapacity: mainDataBytes,
            paddingBit: paddingBit,
            channelMode: channelMode,
            modeExtension: modeExtension
        )

        var output = Data()
        if let previousFrame = pendingFrame {
            let carriedBytes = min(previousFrame.availableReservoirBytes, currentFrame.mainData.count, maxReservoir / 8)
            currentFrame.mainDataBegin = carriedBytes
            output.append(renderFrame(previousFrame, futureMainDataPrefix: currentFrame.mainData.prefix(carriedBytes)))
        }

        pendingFrame = currentFrame
        reservoir = min(currentFrame.availableReservoirBytes * 8, maxReservoir)

        return output
    }

    private var mainDataBytesForCurrentFrame: Int {
        let headerBytes = 4
        let sideInfoBytes = channels == 1 ? 17 : 32
        return frameSizeBytes - headerBytes - sideInfoBytes
    }

    private func renderFrame(_ frame: PendingMP3Frame, futureMainDataPrefix: Data) -> Data {
        var mainDataPayload = Data(capacity: frame.mainDataCapacity)
        mainDataPayload.append(contentsOf: frame.mainData.dropFirst(frame.mainDataBegin))

        // The quantizer should stay within the current frame plus real bytes carried
        // by the previous frame. Truncating is a last-resort guard for malformed input.
        if mainDataPayload.count + futureMainDataPrefix.count > frame.mainDataCapacity {
            assertionFailure("MP3 main data exceeded reservoir-adjusted payload: \(mainDataPayload.count) > \(frame.mainDataCapacity)")
            mainDataPayload = mainDataPayload.prefix(max(0, frame.mainDataCapacity - futureMainDataPrefix.count))
        }

        let fillerCount = frame.mainDataCapacity - mainDataPayload.count - futureMainDataPrefix.count
        if fillerCount > 0 {
            mainDataPayload.append(Data(repeating: 0, count: fillerCount))
        }
        mainDataPayload.append(contentsOf: futureMainDataPrefix)

        // Header + side info are exactly `headerBytes + sideInfoBytes` once byte-aligned;
        // build them in their own bitstream writer and concatenate the main data
        // directly as bytes - no per-byte bit-level round trip.
        let headerBytes = 4
        let sideInfoBytes = channels == 1 ? 17 : 32
        let headerWriter = BitstreamWriter(reserveBytes: headerBytes + sideInfoBytes)
        writeHeader(
            writer: headerWriter,
            paddingBit: frame.paddingBit,
            channelMode: frame.channelMode,
            modeExtension: frame.modeExtension
        )
        writeSideInfo(writer: headerWriter, granuleInfos: frame.granuleInfos, mainDataBegin: frame.mainDataBegin)
        var frame = headerWriter.toData()
        frame.append(mainDataPayload)
        return frame
    }

    // MARK: - Header writing

    private func writeHeader(
        writer: BitstreamWriter,
        paddingBit: Bool,
        channelMode: Int,
        modeExtension: Int
    ) {
        // Sync word: 12 bits all 1
        writer.writeBits(0xFFF, count: 12)

        // ID: 1 = MPEG1
        writer.writeBit(1)

        // Layer: 01 = Layer III
        writer.writeBits(0b01, count: 2)

        // Protection bit: 1 = no CRC
        writer.writeBit(1)

        // Bitrate index
        writer.writeBits(bitrateIndex, count: 4)

        // Sampling frequency index
        writer.writeBits(sampleRateIndex, count: 2)

        // Padding bit
        writer.writeBit(paddingBit ? 1 : 0)

        // Private bit
        writer.writeBit(0)

        // Mode (2 bits): 0=stereo, 1=jointStereo, 2=dualChannel, 3=mono
        writer.writeBits(channelMode & 0x3, count: 2)

        // Mode extension (2 bits): only meaningful for jointStereo. Bit 1 = M/S on,
        // bit 0 = intensity stereo on. We use 0b10 (M/S only) when M/S is selected
        // and 0 otherwise.
        writer.writeBits(modeExtension & 0x3, count: 2)

        // Copyright: 0
        writer.writeBit(0)

        // Original: 1
        writer.writeBit(1)

        // Emphasis: 0
        writer.writeBits(0, count: 2)
    }

    // MARK: - Side info writing

    private func writeSideInfo(writer: BitstreamWriter, granuleInfos: [[GranuleInfo]], mainDataBegin: Int) {
        // main_data_begin (9 bits): bytes to read from previous frames' main data.
        writer.writeBits(min(mainDataBegin, 511), count: 9)

        // private_bits: 5 for mono, 3 for stereo
        let privateBits = channels == 1 ? 5 : 3
        writer.writeBits(0, count: privateBits)

        // scfsi[ch][4]: scale factor selection info (4 bits per channel)
        for _ in 0 ..< channels {
            writer.writeBits(0, count: 4) // scfsi bands 0-3 all 0
        }

        // Per granule, per channel
        for granule in 0 ..< 2 {
            for channel in 0 ..< channels {
                let granuleInfo = granuleInfos[granule][channel]

                // part2_3_length (12 bits)
                writer.writeBits(min(granuleInfo.part2_3_length, 4095), count: 12)

                // big_values (9 bits)
                writer.writeBits(min(granuleInfo.bigValues, 288), count: 9)

                // global_gain (8 bits)
                writer.writeBits(granuleInfo.globalGain & 0xFF, count: 8)

                // scalefac_compress (4 bits)
                writer.writeBits(granuleInfo.scaleFactorCompress & 0xF, count: 4)

                // window_switching_flag (1 bit)
                writer.writeBit(granuleInfo.windowSwitchingFlag ? 1 : 0)

                if granuleInfo.windowSwitchingFlag {
                    // block_type (2 bits): 1=start, 2=short, 3=stop (0 invalid here)
                    writer.writeBits(granuleInfo.blockType & 0x3, count: 2)
                    // mixed_block_flag (1 bit)
                    writer.writeBit(granuleInfo.mixedBlockFlag ? 1 : 0)
                    // table_select[0], table_select[1] (5 bits each); table_select[2] is implicit 0
                    writer.writeBits(granuleInfo.tableSelect[0] & 0x1F, count: 5)
                    writer.writeBits(granuleInfo.tableSelect[1] & 0x1F, count: 5)
                    // subblock_gain[0..2] (3 bits each)
                    for windowIndex in 0 ..< 3 {
                        let gain = windowIndex < granuleInfo.subblockGain.count
                            ? granuleInfo.subblockGain[windowIndex]
                            : 0
                        writer.writeBits(gain & 0x7, count: 3)
                    }
                } else {
                    // Long-block path: three table_select entries plus region counts.
                    writer.writeBits(granuleInfo.tableSelect[0] & 0x1F, count: 5)
                    writer.writeBits(granuleInfo.tableSelect[1] & 0x1F, count: 5)
                    writer.writeBits(granuleInfo.tableSelect[2] & 0x1F, count: 5)
                    writer.writeBits(granuleInfo.region0Count & 0xF, count: 4)
                    writer.writeBits(granuleInfo.region1Count & 0x7, count: 3)
                }

                // preflag (1 bit)
                writer.writeBit(granuleInfo.preflag ? 1 : 0)

                // scalefac_scale (1 bit)
                writer.writeBit(granuleInfo.scaleFactorScale ? 1 : 0)

                // count1table_select (1 bit)
                writer.writeBit(granuleInfo.count1TableSelect & 1)
            }
        }
    }

    // MARK: - Scale factor writing

    private func writeScaleFactors(writer: BitstreamWriter, granuleInfo: GranuleInfo) {
        let lowBitLengths = [0, 0, 0, 0, 3, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4]
        let highBitLengths = [0, 1, 2, 3, 0, 1, 2, 3, 1, 2, 3, 1, 2, 3, 2, 3]

        let compressIndex = min(granuleInfo.scaleFactorCompress, 15)
        let lowBitLength = lowBitLengths[compressIndex]
        let highBitLength = highBitLengths[compressIndex]

        if granuleInfo.blockType == MDCTBlockType.shortBlocks.rawValue {
            // Pure short blocks: 6 short-bands × 3 windows at lowBitLength, then
            // 6 short-bands × 3 windows at highBitLength. Layout matches what the
            // decoder expects in `readScaleFactors` / `requantizeShort`.
            if lowBitLength > 0 {
                for band in 0 ..< 6 {
                    for windowIndex in 0 ..< 3 {
                        let scaleFactor = granuleInfo.scaleFactorsShort[windowIndex * 13 + band]
                        writer.writeBits(scaleFactor & ((1 << lowBitLength) - 1), count: lowBitLength)
                    }
                }
            }
            if highBitLength > 0 {
                for band in 6 ..< 12 {
                    for windowIndex in 0 ..< 3 {
                        let scaleFactor = granuleInfo.scaleFactorsShort[windowIndex * 13 + band]
                        writer.writeBits(scaleFactor & ((1 << highBitLength) - 1), count: highBitLength)
                    }
                }
            }
            return
        }

        // Long-block path (also used for start/stop, which decode through the long
        // IMDCT and read 21 long scale factors).
        if lowBitLength > 0 {
            for band in 0 ..< 11 {
                let scaleFactor = band < granuleInfo.scaleFactors.count ? granuleInfo.scaleFactors[band] : 0
                writer.writeBits(scaleFactor & ((1 << lowBitLength) - 1), count: lowBitLength)
            }
        }

        if highBitLength > 0 {
            for band in 11 ..< 21 {
                let scaleFactor = band < granuleInfo.scaleFactors.count ? granuleInfo.scaleFactors[band] : 0
                writer.writeBits(scaleFactor & ((1 << highBitLength) - 1), count: highBitLength)
            }
        }
    }

    // MARK: - Huffman data writing

    private func writeHuffman(writer: BitstreamWriter, quantized: UnsafeBufferPointer<Int>, granuleInfo: GranuleInfo) {
        let bigValuesEnd = granuleInfo.bigValues * 2

        let scaleFactorBandBounds = MP3Constants.scaleFactorBandBoundaries(sampleRate: sampleRate)
        let region0SfbCount = min(granuleInfo.region0Count + 1, scaleFactorBandBounds.count - 1)
        let region0End = min(scaleFactorBandBounds[region0SfbCount], bigValuesEnd)

        if granuleInfo.windowSwitchingFlag {
            // For any window-switched granule (short, start, or stop), only the
            // first two `tableSelect` entries are meaningful — the bitstream
            // doesn't carry tableSelect[2] and the decoder hardcodes it to 0
            // (see `MP3Decoder` side-info reader). With our region0Count/region1Count
            // already chosen so region 2 is empty (8/12 for short, 7/13 for
            // start/stop), writing pairs only for regions 0 and 1 is exactly what
            // the decoder will read back.
            writePairs(writer: writer, values: quantized, start: 0, end: region0End, tableIndex: granuleInfo.tableSelect[0])
            writePairs(writer: writer, values: quantized, start: region0End, end: bigValuesEnd, tableIndex: granuleInfo.tableSelect[1])
        } else {
            let region1SfbCount = min(region0SfbCount + granuleInfo.region1Count + 1, scaleFactorBandBounds.count - 1)
            let region1End = min(scaleFactorBandBounds[region1SfbCount], bigValuesEnd)

            writePairs(writer: writer, values: quantized, start: 0, end: region0End, tableIndex: granuleInfo.tableSelect[0])
            writePairs(writer: writer, values: quantized, start: region0End, end: region1End, tableIndex: granuleInfo.tableSelect[1])
            writePairs(writer: writer, values: quantized, start: region1End, end: bigValuesEnd, tableIndex: granuleInfo.tableSelect[2])
        }

        // Mirror Quantizer.countBits() so part2_3_length matches the emitted quads.
        var lastNonZeroIndex = -1
        for index in stride(from: quantized.count - 1, through: 0, by: -1) {
            if quantized[index] != 0 {
                lastNonZeroIndex = index
                break
            }
        }
        var count1Start = lastNonZeroIndex + 1
        count1Start = ((count1Start + 3) / 4) * 4
        count1Start = min(count1Start, quantized.count)

        var quadIndex = bigValuesEnd
        while quadIndex + 3 < count1Start {
            let first = quantized[quadIndex]
            let second = quantized[quadIndex + 1]
            let third = quantized[quadIndex + 2]
            let fourth = quantized[quadIndex + 3]

            if abs(first) > 1 || abs(second) > 1 || abs(third) > 1 || abs(fourth) > 1 {
                break
            }

            let (code, bits) = huffmanEncodeQuad(first: first, second: second, third: third, fourth: fourth, tableIndex: granuleInfo.count1TableSelect)
            writer.writeBits(code, count: bits)
            quadIndex += 4
        }
    }

    private func writePairs(writer: BitstreamWriter, values: UnsafeBufferPointer<Int>, start: Int, end: Int, tableIndex: Int) {
        var pairIndex = start
        let limit = min(end, values.count) - 1
        while pairIndex < limit {
            let firstValue = values[pairIndex]
            let secondValue = values[pairIndex + 1]
            let (code, bits) = huffmanEncodePair(firstValue: firstValue, secondValue: secondValue, tableIndex: tableIndex)
            writer.writeBits(code, count: bits)
            pairIndex += 2
        }
    }
}
