import SwiftUI

struct DevicesView: View {
    @Environment(AppStore.self) private var store
    @State private var isRefreshing = false

    var body: some View {
        VStack(spacing: 14) {
            // Header card
            HStack {
                Label("物理设备", systemImage: "iphone")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    refresh()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                            .animation(
                                isRefreshing
                                    ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                                    : .default,
                                value: isRefreshing
                            )
                        Text("刷新")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshing)
            }
            .card(padding: 12)

            // Device cards
            if store.devices.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "iphone.slash")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("未检测到物理设备")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("通过 USB 或同一 WiFi 连接 iPhone 后刷新")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.devices) { device in
                            DeviceCard(device: device)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                }
            }
        }
        .padding(16)
        .onAppear {
            if store.devices.isEmpty { refresh() }
        }
    }

    private func refresh() {
        withAnimation { isRefreshing = true }
        Task {
            await store.refreshDevices()
            await MainActor.run {
                withAnimation { isRefreshing = false }
            }
        }
    }
}

// MARK: - Device Card
struct DeviceCard: View {
    let device: iOSDevice
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Status
            Circle()
                .fill(device.isAvailable ? Color.green : Color.orange)
                .frame(width: 9, height: 9)
                .shadow(color: (device.isAvailable ? Color.green : Color.orange).opacity(0.4), radius: 3)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(device.udid)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            Spacer()

            // Tags
            HStack(spacing: 6) {
                if !device.osVersion.isEmpty {
                    Text("iOS \(device.osVersion)")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.blue.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                Text(device.connectionType)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.gray.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .card()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
        .scaleEffect(isHovered ? 1.005 : 1.0)
    }
}
