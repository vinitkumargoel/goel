import SwiftUI
import AppKit
import GoelCore

/// Master–detail replacement for the flat transfer strip. The list stays scannable at a
/// glance; the inspector carries the throughput graph, the route and the server facts the
/// old single-line row had no room for.
struct SFTPTransferPanel: View {
    let transfers: [SFTPTransfer]
    let connection: SFTPConnection
    /// Already fetched by the browser for its footer — passed in rather than probed again.
    let volumeSpace: SFTPVolumeSpace?

    @EnvironmentObject private var vm: AppViewModel
    @State private var selection: UUID?

    /// Tall enough for the graph plus the fact rows without either column scrolling in the
    /// common case; both columns still scroll, so a short window degrades rather than clips.
    private static let panelHeight: CGFloat = 292
    private static let listWidth: CGFloat = 248

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                transferList
                    .frame(width: Self.listWidth)
                Divider()
                if let selected {
                    SFTPTransferInspector(transfer: selected, connection: connection,
                                          volumeSpace: volumeSpace,
                                          history: vm.sftpSpeedHistory[selected.id] ?? [])
                } else {
                    EmptyStateView(systemImage: "arrow.up.arrow.down.circle",
                                   title: L10n.t("No transfer selected"),
                                   symbolSize: 26, symbolStyle: .quaternary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(height: Self.panelHeight)
        .background(.regularMaterial)
        .onAppear { adoptSelection() }
        // Rows leave the list on cancel and on "Clear finished": without this the inspector
        // would keep rendering a transfer that no longer exists.
        .onChange(of: transfers.map(\.id)) { adoptSelection() }
    }

    /// Falls back rather than blanking: a stale id resolves to the first live transfer.
    private var selected: SFTPTransfer? {
        transfers.first { $0.id == selection } ?? preferredSelection
    }

    /// What a user most likely wants to look at: something still moving, else the first row.
    private var preferredSelection: SFTPTransfer? {
        transfers.first { $0.isActive } ?? transfers.first { $0.isPaused } ?? transfers.first
    }

    private func adoptSelection() {
        if let selection, transfers.contains(where: { $0.id == selection }) { return }
        selection = preferredSelection?.id
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(L10n.t("Transfers"))
                .scaledFont(size: 11, weight: .bold)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Text(countSummary)
                .scaledFont(size: 11, monospacedDigit: true)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            if aggregateSpeed > 0 {
                SpeedStat(symbol: aggregateGlyph, speed: aggregateSpeed, color: Theme.accent, size: 11)
            }
            if transfers.contains(where: { !$0.occupiesDestination }) {
                Button(L10n.t("Clear")) { vm.clearFinishedSFTPTransfers() }
                    .buttonStyle(.plain).scaledFont(size: 11).foregroundStyle(Theme.accent)
                    .accessibilityLabel(L10n.t("Clear finished transfers"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private var countSummary: String {
        let running = transfers.filter { $0.state == .running }.count
        let waiting = transfers.filter { $0.state == .waiting }.count
        var parts: [String] = []
        if running > 0 { parts.append(L10n.t("%d active", running)) }
        if waiting > 0 { parts.append(L10n.t("%d queued", waiting)) }
        if parts.isEmpty { parts.append(L10n.t("%d items", transfers.count)) }
        return parts.joined(separator: " · ")
    }

    private var aggregateSpeed: Double {
        transfers.reduce(0) { $0 + ($1.isActive ? $1.displaySpeed : 0) }
    }

    /// One glyph for a mixed batch; a single-direction batch gets its own arrow.
    private var aggregateGlyph: String {
        let directions = Set(transfers.filter(\.isActive).map(\.direction))
        guard directions.count == 1, let only = directions.first else {
            return "arrow.up.arrow.down"
        }
        switch only {
        case .upload: return "arrow.up"
        case .download: return "arrow.down"
        case .remoteCopy: return "arrow.left.arrow.right"
        }
    }

    // MARK: - Master list

    private var transferList: some View {
        // Resolved once per render: `selected` scans the array, and reading it per row made
        // drawing the list quadratic in the number of transfers.
        let selectedID = selected?.id
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(transfers) { transfer in
                    // A real Button, not a tap gesture: the row claims `.isButton`, and only
                    // a Button makes that true for keyboard focus and VoiceOver activation.
                    Button { selection = transfer.id } label: {
                        SFTPTransferListRow(transfer: transfer,
                                            isSelected: selectedID == transfer.id)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { rowMenu(transfer) }
                    Divider().opacity(0.4)
                }
            }
        }
        .background(Color.primary.opacity(0.03))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Transfer list"))
    }

    @ViewBuilder
    private func rowMenu(_ transfer: SFTPTransfer) -> some View {
        if transfer.canPause {
            Button(L10n.t("Pause")) { vm.pauseSFTPTransfer(transfer.id) }
        }
        if transfer.canResume {
            Button(L10n.t("Resume")) { vm.resumeSFTPTransfer(transfer.id) }
        }
        if !transfer.isActive && !transfer.isPaused && transfer.state != .finished {
            Button(L10n.t("Retry")) { vm.retrySFTPTransfer(transfer.id) }
        }
        Button(L10n.t("Show Remote Folder")) { vm.revealSFTPTransfer(transfer) }
        Divider()
        Button(L10n.t("Cancel"), role: .destructive) { vm.requestCancelSFTPTransfer(transfer.id) }
    }
}

/// A list row carries only what survives at 248 pt: identity, direction, one bar, one number.
/// Everything else moved to the inspector.
struct SFTPTransferListRow: View {
    let transfer: SFTPTransfer
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: transfer.iconName(filledWhenFinished: true))
                .font(.system(size: 13))
                .foregroundStyle(transfer.tint)
                .frame(width: 16)
                .a11yDecorative()
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name)
                    .scaledFont(size: 12)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if transfer.isActive || transfer.isPaused {
                    ProgressView(value: transfer.fraction)
                        .progressViewStyle(.linear)
                        .tint(transfer.isPaused ? Theme.orange : transfer.directionTint)
                        .frame(height: 3)
                } else {
                    Text(secondaryLine)
                        .scaledFont(size: 10.5)
                        .foregroundStyle(transfer.failureMessage == nil ? Color.secondary : Theme.red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if transfer.total > 0, transfer.isActive || transfer.isPaused {
                Text(transfer.progressLabel)
                    .scaledFont(size: 10.5, weight: .semibold, monospacedDigit: true)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(isSelected ? Theme.accent.opacity(0.18) : Color.clear)
        .overlay(alignment: .leading) {
            if isSelected { Rectangle().fill(Theme.accent).frame(width: 2.5) }
        }
        .contentShape(Rectangle())
        .a11yGroup(label: A11y.sentence(L10n.t(transfer.activityLabel), transfer.name),
                   value: A11y.sentence(transfer.stateLabel,
                                        transfer.total > 0 ? A11y.percent(transfer.fraction) : nil),
                   hint: L10n.t("Shows this transfer’s details."))
        // `.isButton` comes from the enclosing Button; only selection is added here.
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var secondaryLine: String {
        if let failure = transfer.failureMessage { return failure }
        switch transfer.state {
        case .finished:  return L10n.t("Done") + (transfer.total > 0 ? " · \(transfer.total.byteString)" : "")
        case .cancelled: return L10n.t("Cancelled")
        default:         return transfer.stateLabel
        }
    }
}

/// The right-hand pane: progress ring and route (the inspector half), throughput graph and
/// now/average/peak readings (the telemetry half), then the server facts behind the numbers.
struct SFTPTransferInspector: View {
    let transfer: SFTPTransfer
    let connection: SFTPConnection
    let volumeSpace: SFTPVolumeSpace?
    let history: [Double]

    @EnvironmentObject private var vm: AppViewModel
    /// Re-read every sampler tick so elapsed and average advance without their own timer.
    private var now: Date { Date() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                progress
                if let failure = transfer.failureMessage { failureNote(failure) }
                Divider().padding(.vertical, 12)
                telemetry
                Divider().padding(.vertical, 12)
                route
                Divider().padding(.vertical, 12)
                facts
                actions
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(spacing: 13) {
            progressRing
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name)
                    .scaledFont(size: 14, weight: .semibold)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 7) {
                    StatusPill(text: transfer.stateLabel, tint: transfer.tint)
                    if transfer.isDirectory {
                        Text(L10n.t("Folder · up to %d streams", AppViewModel.maxParallelUploads))
                            .scaledFont(size: 11).foregroundStyle(.secondary)
                    } else if transfer.total > 0 {
                        Text(transfer.total.byteString)
                            .scaledFont(size: 11, monospacedDigit: true).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .a11yGroup(label: A11y.sentence(L10n.t(transfer.activityLabel), transfer.name),
                   value: A11y.sentence(transfer.stateLabel, A11y.percent(transfer.fraction)))
    }

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 5)
            Circle()
                .trim(from: 0, to: max(0.001, transfer.fraction))
                .stroke(transfer.tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            // A folder before its walk finishes, and any file the server gave no size for,
            // have no honest percentage — the dash says so instead of showing a stuck 0%.
            Text(transfer.total > 0 ? "\(Int(transfer.fraction * 100))" : "—")
                .scaledFont(size: 12, weight: .semibold, monospacedDigit: true)
        }
        .frame(width: 50, height: 50)
        .a11yDecorative()
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: transfer.fraction)
                .progressViewStyle(.linear)
                .tint(transfer.tint)
            HStack {
                Text(transfer.sizeLabel)
                    .scaledFont(size: 11, monospacedDigit: true).foregroundStyle(.secondary)
                Spacer()
                if let remaining = transfer.remainingBytes {
                    Text(L10n.t("%@ left", remaining.byteString))
                        .scaledFont(size: 11, monospacedDigit: true).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.top, 13)
        .a11yGroup(label: L10n.t("Transfer progress"),
                   value: L10n.t("%1$@ of %2$@", A11y.bytes(transfer.bytes), A11y.bytes(transfer.total)))
    }

    private func failureNote(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(Theme.red)
                .a11yDecorative()
            Text(message)
                .scaledFont(size: 11).foregroundStyle(Theme.red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(Theme.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
        .padding(.top, 11)
        .accessibilityLabel(L10n.t("Failed, %@", message))
    }

    // MARK: - Telemetry

    private var telemetry: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.t("Throughput"))
                    .scaledFont(size: 10.5, weight: .bold).foregroundStyle(.tertiary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if history.count > 1 {
                    Text(L10n.t("last %ds", history.count))
                        .scaledFont(size: 10, monospacedDigit: true).foregroundStyle(.tertiary)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                graph
                readings
            }
        }
    }

    @ViewBuilder
    private var graph: some View {
        if history.count > 2 {
            SparklineView(values: history, tint: transfer.directionTint)
                .frame(height: 58)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .a11yGroup(
                    label: L10n.t("Throughput graph, last %d seconds", history.count),
                    value: A11y.sentence(A11y.speed(transfer.displaySpeed),
                                         L10n.t("peak %@", A11y.speed(transfer.peakSpeed))))
                .accessibilityAddTraits(.updatesFrequently)
        } else {
            // Two samples draw no line; the placeholder keeps the readings from jumping
            // sideways on the second tick.
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
                .frame(height: 70)
                .frame(maxWidth: .infinity)
                .overlay(
                    Text(transfer.isActive ? L10n.t("Measuring…") : L10n.t("No throughput recorded"))
                        .scaledFont(size: 11).foregroundStyle(.tertiary))
                .a11yDecorative()
        }
    }

    private var readings: some View {
        VStack(spacing: 5) {
            reading(L10n.t("Now"), transfer.displaySpeed.speedString,
                    tint: transfer.displaySpeed > 0 ? transfer.directionTint : .secondary,
                    spoken: A11y.speed(transfer.displaySpeed))
            reading(L10n.t("Average"), transfer.averageSpeed(at: now).speedString,
                    spoken: A11y.speed(transfer.averageSpeed(at: now)))
            reading(L10n.t("Peak"), transfer.peakSpeed.speedString,
                    spoken: A11y.speed(transfer.peakSpeed))
            reading(transfer.isActive ? L10n.t("ETA") : L10n.t("Took"),
                    transfer.isActive ? (transfer.etaLabel ?? "—") : (elapsedLabel ?? "—"),
                    spoken: transfer.isActive ? (A11y.eta(transfer.etaSeconds) ?? "—")
                                              : (elapsedLabel ?? "—"))
        }
        .frame(width: 132)
    }

    private func reading(_ label: String, _ value: String,
                         tint: Color = .primary, spoken: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .scaledFont(size: 10, weight: .semibold).foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            Text(value)
                .scaledFont(size: 11.5, weight: .semibold, monospacedDigit: true)
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .a11yGroup(label: label, value: spoken ?? value)
    }

    private var elapsedLabel: String? {
        transfer.elapsed(at: now).map { DownloadTask.etaString($0) }
    }

    // MARK: - Route

    /// Source always on the left, destination on the right, so the arrow between them reads
    /// in the direction the bytes actually travel — including for a remote copy, where both
    /// ends live on the server and there is no local path at all.
    private var route: some View {
        HStack(alignment: .top, spacing: 10) {
            routeEnd(title: L10n.t("From · %@", sourcePlace), path: sourcePath)
            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(transfer.directionTint)
                .padding(.top, 13)
                .a11yDecorative()
            routeEnd(title: L10n.t("To · %@", destinationPlace), path: destinationPath)
        }
    }

    private var thisMac: String { L10n.t("this Mac") }
    private var theServer: String { L10n.t("server") }

    private var sourcePlace: String { transfer.direction == .upload ? thisMac : theServer }

    private var destinationPlace: String { transfer.direction == .download ? thisMac : theServer }

    private var sourcePath: String {
        switch transfer.direction {
        case .upload:
            return transfer.localURL?.path ?? L10n.t("Unknown")
        case .download:
            return transfer.remotePath
        case .remoteCopy:
            // The plan is the only record of where a copy came from; it is dropped when the
            // row is cleared, so the fallback must not claim the destination is the source.
            return vm.sftpRemoteCopyPlans[transfer.id]?.sourcePath ?? L10n.t("Unknown")
        }
    }

    private var destinationPath: String {
        transfer.direction == .download
            ? (transfer.localURL?.path ?? L10n.t("Unknown"))
            : transfer.remotePath
    }

    private func routeEnd(title: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .scaledFont(size: 9.5, weight: .bold).foregroundStyle(.tertiary)
            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .a11yGroup(label: title, value: path)
    }

    // MARK: - Facts

    private var facts: some View {
        VStack(alignment: .leading, spacing: 6) {
            factRow(L10n.t("Server"), serverValue)
            factRow(L10n.t("Login"), L10n.t("%1$@ · %2$@", connection.credentialKey, authLabel))
            if let os = vm.serverMeta[connection.id]?.os {
                factRow(L10n.t("System"), A11y.sentence(os.label, volumeLabel))
            } else if let volumeLabel {
                factRow(L10n.t("Disk"), volumeLabel)
            }
            factRow(L10n.t("Limit"), limitLabel)
            if transfer.resumedFrom > 0 {
                factRow(L10n.t("Resumed"),
                        L10n.t("%@ was already there and wasn’t sent again",
                               transfer.resumedFrom.byteString))
            }
            if let started = transfer.startedAt {
                factRow(L10n.t("Started"), started.formatted(date: .omitted, time: .standard))
            }
        }
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .scaledFont(size: 11).foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .trailing)
            Text(value)
                .scaledFont(size: 11.5)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .a11yGroup(label: label, value: value)
    }

    private var serverValue: String {
        let meta = vm.serverMeta[connection.id]
        let reach = L10n.t(meta?.reachability.help ?? ServerReachability.unknown.help)
        guard let latency = meta?.latencyMS else {
            return L10n.t("%1$@ · %2$@", connection.label, reach)
        }
        return L10n.t("%1$@ · %2$@ · %3$d ms", connection.label, reach, latency)
    }

    private var authLabel: String {
        if connection.useAgent { return L10n.t("SSH agent") }
        if connection.privateKeyPath?.isEmpty == false { return L10n.t("SSH key") }
        return L10n.t("Password")
    }

    private var volumeLabel: String? {
        guard let volumeSpace, volumeSpace.totalBytes > 0 else { return nil }
        return L10n.t("%@ free", volumeSpace.freeBytes.byteString)
    }

    /// Names the cap that is actually throttling *this* direction, so a slow upload under a
    /// download-only limit doesn't read as if the limit were to blame.
    private var limitLabel: String {
        let profile = vm.settings.effectiveProfile
        let cap = transfer.direction == .download ? profile.maxDownloadBytesPerSec
                                                  : profile.maxUploadBytesPerSec
        guard cap > 0 else { return L10n.t("No speed limit") }
        return L10n.t("Capped at %@", Double(cap).speedString)
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 8) {
            if transfer.canPause {
                Button(L10n.t("Pause")) { vm.pauseSFTPTransfer(transfer.id) }
                    .a11yButton(L10n.t("Pause transfer of %@", transfer.name))
            }
            if transfer.canResume {
                Button(L10n.t("Resume")) { vm.resumeSFTPTransfer(transfer.id) }
                    .buttonStyle(.borderedProminent)
                    .a11yButton(L10n.t("Resume transfer of %@", transfer.name))
            }
            if !transfer.isActive, !transfer.isPaused, transfer.state != .finished {
                Button(L10n.t("Retry")) { vm.retrySFTPTransfer(transfer.id) }
                    .a11yButton(L10n.t("Retry transfer of %@", transfer.name))
            }
            Button(L10n.t("Show Remote Folder")) { vm.revealSFTPTransfer(transfer) }
                .a11yButton(L10n.t("Show the remote folder for %@", transfer.name))
            if let localURL = transfer.localURL, transfer.state == .finished {
                Button(L10n.t("Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([localURL])
                }
                .a11yButton(L10n.t("Show %@ in Finder", transfer.name))
            }
            Menu {
                Button(L10n.t("Copy Remote Path")) { copy(transfer.remotePath) }
                Button(L10n.t("Copy sftp:// Link")) { copy(sftpURL) }
                if let localURL = transfer.localURL {
                    Button(L10n.t("Copy Local Path")) { copy(localURL.path) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(L10n.t("More actions"))
            Spacer(minLength: 0)
            if transfer.isActive || transfer.isPaused {
                Button(L10n.t("Cancel"), role: .destructive) {
                    vm.requestCancelSFTPTransfer(transfer.id)
                }
                .a11yButton(L10n.t("Cancel transfer of %@", transfer.name))
            }
        }
        .controlSize(.small)
        .padding(.top, 14)
    }

    private var sftpURL: String {
        let path = transfer.remotePath
        return "sftp://\(connection.username)@\(connection.host):\(connection.port)"
            + (path.hasPrefix("/") ? path : "/" + path)
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        vm.toastNow(L10n.t("Copied"))
    }
}

struct StatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .scaledFont(size: 10, weight: .bold)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            // 12% matches KindBadge, which was measured at 3.83–7.95:1 across the themes.
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }
}

#if DEBUG
/// Only the list row is previewed. The panel and the inspector need an `AppViewModel` in the
/// environment, and constructing one opens the real Application Support database and reassigns
/// the app-wide `AppViewModel.shared` — which is why no view in this app previews with one.
#Preview("SFTP transfer rows") {
    func sample(_ name: String, _ direction: SFTPTransfer.Direction,
                total: Int64, done: Int64, state: SFTPTransfer.State) -> SFTPTransfer {
        var t = SFTPTransfer(connectionID: UUID(), name: name, direction: direction,
                             isDirectory: false,
                             localURL: URL(fileURLWithPath: "/Users/you/Downloads/\(name)"),
                             remotePath: "/srv/media/isos/\(name)", total: total)
        t.record(bytes: done)
        t.state = state
        return t
    }

    return VStack(spacing: 0) {
        SFTPTransferListRow(
            transfer: sample("ubuntu-24.04-desktop.iso", .download,
                             total: 3_113_851_904, done: 1_847_249_920, state: .running),
            isSelected: true)
        Divider()
        SFTPTransferListRow(
            transfer: sample("site-backup.tar.zst", .upload,
                             total: 3_221_225_472, done: 1_095_216_660, state: .paused),
            isSelected: false)
        Divider()
        SFTPTransferListRow(
            transfer: sample("old-logs.tar", .download,
                             total: 0, done: 0, state: .failed("Permission denied")),
            isSelected: false)
    }
    .frame(width: 248)
}
#endif
