//
//  MissionControlProbe.swift
//  Callsign
//

import ApplicationServices
import AppKit
import Combine
import Darwin

struct Thumbnail {
    let windowID: CGWindowID?
    let title: String
    let frame: CGRect

    static func fromWindowServer(
        _ windows: [WindowInfo],
        accessibilityTitles: [pid_t: [CGWindowID: String]]
    ) -> [Thumbnail] {
        // ponytail: assumes WindowServer bounds track thumbnails; revisit if their layouts diverge.
        return windows.filter(\.canReceiveBadge)
            .map { Thumbnail(
                windowID: $0.id,
                title: accessibilityTitles[$0.pid]?[$0.id] ?? "",
                frame: $0.frame) }
    }

    func matchingWindow(in windows: [WindowInfo]) -> WindowInfo? {
        let candidates = windows.filter(\.canReceiveBadge)
        if let windowID {
            return candidates.first { $0.id == windowID }
        }

        // Tahoe's Dock AX thumbnails have no window ID; retain geometry matching there.
        func distance(_ rect: CGRect) -> CGFloat {
            abs(rect.minX - frame.minX) + abs(rect.minY - frame.minY)
                + abs(rect.width - frame.width) + abs(rect.height - frame.height)
        }
        guard let nearest = candidates.min(by: { distance($0.frame) < distance($1.frame) }) else { return nil }
        // Hovering can shift each thumbnail edge by roughly 30 points.
        return distance(nearest.frame) < 160 ? nearest : nil
    }
}

struct ThumbnailStability {
    private var referenceFrames: [CGRect] = []
    private var unchangedPolls: Int?
    private(set) var didMove = false

    mutating func invalidate() {
        unchangedPolls = nil
    }

    mutating func update(frames: [CGRect], blocked: Bool) -> Bool {
        // WindowServer may reorder windows when one is hovered; geometry order must stay consistent.
        let frames = frames.sorted {
            ($0.minX, $0.minY, $0.width, $0.height) < ($1.minX, $1.minY, $1.width, $1.height)
        }
        let moved = frames.count != referenceFrames.count || zip(frames, referenceFrames).contains {
            abs($0.minX - $1.minX) > 1 || abs($0.minY - $1.minY) > 1
                || abs($0.width - $1.width) > 1 || abs($0.height - $1.height) > 1
        }
        didMove = !referenceFrames.isEmpty && moved
        if moved {
            // Keep this reference until movement exceeds the tolerance, so slow drift accumulates.
            referenceFrames = frames
            unchangedPolls = nil
        }
        guard !frames.isEmpty, !blocked else {
            unchangedPolls = nil
            return false
        }
        guard let count = unchangedPolls else {
            unchangedPolls = 0
            return false
        }
        // ponytail: two quiet polls (~66 ms) estimate completion; increase if slow animations flash.
        unchangedPolls = min(count + 1, 2)
        return unchangedPolls == 2
    }
}

struct WindowInfo {
    let id: CGWindowID
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
    case normal, entering, active, transitioning
}

// Dock accessibility (AX) detects Mission Control on both versions.
// macOS 26 uses Dock AX thumbnails; macOS 27+ uses WindowServer frames and app AX titles.
@MainActor
final class MissionControlProbe: ObservableObject {
    @Published private(set) var isTrusted = AXIsProcessTrusted()
    @Published private(set) var status = "Accessibility access is required."
    @Published private(set) var report = ""

    private let overlays = OverlayManager()
    private let inputMonitor = MissionControlInputMonitor()
    private var phase = MissionControlPhase.normal
    private var stability = ThumbnailStability()
    private var settleStartedAt = 0.0
    private var settledMilliseconds: Int?
    private var readySince: TimeInterval?
    private var reportTask: Task<Void, Never>?
    private var lastBadgeSync = 0.0
    private var appCache: [pid_t: AppIdentity] = [:]
    private var accessibilityTitles: [pid_t: [CGWindowID: String]] = [:]
    private var titleTask: Task<Void, Never>?
    private var lastTitleSync = -Double.infinity

    init() {
        inputMonitor.onTransition = { [weak self] in
            guard let self else { return }
            self.stability.invalidate()
            self.suspendBadges()
        }
    }

    func requestAccess() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        status = "Enable Callsign in System Settings, then return here."
    }

    func openMissionControl() {
        inputMonitor.anticipateTransition()
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

    // Returns the delay in milliseconds before the UI should poll again.
    func poll(configuration: TagConfiguration) -> Int {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
        }
        guard trusted else {
            inputMonitor.stop()
            resetMissionControl()
            status = "Accessibility access is required."
            return 500
        }
        inputMonitor.start()
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
            settleStartedAt = ProcessInfo.processInfo.systemUptime
            status = "Mission Control entering…"
        }
        inputMonitor.missionControlIsOpen = true

        let windows = onScreenWindows()
        let thumbnails: [Thumbnail]
        let source: String
        if #available(macOS 27, *) {
            // macOS 27 can expose an empty AX group, so do not rely on its children.
            if configuration.label == .windowTitle {
                refreshAccessibilityTitles(for: windows)
            }
            thumbnails = Thumbnail.fromWindowServer(windows, accessibilityTitles: accessibilityTitles)
            source = "WindowServer"
        } else {
            thumbnails = missionControlThumbnails(in: missionControl)
            source = "AX"
        }

        let now = ProcessInfo.processInfo.systemUptime
        let settled = stability.update(
            frames: thumbnails.map(\.frame),
            blocked: inputMonitor.interaction.blocksSettling(at: now))
        if stability.didMove { inputMonitor.observedMotion() }
        if !settled {
            suspendBadges()
            settledMilliseconds = nil
            status = thumbnails.isEmpty
                ? "Mission Control — waiting for thumbnail frames…"
                : "Mission Control transitioning — tags hidden…"
            return 33
        }
        if phase != .active {
            if readySince == nil {
                readySince = now
                settledMilliseconds = Int((now - settleStartedAt) * 1_000)
                status = "Mission Control settled — waiting for appear delay…"
            }
            guard now - (readySince ?? now) >= configuration.appearDelay else { return 33 }
        }
        let shouldFadeIn = phase != .active
        phase = .active
        readySince = nil

        // Poll geometry every 33 ms, but refresh badge content and layout at most 10 Hz.
        guard shouldFadeIn || now - lastBadgeSync >= 0.1 else { return 33 }
        lastBadgeSync = now

        let badges = thumbnails.compactMap { thumbnail -> AppBadge? in
            guard let window = thumbnail.matchingWindow(in: windows) else { return nil }
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
        if let elapsed = settledMilliseconds {
            status += " Settled after ~\(elapsed) ms."
        }
        if !inputMonitor.isRunning {
            status += " Input monitor unavailable; using window motion only."
        }

        scheduleReport(for: missionControl, dockPID: dockPID, windows: windows)
        return 33
    }

    private func suspendBadges() {
        // Hiding must be immediate, including when an input arrives between geometry polls.
        overlays.hide()
        readySince = nil
        lastBadgeSync = 0
        if phase == .active {
            phase = .transitioning
            settleStartedAt = ProcessInfo.processInfo.systemUptime
            settledMilliseconds = nil
            reportTask?.cancel()
            reportTask = nil
            status = "Mission Control transitioning — tags hidden…"
        }
    }

    private func currentMissionControl() -> (AXUIElement, pid_t)? {
        guard let dock = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock").first else { return nil }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(dockElement, 0.2)
        // Mission Control lives in the Dock's AX tree; these identifiers are macOS internals.
        guard let group = children(of: dockElement).first(where: {
            stringAttribute("AXIdentifier", of: $0) == "mc"
        }) else { return nil }
        return (group, dock.processIdentifier)
    }

    private func resetMissionControl() {
        phase = .normal
        inputMonitor.missionControlIsOpen = false
        stability = ThumbnailStability()
        settleStartedAt = 0
        settledMilliseconds = nil
        readySince = nil
        reportTask?.cancel()
        reportTask = nil
        lastBadgeSync = 0
        titleTask?.cancel()
        titleTask = nil
        accessibilityTitles = [:]
        lastTitleSync = -Double.infinity
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
                    windowID: nil,
                    title: stringAttribute("AXTitle", of: element) ?? "",
                    frame: frame)
            }
    }

    private func refreshAccessibilityTitles(for windows: [WindowInfo]) {
        let now = ProcessInfo.processInfo.systemUptime
        guard titleTask == nil, now - lastTitleSync >= 1 else { return }
        lastTitleSync = now
        let candidates = windows.filter { $0.canReceiveBadge && $0.pid > 0 }
        let targets = Dictionary(grouping: candidates, by: \.pid).mapValues { Set($0.map(\.id)) }
        guard !targets.isEmpty else {
            accessibilityTitles = [:]
            return
        }

        // Read remote AX titles off the main thread so a slow app cannot stall gesture hiding.
        // Refresh once a second rather than doing AX IPC on every geometry poll.
        titleTask = Task.detached(priority: .utility) { [weak self] in
            let titles = Self.readAccessibilityTitles(for: targets)
            await MainActor.run { [weak self] in
                guard !Task.isCancelled, let self else { return }
                self.accessibilityTitles = titles
                self.titleTask = nil
            }
        }
    }

    private nonisolated static func readAccessibilityTitles(
        for targets: [pid_t: Set<CGWindowID>]
    ) -> [pid_t: [CGWindowID: String]] {
        // This private bridge identifies AX windows even when Mission Control scales their frames.
        typealias WindowIDFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        guard let handle = dlopen(nil, RTLD_LAZY) else { return [:] }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return [:] }
        let windowID = unsafeBitCast(symbol, to: WindowIDFunction.self)
        var titles: [pid_t: [CGWindowID: String]] = [:]
        for (pid, ids) in targets {
            guard !Task.isCancelled else { break }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.05)
            let windows = attribute("AXWindows", of: app) as? [AXUIElement] ?? []
            for window in windows {
                guard !Task.isCancelled else { break }
                AXUIElementSetMessagingTimeout(window, 0.05)
                var id: CGWindowID = 0
                guard windowID(window, &id) == .success, ids.contains(id),
                      let title = attribute("AXTitle", of: window) as? String, !title.isEmpty else { continue }
                titles[pid, default: [:]][id] = title
            }
        }
        return titles
    }

    private func scheduleReport(
        for missionControl: AXUIElement,
        dockPID: pid_t,
        windows: [WindowInfo]
    ) {
        // Keep the completed task until the next transition: one capture per settled layout.
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
        // Cap the diagnostic node budget because AX reads run on the main thread.
        var remaining = 500
        let tree = dumpTree(missionControl, depth: 0, remaining: &remaining)
            .joined(separator: "\n")
        let timing = settledMilliseconds.map { "~\($0) ms from transition detection to settled" } ?? "Not measured"
        let monitoring = inputMonitor.isRunning
            ? "Read-only input monitor active; Dock gesture events: \(inputMonitor.gestureEventCount)"
            : "Input monitor unavailable. Check Privacy & Security > Input Monitoring for Callsign."
        return "SETTLE TIMING\n\(timing) (2 unchanged polls, ~66 ms; 33 ms poll delay + API overhead; excludes appear delay)\n\(monitoring)\n\nMISSION CONTROL AX TREE\n\(tree)\n\nON-SCREEN WINDOWS\n\(windowReport(dockPID: dockPID, windows: windows))"
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
        Self.attribute("AXChildren", of: element) as? [AXUIElement] ?? []
    }

    private func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        Self.attribute(name, of: element) as? String
    }

    private nonisolated static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard
            let positionValue = Self.attribute("AXPosition", of: element),
            let sizeValue = Self.attribute("AXSize", of: element),
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
            let id = number(window[kCGWindowNumber as String]).uint32Value
            guard id != kCGNullWindowID, frame.width > 1, frame.height > 1 else { return nil }
            return WindowInfo(
                id: id,
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
