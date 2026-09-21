import AppKit
import Observation
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class AppController {
    let probe = MissionControlProbe()
    private let defaults: UserDefaults
    private var pollingTask: Task<Void, Never>?
    private var started = false
    private(set) var settingsWindow: NSWindow?

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
        if settingsWindow == nil {
            let window = NSWindow()
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.toolbarStyle = .preference
            let tabs = SettingsTabViewController()
            tabs.tabStyle = .toolbar
            tabs.transitionOptions = [] // The window resizes with the pane hidden, rather than crossfading layouts.
            for (page, symbol) in [(ContentView.SettingsPage.general, "gearshape"),
                                   (.appearance, "paintpalette"), (.about, "info.circle")] {
                let pane = NSHostingController(rootView: ContentView(controller: self, page: page))
                pane.title = page.rawValue
                pane.sizingOptions = .preferredContentSize
                // Avoid the convenience initializer's implicit image-resource lookup.
                let tab = NSTabViewItem(identifier: page.rawValue)
                tab.label = page.rawValue
                tab.image = NSImage(systemSymbolName: symbol, accessibilityDescription: page.rawValue)
                tab.viewController = pane
                tabs.addTabViewItem(tab)
            }
            window.contentViewController = tabs
            window.bind(.title, to: tabs, withKeyPath: #keyPath(NSTabViewController.title))
            window.isReleasedWhenClosed = false
            window.layoutIfNeeded()
            tabs.resizeToSelectedPane(animated: false)
            window.center()
            settingsWindow = window
        }
        defaults.set(true, forKey: "app.hasOpenedSettings")
        refreshLoginStatus()
        (settingsWindow?.contentViewController as? SettingsTabViewController)?.resizeToSelectedPane(animated: false)
        NSApp.activate()
        settingsWindow?.deminiaturize(nil)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class SettingsTabViewController: NSTabViewController {
    private lazy var heightLimit = view.heightAnchor.constraint(lessThanOrEqualToConstant: 0)
    private var resizeGeneration = 0

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        resizeToSelectedPane()
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        if tabView.selectedTabViewItem?.viewController === viewController {
            resizeToSelectedPane()
        }
    }

    func resizeToSelectedPane(animated: Bool = true) {
        guard isViewLoaded, let window = view.window,
              let size = tabView.selectedTabViewItem?.viewController?.preferredContentSize,
              size.width > 0, size.height > 0 else { return }
        let screen = window.screen ?? NSScreen.main
        let chromeHeight = window.frameRect(forContentRect: .zero).height
        // A constraint keeps Auto Layout from undoing the screen-height cap; forms can scroll instead.
        heightLimit.constant = max(0, (screen?.visibleFrame.height ?? 720) - chromeHeight - 40)
        heightLimit.isActive = true
        var frame = window.frameRect(forContentRect: NSRect(
            origin: .zero, size: NSSize(width: size.width, height: min(size.height, heightLimit.constant))))
        frame.size.height = ceil(frame.height)
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let screen {
            // Keep the top edge steady unless growing would put controls below the screen.
            frame.origin.y = max(frame.origin.y, screen.visibleFrame.minY + 20)
        }
        guard frame != window.frame || view.isHidden else { return }
        resizeGeneration += 1
        let generation = resizeGeneration
        guard animated, window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.setFrame(frame, display: true)
            view.isHidden = false
            return
        }
        view.isHidden = true
        NSAnimationContext.runAnimationGroup { context in
            context.allowsImplicitAnimation = true
            context.duration = window.animationResizeTime(frame)
            window.setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                // A superseded animation must not reveal a pane while its replacement is still resizing.
                guard let self, self.resizeGeneration == generation else { return }
                self.view.isHidden = false
            }
        }
    }
}
