"""Turrets, weapons, enemies, and enemy-sight live checks."""
from __future__ import annotations

import json
import math
import time

from . import live_lib


def check_turrets(c, hello):
    """Turret states (`ts`, turrets.lua): real turrets with ammo, fluid and power, a tank the
    character drives and shoots from, a spidertron and an artillery turret, with biters to the
    north (they come once the mod watches the turrets). Each turret's record has its weapon's orientation, its target and the shots counted
    from its ammo (or its hits)."""
    if not live_lib.clean_spot(c, hello, half=20):
        live_lib.report(False, "turrets: no clean spot to build on", live_lib.SPOT_WHY)
        return
    x, y = math.floor(c.me["x"] / 256) + 0.5, math.floor(c.me["y"] / 256) + 0.5
    # The tank stands north-east of the row: Factorio's cannon shells hit the player's own
    # buildings in their way (from behind the row they killed the laser turret).
    out = live_lib.mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface
local made = {{}}
local function put(name, dx, dy, fill)
  local e = s.create_entity({{ name = name, position = {{ {x} + dx, {y} + dy }}, force = 'player', raise_built = true }})
  if e then made[name] = e.unit_number if fill then fill(e) end end
  return e
end
put('gun-turret', -6, 0, function(e) e.insert({{ name = 'firearm-magazine', count = 20 }}) end)
put('laser-turret', -3, 0, function(e) e.energy = 1e9 end)
put('flamethrower-turret', 0, 0, function(e) e.insert_fluid({{ name = 'crude-oil', amount = 100 }}) end)
if prototypes.entity['rocket-turret'] then put('rocket-turret', 3.5, 0, function(e) e.insert({{ name = 'rocket', count = 20 }}) end) end
if prototypes.entity['tesla-turret'] then put('tesla-turret', 7, 0, function(e) e.energy = 1e9 end) end
if prototypes.entity['railgun-turret'] then put('railgun-turret', 11.5, 0.5, function(e) e.insert({{ name = 'railgun-ammo', count = 5 }}) end) end
put('artillery-turret', -10.5, 5.5, function(e) e.insert({{ name = 'artillery-shell', count = 5 }}) end)
put('spidertron', 6, 8, function(e) e.get_inventory(defines.inventory.spider_ammo).insert({{ name = 'rocket', count = 20 }}) end)
local tank = put('tank', 20, -6, function(e)
  e.get_inventory(defines.inventory.car_ammo).insert({{ name = 'cannon-shell', count = 10 }})
  e.get_fuel_inventory().insert({{ name = 'coal', count = 10 }})
end)
if tank then tank.set_driver(c) end
storage.f3d_tur = made
storage.f3d_tur_biters = {{}}
local nest = s.create_entity({{ name = 'biter-spawner', position = {{ {x} - 10.5, {y} + 45.5 }}, force = 'enemy' }})
if nest then storage.f3d_tur_biters[1] = nest end
rcon.print(helpers.table_to_json(made))""".replace("\n", " "))
    try:
        made = json.loads(out)
    except ValueError:
        live_lib.report(False, "turrets: built the row", out)
        return
    # The character in the tank shoots at the biters as the client does (`shoot`: Factorio fires
    # the tank's selected gun); new biters come while the old ones die, and the electric turrets'
    # buffers are topped up (nothing powers them).
    shoot = {"t": "shoot", "m": 0, "x": int((x + 20) * 256), "y": int((y - 17) * 256)}
    refill = (f"local c = storage.f3d.puppet local s = c.surface "
              f"local alive = 0 for _, b in pairs(storage.f3d_tur_biters) do if b.valid then alive = alive + 1 end end "
              f"for i = alive + 1, 4 do local b = s.create_entity({{ name = 'medium-biter', position = {{ {x} - 10 + i * 4, {y} - 18 }}, force = 'enemy' }}) "
              f"if b then storage.f3d_tur_biters[#storage.f3d_tur_biters + 1] = b end end "
              "for _, n in pairs({ 'laser-turret', 'tesla-turret', 'railgun-turret' }) do local u = storage.f3d_tur[n] "
              "if u then for _, e in pairs(s.find_entities_filtered({ name = n, force = c.force })) do "
              "if e.unit_number == u then e.energy = 1e9 end end end end")
    recs = {}
    seen = ""
    rail = ""
    c.pump(1.5, every=hello)  # the mod finds new turrets once a second: let it see them before they shoot
    for i in range(24):
        live_lib.mod_lua(refill)
        if i == 20 and "railgun-turret" in made:
            rail = live_lib.mod_lua("local st = {} for k, v in pairs(defines.entity_status) do st[v] = k end "
                           f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'railgun-turret' }})) do "
                           f"if e.unit_number == {made['railgun-turret']} then rcon.print(st[e.status] .. ' energy ' .. e.energy .. "
                           "' ammo ' .. e.get_inventory(defines.inventory.turret_ammo).get_item_count() .. ' target ' .. tostring(e.shooting_target)) end end")
        if i == 8:
            seen = live_lib.mod_lua("local out = {} for u, e in pairs(storage.f3d.turrets or {}) do "
                           "out[#out + 1] = u .. (e.valid and (':' .. e.name .. ':' .. tostring(e.health)) or ':gone') end "
                           "rcon.print(table.concat(out, ' '))")
        for m in live_lib.of_type(c.pump(0.5, every=(0.2, shoot)), "ts"):
            for rec in m["l"]:
                recs.setdefault(rec[0], []).append(rec)
    names = {u: n for n, u in made.items()}

    def shots(name):
        return sum(r[2] for r in recs.get(made.get(name), []))

    def targeted(name):
        return any(len(r) == 6 for r in recs.get(made.get(name), []))

    gun = recs.get(made.get("gun-turret"), [])
    north = [r for r in gun if len(r) == 6 and (r[1] > 850 or r[1] < 150)]
    live_lib.report(gun and shots("gun-turret") > 0 and north, "ts: a gun turret's shots from its ammo, its target and its weapon's "
           "orientation towards it (LuaEntity.orientation)", f"{shots('gun-turret')} shots, {gun[-3:]}")
    live_lib.report(targeted("laser-turret") and shots("laser-turret") > 0, "ts: a laser turret's target and shots (its hits)",
           f"{recs.get(made.get('laser-turret'), [])[-3:]}; watched turrets: {seen}")
    live_lib.report(targeted("flamethrower-turret") and shots("flamethrower-turret") > 0, "ts: a flamethrower turret's target and shots (its stream's hits)",
           str(recs.get(made.get("flamethrower-turret"), [])[-3:]))
    for name in ("rocket-turret", "tesla-turret"):
        if name in made:
            live_lib.report(targeted(name) and shots(name) > 0, f"ts: a {name}'s target and shots", str(recs.get(made[name], [])[-3:]))
    if "railgun-turret" in made:
        # It aims but seldom fires here: the ammo going down once is the round it loads. Its shots
        # are counted the same way as the others' (mock-checked). Its turn_range (0.2) is where it
        # takes targets, not a stop for its head: following a biter that walked out of it the head
        # went 0.217 from north on 0.2.0's CI (783; the old check failed there). So the head is
        # checked against the target it reports: on it, within 0.02 of the bearing from the turret,
        # once raised (its orientation reads 0 while it raises, the target already set). And loosely
        # the arc: the biters come from the north-west to the row, all within 0.26 of north from here.
        rail_recs = recs.get(made["railgun-turret"], [])
        at = live_lib.mod_lua("for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({ name = 'railgun-turret' })) do "
                     f"if e.unit_number == {made['railgun-turret']} then rcon.print(e.position.x .. ' ' .. e.position.y) end end").split()
        px, py = (float(v) for v in at) if len(at) == 2 else (x + 12, y + 1)

        def off_target(r):
            bearing = (math.atan2(r[4] / 256 - px, -(r[5] / 256 - py)) / (2 * math.pi)) % 1
            d = abs(r[1] / 1000 - bearing) % 1
            return min(d, 1 - d)
        aims = [off_target(r) for r in rail_recs if len(r) == 6 and r[1] != 0]
        live_lib.report(any(d < 0.02 for d in aims) and all(r[1] >= 700 or r[1] <= 300 for r in rail_recs),
               "ts: a railgun turret's target, its head turned onto it (within 0.02 of its bearing), within 0.3 of its facing",
               f"{shots('railgun-turret')} shots; {sum(d < 0.02 for d in aims)} of {len(aims)} raised aims on the target "
               f"(closest {min(aims) if aims else '-'}); orientations {sorted({r[1] for r in rail_recs})}; {rail_recs[-3:]}; {rail}")
    art = recs.get(made.get("artillery-turret"), [])
    live_lib.report(art and shots("artillery-turret") > 0 and any(400 < r[1] < 600 for r in art),
           "ts: an artillery turret's cannon turned south to a nest 40 tiles off (relative_turret_orientation), its shells "
           "(2.1.23 gives no shooting_target for it)",
           f"{shots('artillery-turret')} shots, {art[-2:]}")
    live_lib.report(made.get("spidertron") in recs and shots("spidertron") > 0,
           "ts: a spidertron's torso (torso_orientation) and the rockets it fires by itself", f"{shots('spidertron')} shots, {recs.get(made.get('spidertron'), [])[-2:]}")
    tank = recs.get(made.get("tank"), [])
    live_lib.report(tank and any(len(r) == 6 and r[3] == 1 for r in tank) and shots("tank") > 0,
           "ts: the tank the character drives: its gunner's aim (shooting_state), its cannon (gun 1) and shots from car_ammo",
           f"{shots('tank')} shots, {tank[-3:]}")
    unknown = [u for u in recs if u not in names]
    c.send({"t": "shoot", "m": -1, "x": 0, "y": 0})
    c.pump(0.3, every=hello)
    live_lib.mod_lua("local c = storage.f3d.puppet if c.vehicle then c.driving = false end "
            "for _, b in pairs(storage.f3d_tur_biters or {}) do if b.valid then b.destroy() end end")
    # The row to the nest 45 tiles south and the defenders it spawned; and every biter within 400 tiles: a group
    # from further off than the 96 (the artillery reaches 224) arrives checks later (once 12 small biters killed
    # the character in the middle of the underground check, and the platform and planet checks after it lost theirs).
    live_lib.clear_enemies(96, x - 10.5, y + 20, units=400)
    live_lib.destroy_units(list(made.values()))
    live_lib.report(True, f"turrets: cleaned up ({len(unknown)} other turrets reported nearby)", str(made))


def check_weapons(c, hello):
    """What weapons fire (shots.lua, combat.lua's `shot`): each gun at a still biter, then capsules.
    Checks find_entities_filtered for projectiles, streams, beams, explosions, fires and clouds,
    register_on_object_destroyed as their id, on_object_destroyed for where projectiles end, and
    find_nearest_enemy for a shot's target."""
    live_lib.clean_spot(c, hello, half=20)
    c.send({"t": "focus", "x": c.me["x"], "y": c.me["y"], "r": 48})
    fx = lambda v: int(round(v * 256))

    def biter(dx, dy, name="medium-biter"):
        out = live_lib.mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface
local p = s.find_non_colliding_position("{name}", {{ c.position.x + {dx}, c.position.y + {dy} }}, 4, 0.5)
local b = p and s.create_entity({{ name = "{name}", position = p, force = "enemy" }})
if b then b.disabled_by_script = true end
rcon.print(b and (b.unit_number .. " " .. b.position.x .. " " .. b.position.y) or "none")
""".replace("\n", " "))
        try:
            unit, x, y = out.split()
            return int(unit), float(x), float(y)
        except ValueError:
            live_lib.report(False, f"spawn a {name} to shoot", out)
            return None

    def arm(gun, ammo, count=20):
        live_lib.mod_lua(f'local c = storage.f3d.puppet '
                f'c.get_inventory(defines.inventory.character_guns).clear() c.get_inventory(defines.inventory.character_ammo).clear() '
                f'c.get_inventory(defines.inventory.character_guns).insert({{name = "{gun}"}}) '
                f'c.get_inventory(defines.inventory.character_ammo).insert({{name = "{ammo}", count = {count}}}) '
                f'c.selected_gun_index = 1 storage.f3d.guns_sig = nil')

    def clear_units():
        live_lib.mod_lua("for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({ type = 'unit', position = storage.f3d.puppet.position, radius = 30 })) do e.destroy() end")

    def fire(gun, ammo, dx=7, dy=0, seconds=2.0, mode=1, name="medium-biter"):
        arm(gun, ammo)
        b = biter(dx, dy, name)
        if not b:
            return [], None
        msgs = c.pump(seconds, every=(0.15, {"t": "shoot", "m": mode, "x": fx(b[1]), "y": fx(b[2])}))
        c.send({"t": "shoot", "m": -1})
        msgs += c.pump(1.0, every=hello)
        clear_units()
        return msgs, b

    def flying(msgs, key="p", width=4):
        return [m[key][i:i + width] for m in live_lib.of_type(msgs, "pj") for i in range(0, len(m.get(key, [])), width)]

    msgs, b = fire("submachine-gun", "firearm-magazine", seconds=1.5)
    shots = live_lib.of_type(msgs, "shot")
    near = [m for m in shots if b and abs(m["x"] / 256 - b[1]) < 1.5 and abs(m["y"] / 256 - b[2]) < 1.5]
    live_lib.report(len(shots) >= 5 and near and shots[0]["g"] == "submachine-gun" and shots[0]["a"] == "firearm-magazine",
           "shot: each submachine-gun shot (ammo down a round) with the gun, ammo and the target biter's position",
           f"{len(shots)} shots, {len(near)} at the biter, first {shots[:1]}")
    gaps = [b2["k"] - a["k"] for a, b2 in zip(shots, shots[1:])]
    live_lib.report(gaps and min(gaps) >= 5, "shot: about one per 6 ticks, the submachine gun's cooldown", f"tick gaps {gaps[:10]}")
    xs = [m["x"][i] for m in live_lib.of_type(msgs, "pj") for i in range(0, len(m.get("x", [])), 3)]
    live_lib.report("explosion-gunshot" not in xs and "explosion-hit" not in xs,
           "headless: no explosion-gunshot / explosion-hit (only_when_visible), so the client plays them", str(sorted(set(xs)))[:200])

    msgs, b = fire("shotgun", "shotgun-shell", dx=6, seconds=1.0)
    pellets = [r for r in flying(msgs) if r[1] == "shotgun-pellet"]
    ids = {r[0] for r in pellets}
    ended = flying(msgs, "e", 3)
    live_lib.report(len(ids) >= 10 and all(isinstance(i, int) for i in ids),
           "pj: shotgun pellets in flight, each with its register_on_object_destroyed id", f"{len(ids)} pellets")
    live_lib.report(any(e[0] in ids for e in ended), "pj.e: on_object_destroyed says where pellets ended", f"{len(ended)} ended")
    moves = {}
    for r in pellets:
        moves.setdefault(r[0], []).append(r[2])
    live_lib.report(any(len(set(v)) > 1 for v in moves.values()), "pj: a pellet's position changes between scans")

    msgs, b = fire("rocket-launcher", "rocket", dx=12, seconds=2.5)
    rockets = [r for r in flying(msgs) if r[1] == "rocket"]
    rids = {r[0] for r in rockets}
    live_lib.report(rids and any(e[0] in rids for e in flying(msgs, "e", 3)), "pj: a rocket in flight and where it hit",
           f"{len(rockets)} positions of {len(rids)} rockets")

    msgs, b = fire("flamethrower", "flamethrower-ammo", dx=8, seconds=2.0)
    streams = [r for r in flying(msgs) if r[1] == "handheld-flamethrower-fire-stream"]
    fires = [m["l"][i:i + 5] for m in live_lib.of_type(msgs, "gf") for i in range(0, len(m["l"]), 5)]
    live_lib.report(streams, "pj: the hand flamethrower's stream entities", f"{len(streams)} positions")
    live_lib.report(any(f[1] == "fire-flame" and f[4] == -1 for f in fires), "gf: fire-flame on the ground where the stream landed",
           str(fires[:2]))
    live_lib.report(not live_lib.of_type(msgs, "shot"), "shot: none for a stream gun (the stream shows it)")

    if live_lib.mod_lua("rcon.print(prototypes.item['teslagun'] and 'yes' or 'no')") == "yes":
        msgs, b = fire("teslagun", "tesla-ammo", dx=7, seconds=2.0)
        beams = [r for r in flying(msgs, "b", 6) if r[1].startswith("chain-tesla-gun-beam")]
        live_lib.report(beams and b and any(abs(r[4] / 256 - b[1]) < 2 and abs(r[5] / 256 - b[2]) < 2 for r in beams),
               "pj.b: the tesla gun's chain beam from the character to the biter (get_beam_source/target)",
               str(beams[:2]))
        msgs, b = fire("railgun", "railgun-ammo", dx=9, seconds=2.2)
        shots = live_lib.of_type(msgs, "shot")
        live_lib.report(shots and shots[0]["g"] == "railgun", "shot: the railgun's shot (its beam is only_when_visible)", str(shots[:1]))

    live_lib.mod_lua('storage.f3d.puppet.insert({name = "grenade", count = 5}) storage.f3d.puppet.insert({name = "poison-capsule", count = 5})')
    x, y = c.me["x"] / 256, c.me["y"] / 256
    c.send({"t": "throw", "item": "grenade", "x": fx(x + 8), "y": fx(y + 2)})
    msgs = c.pump(2.5, every=hello)
    gren = [r for r in flying(msgs) if r[1] == "grenade"]
    xs = [m["x"][i:i + 3] for m in live_lib.of_type(msgs, "pj") for i in range(0, len(m.get("x", [])), 3)]
    live_lib.report(gren, "pj: a thrown grenade in flight", f"{len(gren)} positions")
    live_lib.report(any(e[0] == "grenade-explosion" and abs(e[1] / 256 - x - 8) < 2 for e in xs),
           "pj.x: the grenade's explosion entity, found once where it landed", str(xs[:4]))
    live_lib.report(len([e for e in xs if e[0] == "grenade-explosion"]) == 1, "pj.x: each explosion is reported once")
    c.send({"t": "throw", "item": "poison-capsule", "x": fx(x - 8), "y": fx(y)})
    msgs = c.pump(3.0, every=hello)
    clouds = [m["l"][i:i + 5] for m in live_lib.of_type(msgs, "gf") for i in range(0, len(m["l"]), 5)]
    live_lib.report(any(f[1] == "poison-cloud" and f[4] > 0 for f in clouds), "gf: the poison cloud with its time_to_live",
           str([f for f in clouds if f[1] == "poison-cloud"][:1]))
    live_lib.mod_lua("for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({ type = {'fire', 'smoke-with-trigger'}, position = storage.f3d.puppet.position, radius = 40 })) do e.destroy() end")
    msgs = c.pump(1.0, every=hello)
    live_lib.report(any(not m["l"] for m in live_lib.of_type(msgs, "gf")), "gf: an empty list once the fires and clouds are gone")


def check_enemies(c, hello):
    """Enemies' attacks (`en`, scripts/enemies.lua) and the decals round nests. Biters next to a
    wall attack it or the character (their attack command's distraction in 2.1.23), a worm shoots
    (its shooting_target), and each is listed with its target's position. A spawner and a worm
    made with spawn_decorations place Factorio's enemy decals, which reach a client that asks for
    decoratives (`dec`) with the chunk's resend."""
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "enemies: an empty spot", live_lib.SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    on = (1.0, dict(hello[1], dc=1))
    c.send(on[1])
    early = c.pump(2.0, every=on)
    out = live_lib.mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface
local x, y = {x}, {y}
local wall = s.create_entity({{ name = "stone-wall", position = {{ x + 8, y }}, force = c.force, raise_built = true }})
local made = {{ wall.unit_number }}
for i = -1, 1 do
  made[#made + 1] = s.create_entity({{ name = "small-biter", position = {{ x + 9.5, y + i }}, force = "enemy" }}).unit_number
end
made[#made + 1] = s.create_entity({{ name = "small-worm-turret", position = {{ x + 8, y - 9 }}, force = "enemy",
  spawn_decorations = true, raise_built = true }}).unit_number
made[#made + 1] = s.create_entity({{ name = "biter-spawner", position = {{ x + 12, y + 10 }}, force = "enemy",
  spawn_decorations = true, raise_built = true }}).unit_number
local decals = 0
for _, d in pairs(s.find_decoratives_filtered({{ area = {{ {{ x - 8, y - 20 }}, {{ x + 30, y + 26 }} }} }})) do
  if d.decorative.name == "enemy-decal" or d.decorative.name == "enemy-decal-transparent" then decals = decals + 1 end
end
rcon.print(table.concat(made, " ") .. " " .. decals)
""".replace("\n", " "))
    try:
        nums = [int(v) for v in out.split()]
    except ValueError:
        live_lib.report(False, "enemies: spawned a wall, biters, a worm and a spawner", out)
        return
    made, decals = nums[:-1], nums[-1]
    biters, worm, spawner = made[1:4], made[4], made[5]
    msgs = c.pump(4.0, every=on)
    rows = [m["l"][i:i + 3] for m in live_lib.of_type(msgs, "en") for i in range(0, len(m["l"]), 3)]
    attacking = {r[0]: (r[1] / 256, r[2] / 256) for r in rows}
    wall_at, me_at = (x + 8.5, y + 0.5), (c.me["x"] / 256, c.me["y"] / 256)

    def near(p, q):
        return abs(p[0] - q[0]) < 1.5 and abs(p[1] - q[1]) < 1.5
    hit = [u for u in biters if u in attacking and (near(attacking[u], wall_at) or near(attacking[u], me_at))]
    live_lib.report(len(hit) >= 2, "en: biters in range of their attack target are listed with its position (distraction_command)",
           f"{len(hit)} of 3; {len(live_lib.of_type(msgs, 'en'))} en, rows {rows[-6:]}")
    live_lib.report(worm in attacking, "en: a worm with a shooting_target is listed", f"{attacking.get(worm)}; {sorted(attacking)[:8]}")
    did = {rec[1]: rec[0] for m in live_lib.of_type(early + msgs, "dprotos") for rec in m["l"]}
    sent = set()
    for m in live_lib.of_type(msgs, "dec"):
        l = m["l"] if isinstance(m["l"], list) else []
        sent.update(l[0::4])
    want = {did.get("enemy-decal"), did.get("enemy-decal-transparent")} - {None}
    live_lib.report(decals > 0 and bool(want & sent), "nest decals: spawn_decorations places enemy decals and dec sends them",
           f"{decals} enemy decals on the surface, decal ids {sorted(want)} in dec: {sorted(want & sent)}")
    live_lib.mod_lua(f"local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({{ force = 'enemy', "
            f"area = {{ {{ {x} - 40, {y} - 40 }}, {{ {x} + 40, {y} + 40 }} }} }})) do e.destroy() end")
    live_lib.destroy_units(made[:1])
    c.send(hello[1])
    c.pump(0.5, every=hello)


ES_LUA = """
local CN = {} for k, v in pairs(defines.command) do CN[v] = k end
local DN = {} for k, v in pairs(defines.distraction) do DN[v] = k end
local c = storage.f3d.puppet local s = c.surface
local function find(units)
  local want, out = {}, {}
  for _, u in pairs(units) do want[u] = true end
  for _, e in pairs(s.find_entities_filtered({ force = 'enemy', position = c.position, radius = 200 })) do
    if e.unit_number and want[e.unit_number] then out[#out + 1] = e end
  end
  return out
end
local function cmd(t)
  if not t then return 'nil' end
  local x = CN[t.type] or tostring(t.type)
  if t.target then x = x .. (t.target == c and '>char' or ('>' .. (t.target.valid and t.target.name or '?'))) end
  if t.distraction then x = x .. '/' .. (DN[t.distraction] or tostring(t.distraction)) end
  return x
end
local function row(e)
  local r = { u = e.unit_number, n = e.name, x = math.floor(e.position.x * 10) / 10, y = math.floor(e.position.y * 10) / 10,
    d = math.floor(math.sqrt((e.position.x - c.position.x) ^ 2 + (e.position.y - c.position.y) ^ 2) * 10) / 10, hp = e.health }
  if e.commandable then
    local cm = e.commandable
    r.cmd = cmd(cm.command) r.dis = cmd(cm.distraction_command)
    r.grp = cm.parent_group and 1 or 0
    local ok, sp = pcall(function() return cm.spawner end) r.sp = ok and sp and 1 or 0
  end
  local ok, a = pcall(function() return e.active end) if ok then r.act = a end
  local ok2, f = pcall(function() return e.frozen end) if ok2 then r.frz = f end
  if e.type == 'turret' then
    local t = e.shooting_target r.shoot = t and (t == c and 'char' or t.name) or 'nil'
  end
  return r
end
"""


def fix_compare(c, hello, lua, sample, show, rows_of, attacking, nest_units, nx, ny):
    """The bridge's fix (/f3d-perf enemy_sight, enemy_sight.lua) at a nest the map made, its biters asleep: the character
    walks up from 90 tiles west with the switch off, then back out and up again with it on. Off, none of the nest's
    biters may attack it; on, they must once it is within their vision (30), the whole nest together. Then, on, it
    stands among them for 45 s (the health bonus kept, healed four times a second) and the attackers are counted each
    second: held and dropping off gradually, as a real player's were; then it walks 150 tiles away and they must still
    be on it (no leash). Returns the numbers for the summary."""
    set_sight = lambda on: live_lib.mod_lua("storage.f3d_perf = storage.f3d_perf or {} storage.f3d_perf.enemy_sight = "
                                   + ("nil" if on else "false"))

    def biters():
        return [r for r in rows_of(sample(nest_units)) if "cmd" in r]

    def walk_to(dist):
        stop = nx - dist
        if c.me["x"] / 256 < stop:
            c.pump(10.0, until=lambda m: m.get("t") == "me" and m["x"] / 256 >= stop, every=(0.15, {"t": "walk", "d": 4}))
        c.send({"t": "walk", "d": -1})
        c.pump(0.3, every=hello)

    def heal_watch(seconds, tag):
        """Samples every second, healing the character every quarter second in between (the caller's health bonus
        left as it is, on for the standing hold): attackers per second, the hp it lost, and whether it died."""
        counts, lost, died = [], 0.0, False
        for i in range(int(seconds)):
            for _ in range(4):
                c.pump(0.25, every=hello)
                out = live_lib.mod_lua("local c = storage.f3d.puppet if not (c and c.valid) then rcon.print('dead') return end "
                              "local l = c.max_health - c.health c.health = c.max_health rcon.print(l)")
                if out.strip() == "dead":
                    died = True
                else:
                    try:
                        lost += float(out)
                    except ValueError:
                        pass
            smp = sample(nest_units)
            show(f"{tag} +{i + 1}s", smp)
            counts.append(len(set(attacking(smp, True))))
        print(f"  {tag}: attackers each second {counts}, hp lost {lost:.0f} (healed), died {died}")
        return counts, round(lost), died

    def approach(tag):
        """Walks up in steps; at each, 5 s of samples. Returns (distance, nearest biter, attackers) at the first stop
        any biter attacked, or None."""
        for dist in (50, 40, 32, 26, 20, 14):
            walk_to(dist)
            for i in range(5):
                c.pump(1.0, every=hello)
                live_lib.mod_lua("local c = storage.f3d.puppet if c and c.valid then c.health = c.max_health end")
                smp = sample(nest_units)
                show(f"{tag} at {dist} +{i + 1}s", smp)
                att = set(attacking(smp, True))
                if att:
                    units = [r for r in rows_of(smp) if "cmd" in r]
                    near = min((r["d"] for r in units), default=None)
                    return dist, near, len(att), len(units), i + 1
        return None

    # The nest's worms shoot the character (they need no fix) and would kill it between the samples: gone. During the
    # approaches a health bonus keeps it alive (it changes no targeting, the diagnostic found); none for the fades.
    live_lib.mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ type = 'turret', force = 'enemy', "
            f"position = {{ {nx}, {ny} }}, radius = 40 }})) do e.destroy() end")
    bonus = lambda n: live_lib.mod_lua(f"storage.f3d.puppet.character_health_bonus = {n} local c = storage.f3d.puppet c.health = c.max_health")
    alive = lambda: live_lib.mod_lua("local c = storage.f3d.puppet rcon.print(tostring(c and c.valid and c.health > 0) .. ' ' .. "
                            "(c and c.valid and math.floor(c.position.x) or 0))")
    groups = biters()
    print(f"INFO enemysight fix: {len(groups)} nest biters, in a unit group (parent_group) {sum(r.get('grp', 0) for r in groups)}, "
          f"spawner set {sum(r.get('sp', 0) for r in groups)}")
    set_sight(False)
    live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {nx - 90}, {ny} }})")
    bonus(100000)
    c.pump(1.0, every=hello)
    off = approach("fix off")
    print(f"  after the approach, alive and x: {alive()}")
    print(f"INFO enemysight fix off: first attack (distance, nearest biter, attackers, biters, s) {off}")
    live_lib.report(off is None and alive().startswith("true"), "enemysight: with /f3d-perf enemy_sight off the nest's biters don't attack the character "
           "walking up to 14 tiles (as before the fix)", str(off))
    # Out again, and a while for anything stirred up to settle.
    live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {nx - 90}, {ny} }}) local c = storage.f3d.puppet c.health = c.max_health")
    c.pump(20.0, every=hello)
    set_sight(True)
    on = approach("fix on")
    print(f"  after the approach, alive and x: {alive()}")
    print(f"INFO enemysight fix on: first attack (distance, nearest biter, attackers, biters, s) {on}")
    live_lib.report(on is not None and on[1] is not None and on[1] <= 31,
           "enemysight: with the fix on the nest's biters attack the approaching character once within their vision (30)",
           str(on))
    # The whole nest wakes together (a real player's: 14 of 14 within 0.6 s), not only those in vision.
    woke = None
    if on:
        c.pump(0.6, every=hello)
        smp = sample(nest_units)
        units = [r for r in rows_of(smp) if "cmd" in r]
        woke = (len(set(attacking(smp, True))), len(units))
        print(f"INFO enemysight fix on: attacking 0.6 s after the first attack {woke[0]} of {woke[1]} nest biters")
        live_lib.report(woke[1] > 0 and woke[0] >= 0.8 * woke[1],
               "enemysight: the whole nest wakes together, as for a real player (at least 80% of its biters)", str(woke))
    # Standing still 45 s (the health bonus kept, as in the real player's measurement): held and dropping off
    # gradually, about half by 8-10 s, a few left at 40 s; not the 3-6 s fade without the fix.
    hold = heal_watch(45, "fix on, standing") if on else None
    if hold:
        n = hold[0]
        print(f"INFO enemysight fix on, standing: attackers at 2, 5, 10, 20, 30, 40 s: {[n[i - 1] for i in (2, 5, 10, 20, 30, 40)]} "
              "(real player: 14, 11-13, 6-7, 4-5, 3-4, 1-2)")
        live_lib.report(n[1] >= 1 and n[9] < n[1] and n[19] >= 1 and n[44] <= n[9],
               "enemysight: standing, the attack is held and drops off gradually (on at 20 s, fewer at 10 s than at 2 s)", str(n))
    # Walking away west 150 tiles in one-tile steps (as the measurement moved both characters): no leash, the
    # attackers keep chasing while they keep up.
    chase = []
    if on:
        start = float(alive().split()[1])
        for i in range(150):
            live_lib.mod_lua("local c = storage.f3d.puppet if c and c.valid then c.teleport({ c.position.x - 1, c.position.y }) "
                    "c.health = c.max_health end")
            c.pump(0.13, every=hello)
            if i % 10 == 9:
                smp = sample(nest_units)
                chase.append((round(nx - (start - i - 1)), len(set(attacking(smp, True)))))
        print(f"INFO enemysight fix on, walking away: (tiles from the nest, attackers) {chase} (real player: 8-13 to 400 tiles)")
        live_lib.report(bool(chase) and chase[-1][1] >= 1,
               f"enemysight: chasing with no leash, still attacked {chase[-1][0] if chase else '?'} tiles from the nest", str(chase))
    bonus(0)
    live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {nx - 90}, {ny} }}) local c = storage.f3d.puppet c.health = c.max_health")
    c.pump(1.0, every=hello)
    return {"off": off, "on": on, "woke": woke, "hold": hold, "chase": chase,
            "grouped": sum(r.get("grp", 0) for r in groups), "biters": len(groups)}


def car_compare(c, hello, sample, show, rows_of, nest_units, nx, ny):
    """The vehicle path (/f3d-perf enemy_sight_vehicle, enemy_sight.lua) at the same nest after fix_compare, with a
    fresh sleeping set of its biters (step 6 grows them): with enemy_sight on, the character drives a car (put in it by the check, the car moved in steps by
    teleport) up from 90 tiles west with enemy_sight_vehicle off, then out and up again with it on. Off, none may go
    for the car (as before); on, they must once it is within their vision, the whole nest, the car the target (a real
    player's in a car is attacked so). Then 10 s parked (held), and the character gets out: the ones on the car must
    turn to it. The car is healed four times a second. Returns the numbers for the summary."""
    set_veh = lambda on: live_lib.mod_lua("storage.f3d_perf = storage.f3d_perf or {} storage.f3d_perf.enemy_sight_vehicle = "
                                 + ("nil" if on else "false"))
    on_car = lambda smp: [r["u"] for r in rows_of(smp) if "cmd" in r and (">car" in str(r.get("cmd")) or ">car" in str(r.get("dis")))]
    on_char = lambda smp: [r["u"] for r in rows_of(smp) if "cmd" in r and (">char" in str(r.get("cmd")) or ">char" in str(r.get("dis")))]
    heal = ("local c = storage.f3d.puppet if c and c.valid then c.health = c.max_health end "
            "local v = storage.f3d_check_car if v and v.valid then v.health = v.max_health end")

    def settle(limit=90):
        """The character 90 tiles west on foot until 80% of the nest's biters are home (within 40 of it) with no
        distraction, or `limit` s."""
        live_lib.mod_lua(f"local c = storage.f3d.puppet if c.vehicle then c.vehicle.set_driver(nil) end c.teleport({{ {nx - 90}, {ny} }})")
        # Counted round the nest by unit number, whatever the character's state: (home and asleep, alive).
        census = (f"local want = {{}} for _, u in pairs({{ {', '.join(map(str, nest_units))} }}) do want[u] = true end "
                  "local s = game.surfaces.nauvis local home, alive = 0, 0 "
                  f"for _, e in pairs(s.find_entities_filtered({{ force = 'enemy', type = 'unit', position = {{ {nx}, {ny} }}, radius = 400 }})) do "
                  "if want[e.unit_number] then alive = alive + 1 local dx, dy = e.position.x - " + str(nx) + ", e.position.y - " + str(ny) + " "
                  "if dx * dx + dy * dy <= 1600 and e.commandable and not e.commandable.distraction_command then home = home + 1 end end end "
                  "rcon.print(home .. ' ' .. alive)")
        t0, home, out = time.time(), (0, 0), ""
        while time.time() - t0 < limit:
            c.pump(5.0, every=hello)
            live_lib.mod_lua(heal)
            out = live_lib.mod_lua(census)
            try:
                home = tuple(int(v) for v in out.split())
            except ValueError:
                home = (0, 0)
            if len(home) == 2 and home[1] and home[0] >= 0.8 * home[1]:
                break
        print(f"  settled after {time.time() - t0:.0f} s: {home[0]} of {home[1]} biters home and asleep"
              + ("" if home[1] else f" (census: {out[:200]!r})"))
        return home

    def drive_up(tag):
        """The car (the character driving) moved up in steps; at each, 5 s of samples. The first stop any biter went
        for the car: (distance, nearest biter, on the car, biters, s), else None."""
        out = live_lib.mod_lua(f"local c = storage.f3d.puppet local s = c.surface "
                      f"local p = s.find_non_colliding_position('car', {{ {nx - 90}, {ny} }}, 10, 0.5) "
                      "local v = s.create_entity({ name = 'car', position = p, force = c.force }) "
                      "v.set_driver(c) storage.f3d_check_car = v "
                      "rcon.print(tostring(c.vehicle == v) .. ' ' .. v.unit_number .. ' ' .. tostring(v.is_military_target))")
        print(f"  {tag}: the character in a car (in it, unit number, is_military_target) {out}")
        c.pump(1.0, every=hello)
        for dist in (50, 40, 32, 26, 20, 14):
            live_lib.mod_lua(f"local v = storage.f3d_check_car v.teleport({{ {nx - dist}, {ny} }})")
            for i in range(5):
                for _ in range(4):
                    c.pump(0.25, every=hello)
                    live_lib.mod_lua(heal)
                smp = sample(nest_units)
                show(f"{tag} at {dist} +{i + 1}s", smp)
                att = on_car(smp)
                if att:
                    units = [r for r in rows_of(smp) if "cmd" in r]
                    return dist, min((r["d"] for r in units), default=None), len(att), len(units), i + 1
        return None

    def out_of_car():
        live_lib.mod_lua("local v = storage.f3d_check_car if v and v.valid then v.set_driver(nil) v.destroy() end storage.f3d_check_car = nil "
                f"local c = storage.f3d.puppet c.teleport({{ {nx - 90}, {ny} }}) c.health = c.max_health")

    home = settle()
    set_veh(False)
    off = drive_up("car, enemy_sight_vehicle off")
    print(f"INFO enemysight car off: first on the car (distance, nearest biter, on the car, biters, s) {off}")
    live_lib.report(off is None, "enemysight: with /f3d-perf enemy_sight_vehicle off the nest's biters don't go for the character's car "
           "driven up to 14 tiles (as before)", str(off))
    out_of_car()
    set_veh(True)
    settle()
    on = drive_up("car, on")
    print(f"INFO enemysight car on: first on the car (distance, nearest biter, on the car, biters, s) {on}")
    live_lib.report(on is not None and on[1] is not None and on[1] <= 31,
           "enemysight: in a car, the nest's biters go for the car once within their vision (30), as for a real player's", str(on))
    woke = hold = turned = None
    if on:
        c.pump(0.6, every=hello)
        smp = sample(nest_units)
        units = [r for r in rows_of(smp) if "cmd" in r]
        woke = (len(on_car(smp)), len(units))
        print(f"INFO enemysight car on: on the car 0.6 s after the first {woke[0]} of {woke[1]} nest biters")
        live_lib.report(woke[1] > 0 and woke[0] >= 0.8 * woke[1], "enemysight: in a car, the whole nest wakes together (at least 80%)", str(woke))
        hold = []
        for i in range(10):
            for _ in range(4):
                c.pump(0.25, every=hello)
                live_lib.mod_lua(heal)
            hold.append(len(on_car(sample(nest_units))))
        print(f"INFO enemysight car on, parked: on the car each second {hold}")
        live_lib.report(hold[1] >= 1, "enemysight: parked, the attack on the car is held", str(hold))
        before = hold[-1]
        live_lib.mod_lua("local v = storage.f3d_check_car v.set_driver(nil)")
        turned = []
        for i in range(3):
            for _ in range(4):
                c.pump(0.25, every=hello)
                live_lib.mod_lua(heal)
            smp = sample(nest_units)
            turned.append((len(on_char(smp)), len(on_car(smp))))
        print(f"INFO enemysight car on, got out: (on the character, on the car) each second {turned}, {before} on the car before")
        live_lib.report(max(t[0] for t in turned) >= 1 and turned[-1][1] <= max(1, before // 3),
               "enemysight: getting out, the biters on the car turn to the character", str(turned))
    out_of_car()
    c.pump(1.0, every=hello)
    return {"off": off, "on": on, "woke": woke, "hold": hold, "turned": turned, "home": home}


def check_enemy_sight(c, hello, nest_only=False, old_nest=False):
    """A diagnostic, not a pass/fail check (stability, `alerts` group, step 0 of the R&D's Question 3): do idle
    biters notice the bridge's player-less character walking up to them, as they would a real player? Prints raw
    numbers per step: the character's flags; three small biters made 60 tiles off and left to go idle; the character
    walking (the client's `walk`) to 20 tiles of them and then 8; one pistol shot at one of them; a small worm
    approached to inside its range; and by hand the two candidate fixes, B (an idle biter's command re-issued as a
    wander with distraction by_enemy) and A (set_distraction_command attack on the character for each biter within
    vision); last, the nearest nest the map made itself, walked up to from 90 tiles in steps. The character is healed
    after every sample, so an attack can't kill it. Use a fresh map: enemies within 200 tiles of the spot are destroyed,
    and step 6 runs the game fast (speed 10) for up to 5 minutes.
    Steps 1-5 run with /f3d-perf enemy_sight off (the bridge's fix, enemy_sight.lua), as the diagnostic first ran them. At
    the nest, the fix is compared off and on (fix_compare): its biters must not attack the approaching character with
    it off and must with it on; then how long their attack lasts, without the health bonus (the character healed four
    times a second instead). old_nest: the diagnostic's own nest step (options A and B by hand, a shot) after it.
    nest_only (`--only enemysightfix`): steps 1 and 6 alone."""
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "enemysight: a clean spot", live_lib.SPOT_WHY)
        return
    live_lib.clear_enemies(radius=200)
    # The approach runs 60 tiles east: trees, rocks, cliffs and water there would stop the walk.
    spot = live_lib.mod_lua("local c = storage.f3d.puppet local s = c.surface local p = c.position "
                   "local area = { { p.x - 20, p.y - 24 }, { p.x + 100, p.y + 24 } } "
                   "for _, e in pairs(s.find_entities_filtered({ area = area, type = { 'tree', 'simple-entity', 'cliff', 'fish' } })) do e.destroy() end "
                   "local tiles = {} for _, t in pairs(s.find_tiles_filtered({ area = area, collision_mask = 'water_tile' })) do "
                   "tiles[#tiles + 1] = { name = 'landfill', position = t.position } end "
                   "if #tiles > 0 then s.set_tiles(tiles) end rcon.print(p.x .. ' ' .. p.y)")
    sx, sy = (float(v) for v in spot.split())
    c.pump(0.5, every=hello)
    set_sight = lambda on: live_lib.mod_lua("storage.f3d_perf = storage.f3d_perf or {} storage.f3d_perf.enemy_sight = "
                                   + ("nil" if on else "false"))
    set_sight(False)

    def lua(code):
        return live_lib.mod_lua((ES_LUA + code).replace("\n", " "))

    print("INFO enemysight step 1: " + lua(
        "local ok, mil = pcall(function() return c.is_military_target end) "
        "local ok2, act = pcall(function() return c.active end) "
        "local ok3, dis = pcall(function() return c.disabled_by_script end) "
        "local ok4, pmil = pcall(function() return c.prototype.is_military_target end) "
        "rcon.print('force ' .. c.force.name .. ', is_military_target ' .. tostring(mil) .. ', destructible ' .. tostring(c.destructible) "
        ".. ', active ' .. tostring(act) .. ', disabled_by_script ' .. tostring(dis) .. ', c.player ' .. tostring(c.player and c.player.name) "
        ".. ', #game.players ' .. #game.players .. ', #game.connected_players ' .. #game.connected_players "
        ".. ', peaceful_mode ' .. tostring(s.peaceful_mode) .. ', no_enemies_mode ' .. tostring(s.no_enemies_mode) "
        ".. ', enemy at war with it ' .. tostring(game.forces.enemy.is_enemy(c.force)) .. ', cease_fire ' .. tostring(game.forces.enemy.get_cease_fire(c.force)) "
        ".. ', prototype is_military_target ' .. tostring(pmil) .. ', tick ' .. game.tick)"))

    def sample(units):
        """The units' rows, the character's damage since the last sample (then it is healed)."""
        out = lua(f"local rows = {{}} for _, e in pairs(find({{ {', '.join(str(u) for u in units)} }})) do rows[#rows + 1] = row(e) end "
                  "local lost = c.max_health - c.health c.health = c.max_health "
                  "rcon.print(helpers.table_to_json({ tick = game.tick, cx = math.floor(c.position.x * 10) / 10, lost = lost, rows = rows }))")
        try:
            return json.loads(out)
        except ValueError:
            return {"error": out}

    seen = {}

    def rows_of(smp):
        return smp["rows"] if isinstance(smp.get("rows"), list) else []

    def show(tag, smp):
        if "error" in smp:
            print(f"  {tag}: error {smp['error'][:300]}")
            return
        rows = rows_of(smp)
        units = [r for r in rows if "cmd" in r]
        crowd = len(units) > 6
        line = lambda r: (f"{r['u']} {r['n']} d {r['d']} ({r['x']},{r['y']}) hp {r['hp']:.0f}"
                          + (f" cmd {r.get('cmd')} dis {r.get('dis')} spawner {r.get('sp')}" if "cmd" in r else "")
                          + (f" active {r['act']}" if "act" in r else "") + (f" frozen {r['frz']}" if "frz" in r else "")
                          + (f" shoot {r['shoot']}" if "shoot" in r else ""))
        text = " | ".join(line(r) for r in rows if not crowd or "cmd" not in r)
        if crowd:
            ds = sorted(r["d"] for r in units)
            moved = sum(1 for r in units if seen.get(r["u"]) not in (None, (r["x"], r["y"])))
            for r in units:
                seen[r["u"]] = (r["x"], r["y"])
            text += (f" | {len(units)} biters: d {ds[0]}-{ds[-1]}, moved since the last sample {moved}, "
                     f"cmd {sorted({str(r.get('cmd')) for r in units})}, dis {sorted({str(r.get('dis')) for r in units})} "
                     f"({sum(1 for r in units if r.get('dis') != 'nil')} with one), spawner set {sum(r.get('sp', 0) for r in units)}, "
                     f"in a unit group {sum(r.get('grp', 0) for r in units)}, "
                     f"active {sorted({str(r.get('act')) for r in units})}, nearest: {line(min(units, key=lambda r: r['d']))}")
        print(f"  {tag}: tick {smp['tick']} char x {smp['cx']} lost {smp['lost']:.0f} hp | " + text)

    def attacking(smp, biters_only=False):
        return [r["u"] for r in rows_of(smp) if ">char" in str(r.get("cmd")) or ">char" in str(r.get("dis"))
                or (r.get("shoot") == "char" and not biters_only)]

    def setup(name="small-biter", n=3, idle=20):
        """Back to the spot, the enemies cleared, `n` of `name` made 60 tiles east, then waited on until idle."""
        live_lib.clear_enemies(radius=200)
        live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {sx}, {sy} }})")
        c.pump(0.5, every=hello)
        out = lua(f"local u = {{}} for i = 1, {n} do local p = s.find_non_colliding_position('{name}', {{ c.position.x + 60, c.position.y + (i - ({n} + 1) / 2) * 3 }}, 4, 0.5) "
                  f"local e = p and s.create_entity({{ name = '{name}', position = p, force = 'enemy' }}) u[#u + 1] = e and e.unit_number or 0 end "
                  "rcon.print(table.concat(u, ' '))")
        units = [int(v) for v in out.split()]
        smp = sample(units)
        show("made", smp)
        if name != "small-biter":
            return units
        end, last, start = time.time() + idle + 15, None, time.time()
        while time.time() < end:
            c.pump(2.0, every=hello)
            smp = sample(units)
            pos = [(r["x"], r["y"], r.get("dis")) for r in rows_of(smp)]
            if time.time() - start >= idle and pos == last and all(p[2] == "nil" for p in pos):
                show(f"idle after {time.time() - start:.0f} s", smp)
                return units
            last = pos
        show("not idle in time", smp)
        return units

    def approach(units, dist):
        """Walks east (the client's walk) until the character is `dist` tiles west of the units' middle x."""
        rows = rows_of(sample(units))
        if not rows:
            return None
        stop = sum(r["x"] for r in rows) / len(rows) - dist
        t0 = time.time()
        if c.me["x"] / 256 < stop:
            c.pump(10.0, until=lambda m: m.get("t") == "me" and m["x"] / 256 >= stop, every=(0.15, {"t": "walk", "d": 4}))
        c.send({"t": "walk", "d": -1})
        c.pump(0.3, every=hello)
        smp = sample(units)
        show(f"walked to {dist} ({time.time() - t0:.1f} s)", smp)
        return smp

    def watch(units, seconds, tag, biters_only=False):
        first, t0 = None, time.time()
        for i in range(int(seconds)):
            c.pump(1.0, every=hello)
            smp = sample(units)
            show(f"{tag} +{i + 1}s", smp)
            if first is None and (attacking(smp, biters_only) or (smp.get("lost", 0) > 0 and not biters_only)):
                first = (round(time.time() - t0, 1), smp.get("tick"), attacking(smp, biters_only), smp.get("lost"))
        print(f"  {tag}: first attack (s, tick, attackers, hp lost) {first}")
        return first

    near20 = near8 = shot = opt_b = opt_a = worm_hit = None
    if not nest_only:
        print("INFO enemysight step 2-3: three idle small biters, the character walks up to 20 tiles, then 8")
        units = setup()
        approach(units, 20)
        near20 = watch(units, 10, "at 20")
        approach(units, 8)
        near8 = watch(units, 5, "at 8")

        print("INFO enemysight step 4: one pistol shot at one idle biter at 20 tiles")
        units = setup()
        approach(units, 20)
        watch(units, 3, "before shot")
        live_lib.mod_lua('local c = storage.f3d.puppet '
                'c.get_inventory(defines.inventory.character_guns).clear() c.get_inventory(defines.inventory.character_ammo).clear() '
                'c.get_inventory(defines.inventory.character_guns).insert({name = "pistol"}) '
                'c.get_inventory(defines.inventory.character_ammo).insert({name = "firearm-magazine", count = 10}) '
                'c.selected_gun_index = 1 storage.f3d.guns_sig = nil')
        rows = rows_of(sample(units))
        shot = None
        if rows:
            target = rows[0]
            ammo = ("local i = storage.f3d.puppet.get_inventory(defines.inventory.character_ammo) "
                    "rcon.print(i.get_item_count('firearm-magazine') .. ' mags, ' .. (i[1].valid_for_read and i[1].ammo or 0) .. ' rounds in the first')")
            before = live_lib.mod_lua(ammo)
            c.send({"t": "shoot", "m": 1, "x": int(target["x"] * 256), "y": int(target["y"] * 256)})
            c.pump(0.1)
            c.send({"t": "shoot", "m": -1})
            c.pump(0.5, every=hello)
            print(f"  shot at {target['u']}: {before} -> {live_lib.mod_lua(ammo)}")
            shot = watch(units, 10, "after shot")

        print("INFO enemysight option B by hand: each idle biter's command re-issued as wander, distraction by_enemy, then the walk")
        units = setup()
        print("  set_command: " + lua(f"local r = {{}} for _, e in pairs(find({{ {', '.join(map(str, units))} }})) do "
                                     "local ok, err = pcall(function() e.commandable.set_command({ type = defines.command.wander, distraction = defines.distraction.by_enemy, radius = 3 }) end) "
                                     "r[#r + 1] = tostring(ok) .. (ok and '' or (' ' .. tostring(err))) end rcon.print(table.concat(r, ', '))"))
        c.pump(2.0, every=hello)
        show("after set_command", sample(units))
        approach(units, 20)
        opt_b = watch(units, 10, "B at 20")

        print("INFO enemysight option A by hand: set_distraction_command attack on the character for each biter within 30 tiles")
        units = setup()
        approach(units, 20)
        watch(units, 2, "A before")
        print("  set_distraction_command: " + lua(
            f"local r = {{ 'tick ' .. game.tick }} for _, e in pairs(find({{ {', '.join(map(str, units))} }})) do "
            "local d = math.sqrt((e.position.x - c.position.x) ^ 2 + (e.position.y - c.position.y) ^ 2) "
            "if d <= 30 then local ok, err = pcall(function() e.commandable.set_distraction_command({ type = defines.command.attack, target = c, distraction = defines.distraction.by_enemy }) end) "
            "r[#r + 1] = e.unit_number .. ' ' .. tostring(ok) .. (ok and '' or (' ' .. tostring(err))) end end rcon.print(table.concat(r, ', '))"))
        opt_a = watch(units, 10, "A after")

        print("INFO enemysight step 5: a small worm, approached to 3 tiles inside its range")
        worm_range = float(live_lib.mod_lua("rcon.print(prototypes.entity['small-worm-turret'].attack_parameters.range)"))
        print(f"  small-worm-turret attack range {worm_range}")
        worm = setup("small-worm-turret", n=1)
        c.pump(5.0, every=hello)
        show("worm after 5 s", sample(worm))
        approach(worm, worm_range + 8)
        watch(worm, 3, "worm outside range")
        approach(worm, worm_range - 3)
        worm_hit = watch(worm, 8, "worm in range")

        live_lib.clear_enemies(radius=200)
        live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {sx}, {sy} }}) local c = storage.f3d.puppet "
                "c.get_inventory(defines.inventory.character_guns).clear() c.get_inventory(defines.inventory.character_ammo).clear() storage.f3d.guns_sig = nil")

    # Script-made biters keep the wander command create_entity gives them and never settle, so they may not be
    # what the owner meets: the map's own nests' biters, left alone since the map was made, are.
    print("INFO enemysight step 6: the nearest nest the map made, approached from 90 tiles west in steps")
    nest = lua("local n = s.find_entities_filtered({ type = 'unit-spawner', force = 'enemy', position = c.position, radius = 900 }) "
               "if #n == 0 then s.request_to_generate_chunks(c.position, 20) s.force_generate_chunk_requests() "
               "n = s.find_entities_filtered({ type = 'unit-spawner', force = 'enemy', position = c.position, radius = 900 }) end "
               "local best = s.get_closest(c.position, n) if not best then rcon.print('none') return end "
               "local p = best.position local u = {} "
               "for _, e in pairs(s.find_entities_filtered({ force = 'enemy', type = { 'unit', 'turret', 'unit-spawner' }, position = p, radius = 32 })) do "
               "u[#u + 1] = e.unit_number end "
               "local area = { { p.x - 100, p.y - 6 }, { p.x - 8, p.y + 6 } } "
               "for _, e in pairs(s.find_entities_filtered({ area = area, type = { 'tree', 'simple-entity', 'cliff', 'fish' } })) do e.destroy() end "
               "local tiles = {} for _, t in pairs(s.find_tiles_filtered({ area = area, collision_mask = 'water_tile' })) do "
               "tiles[#tiles + 1] = { name = 'landfill', position = t.position } end if #tiles > 0 then s.set_tiles(tiles) end "
               "c.teleport({ p.x - 90, p.y }) "
               "rcon.print(p.x .. ' ' .. p.y .. ' ' .. table.concat(u, ' '))")
    nest_first = None
    if nest == "none" or not nest:
        print("  no nest within 900 tiles")
    else:
        nx, ny, *nest_units = nest.split()
        nx, ny, nest_units = float(nx), float(ny), [int(u) for u in nest_units]
        print(f"  nest at ({nx}, {ny}), {len(nest_units)} enemies within 32 tiles of it; the character at {nx - 90}")
        live_lib.watch_around(c, hello, nx - 90, ny)
        # A fresh map's nests own one biter each and spawn more on their own over the first minutes (seen live: about
        # 7 a spawner after 10 game minutes). Pollution would spawn them faster but sends them off as an attack group
        # (parent_group set, spawner lost), which enemy_sight leaves to the engine on purpose: not the sleeping nest a
        # player walks up to. So the game runs fast until the nest owns enough idle biters of its own, no pollution.
        own = f"{{ {nx}, {ny} }}"
        count = ("local sp = {} for _, e in pairs(s.find_entities_filtered({ type = 'unit-spawner', force = 'enemy', position = " + own
                 + ", radius = 20 })) do sp[e.unit_number] = true end local u = {} for _, e in pairs(s.find_entities_filtered({ force = 'enemy', "
                 "type = 'unit', position = " + own + ", radius = 32 })) do local cm = e.commandable local k = cm and cm.spawner "
                 "if k and k.valid and sp[k.unit_number] and not cm.parent_group then u[#u + 1] = e.unit_number end end "
                 "rcon.print(table.concat(u, ' '))")

        def grow():
            """The game fast until the nest owns 8 idle biters of its own (5 minutes at most): their unit numbers."""
            t0 = time.time()
            got = lua(count).split()
            if len(got) < 8:
                # Speed 1 again on any way out (an RCON or socket error, Ctrl+C), or the map runs ten times fast after.
                try:
                    lua("game.speed = 10")
                    while time.time() - t0 < 300:
                        c.pump(5.0, every=hello)
                        got = lua(count).split()
                        if len(got) >= 8:
                            break
                finally:
                    try:
                        lua("game.speed = 1")
                    except Exception as e:  # (a dead link mustn't hide the first error)
                        print(f"WARN enemysight step 6: game.speed not set back to 1 ({e}); set it by hand")
                c.pump(10.0, every=hello)  # settled at normal speed
                got = lua(count).split()
            print(f"  {len(got)} idle biters of the nest's own (spawner set, no group) after {time.time() - t0:.0f} s (game speed 10 meanwhile)")
            return [int(u) for u in got]

        nest_units += [u for u in grow() if u not in nest_units]
        show("nest, the character 90 tiles off", sample(nest_units))
        c.pump(20.0, every=hello)
        show("nest, 20 s later", sample(nest_units))
        fix = fix_compare(c, hello, lua, sample, show, rows_of, attacking, nest_units, nx, ny)
        # The car (enemy_sight_vehicle) last: the chase left the nest's biters far west, so they go and the nest grows
        # a fresh sleeping set first.
        lua("local sp = {} for _, e in pairs(s.find_entities_filtered({ type = 'unit-spawner', force = 'enemy', position = " + own
            + ", radius = 20 })) do sp[e.unit_number] = true end for _, e in pairs(s.find_entities_filtered({ force = 'enemy', "
            "type = 'unit', position = " + own + ", radius = 400 })) do local k = e.commandable and e.commandable.spawner "
            "if k and k.valid and sp[k.unit_number] then e.destroy() end end")
        car_units = grow()
        c.pump(20.0, every=hello)
        fix["car"] = car_compare(c, hello, sample, show, rows_of, car_units, nx, ny)
        nest_first = ("fix", fix)
        if old_nest:
            # The diagnostic's own approach (the switch off), from 90 tiles again.
            set_sight(False)
            live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {nx - 90}, {ny} }})")
            c.pump(20.0, every=hello)
            # 26 biters on the character: a big health bonus keeps it alive between the heals (it changes no targeting).
            live_lib.mod_lua("storage.f3d.puppet.character_health_bonus = 100000")
            for dist in (50, 40, 32, 26, 20, 14, 8):
                stop = nx - dist
                t0 = time.time()
                if c.me["x"] / 256 < stop:
                    c.pump(10.0, until=lambda m: m.get("t") == "me" and m["x"] / 256 >= stop, every=(0.15, {"t": "walk", "d": 4}))
                c.send({"t": "walk", "d": -1})
                c.pump(0.3, every=hello)
                show(f"walked to {dist} of the nest ({time.time() - t0:.1f} s)", sample(nest_units))
                first = watch(nest_units, 5, f"nest at {dist}", biters_only=True)
                if first:
                    nest_first = (dist,) + first
                    break
            if not nest_first:
                # Still asleep at 8 tiles: option B on half of the nest's biters, option A on the other half, at once.
                biters = sorted(r["u"] for r in rows_of(sample(nest_units)) if "cmd" in r)
                half_b, half_a = biters[0::2], biters[1::2]
                print("  option B (wander, by_enemy) on " + str(half_b) + ": " + lua(
                    f"local r = {{}} for _, e in pairs(find({{ {', '.join(map(str, half_b))} }})) do "
                    "r[#r + 1] = tostring(pcall(function() e.commandable.set_command({ type = defines.command.wander, distraction = defines.distraction.by_enemy, radius = 3 }) end)) end "
                    "rcon.print(table.concat(r, ' '))"))
                print("  option A (distraction attack on the character, within 30) on " + str(half_a) + ": " + lua(
                    f"local r = {{}} for _, e in pairs(find({{ {', '.join(map(str, half_a))} }})) do "
                    "local d = math.sqrt((e.position.x - c.position.x) ^ 2 + (e.position.y - c.position.y) ^ 2) "
                    "if d <= 30 then r[#r + 1] = tostring(pcall(function() e.commandable.set_distraction_command({ type = defines.command.attack, target = c, distraction = defines.distraction.by_enemy }) end)) end end "
                    "rcon.print(table.concat(r, ' '))"))
                for i in range(6):
                    c.pump(1.0, every=hello)
                    smp = sample(nest_units)
                    show(f"nest after options +{i + 1}s", smp)
                    att = set(attacking(smp, True))
                    print(f"    attacking: of B's {len(half_b)} {len(att & set(half_b))}, of A's {len(half_a)} {len(att & set(half_a))}")
                nest_first = ("options", sorted(att & set(half_b)), sorted(att & set(half_a)))
                # The owner's "until you shoot": one pistol round at one of B's biters, still asleep.
                asleep = [r for r in rows_of(sample(half_b)) if r.get("dis") == "nil"]
                if asleep:
                    t = min(asleep, key=lambda r: r["d"])
                    live_lib.mod_lua('local c = storage.f3d.puppet '
                            'c.get_inventory(defines.inventory.character_guns).clear() c.get_inventory(defines.inventory.character_ammo).clear() '
                            'c.get_inventory(defines.inventory.character_guns).insert({name = "pistol"}) '
                            'c.get_inventory(defines.inventory.character_ammo).insert({name = "firearm-magazine", count = 2}) '
                            'c.selected_gun_index = 1 storage.f3d.guns_sig = nil')
                    c.send({"t": "shoot", "m": 1, "x": int(t["x"] * 256), "y": int(t["y"] * 256)})
                    c.pump(0.1)
                    c.send({"t": "shoot", "m": -1})
                    print(f"  one shot at sleeping {t['u']} (d {t['d']}); B's {len(asleep)} still asleep before it")
                    woke = []
                    for i in range(5):
                        c.pump(1.0, every=hello)
                        smp = sample(half_b)
                        show(f"nest after the shot +{i + 1}s", smp)
                        woke = [r["u"] for r in rows_of(smp) if r.get("dis") != "nil"]
                        print(f"    of B's {len(half_b)}: {len(woke)} with a distraction, "
                              f"{len(set(attacking(smp, True)))} attacking the character, {t['u']} hp {next((r['hp'] for r in rows_of(smp) if r['u'] == t['u']), 'dead')}")
                    nest_first += (("shot", t["u"], len(woke)),)
                    live_lib.mod_lua("local c = storage.f3d.puppet c.get_inventory(defines.inventory.character_guns).clear() "
                            "c.get_inventory(defines.inventory.character_ammo).clear() storage.f3d.guns_sig = nil")
            live_lib.mod_lua("storage.f3d.puppet.character_health_bonus = 0")
            live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {sx}, {sy} }}) local c = storage.f3d.puppet c.health = c.max_health")
        c.pump(1.0, every=hello)
    print(f"INFO enemysight summary (first attack: seconds into the watch, tick, attackers, hp lost): walk to 20 -> {near20}; "
          f"walk to 8 -> {near8}; one shot -> {shot}; option B -> {opt_b}; option A -> {opt_a}; worm in range -> {worm_hit}; "
          f"the map's nest (distance, ...) -> {nest_first}")
    set_sight(True)
    live_lib.report(True, "enemysight: the diagnostic ran (its numbers are in the INFO lines)")
