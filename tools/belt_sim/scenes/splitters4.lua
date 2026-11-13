-- When does an item fall back from a full priority output? (tools/belt_rules.py's lab surface, made
-- here if missing.) Turbo splitters with output priority right, that output never emptied (2 belts, so
-- it fills at once); single items put on the input belt's left lane every 40 ticks at a different
-- place in each row, so the item behind the waiting one comes up at every phase of a 32-step tick.
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
    r.feeds[#r.feeds + 1] = {fd[1] == 1 and a[1] or b[1], fd[2], fd[3], fd[4] or 1, 0, fd[5]}
  end
  r.takes[#r.takes + 1] = {c[#c], opts.take_c or function() return true end}
  r.takes[#r.takes + 1] = {d[#d], opts.take_d or function() return true end}
  rows[#rows + 1] = r
  return sp
end
local never = function() return false end
for k = 0, 7 do
  row(k * 10, {belt = "turbo-transport-belt", splitter = "turbo-splitter", out_prio = "right", take_d = never, out_len = 1,
    feeds = {{1, 1, {"iron-plate"}, 40, 252 - 4 * k}}})
end
feed = function(tick)
  local t = tick - T0
  for _, r in ipairs(rows) do
    for _, fd in ipairs(r.feeds) do
      if t % fd[4] == 0 then
        local l = fd[1].get_transport_line(fd[2])
        fd[5] = fd[5] + 1
        local stack = {name = fd[3][(fd[5] - 1) % #fd[3] + 1], count = 1}
        if fd[6] then
          if l.can_insert_at(fd[6] / 256) then l.insert_at(fd[6] / 256, stack) end
        elseif l.can_insert_at_back() then
          l.insert_at_back(stack)
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
