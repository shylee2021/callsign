import AppKit
import CoreGraphics
import Darwin
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
    }

    @Test func liquidGlassIsOptInAndChangesConfiguration() {
        let original = TagConfiguration.default
        #expect(!original.liquidGlass)
        var glass = original
        glass.liquidGlass = true
        // Appearance changes must invalidate reused badge content.
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
            windowID: 10, pid: 1, appName: "Test", windowTitle: "Window",
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            thumbnailFrame: CGRect(x: 100, y: 100, width: 400, height: 300))
        var configuration = TagConfiguration.default

        overlays.show([badge], configuration: configuration, animated: false)
        let original = try #require(overlays.panels[10]?.window)
        #expect(type(of: original) == NSPanel.self)
        // Fail explicitly if a future AppKit removes the private appearance query.
        try #require(original.responds(to: NSSelectorFromString("_hasActiveAppearance")))

        configuration.liquidGlass = true
        overlays.show([badge], configuration: configuration, animated: false)
        let glass = try #require(overlays.panels[10]?.window)
        #expect(glass !== original)
        #expect(!original.isVisible)
        #expect(glass.value(forKey: "_hasActiveAppearance") as? Bool == true)
        #expect(!glass.canBecomeKey && !glass.canBecomeMain && !glass.isKeyWindow)
        #expect(glass.ignoresMouseEvents && glass.styleMask.contains(.nonactivatingPanel))

        overlays.show([badge], configuration: configuration, animated: false)
        #expect(overlays.panels[10]?.window === glass)

        configuration.liquidGlass = false
        overlays.show([badge], configuration: configuration, animated: false)
        let restored = try #require(overlays.panels[10]?.window)
        #expect(restored !== glass)
        #expect(type(of: restored) == NSPanel.self)
        #expect(!glass.isVisible)
        for window in [original, glass, restored] {
            // AppKit must not move the overlay back onto a desktop after ordering it.
            #expect(!window.collectionBehavior.contains(.moveToActiveSpace))
            #expect(!window.collectionBehavior.contains(.canJoinAllSpaces))
            #expect(window.collectionBehavior.contains(.stationary))
        }
    }

    @Test func panelsStayOutsideDesktopSpacesAfterMovingAndReopening() async throws {
        let handle = try #require(dlopen(nil, RTLD_LAZY))
        defer { dlclose(handle) }
        let main = try #require(dlsym(handle, "CGSMainConnectionID"))
        let copy = try #require(dlsym(handle, "CGSCopySpacesForWindows"))
        let connection = unsafeBitCast(main, to: (@convention(c) () -> Int32).self)()
        let spaces = unsafeBitCast(copy, to:
            (@convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?).self)

        for liquidGlass in [false, true] {
            let overlays = OverlayManager()
            defer { overlays.hide() }
            let configuration = TagConfiguration(liquidGlass: liquidGlass)
            var original: NSPanel?
            for stage in 0..<3 {
                if stage == 2 { overlays.hide() }
                let badge = AppBadge(
                    windowID: 40, pid: 1, appName: "Preview exclusion", windowTitle: "Window",
                    icon: NSImage(size: NSSize(width: 32, height: 32)),
                    thumbnailFrame: CGRect(x: 100 + stage * 40, y: 100, width: 400, height: 300))
                overlays.show([badge], configuration: configuration, animated: false)
                let window = try #require(overlays.panels[40]?.window)
                if let original { #expect(window === original) } else { original = window }
                // Let AppKit finish ordering: moveToActiveSpace used to reattach it asynchronously.
                try await Task.sleep(for: .milliseconds(250))
                overlays.show([badge], configuration: configuration, animated: false)
                let desktops = try #require(spaces(
                    connection, 7, [window.windowNumber] as CFArray)).takeRetainedValue()
                #expect(CFArrayGetCount(desktops) == 0)
                #expect(window.isVisible && !window.isKeyWindow)
                #expect(window.alphaValue == 1)
            }
            overlays.show([], configuration: configuration, animated: false)
            #expect(original?.isVisible == false)
        }
    }

    @Test func lateTitlesAndReorderingKeepPanelsAttachedToTheirWindows() throws {
        let overlays = OverlayManager()
        defer { overlays.hide() }
        let icon = NSImage(size: NSSize(width: 32, height: 32))
        func badge(_ id: CGWindowID, title: String) -> AppBadge {
            AppBadge(windowID: id, pid: 1, appName: "Editor", windowTitle: title, icon: icon,
                     thumbnailFrame: CGRect(x: -10000, y: -10000 + Int(id) * 100, width: 400, height: 300))
        }
        let first = badge(10, title: "First document")
        let second = badge(20, title: "Second document")
        let configuration = TagConfiguration(label: .windowTitle)
        // The second window's title arrives first; the first must not steal its visible panel.
        overlays.show([second], configuration: configuration, animated: false)
        let secondPanel = try #require(overlays.panels[20])
        let secondFrame = secondPanel.window.frame
        overlays.show([first, second], configuration: configuration, animated: false)
        let firstPanel = try #require(overlays.panels[10])
        #expect(overlays.panels[20] === secondPanel)
        #expect(secondPanel.window.frame == secondFrame)
        #expect((secondPanel.window.contentView as? NSHostingView<BadgeView>)?.rootView.text == "Second document")
        #expect(firstPanel.window.frame.width > 100)

        overlays.show([second, first], configuration: configuration, animated: false)
        #expect(overlays.panels[10] === firstPanel && overlays.panels[20] === secondPanel)
        let width = firstPanel.window.frame.width
        let renamed = badge(10, title: "Document with a much longer window title")
        overlays.show([renamed], configuration: configuration, animated: false)
        #expect(overlays.panels[10] === firstPanel)
        #expect(firstPanel.window.frame.width > width)
        #expect(overlays.panels[20] == nil && !secondPanel.window.isVisible)
        overlays.hide()
        overlays.show([renamed], configuration: configuration, animated: false)
        #expect(overlays.panels[10] === firstPanel)
    }

    @Test func unchangedUpdatesDoNotKeepRestartingTheAppearanceFade() async throws {
        let overlays = OverlayManager()
        defer { overlays.hide() }
        let badge = AppBadge(
            windowID: 30, pid: 1, appName: "Editor", windowTitle: "Document",
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            thumbnailFrame: CGRect(x: -10000, y: -10000, width: 400, height: 300))
        overlays.show([badge], configuration: .default, animated: true)
        let panel = try #require(overlays.panels[30])
        for _ in 0..<16 {
            try await Task.sleep(for: .milliseconds(25))
            overlays.show([badge], configuration: .default, animated: false)
        }
        #expect(panel.window.alphaValue == 1)
    }

    @Test func appearancePreferencesPreserveExistingValuesAndValidateSavedNumbers() throws {
        let suite = "CallsignTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(TagConfiguration.load(from: defaults) == .default)

        let custom = TagConfiguration(
            position: .rightCenter, label: .windowTitle, liquidGlass: true,
            overlap: 0.7, scale: 1.3, offsetX: 12, offsetY: -25,
            red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4,
            textRed: 0.5, textGreen: 0.6, textBlue: 0.7, textAlpha: 0.8)
        custom.save(to: defaults)
        #expect(TagConfiguration.load(from: defaults) == custom)
        #expect(defaults.string(forKey: "tag.position") == "rightCenter")
        #expect(defaults.double(forKey: "tag.textBlue") == 0.7)
        defaults.set(0.5, forKey: "tag.appearDelay")
        #expect(TagConfiguration.load(from: defaults) == custom)

        defaults.set("unknown", forKey: "tag.position")
        defaults.set(Double.infinity, forKey: "tag.scale")
        defaults.set(900, forKey: "tag.offsetX")
        defaults.set(-1, forKey: "tag.alpha")
        let validated = TagConfiguration.load(from: defaults)
        #expect(validated.position == TagConfiguration.default.position)
        #expect(validated.scale == TagConfiguration.default.scale)
        #expect(validated.offsetX == 80)
        #expect(validated.alpha == 0)
        #expect(validated.textBlue == custom.textBlue)

        defaults.set(true, forKey: "app.showInDock")
        TagConfiguration.default.save(to: defaults)
        #expect(TagConfiguration.load(from: defaults) == .default)
        #expect(defaults.object(forKey: "tag.appearDelay") == nil)
        #expect(defaults.bool(forKey: "app.showInDock"))
    }

    @Test func labelSelectionAndFallback() {
        #expect(TagLabel.appName.text(appName: "App", windowTitle: "Window") == "App")
        #expect(TagLabel.windowTitle.text(appName: "App", windowTitle: "Window") == "Window")
        #expect(TagLabel.windowTitle.text(appName: "App", windowTitle: "") == "App")
        #expect(TagLabel.iconOnly.text(appName: "App", windowTitle: "Window") == nil)
    }
}
