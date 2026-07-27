import XCTest
import GoelCore
@testable import GoelApp

/// The clipboard's guards are what stand between a paste and an unbounded or
/// destructive operation, so they are tested directly rather than through the UI.
final class SFTPClipboardTests: XCTestCase {

    private let serverA = UUID()
    private let serverB = UUID()

    private func entry(_ name: String, isDirectory: Bool = false) -> SFTPEntry {
        SFTPEntry(name: name, isDirectory: isDirectory, size: 10, modified: nil, permissions: 0o644)
    }

    private func clip(_ operation: SFTPClipboard.Operation, directory: String,
                      _ entries: [SFTPEntry], server: UUID? = nil) -> SFTPClipboard {
        SFTPClipboard(operation: operation, connectionID: server ?? serverA,
                      directory: directory, items: entries)
    }

    func testSourcePathsAreBuiltFromTheCopiedDirectoryNotTheCurrentOne() {
        let c = clip(.copy, directory: "/srv/data", [entry("notes.txt")])
        // The browser may have navigated away since the copy; the path must still
        // resolve against where the items actually live.
        XCTAssertEqual(c.sourcePath(c.items[0]), "/srv/data/notes.txt")
    }

    func testCuttingAndPastingIntoTheSameFolderIsANoOp() {
        let c = clip(.cut, directory: "/srv/data", [entry("notes.txt")])
        XCTAssertTrue(c.isSelfMove(toConnection: serverA, directory: "/srv/data"))
        XCTAssertFalse(c.isSelfMove(toConnection: serverA, directory: "/srv/other"))
        // Same path, different server, is a real cross-server move.
        XCTAssertFalse(c.isSelfMove(toConnection: serverB, directory: "/srv/data"))
    }

    func testCopyingIntoTheSameFolderIsAllowed() {
        // Unlike a cut, this is a duplicate — it must not be suppressed.
        let c = clip(.copy, directory: "/srv/data", [entry("notes.txt")])
        XCTAssertFalse(c.isSelfMove(toConnection: serverA, directory: "/srv/data"))
    }

    func testPastingAFolderIntoItselfIsRefused() {
        let folder = entry("project", isDirectory: true)
        let c = clip(.copy, directory: "/srv", [folder])
        XCTAssertTrue(c.wouldRecurse(folder, intoConnection: serverA, directory: "/srv/project"))
        XCTAssertTrue(c.wouldRecurse(folder, intoConnection: serverA, directory: "/srv/project/sub/deep"))
    }

    func testPastingAFolderBesideItselfIsAllowed() {
        let folder = entry("project", isDirectory: true)
        let c = clip(.copy, directory: "/srv", [folder])
        XCTAssertFalse(c.wouldRecurse(folder, intoConnection: serverA, directory: "/srv/elsewhere"))
        // A sibling whose name merely starts with the source name is not inside it.
        XCTAssertFalse(c.wouldRecurse(folder, intoConnection: serverA, directory: "/srv/project-archive"))
    }

    func testTheSamePathOnAnotherServerIsNotRecursion() {
        let folder = entry("project", isDirectory: true)
        let c = clip(.copy, directory: "/srv", [folder])
        XCTAssertFalse(c.wouldRecurse(folder, intoConnection: serverB, directory: "/srv/project"))
    }

    func testFilesCannotRecurse() {
        let file = entry("notes.txt")
        let c = clip(.copy, directory: "/srv", [file])
        XCTAssertFalse(c.wouldRecurse(file, intoConnection: serverA, directory: "/srv/notes.txt"))
    }

    func testPasteLabelNamesASingleItemAndCountsMany() {
        XCTAssertEqual(clip(.copy, directory: "/a", [entry("one.txt")]).pasteLabel,
                       "Paste “one.txt”")
        XCTAssertEqual(clip(.copy, directory: "/a", [entry("a"), entry("b")]).pasteLabel,
                       "Paste 2 Items")
    }
}
