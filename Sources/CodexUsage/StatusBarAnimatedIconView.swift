import AppKit
import QuartzCore

struct StatusBarLayerAnimationTimeline: Equatable {
    let frameDurations: [TimeInterval]
    let keyTimes: [Double]
    let duration: TimeInterval
    let maximumPlaybackSpeed: Double

    init?(durations: [TimeInterval], baseSpeed: Double) {
        guard !durations.isEmpty, durations.allSatisfy({ $0 > 0 }) else {
            return nil
        }

        let clampedBaseSpeed = StatusBarAnimationTiming.clampedBaseSpeed(baseSpeed)
        let frameDurations = durations.map {
            max($0 / clampedBaseSpeed, StatusBarAnimationTiming.minimumInterval)
        }
        let duration = frameDurations.reduce(0, +)
        guard duration > 0 else { return nil }

        var elapsed: TimeInterval = 0
        let keyTimes = frameDurations.map { frameDuration in
            defer { elapsed += frameDuration }
            return elapsed / duration
        }
        let maximumPlaybackSpeed = frameDurations
            .map { $0 / StatusBarAnimationTiming.minimumInterval }
            .min()
            ?? 1

        self.frameDurations = frameDurations
        self.keyTimes = keyTimes
        self.duration = duration
        self.maximumPlaybackSpeed = max(maximumPlaybackSpeed, 1)
    }

    func clampedPlaybackSpeed(_ speed: Double) -> Double {
        min(max(speed, 0.1), maximumPlaybackSpeed)
    }
}

@MainActor
final class StatusBarAnimatedIconView: NSView {
    private static let animationKey = "codex-usage.frames"

    private let colorLayer = CALayer()
    private let tintLayer = CALayer()
    private let maskLayer = CALayer()
    private var activeAnimationLayer: CALayer?
    private var timeline: StatusBarLayerAnimationTimeline?
    private var playbackSpeed = 1.0

    var isAnimating: Bool {
        activeAnimationLayer?.animation(forKey: Self.animationKey) != nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        isHidden = true

        colorLayer.contentsGravity = .resizeAspect
        maskLayer.contentsGravity = .resizeAspect
        tintLayer.mask = maskLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        colorLayer.frame = bounds
        tintLayer.frame = bounds
        maskLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTintColor()
    }

    @discardableResult
    func play(
        frames: [CGImage],
        durations: [TimeInterval],
        usesTemplateRendering: Bool,
        baseSpeed: Double
    ) -> Bool {
        guard
            frames.count > 1,
            frames.count == durations.count,
            let timeline = StatusBarLayerAnimationTimeline(
                durations: durations,
                baseSpeed: baseSpeed
            )
        else {
            stop()
            return false
        }

        stop()
        self.timeline = timeline
        isHidden = false

        let animationLayer: CALayer
        if usesTemplateRendering {
            layer?.addSublayer(tintLayer)
            maskLayer.contents = frames[0]
            animationLayer = maskLayer
            updateTintColor()
        } else {
            layer?.addSublayer(colorLayer)
            colorLayer.contents = frames[0]
            animationLayer = colorLayer
        }

        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.keyTimes = timeline.keyTimes.map(NSNumber.init(value:))
        animation.duration = timeline.duration
        animation.calculationMode = .discrete
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false

        resetTiming(of: animationLayer)
        animationLayer.add(animation, forKey: Self.animationKey)
        activeAnimationLayer = animationLayer
        setPlaybackSpeed(playbackSpeed)
        needsLayout = true
        return true
    }

    func setPlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
        guard let activeAnimationLayer, let timeline else { return }

        let clampedSpeed = timeline.clampedPlaybackSpeed(speed)
        guard abs(Double(activeAnimationLayer.speed) - clampedSpeed) >= 0.001 else {
            return
        }

        let mediaTime = CACurrentMediaTime()
        let localTime = activeAnimationLayer.convertTime(mediaTime, from: nil)
        let parentTime = activeAnimationLayer.superlayer?
            .convertTime(mediaTime, from: nil)
            ?? mediaTime

        activeAnimationLayer.speed = Float(clampedSpeed)
        activeAnimationLayer.timeOffset = 0
        activeAnimationLayer.beginTime = parentTime - localTime / clampedSpeed
    }

    func stop() {
        activeAnimationLayer?.removeAnimation(forKey: Self.animationKey)
        resetTiming(of: colorLayer)
        resetTiming(of: maskLayer)
        colorLayer.removeFromSuperlayer()
        tintLayer.removeFromSuperlayer()
        colorLayer.contents = nil
        maskLayer.contents = nil
        activeAnimationLayer = nil
        timeline = nil
        playbackSpeed = 1
        isHidden = true
    }

    private func resetTiming(of layer: CALayer) {
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
    }

    private func updateTintColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tintLayer.backgroundColor = NSColor.labelColor.cgColor
        }
    }
}
