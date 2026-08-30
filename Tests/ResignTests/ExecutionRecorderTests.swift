import XCTest
@testable import Resign

final class ExecutionRecorderTests: XCTestCase {
    private var state = PersistedState()
    private let projectID = UUID()

    override func setUp() {
        super.setUp()
        state = PersistedState(
            projects: [iOSProject(id: projectID, name: "Demo", projectPath: "/tmp/Demo.xcodeproj")]
        )
    }

    private func apply(_ result: BuildResult, source: ExecutionSource = .manual, externalize: ExecutionRecorder.OutputExternalizer? = nil, startedAt: Date = Date(timeIntervalSince1970: 1_000)) {
        ExecutionRecorder.apply(
            .init(
                projectID: projectID,
                projectName: "Demo",
                result: result,
                source: source,
                startedAt: startedAt,
                durationSeconds: 42,
                deviceNames: ["D1": "iPhone 15"]
            ),
            to: &state,
            externalize: externalize ?? { raw, _ in (nil, raw) }
        )
    }

    func testSuccessUpdatesExecutionStateAndProjectFields() {
        apply(BuildResult(success: true, output: "ok"), source: .scheduled)

        XCTAssertEqual(state.logs.count, 1)
        XCTAssertEqual(state.logs.first?.status, .success)
        XCTAssertEqual(state.logs.first?.source, .scheduled)
        XCTAssertEqual(state.logs.first?.durationSeconds, 42)

        let executionState = state.executionStates.first
        XCTAssertEqual(executionState?.projectID, projectID)
        XCTAssertEqual(executionState?.lastSuccessfulInstallDate, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(executionState?.lastStatus, .success)
        XCTAssertEqual(executionState?.lastSource, .scheduled)
        XCTAssertNil(executionState?.lastFailureSummary)

        XCTAssertEqual(state.projects.first?.lastBuildStatus, .success)
    }

    func testFailureKeepsPreviousSuccessDateAndRecordsSummary() {
        // First run succeeds.
        apply(BuildResult(success: true, output: "ok"), startedAt: Date(timeIntervalSince1970: 1_000))
        // Second run fails with a signing error.
        apply(
            BuildResult(success: false, output: "error: no profiles for 'com.example' were found", failedDeviceUDIDs: []),
            startedAt: Date(timeIntervalSince1970: 2_000)
        )

        let executionState = state.executionStates.first
        XCTAssertEqual(executionState?.lastSuccessfulInstallDate, Date(timeIntervalSince1970: 1_000), "失败不能清空上次成功时间")
        XCTAssertEqual(executionState?.lastStatus, .failed)
        XCTAssertEqual(executionState?.lastFailureSummary?.contains("Provisioning Profile"), true)

        // Failed device names are reflected in the log entry.
        apply(
            BuildResult(success: false, output: "install failed", failedDeviceUDIDs: ["D1"]),
            startedAt: Date(timeIntervalSince1970: 3_000)
        )
        XCTAssertEqual(state.logs.first?.failedDevices, ["iPhone 15"])
    }

    func testCancelledRunRecordedAsCancelled() {
        apply(BuildResult.cancelledResult())
        XCTAssertEqual(state.logs.first?.status, .cancelled)
        XCTAssertEqual(state.executionStates.first?.lastStatus, .cancelled)
    }

    func testFirstEverFailureRecordsFailureSummary() {
        // 项目第一次运行就失败：execution state 是新建的，
        // lastFailureSummary 也必须立刻写入，而不是等第二次失败。
        apply(
            BuildResult(success: false, output: "error: No Account for Team \"XXXX\". Add a new account in Accounts settings"),
            startedAt: Date(timeIntervalSince1970: 5_000)
        )

        let executionState = state.executionStates.first
        XCTAssertEqual(executionState?.lastStatus, .failed)
        XCTAssertNil(executionState?.lastSuccessfulInstallDate)
        XCTAssertEqual(executionState?.lastFailureSummary?.contains("没有登录 Xcode"), true)
    }

    func testRecordsDeviceSummariesAndInstalledAppPath() {
        var result = BuildResult(success: false, output: "install output")
        result.installedAppPath = "/tmp/Demo.app"
        result.deviceOutcomes = [
            DeviceInstallOutcome(udid: "D1", success: true, attempts: 1, output: ""),
            DeviceInstallOutcome(udid: "D2", success: false, attempts: 3, output: "")
        ]
        apply(result, source: .scheduled)

        let entry = state.logs.first
        XCTAssertEqual(entry?.installedAppPath, "/tmp/Demo.app")
        XCTAssertEqual(entry?.deviceInstallSummaries, [
            DeviceInstallSummary(udid: "D1", deviceName: "iPhone 15", success: true, attempts: 1),
            DeviceInstallSummary(udid: "D2", deviceName: "D2", success: false, attempts: 3)
        ])
    }

    func testUpsertDoesNotDuplicateExecutionState() {
        apply(BuildResult(success: true, output: "ok"))
        apply(BuildResult(success: true, output: "ok again"))
        XCTAssertEqual(state.executionStates.count, 1)
        XCTAssertEqual(state.logs.count, 2)
    }

    func testOversizedOutputIsExternalized() {
        let bigOutput = String(repeating: "z", count: 200_000)
        var externalizedName: String?
        apply(
            BuildResult(success: false, output: bigOutput),
            externalize: { raw, _ in
                let name = "build_test.log"
                externalizedName = name
                return (name, LogRepository.summary(of: raw, fileName: name))
            }
        )
        XCTAssertEqual(state.logs.first?.logFile, externalizedName)
        XCTAssertLessThan(state.logs.first!.output.count, bigOutput.count)
    }
}
