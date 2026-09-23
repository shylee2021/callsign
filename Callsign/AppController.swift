import AppKit
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppController {
    let probe = MissionControlProbe()
    private let defaults: UserDefaults
    private var pollingTask: Task<Void, Never>?
    private var started = false
    private(set) var settingsRequest = 0

    var configuration: TagConfiguration {
        didSet { configuration.save(to: defaults) }
    }
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: "app.enabled")
            updatePolling()
        }
    }
    var showInDock: Bool {
        didSet {
            defaults.set(showInDock, forKey: "app.showInDock")
            applyDockVisibility()
        }
    }
    private(set) var loginStatus = SMAppService.mainApp.status
    private(set) var loginError: String?

    static var isPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    var isPolling: Bool { pollingTask != nil }
    var hasOpenedSettings: Bool { defaults.bool(forKey: "app.hasOpenedSettings") }
    var launchAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["app.enabled": true])
        configuration = TagConfiguration.load(from: defaults)
        isEnabled = defaults.bool(forKey: "app.enabled")
        showInDock = defaults.bool(forKey: "app.showInDock")
    }

    func start() {
        guard !Self.isPreview, !started else { return }
        started = true
        updatePolling()
    }

    func stop() {
        started = false
        updatePolling()
    }

    private func updatePolling() {
        pollingTask?.cancel()
        pollingTask = nil
        guard started, isEnabled else {
            probe.stop()
            return
        }
        // App-owned, not view-owned: closing Settings must not stop tags or create another engine.
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = self.probe.poll(configuration: self.configuration)
                do { try await Task.sleep(for: .milliseconds(delay)) }
                catch { return }
            }
        }
    }

    func applyDockVisibility() {
        guard !Self.isPreview else { return }
        let wasActive = NSApp.isActive
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        if wasActive { NSApp.activate() }
    }

    func refreshLoginStatus() {
        loginStatus = SMAppService.mainApp.status
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !Self.isPreview else { return }
        loginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "Could not change launch at login: \(error.localizedDescription)"
        }
        // macOS is the source of truth, including approval pending and changes made in System Settings.
        refreshLoginStatus()
    }

    func showSettings() {
        // The app's SwiftUI scene handles requests from the menu, first launch, and Dock reopen.
        settingsRequest += 1
    }

    func settingsDidAppear() {
        defaults.set(true, forKey: "app.hasOpenedSettings")
        refreshLoginStatus()
    }
}
