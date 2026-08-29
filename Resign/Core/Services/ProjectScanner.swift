import Foundation

/// Filesystem scanning for Xcode projects.
enum ProjectScanner {
    static let skippedDirectories: Set<String> = [
        "Pods", "DerivedData", "Carthage", "build", ".build", "node_modules", ".git", "fastlane", ".swiftpm"
    ]

    static func scan(in folder: URL) -> [URL] {
        var results: [URL] = []
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return results }

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") {
                if url.deletingLastPathComponent().pathExtension == "xcodeproj" {
                    // Skip nested project files inside .xcodeproj bundles.
                    enumerator.skipDescendants()
                    continue
                }
                results.append(url)
                enumerator.skipDescendants()
            } else {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory && skippedDirectories.contains(name) {
                    enumerator.skipDescendants()
                }
            }
        }
        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
