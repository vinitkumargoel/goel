import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

/// The panes split out of the old catch-all "Advanced": each answers one question
/// ("will I hear about it?", "what runs after a download?", "is my list backed up?").

struct NotificationsPane: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var permission: NotificationService.Permission?

    var body: some View {
        PaneScaffold(title: L10n.t("Notifications"),
                     subtitle: L10n.t("Which events show a banner, and whether macOS lets them through.")) {
            permissionRow
            SectionHeader(L10n.t("Notify me"))
            SetRow(name: L10n.t("On download added"),
                   desc: L10n.t("A banner each time something joins the queue.")) {
                SettingSwitch(isOn: setting(vm, \.notifyOnAdded))
            }
            SetRow(name: L10n.t("On download completed"),
                   desc: L10n.t("A banner the moment a file is ready.")) {
                SettingSwitch(isOn: setting(vm, \.notifyOnCompleted))
            }
            SetRow(name: L10n.t("On download failed"),
                   desc: L10n.t("Says why, so you can retry without opening the app.")) {
                SettingSwitch(isOn: setting(vm, \.notifyOnFailed))
            }
            SetRow(name: L10n.t("Only when app is inactive"),
                   desc: L10n.t("Stay quiet while Goel° is the frontmost app.")) {
                SettingSwitch(isOn: setting(vm, \.notifyOnlyWhenInactive))
            }
            SetRow(name: L10n.t("Play sound"), desc: L10n.t("The system alert sound with each banner.")) {
                SettingSwitch(isOn: setting(vm, \.notificationSound))
            }
        }
        .task { permission = await NotificationService.permission() }
    }

    private var permissionRow: some View {
        SetRow(name: L10n.t("Permission"), desc: permissionText) {
            HStack(spacing: Theme.Space.s) {
                if permission == .denied {
                    Button(L10n.t("Open System Settings…")) { NotificationService.openSystemSettings() }
                } else if permission == .notAsked {
                    Button(L10n.t("Allow…")) {
                        NotificationService.requestAuthorization()
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            permission = await NotificationService.permission()
                        }
                    }
                }
                Button(L10n.t("Send Test")) {
                    NotificationService.sendTest(sound: vm.settings.notificationSound)
                }
                .disabled(permission == .denied)
            }
        }
    }

    private var permissionText: String {
        switch permission {
        case .allowed: return L10n.t("Allowed — banners appear.")
        case .denied: return L10n.t("Turned off in System Settings — no banners will appear.")
        case .notAsked: return L10n.t("Not asked yet — macOS asks the first time a banner is due.")
        case nil: return L10n.t("Checking…")
        }
    }
}

/// Lives on the General pane: whether the Mac may sleep mid-download.
struct PowerSection: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        SectionHeader(L10n.t("Power management"))
        SetRow(name: L10n.t("Prevent sleep during active downloads"),
               desc: L10n.t("Keep the Mac awake while anything is downloading.")) {
            SettingSwitch(isOn: setting(vm, \.preventSleepWhileDownloading))
        }
        SetRow(name: L10n.t("Allow sleep if downloads can resume later"),
               desc: L10n.t("Sleep anyway when every running download can pick up where it stopped.")) {
            SettingSwitch(isOn: setting(vm, \.allowSleepIfResumable))
        }
        SetRow(name: L10n.t("Allow sleep while seeding"),
               desc: L10n.t("Seeding alone doesn’t keep the Mac awake.")) {
            SettingSwitch(isOn: setting(vm, \.allowSleepWhileSeeding))
        }
        SetRow(name: L10n.t("Pause downloads below battery threshold"),
               desc: L10n.t("On battery, pause below this charge. 0 turns it off.")) {
            HStack(spacing: Theme.Space.xs) {
                SettingInt(value: batteryBinding, width: 48)
                Text(L10n.t("%")).scaledFont(size: Theme.TextSize.body)
            }
        }
        SetRow(name: L10n.t("Don’t seed on battery"),
               desc: L10n.t("Stop uploading when the charger is unplugged.")) {
            SettingSwitch(isOn: setting(vm, \.dontSeedOnBattery))
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

struct AfterDownloadPane: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        PaneScaffold(title: L10n.t("Extract & Scripts"),
                     subtitle: L10n.t("What happens to a file once it finishes.")) {
            SectionHeader(L10n.t("Extract"))
            SetRow(name: L10n.t("Auto-extract archives"), desc: L10n.t("Unpack finished .zip downloads next to the file.")) {
                SettingSwitch(isOn: setting(vm, \.postDownloadExtractArchives))
            }
            SectionHeader(L10n.t("Script"))
            SetRow(name: L10n.t("Run a script on completion"),
                   desc: L10n.t("An executable script; %path% in the arguments becomes the finished file.")) {
                SettingSwitch(isOn: setting(vm, \.postDownloadScriptEnabled))
            }
            if vm.settings.postDownloadScriptEnabled {
                SetRow(name: L10n.t("Script path"), desc: L10n.t("Must be executable (not “bash script.sh”).")) {
                    SettingText(text: setting(vm, \.postDownloadScriptPath), width: 200)
                }
                SetRow(name: L10n.t("Arguments"), desc: L10n.t("Passed to the script; %path% becomes the finished file.")) {
                    SettingText(text: setting(vm, \.postDownloadScriptArgs), width: 140)
                }
            }
        }
    }
}

struct MediaToolsPane: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        PaneScaffold(title: L10n.t("Media Tools"),
                     subtitle: L10n.t("Stream quality, subtitles, and ffmpeg conversions.")) {
            SetRow(name: L10n.t("Max video quality"),
                   desc: L10n.t("Preferred rendition when grabbing an HLS (.m3u8) stream.")) {
                Dropdown(selection: setting(vm, \.hlsMaxHeight), items: [
                    .option(0, L10n.t("Best available")),
                    .option(1080, "1080p"),
                    .option(720, "720p"),
                    .option(480, "480p"),
                    .option(360, "360p"),
                ], width: 150)
            }
            SectionHeader(L10n.t("Subtitles"))
            SetRow(name: L10n.t("Download subtitles"),
                   desc: L10n.t("Fetch subtitles alongside yt-dlp video downloads (requires yt-dlp).")) {
                SettingSwitch(isOn: setting(vm, \.subtitleDownloadEnabled))
            }
            if vm.settings.subtitleDownloadEnabled {
                SetRow(name: L10n.t("Subtitle languages"),
                       desc: L10n.t("Comma-separated codes, e.g. “en, es”.")) {
                    SettingText(text: setting(vm, \.subtitleLanguages), width: 140)
                }
                SetRow(name: L10n.t("Include auto-captions"),
                       desc: L10n.t("Fall back to machine-generated captions when no human subtitles exist.")) {
                    SettingSwitch(isOn: setting(vm, \.subtitleIncludeAutoGenerated))
                }
            }
            SectionHeader(L10n.t("Conversions"))
            SetRow(name: L10n.t("ffmpeg path"),
                   desc: L10n.t("Optional. Leave empty to use the copy included with Goel°. Enables Convert / Extract-audio on finished media.")) {
                SettingText(text: setting(vm, \.ffmpegPath), width: 200)
            }
            Text(vm.ffmpegResolutionSummary)
                .scaledFont(size: Theme.TextSize.micro)
                .foregroundStyle(vm.ffmpegUnavailableReason == nil ? Color.secondary : Theme.orange)
                .fixedSize(horizontal: false, vertical: true)
            SetRow(name: L10n.t("Conversions at once"),
                   desc: L10n.t("ffmpeg already uses every core for one job, so running more at "
                       + "the same time makes each one slower without finishing the batch sooner.")) {
                Dropdown(selection: setting(vm, \.mediaConcurrency), items: [
                    .option(1, "1"), .option(2, "2"), .option(3, "3"), .option(4, "4"),
                ], width: 90)
            }
        }
    }
}

struct BackupUpdatesPane: View {
    @EnvironmentObject private var vm: AppViewModel

    private static let updatesManagedKeys: [ManagedPolicy.Key] = [.autoCheckUpdates, .updateFeedURL]

    var body: some View {
        PaneScaffold(title: L10n.t("Backup & Updates"),
                     subtitle: L10n.t("Keep a copy of the download list, and keep the app current.")) {
            SectionHeader(L10n.t("Backup"))
            SetRow(name: L10n.t("Periodically back up the download list"),
                   desc: L10n.t("Saves the queue and history, not the downloaded files.")) {
                SettingSwitch(isOn: setting(vm, \.backupEnabled))
            }
            SetRow(name: L10n.t("Backup interval"), desc: L10n.t("How often a new backup is written.")) {
                Dropdown(selection: setting(vm, \.backupIntervalHours), items: [
                    .option(1, L10n.t("Hourly")),
                    .option(24, L10n.t("Daily")),
                    .option(168, L10n.t("Weekly")),
                ], width: 140)
            }
            SetRow(name: L10n.t("Keep"), desc: L10n.t("Older backups are pruned automatically.")) {
                Dropdown(selection: setting(vm, \.backupKeepCount), items: [
                    .option(5, L10n.t("5 backups")),
                    .option(20, L10n.t("20 backups")),
                    .option(50, L10n.t("50 backups")),
                ], width: 140)
            }
            SectionHeader(L10n.t("Updates"))
            ManagedPolicyNotice(policy: vm.managedPolicy, keys: Self.updatesManagedKeys)
            SetRow(name: L10n.t("Check for updates automatically"), desc: L10n.t("Once at launch.")) {
                SettingSwitch(isOn: setting(vm, \.autoCheckUpdates))
                    .managed(.autoCheckUpdates, vm.managedPolicy)
            }
            SetRow(name: L10n.t("Release feed URL"),
                   desc: L10n.t("A GitHub releases API URL (or compatible JSON feed).")) {
                SettingText(text: setting(vm, \.updateFeedURL), width: 220)
                    .managed(.updateFeedURL, vm.managedPolicy)
            }
            SetRow(name: "", desc: "") {
                Button(L10n.t("Check Now")) { vm.checkForUpdates() }
            }
        }
    }
}

/// No telemetry: assembled in memory on demand, handed straight to the user, never sent or stored.
struct DiagnosticsPane: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        PaneScaffold(title: L10n.t("Diagnostics"),
                     subtitle: L10n.t("A support report you can read before you share it.")) {
            SetRow(name: L10n.t("Support report"),
                   desc: L10n.t("Versions, engine states, task counts, and a redacted settings dump — "
                       + "no URLs, file names, paths, or credentials. Nothing is ever sent automatically.")) {
                HStack(spacing: Theme.Space.s) {
                    Button(L10n.t("Copy")) { copyDiagnostics() }
                    Button(L10n.t("Export…")) { exportDiagnostics() }
                }
            }
            Text(L10n.t("Withheld from every report: %@.",
                        DiagnosticsRedaction.withheldSettingsKeys.sorted().joined(separator: ", ")))
                .scaledFont(size: Theme.TextSize.micro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
