import AppKit
import ApplicationServices
import Testing
@testable import Callsign

@MainActor
private final class ScriptedThumbnails: ThumbnailSource {
    let name = "Scripted"
    let usesWindowTitles = false
    var frames: [Thumbnail] = []

    func thumbnails(
        missionControl: AXUIElement,
        windows: [WindowInfo],
        windowTitles: [pid_t: [CGWindowID: String]]
    ) -> [Thumbnail] {
        frames
    }
}

@MainActor
private final class RecordingOverlays: BadgeSink {
    private(set) var shown: [(badges: [AppBadge], animated: Bool)] = []
    private(set) var hides = 0

    func show(_ badges: [AppBadge], configuration: TagConfiguration, animated: Bool) {
        shown.append((badges, animated))
    }

    func hide() { hides += 1 }
}

@MainActor
private final class Switch {
    var isOn = false
}

@MainActor
@Suite(.serialized)
struct MissionControlProbeTests {
    // PIDs without a running app, so names fall back to the window owner.
    private static let windows = [
        WindowInfo(
            id: 10, pid: .max, owner: "Editor", title: "",
            frame: CGRect(x: 100, y: 200, width: 400, height: 300), layer: 0, alpha: 1),
        WindowInfo(
            id: 20, pid: .max - 1, owner: "Browser", title: "",
            frame: CGRect(x: 700, y: 200, width: 500, height: 400), layer: 0, alpha: 1),
    ]
    private let thumbnails: ScriptedThumbnails
    private let overlays: RecordingOverlays
    private let missionControlOpen: Switch
    private let probe: MissionControlProbe
    private let configuration = TagConfiguration.default

    init() {
        let thumbnails = ScriptedThumbnails()
        let overlays = RecordingOverlays()
        let open = Switch()
        thumbnails.frames = [
            Thumbnail(windowID: 10, title: "Notes", frame: CGRect(x: 110, y: 220, width: 200, height: 150)),
            Thumbnail(windowID: 20, title: "Docs", frame: CGRect(x: 400, y: 220, width: 250, height: 200)),
        ]
        self.thumbnails = thumbnails
        self.overlays = overlays
        missionControlOpen = open
        // Any AX element will do; the scripted source never reads it.
        probe = MissionControlProbe(
            source: thumbnails,
            overlays: overlays,
            windowList: { Self.windows },
            locateMissionControl: { open.isOn ? (AXUIElementCreateSystemWide(), 1) : nil },
            isProcessTrusted: { true })
    }

    private func poll() -> Int { probe.poll(configuration: configuration) }

    private func open() -> Int {
        missionControlOpen.isOn = true
        #expect(poll() == 33)
        #expect(poll() == 33)
        return poll()
    }

    @Test func closedProbesAreReadyAndPollSlowly() {
        #expect(poll() == 100)
        #expect(probe.status == .ready)
        #expect(overlays.shown.isEmpty)
    }

    @Test func firstDetectionHidesBadgesUntilFramesSettle() {
        #expect(poll() == 100)
        missionControlOpen.isOn = true
        let hides = overlays.hides
        #expect(poll() == 33)
        // Entry reports the unsettled geometry measured by the same poll.
        #expect(probe.status == .transitioning)
        #expect(overlays.hides > hides)
        #expect(overlays.shown.isEmpty)

        thumbnails.frames = []
        #expect(poll() == 33)
        #expect(probe.status == .waitingForFrames)
        #expect(overlays.shown.isEmpty)
    }

    @Test func twoUnchangedPollsShowBadgesOnce() throws {
        #expect(open() == 100)
        let shown = try #require(overlays.shown.last)
        #expect(overlays.shown.count == 1)
        #expect(shown.animated)
        #expect(shown.badges.map(\.windowID) == [10, 20])
        #expect(shown.badges.map(\.appName) == ["Editor", "Browser"])
        #expect(shown.badges.map(\.windowTitle) == ["Notes", "Docs"])
        #expect(shown.badges.map(\.thumbnailFrame) == thumbnails.frames.map(\.frame))
        guard case let .active(labeled, total, source, settled) = probe.status else {
            Issue.record("Unexpected status \(probe.status)")
            return
        }
        #expect(labeled == 2 && total == 2 && source == "Scripted")
        #expect(settled != nil)

        // Settled polls stay slow and do not relayout badges more than 10 times a second.
        #expect(poll() == 100)
        #expect(overlays.shown.count == 1)
    }

    @Test func movementAfterSettlingHidesBadgesAndFadesThemBackIn() throws {
        #expect(open() == 100)
        let hides = overlays.hides
        thumbnails.frames = thumbnails.frames.map {
            Thumbnail(windowID: $0.windowID, title: $0.title, frame: $0.frame.offsetBy(dx: 40, dy: 0))
        }
        #expect(poll() == 33)
        #expect(probe.status == .transitioning)
        #expect(overlays.hides > hides)
        #expect(poll() == 33)
        #expect(poll() == 100)
        #expect(overlays.shown.count == 2)
        #expect(overlays.shown.last?.animated == true)
    }

    @Test func spaceChangesHideSettledBadges() {
        #expect(open() == 100)
        let hides = overlays.hides
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
        #expect(probe.status == .transitioning)
        #expect(overlays.hides > hides)
        // The Space change restarts settling even though no frame moved: two unchanged polls, as after a move.
        #expect(poll() == 33)
        #expect(poll() == 100)
        #expect(overlays.shown.count == 2)
        #expect(overlays.shown.last?.animated == true)
    }

    @Test func closingMissionControlResetsAndHides() {
        #expect(open() == 100)
        missionControlOpen.isOn = false
        let hides = overlays.hides
        #expect(poll() == 100)
        #expect(probe.status == .closed)
        #expect(overlays.hides > hides)
        #expect(poll() == 100)
        #expect(probe.status == .ready)

        // Reopening starts a fresh settle and fade-in.
        #expect(open() == 100)
        #expect(overlays.shown.count == 2)
        #expect(overlays.shown.last?.animated == true)
    }

    @Test func stopPausesAndHides() {
        #expect(open() == 100)
        let hides = overlays.hides
        probe.stop()
        #expect(probe.status == .paused)
        #expect(overlays.hides > hides)
    }

    @Test func untrustedProbesWaitForAccessibility() {
        let probe = MissionControlProbe(
            source: thumbnails,
            overlays: overlays,
            windowList: { [] },
            locateMissionControl: { (AXUIElementCreateSystemWide(), 1) },
            isProcessTrusted: { false })
        #expect(!probe.isTrusted)
        #expect(probe.poll(configuration: configuration) == 500)
        #expect(probe.status == .accessibilityRequired)
        #expect(overlays.shown.isEmpty)
    }

    @Test func statusTextMatchesTheSettingsCopy() {
        #expect(ProbeStatus.accessibilityRequired.text == "Accessibility access is required.")
        #expect(ProbeStatus.promptShown.text == "Enable Callsign in System Settings, then return here.")
        #expect(ProbeStatus.paused.text == "Callsign is paused.")
        #expect(ProbeStatus.ready.text == "Ready. Open Mission Control.")
        #expect(ProbeStatus.closed.text == "Mission Control closed.")
        #expect(ProbeStatus.waitingForFrames.text == "Mission Control: waiting for thumbnail frames…")
        #expect(ProbeStatus.transitioning.text == "Mission Control transitioning. Tags hidden…")
        #expect(ProbeStatus.active(labeled: 1, total: 2, source: "AX", settledMilliseconds: nil).text
                == "Mission Control active. Labeled 1 of 2 windows (AX).")
        #expect(ProbeStatus.active(labeled: 2, total: 2, source: "WindowServer", settledMilliseconds: 70).text
                == "Mission Control active. Labeled 2 of 2 windows (WindowServer). Settled after ~70 ms.")
    }
}
