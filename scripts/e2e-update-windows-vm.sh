#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_NAME="${VM_NAME:-${1:-Windows 11}}"
GUEST_REPO="${GUEST_REPO:-C:\\Mac\\Home\\src\\nostr-vpn}"
GUEST_ARTIFACT_ROOT="${GUEST_ARTIFACT_ROOT:-C:\\Mac\\Home\\src\\nostr-vpn\\artifacts}"

encode_ps() {
  iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n'
}

run_ps_user() {
  local encoded
  encoded="$(printf '%s' "$1" | encode_ps)"
  prlctl exec "$VM_NAME" --current-user powershell.exe -NoProfile -EncodedCommand "$encoded"
}

run_ps_user "Set-Location \"$GUEST_REPO\"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\e2e-update-windows.ps1 -ArtifactRoot \"$GUEST_ARTIFACT_ROOT\"
exit \$LASTEXITCODE"
