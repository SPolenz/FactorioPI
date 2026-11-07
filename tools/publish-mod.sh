#!/usr/bin/env bash
# Uploads dist/pi-companion_<version>.zip to the Factorio mod portal.
# First upload publishes the mod (API key scope "ModPortal: Publish Mods"), later ones add a release
# ("ModPortal: Upload Mods"). Create the key at https://factorio.com/profile and keep it out of the repo:
#   FACTORIO_API_KEY=... tools/publish-mod.sh   or   ~/.config/factorio/api-key (chmod 600)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOD=pi-companion
KEY="${FACTORIO_API_KEY:-$(cat "$HOME/.config/factorio/api-key" 2>/dev/null || true)}"
[[ -n "$KEY" ]] || { echo "No API key (FACTORIO_API_KEY or ~/.config/factorio/api-key)"; exit 1; }
ZIP="$("$ROOT/tools/package-mod.sh")"
API=https://mods.factorio.com/api/v2/mods

if [[ "$(curl -s -o /dev/null -w '%{http_code}' "https://mods.factorio.com/api/mods/$MOD")" == 200 ]]; then
  INIT="$API/releases/init_upload"; EXTRA=()
else
  INIT="$API/init_publish"
  EXTRA=(-F "description=<$ROOT/README.md" -F category=utilities -F license=default_mit
         -F "source_url=https://github.com/SPolenz/FactorioPI")
fi
URL=$(curl -sf -H "Authorization: Bearer $KEY" -F "mod=$MOD" "$INIT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["upload_url"])')
curl -sf -F "file=@$ZIP" "${EXTRA[@]}" "$URL"
echo
