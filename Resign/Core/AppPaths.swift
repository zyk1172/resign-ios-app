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

    static var schedulePlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(ScheduleManager.label).plist")
    }
}
