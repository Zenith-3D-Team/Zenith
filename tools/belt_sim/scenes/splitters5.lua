-- Which output is "left" and "right" (splitter_output_priority) for each direction: a turbo splitter
-- facing north, east, south and west with output priority right, both outputs free, one input lane fed.
if not s then
  s = game.create_surface("zenith-belt-rules", {width = 512, height = 512})
  s.generate_with_lab_tiles = true
  s.always_day = true
end
s.request_to_generate_chunks({0, 0}, 5)
s.force_generate_chunk_requests()
for _, e in pairs(s.find_entities_filtered({area = {{-60, -60}, {100, 120}}})) do e.destroy() end
local f = game.forces.player
local D = defines.direction
local function put(name, x, y, d, extra)
  local t = {name = name, position = {x, y}, direction = d, force = f}
  if extra then for k, v in pairs(extra) do t[k] = v end end
  return s.create_entity(t)
end
local feeds = {}
-- {direction, unit vector along the way items go, across (to the second belt)}
local rows = {{D.east, 1, 0, 0, 1, 0, 0}, {D.west, -1, 0, 0, 1, 40, 0}, {D.south, 0, 1, 1, 0, 0, 20}, {D.north, 0, -1, 1, 0, 40, 30}}
for _, r in ipairs(rows) do
  local d, vx, vy, ax, ay, ox, oy = r[1], r[2], r[3], r[4], r[5], r[6], r[7]
  local first
  for k = -6, 6 do
    if k ~= 0 then
      for w = 0, 1 do
        local b = put("turbo-transport-belt", ox + vx * k + ax * w + 0.5, oy + vy * k + ay * w + 0.5, d)
        if k == -6 and w == 0 then first = b end
      end
    end
  end
  local sp = put("turbo-splitter", ox + 0.5 + ax * 0.5, oy + 0.5 + ay * 0.5, d)
  sp.splitter_output_priority = "right"
  feeds[#feeds + 1] = first
end
feed = function(tick)
  for _, b in ipairs(feeds) do
    local l = b.get_transport_line(1)
    if tick % 20 == 0 and l.can_insert_at_back() then l.insert_at_back({name = "iron-plate", count = 1}) end
  end
end
