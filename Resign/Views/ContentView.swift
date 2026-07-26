import SwiftUI

enum NavTab: String, CaseIterable {
    case projects = "项目"
    case devices  = "设备"
    case schedule = "调度"
    case logs     = "日志"

    var icon: String {
        switch self {
        case .projects: return "shippingbox"
        case .devices:  return "iphone"
        case .schedule: return "timer"
        case .logs:     return "terminal"
        }
    }
}

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var tab: NavTab = .projects
    @Namespace private var tabAnimation

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                Divider()
                content
            }

            // Toast overlay
            if let toast = store.toast {
                VStack {
                    Spacer()
                    ToastView(toast: toast)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .padding(.bottom, 24)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: store.toast)
        .frame(minWidth: 680, minHeight: 460)
    }

    // MARK: - Top Bar
    private var topBar: some View {
        HStack(spacing: 12) {
            // Nav pills
            HStack(spacing: 4) {
                ForEach(NavTab.allCases, id: \.self) { t in
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { tab = t }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: t.icon)
                                .font(.system(size: 12, weight: .medium))
                            Text(t.rawValue)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .foregroundStyle(tab == t ? .white : .secondary)
                        .background {
                            if tab == t {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.accentColor)
                                    .matchedGeometryEffect(id: "tab_bg", in: tabAnimation)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            // Status
            if store.isBuilding {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(store.statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            // Run button
            Button {
                if store.isBuilding {
                    store.cancelBuild()
                } else {
                    store.startBuildAll()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: store.isBuilding ? "stop.fill" : "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(store.isBuilding ? "取消" : "执行全部")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(store.isBuilding ? .red : .accentColor)
            .disabled(!store.isBuilding && store.projects.filter(\.isEnabled).isEmpty)
            .animation(.easeInOut(duration: 0.2), value: store.isBuilding)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Content
    private var content: some View {
        Group {
            switch tab {
            case .projects: ProjectsView()
            case .devices:  DevicesView()
            case .schedule: ScheduleView()
            case .logs:     LogsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy(duration: 0.2), value: tab)
    }
}

// MARK: - Card Modifier
struct CardStyle: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
            }
    }
}

extension View {
    func card(padding: CGFloat = 14) -> some View {
        modifier(CardStyle(padding: padding))
    }
}

// MARK: - Toast View
struct ToastView: View {
    let toast: AppStore.Toast

    private var accent: Color {
        switch toast.kind {
        case .success: return Color.green
        case .error:   return Color.red
        case .info:    return Color.blue
        }
    }

    private var icon: String {
        switch toast.kind {
        case .success: return "checkmark.circle.fill"
        case .error:   return "xmark.circle.fill"
        case .info:    return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
            Text(toast.message)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            Capsule()
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        }
        .overlay {
            Capsule().strokeBorder(accent.opacity(0.35), lineWidth: 1)
        }
    }
}
