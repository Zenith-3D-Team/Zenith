-- Splitters on the belt rules' lab surface (tools/belt_rules.py makes it): a yellow splitter fed on
-- both input belts, both lanes, every tick; one output belt free, the other blocked every other
-- 200 ticks; then a splitter feeding another (a chain), and one with an output priority. Every
-- run's front item is taken off where it ends, unless blocked.
for _, e in pairs(s.find_entities_filtered({area = {{-60, -60}, {60, 60}}})) do e.destroy() end
local E = defines.direction.east
local f = game.forces.player
local function put(name, x, y, extra)
  local t = {name = name, position = {x, y}, direction = E, force = f}
  if extra then for k, v in pairs(extra) do t[k] = v end end
  return s.create_entity(t)
end
local function run(x0, x1, y)
  local l = {}
  for x = x0, x1 do l[#l + 1] = put("transport-belt", x + 0.5, y + 0.5) end
  return l
end
local backs, fronts, blocked = {}, {}, {}
-- 1: a splitter at x=6, its belts at y=0 and y=1.
local a1, b1 = run(0, 5, 0), run(0, 5, 1)
put("splitter", 6.5, 1)
local c1, d1 = run(7, 14, 0), run(7, 14, 1)
backs[#backs + 1] = a1[1] backs[#backs + 1] = b1[1]
fronts[#fronts + 1] = c1[#c1] fronts[#fronts + 1] = {d1[#d1], 200}
-- 2: a chain: a splitter at x=6 feeding another at x=10 (y=10/11).
local a2, b2 = run(0, 5, 10), run(0, 5, 11)
put("splitter", 6.5, 11)
run(7, 9, 10) run(7, 9, 11)
put("splitter", 10.5, 11)
local c2, d2 = run(11, 18, 10), run(11, 18, 11)
backs[#backs + 1] = a2[1] backs[#backs + 1] = b2[1]
fronts[#fronts + 1] = c2[#c2] fronts[#fronts + 1] = {d2[#d2], 300}
-- 3: one input, output priority left.
local a3 = run(0, 5, 20)
run(0, 5, 21)
local sp3 = put("splitter", 6.5, 21)
sp3.splitter_output_priority = "left"
local c3, d3 = run(7, 14, 20), run(7, 14, 21)
backs[#backs + 1] = a3[1]
fronts[#fronts + 1] = {c3[#c3], 250} fronts[#fronts + 1] = d3[#d3]
local plates = {"iron-plate", "copper-plate"}
feed = function(t)
  for k, b in ipairs(backs) do
    for i = 1, 2 do
      local l = b.get_transport_line(i)
      if l.can_insert_at_back() then l.insert_at_back({name = plates[i], count = 1}) end
    end
  end
  for _, fr in ipairs(fronts) do
    local b, period = fr, nil
    if type(fr) == "table" and fr[2] then b, period = fr[1], fr[2] end
    if not period or math.floor(t / period) % 2 == 0 then
      for i = 1, 2 do
        local l = b.get_transport_line(i)
        for _, it in ipairs(l.get_detailed_contents()) do
          if it.position < 0.02 then l.remove_item({name = it.stack.name, count = 1}) break end
        end
      end
    end
  end
end
