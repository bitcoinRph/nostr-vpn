# Linux Native Shell

Rust GTK4/libadwaita shell over `nostr-vpn-app-core`.

Run it from the repo root:

```bash
just run-linux
```

The dev target runs inside Docker with a small Xvfb/Fluxbox desktop and VNC on
`localhost:5902`. The VNC password is `nostrvpn`.

Useful commands:

```bash
just linux-build
./tools/run-linux cargo check
./tools/run-linux cargo run
```

The shell follows the current SwiftUI/AppKit app structure: Devices, Share,
Routing, Settings, and an Advanced disclosure for relays and diagnostics. It
owns the same core flows for connect/disconnect, roster presence, participant
management, invite QR/import, LAN pairing, saved networks, exit-node selection,
advertised routes, relays, service/CLI actions, and diagnostics. Remaining
Linux-native work is desktop portal integration, file/camera QR scanning,
tray/status notifier support, deep links, and packaged update UX.

The parity checklist is in `../docs/native-ui-parity-matrix.md`.
