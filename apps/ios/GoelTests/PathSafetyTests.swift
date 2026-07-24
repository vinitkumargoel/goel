import Foundation
import Testing
@testable import Goel

/// The choke point that keeps every Library write inside `Documents/`.
///
/// This is the iOS counterpart of the desktop's `PathSafety.isContained` (PRD §4.2), and it is
/// the *only* place in the app that turns a user-supplied or persisted string into a `URL`. The
/// tests below are the reason it can stay that way: each one is a real escape that a plausible
/// implementation lets through.
///
/// Nothing here touches the filesystem. Path resolution is pure string and component work, so a
/// path does not need to exist to be judged — which matters, because the paths that must be
/// rejected are precisely the ones nobody should ever create.
@Suite("LibraryPathSafety")
struct PathSafetyTests {

    private static var root: URL { LibraryPathSafety.documentsURL }

    /// A synthetic root, so containment is tested against a known shape rather than against
    /// whatever the test host's container happens to be.
    private static let syntheticRoot = URL(fileURLWithPath: "/private/tmp/GoelPathSafety/Documents", isDirectory: true)

    // MARK: - Rejected names

    @Test("A name containing .. is rejected")
    func traversalNameIsRejected() {
        #expect(throws: LibraryPathSafety.PathError.invalidCharacters) {
            try LibraryPathSafety.validatedComponent("..")
        }
        #expect(throws: LibraryPathSafety.PathError.invalidCharacters) {
            try LibraryPathSafety.validatedComponent("../Preferences")
        }
        // The substring is enough. `Goel..escape` cannot traverse on its own, but a name is
        // cheap to retype and a hole here is not cheap to find.
        #expect(throws: LibraryPathSafety.PathError.invalidCharacters) {
            try LibraryPathSafety.validatedComponent("Goel..escape")
        }
    }

    @Test("A name containing a path separator is rejected")
    func separatorNameIsRejected() {
        #expect(throws: LibraryPathSafety.PathError.invalidCharacters) {
            try LibraryPathSafety.validatedComponent("Linux/ISOs")
        }
        #expect(throws: LibraryPathSafety.PathError.invalidCharacters) {
            try LibraryPathSafety.validatedComponent("back\\slash")
        }
        // Files and the Finder both render `:` as `/`. Letting it through moves the traversal
        // one layer down instead of preventing it.
        #expect(throws: LibraryPathSafety.PathError.invalidCharacters) {
            try LibraryPathSafety.validatedComponent("colon:name")
        }
    }

    @Test("An absolute path is rejected")
    func absolutePathIsRejected() {
        #expect(throws: LibraryPathSafety.PathError.escapesContainer) {
            try LibraryPathSafety.resolve("/etc/passwd", within: Self.syntheticRoot)
        }
        #expect(throws: LibraryPathSafety.PathError.escapesContainer) {
            try LibraryPathSafety.resolve("/var/mobile/Library/Preferences", within: Self.syntheticRoot)
        }
        // As a component it is refused earlier, on the leading separator.
        #expect(throws: LibraryPathSafety.PathError.invalidCharacters) {
            try LibraryPathSafety.validatedComponent("/etc/passwd")
        }
    }

    @Test("An empty or all-whitespace name is rejected")
    func blankNameIsRejected() {
        #expect(throws: LibraryPathSafety.PathError.emptyName) {
            try LibraryPathSafety.validatedComponent("")
        }
        #expect(throws: LibraryPathSafety.PathError.emptyName) {
            try LibraryPathSafety.validatedComponent("   \t\n ")
        }
        #expect(throws: LibraryPathSafety.PathError.emptyName) {
            try LibraryPathSafety.resolve("   ", within: Self.syntheticRoot)
        }
    }

    @Test("A symlink-style escape is rejected")
    func compoundTraversalIsRejected() {
        // Standardising collapses this to `<root>/../b`, which is outside the container even
        // though no single component of the input is `..` at the front.
        #expect(throws: LibraryPathSafety.PathError.escapesContainer) {
            try LibraryPathSafety.resolve("a/../../b", within: Self.syntheticRoot)
        }
        #expect(throws: LibraryPathSafety.PathError.escapesContainer) {
            try LibraryPathSafety.resolve("Linux/../../../tmp/evil", within: Self.syntheticRoot)
        }
        #expect(throws: LibraryPathSafety.PathError.escapesContainer) {
            try LibraryPathSafety.resolve("..", within: Self.syntheticRoot)
        }
    }

    // MARK: - Accepted names

    @Test("A normal name resolves inside Documents")
    func normalNameResolvesInsideContainer() throws {
        let resolved = try LibraryPathSafety.resolve("Blender-4.2-macOS-arm64.dmg")
        #expect(LibraryPathSafety.isContained(resolved, within: Self.root))
        #expect(resolved.lastPathComponent == "Blender-4.2-macOS-arm64.dmg")
        #expect(LibraryPathSafety.relativePath(of: resolved) == "Blender-4.2-macOS-arm64.dmg")
    }

    @Test("A nested relative path resolves inside Documents")
    func nestedPathResolvesInsideContainer() throws {
        let resolved = try LibraryPathSafety.resolve("Goel°/Apps/Blender-4.2-macOS-arm64.dmg")
        #expect(LibraryPathSafety.isContained(resolved, within: Self.root))
        #expect(LibraryPathSafety.relativePath(of: resolved) == "Goel°/Apps/Blender-4.2-macOS-arm64.dmg")
    }

    @Test("A name with dots, spaces and non-ASCII survives")
    func ordinaryNamesAreNotOverBlocked() throws {
        // `ubuntu-24.04.1-…` has plenty of dots and no traversal; over-blocking would make the
        // app unable to name the file the mockup shows.
        #expect(try LibraryPathSafety.validatedComponent("ubuntu-24.04.1-desktop-amd64.iso")
                == "ubuntu-24.04.1-desktop-amd64.iso")
        #expect(try LibraryPathSafety.validatedComponent("  Goel° Archive  ") == "Goel° Archive")
        #expect(try LibraryPathSafety.validatedComponent("nas-backup-2026-07-14.tar.zst")
                == "nas-backup-2026-07-14.tar.zst")
    }

    @Test("A leading-dot name is rejected as unreachable")
    func hiddenNameIsRejected() {
        // Hidden files are skipped by the folder listing and by the media scan, so creating one
        // would make a folder the user can never see again.
        #expect(throws: LibraryPathSafety.PathError.invalidCharacters) {
            try LibraryPathSafety.validatedComponent(".hidden")
        }
    }

    // MARK: - Containment

    @Test("Containment compares components, not string prefixes")
    func containmentIsNotAPrefixMatch() {
        let root = URL(fileURLWithPath: "/private/tmp/GoelPathSafety/Documents", isDirectory: true)
        let sibling = URL(fileURLWithPath: "/private/tmp/GoelPathSafety/Documents2/leak", isDirectory: false)
        let child = URL(fileURLWithPath: "/private/tmp/GoelPathSafety/Documents/Goel°/a.dmg", isDirectory: false)

        #expect(LibraryPathSafety.isContained(child, within: root))
        #expect(!LibraryPathSafety.isContained(sibling, within: root))
        // The root is inside itself: the Folders tab starts there.
        #expect(LibraryPathSafety.isContained(root, within: root))
    }

    @Test("The parent of the container is not contained")
    func parentIsNotContained() {
        let root = URL(fileURLWithPath: "/private/tmp/GoelPathSafety/Documents", isDirectory: true)
        #expect(!LibraryPathSafety.isContained(root.deletingLastPathComponent(), within: root))
    }

    // MARK: - Download resolution

    // `LibraryPathSafety.downloadURL` is a two-line forward to `FileStore.destinationURL` — the
    // app's single save-path resolver. These tests assert the *guarantee* the Library depends on
    // (the share sheet is never aimed outside the container), not the mechanism, so they keep
    // holding if `FileStore` changes how it sanitises.

    private static func download(
        filename: String = "Blender-4.2-macOS-arm64.dmg",
        saveDirectory: String
    ) -> Download {
        Download(
            url: URL(fileURLWithPath: "/dev/null"),
            filename: filename,
            saveDirectory: saveDirectory,
            kind: .https,
            status: .completed
        )
    }

    @Test("A relative saveDirectory resolves under Documents")
    func relativeSaveDirectoryResolves() throws {
        let url = try LibraryPathSafety.downloadURL(Self.download(saveDirectory: "Goel°/Apps"))
        #expect(LibraryPathSafety.isContained(url, within: Self.root))
        #expect(LibraryPathSafety.relativePath(of: url) == "Goel°/Apps/Blender-4.2-macOS-arm64.dmg")
    }

    @Test("An empty saveDirectory resolves to the container root")
    func emptySaveDirectoryResolves() throws {
        let url = try LibraryPathSafety.downloadURL(Self.download(saveDirectory: ""))
        #expect(LibraryPathSafety.relativePath(of: url) == "Blender-4.2-macOS-arm64.dmg")
    }

    @Test("An absolute saveDirectory inside the container is honoured")
    func absoluteInContainerSaveDirectoryResolves() throws {
        // `AppModel.apply(_:)` writes the engine's absolute directory back onto the download when
        // it completes, so this is the shape most real records have.
        let directory = Self.root.appending(path: "Goel°/Apps", directoryHint: .isDirectory)
        let url = try LibraryPathSafety.downloadURL(
            Self.download(saveDirectory: directory.path(percentEncoded: false))
        )
        #expect(LibraryPathSafety.isContained(url, within: Self.root))
        #expect(url.lastPathComponent == "Blender-4.2-macOS-arm64.dmg")
    }

    @Test("An absolute saveDirectory outside the container never escapes")
    func absoluteEscapingSaveDirectoryFallsBack() throws {
        // A record persisted by an older build — or by a different container path after a
        // reinstall — must never aim the share sheet outside the sandbox.
        let url = try LibraryPathSafety.downloadURL(
            Self.download(filename: "victim.plist", saveDirectory: "/var/mobile/Library/Preferences")
        )
        #expect(LibraryPathSafety.isContained(url, within: Self.root))
        #expect(LibraryPathSafety.relativePath(of: url) == "victim.plist")
    }

    @Test("A filename carrying a separator or traversal cannot escape")
    func escapingFilenameCannotEscape() throws {
        for name in ["../../escape.dmg", "..", "   ", "..\\..\\escape.dmg", "/etc/passwd"] {
            let url = try LibraryPathSafety.downloadURL(
                Self.download(filename: name, saveDirectory: "Goel°/Apps")
            )
            #expect(
                LibraryPathSafety.isContained(url, within: Self.root),
                "\(name) resolved to \(url.path(percentEncoded: false))"
            )
            #expect(url.lastPathComponent != "..")
        }
    }

    @Test("relativePath refuses a URL outside the container")
    func relativePathRefusesOutsiders() {
        let outsider = URL(fileURLWithPath: "/etc/passwd")
        #expect(LibraryPathSafety.relativePath(of: outsider) == nil)
    }
}
