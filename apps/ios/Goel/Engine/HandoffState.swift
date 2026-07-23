import Foundation
import SwiftUI

// MARK: - TransferStrategy

/// How a transfer should be carried right now.
///
/// PRD §4.1's whole argument compressed into three cases: our segmented downloader is fast but
/// dies when the app suspends; a background `URLSession` is slow, out-of-process and survives.
/// The product answer is not to pick one — it is to switch between them without corrupting the
/// file in the switch.
public enum TransferStrategy: Sendable, Equatable {
    /// Foreground: N connections, N ranges, our speed advantage on display.
    case segmented
    /// Backgrounded mid-transfer: one system-managed `URLSession` task for `[prefix, total]`.
    case backgroundSingle
    /// Nothing should be moving — paused, waiting for Wi-Fi, finished, or failed.
    case suspended
}

// MARK: - HandoffState

/// The foreground ⇄ background state machine, as pure functions.
///
/// **There is deliberately no `URLSession` anywhere in this file.** The simulator does not truly
/// suspend apps and a physical-device run of the PRD's acceptance test (4 GB, locked an hour,
/// airplane mode toggled) is not something a build can gate on. So the gate is this type's unit
/// tests instead, and that only works if every decision the handoff makes is reachable without a
/// network, a session, or a scene.
///
/// ## The rule that matters
///
/// A background task may only resume from the **contiguous prefix** of the file, never from
/// `receivedBytes`. Six segments at 100/78/64/57/41/22 % of 1 000 bytes each have received
/// 3 620 bytes in total, but only the leading 1 780 are reachable from byte 0 — segment 0 is
/// complete, so segment 1's 780 bytes continue it, and segment 1 is incomplete, so everything
/// beyond 1 780 is separated from the start by a hole. Handing 3 620 to a `Range:` header writes
/// the remainder 1 840 bytes too early and produces a file that is the right length, passes no
/// checksum, and looks perfectly fine until someone opens it.
public enum HandoffState {

    // MARK: - Strategy

    /// The strategy a download should be running under, given the scene phase.
    ///
    /// `.inactive` (the transient phase during an app switcher swipe or an incoming call) is
    /// treated as foreground: tearing six connections down and rebuilding them every time a
    /// notification banner appears would cost far more than it saves.
    public static func strategy(for phase: ScenePhase, download: Download) -> TransferStrategy {
        switch download.status {
        case .completed, .failed, .paused, .waitingForWiFi, .verifying:
            // Nothing is in flight, or what is in flight is local CPU work with no socket to hand
            // over. Either way there is nothing to hand off.
            return .suspended
        case .queued, .probing, .downloading:
            break
        }

        // A finished byte count with a `.downloading` status is a state the store can hold for a
        // tick before the completion event lands. Do not start a background task for zero bytes.
        if let total = download.totalBytes, download.contiguousPrefix >= total {
            return .suspended
        }

        switch phase {
        case .active, .inactive:
            return .segmented
        case .background:
            // Without ranges there is no resume, so a background task would have to start from
            // zero and would throw away everything already on disk. Better to stop and keep the
            // bytes: PRD §4.1's "we say so honestly up front rather than failing at 99 %".
            return download.supportsResume ? .backgroundSingle : .suspended
        @unknown default:
            return .suspended
        }
    }

    // MARK: - Resume range

    /// The inclusive byte range a background task must request, or `nil` when there is nothing
    /// left to fetch or nothing sensible to ask for.
    ///
    /// Always anchored on ``Download/contiguousPrefix``. This is the single highest-risk value in
    /// T06; see the type-level note.
    public static func rangeForResume(_ download: Download) -> ClosedRange<Int64>? {
        guard let total = download.totalBytes, total > 0 else { return nil }
        let prefix = max(0, min(download.contiguousPrefix, total))
        guard prefix < total else { return nil }
        return prefix...(total - 1)
    }

    /// `"bytes=a-b"`. Inclusive on both ends, because that is what HTTP means: `bytes=0-99` is
    /// one hundred bytes, not ninety-nine and not one hundred and one.
    public static func rangeHeaderValue(_ range: ClosedRange<Int64>) -> String {
        "bytes=\(range.lowerBound)-\(range.upperBound)"
    }

    // MARK: - Adoption

    /// Whether bytes produced by a background task may be spliced into the bytes already on disk.
    ///
    /// The answer is "only when we can *prove* both sets came from the same remote file".
    /// Unprovable sameness is the case that silently corrupts, so every ambiguous combination
    /// answers `false` and the caller restarts from zero with ``TransferError/remoteFileChanged``.
    public static func canAdoptBackgroundResult(_ download: Download, validator: String?) -> Bool {
        switch (download.validator, validator) {
        case let (.some(known), .some(fresh)):
            // The ordinary path: an `ETag` (or `Last-Modified`) that still matches.
            return known == fresh
        case (.some, .none):
            // We had a validator and the server has stopped sending one. It may be the same file.
            // It may not be, and there is no way to tell.
            return false
        case (.none, .some):
            // We never had one, so there is nothing the fresh validator can be compared against.
            return false
        case (.none, .none):
            // No validator on either side. Safe only when there is nothing on disk to splice
            // into — i.e. the "adoption" is really just a fresh start.
            return download.contiguousPrefix == 0
        }
    }

    /// The download after a background task has made bytes `0..<offset` contiguous on disk.
    ///
    /// Two properties this must have, and both are tested:
    ///
    /// - **Idempotent.** A `.background → .active → .background` cycle can report the same
    ///   offset twice (the coordinator replays its manifest after an app relaunch). Applying it
    ///   twice must not double-count — hence an absolute offset parameter rather than a delta.
    /// - **Non-destructive.** Segments the foreground phase completed *beyond* the background
    ///   task's reach are still valid bytes on disk; they are trimmed to start at `offset` and
    ///   kept, not discarded.
    public static func adopting(_ download: Download, contiguousBytes offset: Int64) -> Download {
        var updated = download
        let total = download.totalBytes
        let prefix = max(0, min(offset, total ?? offset))

        var segments: [Download.Segment] = []
        if prefix > 0 {
            segments.append(
                Download.Segment(id: 0, range: 0...(prefix - 1), receivedBytes: prefix, isActive: false)
            )
        }

        for segment in download.segments.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard segment.range.upperBound >= prefix else { continue }
            let lower = max(segment.range.lowerBound, prefix)
            guard lower <= segment.range.upperBound else { continue }
            // How far this segment's own forward run actually reached, clipped to `prefix`.
            let reach = segment.range.lowerBound + max(0, min(segment.receivedBytes, segment.totalBytes))
            let carried = min(max(0, reach - lower), segment.range.upperBound - lower + 1)
            segments.append(
                Download.Segment(
                    id: segments.count,
                    range: lower...segment.range.upperBound,
                    receivedBytes: carried,
                    isActive: false
                )
            )
        }

        updated.segments = segments.enumerated().map { index, segment in
            var segment = segment
            segment.id = index
            return segment
        }
        let summed = updated.segments.reduce(Int64(0)) { $0 + $1.receivedBytes }
        updated.receivedBytes = min(summed, total ?? summed)
        return updated
    }

    // MARK: - Range algebra

    /// Sorted, merged, non-overlapping. Adjacent ranges (`0...9` and `10...19`) coalesce, which
    /// is what keeps a sequential download's completed-block list from growing without bound.
    public static func merged(_ ranges: [ClosedRange<Int64>]) -> [ClosedRange<Int64>] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var out: [ClosedRange<Int64>] = [sorted[0]]
        for range in sorted.dropFirst() {
            let last = out[out.count - 1]
            if range.lowerBound <= last.upperBound + 1 {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                out.append(range)
            }
        }
        return out
    }

    /// The length of the run starting at byte 0 in a merged range list.
    public static func contiguousPrefix(of ranges: [ClosedRange<Int64>]) -> Int64 {
        guard let first = merged(ranges).first, first.lowerBound == 0 else { return 0 }
        return first.upperBound + 1
    }

    /// The ranges of `0...total-1` that `covered` does not include, in order.
    /// This is what a resumed download actually has left to fetch.
    public static func gaps(in covered: [ClosedRange<Int64>], total: Int64) -> [ClosedRange<Int64>] {
        guard total > 0 else { return [] }
        var out: [ClosedRange<Int64>] = []
        var cursor: Int64 = 0
        for range in merged(covered) {
            if range.lowerBound > cursor {
                out.append(cursor...(range.lowerBound - 1))
            }
            cursor = max(cursor, range.upperBound + 1)
            if cursor >= total { break }
        }
        if cursor < total { out.append(cursor...(total - 1)) }
        return out
    }
}
