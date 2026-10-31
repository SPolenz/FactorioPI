# factorio-pi

Ziel: Pi spielt bei Factorio mit, als Planer und Berater (Blueprints und Geister, die eure Bauroboter bauen) und per Chat (`@pi …`).

## Aufbau

- `mod/pi-companion/`: Begleit-Mod (Lua). Steuerung über den eigenen Befehl `/pi <json>`, nur von der Serverkonsole bzw. RCON. Kein `/c`, damit Achievements nicht abgeschaltet werden.
- `server/server.sh`: lokaler dedizierter Server mit eigenem Datenordner `server/data` (berührt `~/.factorio` nicht), RCON nur auf `127.0.0.1:27015`, Passwort in `server/.env`.
- `tools/rcon.py`: minimaler RCON-Client zum Testen.

## Schnellstart

```bash
server/server.sh create spike     # neue Karte
server/server.sh start spike      # Server starten (Spielport 34197)
tools/rcon.py --op ping
tools/rcon.py --op summary
tools/rcon.py --op say '{"text":"Hallo"}'
tools/rcon.py --op inbox          # Chatnachrichten, die mit "@pi" beginnen
```
