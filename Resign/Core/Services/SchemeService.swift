import Foundation

/// Shared schemes of an Xcode project/workspace.
struct SchemeService: Sendable {
    let runner: ProcessRunning

    func listSchemes(projectPath: String, xcodePath: String) async -> [String] {
        guard XcodeToolchain.validate(xcodePath: xcodePath) == nil else { return [] }
        let isWorkspace = projectPath.hasSuffix(".xcworkspace")
        let flag = isWorkspace ? "-workspace" : "-project"
        let result = await runner.run(
            XcodeToolchain.xcodebuildPath(xcodePath: xcodePath),
            arguments: [flag, projectPath, "-list", "-json"],
            environment: XcodeToolchain.environment(xcodePath: xcodePath)
        )
        guard result.exitCode == 0 else { return [] }

        if let data = result.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let project = json["project"] as? [String: Any] ?? json["workspace"] as? [String: Any],
           let schemes = project["schemes"] as? [String] {
            return schemes.filter { !$0.localizedCaseInsensitiveContains("Tests") }
        }
        return Self.parseSchemesPlainText(result.stdout)
    }

    static func parseSchemesPlainText(_ output: String) -> [String] {
        var schemes: [String] = []
        var inSchemes = false
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "Schemes:" { inSchemes = true; continue }
            if inSchemes {
                if trimmed.isEmpty { break }
                if !trimmed.localizedCaseInsensitiveContains("Tests") {
                    schemes.append(trimmed)
                }
            }
        }
        return schemes
    }
}
