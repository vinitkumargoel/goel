import SwiftUI
import AppKit
import GoelCore

/// Where the bottom detail panel's height may go, in points.
enum DetailPanelHeight {
    static let standard: Double = 300
    static let range: ClosedRange<Double> = 220...480
    /// One VoiceOver increment or arrow-key press.
    static let step: Double = 20
    /// The list above the panel keeps at least this much of the column.
    static let listReserve: Double = 220
    /// However short the window, the panel never shrinks below this.
    static let floor: Double = 120

    static func clamped(_ height: Double) -> Double {
        guard height.isFinite else { return standard }
        return min(max(height, range.lowerBound), range.upperBound)
    }

    /// The height to draw with `available` points in the list column: the stored preference,
    /// cut back so the list above keeps ``listReserve``. Never persisted, so the preference
    /// returns once the window grows again. Unknown (zero) space leaves the preference alone.
    static func fitted(_ height: Double, available: Double) -> Double {
        let preferred = clamped(height)
        guard available.isFinite, available > 0 else { return preferred }
        return max(floor, min(preferred, available - listReserve))
    }
}

/// The divider above the bottom panel doubles as its resize grip: drag it, arrow-key it when
/// focused, or adjust it with VoiceOver.
struct DetailPanelResizeHandle: View {
    /// The stored preference; written once per drag, not on every frame.
    @Binding var storedHeight: Double
    /// The height being drawn mid-drag; nil otherwise.
    @Binding var liveHeight: Double?
    /// The height actually on screen, after fitting to the window.
    let displayedHeight: Double

    @State private var dragStartHeight: Double?
    @State private var isCursorPushed = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Divider()
            .overlay {
                Rectangle()
                    .fill(isFocused ? Theme.accent.opacity(0.6) : Color.clear)
                    .frame(height: isFocused ? 3 : 9)
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .onHover { setCursor($0) }
                    .onDisappear { setCursor(false) }
                    .gesture(drag)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($isFocused)
                    .onKeyPress(.upArrow) { nudge(by: DetailPanelHeight.step); return .handled }
                    .onKeyPress(.downArrow) { nudge(by: -DetailPanelHeight.step); return .handled }
                    .accessibilityElement()
                    .accessibilityLabel(L10n.t("Detail panel height"))
                    .accessibilityValue(L10n.t("%d points", Int(displayedHeight)))
                    .accessibilityAdjustableAction { direction in
                        nudge(by: direction == .increment ? DetailPanelHeight.step : -DetailPanelHeight.step)
                    }
                    .help(L10n.t("Drag to resize the detail panel"))
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStartHeight ?? displayedHeight
                dragStartHeight = start
                // Dragging up makes the panel taller.
                liveHeight = DetailPanelHeight.clamped(start - value.translation.height)
            }
            .onEnded { _ in
                if let liveHeight { storedHeight = liveHeight }
                liveHeight = nil
                dragStartHeight = nil
            }
    }

    /// Steps from what is on screen, so a panel cut back by a short window responds at once.
    private func nudge(by step: Double) {
        storedHeight = DetailPanelHeight.clamped(displayedHeight + step)
    }

    /// Push and pop stay paired: a pop without its push would unwind someone else's cursor.
    private func setCursor(_ inside: Bool) {
        guard inside != isCursorPushed else { return }
        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        isCursorPushed = inside
    }
}
