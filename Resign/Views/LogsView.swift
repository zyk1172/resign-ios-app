import SwiftUI

struct LogsView: View {
    @Environment(AppStore.self) private var store
    @State private var selectedLog: BuildLogEntry?
    @State private var showDetail = false

    var body: some View {
        VStack(spacing: 14) {
            // Header
            HStack {
                Label("构建记录", systemImage: "terminal")
                    .font(.system(size: AppStyle.cardTitleSize, weight: .semibold))
                Spacer()
                if !store.logs.isEmpty {
                    Button(role: .destructive) {
                        withAnimation(.snappy(duration: 0.25)) {
                            store.logs.removeAll()
                            store.save()
                        }
                    } label: {
                        Label("清空", systemImage: "trash")
                            .font(.system(size: AppStyle.captionSize, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
            .card()

            // Log cards
            if store.logs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: AppStyle.emptyIconSize))
                        .foregroundStyle(.tertiary)
                    Text("暂无记录")
                        .font(.system(size: AppStyle.emptyTitleSize, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("执行构建后记录将显示在这里")
                        .font(.system(size: AppStyle.emptySubtitleSize))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: AppStyle.listSpacing) {
                        ForEach(store.logs) { entry in
                            LogCard(entry: entry) {
                                selectedLog = entry
                                showDetail = true
                            }
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            ))
                        }
                    }
                }
            }
        }
        .padding(16)
        .sheet(isPresented: $showDetail) {
            if let log = selectedLog {
                LogDetailSheet(entry: log)
            }
        }
        .onAppear { store.importScheduledRuns() }
    }
}

// MARK: - Log Card
struct LogCard: View {
    let entry: BuildLogEntry
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                // Top row
                HStack(spacing: 10) {
                    Image(systemName: entry.status.symbolName)
                        .font(.system(size: 13))
                        .foregroundStyle(statusColor)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.projectName)
                            .font(.system(size: AppStyle.listTitleSize, weight: .semibold))
                            .lineLimit(1)
                        Text(entry.date.formatted(.dateTime.month(.twoDigits).day().hour().minute().second()))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Text(entry.durationText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text(entry.status.label)
                        .font(.system(size: AppStyle.captionSize, weight: .medium))
                        .padding(.horizontal, AppStyle.badgeHPadding)
                        .padding(.vertical, AppStyle.badgeVPadding)
                        .background(statusColor.opacity(0.1))
                        .foregroundStyle(statusColor)
                        .clipShape(RoundedRectangle(cornerRadius: AppStyle.badgeCornerRadius))

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(isHovered ? 1 : 0)
                }

                // Error summary — "where" + "why", visible without opening detail
                if let summary = entry.errorSummary {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 10, weight: .semibold))
                            Text(summary.location)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                        .foregroundStyle(Color.red.opacity(0.85))

                        Text(summary.reason)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.red.opacity(0.05))
                    }
                }
            }
            .card()
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
        .scaleEffect(isHovered ? 1.003 : 1.0)
    }

    private var statusColor: Color {
        switch entry.status {
        case .success:   return .green
        case .failed:    return .red
        case .running:   return .blue
        case .cancelled: return .gray
        }
    }
}

// MARK: - Log Detail Sheet
struct LogDetailSheet: View {
    let entry: BuildLogEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: entry.status.symbolName)
                    .font(.system(size: 15))
                    .foregroundStyle(entry.status == .success ? .green : .red)
                Text(entry.projectName)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(entry.date.formatted(date: .abbreviated, time: .standard))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(entry.durationText)
                    .font(.system(size: AppStyle.captionSize, design: .monospaced))
                    .padding(.horizontal, AppStyle.badgeHPadding)
                    .padding(.vertical, AppStyle.badgeVPadding)
                    .background(.gray.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: AppStyle.badgeCornerRadius))
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(14)

            Divider()

            // Error summary at top (where + why)
            if let summary = entry.errorSummary {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.red)
                        Text("问题定位")
                            .font(.system(size: 12, weight: .semibold))
                        Text(summary.location)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.red)
                    }
                    Text(summary.reason)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.06))

                Divider()
            }

            // Full raw output (collapsible)
            ScrollView {
                Text(entry.output)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(width: 600, height: 420)
    }
}
