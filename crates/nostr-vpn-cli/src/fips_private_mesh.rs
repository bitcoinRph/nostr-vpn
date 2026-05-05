#![allow(dead_code)]

use anyhow::{Context, Result, anyhow};
use fips_endpoint::{
    Config, ConnectPolicy, FipsEndpoint, FipsEndpointError, NostrDiscoveryPolicy,
    PeerConfig as FipsPeerConfig, TransportInstances, UdpConfig,
};
use nostr_vpn_core::config::{AppConfig, derive_mesh_tunnel_ip};
use nostr_vpn_core::data_plane::{MeshPeerStatus, PrivatePacket};
use nostr_vpn_core::fips_mesh::{FipsMeshPeerConfig, FipsMeshRuntime};
use std::sync::{Arc, RwLock};

#[cfg(any(target_os = "linux", target_os = "macos"))]
use boringtun::device::{Error as TunError, tun::TunSocket};
#[cfg(any(target_os = "linux", target_os = "macos"))]
use tokio::sync::mpsc;
#[cfg(any(target_os = "linux", target_os = "macos"))]
use tokio::task::JoinHandle;
#[cfg(any(target_os = "linux", target_os = "macos"))]
use tokio::time::{Duration, sleep};

pub(crate) struct FipsPrivateMeshRuntime {
    endpoint: FipsEndpoint,
    mesh: RwLock<FipsMeshRuntime>,
}

impl FipsPrivateMeshRuntime {
    pub(crate) async fn bind(
        identity_nsec: impl Into<String>,
        network_id: impl AsRef<str>,
        peers: Vec<FipsMeshPeerConfig>,
    ) -> Result<Self> {
        Self::bind_with_relays(identity_nsec, network_id, peers, &[]).await
    }

    pub(crate) async fn bind_with_relays(
        identity_nsec: impl Into<String>,
        network_id: impl AsRef<str>,
        peers: Vec<FipsMeshPeerConfig>,
        relays: &[String],
    ) -> Result<Self> {
        let scope = format!("nostr-vpn:{}", network_id.as_ref().trim());
        let config = fips_endpoint_config(&scope, relays, &peers);
        Self::bind_with_config(identity_nsec, scope, peers, config).await
    }

    async fn bind_with_config(
        identity_nsec: impl Into<String>,
        scope: impl Into<String>,
        peers: Vec<FipsMeshPeerConfig>,
        config: Config,
    ) -> Result<Self> {
        let scope = scope.into();
        let endpoint = FipsEndpoint::builder()
            .config(config)
            .identity_nsec(identity_nsec)
            .discovery_scope(scope)
            .without_system_tun()
            .bind()
            .await
            .context("failed to bind embedded FIPS endpoint")?;

        Ok(Self {
            endpoint,
            mesh: RwLock::new(FipsMeshRuntime::new(peers)),
        })
    }

    pub(crate) fn npub(&self) -> &str {
        self.endpoint.npub()
    }

    pub(crate) async fn send_tunnel_packet(&self, packet: &[u8]) -> Result<bool> {
        let outgoing = {
            self.mesh
                .read()
                .map_err(|_| anyhow!("FIPS mesh route table lock poisoned"))?
                .route_outbound_packet(packet)
        };
        let Some(outgoing) = outgoing else {
            return Ok(false);
        };

        self.endpoint
            .send(outgoing.endpoint_npub, outgoing.bytes)
            .await
            .context("failed to send private packet over FIPS endpoint data")?;
        Ok(true)
    }

    pub(crate) async fn recv_tunnel_packet(&self) -> Result<Option<PrivatePacket>> {
        loop {
            let Some(message) = self.endpoint.recv().await else {
                return Ok(None);
            };

            if let Some(packet) = self
                .mesh
                .read()
                .map_err(|_| anyhow!("FIPS mesh route table lock poisoned"))?
                .receive_endpoint_data(message.source_npub.as_deref(), &message.data)
            {
                return Ok(Some(packet));
            }
        }
    }

    pub(crate) fn peer_statuses(&self) -> Vec<MeshPeerStatus> {
        self.mesh
            .read()
            .map(|mesh| mesh.peer_statuses())
            .unwrap_or_default()
    }

    pub(crate) fn replace_peers(&self, peers: Vec<FipsMeshPeerConfig>) -> Result<()> {
        *self
            .mesh
            .write()
            .map_err(|_| anyhow!("FIPS mesh route table lock poisoned"))? =
            FipsMeshRuntime::new(peers);
        Ok(())
    }

    pub(crate) async fn shutdown(self) -> Result<(), FipsEndpointError> {
        self.endpoint.shutdown().await
    }
}

fn fips_endpoint_config(scope: &str, relays: &[String], peers: &[FipsMeshPeerConfig]) -> Config {
    let mut config = Config::new();
    config.node.discovery.nostr.enabled = !relays.is_empty();
    config.node.discovery.nostr.advertise = false;
    config.node.discovery.nostr.policy = NostrDiscoveryPolicy::ConfiguredOnly;
    config.node.discovery.nostr.app = scope.to_string();
    if !relays.is_empty() {
        config.node.discovery.nostr.advert_relays = relays.to_vec();
        config.node.discovery.nostr.dm_relays = relays.to_vec();
    }
    config.transports.udp = TransportInstances::Single(UdpConfig {
        bind_addr: None,
        advertise_on_nostr: Some(false),
        public: Some(false),
        outbound_only: Some(true),
        accept_connections: Some(false),
        ..UdpConfig::default()
    });
    if !relays.is_empty() {
        config.peers = peers
            .iter()
            .map(|peer| FipsPeerConfig {
                npub: peer.endpoint_npub.clone(),
                alias: Some(peer.participant_pubkey.clone()),
                addresses: Vec::new(),
                connect_policy: ConnectPolicy::AutoConnect,
                auto_reconnect: true,
                via_nostr: true,
            })
            .collect();
    }
    config
}

#[derive(Debug, Clone)]
pub(crate) struct FipsPrivateTunnelConfig {
    pub(crate) identity_nsec: String,
    pub(crate) network_id: String,
    pub(crate) relays: Vec<String>,
    pub(crate) iface: String,
    pub(crate) local_address: String,
    pub(crate) peers: Vec<FipsMeshPeerConfig>,
    pub(crate) route_targets: Vec<String>,
}

impl FipsPrivateTunnelConfig {
    pub(crate) fn from_app(
        app: &AppConfig,
        network_id: &str,
        iface: impl Into<String>,
        relays: &[String],
        own_pubkey: Option<&str>,
    ) -> Result<Self> {
        let mut peers = Vec::new();
        let mut route_targets = Vec::new();
        for participant in app
            .participant_pubkeys_hex()
            .into_iter()
            .filter(|participant| Some(participant.as_str()) != own_pubkey)
        {
            let Some(tunnel_ip) = derive_mesh_tunnel_ip(network_id, &participant) else {
                continue;
            };
            let allowed_ip = format!("{}/32", strip_cidr(&tunnel_ip));
            route_targets.push(allowed_ip.clone());
            peers.push(FipsMeshPeerConfig::from_participant_pubkey(
                participant,
                vec![allowed_ip],
            )?);
        }
        route_targets.sort();
        route_targets.dedup();

        Ok(Self {
            identity_nsec: app.nostr.secret_key.clone(),
            network_id: network_id.to_string(),
            relays: relays.to_vec(),
            iface: iface.into(),
            local_address: local_interface_address_for_tunnel(&app.node.tunnel_ip),
            peers,
            route_targets,
        })
    }
}

fn local_interface_address_for_tunnel(tunnel_ip: &str) -> String {
    let tunnel_ip = tunnel_ip.trim();
    if tunnel_ip.is_empty() {
        return "10.44.0.1/32".to_string();
    }
    if tunnel_ip.contains('/') {
        return tunnel_ip.to_string();
    }
    format!("{}/32", strip_cidr(tunnel_ip))
}

fn strip_cidr(value: &str) -> &str {
    value.split('/').next().unwrap_or(value)
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
pub(crate) struct FipsPrivateTunnelRuntime {
    iface: String,
    mesh: Arc<FipsPrivateMeshRuntime>,
    tun_read_task: JoinHandle<()>,
    mesh_send_task: JoinHandle<()>,
    mesh_recv_task: JoinHandle<()>,
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
impl FipsPrivateTunnelRuntime {
    pub(crate) async fn start(config: FipsPrivateTunnelConfig) -> Result<Self> {
        let mesh = Arc::new(
            FipsPrivateMeshRuntime::bind_with_relays(
                config.identity_nsec,
                &config.network_id,
                config.peers,
                &config.relays,
            )
            .await?,
        );
        let tun = Arc::new(
            TunSocket::new(&config.iface)
                .with_context(|| format!("failed to create FIPS tunnel {}", config.iface))?
                .set_non_blocking()
                .context("failed to set FIPS tunnel nonblocking")?,
        );
        let iface = tun.name().context("failed to read FIPS tunnel name")?;
        crate::apply_local_interface_network(&iface, &config.local_address, &config.route_targets)
            .with_context(|| format!("failed to configure FIPS tunnel interface {iface}"))?;

        let (packet_tx, mut packet_rx) = mpsc::channel::<Vec<u8>>(1024);
        let tun_read_task = spawn_tun_read_task(Arc::clone(&tun), packet_tx);
        let mesh_send_task = {
            let mesh = Arc::clone(&mesh);
            tokio::spawn(async move {
                while let Some(packet) = packet_rx.recv().await {
                    if let Err(error) = mesh.send_tunnel_packet(&packet).await {
                        eprintln!("fips: failed to send tunnel packet: {error}");
                    }
                }
            })
        };
        let mesh_recv_task = spawn_mesh_recv_task(Arc::clone(&mesh), tun);

        Ok(Self {
            iface,
            mesh,
            tun_read_task,
            mesh_send_task,
            mesh_recv_task,
        })
    }

    pub(crate) fn iface(&self) -> &str {
        &self.iface
    }

    pub(crate) fn peer_statuses(&self) -> Vec<MeshPeerStatus> {
        self.mesh.peer_statuses()
    }

    pub(crate) async fn stop(self) -> Result<()> {
        self.tun_read_task.abort();
        self.mesh_send_task.abort();
        self.mesh_recv_task.abort();
        let _ = self.tun_read_task.await;
        let _ = self.mesh_send_task.await;
        let _ = self.mesh_recv_task.await;
        if let Ok(mesh) = Arc::try_unwrap(self.mesh) {
            mesh.shutdown()
                .await
                .context("failed to stop FIPS endpoint")?;
        }
        Ok(())
    }
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn spawn_tun_read_task(tun: Arc<TunSocket>, packet_tx: mpsc::Sender<Vec<u8>>) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut buf = vec![0_u8; 65_535];
        loop {
            match tun.read(&mut buf) {
                Ok(packet) if packet.is_empty() => {
                    sleep(Duration::from_millis(10)).await;
                }
                Ok(packet) => {
                    if packet_tx.send(packet.to_vec()).await.is_err() {
                        break;
                    }
                }
                Err(error) if temporary_tun_read_error(&error) => {
                    sleep(Duration::from_millis(10)).await;
                }
                Err(error) => {
                    eprintln!("fips: tunnel read failed: {error}");
                    sleep(Duration::from_millis(100)).await;
                }
            }
        }
    })
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn spawn_mesh_recv_task(mesh: Arc<FipsPrivateMeshRuntime>, tun: Arc<TunSocket>) -> JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            match mesh.recv_tunnel_packet().await {
                Ok(Some(packet)) => write_packet_to_tun(&tun, &packet.bytes),
                Ok(None) => break,
                Err(error) => {
                    eprintln!("fips: failed to receive tunnel packet: {error}");
                    sleep(Duration::from_millis(100)).await;
                }
            }
        }
    })
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn write_packet_to_tun(tun: &TunSocket, packet: &[u8]) {
    match packet.first().map(|byte| byte >> 4) {
        Some(4) => {
            let _ = tun.write4(packet);
        }
        Some(6) => {
            let _ = tun.write6(packet);
        }
        _ => {}
    }
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn temporary_tun_read_error(error: &TunError) -> bool {
    match error {
        TunError::IfaceRead(source) => matches!(
            source.kind(),
            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted
        ),
        _ => false,
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub(crate) struct FipsPrivateTunnelRuntime;

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
impl FipsPrivateTunnelRuntime {
    pub(crate) async fn start(_config: FipsPrivateTunnelConfig) -> Result<Self> {
        Err(anyhow!(
            "FIPS private tunnel runtime is not implemented for this platform"
        ))
    }

    pub(crate) fn iface(&self) -> &str {
        ""
    }

    pub(crate) fn peer_statuses(&self) -> Vec<MeshPeerStatus> {
        Vec::new()
    }

    pub(crate) async fn stop(self) -> Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{FipsPrivateMeshRuntime, fips_endpoint_config};
    use fips_endpoint::{Config, PeerConfig as FipsPeerConfig, TransportInstances, UdpConfig};
    use nostr_sdk::prelude::{Keys, ToBech32};
    use nostr_vpn_core::fips_mesh::FipsMeshPeerConfig;
    use std::net::{Ipv4Addr, UdpSocket};
    use std::time::Duration;

    fn ipv4_packet(source: Ipv4Addr, destination: Ipv4Addr) -> Vec<u8> {
        let payload = [0xde, 0xad, 0xbe, 0xef];
        let total_len = 20 + payload.len();
        let mut packet = vec![0_u8; total_len];
        packet[0] = 0x45;
        packet[2..4].copy_from_slice(&(total_len as u16).to_be_bytes());
        packet[8] = 64;
        packet[9] = 17;
        packet[12..16].copy_from_slice(&source.octets());
        packet[16..20].copy_from_slice(&destination.octets());
        packet[20..].copy_from_slice(&payload);
        packet
    }

    #[tokio::test]
    async fn endpoint_data_runtime_sends_and_receives_raw_packets() {
        let keys = Keys::generate();
        let nsec = keys.secret_key().to_bech32().expect("nsec");
        let participant_pubkey = keys.public_key().to_hex();
        let source = Ipv4Addr::new(10, 44, 10, 1);
        let destination = Ipv4Addr::new(10, 44, 22, 44);

        // The FIPS endpoint self-loop is used only to exercise send/recv
        // without external discovery. Real peers should not own both routes.
        let peer = FipsMeshPeerConfig::from_participant_pubkey(
            &participant_pubkey,
            vec![format!("{source}/32"), format!("{destination}/32")],
        )
        .expect("peer config");
        let runtime = FipsPrivateMeshRuntime::bind(nsec, "test-network", vec![peer])
            .await
            .expect("runtime should bind");
        let packet = ipv4_packet(source, destination);

        let sent = runtime
            .send_tunnel_packet(&packet)
            .await
            .expect("send packet");
        assert!(sent);

        let received = tokio::time::timeout(Duration::from_secs(2), runtime.recv_tunnel_packet())
            .await
            .expect("packet should arrive")
            .expect("receive packet")
            .expect("packet should pass admission");

        assert_eq!(received.source_pubkey, participant_pubkey);
        assert_eq!(received.bytes, packet);
        runtime.shutdown().await.expect("shutdown");
    }

    fn available_udp_port() -> u16 {
        UdpSocket::bind("127.0.0.1:0")
            .expect("bind test port")
            .local_addr()
            .expect("local addr")
            .port()
    }

    fn direct_udp_endpoint_config(local_port: u16, peer_npub: &str, peer_port: u16) -> Config {
        let mut config = Config::new();
        config.transports.udp = TransportInstances::Single(UdpConfig {
            bind_addr: Some(format!("127.0.0.1:{local_port}")),
            accept_connections: Some(true),
            ..UdpConfig::default()
        });
        config.peers.push(FipsPeerConfig::new(
            peer_npub,
            "udp",
            format!("127.0.0.1:{peer_port}"),
        ));
        config
    }

    async fn send_with_retry(runtime: &FipsPrivateMeshRuntime, packet: &[u8]) {
        let mut last_error = None;
        for _ in 0..50 {
            match runtime.send_tunnel_packet(packet).await {
                Ok(true) => return,
                Ok(false) => panic!("packet had no FIPS route"),
                Err(error) => {
                    last_error = Some(error);
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
            }
        }
        panic!(
            "packet did not send after retry: {}",
            last_error
                .map(|error| error.to_string())
                .unwrap_or_else(|| "unknown error".to_string())
        );
    }

    #[tokio::test]
    async fn two_local_endpoints_exchange_raw_packets_over_fips() {
        let alice_keys = Keys::generate();
        let bob_keys = Keys::generate();
        let alice_nsec = alice_keys.secret_key().to_bech32().expect("alice nsec");
        let bob_nsec = bob_keys.secret_key().to_bech32().expect("bob nsec");
        let alice_pubkey = alice_keys.public_key().to_hex();
        let bob_pubkey = bob_keys.public_key().to_hex();
        let alice_npub = alice_keys.public_key().to_bech32().expect("alice npub");
        let bob_npub = bob_keys.public_key().to_bech32().expect("bob npub");
        let alice_port = available_udp_port();
        let bob_port = available_udp_port();
        let alice_ip = Ipv4Addr::new(10, 44, 11, 1);
        let bob_ip = Ipv4Addr::new(10, 44, 11, 2);
        let scope = "nostr-vpn:two-local-endpoints";

        let alice_runtime = FipsPrivateMeshRuntime::bind_with_config(
            alice_nsec,
            scope,
            vec![FipsMeshPeerConfig {
                participant_pubkey: bob_pubkey.clone(),
                endpoint_npub: bob_npub.clone(),
                allowed_ips: vec![format!("{bob_ip}/32")],
            }],
            direct_udp_endpoint_config(alice_port, &bob_npub, bob_port),
        )
        .await
        .expect("alice endpoint should bind");
        let bob_runtime = FipsPrivateMeshRuntime::bind_with_config(
            bob_nsec,
            scope,
            vec![FipsMeshPeerConfig {
                participant_pubkey: alice_pubkey.clone(),
                endpoint_npub: alice_npub.clone(),
                allowed_ips: vec![format!("{alice_ip}/32")],
            }],
            direct_udp_endpoint_config(bob_port, &alice_npub, alice_port),
        )
        .await
        .expect("bob endpoint should bind");

        let alice_to_bob = ipv4_packet(alice_ip, bob_ip);
        send_with_retry(&alice_runtime, &alice_to_bob).await;
        let received =
            tokio::time::timeout(Duration::from_secs(5), bob_runtime.recv_tunnel_packet())
                .await
                .expect("Bob should receive Alice packet")
                .expect("receive packet")
                .expect("packet should pass Bob admission");
        assert_eq!(received.source_pubkey, alice_pubkey);
        assert_eq!(received.bytes, alice_to_bob);

        let bob_to_alice = ipv4_packet(bob_ip, alice_ip);
        send_with_retry(&bob_runtime, &bob_to_alice).await;
        let received =
            tokio::time::timeout(Duration::from_secs(5), alice_runtime.recv_tunnel_packet())
                .await
                .expect("Alice should receive Bob packet")
                .expect("receive packet")
                .expect("packet should pass Alice admission");
        assert_eq!(received.source_pubkey, bob_pubkey);
        assert_eq!(received.bytes, bob_to_alice);

        alice_runtime.shutdown().await.expect("shutdown alice");
        bob_runtime.shutdown().await.expect("shutdown bob");
    }

    #[test]
    fn endpoint_config_uses_client_posture_and_configured_peers_only() {
        let keys = Keys::generate();
        let participant_pubkey = keys.public_key().to_hex();
        let peer = FipsMeshPeerConfig::from_participant_pubkey(
            &participant_pubkey,
            vec!["10.44.1.2/32".to_string()],
        )
        .expect("peer config");
        let relays = vec!["wss://relay.example".to_string()];

        let config = fips_endpoint_config("nostr-vpn:test", &relays, &[peer]);

        assert!(config.node.discovery.nostr.enabled);
        assert!(!config.node.discovery.nostr.advertise);
        assert_eq!(
            config.node.discovery.nostr.policy,
            fips_endpoint::NostrDiscoveryPolicy::ConfiguredOnly
        );
        assert_eq!(config.node.discovery.nostr.app, "nostr-vpn:test");
        let udp = match config.transports.udp {
            fips_endpoint::TransportInstances::Single(udp) => udp,
            _ => panic!("expected one UDP transport"),
        };
        assert!(udp.outbound_only());
        assert!(!udp.advertise_on_nostr());
        assert!(!udp.accept_connections());
        assert_eq!(config.peers.len(), 1);
        assert!(config.peers[0].via_nostr);
    }
}
