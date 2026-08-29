import XCTest
@testable import Resign

final class FileLockTests: XCTestCase {
    private var lockPath: String!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("filelock-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lockPath = dir.appendingPathComponent("test.lock").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: lockPath)
    }

    func testSecondAcquireFailsWhileHeld() {
        let first = FileLock(path: lockPath)
        let second = FileLock(path: lockPath)

        XCTAssertTrue(first.acquire())
        XCTAssertFalse(second.acquire(), "同一进程内第二次获取应失败（跨进程锁语义）")
        first.release()
        XCTAssertTrue(second.acquire(), "释放后应可获取")
        second.release()
    }

    func testAcquireWithRetrySucceedsAfterRelease() {
        let holder = FileLock(path: lockPath)
        XCTAssertTrue(holder.acquire())

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            holder.release()
        }

        let waiter = FileLock(path: lockPath)
        XCTAssertTrue(waiter.acquireWithRetry(attempts: 20, delayMilliseconds: 25))
        waiter.release()
    }
}
