-- A turbo splitter with output priority right whose right output leads on to slower belts that are
-- blocked (as on Zenith Test), against one whose right output's own belts are blocked: does the item
-- fall back to the left output at once? (tools/belt_rules.py's lab surface, made here if missing.)
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
local function put(name, x, y)
  return s.create_entity({name = name, position = {x, y}, direction = E, force = f})
end
local function run(name, x0, x1, y)
  local l = {}
  for x = x0, x1 do l[#l + 1] = put(name, x + 0.5, y + 0.5) end
  return l
end
local feeds, takes = {}, {}
-- {the right output's belt, its length, lane 2's feed interval}
local rows = {{"transport-belt", 3, 23}, {"turbo-transport-belt", 3, 23}, {"transport-belt", 1, 23}, {"fast-transport-belt", 3, 19}}
for k, r in ipairs(rows) do
  local y = (k - 1) * 10
  local a = run("turbo-transport-belt", 0, 5, y)
  run("turbo-transport-belt", 0, 5, y + 1)
  s.create_entity({name = "turbo-splitter", position = {6.5, y + 1}, direction = E, force = f}).splitter_output_priority = "right"
  local c = run("turbo-transport-belt", 7, 10, y)
  run(r[1], 7, 6 + r[2], y + 1)
  feeds[#feeds + 1] = {a[1], r[3]}
  takes[#takes + 1] = c[#c]
end
feed = function(tick)
  for _, fd in ipairs(feeds) do
    local l = fd[1].get_transport_line(2)
    if tick % fd[2] == 0 and l.can_insert_at_back() then l.insert_at_back({name = "iron-plate", count = 1}) end
  end
  for _, b in ipairs(takes) do
    for i = 1, 2 do
      local l = b.get_transport_line(i)
      for _, it in ipairs(l.get_detailed_contents()) do
        if it.position < 0.02 then l.remove_item({name = it.stack.name, count = 1}) break end
      end
    end
  end
end
