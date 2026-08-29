import XCTest
@testable import Resign

final class FailureClassifierTests: XCTestCase {
    // MARK: - Classification

    func testDeterministicErrorsAreFatal() {
        let fatalOutputs = [
            "Failed to install embedded profile for com.example : 0xe8008012 (This provisioning profile cannot be installed on this device.)",
            "FunctionName = -[MIFreeProfileValidatedAppTracker _onQueue_addReferenceForApplicationIdentifier:bundle:error:]",
            "The maximum number of apps for free development profiles has been reached",
            "error: Failed Registering Bundle Identifier: The app identifier \"com.example\" cannot be registered to your development team because it is not available",
            "error: No Account for Team \"9KXSB4HR69\". Add a new account in Accounts settings",
            "error: No profiles for 'com.example' were found",
            "Developer Mode is disabled on this device",
            "The certificate has expired"
        ]
        for output in fatalOutputs {
            XCTAssertEqual(FailureClassifier.classify(output), .fatal, "应为 fatal：\(output)")
        }
    }

    func testTransientErrorsAreRetryable() {
        XCTAssertEqual(FailureClassifier.classify("The network connection was lost"), .retryable)
        XCTAssertEqual(FailureClassifier.classify("Device is locked"), .retryable)
        XCTAssertEqual(FailureClassifier.classify("Timed out waiting for device"), .retryable)
    }

    func testUnrecognizedErrorsAreUnknown() {
        XCTAssertEqual(FailureClassifier.classify("error: Example.swift:12: type mismatch"), .unknown)
        XCTAssertEqual(FailureClassifier.classify("random failure text"), .unknown)
    }

    func testSigningErrorsAreNotTransient() {
        XCTAssertFalse(FailureClassifier.isTransientFailure("error: no signing certificate found"))
        XCTAssertFalse(FailureClassifier.isTransientFailure("Example.swift:12: error: type mismatch"))
    }

    // MARK: - Diagnosis

    func testSigningErrorSummary() {
        let summary = FailureClassifier.diagnose("error: No signing certificate found")
        XCTAssertEqual(summary?.location, "签名")
    }

    func testProfileMissingDeviceErrorSummary() {
        let summary = FailureClassifier.diagnose(
            "Failed to install embedded profile for com.example : 0xe8008012 (This provisioning profile cannot be installed on this device.)"
        )
        XCTAssertEqual(summary?.location, "安装")
        XCTAssertTrue(summary?.reason.contains("不在当前 Team 的测试设备列表") == true)
    }

    func testFreeProfileQuotaErrorSummary() {
        let summary = FailureClassifier.diagnose(
            "FunctionName = -[MIFreeProfileValidatedAppTracker _onQueue_addReferenceForApplicationIdentifier:bundle:error:]\n无法安装此App。"
        )
        XCTAssertEqual(summary?.location, "安装")
        XCTAssertTrue(summary?.reason.contains("每台设备最多安装 3 个开发 App") == true)
    }

    func testBundleIDUnavailableErrorSummary() {
        let summary = FailureClassifier.diagnose(
            "error: Failed Registering Bundle Identifier: The app identifier \"com.example\" cannot be registered to your development team because it is not available."
        )
        XCTAssertEqual(summary?.location, "签名")
        XCTAssertTrue(summary?.reason.contains("已被另一个开发者账号注册") == true)
    }

    func testNoAccountForTeamErrorSummary() {
        let summary = FailureClassifier.diagnose(
            "error: No Account for Team \"9KXSB4HR69\". Add a new account in Accounts settings."
        )
        XCTAssertEqual(summary?.location, "签名")
        XCTAssertTrue(summary?.reason.contains("没有登录 Xcode") == true)
    }

    func testCompilerErrorSummaryHasFileAndLine() {
        let summary = FailureClassifier.diagnose(
            "/Users/dev/Proj/ContentView.swift:42:7: error: cannot find 'foo' in scope"
        )
        XCTAssertEqual(summary?.location, "ContentView.swift:42")
    }
}
