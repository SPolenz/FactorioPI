-- Shared to-do list for all players and Pi.
-- Players use the GUI (button "Todos" top left) or /todo; Pi uses the ops todos, todo_add, todo_update,
-- todo_remove and todo_clear_done over RCON. Every change is announced in chat and shown to everybody.

local mod_gui = require("mod-gui")

local M = {}

local PI_NAME = "Pi"
local DONE_COLOR = { 0.55, 0.55, 0.55 }
local TODO_MAX = 100

local function ensure()
  storage.todos = storage.todos or {}
  storage.todo_seq = storage.todo_seq or 0
  storage.todo_open = storage.todo_open or {} -- player_index -> true if the list is shown
end

local function find(id)
  id = tonumber(id)
  for i, t in ipairs(storage.todos) do
    if t.id == id then return t, i end
  end
end

local function announce(msg)
  game.print({ "", "[color=1,0.8,0.3][Todo][/color] ", msg })
end

local function line(t)
  local s = "#" .. t.id .. " " .. t.text
  if t.assignee then s = s .. " → " .. t.assignee end
  return s
end

-- ---------------------------------------------------------------------------
-- GUI
-- ---------------------------------------------------------------------------

local function assignee_items()
  local items = { { "pi-companion.todo-everybody" }, PI_NAME }
  for _, p in pairs(game.connected_players) do items[#items + 1] = p.name end
  return items
end

local function build(player)
  local flow = mod_gui.get_button_flow(player)
  if not flow.pi_todo_toggle then
    flow.add {
      type = "button", name = "pi_todo_toggle", style = mod_gui.button_style,
      caption = { "pi-companion.todo-title" }, tooltip = { "pi-companion.todo-toggle-tooltip" },
    }
  end
  local frames = mod_gui.get_frame_flow(player)
  -- Keep what the player is typing when the list changes under them.
  local typed, typed_for = "", nil
  local old = frames.pi_todo_frame
  if old then
    local row = old.pi_todo_add_row
    if row then
      typed = row.pi_todo_input.text
      local dd = row.pi_todo_assignee
      if dd.selected_index > 1 then typed_for = dd.get_item(dd.selected_index) end
    end
    old.destroy()
  end
  if not storage.todo_open[player.index] then return end

  local frame = frames.add { type = "frame", name = "pi_todo_frame", direction = "vertical", caption = { "pi-companion.todo-title" } }
  local list = frame.add { type = "scroll-pane", direction = "vertical" }
  list.style.maximal_height = 400
  if #storage.todos == 0 then
    list.add { type = "label", caption = { "pi-companion.todo-empty" } }
  end
  for _, t in ipairs(storage.todos) do
    local row = list.add { type = "flow", direction = "horizontal" }
    row.style.vertical_align = "center"
    row.add { type = "checkbox", state = t.done, tags = { pi_todo = t.id, action = "check" },
      tooltip = { "pi-companion.todo-check-tooltip" } }
    local label = row.add { type = "label", caption = line(t),
      tooltip = { "", { "pi-companion.todo-by" }, " ", t.by or "?" } }
    label.style.maximal_width = 320
    label.style.single_line = false
    if t.done then label.style.font_color = DONE_COLOR end
    row.add { type = "sprite-button", sprite = "utility/close", style = "mini_tool_button_red",
      tags = { pi_todo = t.id, action = "remove" }, tooltip = { "pi-companion.todo-remove-tooltip" } }
  end

  local add = frame.add { type = "flow", name = "pi_todo_add_row", direction = "horizontal" }
  add.style.vertical_align = "center"
  local field = add.add { type = "textfield", name = "pi_todo_input", text = typed }
  field.style.width = 200
  local items, selected = assignee_items(), 1
  for i, it in ipairs(items) do if it == typed_for then selected = i end end
  add.add { type = "drop-down", name = "pi_todo_assignee", items = items, selected_index = selected,
    tooltip = { "pi-companion.todo-assignee-tooltip" } }
  add.add { type = "button", name = "pi_todo_add", caption = "+", style = "tool_button",
    tooltip = { "pi-companion.todo-add-tooltip" } }
  if #storage.todos > 0 then
    frame.add { type = "button", name = "pi_todo_clear", caption = { "pi-companion.todo-clear" } }
  end
end

local function refresh_all()
  -- A GUI error must not take the game down; log it and keep going.
  for _, p in pairs(game.connected_players) do
    local ok, err = pcall(build, p)
    if not ok then log("pi-companion todo GUI: " .. tostring(err)) end
  end
end

-- ---------------------------------------------------------------------------
-- Core actions, shared by GUI, /todo and RCON ops
-- ---------------------------------------------------------------------------

local function add(text, by, assignee)
  ensure()
  text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then error("empty text") end
  if #storage.todos >= TODO_MAX then error("too many todos, clear the done ones first") end
  storage.todo_seq = storage.todo_seq + 1
  local t = { id = storage.todo_seq, text = text, by = by, assignee = assignee, done = false, tick = game.tick }
  storage.todos[#storage.todos + 1] = t
  announce({ "", by or "?", ": + ", line(t) })
  refresh_all()
  return t
end

local function set_done(id, done, by)
  ensure()
  local t = find(id)
  if not t then error("no todo #" .. tostring(id)) end
  t.done = done and true or false
  t.done_by = t.done and by or nil
  announce({ "", by or "?", t.done and ": ✔ " or ": ↺ ", line(t) })
  refresh_all()
  return t
end

local function remove(id, by)
  ensure()
  local t, i = find(id)
  if not t then error("no todo #" .. tostring(id)) end
  table.remove(storage.todos, i)
  announce({ "", by or "?", ": − ", line(t) })
  refresh_all()
  return t
end

local function clear_done(by)
  ensure()
  local keep, n = {}, 0
  for _, t in ipairs(storage.todos) do
    if t.done then n = n + 1 else keep[#keep + 1] = t end
  end
  storage.todos = keep
  if n > 0 then announce({ "", by or "?", ": ", { "pi-companion.todo-cleared", n } }) end
  refresh_all()
  return n
end

-- ---------------------------------------------------------------------------
-- RCON ops for Pi
-- ---------------------------------------------------------------------------

function M.register_ops(ops)
  function ops.todos(args)
    ensure()
    local out = {}
    for _, t in ipairs(storage.todos) do
      if args.all or not t.done then out[#out + 1] = t end
    end
    return { todos = out, open = #out }
  end

  function ops.todo_add(args)
    return add(args.text, args.by or PI_NAME, args.assignee)
  end

  -- {id, done?, text?, assignee?}; assignee "" clears it.
  function ops.todo_update(args)
    ensure()
    local t = find(args.id)
    if not t then error("no todo #" .. tostring(args.id)) end
    if args.text and args.text ~= "" then t.text = args.text end
    if args.assignee ~= nil then t.assignee = (args.assignee ~= "") and args.assignee or nil end
    if args.done ~= nil and (args.done and true or false) ~= t.done then
      return set_done(t.id, args.done, args.by or PI_NAME)
    end
    announce({ "", args.by or PI_NAME, ": ✎ ", line(t) })
    refresh_all()
    return t
  end

  function ops.todo_remove(args)
    return remove(args.id, args.by or PI_NAME)
  end

  function ops.todo_clear_done(args)
    return { removed = clear_done(args.by or PI_NAME) }
  end
end

-- ---------------------------------------------------------------------------
-- Player command /todo and GUI events
-- ---------------------------------------------------------------------------

local function command(cmd)
  local p = cmd.player_index and game.get_player(cmd.player_index)
  local by = p and p.name or "Server"
  local function reply(msg) if p then p.print(msg) else rcon.print(msg) end end
  local param = cmd.parameter or ""
  local verb, rest = param:match("^%s*(%S*)%s*(.-)%s*$")
  local ok, err = pcall(function()
    ensure()
    if verb == "" or verb == "list" then
      if #storage.todos == 0 then reply({ "pi-companion.todo-empty" }) end
      for _, t in ipairs(storage.todos) do reply((t.done and "✔ " or "☐ ") .. line(t)) end
    elseif verb == "done" then set_done(rest, true, by)
    elseif verb == "undo" then set_done(rest, false, by)
    elseif verb == "del" or verb == "remove" then remove(rest, by)
    elseif verb == "clear" then clear_done(by)
    elseif verb == "add" then
      local text, who = rest:match("^(.-)%s+@(%S+)$")
      add(text or rest, by, who)
    else
      -- "/todo Eisen holen @Max" adds directly.
      local text, who = param:match("^%s*(.-)%s+@(%S+)%s*$")
      add(text or param, by, who)
    end
  end)
  if not ok then reply({ "", "[Todo] ", (tostring(err):gsub("^.-:%d+: ", "")) }) end
end

local function on_click(e)
  local el = e.element
  if not (el and el.valid) then return end
  local p = game.get_player(e.player_index)
  if el.name == "pi_todo_toggle" then
    ensure()
    storage.todo_open[p.index] = not storage.todo_open[p.index] or nil
    build(p)
  elseif el.name == "pi_todo_add" then
    local row = el.parent
    local text = row.pi_todo_input.text
    if text:match("%S") then
      local dd = row.pi_todo_assignee
      local who = dd.selected_index > 1 and dd.get_item(dd.selected_index) or nil
      row.pi_todo_input.text = ""
      add(text, p.name, who)
    end
  elseif el.name == "pi_todo_clear" then
    clear_done(p.name)
  elseif el.tags and el.tags.action == "remove" then
    remove(el.tags.pi_todo, p.name)
  end
end

function M.init()
  ensure()
  refresh_all()
end

-- An error in a GUI handler would end the game for everybody; report it to the player instead.
local function safe(handler)
  return function(e)
    local ok, err = pcall(handler, e)
    if not ok then
      local p = e.player_index and game.get_player(e.player_index)
      if p then p.print({ "", "[Todo] ", (tostring(err):gsub("^.-:%d+: ", "")) }) end
    end
  end
end

function M.register_events()
  commands.add_command("todo", { "pi-companion.todo-help" }, command)
  script.on_event(defines.events.on_gui_click, safe(on_click))
  script.on_event(defines.events.on_gui_checked_state_changed, safe(function(e)
    local el = e.element
    if el.valid and el.tags and el.tags.action == "check" then
      set_done(el.tags.pi_todo, el.state, game.get_player(e.player_index).name)
    end
  end))
  script.on_event(defines.events.on_gui_confirmed, safe(function(e)
    local el = e.element
    if el.valid and el.name == "pi_todo_input" and el.text:match("%S") then
      local dd = el.parent.pi_todo_assignee
      local who = dd.selected_index > 1 and dd.get_item(dd.selected_index) or nil
      local text = el.text
      el.text = ""
      add(text, game.get_player(e.player_index).name, who)
    end
  end))
  -- Players joining or leaving change the assignee drop-down.
  script.on_event({ defines.events.on_player_joined_game, defines.events.on_player_left_game }, function()
    ensure()
    refresh_all()
  end)
end

return M
