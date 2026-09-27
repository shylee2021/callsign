//
//  AppIdentityCache.swift
//  Callsign
//

import AppKit

struct AppIdentity {
    let name: String
    let icon: NSImage
}

@MainActor
final class AppIdentityCache {
    private(set) var identities: [pid_t: AppIdentity] = [:]
    private let workspaceCenter = NSWorkspace.shared.notificationCenter
    private var terminateObserver: NSObjectProtocol?

    init() {
        terminateObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            // PIDs are recycled, so a quit app's identity must not outlive it.
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                self?.evict(pid: pid)
            }
        }
    }

    // Observer tokens are not Sendable, so remove this one on the main actor.
    isolated deinit {
        if let terminateObserver { workspaceCenter.removeObserver(terminateObserver) }
    }

    func identity(for window: WindowInfo) -> AppIdentity {
        if let cached = identities[window.pid] { return cached }
        let app = NSRunningApplication(processIdentifier: window.pid)
        let identity = AppIdentity(
            name: app?.localizedName ?? window.owner,
            icon: app?.icon ?? NSImage(
                systemSymbolName: "app.fill",
                accessibilityDescription: window.owner) ?? NSImage(size: NSSize(width: 32, height: 32)))
        identities[window.pid] = identity
        return identity
    }

    func evict(pid: pid_t) {
        identities[pid] = nil
    }
}
