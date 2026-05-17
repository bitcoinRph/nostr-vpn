#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_NAME="nostr-vpn-e2e-join-request"
COMPOSE=(docker compose -p "$PROJECT_NAME" -f "$ROOT_DIR/docker-compose.e2e.yml")

NETWORK_ID="docker-join-request"
REQUESTER_NAME="iphone"

cleanup() {
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  docker network rm "${PROJECT_NAME}_e2e" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    docker network inspect "${PROJECT_NAME}_e2e" >/dev/null 2>&1 || break
    sleep 1
  done
}

dump_debug() {
  set +e
  echo "join-request docker e2e failed, collecting debug output..."
  "${COMPOSE[@]}" ps || true
  for service in node-a node-c; do
    echo "--- logs: $service ---"
    "${COMPOSE[@]}" logs --no-color --tail 160 "$service" || true
    echo "--- $service status ---"
    "${COMPOSE[@]}" exec -T "$service" nvpn status --json --discover-secs 0 || true
    echo "--- $service config ---"
    "${COMPOSE[@]}" exec -T "$service" sh -lc "cat /root/.config/nvpn/config.toml 2>/dev/null || true" || true
    echo "--- $service daemon.log ---"
    "${COMPOSE[@]}" exec -T "$service" sh -lc "tail -n 260 /root/.config/nvpn/daemon.log 2>/dev/null || true" || true
  done
}

on_exit() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    dump_debug
  fi
  cleanup
  exit "$exit_code"
}
trap on_exit EXIT

wait_for_service() {
  local service="$1"
  local container_id=""
  for _ in $(seq 1 30); do
    container_id="$("${COMPOSE[@]}" ps -q "$service" 2>/dev/null || true)"
    if [[ -n "$container_id" ]] \
      && [[ "$(docker inspect -f '{{.State.Running}}' "$container_id" 2>/dev/null || true)" == "true" ]]; then
      return 0
    fi
    sleep 1
  done

  echo "join-request docker e2e failed: service '$service' did not reach running state" >&2
  exit 1
}

read_npub() {
  local service="$1"
  "${COMPOSE[@]}" exec -T "$service" sh -lc \
    "nvpn init --force >/dev/null && awk '
      /^\\[nostr\\]$/ { in_nostr = 1; next }
      /^\\[/ { in_nostr = 0 }
      in_nostr && /^public_key[[:space:]]*=/ {
        print \$3;
        exit
      }
    ' /root/.config/nvpn/config.toml" | tr -d '\r\"'
}

toml_array() {
  local result="["
  local first=true
  local item
  for item in "$@"; do
    if [[ "$first" == true ]]; then
      first=false
    else
      result+=", "
    fi
    result+="\"$item\""
  done
  result+="]"
  printf '%s' "$result"
}

set_admin_roster() {
  local service="$1"
  local participants_toml="$2"
  local admins_toml="$3"
  local admin="$4"
  local shared_at
  shared_at="$(date +%s)"

  "${COMPOSE[@]}" exec -T \
    -e PARTICIPANTS_TOML="$participants_toml" \
    -e ADMINS_TOML="$admins_toml" \
    -e ADMIN="$admin" \
    -e SHARED_AT="$shared_at" \
    "$service" sh -lc '
cfg=/root/.config/nvpn/config.toml
tmp=$(mktemp)
perl -0pe '"'"'
  s/^participants\s*=\s*\[[^\]]*\]/participants = $ENV{PARTICIPANTS_TOML}/ms;
  if (/^admins\s*=/m) {
    s/^admins\s*=\s*\[[^\]]*\]/admins = $ENV{ADMINS_TOML}/ms;
  } else {
    s/^participants\s*=\s*\[[^\]]*\]/participants = $ENV{PARTICIPANTS_TOML}\nadmins = $ENV{ADMINS_TOML}/ms;
  }
  if (/^listen_for_join_requests\s*=/m) {
    s/^listen_for_join_requests\s*=.*$/listen_for_join_requests = true/m;
  } else {
    s/^admins\s*=.*$/admins = $ENV{ADMINS_TOML}\nlisten_for_join_requests = true/m;
  }
  if (/^invite_inviter\s*=/m) {
    s/^invite_inviter\s*=.*$/invite_inviter = "$ENV{ADMIN}"/m;
  } else {
    s/^listen_for_join_requests\s*=.*$/listen_for_join_requests = true\ninvite_inviter = "$ENV{ADMIN}"/m;
  }
  if (/^shared_roster_updated_at\s*=/m) {
    s/^shared_roster_updated_at\s*=.*$/shared_roster_updated_at = $ENV{SHARED_AT}/m;
  } else {
    s/^invite_inviter\s*=.*$/invite_inviter = "$ENV{ADMIN}"\nshared_roster_updated_at = $ENV{SHARED_AT}/m;
  }
  if (/^shared_roster_signed_by\s*=/m) {
    s/^shared_roster_signed_by\s*=.*$/shared_roster_signed_by = "$ENV{ADMIN}"/m;
  } else {
    s/^shared_roster_updated_at\s*=.*$/shared_roster_updated_at = $ENV{SHARED_AT}\nshared_roster_signed_by = "$ENV{ADMIN}"/m;
  }
'"'"' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
'
}

start_daemon_open_discovery() {
  local service="$1"
  if ! "${COMPOSE[@]}" exec -T "$service" sh -lc \
    "NVPN_FIPS_NOSTR_DISCOVERY_POLICY=open nvpn start --daemon --connect >/tmp/nvpn-start.log 2>&1"; then
    echo "join-request docker e2e failed: daemon start failed on $service" >&2
    "${COMPOSE[@]}" exec -T "$service" sh -lc "cat /tmp/nvpn-start.log" >&2 || true
    exit 1
  fi
}

wait_for_inbound_join_request() {
  local service="$1"
  local requester="$2"
  local requester_name="$3"
  local found=""

  for _ in $(seq 1 90); do
    found="$("${COMPOSE[@]}" exec -T \
      -e REQUESTER="$requester" \
      -e REQUESTER_NAME="$requester_name" \
      "$service" perl -0ne '
  my $requester = $ENV{REQUESTER};
  my $requester_name = $ENV{REQUESTER_NAME};
  while (/\[\[networks\.inbound_join_requests\]\]\s*\n(.*?)(?=^\[|\z)/msg) {
    my $block = $1;
    if ($block =~ /^requester\s*=\s*"\Q$requester\E"\s*$/m
      && $block =~ /^requester_node_name\s*=\s*"\Q$requester_name\E"\s*$/m) {
      print "yes";
      exit;
    }
  }
' /root/.config/nvpn/config.toml || true)"
    if [[ "$found" == "yes" ]]; then
      return 0
    fi
    sleep 1
  done

  echo "join-request docker e2e failed: admin never persisted request from $requester" >&2
  "${COMPOSE[@]}" exec -T "$service" sh -lc "cat /root/.config/nvpn/config.toml" >&2 || true
  exit 1
}

cleanup

"${COMPOSE[@]}" build >/dev/null
"${COMPOSE[@]}" up -d node-a node-c >/dev/null
wait_for_service node-a
wait_for_service node-c

ADMIN_NPUB="$(read_npub node-a)"
REQUESTER_NPUB="$(read_npub node-c)"

if [[ -z "$ADMIN_NPUB" || -z "$REQUESTER_NPUB" ]]; then
  echo "join-request docker e2e failed: unable to resolve npubs" >&2
  exit 1
fi

ADMIN_ONLY="$(toml_array "$ADMIN_NPUB")"

"${COMPOSE[@]}" exec -T node-a nvpn set \
  --network-id "$NETWORK_ID" \
  --node-name "macos-admin" \
  --endpoint "10.203.0.10:51820" \
  --listen-port 51820 \
  --fips-advertise-endpoint true >/dev/null
set_admin_roster node-a "$ADMIN_ONLY" "$ADMIN_ONLY" "$ADMIN_NPUB"

INVITE="$("${COMPOSE[@]}" exec -T node-a nvpn create-invite | tr -d '\r')"
if [[ -z "$INVITE" ]]; then
  echo "join-request docker e2e failed: admin did not create an invite" >&2
  exit 1
fi

start_daemon_open_discovery node-a

"${COMPOSE[@]}" exec -T node-c nvpn import-invite "$INVITE" >/dev/null
"${COMPOSE[@]}" exec -T node-c nvpn set \
  --node-name "$REQUESTER_NAME" \
  --endpoint "10.203.0.12:51820" \
  --listen-port 51820 \
  --fips-advertise-endpoint true \
  --fips-peer-endpoint "$ADMIN_NPUB=10.203.0.10:51820" >/dev/null
start_daemon_open_discovery node-c

wait_for_inbound_join_request node-a "$REQUESTER_NPUB" "$REQUESTER_NAME"

echo "join request from $REQUESTER_NAME was persisted on admin"
