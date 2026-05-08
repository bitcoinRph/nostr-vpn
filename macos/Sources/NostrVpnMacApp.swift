import AppKit
import SwiftUI

@main
struct NostrVpnMacApp: App {
    @StateObject private var manager: AppManager
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    init() {
        runUpdateE2ECommandIfRequested()
        _manager = StateObject(wrappedValue: AppManager())
    }

    var body: some Scene {
        WindowGroup("Nostr VPN", id: "main") {
            RootView(manager: manager)
                .frame(minWidth: 880, minHeight: 620)
                .onAppear {
                    appDelegate.configure(manager: manager)
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
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 760)
        .windowResizability(.automatic)

        MenuBarExtra {
            StatusMenuView(manager: manager) {
                openWindow(id: "main")
                appDelegate.showMainWindow()
                NSApp.activate(ignoringOtherApps: true)
            }
        } label: {
            TrayIconLabel(state: manager.state)
        }
    }
}

private struct TrayIconLabel: View {
    let state: NativeAppState

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image("TrayIcon")
                .renderingMode(.template)
            if state.exitNodeBlocked {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                    .offset(x: 2, y: -2)
            }
        }
        .help(trayHelpText)
    }

    private var trayHelpText: String {
        if !state.exitNodeStatusText.isEmpty {
            return state.exitNodeStatusText
        }
        if !state.vpnStatus.isEmpty {
            return state.vpnStatus
        }
        return "Nostr VPN"
    }
}
