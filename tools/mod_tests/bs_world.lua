-- A recorded world for tools/bs_offline.py: belts whose transport lines hold, each tick, the items a
-- recording of the game (tools/belt_sim/record.py) has there, and the inserters and mining drills
-- round them (tools/belt_sim/record_world.py) whose hands and progress change as recorded. Loaded
-- after fake_factorio.lua and before the mod's control.lua: the entities are the fake's own (F.spawn),
-- with their unit numbers, names, speeds, neighbours and lines set to the recording's.
--
-- Lines: line_length, get_line_item_position (through the recorded line positions 0, half way and
-- the end: exact at those three, a parabola between, which is right for straight lines and close for
-- curves), get_detailed_contents, get_item_position, get_item_count, #line and line[k], from the row
-- of the recording for the current tick (H.set_row). Items keep the recording's unique ids, positions
-- and stack sizes; their quality is normal and their spoilage 0 (record.py doesn't record those).

H = { lanes = {}, lanekey = {}, names = {}, cur = {}, cache = {}, by_unit = {}, actors = {}, belts = {}, cb = {} }

-- The fake entity's own fields (make_entity's upvalue `data`): what the mod reads.
local function data_of(e)
  local idx = getmetatable(e).__index
  for i = 1, 80 do
    local n, v = debug.getupvalue(idx, i)
    if not n then
      break
    end
    if n == "data" then
      return v
    end
  end
  error("bs_world: no data upvalue")
end
H.data_of = data_of

-- A prototype named `name` of `base`'s kind (an inserter, a drill: the fake has few names).
local function scaled_box(w, h, m)
  return { left_top = { x = -w / 2 + m, y = -h / 2 + m }, right_bottom = { x = w / 2 - m, y = h / 2 - m } }
end
function H.add_proto(name, base, typ, w, h)
  local protos = prototypes.entity
  if rawget(protos, name) then
    return
  end
  local b = protos[base]
  local p = {}
  for k, v in pairs(b) do
    p[k] = v
  end
  p.name, p.type = name, typ or b.type
  if w then
    p.selection_box, p.collision_box = scaled_box(w, h, 0), scaled_box(w, h, 0.1)
    p.tile_width, p.tile_height = math.ceil(w), math.ceil(h)
  end
  setmetatable(p, getmetatable(b))
  rawset(protos, name, p)
end

local function fx(v)
  return v / 256
end

-- Through three points at 0, len / 2 and len.
local function along(m, q)
  local len = m[1] / 256
  local p0, pm, p1 = m[2], m[3], m[4]
  if len <= 0 then
    return { x = fx(p0[1]), y = fx(p0[2]) }
  end
  local t = q / len
  local a, b, c = 2 * (t - 0.5) * (t - 1), -4 * t * (t - 1), 2 * t * (t - 0.5)
  return { x = fx(a * p0[1] + b * pm[1] + c * p1[1]), y = fx(a * p0[2] + b * pm[2] + c * p1[2]) }
end

local STACK_MT = { __index = function(_, k) error("LuaItemStack (bs_world) doesn't contain key " .. tostring(k), 2) end }
local function stack(name, count)
  return setmetatable({ valid_for_read = true, name = name, count = count, quality = { name = "normal" }, spoil_percent = 0,
    type = "item", health = 1 }, STACK_MT)
end

-- The items now on lane `key`: {uid, pos (1/256), count, name id, ...} as the row lists them.
local function items_of(key)
  return H.cur[key] or {}
end

-- Contents front first (lowest position first), cached for the tick.
local function sorted_of(key)
  local c = H.cache[key]
  if c then
    return c
  end
  local raw = items_of(key)
  c = {}
  for i = 1, #raw, 4 do
    c[#c + 1] = { raw[i], raw[i + 1], raw[i + 2], raw[i + 3] }
  end
  table.sort(c, function(a, b) return a[2] < b[2] end)
  H.cache[key] = c
  return c
end

function H.make_line(e, key, m)
  local line = { valid = true, owner = e, line_length = m[1] / 256 }
  line.get_line_item_position = function(q)
    return along(m, q)
  end
  line.get_detailed_contents = function()
    local out = {}
    for _, it in ipairs(sorted_of(key)) do
      out[#out + 1] = { stack = stack(H.names[it[4]] or "iron-plate", it[3]), position = it[2] / 256, unique_id = it[1] }
    end
    return out
  end
  line.get_item_position = function(k)
    local it = assert(sorted_of(key)[k], "get_item_position: no item " .. tostring(k))
    return it[2] / 256
  end
  line.get_item_count = function()
    local n = 0
    for _, it in ipairs(sorted_of(key)) do
      n = n + it[3]
    end
    return n
  end
  return setmetatable(line, {
    __len = function() return #sorted_of(key) end,
    __index = function(_, k)
      if type(k) == "number" then
        local it = assert(sorted_of(key)[k], "line[k]: no item " .. tostring(k))
        return stack(H.names[it[4]] or "iron-plate", it[3])
      end
      error("LuaTransportLine (bs_world) doesn't contain key " .. tostring(k), 2)
    end,
  })
end

local BASE = { ["transport-belt"] = "transport-belt", ["underground-belt"] = "underground-belt", splitter = "splitter",
  ["lane-splitter"] = "lane-splitter", ["linked-belt"] = "linked-belt" }
local CONTROL = setmetatable({ valid = true }, { __index = function(_, k) return nil end })

-- A belt: w = {u, n, t, sh, p = {x, y} in 1/256, d, v (speed in 1/256 a tick), st, cb, sp, lines = {{len, p0, pm, p1}, ...}}.
function H.add_belt(w)
  local base = BASE[w.t]
  assert(base, "bs_world: no belt kind " .. tostring(w.t))
  local extra = { force = "player", direction = w.d }
  if w.t == "underground-belt" then
    extra.type = w.sh
  end
  local e = F.spawn(base, w.p[1] / 256, w.p[2] / 256, extra)
  local d = data_of(e)
  local proto = d.prototype
  d.unit_number, d.name, d.direction = w.u, w.n, w.d
  d.prototype = setmetatable({ name = w.n, belt_speed = w.v / 256 }, { __index = proto })
  if w.t == "transport-belt" then
    d.belt_shape = w.sh ~= "" and w.sh or "straight"
  elseif w.t == "underground-belt" then
    d.belt_to_ground_type = w.sh
  end
  local lines = {}
  for i, m in ipairs(w.lines) do
    lines[i] = H.make_line(e, w.u * 8 + i, m)
  end
  d.get_max_transport_line_index = function() return #lines end
  d.get_transport_line = function(i) return assert(lines[i], "get_transport_line: no line " .. tostring(i)) end
  d.status = w.st ~= 0 and w.st or defines.entity_status.working
  if w.cb == 1 then
    d.get_control_behavior = function() return CONTROL end
  end
  if w.t == "splitter" or w.t == "lane-splitter" then
    local sp = w.sp or {}
    d.splitter_input_priority = sp[1] or "none"
    d.splitter_output_priority = sp[2] or "none"
    d.splitter_filter = (sp[3] and sp[3] ~= "") and { name = sp[3] } or nil
  end
  H.by_unit[w.u] = e
  H.belts[#H.belts + 1] = { e, w }
  return e
end

-- After every belt: neighbours by unit number (outside the recorded world: left out).
function H.link_belts()
  for _, be in ipairs(H.belts) do
    local e, w = be[1], be[2]
    local d = data_of(e)
    local ins, outs = {}, {}
    for _, u in ipairs(w.i or {}) do
      if H.by_unit[u] then ins[#ins + 1] = H.by_unit[u] end
    end
    for _, u in ipairs(w.o or {}) do
      if H.by_unit[u] then outs[#outs + 1] = H.by_unit[u] end
    end
    d.belt_neighbours = { inputs = ins, outputs = outs }
    if w.t == "underground-belt" then
      d.underground_belt_neighbour = H.by_unit[w.un or 0]
    end
  end
end

-- Something an inserter or drill uses that isn't a belt: a chest standing in at its place.
function H.add_target(u, x, y)
  if H.by_unit[u] then
    return H.by_unit[u]
  end
  local e = F.spawn("wooden-chest", x / 256, y / 256, { force = "player" })
  data_of(e).unit_number = u
  H.by_unit[u] = e
  return e
end

-- An inserter or drill: a = {u, n, t, p, d, pk, dr}.
function H.add_actor(a)
  local base = a.t == "inserter" and "inserter" or "electric-mining-drill"
  local e = F.spawn(a.n, a.p[1] / 256, a.p[2] / 256, { force = "player", direction = a.d })
  local d = data_of(e)
  d.unit_number = a.u
  if a.t == "inserter" then
    d.pickup_target = H.by_unit[a.pk or 0]
    d.held_stack = setmetatable({ valid_for_read = false }, STACK_MT)
  else
    d.mining_progress, d.bonus_mining_progress = 0, 0
  end
  d.drop_target = H.by_unit[a.dr or 0]
  H.actors[#H.actors + 1] = e
  return e
end

-- An actor's recorded value: an inserter's held count, a drill's progress * 10000.
function H.set_actor(j, v)
  local e = H.actors[j]
  if not e then
    return
  end
  local d = data_of(e)
  if d.type == "inserter" then
    if v > 0 then
      d.held_stack = stack("iron-plate", v)
    else
      d.held_stack = setmetatable({ valid_for_read = false }, STACK_MT)
    end
  else
    d.mining_progress, d.bonus_mining_progress = v / 10000, 0
  end
end

function H.set_actors(row)
  for i = 2, #row, 2 do
    H.set_actor(row[i], row[i + 1])
  end
end

-- A circuit-connected belt's recorded status (belt index into the world's list).
function H.set_status(row)
  for i = 2, #row, 2 do
    local be = H.belts[row[i]]
    if be then
      data_of(be[1]).status = row[i + 1]
    end
  end
end

-- The recording's lanes (j -> key) and item names (id -> name).
function H.set_lanes(keys, names)
  H.lanekey = keys
  H.names = names
end

-- The recording's row for this tick: {tick, j, uid, pos, count, name id, ...}.
function H.set_row(row)
  local cur = {}
  local lk = H.lanekey
  for i = 2, #row, 5 do
    local key = lk[row[i]]
    if key then
      local l = cur[key]
      if not l then
        l = {}
        cur[key] = l
      end
      local n = #l
      l[n + 1], l[n + 2], l[n + 3], l[n + 4] = row[i + 1], row[i + 2], row[i + 3], row[i + 4]
    end
  end
  H.cur = cur
  H.cache = {}
end

-- Belts outside the recording (H.hide): they stay valid entities, the neighbours of the belts that
-- lead into them, but no search finds them, so the bridge never loads them: what leads into them leads
-- out of what it sends, as at the edge of a live square (their items aren't recorded).
function H.hide(units)
  H.hidden = H.hidden or {}
  for _, u in ipairs(units) do
    local e = H.by_unit[u]
    if e then
      H.hidden[e] = true
    end
  end
end

-- The fake's find_entities_filtered goes through every entity on the surface; a recorded world has
-- thousands, searched by chunk every scan: an index by chunk, for area searches of entities that
-- don't move (the recorded ones), the rest searched the fake's way.
function H.index_surface(surface)
  local plain = surface.find_entities_filtered
  local grid, others = {}, {}
  local static = {}
  local hidden = H.hidden or {}
  for _, be in ipairs(H.belts) do
    static[be[1]] = true
  end
  for _, e in ipairs(H.actors) do
    static[e] = true
  end
  for _, e in pairs(H.by_unit) do
    static[e] = true
  end
  for e in pairs(static) do
    if hidden[e] then
      goto continue
    end
    local p = e.position
    local key = math.floor(p.x / 32) * 65536 + math.floor(p.y / 32)
    grid[key] = grid[key] or {}
    table.insert(grid[key], e)
    ::continue::
  end
  local function has(list, v)
    if type(list) == "string" then
      return list == v
    end
    for _, x in pairs(list) do
      if x == v then
        return true
      end
    end
    return false
  end
  local dyn = {}
  for _, e in ipairs(surface.entities) do
    if not static[e] then
      dyn[#dyn + 1] = e
    end
  end
  surface.entities = dyn
  local static_list = {}
  for e in pairs(static) do
    if not hidden[e] then
      static_list[#static_list + 1] = e
    end
  end
  surface.find_entities_filtered = function(f)
    if not (f.area and f.type and not f.name and not f.invert and not f.position and not f.force and not f.ghost_name) then
      -- (Any other search: the fake's own, over everything.)
      local now = surface.entities
      local all = {}
      for _, e in ipairs(static_list) do
        all[#all + 1] = e
      end
      for _, e in ipairs(now) do
        all[#all + 1] = e
      end
      surface.entities = all
      local ok, r = pcall(plain, f)
      surface.entities = now
      if not ok then
        error(r, 2)
      end
      return r
    end
    local out = plain(f)
    local a1, a2 = f.area[1] or f.area.left_top, f.area[2] or f.area.right_bottom
    local ax1, ay1 = a1.x or a1[1], a1.y or a1[2]
    local ax2, ay2 = a2.x or a2[1], a2.y or a2[2]
    for cx = math.floor((ax1 - 4) / 32), math.floor((ax2 + 4) / 32) do
      for cy = math.floor((ay1 - 4) / 32), math.floor((ay2 + 4) / 32) do
        for _, e in ipairs(grid[cx * 65536 + cy] or {}) do
          if e.valid and has(f.type, e.type) then
            local b, p = e.prototype.collision_box, e.position
            if p.x + b.left_top.x < ax2 and p.x + b.right_bottom.x > ax1 and p.y + b.left_top.y < ay2 and p.y + b.right_bottom.y > ay1 then
              out[#out + 1] = e
            end
          end
        end
      end
    end
    return out
  end
end
