import XCTest

/// Guards against focus rings that can never draw. `@Environment(\.isFocused)` reports the
/// nearest focusable *ancestor*: read by a view that builds a `Button`, it is the view's own
/// container, not the button, so a ring keyed on it stays off. The value is only the button's
/// inside a `ButtonStyle` body (a view holding a `ButtonStyleConfiguration`); custom plain
/// buttons use `.buttonStyle(.studioPlain)` with `.studioButtonFocusRing(shape:)` instead.
final class FocusRingPlacementTests: XCTestCase {

    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/GoelApp")
    }

    func testIsFocusedIsOnlyReadInsideButtonStyleBodies() throws {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "found no sources under \(appSources.path)")

        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("@Environment(\\.isFocused)")
                && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                if !Self.enclosingStructHoldsButtonConfiguration(lines, line: index) {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "read isFocused in a ButtonStyle body, or use .studioPlain + .studioButtonFocusRing")
    }

    /// The lines from the nearest `struct` above `line` to that struct's first `body` hold a
    /// `ButtonStyleConfiguration` stored property.
    private static func enclosingStructHoldsButtonConfiguration(_ lines: [String], line: Int) -> Bool {
        guard let start = lines[...line].lastIndex(where: { $0.contains("struct ") }) else { return false }
        let end = lines[line...].firstIndex(where: { $0.contains("var body") }) ?? line
        return lines[start...end].contains { $0.contains(": ButtonStyleConfiguration") }
    }
}
