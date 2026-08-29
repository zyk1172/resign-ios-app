import XCTest
@testable import Resign

final class ScheduleTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("schedule-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeManager() throws -> ScheduleManager {
        let worker = tempDir.appendingPathComponent("ResignWorker")
        try Data("#!/bin/sh\n".utf8).write(to: worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: worker.path)
        return ScheduleManager(
            plistURL: tempDir.appendingPathComponent("com.resign.auto.plist"),
            workerExecutablePath: worker.path,
            logDirectory: tempDir.appendingPathComponent("logs", isDirectory: true),
            workingDirectory: tempDir,
            legacyScriptURL: tempDir.appendingPathComponent("resign_all.sh")
        )
    }

    // MARK: - Plist generation

    func testMakePlistLaunchesWorkerWithoutProjectSnapshot() throws {
        let manager = try makeManager()
        let plist = manager.makePlist(workerPath: "/Applications/Resign.app/Contents/MacOS/ResignWorker", hour: 4, minute: 45)

        XCTAssertEqual(plist["Label"] as? String, "com.resign.auto")
        XCTAssertEqual(
            plist["ProgramArguments"] as? [String],
            ["/Applications/Resign.app/Contents/MacOS/ResignWorker", "--scheduled-run"]
        )
        XCTAssertNil(plist["StartInterval"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, false)
        XCTAssertEqual(plist["ProcessType"] as? String, "Background")

        let calendar = try XCTUnwrap(plist["StartCalendarInterval"] as? [String: Any])
        XCTAssertEqual(calendar["Hour"] as? Int, 4)
        XCTAssertEqual(calendar["Minute"] as? Int, 45)
    }

    // MARK: - Migration / staleness detection

    func testLegacyBashPlistRequiresUpdate() throws {
        let manager = try makeManager()
        let legacy: [String: Any] = [
            "Label": ScheduleManager.label,
            "ProgramArguments": ["/bin/bash", tempDir.appendingPathComponent("resign_all.sh").path],
            "StartCalendarInterval": ["Hour": 3, "Minute": 0] as [String: Any],
            "RunAtLoad": false
        ]
        XCTAssertFalse(manager.isCurrent(legacy, workerPath: "/fake/ResignWorker", hour: 3, minute: 0))
    }

    func testLegacyStartIntervalPlistRequiresUpdate() throws {
        let manager = try makeManager()
        let legacy: [String: Any] = [
            "Label": ScheduleManager.label,
            "ProgramArguments": ["/bin/bash", "/tmp/resign_all.sh"],
            "StartInterval": 518_400,
            "RunAtLoad": false
        ]
        XCTAssertFalse(manager.isCurrent(legacy, workerPath: "/fake/ResignWorker", hour: 3, minute: 0))
    }

    func testWorkerPlistMatchesConfiguredTime() throws {
        let manager = try makeManager()
        let workerPath = try XCTUnwrap(manager.workerExecutablePath)
        let plist = manager.makePlist(workerPath: workerPath, hour: 5, minute: 20)

        XCTAssertTrue(manager.isCurrent(plist, workerPath: workerPath, hour: 5, minute: 20))
        XCTAssertFalse(manager.isCurrent(plist, workerPath: workerPath, hour: 5, minute: 21))
        XCTAssertFalse(manager.isCurrent(plist, workerPath: "/other/worker", hour: 5, minute: 20))
    }

    func testNeedsUpdateWithoutPlistFile() throws {
        let manager = try makeManager()
        XCTAssertTrue(manager.needsUpdate(hour: 3, minute: 0))
    }

    // MARK: - Due policy

    func testNeverSucceededProjectIsDue() {
        XCTAssertTrue(ScheduleDuePolicy.isDue(lastSuccessfulInstallDate: nil, intervalDays: 6, now: date("2026-08-30 12:00")))
    }

    func testProjectNotDueBeforeInterval() {
        let last = date("2026-08-25 15:00")
        XCTAssertFalse(ScheduleDuePolicy.isDue(lastSuccessfulInstallDate: last, intervalDays: 6, now: date("2026-08-30 12:00")))
    }

    func testProjectDueOnIntervalDay() {
        let last = date("2026-08-24 23:00")
        // last + 6 calendar days = 08-30 → due regardless of check time that day
        XCTAssertTrue(ScheduleDuePolicy.isDue(lastSuccessfulInstallDate: last, intervalDays: 6, now: date("2026-08-30 00:01")))
        XCTAssertFalse(ScheduleDuePolicy.isDue(lastSuccessfulInstallDate: last, intervalDays: 6, now: date("2026-08-29 23:59")))
    }

    func testClockSkewFutureSuccessDateIsNotDueUntilCalendarCatchesUp() {
        // Mirrors the legacy bash rule: due_day = last + N days; a future-dated
        // success pushes due_day into the future, so today is not due.
        let future = date("2027-01-01 00:00")
        XCTAssertFalse(ScheduleDuePolicy.isDue(lastSuccessfulInstallDate: future, intervalDays: 6, now: date("2026-08-30 12:00")))
    }

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone.current
        return formatter.date(from: string)!
    }
}
