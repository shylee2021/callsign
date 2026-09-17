import CoreGraphics
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

    @Test func labelSelectionAndFallback() {
        #expect(TagLabel.appName.text(appName: "App", windowTitle: "Window") == "App")
        #expect(TagLabel.windowTitle.text(appName: "App", windowTitle: "Window") == "Window")
        #expect(TagLabel.windowTitle.text(appName: "App", windowTitle: "") == "App")
        #expect(TagLabel.iconOnly.text(appName: "App", windowTitle: "Window") == nil)
    }
}
