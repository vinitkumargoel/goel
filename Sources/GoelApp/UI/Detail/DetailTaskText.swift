import Foundation
import GoelCore

/// Text the detail panel derives from a task. Pure, no views: moved unchanged out of the old
/// `DetailPanelComponents.swift` (`percentComplete` is also read by `TaskDisplay.compactSizeLine`).
extension DownloadTask {
    var percentComplete: Int { Int((fractionCompleted * 100).rounded()) }

    var sizeProgressText: String {
        L10n.t("%1$@ of %2$@", bytesDownloaded.byteString, totalBytes?.byteString ?? "—")
    }

    var etaText: String? {
        guard let eta = estimatedTimeRemaining, eta > 0 else { return nil }
        return "~\(DownloadTask.etaString(eta))"
    }

    var swarmSummary: (label: String, value: String) {
        if kind == .torrent {
            let seeds = seedCount.map { " · " + L10n.t("%d seeds", $0) } ?? ""
            return (L10n.t("Peers"), "\(connectionCount)\(seeds)")
        }
        return (L10n.t("Connections"), "\(connectionCount)")
    }
}

/// The Network tab's derived facts: the same rules the old Details tab applied, with a Studio
/// tone instead of a colour so the view picks the token.
enum DetailNetworkText {

    static func torrentProtocol(_ settings: AppSettings) -> String {
        var parts = ["BitTorrent"]
        if settings.btEnableDHT { parts.append("DHT") }
        if settings.btEnablePeX { parts.append("PeX") }
        if settings.btEnableLPD { parts.append("LPD") }
        return parts.joined(separator: " · ")
    }

    static func encryption(_ settings: AppSettings) -> String {
        switch settings.btEncryptionMode {
        case "require": return L10n.t("Required")
        case "disable": return L10n.t("Disabled")
        default: return L10n.t("Enabled (prefer)")
        }
    }

    static func range(_ task: DownloadTask) -> (text: String, tone: StudioTone?) {
        switch task.remoteInfo?.acceptRanges {
        case .some(true): return (L10n.t("Yes (Accept-Ranges)"), .good)
        case .some(false): return (L10n.t("No — single connection"), .warn)
        case .none: return ("—", nil)
        }
    }

    static func resumable(_ task: DownloadTask) -> (text: String, tone: StudioTone?) {
        task.resumeData != nil ? (L10n.t("Yes"), .good) : (L10n.t("Pending"), nil)
    }

    /// nil tone means "not provided": drawn as plain secondary text, not a pill.
    static func checksum(_ task: DownloadTask) -> (text: String, tone: StudioTone?) {
        guard let checksum = task.expectedChecksum else { return (L10n.t("Not provided"), nil) }
        let algorithm = checksum.algorithm.displayName
        if case .failed(.checksumMismatch) = task.status { return (L10n.t("%@ mismatch", algorithm), .bad) }
        switch task.status {
        case .verifying: return (L10n.t("Verifying (%@)…", algorithm), .info)
        case .completed: return (L10n.t("%@ verified", algorithm), .good)
        default: return (L10n.t("%@ pending", algorithm), .neutral)
        }
    }

    /// A magnet's `tr=` announce URLs, shown while the engine has no live tracker list yet.
    static func magnetTrackers(_ task: DownloadTask) -> [String] {
        guard case .magnet = task.source,
              let components = URLComponents(string: task.sourceLocator) else { return [] }
        return (components.queryItems ?? [])
            .filter { $0.name == "tr" }
            .compactMap(\.value)
    }

    static func trackerStatus(_ status: TorrentTracker.Status) -> (title: String, tone: StudioTone) {
        switch status {
        case .working: return (L10n.t("Working"), .good)
        case .updating: return (L10n.t("Updating"), .accent)
        case .error: return (L10n.t("Error"), .bad)
        case .inactive: return (L10n.t("Idle"), .neutral)
        }
    }

    /// "#3 · en0 Wi-Fi · releases.ubuntu.com": what a segment row is called.
    static func segmentLabel(_ segment: TaskConnection) -> String {
        let detail = segment.detail.trimmingCharacters(in: .whitespaces)
        return detail.isEmpty ? segment.label : "\(segment.label) · \(detail)"
    }

    /// A peer's client name; "peer" is the engine's placeholder for "unknown".
    static func peerClient(_ peer: TaskConnection) -> String? {
        let detail = peer.detail.trimmingCharacters(in: .whitespaces)
        return detail.isEmpty || detail == "peer" ? nil : detail
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }
}

/// Piece-map arithmetic: how many buckets are complete, partial or untouched.
struct DetailPieceCounts: Equatable {
    let have: Int
    let partial: Int
    let total: Int
    var missing: Int { total - have - partial }

    init(_ buckets: [Double]) {
        have = buckets.filter { $0 >= 0.999 }.count
        partial = buckets.filter { $0 > 0 && $0 < 0.999 }.count
        total = buckets.count
    }
}

/// The queue overview's ring: bytes done over bytes known across downloads still working.
enum DetailQueueProgress {
    static func fraction(_ tasks: [DownloadTask]) -> Double? {
        var total: Int64 = 0
        var done: Int64 = 0
        for task in tasks where task.status.isActiveWork {
            guard let size = task.totalBytes, size > 0 else { continue }
            total += size
            done += min(task.bytesDownloaded, size)
        }
        return total > 0 ? Double(done) / Double(total) : nil
    }
}
