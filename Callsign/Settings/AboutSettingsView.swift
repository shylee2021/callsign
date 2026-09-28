import AppKit
import SwiftUI

struct AboutSettingsView: View {
    @Bindable var controller: AppController

    var body: some View {
        // Same grouped form as the other panes, so the card is system-drawn on every macOS version.
        Form {
            Section {
                HStack(spacing: 24) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 120, height: 120)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Callsign").font(.system(size: 36, weight: .semibold))
                        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
                        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
                        Text("Version \(version) (\(build))").foregroundStyle(.secondary)
                        Text("Custom tags for Mission Control windows.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                }
                .padding(.vertical, 8)
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $controller.automaticallyChecksForUpdates)
                Picker("Update channel", selection: $controller.updateChannel) {
                    ForEach(UpdateChannel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Beta builds may be less stable. The beta channel also receives stable releases.")
                LabeledContent("") {
                    Button("Check for Updates…", action: controller.checkForUpdates)
                        .disabled(!controller.canCheckForUpdates)
                }
            }
            .disabled(AppController.isPreview)
        }
        .formStyle(.grouped)
    }
}
