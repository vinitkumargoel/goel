import Foundation
import GoelCore

/// The one-click choices for a video page. Every video preset asks yt-dlp for a single
/// ready-to-play file (`b`), since the download engine fetches one URL and can't merge tracks.
enum MediaPreset: String, CaseIterable, Identifiable {
    case best, p720, p480, audioM4A, audioMP3

    var id: String { rawValue }

    /// `maxHeight` is Settings › Max video quality; 0 means no cap.
    func formatSelector(maxHeight: Int) -> String {
        switch self {
        case .best: return maxHeight > 0 ? "b[height<=\(maxHeight)]/b" : "b"
        case .p720: return "b[height<=720]/b"
        case .p480: return "b[height<=480]/b"
        case .audioM4A: return "ba[ext=m4a]/ba/b"
        case .audioMP3: return "ba/b"
        }
    }

    func title(maxHeight: Int) -> String {
        switch self {
        case .best: return maxHeight > 0 ? L10n.t("Best ≤ %dp", maxHeight) : L10n.t("Best")
        case .p720: return "720p"
        case .p480: return "480p"
        case .audioM4A: return L10n.t("Audio · M4A")
        case .audioMP3: return L10n.t("Audio · MP3")
        }
    }

    var detail: String {
        switch self {
        case .best: return L10n.t("Highest quality, one playable file")
        case .p720, .p480: return L10n.t("Smaller file")
        case .audioM4A, .audioMP3: return L10n.t("Sound only")
        }
    }

    var symbol: String {
        switch self {
        case .best: return "sparkles.tv"
        case .p720, .p480: return "tv"
        case .audioM4A, .audioMP3: return "waveform"
        }
    }

    /// Audio presets hand the finished file to Extract Audio.
    var chainedAudio: AudioExtractionFormat? {
        switch self {
        case .audioM4A: return .m4a
        case .audioMP3: return .mp3
        case .best, .p720, .p480: return nil
        }
    }

    /// yt-dlp often serves M4A audio directly; extracting it again would only duplicate the file.
    static func needsExtraction(_ format: AudioExtractionFormat, downloadedExtension ext: String) -> Bool {
        ext.lowercased() != format.rawValue
    }

    /// Keeps only pending extractions whose download is still listed and hasn't failed.
    static func prunedChain(_ chain: [UUID: AudioExtractionFormat], listed: Set<UUID>,
                            failed: Set<UUID>) -> [UUID: AudioExtractionFormat] {
        chain.filter { listed.contains($0.key) && !failed.contains($0.key) }
    }
}
