import XCTest

/// Guards against text that ignores the text-size setting. `.font(.system(size:))` draws at a
/// fixed point size; `.scaledFont(size:)` follows the setting. A deliberate fixed size carries a
/// `// fixed-size:` comment with its reason on the line above.
final class FontScalingDriftTests: XCTestCase {

    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/GoelApp")
    }

    func testNoFixedSystemFontSizesOutsideMarkedExceptions() throws {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "found no sources under \(appSources.path)")

        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains(".font(.system(size:") {
                let marked = line.contains("// fixed-size:")
                    || (index > 0 && lines[index - 1].contains("// fixed-size:"))
                if !marked {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "use .scaledFont(size:) or mark the line with // fixed-size: <reason>")
    }
}
