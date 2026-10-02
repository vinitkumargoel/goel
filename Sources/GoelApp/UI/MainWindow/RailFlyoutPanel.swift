import SwiftUI
import GoelCore

/// The collapsed rail's flyout: a floating card beside the rail with one long list (filters,
/// tags or servers). A click outside, Esc, or picking a row closes it.
struct RailFlyoutPanel: View {
    @EnvironmentObject private var vm: AppViewModel
    let kind: RailFlyout
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Studio.Space.s) {
                Text(kind.title)
                    .studioFont(.title3)
                    .foregroundStyle(Studio.Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Studio.Space.s)
                if kind == .servers {
                    StudioIconButton("plus", label: L10n.t("Add SFTP server"), size: .small) {
                        close()
                        vm.presentNewServer()
                    }
                }
                StudioIconButton("xmark", label: L10n.t("Close"), size: .small, action: close)
            }
            .padding(.leading, Studio.Space.l)
            .padding(.trailing, Studio.Space.sm)
            .padding(.top, Studio.Space.m)
            .padding(.bottom, Studio.Space.xs)

            ViewThatFits(in: .vertical) {
                list
                ScrollView { list }.scrollIndicators(.automatic)
            }
        }
        .frame(width: 264)
        .studioSurface(.raised, radius: Studio.Radius.card, elevation: .floating)
        .background {
            // Esc closes the flyout.
            Button(L10n.t("Close"), action: close)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.title)
    }

    @ViewBuilder
    private var list: some View {
        VStack(alignment: .leading, spacing: Studio.Space.hair) {
            switch kind {
            case .filters:
                RailFilterSections(onPick: close)
            case .tags:
                RailTagSection(showsHeader: false, onPick: close)
            case .servers:
                RailServerSection(showsHeader: false, onPick: close)
            }
        }
        .padding(.horizontal, Studio.Space.s)
        .padding(.bottom, Studio.Space.sm)
    }
}
