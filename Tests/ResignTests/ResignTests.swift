import XCTest
@testable import Resign

final class ResignTests: XCTestCase {
    func testExtractTeamIDFromCertificateName() {
        XCTAssertEqual(
            DevelopmentTeamService.extractTeamID(from: "Apple Development: John Appleseed (ABCDE12345)"),
            "ABCDE12345"
        )
        XCTAssertEqual(
            DevelopmentTeamService.extractTeamID(from: "Apple Distribution: Team Co (XYZW987654)"),
            "XYZW987654"
        )
        // No trailing parenthesized 10-char alphanumeric group -> nil
        XCTAssertNil(DevelopmentTeamService.extractTeamID(from: "Apple Development: John Appleseed"))
        XCTAssertNil(DevelopmentTeamService.extractTeamID(from: "Apple Development: John (iOS)"))
        XCTAssertNil(DevelopmentTeamService.extractTeamID(from: "Something (AB12)"))
    }

    func testRetryDefaultIsBounded() {
        XCTAssertEqual(AppSettings().maxRetries, 2)
    }

    func testSettingsNormalizationBoundsValues() {
        var settings = AppSettings()
        settings.resignIntervalDays = 99
        settings.scheduleHour = 42
        settings.scheduleMinute = -5
        settings.maxRetries = 100
        settings.retryIntervalMinutes = 0
        settings.buildCooldownSeconds = -1

        let normalized = settings.normalized()
        XCTAssertEqual(normalized.resignIntervalDays, 7)
        XCTAssertEqual(normalized.scheduleHour, 23)
        XCTAssertEqual(normalized.scheduleMinute, 0)
        XCTAssertEqual(normalized.maxRetries, 3)
        XCTAssertEqual(normalized.retryIntervalMinutes, 1)
        XCTAssertEqual(normalized.buildCooldownSeconds, 0)
    }
}
