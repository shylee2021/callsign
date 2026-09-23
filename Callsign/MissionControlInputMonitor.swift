import AppKit
import ApplicationServices

struct MissionControlInteraction {
    private(set) var gestureActive = false
    private var awaitingMotionUntil = 0.0

    mutating func receiveGesture(phase: Int64) -> Bool {
        switch phase {
        case 1, 2: gestureActive = true // Began or changed, including a missed begin event.
        case 4, 8: gestureActive = false // Ended or cancelled.
        default: return false
        }
        awaitingMotionUntil = 0
        return true
    }

    mutating func anticipateMotion(at now: TimeInterval) {
        // ponytail: allow 250 ms for a shortcut to start moving windows; don't wait forever on a no-op.
        awaitingMotionUntil = now + 0.25
    }

    mutating func observedMotion() {
        awaitingMotionUntil = 0
    }

    func blocksSettling(at now: TimeInterval) -> Bool {
        gestureActive || now < awaitingMotionUntil
    }
}

@MainActor
final class MissionControlInputMonitor {
    var onTransition: (() -> Void)?
    var missionControlIsOpen = false {
        didSet { if !missionControlIsOpen { selectingScreenshot = false } }
    }
    private var selectingScreenshot = false
    private(set) var interaction = MissionControlInteraction()
    private(set) var gestureEventCount = 0
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var spaceObserver: NSObjectProtocol?
    private let workspaceCenter = NSWorkspace.shared.notificationCenter
    private var lastStartAttempt = -Double.infinity

    var isRunning: Bool {
        tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
    }

    func start() {
        guard !isRunning else { return }
        if tap != nil {
            stop()
            onTransition?()
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastStartAttempt >= 1 else { return }
        lastStartAttempt = now

        if spaceObserver == nil {
            spaceObserver = workspaceCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.selectingScreenshot = false
                    self?.onTransition?()
                }
            }
        }

        let types: [UInt32] = [
            30, 14, // Private DockControl and system-defined (e.g. Mission Control media key).
            CGEventType.keyDown.rawValue,
            CGEventType.leftMouseDown.rawValue,
            CGEventType.leftMouseUp.rawValue,
            CGEventType.rightMouseDown.rawValue,
            CGEventType.otherMouseDown.rawValue,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                if let context {
                    // The tap source is installed only on the main run loop.
                    MainActor.assumeIsolated {
                        Unmanaged<MissionControlInputMonitor>.fromOpaque(context)
                            .takeUnretainedValue().handle(type: type, event: event)
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func anticipateTransition() {
        selectingScreenshot = false
        interaction.anticipateMotion(at: ProcessInfo.processInfo.systemUptime)
        onTransition?()
    }

    func observedMotion() {
        interaction.observedMotion()
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        if let spaceObserver { workspaceCenter.removeObserver(spaceObserver) }
        source = nil
        tap = nil
        spaceObserver = nil
        interaction = MissionControlInteraction()
        missionControlIsOpen = false
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        if let spaceObserver { workspaceCenter.removeObserver(spaceObserver) }
    }

    func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            selectingScreenshot = false
            interaction = MissionControlInteraction()
            onTransition?()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if type.rawValue == 30 {
            // Undocumented Dock swipe fields: HID type 23, axis 1/2, phase began/changed/ended/cancelled.
            // ponytail: verify these fields on new macOS releases; geometry remains the fallback.
            let hidType = event.getIntegerValueField(CGEventField(rawValue: 110)!)
            let axis = event.getIntegerValueField(CGEventField(rawValue: 123)!)
            guard hidType == 23, axis == 1 || axis == 2 else { return }
            let phase = event.getIntegerValueField(CGEventField(rawValue: 132)!)
            if interaction.receiveGesture(phase: phase) {
                selectingScreenshot = false
                gestureEventCount += 1
                onTransition?()
            }
            return
        }

        // Inputs are hints, not proof of animation. Observe only; never swallow or rewrite an event.
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let navigationKey = type == .keyDown && (
            (event.flags.contains(.maskControl) && (123...126).contains(key)) || key == 99)
        // ponytail: standard screenshot bindings; read symbolic hotkeys if custom bindings are needed.
        if type == .keyDown, event.flags.contains([.maskCommand, .maskShift]), key == 20 || key == 21 {
            selectingScreenshot = missionControlIsOpen && key == 21 // ⌘⇧4; Control also permits clipboard capture.
            return
        }
        if type == .leftMouseUp {
            selectingScreenshot = false
            return
        }
        if selectingScreenshot && !navigationKey {
            // Keep tags through selection, Space (window capture), and the capture click.
            if type == .keyDown && key == 53 { selectingScreenshot = false } // Escape cancels capture only.
            return
        }
        if missionControlIsOpen || navigationKey {
            anticipateTransition()
        }
    }
}
