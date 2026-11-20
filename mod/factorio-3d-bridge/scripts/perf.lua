-- Run-time switches for the bridge's performance work after 0.2.0 (`/f3d-perf`, docs/RUNNING.md): each
-- change can be turned off, the old behaviour back, to compare them or to get round one that misbehaves.
-- The belt simulation's own switches are `/f3d-bs` (belt_sim.lua). One set for every client, in
-- storage.f3d_perf, changed only by the command (an event every peer runs), so every peer reads the same.
--
-- chunk_text: chunk snapshots (`chunk`, `ents`, `dec`) written as JSON text in the snapshot's slices,
-- under the work budget, instead of helpers.table_to_json in the outbox's flush (1.4-2 ms a tick while
-- chunks stream on the owner's base, 40-65 ms ticks in photo mode). The same messages on the wire.
-- far_lanes: a belt-simulating client's far lane icons (`bfar`) are read only where its square doesn't
-- cover them: none once the square reaches the far distance.
-- wire_strips: the look for wires changed without an event reads the focus square in WIRE_STRIPS strips,
-- one every 30 ticks (each wire within 4 s), instead of all of it every 30 ticks.
-- lightning_planets: lightning is looked for every 12 ticks only on planets whose prototype has lightning
-- (the data stage lists them); elsewhere every 300 (a script's execute_lightning).
-- states_near: machine states within STATE_NEAR tiles every 30 ticks, the rest of the focus square a
-- quarter a round (each every 120 ticks).
-- requeue_slices: the chunk queue put in a new order (the view turned, the middle moved) over a few ticks
-- under the work budget instead of in the packet handler at once.
--
-- The round after the hotfix (bridge.md changes 9-15):
-- records_by_prototype: a chunk record reads its prototype's type and id once a name, and natural
-- entities (trees, rocks, ore, cliffs, fish) only their deconstruction mark (no quality, upgrade, wires).
-- alerts_quiet: the alerts pass (alerts.lua) looks in chunks it found none of the force's machines in only
-- every tenth pass or once something is built there, and steps once a tick for every client.
-- one_search: cargo pods, spiders, rolling stock and enemy units from the movers' search (movers.found)
-- instead of a search each of the same square; worms searched every 300 ticks.
-- dec_distance: a client that says how far it draws decoratives (hello `dd`) gets a chunk's `dec` only
-- within that distance (and a margin) of its square's middle; the rest when the middle brings them inside.
-- belts_last (the owner: belt logic is the last thing culled for performance): the far belt lanes' rounds (`lanes`
-- in rate.lua) slow only at rate level 3, as the belt simulation's updates; off: from level 1 (2, 4, 8 times apart
-- at levels 1-3), as before.
-- chart_same: a minimap chart the client still holds as it is (the stamp it names in `map` h) is answered with
-- `same` and the live parts, not the picture again; pictures kept until the chunk changed, not 30 s.
--
-- The ninth play-test list's delays (not performance, but switched the same way):
-- status_near: turrets out of ammo, machines out of fuel and drills with nothing to mine round the focus from
-- the once-a-second power read and the reads after building or moving items (alerts.lua, J22, J27, J28),
-- not only the alerts' pass (10-40 s late on a big base).
-- mined_now: what the character mines is said at once (`mnd`: the items it got, whether the entity is gone)
-- and its inventory sent, outside the reliable outbox (puppet.lua, J20).
-- put_lanes: a belt the character put items on or took them off (Z, Ctrl+click) has its lanes read in the
-- next belt update, as a client's `bre` asks (ui_actions.lua, J21), not at its next drift check.
-- drop_put: an item Zenith's Z puts on a belt is told at once (`ie` kind 6 with no inserter: its lane, place and
-- id) and wakes the belt's drift checks (quiet_pc); Factorio's own Z onto a belt (hybrid) wakes it and reads its
-- lanes. Off: the lanes' read alone (put_lanes), as before.
-- belt_pickup (issue #18, not performance either): F (`pickup`) takes the items on belts within the character's
-- item pickup distance too, as Factorio's "Pick up items" does, and says at once what it took (`pku`, puppet.lua);
-- off: the items on the ground only, as before.
--
-- The tenth list:
-- alt_machines: while the client has Alt-mode on, the machines with module slots and the labs round the focus are
-- read in the chests' rounds for the modules and science packs Alt-mode draws over them (alt_mode.lua, K1, K2);
-- off: the chests alone.
-- mined_tell (K22): what a player-less character mines is told to what listens (tracker.removing: the belt
-- simulation drops a belt's lanes the next tick and reads the belts round it), as Factorio's on_player_mined_entity
-- tells them when a player mines; off: nothing told, as before (a mined belt's lanes stayed until its next check
-- found it gone, seconds for a belt nothing watched, its neighbours never read again for it).
--
-- The eleventh list:
-- research_chain (L12): `research` of a technology whose prerequisites aren't all researched queues the missing
-- ones first, in order, as Factorio's technology screen does (research.lua); add_research alone refuses it. Off:
-- add_research alone, as before.
-- (L13, not performance either)
-- zenith_join: the player who joins with this Zenith's own Factorio (the name its hello says, `pn`) takes over the
-- character the bridge plays for it on a world that has no player of its own (one Zenith made), and hands it back
-- as a save's player does when they leave (puppet.lua claim); off: they come in as a new player beside it, as before.
-- no_crash_site: on a server where the bridge plays its own character before anyone was created, freeplay is told not
-- to make its crash site (takeover.lua no_crash_site), which it would drop at the spawn, in the base, for the first
-- player to join from Factorio; off: freeplay's intro as before.
-- fluid_icons (L10): a crafting machine with a fluid recipe has its connections and the fluid each takes or gives
-- in its record (`fc`) and in `aiu` (alt_mode.lua), for the arrows and fluid icons Factorio draws on it hovered
-- and in Alt-mode; off: neither, the client draws the prototype's arrows without icons, as before.
-- pipe_alerts (L11): pipelines over Factorio's extent limit (status pipeline_overextended) are an alert (`al`
-- `pipeline`), one entity a fluid segment: the alerts' pass reads pipes, pipes to ground and storage tanks too
-- (a quarter of a machine's cost each), and a pipe built or removed near the focus has its pipeline read the next
-- tick (alerts.lua); off: no such alert, the pass as before.
--
-- The twelfth list:
-- under_clear (M2): an underground belt or pipe-to-ground the character builds that completes a pair mines the plain
-- belts or pipes between its ends into the character (their items too), as Factorio's player build does
-- (building.lua clear_between), and an underground fast-replacing a belt or pipe hands it and its items to the
-- character instead of deleting the items; off: both left as before (the belts between stay, the items on a
-- replaced end deleted).
-- alt_ammo_fuel (K1's leftover): with alt_machines, the ammo turrets and locomotives round the focus are read in
-- the same rounds for the ammo and fuel Alt-mode draws over them (alt_mode.lua); off: machines and labs alone.
--
-- The belts lead:
-- pickup_stop (not performance either): a client's `pickup_stop`, sent as F is let go, ends the pickup at once
-- (puppet.lua); off: the stop ignored, the pickup running on its HOLD_TICKS after the last `pickup`, as before (it
-- picked up items for up to half a second after F was let go).
--
-- The thirteenth list's follow-ups (found against real 2.1.24, not performance):
-- fast_take (N2): an empty hand's Ctrl+click (`fast`) never takes an entity's fuel: what it takes is
-- checked against the entity's own fuel inventory and falls back by its type (ui_actions.lua); off: the
-- output inventory, else the first of chest, car trunk... by index, as before (a locomotive's, boiler's,
-- burner inserter's and burner drill's fuel taken: 2.1's fuel and chest are both inventory 1).
-- vehicle_ammo (N3): while the character drives or rides an armed vehicle, shooting counts the vehicle's
-- selected gun's ammo (combat.lua): `me` `sh` and "Out of ammo" follow it; off: the character's, as before.
--
-- Found after the thirteenth list:
-- mined_neighbours: what a player-less character mines (Factorio raises nothing then) has the pipes and belts beside
-- it read again the tick after and sent (`upd`), as M.removed has them for a player's mining: a pipe left at the end
-- of a run becomes its ending piece, a belt beside a mined one straightens; off: as before (their records kept the
-- connection to what was mined, the run's last pipe drawn as a straight, open at its end in FUE5's kit).
--
-- The Stability lead (not performance either):
-- enemy_sight: the enemy units within their vision of a character with no player (a headless server's) that have no
-- distraction are given one, attack it, with their whole nest, held and chasing, as the engine does for a real
-- player's (enemy_sight.lua): a nest's idle biters ignored such a character until it shot (2.1.24); off: nothing
-- done, as before.

local M = {}

M.OPTIONS = { chunk_text = true, far_lanes = true, wire_strips = true, lightning_planets = true, states_near = true,
  requeue_slices = true, records_by_prototype = true, alerts_quiet = true, one_search = true, dec_distance = true,
  chart_same = true, status_near = true, mined_now = true, put_lanes = true, belts_last = true, belt_pickup = true,
  alt_machines = true, mined_tell = true, research_chain = true, zenith_join = true,
  no_crash_site = true, fluid_icons = true, pipe_alerts = true, under_clear = true, alt_ammo_fuel = true,
  pickup_stop = true, fast_take = true, vehicle_ammo = true, mined_neighbours = true, enemy_sight = true,
  drop_put = true }
M.ORDER = { "chunk_text", "far_lanes", "wire_strips", "lightning_planets", "states_near", "requeue_slices",
  "records_by_prototype", "alerts_quiet", "one_search", "dec_distance", "chart_same", "status_near", "mined_now",
  "put_lanes", "belts_last", "belt_pickup", "alt_machines", "mined_tell", "research_chain", "zenith_join",
  "no_crash_site", "fluid_icons", "pipe_alerts", "under_clear", "alt_ammo_fuel", "pickup_stop", "fast_take",
  "vehicle_ammo", "mined_neighbours", "enemy_sight", "drop_put" }

-- Whether switch `name` is on.
function M.on(name)
  local set = storage.f3d_perf
  local v = set and set[name]
  if v == nil then
    v = M.OPTIONS[name]
  end
  return v
end

-- `/f3d-perf [name on|off|default]`: sets a switch and says them all. Returns the lines to print.
function M.command(param)
  local name, value = tostring(param or ""):match("^%s*([%w_]+)%s+(%S+)")
  local out = {}
  if name then
    if M.OPTIONS[name] == nil then
      out[#out + 1] = "[Zenith] /f3d-perf: no switch " .. name
    elseif value == "on" or value == "1" or value == "true" or value == "off" or value == "0" or value == "false"
        or value == "default" then
      storage.f3d_perf = storage.f3d_perf or {}
      if value == "default" then
        storage.f3d_perf[name] = nil
      else
        storage.f3d_perf[name] = value == "on" or value == "1" or value == "true"
      end
    else
      out[#out + 1] = "[Zenith] /f3d-perf " .. name .. ": on, off or default"
    end
  end
  local parts = {}
  for _, k in ipairs(M.ORDER) do
    parts[#parts + 1] = k .. " " .. (M.on(k) and "on" or "off") .. ((storage.f3d_perf or {})[k] == nil and "" or " (set)")
  end
  out[#out + 1] = "[Zenith] performance switches: " .. table.concat(parts, ", ")
  return out
end

return M
