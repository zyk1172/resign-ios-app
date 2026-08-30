import Foundation
import CryptoKit

/// 计算项目构建指纹：源码/工程/依赖自上次构建以来是否变化。
///
/// 设计原则（对应评审要求）：
/// - 不扫描整个工程目录的所有文件，只纳入**影响构建产物**的输入：
///   允许扩展名（.swift/.m/.h/.plist/.entitlements/.xcconfig/.storyboard/.xib/
///   .strings/.json 等）、特殊文件名（Package.swift、Package.resolved、
///   project.pbxproj、Podfile 等）、以及整个 .xcassets 目录内容；
/// - 排除确定不参与构建的目录：.git、build、.build、DerivedData、
///   node_modules、.swiftpm、xcuserdata、Carthage；
/// - 不依赖 Git（无仓库/切 commit/ignored 文件都要正确）；
/// - 内容哈希（SHA-256）而非 mtime：touch 不会造成假失效；
/// - 工程配置（路径/Scheme/Configuration/平台/Team）作为独立段落参与指纹。
enum ProjectFingerprintService {

    /// 这些目录不参与指纹。注意 Pods 源码参与构建，因此不在排除列表内。
    static let skippedDirectoryNames: Set<String> = [
        ".git", ".build", "build", "Build", "DerivedData", "node_modules",
        ".swiftpm", "xcuserdata", "Carthage", "fastlane"
    ]

    /// 参与指纹的文件扩展名（小写比较）。包含常见"直接作为 Bundle
    /// Resources 的非代码文件"（图片/音视频/字体/PDF 等）。
    static let includedExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "hh", "c", "cpp", "cc", "cxx", "x", "xmm",
        "plist", "entitlements", "xcconfig", "storyboard", "xib",
        "strings", "stringsdict", "xcstrings", "json", "yaml", "yml",
        "xcscheme", "modulemap", "spb", "atlas", "scn",
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "pdf",
        "mp3", "m4a", "wav", "aiff", "caf", "mp4", "mov",
        "ttf", "otf", "mlmodel", "mlpackage"
    ]

    /// 无论扩展名如何都参与指纹的特殊文件名（依赖/工程清单）。
    static let includedFileNames: Set<String> = [
        "project.pbxproj", "Package.swift", "Package.resolved",
        "Podfile", "Podfile.lock", "Cartfile", "Cartfile.resolved"
    ]

    /// 单文件哈希上限：超过此大小的文件只按"路径+大小"参与（防极端资源拖慢指纹）。
    static let maxHashedFileSize = 256 * 1024 * 1024

    /// 计算项目指纹（阻塞文件 IO，调用方应在后台执行）。
    /// 指纹 = SHA-256(工程配置段落 ⊕ 排序后的 [相对路径, 内容哈希] 序列)。
    static func fingerprint(of project: iOSProject) throws -> String {
        var hasher = SHA256()

        let configSection = [
            project.projectPath,
            project.scheme,
            project.configuration,
            project.platform.rawValue,
            project.teamID ?? ""
        ].joined(separator: "\u{0}")
        hasher.update(data: Data(configSection.utf8))

        let root = URL(fileURLWithPath: project.projectPath).deletingLastPathComponent()
        let ownProjectFileName = URL(fileURLWithPath: project.projectPath).lastPathComponent
        var entries: [(path: String, digest: String)] = []
        try collectEntries(root: root, ownProjectFileName: ownProjectFileName, into: &entries)

        for entry in entries.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data(entry.path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(entry.digest.utf8))
            hasher.update(data: Data([0]))
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 目录直属内容里存在**其他名字**的 .xcodeproj → 该目录是另一个独立
    /// 工程的根目录，跳过（扫描根本身豁免）。
    private static func isForeignProjectRoot(_ directory: URL, excluding ownProjectFileName: String) -> Bool {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return children.contains { child in
            child.hasDirectoryPath && child.lastPathComponent.hasSuffix(".xcodeproj")
                && child.lastPathComponent != ownProjectFileName
        }
    }

    private static func collectEntries(
        root: URL,
        ownProjectFileName: String,
        into entries: inout [(path: String, digest: String)]
    ) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if url.hasDirectoryPath {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDirectory else { continue }

                // .xcodeproj / .xcworkspace / .xcassets / .xcdatamodel(d) /
                // .scnassets / .lproj 内部整体参与（除 xcuserdata）。
                let isBundleDir = name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace")
                let isAssetDir = name.hasSuffix(".xcassets") || name.hasSuffix(".xcdatamodeld")
                    || name.hasSuffix(".xcdatamodel") || name.hasSuffix(".scnassets")
                if skippedDirectoryNames.contains(name) || name == "xcuserdata" {
                    enumerator.skipDescendants()
                } else if !isBundleDir && !isAssetDir && !name.hasSuffix(".lproj"),
                          isForeignProjectRoot(url, excluding: ownProjectFileName) {
                    // 兄弟目录是另一个独立 Xcode 工程（有自己的 .xcodeproj）：
                    // 其源码变化不影响本工程构建产物，跳过以避免假 cache miss。
                    enumerator.skipDescendants()
                }
                continue
            }

            // 文件级规则
            if name == ".DS_Store" { continue }
            let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let isInBundleDir = relativePath.contains(".xcodeproj/") || relativePath.contains(".xcworkspace/")
            let isInAssetDir = relativePath.contains(".xcassets/")
            let extensionIncluded = includedExtensions.contains(url.pathExtension.lowercased())
            let nameIncluded = includedFileNames.contains(name)
            guard isInBundleDir || isInAssetDir || extensionIncluded || nameIncluded else { continue }

            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let digest: String
            if size > maxHashedFileSize {
                digest = "size:\(size)"
            } else {
                digest = fileSHA256(url)
            }
            entries.append((relativePath, digest))
        }
    }

    static func fileSHA256(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "unreadable" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
