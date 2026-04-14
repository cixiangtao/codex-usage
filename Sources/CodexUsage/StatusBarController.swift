import AppKit
import Combine
import ImageIO
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let settings: AppSettings
    private let viewModel: DashboardViewModel
    private(set) var statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []
    private var animationTimer: Timer?
    private var animationGeneration = 0

    init(
        settings: AppSettings,
        viewModel: DashboardViewModel,
        updateViewModel: UpdateCheckViewModel
    ) {
        self.settings = settings
        self.viewModel = viewModel
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.imageHugsTitle = true
            button.toolTip = "Codex Usage"
        }

        let content = MenuBarContent(
            viewModel: viewModel,
            settings: settings,
            updateViewModel: updateViewModel
        )
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)

        popover.contentViewController = NSHostingController(rootView: content)
        popover.behavior = .transient
        popover.animates = true

        settings.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusItem()
                }
            }
            .store(in: &cancellables)

        viewModel.$snapshot
            .sink { [weak self] _ in
                self?.updateStatusItem()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .closeCodexUsageStatusPopover)
            .sink { [weak self] _ in
                self?.popover.performClose(nil)
            }
            .store(in: &cancellables)

        updateStatusItem()
    }

    @objc
    private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        resizePopover()
        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY
        )
    }

    func shutdown() {
        stopAnimation()
        popover.close()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        let health = UsageHealth.evaluate(
            snapshot: viewModel.snapshot,
            warning: settings.warningThresholdPercent,
            critical: settings.criticalThresholdPercent
        )
        let label = StatusBarLabel(
            snapshot: viewModel.snapshot,
            health: health,
            showPrimary: settings.showPrimaryWindowInStatusBar,
            showSecondary: settings.showSecondaryWindowInStatusBar,
            showLabels: settings.showStatusBarWindowLabels
        )

        button.title = label.labelText
        button.imagePosition = label.labelText.isEmpty ? .imageOnly : .imageLeading
        button.toolTip = "Codex Usage · \(settings.selectedStatusBarIcon.title)"

        stopAnimation()
        render(
            descriptor: settings.selectedStatusBarIcon,
            health: health,
            animates: settings.animateStatusBarIcon
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        resizePopover()
    }

    private func render(
        descriptor: StatusBarIconDescriptor,
        health: UsageHealth,
        animates: Bool
    ) {
        guard let button = statusItem.button else { return }

        switch descriptor.source {
        case .adaptive:
            let image = NSImage(
                systemSymbolName: adaptiveSymbolName(for: health),
                accessibilityDescription: descriptor.title
            )
            image?.isTemplate = true
            button.image = image
        case let .pixel(style):
            button.image = PixelStatusBarIconRenderer.image(style: style, frame: 0)
            guard animates else { return }
            startPixelAnimation(style: style)
        case let .image(url):
            guard let animation = StatusBarAnimationLoader.animation(at: url) else {
                button.image = NSImage(
                    systemSymbolName: "photo.badge.exclamationmark",
                    accessibilityDescription: "图标不可用"
                )
                return
            }

            button.image = animation.frames[0]
            guard animates, animation.frames.count > 1 else { return }
            startImageAnimation(animation)
        }
    }

    private func startPixelAnimation(style: StatusBarIconStyle) {
        let generation = animationGeneration
        var frame = 0
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, generation == self.animationGeneration else { return }
                frame += 1
                self.statusItem.button?.image = PixelStatusBarIconRenderer.image(
                    style: style,
                    frame: frame
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func startImageAnimation(_ animation: StatusBarAnimation) {
        scheduleImageFrame(animation, index: 1, generation: animationGeneration)
    }

    private func scheduleImageFrame(
        _ animation: StatusBarAnimation,
        index: Int,
        generation: Int
    ) {
        let previousIndex = index == 0 ? animation.frames.count - 1 : index - 1
        let timer = Timer(
            timeInterval: animation.durations[previousIndex],
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, generation == self.animationGeneration else { return }
                self.statusItem.button?.image = animation.frames[index]
                self.scheduleImageFrame(
                    animation,
                    index: (index + 1) % animation.frames.count,
                    generation: generation
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimation() {
        animationGeneration += 1
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func resizePopover() {
        guard let contentView = popover.contentViewController?.view else { return }
        contentView.layoutSubtreeIfNeeded()

        let fittingHeight = contentView.fittingSize.height
        let screenHeight = statusItem.button?.window?.screen?.visibleFrame.height ?? 720
        popover.contentSize = NSSize(
            width: 360,
            height: min(max(fittingHeight, 220), screenHeight - 60)
        )
    }

    private func adaptiveSymbolName(for health: UsageHealth) -> String {
        switch health {
        case .unavailable:
            "bolt.trianglebadge.exclamationmark"
        case .normal:
            AppIcon.statusSymbolName
        case .warning:
            "bolt.badge.clock"
        case .critical:
            "exclamationmark.triangle"
        }
    }
}

struct StatusBarAnimation: @unchecked Sendable {
    let frames: [NSImage]
    let durations: [TimeInterval]
}

@MainActor
enum StatusBarAnimationLoader {
    private static var cache: [URL: StatusBarAnimation] = [:]

    static func animation(at url: URL) -> StatusBarAnimation? {
        if let animation = cache[url] {
            return animation
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        var frames: [NSImage] = []
        var durations: [TimeInterval] = []

        for index in 0..<CGImageSourceGetCount(source) {
            guard
                let cgImage = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    index,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 36
                    ] as CFDictionary
                )
            else {
                continue
            }

            frames.append(statusBarImage(from: cgImage))
            durations.append(frameDuration(source: source, index: index))
        }

        guard !frames.isEmpty else { return nil }
        let animation = StatusBarAnimation(frames: frames, durations: durations)
        cache[url] = animation
        return animation
    }

    private static func statusBarImage(from cgImage: CGImage) -> NSImage {
        let sourceSize = NSSize(width: cgImage.width, height: cgImage.height)
        let scale = min(18 / sourceSize.width, 18 / sourceSize.height)
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(
                width: max(1, floor(sourceSize.width * scale)),
                height: max(1, floor(sourceSize.height * scale))
            )
        )
        image.isTemplate = false
        return image
    }

    private static func frameDuration(
        source: CGImageSource,
        index: Int
    ) -> TimeInterval {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any],
            let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else {
            return 0.1
        }

        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? NSNumber
        return max(unclamped?.doubleValue ?? clamped?.doubleValue ?? 0.1, 0.02)
    }
}

extension Notification.Name {
    static let closeCodexUsageStatusPopover = Notification.Name(
        "closeCodexUsageStatusPopover"
    )
}
