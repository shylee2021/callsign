import AppKit
import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        VStack {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
            .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            Spacer(minLength: 0)
        }
        .padding(20)
    }
}
