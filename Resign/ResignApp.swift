import SwiftUI

@main
struct ResignApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .onAppear {
                    if store.settings.autoInstallSchedule && !store.projects.isEmpty
                        && (!store.isScheduleInstalled || ScheduleService.needsUpdate) {
                        store.installSchedule()
                    }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 680, height: 460)

        // Menu bar extra for quick access
        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu Bar View
struct MenuBarView: View {
    let store: AppStore

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.blue)
                Text("Resign")
                    .font(.headline)
                Spacer()
                if store.isBuilding {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Divider()

            Text(store.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            Button {
                if store.isBuilding {
                    store.cancelBuild()
                } else {
                    store.startBuildAll()
                }
            } label: {
                Label(store.isBuilding ? "取消当前任务" : "立即执行全部",
                      systemImage: store.isBuilding ? "stop.fill" : "play.fill")
            }
            .disabled(!store.isBuilding && store.projects.filter(\.isEnabled).isEmpty)

            Divider()

            Button {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.title.contains("Resign") || $0.isKeyWindow }) {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    NSApp.windows.first?.makeKeyAndOrderFront(nil)
                }
            } label: {
                Label("打开主窗口", systemImage: "macwindow")
            }

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出 Resign", systemImage: "power")
            }
        }
        .padding(12)
        .frame(width: 240)
    }
}
