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
        XCTAssertEqual(FailureClassifier.classify("Device is locked"), .requiresUserAction)
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

    func testNoAccountsTakesPriorityOverMissingProfiles() {
        let output = "error: No Accounts: Add a new account in Accounts settings.\nerror: No profiles for 'com.example' were found"
        XCTAssertEqual(FailureClassifier.classify(output), .fatal)
        XCTAssertTrue(FailureClassifier.diagnose(output)?.reason.contains("登录") == true)
    }

    func testSourceFailureHasActionableSourceSummary() {
        let output = "=== SOURCE SYNC ===\n源码版本检查失败：远端分支 origin/retired 不存在；请先在源码仓库选择 main 并同步。\n"
        let summary = FailureClassifier.diagnose(output)
        XCTAssertEqual(summary?.location, "源码")
        XCTAssertTrue(summary?.reason.contains("origin/retired") == true)
        XCTAssertTrue(summary?.reason.contains("main") == true)
    }

    func testDeviceActionsStopAutomaticRetryAndHaveChineseGuidance() {
        for output in ["device was still locked. error 10003", "has not been unlocked recently", "usage assertion requirements. error 4016", "device not paired"] {
            XCTAssertEqual(FailureClassifier.classify(output), .requiresUserAction)
            XCTAssertFalse(FailureClassifier.isTransientFailure(output))
            XCTAssertEqual(FailureClassifier.diagnose(output)?.location, "设备")
        }
        if case .stop = RetryPolicy(maxAttempts: 3, intervalSeconds: 1800).decision(afterAttempt: 1, failureClass: .requiresUserAction) {} else {
            XCTFail("设备需要用户操作时不能等待重试")
        }
        let mixed = "No profiles for 'com.example.demo' were found\nCoreDevice error 4016"
        XCTAssertEqual(FailureClassifier.classify(mixed), .fatal)
        XCTAssertEqual(FailureClassifier.diagnose(mixed)?.location, "签名")
    }

    func testCompilerErrorSummaryHasFileAndLine() {
        let summary = FailureClassifier.diagnose(
            "/Users/dev/Proj/ContentView.swift:42:7: error: cannot find 'foo' in scope"
        )
        XCTAssertEqual(summary?.location, "ContentView.swift:42")
    }

    func testNoAutomaticTargetHasDeviceSummaryBeforeAndAfterBuild() {
        for output in ["错误：未找到可用的目标设备", "自动选择未找到当前可用设备；产物已生成，未安装。"] {
            let summary = FailureClassifier.diagnose(output)
            XCTAssertEqual(summary?.location, "设备")
            XCTAssertTrue(summary?.reason.contains("解锁") == true)
        }
    }
}
