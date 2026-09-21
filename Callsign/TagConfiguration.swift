//
//  TagConfiguration.swift
//  Callsign
//

import CoreGraphics
import Foundation

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
        var configuration = Self.default
        configuration.position = TagPosition(rawValue: defaults.string(forKey: "tag.position") ?? "")
            ?? Self.default.position
        configuration.label = TagLabel(rawValue: defaults.string(forKey: "tag.label") ?? "")
            ?? Self.default.label
        configuration.liquidGlass = defaults.object(forKey: "tag.liquidGlass") as? Bool ?? false
        for (key, path, range) in numericPreferences {
            guard let value = defaults.object(forKey: "tag.\(key)") as? Double, value.isFinite else { continue }
            configuration[keyPath: path] = min(max(value, range.lowerBound), range.upperBound)
        }
        return configuration
    }

    func save(to defaults: UserDefaults) {
        defaults.set(position.rawValue, forKey: "tag.position")
        defaults.set(label.rawValue, forKey: "tag.label")
        defaults.set(liquidGlass, forKey: "tag.liquidGlass")
        for (key, path, _) in Self.numericPreferences {
            defaults.set(self[keyPath: path], forKey: "tag.\(key)")
        }
        defaults.removeObject(forKey: "tag.appearDelay")
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
