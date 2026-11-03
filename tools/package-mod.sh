#!/usr/bin/env bash
# Packs the companion mod as a zip for the mod portal or for the mods folder of another machine.
# Output: dist/pi-companion_<version>.zip (Factorio expects the folder pi-companion_<version>/ inside).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=$(python3 -c "import json;print(json.load(open('$ROOT/mod/pi-companion/info.json'))['version'])")
NAME="pi-companion_$VERSION"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$ROOT/dist"
cp -r "$ROOT/mod/pi-companion" "$TMP/$NAME"
rm -f "$ROOT/dist/$NAME.zip"
(cd "$TMP" && zip -qr "$ROOT/dist/$NAME.zip" "$NAME")
echo "$ROOT/dist/$NAME.zip"
