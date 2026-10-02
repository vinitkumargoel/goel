import SwiftUI
import GoelCore

/// Scheduler: what happens when the queue finishes, a daily download window, and the weekly
/// profile grid.
struct SchedulerSettingsPane: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        SettingsPane(title: L10n.t("Scheduler"),
                     subtitle: L10n.t("Download windows, scheduled profiles, and "
                         + "what happens when the queue finishes."),
                     fillsWidth: true) {
            VStack(alignment: .leading, spacing: Studio.Space.l) {
                SettingsColumns(spacing: Studio.Space.l) {
                    finishCard
                    windowCard
                        .settingsColumn(.trailing)
                }
                weeklyCard
            }
        }
    }

    private var finishCard: some View {
        SettingsCard(title: L10n.t("When downloads finish"), symbol: "flag.checkered") {
            SettingRow(L10n.t("Then"), detail: L10n.t("One-shot — resets to “Do nothing” after it fires.")) {
                SettingsSelect(selection: setting(vm, \.autoShutdownAction), options: Self.finishOptions, width: 150)
            }
        }
    }

    private static var finishOptions: [SettingsOption<String>] {
        [
            SettingsOption("none", L10n.t("Do nothing")),
            SettingsOption("quit", L10n.t("Quit Goel°")),
            SettingsOption("sleep", L10n.t("Sleep")),
            SettingsOption("shutdown", L10n.t("Shut down")),
        ]
    }

    private var windowCard: some View {
        SettingsCard(title: L10n.t("Download window"), symbol: "clock") {
            SettingRow(L10n.t("Only download during a daily window"),
                       detail: L10n.t("Outside the window active downloads pause and queued ones wait."),
                       isOn: setting(vm, \.scheduleEnabled))
            if vm.settings.scheduleEnabled {
                SettingRow(L10n.t("Start"), isIndented: true) {
                    SettingsSelect(selection: setting(vm, \.scheduleStartMinute), options: Self.timeOptions, width: 100)
                }
                SettingRow(L10n.t("End"), detail: L10n.t("An end before the start wraps past midnight."),
                           isIndented: true) {
                    SettingsSelect(selection: setting(vm, \.scheduleEndMinute), options: Self.timeOptions, width: 100)
                }
                SettingRow(L10n.t("Days"), isIndented: true) {
                    SettingsSelect(selection: daysBinding, options: [
                        SettingsOption("all", L10n.t("Every day")),
                        SettingsOption("weekdays", L10n.t("Weekdays")),
                        SettingsOption("weekend", L10n.t("Weekends")),
                    ], width: 120)
                }
                SettingRow(L10n.t("Profile inside the window"),
                           detail: L10n.t("Switch speed profiles while the window is open (restored after)."),
                           isIndented: true) {
                    SettingsSelect(selection: setting(vm, \.scheduleProfileName),
                                   options: [SettingsOption("", L10n.t("Keep current"))]
                                       + vm.settings.profiles.map { SettingsOption($0.name, $0.name) },
                                   width: 130)
                }
            }
        }
    }

    private var weeklyCard: some View {
        SettingsCard(title: L10n.t("Weekly profile schedule"), symbol: "calendar") {
            SettingRow(L10n.t("Switch profiles by the hour"),
                       detail: L10n.t("Paint hours with a speed profile. A manual "
                           + "change holds until the next painted hour."),
                       isOn: setting(vm, \.profileScheduleEnabled))
            if vm.settings.profileScheduleEnabled {
                SettingsCardBlock {
                    WeeklyProfileGrid()
                    summaryLine
                        .padding(.top, Studio.Space.xs)
                }
                .padding(.bottom, Studio.Space.xs)
            }
        }
    }

    /// "When downloads finish: Do nothing · Daily download window: off · Now: Friday 21:00 · Medium".
    private var summaryLine: some View {
        let finish = Self.finishOptions.first { $0.value == vm.settings.autoShutdownAction }?.title
            ?? L10n.t("Do nothing")
        let now = Date()
        let slot = ProfileSchedule.slot(for: now)
        let painted = ProfileSchedule.profile(at: slot, in: ProfileSchedule.normalized(vm.settings.profileSchedule))
        let clock = Calendar.current.dateComponents([.hour, .minute], from: now)
        let nowText = now.formatted(.dateTime.weekday(.wide))
            + String(format: " %02d:%02d", clock.hour ?? 0, clock.minute ?? 0)
        return HStack(spacing: Studio.Space.l) {
            summaryItem(L10n.t("When downloads finish"), finish)
            summaryItem(L10n.t("Download window"),
                        vm.settings.scheduleEnabled ? L10n.t("On") : L10n.t("Off"))
            Spacer(minLength: Studio.Space.s)
            HStack(spacing: Studio.Space.xxs) {
                Text(L10n.t("Now: %@", nowText))
                    .foregroundStyle(Studio.Palette.ink3)
                Text(verbatim: "·")
                    .foregroundStyle(Studio.Palette.ink3)
                Text(painted ?? L10n.t("Leave alone"))
                    .studioFont(.small.weight(650))
                    .foregroundStyle(painted == nil ? Studio.Palette.ink2 : Studio.Palette.accent)
            }
            .studioFont(.small)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
    }

    private func summaryItem(_ label: String, _ value: String) -> some View {
        HStack(spacing: Studio.Space.xxs) {
            Text(L10n.t("%@:", label))
                .foregroundStyle(Studio.Palette.ink3)
            Text(value)
                .studioFont(.small.weight(650))
                .foregroundStyle(Studio.Palette.ink)
        }
        .studioFont(.small)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private static let timeOptions: [SettingsOption<Int>] =
        stride(from: 0, to: 1440, by: 60).map { minutes in
            SettingsOption(minutes, String(format: "%02d:%02d", minutes / 60, minutes % 60))
        }

    private var daysBinding: Binding<String> {
        Binding(
            get: {
                switch Set(vm.settings.scheduleDays) {
                case Set(2...6): return "weekdays"
                case [1, 7]: return "weekend"
                default: return "all"
                }
            },
            set: { preset in
                vm.update {
                    switch preset {
                    case "weekdays": $0.scheduleDays = [2, 3, 4, 5, 6]
                    case "weekend": $0.scheduleDays = [1, 7]
                    default: $0.scheduleDays = [1, 2, 3, 4, 5, 6, 7]
                    }
                }
            }
        )
    }
}

/// RSS Feeds: how often feeds are checked, the feed list, and adding one.
struct RSSSettingsPane: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var newURL = ""
    @State private var newPattern = ""
    @State private var newStartPaused = false

    var body: some View {
        SettingsPane(title: L10n.t("RSS Feeds"),
                     subtitle: L10n.t("Watch feeds and queue new items automatically "
                         + "(podcasts, releases, torrent feeds).")) {
            SettingsCard(title: L10n.t("Feeds"), symbol: "dot.radiowaves.up.forward") {
                if vm.settings.rssFeeds.isEmpty {
                    SettingsCardBlock(showsDivider: false) {
                        Text(L10n.t("No feeds yet — add one below."))
                            .studioFont(.body)
                            .foregroundStyle(Studio.Palette.ink3)
                    }
                }
                ForEach(vm.settings.rssFeeds) { feed in
                    SettingRow(feed.url, detail: feedSummary(feed)) {
                        HStack(spacing: Studio.Space.sm) {
                            SettingSwitch(isOn: feedEnabledBinding(feed.id))
                            SettingsRowIconButton(symbol: "trash", label: L10n.t("Remove feed %@", feed.url),
                                                  help: L10n.t("Remove feed")) { confirmRemove(feed) }
                        }
                    }
                }
            }
            SettingsCard(title: L10n.t("Add a feed"), symbol: "plus.circle") {
                SettingRow(L10n.t("Feed URL"), detail: L10n.t("RSS 2.0 or Atom.")) {
                    SettingsTextField(text: $newURL, width: 220, placeholder: L10n.t("https://…/feed.xml"),
                                      isMonospaced: true)
                }
                SettingRow(L10n.t("Title contains"), detail: L10n.t("Leave empty to take every item.")) {
                    SettingsTextField(text: $newPattern, width: 160, placeholder: L10n.t("Any title"))
                }
                SettingRow(L10n.t("Add items paused"), detail: L10n.t("Review matches before any bytes move."),
                           isOn: $newStartPaused)
                SettingsActionRow {
                    Button(L10n.t("Add Feed"), systemImage: "plus") { addFeed() }
                        .buttonStyle(.studio(.primary, size: .small))
                        .disabled(URL(string: newURL.trimmingCharacters(in: .whitespaces))?.host == nil)
                }
            }
            .settingsColumn(.trailing)
            SettingsCard(title: L10n.t("Checking"), symbol: "clock.arrow.circlepath") {
                SettingRow(L10n.t("Check feeds every")) {
                    SettingsSelect(selection: setting(vm, \.rssPollIntervalMinutes), options: [
                        SettingsOption(15, L10n.t("15 minutes")),
                        SettingsOption(30, L10n.t("30 minutes")),
                        SettingsOption(60, L10n.t("Hour")),
                        SettingsOption(360, L10n.t("6 hours")),
                    ], width: 120)
                }
                SettingRow(L10n.t("Rules and articles"),
                           detail: L10n.t("Must contain / must not contain, episode ranges, folder "
                               + "and tag per feed — with matches highlighted live.")) {
                    Button(L10n.t("Open RSS Reader")) {
                        vm.closeServerBrowser()
                        RSSReaderModel.shared.open()
                    }
                    .buttonStyle(.studio(.secondary, size: .small))
                }
            }
        }
    }

    private func confirmRemove(_ feed: RSSFeed) {
        vm.settingsConfirm(
            title: L10n.t("Remove the feed %@?", feed.url),
            message: L10n.t("Goel° stops checking it. Downloads it already queued are not touched."),
            confirmTitle: L10n.t("Remove"),
            destructive: true
        ) {
            vm.update { $0.rssFeeds.removeAll { $0.id == feed.id } }
            vm.toastSuccess(L10n.t("Feed removed"))
        }
    }

    /// One whole-sentence key per variant, so a translation never glues fragments together.
    private func feedSummary(_ feed: RSSFeed) -> String {
        switch (feed.titlePattern.isEmpty, feed.startPaused) {
        case (true, false): return L10n.t("Every item")
        case (true, true): return L10n.t("Every item · added paused")
        case (false, false): return L10n.t("Titles containing “%@”", feed.titlePattern)
        case (false, true): return L10n.t("Titles containing “%@” · added paused", feed.titlePattern)
        }
    }

    private func feedEnabledBinding(_ id: RSSFeed.ID) -> Binding<Bool> {
        Binding(
            get: { vm.settings.rssFeeds.first { $0.id == id }?.enabled ?? false },
            set: { newValue in
                vm.update {
                    guard let i = $0.rssFeeds.firstIndex(where: { $0.id == id }) else { return }
                    $0.rssFeeds[i].enabled = newValue
                }
            }
        )
    }

    private func addFeed() {
        let url = newURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        let feed = RSSFeed(url: url,
                           titlePattern: newPattern.trimmingCharacters(in: .whitespaces),
                           startPaused: newStartPaused)
        vm.update { $0.rssFeeds.append(feed) }
        newURL = ""
        newPattern = ""
        newStartPaused = false
        vm.toastSuccess(L10n.t("Feed added"))
    }
}
