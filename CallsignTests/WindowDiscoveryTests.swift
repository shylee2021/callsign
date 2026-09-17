import CoreGraphics
import Testing
@testable import Callsign

@MainActor
struct WindowDiscoveryTests {
    @Test func windowServerThumbnailsExcludeSystemOverlays() {
        let frame = CGRect(x: 100, y: 200, width: 400, height: 300)
        let windows = [
            WindowInfo(id: 101, pid: 1, owner: "App", title: "", frame: frame, layer: 0, alpha: 1),
            WindowInfo(id: 102, pid: 2, owner: "Dock", title: "", frame: frame, layer: 20, alpha: 1),
            WindowInfo(id: 103, pid: 3, owner: "Hidden", title: "", frame: frame, layer: 0, alpha: 0),
            WindowInfo(id: 104, pid: 4, owner: "WindowManager", title: "", frame: frame, layer: 0, alpha: 1),
        ]
        #expect(windows.filter(\.canReceiveBadge).map(\.pid) == [1])
        let thumbnails = Thumbnail.fromWindowServer(windows, accessibilityTitles: [:])
        #expect(thumbnails.count == 1)
        #expect(thumbnails.first?.windowID == 101)
        #expect(thumbnails.first?.frame == frame)
        #expect(thumbnails.first?.title == "")
        #expect(Thumbnail.fromWindowServer([], accessibilityTitles: [:]).isEmpty)
    }

    @Test func windowIDsKeepTitlesWithTheRightWindow() throws {
        let frame = CGRect(x: 100, y: 200, width: 400, height: 300)
        let windows = [
            WindowInfo(id: 10, pid: 1, owner: "Editor", title: "", frame: frame, layer: 0, alpha: 1),
            WindowInfo(id: 20, pid: 1, owner: "Editor", title: "", frame: frame, layer: 0, alpha: 1),
        ]
        let thumbnails = Thumbnail.fromWindowServer(
            windows, accessibilityTitles: [1: [10: "First document", 20: "Second document"]])
        #expect(thumbnails.map(\.title) == ["First document", "Second document"])
        let thumbnail = try #require(thumbnails.last)
        let matched = try #require(thumbnail.matchingWindow(in: windows))
        #expect(matched.id == 20)
        let disappeared = Thumbnail(windowID: 99, title: "", frame: frame)
        #expect(disappeared.matchingWindow(in: windows) == nil)
    }

    @Test func windowServerThumbnailsUseOnlyAppAccessibilityTitles() {
        let window = WindowInfo(id: 10, pid: 1, owner: "Editor", title: "Server title", frame: .zero, layer: 0, alpha: 1)
        #expect(Thumbnail.fromWindowServer(
            [window], accessibilityTitles: [1: [10: "App AX title"]]).first?.title == "App AX title")
        #expect(Thumbnail.fromWindowServer([window], accessibilityTitles: [:]).first?.title == "")
        #expect(Thumbnail.fromWindowServer(
            [window], accessibilityTitles: [2: [10: "Wrong app"]]).first?.title == "")
        #expect(Thumbnail.fromWindowServer(
            [window], accessibilityTitles: [1: [20: "Wrong window"]]).first?.title == "")
    }

    @Test func dockThumbnailsStillMatchByGeometry() {
        let frame = CGRect(x: 100, y: 200, width: 400, height: 300)
        let window = WindowInfo(id: 10, pid: 1, owner: "Editor", title: "", frame: frame, layer: 0, alpha: 1)
        let thumbnail = Thumbnail(windowID: nil, title: "Dock title", frame: frame.offsetBy(dx: 20, dy: 30))
        #expect(thumbnail.matchingWindow(in: [window])?.id == 10)
        let distant = Thumbnail(windowID: nil, title: "", frame: frame.offsetBy(dx: 1_000, dy: 0))
        #expect(distant.matchingWindow(in: [window]) == nil)
    }
}
