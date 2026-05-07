#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-$ROOT/artifacts}"
FIXTURE_DIR="$ARTIFACT_ROOT/update-fixtures/linux"
RESULT_PATH="$ARTIFACT_ROOT/linux-update-e2e.json"
DOWNLOAD_DIR="$ARTIFACT_ROOT/update-downloads/linux"
TAG="${NVPN_UPDATE_E2E_TAG:-v99.0.0}"
ASSET_NAMES=(
  "nostr-vpn-${TAG}-linux-x64.AppImage"
  "nostr-vpn-${TAG}-linux-arm64.AppImage"
)

rm -rf "$FIXTURE_DIR" "$DOWNLOAD_DIR"
mkdir -p "$FIXTURE_DIR" "$DOWNLOAD_DIR"
for ASSET_NAME in "${ASSET_NAMES[@]}"; do
  printf '#!/bin/sh\necho nostr vpn update fixture\n' >"$FIXTURE_DIR/$ASSET_NAME"
  chmod +x "$FIXTURE_DIR/$ASSET_NAME"
done

node - "$FIXTURE_DIR/release.json" "$TAG" "${ASSET_NAMES[@]}" <<'NODE'
const fs = require('fs');
const [manifestPath, tag, ...assetNames] = process.argv.slice(2);
fs.writeFileSync(manifestPath, JSON.stringify({
  tag,
  assets: assetNames.map((assetName) => ({ name: assetName, path: assetName })),
}, null, 2));
NODE

cd "$ROOT/linux"
docker compose up -d --build
docker compose exec \
  -T \
  -e NVPN_UPDATE_MANIFEST_URL="file:///workspace/nostr-vpn/artifacts/update-fixtures/linux/release.json" \
  -e NVPN_UPDATE_E2E_RESULT_PATH="/workspace/nostr-vpn/artifacts/linux-update-e2e.json" \
  -e NVPN_UPDATE_DOWNLOAD_DIR="/workspace/nostr-vpn/artifacts/update-downloads/linux" \
  -e NVPN_UPDATE_SKIP_OPEN=1 \
  nostr-vpn-linux \
  /usr/local/bin/dev-entrypoint cargo run -- --nvpn-e2e-update-check --nvpn-e2e-install-update

node - "$RESULT_PATH" "$ROOT" <<'NODE'
const fs = require('fs');
const [resultPath, root] = process.argv.slice(2);
const result = JSON.parse(fs.readFileSync(resultPath, 'utf8'));
if (!result.ok) throw new Error(result.error || 'Linux update e2e failed');
if (!result.available) throw new Error('Linux update was not detected as available');
if (!result.assetName || !/linux.*\.(AppImage|deb)$/.test(result.assetName)) {
  throw new Error(`unexpected Linux asset: ${result.assetName}`);
}
const hostDownloadedPath = result.downloadedPath?.replace(/^\/workspace\/nostr-vpn/, root);
if (!hostDownloadedPath || !fs.existsSync(hostDownloadedPath)) {
  throw new Error(`download missing: ${result.downloadedPath}`);
}
if (result.downloadedExecutable !== true) {
  throw new Error('downloaded Linux update was not executable');
}
NODE

echo "LINUX_UPDATE_E2E_OK"
echo "Result: $RESULT_PATH"
