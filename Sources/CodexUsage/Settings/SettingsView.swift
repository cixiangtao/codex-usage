import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    #if DEBUG
    @ObservedObject var viewModel: DashboardViewModel
    #endif
    @ObservedObject var updateViewModel: UpdateCheckViewModel
    @ObservedObject var intelligenceCheckViewModel: CodexIntelligenceCheckViewModel
    @State private var selectedTab = SettingsTab.general

    init(
        settings: AppSettings,
        viewModel: DashboardViewModel,
        updateViewModel: UpdateCheckViewModel,
        intelligenceCheckViewModel: CodexIntelligenceCheckViewModel
    ) {
        self.settings = settings
        #if DEBUG
        self.viewModel = viewModel
        #else
        _ = viewModel
        #endif
        self.updateViewModel = updateViewModel
        self.intelligenceCheckViewModel = intelligenceCheckViewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("设置分类", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(tab.title)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 360)
            .padding(.vertical, 12)
            .accessibilityLabel("设置分类")

            Divider()

            selectedContent
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedTab {
        case .general:
            GeneralSettingsTab(settings: settings)
        case .notifications:
            notificationTab
        case .intelligence:
            IntelligenceSettingsTab(
                settings: settings,
                intelligenceCheckViewModel: intelligenceCheckViewModel
            )
        case .maintenance:
            MaintenanceSettingsTab(
                settings: settings,
                updateViewModel: updateViewModel
            )
        }
    }

    @ViewBuilder
    private var notificationTab: some View {
        #if DEBUG
        NotificationSettingsTab(settings: settings, viewModel: viewModel)
        #else
        NotificationSettingsTab(settings: settings)
        #endif
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case notifications
    case intelligence
    case maintenance

    var id: Self { self }

    var title: String {
        switch self {
        case .general:
            "常规"
        case .notifications:
            "通知"
        case .intelligence:
            "检测"
        case .maintenance:
            "维护"
        }
    }
}

struct SettingsTabPage<Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 18, weight: .semibold))

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                content
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
