import Foundation

/// Classification of a build/install failure for retry decisions.
/// Both the GUI and the scheduled worker route every failure through here,
/// so the same error always produces the same retry behaviour and diagnosis.
enum FailureClass: Equatable, Sendable {
    /// Temporary (device offline, network hiccup) - retrying may help.
    case retryable
    /// Requires connection, unlock or trust; waiting alone will not fix it.
    case requiresUserAction
    /// Deterministic (profile missing device, quota full, bundle id taken) - retrying is pointless.
    case fatal
    /// Not recognized - conservative default that does NOT retry.
    case unknown
}

enum FailureClassifier {
    static let transientMarkers = [
        "timed out", "timeout", "temporarily unavailable",
        "device unavailable", "lost connection", "connection interrupted",
        "could not connect", "developer disk image", "network connection was lost",
    ]

    static let fatalMarkers = [
        "0xe8008012",
        "provisioning profile cannot be installed on this device",
        "doesn't include the currently connected device",
        "is not included in the provisioning profile",
        "mifreeprofilevalidatedapptracker",
        "maximum number of apps for free development profiles",
        "failed registering bundle identifier",
        "cannot be registered to your development team",
        "no account for team",
        "no accounts: add a new account",
        "no profiles for",
        "developer mode is disabled",
        "developer mode has not been enabled",
        "certificate has expired",
        "certificate expired",
        "xcode license",
        "not enough space",
        "disk full"
    ]

    static func isTransientFailure(_ output: String) -> Bool {
        guard deviceActionReason(output) == nil else { return false }
        let text = output.lowercased()
        return transientMarkers.contains { text.contains($0) }
    }

    static func classify(_ output: String) -> FailureClass {
        let text = output.lowercased()
        if fatalMarkers.contains(where: { text.contains($0) }) {
            return .fatal
        }
        if deviceActionReason(output) != nil { return .requiresUserAction }
        if isTransientFailure(output) {
            return .retryable
        }
        return .unknown
    }

    /// Maps a raw build/install output to a concise, actionable "where + why"
    /// diagnosis (in Chinese, actionable steps included where known).
    static func diagnose(_ output: String) -> BuildErrorSummary? {
        let text = output.lowercased()
        let lines = output.components(separatedBy: .newlines)

        if let failure = lines.first(where: { $0.contains("源码版本检查失败：") }) {
            return BuildErrorSummary(
                location: "源码",
                reason: failure.replacingOccurrences(of: "源码版本检查失败：", with: "")
            )
        }

        // Keep deterministic signing/account failures ahead of secondary
        // device or timeout messages, matching the retry classification.
        if let known = knownFailureSummary(text) { return known }
        if let reason = deviceActionReason(output) {
            return BuildErrorSummary(location: "设备", reason: reason)
        }
        if text.contains("process timed out after") {
            return BuildErrorSummary(location: "执行超时", reason: "外部命令超过设定时限，已终止本次命令及其进程组；请检查设备连接和阶段日志。")
        }

        // 1. First meaningful "error:" line (xcodebuild / clang / swiftc)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let r = line.range(of: "error:", options: .caseInsensitive) else { continue }
            let before = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let reason = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)

            // Skip generic summary lines that carry no detail
            let low = reason.lowercased()
            if reason.isEmpty || low.hasPrefix("build commands failed") || low.hasPrefix("build failed") {
                continue
            }

            // Signing / provisioning problems
            if isSigningRelated(reason) {
                return BuildErrorSummary(location: "签名", reason: reason)
            }

            // Compiler error with a file path (optionally :line:col)
            if !before.isEmpty, before.contains("/") {
                let segs = before.components(separatedBy: ":")
                let filename = URL(fileURLWithPath: segs[0]).lastPathComponent
                if segs.count >= 2, !segs[1].isEmpty, segs[1].allSatisfy({ $0.isNumber }) {
                    return BuildErrorSummary(location: "\(filename):\(segs[1])", reason: reason)
                }
                return BuildErrorSummary(location: filename, reason: reason)
            }

            // No path info — fall back to the failing phase
            return BuildErrorSummary(location: phase(of: output), reason: reason)
        }

        // 2. devicectl / install failures that don't use the "error:" prefix
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.contains("Failed to install") || line.contains("install app failed") {
                return BuildErrorSummary(location: "安装", reason: line)
            }
        }

        // 3. Last resort
        if output.contains("未找到已连接设备") || output.contains("未找到可用的目标设备")
            || output.contains("自动选择未找到当前可用设备") {
            return BuildErrorSummary(location: "设备", reason: "未找到当前可用的目标设备，请连接、解锁设备并确认已信任此电脑后重试")
        }
        if output.contains("未找到 .app 产物") {
            return BuildErrorSummary(location: "构建", reason: "未找到 .app 产物，请检查 Scheme 与 Configuration 配置")
        }

        return nil
    }

    static func deviceActionReason(_ output: String) -> String? {
        let text = output.lowercased()
        if text.contains("device is locked") || text.contains("device was still locked")
            || text.contains("has not been unlocked recently") || text.contains("error 10003") {
            return "设备已锁定或长时间未解锁，请先解锁设备，再重新安装；不会长时间等待重试。"
        }
        if text.contains("error 4016") || text.contains("usage assertion requirements") {
            return "设备连接或 CoreDevice 服务尚未就绪，请连接、解锁设备并确认 Xcode 中可用后重试。"
        }
        if text.contains("is not paired") || text.contains("device not paired") || text.contains("trust this computer") {
            return "设备尚未配对或信任此电脑，请在设备上完成信任并确认 Xcode 中可用后重试。"
        }
        return nil
    }

    private static func isSigningRelated(_ reason: String) -> Bool {
        let keywords = ["signing certificate", "provisioning profile", "no profile for team",
                        "code signing", "requires a development team", "signing"]
        let low = reason.lowercased()
        return keywords.contains { low.contains($0) }
    }

    private static func phase(of output: String) -> String {
        if output.contains("=== INSTALL") { return "安装" }
        return "构建"
    }

    /// Maps the deterministic failure modes that occur with free Apple
    /// developer accounts to a concise, actionable diagnosis.
    private static func knownFailureSummary(_ text: String) -> BuildErrorSummary? {
        // Device is not in the current team's provisioning profile.
        if text.contains("0xe8008012")
            || text.contains("provisioning profile cannot be installed on this device")
            || text.contains("doesn't include the currently connected device")
            || text.contains("is not included in the provisioning profile") {
            return BuildErrorSummary(
                location: "安装",
                reason: "这台设备的 UDID 不在当前 Team 的测试设备列表里。请在 Xcode 中连接该设备并选它运行一次（会自动注册），或到 Xcode → Settings → Accounts 确认设备已加入该 Apple ID。"
            )
        }

        // Free-development-profile app quota reached on this device.
        if text.contains("mifreeprofilevalidatedapptracker")
            || text.contains("maximum number of apps for free development profiles") {
            return BuildErrorSummary(
                location: "安装",
                reason: "免费 Personal Team 每台设备最多安装 3 个开发 App；带有 App 扩展的项目还会额外消耗 App ID / provisioning 资源。请先卸载该设备上的一个免费签名 App，或改用付费开发者账号（Apple Developer Program，$99/年）。"
            )
        }

        // Bundle identifier already registered by another team / unavailable.
        if text.contains("failed registering bundle identifier")
            || (text.contains("cannot be registered to your development team") && text.contains("not available")) {
            return BuildErrorSummary(
                location: "签名",
                reason: "这个 Bundle ID 已被另一个开发者账号注册，当前 Team 无法注册它。请把项目的 Team 改回注册过该 Bundle ID 的账号，或修改 Bundle ID。"
            )
        }

        // Team's Apple ID is not signed into Xcode.
        if text.contains("no account for team") || text.contains("no accounts: add a new account") {
            return BuildErrorSummary(
                location: "签名",
                reason: "当前 Team 对应的 Apple ID 没有登录 Xcode。请到 Xcode → Settings → Accounts 登录该账号后重试。"
            )
        }

        // No matching provisioning profile for the bundle id / team.
        if text.contains("no profiles for") {
            return BuildErrorSummary(
                location: "签名",
                reason: "没有找到匹配的 Provisioning Profile。通常是该 Team 下没有对应 Bundle ID 的 App ID，或证书/设备不匹配；可在 Xcode 中打开项目让其自动生成。"
            )
        }

        // Developer mode is disabled on the device (iOS 16+).
        if text.contains("developer mode is disabled")
            || text.contains("developer mode has not been enabled")
            || text.contains("enable developer mode") {
            return BuildErrorSummary(
                location: "安装",
                reason: "这台设备的开发者模式未开启。请到 设置 → 隐私与安全性 → 开发者模式 开启（需要重启设备），然后再试。"
            )
        }

        // Signing certificate expired.
        if text.contains("certificate has expired")
            || text.contains("certificate expired")
            || (text.contains("has expired") && text.contains("certificate")) {
            return BuildErrorSummary(
                location: "签名",
                reason: "签名证书已过期。请在 Xcode → Settings → Accounts 中刷新或重新生成证书后重试。"
            )
        }

        // Xcode license not accepted / first-launch components missing.
        if text.contains("xcode license")
            || text.contains("agree to the license")
            || text.contains("license agreement") {
            return BuildErrorSummary(
                location: "构建",
                reason: "Xcode 许可协议尚未接受或需要刷新。请打开 Xcode 接受许可协议后重试。"
            )
        }

        // Disk full.
        if text.contains("not enough space")
            || text.contains("disk full")
            || text.contains("no space left") {
            return BuildErrorSummary(
                location: "构建",
                reason: "磁盘空间不足，无法完成构建。请清理磁盘空间后重试。"
            )
        }

        return nil
    }
}
