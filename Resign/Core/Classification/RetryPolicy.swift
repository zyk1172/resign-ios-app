import Foundation

/// The single retry decision maker for both build and install attempts.
/// retryable → may retry; fatal → never; unknown → never (waiting on an
/// unrecognized failure just burns hours).
struct RetryPolicy: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        case retryAfter(seconds: Int)
        case stop(reason: String)
    }

    /// Total attempts including the first one.
    let maxAttempts: Int
    let intervalSeconds: Int

    /// Raw initializer for tests and internal use — no clamping.
    init(maxAttempts: Int, intervalSeconds: Int) {
        self.maxAttempts = max(1, maxAttempts)
        self.intervalSeconds = max(0, intervalSeconds)
    }

    /// User-settings driven initializer with the shipped bounds.
    init(settings: AppSettings) {
        let retries = min(max(settings.maxRetries, 0), 3)
        self.init(
            maxAttempts: settings.enableRetry ? 1 + retries : 1,
            intervalSeconds: min(max(settings.retryIntervalMinutes, 1), 120) * 60
        )
    }

    /// Decision after the given 1-based attempt has failed.
    func decision(afterAttempt attempt: Int, failureClass: FailureClass) -> Decision {
        switch failureClass {
        case .fatal:
            return .stop(reason: "失败原因为确定性问题（签名/Profile/账号配置），重试不会成功，已停止重试。")
        case .unknown:
            return .stop(reason: "失败原因无法识别，为安全起见不再自动重试；请检查日志后手动重试。")
        case .retryable:
            guard attempt < maxAttempts else {
                return .stop(reason: "已达最大尝试次数（\(maxAttempts) 次）。")
            }
            return .retryAfter(seconds: intervalSeconds)
        }
    }
}
