import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

/// Backup & Updates: keep a copy of the download list, and keep the app current.
struct BackupUpdatesSettingsPane: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        SettingsPane(title: L10n.t("Backup & Updates"),
                     subtitle: L10n.t("Keep a copy of the download list, and keep the app current.")) {
            SettingsCard(title: L10n.t("Backup"), symbol: "externaldrive.badge.timemachine") {
                SettingRow(L10n.t("Periodically back up the download list"),
                           detail: L10n.t("Saves the queue and history, not the downloaded files."),
                           isOn: setting(vm, \.backupEnabled))
                SettingRow(L10n.t("Backup interval"), detail: L10n.t("How often a new backup is written.")) {
                    SettingsSelect(selection: setting(vm, \.backupIntervalHours), options: [
                        SettingsOption(1, L10n.t("Hourly")),
                        SettingsOption(24, L10n.t("Daily")),
                        SettingsOption(168, L10n.t("Weekly")),
                    ], width: 130)
                }
                SettingRow(L10n.t("Keep"), detail: L10n.t("Older backups are pruned automatically.")) {
                    SettingsSelect(selection: setting(vm, \.backupKeepCount), options: [
                        SettingsOption(5, L10n.t("5 backups")),
                        SettingsOption(20, L10n.t("20 backups")),
                        SettingsOption(50, L10n.t("50 backups")),
                    ], width: 130)
                }
            }
            SettingsCard(title: L10n.t("Updates"), symbol: "arrow.down.app") {
                if [.autoCheckUpdates, .updateFeedURL].contains(where: vm.managedPolicy.isLocked) {
                    SettingsCardBlock(showsDivider: false) {
                        SettingsManagedNotice(policy: vm.managedPolicy, keys: [.autoCheckUpdates, .updateFeedURL])
                    }
                }
                SettingRow(L10n.t("Check for updates automatically"), detail: L10n.t("Once at launch.")) {
                    SettingSwitch(isOn: setting(vm, \.autoCheckUpdates))
                        .managed(.autoCheckUpdates, vm.managedPolicy)
                }
                SettingRow(L10n.t("Release feed URL"),
                           detail: L10n.t("A GitHub releases API URL (or compatible JSON feed).")) {
                    SettingsTextField(text: setting(vm, \.updateFeedURL), width: 200,
                                      placeholder: L10n.t("https://api.github.com/…"), isMonospaced: true)
                        .managed(.updateFeedURL, vm.managedPolicy)
                }
                SettingsActionRow {
                    Button(L10n.t("Check Now"), systemImage: "arrow.clockwise") { vm.checkForUpdates() }
                        .buttonStyle(.studio(.secondary, size: .small))
                }
            }
            .settingsColumn(.trailing)
        }
    }
}

/// Audit Log: an append-only, local-only record of downloads added, completed and failed.
struct AuditLogSettingsPane: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        SettingsPane(title: L10n.t("Audit Log"),
                     subtitle: L10n.t("An append-only record of downloads added, completed, and failed — written to "
                                      + "a file on this Mac and nowhere else."),
                     managedKeys: [.auditLogEnabled, .auditLogDirectory, .auditLogRetentionDays,
                                   .auditLogKeepFiles, .auditLogMaxFileMegabytes]) {
            SettingsCard(title: L10n.t("Audit Log"), symbol: "doc.text.magnifyingglass") {
                SettingRow(L10n.t("Keep an audit log"),
                           detail: L10n.t("Off by default. Nothing is recorded, and nothing is ever sent anywhere — "
                                          + "Goel° has no telemetry.")) {
                    SettingSwitch(isOn: setting(vm, \.auditLogEnabled))
                        .managed(.auditLogEnabled, vm.managedPolicy)
                }
                if vm.settings.auditLogEnabled {
                    SettingRow(L10n.t("Folder"),
                               detail: L10n.t("Leave empty for Application Support/GoelDownloader/Audit. File names "
                                              + "and hosts are recorded; URLs are reduced to their host."),
                               isIndented: true) {
                        SettingsTextField(text: setting(vm, \.auditLogDirectory), width: 160,
                                          placeholder: L10n.t("Default folder"), isMonospaced: true,
                                          placeholderIsMonospaced: false)
                            .managed(.auditLogDirectory, vm.managedPolicy)
                    }
                    SettingRow(L10n.t("Reveal in Finder"),
                               detail: L10n.t("Turning the log off never deletes what is already written — that "
                                              + "record is not Goel°’s to discard."),
                               isIndented: true) {
                        Button(L10n.t("Show Audit Folder"), systemImage: "folder") { vm.revealAuditLogFolder() }
                            .buttonStyle(.studio(.secondary, size: .small))
                    }
                }
            }
            if vm.settings.auditLogEnabled {
                SettingsCard(title: L10n.t("Rotation"), symbol: "arrow.triangle.2.circlepath") {
                    SettingRow(L10n.t("Rotate at (MB)"),
                               detail: SettingsRangeText.detail(L10n.t("The live file is rotated once it passes this size."),
                                   SettingsBounds.auditLogMaxFileMegabytes)) {
                        SettingsIntField(value: setting(vm, \.auditLogMaxFileMegabytes), unit: L10n.t("MB"),
                                         range: SettingsBounds.auditLogMaxFileMegabytes)
                            .managed(.auditLogMaxFileMegabytes, vm.managedPolicy)
                    }
                    SettingRow(L10n.t("Rotated files to keep"), detail: SettingsRangeText.detail(L10n.t("Older ones are deleted."),
                        SettingsBounds.auditLogKeepFiles)) {
                        SettingsIntField(value: setting(vm, \.auditLogKeepFiles),
                                         range: SettingsBounds.auditLogKeepFiles)
                            .managed(.auditLogKeepFiles, vm.managedPolicy)
                    }
                    SettingRow(L10n.t("Keep for (days)"),
                               detail: SettingsRangeText.detail(L10n.t("Rotated files older than this are deleted. 0 keeps them forever."),
                                   SettingsBounds.auditLogRetentionDays)) {
                        SettingsIntField(value: setting(vm, \.auditLogRetentionDays),
                                         range: SettingsBounds.auditLogRetentionDays)
                            .managed(.auditLogRetentionDays, vm.managedPolicy)
                    }
                }
                .settingsColumn(.trailing)
            }
        }
    }
}

/// Diagnostics. No telemetry: assembled in memory on demand, handed straight to the user, never
/// sent or stored.
struct DiagnosticsSettingsPane: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        SettingsPane(title: L10n.t("Diagnostics"),
                     subtitle: L10n.t("A support report you can read before you share it.")) {
            SettingsCard(title: L10n.t("Support report"), symbol: "stethoscope") {
                SettingsCardBlock(showsDivider: false) {
                    Text(L10n.t("Versions, engine states, task counts, and a redacted settings dump — "
                         + "no URLs, file names, paths, or credentials. Nothing is ever sent automatically."))
                        .studioFont(.small)
                        .foregroundStyle(Studio.Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .settingsHighlightBlock(L10n.t("Support report"))
                    HStack(spacing: Studio.Space.s) {
                        Button(L10n.t("Copy"), systemImage: "doc.on.doc") { copyDiagnostics() }
                            .buttonStyle(.studio(.primary, size: .small))
                        Button(L10n.t("Export…"), systemImage: "square.and.arrow.up") { exportDiagnostics() }
                            .buttonStyle(.studio(.secondary, size: .small))
                    }
                    .padding(.top, Studio.Space.xxs)
                }
                SettingsCardBlock {
                    SettingsFootnote(text: L10n.t("Withheld from every report: %@.",
                                                  DiagnosticsRedaction.withheldSettingsKeys.sorted()
                                                      .joined(separator: ", ")),
                                     symbol: "eye.slash")
                }
            }
        }
    }

    private func makeDiagnostics() -> DiagnosticsBundle {
        DiagnosticsBundle.make(settings: vm.settings, tasks: vm.tasks, runningEngineKinds: vm.runningEngineKinds)
    }

    private func copyDiagnostics() {
        vm.copyToPasteboard(makeDiagnostics().plainText)
        vm.toastSuccess(L10n.t("Diagnostics copied — paste it into your bug report"))
    }

    private func exportDiagnostics() {
        guard let url = FilePicker.save(name: "Goel-diagnostics.json", type: .json) else { return }
        do {
            try makeDiagnostics().jsonData().write(to: url, options: .atomic)
            vm.toastSuccess(L10n.t("Diagnostics saved"))
        } catch {
            vm.settingsMessage(L10n.t("Export Failed"),
                               L10n.t("Couldn’t write the diagnostics report to that location."))
        }
    }
}
