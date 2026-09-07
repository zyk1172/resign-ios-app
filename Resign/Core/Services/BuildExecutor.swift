import Foundation

/// Result of checking whether a Git-backed source tree is current before build.
/// `success == false` means the caller must not continue with xcodebuild because
/// doing so could produce an app from stale or ambiguous source.
struct GitSourceSyncResult: Sendable, Equatable {
    let success: Bool
    let didUpdate: Bool
    let log: String

    static let skipped = GitSourceSyncResult(success: true, didUpdate: false, log: "")
}

/// Keeps Git-backed project sources on the latest commit of the branch's remote
/// tracking ref. Updates are deliberately limited to clean, fast-forward-only
/// moves so Resign never overwrites local work or chooses a branch implicitly.
struct GitSourceSynchronizer: Sendable {
    let runner: ProcessRunning

    static let gitExecutable = "/usr/bin/git"

    /// Finds the nearest enclosing Git repository for an .xcodeproj/.xcworkspace.
    /// Supports both normal `.git` directories and worktree/submodule `.git` files.
    static func repositoryRoot(for projectPath: String) -> URL? {
        var directory = URL(fileURLWithPath: projectPath)
            .standardizedFileURL
            .deletingLastPathComponent()
        let fileManager = FileManager.default

        while true {
            if fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
    }

    func synchronize(projectPath: String) async -> GitSourceSyncResult {
        guard let root = Self.repositoryRoot(for: projectPath) else { return .skipped }
        return await synchronize(repositoryRoot: root)
    }

    func synchronize(repositoryRoot root: URL) async -> GitSourceSyncResult {
        let remotesResult = await git(root, ["remote"])
        guard remotesResult.exitCode == 0 else {
            return failure("无法读取 Git 远端配置，已停止构建，避免使用无法确认版本的源码。")
        }
        let remotes = remotesResult.stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !remotes.isEmpty else {
            // A local-only Git repository has no remote version to compare with.
            return .skipped
        }

        let branchResult = await git(root, ["branch", "--show-current"])
        guard branchResult.exitCode == 0 else {
            return failure("无法读取当前 Git 分支，已停止构建。")
        }
        let branch = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else {
            return failure("源码仓库当前处于 detached HEAD；无法判断应跟踪哪个远端最新分支，已停止构建。")
        }

        let upstreamResult = await git(
            root,
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]
        )

        let remote: String
        let targetRef: String
        if upstreamResult.exitCode == 0 {
            let upstream = upstreamResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !upstream.isEmpty else {
                return failure("当前分支的 upstream 为空，无法确认远端最新版本，已停止构建。")
            }
            let matchingRemote = remotes
                .sorted { $0.count > $1.count }
                .first { upstream == $0 || upstream.hasPrefix($0 + "/") }
            guard let matchingRemote else {
                return failure("无法从当前分支 upstream 解析远端名称，已停止构建。")
            }
            remote = matchingRemote
            targetRef = upstream
        } else {
            // Repositories cloned without an explicit upstream are still common.
            // Use origin/<same branch> when unambiguous; never guess across several remotes.
            if remotes.contains("origin") {
                remote = "origin"
            } else if remotes.count == 1, let onlyRemote = remotes.first {
                remote = onlyRemote
            } else {
                return failure("当前分支没有 upstream，且存在多个 Git 远端；无法安全判断最新版本来源，已停止构建。")
            }
            targetRef = "\(remote)/\(branch)"
        }

        let fetchResult = await git(root, ["fetch", "--prune", remote])
        guard fetchResult.exitCode == 0 else {
            return failure("Git fetch 失败，无法确认远端最新提交；本次停止构建，避免继续构建旧版本。")
        }

        let localResult = await git(root, ["rev-parse", "HEAD"])
        let remoteResult = await git(root, ["rev-parse", targetRef])
        guard localResult.exitCode == 0, remoteResult.exitCode == 0 else {
            return failure("远端分支 \(targetRef) 不存在或提交无法解析，已停止构建。")
        }

        let localSHA = localResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteSHA = remoteResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localSHA.isEmpty, !remoteSHA.isEmpty else {
            return failure("Git 提交信息为空，无法验证源码版本，已停止构建。")
        }

        if localSHA == remoteSHA {
            return GitSourceSyncResult(
                success: true,
                didUpdate: false,
                log: "源码已是最新：\(targetRef) @ \(shortSHA(remoteSHA))"
            )
        }

        // If remote is already an ancestor of local HEAD, local contains every
        // remote commit plus additional local commits. No update is required.
        let remoteIsAncestor = await git(root, ["merge-base", "--is-ancestor", targetRef, "HEAD"])
        if remoteIsAncestor.exitCode == 0 {
            return GitSourceSyncResult(
                success: true,
                didUpdate: false,
                log: "本地分支已包含远端最新提交：\(targetRef) @ \(shortSHA(remoteSHA))（本地存在额外提交）"
            )
        }
        guard remoteIsAncestor.exitCode == 1 else {
            return failure("无法比较本地与远端提交关系，已停止构建。")
        }

        let localIsAncestor = await git(root, ["merge-base", "--is-ancestor", "HEAD", targetRef])
        guard localIsAncestor.exitCode == 0 else {
            if localIsAncestor.exitCode == 1 {
                return failure("本地分支与 \(targetRef) 已发生分叉；为避免覆盖本地提交，不自动合并，也不构建可能过期的源码。")
            }
            return failure("无法比较本地与远端提交关系，已停止构建。")
        }

        // Local is strictly behind. Only a clean worktree may be moved forward.
        let statusResult = await git(root, ["status", "--porcelain"])
        guard statusResult.exitCode == 0 else {
            return failure("无法检查 Git 工作区状态，已停止构建。")
        }
        guard statusResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return failure("检测到远端已有新提交，但本地存在未提交修改；为避免覆盖修改，本次不自动更新且停止构建。请先提交、暂存或清理修改后重试。")
        }

        let mergeResult = await git(root, ["merge", "--ff-only", targetRef])
        guard mergeResult.exitCode == 0 else {
            return failure("检测到远端新版本，但 fast-forward 更新失败；本次停止构建，避免继续构建旧版本。")
        }

        let verifiedResult = await git(root, ["rev-parse", "HEAD"])
        let verifiedSHA = verifiedResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard verifiedResult.exitCode == 0, verifiedSHA == remoteSHA else {
            return failure("Git 更新后校验失败：本地 HEAD 与远端最新提交不一致，已停止构建。")
        }

        return GitSourceSyncResult(
            success: true,
            didUpdate: true,
            log: "检测到源码更新并已安全快进：\(shortSHA(localSHA)) → \(shortSHA(remoteSHA))（\(targetRef)）"
        )
    }

    private func git(_ root: URL, _ arguments: [String]) async -> ProcessResult {
        await runner.run(
            Self.gitExecutable,
            arguments: ["-C", root.path] + arguments,
            environment: ["GIT_TERMINAL_PROMPT": "0"]
        )
    }

    private func failure(_ message: String) -> GitSourceSyncResult {
        GitSourceSyncResult(success: false, didUpdate: false, log: "源码版本检查失败：\(message)")
    }

    private func shortSHA(_ sha: String) -> String {
        String(sha.prefix(8))
    }
}

private actor GitSourceSyncCache {
    private var values: [String: GitSourceSyncResult] = [:]

    func value(for repositoryRoot: String) -> GitSourceSyncResult? {
        values[repositoryRoot]
    }

    func store(_ value: GitSourceSyncResult, for repositoryRoot: String) {
        values[repositoryRoot] = value
    }
}

/// Runs `xcodebuild` (single invocations only; retry decisions belong to
/// RetryPolicy / BuildCoordinator).
struct BuildExecutor: Sendable {
    let runner: ProcessRunning
    private let sourceSyncCache: GitSourceSyncCache

    init(runner: ProcessRunning) {
        self.runner = runner
        self.sourceSyncCache = GitSourceSyncCache()
    }

    /// Common xcodebuild arguments for one project. Team is injected through
    /// DEVELOPMENT_TEAM so automatic signing uses the user-selected team.
    static func baseArguments(for project: iOSProject, derivedDataPath: String) -> [String] {
        let destination = project.platform == .macos ? "platform=macOS" : "generic/platform=iOS"
        var arguments = [
            project.projectFlag, project.projectPath,
            "-scheme", project.scheme,
            "-configuration", project.configuration,
            "-destination", destination,
            "-derivedDataPath", derivedDataPath,
            "-allowProvisioningUpdates",
            "CODE_SIGN_STYLE=Automatic"
        ]
        if let teamID = project.teamID, !teamID.isEmpty {
            arguments += ["DEVELOPMENT_TEAM=\(teamID)"]
        }
        return arguments
    }

    func showBuildSettings(arguments: [String], xcodePath: String) async -> ProcessResult {
        let sourceSync = await ensureLatestSource(arguments: arguments)
        guard sourceSync.success else {
            return ProcessResult(exitCode: 1, stdout: "", stderr: sourceSync.log)
        }

        return await runner.run(
            XcodeToolchain.xcodebuildPath(xcodePath: xcodePath),
            arguments: arguments + ["-showBuildSettings", "-json"],
            environment: XcodeToolchain.environment(xcodePath: xcodePath)
        )
    }

    func build(arguments: [String], xcodePath: String) async -> ProcessResult {
        let sourceSync = await ensureLatestSource(arguments: arguments)
        guard sourceSync.success else {
            return ProcessResult(exitCode: 1, stdout: "", stderr: sourceSync.log)
        }

        let result = await runner.run(
            XcodeToolchain.xcodebuildPath(xcodePath: xcodePath),
            arguments: arguments + ["build"],
            environment: XcodeToolchain.environment(xcodePath: xcodePath)
        )

        guard !sourceSync.log.isEmpty else { return result }
        let prefix = "=== SOURCE SYNC ===\n\(sourceSync.log)\n"
        return ProcessResult(
            exitCode: result.exitCode,
            stdout: prefix + result.stdout,
            stderr: result.stderr
        )
    }

    private func ensureLatestSource(arguments: [String]) async -> GitSourceSyncResult {
        guard let projectPath = Self.projectPath(from: arguments),
              let repositoryRoot = GitSourceSynchronizer.repositoryRoot(for: projectPath)
        else {
            return .skipped
        }

        let cacheKey = repositoryRoot.standardizedFileURL.path
        if let cached = await sourceSyncCache.value(for: cacheKey) {
            return cached
        }

        let result = await GitSourceSynchronizer(runner: runner)
            .synchronize(repositoryRoot: repositoryRoot)
        await sourceSyncCache.store(result, for: cacheKey)
        return result
    }

    private static func projectPath(from arguments: [String]) -> String? {
        for flag in ["-project", "-workspace"] {
            guard let index = arguments.firstIndex(of: flag) else { continue }
            let next = arguments.index(after: index)
            guard next < arguments.endIndex else { continue }
            return arguments[next]
        }
        return nil
    }
}
