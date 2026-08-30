import Foundation
import SwiftUI
import Observation

@MainActor
@Observable
final class AppStore {
    var projects: [iOSProject] = []
    var devices: [iOSDevice] = []
    var settings = AppSettings()
    var logs: [BuildLogEntry] = []
    var executionStates: [ProjectExecutionState] = []
    var isBuilding = false
    var scheduleInstalled = false
    var statusMessage = "就绪"

    struct Toast: Equatable {
        enum Kind { case success, error, info }
        var kind: Kind
        var message: String
    }
    var toast: Toast?

    @ObservationIgnored private let configStore: ConfigStore
    @ObservationIgnored private let logRepository: LogRepository
    @ObservationIgnored private let scheduleManager: ScheduleManager
    @ObservationIgnored private let buildCoordinator: BuildCoordinator
    @ObservationIgnored private let deviceService: DeviceService
    @ObservationIgnored private let schemeService: SchemeService
    @ObservationIgnored private let teamService: DevelopmentTeamService

    @ObservationIgnored private var activeBuildTask: Task<Void, Never>?
    @ObservationIgnored private var deviceRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var scheduleSyncTask: Task<Void, Never>?

    init(configDirectory: URL = AppPaths.configDirectory) {
        let logDirectory = configDirectory.appendingPathComponent("logs", isDirectory: true)
        let runner = FoundationProcessRunner()
        configStore = ConfigStore(directory: configDirectory, logRepository: LogRepository(directory: logDirectory))
        logRepository = LogRepository(directory: logDirectory)
        scheduleManager = ScheduleManager(
            plistURL: AppPaths.schedulePlistURL,
            workerExecutablePath: ScheduleManager.workerExecutablePath(),
            logDirectory: logDirectory,
            workingDirectory: configDirectory,
            legacyScriptURL: AppPaths.legacyScriptURL
        )
        buildCoordinator = BuildCoordinator(runner: runner)
        deviceService = DeviceService(runner: runner)
        schemeService = SchemeService(runner: runner)
        teamService = DevelopmentTeamService(runner: runner)

        load()
        Task.detached(priority: .utility) {
            AppPaths.cleanupLegacyTemporaryWorkspaces()
        }
    }

    /// 清除某项目的增量构建工作区与缓存元数据（下次执行将完整重建）。
    /// 构建进行中（锁被占用）时拒绝执行。
    func clearBuildCache(for project: iOSProject) {
        do {
            try BuildCacheManager.clear(projectID: project.id, buildLockPath: AppPaths.buildLockURL.path)
            statusMessage = "已清除 \(project.name) 的构建缓存"
            showToast(.success, "已清除构建缓存，下次执行将完整重建")
        } catch {
            statusMessage = "清除构建缓存失败：\(error.localizedDescription)"
            showToast(.error, "清除构建缓存失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Persistence (delegated to ConfigStore — the single source of truth)

    private func load() {
        let loaded = configStore.load()
        if let error = loaded.error {
            statusMessage = error
        }
        let state = loaded.state
        projects = state.projects
        settings = state.settings.normalized()
        logs = state.logs
        executionStates = state.executionStates

        // Adopt worker-written results into UI fields (covers runs that
        // happened while the app was closed).
        for projectIndex in projects.indices {
            guard let stateEntry = executionStates.first(where: { $0.projectID == projects[projectIndex].id }),
                  let attempt = stateEntry.lastAttemptDate,
                  (projects[projectIndex].lastBuildDate ?? .distantPast) < attempt
            else { continue }
            projects[projectIndex].lastBuildDate = attempt
            projects[projectIndex].lastBuildStatus = stateEntry.lastStatus
        }

        // One-time import of legacy bash-engine run logs (pre-1.5).
        importScheduledRuns(saveAfterImport: false)
        logRepository.deleteOrphans(referencedLogFileNames: Set(logs.compactMap(\.logFile)))
    }

    private func currentState() -> PersistedState {
        PersistedState(
            projects: projects,
            settings: settings,
            executionStates: executionStates,
            logs: logs
        )
    }

    /// Schedules an off-main save. ConfigStore merges concurrent worker
    /// results back in, so GUI edits never clobber background outcomes.
    func save() {
        configStore.enqueueSave(currentState())
    }

    // MARK: - Projects

    func addProject(path: String) {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !projects.contains(where: { URL(fileURLWithPath: $0.projectPath).standardizedFileURL.path == standardizedPath }) else {
            showToast(.info, "这个项目已经添加")
            return
        }
        let name = URL(fileURLWithPath: standardizedPath).deletingPathExtension().lastPathComponent
        let newProject = iOSProject(name: name, projectPath: standardizedPath)
        projects.append(newProject)
        save()

        Task { await discoverSchemes(for: [newProject.id]) }
    }

    func removeProject(_ project: iOSProject) {
        projects.removeAll { $0.id == project.id }
        executionStates.removeAll { $0.projectID == project.id }
        save()
    }

    /// Scans a folder once, batch-inserts new projects with a single save,
    /// then discovers schemes with bounded concurrency instead of one
    /// xcodebuild per project racing at once.
    func addProjectsFromFolder(_ folder: URL) {
        let found = ProjectScanner.scan(in: folder)
        let existingPaths = Set(projects.map { URL(fileURLWithPath: $0.projectPath).standardizedFileURL.path })
        let newPaths = found
            .map { $0.standardizedFileURL.path }
            .filter { !existingPaths.contains($0) }
        guard !newPaths.isEmpty else {
            showToast(.info, "未发现新项目（共扫描到 \(found.count) 个）")
            return
        }

        let newProjects = newPaths.map { path in
            iOSProject(
                name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                projectPath: path
            )
        }
        projects.append(contentsOf: newProjects)
        save()
        showToast(.success, "已添加 \(newPaths.count) 个项目")

        Task { await discoverSchemes(for: newProjects.map(\.id)) }
    }

    /// Scheme discovery with a concurrency limit (max 3 xcodebuild at a time),
    /// applying results in one batch and saving once.
    private func discoverSchemes(for ids: [UUID]) async {
        let xcodePath = settings.xcodePath
        let service = schemeService
        var schemesByID: [UUID: String] = [:]

        let targets = ids.compactMap { id -> (UUID, String)? in
            guard let project = projects.first(where: { $0.id == id }) else { return nil }
            return (id, project.projectPath)
        }

        var index = 0
        while index < targets.count {
            let chunk = Array(targets[index..<min(index + 3, targets.count)])
            index += 3
            await withTaskGroup(of: (UUID, [String]).self) { group in
                for (id, path) in chunk {
                    group.addTask {
                        let schemes = await service.listSchemes(projectPath: path, xcodePath: xcodePath)
                        return (id, schemes)
                    }
                }
                for await (id, schemes) in group {
                    schemesByID[id] = schemes.first ?? ""
                }
            }
        }

        for (id, scheme) in schemesByID {
            guard let projectIndex = projects.firstIndex(where: { $0.id == id }),
                  projects[projectIndex].scheme.isEmpty || !scheme.isEmpty
            else { continue }
            projects[projectIndex].scheme = scheme
        }
        save()
    }

    func updateProject(_ project: iOSProject) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
            save()
        }
    }

    // MARK: - Application-level actions for Views

    func schemes(for projectPath: String) async -> [String] {
        await schemeService.listSchemes(projectPath: projectPath, xcodePath: settings.xcodePath)
    }

    func developmentTeams() async -> [DevelopmentTeam] {
        await teamService.listTeams()
    }

    func appIcon(for projectPath: String) async -> NSImage? {
        await AppIconService.loadAppIcon(projectPath: projectPath)
    }

    // MARK: - Devices

    func refreshDevices() async {
        if let inFlight = deviceRefreshTask {
            await inFlight.value
            return
        }
        let xcodePath = settings.xcodePath
        let service = deviceService
        let task = Task { [weak self] in
            let devices = await service.listDevices(xcodePath: xcodePath)
            guard let self else { return }
            self.devices = devices
            self.deviceRefreshTask = nil
        }
        deviceRefreshTask = task
        await task.value
    }

    // MARK: - Build Lifecycle

    func startBuildAll() {
        guard activeBuildTask == nil else { return }
        activeBuildTask = Task { [weak self] in
            await self?.buildAll()
            self?.activeBuildTask = nil
        }
    }

    func startBuildSingle(_ project: iOSProject, toDevice udid: String? = nil) {
        guard activeBuildTask == nil else { return }
        activeBuildTask = Task { [weak self] in
            await self?.buildSingle(project, deviceOverride: udid.map { [$0] })
            self?.activeBuildTask = nil
        }
    }

    func cancelBuild() {
        guard let activeBuildTask else { return }
        statusMessage = "正在取消…"
        activeBuildTask.cancel()
    }

    private func buildAll() async {
        guard !isBuilding else { return }
        let enabled = projects.filter { $0.isEnabled && !$0.projectPath.isEmpty }
        guard !enabled.isEmpty else {
            showToast(.info, "没有已启用的项目")
            return
        }

        isBuilding = true
        let activity = beginPreventSleepActivityIfNeeded()
        defer {
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            isBuilding = false
            save()
        }

        statusMessage = "正在刷新设备…"
        await refreshDevices()
        var succeeded = 0
        var failed = 0

        for (index, project) in enabled.enumerated() {
            if Task.isCancelled { break }
            let result = await performBuild(of: project, source: .manual)
            if result.cancelled { break }
            if result.success { succeeded += 1 } else { failed += 1 }

            if index < enabled.count - 1 && settings.buildCooldownSeconds > 0 {
                statusMessage = "等待 \(settings.buildCooldownSeconds) 秒后执行下一个项目…"
                do {
                    try await Task.sleep(for: .seconds(settings.buildCooldownSeconds))
                } catch {
                    break
                }
            }
        }

        if Task.isCancelled {
            statusMessage = "任务已取消"
            showToast(.info, "已取消后续任务")
            return
        }

        statusMessage = failed == 0 ? "全部完成" : "完成：\(succeeded) 成功，\(failed) 失败"
        if settings.notifyOnComplete {
            NotificationService.send(
                title: failed == 0 ? "Resign 完成" : "Resign 部分失败",
                body: "成功 \(succeeded) 个，失败 \(failed) 个"
            )
        }
    }

    private func buildSingle(_ project: iOSProject, deviceOverride: [String]? = nil) async {
        guard !isBuilding else { return }
        isBuilding = true
        let activity = beginPreventSleepActivityIfNeeded()
        defer {
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            isBuilding = false
            save()
        }

        statusMessage = "正在刷新设备…"
        await refreshDevices()
        let result = await performBuild(of: project, source: .manual, deviceOverride: deviceOverride)
        if result.cancelled {
            statusMessage = "任务已取消"
        } else if let udid = deviceOverride?.first,
                  let deviceName = devices.first(where: { $0.udid == udid })?.name {
            statusMessage = result.success ? "\(project.name) 已推送到 \(deviceName)" : "\(project.name) 推送到 \(deviceName) 失败"
        } else {
            statusMessage = result.success ? "\(project.name) 构建成功" : "\(project.name) 构建失败"
        }
    }

    private func beginPreventSleepActivityIfNeeded() -> NSObjectProtocol? {
        guard settings.preventSleep else { return nil }
        return ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled, .userInitiated],
            reason: "正在构建并安装 iOS 应用"
        )
    }

    /// Runs the shared BuildCoordinator and records the outcome into the
    /// unified execution state + logs, then persists with merge. When
    /// `deviceOverride` names a device that is not currently connected, the
    /// run fails fast without building.
    private func performBuild(
        of project: iOSProject,
        source: ExecutionSource,
        deviceOverride: [String]? = nil
    ) async -> BuildResult {
        let startedAt = Date()
        if let udid = deviceOverride?.first,
           let deviceName = devices.first(where: { $0.udid == udid })?.name {
            statusMessage = "正在构建：\(project.name) → \(deviceName)"
        } else {
            statusMessage = "正在构建：\(project.name)"
        }

        let result: BuildResult
        if let udid = deviceOverride?.first,
           !devices.contains(where: { $0.udid == udid && $0.isAvailable }) {
            let deviceName = devices.first(where: { $0.udid == udid })?.name ?? String(udid.prefix(8))
            result = BuildResult(
                success: false,
                output: "错误：目标设备「\(deviceName)」当前未连接。请连接并信任此电脑后在设备页刷新，然后再试。"
            )
        } else {
            let request = BuildRequest(
                project: project,
                settings: settings,
                availableDevices: devices,
                source: source,
                deviceOverride: deviceOverride
            )
            result = await buildCoordinator.execute(request)
        }
        let duration = Date().timeIntervalSince(startedAt)

        var state = currentState()
        ExecutionRecorder.apply(
            .init(
                projectID: project.id,
                projectName: project.name,
                result: result,
                source: source,
                startedAt: startedAt,
                durationSeconds: duration,
                deviceNames: Dictionary(uniqueKeysWithValues: devices.map { ($0.udid, $0.name) })
            ),
            to: &state
        ) { raw, date in
            logRepository.externalize(raw, date: date)
        }
        logRepository.trim(&state.logs)

        projects = state.projects
        logs = state.logs
        executionStates = state.executionStates
        save()
        return result
    }

    // MARK: - Logs

    /// Clears log entries plus every managed artifact on disk.
    func clearLogs() {
        logs.removeAll()
        logRepository.clearAll()
        save()
        showToast(.info, "日志已清空")
    }

    func fullLogText(for entry: BuildLogEntry) -> String {
        logRepository.fullLogText(for: entry) ?? entry.output
    }

    /// Imports legacy bash-engine scheduled runs (pre-1.5) once each.
    func importScheduledRuns(saveAfterImport: Bool = true) {
        let known = Set(logs.compactMap(\.sourceIdentifier))
        let imported = logRepository.importLegacyScheduledRuns(knownIdentifiers: known)
        guard !imported.isEmpty else { return }

        logs.append(contentsOf: imported)
        logs.sort { $0.date > $1.date }
        logRepository.trim(&logs)
        if saveAfterImport { save() }
    }

    // MARK: - Schedule (delegated to ScheduleManager)

    /// Refreshes installed-state and auto-installs/migrates on launch when
    /// enabled. The legacy bash plist is replaced by the worker plist here.
    func refreshScheduleAndAutoInstall() async {
        let manager = scheduleManager
        scheduleInstalled = await Task.detached(priority: .utility) { manager.isInstalled }.value

        guard settings.autoInstallSchedule, !projects.isEmpty else { return }
        let hour = settings.scheduleHour
        let minute = settings.scheduleMinute
        let needsUpdate = await Task.detached(priority: .utility) {
            manager.needsUpdate(hour: hour, minute: minute)
        }.value
        guard !scheduleInstalled || needsUpdate else { return }
        installSchedule()
    }

    /// Debounced schedule refresh when only the calendar time changes. The
    /// plist carries no project snapshot, so this is cheap and idempotent —
    /// but changes are never silently dropped either.
    func refreshScheduleIfInstalled() {
        guard scheduleInstalled, settings.autoInstallSchedule else { return }
        scheduleSyncTask?.cancel()
        scheduleSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            let manager = self.scheduleManager
            let hour = self.settings.scheduleHour
            let minute = self.settings.scheduleMinute
            let needsUpdate = await Task.detached(priority: .utility) {
                manager.needsUpdate(hour: hour, minute: minute)
            }.value
            if needsUpdate {
                self.installSchedule()
            }
        }
    }

    func installSchedule() {
        do {
            try scheduleManager.install(
                xcodePath: settings.xcodePath,
                hour: settings.scheduleHour,
                minute: settings.scheduleMinute
            )
            scheduleInstalled = true
            statusMessage = "定时任务已安装（每天 \(String(format: "%02d", settings.scheduleHour)):\(String(format: "%02d", settings.scheduleMinute)) 检查）"
            showToast(.success, "定时任务已安装并通过状态检查")
        } catch {
            Task { await self.refreshScheduleInstalledFlag() }
            statusMessage = "定时任务安装失败：\(error.localizedDescription)"
            showToast(.error, "定时任务安装失败")
        }
    }

    func uninstallSchedule() {
        do {
            try scheduleManager.uninstall()
            scheduleInstalled = false
            statusMessage = "定时任务已卸载"
            showToast(.info, "定时任务已卸载")
        } catch {
            Task { await self.refreshScheduleInstalledFlag() }
            statusMessage = "定时任务卸载失败：\(error.localizedDescription)"
            showToast(.error, "定时任务卸载失败")
        }
    }

    private func refreshScheduleInstalledFlag() async {
        let manager = scheduleManager
        scheduleInstalled = await Task.detached(priority: .utility) { manager.isInstalled }.value
    }

    var isScheduleInstalled: Bool { scheduleInstalled }

    // MARK: - Toast

    func showToast(_ kind: Toast.Kind, _ message: String) {
        toast = Toast(kind: kind, message: message)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            if self?.toast?.message == message { self?.toast = nil }
        }
    }
}
