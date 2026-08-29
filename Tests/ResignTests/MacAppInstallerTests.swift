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
    }

    func testSendsTermWhenGracefulQuitFails() async throws {
        // pgrep#1: running → osascript → pgrep#2: still running → pkill
        runner.enqueue(makeProcessResult(exitCode: 0)) // pgrep: running
        runner.enqueue(makeProcessResult(exitCode: 0)) // osascript
        runner.enqueue(makeProcessResult(exitCode: 0)) // pgrep: still running

        _ = await installer.install(appPath: builtApp.path)

        XCTAssertTrue(runner.recordedCalls.contains { call in
            call.executable == "/usr/bin/pkill" && call.arguments.contains("Demo")
        })
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
