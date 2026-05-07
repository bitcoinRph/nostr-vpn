# Path Maintenance Architecture

This document used to describe the legacy Unix WireGuard path-maintenance plan.
That runtime has been removed from the main nostr-vpn mesh mode.

Current path maintenance belongs to the FIPS private mesh runtime:

- FIPS owns peer transport selection and link probing.
- `nostr-vpn` supplies roster-derived peers, route targets, configured static FIPS endpoints, and NAT-discovered local endpoint hints.
- Daemon state reports FIPS link status through `fips_*` fields and `last_fips_seen_at`.
- Any future WireGuard exit-node work should live in a separate component, not in the main private mesh path manager.

The current implementation is centered in `crates/nostr-vpn-cli/src/fips_private_mesh.rs`.
