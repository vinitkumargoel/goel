import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// AVFoundation ships no demuxer for Matroska, WebM, FLV or WMV. Handed one, `VideoPlayer`
/// draws a dead frame and a slashed play button — no error, no delegate callback, nothing the
/// player view can catch. The only reliable signal is to ask before opening the sheet.
///
/// The list is Apple's, not ours: `audiovisualTypes()` tracks what the installed OS actually
/// demuxes, so a future macOS that gains Matroska needs no change here.
enum InAppPlayback {

    /// Extension-level only. It settles the container, which is what rules out .mkv; a file whose
    /// container is fine but whose codecs are not still fails later, which is what
    /// `InAppPlayerView` reports.
    static func canPlay(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return supportedTypes.contains { type.conforms(to: $0) }
    }

    private static let supportedTypes: [UTType] =
        AVURLAsset.audiovisualTypes().compactMap { UTType($0.rawValue) }
}
