import XCTest
@testable import Resign

/// End-to-end coordinator tests against a scripted ProcessRunner: verify that
/// ONE build engine produces the same arguments, product resolution, retry
/// decisions, per-device install behaviour and lock semantics for GUI and
/// scheduled execution.
final class BuildCoordinatorTests: XCTestCase {
    private var root: URL!
    private var productsDir: URL!
    private var xcodePath: String!
    private var projectPath: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("coordinator-tests-\(UUID().uuidString)", isDirectory: true)
        productsDir = root.appendingPathComponent("products", isDirectory: true)
        try FileManager.default.createDirectory(at: productsDir, withIntermediateDirectories: true)

        // Fake toolchain so validation never depends on the host machine.
        let bin = root.appendingPathComponent("Xcode.app/Contents/Developer/usr/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let xcodebuild = bin.appendingPathComponent("xcodebuild")
        try Data("#!/bin/sh\n".utf8).write(to: xcodebuild)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcodebuild.path)
        xcodePath = root.appendingPathComponent("Xcode.app").path

        projectPath = root.appendingPathComponent("Demo.xcodeproj").path
        try FileManager.default.createDirectory(atPath: projectPath, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func makeProject(
        scheme: String = "Demo",
        teamID: String? = nil,
        deviceUDIDs: [String] = []
    ) -> iOSProject {
        var project = iOSProject(name: "Demo", projectPath: projectPath, scheme: scheme)
        project.teamID = teamID
        project.deviceUDIDs = deviceUDIDs
        return project
    }

    private func makeSettings() -> AppSettings {
        var settings = AppSettings()
        settings.xcodePath = xcodePath
        return settings
    }

    private func makeDevices() -> [iOSDevice] {
        [
            iOSDevice(udid: "D1", name: "iPhone 15", osVersion: "18.0", connectionType: "USB", isAvailable: true),
            iOSDevice(udid: "D2", name: "iPad Pro", osVersion: "18.0", connectionType: "WiFi", isAvailable: true)
        ]
    }

    @discardableResult
    private func createApp(_ name: String) -> URL {
        let url = productsDir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func buildSettingsJSON(targets: [(target: String, wrapper: String)]) -> ProcessResult {
        let payload: [[String: Any]] = targets.map { target in
            [
                "target": target.target,
                "buildSettings": [
                    "TARGET_BUILD_DIR": productsDir.path,
                    "WRAPPER_NAME": target.wrapper
                ]
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return makeProcessResult(exitCode: 0, stdout: String(data: data, encoding: .utf8)!)
    }

    private func makeCoordinator(
        runner: MockProcessRunner,
        derivedDataRoot: URL? = nil,
        lockPath: String? = nil
    ) -> BuildCoordinator {
        var coordinator = BuildCoordinator(runner: runner)
        coordinator.derivedDataRoot = derivedDataRoot ?? root.appendingPathComponent("derived", isDirectory: true)
        coordinator.buildLockPath = lockPath ?? root.appendingPathComponent("build.lock").path
        return coordinator
    }

    private func makeRequest(
        project: iOSProject,
        settings: AppSettings? = nil,
        devices: [iOSDevice]? = nil,
        retry: RetryPolicy? = nil,
        source: ExecutionSource = .manual
    ) -> BuildRequest {
        BuildRequest(
            project: project,
            settings: settings ?? makeSettings(),
            availableDevices: devices ?? makeDevices(),
            source: source,
            retryPolicyOverride: retry ?? RetryPolicy(maxAttempts: 3, intervalSeconds: 0)
        )
    }

    // MARK: - Happy path

    func testHappyPathResolvesNamedProductAndInstallsAllDevices() async throws {
        let runner = MockProcessRunner()
        let appURL = createApp("Demo.app")
        runner.enqueue(buildSettingsJSON(targets: [("Widget", "Widget.app"), ("Demo", "Demo.app")]))

        let devices = makeDevices()
        let request = makeRequest(project: makeProject(deviceUDIDs: devices.map(\.udid)), devices: devices)
        let result = await makeCoordinator(runner: runner).execute(request)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains(appURL.path))
        XCTAssertEqual(result.failedDeviceUDIDs, [])

        let xcodebuildCalls = runner.calls(to: "xcodebuild")
        // -showBuildSettings + build
        XCTAssertEqual(xcodebuildCalls.count, 2)
        XCTAssertTrue(xcodebuildCalls[1].arguments.contains("build"))
        XCTAssertTrue(xcodebuildCalls[0].arguments.contains("-showBuildSettings"))
        XCTAssertTrue(
            xcodebuildCalls[0].arguments.contains("-derivedDataPath"),
            "必须使用受管 DerivedData 目录"
        )

        let installCalls = runner.calls(to: "xcrun")
        XCTAssertEqual(installCalls.count, 2, "两台设备各安装一次")
        XCTAssertTrue(installCalls.allSatisfy { $0.arguments.contains("devicectl") && $0.arguments.contains("install") })
    }

    func testTeamArgumentInjectedOnlyWhenSet() async throws {
        let runner = MockProcessRunner()
        createApp("Demo.app")
        runner.enqueue(buildSettingsJSON(targets: [("Demo", "Demo.app")]))

        _ = await makeCoordinator(runner: runner).execute(makeRequest(project: makeProject(teamID: "ABCDE12345")))
        XCTAssertTrue(
            runner.calls(to: "xcodebuild").allSatisfy { $0.arguments.contains("DEVELOPMENT_TEAM=ABCDE12345") }
        )

        let plainRunner = MockProcessRunner()
        plainRunner.enqueue(buildSettingsJSON(targets: [("Demo", "Demo.app")]))
        _ = await makeCoordinator(runner: plainRunner).execute(makeRequest(project: makeProject()))
        XCTAssertFalse(
            plainRunner.calls(to: "xcodebuild").contains { $0.arguments.contains { $0.hasPrefix("DEVELOPMENT_TEAM") } }
        )
    }

    // MARK: - Product resolution safety

    func testAmbiguousProductsFailWithoutInstall() async throws {
        let runner = MockProcessRunner()
        createApp("Alpha.app")
        createApp("Beta.app")
        runner.enqueue(buildSettingsJSON(targets: [("Alpha", "Alpha.app"), ("Beta", "Beta.app")]))

        let result = await makeCoordinator(runner: runner).execute(makeRequest(project: makeProject(scheme: "Demo")))

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.contains("无法确定"))
        XCTAssertTrue(runner.calls(to: "xcrun").isEmpty, "产物不明确时绝不能安装")
    }

    func testSchemeNameMatchWinsOverExtensionLikeTargets() async throws {
        let runner = MockProcessRunner()
        createApp("DemoWidget.app")
        createApp("Demo.app")
        runner.enqueue(buildSettingsJSON(targets: [("DemoWidget", "DemoWidget.app"), ("Demo", "Demo.app")]))

        let result = await makeCoordinator(runner: runner).execute(makeRequest(project: makeProject(scheme: "Demo")))

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("Demo.app"))
        XCTAssertFalse(result.output.contains("DemoWidget.app/"), "不能安装扩展产物")
    }

    // MARK: - Retry decisions

    func testFatalBuildErrorStopsImmediately() async throws {
        let runner = MockProcessRunner()
        runner.enqueue(makeProcessResult(exitCode: 0, stdout: "[]"))
        runner.enqueue(makeProcessResult(exitCode: 65, stderr: "error: No Account for Team \"XXXX\""))

        let result = await makeCoordinator(runner: runner).execute(makeRequest(project: makeProject()))

        XCTAssertFalse(result.success)
        XCTAssertEqual(runner.calls(to: "xcodebuild").count, 2, "showBuildSettings + 一次构建；fatal 不重试")
        XCTAssertTrue(runner.calls(to: "xcrun").isEmpty)
    }

    func testUnknownBuildErrorDoesNotRetry() async throws {
        let runner = MockProcessRunner()
        runner.enqueue(makeProcessResult(exitCode: 0, stdout: "[]"))
        runner.enqueue(makeProcessResult(exitCode: 65, stderr: "error: Example.swift:12: type mismatch"))

        let result = await makeCoordinator(runner: runner).execute(makeRequest(project: makeProject()))

        XCTAssertFalse(result.success)
        XCTAssertEqual(runner.calls(to: "xcodebuild").count, 2, "unknown 不应自动重试")
    }

    func testTransientBuildErrorRetriesThenSucceeds() async throws {
        let runner = MockProcessRunner()
        createApp("Demo.app")
        runner.enqueue(buildSettingsJSON(targets: [("Demo", "Demo.app")]))
        runner.enqueue(makeProcessResult(exitCode: 70, stderr: "The network connection was lost"))
        runner.enqueue(makeProcessResult(exitCode: 0, stdout: "BUILD SUCCEEDED"))
        runner.enqueue(makeProcessResult(exitCode: 0))

        let result = await makeCoordinator(runner: runner).execute(makeRequest(project: makeProject()))

        XCTAssertTrue(result.success)
        XCTAssertEqual(runner.calls(to: "xcodebuild").count, 3, "showBuildSettings + 两次构建")
    }

    // MARK: - Multi-device install

    func testOnlyFailedDeviceIsRetried() async throws {
        let runner = MockProcessRunner()
        createApp("Demo.app")
        runner.enqueue(buildSettingsJSON(targets: [("Demo", "Demo.app")]))
        runner.enqueue(makeProcessResult(exitCode: 0, stdout: "BUILD SUCCEEDED"))
        // Round structure per device: D1 ok; D2 fails transiently then succeeds.
        runner.enqueue(makeProcessResult(exitCode: 0))
        runner.enqueue(makeProcessResult(exitCode: 1, stderr: "The network connection was lost"))
        runner.enqueue(makeProcessResult(exitCode: 0))

        let devices = makeDevices()
        let request = makeRequest(project: makeProject(deviceUDIDs: devices.map(\.udid)), devices: devices)
        let result = await makeCoordinator(runner: runner).execute(request)

        XCTAssertTrue(result.success)
        let installCalls = runner.calls(to: "xcrun")
        XCTAssertEqual(installCalls.count, 3, "D1 一次 + D2 两次；成功的设备绝不重装")
        let d1Calls = installCalls.filter { $0.arguments.contains("D1") }
        let d2Calls = installCalls.filter { $0.arguments.contains("D2") }
        XCTAssertEqual(d1Calls.count, 1)
        XCTAssertEqual(d2Calls.count, 2)
    }

    func testFatalInstallErrorStopsThatDeviceOnly() async throws {
        let runner = MockProcessRunner()
        createApp("Demo.app")
        runner.enqueue(buildSettingsJSON(targets: [("Demo", "Demo.app")]))
        runner.enqueue(makeProcessResult(exitCode: 0, stdout: "BUILD SUCCEEDED"))
        runner.enqueue(makeProcessResult(exitCode: 0))
        runner.enqueue(makeProcessResult(exitCode: 1, stderr: "0xe8008012 provisioning profile cannot be installed on this device"))

        let devices = makeDevices()
        let request = makeRequest(project: makeProject(deviceUDIDs: devices.map(\.udid)), devices: devices)
        let result = await makeCoordinator(runner: runner).execute(request)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.failedDeviceUDIDs, ["D2"])
        XCTAssertEqual(runner.calls(to: "xcrun").filter { $0.arguments.contains("D2") }.count, 1, "fatal 设备停止重试")
    }

    // MARK: - Validation & lock

    func testMissingDevicesFailsWithoutBuild() async throws {
        let runner = MockProcessRunner()
        let result = await makeCoordinator(runner: runner)
            .execute(makeRequest(project: makeProject(), devices: [iOSDevice(udid: "X", name: "n", osVersion: "", connectionType: "", isAvailable: false)]))

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.contains("未找到可用的已连接设备"))
        XCTAssertTrue(runner.recordedCalls.isEmpty)
    }

    func testMissingSchemeFailsWithoutBuild() async throws {
        let runner = MockProcessRunner()
        let result = await makeCoordinator(runner: runner).execute(makeRequest(project: makeProject(scheme: "")))

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.contains("Scheme"))
        XCTAssertTrue(runner.recordedCalls.isEmpty)
    }

    func testLockHeldByOtherInstanceBlocksExecution() async throws {
        let lockPath = root.appendingPathComponent("shared-build.lock").path
        let holder = FileLock(path: lockPath)
        XCTAssertTrue(holder.acquire())
        defer { holder.release() }

        let runner = MockProcessRunner()
        let result = await makeCoordinator(runner: runner, lockPath: lockPath)
            .execute(makeRequest(project: makeProject()))

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.lockBlocked)
        XCTAssertTrue(result.output.contains("构建锁被占用"))
        XCTAssertTrue(runner.recordedCalls.isEmpty, "被锁挡下时不得执行任何外部命令")
    }
}
