import SwiftUI
import GoelCore

/// Blocking card over the window while an auto quit/sleep/shutdown counts down.
struct AutoShutdownCountdownView: View {
    @ObservedObject var countdown: AutoShutdownCountdown

    var body: some View {
        if case .counting(let intent, let remaining) = countdown.phase {
            ZStack {
                Color.black.opacity(0.25).ignoresSafeArea()
                VStack(spacing: 14) {
                    Image(systemName: intent == .quit ? "power" : (intent == .sleep ? "moon.fill" : "power.circle.fill"))
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.orange)
                        .a11yDecorative()
                    Text(AutoShutdownCountdown.title(for: intent))
                        .scaledFont(size: 14, weight: .semibold)
                        .multilineTextAlignment(.center)
                    Text(AutoShutdownCountdown.message(remaining: remaining))
                        .scaledFont(size: 12, monospacedDigit: true)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        // Return cancels (Escape too, below): a stray keypress must never power off.
                        Button(L10n.t("Cancel"), role: .cancel) { countdown.cancel() }
                            .keyboardShortcut(.defaultAction)
                        Button(AutoShutdownCountdown.actionTitle(for: intent)) { countdown.performNow() }
                    }
                    .controlSize(.large)
                }
                .padding(24)
                .frame(width: 340)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
                .shadow(radius: 18, y: 8)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
                .onExitCommand { countdown.cancel() }
            }
            .transition(.opacity)
        }
    }
}
