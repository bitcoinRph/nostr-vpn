# Native UI Parity Matrix

This is the working checklist for replacing the current Svelte/Tauri app with
a Rust-core, native-front architecture similar to `~/src/iris-chat-rs`.

The goal is not visual sameness. The goal is feature and behavior parity across
native shells while keeping product truth in Rust.

## Target Shape

| Layer | macOS | Windows | Linux | Android | iPhone |
| --- | --- | --- | --- | --- | --- |
| Shared core | Rust app core exposed through UniFFI | Rust app core exposed through UniFFI | Rust app core used directly or through UniFFI | Rust app core exposed through UniFFI | Rust app core exposed through UniFFI |
| Native shell | SwiftUI/AppKit | WPF/.NET | GTK4/libadwaita Rust | Kotlin/Jetpack Compose | SwiftUI/UIKit |
| App state owner | Rust | Rust | Rust | Rust | Rust |
| Rendering owner | Native | Native | Native | Native | Native |
| Secure/platform effects | Keychain, launch agent, status item | Credential Manager, service/UAC, tray | Secret Service fallback, desktop entry, tray/status notifier | Keystore, VpnService, camera/share intents | Keychain, NetworkExtension, camera/share sheet |
| VPN control model | Background service + userspace WireGuard | Windows service + Wintun/userspace WireGuard | Background service + tun/userspace WireGuard | Android VpnService runtime | NetworkExtension Packet Tunnel |
| Package target | `.app`/DMG or signed archive | Installer/MSIX or NSIS | AppImage/deb/rpm later | APK/AAB/Zapstore | TestFlight/App Store |

## Rust Core Boundary

| Area | Core responsibility | Native responsibility |
| --- | --- | --- |
| State projection | `UiState`, networks, participants, relays, diagnostics, service status, mobile capability flags | Render state with platform controls and local presentation state |
| Actions | All existing Tauri commands as typed Rust actions | Dispatch actions, disable conflicting controls while actions run |
| Long-running runtime | Daemon/session lifecycle, config persistence, relay status, peer status, LAN pairing, join requests | Keep app alive enough for platform lifecycle and show system-level affordances |
| Formatting | Shared user-facing derived labels that encode policy, like mesh readiness, join request status, exit-node availability, service repair recommendation | Platform typography, layout, control affordances |
| Platform effects | Declare requested effect and update state after completion | Clipboard, startup registration, tray/status item, camera QR scan, update installer, mobile VPN permission prompts |
| Errors | Stable action errors and recoverable service repair hints | Dialog/toast/sheet presentation |

## Feature Parity Matrix

Legend:

- `Required`: must ship on that platform.
- `Desktop`: desktop-only parity.
- `Mobile`: mobile-only equivalent.
- `Hidden`: code exists today but is not mounted in the current app.
- `N/A`: intentionally not applicable.

| Current feature | Current source | Core/API need | macOS | Windows | Linux | Android | iPhone | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| One snapshot app model | `UiState`, `get_state`, `tick` | `FfiApp.state()`, periodic or push updates, typed actions | Required | Required | Required | Required | Required | Keep a single state/action contract for all shells. |
| Initial boot sequencing | `AppBootstrap.svelte` | Start core, load config, first tick, ready event for tests | Required | Required | Required | Required | Required | Native tests need a replacement for `nvpn:boot-ready`. |
| Periodic refresh | `tick` every 1500ms | Prefer push updates; retain tick as fallback | Required | Required | Required | Required | Required | Mobile should avoid aggressive background polling. |
| Action lock/error recovery | `runAction`, action flags | Action in-flight state or shell-side lock | Required | Required | Required | Required | Required | Prevent overlapping config/session mutations. |
| Main status hero | `HeroStatusPanel.svelte` | Hero badge/subtext/detail helpers, active network projection | Required | Required | Required | Required | Required | Includes active network title, admin badge, mesh readiness, daemon/VPN/FIPS badges. |
| VPN on/off switch | `connect_session`, `disconnect_session` | Start/stop session action, service setup guidance | Required | Required | Required | Mobile | Mobile | Mobile uses platform VPN permission/control flow instead of desktop service. |
| Privacy disclosure | `shouldShowVpnDataDisclosure` | Capability/state flag and disclosure text | Required | Required | Required | Required | Required | Current copy should become a shared string or policy doc reference. |
| Own npub display/copy | `HeroStatusPanel.svelte` | `own_npub` in state | Required | Required | Required | Required | Required | Clipboard is native platform effect. |
| Device name editing | `update_settings.nodeName` | Typed settings patch | Required | Required | Required | Required | Required | Debounced edit, DNS-safe preview. |
| Device endpoint/tunnel summary | `UiState.endpoint`, `tunnelIp` | State fields | Required | Required | Required | Required | Required | Mobile may show platform-managed tunnel info. |
| Active network profile | `ActiveNetworkPanel.svelte` | Network name, mesh ID, local admin flag | Required | Required | Required | Required | Required | Non-admins must not edit shared network identity. |
| Mesh ID editing/validation | `mesh-id.js`, `set_network_mesh_id` | Move validation/canonicalization into Rust | Required | Required | Required | Required | Required | Current 5s idle commit plus blur/Enter commit should be preserved. |
| Mesh ID copy | `copyMeshId` | Current active network ID | Required | Required | Required | Required | Required | Copy raw canonical ID, not display grouping. |
| Network admin visibility | `networkAdminSummary`, badges | Admin summary and participant admin flags | Required | Required | Required | Required | Required | Keep admin-specific disabled states. |
| Join request listener toggle | `set_network_join_requests_enabled` | Per-network listener setting | Required | Required | Required | Required | Required | Works for active and saved networks. |
| Inbound join request list | `inboundJoinRequests` | Pending request state and accept action | Required | Required | Required | Required | Required | Accept action must remain admin-gated. |
| Outbound join request status | `outboundJoinRequest` | Request state and requested-at text | Required | Required | Required | Required | Required | Includes imported-from inviter and connected state. |
| Request join action | `request_network_join` | Action by network ID | Required | Required | Required | Required | Required | Deep links can also trigger this in test/debug flows. |
| Accept join action | `accept_join_request` | Action by network ID + requester npub | Required | Required | Required | Required | Required | Must persist acceptance even if session start fails. |
| Invite generation | `activeNetworkInvite` | Core-generated invite string | Required | Required | Required | Required | Required | Include mesh ID, inviter npub, admins, participants, relays. |
| Invite copy | `copyInvite` | Invite string in state | Required | Required | Required | Required | Required | Native share sheet can supplement copy on mobile. |
| Invite QR generation | `qrcode` in `InviteShareSection` | Prefer core QR bitmap/SVG helper or native QR library | Required | Required | Required | Required | Required | Must match current invite payload exactly. |
| Invite paste/import | `import_network_invite` | Action with parsed invite result | Required | Required | Required | Required | Required | Current auto-import after 250ms should be reconsidered for native UX but behavior must be covered. |
| Invite QR live scan | `jsQR`, `getUserMedia` | Native camera scanner effect, core import action | Required | Required | Required | Required | Required | Desktop platforms can use webcam when available. |
| Invite QR image scan | file input + `jsQR` | Native file/image picker + decoder | Required | Required | Required | Required | Required | Keep image fallback when camera is denied/unavailable. |
| Invite import confirmation | `window.confirm` with target mode | Core should expose parsed invite + import target | Required | Required | Required | Required | Required | Native alert/sheet; Cancel fills field instead of importing. |
| Auto-connect after invite import | `ensureSessionActiveAfterInviteImport` | Import action result plus session capability state | Required | Required | Required | Required | Required | On mobile this may require VPN permission prompt. |
| Manual add participant | `add_participant` | Add participant with optional alias | Required | Required | Required | Required | Required | Admin-gated. |
| Participant alias editing | `set_participant_alias` | Alias action and MagicDNS suffix | Required | Required | Required | Required | Required | Debounced, admin-gated. |
| Participant npub copy | participant rows | Participant npub in state | Required | Required | Required | Required | Required | Present in active, saved, join request, LAN peer rows. |
| Participant admin toggle | `add_admin`, `remove_admin` | Admin mutation actions | Required | Required | Required | Required | Required | Active network currently exposes toggle; saved network mainly shows admin state. |
| Participant remove | `remove_participant` | Remove participant action | Required | Required | Required | Required | Required | Admin-gated, icon button on native shells. |
| Participant status badges | `participantBadgeClass`, badge text helpers | Shared derived labels | Required | Required | Required | Required | Required | FIPS reachable/pending/offline plus mesh seen/unseen. |
| Participant traffic/path details | `participantTrafficText`, fields | tx/rx, relay path, runtime endpoint, routes | Required | Required | Required | Required | Required | Keep fallback and advertised route visibility. |
| LAN pairing start/stop | `start_lan_pairing`, `stop_lan_pairing` | Core-owned multicast pairing runtime | Required | Required | Required | Required | Required | Mobile multicast may need platform permissions/capabilities. |
| LAN pairing countdown | local deadline from state | `lanPairingActive`, remaining seconds | Required | Required | Required | Required | Required | UI ticks once per second without forcing backend refresh. |
| Nearby LAN peer list | `lanPeers` | Core pairing snapshot | Required | Required | Required | Required | Required | Filter peers already in current network. |
| Join LAN peer | `onJoinLanPeer` | Import invite action | Required | Required | Required | Required | Required | Same auto-connect behavior as invite import. |
| Saved networks list | `SavedNetworksPanel.svelte` | All networks with enabled flag | Required | Required | Required | Required | Required | Active network separate; inactive networks collapsible/listed. |
| Add saved network | `add_network` | Add network action | Required | Required | Required | Required | Required | Optional name. |
| Activate saved network | `set_network_enabled` | Set active network action | Required | Required | Required | Required | Required | Ensure daemon reload/session state is correct. |
| Delete saved network | `remove_network` | Remove network action | Required | Required | Required | Required | Required | Current button is disabled when only one inactive network remains; revisit rule in core. |
| Edit saved network profile | `SavedNetworkCard.svelte` | Same name/mesh/admin actions as active network | Required | Required | Required | Required | Required | Inactive networks still receive join requests. |
| Saved network participants | `SavedNetworkParticipantRow.svelte` | Participant list and alias actions | Required | Required | Required | Required | Required | Minimal status for inactive profiles. |
| Routing mode summary | `RoutingPanel.svelte` | Derived routing status text | Required | Required | Required | Required | Required | Direct mesh, remote exit, local exit, or both. |
| Advertise private exit node | `advertiseExitNode` | Settings patch | Required | Required | Required | Required | Required | Affects default route advertisement. |
| Advertised routes editing | `advertisedRoutes` | Settings patch + validation | Required | Required | Required | Required | Required | Debounced comma-separated input today; core should validate CIDRs. |
| Exit node search/select | `exitNode` | Candidate projection and setting | Required | Required | Required | Required | Required | Search alias, npub, tunnel IP. Disable peers not offering exit. |
| No exit node selection | `onSelectExitNode('')` | Clear exit-node setting | Required | Required | Required | Required | Required | Also exposed in desktop tray. |
| Diagnostics panel | `AdvancedPanels.svelte` | Health issues, network summary, port mapping | Required | Required | Required | Required | Required | Auto-open when health count increases. |
| Health warnings | `health` | Health issue list with severity | Required | Required | Required | Required | Required | Keep empty state and severity mapping. |
| Network diagnostics | `NetworkSummary` | Interface, local IPs, gateway, captive portal | Required | Required | Required | Required | Required | Mobile may have reduced details if OS restricts APIs. |
| Port mapping status | `PortMappingStatus` | UPnP/NAT-PMP/PCP state | Required | Required | Required | Required | Required | Show active protocol and external endpoint. |
| FIPS relay list | `relays`, `add_relay`, `remove_relay` | Relay config + status | Required | Required | Required | Required | Required | At least one relay required. |
| Relay state badges | `RelayView` | Up/down/checking/unknown status | Required | Required | Required | Required | Required | Keep status text. |
| Session options | `autoconnect` | Settings patch | Required | Required | Required | Required | Required | Text should be platform neutral. |
| Background service panel | `ServiceActionPanel.svelte` | Service status, service repair recommendation, actions | Desktop | Desktop | Desktop | N/A | N/A | Mobile should not show desktop service install/repair UI. |
| Install/reinstall service | `install_system_service` | Desktop service action | Required | Required | Required | N/A | N/A | May require admin/UAC/sudo/polkit flow. |
| Enable/disable service | `enable_system_service`, `disable_system_service` | Desktop service action | Required | Required | Required | N/A | N/A | Current macOS copy references launchd; native copy should use platform-specific terms. |
| Uninstall service | `uninstall_system_service` | Desktop service action | Required | Required | Required | N/A | N/A | Keep reachable after setup. |
| Service version repair prompt | `service-repair.js` | Core-derived repair prompt state | Required | Required | Required | N/A | N/A | Use native confirmation dialog; avoid repeated prompt per version key. |
| Service action settlement polling | `waitForServiceActionSettlement` | Core/service action status | Required | Required | Required | N/A | N/A | Native shell should show progress while launchd/service manager settles. |
| CLI install/uninstall | `install_cli`, `uninstall_cli` | Desktop CLI action | Required | Required | Required | N/A | N/A | Installs `nvpn` into PATH; may require elevation. |
| App version/config path display | `SystemPanel.svelte` | App version, config path | Required | Required | Required | Required | Required | Mobile may hide raw path behind support/debug view. |
| MagicDNS status | `magicDnsStatus` | Runtime DNS status string | Required | Required | Required | Required | Required | Mobile DNS behavior may be tunnel-scoped. |
| MagicDNS suffix editing | `magicDnsSuffix` | Settings patch | Required | Required | Required | Required | Required | Debounced. |
| Endpoint/tunnel IP/listen port settings | `SystemPanel.svelte` | Settings patch + validation | Required | Required | Required | Required | Required | Mobile may constrain endpoint/listen port by OS VPN APIs. |
| Launch on startup | Tauri autostart plugin | Native startup registration effect + config setting | Required | Required | Required | N/A | N/A | Android/iPhone use OS background/VPN behavior, not login startup. |
| Close to tray/status item | `closeToTrayOnClose` | Config setting + native close behavior | Required | Required | Required | N/A | N/A | macOS menu bar item; Windows/Linux tray/status notifier. |
| Desktop tray/status menu | `tray_runtime.rs` | Tray runtime projection and actions | Required | Required | Required | N/A | N/A | Menu: VPN status, toggle, this-device copy, network devices, exit nodes, settings, quit. |
| Tray left-click opens app | Tauri tray handler | Native shell action | Required | Required | Required | N/A | N/A | Keep menu/status item accessible. |
| Autostart hidden launch | `--autostart`, hide to tray | Launch-mode detection | Required | Required | Required | N/A | N/A | Current code mainly handles macOS conflict/defer behavior; port intentionally. |
| Single-instance handling | `tauri-plugin-single-instance`, `gui_launch.rs` | Native process/singleton coordination | Required | Required | Required | Mobile | Mobile | Mobile OS already single-instances app task but deep links must route to existing app. |
| Deep links | `nvpn://invite`, `nvpn://debug/...` | Core deep-link parser/action dispatcher | Required | Required | Required | Required | Required | Support startup URLs and already-running app URLs. |
| Debug automation deep links | `nvpn://debug/tick`, request/accept join | Test-only action path | Required | Required | Required | Required | Required | Keep for e2e harness parity. |
| Update banner | `UpdateBanner.svelte`, hashtree updater | Update check/download/install API | Required | Required | Required | N/A | N/A | Mobile updates go through store/TestFlight/Zapstore unless a separate allowed updater exists. |
| Manual update panel | `SystemPanel.svelte` updater section | Same updater API + prefs | Required | Required | Required | N/A | N/A | Preserve auto-check/auto-install prefs on desktop. |
| Update prefs storage | `localStorage` | Native preference storage | Required | Required | Required | N/A | N/A | Move prefs into core or native settings store. |
| Window chrome/drag region | `App.svelte`, Tauri overlay titlebar | Native window style | Required | Required | Required | N/A | N/A | Native shells can use platform chrome instead of custom overlay. |
| Responsive layout | Svelte CSS | Native adaptive layouts | Required | Required | Required | Required | Required | Desktop can use multi-panel; mobile should use navigation stack/sheets. |
| Copy feedback | `copiedValue` timeout | Native transient status | Required | Required | Required | Required | Required | Snackbar/toast/checkmark, clears after roughly 2s. |
| Collapsible panels | `<details>` panels | Local UI state only | Required | Required | Required | Required | Required | Diagnostics auto-opens on new health issues. |
| Mock/demo backend | `mock-backend.ts` | Native previews/test fixtures | Required | Required | Required | Required | Required | Replace with core fixture snapshots and platform preview states. |
| Mobile VPN permission/control | `android_vpn`, `ios_vpn`, `ios_packet_tunnel` | Platform-specific native VPN bridge | N/A | N/A | N/A | Required | Required | Must preserve current Android VpnService and iPhone Packet Tunnel behavior. |
| Mobile runtime status detail | `runtime_capabilities_for_platform` | Capability flags in state | N/A | N/A | N/A | Required | Required | Keep simulator/device distinction for iPhone. |

## macOS App Parity Status

This table tracks the current SwiftUI/AppKit shell under `macos/` against the
current Svelte/Tauri app. It is scoped to macOS only.

Status legend:

- `Ready`: implemented in the native macOS shell and build-verified.
- `Partial`: visible or wired, but missing behavior from the current app.
- `Missing`: no macOS native implementation yet.
- `Removed`: removed from current product behavior; no native parity work.

| Feature group | Current Tauri source | macOS status | Native macOS coverage | Remaining parity work |
| --- | --- | --- | --- | --- |
| Typed Rust core boundary | `nostr-vpn-app-core`, Tauri commands | Ready | `FfiApp.state()`, `refresh()`, and typed `NativeAppAction` dispatch are used directly from Swift through UniFFI. | Keep action/state additions typed; avoid reintroducing JSON bridge helpers. |
| Initial state load | `get_state`, `AppBootstrap.svelte` | Partial | `AppManager` constructs `FfiApp` and reads initial state synchronously. | Add boot-ready automation event equivalent and startup deep-link drain. |
| Periodic refresh | `tick` interval | Ready | `AppManager.start()` refreshes every 1500ms. | Later replace polling with a core update stream if added. |
| Action lock/error recovery | `runAction`, action flags | Partial | Errors from `FfiApp.dispatch` are projected into `state.error` and rendered. | Add shell-side action-in-flight locking/progress so connect/settings/import actions cannot overlap. |
| Main status hero | `HeroStatusPanel.svelte` | Partial | Shows connected/disconnected, session status, mesh/peer/relay/tunnel metrics, and connect button. | Add active network title/admin badge, daemon/VPN/FIPS badges, privacy disclosure, and shared hero subtext/detail parity. |
| VPN connect/disconnect | `connect_session`, `disconnect_session` | Ready | Connect/disconnect dispatches typed native actions; Rust runs elevated `nvpn` on macOS. | Add service setup guidance before first connect. |
| Privacy disclosure | `shouldShowVpnDataDisclosure` | Missing | None. | Add native disclosure using shared policy text/state. |
| Own npub display/copy | `HeroStatusPanel.svelte` | Missing | `NativeAppState` exposes `ownNpub`, but UI does not render it. | Add compact identity row and copy feedback. |
| Active network summary | `ActiveNetworkPanel.svelte` | Partial | Shows name, mesh ID, local admin state, invite code, and mesh ID copy. | Add name edit, mesh ID edit/validation, admin summary, join request toggle/list, and non-admin disabled states. |
| Mesh ID editing | `mesh-id.js`, `set_network_mesh_id` | Missing | Mesh ID is read-only in SwiftUI. | Move validation/canonicalization into Rust and add idle/blur/Enter commit behavior. |
| Invite generation/copy | `InviteShareSection.svelte` | Partial | Invite string comes from Rust and can be copied. | Add copy feedback, share sheet, QR render, and QR/paste import panel. |
| Invite deep-link import | `nvpn://invite/...` handler | Partial | `WindowGroup.onOpenURL` imports invite URLs while app is running. | Handle startup URLs, add parsed confirmation, cancel-to-fill behavior, and auto-connect after import. |
| Invite paste/import | `InviteImportPanel.svelte` | Missing | None. | Add paste field, import target confirmation, error states, and session auto-start behavior. |
| Invite QR generation | `qrcode` | Missing | None. | Add native or Rust-generated QR that exactly encodes `activeNetworkInvite`. |
| Invite QR scan | `jsQR`, camera/image input | Missing | None. | Add AVFoundation live scan and image picker decode path. |
| Participant list | `ActiveNetworkPanel.svelte` | Partial | Shows participants, reachability icon, status text, npub, and npub copy. | Add status badge parity, traffic/path details, admin toggles, alias editing, and remove action. |
| Manual add participant | `add_participant` | Ready | Admin can type an npub and dispatch add-participant action. | Add optional alias field and admin gating in UI. |
| Participant alias editing | `set_participant_alias` | Missing | Rust action exists; UI does not expose it. | Add debounced alias edit and MagicDNS name display. |
| Participant admin/remove actions | `add_admin`, `remove_admin`, `remove_participant` | Missing | Rust actions exist; UI does not expose them. | Add admin toggle and remove icon with local-admin gating. |
| Participant traffic/path details | Participant runtime fields | Missing | Native state currently exposes only a reduced participant projection. | Expand `NativeParticipantState` or share current `ParticipantView` equivalent. |
| LAN pairing | `start_lan_pairing`, `stop_lan_pairing`, `lanPeers` | Missing | Rust actions are placeholders in `FfiApp`; UI does not expose pairing. | Move pairing runtime into app-core, add countdown and nearby peer join list. |
| Saved networks list | `SavedNetworksPanel.svelte` | Partial | Sidebar lists networks and can add a network. | Add activate, rename, delete, edit mesh ID, invite/import status, join requests, and inactive participant management. |
| Activate saved network | `set_network_enabled` | Missing | Network rows are not selectable/actionable. | Add selection/activation behavior and daemon reload handling. |
| Delete saved network | `remove_network` | Missing | Rust action exists; UI does not expose it. | Add native delete confirmation and core rule for last network behavior. |
| Routing summary | `RoutingPanel.svelte` | Missing | No routing panel. | Add direct mesh/remote exit/local exit summary. |
| Advertise exit node | `advertiseExitNode` | Ready | `Offer exit` toggle dispatches settings patch. | Add route visibility and disabled/explanatory states from routing panel. |
| Advertised routes editing | `advertisedRoutes` | Missing | Settings patch helper supports it; UI does not expose it. | Add CIDR editor and core validation errors. |
| Exit node search/select | `exitNode` | Missing | Settings patch helper supports it; UI does not expose it. | Add searchable candidate list and no-exit selection. |
| Diagnostics panel | `AdvancedPanels.svelte` | Missing | No native health/network/port-mapping panel. | Add health issue list, network summary, port mapping state, and auto-open behavior. |
| Relay list/status | Relay panel | Ready | Shows relay URLs, status text, add, and remove. | Add explicit at-least-one-relay disabled/error state and status badge parity. |
| Session options | `autoconnect` | Ready | `Autoconnect` toggle dispatches settings patch. | Add launch/startup and close-to-tray settings when platform effects exist. |
| Device settings | `SystemPanel.svelte` | Partial | Name, endpoint, tunnel IP, and listen port are editable and saved. | Add validation feedback, MagicDNS status/suffix, app version, config path, CLI install, and updater controls. |
| MagicDNS | `magicDnsStatus`, `magicDnsSuffix` | Missing | Settings patch helper supports suffix; UI does not expose status or suffix. | Add status and suffix editor. |
| Background service panel | `ServiceActionPanel.svelte` | Missing | Rust actions exist for install/uninstall/enable/disable service; UI does not expose them. | Add service status projection, repair prompt, elevated action progress, and settlement polling. |
| CLI install/uninstall | `install_cli`, `uninstall_cli` | Missing | Rust actions exist; UI does not expose them. | Add CLI install status and elevated install/uninstall buttons. |
| Launch on startup | Autostart plugin | Missing | Settings patch helper supports it; no native LaunchAgent effect/UI. | Add launch agent registration and settings toggle. |
| Close to tray/status item | Tray runtime | Missing | No status item/menu behavior. | Add menu bar item with VPN toggle, this-device copy, network devices, exit nodes, settings, quit. |
| Autostart hidden launch | `--autostart` | Missing | No launch-mode handling. | Add hidden launch path and single-instance conflict handling. |
| Single-instance handling | Tauri plugin | Missing | No native singleton coordination. | Route new opens/deep links into existing app instance. |
| Debug automation deep links | `nvpn://debug/...` | Missing | Only invite URLs are handled. | Add test-only parser/actions for tick, request join, and accept join. |
| Hashtree updater | `UpdateBanner.svelte`, updater panel | Missing | No updater UI/effects. | Port update check/download/install and desktop update prefs. |
| Responsive/adaptive layout | Svelte CSS | Partial | Native split-view desktop layout works at default size. | Add compact window behavior, accessibility pass, empty states, and screenshot coverage. |
| Copy feedback | `copiedValue` timeout | Missing | Clipboard writes happen silently. | Add transient copied indicator/toast/checkmark. |
| Collapsible panels | `<details>` state | Missing | Native shell has a flat scroll layout. | Add disclosure groups where density needs it, especially diagnostics/system. |
| Mock/demo fixtures | `mock-backend.ts` | Missing | No SwiftUI previews/fixtures. | Add fixture snapshots from Rust state for previews and screenshot tests. |
| Public relay fallback UI | Removed relay fallback/public services code | Removed | Removed upstream in `origin/master`; native shell also omits those fields and controls. | No parity work unless product reintroduces a public-service feature. |

## Native Implementation Phases

| Phase | Deliverable | Exit criteria |
| --- | --- | --- |
| 0. Contract extraction | Move Tauri backend state, settings patches, action handlers, derived labels, invite parsing, mesh ID validation, and tray projections into a native-ready Rust app core | Current Tauri command tests pass against the extracted core API. `crates/nostr-vpn-app-core` now exposes typed UniFFI state/actions and the macOS shell consumes `FfiApp` directly; more Tauri-derived runtime behavior still needs to move out of the Tauri crate. |
| 1. Desktop minimum | macOS, Windows, and Linux render the main status, active network, invite import/share, participant management, routing, diagnostics, relays, service panel, system settings, deep links, and tray/menu actions | Desktop smoke tests can import invites, request/accept join, toggle VPN, and exercise tray actions. macOS has the first native shell, but remains partial per the macOS status table above. |
| 2. Mobile minimum | Android and iPhone render the same state/action surface with native VPN permission/session control, invite QR scan/share, LAN pairing, saved networks, routing, diagnostics, relays, and deep links | Android emulator/device and iPhone simulator/device smoke tests can import invites and start supported VPN flows |
| 3. Desktop niceties | Hashtree updater, CLI install/uninstall, startup registration, close-to-tray, service repair prompts, single-instance conflict handling | Current Tauri desktop e2e scenarios have native replacements |
| 4. Polish/parity hardening | Platform screenshots, accessibility pass, empty/error states, fixture preview coverage | All rows above are either implemented or explicitly marked removed/deferred in this file |

## Open Decisions

| Decision | Options | Current recommendation |
| --- | --- | --- |
| Push updates vs polling | Keep 1500ms polling, add core update stream, or hybrid | Use update stream with tick fallback; avoid mobile background polling |
| Linux shell API | Direct Rust GTK calls into the core or UniFFI like other shells | Direct Rust is simpler, but keep the same typed state/action structs so parity tests are shared |
| QR generation location | Native QR libraries per platform or Rust QR helper | Rust helper for invite QR bytes; native scanner APIs for camera/image decode |
| Derived text ownership | Keep per-shell text formatting or move helper text into core | Move policy-bearing derived labels into core; keep purely visual labels native |
| Desktop updater on Linux | Keep hashtree updater or only package-manager updates | Keep hashtree updater for parity unless Linux packaging policy says otherwise |
