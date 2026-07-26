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
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("暂无项目")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("添加 Xcode 项目以开始自动重签名")
                .font(.system(size: 12))
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
    let onDelete: () -> Void
    @State private var isHovered = false
    @State private var appIcon: NSImage?

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

            // ── Config badge ──
            Text(project.configuration)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(statusColor.opacity(0.10))
                .foregroundStyle(statusColor)
                .clipShape(Capsule())
                .padding(.top, 8)

            Spacer(minLength: 8)

            // ── Footer: devices + last build ──
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "iphone")
                        .font(.system(size: 9))
                    Text(project.deviceUDIDs.isEmpty
                         ? "自动选择设备"
                         : "\(project.deviceUDIDs.count) 台设备")
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
                .help("立即构建")

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
                        .font(.system(size: 10))
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
            appIcon = await BuildService.loadAppIcon(projectPath: project.projectPath)
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
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)
                    Picker("", selection: $project.scheme) {
                        ForEach(schemes.isEmpty ? [project.scheme] : schemes, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .frame(maxWidth: 220)
                }
                HStack {
                    Text("Configuration")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)
                    Picker("", selection: $project.configuration) {
                        Text("Debug").tag("Debug")
                        Text("Release").tag("Release")
                    }
                    .frame(maxWidth: 220)
                }
                // ── Multi-device selection ──
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("目标设备")
                            .font(.system(size: 12))
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
                HStack {
                    Text("启用")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)
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
        .onAppear { loadSchemes() }
    }

    private func loadSchemes() {
        guard !project.projectPath.isEmpty else { return }
        Task {
            let result = await BuildService.listSchemes(
                projectPath: project.projectPath,
                xcodePath: store.settings.xcodePath
            )
            await MainActor.run { schemes = result }
        }
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
