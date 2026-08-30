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
    /// Test hook: overrides the retry policy derived from settings so unit
    /// tests can use zero-interval retries.
    var deviceOverride: [String]?

    init(
        project: iOSProject,
        settings: AppSettings,
        availableDevices: [iOSDevice],
        source: ExecutionSource,
        retryPolicyOverride: RetryPolicy? = nil,
        deviceOverride: [String]? = nil
    ) {
        self.project = project
        self.settings = settings
        self.availableDevices = availableDevices
        self.source = source
        self.retryPolicyOverride = retryPolicyOverride
        self.deviceOverride = deviceOverride
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
    /// 本次解析/生成出来的主 .app 产物路径（安装失败时也可能存在）。
    var builtAppPath: String? = nil
    /// 构建方式（完整/增量），来自缓存决策。
    var buildMode: BuildMode? = nil

    static func cancelledResult(output: String = "任务已取消") -> BuildResult {
        BuildResult(success: false, output: output, cancelled: true)
    }
}

/// The ONLY build engine. The GUI and the scheduled worker both execute
/// through this coordinator, so device selection, product resolution, cache
/// decisions, retry policy, failure classification, derived-data handling and
/// the cross-process build lock exist exactly once.
///
/// 构建缓存（v1.6）：
/// - 工作区（DerivedData）默认**保留**，位于 Application Support，Xcode 自行
///   增量编译——源码未变化时编译阶段被完全跳过；
/// - 每次构建前清空本配置的产物目录（*.app），强制 xcodebuild 重建产物并
///   **重跑签名阶段**——这是免费签名 7 天有效期得以刷新的保证（直接重装
///   旧签名 .app 不会刷新 profile 有效期，因此不做产物级复用）；
/// - 指纹/决策/元数据见 ProjectFingerprintService 与 BuildCacheManager。
struct BuildCoordinator: Sendable {
    let runner: ProcessRunning
    var derivedDataRoot: URL = AppPaths.buildWorkspacesDirectory
    /// Cross-process lock guarding the build area. Both entry points share it.
    var buildLockPath: String = AppPaths.buildLockURL.path
    /// Where macOS projects get installed (injectable for tests).
    var macInstallDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    /// 构建缓存元数据目录（injectable for tests）。
    var buildCacheDirectory: URL = AppPaths.buildCacheDirectory

    /// Where a finished run installs: paired devices (iOS) or this Mac (macOS).
    private enum InstallPlan: Sendable {
        case devices([String])
        case localMac
    }

    func execute(_ request: BuildRequest) async -> BuildResult {
        let project = request.project
        if Task.isCancelled { return .cancelledResult() }

        // Cross-process lock: the GUI and the LaunchAgent worker share the same
        // workspace directories and both mutate the cache metadata. Without the
        // lock they can tear each other down.
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

        let installPlan: InstallPlan
        switch project.platform {
        case .macos:
            installPlan = .localMac
        case .ios:
            let deviceUDIDs = request.deviceOverride ?? DeviceSelection.resolveDeviceUDIDs(
                projectUDIDs: project.deviceUDIDs,
                availableDevices: request.availableDevices
            )
            guard !deviceUDIDs.isEmpty else {
                return BuildResult(success: false, output: "错误：未找到可用的已连接设备")
            }
            installPlan = .devices(deviceUDIDs)
        }

        // ── 缓存决策（GUI 与 Worker 共用同一逻辑）──
        var fingerprint: String?
        do {
            fingerprint = try await Task.detached(priority: .userInitiated) {
                try ProjectFingerprintService.fingerprint(of: project)
            }.value
        } catch {
            fingerprint = nil
        }

        let versionResult = await runner.run(
            XcodeToolchain.xcodebuildPath(xcodePath: request.settings.xcodePath),
            arguments: ["-version"],
            environment: XcodeToolchain.environment(xcodePath: request.settings.xcodePath)
        )
        let xcodeVersion = versionResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let workspace = derivedDataRoot.appendingPathComponent(project.id.uuidString, isDirectory: true)
        let reusedExistingWorkspace = FileManager.default.fileExists(atPath: workspace.path)
        let decision: BuildCacheDecision
        if let fingerprint {
            decision = BuildCacheManager.decide(
                project: project,
                currentFingerprint: fingerprint,
                xcodeVersion: xcodeVersion,
                workspaceExists: reusedExistingWorkspace,
                directory: buildCacheDirectory
            )
        } else {
            decision = .fullBuild(reason: "项目指纹计算失败，按完整构建处理")
        }
        var fullOutput = "=== CACHE ===\n\(decision.logDescription)\n"

        do {
            try Self.prepareWorkspace(workspace, root: derivedDataRoot, clear: false)
        } catch {
            return BuildResult(success: false, output: fullOutput + "\n错误：无法准备构建工作区：\(error.localizedDescription)")
        }

        // 强制签名刷新：清空产物目录后，xcodebuild 必须重建 .app 并重跑
        // 签名阶段（与全量构建的签名行为一致），编译产物仍然复用。
        Self.clearProductsDirectory(workspace: workspace, configuration: project.configuration, platform: project.platform)

        let executor = BuildExecutor(runner: runner)
        let baseArguments = BuildExecutor.baseArguments(for: project, derivedDataPath: workspace.path)

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
        var cacheFallbackUsed = false
        var attempt = 0
        buildLoop: while attempt < retry.maxAttempts {
            let buildResult = await executor.build(arguments: baseArguments, xcodePath: request.settings.xcodePath)
            attempt += 1
            let buildOutput = buildResult.combined
            fullOutput += "=== BUILD \(attempt)/\(retry.maxAttempts) ===\n\(buildOutput)\n"

            if Task.isCancelled { return .cancelledResult(output: fullOutput + "\n任务已取消") }
            if buildResult.exitCode == 0 {
                buildSucceeded = true
                break
            }

            // 增量工作区偶发损坏（模块不兼容等）：清除工作区回退完整构建一次，
            // 不消耗重试次数。确定性编译错误不会触发回退。
            if !cacheFallbackUsed, reusedExistingWorkspace,
               Self.containsWorkspaceCorruptionMarkers(buildOutput) {
                cacheFallbackUsed = true
                fullOutput += "\n⚠️ 检测到增量构建工作区异常，清除工作区后回退完整构建…\n"
                do {
                    try Self.prepareWorkspace(workspace, root: derivedDataRoot, clear: true)
                } catch {
                    fullOutput += "清除工作区失败：\(error.localizedDescription)\n"
                }
                continue
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
            return BuildResult(success: false, output: fullOutput, buildMode: decision.mode)
        }

        let appPath: String?
        if let expectedProduct, FileManager.default.fileExists(atPath: expectedProduct) {
            appPath = expectedProduct
        } else {
            appPath = ProductResolver.mainApp(
                in: Self.productsDirectory(
                    workspace: workspace,
                    configuration: project.configuration,
                    platform: project.platform
                ),
                preferredNames: [project.scheme, project.projectName]
            )
        }

        guard let appPath else {
            fullOutput += "\n错误：无法确定本次构建生成的主 .app，已停止安装以避免安装错误产物\n"
            return BuildResult(success: false, output: fullOutput, buildMode: decision.mode)
        }
        fullOutput += "\n本次产物: \(appPath)\n"

        // 签名审计：把嵌入 profile 的有效期写进日志，续签是否真的刷新一目了然。
        if let expiration = Self.embeddedProfileExpiration(appPath: appPath) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            formatter.timeZone = TimeZone.current
            fullOutput += "签名有效期至: \(formatter.string(from: expiration))\n"
        }

        // 构建成功：写入缓存元数据（best effort，失败只记日志不判失败）。
        if let fingerprint {
            do {
                try BuildCacheManager.saveMetadata(
                    BuildArtifactMetadata(
                        projectID: project.id,
                        fingerprint: fingerprint,
                        xcodeVersion: xcodeVersion,
                        builtAt: Date(),
                        scheme: project.scheme,
                        configuration: project.configuration,
                        platform: project.platform,
                        teamID: project.teamID,
                        projectPath: project.projectPath,
                        productName: URL(fileURLWithPath: appPath).lastPathComponent,
                        bundleIdentifier: Self.readBundleIdentifier(appPath: appPath),
                        buildSucceeded: true
                    ),
                    directory: buildCacheDirectory
                )
            } catch {
                fullOutput += "缓存元数据写入失败（不影响本次执行）：\(error.localizedDescription)\n"
            }
        }

        switch installPlan {
        case .localMac:
            let installer = MacAppInstaller(
                runner: runner,
                applicationsDirectory: macInstallDirectory
            )
            let outcome = await installer.install(appPath: appPath)
            fullOutput += "\n=== INSTALL (macOS) ===\n\(outcome.output)\n"
            if Task.isCancelled { return .cancelledResult(output: fullOutput + "\n任务已取消") }
            return BuildResult(
                success: outcome.success,
                output: fullOutput,
                builtAppPath: appPath,
                buildMode: decision.mode
            )

        case .devices(let deviceUDIDs):
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
                deviceOutcomes: outcomes,
                builtAppPath: appPath,
                buildMode: decision.mode
            )
        }
    }

    // MARK: - Workspace & products

    /// 准备工作区：默认只创建不删除（Xcode 增量构建依赖工作区保留）；
    /// 仅在显式失效（缓存损坏回退、手动清理）时 clear == true。
    static func prepareWorkspace(_ directory: URL, root: URL, clear: Bool) throws {
        let rootPrefix = root.standardizedFileURL.path + "/"
        let target = directory.standardizedFileURL.path
        guard target.hasPrefix(rootPrefix), target.count > rootPrefix.count else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if clear, FileManager.default.fileExists(atPath: target) {
            try FileManager.default.removeItem(atPath: target)
        }
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
    }

    static func productsDirectory(workspace: URL, configuration: String, platform: ProjectPlatform) -> URL {
        workspace
            .appendingPathComponent("Build/Products", isDirectory: true)
            .appendingPathComponent(
                platform == .macos ? configuration : "\(configuration)-iphoneos",
                isDirectory: true
            )
    }

    /// 清空本配置的产物目录中的 .app：产物缺失会迫使 xcodebuild 重跑
    /// 资源组装与签名阶段（刷新 provisioning profile），而对象文件等
    /// 编译缓存位于 Intermediates，不受影响。
    static func clearProductsDirectory(workspace: URL, configuration: String, platform: ProjectPlatform) {
        let products = productsDirectory(workspace: workspace, configuration: configuration, platform: platform)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: products,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for url in files where url.pathExtension == "app" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 增量工作区损坏的典型特征（用于回退 clean build 判断）。
    static let workspaceCorruptionMarkers = [
        "no such module",
        "module compiled with",
        "precompiled header",
        "pch file",
        "unable to load standard library",
        "build input file cannot be found",
        "object file was built with a different version",
        "failed to build module"
    ]

    static func containsWorkspaceCorruptionMarkers(_ output: String) -> Bool {
        let text = output.lowercased()
        return workspaceCorruptionMarkers.contains { text.contains($0) }
    }

    /// 读取 App 的 bundle identifier（iOS: Foo.app/Info.plist；macOS: Contents/Info.plist）。
    static func readBundleIdentifier(appPath: String) -> String? {
        let candidates = [
            URL(fileURLWithPath: appPath).appendingPathComponent("Info.plist"),
            URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty
            else { continue }
            return bundleID
        }
        return nil
    }

    /// 读取 iOS App 内嵌 provisioning profile 的过期时间。
    /// mobileprovision = CMS 包裹的明文 plist，直接按 XML 边界提取解析；
    /// 解析失败只返回 nil，不影响执行。
    static func embeddedProfileExpiration(appPath: String) -> Date? {
        let profileURL = URL(fileURLWithPath: appPath).appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: profileURL) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>"),
              start.lowerBound < end.upperBound
        else { return nil }
        let xml = String(text[start.lowerBound..<end.upperBound])
        guard let plist = try? PropertyListSerialization.propertyList(
            from: Data(xml.utf8), options: [], format: nil
        ) as? [String: Any] else { return nil }
        return plist["ExpirationDate"] as? Date
    }
}
