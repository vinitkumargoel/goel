import Foundation
// Corelibs-foundation has no preferences API, so CoreFoundation is imported only where CFPreferences exists.
#if canImport(CoreFoundation) && os(macOS)
import CoreFoundation
#endif

public enum ManagedValue: Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case stringList([String])

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i):    return String(i)
        case .bool(let b):   return b ? "true" : "false"
        case .stringList:    return nil
        }
    }

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

    public var intValue: Int? {
        switch self {
        case .int(let i):    return i
        case .bool(let b):   return b ? 1 : 0
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
        case .stringList:    return nil
        }
    }

    public var stringListValue: [String]? {
        switch self {
        case .stringList(let list): return list
        case .string(let s):        return [s]
        case .bool, .int:           return nil
        }
    }

    static func dictionary(from object: [String: Any]) -> [String: ManagedValue] {
        var parsed: [String: ManagedValue] = [:]
        for (key, raw) in object {
            if let flag = raw as? Bool { parsed[key] = .bool(flag) }
            else if let number = raw as? Int { parsed[key] = .int(number) }
            // `Int(_:)` traps out of range and this is parsed input: `9e30` is valid JSON and would abort the process.
            else if let number = raw as? Double,
                    let whole = Int(exactly: number.rounded(.towardZero)) { parsed[key] = .int(whole) }
            else if let text = raw as? String { parsed[key] = .string(text) }
            else if let list = raw as? [String] { parsed[key] = .stringList(list) }
        }
        return parsed
    }
}

public protocol ManagedPreferenceReading: Sendable {
    func value(forKey key: String) -> ManagedValue?
    /// Forced = from a configuration profile, not the user's own writable preference domain.
    func isForced(_ key: String) -> Bool
}

public struct ManagedPolicy: Sendable, Equatable {

    /// Not a trust boundary — forcedness is (see ``apply(to:)``).
    public static let domain = "com.goel.downloader"

    /// Raw values are the literal `.mobileconfig` / Linux-JSON keys and are public API: renaming one silently breaks a fleet.
    public enum Key: String, Sendable, CaseIterable {

        case defaultSaveDirectory
        case defaultFolderRule

        case proxyMode
        case proxyType
        case proxyHost
        case proxyPort
        case proxyAllProtocols

        case selectedProfileName
        case speedLimitEnabled
        case maxDownloadBytesPerSec
        case maxUploadBytesPerSec

        case remoteAccessEnabled
        case remoteAllowLAN
        case remoteRequireAuth
        case remoteReadOnly
        case remoteTLSEnabled
        case remoteTLSIdentityPath
        case remoteTrustedHeaderAuthEnabled
        case remoteTrustedHeaderName
        case remoteTrustedProxies

        case autoCheckUpdates
        case updateFeedURL

        case auditLogEnabled
        case auditLogDirectory
        case auditLogRetentionDays
        case auditLogKeepFiles
        case auditLogMaxFileMegabytes
    }

    public struct Entry: Sendable, Equatable {
        public let value: ManagedValue
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

    public init(forced values: [Key: ManagedValue]) {
        self.entries = values.mapValues { Entry(value: $0, isForced: true) }
    }

    public var isEmpty: Bool { entries.isEmpty }

    public var managedKeys: Set<Key> { Set(entries.keys) }

    public var lockedKeys: Set<Key> {
        Set(entries.filter { $0.value.isForced }.keys)
    }

    public func isManaged(_ key: Key) -> Bool { entries[key] != nil }
    public func isLocked(_ key: Key) -> Bool { entries[key]?.isForced == true }
    public func value(for key: Key) -> ManagedValue? { entries[key]?.value }

    /// Only *forced* entries apply; a value that fails to coerce degrades to "not managed", never a guess.
    public func apply(to settings: AppSettings) -> AppSettings {
        var out = settings

        if let v = string(.defaultSaveDirectory), !v.isEmpty { out.defaultSaveDirectory = v }
        if let v = string(.defaultFolderRule), !v.isEmpty { out.defaultFolderRule = v }

        if let v = string(.proxyMode), !v.isEmpty { out.proxyMode = v }
        if let v = string(.proxyType), !v.isEmpty { out.proxyType = v }
        if let v = string(.proxyHost) { out.proxyHost = v }
        if let v = int(.proxyPort), (0...65535).contains(v) { out.proxyPort = v }
        if let v = bool(.proxyAllProtocols) { out.proxyAllProtocols = v }

        // Ceilings must clamp every profile, not just the selected one: the user can switch profile at any time.
        if let v = string(.selectedProfileName), !v.isEmpty { out.selectedProfileName = v }
        let downCeiling = int(.maxDownloadBytesPerSec).map(Int64.init)
        let upCeiling = int(.maxUploadBytesPerSec).map(Int64.init)
        if (downCeiling ?? 0) > 0 || (upCeiling ?? 0) > 0 {
            // `selectedProfile` falls back to `.medium`, which is not in `profiles` — an empty list would escape the ceiling.
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
            // `effectiveProfile` zeroes both caps while the limiter is off, so a forced ceiling must force it on.
            out.speedLimitEnabled = true
        }
        if let v = bool(.speedLimitEnabled) { out.speedLimitEnabled = v }

        if let v = bool(.remoteAccessEnabled) { out.remoteAccessEnabled = v }
        if let v = bool(.remoteAllowLAN) { out.remoteAllowLAN = v }
        if let v = bool(.remoteRequireAuth) { out.remoteRequireAuth = v }
        if let v = bool(.remoteReadOnly) { out.remoteReadOnly = v }
        if let v = bool(.remoteTLSEnabled) { out.remoteTLSEnabled = v }
        if let v = string(.remoteTLSIdentityPath) { out.remoteTLSIdentityPath = v }
        if let v = bool(.remoteTrustedHeaderAuthEnabled) { out.remoteTrustedHeaderAuthEnabled = v }
        if let v = string(.remoteTrustedHeaderName), !v.isEmpty { out.remoteTrustedHeaderName = v }
        if let v = stringList(.remoteTrustedProxies) { out.remoteTrustedProxies = v }

        if let v = bool(.autoCheckUpdates) { out.autoCheckUpdates = v }
        if let v = string(.updateFeedURL) { out.updateFeedURL = v }

        if let v = bool(.auditLogEnabled) { out.auditLogEnabled = v }
        if let v = string(.auditLogDirectory) { out.auditLogDirectory = v }
        if let v = int(.auditLogRetentionDays), v >= 0 { out.auditLogRetentionDays = v }
        if let v = int(.auditLogKeepFiles), v >= 1 { out.auditLogKeepFiles = v }
        if let v = int(.auditLogMaxFileMegabytes), v >= 1 { out.auditLogMaxFileMegabytes = v }

        return out
    }

    /// Only a forced value is policy: an unforced one came from the user-writable plist.
    private func forcedValue(_ key: Key) -> ManagedValue? {
        guard let entry = entries[key], entry.isForced else { return nil }
        return entry.value
    }

    private func string(_ key: Key) -> String? { forcedValue(key)?.stringValue }
    private func bool(_ key: Key) -> Bool? { forcedValue(key)?.boolValue }
    private func int(_ key: Key) -> Int? { forcedValue(key)?.intValue }
    private func stringList(_ key: Key) -> [String]? { forcedValue(key)?.stringListValue }

    public static func read(using reader: some ManagedPreferenceReading) -> ManagedPolicy {
        var entries: [Key: Entry] = [:]
        for key in Key.allCases {
            guard let value = reader.value(forKey: key.rawValue) else { continue }
            entries[key] = Entry(value: value, isForced: reader.isForced(key.rawValue))
        }
        return ManagedPolicy(entries: entries)
    }

    public static func current() -> ManagedPolicy {
        #if os(macOS)
        // Prefer the managed-preferences directory: the trust boundary is then a filesystem permission, not an API contract.
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

/// A policy file's only authority is its permissions, so readers must refuse group/world-writable ones.
private func isWritableByOthers(_ path: String) -> Bool {
    guard let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions],
          let bits = (mode as? NSNumber)?.uint16Value else { return false }
    return bits & 0o022 != 0
}

#if os(macOS)
public struct CFManagedPreferenceReader: ManagedPreferenceReading {

    /// Held as a `String`, not a `CFString`: `CFString` is not `Sendable` and this reader crosses isolation boundaries.
    private let domain: String

    public init(domain: String) {
        self.domain = domain
    }

    public func value(forKey key: String) -> ManagedValue? {
        // Without the forced check, `CFPreferencesCopyAppValue` reaches the user-writable plist and `defaults write` becomes policy.
        guard CFPreferencesAppValueIsForced(key as CFString, domain as CFString),
              let raw = CFPreferencesCopyAppValue(key as CFString, domain as CFString) else {
            return nil
        }
        return Self.convert(raw)
    }

    public func isForced(_ key: String) -> Bool {
        CFPreferencesAppValueIsForced(key as CFString, domain as CFString)
    }

    /// Boolean-ness must be checked first: CoreFoundation hands back `kCFBooleanTrue` as `NSNumber`, so `<true/>` would read as `1`.
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

/// The root-owned `/Library/Managed Preferences` is a filesystem trust boundary: every value there is forced by construction.
public struct ManagedPreferencePathReader: ManagedPreferenceReading {

    public static let managedRoot = "/Library/Managed Preferences"

    private let values: [String: ManagedValue]

    public init?(domain: String, user: String = NSUserName(), root: String = managedRoot) {
        var merged = Self.load(root + "/" + domain + ".plist") ?? [:]
        for (key, value) in Self.load(root + "/" + user + "/" + domain + ".plist") ?? [:] {
            merged[key] = value
        }
        // Nothing found means "no profile here", not "unmanaged" — the caller must still reach the CoreFoundation fallback.
        guard !merged.isEmpty else { return nil }
        self.values = merged
    }

    /// A plist writable by anyone but its owner is refused: the directory's permissions are the whole reason to trust it.
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

    /// Everything here came out of the managed-preferences directory, so everything it returns is forced.
    public func isForced(_ key: String) -> Bool { values[key] != nil }
}
#endif

/// Every key here counts as forced, so ``init(contentsOfFile:)`` refuses a file any user can rewrite.
public struct JSONManagedPreferenceReader: ManagedPreferenceReading {

    private let values: [String: ManagedValue]

    public init(values: [String: ManagedValue]) {
        self.values = values
    }

    public init?(contentsOfFile path: String) {
        // Trusting a group/world-writable policy file is how a local user grants themselves a fleet proxy and disables the audit log.
        if isWritableByOthers(path) {
            GoelLog.app.error("refusing a group/world-writable managed policy file", .path(path))
            return nil
        }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Must be logged: otherwise an administrator's typo silently drops policy across a fleet.
            GoelLog.app.error("managed policy file is present but is not a JSON object",
                              .path(path))
            return nil
        }
        self.values = ManagedValue.dictionary(from: object)
    }

    public func value(forKey key: String) -> ManagedValue? { values[key] }

    public func isForced(_ key: String) -> Bool { values[key] != nil }
}
