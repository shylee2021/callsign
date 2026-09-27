import AppKit
import Testing
@testable import Callsign

struct TransitionTests {
    private let thumbnail = CGRect(x: 100, y: 200, width: 400, height: 300)

    @Test func settlingRequiresTwoUnchangedPolls() {
        var stability = ThumbnailStability()
        let frames = [thumbnail, thumbnail.offsetBy(dx: 600, dy: 0)]
        #expect(stability.update(frames: frames) == false)
        #expect(stability.update(frames: frames) == false)
        #expect(stability.update(frames: frames.reversed()) == true)
        // No keyboard/mouse hints or gesture phases are needed to stay settled.
        #expect(stability.update(frames: frames) == true)

        let moved = frames.map { $0.offsetBy(dx: 20, dy: -10) }
        #expect(stability.update(frames: moved) == false)
        #expect(stability.update(frames: moved) == false)
        #expect(stability.update(frames: moved) == true)
    }

    @Test func windowChangesAndInvalidationRestartSettling() {
        var stability = ThumbnailStability()
        let frames = [thumbnail, thumbnail.offsetBy(dx: 600, dy: 0)]
        #expect(stability.update(frames: frames) == false)
        #expect(stability.update(frames: frames) == false)
        #expect(stability.update(frames: frames) == true)
        #expect(stability.update(frames: [thumbnail]) == false)
        #expect(stability.update(frames: [thumbnail]) == false)
        #expect(stability.update(frames: [thumbnail]) == true)
        #expect(stability.update(frames: []) == false)
        #expect(stability.update(frames: []) == false)
        #expect(stability.update(frames: [thumbnail]) == false)
        #expect(stability.update(frames: [thumbnail]) == false)
        #expect(stability.update(frames: [thumbnail]) == true)
        stability.invalidate()
        #expect(stability.update(frames: [thumbnail]) == false)
        #expect(stability.update(frames: [thumbnail]) == true)
    }

    @Test func subPointDriftAccumulatesAcrossPolls() {
        var stability = ThumbnailStability()
        #expect(stability.update(frames: [thumbnail]) == false)
        #expect(stability.update(frames: [thumbnail.offsetBy(dx: 0.75, dy: 0)]) == false)
        #expect(stability.update(frames: [thumbnail.offsetBy(dx: 1.5, dy: 0)]) == false)
        #expect(stability.update(frames: [thumbnail.offsetBy(dx: 1.5, dy: 0)]) == false)
        #expect(stability.update(frames: [thumbnail.offsetBy(dx: 1.5, dy: 0)]) == true)
    }

    @Test func pollingSlowsWhileClosedOrSettled() {
        #expect(MissionControlProbe.pollDelay(missionControlOpen: false, settled: false, awaitingTitles: false) == 100)
        #expect(MissionControlProbe.pollDelay(missionControlOpen: true, settled: false, awaitingTitles: false) == 33)
        #expect(MissionControlProbe.pollDelay(missionControlOpen: true, settled: true, awaitingTitles: false) == 100)
        // A title read in flight keeps polls fast so the late title appears promptly.
        #expect(MissionControlProbe.pollDelay(missionControlOpen: true, settled: true, awaitingTitles: true) == 33)
    }

    @Test func movementAfterSettlingRestoresFastPolling() {
        var stability = ThumbnailStability()
        func delay(_ frames: [CGRect]) -> Int {
            MissionControlProbe.pollDelay(
                missionControlOpen: true, settled: stability.update(frames: frames), awaitingTitles: false)
        }
        #expect(delay([thumbnail]) == 33)
        #expect(delay([thumbnail]) == 33)
        #expect(delay([thumbnail]) == 100)
        #expect(delay([thumbnail.offsetBy(dx: 40, dy: 0)]) == 33)
    }

    @Test func spaceNotificationsDoNotRestartOrRetainPausedProbes() {
        weak var released: MissionControlProbe?
        do {
            let probe = MissionControlProbe()
            released = probe
            probe.stop()
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared)
            #expect(probe.status == .paused)
        }
        #expect(released == nil)
    }
}
