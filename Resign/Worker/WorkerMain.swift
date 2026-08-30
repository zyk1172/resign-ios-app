import Foundation

/// ResignWorker entry point. The LaunchAgent runs:
///   ResignWorker --scheduled-run
/// The worker reads the same config.json as the GUI and drives the SAME
/// BuildCoordinator — no build logic is duplicated here.
///
/// Exit codes: 0 = 正常（含无到期项目）；1 = 构建/安装失败；
/// 2 = 无效调用；3 = 配置读取失败；4 = 执行结果落盘失败。
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
