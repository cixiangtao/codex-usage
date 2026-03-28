import AppKit
import SwiftUI

@MainActor
final class SettingsWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowPresenter()

    private static let contentSize = NSSize(width: 560, height: 640)

    private let intelligenceCheckViewModel = CodexIntelligenceCheckViewModel()
    private var window: NSWindow?
    private var updatePreparationTask: Task<Void, Never>?
    private var intelligencePreparationTask: Task<Void, Never>?

    private override init() {
        super.init()
    }

    func show(settings: AppSettings, viewModel: DashboardViewModel, updateViewModel: UpdateCheckViewModel) {
        if let window {
            show(window, floatsAboveOtherApps: false)
            return
        }

        updatePreparationTask?.cancel()
        updatePreparationTask = Task { [weak updateViewModel] in
            await updateViewModel?.checkForPresentedSurface()
        }

        intelligencePreparationTask?.cancel()
        let intelligenceCheckViewModel = intelligenceCheckViewModel
        let codexHomePath = settings.codexHomePath
        intelligencePreparationTask = Task { [weak intelligenceCheckViewModel] in
            await intelligenceCheckViewModel?.prepareForPresentation(codexHomePath: codexHomePath)
        }

        let hostingController = NSHostingController(
            rootView: SettingsView(
                settings: settings,
                viewModel: viewModel,
                updateViewModel: updateViewModel,
                intelligenceCheckViewModel: intelligenceCheckViewModel
            )
            .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        )

        let nextWindow = NSWindow(contentViewController: hostingController)
        nextWindow.setContentSize(Self.contentSize)
        nextWindow.title = "设置"
        nextWindow.styleMask = [.titled, .closable, .miniaturizable]
        nextWindow.isReleasedWhenClosed = false
        nextWindow.collectionBehavior = [.moveToActiveSpace]
        nextWindow.delegate = self
        nextWindow.center()

        window = nextWindow
        show(nextWindow, floatsAboveOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        cancelIntelligenceCheck()

        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else {
            return
        }

        closingWindow.delegate = nil
        closingWindow.contentViewController = nil
        window = nil
    }

    func cancelIntelligenceCheck() {
        updatePreparationTask?.cancel()
        updatePreparationTask = nil
        intelligencePreparationTask?.cancel()
        intelligencePreparationTask = nil
        intelligenceCheckViewModel.cancel()
    }

    private func show(_ window: NSWindow, floatsAboveOtherApps: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        window.level = floatsAboveOtherApps ? .floating : .normal
        window.makeKeyAndOrderFront(nil)

        guard floatsAboveOtherApps else { return }

        window.orderFrontRegardless()
        DispatchQueue.main.async { [weak window] in
            window?.level = .normal
        }
    }
}
