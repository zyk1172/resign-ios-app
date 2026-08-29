import Foundation
import AppKit

/// Loads and caches a representative app icon for a project by locating its
/// largest AppIcon.appiconset PNG on disk.
enum AppIconService {
    private static let iconCache = IconDataCache()

    @MainActor
    static func loadAppIcon(projectPath: String) async -> NSImage? {
        if let cached = await iconCache.data(for: projectPath) {
            return NSImage(data: cached)
        }
        let data = await Task.detached(priority: .utility) {
            findIconData(projectPath: projectPath)
        }.value
        guard let data else { return nil }
        await iconCache.insert(data, for: projectPath)
        return NSImage(data: data)
    }

    private static func findIconData(projectPath: String) -> Data? {
        let root = URL(fileURLWithPath: projectPath).deletingLastPathComponent()
        let fileManager = FileManager.default
        let skippedDirectories: Set<String> = [
            "Pods", "DerivedData", "Carthage", "build", ".build", "node_modules", ".git", "fastlane"
        ]

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var appIconSetURL: URL?
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name == "AppIcon.appiconset" {
                appIconSetURL = url
                break
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory && skippedDirectories.contains(name) {
                enumerator.skipDescendants()
            }
        }
        guard let appIconSetURL,
              let files = try? fileManager.contentsOfDirectory(
                at: appIconSetURL,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
              )
        else { return nil }

        let pngFiles = files.filter { $0.pathExtension.lowercased() == "png" }
        guard let largest = pngFiles.max(by: {
            let lhs = (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let rhs = (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return lhs < rhs
        }) else { return nil }
        return try? Data(contentsOf: largest)
    }
}

private actor IconDataCache {
    private var storage: [String: Data] = [:]

    func data(for key: String) -> Data? { storage[key] }
    func insert(_ data: Data, for key: String) { storage[key] = data }
}
