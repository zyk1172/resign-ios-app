import Foundation

/// All paths Resign manages. Everything the app or worker deletes must live
/// under one of these directories.
enum AppPaths {
    static var configDirectory: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Resign", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var configURL: URL {
        configDirectory.appendingPathComponent("config.json")
    }

    /// Lock serializing config.json read-modify-write across GUI and worker.
    static var configLockURL: URL {
        configDirectory.appendingPathComponent("config.lock")
    }

    /// Lock serializing build execution (shared by GUI and worker).
    static var buildLockURL: URL {
        configDirectory.appendingPathComponent("resign.lock")
    }

    /// Legacy LaunchAgent bash script (pre-1.5). Removed after migration.
    static var legacyScriptURL: URL {
        configDirectory.appendingPathComponent("resign_all.sh")
    }

    static var logDirectory: URL {
        let directory = configDirectory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Legacy per-project due-state directory (one `<projectUUID>.epoch` each).
    /// Migrated into PersistedState.executionStates by ConfigStore.
    static var scheduledStateDirectory: URL {
        let directory = logDirectory.appendingPathComponent("state", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 持久增量构建工作区（原 /tmp/ResignBuild）。放在 Application Support
    /// 下，重启不丢失，Xcode 增量构建才能跨天复用编译缓存。
    static var buildWorkspacesDirectory: URL {
        let directory = configDirectory.appendingPathComponent("DerivedData", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func workspaceURL(for projectID: UUID) -> URL {
        buildWorkspacesDirectory.appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    /// 构建缓存元数据目录（每个项目一个 <uuid>.json）。
    static var buildCacheDirectory: URL {
        let directory = configDirectory.appendingPathComponent("BuildCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 清理旧版 /tmp/ResignBuild 工作区（v1.6 前的位置，重启即失效）。
    static func cleanupLegacyTemporaryWorkspaces() {
        let legacy = URL(fileURLWithPath: "/tmp/ResignBuild", isDirectory: true)
        try? FileManager.default.removeItem(at: legacy)
    }

    static var schedulePlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(ScheduleManager.label).plist")
    }
}
