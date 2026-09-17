//
//  TagConfiguration.swift
//  Callsign
//

import CoreGraphics

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
    // Fraction of the badge inside the chosen edge: 0 = outside, 1 = inside.
    var overlap = 0.5
    var scale = 1.0
    var appearDelay = 0.0
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
