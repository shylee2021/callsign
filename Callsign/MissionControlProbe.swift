//
//  MissionControlProbe.swift
//  Callsign
//

@preconcurrency import ApplicationServices
import AppKit
import Darwin
import Observation
import os

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

    mutating func invalidate() {
        unchangedPolls = nil
    }

    mutating func update(frames: [CGRect]) -> Bool {
        // WindowServer may reorder windows when one is hovered; geometry order must stay consistent.
        let frames = frames.sorted {
            ($0.minX, $0.minY, $0.width, $0.height) < ($1.minX, $1.minY, $1.width, $1.height)
        }
        let moved = frames.count != referenceFrames.count || zip(frames, referenceFrames).contains {
            abs($0.minX - $1.minX) > 1 || abs($0.minY - $1.minY) > 1
                || abs($0.width - $1.width) > 1 || abs($0.height - $1.height) > 1
        }
        if moved {
            // Keep this reference until movement exceeds the tolerance, so slow drift accumulates.
            referenceFrames = frames
            unchangedPolls = nil
        }
        guard !frames.isEmpty else {
            unchangedPolls = nil
            return false
        }
        guard let count = unchangedPolls else {
            unchangedPolls = 0
            return false
        }
        // ponytail: two quiet polls (~66 ms) can mistake a paused swipe for completion.
        // Prefer a system transition-completion notification if one becomes available.
        unchangedPolls = min(count + 1, 2)
        return unchangedPolls == 2
    }
}

struct AppBadge {
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    let windowTitle: String
    let icon: NSImage
    let thumbnailFrame: CGRect
}

private enum MissionControlPhase {
    case normal, entering, active, transitioning
}

@MainActor
@Observable
final class MissionControlProbe {
    private(set) var isTrusted = AXIsProcessTrusted()
    private(set) var status = "Accessibility access is required."
    let diagnostics = DiagnosticsRecorder()

    // Polling bookkeeping changes up to ~30 times a second; views observe only the state above.
    private let overlays = OverlayManager()
    private let apps = AppIdentityCache()
    private let titles = WindowTitleCache()
    private let source = defaultThumbnailSource()
    private let locator = MissionControlLocator()
    private let workspaceCenter = NSWorkspace.shared.notificationCenter
    @ObservationIgnored private var spaceObserver: NSObjectProtocol?
    @ObservationIgnored private var phase = MissionControlPhase.normal
    @ObservationIgnored private var stability = ThumbnailStability()
    @ObservationIgnored private var settleStartedAt = 0.0
    @ObservationIgnored private var settleSignpost: OSSignpostIntervalState?
    @ObservationIgnored private var settledMilliseconds: Int?
    @ObservationIgnored private var lastBadgeSync = 0.0

    init() {
        Accessibility.boundMessagingTimeout()
        titles.onTitlesArrived = { [weak self] in self?.lastBadgeSync = 0 }
        spaceObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase != .normal else { return }
                self.stability.invalidate()
                self.suspendBadges()
            }
        }
    }

    deinit {
        if let spaceObserver { workspaceCenter.removeObserver(spaceObserver) }
    }

    func requestAccess() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        status = "Enable Callsign in System Settings, then return here."
    }

    func stop() {
        titles.clear()
        resetMissionControl()
        status = "Callsign is paused."
    }

    // Milliseconds. Closed or settled, entry and swipes are still caught within one idle poll.
    static let idlePollDelay = 100
    static let activePollDelay = 33

    static func pollDelay(missionControlOpen: Bool, settled: Bool, awaitingTitles: Bool) -> Int {
        // Stay fast until settled, and while a title read is in flight so it appears promptly.
        guard missionControlOpen else { return idlePollDelay }
        return settled && !awaitingTitles ? idlePollDelay : activePollDelay
    }

    // Returns the delay in milliseconds before the app should poll again.
    func poll(configuration: TagConfiguration) -> Int {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            Log.detection.notice("Accessibility trust changed: \(trusted, privacy: .public)")
        }
        isTrusted = trusted
        if !trusted || configuration.label != .windowTitle {
            titles.clear()
        }
        guard trusted else {
            resetMissionControl()
            status = "Accessibility access is required."
            return 500
        }
        guard let (missionControl, dockPID) = locator.currentMissionControl() else {
            let wasRunning = phase != .normal
            if wasRunning {
                resetMissionControl()
            }
            if source.usesWindowTitles, configuration.label == .windowTitle {
                // Warm titles before entry; the refresh throttles WindowServer and AX reads to 1 Hz.
                titles.refresh()
            }
            status = wasRunning
                ? "Mission Control closed."
                : "Ready. Open Mission Control."
            return Self.pollDelay(missionControlOpen: false, settled: false, awaitingTitles: false)
        }

        if phase == .normal {
            resetMissionControl()
            // Refresh renamed windows during entry without discarding already-known titles.
            titles.markStale()
            phase = .entering
            settleStartedAt = ProcessInfo.processInfo.systemUptime
            beginSettleInterval()
            status = "Mission Control entering…"
        }

        let windows = WindowList.onScreen()
        if source.usesWindowTitles, configuration.label == .windowTitle {
            titles.refresh(for: windows)
        }
        let thumbnails = source.thumbnails(
            missionControl: missionControl, windows: windows, windowTitles: titles.windowTitles)

        let now = ProcessInfo.processInfo.systemUptime
        let settled = stability.update(frames: thumbnails.map(\.frame))
        if !settled {
            suspendBadges()
            settledMilliseconds = nil
            status = thumbnails.isEmpty
                ? "Mission Control: waiting for thumbnail frames…"
                : "Mission Control transitioning. Tags hidden…"
            return Self.pollDelay(missionControlOpen: true, settled: false, awaitingTitles: false)
        }
        let shouldFadeIn = phase != .active
        if shouldFadeIn {
            settledMilliseconds = Int((now - settleStartedAt) * 1_000)
            endSettleInterval(settled: true)
        }
        phase = .active
        let delay = Self.pollDelay(missionControlOpen: true, settled: true, awaitingTitles: titles.isFetching)

        // Refresh badge content and layout at most 10 Hz; idle polls already space out to that.
        guard shouldFadeIn || now - lastBadgeSync >= 0.1 else { return delay }
        lastBadgeSync = now

        let badges = thumbnails.compactMap { thumbnail -> AppBadge? in
            guard let window = thumbnail.matchingWindow(in: windows) else { return nil }
            if source.usesWindowTitles, configuration.label == .windowTitle,
               !titles.hasResult(for: window) {
                return nil
            }
            let identity = apps.identity(for: window)
            return AppBadge(
                windowID: window.id,
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
        status = "Mission Control active. Labeled \(badges.count) of \(thumbnails.count) windows (\(source.name))."
        if let elapsed = settledMilliseconds {
            status += " Settled after ~\(elapsed) ms."
        }

        diagnostics.scheduleReport { [weak self] in
            guard let self else { return "" }
            return DiagnosticsRecorder.makeReport(
                for: missionControl,
                dockPID: dockPID,
                windows: windows,
                settledMilliseconds: self.settledMilliseconds)
        }
        return delay
    }

    private func suspendBadges() {
        // Space notifications can arrive between geometry polls; hide immediately.
        overlays.hide()
        lastBadgeSync = 0
        if phase == .active {
            phase = .transitioning
            settleStartedAt = ProcessInfo.processInfo.systemUptime
            beginSettleInterval()
            settledMilliseconds = nil
            diagnostics.cancel()
            status = "Mission Control transitioning. Tags hidden…"
        }
    }

    private func resetMissionControl() {
        phase = .normal
        stability = ThumbnailStability()
        settleStartedAt = 0
        endSettleInterval(settled: false)
        settledMilliseconds = nil
        diagnostics.cancel()
        lastBadgeSync = 0
        // Title fetching outlives Mission Control transitions, so entry can reuse warm results.
        overlays.hide()
    }

    private func beginSettleInterval() {
        endSettleInterval(settled: false)
        settleSignpost = Log.signposter.beginInterval("Settle", id: Log.signposter.makeSignpostID())
    }

    private func endSettleInterval(settled: Bool) {
        guard let settleSignpost else { return }
        Log.signposter.endInterval("Settle", settleSignpost, "\(settled ? "settled" : "abandoned", privacy: .public)")
        self.settleSignpost = nil
    }
}
