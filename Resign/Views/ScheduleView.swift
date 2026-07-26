import SwiftUI

struct ScheduleView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store

        ScrollView {
            VStack(spacing: 14) {
                // Xcode Path Card
                VStack(alignment: .leading, spacing: 10) {
                    Label("Xcode 路径", systemImage: "hammer")
                        .font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 8) {
                        TextField("/Applications/Xcode-beta.app", text: $store.settings.xcodePath)
                            .font(.system(size: 12, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                        Button("选择") { chooseXcode() }
                            .controlSize(.regular)
                    }
                }
                .card()

                // Schedule Card
                VStack(alignment: .leading, spacing: 12) {
                    Label("定时计划", systemImage: "calendar")
                        .font(.system(size: 13, weight: .semibold))

                    HStack(spacing: 16) {
                        HStack(spacing: 6) {
                            Text("间隔")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Stepper("\(store.settings.resignIntervalDays) 天",
                                    value: $store.settings.resignIntervalDays, in: 1...7)
                        }
                        HStack(spacing: 6) {
                            Text("时间")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Picker("", selection: $store.settings.scheduleHour) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(String(format: "%02d", h)).tag(h)
                                }
                            }
                            .frame(width: 60)
                            Text(":")
                            Picker("", selection: $store.settings.scheduleMinute) {
                                ForEach([0, 15, 30, 45], id: \.self) { m in
                                    Text(String(format: "%02d", m)).tag(m)
                                }
                            }
                            .frame(width: 60)
                        }
                    }

                    HStack(spacing: 6) {
                        Text("项目间隔")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Stepper("\(store.settings.buildCooldownSeconds) 秒",
                                value: $store.settings.buildCooldownSeconds, in: 0...60)
                        Text("每个项目构建完成后暂停，避免瞬时资源占用过高")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    Text("每天在设定时间检查；距离上次成功达到间隔天数后才执行。免费签名建议 ≤ 6 天")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                .card()

                // Options Card
                VStack(alignment: .leading, spacing: 10) {
                    Label("选项", systemImage: "gearshape")
                        .font(.system(size: 13, weight: .semibold))
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("防止构建时睡眠", isOn: $store.settings.preventSleep)
                        Toggle("完成后通知", isOn: $store.settings.notifyOnComplete)
                        Toggle("启动时自动装载任务", isOn: $store.settings.autoInstallSchedule)
                    }
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
                }
                .card()

                // Retry Card
                VStack(alignment: .leading, spacing: 10) {
                    Label("失败重试", systemImage: "arrow.clockwise.circle")
                        .font(.system(size: 13, weight: .semibold))
                    Toggle("构建失败时自动重试", isOn: $store.settings.enableRetry)
                        .toggleStyle(.switch)
                        .font(.system(size: 12))
                    if store.settings.enableRetry {
                        HStack(spacing: 16) {
                            HStack(spacing: 6) {
                                Text("次数")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Stepper("\(store.settings.maxRetries) 次",
                                        value: $store.settings.maxRetries, in: 0...3)
                            }
                            HStack(spacing: 6) {
                                Text("间隔")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Stepper("\(store.settings.retryIntervalMinutes) 分钟",
                                        value: $store.settings.retryIntervalMinutes, in: 1...120)
                            }
                        }
                        Text("最多重试 \(store.settings.maxRetries) 次，每次间隔 \(store.settings.retryIntervalMinutes) 分钟")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .card()

                // Launchd Card
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("launchd 任务", systemImage: "clock.badge.checkmark")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        HStack(spacing: 5) {
                            Circle()
                                .fill(store.isScheduleInstalled ? .green : .red)
                                .frame(width: 7, height: 7)
                            Text(store.isScheduleInstalled ? "已装载" : "未装载")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            store.save()
                            withAnimation(.snappy(duration: 0.3)) {
                                store.installSchedule()
                            }
                        } label: {
                            Label("安装 / 更新", systemImage: "calendar.badge.plus")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                        }
                        .buttonStyle(.borderedProminent)

                        Button(role: .destructive) {
                            withAnimation(.snappy(duration: 0.3)) {
                                store.uninstallSchedule()
                            }
                        } label: {
                            Label("卸载", systemImage: "calendar.badge.minus")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                        }
                        .buttonStyle(.bordered)
                    }

                    Text(AppStore.scriptURL.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                .card()
            }
            .padding(16)
        }
        .onChange(of: store.settings) { _, _ in store.save() }
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
