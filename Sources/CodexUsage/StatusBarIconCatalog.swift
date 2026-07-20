import Foundation
import ImageIO

struct CustomStatusBarIcon: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    let filename: String

    var catalogID: String {
        "custom.\(id.uuidString.lowercased())"
    }
}

enum StatusBarIconSource: Equatable {
    case adaptive
    case pixel(StatusBarIconStyle)
    case image(URL)
}

struct StatusBarIconDescriptor: Equatable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let source: StatusBarIconSource
}

enum StatusBarIconCatalog {
    static let defaultID = StatusBarIconStyle.adaptive.rawValue

    static let builtIns: [StatusBarIconDescriptor] = [
        descriptor(for: .adaptive),
        descriptor(for: .pixelBot),
        descriptor(for: .pixelSpark),
        descriptor(for: .pixelPulse),
        bundledGIF("mongmong", title: "萌萌兔", subtitle: "mongmong 🐰"),
        bundledGIF("cat", title: "猫砸键盘", subtitle: "专注敲击中"),
        bundledGIF("gojo_satoru", title: "五条悟", subtitle: "高速移动"),
        bundledGIF("pink_cat", title: "粉色猫猫", subtitle: "轻快摇摆"),
        bundledGIF("zhiyin_basketball", title: "只因篮球", subtitle: "篮球循环"),
        bundledGIF("big_mouse_frog", title: "大嘴青蛙", subtitle: "大嘴循环"),
        bundledGIF("xiaolan_turn", title: "小蓝转圈", subtitle: "持续旋转"),
        bundledGIF("karby", title: "星之卡比", subtitle: "像素奔跑"),
        bundledGIF("txbb", title: "天线宝宝", subtitle: "快乐奔跑"),
        bundledGIF("zhiyin", title: "只因铁山靠", subtitle: "经典循环"),
        bundledGIF("3body", title: "金凯瑞摇", subtitle: "摇摆循环"),
        bundledGIF("baby_circle", title: "可爱小圈圈", subtitle: "圆圈舞步"),
        bundledGIF("cat2", title: "猫砸键盘盘", subtitle: "加速敲击"),
        bundledGIF("cat3", title: "猫猫摇爪", subtitle: "挥爪循环"),
        bundledGIF("color_worm", title: "彩虹毛毛虫", subtitle: "彩色蠕动"),
        bundledGIF("everonecat0", title: "Everyone Cat", subtitle: "长动画循环"),
        bundledGIF("hoshiguma", title: "星熊警官", subtitle: "像素待机"),
        bundledGIF("jerry", title: "Jerry", subtitle: "快速奔跑"),
        bundledGIF("my0", title: "BenignX", subtitle: "作者动画")
    ]

    static func descriptor(
        id: String,
        customIcons: [CustomStatusBarIcon],
        customIconDirectory: URL
    ) -> StatusBarIconDescriptor {
        if let builtIn = builtIns.first(where: { $0.id == id }) {
            return builtIn
        }

        if let customIcon = customIcons.first(where: { $0.catalogID == id }) {
            return StatusBarIconDescriptor(
                id: customIcon.catalogID,
                title: customIcon.name,
                subtitle: "自定义图片",
                source: .image(customIconDirectory.appendingPathComponent(customIcon.filename))
            )
        }

        return builtIns[0]
    }

    static func resourceURL(for descriptor: StatusBarIconDescriptor) -> URL? {
        guard case let .image(url) = descriptor.source else { return nil }
        return url
    }

    private static func descriptor(for style: StatusBarIconStyle) -> StatusBarIconDescriptor {
        StatusBarIconDescriptor(
            id: style.rawValue,
            title: style.title,
            subtitle: style.subtitle,
            source: style == .adaptive ? .adaptive : .pixel(style)
        )
    }

    private static func bundledGIF(
        _ name: String,
        title: String,
        subtitle: String
    ) -> StatusBarIconDescriptor {
        let resourceBundle = AppResources.bundle

        return StatusBarIconDescriptor(
            id: "builtin.\(name)",
            title: title,
            subtitle: subtitle,
            source: .image(
                resourceBundle.url(
                    forResource: name,
                    withExtension: "gif",
                    subdirectory: "StatusBarGIFs"
                )
                    ?? resourceBundle.url(forResource: name, withExtension: "gif")
                    ?? resourceBundle.bundleURL
            )
        )
    }
}

enum CustomStatusBarIconStore {
    static let maximumFileSize = 20 * 1_024 * 1_024
    static let maximumFrameCount = 300

    enum ImportError: LocalizedError {
        case fileTooLarge
        case unsupportedImage
        case tooManyFrames

        var errorDescription: String? {
            switch self {
            case .fileTooLarge:
                "图片不能超过 20 MB。"
            case .unsupportedImage:
                "无法读取这张图片，请选择 GIF、PNG、JPEG、HEIC 或 TIFF 文件。"
            case .tooManyFrames:
                "动图帧数不能超过 300 帧。"
            }
        }
    }

    static func importIcon(
        from sourceURL: URL,
        into directory: URL,
        fileManager: FileManager = .default
    ) throws -> CustomStatusBarIcon {
        let resourceValues = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = resourceValues.fileSize, fileSize > maximumFileSize {
            throw ImportError.fileTooLarge
        }

        guard
            let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
            CGImageSourceGetCount(imageSource) > 0
        else {
            throw ImportError.unsupportedImage
        }

        if CGImageSourceGetCount(imageSource) > maximumFrameCount {
            throw ImportError.tooManyFrames
        }

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let id = UUID()
        let sourceExtension = sourceURL.pathExtension.lowercased()
        let fileExtension = sourceExtension.isEmpty ? "image" : sourceExtension
        let filename = "\(id.uuidString.lowercased()).\(fileExtension)"
        let destinationURL = directory.appendingPathComponent(filename)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        let displayName = sourceURL.deletingPathExtension().lastPathComponent
        return CustomStatusBarIcon(
            id: id,
            name: displayName.isEmpty ? "自定义图标" : displayName,
            filename: filename
        )
    }

    static func remove(
        _ icon: CustomStatusBarIcon,
        from directory: URL,
        fileManager: FileManager = .default
    ) throws {
        let fileURL = directory.appendingPathComponent(icon.filename)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}
