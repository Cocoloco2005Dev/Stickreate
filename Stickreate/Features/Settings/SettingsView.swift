import SwiftUI

/// Real, persisted settings backed by `SettingsStore.shared`. Every control
/// changes app behaviour — no decorative toggles.
struct SettingsView: View {
    @Bindable private var settings = SettingsStore.shared

    @State private var cacheNote: String?

    var body: some View {
        Form {
            Section {
                Stepper(value: $settings.defaultFPS, in: 5...30) {
                    LabeledContent("Default frame rate", value: "\(settings.defaultFPS) fps")
                }

                Toggle("Confirm Intelligent Cut", isOn: $settings.confirmIntelligentCut)
                Toggle("Keep original sources", isOn: $settings.keepOriginalSources)
            } header: {
                Text("Stickers")
            } footer: {
                Text("The default frame rate is used when you trim a video. Keeping original sources lets you re-edit stickers later.")
            }

            Section {
                Picker("Export mode", selection: $settings.exportMode) {
                    ForEach(ExportMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            } header: {
                Text("Export")
            } footer: {
                Text("WhatsApp sends the pack straight to WhatsApp. File shares a .stickreatepack you can send or import later.")
            }

            Section {
                LabeledContent("Storage", value: settings.storageSummary)

                Button("Clear Cache") {
                    clearCache()
                }

                if let cacheNote {
                    Text(cacheNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Clearing removes temporary files created while editing. Your packs are not touched.")
            }

            Section {
                LabeledContent("On-device", value: "Yes")
                LabeledContent("Network requests", value: "None")
            } header: {
                Text("Privacy")
            } footer: {
                Text("Stickers are created entirely on your iPhone. Intelligent Cut uses Apple's Vision framework on-device.")
            }

            Section("About") {
                LabeledContent("App", value: "Stickreate")
                LabeledContent("Version", value: Bundle.main.shortVersion)
                LabeledContent("Build", value: Bundle.main.buildNumber)
            }
        }
        .navigationTitle("Settings")
    }

    private func clearCache() {
        let freed = settings.clearCache()
        cacheNote = freed > 0
            ? "Freed \(Self.formatted(freed))."
            : "Nothing to clear."
    }

    private static func formatted(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }

    var buildNumber: String {
        (infoDictionary?["CFBundleVersion"] as? String) ?? "—"
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
