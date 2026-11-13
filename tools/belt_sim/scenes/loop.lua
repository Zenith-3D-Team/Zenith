-- A closed loop of yellow belts, full on its inner lane with two kinds of item in turn, fed by an
-- inserter from a chest (the owner's loop: it must circulate as an unbroken ring). Built on the
-- surface `s` on empty ground near LOOP_AT (set before running; default -62,-26), the first place
-- within 60 tiles where a W x H rectangle is free, with W, H as set (default 14 x 9). Prints where.
-- Run over RCON (tools/belt_view_check.py --build, or by hand) before the client joins.
local ax, ay = LOOP_AT and LOOP_AT[1] or -62, LOOP_AT and LOOP_AT[2] or -26
local W, H = LOOP_W or 14, LOOP_H or 9
local f = game.forces.player
local D = defines.direction
local function free(x0, y0)
  -- (Two tiles round the loop too: the chest and inserter, and nothing drawn against it.)
  local area = {{x0 - 2, y0 - 2}, {x0 + W + 3, y0 + H + 4}}
  if s.count_entities_filtered({area = area}) > 0 then return false end
  for x = x0 - 2, x0 + W + 2 do
    for y = y0 - 2, y0 + H + 3 do
      if not s.can_place_entity({name = "transport-belt", position = {x + 0.5, y + 0.5}, force = f}) then return false end
    end
  end
  return true
end
local ox, oy
for r = 0, 60 do
  for dx = -r, r do
    for _, dy in ipairs({-r, r}) do
      if not ox and free(math.floor(ax + dx), math.floor(ay + dy)) then ox, oy = math.floor(ax + dx), math.floor(ay + dy) end
    end
  end
  for dy = -r + 1, r - 1 do
    for _, dx in ipairs({-r, r}) do
      if not ox and free(math.floor(ax + dx), math.floor(ay + dy)) then ox, oy = math.floor(ax + dx), math.floor(ay + dy) end
    end
  end
  if ox then break end
end
if not ox then rcon.print("loop: no free ground near " .. ax .. "," .. ay) return end
-- Clockwise: east along the top, south down the right, west along the bottom, north up the left.
local belts = {}
local function put(x, y, d)
  local e = s.create_entity({name = "transport-belt", position = {x + 0.5, y + 0.5}, direction = d, force = f})
  belts[#belts + 1] = e
  return e
end
for x = ox, ox + W - 1 do put(x, oy, D.east) end
for y = oy, oy + H - 1 do put(ox + W - 1, y, D.south) end
for x = ox + W - 1, ox, -1 do put(x, oy + H - 1, D.west) end
for y = oy + H - 1, oy, -1 do put(ox, y, D.north) end
-- The inner lane (the right lane, going clockwise) full: two kinds in turn on every straight belt;
-- the curves fill from the chest as the loop runs.
local kinds = {"iron-gear-wheel", "copper-cable"}
local n = 0
local function corner(e)
  local x, y = math.floor(e.position.x), math.floor(e.position.y)
  return (x == ox or x == ox + W - 1) and (y == oy or y == oy + H - 1)
end
-- (A loop with no gap but its corners' inner lanes doesn't move in Factorio: one straight belt is left
-- empty, so the loop circulates with a gap going round, as the owner's does.)
local empty = belts[3]
for _, e in ipairs(belts) do
  -- (belt_shape isn't settled until a tick has passed: the corners are told by their place.)
  if e.valid and not corner(e) and e ~= empty then
    local l = e.get_transport_line(2)
    for q = 0, 3 do
      n = n + 1
      l.insert_at(q * 0.25 + 0.125, {name = kinds[n % 2 + 1], count = 1})
    end
  end
end
-- A chest of both kinds and an inserter dropping onto the top row's first belt.
local ch = s.create_entity({name = "iron-chest", position = {ox + 1.5, oy - 1.5}, force = f})
ch.insert({name = "iron-gear-wheel", count = 200})
ch.insert({name = "copper-cable", count = 200})
s.create_entity({name = "inserter", position = {ox + 1.5, oy - 0.5}, direction = D.north, force = f})
-- Beside it, a backed-up line: a row of belts packed with copper plates on both lanes, whose front an
-- inserter empties into a chest an item at a time, so the whole row stops and starts every few ticks
-- (a line must move in unison: no gap opens between its items); an inserter at its back keeps it full.
local ry = oy + H + 2
local row = {}
for x = ox, ox + W - 1 do
  local e = s.create_entity({name = "transport-belt", position = {x + 0.5, ry + 0.5}, direction = D.east, force = f})
  row[#row + 1] = e
  for li = 1, 2 do
    local l = e.get_transport_line(li)
    for q = 0, 3 do l.insert_at(q * 0.25 + 0.125, {name = "copper-plate", count = 1}) end
  end
end
local take = s.create_entity({name = "iron-chest", position = {ox + W + 1.5, ry + 0.5}, force = f})
s.create_entity({name = "inserter", position = {ox + W + 0.5, ry + 0.5}, direction = D.west, force = f})
local src = s.create_entity({name = "iron-chest", position = {ox - 0.5, ry + 2.5}, force = f})
src.insert({name = "copper-plate", count = 1000})
s.create_entity({name = "fast-inserter", position = {ox - 0.5, ry + 1.5}, direction = D.south, force = f})
s.create_entity({name = "transport-belt", position = {ox - 0.5, ry + 0.5}, direction = D.east, force = f})
-- Power for the inserters: an electric energy interface and medium poles chained round the scene.
local eei = s.create_entity({name = "electric-energy-interface", position = {ox + W + 1, oy + 2}, force = f})
-- (Medium poles reach 9 tiles: each hop is under that.)
local poles = 0
for _, p in ipairs({{ox + 3.5, oy - 1.5}, {ox + 8.5, oy - 1.5}, {ox + W + 1.5, oy - 0.5}, {ox - 1.5, oy + 4.5}, {ox - 1.5, ry + 1.5},
    {ox + 6.5, ry + 2.5}, {ox + W + 0.5, ry + 2.5}}) do
  if s.create_entity({name = "medium-electric-pole", position = p, force = f}) then poles = poles + 1 end
end
rcon.print(string.format("loop: %d belts at %d,%d to %d,%d, %d items on the inner lane; row at y %d; power %s, %d poles",
  #belts, ox, oy, ox + W, oy + H, n, ry, eei and "yes" or "NO", poles))
