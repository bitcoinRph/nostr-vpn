import AppKit
import CoreImage
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppManager: ObservableObject {
    @Published private(set) var state: NativeAppState
    @Published private(set) var actionInFlight = false
    @Published private(set) var actionStatus = ""
    @Published private(set) var copiedValue: CopyValue?
    @Published private(set) var copiedPeerNpub: String?

    private let app: FfiApp
    private var refreshTask: Task<Void, Never>?
    private var copyClearTask: Task<Void, Never>?

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

    var activeNetwork: NativeNetworkState? {
        state.networks.first(where: { $0.enabled }) ?? state.networks.first
    }

    var inactiveNetworks: [NativeNetworkState] {
        state.networks.filter { !$0.enabled }
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
        let app = app
        Task {
            let nextState = await Task.detached {
                app.refresh()
            }.value
            await MainActor.run {
                self.state = nextState
            }
        }
    }

    func dispatch(_ action: NativeAppAction, status: String = "") {
        guard !actionInFlight else {
            return
        }
        actionInFlight = true
        actionStatus = status
        let app = app
        Task {
            let nextState = await Task.detached {
                app.dispatch(action: action)
            }.value
            await MainActor.run {
                self.state = nextState
                self.actionInFlight = false
                self.actionStatus = nextState.error.isEmpty ? "" : nextState.error
            }
        }
    }

    func toggleSession() {
        dispatch(
            state.sessionActive ? .disconnectSession : .connectSession,
            status: state.sessionActive ? "Disconnecting VPN" : "Connecting VPN"
        )
    }

    func copy(_ value: String, as copied: CopyValue? = nil, peerNpub: String? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedValue = copied
        copiedPeerNpub = peerNpub
        copyClearTask?.cancel()
        copyClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                guard !Task.isCancelled else {
                    return
                }
                self?.copiedValue = nil
                self?.copiedPeerNpub = nil
            }
        }
    }

    func share(_ value: String) {
        guard let contentView = NSApp.keyWindow?.contentView else {
            copy(value, as: .invite)
            return
        }
        let picker = NSSharingServicePicker(items: [value])
        picker.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
    }

    func handle(url: URL) {
        let raw = url.absoluteString
        if raw.starts(with: "nvpn://invite/") {
            importInvite(raw)
        } else if raw.starts(with: "nvpn://debug/tick") {
            dispatch(.tick, status: "Refreshing")
        }
    }

    func importInvite(_ invite: String) {
        let trimmed = invite.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        dispatch(.importNetworkInvite(invite: trimmed), status: "Importing invite")
    }

    func chooseInviteQrImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            Task { @MainActor in
                self?.importInviteFromQrImage(url)
            }
        }
    }

    func importInviteFromQrImage(_ url: URL) {
        do {
            let invite = try decodeQrCode(from: url)
            importInvite(invite)
        } catch {
            actionStatus = error.localizedDescription
        }
    }

    func saveNodeSettings(
        nodeName: String,
        endpoint: String,
        tunnelIp: String,
        listenPort: String,
        magicDnsSuffix: String
    ) {
        let parsedPort = UInt16(listenPort.trimmingCharacters(in: .whitespacesAndNewlines))
        dispatch(.updateSettings(patch: settingsPatch(
            nodeName: nodeName,
            endpoint: endpoint,
            tunnelIp: tunnelIp,
            listenPort: parsedPort,
            magicDnsSuffix: magicDnsSuffix
        )), status: "Saving device settings")
    }

    func setAdvertiseExitNode(_ enabled: Bool) {
        dispatch(.updateSettings(patch: settingsPatch(advertiseExitNode: enabled)), status: "Saving routing")
    }

    func setAutoconnect(_ enabled: Bool) {
        dispatch(.updateSettings(patch: settingsPatch(autoconnect: enabled)), status: "Saving session option")
    }

    func setLaunchOnStartup(_ enabled: Bool) {
        dispatch(.updateSettings(patch: settingsPatch(launchOnStartup: enabled)), status: "Saving startup option")
    }

    func setCloseToTray(_ enabled: Bool) {
        dispatch(.updateSettings(patch: settingsPatch(closeToTrayOnClose: enabled)), status: "Saving menu bar option")
    }

    func setAdvertisedRoutes(_ routes: String) {
        dispatch(.updateSettings(patch: settingsPatch(advertisedRoutes: routes)), status: "Saving routes")
    }

    func setExitNode(_ npub: String) {
        dispatch(.updateSettings(patch: settingsPatch(exitNode: npub)), status: "Saving exit node")
    }

    func addRelay(_ relay: String) {
        let trimmed = relay.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            dispatch(.addRelay(relay: trimmed), status: "Adding relay")
        }
    }

    func removeRelay(_ relay: String) {
        dispatch(.removeRelay(relay: relay), status: "Removing relay")
    }

    func addParticipant(networkId: String, npub: String, alias: String? = nil) {
        let trimmed = npub.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let trimmedAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
            dispatch(
                .addParticipant(networkId: networkId, npub: trimmed, alias: trimmedAlias?.isEmpty == false ? trimmedAlias : nil),
                status: "Adding participant"
            )
        }
    }

    func renameNetwork(networkId: String, name: String) {
        dispatch(.renameNetwork(networkId: networkId, name: name), status: "Renaming network")
    }

    func setNetworkMeshId(networkId: String, meshId: String) {
        dispatch(.setNetworkMeshId(networkId: networkId, meshId: meshId), status: "Saving mesh ID")
    }

    func setNetworkEnabled(networkId: String, enabled: Bool) {
        dispatch(.setNetworkEnabled(networkId: networkId, enabled: enabled), status: enabled ? "Activating network" : "Disabling network")
    }

    func setJoinRequests(networkId: String, enabled: Bool) {
        dispatch(.setNetworkJoinRequestsEnabled(networkId: networkId, enabled: enabled), status: "Saving join request setting")
    }

    func requestNetworkJoin(networkId: String) {
        dispatch(.requestNetworkJoin(networkId: networkId), status: "Requesting network join")
    }

    func acceptJoinRequest(networkId: String, requesterNpub: String) {
        dispatch(.acceptJoinRequest(networkId: networkId, requesterNpub: requesterNpub), status: "Accepting join request")
    }

    func setParticipantAlias(npub: String, alias: String) {
        dispatch(.setParticipantAlias(npub: npub, alias: alias), status: "Saving alias")
    }

    func toggleAdmin(networkId: String, participant: NativeParticipantState) {
        if participant.isAdmin {
            dispatch(.removeAdmin(networkId: networkId, npub: participant.npub), status: "Removing admin")
        } else {
            dispatch(.addAdmin(networkId: networkId, npub: participant.npub), status: "Adding admin")
        }
    }

    func removeParticipant(networkId: String, npub: String) {
        dispatch(.removeParticipant(networkId: networkId, npub: npub), status: "Removing participant")
    }

    func addNetwork(_ name: String) {
        dispatch(.addNetwork(name: name.trimmingCharacters(in: .whitespacesAndNewlines)), status: "Adding network")
    }

    func removeNetwork(_ networkId: String) {
        dispatch(.removeNetwork(networkId: networkId), status: "Deleting network")
    }

    func installCli() {
        dispatch(.installCli, status: "Installing CLI")
    }

    func uninstallCli() {
        dispatch(.uninstallCli, status: "Uninstalling CLI")
    }

    func installService() {
        dispatch(.installSystemService, status: "Installing service")
    }

    func enableService() {
        dispatch(.enableSystemService, status: "Enabling service")
    }

    func disableService() {
        dispatch(.disableSystemService, status: "Disabling service")
    }

    func uninstallService() {
        dispatch(.uninstallSystemService, status: "Uninstalling service")
    }

    func startLanPairing() {
        dispatch(.startLanPairing, status: "Starting LAN pairing")
    }

    func stopLanPairing() {
        dispatch(.stopLanPairing, status: "Stopping LAN pairing")
    }

    private func decodeQrCode(from url: URL) throws -> String {
        guard let image = CIImage(contentsOf: url) else {
            throw QrImportError.unreadableImage
        }
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let features = detector?.features(in: image) ?? []
        for feature in features {
            if let qr = feature as? CIQRCodeFeature,
               let message = qr.messageString?.trimmingCharacters(in: .whitespacesAndNewlines),
               !message.isEmpty {
                return message
            }
        }
        throw QrImportError.noQrCode
    }
}

enum CopyValue {
    case pubkey
    case meshId
    case invite
    case peerNpub
}

enum QrImportError: LocalizedError {
    case unreadableImage
    case noQrCode

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "Could not read the selected image."
        case .noQrCode:
            return "No QR invite was found in the selected image."
        }
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
