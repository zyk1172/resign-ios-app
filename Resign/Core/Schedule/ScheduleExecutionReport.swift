import Foundation

/// 汇总"下次定时检查将执行什么"，供调度页的执行明细面板展示：
/// 每个启用项目的到期状态与安装目标，让用户可以在执行前核实
/// 定时任务的设备/App 选择是否符合预期。
enum ScheduleExecutionReport {
    struct ProjectPreview: Equatable, Sendable {
        var name: String
        var platform: ProjectPlatform
        var due: Bool
        var lastSuccessfulInstallDate: Date?
        var targetDescription: String
    }

    static func previews(
        projects: [iOSProject],
        executionStates: [ProjectExecutionState],
        devices: [iOSDevice],
        intervalDays: Int,
        now: Date = Date()
    ) -> [ProjectPreview] {
        projects
            .filter { $0.isEnabled && !$0.projectPath.isEmpty }
            .map { project in
                let lastSuccess = executionStates
                    .first { $0.projectID == project.id }?
                    .lastSuccessfulInstallDate
                let due = ScheduleDuePolicy.isDue(
                    lastSuccessfulInstallDate: lastSuccess,
                    intervalDays: intervalDays,
                    now: now
                )
                return ProjectPreview(
                    name: project.name,
                    platform: project.platform,
                    due: due,
                    lastSuccessfulInstallDate: lastSuccess,
                    targetDescription: targetDescription(for: project, devices: devices)
                )
            }
    }

    private static func targetDescription(for project: iOSProject, devices: [iOSDevice]) -> String {
        switch project.platform {
        case .macos:
            return "本机 /Applications"
        case .ios:
            if project.deviceUDIDs.isEmpty {
                return "自动选择第一台可用设备"
            }
            return project.deviceUDIDs
                .map { udid in devices.first { $0.udid == udid }?.name ?? String(udid.prefix(8)) }
                .joined(separator: "、")
        }
    }
}
