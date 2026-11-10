-- Chunk subscriptions and snapshots: the static part of the world (tiles, buildings, trees,
-- ore). The client subscribes to the chunks around its camera; each one is read and sent once,
-- then kept current by the deltas in tracker.lua and refreshed now and then to heal any loss.

local registry = require("scripts.registry")
local transport = require("scripts.transport")
local budget = require("scripts.budget")
local alt_mode = require("scripts.alt_mode")
local entity_ui = require("scripts.entity_ui")

local M = {}

local CHUNK = 32
local ENTITIES_PER_MESSAGE = 120
local MAX_SUBSCRIPTIONS = 625 -- a 25x25 chunk square, 800x800 tiles
local MAX_BACKLOG = 64        -- don't read more chunks while this many messages wait to be sent
local REFRESH_INTERVAL = 300  -- ticks between re-sending one subscribed chunk
local DECORATIVES_PER_MESSAGE = 1000 -- 4 numbers each
local MAX_DECORATIVES = 8000       -- per chunk; a lush Nauvis chunk has a few hundred
local DECORATIVE_INTERVAL = 30     -- ticks between resending chunks whose decoratives changed

-- Positions are sent as integers in 1/256 tile, the engine's own resolution.
function M.fixed(v)
  return math.floor(v * 256 + 0.5)
end

-- Numbers from a packet that the tick goes on using. tonumber("1e999") is inf, so a packet can
-- carry it as a string; the tick isn't under pcall, so an inf or NaN reaching the game's API
-- there would stop the game. Factorio's maps end a million tiles from the centre.
M.MAP_LIMIT = 1000000
local CHUNK_LIMIT = M.MAP_LIMIT / 32 + 1

-- A position in 1/256 tile from a packet: finite and on the map (clamped to its edge), or nil.
function M.fixed_in(v)
  v = tonumber(v)
  if not v or v ~= v then
    return nil
  end
  local lim = M.MAP_LIMIT * 256
  return math.max(-lim, math.min(lim, v))
end

-- A chunk coordinate from a packet: a whole number on the map, or nil.
function M.chunk_in(v)
  v = tonumber(v)
  if v and v == v and v >= -CHUNK_LIMIT and v <= CHUNK_LIMIT then
    return math.floor(v)
  end
  return nil
end

-- The area {x1, y1, x2, y2} (1/256 tile) of a planner or copy, or nil with why: at most MAX_AREA
-- squared tiles in all. Without the cap a client's area could be the whole map, and the marking,
-- the history's list of what changed and the blueprint read every entity on the surface in one
-- tick. A drag across the whole of the client's furthest remote view is a few hundred a side; the
-- cap is on the area, not each side, so a long thin drag made while panning (a rail line) still goes.
M.MAX_AREA = 2048
function M.area_in(cmd)
  local x1, y1 = M.fixed_in(cmd.x1) or 0, M.fixed_in(cmd.y1) or 0
  local x2, y2 = M.fixed_in(cmd.x2) or 0, M.fixed_in(cmd.y2) or 0
  x1, y1, x2, y2 = x1 / 256, y1 / 256, x2 / 256, y2 / 256
  if math.abs(x2 - x1) * math.abs(y2 - y1) > M.MAX_AREA * M.MAX_AREA then
    return nil, "That area is too big (at most " .. M.MAX_AREA .. " by " .. M.MAX_AREA .. " tiles)"
  end
  return { { math.min(x1, x2), math.min(y1, y2) }, { math.max(x1, x2), math.max(y1, y2) } }
end

local function key(cx, cy)
  return cx .. "," .. cy
end

-- The surface the client's world shows: the one the remote view looks at (`view`), else the
-- character's.
function M.surface()
  local s = storage.f3d
  if s.view_si then
    local viewed = game.get_surface(s.view_si)
    if viewed and viewed.valid then
      return viewed
    end
  end
  if s.puppet and s.puppet.valid then
    return s.puppet.surface
  end
  return game.get_surface(settings.global["f3d-surface"].value) or game.get_surface(1)
end

-- Each chunk's change count (storage.f3d.revs[surface index][key]), raised by every build, mine,
-- rotation, death, tile change and generation in it, subscribed or not, from events only (so the
-- same on every peer). A snapshot carries its chunk's count (`rv`) and entity count (`n`); a client
-- that kept a chunk lists it when it subscribes again (`sub` h), and a chunk whose counts still
-- match is answered with `same` instead of being read and sent (the client draws its own copy).
local function rev_table(si)
  local s = storage.f3d
  s.revs = s.revs or {}
  local t = s.revs[si]
  if not t then
    t = {}
    s.revs[si] = t
  end
  return t
end

function M.rev(si, k)
  local t = storage.f3d.revs and storage.f3d.revs[si]
  return t and t[k] or 0
end

-- Raises the counts of the chunk at `position` and of neighbours within 2 tiles (a belt's or pipe's
-- look follows the ones next to it, which may be across the edge).
function M.bump(si, position)
  local t = rev_table(si)
  local x, y = position.x or position[1], position.y or position[2]
  local cx, cy = math.floor(x / CHUNK), math.floor(y / CHUNK)
  local lx, ly = x - cx * CHUNK, y - cy * CHUNK
  local x0 = lx < 2 and -1 or 0
  local x1 = lx > CHUNK - 2 and 1 or 0
  local y0 = ly < 2 and -1 or 0
  local y1 = ly > CHUNK - 2 and 1 or 0
  for dy = y0, y1 do
    for dx = x0, x1 do
      local k = key(cx + dx, cy + dy)
      t[k] = (t[k] or 0) + 1
    end
  end
end

function M.is_subscribed(surface, position)
  local s = storage.f3d
  if not s.client or surface.index ~= s.surface_index then
    return false
  end
  return s.subs[key(math.floor(position.x / CHUNK), math.floor(position.y / CHUNK))] ~= nil
end

-- Which sides a pipe connects on, as a bitmask: 1 north, 2 east, 4 south, 8 west. Only ordinary
-- connections to something (a pipe-to-ground's underground side isn't one).
local function pipe_mask(entity)
  local mask = 0
  local p = entity.position
  -- 2.1 has no LuaEntity.fluidbox: fluid boxes are counted by fluids_count.
  for i = 1, entity.fluids_count do
    for _, c in pairs(entity.get_fluid_box_pipe_connections(i) or {}) do
      if c.target and c.connection_type == "normal" then
        local dx, dy = c.target_position.x - p.x, c.target_position.y - p.y
        if math.abs(dy) >= math.abs(dx) then
          mask = bit32.bor(mask, dy < 0 and 1 or 4)
        else
          mask = bit32.bor(mask, dx > 0 and 2 or 8)
        end
      end
    end
  end
  return mask
end

-- Types whose colour the player sets (the client tints their paint with it).
local PAINTED = { locomotive = true, ["cargo-wagon"] = true, ["fluid-wagon"] = true, ["artillery-wagon"] = true,
  ["train-stop"] = true }

local function extra_of_type(entity)
  local t = entity.type
  if registry.is_pipe(t) then
    local ok, mask = pcall(pipe_mask, entity)
    return ok and { pc = mask } or nil
  end
  if t == "transport-belt" then
    return { s = string.sub(entity.belt_shape, 1, 1) }
  elseif t == "underground-belt" then
    return { u = string.sub(entity.belt_to_ground_type, 1, 1) }
  elseif t == "linked-belt" then
    return { u = string.sub(entity.linked_belt_type, 1, 1) }
  elseif t == "corpse" or t == "rail-remnants" then
    -- What the remnants were (the client draws its model broken).
    local of = registry.remnant_of(entity.name)
    return of and { rm = of } or nil
  elseif t == "resource" then
    return { a = entity.amount }
  elseif t == "entity-ghost" then
    if entity.ghost_type == "underground-belt" then
      return { gh = registry.entity_id(entity.ghost_name), u = string.sub(entity.belt_to_ground_type, 1, 1) }
    end
    return { gh = registry.entity_id(entity.ghost_name) }
  elseif t == "tile-ghost" then
    return { tg = registry.tile_id(entity.ghost_name) }
  elseif t == "train-stop" then
    return { n = entity.backer_name }
  elseif t == "cliff" then
    -- Which piece of a cliff chain this is ("west-to-east", "none-to-north", ...).
    return { co = entity.cliff_orientation }
  end
  return nil
end

local function quality_of(entity)
  return entity.quality.name
end

-- Marked for deconstruction (d = 1) or for an upgrade (up = the target's prototype id).
local function marks(entity)
  local out
  if entity.to_be_deconstructed() then
    out = { d = 1 }
  end
  if entity.to_be_upgraded() then
    out = out or {}
    out.up = registry.entity_id(entity.get_upgrade_target().name)
  end
  return out
end

-- Copper and circuit wires from this entity, by the unit numbers at their other end:
-- {w = copper, r = red, g = green}, or nil without any. 2.x keeps wires on wire connectors.
local WIRE_KEYS
local function wires(entity)
  if not WIRE_KEYS then
    WIRE_KEYS = { [defines.wire_type.copper] = "w", [defines.wire_type.red] = "r", [defines.wire_type.green] = "g" }
  end
  local out
  for _, connector in pairs(entity.get_wire_connectors(false)) do
    local key = WIRE_KEYS[connector.wire_type]
    for _, connection in pairs(connector.connections) do
      local unit = connection.target.owner.unit_number
      if key and unit then
        out = out or {}
        out[key] = out[key] or {}
        table.insert(out[key], unit)
      end
    end
  end
  return out
end

-- The entity's wires as a string, to notice when one is added or removed (no event for that).
function M.wire_signature(entity)
  local ok, w = pcall(wires, entity)
  if not ok or not w then
    return ""
  end
  local parts = {}
  for _, key in ipairs({ "w", "r", "g" }) do
    local units = w[key] or {}
    table.sort(units)
    parts[#parts + 1] = key .. table.concat(units, ",")
  end
  return table.concat(parts, ";")
end

-- Quality (2.x) only when it isn't normal, so most records stay short.
local function quality_extra(entity)
  local q = quality_of(entity)
  return q ~= "normal" and { q = q } or nil
end

-- Quality, marks and, for entities with a unit number, wires: the client draws a wire when
-- either end lists the other.
local function all_extras(entity, has_unit)
  local out = quality_extra(entity) or {}
  for k, v in pairs(marks(entity) or {}) do
    out[k] = v
  end
  if has_unit then
    for k, v in pairs(wires(entity) or {}) do
      out[k] = v
    end
  end
  return out
end

-- What a record carries beyond its id, place and direction; painted things add their colour.
local function extra(entity)
  local x = extra_of_type(entity)
  if PAINTED[entity.type] then
    -- The colour the player gave it (H21: trains and stops were drawn in their models' grey).
    local ok, c = pcall(function() return entity.color end)
    if ok and c then
      x = x or {}
      x.col = entity_ui.color_out(c)
    end
  end
  return x
end

-- Ghosts of rolling stock (issue #13). Their `direction` stays north whichever way they face, so
-- the record gets the nearest of 16 directions to their orientation. And a train the robots build
-- is a mover, never `add`ed, so the client can't drop its ghost on seeing it built there, as it
-- does for buildings: the ghost is registered for on_object_destroyed when it is sent, and its
-- going sends `del` (tracker.on_object_destroyed). Kept per client, in storage.f3d.stock_ghosts.
local STOCK = { locomotive = true, ["cargo-wagon"] = true, ["fluid-wagon"] = true, ["artillery-wagon"] = true }

local function stock_ghost(entity, rec)
  local ok, orientation = pcall(function() return entity.orientation end)
  if ok and type(orientation) == "number" then
    rec[5] = math.floor(orientation * 16 + 0.5) % 16
  end
  local s = storage.f3d
  local ok_reg, reg = pcall(script.register_on_object_destroyed, entity)
  if s and ok_reg and reg then
    s.stock_ghosts = s.stock_ghosts or {}
    s.stock_ghosts[reg] = { u = rec[1], p = rec[2], x = rec[3], y = rec[4], s = entity.surface.index }
  end
end

-- [unit_number or 0, prototype id, x, y, direction, extra?]
-- Entities without a unit number (trees, rocks, ore) are identified by prototype + position.
function M.record(entity)
  local p = entity.position
  local rec = { entity.unit_number or 0, registry.entity_id(entity.name), M.fixed(p.x), M.fixed(p.y), entity.direction or 0 }
  if entity.type == "entity-ghost" and STOCK[entity.ghost_type] then
    stock_ghost(entity, rec)
  end
  local x = extra(entity)
  -- Quality, marks and wires (2.x API) in one protected call: a record is made for every entity
  -- in a chunk snapshot, so this is the bridge's busiest path. If it fails, each is tried alone
  -- so one missing API doesn't lose the others.
  local ok, more = pcall(all_extras, entity, rec[1] ~= 0)
  if not ok then
    more = {}
    for _, f in ipairs({ quality_extra, marks, rec[1] ~= 0 and wires or nil }) do
      local ok2, part = pcall(f, entity)
      if ok2 and part then
        for k, v in pairs(part) do
          more[k] = v
        end
      end
    end
  end
  if more and next(more) then
    x = x or {}
    for k, v in pairs(more) do
      x[k] = v
    end
  end
  -- Alt-mode's icon (issue #9): with the record, so every loaded machine has it, no scanning.
  -- and its machine or pump arrows (part 2, extra.fa).
  if rec[1] ~= 0 and alt_mode.TYPES[entity.type] then
    local icon, arrows = alt_mode.state(entity)
    if icon then
      x = x or {}
      x.ai = icon
    end
    if arrows then
      x = x or {}
      x.fa = arrows
    end
    alt_mode.recorded(entity, icon, x, arrows)
  end
  if x then
    rec[6] = x
  end
  return rec
end

-- The queue is kept in the client's order (nearest the character first, `s.rank`), whatever
-- queued a chunk: a new subscription, a chunk Factorio has just generated, a resend. Otherwise,
-- after a jump, chunks queued for the old place and land generated in Factorio's own order went
-- first, and the ground under the character came last.
local function enqueue(k)
  local s = storage.f3d
  if s.queued[k] then
    return
  end
  s.queued[k] = true
  local rank = s.rank and s.rank[k] or math.huge
  local q = s.queue
  local lo, hi = 1, #q + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    local r = s.rank and s.rank[q[mid]] or math.huge
    if r <= rank then
      lo = mid + 1
    else
      hi = mid
    end
  end
  table.insert(q, lo, k)
end

M.enqueue = enqueue

-- Replace the subscription set. `list` is ordered nearest first, which is the order chunks
-- are sent in.
function M.subscribe(list, have)
  local s = storage.f3d
  local want, order = {}, {}
  for _, c in pairs(list) do
    local cx, cy = type(c) == "table" and M.chunk_in(c[1]), type(c) == "table" and M.chunk_in(c[2])
    if cx and cy and #order < MAX_SUBSCRIPTIONS then
      local k = key(cx, cy)
      if not want[k] then
        want[k] = { cx, cy }
        order[#order + 1] = k
      end
    end
  end
  for k in pairs(s.subs) do
    if not want[k] then
      s.subs[k] = nil
      -- The client forgets a chunk's far belt lanes with it (belt_items.lua): sent again if it comes back.
      if s.far then
        s.far.sent[k] = nil
      end
    end
  end
  s.rank = {}
  for i, k in ipairs(order) do
    s.rank[k] = i
  end
  -- Still wanted and not sent yet, or new: in the new order.
  local queue = {}
  for _, k in ipairs(order) do
    if s.queued[k] or not s.subs[k] then
      s.subs[k] = want[k]
      queue[#queue + 1] = k
    end
  end
  s.queue, s.queued = queue, {}
  for _, k in ipairs(queue) do
    s.queued[k] = true
  end
  -- The client's own copies of chunks it subscribes to again: [surface index, cx, cy, rv, n].
  s.have = s.have or {}
  for k in pairs(s.have) do
    if not s.queued[k] then
      s.have[k] = nil
    end
  end
  if type(have) == "table" then
    local n = 0
    for _, h in pairs(have) do
      if type(h) == "table" and tonumber(h[1]) and M.chunk_in(h[2]) and M.chunk_in(h[3]) and tonumber(h[4])
          and tonumber(h[5]) and n < MAX_SUBSCRIPTIONS then
        local k = key(M.chunk_in(h[2]), M.chunk_in(h[3]))
        if s.queued[k] then
          s.have[k] = { si = math.floor(tonumber(h[1])), rv = math.floor(tonumber(h[4])), n = math.floor(tonumber(h[5])) }
        end
        n = n + 1
      end
    end
  end
end

-- Queue just these chunks again, ignoring any the client isn't subscribed to.
function M.resend(list)
  local s = storage.f3d
  local n = 0
  for _, c in pairs(list) do
    local cx, cy = type(c) == "table" and M.chunk_in(c[1]), type(c) == "table" and M.chunk_in(c[2])
    if cx and cy and n < MAX_SUBSCRIPTIONS then
      local k = key(cx, cy)
      if s.subs[k] then
        enqueue(k)
      end
      n = n + 1
    end
  end
end

function M.resend_all()
  local s = storage.f3d
  s.queue, s.queued = {}, {}
  for k in pairs(s.subs) do
    enqueue(k)
  end
end

function M.clear()
  local s = storage.f3d
  s.subs, s.queue, s.queued, s.dec_dirty, s.rank, s.have = {}, {}, {}, {}, {}, {}
  s.refresh_cursor, s.snap = nil, nil
end

local function read_tiles(surface, x0, y0)
  -- Run-length encoded tile ids, row by row: [id, count, id, count, ...]
  local rle = {}
  local last, count = nil, 0
  for y = y0, y0 + CHUNK - 1 do
    for x = x0, x0 + CHUNK - 1 do
      local id = registry.tile_id(surface.get_tile(x, y).name)
      if id == last then
        count = count + 1
      else
        if last then
          rle[#rle + 1] = last
          rle[#rle + 1] = count
        end
        last, count = id, 1
      end
    end
  end
  rle[#rle + 1] = last
  rle[#rle + 1] = count
  return rle
end

-- The chunk's decoratives for a client that asked for them (`dc` in its hello), always sent (an
-- empty list clears the chunk): [decorative id, x, y, amount, ...], x and y the tile within the
-- chunk (0-31).
local function send_decoratives(surface, cx, cy)
  local s = storage.f3d
  if not (s.client and s.client.dc) then
    return
  end
  local x0, y0 = cx * CHUNK, cy * CHUNK
  local ok, found = pcall(surface.find_decoratives_filtered, { area = { { x0, y0 }, { x0 + CHUNK, y0 + CHUNK } } })
  local flat, m = {}, 0
  for _, d in pairs(ok and found or {}) do
    local id = registry.decorative_id(d.decorative.name)
    local lx, ly = d.position.x - x0, d.position.y - y0
    if id > 0 and lx >= 0 and lx < CHUNK and ly >= 0 and ly < CHUNK then
      flat[m + 1], flat[m + 2], flat[m + 3], flat[m + 4] = id, lx, ly, d.amount
      m = m + 4
      if m >= MAX_DECORATIVES * 4 then
        break
      end
    end
  end
  local per = DECORATIVES_PER_MESSAGE * 4
  local parts = math.max(1, math.ceil(m / per))
  for part = 1, parts do
    local slice = {}
    for i = (part - 1) * per + 1, math.min(part * per, m) do
      slice[#slice + 1] = flat[i]
    end
    transport.send_reliable({ t = "dec", cx = cx, cy = cy, part = part, parts = parts, l = slice })
  end
end

-- Tiles placed or mined, or something built, can remove decoratives (no event says which):
-- the chunk is sent again on the next DECORATIVE_INTERVAL.
-- The callers raised the chunk's change count already (tracker's `touched`, tiles_changed): raising
-- it here again counted every build and tile change twice.
function M.decoratives_changed(surface, position)
  local s = storage.f3d
  if not (s.client and s.client.dc) or surface.index ~= s.surface_index then
    return
  end
  local k = key(math.floor(position.x / CHUNK), math.floor(position.y / CHUNK))
  if s.subs[k] then
    s.dec_dirty = s.dec_dirty or {}
    s.dec_dirty[k] = true
  end
end

local function send_dirty_decoratives(surface)
  local s = storage.f3d
  local dirty = s.dec_dirty
  if not dirty or not next(dirty) then
    return
  end
  s.dec_dirty = {}
  for k in pairs(dirty) do
    local c = s.subs[k]
    if c and not s.queued[k] then
      send_decoratives(surface, c[1], c[2])
    end
  end
end

-- A chunk's snapshot is a job in slices under the work budget (budget.lua), so a busy chunk (two
-- thousand entities on the owner's base) never makes one slow tick: whether it exists and how many
-- entities it has, its tiles, its entities in strips of rows (each about half a budget's worth),
-- then its decoratives, and only then the messages, in the order the client expects (`chunk`,
-- `ents`, `dec`). The job and the records made so far are kept in storage.f3d.snap; its prices come
-- from the game's counts, so it moves the same way on every peer. Something built, mined or changed
-- in the chunk meanwhile (tracker.lua tells M.touched) queues it again once it is sent, as a strip
-- already read wouldn't have it.
local WORLD_SHARE = 0.7
-- Priced from /f3d-profile trace on the owner's save: a record (quality, marks, wires) costs about
-- twice a chart's entity, a chunk's 1024 tiles about 100 units, its decoratives up to 100.
local RECORD_PRICE = 2
local TILES_PRICE = 100
local DECORATIVE_PRICE = 100

local function strips_for(count)
  local per = budget.slice(50)
  local strips = 1
  while strips < 8 and count * RECORD_PRICE > per * strips do
    strips = strips * 2
  end
  return strips
end

local function snap_price(job)
  if job.step < 0 then
    return 2
  elseif job.step == 0 then
    return TILES_PRICE
  elseif job.step <= job.strips then
    return 2 + RECORD_PRICE * math.ceil(job.count / job.strips)
  end
  return DECORATIVE_PRICE
end

local function send_snapshot(job)
  local records = job.records
  local parts = math.max(1, math.ceil(#records / ENTITIES_PER_MESSAGE))
  transport.send_reliable({ t = "chunk", cx = job.cx, cy = job.cy, tiles = job.tiles, parts = parts,
    rs = job.si, rv = job.rev, n = job.count })
  for part = 1, parts do
    local slice = {}
    for i = (part - 1) * ENTITIES_PER_MESSAGE + 1, math.min(part * ENTITIES_PER_MESSAGE, #records) do
      slice[#slice + 1] = records[i]
    end
    transport.send_reliable({ t = "ents", cx = job.cx, cy = job.cy, part = part, parts = parts, e = slice })
  end
end

-- One slice of the job in s.snap; clears it when the chunk is sent.
local function snapshot_step(surface, s)
  local job = s.snap
  local cx, cy = job.cx, job.cy
  local x0, y0 = cx * CHUNK, cy * CHUNK
  if job.step < 0 then
    if not surface.is_chunk_generated({ cx, cy }) then
      transport.send_reliable({ t = "chunk", cx = cx, cy = cy, none = true })
      surface.request_to_generate_chunks({ cx * CHUNK + 16, cy * CHUNK + 16 }, 0)
      s.snap = nil
      return
    end
    job.count = surface.count_entities_filtered({
      area = { { x0, y0 }, { x0 + CHUNK, y0 + CHUNK } }, type = registry.excluded_types(), invert = true,
    })
    job.si = surface.index
    job.rev = M.rev(surface.index, job.k)
    -- The client still has this chunk as it is now: nothing to read or send.
    local h = s.have and s.have[job.k]
    if h then
      s.have[job.k] = nil
      if h.si == job.si and h.rv == job.rev and h.n == job.count then
        transport.send_reliable({ t = "chunk", cx = cx, cy = cy, rs = job.si, same = job.rev })
        s.snap = nil
        return
      end
    end
    job.strips = strips_for(job.count)
    job.records = {}
    job.step = 0
    return
  end
  if job.step == 0 then
    job.tiles = read_tiles(surface, x0, y0)
    job.step = 1
    return
  end
  if job.step <= job.strips then
    local h = CHUNK / job.strips
    local ya = y0 + (job.step - 1) * h
    local yb = ya + h
    local area = { { x0, ya }, { x0 + CHUNK, yb } }
    local found = surface.find_entities_filtered({ area = area, type = registry.excluded_types(), invert = true })
    -- Remnants are corpses, which the type filter leaves out.
    local names = registry.remnant_names()
    if #names > 0 then
      for _, e in pairs(surface.find_entities_filtered({ area = area, type = "corpse", name = names })) do
        found[#found + 1] = e
      end
    end
    -- An entity overlapping several chunks (or strips) belongs to the one containing its centre.
    local records = job.records
    for _, e in pairs(found) do
      local p = e.position
      if p.x >= x0 and p.x < x0 + CHUNK and p.y >= ya and p.y < yb then
        records[#records + 1] = M.record(e)
      end
    end
    job.step = job.step + 1
    return
  end
  s.snap = nil
  send_snapshot(job)
  send_decoratives(surface, cx, cy)
  if job.touched then
    enqueue(job.k)
  end
end

-- Something was built, mined or changed at the entity: if its chunk is being read, it is read again.
function M.touched(entity)
  if entity and entity.valid then
    M.bump(entity.surface.index, entity.position)
  end
  local s = storage.f3d
  local job = s and s.snap
  if job and entity and entity.valid and entity.surface.index == s.surface_index then
    local p = entity.position
    if math.floor(p.x / CHUNK) == job.cx and math.floor(p.y / CHUNK) == job.cy then
      job.touched = true
    end
  end
end

-- Chunks waiting to be sent (the one being read counts).
function M.queue_length()
  local s = storage.f3d
  return #(s.queue or {}) + (s.snap and 1 or 0)
end
budget.register_queue("chunks", M.queue_length)

local function next_refresh()
  local s = storage.f3d
  if s.refresh_cursor and not s.subs[s.refresh_cursor] then
    s.refresh_cursor = nil
  end
  s.refresh_cursor = next(s.subs, s.refresh_cursor)
  if s.refresh_cursor then
    enqueue(s.refresh_cursor)
  end
end

function M.tick()
  local s = storage.f3d
  if game.tick % REFRESH_INTERVAL == 0 then
    next_refresh()
  end
  local surface = M.surface()
  if game.tick % DECORATIVE_INTERVAL == 0 then
    send_dirty_decoratives(surface)
  end
  -- At most f3d-chunks-per-tick chunks start a tick, and each is read in slices while the work
  -- budget lasts. Only a chunk that has to be read counts: one the client still has (`same`) or
  -- that isn't generated (`none`) costs a count of its entities, so a view the client kept comes
  -- back within a few ticks instead of a chunk a tick (a surface change and back, Factorissimo's
  -- buildings: 441 chunks took 7.4 s).
  local starts = settings.global["f3d-chunks-per-tick"].value
  while transport.backlog() < MAX_BACKLOG do
    if s.snap and not s.subs[s.snap.k] then
      s.snap = nil -- no longer wanted
    end
    if not s.snap then
      if starts <= 0 or #s.queue == 0 then
        return
      end
      local k = table.remove(s.queue, 1)
      s.queued[k] = nil
      local c = s.subs[k]
      if c then
        s.snap = { k = k, cx = c[1], cy = c[2], step = -1 }
      end
    end
    if s.snap then
      local price = snap_price(s.snap)
      if not budget.can(price, "chunks", WORLD_SHARE) then
        return
      end
      budget.spend(price, "chunks")
      local checking = s.snap.step < 0
      snapshot_step(surface, s)
      if checking and s.snap then
        starts = starts - 1 -- it has to be read
      end
    end
  end
end

function M.on_chunk_generated(surface, position)
  M.bump(surface.index, { x = position.x * CHUNK + 16, y = position.y * CHUNK + 16 })
  local s = storage.f3d
  if s.client and surface.index == s.surface_index then
    local k = key(position.x, position.y)
    if s.subs[k] then
      enqueue(k)
    end
  end
end

-- Send the current tile at each changed position that the client can see.
function M.tiles_changed(surface, positions)
  local seen = {}
  for _, p in pairs(positions) do
    local x, y = math.floor(p.x), math.floor(p.y)
    local k = math.floor(x / 2) .. "," .. math.floor(y / 2)
    if not seen[k] then
      seen[k] = true
      M.bump(surface.index, { x = x, y = y })
    end
  end
  local s = storage.f3d
  if not s.client or surface.index ~= s.surface_index then
    return
  end
  -- Flat [x, y, tile id, ...], split so a big landfill job doesn't make one huge packet.
  local list = {}
  for _, p in pairs(positions) do
    if M.is_subscribed(surface, p) then
      M.decoratives_changed(surface, p)
      local x, y = math.floor(p.x), math.floor(p.y)
      list[#list + 1] = x
      list[#list + 1] = y
      list[#list + 1] = registry.tile_id(surface.get_tile(x, y).name)
      if #list >= 1500 then
        transport.send_reliable({ t = "tiles", l = list })
        list = {}
      end
    end
  end
  if #list > 0 then
    transport.send_reliable({ t = "tiles", l = list })
  end
end

return M
