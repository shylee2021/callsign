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
        windowTitles: [pid_t: [CGWindowID: String]]
    ) -> [Thumbnail] {
        // ponytail: assumes WindowServer bounds track thumbnails; revisit if their layouts diverge.
        return windows.filter(\.canReceiveBadge)
            .map { Thumbnail(
                windowID: $0.id,
                title: windowTitles[$0.pid]?[$0.id] ?? "",
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

    func hasWindowTitleResult(in titles: [pid_t: [CGWindowID: String]]) -> Bool {
        // Missing means pending; an empty string means the lookup finished without a title.
        titles[pid]?[id] != nil
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
// macOS 26 uses Dock AX thumbnails; macOS 27+ uses WindowServer frames.
// On macOS 27, remote titles come from AX; our own titles come directly from AppKit.
@MainActor
final class MissionControlProbe: ObservableObject {
    @Published private(set) var isTrusted = AXIsProcessTrusted()
    @Published private(set) var status = "Accessibility access is required."
    @Published private(set) var report = ""
    // Session-only: never save diagnostic recording in preferences.
    @Published var recordDiagnostics = false {
        didSet {
            if !recordDiagnostics { cancelReport() }
        }
    }

    private let overlays = OverlayManager()
    private let inputMonitor = MissionControlInputMonitor()
    private var phase = MissionControlPhase.normal
    private var stability = ThumbnailStability()
    private var settleStartedAt = 0.0
    private var settledMilliseconds: Int?
    private var reportTask: Task<Void, Never>?
    private var lastBadgeSync = 0.0
    private var appCache: [pid_t: AppIdentity] = [:]
    private var windowTitles: [pid_t: [CGWindowID: String]] = [:]
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

    func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    func stop() {
        inputMonitor.stop()
        clearWindowTitles()
        resetMissionControl()
        status = "Callsign is paused."
    }

    private func clearWindowTitles() {
        titleTask?.cancel()
        titleTask = nil
        windowTitles = [:]
        lastTitleSync = -Double.infinity
    }

    // Returns the delay in milliseconds before the app should poll again.
    func poll(configuration: TagConfiguration) -> Int {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
        }
        if !trusted || configuration.label != .windowTitle {
            clearWindowTitles()
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
            if #available(macOS 27, *), configuration.label == .windowTitle {
                // Warm titles before entry; the refresh throttles WindowServer and AX reads to 1 Hz.
                refreshWindowTitles()
            }
            status = wasRunning
                ? "Mission Control closed."
                : "Ready. Open Mission Control."
            return 33
        }

        if phase == .normal {
            resetMissionControl()
            // Refresh renamed windows during entry without discarding already-known titles.
            lastTitleSync = -Double.infinity
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
                refreshWindowTitles(for: windows)
            }
            thumbnails = Thumbnail.fromWindowServer(windows, windowTitles: windowTitles)
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
                ? "Mission Control: waiting for thumbnail frames…"
                : "Mission Control transitioning. Tags hidden…"
            return 33
        }
        let shouldFadeIn = phase != .active
        if shouldFadeIn {
            settledMilliseconds = Int((now - settleStartedAt) * 1_000)
        }
        phase = .active

        // Poll geometry every 33 ms, but refresh badge content and layout at most 10 Hz.
        guard shouldFadeIn || now - lastBadgeSync >= 0.1 else { return 33 }
        lastBadgeSync = now

        let badges = thumbnails.compactMap { thumbnail -> AppBadge? in
            guard let window = thumbnail.matchingWindow(in: windows) else { return nil }
            if #available(macOS 27, *), configuration.label == .windowTitle,
               !window.hasWindowTitleResult(in: windowTitles) {
                return nil
            }
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
        status = "Mission Control active. Labeled \(badges.count) of \(thumbnails.count) windows (\(source))."
        if let elapsed = settledMilliseconds {
            status += " Settled after ~\(elapsed) ms."
        }
        if !inputMonitor.isRunning {
            status += " Input monitor unavailable; using window motion only."
        }

        scheduleReport { [weak self] in
            self?.makeReport(for: missionControl, dockPID: dockPID, windows: windows) ?? ""
        }
        return 33
    }

    private func suspendBadges() {
        // Hiding must be immediate, including when an input arrives between geometry polls.
        overlays.hide()
        lastBadgeSync = 0
        if phase == .active {
            phase = .transitioning
            settleStartedAt = ProcessInfo.processInfo.systemUptime
            settledMilliseconds = nil
            cancelReport()
            status = "Mission Control transitioning. Tags hidden…"
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
        cancelReport()
        lastBadgeSync = 0
        // Title fetching outlives Mission Control transitions, so entry can reuse warm results.
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

    private func refreshWindowTitles(for windows: [WindowInfo]? = nil) {
        guard titleTask == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Outside Mission Control, do not enumerate windows on every polling tick.
        if windows == nil, now - lastTitleSync < 1 { return }
        let candidates = (windows ?? onScreenWindows()).filter { $0.canReceiveBadge && $0.pid > 0 }
        // Newly discovered windows need their first result without waiting for the refresh interval.
        guard now - lastTitleSync >= 1
                || candidates.contains(where: { !$0.hasWindowTitleResult(in: windowTitles) })
        else { return }
        lastTitleSync = now
        var targets = Dictionary(grouping: candidates, by: \.pid).mapValues { Set($0.map(\.id)) }
        windowTitles = targets.reduce(into: [:]) { cache, target in
            cache[target.key] = windowTitles[target.key]?.filter { target.value.contains($0.key) }
        }
        if let localTitles = Self.readLocalWindowTitles(removingFrom: &targets) {
            windowTitles[ProcessInfo.processInfo.processIdentifier] = localTitles
        }
        guard !targets.isEmpty else { return }

        // Read off-main and publish each app independently, so a slow app cannot hold up the others.
        titleTask = Task.detached(priority: .utility) { [weak self] in
            await withTaskGroup(of: (pid_t, [CGWindowID: String]).self) { group in
                for (pid, ids) in targets {
                    group.addTask { (pid, Self.readAccessibilityTitles(for: pid, windowIDs: ids)) }
                }
                for await (pid, titles) in group {
                    await MainActor.run { [weak self] in
                        guard !Task.isCancelled, let self else { return }
                        self.windowTitles[pid] = titles
                    }
                }
            }
            await MainActor.run { [weak self] in
                guard !Task.isCancelled, let self else { return }
                self.titleTask = nil
            }
        }
    }

    static func readLocalWindowTitles(
        removingFrom targets: inout [pid_t: Set<CGWindowID>]
    ) -> [CGWindowID: String]? {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let ids = targets.removeValue(forKey: pid) else { return nil }
        // Keep our AppKit access on the main actor and our PID out of background AX requests.
        var titles = Dictionary(uniqueKeysWithValues: ids.map { ($0, "") })
        for window in NSApplication.shared.windows {
            guard let id = CGWindowID(exactly: window.windowNumber), ids.contains(id) else { continue }
            titles[id] = window.title
        }
        return titles
    }

    private nonisolated static func readAccessibilityTitles(
        for pid: pid_t, windowIDs: Set<CGWindowID>
    ) -> [CGWindowID: String] {
        // Record completed lookups even for untitled/inaccessible windows, allowing the app-name fallback.
        var titles = Dictionary(uniqueKeysWithValues: windowIDs.map { ($0, "") })
        // This private bridge identifies AX windows even when Mission Control scales their frames.
        typealias WindowIDFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        guard let handle = dlopen(nil, RTLD_LAZY) else { return titles }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return titles }
        let windowID = unsafeBitCast(symbol, to: WindowIDFunction.self)
        guard !Task.isCancelled else { return titles }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        let windows = attribute("AXWindows", of: app) as? [AXUIElement] ?? []
        for window in windows {
            guard !Task.isCancelled else { break }
            AXUIElementSetMessagingTimeout(window, 0.05)
            var id: CGWindowID = 0
            guard windowID(window, &id) == .success, windowIDs.contains(id),
                  let title = attribute("AXTitle", of: window) as? String, !title.isEmpty else { continue }
            titles[id] = title
        }
        return titles
    }

    private func cancelReport() {
        reportTask?.cancel()
        reportTask = nil
        // Keep the last report in memory so recording can be stopped before reviewing/copying it.
    }

    @discardableResult
    func scheduleReport(_ capture: @escaping @MainActor () -> String) -> Task<Void, Never>? {
        guard recordDiagnostics else { return nil }
        // Poll schedules only after settling; transitions and pause cancel pending captures.
        // Keep the completed task until the next transition: one capture per settled layout.
        if let reportTask { return reportTask }
        let task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch { return }
            guard let self, self.recordDiagnostics, !Task.isCancelled else { return }
            let payload = capture()
            guard self.recordDiagnostics, !Task.isCancelled else { return }
            self.report = "Captured \(Date().formatted(date: .omitted, time: .standard))\n\n\(payload)"
        }
        reportTask = task
        return task
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
        return "SETTLE TIMING\n\(timing) (2 unchanged polls, ~66 ms; 33 ms poll delay + API overhead)\n\(monitoring)\n\nMISSION CONTROL AX TREE\n\(tree)\n\nON-SCREEN WINDOWS\n\(windowReport(dockPID: dockPID, windows: windows))"
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
