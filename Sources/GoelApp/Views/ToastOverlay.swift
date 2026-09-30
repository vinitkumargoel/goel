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
                    Text(toast.message).scaledFont(size: 12.5)
                    if let action = toast.action {
                        Button(action.title) { queue.performAction() }
                            .buttonStyle(.borderless)
                            .scaledFont(size: 12.5, weight: .semibold)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Theme.hairline))
                .shadow(radius: 12, y: 6)
                .padding(.bottom, bottomPadding)
                .transition(.opacity)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(toast.message)
                .id(toast.id)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: queue.current)
    }
}
