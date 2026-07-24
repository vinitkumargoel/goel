import SwiftUI

/// The 2 × 2 facts card: what has arrived, how big the file is, whether it can survive an
/// interruption, and how it will be verified.
///
/// Resume and checksum are the two that matter and the two every other downloader hides. They
/// are stated plainly, and `Supported` is green because it is a real guarantee about the
/// transfer, not decoration.
struct StatsCard: View {

    let download: Download

    // The key is a 10.5 pt tracked uppercase label — `.caption`. The value is the fact the cell
    // exists to state, so it takes `.title3` rather than `.body`: on `.body` a two-word value
    // like `Not supported` outgrows its half of the grid and `minimumScaleFactor` quietly shrinks
    // it back, which is Dynamic Type being honoured and then undone.
    @ScaledMetric(relativeTo: .caption) private var labelSize = Theme.Typo.Size.statLabel
    @ScaledMetric(relativeTo: .title3) private var valueSize = Theme.Typo.Size.statValue

    var body: some View {
        DetailCard {
            Grid(
                alignment: .leading,
                horizontalSpacing: DetailMetric.statColumnSpacing,
                verticalSpacing: DetailMetric.statRowSpacing
            ) {
                GridRow {
                    stat("Downloaded", Fmt.bytes(download.receivedBytes))
                    stat("Total", Fmt.bytes(download.totalBytes))
                }
                GridRow {
                    stat(
                        "Resume",
                        download.supportsResume ? "Supported" : "Not supported",
                        tint: download.supportsResume ? Theme.Color.success : Theme.Color.warning,
                        spokenValue: download.supportsResume
                            ? "Supported. This transfer survives an interruption."
                            : "Not supported. An interruption restarts this transfer."
                    )
                    stat(
                        "Checksum",
                        Self.checksumAlgorithm,
                        tint: download.checksumVerified ? Theme.Color.success : Theme.Color.label1,
                        spokenValue: download.checksumVerified
                            ? "\(Self.checksumAlgorithm), verified"
                            : "\(Self.checksumAlgorithm), not verified yet"
                    )
                }
            }
        }
    }

    /// The digest the app computes on completion. It is a property of this client, not of the
    /// server, so it is known before verification has run.
    private static let checksumAlgorithm = "SHA-256"

    /// `.stat` — a 10.5 pt tracked uppercase key over a 16 pt tabular value.
    private func stat(
        _ label: String,
        _ value: String,
        tint: Color = Theme.Color.label1,
        spokenValue: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: DetailMetric.statLabelSpacing) {
            Text(label.uppercased())
                .font(.system(size: labelSize))
                .tracking(Theme.Typo.statTracking)
                .foregroundStyle(Theme.Color.label3)
            Text(value)
                .font(.system(size: valueSize, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spokenValue ?? value)
    }
}

// MARK: - Previews

#Preview("Downloading — resumable, unverified") {
    let ubuntu = PreviewTransferEngine.fixtures().first { $0.id == PreviewTransferEngine.ubuntuID }
    return VStack {
        if let ubuntu { StatsCard(download: ubuntu) }
    }
    .padding(Theme.Metric.gutter)
    .frame(maxHeight: .infinity)
    .background(Theme.Color.ground)
    .preferredColorScheme(.dark)
}

#Preview("Completed — verified") {
    let blender = PreviewTransferEngine.fixtures().first { $0.id == PreviewTransferEngine.blenderID }
    return VStack {
        if let blender { StatsCard(download: blender) }
    }
    .padding(Theme.Metric.gutter)
    .frame(maxHeight: .infinity)
    .background(Theme.Color.ground)
    .preferredColorScheme(.dark)
}

#Preview("Unknown size — no resume") {
    let sample = Download(
        url: URL(string: "https://example.org/stream.bin") ?? URL(filePath: "/dev/null"),
        filename: "stream.bin",
        saveDirectory: "Goel°",
        kind: .https,
        status: .downloading,
        totalBytes: nil,
        receivedBytes: 412_300_000,
        supportsResume: false
    )
    return VStack {
        StatsCard(download: sample)
    }
    .padding(Theme.Metric.gutter)
    .frame(maxHeight: .infinity)
    .background(Theme.Color.ground)
    .preferredColorScheme(.dark)
}
