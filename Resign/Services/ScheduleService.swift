import Foundation
import Darwin

enum ScheduleServiceError: LocalizedError {
    case invalidXcode(String)
    case serializationFailed
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidXcode(let message): return message
        case .serializationFailed: return "无法生成 launchd 配置文件"
        case .processFailed(let message): return message
        }
    }
}

enum ScheduleService {
    static let label = "com.resign.auto"
    static let scheduleVersion = 4

    private static var userDomain: String { "gui/\(getuid())" }

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool {
        let result = runLaunchctl(["print", "\(userDomain)/\(label)"])
        return result.exitCode == 0
    }

    static var isPlistPresent: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func needsUpdate(settings: AppSettings) -> Bool {
        guard let script = try? String(contentsOf: AppPaths.scriptURL, encoding: .utf8),
              script.contains("# Resign schedule version: \(scheduleVersion)"),
              let data = try? Data(contentsOf: plistURL),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = object as? [String: Any]
        else {
            return true
        }

        return !isCurrentPlist(plist, scriptURL: AppPaths.scriptURL, settings: settings)
    }

    static func isCurrentPlist(
        _ plist: [String: Any],
        scriptURL: URL,
        settings: AppSettings
    ) -> Bool {
        guard plist["StartInterval"] == nil,
              plist["Label"] as? String == label,
              plist["RunAtLoad"] as? Bool == false,
              let arguments = plist["ProgramArguments"] as? [String],
              arguments == ["/bin/bash", scriptURL.path],
              let calendar = plist["StartCalendarInterval"] as? [String: Any],
              let hour = calendar["Hour"] as? Int,
              let minute = calendar["Minute"] as? Int
        else {
            return false
        }

        return hour == min(max(settings.scheduleHour, 0), 23)
            && minute == min(max(settings.scheduleMinute, 0), 59)
    }

    static func install(scriptURL: URL, settings: AppSettings, projects: [iOSProject]) throws {
        if let error = BuildService.validateXcode(at: settings.xcodePath) {
            throw ScheduleServiceError.invalidXcode(error)
        }

        try generateScript(at: scriptURL, settings: settings, projects: projects)
        let plist = makePlist(scriptURL: scriptURL, settings: settings)
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ) else {
            throw ScheduleServiceError.serializationFailed
        }

        let agentDirectory = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
        _ = runLaunchctl(["bootout", "\(userDomain)/\(label)"])
        try data.write(to: plistURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)

        let result = runLaunchctl(["bootstrap", userDomain, plistURL.path])
        guard result.exitCode == 0 else {
            throw ScheduleServiceError.processFailed(
                result.output.isEmpty ? "launchd 任务装载失败" : "launchd 任务装载失败：\(result.output)"
            )
        }
        guard isInstalled else {
            throw ScheduleServiceError.processFailed("launchd 没有返回已装载状态")
        }
    }

    static func uninstall() throws {
        let result = runLaunchctl(["bootout", "\(userDomain)/\(label)"])
        if result.exitCode != 0 && isInstalled {
            throw ScheduleServiceError.processFailed(
                result.output.isEmpty ? "launchd 任务卸载失败" : "launchd 任务卸载失败：\(result.output)"
            )
        }
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    static func makePlist(scriptURL: URL, settings: AppSettings) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": ["/bin/bash", scriptURL.path],
            "StartCalendarInterval": [
                "Hour": min(max(settings.scheduleHour, 0), 23),
                "Minute": min(max(settings.scheduleMinute, 0), 59)
            ] as [String: Any],
            "StandardOutPath": AppPaths.logDirectory.appendingPathComponent("stdout.log").path,
            "StandardErrorPath": AppPaths.logDirectory.appendingPathComponent("stderr.log").path,
            "RunAtLoad": false,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "WorkingDirectory": AppPaths.configDirectory.path,
            "EnvironmentVariables": [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            ]
        ]
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func generateScript(at url: URL, settings: AppSettings, projects: [iOSProject]) throws {
        let script = scriptText(settings: settings, projects: projects)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func scriptText(settings: AppSettings, projects: [iOSProject]) -> String {
        let developerDirectory = settings.xcodePath + "/Contents/Developer"
        let xcodebuild = settings.xcodePath + "/Contents/Developer/usr/bin/xcodebuild"
        let logDirectory = AppPaths.logDirectory.path
        let lastSuccessFile = AppPaths.lastScheduledSuccessURL.path
        let enabled = projects.filter { $0.isEnabled && !$0.projectPath.isEmpty }
        let retryCount = min(max(settings.maxRetries, 0), 3)
        let maxAttempts = settings.enableRetry ? 1 + retryCount : 1
        let retrySeconds = min(max(settings.retryIntervalMinutes, 1), 120) * 60
        let intervalDays = min(max(settings.resignIntervalDays, 1), 7)
        let cooldownSeconds = min(max(settings.buildCooldownSeconds, 0), 60)

        var script = """
        #!/bin/bash
        # Resign schedule version: \(scheduleVersion)
        # Generated by Resign.app. User-controlled values are shell-quoted.

        set -uo pipefail
        export DEVELOPER_DIR=\(shellQuote(developerDirectory))
        export PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
        XCODEBUILD=\(shellQuote(xcodebuild))
        XCRUN='/usr/bin/xcrun'
        PLUTIL='/usr/bin/plutil'
        LOG_DIR=\(shellQuote(logDirectory))
        LAST_SUCCESS_FILE=\(shellQuote(lastSuccessFile))
        INTERVAL_DAYS=\(intervalDays)
        PREVENT_SLEEP=\(settings.preventSleep ? 1 : 0)
        NOTIFY_ON_COMPLETE=\(settings.notifyOnComplete ? 1 : 0)
        PROJECT_COUNT=\(enabled.count)

        mkdir -p "$LOG_DIR"

        now_epoch=$(date '+%s')
        if [ -f "$LAST_SUCCESS_FILE" ]; then
            last_epoch=$(tr -dc '0-9' < "$LAST_SUCCESS_FILE")
            if [ -n "$last_epoch" ]; then
                due_day=$(date -r "$last_epoch" -v+"${INTERVAL_DAYS}"d '+%Y%m%d' 2>/dev/null || true)
                today=$(date '+%Y%m%d')
                if [[ "$due_day" =~ ^[0-9]{8}$ ]] && [ "$today" -lt "$due_day" ]; then
                    exit 0
                fi
            fi
        fi

        timestamp=$(date '+%Y%m%d_%H%M%S')
        LOG_FILE="$LOG_DIR/resign_$timestamp.log"
        STATUS_FILE="$LOG_DIR/run_$timestamp.status"
        RUN_OK=1

        log() {
            printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$1" | tee -a "$LOG_FILE"
        }

        log '=== Resign 自动任务开始 ==='

        DEVICE_UDID=$("$XCRUN" devicectl list devices 2>/dev/null \\
            | grep 'physical' \\
            | grep 'available' \\
            | grep -oiE '[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}' \\
            | head -1 || true)

        if [ "$PROJECT_COUNT" -eq 0 ]; then
            log '错误：没有可执行的项目'
            RUN_OK=0
        fi

        """

        for (index, project) in enabled.enumerated() {
            let projectName = shellQuote(project.name)
            let projectPath = shellQuote(project.projectPath)
            let scheme = shellQuote(project.scheme)
            let configuration = shellQuote(project.configuration)
            let derivedData = shellQuote("/tmp/ResignBuild/\(project.id.uuidString)")

            let teamSigningArgument: String
            if let teamID = project.teamID, !teamID.isEmpty {
                teamSigningArgument = "DEVELOPMENT_TEAM=\(shellQuote(teamID)) \\\n                    "
            } else {
                teamSigningArgument = ""
            }
            let projectIdentifier = shellQuote(project.id.uuidString)
            let deviceValues = project.deviceUDIDs.map(shellQuote).joined(separator: " ")
            let deviceSetup: String
            if project.deviceUDIDs.isEmpty {
                deviceSetup = "DEVICE_LIST=()\nif [ -n \"$DEVICE_UDID\" ]; then DEVICE_LIST+=(\"$DEVICE_UDID\"); fi"
            } else {
                deviceSetup = "DEVICE_LIST=(\(deviceValues))"
            }

            script += """

            PROJECT_NAME=\(projectName)
            PROJECT_PATH=\(projectPath)
            PROJECT_SCHEME=\(scheme)
            PROJECT_CONFIGURATION=\(configuration)
            PROJECT_ID=\(projectIdentifier)
            DERIVED_DATA=\(derivedData)
            \(deviceSetup)

            log "项目：$PROJECT_NAME"

            if [ -z "$PROJECT_SCHEME" ]; then
                log "✗ $PROJECT_NAME 未设置 Scheme"
                RUN_OK=0
                continue
            fi

            if [ ! -e "$PROJECT_PATH" ]; then
                log "✗ $PROJECT_NAME 的项目路径不存在"
                RUN_OK=0
                continue
            fi

            if [ "${#DEVICE_LIST[@]}" -eq 0 ]; then
                log "✗ $PROJECT_NAME 没有可用设备，将在下次计划中重试"
                RUN_OK=0
                continue
            fi

            case "$DERIVED_DATA" in
                /tmp/ResignBuild/*) /bin/rm -rf -- "$DERIVED_DATA" ;;
                *) log "✗ 拒绝使用不安全的构建目录"; RUN_OK=0; continue ;;
            esac
            mkdir -p "$DERIVED_DATA"

            BUILD_SETTINGS_FILE="$LOG_DIR/buildsettings_${PROJECT_ID}_$timestamp.json"
            "$XCODEBUILD" \\
                \(project.projectFlag) "$PROJECT_PATH" \\
                -scheme "$PROJECT_SCHEME" \\
                -configuration "$PROJECT_CONFIGURATION" \\
                -destination 'generic/platform=iOS' \\
                -derivedDataPath "$DERIVED_DATA" \\
                -allowProvisioningUpdates \\
                CODE_SIGN_STYLE=Automatic \\
                \(teamSigningArgument)-showBuildSettings -json > "$BUILD_SETTINGS_FILE" 2>> "$LOG_FILE"

            TARGET_BUILD_DIR=$("$PLUTIL" -extract 0.buildSettings.TARGET_BUILD_DIR raw -o - "$BUILD_SETTINGS_FILE" 2>/dev/null || true)
            WRAPPER_NAME=$("$PLUTIL" -extract 0.buildSettings.WRAPPER_NAME raw -o - "$BUILD_SETTINGS_FILE" 2>/dev/null || true)
            /bin/rm -f -- "$BUILD_SETTINGS_FILE"

            if [ -z "$TARGET_BUILD_DIR" ] || [ -z "$WRAPPER_NAME" ]; then
                log "✗ $PROJECT_NAME 无法确定主 App 产物路径"
                RUN_OK=0
                continue
            fi

            log "构建 $PROJECT_NAME…"
            if [ "$PREVENT_SLEEP" -eq 1 ]; then
                /usr/bin/caffeinate -dimsu "$XCODEBUILD" \\
                    \(project.projectFlag) "$PROJECT_PATH" \\
                    -scheme "$PROJECT_SCHEME" \\
                    -configuration "$PROJECT_CONFIGURATION" \\
                    -destination 'generic/platform=iOS' \\
                    -derivedDataPath "$DERIVED_DATA" \\
                    -allowProvisioningUpdates \\
                    CODE_SIGN_STYLE=Automatic \\
                    \(teamSigningArgument)build >> "$LOG_FILE" 2>&1
            else
                "$XCODEBUILD" \\
                    \(project.projectFlag) "$PROJECT_PATH" \\
                    -scheme "$PROJECT_SCHEME" \\
                    -configuration "$PROJECT_CONFIGURATION" \\
                    -destination 'generic/platform=iOS' \\
                    -derivedDataPath "$DERIVED_DATA" \\
                    -allowProvisioningUpdates \\
                    CODE_SIGN_STYLE=Automatic \\
                    \(teamSigningArgument)build >> "$LOG_FILE" 2>&1
            fi
            BUILD_EXIT=$?

            if [ "$BUILD_EXIT" -ne 0 ]; then
                log "✗ $PROJECT_NAME 构建失败；编译或签名错误不会盲目重复构建"
                RUN_OK=0
                continue
            fi

            APP_PATH="$TARGET_BUILD_DIR/$WRAPPER_NAME"
            if [ ! -d "$APP_PATH" ]; then
                log "✗ $PROJECT_NAME 的预期 App 产物不存在"
                RUN_OK=0
                continue
            fi

            PROJECT_OK=0
            ATTEMPT=1
            while [ "$ATTEMPT" -le \(maxAttempts) ]; do
                ALL_DEVICES_OK=1
                for TARGET_UDID in "${DEVICE_LIST[@]}"; do
                    log "安装 $PROJECT_NAME → ${TARGET_UDID}（第 ${ATTEMPT}/\(maxAttempts) 次）"
                    "$XCRUN" devicectl device install app \\
                        --device "$TARGET_UDID" "$APP_PATH" >> "$LOG_FILE" 2>&1
                    if [ $? -ne 0 ]; then
                        log "✗ $PROJECT_NAME → ${TARGET_UDID} 安装失败"
                        ALL_DEVICES_OK=0
                    fi
                done

                if [ "$ALL_DEVICES_OK" -eq 1 ]; then
                    PROJECT_OK=1
                    log "✓ $PROJECT_NAME 全部安装成功"
                    break
                fi
                if [ "$ATTEMPT" -lt \(maxAttempts) ]; then
                    log "等待 \(retrySeconds) 秒后重试安装…"
                    sleep \(retrySeconds)
                fi
                ATTEMPT=$((ATTEMPT + 1))
            done

            if [ "$PROJECT_OK" -ne 1 ]; then
                RUN_OK=0
            fi

            """

            if index < enabled.count - 1 && cooldownSeconds > 0 {
                script += "\nsleep \(cooldownSeconds)\n"
            }
        }

        script += """

        if [ "$RUN_OK" -eq 1 ] && [ "$PROJECT_COUNT" -gt 0 ]; then
            date '+%s' > "$LAST_SUCCESS_FILE"
            printf 'success\n' > "$STATUS_FILE"
            log '=== Resign 自动任务成功 ==='
            if [ "$NOTIFY_ON_COMPLETE" -eq 1 ]; then
                osascript -e 'display notification "所有项目已成功构建并安装" with title "Resign"' 2>/dev/null || true
            fi
            exit 0
        fi

        printf 'failed\n' > "$STATUS_FILE"
        log '=== Resign 自动任务失败 ==='
        if [ "$NOTIFY_ON_COMPLETE" -eq 1 ]; then
            osascript -e 'display notification "自动任务失败，请打开 Resign 查看日志" with title "Resign"' 2>/dev/null || true
        fi
        exit 1
        """

        return script + "\n"
    }

    private static func runLaunchctl(_ arguments: [String]) -> (exitCode: Int32, output: String) {
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
