import Foundation
// CoreFoundation only where `CFPreferences` exists: on Linux it is a corelibs-foundation internal with
// no preferences API, so importing it buys nothing and risks a break on toolchains that hide it.
#if canImport(CoreFoundation) && os(macOS)
import CoreFoundation
#endif

// Managed preferences (MDM): a pushed `.mobileconfig` on `com.goel.downloader` (macOS) or
// `/etc/goel/managed-policy.json` (Linux). Only *forced* keys are policy; this pins values, never gates.

/// One value from a managed-preferences payload. Profiles are plists, so a key may arrive as bool, int,
/// string or [string] — hand-written ones send `<string>true</string>`; accessors coerce, never guess.
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

    /// The value as a list of strings. A bare string becomes a one-element list — what an administrator
    /// means when they type one hostname into a key documented as a list.
    public var stringListValue: [String]? {
        switch self {
        case .stringList(let list): return list
        case .string(let s):        return [s]
        case .bool, .int:           return nil
        }
    }

    /// Map decoded JSON / plist onto the managed value space, dropping ill-shaped entries; shared by both
    /// file readers so they cannot drift. Bool/int may swap buckets (`NSNumber`) — harmless, accessors coerce.
    static func dictionary(from object: [String: Any]) -> [String: ManagedValue] {
        var parsed: [String: ManagedValue] = [:]
        for (key, raw) in object {
            if let flag = raw as? Bool { parsed[key] = .bool(flag) }
            else if let number = raw as? Int { parsed[key] = .int(number) }
            // `Int(_:)` on a `Double` traps out of range, and this is parsed input: `9e30` is valid JSON
            // and would abort the process. Truncate toward zero; out-of-range falls to "not managed".
            else if let number = raw as? Double,
                    let whole = Int(exactly: number.rounded(.towardZero)) { parsed[key] = .int(whole) }
            else if let text = raw as? String { parsed[key] = .string(text) }
            else if let list = raw as? [String] { parsed[key] = .stringList(list) }
        }
        return parsed
    }
}

/// The read side of managed preferences, behind a port so the policy layer is unit-testable (and Linux
/// can supply a file-backed implementation) without a real MDM enrolment.
public protocol ManagedPreferenceReading: Sendable {
    /// The effective value for `key` in the managed domain, or `nil` when the
    /// administrator did not set it.
    func value(forKey key: String) -> ManagedValue?
    /// Whether that value is *forced* — from a configuration profile, not the user's own preference
    /// domain. Forced keys are the ones the UI must render as locked.
    func isForced(_ key: String) -> Bool
}

// MARK: - Policy

/// The administrator-supplied overlay on ``AppSettings``. Build at launch and on re-activation (a profile
/// can install while running); ``managedKeys``/``lockedKeys`` let Settings dim controls, not revert edits.
public struct ManagedPolicy: Sendable, Equatable {

    /// The domain a configuration profile must target: the bundle identifier, what
    /// `CFPreferencesCopyAppValue` searches. Not a trust boundary — forcedness is (see ``apply(to:)``).
    public static let domain = "com.goel.downloader"

    /// Every key an administrator may set. Raw values are the literal `.mobileconfig` / Linux-JSON keys
    /// and are public API — renaming one silently breaks a fleet. Kept identical to ``AppSettings`` names.
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

    /// Whether an administrator set anything at all. `false` on an unmanaged Mac — the overwhelmingly
    /// common case, where the app behaves exactly as it always has.
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

    /// Layer the policy over the user's settings. Only *forced* entries apply (see ``forcedValue(_:)``);
    /// unset keys are left alone, and values that fail to coerce degrade to "not managed", never a guess.
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

        // Speed profiles. Ceilings clamp *every* profile, not just the selected one: the user can switch
        // profile at any time, and a 5 MB/s fleet cap must not mean "5 MB/s until someone picks High".
        if let v = string(.selectedProfileName), !v.isEmpty { out.selectedProfileName = v }
        let downCeiling = int(.maxDownloadBytesPerSec).map(Int64.init)
        let upCeiling = int(.maxUploadBytesPerSec).map(Int64.init)
        if (downCeiling ?? 0) > 0 || (upCeiling ?? 0) > 0 {
            // ``AppSettings/selectedProfile`` falls back to `.medium`, not in `profiles`, so an empty list
            // (from an imported backup) would run at Medium's 50 MB/s under a 5 MB/s fleet ceiling.
            if out.profiles.isEmpty { out.profiles = [.medium] }
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
            // ``AppSettings/effectiveProfile`` zeroes both byte caps while the limiter is off, so forcing
            // a ceiling implies forcing the limiter on — unless the admin overrides on the next line.
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
    // All go via ``forcedValue(_:)``: an unforced value came from the user-writable plist, not policy.

    /// The value for `key`, but only when it is forced.
    private func forcedValue(_ key: Key) -> ManagedValue? {
        guard let entry = entries[key], entry.isForced else { return nil }
        return entry.value
    }

    private func string(_ key: Key) -> String? { forcedValue(key)?.stringValue }
    private func bool(_ key: Key) -> Bool? { forcedValue(key)?.boolValue }
    private func int(_ key: Key) -> Int? { forcedValue(key)?.intValue }
    private func stringList(_ key: Key) -> [String]? { forcedValue(key)?.stringListValue }

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

    /// The policy in effect now: macOS reads `/Library/Managed Preferences`, then CoreFoundation; Linux
    /// reads `/etc/goel/managed-policy.json` (`GOEL_MANAGED_POLICY` overrides). Empty when unmanaged.
    public static func current() -> ManagedPolicy {
        #if os(macOS)
        // Prefer the managed-preferences directory: the trust boundary is then a filesystem permission,
        // not an API contract. CFPreferences is the (forced-gated) fallback when the profile is elsewhere.
        if let managed = ManagedPreferencePathReader(domain: domain) { return read(using: managed) }
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

// MARK: - Policy-file trust

/// Whether `path` can be rewritten by someone other than its owner. A policy file's only authority is
/// its permissions, so readers refuse group/world-writable ones; an unstattable file fails at the read.
private func isWritableByOthers(_ path: String) -> Bool {
    guard let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions],
          let bits = (mode as? NSNumber)?.uint16Value else { return false }
    return bits & 0o022 != 0
}

// MARK: - macOS readers

#if os(macOS)
/// Reads the managed domain through CoreFoundation. `CFPreferencesCopyAppValue`'s search chain ends in
/// a user-writable plist, so only values `CFPreferencesAppValueIsForced` confirms are reported.
public struct CFManagedPreferenceReader: ManagedPreferenceReading {

    /// Held as a `String`, not a `CFString`: `CFString` is not `Sendable`, and
    /// this reader must cross isolation boundaries. The bridge is free.
    private let domain: String

    public init(domain: String) {
        self.domain = domain
    }

    public func value(forKey key: String) -> ManagedValue? {
        // Only a forced value is policy: `CFPreferencesCopyAppValue`'s search chain ends in the
        // user-writable `~/Library/Preferences/<domain>.plist`, so `defaults write` would be policy.
        guard CFPreferencesAppValueIsForced(key as CFString, domain as CFString),
              let raw = CFPreferencesCopyAppValue(key as CFString, domain as CFString) else {
            return nil
        }
        return Self.convert(raw)
    }

    public func isForced(_ key: String) -> Bool {
        CFPreferencesAppValueIsForced(key as CFString, domain as CFString)
    }

    /// Map a property-list value onto ``ManagedValue``. Boolean-ness is checked first: CoreFoundation
    /// hands back `kCFBooleanTrue` as `NSNumber`, so `<true/>` would be readable as the byte count `1`.
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

/// Reads profiles from the root-owned `/Library/Managed Preferences`, so every value is forced by
/// construction — a filesystem trust boundary, hence preferred over ``CFManagedPreferenceReader``.
public struct ManagedPreferencePathReader: ManagedPreferenceReading {

    /// Where macOS materialises installed configuration profiles.
    public static let managedRoot = "/Library/Managed Preferences"

    private let values: [String: ManagedValue]

    /// Load the device-scope profile, then overlay the current user's — more
    /// specific wins, which is the precedence CoreFoundation itself applies.
    public init?(domain: String, user: String = NSUserName(), root: String = managedRoot) {
        var merged = Self.load(root + "/" + domain + ".plist") ?? [:]
        for (key, value) in Self.load(root + "/" + user + "/" + domain + ".plist") ?? [:] {
            merged[key] = value
        }
        // Nothing found means "no profile at this path", not "unmanaged": the caller falls back to
        // CoreFoundation, so this reader can only ever add coverage, never take it away.
        guard !merged.isEmpty else { return nil }
        self.values = merged
    }

    /// Parse one profile plist; `nil` when absent, unreadable, or not a dictionary. One writable by
    /// anyone but its owner is refused — the directory's permissions are the whole reason to trust it.
    private static func load(_ path: String) -> [String: ManagedValue]? {
        guard !isWritableByOthers(path) else {
            GoelLog.app.error("refusing a group/world-writable managed preference file", .path(path))
            return nil
        }
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return ManagedValue.dictionary(from: object)
    }

    public func value(forKey key: String) -> ManagedValue? { values[key] }

    /// Everything this reader returns came out of the managed-preferences
    /// directory, so everything it returns is forced.
    public func isForced(_ key: String) -> Bool { values[key] != nil }
}
#endif

// MARK: - File reader (Linux daemons, and tests everywhere)

/// Managed preferences from a flat JSON object — the Linux daemon (no CFPreferences/MDM) and tests.
/// Every key counts as forced, but checked: ``init(contentsOfFile:)`` refuses a file any user can rewrite.
public struct JSONManagedPreferenceReader: ManagedPreferenceReading {

    private let values: [String: ManagedValue]

    public init(values: [String: ManagedValue]) {
        self.values = values
    }

    /// Parse a JSON object of scalar (or string-array) values. Returns `nil` — "unmanaged", never
    /// "fail to launch" — if absent, writable by a non-owner, or unparseable (the last two are logged).
    public init?(contentsOfFile path: String) {
        // Permissions are this file's only authority; a group/world-writable one is refused, because
        // trusting it is how a local user grants themselves a fleet proxy and turns the audit log off.
        if isWritableByOthers(path) {
            GoelLog.app.error("refusing a group/world-writable managed policy file", .path(path))
            return nil
        }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // A parse failure is an administrator's typo, not an unmanaged machine: run unmanaged
            // (refusing to launch over a stray comma is worse) but log it, or a fleet loses policy silently.
            GoelLog.app.error("managed policy file is present but is not a JSON object",
                              .path(path))
            return nil
        }
        self.values = ManagedValue.dictionary(from: object)
    }

    public func value(forKey key: String) -> ManagedValue? { values[key] }

    public func isForced(_ key: String) -> Bool { values[key] != nil }
}
