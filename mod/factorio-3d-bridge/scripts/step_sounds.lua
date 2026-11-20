-- The character's steps from Factorio's own prototypes (step 5 task 3a): each tile's walking_sound, the
-- rails' and resources' (what is walked over), each decorative's (grass and bushes rustling underfoot),
-- the two utility sounds (belts and other metal: metal_walking_sound; heat pipes), and armours'
-- steps_sound and moving_sound (listed only; the client doesn't play them yet). The runtime API has no
-- reader for any of them, so the data stage (data-final-fixes.lua) lists them in a `mod-data` prototype,
-- "zenith-step-sounds", kept apart from zenith-mining-sounds so a fault in one list doesn't cost the
-- other. The handshake sends them as `steps` (session.lua, after `eprops`), in parts.
--
-- A sound is listed once, {key, volume x 100, variations}: the key is its files' prefix as
-- mining_sounds.prefix() makes it ("base/sound/walking/grass") when they are prefix-1..n (or one file,
-- prefix.ogg), else the list of its files ("my-mod/sound/steps/a.ogg", ...), as a mod may name them
-- anyhow. Names then point at it by its place in the list (from 1), 0 for a prototype that has no sound
-- (a tile walked on in silence: deep water, lava). A sound that is there but can't be read leaves its
-- prototype out, so the client plays its own table there rather than nothing. Only prototype data: the
-- same on every peer.

local mining_sounds = require("scripts.mining_sounds")

local M = {}

M.NAME = "zenith-step-sounds"
-- Entries a `steps` part holds at most, counted by the bytes they take (about): the outbox sends
-- f3d-bytes-per-tick (at least 4096) a tick.
M.PART_BYTES = 3000

-- Every file a Sound plays, in order: {filename}, {variations = {...}}, or a list of variations as
-- sound_variations() makes them. Odd shapes give what can be read of them.
local function files_of(sound, out, depth)
  if type(sound) ~= "table" or depth > 4 then
    return out
  end
  if type(sound.filename) == "string" then
    out[#out + 1] = sound.filename
    return out
  end
  if type(sound.variations) == "table" then
    files_of(sound.variations, out, depth + 1)
  end
  for _, v in ipairs(sound) do
    files_of(v, out, depth + 1)
  end
  return out
end

-- The volume of the first variation that gives one (min and max: their middle), else the sound's own, else 1.
local function volume_of(sound, depth)
  if type(sound) ~= "table" or depth > 4 then
    return nil
  end
  if type(sound.volume) == "number" then
    return sound.volume
  end
  if type(sound.min_volume) == "number" and type(sound.max_volume) == "number" then
    return (sound.min_volume + sound.max_volume) / 2
  end
  if type(sound.variations) == "table" then
    local v = volume_of(sound.variations, depth + 1)
    if v then
      return v
    end
  end
  return volume_of(sound[1], depth + 1)
end

-- "__base__/sound/x-1.ogg" -> "base/sound/x-1.ogg", as the client looks files up; nil for anything else.
local function path_of(file)
  local mod, path = string.match(file, "^__([%w_%-]+)__/(.+)$")
  return mod and (mod .. "/" .. path) or nil
end

-- {key, volume x 100, count} for a Sound, or nil when it plays no file.
function M.entry(sound)
  local files = files_of(sound, {}, 0)
  local paths = {}
  for _, f in ipairs(files) do
    local p = path_of(f)
    if p then
      paths[#paths + 1] = p
    end
  end
  if #paths == 0 then
    return nil
  end
  local volume = math.floor((volume_of(sound, 0) or 1) * 100 + 0.5)
  local prefix = mining_sounds.prefix(files[1])
  local numbered = prefix ~= nil and #paths == #files
  for i, p in ipairs(numbered and paths or {}) do
    if p ~= prefix .. "-" .. i .. ".ogg" and not (#paths == 1 and p == prefix .. ".ogg") then
      numbered = false
      break
    end
  end
  if numbered then
    return { prefix, volume, #paths }
  end
  return { paths, volume, #paths }
end

local function key_of(e)
  local k = type(e[1]) == "table" and table.concat(e[1], "|") or e[1]
  return k .. "@" .. e[2]
end

-- Data stage: the mod-data prototype. Each part in its own pcall: a mod's odd sound costs only its name.
function M.prototype(raw)
  local sounds, index = {}, {}
  -- A sound's place in the list; 0 for no sound; nil for one that can't be read (left out).
  local function add(sound)
    if sound == nil then
      return 0
    end
    local ok, e = pcall(M.entry, sound)
    if not ok or not e then
      return nil
    end
    local k = key_of(e)
    if not index[k] then
      sounds[#sounds + 1] = e
      index[k] = #sounds
    end
    return index[k]
  end
  local function each(kind, fn)
    if type(raw[kind]) == "table" then
      for name, p in pairs(raw[kind]) do
        if type(p) == "table" then
          pcall(fn, name, p)
        end
      end
    end
  end
  local tile, entity, decorative, armor = {}, {}, {}, {}
  -- Every tile, those without a sound too: the client then knows it is walked on in silence.
  each("tile", function(name, p) tile[name] = add(p.walking_sound) end)
  for kind in pairs(raw) do
    if kind == "resource" or (type(kind) == "string" and kind:find("rail", 1, true)) then
      each(kind, function(name, p)
        if p.walking_sound then
          entity[name] = add(p.walking_sound)
        end
      end)
    end
  end
  for _, kind in ipairs({ "optimized-decorative", "decorative" }) do
    each(kind, function(name, p)
      if p.walking_sound then
        decorative[name] = add(p.walking_sound)
      end
    end)
  end
  each("armor", function(name, p)
    if p.steps_sound or p.moving_sound then
      armor[name] = { add(p.steps_sound) or 0, add(p.moving_sound) or 0 }
    end
  end)
  local u = { 0, 0 }
  pcall(function()
    local us = raw["utility-sounds"] and raw["utility-sounds"].default
    if type(us) == "table" then
      u = { add(us.metal_walking_sound) or 0, add(us.heat_pipe_walking_sound) or 0 }
    end
  end)
  -- The night vision equipment's activate and deactivate sounds (the client plays them as it turns on and
  -- off); the vanilla one's name first, else any. 0 for a sound it has none of.
  local nv = { 0, 0 }
  pcall(function()
    local all = raw["night-vision-equipment"]
    local p = type(all) == "table" and (all["night-vision-equipment"] or select(2, next(all)))
    if type(p) == "table" then
      nv = { add(p.activate_sound) or 0, add(p.deactivate_sound) or 0 }
    end
  end)
  return {
    type = "mod-data", name = M.NAME, data_type = M.NAME,
    data = { s = sounds, tile = tile, entity = entity, decorative = decorative, armor = armor, u = u, nv = nv },
  }
end

-- Runtime: the `steps` messages, made once a load from the list (prototype data and the registry's ids
-- alone: module-local). None when there is no list (the data stage's failed): nothing is sent, and the
-- client keeps its own table. This file is loaded in the data stage too, so the registry comes as an
-- argument rather than a require.
local parts_cache

local function get(data, key)
  local ok, v = pcall(function() return data.get(key) end)
  return ok and type(v) == "table" and v or nil
end

local function bytes_of(rec)
  local n = 12
  for _, v in ipairs(rec) do
    n = n + (type(v) == "table" and #table.concat(v, "\",\"") + 4 or #tostring(v)) + 1
  end
  return n
end

-- A sound whose own file list is bigger than a part (a mod listing dozens of long, unnumbered files)
-- keeps as many of its files as fit, with a log line: a part over the outbox's bytes a tick would wait.
function M.fit(rec, i)
  if type(rec) ~= "table" or type(rec[1]) ~= "table" or bytes_of(rec) <= M.PART_BYTES then
    return rec
  end
  local files, n = {}, 12 + #tostring(rec[2]) + 8
  for _, f in ipairs(rec[1]) do
    n = n + #f + 3
    if n > M.PART_BYTES then
      break
    end
    files[#files + 1] = f
  end
  log("[Zenith] steps: sound " .. i .. " lists " .. #rec[1] .. " files, too many for one message: " .. #files .. " sent")
  return { files, rec[2], #files }
end

local function build(registry)
  local ok, data = pcall(function() return prototypes.mod_data[M.NAME] end)
  if not ok or not data then
    return false
  end
  local s = get(data, "s")
  if not s then
    return false
  end
  local lists = { s = {}, tl = {}, el = {}, dl = {}, al = {} }
  for i = 1, #s do
    lists.s[i] = M.fit(s[i], i)
  end
  local function ids(src, out, id_of)
    for name, v in pairs(src or {}) do
      local id = id_of(name)
      if id and id > 0 then
        if type(v) == "table" then
          out[#out + 1] = { id, v[1] or 0, v[2] or 0 }
        else
          out[#out + 1] = { id, v }
        end
      end
    end
    table.sort(out, function(a, b) return a[1] < b[1] end)
  end
  ids(get(data, "tile"), lists.tl, registry.tile_id)
  ids(get(data, "entity"), lists.el, registry.entity_id)
  ids(get(data, "decorative"), lists.dl, registry.decorative_id)
  ids(get(data, "armor"), lists.al, registry.item_id)
  local u = get(data, "u") or { 0, 0 }
  -- Split into parts under PART_BYTES, the sounds first (the names point at them), in order.
  local nv = get(data, "nv") or { 0, 0 }
  local parts, part, size = {}, { u = { u[1] or 0, u[2] or 0 }, nv = { nv[1] or 0, nv[2] or 0 } }, 0
  for _, key in ipairs({ "s", "tl", "el", "dl", "al" }) do
    for _, rec in ipairs(lists[key]) do
      local b = bytes_of(rec)
      if size + b > M.PART_BYTES and size > 0 then
        parts[#parts + 1] = part
        part, size = {}, 0
      end
      part[key] = part[key] or {}
      part[key][#part[key] + 1] = rec
      size = size + b
    end
  end
  parts[#parts + 1] = part
  return parts
end

-- The messages to send, new tables each time (the outbox numbers them): [] without a list.
function M.messages(registry)
  if parts_cache == nil then
    parts_cache = build(registry)
  end
  local out = {}
  for i, p in ipairs(parts_cache or {}) do
    local msg = { t = "steps", part = i, parts = #parts_cache }
    for k, v in pairs(p) do
      msg[k] = v
    end
    out[#out + 1] = msg
  end
  return out
end

return M
