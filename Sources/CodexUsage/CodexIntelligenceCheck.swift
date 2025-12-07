import Foundation
import AppKit
import SwiftUI

enum CodexReasoningEffort: String, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low:
            "low"
        case .medium:
            "medium"
        case .high:
            "high"
        case .xhigh:
            "xhigh"
        }
    }
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

    var tokensPerSecond: Double? {
        guard let outputTokens, elapsedSeconds > 0 else { return nil }
        return Double(outputTokens) / elapsedSeconds
    }
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

    @Published var modelName = ""
    @Published private(set) var detectedModelName: String?
    @Published private(set) var detectedReasoningEffort: CodexReasoningEffort?
    @Published var reasoningEffort: CodexReasoningEffort = .medium
    @Published var runCount = 3
    @Published private(set) var runs: [CodexIntelligenceCheckRun] = []
    @Published private(set) var historyEntries: [CodexIntelligenceCheckHistoryEntry]
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var installationState: CodexCLIInstallationState = .unknown

    private var task: Task<Void, Never>?
    private var hasLoadedConfiguredModel = false
    private let historyStore: CodexIntelligenceCheckHistoryStore

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
        !isRunning && installationState.isInstalled
    }

    func checkInstallationIfNeeded(codexHomePath: String) async {
        await loadConfiguredModelIfNeeded(codexHomePath: codexHomePath)

        if case .unknown = installationState {
            await checkInstallation()
        }
    }

    func loadConfiguredModelIfNeeded(codexHomePath: String) async {
        guard !hasLoadedConfiguredModel else { return }
        hasLoadedConfiguredModel = true

        let configuredDefaults = await Task.detached(priority: .utility) {
            CodexConfigModelResolver.resolveConfiguredDefaults(codexHomePath: codexHomePath)
        }.value

        detectedModelName = configuredDefaults.model
        detectedReasoningEffort = configuredDefaults.reasoningEffort

        if let configuredModel = configuredDefaults.model,
           modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            modelName = configuredModel
        }

        if let configuredReasoningEffort = configuredDefaults.reasoningEffort,
           reasoningEffort == .medium {
            reasoningEffort = configuredReasoningEffort
        }
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

        task = Task { [weak self] in
            guard let self else { return }

            for index in 1...tests {
                if Task.isCancelled { break }

                let run = await Task.detached(priority: .userInitiated) {
                    CodexIntelligenceCheckRunner.runOne(
                        index: index,
                        executablePath: executablePath,
                        model: selectedModel,
                        effort: effort
                    )
                }.value

                if Task.isCancelled { break }
                runs.append(run)
            }

            isRunning = false
            recordHistoryIfUseful(model: selectedModel, effort: effort, requestedCount: tests)
        }
    }

    private func recordHistoryIfUseful(model: String?, effort: CodexReasoningEffort, requestedCount: Int) {
        let completedRuns = runs.filter { $0.isCorrect != nil }
        guard !completedRuns.isEmpty else { return }

        let correctCount = completedRuns.filter { $0.isCorrect == true }.count
        let reasoningValues = completedRuns.compactMap(\.reasoningOutputTokens)
        let tpsValues = completedRuns.compactMap(\.tokensPerSecond)

        let entry = CodexIntelligenceCheckHistoryEntry(
            id: UUID(),
            capturedAt: Date(),
            modelName: model ?? detectedModelName ?? "Codex CLI 默认模型",
            reasoningEffort: effort.title,
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
            statusRow
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
        .task {
            await viewModel.checkInstallationIfNeeded(codexHomePath: codexHomePath)
        }
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

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("本地默认模型", text: $viewModel.modelName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.isRunning)

                Stepper("\(viewModel.runCount) 次", value: $viewModel.runCount, in: 1...10)
                    .frame(width: 92, alignment: .trailing)
                    .disabled(viewModel.isRunning)
            }

            Picker("推理强度", selection: $viewModel.reasoningEffort) {
                ForEach(CodexReasoningEffort.allCases) { effort in
                    Text(effort.title).tag(effort)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .disabled(viewModel.isRunning)

            HStack(spacing: 8) {
                Button {
                    viewModel.start()
                } label: {
                    Label {
                        Text(viewModel.isRunning ? "检测中" : "开始检测")
                    } icon: {
                        if viewModel.isRunning {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "play.fill")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!viewModel.canStart)

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
                            await viewModel.checkInstallation()
                        }
                    } label: {
                        Label("重新检测", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.isRunning || viewModel.installationState == .checking)
                }

                Spacer()
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

        if let executablePath = viewModel.installationState.executablePath, viewModel.completedCount == 0, !viewModel.isRunning {
            if let detectedModelName = viewModel.detectedModelName,
               let detectedReasoningEffort = viewModel.detectedReasoningEffort {
                return "已找到 \(executablePath)，默认使用 \(detectedModelName) / \(detectedReasoningEffort.title)。"
            }

            if let detectedModelName = viewModel.detectedModelName {
                return "已找到 \(executablePath)，默认使用配置模型 \(detectedModelName)。"
            }

            if let detectedReasoningEffort = viewModel.detectedReasoningEffort {
                return "已找到 \(executablePath)，默认使用配置推理强度 \(detectedReasoningEffort.title)。"
            }

            return "已找到 \(executablePath)，未配置模型时会使用 Codex CLI 默认模型。"
        }

        if viewModel.isRunning {
            return "已完成 \(viewModel.runs.count)/\(viewModel.runCount)，正在运行样本检测。"
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

        if let path = try? shellCodexPath(), !path.isEmpty {
            return path
        }

        for candidate in fallbackCandidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
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

            if FileManager.default.isExecutableFile(atPath: candidate) {
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
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return ""
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

private enum CodexConfigModelResolver {
    struct Defaults {
        var model: String?
        var reasoningEffort: CodexReasoningEffort?
    }

    static func resolveConfiguredDefaults(codexHomePath: String) -> Defaults {
        let configURL = URL(fileURLWithPath: codexHomePath)
            .appendingPathComponent("config.toml")

        guard let config = try? String(contentsOf: configURL, encoding: .utf8) else {
            return Defaults(model: nil, reasoningEffort: nil)
        }

        let model = parseTopLevelStringValue(named: "model", in: config)
        let reasoningEffort = parseTopLevelStringValue(named: "model_reasoning_effort", in: config)
            .flatMap(CodexReasoningEffort.init(rawValue:))

        return Defaults(model: model, reasoningEffort: reasoningEffort)
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
        effort: CodexReasoningEffort
    ) -> CodexIntelligenceCheckRun {
        let start = Date()

        do {
            let result = try runCodex(
                executablePath: executablePath,
                model: model,
                effort: effort
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
                errorMessage: nil
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
                errorMessage: error.localizedDescription
            )
        }
    }

    private static func runCodex(
        executablePath: String,
        model: String?,
        effort: CodexReasoningEffort
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

        if let data = prompt.data(using: .utf8) {
            input.fileHandleForWriting.write(data)
        }
        try? input.fileHandleForWriting.close()

        process.waitUntilExit()

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

    private static func arguments(model: String?, effort: CodexReasoningEffort) -> [String] {
        var values = [
            "exec",
            "--json",
            "--skip-git-repo-check",
            "--ephemeral",
            "-s",
            "read-only",
            "--disable",
            "memories",
            "-c",
            "model_reasoning_effort=\(effort.rawValue)"
        ]

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
