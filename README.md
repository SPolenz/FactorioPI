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

## Sichten (Ops des Begleit-Mods)

- `rails {surface?, limit?}`: Schienennetz verdichtet. Probleme (u. a. `DEADLOCK: trains a -> b -> … -> a` aus dem Wartegraphen), Linien (Fahrpläne je Zuggruppe, einmal statt pro Zug), Bahnhöfe, Züge mit Zustand, Ziel, Ladung und `waits_for` (auf welchen Zug ein wartender Zug wartet).
- `map {x, y, r}` oder `{x1, y1, x2, y2, scale?}`: ASCII-Karte. `- | / \` Schienen, `+` Kreuzung, `H` Haltestelle, Signal `o`/`y`/`x` (offen/reserviert/zu), Kettensignal `O`/`Y`/`X`, Buchstaben = Züge.
- `entities {x1, y1, x2, y2, type?|name?}`: Entitäten eines Bereichs mit Position, Richtung und Signalzustand. Ein Signal zeigt zum ankommenden Zug.

## Echte Spielstände

Ein Spielstand mit eigenem Modset bekommt einen eigenen Mod-Ordner `server/data/mods-<name>` (Symlinks auf die passenden Zips in `~/.factorio/mods`, `mod-list.json`, `mod-settings.dat`, plus `pi-companion`). `server.sh start <name>` nimmt ihn automatisch. Den Spielstand vorher nach `server/data/saves/<name>.zip` kopieren; das Original in `~/.factorio/saves` bleibt unberührt.

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
