//
//  MissionControlProbe.swift
//  Callsign
//

import ApplicationServices
import AppKit
import Combine

struct Thumbnail {
    let title: String
    let frame: CGRect

    static func fromWindowServer(_ windows: [WindowInfo]) -> [Thumbnail] {
        // ponytail: assumes WindowServer bounds track thumbnails; revisit if their layouts diverge.
        return windows.filter(\.canReceiveBadge)
            .map { Thumbnail(title: $0.title, frame: $0.frame) }
    }
}

struct WindowInfo {
    let pid: pid_t
    let owner: String
    let title: String
    let frame: CGRect
    let layer: Int
    let alpha: Double

    var canReceiveBadge: Bool {
        // WindowManager's hover decoration is system UI, even when it appears on layer 0.
        layer == 0 && alpha > 0.01 && owner != "WindowManager"
    }
}

struct AppBadge {
    let pid: pid_t
    let appName: String
    let windowTitle: String
    let icon: NSImage
    let thumbnailFrame: CGRect
}

private struct AppIdentity {
    let name: String
    let icon: NSImage
}

private enum MissionControlPhase {
    case normal, entering, active, exiting
}

// Dock accessibility (AX) detects Mission Control on both versions.
// Thumbnail geometry comes from AX on macOS 26 and WindowServer on macOS 27+.
@MainActor
final class MissionControlProbe: ObservableObject {
    @Published private(set) var isTrusted = AXIsProcessTrusted()
    @Published private(set) var status = "Accessibility access is required."
    @Published private(set) var report = ""

    private let overlays = OverlayManager()
    private let sceneProbe = SceneProbe()
    private var phase = MissionControlPhase.normal
    private var stableProbeReads = 0
    private var unreadableProbeReads = 0
    private var sawSceneMovement = false
    private var exitFadeStarted = false
    private var readySince: TimeInterval?
    private var reportTask: Task<Void, Never>?
    private var lastBadgeSync = 0.0
    private var appCache: [pid_t: AppIdentity] = [:]

    func requestAccess() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        status = "Enable Callsign in System Settings, then return here."
    }

    func openMissionControl() {
        do {
            try Process.run(
                URL(fileURLWithPath: "/usr/bin/open"),
                arguments: ["-b", "com.apple.exposelauncher"])
        } catch {
            status = "Could not open Mission Control: \(error.localizedDescription)"
        }
    }

    func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    func poll(configuration: TagConfiguration) -> Int {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
        }
        guard trusted else {
            resetMissionControl()
            status = "Accessibility access is required."
            return 500
        }
        guard let (missionControl, dockPID) = currentMissionControl() else {
            let wasRunning = phase != .normal
            if wasRunning {
                resetMissionControl()
            }
            status = wasRunning
                ? "Mission Control closed — latest capture retained."
                : "Ready — open Mission Control."
            return 33
        }

        if phase == .normal {
            resetMissionControl()
            phase = .entering
            sceneProbe.show()
            status = "Mission Control entering…"
            return 33
        }

        switch sceneProbe.isAtRest() {
        case true:
            unreadableProbeReads = 0
            if phase != .active && trackpadGestureIsActive() {
                stableProbeReads = 0
                readySince = nil
                return 33
            }
            stableProbeReads += 1
        case false:
            stableProbeReads = 0
            unreadableProbeReads = 0
            sawSceneMovement = true
            readySince = nil
            if phase == .active {
                phase = .exiting
                exitFadeStarted = false
                status = "Mission Control transitioning…"
            }
            if phase == .exiting,
               !exitFadeStarted,
               !trackpadGestureIsActive() {
                exitFadeStarted = true
                overlays.fadeOut(after: configuration.disappearDelay)
            }
            return 33
        case nil:
            unreadableProbeReads += 1
            guard unreadableProbeReads >= 30 else { return 33 }
            // ponytail: fail open after one second if WindowServer stops listing the probe.
            stableProbeReads = 3
        }

        let requiredStableReads = phase == .entering && !sawSceneMovement ? 3 : 1
        guard stableProbeReads >= requiredStableReads else { return 33 }
        let now = ProcessInfo.processInfo.systemUptime
        if phase == .entering {
            readySince = readySince ?? now
            guard now - (readySince ?? now) >= configuration.appearDelay else { return 33 }
        }
        let shouldFadeIn = phase == .entering
        phase = .active
        exitFadeStarted = false
        readySince = nil

        guard shouldFadeIn || now - lastBadgeSync >= 0.1 else { return 33 }
        lastBadgeSync = now

        let windows = onScreenWindows()
        let thumbnails: [Thumbnail]
        let source: String
        if #available(macOS 27, *) {
            // macOS 27 can expose an empty AX group, so do not rely on its children.
            thumbnails = Thumbnail.fromWindowServer(windows)
            source = "WindowServer"
        } else {
            thumbnails = missionControlThumbnails(in: missionControl)
            source = "AX"
        }
        let badges = thumbnails.compactMap { thumbnail -> AppBadge? in
            guard let window = matchingWindow(for: thumbnail, in: windows) else { return nil }
            let identity = appIdentity(for: window)
            return AppBadge(
                pid: window.pid,
                appName: identity.name,
                windowTitle: thumbnail.title,
                icon: identity.icon,
                thumbnailFrame: thumbnail.frame)
        }

        overlays.show(
            badges,
            configuration: configuration,
            animated: shouldFadeIn)
        status = "Mission Control active — labeled \(badges.count) of \(thumbnails.count) windows (\(source))."

        scheduleReport(for: missionControl, dockPID: dockPID, windows: windows)
        return 33
    }

    private func trackpadGestureIsActive() -> Bool {
        // ponytail: raw gesture type 29 is macOS-specific; replace if Apple exposes touch-state API.
        guard let gesture = CGEventType(rawValue: 29) else { return false }
        return CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: gesture) < 0.05
    }

    private func currentMissionControl() -> (AXUIElement, pid_t)? {
        guard let dock = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock").first else { return nil }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(dockElement, 0.2)
        guard let group = children(of: dockElement).first(where: {
            stringAttribute("AXIdentifier", of: $0) == "mc"
        }) else { return nil }
        return (group, dock.processIdentifier)
    }

    private func resetMissionControl() {
        phase = .normal
        stableProbeReads = 0
        unreadableProbeReads = 0
        sawSceneMovement = false
        exitFadeStarted = false
        readySince = nil
        reportTask?.cancel()
        reportTask = nil
        lastBadgeSync = 0
        sceneProbe.hide()
        overlays.hide()
    }

    private func appIdentity(for window: WindowInfo) -> AppIdentity {
        if let cached = appCache[window.pid] { return cached }
        let app = NSRunningApplication(processIdentifier: window.pid)
        let identity = AppIdentity(
            name: app?.localizedName ?? window.owner,
            icon: app?.icon ?? NSImage(
                systemSymbolName: "app.fill",
                accessibilityDescription: window.owner) ?? NSImage(size: NSSize(width: 32, height: 32)))
        appCache[window.pid] = identity
        return identity
    }

    private func missionControlThumbnails(in group: AXUIElement) -> [Thumbnail] {
        children(of: group)
            .filter { stringAttribute("AXIdentifier", of: $0) == "mc.display" }
            .flatMap(children)
            .filter { stringAttribute("AXIdentifier", of: $0) == "mc.windows" }
            .flatMap(children)
            .compactMap { element in
                guard let frame = frame(of: element) else { return nil }
                return Thumbnail(
                    title: stringAttribute("AXTitle", of: element) ?? "",
                    frame: frame)
            }
    }

    private func matchingWindow(for thumbnail: Thumbnail, in windows: [WindowInfo]) -> WindowInfo? {
        let candidates = windows.filter(\.canReceiveBadge)
        guard let nearest = candidates.min(by: {
            frameDistance($0.frame, thumbnail.frame) < frameDistance($1.frame, thumbnail.frame)
        }) else { return nil }

        // Hovering a Mission Control thumbnail can shift each edge by roughly 30 points.
        return frameDistance(nearest.frame, thumbnail.frame) < 160 ? nearest : nil
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX)
            + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
    }

    private func scheduleReport(
        for missionControl: AXUIElement,
        dockPID: pid_t,
        windows: [WindowInfo]
    ) {
        // Keep the completed task until reset: capture at most once per session.
        guard reportTask == nil else { return }
        reportTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch { return }
            guard let self, self.phase == .active else { return }
            let payload = self.makeReport(for: missionControl, dockPID: dockPID, windows: windows)
            self.report = "Captured \(Date().formatted(date: .omitted, time: .standard))\n\n\(payload)"
        }
    }

    private func makeReport(
        for missionControl: AXUIElement,
        dockPID: pid_t,
        windows: [WindowInfo]
    ) -> String {
        var remaining = 500
        let tree = dumpTree(missionControl, depth: 0, remaining: &remaining)
            .joined(separator: "\n")
        return "MISSION CONTROL AX TREE\n\(tree)\n\nON-SCREEN WINDOWS\n\(windowReport(dockPID: dockPID, windows: windows))"
    }

    private func dumpTree(
        _ element: AXUIElement,
        depth: Int,
        remaining: inout Int
    ) -> [String] {
        guard remaining > 0 else { return ["\(String(repeating: "  ", count: depth))… node limit reached"] }
        remaining -= 1

        let indent = String(repeating: "  ", count: depth)
        let role = stringAttribute("AXRole", of: element) ?? "?"
        let identifier = stringAttribute("AXIdentifier", of: element)
        let title = stringAttribute("AXTitle", of: element)
        let description = stringAttribute("AXDescription", of: element)
        let frame = frame(of: element)
        let childElements = children(of: element)
        var details = [role]
        if let identifier, !identifier.isEmpty { details.append("id=\(identifier)") }
        if let title, !title.isEmpty { details.append("title=\(title.debugDescription)") }
        if let description, !description.isEmpty { details.append("description=\(description.debugDescription)") }
        if let frame {
            details.append(String(
                format: "frame=(%.0f, %.0f, %.0f, %.0f)",
                frame.origin.x, frame.origin.y, frame.width, frame.height))
        }
        details.append("children=\(childElements.count)")

        var lines = [indent + details.joined(separator: "  ")]
        guard depth < 8 else { return lines }
        for child in childElements.prefix(50) {
            lines.append(contentsOf: dumpTree(child, depth: depth + 1, remaining: &remaining))
        }
        if childElements.count > 50 {
            lines.append("\(indent)  … \(childElements.count - 50) children omitted")
        }
        return lines
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        attribute("AXChildren", of: element) as? [AXUIElement] ?? []
    }

    private func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        attribute(name, of: element) as? String
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard
            let positionValue = attribute("AXPosition", of: element),
            let sizeValue = attribute("AXSize", of: element),
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func onScreenWindows() -> [WindowInfo] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]] else { return [] }

        return windows.compactMap { window in
            let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let frame = CGRect(
                x: number(bounds["X"]).doubleValue,
                y: number(bounds["Y"]).doubleValue,
                width: number(bounds["Width"]).doubleValue,
                height: number(bounds["Height"]).doubleValue)
            guard frame.width > 1, frame.height > 1 else { return nil }
            return WindowInfo(
                pid: pid_t(number(window[kCGWindowOwnerPID as String]).int32Value),
                owner: window[kCGWindowOwnerName as String] as? String ?? "?",
                title: window[kCGWindowName as String] as? String ?? "",
                frame: frame,
                layer: number(window[kCGWindowLayer as String]).intValue,
                alpha: number(window[kCGWindowAlpha as String]).doubleValue)
        }
    }

    private func windowReport(dockPID: pid_t, windows: [WindowInfo]) -> String {
        windows
            .filter { $0.layer == 0 || $0.pid == dockPID }
            .map { window in
                String(
                    format: "layer=%d pid=%d owner=%@ title=%@ frame=(%.0f, %.0f, %.0f, %.0f) alpha=%.2f",
                    window.layer,
                    window.pid,
                    window.owner,
                    window.title.debugDescription,
                    window.frame.origin.x,
                    window.frame.origin.y,
                    window.frame.width,
                    window.frame.height,
                    window.alpha)
            }
            .joined(separator: "\n")
    }

    private func number(_ value: Any?) -> NSNumber {
        value as? NSNumber ?? 0
    }
}
