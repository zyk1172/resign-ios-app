import Foundation
import Darwin

enum ScheduleManagerError: LocalizedError {
    case workerMissing
    case invalidXcode(String)
    case serializationFailed
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .workerMissing:
            return "找不到 ResignWorker（应位于 Resign.app/Contents/MacOS/ 内）。请使用完整的 App 包或重新构建。"
        case .invalidXcode(let message):
            return message
        case .serializationFailed:
            return "无法生成 launchd 配置文件"
        case .processFailed(let message):
            return message
        }
    }
}

/// Installs and manages the LaunchAgent. The agent's only job is to launch the
/// bundled Swift worker at the configured time — it carries no project or
/// settings snapshot. All scheduling behaviour lives in the worker, which
/// reads the same config.json as the GUI.
struct ScheduleManager: Sendable {
    static let label = "com.resign.auto"

    let plistURL: URL
    /// Path of the bundled worker binary (Contents/MacOS/ResignWorker).
    let workerExecutablePath: String?
    let logDirectory: URL
    let workingDirectory: URL
    /// Legacy bash engine script; deleted after a successful migration.
    let legacyScriptURL: URL

    static func workerExecutablePath() -> String? {
        guard let executableURL = Bundle.main.executableURL else { return nil }
        return executableURL.deletingLastPathComponent()
            .appendingPathComponent("ResignWorker").path
    }

    static func standard() -> ScheduleManager {
        ScheduleManager(
            plistURL: AppPaths.schedulePlistURL,
            workerExecutablePath: workerExecutablePath(),
            logDirectory: AppPaths.logDirectory,
            workingDirectory: AppPaths.configDirectory,
            legacyScriptURL: AppPaths.legacyScriptURL
        )
    }

    // MARK: - Plist (pure)

    func makePlist(workerPath: String, hour: Int, minute: Int) -> [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": [workerPath, "--scheduled-run"],
            "StartCalendarInterval": [
                "Hour": min(max(hour, 0), 23),
                "Minute": min(max(minute, 0), 59)
            ] as [String: Any],
            "StandardOutPath": logDirectory.appendingPathComponent("launchd_stdout.log").path,
            "StandardErrorPath": logDirectory.appendingPathComponent("launchd_stderr.log").path,
            "RunAtLoad": false,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "WorkingDirectory": workingDirectory.path,
            "EnvironmentVariables": [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            ]
        ]
    }

    func isCurrent(_ plist: [String: Any], workerPath: String, hour: Int, minute: Int) -> Bool {
        guard plist["StartInterval"] == nil,
              plist["Label"] as? String == Self.label,
              plist["RunAtLoad"] as? Bool == false,
              let arguments = plist["ProgramArguments"] as? [String],
              arguments == [workerPath, "--scheduled-run"],
              let calendar = plist["StartCalendarInterval"] as? [String: Any],
              let plistHour = calendar["Hour"] as? Int,
              let plistMinute = calendar["Minute"] as? Int
        else { return false }

        return plistHour == min(max(hour, 0), 23)
            && plistMinute == min(max(minute, 0), 59)
    }

    /// True when the installed agent is missing, unreadable, still the legacy
    /// bash engine, or its calendar time diverges from the settings.
    func needsUpdate(hour: Int, minute: Int) -> Bool {
        guard let workerPath = workerExecutablePath,
              FileManager.default.isExecutableFile(atPath: workerPath)
        else { return true }
        guard let data = try? Data(contentsOf: plistURL),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = object as? [String: Any]
        else { return true }
        return !isCurrent(plist, workerPath: workerPath, hour: hour, minute: minute)
    }

    // MARK: - Status

    var isInstalled: Bool {
        let result = Self.runLaunchctl(["print", "\(Self.userDomain)/\(Self.label)"])
        return result.exitCode == 0
    }

    // MARK: - Install / Uninstall

    func install(xcodePath: String, hour: Int, minute: Int) throws {
        if let error = XcodeToolchain.validate(xcodePath: xcodePath) {
            throw ScheduleManagerError.invalidXcode(error)
        }
        guard let workerPath = workerExecutablePath,
              FileManager.default.isExecutableFile(atPath: workerPath)
        else { throw ScheduleManagerError.workerMissing }

        let plist = makePlist(workerPath: workerPath, hour: hour, minute: minute)
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ) else {
            throw ScheduleManagerError.serializationFailed
        }

        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = Self.runLaunchctl(["bootout", "\(Self.userDomain)/\(Self.label)"])
        try data.write(to: plistURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)

        let result = Self.runLaunchctl(["bootstrap", Self.userDomain, plistURL.path])
        guard result.exitCode == 0 else {
            throw ScheduleManagerError.processFailed(
                result.output.isEmpty ? "launchd 任务装载失败" : "launchd 任务装载失败：\(result.output)"
            )
        }
        guard isInstalled else {
            throw ScheduleManagerError.processFailed("launchd 没有返回已装载状态")
        }

        // Migration: the legacy bash engine is replaced by the worker; remove
        // the stale script so it can never run again.
        if FileManager.default.fileExists(atPath: legacyScriptURL.path) {
            try? FileManager.default.removeItem(at: legacyScriptURL)
        }
    }

    func uninstall() throws {
        let result = Self.runLaunchctl(["bootout", "\(Self.userDomain)/\(Self.label)"])
        if result.exitCode != 0 && isInstalled {
            throw ScheduleManagerError.processFailed(
                result.output.isEmpty ? "launchd 任务卸载失败" : "launchd 任务卸载失败：\(result.output)"
            )
        }
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
        if FileManager.default.fileExists(atPath: legacyScriptURL.path) {
            try? FileManager.default.removeItem(at: legacyScriptURL)
        }
    }

    // MARK: - launchctl

    private static var userDomain: String { "gui/\(getuid())" }

    static func runLaunchctl(_ arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus, output)
        } catch {
            return (1, error.localizedDescription)
        }
    }
}
