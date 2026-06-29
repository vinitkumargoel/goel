import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

/// Thin wrapper over the IOKit power-management APIs the scheduler uses to keep
/// the Mac awake while transfers are running and to tell whether we are on
/// battery.
///
/// macOS lets a process create a **power assertion** that prevents the system
/// from idle-sleeping. The assertion stays in effect until it is explicitly
/// released (or the owning process dies), so this type holds **at most one**
/// assertion at a time and remembers its id to make ``setPreventSleep(_:)``
/// idempotent: repeated `true` calls keep the single assertion rather than
/// leaking new ones, and `false` releases whatever is outstanding.
///
/// `DownloadManager` (an `actor`) keeps a reference to this object, so it must
/// be `Sendable`. Its only mutable state is the optional assertion id, guarded
/// by an internal lock; hence the `@unchecked Sendable` conformance.
public final class PowerManager: @unchecked Sendable {

    // MARK: State

    /// Serializes access to ``assertionID`` so the manager can be touched from
    /// any isolation domain.
    private let lock = NSLock()

    /// The id of the outstanding "prevent idle sleep" assertion, or `nil` when
    /// none is held. Guarded by ``lock``.
    private var assertionID: IOPMAssertionID?

    public init() {}

    deinit {
        // Drop any assertion we still hold on the way out so we never leave the
        // system pinned awake after the manager goes away.
        setPreventSleep(false)
    }

    // MARK: Sleep prevention

    /// Create or release the single "prevent idle system sleep" power assertion.
    ///
    /// Passing the same value repeatedly is safe: a second `true` keeps the
    /// existing assertion instead of allocating another, and `false` with
    /// nothing held is a no-op.
    public func setPreventSleep(_ on: Bool) {
        lock.lock()
        defer { lock.unlock() }

        if on {
            // Already holding an assertion — nothing to do.
            guard assertionID == nil else { return }
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "GoelDownloader active download" as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                assertionID = id
            }
        } else {
            // Release whatever assertion we are holding, if any.
            guard let id = assertionID else { return }
            IOPMAssertionRelease(id)
            assertionID = nil
        }
    }

    // MARK: Power source

    /// Whether the Mac is currently drawing from its battery rather than AC/UPS.
    ///
    /// Returns `false` on desktops (which report AC power) and whenever the
    /// providing power source cannot be determined.
    public var isOnBattery: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return false
        }
        // `IOPSGetProvidingPowerSourceType` follows the "Get" convention, so the
        // returned string is not owned by us — take it unretained.
        guard let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return false
        }
        return (providing as String) == kIOPMBatteryPowerKey
    }
}
