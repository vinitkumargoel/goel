import SwiftUI
import GoelCore

/// Observes only the toast queue, so a toast coming or going redraws this capsule alone.
struct ToastOverlay: View {
    @ObservedObject var queue: ToastQueue
    var bottomPadding: CGFloat = 52

    var body: some View {
        Group {
            if let toast = queue.current {
                HStack(spacing: 9) {
                    Image(systemName: toast.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .foregroundStyle(toast.isError ? Theme.red : Theme.green)
                        .a11yDecorative()
                    Text(toast.message).scaledFont(size: Theme.TextSize.body)
                    if let action = toast.action {
                        Button(action.title) { queue.performAction() }
                            .buttonStyle(.borderless)
                            .scaledFont(size: Theme.TextSize.body, weight: .semibold)
                            .foregroundStyle(Theme.accent)
                    }
                    IconButton(symbol: "xmark", help: L10n.t("Dismiss"), size: 9.5) {
                        queue.dismiss(toast.id)
                    }
                    .padding(.trailing, -6)
                }
                .padding(.leading, 15)
                .padding(.trailing, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Theme.hairline))
                .shadow(radius: 12, y: 6)
                // Reading (or reaching for the button) must not race the timer.
                .onHover { inside in inside ? queue.hold() : queue.release() }
                .padding(.bottom, bottomPadding)
                .transition(.opacity)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(toast.message)
                .id(toast.id)
            }
        }
        // A plain fade: fine under Reduce Motion, which only rules out movement.
        .animation(.easeInOut(duration: 0.15), value: queue.current)
    }
}
