-- Chunk subscriptions and snapshots: the static part of the world (tiles, buildings, trees,
-- ore). The client subscribes to the chunks around its camera; each one is read and sent once,
-- then kept current by the deltas in tracker.lua and refreshed now and then to heal any loss.

local registry = require("scripts.registry")
local transport = require("scripts.transport")
local budget = require("scripts.budget")
local alt_mode = require("scripts.alt_mode")
local photo = require("scripts.photo")
local perf = require("scripts.perf")
local corpses = require("scripts.corpses")
local world_chunk = require("scripts.world_chunk")

local M = {}

local CHUNK = 32
M.REGION = 16
local ENTITIES_PER_MESSAGE = 120
local BIN_ENTITIES_PER_MESSAGE = 400
local MAX_SUBSCRIPTIONS = 10201 -- a 101x101 chunk square, 3232x3232 tiles (the client's view distance 50)
local MAX_BACKLOG = 128       -- don't read more chunks while this many messages wait to be sent
local ROOM_STARTS = 8         -- chunks started a tick while the work budget has room (I18; f3d-chunks-per-tick the least)
local REFRESH_INTERVAL = 300  -- ticks between re-sending one subscribed chunk
local COUNT_NEAR = 121        -- the nearest this many subscribed chunks (11x11) are counted in turn
local NEAR_CHUNK_RING = 2     -- chunks within this Chebyshev distance of sub_o sort/stream ahead of outer work
local NEAR_CHUNK_FLOOR = 150  -- minimum budget floor (units) for near chunk snapshots under near_rate
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

local function lod_rev_table(si)
  local s = storage.f3d
  s.lod_revs = s.lod_revs or {}
  local t = s.lod_revs[si]
  if not t then
    t = {}
    s.lod_revs[si] = t
  end
  return t
end

function M.rev(si, k)
  local t = storage.f3d.revs and storage.f3d.revs[si]
  return t and t[k] or 0
end

function M.region_rev(si, rx, ry)
  local t = storage.f3d.lod_revs and storage.f3d.lod_revs[si]
  return t and t[key(rx, ry)] or 0
end

function M.all_region_revs(si)
  local t = storage.f3d.lod_revs and storage.f3d.lod_revs[si]
  return t or {}
end

function M.bump_region(si, rx, ry)
  local rt = lod_rev_table(si)
  local rk = key(rx, ry)
  rt[rk] = (rt[rk] or 0) + 1
end

-- Raises the counts of the chunk at `position` and of neighbours within 2 tiles (a belt's or pipe's
-- look follows the ones next to it, which may be across the edge).
function M.bump(si, position)
  local t = rev_table(si)
  local rt = lod_rev_table(si)
  local x, y = position.x or position[1], position.y or position[2]
  local cx, cy = math.floor(x / CHUNK), math.floor(y / CHUNK)
  local lx, ly = x - cx * CHUNK, y - cy * CHUNK
  local x0 = lx < 2 and -1 or 0
  local x1 = lx > CHUNK - 2 and 1 or 0
  local y0 = ly < 2 and -1 or 0
  local y1 = ly > CHUNK - 2 and 1 or 0
  local counted = storage.f3d.counted
  if counted and si ~= storage.f3d.surface_index then
    counted = nil
  end
  local seen_regions = {}
  for dy = y0, y1 do
    for dx = x0, x1 do
      local ncx, ncy = cx + dx, cy + dy
      local k = key(ncx, ncy)
      t[k] = (t[k] or 0) + 1
      local rk = key(math.floor(ncx / M.REGION), math.floor(ncy / M.REGION))
      if not seen_regions[rk] then
        seen_regions[rk] = true
        rt[rk] = (rt[rk] or 0) + 1
      end
      if counted then
        counted[k] = nil -- an event changed it: the client was told, so count_check starts again from here
      end
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

local concat = table.concat
M.wire_signature = world_chunk.wire_signature
M.record = world_chunk.record
M.record_text = world_chunk.record_text

-- A chunk's place in the client's order, nearest the character first. A list subscription (`c`)
-- gives each chunk its place in `s.rank`; a square one (`w`) orders by squared distance from its
-- middle, then row by row, as the client's ring_order does (world.gd), worked out from the chunk.
-- With the client's view direction (`sub` f, I18) a chunk behind it counts as further away: up to
-- twice its distance straight behind (BEHIND), as the client's prio_order, so what the camera looks
-- at and where the character walks comes first. Integers all the way (the most, 101x101 chunks with
-- f, is under 1e14, exact in a double): the same order on every peer.
local BEHIND = 3
local DIST_SCALE = 65536

local function distance_of(s, dx, dy)
  local d = (dx * dx + dy * dy) * DIST_SCALE
  local f = s.sub_f
  if f then
    local dot = dx * f[1] + dy * f[2]
    if dot < 0 then
      d = d + BEHIND * dot * dot
    end
  end
  return d
end

local function rank_of(s, k)
  local o = s.sub_o
  if o then
    local c = s.subs[k]
    if not c then
      return math.huge
    end
    local side = 2 * s.sub_r + 1
    local dx, dy = c[1] - o[1], c[2] - o[2]
    return distance_of(s, dx, dy) * side * side + (dy + s.sub_r) * side + dx + s.sub_r
  end
  return s.rank and s.rank[k] or math.huge
end

-- The queue (s.queue) holds chunk keys from its head, q.h (1 when absent), on: a chunk sent moves the
-- head on and stays in the list until COMPACT_AT have gathered before it. table.remove(q, 1) shifted the
-- whole queue for each chunk: 60 us with 10,201 queued, up to four times a tick. The head is a field
-- of the list itself, so a list made anew starts at 1 (and a save without it too). The same for the
-- chunks told as kept (s.kept).
local COMPACT_AT = 1024

local function qhead(q)
  return q.h or 1
end

-- How many are waiting in a list with a head.
local function qlen(q)
  return #q - (q.h or 1) + 1
end

-- Takes the first of list `q` (s[field]); returns it, or nil when it is empty.
local function qpop(s, field)
  local q = s[field]
  local h = q.h or 1
  local k = q[h]
  if k == nil then
    return nil
  end
  if h >= #q then
    s[field] = {}
  elseif h >= COMPACT_AT then
    local rest = {}
    for i = h + 1, #q do
      rest[#rest + 1] = q[i]
    end
    s[field] = rest
  else
    q.h = h + 1
  end
  return k
end

-- What is queued, from the head, as a new list (h 1).
local function qlist(q)
  local out = {}
  for i = q.h or 1, #q do
    out[#out + 1] = q[i]
  end
  return out
end

local function is_near_chunk(s, k)
  local o = s.sub_o
  if not o then
    return false
  end
  local c = s.subs[k]
  if not c then
    return false
  end
  return math.max(math.abs(c[1] - o[1]), math.abs(c[2] - o[2])) <= NEAR_CHUNK_RING
end

-- Where rank `rank` goes in list `q` (from `lo`, default q.h or 1, to `hi`, default #q + 1), by rank_of.
local function qplace(s, q, rank, lo, hi)
  lo = lo or q.h or 1
  hi = hi or (#q + 1)
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    local r = rank_of(s, q[mid])
    if r <= rank then
      lo = mid + 1
    else
      hi = mid
    end
  end
  return lo
end

-- A chunk's bucket in a requeue (requeue_now, the job): its squared distance with the view direction.
local function bucket_of(s, r)
  local side = 2 * s.sub_r + 1
  return math.floor(math.floor(r / (side * side)) / DIST_SCALE)
end

-- requeue_slices (perf.lua): a long square queue put in a new order (the view turned, the middle moved)
-- by a job over the ticks after (s.rq) instead of at once in the packet handler, where it took several
-- ms with 10,000 queued each time the camera turned during a join. Phase 1 deals the queue's chunks into
-- buckets by their squared distance (with the view direction), REQUEUE_PER_TICK a tick, while chunks are
-- still taken from the queue in its old order; phase 2 makes the queue anew from the buckets in order,
-- each sorted on its own (ranks are unique), as requeue_now does at once, skipping what was taken or
-- dropped meanwhile. A queue of up to REQUEUE_NOW is still ordered at once. rq: {phase, src (the list
-- dealt), i, buckets (d -> keys), top, d (the next bucket read out), tail (no rank), rank (key -> rank,
-- while dealt and not yet read out), n (dealt), out (read out)}. In storage, from packets and ticks.
local REQUEUE_NOW = 512
local REQUEUE_PER_TICK = 1024

-- Puts chunk k, of rank `rank`, in the job's buckets.
local function rq_put(s, rq, k, rank)
  rq.n = rq.n + 1
  if rank == math.huge then
    rq.rank[k] = -1  -- (a mark: no infinity kept in storage)
    rq.tail[#rq.tail + 1] = k
    return
  end
  rq.rank[k] = rank
  local d = bucket_of(s, rank)
  local b = rq.buckets[d]
  if not b then
    b = {}
    rq.buckets[d] = b
    if d > rq.top then
      rq.top = d
    end
  end
  b[#b + 1] = k
end

-- Deals chunk k into the job's buckets, once.
local function rq_deal(s, rq, k)
  if s.queued[k] and rq.rank[k] == nil then
    rq_put(s, rq, k, rank_of(s, k))
  end
end

-- The queue is kept in the client's order (nearest the character first, rank_of), whatever
-- queued a chunk: a new subscription, a chunk Factorio has just generated, a resend. Otherwise,
-- after a jump, chunks queued for the old place and land generated in Factorio's own order went
-- first, and the ground under the character came last.
-- (While a requeue job runs, s.rq: a chunk queued meanwhile goes into its buckets too, or, once they are
-- being read out, into the new queue by its rank if its bucket was read out already.)
local function enqueue(k)
  local s = storage.f3d
  if s.queued[k] then
    return
  end
  s.queued[k] = true
  local rank = rank_of(s, k)
  local near_first = perf.on("near_first") and s.sub_o ~= nil
  local near = near_first and is_near_chunk(s, k)
  local rq = s.rq
  if rq then
    if near then
      rq.rank[k] = nil
    elseif rq.phase == 1 then
      rq_put(s, rq, k, rank)  -- (and in the old queue below, so it can still be taken meanwhile)
    elseif rank == math.huge or bucket_of(s, rank) >= rq.d then
      rq_put(s, rq, k, rank)
      return
    end
  end
  local q = s.queue
  if near_first then
    local head = qhead(q)
    local split = head
    while split <= #q and is_near_chunk(s, q[split]) do
      split = split + 1
    end
    if near then
      table.insert(q, qplace(s, q, rank, head, split), k)
    else
      table.insert(q, qplace(s, q, rank, split, #q + 1), k)
    end
  else
    table.insert(q, qplace(s, q, rank), k)
  end
end

M.enqueue = enqueue

-- The client's copies of chunks it subscribes to again: [surface index, cx, cy, rv, n]. Kept only
-- for chunks still queued.
local function take_have(s, have)
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

-- Chunks the client keeps after they leave its square (`kept`, I18): when a chunk is dropped, its
-- change count then is noted, and a few ticks later (kept_step, under the work budget) the client is
-- told the counts its copy matches, if nothing changed there meanwhile and its entities still number
-- what the bridge last knew the client has. The client's copy then carries those counts, so coming
-- back to it is answered `same` even when things were built there while it was in view (its copy got
-- them as `add` and `del`). For a client whose hello says `lv`.
local MAX_KEPT = 2048     -- noted and not yet told at most (the rest are not told: a snapshot later)
local KEPT_PER_TICK = 16  -- counted a tick at most

-- A chunk the client no longer wants.
local function drop_sub(s, k)
  local c = s.subs[k]
  if c and s.client and s.client.lv and not s.queued[k] and not (s.snap and s.snap.k == k) then
    -- Sent and not to be sent again: the client's copy is as the bridge last told it.
    s.kept = s.kept or {}
    if qlen(s.kept) < MAX_KEPT then
      s.kept[#s.kept + 1] = { k, c[1], c[2], s.surface_index, M.rev(s.surface_index, k) }
    end
  end
  s.subs[k] = nil
  -- The client forgets a chunk's far belt lanes with it (belt_items.lua): sent again if it comes back.
  if s.far then
    s.far.sent[k] = nil
  end
  if s.have then
    s.have[k] = nil
  end
  if s.dec_queued then
    s.dec_queued[k] = nil
  end
  if s.sent then
    s.sent[k] = nil
  end
end

-- A requeue job stopped: what it holds goes back into the queue (in no order: a new order follows).
local function rq_stop(s)
  local rq = s.rq
  if not rq then
    return
  end
  s.rq = nil
  if rq.phase == 2 then
    -- (Phase 1 leaves the old queue whole; phase 2 has the chunks not read out yet in its buckets.)
    local q = s.queue
    for d = rq.d, rq.top do
      for _, k in ipairs(rq.buckets[d] or {}) do
        if s.queued[k] and rq.rank[k] then
          rq.rank[k] = nil
          q[#q + 1] = k
        end
      end
    end
    for _, k in ipairs(rq.tail) do
      if s.queued[k] and rq.rank[k] then
        rq.rank[k] = nil
        q[#q + 1] = k
      end
    end
  end
end

-- One tick of the requeue job, up to `limit` chunks; returns how many it went through.
local function rq_step(s, limit)
  local rq = s.rq
  if not rq then
    return 0
  end
  local n = 0
  if rq.phase == 1 then
    local src = rq.src
    while rq.i <= #src and n < limit do
      rq_deal(s, rq, src[rq.i])
      rq.i = rq.i + 1
      n = n + 1
    end
    if rq.i <= #src then
      return n
    end
    -- Every chunk queued is in the buckets: the queue keeps any remaining near chunks ahead of outer buckets.
    local keep = {}
    if perf.on("near_first") and s.sub_o then
      local q = s.queue
      for idx = qhead(q), #q do
        local k = q[idx]
        if s.queued[k] and is_near_chunk(s, k) and rq.rank[k] == nil then
          keep[#keep + 1] = k
        end
      end
    end
    rq.phase, rq.src, rq.d = 2, nil, 0
    s.queue = keep
  end
  local q = s.queue
  local queued, ranks = s.queued, rq.rank
  local by_rank = function(a, b) return ranks[a] < ranks[b] end
  while rq.d <= rq.top and n < limit do
    local b = rq.buckets[rq.d]
    if b then
      rq.buckets[rq.d] = nil
      if #b > 1 then
        table.sort(b, by_rank)
      end
      for _, k in ipairs(b) do
        if queued[k] and ranks[k] then
          q[#q + 1] = k
          rq.out = rq.out + 1
        end
        ranks[k] = nil
      end
      n = n + #b
    end
    rq.d = rq.d + 1
    n = n + 0.0625 -- (most distances have no chunk)
  end
  if rq.d > rq.top then
    for _, k in ipairs(rq.tail) do
      if queued[k] and ranks[k] then
        q[#q + 1] = k
      end
    end
    s.rq = nil
  end
  return n
end

-- Chunks a requeue job holds that aren't in the queue yet (phase 2), for queue_length.
local function rq_waiting(s)
  local rq = s.rq
  if not (rq and rq.phase == 2) then
    return 0
  end
  return math.max(0, rq.n - rq.out)
end

-- The queue put in the client's order again (rank_of). A long one (a resend of a whole square) is
-- dealt into buckets by squared distance, each sorted on its own, instead of one sort of thousands;
-- with requeue_slices over the ticks after (the job above).
local function requeue_now(s)
  local q = qlist(s.queue)
  s.queue = q
  local rank = {}
  for _, k in ipairs(q) do
    rank[k] = rank_of(s, k)
  end
  local by_rank = function(a, b) return rank[a] < rank[b] end
  local near_first = perf.on("near_first") and s.sub_o ~= nil
  if #q <= REQUEUE_NOW or not s.sub_o then
    if near_first then
      local near, outer = {}, {}
      for _, k in ipairs(q) do
        if is_near_chunk(s, k) then
          near[#near + 1] = k
        else
          outer[#outer + 1] = k
        end
      end
      table.sort(near, by_rank)
      table.sort(outer, by_rank)
      for _, k in ipairs(outer) do
        near[#near + 1] = k
      end
      s.queue = near
      return
    end
    table.sort(q, by_rank)
    return
  end
  local near, buckets, tail = {}, {}, {}
  for _, k in ipairs(q) do
    local r = rank[k]
    if near_first and is_near_chunk(s, k) then
      near[#near + 1] = k
    elseif r == math.huge then
      tail[#tail + 1] = k
    else
      local d = bucket_of(s, r)
      local b = buckets[d]
      if not b then
        b = {}
        buckets[d] = b
      end
      b[#b + 1] = k
    end
  end
  -- The buckets' own distances in order (a view direction stretches them past 2 r^2).
  local ds = {}
  for d in pairs(buckets) do
    ds[#ds + 1] = d
  end
  table.sort(ds)
  local out = {}
  if near_first then
    table.sort(near, by_rank)
    for _, k in ipairs(near) do
      out[#out + 1] = k
    end
  end
  for _, d in ipairs(ds) do
    local b = buckets[d]
    table.sort(b, by_rank)
    for _, k in ipairs(b) do
      out[#out + 1] = k
    end
  end
  for _, k in ipairs(tail) do
    out[#out + 1] = k
  end
  s.queue = out
end

local function requeue(s)
  rq_stop(s)
  if s.sub_o and qlen(s.queue) > REQUEUE_NOW and perf.on("requeue_slices") then
    local q = s.queue
    if perf.on("near_first") then
      local near, outer = {}, {}
      for i = qhead(q), #q do
        local k = q[i]
        if s.queued[k] then
          if is_near_chunk(s, k) then
            near[#near + 1] = k
          else
            outer[#outer + 1] = k
          end
        end
      end
      if #near > 1 then
        local rank = {}
        for _, k in ipairs(near) do
          rank[k] = rank_of(s, k)
        end
        table.sort(near, function(a, b) return rank[a] < rank[b] end)
      end
      local merged = {}
      for _, k in ipairs(near) do
        merged[#merged + 1] = k
      end
      for _, k in ipairs(outer) do
        merged[#merged + 1] = k
      end
      s.queue = merged
      s.rq = { phase = 1, src = outer, i = 1, buckets = {}, top = 0, d = 0, tail = {}, rank = {}, n = 0, out = 0 }
      return
    end
    s.rq = { phase = 1, src = q, i = qhead(q), buckets = {}, top = 0, d = 0, tail = {}, rank = {}, n = 0, out = 0 }
    return
  end
  requeue_now(s)
end
M.requeue_step = rq_step  -- (tests)

-- Replace the subscription set. `list` is ordered nearest first, which is the order chunks
-- are sent in.
function M.subscribe(list, have)
  local s = storage.f3d
  -- (A requeue job's chunks are still `queued`: in the new queue below.)
  s.rq = nil
  s.sub_o, s.sub_r, s.sub_rows, s.sub_n, s.sub_f = nil, nil, nil, nil, nil
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
      drop_sub(s, k)
    end
  end
  s.rank = {}
  for i, k in ipairs(order) do
    s.rank[k] = i
  end
  s.order = order
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
  take_have(s, have)
end

-- The client's view distance reaches 50 chunks, a 101x101 square of 10,201. As a list (`c`) that
-- is about 120 KB, more than a datagram carries, and replacing the whole set took 12-18 ms of a
-- tick each time it changed. So the client sends its square instead (`sub` `o`, `r`, `w`): the
-- middle chunk, how far it reaches, and per row of chunks the runs it wants. Only the chunks that
-- came or went since the last one are touched, row by row; the order (rank_of) comes from the
-- middle, as the client's own.
M.MAX_RADIUS = 50

-- A row's runs from a packet, [cy, x, count, x, count, ...], as sorted, merged inclusive pairs
-- {x1, x2, x1, x2, ...} within lo..hi, added to `into` (empty when there are none).
local function row_runs(row, lo, hi, into)
  local runs = {}
  for i = 2, #row - 1, 2 do
    local x, n = M.chunk_in(row[i]), tonumber(row[i + 1])
    if x and n and n >= 1 then
      local x1, x2 = math.max(x, lo), math.min(x + math.floor(math.min(n, 2 * M.MAX_RADIUS + 1)) - 1, hi)
      if x1 <= x2 then
        runs[#runs + 1] = { x1, x2 }
      end
    end
  end
  for i = 1, #into, 2 do
    runs[#runs + 1] = { into[i], into[i + 1] }
  end
  table.sort(runs, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
  local out = {}
  for _, r in ipairs(runs) do
    if #out > 0 and r[1] <= out[#out] + 1 then
      out[#out] = math.max(out[#out], r[2])
    else
      out[#out + 1] = r[1]
      out[#out + 1] = r[2]
    end
  end
  return out
end

-- Calls fn(cx) for each chunk of runs `a` not in runs `b` (both as row_runs returns them, or nil).
local function each_minus(a, b, fn)
  if not a then
    return
  end
  local nb = b and #b or 0
  local j = 1
  for i = 1, #a, 2 do
    local x, x2 = a[i], a[i + 1]
    while x <= x2 do
      while j <= nb and b[j + 1] < x do
        j = j + 2
      end
      if j > nb or b[j] > x2 then
        for cx = x, x2 do
          fn(cx)
        end
        break
      end
      for cx = x, b[j] - 1 do
        fn(cx)
      end
      x = b[j + 1] + 1
    end
  end
end

-- Whether chunk x is in a row's runs.
local function in_runs(runs, x)
  if runs then
    for i = 1, #runs, 2 do
      if x >= runs[i] and x <= runs[i + 1] then
        return true
      end
    end
  end
  return false
end

-- The nearest COUNT_NEAR subscribed chunks, nearest first (count_check counts them in turn): looked
-- for ring by ring round the middle, so a full square costs a handful of rings.
local function nearest_order(s)
  local o, R = s.sub_o, s.sub_r
  local found = {}
  local want = math.min(COUNT_NEAR, s.sub_n)
  for r = 0, R do
    if #found >= want then
      break
    end
    for dy = -r, r do
      local step = (dy == -r or dy == r) and 1 or 2 * r
      for dx = -r, r, step do
        local k = key(o[1] + dx, o[2] + dy)
        if s.subs[k] then
          found[#found + 1] = k
        end
      end
    end
  end
  local rank = {}
  for _, k in ipairs(found) do
    rank[k] = rank_of(s, k)
  end
  table.sort(found, function(a, b) return rank[a] < rank[b] end)
  for i = #found, COUNT_NEAR + 1, -1 do
    found[i] = nil
  end
  return found
end

-- A square subscription (handlers.sub with `o`, `r`, `w`): see M.MAX_RADIUS. False if malformed.
-- `f`, optional: the client's view direction, [fx, fy] with a length of about 256 (I18); the queue
-- puts chunks behind it later (rank_of).
local function view_dir_in(f)
  if type(f) ~= "table" then
    return nil
  end
  local fx, fy = tonumber(f[1]), tonumber(f[2])
  if not (fx and fy and fx == fx and fy == fy) then
    return nil
  end
  fx = math.max(-256, math.min(256, math.floor(fx)))
  fy = math.max(-256, math.min(256, math.floor(fy)))
  if fx == 0 and fy == 0 then
    return nil
  end
  return { fx, fy }
end

function M.subscribe_square(o, r, w, have, f)
  local s = storage.f3d
  local ox = type(o) == "table" and M.chunk_in(o[1])
  local oy = type(o) == "table" and M.chunk_in(o[2])
  r = tonumber(r)
  if not (ox and oy and r and r == r and type(w) == "table") then
    return false
  end
  f = view_dir_in(f)
  r = math.max(0, math.min(M.MAX_RADIUS, math.floor(r)))
  local rows = {}
  for _, row in pairs(w) do
    local cy = type(row) == "table" and M.chunk_in(row[1])
    if cy and cy >= oy - r and cy <= oy + r then
      local runs = row_runs(row, ox - r, ox + r, rows[cy] or {})
      rows[cy] = #runs > 0 and runs or nil
    end
  end
  local old_rows, old_o, old_r = s.sub_rows, s.sub_o, s.sub_r
  local added = {}
  local dropped = false
  local function add(cx, cy)
    local k = key(cx, cy)
    if not s.subs[k] then
      s.subs[k] = { cx, cy }
      added[#added + 1] = k
    end
  end
  if old_rows then
    -- Row by row, the chunks that went and the ones that came.
    for cy = old_o[2] - old_r, old_o[2] + old_r do
      each_minus(old_rows[cy], rows[cy], function(cx)
        local k = key(cx, cy)
        if s.subs[k] then
          drop_sub(s, k)
          dropped = dropped or s.queued[k]
        end
      end)
    end
    for cy = oy - r, oy + r do
      each_minus(rows[cy], old_rows[cy], function(cx) add(cx, cy) end)
    end
  else
    -- After a list subscription, or none: everything not in the square goes, then the rest comes.
    for k, c in pairs(s.subs) do
      if not in_runs(rows[c[2]], c[1]) then
        drop_sub(s, k)
        dropped = dropped or s.queued[k]
      end
    end
    for cy = oy - r, oy + r do
      local runs = rows[cy]
      if runs then
        for i = 1, #runs, 2 do
          for cx = runs[i], runs[i + 1] do
            add(cx, cy)
          end
        end
      end
    end
  end
  -- A new view direction orders the queue again, as a new middle does.
  local old_f = s.sub_f
  local turned = (old_f == nil) ~= (f == nil) or (f ~= nil and (old_f[1] ~= f[1] or old_f[2] ~= f[2]))
  local moved = not old_o or old_o[1] ~= ox or old_o[2] ~= oy or old_r ~= r or turned
  s.sub_rows, s.sub_o, s.sub_r, s.rank, s.sub_f = rows, { ox, oy }, r, nil, f
  local n = 0
  for cy = oy - r, oy + r do
    local runs = rows[cy]
    if runs then
      for i = 1, #runs, 2 do
        n = n + runs[i + 1] - runs[i] + 1
      end
    end
  end
  s.sub_n = n
  if dropped then
    local queue = {}
    for _, k in ipairs(qlist(s.queue)) do
      if s.subs[k] then
        queue[#queue + 1] = k
      else
        s.queued[k] = nil
      end
    end
    s.queue = queue
  end
  -- New chunks join the queue in the client's order; a new middle orders the whole queue again.
  if moved or #added > 64 then
    for _, k in ipairs(added) do
      if not s.queued[k] then
        s.queued[k] = true
        s.queue[#s.queue + 1] = k
      end
    end
    requeue(s)
  else
    for _, k in ipairs(added) do
      enqueue(k)
    end
  end
  if moved or #added > 0 or dropped or not s.order then
    s.order = nearest_order(s)
  end
  if moved then
    M.dec_in_range()
  end
  take_have(s, have)
  return true
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

-- Every subscribed chunk queued again, in order: put in and ordered once (enqueue's sorted insert
-- of each was quadratic, 0.1 s for a 101x101 square).
function M.resend_all()
  local s = storage.f3d
  s.rq = nil
  s.queue, s.queued = {}, {}
  local in_order = not s.sub_o and s.order
  if in_order then
    -- A list subscription: its own order already.
    for _, k in ipairs(s.order) do
      if s.subs[k] and not s.queued[k] then
        s.queued[k] = true
        s.queue[#s.queue + 1] = k
      end
    end
  end
  local more = false
  for k in pairs(s.subs) do
    if not s.queued[k] then
      s.queued[k] = true
      s.queue[#s.queue + 1] = k
      more = true
    end
  end
  if more then
    requeue(s)
  end
end

function M.clear()
  local s = storage.f3d
  s.subs, s.queue, s.queued, s.dec_dirty, s.rank, s.have = {}, {}, {}, {}, {}, {}
  s.order, s.counted, s.sent = {}, {}, {}
  s.sub_o, s.sub_r, s.sub_rows, s.sub_n, s.sub_f = nil, nil, nil, nil, nil
  s.refresh_cursor, s.snap, s.count_cursor, s.kept, s.rq = nil, nil, nil, nil, nil
  s.dec_held, s.dec_sent, s.dec_queue, s.dec_queued = nil, nil, nil, nil
  alt_mode.contents_forget() -- the chests' Alt-mode icons are sent again with the new world
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
-- dec_distance (perf.lua): a client whose hello says how far it draws decoratives (`dd`, tiles) gets a chunk's
-- `dec` only while the chunk's middle is within dd + DEC_MARGIN of its square's middle (else of the focus); a
-- chunk left out is held (s.dec_held) and sent once the square's middle brings it inside (dec_in_range) or the
-- distance grows. At view distance 50, 94% of chunks lie past the 256-320 tiles the client draws them at, and
-- decoratives are a fifth to a third of a snapshot's work. s.dec_sent: the chunks whose decoratives the client
-- was sent (a `same` answer for one it hasn't sends them). Without dd every chunk's, as before.
local DEC_MARGIN = 64

local function dec_middle(s)
  local o = s.sub_o
  if o then
    return o[1] * CHUNK + 16, o[2] * CHUNK + 16
  end
  return s.focus.x, s.focus.y
end

local function dec_near(s, cx, cy)
  local dd = s.client and s.client.dd
  if not dd or not perf.on("dec_distance") then
    return true
  end
  local mx, my = dec_middle(s)
  local dx, dy = cx * CHUNK + 16 - mx, cy * CHUNK + 16 - my
  local reach = dd + DEC_MARGIN
  return dx * dx + dy * dy <= reach * reach
end

local function send_decoratives(surface, cx, cy)
  local s = storage.f3d
  if not (s.client and s.client.dc) then
    return
  end
  local k = key(cx, cy)
  if not dec_near(s, cx, cy) then
    s.dec_held = s.dec_held or {}
    s.dec_held[k] = true
    if s.dec_sent then
      s.dec_sent[k] = nil
    end
    return
  end
  if s.dec_held then
    s.dec_held[k] = nil
  end
  if s.client.dd then
    s.dec_sent = s.dec_sent or {}
    s.dec_sent[k] = true
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
  if perf.on("chunk_text") then
    -- (As text: the numbers are integers, which table.concat writes as JSON does.)
    for part = 1, parts do
      transport.send_reliable_text("dec", ',"cx":' .. cx .. ',"cy":' .. cy .. ',"part":' .. part .. ',"parts":' .. parts
        .. ',"l":[' .. concat(flat, ",", (part - 1) * per + 1, math.min(part * per, m)) .. "]")
    end
    return
  end
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

-- The same for every chunk a box (an entity's bounding_box) reaches.
function M.decoratives_changed_in(surface, box)
  local lt, rb = box.left_top, box.right_bottom
  for cy = math.floor(lt.y / CHUNK), math.floor(rb.y / CHUNK) do
    for cx = math.floor(lt.x / CHUNK), math.floor(rb.x / CHUNK) do
      M.decoratives_changed(surface, { x = cx * CHUNK, y = cy * CHUNK })
    end
  end
end

-- (dec_distance) The held chunks now within reach (the square's middle moved, the distance grew): sent with
-- the next decoratives' round. Looks at the chunks round the middle only, not every held one.
function M.dec_in_range()
  local s = storage.f3d
  local held = s.dec_held
  if not (held and next(held) and s.client) then
    return
  end
  if not s.client.dd or not perf.on("dec_distance") then
    -- (No distance any more, or the switch turned off: every chunk held comes.)
    s.dec_dirty = s.dec_dirty or {}
    for k in pairs(held) do
      if s.subs[k] then
        s.dec_dirty[k] = true
      end
    end
    s.dec_held = {}
    return
  end
  local mx, my = dec_middle(s)
  local reach = s.client.dd + DEC_MARGIN
  local r = math.ceil(reach / CHUNK)
  local ox, oy = math.floor(mx / CHUNK), math.floor(my / CHUNK)
  for cy = oy - r, oy + r do
    for cx = ox - r, ox + r do
      local k = key(cx, cy)
      if held[k] and s.subs[k] and dec_near(s, cx, cy) then
        held[k] = nil
        s.dec_dirty = s.dec_dirty or {}
        s.dec_dirty[k] = true
      end
    end
  end
end

-- Queues a chunk's decoratives into a lower-priority list so chunk snapshots (tiles + buildings)
-- finish ahead of clutter when many chunks stream at once. Chunks outside dd+margin move straight
-- to s.dec_held without spending decorative budget.
local function queue_decoratives(s, k, cx, cy)
  if not (s.client and s.client.dc) then
    return
  end
  if not dec_near(s, cx, cy) then
    s.dec_held = s.dec_held or {}
    s.dec_held[k] = true
    if s.dec_sent then
      s.dec_sent[k] = nil
    end
    return
  end
  s.dec_queued = s.dec_queued or {}
  if s.dec_queued[k] then
    return
  end
  s.dec_queued[k] = true
  s.dec_queue = s.dec_queue or {}
  s.dec_queue[#s.dec_queue + 1] = { k, cx, cy }
end

local function send_dirty_decoratives(surface)
  local s = storage.f3d
  local dirty = s.dec_dirty
  if not dirty or not next(dirty) then
    return
  end
  s.dec_dirty = {}
  if perf.on("prio_queue") then
    local keys, rank = {}, {}
    for k in pairs(dirty) do
      keys[#keys + 1] = k
      rank[k] = rank_of(s, k)
    end
    table.sort(keys, function(a, b)
      if rank[a] ~= rank[b] then
        return rank[a] < rank[b]
      end
      return a < b
    end)
    for _, k in ipairs(keys) do
      local c = s.subs[k]
      if c and not s.queued[k] then
        queue_decoratives(s, k, c[1], c[2])
      end
    end
    return
  end
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
local REQUEUE_UNITS = 40  -- chunks a requeue job deals or reads out for a work unit
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
  return math.max(10, math.min(60, math.floor((job.count or #job.records) / 8)))
end

-- A snapshot's frames for a wire version 3 client (docs/PROTOCOL.md, "Binary frames"): `chunk` (kind 19) with
-- its tiles' runs as a block, then each `ents` part (kind 20): the records' five numbers as one block, the
-- indexes of those with extras as another, and their extras as JSON text after them (transport.json_object,
-- as chunk_text writes them). Made whole before any is sent; throws when string.pack refuses a number.
local function snapshot_frames(job, parts, per)
  local records = job.records
  local out = { string.pack("<i4i4I4I4I4I4", job.cx, job.cy, parts, job.si, job.rev, job.count) }
  transport.pack_block(out, job.tiles)
  local frames = { concat(out) }
  local head = string.pack("<i4i4", job.cx, job.cy)
  for part = 1, parts do
    local flat, xi, extras = {}, {}, {}
    local first = (part - 1) * per + 1
    local n = 0
    for i = first, math.min(part * per, #records) do
      local rec = records[i]
      flat[n + 1], flat[n + 2], flat[n + 3], flat[n + 4], flat[n + 5] = rec[1], rec[2], rec[3], rec[4], rec[5]
      n = n + 5
      local x = rec[6]
      if x then
        xi[#xi + 1] = i - first
        extras[#extras + 1] = transport.json_object(x)
      end
    end
    local tail = #extras > 0 and "[" .. concat(extras, ",") .. "]" or ""
    out = { head, string.pack("<I4I4", part, parts) }
    transport.pack_block(out, flat)
    transport.pack_block(out, xi)
    out[#out + 1] = string.pack("<I4", #tail)
    out[#out + 1] = tail
    frames[part + 1] = concat(out)
  end
  return frames
end

local function send_snapshot(job)
  local records = job.records
  local ckey = job.cx .. "," .. job.cy
  if job.bin then
    if transport.binary(3) then
      local parts = math.max(1, math.ceil(#records / BIN_ENTITIES_PER_MESSAGE))
      local ok, frames = pcall(snapshot_frames, job, parts, BIN_ENTITIES_PER_MESSAGE)
      if ok then
        transport.send_reliable_frame(transport.KIND_CHUNK, "chunk", frames[1], 3, ckey)
        for part = 1, parts do
          transport.send_reliable_frame(transport.KIND_ENTS, "ents", frames[part + 1], 3, ckey)
        end
        return
      end
    end
    -- (string.pack refused a number, or the client reads no binary now: the same as text, below.)
    job.bin = nil
    if job.text then
      job.tiles = concat(job.tiles, ",")
      for i = 1, #records do
        records[i] = M.record_text(records[i])
      end
    end
  end
  local parts = math.max(1, math.ceil(#records / ENTITIES_PER_MESSAGE))
  if job.text then
    -- (chunk_text: the tiles and records are text already, made in the job's slices.)
    local at = ',"cx":' .. job.cx .. ',"cy":' .. job.cy
    transport.send_reliable_text("chunk", at .. ',"tiles":[' .. job.tiles .. '],"parts":' .. parts .. ',"rs":' .. job.si
      .. ',"rv":' .. job.rev .. ',"n":' .. job.count, ckey)
    for part = 1, parts do
      transport.send_reliable_text("ents", at .. ',"part":' .. part .. ',"parts":' .. parts .. ',"e":['
        .. concat(records, ",", (part - 1) * ENTITIES_PER_MESSAGE + 1, math.min(part * ENTITIES_PER_MESSAGE, #records)) .. "]", ckey)
    end
    return
  end
  transport.send_reliable({ t = "chunk", cx = job.cx, cy = job.cy, tiles = job.tiles, parts = parts,
    rs = job.si, rv = job.rev, n = job.count }, ckey)
  for part = 1, parts do
    local slice = {}
    for i = (part - 1) * ENTITIES_PER_MESSAGE + 1, math.min(part * ENTITIES_PER_MESSAGE, #records) do
      slice[#slice + 1] = records[i]
    end
    transport.send_reliable({ t = "ents", cx = job.cx, cy = job.cy, part = part, parts = parts, e = slice }, ckey)
  end
end

-- What count_check last counted in each chunk (key -> entities), from the snapshot on.
local function counted(s)
  s.counted = s.counted or {}
  return s.counted
end

-- One slice of the job in s.snap; clears it when the chunk is sent.
local function snapshot_step(surface, s)
  local job = s.snap
  local cx, cy = job.cx, job.cy
  local x0, y0 = cx * CHUNK, cy * CHUNK
  if job.step < 0 then
    local ckey = cx .. "," .. cy
    if not surface.is_chunk_generated({ cx, cy }) then
      if job.text then
        transport.send_reliable_text("chunk", ',"cx":' .. cx .. ',"cy":' .. cy .. ',"none":true', ckey)
      else
        transport.send_reliable({ t = "chunk", cx = cx, cy = cy, none = true }, ckey)
      end
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
        counted(s)[job.k] = job.count
        s.sent = s.sent or {}
        s.sent[job.k] = { si = job.si, rv = job.rev, n = job.count }
        if job.text then
          transport.send_reliable_text("chunk", ',"cx":' .. cx .. ',"cy":' .. cy .. ',"rs":' .. job.si .. ',"same":' .. job.rev, ckey)
        else
          transport.send_reliable({ t = "chunk", cx = cx, cy = cy, rs = job.si, same = job.rev }, ckey)
        end
        -- (dec_distance: the client's copy may have been made while the chunk was too far for its decoratives.)
        if s.client and s.client.dd and s.client.dc and not (s.dec_sent and s.dec_sent[job.k]) then
          queue_decoratives(s, job.k, cx, cy)
        end
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
    if job.text and not job.bin then
      job.tiles = concat(job.tiles, ",")
    end
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
    -- So are characters' corpses (corpses.lua; f3d-character-corpses off: not sent).
    for _, e in pairs(corpses.in_area(surface, area)) do
      found[#found + 1] = e
    end
    -- An entity overlapping several chunks (or strips) belongs to the one containing its centre.
    local records, text = job.records, job.text and not job.bin
    for _, e in pairs(found) do
      local p = e.position
      if p.x >= x0 and p.x < x0 + CHUNK and p.y >= ya and p.y < yb then
        if text then
          records[#records + 1] = M.record_text(M.record(e))
        else
          records[#records + 1] = M.record(e)
        end
      end
    end
    job.step = job.step + 1
    return
  end
  s.snap = nil
  send_snapshot(job)
  counted(s)[job.k] = not job.touched and job.count or nil
  s.sent = s.sent or {}
  s.sent[job.k] = not job.touched and { si = job.si, rv = job.rev, n = job.count } or nil
  queue_decoratives(s, job.k, cx, cy)
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

-- The next chunk queued, taken off the queue (nil when it is empty).
function M.take_next()
  local s = storage.f3d
  local k = qpop(s, "queue")
  if k ~= nil then
    s.queued[k] = nil
  end
  return k
end

-- Chunks queued (/f3d-status).
function M.queued_count()
  local s = storage.f3d
  return (s.queue and qlen(s.queue) or 0) + rq_waiting(s)
end

-- Chunks waiting to be sent (the one being read counts).
function M.queue_length()
  local s = storage.f3d
  return (s.queue and qlen(s.queue) or 0) + rq_waiting(s) + (s.snap and 1 or 0) + (s.kept and qlen(s.kept) or 0)
    + (s.dec_queue and qlen(s.dec_queue) or 0)
end
budget.register_queue("chunks", M.queue_length)

local function next_refresh(surface)
  local s = storage.f3d
  if s.refresh_cursor and not s.subs[s.refresh_cursor] then
    s.refresh_cursor = nil
  end
  s.refresh_cursor = next(s.subs, s.refresh_cursor) or next(s.subs, nil)
  local k = s.refresh_cursor
  if not k or s.queued[k] or (s.snap and s.snap.k == k) then
    return
  end
  local sent = s.sent and s.sent[k]
  if sent and surface and sent.si == surface.index and M.rev(surface.index, k) == sent.rv then
    local c = s.subs[k]
    local x0, y0 = c[1] * CHUNK, c[2] * CHUNK
    local count = surface.count_entities_filtered({
      area = { { x0, y0 }, { x0 + CHUNK, y0 + CHUNK } }, type = registry.excluded_types(), invert = true,
    })
    budget.spend(2, "chunks")
    if count == sent.n then
      counted(s)[k] = count
      return
    end
    M.bump(surface.index, { x = x0 + 16, y = y0 + 16 })
  end
  enqueue(k)
end

-- Entities made or removed by a script without an event (`destroy()` without raise_destroy,
-- `create_entity` without raise_built) reach no tracker handler, so the client went on drawing
-- them, or never drew them, until the chunk's turn in next_refresh: one chunk every 5 s, most of an
-- hour for a whole view (trees cleared by a script stayed drawn, filming the B-roll). The chunks
-- nearest the client are counted in turn instead, one every count_interval ticks (11x11 chunks in
-- 8 s), against the count its snapshot had; an event in a chunk (bump) starts its count again from
-- the next look, since the client was told of it. A count that changed unseen sends the chunk again.
M.count_interval = 4  -- ticks between two counts (0: none; tools/mod_tests set it, a constant otherwise)

local function count_check(surface, s)
  local order = s.order
  if not order or #order == 0 then
    return
  end
  local n = math.min(#order, COUNT_NEAR)
  local i = (s.count_cursor or 0) % n + 1
  s.count_cursor = i
  local k = order[i]
  local c = s.subs[k]
  if not c or s.queued[k] or (s.snap and s.snap.k == k) then
    return
  end
  local x0, y0 = c[1] * CHUNK, c[2] * CHUNK
  local count = surface.count_entities_filtered({
    area = { { x0, y0 }, { x0 + CHUNK, y0 + CHUNK } }, type = registry.excluded_types(), invert = true,
  })
  budget.spend(2, "chunks")
  local seen = counted(s)
  local before = seen[k]
  if before == nil then
    seen[k] = count
  elseif before ~= count then
    M.bump(surface.index, { x = x0 + 16, y = y0 + 16 }) -- the client's kept copy is out of date too
    enqueue(k)
  end
end

-- The chunks the client dropped, told as kept (see MAX_KEPT): KEPT_PER_TICK counted a tick, under the
-- chunks' share of the work budget, in one `kept` message.
local function kept_step(surface, s)
  local q = s.kept
  if not q or qlen(q) == 0 then
    return
  end
  local out = {}
  local seen = counted(s)
  local taken = 0
  while taken < KEPT_PER_TICK and qlen(s.kept) > 0 do
    if not budget.can(2, "chunks", WORLD_SHARE) then
      break
    end
    local e = qpop(s, "kept")
    taken = taken + 1
    local k = e[1]
    -- Asked for again meanwhile (its snapshot or `same` tells it), another surface, or changed since.
    if not s.subs[k] and e[4] == surface.index and M.rev(surface.index, k) == e[5] then
      local x0, y0 = e[2] * CHUNK, e[3] * CHUNK
      local n = surface.count_entities_filtered({
        area = { { x0, y0 }, { x0 + CHUNK, y0 + CHUNK } }, type = registry.excluded_types(), invert = true,
      })
      budget.spend(2, "chunks")
      -- Counted since its last event, and not as many now: something changed unseen, not told.
      local before = seen[k]
      if before == nil or before == n then
        out[#out + 1] = e[2]
        out[#out + 1] = e[3]
        out[#out + 1] = e[5]
        out[#out + 1] = n
      end
    end
  end
  if #out > 0 then
    transport.send_reliable({ t = "kept", rs = surface.index, l = out })
  end
end

function M.tick()
  local s = storage.f3d
  local surface = M.surface()
  if game.tick % REFRESH_INTERVAL == 0 then
    next_refresh(surface)
  end
  if M.count_interval > 0 and game.tick % M.count_interval == 0 then
    count_check(surface, s)
  end
  kept_step(surface, s)
  if game.tick % DECORATIVE_INTERVAL == 0 then
    send_dirty_decoratives(surface)
  end
  -- At most f3d-chunks-per-tick chunks start a tick, and each is read in slices while the work
  -- budget lasts. Only a chunk that has to be read counts: one the client still has (`same`) or
  -- that isn't generated (`none`) costs a count of its entities, so a view the client kept comes
  -- back within a few ticks instead of a chunk a tick (a surface change and back, Factorissimo's
  -- buildings: 441 chunks took 7.4 s).
  -- A screenshot loading (photo.lua) reads more a tick, with more of the budget and a longer outbox.
  -- More than one start a tick (ROOM_STARTS, I18): each later chunk only while its slices fit what is
  -- left of the chunks' share this tick (budget.can lets only a job's first slice of a tick past it),
  -- so it costs nothing on a tick that is full anyway, and the UPS governor's budget bounds it all.
  -- A requeue job (requeue_slices) first: the queue's new order, a slice a tick.
  if s.rq and budget.can(REQUEUE_PER_TICK / REQUEUE_UNITS, "chunks", WORLD_SHARE) then
    budget.spend(rq_step(s, REQUEUE_PER_TICK) / REQUEUE_UNITS, "chunks")
  end
  local starts = math.max(settings.global["f3d-chunks-per-tick"].value, ROOM_STARTS)
  local share, backlog = WORLD_SHARE, MAX_BACKLOG
  if photo.on() then
    starts, share, backlog = math.max(starts, photo.STARTS), photo.SHARE, photo.BACKLOG
  end
  while transport.backlog() < backlog do
    if s.snap and not s.subs[s.snap.k] then
      s.snap = nil -- no longer wanted
    end
    if not s.snap then
      if starts <= 0 or qlen(s.queue) == 0 then
        break
      end
      local k = M.take_next()
      local c = s.subs[k]
      if c then
        -- (text: written as JSON text in its slices, perf.lua chunk_text; bin: kept as numbers for a client of
        -- wire version 3, its snapshot sent as binary frames, send_snapshot. A job keeps the way it began.)
        s.snap = { k = k, cx = c[1], cy = c[2], step = -1, text = perf.on("chunk_text") or nil,
          bin = transport.binary(3) or nil }
      end
    end
    if s.snap then
      local price = snap_price(s.snap)
      local can
      if perf.on("near_rate") and s.sub_o
          and math.max(math.abs(s.snap.cx - s.sub_o[1]), math.abs(s.snap.cy - s.sub_o[2])) <= NEAR_CHUNK_RING then
        can = budget.can(price, "chunks", share, NEAR_CHUNK_FLOOR)
      else
        can = budget.can(price, "chunks", share)
      end
      if not can then
        break
      end
      budget.spend(price, "chunks")
      local checking = s.snap.step < 0
      snapshot_step(surface, s)
      if checking and s.snap then
        starts = starts - 1 -- it has to be read
      end
    end
  end
  if not s.snap and qlen(s.queue) == 0 and s.dec_queue then
    while transport.backlog() < backlog and qlen(s.dec_queue) > 0 do
      local entry = s.dec_queue[qhead(s.dec_queue)]
      local k, cx, cy = entry[1], entry[2], entry[3]
      if not s.subs[k] then
        qpop(s, "dec_queue")
        if s.dec_queued then
          s.dec_queued[k] = nil
        end
      elseif not dec_near(s, cx, cy) then
        qpop(s, "dec_queue")
        if s.dec_queued then
          s.dec_queued[k] = nil
        end
        send_decoratives(surface, cx, cy)
      else
        if not budget.can(DECORATIVE_PRICE, "chunks", share) then
          break
        end
        qpop(s, "dec_queue")
        if s.dec_queued then
          s.dec_queued[k] = nil
        end
        budget.spend(DECORATIVE_PRICE, "chunks")
        send_decoratives(surface, cx, cy)
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
        transport.send_reliable_priority({ t = "tiles", l = list })
        list = {}
      end
    end
  end
  if #list > 0 then
    transport.send_reliable_priority({ t = "tiles", l = list })
  end
end

corpses.bind(M)

return M
