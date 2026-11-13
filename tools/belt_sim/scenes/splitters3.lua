-- Splitters with an output priority whose priority output is full (tools/belt_rules.py's lab surface,
-- made here if missing): items arriving one at a time at different phases, on each tier.
-- An input belt is fed at its back whenever its lane has room; an output belt's front item is taken
-- off at the run's end when the row's rule says so (else the output backs up).
if not s then
  s = game.create_surface("zenith-belt-rules", {width = 512, height = 512})
  s.generate_with_lab_tiles = true
  s.always_day = true
end
s.request_to_generate_chunks({0, 0}, 5)
s.force_generate_chunk_requests()
for _, e in pairs(s.find_entities_filtered({area = {{-60, -60}, {100, 120}}})) do e.destroy() end
local E = defines.direction.east
local f = game.forces.player
local T0 = game.tick
local function put(name, x, y, extra)
  local t = {name = name, position = {x, y}, direction = E, force = f}
  if extra then for k, v in pairs(extra) do t[k] = v end end
  return s.create_entity(t)
end
local function run(name, x0, x1, y)
  local l = {}
  for x = x0, x1 do l[#l + 1] = put(name, x + 0.5, y + 0.5) end
  return l
end
-- rows[k] = {feeds = {{belt, lane, items, every}}, takes = {{belt, rule(t)}}}; t counts from the build.
local rows = {}
local function row(y, opts)
  local belt = opts.belt or "transport-belt"
  local sp_name = opts.splitter or "splitter"
  local a, b = run(opts.in_belt or belt, 0, 5, y), run(opts.in_belt or belt, 0, 5, y + 1)
  local sp = put(sp_name, 6.5, y + 1)
  if opts.out_prio then sp.splitter_output_priority = opts.out_prio end
  if opts.in_prio then sp.splitter_input_priority = opts.in_prio end
  if opts.filter then sp.splitter_filter = {name = opts.filter} end
  local c, d = run(opts.out_belt or belt, 7, 7 + (opts.out_len or 7), y), run(opts.out_belt or belt, 7, 7 + (opts.out_len or 7), y + 1)
  local r = {feeds = {}, takes = {}}
  for _, fd in ipairs(opts.feeds) do
    -- {input 1 (north) or 2 (south), lane, items (cycled), every n ticks (1)}
    r.feeds[#r.feeds + 1] = {fd[1] == 1 and a[1] or b[1], fd[2], fd[3], fd[4] or 1, 0}
  end
  r.takes[#r.takes + 1] = {c[#c], opts.take_c or function() return true end}
  r.takes[#r.takes + 1] = {d[#d], opts.take_d or function() return true end}
  rows[#rows + 1] = r
  return sp
end
local IRON, COPPER = {"iron-plate"}, {"copper-plate"}
local never = function() return false end
-- Output priority right (the south belt: right of east), that output never emptied: everything falls
-- back to the north output. Single items, fed every 40, 23, 31 ticks.
row(0, {out_prio = "right", take_d = never, feeds = {{1, 1, IRON, 40}, {1, 2, COPPER, 23}}})
row(10, {belt = "turbo-transport-belt", splitter = "turbo-splitter", out_prio = "right", take_d = never,
  feeds = {{1, 1, IRON, 40}, {1, 2, COPPER, 23}}})
row(20, {belt = "express-transport-belt", splitter = "express-splitter", out_prio = "right", take_d = never,
  feeds = {{1, 1, IRON, 31}, {2, 2, COPPER, 17}}})
-- No priority, the south output never emptied (a control).
row(30, {belt = "turbo-transport-belt", splitter = "turbo-splitter", take_d = never,
  feeds = {{1, 1, IRON, 40}, {1, 2, COPPER, 23}}})
-- Output priority left, the north output never emptied.
row(40, {belt = "turbo-transport-belt", splitter = "turbo-splitter", out_prio = "left", take_c = never,
  feeds = {{2, 1, IRON, 37}, {1, 2, COPPER, 29}}})
-- Output priority right, both outputs free.
row(50, {belt = "turbo-transport-belt", splitter = "turbo-splitter", out_prio = "right",
  feeds = {{1, 1, IRON, 40}, {1, 2, COPPER, 23}}})
-- Output priority right, its output emptied every 50 ticks.
row(60, {belt = "turbo-transport-belt", splitter = "turbo-splitter", out_prio = "right", take_d = function(t) return t % 50 == 0 end,
  feeds = {{1, 1, IRON, 13}, {2, 2, COPPER, 11}}})
-- A filter (iron to the right), the right output never emptied: iron waits, copper goes left.
row(70, {belt = "turbo-transport-belt", splitter = "turbo-splitter", out_prio = "right", filter = "iron-plate", take_d = never,
  feeds = {{1, 1, {"iron-plate", "copper-plate", "copper-plate"}, 19}}})
feed = function(tick)
  local t = tick - T0
  for _, r in ipairs(rows) do
    for _, fd in ipairs(r.feeds) do
      if t % fd[4] == 0 then
        local l = fd[1].get_transport_line(fd[2])
        if l.can_insert_at_back() then
          fd[5] = fd[5] + 1
          l.insert_at_back({name = fd[3][(fd[5] - 1) % #fd[3] + 1], count = 1})
        end
      end
    end
    for _, tk in ipairs(r.takes) do
      if tk[2](t) then
        for i = 1, 2 do
          local l = tk[1].get_transport_line(i)
          for _, it in ipairs(l.get_detailed_contents()) do
            if it.position < 0.02 then l.remove_item({name = it.stack.name, count = 1}) break end
          end
        end
      end
    end
  end
end
