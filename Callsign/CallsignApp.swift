import AppKit
import SwiftUI

@main
struct CallsignApp: App {
    @NSApplicationDelegateAdaptor(CallsignAppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Callsign", systemImage: "tag") {
            CallsignMenu(controller: delegate.controller)
        }
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w")
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…", action: delegate.controller.showSettings)
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .help) {}
        }
    }
}

@MainActor
final class CallsignAppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Neither previews nor the hosted test runner should start desktop monitoring or onboarding.
        guard !AppController.isPreview,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        controller.applyDockVisibility()
        controller.start()
        if !controller.hasOpenedSettings { controller.showSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.showSettings()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }
}

private struct CallsignMenu: View {
    @Bindable var controller: AppController

    var body: some View {
        Toggle("Enable Callsign", isOn: $controller.isEnabled)
        Button("Settings…", action: controller.showSettings)
            .keyboardShortcut(",")
        Divider()
        Button("Quit Callsign") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
