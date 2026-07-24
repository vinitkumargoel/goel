import ActivityKit
import Foundation
import UserNotifications
import os

/// Owns the app's single Live Activity — PRD §6.5.
///
/// Four rules govern everything below, and each of them exists because the obvious
/// implementation gets it wrong:
///
/// 1. **One activity, never one per download.** More than one active transfer collapses to a
///    single aggregate activity ("3 downloads · 62%") published under
///    ``DownloadActivityAttributes/aggregateID``, and expands back to a per-file activity when
///    one remains. iOS caps concurrent activities anyway; a queue of eight would simply lose.
/// 2. **Update on a clock, not on bytes.** At most one update every ``minimumUpdateInterval``
///    while foregrounded. Progress arrives several times a second per transfer; forwarding that
///    to ActivityKit gets the app rate-limited and the activity frozen — the exact failure the
///    stale branch exists to survive. Background `URLSession` delegate wakes bypass the throttle
///    via ``backgroundWake(_:)``, because those are rare and are the only execution time we get.
/// 3. **Publish a `staleDate`.** Every content is published with `staleDate` ≈
///    ``staleAfter`` seconds out, so when the app is suspended the system flips the activity into
///    the degraded presentation by itself instead of leaving a lying percentage on screen.
/// 4. **Expect to be outlived.** ActivityKit allows roughly eight hours of updates and twelve of
///    visibility. A 40 GB download on hotel Wi-Fi will outlast that, so the controller ends the
///    activity itself at ``maxActivityLifetime`` and hands off to a local notification.
///
/// **No push server.** §6.5 rejects one explicitly: disproportionate cost and a privacy surface
/// for a cosmetic gain. Every update here is app-driven.
///
/// ## Wiring
///
/// Two call sites, both outside this file (T13 does not own `AppModel`):
///
/// ```swift
/// // AppModel.apply(_:) and AppModel.start(_:), after the store mutation:
/// ActivityController.shared.sync(store.downloads)
///
/// // The background URLSession delegate wake (T06), which bypasses the throttle:
/// ActivityController.shared.backgroundWake(store.downloads)
/// ```
///
/// Until the first of those lands the activity never starts — everything below is inert but
/// correct, and `sync` is cheap enough to call on every store mutation.
@MainActor
public final class ActivityController {

    /// The app has exactly one Live Activity, so it has exactly one controller.
    public static let shared = ActivityController()

    // MARK: - Tunables

    /// Floor on the interval between foreground updates.
    public static let minimumUpdateInterval: TimeInterval = 2
    /// How long a published state stays trustworthy. After this the system degrades it.
    public static let staleAfter: TimeInterval = 90
    /// ActivityKit stops accepting updates around here. We end first, on our own terms.
    public static let maxActivityLifetime: TimeInterval = 8 * 60 * 60
    /// How long a finished activity lingers on the Lock Screen before the system clears it.
    public static let dismissalDelay: TimeInterval = 8
    /// After `Activity.request()` is rejected (system activity cap, per-app toggle off), how long
    /// to wait before trying again. Without it a rejected request would be re-issued on every
    /// progress tick (~10 Hz), spamming ActivityKit and the log for the life of the download.
    public static let requestRetryCooldown: TimeInterval = 30

    // MARK: - State

    private var activity: Activity<DownloadActivityAttributes>?
    private var currentAttributes: DownloadActivityAttributes?
    private var lastState: DownloadActivityAttributes.ContentState?
    private var startedAt: Date?
    private var lastPublish: Date = .distantPast
    /// When the last `Activity.request()` was rejected, or nil if the last attempt succeeded.
    /// Gates ``restart(attributes:state:)`` so a failing request backs off instead of storming.
    private var lastRequestFailure: Date?
    private var trailingUpdate: Task<Void, Never>?
    private var stateObserver: Task<Void, Never>?

    /// The downloads whose activity was ended because it hit ``maxActivityLifetime``. Each of
    /// these finishes with a local notification rather than a new activity — restarting would just
    /// burn another eight hours and confuse the Lock Screen. Tracked per-download, not as a single
    /// latch, so a genuinely new transfer added after an expiry still gets its own activity instead
    /// of being suppressed until the whole queue drains.
    private var expiredIDs: Set<UUID> = []

    private let log = Logger(subsystem: GoelIdentifiers.logSubsystem, category: "LiveActivity")

    public init() {}

    /// Whether a Live Activity is currently on screen. Read by the debug gallery.
    public var isRunning: Bool { activity != nil }

    // MARK: - Entry points

    /// The single funnel. Call it whenever the queue changes; it decides everything else.
    ///
    /// Starting is deliberately un-throttled so the PRD's "visible within 1 s of a download
    /// starting" criterion is met by construction — only *updates* wait for the clock.
    public func sync(_ downloads: [Download]) {
        publish(downloads, force: false)
    }

    /// A background `URLSession` delegate wake. Bypasses the throttle: these are infrequent, and
    /// while suspended they are the only chance we get to tell the truth.
    public func backgroundWake(_ downloads: [Download]) {
        publish(downloads, force: true)
    }

    /// Tears the activity down without a completion state — app teardown, or the user turning
    /// Live Activities off in Settings.
    public func stop() {
        trailingUpdate?.cancel()
        trailingUpdate = nil
        stateObserver?.cancel()
        stateObserver = nil
        guard let activity else { return }
        endActivity(activity, lastState.map { ActivityContent(state: $0, staleDate: nil) }, .immediate)
        clear()
    }

    /// Republishes the current state with a `staleDate` that has **already passed**, so the
    /// system flips straight to the degraded presentation.
    ///
    /// This exists because the stale branch is otherwise unreachable on a simulator — it needs
    /// the app to be genuinely suspended mid-transfer — and it is the state most likely to be
    /// wrong precisely because nobody ever looks at it. See T13's exit criteria.
    public func publishStaleForDebug() {
        guard let activity, let lastState else {
            log.notice("No activity to make stale.")
            return
        }
        let content = ActivityContent(state: lastState, staleDate: Date().addingTimeInterval(-1))
        updateActivity(activity, content)
    }

    // MARK: - Core

    private func publish(_ downloads: [Download], force: Bool) {
        // Degrade silently: the user may have Live Activities off system-wide or for this app,
        // and that is a preference, not an error.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            if activity != nil { stop() }
            return
        }

        let tracked = downloads.filter { !$0.status.isTerminal }

        guard !tracked.isEmpty else {
            finish(downloads)
            return
        }

        // A download that already hit the lifetime ceiling is handed off to a notification and must
        // not spawn a fresh activity (that would just burn another eight hours). Suppress only
        // *those* downloads — a genuinely new transfer added afterward still deserves its own
        // activity, so we publish for whatever is left once the expired ones are removed.
        let fresh = tracked.filter { !expiredIDs.contains($0.id) }
        guard !fresh.isEmpty else { return }

        if let startedAt, Date().timeIntervalSince(startedAt) >= Self.maxActivityLifetime {
            expire(fresh)
            return
        }

        let attributes = makeAttributes(for: fresh)
        let state = makeState(for: fresh)

        // Attributes are immutable for the life of an activity, so crossing the
        // single ⇄ aggregate boundary (or switching which file is the only one left) means
        // ending one activity and requesting another. This is the only place that happens.
        // `DownloadActivityAttributes` is not `Equatable` — `ActivityAttributes` does not require
        // it and that file is a fixed contract — so the two fields are compared by hand.
        guard let activity,
              currentAttributes?.downloadID == attributes.downloadID,
              currentAttributes?.kindToken == attributes.kindToken
        else {
            // Back off after a rejected request (`lastRequestFailure` is cleared on success, so
            // this only bites while there is no activity and requests keep failing). Otherwise a
            // request the system refuses would be retried on every progress tick.
            if let lastRequestFailure,
               Date().timeIntervalSince(lastRequestFailure) < Self.requestRetryCooldown {
                return
            }
            restart(attributes: attributes, state: state)
            return
        }

        update(activity, with: state, force: force)
    }

    private func update(
        _ activity: Activity<DownloadActivityAttributes>,
        with state: DownloadActivityAttributes.ContentState,
        force: Bool
    ) {
        lastState = state
        let elapsed = Date().timeIntervalSince(lastPublish)

        guard force || elapsed >= Self.minimumUpdateInterval else {
            scheduleTrailingUpdate(after: Self.minimumUpdateInterval - elapsed)
            return
        }

        trailingUpdate?.cancel()
        trailingUpdate = nil
        lastPublish = Date()

        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
        updateActivity(activity, content)
    }

    /// Coalesces a burst of progress ticks into one update at the end of the window, so the last
    /// value in a burst is never dropped just because it arrived a few hundred ms too early.
    private func scheduleTrailingUpdate(after delay: TimeInterval) {
        guard trailingUpdate == nil else { return }
        trailingUpdate = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(delay, 0)))
            guard !Task.isCancelled, let self else { return }
            self.trailingUpdate = nil
            guard let activity = self.activity, let state = self.lastState else { return }
            self.update(activity, with: state, force: true)
        }
    }

    private func restart(
        attributes: DownloadActivityAttributes,
        state: DownloadActivityAttributes.ContentState
    ) {
        if let existing = activity {
            let final = lastState ?? state
            endActivity(existing, ActivityContent(state: final, staleDate: nil), .immediate)
            clear()
        }

        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
        do {
            let started = try Activity.request(attributes: attributes, content: content, pushType: nil)
            activity = started
            currentAttributes = attributes
            lastState = state
            startedAt = Date()
            lastPublish = Date()
            lastRequestFailure = nil
            observe(started)
            log.info("Live Activity started for \(attributes.downloadID, privacy: .public)")
        } catch {
            // Almost always `NSSupportsLiveActivities` missing, the per-app toggle being off, or
            // the system activity cap. None of them are worth interrupting a download over — and
            // the timestamp makes the next attempt wait out `requestRetryCooldown`.
            lastRequestFailure = Date()
            log.warning("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Watches for the system ending or dismissing the activity behind our back — the user
    /// swiping it away, or ActivityKit reclaiming it — so we do not keep updating a ghost.
    private func observe(_ activity: Activity<DownloadActivityAttributes>) {
        stateObserver?.cancel()
        stateObserver = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }
                if state == .ended || state == .dismissed {
                    self?.clear()
                    return
                }
            }
        }
    }

    /// Everything finished. Publish the completed state, then let it dismiss itself.
    private func finish(_ downloads: [Download]) {
        trailingUpdate?.cancel()
        trailingUpdate = nil
        stateObserver?.cancel()
        stateObserver = nil

        if !expiredIDs.isEmpty {
            // Those activities are long gone; the notification is the only thing left that can tell
            // the user their multi-hour downloads finished.
            postCompletionNotification(for: downloads)
            expiredIDs.removeAll()
        }

        guard let activity else {
            clear()
            return
        }

        let completed = completedState(for: downloads)
        lastState = completed
        endActivity(
            activity,
            ActivityContent(state: completed, staleDate: nil),
            .after(Date().addingTimeInterval(Self.dismissalDelay))
        )
        clear()
    }

    /// Hit the ActivityKit lifetime ceiling. End cleanly rather than being frozen by the system.
    /// The downloads on the expiring activity are remembered so they hand off to a notification
    /// instead of restarting; anything not in that set can still open a fresh activity.
    private func expire(_ expiring: [Download]) {
        log.notice("Live Activity reached its \(Int(Self.maxActivityLifetime / 3600)) h ceiling; ending and falling back to a notification.")
        expiredIDs.formUnion(expiring.map(\.id))
        if let activity, let lastState {
            endActivity(activity, ActivityContent(state: lastState, staleDate: nil), .immediate)
        }
        clear()
    }

    private func clear() {
        activity = nil
        currentAttributes = nil
        startedAt = nil
    }

    // MARK: - Content

    /// Single transfer → its own id and kind. More than one → the well-known aggregate id, so a
    /// second call can recognise the running activity instead of stacking another one on top.
    private func makeAttributes(for tracked: [Download]) -> DownloadActivityAttributes {
        if tracked.count == 1, let only = tracked.first {
            return DownloadActivityAttributes(downloadID: only.id.uuidString, kindToken: only.kind.token)
        }
        return DownloadActivityAttributes(
            downloadID: DownloadActivityAttributes.aggregateID,
            kindToken: WidgetGlyph.aggregateToken
        )
    }

    private func makeState(for tracked: [Download]) -> DownloadActivityAttributes.ContentState {
        let activeCount = tracked.filter { $0.status.isActive }.count

        if tracked.count == 1, let only = tracked.first {
            return DownloadActivityAttributes.ContentState(
                filename: only.filename,
                receivedBytes: only.receivedBytes,
                totalBytes: only.totalBytes,
                fraction: only.fractionComplete,
                speed: only.currentSpeed,
                eta: only.eta,
                isAggregate: false,
                activeCount: max(activeCount, 1),
                isPaused: only.status == .paused || only.status == .waitingForWiFi,
                updatedAt: Date()
            )
        }

        // Aggregate: weight by bytes, not by row, so one 18 GB file does not read as "one of
        // four" while it dominates the actual wait.
        var received: Int64 = 0
        var total: Int64 = 0
        var knownTotal = false
        for d in tracked {
            received += max(0, d.receivedBytes)
            if let t = d.totalBytes, t > 0 {
                total += t
                knownTotal = true
            }
        }
        let fraction = total > 0 ? Double(received) / Double(total) : 0
        let speed = tracked.reduce(0.0) { $0 + $1.currentSpeed }
        let remaining = tracked.reduce(Int64(0)) { $0 + $1.remainingBytes }
        let eta: TimeInterval? = speed > 0 && remaining > 0 ? Double(remaining) / speed : nil

        return DownloadActivityAttributes.ContentState(
            filename: "",
            receivedBytes: received,
            totalBytes: knownTotal ? total : nil,
            fraction: fraction,
            speed: speed,
            eta: eta,
            isAggregate: true,
            activeCount: max(activeCount, tracked.count),
            isPaused: tracked.allSatisfy { $0.status == .paused || $0.status == .waitingForWiFi },
            updatedAt: Date()
        )
    }

    private func completedState(for downloads: [Download]) -> DownloadActivityAttributes.ContentState {
        let finished = downloads.filter { $0.status == .completed }

        // Nothing in this finishing batch actually completed — it drained by failing. Painting a
        // full/100% "0 downloads" bar would be a lie for up to `dismissalDelay`, so show the real
        // (partial) progress of what failed: an unfinished bar reads as "did not finish", not done.
        guard !finished.isEmpty else {
            let failed = downloads.filter { $0.status == .failed }
            let received = failed.reduce(Int64(0)) { $0 + $1.receivedBytes }
            let total = failed.reduce(Int64(0)) { $0 + ($1.totalBytes ?? $1.receivedBytes) }
            return DownloadActivityAttributes.ContentState(
                filename: failed.count == 1 ? (failed.first?.filename ?? "") : "",
                receivedBytes: received,
                totalBytes: total > 0 ? total : nil,
                fraction: total > 0 ? Double(received) / Double(total) : 0,
                speed: 0,
                eta: nil,
                isAggregate: failed.count != 1,
                activeCount: failed.count,
                isPaused: false,
                updatedAt: Date()
            )
        }

        let bytes = finished.reduce(Int64(0)) { $0 + $1.receivedBytes }
        return DownloadActivityAttributes.ContentState(
            filename: finished.count == 1 ? (finished.first?.filename ?? "") : "",
            receivedBytes: bytes,
            totalBytes: bytes,
            fraction: 1,
            speed: 0,
            eta: nil,
            isAggregate: finished.count != 1,
            activeCount: 0,
            isPaused: false,
            updatedAt: Date()
        )
    }

    // MARK: - Expiry fallback

    /// The consolation prize for a transfer that outlived its activity.
    ///
    /// Authorization is never *requested* here — that belongs to onboarding, and a permission
    /// prompt fired by a background wake eight hours in would be indefensible. If we do not
    /// already have permission, the notification is simply skipped.
    private func postCompletionNotification(for downloads: [Download]) {
        let finished = downloads.filter { $0.status == .completed }
        guard !finished.isEmpty else { return }

        let body: String
        if finished.count == 1, let only = finished.first {
            body = only.filename
        } else {
            body = "\(finished.count) downloads finished"
        }

        let center = UNUserNotificationCenter.current()
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Download complete"
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "dev.goel.ios.complete.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    // MARK: - Isolation funnels

    /// Every `Activity.update` in this type goes through here, so the `ActivityBox` opt-out
    /// exists in exactly two places instead of seven.
    private func updateActivity(
        _ activity: Activity<DownloadActivityAttributes>,
        _ content: ActivityContent<DownloadActivityAttributes.ContentState>
    ) {
        let box = ActivityBox(activity: activity)
        Task { await box.update(content) }
    }

    private func endActivity(
        _ activity: Activity<DownloadActivityAttributes>,
        _ content: ActivityContent<DownloadActivityAttributes.ContentState>?,
        _ dismissalPolicy: ActivityUIDismissalPolicy
    ) {
        let box = ActivityBox(activity: activity)
        Task { await box.end(content, dismissalPolicy: dismissalPolicy) }
    }
}


// MARK: - Sendability shim

/// `ActivityKit.Activity` is a thread-safe class whose `update(_:)` and `end(_:dismissalPolicy:)`
/// are `nonisolated async` and documented as callable from any thread — but the iOS 26.5 SDK
/// does not annotate it `Sendable`. Under Swift 6 strict concurrency that makes every
/// `await activity.update(...)` from `@MainActor` a "sending 'activity' risks causing data
/// races" error, with no safe spelling available at the call site.
///
/// This box is the narrowest possible opt-out: it holds nothing but the activity handle and
/// exposes only the two calls, so the unchecked conformance covers an SDK annotation gap rather
/// than any state of ours. If ActivityKit is ever annotated `Sendable`, delete this type and
/// call the methods directly.
private struct ActivityBox: @unchecked Sendable {
    let activity: Activity<DownloadActivityAttributes>

    func update(_ content: ActivityContent<DownloadActivityAttributes.ContentState>) async {
        await activity.update(content)
    }

    func end(
        _ content: ActivityContent<DownloadActivityAttributes.ContentState>?,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) async {
        await activity.end(content, dismissalPolicy: dismissalPolicy)
    }
}
