import Foundation
import SwiftUI

// MARK: - SpeedLimitOption

/// The Speed limit menu: `Off / 1 / 5 / 10 / 25 MB/s`.
///
/// Base 10 throughout, to match `Fmt` and the mockup — 1 MB/s is 1 000 000 bytes per second,
/// not 1 048 576. The engine's token bucket reads the same number, so the label on the row and
/// the rate on the wire are the same value.
public enum SpeedLimitOption: Int64, CaseIterable, Identifiable, Sendable {
    case off = 0
    case oneMBps = 1_000_000
    case fiveMBps = 5_000_000
    case tenMBps = 10_000_000
    case twentyFiveMBps = 25_000_000

    public var id: Int64 { rawValue }

    /// `nil` is unlimited — the spelling `EngineTuning.speedLimitBytesPerSec` uses.
    public var bytesPerSecond: Int64? { self == .off ? nil : rawValue }

    public var displayName: String {
        self == .off ? "Off" : "\(rawValue / SpeedLimitOption.oneMBps.rawValue) MB/s"
    }

    /// The nearest option at or below a stored rate, so a value written by an older build (or by
    /// hand) still lands on a real menu entry instead of silently reading as Off.
    public init(bytesPerSecond: Int64?) {
        guard let bytesPerSecond, bytesPerSecond > 0 else {
            self = .off
            return
        }
        let candidates = Self.allCases.filter { $0 != .off && $0.rawValue <= bytesPerSecond }
        self = candidates.max(by: { $0.rawValue < $1.rawValue }) ?? .oneMBps
    }
}

// MARK: - CellularDataLedger

/// "Data used this month" — a real, persisted counter with a real reset rule.
///
/// The rollover is a pure function of a snapshot and a `now`, with the `Calendar` injected, so
/// the month boundary can be unit-tested without waiting for one. Everything that touches
/// `UserDefaults` is a thin wrapper over it.
///
/// - Note: this ledger only *holds* the number. The producer is the engine, which is the only
///   thing that knows a given byte crossed a cellular interface — it calls ``record(_:in:now:calendar:)``.
public enum CellularDataLedger {

    public struct Snapshot: Codable, Sendable, Equatable {
        /// Bytes transferred over cellular during the current period.
        public var bytes: Int64
        /// Midnight on the first of the month this count belongs to.
        public var periodStart: Date

        public init(bytes: Int64, periodStart: Date) {
            self.bytes = max(0, bytes)
            self.periodStart = periodStart
        }
    }

    /// Owned by this file. Distinct from `EngineTuning`'s key, which is owned by `AppModel`.
    public static let defaultsKey = "dev.goel.ios.cellularDataThisMonth"

    // MARK: Pure

    /// Midnight on the first of `date`'s month.
    public static func startOfMonth(containing date: Date, calendar: Calendar = .current) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }

    /// The whole reset rule, with nothing to mock.
    ///
    /// `isDate(_:equalTo:toGranularity: .month)` compares era, year *and* month, so the same
    /// month number a year later is correctly a new period.
    public static func rollingOver(
        _ snapshot: Snapshot,
        now: Date,
        calendar: Calendar = .current
    ) -> Snapshot {
        guard !calendar.isDate(snapshot.periodStart, equalTo: now, toGranularity: .month) else {
            return snapshot
        }
        return Snapshot(bytes: 0, periodStart: startOfMonth(containing: now, calendar: calendar))
    }

    // MARK: Persistence

    public static func load(
        from defaults: UserDefaults = .standard,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Snapshot {
        let stored: Snapshot
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            stored = decoded
        } else {
            stored = Snapshot(bytes: 0, periodStart: startOfMonth(containing: now, calendar: calendar))
        }

        let rolled = rollingOver(stored, now: now, calendar: calendar)
        if rolled != stored { save(rolled, to: defaults) }
        return rolled
    }

    public static func save(_ snapshot: Snapshot, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Adds cellular bytes to the current period, rolling the month over first if it has changed.
    @discardableResult
    public static func record(
        _ bytes: Int64,
        in defaults: UserDefaults = .standard,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Snapshot {
        let current = load(from: defaults, now: now, calendar: calendar)
        let updated = Snapshot(bytes: current.bytes + max(0, bytes), periodStart: current.periodStart)
        save(updated, to: defaults)
        return updated
    }
}

// MARK: - ContainerStorage

/// Recursive byte total of the app's Documents directory — the folder the Files app exposes and
/// the one downloads land in.
///
/// Free-standing and nonisolated so `SettingsView` can run it off the main actor. Walking a few
/// gigabytes of directory entries on the main thread is a visible stall, and this row is the one
/// place in the app that would do it.
enum ContainerStorage {

    static func usedBytes(at root: URL = URL.documentsDirectory) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else {
                continue
            }
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
            total += Int64(size)
        }
        return total
    }
}

// MARK: - Pill

/// `.pill { font-size: 11px; padding: 3px 8px; border-radius: 999px; background: rgba(48,209,88,.18) }`
/// from `visual.html`.
///
/// These belong in `Theme.Metric`; this task may not edit `Theme.swift`, so they are named here
/// rather than smuggled into the call site as bare literals.
private enum PillSpec {
    static let horizontalPadding: CGFloat = Theme.Metric.gutter / 2
    static let verticalPadding: CGFloat = 3
    static let fillOpacity: Double = 0.18
}

// MARK: - SettingsView

/// Frame 9 of `visual.html`: real engine capability, named in phone vocabulary.
///
/// Every control here writes to `AppModel.tuning`, whose `didSet` persists the value and pushes
/// it across the seam to the engine. Nothing on this screen is decorative — with one exception,
/// the Desktop row, which says out loud that it is a placeholder rather than pretending to pair.
public struct SettingsView: View {

    @Environment(AppModel.self) private var app

    @State private var storageUsed: Int64?
    @State private var cellularUsed: Int64 = 0
    @State private var isConfirmingClear = false

    @ScaledMetric(relativeTo: .caption2) private var pillSize: CGFloat = Theme.Typo.Size.sectionLabel

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                transfersSection
                cellularSection
                filesSection
                desktopSection
                aboutSection
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Clear completed downloads?",
                isPresented: $isConfirmingClear,
                titleVisibility: .visible
            ) {
                Button("Clear Completed", role: .destructive) {
                    app.store.clearCompleted()
                    refreshStorage()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes finished transfers from the Library list. The downloaded files stay in Goel° on this iPhone.")
            }
            .task {
                cellularUsed = CellularDataLedger.load().bytes
                refreshStorage()
            }
        }
    }

    // MARK: - Transfers

    private var transfersSection: some View {
        Section {
            NavigationLink {
                TrafficProfilePicker()
            } label: {
                LabeledContent("Traffic profile", value: app.tuning.trafficProfile.displayName)
            }

            Stepper(value: connections, in: TrafficProfilePolicy.connectionRange) {
                LabeledContent("Maximum connections") {
                    Text(app.tuning.maxConnections.formatted())
                        .monospacedDigit()
                }
            }
            .accessibilityValue("\(app.tuning.maxConnections) connections")

            Picker("Speed limit", selection: speedLimit) {
                ForEach(SpeedLimitOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.navigationLink)
        } header: {
            Text("Transfers").textCase(.uppercase)
        }
    }

    // MARK: - Cellular

    private var cellularSection: some View {
        Section {
            Toggle("Download over cellular", isOn: allowCellular)
                .tint(Theme.Color.success)

            Toggle("Finish on Wi\u{2011}Fi", isOn: finishOnWiFi)
                .tint(Theme.Color.success)

            LabeledContent("Data used this month") {
                Text(Fmt.bytes(cellularUsed))
                    .monospacedDigit()
            }
        } header: {
            Text("Cellular").textCase(.uppercase)
        } footer: {
            Text("With cellular off, a transfer that can only reach the network over cellular waits for Wi\u{2011}Fi instead of failing. The counter resets on the first of each month.")
        }
    }

    // MARK: - Files

    private var filesSection: some View {
        Section {
            // Not a toggle: file sharing is declared in Info.plist and cannot be switched at
            // runtime. A switch here would move nothing, so this states the fact instead.
            LabeledContent("Show in Files app", value: "On")

            Toggle("Verify checksums", isOn: verifyChecksums)
                .tint(Theme.Color.success)

            LabeledContent("Storage used") {
                if let storageUsed {
                    Text(Fmt.bytes(storageUsed))
                        .monospacedDigit()
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Measuring")
                }
            }

            Button("Clear completed", role: .destructive) {
                isConfirmingClear = true
            }
            .disabled(app.store.completedDownloads.isEmpty)
        } header: {
            Text("Files").textCase(.uppercase)
        } footer: {
            Text("Downloads land in Goel°, which the Files app shows under On My iPhone. Checksum verification runs after the last byte arrives and refuses a file that does not match.")
        }
    }

    // MARK: - Desktop

    /// T12 is explicit that this is a placeholder for the V1.2 continuity feature. It keeps the
    /// mockup's shape — label, secondary value, green pill — and tells the truth in all three.
    private var desktopSection: some View {
        Section {
            LabeledContent("Paired with") {
                HStack {
                    Text("Nothing yet")
                        .foregroundStyle(Theme.Color.label2)
                    pill("Coming in 1.2")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Paired with nothing yet. Desktop pairing arrives in version 1.2.")
        } header: {
            Text("Desktop").textCase(.uppercase)
        } footer: {
            Text("Handing a transfer between Goel° on your Mac and this iPhone arrives in version 1.2. There is nothing to pair yet — this row is where it will live.")
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: pillSize, weight: .semibold))
            .foregroundStyle(Theme.Color.success)
            .padding(.horizontal, PillSpec.horizontalPadding)
            .padding(.vertical, PillSpec.verticalPadding)
            .background(Capsule().fill(Theme.Color.success.opacity(PillSpec.fillOpacity)))
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Self.versionString())

            NavigationLink {
                AcknowledgementsView()
            } label: {
                Text("Acknowledgements")
            }

            #if DEBUG
            NavigationLink {
                SwatchView()
            } label: {
                Text("Design tokens")
            }

            NavigationLink {
                WidgetGalleryView()
            } label: {
                Text("Widget gallery")
            }
            #endif
        } header: {
            Text("About").textCase(.uppercase)
        }
    }

    static func versionString(bundle: Bundle = .main) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let short, let build else { return short ?? build ?? Fmt.placeholder }
        return "\(short) (\(build))"
    }

    // MARK: - Bindings
    //
    // Written as explicit bindings rather than one `@Bindable` in `body`, so the sections can be
    // separate computed properties. Each write goes through `AppModel.tuning`'s `didSet`, which
    // persists and pushes to the engine.

    private var connections: Binding<Int> {
        Binding(
            get: { app.tuning.maxConnections },
            set: { app.tuning.maxConnections = TrafficProfilePolicy.clampConnections($0) }
        )
    }

    private var speedLimit: Binding<SpeedLimitOption> {
        Binding(
            get: { SpeedLimitOption(bytesPerSecond: app.tuning.speedLimitBytesPerSec) },
            set: { app.tuning.speedLimitBytesPerSec = $0.bytesPerSecond }
        )
    }

    private var allowCellular: Binding<Bool> {
        Binding(get: { app.tuning.allowCellular }, set: { app.tuning.allowCellular = $0 })
    }

    private var finishOnWiFi: Binding<Bool> {
        Binding(get: { app.tuning.finishOnWiFi }, set: { app.tuning.finishOnWiFi = $0 })
    }

    private var verifyChecksums: Binding<Bool> {
        Binding(get: { app.tuning.verifyChecksums }, set: { app.tuning.verifyChecksums = $0 })
    }

    // MARK: - Storage

    private func refreshStorage() {
        Task {
            let bytes = await Task.detached(priority: .utility) {
                ContainerStorage.usedBytes()
            }.value
            storageUsed = bytes
        }
    }
}

// MARK: - AcknowledgementsView

/// Short because it is true: `apps/ios/project.yml` has zero SPM dependencies.
struct AcknowledgementsView: View {
    var body: some View {
        List {
            Section {
                Text("Goel° for iPhone ships no third-party code. Everything on screen is built from Apple's SDK — SwiftUI, Observation, URLSession, ActivityKit, WidgetKit and App Intents.")
            } header: {
                Text("Third-party code").textCase(.uppercase)
            }

            Section {
                Text("The type scale, colour ramp and metrics come from the project's own design reference, `visual.html`. `Theme.swift` is the single place those values live.")
            } header: {
                Text("Design").textCase(.uppercase)
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}
