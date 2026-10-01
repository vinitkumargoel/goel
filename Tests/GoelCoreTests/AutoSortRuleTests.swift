import XCTest
@testable import GoelCore

final class AutoSortRuleTests: XCTestCase {

    private func candidate(_ name: String, url: String = "https://github.com/o/r/releases/download/v1/app.dmg",
                           host: String = "github.com", size: Int64? = nil) -> AutoSortCandidate {
        AutoSortCandidate(fileName: name, url: url, host: host, size: size)
    }

    private func rule(_ conditions: [AutoSortRule.Condition], match: AutoSortRule.Match = .all,
                      enabled: Bool = true) -> AutoSortRule {
        AutoSortRule(name: "r", enabled: enabled, match: match, conditions: conditions)
    }

    func testExtensionIsAnyOfIgnoresDotsCaseAndSeparators() {
        let r = rule([.init(field: .fileExtension, op: .isAnyOf, value: ".DMG, pkg;zip")])
        XCTAssertTrue(r.matches(candidate("Installer.dmg")))
        XCTAssertTrue(r.matches(candidate("tool.PKG")))
        XCTAssertFalse(r.matches(candidate("movie.mkv")))
    }

    func testDomainEndsWithRespectsLabelBoundary() {
        let r = rule([.init(field: .domain, op: .endsWith, value: "example.com")])
        XCTAssertTrue(r.matches(candidate("a", host: "example.com")))
        XCTAssertTrue(r.matches(candidate("a", host: "cdn.example.com")))
        XCTAssertFalse(r.matches(candidate("a", host: "badexample.com")))
    }

    func testTextOperators() {
        XCTAssertTrue(rule([.init(field: .fileName, op: .contains, value: "S01")]).matches(candidate("Show.s01e02.mkv")))
        XCTAssertTrue(rule([.init(field: .fileName, op: .beginsWith, value: "show")]).matches(candidate("Show.s01e02.mkv")))
        XCTAssertTrue(rule([.init(field: .fileName, op: .isEqual, value: "a.iso")]).matches(candidate("A.ISO")))
        XCTAssertTrue(rule([.init(field: .url, op: .contains, value: "/releases/")]).matches(candidate("x")))
    }

    func testRegexMatchesAndInvalidOrHugePatternsNeverMatch() {
        XCTAssertTrue(rule([.init(field: .fileName, op: .matchesRegex, value: #"s\d{2}e\d{2}"#)])
            .matches(candidate("Show.S01E02.mkv")))
        XCTAssertFalse(rule([.init(field: .fileName, op: .matchesRegex, value: "([")]).matches(candidate("a")))
        let huge = String(repeating: "a", count: 600)
        XCTAssertFalse(rule([.init(field: .fileName, op: .matchesRegex, value: huge)]).matches(candidate(huge)))
    }

    func testSizeComparesWithUnitsAndUnknownSizeNeverMatches() {
        let big = rule([.init(field: .size, op: .largerThan, value: "1 GB")])
        XCTAssertTrue(big.matches(candidate("a", size: 2_000_000_000)))
        XCTAssertFalse(big.matches(candidate("a", size: 500_000_000)))
        XCTAssertFalse(big.matches(candidate("a", size: nil)))
        let small = rule([.init(field: .size, op: .smallerThan, value: "10MB")])
        XCTAssertTrue(small.matches(candidate("a", size: 1_000)))
        XCTAssertFalse(small.matches(candidate("a", size: nil)))
    }

    func testParseBytes() {
        XCTAssertEqual(AutoSortRule.Condition.parseBytes("2048"), 2048)
        XCTAssertEqual(AutoSortRule.Condition.parseBytes("1.5 GB"), 1_500_000_000)
        XCTAssertEqual(AutoSortRule.Condition.parseBytes("500k"), 500_000)
        XCTAssertNil(AutoSortRule.Condition.parseBytes("lots"))
        XCTAssertNil(AutoSortRule.Condition.parseBytes("5 parsecs"))
    }

    func testAllVersusAnyAndEmptyOrDisabledRulesNeverMatch() {
        let conds: [AutoSortRule.Condition] = [
            .init(field: .domain, op: .isEqual, value: "github.com"),
            .init(field: .fileExtension, op: .isEqual, value: "zip"),
        ]
        XCTAssertFalse(rule(conds, match: .all).matches(candidate("app.dmg")))
        XCTAssertTrue(rule(conds, match: .any).matches(candidate("app.dmg")))
        XCTAssertFalse(rule([]).matches(candidate("app.dmg")))
        XCTAssertFalse(rule(conds, match: .any, enabled: false).matches(candidate("app.dmg")))
        XCTAssertFalse(rule([.init(field: .fileName, op: .contains, value: "  ")]).matches(candidate("a")))
    }

    func testFirstMatchIsOrderedAndCountIgnoresEnabled() {
        let a = AutoSortRule(name: "a", conditions: [.init(field: .fileExtension, op: .isEqual, value: "dmg")], folder: "/A")
        let b = AutoSortRule(name: "b", conditions: [.init(field: .domain, op: .isEqual, value: "github.com")], folder: "/B")
        XCTAssertEqual(AutoSortRules.firstMatch(in: [a, b], for: candidate("x.dmg"))?.folder, "/A")
        XCTAssertEqual(AutoSortRules.firstMatch(in: [a, b], for: candidate("x.zip"))?.folder, "/B")
        var off = a
        off.enabled = false
        XCTAssertEqual(AutoSortRules.matchCount(of: off, in: [candidate("x.dmg"), candidate("y.dmg"), candidate("z.zip")]), 2)
    }

    func testCandidateFromSourceTakesHostAndLocator() {
        let url = URL(string: "https://Downloads.Example.com/files/a.iso")!
        let c = AutoSortCandidate(source: .url(url), name: "a.iso", size: 10)
        XCTAssertEqual(c.host, "downloads.example.com")
        XCTAssertEqual(c.fileExtension, "iso")
        XCTAssertTrue(c.url.contains("/files/a.iso"))
    }

    func testRulesRoundTripThroughSettingsAndBadRulesDontSinkSettings() throws {
        var settings = AppSettings()
        settings.autoSortRules = [AutoSortRule(name: "a", conditions: [.init(field: .size, op: .largerThan, value: "1GB")],
                                               folder: "~/Big", tag: "big", whenDone: WhenDone(.reveal))]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.autoSortRules, settings.autoSortRules)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["autoSortRules"] = [["bogus": true]]
        let broken = try JSONSerialization.data(withJSONObject: json)
        let recovered = try JSONDecoder().decode(AppSettings.self, from: broken)
        XCTAssertEqual(recovered.autoSortRules, [])
        XCTAssertEqual(recovered.defaultFolderRule, settings.defaultFolderRule)
    }

    func testWhenDoneActionableNeedsTargetsWhereRequired() {
        XCTAssertFalse(WhenDone.nothing.isActionable)
        XCTAssertTrue(WhenDone(.open).isActionable)
        XCTAssertFalse(WhenDone(.moveTo).isActionable)
        XCTAssertFalse(WhenDone(.runScript, target: "").isActionable)
        XCTAssertTrue(WhenDone(.openWith, target: "/Applications/IINA.app").isActionable)
    }

    func testRuleFolderRequiresAbsolutePath() {
        XCTAssertNil(DownloadManager.ruleFolder("relative/dir"))
        XCTAssertEqual(DownloadManager.ruleFolder("/Volumes/NAS"), "/Volumes/NAS")
        XCTAssertEqual(DownloadManager.ruleFolder("~/Big"), ("~/Big" as NSString).expandingTildeInPath)
    }

    func testApplyingRuleAddsTagCapAndOnlyRaisesDefaultPriority() {
        let task = DownloadTask(source: .url(URL(string: "https://a.b/c.zip")!), name: "c.zip",
                                saveDirectory: "/tmp", tags: ["keep"])
        let r = AutoSortRule(name: "r", conditions: [], tag: "zips", speedLimitBytesPerSec: 1_000, priority: .high)
        let applied = DownloadManager.applying(r, to: task, callerPriority: .normal)
        XCTAssertEqual(applied.tags, ["keep", "zips"])
        XCTAssertEqual(applied.speedLimitBytesPerSec, 1_000)
        XCTAssertEqual(applied.priority, .high)
        let explicit = DownloadManager.applying(r, to: task, callerPriority: .low)
        XCTAssertEqual(explicit.priority, task.priority)
    }

    func testCatastrophicRegexGivesUpQuicklyAndCountsAsNoMatch() {
        let evil = rule([.init(field: .fileName, op: .matchesRegex, value: "(a+)+$")])
        let name = String(repeating: "a", count: 5_000) + "!"
        let started = Date()
        XCTAssertFalse(evil.matches(candidate(name)))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        // The history preview runs the same bounded match over every entry.
        let history = Array(repeating: candidate(name), count: 5)
        let previewStarted = Date()
        XCTAssertEqual(AutoSortRules.matchCount(of: evil, in: history), 0)
        XCTAssertLessThan(Date().timeIntervalSince(previewStarted), 2.0)
    }

    func testBacktrackingWithinTheLengthCapStopsAtTheDeadline() {
        // Short enough to be evaluated, long enough that `(a+)+$` backtracks for far longer than 1 s.
        let name = String(repeating: "a", count: 40) + "!"
        let started = Date()
        XCTAssertFalse(RuleRegex.matches(pattern: "(a+)+$", in: name))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    func testRegexCacheAndHaystackCap() {
        XCTAssertTrue(RuleRegex.compiled("abc") === RuleRegex.compiled("abc"))
        let tail = String(repeating: "x", count: RuleRegex.maxHaystackLength) + "needle"
        XCTAssertFalse(RuleRegex.matches(pattern: "needle", in: tail), "past the cap is never read")
        XCTAssertFalse(RuleRegex.matches(pattern: "^x+", in: tail), "over-long text never matches")
        XCTAssertTrue(RuleRegex.matches(pattern: "^x+", in: String(tail.prefix(RuleRegex.maxHaystackLength))))
    }

    func testExtractableKindsAndCommands() {
        XCTAssertEqual(DownloadManager.extractableArchiveKind(for: "/x/a.ZIP"), "zip")
        XCTAssertEqual(DownloadManager.extractableArchiveKind(for: "/x/a.tar.gz"), "tar")
        XCTAssertEqual(DownloadManager.extractableArchiveKind(for: "/x/a.tgz"), "tar")
        XCTAssertEqual(DownloadManager.extractableArchiveKind(for: "/x/a.7z"), "7z")
        XCTAssertEqual(DownloadManager.extractableArchiveKind(for: "/x/a.rar"), "rar")
        XCTAssertNil(DownloadManager.extractableArchiveKind(for: "/x/a.dmg"))
    }

    func testDeclaredBytesSumsTheListingAndCapIsBounded() {
        let listing = """
        drwxr-xr-x  0 me     staff       0 Jan  1  2020 dir/
        -rw-r--r--  0 me     staff    1500 Jan  1  2020 dir/a.txt
        -rw-r--r--  0 me     staff    2500 Jan  1  2020 b.bin
        garbage line
        """
        XCTAssertEqual(ArchiveExtractor.declaredBytes(inListing: listing), 4_000)
        XCTAssertEqual(ArchiveExtractor.sizeCap(freeBytes: nil), ArchiveExtractor.absoluteCap)
        XCTAssertEqual(ArchiveExtractor.sizeCap(freeBytes: 500_000_000_000), ArchiveExtractor.absoluteCap)
        XCTAssertEqual(ArchiveExtractor.sizeCap(freeBytes: 12_000_000_000), 10_000_000_000)
        XCTAssertEqual(ArchiveExtractor.sizeCap(freeBytes: 1_000), 0)
    }

    private func makeZip() throws -> (root: String, archive: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let src = (root as NSString).appendingPathComponent("src")
        try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
        try Data(repeating: 65, count: 10_000).write(to: URL(fileURLWithPath: (src as NSString).appendingPathComponent("a.txt")))
        let archive = (root as NSString).appendingPathComponent("pack.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        zip.arguments = ["-c", "-a", "-f", archive, "-C", src, "a.txt"]
        try zip.run()
        zip.waitUntilExit()
        return (root, archive)
    }

    func testExtractStagesThenMovesIntoAFreshFolder() throws {
        let (root, archive) = try makeZip()
        defer { try? FileManager.default.removeItem(atPath: root) }
        guard case .extracted(let first) = ArchiveExtractor.extract(archive, into: root) else {
            return XCTFail("zip did not extract")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: (first as NSString).appendingPathComponent("a.txt")))
        guard case .extracted(let second) = ArchiveExtractor.extract(archive, into: root) else {
            return XCTFail("second extract failed")
        }
        XCTAssertNotEqual(first, second, "an earlier extraction is never merged into")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root).filter { $0.hasPrefix(".goel-extract-") }
        XCTAssertEqual(leftovers, [])
    }

    func testExtractRefusesAnArchiveOverTheCap() throws {
        let (root, archive) = try makeZip()
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertEqual(ArchiveExtractor.extract(archive, into: root, cap: 1_000), .tooLarge(cap: 1_000))
        let contents = try FileManager.default.contentsOfDirectory(atPath: root)
        XCTAssertFalse(contents.contains { $0.hasPrefix(".goel-extract-") || $0.hasSuffix("extracted") })
    }

    func testMoveRenamesOnCollisionAndStaysContained() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let src = (root as NSString).appendingPathComponent("src")
        let dst = (root as NSString).appendingPathComponent("dst")
        try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dst, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let file = (src as NSString).appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        try Data("y".utf8).write(to: URL(fileURLWithPath: (dst as NSString).appendingPathComponent("a.txt")))
        let moved = DownloadManager.move(from: file, into: dst, name: "a.txt", policy: "rename")
        XCTAssertNotNil(moved)
        XCTAssertNotEqual(moved, "a.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
        XCTAssertNil(DownloadManager.move(from: file, into: dst, name: "a.txt", policy: "rename"))
    }
}
