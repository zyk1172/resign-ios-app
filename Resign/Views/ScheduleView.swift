import SwiftUI

/// 调度页布局约定：
/// - 所有表单行使用统一的「90pt 右对齐标签列 + 控件列」网格（与编辑弹窗一致）；
/// - 每张卡片只承载一个语义分组，标题用 Label + AppStyle.cardTitleSize；
/// - 数值控件使用等宽数字 + 固定宽度标签，避免步进时行宽抖动；
/// - 开关右对齐（macOS 设置页惯例），说明文字统一用 caption/micro 层级。
struct ScheduleView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(spacing: AppStyle.listSpacing) {
                toolchainCard
                scheduleCard
                ExecutionDetailsView()
                optionsCard
                retryCard
                launchdCard
            }
            .padding(16)
        }
        .onChange(of: store.settings) { _, _ in store.save() }
        .onChange(of: store.settings.scheduleHour) { _, _ in store.refreshScheduleIfInstalled() }
        .onChange(of: store.settings.scheduleMinute) { _, _ in store.refreshScheduleIfInstalled() }
    }

    // MARK: - Xcode 工具链

    private var toolchainCard: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 12) {
            Label("Xcode 工具链", systemImage: "hammer")
                .font(.system(size: AppStyle.cardTitleSize, weight: .semibold))

            formRow("Xcode 路径") {
                TextField("/Applications/Xcode-beta.app", text: $store.settings.xcodePath)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                Button("选择") { chooseXcode() }
                    .controlSize(.regular)
            }
        }
        .card()
    }

    // MARK: - 定时计划

    private var scheduleCard: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 12) {
            Label("定时计划", systemImage: "calendar")
                .font(.system(size: AppStyle.cardTitleSize, weight: .semibold))

            formRow("执行间隔") {
                Stepper(value: $store.settings.resignIntervalDays, in: 1...7) {
                    stepperLabel("\(store.settings.resignIntervalDays) 天", width: 44)
                }
            }

            formRow("检查时间") {
                HStack(spacing: 6) {
                    Picker("", selection: $store.settings.scheduleHour) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(String(format: "%02d", h)).tag(h)
                        }
                    }
                    .frame(width: 64)
                    Text(":")
                        .font(.system(size: AppStyle.fieldSize, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Picker("", selection: $store.settings.scheduleMinute) {
                        ForEach([0, 15, 30, 45], id: \.self) { m in
                            Text(String(format: "%02d", m)).tag(m)
                        }
                    }
                    .frame(width: 64)
                }
            }

            Text("每天在设定时间检查；距上次成功安装达到间隔天数后逐项目执行。免费签名建议间隔 ≤ 6 天")
                .font(.system(size: AppStyle.captionSize))
                .foregroundStyle(.orange)
                .padding(.leading, AppStyle.formLabelWidth + 10)
        }
        .card()
    }

    // MARK: - 构建选项

    private var optionsCard: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 12) {
            Label("构建选项", systemImage: "gearshape")
                .font(.system(size: AppStyle.cardTitleSize, weight: .semibold))

            formRow("项目间隔") {
                HStack(spacing: 10) {
                    Stepper(value: $store.settings.buildCooldownSeconds, in: 0...60) {
                        stepperLabel("\(store.settings.buildCooldownSeconds) 秒", width: 44)
                    }
                    Text("每个项目完成后暂停，避免瞬时资源占用过高")
                        .font(.system(size: AppStyle.microSize))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            toggleRow("防止睡眠", value: \.preventSleep)
            toggleRow("完成通知", value: \.notifyOnComplete)
            toggleRow("自动装载", value: \.autoInstallSchedule)

            Text("自动装载：启动时校验并安装后台任务；修改项目或设置后同样自动同步")
                .font(.system(size: AppStyle.microSize))
                .foregroundStyle(.tertiary)
                .padding(.leading, AppStyle.formLabelWidth + 10)
        }
        .card()
    }

    // MARK: - 失败重试

    private var retryCard: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 12) {
            Label("失败重试", systemImage: "arrow.clockwise.circle")
                .font(.system(size: AppStyle.cardTitleSize, weight: .semibold))

            toggleRow("自动重试", value: \.enableRetry)

            if store.settings.enableRetry {
                Divider()

                formRow("重试次数") {
                    Stepper(value: $store.settings.maxRetries, in: 0...3) {
                        stepperLabel("\(store.settings.maxRetries) 次", width: 44)
                    }
                }

                formRow("重试间隔") {
                    Stepper(value: $store.settings.retryIntervalMinutes, in: 1...120) {
                        stepperLabel("\(store.settings.retryIntervalMinutes) 分钟", width: 64)
                    }
                }

                Text("仅临时性错误（设备掉线、超时等）会自动重试；签名/配额类确定性错误立即停止")
                    .font(.system(size: AppStyle.microSize))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, AppStyle.formLabelWidth + 10)
            }
        }
        .card()
    }

    // MARK: - 后台任务

    private var launchdCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("后台任务", systemImage: "clock.badge.checkmark")
                    .font(.system(size: AppStyle.cardTitleSize, weight: .semibold))
                Spacer()
                scheduleStatusBadge
            }

            HStack(spacing: 10) {
                Button {
                    store.save()
                    withAnimation(.snappy(duration: 0.3)) {
                        store.installSchedule()
                    }
                } label: {
                    Label("安装 / 更新", systemImage: "calendar.badge.plus")
                        .font(.system(size: AppStyle.captionSize, weight: .medium))
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    withAnimation(.snappy(duration: 0.3)) {
                        store.uninstallSchedule()
                    }
                } label: {
                    Label("卸载", systemImage: "calendar.badge.minus")
                        .font(.system(size: AppStyle.captionSize, weight: .medium))
                }
                .buttonStyle(.bordered)

                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Text(AppPaths.schedulePlistURL.path)
                    .font(.system(size: AppStyle.microSize, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(AppPaths.schedulePlistURL.path)
                Text("后台任务由 Resign.app 内置的 ResignWorker 执行，与手动执行共用同一构建引擎和配置")
                    .font(.system(size: AppStyle.microSize))
                    .foregroundStyle(.tertiary)
            }
        }
        .card()
    }

    // MARK: - Pieces

    private var scheduleStatusBadge: some View {
        let color: Color = store.isScheduleInstalled ? .green : .red
        return HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.4), radius: 2)
            Text(store.isScheduleInstalled ? "已装载" : "未装载")
                .font(.system(size: AppStyle.captionSize, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, AppStyle.badgeHPadding)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.08)))
    }

    /// 统一的「标签列 + 控件列」表单行。
    private func formRow(
        _ label: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: AppStyle.fieldSize))
                .foregroundStyle(.secondary)
                .frame(width: AppStyle.formLabelWidth, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }

    /// 右对齐的开关行。
    private func toggleRow(
        _ label: String,
        value keyPath: WritableKeyPath<AppSettings, Bool>
    ) -> some View {
        formRow(label) {
            HStack {
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { store.settings[keyPath: keyPath] },
                    set: { store.settings[keyPath: keyPath] = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
    }

    /// 等宽数字的固定宽度步进标签，避免数值变化时行宽抖动。
    private func stepperLabel(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .monospacedDigit()
            .font(.system(size: AppStyle.fieldSize, weight: .medium))
            .frame(width: width, alignment: .leading)
    }

    private func chooseXcode() {
        let panel = NSOpenPanel()
        panel.title = "选择 Xcode.app"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            store.settings.xcodePath = url.path
            store.save()
        }
    }
}
