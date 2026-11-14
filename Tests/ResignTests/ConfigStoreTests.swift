import XCTest
@testable import Resign

final class ConfigStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("configstore-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var configURL: URL { directory.appendingPathComponent("config.json") }

    private func writeConfig(_ string: String) throws {
        try Data(string.utf8).write(to: configURL)
    }

    // MARK: - v1 → v2 migration

    func testV1ProjectWithoutPlatformDecodesAsIOS() throws {
        // 显式验证 macOS 平台字段的前向兼容：v1 项目 JSON 没有 platform，
        // 解码后必须回落为 .ios，而不是整体解码失败。
        let projectID = UUID()
        let v1Config = """
        {
          "schemaVersion": 2,
          "projects": [{"id": "\(projectID.uuidString)", "name": "Legacy", "projectPath": "/tmp/Legacy.xcodeproj"}],
          "settings": {},
          "executionStates": [],
          "logs": []
        }
        """
        try writeConfig(v1Config)

        let loaded = ConfigStore(directory: directory).load()
        XCTAssertNil(loaded.error)
        let project = try XCTUnwrap(loaded.state.projects.first)
        XCTAssertEqual(project.platform, .ios)
        XCTAssertEqual(project.configuration, "Debug")
    }

    func testV1ConfigMigratesSchemaEpochsAndFatLogs() throws {
        let projectID = UUID()
        let fatOutput = String(repeating: "x", count: 100_000)

        let v1Config = """
        {
          "projects": [{"id": "\(projectID.uuidString)", "name": "Demo", "projectPath": "/tmp/Demo.xcodeproj", "scheme": "Demo", "configuration": "Debug", "deviceUDIDs": [], "isEnabled": true}],
          "settings": {"resignIntervalDays": 6},
          "logs": [{"date": "2026-08-01T03:00:00Z", "projectName": "Demo", "status": "success", "output": "\(fatOutput)", "durationSeconds": 12.5}]
        }
        """
        try writeConfig(v1Config)

        let epochDate = Date(timeIntervalSince1970: 1_750_000_000)
        let stateDir = directory.appendingPathComponent("logs/state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let epochURL = stateDir.appendingPathComponent("\(projectID.uuidString).epoch")
        try Data("1750000000\n".utf8).write(to: epochURL)

        let store = ConfigStore(directory: directory)
        let loaded = store.load()

        XCTAssertNil(loaded.error)
        XCTAssertEqual(loaded.state.schemaVersion, PersistedState.currentSchemaVersion)
        XCTAssertEqual(loaded.state.projects.first?.name, "Demo")

        // Epoch folded into execution state, file removed.
        let executionState = try XCTUnwrap(loaded.state.executionStates.first)
        XCTAssertEqual(executionState.projectID, projectID)
        XCTAssertEqual(
            executionState.lastSuccessfulInstallDate!.timeIntervalSince1970,
            epochDate.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: epochURL.path))

        // Fat inline log externalized.
        let logEntry = try XCTUnwrap(loaded.state.logs.first)
        XCTAssertNotNil(logEntry.logFile)
        XCTAssertTrue(logEntry.output.contains("完整日志见"))
        XCTAssertLessThan(logEntry.output.count, fatOutput.count)

        // Migration persisted; a second load does not regress.
        let second = store.load()
        XCTAssertEqual(second.state.schemaVersion, PersistedState.currentSchemaVersion)
        XCTAssertEqual(second.state.executionStates.count, 1)
    }

    func testV2ConfigLoadsUnchanged() throws {
        let v2 = PersistedState(
            projects: [iOSProject(name: "A", projectPath: "/tmp/A.xcodeproj")],
            settings: AppSettings(),
            executionStates: [ProjectExecutionState(projectID: UUID())],
            logs: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try Data(encoder.encode(v2)).write(to: configURL)

        let loaded = ConfigStore(directory: directory).load()
        XCTAssertEqual(loaded.state.projects.count, 1)
        XCTAssertEqual(loaded.state.executionStates.count, 1)
        XCTAssertNil(loaded.error)
    }

    func testLegacyInstalledAppPathDecodesIntoBuiltAppPath() throws {
        // 评审 §19.26：旧日志只有 installedAppPath，仍必须能读出 builtAppPath。
        let legacy = """
        {"date": "2026-08-01T03:00:00Z", "projectName": "A", "status": "success", "output": "ok", "durationSeconds": 1, "installedAppPath": "/tmp/Old.app"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(BuildLogEntry.self, from: Data(legacy.utf8))
        XCTAssertEqual(entry.builtAppPath, "/tmp/Old.app")
    }

    func testNewLogEntriesEncodeBuiltAppPathOnly() throws {
        // 评审 §19.27：新编码只写 builtAppPath，不再写 installedAppPath。
        let entry = BuildLogEntry(
            date: Date(),
            projectName: "A",
            status: .success,
            output: "ok",
            durationSeconds: 1,
            builtAppPath: "/tmp/New.app",
            buildMode: .incrementalUnchanged
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(data: try encoder.encode(entry), encoding: .utf8)!
        XCTAssertTrue(json.contains("builtAppPath"))
        XCTAssertFalse(json.contains("installedAppPath"))

        let decodeBack = JSONDecoder()
        decodeBack.dateDecodingStrategy = .iso8601
        let decoded = try decodeBack.decode(BuildLogEntry.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.builtAppPath, "/tmp/New.app")
        XCTAssertEqual(decoded.buildMode, .incrementalUnchanged)
    }

    func testTimeoutSettingsRemainCompatibleWithOldConfigsAndNormalizeBounds() throws {
        try writeConfig("{\"schemaVersion\":2,\"settings\":{}}")
        let store = ConfigStore(directory: directory)
        let loaded = store.load()
        XCTAssertNil(loaded.error)
        XCTAssertEqual(loaded.state.settings.buildTimeoutMinutes, 30)
        XCTAssertEqual(loaded.state.settings.installTimeoutSeconds, 120)
        var state = loaded.state
        state.settings.buildTimeoutMinutes = 4
        state.settings.installTimeoutSeconds = 45
        try store.saveSynchronously(state)
        XCTAssertEqual(store.load().state.settings.buildTimeoutMinutes, 4)
        XCTAssertEqual(store.load().state.settings.installTimeoutSeconds, 45)
        state.settings.buildTimeoutMinutes = -5
        state.settings.installTimeoutSeconds = 9999
        XCTAssertEqual(state.settings.normalized().buildTimeoutMinutes, 1)
        XCTAssertEqual(state.settings.normalized().installTimeoutSeconds, 600)
    }

    func testLegacyDeviceSummaryDecodesWithoutFailureReason() throws {
        let json = Data("{\"udid\":\"D1\",\"deviceName\":\"Phone\",\"success\":false,\"attempts\":1}".utf8)
        let summary = try JSONDecoder().decode(DeviceInstallSummary.self, from: json)
        XCTAssertNil(summary.failureReason)
    }

    // MARK: - Merge semantics

    func testMergeUnionsLogsAndKeepsNewestExecutionState() {
        let projectID = UUID()
        let oldEntry = BuildLogEntry(date: Date(timeIntervalSince1970: 100), projectName: "A", status: .success, output: "old", durationSeconds: 1)
        let newEntry = BuildLogEntry(date: Date(timeIntervalSince1970: 900), projectName: "A", status: .failed, output: "worker", durationSeconds: 2)

        let local = PersistedState(
            projects: [iOSProject(id: projectID, name: "A", projectPath: "/tmp/A.xcodeproj")],
            executionStates: [ProjectExecutionState(projectID: projectID, lastAttemptDate: Date(timeIntervalSince1970: 100))],
            logs: [oldEntry]
        )
        let disk = PersistedState(
            projects: [iOSProject(id: projectID, name: "A", projectPath: "/tmp/A.xcodeproj")],
            executionStates: [ProjectExecutionState(projectID: projectID, lastAttemptDate: Date(timeIntervalSince1970: 900))],
            logs: [newEntry, oldEntry]
        )

        let merged = ConfigStore.merge(local: local, disk: disk)
        XCTAssertEqual(merged.logs.count, 2)
        XCTAssertEqual(merged.logs.first?.output, "worker") // sorted newest first
        XCTAssertEqual(merged.executionStates.first?.effectiveLastAttempt.timeIntervalSince1970, 900)
    }

    func testMergeAdoptsNewerWorkerBuildDateIntoProject() {
        let projectID = UUID()
        var project = iOSProject(id: projectID, name: "A", projectPath: "/tmp/A.xcodeproj")
        project.lastBuildDate = Date(timeIntervalSince1970: 100)

        var diskProject = project
        diskProject.lastBuildDate = Date(timeIntervalSince1970: 500)
        diskProject.lastBuildStatus = .success

        let merged = ConfigStore.merge(
            local: PersistedState(projects: [project]),
            disk: PersistedState(projects: [diskProject])
        )
        XCTAssertEqual(merged.projects.first?.lastBuildDate?.timeIntervalSince1970, 500)
        XCTAssertEqual(merged.projects.first?.lastBuildStatus, .success)
    }

    // MARK: - Read-modify-write

    func testGUISavePreservesCorruptedConfig() throws {
        let original = Data("{ interrupted config".utf8)
        try original.write(to: configURL)
        let store = ConfigStore(directory: directory)

        XCTAssertNotNil(store.load().error)
        XCTAssertThrowsError(try store.saveSynchronously(PersistedState()))
        XCTAssertEqual(try Data(contentsOf: configURL), original)
    }

    func testWorkerUpdateRejectsCorruptedConfigBeforeMutation() throws {
        let original = Data("{ interrupted config".utf8)
        try original.write(to: configURL)
        var didMutate = false

        XCTAssertThrowsError(try ConfigStore(directory: directory).updateSynchronously { _ in
            didMutate = true
        })
        XCTAssertFalse(didMutate)
        XCTAssertEqual(try Data(contentsOf: configURL), original)
    }

    func testFutureSchemaIsRejectedWithoutRewritingUnknownFields() throws {
        let original = Data("{\"schemaVersion\":999,\"futureSetting\":\"keep\"}".utf8)
        try original.write(to: configURL)
        let store = ConfigStore(directory: directory)

        XCTAssertNotNil(store.load().error)
        XCTAssertThrowsError(try store.saveSynchronously(PersistedState()))
        XCTAssertThrowsError(try store.updateSynchronously { _ in })
        XCTAssertEqual(try Data(contentsOf: configURL), original)
    }

    func testMigrationReadsLatestStateAfterWaitingForConfigLock() async throws {
        try writeConfig("{\"projects\":[{\"name\":\"Legacy\"}]}")
        let lock = FileLock(path: directory.appendingPathComponent("config.lock").path)
        XCTAssertTrue(lock.acquire())
        defer { lock.release() }

        let store = ConfigStore(directory: directory)
        let started = DispatchSemaphore(value: 0)
        let loadTask = Task.detached {
            started.signal()
            return store.load()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        // Keep the lock long enough for the reader to reach the transaction.
        // A pre-lock migration would now have captured the stale v1 snapshot.
        try await Task.sleep(for: .milliseconds(200))
        try writeConfig("{\"schemaVersion\":2,\"projects\":[{\"name\":\"Updated while waiting\"}]}")
        lock.release()

        let loaded = await loadTask.value
        XCTAssertNil(loaded.error)
        XCTAssertEqual(loaded.state.projects.first?.name, "Updated while waiting")
        XCTAssertEqual(store.load().state.projects.first?.name, "Updated while waiting")
    }

    func testClearLogsDrainsPendingSaveAndDoesNotResurrectOnNextSave() throws {
        let store = ConfigStore(directory: directory)
        let project = iOSProject(name: "A", projectPath: "/tmp/A.xcodeproj")
        let entry = BuildLogEntry(date: Date(), projectName: "A", status: .success, output: "old", durationSeconds: 1)
        var guiState = PersistedState(
            projects: [project],
            executionStates: [ProjectExecutionState(projectID: project.id)],
            logs: [entry]
        )
        store.enqueueSave(guiState)

        try store.clearLogsSynchronously(including: guiState.logs)
        XCTAssertTrue(store.load().state.logs.isEmpty)
        guiState.logs.removeAll()
        try store.saveSynchronously(guiState)

        let loaded = store.load()
        XCTAssertTrue(loaded.state.logs.isEmpty)
        XCTAssertEqual(loaded.state.projects.first?.id, project.id)
        XCTAssertEqual(loaded.state.executionStates.first?.projectID, project.id)

        // Worker updates after the clear remain visible and survive GUI saves.
        try store.updateSynchronously { $0.logs.append(entry) }
        try store.saveSynchronously(guiState)
        XCTAssertEqual(store.load().state.logs.map(\.id), [entry.id])
    }

    func testClearOnlyDeletesCommittedLogArtifacts() throws {
        let repository = LogRepository(directory: directory.appendingPathComponent("logs"))
        let raw = String(repeating: "x", count: LogRepository.inlineThreshold + 1)
        let (oldFile, stored) = repository.externalize(raw, date: Date())
        let entry = BuildLogEntry(date: Date(), projectName: "A", status: .success, output: stored, durationSeconds: 1, logFile: oldFile)
        let store = ConfigStore(directory: directory, logRepository: repository)
        try store.saveSynchronously(PersistedState(logs: [entry]))

        // Another process has produced output but has not committed its entry.
        let (pendingFile, _) = repository.externalize(raw, date: Date())
        try store.clearLogsSynchronously()

        XCTAssertTrue(store.load().state.logs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.directory.appendingPathComponent(try XCTUnwrap(oldFile)).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.directory.appendingPathComponent(try XCTUnwrap(pendingFile)).path))
    }

    func testFailedClearPreservesConfigAndLogFiles() throws {
        let repository = LogRepository(directory: directory.appendingPathComponent("logs"))
        let (file, _) = repository.externalize(String(repeating: "x", count: LogRepository.inlineThreshold + 1), date: Date())
        let entry = BuildLogEntry(date: Date(), projectName: "A", status: .success, output: "old", durationSeconds: 1, logFile: file)
        let original = Data("{ damaged".utf8)
        try original.write(to: configURL)
        let store = ConfigStore(directory: directory, logRepository: repository)

        XCTAssertThrowsError(try store.clearLogsSynchronously(including: [entry]))
        XCTAssertEqual(try Data(contentsOf: configURL), original)
        XCTAssertEqual(repository.fullLogText(for: entry)?.count, LogRepository.inlineThreshold + 1)
    }

    func testRetentionDeletesArtifactsOnlyAfterSuccessfulCommit() throws {
        let repository = LogRepository(directory: directory.appendingPathComponent("logs"))
        let (file, stored) = repository.externalize(String(repeating: "x", count: LogRepository.inlineThreshold + 1), date: .distantPast)
        let oldEntry = BuildLogEntry(date: .distantPast, projectName: "A", status: .success, output: stored, durationSeconds: 1, logFile: file)
        let store = ConfigStore(directory: directory, logRepository: repository)
        try store.saveSynchronously(PersistedState(logs: [oldEntry]))

        let newEntries = (0..<LogRepository.maxEntries).map { index in
            BuildLogEntry(date: Date(timeIntervalSince1970: Double(index)), projectName: "A", status: .success, output: "new", durationSeconds: 1)
        }
        let invalid = BuildLogEntry(date: Date(), projectName: "A", status: .failed, output: "invalid", durationSeconds: .infinity)
        XCTAssertThrowsError(try store.updateSynchronously { $0.logs = [invalid] + newEntries + [oldEntry] })
        XCTAssertNotNil(repository.fullLogText(for: oldEntry))
        XCTAssertEqual(store.load().state.logs.map(\.id), [oldEntry.id])

        try store.updateSynchronously { $0.logs = newEntries + [oldEntry] }
        XCTAssertEqual(store.load().state.logs.count, LogRepository.maxEntries)
        XCTAssertNil(repository.fullLogText(for: oldEntry))
    }

    func testEnqueuedSaveReportsReadFailure() async throws {
        try writeConfig("{ damaged")
        let finished = expectation(description: "save error returned")
        ConfigStore(directory: directory).enqueueSave(PersistedState()) { error in
            XCTAssertTrue(error?.contains("配置读取失败") == true)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)
    }

    @MainActor
    func testAppStoreDoesNotOverwriteRepairedConfigAfterFailedInitialLoad() throws {
        let repository = LogRepository(directory: directory.appendingPathComponent("logs"))
        let (file, _) = repository.externalize(String(repeating: "x", count: LogRepository.inlineThreshold + 1), date: Date())
        try writeConfig("{ damaged")
        let app = AppStore(configDirectory: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.directory.appendingPathComponent(try XCTUnwrap(file)).path))

        // A repaired file must not be replaced by the GUI's empty fallback.
        let disk = ConfigStore(directory: directory)
        try writeConfig("{\"schemaVersion\":2,\"projects\":[{\"name\":\"Recovered\"}]}")
        app.projects = [iOSProject(name: "Unsaved", projectPath: "/tmp/Unsaved.xcodeproj")]
        app.save()

        XCTAssertTrue(app.statusMessage.contains("配置未成功载入"))
        XCTAssertEqual(disk.load().state.projects.first?.name, "Recovered")
    }

    @MainActor
    func testAppStoreDisplaysAsynchronousSaveFailure() async throws {
        try ConfigStore(directory: directory).saveSynchronously(PersistedState())
        let app = AppStore(configDirectory: directory)
        try writeConfig("{ damaged")
        app.statusMessage = "就绪"
        app.save()

        for _ in 0..<100 where app.toast == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(app.statusMessage.contains("配置读取失败"))
        XCTAssertEqual(app.toast?.kind, .error)
    }

    @MainActor
    func testAppStoreClearPersistsBeforeReportingSuccess() throws {
        let entry = BuildLogEntry(date: Date(), projectName: "A", status: .success, output: "old", durationSeconds: 1)
        let disk = ConfigStore(directory: directory)
        try disk.saveSynchronously(PersistedState(logs: [entry]))
        let app = AppStore(configDirectory: directory)

        app.clearLogs()

        XCTAssertTrue(app.logs.isEmpty)
        XCTAssertTrue(disk.load().state.logs.isEmpty)
        XCTAssertEqual(app.toast?.message, "日志已清空")
    }

    @MainActor
    func testAppStoreFailedClearKeepsVisibleEntriesAndFiles() throws {
        let repository = LogRepository(directory: directory.appendingPathComponent("logs"))
        let (file, stored) = repository.externalize(String(repeating: "x", count: LogRepository.inlineThreshold + 1), date: Date())
        let entry = BuildLogEntry(date: Date(), projectName: "A", status: .success, output: stored, durationSeconds: 1, logFile: file)
        try ConfigStore(directory: directory).saveSynchronously(PersistedState(logs: [entry]))
        let app = AppStore(configDirectory: directory)
        try writeConfig("{ damaged")

        app.clearLogs()

        XCTAssertEqual(app.logs.map(\.id), [entry.id])
        XCTAssertEqual(app.toast?.kind, .error)
        XCTAssertNotNil(repository.fullLogText(for: entry))
    }

    func testUpdatePersistsAndIsVisibleToNextRead() throws {
        let store = ConfigStore(directory: directory)
        let projectID = UUID()

        try store.updateSynchronously { state in
            state.projects.append(iOSProject(id: projectID, name: "A", projectPath: "/tmp/A.xcodeproj"))
        }
        try store.updateSynchronously { state in
            state.logs.append(BuildLogEntry(date: Date(), projectName: "A", status: .success, output: "run", durationSeconds: 3))
        }

        let loaded = store.load()
        XCTAssertEqual(loaded.state.projects.count, 1)
        XCTAssertEqual(loaded.state.logs.count, 1)
    }

    func testUpdateFailurePropagatesInsteadOfReportingSuccess() throws {
        let store = ConfigStore(directory: directory)

        // config 目录被一个不可写的同名"目录"占位，写入必然失败；
        // updateSynchronously 必须抛错，而不是把"拿到锁"当成功。
        let bogusConfig = directory.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: bogusConfig, withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.updateSynchronously { _ in })
    }

    func testGUISaveDoesNotClobberWorkerLogEntries() throws {
        let store = ConfigStore(directory: directory)
        let projectID = UUID()

        // GUI state in memory — first save puts the project on disk.
        let guiState = PersistedState(
            projects: [iOSProject(id: projectID, name: "A", projectPath: "/tmp/A.xcodeproj")],
            settings: AppSettings(),
            logs: []
        )
        try store.saveSynchronously(guiState)

        // Worker records a result directly on disk while the GUI stays open.
        try store.updateSynchronously { state in
            ExecutionRecorder.apply(
                .init(
                    projectID: projectID,
                    projectName: "A",
                    result: BuildResult(success: true, output: "worker output"),
                    source: .scheduled,
                    startedAt: Date(),
                    durationSeconds: 5
                ),
                to: &state
            )
        }

        // GUI saves its (stale) snapshot again — merge must preserve the
        // worker's log entry, execution state and newer project fields.
        try store.saveSynchronously(guiState)

        let loaded = store.load()
        XCTAssertTrue(loaded.state.logs.contains { $0.output == "worker output" && $0.source == .scheduled })
        XCTAssertTrue(loaded.state.executionStates.contains { $0.projectID == projectID && $0.lastSuccessfulInstallDate != nil })
        XCTAssertEqual(loaded.state.projects.first?.lastBuildStatus, .success)
    }
}
