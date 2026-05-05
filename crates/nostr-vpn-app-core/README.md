# nostr-vpn-app-core

Native shells use this crate as the shared app contract while the runtime is
being extracted from the current Tauri backend.

It currently owns:

- the UI snapshot structs that mirror the shipped Svelte/Tauri `UiState`
- the typed native state used by the macOS SwiftUI shell
- the complete typed action set corresponding to current app behavior
- platform capability projection for desktop, Android, and iPhone
- a UniFFI `FfiApp` object with `state`, `refresh`, and `dispatch`

Tauri can keep consuming the shared data structs while native shells move to the
typed UniFFI API.
