import Foundation

/// Resolves the main .app product of a build.
///
/// Safety policy (the ONLY policy — used by both GUI and scheduled worker):
/// - only `.app` wrappers qualify (frameworks/app extensions/tests never match);
/// - the main app is identified by matching the scheme or project name against
///   the target name or the wrapper base name;
/// - without a name match, a single unambiguous candidate is accepted;
/// - otherwise resolution FAILS — an uncertain product is never installed.
enum ProductResolver {
    struct Candidate: Equatable, Sendable {
        let targetName: String
        let wrapperName: String
        let path: String
    }

    /// Extracts .app candidates from `xcodebuild -showBuildSettings -json` output.
    static func candidates(fromBuildSettingsJSON data: Data) -> [Candidate] {
        guard let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return targets.compactMap { target in
            guard let settings = target["buildSettings"] as? [String: Any],
                  let buildDirectory = settings["TARGET_BUILD_DIR"] as? String,
                  let wrapperName = settings["WRAPPER_NAME"] as? String,
                  wrapperName.hasSuffix(".app")
            else { return nil }
            return Candidate(
                targetName: target["target"] as? String ?? "",
                wrapperName: wrapperName,
                path: URL(fileURLWithPath: buildDirectory).appendingPathComponent(wrapperName).path
            )
        }
    }

    static func select(from candidates: [Candidate], preferredNames: [String]) -> Candidate? {
        for preferredName in preferredNames {
            if let match = candidates.first(where: { isMatch($0, preferredName) }) {
                return match
            }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    static func expectedProductPath(fromBuildSettingsJSON data: Data, preferredNames: [String]) -> String? {
        select(from: candidates(fromBuildSettingsJSON: data), preferredNames: preferredNames)?.path
    }

    /// Fallback: scans the configuration products directory on disk.
    static func mainApp(in directory: URL, preferredNames: [String]) -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let apps = files.filter { $0.pathExtension == "app" }
        for preferredName in preferredNames {
            if let match = apps.first(where: {
                $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(preferredName) == .orderedSame
            }) {
                return match.path
            }
        }
        return apps.count == 1 ? apps[0].path : nil
    }

    private static func isMatch(_ candidate: Candidate, _ preferredName: String) -> Bool {
        candidate.targetName.caseInsensitiveCompare(preferredName) == .orderedSame
            || URL(fileURLWithPath: candidate.wrapperName)
                .deletingPathExtension().lastPathComponent
                .caseInsensitiveCompare(preferredName) == .orderedSame
    }
}
