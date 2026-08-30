import Foundation

// MARK: - Execution Source
/// Where a build/install run originated: the GUI or the scheduled worker.
enum ExecutionSource: String, Codable, Equatable, Sendable {
    case manual
    case scheduled
}

// MARK: - Project Platform
/// Build destination of a project: install to paired iOS devices, or install
/// the built app into the local /Applications folder.
enum ProjectPlatform: String, Codable, Equatable, Sendable, CaseIterable {
    case ios
    case macos
}

// MARK: - iOS Project Configuration
struct iOSProject: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id = UUID()
    var name: String = ""
    /// Path to .xcodeproj or .xcworkspace
    var projectPath: String = ""
    var scheme: String = ""
    var configuration: String = "Debug"
    /// Build destination: iOS devices (default) or the local Mac.
    var platform: ProjectPlatform = .ios
    /// Apple Developer Team ID used for automatic signing; empty/nil = follow project defaults
    var teamID: String? = nil
    /// Target device UDIDs; empty = first available device. Unused for macOS.
    var deviceUDIDs: [String] = []
    var isEnabled: Bool = true
    /// Last build time (UI cache; ExecutionState is authoritative for scheduling)
    var lastBuildDate: Date?
    /// Last build status (drives card color)
    var lastBuildStatus: BuildStatus?

    var isWorkspace: Bool {
        projectPath.hasSuffix(".xcworkspace")
    }

    var projectName: String {
        URL(fileURLWithPath: projectPath)
            .deletingPathExtension()
            .lastPathComponent
    }

    var projectFlag: String {
        isWorkspace ? "-workspace" : "-project"
    }
}

// MARK: - Project Execution State
/// The single source of truth for "when was this project last built/installed
/// successfully". Both the GUI and the scheduled worker read and update this
/// via ConfigStore; the scheduling due-date is derived from
/// `lastSuccessfulInstallDate` (not from any sidecar epoch file).
struct ProjectExecutionState: Codable, Equatable, Sendable {
    var projectID: UUID
    var lastAttemptDate: Date?
    var lastSuccessfulInstallDate: Date?
    var lastStatus: BuildStatus?
    var lastSource: ExecutionSource?
    /// Human-readable reason of the most recent failure (nil when last run succeeded)
    var lastFailureSummary: String?

    init(
        projectID: UUID,
        lastAttemptDate: Date? = nil,
        lastSuccessfulInstallDate: Date? = nil,
        lastStatus: BuildStatus? = nil,
        lastSource: ExecutionSource? = nil,
        lastFailureSummary: String? = nil
    ) {
        self.projectID = projectID
        self.lastAttemptDate = lastAttemptDate
        self.lastSuccessfulInstallDate = lastSuccessfulInstallDate
        self.lastStatus = lastStatus
        self.lastSource = lastSource
        self.lastFailureSummary = lastFailureSummary
    }

    /// Merge key: never nil so comparisons are total.
    var effectiveLastAttempt: Date { lastAttemptDate ?? .distantPast }
}

// MARK: - Connected iOS Device
struct iOSDevice: Identifiable, Equatable, Sendable {
    var id: String { udid }
    let udid: String
    let name: String
    let osVersion: String
    let connectionType: String   // "USB" / "WiFi"
    let isAvailable: Bool
}

// MARK: - Development Team
/// An Apple Developer Team that can be selected for automatic signing.
struct DevelopmentTeam: Identifiable, Equatable, Hashable, Sendable {
    var id: String { teamID }
    let teamID: String
    let displayName: String
}

// MARK: - App Settings
struct AppSettings: Codable, Equatable, Sendable {
    /// Days between auto-resign runs (default 6, safe margin before 7-day expiry)
    var resignIntervalDays: Int = 6
    /// Hour of day to run (0–23)
    var scheduleHour: Int = 3
    /// Minute of hour to run (0–59)
    var scheduleMinute: Int = 0
    /// Path to Xcode.app (supports Beta)
    var xcodePath: String = "/Applications/Xcode-beta.app"
    /// Keep macOS awake during build
    var preventSleep: Bool = true
    /// Send macOS notification on completion
    var notifyOnComplete: Bool = true
    /// Auto-install schedule on launch
    var autoInstallSchedule: Bool = true
    /// Cooldown seconds between consecutive project builds (avoid resource spikes)
    var buildCooldownSeconds: Int = 5
    /// Enable automatic retry on failure
    var enableRetry: Bool = true
    /// Max retry attempts (0 = no retry)
    var maxRetries: Int = 2
    /// Minutes between retry attempts
    var retryIntervalMinutes: Int = 30

    func normalized() -> AppSettings {
        var s = self
        s.resignIntervalDays = min(max(s.resignIntervalDays, 1), 7)
        s.scheduleHour = min(max(s.scheduleHour, 0), 23)
        s.scheduleMinute = min(max(s.scheduleMinute, 0), 59)
        s.buildCooldownSeconds = min(max(s.buildCooldownSeconds, 0), 60)
        s.maxRetries = min(max(s.maxRetries, 0), 3)
        s.retryIntervalMinutes = min(max(s.retryIntervalMinutes, 1), 120)
        return s
    }
}

// MARK: - Build Mode
/// 本次执行的构建方式（日志/UI 展示用）。语义与实际执行严格对应：
/// - cold：首次构建（无工作区）或工作区被决策性清除后重建；
/// - incrementalChanged：保留工作区，项目有更新，Xcode 增量编译变化部分；
/// - incrementalUnchanged：保留工作区，项目未变化，仅重组产物并重新签名；
/// - cleanFallback：增量工作区损坏，已清除并完整重建（运行时回退）。
enum BuildMode: String, Codable, Sendable {
    case cold
    case incrementalChanged
    case incrementalUnchanged
    case cleanFallback
    // v1.6.0 首发使用过的旧语义值，仅保证旧日志可解码
    case legacyFull = "full"
    case legacyIncremental = "incremental"

    var label: String {
        switch self {
        case .cold: return "首次构建"
        case .incrementalChanged: return "增量构建 · 项目有更新"
        case .incrementalUnchanged: return "增量构建 · 项目未变化"
        case .cleanFallback: return "缓存失效 · 完整重建"
        case .legacyFull: return "完整构建"
        case .legacyIncremental: return "增量构建"
        }
    }

    var color: String {
        switch self {
        case .cold: return "blue"
        case .incrementalChanged: return "orange"
        case .incrementalUnchanged: return "green"
        case .cleanFallback: return "red"
        case .legacyFull: return "blue"
        case .legacyIncremental: return "green"
        }
    }
}

// MARK: - Device Install Summary
/// Structured per-device install outcome recorded with a build log entry,
/// so scheduled runs can be audited ("哪台设备装了哪个 App") without
/// parsing raw xcodebuild/devicectl text.
struct DeviceInstallSummary: Codable, Equatable, Hashable, Sendable {
    var udid: String
    var deviceName: String
    var success: Bool
    var attempts: Int
}

// MARK: - Build Log Entry
struct BuildLogEntry: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id = UUID()
    let date: Date
    let projectName: String
    var status: BuildStatus
    var output: String
    var durationSeconds: Double
    /// Device names that failed to install (nil = not recorded / N/A)
    var failedDevices: [String]? = nil
    /// Stable identifier for imported background-run logs.
    var sourceIdentifier: String? = nil
    /// File name (under the logs directory) that holds the full raw log.
    /// Empty means `output` already contains the full text. Keeps large
    /// xcodebuild logs out of config.json.
    var logFile: String? = nil
    /// Manual (GUI) or scheduled (worker) execution. nil = legacy entry.
    var source: ExecutionSource? = nil
    /// 本次解析/生成出来的主 .app 产物路径（安装失败时也可能存在）。
    /// v1.6 前的字段名是 installedAppPath，解码时兼容读取。
    var builtAppPath: String? = nil
    /// Per-device install outcomes for this run (nil = not recorded).
    var deviceInstallSummaries: [DeviceInstallSummary]? = nil
    /// 构建方式（完整/增量/缓存复用）。nil = 旧版日志。
    var buildMode: BuildMode? = nil

    var durationText: String {
        let m = Int(durationSeconds) / 60
        let s = Int(durationSeconds) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    /// Concise "where + why" summary for failed builds
    var errorSummary: BuildErrorSummary? {
        guard status == .failed else { return nil }
        let base = FailureClassifier.diagnose(output)
        // If specific devices failed, include them in the location
        if let names = failedDevices, !names.isEmpty {
            let devicePart = names.joined(separator: "、")
            let reason = base?.reason ?? "安装失败"
            return BuildErrorSummary(location: "安装 → \(devicePart)", reason: reason)
        }
        return base
    }
}

// MARK: - Build Error Summary
struct BuildErrorSummary: Equatable, Sendable {
    /// Where the problem is (e.g. "ContentView.swift:42", "签名", "安装")
    let location: String
    /// Why it failed (the actual error message)
    let reason: String
}

enum BuildStatus: String, Codable, Sendable {
    case success
    case failed
    case running
    case cancelled

    var label: String {
        switch self {
        case .success:   return "成功"
        case .failed:    return "失败"
        case .running:   return "运行中"
        case .cancelled: return "已取消"
        }
    }

    var symbolName: String {
        switch self {
        case .success:   return "checkmark.circle.fill"
        case .failed:    return "xmark.circle.fill"
        case .running:   return "arrow.triangle.2.circlepath"
        case .cancelled: return "minus.circle.fill"
        }
    }
}

// MARK: - Persisted App State
/// Schema-v2 persistence. v1 (the pre-1.5 release format) had no schemaVersion
/// key and no executionStates; ConfigStore migrates those transparently.
struct PersistedState: Codable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var projects: [iOSProject]
    var settings: AppSettings
    var executionStates: [ProjectExecutionState]
    var logs: [BuildLogEntry]

    init(
        projects: [iOSProject] = [],
        settings: AppSettings = AppSettings(),
        executionStates: [ProjectExecutionState] = [],
        logs: [BuildLogEntry] = [],
        schemaVersion: Int = PersistedState.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.projects = projects
        self.settings = settings
        self.executionStates = executionStates
        self.logs = logs
    }
}

// MARK: - Forward-compatible Codable
// All persisted types decode with `decodeIfPresent` + defaults so adding a
// field in a future version can never invalidate an existing config.json.
// The custom implementations live in extensions to preserve memberwise inits.

extension iOSProject {
    private enum CodingKeys: String, CodingKey {
        case id, name, projectPath, scheme, configuration, platform, teamID
        case deviceUDIDs, isEnabled, lastBuildDate, lastBuildStatus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath) ?? ""
        scheme = try c.decodeIfPresent(String.self, forKey: .scheme) ?? ""
        configuration = try c.decodeIfPresent(String.self, forKey: .configuration) ?? "Debug"
        platform = try c.decodeIfPresent(ProjectPlatform.self, forKey: .platform) ?? .ios
        teamID = try c.decodeIfPresent(String.self, forKey: .teamID)
        deviceUDIDs = try c.decodeIfPresent([String].self, forKey: .deviceUDIDs) ?? []
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        lastBuildDate = try c.decodeIfPresent(Date.self, forKey: .lastBuildDate)
        lastBuildStatus = try c.decodeIfPresent(BuildStatus.self, forKey: .lastBuildStatus)
    }
}

extension AppSettings {
    private enum CodingKeys: String, CodingKey {
        case resignIntervalDays, scheduleHour, scheduleMinute, xcodePath
        case preventSleep, notifyOnComplete, autoInstallSchedule
        case buildCooldownSeconds, enableRetry, maxRetries, retryIntervalMinutes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        resignIntervalDays = try c.decodeIfPresent(Int.self, forKey: .resignIntervalDays) ?? 6
        scheduleHour = try c.decodeIfPresent(Int.self, forKey: .scheduleHour) ?? 3
        scheduleMinute = try c.decodeIfPresent(Int.self, forKey: .scheduleMinute) ?? 0
        xcodePath = try c.decodeIfPresent(String.self, forKey: .xcodePath) ?? "/Applications/Xcode-beta.app"
        preventSleep = try c.decodeIfPresent(Bool.self, forKey: .preventSleep) ?? true
        notifyOnComplete = try c.decodeIfPresent(Bool.self, forKey: .notifyOnComplete) ?? true
        autoInstallSchedule = try c.decodeIfPresent(Bool.self, forKey: .autoInstallSchedule) ?? true
        buildCooldownSeconds = try c.decodeIfPresent(Int.self, forKey: .buildCooldownSeconds) ?? 5
        enableRetry = try c.decodeIfPresent(Bool.self, forKey: .enableRetry) ?? true
        maxRetries = try c.decodeIfPresent(Int.self, forKey: .maxRetries) ?? 2
        retryIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .retryIntervalMinutes) ?? 30
    }
}

extension BuildLogEntry {
    private enum CodingKeys: String, CodingKey {
        case id, date, projectName, status, output, durationSeconds
        case failedDevices, sourceIdentifier, logFile, source
        case builtAppPath, deviceInstallSummaries, buildMode
        // v1.6 前的字段名，仅用于解码兼容
        case legacyInstalledAppPath = "installedAppPath"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decode(Date.self, forKey: .date)
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName) ?? ""
        status = try c.decodeIfPresent(BuildStatus.self, forKey: .status) ?? .failed
        output = try c.decodeIfPresent(String.self, forKey: .output) ?? ""
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        failedDevices = try c.decodeIfPresent([String].self, forKey: .failedDevices)
        sourceIdentifier = try c.decodeIfPresent(String.self, forKey: .sourceIdentifier)
        logFile = try c.decodeIfPresent(String.self, forKey: .logFile)
        source = try c.decodeIfPresent(ExecutionSource.self, forKey: .source)
        builtAppPath = try c.decodeIfPresent(String.self, forKey: .builtAppPath)
            ?? c.decodeIfPresent(String.self, forKey: .legacyInstalledAppPath)
        deviceInstallSummaries = try c.decodeIfPresent([DeviceInstallSummary].self, forKey: .deviceInstallSummaries)
        // 未知 buildMode 值不致命：置 nil 保留日志本体
        buildMode = (try? c.decodeIfPresent(BuildMode.self, forKey: .buildMode)) ?? nil
    }

    // 旧字段名 installedAppPath 仅用于解码兼容；编码只写 builtAppPath。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(date, forKey: .date)
        try c.encode(projectName, forKey: .projectName)
        try c.encode(status, forKey: .status)
        try c.encode(output, forKey: .output)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encodeIfPresent(failedDevices, forKey: .failedDevices)
        try c.encodeIfPresent(sourceIdentifier, forKey: .sourceIdentifier)
        try c.encodeIfPresent(logFile, forKey: .logFile)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(builtAppPath, forKey: .builtAppPath)
        try c.encodeIfPresent(deviceInstallSummaries, forKey: .deviceInstallSummaries)
        try c.encodeIfPresent(buildMode, forKey: .buildMode)
    }
}

extension ProjectExecutionState {
    private enum CodingKeys: String, CodingKey {
        case projectID, lastAttemptDate, lastSuccessfulInstallDate
        case lastStatus, lastSource, lastFailureSummary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try c.decode(UUID.self, forKey: .projectID)
        lastAttemptDate = try c.decodeIfPresent(Date.self, forKey: .lastAttemptDate)
        lastSuccessfulInstallDate = try c.decodeIfPresent(Date.self, forKey: .lastSuccessfulInstallDate)
        lastStatus = try c.decodeIfPresent(BuildStatus.self, forKey: .lastStatus)
        lastSource = try c.decodeIfPresent(ExecutionSource.self, forKey: .lastSource)
        lastFailureSummary = try c.decodeIfPresent(String.self, forKey: .lastFailureSummary)
    }
}

extension PersistedState {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, projects, settings, executionStates, logs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A config without schemaVersion is the released v1 format.
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        projects = try c.decodeIfPresent([iOSProject].self, forKey: .projects) ?? []
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        executionStates = try c.decodeIfPresent([ProjectExecutionState].self, forKey: .executionStates) ?? []
        logs = try c.decodeIfPresent([BuildLogEntry].self, forKey: .logs) ?? []
    }
}
