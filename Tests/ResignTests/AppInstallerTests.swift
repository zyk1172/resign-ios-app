import XCTest
@testable import Resign

final class AppInstallerTests: XCTestCase {
    private func device(_ id: String, available: Bool = true) -> iOSDevice {
        iOSDevice(udid: id, name: "Device \(id)", osVersion: "27", connectionType: "USB", isAvailable: available)
    }
    private let retry = RetryPolicy(maxAttempts: 3, intervalSeconds: 0)

    func testOtherDevicesGetFirstAttemptBeforeRetryingFailedDevice() async {
        let runner = MockProcessRunner()
        runner.enqueue(makeProcessResult(exitCode: 1, stderr: "network connection was lost"))
        runner.enqueue(makeProcessResult(exitCode: 0))
        runner.enqueue(makeProcessResult(exitCode: 0))
        let installer = AppInstaller(runner: runner, deviceDiscovery: FixedDeviceDiscovery(devices: [device("A"), device("B")]), timeout: 77)
        let outcomes = await installer.install(appPath: "/tmp/Demo.app", deviceUDIDs: ["A", "B"], xcodePath: "/Xcode", retry: retry)
        XCTAssertEqual(runner.recordedCalls.map { $0.arguments[5] }, ["A", "B", "A"])
        XCTAssertEqual(outcomes.map(\.attempts), [2, 1])
        XCTAssertTrue(outcomes.allSatisfy(\.success))
        XCTAssertTrue(runner.recordedCalls.allSatisfy { $0.timeout == 77 })
    }

    func testUnavailableExplicitTargetIsNotReplacedAndDoesNotBlockOnlineTarget() async {
        let runner = MockProcessRunner()
        let discovery = FixedDeviceDiscovery(devices: [device("A", available: false), device("B"), device("UNSELECTED")])
        let outcomes = await AppInstaller(runner: runner, deviceDiscovery: discovery)
            .install(appPath: "/tmp/Demo.app", deviceUDIDs: ["A", "B"], xcodePath: "/Xcode", retry: retry)
        XCTAssertEqual(outcomes.map(\.attempts), [0, 1])
        XCTAssertFalse(outcomes[0].success)
        XCTAssertTrue(outcomes[0].failureReason?.contains("当前不可用") == true)
        XCTAssertTrue(outcomes[1].success)
        XCTAssertEqual(runner.recordedCalls.map { $0.arguments[5] }, ["B"])
    }

    func testLockedAndNotReadyDevicesDoNotEnterRetryWait() async {
        for error in ["The device was still locked. error 10003", "usage assertion requirements. error 4016"] {
            let runner = MockProcessRunner()
            runner.enqueue(makeProcessResult(exitCode: 1, stderr: error))
            runner.enqueue(makeProcessResult(exitCode: 0))
            let outcomes = await AppInstaller(runner: runner, deviceDiscovery: FixedDeviceDiscovery(devices: [device("A"), device("B")]))
                .install(appPath: "/tmp/Demo.app", deviceUDIDs: ["A", "B"], xcodePath: "/Xcode", retry: RetryPolicy(maxAttempts: 3, intervalSeconds: 1800))
            XCTAssertEqual(outcomes.map(\.attempts), [1, 1])
            XCTAssertNotNil(outcomes[0].failureReason)
            XCTAssertFalse(outcomes[0].output.contains("秒后仅重试"))
            XCTAssertTrue(outcomes[1].success)
        }
    }

    func testEachRetryRefreshesDeviceInsteadOfUsingOldSnapshot() async {
        let runner = MockProcessRunner()
        runner.enqueue(makeProcessResult(exitCode: 1, stderr: "connection interrupted"))
        let discovery = ScriptedDeviceDiscovery([[device("A")], [device("A", available: false)]])
        let outcomes = await AppInstaller(runner: runner, deviceDiscovery: discovery)
            .install(appPath: "/tmp/Demo.app", deviceUDIDs: ["A"], xcodePath: "/Xcode", retry: retry)
        XCTAssertEqual(runner.recordedCalls.count, 1)
        XCTAssertEqual(outcomes[0].attempts, 1)
        XCTAssertTrue(outcomes[0].failureReason?.contains("当前不可用") == true)
        let calls = await discovery.calls
        XCTAssertEqual(calls, 2)
    }

    func testDuplicateTargetsAreInstalledOnlyOnce() async {
        let runner = MockProcessRunner()
        let result = await AppInstaller(runner: runner, deviceDiscovery: FixedDeviceDiscovery(devices: [device("A")]))
            .install(appPath: "/tmp/Demo.app", deviceUDIDs: ["A", "A"], xcodePath: "/Xcode", retry: retry)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(runner.recordedCalls.count, 1)
    }

    func testCancellationPreservesCompletedDeviceAndSkipsRemainingTargets() async {
        let runner = MockProcessRunner()
        runner.enqueue(makeProcessResult(exitCode: 0)) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let installer = AppInstaller(runner: runner, deviceDiscovery: FixedDeviceDiscovery(devices: [device("A"), device("B")]))
        let result = await Task {
            await installer.install(appPath: "/tmp/Demo.app", deviceUDIDs: ["A", "B"], xcodePath: "/Xcode", retry: retry)
        }.value
        XCTAssertEqual(result.map(\.success), [true, false])
        XCTAssertEqual(result.map(\.attempts), [1, 0])
        XCTAssertEqual(runner.recordedCalls.map { $0.arguments[5] }, ["A"])
    }
}
