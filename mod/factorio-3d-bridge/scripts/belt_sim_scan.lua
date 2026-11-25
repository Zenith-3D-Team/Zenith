-- Square/trace scanning, chunk belt caching, touched-belt tracking, and chain loading for belt_sim.lua.
-- Shares `M` and `H` via `init(m, h)`.

local registry = require("scripts.registry")
local transport = require("scripts.transport")
local world = require("scripts.world")
local map = require("scripts.map")
local tracker = require("scripts.tracker")
local budget = require("scripts.budget")
local profile = require("scripts.profile")
local write = require("scripts.belt_sim_write")
local options = require("scripts.belt_sim_options")

local floor = math.floor
local ceil = math.ceil
local LANE_KEYS = write.LANE_KEYS
local S = write.S
local O = options.O
local ins_driven = options.ins_driven
local UNITS_PER_BUDGET_UNIT = options.UNITS_PER_BUDGET_UNIT

local M, H
local mod = {}

local function chunk_belts(b, surface, cx, cy)
  b.bc = b.bc or {}
  local key = H.chunk_key(cx * 32, cy * 32)
  local list = b.bc[key]
  if list and game.tick - list.tick < H.CHUNK_REFRESH + key % H.CHUNK_REFRESH then
    return list, 0
  end
  list = { tick = game.tick }
  local types = registry.belt_types()
  local units = H.FIND_UNITS
  if #types > 0 then
    local x0, y0 = cx * 32, cy * 32
    for _, belt in pairs(surface.find_entities_filtered({ area = { { x0, y0 }, { x0 + 32, y0 + 32 } }, type = types })) do
      local q = belt.position
      if belt.unit_number and q.x >= x0 and q.x < x0 + 32 and q.y >= y0 and q.y < y0 + 32 then
        list[#list + 1] = { belt, belt.unit_number, q.x, q.y }
        units = units + 1
      end
    end
  end
  b.bc[key] = list
  return list, units
end

-- What an actor's check reads: an inserter's hand (how many it holds), a drill's mining progress and
-- its productivity bonus's (they go round when it drops what it mined).
local function touched(entity)
  local s = storage.f3d
  local b = s and s.bs
  if not (b and entity and entity.valid) then
    return
  end
  local t = entity.type
  if not (H.BELTISH[t] or t == "inserter" or t == "mining-drill") then
    return
  end
  local p = entity.position
  b.dirty = b.dirty or {}
  b.dirty[#b.dirty + 1] = { entity.surface.index, p.x, p.y, entity.unit_number or 0, H.BELTISH[t] or false }
  -- (built_now) The belt itself, for the next tick: {entity, unit number, x, y, an underground's other end as it
  -- is now (a removed one's partner is unpaired by then; a new exit's entrance has new hidden lines)}. Kept
  -- whatever the switch says (it is read at a tick's start, module-local): the round drops the list when it is off.
  local u = entity.unit_number
  if H.BELTISH[t] and u then
    local partner
    if t == "underground-belt" then
      local ok, o = pcall(function() return entity.underground_belt_neighbour end)
      if ok and o and o.valid and o.unit_number then
        partner = o
      end
    end
    b.fresh = b.fresh or {}
    b.fresh[#b.fresh + 1] = { entity, u, p.x, p.y, partner }
  end
end
tracker.listeners[#tracker.listeners + 1] = touched

-- The dirty places (from on_tick): chunk lists and targets round them forgotten, and loaded belts
-- near them marked to be worked out again and sent again (lm and sl). A scan follows.
local function forget_touched(b)
  local dirty = b.dirty
  if not dirty then
    return 0
  end
  b.dirty = nil
  M.counts.dirty = (M.counts.dirty or 0) + #dirty
  local si = world.surface().index
  local units = 0
  for _, at in ipairs(dirty) do
    if at[1] == si then
      local x, y = at[2], at[3]
      if b.bc then
        for cx = floor((x - 2) / 32), floor((x + 2) / 32) do
          for cy = floor((y - 2) / 32), floor((y + 2) / 32) do
            b.bc[H.chunk_key(cx * 32, cy * 32)] = nil
          end
        end
      end
      if b.bt then
        for cx = floor((x - H.REACH) / 32), floor((x + H.REACH) / 32) do
          for cy = floor((y - H.REACH) / 32), floor((y + H.REACH) / 32) do
            b.bt[H.chunk_key(cx * 32, cy * 32)] = nil
          end
        end
      end
      local types = registry.belt_types()
      if #types > 0 then
        local r = H.REACH + 1.5
        local found = world.surface().find_entities_filtered({ area = { { x - r, y - r }, { x + r, y + r } }, type = types })
        units = units + H.FIND_UNITS + #found
        for _, belt in pairs(found) do
          local u = belt.unit_number
          if u and b.belts[u] then
            b.reload[#b.reload + 1] = u
          end
        end
      end
      -- (A belt built or removed changes the scan; an inserter or drill only its neighbours' records.)
      if at[5] then
        b.rescan = true
      end
    end
  end
  return units
end

---------------------------------------------------------------------------------------------
-- Lanes: their kind and meta, the cheap check, the full read.

local function new_scan(f, r)
  local sc = { fx = f.x, fy = f.y, r = r, tick = game.tick, chunks = {}, ci = 1, by = {}, top = -1 }
  if options.trace_on() then
    sc.near, sc.tkey = options.near_now(), options.trace_key()
  end
  return sc
end

-- The unit numbers of the belts that feed a belt and of those it feeds (an underground's other end
-- among them).
local function neighbours_of(belt)
  local ins, outs = {}, {}
  if belt.type == "underground-belt" then
    local ok, other = pcall(function() return belt.underground_belt_neighbour end)
    if ok and other and other.valid and other.unit_number then
      local list = belt.belt_to_ground_type == "input" and outs or ins
      list[#list + 1] = other.unit_number
    end
  end
  local ok, nb = pcall(function() return belt.belt_neighbours end)
  if ok and nb then
    for _, e in pairs(nb.inputs or {}) do
      if e.valid and e.unit_number then
        ins[#ins + 1] = e.unit_number
      end
    end
    for _, e in pairs(nb.outputs or {}) do
      if e.valid and e.unit_number then
        outs[#outs + 1] = e.unit_number
      end
    end
  end
  return ins, outs
end

-- area trace, over a finished scan: the belts within sc.near of the focus, then (breadth first, up to
-- `limit` units; the trace goes on next tick where it stopped) the belts feeding them back to their
-- origins, at most trace_hops belts back, then the belts those all feed trace_down belts on. sc.sel:
-- unit number -> true for every belt to load. tr: {q (indices), qi, h (index -> hops), phase, order}.
-- Returns the units spent and whether it finished.
local function trace_step(sc, limit)
  local tr = sc.tr
  local spent = 0
  if not tr then
    tr = { q = {}, qi = 1, h = {}, phase = 1, order = {} }
    sc.tr = tr
    sc.sel = {}
    local stop = sc.first[sc.near] or sc.first[sc.top + 1] or 1
    if sc.near > sc.top then
      stop = sc.n + 1
    end
    for j = 1, stop - 1 do
      tr.q[#tr.q + 1] = j
      tr.h[j] = 0
      tr.order[#tr.order + 1] = j
      sc.sel[sc.units[j]] = true
    end
    spent = spent + #tr.q * H.SCAN_UNITS
  end
  local hops = floor(tonumber(O.trace_hops) or 0)
  local down = floor(tonumber(O.trace_down) or 0)
  local idx, ents = sc.idx, sc.ents
  while spent < limit do
    if tr.qi > #tr.q then
      if tr.phase == 1 then
        -- Downstream from everything traced so far.
        tr.phase, tr.q, tr.qi = 2, {}, 1
        for _, j in ipairs(tr.order) do
          tr.q[#tr.q + 1] = j
          tr.h[j] = 0
        end
        tr.order = nil
        if down <= 0 then
          break
        end
      else
        break
      end
    end
    local j = tr.q[tr.qi]
    tr.qi = tr.qi + 1
    local h = tr.h[j]
    local bound = tr.phase == 1 and hops or down
    if (bound <= 0 or h < bound) and ents[j].valid then
      spent = spent + H.TARGET_UNITS
      local ins, outs = neighbours_of(ents[j])
      for _, u in ipairs(tr.phase == 1 and ins or outs) do
        local k = idx[u]
        if k and not sc.sel[u] then
          sc.sel[u] = true
          tr.h[k] = h + 1
          tr.q[#tr.q + 1] = k
          if tr.order then
            tr.order[#tr.order + 1] = k
          end
        end
      end
    else
      spent = spent + H.SKIP_UNITS
    end
  end
  local done = tr.phase == 2 and (tr.qi > #tr.q or down <= 0)
  if done then
    local n = 0
    for _ in pairs(sc.sel) do
      n = n + 1
    end
    sc.nsel = n
    M.counts.traced = n
    sc.tr = nil
  end
  return spent, done
end

-- (scan_incremental) The scan's rings flattened, nearest first, up to `limit` units: sc.fl the cursor (ring, k) and
-- the arrays being filled (the spare scan's when there is one: its index cleared of its units first, a slice at a
-- time too). Returns the units spent and whether it finished (sc.ents and the rest set, sc.by gone).
local function flatten_step(b, sc, limit)
  -- (Units a belt flattened, and a slot of the spare cleared: about 1 us a belt live, 2.1.24, as a unit is. Locals
  -- here: the file is at Lua's 200.)
  local FLAT_UNITS, CLEAR_UNITS = 1, 0.1
  local spent = 0
  local fl = sc.fl
  if not fl then
    local sp = b.spare
    b.spare = nil
    if sp and sp.ents and sp.idx then
      fl = { ring = 0, k = 1, n = 0, ents = sp.ents, units = sp.units, xs = sp.xs, ys = sp.ys, rings = sp.rings,
        first = sp.first, idx = sp.idx, old_n = sp.n or 0, old_top = sp.top or -1, ci = 1 }
    else
      fl = { ring = 0, k = 1, n = 0, ents = {}, units = {}, xs = {}, ys = {}, rings = {}, first = {}, idx = {},
        old_n = 0, old_top = -1, ci = 1 }
    end
    sc.fl = fl
  end
  -- The spare's index emptied of its units (each set below again if it is in this scan).
  local idx, units = fl.idx, fl.units
  local ci, old_n = fl.ci, fl.old_n
  while ci <= old_n do
    if spent >= limit then
      fl.ci = ci
      return spent, false
    end
    local last = math.min(old_n, ci + 255)
    for j = ci, last do
      idx[units[j]] = nil
    end
    spent = spent + (last - ci + 1) * CLEAR_UNITS
    ci = last + 1
  end
  fl.ci = ci
  local ents, xs, ys, rings, first = fl.ents, fl.xs, fl.ys, fl.rings, fl.first
  local by, top = sc.by, sc.top
  local n, ring, k = fl.n, fl.ring, fl.k
  while ring <= top do
    if k == 1 then
      first[ring] = n + 1
    end
    local bucket = by[ring]
    local m = bucket and #bucket or 0
    while k <= m do
      if spent >= limit then
        fl.n, fl.ring, fl.k = n, ring, k
        return spent, false
      end
      local last = math.min(m, k + 63)
      for x = k, last do
        local e = bucket[x]
        n = n + 1
        local unit = e[2]
        ents[n], units[n], xs[n], ys[n], rings[n] = e[1], unit, e[3], e[4], ring
        idx[unit] = n
      end
      spent = spent + (last - k + 1) * FLAT_UNITS
      k = last + 1
    end
    ring, k = ring + 1, 1
  end
  first[top + 1] = n + 1
  -- What the spare held past the new end: gone (a few ticks' worth at most; its units' index already cleared).
  for j = n + 1, fl.old_n do
    ents[j], units[j], xs[j], ys[j], rings[j] = nil, nil, nil, nil, nil
  end
  for r = top + 2, fl.old_top + 1 do
    first[r] = nil
  end
  spent = spent + math.max(0, fl.old_n - n) * CLEAR_UNITS
  sc.ents, sc.units, sc.xs, sc.ys, sc.rings, sc.first, sc.n, sc.idx = ents, units, xs, ys, rings, first, n, idx
  sc.by, sc.chunks, sc.fl = nil, nil, nil
  return spent, true
end

-- Scans up to `limit` units: returns the units spent and whether it finished. Once a scan has been
-- taken, at most SCAN_FINDS a tick of its chunks are searched afresh (chunk_belts' lists expire
-- together, CHUNK_REFRESH after a load: a scan again then found 10-20 chunks on one tick, 30-85 ms
-- at -62,-26); the first scan reads as many as the units allow.
local function scan_step(b, sc, limit)
  local surface = world.surface()
  local spent = 0
  local finds, most = 0, b.scan and H.SCAN_FINDS or math.huge
  if not sc.list then
    -- The chunks the square touches.
    local list = {}
    for cx = floor((sc.fx - sc.r) / 32), floor((sc.fx + sc.r) / 32) do
      for cy = floor((sc.fy - sc.r) / 32), floor((sc.fy + sc.r) / 32) do
        list[#list + 1] = { cx, cy }
      end
    end
    sc.list = list
  end
  -- (The remote view's filter as the game is now, not its module-local cache: what is read goes in
  -- storage.)
  local seen = map.view_filter(true)
  -- (scan_incremental: a belt put in its ring priced at 0.75 units, about what it costs live; SCAN_UNITS before.)
  local per_belt = O.scan_incremental and 0.75 or H.SCAN_UNITS
  while spent < limit and sc.ci <= #sc.list do
    local c = sc.list[sc.ci]
    sc.ci = sc.ci + 1
    local belts, u = chunk_belts(b, surface, c[1], c[2])
    spent = spent + u + H.FIND_UNITS
    if u > 0 then
      finds = finds + 1
    end
    for _, e in ipairs(belts) do
      local dx, dy = e[3] - sc.fx, e[4] - sc.fy
      local ring = floor(math.max(dx < 0 and -dx or dx, dy < 0 and -dy or dy))
      if ring < sc.r and (not seen or seen(e[3], e[4])) then
        local bucket = sc.by[ring]
        if not bucket then
          bucket = {}
          sc.by[ring] = bucket
          if ring > sc.top then
            sc.top = ring
          end
        end
        bucket[#bucket + 1] = e
        spent = spent + per_belt
      end
    end
    if finds >= most then
      break
    end
  end
  if sc.ci <= #sc.list then
    return spent, false
  end
  if O.scan_incremental and not sc.flat_waited then
    -- (scan_incremental: flattened over as many ticks as the units allow, FLAT_UNITS a belt, into the arrays of
    -- the scan before last where there is one (b.spare: nothing holds them any more), what they held past the
    -- new end cleared as it goes. take_scan the tick after the last of it, not on top of it. All at once
    -- before: 16-27 ms on Zenith Test's square with the collector out of the way.)
    if not sc.ents then
      local tf = profile.start()
      local u, done = H.flatten_step(b, sc, limit - spent)
      spent = spent + u
      profile.stop("bsc.flat", tf)
      if not done then
        return spent, false
      end
    end
    sc.flat_waited = true
    return spent, false
  elseif not sc.ents then
    local tf = profile.start()
    -- Flattened nearest ring first, with where each ring starts.
    local ents, units, xs, ys, rings, first = {}, {}, {}, {}, {}, {}
    for ring = 0, sc.top do
      first[ring] = #ents + 1
      for _, e in ipairs(sc.by[ring] or {}) do
        local j = #ents + 1
        ents[j], units[j], xs[j], ys[j], rings[j] = e[1], e[2], e[3], e[4], ring
      end
    end
    first[sc.top + 1] = #ents + 1
    local idx = {}
    for j = 1, #ents do
      idx[units[j]] = j
    end
    sc.ents, sc.units, sc.xs, sc.ys, sc.rings, sc.first, sc.n, sc.idx = ents, units, xs, ys, rings, first, #ents, idx
    sc.by, sc.chunks = nil, nil
    spent = spent + #ents * H.SCAN_UNITS
    profile.stop("bsc.flat", tf)
  end
  -- (area trace: the belts to load, traced from the near square.)
  if sc.near and not sc.nsel then
    local u, done = trace_step(sc, limit - spent)
    spent = spent + u
    if not done then
      return spent, false
    end
  end
  sc.list = nil
  return spent, true
end

-- Slices take_scan() belt drops and chunk/actor cache pruning across ticks (take_slice).

local function prune_step(b, p)
  local did = false
  local dq = b.drop_q
  if dq then
    did = true
    local i = b.drop_i or 1
    local n = #dq
    local cap = M.drop_slice or math.max(H.DROP_MIN, math.min(H.DROP_MAX, floor(math.max(0, budget.left()))))
    local stop = math.min(n, i + cap - 1)
    while i <= stop do
      H.drop_belt(b, dq[i], p)
      i = i + 1
    end
    if i > n then
      b.drop_q, b.drop_i = nil, nil
    else
      b.drop_i = i
    end
  end
  local pr = b.prune
  if pr then
    did = true
    local budget_n = H.PRUNE
    if pr.bc and pr.bci <= #pr.bc then
      local stop = math.min(#pr.bc, pr.bci + budget_n - 1)
      if b.bc then
        for i = pr.bci, stop do
          b.bc[pr.bc[i]] = nil
        end
      end
      budget_n = budget_n - (stop - pr.bci + 1)
      pr.bci = stop + 1
    end
    if budget_n > 0 and pr.bt and pr.bti <= #pr.bt then
      local stop = math.min(#pr.bt, pr.bti + budget_n - 1)
      if b.bt then
        for i = pr.bti, stop do
          b.bt[pr.bt[i]] = nil
        end
      end
      budget_n = budget_n - (stop - pr.bti + 1)
      pr.bti = stop + 1
    end
    if budget_n > 0 and pr.rt and pr.rti <= #pr.rt then
      local stop = math.min(#pr.rt, pr.rti + budget_n - 1)
      if b.retry then
        for i = pr.rti, stop do
          b.retry[pr.rt[i]] = nil
        end
      end
      budget_n = budget_n - (stop - pr.rti + 1)
      pr.rti = stop + 1
    end
    if budget_n > 0 and pr.ac and pr.aci <= #pr.ac then
      local live = {}
      for _, t in pairs(b.bt or {}) do
        for _, u in ipairs(t.a or {}) do
          live[u] = true
        end
      end
      local stop = math.min(#pr.ac, pr.aci + budget_n - 1)
      for i = pr.aci, stop do
        local u = pr.ac[i]
        if not live[u] then
          b.actors[u] = nil
        end
      end
      pr.aci = stop + 1
      if pr.aci > #pr.ac then
        local list, seen = {}, {}
        for _, u in ipairs(b.alist) do
          if b.actors[u] then
            H.enlist(list, seen, u)
          end
        end
        b.alist, b.aseen = list, seen
      end
    end
    if (not pr.bc or pr.bci > #pr.bc) and (not pr.bt or pr.bti > #pr.bt)
        and (not pr.rt or pr.rti > #pr.rt) and (not pr.ac or pr.aci > #pr.ac) then
      b.prune = nil
    end
  end
  if did then
    M.counts.take_slices = (M.counts.take_slices or 0) + 1
  end
end

-- A finished scan taken: loaded belts outside it dropped; the load pointer kept past inner loaded rings.
local function scan_cap_edge(b, sc, c)
  local keep = sc.r
  local edge = nil
  if c < math.huge then
    -- Items + lanes of the loaded lanes, ring by ring, and the cap's edge kept or moved.
    local cum, total = {}, 0
    for ring = 0, sc.top do
      for j = sc.first[ring], sc.first[ring + 1] - 1 do
        local unit = sc.units[j]
        if b.belts[unit] then
          for i = 1, LANE_KEYS do
            local rec = b.lanes[unit * LANE_KEYS + i]
            if rec then
              total = total + rec[1] + 1
            end
          end
        end
      end
      cum[ring] = total
    end
    edge = b.edge
    if edge then
      if (cum[edge - 1] or total) > c * H.KEEP then
        edge = nil
        for ring = 0, sc.top do
          if cum[ring] > c then
            edge = ring + 1
            break
          end
        end
      elseif (cum[edge - 1] or total) < c * H.GROW then
        edge = nil
      end
    end
    if not edge and O.take_slice then
      for ring = 0, sc.top do
        if cum[ring] > c then
          edge = ring + 1
          break
        end
      end
    end
    keep = math.min(sc.r, (edge or sc.r) + H.DROP)
  end
  b.edge = edge
  return keep
end

local function prune_scan_caches(b, sc, margin, drop, p, c)
  local sel = sc.sel
  local pad = ceil(margin / 32)
  local cx0, cx1 = floor((sc.fx - sc.r) / 32) - 1 - pad, floor((sc.fx + sc.r) / 32) + 1 + pad
  local cy0, cy1 = floor((sc.fy - sc.r) / 32) - 1 - pad, floor((sc.fy + sc.r) / 32) + 1 + pad
  local function outside(key)
    local cx, cy = floor(key / 65536) - 32768, key % 65536 - 32768
    return cx < cx0 or cx > cx1 or cy < cy0 or cy > cy1
  end
  if not O.take_slice then
    b.drop_q, b.drop_i, b.prune = nil, nil, nil
    for _, unit in ipairs(drop) do
      H.drop_belt(b, unit, p)
    end
    if b.bc then
      for key in pairs(b.bc) do
        if outside(key) then
          b.bc[key] = nil
        end
      end
    end
    if b.bt then
      local gone, kept = {}, {}
      for key, t in pairs(b.bt) do
        if outside(key) then
          b.bt[key] = nil
          for _, u in ipairs(t.a or {}) do
            gone[#gone + 1] = u
          end
        else
          for _, u in ipairs(t.a or {}) do
            kept[u] = true
          end
        end
      end
      local pruned = false
      for _, u in ipairs(gone) do
        if not kept[u] then
          b.actors[u] = nil
          pruned = true
        end
      end
      if b.retry then
        local rdrop = {}
        for u, ent in pairs(b.retry) do
          if outside(ent[2]) then
            rdrop[#rdrop + 1] = u
          end
        end
        for _, u in ipairs(rdrop) do
          b.retry[u] = nil
        end
      end
      if pruned then
        local list, seen = {}, {}
        for _, u in ipairs(b.alist) do
          if b.actors[u] then
            H.enlist(list, seen, u)
          end
        end
        b.alist, b.aseen = list, seen
      end
    end
    b.scan, b.load_i, b.load_total = sc, 1, 0
    return
  end
  b.drop_q = #drop > 0 and drop or nil
  b.drop_i = #drop > 0 and 1 or nil
  local bc_drop, bt_drop, rt_drop, ac_drop = {}, {}, {}, {}
  if b.bc then
    for key in pairs(b.bc) do
      if outside(key) then
        bc_drop[#bc_drop + 1] = key
      end
    end
    table.sort(bc_drop)
  end
  if b.bt then
    local gone, kept = {}, {}
    for key, t in pairs(b.bt) do
      if outside(key) then
        bt_drop[#bt_drop + 1] = key
        for _, u in ipairs(t.a or {}) do
          gone[#gone + 1] = u
        end
      else
        for _, u in ipairs(t.a or {}) do
          kept[u] = true
        end
      end
    end
    table.sort(bt_drop)
    local gseen = {}
    for _, u in ipairs(gone) do
      if not kept[u] and not gseen[u] then
        gseen[u] = true
        ac_drop[#ac_drop + 1] = u
      end
    end
    table.sort(ac_drop)
    if b.retry then
      for u, ent in pairs(b.retry) do
        if outside(ent[2]) then
          rt_drop[#rt_drop + 1] = u
        end
      end
      table.sort(rt_drop)
    end
  end
  if #bc_drop > 0 or #bt_drop > 0 or #rt_drop > 0 or #ac_drop > 0 then
    b.prune = { bc = bc_drop, bci = 1, bt = bt_drop, bti = 1, rt = rt_drop, rti = 1, ac = ac_drop, aci = 1 }
  else
    b.prune = nil
  end
  -- Skip inner rings that are already completely loaded instead of resetting b.load_i = 1.
  local start_i, start_total = 1, 0
  local units, ents, belts, lanes = sc.units, sc.ents, b.belts, b.lanes
  local stop = math.min(sc.r, b.edge or sc.r)
  local n = sc.n
  while start_i <= n do
    local ring = sc.rings[start_i]
    if ring >= stop then
      break
    end
    local unit = units[start_i]
    if not belts[unit] and (not sel or sel[unit]) and ents[start_i].valid then
      break
    end
    if c < math.huge and belts[unit] then
      for i = 1, LANE_KEYS do
        local rec = lanes[unit * LANE_KEYS + i]
        if rec then
          start_total = start_total + rec[1] + 1
        end
      end
    end
    start_i = start_i + 1
  end
  b.scan, b.load_i, b.load_total = sc, start_i, start_total
end

local function take_scan(b, sc, p)
  local inside = sc.idx
  local c = options.cap(M.max_items)
  local tt = profile.start()
  local keep = scan_cap_edge(b, sc, c)
  profile.stop("bsc.cum", tt)
  tt = profile.start()
  local old_sc = b.scan
  -- (scan_incremental: the scan this one replaces, its arrays filled again by the next one's flatten_step.)
  b.spare = O.scan_incremental and old_sc ~= sc and old_sc or nil
  local margin = 0
  if not sc.sel and keep >= sc.r and not b.cut and not (old_sc and sc.r < old_sc.r) then
    margin = math.max(0, floor(tonumber(O.drop_margin) or 0))
  end
  local drop = {}
  local sel = sc.sel
  -- (built_now: a belt loaded on its event after this scan began isn't in it; the scan asked for then finds it.
  -- Those loaded before it began were seen by it: forgotten here.)
  local direct = b.direct
  for unit, rec in pairs(b.belts) do
    local j = inside[unit]
    if not j and direct and (direct[unit] or -1) >= sc.tick then
      M.counts.direct_kept = (M.counts.direct_kept or 0) + 1
    elseif j then
      if sc.rings[j] >= keep or (sel and not sel[unit]) then
        drop[#drop + 1] = unit
      end
    else
      local dx, dy = rec[2] - sc.fx, rec[3] - sc.fy
      local dist = math.max(dx < 0 and -dx or dx, dy < 0 and -dy or dy)
      if margin <= 0 or dist < sc.r or dist >= sc.r + margin then
        drop[#drop + 1] = unit
      end
    end
  end
  if direct then
    local left = false
    for unit, t in pairs(direct) do
      if t < sc.tick then
        direct[unit] = nil
      else
        left = true
      end
    end
    if not left then
      b.direct = nil
    end
  end
  table.sort(drop)
  profile.stop("bsc.drop", tt)
  tt = profile.start()
  -- The chunk caches outside the square (its belts, bs.bc; the belts inserters and drills use, bs.bt)
  -- and the actors those listed are forgotten: they only grew as the focus moved, every actor checked
  -- every update. (A chunk either side too: a neighbour's targets are looked up where it stands.
  -- Found again when the square comes back. Order-free: the same whatever pairs gives.)
  prune_scan_caches(b, sc, margin, drop, p, c)
  profile.stop("bsc.rest", tt)
  b.wver = (b.wver or 0) + 1
  b.wlver = (b.wlver or 0) + 1
  M.counts.scans = M.counts.scans + 1
  return #drop
end

-- The unit numbers of the belts a belt feeds (an underground entrance's exit too).
local function outputs_of(belt)
  local outs = {}
  if belt.type == "underground-belt" and belt.belt_to_ground_type == "input" then
    local ok, other = pcall(function() return belt.underground_belt_neighbour end)
    if ok and other and other.valid and other.unit_number then
      outs[#outs + 1] = other.unit_number
    end
  end
  local ok, nb = pcall(function() return belt.belt_neighbours end)
  if ok and nb then
    for _, e in pairs(nb.outputs or {}) do
      if e.valid and e.unit_number then
        outs[#outs + 1] = e.unit_number
      end
    end
  end
  return outs
end

-- Loads the scan's belt j0 after the unloaded belts of the scan it leads into, and those after the
-- ones they lead into (depth first, within the ring `stop`), so that a lane is loaded after the one
-- it feeds: a lane whose next isn't loaded yet leads out of what is sent, which the client can only
-- hold where it was read, while one whose feeder isn't loaded yet only misses what comes in, which
-- the feeder's load reads again. Up to `limit` units (at least one belt). Returns the units spent
-- and whether j0 was loaded.
local function load_chain(b, sc, j0, stop, limit, p)
  local spent = 0
  local order, seen = {}, { [j0] = true }
  local stack = { { j0 } }
  while #stack > 0 do
    local top = stack[#stack]
    if not top[2] then
      local kids = {}
      top[2], top[3] = kids, 1
      local belt = sc.ents[top[1]]
      if belt.valid then
        spent = spent + H.TARGET_UNITS
        for _, u in ipairs(outputs_of(belt)) do
          local j = sc.idx and sc.idx[u]
          if j and not seen[j] and not b.belts[u] and sc.rings[j] < stop and sc.ents[j].valid and (not sc.sel or sc.sel[u]) then
            seen[j] = true
            kids[#kids + 1] = j
          end
        end
      end
    end
    local kids = top[2]
    if top[3] <= #kids then
      stack[#stack + 1] = { kids[top[3]] }
      top[3] = top[3] + 1
    else
      stack[#stack] = nil
      order[#order + 1] = top[1]
    end
  end
  for x, j in ipairs(order) do
    if x > 1 and spent >= limit then
      return spent, false
    end
    local unit = sc.units[j]
    local belt = sc.ents[j]
    if not b.belts[unit] and belt.valid then
      spent = spent + H.load_belt(b, belt, unit, sc.xs[j], sc.ys[j], p)
    end
  end
  return spent, true
end

-- Loads belts nearest first, up to `limit` units: the next unloaded belts of the scan (each after
-- those it leads into within CHAIN_RINGS rings further out: load_chain). Returns the units spent.
local function load_step(b, limit, p)
  local sc = b.scan
  if not sc then
    return 0
  end
  local spent = 0
  local c = options.cap(M.max_items)
  local stop = math.min(sc.r, b.edge or sc.r)
  local j = b.load_i or 1
  -- (With the cap: items + lanes of the loaded lanes passed so far, ring by ring.)
  local total = b.load_total or 0
  while j <= sc.n and spent < limit do
    local ring = sc.rings[j]
    if ring >= stop then
      break
    end
    local unit = sc.units[j]
    spent = spent + H.SKIP_UNITS
    if not b.belts[unit] and sc.ents[j].valid and (not sc.sel or sc.sel[unit]) then
      -- (The belts it leads into a few rings further out at most: a main line's whole length first
      -- held the near rings back for seconds.)
      local u, done = load_chain(b, sc, j, O.full_area and math.min(stop, ring + H.CHAIN_RINGS) or stop, limit - spent, p)
      spent = spent + u
      if not done then
        break
      end
    end
    if c < math.huge and b.belts[unit] then
      for i = 1, LANE_KEYS do
        local rec = b.lanes[unit * LANE_KEYS + i]
        if rec then
          total = total + rec[1] + 1
        end
      end
    end
    j = j + 1
    if total > c and (j > sc.n or sc.rings[j] ~= ring) then
      b.edge = ring + 1
      break
    end
  end
  b.load_i, b.load_total = j, total
  return spent
end

-- The first ring with a belt not loaded yet (or the radius): every lane inside it is loaded.
local function loaded_edge(b)
  local sc = b.scan
  if not sc then
    return 0
  end
  local fr = math.min(sc.r, b.edge or sc.r)
  local sel = sc.sel
  for j = b.load_i or 1, sc.n do
    local ring = sc.rings[j]
    if ring >= fr then
      break
    end
    local unit = sc.units[j]
    if not b.belts[unit] and (not sel or sel[unit]) then
      return ring
    end
  end
  -- (Belts before load_i that were dropped or reloaded are loaded again or gone; a belt before it
  -- not loaded is one that wasn't valid.)
  return fr
end

---------------------------------------------------------------------------------------------
-- An update.
--
-- bs.round = {start, steps: the steady work's queue (reloads, `bre` lanes, watched belts, drift
-- checks), i, units, scan (one being made)}.

-- (quiet_pc) Whether a belt's drift check is due on this turn: none made since its touch, or the next turn would
-- come past its wait (rec.qw ticks from its last). The turn's tick kept (rec.qt) for the gap between turns.
local function far_loads(b)
  local sc = b.scan
  local j = b.load_i or 1
  if not sc or j > sc.n then
    return false
  end
  return sc.rings[j] >= (tonumber(O.walk_near) or 0)
end

-- The units first loads may take this tick: their share of the work budget, more while the view's reach
-- isn't all loaded (walk_load, b.thin from the last update), LOAD_MIN for belts past walk_near while the
-- tick's budget isn't idle (far_load_cap), once the square has been loaded whole (b.whole: the join's first
-- load goes at its full share).
local function load_limit_now(b)
  if M.load_cap then
    return M.load_cap
  end
  if not O.load_budget then
    local limit = math.max(H.LOAD_MIN, floor(budget.left("bsload", H.LOAD_SHARE) * UNITS_PER_BUDGET_UNIT))
    if b.thin then
      return math.max(limit, floor(tonumber(O.walk_load) or 0))
    end
    if O.far_load_cap and b.whole and far_loads(b) and budget.left() < budget.limit() * H.IDLE_SHARE then
      return H.LOAD_MIN
    end
    return limit
  end
  local head = math.max(0, floor(budget.left() * UNITS_PER_BUDGET_UNIT))
  local share = math.max(0, floor(budget.left("bsload", H.LOAD_SHARE) * UNITS_PER_BUDGET_UNIT))
  local floor_u = math.min(H.LOAD_MIN, math.max(H.LOAD_FLOOR, head))
  local limit = math.max(floor_u, share)
  if b.thin then
    local walk = floor(tonumber(O.walk_load) or 0)
    local walk_cap = walk > 0 and math.min(walk, math.max(H.LOAD_FLOOR, head)) or 0
    return math.max(limit, walk_cap)
  end
  if O.far_load_cap and b.whole and far_loads(b) and budget.left() < budget.limit() * H.IDLE_SHARE then
    return math.min(H.LOAD_MIN, head)
  end
  return limit
end

-- (Tests.)

function mod.init(m, h)
  M, H = m, h
  H.DROP_MIN, H.DROP_MAX, H.PRUNE, H.EDGE_MIN, H.EDGE_MAX, H.LOAD_FLOOR = 32, 128, 64, 200, 1200, 200
  H.flatten_step = flatten_step
  H.prune_step = prune_step
  H.SCAN_FINDS = 2
  H.CHAIN_RINGS = 4
  H.chunk_belts = chunk_belts
  H.far_loads = far_loads
  H.forget_touched = forget_touched
  H.load_chain = load_chain
  H.load_limit_now = load_limit_now
  H.load_step = load_step
  H.loaded_edge = loaded_edge
  H.neighbours_of = neighbours_of
  H.new_scan = new_scan
  H.outputs_of = outputs_of
  H.scan_step = scan_step
  H.take_scan = take_scan
  H.touched = touched
  H.trace_step = trace_step
end

return mod
