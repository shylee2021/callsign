import AppKit
import Observation
import SwiftUI
import Testing
@testable import Callsign

@MainActor
@Suite(.serialized)
struct AppControllerTests {
    @Test func menuBarIconsAreDistinctTransparentTemplates() throws {
        var masks: [[CGFloat]] = []
        for resource in [ImageResource.menuBarIcon, .menuBarIconPaused] {
            let image = NSImage(resource: resource)
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 20, height: 20))
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            let alpha = (0..<bitmap.pixelsHigh).flatMap { y in
                (0..<bitmap.pixelsWide).map { x in bitmap.colorAt(x: x, y: y)!.alphaComponent }
            }
            #expect(alpha.first == 0 && alpha.last == 0)
            #expect(alpha.contains(1))
            masks.append(alpha)
        }
        #expect(masks[0] != masks[1])
    }

    @Test func settingsPagesPreserveControlsAndFitContent() async throws {
        let suite = "CallsignTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let controller = AppController(defaults: defaults)
        func page(_ page: ContentView.SettingsPage) -> some View {
            ContentView(controller: controller, page: page).fixedSize(horizontal: false, vertical: true)
        }
        let host = NSHostingController(rootView: page(.general))
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 600, height: 700))
        window.isReleasedWhenClosed = false
        var preferredSize: CGSize { host.sizeThatFits(in: CGSize(width: 600, height: 10_000)) }
        defer {
            window.close()
            window.contentViewController = nil
            defaults.removePersistentDomain(forName: suite)
        }
        window.makeKeyAndOrderFront(nil)
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
            host.view.layoutSubtreeIfNeeded()
        }
        try await settle()
        func descendants(of view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants(of: $0) }
        }
        #expect(!controller.isPolling)
        // The master switch is the topmost switch; SwiftUI owns its accessibility label.
        let enableSwitch = try #require(descendants(of: host.view).compactMap { $0 as? NSSwitch }.max {
            $0.convert($0.bounds, to: nil).midY < $1.convert($1.bounds, to: nil).midY
        })
        for enabled in [false, true] {
            enableSwitch.state = enabled ? .on : .off
            #expect(enableSwitch.sendAction(enableSwitch.action, to: enableSwitch.target))
            #expect(controller.isEnabled == enabled)
            #expect(AppController(defaults: defaults).isEnabled == enabled)
            #expect(!controller.isPolling)
        }

        func selectPage(_ selection: ContentView.SettingsPage) async throws -> NSView {
            host.rootView = page(selection)
            try await settle()
            return host.view
        }
        let generalHeight = preferredSize.height
        let view = try await selectPage(.appearance)
        let appearanceHeight = preferredSize.height
        let picker = try #require(descendants(of: view).compactMap { $0 as? NSSegmentedControl }.first {
            $0.segmentCount == 3 && $0.label(forSegment: 0) == "App Name"
        })
        // Exercise the real segmented control action, not just the model's setter.
        for (index, label) in [(1, TagLabel.windowTitle), (2, .iconOnly), (0, .appName)] {
            let (changes, continuation) = AsyncStream<Void>.makeStream()
            withObservationTracking {
                _ = controller.configuration
            } onChange: {
                continuation.yield(())
            }
            picker.selectedSegment = index
            #expect(picker.sendAction(picker.action, to: picker.target))
            continuation.finish()
            var iterator = changes.makeAsyncIterator()
            #expect(await iterator.next() != nil)
            #expect(controller.configuration.label == label)
            #expect(TagConfiguration.load(from: defaults).label == label)
        }
        view.layoutSubtreeIfNeeded()
        let wells = descendants(of: view).compactMap { $0 as? NSColorWell }
        try #require(wells.count == 2)
        let first = wells[0].convert(wells[0].bounds, to: view)
        let second = wells[1].convert(wells[1].bounds, to: view)
        #expect(abs(first.maxX - second.maxX) < 1)
        #expect(abs(first.midY - second.midY) >= max(first.height, second.height))

        let about = try await selectPage(.about)
        let aboutHeight = preferredSize.height
        #expect(appearanceHeight > generalHeight && generalHeight > aboutHeight)
        #expect(abs(preferredSize.width - 600) < 1)
        #expect(descendants(of: about).compactMap { $0 as? NSColorWell }.isEmpty)
        let general = try await selectPage(.general)
        #expect(descendants(of: general).compactMap { $0 as? NSSegmentedControl }.isEmpty)
        #expect(descendants(of: general).compactMap { $0 as? NSColorWell }.isEmpty)
        #expect(abs(preferredSize.height - generalHeight) < 1)
        let appearance = try await selectPage(.appearance)
        #expect(descendants(of: appearance).compactMap { $0 as? NSSegmentedControl }.count == 1)
        #expect(controller.configuration.label == .appName)
        #expect(abs(preferredSize.height - appearanceHeight) < 1)
        #expect(!controller.isPolling)
    }

    @Test func nativeSettingsSceneAnimatesTabResizing() async throws {
        // Native window animations must be exercised in the real SwiftUI scene, not an NSHostingController.
        let previousOpened = UserDefaults.standard.object(forKey: "app.hasOpenedSettings")
        defer {
            if let previousOpened { UserDefaults.standard.set(previousOpened, forKey: "app.hasOpenedSettings") }
            else { UserDefaults.standard.removeObject(forKey: "app.hasOpenedSettings") }
        }
        let menu = try #require(NSApp.mainMenu?.items.first?.submenu)
        let command = try #require(menu.items.first { $0.keyEquivalent == "," })
        let action = try #require(command.action)
        #expect(NSApp.sendAction(action, to: command.target, from: command))
        try await Task.sleep(for: .milliseconds(500))
        let titles = ["General", "Appearance", "About"]
        let window = try #require(NSApp.windows.first { $0.toolbar?.items.map(\.label) == titles })
        defer { window.close() }
        let toolbar = try #require(window.toolbar)
        func select(_ title: String) throws {
            let item = try #require(toolbar.items.first { $0.label == title })
            let action = try #require(item.action)
            #expect(NSApp.sendAction(action, to: item.target, from: item))
        }
        var settledHeights: [String: CGFloat] = [:]
        for title in titles {
            let before = window.frame.height
            try select(title)
            var heights = [CGFloat]()
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(16))
                heights.append(window.frame.height)
            }
            #expect(window.title == title)
            #expect(abs(window.frame.width - 600) < 1)
            let after = window.frame.height
            settledHeights[title] = after
            if abs(after - before) > 1 {
                let animated = heights.contains { $0 > min(before, after) + 1 && $0 < max(before, after) - 1 }
                #expect(animated == !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
        }

        // Interrupt resizing; only the last request may win.
        for title in ["General", "Appearance", "About", "General"] {
            try select(title)
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(600))
        #expect(window.title == "General")
        let generalHeight = try #require(settledHeights["General"])
        #expect(abs(window.frame.height - generalHeight) <= 1)

        try select("Appearance")
        window.close()
        try await Task.sleep(for: .milliseconds(100))
        #expect(NSApp.sendAction(action, to: command.target, from: command))
        try await Task.sleep(for: .milliseconds(500))
        #expect(window.isVisible)
        try select("Appearance")
        try await Task.sleep(for: .milliseconds(600))
        #expect(window.title == "Appearance")
        let appearanceHeight = try #require(settledHeights["Appearance"])
        #expect(abs(window.frame.height - appearanceHeight) <= 1)
    }

    @Test func settingsRequestsDoNotControlTheEngineAndPauseStopsIt() throws {
        let suite = "CallsignTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let controller = AppController(defaults: defaults)
        defer {
            controller.stop()
            defaults.removePersistentDomain(forName: suite)
        }
        #expect(controller.isEnabled)
        #expect(!controller.showInDock)
        #expect(!controller.isPolling)
        #expect(!controller.hasOpenedSettings)
        #expect(controller.settingsRequest == 0)

        controller.showSettings()
        #expect(controller.settingsRequest == 1)
        #expect(!controller.hasOpenedSettings) // A request alone does not complete onboarding.
        #expect(!controller.isPolling)
        controller.settingsDidAppear()
        #expect(controller.hasOpenedSettings)
        #expect(AppController(defaults: defaults).hasOpenedSettings)
        #expect(!controller.isPolling)

        controller.start()
        controller.start() // Repeated startup must not create a second polling loop.
        #expect(controller.isPolling)
        let probe = controller.probe
        controller.showSettings()
        #expect(controller.settingsRequest == 2)
        #expect(controller.isPolling)
        #expect(controller.probe === probe)
        probe.diagnostics.recordDiagnostics = true
        #expect(controller.isPolling)
        probe.diagnostics.recordDiagnostics = false
        #expect(controller.isPolling)
        #expect(!AppController(defaults: defaults).probe.diagnostics.recordDiagnostics)

        controller.configuration.label = .windowTitle
        #expect(TagConfiguration.load(from: defaults).label == .windowTitle)
        controller.isEnabled = false
        #expect(!controller.isPolling)
        #expect(controller.probe.status == "Callsign is paused.")
        #expect(!AppController(defaults: defaults).isEnabled)

        controller.isEnabled = true
        #expect(controller.isPolling)
        controller.stop()
        #expect(!controller.isPolling)
        controller.isEnabled = false
        controller.isEnabled = true
        #expect(!controller.isPolling) // Settings alone must not restart a stopped app lifecycle.
        #expect(!CallsignAppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApp))
    }
}
