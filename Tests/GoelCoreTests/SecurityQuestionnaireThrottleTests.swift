import Foundation
import XCTest
@testable import GoelCore

/// Guards §4.4 (brute-force protection) of `docs/compliance/security-questionnaire.md`, which quotes hard numbers from code and has drifted from them once already.
final class SecurityQuestionnaireThrottleTests: XCTestCase {

    private func bruteForceAnswer() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GoelCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
        let doc = root.appendingPathComponent("docs/compliance/security-questionnaire.md")
        guard let text = try? String(contentsOf: doc, encoding: .utf8) else {
            throw XCTSkip("security-questionnaire.md is not present in this checkout")
        }
        let start = try XCTUnwrap(text.range(of: "**4.4 "), "questionnaire has no §4.4")
        let end = try XCTUnwrap(text.range(of: "**4.5 "), "questionnaire has no §4.5")
        return String(text[start.lowerBound..<end.lowerBound])
    }

    func testQuestionnaireStatesTheShippedThrottleDefaults() throws {
        let shipped = RemoteLoginThrottle(settings: AppSettings())
        XCTAssertEqual(shipped.freeAttempts, 5,
                       "free attempts changed — update questionnaire §4.4")
        XCTAssertEqual(shipped.baseDelay, 5,
                       "first lockout changed — update questionnaire §4.4")
        XCTAssertEqual(shipped.maxDelay, 15 * 60,
                       "backoff ceiling changed — update questionnaire §4.4")

        let answer = try bruteForceAnswer()
        XCTAssertTrue(answer.contains("five free attempts"), "§4.4 lost the free-attempt count")
        XCTAssertTrue(answer.contains("five-second"), "§4.4 lost the first-lockout duration")
        XCTAssertTrue(answer.contains("fifteen-minute"), "§4.4 lost the backoff ceiling")
    }

    func testQuestionnaireNoLongerDescribesTheRetiredGlobalLockout() throws {
        let answer = try bruteForceAnswer()
        XCTAssertFalse(answer.localizedCaseInsensitiveContains("30-second"),
                       "§4.4 describes the fixed 30-second lockout that commit 6075b42 removed")
        XCTAssertTrue(answer.contains("per client address"),
                      "§4.4 must say the lockout is per-IP, not global")
    }
}
