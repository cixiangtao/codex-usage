import SwiftUI

struct MaintenanceSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var updateViewModel: UpdateCheckViewModel
    @State private var isResetConfirmationPresented = false

    var body: some View {
        SettingsTabPage(
            title: "维护",
            subtitle: "检查应用更新，或在需要时恢复默认偏好。"
        ) {
            SettingsSection(
                icon: "arrow.down.circle",
                title: "更新",
                subtitle: "从 GitHub Release 检查新版本。"
            ) {
                UpdateCheckRows(viewModel: updateViewModel)
            }

            SettingsSection(
                icon: "arrow.counterclockwise",
                title: "重置设置",
                subtitle: "恢复默认偏好。"
            ) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("恢复默认设置")
                            .font(.callout.weight(.medium))

                        Text("刷新、状态栏图标和通知偏好会恢复到初始状态")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(role: .destructive) {
                        isResetConfirmationPresented = true
                    } label: {
                        Label("重置", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(
                    Color(nsColor: .windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
        }
        .alert("重置偏好设置？", isPresented: $isResetConfirmationPresented) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    settings.reset()
                }
            }
        } message: {
            Text("这会恢复刷新间隔、状态栏图标与展示、通知阈值、图表范围和 Codex 路径设置。")
        }
    }
}
