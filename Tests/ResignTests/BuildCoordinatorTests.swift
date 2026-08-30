import XCTest
@testable import Resign

/// End-to-end coordinator tests against a scripted ProcessRunner: verify that
/// ONE build engine produces the same arguments, product resolution, retry
/// decisions, cache behaviour, per-device install behaviour and lock
/// semantics for GUI and scheduled execution.
///
/// 每个 execute 的外部调用顺序（供 mock 队列排布）：
///   1. xcodebuild -version（缓存决策）
///   2. xcodebuild -showBuildSettings
///   3. xcodebuild build（可重试/回退）
///   4. devicectl install（iOS）或 pgrep/codesign（macOS）
final class BuildCoordinatorTests: XCTestCase {
    private var projectRoot: URL!   // 指纹扫描范围（项目父目录）
    private var stateRoot: URL!     // 工作区/缓存（必须在指纹范围之外，否则元数据写入会干扰指纹）
    private var productsDir: URL!
    private var xcodePath: String!
    private var projectPath: String!
    private var cacheDirectory: URL!

    override func setUpWithError() throws {
        projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-proj-\(UUID().uuidString)", isDirectory: true)
        stateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("coord-state-\(UUID().uuidString)", isDirectory: true)
        productsDir = projectRoot.appendingPathComponent("products", isDirectory: true)
        try FileManager.default.createDirectory(at: productsDir, withIntermediateDirectories: true)

        // Fake toolchain so validation never depends on the host machine.
        let bin = projectRoot.appendingPathComponent("Xcode.app/Contents/Developer/usr/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let xcodebuild = bin.appendingPathComponent("xcodebuild")
        try Data("#!/bin/sh\n".utf8).write(to: xcodebuild)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcodebuild.path)
        xcodePath = projectRoot.appendingPathComponent("Xcode.app").path

        projectPath = projectRoot.appendingPathComponent("Demo.xcodeproj").path
        try FileManager.default.createDirectory(atPath: projectPath, withIntermediateDirectories: true)

        cacheDirectory = stateRoot.appendingPathComponent("BuildCache", isDirectory: true)
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectRoot)
        try? FileManager.default.removeItem(at: stateRoot)
    }

    // MARK: - Helpers

    private func makeProject(
        scheme: String = "Demo",
        platform: ProjectPlatform = .ios,
        teamID: String? = nil,
        deviceUDIDs: [String] = []
    ) -> iOSProject {
        var project = iOSProject(name: "Demo", projectPath: projectPath, scheme: scheme)
        project.platform = platform
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
        coordinator.derivedDataRoot = derivedDataRoot ?? stateRoot.appendingPathComponent("derived", isDirectory: true)
        coordinator.buildLockPath = lockPath ?? stateRoot.appendingPathComponent("build.lock").path
        coordinator.buildCacheDirectory = cacheDirectory
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
        runner.enqueueVersion()
        runner.enqueue(buildSettingsJSON(targets: [("Widget", "Widget.app"), ("Demo", "Demo.app")]))

        let devices = makeDevices()
        let request = makeRequest(project: makeProject(deviceUDIDs: devices.map(\.udid)), devices: devices)
        let result = await makeCoordinator(runner: runner).execute(request)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains(appURL.path))
        XCTAssertEqual(result.failedDeviceUDIDs, [])
        XCTAssertEqual(result.builtAppPath, appURL.path, "产物路径必须结构化记录，供执行明细面板使用")
        XCTAssertEqual(result.buildMode, .full, "首次执行应为完整构建")
        XCTAssertTrue(result.output.contains("=== CACHE ==="), "缓存决策必须写入日志")

        let deviceOutcomes = result.deviceOutcomes
        XCTAssertEqual(deviceOutcomes.map(\.attempts), [1, 1], "单次成功各尝试 1 次")

        let xcodebuildCalls = runner.calls(to: "xcodebuild")
        // -version + -showBuildSettings + build
        XCTAssertEqual(xcodebuildCalls.count, 3)
        XCTAssertTrue(xcodebuildCalls[0].arguments.contains("-version"))
        XCTAssertTrue(xcodebuildCalls[1].arguments.contains("-showBuildSettings"))
        XCTAssertTrue(xcodebuildCalls[2].arguments.contains("build"))
        XCTAssertTrue(
            xcodebuildCalls[1].arguments.contains("-derivedDataPath"),
            "必须使用受管 DerivedData 目录"
        )

        let installCalls = runner.calls(to: "xcrun")
        XCTAssertEqual(installCalls.count, 2, "两台设备各安装一次")
        XCTAssertTrue(installCalls.allSatisfy { $0.arguments.contains("devicectl") && $0.arguments.contains("install") })
    }

    func testTeamArgumentInjectedOnlyWhenSet() async throws {
        let runner = MockProcessRunner()
        createApp("Demo.app")
        runner.enqueueVersion()
        runner.enqueue(buildSettingsJSON(targets: [("Demo", "Demo.app")]))

        _ = await makeCoordinator(runner: runner).execute(makeRequest(project: makeProject(teamID: "ABCDE12345")))
        let buildCalls = runner.calls(to: "xcodebuild").filter { !$0.arguments.contains("-version") }
        XCTAssertTrue(buildCalls.allSatisfy { $0.arguments.contains("DEVELOPMENT_TEAM=ABCDE12345") })

        let plainRunner = MockProcessRunner()
        plainRunner.enqueueVersion()
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
        runner.enqueueVersion()
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
        runner.enqueueVersion()
        runner.enqueue(buildSettingsJSON(targets: [("DemoWidget", "DemoWidget.app"), ("Demo", "Demo.app")]))

        let result = await makeCoordinator(runner: runner).execute(makeRequest(project: makeProject(scheme: "Demo")))

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("Demo.app"))
        XCTAssertFalse(result.output.contains("DemoWidget.app/"), "不能安装扩展产物")
    }

    // MARK: - Retry decisions

    func testFatalBuildErrorStopsImmediately() async throws {
        let runner = MockProcessRunner()
        runner.enqueueVersion()
        runner.enqueue(makeProcessResult(exitCode: 0, stdout: "[]"))
        runner.enqueue(makeProcessResult(exitCode: 65, stderr: "error: No Account for Team \"XXXX\""))

        let result = await makeCoordinator(runner: runner).execute(makeRequest(project: makeProject()))

        XCTAssertFalse(result.success)
        XCTAssertEqual(runner.calls(to: "xcodebuild").count, 3, "version + settings + 一次构建；fatal 不重试")
        XCTAssertTrue(runner.calls(to: "xcrun").isEmpty)
    }

    func testUnknownBuildErrorDoesNotRetry() async throws {
        let runner = MockProcessRunner()
        runner.enqueueVersion()
        runner.enqueue(makeProcessResult(exitCode: 0, stdout: "[]"))
        runner.enqueue(makeProcessResult(exitCode: 65, stderr: "error: Example.swift:12: type mismatch"))

        let result = await makeCoordinator(runner: runner).execute(makeRequest(project: makeProject()))

        XCTAssertFalse(result.success)
        XCTAssertEqual(runner.calls(to: "xcodebuild").count, 3, "version + settings + 一次构建；unknown 不应自动重试")
    }

    func testTransientBuildErrorRetriesThenSucceeds() async throws {
        let runner = MockProcessRunner()
        createApp("Demo.app")
        runner.enqueueVersion()
        runner.enqueue(buildSettingsJSON(targets: [("Demo", "Demo.app")]))
        runner.enqueue(makeProcessResult(exitCode: 70, stderr: "The network connection was lost"))
        runner.enqueue(makeProcessResult(exitCode: 0, stdout: "BUILD SUCCEEDED"))
        runner.enqueue(makeProcessResult(exitCode: 0))

        let result = await makeCoordinator(runner: runner).execute(makeRequest(project: makeProject()))

        XCTAssertTrue(result.success)
        XCTAssertEqual(runner.calls(to: "xcodebuild").count, 4, "version + settings + 两次构建")
    }

    // MARK: - Multi-device install

    func testOnlyFailedDeviceIsRetried() async throws {
        let runner = MockProcessRunner()
        createApp("Demo.app")
        runner.enqueueVersion()
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
        runner.enqueueVersion()
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

    func testDeviceOverrideBypassesDefaultSelection() async throws {
        let runner = MockProcessRunner()
        createApp("Demo.app")
        runner.enqueueVersion()
        runner.enqueue(buildSettingsJSON(targets: [("Demo", "Demo.app")]))
        runner.enqueue(makeProcessResult(exitCode: 0, stdout: "BUILD SUCCEEDED"))
        runner.enqueue(makeProcessResult(exitCode: 0))

        // Project has no saved devices and only D1 is available; the explicit
        // "push to this device" target D2 must win over both rules.
        let onlyD1 = [iOSDevice(udid: "D1", name: "iPhone", osVersion: "18.0", connectionType: "USB", isAvailable: true)]
        var request = makeRequest(project: makeProject(), devices: onlyD1)
        request.deviceOverride = ["D2"]

        let result = await makeCoordinator(runner: runner).execute(request)

        XCTAssertTrue(result.success)
        let installCalls = runner.calls(to: "xcrun")
        XCTAssertEqual(installCalls.count, 1)
        XCTAssertTrue(installCalls[0].arguments.contains("D2"))
        XCTAssertFalse(installCalls[0].arguments.contains("D1"))
    }

    // MARK: - macOS platform

    func testMacOSProjectBuildsForMacAndInstallsIntoApplications() async throws {
        let runner = MockProcessRunner()
        let macApplications = stateRoot.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: macApplications, withIntermediateDirectories: true)

        let macProducts = stateRoot.appendingPathComponent("macproducts", isDirectory: true)
        try FileManager.default.createDirectory(at: macProducts.appendingPathComponent("Demo.app/Contents/MacOS"), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: macProducts.appendingPathComponent("Demo.app/Contents/MacOS/Demo"))

        runner.enqueueVersion()
        runner.enqueue(makeProcessResult(exitCode: 0, stdout: String(
            data: try! JSONSerialization.data(withJSONObject: [[
                "target": "Demo",
                "buildSettings": [
                    "TARGET_BUILD_DIR": macProducts.path,
                    "WRAPPER_NAME": "Demo.app"
                ]
            ]]),
            encoding: .utf8)!
        ))
        runner.enqueue(makeProcessResult(exitCode: 0, stdout: "BUILD SUCCEEDED")) // build
        runner.enqueue(makeProcessResult(exitCode: 1))                            // pgrep: not running
        // codesign verify uses the success default

        var coordinator = makeCoordinator(runner: runner)
        coordinator.macInstallDirectory = macApplications
        let result = await coordinator.execute(makeRequest(project: makeProject(platform: .macos)))

        XCTAssertTrue(result.success, result.output)
        XCTAssertTrue(result.output.contains("已安装到"))

        let xcodebuildCalls = runner.calls(to: "xcodebuild")
        XCTAssertEqual(xcodebuildCalls.count, 3)
        XCTAssertTrue(xcodebuildCalls[1].arguments.contains("platform=macOS"), "macOS 项目必须用 macOS destination")
        XCTAssertTrue(runner.calls(to: "xcrun").isEmpty, "macOS 项目不应调用 devicectl")

        let installed = macApplications.appendingPathComponent("Demo.app/Contents/MacOS/Demo")
        XCTAssertEqual(try? String(contentsOf: installed, encoding: .utf8), "binary")
    }

    func testMacOSInstallSignatureFailureKeepsExistingApp() async throws {
        let runner = MockProcessRunner()
        let macApplications = stateRoot.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: macApplications.appendingPathComponent("Demo.app"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: macApplications.appendingPathComponent("Demo.app/marker"))

        // Built product exists so resolution succeeds and install proceeds.
        let macProducts = stateRoot.appendingPathComponent("macproducts", isDirectory: true)
        try FileManager.default.createDirectory(at: macProducts.appendingPathComponent("Demo.app"), withIntermediateDirectories: true)
        let settingsJSON = String(
            data: try! JSONSerialization.data(withJSONObject: [[
                "target": "Demo",
                "buildSettings": [
                    "TARGET_BUILD_DIR": macProducts.path,
                    "WRAPPER_NAME": "Demo.app"
                ]
            ]]),
            encoding: .utf8)!
        runner.enqueueVersion()
        runner.enqueue(makeProcessResult(exitCode: 0, stdout: settingsJSON)) // build settings
        runner.enqueue(makeProcessResult(exitCode: 0))                       // build
        runner.enqueue(makeProcessResult(exitCode: 1))                       // pgrep: not running
        runner.enqueue(makeProcessResult(exitCode: 1, stderr: "invalid signature")) // codesign verify fails

        var coordinator = makeCoordinator(runner: runner)
        coordinator.macInstallDirectory = macApplications
        let result = await coordinator.execute(makeRequest(project: makeProject(platform: .macos)))

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.output.contains("签名校验失败"))
        XCTAssertEqual(
            try? String(contentsOf: macApplications.appendingPathComponent("Demo.app/marker"), encoding: .utf8),
            "old",
            "验签失败时现有安装必须原样保留"
        )
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: macApplications.path)
            .allSatisfy { !$0.hasPrefix(".") }, "暂存目录必须被清理")
    }

    // MARK: - Validation & lock

    func testMissingDevicesFailsWithoutBuild() async throws {
        let runner = MockProcessRunner()
        let result = await makeCoordinator(runner: runner)
            .execute(makeRequest(project: makeProject(), devices: [iOSDevice(udid: "X", name: "n", osVersion: "", connectionType: "", isAvailable: false)]))

        XCTAssertFalse(result.success)
        let probe = FileLock(path: stateRoot.appendingPathComponent("build.lock").path)
        probe.release()

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
        let lockPath = stateRoot.appendingPathComponent("shared-build.lock").path
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

    // MARK: - Signature audit

    func testEmbeddedProfileExpirationParsedFromMobileProvision() throws {
        // mobileprovision = CMS 前缀 + 明文 XML plist + 结尾填充。
        let expiration = Date(timeIntervalSince1970: 1_788_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>ExpirationDate</key><date>\(formatter.string(from: expiration))</date><key>Name</key><string>iOS Team Provisioning Profile</string></dict></plist>
        """
        let payload = Data("binary-cms-noise-prefix".utf8) + Data(xml.utf8) + Data("trailing-signature-bytes".utf8)
        let appDir = stateRoot.appendingPathComponent("audit-app/Demo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        try payload.write(to: appDir.appendingPathComponent("embedded.mobileprovision"))

        let parsed = try XCTUnwrap(
            BuildCoordinator.embeddedProfileExpiration(appPath: appDir.path)
        )
        XCTAssertEqual(parsed.timeIntervalSince1970, expiration.timeIntervalSince1970, accuracy: 1)

        // 无 profile 的 App 返回 nil，不影响执行。
        let bareDir = stateRoot.appendingPathComponent("audit-bare/Bar.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bareDir, withIntermediateDirectories: true)
        XCTAssertNil(BuildCoordinator.embeddedProfileExpiration(appPath: bareDir.path))
    }

    // MARK: - Build cache

    func testUnchangedProjectReusesIncrementalWorkspaceWithoutDeletingIt() async throws {
        let runner = MockProcessRunner()
        createApp("Demo.app")
        let project = makeProject(deviceUDIDs: makeDevices().map(\.udid))
        let devices = makeDevices()
        let request = makeRequest(project: project, devices: devices)
        let coordinator = makeCoordinator(runner: runner)
        let workspace = stateRoot.appendingPathComponent("derived/\(project.id.uuidString)", isDirectory: true)

        // ── 第一次执行：完整构建 ──
        runner.enqueueVersion()
        runner.enqueue(buildSettingsJSON(targets: [("Demo", "Demo.app")]))
        runner.enqueue(makeProcessResult(exitCode: 0, stdout: "BUILD SUCCEEDED"))
        runner.enqueue(makeProcessResult(exitCode: 0)) // D1
        runner.enqueue(makeProcessResult(exitCode: 0)) // D2
        let first = await coordinator.execute(request)
        XCTAssertTrue(first.success, first.output)
        XCTAssertEqual(first.buildMode, .full)

        // 工作区标记文件：如果第二次执行错误地清空工作区，标记会消失。
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("marker".utf8).write(to: workspace.appendingPathComponent("cache.marker"))

        // ── 第二次执行：源码未变化 → 增量复用 ──
        runner.enqueueVersion()
        runner.enqueue(buildSettingsJSON(targets: [("Demo", "Demo.app")]))
        runner.enqueue(makeProcessResult(exitCode: 0, stdout: "BUILD SUCCEEDED"))
        runner.enqueue(makeProcessResult(exitCode: 0)) // D1
        runner.enqueue(makeProcessResult(exitCode: 0)) // D2
        let second = await coordinator.execute(request)

        XCTAssertTrue(second.success, second.output)
        XCTAssertEqual(second.buildMode, .incremental, "指纹未变化时必须复用增量工作区")
        XCTAssertTrue(second.output.contains("项目指纹未变化"))
        XCTAssertTrue(second.output.contains("=== CACHE ==="))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: workspace.appendingPathComponent("cache.marker").path),
            "增量复用绝不能清空工作区"
        )
        XCTAssertEqual(runner.calls(to: "xcodebuild").count, 6, "两次执行：各 version+settings+build")
    }

    func testProductsDirectoryClearedBeforeEveryBuildToForceSigningRefresh() async throws {
        let runner = MockProcessRunner()
        let project = makeProject(deviceUDIDs: ["D1"])
        let workspaceProducts = stateRoot
            .appendingPathComponent("derived/\(project.id.uuidString)/Build/Products/Debug-iphoneos", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceProducts.appendingPathComponent("Old.app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceProducts.appendingPathComponent("Demo.app"), withIntermediateDirectories: true)

        let settingsJSON = String(
            data: try! JSONSerialization.data(withJSONObject: [[
                "target": "Demo",
                "buildSettings": [
                    "TARGET_BUILD_DIR": workspaceProducts.path,
                    "WRAPPER_NAME": "Demo.app"
                ]
            ]]),
            encoding: .utf8)!
        runner.enqueueVersion()
        runner.enqueue(makeProcessResult(exitCode: 0, stdout: settingsJSON))
        // mock 的 build 调用模拟真实行为：重建被清空的产物
        runner.enqueue(
            makeProcessResult(exitCode: 0, stdout: "BUILD SUCCEEDED"),
            sideEffect: { _ in
                try? FileManager.default.createDirectory(
                    at: workspaceProducts.appendingPathComponent("Demo.app"),
                    withIntermediateDirectories: true
                )
            }
        )
        runner.enqueue(makeProcessResult(exitCode: 0)) // D1

        let result = await makeCoordinator(runner: runner).execute(makeRequest(project: project))

        XCTAssertTrue(result.success, result.output)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workspaceProducts.appendingPathComponent("Old.app").path),
            "产物目录必须在每次构建前清空，迫使 xcodebuild 重跑签名阶段（刷新免费签名有效期）"
        )
        XCTAssertEqual(result.builtAppPath, workspaceProducts.appendingPathComponent("Demo.app").path)
    }

    func testCorruptedWorkspaceFallsBackToCleanBuild() async throws {
        let runner = MockProcessRunner()
        createApp("Demo.app")
        let project = makeProject(deviceUDIDs: makeDevices().map(\.udid))
        let devices = makeDevices()
        let request = makeRequest(project: project, devices: devices)
        let coordinator = makeCoordinator(runner: runner)
        let workspace = stateRoot.appendingPathComponent("derived/\(project.id.uuidString)", isDirectory: true)

        // 第一次：成功建立缓存元数据。
        runner.enqueueVersion()
        runner.enqueue(buildSettingsJSON(targets: [("Demo", "Demo.app")]))
        runner.enqueue(makeProcessResult(exitCode: 0, stdout: "BUILD SUCCEEDED"))
        runner.enqueue(makeProcessResult(exitCode: 0))
        runner.enqueue(makeProcessResult(exitCode: 0))
        _ = await coordinator.execute(request)

        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("marker".utf8).write(to: workspace.appendingPathComponent("cache.marker"))

        // 第二次：增量工作区损坏（特征错误）→ 自动清除工作区回退完整构建。
        runner.enqueueVersion()
        runner.enqueue(buildSettingsJSON(targets: [("Demo", "Demo.app")]))
        runner.enqueue(makeProcessResult(exitCode: 65, stderr: "error: no such module 'Foo'"))
        runner.enqueue(makeProcessResult(exitCode: 0, stdout: "BUILD SUCCEEDED"))
        runner.enqueue(makeProcessResult(exitCode: 0)) // D1
        runner.enqueue(makeProcessResult(exitCode: 0)) // D2
        let second = await coordinator.execute(request)

        XCTAssertTrue(second.success, second.output)
        XCTAssertTrue(second.output.contains("回退完整构建"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: workspace.appendingPathComponent("cache.marker").path),
            "回退 clean build 必须清除工作区"
        )
        // version+settings+build ×2 轮 + 回退后的 build = 3+2+1... 精确计数：
        // 第一轮 3 次，第二轮 version+settings+build+build = 4 次，共 7 次。
        XCTAssertEqual(runner.calls(to: "xcodebuild").count, 7)
    }

    func testInstallFailureOnCacheHitStillRecordsFailure() async throws {
        let runner = MockProcessRunner()
        createApp("Demo.app")
        let project = makeProject(deviceUDIDs: makeDevices().map(\.udid))
        let devices = makeDevices()
        let request = makeRequest(project: project, devices: devices)
        let coordinator = makeCoordinator(runner: runner)

        runner.enqueueVersion()
        runner.enqueue(buildSettingsJSON(targets: [("Demo", "Demo.app")]))
        runner.enqueue(makeProcessResult(exitCode: 0, stdout: "BUILD SUCCEEDED"))
        runner.enqueue(makeProcessResult(exitCode: 0))
        runner.enqueue(makeProcessResult(exitCode: 0))
        _ = await coordinator.execute(request)

        // 第二次缓存命中，构建成功但 D2 fatal 安装失败。
        runner.enqueueVersion()
        runner.enqueue(buildSettingsJSON(targets: [("Demo", "Demo.app")]))
        runner.enqueue(makeProcessResult(exitCode: 0, stdout: "BUILD SUCCEEDED"))
        runner.enqueue(makeProcessResult(exitCode: 0))
        runner.enqueue(makeProcessResult(exitCode: 1, stderr: "0xe8008012 provisioning profile cannot be installed"))
        let second = await coordinator.execute(request)

        XCTAssertEqual(second.buildMode, .incremental)
        XCTAssertFalse(second.success)
        XCTAssertEqual(second.failedDeviceUDIDs, ["D2"])
        // 缓存元数据不受安装失败影响（构建本身成功）。
        let metadata = BuildCacheManager.loadMetadata(for: project.id, directory: cacheDirectory)
        XCTAssertEqual(metadata?.buildSucceeded, true)
    }
}
