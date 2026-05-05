import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppManager: ObservableObject {
    @Published private(set) var state: NativeAppState

    private let app: FfiApp
    private var refreshTask: Task<Void, Never>?

    init() {
        let dataDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Nostr VPN", isDirectory: true)
            .path ?? ""
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let app = FfiApp(dataDir: dataDir, appVersion: version)
        self.app = app
        self.state = app.state()
    }

    func start() {
        guard refreshTask == nil else {
            return
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func refresh() {
        state = app.refresh()
    }

    func dispatch(_ action: NativeAppAction) {
        state = app.dispatch(action: action)
    }

    func toggleSession() {
        dispatch(state.sessionActive ? .disconnectSession : .connectSession)
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func handle(url: URL) {
        let raw = url.absoluteString
        if raw.starts(with: "nvpn://invite/") {
            dispatch(.importNetworkInvite(invite: raw))
        }
    }

    func saveNodeSettings(
        nodeName: String,
        endpoint: String,
        tunnelIp: String,
        listenPort: String
    ) {
        let parsedPort = UInt16(listenPort.trimmingCharacters(in: .whitespacesAndNewlines))
        dispatch(.updateSettings(patch: settingsPatch(
            nodeName: nodeName,
            endpoint: endpoint,
            tunnelIp: tunnelIp,
            listenPort: parsedPort
        )))
    }

    func setAdvertiseExitNode(_ enabled: Bool) {
        dispatch(.updateSettings(patch: settingsPatch(advertiseExitNode: enabled)))
    }

    func setAutoconnect(_ enabled: Bool) {
        dispatch(.updateSettings(patch: settingsPatch(autoconnect: enabled)))
    }

    func addRelay(_ relay: String) {
        let trimmed = relay.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            dispatch(.addRelay(relay: trimmed))
        }
    }

    func removeRelay(_ relay: String) {
        dispatch(.removeRelay(relay: relay))
    }

    func addParticipant(networkId: String, npub: String) {
        let trimmed = npub.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            dispatch(.addParticipant(networkId: networkId, npub: trimmed, alias: nil))
        }
    }

    func addNetwork(_ name: String) {
        dispatch(.addNetwork(name: name.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

func settingsPatch(
    nodeName: String? = nil,
    endpoint: String? = nil,
    tunnelIp: String? = nil,
    listenPort: UInt16? = nil,
    exitNode: String? = nil,
    advertiseExitNode: Bool? = nil,
    advertisedRoutes: String? = nil,
    magicDnsSuffix: String? = nil,
    autoconnect: Bool? = nil,
    launchOnStartup: Bool? = nil,
    closeToTrayOnClose: Bool? = nil
) -> SettingsPatch {
    SettingsPatch(
        nodeName: nodeName,
        endpoint: endpoint,
        tunnelIp: tunnelIp,
        listenPort: listenPort,
        exitNode: exitNode,
        advertiseExitNode: advertiseExitNode,
        advertisedRoutes: advertisedRoutes,
        magicDnsSuffix: magicDnsSuffix,
        autoconnect: autoconnect,
        launchOnStartup: launchOnStartup,
        closeToTrayOnClose: closeToTrayOnClose
    )
}
