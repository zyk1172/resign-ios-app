import Foundation

/// Scheduled execution mode. Runs the due projects through the shared
/// BuildCoordinator and records every result into the single config.json
/// (execution state + unified log entries). Exits 0 when all due projects
/// succeeded, 1 otherwise, 2 on invalid invocation.
struct ScheduledRunCoordinator: Sendable {
    let configDirectory: URL
    let runner: ProcessRunning

    func run(now: Date = Date()) async -> Int32 {
        let logRepository = LogRepository(
            directory: configDirectory.appendingPathComponent("logs", isDirectory: true)
        )
        let configStore = ConfigStore(directory: configDirectory, logRepository: logRepository)

        let loaded = configStore.load()
        if let error = loaded.error {
            print("[ResignWorker] \(error)")
        }
        let state = loaded.state
        let settings = state.settings.normalized()

        logRepository.deleteOrphans(referencedLogFileNames: Set(state.logs.compactMap(\.logFile)))

        let enabled = state.projects.filter { $0.isEnabled && !$0.projectPath.isEmpty }
        guard !enabled.isEmpty else {
            print("[ResignWorker] 没有已启用的项目，结束")
            return 0
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
            return 0
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
            let recorded = configStore.updateSynchronously { currentState in
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
            if !recorded {
                print("[ResignWorker] ⚠️ 结果写入被跳过（config 被长期占用）")
            }

            print("[ResignWorker] \(result.success ? "✓" : "✗") \(project.name)（耗时 \(Int(duration))s）")

            if !result.success { anyFailure = true }

            if index < due.count - 1, settings.buildCooldownSeconds > 0 {
                try? await Task.sleep(for: .seconds(settings.buildCooldownSeconds))
            }
        }

        if settings.notifyOnComplete {
            let body = anyFailure
                ? "到期项目存在失败，请打开 Resign 查看日志"
                : "到期项目已全部构建并安装成功"
            _ = await runner.run(
                "/usr/bin/osascript",
                arguments: ["-e", "display notification \"\(body)\" with title \"Resign\""]
            )
        }

        return anyFailure ? 1 : 0
    }
}
