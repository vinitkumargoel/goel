import XCTest
@testable import GoelCore

final class SettingsBoundsTests: XCTestCase {

    func testClampReportsWhetherTheValueMoved() {
        XCTAssertEqual(SettingsBounds.clamp(5000, to: 1...3600).value, 3600)
        XCTAssertTrue(SettingsBounds.clamp(5000, to: 1...3600).wasClamped)
        XCTAssertFalse(SettingsBounds.clamp(30, to: 1...3600).wasClamped)
        XCTAssertEqual(SettingsBounds.clamp(-2.5, to: 0.0...10).value, 0)
    }

    /// The fields and `validated()` must agree: a value at either end of a bound survives validation,
    /// and one past it is pulled back to the end.
    func testValidationUsesTheSameBoundsTheFieldsShow() {
        var s = AppSettings()
        s.proxyPort = SettingsBounds.proxyPort.upperBound + 10
        s.remotePort = SettingsBounds.remotePort.lowerBound - 1
        s.retryCount = SettingsBounds.retryCount.upperBound
        s.connectionTimeout = SettingsBounds.connectionTimeout.upperBound * 2
        let v = s.validated()
        XCTAssertEqual(v.proxyPort, SettingsBounds.proxyPort.upperBound)
        XCTAssertEqual(v.remotePort, SettingsBounds.remotePort.lowerBound)
        XCTAssertEqual(v.retryCount, SettingsBounds.retryCount.upperBound)
        XCTAssertEqual(v.connectionTimeout, SettingsBounds.connectionTimeout.upperBound)
    }

    func testProfileBoundsMatchProfileValidation() {
        var p = TrafficProfile.medium
        p.maxConnections = SettingsBounds.profileMaxConnections.upperBound + 1
        p.maxSimultaneousDownloads = 0
        let v = p.validated()
        XCTAssertEqual(v.maxConnections, SettingsBounds.profileMaxConnections.upperBound)
        XCTAssertEqual(v.maxSimultaneousDownloads, SettingsBounds.profileMaxSimultaneousDownloads.lowerBound)
    }
}
