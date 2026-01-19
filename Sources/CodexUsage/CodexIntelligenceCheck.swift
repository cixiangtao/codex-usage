import Foundation
import AppKit
import Darwin
import SwiftUI

private let intelligenceCheckSampleTimeout: TimeInterval = 120

struct CodexReasoningEffort: RawRepresentable, Hashable, Identifiable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        self.rawValue = value
    }

    var id: String { rawValue }

    var title: String { rawValue }
}

struct CodexIntelligenceCheckRun: Identifiable, Equatable, Sendable {
    let id = UUID()
    var index: Int
    var answer: String
    var inputTokens: Int?
    var outputTokens: Int?
    var reasoningOutputTokens: Int?
    var elapsedSeconds: Double
    var isCorrect: Bool?
    var errorMessage: String?
    var failureKind: CodexIntelligenceCheckFailureKind?

    var tokensPerSecond: Double? {
        guard let outputTokens, elapsedSeconds > 0 else { return nil }
        return Double(outputTokens) / elapsedSeconds
    }
}

enum CodexIntelligenceCheckFailureKind: Equatable, Sendable {
    case command
    case cancelled
    case timedOut
}

enum CodexCLIInstallationState: Equatable {
    case unknown
    case checking
    case installed(String)
    case missing

    var executablePath: String? {
        if case let .installed(path) = self {
            return path
        }

        return nil
    }

    var isInstalled: Bool {
        executablePath != nil
    }
}

struct CodexModelOption: Identifiable, Equatable, Sendable {
    var id: String { slug }

    var slug: String
    var displayName: String
    var supportedReasoningEfforts: [CodexReasoningEffort]
    var defaultReasoningEffort: CodexReasoningEffort?
    var isDefault: Bool
    var isConfiguredFallback: Bool
}

enum CodexIntelligenceCheckConclusion {
    case notEnoughData
    case notDegraded
    case suspectedDegraded

    var title: String {
        switch self {
        case .notEnoughData:
            "不足判断"
        case .notDegraded:
            "未发现降智"
        case .suspectedDegraded:
            "疑似降智"
        }
    }

    var badgeTitle: String {
        switch self {
        case .notEnoughData:
            "不足"
        case .notDegraded:
            "正常"
        case .suspectedDegraded:
            "疑似"
        }
    }

    var tint: Color {
        switch self {
        case .notEnoughData:
            .secondary
        case .notDegraded:
            .green
        case .suspectedDegraded:
            .red
        }
    }
}

@MainActor
final class CodexIntelligenceCheckViewModel: ObservableObject {
    static let installGuideURL = URL(string: "https://developers.openai.com/codex/quickstart")!

    @Published private(set) var modelName = ""
    @Published private(set) var modelOptions: [CodexModelOption] = []
    @Published private(set) var cliDefaultModelDisplayName: String?
    @Published private(set) var modelListErrorMessage: String?
    @Published private(set) var detectedModelName: String?
    @Published private(set) var detectedReasoningEffort: CodexReasoningEffort?
    @Published private(set) var reasoningEffortOptions: [CodexReasoningEffort] = []
    @Published var reasoningEffort: CodexReasoningEffort?
    @Published var runCount = 3
    @Published private(set) var runs: [CodexIntelligenceCheckRun] = []
    @Published private(set) var historyEntries: [CodexIntelligenceCheckHistoryEntry]
    @Published private(set) var isRunning = false
    @Published private(set) var currentRunIndex: Int?
    @Published private(set) var errorMessage: String?
    @Published private(set) var installationState: CodexCLIInstallationState = .unknown
    @Published private(set) var cliUpdateState: CodexCLIUpdateState = .idle
    @Published private(set) var isPreparingEnvironment = false

    private var task: Task<Void, Never>?
    private let historyStore: CodexIntelligenceCheckHistoryStore
    private let cliUpdater = CodexCLIUpdater()
    private let processController = CodexProcessLifetimeController()

    init(historyStore: CodexIntelligenceCheckHistoryStore = CodexIntelligenceCheckHistoryStore()) {
        self.historyStore = historyStore
        historyEntries = historyStore.load()
    }

    var completedCount: Int {
        runs.filter { $0.isCorrect != nil }.count
    }

    var correctCount: Int {
        runs.filter { $0.isCorrect == true }.count
    }

    var accuracyText: String {
        guard completedCount > 0 else { return "--" }
        let accuracy = Double(correctCount) / Double(completedCount) * 100
        return "\(Int(accuracy.rounded()))%"
    }

    var averageReasoningTokensText: String {
        let values = runs.compactMap(\.reasoningOutputTokens)
        guard !values.isEmpty else { return "--" }
        let average = values.reduce(0, +) / values.count
        return UsageFormatters.compactTokens(average)
    }

    var averageTPSText: String {
        let values = runs.compactMap(\.tokensPerSecond)
        guard !values.isEmpty else { return "--" }
        let average = values.reduce(0, +) / Double(values.count)
        return String(format: "%.1f", average)
    }

    var conclusion: CodexIntelligenceCheckConclusion {
        guard completedCount > 0 else { return .notEnoughData }
        return correctCount == completedCount ? .notDegraded : .suspectedDegraded
    }

    var conclusionExplanation: String {
        switch conclusion {
        case .notEnoughData:
            return "没有有效样本，无法判断是否降智。"
        case .notDegraded:
            if completedCount < runs.count {
                return "有效样本全部通过，未发现降智；部分样本未完成。"
            }

            return "有效样本全部通过，未发现降智。"
        case .suspectedDegraded:
            return "存在有效样本未通过，结论为疑似降智。"
        }
    }

    var canStart: Bool {
        !controlsAreDisabled && installationState.isInstalled
    }

    var controlsAreDisabled: Bool {
        isRunning || isPreparingEnvironment || cliUpdateState.blocksDetection
    }

    var effectiveCLIDefaultModelDisplayName: String? {
        guard let detectedModelName else {
            return cliDefaultModelDisplayName
        }

        return modelOptions.first(where: { $0.slug == detectedModelName })?.displayName
            ?? detectedModelName
    }

    func selectModel(_ modelName: String) {
        guard self.modelName != modelName else { return }
        self.modelName = modelName
        synchronizeReasoningEffort(
            preferred: modelName.isEmpty ? detectedReasoningEffort : nil
        )
    }

    func prepareForPresentation(codexHomePath: String) async {
        guard !isRunning, !isPreparingEnvironment else { return }
        if case .updating = cliUpdateState { return }

        isPreparingEnvironment = true
        await checkInstallation()

        guard let executablePath = installationState.executablePath else {
            cliUpdateState = .idle
            await reloadConfiguredDefaults(codexHomePath: codexHomePath, executablePath: nil)
            isPreparingEnvironment = false
            return
        }

        cliUpdateState = .checking

        do {
            let update = try await cliUpdater.checkForUpdate(executablePath: executablePath)
            if update.isUpdateAvailable {
                cliUpdateState = .updateAvailable(update)
                isPreparingEnvironment = false
                return
            }

            await reloadConfiguredDefaults(
                codexHomePath: codexHomePath,
                executablePath: executablePath
            )
            if let modelListErrorMessage {
                cliUpdateState = .failed(
                    currentVersion: update.currentVersion,
                    message: modelListErrorMessage
                )
            } else {
                cliUpdateState = .current(update.currentVersion)
            }
        } catch {
            let currentVersion = try? await cliUpdater.installedVersion(at: executablePath)
            await reloadConfiguredDefaults(
                codexHomePath: codexHomePath,
                executablePath: executablePath
            )
            cliUpdateState = .failed(
                currentVersion: currentVersion,
                message: error.localizedDescription
            )
        }

        isPreparingEnvironment = false
    }

    func deferCLIUpdate(codexHomePath: String) {
        guard case .updateAvailable(let update) = cliUpdateState else { return }

        cliUpdateState = .deferred(update)
        isPreparingEnvironment = true
        Task { [weak self] in
            guard let self else { return }
            await reloadConfiguredDefaults(
                codexHomePath: codexHomePath,
                executablePath: update.executablePath
            )
            if let modelListErrorMessage {
                cliUpdateState = .failed(
                    currentVersion: update.currentVersion,
                    message: modelListErrorMessage
                )
            }
            isPreparingEnvironment = false
        }
    }

    func beginCLIUpdate() -> CodexCLIUpdateCheckResult? {
        guard !isPreparingEnvironment else { return nil }

        let update: CodexCLIUpdateCheckResult
        switch cliUpdateState {
        case .updateAvailable(let result), .deferred(let result):
            update = result
        default:
            return nil
        }

        cliUpdateState = .updating(update)
        return update
    }

    func performCLIUpdate(
        _ update: CodexCLIUpdateCheckResult,
        codexHomePath: String
    ) async {
        do {
            try await cliUpdater.update(
                executablePath: update.executablePath,
                codexHomePath: codexHomePath
            )

            let executablePath = try await Task.detached(priority: .userInitiated) {
                try CodexExecutableResolver.resolve()
            }.value
            let installedVersion = try await cliUpdater.installedVersion(at: executablePath)

            guard let expected = SemanticVersion(update.latestVersion),
                  let actual = SemanticVersion(installedVersion),
                  actual >= expected else {
                throw CodexCLIUpdateError.verificationFailed(
                    expected: update.latestVersion,
                    actual: installedVersion
                )
            }

            installationState = .installed(executablePath)
            await reloadConfiguredDefaults(
                codexHomePath: codexHomePath,
                executablePath: executablePath
            )
            if let modelListErrorMessage {
                cliUpdateState = .failed(
                    currentVersion: installedVersion,
                    message: "CLI 已更新，但\(modelListErrorMessage)"
                )
            } else {
                cliUpdateState = .updated(installedVersion)
            }
        } catch {
            let fallbackPath = (try? await Task.detached(priority: .utility) {
                try CodexExecutableResolver.resolve()
            }.value) ?? update.executablePath
            let currentVersion = try? await cliUpdater.installedVersion(at: fallbackPath)

            if FileManager.default.isExecutableFile(atPath: fallbackPath) {
                installationState = .installed(fallbackPath)
            } else {
                installationState = .missing
            }
            await reloadConfiguredDefaults(
                codexHomePath: codexHomePath,
                executablePath: installationState.executablePath
            )
            cliUpdateState = .failed(
                currentVersion: currentVersion ?? update.currentVersion,
                message: error.localizedDescription
            )
        }
    }

    func reloadConfiguredDefaults(
        codexHomePath: String,
        executablePath: String?
    ) async {
        let configuredDefaults = await Task.detached(priority: .utility) {
            CodexConfigModelResolver.resolveConfiguredDefaults(
                codexHomePath: codexHomePath,
                executablePath: executablePath
            )
        }.value

        detectedModelName = configuredDefaults.model
        detectedReasoningEffort = configuredDefaults.reasoningEffort
        cliDefaultModelDisplayName = configuredDefaults.cliDefaultModelDisplayName
        modelListErrorMessage = configuredDefaults.modelListErrorMessage

        var modelOptions = configuredDefaults.modelOptions
        appendFallbackModelIfNeeded(
            configuredDefaults.model,
            reasoningEffort: configuredDefaults.reasoningEffort,
            isConfigured: true,
            to: &modelOptions
        )
        if isRunning {
            appendFallbackModelIfNeeded(
                modelName,
                reasoningEffort: reasoningEffort,
                isConfigured: false,
                to: &modelOptions
            )
        }
        self.modelOptions = modelOptions

        guard !isRunning else { return }

        modelName = configuredDefaults.model ?? ""
        synchronizeReasoningEffort(preferred: configuredDefaults.reasoningEffort)
    }

    private func appendFallbackModelIfNeeded(
        _ modelName: String?,
        reasoningEffort: CodexReasoningEffort?,
        isConfigured: Bool,
        to modelOptions: inout [CodexModelOption]
    ) {
        guard let modelName = modelName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelName.isEmpty,
              !modelOptions.contains(where: { $0.slug == modelName }) else {
            return
        }

        modelOptions.append(
            CodexModelOption(
                slug: modelName,
                displayName: modelName,
                supportedReasoningEfforts: reasoningEffort.map { [$0] } ?? [],
                defaultReasoningEffort: reasoningEffort,
                isDefault: false,
                isConfiguredFallback: isConfigured
            )
        )
    }

    private func synchronizeReasoningEffort(preferred: CodexReasoningEffort?) {
        guard let model = selectedModelOption else {
            reasoningEffortOptions = []
            reasoningEffort = nil
            return
        }

        let options = model.supportedReasoningEfforts
        reasoningEffortOptions = options

        if let preferred, options.contains(preferred) {
            reasoningEffort = preferred
        } else if let defaultReasoningEffort = model.defaultReasoningEffort,
                  options.contains(defaultReasoningEffort) {
            reasoningEffort = defaultReasoningEffort
        } else {
            reasoningEffort = options.first
        }
    }

    private var selectedModelOption: CodexModelOption? {
        if !modelName.isEmpty {
            return modelOptions.first(where: { $0.slug == modelName })
        }

        if let detectedModelName,
           let configuredModel = modelOptions.first(where: { $0.slug == detectedModelName }) {
            return configuredModel
        }

        return modelOptions.first(where: \.isDefault)
    }

    func checkInstallation() async {
        guard !isRunning else { return }

        installationState = .checking

        do {
            let executablePath = try await Task.detached(priority: .userInitiated) {
                try CodexExecutableResolver.resolve()
            }.value
            installationState = .installed(executablePath)
            if errorMessage == CodexIntelligenceCheckError.codexNotFound.localizedDescription {
                errorMessage = nil
            }
        } catch {
            installationState = .missing
            errorMessage = nil
        }
    }

    func openInstallGuide() {
        NSWorkspace.shared.open(Self.installGuideURL)
    }

    func start() {
        guard !isRunning else { return }
        guard let executablePath = installationState.executablePath else {
            installationState = .missing
            errorMessage = nil
            return
        }

        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel = model.isEmpty ? nil : model
        let effort = reasoningEffort
        let tests = max(1, min(10, runCount))

        runs = []
        errorMessage = nil
        isRunning = true
        processController.reset()
        let processController = self.processController

        task = Task { [weak self] in
            guard let self else { return }

            for index in 1...tests {
                if Task.isCancelled { break }
                currentRunIndex = index

                let run = await Task.detached(priority: .userInitiated) {
                    CodexIntelligenceCheckRunner.runOne(
                        index: index,
                        executablePath: executablePath,
                        model: selectedModel,
                        effort: effort,
                        processController: processController
                    )
                }.value
                currentRunIndex = nil

                if Task.isCancelled || run.failureKind == .cancelled { break }
                runs.append(run)
                if run.failureKind == .timedOut { break }
            }

            isRunning = false
            currentRunIndex = nil
            task = nil
            recordHistoryIfUseful(model: selectedModel, effort: effort, requestedCount: tests)
        }
    }

    func cancel() {
        guard isRunning else { return }
        task?.cancel()
        processController.cancelAndTerminate()
    }

    private func recordHistoryIfUseful(model: String?, effort: CodexReasoningEffort?, requestedCount: Int) {
        let completedRuns = runs.filter { $0.isCorrect != nil }
        guard !completedRuns.isEmpty else { return }

        let correctCount = completedRuns.filter { $0.isCorrect == true }.count
        let reasoningValues = completedRuns.compactMap(\.reasoningOutputTokens)
        let tpsValues = completedRuns.compactMap(\.tokensPerSecond)

        let entry = CodexIntelligenceCheckHistoryEntry(
            id: UUID(),
            capturedAt: Date(),
            modelName: model ?? detectedModelName ?? "Codex CLI 默认模型",
            reasoningEffort: effort?.title ?? detectedReasoningEffort?.title ?? "CLI 默认",
            requestedCount: requestedCount,
            completedCount: completedRuns.count,
            correctCount: correctCount,
            averageReasoningTokens: reasoningValues.isEmpty ? nil : reasoningValues.reduce(0, +) / reasoningValues.count,
            averageTokensPerSecond: tpsValues.isEmpty ? nil : tpsValues.reduce(0, +) / Double(tpsValues.count),
            conclusionTitle: conclusion.title
        )

        historyEntries = historyStore.appending(entry, to: historyEntries)
    }
}

struct CodexIntelligenceCheckRows: View {
    @ObservedObject var viewModel: CodexIntelligenceCheckViewModel
    var codexHomePath: String

    var body: some View {
        VStack(spacing: 10) {
            cliUpdateNotice
            statusRow
            runningNotice
            controls

            if !viewModel.runs.isEmpty {
                summaryGrid
                VStack(spacing: 8) {
                    ForEach(viewModel.runs) { run in
                        resultRow(run)
                    }
                }
            }

            if !viewModel.historyEntries.isEmpty {
                historySection
            }
        }
        .alert("发现 Codex CLI 更新", isPresented: cliUpdateAlertBinding) {
            Button("暂不更新", role: .cancel) {
                viewModel.deferCLIUpdate(codexHomePath: codexHomePath)
            }
            Button("更新 CLI") {
                startCLIUpdate()
            }
        } message: {
            Text(cliUpdateAlertMessage)
        }
    }

    @ViewBuilder
    private var cliUpdateNotice: some View {
        switch viewModel.cliUpdateState {
        case .idle, .current:
            EmptyView()
        case .checking:
            cliUpdateNoticeRow(
                title: "正在检查 Codex CLI 更新",
                subtitle: "完成前暂不能开始降智检测。",
                tint: .secondary
            ) {
                ProgressView()
                    .controlSize(.small)
            }
        case .updateAvailable(let update):
            cliUpdateNoticeRow(
                title: "Codex CLI 可更新至 \(update.latestVersion)",
                subtitle: "当前 \(update.currentVersion)，等待确认是否更新。",
                tint: .orange
            ) {
                Text("待确认")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        case .deferred(let update):
            cliUpdateNoticeRow(
                title: "Codex CLI 可更新至 \(update.latestVersion)",
                subtitle: "已暂缓更新，当前仍使用 \(update.currentVersion)。",
                tint: .orange
            ) {
                Button("更新 CLI") {
                    startCLIUpdate()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isPreparingEnvironment)
            }
        case .updating(let update):
            cliUpdateNoticeRow(
                title: "正在更新 Codex CLI",
                subtitle: "\(update.currentVersion) → \(update.latestVersion)，完成后会重新获取模型列表。",
                tint: .orange
            ) {
                ProgressView()
                    .controlSize(.small)
            }
        case .updated(let version):
            cliUpdateNoticeRow(
                title: "Codex CLI 已更新至 \(version)",
                subtitle: "已重新读取默认配置和模型列表。",
                tint: .green
            ) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case let .failed(currentVersion, message):
            cliUpdateNoticeRow(
                title: "Codex CLI 状态异常",
                subtitle: "\(currentVersion.map { "当前 \($0)。" } ?? "")\(message) 不影响继续使用当前 CLI 检测。",
                tint: .red
            ) {
                Button("重试") {
                    Task {
                        await viewModel.prepareForPresentation(codexHomePath: codexHomePath)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isPreparingEnvironment)
            }
        }
    }

    private func cliUpdateNoticeRow<Trailing: View>(
        title: String,
        subtitle: String,
        tint: Color,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
            trailing()
        }
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.callout.weight(.medium))

                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            statusBadge
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var runningNotice: some View {
        if viewModel.isRunning {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text("检测进行中")
                        .font(.caption.weight(.semibold))

                    Text("单次最长等待 2 分钟；关闭窗口或退出应用会自动取消当前检测。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Text("\(viewModel.runs.count)/\(viewModel.runCount)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.orange)
            }
            .padding(10)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.orange.opacity(0.25), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "检测进行中。已完成 \(viewModel.runs.count) 次，共 \(viewModel.runCount) 次。关闭窗口或退出应用会自动取消。"
            )
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("模型名称", selection: modelSelection) {
                    Text(defaultModelOptionTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .tag("")

                    ForEach(viewModel.modelOptions) { model in
                        Text(modelOptionTitle(model))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .tag(model.slug)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                .disabled(viewModel.controlsAreDisabled)
                .help("选择用于降智检测的模型")

                Stepper("\(viewModel.runCount) 次", value: $viewModel.runCount, in: 1...10)
                    .frame(width: 92, alignment: .trailing)
                    .disabled(viewModel.controlsAreDisabled)
            }

            Picker("推理强度", selection: $viewModel.reasoningEffort) {
                if viewModel.reasoningEffortOptions.isEmpty {
                    Text("CLI 默认").tag(CodexReasoningEffort?.none)
                } else {
                    ForEach(viewModel.reasoningEffortOptions) { effort in
                        Text(effort.title).tag(CodexReasoningEffort?.some(effort))
                    }
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .disabled(viewModel.controlsAreDisabled || viewModel.reasoningEffortOptions.isEmpty)
            .help(reasoningEffortHelp)

            HStack(spacing: 8) {
                if viewModel.isRunning {
                    Button(role: .cancel) {
                        viewModel.cancel()
                    } label: {
                        Label("取消检测", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        viewModel.start()
                    } label: {
                        Label {
                            Text("开始检测")
                        } icon: {
                            Image(systemName: "play.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!viewModel.canStart)
                }

                if viewModel.installationState == .missing {
                    Button {
                        viewModel.openInstallGuide()
                    } label: {
                        Label("安装 Codex CLI", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        Task {
                            await viewModel.prepareForPresentation(codexHomePath: codexHomePath)
                        }
                    } label: {
                        Label("重新检测", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.controlsAreDisabled || viewModel.installationState == .checking)
                }

                Spacer()
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var cliUpdateAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.cliUpdateState.pendingUpdate != nil },
            set: { isPresented in
                guard !isPresented else { return }
                Task { @MainActor in
                    await Task.yield()
                    viewModel.deferCLIUpdate(codexHomePath: codexHomePath)
                }
            }
        )
    }

    private var cliUpdateAlertMessage: String {
        guard let update = viewModel.cliUpdateState.pendingUpdate else { return "" }
        return "当前版本 \(update.currentVersion)，最新版本 \(update.latestVersion)。将更新 \(update.executablePath)，完成后自动重新获取模型列表。"
    }

    private func startCLIUpdate() {
        guard let update = viewModel.beginCLIUpdate() else { return }
        Task {
            await viewModel.performCLIUpdate(update, codexHomePath: codexHomePath)
        }
    }

    private func modelOptionTitle(_ model: CodexModelOption) -> String {
        model.isConfiguredFallback ? "\(model.displayName)（当前配置）" : model.displayName
    }

    private var defaultModelOptionTitle: String {
        guard let displayName = viewModel.effectiveCLIDefaultModelDisplayName else {
            return "Codex CLI 默认模型"
        }

        return "Codex CLI 默认模型（\(displayName)）"
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { viewModel.modelName },
            set: { viewModel.selectModel($0) }
        )
    }

    private var reasoningEffortHelp: String {
        if viewModel.reasoningEffortOptions.isEmpty {
            return "Codex CLI 未返回该模型的推理强度列表，将使用 CLI 默认值。"
        }

        return "选项来自当前模型返回的推理强度列表。"
    }

    private var summaryGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                metricCell("结论", viewModel.conclusion.title, tint: viewModel.conclusion.tint)
                metricCell("正确率", viewModel.accuracyText, tint: viewModel.correctCount == viewModel.completedCount ? .green : .orange)
                metricCell("思考", viewModel.averageReasoningTokensText, tint: .accentColor)
                metricCell("TPS", viewModel.averageTPSText, tint: .secondary)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("历史基线", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))

                Spacer()

                Text(historyComparisonText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(viewModel.historyEntries.prefix(3))) { entry in
                historyRow(entry)
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func historyRow(_ entry: CodexIntelligenceCheckHistoryEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(UsageFormatters.fullDateTime(entry.capturedAt)) · \(entry.conclusionTitle)")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)

                Text("\(entry.modelName) / \(entry.reasoningEffort)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(historyMetricText(for: entry))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var historyComparisonText: String {
        guard viewModel.completedCount > 0 else {
            return "最近 \(viewModel.historyEntries.count) 次"
        }

        guard let baseline = comparisonBaseline else {
            return "已建立本机基线"
        }

        let currentAccuracy = Int((Double(viewModel.correctCount) / Double(viewModel.completedCount) * 100).rounded())
        let accuracyDelta = currentAccuracy - baseline.accuracyPercent
        let accuracyText = accuracyDelta == 0 ? "正确率持平" : "正确率 \(signedPercent(accuracyDelta))"

        guard let currentReasoning = currentAverageReasoningTokens(),
              let baselineReasoning = baseline.averageReasoningTokens else {
            return "较上次：\(accuracyText)"
        }

        return "较上次：\(accuracyText) · 思考 \(signedTokens(currentReasoning - baselineReasoning))"
    }

    private var comparisonBaseline: CodexIntelligenceCheckHistoryEntry? {
        guard viewModel.completedCount > 0 else {
            return viewModel.historyEntries.first
        }

        if let latest = viewModel.historyEntries.first,
           latest.completedCount == viewModel.completedCount,
           latest.correctCount == viewModel.correctCount {
            return Array(viewModel.historyEntries.dropFirst()).first
        }

        return viewModel.historyEntries.first
    }

    private func currentAverageReasoningTokens() -> Int? {
        let values = viewModel.runs.compactMap(\.reasoningOutputTokens)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / values.count
    }

    private func historyMetricText(for entry: CodexIntelligenceCheckHistoryEntry) -> String {
        let reasoning = entry.averageReasoningTokens.map(UsageFormatters.compactTokens) ?? "--"
        let tps = entry.averageTokensPerSecond.map { String(format: "%.1f", $0) } ?? "--"
        return "\(entry.accuracyPercent)% · 思考 \(reasoning) · \(tps) t/s"
    }

    private func signedPercent(_ value: Int) -> String {
        value > 0 ? "+\(value)%" : "\(value)%"
    }

    private func signedTokens(_ value: Int) -> String {
        if value == 0 {
            return "持平"
        }

        let prefix = value > 0 ? "+" : "-"
        return "\(prefix)\(UsageFormatters.compactTokens(abs(value)))"
    }

    private func metricCell(_ label: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func resultRow(_ run: CodexIntelligenceCheckRun) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("#\(run.index)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Label(resultTitle(for: run), systemImage: resultIcon(for: run))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(resultTint(for: run))

                    Text(tokenText(for: run))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(detailText(for: run))
                    .font(.caption2)
                    .foregroundStyle(run.errorMessage == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var statusBadge: some View {
        if viewModel.isRunning || viewModel.installationState == .checking {
            ProgressView()
                .controlSize(.small)
        } else if viewModel.installationState == .missing {
            Text("未安装")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.12), in: Capsule())
        } else if viewModel.errorMessage != nil {
            Text("失败")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.12), in: Capsule())
        } else if viewModel.completedCount > 0 {
            Text(viewModel.conclusion.badgeTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(viewModel.conclusion.tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(viewModel.conclusion.tint.opacity(0.12), in: Capsule())
        } else {
            Text("未检测")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
    }

    private var statusTitle: String {
        if viewModel.installationState == .checking {
            return "正在检测 Codex CLI"
        }

        if viewModel.installationState == .missing {
            return "未安装 Codex CLI"
        }

        if viewModel.isRunning {
            return "正在检测智能状态"
        }

        if viewModel.runs.last?.failureKind == .timedOut {
            return "检测超时"
        }

        if viewModel.errorMessage != nil {
            return "检测无法启动"
        }

        if viewModel.completedCount > 0 {
            return "结论：\(viewModel.conclusion.title)"
        }

        return "智能状态检测"
    }

    private var statusSubtitle: String {
        if let errorMessage = viewModel.errorMessage {
            return errorMessage
        }

        if viewModel.installationState == .checking {
            return "正在查找本机可执行的 codex 命令。"
        }

        if viewModel.installationState == .missing {
            return "需要先安装 Codex CLI。安装说明：\(CodexIntelligenceCheckViewModel.installGuideURL.absoluteString)"
        }

        if let lastRun = viewModel.runs.last,
           lastRun.failureKind == .timedOut,
           let errorMessage = lastRun.errorMessage {
            return errorMessage
        }

        if let executablePath = viewModel.installationState.executablePath, viewModel.completedCount == 0, !viewModel.isRunning {
            let cliDescription = viewModel.cliUpdateState.currentVersion
                .map { "Codex CLI \($0) · \(executablePath)" }
                ?? "已找到 \(executablePath)"

            if let detectedModelName = viewModel.detectedModelName,
               let detectedReasoningEffort = viewModel.detectedReasoningEffort {
                return "\(cliDescription)，默认使用 \(detectedModelName) / \(detectedReasoningEffort.title)。"
            }

            if let detectedModelName = viewModel.detectedModelName {
                return "\(cliDescription)，默认使用配置模型 \(detectedModelName)。"
            }

            if let detectedReasoningEffort = viewModel.detectedReasoningEffort {
                return "\(cliDescription)，默认使用配置推理强度 \(detectedReasoningEffort.title)。"
            }

            return "\(cliDescription)，未配置模型时会使用 Codex CLI 默认模型。"
        }

        if viewModel.isRunning {
            if let currentRunIndex = viewModel.currentRunIndex {
                return "正在运行第 \(currentRunIndex)/\(viewModel.runCount) 个样本，单次最长等待 2 分钟。"
            }

            return "正在准备样本检测。"
        }

        if viewModel.completedCount > 0 {
            return "\(viewModel.conclusionExplanation) 通过 \(viewModel.correctCount)/\(viewModel.completedCount)，平均思考量 \(viewModel.averageReasoningTokensText)。"
        }

        return "手动运行一组轻量样本，检测当前模型状态。"
    }

    private func resultTitle(for run: CodexIntelligenceCheckRun) -> String {
        if run.errorMessage != nil {
            return "错误"
        }

        return run.isCorrect == true ? "通过" : "未通过"
    }

    private func resultIcon(for run: CodexIntelligenceCheckRun) -> String {
        if run.errorMessage != nil {
            return "exclamationmark.triangle.fill"
        }

        return run.isCorrect == true ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private func resultTint(for run: CodexIntelligenceCheckRun) -> Color {
        if run.errorMessage != nil {
            return .red
        }

        return run.isCorrect == true ? .green : .orange
    }

    private func tokenText(for run: CodexIntelligenceCheckRun) -> String {
        let reasoning = run.reasoningOutputTokens.map(UsageFormatters.compactTokens) ?? "--"
        let output = run.outputTokens.map(UsageFormatters.compactTokens) ?? "--"
        let tps = run.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "--"
        return "思考 \(reasoning) · 输出 \(output) · \(String(format: "%.1f", run.elapsedSeconds))s · \(tps) t/s"
    }

    private func detailText(for run: CodexIntelligenceCheckRun) -> String {
        if let errorMessage = run.errorMessage {
            return errorMessage
        }

        return run.isCorrect == true ? "该样本表现正常" : "该样本表现异常"
    }
}

private enum CodexExecutableResolver {
    static func resolve() throws -> String {
        if let path = executableInPath(ProcessInfo.processInfo.environment["PATH"]) {
            return path
        }

        if let path = try? shellCodexPath(), isUsableCandidate(path) {
            return path
        }

        for candidate in fallbackCandidates {
            if isUsableCandidate(candidate) {
                return candidate
            }
        }

        throw CodexIntelligenceCheckError.codexNotFound
    }

    private static func executableInPath(_ pathValue: String?) -> String? {
        guard let pathValue else { return nil }

        for directory in pathValue.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent("codex")
                .path

            if isUsableCandidate(candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func shellCodexPath() throws -> String {
        let process = Process()
        let output = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v codex"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()
        guard process.waitUntilExit(timeout: 5) else { return "" }

        guard process.terminationStatus == 0 else {
            return ""
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func isUsableCandidate(_ path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return !resolvedPath.contains(".app/Contents/Resources/")
    }

    private static var fallbackCandidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.bun/bin/codex"
        ]
    }
}

private enum CodexModelListResolver {
    struct Result {
        var modelOptions: [CodexModelOption]
        var defaultModelDisplayName: String?
        var errorMessage: String?
    }

    private struct ResponseIdentifier: Decodable {
        var id: Int?
    }

    private struct ModelListResponse: Decodable {
        struct ResponseResult: Decodable {
            struct Model: Decodable {
                struct ReasoningEffortOption: Decodable {
                    var reasoningEffort: String?
                }

                var model: String?
                var displayName: String?
                var hidden: Bool?
                var isDefault: Bool?
                var supportedReasoningEfforts: [ReasoningEffortOption]?
                var defaultReasoningEffort: String?
            }

            var data: [Model]
            var nextCursor: String?
        }

        var id: Int?
        var result: ResponseResult?
    }

    static func resolve(
        codexHomePath: String,
        executablePath: String?,
        configuredModel: String?
    ) -> Result {
        guard let executablePath else {
            return Result(modelOptions: [], defaultModelDisplayName: nil, errorMessage: nil)
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHomePath
        process.environment = environment

        do {
            try process.run()
        } catch {
            return Result(
                modelOptions: [],
                defaultModelDisplayName: nil,
                errorMessage: "无法启动 Codex CLI 模型服务：\(error.localizedDescription)"
            )
        }

        defer {
            try? input.fileHandleForWriting.close()
            process.terminateAndWait()
        }

        let deadline = Date().addingTimeInterval(8)
        var responseBuffer: [UInt8] = []

        guard writeJSON(
            [
                "method": "initialize",
                "id": 0,
                "params": [
                    "clientInfo": [
                        "name": "codex_usage",
                        "title": "CodexUsage",
                        "version": "0.1.0"
                    ]
                ]
            ],
            to: input.fileHandleForWriting
        ), readResponseLine(
            id: 0,
            from: output.fileHandleForReading,
            buffer: &responseBuffer,
            deadline: deadline
        ) != nil,
        writeJSON(
            ["method": "initialized", "params": [:]],
            to: input.fileHandleForWriting
        ) else {
            return Result(
                modelOptions: [],
                defaultModelDisplayName: nil,
                errorMessage: "初始化 Codex CLI 模型服务超时。"
            )
        }

        var models: [ModelListResponse.ResponseResult.Model] = []
        var cursor: String?
        var requestID = 1
        var listErrorMessage: String?

        repeat {
            let cursorValue: Any = cursor ?? NSNull()
            guard writeJSON(
                [
                    "method": "model/list",
                    "id": requestID,
                    "params": [
                        "cursor": cursorValue,
                        "limit": 100,
                        "includeHidden": true
                    ]
                ],
                to: input.fileHandleForWriting
            ), let responseLine = readResponseLine(
                id: requestID,
                from: output.fileHandleForReading,
                buffer: &responseBuffer,
                deadline: deadline
            ), let response = try? JSONDecoder().decode(ModelListResponse.self, from: responseLine),
            let result = response.result else {
                listErrorMessage = "读取 Codex CLI 模型列表失败或超时。"
                break
            }

            models.append(contentsOf: result.data)
            cursor = result.nextCursor
            requestID += 1
        } while cursor != nil

        var seenModels = Set<String>()
        var defaultModelDisplayName: String?
        let modelOptions = models.compactMap { model -> CodexModelOption? in
            guard let slug = model.model?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !slug.isEmpty,
                  model.hidden != true || slug == configuredModel || model.isDefault == true,
                  seenModels.insert(slug).inserted else {
                return nil
            }

            let displayName = model.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedDisplayName = displayName.flatMap { $0.isEmpty ? nil : $0 } ?? slug

            if model.isDefault == true {
                defaultModelDisplayName = resolvedDisplayName
            }

            var seenEfforts = Set<CodexReasoningEffort>()
            var supportedReasoningEfforts = (model.supportedReasoningEfforts ?? []).compactMap {
                $0.reasoningEffort
                    .flatMap(CodexReasoningEffort.init(rawValue:))
            }.filter { seenEfforts.insert($0).inserted }
            let defaultReasoningEffort = model.defaultReasoningEffort
                .flatMap(CodexReasoningEffort.init(rawValue:))

            if supportedReasoningEfforts.isEmpty,
               let defaultReasoningEffort {
                supportedReasoningEfforts = [defaultReasoningEffort]
            }

            return CodexModelOption(
                slug: slug,
                displayName: resolvedDisplayName,
                supportedReasoningEfforts: supportedReasoningEfforts,
                defaultReasoningEffort: defaultReasoningEffort,
                isDefault: model.isDefault == true,
                isConfiguredFallback: model.hidden == true && slug == configuredModel
            )
        }

        return Result(
            modelOptions: modelOptions,
            defaultModelDisplayName: defaultModelDisplayName,
            errorMessage: listErrorMessage
        )
    }

    private static func writeJSON(_ object: [String: Any], to fileHandle: FileHandle) -> Bool {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else {
            return false
        }

        data.append(0x0A)
        do {
            try fileHandle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    private static func readResponseLine(
        id: Int,
        from fileHandle: FileHandle,
        buffer: inout [UInt8],
        deadline: Date
    ) -> Data? {
        while true {
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newlineIndex])
                buffer.removeFirst(newlineIndex + 1)

                if let identifier = try? JSONDecoder().decode(ResponseIdentifier.self, from: line),
                   identifier.id == id {
                    return line
                }
            }

            let remainingSeconds = deadline.timeIntervalSinceNow
            guard remainingSeconds > 0 else { return nil }

            var descriptor = pollfd(
                fd: fileHandle.fileDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let timeoutMilliseconds = Int32(min(remainingSeconds * 1_000, Double(Int32.max)))
            let pollResult = poll(&descriptor, 1, max(1, timeoutMilliseconds))

            if pollResult == 0 {
                return nil
            }

            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                return nil
            }

            var chunk = [UInt8](repeating: 0, count: 8_192)
            let bytesRead = chunk.withUnsafeMutableBytes { bytes in
                Darwin.read(fileHandle.fileDescriptor, bytes.baseAddress, bytes.count)
            }

            guard bytesRead > 0 else { return nil }
            buffer.append(contentsOf: chunk.prefix(bytesRead))
        }
    }

}

private enum CodexConfigModelResolver {
    struct Defaults {
        var model: String?
        var reasoningEffort: CodexReasoningEffort?
        var modelOptions: [CodexModelOption]
        var cliDefaultModelDisplayName: String?
        var modelListErrorMessage: String?
    }

    static func resolveConfiguredDefaults(
        codexHomePath: String,
        executablePath: String?
    ) -> Defaults {
        let configURL = URL(fileURLWithPath: codexHomePath)
            .appendingPathComponent("config.toml")
        let config = try? String(contentsOf: configURL, encoding: .utf8)
        let model = config.flatMap { parseTopLevelStringValue(named: "model", in: $0) }
        let reasoningEffort = config
            .flatMap { parseTopLevelStringValue(named: "model_reasoning_effort", in: $0) }
            .flatMap(CodexReasoningEffort.init(rawValue:))
        let modelList = CodexModelListResolver.resolve(
            codexHomePath: codexHomePath,
            executablePath: executablePath,
            configuredModel: model
        )

        return Defaults(
            model: model,
            reasoningEffort: reasoningEffort,
            modelOptions: modelList.modelOptions,
            cliDefaultModelDisplayName: modelList.defaultModelDisplayName,
            modelListErrorMessage: modelList.errorMessage
        )
    }

    private static func parseTopLevelStringValue(named key: String, in toml: String) -> String? {
        for rawLine in toml.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            if line.hasPrefix("[") {
                return nil
            }

            guard line.hasPrefix("\(key)") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == key else {
                continue
            }

            return parseStringLiteral(String(parts[1]))
        }

        return nil
    }

    private static func parseStringLiteral(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quote = trimmed.first, quote == "\"" || quote == "'" else {
            return nil
        }

        var result = ""
        var isEscaped = false

        for character in trimmed.dropFirst() {
            if isEscaped {
                result.append(character)
                isEscaped = false
                continue
            }

            if quote == "\"" && character == "\\" {
                isEscaped = true
                continue
            }

            if character == quote {
                let value = result.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }

            result.append(character)
        }

        return nil
    }
}

private enum CodexIntelligenceCheckRunner {
    private static let prompt = """
    不使用任何外部工具回答以下问题：
    在一个黑色的袋子里放有三种口味的糖果，每种糖果有两种不同的形状（圆形和五角星形，不同的形状靠手感可以分辨）。现已知不同口味的糖和不同形状的数量统计如下表。参赛者需要在活动前决定摸出的糖果数目，那么，最少取出多少个糖果才能保证手中同时拥有不同形状的苹果味和桃子味的糖？（同时手中有圆形苹果味匹配五角星桃子味糖果，或者有圆形桃子味匹配五角星苹果味糖果都满足要求）

              苹果味  桃子味  西瓜味
    圆形        7      9      8
    五角星形    7      6      4
    """

    private static let answerPattern = try? NSRegularExpression(pattern: "(^|[^0-9])21([^0-9]|$)")

    static func runOne(
        index: Int,
        executablePath: String,
        model: String?,
        effort: CodexReasoningEffort?,
        processController: CodexProcessLifetimeController
    ) -> CodexIntelligenceCheckRun {
        let start = Date()

        do {
            let result = try runCodex(
                executablePath: executablePath,
                model: model,
                effort: effort,
                processController: processController
            )
            let elapsed = Date().timeIntervalSince(start)

            return CodexIntelligenceCheckRun(
                index: index,
                answer: result.answer,
                inputTokens: result.inputTokens,
                outputTokens: result.outputTokens,
                reasoningOutputTokens: result.reasoningOutputTokens,
                elapsedSeconds: elapsed,
                isCorrect: isCorrectAnswer(result.answer),
                errorMessage: nil,
                failureKind: nil
            )
        } catch let error as CodexProcessLifetimeError {
            let failureKind: CodexIntelligenceCheckFailureKind
            let message: String

            switch error {
            case .cancelled:
                failureKind = .cancelled
                message = "检测已取消，Codex CLI 已终止。"
            case .timedOut:
                failureKind = .timedOut
                message = "单次检测超过 2 分钟，已自动终止 Codex CLI。"
            }

            return CodexIntelligenceCheckRun(
                index: index,
                answer: "",
                inputTokens: nil,
                outputTokens: nil,
                reasoningOutputTokens: nil,
                elapsedSeconds: Date().timeIntervalSince(start),
                isCorrect: nil,
                errorMessage: message,
                failureKind: failureKind
            )
        } catch {
            return CodexIntelligenceCheckRun(
                index: index,
                answer: "",
                inputTokens: nil,
                outputTokens: nil,
                reasoningOutputTokens: nil,
                elapsedSeconds: Date().timeIntervalSince(start),
                isCorrect: nil,
                errorMessage: error.localizedDescription,
                failureKind: .command
            )
        }
    }

    private static func runCodex(
        executablePath: String,
        model: String?,
        effort: CodexReasoningEffort?,
        processController: CodexProcessLifetimeController
    ) throws -> CodexCommandResult {
        let process = Process()
        let input = Pipe()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageCheck-\(UUID().uuidString)", isDirectory: true)
        let outputURL = temporaryDirectory.appendingPathComponent("stdout.jsonl")
        let errorURL = temporaryDirectory.appendingPathComponent("stderr.txt")

        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)

        defer {
            try? outputHandle.close()
            try? errorHandle.close()
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        process.arguments = arguments(model: model, effort: effort)

        try process.run()
        guard processController.register(process) else {
            throw CodexProcessLifetimeError.cancelled
        }

        if let data = prompt.data(using: .utf8) {
            input.fileHandleForWriting.write(data)
        }
        try? input.fileHandleForWriting.close()

        try processController.waitForExit(
            of: process,
            timeout: intelligenceCheckSampleTimeout
        )

        try? outputHandle.synchronize()
        try? errorHandle.synchronize()

        let outputData = try Data(contentsOf: outputURL)
        let errorData = try Data(contentsOf: errorURL)
        let outputText = String(data: outputData, encoding: .utf8) ?? ""
        let errorText = String(data: errorData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw CodexIntelligenceCheckError.codexFailed(errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return parseOutput(outputText)
    }

    private static func arguments(model: String?, effort: CodexReasoningEffort?) -> [String] {
        var values = [
            "exec",
            "--json",
            "--skip-git-repo-check",
            "--ephemeral",
            "-s",
            "read-only",
            "--disable",
            "memories"
        ]

        if let effort {
            values.append(contentsOf: ["-c", "model_reasoning_effort=\(effort.rawValue)"])
        }

        if let model {
            values.append(contentsOf: ["-m", model])
        }

        return values
    }

    private static func parseOutput(_ output: String) -> CodexCommandResult {
        var answer = ""
        var inputTokens: Int?
        var outputTokens: Int?
        var reasoningOutputTokens: Int?

        for line in output.split(whereSeparator: \.isNewline) {
            guard line.first == "{",
                  let data = String(line).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else {
                continue
            }

            if type == "item.completed",
               let item = event["item"] as? [String: Any],
               item["type"] as? String == "agent_message",
               let text = item["text"] as? String {
                answer = text
            } else if type == "turn.completed",
                      let usage = event["usage"] as? [String: Any] {
                inputTokens = integerValue(usage["input_tokens"])
                outputTokens = integerValue(usage["output_tokens"])
                reasoningOutputTokens = integerValue(usage["reasoning_output_tokens"])
            }
        }

        return CodexCommandResult(
            answer: answer,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens
        )
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }

        if let value = value as? NSNumber {
            return value.intValue
        }

        return nil
    }

    private static func isCorrectAnswer(_ answer: String) -> Bool {
        guard let answerPattern else { return answer.contains("21") }
        let range = NSRange(answer.startIndex..<answer.endIndex, in: answer)
        return answerPattern.firstMatch(in: answer, range: range) != nil
    }
}

private struct CodexCommandResult {
    var answer: String
    var inputTokens: Int?
    var outputTokens: Int?
    var reasoningOutputTokens: Int?
}

private enum CodexIntelligenceCheckError: LocalizedError {
    case codexNotFound
    case codexFailed(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            "找不到 codex 命令，请确认 Codex CLI 已安装并能在终端运行。"
        case let .codexFailed(message):
            message.isEmpty ? "codex exec 执行失败。" : message
        }
    }
}
