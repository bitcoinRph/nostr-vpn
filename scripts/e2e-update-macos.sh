#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-$ROOT/artifacts}"
FIXTURE_DIR="$ARTIFACT_ROOT/update-fixtures/macos"
RESULT_PATH="$ARTIFACT_ROOT/macos-update-e2e.json"
TAG="${NVPN_UPDATE_E2E_TAG:-v99.0.0}"
XCODE_CONFIGURATION="${NVPN_MACOS_XCODE_CONFIGURATION:-Debug}"
ASSET_NAME="nostr-vpn-${TAG}-macos-arm64.app.tar.gz"
ASSET_PATH="$FIXTURE_DIR/$ASSET_NAME"
MANIFEST_PATH="$FIXTURE_DIR/release.json"

rm -rf "$FIXTURE_DIR"
mkdir -p "$FIXTURE_DIR/app/Nostr VPN.app/Contents" "$ARTIFACT_ROOT"
cat >"$FIXTURE_DIR/app/Nostr VPN.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleName</key><string>Nostr VPN</string></dict></plist>
PLIST
tar -czf "$ASSET_PATH" -C "$FIXTURE_DIR/app" "Nostr VPN.app"

node - "$MANIFEST_PATH" "$TAG" "$ASSET_NAME" <<'NODE'
const fs = require('fs');
const [manifestPath, tag, assetName] = process.argv.slice(2);
fs.writeFileSync(manifestPath, JSON.stringify({
  tag,
  assets: [{ name: assetName, path: assetName }],
}, null, 2));
NODE

"$ROOT/scripts/macos-build" macos-build

APP_PATH="$ROOT/macos/.build/DerivedData/Build/Products/$XCODE_CONFIGURATION/Nostr VPN.app"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "Built macOS app not found" >&2
  exit 1
fi

pkill -x "Nostr VPN" >/dev/null 2>&1 || true
rm -f "$RESULT_PATH"

MANIFEST_URL="$(node -e 'const { pathToFileURL } = require("url"); console.log(pathToFileURL(process.argv[1]).href)' "$MANIFEST_PATH")"
env \
  NVPN_UPDATE_MANIFEST_URL="$MANIFEST_URL" \
  NVPN_UPDATE_E2E_RESULT_PATH="$RESULT_PATH" \
  "$APP_PATH/Contents/MacOS/Nostr VPN" \
  --nvpn-e2e-update-check \
  --nvpn-e2e-install-update

node - "$RESULT_PATH" <<'NODE'
const fs = require('fs');
const resultPath = process.argv[2];
const result = JSON.parse(fs.readFileSync(resultPath, 'utf8'));
if (!result.ok) throw new Error(result.error || 'macOS update e2e failed');
if (!result.available) throw new Error('macOS update was not detected as available');
if (!result.assetName || !result.assetName.endsWith('-macos-arm64.app.tar.gz')) {
  throw new Error(`unexpected macOS asset: ${result.assetName}`);
}
if (!result.downloadedPath || !fs.existsSync(result.downloadedPath)) {
  throw new Error(`download missing: ${result.downloadedPath}`);
}
if (!result.preparedAppPath || !fs.existsSync(result.preparedAppPath)) {
  throw new Error(`prepared app missing: ${result.preparedAppPath}`);
}
NODE

echo "MACOS_UPDATE_E2E_OK"
echo "Result: $RESULT_PATH"
