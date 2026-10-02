import SwiftUI
import GoelCore

/// General: appearance and language, startup, where files land, and power.
struct GeneralSettingsPane: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        SettingsPane(title: L10n.t("General"),
                     subtitle: L10n.t("Appearance, startup, where files land, and sleep."),
                     managedKeys: [.defaultFolderRule, .defaultSaveDirectory]) {
            Text(L10n.t("Changes save as you make them"))
                .studioFont(.small)
                .foregroundStyle(Studio.Palette.ink3)
        } content: {
            appearanceCard
            startupCard
            downloadsCard
                .settingsColumn(.trailing)
            PowerSettingsCard()
                .settingsColumn(.trailing)
        }
    }

    private var appearanceCard: some View {
        SettingsCard(title: L10n.t("Appearance"), symbol: "circle.lefthalf.filled") {
            SettingsCardBlock(showsDivider: false, verticalPadding: Studio.Space.sm) {
                SettingsAppearancePicker(selection: $vm.appearanceMode)
                    .settingsHighlightBlock(L10n.t("Theme"))
            }
            // Only languages that ship a strings table: anything else silently resolves to English.
            SettingRow(L10n.t("Language"),
                       detail: L10n.t("%@ ship translations today.",
                                      L10n.supportedLanguages.map(\.name).joined(separator: ", "))) {
                SettingsSelect(selection: setting(vm, \.language),
                               options: L10n.supportedLanguages.map { SettingsOption($0.name, $0.name) },
                               width: 150)
            }
        }
    }

    private var startupCard: some View {
        SettingsCard(title: L10n.t("Startup"), symbol: "power") {
            SettingRow(L10n.t("Launch at login"), detail: L10n.t("Start Goel° when you log in."),
                       isOn: setting(vm, \.launchAtLogin))
            SettingRow(L10n.t("Launch minimized"), detail: L10n.t("Open to the menu bar instead of a window."),
                       isOn: setting(vm, \.launchMinimized))
            SettingRow(L10n.t("Show in menu bar"),
                       detail: L10n.t("Add a menu-bar item with live ↓/↑ speed and quick controls."),
                       isOn: setting(vm, \.menuBarExtraEnabled))
        }
    }

    private var downloadsCard: some View {
        SettingsCard(title: L10n.t("Downloads"), symbol: "arrow.down.circle") {
            SettingRow(L10n.t("Default download folder"),
                       detail: L10n.t("Choose automatically, by type, by source URL, or fixed."),
                       alignment: .top) {
                SettingsRadioGroup(selection: setting(vm, \.defaultFolderRule), options: [
                    SettingsOption("automatic", L10n.t("Automatic")),
                    SettingsOption("byType", L10n.t("By file type")),
                    SettingsOption("bySource", L10n.t("By source URL")),
                    SettingsOption("fixed", L10n.t("Fixed folder…")),
                ])
                .frame(width: 150, alignment: .leading)
                .managed(.defaultFolderRule, vm.managedPolicy)
            }
            if vm.settings.defaultFolderRule == "fixed" {
                SettingRow(L10n.t("Fixed folder"),
                           detail: (vm.settings.defaultSaveDirectory as NSString).abbreviatingWithTildeInPath,
                           isIndented: true) {
                    Button(L10n.t("Choose…"), systemImage: "folder") { chooseDefaultFolder() }
                        .buttonStyle(.studio(.secondary, size: .small))
                        .accessibilityLabel(L10n.t("Choose fixed download folder"))
                        .managed(.defaultSaveDirectory, vm.managedPolicy)
                }
            }
            SettingRow(L10n.t("When a file exists"),
                       detail: L10n.t("Replace it, or keep both by appending “(1)”.")) {
                StudioSegmentedControl(selection: setting(vm, \.existingFileReaction), segments: [
                    StudioSegment("rename", title: L10n.t("Rename")),
                    StudioSegment("overwrite", title: L10n.t("Overwrite")),
                ], size: .small)
                .accessibilityLabel(L10n.t("When a file exists"))
            }
            SettingRow(L10n.t("Clipboard capture"),
                       detail: L10n.t("Offer to download http(s)/magnet links you copy."),
                       isOn: setting(vm, \.clipboardMonitorEnabled))
        }
    }

    private func chooseDefaultFolder() {
        if let url = FilePicker.chooseDirectory() {
            vm.setDefaultSaveDirectory(url.path)
        }
    }
}

/// Whether the Mac may sleep mid-download.
private struct PowerSettingsCard: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        SettingsCard(title: L10n.t("Power management"), symbol: "battery.75percent") {
            SettingRow(L10n.t("Prevent sleep during active downloads"),
                       detail: L10n.t("Keep the Mac awake while anything is downloading."),
                       isOn: setting(vm, \.preventSleepWhileDownloading))
            SettingRow(L10n.t("Allow sleep if downloads can resume later"),
                       detail: L10n.t("Sleep anyway when every running download can pick up where it stopped."),
                       isOn: setting(vm, \.allowSleepIfResumable))
            SettingRow(L10n.t("Allow sleep while seeding"),
                       detail: L10n.t("Seeding alone doesn’t keep the Mac awake."),
                       isOn: setting(vm, \.allowSleepWhileSeeding))
            SettingRow(L10n.t("Pause downloads below battery threshold"),
                       detail: L10n.t("On battery, pause below this charge. 0 turns it off.")) {
                SettingsIntField(value: batteryBinding, unit: L10n.t("%"), width: 80)
            }
            SettingRow(L10n.t("Don’t seed on battery"),
                       detail: L10n.t("Stop uploading when the charger is unplugged."),
                       isOn: setting(vm, \.dontSeedOnBattery))
        }
    }

    /// The getter must report 0 while off: showing the stored value made re-typing it a dropped no-op.
    private var batteryBinding: Binding<Int> {
        Binding(
            get: { vm.settings.pauseBelowBatteryThreshold ? vm.settings.batteryThresholdPercent : 0 },
            set: { newValue in
                vm.update {
                    $0.batteryThresholdPercent = newValue
                    $0.pauseBelowBatteryThreshold = newValue > 0
                }
            }
        )
    }
}

/// System / Light / Dark as three miniature windows (the mockup's Appearance tiles).
struct SettingsAppearancePicker: View {
    @Binding var selection: StudioAppearanceMode

    var body: some View {
        HStack(spacing: Studio.Space.sm) {
            ForEach([StudioAppearanceMode.light, .dark, .system]) { mode in
                SettingsAppearanceTile(mode: mode, isSelected: selection == mode) { selection = mode }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Theme"))
    }
}

private struct SettingsAppearanceTile: View {
    let mode: StudioAppearanceMode
    let isSelected: Bool
    let action: () -> Void

    @State private var hovered = false
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous)
        Button(action: action) {
            VStack(spacing: Studio.Space.xs) {
                preview
                    .frame(height: 62)
                    .clipShape(shape)
                    .overlay {
                        shape.strokeBorder(isSelected ? Studio.Palette.accent
                                           : hovered ? Studio.Palette.accentLine : Studio.Palette.hairline,
                                           lineWidth: isSelected ? 2 : 1)
                    }
                    .studioFocusRing(isFocused, shape: shape)
                HStack(spacing: Studio.Space.xxs) {
                    Image(systemName: mode.symbol)
                        .studioFont(.ui, size: 11, weight: 650)
                        .accessibilityHidden(true)
                    Text(mode.title)
                        .studioFont(.small.weight(isSelected ? 650 : 500))
                }
                .foregroundStyle(isSelected ? Studio.Palette.ink : Studio.Palette.ink2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// A tiny window in that appearance's own colours, whatever the current one is.
    @ViewBuilder private var preview: some View {
        switch mode {
        case .light: MiniWindow(isDark: false)
        case .dark: MiniWindow(isDark: true)
        case .system:
            ZStack {
                MiniWindow(isDark: false)
                MiniWindow(isDark: true)
                    .mask(DiagonalHalf())
            }
        }
    }

    private struct MiniWindow: View {
        let isDark: Bool

        private func tone(_ token: StudioColorToken) -> Color {
            Color(nsColor: (isDark ? token.dark : token.light).nsColor)
        }

        var body: some View {
            let canvas = tone(Studio.Tones.canvas)
            let card = tone(Studio.Tones.card)
            let accent = tone(Studio.Tones.accent)
            let rail = tone(Studio.Tones.rail)
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(rail).frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 22, height: 4)
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(card)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(canvas)
        }
    }

    private struct DiagonalHalf: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}

extension View {
    /// Lights a non-row block (the appearance tiles, a field tile) for the search, like a row.
    func settingsHighlightBlock(_ title: String) -> some View {
        modifier(SettingsBlockHighlight(title: title))
    }
}

private struct SettingsBlockHighlight: ViewModifier {
    let title: String
    @Environment(\.settingsSearchQuery) private var query

    func body(content: Content) -> some View {
        content
            .padding(Studio.Space.xs)
            .background {
                if SettingsSearch.highlights(title, query: query) {
                    RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous)
                        .fill(Studio.Palette.accentSoft)
                        .accessibilityHidden(true)
                }
            }
            .padding(-Studio.Space.xs)
    }
}
