import Foundation

struct DeviceInstallOutcome: Sendable {
    let udid: String
    let success: Bool
    let attempts: Int
    let output: String
    var deviceName: String? = nil
    var failureReason: String? = nil
}

/// Complete one pass across all targets before waiting to retry failures.
/// Every attempt re-discovers the named device; explicit targets never change.
struct AppInstaller: Sendable {
    let runner: ProcessRunning
    var deviceDiscovery: DeviceDiscovering? = nil
    var timeout: TimeInterval = 120

    func install(
        appPath: String, deviceUDIDs: [String], xcodePath: String, retry: RetryPolicy,
        onProgress: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> [DeviceInstallOutcome] {
        let discovery = deviceDiscovery ?? DeviceService(runner: runner)
        var seen = Set<String>()
        let targets = deviceUDIDs.filter { seen.insert($0).inserted }
        var outcomes = targets.map { DeviceInstallOutcome(udid: $0, success: false, attempts: 0, output: "") }
        var pending = Array(targets.indices)
        let interval = min(retry.intervalSeconds, 30)

        while !pending.isEmpty && !Task.isCancelled {
            var next: [Int] = []
            for index in pending {
                if Task.isCancelled { break }
                let previous = outcomes[index]
                let udid = targets[index]
                let availabilityStage = ExecutionStage("安装设备检查 → \(previous.deviceName ?? udid)", onProgress: onProgress)
                var output = previous.output + availabilityStage.startedLog
                let devices = await discovery.listDevices(xcodePath: xcodePath)
                output += availabilityStage.finish()
                if Task.isCancelled { break }
                let device = devices.first { $0.udid == udid }
                let name = device?.name ?? previous.deviceName ?? String(udid.prefix(8))
                guard device?.isAvailable == true else {
                    let reason = "目标设备「\(name)」当前不可用，请连接、解锁并信任此电脑后重试；未改用其他设备。"
                    outcomes[index] = DeviceInstallOutcome(
                        udid: udid, success: false, attempts: previous.attempts,
                        output: output + "\n设备待处理：\(reason)\n", deviceName: name, failureReason: reason
                    )
                    continue
                }
                let attempt = previous.attempts + 1
                let stage = ExecutionStage("安装 → \(name)（第 \(attempt) 次）", onProgress: onProgress)
                let result = await runner.run(
                    XcodeToolchain.xcrunPath,
                    arguments: ["devicectl", "device", "install", "app", "--device", udid, appPath],
                    environment: XcodeToolchain.environment(xcodePath: xcodePath), timeout: timeout
                )
                output += stage.startedLog
                    + "\n=== INSTALL \(attempt)/\(retry.maxAttempts) → \(udid) ===\n\(result.combined)\n"
                    + stage.finish()
                let issue = result.exitCode == 0 ? nil : FailureClassifier.diagnose(result.combined)?.reason
                if result.exitCode != 0 && !Task.isCancelled {
                    switch retry.decision(afterAttempt: attempt, failureClass: FailureClassifier.classify(result.combined)) {
                    case .retryAfter:
                        output += "\n本轮其他设备尝试完毕后，\(interval) 秒后仅重试该设备。\n"
                        next.append(index)
                    case .stop(let reason): output += "\n⚠️ \(reason)\n"
                    }
                }
                outcomes[index] = DeviceInstallOutcome(
                    udid: udid, success: result.exitCode == 0, attempts: attempt, output: output,
                    deviceName: name, failureReason: issue
                )
            }
            pending = next
            if !pending.isEmpty && !Task.isCancelled {
                onProgress("等待 \(interval) 秒后重试 \(pending.count) 台失败设备")
                do { try await Task.sleep(for: .seconds(interval)) }
                catch { break }
            }
        }
        return outcomes
    }
}
