import SwiftUI
import GoelCore

/// Extract & Scripts: what happens to a file once it finishes.
struct ExtractScriptsSettingsPane: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        SettingsPane(title: L10n.t("Extract & Scripts"),
                     subtitle: L10n.t("What happens to a file once it finishes.")) {
            SettingsCard(title: L10n.t("Extract"), symbol: "archivebox") {
                SettingRow(L10n.t("Auto-extract archives"),
                           detail: L10n.t("Unpack finished .zip, .tar, .7z and .rar downloads next to the file."),
                           isOn: setting(vm, \.postDownloadExtractArchives))
            }
            SettingsCard(title: L10n.t("Script"), symbol: "terminal") {
                SettingRow(L10n.t("Run a script on completion"),
                           detail: L10n.t("An executable script; %path% in the arguments becomes the finished file."),
                           isOn: setting(vm, \.postDownloadScriptEnabled))
                if vm.settings.postDownloadScriptEnabled {
                    SettingRow(L10n.t("Script path"), detail: L10n.t("Must be executable (not “bash script.sh”)."),
                               isIndented: true) {
                        SettingsTextField(text: setting(vm, \.postDownloadScriptPath), width: 200,
                                          placeholder: L10n.t("/path/to/script"), isMonospaced: true)
                    }
                    SettingRow(L10n.t("Arguments"),
                               detail: L10n.t("Passed to the script; %path% becomes the finished file."),
                               isIndented: true) {
                        SettingsTextField(text: setting(vm, \.postDownloadScriptArgs), width: 160,
                                          placeholder: L10n.t("%path%"), isMonospaced: true)
                    }
                }
            }
            .settingsColumn(.trailing)
        }
    }
}

/// Antivirus: an optional external scanner run on finished files.
struct AntivirusSettingsPane: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        SettingsPane(title: L10n.t("Antivirus"),
                     subtitle: L10n.t("Run an external scanner on finished files. Optional, low priority on macOS.")) {
            SettingsCard(title: L10n.t("Scanner"), symbol: "shield") {
                SettingRow(L10n.t("Scan finished files"),
                           detail: L10n.t("Run the scanner on each file when it finishes."),
                           isOn: setting(vm, \.antivirusEnabled))
                SettingRow(L10n.t("Scanner"),
                           detail: L10n.t("Pick ClamAV for its defaults, or set the command yourself.")) {
                    SettingsSelect(selection: setting(vm, \.antivirusScanner), options: [
                        SettingsOption("", L10n.t("Configure manually…")),
                        SettingsOption("ClamAV", "ClamAV"),
                    ], width: 170)
                }
                SettingRow(L10n.t("Executable path"),
                           detail: L10n.t("Full path to the scanner, e.g. /opt/homebrew/bin/clamscan.")) {
                    SettingsTextField(text: setting(vm, \.antivirusExecutablePath), width: 200,
                                      placeholder: L10n.t("/path/to/scanner"), isMonospaced: true)
                }
                SettingRow(L10n.t("Argument template"), detail: L10n.t("%path% is replaced with the file.")) {
                    SettingsTextField(text: setting(vm, \.antivirusArgumentTemplate), width: 140,
                                      placeholder: L10n.t("%path%"), isMonospaced: true)
                }
            }
        }
    }
}

/// Media Tools: stream quality, subtitles, and ffmpeg conversions.
struct MediaToolsSettingsPane: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        SettingsPane(title: L10n.t("Media Tools"),
                     subtitle: L10n.t("Stream quality, subtitles, and ffmpeg conversions.")) {
            SettingsCard(title: L10n.t("Streams"), symbol: "play.rectangle") {
                SettingRow(L10n.t("Max video quality"),
                           detail: L10n.t("Preferred rendition when grabbing an HLS (.m3u8) stream.")) {
                    SettingsSelect(selection: setting(vm, \.hlsMaxHeight), options: [
                        SettingsOption(0, L10n.t("Best available")),
                        SettingsOption(1080, "1080p"),
                        SettingsOption(720, "720p"),
                        SettingsOption(480, "480p"),
                        SettingsOption(360, "360p"),
                    ], width: 140)
                }
            }
            SettingsCard(title: L10n.t("Subtitles"), symbol: "captions.bubble") {
                SettingRow(L10n.t("Download subtitles"),
                           detail: L10n.t("Fetch subtitles alongside yt-dlp video downloads (requires yt-dlp)."),
                           isOn: setting(vm, \.subtitleDownloadEnabled))
                if vm.settings.subtitleDownloadEnabled {
                    SettingRow(L10n.t("Subtitle languages"),
                               detail: L10n.t("Comma-separated codes, e.g. “en, es”."),
                               isIndented: true) {
                        SettingsTextField(text: setting(vm, \.subtitleLanguages), width: 130,
                                          placeholder: L10n.t("en, es"), isMonospaced: true)
                    }
                    SettingRow(L10n.t("Include auto-captions"),
                               detail: L10n.t("Fall back to machine-generated captions when no human subtitles exist."),
                               isIndented: true, isOn: setting(vm, \.subtitleIncludeAutoGenerated))
                }
            }
            SettingsCard(title: L10n.t("Conversions"), symbol: "arrow.left.arrow.right") {
                SettingRow(L10n.t("ffmpeg path"),
                           detail: L10n.t("Optional. Leave empty to use the copy included with Goel°. Enables "
                               + "Convert / Extract-audio on finished media.")) {
                    SettingsTextField(text: setting(vm, \.ffmpegPath), width: 180,
                                      placeholder: L10n.t("Included copy"), isMonospaced: true,
                                      placeholderIsMonospaced: false)
                }
                SettingsCardBlock(showsDivider: false, verticalPadding: 0) {
                    SettingsFootnote(text: vm.ffmpegResolutionSummary,
                                     tone: vm.ffmpegUnavailableReason == nil ? .neutral : .warn,
                                     symbol: vm.ffmpegUnavailableReason == nil
                                         ? "checkmark.circle" : "exclamationmark.triangle")
                }
                .padding(.bottom, Studio.Space.m)
                SettingRow(L10n.t("Conversions at once"),
                           detail: L10n.t("ffmpeg already uses every core for one job, so running more at "
                               + "the same time makes each one slower without finishing the batch sooner.")) {
                    SettingsSelect(selection: setting(vm, \.mediaConcurrency), options: [
                        SettingsOption(1, "1"), SettingsOption(2, "2"), SettingsOption(3, "3"), SettingsOption(4, "4"),
                    ], width: 80)
                }
            }
            .settingsColumn(.trailing)
        }
    }
}
