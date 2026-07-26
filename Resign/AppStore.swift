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
    var isBuilding = false
    var scheduleInstalled = false
    var statusMessage = "就绪"

    struct Toast: Equatable {
        enum Kind { case success, error, info }
        var kind: Kind
        var message: String
    }
    var toast: Toast?

    @ObservationIgnored private var activeBuildTask: Task<Void, Never>?

    static var configURL: URL { AppPaths.configURL }
    static var scriptURL: URL { AppPaths.scriptURL }
    static var logDir: URL { AppPaths.logDirectory }

    init() {
        load()
        scheduleInstalled = ScheduleService.isInstalled
    }

    // MARK: - Persistence
    func load() {
        if FileManager.default.fileExists(atPath: Self.configURL.path) {
            do {
                let data = try Data(contentsOf: Self.configURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let state = try decoder.decode(PersistedState.self, from: data)
                projects = state.projects
                settings = state.settings
                logs = state.logs
            } catch {
                statusMessage = "配置读取失败：\(error.localizedDescription)"
            }
        }
        normalizeSettings()
        importScheduledRuns(saveAfterImport: false)
    }

    func save() {
        let state = PersistedState(projects: projects, settings: settings, logs: logs)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(state)
            try data.write(to: Self.configURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            statusMessage = "配置保存失败：\(error.localizedDescription)"
            showToast(.error, "配置保存失败")
        }
    }

    private func normalizeSettings() {
        settings.resignIntervalDays = min(max(settings.resignIntervalDays, 1), 7)
        settings.scheduleHour = min(max(settings.scheduleHour, 0), 23)
        settings.scheduleMinute = min(max(settings.scheduleMinute, 0), 59)
        settings.buildCooldownSeconds = min(max(settings.buildCooldownSeconds, 0), 60)
        settings.maxRetries = min(max(settings.maxRetries, 0), 3)
        settings.retryIntervalMinutes = min(max(settings.retryIntervalMinutes, 1), 120)
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

        let projectID = newProject.id
        let xcodePath = settings.xcodePath
        Task { [weak self] in
            let schemes = await BuildService.listSchemes(projectPath: standardizedPath, xcodePath: xcodePath)
            guard let self else { return }
            if let index = self.projects.firstIndex(where: { $0.id == projectID }) {
                self.projects[index].scheme = schemes.first ?? ""
            }
            self.save()
        }
    }

    func removeProject(_ project: iOSProject) {
        projects.removeAll { $0.id == project.id }
        save()
    }

    func addProjectsFromFolder(_ folder: URL) {
        let found = BuildService.scanProjects(in: folder)
        let existingPaths = Set(projects.map { URL(fileURLWithPath: $0.projectPath).standardizedFileURL.path })
        let newPaths = found.map { $0.standardizedFileURL.path }.filter { !existingPaths.contains($0) }
        for path in newPaths { addProject(path: path) }
        if newPaths.isEmpty {
            showToast(.info, "未发现新项目（共扫描到 \(found.count) 个）")
        } else {
            showToast(.success, "已添加 \(newPaths.count) 个项目")
        }
    }

    func updateProject(_ project: iOSProject) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
            save()
        }
    }

    // MARK: - Devices
    func refreshDevices() async {
        devices = await BuildService.listDevices(xcodePath: settings.xcodePath)
    }

    // MARK: - Build Lifecycle
    func startBuildAll() {
        guard activeBuildTask == nil else { return }
        activeBuildTask = Task { [weak self] in
            await self?.buildAll()
            self?.activeBuildTask = nil
        }
    }

    func startBuildSingle(_ project: iOSProject) {
        guard activeBuildTask == nil else { return }
        activeBuildTask = Task { [weak self] in
            await self?.buildSingle(project)
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
            let result = await performBuild(of: project)
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
            BuildService.sendNotification(
                title: failed == 0 ? "Resign 完成" : "Resign 部分失败",
                body: "成功 \(succeeded) 个，失败 \(failed) 个"
            )
        }
    }

    private func buildSingle(_ project: iOSProject) async {
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
        let result = await performBuild(of: project)
        if result.cancelled {
            statusMessage = "任务已取消"
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

    @discardableResult
    private func performBuild(of project: iOSProject) async -> BuildResult {
        let start = Date()
        statusMessage = "正在构建：\(project.name)"
        let result = await BuildService.buildAndInstall(
            project: project,
            xcodePath: settings.xcodePath,
            deviceUDIDs: resolveDeviceUDIDs(for: project),
            maxAttempts: settings.enableRetry ? 1 + settings.maxRetries : 1,
            retryIntervalSeconds: settings.retryIntervalMinutes * 60
        )
        let duration = Date().timeIntervalSince(start)
        let failedNames = result.failedDeviceUDIDs.map { udid in
            devices.first { $0.udid == udid }?.name ?? String(udid.prefix(8))
        }
        let status: BuildStatus = result.cancelled ? .cancelled : (result.success ? .success : .failed)
        logs.insert(
            BuildLogEntry(
                date: start,
                projectName: project.name,
                status: status,
                output: result.output,
                durationSeconds: duration,
                failedDevices: failedNames.isEmpty ? nil : failedNames
            ),
            at: 0
        )
        trimLogs()

        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index].lastBuildDate = Date()
            projects[index].lastBuildStatus = status
        }
        save()
        return result
    }

    private func resolveDeviceUDIDs(for project: iOSProject) -> [String] {
        if !project.deviceUDIDs.isEmpty { return project.deviceUDIDs }
        return devices.first(where: \.isAvailable).map { [$0.udid] } ?? []
    }

    // MARK: - Scheduled Run Import
    func importScheduledRuns(saveAfterImport: Bool = true) {
        let known = Set(logs.compactMap(\.sourceIdentifier))
        guard let statusFiles = try? FileManager.default.contentsOfDirectory(
            at: Self.logDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        var imported = false

        for statusURL in statusFiles where statusURL.pathExtension == "status" && !known.contains(statusURL.lastPathComponent) {
            guard let rawStatus = try? String(contentsOf: statusURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  rawStatus == "success" || rawStatus == "failed"
            else { continue }

            let timestamp = statusURL.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "run_", with: "")
            let date = formatter.date(from: timestamp)
                ?? (try? statusURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date()
            let logURL = Self.logDir.appendingPathComponent("resign_\(timestamp).log")
            let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "定时任务日志文件不可用"

            logs.append(
                BuildLogEntry(
                    date: date,
                    projectName: "自动任务",
                    status: rawStatus == "success" ? .success : .failed,
                    output: output,
                    durationSeconds: 0,
                    sourceIdentifier: statusURL.lastPathComponent
                )
            )
            imported = true
        }

        if imported {
            logs.sort { $0.date > $1.date }
            trimLogs()
            if saveAfterImport { save() }
        }
    }

    private func trimLogs() {
        if logs.count > 200 { logs = Array(logs.prefix(200)) }
    }

    // MARK: - Schedule
    func installSchedule() {
        do {
            try ScheduleService.install(scriptURL: Self.scriptURL, settings: settings, projects: projects)
            scheduleInstalled = true
            statusMessage = "定时任务已安装（每天 \(String(format: "%02d", settings.scheduleHour)):\(String(format: "%02d", settings.scheduleMinute)) 检查）"
            showToast(.success, "定时任务已安装并通过状态检查")
        } catch {
            scheduleInstalled = ScheduleService.isInstalled
            statusMessage = "定时任务安装失败：\(error.localizedDescription)"
            showToast(.error, "定时任务安装失败")
        }
    }

    func uninstallSchedule() {
        do {
            try ScheduleService.uninstall()
            scheduleInstalled = false
            statusMessage = "定时任务已卸载"
            showToast(.info, "定时任务已卸载")
        } catch {
            scheduleInstalled = ScheduleService.isInstalled
            statusMessage = "定时任务卸载失败：\(error.localizedDescription)"
            showToast(.error, "定时任务卸载失败")
        }
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
