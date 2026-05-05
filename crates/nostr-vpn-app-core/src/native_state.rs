#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq, Default)]
pub struct NativeRelayState {
    pub url: String,
    pub state: String,
    pub status_text: String,
}

#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq, Default)]
pub struct NativeParticipantState {
    pub npub: String,
    pub pubkey_hex: String,
    pub alias: String,
    pub tunnel_ip: String,
    pub is_admin: bool,
    pub reachable: bool,
    pub status_text: String,
}

#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq, Default)]
pub struct NativeNetworkState {
    pub id: String,
    pub name: String,
    pub enabled: bool,
    pub network_id: String,
    pub local_is_admin: bool,
    pub join_requests_enabled: bool,
    pub online_count: u64,
    pub expected_count: u64,
    pub admins: Vec<String>,
    pub participants: Vec<NativeParticipantState>,
}

#[allow(clippy::struct_excessive_bools)]
#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq, Default)]
pub struct NativeAppState {
    pub rev: u64,
    pub platform: String,
    pub mobile: bool,
    pub vpn_session_control_supported: bool,
    pub cli_install_supported: bool,
    pub startup_settings_supported: bool,
    pub tray_behavior_supported: bool,
    pub runtime_status_detail: String,
    pub app_version: String,
    pub config_path: String,
    pub error: String,
    pub daemon_running: bool,
    pub session_active: bool,
    pub relay_connected: bool,
    pub session_status: String,
    pub daemon_binary_version: String,
    pub own_npub: String,
    pub own_pubkey_hex: String,
    pub node_id: String,
    pub node_name: String,
    pub endpoint: String,
    pub tunnel_ip: String,
    pub listen_port: u32,
    pub network_id: String,
    pub active_network_invite: String,
    pub exit_node: String,
    pub advertise_exit_node: bool,
    pub advertised_routes: Vec<String>,
    pub effective_advertised_routes: Vec<String>,
    pub magic_dns_suffix: String,
    pub autoconnect: bool,
    pub launch_on_startup: bool,
    pub close_to_tray_on_close: bool,
    pub connected_peer_count: u64,
    pub expected_peer_count: u64,
    pub mesh_ready: bool,
    pub networks: Vec<NativeNetworkState>,
    pub relays: Vec<NativeRelayState>,
}
