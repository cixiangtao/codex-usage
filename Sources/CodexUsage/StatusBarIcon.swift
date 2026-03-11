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
    var style: StatusBarIconStyle
    var health: UsageHealth
    var animates = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch style {
        case .adaptive:
            Image(systemName: adaptiveSymbolName)
                .accessibilityLabel(style.accessibilityLabel)
        case .pixelBot, .pixelSpark, .pixelPulse:
            if animates && !reduceMotion {
                TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                    RasterizedPixelStatusBarIcon(
                        style: style,
                        frame: animationFrame(at: timeline.date)
                    )
                }
            } else {
                RasterizedPixelStatusBarIcon(style: style, frame: 0)
            }
        }
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

    private func animationFrame(at date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate * 2)
    }
}

private struct RasterizedPixelStatusBarIcon: View {
    var style: StatusBarIconStyle
    var frame: Int

    var body: some View {
        Image(nsImage: PixelStatusBarIconRenderer.image(style: style, frame: frame))
            .interpolation(.none)
            .frame(width: 16, height: 16)
            .accessibilityLabel(style.accessibilityLabel)
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

struct StatusBarIconPicker: View {
    @Binding var selection: StatusBarIconStyle

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("状态栏图标")
                .font(.callout.weight(.medium))

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(StatusBarIconStyle.allCases) { style in
                    Button {
                        selection = style
                    } label: {
                        HStack(spacing: 10) {
                            StatusBarIconView(style: style, health: .normal, animates: true)
                                .frame(width: 28, height: 28)
                                .background(
                                    Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(style.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)

                                Text(style.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)

                            Image(systemName: selection == style ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection == style ? Color.accentColor : Color.secondary.opacity(0.45))
                        }
                        .padding(8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        selection == style ? Color.accentColor.opacity(0.1) : Color(nsColor: .windowBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(
                                selection == style ? Color.accentColor.opacity(0.7) : Color.clear,
                                lineWidth: 1
                            )
                    )
                    .accessibilityLabel("\(style.title)，\(style.subtitle)")
                    .accessibilityAddTraits(selection == style ? .isSelected : [])
                }
            }

            Text("设置页展示动画预览；状态栏使用静态像素帧，避免持续刷新影响性能。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
