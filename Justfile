set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
    @just --list

info:
    @echo "Nostr VPN commands"
    @echo
    @echo "Run"
    @echo "  just run-macos"
    @echo
    @echo "macOS"
    @echo "  just macos-gen-swift"
    @echo "  just macos-rust"
    @echo "  just macos-xcframework"
    @echo "  just macos-xcodeproj"
    @echo "  just macos-build"
    @echo
    @echo "Checks"
    @echo "  just test"
    @echo "  just e2e"
    @echo "  just e2e-connect"
    @echo "  just e2e-active-network"
    @echo "  just e2e-exit-node"
    @echo "  just e2e-nat"
    @echo "  just e2e-roster-admin"

run-macos:
    ./tools/run-macos

macos-gen-swift:
    ./scripts/macos-build macos-gen-swift

macos-rust:
    ./scripts/macos-build macos-rust

macos-xcframework:
    ./scripts/macos-build macos-xcframework

macos-xcodeproj:
    ./scripts/macos-build macos-xcodeproj

macos-build:
    ./scripts/macos-build macos-build

test:
    cargo test

e2e:
    ./scripts/e2e-docker.sh

e2e-connect:
    ./scripts/e2e-connect-docker.sh

e2e-active-network:
    ./scripts/e2e-active-network-docker.sh

e2e-divergent-roster:
    ./scripts/e2e-divergent-roster-docker.sh

e2e-exit-node:
    ./scripts/e2e-exit-node-docker.sh

e2e-nat:
    ./scripts/e2e-nat-docker.sh

e2e-roster-admin:
    ./scripts/e2e-roster-admin-docker.sh
