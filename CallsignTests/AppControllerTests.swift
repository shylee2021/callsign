import AppKit
import Observation
import SwiftUI
import Testing
@testable import Callsign

@MainActor
struct AppControllerTests {
    @Test func nativeToolbarTabsPreserveLabelSelectionAndColorAlignment() async throws {
        let suite = "CallsignTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let controller = AppController(defaults: defaults)
        defer {
            controller.settingsWindow?.close()
            controller.settingsWindow?.unbind(.title)
            controller.settingsWindow?.contentViewController = nil
            defaults.removePersistentDomain(forName: suite)
        }
        controller.showSettings()
        let window = try #require(controller.settingsWindow)
        #expect(window.toolbarStyle == .preference)
        let tabs = try #require(window.contentViewController as? NSTabViewController)
        let toolbar = try #require(window.toolbar)
        let titles = ["General", "Appearance", "About"]
        #expect(tabs.tabStyle == .toolbar)
        #expect(tabs.tabViewItems.map(\.label) == titles)
        #expect(tabs.tabViewItems.compactMap { $0.identifier as? String } == titles)
        #expect(toolbar.items.map(\.label) == titles)
        #expect(toolbar.displayMode == .iconAndLabel)
        #expect(toolbar.items.allSatisfy { $0.image != nil })
        #expect(tabs.selectedTabViewItemIndex == 0)
        #expect(window.title == "General")
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        func descendants(of view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants(of: $0) }
        }
        #expect(descendants(of: content).compactMap { $0 as? NSSplitView }.isEmpty)
        func selectTab(_ index: Int) throws -> NSView {
            let item = toolbar.items[index]
            let action = try #require(item.action)
            #expect(NSApp.sendAction(action, to: item.target, from: item))
            content.layoutSubtreeIfNeeded()
            #expect(tabs.selectedTabViewItemIndex == index)
            #expect(toolbar.selectedItemIdentifier == item.itemIdentifier)
            #expect(window.title == titles[index])
            #expect(toolbar.items.allSatisfy { $0.isVisible })
            let pane = try #require(tabs.tabViewItems[index].viewController?.view)
            pane.layoutSubtreeIfNeeded()
            return pane
        }
        let view = try selectTab(1)
        let picker = try #require(descendants(of: view).compactMap { $0 as? NSSegmentedControl }.first {
            $0.segmentCount == 3 && $0.label(forSegment: 0) == "App Name"
        })
        // Exercise the actual AppKit action that used to synchronously publish during SwiftUI updates.
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

        for index in [0, 2] { // General and About leave the appearance controls on their own page.
            let pane = try selectTab(index)
            #expect(descendants(of: pane).compactMap { $0 as? NSSegmentedControl }.isEmpty)
            #expect(descendants(of: pane).compactMap { $0 as? NSColorWell }.isEmpty)
        }
        let appearance = try selectTab(1)
        #expect(descendants(of: appearance).compactMap { $0 as? NSSegmentedControl }.count == 1)
        #expect(controller.configuration.label == .appName)
        window.close()
        controller.showSettings()
        #expect(controller.settingsWindow === window)
        #expect(window.toolbar === toolbar)
        #expect(window.title == "Appearance")
        #expect(tabs.selectedTabViewItemIndex == 1)
        #expect(!controller.isPolling)
    }

    @Test func settingsHeightsFitContentAndHandleInterruptedAndDynamicResizes() async throws {
        let suite = "CallsignTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let controller = AppController(defaults: defaults)
        defer {
            controller.settingsWindow?.close()
            controller.settingsWindow?.unbind(.title)
            controller.settingsWindow?.contentViewController = nil
            defaults.removePersistentDomain(forName: suite)
        }
        controller.showSettings()
        let window = try #require(controller.settingsWindow)
        let tabs = try #require(window.contentViewController as? SettingsTabViewController)
        let screen = try #require(window.screen)
        #expect(!window.styleMask.contains(.resizable))
        window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: screen.visibleFrame.maxY - 20))
        let top = window.frame.maxY
        func settle() async throws -> CGFloat {
            var previous = NSRect.null
            var expectedHeight: CGFloat = 0
            for _ in 0..<125 {
                try await Task.sleep(for: .milliseconds(16))
                window.layoutIfNeeded()
                let size = tabs.tabView.selectedTabViewItem!.viewController!.preferredContentSize
                expectedHeight = min(ceil(window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).height),
                                     screen.visibleFrame.height - 40)
                if !tabs.view.isHidden && window.frame == previous && abs(window.frame.height - expectedHeight) < 1 { break }
                previous = window.frame
            }
            #expect(!tabs.view.isHidden)
            #expect(abs(window.frame.height - expectedHeight) < 1)
            #expect(abs(window.frame.maxY - top) < 1)
            #expect(abs(window.frame.width - 600) < 1)
            #expect(window.frame.height <= screen.visibleFrame.height - 40)
            #expect(window.toolbar?.items.allSatisfy { $0.isVisible } == true)
            return window.frame.height
        }
        var heights = [CGFloat]()
        for index in 0..<3 {
            tabs.selectedTabViewItemIndex = index
            heights.append(try await settle())
            let pane = try #require(tabs.tabViewItems[index].viewController)
            let expected = window.frameRect(forContentRect: NSRect(origin: .zero, size: pane.preferredContentSize))
            #expect(abs(window.frame.height - min(ceil(expected.height), screen.visibleFrame.height - 40)) < 1)
        }
        #expect(heights[1] > heights[0] && heights[0] > heights[2])
        for index in [0, 1, 2, 0, 1, 0] { tabs.selectedTabViewItemIndex = index }
        #expect(abs((try await settle()) - heights[0]) < 1)
        tabs.selectedTabViewItemIndex = 1
        window.close() // Reopening during an animation must cancel it and reveal the retained pane.
        controller.showSettings()
        #expect(controller.settingsWindow === window)
        #expect(tabs.selectedTabViewItemIndex == 1)
        let reopenedHeight = try await settle()
        #expect(abs(reopenedHeight - heights[1]) < 1, "Reopened height \(reopenedHeight), original heights \(heights), preferred \(tabs.tabViewItems[1].viewController!.preferredContentSize)")

        func form(rows: Int) -> some View {
            Form { Section { ForEach(0..<rows, id: \.self) { Text("Setting \($0)") } } }
                .formStyle(.grouped).frame(width: 600)
        }
        let pane = NSHostingController(rootView: form(rows: 2))
        pane.sizingOptions = .preferredContentSize
        let item = NSTabViewItem(identifier: "Sizing")
        item.label = "Sizing"
        item.image = NSImage(systemSymbolName: "arrow.up.and.down", accessibilityDescription: "Sizing")
        item.viewController = pane
        tabs.addTabViewItem(item)
        tabs.selectedTabViewItemIndex = 3
        let shortHeight = try await settle()
        pane.rootView = form(rows: 8) // Content changes within a tab, such as a permission notice disappearing.
        let tallerHeight = try await settle()
        #expect(tallerHeight > shortHeight)
        pane.rootView = form(rows: 200)
        let cappedHeight = try await settle()
        #expect(abs(cappedHeight - (screen.visibleFrame.height - 40)) < 1)
        #expect(pane.preferredContentSize.height > window.contentLayoutRect.height)
        pane.rootView = form(rows: 2)
        #expect(abs((try await settle()) - shortHeight) < 1)
        tabs.selectedTabViewItemIndex = 0
        tabs.resizeToSelectedPane(animated: false)
        #expect(!tabs.view.isHidden) // The same immediate path is used when Reduce Motion is enabled.
        #expect(abs((try await settle()) - heights[0]) < 1)
        #expect(!controller.isPolling)
    }

    @Test func settingsLifetimeDoesNotControlTheEngineAndPauseStopsIt() throws {
        let suite = "CallsignTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let controller = AppController(defaults: defaults)
        defer {
            controller.stop()
            controller.settingsWindow?.close()
            controller.settingsWindow?.unbind(.title)
            controller.settingsWindow?.contentViewController = nil
            defaults.removePersistentDomain(forName: suite)
        }
        #expect(controller.isEnabled)
        #expect(!controller.showInDock)
        #expect(!controller.isPolling)
        #expect(!controller.hasOpenedSettings)

        controller.start()
        controller.start() // Repeated startup must not create a second polling loop.
        #expect(controller.isPolling)
        let probe = controller.probe
        controller.showSettings()
        let window = try #require(controller.settingsWindow)
        #expect(controller.hasOpenedSettings)
        window.close()
        #expect(controller.isPolling)
        controller.showSettings()
        #expect(controller.settingsWindow === window)
        #expect(controller.probe === probe)
        probe.recordDiagnostics = true
        #expect(controller.isPolling)
        probe.recordDiagnostics = false
        #expect(controller.isPolling) // Recording does not own or pause the tag engine.
        #expect(!AppController(defaults: defaults).probe.recordDiagnostics)

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
