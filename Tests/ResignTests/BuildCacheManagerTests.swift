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

    func testFirstRunIsFullBuild() {
        // 全新安装：无元数据、无工作区 → 首次构建。
        if case .fullBuild(let reason) = decide(workspaceExists: false) {
            XCTAssertTrue(reason.contains("首次构建"))
        } else {
            XCTFail("无元数据必须完整构建")
        }
        // 有工作区但无元数据（例如元数据文件被手动删除）→ 同样完整构建。
        if case .fullBuild = decide(workspaceExists: true) {
            // 期望完整构建
        } else {
            XCTFail("无元数据必须完整构建")
        }
    }

    func testUnchangedProjectIsIncrementalBuild() throws {
        try BuildCacheManager.saveMetadata(metadata(), directory: cacheDirectory)
        if case .incrementalBuild(let reason) = decide() {
            XCTAssertTrue(reason.contains("指纹未变化"))
        } else {
            XCTFail("指纹一致必须增量复用")
        }
    }

    func testChangedFingerprintIsFullBuild() throws {
        try BuildCacheManager.saveMetadata(metadata(), directory: cacheDirectory)
        if case .fullBuild(let reason) = decide(fingerprint: "fingerprint-v2") {
            XCTAssertTrue(reason.contains("指纹变化"))
        } else {
            XCTFail("源码变化必须完整构建")
        }
    }

    func testMissingWorkspaceIsFullBuildEvenWhenFingerprintMatches() throws {
        try BuildCacheManager.saveMetadata(metadata(), directory: cacheDirectory)
        if case .fullBuild(let reason) = decide(workspaceExists: false) {
            XCTAssertTrue(reason.contains("工作区缺失"), "元数据在但工作区不存在必须重建（对应评审 §19.12）")
        } else {
            XCTFail("工作区缺失必须完整构建")
        }
    }

    func testXcodeVersionChangeInvalidatesCache() throws {
        try BuildCacheManager.saveMetadata(
            metadata(xcodeVersion: "Xcode 16.4\nBuild version 16F6"),
            directory: cacheDirectory
        )
        if case .fullBuild(let reason) = decide() {
            XCTAssertTrue(reason.contains("Xcode 版本变化"))
        } else {
            XCTFail("Xcode 版本变化必须失效缓存")
        }
    }

    func testConfigurationChangeInvalidatesCache() throws {
        try BuildCacheManager.saveMetadata(metadata(configuration: "Release"), directory: cacheDirectory)
        if case .fullBuild(let reason) = decide() {
            XCTAssertTrue(reason.contains("配置变化"))
        } else {
            XCTFail("Configuration 变化必须失效缓存")
        }
    }

    func testProjectPathChangeInvalidatesCache() throws {
        try BuildCacheManager.saveMetadata(
            metadata(projectPath: "/tmp/other/Demo.xcodeproj"),
            directory: cacheDirectory
        )
        if case .fullBuild(let reason) = decide() {
            XCTAssertTrue(reason.contains("项目路径变化"))
        } else {
            XCTFail("项目路径变化必须失效缓存")
        }
    }

    func testCorruptedMetadataFallsBackToFullBuild() throws {
        try Data("not json {".utf8).write(to: BuildCacheManager.metadataURL(for: project.id, directory: cacheDirectory))
        if case .fullBuild = decide() {
            // 期望：元数据损坏 → 无缓存 → 回退完整构建，不失败
        } else {
            XCTFail("元数据损坏必须回退完整构建")
        }
    }

    func testUnsuccessfulPreviousBuildIsFullBuild() throws {
        try BuildCacheManager.saveMetadata(metadata(buildSucceeded: false), directory: cacheDirectory)
        if case .fullBuild(let reason) = decide() {
            XCTAssertTrue(reason.contains("未成功"))
        } else {
            XCTFail("上次构建未成功时不能复用")
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
