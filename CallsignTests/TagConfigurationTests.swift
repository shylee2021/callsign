import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import Callsign

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
        // Literal on-disk names: a renamed key would silently drop saved preferences.
        #expect(defaults.string(forKey: "tag.position") == "rightCenter")
        #expect(defaults.double(forKey: "tag.textBlue") == 0.7)
        defaults.set(0.5, forKey: PreferenceKey.appearDelay)
        #expect(TagConfiguration.load(from: defaults) == custom)
        #expect(defaults.object(forKey: PreferenceKey.appearDelay) == nil)

        defaults.set("unknown", forKey: PreferenceKey.position)
        defaults.set(Double.infinity, forKey: PreferenceKey.tag("scale"))
        defaults.set(900, forKey: PreferenceKey.tag("offsetX"))
        defaults.set(-1, forKey: PreferenceKey.tag("alpha"))
        let validated = TagConfiguration.load(from: defaults)
        #expect(validated.position == TagConfiguration.default.position)
        #expect(validated.scale == TagConfiguration.default.scale)
        #expect(validated.offsetX == 80)
        #expect(validated.alpha == 0)
        #expect(validated.textBlue == custom.textBlue)

        defaults.set(true, forKey: PreferenceKey.showInDock)
        TagConfiguration.default.save(to: defaults)
        #expect(TagConfiguration.load(from: defaults) == .default)
        #expect(defaults.bool(forKey: PreferenceKey.showInDock))
    }

    @Test func changedPreferencesSaveOnlyTheirKeys() throws {
        let suite = "CallsignTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(0.3, forKey: PreferenceKey.tag("red"))
        var changed = TagConfiguration.default
        changed.scale = 1.2
        changed.save(to: defaults, changedFrom: .default)
        #expect(defaults.double(forKey: PreferenceKey.tag("scale")) == 1.2)
        #expect(defaults.double(forKey: PreferenceKey.tag("red")) == 0.3)
        #expect(defaults.object(forKey: PreferenceKey.position) == nil)
    }

    @Test func preferenceKeysKeepTheirOnDiskNames() {
        #expect(PreferenceKey.enabled == "app.enabled")
        #expect(PreferenceKey.showInDock == "app.showInDock")
        #expect(PreferenceKey.hasOpenedSettings == "app.hasOpenedSettings")
        #expect(PreferenceKey.position == "tag.position")
        #expect(PreferenceKey.label == "tag.label")
        #expect(PreferenceKey.liquidGlass == "tag.liquidGlass")
        #expect(PreferenceKey.appearDelay == "tag.appearDelay")
        #expect(PreferenceKey.tag("offsetX") == "tag.offsetX")
    }

    @Test func labelSelectionAndFallback() {
        #expect(TagLabel.appName.text(appName: "App", windowTitle: "Window") == "App")
        #expect(TagLabel.windowTitle.text(appName: "App", windowTitle: "Window") == "Window")
        #expect(TagLabel.windowTitle.text(appName: "App", windowTitle: "") == "App")
        #expect(TagLabel.iconOnly.text(appName: "App", windowTitle: "Window") == nil)
    }
}
