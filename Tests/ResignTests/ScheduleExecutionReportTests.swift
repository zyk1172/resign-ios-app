import XCTest
@testable import Resign

final class ScheduleExecutionReportTests: XCTestCase {
    private let projectID = UUID()
    private let otherID = UUID()

    private var projects: [iOSProject] {
        var ios = iOSProject(id: projectID, name: "iOS App", projectPath: "/tmp/iOS.xcodeproj")
        ios.platform = .ios
        ios.deviceUDIDs = ["D1", "UNKNOWN"]

        var mac = iOSProject(id: otherID, name: "Mac App", projectPath: "/tmp/Mac.xcodeproj")
        mac.platform = .macos

        var disabled = iOSProject(id: UUID(), name: "Disabled", projectPath: "/tmp/Off.xcodeproj")
        disabled.isEnabled = false

        return [ios, mac, disabled]
    }

    private let devices: [iOSDevice] = [
        iOSDevice(udid: "D1", name: "iPhone 15", osVersion: "18.0", connectionType: "USB", isAvailable: true)
    ]

    func testPreviewsCoverEnabledProjectsWithTargetsAndDueState() {
        // iOS 项目 5 天前成功，间隔 6 天 → 未到期；Mac 项目从未成功 → 到期。
        let states: [ProjectExecutionState] = [
            ProjectExecutionState(
                projectID: projectID,
                lastAttemptDate: now(-5 * 86_400),
                lastSuccessfulInstallDate: now(-5 * 86_400)
            )
        ]

        let previews = ScheduleExecutionReport.previews(
            projects: projects,
            executionStates: states,
            devices: devices,
            intervalDays: 6,
            now: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )

        XCTAssertEqual(previews.count, 2, "停用项目不应出现在预览中")
        XCTAssertEqual(previews[0].name, "iOS App")
        XCTAssertEqual(previews[0].platform, .ios)
        XCTAssertFalse(previews[0].due)
        XCTAssertEqual(previews[0].targetDescription, "iPhone 15、UNKNOWN", "已知 UDID 显示设备名，未知显示短 UDID")
        XCTAssertNotNil(previews[0].lastSuccessfulInstallDate)

        XCTAssertEqual(previews[1].name, "Mac App")
        XCTAssertEqual(previews[1].platform, .macos)
        XCTAssertTrue(previews[1].due, "从未成功的项目必须到期")
        XCTAssertNil(previews[1].lastSuccessfulInstallDate)
        XCTAssertEqual(previews[1].targetDescription, "本机 /Applications")
    }

    func testAutoSelectDescriptionWhenNoExplicitDevices() {
        var auto = iOSProject(id: UUID(), name: "Auto", projectPath: "/tmp/Auto.xcodeproj")
        auto.platform = .ios
        auto.deviceUDIDs = []

        let previews = ScheduleExecutionReport.previews(
            projects: [auto],
            executionStates: [],
            devices: devices,
            intervalDays: 6
        )

        XCTAssertEqual(previews.first?.targetDescription, "自动选择第一台可用设备")
    }

    private func now(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: 800_000_000 + offset)
    }
}
