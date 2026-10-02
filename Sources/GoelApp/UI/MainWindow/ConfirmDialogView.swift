import SwiftUI
import GoelCore

/// The in-window confirmation (`vm.requestConfirm`): a Studio sheet over a scrim. A click on the
/// scrim cancels. Return never confirms a destructive action — a stray keypress would throw away
/// files — so there Cancel holds Return and the destructive button needs a deliberate click.
/// Cancel takes keyboard focus when it opens and VoiceOver reads the title; RootView disables
/// the window behind it.
struct ConfirmDialogView: View {
    let request: AppViewModel.ConfirmRequest
    let dismiss: () -> Void

    @FocusState private var cancelFocused: Bool

    var body: some View {
        ZStack {
            Studio.Palette.scrim
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: Studio.Space.m) {
                    Image(systemName: request.isDestructive ? "trash" : "questionmark")
                        .font(StudioFonts.font(.ui, size: 16, weight: 650))
                        .foregroundStyle(request.isDestructive ? Studio.Palette.bad : Studio.Palette.accent)
                        .frame(width: 36, height: 36)
                        .background(request.isDestructive ? Studio.Palette.badSoft : Studio.Palette.accentSoft,
                                    in: RoundedRectangle(cornerRadius: Studio.Radius.control, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Studio.Space.xs) {
                        Text(request.title)
                            .studioFont(.title3.size(17))
                            .foregroundStyle(Studio.Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(request.message)
                            .studioFont(.body)
                            .foregroundStyle(Studio.Palette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Studio.Space.xl)
                .padding(.top, Studio.Space.xl)
                .padding(.bottom, Studio.Space.l)

                footer
            }
            // Widens with the text size, so large text wraps less instead of running long.
            .modifier(ConfirmDialogWidth())
            .studioSurface(.sheet, radius: Studio.Radius.sheet, elevation: .floating)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityLabel(request.title)
        }
        .defaultFocus($cancelFocused, true)
        .onAppear {
            cancelFocused = true
            A11yAnnouncer.announce(request.title + ". " + request.message)
        }
    }

    private var footer: some View {
        HStack(spacing: Studio.Space.s) {
            Spacer(minLength: 0)
            if request.isDestructive {
                Button(L10n.t("Cancel"), action: dismiss)
                    .buttonStyle(.studio(.secondary))
                    .keyboardShortcut(.defaultAction)
                    .focused($cancelFocused)
                    // Draws the Return-key ring, so the keyboard default is visible.
                    .overlay(RoundedRectangle(cornerRadius: Studio.Radius.control + 2, style: .continuous)
                        .strokeBorder(Studio.Palette.focusRing, lineWidth: 2)
                        .padding(-2)
                        .accessibilityHidden(true))
                Button(request.confirmTitle, role: .destructive, action: confirm)
                    .buttonStyle(.studio(.destructivePrimary))
                    .accessibilityLabel(L10n.t("%@, destructive", request.confirmTitle))
            } else {
                Button(L10n.t("Cancel"), action: dismiss)
                    .buttonStyle(.studio(.ghost))
                    .keyboardShortcut(.cancelAction)
                    .focused($cancelFocused)
                Button(request.confirmTitle, action: confirm)
                    .buttonStyle(.studio(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Studio.Space.xl)
        .padding(.vertical, Studio.Space.ml)
        .background(Studio.Palette.well)
        .overlay(alignment: .top) { StudioDivider() }
        .background {
            // Escape for the destructive layout, where Cancel already holds Return.
            if request.isDestructive {
                Button("", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
    }

    private func confirm() {
        request.onConfirm()
        dismiss()
    }
}

/// 400 pt at the default text size, scaled with the text-size setting.
private struct ConfirmDialogWidth: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 400

    func body(content: Content) -> some View {
        content.frame(width: width)
    }
}

/// While a drag hovers the window: the content dims and a dashed accent target names what it takes.
/// Hit-testing stays off, or this overlay swallows the drag before `.onDrop` sees it.
struct DropTargetOverlay: View {
    var body: some View {
        ZStack {
            Studio.Palette.scrim.ignoresSafeArea()
            VStack(spacing: Studio.Space.sm) {
                Image(systemName: "arrow.down.to.line")
                    .font(StudioFonts.font(.ui, size: 30, weight: 600))
                Text(L10n.t("Drop a URL or .torrent file here"))
                    .studioFont(.title3)
                Text(L10n.t("Links, magnets and .torrent files are added to the queue"))
                    .studioFont(.small)
                    .foregroundStyle(Studio.Palette.ink2)
            }
            .foregroundStyle(Studio.Palette.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Studio.Palette.card, in: RoundedRectangle(cornerRadius: Studio.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Studio.Radius.card, style: .continuous)
                    .strokeBorder(Studio.Palette.accentLine, style: StrokeStyle(lineWidth: 3, dash: [10, 7]))
            )
            .padding(Studio.Space.xl)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityHidden(true)
    }
}
