import Foundation
#if canImport(IOKit)
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
#endif

/// Keeps the machine awake while transfers run and reports battery state: IOKit power assertions on
/// macOS, `systemd-inhibit` + sysfs on Linux. `@unchecked Sendable` — mutable state is lock-guarded.
public final class PowerManager: @unchecked Sendable {

    // MARK: State

    /// Serializes access to the platform handle so the manager can be touched
    /// from any isolation domain.
    private let lock = NSLock()

    #if canImport(IOKit)
    /// The id of the outstanding "prevent idle sleep" assertion, or `nil`.
    private var assertionID: IOPMAssertionID?
    #else
    /// The running `systemd-inhibit` process holding the sleep lock, or `nil`.
    private var inhibitor: Process?
    #endif

    public init() {}

    deinit {
        // Drop any hold on the way out so we never leave the system pinned awake.
        setPreventSleep(false)
    }

    // MARK: Sleep prevention

    /// Create or release the single "prevent idle sleep" hold. Idempotent: a second `true` keeps the
    /// existing hold, and `false` with nothing held is a no-op.
    public func setPreventSleep(_ on: Bool) {
        lock.lock()
        defer { lock.unlock() }

        #if canImport(IOKit)
        if on {
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
            guard let id = assertionID else { return }
            IOPMAssertionRelease(id)
            assertionID = nil
        }
        #else
        if on {
            guard inhibitor == nil else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/systemd-inhibit")
            p.arguments = [
                "--what=sleep:idle", "--who=GoelDownloader",
                "--why=active download", "--mode=block",
                "sleep", "infinity",
            ]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            // Best-effort: on a box without systemd-inhibit this simply does
            // nothing (a headless server rarely idle-sleeps anyway).
            do { try p.run(); inhibitor = p } catch { /* not available — ignore */ }
        } else {
            inhibitor?.terminate()
            inhibitor = nil
        }
        #endif
    }

    // MARK: Power source

    /// Whether the machine is currently drawing from a battery rather than AC.
    /// Desktops/servers (AC online or no battery) report `false`.
    public var isOnBattery: Bool {
        #if canImport(IOKit)
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return false
        }
        // `IOPSGetProvidingPowerSourceType` follows the "Get" convention, so the
        // returned string is not owned by us — take it unretained.
        guard let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return false
        }
        return (providing as String) == kIOPMBatteryPowerKey
        #else
        // Read the sysfs power-supply tree. AC online → not on battery; a battery
        // reporting "Discharging" → on battery.
        let base = "/sys/class/power_supply"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: base) else {
            return false
        }
        func read(_ path: String) -> String? {
            (try? String(contentsOfFile: path, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var sawMains = false
        for entry in entries {
            let dir = base + "/" + entry
            switch read(dir + "/type") {
            case "Mains", "USB":
                sawMains = true
                if read(dir + "/online") == "1" { return false }  // AC connected
            case "Battery":
                if read(dir + "/status") == "Discharging" { return true }
            default:
                break
            }
        }
        // A mains adapter present but none online means we're on battery.
        return sawMains
        #endif
    }

    /// Remaining battery charge `0…100`, or `nil` when there is no battery / it can't be read. `nil` is
    /// deliberately not zero: a desktop must not look like a flat laptop and pause the queue.
    public var batteryPercent: Int? {
        #if canImport(IOKit)
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            // "Get" convention again — the description dictionary is not ours.
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                    .takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey as String] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey as String] as? Int,
                  maximum > 0
            else { continue }
            return min(100, max(0, current * 100 / maximum))
        }
        return nil
        #else
        // sysfs reports the level directly as a percentage.
        let base = "/sys/class/power_supply"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: base) else {
            return nil
        }
        func read(_ path: String) -> String? {
            (try? String(contentsOfFile: path, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for entry in entries {
            let dir = base + "/" + entry
            guard read(dir + "/type") == "Battery",
                  let capacity = read(dir + "/capacity").flatMap(Int.init)
            else { continue }
            return min(100, max(0, capacity))
        }
        return nil
        #endif
    }
}
