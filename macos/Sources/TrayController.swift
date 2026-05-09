import AppKit
import Combine
import SwiftUI

/// AppKit-backed tray menu.
///
/// SwiftUI's `MenuBarExtra` rebuilt the menu hierarchy on every AppManager
/// state publish (~1.5s tick), which dismissed any submenu the user had
/// open. NSMenuItems are persistent AppKit objects: mutating their titles
/// in place leaves an open submenu undisturbed.
///
/// Menu layout:
///
///     ☐ VPN                       ← toggle, first item
///     ─────────────
///     <device-name>               ← disabled section header
///     Copy Device ID
///     ─────────────
///     <network-name> ▶            ← list of network peers (copy npub)
///     Exit Node ▶                 ← offer toggle + selection
///       <exit status, if any>
///       ☐ Offer This Device
///       ─────────
///       ☑ No exit node
///       Device 1
///       Device 2
///     ─────────────
///     Open Nostr VPN
///     Quit
@MainActor
final class TrayController: NSObject {
    private let manager: AppManager
    private let openMainWindow: () -> Void

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    // Stable items
    private let vpnToggleItem = NSMenuItem()
    private let vpnToggleView: VpnToggleItemView
    private let deviceNameItem = NSMenuItem()
    private let copyDeviceIdItem = NSMenuItem()
    private let networkSubmenuItem = NSMenuItem()
    private let exitNodeSubmenuItem = NSMenuItem()
    private let openItem = NSMenuItem()
    private let quitItem = NSMenuItem()

    private let networkSubmenu = NSMenu()
    private let exitNodeSubmenu = NSMenu()

    // Stable items inside Exit Node submenu
    private let exitNodeStatusItem = NSMenuItem()
    private let offerExitItem = NSMenuItem()
    private let exitNodeSelectionSeparator = NSMenuItem.separator()
    private let noExitNodeItem = NSMenuItem()

    private var cancellables = Set<AnyCancellable>()
    private var lastSnapshot: MenuSnapshot?

    init(manager: AppManager, openMainWindow: @escaping () -> Void) {
        self.manager = manager
        self.openMainWindow = openMainWindow
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Allocated before super.init so we can wire its callback to self.
        var toggleAction: () -> Void = {}
        self.vpnToggleView = VpnToggleItemView { toggleAction() }
        super.init()
        toggleAction = { [weak self] in self?.handleToggleVpn() }

        configureStatusItem()
        buildMenuSkeleton()
        statusItem.menu = menu

        refreshFromState()
        manager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshFromState()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Setup

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        if let image = NSImage(named: "TrayIcon") {
            image.isTemplate = true
            button.image = image
        }
        button.toolTip = "Nostr VPN"
    }

    private func buildMenuSkeleton() {
        // VPN toggle is a custom NSView with an NSSwitch — matches the in-app
        // header capsule toggle and the macOS native toggle pattern. The menu
        // item's view absorbs clicks on the switch; the surrounding row has
        // no action.
        vpnToggleItem.view = vpnToggleView

        deviceNameItem.isEnabled = false

        copyDeviceIdItem.title = "Copy Device ID"
        copyDeviceIdItem.target = self
        copyDeviceIdItem.action = #selector(handleCopyDeviceId)

        networkSubmenuItem.submenu = networkSubmenu
        networkSubmenuItem.isHidden = true

        exitNodeSubmenuItem.title = "Exit Node"
        exitNodeSubmenuItem.submenu = exitNodeSubmenu

        // Exit Node submenu skeleton.
        exitNodeStatusItem.isEnabled = false
        exitNodeStatusItem.isHidden = true

        offerExitItem.title = "Offer This Device"
        offerExitItem.target = self
        offerExitItem.action = #selector(handleToggleOfferExit)

        noExitNodeItem.title = "No exit node"
        noExitNodeItem.target = self
        noExitNodeItem.action = #selector(handleSelectNoExit)

        exitNodeSubmenu.addItem(exitNodeStatusItem)
        exitNodeSubmenu.addItem(offerExitItem)
        exitNodeSubmenu.addItem(exitNodeSelectionSeparator)
        exitNodeSubmenu.addItem(noExitNodeItem)
        // Peer items appended in updateExitNodeSubmenu().

        openItem.title = "Open Nostr VPN"
        openItem.target = self
        openItem.action = #selector(handleOpenMain)

        quitItem.title = "Quit"
        quitItem.target = self
        quitItem.action = #selector(handleQuit)
        quitItem.keyEquivalent = "q"

        menu.addItem(vpnToggleItem)
        menu.addItem(.separator())
        menu.addItem(deviceNameItem)
        menu.addItem(copyDeviceIdItem)
        menu.addItem(.separator())
        menu.addItem(networkSubmenuItem)
        menu.addItem(exitNodeSubmenuItem)
        menu.addItem(.separator())
        menu.addItem(openItem)
        menu.addItem(quitItem)
    }

    // MARK: - Update from state

    private func refreshFromState() {
        let snapshot = MenuSnapshot.capture(from: manager)
        if snapshot == lastSnapshot {
            return
        }
        lastSnapshot = snapshot

        // VPN toggle (NSSwitch in custom view).
        vpnToggleView.update(
            isOn: snapshot.vpnEnabled,
            isEnabled: snapshot.vpnTogglable,
            statusText: snapshot.vpnStatusText
        )

        // Device name + copy
        deviceNameItem.title = snapshot.deviceName
        copyDeviceIdItem.isEnabled = !snapshot.deviceIdValue.isEmpty

        // Network submenu
        networkSubmenuItem.title = snapshot.networkTitle ?? "Network Devices"
        networkSubmenuItem.isHidden = snapshot.networkTitle == nil
        rebuildSubmenu(networkSubmenu, items: snapshot.networkItems) { [weak self] item in
            self?.manager.copy(item.npub, as: .peerNpub, peerNpub: item.npub)
        }

        // Exit Node submenu
        exitNodeStatusItem.title = snapshot.exitNodeStatusText
        exitNodeStatusItem.isHidden = snapshot.exitNodeStatusText.isEmpty
        offerExitItem.state = snapshot.advertiseExitNode ? .on : .off
        noExitNodeItem.state = snapshot.exitNodeNpub.isEmpty ? .on : .off
        rebuildExitNodePeers(items: snapshot.exitNodeItems, selectedNpub: snapshot.exitNodeNpub)

        statusItem.button?.toolTip = snapshot.tooltip
    }

    private func rebuildSubmenu<T: Equatable>(
        _ submenu: NSMenu,
        items: [SubmenuItem<T>],
        action: @escaping (SubmenuItem<T>) -> Void
    ) {
        let current: [SubmenuItem<T>] = submenu.items.compactMap { item in
            (item.representedObject as? SubmenuClickPayload<T>)?.item
        }
        if current == items {
            return
        }
        submenu.removeAllItems()
        for item in items {
            let menuItem = NSMenuItem(
                title: item.title, action: #selector(handleSubmenuClick(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = SubmenuClickPayload(item: item, action: action)
            submenu.addItem(menuItem)
        }
    }

    /// The Exit Node submenu has stable header items (status, offer, separator,
    /// "No exit node") followed by a dynamic list of peers offering exit. Keep
    /// the header items in place and rebuild the trailing peer list.
    private func rebuildExitNodePeers(items: [SubmenuItem<ExitNodeRow>], selectedNpub: String) {
        // Drop everything past the "No exit node" item.
        let keepCount = exitNodeSubmenu.items.firstIndex(of: noExitNodeItem).map { $0 + 1 } ?? 0
        while exitNodeSubmenu.items.count > keepCount {
            exitNodeSubmenu.removeItem(at: exitNodeSubmenu.items.count - 1)
        }
        for item in items {
            let menuItem = NSMenuItem(
                title: item.title,
                action: #selector(handleSelectExitNode(_:)),
                keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.npub
            menuItem.state = item.npub == selectedNpub ? .on : .off
            exitNodeSubmenu.addItem(menuItem)
        }
    }

    // MARK: - Action handlers

    @objc private func handleToggleVpn() {
        manager.toggleVpn()
    }

    @objc private func handleToggleOfferExit() {
        manager.setAdvertiseExitNode(!manager.state.advertiseExitNode)
    }

    @objc private func handleCopyDeviceId() {
        let value = manager.state.ownNpub
        guard !value.isEmpty else { return }
        manager.copy(value, as: .pubkey)
    }

    @objc private func handleSubmenuClick(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? AnySubmenuClickPayload else { return }
        payload.invoke()
    }

    @objc private func handleSelectNoExit() {
        manager.setExitNode("")
    }

    @objc private func handleSelectExitNode(_ sender: NSMenuItem) {
        guard let npub = sender.representedObject as? String else { return }
        manager.setExitNode(npub)
    }

    @objc private func handleOpenMain() {
        openMainWindow()
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Menu snapshot

private struct MenuSnapshot: Equatable {
    let vpnEnabled: Bool
    let vpnTogglable: Bool
    let vpnStatusText: String
    let deviceName: String
    let deviceIdValue: String
    let networkTitle: String?
    let networkItems: [SubmenuItem<NetworkRow>]
    let exitNodeStatusText: String
    let advertiseExitNode: Bool
    let exitNodeNpub: String
    let exitNodeItems: [SubmenuItem<ExitNodeRow>]
    let tooltip: String

    @MainActor
    static func capture(from manager: AppManager) -> MenuSnapshot {
        let state = manager.state
        let activeNetwork = manager.activeNetwork

        var networkTitle: String? = nil
        var networkItems: [SubmenuItem<NetworkRow>] = []
        var exitNodeItems: [SubmenuItem<ExitNodeRow>] = []

        if let activeNetwork {
            networkTitle = activeNetwork.name.isEmpty ? "Network Devices" : activeNetwork.name
            networkItems = activeNetwork.participants.map { p in
                SubmenuItem<NetworkRow>(
                    title: participantMenuTitle(p),
                    npub: p.npub,
                    payload: NetworkRow(pubkeyHex: p.pubkeyHex)
                )
            }
            exitNodeItems = activeNetwork.participants.filter { $0.offersExitNode }
                .map { p in
                    SubmenuItem<ExitNodeRow>(
                        title: p.magicDnsName.isEmpty ? p.alias : p.magicDnsName,
                        npub: p.npub,
                        payload: ExitNodeRow(pubkeyHex: p.pubkeyHex)
                    )
                }
        }

        let tooltip: String = {
            if !state.exitNodeStatusText.isEmpty { return state.exitNodeStatusText }
            if !state.vpnStatus.isEmpty { return state.vpnStatus }
            return "Nostr VPN"
        }()

        return MenuSnapshot(
            vpnEnabled: state.vpnEnabled,
            vpnTogglable: !manager.actionInFlight && state.vpnControlSupported,
            vpnStatusText: vpnSubtitle(for: state, actionInFlight: manager.actionInFlight),
            deviceName: resolveDeviceName(from: state),
            deviceIdValue: state.ownNpub,
            networkTitle: networkTitle,
            networkItems: networkItems,
            exitNodeStatusText: state.exitNodeStatusText,
            advertiseExitNode: state.advertiseExitNode,
            exitNodeNpub: state.exitNode,
            exitNodeItems: exitNodeItems,
            tooltip: tooltip
        )
    }
}

private func vpnSubtitle(for state: NativeAppState, actionInFlight: Bool) -> String {
    if actionInFlight, !state.vpnStatus.isEmpty {
        return state.vpnStatus
    }
    if state.vpnActive {
        return "Connected"
    }
    if state.vpnEnabled, !state.vpnStatus.isEmpty {
        return state.vpnStatus
    }
    return state.vpnEnabled ? "Connecting…" : "Off"
}

private func resolveDeviceName(from state: NativeAppState) -> String {
    if !state.selfMagicDnsName.isEmpty {
        return state.selfMagicDnsName
    }
    if !state.nodeName.isEmpty {
        return state.nodeName
    }
    if !state.tunnelIp.isEmpty, state.tunnelIp != "-" {
        return state.tunnelIp
    }
    return "This Device"
}

private func participantMenuTitle(_ participant: NativeParticipantState) -> String {
    let name = participant.magicDnsName.isEmpty ? participant.alias : participant.magicDnsName
    if participant.tunnelIp.isEmpty || participant.tunnelIp == "-" {
        return name
    }
    return "\(name) (\(participant.tunnelIp))"
}

private struct NetworkRow: Equatable { let pubkeyHex: String }
private struct ExitNodeRow: Equatable { let pubkeyHex: String }

private struct SubmenuItem<Payload: Equatable>: Equatable {
    let title: String
    let npub: String
    let payload: Payload
}

private protocol AnySubmenuClickPayload {
    func invoke()
}

private struct SubmenuClickPayload<T: Equatable>: AnySubmenuClickPayload {
    let item: SubmenuItem<T>
    let action: (SubmenuItem<T>) -> Void
    func invoke() { action(item) }
}

// MARK: - VPN toggle row view

/// Custom NSView used as the first menu item: a brand-style row with a
/// title, a status subtitle, and a real NSSwitch on the right. NSSwitch is
/// the platform-native toggle widget — same control class used in
/// Tailscale's menu bar item, System Settings, etc.
@MainActor
private final class VpnToggleItemView: NSView {
    let titleLabel = NSTextField(labelWithString: "VPN")
    let subtitleLabel = NSTextField(labelWithString: "")
    let toggle = NSSwitch()
    private let onToggle: () -> Void

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 44))
        autoresizingMask = .width

        titleLabel.font = NSFont.menuFont(ofSize: 0)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.target = self
        toggle.action = #selector(handleToggle)
        addSubview(toggle)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: toggle.leadingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    @objc private func handleToggle() {
        onToggle()
    }

    func update(isOn: Bool, isEnabled: Bool, statusText: String) {
        // Avoid restarting the switch's animation when nothing changed.
        let desiredState: NSControl.StateValue = isOn ? .on : .off
        if toggle.state != desiredState {
            toggle.state = desiredState
        }
        if toggle.isEnabled != isEnabled {
            toggle.isEnabled = isEnabled
        }
        titleLabel.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        if subtitleLabel.stringValue != statusText {
            subtitleLabel.stringValue = statusText
        }
        subtitleLabel.isHidden = statusText.isEmpty
    }
}
