//
//  MP3EncoderProfiler.swift
//  MP3Coder
//
//  Created by GPT 5.5 and Opus 4.7 on 4/24/26.
//

import Foundation

/// Per-stage wall-clock accumulator attached to a single `MP3Encoder` instance.
/// Default behaviour is "no profiler attached" — `MP3Encoder.profiler` is `nil`,
/// the per-phase wrappers compile down to a direct call, and there is zero
/// overhead in production. Assign a profiler before encoding to opt in:
///
///     let profiler = MP3EncoderProfiler()
///     encoder.profiler = profiler
///     _ = encoder.encode(pcm: samples)
///     _ = encoder.flush()
///     print(profiler.summary(sampleRate: 44_100))
public final class MP3EncoderProfiler {
    public enum Phase: String, CaseIterable, Sendable {
        case deinterleave
        case transient
        case filterBank
        case mdct
        case midSideDecision
        case midSideTransform
        case psychoacoustic
        case quantize
        case writeMainData
        case writeHeaderSideInfo
    }

    /// Quantizer-specific counters surfaced through the profiler. These do not
    /// belong in `Phase` (they are not wall-clock buckets) but are useful for
    /// reasoning about rate-control behaviour: how many gain probes the binary
    /// search burns per `innerLoop`, how often distortion-control hits its
    /// 3-iteration cap, how often the smoothing fallback fires. Populated by
    /// `Quantizer` when a profiler is attached to the owning `MP3Encoder`.
    public enum Counter: Int, CaseIterable, Sendable {
        /// Number of `innerLoop` invocations.
        case innerLoopCalls = 0
        /// Number of `quantizeFromCachedAbsPow075` probes (binary search probes
        /// + the optional hint warm-start probe + the optional smoothing
        /// re-quantize). Divide by `innerLoopCalls` for mean probes per call.
        case innerLoopProbes
        /// Number of times the warm-start hint probe was satisfied before the
        /// binary search began (i.e. hint was already a feasible upper bound).
        case innerLoopHintHits
        /// Number of times the smoothing-clamp re-quantize fired (best gain
        /// dropped more than `gainSmoothingMaxDelta` below the hint).
        case innerLoopSmoothingFires
        /// Number of `distortionControlPass` invocations (one per `outerLoop`
        /// long-block call, plus any reservoir-pass retries).
        case distortionPasses
        /// Number of distortion-control iterations actually executed across
        /// every pass. Divide by `distortionPasses` for mean iterations.
        case distortionIterations
        /// Number of `outerLoop` calls that ran a reservoir refinement pass
        /// (i.e. `reservoirBits > 0` and masking pressure exceeded threshold).
        case outerLoopReservoirPasses
        /// Number of short-block fast-path calls (`outerLoopShort`).
        case outerLoopShortPasses

        var displayName: String {
            switch self {
            case .innerLoopCalls:
                "innerLoopCalls"
            case .innerLoopProbes:
                "innerLoopProbes"
            case .innerLoopHintHits:
                "innerLoopHintHits"
            case .innerLoopSmoothingFires:
                "innerLoopSmoothingFires"
            case .distortionPasses:
                "distortionPasses"
            case .distortionIterations:
                "distortionIterations"
            case .outerLoopReservoirPasses:
                "outerLoopReservoirPasses"
            case .outerLoopShortPasses:
                "outerLoopShortPasses"
            }
        }
    }

    private var phaseNanos: [Phase: UInt64] = [:]
    private var phaseCalls: [Phase: UInt64] = [:]
    /// Counter storage indexed by `Counter.rawValue` so the increment helper
    /// stays a single array store — `[Counter: UInt64]` measurably slowed the
    /// inner loop because every probe paid a dictionary lookup.
    private var counterValues: [UInt64] = Array(repeating: 0, count: Counter.allCases.count)
    public private(set) var framesEncoded: UInt64 = 0
    public private(set) var samplesEncoded: UInt64 = 0

    public init() {
    }

    public func reset() {
        phaseNanos.removeAll(keepingCapacity: true)
        phaseCalls.removeAll(keepingCapacity: true)
        for index in counterValues.indices {
            counterValues[index] = 0
        }
        framesEncoded = 0
        samplesEncoded = 0
    }

    public func recordFrame(samples: Int) {
        framesEncoded &+= 1
        samplesEncoded &+= UInt64(samples)
    }

    @inline(__always)
    func measure<T>(_ phase: Phase, _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try body()
        let elapsed = DispatchTime.now().uptimeNanoseconds &- start
        phaseNanos[phase, default: 0] &+= elapsed
        phaseCalls[phase, default: 0] &+= 1
        return result
    }

    public func nanos(for phase: Phase) -> UInt64 {
        phaseNanos[phase] ?? 0
    }

    public func calls(for phase: Phase) -> UInt64 {
        phaseCalls[phase] ?? 0
    }

    /// Increment a quantizer counter by `amount`. Called on the encoder's
    /// thread while quantization is in flight; storage is an `Int`-indexed
    /// array so the inner loop pays one array store, not a dictionary lookup.
    @inline(__always)
    func incrementCounter(_ counter: Counter, by amount: UInt64 = 1) {
        counterValues[counter.rawValue] &+= amount
    }

    /// Merge a per-quantizer counter snapshot into the shared profiler. The
    /// per-channel parallel quantize phase keeps counters local so concurrent
    /// quantizers never write to the same storage; the encoder drains those
    /// snapshots into here after the parallel block completes.
    func mergeCounters(_ snapshot: [UInt64]) {
        let limit = Swift.min(snapshot.count, counterValues.count)
        for index in 0 ..< limit {
            counterValues[index] &+= snapshot[index]
        }
    }

    public func value(for counter: Counter) -> UInt64 {
        counterValues[counter.rawValue]
    }

    public var totalNanos: UInt64 {
        phaseNanos.values.reduce(0, +)
    }

    public func summary(sampleRate: Int) -> String {
        let totalNanos = totalNanos
        let audioSeconds = sampleRate > 0
            ? Double(samplesEncoded) / Double(sampleRate)
            : 0
        let totalSeconds = Double(totalNanos) / 1_000_000_000
        let realtimeRatio = totalSeconds > 0 ? audioSeconds / totalSeconds : 0

        var lines: [String] = []
        lines.append(String(format: "  Frames encoded: %d (%.3fs of audio)", framesEncoded, audioSeconds))
        lines.append(String(format: "  Profiled total: %.3fs", totalSeconds))
        lines.append(String(format: "  Realtime ratio: %.2fx", realtimeRatio))
        lines.append("")
        lines.append("  " + columnHeader())

        let rows: [(Phase, UInt64, UInt64)] = Phase.allCases.compactMap { phase in
            guard let nanos = phaseNanos[phase], let calls = phaseCalls[phase] else {
                return nil
            }
            return (phase, nanos, calls)
        }
        .sorted { $0.1 > $1.1 }

        for (phase, nanos, calls) in rows {
            let seconds = Double(nanos) / 1_000_000_000
            let percent = totalNanos > 0
                ? Double(nanos) * 100 / Double(totalNanos)
                : 0
            let perCallMicros = calls > 0
                ? Double(nanos) / Double(calls) / 1_000
                : 0
            lines.append("  " + columnRow(
                phase: phase.rawValue,
                seconds: seconds,
                percent: percent,
                calls: calls,
                perCallMicros: perCallMicros
            ))
        }

        if counterValues.contains(where: { $0 > 0 }) {
            lines.append("")
            lines.append("  Quantizer counters:")
            let innerCalls = value(for: .innerLoopCalls)
            let innerProbes = value(for: .innerLoopProbes)
            let hintHits = value(for: .innerLoopHintHits)
            let smoothFires = value(for: .innerLoopSmoothingFires)
            let distPasses = value(for: .distortionPasses)
            let distIters = value(for: .distortionIterations)
            let reservoirPasses = value(for: .outerLoopReservoirPasses)
            let shortPasses = value(for: .outerLoopShortPasses)
            let probesPerCall = innerCalls > 0
                ? Double(innerProbes) / Double(innerCalls)
                : 0
            let itersPerPass = distPasses > 0
                ? Double(distIters) / Double(distPasses)
                : 0
            lines.append(String(format: "    innerLoop calls: %d", innerCalls))
            lines.append(String(format: "    innerLoop probes: %d (%.2f / call)", innerProbes, probesPerCall))
            lines.append(String(format: "    innerLoop hint hits: %d", hintHits))
            lines.append(String(format: "    innerLoop smoothing fires: %d", smoothFires))
            lines.append(String(format: "    distortion passes: %d (%.2f iters / pass)", distPasses, itersPerPass))
            lines.append(String(format: "    outerLoop reservoir passes: %d", reservoirPasses))
            lines.append(String(format: "    outerLoop short-block passes: %d", shortPasses))
        }

        return lines.joined(separator: "\n")
    }

    private func columnHeader() -> String {
        let phaseColumn = "phase".padding(toLength: 22, withPad: " ", startingAt: 0)
        let timeColumn = "time".leftPadded(toLength: 9)
        let pctColumn = "pct".leftPadded(toLength: 7)
        let callsColumn = "calls".leftPadded(toLength: 10)
        let perCallColumn = "us/call".leftPadded(toLength: 12)
        return "\(phaseColumn) \(timeColumn) \(pctColumn) \(callsColumn) \(perCallColumn)"
    }

    private func columnRow(phase: String, seconds: Double, percent: Double, calls: UInt64, perCallMicros: Double) -> String {
        let phaseColumn = phase.padding(toLength: 22, withPad: " ", startingAt: 0)
        let timeColumn = String(format: "%.3fs", seconds).leftPadded(toLength: 9)
        let pctColumn = String(format: "%.1f%%", percent).leftPadded(toLength: 7)
        let callsColumn = String(calls).leftPadded(toLength: 10)
        let perCallColumn = String(format: "%.2f", perCallMicros).leftPadded(toLength: 12)
        return "\(phaseColumn) \(timeColumn) \(pctColumn) \(callsColumn) \(perCallColumn)"
    }
}

private extension String {
    func leftPadded(toLength length: Int, with character: Character = " ") -> String {
        if count >= length {
            return self
        }
        return String(repeating: character, count: length - count) + self
    }
}
