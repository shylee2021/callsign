import AppKit
import Observation
import ServiceManagement
import Sparkle

// NSObject subclass because Sparkle's delegate protocol is Objective-C.
@Observable
final class AppController: NSObject, SPUUpdaterDelegate {
    let probe = MissionControlProbe()
    private let defaults: UserDefaults
    private var pollingTask: Task<Void, Never>?
    private var started = false
    private(set) var settingsRequest = 0
    // Mirrors Sparkle's canCheckForUpdates so the menu item can observe it.
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var updaterController: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    var configuration: TagConfiguration {
        didSet { configuration.save(to: defaults, changedFrom: oldValue) }
    }
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: PreferenceKey.enabled)
            updatePolling()
        }
    }
    var showInDock: Bool {
        didSet {
            defaults.set(showInDock, forKey: PreferenceKey.showInDock)
            applyDockVisibility()
        }
    }
    var updateChannel: UpdateChannel {
        didSet { defaults.set(updateChannel.rawValue, forKey: PreferenceKey.updateChannel) }
    }
    // Sparkle persists these itself (SUEnableAutomaticChecks, SUAutomaticallyUpdate).
    var automaticallyChecksForUpdates: Bool {
        didSet { updaterController?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }
    var automaticallyDownloadsUpdates: Bool {
        didSet { updaterController?.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }
    private(set) var loginStatus = SMAppService.mainApp.status
    private(set) var loginError: String?

    static var isPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    var isPolling: Bool { pollingTask != nil }
    var hasOpenedSettings: Bool { defaults.bool(forKey: PreferenceKey.hasOpenedSettings) }
    var launchAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [PreferenceKey.enabled: true])
        configuration = TagConfiguration.load(from: defaults)
        isEnabled = defaults.bool(forKey: PreferenceKey.enabled)
        showInDock = defaults.bool(forKey: PreferenceKey.showInDock)
        updateChannel = UpdateChannel(rawValue: defaults.string(forKey: PreferenceKey.updateChannel) ?? "") ?? .stable
        automaticallyChecksForUpdates = defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
        automaticallyDownloadsUpdates = defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool ?? false
        super.init()
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

    // MARK: Updates

    // Called by the app delegate only; previews and the test runner never create an updater.
    func startUpdater() {
        guard !Self.isPreview, updaterController == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        updaterController = controller
        // Sparkle's stored values win over the Info.plist defaults once it is running.
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    // Sparkle calls its delegate on the main thread.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { updateChannel.allowedSparkleChannels }
    }

    // MARK: Dock, login item, settings

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
        defaults.set(true, forKey: PreferenceKey.hasOpenedSettings)
        refreshLoginStatus()
    }
}
