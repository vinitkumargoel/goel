import Foundation
#if canImport(IOKit)
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
#endif

/// `@unchecked Sendable`: every mutable field below must stay behind `lock`.
public final class PowerManager: @unchecked Sendable {

    private let lock = NSLock()

    #if canImport(IOKit)
    private var assertionID: IOPMAssertionID?
    #else
    private var inhibitor: Process?
    #endif

    public init() {}

    deinit {
        setPreventSleep(false)
    }

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
            // Deliberately swallowed: a box without systemd-inhibit simply never idle-sleeps.
            do { try p.run(); inhibitor = p } catch { }
        } else {
            inhibitor?.terminate()
            inhibitor = nil
        }
        #endif
    }

    public var isOnBattery: Bool {
        #if canImport(IOKit)
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return false
        }
        // "Get" convention: the string is not ours, so it must be taken unretained.
        guard let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return false
        }
        return (providing as String) == kIOPMBatteryPowerKey
        #else
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
                if read(dir + "/online") == "1" { return false }
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

    /// `nil` is deliberately not zero: a desktop must not look like a flat laptop and pause the queue.
    public var batteryPercent: Int? {
        #if canImport(IOKit)
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            // "Get" convention: the description dictionary is not ours to retain.
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
