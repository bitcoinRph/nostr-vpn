#!/usr/bin/env bash
# Bottleneck investigation suite. Runs after the mesh is up:
#   - UDP saturation sweep: 1G, 1.5G, 2G, 3G  -> identify lossy point
#   - TCP single with -w 4M                    -> rule out window-bound
#   - TCP -P 16 / -P 32 / -P 64                -> saturate beyond 1548 Mbps cap
#   - TCP -P 4 with --zerocopy on sender       -> userspace-copy cost check
#
# Re-uses the same up/down logic as perf-docker.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-nvpn-perf}"
COMPOSE=(docker compose -p "$PROJECT_NAME" -f "$ROOT_DIR/docker-compose.e2e.yml")

NETWORK_ID="docker-perf"
DURATION="${DURATION:-10}"

cleanup() {
  if [[ -z "${KEEP:-}" ]]; then
    "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
    docker network rm "${PROJECT_NAME}_e2e" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

wait_for_service() {
  local service="$1"
  for _ in $(seq 1 30); do
    cid="$("${COMPOSE[@]}" ps -q "$service" 2>/dev/null || true)"
    if [[ -n "$cid" ]] && [[ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || true)" == "true" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "perf: service '$service' did not start" >&2
  exit 1
}

nostr_pubkey_from_config() {
  local service="$1"
  "${COMPOSE[@]}" exec -T "$service" sh -lc "
    awk '
      /^\\[nostr\\]\$/ { in_nostr = 1; next }
      /^\\[/ { in_nostr = 0 }
      in_nostr && /^public_key[[:space:]]*=/ {
        print \$3;
        exit
      }
    ' /root/.config/nvpn/config.toml
  " | tr -d '\r"'
}

cleanup
"${COMPOSE[@]}" up -d node-a node-b >/dev/null
for service in node-a node-b; do
  wait_for_service "$service"
done

"${COMPOSE[@]}" exec -T node-a nvpn init --force >/dev/null
"${COMPOSE[@]}" exec -T node-b nvpn init --force >/dev/null
ALICE_NPUB="$(nostr_pubkey_from_config node-a)"
BOB_NPUB="$(nostr_pubkey_from_config node-b)"

"${COMPOSE[@]}" exec -T node-a nvpn set \
  --network-id "$NETWORK_ID" \
  --participant "$ALICE_NPUB" \
  --participant "$BOB_NPUB" \
  --endpoint "10.203.0.10:51820" \
  --listen-port 51820 \
  --fips-advertise-endpoint true \
  --fips-peer-endpoint "$BOB_NPUB=10.203.0.11:51820" >/dev/null

"${COMPOSE[@]}" exec -T node-b nvpn set \
  --network-id "$NETWORK_ID" \
  --participant "$ALICE_NPUB" \
  --participant "$BOB_NPUB" \
  --endpoint "10.203.0.11:51820" \
  --listen-port 51820 \
  --fips-advertise-endpoint true \
  --fips-peer-endpoint "$ALICE_NPUB=10.203.0.10:51820" >/dev/null

ALICE_TUNNEL_IP="$("${COMPOSE[@]}" exec -T node-a nvpn ip | tr -d '\r')"
BOB_TUNNEL_IP="$("${COMPOSE[@]}" exec -T node-b nvpn ip | tr -d '\r')"

"${COMPOSE[@]}" exec -d node-a sh -lc "nvpn connect > /tmp/connect.log 2>&1"
"${COMPOSE[@]}" exec -d node-b sh -lc "nvpn connect > /tmp/connect.log 2>&1"

for _ in $(seq 1 30); do
  a="$("${COMPOSE[@]}" exec -T node-a sh -lc 'cat /tmp/connect.log 2>/dev/null || true')"
  b="$("${COMPOSE[@]}" exec -T node-b sh -lc 'cat /tmp/connect.log 2>/dev/null || true')"
  if grep -q "mesh: 1/1 peers connected" <<<"$a" \
    && grep -q "mesh: 1/1 peers connected" <<<"$b"; then
    break
  fi
  sleep 1
done

if ! "${COMPOSE[@]}" exec -T node-a ping -c 3 -W 2 "$BOB_TUNNEL_IP" >/dev/null; then
  echo "perf: ping a->b over mesh failed" >&2
  exit 1
fi

echo "alice tunnel ip: $ALICE_TUNNEL_IP"
echo "bob   tunnel ip: $BOB_TUNNEL_IP"
echo

"${COMPOSE[@]}" exec -d node-b sh -lc "iperf3 -s -D --logfile /tmp/iperf3-server.log"
sleep 1

run_test() {
  local label="$1"; shift
  printf '## %s\n' "$label"
  set +e
  "${COMPOSE[@]}" exec -T node-a iperf3 -c "$BOB_TUNNEL_IP" -t "$DURATION" -i 0 -f m \
    --connect-timeout 3000 "$@" 2>&1 | tail -8
  set -e
  echo
}

# Bump TCP rmem_max so -w 4M is accepted. Best-effort.
"${COMPOSE[@]}" exec -T --privileged node-a sh -lc 'sysctl -w net.core.rmem_max=8388608 net.core.wmem_max=8388608' >/dev/null 2>&1 || true
"${COMPOSE[@]}" exec -T --privileged node-b sh -lc 'sysctl -w net.core.rmem_max=8388608 net.core.wmem_max=8388608' >/dev/null 2>&1 || true

# --- TCP scaling beyond 1548 Mbps cap (run first; UDP can leave receiver
# back-pressured for ~10s into next test). ---
run_test "TCP 1 stream, 4M window" -w 4M
run_test "TCP 16 streams" -P 16
run_test "TCP 32 streams" -P 32
run_test "TCP 64 streams" -P 64

# --- Sender-side userspace copy cost ---
run_test "TCP 4 streams, zerocopy" -P 4 --zerocopy

# --- UDP saturation sweep ---
run_test "UDP 1000 Mbit" -u -b 1G --length 1200
run_test "UDP 1500 Mbit" -u -b 1500M --length 1200
run_test "UDP 2000 Mbit" -u -b 2G --length 1200
