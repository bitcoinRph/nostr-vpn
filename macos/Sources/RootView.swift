import SwiftUI

struct RootView: View {
    @ObservedObject var manager: AppManager

    @State private var nodeName = ""
    @State private var endpoint = ""
    @State private var tunnelIp = ""
    @State private var listenPort = ""
    @State private var relayInput = ""
    @State private var participantInput = ""
    @State private var networkNameInput = ""
    @State private var lastSyncedRev: UInt64 = 0

    private var state: NativeAppState {
        manager.state
    }

    private var activeNetwork: NativeNetworkState? {
        state.networks.first(where: { $0.enabled }) ?? state.networks.first
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    statusSection
                    if let activeNetwork {
                        networkSection(activeNetwork)
                        participantSection(activeNetwork)
                    }
                    relaySection
                    settingsSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 44)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    manager.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .onAppear(perform: syncDrafts)
        .onChange(of: state.rev) { _, _ in
            syncDrafts()
        }
    }

    private var sidebar: some View {
        List(selection: .constant(activeNetwork?.id)) {
            Section("Networks") {
                ForEach(state.networks, id: \.id) { network in
                    HStack {
                        Image(systemName: network.enabled ? "circle.fill" : "circle")
                            .foregroundStyle(network.enabled ? .green : .secondary)
                            .imageScale(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(network.name.isEmpty ? "Network" : network.name)
                            Text("\(network.onlineCount)/\(network.expectedCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                HStack {
                    TextField("New network", text: $networkNameInput)
                    Button {
                        manager.addNetwork(networkNameInput)
                        networkNameInput = ""
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(networkNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.sessionActive ? "Connected" : "Disconnected")
                        .font(.system(size: 30, weight: .semibold))
                    Text(state.sessionStatus)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    manager.toggleSession()
                } label: {
                    Label(
                        state.sessionActive ? "Disconnect" : "Connect",
                        systemImage: state.sessionActive ? "stop.fill" : "play.fill"
                    )
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 18) {
                metric("Mesh", state.meshReady ? "Ready" : "Pending")
                metric("Peers", "\(state.connectedPeerCount)/\(state.expectedPeerCount)")
                metric("Relay", state.relayConnected ? "Connected" : "Idle")
                metric("Tunnel", state.tunnelIp.isEmpty ? "None" : state.tunnelIp)
            }

            if !state.error.isEmpty {
                Label(state.error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    private func networkSection(_ network: NativeNetworkState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Active Network", systemImage: "point.3.connected.trianglepath.dotted")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    label("Name")
                    Text(network.name.isEmpty ? "Network" : network.name)
                }
                GridRow {
                    label("Mesh ID")
                    HStack {
                        Text(network.networkId).textSelection(.enabled)
                        Button {
                            manager.copy(network.networkId)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                GridRow {
                    label("Admin")
                    Text(network.localIsAdmin ? "Yes" : "No")
                }
            }
            HStack {
                Text(state.activeNetworkInvite.isEmpty ? "No invite" : state.activeNetworkInvite)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                Button {
                    manager.copy(state.activeNetworkInvite)
                } label: {
                    Label("Copy Invite", systemImage: "square.and.arrow.up")
                }
                .labelStyle(.iconOnly)
                .disabled(state.activeNetworkInvite.isEmpty)
            }
        }
    }

    private func participantSection(_ network: NativeNetworkState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Devices", systemImage: "desktopcomputer")
            ForEach(network.participants, id: \.pubkeyHex) { participant in
                HStack(spacing: 10) {
                    Image(systemName: participant.reachable ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(participant.reachable ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(participant.alias)
                        Text(participant.npub)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(participant.statusText)
                        .foregroundStyle(.secondary)
                    Button {
                        manager.copy(participant.npub)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("npub", text: $participantInput)
                Button {
                    manager.addParticipant(networkId: network.id, npub: participantInput)
                    participantInput = ""
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(participantInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var relaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Relays", systemImage: "antenna.radiowaves.left.and.right")
            ForEach(state.relays, id: \.url) { relay in
                HStack {
                    Image(systemName: relay.state == "up" ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(relay.state == "up" ? .green : .secondary)
                    Text(relay.url)
                        .textSelection(.enabled)
                    Spacer()
                    Text(relay.statusText)
                        .foregroundStyle(.secondary)
                    Button {
                        manager.removeRelay(relay.url)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Relay URL", text: $relayInput)
                Button {
                    manager.addRelay(relayInput)
                    relayInput = ""
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(relayInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Device", systemImage: "gearshape")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    label("Name")
                    TextField("Name", text: $nodeName)
                }
                GridRow {
                    label("Endpoint")
                    TextField("Endpoint", text: $endpoint)
                }
                GridRow {
                    label("Tunnel IP")
                    TextField("Tunnel IP", text: $tunnelIp)
                }
                GridRow {
                    label("Listen Port")
                    TextField("Listen Port", text: $listenPort)
                }
            }
            HStack {
                Toggle("Autoconnect", isOn: Binding(
                    get: { state.autoconnect },
                    set: { manager.setAutoconnect($0) }
                ))
                Toggle("Offer exit", isOn: Binding(
                    get: { state.advertiseExitNode },
                    set: { manager.setAdvertiseExitNode($0) }
                ))
            }
            Button {
                manager.saveNodeSettings(
                    nodeName: nodeName,
                    endpoint: endpoint,
                    tunnelIp: tunnelIp,
                    listenPort: listenPort
                )
            } label: {
                Label("Save", systemImage: "checkmark")
            }
        }
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(width: 90, alignment: .leading)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
        }
    }

    private func syncDrafts() {
        guard lastSyncedRev != state.rev else {
            return
        }
        lastSyncedRev = state.rev
        nodeName = state.nodeName
        endpoint = state.endpoint
        tunnelIp = state.tunnelIp
        listenPort = String(state.listenPort)
    }
}
