-- The link between a Zenith add-on and a Factorio mod of its own (`ext`, PROTOCOL.md "Messages for
-- add-ons and their mods"; docs/ADDONS.md "Messages to your Factorio mod"). The add-on's messages
-- arrive as a custom event other mods listen to, and mods answer through the `zenith` remote
-- interface (console.lua adds these calls to it). The bridge only carries the messages: it never
-- reads what is inside, changes nothing in the game for them and runs no Lua from them.
--
-- Determinism: a packet reaches every peer as an input action, so the handler, the raised event and
-- the other mods' handlers run the same on each. The caps count in the client's state in `storage`.
-- The list of events to raise is module-local, but it is filled and emptied within one event
-- (control.lua raises it after the packet's handler and after the tick's clients are served), so it
-- never differs between peers and is always empty when the game is saved. The one exception is
-- on_configuration_changed: its events wait in `storage` for the first raise after it (M.later).
--
-- A companion mod's error: each event is raised in its own pcall, so one handler's error doesn't
-- lose the events after it, and a client's packet never stops the game (AGENTS.md). The error is
-- logged naming the mod and sent back to the add-on on its channel (`ext` with `err`); after
-- MAX_ERRORS on a channel within ERROR_WINDOW ticks that channel is closed for the client's
-- session. The counts are in the client's state in `storage`, so every peer closes it alike.

local transport = require("scripts.transport")
local puppet = require("scripts.puppet")

local M = {}

-- The link's version (the welcome's `ext`, the interface's link()).
M.VERSION = 1
-- A message: the whole datagram line at most this many bytes, both ways.
M.MAX_BYTES = 4096
-- A channel: "<factorio mod>[/<topic>]", at most this many bytes.
M.MAX_CHANNEL = 128
-- Per client, each way counted apart: at most MAX_MESSAGES and MAX_WINDOW_BYTES every WINDOW ticks.
M.WINDOW = 60
M.MAX_MESSAGES = 60
M.MAX_WINDOW_BYTES = 32768
-- A channel whose mod's handler failed this many times within ERROR_WINDOW ticks is closed.
M.MAX_ERRORS = 10
M.ERROR_WINDOW = 3600
-- An error's text sent back at most this many bytes; the first LOG_FIRST errors logged in full,
-- after that a count every LOG_EVERY.
M.MAX_ERROR_TEXT = 1000
local LOG_FIRST = 5
local LOG_EVERY = 100
-- The bridge's own mod: no add-on's channel.
local BRIDGE_MOD = "factorio-3d-bridge"

-- Made in the main chunk, unconditionally, so every peer makes the same ids in the same order on
-- each load (Factorio doesn't save them: other mods ask for them in on_init and on_load).
local ON_MESSAGE = script.generate_event_name()
local ON_CLIENT = script.generate_event_name()

local session  -- session.lua (M.attach): its states, without requiring it back
local pending = {}  -- {event id, data}: raised by M.raise, within the same event
-- The packet being handled (M.from_packet): its size and the machine it came in on.
local packet_bytes, packet_machine = 0, 0
local warned = false
local errors_seen = 0  -- (only gates log lines)
local state_of  -- (below)

function M.attach(s)
  session = s
end

-- session.on_packet, for each packet before its handler runs.
function M.from_packet(event)
  packet_bytes = type(event.payload) == "string" and #event.payload or 0
  packet_machine = tonumber(event.player_index) or 0
end

local function dropped(why)
  if not warned then
    warned = true
    log("[Zenith] an add-on's message was dropped (" .. why .. "); later ones are dropped without a note")
  end
end

-- The mod a channel is for, or nil when it isn't a channel: a mod name ([A-Za-z0-9_-]), optionally
-- "/" and a topic without control characters. The bridge's own name isn't a channel.
function M.channel_mod(ch)
  if type(ch) ~= "string" or #ch == 0 or #ch > M.MAX_CHANNEL then
    return nil
  end
  local mod, rest = ch:match("^([%w_%-]+)(.*)$")
  if not mod or mod == BRIDGE_MOD or (rest ~= "" and (rest:sub(1, 1) ~= "/" or rest:find("%c"))) then
    return nil
  end
  return mod
end

-- Counts a message of `bytes` one way ("i" in, "o" out) for the client `s`; false over the caps.
local function counted(s, way, bytes)
  local l = s.link
  if not l or game.tick - l.w >= M.WINDOW or game.tick < l.w then
    l = { w = game.tick, i = 0, ib = 0, o = 0, ob = 0 }
    s.link = l
  end
  if l[way] + 1 > M.MAX_MESSAGES or l[way .. "b"] + bytes > M.MAX_WINDOW_BYTES then
    return false
  end
  l[way] = l[way] + 1
  l[way .. "b"] = l[way .. "b"] + bytes
  return true
end

-- The index of the player playing the served client's character, nil for the bridge's own.
local function player_index()
  local c = puppet.get()
  local p = c and puppet.player_of(c)
  return p and p.index or nil
end

---------------------------------------------------------------------------------------------
-- In: {t = "ext", ch, d} from a client (session.lua's handler, the client's state served)

function M.receive(msg, port)
  local mod = M.channel_mod(msg.ch)
  local s = storage.f3d
  if session.handshaking() then
    return dropped("its client's handshake isn't done")
  elseif not mod then
    return dropped("not a channel")
  elseif s.link_closed and s.link_closed[msg.ch] then
    return  -- (said once when it closed)
  elseif msg.d == nil then
    return dropped("no data")
  elseif not script.active_mods[mod] then
    return dropped("the mod " .. mod .. " isn't in this game")
  elseif packet_bytes > M.MAX_BYTES then
    return dropped("over " .. M.MAX_BYTES .. " bytes")
  elseif not counted(s, "i", packet_bytes) then
    return dropped("too many from one client")
  end
  pending[#pending + 1] = { ON_MESSAGE, { client = port, channel = msg.ch, data = msg.d,
    player_index = player_index(), machine = packet_machine } }
end

-- A client came (its first hello) or went (a goodbye, its timeout, another taking its place).
function M.client_changed(port, joined)
  -- (A channel closed after repeated errors stays closed for the client's session: until now.)
  storage.f3d.link_err, storage.f3d.link_closed = nil, nil
  if type(port) == "number" then
    pending[#pending + 1] = { ON_CLIENT, { client = port, joined = joined, player_index = joined and player_index() or nil } }
  end
end

-- on_configuration_changed: its events (clients a new bridge version dropped) wait in `storage`
-- for the first raise after it. Raised there, a companion mod's handler would run before that mod's
-- own on_configuration_changed has migrated its `storage` (it runs after the bridge's).
function M.later()
  if #pending == 0 then
    return
  end
  local later = storage.f3d_link_later or {}
  for _, e in ipairs(pending) do
    later[#later + 1] = { e[1] == ON_CLIENT and "client" or "message", e[2] }
  end
  storage.f3d_link_later = later
  pending = {}
end

local function trimmed(text)
  text = tostring(text)
  if #text > M.MAX_ERROR_TEXT then
    -- (Cut at a character's start: half a UTF-8 character isn't JSON text.)
    text = text:sub(1, M.MAX_ERROR_TEXT - 3):gsub("[\192-\255][\128-\191]*$", "") .. "..."
  end
  return text
end

-- Tells client `port`'s add-on on `channel` of an error: {t = "ext", ch, err}.
local function tell(port, channel, text)
  local s = state_of(port)
  if not s then
    return
  end
  local fields = ',"ch":' .. transport.json_string(channel) .. ',"err":' .. transport.json_string(text)
  if s == storage.f3d then
    transport.send_text("ext", fields)
  else
    session.serve(s, transport.send_text, "ext", fields)
  end
end

-- A companion mod's handler failed on event `data` (an on_message's when it has a channel).
local function failed(data, err)
  errors_seen = errors_seen + 1
  local channel = data.channel
  local text = trimmed(err)
  local mod = channel and M.channel_mod(channel)
  if errors_seen <= LOG_FIRST then
    log("[Zenith] " .. (mod and ("the mod " .. mod .. "'s handler failed on the channel " .. channel)
      or "a mod's on_client handler failed") .. ": " .. text)
  elseif errors_seen % LOG_EVERY == 0 then
    log("[Zenith] " .. errors_seen .. " errors from mods' handlers of add-on messages so far (only counted now)")
  end
  if not channel then
    return
  end
  tell(data.client, channel, text)
  -- Counted in the client's state, the same on every peer.
  local s = state_of(data.client)
  if not s then
    return
  end
  local errs = s.link_err or {}
  s.link_err = errs
  local e = errs[channel]
  if not e or game.tick - e.w >= M.ERROR_WINDOW or game.tick < e.w then
    e = { w = game.tick, n = 0 }
    errs[channel] = e
  end
  e.n = e.n + 1
  if e.n >= M.MAX_ERRORS then
    errs[channel] = nil
    s.link_closed = s.link_closed or {}
    s.link_closed[channel] = true
    local why = "closed after repeated errors (" .. M.MAX_ERRORS .. " within " .. (M.ERROR_WINDOW / 60) .. " s)"
    log("[Zenith] the channel " .. channel .. " (the mod " .. tostring(mod) .. ") is " .. why
      .. ": the bridge drops its messages until the client connects again")
    tell(data.client, channel, why)
  end
end

local function raised(id, data)
  local ok, err = pcall(script.raise_event, id, data)
  if not ok then
    failed(data, err)
  end
end

-- Raises what came in (control.lua, after each packet's handler and after the tick's clients were
-- served, so a mod calling back into `zenith` from its handler never sees one client's state
-- swapped in for another's: session.serve). What on_configuration_changed left goes first.
function M.raise()
  local later = storage.f3d_link_later
  if later then
    storage.f3d_link_later = nil
    for _, e in ipairs(later) do
      raised(e[1] == "client" and ON_CLIENT or ON_MESSAGE, e[2])
    end
  end
  if #pending == 0 then
    return
  end
  local list = pending
  pending = {}
  for _, e in ipairs(list) do
    raised(e[1], e[2])
  end
end

---------------------------------------------------------------------------------------------
-- The `zenith` interface's calls (console.register_remote)

-- The state of client `id` (its port), nil when no such client is connected.
function state_of(id)
  id = tonumber(id)
  if not id then
    return nil
  end
  local first = session.first_state()
  if first.client and first.client.port == id then
    return first
  end
  local extra = storage.f3d_extra and storage.f3d_extra[id]
  if extra and extra.client then
    return extra
  end
  return nil
end

-- fn() with client `id`'s state served: its result, nil for no such client.
function M.with_client(id, fn)
  local s = state_of(id)
  if not s then
    return nil
  end
  if s == storage.f3d then
    return fn()
  end
  local out
  session.serve(s, function() out = fn() end)
  return out
end

-- The JSON text of `data` (a table, string, number or boolean), or nil.
local function encoded(data)
  local kind = type(data)
  if kind == "string" then
    return transport.json_string(data)
  elseif kind == "boolean" then
    return data and "true" or "false"
  elseif kind == "number" then
    if data ~= data or data == math.huge or data == -math.huge then
      return nil
    end
    return data == math.floor(data) and math.abs(data) < 1e15 and string.format("%d", data) or string.format("%.17g", data)
  elseif kind == "table" then
    local ok, text = pcall(helpers.table_to_json, data)
    return ok and type(text) == "string" and text or nil
  end
  return nil
end

-- send(client, channel, data): true, or false and why ("no such client", "bad channel", "bad data",
-- "too big", "too many"). The same answer on every peer; only the server's instance sends.
function M.send(client, channel, data)
  local s = state_of(client)
  if not s then
    return false, "no such client"
  elseif not M.channel_mod(channel) then
    return false, "bad channel"
  end
  local body = encoded(data)
  if not body then
    return false, "bad data"
  end
  local fields = ',"ch":' .. transport.json_string(channel) .. ',"d":' .. body
  -- {"t":"ext","k":<tick>...}: the line as the client reads it.
  local bytes = 16 + #tostring(game.tick) + #fields
  if bytes > M.MAX_BYTES then
    return false, "too big"
  elseif not counted(s, "o", bytes) then
    return false, "too many"
  end
  if s == storage.f3d then
    transport.send_text("ext", fields)
  else
    session.serve(s, transport.send_text, "ext", fields)
  end
  return true
end

-- {{client, player_index}, ...}: the connected clients, the first one first, the others by port.
function M.clients()
  local out = {}
  local first = session.first_state()
  if first.client then
    out[1] = { client = first.client.port, player_index = M.with_client(first.client.port, player_index) }
  end
  local ports = {}
  for port, s in pairs(storage.f3d_extra or {}) do
    if s.client then
      ports[#ports + 1] = port
    end
  end
  table.sort(ports)
  for _, port in ipairs(ports) do
    out[#out + 1] = { client = port, player_index = M.with_client(port, player_index) }
  end
  return out
end

-- set_cue(tick): the game tick a filmed scene's cue happens on (usually game.tick), for every
-- client's add-ons (api.world.cue_tick, Immersive Weather's timeline and strikes); nil or a negative
-- number clears it. Kept in `storage` (the remote call runs inside the caller's event, so every
-- peer sets it alike), sent at once to each client as {t = "cue", c}, and in each later welcome.
-- Returns the cue now set, -1 when none.
function M.set_cue(tick)
  local v = tonumber(tick)
  v = (v and v == v and v >= 0 and v < 2 ^ 53) and math.floor(v) or -1
  storage.f3d_cue = v >= 0 and v or nil
  session.each_client(function()
    transport.send_reliable({ t = "cue", c = v })
  end)
  return v
end

-- The cue set by set_cue, or nil (session.lua's welcome).
function M.cue()
  return storage.f3d_cue
end

function M.on_message()
  return ON_MESSAGE
end

function M.on_client()
  return ON_CLIENT
end

return M
