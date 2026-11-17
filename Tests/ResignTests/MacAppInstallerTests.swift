import XCTest
@testable import Resign

final class MacAppInstallerTests: XCTestCase {
    private var root: URL!
    private var applications: URL!
    private var builtApp: URL!
    private var runner: MockProcessRunner!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macinstaller-tests-\(UUID().uuidString)", isDirectory: true)
        applications = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)

        // A fake built .app with payload.
        builtApp = root.appendingPathComponent("built/Demo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: builtApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("newbinary".utf8).write(to: builtApp.appendingPathComponent("Contents/MacOS/Demo"))
        try makeInfoPlist().write(to: builtApp.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)

        runner = MockProcessRunner()
    }

    override func tearDownWithError() throws {
        // Safety net in case an assertion fired before the immutable flag was reset.
        let destination = applications.appendingPathComponent("Demo.app")
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: destination.path)
        try? FileManager.default.removeItem(at: root)
    }

    private var installer: MacAppInstaller {
        MacAppInstaller(runner: runner, applicationsDirectory: applications)
    }

    private func writePayload(_ text: String) throws {
        try Data(text.utf8).write(to: builtApp.appendingPathComponent("Contents/MacOS/Demo"))
    }

    private func installedPayload() -> String? {
        try? String(contentsOf: applications.appendingPathComponent("Demo.app/Contents/MacOS/Demo"), encoding: .utf8)
    }

    private func createInstalledApp(payload: String) throws {
        try FileManager.default.createDirectory(
            at: applications.appendingPathComponent("Demo.app/Contents/MacOS"),
            withIntermediateDirectories: true
        )
        try Data(payload.utf8).write(to: applications.appendingPathComponent("Demo.app/Contents/MacOS/Demo"))
        try makeInfoPlist().write(to: applications.appendingPathComponent("Demo.app/Contents/Info.plist"), atomically: true, encoding: .utf8)
    }

    /// Default fixture; separate tests rename the bundle while keeping the
    /// executable name Demo to cover the differing-name workflow.
    private func makeInfoPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
            <key>CFBundleExecutable</key><string>Demo</string>
            <key>CFBundleIdentifier</key><string>com.resign.test.demo</string>
        </dict></plist>
        """
    }

    private func writeInfo(bundleID: String?, executable: String = "Demo",
                           format: PropertyListSerialization.PropertyListFormat = .xml) throws {
        var info = ["CFBundleExecutable": executable]
        if let bundleID { info["CFBundleIdentifier"] = bundleID }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0)
        try data.write(to: builtApp.appendingPathComponent("Contents/Info.plist"))
    }

    private func enqueueGracefulExit() {
        runner.enqueue(makeProcessResult(exitCode: 0)) // pgrep: running
        runner.enqueue(makeProcessResult(exitCode: 0)) // osascript
        runner.enqueue(makeProcessResult(exitCode: 1)) // pgrep: exited
    }

    func testBundleIdentifierCannotBecomeAppleScriptSource() async throws {
        let payloads = ["com.example.demo\"\nreturn \"injected\"\n--", "com.example.\\\"demo", "-e return 42"]
        var scriptSource: String?
        for (index, payload) in payloads.enumerated() {
            // Both XML entity decoding and binary plists reach the same boundary.
            try writeInfo(bundleID: payload, format: index.isMultiple(of: 2) ? .xml : .binary)
            enqueueGracefulExit()
            let result = await installer.install(appPath: builtApp.path)
            XCTAssertTrue(result.success, result.output)
            let call = try XCTUnwrap(runner.recordedCalls.last { $0.executable == "/usr/bin/osascript" })
            XCTAssertEqual(Array(call.arguments.suffix(3)), ["--", "id", payload])
            XCTAssertFalse(call.arguments[1].contains(payload), "Metadata must never be parsed as script source")
            if let scriptSource { XCTAssertEqual(call.arguments[1], scriptSource) }
            scriptSource = call.arguments[1]
        }
    }

    func testMissingBundleIdentifierUsesAppNameAsDataAndExecutableForProcessLookup() async throws {
        let renamed = builtApp.deletingLastPathComponent().appendingPathComponent("Nice Demo.app")
        try FileManager.default.moveItem(at: builtApp, to: renamed)
        builtApp = renamed
        try writeInfo(bundleID: nil)
        enqueueGracefulExit()
        let result = await installer.install(appPath: builtApp.path)
        XCTAssertTrue(result.success, result.output)
        let call = try XCTUnwrap(runner.recordedCalls.first { $0.executable == "/usr/bin/osascript" })
        XCTAssertEqual(Array(call.arguments.suffix(3)), ["--", "name", "Nice Demo"])
        XCTAssertEqual(runner.calls(to: "pgrep").first?.arguments, ["-x", "--", "Demo"])
    }

    func testExecutableNameIsLiteralForLookupAndTermination() async throws {
        let executable = "-Demo.*+(Test)"
        try writeInfo(bundleID: "com.resign.test.demo", executable: executable)
        runner.enqueue(makeProcessResult(exitCode: 0)) // running
        runner.enqueue(makeProcessResult(exitCode: 0)) // osascript
        runner.enqueue(makeProcessResult(exitCode: 0)) // still running
        runner.enqueue(makeProcessResult(exitCode: 0)) // pkill
        runner.enqueue(makeProcessResult(exitCode: 1)) // exited
        let result = await installer.install(appPath: builtApp.path)
        XCTAssertTrue(result.success, result.output)
        let pattern = NSRegularExpression.escapedPattern(for: executable)
        XCTAssertTrue(runner.calls(to: "pgrep").allSatisfy { $0.arguments == ["-x", "--", pattern] })
        XCTAssertEqual(runner.calls(to: "pkill").first?.arguments, ["-TERM", "-x", "--", pattern])
    }

    // MARK: - Fresh install

    func testFreshInstallCopiesVerifiedApp() async throws {
        runner.enqueue(makeProcessResult(exitCode: 1)) // pgrep: not running
        // copyItem (in-process) + codesign verify succeed via default response

        let outcome = await installer.install(appPath: builtApp.path)

        XCTAssertTrue(outcome.success, outcome.output)
        XCTAssertEqual(installedPayload(), "newbinary")
        // pgrep + codesign（复制用 FileManager，不再依赖外部命令）
        XCTAssertEqual(runner.recordedCalls.count, 2)
    }

    // MARK: - Replace existing

    func testReplacesExistingAppAndCleansUp() async throws {
        try createInstalledApp(payload: "old")
        try writePayload("replaced")

        runner.enqueue(makeProcessResult(exitCode: 1)) // pgrep: not running

        let outcome = await installer.install(appPath: builtApp.path)

        XCTAssertTrue(outcome.success, outcome.output)
        XCTAssertEqual(installedPayload(), "replaced")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: applications.path)
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".") }, "暂存目录不应残留")
    }

    // MARK: - Running instance handling

    func testQuitsRunningInstanceBeforeReplacing() async throws {
        // pgrep#1: running → osascript quit → pgrep#2: exited
        runner.enqueue(makeProcessResult(exitCode: 0)) // pgrep: running
        runner.enqueue(makeProcessResult(exitCode: 0)) // osascript quit
        runner.enqueue(makeProcessResult(exitCode: 1)) // pgrep: gone

        let outcome = await installer.install(appPath: builtApp.path)

        XCTAssertTrue(outcome.success, outcome.output)
        let executables = runner.recordedCalls.map(\.executable)
        XCTAssertTrue(executables.contains("/usr/bin/osascript"))
        XCTAssertFalse(executables.contains("/usr/bin/pkill"), "优雅退出成功后不应强杀")
        XCTAssertTrue(outcome.output.contains("正在运行"))
        let osascript = try XCTUnwrap(runner.recordedCalls.first { $0.executable == "/usr/bin/osascript" })
        XCTAssertEqual(osascript.arguments.first, "-e")
        XCTAssertTrue(osascript.arguments[1].contains("on run argv"))
        XCTAssertFalse(osascript.arguments[1].contains("com.resign.test.demo"))
        XCTAssertEqual(Array(osascript.arguments.suffix(3)), ["--", "id", "com.resign.test.demo"], "必须按 bundle id 精确寻址退出")
    }

    func testSendsTermWhenGracefulQuitFails() async throws {
        // pgrep#1: running → osascript → pgrep#2: still running → pkill → pgrep#3: exited
        runner.enqueue(makeProcessResult(exitCode: 0)) // pgrep: running
        runner.enqueue(makeProcessResult(exitCode: 0)) // osascript
        runner.enqueue(makeProcessResult(exitCode: 0)) // pgrep: still running
        runner.enqueue(makeProcessResult(exitCode: 0)) // pkill
        runner.enqueue(makeProcessResult(exitCode: 1)) // pgrep: gone

        let outcome = await installer.install(appPath: builtApp.path)

        XCTAssertTrue(outcome.success, outcome.output)
        XCTAssertTrue(runner.recordedCalls.contains { call in
            call.executable == "/usr/bin/pkill" && call.arguments.contains("Demo")
        })
    }

    func testAbortsWhenAppRefusesToQuit() async throws {
        // pgrep#1: running → osascript → pgrep#2: still running → pkill → pgrep#3: STILL running
        try createInstalledApp(payload: "old")
        runner.enqueue(makeProcessResult(exitCode: 0)) // pgrep: running
        runner.enqueue(makeProcessResult(exitCode: 0)) // osascript
        runner.enqueue(makeProcessResult(exitCode: 0)) // pgrep: still running
        runner.enqueue(makeProcessResult(exitCode: 0)) // pkill
        runner.enqueue(makeProcessResult(exitCode: 0)) // pgrep: STILL running

        let outcome = await installer.install(appPath: builtApp.path)

        XCTAssertFalse(outcome.success)
        XCTAssertTrue(outcome.output.contains("未能退出"))
        XCTAssertEqual(installedPayload(), "old", "应用拒绝退出时必须中止，绝不替换还在运行的应用")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: applications.path)
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".") }, "中止时暂存目录不应残留")
    }

    // MARK: - Failure paths

    func testSignatureFailureKeepsExistingAppAndCleansStaging() async throws {
        try createInstalledApp(payload: "old")

        runner.enqueue(makeProcessResult(exitCode: 1))                  // pgrep: not running
        runner.enqueue(makeProcessResult(exitCode: 1, stderr: "invalid signature")) // codesign

        let outcome = await installer.install(appPath: builtApp.path)

        XCTAssertFalse(outcome.success)
        XCTAssertTrue(outcome.output.contains("签名校验失败"))
        XCTAssertEqual(installedPayload(), "old", "验签失败必须保留现有安装")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: applications.path)
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".") }, "暂存目录必须清理")
    }

    func testBackupFailureKeepsExistingApp() async throws {
        // An immutable destination makes the backup move fail; the installer
        // must report failure and leave the old app untouched.
        let destination = applications.appendingPathComponent("Demo.app")
        try createInstalledApp(payload: "old")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: destination.path)

        runner.enqueue(makeProcessResult(exitCode: 1)) // pgrep: not running

        let outcome = await installer.install(appPath: builtApp.path)
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: destination.path)

        XCTAssertFalse(outcome.success)
        XCTAssertTrue(outcome.output.contains("无法备份现有应用"))
        XCTAssertEqual(installedPayload(), "old", "备份失败时旧应用必须原样保留")
    }

    func testCleansStagingLeftByCrashedPreviousRun() async throws {
        try FileManager.default.createDirectory(
            at: applications.appendingPathComponent(".Demo.installing.app"),
            withIntermediateDirectories: true
        )
        runner.enqueue(makeProcessResult(exitCode: 1)) // pgrep: not running

        let outcome = await installer.install(appPath: builtApp.path)

        XCTAssertTrue(outcome.success, outcome.output)
        XCTAssertEqual(installedPayload(), "newbinary")
    }

    func testRejectsNonAppBundle() async throws {
        let outcome = await installer.install(appPath: root.appendingPathComponent("notanapp").path)
        XCTAssertFalse(outcome.success)
        XCTAssertTrue(runner.recordedCalls.isEmpty, "名称校验失败不得执行任何命令")
    }
}
