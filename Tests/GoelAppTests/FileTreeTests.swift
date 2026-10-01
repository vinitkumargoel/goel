import XCTest
@testable import GoelApp

final class FileTreeTests: XCTestCase {

    private let items = [
        FileTreeItem(id: 0, path: "Show/Season 1/e01.mkv", size: 100, done: 50),
        FileTreeItem(id: 1, path: "Show/Season 1/e02.mkv", size: 100, done: 100),
        FileTreeItem(id: 2, path: "Show/Season 1/e01.srt", size: 1),
        FileTreeItem(id: 3, path: "Show/readme.txt", size: 3),
        FileTreeItem(id: 4, path: "Show/Extras/behind.MP4", size: 40),
    ]

    func testBuildsFoldersWithTotalsFoldersFirst() {
        let tree = FileTree.build(items)
        XCTAssertEqual(tree.count, 1)
        let show = tree[0]
        XCTAssertTrue(show.isFolder)
        XCTAssertEqual(show.size, 244)
        XCTAssertEqual(show.done, 150)
        XCTAssertEqual(show.children.map(\.name), ["Extras", "Season 1", "readme.txt"])
        XCTAssertEqual(Set(show.fileIDs), [0, 1, 2, 3, 4])
        XCTAssertEqual(show.children[1].size, 201)
    }

    func testTriStateAndToggle() {
        let season = FileTree.build(items)[0].children[1]
        XCTAssertEqual(FileTree.state(of: season, wanted: []), .off)
        XCTAssertEqual(FileTree.state(of: season, wanted: [0]), .mixed)
        XCTAssertEqual(FileTree.state(of: season, wanted: [0, 1, 2]), .on)
        XCTAssertEqual(FileTree.toggling(season, in: [0, 3]), [0, 1, 2, 3])
        XCTAssertEqual(FileTree.toggling(season, in: [0, 1, 2, 3]), [3])
    }

    func testPresets() {
        XCTAssertEqual(FileTree.applying(.all, to: items), [0, 1, 2, 3, 4])
        XCTAssertEqual(FileTree.applying(.none, to: items), [])
        XCTAssertEqual(FileTree.applying(.onlyVideo, to: items), [0, 1, 4])
        XCTAssertEqual(FileTree.applying(.byExtension(".SRT"), to: items), [2])
        XCTAssertEqual(FileTree.extensionCounts(items).first?.ext, "mkv")
    }

    func testFilterKeepsAncestorsAndRowsFlatten() {
        let filtered = FileTree.filtered(FileTree.build(items), query: "e02")
        let rows = FileTree.rows(filtered, expanded: [], expandAll: true)
        XCTAssertEqual(rows.map(\.node.name), ["Show", "Season 1", "e02.mkv"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2])
        XCTAssertTrue(FileTree.filtered(FileTree.build(items), query: "zzz").isEmpty)
    }

    func testCollapsedFoldersHideChildren() {
        let tree = FileTree.build(items)
        XCTAssertEqual(FileTree.rows(tree, expanded: []).count, 1)
        let open = FileTree.defaultExpanded(tree)
        XCTAssertEqual(FileTree.rows(tree, expanded: open).map(\.node.name), ["Show", "Extras", "Season 1", "readme.txt"])
    }

    func testSameNamedFileAndFolderDoNotCollide() {
        let tree = FileTree.build([FileTreeItem(id: 0, path: "a", size: 1), FileTreeItem(id: 1, path: "a/b", size: 1)])
        XCTAssertEqual(Set(tree.map(\.id)).count, 2)
    }
}
