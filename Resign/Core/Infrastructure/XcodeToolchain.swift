import Foundation

/// Xcode installation locations, environment and validation.
enum XcodeToolchain {
    static func developerDirectory(xcodePath: String) -> String {
        xcodePath + "/Contents/Developer"
    }

    static func xcodebuildPath(xcodePath: String) -> String {
        xcodePath + "/Contents/Developer/usr/bin/xcodebuild"
    }

    static let xcrunPath = "/usr/bin/xcrun"

    static func validate(xcodePath: String) -> String? {
        let executable = xcodebuildPath(xcodePath: xcodePath)
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return "无效的 Xcode 路径：找不到可执行的 xcodebuild"
        }
        return nil
    }

    static func environment(xcodePath: String) -> [String: String] {
        var path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for prefix in ["/opt/homebrew/bin", "/usr/local/bin"] where !path.split(separator: ":").contains(Substring(prefix)) {
            path = prefix + ":" + path
        }
        return [
            "DEVELOPER_DIR": developerDirectory(xcodePath: xcodePath),
            "PATH": path
        ]
    }
}
