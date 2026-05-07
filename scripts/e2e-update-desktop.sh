#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT/scripts/e2e-update-macos.sh"
"$ROOT/scripts/e2e-update-linux.sh"

if [[ "${SKIP_WINDOWS_UPDATE_E2E:-0}" != "1" ]]; then
  "$ROOT/scripts/e2e-update-windows-vm.sh" "${VM_NAME:-Windows 11}"
fi
