import XCTest
@testable import Resign

/// 缓存决策测试（评审 §19.9–19.20 的决策与清理部分）。
final class BuildCacheManagerTests: XCTestCase {
    private var stateRoot: URL!
    private var cacheDirectory: URL!
    private var workspacesDirectory: URL!
    private var project: iOSProject!
    private var fingerprint: String!
    private let xcodeVersion = "Xcode 27.0\nBuild version 27A5209h"

    override func setUpWithError() throws {
        stateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cachemgr-tests-\(UUID().uuidString)", isDirectory: true)
        cacheDirectory = stateRoot.appendingPathComponent("BuildCache", isDirectory: true)
        workspacesDirectory = stateRoot.appendingPathComponent("DerivedData", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        var p = iOSProject(name: "Demo", projectPath: "/tmp/proj/Demo.xcodeproj", scheme: "Demo")
        p.platform = .ios
        p.teamID = "ABCDE12345"
        project = p
        fingerprint = "fingerprint-v1"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateRoot)
    }

    private func metadata(
        fingerprint: String = "fingerprint-v1",
        xcodeVersion: String = "Xcode 27.0\nBuild version 27A5209h",
        projectPath: String = "/tmp/proj/Demo.xcodeproj",
        configuration: String = "Debug",
        buildSucceeded: Bool = true
    ) -> BuildArtifactMetadata {
        BuildArtifactMetadata(
            projectID: project.id,
            fingerprint: fingerprint,
            xcodeVersion: xcodeVersion,
            builtAt: Date(),
            scheme: "Demo",
            configuration: configuration,
            platform: .ios,
            teamID: "ABCDE12345",
            projectPath: projectPath,
            buildSucceeded: buildSucceeded
        )
    }

    private func decide(
        fingerprint: String = "fingerprint-v1",
        workspaceExists: Bool = true
    ) -> BuildCacheDecision {
        BuildCacheManager.decide(
            project: project,
            currentFingerprint: fingerprint,
            xcodeVersion: xcodeVersion,
            workspaceExists: workspaceExists,
            directory: cacheDirectory
        )
    }

    // MARK: - Decision

    func testFirstRunIsColdBuild() {
        // 全新安装：无元数据、无工作区 → 冷启动构建。
        if case .coldBuild(let reason) = decide(workspaceExists: false) {
            XCTAssertTrue(reason.contains("首次构建"))
        } else {
            XCTFail("无元数据且无工作区必须冷启动构建")
        }
        // 有工作区但无元数据（例如元数据文件被手动删除）→ 信任 Xcode 增量状态。
        if case .incrementalChangedBuild(let reason) = decide(workspaceExists: true) {
            XCTAssertTrue(reason.contains("无缓存元数据"))
        } else {
            XCTFail("有工作区无元数据必须按增量处理")
        }
    }

    func testUnchangedProjectIsIncrementalUnchangedBuild() throws {
        try BuildCacheManager.saveMetadata(metadata(), directory: cacheDirectory)
        if case .incrementalUnchangedBuild(let reason) = decide() {
            XCTAssertTrue(reason.contains("项目未变化"))
        } else {
            XCTFail("指纹一致必须增量复用")
        }
    }

    func testChangedFingerprintIsIncrementalChangedBuild() throws {
        try BuildCacheManager.saveMetadata(metadata(), directory: cacheDirectory)
        if case .incrementalChangedBuild(let reason) = decide(fingerprint: "fingerprint-v2") {
            XCTAssertTrue(reason.contains("项目有更新"))
        } else {
            XCTFail("源码变化必须走增量变更构建（保留工作区）")
        }
    }

    func testMissingWorkspaceIsColdBuildEvenWhenFingerprintMatches() throws {
        try BuildCacheManager.saveMetadata(metadata(), directory: cacheDirectory)
        if case .coldBuild(let reason) = decide(workspaceExists: false) {
            XCTAssertTrue(reason.contains("工作区缺失"), "元数据在但工作区不存在必须重建（对应评审 §19.12）")
        } else {
            XCTFail("工作区缺失必须冷启动重建")
        }
    }

    func testXcodeVersionChangeTriggersCleanBuild() throws {
        try BuildCacheManager.saveMetadata(
            metadata(xcodeVersion: "Xcode 16.4\nBuild version 16F6"),
            directory: cacheDirectory
        )
        if case .cleanBuild(let reason) = decide() {
            XCTAssertTrue(reason.contains("Xcode 版本变化"))
        } else {
            XCTFail("Xcode 版本变化必须清除工作区重建")
        }
        XCTAssertTrue(decide().clearsWorkspace, "cleanBuild 决策必须清除工作区")
    }

    func testConfigurationChangeIsIncrementalChangedBuild() throws {
        try BuildCacheManager.saveMetadata(metadata(configuration: "Release"), directory: cacheDirectory)
        if case .incrementalChangedBuild(let reason) = decide() {
            XCTAssertTrue(reason.contains("配置变化"))
        } else {
            XCTFail("Configuration 变化必须走增量变更构建")
        }
        XCTAssertFalse(decide().clearsWorkspace)
    }

    func testProjectPathChangeTriggersCleanBuild() throws {
        try BuildCacheManager.saveMetadata(
            metadata(projectPath: "/tmp/other/Demo.xcodeproj"),
            directory: cacheDirectory
        )
        if case .cleanBuild(let reason) = decide() {
            XCTAssertTrue(reason.contains("项目路径变化"))
        } else {
            XCTFail("项目路径变化必须清除工作区重建")
        }
    }

    func testCorruptedMetadataTreatedAsNoMetadata() throws {
        try Data("not json {".utf8).write(to: BuildCacheManager.metadataURL(for: project.id, directory: cacheDirectory))
        // 元数据损坏 → 视为无元数据；工作区仍在则按增量处理，不失败
        if case .incrementalChangedBuild = decide(workspaceExists: true) {
            // 期望
        } else {
            XCTFail("元数据损坏且有工作区时必须按增量处理")
        }
    }

    func testUnsuccessfulPreviousBuildIsIncrementalChangedBuild() throws {
        try BuildCacheManager.saveMetadata(metadata(buildSucceeded: false), directory: cacheDirectory)
        if case .incrementalChangedBuild(let reason) = decide() {
            XCTAssertTrue(reason.contains("未成功"))
        } else {
            XCTFail("上次构建未成功时按增量变更处理")
        }
    }

    // MARK: - Clear

    func testClearRemovesWorkspaceAndMetadataButNothingElse() throws {
        let workspace = workspacesDirectory.appendingPathComponent(project.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Build"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: workspace.appendingPathComponent("Build/artifact"))
        try BuildCacheManager.saveMetadata(metadata(), directory: cacheDirectory)

        let sibling = workspacesDirectory.appendingPathComponent("sibling-keep.txt")
        try Data("keep".utf8).write(to: sibling)

        try BuildCacheManager.clear(
            projectID: project.id,
            buildLockPath: stateRoot.appendingPathComponent("clear.lock").path,
            workspacesDirectory: workspacesDirectory,
            directory: cacheDirectory
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
        XCTAssertNil(BuildCacheManager.loadMetadata(for: project.id, directory: cacheDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path), "只允许清理 Resign 管理路径")
    }

    func testClearRefusesWhileBuildLockHeld() throws {
        let lockPath = stateRoot.appendingPathComponent("clear.lock").path
        let holder = FileLock(path: lockPath)
        XCTAssertTrue(holder.acquire())
        defer { holder.release() }

        XCTAssertThrowsError(
            try BuildCacheManager.clear(
                projectID: project.id,
                buildLockPath: lockPath,
                workspacesDirectory: workspacesDirectory,
                directory: cacheDirectory
            )
        ) { error in
            XCTAssertTrue("\(error)".contains("锁") || error is BuildCacheError)
        }
    }
}
