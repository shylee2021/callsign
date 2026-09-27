//
//  TagConfiguration.swift
//  Callsign
//

import CoreGraphics
import Foundation

// UserDefaults keys as stored on disk; renaming one silently drops users' saved preferences.
enum PreferenceKey {
    static let enabled = "app.enabled"
    static let showInDock = "app.showInDock"
    static let hasOpenedSettings = "app.hasOpenedSettings"
    static let position = "tag.position"
    static let label = "tag.label"
    static let liquidGlass = "tag.liquidGlass"
    // Retired; removed on load.
    static let appearDelay = "tag.appearDelay"

    // Numeric tag preferences are stored under their property names, e.g. "tag.textBlue".
    static func tag(_ name: String) -> String { "tag.\(name)" }
}

enum TagPosition: String, CaseIterable, Identifiable {
    case topLeft, topCenter, topRight, leftCenter, rightCenter, bottomLeft, bottomCenter, bottomRight

    var id: Self { self }

    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topCenter: "Top Center"
        case .topRight: "Top Right"
        case .leftCenter: "Left Center"
        case .rightCenter: "Right Center"
        case .bottomLeft: "Bottom Left"
        case .bottomCenter: "Bottom Center"
        case .bottomRight: "Bottom Right"
        }
    }
}

enum TagLabel: String, CaseIterable, Identifiable {
    case appName, windowTitle, iconOnly

    var id: Self { self }

    var title: String {
        switch self {
        case .appName: "App Name"
        case .windowTitle: "Window Name"
        case .iconOnly: "Icon Only"
        }
    }

    func text(appName: String, windowTitle: String) -> String? {
        switch self {
        case .appName: appName
        case .windowTitle: windowTitle.isEmpty ? appName : windowTitle
        case .iconOnly: nil
        }
    }
}

struct TagConfiguration: Hashable {
    var position: TagPosition = .bottomCenter
    var label: TagLabel = .appName
    var liquidGlass = false
    // Fraction of the badge inside the chosen edge: 0 = outside, 1 = inside.
    var overlap = 0.5
    var scale = 1.0
    var offsetX = 0.0
    var offsetY = 0.0
    var red = 0.08
    var green = 0.08
    var blue = 0.09
    var alpha = 0.85
    var textRed = 1.0
    var textGreen = 1.0
    var textBlue = 1.0
    var textAlpha = 1.0

    static let `default` = TagConfiguration()

    // Keep the existing preference keys, including custom colors saved while Glass is enabled.
    private static let numericPreferences: [(String, WritableKeyPath<Self, Double>, ClosedRange<Double>)] = [
        ("overlap", \.overlap, 0...1), ("scale", \.scale, 0.7...1.5),
        ("offsetX", \.offsetX, -80...80), ("offsetY", \.offsetY, -80...80),
        ("red", \.red, 0...1), ("green", \.green, 0...1), ("blue", \.blue, 0...1),
        ("alpha", \.alpha, 0...1),
        ("textRed", \.textRed, 0...1), ("textGreen", \.textGreen, 0...1),
        ("textBlue", \.textBlue, 0...1), ("textAlpha", \.textAlpha, 0...1),
    ]

    static func load(from defaults: UserDefaults) -> Self {
        // One-time cleanup of a retired preference.
        defaults.removeObject(forKey: PreferenceKey.appearDelay)
        var configuration = Self.default
        configuration.position = TagPosition(rawValue: defaults.string(forKey: PreferenceKey.position) ?? "")
            ?? Self.default.position
        configuration.label = TagLabel(rawValue: defaults.string(forKey: PreferenceKey.label) ?? "")
            ?? Self.default.label
        configuration.liquidGlass = defaults.object(forKey: PreferenceKey.liquidGlass) as? Bool ?? false
        for (name, path, range) in numericPreferences {
            guard let value = defaults.object(forKey: PreferenceKey.tag(name)) as? Double, value.isFinite else { continue }
            configuration[keyPath: path] = min(max(value, range.lowerBound), range.upperBound)
        }
        return configuration
    }

    // Without a previous value, writes every preference.
    func save(to defaults: UserDefaults, changedFrom old: Self? = nil) {
        if position != old?.position { defaults.set(position.rawValue, forKey: PreferenceKey.position) }
        if label != old?.label { defaults.set(label.rawValue, forKey: PreferenceKey.label) }
        if liquidGlass != old?.liquidGlass { defaults.set(liquidGlass, forKey: PreferenceKey.liquidGlass) }
        for (name, path, _) in Self.numericPreferences where self[keyPath: path] != old?[keyPath: path] {
            defaults.set(self[keyPath: path], forKey: PreferenceKey.tag(name))
        }
    }

    // AX coordinates: origin at the top left, positive Y points down.
    func badgeOrigin(thumbnail: CGRect, badgeSize: CGSize) -> CGPoint {
        let overlap = CGFloat(overlap)
        let x: CGFloat = switch position {
        case .topLeft, .bottomLeft:
            thumbnail.minX
        case .topCenter, .bottomCenter:
            thumbnail.midX - badgeSize.width / 2
        case .topRight, .bottomRight:
            thumbnail.maxX - badgeSize.width
        case .leftCenter:
            thumbnail.minX - badgeSize.width * (1 - overlap)
        case .rightCenter:
            thumbnail.maxX - badgeSize.width * overlap
        }

        let y: CGFloat = switch position {
        case .topLeft, .topCenter, .topRight:
            thumbnail.minY - badgeSize.height * (1 - overlap)
        case .bottomLeft, .bottomCenter, .bottomRight:
            thumbnail.maxY - badgeSize.height * overlap
        case .leftCenter, .rightCenter:
            thumbnail.midY - badgeSize.height / 2
        }
        return CGPoint(x: x + offsetX, y: y + offsetY)
    }
}
