import Foundation
import Darwin
@preconcurrency import UserNotifications
import AppKit

struct BuildResult: Sendable {
    let success: Bool
    let output: String
    var failedDeviceUDIDs: [String] = []
    var cancelled: Bool = false
    var retryable: Bool = false

    static func cancelledResult(output: String = "任务已取消") -> BuildResult {
        BuildResult(success: false, output: output, cancelled: true)
    }
}

/// Classification of a build/install failure for retry decisions.
enum BuildFailureClass: Equatable {
    /// Temporary (device offline, network hiccup) - retrying may help.
    case retryable
    /// Deterministic (profile missing device, quota full, bundle id taken) - retrying is pointless.
    case fatal
    /// Not recognized - conservative default that still allows retry.
    case unknown
}

private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    func register(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return false }
        self.process = process
        return true
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let running = process
        lock.unlock()
        if running?.isRunning == true {
            running?.terminate()
        }
    }
}

private actor IconDataCache {
    private var storage: [String: Data] = [:]

    func data(for key: String) -> Data? { storage[key] }
    func insert(_ data: Data, for key: String) { storage[key] = data }
}

/// Captures a process run with stdout and stderr kept separate.
///
/// JSON-producing commands (`xcodebuild -list -json`, `-showBuildSettings -json`,
/// `devicectl --json-output`) must only parse `stdout`; `xcodebuild` routinely
/// writes warnings/notes to stderr that would otherwise corrupt the JSON payload.
struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    /// Combined output for human-readable logs and error diagnosis.
    var combined: String {
        if stderr.isEmpty { return stdout }
        if stdout.isEmpty { return stderr }
        return stdout + "\n" + stderr
    }
}

/// Cross-process advisory lock so the GUI and the LaunchAgent background task
/// cannot `rm -rf` the same DerivedData directory while the other is building.
private final class CrossProcessLock {
    private var fd: Int32 = -1

    func acquire(at path: String) -> Bool {
        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return false }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            fd = descriptor
            return true
        }
        close(descriptor)
        return false
    }

    func release() {
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    deinit { release() }
}

enum BuildService {

    // MARK: - Run Process
    private static func run(
        _ executable: String,
        arguments: [String],
        environment extra: [String: String] = [:],
        currentDirectory: String? = nil
    ) async -> ProcessResult {
        let runningProcess = RunningProcess()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments

                    var environment = ProcessInfo.processInfo.environment
                    environment.merge(extra) { _, new in new }
                    process.environment = environment

                    if let currentDirectory {
                        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
                    }

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    guard runningProcess.register(process) else {
                        continuation.resume(returning: ProcessResult(exitCode: 130, stdout: "", stderr: "任务已取消"))
                        return
                    }
                    defer { runningProcess.clear() }

                    do {
                        try process.run()
                        // Drain stdout and stderr in parallel so a large volume on one
                        // stream cannot deadlock the other, then join.
                        var stdoutData = Data()
                        var stderrData = Data()
                        let group = DispatchGroup()
                        DispatchQueue.global().async(group: group) {
                            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        }
                        DispatchQueue.global().async(group: group) {
                            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        }
                        group.wait()
                        process.waitUntilExit()
                        continuation.resume(returning: ProcessResult(
                            exitCode: process.terminationStatus,
                            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                            stderr: String(data: stderrData, encoding: .utf8) ?? ""
                        ))
                    } catch {
                        continuation.resume(returning: ProcessResult(exitCode: 1, stdout: "", stderr: "启动进程失败: \(error.localizedDescription)"))
                    }
                }
            }
        } onCancel: {
            runningProcess.cancel()
        }
    }

    // MARK: - Paths
    private static func developerDirectory(xcodePath: String) -> String {
        xcodePath + "/Contents/Developer"
    }

    private static func xcodebuildPath(xcodePath: String) -> String {
        xcodePath + "/Contents/Developer/usr/bin/xcodebuild"
    }

    private static let xcrunPath = "/usr/bin/xcrun"
    private static let derivedDataRoot = URL(fileURLWithPath: "/tmp/ResignBuild", isDirectory: true)

    private static func environment(xcodePath: String) -> [String: String] {
        var path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for prefix in ["/opt/homebrew/bin", "/usr/local/bin"] where !path.split(separator: ":").contains(Substring(prefix)) {
            path = prefix + ":" + path
        }
        return [
            "DEVELOPER_DIR": developerDirectory(xcodePath: xcodePath),
            "PATH": path
        ]
    }

    static func validateXcode(at xcodePath: String) -> String? {
        let executable = xcodebuildPath(xcodePath: xcodePath)
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return "无效的 Xcode 路径：找不到可执行的 xcodebuild"
        }
        return nil
    }

    // MARK: - List Schemes
    static func listSchemes(projectPath: String, xcodePath: String) async -> [String] {
        guard validateXcode(at: xcodePath) == nil else { return [] }
        let isWorkspace = projectPath.hasSuffix(".xcworkspace")
        let flag = isWorkspace ? "-workspace" : "-project"
        let result = await run(
            xcodebuildPath(xcodePath: xcodePath),
            arguments: [flag, projectPath, "-list", "-json"],
            environment: environment(xcodePath: xcodePath)
        )
        guard result.exitCode == 0 else { return [] }

        if let data = result.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let project = json["project"] as? [String: Any] ?? json["workspace"] as? [String: Any],
           let schemes = project["schemes"] as? [String] {
            return schemes.filter { !$0.localizedCaseInsensitiveContains("Tests") }
        }
        return parseSchemesPlainText(result.stdout)
    }

    private static func parseSchemesPlainText(_ output: String) -> [String] {
        var schemes: [String] = []
        var inSchemes = false
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "Schemes:" { inSchemes = true; continue }
            if inSchemes {
                if trimmed.isEmpty { break }
                if !trimmed.localizedCaseInsensitiveContains("Tests") {
                    schemes.append(trimmed)
                }
            }
        }
        return schemes
    }

    // MARK: - List Devices
    static func listDevices(xcodePath: String) async -> [iOSDevice] {
        guard validateXcode(at: xcodePath) == nil else { return [] }
        let jsonURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("resign_devices_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        let result = await run(
            xcrunPath,
            arguments: ["devicectl", "list", "devices", "--json-output", jsonURL.path],
            environment: environment(xcodePath: xcodePath)
        )

        guard result.exitCode == 0,
              let data = try? Data(contentsOf: jsonURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let deviceList = result["devices"] as? [[String: Any]]
        else { return [] }

        return deviceList.compactMap { dictionary -> iOSDevice? in
            guard let hardware = dictionary["hardwareProperties"] as? [String: Any],
                  let udid = hardware["udid"] as? String,
                  hardware["reality"] as? String == "physical",
                  let properties = dictionary["deviceProperties"] as? [String: Any],
                  let name = properties["name"] as? String
            else { return nil }

            let osVersion = properties["osVersionNumber"] as? String ?? ""
            let bootState = properties["bootState"] as? String ?? ""
            let connection = dictionary["connectionProperties"] as? [String: Any]
            let transport = connection?["transportType"] as? String ?? ""
            let pairing = connection?["pairingState"] as? String ?? ""

            let connectionType: String
            switch transport {
            case "wired", "usb": connectionType = "USB"
            case "localNetwork": connectionType = "WiFi"
            default: connectionType = transport.isEmpty ? "未连接" : transport
            }

            return iOSDevice(
                udid: udid,
                name: name,
                osVersion: osVersion,
                connectionType: connectionType,
                isAvailable: pairing == "paired" && bootState == "booted" && !transport.isEmpty
            )
        }
        .sorted {
            if $0.isAvailable != $1.isAvailable { return $0.isAvailable && !$1.isAvailable }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - List Development Teams
    /// Returns the teams of the Apple IDs currently signed into Xcode, which is
    /// the authoritative set of teams that can actually sign apps. Falls back to
    /// codesigning certificates / local provisioning profiles if the Xcode
    /// account list cannot be read (e.g. Xcode has never been opened).
    static func listDevelopmentTeams() async -> [DevelopmentTeam] {
        var teams: [DevelopmentTeam] = []
        var seen = Set<String>()

        func append(_ teamID: String, _ displayName: String) {
            guard !seen.contains(teamID) else { return }
            seen.insert(teamID)
            teams.append(DevelopmentTeam(teamID: teamID, displayName: displayName))
        }

        // 1) Teams of the Apple IDs signed into Xcode (authoritative).
        let xcodePrefs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.dt.Xcode.plist")
        let plistResult = await run(
            "/usr/bin/plutil",
            arguments: [
                "-extract", "IDEProvisioningTeamByIdentifier", "json",
                "-o", "-", xcodePrefs.path
            ]
        )
        if plistResult.exitCode == 0,
           let data = plistResult.stdout.data(using: .utf8),
           let accounts = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (_, value) in accounts {
                guard let teamList = value as? [[String: Any]] else { continue }
                for team in teamList {
                    guard let teamID = team["teamID"] as? String, !teamID.isEmpty else { continue }
                    let teamName = team["teamName"] as? String ?? "Team \(teamID)"
                    append(teamID, teamName)
                }
            }
        }

        // 2) Fallback when Xcode's account list is unavailable: teams whose
        //    codesigning certificates are installed in the keychain, plus teams
        //    found in local provisioning profiles.
        if teams.isEmpty {
            let identityResult = await run(
                "/usr/bin/security",
                arguments: ["find-identity", "-v", "-p", "codesigning"]
            )
            for line in identityResult.stdout.components(separatedBy: .newlines) {
                guard let openQuote = line.range(of: "\""),
                      let closeQuote = line.range(of: "\"", range: openQuote.upperBound..<line.endIndex)
                else { continue }
                let certificateName = String(line[openQuote.upperBound..<closeQuote.lowerBound])
                if let teamID = extractTeamID(from: certificateName) {
                    append(teamID, certificateName)
                }
            }

            let profilesDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles", isDirectory: true)
            if let files = try? FileManager.default.contentsOfDirectory(
                at: profilesDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for url in files where url.pathExtension == "mobileprovision" {
                    let profileResult = await run(
                        "/usr/bin/security",
                        arguments: ["cms", "-D", "-i", url.path]
                    )
                    guard let data = profileResult.stdout.data(using: .utf8),
                          let plist = try? PropertyListSerialization.propertyList(
                            from: data,
                            options: [],
                            format: nil
                          ) as? [String: Any],
                          let teamID = (plist["TeamIdentifier"] as? [String])?.first,
                          !teamID.isEmpty
                    else { continue }
                    append(teamID, "Team \(teamID)（本机 Profile）")
                }
            }
        }

        return teams.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    /// Extracts the trailing "(TEAMID)" group from a codesigning certificate name,
    /// e.g. `Apple Development: John Appleseed (ABCDE12345)` -> `ABCDE12345`.
    static func extractTeamID(from certificateName: String) -> String? {
        guard let open = certificateName.lastIndex(of: "("),
              let close = certificateName.lastIndex(of: ")"),
              close > open
        else { return nil }

        let candidate = certificateName[certificateName.index(after: open)..<close]
            .trimmingCharacters(in: .whitespaces)
        guard candidate.count == 10,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber })
        else { return nil }
        return candidate
    }

    // MARK: - Build & Install
    static func buildAndInstall(
        project: iOSProject,
        xcodePath: String,
        deviceUDIDs: [String],
        maxAttempts: Int = 1,
        retryIntervalSeconds: Int = 60
    ) async -> BuildResult {
        if Task.isCancelled { return .cancelledResult() }

        // Cross-process lock: the GUI and the LaunchAgent background task share
        // the same /tmp/ResignBuild/<project UUID> directory and both `rm -rf`
        // it before building. Without a lock they can tear each other down.
        let runLock = CrossProcessLock()
        let lockPath = AppPaths.configDirectory.appendingPathComponent("resign.lock").path
        guard runLock.acquire(at: lockPath) else {
            return BuildResult(
                success: false,
                output: "已有 Resign 任务正在运行（跨进程锁被占用）。为避免后台任务与手动任务互相踩踏构建目录，本次已跳过。"
            )
        }
        defer { runLock.release() }

        if let validationError = validateXcode(at: xcodePath) {
            return BuildResult(success: false, output: validationError)
        }
        guard !project.scheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return BuildResult(success: false, output: "错误：项目尚未选择 Scheme")
        }
        guard FileManager.default.fileExists(atPath: project.projectPath) else {
            return BuildResult(success: false, output: "错误：项目路径不存在：\(project.projectPath)")
        }
        guard !deviceUDIDs.isEmpty else {
            return BuildResult(success: false, output: "错误：未找到可用的已连接设备", retryable: true)
        }

        let derivedData = derivedDataRoot.appendingPathComponent(project.id.uuidString, isDirectory: true)
        do {
            try prepareDerivedData(derivedData)
        } catch {
            return BuildResult(success: false, output: "错误：无法准备构建目录：\(error.localizedDescription)")
        }

        var baseArguments = [
            project.projectFlag, project.projectPath,
            "-scheme", project.scheme,
            "-configuration", project.configuration,
            "-destination", "generic/platform=iOS",
            "-derivedDataPath", derivedData.path,
            "-allowProvisioningUpdates",
            "CODE_SIGN_STYLE=Automatic"
        ]
        if let teamID = project.teamID, !teamID.isEmpty {
            baseArguments += ["DEVELOPMENT_TEAM=\(teamID)"]
        }

        var fullOutput = ""
        let settingsResult = await run(
            xcodebuildPath(xcodePath: xcodePath),
            arguments: baseArguments + ["-showBuildSettings", "-json"],
            environment: environment(xcodePath: xcodePath)
        )
        let expectedProduct = productPath(
            from: settingsResult.stdout,
            preferredNames: [project.scheme, project.projectName]
        )
        if settingsResult.exitCode != 0 {
            fullOutput += "=== BUILD SETTINGS ===\n\(settingsResult.combined)\n"
        }

        let attempts = min(max(maxAttempts, 1), 4)
        let retryDelay = min(max(retryIntervalSeconds, 1), 7_200)
        var buildSucceeded = false
        for attempt in 1...attempts {
            let buildResult = await run(
                xcodebuildPath(xcodePath: xcodePath),
                arguments: baseArguments + ["build"],
                environment: environment(xcodePath: xcodePath)
            )
            let buildOutput = buildResult.combined
            fullOutput += "=== BUILD \(attempt)/\(attempts) ===\n\(buildOutput)\n"

            if Task.isCancelled { return .cancelledResult(output: fullOutput + "\n任务已取消") }
            if buildResult.exitCode == 0 {
                buildSucceeded = true
                break
            }
            // Retry policy: only explicit transient failures are retried.
            // Compile/link/script errors and unrecognized failures are
            // deterministic in practice, so retrying just burns time.
            switch failureClass(buildOutput) {
            case .retryable:
                guard attempt < attempts else {
                    return BuildResult(success: false, output: fullOutput)
                }
                fullOutput += "\n检测到临时性构建错误，\(retryDelay) 秒后重试。\n"
                do {
                    try await Task.sleep(for: .seconds(retryDelay))
                } catch {
                    return .cancelledResult(output: fullOutput + "\n任务已取消")
                }
            case .fatal:
                fullOutput += "\n⚠️ 构建失败为确定性问题（签名/Profile/账号配置），重试不会成功，已停止重试。\n"
                return BuildResult(success: false, output: fullOutput)
            case .unknown:
                fullOutput += "\n⚠️ 构建失败原因无法识别，为安全起见不再自动重试；请检查日志后手动重试。\n"
                return BuildResult(success: false, output: fullOutput)
            }
        }
        guard buildSucceeded else {
            return BuildResult(success: false, output: fullOutput)
        }

        let appPath: String?
        if let expectedProduct, FileManager.default.fileExists(atPath: expectedProduct) {
            appPath = expectedProduct
        } else {
            appPath = findUnambiguousApp(
                in: derivedData,
                configuration: project.configuration,
                preferredNames: [project.scheme, project.projectName]
            )
        }

        guard let appPath else {
            fullOutput += "\n错误：无法确定本次构建生成的主 .app，已停止安装以避免安装错误产物\n"
            return BuildResult(success: false, output: fullOutput)
        }
        fullOutput += "\n本次产物: \(appPath)\n"

        var failedUDIDs: [String] = []
        for udid in deviceUDIDs {
            var installed = false
            for attempt in 1...attempts {
                if Task.isCancelled { return .cancelledResult(output: fullOutput + "\n任务已取消") }
                let installResult = await run(
                    xcrunPath,
                    arguments: ["devicectl", "device", "install", "app", "--device", udid, appPath],
                    environment: environment(xcodePath: xcodePath)
                )
                let installOutput = installResult.combined
                fullOutput += "\n=== INSTALL \(attempt)/\(attempts) → \(udid) ===\n\(installOutput)\n"
                if installResult.exitCode == 0 {
                    installed = true
                    break
                }
                if failureClass(installOutput) == .fatal {
                    fullOutput += "\n⚠️ 安装失败为确定性问题（如设备不在当前 Team 测试列表 / 免费签名配额已满），已停止对该设备重试。\n"
                    break
                }
                if attempt < attempts {
                    fullOutput += "\n安装失败，\(retryDelay) 秒后重试。\n"
                    do {
                        try await Task.sleep(for: .seconds(retryDelay))
                    } catch {
                        return .cancelledResult(output: fullOutput + "\n任务已取消")
                    }
                }
            }
            if !installed { failedUDIDs.append(udid) }
        }

        return BuildResult(
            success: failedUDIDs.isEmpty,
            output: fullOutput,
            failedDeviceUDIDs: failedUDIDs
        )
    }

    private static func prepareDerivedData(_ directory: URL) throws {
        let root = derivedDataRoot.standardizedFileURL.path + "/"
        let target = directory.standardizedFileURL.path
        guard target.hasPrefix(root), target.count > root.count else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if FileManager.default.fileExists(atPath: target) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func productPath(from output: String, preferredNames: [String]) -> String? {
        guard let data = output.data(using: .utf8),
              let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        var candidates: [(targetName: String, wrapperName: String, path: String)] = []
        for target in targets {
            guard let settings = target["buildSettings"] as? [String: Any],
                  let buildDirectory = settings["TARGET_BUILD_DIR"] as? String,
                  let wrapperName = settings["WRAPPER_NAME"] as? String,
                  wrapperName.hasSuffix(".app")
            else { continue }
            candidates.append((
                target["target"] as? String ?? "",
                wrapperName,
                URL(fileURLWithPath: buildDirectory).appendingPathComponent(wrapperName).path
            ))
        }
        for preferredName in preferredNames {
            if let match = candidates.first(where: {
                $0.targetName.caseInsensitiveCompare(preferredName) == .orderedSame
                    || URL(fileURLWithPath: $0.wrapperName).deletingPathExtension().lastPathComponent
                        .caseInsensitiveCompare(preferredName) == .orderedSame
            }) {
                return match.path
            }
        }
        return candidates.count == 1 ? candidates[0].path : nil
    }

    private static func findUnambiguousApp(
        in derivedData: URL,
        configuration: String,
        preferredNames: [String]
    ) -> String? {
        let directory = derivedData
            .appendingPathComponent("Build/Products", isDirectory: true)
            .appendingPathComponent("\(configuration)-iphoneos", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let apps = files.filter { $0.pathExtension == "app" }
        for preferredName in preferredNames {
            if let match = apps.first(where: {
                $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(preferredName) == .orderedSame
            }) {
                return match.path
            }
        }
        return apps.count == 1 ? apps[0].path : nil
    }

    static func isTransientFailure(_ output: String) -> Bool {
        let text = output.lowercased()
        let transientMarkers = [
            "timed out", "timeout", "temporarily unavailable", "device is locked",
            "device unavailable", "lost connection", "connection interrupted",
            "could not connect", "developer disk image", "network connection was lost",
            "is not paired", "device not paired", "pairing"
        ]
        return transientMarkers.contains { text.contains($0) }
    }

    /// Classifies a build/install failure. Deterministic errors (profile does
    /// not include the device, free-profile quota reached, bundle id already
    /// taken, team not signed in) are returned as `.fatal` so the caller stops
    /// retrying instead of appearing to hang for minutes/hours.
    static func failureClass(_ output: String) -> BuildFailureClass {
        let text = output.lowercased()
        let fatalMarkers = [
            "0xe8008012",
            "provisioning profile cannot be installed on this device",
            "doesn't include the currently connected device",
            "is not included in the provisioning profile",
            "mifreeprofilevalidatedapptracker",
            "maximum number of apps for free development profiles",
            "failed registering bundle identifier",
            "cannot be registered to your development team",
            "no account for team",
            "no profiles for",
            "developer mode is disabled",
            "developer mode has not been enabled",
            "certificate has expired",
            "certificate expired",
            "xcode license",
            "not enough space",
            "disk full"
        ]
        if fatalMarkers.contains(where: { text.contains($0) }) {
            return .fatal
        }
        if isTransientFailure(output) {
            return .retryable
        }
        return .unknown
    }

    // MARK: - App Icon Loading
    private static let iconCache = IconDataCache()

    @MainActor
    static func loadAppIcon(projectPath: String) async -> NSImage? {
        if let cached = await iconCache.data(for: projectPath) {
            return NSImage(data: cached)
        }
        let data = await Task.detached(priority: .utility) {
            findIconData(projectPath: projectPath)
        }.value
        guard let data else { return nil }
        await iconCache.insert(data, for: projectPath)
        return NSImage(data: data)
    }

    private static func findIconData(projectPath: String) -> Data? {
        let root = URL(fileURLWithPath: projectPath).deletingLastPathComponent()
        let fileManager = FileManager.default
        let skippedDirectories: Set<String> = [
            "Pods", "DerivedData", "Carthage", "build", ".build", "node_modules", ".git", "fastlane"
        ]

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var appIconSetURL: URL?
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name == "AppIcon.appiconset" {
                appIconSetURL = url
                break
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory && skippedDirectories.contains(name) {
                enumerator.skipDescendants()
            }
        }
        guard let appIconSetURL,
              let files = try? fileManager.contentsOfDirectory(
                at: appIconSetURL,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
              )
        else { return nil }

        let pngFiles = files.filter { $0.pathExtension.lowercased() == "png" }
        guard let largest = pngFiles.max(by: {
            let lhs = (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let rhs = (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return lhs < rhs
        }) else { return nil }
        return try? Data(contentsOf: largest)
    }

    // MARK: - Project Scanning
    static func scanProjects(in folder: URL) -> [URL] {
        var results: [URL] = []
        let fileManager = FileManager.default
        let skippedDirectories: Set<String> = [
            "Pods", "DerivedData", "Carthage", "build", ".build", "node_modules", ".git", "fastlane", ".swiftpm"
        ]

        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return results }

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") {
                if url.deletingLastPathComponent().pathExtension == "xcodeproj" {
                    enumerator.skipDescendants()
                    continue
                }
                results.append(url)
                enumerator.skipDescendants()
            } else {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory && skippedDirectories.contains(name) {
                    enumerator.skipDescendants()
                }
            }
        }
        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: - Notification
    @MainActor
    static func sendNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }
}
