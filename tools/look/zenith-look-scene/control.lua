-- Builds a fixed scene beside the spawn (tick 30) and, in a Factorio window, saves Factorio's own
-- picture of it at noon (script-output/zenith-look/factorio.png) and through its dusk
-- (factorio-0.30.png...), and with Space Age on, of Gleba's bare ground at the same times
-- (gleba-0.00.png...). With the bridge (Zenith's server) the bridge's character is put in the
-- middle instead, where Zenith's camera looks.
local C = {x = 0.5, y = -24.5}
local RES = {1600, 900}
-- Noon first, then the dusk: 0.25 starts it and 0.45 ends it.
local DAYTIMES = {0, 0.30, 0.35, 0.40, 0.45}
-- Ticks for lamps and the like to catch up with a new time of day.
local SETTLE = 90

local function put(s, name, x, y, extra)
  local spec = {name = name, position = {C.x + x, C.y + y}, force = "player", raise_built = true}
  for k, v in pairs(extra or {}) do spec[k] = v end
  return s.create_entity(spec)
end

local function build()
  local s = game.surfaces[1]
  s.always_day = true
  local area = {{C.x - 13, C.y - 8}, {C.x + 13, C.y + 8}}
  for _, e in pairs(s.find_entities_filtered{area = area}) do
    if e.valid and e.type ~= "character" then e.destroy() end
  end
  s.destroy_decoratives{area = {{C.x - 12, C.y - 7}, {C.x + 12, C.y + 7}}}
  local D = defines.direction
  -- power from out of frame, so no machine shows Factorio's no-power icon
  put(s, "electric-energy-interface", 40, 0)
  for x = 4, 36, 8 do put(s, "medium-electric-pole", x, 4) end
  put(s, "medium-electric-pole", -4, 4)
  -- a row of machines
  local a1 = put(s, "assembling-machine-2", -8, -3) if a1 then a1.set_recipe("iron-gear-wheel") end
  local a2 = put(s, "assembling-machine-1", -4, -3) if a2 then a2.set_recipe("copper-cable") end
  put(s, "lab", 0, -3)
  put(s, "electric-mining-drill", 5, -3)
  local f1 = put(s, "stone-furnace", 9, -3.5)
  put(s, "steel-furnace", 9, -1)
  -- a belt with items in front of them
  for x = -10, 10 do
    local b = put(s, "transport-belt", x, 1, {direction = D.east})
    if b then
      for line = 1, 2 do b.get_transport_line(line).insert_at_back({name = (x % 2 == 0) and "iron-plate" or "copper-plate", count = 1}) end
    end
  end
  for _, x in pairs({-8, -4, 0}) do put(s, "inserter", x, -0.5 + 0.5, {direction = D.south}) end
  -- chests, pipes and a tank in the lower half
  put(s, "wooden-chest", -10, 4) put(s, "iron-chest", -9, 4) put(s, "steel-chest", -8, 4)
  for x = -5, 2 do put(s, "pipe", x, 5) end
  put(s, "storage-tank", 4.5, 5.5)
  put(s, "small-electric-pole", -6, 3)
  put(s, "stone-wall", 8, 5) put(s, "stone-wall", 9, 5) put(s, "stone-wall", 10, 5)
  local car = put(s, "car", -1, 3.5)
  put(s, "small-lamp", -3, 6.5)  -- its lit patch is measured at dusk
  -- where the characters stand
  for _, c in pairs(s.find_entities_filtered{type = "character"}) do
    if script.active_mods["factorio-3d-bridge"] then
      c.teleport({C.x, C.y + 3.5})
    else
      c.teleport({C.x, C.y + 30})
    end
  end
  storage.built = true
  storage.built_tick = game.tick
end

script.on_event(defines.events.on_tick, function(e)
  if e.tick % 30 == 0 and not storage.built then build() end
  if script.active_mods["factorio-3d-bridge"] then
    if e.tick % 120 == 0 then
      local s = game.surfaces[1]
      for _, c in pairs(s.find_entities_filtered{type = "character"}) do
        local p = c.position
        if math.abs(p.x - C.x) > 0.6 or math.abs(p.y - (C.y + 3.5)) > 0.6 then c.teleport({C.x, C.y + 3.5}) end
      end
    end
    return
  end
  if not storage.built or storage.shots_done then return end
  storage.shot_index = storage.shot_index or 0
  storage.next_at = storage.next_at or storage.built_tick + 200
  if e.tick < storage.next_at then return end
  local s = game.surfaces[1]
  if storage.shot_index > 0 then
    local d = DAYTIMES[storage.shot_index]
    local name = d == 0 and "factorio" or string.format("factorio-%.2f", d)
    game.take_screenshot{surface = s, position = {C.x, C.y + 3.5}, resolution = RES, zoom = 1,
      show_entity_info = false, show_gui = false, hide_clouds = true, hide_fog = true,
      anti_alias = true, path = "zenith-look/" .. name .. ".png", quality = 100}
    if storage.gleba then
      storage.gleba.daytime = d
      game.take_screenshot{surface = storage.gleba, position = {0, 0}, resolution = RES, zoom = 1,
        show_entity_info = false, show_gui = false, hide_clouds = true, hide_fog = true,
        anti_alias = true, path = string.format("zenith-look/gleba-%.2f.png", d), quality = 100}
    end
    log("zenith-look: screenshot taken at daytime " .. d)
  elseif script.active_mods["space-age"] and game.planets["gleba"] then
    local g = game.planets["gleba"].create_surface()
    g.request_to_generate_chunks({0, 0}, 3)
    g.force_generate_chunk_requests()
    g.freeze_daytime = true
    storage.gleba = g
  end
  storage.shot_index = storage.shot_index + 1
  local d = DAYTIMES[storage.shot_index]
  if not d then
    storage.shots_done = true
    game.print("zenith-look: screenshots taken")
    return
  end
  -- The real time of day, frozen, so lamps come on as they would (a screenshot's daytime only
  -- changes the picture's colours).
  s.always_day = false
  s.freeze_daytime = true
  s.daytime = d
  storage.next_at = e.tick + SETTLE
end)
