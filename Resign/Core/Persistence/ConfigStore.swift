import Foundation

/// The single source of truth for projects, settings, execution states and
/// logs. Both the GUI app and the scheduled worker read and write this one
/// config.json; concurrent read-modify-write is serialized with a
/// cross-process flock (`config.lock`) plus an in-process serial queue.
///
/// Schema: versioned. A v1 config (no `schemaVersion` key) is migrated once:
/// oversized inline log outputs are externalized, and the legacy per-project
/// epoch files (`logs/state/<uuid>.epoch`) are folded into executionStates.
struct ConfigStore: Sendable {
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

    /// Loads the state, running the one-time v1 → v2 migration when needed.
    /// Never throws: a missing or unreadable config yields defaults plus an
    /// error string for the caller to surface.
    func load() -> (state: PersistedState, error: String?) {
        ioQueue.sync {
            let (state, decodeError) = readState()
            if state.schemaVersion < PersistedState.currentSchemaVersion {
                let migrated = Self.migrate(from: state, directory: directory, logRepository: logRepository)
                writeState(migrated)
                return (migrated, decodeError)
            }
            return (state, decodeError)
        }
    }

    // MARK: - Write (GUI)

    /// Fire-and-forget save for the GUI: merges the in-memory snapshot with
    /// whatever landed on disk meanwhile (e.g. worker results) and writes.
    func enqueueSave(_ state: PersistedState) {
        ioQueue.async { [directory] in
            ConfigStore(directory: directory).saveSynchronously(state)
        }
    }

    /// Synchronous save with merge; used by tests and callers that must wait.
    @discardableResult
    func saveSynchronously(_ state: PersistedState) -> Bool {
        ioQueue.sync {
            performUnderConfigLock { diskState in
                let merged = Self.merge(local: state, disk: diskState)
                writeState(merged)
            }
        }
    }

    // MARK: - Write (worker)

    /// Atomic read-modify-write used by the scheduled worker to record one
    /// execution result without clobbering concurrent GUI edits.
    @discardableResult
    func updateSynchronously(_ mutate: (inout PersistedState) -> Void) -> Bool {
        ioQueue.sync {
            performUnderConfigLock { diskState in
                var state = diskState ?? PersistedState()
                mutate(&state)
                writeState(state)
            }
        }
    }

    /// Runs `body` with the freshly-read disk state while holding the config
    /// lock; body performs the write before returning.
    private func performUnderConfigLock(_ body: (PersistedState?) -> Void) -> Bool {
        let lock = FileLock(path: lockPath)
        guard lock.acquireWithRetry(attempts: 50, delayMilliseconds: 100) else {
            FileHandle.standardError.write(Data("Resign: config.lock 被长期占用，跳过本次写入\n".utf8))
            return false
        }
        defer { lock.release() }
        let (diskState, _) = readState()
        body(diskState)
        return true
    }

    // MARK: - Encoding

    private func readState() -> (PersistedState, String?) {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return (PersistedState(), nil)
        }
        do {
            let data = try Data(contentsOf: configURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(PersistedState.self, from: data)
            return (state, nil)
        } catch {
            return (PersistedState(), "配置读取失败：\(error.localizedDescription)")
        }
    }

    private func writeState(_ state: PersistedState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(state)
            try data.write(to: configURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            FileHandle.standardError.write(Data("Resign: 配置保存失败：\(error.localizedDescription)\n".utf8))
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
        merged.logs = Array(logsByID.values.sorted { $0.date > $1.date }.prefix(LogRepository.maxEntries))

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
        //    projects that still exist; files are removed after the read.
        let stateDirectory = directory
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
        var states = migrated.executionStates
        if let files = try? FileManager.default.contentsOfDirectory(at: stateDirectory, includingPropertiesForKeys: nil) {
            let knownProjectIDs = Set(migrated.projects.map(\.id))
            for url in files where url.pathExtension == "epoch" {
                defer { try? FileManager.default.removeItem(at: url) }
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
}
