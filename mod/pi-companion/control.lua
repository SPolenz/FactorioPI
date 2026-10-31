-- pi-companion: bridge between Factorio and the Pi agent.
-- Protocol: RCON sends `/pi <json>` with {op=..., ...}; the reply is one JSON line via rcon.print.
-- Only the server console (RCON) may call /pi; players talk to Pi via chat ("@pi ...").

local PI_NAME = "Pi"
local PI_COLOR = { r = 0.4, g = 0.8, b = 1.0 }
local INBOX_MAX = 100

local function ensure_storage()
  storage.inbox = storage.inbox or {}
  storage.inbox_seq = storage.inbox_seq or 0
end

local ops = {}

function ops.ping(_)
  return { pong = true, tick = game.tick, version = script.active_mods["pi-companion"] }
end

function ops.summary(_)
  local players = {}
  for _, p in pairs(game.connected_players) do
    local pos = p.physical_position or p.position
    players[#players + 1] = {
      name = p.name,
      surface = p.surface.name,
      x = math.floor(pos.x), y = math.floor(pos.y),
      controller = p.controller_type,
    }
  end
  local surfaces = {}
  for _, s in pairs(game.surfaces) do surfaces[#surfaces + 1] = s.name end
  local force = game.forces.player
  local research = force.current_research
  return {
    tick = game.tick,
    hours = math.floor(game.tick / 216000 * 10) / 10,
    players = players,
    surfaces = surfaces,
    research = research and research.name or nil,
    research_progress = research and math.floor(force.research_progress * 100) or nil,
    mods = script.active_mods,
  }
end

-- Send a chat message as Pi.
function ops.say(args)
  game.print({ "", "[color=0.4,0.8,1][Pi][/color] ", tostring(args.text or "") }, { color = PI_COLOR })
  return { ok = true }
end

-- Chat messages addressed to Pi that have not been acknowledged yet.
function ops.inbox(_)
  ensure_storage()
  return { messages = storage.inbox }
end

-- Acknowledge messages up to seq (inclusive); optionally tell the senders that Pi is on it.
function ops.ack(args)
  ensure_storage()
  local upto = tonumber(args.upto) or 0
  local keep, notified = {}, {}
  for _, m in ipairs(storage.inbox) do
    if m.seq > upto then
      keep[#keep + 1] = m
    elseif args.notify and m.player and not notified[m.player] then
      notified[m.player] = true
      local p = game.get_player(m.player)
      if p and p.connected then
        p.print("[color=0.6,0.6,0.6][Pi] denkt nach ...[/color]", { game_state = false })
      end
    end
  end
  storage.inbox = keep
  return { remaining = #keep }
end

local function handle(cmd)
  if cmd.player_index then
    local p = game.get_player(cmd.player_index)
    if p then p.print("/pi is reserved for the Pi bridge. Write '@pi ...' in chat instead.") end
    return
  end
  local ok, result = pcall(function()
    local args = {}
    if cmd.parameter and cmd.parameter ~= "" then
      args = helpers.json_to_table(cmd.parameter)
      if type(args) ~= "table" then error("invalid JSON parameter") end
    end
    local fn = ops[args.op or "ping"]
    if not fn then error("unknown op: " .. tostring(args.op)) end
    return fn(args)
  end)
  if ok then
    rcon.print(helpers.table_to_json({ ok = true, data = result }))
  else
    rcon.print(helpers.table_to_json({ ok = false, error = tostring(result) }))
  end
end

local function register()
  commands.add_command("pi", "Pi bridge (server console only)", handle)
end

script.on_init(function()
  ensure_storage()
end)
script.on_configuration_changed(ensure_storage)

script.on_event(defines.events.on_console_chat, function(e)
  if not e.player_index or not e.message then return end
  local text = e.message:match("^%s*@[Pp][Ii][%s:,]*(.*)$")
  if not text then return end
  ensure_storage()
  storage.inbox_seq = storage.inbox_seq + 1
  local p = game.get_player(e.player_index)
  local inbox = storage.inbox
  inbox[#inbox + 1] = { seq = storage.inbox_seq, tick = e.tick, player = p and p.name, text = text }
  if #inbox > INBOX_MAX then table.remove(inbox, 1) end
end)

register()
