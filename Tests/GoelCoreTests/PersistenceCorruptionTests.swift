import XCTest
@testable import GoelCore

/// "Move the broken database aside" is offered only for a damaged file, never for one that is merely locked.
final class PersistenceCorruptionTests: XCTestCase {

    func testAFileThatIsNotSQLiteIsCorruption() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-notadb-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        try Data(repeating: 0x41, count: 8192).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try PersistenceStore(path: path)) { error in
            XCTAssertTrue(PersistenceStore.isCorruption(error), String(describing: error))
        }
    }

    func testOtherErrorsAreNot() {
        XCTAssertFalse(PersistenceStore.isCorruption(CocoaError(.fileNoSuchFile)))
        XCTAssertFalse(PersistenceStore.isCorruption(URLError(.timedOut)))
    }
}
