import SwiftUI
import AppKit
import GoelCore

/// The transfer panel's right-hand side: progress arc and state, the throughput graph with
/// Now / Average / Peak / ETA (or Took), the route From → To, and the facts — server, login,
/// system or disk, the speed limit in force, any resumed bytes and the start time.
struct SFTPTransferInspector: View {
    let transfer: SFTPTransfer
    let connection: SFTPConnection
    let volumeSpace: SFTPVolumeSpace?
    let history: [Double]

    @EnvironmentObject private var vm: AppViewModel
    /// Re-read every sampler tick so elapsed and average advance without their own timer.
    private var now: Date { Date() }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Studio.Space.xl) {
                        leftColumn.frame(minWidth: 300, maxWidth: .infinity)
                        rightColumn.frame(width: 300)
                    }
                    VStack(alignment: .leading, spacing: Studio.Space.ml) {
                        leftColumn
                        rightColumn
                    }
                }
                .padding(.horizontal, Studio.Space.l)
                .padding(.vertical, Studio.Space.ml)
            }
            // The actions stay in view however far the facts scroll (`.actbar`).
            actions
                .padding(.horizontal, Studio.Space.l)
                .padding(.vertical, Studio.Space.s)
                .background(Studio.Palette.well)
                .overlay(alignment: .top) { StudioDivider() }
        }
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: Studio.Space.m) {
            hero
            progress
            if let failure = transfer.failureMessage {
                StudioNote(tone: .bad, symbol: "exclamationmark.triangle.fill", message: failure)
                    .accessibilityLabel(L10n.t("Failed, %@", failure))
            }
            telemetry
        }
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: Studio.Space.m) {
            route
            StudioDivider()
            facts
        }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(spacing: Studio.Space.m) {
            // A folder before its walk finishes, and any file the server gave no size for,
            // have no honest percentage — the arc spins instead of showing a stuck 0%.
            StudioProgressArc(fraction: transfer.total > 0 ? transfer.fraction : (transfer.isActive ? nil : 0),
                              tone: transfer.progressTone, diameter: 50)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Studio.Space.xs) {
                FileNameText(transfer.name, lineLimit: 1)
                    .studioFont(.headline)
                    .foregroundStyle(Studio.Palette.ink)
                HStack(spacing: Studio.Space.s) {
                    StudioPill(transfer.stateLabel, tone: transfer.studioTone)
                        .accessibilityHidden(true)
                    if transfer.isDirectory {
                        Text(L10n.t("Folder · up to %d streams", AppViewModel.maxParallelUploads))
                            .studioFont(.small)
                            .foregroundStyle(Studio.Palette.ink3)
                    } else if transfer.total > 0 {
                        Text(transfer.total.byteString)
                            .studioFont(.mono)
                            .foregroundStyle(Studio.Palette.ink3)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .a11yGroup(label: A11y.sentence(L10n.t(transfer.activityLabel), transfer.name),
                   value: A11y.sentence(transfer.stateLabel, A11y.percent(transfer.fraction)))
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: Studio.Space.xs) {
            StudioLinearProgress(fraction: transfer.fraction, tone: transfer.progressTone)
            HStack {
                Text(transfer.sizeLabel)
                Spacer()
                if let remaining = transfer.remainingBytes {
                    Text(L10n.t("%@ left", remaining.byteString))
                }
            }
            .studioFont(.monoSmall)
            .foregroundStyle(Studio.Palette.ink3)
        }
        .a11yGroup(label: L10n.t("Transfer progress"),
                   value: L10n.t("%1$@ of %2$@", A11y.bytes(transfer.bytes), A11y.bytes(transfer.total)))
    }

    // MARK: - Telemetry

    private var telemetry: some View {
        VStack(alignment: .leading, spacing: Studio.Space.s) {
            HStack {
                Text(L10n.t("Throughput"))
                    .studioFont(.eyebrow)
                    .foregroundStyle(Studio.Palette.ink3)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if history.count > 1 {
                    Text(L10n.t("last %ds", history.count))
                        .studioFont(.monoSmall)
                        .foregroundStyle(Studio.Palette.ink3)
                }
            }
            graph
            readings
        }
    }

    @ViewBuilder
    private var graph: some View {
        if history.count > 2 {
            StudioSparkline(values: history, gridLines: 1, showsEndDot: transfer.isActive,
                            color: transfer.studioDirectionColor,
                            accessibilityLabel: L10n.t("Throughput graph, last %d seconds", history.count))
                .frame(height: 56)
                .accessibilityValue(A11y.sentence(A11y.speed(transfer.displaySpeed),
                                                  L10n.t("peak %@", A11y.speed(transfer.peakSpeed))))
                .accessibilityAddTraits(.updatesFrequently)
        } else {
            // Two samples draw no line; the placeholder keeps the readings from jumping on the second tick.
            RoundedRectangle(cornerRadius: Studio.Radius.small, style: .continuous)
                .fill(Studio.Palette.well)
                .frame(height: 56)
                .overlay(
                    Text(transfer.isActive ? L10n.t("Measuring…") : L10n.t("No throughput recorded"))
                        .studioFont(.small)
                        .foregroundStyle(Studio.Palette.ink3))
                .a11yDecorative()
        }
    }

    private var readings: some View {
        HStack(spacing: Studio.Space.s) {
            reading(L10n.t("Now"), transfer.displaySpeed.speedString,
                    highlight: transfer.displaySpeed > 0, spoken: A11y.speed(transfer.displaySpeed))
            reading(L10n.t("Average"), transfer.averageSpeed(at: now).speedString,
                    spoken: A11y.speed(transfer.averageSpeed(at: now)))
            reading(L10n.t("Peak"), transfer.peakSpeed.speedString, spoken: A11y.speed(transfer.peakSpeed))
            reading(transfer.isActive ? L10n.t("ETA") : L10n.t("Took"),
                    transfer.isActive ? (transfer.etaLabel ?? "—") : (elapsedLabel ?? "—"),
                    spoken: transfer.isActive ? (A11y.eta(transfer.etaSeconds) ?? "—") : (elapsedLabel ?? "—"))
        }
    }

    private func reading(_ label: String, _ value: String, highlight: Bool = false, spoken: String) -> some View {
        VStack(spacing: Studio.Space.hair) {
            Text(value)
                .studioFont(Studio.TextStyle.mono.weight(700))
                .foregroundStyle(highlight ? transfer.studioDirectionColor : Studio.Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label)
                .studioFont(.tiny)
                .foregroundStyle(Studio.Palette.ink3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Studio.Space.xs)
        .background(Studio.Palette.well, in: RoundedRectangle(cornerRadius: Studio.Radius.small, style: .continuous))
        .a11yGroup(label: label, value: spoken)
    }

    private var elapsedLabel: String? {
        transfer.elapsed(at: now).map { DownloadTask.etaString($0) }
    }

    // MARK: - Route

    /// Source always on the left, destination on the right, so the arrow between them reads
    /// in the direction the bytes actually travel — including for a remote copy, where both
    /// ends live on the server and there is no local path at all.
    private var route: some View {
        Grid(alignment: .leading, horizontalSpacing: Studio.Space.m, verticalSpacing: 7) {
            routeRow(L10n.t("From · %@", sourcePlace), sourcePath)
            routeRow(L10n.t("To · %@", destinationPlace), destinationPath)
        }
    }

    private func routeRow(_ title: String, _ path: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title)
                .studioFont(.callout.weight(400))
                .foregroundStyle(Studio.Palette.ink3)
                .lineLimit(1)
                .fixedSize()
            Text(path)
                .studioFont(.mono)
                .foregroundStyle(Studio.Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .a11yGroup(label: title, value: path)
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
        transfer.direction == .download ? (transfer.localURL?.path ?? L10n.t("Unknown")) : transfer.remotePath
    }

    // MARK: - Facts

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: Studio.Space.m, verticalSpacing: 7) {
            factRow(L10n.t("Server"), serverValue)
            factRow(L10n.t("Login"),
                    L10n.t("%1$@ · %2$@", connection.credentialKey, SFTPAuthLabel.label(for: connection)))
            if let os = vm.serverMeta[connection.id]?.os {
                factRow(L10n.t("System"), A11y.sentence(os.label, volumeLabel))
            } else if let volumeLabel {
                factRow(L10n.t("Disk"), volumeLabel)
            }
            factRow(L10n.t("Limit"), limitLabel)
            if transfer.resumedFrom > 0 {
                factRow(L10n.t("Resumed"),
                        L10n.t("%@ was already there and wasn’t sent again", transfer.resumedFrom.byteString))
            }
            if let started = transfer.startedAt {
                factRow(L10n.t("Started"), started.formatted(date: .omitted, time: .standard))
            }
        }
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .studioFont(.callout.weight(400))
                .foregroundStyle(Studio.Palette.ink3)
                .fixedSize()
            Text(value)
                .studioFont(.callout.weight(550))
                .foregroundStyle(Studio.Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .a11yGroup(label: label, value: value)
    }

    private var serverValue: String {
        let meta = vm.serverMeta[connection.id]
        let reach = L10n.t(meta?.reachability.help ?? ServerReachability.unknown.help)
        guard let latency = meta?.latencyMS else { return L10n.t("%1$@ · %2$@", connection.label, reach) }
        return L10n.t("%1$@ · %2$@ · %3$d ms", connection.label, reach, latency)
    }

    private var volumeLabel: String? {
        guard let volumeSpace, volumeSpace.totalBytes > 0 else { return nil }
        return L10n.t("%@ free", volumeSpace.freeBytes.byteString)
    }

    /// Names the cap that is actually throttling *this* direction, so a slow upload under a
    /// download-only limit doesn't read as if the limit were to blame.
    private var limitLabel: String {
        let profile = vm.settings.effectiveProfile
        let cap = transfer.direction == .download ? profile.maxDownloadBytesPerSec : profile.maxUploadBytesPerSec
        guard cap > 0 else { return L10n.t("No speed limit") }
        return L10n.t("Capped at %@", Double(cap).speedString)
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: Studio.Space.xs) {
            if transfer.canPause {
                Button(L10n.t("Pause"), systemImage: "pause.fill") { vm.pauseSFTPTransfer(transfer.id) }
                    .buttonStyle(.studio(.secondary, size: .small))
                    .a11yButton(L10n.t("Pause transfer of %@", transfer.name))
            }
            if transfer.canResume {
                Button(L10n.t("Resume"), systemImage: "play.fill") { vm.resumeSFTPTransfer(transfer.id) }
                    .buttonStyle(.studio(.primary, size: .small))
                    .a11yButton(L10n.t("Resume transfer of %@", transfer.name))
            }
            if !transfer.isActive, !transfer.isPaused, transfer.state != .finished {
                Button(L10n.t("Retry"), systemImage: "arrow.clockwise") { vm.retrySFTPTransfer(transfer.id) }
                    .buttonStyle(.studio(.soft, size: .small))
                    .a11yButton(L10n.t("Retry transfer of %@", transfer.name))
            }
            Button(L10n.t("Show Remote Folder")) { vm.revealSFTPTransfer(transfer) }
                .buttonStyle(.studio(.ghost, size: .small))
                .a11yButton(L10n.t("Show the remote folder for %@", transfer.name))
            if let localURL = transfer.localURL, transfer.state == .finished {
                Button(L10n.t("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([localURL]) }
                    .buttonStyle(.studio(.ghost, size: .small))
                    .a11yButton(L10n.t("Show %@ in Finder", transfer.name))
            }
            moreMenu
            Spacer(minLength: 0)
            if transfer.isActive || transfer.isPaused {
                Button(L10n.t("Cancel"), role: .destructive) { vm.requestCancelSFTPTransfer(transfer.id) }
                    .buttonStyle(.studio(.destructive, size: .small))
                    .a11yButton(L10n.t("Cancel transfer of %@", transfer.name))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var moreMenu: some View {
        Menu {
            Button(L10n.t("Copy Remote Path")) { copy(transfer.remotePath) }
            Button(L10n.t("Copy sftp:// Link")) {
                copy(SFTPBrowserListing.sftpLink(connection, remotePath: transfer.remotePath))
            }
            if let localURL = transfer.localURL {
                Button(L10n.t("Copy Local Path")) { copy(localURL.path) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(StudioFonts.font(.ui, size: 13, weight: 650))
                .foregroundStyle(Studio.Palette.ink2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 26, height: 26)
        .help(L10n.t("More actions"))
        .accessibilityLabel(L10n.t("More actions"))
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        vm.toastSuccess(L10n.t("Copied"))
    }
}
