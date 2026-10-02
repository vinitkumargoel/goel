import Foundation

/// `GET /api/settings`: the handful of server settings the portal edits, grouped as the desktop
/// app's General and BitTorrent panes are. `maxSimultaneousDownloads` belongs to the *active*
/// traffic profile (the desktop keeps it on the Speed pane); `profile` names which one.
public struct RemoteSettingsState: Sendable, Codable, Equatable {
    public struct General: Sendable, Codable, Equatable {
        public var defaultSaveDirectory: String
        /// `automatic`, `byType`, `bySource` or `fixed`.
        public var defaultFolderRule: String
        /// `rename` or `overwrite`.
        public var existingFileReaction: String
        public var maxSimultaneousDownloads: Int
        public var profile: String
    }

    public struct BitTorrent: Sendable, Codable, Equatable {
        /// `prefer`, `require` or `disable`.
        public var encryptionMode: String
        public var dht: Bool
        public var pex: Bool
        public var lpd: Bool
        public var utp: Bool
        public var autoDeleteTorrent: Bool
    }

    public var general: General
    public var bittorrent: BitTorrent
}

/// `POST /api/settings`: every field optional; a missing one keeps its value. Unknown keys are ignored.
public struct RemoteSettingsUpdate: Sendable, Equatable, Decodable {
    public struct General: Sendable, Equatable, Decodable {
        public var defaultSaveDirectory: String?
        public var defaultFolderRule: String?
        public var existingFileReaction: String?
        public var maxSimultaneousDownloads: Int?

        public init(defaultSaveDirectory: String? = nil, defaultFolderRule: String? = nil,
                    existingFileReaction: String? = nil, maxSimultaneousDownloads: Int? = nil) {
            self.defaultSaveDirectory = defaultSaveDirectory
            self.defaultFolderRule = defaultFolderRule
            self.existingFileReaction = existingFileReaction
            self.maxSimultaneousDownloads = maxSimultaneousDownloads
        }
    }

    public struct BitTorrent: Sendable, Equatable, Decodable {
        public var encryptionMode: String?
        public var dht: Bool?
        public var pex: Bool?
        public var lpd: Bool?
        public var utp: Bool?
        public var autoDeleteTorrent: Bool?

        public init(encryptionMode: String? = nil, dht: Bool? = nil, pex: Bool? = nil,
                    lpd: Bool? = nil, utp: Bool? = nil, autoDeleteTorrent: Bool? = nil) {
            self.encryptionMode = encryptionMode
            self.dht = dht
            self.pex = pex
            self.lpd = lpd
            self.utp = utp
            self.autoDeleteTorrent = autoDeleteTorrent
        }
    }

    public var general: General?
    public var bittorrent: BitTorrent?

    public init(general: General? = nil, bittorrent: BitTorrent? = nil) {
        self.general = general
        self.bittorrent = bittorrent
    }

    static let folderRules: Set<String> = ["automatic", "byType", "bySource", "fixed"]
    /// "overwrite" is left out on purpose: with it a remote Add could replace any file the user
    /// already has under home. It can only be turned on in the app; GET still reports it.
    static let fileReactions: Set<String> = ["rename"]
    static let encryptionModes: Set<String> = ["prefer", "require", "disable"]
    static let simultaneousRange = 1...20
    static let maxPathLength = 1024

    /// Shape checks only; whether the folder is writable and allowed is the backend's call (the router asks).
    /// Refuse rather than clamp: a typo must not quietly become some other value.
    public func refusal() -> String? {
        if let g = general {
            if let path = g.defaultSaveDirectory {
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || !trimmed.hasPrefix("/") { return "The download folder must be an absolute path." }
                if trimmed.utf8.count > Self.maxPathLength || trimmed.contains("\0") {
                    return "That download folder path is not valid."
                }
            }
            if let rule = g.defaultFolderRule, !Self.folderRules.contains(rule) {
                return "The folder rule must be automatic, byType, bySource or fixed."
            }
            if let reaction = g.existingFileReaction, !Self.fileReactions.contains(reaction) {
                return reaction == "overwrite"
                    ? "Overwrite can only be turned on in the Goel° app."
                    : "When a file exists must be rename."
            }
            if let n = g.maxSimultaneousDownloads, !Self.simultaneousRange.contains(n) {
                return "Simultaneous downloads must be \(Self.simultaneousRange.lowerBound)–\(Self.simultaneousRange.upperBound)."
            }
        }
        if let mode = bittorrent?.encryptionMode, !Self.encryptionModes.contains(mode) {
            return "Encryption must be prefer, require or disable."
        }
        return nil
    }

    /// The folder to vet with the backend, trimmed; nil when the update does not touch it.
    var requestedFolder: String? {
        general?.defaultSaveDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func apply(to settings: inout AppSettings) {
        if let g = general {
            if let path = requestedFolder { settings.defaultSaveDirectory = path }
            if let rule = g.defaultFolderRule { settings.defaultFolderRule = rule }
            if let reaction = g.existingFileReaction { settings.existingFileReaction = reaction }
            if let n = g.maxSimultaneousDownloads,
               let at = settings.profiles.firstIndex(where: { $0.name == settings.selectedProfile.name }) {
                settings.profiles[at].maxSimultaneousDownloads = n
            }
        }
        if let b = bittorrent {
            if let mode = b.encryptionMode { settings.btEncryptionMode = mode }
            if let dht = b.dht { settings.btEnableDHT = dht }
            if let pex = b.pex { settings.btEnablePeX = pex }
            if let lpd = b.lpd { settings.btEnableLPD = lpd }
            if let utp = b.utp { settings.btEnableUTP = utp }
            if let del = b.autoDeleteTorrent { settings.btAutoDeleteTorrent = del }
        }
    }
}

extension RemoteSettingsState {
    init(_ s: AppSettings) {
        self.init(
            general: General(defaultSaveDirectory: s.defaultSaveDirectory,
                             defaultFolderRule: s.defaultFolderRule,
                             existingFileReaction: s.existingFileReaction,
                             maxSimultaneousDownloads: s.selectedProfile.maxSimultaneousDownloads,
                             profile: s.selectedProfile.name),
            bittorrent: BitTorrent(encryptionMode: s.btEncryptionMode, dht: s.btEnableDHT,
                                   pex: s.btEnablePeX, lpd: s.btEnableLPD, utp: s.btEnableUTP,
                                   autoDeleteTorrent: s.btAutoDeleteTorrent))
    }
}
