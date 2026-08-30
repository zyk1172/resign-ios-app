import XCTest
@testable import Resign

/// 项目指纹测试：相同输入 → 相同指纹；影响构建的输入变化 → 指纹变化；
/// 无关临时文件 → 指纹不变（评审 §19.1–19.8）。
final class FingerprintServiceTests: XCTestCase {
    private var root: URL!
    private var project: iOSProject!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fingerprint-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Demo.xcodeproj"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Demo"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Demo/Assets.xcassets/AppIcon.appiconset"),
            withIntermediateDirectories: true
        )

        try Data("pbxproj-v1".utf8).write(to: root.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
        try Data("import SwiftUI".utf8).write(to: root.appendingPathComponent("Demo/App.swift"))
        try Data("<plist/>".utf8).write(to: root.appendingPathComponent("Demo/Info.plist"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("Demo/Assets.xcassets/AppIcon.appiconset/Contents.json"))
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: root.appendingPathComponent("Demo/Assets.xcassets/AppIcon.appiconset/icon.png"))

        var p = iOSProject(name: "Demo", projectPath: root.appendingPathComponent("Demo.xcodeproj").path, scheme: "Demo")
        p.platform = .ios
        p.teamID = "ABCDE12345"
        project = p
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func fingerprint() throws -> String {
        try ProjectFingerprintService.fingerprint(of: project)
    }

    func testIdenticalProjectYieldsSameFingerprint() throws {
        XCTAssertEqual(try fingerprint(), try fingerprint())
    }

    func testSwiftSourceChangeChangesFingerprint() throws {
        let before = try fingerprint()
        try Data("import SwiftUI\nimport os".utf8).write(to: root.appendingPathComponent("Demo/App.swift"))
        XCTAssertNotEqual(before, try fingerprint())
    }

    func testPlistChangeChangesFingerprint() throws {
        let before = try fingerprint()
        try Data("<plist version=2/>".utf8).write(to: root.appendingPathComponent("Demo/Info.plist"))
        XCTAssertNotEqual(before, try fingerprint())
    }

    func testAssetResourceChangeChangesFingerprint() throws {
        let before = try fingerprint()
        try Data([0x89, 0x50, 0x4E, 0x48]).write(to: root.appendingPathComponent("Demo/Assets.xcassets/AppIcon.appiconset/icon.png"))
        XCTAssertNotEqual(before, try fingerprint())
    }

    func testProjectFileChangeChangesFingerprint() throws {
        let before = try fingerprint()
        try Data("pbxproj-v2".utf8).write(to: root.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
        XCTAssertNotEqual(before, try fingerprint())
    }

    func testPackageResolvedChangeChangesFingerprint() throws {
        let before = try fingerprint()
        try Data(#"{"sha1":"a"}"#.utf8).write(to: root.appendingPathComponent("Package.resolved"))
        let afterAdd = try fingerprint()
        XCTAssertNotEqual(before, afterAdd, "依赖清单文件必须参与指纹")

        try Data(#"{"sha1":"b"}"#.utf8).write(to: root.appendingPathComponent("Package.resolved"))
        XCTAssertNotEqual(afterAdd, try fingerprint(), "Package.resolved 变化必须使缓存失效")
    }

    func testUnrelatedFilesDoNotChangeFingerprint() throws {
        let before = try fingerprint()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: root.appendingPathComponent("build/cache.tmp"))
        try Data("junk".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        try Data("notes".utf8).write(to: root.appendingPathComponent("README.txt"))
        XCTAssertEqual(before, try fingerprint(), "临时文件/未纳入构建的文件不应使缓存失效")
    }

    func testConfigurationChangeChangesFingerprint() throws {
        let before = try fingerprint()
        project.configuration = "Release"
        XCTAssertNotEqual(before, try fingerprint())
    }
}
