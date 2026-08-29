import XCTest
@testable import Resign

final class RetryPolicyTests: XCTestCase {
    func testDefaultSettingsProduceThreeAttemptsAndThirtyMinutes() {
        let policy = RetryPolicy(settings: AppSettings())
        XCTAssertEqual(policy.maxAttempts, 3)
        XCTAssertEqual(policy.intervalSeconds, 30 * 60)
    }

    func testDisabledRetryMeansSingleAttempt() {
        var settings = AppSettings()
        settings.enableRetry = false
        settings.maxRetries = 3
        let policy = RetryPolicy(settings: settings)
        XCTAssertEqual(policy.maxAttempts, 1)
    }

    func testRetryableFailuresRetryUntilExhausted() {
        let policy = RetryPolicy(maxAttempts: 3, intervalSeconds: 0)

        XCTAssertEqual(policy.decision(afterAttempt: 1, failureClass: .retryable), .retryAfter(seconds: 0))
        XCTAssertEqual(policy.decision(afterAttempt: 2, failureClass: .retryable), .retryAfter(seconds: 0))
        if case .stop = policy.decision(afterAttempt: 3, failureClass: .retryable) {
            // exhausted
        } else {
            XCTFail("第 3 次失败后应停止")
        }
    }

    func testFatalFailuresNeverRetry() {
        let policy = RetryPolicy(maxAttempts: 4, intervalSeconds: 0)
        if case .stop = policy.decision(afterAttempt: 1, failureClass: .fatal) {
        } else {
            XCTFail("fatal 不应重试")
        }
    }

    func testUnknownFailuresNeverRetry() {
        let policy = RetryPolicy(maxAttempts: 4, intervalSeconds: 0)
        if case .stop = policy.decision(afterAttempt: 1, failureClass: .unknown) {
        } else {
            XCTFail("unknown 不应自动重试")
        }
    }

    func testRawInitKeepsAtLeastOneAttempt() {
        XCTAssertEqual(RetryPolicy(maxAttempts: 0, intervalSeconds: 0).maxAttempts, 1)
    }
}
