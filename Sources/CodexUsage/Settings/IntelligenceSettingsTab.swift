import SwiftUI

struct IntelligenceSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var intelligenceCheckViewModel: CodexIntelligenceCheckViewModel

    var body: some View {
        SettingsTabPage(
            title: "降智检测",
            subtitle: "运行轻量样本，判断当前 Codex 模型是否处于预期状态。"
        ) {
            SettingsSection(
                icon: "brain.head.profile",
                title: "模型状态",
                subtitle: "结果以 Codex CLI 能力与实际样本响应为准。"
            ) {
                CodexIntelligenceCheckRows(
                    viewModel: intelligenceCheckViewModel,
                    codexHomePath: settings.codexHomePath
                )
            }
        }
    }
}
