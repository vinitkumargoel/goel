import SwiftUI
import GoelCore

/// Speed & Connections: three switchable profiles as cards, and the selected one's numbers below.
struct SpeedSettingsPane: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        SettingsPane(title: L10n.t("Speed & Connections"),
                     subtitle: L10n.t("Three switchable profiles. The status-bar "
                         + "snail toggles Unlimited vs the active profile."),
                     managedKeys: [.selectedProfileName, .maxDownloadBytesPerSec, .maxUploadBytesPerSec],
                     fillsWidth: true) {
            VStack(alignment: .leading, spacing: Studio.Space.l) {
                HStack(alignment: .top, spacing: Studio.Space.m) {
                    ForEach(vm.settings.profiles) { profile in
                        ProfileCard(profile: profile,
                                    isSelected: profile.name == vm.settings.selectedProfileName) {
                            vm.setProfile(profile.name)
                        }
                        .managed(.selectedProfileName, vm.managedPolicy)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                editingCard
            }
        }
    }

    private var editingCard: some View {
        let active = vm.settings.selectedProfile
        return SettingsCard(title: L10n.t("Editing: %@ profile", active.name), symbol: "slider.horizontal.3") {
            SettingsCardBlock(showsDivider: false, verticalPadding: Studio.Space.m) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Studio.Space.ml, alignment: .top)],
                          alignment: .leading, spacing: Studio.Space.ml) {
                    // Deliberately not `.managed(…)`: a forced ceiling is a clamp, not an assignment.
                    ProfileFieldTile(title: L10n.t("Max download speed"), label: L10n.t("Max download"),
                                     detail: L10n.t("0 = unlimited.")) {
                        SettingsDoubleField(value: megabytesBinding(\.maxDownloadBytesPerSec), unit: L10n.t("MB/s"),
                                            width: nil)
                    }
                    ProfileFieldTile(title: L10n.t("Max upload speed"), label: L10n.t("Max upload"),
                                     detail: L10n.t("Seeding and peer uploads. 0 = unlimited.")) {
                        SettingsDoubleField(value: megabytesBinding(\.maxUploadBytesPerSec), unit: L10n.t("MB/s"),
                                            width: nil)
                    }
                    ProfileFieldTile(title: L10n.t("Max simultaneous downloads"),
                                     label: L10n.t("Simultaneous downloads"),
                                     detail: L10n.t("The rest wait in the queue.")) {
                        SettingsIntField(value: profileBinding(\.maxSimultaneousDownloads), width: nil)
                    }
                    ProfileFieldTile(title: L10n.t("Stop seeding at ratio"), label: L10n.t("Seed ratio"),
                                     detail: L10n.t("Uploaded ÷ downloaded; 0 seeds forever.")) {
                        SettingsDoubleField(value: profileBinding(\.seedRatioLimit), unit: "×", width: nil)
                    }
                    ProfileFieldTile(title: L10n.t("Max connections (global)"), label: L10n.t("Connections, global"),
                                     detail: L10n.t("Open connections across every download.")) {
                        SettingsIntField(value: profileBinding(\.maxConnections), width: nil)
                    }
                    ProfileFieldTile(title: L10n.t("Max connections per server"), label: L10n.t("Per server"),
                                     detail: L10n.t("Some servers block clients that open too many.")) {
                        SettingsIntField(value: profileBinding(\.maxConnectionsPerServer), width: nil)
                    }
                    ProfileFieldTile(title: L10n.t("Max metadata-resolution downloads"),
                                     label: L10n.t("Metadata slots"),
                                     detail: L10n.t("Concurrent “requesting info” magnets.")) {
                        SettingsIntField(value: profileBinding(\.maxMetadataResolutions), width: nil)
                    }
                    ProfileFieldTile(title: L10n.t("Extra connections per download"),
                                     label: L10n.t("Extra connections"),
                                     detail: L10n.t("Split one file across more connections "
                                         + "when the server allows it.")) {
                        HStack {
                            SettingSwitch(isOn: profileBinding(\.enableExtraConnections))
                            Spacer(minLength: 0)
                        }
                        .frame(height: StudioFieldSize.small.height)
                    }
                }
            }
        }
    }

    private func profileBinding<T>(_ keyPath: WritableKeyPath<TrafficProfile, T>) -> Binding<T> {
        Binding(
            get: { vm.settings.selectedProfile[keyPath: keyPath] },
            set: { newValue in
                vm.update { settings in
                    guard let idx = settings.profiles.firstIndex(where: { $0.name == settings.selectedProfileName })
                    else { return }
                    settings.profiles[idx][keyPath: keyPath] = newValue
                }
            }
        )
    }

    /// Clamped to 1 TB/s only because `Int64(Double)` traps on overflow; the real ceiling is
    /// `TrafficProfile.validated()`.
    private func megabytesBinding(_ keyPath: WritableKeyPath<TrafficProfile, Int64>) -> Binding<Double> {
        Binding(
            get: { Double(vm.settings.selectedProfile[keyPath: keyPath]) / 1_048_576 },
            set: { mbPerSec in
                let mb = mbPerSec.isFinite ? min(max(0, mbPerSec), 1_048_576) : 0
                let bytes = Int64(mb * 1_048_576)
                vm.update { settings in
                    guard let idx = settings.profiles.firstIndex(where: { $0.name == settings.selectedProfileName })
                    else { return }
                    settings.profiles[idx][keyPath: keyPath] = bytes
                }
            }
        )
    }
}

/// One profile you can switch to: its glyph and name, its caps in mono, and how many at once.
private struct ProfileCard: View {
    let profile: TrafficProfile
    let isSelected: Bool
    let action: () -> Void

    @State private var hovered = false
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.card, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: Studio.Space.xs) {
                HStack(spacing: Studio.Space.s) {
                    Image(systemName: symbol)
                        .studioFont(.ui, size: 17, weight: 650)
                        .foregroundStyle(tint)
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                    Text(profile.name)
                        .studioFont(.title3)
                        .foregroundStyle(Studio.Palette.ink)
                    Spacer(minLength: Studio.Space.xs)
                    if isSelected {
                        StudioPill(L10n.t("In use"), tone: .accent)
                            .frame(height: 20)
                    }
                }
                .frame(height: 22)
                Text(speedLine)
                    .studioFont(.mono)
                    .foregroundStyle(Studio.Palette.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(L10n.t("%1$@ conns · %2$@ active", String(profile.maxConnections),
                            String(profile.maxSimultaneousDownloads))
                     + " · " + L10n.t("seed to %@×", String(format: "%.1f", profile.seedRatioLimit)))
                    .studioFont(.tiny)
                    .foregroundStyle(Studio.Palette.ink3)
                    .lineLimit(2)
            }
            .padding(Studio.Space.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .studioSurface(.card, radius: Studio.Radius.card, isSelected: isSelected)
            .overlay {
                if hovered && !isSelected {
                    shape.strokeBorder(Studio.Palette.accentLine, lineWidth: 1)
                }
            }
            .studioFocusRing(isFocused, shape: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(profile.name)
        .accessibilityValue(speedLine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var speedLine: String {
        let down = profile.isDownloadUnlimited
            ? L10n.t("Unlimited") : profile.maxDownloadBytesPerSec.byteString + "/s"
        let up = profile.maxUploadBytesPerSec <= 0
            ? L10n.t("Unlimited") : profile.maxUploadBytesPerSec.byteString + "/s"
        return "↓ \(down) · ↑ \(up)"
    }

    private var symbol: String {
        switch profile.name {
        case "Low": return "tortoise"
        case "High": return "bolt"
        default: return "gauge.with.dots.needle.33percent"
        }
    }

    private var tint: Color {
        switch profile.name {
        case "Low": return Studio.Palette.upload
        case "High": return Studio.Palette.ink2
        default: return Studio.Palette.accent
        }
    }
}

/// A labelled field in the profile grid (`.lbl` above `.field.sm.mono`), with its explanation.
private struct ProfileFieldTile<Field: View>: View {
    /// The full setting name: what VoiceOver hears and what the search matches.
    let title: String
    /// The short label shown above the field.
    let label: String
    let detail: String
    @ViewBuilder var field: () -> Field

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .studioFont(.small.weight(650))
                .foregroundStyle(Studio.Palette.ink2)
                .lineLimit(1)
                .help(title)
                .accessibilityHidden(true)
            field()
                .environment(\.settingRowName, title)
            Text(detail)
                .studioFont(.tiny)
                .foregroundStyle(Studio.Palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .settingsHighlightBlock(title)
    }
}
