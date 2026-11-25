-- Belt reading, loading, dropping, and event-driven lane reads for belt_sim.lua.
-- Shares `M` and `H` via `init(m, h)`; `pays` and caches are module-local.

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

local function kind_of(belt, i)
  local t = belt.type
  if t == "transport-belt" then
    return belt.belt_shape == "straight" and 1 or 2
  elseif t == "underground-belt" then
    if i <= 2 then
      return 3
    end
    return belt.belt_to_ground_type == "input" and 4 or 8
  elseif t == "splitter" then
    return i <= 4 and 5 or 6
  elseif t == "lane-splitter" then
    -- (One side of a splitter: lines 1-2 its inputs, 3-4 its outputs; the client tells it from a
    -- splitter by an output among lines 1-4.)
    return i <= 2 and 5 or 6
  elseif H.LOADERS[t] then
    return 7
  end
  return 8
end


-- A splitter's priorities and filter: input + 3 * output + 9 * filter item id.
local function splitter_extra(belt)
  local ok, v = pcall(function()
    local inp = H.PRIORITY[belt.splitter_input_priority] or 0
    local out = H.PRIORITY[belt.splitter_output_priority] or 0
    local flt = belt.splitter_filter
    local name = flt and (type(flt.name) == "table" and flt.name.name or flt.name)
    local id = type(name) == "string" and registry.item_id(name) or 0
    return inp + 3 * out + 9 * (id or 0)
  end)
  return ok and v or 0
end

-- The key items on lane i go on into when the game says so for certain: an underground entrance's
-- visible lines 1-2 into its own hidden lines 3-4 (key + 2), its hidden lines into its exit's lines
-- 1-2, the same side (2.1.24, Zenith Test: an entrance's line 1 ends where its line 3 starts, and
-- line 3 ends where the exit's line 1 starts). Else 0 (the client joins lanes by geometry).
local function next_of(belt, unit, i, kind)
  if kind == 3 and belt.belt_to_ground_type == "input" then
    return unit * LANE_KEYS + i + 2
  elseif kind == 4 then
    -- (2.1: underground_belt_neighbour; 2.0: neighbours.)
    local ok, exit = pcall(function() return belt.underground_belt_neighbour end)
    if not ok then
      ok, exit = pcall(function() return belt.neighbours end)
    end
    if ok and exit and exit.valid and exit.unit_number then
      return exit.unit_number * LANE_KEYS + i - 2
    end
  end
  return 0
end

local function fixed(v)
  return floor(v * 256 + 0.5)
end

-- Whether line i of a belt is one its items leave the belt by (not one leading on inside it: an
-- underground entrance's visible lines, a splitter's inputs).
local function exit_line(belt, i)
  local t = belt.type
  if t == "underground-belt" then
    return i > 2 or belt.belt_to_ground_type ~= "input"
  elseif t == "splitter" then
    return i > 4
  elseif t == "lane-splitter" then
    return i > 2
  end
  return true
end

-- Where lane i's items leave a splitter: the unit number of the output (among `list`) standing on the tile just past
-- the line's exit end (its own half's), 0 for none (that half has no belt: they stop at its end).
local function out_ahead(line, list)
  local p0 = line.get_line_item_position(0)
  local pm = line.get_line_item_position(line.line_length / 2)
  local dx, dy = p0.x - pm.x, p0.y - pm.y
  local d = math.sqrt(dx * dx + dy * dy)
  if d <= 0 then
    return 0
  end
  local qx, qy = floor(p0.x + dx / d * 0.25), floor(p0.y + dy / d * 0.25)
  for _, e in ipairs(list) do
    local box = e.bounding_box
    if qx >= floor(box.left_top.x) and qx < ceil(box.right_bottom.x) and qy >= floor(box.left_top.y) and qy < ceil(box.right_bottom.y) then
      return e.unit_number
    end
  end
  return 0
end

-- (lane_next) Where each line items leave a belt by (exit_line) leads: line index -> the unit number of the belt its
-- items go on into, 0 for none (the line ends there). An underground entrance's hidden lines into its exit
-- (`partner`), a splitter's outputs each into its half's belt (out_ahead), any other belt's into its one output
-- (belt_neighbours' `outputs`). Worked out with the belt's record (load_belt), so a belt changed is read again.
local function lane_outs(belt, t, outputs, partner, lines)
  local per = {}
  local n = #lines
  if t == "underground-belt" and belt.belt_to_ground_type == "input" then
    for i = 3, n do
      per[i] = partner or 0
    end
    return per
  end
  local list = {}
  for _, e in pairs(outputs or {}) do
    if e.valid and e.unit_number then
      list[#list + 1] = e
    end
  end
  local one = nil
  if #list == 0 then
    one = 0
  elseif #list == 1 and t ~= "splitter" then
    one = list[1].unit_number
  end
  for i = 1, n do
    if exit_line(belt, i) then
      per[i] = one or out_ahead(lines[i], list)
    end
  end
  return per
end

-- Whether lane i of a loaded belt (its record `rec`) leads out of what is sent: the belt its own items go on into
-- isn't loaded (lane_next); off, as before: the belt feeds one that isn't (bs.oset) and items leave it by the line.
local function lane_out(b, rec, unit, i, belt)
  local per = O.lane_next and rec and rec[15]
  if per then
    local u = per[i]
    return u ~= nil and u ~= 0 and b.belts[u] == nil
  end
  return (b.oset[unit] and exit_line(belt, i)) and true or false
end

-- The lane's meta, 12 integers into `out`. `edge`: the lane leads out of what is sent (lane_out): its next is
-- negative.
-- A lane's meta but its last number, as text, by lane key: the line's geometry doesn't change while
-- the belt stands (rotated or replaced, the belt is loaded again: load_belt forgets its lanes' metas).
-- m[12]: the lane it goes on into (next_of), a number; m[13]: whether items leave the belt by it.
-- Module-local, like line_cache (a `bre` lane sent again cost seven calls for its meta).
local meta_cache = {}

local function write_meta(out, belt, unit, i, line, step, edge)
  local key = unit * LANE_KEYS + i
  local m = meta_cache[key]
  local kind
  if m then
    kind = m[0]
  else
    kind = kind_of(belt, i)
    local len = line.line_length
    local p0 = line.get_line_item_position(0)
    local pm = line.get_line_item_position(len / 2)
    local p1 = line.get_line_item_position(len)
    m = { S(key), S(kind), S(fixed(len)), S(step), S(fixed(p0.x)), S(fixed(p0.y)), S(fixed(pm.x)), S(fixed(pm.y)),
      S(fixed(p1.x)), S(fixed(p1.y)), S(0), next_of(belt, unit, i, kind), exit_line(belt, i) }
    m[0] = kind
    meta_cache[key] = m
  end
  local n = #out
  for j = 1, 10 do
    out[n + j] = m[j]
  end
  -- (A splitter's priorities and filter are read each time: set from its GUI, no event.)
  out[n + 11] = S((kind == 5 or kind == 6) and splitter_extra(belt) or 0)
  local nk = m[12]
  if edge and m[13] then
    -- (Leading out of what is sent: minus the lane it goes on into when the game says, else -1.)
    nk = nk > 0 and -nk or -1
  end
  out[n + 12] = S(nk)
end

-- Line objects by unit number: module-local (getting one costs about as much as a check); the
-- units are counted whether it was kept or not, so every peer counts the same.
local line_cache = {}

local function lines_of(belt, unit)
  local lines = line_cache[unit]
  if not lines then
    local t = belt.type
    -- (input: how many of its lines are a splitter's inputs.)
    -- (len: each line's length, read once (catch_up_fn asked for it at every read).)
    lines = { v = floor(belt.prototype.belt_speed * 256 + 0.5), input = t == "splitter" and 4 or t == "lane-splitter" and 2 or 0, len = {} }
    for i = 1, belt.get_max_transport_line_index() do
      lines[i] = belt.get_transport_line(i)
    end
    line_cache[unit] = lines
  end
  return lines
end

-- Line i's length (tiles), from the cache.
local function line_len(lines, i)
  local len = lines.len[i]
  if not len then
    len = lines[i].line_length
    lines.len[i] = len
  end
  return len
end

-- (watch_lean) Line i's methods, each read off the line once: { get_item_count, get_item_position,
-- get_detailed_contents, get_contents }. Reading a method off a game object makes a new function each time
-- (88 bytes, live: 2.1.24), three or four a lane check, the garbage that made the collector's long pauses;
-- the function read once calls the same line. With the line, in line_cache (module-local: nothing sent or
-- stored depends on it). Off: nil, every call reads the method again, as before.
local function fns(lines, i)
  if not O.watch_lean then
    return nil
  end
  local m = lines.m
  if not m then
    m = {}
    lines.m = m
  end
  local f = m[i]
  if not f then
    local line = lines[i]
    -- ([4], get_contents: read by one_kind once it knows the line has it.)
    f = { line.get_item_count, line.get_item_position, line.get_detailed_contents }
    m[i] = f
  end
  return f
end

-- {count, front, back, items} of a line, as the cheap check reads it. f: its methods (fns), or nil.
local function check_line(line, f)
  local n = #line
  if n == 0 then
    return 0, -1, -1, 0
  end
  if f then
    local gip = f[2]
    local p1 = gip(1)
    local pn = n > 1 and gip(n) or p1
    return n, fixed(p1), fixed(pn), f[1]()
  end
  local p1 = line.get_item_position(1)
  local pn = n > 1 and line.get_item_position(n) or p1
  return n, fixed(p1), fixed(pn), line.get_item_count()
end

-- two_call (bridge.md change 12, on by default): a watched lane's check first reads its item count and its
-- front item's place; when both are as its record has them it counts as unchanged, its stacks and back item
-- taken from the record (two calls instead of four). The four-call check when either differs, and every
-- two_call_full'th check anyway (default 16; 4 before; rec[15] counts them). What it adds to the cheap check's
-- blind spots: the stack count or the back item changing with the count and the front both the same.
local function two_call_line(line, rec, f)
  local c = (rec[15] or 0) + 1
  rec[15] = c
  local full_every = math.max(1, floor(tonumber(O.two_call_full) or H.TWO_CALL_FULL))
  if c % full_every == 0 or not rec[1] then
    return check_line(line, f)
  end
  local gip = f and f[2] or line.get_item_position
  local total = f and f[1]() or line.get_item_count()
  if total == 0 then
    return 0, -1, -1, 0
  end
  local p1 = fixed(gip(1))
  if total == rec[4] and p1 == rec[2] and rec[1] > 0 then
    M.counts.two_call = (M.counts.two_call or 0) + 1
    return rec[1], p1, rec[3], total
  end
  local n = #line
  local pn = n > 1 and fixed(gip(n)) or p1
  return n, p1, pn, total
end


-- The item id of a lane's items when they are all one kind of item of normal quality (its totals:
-- one call), else nil. (Not where a line has no totals: tests' fake worlds.)
local has_totals = nil
local function one_kind(line, f)
  if has_totals == nil then
    has_totals = pcall(function() return line.get_contents end) or false
  end
  if not has_totals then
    return nil
  end
  local gc = f and f[4]
  if f and not gc then
    gc = line.get_contents
    f[4] = gc
  end
  local c = gc and gc() or line.get_contents()
  local k = c[1]
  if k and not c[2] and (k.quality == nil or k.quality == "normal") then
    return registry.item_id(k.name)
  end
  return nil
end

-- What is sent this update (module-local; see the header), by client state: storage.f3d is swapped
-- per client (session.serve) and two clients' rounds start on the same ticks, so one keyed by the
-- tick alone sent the first client both clients' lanes and the second nothing. lm and sl lanes by
-- key once each.
local function payload(b)
  local round = b.round
  local pay = H.pays[storage.f3d]
  if pay and round and pay.id == round.start then
    return pay
  end
  return nil
end

local function new_payload(id)
  -- (sent: lane key -> the tick its sl went; msent, lane_next: the tick its lm went.)
  return { id = id, lm = {}, sl = {}, qu = {}, pc = {}, dl = {}, of = {}, ew = {}, sh = {}, sx = {}, sent = {}, msent = {} }
end

-- Why lanes are read in full (step 1 of belts-quiet-reads): a group of reads sets read_cause round them, or
-- read_lane is given one; each read counted as M.counts.rw_<cause> (a watched belt's lane) or ru_<cause> (the rest).
-- Module-local: counting only. load: a belt's first load; reload: loaded again; next: its next told again (lane_next);
-- exits: a lane leading out; catch: round a belt built; run: a packed run round an asked lane; tail: the belts after
-- a changed watched belt or a hand's take or put; settle: round one that settled; settled: a watched lane read once it
-- stood; watched: a watched lane that changed; asked: `bre`; ins: a hand's take or put (ins_driven); edge: the edge
-- checks.
local read_cause = "other"
local function set_cause(c)
  local c0 = read_cause
  read_cause = c
  return c0
end

-- (quiet_pc) A belt touched: its drift checks every turn again. rec.qw: the ticks its next drift check may wait
-- (nil: every turn); rec.ql: the tick of its last drift check (nil since the touch); rec.qt: its last turn's tick.
local function wake(rec)
  if rec and (rec.qw or rec.ql) then
    rec.qw, rec.ql = nil, nil
    M.counts.woken = (M.counts.woken or 0) + 1
  end
end

-- The belts a belt feeds, `depth` on (a watched belt's tails' reach): woken.
local function wake_after(b, unit, depth)
  local rec = b.belts[unit]
  if not rec or depth <= 0 then
    return
  end
  for _, u in ipairs(rec[7] or {}) do
    local r = b.belts[u]
    if r and not b.wset[u] then
      wake(r)
    end
    wake_after(b, u, depth - 1)
  end
end

-- (quiet_pc, drop_put) A belt an item was put on that no event of the belt simulation's sees (Z, from Zenith or a
-- player in the game window: ui_actions.lua): its drift checks every turn again at once, not after the wait it had
-- grown (up to quiet_pc_max ticks). From a command or an event: storage only.
local function wake_unit(unit)
  local b = storage.f3d and storage.f3d.bs
  if b and b.belts and unit then
    wake(b.belts[unit])
  end
end


-- (quiet_pc) A splitter set again (its filter, its priorities): the belts after it woken, as a watched belt's tails.
-- (Its lanes change at once in the game; a put or take's tails reach as far.)
tracker.configure_listeners[#tracker.configure_listeners + 1] = function(entity)
  local s = storage.f3d
  local b = s and s.bs
  local u = entity.unit_number
  if b and b.belts and u and b.belts[u] and (entity.type == "splitter" or entity.type == "lane-splitter") then
    wake_after(b, u, 2)
  end
end

-- Reads lane i of a belt in full (and its meta with `meta`): its record in storage, what is sent
-- into `p`. Returns the units it cost.
local function read_lane(b, belt, unit, i, lines, meta, p, n, p1, pn, total, why)
  local line = lines[i]
  local f = H.fns(lines, i)
  local key = unit * LANE_KEYS + i
  local now = game.tick
  if not n then
    n, p1, pn, total = check_line(line, f)
  end
  local rec = b.lanes[key]
  if not rec then
    rec = {}
    b.lanes[key] = rec
  end
  -- rec: {count, front, back, items, tick read in full, tick checked, checks unchanged in a row}
  -- rec: ..., [8] changed since it was last sent settled (watch_lane), [9] its length (1/256), [10]
  -- and [11] the front and back items' unique ids
  rec[1], rec[2], rec[3], rec[4], rec[5], rec[6], rec[7] = n, p1, pn, total, now, now, 0
  -- rec[14]: the client's last read of it is the lane as it is (hold_inputs).
  rec[14] = true
  local br = b.belts[unit]
  if br then
    br[13] = nil
    -- (quiet_pc: read in full, touched.)
    wake(br)
  end
  local ck = (b.wset[unit] and "rw_" or "ru_") .. (why or read_cause)
  M.counts[ck] = (M.counts[ck] or 0) + 1
  if not rec[9] then
    rec[9] = fixed(line_len(lines, i))
  end
  M.counts.read = M.counts.read + 1
  local units = H.CHECK_UNITS + n * H.ITEM_UNITS
  if meta then
    units = units + H.META_UNITS
    M.counts.meta = M.counts.meta + 1
  end
  -- rec[16]: whether the client was told the lane leads out (its last lm's next negative; nil before one went). Set
  -- with every read with meta, payload or not (storage the same on every peer; one without the payload sends less).
  -- (lane_next: a lane read again in the tick sends its meta too when none went this tick or its next changed: a
  -- catch-up's or a feeder's read before a reload held the reload's lm back, the belt turned or its next changed
  -- kept its old meta in Zenith. Off: the meta only with the tick's first read, as before.)
  if meta then
    local edge = lane_out(b, br, unit, i, belt)
    local changed = rec[16] ~= edge
    rec[16] = edge
    if p and (p.sent[key] ~= now or (O.lane_next and (p.msent[key] ~= now or changed))) then
      p.msent[key] = now
      write_meta(p.lm, belt, unit, i, line, lines.v, edge)
    end
  end
  -- (A lane is sent once a tick: read again on a later tick of the same update, it goes again, the
  -- client applying each at its own tick.)
  if p and p.sent[key] ~= now then
    p.sent[key] = now
    local sl = p.sl
    local m = #sl
    local at = m + 3
    -- (The count stays a number: emit walks the list by it.)
    sl[m + 1], sl[m + 2], sl[m + 3] = S(key), S(now), n
    m = at
    local qu = p.qu
    local contents = (f and f[3]() or line.get_detailed_contents())
    rec[10] = contents[1] and contents[1].unique_id or nil
    rec[11] = contents[#contents] and contents[#contents].unique_id or nil
    -- One kind of item, normal, none stacked (most lanes): its id from the lane's totals, nothing
    -- read item by item but its id and place.
    -- (A lane of one item too, perfbridge2: its totals are one call where its stack's name, count
    -- and quality were four.)
    -- rec[17]: the lane's one kind of item at its last read in full, stacked or not (false: more, or none known);
    -- the item-by-item fast path below only for one kind none stacked.
    local kind = n >= 1 and one_kind(line, f) or false
    rec[17] = kind
    local one = total == n and kind
    if one then
      one = S(one)
      local single = S(1)
      for _, item in pairs(contents) do
        sl[m + 1], sl[m + 2], sl[m + 3], sl[m + 4] = S(item.unique_id), one, S(fixed(item.position)), single
        m = m + 4
      end
    else
      for _, item in pairs(contents) do
        local st = item.stack
        local c = st.count
        sl[m + 1], sl[m + 2], sl[m + 3], sl[m + 4] = S(item.unique_id), S(registry.item_id(st.name)), S(fixed(item.position)), S(c > 4 and 4 or c)
        m = m + 4
        local q = st.quality.name
        if q ~= "normal" then
          qu[#qu + 1] = S(item.unique_id)
          qu[#qu + 1] = q
        end
      end
    end
    -- (The count is what was listed: the same as the check's on one tick, but the list is what the
    -- client gets.)
    sl[at] = (m - at) / 4
    M.counts.items = M.counts.items + n
  elseif n > 0 then
    local contents = (f and f[3]() or line.get_detailed_contents())
    rec[10] = contents[1] and contents[1].unique_id or nil
    rec[11] = contents[#contents] and contents[#contents].unique_id or nil
  else
    rec[10], rec[11] = nil, nil
  end
  return units
end

-- Works out a belt's record: whether it is watched (see the header), whether it has a circuit
-- connection. Returns the record, the units it cost, and for lane_outs the belts it outputs into
-- (belt_neighbours' `outputs`) and an underground entrance's exit's unit number.
local function belt_record(b, belt, unit, x, y)
  local surface = world.surface()
  local t = belt.type
  local rec = { belt, x, y }
  rec[14] = t
  local units = H.WATCH_UNITS
  local watched = not (t == "transport-belt" or t == "underground-belt")
  -- (rec[16], ins_driven: watched for inserters alone. other: watched for anything else.)
  local ins, other = false, watched
  local here, u1 = H.targets_of(b, surface, x, y)
  units = units + u1
  -- rec[11]: inserters or drills use it (1 drop, 2 pickup, 3 the belt behind a pickup belt).
  if here[unit] then
    watched = true
    rec[11] = here[unit]
    rec[12] = true
    -- (A drill's drop belt, or one in a chunk read before drills were told apart: watched, drills send nothing.)
    if here.dv and not (here.d and here.d[unit]) then
      ins = true
    else
      other = true
    end
  end
  -- rec[7], rec[8]: the unit numbers of the belts it feeds and that feed it (an underground's other
  -- end too).
  local outs, ins = {}, {}
  rec[7], rec[8] = outs, ins
  local partner = nil
  if t == "underground-belt" then
    local uok, other = pcall(function() return belt.underground_belt_neighbour end)
    if uok and other and other.valid and other.unit_number then
      local list = belt.belt_to_ground_type == "input" and outs or ins
      list[#list + 1] = other.unit_number
      partner = other.unit_number
    end
  end
  local ok, nb = pcall(function() return belt.belt_neighbours end)
  if ok and nb then
    for _, e in pairs(nb.inputs or {}) do
      if e.valid then
        if e.unit_number then
          ins[#ins + 1] = e.unit_number
        end
        if H.LOADERS[e.type] then
          watched = true
          other = true
          rec[12] = true
        end
      end
    end
    for _, e in pairs(nb.outputs or {}) do
      if e.valid then
        if e.unit_number then
          outs[#outs + 1] = e.unit_number
        end
        if H.LOADERS[e.type] then
          watched = true
          other = true
          rec[12] = true
        elseif e.unit_number then
          local q = e.position
          local there, u2 = H.targets_of(b, surface, q.x, q.y)
          units = units + u2
          if there[e.unit_number] == 2 then
            watched = true  -- the belt behind a pickup belt: hands chase items there
            ins = true
            rec[11] = rec[11] or 3
            rec[12] = true
          end
        end
      end
    end
  end
  local cok, behavior = pcall(function() return belt.get_control_behavior() end)
  if cok and behavior then
    watched = true
    other = true
    rec[5] = true
    rec[12] = true
  end
  if H.LOADERS[t] then
    rec[12] = true
  end
  rec[4] = watched
  rec[16] = ins and not other or nil
  return rec, units, ok and nb and nb.outputs or nil, partner
end

local OFF = nil
local function off_status()
  if OFF == nil then
    local ok, v = pcall(function() return defines.entity_status.disabled_by_control_behavior end)
    OFF = ok and v or false
  end
  return OFF
end

-- Whether a circuit-connected belt is switched off.
local function is_off(belt)
  local off = off_status()
  if not off then
    return false
  end
  local ok, st = pcall(function() return belt.status end)
  return ok and st == off
end

-- Whether a belt feeds one that isn't loaded (its items leave what is sent: `lm` next -1). (lane_next: whether
-- any of its lanes does, lane_outs'.)
local function leads_out(b, rec)
  local per = O.lane_next and rec[15]
  if per then
    for _, u in pairs(per) do
      if u ~= 0 and not b.belts[u] then
        return true
      end
    end
    return false
  end
  for _, u in ipairs(rec[7]) do
    if not b.belts[u] then
      return true
    end
  end
  return false
end

-- Whether a belt is fed by one that isn't loaded (what comes in from it is news to the client:
-- watched, as the square's outer ring is).
local function leads_in(b, rec)
  for _, u in ipairs(rec[8]) do
    if not b.belts[u] then
      return true
    end
  end
  return false
end

-- Reads a belt's exit lines in full again (no meta). Returns the units.
local function read_exits(b, belt, unit, p)
  local lines = lines_of(belt, unit)
  local units = 0
  for i = 1, #lines do
    if exit_line(belt, i) and b.lanes[unit * LANE_KEYS + i] then
      units = units + read_lane(b, belt, unit, i, lines, false, p, nil, nil, nil, nil, "exits")
    end
  end
  return units
end

-- (lane_next) A loaded belt's lanes whose next leads out otherwise than the client was told (rec[16]; nil: no lm
-- went yet): read again now, with their meta (lm and sl: a lane that leads out now needs its wall, the front the
-- client holds its line at). Payload or not, as storage goes (a peer without one sends nothing of it). `count`: the
-- M.counts field the reads go in (next_sent where a belt came or went, next_fix where a look found it otherwise).
-- Returns the units.
local function next_check(b, unit, p, count)
  local rec = b.belts[unit]
  local per = rec and rec[15]
  if not (O.lane_next and per and rec[1].valid) then
    return 0
  end
  local belt = rec[1]
  local units = 0
  local lines = nil
  -- (A belt a drop listed this tick is a change known: a look coming to it first sends it as next_refresh would.)
  if b.nref[unit] then
    b.nref[unit] = nil
    count = "next_sent"
  end
  -- (Only the lines items leave it by (lane_outs lists them): no other lane's next leads out.)
  for i = 1, LANE_KEYS do
    local u = per[i]
    if u ~= nil then
      local lr = b.lanes[unit * LANE_KEYS + i]
      if lr and lr[16] ~= (u ~= 0 and b.belts[u] == nil) then
        lines = lines or lines_of(belt, unit)
        if lines[i] then
          units = units + read_lane(b, belt, unit, i, lines, true, p, nil, nil, nil, nil, "next")
          M.counts[count] = (M.counts[count] or 0) + 1
        end
      end
    end
  end
  return units
end

-- (lane_next) The belts whose lanes' next may have changed this tick (a belt they feed left: drop_belt), looked at
-- before the tick ends, in the update that says it left. Returns the units.
local function next_refresh(b, p)
  if not next(b.nref) then
    return 0
  end
  local list = {}
  for u in pairs(b.nref) do
    list[#list + 1] = u
  end
  table.sort(list)
  b.nref = {}
  local units = 0
  for _, u in ipairs(list) do
    units = units + next_check(b, u, p, "next_sent")
  end
  return units
end

-- Reads a loaded belt's lanes in full again (those not read this tick), and those of the belts it
-- leads into while what came in at its back up to `dt` ticks ago can have got that far (at most
-- CATCH_DEPTH belts on). Returns the units.
-- A changed watched belt's tail: at most this many belts on (the client's carrying on from an item's
-- last read is a few ticks; a long tail through splitters cost more than it fixed).
local function catch_up_fn(b, unit, dt, p, depth)
  local rec = b.belts[unit]
  if not (rec and rec[1].valid) or depth > H.CATCH_DEPTH then
    return 0
  end
  local belt = rec[1]
  local lines = lines_of(belt, unit)
  local now = game.tick
  local units, cross = 0, math.huge
  for i = 1, #lines do
    local lr = b.lanes[unit * LANE_KEYS + i]
    if lr and lr[5] ~= now then
      units = units + read_lane(b, belt, unit, i, lines, false, p)
    end
    if lines.v > 0 then
      cross = math.min(cross, floor(line_len(lines, i) * 256 / lines.v))
    end
  end
  if dt > cross then
    for _, u in ipairs(rec[7] or {}) do
      units = units + catch_up_fn(b, u, dt - cross, p, depth + 1)
    end
  end
  return units
end

-- Loads a belt (all its lanes, meta and items) or loads it again. Returns the units.
local function load_belt(b, belt, unit, x, y, p)
  local old = b.belts[unit]
  local rec, units, outputs, partner = belt_record(b, belt, unit, x, y)
  if old then
    rec[6] = old[6]
  end
  b.belts[unit] = rec
  b.wver = (b.wver or 0) + 1
  local was_w, was_i = b.wset[unit], b.iset[unit]
  b.wset[unit] = rec[4] or nil
  b.cset[unit] = rec[5] or nil
  b.iset[unit] = leads_in(b, rec) or nil
  -- (watch_nosort: the watched list is made again only when what it holds or its order's keys changed.)
  if was_w ~= b.wset[unit] or (rec[4] and (old and old[12] or false) ~= (rec[12] or false))
      or (not O.feed_edges and was_i ~= b.iset[unit])
      or (O.ins_driven and rec[4] and (old and old[16] or false) ~= (rec[16] or false)) then
    b.wlver = (b.wlver or 0) + 1
  end
  -- (built_now: the tile it stands on, b.at, so a belt built over it finds it once its entity is gone.)
  b.at = b.at or {}
  b.at[H.tile_key(x, y)] = unit
  -- (Loaded again after an event: the belt may have turned; its lines' geometry is read again. built_now: their
  -- lengths too, kept with the line objects and the lane records: a belt turned into a curve, or a curve
  -- straightened by a belt built behind it, kept its old lengths for the catch-up's reach and packed checks.)
  if old and O.built_now then
    line_cache[unit] = nil
    for i = 1, LANE_KEYS do
      local lr = b.lanes[unit * LANE_KEYS + i]
      if lr then
        lr[9] = nil
      end
    end
  end
  local lines = lines_of(belt, unit)
  -- rec[15]: where each of its exit lanes goes on into (lane_outs), for each lane's next (lane_out).
  rec[15] = lane_outs(belt, rec[14], outputs, partner, lines)
  b.oset[unit] = leads_out(b, rec) or nil
  if old then
    for i = 1, LANE_KEYS do
      meta_cache[unit * LANE_KEYS + i] = nil
    end
  end
  for i = 1, #lines do
    units = units + read_lane(b, belt, unit, i, lines, true, p, nil, nil, nil, nil, old and "reload" or "load")
  end
  -- Loaded belts that led into this one led out of what was sent: the client held their fronts
  -- where they were last read. Read again now (where the game has them as this one comes), and from
  -- here on they lead into it.
  if not old then
    -- Loaded belts it leads into missed what came in from it since they were last checked (read in
    -- full, or found unchanged): read again, and on as far as that can have gone.
    local now = game.tick
    for _, u in ipairs(rec[7]) do
      local r = b.belts[u]
      if r and b.iset[u] and not leads_in(b, r) then
        b.iset[u] = nil
        if not O.feed_edges then
          b.wlver = (b.wlver or 0) + 1
        end
      end
      if r then
        local since = now
        for i = 1, LANE_KEYS do
          local lr = b.lanes[u * LANE_KEYS + i]
          if lr and lr[6] < since then
            since = lr[6]
          end
        end
        if since < now then
          local r0, c0 = M.counts.read, set_cause("catch")
          units = units + catch_up_fn(b, u, now - since, p, 0)
          set_cause(c0)
          M.counts.r_catch = (M.counts.r_catch or 0) + M.counts.read - r0
        end
      end
    end
    for _, u in ipairs(rec[8]) do
      local r = b.belts[u]
      if r and O.lane_next then
        -- (lane_next: their lanes into it, read again with their meta, the next now 0 or the key it goes on
        -- into; the rest of a belt still leading out elsewhere keep theirs. Off: every exit lane read again, the
        -- meta not sent, so the client kept its -1.)
        local r0 = M.counts.read
        units = units + next_check(b, u, p, "next_sent")
        M.counts.r_exits = (M.counts.r_exits or 0) + M.counts.read - r0
        if b.oset[u] and not leads_out(b, r) then
          b.oset[u] = nil
        end
      elseif r and b.oset[u] then
        if r[1].valid then
          local r0 = M.counts.read
          units = units + read_exits(b, r[1], u, p)
          M.counts.r_exits = (M.counts.r_exits or 0) + M.counts.read - r0
        end
        if not leads_out(b, r) then
          b.oset[u] = nil
        end
      end
    end
  end
  if rec[5] then
    local off = is_off(belt)
    if off ~= (rec[6] or false) and p then
      p.of[#p.of + 1] = S(unit)
      p.of[#p.of + 1] = S(off and 1 or 0)
    end
    rec[6] = off
  end
  M.counts.loaded = M.counts.loaded + 1
  return units
end

-- Drops a loaded belt: its lanes leave (`dl`).
local function drop_belt(b, unit, p)
  local rec = b.belts[unit]
  if not rec then
    return
  end
  if b.wset[unit] or (not O.feed_edges and b.iset[unit]) then
    b.wlver = (b.wlver or 0) + 1
  end
  b.belts[unit], b.wset[unit], b.cset[unit], b.oset[unit], b.iset[unit] = nil, nil, nil, nil, nil
  if b.wake then
    b.wake[unit] = nil
  end
  if b.at then
    local k = H.tile_key(rec[2], rec[3])
    if b.at[k] == unit then
      b.at[k] = nil
    end
  end
  if b.direct then
    b.direct[unit] = nil
  end
  b.wver = (b.wver or 0) + 1
  -- The loaded belts it fed are fed from outside what is sent now: watched.
  for _, u in ipairs(rec[7] or {}) do
    if b.belts[u] then
      if not O.feed_edges and not b.iset[u] then
        b.wlver = (b.wlver or 0) + 1
      end
      b.iset[u] = true
    end
  end
  -- The loaded belts feeding it lead out of what is sent now: sent again (their `lm` next -1).
  -- (lane_next: their lanes into it, read with their meta before the tick ends (next_refresh), in the update whose
  -- dl says it left; one gone from the game changed what they lead into: their records again (reload). Off: every
  -- one reloaded with the next round, its lanes saying 0 till then.)
  local gone = not rec[1].valid
  for _, u in ipairs(rec[8] or {}) do
    local r = b.belts[u]
    if r and O.lane_next then
      if leads_out(b, r) then
        b.oset[u] = true
      end
      if gone then
        b.reload[#b.reload + 1] = u
      else
        b.nref[u] = true
      end
    elseif r and not b.oset[u] then
      b.oset[u] = true
      b.reload[#b.reload + 1] = u
    end
  end
  line_cache[unit] = nil
  for i = 1, LANE_KEYS do
    local key = unit * LANE_KEYS + i
    meta_cache[key] = nil
    if b.lanes[key] then
      b.lanes[key] = nil
      M.counts.dl = M.counts.dl + 1
      if p then
        p.dl[#p.dl + 1] = S(key)
      end
    end
  end
end

-- The cheap check of a loaded lane against its record: read in full when it changed. Returns the units.
-- A packed lane can move on a whole gap and look the same to the cheap check: its front item
-- leaving, the next taking its place, one more coming in at the back (a packed line leading out of
-- the square moving on a gap at a time), or an inserter taking one from a packed, standing line
-- and the items behind closing up, one more coming in at the back. Its front and back items' ids
-- tell.
local GAP = 64
-- Returns whether they moved, and the front and back ids now.
-- The reads made for accuracy alone (ids of packed lanes, tails, reads round a settled belt) share
-- extra_units an update, so they cost about the same whatever the square's size (lanes leading out
-- are checked whatever this says: their walls).
local function event_lane(b, belt, unit, i, lines, p)
  local rec = b.lanes[unit * LANE_KEYS + i]
  local now = game.tick
  if not rec or rec[5] == now then
    return 0, false
  end
  local f = H.fns(lines, i)
  local n, p1, pn, total = check_line(lines[i], f)
  M.counts.checked = M.counts.checked + 1
  M.counts.ins_checks = (M.counts.ins_checks or 0) + 1
  local units = H.CHECK_UNITS
  local same = n > 0 and n == rec[1] and p1 == rec[2] and pn == rec[3] and total == rec[4]
  if same and M.identity then
    units = units + n * H.ITEM_UNITS
    same = not H.front_moved(lines[i], rec, f)
  end
  if same then
    rec[6] = now
    return units, false
  end
  M.counts.ins_reads = (M.counts.ins_reads or 0) + 1
  return units + read_lane(b, belt, unit, i, lines, false, p, n, p1, pn, total, "ins"), true
end

-- (ins_driven) A belt watched for its inserters alone, after a hand took or put there: its lanes (event_lane), and the
-- belts it feeds, as far as an item can have gone in `dt` ticks (a changed watched belt's tails, do_step), whatever its
-- lanes showed: an item taken as it left the belt, or put and run off it since, is on the next belt in the client's
-- simulation. Returns the units and the extra units (the tails, under extra_units).
local function event_belt(b, u, p, dt)
  local rec = b.belts[u]
  if not rec then
    return 0, 0
  end
  local belt = rec[1]
  if not belt.valid then
    drop_belt(b, u, p)
    return 1, 0
  end
  M.counts.ins_belts = (M.counts.ins_belts or 0) + 1
  local lines = lines_of(belt, u)
  local units = 0
  for i = 1, #lines do
    units = units + event_lane(b, belt, u, i, lines, p)
  end
  rec[9] = game.tick
  local win = floor(tonumber(O.ins_window) or 0)
  if win > 0 then
    b.iwin = b.iwin or {}
    b.iwin[u] = b.count + win
  end
  local extra = 0
  if O.quiet_pc then
    wake_after(b, u, H.TAIL_DEPTH)
  end
  if M.tails and H.extra_left(b) then
    local r0, c0 = M.counts.read, set_cause("tail")
    for _, w in ipairs(rec[7] or {}) do
      extra = extra + catch_up_fn(b, w, math.max(1, dt), p, H.CATCH_DEPTH - H.TAIL_DEPTH + 1)
    end
    set_cause(c0)
    M.counts.r_tail = (M.counts.r_tail or 0) + M.counts.read - r0
    H.extra_spend(b, extra)
  end
  return units, extra
end

-- (ins_ho) Whether the client is told each item this inserter puts on a belt (inserters.lua's PLACED): a client
-- taking `ie` and `ho`, the inserter inside inserters.lua's square (the detail radius round the focus), no remote
-- view (inserters.lua leaves out what no radar sees). From storage and settings: the same on every peer.

function mod.reset()
  meta_cache = {}
  line_cache = {}
  read_cause = "other"
end

function mod.init(m, h)
  M, H = m, h
  H.fns = fns
  M.wake_unit = wake_unit
  H.PRIORITY = { none = 0, left = 1, right = 2 }
  H.TWO_CALL_FULL = 16
  M.two_call_line = two_call_line  -- (tests)
  M.line_fns = function(lines, i) return H.fns(lines, i) end  -- (tests)
  M.READ_CAUSES = { "load", "reload", "next", "exits", "catch", "run", "tail", "settle", "settled", "watched", "asked",
    "ins", "edge", "other" }
  H.CATCH_DEPTH = 8
  H.TAIL_DEPTH = 2
  H.belt_record = belt_record
  H.catch_up = catch_up_fn
  H.catch_up_fn = catch_up_fn
  H.check_line = check_line
  H.drop_belt = drop_belt
  H.event_belt = event_belt
  H.event_lane = event_lane
  H.exit_line = exit_line
  H.fixed = fixed
  H.is_off = is_off
  H.kind_of = kind_of
  H.lane_out = lane_out
  H.lane_outs = lane_outs
  H.leads_in = leads_in
  H.leads_out = leads_out
  H.line_len = line_len
  H.lines_of = lines_of
  H.load_belt = load_belt
  H.new_payload = new_payload
  H.next_check = next_check
  H.next_of = next_of
  H.next_refresh = next_refresh
  H.off_status = off_status
  H.one_kind = one_kind
  H.out_ahead = out_ahead
  H.payload = payload
  H.read_exits = read_exits
  H.read_lane = read_lane
  H.set_cause = set_cause
  H.splitter_extra = splitter_extra
  H.two_call_line = two_call_line
  H.wake = wake
  H.wake_after = wake_after
  H.write_meta = write_meta
end

return mod
