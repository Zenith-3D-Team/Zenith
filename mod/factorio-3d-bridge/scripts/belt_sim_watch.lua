-- Watched lane checks, drift checks, packed-run rereads, and watch ordering for belt_sim.lua.
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
local GAP = 64

local M, H
local mod = {}

local function extra_left(b)
  local r = b.round
  return not r or (r.x or 0) < M.extra_units
end
local function extra_spend(b, units)
  local r = b.round
  if r then
    r.x = (r.x or 0) + units
  end
end

-- Crossing hints' own share (hint_units, in b.round.hx: storage, so the same on every peer). None once the
-- square is cut (bs.cut): hints never take the round back over its bound.
local function hint_left(b)
  if b.cut then
    return false
  end
  local r = b.round
  return not r or (r.hx or 0) < M.hint_units
end
local function hint_spend(b, units)
  local r = b.round
  if r then
    r.hx = (r.hx or 0) + units
  end
end

local function front_moved(line, rec, f)
  M.counts.identity = (M.counts.identity or 0) + 1
  local contents = (f and f[3]() or line.get_detailed_contents())
  local first, last = contents[1], contents[#contents]
  local fu, bu = first and first.unique_id, last and last.unique_id
  return fu ~= rec[10] or bu ~= rec[11], fu, bu
end

-- How long a quiet lane goes unchecked: spot_quiet_ticks at an input spot (its inserters and drills
-- wake it), else quiet_ticks, twice that once it stood for 2 * quiet_after checks and four times at
-- 4 * quiet_after (quiet_backoff: splitters' and loaders' lanes, circuit belts, the outer ring that
-- stand backed up for minutes).
-- checkpoints: whether lane i is one where our copy of the belt rules is known to go a tick from the
-- game's (docs/BELT-SIM-PLAN.md, the fronts round): a splitter's input (an item crossing a tick early),
-- a lane an inserter takes from (its front), an underground entrance an inserter drops on.
local function checkpoint_lane(brec, belt, i, lines)
  if lines.input >= i then
    return true
  end
  local used = brec and brec[11]
  if used == 2 then
    return true
  end
  return used == 1 and belt.type == "underground-belt"
end

-- A splitter's side: its input and output line indices (half 0, half 1). A splitter's lines 1 + side and 3 + side
-- are its inputs, 5 + side and 7 + side its outputs; a lane splitter (one side) has 1, 2 in and 3, 4 out.
local function side_lines(lines, side)
  if lines.input == 2 then
    return 1, 2, 3, 4
  end
  return 1 + side, 3 + side, 5 + side, 7 + side
end

-- The side of a splitter's line i.
local function line_side(lines, i)
  if lines.input == 2 then
    return 0
  end
  return (i - 1) % 2
end

-- (crossings hints) The items a lane of record r holds packed end to end: its length (r[9], 1/256 tile) a gap
-- each, two at least. A real splitter's outputs are 128 long and its inputs 179 (2 items), a belt's lanes 256 (4).
local function packed_n(r)
  return math.max(2, floor((r[9] or 256) / GAP))
end

-- (crossings hints) Whether a splitter side's lanes with items are all packed end to end (packed_n items or more, a
-- gap apart, from its front to its back) with the same one kind of item, stacked or not, as their records last had
-- them: the client draws those alike (BeltLattice) whichever way an item crosses, so no hints go and its outputs go
-- quiet. A lane whose kind isn't known isn't packed.
local function packed_kind(b, unit, i, kind)
  local r = b.lanes[unit * LANE_KEYS + i]
  local n = r and r[1] or 0
  if n == 0 then
    return kind
  end
  local len = r[9] or 256
  if n < packed_n(r) or r[2] > GAP or len - r[3] > GAP + 1 or r[3] - r[2] ~= GAP * (n - 1) or not r[17]
      or (kind and kind ~= r[17]) then
    return false
  end
  return r[17]
end

local function split_packed(b, unit, lines, side)
  local i0, i1, o0, o1 = side_lines(lines, side)
  local kind = packed_kind(b, unit, i0, nil)
  if kind ~= false then
    kind = packed_kind(b, unit, i1, kind)
  end
  if kind ~= false then
    kind = packed_kind(b, unit, o0, kind)
  end
  if kind ~= false then
    kind = packed_kind(b, unit, o1, kind)
  end
  return kind ~= false
end

-- crossings hints, and a client that reads them: one taking JSON (bs.sx) or binary frames of wire version 5 or later
-- (an older binary client gets none, so none are made for it). storage.f3d.client: the same on every peer.
local function hints_active()
  return O.crossings == "hints" and (not transport.binary(1) or transport.binary(5))
end

-- crossings game: whether lane i is a splitter's output (checked every update, never quiet: what crossed
-- shows there). Under hints none is: an output is watched as under sim (two_call catches it moving, quiet_first
-- passes it over standing), a packed side with mixed items checked by its ids too (watch_lane, hint_ids).
local function crossing_lane(b, unit, i, lines)
  if lines.input == 0 or i <= lines.input then
    return false
  end
  return O.crossings == "game"
end

-- (crossings hints) A splitter's output records' count, front, back, totals and front and back ids before its
-- lanes are watched (out[(i - 1) * 6 + 1..6], line i), and whether one changed since. Module-local scratch: only
-- what is sent depends on it.
local sig_before = {}
local function note_sig(r, i)
  local at = (i - 1) * 6
  for f = 1, 6 do
    sig_before[at + f] = r and r[H.SIG_FIELDS[f]] or false
  end
end
local function sig_changed(r, i)
  local at = (i - 1) * 6
  for f = 1, 6 do
    local v = r and r[H.SIG_FIELDS[f]] or false
    if v ~= sig_before[at + f] then
      return true
    end
  end
  return false
end

-- (crossings hints) The item on each of a splitter side's outputs (back first) and at each input's front, by unique
-- id, at this tick: one `sx` record a pair of output items, at least one, [unit, side, tick, out0, out1, in0, in1]
-- (0: none). The inputs are read with get_detailed_contents too (their fronts only used: a splitter's input holds
-- 2-3 items), never sent in full (sl). Returns the units it cost, the inputs' items counted.
local function emit_hints(unit, side, lines, p)
  local i0, i1, o0, o1 = side_lines(lines, side)
  local function dc(i)
    local f = H.fns(lines, i)
    return f and f[3]() or lines[i].get_detailed_contents()
  end
  local c0, c1 = dc(o0), dc(o1)
  local d0, d1 = dc(i0), dc(i1)
  local f0, f1 = d0[1], d1[1]
  local zero = S(0)
  local u0, u1 = f0 and S(f0.unique_id) or zero, f1 and S(f1.unique_id) or zero
  local sx, now, su, ss = p.sx, S(game.tick), S(unit), S(side)
  local n0, n1 = #c0, #c1
  local rows = math.max(1, n0, n1)
  local m = #sx
  for r = 0, rows - 1 do
    local a, z = c0[n0 - r], c1[n1 - r]
    sx[m + 1], sx[m + 2], sx[m + 3] = su, ss, now
    sx[m + 4], sx[m + 5] = a and S(a.unique_id) or zero, z and S(z.unique_id) or zero
    sx[m + 6], sx[m + 7] = u0, u1
    m = m + 7
  end
  M.counts.sx = (M.counts.sx or 0) + rows
  return 4 * H.CHECK_UNITS + (n0 + n1 + #d0 + #d1) * H.ITEM_UNITS
end

local function quiet_for(brec, rec)
  if O.inputs_first and brec and brec[12] and brec[11] then
    return M.spot_quiet_ticks
  end
  local qt = M.quiet_ticks
  if O.quiet_backoff then
    local c = rec[7] or 0
    local qa = M.quiet_after
    if c >= 4 * qa then
      return qt * 4
    elseif c >= 2 * qa then
      return qt * 2
    end
  end
  return qt
end

local function watch_lane(b, belt, unit, i, lines, p)
  local key = unit * LANE_KEYS + i
  local rec = b.lanes[key]
  if not rec then
    return 0
  end
  local now = game.tick
  -- (A lane leading out is never quiet nor left out for having only flowed: the client's wall
  -- moves only when it is sent.)
  -- (lane_next: the lane itself, lane_out's: a splitter's half feeding a loaded belt isn't one.)
  local brec = b.belts[unit]
  local edge = H.lane_out(b, brec, unit, i, belt)
  -- (An inserter's or drill's belt: what they take or put is what the cheap check can miss.)
  local handled = brec and brec[11]
  -- (A lane fed from outside what is sent: what comes in at its back is news to the client. Never
  -- quiet, never left out for having only flowed, a packed one checked by its ids too.)
  local fed = O.feed_edges and b.iset[unit]
  -- (An input spot whose inserter or drill acted since its last check.)
  local woke = O.inputs_first and b.wake[unit]
  -- (A checkpoint: checked every update, a packed one by its ids, as a lane fed from outside is.)
  local cp = O.checkpoints and checkpoint_lane(brec, belt, i, lines)
  if cp then
    M.counts.checkpoints = (M.counts.checkpoints or 0) + 1
  end
  -- (crossings game: a splitter's output, checked every update by its ids: what crossed shows there.)
  if not cp and crossing_lane(b, unit, i, lines) then
    cp = true
    M.counts.crossings = (M.counts.crossings or 0) + 1
  end
  local quiet_ticks = quiet_for(brec, rec)
  -- A quiet lane (unchanged at its last quiet_after checks: most watched lanes are backed up) is
  -- checked again only quiet_ticks after its last check: a change there is sent at most that much
  -- later, with the tick it was read on.
  if not edge and not fed and not woke and not cp and quiet_ticks > 0 and (rec[7] or 0) >= M.quiet_after and now - rec[6] < quiet_ticks then
    M.counts.quiet = M.counts.quiet + 1
    return 0.5
  end
  local n, p1, pn, total
  -- (two_call: not for a lane leading out or fed from outside: their walls and what comes in.)
  local f = H.fns(lines, i)
  if O.two_call and not edge and not fed then
    n, p1, pn, total = H.two_call_line(lines[i], rec, f)
  else
    n, p1, pn, total = H.check_line(lines[i], f)
  end
  M.counts.checked = M.counts.checked + 1
  if brec then
    brec[13] = nil
  end
  local same = n == rec[1] and p1 == rec[2] and pn == rec[3] and total == rec[4]
  local extra = 0
  local shifted, sfu, sbu = false, nil, nil
  -- (At most every identity_ticks a lane, but every update for a lane leading out: its wall.)
  if same and n > 0 and pn - p1 == GAP * (n - 1) and M.identity and (edge or ((fed or woke or cp) and n > 1) or (handled and now - (rec[12] or -1e9) >= M.identity_ticks and extra_left(b))) then
    rec[12] = now
    if edge then
      M.counts.identity_edge = (M.counts.identity_edge or 0) + 1
    end
    extra = n * H.ITEM_UNITS
    if not edge and not fed and not woke and not cp then
      extra_spend(b, extra + H.CHECK_UNITS)
    end
    shifted, sfu, sbu = front_moved(lines[i], rec, f)
    same = not shifted
  elseif same and M.identity and p and lines.input > 0 and i > lines.input and n >= 2 and pn - p1 == GAP * (n - 1)
      and n >= packed_n(rec) and hints_active() and hint_left(b) and not split_packed(b, unit, lines, line_side(lines, i)) then
    -- (crossings hints: a splitter's output packed with mixed items, unchanged by the cheap check, by its ids too:
    -- a packed flow a gap on looks the same. Shifted, its new ids are all that changes in its record, so do_step's
    -- sig_changed sends the side's sx and nothing else (no sl: the client simulates the flow itself). Under
    -- hint_units, their own share: never over the bound. Not edge, fed or woke: those take the
    -- identity branch above.)
    rec[12] = now
    extra = n * H.ITEM_UNITS
    hint_spend(b, extra + H.CHECK_UNITS)
    M.counts.hint_ids = (M.counts.hint_ids or 0) + 1
    shifted, sfu, sbu = front_moved(lines[i], rec, f)
    if shifted then
      M.counts.hint_shifts = (M.counts.hint_shifts or 0) + 1
      rec[10], rec[11] = sfu, sbu
      rec[6], rec[7] = now, 0
      return H.CHECK_UNITS + extra
    end
  end
  -- (hold_inputs: a splitter's input as the client last had it; a packed one only by its ids too, as a
  -- lane flowing a whole gap between checks looks the same.)
  local hold = same and O.hold_inputs and rec[14] and n > 0 and lines.input >= i
  if hold and not shifted and n > 1 and pn - p1 == GAP * (n - 1) and rec[12] ~= now then
    rec[12] = now
    extra = extra + n * H.ITEM_UNITS
    shifted, sfu, sbu = front_moved(lines[i], rec, f)
    same = not shifted
    hold = same
  end
  if same then
    local c = (rec[7] or 0) + 1
    rec[6], rec[7] = now, c
    -- Settled (unchanged at quiet_after checks running) after changing: read and sent once more. The
    -- client simulated it on from the reads made while it changed, each on a tick of its own, while
    -- the lanes round it were read on others; once it stands its last state goes, which nothing else
    -- would send (it no longer changes). With settled_flow_only (default on), skip that re-read when
    -- rec[14] says the lane's resting state was already sent by `sl`, still sending it after skip_flow
    -- (where rec[14] was cleared).
    if c == M.quiet_after and rec[8] and not (O.settled_flow_only and rec[14]) then
      M.counts.settled = (M.counts.settled or 0) + 1
      local u = H.read_lane(b, belt, unit, i, lines, false, p, n, p1, pn, total, read_cause == "edge" and "edge" or "settled")
      rec[7], rec[8] = c, nil
      return H.CHECK_UNITS + extra + u, 2
    end
    if hold and p and p.sent[key] ~= now then
      M.counts.held = (M.counts.held or 0) + 1
      local sh = p.sh
      local m = #sh
      sh[m + 1], sh[m + 2] = S(key), S(now)
    end
    return H.CHECK_UNITS + extra
  end
  -- Every item moved on the same way and nothing came or went: what the client simulates itself,
  -- not sent (in 2.1 a lane's items move on as one; an inserter's take or put changes the count or
  -- breaks the even shift).
  if M.skip_flow and not edge and not fed and n == rec[1] and total == rec[4] and p1 - rec[2] == pn - rec[3] and p1 < rec[2] then
    M.counts.flow = M.counts.flow + 1
    rec[2], rec[3], rec[6], rec[7], rec[8], rec[14] = p1, pn, now, 0, true, nil
    return H.CHECK_UNITS
  end
  -- A lane leading out whose items only moved on alike (or, packed, a whole gap on: its front item
  -- left, one more came in at the back): its new wall is all the client needs (`ew`), the line behind
  -- following it there; a full read only when items came or went otherwise.
  if edge and M.edge_walls and ((n == rec[1] and total == rec[4] and p1 - rec[2] == pn - rec[3] and p1 < rec[2] and rec[10])
      or (shifted and sfu)) then
    M.counts.walls = (M.counts.walls or 0) + 1
    if shifted then
      rec[10], rec[11] = sfu, sbu
    end
    rec[1], rec[2], rec[3], rec[4], rec[6], rec[7], rec[8], rec[14] = n, p1, pn, total, now, 0, true, nil
    if p and p.sent[key] ~= now then
      p.sent[key] = now
      local ew = p.ew
      local m = #ew
      ew[m + 1], ew[m + 2], ew[m + 3], ew[m + 4] = S(key), S(now), S(rec[10]), S(p1)
    end
    return H.CHECK_UNITS + extra
  end
  M.counts.changed = M.counts.changed + 1
  -- (1: items came or went, 3: they only moved otherwise.)
  local came = n ~= rec[1] or total ~= rec[4]
  local u = H.read_lane(b, belt, unit, i, lines, false, p, n, p1, pn, total, read_cause == "edge" and "edge" or "watched")
  rec[8] = true
  return H.CHECK_UNITS + extra + u, came and 1 or 3
end

-- Whether a belt's lanes hold an item within two gaps of where items come in (a packed line goes on
-- behind it).
local function full_back(b, unit)
  for i = 1, LANE_KEYS do
    local lr = b.lanes[unit * LANE_KEYS + i]
    if lr and lr[1] > 0 and lr[9] and lr[3] >= lr[9] - 128 then
      return true
    end
  end
  return false
end

local catch_up
-- The packed line behind a belt (the belts feeding it as far back as their lanes are full at the
-- back, at most SETTLE_DEPTH), read again. Returns the units.
local function read_run(b, unit, p)
  local rec = b.belts[unit]
  local units = 0
  local seen = { [unit] = true }
  local function up(u, depth)
    local r = b.belts[u]
    if not r or seen[u] or depth > H.SETTLE_DEPTH then
      return
    end
    seen[u] = true
    units = units + H.catch_up(b, u, 0, p, 0)
    if full_back(b, u) then
      for _, w in ipairs(r[8] or {}) do
        up(w, depth + 1)
      end
    end
  end
  if full_back(b, unit) then
    for _, u in ipairs(rec[8] or {}) do
      up(u, 1)
    end
  end
  return units
end

-- A watched belt settled: the belts it feeds, and the packed line behind it, read once more: what
-- the client's simulation did with the items moving across their ends while they changed (a
-- splitter's turns, a take near the front) shows there, and a packed line standing behind a belt is
-- moved by nothing else. Returns the units.
local function settle_around(b, unit, p)
  local rec = b.belts[unit]
  local units = 0
  local c0 = H.set_cause("settle")
  for _, u in ipairs(rec[7] or {}) do
    units = units + H.catch_up(b, u, 0, p, 0)
  end
  units = units + read_run(b, unit, p)
  H.set_cause(c0)
  return units
end

-- A packed run goes on across a belt's front (a lane's front item within a gap of its exit, its
-- items a gap apart) or its back (its back item within a gap of its entry), by its lanes' records.
-- (RUN_SLACK: the client's PACK_SLACK, how far over a gap packed items may be and still move as one.)
local function packed_at(b, unit, front)
  for i = 1, LANE_KEYS do
    local lr = b.lanes[unit * LANE_KEYS + i]
    if lr and lr[1] > 0 and lr[3] - lr[2] <= (GAP + H.RUN_SLACK) * (lr[1] - 1) then
      if front and lr[2] < GAP + H.RUN_SLACK then
        return true
      elseif not front and lr[9] and lr[3] > lr[9] - GAP - H.RUN_SLACK then
        return true
      end
    end
  end
  return false
end

-- A lane read again: the packed run it belongs to read on the same tick, ahead (the belts it feeds,
-- on while the run goes on across their fronts) and behind (the belts feeding it, on while it goes on
-- across their backs), at most M.run_belts belts each way. The client moves a read's packed run
-- with it; read whole, it replaces the run. Returns the units.
local function read_runs(b, unit, ahead, behind, p)
  if M.run_belts <= 0 then
    return 0
  end
  local units = 0
  local r0, c0 = M.counts.read, H.set_cause("run")
  local function walk(field, front)
    local seen = { [unit] = true }
    local layer = { unit }
    for _ = 1, M.run_belts do
      local nxt = {}
      for _, v in ipairs(layer) do
        local rec = b.belts[v]
        if rec and packed_at(b, v, front) then
          for _, w in ipairs(rec[field] or {}) do
            if not seen[w] and b.belts[w] then
              seen[w] = true
              units = units + H.catch_up(b, w, 0, p, 0)
              nxt[#nxt + 1] = w
            end
          end
        end
      end
      if #nxt == 0 then
        return
      end
      layer = nxt
    end
  end
  if ahead then
    walk(7, true)
  end
  if behind then
    walk(8, false)
  end
  M.counts.r_run = (M.counts.r_run or 0) + M.counts.read - r0
  H.set_cause(c0)
  return units
end

-- A drift check of every lane of a belt (`pc`). (A watched belt's (drift_watched) last check stays as its
-- own checks left it: their quiet turns go by it.)
local function drift_check(b, belt, unit, p)
  local lines = H.lines_of(belt, unit)
  -- (lane_next: each lane's next as the client was told, looked at too: a table look a lane.)
  local units = H.next_check(b, unit, p, "next_fix")
  local now = game.tick
  local unwatched = not b.wset[unit] or (ins_driven() and (b.belts[unit] or {})[16])
  -- (quiet_pc: nothing touched it since its last check: twice as long to the next, up to quiet_pc_max ticks.)
  local br = b.belts[unit]
  if br and not b.wset[unit] then
    if O.quiet_pc and br.ql and now > br.ql then
      br.qw = math.min(tonumber(O.quiet_pc_max) or 0, 2 * (now - br.ql))
    end
    br.ql = now
  end
  for i = 1, #lines do
    local key = unit * LANE_KEYS + i
    local rec = b.lanes[key]
    if rec and rec[5] ~= now then
      local f = H.fns(lines, i)
      local n, p1, pn = H.check_line(lines[i], f)
      units = units + H.CHECK_UNITS
      M.counts.pc = M.counts.pc + 1
      if unwatched then
        rec[6] = now
      end
      -- A packed lane: its front and back items' ids too (`pu`), the only way a lane the client has
      -- a whole gap off shows.
      local fu, bu = 0, 0
      if n > 0 and pn - p1 == GAP * (n - 1) and M.identity and (O.pc_ids or extra_left(b)) then
        local contents = (f and f[3]() or lines[i].get_detailed_contents())
        units = units + n * H.ITEM_UNITS
        if not O.pc_ids then
          extra_spend(b, n * H.ITEM_UNITS)
        end
        -- (As text; 0, a number, where the lane isn't packed: emit tells them apart by it.)
        fu = contents[1] and S(contents[1].unique_id) or 0
        bu = contents[#contents] and S(contents[#contents].unique_id) or 0
      end
      if p then
        local pc = p.pc
        local m = #pc
        pc[m + 1], pc[m + 2], pc[m + 3], pc[m + 4], pc[m + 5], pc[m + 6], pc[m + 7] = S(key), S(now), S(n), S(p1), S(pn), fu, bu
      end
    end
  end
  return units
end

---------------------------------------------------------------------------------------------
-- The scan: the square's belts by ring, nearest first.
--
-- bs.scan = {fx, fy, r, tick, ents, units, xs, ys, rings, first (ring -> index of its first belt),
-- n, idx (unit -> index)}; bs.scanning, one being made.

-- (full_area off.) The client's cap (`bfar` m: items + lanes), its edge holding still: kept while the
-- rings inside it hold up to KEEP times the cap, grown again only once they hold less than GROW times
-- it; belts more than DROP rings past it dropped.

local function quiet_due(rec, now)
  local gap = now - (rec.qt or now)
  rec.qt = now
  if not (rec.qw and rec.ql) then
    return true
  end
  if now - rec.ql + gap > rec.qw then
    return true
  end
  M.counts.pc_quiet = (M.counts.pc_quiet or 0) + 1
  return false
end

-- Drift checks' bands of rings {from, to, how many times pc_every apart} (drift_far), and without it.

-- The watched belts in the order they are checked (input spots first, then nearest first: the
-- scan's order, so the reads for accuracy alone (extra_units) go where the player is looking before
-- they run out), with those fed from outside what is sent when feed_edges is off. Kept in storage
-- and sorted again only when a belt was loaded or dropped or a scan taken (bs.wver): sorting every
-- update cost more than the checks themselves at 160 tiles.
local function watch_order(b)
  local c = b.wcache
  local nosort = O.watch_nosort
  -- (watch_nosort: by wlver, raised only when the watched set, a watched belt's spot or the scan changed;
  -- wver, raised by every belt loaded or dropped, made it again on every update of a walk.)
  local ver = nosort and -(b.wlver or 0) - 1 or (b.wver or 0)
  -- (ins_driven: the belts watched for inserters alone left out; their inserters' checks read them.)
  local driven = ins_driven()
  if c and c.ver == ver and c.fe == O.feed_edges and c.inf == O.inputs_first and c.ins == driven then
    return c.list
  end
  if nosort then
    -- Spots first, then the rest, each nearest first: the scan's indices sorted as numbers (no Lua
    -- comparator: table.sort's own <), then those outside the scan by unit number, as the sort below.
    local idx = b.scan and b.scan.idx
    local units = b.scan and b.scan.units
    local spot = O.inputs_first
    local belts = b.belts
    local si, so, ri, ro = {}, {}, {}, {}
    local function add(u)
      local r = belts[u]
      local j = idx and idx[u]
      -- (Without a scan, by unit number alone, as the sort below.)
      local first = not idx or not spot or (r and r[12])
      if j then
        local t = first and si or ri
        t[#t + 1] = j
      else
        local t = first and so or ro
        t[#t + 1] = u
      end
    end
    for unit in pairs(b.wset) do
      if not (driven and belts[unit] and belts[unit][16]) then
        add(unit)
      end
    end
    if not O.feed_edges then
      for unit in pairs(b.iset) do
        if not b.wset[unit] then
          add(unit)
        end
      end
    end
    table.sort(si)
    table.sort(so)
    table.sort(ri)
    table.sort(ro)
    local w = {}
    for _, j in ipairs(si) do
      w[#w + 1] = units[j]
    end
    for _, u in ipairs(so) do
      w[#w + 1] = u
    end
    for _, j in ipairs(ri) do
      w[#w + 1] = units[j]
    end
    for _, u in ipairs(ro) do
      w[#w + 1] = u
    end
    b.wcache = { ver = ver, fe = O.feed_edges, inf = O.inputs_first, ins = driven, list = w }
    return w
  end
  local w = {}
  for unit in pairs(b.wset) do
    local r = b.belts[unit]
    if not (driven and r and r[16]) then
      w[#w + 1] = unit
    end
  end
  if not O.feed_edges then
    for unit in pairs(b.iset) do
      if not b.wset[unit] then
        w[#w + 1] = unit
      end
    end
  end
  local sc0 = b.scan
  local order = sc0 and sc0.idx
  if order then
    -- (Sort keys worked out once, not in the comparison.)
    local big = math.huge
    local belts = b.belts
    local spot = O.inputs_first
    local key = {}
    for _, u in ipairs(w) do
      local r = belts[u]
      key[u] = ((spot and not (r and r[12])) and 1e9 or 0) + (order[u] or 5e8)
    end
    table.sort(w, function(x, y)
      local kx, ky = key[x], key[y]
      if kx ~= ky then
        return kx < ky
      end
      return x < y
    end)
  else
    table.sort(w)
  end
  b.wcache = { ver = ver, fe = O.feed_edges, inf = O.inputs_first, ins = driven, list = w }
  return w
end

-- far_tier: the watched belts and actors (inserters, drills) split by their ring (far_ring): {near_w, near_a,
-- kinds, units (the far ones, actor before its belt, nearest first), i (the cursor, carried across updates)},
-- made again when the watched list, the actors' list or the scan changed, at most every FAR_REBUILD updates
-- for the same scan (an actor or watched belt new meanwhile waits that long for its first check). In
-- storage (bs.ft), from the scan and the lists.
local function far_split(b, w)
  local ft = b.ft
  local sc = b.scan
  local edge = tonumber(O.far_ring) or 96
  local key = (b.wlver or 0) .. ":" .. #b.alist .. ":" .. edge .. ":" .. tostring(O.inputs_first) .. ":" .. #w
  if ft and ft.scan == sc.tick and (ft.key == key or b.count - ft.built < H.FAR_REBUILD) then
    return ft
  end
  local idx, rings = sc.idx, sc.rings
  local near_w, near_a = {}, {}
  local far_b, far_a = {}, {}
  local jmin, jmax = math.huge, 0
  for _, u in ipairs(w) do
    local j = idx[u]
    if j and rings[j] >= edge then
      local slot = far_b[j]
      if slot == nil then
        far_b[j] = u
      elseif type(slot) == "number" then
        far_b[j] = { slot, u }
      else
        slot[#slot + 1] = u
      end
      if j < jmin then jmin = j end
      if j > jmax then jmax = j end
    else
      near_w[#near_w + 1] = u
    end
  end
  if O.inputs_first then
    for _, u in ipairs(b.alist) do
      local a = b.actors[u]
      if a then
        local j1, j2 = a[2] and idx[a[2]], a[3] and idx[a[3]]
        local j = j1 and j2 and math.min(j1, j2) or j1 or j2
        if j and rings[j] >= edge then
          local slot = far_a[j]
          if slot == nil then
            far_a[j] = u
          elseif type(slot) == "number" then
            far_a[j] = { slot, u }
          else
            slot[#slot + 1] = u
          end
          if j < jmin then jmin = j end
          if j > jmax then jmax = j end
        else
          near_a[#near_a + 1] = u
        end
      end
    end
  end
  local kinds, units = {}, {}
  for j = jmin, jmax do
    local sa = far_a[j]
    if sa then
      if type(sa) == "number" then
        kinds[#kinds + 1] = 7
        units[#units + 1] = sa
      else
        table.sort(sa)
        for _, u in ipairs(sa) do
          kinds[#kinds + 1] = 7
          units[#units + 1] = u
        end
      end
    end
    local sb = far_b[j]
    if sb then
      if type(sb) == "number" then
        kinds[#kinds + 1] = 3
        units[#units + 1] = sb
      else
        table.sort(sb)
        for _, u in ipairs(sb) do
          kinds[#kinds + 1] = 3
          units[#units + 1] = u
        end
      end
    end
  end
  local i = ft and ft.i or 1
  b.ft = { key = key, scan = sc.tick, built = b.count, near_w = near_w, near_a = near_a, kinds = kinds, units = units,
    i = #units > 0 and (i - 1) % #units + 1 or 1 }
  M.counts.far_lists = (M.counts.far_lists or 0) + 1
  return b.ft
end

-- The steady work's queue: segments {kind, list} worked through in order (1 belts touched by events,
-- loaded again whole; 2 groups of lanes the client asked for again; 7 inserters and drills; 3
-- watched belts, then the outermost ring's; 4 drift checks), lists of unit numbers (groups for 2):
-- no table a step.

function mod.reset()
  sig_before = {}
end

function mod.init(m, h)
  M, H = m, h
  H.KEEP, H.GROW, H.DROP = 1.25, 0.85, 2
  catch_up = H.catch_up_fn
  M.hints_active = hints_active
  H.SIG_FIELDS = { 1, 2, 3, 4, 10, 11 }
  H.SETTLE_DEPTH = 1
  H.RUN_SLACK = 8
  M.max_items = 6000
  M.bound_min = 16
  M.bound = nil
  H.DRIFT_NEAR = 48
  H.DRIFT_BANDS = { { 0, H.DRIFT_NEAR, 1 }, { H.DRIFT_NEAR, 2 * H.DRIFT_NEAR, 2 }, { 2 * H.DRIFT_NEAR, math.huge, 4 } }
  H.DRIFT_ONE = { { 0, math.huge, 1 } }
  H.FAR_REBUILD = 16
  H.checkpoint_lane = checkpoint_lane
  H.crossing_lane = crossing_lane
  H.drift_check = drift_check
  H.emit_hints = emit_hints
  H.extra_left = extra_left
  H.extra_spend = extra_spend
  H.far_split = far_split
  H.front_moved = front_moved
  H.full_back = full_back
  H.hint_left = hint_left
  H.hint_spend = hint_spend
  H.hints_active = hints_active
  H.line_side = line_side
  H.note_sig = note_sig
  H.packed_at = packed_at
  H.packed_kind = packed_kind
  H.packed_n = packed_n
  H.quiet_due = quiet_due
  H.quiet_for = quiet_for
  H.read_run = read_run
  H.read_runs = read_runs
  H.settle_around = settle_around
  H.side_lines = side_lines
  H.sig_changed = sig_changed
  H.split_packed = split_packed
  H.watch_lane = watch_lane
  H.watch_order = watch_order
end

return mod
