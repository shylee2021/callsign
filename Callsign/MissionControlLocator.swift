//
//  MissionControlLocator.swift
//  Callsign
//

@preconcurrency import ApplicationServices
import AppKit
import os

@MainActor
final class MissionControlLocator {
    private static let dockBundleIdentifier = "com.apple.dock"

    private var dock: (element: AXUIElement, pid: pid_t)?
    private let workspaceCenter = NSWorkspace.shared.notificationCenter
    private var terminateObserver: NSObjectProtocol?

    init() {
        terminateObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let bundleIdentifier = app.bundleIdentifier
            MainActor.assumeIsolated {
                // A relaunched Dock gets a new PID and AX element.
                if bundleIdentifier == Self.dockBundleIdentifier { self?.dock = nil }
            }
        }
    }

    // Observer tokens are not Sendable, so remove this one on the main actor.
    isolated deinit {
        if let terminateObserver { workspaceCenter.removeObserver(terminateObserver) }
    }

    // The Mission Control AX group and the Dock PID, or nil while Mission Control is closed.
    func currentMissionControl() -> (AXUIElement, pid_t)? {
        if dock == nil, let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.dockBundleIdentifier).first {
            dock = (AXUIElementCreateApplication(app.processIdentifier), app.processIdentifier)
        }
        guard let dock else { return nil }

        // A failed read may mean a relaunched Dock without a notification; resolve it again next poll.
        guard let children = Accessibility.attribute(kAXChildrenAttribute, of: dock.element) as? [AXUIElement] else {
            Log.detection.info("Dropped the cached Dock element after a failed AXChildren read")
            self.dock = nil
            return nil
        }
        // Mission Control lives in the Dock's AX tree; these identifiers are macOS internals.
        guard let group = children.first(where: {
            Accessibility.string(kAXIdentifierAttribute, of: $0) == "mc"
        }) else { return nil }
        return (group, dock.pid)
    }
}
