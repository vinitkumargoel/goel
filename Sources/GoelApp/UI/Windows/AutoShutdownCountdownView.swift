import SwiftUI
import GoelCore

/// Blocking card over the window while an auto quit/sleep/shutdown counts down.
struct AutoShutdownCountdownView: View {
    @ObservedObject var countdown: AutoShutdownCountdown

    var body: some View {
        if case .counting(let intent, let remaining) = countdown.phase {
            ZStack {
                Studio.Palette.scrim
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                AutoShutdownCountdownCard(intent: intent, remaining: remaining,
                                          total: AutoShutdownCountdown.defaultSeconds,
                                          onCancel: countdown.cancel,
                                          onNow: countdown.performNow)
            }
            .transition(.opacity)
        }
    }
}

/// The countdown card itself: a draining arc with the seconds left, what is about to happen, and
/// Cancel (the default: a stray Return must never power off) beside "do it now".
struct AutoShutdownCountdownCard: View {
    let intent: DrainIntent
    let remaining: Int
    let total: Int
    let onCancel: () -> Void
    let onNow: () -> Void

    var body: some View {
        VStack(spacing: Studio.Space.ml) {
            StudioProgressArc(fraction: Double(remaining) / Double(max(1, total)), tone: .warn, diameter: 104,
                              lineWidth: 8, accessibilityLabel: L10n.t("Time left")) {
                Text(verbatim: "\(remaining)")
                    .studioFont(.display, size: 34, weight: 750, tabularNumbers: true)
                    .foregroundStyle(Studio.Palette.ink)
            }
            .accessibilityValue(AutoShutdownCountdown.message(remaining: remaining))
            VStack(spacing: Studio.Space.xs) {
                Text(AutoShutdownCountdown.title(for: intent))
                    .studioFont(.title3)
                    .foregroundStyle(Studio.Palette.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(AutoShutdownCountdown.message(remaining: remaining))
                    .studioFont(.small)
                    .monospacedDigit()
                    .foregroundStyle(Studio.Palette.ink2)
            }
            HStack(spacing: Studio.Space.sm) {
                Button(L10n.t("Cancel"), role: .cancel, action: onCancel)
                    .buttonStyle(.studio(.secondary))
                    .keyboardShortcut(.defaultAction)
                Button(AutoShutdownCountdown.actionTitle(for: intent), systemImage: Self.symbol(for: intent),
                       action: onNow)
                    .buttonStyle(.studio(.primary))
            }
            .padding(.top, Studio.Space.xxs)
        }
        .padding(.horizontal, Studio.Space.xl)
        .padding(.top, 24)
        .padding(.bottom, Studio.Space.xl)
        .frame(width: 330)
        .studioSurface(.sheet, radius: Studio.Radius.sheet, elevation: .floating)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onExitCommand(perform: onCancel)
    }

    static func symbol(for intent: DrainIntent) -> String {
        switch intent {
        case .quit: return "power"
        case .sleep: return "moon"
        case .shutdown: return "power.circle"
        }
    }
}
