import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("On-device", value: "Yes")
                LabeledContent("Network requests", value: "None")
            } header: {
                Text("Privacy")
            } footer: {
                Text("Stickers are created entirely on your iPhone. Background removal uses Apple's Vision framework.")
            }

            Section("About") {
                LabeledContent("App", value: "Stickreate")
                LabeledContent("Version", value: Bundle.main.shortVersion)
            }
        }
        .navigationTitle("Settings")
    }
}

private extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
