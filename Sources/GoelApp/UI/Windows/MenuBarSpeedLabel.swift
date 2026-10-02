import SwiftUI
import AppKit
import GoelCore

/// Drawn into a single template `NSImage` because the menu bar clips a two-line SwiftUI stack.
struct MenuBarSpeedLabel: View {
    @ObservedObject var telemetry: TelemetryStore

    var body: some View {
        // `.equatable()` gates the image-allocating redraw to real changes of the 2 Hz read-out.
        SpeedContent(sample: telemetry.displayedCombinedSpeed).equatable()
            // Always alive while the menu-bar item shows, so a banner click can build a window.
            .registersMainWindowOpener()
    }

    private struct SpeedContent: View, Equatable {
        let sample: SpeedSample

        var body: some View {
            if sample.down > 0 || sample.up > 0 {
                Image(nsImage: MenuBarSpeedLabel.speedImage(down: sample.down, up: sample.up))
                    .accessibilityLabel(
                        L10n.t("Goel downloads. Downloading at %1$@, uploading at %2$@.",
                               A11y.speed(sample.down), A11y.speed(sample.up)))
            } else {
                Image(systemName: "arrow.down.circle")
                    .accessibilityLabel(L10n.t("Goel downloads. Idle."))
            }
        }

        static func == (a: SpeedContent, b: SpeedContent) -> Bool { a.sample == b.sample }
    }

    private static func compact(_ bytesPerSec: Double) -> String {
        bytesPerSec > 0 ? Int64(bytesPerSec).byteString + "/s" : "0"
    }

    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)

    private static let fixedWidth: CGFloat =
        ceil(("↓ 8888.88 MB/s" as NSString).size(withAttributes: [.font: labelFont]).width) + 2

    static func speedImage(down: Double, up: Double) -> NSImage {
        let downText = "↓ " + compact(down)
        let upText   = "↑ " + compact(up)
        let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.labelColor]

        let lineH = ceil(("↑ 0" as NSString).size(withAttributes: attrs).height)
        let width = fixedWidth
        let height = max(NSStatusBar.system.thickness, lineH * 2)

        func drawRightAligned(_ text: String, atY y: CGFloat) {
            let w = (text as NSString).size(withAttributes: attrs).width
            (text as NSString).draw(at: NSPoint(x: width - w - 1, y: y), withAttributes: attrs)
        }

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        // NSImage origin is bottom-left, so the upload row draws lower and download a line-height above it.
        let bottomY = (height - lineH * 2) / 2
        drawRightAligned(upText,   atY: bottomY)
        drawRightAligned(downText, atY: bottomY + lineH)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
