#!/usr/bin/env bash
# Packt den Begleit-Mod als Zip, das man in den mods-Ordner eines anderen Rechners legen kann.
# Ergebnis: dist/pi-companion_<version>.zip (Factorio erwartet darin den Ordner pi-companion_<version>/).
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
