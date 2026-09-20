import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import Callsign

@MainActor
struct TagConfigurationTests {
    @Test func badgePlacementAndOffsets() {
        let thumbnail = CGRect(x: 100, y: 200, width: 400, height: 300)
        let badgeSize = CGSize(width: 100, height: 40)
        let expected: [TagPosition: [CGPoint]] = [
            .topLeft:      [CGPoint(x: 100, y: 160), CGPoint(x: 100, y: 180), CGPoint(x: 100, y: 200)],
            .topCenter:    [CGPoint(x: 250, y: 160), CGPoint(x: 250, y: 180), CGPoint(x: 250, y: 200)],
            .topRight:     [CGPoint(x: 400, y: 160), CGPoint(x: 400, y: 180), CGPoint(x: 400, y: 200)],
            .leftCenter:   [CGPoint(x: 0, y: 330), CGPoint(x: 50, y: 330), CGPoint(x: 100, y: 330)],
            .rightCenter:  [CGPoint(x: 500, y: 330), CGPoint(x: 450, y: 330), CGPoint(x: 400, y: 330)],
            .bottomLeft:   [CGPoint(x: 100, y: 500), CGPoint(x: 100, y: 480), CGPoint(x: 100, y: 460)],
            .bottomCenter: [CGPoint(x: 250, y: 500), CGPoint(x: 250, y: 480), CGPoint(x: 250, y: 460)],
            .bottomRight:  [CGPoint(x: 400, y: 500), CGPoint(x: 400, y: 480), CGPoint(x: 400, y: 460)],
        ]

        for position in TagPosition.allCases {
            for (index, overlap) in [0.0, 0.5, 1.0].enumerated() {
                var configuration = TagConfiguration(position: position, overlap: overlap)
                let origin = expected[position]![index]
                #expect(configuration.badgeOrigin(thumbnail: thumbnail, badgeSize: badgeSize) == origin)
                configuration.offsetX = -17
                configuration.offsetY = 23
                // Include displays above or to the left of the primary display.
                #expect(configuration.badgeOrigin(
                    thumbnail: thumbnail.offsetBy(dx: -1_000, dy: -700), badgeSize: badgeSize)
                    == CGPoint(x: origin.x - 1_017, y: origin.y - 677))
            }
        }

        #expect(TagConfiguration.default.badgeOrigin(thumbnail: thumbnail, badgeSize: badgeSize)
                == CGPoint(x: 250, y: 480))
        #expect(TagConfiguration.default.scale == 1)
        #expect(TagConfiguration.default.appearDelay == 0)
    }

    @Test func liquidGlassIsOptInAndChangesConfiguration() {
        let original = TagConfiguration.default
        #expect(!original.liquidGlass)
        var glass = original
        glass.liquidGlass = true
        // Both the polling task and badge refresh use configuration equality.
        #expect(glass != original)
        #expect(Set([original, glass]).count == 2)
    }

    @Test func liquidGlassUsesRegularMaterialAndSystemText() {
        var configuration = TagConfiguration(
            liquidGlass: true, red: 1, green: 1, blue: 1, alpha: 1,
            textRed: 0, textGreen: 0, textBlue: 0, textAlpha: 0.5)
        let icon = NSImage(size: NSSize(width: 32, height: 32))
        let glass = BadgeView(icon: icon, text: "Window", configuration: configuration)
        #expect(glass.glassMaterial == .regular)
        #expect(glass.textColor == .primary)

        configuration.liquidGlass = false
        let custom = BadgeView(icon: icon, text: "Window", configuration: configuration)
        #expect(custom.glassMaterial == .identity)
        #expect(custom.textColor == Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.5))
    }

    @Test func glassPanelAppearanceDoesNotTakeFocusOrChangeGlassOffPanels() throws {
        let overlays = OverlayManager()
        defer { overlays.hide() }
        let badge = AppBadge(
            pid: 1, appName: "Test", windowTitle: "Window",
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            thumbnailFrame: CGRect(x: 100, y: 100, width: 400, height: 300))
        var configuration = TagConfiguration.default

        overlays.show([badge], configuration: configuration, animated: false)
        let original = try #require(overlays.panels.first?.window)
        #expect(type(of: original) == NSPanel.self)
        // Fail explicitly if a future AppKit removes the private appearance query.
        try #require(original.responds(to: NSSelectorFromString("_hasActiveAppearance")))

        configuration.liquidGlass = true
        overlays.show([badge], configuration: configuration, animated: false)
        let glass = try #require(overlays.panels.first?.window)
        #expect(glass !== original)
        #expect(!original.isVisible)
        #expect(glass.value(forKey: "_hasActiveAppearance") as? Bool == true)
        #expect(!glass.canBecomeKey && !glass.canBecomeMain && !glass.isKeyWindow)
        #expect(glass.ignoresMouseEvents && glass.styleMask.contains(.nonactivatingPanel))

        overlays.show([badge], configuration: configuration, animated: false)
        #expect(overlays.panels.first?.window === glass)

        configuration.liquidGlass = false
        overlays.show([badge], configuration: configuration, animated: false)
        let restored = try #require(overlays.panels.first?.window)
        #expect(restored !== glass)
        #expect(type(of: restored) == NSPanel.self)
        #expect(!glass.isVisible)
    }

    @Test func labelSelectionAndFallback() {
        #expect(TagLabel.appName.text(appName: "App", windowTitle: "Window") == "App")
        #expect(TagLabel.windowTitle.text(appName: "App", windowTitle: "Window") == "Window")
        #expect(TagLabel.windowTitle.text(appName: "App", windowTitle: "") == "App")
        #expect(TagLabel.iconOnly.text(appName: "App", windowTitle: "Window") == nil)
    }
}
