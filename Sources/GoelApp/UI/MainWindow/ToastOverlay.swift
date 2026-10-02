import SwiftUI
import GoelCore

/// Observes only the toast queue, so a toast coming or going redraws this card alone.
/// Hosted by the main window and by the Settings window.
struct ToastOverlay: View {
    @ObservedObject var queue: ToastQueue
    var bottomPadding: CGFloat = 56

    var body: some View {
        Group {
            if let toast = queue.current {
                ToastCard(queue: queue, toast: toast)
                    .padding(.bottom, bottomPadding)
                    .transition(.opacity)
                    .id(toast.id)
            }
        }
        // A plain fade: fine under Reduce Motion, which only rules out movement.
        .animation(.easeInOut(duration: 0.15), value: queue.current)
    }
}

/// One toast (`.toast`): a floating card with a tinted glyph tile, the message, a "+N waiting"
/// count, the action (Undo, Show…) and ✕. Identified by the toast, so its hover and focus state
/// start fresh with every replacement, as the queue drops a hold when it presents a new toast.
private struct ToastCard: View {
    @ObservedObject var queue: ToastQueue
    let toast: Toast

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.studioStillFrames) private var stillFrames
    @FocusState private var focusedButton: ToastButton?
    @AccessibilityFocusState private var accessibilityFocus: ToastButton?

    private enum ToastButton: Hashable { case action, dismiss }

    /// Reading the toast, or reaching its button by pointer, keyboard or VoiceOver, must not race the timer.
    private var isHeld: Bool {
        isHovering || focusedButton != nil || accessibilityFocus != nil
    }

    var body: some View {
        let tone = Self.tone(for: toast.kind)
        HStack(spacing: Studio.Space.m) {
            Image(systemName: Self.symbol(for: toast.kind))
                .font(StudioFonts.font(.ui, size: 14, weight: 700))
                .foregroundStyle(tone.foreground)
                .frame(width: 32, height: 32)
                .background(tone.background,
                            in: RoundedRectangle(cornerRadius: Studio.Radius.control, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.message)
                    .studioFont(.bodyStrong)
                    .foregroundStyle(Studio.Palette.ink)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if !queue.pending.isEmpty {
                    Text(L10n.t("%d more waiting", queue.pending.count))
                        .studioFont(.tiny)
                        .foregroundStyle(Studio.Palette.ink3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let action = toast.action {
                Button(action.title) { queue.performAction() }
                    .buttonStyle(.studio(.soft, size: .small))
                    .focused($focusedButton, equals: .action)
                    .accessibilityFocused($accessibilityFocus, equals: .action)
            }
            StudioIconButton("xmark", label: L10n.t("Dismiss"), size: .small) {
                queue.dismiss(toast.id)
            }
            .focused($focusedButton, equals: .dismiss)
            .accessibilityFocused($accessibilityFocus, equals: .dismiss)
        }
        .padding(.leading, Studio.Space.m)
        .padding([.vertical, .trailing], Studio.Space.sm)
        .frame(minWidth: 320, maxWidth: 440)
        .fixedSize(horizontal: true, vertical: false)
        .overlay(alignment: .bottom) {
            if toast.action != nil, let countdown = queue.countdown {
                CountdownHairline(countdown: countdown, animated: !reduceMotion && !stillFrames)
                    .padding(.horizontal, Studio.Space.l)
                    .padding(.bottom, 1)
            }
        }
        .studioSurface(.raised, radius: Studio.Radius.card, elevation: .floating)
        .onHover { isHovering = $0 }
        .onChange(of: isHeld) { _, held in held ? queue.hold() : queue.release() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(toast.message)
    }

    static func symbol(for kind: Toast.Kind) -> String {
        switch kind {
        case .success: return "checkmark"
        case .error: return "exclamationmark.triangle"
        case .warning: return "exclamationmark"
        case .info: return "info"
        }
    }

    static func tone(for kind: Toast.Kind) -> StudioTone {
        switch kind {
        case .success: return .good
        case .error: return .bad
        case .warning: return .warn
        case .info: return .accent
        }
    }
}

/// A 2 pt accent line along the card's foot that shrinks as an action toast's time runs out,
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
        .accessibilityHidden(true)
    }

    private func bar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            Capsule()
                .fill(Studio.Palette.accent)
                .frame(width: geo.size.width * fraction)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
