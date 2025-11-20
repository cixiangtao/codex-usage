import Foundation
import ServiceManagement

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isBusy = false
    @Published private(set) var statusText = ""
    @Published private(set) var errorMessage: String?

    private var status = SMAppService.mainApp.status

    var canManageLoginItem: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    var shouldOfferSystemSettings: Bool {
        !canManageLoginItem || status == .requiresApproval
    }

    init() {
        refresh()
    }

    func refresh() {
        status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        statusText = statusDescription
    }

    func setEnabled(_ enabled: Bool) {
        guard !isBusy else { return }

        guard canManageLoginItem else {
            refresh()
            errorMessage = "需要从打包后的 .app 中设置，开发运行不会写入登录项。"
            return
        }

        isBusy = true
        errorMessage = nil

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        refresh()
        isBusy = false
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private var statusDescription: String {
        guard canManageLoginItem else {
            return "需要从打包后的 .app 中设置，swift run 开发运行不会写入登录项。"
        }

        switch status {
        case .enabled:
            return "登录 macOS 后自动启动菜单栏监控。"
        case .notRegistered:
            return "关闭后不会随 macOS 登录自动启动。"
        case .requiresApproval:
            return "需要在系统设置的登录项中允许 CodexUsage。"
        case .notFound:
            return "当前应用包无法作为登录项注册，请重新安装应用。"
        @unknown default:
            return "当前登录项状态暂时无法识别。"
        }
    }
}
