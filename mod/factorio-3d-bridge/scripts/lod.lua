-- Distant Horizon LOD sampler: charted-chunk overview (`lodm`), region revisions (`lodr`),
-- and multi-resolution chunk tile + entity summaries (`lod`), served strictly over charted and
-- already-generated chunks (never calls `request_to_generate_chunks`).
--
-- Determinism: all queue, cursor, and fine-chunk slice state lives in `storage.f3d.lod`, mutated
-- only from events, packet handlers, and `on_tick`. Module-local `proto_lod` is derived solely
-- from read-only `prototypes.entity`.

local transport = require("scripts.transport")
local registry = require("scripts.registry")
local world = require("scripts.world")
local map = require("scripts.map")
local puppet = require("scripts.puppet")
local budget = require("scripts.budget")
local profile = require("scripts.profile")

local M = {}

local CHUNK = 32
local REGION = world.REGION or 16
local REGION_LIMIT = 4096
local MAX_REVS_ASK = 512
local MAX_WANT = 256
local MAX_WANT_SCAN = 2048
local PAGE_BYTES = 28000
local MAP_PAGES_PER_TICK = 4
local MAX_BACKLOG = 48
local LOD_SHARE_BUSY = 0.25
local LOD_SHARE_IDLE = 0.5
local MACRO_LIMIT = 8
local COUNT_CAP = 64
local MAP_SCAN_PER_TICK = 1024

local VALID_RES = { [2] = true, [4] = true, [8] = true, [16] = true, [32] = true }

local GLOW_LAMP = {
  ["lamp"] = true,
}

local GLOW_STRONG = {
  ["reactor"] = true,
  ["fusion-reactor"] = true,
  ["rocket-silo"] = true,
}

local GLOW_SOFT = {
  ["furnace"] = true,
  ["lab"] = true,
  ["heating-tower"] = true,
  ["burner-generator"] = true,
}

local NATURE_TYPES = {
  ["tree"] = true,
  ["plant"] = true,
}

local LOW_TYPES = {
  ["resource"] = true,
  ["transport-belt"] = true,
  ["underground-belt"] = true,
  ["splitter"] = true,
  ["lane-splitter"] = true,
  ["loader"] = true,
  ["loader-1x1"] = true,
  ["linked-belt"] = true,
  ["straight-rail"] = true,
  ["half-diagonal-rail"] = true,
  ["curved-rail-a"] = true,
  ["curved-rail-b"] = true,
  ["legacy-straight-rail"] = true,
  ["legacy-curved-rail"] = true,
  ["elevated-straight-rail"] = true,
  ["elevated-half-diagonal-rail"] = true,
  ["elevated-curved-rail-a"] = true,
  ["elevated-curved-rail-b"] = true,
  ["rail-ramp"] = true,
  ["rail-support"] = true,
}

local PROP_TYPES = {
  ["rail-signal"] = true,
  ["rail-chain-signal"] = true,
  ["inserter"] = true,
  ["electric-pole"] = true,
  ["arithmetic-combinator"] = true,
  ["decider-combinator"] = true,
  ["selector-combinator"] = true,
  ["constant-combinator"] = true,
  ["power-switch"] = true,
  ["programmable-speaker"] = true,
  ["display-panel"] = true,
}

local BUILDING_TYPES = {
  ["assembling-machine"] = true, ["furnace"] = true, ["mining-drill"] = true, ["lab"] = true,
  ["boiler"] = true, ["generator"] = true, ["reactor"] = true, ["fusion-reactor"] = true,
  ["fusion-generator"] = true, ["solar-panel"] = true, ["accumulator"] = true, ["radar"] = true,
  ["roboport"] = true, ["rocket-silo"] = true, ["beacon"] = true, ["ammo-turret"] = true,
  ["electric-turret"] = true, ["fluid-turret"] = true, ["artillery-turret"] = true, ["wall"] = true,
  ["gate"] = true, ["container"] = true, ["logistic-container"] = true, ["storage-tank"] = true,
  ["pump"] = true, ["offshore-pump"] = true, ["pipe"] = true, ["pipe-to-ground"] = true,
  ["heat-pipe"] = true, ["heat-exchanger"] = true, ["lamp"] = true, ["train-stop"] = true,
  ["cargo-bay"] = true, ["cargo-landing-pad"] = true, ["space-platform-hub"] = true,
  ["asteroid-collector"] = true, ["thruster"] = true, ["crusher"] = true,
  ["agricultural-tower"] = true, ["lightning-attractor"] = true, ["heating-tower"] = true,
  ["burner-generator"] = true, ["market"] = true, ["unit-spawner"] = true, ["turret"] = true,
  ["simple-entity-with-owner"] = true, ["simple-entity-with-force"] = true,
}

-- Module-local prototype cache derived solely from read-only `prototypes.entity`.
local proto_lod = {}
local excluded_set
-- Non-serializable LuaChunkIterator for sliced map scans (never persisted in `storage`).
local map_iter = nil
local map_iter_key = nil
-- Chunks the rebuilt iterator has skipped so far toward `job.scanned` (module state, never read by storage writers).
local map_skipped = 0

local function is_excluded(ptype)
  if not excluded_set then
    excluded_set = {}
    for _, t in ipairs(registry.excluded_types()) do
      excluded_set[t] = true
    end
  end
  return excluded_set[ptype] == true
end

local function not_on_map(proto)
  local ok, fl = pcall(function() return proto.flags end)
  return ok and type(fl) == "table" and fl["not-on-map"] == true
end

local function proto_half_extents(proto)
  local ok, box = pcall(function() return proto.collision_box end)
  if not (ok and box and box.left_top and box.right_bottom) then
    ok, box = pcall(function() return proto.selection_box end)
  end
  if ok and box and box.left_top and box.right_bottom then
    local x1 = tonumber(box.left_top.x or box.left_top[1])
    local y1 = tonumber(box.left_top.y or box.left_top[2])
    local x2 = tonumber(box.right_bottom.x or box.right_bottom[1])
    local y2 = tonumber(box.right_bottom.y or box.right_bottom[2])
    if x1 and y1 and x2 and y2 then
      local w, h = x2 - x1, y2 - y1
      if w > 0 and h > 0 then
        return math.max(0.25, w * 0.5), math.max(0.25, h * 0.5), math.max(0.25, w * h)
      end
    end
  end
  local oktw, tw = pcall(function() return proto.tile_width end)
  local okth, th = pcall(function() return proto.tile_height end)
  local w = (oktw and tonumber(tw)) or 1
  local h = (okth and tonumber(th)) or 1
  if w <= 0 then w = 1 end
  if h <= 0 then h = 1 end
  return math.max(0.25, w * 0.5), math.max(0.25, h * 0.5), math.max(0.25, w * h)
end

local function proto_info(name)
  local cached = proto_lod[name]
  if cached ~= nil then
    return cached or nil
  end
  local proto = prototypes.entity[name]
  if not proto then
    proto_lod[name] = false
    return nil
  end
  local ptype = proto.type
  if is_excluded(ptype) or ptype == "fish" then
    proto_lod[name] = false
    return nil
  end
  if not_on_map(proto) and not NATURE_TYPES[ptype] and ptype ~= "resource" and ptype ~= "simple-entity" and ptype ~= "cliff" then
    proto_lod[name] = false
    return nil
  end
  local id = registry.entity_id(name)
  local hw, hh, area = proto_half_extents(proto)
  local glow = 0
  if GLOW_LAMP[ptype] then
    glow = 3
  elseif GLOW_STRONG[ptype] then
    glow = 2
  elseif GLOW_SOFT[ptype] then
    glow = 1
  end
  local cat = 0
  if BUILDING_TYPES[ptype] then
    cat = 1
  elseif NATURE_TYPES[ptype] then
    cat = 2
  elseif LOW_TYPES[ptype] or PROP_TYPES[ptype] then
    cat = 3
  end
  local prio
  if ptype == "lamp" then
    prio = 220
  elseif cat == 1 then
    prio = 300 + math.min(80, area) + glow * 10
  elseif PROP_TYPES[ptype] then
    prio = 120
  elseif cat == 3 then
    prio = (ptype == "resource") and 50 or (200 + math.min(40, area))
  elseif cat == 2 then
    prio = 150
  elseif ptype == "entity-ghost" or ptype == "tile-ghost" then
    prio = 10
  else
    prio = 100
  end
  cached = { id = id, hw = hw, hh = hh, area = area, glow = glow, cat = cat, prio = prio }
  proto_lod[name] = cached
  return cached
end

local function small_int(v, default)
  if type(v) ~= "number" then
    v = tonumber(v)
  end
  if v and v == v and v > -2147483648 and v < 2147483648 then
    return math.floor(v)
  end
  return default
end

local function region_in(v)
  local n = small_int(v, nil)
  if n and n >= -REGION_LIMIT and n <= REGION_LIMIT then
    return n
  end
  return nil
end

local function resolve_surface(cmd)
  if type(cmd) ~= "table" then
    return nil
  end
  if cmd.si == nil then
    local s = world.surface()
    return s and s.valid and s or nil
  end
  local si = small_int(cmd.si, nil)
  if si == nil then
    local s = world.surface()
    return s and s.valid and s or nil
  end
  if si < 1 then
    return nil
  end
  local surface = game.get_surface(si)
  return surface and surface.valid and surface or nil
end

local function state()
  local s = storage.f3d
  s.lod = s.lod or {}
  return s.lod
end

local function current_force()
  local c = puppet.get()
  if c and c.force then
    return c.force
  end
  return game.forces.player
end

function M.reset()
  map_iter, map_iter_key = nil, nil
  if storage.f3d then
    storage.f3d.lod = nil
  end
end

function M.queue_length()
  local l = storage.f3d and storage.f3d.lod
  if not l then
    return 0
  end
  local n = l.queue and (#l.queue - (l.head or 1) + 1) or 0
  if n < 0 then
    n = 0
  end
  if l.job then
    n = n + 1
  end
  if l.map_job then
    n = n + 1
  end
  return n
end

budget.register_queue("lod", M.queue_length)

local function lod_share()
  return world.queue_length() > 0 and LOD_SHARE_BUSY or LOD_SHARE_IDLE
end

-- Paginate `[rx, ry, rev, ...]` triples and emit as one or more `lodr` packets under PAGE_BYTES.
local function send_lodr_list(si, q, flat_triples)
  if #flat_triples == 0 then
    transport.send_text("lodr", ',"si":' .. si .. ',"q":' .. q .. ',"l":[]')
    return
  end
  local limit = PAGE_BYTES - 256
  local chunk, chars = {}, 0
  for i = 1, #flat_triples, 3 do
    local s1 = tostring(flat_triples[i])
    local s2 = tostring(flat_triples[i + 1])
    local s3 = tostring(flat_triples[i + 2])
    local add = #s1 + #s2 + #s3 + 3
    if #chunk > 0 and chars + add > limit then
      transport.send_text("lodr", ',"si":' .. si .. ',"q":' .. q .. ',"l":[' .. table.concat(chunk, ",") .. ']')
      chunk, chars = {}, 0
    end
    chunk[#chunk + 1] = s1
    chunk[#chunk + 1] = s2
    chunk[#chunk + 1] = s3
    chars = chars + add
  end
  if #chunk > 0 then
    transport.send_text("lodr", ',"si":' .. si .. ',"q":' .. q .. ',"l":[' .. table.concat(chunk, ",") .. ']')
  end
end

local function build_lodr_pages(all_revs)
  local items = {}
  for rk, rev in pairs(all_revs or {}) do
    if type(rev) == "number" and rev > 0 then
      local rxs, rys = string.match(rk, "^(%-?%d+),(%-?%d+)$")
      if rxs and rys then
        items[#items + 1] = { tonumber(rxs), tonumber(rys), math.floor(rev) }
      end
    end
  end
  table.sort(items, function(a, b)
    if a[2] ~= b[2] then
      return a[2] < b[2]
    end
    return a[1] < b[1]
  end)
  if #items == 0 then
    return { "" }
  end
  local limit = PAGE_BYTES - 256
  local pages, chunk, chars = {}, {}, 0
  for i = 1, #items do
    local it = items[i]
    local s1, s2, s3 = tostring(it[1]), tostring(it[2]), tostring(it[3])
    local add = #s1 + #s2 + #s3 + 3
    if #chunk > 0 and chars + add > limit then
      pages[#pages + 1] = table.concat(chunk, ",")
      chunk, chars = {}, 0
    end
    chunk[#chunk + 1] = s1
    chunk[#chunk + 1] = s2
    chunk[#chunk + 1] = s3
    chars = chars + add
  end
  if #chunk > 0 then
    pages[#pages + 1] = table.concat(chunk, ",")
  end
  return pages
end

local function build_lodm_pages_from_rows(rows)
  local cys = {}
  for cy in pairs(rows) do
    cys[#cys + 1] = cy
  end
  table.sort(cys)
  local limit = PAGE_BYTES - 256
  local pages, cur, cur_bytes = {}, {}, 0

  local function flush_page()
    if #cur > 0 then
      pages[#pages + 1] = table.concat(cur, ",")
      cur, cur_bytes = {}, 0
    end
  end

  local function push_row_str(row_str)
    local add = #row_str + (#cur > 0 and 1 or 0)
    if #cur > 0 and cur_bytes + add > limit then
      flush_page()
    end
    cur[#cur + 1] = row_str
    cur_bytes = cur_bytes + #row_str + (#cur > 1 and 1 or 0)
  end

  for _, cy in ipairs(cys) do
    local xs = rows[cy]
    table.sort(xs)
    local prefix = "[" .. cy
    local segs, seg_bytes = {}, #prefix + 1
    local run_start, run_count
    local i = 1
    while i <= #xs do
      local cx = xs[i]
      if run_start == nil then
        run_start, run_count = cx, 1
      elseif cx == run_start + run_count then
        run_count = run_count + 1
      elseif cx > run_start + run_count then
        local tok = "," .. run_start .. "," .. run_count
        if #segs > 0 and seg_bytes + #tok > limit then
          push_row_str(prefix .. table.concat(segs) .. "]")
          segs, seg_bytes = {}, #prefix + 1
        end
        segs[#segs + 1] = tok
        seg_bytes = seg_bytes + #tok
        run_start, run_count = cx, 1
      end
      i = i + 1
    end
    if run_start ~= nil then
      local tok = "," .. run_start .. "," .. run_count
      if #segs > 0 and seg_bytes + #tok > limit then
        push_row_str(prefix .. table.concat(segs) .. "]")
        segs, seg_bytes = {}, #prefix + 1
      end
      segs[#segs + 1] = tok
    end
    if #segs > 0 then
      push_row_str(prefix .. table.concat(segs) .. "]")
    end
  end
  flush_page()
  if #pages == 0 then
    pages[1] = ""
  end
  return pages
end

-- Runs one step of `s.lod.map_job`, slicing `get_chunks()` scans across ticks and sending `lodm`/`lodr`.
local function map_step(l, force)
  local job = l.map_job
  if not job then
    return
  end
  local surface = game.get_surface(job.si)
  if not (surface and surface.valid) then
    l.map_job = nil
    map_iter, map_iter_key = nil, nil
    return
  end
  if not job.pages then
    local key = job.si .. ":" .. job.q
    -- `storage` changes only on storage-held signals: rows being nil (a new job, or invalidate_map_job)
    -- starts the scan over. The iterator is module state a loading or joining peer lacks, so a missing
    -- one only rebuilds the iterator and skips the `job.scanned` chunks already in `job.rows`
    -- (get_chunks() lists the same chunks in the same order on every peer).
    if not job.rows then
      job.rows = {}
      job.scanned = 0
      map_iter = nil
    end
    if map_iter == nil or map_iter_key ~= key then
      map_iter = surface.get_chunks()
      map_iter_key = key
      map_skipped = 0
    end
    -- Skip the chunks `job.rows` already covers a slice a tick (MAP_SCAN_PER_TICK iterator calls at most),
    -- so a loaded save or a joining peer on a big map never makes one huge call burst. No storage write and
    -- no budget spend here: only the pacing differs between peers, never the result.
    local want = job.scanned or 0
    local skip_used = 0
    if map_skipped < want then
      local n = 0
      while map_skipped < want and n < MAP_SCAN_PER_TICK do
        n = n + 1
        map_skipped = map_skipped + 1
        if not map_iter() then
          map_skipped = want
          break
        end
      end
      skip_used = n
      if map_skipped < want then
        return
      end
    end
    if not budget.can(1, "lod", lod_share()) then
      return
    end
    local scanned = 0
    local done = false
    while scanned + skip_used < MAP_SCAN_PER_TICK do
      local chunk = map_iter()
      if not chunk then
        done = true
        break
      end
      scanned = scanned + 1
      local cx, cy = chunk.x, chunk.y
      if map.chunk_charted(surface, force, cx, cy) then
        local r = job.rows[cy]
        if not r then
          r = {}
          job.rows[cy] = r
        end
        r[#r + 1] = cx
      end
    end
    job.scanned = (job.scanned or 0) + scanned
    map_skipped = job.scanned
    budget.spend(math.max(1, math.ceil(scanned / 256)), "lod")
    if not done then
      return
    end
    map_iter, map_iter_key = nil, nil
    job.pages = build_lodm_pages_from_rows(job.rows)
    job.rev_pages = build_lodr_pages(world.all_region_revs(job.si))
    job.rows = nil
    job.idx = 1
    job.rev_idx = 1
    l.map_dirty = nil
  end
  local sent = 0
  local parts = #job.pages
  while job.idx <= parts and sent < MAP_PAGES_PER_TICK and transport.backlog() < MAX_BACKLOG do
    if sent > 0 and not budget.can(1, "lod", lod_share()) then
      return
    end
    if sent > 0 then
      budget.spend(1, "lod")
    end
    transport.send_text("lodm", ',"si":' .. job.si .. ',"q":' .. job.q .. ',"part":' .. job.idx
      .. ',"parts":' .. parts .. ',"w":[' .. job.pages[job.idx] .. ']')
    job.idx = job.idx + 1
    sent = sent + 1
  end
  if job.idx > parts then
    local rparts = #job.rev_pages
    while job.rev_idx <= rparts and transport.backlog() < MAX_BACKLOG do
      transport.send_text("lodr", ',"si":' .. job.si .. ',"q":' .. job.q .. ',"l":[' .. job.rev_pages[job.rev_idx] .. ']')
      job.rev_idx = job.rev_idx + 1
    end
    if job.rev_idx > rparts then
      l.map_job = nil
    end
  end
end

local function sample_tiles_rle(surface, x0, y0, n, res)
  local half = math.floor(res / 2)
  local tl = {}
  local cur_id, cur_count = nil, 0
  for cy_i = 0, n - 1 do
    local ty = y0 + cy_i * res + half
    for cx_i = 0, n - 1 do
      local tx = x0 + cx_i * res + half
      local tile = surface.get_tile(tx, ty)
      local tid = (tile and tile.valid) and registry.tile_id(tile.name) or 1
      if tid == cur_id then
        cur_count = cur_count + 1
      else
        if cur_id ~= nil then
          tl[#tl + 1] = cur_id
          tl[#tl + 1] = cur_count
        end
        cur_id, cur_count = tid, 1
      end
    end
  end
  if cur_id ~= nil then
    tl[#tl + 1] = cur_id
    tl[#tl + 1] = cur_count
  end
  return tl
end

local function chunk_pollution(surface, cx, cy)
  local okk, kind = pcall(function()
    local k = surface.pollutant_type
    return k and k.name
  end)
  if okk and kind ~= nil and kind ~= "pollution" then
    return nil
  end
  local okp, p = pcall(surface.get_pollution, { cx * CHUNK + 16, cy * CHUNK + 16 })
  if okp and p and p >= 0.5 then
    return math.floor(p + 0.5)
  end
  return nil
end

local function send_lod_chunk(si, cx, cy, res, rv, tl_str, el_str, pol)
  local pol_field = (pol and pol >= 1) and (',"pol":' .. pol) or ""
  transport.send_text("lod", ',"si":' .. si .. ',"cx":' .. cx .. ',"cy":' .. cy .. ',"res":' .. res
    .. ',"rv":' .. rv .. pol_field .. ',"tl":[' .. tl_str .. '],"el":[' .. el_str .. ']')
end

local function send_lod_none(si, cx, cy, res)
  transport.send_text("lod", ',"si":' .. si .. ',"cx":' .. cx .. ',"cy":' .. cy .. ',"res":' .. res .. ',"none":1')
end

local function sample_macro_chunk(surface, force, si, cx, cy, res)
  if not (map.chunk_charted(surface, force, cx, cy) and surface.is_chunk_generated({ cx, cy })) then
    send_lod_none(si, cx, cy, res)
    return 1
  end
  local n = CHUNK / res
  local cells = n * n
  local x0, y0 = cx * CHUNK, cy * CHUNK
  local tl = sample_tiles_rle(surface, x0, y0, n, res)
  local tl_str = table.concat(tl, ",")
  local rv = world.rev(si, cx .. "," .. cy)
  local excluded = registry.excluded_types()
  local pol = chunk_pollution(surface, cx, cy)
  local area = { { x0, y0 }, { x0 + CHUNK, y0 + CHUNK } }
  local has_any = surface.count_entities_filtered({ area = area, type = excluded, invert = true, limit = 1 })
  if has_any == 0 then
    send_lod_chunk(si, cx, cy, res, rv, tl_str, "0,0," .. cells, pol)
    return 1 + math.ceil(cells / budget.TILES_PER_UNIT)
  end
  local cell_area_tiles = res * res
  local count_cap = res == 8 and 16 or (res == 16 and 32 or COUNT_CAP)
  local el = {}
  local cur_pid, cur_flags, cur_count = nil, nil, 0
  for cy_i = 0, n - 1 do
    local ay0 = y0 + cy_i * res
    for cx_i = 0, n - 1 do
      local ax0 = x0 + cx_i * res
      local cell_box = { { ax0, ay0 }, { ax0 + res, ay0 + res } }
      local found = surface.find_entities_filtered({ area = cell_box, type = excluded, invert = true, limit = MACRO_LIMIT })
      local best
      for _, e in pairs(found) do
        local info = proto_info(e.name)
        if info and (not best or info.prio > best.prio or (info.prio == best.prio and info.id < best.id)) then
          best = info
        end
      end
      local pid, flags = 0, 0
      if best then
        local total = #found
        if total >= MACRO_LIMIT then
          total = surface.count_entities_filtered({ area = cell_box, type = excluded, invert = true, limit = COUNT_CAP })
        end
        local cov = math.min(1, best.area / cell_area_tiles)
        local density = math.max(1, math.min(15, math.floor(math.max(cov, math.min(1, total / count_cap)) * 14 + 1)))
        pid = best.id
        flags = density + best.glow * 16 + best.cat * 64
      end
      if pid == cur_pid and flags == cur_flags then
        cur_count = cur_count + 1
      else
        if cur_pid ~= nil then
          el[#el + 1] = cur_pid
          el[#el + 1] = cur_flags
          el[#el + 1] = cur_count
        end
        cur_pid, cur_flags, cur_count = pid, flags, 1
      end
    end
  end
  if cur_pid ~= nil then
    el[#el + 1] = cur_pid
    el[#el + 1] = cur_flags
    el[#el + 1] = cur_count
  end
  send_lod_chunk(si, cx, cy, res, rv, tl_str, table.concat(el, ","), pol)
  return 1 + math.ceil(cells / budget.TILES_PER_UNIT) + cells
end

local function strips_for(count, res)
  if count <= 120 then
    return 1
  elseif count <= 280 then
    return 2
  elseif count <= 640 then
    return 4
  elseif count <= 1400 or res == 4 then
    return 8
  end
  return 16
end

local function fine_price(job)
  if job.step < 0 then
    return 2
  elseif job.step == 0 then
    local n = CHUNK / job.res
    return math.max(1, math.ceil((n * n) / budget.TILES_PER_UNIT))
  end
  return 1 + math.ceil((job.count or 1) / math.max(1, job.strips) / 16)
end

local function fine_step(l, surface, force)
  local job = l.job
  local si, cx, cy, res = job.si, job.cx, job.cy, job.res
  local n = CHUNK / res
  local cells = n * n
  local x0, y0 = cx * CHUNK, cy * CHUNK
  local excluded = registry.excluded_types()
  if job.step < 0 then
    if not (map.chunk_charted(surface, force, cx, cy) and surface.is_chunk_generated({ cx, cy })) then
      send_lod_none(si, cx, cy, res)
      l.job = nil
      return
    end
    local area = { { x0, y0 }, { x0 + CHUNK, y0 + CHUNK } }
    if surface.count_entities_filtered({ area = area, type = excluded, invert = true, limit = 1 }) == 0 then
      local tl_str = table.concat(sample_tiles_rle(surface, x0, y0, n, res), ",")
      local rv = world.rev(si, cx .. "," .. cy)
      send_lod_chunk(si, cx, cy, res, rv, tl_str, "0,0," .. cells, chunk_pollution(surface, cx, cy))
      l.job = nil
      return
    end
    local total = surface.count_entities_filtered({ area = area, type = excluded, invert = true })
    job.count = total
    job.strips = strips_for(total, res)
    job.step = 0
    return
  end
  if not surface.is_chunk_generated({ cx, cy }) then
    send_lod_none(si, cx, cy, res)
    l.job = nil
    return
  end
  if job.step == 0 then
    job.tl_str = table.concat(sample_tiles_rle(surface, x0, y0, n, res), ",")
    job.ep, job.ef, job.prio, job.cov = {}, {}, {}, {}
    for idx = 1, cells do
      job.ep[idx] = 0
      job.ef[idx] = 0
      job.prio[idx] = 0
      job.cov[idx] = 0
    end
    job.step = 1
    return
  end
  local h = CHUNK / job.strips
  local ya = y0 + (job.step - 1) * h
  local yb = ya + h
  local found = surface.find_entities_filtered({
    area = { { x0, ya }, { x0 + CHUNK, yb } },
    type = excluded,
    invert = true,
  })
  local x_end, y_end = x0 + CHUNK, y0 + CHUNK
  for _, e in pairs(found) do
    local pos = e.position
    local px, py = pos.x, pos.y
    if (py >= ya and py < yb) or (job.step == 1 and py < y0) or (job.step == job.strips and py >= y_end) then
      local info = proto_info(e.name)
      if info then
        local bx1, by1 = px - info.hw, py - info.hh
        local bx2, by2 = px + info.hw, py + info.hh
        if bx2 > x0 and bx1 < x_end and by2 > y0 and by1 < y_end then
          local i1 = math.max(0, math.floor((bx1 - x0) / res))
          local i2 = math.min(n - 1, math.floor((bx2 - x0 - 0.001) / res))
          local j1 = math.max(0, math.floor((by1 - y0) / res))
          local j2 = math.min(n - 1, math.floor((by2 - y0 - 0.001) / res))
          for j = j1, j2 do
            local cy0 = y0 + j * res
            local oy = math.max(0, math.min(by2, cy0 + res) - math.max(by1, cy0))
            local row_off = j * n
            for i = i1, i2 do
              local cx0 = x0 + i * res
              local ox = math.max(0, math.min(bx2, cx0 + res) - math.max(bx1, cx0))
              local ov = ox * oy
              if ov <= 0 then
                ov = 0.25
              end
              local idx = row_off + i + 1
              job.cov[idx] = job.cov[idx] + ov
              local cur_p = job.prio[idx]
              if info.prio > cur_p or (info.prio == cur_p and (job.ep[idx] == 0 or info.id < job.ep[idx])) then
                job.prio[idx] = info.prio
                job.ep[idx] = info.id
                job.ef[idx] = info.glow * 16 + info.cat * 64
              end
            end
          end
        end
      end
    end
  end
  if job.step < job.strips then
    job.step = job.step + 1
    return
  end
  local cell_area_tiles = res * res
  local el = {}
  local cur_pid, cur_flags, cur_count = nil, nil, 0
  for idx = 1, cells do
    local pid = job.ep[idx]
    local flags = 0
    if pid ~= 0 then
      local density = math.max(1, math.min(15, math.floor(math.min(1, job.cov[idx] / cell_area_tiles) * 14 + 1)))
      flags = density + job.ef[idx]
    end
    if pid == cur_pid and flags == cur_flags then
      cur_count = cur_count + 1
    else
      if cur_pid ~= nil then
        el[#el + 1] = cur_pid
        el[#el + 1] = cur_flags
        el[#el + 1] = cur_count
      end
      cur_pid, cur_flags, cur_count = pid, flags, 1
    end
  end
  if cur_pid ~= nil then
    el[#el + 1] = cur_pid
    el[#el + 1] = cur_flags
    el[#el + 1] = cur_count
  end
  local rv = world.rev(si, cx .. "," .. cy)
  send_lod_chunk(si, cx, cy, res, rv, job.tl_str, table.concat(el, ","), chunk_pollution(surface, cx, cy))
  l.job = nil
end

function M.handle(cmd)
  if type(cmd) ~= "table" or not storage.f3d.client then
    return
  end
  local act = cmd.act
  if type(act) ~= "string" then
    return
  end
  if act == "stop" then
    local l = storage.f3d.lod
    if l then
      l.queue = nil
      l.head = nil
      l.job = nil
    end
    return
  end
  local surface = resolve_surface(cmd)
  if not surface then
    return
  end
  local si = surface.index
  local q = small_int(cmd.q, 0)
  if act == "map" then
    local l = state()
    l.map_si = si
    l.map_q = q
    l.map_dirty = nil
    map_iter, map_iter_key = nil, nil
    l.map_job = { si = si, q = q, rows = nil, scanned = 0, pages = nil, rev_pages = nil, idx = 1, rev_idx = 1 }
    return
  end
  if act == "revs" then
    local rg = cmd.rg
    local diff = {}
    if type(rg) == "table" then
      local count = math.min(#rg, MAX_REVS_ASK)
      for i = 1, count do
        local entry = rg[i]
        if type(entry) == "table" then
          local rx = region_in(entry[1])
          local ry = region_in(entry[2])
          local crev = small_int(entry[3], nil)
          if rx and ry and crev ~= nil then
            local srev = world.region_rev(si, rx, ry)
            if srev ~= crev then
              diff[#diff + 1] = rx
              diff[#diff + 1] = ry
              diff[#diff + 1] = srev
            end
          end
        end
      end
    end
    send_lodr_list(si, q, diff)
    return
  end
  if act == "want" then
    local res = small_int(cmd.res, 8)
    if not VALID_RES[res] then
      res = 8
    end
    local queue = {}
    local seen = {}
    if type(cmd.c) == "table" then
      local limit = math.min(#cmd.c, MAX_WANT_SCAN)
      for i = 1, limit do
        if #queue >= MAX_WANT then
          break
        end
        local entry = cmd.c[i]
        if type(entry) == "table" then
          local cx = world.chunk_in(entry[1])
          local cy = world.chunk_in(entry[2])
          if cx and cy then
            local k = cx .. "," .. cy
            if not seen[k] then
              seen[k] = true
              queue[#queue + 1] = { cx, cy }
            end
          end
        end
      end
    end
    local l = state()
    l.queue = queue
    l.head = 1
    l.job = nil
    l.want_si = si
    l.want_res = res
    return
  end
end

function M.tick()
  local s = storage.f3d
  if not s or not s.client then
    return
  end
  local l = s.lod
  if not l then
    return
  end
  local force = current_force()
  if l.map_job then
    local tp = profile.start()
    local ok, err = pcall(map_step, l, force)
    profile.stop("lod.map", tp)
    if not ok then
      l.map_job = nil
      transport.send_now({ t = "msg", text = "LOD map error: " .. tostring(err) })
    end
  end
  while transport.backlog() < MAX_BACKLOG do
    if l.job then
      local jsurf = game.get_surface(l.job.si)
      if not (jsurf and jsurf.valid) then
        l.job = nil
        return
      end
      local price = fine_price(l.job)
      if not budget.can(price, "lod", lod_share()) then
        return
      end
      budget.spend(price, "lod")
      local tp = profile.start()
      local ok, err = pcall(fine_step, l, jsurf, force)
      profile.stop("lod.fine", tp)
      if not ok then
        l.job = nil
        transport.send_now({ t = "msg", text = "LOD error: " .. tostring(err) })
        return
      end
    else
      local entry = l.queue and l.queue[l.head]
      if not entry then
        l.queue, l.head = nil, nil
        return
      end
      local surface = l.want_si and game.get_surface(l.want_si)
      if not (surface and surface.valid) then
        l.queue, l.head = nil, nil
        return
      end
      local res = l.want_res or 8
      if res >= 8 then
        local n = CHUNK / res
        local price = 2 + n * n
        if not budget.can(price, "lod", lod_share()) then
          return
        end
        l.queue[l.head] = nil
        l.head = l.head + 1
        local tp = profile.start()
        local ok, spent = pcall(sample_macro_chunk, surface, force, l.want_si, entry[1], entry[2], res)
        profile.stop("lod.macro", tp)
        if not ok then
          l.queue, l.head = nil, nil
          transport.send_now({ t = "msg", text = "LOD error: " .. tostring(spent) })
          return
        end
        budget.spend(spent, "lod")
      else
        l.queue[l.head] = nil
        l.head = l.head + 1
        l.job = { si = l.want_si, cx = entry[1], cy = entry[2], res = res, step = -1 }
      end
    end
  end
end

local function invalidate_map_job(si)
  local l = storage.f3d and storage.f3d.lod
  if not l then
    return
  end
  if l.map_job and l.map_job.si == si and not l.map_job.pages then
    l.map_job.rows = nil
    map_iter, map_iter_key = nil, nil
  elseif l.map_job and l.map_job.si == si and l.map_job.idx == 1 then
    l.map_job.pages = nil
    l.map_job.rev_pages = nil
    l.map_job.rows = nil
    map_iter, map_iter_key = nil, nil
  elseif l.map_job and l.map_job.si == si then
    l.map_dirty = true
  elseif l.map_si == si then
    l.map_dirty = true
  end
end

local function bump_and_invalidate(si, cx, cy)
  world.bump_region(si, math.floor(cx / REGION), math.floor(cy / REGION))
  invalidate_map_job(si)
end

function M.on_chunk_charted(event)
  local si = event.surface_index
  local pos = event.position
  if not (si and pos) then
    return
  end
  local cx = pos.x or pos[1]
  local cy = pos.y or pos[2]
  if cx and cy then
    bump_and_invalidate(si, cx, cy)
  end
end

function M.on_chunk_deleted(event)
  local si = event.surface_index
  local positions = event.positions
  if not (si and type(positions) == "table") then
    return
  end
  local seen = {}
  local invalidated = false
  for _, pos in pairs(positions) do
    local cx = pos.x or pos[1]
    local cy = pos.y or pos[2]
    if cx and cy then
      local rx, ry = math.floor(cx / REGION), math.floor(cy / REGION)
      local rk = rx .. "," .. ry
      if not seen[rk] then
        seen[rk] = true
        world.bump_region(si, rx, ry)
      end
      if not invalidated then
        invalidated = true
        invalidate_map_job(si)
      end
    end
  end
end

function M.register()
  script.on_event(defines.events.on_chunk_charted, M.on_chunk_charted)
  script.on_event(defines.events.on_chunk_deleted, M.on_chunk_deleted)
end

return M
