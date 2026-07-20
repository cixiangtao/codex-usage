import AppKit

@MainActor
enum AppIcon {
    static let statusSymbolName = "bolt.circle"

    static func installApplicationIcon() {
        NSApplication.shared.applicationIconImage = image()
    }

    static func image(size: CGFloat = 1024) -> NSImage {
        if let bundledIcon = bundledIconImage() {
            return bundledIcon
        }

        return renderedSymbolIcon(size: size)
    }

    private static func bundledIconImage() -> NSImage? {
        if let image = iconImage(in: .main) {
            return image
        }

        return iconImage(in: AppResources.bundle)
    }

    private static func iconImage(in bundle: Bundle) -> NSImage? {
        guard let url = bundle.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }

        image.isTemplate = false
        return image
    }

    private static func renderedSymbolIcon(size: CGFloat) -> NSImage {
        let imageSize = NSSize(width: size, height: size)
        let image = NSImage(size: imageSize)

        image.lockFocus()

        let canvas = NSRect(origin: .zero, size: imageSize)
        let background = NSBezierPath(
            roundedRect: canvas.insetBy(dx: size * 0.06, dy: size * 0.06),
            xRadius: size * 0.22,
            yRadius: size * 0.22
        )
        NSColor(calibratedRed: 0.08, green: 0.18, blue: 0.34, alpha: 1).setFill()
        background.fill()

        let highlight = NSBezierPath(
            ovalIn: NSRect(
                x: size * 0.18,
                y: size * 0.58,
                width: size * 0.24,
                height: size * 0.18
            )
        )
        NSColor(calibratedWhite: 1, alpha: 0.18).setFill()
        highlight.fill()

        drawStatusSymbol(size: size)

        image.unlockFocus()
        image.isTemplate = false

        return image
    }

    private static func drawStatusSymbol(size: CGFloat) {
        guard let symbol = NSImage(systemSymbolName: statusSymbolName, accessibilityDescription: "Codex Usage") else {
            return
        }

        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size * 0.56, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: .white))
        let configuredSymbol = symbol.withSymbolConfiguration(symbolConfiguration) ?? symbol
        let symbolRect = NSRect(x: size * 0.22, y: size * 0.22, width: size * 0.56, height: size * 0.56)

        configuredSymbol.draw(
            in: symbolRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }
}
