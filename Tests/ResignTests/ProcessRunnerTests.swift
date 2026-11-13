import XCTest
import Darwin
@testable import Resign

final class ProcessRunnerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("runner-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testDrainsBothStreamsWithoutDeadlocking() async {
        let result = await FoundationProcessRunner().run(
            "/bin/sh", arguments: ["-c", "i=0; while [ $i -lt 4000 ]; do echo stdout-content; echo stderr-content >&2; i=$((i+1)); done"], timeout: 10
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout.split(separator: "\n").count, 4000)
        XCTAssertEqual(result.stderr.split(separator: "\n").count, 4000)
    }

    func testTimeoutKillsIgnoringDescendantsAndPreservesUnrelatedProcess() async throws {
        let unrelated = Process()
        let unrelatedExited = expectation(description: "unrelated process exited")
        unrelated.terminationHandler = { _ in unrelatedExited.fulfill() }
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["15"]
        try unrelated.run()
        defer { if unrelated.isRunning { _ = kill(unrelated.processIdentifier, SIGKILL) } }
        let pidFile = directory.appendingPathComponent("child.pid")
        let start = Date()
        let result = await FoundationProcessRunner().run(
            "/bin/sh", arguments: ["-c", "trap '' TERM; /bin/sleep 60 & echo $! > \"$1\"; wait", "test", pidFile.path], timeout: 1
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exitCode, 124)
        XCTAssertTrue(result.stderr.contains("Process timed out"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
        let pid = try childPID(pidFile)
        await assertExited(pid)
        XCTAssertTrue(unrelated.isRunning)
        unrelated.terminate()
        // An async test may resume on a different thread after await. Do not
        // call waitUntilExit there: its launch-thread run loop can hang even
        // after the child has exited. The termination callback is bounded.
        await fulfillment(of: [unrelatedExited], timeout: 3)
    }

    func testCancellationKillsChildEvenWhenItsOutputIsRedirected() async throws {
        let file = directory.appendingPathComponent("child.pid")
        let task = Task {
            await FoundationProcessRunner().run("/bin/sh", arguments: [
                "-c", "trap 'exit 0' TERM; /bin/sh -c 'trap \"\" TERM; exec /bin/sleep 60' >/dev/null 2>&1 & echo $! > \"$1\"; wait", "test", file.path
            ], timeout: 10)
        }
        defer { task.cancel() }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: file.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try childPID(file)
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.exitCode, 130)
        XCTAssertFalse(result.timedOut)
        await assertExited(pid)
    }

    func testTimeoutStillKillsChildAfterParentHasExited() async throws {
        let file = directory.appendingPathComponent("orphan.pid")
        let start = Date()
        let result = await FoundationProcessRunner().run("/bin/sh", arguments: [
            "-c", "/bin/sleep 60 & echo $! > \"$1\"; exit 0", "test", file.path
        ], timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exitCode, 124)
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
        let pid = try childPID(file)
        await assertExited(pid)
    }

    func testAlreadyCancelledTaskDoesNotLaunchCommand() async {
        let file = directory.appendingPathComponent("must-not-exist")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await FoundationProcessRunner().run("/usr/bin/touch", arguments: [file.path], timeout: 2)
        }
        let result = await task.value
        XCTAssertEqual(result.exitCode, 130)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testLaunchFailureReturnsWithoutTimeout() async {
        let result = await FoundationProcessRunner().run("/resign/nonexistent/executable", arguments: [], timeout: 1)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.stderr.contains("启动进程失败"))
    }

    private func childPID(_ file: URL) throws -> pid_t {
        let text = try String(contentsOf: file).trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(Int32(text))
    }

    private func assertExited(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<150 {
            if kill(pid, 0) != 0 && errno == ESRCH { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        // Only the child created by this test may be cleaned up on failure.
        _ = kill(pid, SIGKILL)
        XCTFail("本次命令的子进程仍未退出：\(pid)", file: file, line: line)
    }
}
