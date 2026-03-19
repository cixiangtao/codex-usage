import AppKit
import Testing
@testable import CodexUsage

@Suite("Application icon")
struct AppIconTests {
    @Test("Application icon initializes with visible content")
    @MainActor
    func applicationIconInitializes() throws {
        let image = AppIcon.image(size: 64)
        let tiffData = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiffData))

        #expect(image.isTemplate == false)
        #expect(bitmap.pixelsWide > 0)
        #expect(bitmap.pixelsHigh > 0)
        #expect(hasVisiblePixel(in: bitmap))
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
