-- Text and binary part writers for belt_sim.lua: integer formatting (`S`, `NUM`, `STR`),
-- JSON and binary frame encoders (`part_text`, `part_bin`), and multi-part range packing
-- (`build_parts`). Module-local caches/buffers only; never touches `storage`.

local transport = require("scripts.transport")
local world = require("scripts.world")
local profile = require("scripts.profile")

local M = {}

local floor = math.floor
local ceil = math.ceil

-- Lane keys: unit number * LANE_KEYS + line index (a splitter has 8 lines).
local LANE_KEYS = 8
M.LANE_KEYS = LANE_KEYS

-- What is sent is written as text where it is read (S): the small integers most of a `bs` part is
-- (positions, counts, item ids) from NUM, the big ones (unique ids, lane keys, the tick) memoised in
-- STR, emptied once it holds STR_MAX (keys and the tick recur every update, an item's id while it is
-- on the watched lanes). tostring of a number is the dear part of writing one, and a loop in Lua
-- over the numbers at send time cost as much again. Module-local: the same text on every peer.
local NUM = {}
for v = -1, 8192 do
  NUM[v] = tostring(v)
end
-- For a client that gets binary frames (transport.binary(2), docs/PROTOCOL.md "Binary frames") the numbers
-- stay numbers (`raw`, set each tick by belt_sim.tick): string.pack takes them at about 31 ns each, against 59
-- for their text and 34 for table.concat of it (2.1, live), and no text is made. Either encoder takes
-- either kind, so a list written before the client's hello changed it is still sent whole.
local STR, str_n = {}, 0
local STR_MAX = 60000
local raw = false

function M.set_raw(v)
  raw = v
end

function M.S(v)
  if raw then
    return v
  end
  local s = NUM[v]
  if s then
    return s
  end
  s = STR[v]
  if not s then
    if str_n >= STR_MAX then
      STR, str_n = {}, 0
    end
    s = tostring(v)
    STR[v] = s
    str_n = str_n + 1
  end
  return s
end

-- The text of one part: its fields' ranges written as JSON lists. The lists hold the numbers' text
-- already (S, where they are written), so each range is one table.concat in C, no loop over the
-- numbers here (the perfbridge2 round: that loop was most of bse.text, 6-10 ms an update at -62,-26).
local PART_FIELDS = { "lm", "sl", "ew", "sh", "pc", "pu", "dl", "of", "sx" }
local part_pieces = {}

function M.part_text(head, k, part)
  local text = { head, ',"part":', k }
  local pieces = part_pieces
  for _, field in ipairs(PART_FIELDS) do
    local ranges = part[field]
    if ranges and #ranges > 0 then
      local n = 0
      for r = 1, #ranges, 3 do
        n = n + 1
        pieces[n] = table.concat(ranges[r], ",", ranges[r + 1], ranges[r + 2])
      end
      text[#text + 1] = ',"' .. field .. '":[' .. table.concat(pieces, ",", 1, n) .. "]"
    end
  end
  local ranges = part.qu
  if #ranges > 0 then
    local q = {}
    for r = 1, #ranges, 3 do
      local list = ranges[r]
      for y = ranges[r + 1], ranges[r + 2], 2 do
        q[#q + 1] = list[y] .. ',"' .. list[y + 1] .. '"'
      end
    end
    text[#text + 1] = ',"qu":[' .. table.concat(q, ",") .. "]"
  end
  return table.concat(text)
end

-- The binary twin of part_text, for a client that gets binary frames (docs/PROTOCOL.md, "Binary frames",
-- kind 17): the same ranges packed with string.pack, never turned into text. The head's numbers as u32
-- (fx, fy signed), then one block a field in BIN_FIELDS' order, then qu. Every lane key (a record's
-- first number, and lm's next) is written as two numbers, the belt's unit number and the line index
-- (signed as the key: lm's next -1 is 0, -1), so a part stays 32-bit whatever the unit numbers reach.
-- `width` 4 or 8; throws when a number doesn't fit (spool_step tries 8, then the text). For a client of wire
-- version 5 or later a part with crossing hints ends with one more block, sx (7 numbers a record, no lane keys);
-- without hints it ends at qu's text as before, which is all an older client reads.
local BIN_FIELDS = { "lm", "sl", "ew", "sh", "pc", "pu", "dl", "of" }
-- Numbers a record (0: sl, by its count) and whether it starts with a lane key.
local BIN_STRIDE = { lm = 12, sl = 0, ew = 4, sh = 2, pc = 5, pu = 3, dl = 1, of = 2 }
local BIN_KEYED = { lm = true, sl = true, ew = true, sh = true, pc = true, pu = true, dl = true }

-- A lane key (a number or its text) as the belt's unit number and line index: 0 is 0, 0; minus a
-- key (lm's next leading out) has the line negative.
local function lane_pair(key)
  local v = tonumber(key)
  if v == 0 then
    return 0, 0
  end
  local a = v < 0 and -v or v
  local unit = floor((a - 1) / LANE_KEYS)
  local line = a - unit * LANE_KEYS
  return unit, v < 0 and -line or line
end

local bin_tmp = {}

function M.part_bin(scalars, k, number, part, width)
  local pack, run_format = string.pack, transport.run_format
  local out = { pack("<I4I4I4I4I4i4i4I4I4", k, number, scalars[1], scalars[2], scalars[3], scalars[4], scalars[5],
    scalars[6], scalars[7]) }
  local tmp = bin_tmp
  for _, field in ipairs(BIN_FIELDS) do
    local ranges = part[field]
    local head = #out + 1
    out[head] = ""
    local count = 0
    if field == "sl" then
      -- (A range is one lane: its key split, the rest packed straight from the list.)
      for r = 1, #ranges, 3 do
        local list, a, b = ranges[r], ranges[r + 1], ranges[r + 2]
        local u, l = lane_pair(list[a])
        if b - a <= transport.PACK_RUN then
          out[#out + 1] = pack(run_format(width, b - a + 2), u, l, table.unpack(list, a + 1, b))
        else
          out[#out + 1] = pack(run_format(width, 2), u, l)
          transport.pack_runs(out, list, a + 1, b, width)
        end
        count = count + b - a + 2
      end
    elseif #ranges > 0 then
      -- (Short records, or few: copied with their keys split, then packed.)
      local stride, keyed = BIN_STRIDE[field], BIN_KEYED[field]
      local n = 0
      for r = 1, #ranges, 3 do
        local list, a, b = ranges[r], ranges[r + 1], ranges[r + 2]
        for x = a, b, stride do
          local y = 0
          if keyed then
            tmp[n + 1], tmp[n + 2] = lane_pair(list[x])
            n, y = n + 2, 1
          end
          for j = x + y, x + stride - 1 do
            n = n + 1
            tmp[n] = list[j]
          end
          if field == "lm" then
            -- (Its last number, next, is a key too.)
            tmp[n], tmp[n + 1] = lane_pair(list[x + 11])
            n = n + 1
          end
        end
      end
      transport.pack_runs(out, tmp, 1, n, width)
      count = n
      for j = n, 1, -1 do
        tmp[j] = nil
      end
    end
    out[head] = pack("<BI4", width, count)
  end
  -- qu: the items' unique ids as a block, then their quality names joined by commas (u32 bytes, the text).
  local ranges = part.qu
  local names, n = {}, 0
  for r = 1, #ranges, 3 do
    local list = ranges[r]
    for y = ranges[r + 1], ranges[r + 2], 2 do
      n = n + 1
      tmp[n] = list[y]
      names[n] = list[y + 1]
    end
  end
  out[#out + 1] = pack("<BI4", width, n)
  transport.pack_runs(out, tmp, 1, n, width)
  for j = n, 1, -1 do
    tmp[j] = nil
  end
  local text = table.concat(names, ",")
  out[#out + 1] = pack("<I4", #text) .. text
  -- sx (wire version 5): its records' numbers as they are.
  ranges = part.sx
  if ranges and #ranges > 0 and transport.binary(5) then
    n = 0
    for r = 1, #ranges, 3 do
      local list = ranges[r]
      for y = ranges[r + 1], ranges[r + 2] do
        n = n + 1
        tmp[n] = list[y]
      end
    end
    out[#out + 1] = pack("<BI4", width, n)
    transport.pack_runs(out, tmp, 1, n, width)
    for j = n, 1, -1 do
      tmp[j] = nil
    end
  end
  return table.concat(out)
end

local function is_near_unit(b, sc, near_r, unit)
  if not sc or not unit or unit <= 0 then
    return true
  end
  local j = sc.idx and sc.idx[unit]
  if j then
    return sc.rings[j] <= near_r
  end
  local rec = b.belts[unit]
  if rec then
    return math.max(math.abs(rec[2] - sc.fx), math.abs(rec[3] - sc.fy)) <= near_r
  end
  return false
end

-- Packs an update's payload into `bs` parts (near-first when near_spool is active) and returns
-- `parts, head, scalars`. Each part's fields are kept as ranges of the update's lists (nothing copied).
function M.build_parts(b, p, period, fr, work, loading, most, near_spool, walk_near)
  local te = profile.start()
  local sc = b.scan
  local parts = {}
  local cur, size = nil, 0
  local function new_part()
    cur = { lm = {}, sl = {}, qu = {}, pc = {}, pu = {}, dl = {}, of = {}, ew = {}, sh = {}, sx = {} }
    parts[#parts + 1] = cur
    size = 0
  end
  new_part()
  -- (A range: list, from, to; one after another in the part's field.)
  local function add(field, list, from, to)
    if size > 0 and size + (to - from + 1) > most then
      new_part()
    end
    local out = cur[field]
    local m = #out
    out[m + 1], out[m + 2], out[m + 3] = list, from, to
    size = size + (to - from + 1)
  end
  local dl, of, lm, sl, qu, ew, sh, pc, sx = p.dl, p.of, p.lm, p.sl, p.qu, p.ew, p.sh, p.pc, p.sx or {}
  -- (pc 7 wide here: the last two its packed lane's front and back ids, 0 when not packed, sent in
  -- `pu` in the same part.)
  local pu = {}
  local function emit_pc(y)
    add("pc", pc, y, y + 4)
    if pc[y + 5] ~= 0 then
      local m = #pu
      pu[m + 1], pu[m + 2], pu[m + 3] = pc[y], pc[y + 5], pc[y + 6]
      local out = cur.pu
      local k = #out
      out[k + 1], out[k + 2], out[k + 3] = pu, m + 1, m + 3
      size = size + 3
    end
  end
  local est = #dl + #of + #lm + #sl + #qu + #ew + #sh + #sx + #pc + ceil(#pc / 7) * 3
  local use_near = near_spool and sc and est > most
  local near_u, near_k
  if use_near then
    local near_r = tonumber(walk_near) or 96
    local near_cache = {}
    near_u = function(u)
      local v = near_cache[u]
      if v == nil then
        v = is_near_unit(b, sc, near_r, u)
        near_cache[u] = v
      end
      return v
    end
    near_k = function(k)
      local v = tonumber(k)
      return near_u(v and floor((v - 1) / LANE_KEYS) or 0)
    end
  end
  local function emit_band(want, dl_list, sh_list, sx_list)
    local filter = want ~= nil
    for x = 1, #dl_list, 64 do
      add("dl", dl_list, x, math.min(#dl_list, x + 63))
    end
    for x = 1, #of, 2 do
      if not filter or near_u(tonumber(of[x]) or 0) == want then
        add("of", of, x, x + 1)
      end
    end
    -- Each lane's meta goes in the part with (or before) its items: metas first, by key.
    for x = 1, #lm, 12 do
      if not filter or near_k(lm[x]) == want then
        add("lm", lm, x, x + 11)
      end
    end
    local x = 1
    while x <= #sl do
      local n = sl[x + 2]
      if not filter or near_k(sl[x]) == want then
        add("sl", sl, x, x + 2 + n * 4)
      end
      x = x + 3 + n * 4
    end
    if not want then
      for y = 1, #qu, 2 do
        add("qu", qu, y, y + 1)
      end
    end
    for y = 1, #ew, 4 do
      if not filter or near_k(ew[y]) == want then
        add("ew", ew, y, y + 3)
      end
    end
    for y = 1, #sh_list, 64 do
      add("sh", sh_list, y, math.min(#sh_list, y + 63))
    end
    -- (sx: crossing hints, 7 numbers a record, a few records a range.)
    for y = 1, #sx_list, 56 do
      add("sx", sx_list, y, math.min(#sx_list, y + 55))
    end
    for y = 1, #pc, 7 do
      if not filter or near_k(pc[y]) == want then
        emit_pc(y)
      end
    end
  end
  if use_near then
    local dl_n, dl_o, sh_n, sh_o, sx_n, sx_o = {}, {}, {}, {}, {}, {}
    for x = 1, #dl do
      local t = near_k(dl[x]) and dl_n or dl_o
      t[#t + 1] = dl[x]
    end
    for y = 1, #sh do
      local t = near_k(sh[y]) and sh_n or sh_o
      t[#t + 1] = sh[y]
    end
    for y = 1, #sx - 6, 7 do
      local t = near_u(tonumber(sx[y]) or 0) and sx_n or sx_o
      local m = #t
      for k = 0, 6 do
        t[m + 1 + k] = sx[y + k]
      end
    end
    emit_band(true, dl_n, sh_n, sx_n)
    emit_band(false, dl_o, sh_o, sx_o)
  else
    emit_band(nil, dl, sh, sx)
  end
  profile.stop("bse.build", te)
  local head = ',"parts":' .. #parts .. ',"p":' .. period .. ',"w":' .. floor(work)
    .. ',"fx":' .. world.fixed(sc and sc.fx or 0) .. ',"fy":' .. world.fixed(sc and sc.fy or 0) .. ',"fr":' .. fr
    .. (loading and ',"ld":1' or "")
  local scalars = { #parts, period, floor(work), world.fixed(sc and sc.fx or 0), world.fixed(sc and sc.fy or 0), fr,
    loading and 1 or 0 }
  return parts, head, scalars
end

return M
