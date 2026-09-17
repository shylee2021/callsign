import CoreGraphics
import Testing
@testable import Callsign

@MainActor
struct TransitionTests {
    private let thumbnail = CGRect(x: 100, y: 200, width: 400, height: 300)

    @Test func settlingRequiresTwoUnchangedPolls() {
        var stability = ThumbnailStability()
        let frames = [thumbnail, thumbnail.offsetBy(dx: 600, dy: 0)]
        #expect(stability.update(frames: frames, blocked: false) == false)
        #expect(!stability.didMove)
        #expect(stability.update(frames: frames, blocked: false) == false)
        #expect(stability.update(frames: frames.reversed(), blocked: false) == true)

        let moved = frames.map { $0.offsetBy(dx: 20, dy: -10) }
        #expect(stability.update(frames: moved, blocked: false) == false)
        #expect(stability.didMove)
        #expect(stability.update(frames: moved, blocked: false) == false)
        #expect(stability.update(frames: moved, blocked: false) == true)
    }

    @Test func pausedGestureBlocksSettlingUntilRelease() {
        var stability = ThumbnailStability()
        var interaction = MissionControlInteraction()
        #expect(interaction.receiveGesture(phase: 1) == true)
        #expect(stability.update(frames: [thumbnail], blocked: interaction.blocksSettling(at: 10)) == false)
        #expect(interaction.blocksSettling(at: 100))
        #expect(interaction.receiveGesture(phase: 0) == false)
        #expect(interaction.gestureActive)
        #expect(interaction.receiveGesture(phase: 4) == true)
        #expect(stability.update(frames: [thumbnail], blocked: interaction.blocksSettling(at: 100)) == false)
        #expect(stability.update(frames: [thumbnail], blocked: false) == false)
        #expect(stability.update(frames: [thumbnail], blocked: false) == true)
        #expect(interaction.receiveGesture(phase: 2) == true)
        #expect(interaction.receiveGesture(phase: 8) == true)
        #expect(!interaction.blocksSettling(at: 101))
    }

    @Test func shortcutHintsClearOnMotionOrExpire() {
        var stability = ThumbnailStability()
        var interaction = MissionControlInteraction()
        interaction.anticipateMotion(at: 102)
        #expect(stability.update(frames: [thumbnail], blocked: interaction.blocksSettling(at: 102.02)) == false)
        let moved = [thumbnail.offsetBy(dx: 20, dy: -10)]
        #expect(stability.update(frames: moved, blocked: interaction.blocksSettling(at: 102.04)) == false)
        #expect(stability.didMove)
        interaction.observedMotion()
        #expect(!interaction.blocksSettling(at: 102.04))
        #expect(stability.update(frames: moved, blocked: false) == false)
        #expect(stability.update(frames: moved, blocked: false) == false)
        #expect(stability.update(frames: moved, blocked: false) == true)
        interaction.anticipateMotion(at: 103)
        #expect(interaction.blocksSettling(at: 103.10))
        #expect(!interaction.blocksSettling(at: 103.30))
    }

    @Test func windowChangesAndInvalidationRestartSettling() {
        var stability = ThumbnailStability()
        let frames = [thumbnail, thumbnail.offsetBy(dx: 600, dy: 0)]
        #expect(stability.update(frames: frames, blocked: false) == false)
        #expect(stability.update(frames: frames, blocked: false) == false)
        #expect(stability.update(frames: frames, blocked: false) == true)
        #expect(stability.update(frames: [thumbnail], blocked: false) == false)
        #expect(stability.update(frames: [thumbnail], blocked: false) == false)
        #expect(stability.update(frames: [thumbnail], blocked: false) == true)
        #expect(stability.update(frames: [], blocked: false) == false)
        #expect(stability.update(frames: [], blocked: false) == false)
        #expect(stability.update(frames: [thumbnail], blocked: false) == false)
        #expect(stability.update(frames: [thumbnail], blocked: false) == false)
        #expect(stability.update(frames: [thumbnail], blocked: false) == true)
        stability.invalidate()
        #expect(stability.update(frames: [thumbnail], blocked: false) == false)
        #expect(stability.update(frames: [thumbnail], blocked: false) == false)
        #expect(stability.update(frames: [thumbnail], blocked: false) == true)
    }

    @Test func subPointDriftAccumulatesAcrossPolls() {
        var stability = ThumbnailStability()
        #expect(stability.update(frames: [thumbnail], blocked: false) == false)
        #expect(stability.update(frames: [thumbnail.offsetBy(dx: 0.75, dy: 0)], blocked: false) == false)
        #expect(stability.update(frames: [thumbnail.offsetBy(dx: 1.5, dy: 0)], blocked: false) == false)
        #expect(stability.update(frames: [thumbnail.offsetBy(dx: 1.5, dy: 0)], blocked: false) == false)
        #expect(stability.update(frames: [thumbnail.offsetBy(dx: 1.5, dy: 0)], blocked: false) == true)
    }

    @Test func inputMonitorDecodesTransitionsAndRecoversFromDisabledTap() throws {
        // Decode synthetic events without installing a tap, requesting access, or posting input.
        let monitor = MissionControlInputMonitor()
        var transitions = 0
        monitor.onTransition = { transitions += 1 }
        let event = try #require(CGEvent(source: nil))
        event.type = CGEventType(rawValue: 30)!
        event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 23)
        event.setIntegerValueField(CGEventField(rawValue: 123)!, value: 2)
        event.setIntegerValueField(CGEventField(rawValue: 132)!, value: 1)
        monitor.handle(type: CGEventType(rawValue: 30)!, event: event)
        #expect(monitor.interaction.gestureActive && transitions == 1)
        event.setIntegerValueField(CGEventField(rawValue: 132)!, value: 4)
        monitor.handle(type: CGEventType(rawValue: 30)!, event: event)
        #expect(!monitor.interaction.gestureActive && transitions == 2)
        event.setIntegerValueField(CGEventField(rawValue: 123)!, value: 1)
        event.setIntegerValueField(CGEventField(rawValue: 132)!, value: 2)
        monitor.handle(type: CGEventType(rawValue: 30)!, event: event)
        #expect(monitor.interaction.gestureActive && transitions == 3)
        monitor.handle(type: .tapDisabledByTimeout, event: event)
        #expect(!monitor.interaction.gestureActive && transitions == 4)
        event.setIntegerValueField(CGEventField(rawValue: 123)!, value: 3)
        monitor.handle(type: CGEventType(rawValue: 30)!, event: event)
        #expect(transitions == 4)
        event.type = .keyDown
        event.flags = .maskControl
        event.setIntegerValueField(.keyboardEventKeycode, value: 124)
        monitor.handle(type: .keyDown, event: event)
        #expect(transitions == 5)
        monitor.missionControlIsOpen = true
        monitor.handle(type: .otherMouseDown, event: event)
        #expect(transitions == 6)
        monitor.stop()
        #expect(!monitor.interaction.gestureActive && !monitor.isRunning)
    }
}
