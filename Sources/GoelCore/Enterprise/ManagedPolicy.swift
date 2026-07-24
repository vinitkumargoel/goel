import Foundation
// CoreFoundation is imported only where `CFPreferences` actually exists. On Linux
// the module is an implementation detail of corelibs-foundation and carries none
// of the preferences API, so importing it there would buy nothing and risk a
// build break on a toolchain that hides it.
#if canImport(CoreFoundation) && os(macOS)
import CoreFoundation
#endif

// ============================================================================
// Managed preferences (MDM) — the layer that makes the app deployable.
//
// An IT department does not install software per-machine by hand: it pushes a
// configuration profile through Jamf / Kandji / Intune / Munki and expects the
// app to (a) pick the settings up without the user doing anything and (b) stop
// the user from changing the ones the administrator marked as forced. Without
// that, "can we deploy this to 400 Macs?" has no good answer.
//
// The mechanism on macOS is the standard one: a `.mobileconfig` payload whose
// `PayloadType` is the app's preference domain (`com.goel.downloader`) lands in
// `/Library/Managed Preferences/…`, and `CFPreferencesCopyAppValue` returns the
// managed value ahead of anything the user wrote. `CFPreferencesAppValueIsForced`
// then says whether that value came from the managed level (locked) or merely
// from the user's own domain (a seeded default they may still change).
//
// This file is deliberately a *pure* layer over ``AppSettings``:
//
//     let managed = ManagedPolicy.current()
//     let effective = managed.apply(to: storedSettings)
//
// Nothing here writes preferences, phones home, or gates a feature. A managed
// policy can only pin values the user could have set themselves — it can never
// disable the app, expire it, or make it refuse to run. That is a hard product
// rule, not an implementation detail.
//
// The CoreFoundation read is macOS-only; the Linux daemon reads the same key set
// from a JSON file (`/etc/goel/managed-policy.json`), so a fleet of headless
// boxes can be configured by the same configuration-management tooling that
// already owns `/etc`.
// ============================================================================

/// One value as delivered by a managed-preferences payload.
///
/// Profiles are plists, so a key can legitimately arrive as a boolean, an
/// integer, a string or an array of strings — and hand-written payloads
/// routinely send `<string>true</string>` where `<true/>` was meant. The
/// accessors below are therefore lenient in exactly one direction: they coerce
/// an obviously-equivalent representation, and refuse anything else rather than
/// guessing.
public enum ManagedValue: Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case stringList([String])

    /// The value as text, when it can be read as text at all.
    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i):    return String(i)
        case .bool(let b):   return b ? "true" : "false"
        case .stringList:    return nil
        }
    }

    /// The value as a flag. Accepts `true`/`false`, `1`/`0`, and the usual
    /// textual spellings an administrator types into a payload by hand.
    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .int(let i):  return i != 0
        case .string(let s):
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "1", "true", "yes", "on":   return true
            case "0", "false", "no", "off":  return false
            default:                         return nil
            }
        case .stringList: return nil
        }
    }

    /// The value as a whole number.
    public var intValue: Int? {
        switch self {
        case .int(let i):    return i
        case .bool(let b):   return b ? 1 : 0
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
        case .stringList:    return nil
        }
    }

    /// The value as a list of strings. A single string is treated as a one-element
    /// list, which is what an administrator means when they type one hostname into
    /// a key documented as a list.
    public var stringListValue: [String]? {
        switch self {
        case .stringList(let list): return list
        case .string(let s):        return [s]
        case .bool, .int:           return nil
        }
    }
}

/// The read side of managed preferences, behind a port so the policy layer can be
/// unit-tested (and so Linux can supply a file-backed implementation) without a
/// real MDM enrolment.
public protocol ManagedPreferenceReading: Sendable {
    /// The effective value for `key` in the managed domain, or `nil` when the
    /// administrator did not set it.
    func value(forKey key: String) -> ManagedValue?
    /// Whether that value is *forced* — i.e. it came from a configuration profile
    /// rather than from the user's own preference domain. Forced keys are the ones
    /// the UI must render as locked.
    func isForced(_ key: String) -> Bool
}

// MARK: - Policy

/// The administrator-supplied overlay on top of ``AppSettings``.
///
/// Construct it once at launch (and on `NSApplication` re-activation, since a
/// profile can be installed while the app is running), then apply it to the
/// user's stored settings before handing them to the engines. ``managedKeys``
/// and ``lockedKeys`` let the Settings UI dim the controls the user no longer
/// owns instead of silently reverting their edits.
public struct ManagedPolicy: Sendable, Equatable {

    /// The preference domain a configuration profile must target. Matches the
    /// app's bundle identifier — that is what `CFPreferencesCopyAppValue` searches.
    public static let domain = "com.goel.downloader"

    /// Every key an administrator may set. The raw values are the literal keys
    /// used inside the `.mobileconfig` payload and in the Linux JSON file, and
    /// they are effectively public API: renaming one silently breaks a deployed
    /// fleet, so they are kept identical to the ``AppSettings`` property names.
    public enum Key: String, Sendable, CaseIterable {

        // Storage
        /// Absolute path new downloads are saved to.
        case defaultSaveDirectory
        /// How the save folder is chosen: `automatic` | `byType` | `bySource` | `fixed`.
        case defaultFolderRule

        // Proxy
        /// `none` | `system` | `manual`.
        case proxyMode
        /// `http` | `socks5`.
        case proxyType
        case proxyHost
        case proxyPort
        /// Route FTP/SFTP/BitTorrent through the manual proxy too.
        case proxyAllProtocols

        // Speed profiles
        /// Name of the traffic profile the app starts on.
        case selectedProfileName
        /// Whether the byte/sec caps apply at all.
        case speedLimitEnabled
        /// A fleet-wide download ceiling in bytes/sec. Applied as a *clamp* to
        /// every profile, so switching profile cannot escape it.
        case maxDownloadBytesPerSec
        /// A fleet-wide upload ceiling in bytes/sec, clamped the same way.
        case maxUploadBytesPerSec

        // Remote portal
        case remoteAccessEnabled
        case remoteAllowLAN
        case remoteRequireAuth
        case remoteReadOnly
        case remoteTLSEnabled
        case remoteTLSIdentityPath
        case remoteTrustedHeaderAuthEnabled
        case remoteTrustedHeaderName
        case remoteTrustedProxies

        // Updates
        case autoCheckUpdates
        case updateFeedURL

        // Audit
        case auditLogEnabled
        case auditLogDirectory
        case auditLogRetentionDays
        case auditLogKeepFiles
        case auditLogMaxFileMegabytes
    }

    /// One administrator-supplied value plus whether it is locked.
    public struct Entry: Sendable, Equatable {
        public let value: ManagedValue
        /// `true` when the value came from a configuration profile (forced), so
        /// the user must not be able to change it.
        public let isForced: Bool

        public init(value: ManagedValue, isForced: Bool) {
            self.value = value
            self.isForced = isForced
        }
    }

    private var entries: [Key: Entry]

    public init(entries: [Key: Entry] = [:]) {
        self.entries = entries
    }

    /// Convenience for tests and for the Linux file reader: everything forced.
    public init(forced values: [Key: ManagedValue]) {
        self.entries = values.mapValues { Entry(value: $0, isForced: true) }
    }

    /// Whether an administrator set anything at all. `false` on an unmanaged Mac,
    /// which is the overwhelmingly common case — the app then behaves exactly as
    /// it always has.
    public var isEmpty: Bool { entries.isEmpty }

    /// Keys the administrator supplied a value for.
    public var managedKeys: Set<Key> { Set(entries.keys) }

    /// Keys the administrator *forced*. These are the ones the Settings UI should
    /// disable, with a "Managed by your organisation" note.
    public var lockedKeys: Set<Key> {
        Set(entries.filter { $0.value.isForced }.keys)
    }

    public func isManaged(_ key: Key) -> Bool { entries[key] != nil }
    public func isLocked(_ key: Key) -> Bool { entries[key]?.isForced == true }
    public func value(for key: Key) -> ManagedValue? { entries[key]?.value }

    // MARK: Applying

    /// Layer the policy over the user's settings and return the effective values.
    ///
    /// Unset keys are left completely alone — this never resets a setting to a
    /// default just because it is absent from the payload. Values that fail to
    /// coerce (a payload saying `proxyPort = "eight-thousand"`) are ignored
    /// rather than clamped to something arbitrary, so a typo degrades to "not
    /// managed" instead of to a wrong number.
    public func apply(to settings: AppSettings) -> AppSettings {
        var out = settings

        // Storage
        if let v = string(.defaultSaveDirectory), !v.isEmpty { out.defaultSaveDirectory = v }
        if let v = string(.defaultFolderRule), !v.isEmpty { out.defaultFolderRule = v }

        // Proxy
        if let v = string(.proxyMode), !v.isEmpty { out.proxyMode = v }
        if let v = string(.proxyType), !v.isEmpty { out.proxyType = v }
        if let v = string(.proxyHost) { out.proxyHost = v }
        if let v = int(.proxyPort), (0...65535).contains(v) { out.proxyPort = v }
        if let v = bool(.proxyAllProtocols) { out.proxyAllProtocols = v }

        // Speed profiles. The ceilings are applied as a clamp over *every* profile
        // rather than as an assignment to the selected one: the user can switch
        // profile at any time, and an administrator who caps the fleet at 5 MB/s
        // means 5 MB/s, not "5 MB/s until someone picks High".
        if let v = string(.selectedProfileName), !v.isEmpty { out.selectedProfileName = v }
        let downCeiling = int(.maxDownloadBytesPerSec).map(Int64.init)
        let upCeiling = int(.maxUploadBytesPerSec).map(Int64.init)
        if (downCeiling ?? 0) > 0 || (upCeiling ?? 0) > 0 {
            out.profiles = out.profiles.map { profile in
                var p = profile
                if let cap = downCeiling, cap > 0 {
                    p.maxDownloadBytesPerSec = p.maxDownloadBytesPerSec <= 0
                        ? cap : min(p.maxDownloadBytesPerSec, cap)
                }
                if let cap = upCeiling, cap > 0 {
                    p.maxUploadBytesPerSec = p.maxUploadBytesPerSec <= 0
                        ? cap : min(p.maxUploadBytesPerSec, cap)
                }
                return p
            }
            // A managed ceiling is meaningless while the snail is off, because
            // ``AppSettings/effectiveProfile`` then zeroes both byte caps. Forcing
            // a ceiling therefore implies forcing the limiter on, unless the
            // administrator explicitly said otherwise on the very next line.
            out.speedLimitEnabled = true
        }
        if let v = bool(.speedLimitEnabled) { out.speedLimitEnabled = v }

        // Remote portal
        if let v = bool(.remoteAccessEnabled) { out.remoteAccessEnabled = v }
        if let v = bool(.remoteAllowLAN) { out.remoteAllowLAN = v }
        if let v = bool(.remoteRequireAuth) { out.remoteRequireAuth = v }
        if let v = bool(.remoteReadOnly) { out.remoteReadOnly = v }
        if let v = bool(.remoteTLSEnabled) { out.remoteTLSEnabled = v }
        if let v = string(.remoteTLSIdentityPath) { out.remoteTLSIdentityPath = v }
        if let v = bool(.remoteTrustedHeaderAuthEnabled) { out.remoteTrustedHeaderAuthEnabled = v }
        if let v = string(.remoteTrustedHeaderName), !v.isEmpty { out.remoteTrustedHeaderName = v }
        if let v = stringList(.remoteTrustedProxies) { out.remoteTrustedProxies = v }

        // Updates
        if let v = bool(.autoCheckUpdates) { out.autoCheckUpdates = v }
        if let v = string(.updateFeedURL) { out.updateFeedURL = v }

        // Audit
        if let v = bool(.auditLogEnabled) { out.auditLogEnabled = v }
        if let v = string(.auditLogDirectory) { out.auditLogDirectory = v }
        if let v = int(.auditLogRetentionDays), v >= 0 { out.auditLogRetentionDays = v }
        if let v = int(.auditLogKeepFiles), v >= 1 { out.auditLogKeepFiles = v }
        if let v = int(.auditLogMaxFileMegabytes), v >= 1 { out.auditLogMaxFileMegabytes = v }

        return out
    }

    // MARK: Typed accessors

    private func string(_ key: Key) -> String? { entries[key]?.value.stringValue }
    private func bool(_ key: Key) -> Bool? { entries[key]?.value.boolValue }
    private func int(_ key: Key) -> Int? { entries[key]?.value.intValue }
    private func stringList(_ key: Key) -> [String]? { entries[key]?.value.stringListValue }

    // MARK: Reading

    /// Read every known key through `reader`, keeping only the ones present.
    public static func read(using reader: some ManagedPreferenceReading) -> ManagedPolicy {
        var entries: [Key: Entry] = [:]
        for key in Key.allCases {
            guard let value = reader.value(forKey: key.rawValue) else { continue }
            entries[key] = Entry(value: value, isForced: reader.isForced(key.rawValue))
        }
        return ManagedPolicy(entries: entries)
    }

    /// The policy in effect on this machine right now.
    ///
    /// macOS reads the managed-preferences domain; Linux reads
    /// `/etc/goel/managed-policy.json` (override with `GOEL_MANAGED_POLICY`).
    /// Anywhere else — and on an unmanaged Mac — this is empty, and the app runs
    /// exactly as it does for a personal user.
    public static func current() -> ManagedPolicy {
        #if os(macOS)
        return read(using: CFManagedPreferenceReader(domain: domain))
        #else
        let path = ProcessInfo.processInfo.environment["GOEL_MANAGED_POLICY"]
            ?? "/etc/goel/managed-policy.json"
        guard let reader = JSONManagedPreferenceReader(contentsOfFile: path) else {
            return ManagedPolicy()
        }
        return read(using: reader)
        #endif
    }
}

// MARK: - macOS reader

#if os(macOS)
/// Reads the managed domain through CoreFoundation.
///
/// `CFPreferencesCopyAppValue` walks the full search chain — managed profile
/// first, then the user's own domain — which is exactly the precedence an
/// administrator expects. `CFPreferencesAppValueIsForced` distinguishes the two
/// so a value seeded with `defaults write` shows up as managed-but-editable
/// while a profile-installed value shows up as locked.
public struct CFManagedPreferenceReader: ManagedPreferenceReading {

    /// Held as a `String`, not a `CFString`: `CFString` is not `Sendable`, and
    /// this reader must cross isolation boundaries. The bridge is free.
    private let domain: String

    public init(domain: String) {
        self.domain = domain
    }

    public func value(forKey key: String) -> ManagedValue? {
        guard let raw = CFPreferencesCopyAppValue(key as CFString, domain as CFString) else {
            return nil
        }
        return Self.convert(raw)
    }

    public func isForced(_ key: String) -> Bool {
        CFPreferencesAppValueIsForced(key as CFString, domain as CFString)
    }

    /// Map a property-list value onto ``ManagedValue``.
    ///
    /// The `NSNumber` case is checked for boolean-ness first because CoreFoundation
    /// hands back `kCFBooleanTrue` as an `NSNumber`, and treating a `<true/>` as
    /// the integer `1` would make a flag silently readable as a byte count.
    static func convert(_ raw: CFPropertyList) -> ManagedValue? {
        if let number = raw as? NSNumber {
            if CFGetTypeID(raw) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .int(number.intValue)
        }
        if let text = raw as? String { return .string(text) }
        if let list = raw as? [Any] {
            let strings = list.compactMap { $0 as? String }
            return strings.count == list.count ? .stringList(strings) : nil
        }
        return nil
    }
}
#endif

// MARK: - File reader (Linux daemons, and tests everywhere)

/// A managed-preferences source backed by a flat JSON object.
///
/// Used by the Linux daemon — where there is no CFPreferences and no MDM, but
/// there *is* configuration management that already owns `/etc` — and by the
/// tests, so the policy layering can be exercised without an enrolled Mac.
///
/// Every key present is reported as forced: a file placed in `/etc` by root is
/// the administrator speaking, with the same authority a profile carries.
public struct JSONManagedPreferenceReader: ManagedPreferenceReading {

    private let values: [String: ManagedValue]

    public init(values: [String: ManagedValue]) {
        self.values = values
    }

    /// Parse a JSON object of scalar (or string-array) values. Returns `nil` when
    /// the file is missing or unreadable — an absent policy file means "unmanaged",
    /// never "fail to launch".
    public init?(contentsOfFile path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var parsed: [String: ManagedValue] = [:]
        // `JSONSerialization` hands back `NSNumber` for both booleans and integers,
        // so `1` may land in the `.bool` bucket and `true` in the `.int` bucket
        // depending on the platform's bridging. That is harmless here because
        // ``ManagedValue`` coerces between the two — a flag read as `.int(1)` still
        // answers `boolValue == true`, and a count read as `.bool(true)` still
        // answers `intValue == 1`.
        for (key, raw) in object {
            if let flag = raw as? Bool { parsed[key] = .bool(flag) }
            else if let number = raw as? Int { parsed[key] = .int(number) }
            else if let number = raw as? Double { parsed[key] = .int(Int(number)) }
            else if let text = raw as? String { parsed[key] = .string(text) }
            else if let list = raw as? [String] { parsed[key] = .stringList(list) }
        }
        self.values = parsed
    }

    public func value(forKey key: String) -> ManagedValue? { values[key] }

    public func isForced(_ key: String) -> Bool { values[key] != nil }
}
