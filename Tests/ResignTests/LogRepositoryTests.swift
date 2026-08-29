import XCTest
@testable import Resign

final class LogRepositoryTests: XCTestCase {
    private var directory: URL!
    private var repository: LogRepository!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("logrepo-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        repository = LogRepository(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Externalize

    func testSmallOutputStaysInline() {
        let (logFile, stored) = repository.externalize("short", date: Date())
        XCTAssertNil(logFile)
        XCTAssertEqual(stored, "short")
    }

    func testLargeOutputWrittenToStandaloneFile() throws {
        let raw = String(repeating: "e", count: LogRepository.inlineThreshold + 1)
        let (logFile, stored) = repository.externalize(raw, date: Date())

        let name = try XCTUnwrap(logFile)
        XCTAssertTrue(name.hasPrefix("build_"))
        XCTAssertTrue(name.hasSuffix(".log"))
        XCTAssertTrue(stored.contains("完整日志见 logs/\(name)"))
        let written = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        XCTAssertEqual(written, raw)
    }

    func testFullLogTextLoadsExternalFileAndRejectsUnsafeNames() throws {
        let raw = String(repeating: "f", count: LogRepository.inlineThreshold + 10)
        let (logFile, _) = repository.externalize(raw, date: Date())
        let entry = BuildLogEntry(date: Date(), projectName: "A", status: .success, output: "summary", durationSeconds: 1, logFile: logFile)

        XCTAssertEqual(repository.fullLogText(for: entry), raw)

        var unsafe = entry
        unsafe = BuildLogEntry(date: Date(), projectName: "A", status: .success, output: "s", durationSeconds: 1, logFile: "../config.json")
        XCTAssertNil(repository.fullLogText(for: unsafe), "路径穿越必须被拒绝")
    }

    // MARK: - Trim

    func testTrimDeletesArtifactsOfDroppedEntries() throws {
        // Logs are stored newest-first; trim keeps the newest 200 and drops
        // the oldest suffix together with their disk artifacts.
        var logs: [BuildLogEntry] = []
        for index in 0..<(LogRepository.maxEntries + 5) {
            let fileName = "build_\(index).log"
            try Data("log \(index)".utf8).write(to: directory.appendingPathComponent(fileName))
            logs.append(BuildLogEntry(
                date: Date(timeIntervalSinceNow: -Double(index) * 60),
                projectName: "A",
                status: .success,
                output: "\(index)",
                durationSeconds: 1,
                logFile: fileName
            ))
        }
        repository.trim(&logs)

        XCTAssertEqual(logs.count, LogRepository.maxEntries)
        XCTAssertEqual(logs.first?.logFile, "build_0.log", "最新的条目保留")
        // Dropped (oldest) entries' files are gone; kept entries' files remain.
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("build_200.log").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("build_204.log").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("build_0.log").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("build_199.log").path))
    }

    func testTrimDeletesLegacyScheduledRunPairs() throws {
        // Newest 200 plain entries first, legacy pair last (oldest → dropped).
        var logs: [BuildLogEntry] = (0..<LogRepository.maxEntries).map { index in
            BuildLogEntry(
                date: Date(timeIntervalSinceNow: -Double(index) * 60),
                projectName: "自动任务",
                status: .success,
                output: "\(index)",
                durationSeconds: 0
            )
        }
        logs.append(BuildLogEntry(
            date: Date().addingTimeInterval(-100),
            projectName: "自动任务",
            status: .success,
            output: "old run",
            durationSeconds: 0,
            sourceIdentifier: "run_20260101_030000.status"
        ))
        try Data("failed".utf8).write(to: directory.appendingPathComponent("run_20260101_030000.status"))
        try Data("log".utf8).write(to: directory.appendingPathComponent("resign_20260101_030000.log"))

        repository.trim(&logs)

        XCTAssertEqual(logs.count, LogRepository.maxEntries)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("run_20260101_030000.status").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("resign_20260101_030000.log").path))
    }

    // MARK: - Clear

    func testClearAllRemovesOnlyManagedArtifacts() throws {
        let managed: Set<String> = [
            "build_1.log", "resign_20260101_030000.log", "run_20260101_030000.status",
            "stdout.log", "stderr.log", "launchd_stdout.log"
        ]
        for name in managed {
            try Data("x".utf8).write(to: directory.appendingPathComponent(name))
        }
        try Data("keep".utf8).write(to: directory.appendingPathComponent("unrelated.txt"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("state"), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: directory.appendingPathComponent("state/1.epoch"))

        repository.clearAll()

        for name in managed {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path), "\(name) 应被删除")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("unrelated.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state/1.epoch").path), "调度状态目录不应被清空")
    }

    // MARK: - Legacy scheduled-run import

    func testImportLegacyScheduledRunsOnceEach() throws {
        try Data("success".utf8).write(to: directory.appendingPathComponent("run_20260819_122357.status"))
        let bigLog = String(repeating: "L", count: LogRepository.inlineThreshold + 100)
        try Data(bigLog.utf8).write(to: directory.appendingPathComponent("resign_20260819_122357.log"))
        try Data("failed".utf8).write(to: directory.appendingPathComponent("run_20260820_120000.status"))

        let first = repository.importLegacyScheduledRuns(knownIdentifiers: [])
        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(first.allSatisfy { $0.source == .scheduled })

        let successEntry = first.first { $0.status == .success }
        XCTAssertEqual(successEntry?.sourceIdentifier, "run_20260819_122357.status")
        XCTAssertEqual(successEntry?.logFile, "resign_20260819_122357.log", "大日志复用原有文件，不重复落盘")
        XCTAssertTrue((successEntry?.output.contains("完整日志见"))!)

        // Known identifiers are not imported again.
        let second = repository.importLegacyScheduledRuns(knownIdentifiers: Set(first.compactMap(\.sourceIdentifier)))
        XCTAssertTrue(second.isEmpty)
    }
}
