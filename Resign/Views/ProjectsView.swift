import SwiftUI
import UniformTypeIdentifiers

struct ProjectsView: View {
    @Environment(AppStore.self) private var store
    @State private var showingFilePicker = false
    @State private var showingFolderPicker = false
    @State private var editingProject: iOSProject?

    var body: some View {
        VStack(spacing: 0) {
            if store.projects.isEmpty {
                emptyState
            } else {
                projectCards
            }
        }
        .padding(16)
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.folder, .item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls {
                    let path = url.path
                    if path.hasSuffix(".xcodeproj") || path.hasSuffix(".xcworkspace") {
                        store.addProject(path: path)
                    } else {
                        let fm = FileManager.default
                        if let contents = try? fm.contentsOfDirectory(atPath: path) {
                            if let proj = contents.first(where: { $0.hasSuffix(".xcworkspace") }) {
                                store.addProject(path: path + "/" + proj)
                            } else if let proj = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
                                store.addProject(path: path + "/" + proj)
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $editingProject) { project in
            ProjectEditSheet(project: project) { updated in
                store.updateProject(updated)
            }
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let folder = urls.first {
                store.addProjectsFromFolder(folder)
            }
        }
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: AppStyle.emptyIconSize))
                .foregroundStyle(.tertiary)
            Text("暂无项目")
                .font(.system(size: AppStyle.emptyTitleSize, weight: .medium))
                .foregroundStyle(.secondary)
            Text("添加 Xcode 项目以开始自动重签名")
                .font(.system(size: AppStyle.emptySubtitleSize))
                .foregroundStyle(.tertiary)
            Button {
                showingFilePicker = true
            } label: {
                Label("添加项目", systemImage: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)

            Button {
                showingFolderPicker = true
            } label: {
                Label("扫描文件夹", systemImage: "folder.badge.gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Project Cards (tarot-style grid)
    private var projectCards: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(store.projects) { project in
                        ProjectCard(
                            project: project,
                            onEdit: { editingProject = project },
                            onBuild: { store.startBuildSingle(project) },
                            onPushToDevice: { udid in
                                store.startBuildSingle(project, toDevice: udid)
                            },
                            onDelete: {
                                withAnimation(.snappy(duration: 0.25)) {
                                    store.removeProject(project)
                                }
                            }
                        )
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.85).combined(with: .opacity),
                            removal: .scale(scale: 0.85).combined(with: .opacity)
                        ))
                    }
                }
                .padding(.bottom, 8)
            }

            // Add buttons
            HStack(spacing: 10) {
                Button {
                    showingFilePicker = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 14))
                        Text("添加项目")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
                            .foregroundStyle(.secondary.opacity(0.4))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    showingFolderPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.system(size: 14))
                        Text("扫描文件夹")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
                            .foregroundStyle(.secondary.opacity(0.4))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("递归扫描文件夹下的所有 Xcode 项目")
            }
        }
    }
}

// MARK: - Project Card (tarot-style, vertical)
struct ProjectCard: View {
    let project: iOSProject
    let onEdit: () -> Void
    let onBuild: () -> Void
    let onPushToDevice: (String) -> Void
    let onDelete: () -> Void
    @Environment(AppStore.self) private var store
    @State private var isHovered = false
    @State private var appIcon: NSImage?
    @State private var showingDevicePicker = false

    /// Card accent color driven by last build status
    private var statusColor: Color {
        guard project.isEnabled else { return Color.gray.opacity(0.45) }
        switch project.lastBuildStatus {
        case .success:            return Color.green
        case .failed:             return Color.red
        case .running:            return Color.orange
        case .cancelled, .none:   return Color.gray.opacity(0.55)
        }
    }

    private var statusSymbol: String {
        switch project.lastBuildStatus {
        case .success:            return "checkmark.seal.fill"
        case .failed:             return "xmark.seal.fill"
        case .running:            return "arrow.triangle.2.circlepath"
        case .cancelled, .none:   return "app.dashed"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Top: app icon + status badge ──
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let appIcon {
                        Image(nsImage: appIcon)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 13)
                                .fill(statusColor.opacity(0.14))
                            Image(systemName: "app.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(statusColor.opacity(0.55))
                        }
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                }

                // Status badge (corner)
                Image(systemName: statusSymbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 19, height: 19)
                    .background(statusColor)
                    .clipShape(Circle())
                    .overlay {
                        Circle().strokeBorder(Color(nsColor: .controlBackgroundColor), lineWidth: 2)
                    }
                    .offset(x: 4, y: 4)
            }
            .padding(.top, 16)

            // ── Name ──
            Text(project.name)
                .font(.system(size: 14, weight: .bold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .padding(.top, 10)

            // ── Scheme ──
            Text(project.scheme.isEmpty ? "未设置 Scheme" : project.scheme)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 3)

            // ── Config + Team badge ──
            HStack(spacing: 4) {
                Text(project.configuration)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(statusColor.opacity(0.10))
                    .foregroundStyle(statusColor)
                    .clipShape(Capsule())
                if let teamID = project.teamID, !teamID.isEmpty {
                    Text(teamID)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.gray.opacity(0.08))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                        .help("开发者 Team：\(teamID)")
                }
            }
            .padding(.top, 8)

            Spacer(minLength: 8)

            // ── Footer: destination + last build ──
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: project.platform == .macos
                          ? "desktopcomputer" : "iphone")
                        .font(.system(size: 9))
                    Text(project.platform == .macos
                         ? "安装到本机 /Applications"
                         : (project.deviceUDIDs.isEmpty ? "自动选择设备" : "\(project.deviceUDIDs.count) 台设备"))
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(.secondary)

                if let date = project.lastBuildDate {
                    Text(date.formatted(.relative(presentation: .named)))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, 10)

            // ── Hover actions ──
            HStack(spacing: 8) {
                Button(action: onBuild) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Color.green.opacity(0.12))
                        .foregroundStyle(Color.green)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(project.platform == .macos ? "构建并安装到本机" : "立即构建（按项目默认设备）")

                if project.platform == .ios {
                    Button {
                        showingDevicePicker = true
                    } label: {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(Color.blue.opacity(0.12))
                            .foregroundStyle(Color.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help("推送到指定设备")
                    .popover(isPresented: $showingDevicePicker, arrowEdge: .bottom) {
                        DeviceQuickPicker(project: project) { udid in
                            showingDevicePicker = false
                            onPushToDevice(udid)
                        }
                    }
                }

                Button(action: onEdit) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .frame(width: 28, height: 28)
                        .background(Color.gray.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("设置")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .frame(width: 28, height: 28)
                        .background(Color.red.opacity(0.08))
                        .foregroundStyle(Color.red.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("删除")
            }
            .padding(.bottom, 12)
            .opacity(isHovered ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: statusColor.opacity(isHovered ? 0.28 : 0.12),
                        radius: isHovered ? 10 : 4, y: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(statusColor.opacity(project.isEnabled ? 0.65 : 0.3),
                              lineWidth: project.isEnabled ? 1.8 : 1)
        }
        .overlay {
            // subtle top sheen
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [statusColor.opacity(0.07), Color.clear],
                        startPoint: .top, endPoint: .center
                    )
                )
                .allowsHitTesting(false)
        }
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .offset(y: isHovered ? -3 : 0)
        .onHover { hovering in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
        .task(id: project.projectPath) {
            appIcon = await store.appIcon(for: project.projectPath)
        }
    }
}

// MARK: - Device Quick Picker (popover for "push to a specific device")
struct DeviceQuickPicker: View {
    let project: iOSProject
    let onPick: (String) -> Void
    @Environment(AppStore.self) private var store
    @State private var hoveredUDID: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.blue)
                    Text("推送到设备")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(project.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(store.isBuilding
                     ? "构建进行中，请稍候…"
                     : "本次构建并安装到所选设备，不改变项目默认设置")
                    .font(.system(size: 10))
                    .foregroundStyle(store.isBuilding ? Color.orange : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 9)

            Divider()

            // Device list
            if store.devices.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "iphone.slash")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    Text("未检测到设备")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("连接 iPhone 并信任此电脑后，在设备页刷新")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(store.devices) { device in
                            pickerRow(device)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 248)
            }
        }
        .frame(width: 252)
    }

    private func pickerRow(_ device: iOSDevice) -> some View {
        let isHovered = hoveredUDID == device.udid
        let isProjectDefault = project.deviceUDIDs.contains(device.udid)
        return Button {
            onPick(device.udid)
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(device.isAvailable ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                    .shadow(color: (device.isAvailable ? Color.green : Color.orange).opacity(0.4), radius: 2.5)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(device.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        if isProjectDefault {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.blue)
                                .help("项目默认目标设备")
                        }
                    }
                    Text(device.osVersion.isEmpty
                         ? device.connectionType
                         : "iOS \(device.osVersion) · \(device.connectionType)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if device.isAvailable {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(isHovered ? Color.blue : Color.blue.opacity(0.30))
                        .scaleEffect(isHovered ? 1.08 : 1.0)
                        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isHovered)
                } else {
                    Text("未连接")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isHovered && device.isAvailable ? Color.blue.opacity(0.08) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!device.isAvailable || store.isBuilding)
        .opacity(device.isAvailable ? 1 : 0.55)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                if hovering {
                    hoveredUDID = device.udid
                } else if hoveredUDID == device.udid {
                    hoveredUDID = nil
                }
            }
        }
    }
}

// MARK: - Edit Sheet
struct ProjectEditSheet: View {
    @State var project: iOSProject
    let onSave: (iOSProject) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @State private var schemes: [String] = []
    @State private var teams: [DevelopmentTeam] = []

    var body: some View {
        VStack(spacing: 0) {
            // Title
            HStack {
                Text(project.name)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            // Form
            VStack(spacing: 14) {
                HStack {
                    Text("Scheme")
                        .font(.system(size: AppStyle.fieldSize))
                        .foregroundStyle(.secondary)
                        .frame(width: AppStyle.formLabelWidth, alignment: .trailing)
                    Picker("", selection: $project.scheme) {
                        ForEach(schemes.isEmpty ? [project.scheme] : schemes, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .frame(maxWidth: AppStyle.formFieldMaxWidth)
                }
                HStack {
                    Text("Configuration")
                        .font(.system(size: AppStyle.fieldSize))
                        .foregroundStyle(.secondary)
                        .frame(width: AppStyle.formLabelWidth, alignment: .trailing)
                    Picker("", selection: $project.configuration) {
                        Text("Debug").tag("Debug")
                        Text("Release").tag("Release")
                    }
                    .frame(maxWidth: AppStyle.formFieldMaxWidth)
                }
                HStack {
                    Text("平台")
                        .font(.system(size: AppStyle.fieldSize))
                        .foregroundStyle(.secondary)
                        .frame(width: AppStyle.formLabelWidth, alignment: .trailing)
                    Picker("", selection: $project.platform) {
                        Text("iOS / iPadOS").tag(ProjectPlatform.ios)
                        Text("macOS（本机）").tag(ProjectPlatform.macos)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: AppStyle.formFieldMaxWidth + 40)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("开发者 Team")
                            .font(.system(size: AppStyle.fieldSize))
                            .foregroundStyle(.secondary)
                            .frame(width: AppStyle.formLabelWidth, alignment: .trailing)
                        TextField("未指定（跟随项目设置）", text: teamTextFieldBinding)
                            .font(.system(size: 12, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack(spacing: 6) {
                        Color.clear
                            .frame(width: AppStyle.formLabelWidth)
                        Picker("", selection: $project.teamID) {
                            Text("从已登录账号选择…").tag(String?.none)
                            ForEach(teams) { team in
                                Text(team.displayName).tag(String?.some(team.teamID))
                            }
                        }
                        .frame(maxWidth: AppStyle.formFieldMaxWidth)
                        Button {
                            loadTeams()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .help("刷新开发者 Team 列表")
                        Spacer()
                    }
                    Text(teams.isEmpty
                         ? "未检测到 Xcode 已登录的账号，可手动输入 Team ID（Xcode → Settings → Accounts 查看）"
                         : "选项来自 Xcode 已登录账号；新登录的账号请点刷新，也可直接在上方输入 Team ID")
                        .font(.system(size: AppStyle.microSize))
                        .foregroundStyle(teams.isEmpty ? Color.orange : Color.secondary)
                        .padding(.leading, AppStyle.formLabelWidth)
                        .padding(.trailing, 10)
                }
                // ── Destination: device selection (iOS) or local install note ──
                if project.platform == .ios {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("目标设备")
                                .font(.system(size: AppStyle.fieldSize))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(project.deviceUDIDs.isEmpty
                                 ? "未选择 = 自动选第一台"
                                 : "已选 \(project.deviceUDIDs.count) 台")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }

                        if store.devices.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 11))
                                Text("未检测到设备，请先在“设备”页刷新")
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(.orange)
                            .padding(.vertical, 4)
                        } else {
                            VStack(spacing: 6) {
                                ForEach(store.devices) { device in
                                    DeviceCheckRow(
                                        device: device,
                                        isSelected: project.deviceUDIDs.contains(device.udid)
                                    ) {
                                        toggleDevice(device.udid)
                                    }
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.05))
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 13))
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("安装到本机")
                                .font(.system(size: 11, weight: .semibold))
                            Text("构建完成后自动替换 /Applications 中的同名应用；定时任务同样按此执行")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.blue.opacity(0.05))
                    }
                }
                HStack {
                    Text("启用")
                        .font(.system(size: AppStyle.fieldSize))
                        .foregroundStyle(.secondary)
                        .frame(width: AppStyle.formLabelWidth, alignment: .trailing)
                    Toggle("", isOn: $project.isEnabled)
                        .toggleStyle(.switch)
                }
            }
            .padding(20)

            Divider()

            // Actions
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button("保存") {
                    onSave(project)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
            .padding(16)
        }
        .frame(width: 400)
        .onAppear {
            loadSchemes()
            loadTeams()
        }
    }

    private func loadSchemes() {
        guard !project.projectPath.isEmpty else { return }
        Task {
            schemes = await store.schemes(for: project.projectPath)
        }
    }

    private func loadTeams() {
        Task {
            teams = await store.developmentTeams()
        }
    }

    private var teamTextFieldBinding: Binding<String> {
        Binding(
            get: { project.teamID ?? "" },
            set: { project.teamID = $0.isEmpty ? nil : $0 }
        )
    }

    private func toggleDevice(_ udid: String) {
        if let idx = project.deviceUDIDs.firstIndex(of: udid) {
            project.deviceUDIDs.remove(at: idx)
        } else {
            project.deviceUDIDs.append(udid)
        }
    }
}

// MARK: - Device Checkbox Row
struct DeviceCheckRow: View {
    let device: iOSDevice
    let isSelected: Bool
    let onToggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(.system(size: 12, weight: .medium))
                    Text("iOS \(device.osVersion) · \(device.connectionType)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Circle()
                    .fill(device.isAvailable ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.gray.opacity(0.08) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!device.isAvailable && !isSelected)
        .opacity(device.isAvailable || isSelected ? 1 : 0.55)
        .onHover { isHovered = $0 }
    }
}
