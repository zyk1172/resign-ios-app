import Foundation

/// 管理存储在 `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`
/// 的本地 provisioning profile。
///
/// 关键职责：在签名构建前删除该 App 的旧 profile。xcodebuild
/// `-allowProvisioningUpdates` 的行为是"存储里有有效 profile 就直接复用"，
/// 即使项目已切换 Team / 设备注册已变化——这会导致构建出的 App 嵌着旧
/// 团队或旧设备列表的 profile，安装失败（0xe8008012）或装上后过期失效。
/// 删除旧 profile 后，xcodebuild 才会为当前 Team + 当前已注册设备重新
/// 生成新 profile（免费账号有效期 = 创建时刻 + 7 天）。
enum ProvisioningProfileService {

    struct StoredProfile: Equatable, Sendable {
        var url: URL
        var name: String
        var teamID: String?
        var applicationID: String?
        var expirationDate: Date?
    }

    static var defaultDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles", isDirectory: true)
        ]
    }

    /// 解析目录内所有 profile（损坏/无法解析的文件跳过）。
    static func storedProfiles(directory: URL) -> [StoredProfile] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files.compactMap { url in
            let ext = url.pathExtension.lowercased()
            guard ext == "mobileprovision" || ext == "provisionprofile" else { return nil }
            return parse(url: url)
        }
    }

    /// 解析单个 profile（mobileprovision = CMS 包裹的明文 XML plist）。
    static func parse(url: URL) -> StoredProfile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>"),
              start.lowerBound < end.upperBound
        else { return nil }
        let xml = String(text[start.lowerBound..<end.upperBound])
        guard let plist = try? PropertyListSerialization.propertyList(
            from: Data(xml.utf8), options: [], format: nil
        ) as? [String: Any] else { return nil }

        let entitlements = plist["Entitlements"] as? [String: Any]
        return StoredProfile(
            url: url,
            name: plist["Name"] as? String ?? "",
            teamID: (plist["TeamIdentifier"] as? [String])?.first,
            applicationID: entitlements?["application-identifier"] as? String,
            expirationDate: plist["ExpirationDate"] as? Date
        )
    }

    /// 删除 application-identifier 对应 `bundleID`（主 App）或以其为前缀
    /// （App 扩展，如 `TEAMID.bundleID.Widget`）的旧 profile，返回删除数量。
    /// application-identifier 形如 `TEAMID（10 位）.bundleID`；只触碰 profile
    /// 存储目录内的文件。
    @discardableResult
    static func deleteStoredProfiles(
        bundleID: String,
        directories: [URL] = defaultDirectories
    ) throws -> Int {
        guard !bundleID.isEmpty else { return 0 }
        var removed = 0
        for directory in directories {
            for profile in storedProfiles(directory: directory) {
                guard let appID = profile.applicationID else { continue }
                // 剥离 "TEAMID." 前缀（团队 ID 固定 10 位）
                let idPart = appID.count > 11 ? String(appID.dropFirst(11)) : appID
                let matches = idPart == bundleID || idPart.hasPrefix(bundleID + ".")
                guard matches else { continue }
                try? FileManager.default.removeItem(at: profile.url)
                removed += 1
            }
        }
        return removed
    }
}
