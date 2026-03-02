import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexUsage

@Suite("App settings")
struct AppSettingsTests {
    @Test("Status bar icon choice persists and resets to adaptive")
    @MainActor
    func statusBarIconChoicePersistsAndResets() {
        let suiteName = "CodexUsageTests.AppSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.statusBarIconStyle == .adaptive)

        settings.statusBarIconStyle = .pixelBot

        let reloadedSettings = AppSettings(defaults: defaults)
        #expect(reloadedSettings.statusBarIconStyle == .pixelBot)

        reloadedSettings.reset()
        #expect(reloadedSettings.statusBarIconStyle == .adaptive)
    }

    @Test("Unknown status bar icon values fall back safely")
    @MainActor
    func unknownStatusBarIconFallsBackToAdaptive() {
        let suiteName = "CodexUsageTests.AppSettings.Invalid.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("future-icon", forKey: "statusBarIconStyle")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.statusBarIconStyle == .adaptive)
    }

    @Test("Every custom status bar icon produces a visible template image")
    @MainActor
    func customStatusBarIconsProduceVisibleTemplateImages() throws {
        for style in StatusBarIconStyle.allCases where style != .adaptive {
            for frame in [0, 1] {
                let image = PixelStatusBarIconRenderer.image(style: style, frame: frame)
                let tiffData = try #require(image.tiffRepresentation)
                let bitmap = try #require(NSBitmapImageRep(data: tiffData))

                #expect(image.isTemplate)
                #expect(image.size == NSSize(width: 16, height: 16))
                #expect(hasVisiblePixel(in: bitmap))

                let renderedView = StatusBarIconView(
                    style: style,
                    health: .normal,
                    animates: false
                )
                let renderedImage = try #require(ImageRenderer(content: renderedView).nsImage)
                let renderedData = try #require(renderedImage.tiffRepresentation)
                let renderedBitmap = try #require(NSBitmapImageRep(data: renderedData))

                #expect(hasVisiblePixel(in: renderedBitmap))
            }
        }
    }

    private func hasVisiblePixel(in bitmap: NSBitmapImageRep) -> Bool {
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                    return true
                }
            }
        }

        return false
    }
}
