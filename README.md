# FactorioPI

Another playground connecting the top two games in town: Factorio and AI.

An AI co-player for Factorio, built on the [Pi coding agent](https://www.npmjs.com/package/@earendil-works/pi-coding-agent). Pi reads a compact view of your factory, answers questions in game chat (`@pi …`) and acts as a planner and advisor. Its current focus is rail networks: deadlocks, signalling and block lengths.

Pi never uses `/c` console commands, so achievements stay enabled. Everything runs through a small companion mod that only the server console (RCON) can control.

## Components

| Path | What it is |
|---|---|
| `mod/pi-companion/` | Companion mod (Lua). Registers `/pi <json>`; refuses calls from players. Published on the mod portal as `pi-companion`. |
| `pi-extension/` | Pi extension: tools `factorio_call` / `factorio_say`, chat bridge, RCON client. |
| `mcp-server/` | MCP server (stdio, no dependencies) for Claude Desktop, Claude Code and other MCP clients. |
| `server/server.sh` | Optional local dedicated server with its own data directory (does not touch `~/.factorio`). |
| `tools/rcon.py` | Minimal RCON client for testing. |
| `tools/package-mod.sh` | Builds `dist/pi-companion_<version>.zip`. |

## Setup

1. Install the mod `pi-companion` (mod portal, or copy the zip from `tools/package-mod.sh` into your mods folder). Everybody in the game needs the same version; with the portal Factorio downloads it on join.
2. Enable RCON on the hosting machine:
   - **Hosting from the game menu:** in `config.ini` (Linux `~/.factorio/config/config.ini`, Windows `%APPDATA%\Factorio\config\config.ini`) set
     ```ini
     local-rcon-socket=0.0.0.0:27015
     local-rcon-password=<secret>
     ```
     Open port 27015 in the firewall for the machine that runs Pi only. Use `127.0.0.1:27015` if Pi runs on the hosting machine.
   - **Dedicated server:** `server/server.sh create <name> [map-gen-settings.json]` / `server/server.sh start <name>`. `server/map-gen-relaxed.json` gives a relaxed map (peaceful biters, rich ore, no cliffs). Without Space Age: put a `mod-list.json` with only `base` and `pi-companion` enabled into `server/data/mods-<name>/` before `create`. RCON binds to `127.0.0.1:27015`, the password is generated into `server/.env`.
3. Add `pi-extension/` as a local package in `~/.pi/agent/settings.json` and point it at the host:
   ```bash
   export FACTORIO_RCON_HOST=game-host.example   # default 127.0.0.1
   export FACTORIO_RCON_PORT=27015
   export FACTORIO_RCON_PASSWORD=<secret>   # default: RCON_PASSWORD from server/.env
   ```

Alternatively, configure the extension in the git-ignored `server/.env` (plain, unquoted `KEY=value` lines, not shell expressions):

```dotenv
RCON_HOST=game-host.example
RCON_PORT=27015
RCON_PASSWORD=<secret>
```

Each `FACTORIO_RCON_*` environment variable overrides its matching file value. Without host/port settings the defaults remain `127.0.0.1:27015`; the password is required. Ports must be integers from 1 to 65535. After editing the file, run `/reload` in Pi to close the old connection and load the new settings. `/factorio status` and the bridge status show the target host and port, never the password. This file configures the extension; it does not change the server's listening address or port.

The usual setup: the machine that hosts the game sits in the LAN of the hosting player, Pi connects over the LAN.

## Using it

- In game chat: `@pi where is my iron plate bottleneck?` Pi answers as `[Pi]`.
- Shared to-do list: button **Todos** top left, or `/todo Eisen holen @Max`, `/todo done 3`, `/todo del 3`, `/todo clear`. Pi reads and writes the same list.
- Works with the base game alone; Space Age is optional.
- In Pi: `/factorio on|off|status` switches the chat bridge; `FACTORIO_PI_BRIDGE=off` starts without it.
- Testing from a shell:
  ```bash
  tools/rcon.py --op ping
  tools/rcon.py --op rails '{"limit":10}'
  ```

## Claude Desktop (MCP server)

`mcp-server/` exposes the mod as an MCP server. It needs Node.js 22.18 or newer (Windows: `winget install OpenJS.NodeJS.LTS`, then restart Claude Desktop completely) and no `npm install`. With an older Node the server writes what to do into the Claude Desktop MCP log (Settings → Developer). If Node is missing entirely Claude Desktop only reports `spawn node ENOENT`: install Node as above.

Tools: `factorio_summary`, `factorio_rails`, `factorio_map`, `factorio_entities`, `factorio_blockcheck`, `factorio_todos`, `factorio_todo_add`, `factorio_todo_update`, `factorio_say`, `factorio_inbox` and the generic fallback `factorio_call {op, args}`. Resource: `factorio://inbox`.

Add it to `claude_desktop_config.json` (Claude Desktop: Settings → Developer → Edit Config; Windows `%APPDATA%\Claude\`, macOS `~/Library/Application Support/Claude/`) and restart Claude Desktop:

```json
{
  "mcpServers": {
    "factorio": {
      "command": "node",
      "args": ["C:\\path\\to\\FactorioPI\\mcp-server\\start.mjs"],
      "env": {
        "FACTORIO_RCON_HOST": "127.0.0.1",
        "FACTORIO_RCON_PORT": "27015",
        "FACTORIO_RCON_PASSWORD": "<secret>"
      }
    }
  }
}
```

Instead of the `FACTORIO_RCON_*` variables you can set `FACTORIO_ENV_FILE` to a `.env` file with `RCON_HOST`, `RCON_PORT`, `RCON_PASSWORD`. Optional: `FACTORIO_POLL_MS` (inbox poll interval, default 3000, `0` off), `FACTORIO_NOTIFY_IN_GAME=off` (no in-game hint). Claude Code: `claude mcp add factorio -- node /path/to/mcp-server/start.mjs` (same env variables).

Test without Claude: `npx @modelcontextprotocol/inspector node mcp-server/start.mjs`; offline tests: `cd mcp-server && npm test`.

### Limitation: the game cannot wake up Claude Desktop

A Claude Desktop conversation only runs when the user writes in it. An MCP server cannot start a turn, so `@pi` messages in game chat are not answered by themselves. What the server does instead:

- **A, pull:** the server instructions tell Claude to call `factorio_inbox` at the start of a conversation; it returns the open messages and marks them as read. In game, players get the hint "Nachricht gesehen. Ich antworte, sobald jemand in Claude Desktop mit mir spricht." (once per new message batch).
- **B, push:** the server polls the inbox and sends `notifications/resources/updated` for `factorio://inbox` (if subscribed) and a `notifications/message` log entry. Claude Desktop currently shows these at most in its MCP log and does not start a turn; clients that react to them get them for free.

For a real chat co-player use an agent that can be triggered from outside:

- **Pi** (`pi-extension/`): the chat bridge starts a turn for every `@pi` message. This is the full experience today.
- **Claude Code**: same MCP server, plus a loop that triggers turns, e.g. a small script that waits for new inbox messages and runs `claude -p "Answer the open Factorio chat messages" --mcp-config …` (headless), or `claude --continue` to keep the conversation. Possible follow-up: a `--wait` mode in the MCP server tooling for this.

## Mod ops

Called as `/pi {"op":"<name>", ...args}` over RCON. Results are JSON.

- `ping`, `summary`: tick, players, surfaces, research, mods.
- `say {text}`: chat message as `[Pi]`.
- `inbox`, `ack {upto, notify?}`: chat messages starting with `@pi`; `notify` tells the sender that Pi is thinking.
- `rails {surface?, limit?}`: rail network in compact form. Problems (including `DEADLOCK: trains a -> b -> … -> a` from the wait graph), lines (schedules per train group), stations, trains with state, target, cargo and `waits_for`.
- `map {x, y, r}` or `{x1, y1, x2, y2, scale?}`: ASCII map. `- | / \` rails, `+` crossing, `H` stop, signals `o`/`y`/`x` (open/reserved/closed), chain signals `O`/`Y`/`X`, letters = trains.
- `entities {x1, y1, x2, y2, type?|name?, limit?}`: entities in an area with position, direction and signal state. A signal faces the oncoming train.
- `todos {all?}`, `todo_add {text, assignee?}`, `todo_update {id, done?, text?, assignee?}`, `todo_remove {id}`, `todo_clear_done`: shared to-do list; every change is announced in chat.
- `blockcheck {x1?, y1?, x2?, y2?, train_length?, cluster_radius?, limit?, detail?}`: signalling check. A train can stop in front of a signal if it can enter that block through a rail signal. From each such point the check walks back one train length; if the train touches a block with foreign exits and more than one entrance, it blocks other traffic. `fits` = tiles until that block, 0 = the stop point is inside a junction. Results are grouped by junction.

## Real save games

A save with its own mod set gets its own mod folder `server/data/mods-<name>` (symlinks to the matching zips in `~/.factorio/mods`, `mod-list.json`, `mod-settings.dat`, plus `pi-companion`). `server.sh start <name>` picks it up automatically. Copy the save to `server/data/saves/<name>.zip` first; the original stays untouched.

## Dedicated server as a service (optional)

```bash
systemctl --user link "$PWD/server/systemd/factorio-pi.service"   # adjust ExecStart path first
systemctl --user enable --now factorio-pi
journalctl --user -u factorio-pi -f
```

## Extension tests

With Node.js 22.19 or newer:

```bash
cd pi-extension && npm test
```

## License

MIT, see `LICENSE`.
