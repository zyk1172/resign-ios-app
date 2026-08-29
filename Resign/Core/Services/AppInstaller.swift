import Foundation

/// Per-device install result. `output` carries the raw devicectl transcripts so
/// the coordinator can assemble one complete run log.
struct DeviceInstallOutcome: Sendable {
    let udid: String
    let success: Bool
    let output: String
}

/// Installs a built .app onto devices via `devicectl`. Each device is tracked
/// independently: a device that succeeded is never reinstalled, and a device
/// with a deterministic failure stops retrying immediately.
struct AppInstaller: Sendable {
    let runner: ProcessRunning

    func install(
        appPath: String,
        deviceUDIDs: [String],
        xcodePath: String,
        retry: RetryPolicy
    ) async -> [DeviceInstallOutcome] {
        var outcomes: [DeviceInstallOutcome] = []
        for udid in deviceUDIDs {
            outcomes.append(await install(appPath: appPath, udid: udid, xcodePath: xcodePath, retry: retry))
        }
        return outcomes
    }

    private func install(
        appPath: String,
        udid: String,
        xcodePath: String,
        retry: RetryPolicy
    ) async -> DeviceInstallOutcome {
        var output = ""
        var installed = false

        deviceLoop: for attempt in 1...retry.maxAttempts {
            if Task.isCancelled {
                output += "\n任务已取消"
                break
            }
            let result = await runner.run(
                XcodeToolchain.xcrunPath,
                arguments: ["devicectl", "device", "install", "app", "--device", udid, appPath],
                environment: XcodeToolchain.environment(xcodePath: xcodePath)
            )
            output += "\n=== INSTALL \(attempt)/\(retry.maxAttempts) → \(udid) ===\n\(result.combined)\n"

            if result.exitCode == 0 {
                installed = true
                break
            }

            switch retry.decision(afterAttempt: attempt, failureClass: FailureClassifier.classify(result.combined)) {
            case .retryAfter(let seconds):
                output += "\n安装失败，\(seconds) 秒后重试。\n"
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    output += "\n任务已取消"
                    break deviceLoop
                }
            case .stop(let reason):
                output += "\n⚠️ \(reason)\n"
                break deviceLoop
            }
        }

        return DeviceInstallOutcome(udid: udid, success: installed, output: output)
    }
}
