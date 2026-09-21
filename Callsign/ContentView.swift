import AppKit
import ServiceManagement
import SwiftUI

struct ContentView: View {
    @Bindable var controller: AppController
    let page: SettingsPage
    @State private var showsTroubleshooting = false

    enum SettingsPage: String {
        case general = "General", appearance = "Appearance", about = "About"
    }

    var body: some View {
        VStack(spacing: 0) {
            switch page {
            case .general: generalSettings
            case .appearance: appearanceSettings
            case .about: aboutSettings
            }
        }
        .frame(width: 600)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshLoginStatus()
        }
        .sheet(isPresented: $showsTroubleshooting) {
            TroubleshootingView(probe: controller.probe)
        }
    }

    private var appearanceSettings: some View {
        VStack(spacing: 0) {
            TagPreview(configuration: controller.configuration)
                .frame(height: 140)
                .padding([.horizontal, .top], 20)

            Form {
                Section {
                    Picker("Label", selection: $controller.configuration.label) {
                        ForEach(TagLabel.allCases) { label in
                            Text(label.title).tag(label)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("Liquid Glass", isOn: $controller.configuration.liquidGlass)
                        .help("Uses macOS appearance. Your custom colors are preserved while Glass is enabled.")
                    ColorPicker("Background color", selection: colorBinding(\.red, \.green, \.blue, \.alpha))
                        .disabled(controller.configuration.liquidGlass)
                    ColorPicker("Text color", selection: colorBinding(\.textRed, \.textGreen, \.textBlue, \.textAlpha))
                        .disabled(controller.configuration.liquidGlass)

                    LabeledContent("Size") {
                        HStack {
                            Slider(value: $controller.configuration.scale, in: 0.7...1.5)
                                .accessibilityLabel("Tag size")
                            Text(controller.configuration.scale, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                    }
                    Picker("Position", selection: $controller.configuration.position) {
                        ForEach(TagPosition.allCases) { position in
                            Text(position.title).tag(position)
                        }
                    }
                    LabeledContent("Placement") {
                        HStack {
                            Text("Outside").foregroundStyle(.secondary)
                            Slider(value: $controller.configuration.overlap, in: 0...1)
                                .accessibilityLabel("Placement inside the window")
                                .accessibilityValue(Text(controller.configuration.overlap, format: .percent))
                            Text("Inside").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Fine offsets") {
                        HStack(spacing: 20) {
                            Stepper("X: \(Int(controller.configuration.offsetX)) pt",
                                    value: $controller.configuration.offsetX, in: -80...80, step: 1)
                                .accessibilityLabel("Horizontal offset")
                            Stepper("Y: \(Int(controller.configuration.offsetY)) pt",
                                    value: $controller.configuration.offsetY, in: -80...80, step: 1)
                                .accessibilityLabel("Vertical offset")
                        }
                        .monospacedDigit()
                    }
                    Button("Restore Appearance Defaults") { controller.configuration = .default }
                        .disabled(controller.configuration == .default)
                }
            }
            .formStyle(.grouped)
        }
    }

    private var generalSettings: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { controller.launchAtLogin }, set: controller.setLaunchAtLogin))
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
            DiagnosticsControls(probe: controller.probe) { showsTroubleshooting = true }
        }
        .formStyle(.grouped)
    }

    private var aboutSettings: some View {
        VStack {
            HStack(spacing: 24) {
                // Reuse the menu-bar symbol until Callsign has a custom app icon.
                Image(systemName: "tag")
                    .font(.system(size: 64, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 120, height: 120)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 26))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Callsign").font(.system(size: 36, weight: .semibold))
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
                    Text("Version \(version) (\(build))").foregroundStyle(.secondary)
                    Text("Custom tags for Mission Control windows.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
            .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private func colorBinding(
        _ red: WritableKeyPath<TagConfiguration, Double>, _ green: WritableKeyPath<TagConfiguration, Double>,
        _ blue: WritableKeyPath<TagConfiguration, Double>, _ alpha: WritableKeyPath<TagConfiguration, Double>
    ) -> Binding<Color> {
        Binding(
            get: {
                let configuration = controller.configuration
                return Color(.sRGB, red: configuration[keyPath: red], green: configuration[keyPath: green],
                             blue: configuration[keyPath: blue], opacity: configuration[keyPath: alpha])
            },
            set: { value in
                guard let color = NSColor(value).usingColorSpace(.deviceRGB) else { return }
                var configuration = controller.configuration
                configuration[keyPath: red] = color.redComponent
                configuration[keyPath: green] = color.greenComponent
                configuration[keyPath: blue] = color.blueComponent
                configuration[keyPath: alpha] = color.alphaComponent
                controller.configuration = configuration
            })
    }
}

// A local sample only: reuse the real badge and placement math, never install desktop overlays here.
private struct TagPreview: View {
    let configuration: TagConfiguration
    @State private var badgeSize = CGSize(width: 100, height: 38)
    private let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/TextEdit.app")

    var body: some View {
        GeometryReader { geometry in
            let thumbnail = CGRect(x: 0, y: 0, width: 240, height: 100)
            let origin = configuration.badgeOrigin(thumbnail: thumbnail, badgeSize: badgeSize)
            let bounds = thumbnail.union(CGRect(origin: origin, size: badgeSize)).insetBy(dx: -24, dy: -24)
            let scale = min(1, geometry.size.width / bounds.width, geometry.size.height / bounds.height)

            ZStack(alignment: .topLeading) {
                sampleWindow
                    .frame(width: thumbnail.width, height: thumbnail.height)
                    .offset(x: -bounds.minX, y: -bounds.minY)
                BadgeView(
                    icon: icon,
                    text: configuration.label.text(appName: "TextEdit", windowTitle: "Project notes"),
                    configuration: configuration)
                    .onGeometryChange(for: CGSize.self, of: \.size) { badgeSize = $0 }
                    .offset(x: origin.x - bounds.minX, y: origin.y - bounds.minY)
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: bounds.width * scale, height: bounds.height * scale, alignment: .topLeading)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topLeading) {
            Text("Preview").font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tag preview")
        .accessibilityValue("\(configuration.label.title), \(configuration.position.title)")
    }

    private var sampleWindow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.75)).frame(width: 7, height: 7)
                }
                Spacer()
                Text("Project notes").font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(9)
            .background(.quaternary)
            VStack(alignment: .leading, spacing: 7) {
                ForEach([150.0, 190, 125], id: \.self) { width in
                    Capsule().fill(.tertiary).frame(width: width, height: 4)
                }
            }
            .padding(14)
            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.primary.opacity(0.12)))
    }
}

private struct AccessibilityNotice: View {
    @ObservedObject var probe: MissionControlProbe

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
    @ObservedObject var probe: MissionControlProbe
    let showReport: () -> Void

    var body: some View {
        Section {
            Toggle("Record diagnostics", isOn: $probe.recordDiagnostics)
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
    @ObservedObject var probe: MissionControlProbe
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Troubleshooting").font(.title2.bold())
            Text(probe.status)
            Text("Reports include app names and window titles. Review them before sharing.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                Text(probe.report.isEmpty
                     ? (probe.recordDiagnostics
                        ? "Open Mission Control to capture a diagnostic report."
                        : "Turn on Record diagnostics in General, then open Mission Control.")
                     : probe.report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Input Monitoring Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                }
                Button("Copy Report", action: probe.copyReport).disabled(probe.report.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 660, height: 420)
    }
}

#Preview {
    ContentView(controller: AppController(defaults: UserDefaults(suiteName: "com.shylee.Callsign.preview")!), page: .appearance)
}
