import Foundation

/// The single source of truth for projects, settings, execution states and
/// logs. Both the GUI app and the scheduled worker read and write this one
/// config.json; concurrent read-modify-write is serialized with a
/// cross-process flock (`config.lock`) plus an in-process serial queue.
///
/// Schema: versioned. A v1 config (no `schemaVersion` key) is migrated once:
/// oversized inline log outputs are externalized, and the legacy per-project
/// epoch files (`logs/state/<uuid>.epoch`) are folded into executionStates.
/// All write failures propagate as thrown errors — acquiring the lock is not
/// reported as success.
struct ConfigStore: Sendable {
    enum ConfigStoreError: LocalizedError {
        case lockUnavailable
        case readFailed(underlying: String)
        case writeFailed(underlying: String)
        case unsupportedSchema(Int)

        var errorDescription: String? {
            switch self {
            case .lockUnavailable:
                return "config.lock 被长期占用，无法完成配置写入"
            case .readFailed(let underlying):
                return "配置读取失败：\(underlying)；已保留原文件，停止写入"
            case .writeFailed(let underlying):
                return "配置写入失败：\(underlying)"
            case .unsupportedSchema(let version):
                return "配置版本 \(version) 高于当前支持的版本；已保留原文件，请使用较新版本的 Resign"
            }
        }
    }

    let directory: URL

    private let ioQueue = DispatchQueue(label: "com.resign.config.io")
    private let logRepository: LogRepository

    init(directory: URL, logRepository: LogRepository? = nil) {
        self.directory = directory
        self.logRepository = logRepository ?? LogRepository(
            directory: directory.appendingPathComponent("logs", isDirectory: true)
        )
    }

    var configURL: URL { directory.appendingPathComponent("config.json") }
    private var lockPath: String { directory.appendingPathComponent("config.lock").path }

    // MARK: - Read

    /// Reads and migrates under the same lock as writers. Only a missing file
    /// is a fresh install; an unreadable or unsupported file must never become
    /// the empty state used by a subsequent save.
    func load() -> (state: PersistedState, error: String?) {
        ioQueue.sync {
            do {
                return (try performUnderConfigLock { $0 }, nil)
            } catch {
                return (PersistedState(), error.localizedDescription)
            }
        }
    }

    // MARK: - Write (GUI)

    /// Fire-and-forget save for the GUI: merges the in-memory snapshot with
    /// whatever landed on disk meanwhile (e.g. worker results) and writes.
    /// Completion runs on the I/O queue, allowing the GUI to surface failures.
    func enqueueSave(_ state: PersistedState, completion: @escaping @Sendable (String?) -> Void = { _ in }) {
        ioQueue.async {
            do {
                try saveUnderConfigLock(state)
                completion(nil)
            } catch {
                FileHandle.standardError.write(Data("Resign: \(error.localizedDescription)\n".utf8))
                completion(error.localizedDescription)
            }
        }
    }

    /// Synchronous save with merge; used by tests and callers that must wait.
    func saveSynchronously(_ state: PersistedState) throws {
        try ioQueue.sync {
            try saveUnderConfigLock(state)
        }
    }

    private func saveUnderConfigLock(_ state: PersistedState) throws {
        try performUnderConfigLock { diskState in
            try commit(Self.merge(local: state, disk: diskState), replacing: diskState)
        }
    }

    /// A clear is an explicit transaction, not an empty snapshot to union with
    /// disk. Waiting on ioQueue also drains earlier GUI saves before clearing.
    /// Only committed/reported artifacts are removed; a concurrent writer may
    /// already have created a new log file that it has not saved yet.
    func clearLogsSynchronously(including localLogs: [BuildLogEntry] = []) throws {
        try ioQueue.sync {
            try performUnderConfigLock { diskState in
                var cleared = diskState
                cleared.logs.removeAll()
                try commit(cleared, replacing: diskState)
                logRepository.deleteArtifacts(for: localLogs, retaining: [])
            }
        }
    }

    // MARK: - Write (worker)

    /// Atomic read-modify-write used by the scheduled worker to record one
    /// execution result without clobbering concurrent GUI edits. Throws when
    /// the lock cannot be acquired or the write fails.
    func updateSynchronously(_ mutate: (inout PersistedState) -> Void) throws {
        try ioQueue.sync {
            try performUnderConfigLock { diskState in
                var state = diskState
                mutate(&state)
                try commit(state, replacing: diskState)
            }
        }
    }

    /// The read, any migration, and the caller's write share one transaction.
    private func performUnderConfigLock<T>(_ body: (PersistedState) throws -> T) throws -> T {
        let lock = FileLock(path: lockPath)
        guard lock.acquireWithRetry(attempts: 50, delayMilliseconds: 100) else {
            throw ConfigStoreError.lockUnavailable
        }
        defer { lock.release() }
        var diskState = try readState()
        if diskState.schemaVersion < PersistedState.currentSchemaVersion {
            let migrated = Self.migrate(from: diskState, directory: directory, logRepository: logRepository)
            try writeState(migrated)
            Self.removeLegacyEpochFiles(directory: directory)
            diskState = migrated
        }
        return try body(diskState)
    }

    // MARK: - Encoding

    private func readState() throws -> PersistedState {
        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return PersistedState()
        } catch {
            throw ConfigStoreError.readFailed(underlying: error.localizedDescription)
        }
        let state: PersistedState
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            state = try decoder.decode(PersistedState.self, from: data)
        } catch {
            throw ConfigStoreError.readFailed(underlying: error.localizedDescription)
        }
        guard state.schemaVersion <= PersistedState.currentSchemaVersion else {
            throw ConfigStoreError.unsupportedSchema(state.schemaVersion)
        }
        return state
    }

    /// Cleanup follows the atomic config write, so a failed write cannot leave
    /// the still-authoritative log entries pointing to files we just deleted.
    private func commit(_ state: PersistedState, replacing previous: PersistedState) throws {
        var saved = state
        saved.logs = Array(state.logs.sorted { $0.date > $1.date }.prefix(LogRepository.maxEntries))
        try writeState(saved)
        logRepository.deleteArtifacts(for: previous.logs + state.logs, retaining: saved.logs)
    }

    private func writeState(_ state: PersistedState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(state)
            try data.write(to: configURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            throw ConfigStoreError.writeFailed(underlying: error.localizedDescription)
        }
    }

    // MARK: - Merge (pure, unit-tested)

    /// Combines the caller's in-memory snapshot with the on-disk state:
    /// - projects & settings: memory wins, but newer worker-written build
    ///   timestamps/status are adopted so UI does not roll back a background run;
    /// - logs & executionStates: union, newer record wins per project.
    static func merge(local: PersistedState, disk: PersistedState?) -> PersistedState {
        guard let disk else { return local }
        var merged = local
        merged.schemaVersion = max(local.schemaVersion, disk.schemaVersion)

        var logsByID: [UUID: BuildLogEntry] = [:]
        for entry in local.logs { logsByID[entry.id] = entry }
        for entry in disk.logs where logsByID[entry.id] == nil { logsByID[entry.id] = entry }
        merged.logs = logsByID.values.sorted { $0.date > $1.date }

        var states = local.executionStates
        for diskState in disk.executionStates {
            if let index = states.firstIndex(where: { $0.projectID == diskState.projectID }) {
                if diskState.effectiveLastAttempt > states[index].effectiveLastAttempt {
                    states[index] = diskState
                }
            } else {
                states.append(diskState)
            }
        }
        merged.executionStates = states

        for diskProject in disk.projects {
            guard let index = merged.projects.firstIndex(where: { $0.id == diskProject.id }),
                  let diskDate = diskProject.lastBuildDate,
                  (merged.projects[index].lastBuildDate ?? .distantPast) < diskDate
            else { continue }
            merged.projects[index].lastBuildDate = diskProject.lastBuildDate
            merged.projects[index].lastBuildStatus = diskProject.lastBuildStatus
        }

        return merged
    }

    // MARK: - Migration (v1 → v2)

    static func migrate(from state: PersistedState, directory: URL, logRepository: LogRepository) -> PersistedState {
        var migrated = state

        // 1) Externalize oversized inline log outputs that predate the
        //    offloading feature (or were imported by the legacy bash engine).
        migrated.logs = migrated.logs.map { entry in
            guard entry.logFile == nil, entry.output.count > LogRepository.inlineThreshold else {
                return entry
            }
            let (logFile, stored) = logRepository.externalize(entry.output, date: entry.date)
            guard let logFile else { return entry }
            var updated = entry
            updated.output = stored
            updated.logFile = logFile
            return updated
        }

        // 2) Legacy epoch files → ProjectExecutionState. Applied only to
        //    projects that still exist. The files themselves are removed by
        //    `removeLegacyEpochFiles` after the migrated state is
        //    successfully persisted, so a failed write never loses them.
        let stateDirectory = directory
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
        var states = migrated.executionStates
        if let files = try? FileManager.default.contentsOfDirectory(at: stateDirectory, includingPropertiesForKeys: nil) {
            let knownProjectIDs = Set(migrated.projects.map(\.id))
            for url in files where url.pathExtension == "epoch" {
                guard let uuid = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      knownProjectIDs.contains(uuid),
                      let raw = try? String(contentsOf: url, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      let epoch = TimeInterval(raw)
                else { continue }

                let date = Date(timeIntervalSince1970: epoch)
                if let index = states.firstIndex(where: { $0.projectID == uuid }) {
                    if (states[index].lastSuccessfulInstallDate ?? .distantPast) < date {
                        states[index].lastSuccessfulInstallDate = date
                    }
                } else {
                    states.append(ProjectExecutionState(projectID: uuid, lastSuccessfulInstallDate: date))
                }
            }
        }
        migrated.executionStates = states
        migrated.schemaVersion = PersistedState.currentSchemaVersion
        return migrated
    }

    /// Removes the legacy epoch sidecar files. Only called after the migrated
    /// state has been successfully written to config.json.
    private static func removeLegacyEpochFiles(directory: URL) {
        let stateDirectory = directory
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: stateDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in files where url.pathExtension == "epoch" {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
