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

    // A Space change restarts the count without a moved frame; the next two unchanged polls settle.
    mutating func invalidate() {
        unchangedPolls = 0
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
        // ponytail: two quiet polls (~66 ms; 33–133 ms after a Space change, since the next poll may
        // still be on the idle delay) can mistake a paused swipe for completion.
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

// Entry and later transitions behave the same: badges stay hidden until frames settle.
private enum MissionControlPhase {
    case closed, settling, active
}

enum ProbeStatus: Equatable {
    case accessibilityRequired
    case promptShown
    case paused
    case ready
    case closed
    case waitingForFrames
    case transitioning
    case active(labeled: Int, total: Int, source: String, settledMilliseconds: Int?)

    var text: String {
        switch self {
        case .accessibilityRequired: "Accessibility access is required."
        case .promptShown: "Enable Callsign in System Settings, then return here."
        case .paused: "Callsign is paused."
        case .ready: "Ready. Open Mission Control."
        case .closed: "Mission Control closed."
        case .waitingForFrames: "Mission Control: waiting for thumbnail frames…"
        case .transitioning: "Mission Control transitioning. Tags hidden…"
        case let .active(labeled, total, source, settledMilliseconds):
            "Mission Control active. Labeled \(labeled) of \(total) windows (\(source))."
                + (settledMilliseconds.map { " Settled after ~\($0) ms." } ?? "")
        }
    }
}

@Observable
final class MissionControlProbe {
    private(set) var isTrusted: Bool
    private(set) var status = ProbeStatus.accessibilityRequired
    let diagnostics = DiagnosticsRecorder()

    // Polling bookkeeping changes up to ~30 times a second; views observe only the state above.
    private let source: any ThumbnailSource
    private let titles: WindowTitleCache
    private let apps: AppIdentityCache
    private let overlays: any BadgeSink
    private let windowList: @MainActor () -> [WindowInfo]
    private let locateMissionControl: @MainActor () -> (AXUIElement, pid_t)?
    private let isProcessTrusted: @MainActor () -> Bool
    private let workspaceCenter = NSWorkspace.shared.notificationCenter
    @ObservationIgnored private var spaceObserver: NSObjectProtocol?
    @ObservationIgnored private var phase = MissionControlPhase.closed
    @ObservationIgnored private var stability = ThumbnailStability()
    @ObservationIgnored private var settleStartedAt = 0.0
    @ObservationIgnored private var settleSignpost: OSSignpostIntervalState?
    @ObservationIgnored private var settledMilliseconds: Int?
    @ObservationIgnored private var lastBadgeSync = 0.0

    // Defaults are the live system; tests substitute scripted Mission Control frames.
    init(
        source: any ThumbnailSource = defaultThumbnailSource(),
        titles: WindowTitleCache? = nil,
        apps: AppIdentityCache = AppIdentityCache(),
        overlays: any BadgeSink = OverlayManager(),
        windowList: @escaping @MainActor () -> [WindowInfo] = WindowList.onScreen,
        locateMissionControl: (@MainActor () -> (AXUIElement, pid_t)?)? = nil,
        isProcessTrusted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.source = source
        self.titles = titles ?? WindowTitleCache(windowList: windowList)
        self.apps = apps
        self.overlays = overlays
        self.windowList = windowList
        self.locateMissionControl = locateMissionControl ?? MissionControlLocator().currentMissionControl
        self.isProcessTrusted = isProcessTrusted
        isTrusted = isProcessTrusted()
        Accessibility.boundMessagingTimeout()
        self.titles.onTitlesArrived = { [weak self] in self?.lastBadgeSync = 0 }
        spaceObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase != .closed else { return }
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
        status = .promptShown
    }

    func stop() {
        titles.clear()
        resetMissionControl()
        status = .paused
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
        let trusted = isProcessTrusted()
        if trusted != isTrusted {
            Log.detection.notice("Accessibility trust changed: \(trusted, privacy: .public)")
        }
        isTrusted = trusted
        if !trusted || configuration.label != .windowTitle {
            titles.clear()
        }
        guard trusted else {
            resetMissionControl()
            status = .accessibilityRequired
            return 500
        }
        guard let (missionControl, dockPID) = locateMissionControl() else {
            let wasRunning = phase != .closed
            if wasRunning {
                resetMissionControl()
            }
            if source.usesWindowTitles, configuration.label == .windowTitle {
                // Warm titles before entry; the refresh throttles WindowServer and AX reads to 1 Hz.
                titles.refresh()
            }
            status = wasRunning ? .closed : .ready
            return Self.pollDelay(missionControlOpen: false, settled: false, awaitingTitles: false)
        }

        if phase == .closed {
            resetMissionControl()
            // Refresh renamed windows during entry without discarding already-known titles.
            titles.markStale()
            phase = .settling
            settleStartedAt = ProcessInfo.processInfo.systemUptime
            beginSettleInterval()
        }

        let windows = windowList()
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
            status = thumbnails.isEmpty ? .waitingForFrames : .transitioning
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
        status = .active(
            labeled: badges.count,
            total: thumbnails.count,
            source: source.name,
            settledMilliseconds: settledMilliseconds)

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
            phase = .settling
            settleStartedAt = ProcessInfo.processInfo.systemUptime
            beginSettleInterval()
            settledMilliseconds = nil
            diagnostics.cancel()
            status = .transitioning
        }
    }

    private func resetMissionControl() {
        phase = .closed
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
