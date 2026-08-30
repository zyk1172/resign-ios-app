import XCTest
@testable import Resign

/// Worker 退出码语义测试：
///   0 正常 / 1 构建/安装失败 / 2 无效调用 / 3 配置读取失败 / 4 结果落盘失败
/// 配置损坏时绝不允许"成功地什么都不做"（旧版 bug：exit 0 静默失败）。
final class ScheduledRunCoordinatorTests: XCTestCase {
    private var directory: URL!
    private var runner: MockProcessRunner!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("worker-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        runner = MockProcessRunner()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCoordinator() -> ScheduledRunCoordinator {
        ScheduledRunCoordinator(configDirectory: directory, runner: runner)
    }

    func testCorruptedConfigExits3WithoutAnyExternalCall() async throws {
        try Data("this is not json {{{".utf8).write(to: directory.appendingPathComponent("config.json"))

        let code = await makeCoordinator().run()

        XCTAssertEqual(code, 3, "配置读取失败必须以 exit 3 中止，而不是当作空配置成功")
        XCTAssertTrue(runner.recordedCalls.isEmpty, "配置无效时不得调用任何外部命令")
    }

    func testEmptyConfigExits0() async throws {
        // 尚未配置过任何项目的全新安装：读取成功、无项目 → 正常结束。
        try Data("{\"schemaVersion\":2}".utf8).write(to: directory.appendingPathComponent("config.json"))

        let code = await makeCoordinator().run()

        XCTAssertEqual(code, 0)
        XCTAssertTrue(runner.recordedCalls.isEmpty, "无到期项目时不应触碰 xcodebuild/devicectl")
    }

    func testDisabledProjectIsNeverDue() async throws {
        let projectID = UUID()
        let config = """
        {"schemaVersion":2,"projects":[{"id":"\(projectID.uuidString)","name":"Idle","projectPath":"/tmp/Idle.xcodeproj","scheme":"Idle","isEnabled":false}],"settings":{},"executionStates":[],"logs":[]}
        """
        try Data(config.utf8).write(to: directory.appendingPathComponent("config.json"))

        let code = await makeCoordinator().run()

        XCTAssertEqual(code, 0)
        XCTAssertTrue(runner.recordedCalls.isEmpty)
    }
}
