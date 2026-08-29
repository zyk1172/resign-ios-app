import Foundation

/// Installs a built macOS .app into the local Applications folder.
///
/// Mirrors the battle-tested install script flow: quit a running instance,
/// stage a copy next to the destination, verify its signature, then swap with
/// rollback on failure. Every external command goes through the ProcessRunner
/// with argument arrays — no shell string concatenation.
struct MacAppInstaller: Sendable {
    struct Outcome: Sendable {
        let success: Bool
        let output: String
    }

    let runner: ProcessRunning
    /// Injectable for tests; production installs into /Applications.
    var applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)

    func install(appPath: String) async -> Outcome {
        var log = ""
        let bundleName = URL(fileURLWithPath: appPath).lastPathComponent // "Foo.app"
        guard bundleName.hasSuffix(".app"), bundleName.count > 4 else {
            return Outcome(success: false, output: "错误：产物不是 .app 包，已停止安装")
        }
        let baseName = String(bundleName.dropLast(4))
        guard !baseName.isEmpty, !baseName.contains("/"),
              !baseName.contains("\""), !baseName.contains("\\") else {
            return Outcome(success: false, output: "错误：产物名称非法，已停止安装")
        }

        let fileManager = FileManager.default
        let destination = applicationsDirectory.appendingPathComponent(bundleName)
        let staging = applicationsDirectory.appendingPathComponent(".\(baseName).installing.app")
        let backup = fileManager.temporaryDirectory
            .appendingPathComponent("Resign.previous.\(UUID().uuidString).\(bundleName)")

        // 1) A running instance must not be replaced under its own feet.
        if await isRunning(baseName) {
            log += "检测到 \(baseName) 正在运行，请求退出…\n"
            _ = await runner.run("/usr/bin/osascript", arguments: ["-e", "quit app \"\(baseName)\""])
            try? await Task.sleep(for: .seconds(1))
            if await isRunning(baseName) {
                log += "仍未退出，发送 TERM 信号…\n"
                _ = await runner.run("/usr/bin/pkill", arguments: ["-TERM", "-x", baseName])
                try? await Task.sleep(for: .seconds(1))
            }
        }

        // 2) Stage a copy inside the applications directory, then verify it
        //    before anything on disk is replaced.
        try? fileManager.removeItem(at: staging)

        do {
            try fileManager.copyItem(atPath: appPath, toPath: staging.path)
            log += "已复制产物到暂存目录\n"
        } catch {
            try? fileManager.removeItem(at: staging)
            return Outcome(success: false, output: log + "\n错误：复制产物失败：\(error.localizedDescription)")
        }

        let verify = await runner.run(
            "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", staging.path]
        )
        log += "$ codesign --verify → exit \(verify.exitCode)\n"
        guard verify.exitCode == 0 else {
            try? fileManager.removeItem(at: staging)
            log += verify.combined + "\n"
            return Outcome(success: false, output: log + "\n错误：暂存产物签名校验失败，已保留现有安装")
        }

        // 3) Swap with rollback.
        var backupCreated = false
        if fileManager.fileExists(atPath: destination.path) {
            do {
                try fileManager.moveItem(at: destination, to: backup)
                backupCreated = true
            } catch {
                try? fileManager.removeItem(at: staging)
                return Outcome(success: false, output: log + "\n错误：无法备份现有应用：\(error.localizedDescription)")
            }
        }
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            if backupCreated {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            try? fileManager.removeItem(at: staging)
            return Outcome(
                success: false,
                output: log + "\n错误：安装失败（/Applications 可能需要管理员权限）：\(error.localizedDescription)"
            )
        }
        if backupCreated {
            try? fileManager.removeItem(at: backup)
        }

        log += "✓ 已安装到 \(destination.path)\n"
        return Outcome(success: true, output: log)
    }

    private func isRunning(_ processName: String) async -> Bool {
        let result = await runner.run("/usr/bin/pgrep", arguments: ["-x", processName])
        return result.exitCode == 0
    }
}
