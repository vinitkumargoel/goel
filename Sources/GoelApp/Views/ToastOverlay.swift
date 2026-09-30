import SwiftUI
import GoelCore

/// Observes only the toast queue, so a toast coming or going redraws this capsule alone.
struct ToastOverlay: View {
    @ObservedObject var queue: ToastQueue
    var bottomPadding: CGFloat = 52

    var body: some View {
        Group {
            if let toast = queue.current {
                ToastCapsule(queue: queue, toast: toast)
                    .padding(.bottom, bottomPadding)
                    .transition(.opacity)
                    .id(toast.id)
            }
        }
        // A plain fade: fine under Reduce Motion, which only rules out movement.
        .animation(.easeInOut(duration: 0.15), value: queue.current)
    }
}

/// One toast's capsule. Identified by the toast, so its hover and focus state start fresh with
/// every replacement, as the queue drops a hold when it presents a new toast.
private struct ToastCapsule: View {
    @ObservedObject var queue: ToastQueue
    let toast: Toast

    @State private var isHovering = false
    @FocusState private var focusedButton: ToastButton?
    @AccessibilityFocusState private var accessibilityFocus: ToastButton?

    private enum ToastButton: Hashable { case action, dismiss }

    /// Reading the toast, or reaching its button by pointer, keyboard or VoiceOver, must not race the timer.
    private var isHeld: Bool {
        isHovering || focusedButton != nil || accessibilityFocus != nil
    }

    var body: some View {
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
                    .focused($focusedButton, equals: .action)
                    .accessibilityFocused($accessibilityFocus, equals: .action)
            }
            IconButton(symbol: "xmark", help: L10n.t("Dismiss"), size: 9.5) {
                queue.dismiss(toast.id)
            }
            .focused($focusedButton, equals: .dismiss)
            .accessibilityFocused($accessibilityFocus, equals: .dismiss)
            .padding(.trailing, -6)
        }
        .padding(.leading, 15)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.hairline))
        .shadow(radius: 12, y: 6)
        .onHover { isHovering = $0 }
        .onChange(of: isHeld) { _, held in held ? queue.hold() : queue.release() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(toast.message)
    }
}
