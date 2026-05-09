#!/usr/bin/env bash
# Throughput / latency benchmark over a 2-node WireGuard userspace tunnel
# inside docker, using Cloudflare's `boringtun-cli` as the userspace
# WireGuard implementation.
#
# Same network shape, same iperf3 / ping methodology as
# scripts/perf-docker.sh, so the output format lines up with the nvpn
# bench tables for an apples-to-apples comparison. Bench uses the
# default chacha20poly1305 wire crypto (NEON on aarch64, AVX on x86_64).
#
# Two passes by default:
#   - WG_THREADS=1 — boringtun in single-task mode, the architectural
#     peer to the current single-task nvpn run_rx_loop.
#   - WG_THREADS=4 — boringtun's CLI default, real-world deployment.
#
# Override: WG_THREADS_LIST="1 4 8" bash scripts/perf-docker-boringtun.sh
# Single pass: WG_THREADS=4 SINGLE_PASS=1 bash scripts/perf-docker-boringtun.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-nvpn-bench-boringtun}"
COMPOSE=(docker compose -p "$PROJECT_NAME" -f "$ROOT_DIR/docker-compose.bench-boringtun.yml")

DURATION="${DURATION:-10}"
ALICE_TUN="10.44.0.1"
BOB_TUN="10.44.0.2"
ALICE_BRIDGE="10.203.0.10"
BOB_BRIDGE="10.203.0.11"
WG_PORT="51820"

if [[ -n "${SINGLE_PASS:-}" ]]; then
  THREADS_LIST=("${WG_THREADS:-4}")
else
  IFS=' ' read -ra THREADS_LIST <<<"${WG_THREADS_LIST:-1 4}"
fi

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
  echo "perf-boringtun: service '$service' did not start" >&2
  exit 1
}

reset_wg() {
  for service in node-a node-b; do
    "${COMPOSE[@]}" exec -T "$service" sh -c "
      pkill -9 boringtun-cli 2>/dev/null
      ip link del wg0 2>/dev/null
      true
    " >/dev/null
  done
}

setup_wg() {
  local threads="$1"

  ALICE_PRIV=$("${COMPOSE[@]}" exec -T node-a wg genkey | tr -d '\r\n')
  ALICE_PUB=$(echo -n "$ALICE_PRIV" | "${COMPOSE[@]}" exec -T node-a wg pubkey | tr -d '\r\n')
  BOB_PRIV=$("${COMPOSE[@]}" exec -T node-b wg genkey | tr -d '\r\n')
  BOB_PUB=$(echo -n "$BOB_PRIV" | "${COMPOSE[@]}" exec -T node-b wg pubkey | tr -d '\r\n')

  "${COMPOSE[@]}" exec -T node-a sh -c "
    set -e
    WG_THREADS=$threads boringtun-cli --disable-drop-privileges wg0 >/dev/null 2>&1
    ip addr add $ALICE_TUN/24 dev wg0
    ip link set wg0 mtu 1420
    ip link set wg0 up
    printf '%s' '$ALICE_PRIV' > /tmp/wg.priv
    wg set wg0 private-key /tmp/wg.priv listen-port $WG_PORT
    wg set wg0 peer '$BOB_PUB' allowed-ips $BOB_TUN/32 endpoint $BOB_BRIDGE:$WG_PORT persistent-keepalive 25
  " >/dev/null

  "${COMPOSE[@]}" exec -T node-b sh -c "
    set -e
    WG_THREADS=$threads boringtun-cli --disable-drop-privileges wg0 >/dev/null 2>&1
    ip addr add $BOB_TUN/24 dev wg0
    ip link set wg0 mtu 1420
    ip link set wg0 up
    printf '%s' '$BOB_PRIV' > /tmp/wg.priv
    wg set wg0 private-key /tmp/wg.priv listen-port $WG_PORT
    wg set wg0 peer '$ALICE_PUB' allowed-ips $ALICE_TUN/32 endpoint $ALICE_BRIDGE:$WG_PORT persistent-keepalive 25
  " >/dev/null

  # Wait for the tunnel to converge (handshake fires on first traffic).
  for _ in $(seq 1 30); do
    if "${COMPOSE[@]}" exec -T node-a ping -c 1 -W 1 "$BOB_TUN" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  echo "perf-boringtun: tunnel did not converge for threads=$threads" >&2
  exit 1
}

run_test() {
  local label="$1"; shift
  printf '## %s\n' "$label"
  "${COMPOSE[@]}" exec -T node-a iperf3 -c "$BOB_TUN" -t "$DURATION" -i 0 -f m \
    --connect-timeout 3000 "$@" 2>&1 | tail -6
  echo
}

cleanup
"${COMPOSE[@]}" up -d node-a node-b >/dev/null
for service in node-a node-b; do
  wait_for_service "$service"
done

for threads in "${THREADS_LIST[@]}"; do
  reset_wg
  setup_wg "$threads"

  printf '\n=========================================\n'
  printf '  boringtun WG_THREADS=%s\n' "$threads"
  printf '=========================================\n'
  printf 'alice tunnel ip: %s\n' "$ALICE_TUN"
  printf 'bob   tunnel ip: %s\n\n' "$BOB_TUN"

  # Restart the iperf3 server fresh per pass so socket state from a
  # prior pass can't leak into the next.
  "${COMPOSE[@]}" exec -T node-b sh -c "pkill -9 iperf3 2>/dev/null; true" >/dev/null
  "${COMPOSE[@]}" exec -d node-b sh -lc "iperf3 -s -D --logfile /tmp/iperf3-server.log"
  sleep 1

  run_test "TCP single stream"
  run_test "TCP 4 streams" -P 4
  run_test "TCP 8 streams" -P 8
  run_test "UDP 200 Mbit target" -u -b 200M
  run_test "UDP 1000 Mbit target" -u -b 1G

  printf '## ping (300 packets, 10ms apart) over wg0\n'
  "${COMPOSE[@]}" exec -T node-a ping -c 300 -i 0.01 -q "$BOB_TUN" 2>&1 | tail -3
  echo
done
