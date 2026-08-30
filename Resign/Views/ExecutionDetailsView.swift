import SwiftUI

/// 调度页「执行明细」卡片：下次定时执行预览 + 最近定时执行记录，
/// 用于核实定时任务的项目、设备与产物。
struct ExecutionDetailsView: View {
    @Environment(AppStore.self) private var store

    private var upcomingPreviews: [ScheduleExecutionReport.ProjectPreview] {
        ScheduleExecutionReport.previews(
            projects: store.projects,
            executionStates: store.executionStates,
            devices: store.devices,
            intervalDays: store.settings.resignIntervalDays
        )
    }

    private var recentScheduledRuns: [BuildLogEntry] {
        let scheduled = store.logs.filter { entry in entry.source == .scheduled }
        return Array(scheduled.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("执行明细", systemImage: "list.bullet.rectangle")
                .font(.system(size: AppStyle.cardTitleSize, weight: .semibold))

            subHeader("下次定时检查将执行")
            if upcomingPreviews.isEmpty {
                emptyHint("没有已启用的项目")
            } else {
                VStack(spacing: 8) {
                    ForEach(upcomingPreviews) { preview in
                        DuePreviewRow(preview: preview)
                    }
                }
            }

            Divider()

            subHeader("最近定时执行记录")
            if recentScheduledRuns.isEmpty {
                emptyHint("暂无定时执行记录（定时任务首次运行后显示在这里）")
            } else {
                VStack(spacing: 10) {
                    ForEach(recentScheduledRuns) { entry in
                        ScheduledRunRow(entry: entry)
                    }
                }
            }
        }
        .card()
    }

    private func subHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppStyle.captionSize, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppStyle.captionSize))
            .foregroundStyle(.tertiary)
            .padding(.leading, AppStyle.formLabelWidth + 10)
    }
}

// MARK: - 到期预览行

struct DuePreviewRow: View {
    let preview: ScheduleExecutionReport.ProjectPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(preview.name)
                    .font(.system(size: AppStyle.listTitleSize, weight: .semibold))
                    .lineLimit(1)
                dueBadge
                Spacer()
                lastSuccessText
            }
            HStack(spacing: 4) {
                Image(systemName: preview.platform == .macos ? "desktopcomputer" : "iphone")
                    .font(.system(size: 9))
                Text("目标：\(preview.targetDescription)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    /// 到期状态徽章：从未成功 → 首次执行（蓝）；已到期 → 已到期（橙）；否则未到期（灰）。
    private var dueBadge: some View {
        let text: String
        let color: Color
        if preview.lastSuccessfulInstallDate == nil {
            text = "首次执行"
            color = .blue
        } else if preview.due {
            text = "已到期"
            color = .orange
        } else {
            text = "未到期"
            color = .gray
        }
        return Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, AppStyle.badgeHPadding - 2)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.12)))
            .foregroundStyle(color)
    }

    @ViewBuilder
    private var lastSuccessText: some View {
        if let date = preview.lastSuccessfulInstallDate {
            let relative: String = date.formatted(.relative(presentation: .named))
            Text("上次成功 \(relative)")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        } else {
            Text("从未成功安装")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - 最近定时执行行

struct ScheduledRunRow: View {
    let entry: BuildLogEntry

    private static let runTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            header
            detailLine
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.gray.opacity(0.04))
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.status.symbolName)
                .font(.system(size: 11))
                .foregroundStyle(statusColor)
            Text(entry.projectName)
                .font(.system(size: AppStyle.listTitleSize, weight: .semibold))
                .lineLimit(1)
            if let mode = entry.buildMode {
                Text(mode.label)
                    .font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(modeColor.opacity(0.10)))
                    .foregroundStyle(modeColor)
            }
            Spacer()
            Text(Self.runTimeFormatter.string(from: entry.date))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    /// 产物 + 逐设备结果行。新日志带结构化摘要；旧版日志回退为失败设备列表。
    private var detailLine: some View {
        HStack(spacing: 5) {
            appLabel
            deviceOutcomes
            Spacer(minLength: 0)
        }
    }

    private var appLabel: some View {
        Group {
            if let appPath = entry.builtAppPath {
                Text(appName)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(appPath)
            }
        }
    }

    @ViewBuilder
    private var deviceOutcomes: some View {
        if let summaries = entry.deviceInstallSummaries, !summaries.isEmpty {
            ForEach(summaries, id: \.udid) { summary in
                chip(name: summary.deviceName, success: summary.success, attempts: summary.attempts)
            }
        } else if let failed = entry.failedDevices, !failed.isEmpty {
            ForEach(failed, id: \.self) { name in
                chip(name: name, success: false, attempts: nil)
            }
            Text("（成功设备未记录）")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        } else if entry.builtAppPath == nil {
            Text("设备与产物明细未记录（旧版日志）")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .success: return .green
        case .failed: return .red
        case .running: return .blue
        case .cancelled: return .gray
        }
    }

    private var modeColor: Color {
        guard let mode = entry.buildMode else { return .gray }
        switch mode {
        case .full: return .blue
        case .incremental: return .green
        case .cached: return .teal
        }
    }

    private var appName: String {
        guard let appPath = entry.builtAppPath else { return "" }
        return URL(fileURLWithPath: appPath).lastPathComponent
    }

    private func chip(name: String, success: Bool, attempts: Int?) -> some View {
        let color: Color = success ? .green : .red
        return HStack(spacing: 3) {
            Image(systemName: success ? "checkmark" : "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(color)
            Text(name)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let attempts = attempts, attempts > 1 {
                Text("×\(attempts)")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.08)))
        .help(success ? "安装成功" : "安装失败")
    }
}
