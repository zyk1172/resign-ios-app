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
        let calendar = try XCTUnwrap(plist["StartCalendarInterval"] as? [String: Any])

        XCTAssertEqual(calendar["Hour"] as? Int, 4)
        XCTAssertEqual(calendar["Minute"] as? Int, 45)
        XCTAssertNil(plist["StartInterval"])
    }

    func testLegacyIntervalScheduleRequiresMigration() {
        var settings = AppSettings()
        settings.scheduleHour = 3
        settings.scheduleMinute = 0
        let scriptURL = URL(fileURLWithPath: "/tmp/resign_all.sh")
        let legacy: [String: Any] = [
            "Label": ScheduleService.label,
            "ProgramArguments": ["/bin/bash", scriptURL.path],
            "StartInterval": 518_400,
            "RunAtLoad": false
        ]

        XCTAssertFalse(
            ScheduleService.isCurrentPlist(legacy, scriptURL: scriptURL, settings: settings)
        )
    }

    func testCurrentScheduleMatchesConfiguredTimeAndScript() {
        var settings = AppSettings()
        settings.scheduleHour = 5
        settings.scheduleMinute = 20
        let scriptURL = URL(fileURLWithPath: "/tmp/resign_all.sh")
        let current = ScheduleService.makePlist(scriptURL: scriptURL, settings: settings)

        XCTAssertTrue(
            ScheduleService.isCurrentPlist(current, scriptURL: scriptURL, settings: settings)
        )

        settings.scheduleMinute = 21
        XCTAssertFalse(
            ScheduleService.isCurrentPlist(current, scriptURL: scriptURL, settings: settings)
        )
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
        XCTAssertTrue(script.contains("INTERVAL_DAYS=6"))
        XCTAssertTrue(script.contains("-v+\"${INTERVAL_DAYS}\"d"))

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

    func testExtractTeamIDFromCertificateName() {
        XCTAssertEqual(
            BuildService.extractTeamID(from: "Apple Development: John Appleseed (ABCDE12345)"),
            "ABCDE12345"
        )
        XCTAssertEqual(
            BuildService.extractTeamID(from: "Apple Distribution: Team Co (XYZW987654)"),
            "XYZW987654"
        )
        // No trailing parenthesized 10-char alphanumeric group -> nil
        XCTAssertNil(BuildService.extractTeamID(from: "Apple Development: John Appleseed"))
        XCTAssertNil(BuildService.extractTeamID(from: "Apple Development: John (iOS)"))
        XCTAssertNil(BuildService.extractTeamID(from: "Something (AB12)"))
    }

    func testScheduleScriptInjectsDevelopmentTeam() throws {
        var settings = AppSettings()
        settings.xcodePath = "/Applications/Xcode.app"
        let withTeam = iOSProject(
            name: "Team App",
            projectPath: "/tmp/Team App.xcodeproj",
            scheme: "Team App",
            teamID: "ABCDE12345"
        )
        let script = ScheduleService.scriptText(settings: settings, projects: [withTeam])

        XCTAssertTrue(script.contains("DEVELOPMENT_TEAM='ABCDE12345'"))

        // The injected signing argument must not break bash syntax.
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/bash")
        check.arguments = ["-n"]
        let input = Pipe()
        check.standardInput = input
        try check.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0)

        let withoutTeam = iOSProject(
            name: "Default App",
            projectPath: "/tmp/Default App.xcodeproj",
            scheme: "Default App"
        )
        let defaultScript = ScheduleService.scriptText(settings: settings, projects: [withoutTeam])
        XCTAssertFalse(defaultScript.contains("DEVELOPMENT_TEAM="))
    }

}
