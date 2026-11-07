# Roadmap and status

Single place for where we stand. Read it at the start of a session, update it at the end.
Last update: 2026-11-07

## Goal

Pi plays Factorio with us as planner and advisor: it reads the factory, explains problems, proposes fixes as ghosts or blueprints that the construction robots build, and talks in game chat (`@pi …`). Focus: rail networks. No `/c` commands, achievements stay enabled.

## Milestones

1. Get at the game state ✅
2. Interpret the state efficiently (compact views) 🔄 rails done, production open
3. Change things in the game (ghosts, blueprints)
4. Understand Factorio concepts well enough to give good advice

## Done

- Companion mod `pi-companion` with `/pi` over RCON, chat inbox, `[Pi]` replies.
- Pi extension: `factorio_call`, `factorio_say`, chat bridge.
- Local dedicated server per save game with its own mod folder.
- Rail views: `rails` (lines, trains, wait graph, deadlock detection), `map` (ASCII), `entities`.
- `blockcheck`: signals where a waiting train blocks other traffic.
- Repo public on GitHub.
- `pi-companion` 0.2.0 published on the mod portal (2026-11-07, `tools/publish-mod.sh`).
- Shared to-do list in the mod: GUI button "Todos", `/todo`, ops `todos`, `todo_add`, `todo_update`, `todo_remove`, `todo_clear_done`.
- Base-game server without Space Age: save `vanilla` with `server/data/mods-vanilla` (only `base` + `pi-companion`) and relaxed map settings `server/map-gen-relaxed.json`.

## Now

- [ ] Push to GitHub.
- [ ] Multiplayer test on save `vanilla` (2026-11-07): second player without Space Age joins, mod downloads from the portal; test the to-do GUI with two players.
- [ ] Then: host from the other PC with RCON over LAN.

## Next

- [ ] `blockcheck`: find the recurring junction types behind the 191 flagged junctions and propose a corrected version for the worst one.
- [ ] Fix proposals as ghosts (signal swaps rail ↔ chain, signal moves), placed only after confirmation in chat.
- [ ] Production view: throughput and bottlenecks per item.

## Later

- [ ] Decode and repair blueprint strings offline (base64 + zlib + JSON).
- [ ] Look at the Factorio Learning Environment (FLE) for ideas on turning state into text.
- [ ] Stations as wait points in `blockcheck`.
- [ ] Offer a remote interface PR to the Todo List mod (jonasjurczok/factorio-todo-list), then Pi could use it instead of our own list.

## Findings in our game (save "rainer", Nauvis)

- Two deadlocks (8 trains, stuck ~6.6 h) on the east–west double track y≈-810 at the junctions x≈90/270/450; the grid repeats every 180 tiles. Cause at x≈270: exit blocks of 19 tiles for 42-tile trains, rail signals inside the junction instead of chain signals.
- `blockcheck`: 2,511 wait points, 319 conflicts in 191 junctions; 114 with a wait point inside the junction, 77 with too-short exit blocks. Worst: (-454,-636), one block with 10 entrances and 11 exits.

## Decisions

- 2026-11-03: Publish on the mod portal as `pi-companion`, author SPolenz, MIT license, source on GitHub `SPolenz/FactorioPI`. Publish only when we want to test.
- 2026-11-03: Default setup: the hosting PC is in the LAN of the hosting player; Pi connects via `FACTORIO_RCON_HOST`.
- 2026-11-03: A signal is a wait point if its block can be entered through a rail signal; behind chain signals a train never stops.
- 2026-11-07: Own to-do list in `pi-companion` instead of an existing mod: Todo List, Task List, Mission Tasks, JOLT and Set Objective have no remote interface, so Pi could only reach them with `/c`.
- 2026-11-07: Portal uploads with an API key kept in `~/.config/factorio/api-key` (outside the repo).
- Mod version must be bumped before every distribution, otherwise clients fail with a checksum mismatch.
