-- Loaders and lane splitters on tools/belt_rules.py's lab surface (made here if missing): a belt into a
-- loader loading a chest, a chest unloaded by a loader onto a belt, the same with 1x1 loaders, and a
-- turbo lane splitter fed on one lane and on both.
if not s then
  s = game.create_surface("zenith-belt-rules", {width = 512, height = 512})
  s.generate_with_lab_tiles = true
  s.always_day = true
end
s.request_to_generate_chunks({0, 0}, 5)
s.force_generate_chunk_requests()
for _, e in pairs(s.find_entities_filtered({area = {{-60, -60}, {100, 120}}})) do e.destroy() end
local f = game.forces.player
local E = defines.direction.east
local W = defines.direction.west
local function put(name, x, y, d, extra)
  local t = {name = name, position = {x, y}, direction = d or E, force = f}
  if extra then for k, v in pairs(extra) do t[k] = v end end
  return s.create_entity(t)
end
local function run(name, x0, x1, y)
  local l = {}
  for x = x0, x1 do l[#l + 1] = put(name, x + 0.5, y + 0.5) end
  return l
end
local feeds, takes = {}, {}
-- 1: belt -> loader (input) -> chest
local a = run("transport-belt", 0, 5, 0)
put("loader", 7, 0.5, E, {type = "input"})
put("iron-chest", 8.5, 0.5)
feeds[#feeds + 1] = {a[1], 1, 1} feeds[#feeds + 1] = {a[1], 2, 3}
-- 2: chest -> loader (output) -> belt
local ch = put("iron-chest", 0.5, 4.5)
ch.insert({name = "copper-plate", count = 1000})
put("loader", 2, 4.5, E, {type = "output"})
local b = run("transport-belt", 3, 9, 4)
takes[#takes + 1] = {b[#b], 1}
-- 3: 1x1 loaders, turbo
local c = run("turbo-transport-belt", 0, 5, 8)
put("loader-1x1", 6.5, 8.5, E, {type = "input"})
put("iron-chest", 7.5, 8.5)
feeds[#feeds + 1] = {c[1], 1, 2}
local ch2 = put("iron-chest", 0.5, 12.5)
ch2.insert({name = "iron-plate", count = 1000})
put("loader-1x1", 1.5, 12.5, E, {type = "output"})
local d = run("turbo-transport-belt", 2, 9, 12)
takes[#takes + 1] = {d[#d], 3}
-- 4: lane splitter (turbo), both lanes fed / one lane fed
for k, both in ipairs({true, false}) do
  local y = 16 + (k - 1) * 4
  local e = run("turbo-transport-belt", 0, 5, y)
  put("lane-splitter", 6.5, y + 0.5)
  local o = run("turbo-transport-belt", 7, 12, y)
  feeds[#feeds + 1] = {e[1], 1, 1}
  if both then feeds[#feeds + 1] = {e[1], 2, 1} end
  takes[#takes + 1] = {o[#o], 1}
end
feed = function(tick)
  for _, fd in ipairs(feeds) do
    local l = fd[1].get_transport_line(fd[2])
    if tick % fd[3] == 0 and l.can_insert_at_back() then l.insert_at_back({name = "iron-plate", count = 1}) end
  end
  for _, tk in ipairs(takes) do
    if tick % tk[2] == 0 then
      for i = 1, 2 do
        local l = tk[1].get_transport_line(i)
        for _, it in ipairs(l.get_detailed_contents()) do
          if it.position < 0.02 then l.remove_item({name = it.stack.name, count = 1}) break end
        end
      end
    end
  end
end
