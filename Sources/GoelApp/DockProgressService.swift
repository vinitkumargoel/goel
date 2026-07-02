import AppKit
import GoelCore

/// Mirrors the queue onto the Dock icon: a badge with the count of active
/// downloads, and a progress bar (aggregate bytes across every sized active
/// task) drawn over the app icon while anything is transferring.
///
/// Redraws are edge-triggered — the tile only re-renders when the badge text
/// changes or the aggregate fraction moves by ≥0.5% — so snapshot chatter
/// never turns into Dock churn.
@MainActor
final class DockProgressService {

    private let progressView = DockProgressView()
    private var installed = false
    private var lastBadge: String?
    private var lastFraction: Double = -1

    func update(with tasks: [DownloadTask]) {
        let active = tasks.filter { task in
            switch task.status {
            case .downloading, .requestingMetadata, .verifying: return true
            default: return false
            }
        }
        let badge = active.isEmpty ? nil : "\(active.count)"
        if badge != lastBadge {
            NSApp.dockTile.badgeLabel = badge
            lastBadge = badge
        }

        let sized = active.filter { ($0.totalBytes ?? 0) > 0 }
        let total = sized.reduce(Int64(0)) { $0 + ($1.totalBytes ?? 0) }
        let done = sized.reduce(Int64(0)) { $0 + min($1.bytesDownloaded, $1.totalBytes ?? 0) }
        let fraction = total > 0 ? Double(done) / Double(total) : -1

        let visibilityChanged = (fraction < 0) != (lastFraction < 0)
        guard visibilityChanged || abs(fraction - lastFraction) >= 0.005 else { return }
        lastFraction = fraction

        if fraction < 0 {
            if installed {
                NSApp.dockTile.contentView = nil
                installed = false
                NSApp.dockTile.display()
            }
            return
        }
        if !installed {
            progressView.frame = NSRect(x: 0, y: 0, width: 128, height: 128)
            NSApp.dockTile.contentView = progressView
            installed = true
        }
        progressView.fraction = fraction
        NSApp.dockTile.display()
    }
}

/// The dock tile's content while downloading: the normal app icon with a
/// rounded progress bar across its lower edge.
private final class DockProgressView: NSView {

    var fraction: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)

        let barHeight = bounds.height * 0.09
        let inset = bounds.width * 0.14
        let barRect = NSRect(x: inset, y: bounds.height * 0.08,
                             width: bounds.width - inset * 2, height: barHeight)
        let backing = NSBezierPath(roundedRect: barRect,
                                   xRadius: barHeight / 2, yRadius: barHeight / 2)
        NSColor.black.withAlphaComponent(0.55).setFill()
        backing.fill()

        var fillRect = barRect.insetBy(dx: 1.5, dy: 1.5)
        fillRect.size.width = max(fillRect.height,
                                  fillRect.width * CGFloat(min(max(fraction, 0), 1)))
        let fill = NSBezierPath(roundedRect: fillRect,
                                xRadius: fillRect.height / 2, yRadius: fillRect.height / 2)
        NSColor.controlAccentColor.setFill()
        fill.fill()
    }
}
