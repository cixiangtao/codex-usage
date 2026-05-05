import AppKit
import SwiftUI

enum StatusBarIconStyle: String, CaseIterable, Identifiable {
    case adaptive
    case pixelBot
    case pixelSpark
    case pixelPulse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .adaptive:
            "跟随状态"
        case .pixelBot:
            "像素机器人"
        case .pixelSpark:
            "像素火花"
        case .pixelPulse:
            "像素脉冲"
        }
    }

    var subtitle: String {
        switch self {
        case .adaptive:
            "随额度健康状态变化"
        case .pixelBot:
            "偶尔眨眼的像素头像"
        case .pixelSpark:
            "轻微闪烁的四角星"
        case .pixelPulse:
            "向外呼吸的能量环"
        }
    }

    var accessibilityLabel: String {
        "Codex Usage，\(title)"
    }
}

struct StatusBarIconView: View {
    var descriptor: StatusBarIconDescriptor
    var health: UsageHealth
    var animates = false
    var baseSpeed = 1.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        descriptor: StatusBarIconDescriptor,
        health: UsageHealth,
        animates: Bool = false,
        baseSpeed: Double = 1
    ) {
        self.descriptor = descriptor
        self.health = health
        self.animates = animates
        self.baseSpeed = baseSpeed
    }

    init(
        style: StatusBarIconStyle,
        health: UsageHealth,
        animates: Bool = false,
        baseSpeed: Double = 1
    ) {
        self.init(
            descriptor: StatusBarIconCatalog.builtIns.first { $0.id == style.rawValue }
                ?? StatusBarIconCatalog.builtIns[0],
            health: health,
            animates: animates,
            baseSpeed: baseSpeed
        )
    }

    var body: some View {
        switch descriptor.source {
        case .adaptive:
            Image(systemName: adaptiveSymbolName)
                .accessibilityLabel(accessibilityLabel)
        case let .pixel(style):
            PixelStatusBarImageView(
                style: style,
                animates: animates && !reduceMotion,
                baseSpeed: baseSpeed
            )
            .frame(width: 14, height: 14)
            .accessibilityLabel(accessibilityLabel)
        case let .image(url):
            AnimatedStatusBarImageView(
                imageURL: url,
                animates: animates && !reduceMotion,
                baseSpeed: baseSpeed
            )
            .frame(width: 18, height: 16)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    private var accessibilityLabel: String {
        "Codex Usage，\(descriptor.title)"
    }

    private var adaptiveSymbolName: String {
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

private struct PixelStatusBarImageView: NSViewRepresentable {
    var style: StatusBarIconStyle
    var animates: Bool
    var baseSpeed: Double

    func makeNSView(context: Context) -> PixelAnimationImageView {
        let imageView = PixelAnimationImageView()
        imageView.imageScaling = .scaleProportionallyDown
        return imageView
    }

    func updateNSView(_ imageView: PixelAnimationImageView, context: Context) {
        imageView.configure(
            style: style,
            animates: animates,
            baseSpeed: baseSpeed
        )
    }

    static func dismantleNSView(_ imageView: PixelAnimationImageView, coordinator: ()) {
        imageView.stopAnimating()
    }
}

@MainActor
private final class PixelAnimationImageView: NSImageView {
    private var animationTimer: Timer?
    private var currentStyle: StatusBarIconStyle?
    private var currentFrame = 0
    private var currentBaseSpeed = 1.0

    override var intrinsicContentSize: NSSize {
        NSSize(width: 14, height: 14)
    }

    func configure(style: StatusBarIconStyle, animates: Bool, baseSpeed: Double) {
        let speedChanged = abs(currentBaseSpeed - baseSpeed) >= 0.001
        if currentStyle != style {
            currentStyle = style
            currentFrame = 0
            image = PixelStatusBarIconRenderer.image(style: style, frame: currentFrame)
        }
        currentBaseSpeed = baseSpeed

        guard animates else {
            stopAnimating()
            currentFrame = 0
            image = PixelStatusBarIconRenderer.image(style: style, frame: 0)
            return
        }

        if speedChanged {
            stopAnimating()
        }
        guard animationTimer == nil else { return }
        let timer = Timer(
            timeInterval: StatusBarAnimationTiming.interval(
                baseDuration: 0.5,
                baseSpeedMultiplier: baseSpeed,
                followsCPU: false
            ),
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let currentStyle = self.currentStyle else { return }
                self.currentFrame += 1
                self.image = PixelStatusBarIconRenderer.image(
                    style: currentStyle,
                    frame: self.currentFrame
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

}

private struct AnimatedStatusBarImageView: NSViewRepresentable {
    var imageURL: URL
    var animates: Bool
    var baseSpeed: Double

    func makeNSView(context: Context) -> AnimatedImageView {
        let imageView = AnimatedImageView()
        imageView.imageAlignment = .alignCenter
        imageView.imageFrameStyle = .none
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = .labelColor
        imageView.wantsLayer = true
        imageView.layer?.masksToBounds = true
        return imageView
    }

    func updateNSView(_ imageView: AnimatedImageView, context: Context) {
        imageView.configure(
            imageURL: imageURL,
            animates: animates,
            baseSpeed: baseSpeed
        )
    }

    static func dismantleNSView(_ imageView: AnimatedImageView, coordinator: ()) {
        imageView.stopAnimating()
    }
}

@MainActor
private final class AnimatedImageView: NSImageView {
    private var animationTimer: Timer?
    private var currentURL: URL?
    private var currentlyAnimates: Bool?
    private var currentBaseSpeed = 1.0

    override var intrinsicContentSize: NSSize {
        NSSize(width: 18, height: 16)
    }

    func configure(imageURL: URL, animates: Bool, baseSpeed: Double) {
        guard currentURL != imageURL
                || currentlyAnimates != animates
                || abs(currentBaseSpeed - baseSpeed) >= 0.001
        else {
            return
        }

        currentURL = imageURL
        currentlyAnimates = animates
        currentBaseSpeed = baseSpeed
        stopAnimating()

        guard let animation = StatusBarAnimationLoader.animation(at: imageURL) else {
            image = nil
            return
        }

        image = animation.frames[0]
        guard animates, animation.frames.count > 1 else { return }
        scheduleFrame(animation, index: 1, baseSpeed: baseSpeed)
    }

    func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func scheduleFrame(
        _ animation: StatusBarAnimation,
        index: Int,
        baseSpeed: Double
    ) {
        let previousIndex = index == 0 ? animation.frames.count - 1 : index - 1
        let timer = Timer(
            timeInterval: StatusBarAnimationTiming.interval(
                baseDuration: animation.durations[previousIndex],
                baseSpeedMultiplier: baseSpeed,
                followsCPU: false
            ),
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.image = animation.frames[index]
                self.scheduleFrame(
                    animation,
                    index: (index + 1) % animation.frames.count,
                    baseSpeed: baseSpeed
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }
}

enum PixelStatusBarIconRenderer {
    private static let gridSize = 8
    private static let imageSize = NSSize(width: 16, height: 16)
    @MainActor private static var cachedImages: [String: NSImage] = [:]

    @MainActor
    static func image(style: StatusBarIconStyle, frame: Int) -> NSImage {
        let normalizedFrame = normalizedFrame(style: style, frame: frame)
        let cacheKey = "\(style.rawValue)-\(normalizedFrame)"
        if let cachedImage = cachedImages[cacheKey] {
            return cachedImage
        }

        let image = NSImage(size: imageSize, flipped: true) { bounds in
            let pixelSize = floor(min(bounds.width, bounds.height) / CGFloat(gridSize))
            let origin = CGPoint(
                x: floor((bounds.width - pixelSize * CGFloat(gridSize)) / 2),
                y: floor((bounds.height - pixelSize * CGFloat(gridSize)) / 2)
            )

            for layer in layers(style: style, frame: normalizedFrame) {
                NSColor.black.withAlphaComponent(layer.opacity).setFill()
                for (x, y) in layer.pixels {
                    NSBezierPath(
                        rect: NSRect(
                            x: origin.x + CGFloat(x) * pixelSize,
                            y: origin.y + CGFloat(y) * pixelSize,
                            width: pixelSize,
                            height: pixelSize
                        )
                    )
                    .fill()
                }
            }

            return true
        }
        image.isTemplate = true
        cachedImages[cacheKey] = image
        return image
    }

    private static func normalizedFrame(style: StatusBarIconStyle, frame: Int) -> Int {
        switch style {
        case .adaptive:
            0
        case .pixelBot:
            frame % 8 == 0 ? 0 : 1
        case .pixelSpark, .pixelPulse:
            frame.isMultiple(of: 2) ? 0 : 1
        }
    }

    private static func layers(style: StatusBarIconStyle, frame: Int) -> [PixelLayer] {
        switch style {
        case .adaptive:
            []
        case .pixelBot:
            [
                PixelLayer(pixels: [
                    (2, 1), (3, 1), (4, 1), (5, 1),
                    (1, 2), (6, 2),
                    (1, 3), (6, 3),
                    (1, 4), (6, 4),
                    (1, 5), (6, 5),
                    (2, 6), (3, 6), (4, 6), (5, 6),
                    (0, 3), (7, 3),
                    (3, 5), (4, 5)
                ]),
                PixelLayer(
                    pixels: frame % 8 == 0
                        ? [(2, 4), (5, 4)]
                        : [(2, 3), (5, 3)]
                )
            ]
        case .pixelSpark:
            [
                PixelLayer(pixels: [
                    (3, 0), (4, 0),
                    (3, 1), (4, 1),
                    (0, 3), (1, 3), (3, 3), (4, 3), (6, 3), (7, 3),
                    (0, 4), (1, 4), (3, 4), (4, 4), (6, 4), (7, 4),
                    (3, 6), (4, 6),
                    (3, 7), (4, 7)
                ]),
                frame.isMultiple(of: 2)
                    ? PixelLayer(
                        pixels: [(2, 2), (5, 2), (2, 5), (5, 5)],
                        opacity: 0.6
                    )
                    : PixelLayer(pixels: [
                        (3, 2), (4, 2), (2, 3), (5, 3),
                        (2, 4), (5, 4), (3, 5), (4, 5)
                    ])
            ]
        case .pixelPulse:
            [
                PixelLayer(pixels: [(3, 3), (4, 3), (3, 4), (4, 4)]),
                frame.isMultiple(of: 2)
                    ? PixelLayer(pixels: [
                        (2, 0), (3, 0), (4, 0), (5, 0),
                        (1, 1), (6, 1),
                        (0, 2), (7, 2),
                        (0, 3), (7, 3),
                        (0, 4), (7, 4),
                        (0, 5), (7, 5),
                        (1, 6), (6, 6),
                        (2, 7), (3, 7), (4, 7), (5, 7)
                    ], opacity: 0.72)
                    : PixelLayer(pixels: [
                        (2, 2), (3, 2), (4, 2), (5, 2),
                        (2, 3), (5, 3),
                        (2, 4), (5, 4),
                        (2, 5), (3, 5), (4, 5), (5, 5)
                    ], opacity: 0.86)
            ]
        }
    }

    private struct PixelLayer {
        var pixels: [(Int, Int)]
        var opacity = 1.0
    }
}
