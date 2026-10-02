import XCTest
import GoelCore
@testable import GoelApp

final class LinkReviewTests: XCTestCase {

    func testItemsExpandCollapseRepeatsAndUntickDuplicates() {
        let text = """
        https://a.example.com/file[1-2].zip

        https://a.example.com/file1.zip
        not a link
        https://cdn.example.org/movie.mkv
        """
        let items = LinkReview.items(from: text) { source in
            source.locator.hasSuffix("movie.mkv") ? "Completed" : nil
        }
        XCTAssertEqual(items.map(\.name), ["file1.zip", "file2.zip", "movie.mkv"])
        XCTAssertEqual(items.map(\.host), ["a.example.com", "a.example.com", "cdn.example.org"])
        XCTAssertEqual(items.map(\.category), [.archive, .archive, .video])
        XCTAssertEqual(items.map(\.checked), [true, true, false])
        XCTAssertEqual(items[2].duplicateStatus, "Completed")
    }

    func testMagnetNameComesFromDisplayName() {
        let items = LinkReview.items(from: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Ubuntu+ISO") { _ in nil }
        XCTAssertEqual(items.first?.name, "Ubuntu ISO")
        XCTAssertEqual(items.first?.category, .other)
    }

    func testFilterMatchesNameOrHostAndCategory() {
        let items = LinkReview.items(from: "https://a.com/x.zip\nhttps://b.org/song.mp3") { _ in nil }
        XCTAssertEqual(LinkReview.visible(items, query: "b.org", category: nil).map(\.name), ["song.mp3"])
        XCTAssertEqual(LinkReview.visible(items, query: "X.Z", category: nil).map(\.name), ["x.zip"])
        XCTAssertEqual(LinkReview.visible(items, query: "", category: .audio).map(\.name), ["song.mp3"])
        XCTAssertEqual(LinkReview.categories(in: items), [.archive, .audio])
    }

    func testTotalsAndAddTitleSayAtLeastWhileSizesAreUnknown() {
        var items = LinkReview.items(from: "https://a.com/1.zip\nhttps://a.com/2.zip\nhttps://a.com/3.zip") { _ in nil }
        items[0].size = 1_000_000
        items[2].checked = false
        let totals = LinkReview.totals(items)
        XCTAssertEqual(totals, LinkReview.Totals(count: 2, knownBytes: 1_000_000, unknownSizes: 1))
        let title = LinkReview.addTitle(totals, freeBytes: 5_000_000_000)
        XCTAssertTrue(title.hasPrefix("Add 2 · ≥ "), title)
        XCTAssertTrue(title.hasSuffix("free"), title)
        XCTAssertEqual(LinkReview.addTitle(.init(count: 1), freeBytes: nil), "Add 1")
    }

    func testTruncationNoteOnlyWhenSomethingWasCut() {
        XCTAssertNil(LinkReview.truncationNote(shown: 10, total: 10))
        XCTAssertEqual(LinkReview.truncationNote(shown: 500, total: 812), "Showing first 500 of 812 links")
    }

    func testLinkExtractorReportsEveryLinkButDisplaysTheCap() {
        let html = (0..<(LinkExtractor.displayCap + 20))
            .map { "<a href=\"/f\($0).zip\">x</a>" }.joined()
        let base = URL(string: "https://example.com/")!
        XCTAssertEqual(LinkExtractor.extractAll(from: html, baseURL: base).count, LinkExtractor.displayCap + 20)
        XCTAssertEqual(LinkExtractor.extract(from: html, baseURL: base).count, LinkExtractor.displayCap)
    }
}

final class RecentFoldersAndNameTests: XCTestCase {

    func testRecentFoldersAreNewestFirstUniqueCappedAndAbsolute() {
        var list: [String] = []
        for path in ["/a", "/b", "/a", "relative", "/c", "/d", "/e", "/f"] {
            list = RecentFolders.updated(list, adding: path)
        }
        XCTAssertEqual(list, ["/f", "/e", "/d", "/c", "/a"])
    }

    func testRecentFoldersPersistInDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RecentFoldersTests-\(UUID().uuidString)"))
        RecentFolders.remember("/x", in: defaults)
        RecentFolders.remember("/y", in: defaults)
        XCTAssertEqual(RecentFolders.load(defaults), ["/y", "/x"])
    }

    func testExtraFoldersSkipTheFixedOnes() {
        XCTAssertEqual(SaveFolderPicker.extraFolders(recent: ["/D", "/r1", "/c"], current: "/c", fixed: ["/D"]),
                       ["/c", "/r1"])
    }

    func testNameEditKeepsTheExtension() {
        XCTAssertEqual(FileNameEdit.split("a.tar.gz").base, "a.tar")
        XCTAssertEqual(FileNameEdit.split("a.tar.gz").ext, "gz")
        XCTAssertEqual(FileNameEdit.split("README").ext, "")
        XCTAssertEqual(FileNameEdit.name(base: "report-final", original: "doc.pdf"), "report-final.pdf")
        XCTAssertEqual(FileNameEdit.name(base: "  ", original: "doc.pdf"), "doc.pdf")
        XCTAssertEqual(FileNameEdit.name(base: nil, original: "doc.pdf"), "doc.pdf")
        XCTAssertFalse(FileNameEdit.name(base: "../../etc/x", original: "doc.pdf").contains("/"))
    }

    func testExistingFileWarningFollowsTheSetting() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appendingPathComponent("a.zip"))
        XCTAssertNil(FileNameEdit.existingFileWarning(name: "b.zip", in: folder.path, reaction: "rename"))
        XCTAssertTrue(FileNameEdit.existingFileWarning(name: "a.zip", in: folder.path, reaction: "rename")!
            .contains("(1)"))
        XCTAssertTrue(FileNameEdit.existingFileWarning(name: "a.zip", in: folder.path, reaction: "overwrite")!
            .contains("replaced"))
    }
}

final class MediaPresetTests: XCTestCase {

    func testSelectorsAskForOneFileAndRespectTheCap() {
        XCTAssertEqual(MediaPreset.best.formatSelector(maxHeight: 0), "b")
        XCTAssertEqual(MediaPreset.best.formatSelector(maxHeight: 1080), "b[height<=1080]/b")
        XCTAssertEqual(MediaPreset.p720.formatSelector(maxHeight: 1080), "b[height<=720]/b")
        XCTAssertEqual(MediaPreset.audioM4A.formatSelector(maxHeight: 0), "ba[ext=m4a]/ba/b")
        for preset in MediaPreset.allCases {
            XCTAssertFalse(preset.formatSelector(maxHeight: 720).contains("+"), "no merge: \(preset)")
        }
    }

    func testAudioPresetsChainExtractionOnlyWhenNeeded() {
        XCTAssertEqual(MediaPreset.audioMP3.chainedAudio, .mp3)
        XCTAssertNil(MediaPreset.p480.chainedAudio)
        XCTAssertFalse(MediaPreset.needsExtraction(.m4a, downloadedExtension: "M4A"))
        XCTAssertTrue(MediaPreset.needsExtraction(.mp3, downloadedExtension: "webm"))
    }

    func testChainedAudioIsDroppedForFailedOrRemovedDownloads() {
        let kept = UUID(), failed = UUID(), removed = UUID()
        let chain: [UUID: AudioExtractionFormat] = [kept: .mp3, failed: .m4a, removed: .mp3]
        let pruned = MediaPreset.prunedChain(chain, listed: [kept, failed], failed: [failed])
        XCTAssertEqual(pruned, [kept: .mp3])
    }

    func testBestTitleNamesTheCap() {
        XCTAssertEqual(MediaPreset.best.title(maxHeight: 720), "Best ≤ 720p")
        XCTAssertEqual(MediaPreset.best.title(maxHeight: 0), "Best")
    }
}

final class NotificationPlanningTests: XCTestCase {

    private func task(_ name: String, _ status: DownloadStatus) -> DownloadTask {
        DownloadTask(source: .url(URL(string: "https://a.com/\(name)")!), name: name,
                     saveDirectory: "/tmp", status: status)
    }

    func testOneFinishKeepsItsBannerAndSeveralBecomeASummary() {
        let a = NotificationPlanning.Finished(taskID: UUID(), name: "a.zip")
        let b = NotificationPlanning.Finished(taskID: UUID(), name: "b.iso")
        let c = NotificationPlanning.Finished(taskID: UUID(), name: "c.dmg")
        XCTAssertNil(NotificationPlanning.completionBanner(for: []))
        XCTAssertEqual(NotificationPlanning.completionBanner(for: [a]), .single(a))
        XCTAssertEqual(NotificationPlanning.completionBanner(for: [a, b]), .summary(count: 2, body: "a.zip, b.iso"))
        XCTAssertEqual(NotificationPlanning.completionBanner(for: [a, b, c]),
                       .summary(count: 3, body: "a.zip, b.iso and 1 more"))
    }

    func testFailureBodyPrefersAdvice() {
        XCTAssertEqual(NotificationPlanning.failureBody(for: .failed(.httpStatus(404))),
                       FailureAdvice.hint(forHTTPStatus: 404))
        XCTAssertEqual(NotificationPlanning.failureBody(for: .failed(.unknown("boom"))), "boom")
        XCTAssertEqual(NotificationPlanning.failureTitle(name: "x.zip"), "Couldn’t download “x.zip”")
    }

    func testTransitionsIgnoreNewRowsAndRepeatFailures() {
        let done = task("done", .completed)
        let fresh = task("fresh", .completed)
        let broke = task("broke", .failed(.timedOut))
        let still = task("still", .failed(.timedOut))
        let previous: [UUID: DownloadStatus] = [done.id: .downloading, broke.id: .downloading,
                                                still.id: .failed(.checksumMismatch)]
        let result = NotificationPlanning.transitions([done, fresh, broke, still], previous: previous)
        XCTAssertEqual(result.completed.map(\.name), ["done"])
        XCTAssertEqual(result.failed.map(\.name), ["broke"])
    }

    func testFailedAndSummaryBannersMapToResponses() {
        let id = UUID()
        let info: [AnyHashable: Any] = [NotificationService.taskIDKey: id.uuidString]
        XCTAssertEqual(NotificationService.response(actionIdentifier: NotificationService.Action.retry.rawValue,
                                                    categoryIdentifier: NotificationService.failedCategory,
                                                    userInfo: info), .retry(id))
        XCTAssertEqual(NotificationService.response(actionIdentifier: NotificationService.Action.show.rawValue,
                                                    categoryIdentifier: NotificationService.failedCategory,
                                                    userInfo: info), .show(id))
        XCTAssertEqual(NotificationService.response(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier",
                                                    categoryIdentifier: NotificationService.summaryCategory,
                                                    userInfo: [:]), .showWindow)
    }

    func testDockRowsListThreeDownloadingWithPercent() {
        var tasks = (0..<5).map { task("f\($0).zip", .downloading) }
        tasks[0].totalBytes = 200
        tasks[0].bytesDownloaded = 50
        tasks.append(task("p.zip", .paused))
        let rows = DockMenuModel.activeRows(tasks)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].title, "f0.zip — 25%")
        XCTAssertEqual(rows[1].title, "f1.zip")
        XCTAssertTrue(DockMenuModel.hasResumable(tasks))
        XCTAssertTrue(DockMenuModel.hasPausable(tasks))
    }
}
