# Agent notes

- Start every session with `ROADMAP.md` (status, next steps, decisions) and `README.md` (setup, ops).
- At the end of a session update `ROADMAP.md`: move finished items to Done, add new findings and decisions with date.
- Never use `/c` or other console commands in the game: achievements must stay enabled. All game access goes through the `pi-companion` mod (`/pi` over RCON).
- Change the game world only after confirmation in chat; prefer ghosts and blueprints that robots build.
- After changing `mod/pi-companion/` restart the server. Bump the version in `info.json` and `changelog.txt` before every distribution or portal upload.
- The repo is public: no passwords, IP addresses, private paths or personal e-mail addresses in files or commits. `server/data/` and `server/.env` stay ignored.
- Factorio API docs: `doc-html/runtime-api.json` and `prototype-api.json` in the Factorio install directory.
