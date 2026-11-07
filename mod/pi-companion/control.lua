-- pi-companion: bridge between Factorio and the Pi agent.
-- Protocol: RCON sends `/pi <json>` with {op=..., ...}; the reply is one JSON line via rcon.print.
-- Only the server console (RCON) may call /pi; players talk to Pi via chat ("@pi ...").

local PI_NAME = "Pi"
local PI_COLOR = { r = 0.4, g = 0.8, b = 1.0 }
local INBOX_MAX = 100
local todo = require("todo")

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
        p.print({ "pi-companion.thinking" }, { game_state = false })
      end
    end
  end
  storage.inbox = keep
  return { remaining = #keep }
end

-- ---------------------------------------------------------------------------
-- Rail network view. Condensed in Lua so that the reply stays small.
-- ---------------------------------------------------------------------------

local TRAIN_STATE = {}
for k, v in pairs(defines.train_state) do TRAIN_STATE[v] = k end

local RAIL_TYPES = {
  "straight-rail", "half-diagonal-rail", "curved-rail-a", "curved-rail-b",
  "elevated-straight-rail", "elevated-half-diagonal-rail", "elevated-curved-rail-a",
  "elevated-curved-rail-b", "legacy-straight-rail", "legacy-curved-rail", "rail-ramp",
}

local STUCK_TICKS = 60 * 60 -- waiting longer than this without activity counts as a problem

local function xy(pos) return { math.floor(pos.x), math.floor(pos.y) } end

-- Composition like "LL-CCCC-l": L = loco facing forward, l = loco facing backward,
-- C = cargo wagon, F = fluid wagon, A = artillery wagon.
local function composition(train)
  local back = {}
  for _, loco in pairs(train.locomotives.back_movers or {}) do back[loco.unit_number] = true end
  local s = {}
  for _, c in ipairs(train.carriages) do
    local t = c.type
    if t == "locomotive" then s[#s + 1] = back[c.unit_number] and "l" or "L"
    elseif t == "cargo-wagon" then s[#s + 1] = "C"
    elseif t == "fluid-wagon" then s[#s + 1] = "F"
    elseif t == "artillery-wagon" then s[#s + 1] = "A"
    else s[#s + 1] = "?" end
  end
  return table.concat(s)
end

-- Top n entries of the train's cargo (items and fluids), as "name:count".
local function cargo(train, n)
  local list = {}
  for _, it in pairs(train.get_contents()) do
    local name = it.name .. ((it.quality and it.quality ~= "normal") and ("@" .. it.quality) or "")
    list[#list + 1] = { name, it.count }
  end
  for name, amount in pairs(train.get_fluid_contents()) do list[#list + 1] = { name, math.floor(amount) } end
  table.sort(list, function(a, b) return a[2] > b[2] end)
  local out = {}
  for i = 1, math.min(n, #list) do out[i] = list[i][1] .. ":" .. list[i][2] end
  if #list > n then out[#out + 1] = "+" .. (#list - n) end
  return out
end

local function condition_text(c)
  local s = c.type
  if c.ticks then s = s .. " " .. math.floor(c.ticks / 60) .. "s" end
  local cond = c.condition
  if cond and cond.first_signal then
    local rhs = cond.second_signal and cond.second_signal.name or cond.constant
    s = s .. " " .. cond.first_signal.name .. (cond.comparator or "") .. tostring(rhs or "")
  elseif cond and cond.name then
    s = s .. " " .. cond.name
  end
  if c.station then s = s .. " " .. c.station end
  return (c.compare_type == "or" and "OR " or "") .. s
end

local function records_text(records, with_conditions)
  local out = {}
  for _, r in ipairs(records or {}) do
    local s = r.station or (r.rail and ("rail@" .. table.concat(xy(r.rail.position), ","))) or "?"
    if r.temporary then s = s .. " (temp)" end
    if with_conditions and r.wait_conditions and #r.wait_conditions > 0 then
      local conds = {}
      for _, c in ipairs(r.wait_conditions) do conds[#conds + 1] = condition_text(c) end
      s = s .. " [" .. table.concat(conds, ", ") .. "]"
    end
    out[#out + 1] = s
  end
  return out
end

-- Signature used to group trains that share the same schedule (with or without a train group).
local function schedule_info(train)
  local sched = train.get_schedule()
  local records = sched.get_records() or {}
  local interrupts = {}
  for _, i in ipairs(sched.get_interrupts() or {}) do interrupts[#interrupts + 1] = i.name end
  return sched, records, interrupts
end

-- Which train is train `t` waiting for? Walks along its path past its own rails and returns the
-- first other train that occupies a block ahead (chain signals look several blocks ahead).
local LOOKAHEAD_RAILS = 400
local function waits_for(train, all_trains)
  local path = train.path
  if not path or not path.valid then return nil end
  local rails = path.rails
  local own = {}
  for _, r in pairs(train.get_rails()) do own[r.unit_number] = true end
  local start = path.current or 1
  local checked_blocks = 0
  local here = rails[start]
  local last = here
  local function in_own_block(r)
    if here and r.is_rail_in_same_rail_block_as(here) then return true end
    for _, orail in pairs(train.get_rails()) do
      if r.is_rail_in_same_rail_block_as(orail) then return true end
    end
    return false
  end
  for i = start, math.min(#rails, start + LOOKAHEAD_RAILS) do
    local r = rails[i]
    if r and r.valid and not own[r.unit_number] and not (last and r.is_rail_in_same_rail_block_as(last))
      and not in_own_block(r) then
      last = r
      checked_blocks = checked_blocks + 1
      if r.trains_in_block > 0 then
        for _, other in pairs(all_trains) do
          if other.id ~= train.id and other.valid then
            for _, orail in pairs(other.get_rails()) do
              if orail.is_rail_in_same_rail_block_as(r) then return other.id, xy(r.position) end
            end
          end
        end
        return -1, xy(r.position) -- occupied, but by an unknown train
      end
      if checked_blocks > 6 then return nil end
    end
  end
  return nil
end

function ops.rails(args)
  local surface_filter = args.surface
  local limit = tonumber(args.limit) or 60
  local tm = game.train_manager
  local now = game.tick

  local surfaces = {}
  for _, s in pairs(game.surfaces) do
    if not surface_filter or s.name == surface_filter then
      local rails = s.count_entities_filtered { type = RAIL_TYPES }
      if rails > 0 then
        surfaces[s.name] = {
          rails = rails,
          signals = s.count_entities_filtered { type = "rail-signal" },
          chain_signals = s.count_entities_filtered { type = "rail-chain-signal" },
          stops = 0, trains = 0,
        }
      end
    end
  end

  -- Stations, grouped by name (several stops can share a name).
  local stations, station_order = {}, {}
  local stop_filter = { force = "player" }
  if surface_filter then stop_filter.surface = surface_filter end
  for _, stop in pairs(tm.get_train_stops(stop_filter)) do
    local key = stop.surface.name .. "/" .. stop.backer_name
    local st = stations[key]
    if not st then
      st = { name = stop.backer_name, surface = stop.surface.name, stops = 0, at = {}, incoming = 0, limit = 0, disabled = 0, unconnected = 0 }
      stations[key] = st
      station_order[#station_order + 1] = key
    end
    st.stops = st.stops + 1
    if #st.at < 3 then st.at[#st.at + 1] = xy(stop.position) end
    st.incoming = st.incoming + (stop.trains_count or 0)
    local lim = stop.trains_limit
    if lim and lim < 1000000 and st.limit then st.limit = st.limit + lim else st.limit = nil end
    local cb = stop.get_control_behavior()
    if cb and cb.disabled then st.disabled = st.disabled + 1 end
    if not stop.connected_rail then st.unconnected = st.unconnected + 1 end
    if surfaces[stop.surface.name] then surfaces[stop.surface.name].stops = surfaces[stop.surface.name].stops + 1 end
  end

  -- Trains, plus schedules deduplicated into "lines".
  local lines, line_order = {}, {}
  local trains, problems = {}, {}
  local referenced = {}
  local train_filter = { force = "player" }
  if surface_filter then train_filter.surface = surface_filter end
  local all = tm.get_trains(train_filter)
  for _, train in pairs(all) do
    local front = train.front_stock
    local sname = front and front.surface.name or "?"
    if surfaces[sname] then surfaces[sname].trains = surfaces[sname].trains + 1 end

    local sched, records, interrupts = schedule_info(train)
    local stops = records_text(records, false)
    for _, r in ipairs(records) do if r.station then referenced[sname .. "/" .. r.station] = true end end
    local key = train.group ~= "" and train.group and ("group:" .. train.group)
      or ("sched:" .. table.concat(stops, ">") .. "|" .. table.concat(interrupts, ","))
    local line = lines[key]
    if not line then
      line = {
        id = #line_order + 1,
        group = (train.group ~= "") and train.group or nil,
        stops = records_text(records, true),
        interrupts = interrupts,
        trains = 0,
      }
      lines[key] = line
      line_order[#line_order + 1] = key
    end
    line.trains = line.trains + 1

    local state = TRAIN_STATE[train.state] or tostring(train.state)
    local idle = now - (sched.tick_of_last_activity or now)
    local t = {
      id = train.id,
      line = line.id,
      comp = composition(train),
      state = state,
      at = front and xy(front.position) or nil,
      surface = sname,
      station = train.station and train.station.backer_name or nil,
      target = train.path_end_stop and train.path_end_stop.backer_name or nil,
      speed = math.floor(train.speed * 216 + 0.5), -- km/h
      idle_s = idle > 0 and math.floor(idle / 60) or nil,
      cargo = cargo(train, 3),
    }
    if train.manual_mode then t.manual = true end
    if state == "wait_signal" and train.signal then t.signal = xy(train.signal.position) end
    if state == "wait_signal" or (state == "destination_full" and not train.station) then
      t.waits_for, t.blocked_at = waits_for(train, all)
    end
    trains[#trains + 1] = t

    -- Problems
    if state == "no_path" then
      problems[#problems + 1] = string.format("train %d: no path (target %s)", train.id, t.target or (stops[sched.current] or "?"))
    elseif state == "no_schedule" then
      problems[#problems + 1] = string.format("train %d: no schedule at %s", train.id, table.concat(t.at or {}, ","))
    elseif state == "destination_full" and not train.station and idle >= STUCK_TICKS then
      -- Waiting at a station for a free destination is normal; waiting on the line blocks others.
      problems[#problems + 1] = string.format("train %d: destination full, waiting on the line at %s for %ds", train.id, table.concat(t.at or {}, ","), math.floor(idle / 60))
    elseif state == "wait_signal" and idle >= STUCK_TICKS then
      problems[#problems + 1] = string.format("train %d: waiting at signal %s for %ds", train.id, table.concat(t.signal or {}, ","), math.floor(idle / 60))
    elseif state == "wait_station" and idle >= 10 * STUCK_TICKS then
      problems[#problems + 1] = string.format("train %d: waiting at %s for %ds", train.id, t.station or "?", math.floor(idle / 60))
    end
  end

  local station_list = {}
  for _, key in ipairs(station_order) do
    local st = stations[key]
    if st.disabled == 0 then st.disabled = nil end
    if st.unconnected == 0 then st.unconnected = nil else
      problems[#problems + 1] = string.format("station %s: %d stop(s) without rail", st.name, st.unconnected)
    end
    if not referenced[key] then st.unused = true end
    station_list[#station_list + 1] = st
  end
  table.sort(station_list, function(a, b) return a.name < b.name end)
  for key in pairs(referenced) do
    if not stations[key] then
      problems[#problems + 1] = "schedule references missing station " .. key
    end
  end

  local line_list = {}
  for _, key in ipairs(line_order) do line_list[#line_list + 1] = lines[key] end

  -- Deadlocks: cycles in the waits-for graph.
  local wf = {}
  for _, t in ipairs(trains) do if t.waits_for and t.waits_for > 0 then wf[t.id] = t.waits_for end end
  local seen_cycle = {}
  for id in pairs(wf) do
    local path, pos, cur = {}, {}, id
    while cur and wf[cur] and not pos[cur] do
      pos[cur] = #path + 1
      path[#path + 1] = cur
      cur = wf[cur]
    end
    if cur and pos[cur] then
      local cycle = {}
      for i = pos[cur], #path do cycle[#cycle + 1] = path[i] end
      local minid = math.huge
      for _, c in ipairs(cycle) do minid = math.min(minid, c) end
      if not seen_cycle[minid] then
        seen_cycle[minid] = true
        local s = {}
        for _, c in ipairs(cycle) do s[#s + 1] = tostring(c) end
        problems[#problems + 1] = "DEADLOCK: trains " .. table.concat(s, " -> ") .. " -> " .. s[1]
      end
    end
  end

  table.sort(trains, function(a, b) return a.id < b.id end)
  local truncated = nil
  if #trains > limit then
    truncated = #trains - limit
    for i = #trains, limit + 1, -1 do trains[i] = nil end
  end

  return {
    tick = now,
    surfaces = surfaces,
    problems = problems,
    lines = line_list,
    stations = station_list,
    trains = trains,
    trains_truncated = truncated,
  }
end

-- ---------------------------------------------------------------------------
-- ASCII map of a rail area.
-- Legend: - | / \ rails, + crossing, H train stop,
--   rail signal o open / y reserved / x closed, chain signal O / Y / X,
--   letters = trains (see `trains` in the reply).
-- ---------------------------------------------------------------------------

local TRAIN_LETTERS = "ABCDEFGIJKLMNPQRSTUVWZabcdefghijkmnpqrstuvwz"
local MAX_CELLS = 24000

local function signal_char(sig)
  local st = sig.signal_state
  local c = (st == defines.signal_state.open) and "o"
    or (st == defines.signal_state.closed) and "x" or "y"
  if sig.type == "rail-chain-signal" then c = c:upper() end
  return c
end

function ops.map(args)
  local surface = game.get_surface(args.surface or "nauvis")
  if not surface then error("unknown surface") end
  local scale = tonumber(args.scale) or 1
  local x1, y1, x2, y2
  if args.x1 then
    x1, y1, x2, y2 = args.x1, args.y1, args.x2, args.y2
  else
    local r = tonumber(args.r) or 20
    x1, y1, x2, y2 = args.x - r, args.y - r, args.x + r, args.y + r
  end
  local w = math.floor((x2 - x1) / scale) + 1
  local h = math.floor((y2 - y1) / scale) + 1
  if w * h > MAX_CELLS then error(string.format("area too large: %dx%d cells (max %d), increase scale", w, h, MAX_CELLS)) end

  local grid = {}
  for row = 1, h do
    local line = {}
    for col = 1, w do line[col] = " " end
    grid[row] = line
  end
  local function cell(x, y)
    local col = math.floor((x - x1) / scale) + 1
    local row = math.floor((y - y1) / scale) + 1
    if col >= 1 and col <= w and row >= 1 and row <= h then return row, col end
  end
  local RAIL_CHARS = { ["-"] = true, ["|"] = true, ["/"] = true, ["\\"] = true, ["+"] = true }
  local function put_rail(x, y, ch)
    local row, col = cell(x, y)
    if not row then return end
    local cur = grid[row][col]
    if cur == " " then grid[row][col] = ch
    elseif RAIL_CHARS[cur] and cur ~= ch then grid[row][col] = "+" end
  end
  local function put(x, y, ch)
    local row, col = cell(x, y)
    if row then grid[row][col] = ch end
  end

  local area = { { x1 - 8, y1 - 8 }, { x2 + 8, y2 + 8 } }
  for _, rail in pairs(surface.find_entities_filtered { area = area, type = RAIL_TYPES }) do
    local a = rail.get_rail_end(defines.rail_direction.back).location.position
    local b = rail.get_rail_end(defines.rail_direction.front).location.position
    local dx, dy = b.x - a.x, b.y - a.y
    local steps = math.max(1, math.ceil(math.max(math.abs(dx), math.abs(dy)) * 2))
    for i = 0, steps do
      local f = i / steps
      local x, y = a.x + dx * f, a.y + dy * f
      -- local direction from the chord; good enough for curves at this resolution
      local ch
      local adx, ady = math.abs(dx), math.abs(dy)
      if ady * 2.4 < adx then ch = "-"
      elseif adx * 2.4 < ady then ch = "|"
      elseif (dx > 0) == (dy > 0) then ch = "\\"
      else ch = "/" end
      put_rail(x, y, ch)
    end
  end
  for _, stop in pairs(surface.find_entities_filtered { area = area, type = "train-stop" }) do
    put(stop.position.x, stop.position.y, "H")
  end
  for _, sig in pairs(surface.find_entities_filtered { area = area, type = { "rail-signal", "rail-chain-signal" } }) do
    put(sig.position.x, sig.position.y, signal_char(sig))
  end

  local letters, legend, n = {}, {}, 0
  local stock = surface.find_entities_filtered { area = area, type = { "locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon" } }
  for _, c in pairs(stock) do
    local train = c.train
    if train and not letters[train.id] then
      n = n + 1
      local ch = TRAIN_LETTERS:sub((n - 1) % #TRAIN_LETTERS + 1, (n - 1) % #TRAIN_LETTERS + 1)
      letters[train.id] = ch
      legend[#legend + 1] = {
        ch = ch, id = train.id, state = TRAIN_STATE[train.state],
        target = train.path_end_stop and train.path_end_stop.backer_name or nil,
        station = train.station and train.station.backer_name or nil,
        speed = math.floor(train.speed * 216 + 0.5),
      }
    end
    local ch = train and letters[train.id] or "?"
    local o = c.orientation * 2 * math.pi
    local ux, uy = math.sin(o), -math.cos(o)
    for t = -2.5, 2.5, 0.5 do put(c.position.x + ux * t, c.position.y + uy * t, ch) end
  end

  local rows = {}
  for row = 1, h do rows[row] = (table.concat(grid[row]):gsub("%s+$", "")) end
  return {
    area = { x1, y1, x2, y2 }, scale = scale,
    legend = "- | / \\ rail, + crossing, H stop, rail signal o open/y reserved/x closed, chain signal O/Y/X, letters = trains",
    rows = rows,
    trains = legend,
  }
end

-- Generic entity listing for an area: {x1,y1,x2,y2, surface?, type?|name?, limit?}
local DIRS = {}
for k, v in pairs(defines.direction) do DIRS[v] = k end
local SIGNAL_STATE = {}
for k, v in pairs(defines.signal_state) do SIGNAL_STATE[v] = k end

function ops.entities(args)
  local surface = game.get_surface(args.surface or "nauvis")
  if not surface then error("unknown surface") end
  local limit = tonumber(args.limit) or 200
  local filter = { area = { { args.x1, args.y1 }, { args.x2, args.y2 } }, type = args.type, name = args.name, limit = limit + 1 }
  local out = {}
  for _, e in pairs(surface.find_entities_filtered(filter)) do
    local o = { e.name, math.floor(e.position.x * 2) / 2, math.floor(e.position.y * 2) / 2, DIRS[e.direction] }
    if e.type == "rail-signal" or e.type == "rail-chain-signal" then o[5] = SIGNAL_STATE[e.signal_state] end
    if e.type == "train-stop" then o[5] = e.backer_name end
    out[#out + 1] = o
  end
  local truncated = #out > limit
  if truncated then out[#out] = nil end
  return { count = #out, truncated = truncated or nil, entities = out }
end

-- ---------------------------------------------------------------------------
-- Block check: where can a waiting train block foreign traffic?
--
-- Wait points: signals whose block can be entered through a rail signal (see is_wait_point).
-- From each wait point we walk back one train length. Every block the tail touches is occupied.
-- A touched block is a conflict if it has exits other than the ones on our way to the wait point
-- AND more than one entrance (crossing / merge+split). A split with a single entrance only causes
-- a queue in the same lane and is not reported.
-- ---------------------------------------------------------------------------

local OPP = {
  [defines.rail_direction.front] = defines.rail_direction.back,
  [defines.rail_direction.back] = defines.rail_direction.front,
}
local CONN = {
  defines.rail_connection_direction.left,
  defines.rail_connection_direction.straight,
  defines.rail_connection_direction.right,
}

local function longest_train()
  local best = 0
  for _, train in pairs(game.train_manager.get_trains { force = "player" }) do
    local len = 0
    for _, c in ipairs(train.carriages) do
      local p = c.prototype
      len = len + (p.joint_distance or 4) + (p.connection_distance or 3)
    end
    if len > best then best = len end
  end
  return best > 0 and best or 42
end

-- (rail, direction) pairs whose rail segment ends in signal `sig` for trains travelling `direction`.
local function approaches(sig)
  local out = {}
  for _, r in pairs(sig.get_connected_rails()) do
    for _, d in pairs(defines.rail_direction) do
      local s = r.get_rail_segment_signal(d, false)
      if s and s.unit_number == sig.unit_number then
        local dup = false
        for _, o in ipairs(out) do
          if o[1].is_rail_in_same_rail_segment_as(r) then dup = true break end
        end
        if not dup then out[#out + 1] = { r, d } end
      end
    end
  end
  return out
end

-- A train can only stop in front of a signal if it can enter that block through a rail signal
-- (or without any signal). Behind a chain signal the train has already reserved up to and
-- including the block after the next rail signal, so it never stops there - whatever the type.
local function is_wait_point(rail)
  local ins = rail.get_inbound_signals()
  if #ins == 0 then return true end
  for _, s in pairs(ins) do
    if s.type == "rail-signal" then return true end
  end
  return false
end

-- Returns nil if fine, else { fits = tiles until the conflicting block, block = length of the block
-- in front of the signal, ins, outs, other = position of a foreign exit signal }.
local function check_wait_point(sig, rail, dir, L)
  local worst
  local first_block
  local queue = { { rail, dir, 0, { [sig.unit_number] = true } } }
  local steps = 0
  while #queue > 0 and steps < 64 do
    steps = steps + 1
    local r, d, dist, allowed = table.unpack(table.remove(queue))
    local conflict = false
    local foreign
    for _, s in pairs(r.get_outbound_signals()) do
      if not allowed[s.unit_number] then foreign = s break end
    end
    if foreign then
      local ins = r.get_inbound_signals()
      if #ins > 1 then
        conflict = true
        if not worst or dist < worst.fits then
          worst = {
            fits = math.floor(dist), ins = #ins, outs = #r.get_outbound_signals(),
            other = xy(foreign.position),
          }
        end
      end
    end
    if not conflict then
      local len = r.get_rail_segment_length()
      local entry = r.get_rail_segment_signal(OPP[d], true)
      if entry and (not first_block or dist + len < first_block) then first_block = dist + len end
      if dist + len < L then
        local back_rail, back_dir = r.get_rail_segment_end(OPP[d])
        local nallowed = allowed
        if entry then
          nallowed = {}
          for k in pairs(allowed) do nallowed[k] = true end
          nallowed[entry.unit_number] = true
        end
        for _, c in ipairs(CONN) do
          local nr, ndir = back_rail.get_connected_rail { rail_direction = back_dir, rail_connection_direction = c }
          if nr then queue[#queue + 1] = { nr, ndir, dist + len, nallowed } end
        end
      end
    end
  end
  if worst then worst.block = first_block and math.floor(first_block) or nil end
  return worst
end

function ops.blockcheck(args)
  local surface = game.get_surface(args.surface or "nauvis")
  if not surface then error("unknown surface") end
  local L = tonumber(args.train_length) or longest_train()
  local filter = { type = { "rail-signal", "rail-chain-signal" }, force = "player" }
  if args.x1 then filter.area = { { args.x1, args.y1 }, { args.x2, args.y2 } } end
  local signals = surface.find_entities_filtered(filter)

  local conflicts, wait_points = {}, 0
  for _, sig in pairs(signals) do
    for _, a in ipairs(approaches(sig)) do
      if is_wait_point(a[1]) then
        wait_points = wait_points + 1
        local c = check_wait_point(sig, a[1], a[2], L)
        if c then
          c.at = xy(sig.position)
          c.kind = sig.type == "rail-chain-signal" and "chain" or "rail"
          c.facing = DIRS[sig.direction]
          conflicts[#conflicts + 1] = c
        end
      end
    end
  end

  -- Cluster nearby conflicts (one junction usually yields several).
  local R = tonumber(args.cluster_radius) or 48
  local clusters = {}
  for _, c in ipairs(conflicts) do
    local home
    for _, cl in ipairs(clusters) do
      if math.abs(cl.at[1] - c.at[1]) <= R and math.abs(cl.at[2] - c.at[2]) <= R then home = cl break end
    end
    if not home then
      home = { at = c.at, n = 0, worst_fits = math.huge, signals = {} }
      clusters[#clusters + 1] = home
    end
    home.n = home.n + 1
    home.worst_fits = math.min(home.worst_fits, c.fits)
    home.signals[#home.signals + 1] = c
  end
  for _, cl in ipairs(clusters) do
    local sx, sy = 0, 0
    for _, c in ipairs(cl.signals) do sx, sy = sx + c.at[1], sy + c.at[2] end
    cl.at = { math.floor(sx / cl.n), math.floor(sy / cl.n) }
    table.sort(cl.signals, function(a, b) return a.fits < b.fits end)
  end
  table.sort(clusters, function(a, b) return a.n > b.n end)

  local limit = tonumber(args.limit) or 30
  local detail = args.detail
  local out = {}
  for i = 1, math.min(limit, #clusters) do
    local cl = clusters[i]
    if not detail then
      local sig = {}
      for j = 1, math.min(4, #cl.signals) do
        local c = cl.signals[j]
        sig[j] = string.format("%s %d,%d %s fits %d", c.kind, c.at[1], c.at[2], c.facing or "?", c.fits)
      end
      cl.signals = sig
    end
    out[i] = cl
  end
  return {
    train_length = L,
    signals = #signals,
    wait_points = wait_points,
    conflicts = #conflicts,
    junctions = #clusters,
    clusters = out,
  }
end

local function handle(cmd)
  if cmd.player_index then
    local p = game.get_player(cmd.player_index)
    if p then p.print({ "pi-companion.reserved" }) end
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
  commands.add_command("pi", { "pi-companion.command-help" }, handle)
end

todo.register_ops(ops)
todo.register_events()

script.on_init(function()
  ensure_storage()
  todo.init()
end)
script.on_configuration_changed(function()
  ensure_storage()
  todo.init()
end)

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
