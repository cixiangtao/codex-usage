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
    private let cpuUsageMonitor = SystemCPUUsageMonitor()
    private var animationSpeedMultiplier = 1.0

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

        NotificationCenter.default.publisher(for: .codexUsagePopoverContentSizeDidChange)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.resizePopover()
                }
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
        let descriptor = settings.selectedStatusBarIcon
        button.toolTip = "Codex Usage · \(descriptor.title)"

        stopAnimation()
        render(
            descriptor: descriptor,
            health: health,
            animates: settings.animateStatusBarIcon
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            followsCPU: settings.statusBarAnimationFollowsCPU,
            baseSpeed: settings.statusBarAnimationBaseSpeed(for: descriptor.id)
        )
        resizePopover()
    }

    private func render(
        descriptor: StatusBarIconDescriptor,
        health: UsageHealth,
        animates: Bool,
        followsCPU: Bool,
        baseSpeed: Double
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
            startCPULinkIfNeeded(followsCPU)
            startPixelAnimation(
                style: style,
                followsCPU: followsCPU,
                baseSpeed: baseSpeed
            )
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
            startCPULinkIfNeeded(followsCPU)
            startImageAnimation(
                animation,
                followsCPU: followsCPU,
                baseSpeed: baseSpeed
            )
        }
    }

    private func startCPULinkIfNeeded(_ followsCPU: Bool) {
        guard followsCPU else { return }
        cpuUsageMonitor.start { [weak self] usage in
            self?.animationSpeedMultiplier =
                StatusBarAnimationTiming.speedMultiplier(forCPUUsage: usage)
        }
    }

    private func startPixelAnimation(
        style: StatusBarIconStyle,
        followsCPU: Bool,
        baseSpeed: Double
    ) {
        schedulePixelFrame(
            style: style,
            frame: 1,
            generation: animationGeneration,
            followsCPU: followsCPU,
            baseSpeed: baseSpeed
        )
    }

    private func schedulePixelFrame(
        style: StatusBarIconStyle,
        frame: Int,
        generation: Int,
        followsCPU: Bool,
        baseSpeed: Double
    ) {
        let timer = Timer(
            timeInterval: animationInterval(
                baseDuration: 0.5,
                followsCPU: followsCPU,
                baseSpeed: baseSpeed
            ),
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, generation == self.animationGeneration else { return }
                self.statusItem.button?.image = PixelStatusBarIconRenderer.image(
                    style: style,
                    frame: frame
                )
                self.schedulePixelFrame(
                    style: style,
                    frame: frame + 1,
                    generation: generation,
                    followsCPU: followsCPU,
                    baseSpeed: baseSpeed
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func startImageAnimation(
        _ animation: StatusBarAnimation,
        followsCPU: Bool,
        baseSpeed: Double
    ) {
        scheduleImageFrame(
            animation,
            index: 1,
            generation: animationGeneration,
            followsCPU: followsCPU,
            baseSpeed: baseSpeed
        )
    }

    private func scheduleImageFrame(
        _ animation: StatusBarAnimation,
        index: Int,
        generation: Int,
        followsCPU: Bool,
        baseSpeed: Double
    ) {
        let previousIndex = index == 0 ? animation.frames.count - 1 : index - 1
        let timer = Timer(
            timeInterval: animationInterval(
                baseDuration: animation.durations[previousIndex],
                followsCPU: followsCPU,
                baseSpeed: baseSpeed
            ),
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, generation == self.animationGeneration else { return }
                self.statusItem.button?.image = animation.frames[index]
                self.scheduleImageFrame(
                    animation,
                    index: (index + 1) % animation.frames.count,
                    generation: generation,
                    followsCPU: followsCPU,
                    baseSpeed: baseSpeed
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
        cpuUsageMonitor.stop()
        animationSpeedMultiplier = 1
    }

    private func animationInterval(
        baseDuration: TimeInterval,
        followsCPU: Bool,
        baseSpeed: Double
    ) -> TimeInterval {
        StatusBarAnimationTiming.interval(
            baseDuration: baseDuration,
            baseSpeedMultiplier: baseSpeed,
            cpuSpeedMultiplier: animationSpeedMultiplier,
            followsCPU: followsCPU
        )
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
    let usesTemplateRendering: Bool
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
        var contrastSamples = StatusBarContrastSamples()

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

            if index < 8 {
                contrastSamples.add(cgImage)
            }
            frames.append(statusBarImage(from: cgImage))
            durations.append(frameDuration(source: source, index: index))
        }

        guard !frames.isEmpty else { return nil }
        let usesTemplateRendering = contrastSamples.prefersTemplateRendering
        frames.forEach { $0.isTemplate = usesTemplateRendering }
        let animation = StatusBarAnimation(
            frames: frames,
            durations: durations,
            usesTemplateRendering: usesTemplateRendering
        )
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

private struct StatusBarContrastSamples {
    private var visiblePixelCount = 0
    private var darkPixelCount = 0
    private var colorfulPixelCount = 0
    private var totalLuminance = 0.0

    var prefersTemplateRendering: Bool {
        guard visiblePixelCount >= 12 else { return false }

        let visibleCount = Double(visiblePixelCount)
        let darkFraction = Double(darkPixelCount) / visibleCount
        let colorfulFraction = Double(colorfulPixelCount) / visibleCount
        let averageLuminance = totalLuminance / visibleCount

        return darkFraction >= 0.62
            && colorfulFraction <= 0.12
            && averageLuminance <= 0.42
    }

    mutating func add(_ image: CGImage) {
        let sampleWidth = min(image.width, 24)
        let sampleHeight = min(image.height, 24)
        guard sampleWidth > 0, sampleHeight > 0 else { return }

        var pixels = [UInt8](
            repeating: 0,
            count: sampleWidth * sampleHeight * 4
        )
        let bytesPerRow = sampleWidth * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue

        let drewImage = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: sampleWidth,
                height: sampleHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }

            context.interpolationQuality = .medium
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight)
            )
            return true
        }
        guard drewImage else { return }

        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = pixels[offset + 3]
            guard alpha >= 32 else { continue }

            let red = Double(pixels[offset]) / 255
            let green = Double(pixels[offset + 1]) / 255
            let blue = Double(pixels[offset + 2]) / 255
            let luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722
            let chroma = max(red, green, blue) - min(red, green, blue)

            visiblePixelCount += 1
            totalLuminance += luminance
            if luminance <= 0.45 {
                darkPixelCount += 1
            }
            if chroma >= 0.18 {
                colorfulPixelCount += 1
            }
        }
    }
}

extension Notification.Name {
    static let closeCodexUsageStatusPopover = Notification.Name(
        "closeCodexUsageStatusPopover"
    )
    static let codexUsagePopoverContentSizeDidChange = Notification.Name(
        "codexUsagePopoverContentSizeDidChange"
    )
}
