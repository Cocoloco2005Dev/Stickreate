import SwiftUI

@main
struct StickreateApp: App {
    var body: some Scene {
        WindowGroup {
            launchView
        }
    }

    /// Release always shows the product shell. In DEBUG, two launch arguments can
    /// divert to the self-test / debug screen; those symbols live in `#if DEBUG`
    /// files, so the whole branch disappears in Release.
    @ViewBuilder
    private var launchView: some View {
        #if DEBUG
        if SelfTestLaunch.isSelfTest {
            NavigationStack { DebugView(autoRun: true) }
        } else if SelfTestLaunch.isDebug {
            NavigationStack { DebugView() }
        } else {
            RootView()
        }
        #else
        RootView()
        #endif
    }
}
