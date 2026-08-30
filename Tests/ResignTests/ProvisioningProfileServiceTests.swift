import XCTest
@testable import Resign

/// profile 存储清理测试：删除当前 App 的旧 profile（含扩展），
/// 保留其他 App 的 profile；只有 Resign 管理的目录会被触碰。
final class ProvisioningProfileServiceTests: XCTestCase {
    private var storeDirectory: URL!
    private var otherDirectory: URL!

    override func setUpWithError() throws {
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-store-\(UUID().uuidString)", isDirectory: true)
        otherDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-other-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeDirectory)
        try? FileManager.default.removeItem(at: otherDirectory)
    }

    private func writeProfile(
        named name: String,
        in directory: URL,
        teamID: String = "9KXSB4HR69",
        appID: String = "9KXSB4HR69.com.example.demo"
    ) throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>Name</key><string>iOS Team Provisioning Profile: \(appID)</string>
        <key>TeamIdentifier</key><array><string>\(teamID)</string></array>
        <key>ExpirationDate</key><date>2026-09-06T00:00:00Z</date>
        <key>Entitlements</key><dict><key>application-identifier</key><string>\(appID)</string></dict>
        </dict></plist>
        """
        let payload = Data("cms-noise".utf8) + Data(xml.utf8) + Data("sig".utf8)
        try payload.write(to: directory.appendingPathComponent("\(name).mobileprovision"))
    }

    func testParseExtractsTeamAppIDAndExpiration() throws {
        try writeProfile(named: "p1", in: storeDirectory)
        let profiles = ProvisioningProfileService.storedProfiles(directory: storeDirectory)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.teamID, "9KXSB4HR69")
        XCTAssertEqual(profiles.first?.applicationID, "9KXSB4HR69.com.example.demo")
        XCTAssertNotNil(profiles.first?.expirationDate)
    }

    func testDeleteRemovesAppAndExtensionProfilesButKeepsOthers() throws {
        try writeProfile(named: "app", in: storeDirectory, appID: "9KXSB4HR69.com.example.demo")
        try writeProfile(named: "ext", in: storeDirectory, appID: "9KXSB4HR69.com.example.demo.Widget")
        try writeProfile(named: "other", in: storeDirectory, appID: "JUQXD87P93.com.other.app")
        try writeProfile(named: "unrelated", in: otherDirectory, appID: "9KXSB4HR69.com.example.demo")

        let removed = try ProvisioningProfileService.deleteStoredProfiles(
            bundleID: "com.example.demo",
            directories: [storeDirectory, otherDirectory]
        )

        XCTAssertEqual(removed, 3, "主 App + 扩展 + 其他目录中的同 Bundle ID profile 都要清除")
        XCTAssertEqual(ProvisioningProfileService.storedProfiles(directory: storeDirectory).count, 1, "只保留其他 App 的 profile")
        XCTAssertEqual(ProvisioningProfileService.storedProfiles(directory: storeDirectory).first?.applicationID, "JUQXD87P93.com.other.app")
    }

    func testDeleteWithEmptyBundleIDIsNoOp() throws {
        try writeProfile(named: "app", in: storeDirectory)
        let removed = try ProvisioningProfileService.deleteStoredProfiles(
            bundleID: "",
            directories: [storeDirectory]
        )
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(ProvisioningProfileService.storedProfiles(directory: storeDirectory).count, 1)
    }

    func testGarbageFileIsSkippedWithoutFailure() throws {
        try Data("random bytes".utf8).write(to: storeDirectory.appendingPathComponent("broken.mobileprovision"))
        XCTAssertEqual(ProvisioningProfileService.storedProfiles(directory: storeDirectory).count, 0)
        XCTAssertEqual(try ProvisioningProfileService.deleteStoredProfiles(bundleID: "x", directories: [storeDirectory]), 0)
    }
}
