use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result, anyhow};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use nostr_sdk::prelude::{PublicKey, ToBech32};
use nostr_vpn_core::config::{
    AppConfig, NetworkConfig, maybe_autoconfigure_node, normalize_advertised_route,
    normalize_nostr_pubkey,
};
use serde::Deserialize;

use crate::actions::NativeAppAction;
use crate::native_state::{
    NativeAppState, NativeNetworkState, NativeParticipantState, NativeRelayState,
};
use crate::platform::current_runtime_capabilities;
use crate::state::{DaemonRuntimeState, SettingsPatch};

const NVPN_BIN_ENV: &str = "NVPN_CLI_PATH";
const NETWORK_INVITE_PREFIX: &str = "nvpn://invite/";
const NETWORK_INVITE_VERSION: u8 = 3;

#[derive(uniffi::Object, Debug)]
pub struct FfiApp {
    runtime: Mutex<NativeAppRuntime>,
}

#[uniffi::export]
impl FfiApp {
    #[uniffi::constructor]
    #[allow(clippy::needless_pass_by_value)]
    #[must_use]
    pub fn new(data_dir: String, app_version: String) -> Arc<Self> {
        let runtime = NativeAppRuntime::new(&data_dir, app_version)
            .unwrap_or_else(|error| NativeAppRuntime::from_startup_error(&error));
        Arc::new(Self {
            runtime: Mutex::new(runtime),
        })
    }

    #[must_use]
    pub fn state(&self) -> NativeAppState {
        self.with_runtime(|runtime| runtime.state())
    }

    #[must_use]
    pub fn refresh(&self) -> NativeAppState {
        self.dispatch(NativeAppAction::Tick)
    }

    #[must_use]
    pub fn dispatch(&self, action: NativeAppAction) -> NativeAppState {
        self.with_runtime(|runtime| {
            runtime.dispatch(action);
            runtime.state()
        })
    }
}

impl FfiApp {
    fn with_runtime(
        &self,
        f: impl FnOnce(&mut NativeAppRuntime) -> NativeAppState,
    ) -> NativeAppState {
        match self.runtime.lock() {
            Ok(mut runtime) => f(&mut runtime),
            Err(poisoned) => {
                let mut runtime = poisoned.into_inner();
                runtime.set_error("native app state lock was poisoned");
                f(&mut runtime)
            }
        }
    }
}

#[derive(Debug)]
struct NativeAppRuntime {
    rev: u64,
    app_version: String,
    config_path: PathBuf,
    config: AppConfig,
    nvpn_bin: Option<PathBuf>,
    startup_error: Option<String>,
    last_error: String,
    daemon_running: bool,
    session_active: bool,
    relay_connected: bool,
    session_status: String,
    daemon_state: Option<DaemonRuntimeState>,
}

#[derive(Debug, Deserialize)]
struct CliStatusResponse {
    daemon: CliDaemonStatus,
}

#[derive(Debug, Deserialize)]
struct CliDaemonStatus {
    running: bool,
    state: Option<DaemonRuntimeState>,
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct NetworkInvite {
    v: u8,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    network_name: String,
    network_id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    inviter_npub: String,
    #[serde(default)]
    inviter_node_name: String,
    #[serde(default)]
    admins: Vec<String>,
    #[serde(default)]
    participants: Vec<String>,
    #[serde(default)]
    relays: Vec<String>,
}

impl NativeAppRuntime {
    fn new(data_dir: &str, app_version: String) -> Result<Self> {
        let config_path = native_config_path(data_dir);
        let mut config = if config_path.exists() {
            AppConfig::load(&config_path)?
        } else {
            let generated = AppConfig::generated();
            generated.save(&config_path)?;
            generated
        };
        config.ensure_defaults();
        maybe_autoconfigure_node(&mut config);
        config.save(&config_path)?;

        let mut runtime = Self {
            rev: 0,
            app_version,
            config_path,
            config,
            nvpn_bin: resolve_nvpn_cli_path().ok(),
            startup_error: None,
            last_error: String::new(),
            daemon_running: false,
            session_active: false,
            relay_connected: false,
            session_status: "Disconnected".to_string(),
            daemon_state: None,
        };
        let _ = runtime.refresh_status();
        Ok(runtime)
    }

    fn from_startup_error(error: &anyhow::Error) -> Self {
        let error = error.to_string();
        Self {
            rev: 0,
            app_version: env!("CARGO_PKG_VERSION").to_string(),
            config_path: default_config_path(),
            config: AppConfig::generated(),
            nvpn_bin: resolve_nvpn_cli_path().ok(),
            startup_error: Some(error.clone()),
            last_error: error,
            daemon_running: false,
            session_active: false,
            relay_connected: false,
            session_status: "Startup failed".to_string(),
            daemon_state: None,
        }
    }

    fn state(&self) -> NativeAppState {
        let capabilities = current_runtime_capabilities();
        let own_pubkey_hex = self.config.own_nostr_pubkey_hex().unwrap_or_default();
        let active_network = self.config.active_network();
        let daemon_state = self.daemon_state.as_ref();
        let expected_peer_count = daemon_state.map_or_else(
            || active_network.participants.len() + active_network.admins.len(),
            |state| state.expected_peer_count,
        );
        let connected_peer_count = daemon_state.map_or(0, |state| state.connected_peer_count);
        let endpoint = daemon_state
            .and_then(|state| non_empty(&state.advertised_endpoint))
            .unwrap_or_else(|| self.config.node.endpoint.clone());
        let listen_port = daemon_state
            .and_then(|state| (state.listen_port > 0).then_some(state.listen_port))
            .unwrap_or(self.config.node.listen_port);

        NativeAppState {
            rev: self.rev,
            platform: capabilities.platform,
            mobile: capabilities.mobile,
            vpn_session_control_supported: capabilities.vpn_session_control_supported,
            cli_install_supported: capabilities.cli_install_supported,
            startup_settings_supported: capabilities.startup_settings_supported,
            tray_behavior_supported: capabilities.tray_behavior_supported,
            runtime_status_detail: capabilities.runtime_status_detail,
            app_version: if self.app_version.is_empty() {
                env!("CARGO_PKG_VERSION").to_string()
            } else {
                self.app_version.clone()
            },
            config_path: self.config_path.display().to_string(),
            error: self
                .startup_error
                .clone()
                .filter(|value| !value.is_empty())
                .unwrap_or_else(|| self.last_error.clone()),
            daemon_running: self.daemon_running,
            session_active: self.session_active,
            relay_connected: self.relay_connected,
            session_status: self.session_status.clone(),
            daemon_binary_version: daemon_state
                .map(|state| state.binary_version.clone())
                .unwrap_or_default(),
            own_npub: to_npub(&own_pubkey_hex),
            own_pubkey_hex: own_pubkey_hex.clone(),
            node_id: self.config.node.id.clone(),
            node_name: self.config.node_name.clone(),
            endpoint,
            tunnel_ip: self.config.node.tunnel_ip.clone(),
            listen_port: u32::from(listen_port),
            network_id: self.config.effective_network_id(),
            active_network_invite: active_network_invite_code(&self.config).unwrap_or_default(),
            exit_node: self.config.exit_node.clone(),
            advertise_exit_node: self.config.node.advertise_exit_node,
            advertised_routes: self.config.node.advertised_routes.clone(),
            effective_advertised_routes: self.config.effective_advertised_routes(),
            magic_dns_suffix: self.config.magic_dns_suffix.clone(),
            autoconnect: self.config.autoconnect,
            launch_on_startup: self.config.launch_on_startup,
            close_to_tray_on_close: self.config.close_to_tray_on_close,
            connected_peer_count: connected_peer_count as u64,
            expected_peer_count: expected_peer_count as u64,
            mesh_ready: daemon_state.map_or_else(
                || expected_peer_count > 0 && connected_peer_count >= expected_peer_count,
                |state| state.mesh_ready,
            ),
            networks: self.network_states(&own_pubkey_hex),
            relays: self.relay_states(),
        }
    }

    fn dispatch(&mut self, action: NativeAppAction) {
        let result = self.apply_action(action);
        match result {
            Ok(()) => self.last_error.clear(),
            Err(error) => self.set_error(error.to_string()),
        }
        self.rev = self.rev.saturating_add(1);
    }

    #[allow(clippy::too_many_lines)]
    fn apply_action(&mut self, action: NativeAppAction) -> Result<()> {
        match action {
            NativeAppAction::GetState | NativeAppAction::Tick => self.refresh_status(),
            NativeAppAction::ConnectSession => self.connect_session(),
            NativeAppAction::DisconnectSession => self.disconnect_session(),
            NativeAppAction::InstallCli => self.run_nvpn(["install-cli"]).map(|_| ()),
            NativeAppAction::UninstallCli => self.run_nvpn(["uninstall-cli"]).map(|_| ()),
            NativeAppAction::InstallSystemService => {
                let output = self.run_nvpn_elevated([
                    "service",
                    "install",
                    "--force",
                    "--config",
                    self.config_path_str()?,
                ])?;
                ensure_success("nvpn service install", &output)
            }
            NativeAppAction::UninstallSystemService => {
                let output = self.run_nvpn_elevated([
                    "service",
                    "uninstall",
                    "--config",
                    self.config_path_str()?,
                ])?;
                ensure_success("nvpn service uninstall", &output)
            }
            NativeAppAction::EnableSystemService => {
                let output = self.run_nvpn_elevated([
                    "service",
                    "enable",
                    "--config",
                    self.config_path_str()?,
                ])?;
                ensure_success("nvpn service enable", &output)
            }
            NativeAppAction::DisableSystemService => {
                let output = self.run_nvpn_elevated([
                    "service",
                    "disable",
                    "--config",
                    self.config_path_str()?,
                ])?;
                ensure_success("nvpn service disable", &output)
            }
            NativeAppAction::AddNetwork { name } => {
                self.config.add_network(&name);
                self.save_reload_and_refresh()
            }
            NativeAppAction::RenameNetwork { network_id, name } => {
                self.config.rename_network(&network_id, &name)?;
                self.save_reload_and_refresh()
            }
            NativeAppAction::RemoveNetwork { network_id } => {
                self.config.remove_network(&network_id)?;
                self.save_reload_and_refresh()
            }
            NativeAppAction::SetNetworkMeshId {
                network_id,
                mesh_id,
            } => {
                self.config.set_network_mesh_id(&network_id, &mesh_id)?;
                self.save_reload_and_refresh()
            }
            NativeAppAction::SetNetworkEnabled {
                network_id,
                enabled,
            } => {
                self.config.set_network_enabled(&network_id, enabled)?;
                self.save_reload_and_refresh()
            }
            NativeAppAction::SetNetworkJoinRequestsEnabled {
                network_id,
                enabled,
            } => {
                self.config
                    .set_network_join_requests_enabled(&network_id, enabled)?;
                self.save_reload_and_refresh()
            }
            NativeAppAction::RequestNetworkJoin { .. }
            | NativeAppAction::AcceptJoinRequest { .. }
            | NativeAppAction::StartLanPairing
            | NativeAppAction::StopLanPairing => Err(anyhow!(
                "this native macOS action is not wired yet; core state/action ownership is in place"
            )),
            NativeAppAction::AddParticipant {
                network_id,
                npub,
                alias,
            } => {
                let normalized = self.config.add_participant_to_network(&network_id, &npub)?;
                if let Some(alias) = alias
                    .as_deref()
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                {
                    self.config.set_peer_alias(&normalized, alias)?;
                }
                self.save_reload_and_refresh()
            }
            NativeAppAction::AddAdmin { network_id, npub } => {
                self.config.add_admin_to_network(&network_id, &npub)?;
                self.save_reload_and_refresh()
            }
            NativeAppAction::ImportNetworkInvite { invite } => {
                let output = self.run_nvpn([
                    "import-invite",
                    "--config",
                    self.config_path_str()?,
                    &invite,
                ])?;
                self.reload_config_from_disk()?;
                let _ = self.refresh_status();
                ensure_success("nvpn import-invite", &output)
            }
            NativeAppAction::RemoveParticipant { network_id, npub } => {
                self.config
                    .remove_participant_from_network(&network_id, &npub)?;
                self.save_reload_and_refresh()
            }
            NativeAppAction::RemoveAdmin { network_id, npub } => {
                self.config.remove_admin_from_network(&network_id, &npub)?;
                self.save_reload_and_refresh()
            }
            NativeAppAction::SetParticipantAlias { npub, alias } => {
                self.config.set_peer_alias(&npub, &alias)?;
                self.save_reload_and_refresh()
            }
            NativeAppAction::AddRelay { relay } => {
                let trimmed = relay.trim();
                if trimmed.is_empty() {
                    return Err(anyhow!("relay URL is empty"));
                }
                if !self
                    .config
                    .nostr
                    .relays
                    .iter()
                    .any(|value| value == trimmed)
                {
                    self.config.nostr.relays.push(trimmed.to_string());
                }
                self.save_reload_and_refresh()
            }
            NativeAppAction::RemoveRelay { relay } => {
                self.config.nostr.relays.retain(|value| value != &relay);
                if self.config.nostr.relays.is_empty() {
                    return Err(anyhow!("at least one relay is required"));
                }
                self.save_reload_and_refresh()
            }
            NativeAppAction::UpdateSettings { patch } => {
                self.apply_settings_patch(patch)?;
                self.save_reload_and_refresh()
            }
        }
    }

    fn apply_settings_patch(&mut self, patch: SettingsPatch) -> Result<()> {
        if let Some(value) = patch.node_name {
            self.config.node_name = value.trim().to_string();
        }
        if let Some(value) = patch.endpoint {
            self.config.node.endpoint = value.trim().to_string();
        }
        if let Some(value) = patch.tunnel_ip {
            self.config.node.tunnel_ip = value.trim().to_string();
        }
        if let Some(value) = patch.listen_port {
            self.config.node.listen_port = value;
        }
        if let Some(value) = patch.exit_node {
            self.config.exit_node = if value.trim().is_empty() {
                String::new()
            } else {
                normalize_nostr_pubkey(&value)?
            };
        }
        if let Some(value) = patch.advertise_exit_node {
            self.config.node.advertise_exit_node = value;
        }
        if let Some(value) = patch.advertised_routes {
            self.config.node.advertised_routes = parse_advertised_routes(&value);
        }
        if let Some(value) = patch.magic_dns_suffix {
            self.config.magic_dns_suffix = value.trim().trim_matches('.').to_ascii_lowercase();
        }
        if let Some(value) = patch.autoconnect {
            self.config.autoconnect = value;
        }
        if let Some(value) = patch.launch_on_startup {
            self.config.launch_on_startup = value;
        }
        if let Some(value) = patch.close_to_tray_on_close {
            self.config.close_to_tray_on_close = value;
        }
        Ok(())
    }

    fn connect_session(&mut self) -> Result<()> {
        self.save_config()?;
        let output = self.run_nvpn_elevated([
            "start",
            "--daemon",
            "--connect",
            "--config",
            self.config_path_str()?,
        ])?;
        ensure_success("nvpn start", &output)?;
        self.refresh_status()
    }

    fn disconnect_session(&mut self) -> Result<()> {
        let output = self.run_nvpn(["pause", "--config", self.config_path_str()?])?;
        ensure_success("nvpn pause", &output)?;
        self.refresh_status()
    }

    fn refresh_status(&mut self) -> Result<()> {
        self.reload_config_from_disk()?;
        let output = self.run_nvpn([
            "status",
            "--json",
            "--discover-secs",
            "0",
            "--config",
            self.config_path_str()?,
        ]);

        match output {
            Ok(output) if output.status.success() => {
                let stdout = String::from_utf8_lossy(&output.stdout);
                let json_text = extract_json_document(&stdout)?;
                let parsed = serde_json::from_str::<CliStatusResponse>(json_text)
                    .context("failed to parse `nvpn status --json` output")?;
                self.daemon_state = parsed.daemon.state;
                self.daemon_running = parsed.daemon.running;
                self.session_active = self
                    .daemon_state
                    .as_ref()
                    .map_or(parsed.daemon.running, |state| state.session_active);
                self.relay_connected = self
                    .daemon_state
                    .as_ref()
                    .is_some_and(|state| state.relay_connected);
                self.session_status = self.daemon_state.as_ref().map_or_else(
                    || {
                        if parsed.daemon.running {
                            "Daemon running".to_string()
                        } else {
                            "Disconnected".to_string()
                        }
                    },
                    |state| state.session_status.clone(),
                );
                Ok(())
            }
            Ok(output) => {
                self.daemon_state = None;
                self.daemon_running = false;
                self.session_active = false;
                self.relay_connected = false;
                self.session_status = "Daemon status unavailable".to_string();
                Err(command_failure("nvpn status", &output))
            }
            Err(error) => {
                self.daemon_state = None;
                self.daemon_running = false;
                self.session_active = false;
                self.relay_connected = false;
                self.session_status = "CLI unavailable".to_string();
                Err(error)
            }
        }
    }

    fn save_reload_and_refresh(&mut self) -> Result<()> {
        self.save_config()?;
        if self.daemon_running {
            let output = self.run_nvpn(["reload", "--config", self.config_path_str()?])?;
            ensure_success("nvpn reload", &output)?;
        }
        self.refresh_status()
    }

    fn save_config(&mut self) -> Result<()> {
        self.config.ensure_defaults();
        maybe_autoconfigure_node(&mut self.config);
        self.config.save(&self.config_path)
    }

    fn reload_config_from_disk(&mut self) -> Result<()> {
        if self.config_path.exists() {
            self.config = AppConfig::load(&self.config_path)?;
            self.config.ensure_defaults();
            maybe_autoconfigure_node(&mut self.config);
        }
        Ok(())
    }

    fn network_states(&self, own_pubkey_hex: &str) -> Vec<NativeNetworkState> {
        self.config
            .networks
            .iter()
            .map(|network| self.network_state(network, own_pubkey_hex))
            .collect()
    }

    fn network_state(&self, network: &NetworkConfig, own_pubkey_hex: &str) -> NativeNetworkState {
        let admins = network
            .admins
            .iter()
            .map(|admin| to_npub(admin))
            .collect::<Vec<_>>();
        let mut participant_keys = network.participants.clone();
        participant_keys.extend(network.admins.iter().cloned());
        participant_keys.sort();
        participant_keys.dedup();
        if !own_pubkey_hex.is_empty()
            && !participant_keys.iter().any(|value| value == own_pubkey_hex)
        {
            participant_keys.push(own_pubkey_hex.to_string());
        }
        let participants = participant_keys
            .iter()
            .map(|participant| self.participant_state(participant, network, own_pubkey_hex))
            .collect::<Vec<_>>();
        let online_count = participants
            .iter()
            .filter(|participant| participant.reachable)
            .count() as u64;

        NativeNetworkState {
            id: network.id.clone(),
            name: network.name.clone(),
            enabled: network.enabled,
            network_id: network.network_id.clone(),
            local_is_admin: self.config.is_network_admin(&network.id, own_pubkey_hex),
            join_requests_enabled: network.listen_for_join_requests,
            online_count,
            expected_count: participants.len() as u64,
            admins,
            participants,
        }
    }

    fn participant_state(
        &self,
        participant: &str,
        network: &NetworkConfig,
        own_pubkey_hex: &str,
    ) -> NativeParticipantState {
        let daemon_peer = self.daemon_state.as_ref().and_then(|state| {
            state
                .peers
                .iter()
                .find(|peer| peer.participant_pubkey == participant)
        });
        let is_local = participant == own_pubkey_hex;
        let reachable = is_local || daemon_peer.is_some_and(|peer| peer.reachable);
        let alias = self
            .config
            .peer_alias(participant)
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| short_pubkey(participant));

        NativeParticipantState {
            npub: to_npub(participant),
            pubkey_hex: participant.to_string(),
            alias,
            tunnel_ip: daemon_peer
                .map(|peer| peer.tunnel_ip.clone())
                .unwrap_or_default(),
            is_admin: network.admins.iter().any(|admin| admin == participant),
            reachable,
            status_text: if is_local {
                "local".to_string()
            } else if reachable {
                "online".to_string()
            } else if self.session_active {
                "pending".to_string()
            } else {
                "offline".to_string()
            },
        }
    }

    fn relay_states(&self) -> Vec<NativeRelayState> {
        self.config
            .nostr
            .relays
            .iter()
            .map(|relay| NativeRelayState {
                url: relay.clone(),
                state: if self.session_active && self.relay_connected {
                    "up".to_string()
                } else if self.session_active {
                    "down".to_string()
                } else {
                    "unknown".to_string()
                },
                status_text: if self.session_active && self.relay_connected {
                    "connected".to_string()
                } else if self.session_active {
                    "disconnected".to_string()
                } else {
                    "not checked".to_string()
                },
            })
            .collect()
    }

    fn config_path_str(&self) -> Result<&str> {
        self.config_path
            .to_str()
            .ok_or_else(|| anyhow!("config path is not valid UTF-8"))
    }

    fn run_nvpn<const N: usize>(&self, args: [&str; N]) -> Result<Output> {
        let Some(nvpn_bin) = &self.nvpn_bin else {
            return Err(anyhow!(
                "nvpn CLI binary not found; set {NVPN_BIN_ENV} or install nvpn"
            ));
        };
        Command::new(nvpn_bin)
            .args(args)
            .output()
            .with_context(|| format!("failed to execute {}", nvpn_bin.display()))
    }

    fn run_nvpn_elevated<const N: usize>(&self, args: [&str; N]) -> Result<Output> {
        #[cfg(target_os = "macos")]
        {
            self.run_nvpn_with_macos_admin(args)
        }
        #[cfg(not(target_os = "macos"))]
        {
            self.run_nvpn(args)
        }
    }

    #[cfg(target_os = "macos")]
    fn run_nvpn_with_macos_admin<const N: usize>(&self, args: [&str; N]) -> Result<Output> {
        let Some(nvpn_bin) = &self.nvpn_bin else {
            return Err(anyhow!(
                "nvpn CLI binary not found; set {NVPN_BIN_ENV} or install nvpn"
            ));
        };
        let shell_command = std::iter::once(nvpn_bin.display().to_string())
            .chain(args.iter().map(|arg| shell_quote(arg)))
            .collect::<Vec<_>>()
            .join(" ");
        let script = format!(
            "do shell script {} with administrator privileges",
            applescript_quote(&shell_command)
        );
        Command::new("osascript")
            .arg("-e")
            .arg(script)
            .output()
            .context("failed to request administrator privileges")
    }

    fn set_error(&mut self, error: impl Into<String>) {
        let error = error.into();
        self.last_error.clone_from(&error);
        if !error.trim().is_empty() {
            self.session_status = error;
        }
    }
}

fn native_config_path(data_dir: &str) -> PathBuf {
    let trimmed = data_dir.trim();
    if trimmed.is_empty() {
        default_config_path()
    } else {
        PathBuf::from(trimmed).join("config.toml")
    }
}

fn default_config_path() -> PathBuf {
    dirs::config_dir().map_or_else(
        || PathBuf::from("nvpn.toml"),
        |dir| dir.join("nvpn").join("config.toml"),
    )
}

fn resolve_nvpn_cli_path() -> Result<PathBuf> {
    if let Some(path) = env::var_os(NVPN_BIN_ENV) {
        return validate_nvpn_binary(&PathBuf::from(path));
    }
    if let Ok(exe) = env::current_exe()
        && let Some(dir) = exe.parent()
    {
        for candidate in bundled_nvpn_candidate_paths(dir) {
            if let Ok(validated) = validate_nvpn_binary(&candidate) {
                return Ok(validated);
            }
        }
    }
    if let Some(path_var) = env::var_os("PATH") {
        for dir in env::split_paths(&path_var) {
            if let Ok(validated) = validate_nvpn_binary(&dir.join(nvpn_binary_name())) {
                return Ok(validated);
            }
        }
    }
    Err(anyhow!("nvpn CLI binary not found"))
}

fn bundled_nvpn_candidate_paths(exe_dir: &Path) -> Vec<PathBuf> {
    let name = nvpn_binary_name();
    let mut paths = vec![exe_dir.join(name)];
    paths.push(exe_dir.join("binaries").join(name));
    if let Some(contents_dir) = exe_dir.parent() {
        paths.push(contents_dir.join("Resources").join("binaries").join(name));
        paths.push(contents_dir.join("Resources").join(name));
    }
    paths
}

fn nvpn_binary_name() -> &'static str {
    if cfg!(windows) { "nvpn.exe" } else { "nvpn" }
}

fn validate_nvpn_binary(path: &Path) -> Result<PathBuf> {
    let canonical = fs::canonicalize(path)
        .with_context(|| format!("failed to canonicalize {}", path.display()))?;
    let metadata = fs::metadata(&canonical)
        .with_context(|| format!("failed to inspect {}", canonical.display()))?;
    if !metadata.is_file() {
        return Err(anyhow!("{} is not a file", canonical.display()));
    }
    Ok(canonical)
}

fn ensure_success(command_name: &str, output: &Output) -> Result<()> {
    if output.status.success() {
        Ok(())
    } else {
        Err(command_failure(command_name, output))
    }
}

fn command_failure(command_name: &str, output: &Output) -> anyhow::Error {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    anyhow!(
        "{command_name} failed\nstdout: {}\nstderr: {}",
        stdout.trim(),
        stderr.trim()
    )
}

fn extract_json_document(output: &str) -> Result<&str> {
    let start = output
        .find('{')
        .ok_or_else(|| anyhow!("command output did not contain JSON"))?;
    let end = output
        .rfind('}')
        .ok_or_else(|| anyhow!("command output did not contain complete JSON"))?;
    Ok(&output[start..=end])
}

fn parse_advertised_routes(input: &str) -> Vec<String> {
    let mut routes = input
        .split([',', '\n', ' ', '\t'])
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .filter_map(normalize_advertised_route)
        .collect::<Vec<_>>();
    routes.sort();
    routes.dedup();
    routes
}

fn active_network_invite_code(config: &AppConfig) -> Result<String> {
    let active_network = config.active_network();
    let roster = config.shared_network_roster(&active_network.id)?;
    if roster.admins.is_empty() {
        return Err(anyhow!("active network has no admin configured"));
    }
    let invite = NetworkInvite {
        v: NETWORK_INVITE_VERSION,
        network_name: String::new(),
        network_id: roster.network_id,
        inviter_npub: String::new(),
        inviter_node_name: String::new(),
        admins: roster.admins.iter().map(|admin| to_npub(admin)).collect(),
        participants: Vec::new(),
        relays: normalized_invite_relays(&config.nostr.relays),
    };
    let encoded = URL_SAFE_NO_PAD
        .encode(serde_json::to_vec(&invite).context("failed to encode network invite JSON")?);
    Ok(format!("{NETWORK_INVITE_PREFIX}{encoded}"))
}

fn normalized_invite_relays(relays: &[String]) -> Vec<String> {
    let mut normalized = relays
        .iter()
        .map(|relay| relay.trim().trim_end_matches('/').to_string())
        .filter(|relay| relay.starts_with("ws://") || relay.starts_with("wss://"))
        .collect::<Vec<_>>();
    normalized.sort();
    normalized.dedup();
    normalized
}

fn to_npub(pubkey_hex: &str) -> String {
    PublicKey::parse(pubkey_hex)
        .ok()
        .and_then(|pubkey| pubkey.to_bech32().ok())
        .unwrap_or_else(|| pubkey_hex.to_string())
}

fn short_pubkey(pubkey_hex: &str) -> String {
    if pubkey_hex.len() <= 12 {
        pubkey_hex.to_string()
    } else {
        format!(
            "{}...{}",
            &pubkey_hex[..8],
            &pubkey_hex[pubkey_hex.len() - 4..]
        )
    }
}

fn non_empty(value: &str) -> Option<String> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

#[cfg(target_os = "macos")]
fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

#[cfg(target_os = "macos")]
fn applescript_quote(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn advertised_routes_are_normalized_and_deduplicated() {
        assert_eq!(
            parse_advertised_routes(" 10.0.0.0/8,10.0.0.0/8\n::/0 "),
            vec!["10.0.0.0/8".to_string(), "::/0".to_string()]
        );
    }

    #[test]
    fn default_config_path_matches_desktop_config_location() {
        let path = default_config_path();

        assert!(path.ends_with(Path::new("nvpn").join("config.toml")));
    }

    #[test]
    fn native_state_initializes_from_generated_config() {
        let error = anyhow!("boom");
        let runtime = NativeAppRuntime::from_startup_error(&error);
        let state = runtime.state();

        assert_eq!(state.error, "boom");
        assert!(!state.own_pubkey_hex.is_empty());
    }
}
