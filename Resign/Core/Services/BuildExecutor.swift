import Foundation

/// Runs `xcodebuild` (single invocations only; retry decisions belong to
/// RetryPolicy / BuildCoordinator).
struct BuildExecutor: Sendable {
    let runner: ProcessRunning

    /// Common xcodebuild arguments for one project. Team is injected through
    /// DEVELOPMENT_TEAM so automatic signing uses the user-selected team.
    static func baseArguments(for project: iOSProject, derivedDataPath: String) -> [String] {
        var arguments = [
            project.projectFlag, project.projectPath,
            "-scheme", project.scheme,
            "-configuration", project.configuration,
            "-destination", "generic/platform=iOS",
            "-derivedDataPath", derivedDataPath,
            "-allowProvisioningUpdates",
            "CODE_SIGN_STYLE=Automatic"
        ]
        if let teamID = project.teamID, !teamID.isEmpty {
            arguments += ["DEVELOPMENT_TEAM=\(teamID)"]
        }
        return arguments
    }

    func showBuildSettings(arguments: [String], xcodePath: String) async -> ProcessResult {
        await runner.run(
            XcodeToolchain.xcodebuildPath(xcodePath: xcodePath),
            arguments: arguments + ["-showBuildSettings", "-json"],
            environment: XcodeToolchain.environment(xcodePath: xcodePath)
        )
    }

    func build(arguments: [String], xcodePath: String) async -> ProcessResult {
        await runner.run(
            XcodeToolchain.xcodebuildPath(xcodePath: xcodePath),
            arguments: arguments + ["build"],
            environment: XcodeToolchain.environment(xcodePath: xcodePath)
        )
    }
}
