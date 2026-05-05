import AppKit
import SwiftUI

@main
struct NostrVpnMacApp: App {
    @StateObject private var manager = AppManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(manager: manager)
                .frame(minWidth: 880, minHeight: 620)
                .onAppear {
                    manager.start()
                }
                .onOpenURL { url in
                    manager.handle(url: url)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        manager.refresh()
                    }
                }
        }
        .defaultSize(width: 1100, height: 760)
        .windowResizability(.automatic)
    }
}
