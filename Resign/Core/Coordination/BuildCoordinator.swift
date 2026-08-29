import Foundation

/// One fully-described execution: which project, with which settings, against
/// which snapshot of available devices. `source` records who asked for it.
struct BuildRequest: Sendable {
    let project: iOSProject
    let settings: AppSettings
    let availableDevices: [iOSDevice]
    let source: ExecutionSource
    /// Test hook: overrides the retry policy derived from settings so unit
    /// tests can use zero-interval retries.
    var retryPolicyOverride: RetryPolicy?

    init(
        project: iOSProject,
        settings: AppSettings,
        availableDevices: [iOSDevice],
        source: ExecutionSource,
        retryPolicyOverride: RetryPolicy? = nil
    ) {
        self.project = project
        self.settings = settings
        self.availableDevices = availableDevices
        self.source = source
        self.retryPolicyOverride = retryPolicyOverride
    }
}

struct BuildResult: Sendable {
    let success: Bool
    let output: String
    var failedDeviceUDIDs: [String] = []
    var cancelled: Bool = false
    /// True when the run never started because the cross-process lock was held.
    var lockBlocked: Bool = false
    var deviceOutcomes: [DeviceInstallOutcome] = []

    static func cancelledResult(output: String = "任务已取消") -> BuildResult {
        BuildResult(success: false, output: output, cancelled: true)
    }
}

/// The ONLY build engine. The GUI and the scheduled worker both execute
/// through this coordinator, so device selection, product resolution, retry
/// policy, failure classification, derived-data handling and the cross-process
/// build lock exist exactly once.
struct BuildCoordinator: Sendable {
    let runner: ProcessRunning
    var derivedDataRoot: URL = URL(fileURLWithPath: "/tmp/ResignBuild", isDirectory: true)
    /// Cross-process lock guarding the build area. Both entry points share it.
    var buildLockPath: String = AppPaths.buildLockURL.path

    func execute(_ request: BuildRequest) async -> BuildResult {
        let project = request.project
        if Task.isCancelled { return .cancelledResult() }

        // Cross-process lock: the GUI and the LaunchAgent worker share the same
        // /tmp/ResignBuild/<project UUID> directory and both clear it before
        // building. Without the lock they can tear each other down.
        let lock = FileLock(path: buildLockPath)
        guard lock.acquire() else {
            return BuildResult(
                success: false,
                output: "已有 Resign 任务正在运行（构建锁被占用）。为避免与另一个执行实例互相踩踏构建目录，本次已跳过。",
                lockBlocked: true
            )
        }
        defer { lock.release() }

        if let validationError = XcodeToolchain.validate(xcodePath: request.settings.xcodePath) {
            return BuildResult(success: false, output: validationError)
        }
        guard !project.scheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return BuildResult(success: false, output: "错误：项目尚未选择 Scheme")
        }
        guard FileManager.default.fileExists(atPath: project.projectPath) else {
            return BuildResult(success: false, output: "错误：项目路径不存在：\(project.projectPath)")
        }

        let deviceUDIDs = DeviceSelection.resolveDeviceUDIDs(
            projectUDIDs: project.deviceUDIDs,
            availableDevices: request.availableDevices
        )
        guard !deviceUDIDs.isEmpty else {
            return BuildResult(success: false, output: "错误：未找到可用的已连接设备")
        }

        let derivedData = derivedDataRoot.appendingPathComponent(project.id.uuidString, isDirectory: true)
        do {
            try Self.prepareDerivedData(derivedData, root: derivedDataRoot)
        } catch {
            return BuildResult(success: false, output: "错误：无法准备构建目录：\(error.localizedDescription)")
        }

        let executor = BuildExecutor(runner: runner)
        let baseArguments = BuildExecutor.baseArguments(for: project, derivedDataPath: derivedData.path)
        var fullOutput = ""

        // Locate the expected product up front from build settings so a
        // multi-target project never installs the wrong bundle.
        let settingsResult = await executor.showBuildSettings(arguments: baseArguments, xcodePath: request.settings.xcodePath)
        let expectedProduct = ProductResolver.expectedProductPath(
            fromBuildSettingsJSON: Data(settingsResult.stdout.utf8),
            preferredNames: [project.scheme, project.projectName]
        )
        if settingsResult.exitCode != 0 {
            fullOutput += "=== BUILD SETTINGS ===\n\(settingsResult.combined)\n"
        }

        let retry = request.retryPolicyOverride ?? RetryPolicy(settings: request.settings)
        var buildSucceeded = false
        buildLoop: for attempt in 1...retry.maxAttempts {
            let buildResult = await executor.build(arguments: baseArguments, xcodePath: request.settings.xcodePath)
            let buildOutput = buildResult.combined
            fullOutput += "=== BUILD \(attempt)/\(retry.maxAttempts) ===\n\(buildOutput)\n"

            if Task.isCancelled { return .cancelledResult(output: fullOutput + "\n任务已取消") }
            if buildResult.exitCode == 0 {
                buildSucceeded = true
                break
            }
            switch retry.decision(afterAttempt: attempt, failureClass: FailureClassifier.classify(buildOutput)) {
            case .retryAfter(let seconds):
                fullOutput += "\n检测到临时性构建错误，\(seconds) 秒后重试。\n"
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    return .cancelledResult(output: fullOutput + "\n任务已取消")
                }
            case .stop(let reason):
                fullOutput += "\n⚠️ \(reason)\n"
                break buildLoop
            }
        }
        guard buildSucceeded else {
            return BuildResult(success: false, output: fullOutput)
        }

        let appPath: String?
        if let expectedProduct, FileManager.default.fileExists(atPath: expectedProduct) {
            appPath = expectedProduct
        } else {
            appPath = ProductResolver.mainApp(
                in: derivedData
                    .appendingPathComponent("Build/Products", isDirectory: true)
                    .appendingPathComponent("\(project.configuration)-iphoneos", isDirectory: true),
                preferredNames: [project.scheme, project.projectName]
            )
        }

        guard let appPath else {
            fullOutput += "\n错误：无法确定本次构建生成的主 .app，已停止安装以避免安装错误产物\n"
            return BuildResult(success: false, output: fullOutput)
        }
        fullOutput += "\n本次产物: \(appPath)\n"

        let installer = AppInstaller(runner: runner)
        let outcomes = await installer.install(
            appPath: appPath,
            deviceUDIDs: deviceUDIDs,
            xcodePath: request.settings.xcodePath,
            retry: retry
        )
        for outcome in outcomes {
            fullOutput += outcome.output
        }
        if Task.isCancelled { return .cancelledResult(output: fullOutput + "\n任务已取消") }

        let failedUDIDs = outcomes.filter { !$0.success }.map(\.udid)
        return BuildResult(
            success: failedUDIDs.isEmpty,
            output: fullOutput,
            failedDeviceUDIDs: failedUDIDs,
            deviceOutcomes: outcomes
        )
    }

    /// Clears and recreates a per-project derived-data directory. Deletion is
    /// strictly confined to paths inside the managed root.
    static func prepareDerivedData(_ directory: URL, root: URL) throws {
        let rootPrefix = root.standardizedFileURL.path + "/"
        let target = directory.standardizedFileURL.path
        guard target.hasPrefix(rootPrefix), target.count > rootPrefix.count else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if FileManager.default.fileExists(atPath: target) {
            try FileManager.default.removeItem(atPath: target)
        }
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
    }
}
