import SwiftUI
import AppKit
import GoelCore

/// First-run setup: a short deck of five cards (welcome, folder, browser, clipboard, ready check)
/// with step dots, Back / Continue, and Skip setup always one click (or Esc) away.
struct OnboardingView: View {

    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable {
        case welcome, saveFolder, browser, clipboard, ready

        var title: String {
            switch self {
            case .welcome:    return L10n.t("Welcome to Goel°")
            case .saveFolder: return L10n.t("Where should downloads land?")
            case .browser:    return L10n.t("Which browser do you use?")
            case .clipboard:  return L10n.t("Copy a link, download it")
            case .ready:      return L10n.t("Ready check")
            }
        }
    }

    @State private var step: Step
    @State private var licenceNoticeVisible = !OnboardingState.licenceNoticeDismissed
    /// For previews and snapshots: a known notification permission instead of asking the system.
    private let notificationPermission: NotificationService.Permission?
    private let browserChoice: OnboardingBrowserChoice?

    init(step: Step = .welcome, notificationPermission: NotificationService.Permission? = nil,
         browserChoice: OnboardingBrowserChoice? = nil) {
        _step = State(initialValue: step)
        self.notificationPermission = notificationPermission
        self.browserChoice = browserChoice
    }

    static let size = CGSize(width: 480, height: 600)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Studio.Space.l) {
                    heading
                    pane
                }
                .padding(Studio.Space.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            if showsLicence {
                OnboardingLicenceStrip {
                    licenceNoticeVisible = false
                    OnboardingState.licenceNoticeDismissed = true
                }
                .padding(.horizontal, Studio.Space.xxl)
                .padding(.bottom, Studio.Space.l)
            }
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Studio.Palette.sheet)
        // The catch-all exit path: the window close button does not call finish().
        .onDisappear { OnboardingState.markCompleted() }
    }

    private var showsLicence: Bool {
        licenceNoticeVisible && (step == .welcome || step == .ready)
    }

    @ViewBuilder
    private var heading: some View {
        if step == .welcome {
            OnboardingLogo()
        } else {
            WindowsEyebrow(L10n.t("Step %1$@ of %2$@", String(step.rawValue + 1), String(Step.allCases.count)))
        }
        Text(step.title)
            .studioFont(.title1)
            .foregroundStyle(Studio.Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var pane: some View {
        switch step {
        case .welcome:    OnboardingWelcomePane()
        case .saveFolder: OnboardingFolderPane()
        case .browser:    OnboardingBrowserPane(previewChoice: browserChoice)
        case .clipboard:  OnboardingClipboardPane()
        case .ready:      OnboardingReadyPane(knownPermission: notificationPermission)
        }
    }

    private var footer: some View {
        HStack(spacing: Studio.Space.s) {
            if step != .welcome {
                Button(L10n.t("Back")) { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                    .buttonStyle(.studio(.ghost, size: .small))
                    .accessibilityLabel(L10n.t("Back to the previous step"))
            }
            // Esc always means "leave setup", on every step; Back is a plain button.
            Button(L10n.t("Skip setup"), action: finish)
                .buttonStyle(.studio(.ghost, size: .small))
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: Studio.Space.s)
            WindowsStepDots(count: Step.allCases.count, current: step.rawValue)
            Spacer(minLength: Studio.Space.s)
            Button(step == .ready ? L10n.t("Start using Goel°") : L10n.t("Continue"), action: advance)
                .buttonStyle(.studio(.primary))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Studio.Space.xl)
        .padding(.vertical, Studio.Space.ml)
        .background(Studio.Palette.well)
        .overlay(alignment: .top) { StudioDivider() }
    }

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
        } else {
            finish()
        }
    }

    private func finish() {
        OnboardingState.markCompleted()
        dismiss()
    }
}

/// The app mark (`.logo.l`): an accent tile with the "g" and its degree ring.
private struct OnboardingLogo: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(LinearGradient(colors: [Studio.Palette.accent, Studio.Palette.accentStrong],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .studioElevation(.raised)
            Text(verbatim: "g")
                .font(StudioFonts.font(.display, size: 38, weight: 800))
                .foregroundStyle(Studio.Palette.onAccent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: -3)
            Circle()
                .strokeBorder(Studio.Palette.onAccent, lineWidth: 3)
                .frame(width: 12, height: 12)
                .padding(Studio.Space.sm)
        }
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
    }
}

/// "Free for personal use…": opens the commercial page; the ✕ hides it for good.
private struct OnboardingLicenceStrip: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Studio.Space.sm) {
            Image(systemName: "key")
                .font(StudioFonts.font(.ui, size: 13, weight: 650))
                .foregroundStyle(Studio.Palette.ink3)
                .accessibilityHidden(true)
            Button {
                NSWorkspace.shared.open(OnboardingState.commercialURL)
            } label: {
                (Text(L10n.t("Free for personal use. Commercial use requires a licence — "))
                    .foregroundStyle(Studio.Palette.ink2)
                 + Text(L10n.t("Learn more"))
                    .foregroundStyle(Studio.Palette.accent))
                    .studioFont(.caption)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("Free for personal use. Commercial use requires a licence. Learn more."))
            .accessibilityAddTraits(.isLink)
            StudioIconButton("xmark", label: L10n.t("Hide licence notice"), size: .small, action: onDismiss)
                .help(L10n.t("Hide this notice"))
        }
        .padding(.leading, Studio.Space.m)
        .padding(.trailing, Studio.Space.xxs)
        .padding(.vertical, Studio.Space.xxs)
        .background(Studio.Palette.segment, in: RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous))
    }
}
