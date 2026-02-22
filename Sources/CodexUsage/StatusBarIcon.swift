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
    var animates = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch style {
        case .adaptive:
            Image(systemName: adaptiveSymbolName)
                .accessibilityLabel(style.accessibilityLabel)
        case .pixelBot, .pixelSpark, .pixelPulse:
            if animates && !reduceMotion {
                TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                    PixelStatusBarIcon(
                        style: style,
                        frame: animationFrame(at: timeline.date)
                    )
                }
            } else {
                PixelStatusBarIcon(style: style, frame: 0)
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

private struct PixelStatusBarIcon: View {
    var style: StatusBarIconStyle
    var frame: Int

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let gridSize = 8
            let pixelSize = floor(min(size.width, size.height) / CGFloat(gridSize))
            let origin = CGPoint(
                x: floor((size.width - pixelSize * CGFloat(gridSize)) / 2),
                y: floor((size.height - pixelSize * CGFloat(gridSize)) / 2)
            )

            func fill(_ pixels: [(Int, Int)], opacity: Double = 1) {
                for (x, y) in pixels {
                    let rect = CGRect(
                        x: origin.x + CGFloat(x) * pixelSize,
                        y: origin.y + CGFloat(y) * pixelSize,
                        width: pixelSize,
                        height: pixelSize
                    )
                    context.fill(
                        Path(rect),
                        with: .color(Color.primary.opacity(opacity))
                    )
                }
            }

            switch style {
            case .adaptive:
                break
            case .pixelBot:
                fill([
                    (2, 1), (3, 1), (4, 1), (5, 1),
                    (1, 2), (6, 2),
                    (1, 3), (6, 3),
                    (1, 4), (6, 4),
                    (1, 5), (6, 5),
                    (2, 6), (3, 6), (4, 6), (5, 6),
                    (0, 3), (7, 3)
                ])

                let isBlinking = frame % 8 == 0
                fill(isBlinking ? [(2, 4), (5, 4)] : [(2, 3), (5, 3)])
                fill([(3, 5), (4, 5)])
            case .pixelSpark:
                let isExpanded = frame.isMultiple(of: 2)
                fill([
                    (3, 0), (4, 0),
                    (3, 1), (4, 1),
                    (0, 3), (1, 3), (3, 3), (4, 3), (6, 3), (7, 3),
                    (0, 4), (1, 4), (3, 4), (4, 4), (6, 4), (7, 4),
                    (3, 6), (4, 6),
                    (3, 7), (4, 7)
                ])
                fill(
                    isExpanded
                        ? [(2, 2), (5, 2), (2, 5), (5, 5)]
                        : [(3, 2), (4, 2), (2, 3), (5, 3), (2, 4), (5, 4), (3, 5), (4, 5)],
                    opacity: isExpanded ? 0.6 : 1
                )
            case .pixelPulse:
                let isExpanded = frame.isMultiple(of: 2)
                fill([(3, 3), (4, 3), (3, 4), (4, 4)])

                if isExpanded {
                    fill([
                        (2, 0), (3, 0), (4, 0), (5, 0),
                        (1, 1), (6, 1),
                        (0, 2), (7, 2),
                        (0, 3), (7, 3),
                        (0, 4), (7, 4),
                        (0, 5), (7, 5),
                        (1, 6), (6, 6),
                        (2, 7), (3, 7), (4, 7), (5, 7)
                    ], opacity: 0.72)
                } else {
                    fill([
                        (2, 2), (3, 2), (4, 2), (5, 2),
                        (2, 3), (5, 3),
                        (2, 4), (5, 4),
                        (2, 5), (3, 5), (4, 5), (5, 5)
                    ], opacity: 0.86)
                }
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityLabel(style.accessibilityLabel)
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
                            StatusBarIconView(style: style, health: .normal)
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

            Text("像素动画以每秒 2 帧低频刷新；开启“减少动态效果”时会自动静止。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
