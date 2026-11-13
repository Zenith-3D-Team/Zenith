-- Splitter rules on the belt rules' lab surface (tools/belt_rules.py makes it; made here if missing):
-- nine splitters, one per row of 10 tiles, each fed and emptied its own way (see each row's comment).
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
local IRON, COPPER, GEAR = {"iron-plate"}, {"copper-plate"}, {"iron-gear-wheel"}
local MIX = {"iron-plate", "copper-plate", "copper-plate", "iron-plate", "iron-plate", "iron-plate", "copper-plate"}
-- A: one input lane (north belt, left lane); south output blocked in windows of 150 (then 110) ticks:
-- the turn across a blocked output.
row(0, {feeds = {{1, 1, IRON}}, take_d = function(t) return (t % 300) < 150 end})
row(10, {feeds = {{1, 1, IRON}, {1, 2, COPPER}}, take_d = function(t) return (t % 230) < 120 end})
-- B: the left side fed from both inputs, the right side from the north input only; outputs taken
-- every 16 ticks: is the input turn per side?
row(20, {feeds = {{1, 1, IRON}, {2, 1, COPPER}, {1, 2, GEAR}}, take_c = function(t) return t % 16 == 0 end,
  take_d = function(t) return t % 16 == 8 end})
-- C, D: input priority left / right, all four input lanes fed, outputs taken every 12 ticks.
row(30, {in_prio = "left", feeds = {{1, 1, IRON}, {1, 2, IRON}, {2, 1, COPPER}, {2, 2, COPPER}},
  take_c = function(t) return t % 12 == 0 end, take_d = function(t) return t % 12 == 0 end})
row(40, {in_prio = "right", feeds = {{1, 1, IRON}, {1, 2, IRON}, {2, 1, COPPER}, {2, 2, COPPER}},
  take_c = function(t) return t % 12 == 0 end, take_d = function(t) return t % 12 == 0 end})
-- E: filter iron to the left (north) output, mixed input; the north output blocked in windows, then
-- the south one.
row(50, {filter = "iron-plate", out_prio = "left", feeds = {{1, 1, MIX}, {1, 2, MIX}, {2, 1, COPPER}},
  take_c = function(t) return (t % 400) < 200 end, take_d = function(t) return (t % 400) < 100 or (t % 400) >= 300 end})
-- F: output priority right, one input; the right (south) output blocked in windows.
row(60, {out_prio = "right", feeds = {{1, 1, IRON}, {1, 2, COPPER}}, take_d = function(t) return (t % 260) < 130 end})
-- G: a turbo splitter fed unevenly (every 5 and 7 ticks), outputs free.
row(70, {belt = "turbo-transport-belt", splitter = "turbo-splitter", feeds = {{1, 1, IRON, 5}, {2, 1, COPPER, 7}, {2, 2, GEAR, 3}}})
-- H: turbo belts through a yellow splitter; the south output taken every 10 ticks.
row(80, {in_belt = "turbo-transport-belt", out_belt = "turbo-transport-belt", feeds = {{1, 1, IRON}, {2, 1, COPPER}, {1, 2, GEAR}},
  take_d = function(t) return t % 10 == 0 end})
-- I: a chain: a splitter's outputs (3 belts) into another splitter; one end taken every 9 ticks.
do
  local a, b = run("transport-belt", 0, 5, 90), run("transport-belt", 0, 5, 91)
  put("splitter", 6.5, 91)
  run("transport-belt", 7, 9, 90) run("transport-belt", 7, 9, 91)
  put("splitter", 10.5, 91)
  local c, d = run("transport-belt", 11, 18, 90), run("transport-belt", 11, 18, 91)
  rows[#rows + 1] = {feeds = {{a[1], 1, IRON, 1, 0}, {b[1], 1, COPPER, 1, 0}, {b[1], 2, GEAR, 2, 0}},
    takes = {{c[#c], function(t) return t % 9 == 0 end}, {d[#d], function() return true end}}}
end
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
