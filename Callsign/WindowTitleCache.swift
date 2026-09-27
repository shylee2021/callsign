//
//  WindowTitleCache.swift
//  Callsign
//

@preconcurrency import ApplicationServices
import AppKit
import os

@MainActor
final class WindowTitleCache {
    private(set) var windowTitles: [pid_t: [CGWindowID: String]] = [:]
    // Called when a background read publishes titles, so badges refresh without waiting for the 10 Hz cap.
    var onTitlesArrived: (@MainActor () -> Void)?
    private let windowList: @MainActor () -> [WindowInfo]
    private var titleTask: Task<Void, Never>?
    private var lastTitleSync = -Double.infinity
    private var requestedTitleIDs: Set<CGWindowID> = []

    init(windowList: @escaping @MainActor () -> [WindowInfo] = WindowList.onScreen) {
        self.windowList = windowList
    }

    var isFetching: Bool { titleTask != nil }

    func hasResult(for window: WindowInfo) -> Bool {
        window.hasWindowTitleResult(in: windowTitles)
    }

    func clear() {
        titleTask?.cancel()
        titleTask = nil
        windowTitles = [:]
        requestedTitleIDs = []
        lastTitleSync = -Double.infinity
    }

    func markStale() {
        lastTitleSync = -Double.infinity
    }

    func refresh(for windows: [WindowInfo]? = nil) {
        guard titleTask == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Outside Mission Control, do not enumerate windows on every polling tick.
        if windows == nil, now - lastTitleSync < 1 { return }
        let candidates = (windows ?? windowList()).filter { $0.canReceiveBadge && $0.pid > 0 }
        // Retry pending reads sooner, but don't hammer a busy app on every geometry poll.
        let interval = candidates.contains { !$0.hasWindowTitleResult(in: windowTitles) } ? 0.15 : 1.0
        guard now - lastTitleSync >= interval
                || candidates.contains(where: { !requestedTitleIDs.contains($0.id) })
        else { return }
        lastTitleSync = now
        requestedTitleIDs = Set(candidates.map(\.id))
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
                    group.addTask {
                        let signpost = Log.signposter.beginInterval(
                            "TitleFetch", id: Log.signposter.makeSignpostID(), "pid \(pid, privacy: .public)")
                        defer { Log.signposter.endInterval("TitleFetch", signpost) }
                        return (pid, Self.readAccessibilityTitles(for: pid, windowIDs: ids))
                    }
                }
                for await (pid, titles) in group {
                    await MainActor.run { [weak self] in
                        guard !Task.isCancelled, let self else { return }
                        // Failed reads stay pending; they must not erase a previously resolved title.
                        self.windowTitles[pid, default: [:]].merge(titles) { _, new in new }
                        if !titles.isEmpty { self.onTitlesArrived?() }
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
        var titles: [CGWindowID: String] = [:]
        let untitled = Dictionary(uniqueKeysWithValues: windowIDs.map { ($0, "") })
        // This private bridge identifies AX windows even when Mission Control scales their frames.
        guard let windowID = PrivateAPI.axWindowID else { return untitled }
        guard !Task.isCancelled else { return titles }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard error == .success, let windows = value as? [AXUIElement] else {
            Log.titles.debug("AXWindows read failed for pid \(pid, privacy: .public): \(error.rawValue, privacy: .public)")
            // Unsupported AX is a real fallback; a timeout or interrupted read is not.
            if error == .attributeUnsupported || error == .notImplemented { return untitled }
            return titles
        }
        for window in windows {
            guard !Task.isCancelled else { break }
            AXUIElementSetMessagingTimeout(window, 0.05)
            var id: CGWindowID = 0
            guard windowID(window, &id) == .success, windowIDs.contains(id) else { continue }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
            if let title = resolvedAccessibilityTitle(value, error: error) { titles[id] = title }
            if titles.count == windowIDs.count { break }
        }
        return titles
    }

    nonisolated static func resolvedAccessibilityTitle(_ value: CFTypeRef?, error: AXError) -> String? {
        switch error {
        case .success: value as? String
        case .noValue, .attributeUnsupported, .notImplemented: ""
        default: nil
        }
    }
}
