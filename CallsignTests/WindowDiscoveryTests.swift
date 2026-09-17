import CoreGraphics
import Testing
@testable import Callsign

@MainActor
struct WindowDiscoveryTests {
    @Test func windowServerThumbnailsExcludeSystemOverlays() {
        let frame = CGRect(x: 100, y: 200, width: 400, height: 300)
        let windows = [
            WindowInfo(pid: 1, owner: "App", title: "", frame: frame, layer: 0, alpha: 1),
            WindowInfo(pid: 2, owner: "Dock", title: "", frame: frame, layer: 20, alpha: 1),
            WindowInfo(pid: 3, owner: "Hidden", title: "", frame: frame, layer: 0, alpha: 0),
            WindowInfo(pid: 4, owner: "WindowManager", title: "", frame: frame, layer: 0, alpha: 1),
        ]
        #expect(windows.filter(\.canReceiveBadge).map(\.pid) == [1])
        let thumbnails = Thumbnail.fromWindowServer(windows)
        #expect(thumbnails.count == 1)
        #expect(thumbnails.first?.frame == frame)
        #expect(thumbnails.first?.title == "")
        #expect(Thumbnail.fromWindowServer([]).isEmpty)
    }
}
