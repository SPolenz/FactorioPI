#!/usr/bin/env bash
# Lokaler Factorio-Server für factorio-pi. Eigene Schreibdaten (server/data), berührt ~/.factorio nicht.
# Nutzung: server/server.sh create <name> | start <name> | stop
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
FACTORIO="${FACTORIO_BIN:-$HOME/.local/share/Steam/steamapps/common/Factorio/bin/x64/factorio}"
DATA="$HERE/data"
MODS="$DATA/mods"
RCON_PORT="${RCON_PORT:-27015}"
GAME_PORT="${GAME_PORT:-34197}"
ENV_FILE="$HERE/.env"

mkdir -p "$DATA/saves" "$MODS"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "RCON_PASSWORD=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi
source "$ENV_FILE"

cat > "$DATA/config.ini" <<CFG
[path]
read-data=__PATH__executable__/../../data
write-data=$DATA
CFG

# Begleit-Mod als Symlink einhängen, damit Änderungen sofort greifen.
VERSION=$(python3 -c "import json;print(json.load(open('$ROOT/mod/pi-companion/info.json'))['version'])")
find "$MODS" -maxdepth 1 -name 'pi-companion*' -exec rm -rf {} +
ln -s "$ROOT/mod/pi-companion" "$MODS/pi-companion_$VERSION"
[[ -f "$MODS/mod-list.json" ]] || cat > "$MODS/mod-list.json" <<JSON
{"mods":[{"name":"base","enabled":true},{"name":"elevated-rails","enabled":true},{"name":"quality","enabled":true},{"name":"recycler","enabled":true},{"name":"space-age","enabled":true},{"name":"pi-companion","enabled":true}]}
JSON

COMMON=(--config "$DATA/config.ini" --mod-directory "$MODS")
case "${1:-}" in
  create) "$FACTORIO" "${COMMON[@]}" --create "$DATA/saves/${2:?name}.zip" ;;
  start)
    exec "$FACTORIO" "${COMMON[@]}" --start-server "$DATA/saves/${2:?name}.zip" \
      --port "$GAME_PORT" --rcon-bind "127.0.0.1:$RCON_PORT" --rcon-password "$RCON_PASSWORD" \
      --server-settings "$HERE/server-settings.json" ;;
  *) echo "usage: $0 create <name> | start <name>"; exit 1 ;;
esac
