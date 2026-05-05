# macOS Native Shell

This is the first native front end for the Rust-owned app architecture.

The app is SwiftUI/AppKit over `nostr-vpn-app-core` through UniFFI:

- `FfiApp.state()` returns typed native state.
- `FfiApp.dispatch(_:)` accepts typed `NativeAppAction`.
- Swift owns rendering, clipboard, URL handling, and macOS app lifecycle.
- Rust owns config mutation, daemon/session commands, state projection, and action outcomes.

Build locally:

```bash
./scripts/macos-build macos-build
```

Run locally:

```bash
./tools/run-macos
```

The parity checklist is in `docs/native-ui-parity-matrix.md`.
