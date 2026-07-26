import XCTest
@testable import Resign

final class ResignTests: XCTestCase {
    func testScheduleUsesConfiguredCalendarTime() throws {
        var settings = AppSettings()
        settings.scheduleHour = 4
        settings.scheduleMinute = 45

        let plist = ScheduleService.makePlist(
            scriptURL: URL(fileURLWithPath: "/tmp/resign_all.sh"),
            settings: settings
        )
        let calendar = try XCTUnwrap(plist["StartCalendarInterval"] as? [String: Int])

        XCTAssertEqual(calendar["Hour"], 4)
        XCTAssertEqual(calendar["Minute"], 45)
        XCTAssertNil(plist["StartInterval"])
    }

    func testShellQuoteTreatsCommandSyntaxAsData() {
        let input = "Project 'quoted' $(touch /tmp/should-not-run) `id`"
        XCTAssertEqual(
            ScheduleService.shellQuote(input),
            "'Project '\"'\"'quoted'\"'\"' $(touch /tmp/should-not-run) `id`'"
        )
    }

    func testGeneratedScriptIsValidAndRejectsMissingDevices() throws {
        var settings = AppSettings()
        settings.xcodePath = "/Applications/Xcode.app"
        let project = iOSProject(
            name: "Example $(false)",
            projectPath: "/tmp/Example 'quoted'.xcodeproj",
            scheme: "Example",
            deviceUDIDs: []
        )
        let script = ScheduleService.scriptText(settings: settings, projects: [project])

        XCTAssertTrue(script.contains("没有可用设备"))
        XCTAssertTrue(script.contains("RUN_OK=0"))
        XCTAssertTrue(script.contains("StartInterval") == false)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n"]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testOnlyTransientFailuresAreRetried() {
        XCTAssertTrue(BuildService.isTransientFailure("The network connection was lost"))
        XCTAssertTrue(BuildService.isTransientFailure("Device is locked"))
        XCTAssertFalse(BuildService.isTransientFailure("error: no signing certificate found"))
        XCTAssertFalse(BuildService.isTransientFailure("Example.swift:12: error: type mismatch"))
    }

    func testSigningErrorSummary() {
        let summary = BuildErrorParser.summarize("error: No signing certificate found")
        XCTAssertEqual(summary?.location, "签名")
    }

    func testRetryDefaultIsBounded() {
        XCTAssertEqual(AppSettings().maxRetries, 2)
    }
}
