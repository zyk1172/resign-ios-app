import Foundation

/// Worker 退出码。launchd 会把 exit 0 记为"成功"，
/// 因此配置损坏（3）与落盘失败（4）绝不能归并进 0。
enum WorkerExitCode: Int32 {
    case ok = 0
    case executionFailed = 1
    case invalidInvocation = 2
    case configInvalid = 3
    case persistenceFailed = 4
}

/// Scheduled execution mode. Runs the due projects through the shared
/// BuildCoordinator and records every result into the single config.json
/// (execution state + unified log entries).
///
/// Exit codes: see `WorkerExitCode`.
struct ScheduledRunCoordinator: Sendable {
    let configDirectory: URL
    let runner: ProcessRunning

    func run(now: Date = Date()) async -> Int32 {
        AppPaths.cleanupLegacyTemporaryWorkspaces()

        let logRepository = LogRepository(
            directory: configDirectory.appendingPathComponent("logs", isDirectory: true)
        )
        let configStore = ConfigStore(directory: configDirectory, logRepository: logRepository)

        let loaded = configStore.load()
        if let error = loaded.error {
            // 配置损坏时绝不能"成功地什么都不做"：launchd 会把 exit 0 记为
            // 成功，用户会以为后台续签正常执行了。
            print("[ResignWorker] \(error)")
            print("[ResignWorker] 已中止：配置读取失败（exit \(WorkerExitCode.configInvalid.rawValue)）")
            return WorkerExitCode.configInvalid.rawValue
        }
        let state = loaded.state
        let settings = state.settings.normalized()

        logRepository.deleteOrphans(referencedLogFileNames: Set(state.logs.compactMap(\.logFile)))

        let enabled = state.projects.filter { $0.isEnabled && !$0.projectPath.isEmpty }
        guard !enabled.isEmpty else {
            print("[ResignWorker] 没有已启用的项目，结束")
            return WorkerExitCode.ok.rawValue
        }

        // Due check against the unified execution states (last successful
        // install date), matching what the GUI displays.
        let due = enabled.filter { project in
            let lastSuccess = state.executionStates
                .first { $0.projectID == project.id }?
                .lastSuccessfulInstallDate
            return ScheduleDuePolicy.isDue(
                lastSuccessfulInstallDate: lastSuccess,
                intervalDays: settings.resignIntervalDays,
                now: now
            )
        }
        guard !due.isEmpty else {
            print("[ResignWorker] 所有项目均未到期，结束")
            return WorkerExitCode.ok.rawValue
        }
        print("[ResignWorker] 到期项目：\(due.map(\.name).joined(separator: "、"))")

        // Same structured device discovery as the GUI.
        let deviceService = DeviceService(runner: runner)
        let devices = await deviceService.listDevices(xcodePath: settings.xcodePath)
        let deviceNames = Dictionary(uniqueKeysWithValues: devices.map { ($0.udid, $0.name) })

        let coordinator = BuildCoordinator(runner: runner)

        var activity: NSObjectProtocol?
        if settings.preventSleep {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled, .userInitiated],
                reason: "Resign 定时构建并安装 iOS 应用"
            )
        }
        defer {
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
        }

        var anyFailure = false
        var persistenceFailed = false
        for (index, project) in due.enumerated() {
            let startedAt = Date()
            print("[ResignWorker] 开始构建：\(project.name)")

            let request = BuildRequest(
                project: project,
                settings: settings,
                availableDevices: devices,
                source: .scheduled
            )
            let result = await coordinator.execute(request)
            let duration = Date().timeIntervalSince(startedAt)

            // Record into the single source of truth (atomic read-modify-write).
            do {
                try configStore.updateSynchronously { currentState in
                    ExecutionRecorder.apply(
                        .init(
                            projectID: project.id,
                            projectName: project.name,
                            result: result,
                            source: .scheduled,
                            startedAt: startedAt,
                            durationSeconds: duration,
                            deviceNames: deviceNames
                        ),
                        to: &currentState
                    ) { raw, date in
                        logRepository.externalize(raw, date: date)
                    }
                    logRepository.trim(&currentState.logs)
                }
            } catch {
                persistenceFailed = true
                print("[ResignWorker] ⚠️ 结果写入失败：\(error.localizedDescription)")
            }

            print("[ResignWorker] \(result.success ? "✓" : "✗") \(project.name)（耗时 \(Int(duration))s）")

            if !result.success { anyFailure = true }

            if index < due.count - 1, settings.buildCooldownSeconds > 0 {
                try? await Task.sleep(for: .seconds(settings.buildCooldownSeconds))
            }
        }

        if settings.notifyOnComplete {
            let body = Self.notificationBody(
                persistenceFailed: persistenceFailed,
                executionFailed: anyFailure
            )
            _ = await runner.run(
                "/usr/bin/osascript",
                arguments: ["-e", "display notification \"\(body)\" with title \"Resign\""]
            )
        }

        if persistenceFailed { return WorkerExitCode.persistenceFailed.rawValue }
        return anyFailure ? WorkerExitCode.executionFailed.rawValue : WorkerExitCode.ok.rawValue
    }

    /// 通知内容按严重度排序：落盘失败 > 执行失败 > 成功。
    /// 落盘失败时绝不能显示"全部成功"——用户会误以为续签完成。
    static func notificationBody(persistenceFailed: Bool, executionFailed: Bool) -> String {
        if persistenceFailed {
            return "项目已执行，但结果保存失败；下次可能重复执行，请打开 Resign 检查"
        }
        if executionFailed {
            return "到期项目存在失败，请打开 Resign 查看日志"
        }
        return "到期项目已全部构建并安装成功"
    }
}
