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

## Server als Dienst (optional, für einen dedizierten Server-Rechner)

Auf dem Spielrechner reicht `server/server.sh start <name>`. Für Dauerbetrieb:

```bash
systemctl --user link "$PWD/server/systemd/factorio-pi.service"
systemctl --user enable --now factorio-pi   # startet ab Login
journalctl --user -u factorio-pi -f
```
Spielstand: `Environment=FACTORIO_SAVE=spike` in der Unit-Datei.

## Pi-Erweiterung

`pi-extension/` ist in `~/.pi/agent/settings.json` als lokales Paket eingetragen.

- Werkzeuge: `factorio_call` (beliebige Mod-Op), `factorio_say` (Chat als [Pi]).
- Chatbrücke: fragt alle 2 s den Posteingang ab; `@pi …`-Nachrichten landen als Nachricht in der laufenden Pi-Sitzung, der Fragende sieht „[Pi] denkt nach …“.
- `/factorio on|off|status`; `FACTORIO_PI_BRIDGE=off` startet ohne Brücke.
