import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct IconSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @State private var errorMessage: String?
    @State private var iconPendingRemoval: CustomStatusBarIcon?

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        SettingsTabPage(
            title: "图标",
            subtitle: "选择状态栏动画，或导入自己的静态图片和 GIF。"
        ) {
            SettingsSection(
                icon: "play.circle",
                title: "播放",
                subtitle: "动图由 macOS 原生图像视图播放，不会触发状态栏整体刷新。"
            ) {
                ToggleRow(
                    title: "播放状态栏动画",
                    subtitle: "关闭后，像素图标和 GIF 都停留在首帧",
                    isOn: $settings.animateStatusBarIcon
                )
            }

            SettingsSection(
                icon: "square.grid.2x2",
                title: "内置图标",
                subtitle: "包含 CodexUsage 图标和“不只因”的 19 个默认动画。"
            ) {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(StatusBarIconCatalog.builtIns) { descriptor in
                        StatusBarIconChoice(
                            descriptor: descriptor,
                            isSelected: settings.statusBarIconID == descriptor.id,
                            animates: settings.animateStatusBarIcon
                        ) {
                            settings.statusBarIconID = descriptor.id
                        }
                    }
                }
            }

            SettingsSection(
                icon: "photo.badge.plus",
                title: "自定义图标",
                subtitle: "支持 GIF、PNG、JPEG、HEIC 和 TIFF；导入的是独立副本。"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    if settings.customStatusBarIcons.isEmpty {
                        Text("还没有自定义图标。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 42, alignment: .center)
                    } else {
                        ForEach(settings.customStatusBarIcons) { icon in
                            customIconRow(icon)
                        }
                    }

                    Button(action: chooseImage) {
                        Label("导入图片…", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .alert(
            "无法导入图标",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "移除这个自定义图标？",
            isPresented: Binding(
                get: { iconPendingRemoval != nil },
                set: { if !$0 { iconPendingRemoval = nil } }
            )
        ) {
            Button("移除", role: .destructive) {
                removePendingIcon()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会删除 CodexUsage 保存的副本，不会影响原文件。")
        }
    }

    private func customIconRow(_ icon: CustomStatusBarIcon) -> some View {
        let descriptor = StatusBarIconCatalog.descriptor(
            id: icon.catalogID,
            customIcons: settings.customStatusBarIcons,
            customIconDirectory: settings.customIconDirectory
        )

        return HStack(spacing: 8) {
            Button {
                settings.statusBarIconID = icon.catalogID
            } label: {
                HStack(spacing: 10) {
                    iconPreview(descriptor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(icon.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text("自定义图片")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    selectionIndicator(isSelected: settings.statusBarIconID == icon.catalogID)
                }
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                settings.statusBarIconID == icon.catalogID
                    ? Color.accentColor.opacity(0.1)
                    : Color(nsColor: .windowBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )

            Button {
                iconPendingRemoval = icon
            } label: {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("移除 \(icon.name)")
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "选择状态栏图标"
        panel.prompt = "导入"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.gif, .png, .jpeg, .heic, .tiff]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try settings.importStatusBarIcon(from: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removePendingIcon() {
        guard let icon = iconPendingRemoval else { return }
        iconPendingRemoval = nil

        do {
            try settings.removeStatusBarIcon(icon)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func iconPreview(_ descriptor: StatusBarIconDescriptor) -> some View {
        StatusBarIconView(
            descriptor: descriptor,
            health: .normal,
            animates: settings.animateStatusBarIcon
                && settings.statusBarIconID == descriptor.id
        )
        .frame(width: 30, height: 28)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
    }

    private func selectionIndicator(isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
    }
}

private struct StatusBarIconChoice: View {
    var descriptor: StatusBarIconDescriptor
    var isSelected: Bool
    var animates: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                StatusBarIconView(
                    descriptor: descriptor,
                    health: .normal,
                    animates: animates && isSelected
                )
                .frame(width: 30, height: 28)
                .background(
                    Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(descriptor.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? Color.accentColor.opacity(0.1) : Color(nsColor: .windowBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.7) : Color.clear,
                    lineWidth: 1
                )
        )
        .accessibilityLabel("\(descriptor.title)，\(descriptor.subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
