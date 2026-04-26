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

    @Test("Status bar icons are static unless animation is explicitly requested")
    @MainActor
    func statusBarIconsDefaultToStaticRendering() {
        let statusBarIcon = StatusBarIconView(style: .pixelPulse, health: .normal)
        let settingsPreview = StatusBarIconView(
            style: .pixelPulse,
            health: .normal,
            animates: true
        )

        #expect(statusBarIcon.animates == false)
        #expect(settingsPreview.animates)
    }

    @Test("Status bar animation is enabled by default and persists")
    @MainActor
    func statusBarAnimationSettingPersists() {
        let suiteName = "CodexUsageTests.AppSettings.Animation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.animateStatusBarIcon)

        settings.animateStatusBarIcon = false

        let reloadedSettings = AppSettings(defaults: defaults)
        #expect(reloadedSettings.animateStatusBarIcon == false)
    }

    @Test("CPU-linked animation is opt-in, persists, and resets")
    @MainActor
    func cpuLinkedAnimationSettingPersistsAndResets() {
        let suiteName = "CodexUsageTests.AppSettings.CPUAnimation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.statusBarAnimationFollowsCPU == false)

        settings.statusBarAnimationFollowsCPU = true

        let reloadedSettings = AppSettings(defaults: defaults)
        #expect(reloadedSettings.statusBarAnimationFollowsCPU)

        reloadedSettings.reset()
        #expect(reloadedSettings.statusBarAnimationFollowsCPU == false)
    }

    @Test("CPU-linked timing is bounded and preserves original timing when disabled")
    func cpuLinkedAnimationTimingIsBounded() {
        #expect(StatusBarAnimationTiming.speedMultiplier(forCPUUsage: -1) == 0.6)
        #expect(StatusBarAnimationTiming.speedMultiplier(forCPUUsage: 0.5) == 1.2)
        #expect(
            abs(StatusBarAnimationTiming.speedMultiplier(forCPUUsage: 2) - 1.8)
                < 0.000_001
        )
        #expect(
            StatusBarAnimationTiming.interval(
                baseDuration: 0.02,
                speedMultiplier: 1.8,
                followsCPU: true
            ) == StatusBarAnimationTiming.minimumInterval
        )
        #expect(
            StatusBarAnimationTiming.interval(
                baseDuration: 0.08,
                speedMultiplier: 0.8,
                followsCPU: false
            ) == 0.08
        )
    }

    @Test("All BuZhiYin default animations are bundled and readable")
    @MainActor
    func bundledGIFCatalogIsComplete() {
        let gifIcons = StatusBarIconCatalog.builtIns.filter {
            if case .image = $0.source { return true }
            return false
        }

        #expect(gifIcons.count == 19)
        #expect(Set(StatusBarIconCatalog.builtIns.map(\.id)).count == StatusBarIconCatalog.builtIns.count)

        for icon in gifIcons {
            let url = StatusBarIconCatalog.resourceURL(for: icon)
            #expect(url != nil)
            if let url {
                #expect(url.pathExtension == "gif")
                #expect(FileManager.default.fileExists(atPath: url.path))
            }
        }
    }

    @Test("Every animated preview frame stays within menu bar dimensions")
    @MainActor
    func animatedPreviewFramesAreBounded() throws {
        let descriptor = try #require(
            StatusBarIconCatalog.builtIns.first {
                $0.id == "builtin.big_mouse_frog"
            }
        )
        let url = try #require(StatusBarIconCatalog.resourceURL(for: descriptor))
        let animation = try #require(StatusBarAnimationLoader.animation(at: url))

        #expect(animation.frames.count > 1)
        #expect(
            animation.frames.allSatisfy {
                $0.size.width > 0
                    && $0.size.height > 0
                    && $0.size.width <= 18
                    && $0.size.height <= 18
            }
        )
    }

    @Test("Dark monochrome animations use adaptive template rendering")
    @MainActor
    func monochromeAnimationsAdaptToMenuBarContrast() throws {
        let monochromeDescriptor = try #require(
            StatusBarIconCatalog.builtIns.first {
                $0.id == "builtin.zhiyin"
            }
        )
        let colorDescriptor = try #require(
            StatusBarIconCatalog.builtIns.first {
                $0.id == "builtin.mongmong"
            }
        )
        let monochromeURL = try #require(
            StatusBarIconCatalog.resourceURL(for: monochromeDescriptor)
        )
        let colorURL = try #require(
            StatusBarIconCatalog.resourceURL(for: colorDescriptor)
        )
        let monochromeAnimation = try #require(
            StatusBarAnimationLoader.animation(at: monochromeURL)
        )
        let colorAnimation = try #require(
            StatusBarAnimationLoader.animation(at: colorURL)
        )

        #expect(monochromeAnimation.usesTemplateRendering)
        #expect(monochromeAnimation.frames.allSatisfy { $0.isTemplate })
        #expect(colorAnimation.usesTemplateRendering == false)
        #expect(colorAnimation.frames.allSatisfy { !$0.isTemplate })
    }

    @Test("Custom status bar images are copied, selected, persisted, and removed")
    @MainActor
    func customStatusBarImageLifecycle() throws {
        let suiteName = "CodexUsageTests.AppSettings.CustomIcon.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceIcon = try #require(
            StatusBarIconCatalog.builtIns.first { $0.id == "builtin.mongmong" }
        )
        let sourceURL = try #require(StatusBarIconCatalog.resourceURL(for: sourceIcon))
        let settings = AppSettings(
            defaults: defaults,
            customIconDirectory: directory
        )

        let customIcon = try settings.importStatusBarIcon(from: sourceURL)

        #expect(settings.statusBarIconID == customIcon.catalogID)
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(customIcon.filename).path
            )
        )

        let reloadedSettings = AppSettings(
            defaults: defaults,
            customIconDirectory: directory
        )
        #expect(reloadedSettings.customStatusBarIcons == [customIcon])
        #expect(reloadedSettings.selectedStatusBarIcon.id == customIcon.catalogID)

        try reloadedSettings.removeStatusBarIcon(customIcon)

        #expect(reloadedSettings.customStatusBarIcons.isEmpty)
        #expect(reloadedSettings.statusBarIconID == StatusBarIconCatalog.defaultID)
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(customIcon.filename).path
            ) == false
        )
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
