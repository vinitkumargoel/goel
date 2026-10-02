import SwiftUI
import AppKit
import GoelCore

/// A Binding onto one setting, written through `update` like every other settings change.
@MainActor
func onboardingSetting<T>(_ vm: AppViewModel, _ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
    Binding(get: { vm.settings[keyPath: keyPath] },
            set: { newValue in vm.update { $0[keyPath: keyPath] = newValue } })
}

/// Secondary copy under a pane title.
struct OnboardingBlurb: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .studioFont(.body.size(14))
            .lineSpacing(3)
            .foregroundStyle(Studio.Palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One onboarding item as a compact card: a leading tile, title and detail, and a control.
struct OnboardingItem<Leading: View, Control: View>: View {
    let title: String
    let detail: String
    var detailTone: StudioTone = .neutral
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var control: () -> Control

    var body: some View {
        WindowsCompactCard {
            leading()
            VStack(alignment: .leading, spacing: Studio.Space.hair) {
                Text(title)
                    .studioFont(.bodyStrong)
                    .foregroundStyle(Studio.Palette.ink)
                Text(detail)
                    .studioFont(.caption)
                    .foregroundStyle(detailTone == .neutral ? Studio.Palette.ink3 : detailTone.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(detail)
            control()
        }
    }
}

extension OnboardingItem where Leading == WindowsGlyphTile {
    init(symbol: String, tone: StudioTone = .accent, title: String, detail: String, detailTone: StudioTone = .neutral,
         @ViewBuilder control: @escaping () -> Control) {
        self.init(title: title, detail: detail, detailTone: detailTone,
                  leading: { WindowsGlyphTile(symbol: symbol, tone: tone) }, control: control)
    }
}

// MARK: - Welcome

struct OnboardingWelcomePane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.l) {
            OnboardingBlurb(L10n.t("One queue for links, torrents, streams and your own servers. A minute of setup and "
                                   + "it will catch downloads from your browser and clipboard by itself."))
            VStack(alignment: .leading, spacing: Studio.Space.s) {
                feature(.disc, L10n.t("HTTP, FTP and SFTP, split across several connections"))
                feature(.magnet, L10n.t("BitTorrent and magnet links"))
                feature(.video, L10n.t("Video pages and HLS streams"))
                feature(.folder, L10n.t("Your own servers, browsed like a folder"))
            }
        }
    }

    private func feature(_ kind: StudioArtKind, _ text: String) -> some View {
        HStack(spacing: Studio.Space.sm) {
            StudioFileArtwork(kind: kind, size: .xs)
            Text(text).studioFont(.small).foregroundStyle(Studio.Palette.ink)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Save folder

struct OnboardingFolderPane: View {
    @EnvironmentObject private var vm: AppViewModel

    private var byType: Binding<Bool> {
        Binding(get: { vm.settings.defaultFolderRule == "byType" },
                set: { on in vm.update { $0.defaultFolderRule = on ? "byType" : "fixed" } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.ml) {
            OnboardingBlurb(L10n.t("Everything you queue lands in one place unless you say otherwise. "
                + "You can still pick a different folder for any individual download."))
            folderCard
            HStack(spacing: Studio.Space.m) {
                VStack(alignment: .leading, spacing: Studio.Space.hair) {
                    Text(L10n.t("Or let Goel° sort them")).studioFont(.bodyStrong).foregroundStyle(Studio.Palette.ink)
                    Text(L10n.t("Video, archives, disc images and documents each get their own subfolder."))
                        .studioFont(.caption)
                        .foregroundStyle(Studio.Palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle(isOn: byType) { EmptyView() }
                    .toggleStyle(.studioSwitch)
                    .accessibilityLabel(L10n.t("Sort downloads by file type"))
                    .accessibilityValue(byType.wrappedValue ? L10n.t("Sorting by file type, already chosen") : "")
            }
            typeGrid
                .opacity(byType.wrappedValue ? 1 : 0.45)
                .animation(Studio.Motion.quick, value: byType.wrappedValue)
        }
    }

    private var folderCard: some View {
        StudioCard(padding: Studio.Space.ml) {
            HStack(spacing: Studio.Space.m) {
                StudioFileArtwork(kind: .folder, size: .m)
                VStack(alignment: .leading, spacing: Studio.Space.hair) {
                    Text(currentFolderLabel)
                        .studioFont(.bodyStrong)
                        .foregroundStyle(Studio.Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(folderDetail)
                        .studioFont(.monoSmall)
                        .foregroundStyle(Studio.Palette.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Button(L10n.t("Choose…"), action: chooseFolder)
                    .buttonStyle(.studio(.secondary, size: .small))
                    .accessibilityLabel(L10n.t("Choose download folder"))
            }
        }
    }

    /// The six type folders, shown as tiles: what "Sort by type" will make.
    private var typeGrid: some View {
        let kinds: [(StudioArtKind, String)] = [
            (.video, FileType.video.accessibilityName), (.audio, FileType.audio.accessibilityName),
            (.disc, FileType.iso.accessibilityName), (.archive, FileType.archive.accessibilityName),
            (.app, FileType.app.accessibilityName), (.doc, FileType.doc.accessibilityName),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Studio.Space.s), count: 3),
                         spacing: Studio.Space.sm) {
            ForEach(kinds, id: \.0) { kind, name in
                VStack(spacing: Studio.Space.xxs) {
                    StudioFileArtwork(kind: kind, size: .m)
                    Text(name).studioFont(.tiny).foregroundStyle(Studio.Palette.ink2).lineLimit(1)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var currentFolderLabel: String {
        switch vm.settings.defaultFolderRule {
        case "byType":   return L10n.t("Automatic — by file type")
        case "bySource": return L10n.t("Automatic — by source site")
        default:
            return (vm.settings.defaultSaveDirectory as NSString).lastPathComponent
        }
    }

    /// "~/Downloads · 312 GB free", and how the rule files things.
    private var folderDetail: String {
        let path = (vm.settings.defaultSaveDirectory as NSString).abbreviatingWithTildeInPath
        let rule = vm.settings.defaultFolderRule == "fixed"
            ? L10n.t("Every download goes here.")
            : L10n.t("Sorted automatically by file type.")
        guard let free = DiskSpaceCheck.availableCapacity(forFolder: vm.settings.defaultSaveDirectory) else {
            return "\(path) · \(rule)"
        }
        return L10n.t("%1$@ · %2$@ free", path, free.byteString)
    }

    private func chooseFolder() {
        guard let url = FilePicker.chooseDirectory(
            prompt: L10n.t("Use Folder"),
            message: L10n.t("Choose where Goel° saves finished downloads.")) else { return }
        vm.setDefaultSaveDirectory(url.path)
        vm.update { $0.defaultFolderRule = "fixed" }
    }
}

// MARK: - Clipboard

struct OnboardingClipboardPane: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.ml) {
            OnboardingBlurb(L10n.t("Goel° can watch for http(s) and magnet links you copy and offer them in a "
                + "banner. It only ever offers — nothing downloads without you clicking Add."))
            OnboardingItem(symbol: "doc.on.clipboard", title: L10n.t("Watch the clipboard"),
                           detail: L10n.t("Links you copy appear as a one-click banner at the top of the window.")) {
                Toggle(isOn: onboardingSetting(vm, \.clipboardMonitorEnabled)) { EmptyView() }
                    .toggleStyle(.studioSwitch)
                    .accessibilityLabel(L10n.t("Watch the clipboard"))
            }
            WindowsEyebrow(L10n.t("A few other ways in"))
                .padding(.top, Studio.Space.xxs)
            OnboardingItem(symbol: "basket", tone: .neutral, title: L10n.t("Drop Basket"),
                           detail: L10n.t("A small always-on-top target — drag links onto it from anywhere.")) {
                StudioKeyCaps("⇧⌘B")
                Button(L10n.t("Show")) { DropBasketController.shared.toggle() }
                    .buttonStyle(.studio(.secondary, size: .small))
                    .accessibilityLabel(L10n.t("Show drop basket"))
            }
            OnboardingItem(symbol: "link.badge.plus", tone: .neutral, title: L10n.t("Link Grabber"),
                           detail: L10n.t("Give it a page URL and it lists every file linked from it to pick from.")) {
                StudioKeyCaps("⇧⌘L")
            }
            OnboardingItem(symbol: "command", tone: .neutral, title: L10n.t("Command Palette"),
                           detail: L10n.t("Every action and settings pane in one search field.")) {
                StudioKeyCaps("⌘K")
            }
        }
    }
}
