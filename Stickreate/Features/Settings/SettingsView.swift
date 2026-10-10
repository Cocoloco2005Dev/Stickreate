import SwiftUI
import UIKit

/// Real, persisted settings backed by `SettingsStore.shared`.
///
/// The "Keep original sources" preference is persisted here and consumed by the
/// sticker commit path (see `SettingsStore.shouldPersistOriginalSources`).
struct SettingsView: View {
    @Bindable private var settings = SettingsStore.shared

    @State private var cacheNote: String?
    @State private var logCount = DebugLog.shared.count
    @State private var logNote: String?

    var body: some View {
        Form {
            Section {
                Toggle("Keep original sources", isOn: $settings.keepOriginalSources)
            } header: {
                Text("Editing")
            } footer: {
                Text("Keeps the original photo or video on this iPhone so you can re-open and re-edit a sticker later.")
            }

            Section {
                Toggle("Expand cut-out to fill the sticker", isOn: $settings.expandCutoutToFill)
            } header: {
                Text("Cut-outs")
            } footer: {
                Text("Off keeps the subject at its original size.")
            }

            Section {
                LabeledContent("Storage used", value: settings.storageSummary)

                Button("Clear Cache") {
                    clearCache()
                }

                if let cacheNote {
                    Label(cacheNote, systemImage: cacheIcon)
                        .font(DS.TextRole.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(cacheNote)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Clearing removes temporary files created while editing. Your packs and originals are not touched.")
            }

            Section {
                LabeledContent("On-device", value: "Yes")
                LabeledContent("Network requests", value: "None")
            } header: {
                Text("Privacy")
            } footer: {
                Text("Stickers are created entirely on your iPhone. Intelligent Cut uses Apple's Vision framework on-device.")
            }

            Section {
                LabeledContent("Log entries", value: "\(logCount)")

                Button("Copy debug log") {
                    copyLog()
                }

                ShareLink(item: DebugLog.shared.text()) {
                    Text("Share log")
                }

                Button("Clear log", role: .destructive) {
                    clearLog()
                }

                if let logNote {
                    Label(logNote, systemImage: "doc.on.doc")
                        .font(DS.TextRole.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(logNote)
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Copy or share recent technical logs to help support. They contain only counts, sizes and timings — no images or personal data.")
            }

            Section {
                LabeledContent("App", value: "Stickreate")
                LabeledContent("Version", value: Bundle.main.shortVersion)
                LabeledContent("Build", value: Bundle.main.buildNumber)
            } header: {
                Text("About")
            }
        }
        .navigationTitle("Settings")
        .haptic(.success, trigger: cacheNote)
        .onAppear { logCount = DebugLog.shared.count }
    }

    private var cacheIcon: String {
        (cacheNote?.hasPrefix("Freed") ?? false) ? "checkmark.circle.fill" : "info.circle"
    }

    private func clearCache() {
        let freed = settings.clearCache()
        cacheNote = freed > 0
            ? "Freed \(Self.formatted(freed))."
            : "Nothing to clear."
    }

    private func copyLog() {
        UIPasteboard.general.string = DebugLog.shared.text()
        logCount = DebugLog.shared.count
        logNote = "Copied"
    }

    private func clearLog() {
        DebugLog.shared.clear()
        logCount = 0
        logNote = "Log cleared."
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

// MARK: - Previews

#Preview("Light") {
    NavigationStack {
        SettingsView()
    }
}

#Preview("Dark") {
    NavigationStack {
        SettingsView()
    }
    .preferredColorScheme(.dark)
}

#Preview("Largest Dynamic Type") {
    NavigationStack {
        SettingsView()
    }
    .dynamicTypeSize(.accessibility5)
}

#Preview("Small iPhone (SE)") {
    NavigationStack {
        SettingsView()
    }
    .frame(width: 375, height: 667)
}

#Preview("Large iPhone (Pro Max)") {
    NavigationStack {
        SettingsView()
    }
    .frame(width: 430, height: 932)
}
