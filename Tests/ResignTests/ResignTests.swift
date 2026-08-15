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
        // Each project block must be wrapped in a single-iteration bash loop so
        // `continue` skips the rest of the project instead of erroring out.
        XCTAssertTrue(script.contains("for _ in once; do"))
        XCTAssertTrue(script.contains("done"))

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


    // MARK: - Deterministic failure classification & diagnostics (1.3.0)

    func testFailureClassClassifiesDeterministicErrorsAsFatal() {
        XCTAssertEqual(
            BuildService.failureClass("Failed to install embedded profile for zhengyk.HabitInsight : 0xe8008012 (This provisioning profile cannot be installed on this device.)"),
            .fatal
        )
        XCTAssertEqual(
            BuildService.failureClass("FunctionName = -[MIFreeProfileValidatedAppTracker _onQueue_addReferenceForApplicationIdentifier:bundle:error:]"),
            .fatal
        )
        XCTAssertEqual(
            BuildService.failureClass("The maximum number of apps for free development profiles has been reached"),
            .fatal
        )
        XCTAssertEqual(
            BuildService.failureClass("error: Failed Registering Bundle Identifier: The app identifier \"zhengyk.HabitInsight\" cannot be registered to your development team because it is not available"),
            .fatal
        )
        XCTAssertEqual(
            BuildService.failureClass("error: No Account for Team \"9KXSB4HR69\". Add a new account in Accounts settings"),
            .fatal
        )
        XCTAssertEqual(
            BuildService.failureClass("error: No profiles for 'zhengyk.HabitInsight' were found"),
            .fatal
        )
    }

    func testFailureClassKeepsTransientErrorsRetryable() {
        XCTAssertEqual(BuildService.failureClass("The network connection was lost"), .retryable)
        XCTAssertEqual(BuildService.failureClass("Device is locked"), .retryable)
        XCTAssertEqual(BuildService.failureClass("error: Example.swift:12: type mismatch"), .unknown)
    }

    func testProfileMissingDeviceErrorSummary() {
        let summary = BuildErrorParser.summarize(
            "Failed to install embedded profile for zhengyk.HabitInsight : 0xe8008012 (This provisioning profile cannot be installed on this device.)"
        )
        XCTAssertEqual(summary?.location, "安装")
        XCTAssertTrue(summary?.reason.contains("不在当前 Team 的测试设备列表") == true)
    }

    func testFreeProfileQuotaErrorSummary() {
        let summary = BuildErrorParser.summarize(
            "FunctionName = -[MIFreeProfileValidatedAppTracker _onQueue_addReferenceForApplicationIdentifier:bundle:error:]\n无法安装此App，因为无法验证其完整性。"
        )
        XCTAssertEqual(summary?.location, "安装")
        XCTAssertTrue(summary?.reason.contains("每台设备最多安装 3 个开发 App") == true)
    }

    func testBundleIDUnavailableErrorSummary() {
        let summary = BuildErrorParser.summarize(
            "error: Failed Registering Bundle Identifier: The app identifier \"zhengyk.HabitInsight\" cannot be registered to your development team because it is not available. Change your bundle identifier to a unique string to try again"
        )
        XCTAssertEqual(summary?.location, "签名")
        XCTAssertTrue(summary?.reason.contains("已被另一个开发者账号注册") == true)
    }

    func testNoAccountForTeamErrorSummary() {
        let summary = BuildErrorParser.summarize(
            "error: No Account for Team \"9KXSB4HR69\". Add a new account in Accounts settings or verify that your accounts have valid credentials."
        )
        XCTAssertEqual(summary?.location, "签名")
        XCTAssertTrue(summary?.reason.contains("没有登录 Xcode") == true)
    }

    func testGeneratedScriptStopsRetryingOnFatalInstallError() throws {
        var settings = AppSettings()
        settings.xcodePath = "/Applications/Xcode.app"
        let project = iOSProject(
            name: "Fatal App",
            projectPath: "/tmp/Fatal App.xcodeproj",
            scheme: "Fatal App",
            teamID: "ABCDE12345",
            deviceUDIDs: ["00008140-000A6D6A2143801C"]
        )
        let script = ScheduleService.scriptText(settings: settings, projects: [project])

        XCTAssertTrue(script.contains("is_fatal_install_error"))
        XCTAssertTrue(script.contains("FATAL_ERROR=1"))
        XCTAssertTrue(script.contains("[ \"$FATAL_ERROR\" -eq 0 ]"))
        XCTAssertTrue(script.contains("不再重试"))
        XCTAssertTrue(script.contains("# Resign schedule version: 8"))

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
    }
}
