import Foundation

// MARK: - iOS Project Configuration
struct iOSProject: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String = ""
    /// Path to .xcodeproj or .xcworkspace
    var projectPath: String = ""
    var scheme: String = ""
    var configuration: String = "Debug"
    /// Target device UDIDs; empty = first available device
    var deviceUDIDs: [String] = []
    var isEnabled: Bool = true
    /// Last build time
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

// MARK: - Connected iOS Device
struct iOSDevice: Identifiable, Equatable {
    var id: String { udid }
    let udid: String
    let name: String
    let osVersion: String
    let connectionType: String   // "USB" / "WiFi"
    let isAvailable: Bool
}

// MARK: - App Settings
struct AppSettings: Codable, Equatable {
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
}

// MARK: - Build Log Entry
struct BuildLogEntry: Identifiable, Codable, Hashable {
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

    var durationText: String {
        let m = Int(durationSeconds) / 60
        let s = Int(durationSeconds) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    /// Concise "where + why" summary for failed builds
    var errorSummary: BuildErrorSummary? {
        guard status == .failed else { return nil }
        let base = BuildErrorParser.summarize(output)
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
struct BuildErrorSummary: Equatable {
    /// Where the problem is (e.g. "ContentView.swift:42", "签名", "安装")
    let location: String
    /// Why it failed (the actual error message)
    let reason: String
}

/// Extracts a concise "where + why" summary from raw build output
enum BuildErrorParser {

    static func summarize(_ output: String) -> BuildErrorSummary? {
        let lines = output.components(separatedBy: .newlines)

        // 1. First meaningful "error:" line (xcodebuild / clang / swiftc)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let r = line.range(of: "error:", options: .caseInsensitive) else { continue }
            let before = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let reason = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)

            // Skip generic summary lines that carry no detail
            let low = reason.lowercased()
            if reason.isEmpty || low.hasPrefix("build commands failed") || low.hasPrefix("build failed") {
                continue
            }

            // Signing / provisioning problems
            if isSigningRelated(reason) {
                return BuildErrorSummary(location: "签名", reason: reason)
            }

            // Compiler error with a file path (optionally :line:col)
            if !before.isEmpty, before.contains("/") {
                let segs = before.components(separatedBy: ":")
                let filename = URL(fileURLWithPath: segs[0]).lastPathComponent
                if segs.count >= 2, !segs[1].isEmpty, segs[1].allSatisfy({ $0.isNumber }) {
                    return BuildErrorSummary(location: "\(filename):\(segs[1])", reason: reason)
                }
                return BuildErrorSummary(location: filename, reason: reason)
            }

            // No path info — fall back to the failing phase
            return BuildErrorSummary(location: phase(of: output), reason: reason)
        }

        // 2. devicectl / install failures that don't use the "error:" prefix
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.contains("Failed to install") || line.contains("install app failed") {
                return BuildErrorSummary(location: "安装", reason: line)
            }
        }

        // 3. Last resort
        if output.contains("未找到已连接设备") {
            return BuildErrorSummary(location: "设备", reason: "未找到已连接设备，请检查 iPhone 是否已连接并信任此电脑")
        }
        if output.contains("未找到 .app 产物") {
            return BuildErrorSummary(location: "构建", reason: "未找到 .app 产物，请检查 Scheme 与 Configuration 配置")
        }

        return nil
    }

    private static func isSigningRelated(_ reason: String) -> Bool {
        let keywords = ["signing certificate", "provisioning profile", "no profile for team",
                        "code signing", "requires a development team", "signing"]
        let low = reason.lowercased()
        return keywords.contains { low.contains($0) }
    }

    private static func phase(of output: String) -> String {
        if output.contains("=== INSTALL") { return "安装" }
        return "构建"
    }
}

enum BuildStatus: String, Codable {
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
struct PersistedState: Codable {
    var projects: [iOSProject] = []
    var settings: AppSettings = AppSettings()
    var logs: [BuildLogEntry] = []
}
