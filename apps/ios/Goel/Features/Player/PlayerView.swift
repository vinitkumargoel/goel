import AVFoundation
import Foundation
import Observation
import OSLog
import SwiftUI
import UIKit

// MARK: - Player tokens

/// Point values read off the `.player-art`, `.playbtn`, `.scrub`, `.scrubtrack` and `.playable`
/// rules in `visual.html`'s player frame.
///
/// `Theme.Metric` owns everything shared — the 6 pt track and the 13 pt knob are already there,
/// and they are used from there. These are the values only this screen needs, kept in one
/// namespace so the frame stays diffable against the mockup, exactly as `DetailMetric` is.
enum PlayerMetric {

    // .player-art { height: 232px }
    static let heroHeight: CGFloat = 232

    // .playbtn { width: 66px; height: 66px; background: rgba(255,255,255,.16) }
    static let playButton: CGFloat = 66
    static let playButtonFillOpacity: Double = 0.16
    /// The SVG triangle is 24 × 26 inside the 66 pt button.
    static let playGlyph: CGFloat = 24

    // .scrub { padding: 18px 20px 0 }
    static let scrubTopPadding: CGFloat = 18
    static let scrubGutter: CGFloat = 20
    // .scrub-t { margin-top: 8px }
    static let timeRowSpacing: CGFloat = 8
    // .scrubtrack .buffered { background: rgba(255,255,255,.26) }
    static let bufferedTrackOpacity: Double = 0.26
    /// How much the knob swells under the finger.
    static let knobDragScale: CGFloat = 1.25
    static let knobResponse: Double = 0.12
    /// Timecodes shrink rather than truncate at large content sizes.
    static let timecodeMinimumScale: CGFloat = 0.75

    // .playable { margin: 16px 20px 0; padding: 10px 12px; border-radius: 11px; gap: 8px }
    static let bannerTopSpacing: CGFloat = 16
    static let bannerVerticalPadding: CGFloat = 10
    static let bannerHorizontalPadding: CGFloat = 12
    static let bannerRadius: CGFloat = 11
    static let bannerSpacing: CGFloat = 8
    /// `.playable { background: rgba(255,107,44,.13) }` — ember, 13 %.
    static let bannerGroundOpacity: Double = 0.13
    /// `.playable { color: #FFB68C }`. That is `emberBright` (#FF8A4C) lifted 38 % toward white in
    /// device RGB, which lands on #FFB690 — so the mockup's value is *derived* from the token
    /// rather than pasted next to it, and it still re-tones with the appearance.
    static let bannerTextLift: Double = 0.38
    /// The star SVG is 15 × 15.
    static let bannerGlyph: CGFloat = 15

    // .card { margin-top: 18px }
    static let cardTopSpacing: CGFloat = 18

    // .navbar { padding: 4px 16px 2px }  .nav-act svg 20 × 20
    static let navTopPadding: CGFloat = 4
    static let navBottomPadding: CGFloat = 2
    static let navGlyph: CGFloat = 20

    // MARK: Behaviour

    /// Seconds an accessibility increment moves the playhead.
    static let accessibilityStep: TimeInterval = 15
    /// How often the playhead is sampled. 5 Hz is smooth for a 6 pt bar and cheap.
    static let tick: TimeInterval = 0.2
    /// How long the asset gets to become playable before the UI says it cannot be opened. A
    /// faststart file opens in well under a second from local disk; anything past this is either a
    /// `moov`-at-the-end file or a container AVFoundation will not take.
    static let openTimeout: TimeInterval = 8
    /// Bytes that must be on disk before it is even worth handing the file to AVFoundation.
    static let minimumStartBytes: Int64 = 64 * 1024
    /// Spacing inside the fault plate drawn over the poster.
    static let faultSpacing: CGFloat = 8
    static let faultGlyph: CGFloat = 26
}

/// Type this screen alone needs, expressed against ``Theme/Typo/Size`` wherever one exists.
enum PlayerTypo {
    /// `.playable { font-size: 12.5px }` — the same 12.5 pt as a queue row subtitle.
    static let banner = Font.system(size: Theme.Typo.Size.rowSubtitle, weight: .regular)
    /// The fault plate's headline, at the detail screen's card-title weight.
    static let faultTitle = Font.system(size: Theme.Typo.Size.rowTitle, weight: .semibold)
}

/// Scene colour that belongs to this frame and nowhere else: `.player-art`'s poster gradient,
/// which stands in for the video before the first frame decodes.
///
/// It is not in ``Theme`` because it is art, not a token — no other surface may use it. If a
/// second screen ever needs it, promote it rather than copying it.
enum PlayerArt {
    /// `linear-gradient(150deg, #2A1B14, #12222B 65%, #0A0A0C)`.
    static let poster = LinearGradient(
        stops: [
            .init(color: Color(red: 0x2A / 255, green: 0x1B / 255, blue: 0x14 / 255), location: 0),
            .init(color: Color(red: 0x12 / 255, green: 0x22 / 255, blue: 0x2B / 255), location: 0.65),
            .init(color: Color(red: 0x0A / 255, green: 0x0A / 255, blue: 0x0C / 255), location: 1),
        ],
        // 150° in CSS runs top-left-ish to bottom-right-ish.
        startPoint: .topLeading,
        endPoint: .bottom
    )
}

// MARK: - PlaybackModel

/// Owns the `AVPlayer`, the resource loader, and everything that can go wrong between "there is a
/// partial file" and "there is a moving picture".
///
/// Kept out of the view so the failure states are explicit values rather than the absence of a
/// frame. The one thing this screen must never do is spin forever: every path either reaches
/// `isReady`, or sets a ``Fault`` that says *specifically* what is wrong.
@MainActor
@Observable
final class PlaybackModel {

    /// Why there is no picture. Each case has a message a person can act on.
    enum Fault: Equatable {
        /// Nothing has been written to disk under this download's name.
        case missingFile
        /// The container keeps its index at the end of the file. Not our bug, and not fixable
        /// from here — but the user should be told which it is.
        case notProgressive
        /// AVFoundation refused the asset outright.
        case failed(String)

        var headline: String {
            switch self {
            case .missingFile: "Nothing on disk yet"
            case .notProgressive: "Not playable until it finishes"
            case .failed: "Could not open this file"
            }
        }

        var detail: String {
            switch self {
            case .missingFile:
                "No bytes have been written for this download yet."
            case .notProgressive:
                "This file keeps its index at the end, so a partial copy has nothing to play. "
                    + "Re-encode with faststart to make it playable while it downloads."
            case let .failed(message):
                message
            }
        }
    }

    private(set) var player: AVPlayer?
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var fault: Fault?
    private(set) var isReady = false

    private var loader: PartialFileResourceLoader?
    private var timeObserver: Any?
    private var readinessTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private let log = Logger(subsystem: GoelIdentifiers.logSubsystem, category: "player")

    nonisolated init() {}

    /// True while the player is legitimately waiting for the first usable bytes — not an error,
    /// just the first second of a transfer.
    var isWaitingForBytes: Bool { player == nil && fault == nil }

    // MARK: Lifecycle

    /// Idempotent. Safe to call from `onAppear` and again from every progress tick.
    func prepare(for download: Download) {
        guard player == nil, fault == nil else { return }

        let store = FileStore()
        guard let destination = try? store.destinationURL(
            filename: download.filename,
            subdirectory: download.saveDirectory
        ) else {
            fault = .missingFile
            return
        }

        let part = store.partURL(for: destination)
        let manager = FileManager.default
        let isComplete = manager.fileExists(atPath: destination.path)
        let source = isComplete ? destination : part

        guard isComplete || manager.fileExists(atPath: part.path) else {
            // Not a fault yet: the engine may simply not have opened the file. Only a download
            // that has genuinely finished with nothing on disk is broken.
            if download.status.isTerminal { fault = .missingFile }
            return
        }

        let writeHead = Self.writeHead(of: download, isComplete: isComplete)
        guard isComplete || writeHead >= PlayerMetric.minimumStartBytes else { return }

        // A `moov` behind `mdat` cannot be played from a prefix. Say which, rather than spinning.
        if !isComplete,
           let head = Self.readHead(of: source, limit: min(Int(writeHead), MediaContainer.probeBytes)),
           MediaContainer.inspect(head, fileLength: download.totalBytes) == .moovAtEnd {
            fault = .notProgressive
            return
        }

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let asset: AVURLAsset
        if isComplete {
            asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        } else {
            guard let url = PartialFileResourceLoader.playbackURL(for: download.id, filename: download.filename) else {
                fault = .failed("The player could not address this file.")
                return
            }
            let loader = PartialFileResourceLoader(
                fileURL: source,
                contentType: MediaContainer.contentType(forFilename: download.filename),
                window: PartialFileWindow(writeHead: writeHead, totalBytes: download.totalBytes)
            )
            let partial = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            partial.resourceLoader.setDelegate(loader, queue: loader.deliveryQueue)
            self.loader = loader
            asset = partial
        }

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        // Load-bearing, and counter-intuitive. Left at its default of `true`, `AVPlayer` looks at a
        // 60-second asset with 23 % of its bytes on disk, concludes it cannot play through without
        // stalling, and sits in `waitingToPlayAtSpecifiedRate` forever with the rate already at 1.
        // That is precisely the judgement this screen exists to overrule: the whole premise is that
        // 23 % is enough to start. Verified against `Scripts/ios/fixtures/sample-video.mp4` — with
        // this `true` the playhead never leaves 0:00; with it `false` it advances immediately.
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player

        observe(player)
        loadDuration(of: asset)
        startWatchdog()
    }

    /// The download moved. Widen the loader's window, and pick playback back up if a stall was
    /// waiting on exactly these bytes.
    func advance(_ download: Download) {
        let isComplete = download.status == .completed
        loader?.advance(
            writeHead: Self.writeHead(of: download, isComplete: isComplete),
            totalBytes: download.totalBytes
        )
        if player == nil { prepare(for: download) }
        // With stall-minimisation off, running out of bytes drops the rate to zero rather than
        // parking in `waitingToPlayAtSpecifiedRate`. Either way the cure is the same: the bytes
        // that were missing have just landed, so ask for the rate back.
        if isPlaying, player?.timeControlStatus != .playing {
            player?.play()
        }
    }

    func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .paused {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    func seek(to seconds: TimeInterval) {
        guard let player, seconds.isFinite else { return }
        position = max(0, seconds)
        player.seek(
            to: CMTime(seconds: position, preferredTimescale: Self.timescale),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func teardown() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        readinessTask?.cancel()
        readinessTask = nil
        watchdog?.cancel()
        watchdog = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        loader?.invalidate()
        loader = nil
        isPlaying = false
        isReady = false
    }

    // MARK: Observation

    private func observe(_ player: AVPlayer) {
        let interval = CMTime(seconds: PlayerMetric.tick, preferredTimescale: Self.timescale)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.position = max(0, seconds) }
                self.isPlaying = self.player?.timeControlStatus == .playing
                if self.duration <= 0,
                   let itemDuration = self.player?.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                    self.isReady = true
                }
                if let error = self.player?.currentItem?.error, self.fault == nil {
                    self.fault = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func loadDuration(of asset: AVURLAsset) {
        readinessTask = Task { [weak self] in
            do {
                let loaded = try await asset.load(.duration)
                guard let self, !Task.isCancelled else { return }
                let seconds = loaded.seconds
                if seconds.isFinite, seconds > 0 { self.duration = seconds }
                self.isReady = true
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.log.error("Asset duration load failed: \(error.localizedDescription, privacy: .public)")
                if self.fault == nil { self.fault = .failed(error.localizedDescription) }
            }
        }
    }

    /// The promise this screen makes: it will not spin forever. If the asset has not become
    /// playable inside the timeout, the most likely cause by a wide margin is an index at the end
    /// of the file, and that is what the UI says.
    private func startWatchdog() {
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(PlayerMetric.openTimeout))
            guard let self, !Task.isCancelled, !self.isReady, self.fault == nil else { return }
            self.fault = .notProgressive
        }
    }

    // MARK: Helpers

    private static let timescale: CMTimeScale = 600

    /// A completed download's whole file is readable; an in-flight one only up to the contiguous
    /// prefix, which is the *only* run of bytes guaranteed to have no holes in it.
    private static func writeHead(of download: Download, isComplete: Bool) -> Int64 {
        if isComplete { return download.totalBytes ?? download.receivedBytes }
        return download.contiguousPrefix
    }

    private static func readHead(of url: URL, limit: Int) -> Data? {
        guard limit > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: limit)
    }
}

// MARK: - PlayerSurface

/// `AVPlayerLayer` in a `UIView`, because `VideoPlayer` brings the system transport controls with
/// it and those cannot draw the three-state scrubber this screen exists to show.
private struct PlayerSurface: UIViewRepresentable {

    let player: AVPlayer?

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .clear
        view.playerLayer?.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        guard let layer = view.playerLayer, layer.player !== player else { return }
        layer.player = player
    }
}

/// A view whose backing layer *is* the player layer, so there is no second layer to keep in sync
/// with the view's bounds.
final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
}

// MARK: - PlayerView

/// Value at 23 %, not at 100 % — PRD §6.3's signature moment.
///
/// Everything on this screen is derived from the one `Download` in the store. The scrubber's
/// buffered edge is `contiguousPrefix / totalBytes`; the buffer lead is that same watermark
/// expressed in minutes of media, which is the number a person can actually act on; the banner is
/// the download's own percentage and speed. A progress tick from the engine repaints all four.
public struct PlayerView: View {

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private let downloadID: UUID
    @State private var model = PlaybackModel()

    public init(downloadID: UUID) {
        self.downloadID = downloadID
    }

    public var body: some View {
        Group {
            if let download = app.store[downloadID] {
                content(for: download)
            } else {
                unavailable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Color.ground)
    }

    // MARK: Content

    private func content(for download: Download) -> some View {
        VStack(spacing: 0) {
            navigationBar
            hero(for: download)

            VStack(spacing: 0) {
                BufferScrubber(
                    duration: model.duration,
                    position: model.position,
                    bufferedFraction: bufferedFraction(for: download),
                    isEnabled: model.player != nil && model.duration > 0,
                    onSeek: model.seek
                )
                banner(for: download)
                    .padding(.top, PlayerMetric.bannerTopSpacing)
            }
            // `.scrub { padding-top: 18px }` puts the *track* 18 pt below the video. The scrubber's
            // box is knob-height and centres the track inside it, so the knob's overhang comes off
            // the top padding — otherwise the bar sits 3.5 pt lower than the mockup's.
            .padding(.top, PlayerMetric.scrubTopPadding
                - (Theme.Metric.scrubberKnob - Theme.Metric.scrubberTrack) / 2)
            .padding(.horizontal, PlayerMetric.scrubGutter)

            statsCard(for: download)
                .padding(.top, PlayerMetric.cardTopSpacing)
                .padding(.horizontal, Theme.Metric.gutter)

            Spacer(minLength: 0)
        }
        .onAppear { model.prepare(for: download) }
        .onDisappear { model.teardown() }
        .onChange(of: download.contiguousPrefix) { _, _ in model.advance(download) }
        .onChange(of: download.status) { _, _ in model.advance(download) }
    }

    private var navigationBar: some View {
        HStack {
            Button(action: close) {
                Image(systemName: "chevron.down")
                    .font(.system(size: PlayerMetric.navGlyph, weight: .semibold))
                    .foregroundStyle(Theme.Color.ember)
                    .frame(width: Theme.Metric.minHitTarget, height: Theme.Metric.minHitTarget)
                    // Lay out at the mockup's 20 pt while still hit-testing at 44 pt.
                    .padding(.vertical, -(Theme.Metric.minHitTarget - PlayerMetric.navGlyph) / 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close player")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metric.gutter)
        .padding(.top, PlayerMetric.navTopPadding)
        .padding(.bottom, PlayerMetric.navBottomPadding)
    }

    private func hero(for download: Download) -> some View {
        ZStack {
            PlayerArt.poster
            PlayerSurface(player: model.player)
            if let fault = model.fault {
                faultPlate(fault)
            } else if model.isWaitingForBytes {
                waiting(for: download)
            } else {
                playButton
            }
        }
        .frame(height: PlayerMetric.heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(download.filename)
    }

    /// 66 pt glass disc. `.white` rather than a label token on purpose — it sits on video, which is
    /// dark in either appearance, so it must not invert with the interface style.
    private var playButton: some View {
        Button(action: model.togglePlay) {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Circle().fill(.white.opacity(PlayerMetric.playButtonFillOpacity))
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: PlayerMetric.playGlyph, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: PlayerMetric.playButton, height: PlayerMetric.playButton)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
    }

    /// Before the first usable bytes. A spinner is only honest while bytes are actually moving —
    /// a paused transfer spinning forever is the exact failure this screen promises not to have.
    @ViewBuilder
    private func waiting(for download: Download) -> some View {
        if download.status.isActive || download.status == .queued {
            ProgressView()
                .tint(.white)
                .accessibilityLabel("Waiting for the first bytes of \(download.filename)")
        } else {
            VStack(spacing: PlayerMetric.faultSpacing) {
                Text("Not enough downloaded to play")
                    .font(PlayerTypo.faultTitle)
                    .foregroundStyle(.white)
                Text("\(download.status.displayName) at \(Fmt.percent(download.fractionComplete)). "
                    + "Resume the download to start watching.")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(.white.opacity(PlayerMetric.bufferedTrackOpacity * 2))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, PlayerMetric.scrubGutter)
            .accessibilityElement(children: .combine)
        }
    }

    private func faultPlate(_ fault: PlaybackModel.Fault) -> some View {
        VStack(spacing: PlayerMetric.faultSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: PlayerMetric.faultGlyph))
                .foregroundStyle(Theme.Color.warning)
            Text(fault.headline)
                .font(PlayerTypo.faultTitle)
                .foregroundStyle(.white)
            Text(fault.detail)
                .font(Theme.Typo.caption)
                .foregroundStyle(.white.opacity(PlayerMetric.bufferedTrackOpacity * 2))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, PlayerMetric.scrubGutter)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(fault.headline). \(fault.detail)")
    }

    // MARK: Banner

    /// `.playable` — "Playing at 23% — still downloading at 48.2 MB/s" on a 13 % ember ground.
    private func banner(for download: Download) -> some View {
        HStack(spacing: PlayerMetric.bannerSpacing) {
            Image(systemName: "star.fill")
                .font(.system(size: PlayerMetric.bannerGlyph))
                .foregroundStyle(Theme.Color.ember)
            Text(bannerText(for: download))
                .font(PlayerTypo.banner)
                .foregroundStyle(Theme.Color.emberBright.mix(with: .white, by: PlayerMetric.bannerTextLift, in: .device))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, PlayerMetric.bannerVerticalPadding)
        .padding(.horizontal, PlayerMetric.bannerHorizontalPadding)
        .background(
            RoundedRectangle(cornerRadius: PlayerMetric.bannerRadius, style: .continuous)
                .fill(Theme.Color.ember.opacity(PlayerMetric.bannerGroundOpacity))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bannerText(for: download))
    }

    /// Assembled from ``Fmt`` so the percentage and the rate read identically to every other
    /// surface in the app. Never a literal.
    private func bannerText(for download: Download) -> String {
        let percent = Fmt.percent(download.fractionComplete)
        switch download.status {
        case .completed:
            return "Playing the complete file" + Self.dash + Fmt.bytes(download.totalBytes)
        case .downloading, .probing, .verifying:
            return "Playing at \(percent)" + Self.dash + "still downloading at \(Fmt.speed(download.currentSpeed))"
        default:
            return "Playing at \(percent)" + Self.dash + download.status.displayName.lowercased()
        }
    }

    /// U+2014 EM DASH with hair space either side, as the mockup sets it.
    private static let dash = " \u{2014} "

    // MARK: Stats

    /// The one number a person can act on. Bytes ahead of the playhead mean nothing; *minutes*
    /// ahead of the playhead mean "you can put the phone in your pocket".
    private func statsCard(for download: Download) -> some View {
        let lead = bufferLeadSeconds(for: download)
        let mode = download.isSequential ? "Sequential" : "Parallel"
        return DetailCard(title: "Downloaded ahead of playhead") {
            Grid(
                alignment: .leading,
                horizontalSpacing: DetailMetric.statColumnSpacing,
                verticalSpacing: DetailMetric.statRowSpacing
            ) {
                GridRow {
                    stat(
                        "Buffer",
                        ScrubMath.leadLabel(lead),
                        tint: lead == nil ? Theme.Color.label2 : Theme.Color.success,
                        // The "still downloading" fact cannot live only in the ember banner —
                        // a banner is a colour and a glyph, and neither is spoken.
                        spokenValue: bufferSpokenValue(for: download, lead: lead)
                    )
                    stat(
                        "Mode",
                        mode,
                        spokenValue: download.isSequential
                            ? "Sequential. Bytes land in order, so the file plays while it transfers."
                            : "Parallel. The file has holes in it and cannot be played until it completes."
                    )
                }
            }
        }
    }

    private func bufferSpokenValue(for download: Download, lead: TimeInterval?) -> String {
        let ahead = lead == nil
            ? "Buffer ahead is not known yet"
            : "\(ScrubMath.leadLabel(lead)) of video ahead of the playhead"
        guard download.status.isActive else { return ahead + ". \(download.status.displayName)." }
        return ahead + ". Still downloading at \(Fmt.speed(download.currentSpeed))."
    }

    /// `.stat` — a 10.5 pt tracked uppercase key over a 16 pt tabular value.
    private func stat(
        _ label: String,
        _ value: String,
        tint: Color = Theme.Color.label1,
        spokenValue: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: DetailMetric.statLabelSpacing) {
            Text(label.uppercased())
                .font(Theme.Typo.statLabel)
                .tracking(Theme.Typo.statTracking)
                .foregroundStyle(Theme.Color.label3)
            Text(value)
                .font(Theme.Typo.statValue)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(PlayerMetric.timecodeMinimumScale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spokenValue ?? value)
    }

    // MARK: Empty

    private var unavailable: some View {
        VStack(spacing: PlayerMetric.faultSpacing) {
            Text("This download is no longer in the queue")
                .font(PlayerTypo.faultTitle)
                .foregroundStyle(Theme.Color.label1)
            Button("Close", action: close)
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.Color.ember)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Derived

    private func bufferedFraction(for download: Download) -> Double {
        ScrubMath.bufferedFraction(
            contiguousPrefix: download.contiguousPrefix,
            totalBytes: download.totalBytes
        )
    }

    private func bufferLeadSeconds(for download: Download) -> TimeInterval? {
        ScrubMath.bufferLeadSeconds(
            contiguousPrefix: download.contiguousPrefix,
            playheadBytes: ScrubMath.playheadBytes(
                position: model.position,
                duration: model.duration,
                totalBytes: download.totalBytes
            ),
            totalBytes: download.totalBytes,
            duration: model.duration
        )
    }

    private func close() {
        if app.playerID == downloadID { app.playerID = nil }
        dismiss()
    }
}

// MARK: - Previews

#Preview("Playing at 23%") {
    let sample = PreviewTransferEngine.fixtures().first { $0.isSequential }
        ?? PreviewTransferEngine.fixtures()[0]
    let store = DownloadStore(persistenceURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("goel-player-preview.json"))
    store.replaceAll([sample])
    let model = AppModel(engine: PreviewTransferEngine.makeStatic(), store: store)
    return PlayerView(downloadID: sample.id)
        .environment(model)
        .preferredColorScheme(.dark)
}
