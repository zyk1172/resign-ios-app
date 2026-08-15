import Foundation

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

    static var scriptURL: URL {
        configDirectory.appendingPathComponent("resign_all.sh")
    }

    static var logDirectory: URL {
        let directory = configDirectory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var lastScheduledSuccessURL: URL {
        logDirectory.appendingPathComponent("last_success_epoch")
    }

    /// Per-project due-state directory (one `<projectUUID>.epoch` file each).
    static var scheduledStateDirectory: URL {
        let directory = logDirectory.appendingPathComponent("state", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
