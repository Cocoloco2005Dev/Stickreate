#if DEBUG
import SwiftUI

/// DEBUG-only developer screen. The whole file is `#if DEBUG`, so it is stripped
/// from Release/App Store builds.
///
/// Entry points (both launch-arg gated, no shipping UI):
/// - `-StickreateSelfTest`: runs the self-test on launch and opens this screen
///   with the fresh report (used by CI / a device run to read the result).
/// - `-StickreateDebug`: opens this screen so checks can be run manually.
///
/// There is no in-app navigation hook from Settings: `SettingsView` is not in
/// scope for this change, so the launch argument is the entry point.
///
/// Deliberately plain system UI — this is a developer tool, not a product
/// screen; it carries no design-system tokens.
struct DebugView: View {
    /// When true (self-test launch arg), run the checks automatically on appear.
    var autoRun: Bool = false

    @State private var report: SelfTestReport?
    @State private var isRunning = false
    @State private var didAutoRun = false

    var body: some View {
        List {
            Section("Self-test") {
                Button {
                    Task { await runChecks() }
                } label: {
                    Label(isRunning ? "Running…" : "Run self-test", systemImage: "play.circle")
                }
                .disabled(isRunning)
            }

            if let report {
                Section("Summary") {
                    LabeledContent("Result", value: report.failed == 0 ? "Passed" : "Failed")
                    LabeledContent("Checks", value: "\(report.passed)/\(report.checks.count)")
                    LabeledContent("Duration", value: "\(Int(report.totalDurationMS.rounded())) ms")
                    Text(report.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Checks") {
                    ForEach(report.checks) { check in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(
                                check.name,
                                systemImage: check.passed ? "checkmark.circle.fill" : "xmark.octagon.fill"
                            )
                            .foregroundStyle(check.passed ? Color.green : Color.red)
                            Text("\(Int(check.durationMS.rounded())) ms · \(check.detail)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if SelfTestReport.fileExists {
                    Section {
                        ShareLink(item: SelfTestReport.fileURL) {
                            Label("Share report", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            } else {
                Section {
                    Text("No report yet.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Debug")
        .onAppear(perform: onAppear)
    }

    private func onAppear() {
        if report == nil { report = SelfTestReport.loadLast() }
        if autoRun, !didAutoRun {
            didAutoRun = true
            Task { await runChecks() }
        }
    }

    @MainActor
    private func runChecks() async {
        isRunning = true
        defer { isRunning = false }
        report = await Task.detached(priority: .userInitiated) {
            SelfTest.run()
        }.value
    }
}
#endif
