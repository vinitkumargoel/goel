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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedButton: ToastButton?
    @AccessibilityFocusState private var accessibilityFocus: ToastButton?

    private enum ToastButton: Hashable { case action, dismiss }

    /// Reading the toast, or reaching its button by pointer, keyboard or VoiceOver, must not race the timer.
    private var isHeld: Bool {
        isHovering || focusedButton != nil || accessibilityFocus != nil
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: Self.symbol(for: toast.kind))
                .foregroundStyle(Self.tint(for: toast.kind))
                .a11yDecorative()
            Text(toast.message).scaledFont(size: Theme.TextSize.body)
            if !queue.pending.isEmpty {
                Text(verbatim: "+\(queue.pending.count)")
                    .scaledFont(size: Theme.TextSize.caption, weight: .bold, monospacedDigit: true)
                    .padding(.horizontal, 5)
                    .frame(minHeight: 16)
                    .background(Theme.fillHover, in: Capsule())
                    .foregroundStyle(.secondary)
                    .help(L10n.t("%d more waiting", queue.pending.count))
                    .accessibilityLabel(L10n.t("%d more waiting", queue.pending.count))
            }
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
        .overlay(alignment: .bottom) {
            if toast.action != nil, let countdown = queue.countdown {
                CountdownHairline(countdown: countdown, animated: !reduceMotion)
                    .padding(.horizontal, 14)
            }
        }
        .overlay(Capsule().stroke(Theme.hairline))
        .shadow(radius: 12, y: 6)
        .onHover { isHovering = $0 }
        .onChange(of: isHeld) { _, held in held ? queue.hold() : queue.release() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(toast.message)
    }

    static func symbol(for kind: Toast.Kind) -> String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    static func tint(for kind: Toast.Kind) -> Color {
        switch kind {
        case .success: return Theme.green
        case .error: return Theme.red
        case .warning: return Theme.orange
        case .info: return Theme.accent
        }
    }
}

/// A 2 pt accent line along the capsule's foot that shrinks as an action toast's time runs out,
/// so the Undo's deadline is visible. It freezes while the toast is held, and under Reduce
/// Motion it stays a static line at whatever is left instead of animating.
private struct CountdownHairline: View {
    let countdown: ToastCountdown
    let animated: Bool

    var body: some View {
        Group {
            if animated && countdown.isRunning {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    bar(countdown.fraction(at: context.date))
                }
            } else {
                bar(animated ? countdown.fraction(at: Date()) : 1)
            }
        }
        .frame(height: 2)
        .a11yDecorative()
    }

    private func bar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            Capsule()
                .fill(Theme.accent)
                .frame(width: geo.size.width * fraction)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
