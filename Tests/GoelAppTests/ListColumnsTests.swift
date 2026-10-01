import XCTest
@testable import GoelApp

final class ListColumnsTests: XCTestCase {

    func testEmptyStorageMeansDefaultsAndDashMeansNone() {
        XCTAssertEqual(ListColumnPrefs.decode(""), ListColumn.defaults)
        XCTAssertEqual(ListColumnPrefs.decode("-"), [])
        XCTAssertEqual(ListColumnPrefs.encode([]), "-")
    }

    func testRoundTripIsStableAndIgnoresUnknown() {
        let set: Set<ListColumn> = [.eta, .size, .savePath]
        let raw = ListColumnPrefs.encode(set)
        XCTAssertEqual(raw, "size,eta,savePath")
        XCTAssertEqual(ListColumnPrefs.decode(raw + ",bogus"), set)
    }

    func testToggleAddsAndRemoves() {
        var raw = ""
        raw = ListColumnPrefs.toggling(.eta, in: raw)
        XCTAssertTrue(ListColumnPrefs.decode(raw).contains(.eta))
        XCTAssertTrue(ListColumnPrefs.decode(raw).isSuperset(of: ListColumn.defaults))
        raw = ListColumnPrefs.toggling(.eta, in: raw)
        XCTAssertEqual(ListColumnPrefs.decode(raw), ListColumn.defaults)
    }

    func testDefaultChoiceKeepsWidthLayoutUnchanged() {
        for width: CGFloat in [0, 500, 700, 1200] {
            let chosen = DownloadColumns(scale: 1, listWidth: width)
            XCTAssertEqual(chosen.layout, DownloadColumns.layout(for: width, columns: DownloadColumns()))
            XCTAssertTrue(chosen.extras.isEmpty)
        }
    }

    func testUnchosenCoreColumnsFreeRoomForTheName() {
        let all = DownloadColumns(scale: 1, listWidth: 700)
        XCTAssertEqual(all.layout, .noAdded)
        let slim = DownloadColumns(scale: 1, listWidth: 700, chosen: [.status, .speed, .added])
        XCTAssertFalse(slim.showsSize)
        XCTAssertTrue(slim.showsAdded)
    }

    func testExtrasShedByPriorityWhenNarrow() {
        let chosen = ListColumn.defaults.union([.eta, .ratio, .savePath])
        let wide = DownloadColumns(scale: 1, listWidth: 2000, chosen: chosen)
        XCTAssertEqual(wide.extras, [.eta, .ratio, .savePath])
        let medium = DownloadColumns(scale: 1, listWidth: 900, chosen: chosen)
        XCTAssertEqual(medium.extras, [.eta, .ratio])
        let narrow = DownloadColumns(scale: 1, listWidth: 420, chosen: chosen)
        XCTAssertTrue(narrow.extras.isEmpty)
        XCTAssertEqual(DownloadColumns(scale: 1, listWidth: 0, chosen: chosen).extras, [.eta, .ratio, .savePath])
    }

    func testExtrasNeverSqueezeNameBelowMinimum() {
        let chosen = Set(ListColumn.allCases)
        for width in stride(from: CGFloat(400), through: 2400, by: 37) {
            let columns = DownloadColumns(scale: 1, listWidth: width, chosen: chosen)
            let extras = columns.extras.reduce(CGFloat(0)) { $0 + columns.width(of: $1) + DownloadColumns.cellPadding }
            if !columns.extras.isEmpty {
                XCTAssertGreaterThanOrEqual(width - columns.coreWidth - extras, DownloadColumns.minimumNameWidth)
            }
        }
    }

    func testDensityToggles() {
        XCTAssertEqual(ListDensity.regular.toggled, .compact)
        XCTAssertLessThanOrEqual(ListDensity.compact.rowHeight, 24)
    }
}
