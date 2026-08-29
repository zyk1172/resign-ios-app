import Foundation

/// ResignWorker entry point. The LaunchAgent runs:
///   ResignWorker --scheduled-run
/// The worker reads the same config.json as the GUI and drives the SAME
/// BuildCoordinator — no build logic is duplicated here.
@main
struct ResignWorkerMain {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.contains("--scheduled-run") else {
            FileHandle.standardError.write(Data("ResignWorker: unsupported invocation. Use --scheduled-run.\n".utf8))
            exit(2)
        }

        let coordinator = ScheduledRunCoordinator(
            configDirectory: AppPaths.configDirectory,
            runner: FoundationProcessRunner()
        )
        let exitCode = await coordinator.run()
        exit(exitCode)
    }
}
