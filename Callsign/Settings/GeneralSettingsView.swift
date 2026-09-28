import AppKit
import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var controller: AppController
    @State private var showsTroubleshooting = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable Callsign", isOn: $controller.isEnabled)
                    .toggleStyle(.switch)
            }
            Section {
                // An explicit closure, not a method reference: Swift 6.2 (Xcode 26.6) crashes
                // generating the isolation thunk for the reference form.
                Toggle("Launch at login", isOn: Binding(
                    get: { controller.launchAtLogin }, set: { controller.setLaunchAtLogin($0) }))
                if controller.loginStatus == .requiresApproval {
                    LabeledContent("Approval needed in System Settings") {
                        Button("Review…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let error = controller.loginError {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                Toggle("Show in Dock", isOn: $controller.showInDock)
                    .help("Also makes Callsign available in Command-Tab. The menu-bar icon stays available.")
            }
            AccessibilityNotice(probe: controller.probe)
            DiagnosticsControls(diagnostics: controller.probe.diagnostics) { showsTroubleshooting = true }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshLoginStatus()
        }
        .sheet(isPresented: $showsTroubleshooting) {
            TroubleshootingView(probe: controller.probe)
        }
    }
}

private struct AccessibilityNotice: View {
    let probe: MissionControlProbe

    var body: some View {
        if !probe.isTrusted {
            Section("Accessibility") {
                Text("Allow Accessibility access so Callsign can identify Mission Control windows and read their titles.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Grant Accessibility Access", action: probe.requestAccess)
                    .accessibilityIdentifier("accessibilityPermission")
            }
            .disabled(AppController.isPreview)
        }
    }
}

private struct DiagnosticsControls: View {
    @Bindable var diagnostics: DiagnosticsRecorder
    let showReport: () -> Void

    var body: some View {
        Section {
            Toggle("Record diagnostics", isOn: $diagnostics.recordDiagnostics)
            Button("View diagnostic report…", action: showReport)
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Collects app names and window titles for troubleshooting. Off by default after restarting Callsign. Normal tags work without recording.")
        }
        .disabled(AppController.isPreview)
    }
}

private struct TroubleshootingView: View {
    let probe: MissionControlProbe
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Troubleshooting").font(.title2.bold())
            Text(probe.status.text)
            Text("Reports include app names and window titles. Review them before sharing.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                Text(probe.diagnostics.report.isEmpty
                     ? (probe.diagnostics.recordDiagnostics
                        ? "Open Mission Control to capture a diagnostic report."
                        : "Turn on Record diagnostics in General, then open Mission Control.")
                     : probe.diagnostics.report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Copy Report", action: probe.diagnostics.copyReport).disabled(probe.diagnostics.report.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 660, height: 420)
    }
}
