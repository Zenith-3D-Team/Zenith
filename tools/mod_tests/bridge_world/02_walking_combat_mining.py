# Bridge test slice 02_walking_combat_mining.py (lines 1850-3604 of original test_bridge.py)
# --- walking ------------------------------------------------------------------------------------
puppet = g.storage.f3d.puppet
send({"t": "walk", "d": 3})  # odd: rounds to an even walking direction
tick(1)
check(puppet.walking_state.walking and puppet.walking_state.direction == 4, "walk command sets walking_state")
tick(40)
check(not puppet.walking_state.walking, "walking stops when the client stops repeating the command")
take()
# B7: an angle walks between the two 8-way directions either side of it, so the path follows it.
for a, want in ((55, (0, 2)), (125, (2,)), (980, (14, 0)), (600, (8, 10)), (250, (4,))):
    dirs = []
    for i in range(60):  # the fake session times out 600 ticks after its hello
        if i % 10 == 0:
            send({"t": "walk", "d": 2, "a": a})
        tick(1)
        dirs.append(puppet.walking_state.direction)
    sx = sum(math.sin(d / 16 * 2 * math.pi) for d in dirs)
    sy = sum(math.cos(d / 16 * 2 * math.pi) for d in dirs)
    got = math.degrees(math.atan2(sx, sy)) % 360
    off = abs((got - a * 0.36 + 180) % 360 - 180)
    check(set(dirs) <= set(want) and off < 1.5, f"walking at {a / 1000} turns steps {sorted(set(dirs))}, path {got:.2f} degrees ({off:.2f} off)")
mes = of_type(take(), "me")
check(mes and mes[-1].get("a") == 250 and mes[-1]["w"] == 1, f"me carries the walk's angle: {mes[-1:]}")
send({"t": "walk", "d": -1})
tick(1)
check(not puppet.walking_state.walking, "walk -1 stops an angled walk at once")
# A wall across the way north: the angle's north steps go nowhere, so the bridge takes the other
# direction each time and the character slides east along the wall instead of standing still
# (the drift is counted from the steps chosen, which a wall can stop).
F.walk_moves = True  # the fake character moves as it walks, as Factorio's does
walk_home = puppet.position
start = (puppet.position.x, puppet.position.y)
wall_y = start[1] - 0.5
F.walk_blocked = lambda x, y: y < wall_y
for i in range(60):
    if i % 10 == 0:
        send({"t": "walk", "d": 2, "a": 56})
    tick(1)
slid = puppet.position.x - start[0]
check(slid > 2.0 and puppet.position.y >= wall_y, f"an angled walk slides along a wall across its way: {slid:.2f} tiles east, y {puppet.position.y - start[1]:.2f}")
send({"t": "walk", "d": -1})
tick(1)
F.walk_blocked = None
F.walk_moves = False
puppet.teleport(walk_home)  # the checks after this one expect the character where it was
# 600 ticks in all for the wall, so the checks after it fall on the same ticks of the bridge's
# periodic jobs as before (several are timed).
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(600 - 61)
tick(4)
mes = of_type(take(), "me")
check(mes and "a" not in mes[-1], f"a stopped character's me has no angle: {mes[-1:]}")

# --- items on the ground ------------------------------------------------------------------------
def ground_items(msgs):
    l = [v for m in of_type(msgs, "gi") for v in m["l"]]
    return sorted(l[i:i + 3] for i in range(0, len(l), 3))


send({"t": "hello", "v": 1, "sid": "s1", "w": 1})  # keep-alive: the client times out after 600 ticks
plate_e = spawn("item-on-ground", 0.6, 0.3, stack={"name": "iron-plate", "count": 1})
gear_e = spawn("item-on-ground", -0.4, 0.9, stack={"name": "iron-gear-wheel", "count": 1})
wood_e = spawn("item-on-ground", 6.5, 0.5, stack={"name": "wood", "count": 1})  # out of pickup range
far_item = spawn("item-on-ground", 30.5, 0.5, stack={"name": "wood", "count": 1})  # outside the detail radius
tick(30)
msgs = take()
check(len(of_type(msgs, "gi")) == 1, f"ground items are sent every 30 ticks: {len(of_type(msgs, 'gi'))}")
expect = sorted([[iid["iron-plate"], fixed(0.6), fixed(0.3)], [iid["iron-gear-wheel"], fixed(-0.4), fixed(0.9)],
                 [iid["wood"], fixed(6.5), fixed(0.5)]])
check(ground_items(msgs) == expect, f"items on the ground near the focus are sent with item ids and positions: {ground_items(msgs)}")

inv = puppet.get_main_inventory()
before = {n: inv.get_item_count(n) for n in ("iron-plate", "iron-gear-wheel", "wood")}
for _ in range(3):
    send({"t": "pickup"})
    tick(9)
msgs = take()
check(not plate_e.valid and not gear_e.valid and wood_e.valid,
      "pickup takes the items within the character's item_pickup_distance, not the one further away")
check([inv.get_item_count(n) - before[n] for n in ("iron-plate", "iron-gear-wheel", "wood")] == [1, 1, 0],
      "picked-up items go to the inventory (mine_entity on the item-entity)")
ground_pku = sorted(tuple(r) for m in of_type(msgs, "pku") for r in m["l"])
check(ground_pku == sorted([("iron-plate", 1, fixed(0.6), fixed(0.3), 0, 0, 0, iid["iron-plate"]),
                            ("iron-gear-wheel", 1, fixed(-0.4), fixed(0.9), 0, 0, 0, iid["iron-gear-wheel"])]),
      f"issue #18: what F took off the ground is said at once (pku, no lane): {ground_pku}")
check(len(of_type(msgs, "gi")) >= 4, f"ground items are sent every detail interval while picking up: {len(of_type(msgs, 'gi'))}")
check(ground_items(of_type(msgs, "gi")[-1:]) == [[iid["wood"], fixed(6.5), fixed(0.5)]], "picked-up items drop out of the list")
tick(40)
check(g.storage.f3d.pickup is None, "pickup stops when the client stops repeating it")
take()
tick(120)
# By the gaps between sends, not a count in a window: where the window falls against the 30-tick beat
# (shifted by the checks before) gives 4 or 5 sends in 120 ticks.
_ks = [m.get("k") for m in of_type(take(), "gi")]
_gaps = [b - a for a, b in zip(_ks, _ks[1:])]
check(len(_ks) >= 4 and all(25 <= d <= 35 for d in _gaps), f"and ground items go back to twice a second: {_gaps}")

F.inventory_space = 0
full_e = spawn("item-on-ground", 0.2, -0.5, stack={"name": "iron-plate", "count": 1})
for _ in range(4):
    send({"t": "pickup"})
    tick(9)
msgs = take()
fulls = [m for m in of_type(msgs, "msg") if m["text"] == "Inventory full"]
check(full_e.valid and len(fulls) == 1, f"a full inventory leaves the item and says so once per press: {len(fulls)} messages")
F.inventory_space = float("inf")
tick(40)
send({"t": "pickup"})
tick(9)
check(not full_e.valid, "pickup works again after letting go")
take()
# J18: the right button on an item lying on the ground picks it up at once (`mine` with `gi`, by
# where it lies), within reach; the walk isn't held for it.
rc_e = spawn("item-on-ground", 3.2, 0.4, stack={"name": "iron-plate", "count": 1})
plates0 = inv.get_item_count("iron-plate")
send({"t": "mine", "gi": 1, "x": fixed(3.25), "y": fixed(0.42)})
tick(1)
check(not rc_e.valid and inv.get_item_count("iron-plate") == plates0 + 1 and g.storage.f3d.mining is None,
      "J18: mine with gi picks up the item lying nearest the point, at once")
rc_far = spawn("item-on-ground", 25.5, 0.5, stack={"name": "iron-plate", "count": 1})
send({"t": "mine", "gi": 1, "x": fixed(25.5), "y": fixed(0.5)})
tick(1)
check(rc_far.valid and any(m["text"] == "Out of reach" for m in of_type(take(), "msg")),
      "J18: an item out of reach stays, and says so")
rc_far.destroy()
send({"t": "mine", "gi": 1, "x": fixed(9.5), "y": fixed(9.5)})
tick(1)
check(g.storage.f3d.mining is None, "J18: mine with gi where nothing lies does nothing")
take()
g.settings["global"]["f3d-detail-radius"].value = 0
tick(60)
check(not of_type(take(), "gi"), "radius 0 turns ground items off")
g.settings["global"]["f3d-detail-radius"].value = 24
for e in (wood_e, far_item):
    e.destroy()
tick(30)
check([m["l"] for m in of_type(take(), "gi")] == [[]], "an empty update means no items on the ground")

# --- combat -------------------------------------------------------------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})  # keep-alive: the client times out after 600 ticks
shooting = g.defines.shooting
gun_slots, ammo_slots = F.slots[puppet].guns, F.slots[puppet].ammo
g.storage.f3d.guns_sig = None
tick(11)  # checked every 10 ticks; reliable messages go out on the next tick
msgs = take()
guns = of_type(msgs, "guns")
check(guns and guns[-1]["sel"] == 1 and [r[:3] for r in guns[-1]["l"]] == [["pistol", "firearm-magazine", 10], ["", "", 0], ["", "", 0]],
      f"guns: the starter pistol and magazines, per gun slot: {guns[-1:]}")
check(guns and guns[-1]["l"][0][4] == 10 and guns[-1]["l"][1][3:] == [0, 0],
      f"guns: rounds left and the magazine size for the ammo slot's bar: {guns[-1:]}")
me = of_type(msgs, "me")[-1]
check(me.get("mhp") == 250 and me.get("sh") == 0, f"me carries max health and whether the character is firing: {me}")
check("fl" not in me and "fh" not in me, f"me has no fl or fh while the character is on the ground: {me}")
puppet.is_flying = True
puppet.flight_height = 0.8125
tick(2)
flying = of_type(take(), "me")[-1]
check(flying.get("fl") == 1 and flying.get("fh") == 813, f"me: fl 1 and fh in thousandths of a tile while flying in mech armour: {flying}")
puppet.is_flying = False
puppet.flight_height = 0
tick(2)
landed = of_type(take(), "me")[-1]
check("fl" not in landed and "fh" not in landed, f"me: fl and fh go once landed: {landed}")

biter = spawn("small-biter", 3.0, 0.0, force="enemy")
send({"t": "shoot", "m": 0, "x": 3 * 256, "y": 0})
tick(2)
st = puppet.shooting_state
check(st.state == shooting.shooting_enemies and st.position.x == 3.0, "shoot m=0 sets shooting_state to shooting_enemies")
ammo_slots[1].ammo = 9  # the game fired a round
tick(4)  # me goes out every 2 ticks, before combat looks at the ammo
msgs = take()
check(of_type(msgs, "me")[-1].get("sh") == 1, "me.sh is 1 once the ammo goes down")
shots = of_type(msgs, "shot")
check(len(shots) == 1 and shots[0]["g"] == "pistol" and shots[0]["a"] == "firearm-magazine"
      and (shots[0]["x"], shots[0]["y"]) == (3 * 256, 0) and shots[0]["u"] == puppet.unit_number,
      f"shot: the round fired, with the gun, ammo and the nearest enemy (find_nearest_enemy) as its target: {shots}")
tick(10)
guns = of_type(msgs + take(), "guns")
check(guns and guns[-1]["l"][0][3:] == [9, 10], f"guns: a round fired shows in the magazine's rounds: {guns[-1:]}")
send({"t": "shoot", "m": 1, "x": 3 * 256, "y": 256})
tick(2)
st = puppet.shooting_state
check(st.state == shooting.shooting_selected and st.position.y == 1.0, "shoot m=1 shoots at the aim point (shooting_selected)")
tick(40)
check(puppet.shooting_state.state == shooting.not_shooting, "shooting stops when the client stops repeating it")

# --- enemies notice the player-less character (enemy_sight.lua, /f3d-perf enemy_sight) ----------------------
# A nest's idle biters ignored a character with no player in 2.1.24 until it shot; a real player's woke them.
# Every 30 ticks (phase 17), as measured for a real player's: a sleeping unit within its own prototype's vision
# of it wakes (attack it, by_enemy) with every sleeping unit of its nest; held while it stands, dropping off over
# about 40 s by unit number; kept on it while it moves and they're within their vision, with no leash; nothing out
# of vision, with a player, peaceful, not destructible, or the switch off. Not those already distracted, attacking
# something of their own, in a unit group, or whose command takes no distraction.
es_mod = g.package.loaded["scripts.enemy_sight"]


def es_new():
    return list(F.distractions.values()) if F.distractions else []


def es_for(unit):
    return [d for d in es_new() if d.unit.unit_number == unit.unit_number]


def es_given():
    return sorted({d.unit.unit_number for d in es_new()})


def es_phase(fade=False, units=()):
    g.storage.f3d.client.last_seen = g.game.tick  # (the client's hellos, so the long waits don't drop it)
    if fade:  # the engine's distraction ends on its own (3-6 s live): taken off before each pass
        for u in units:
            u.commandable.distraction_command = None
    tick(30)  # every 30 ticks on its own phase: one pass within any 30


def es_reset(units):
    for u in units:
        u.commandable.distraction_command = None
    g.storage.f3d.sight = None
    F.distractions = None


es_c = g.storage.f3d.puppet
es_home = es_c.position
cx, cy = es_home.x, es_home.y
es_attack, es_by_enemy = g.defines.command.attack, g.defines.distraction.by_enemy
# Units the earlier checks left near the character are out of the way of these counts.
# (given a distraction for the while, put back at the end)
es_old = [(e, e.commandable.distraction_command) for e in F.surface.entities.values() if e.valid and e.type == "unit"]
for e, _ in es_old:
    e.commandable.distraction_command = lua.table_from({"type": g.defines.command.attack, "target": e})
lua.execute("""
function F_deepcopy(v)
  if type(v) ~= "table" then return v end
  local o = {}
  for k, x in pairs(v) do o[k] = F_deepcopy(x) end
  return o
end
function F_serialize(v)
  if type(v) ~= "table" then return tostring(v) end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. "=" .. F_serialize(v[k]) end
  return "{" .. table.concat(out, ",") .. "}"
end
""")

# A nest 40 tiles west: its spawner, one unit in vision (25 from the character), one beside the spawner out of
# vision (45), one of its units already attacking something else; and round the character the units to leave.
es_sp = spawn("biter-spawner", cx - 40.0, cy, force="enemy")
es_in = spawn("small-biter", cx - 25.0, cy, force="enemy")
es_far = spawn("small-biter", cx - 45.0, cy + 3.0, force="enemy")
es_nbusy = spawn("small-biter", cx - 42.0, cy - 3.0, force="enemy")
es_out = spawn("small-biter", cx + 25.0, cy + 25.0, force="enemy")   # loose, in the search square, 35 away
es_busy = spawn("small-biter", cx, cy + 10.0, force="enemy")         # already distracted
es_own = spawn("small-biter", cx + 5.0, cy + 10.0, force="enemy")    # an attack command of its own
es_grouped = spawn("small-biter", cx, cy - 10.0, force="enemy")      # in a unit group
es_none = spawn("small-biter", cx + 10.0, cy, force="enemy")         # its command takes no distraction
es_mine = spawn("small-biter", cx - 10.0, cy - 10.0, force="player")  # the character's own force
for u in (es_in, es_far, es_nbusy):
    u.commandable.spawner = es_sp
    u.commandable.command = lua.table_from({"type": g.defines.command.wander, "distraction": es_by_enemy})
es_nbusy.commandable.distraction_command = lua.table_from({"type": es_attack, "target": es_out})
es_busy.commandable.distraction_command = lua.table_from({"type": es_attack, "target": es_out})
es_own.commandable.command = lua.table_from({"type": es_attack, "target": es_out})
es_grouped.commandable.parent_group = lua.table_from({"valid": True})
es_none.commandable.command = lua.table_from({"type": g.defines.command.wander, "distraction": g.defines.distraction.none})
es_all = [es_in, es_far, es_nbusy, es_out, es_busy, es_own, es_grouped, es_none, es_mine]
F.distractions = None
es_phase()
dis = es_in.commandable.distraction_command
check(dis is not None and dis.type == es_attack and dis.distraction == es_by_enemy
      and dis.target.unit_number == es_c.unit_number,
      "enemy_sight: a unit within its vision of the player-less character is given attack it, by_enemy")
check(es_far.commandable.distraction_command is not None and es_far.commandable.distraction_command.target.unit_number == es_c.unit_number,
      "enemy_sight: its nest's sleeping unit out of vision wakes with it (the whole nest, as for a real player)")
check(es_given() == sorted([es_in.unit_number, es_far.unit_number]),
      f"enemy_sight: none for one outside its vision, already distracted, attacking of its own, in a group, with "
      f"distraction none, or the character's own force: {len(es_new())} given")
check(es_busy.commandable.distraction_command.target.unit_number == es_out.unit_number
      and es_nbusy.commandable.distraction_command.target.unit_number == es_out.unit_number,
      "enemy_sight: a unit's own distraction left alone (in the nest too)")
woke = es_for(es_in)[0].tick
check(g.storage.f3d.sight.units[es_in.unit_number].first == woke, "enemy_sight: what it woke is kept in storage by unit number")

# The vision distance is the unit's own prototype's: a harness unit that sees 12 tiles wakes at 11, not at 14.
es_short = spawn("f3d-test-short-sighted", cx + 14.0, cy, force="enemy")
F.distractions = None
es_phase()
check(not es_for(es_short), "enemy_sight: a unit seeing 12 tiles (its prototype) doesn't wake 14 tiles off")
es_short.teleport(lua.table_from({"x": cx + 11.0, "y": cy}))
es_phase()
check(len(es_for(es_short)) == 1, "enemy_sight: it wakes 11 tiles off, within its prototype's vision_distance")
es_short.destroy()

# The holds: spread over unit numbers as the real player's two runs dropped off (half by 8-10 s); re-giving ends
# by 15 s, the engine's own tail (live: 3 of 12 still on it at 40 s with nothing re-given) doing the rest.
hold = [es_mod.hold_ticks(n) + es_mod.FADE_TICKS for n in range(1, 1001)]
by9 = sum(h <= 9 * 60 for h in hold) / 1000
past12 = sum(h > 12 * 60 for h in hold) / 1000
check(0.45 <= by9 <= 0.6 and 0.1 <= past12 <= 0.3 and max(hold) <= 15 * 60 and min(hold) >= 150,
      f"enemy_sight: holds spread as measured: {by9:.2f} gone by 9 s, {past12:.2f} past 12 s, {min(hold)}-{max(hold)} ticks")

# A standing character, a nest of 14 (consecutive unit numbers, as a nest's are): each pass the engine's
# distraction has ended; the bridge gives it again only within each unit's hold, so they drop off gradually.
for e in es_all:
    e.destroy()
es_nest = [spawn("small-biter", cx - 20.0 - (i % 4), cy - 6.0 + i, force="enemy") for i in range(14)]
for u in es_nest:
    u.commandable.spawner = es_sp
es_reset(es_nest)
start = g.game.tick
on = []
for p in range(100):  # 50 s
    F.distractions = None
    es_phase(fade=p > 0, units=es_nest)
    on.append((g.game.tick - start, len(es_given())))
at = lambda secs: max([n for t, n in on if t <= secs * 60 + 30 and t > secs * 60 - 30] or [0])
# (Given again at t: still attacking until at least t + FADE_TICKS, the engine's own fade; live, some far longer.)
es_curve = [at(s) for s in (2, 5, 10, 12, 15, 20, 47)]
check(on[0][1] == 14 and es_curve == sorted(es_curve, reverse=True) and at(2) >= 10 and 2 <= at(10) <= 6
      and at(12) >= 1 and at(15) == 0 and at(47) == 0,
      f"enemy_sight: standing, held and dropping off gradually, re-giving over by 15 s: given again {es_curve} at 2-47 s")

# The chase: the character runs off (a tile and a half a pass) with the nest behind it, to 450 tiles from the
# nest. Those within their vision are kept on it every pass, the ones that had dropped off rejoin; no leash.
es_back = es_nest[:3]  # three fall behind
chased = []
for p in range(300):
    x = cx + 1.5 * (p + 1)
    es_c.teleport(lua.table_from({"x": x, "y": cy}))
    for i, u in enumerate(es_nest):
        if u not in es_back:
            u.teleport(lua.table_from({"x": x - 10.0 - (i % 4), "y": cy - 6.0 + i}))
    F.distractions = None
    es_phase(fade=True, units=es_nest)
    chased.append(len(es_given()))
check(min(chased) == 11 and chased[-1] == 11 and abs(es_c.position.x - es_sp.position.x) > 400,
      f"enemy_sight: chasing, kept on it within vision with no leash, 450 tiles out: {min(chased)}-{max(chased)} a pass")
check(not any(es_for(u) for u in es_back), "enemy_sight: the ones fallen behind (out of vision) are left")

# Out of vision: units 37 tiles off for 20 s, nothing (the real player's run woke nothing at 37).
for e in es_nest:
    e.destroy()
es_c.teleport(es_home)
es_far37 = [spawn("small-biter", cx - 37.0, cy + i, force="enemy") for i in range(3)]
for u in es_far37:
    u.commandable.spawner = es_sp
es_reset(es_far37)
for _ in range(40):
    es_phase()
check(not es_new(), "enemy_sight: nothing wakes with the character 37 tiles off for 20 s")
for e in es_far37:
    e.destroy()

# Determinism: two runs of a pass from the same storage (one with the module's prototype caches forgotten, as a
# peer that loaded the save would have them) give the same commands.
es_det = [spawn("small-biter", cx - 20.0 - i, cy + (i % 5), force="enemy") for i in range(8)]
for u in es_det:
    u.commandable.spawner = es_sp
es_reset(es_det)
for _ in range(6):
    es_phase(fade=True, units=es_det)
es_c.teleport(lua.table_from({"x": cx + 2.0, "y": cy}))
for _ in range(8):
    es_phase(fade=True, units=es_det)
es_c.teleport(es_home)
for _ in range(10):
    es_phase(fade=True, units=es_det)
lua.execute("F_es_saved = F_deepcopy(storage.f3d.sight)")
run_at = g.game.tick
while (run_at + 17) % 30:
    run_at += 1


def es_run(forget_caches):
    lua.execute("storage.f3d.sight = F_deepcopy(F_es_saved)")
    for u in es_det:
        u.commandable.distraction_command = None
    if forget_caches:
        check(forget(es_mod.tick, "vision_of_name") and forget(es_mod.tick, "search_radius") is not None,
              "enemy_sight: its prototype caches can be forgotten")
    F.distractions = None
    g.game.tick = run_at
    es_mod.tick()
    return [(d.unit.unit_number, d.tick) for d in es_new()], lua.eval("F_serialize(storage.f3d.sight)")


first = es_run(False)
second = es_run(True)
check(first == second and first[0], f"enemy_sight: two runs from the same storage give the same commands: {first[0]} / {second[0]}")
g.game.tick = run_at

# Nothing when the character can't be sighted as a player's could, or with the switch off (and the records go).
es_in = es_det[0]


def es_none_given(what):
    es_reset(es_det)
    for _ in range(4):
        es_phase()
    check(not es_new(), f"enemy_sight: nothing given {what}")


es_c.destructible = False
es_none_given("to a character that isn't destructible")
check(g.storage.f3d.sight is None, "enemy_sight: the records go when there's nothing to do")
es_c.destructible = True
F.surface.peaceful_mode = True
es_none_given("in peaceful mode")
F.surface.peaceful_mode = False
F.surface.no_enemies_mode = True
es_none_given("in no-enemies mode")
F.surface.no_enemies_mode = False
# (puppet.player_of answers for the character: hybrid single-player's, or an L13 claimed player's.)
lua.execute('F_es_po = package.loaded["scripts.puppet"].player_of; package.loaded["scripts.puppet"].player_of = function() return {} end')
es_none_given("to a character with a real player (the engine sees those)")
lua.execute('package.loaded["scripts.puppet"].player_of = F_es_po')
# In a vehicle (enemy_sight_vehicle): a car, tank or spidertron it drives or rides is the target, as a real player's
# in one is attacked; the same vision, nest and holds, counted from the vehicle. Not a train (not a military target),
# not a vehicle a real player shares (the engine's), not one that isn't destructible; nothing with the switch off.


def es_targets():
    return sorted({d.command.target.unit_number for d in es_new()})


es_sp_det = es_det[0].commandable.spawner
for es_name in ("car", "tank", "spidertron"):
    es_v = spawn(es_name, cx, cy, force="player")
    es_v.set_driver(es_c)
    es_reset(es_det)
    es_phase()
    check(es_targets() == [es_v.unit_number] and len(es_given()) == len(es_det),
          f"enemy_sight: a character driving a {es_name}: its nest wakes, attacking the {es_name} "
          f"({len(es_given())} of {len(es_det)} given, targets {es_targets()})")
    es_v.set_driver(None)
    es_v.destroy()
    es_c.teleport(es_home)
# Riding as a passenger, the same; standing in the car, held and then dropped (the holds counted from the car).
es_car = spawn("car", cx, cy, force="player")
es_car.set_passenger(es_c)
es_reset(es_det)
es_phase()
check(es_targets() == [es_car.unit_number], "enemy_sight: a character riding a car as its passenger: the car is the target")
es_held = []
for _ in range(40):
    F.distractions = None
    es_phase(fade=True, units=es_det)
    es_held.append(len(es_given()))
check(es_held[0] >= 1 and es_held[-1] == 0 and es_held == sorted(es_held, reverse=True),
      f"enemy_sight: a parked car's attackers are held and drop off as on foot: {es_held[:4]}..{es_held[-2:]}")
# Getting out: the units still on the car are given the character (that pass), and back in, the car again.
es_reset(es_det)
es_phase()
es_car.set_passenger(None)
F.distractions = None
es_phase()
check(es_targets() == [es_c.unit_number] and len(es_given()) == len(es_det),
      f"enemy_sight: getting out, the woken on the car are given the character: {len(es_given())} given, {es_targets()}")
es_car.set_driver(es_c)
F.distractions = None
es_phase()
check(es_targets() == [es_car.unit_number] and len(es_given()) == len(es_det),
      f"enemy_sight: getting back in, they are given the car: {len(es_given())} given, {es_targets()}")
# A car that isn't destructible; a real player in the other seat (puppet.player_of answers for that one only).
es_car.destructible = False
es_none_given("in a car that isn't destructible")
es_car.destructible = True
es_other = spawn("character", cx + 1.0, cy, force="player")
es_car.set_passenger(es_other)
lua.execute('F_es_po = package.loaded["scripts.puppet"].player_of')
g.F_es_other = es_other
lua.execute('package.loaded["scripts.puppet"].player_of = function(c) if c == F_es_other then return {} end return F_es_po(c) end')
es_none_given("in a car a real player rides too (the engine sees that one)")
lua.execute('package.loaded["scripts.puppet"].player_of = F_es_po')
es_car.set_passenger(None)
es_other.destroy()
F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "enemy_sight_vehicle off"}))
es_none_given("in a car with /f3d-perf enemy_sight_vehicle off, as before")
es_car.set_driver(None)
es_reset(es_det)
es_phase()
check(es_targets() == [es_c.unit_number], "enemy_sight: with enemy_sight_vehicle off, on foot as before")
F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "enemy_sight_vehicle default"}))
es_car.destroy()
es_c.teleport(es_home)
# A train: rolling stock isn't a military target, and biters don't go for a passing train.
es_loco = spawn("locomotive", cx, cy, force="player")
es_loco.set_driver(es_c)
es_none_given("to a character in a locomotive (not a military target)")
es_loco.set_driver(None)
es_loco.destroy()
es_c.teleport(es_home)
lua.execute('F_es_hub = package.loaded["scripts.puppet"].hub; package.loaded["scripts.puppet"].hub = function(c) return c end')
es_none_given("to a character on a platform's hub")
lua.execute('package.loaded["scripts.puppet"].hub = F_es_hub')
F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "enemy_sight off"}))
es_none_given("with /f3d-perf enemy_sight off, as before")
F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "enemy_sight default"}))
es_reset(es_det)
es_phase()
check(len(es_for(es_in)) == 1, "enemy_sight: given again with the switch back on")
for e in es_det:
    e.destroy()
es_sp.destroy()

# MAX_NESTS (4) a pass: five nests in vision at once. Four wake in the first pass, each unit in vision with its
# spawner's unit out of vision; the fifth's unit waits with no record and wakes its nest in the next pass.
es_five = []
for i in range(5):
    a = i * math.tau / 5
    ux, uy = math.cos(a), math.sin(a)
    sp = spawn("biter-spawner", cx + 40.0 * ux, cy + 40.0 * uy, force="enemy")
    near = spawn("small-biter", cx + 25.0 * ux, cy + 25.0 * uy, force="enemy")
    back = spawn("small-biter", cx + 45.0 * ux, cy + 45.0 * uy, force="enemy")
    for u in (near, back):
        u.commandable.spawner = sp
    es_five.append((sp, near, back))
es_five_units = [u for _, n, b in es_five for u in (n, b)]
es_reset(es_five_units)
es_phase()
first_pass = es_given()
F.distractions = None
es_phase()
second_pass = es_given()
woke_nests_of = lambda nests, given: sorted(i for i, (_, n, b, *_) in enumerate(nests) if n.unit_number in given and b.unit_number in given)
woke_nests = lambda given: sorted(i for i, (_, n, b) in enumerate(es_five) if n.unit_number in given and b.unit_number in given)
check(len(woke_nests(first_pass)) == 4 and len(first_pass) == 8,
      f"enemy_sight: four nests (MAX_NESTS) wake in one pass, whole: {woke_nests(first_pass)}, {len(first_pass)} given")
check(len(woke_nests(second_pass)) == 1 and len(second_pass) == 2
      and sorted(woke_nests(first_pass) + woke_nests(second_pass)) == [0, 1, 2, 3, 4],
      f"enemy_sight: the fifth nest wakes in the next pass, whole (not lost to the cap): {woke_nests(second_pass)}")
for sp, n, b in es_five:
    for e in (sp, n, b):
        e.destroy()

# A spawning nest is no new nest: its spawners are kept after the wake, so a fresh unit of it (a new spawn, held
# busy until now) is given alone, with no spawner search and no place under MAX_NESTS. Four nests woken, each with
# a new unit every pass ahead of the fifth's unit in find_units' order: the fifth still wakes, whole.
es_sn = []
for i in range(5):
    a = i * math.tau / 5
    ux, uy = math.cos(a), math.sin(a)
    sp = spawn("biter-spawner", cx + 40.0 * ux, cy + 40.0 * uy, force="enemy")
    near = spawn("small-biter", cx + 25.0 * ux, cy + 25.0 * uy, force="enemy")
    back = spawn("small-biter", cx + 45.0 * ux, cy + 45.0 * uy, force="enemy")
    new = [spawn("small-biter", cx + (20.0 + j) * ux, cy + (20.0 + j) * uy, force="enemy") for j in range(2)] if i < 4 else []
    for u in [near, back] + new:
        u.commandable.spawner = sp
    es_sn.append((sp, near, back, new))
es_sn_units = [u for _, n, b, new in es_sn for u in [n, b] + new]
es_reset(es_sn_units)
for _, _, _, new in es_sn:
    for u in new:
        u.commandable.distraction_command = lua.table_from({"type": es_attack, "target": u})
es_phase()
check(sorted(woke_nests_of(es_sn, es_given())) == [0, 1, 2, 3], "enemy_sight: (four spawning nests woken first)")
es_sn_finds = []
for j in range(2):
    for _, _, _, new in es_sn[:4]:
        new[j].commandable.distraction_command = None
    F.distractions = None
    F.finds = lua.table_from({})
    es_phase()
    es_sn_finds.append((F.finds.find_units or 0, es_given()))
    F.finds = None
es_sn_new = sorted(new[0].unit_number for _, _, _, new in es_sn[:4])
check(woke_nests_of(es_sn, es_sn_finds[0][1]) == [4]
      and sorted(set(es_sn_finds[0][1]) - {es_sn[4][1].unit_number, es_sn[4][2].unit_number}) == es_sn_new,
      f"enemy_sight: four nests each with a new unit a pass, the fifth still wakes, whole: {es_sn_finds[0][1]}")
# (one find_units a pass for the character, one more per nest woken: a nest's search is its spawner search and
# its find_units together; the spawner searches can't be counted alone, planets.lua lists spawners too)
check(es_sn_finds[0][0] == 2 and es_sn_finds[1][0] == 1
      and sorted(es_sn_finds[1][1]) == sorted(new[1].unit_number for _, _, _, new in es_sn[:4]),
      f"enemy_sight: a spawning nest's new unit is given alone, its nest not searched again: "
      f"find_units {es_sn_finds[0][0]} a pass, then {es_sn_finds[1][0]}")
for sp, n, b, new in es_sn:
    for e in [sp, n, b] + new:
        e.destroy()

# The nest is its spawners' cluster: a nest of two spawners 10 tiles apart wakes together; a second nest's idle
# unit inside the 45-tile circle round the first spawner, its own spawner 36 tiles off (more than NEST_EXTRA),
# stays asleep while its own units can't see the character (58 tiles off).
es_a1 = spawn("biter-spawner", cx - 40.0, cy, force="enemy")
es_a2 = spawn("biter-spawner", cx - 40.0, cy + 10.0, force="enemy")
es_b = spawn("biter-spawner", cx - 60.0, cy - 30.0, force="enemy")
es_ua1 = spawn("small-biter", cx - 25.0, cy, force="enemy")         # in vision, of a1
es_ua2 = spawn("small-biter", cx - 45.0, cy + 12.0, force="enemy")  # out of vision, of a2
es_ub = spawn("small-biter", cx - 55.0, cy - 20.0, force="enemy")   # 25 from a1, of b
es_ua1.commandable.spawner = es_a1
es_ua2.commandable.spawner = es_a2
es_ub.commandable.spawner = es_b
es_cl = [es_ua1, es_ua2, es_ub]
es_reset(es_cl)
for _ in range(3):
    es_phase()
check(es_for(es_ua1) and es_for(es_ua2), "enemy_sight: both spawners of one nest (10 tiles apart) wake their units together")
check(not es_for(es_ub), "enemy_sight: a neighbouring nest's unit inside the circle, its spawner past NEST_EXTRA, stays asleep")
for e in es_cl + [es_a1, es_a2, es_b]:
    e.destroy()
for e, d in es_old:
    e.commandable.distraction_command = d
F.distractions = None
check(of_type(take(), "me")[-1].get("sh") == 0, "and me.sh goes back to 0")
send({"t": "shoot", "m": 0, "x": 0, "y": 0})
tick(2)
send({"t": "shoot", "m": -1})
tick(2)
check(puppet.shooting_state.state == shooting.not_shooting, "shoot m=-1 stops at once")
take()
# Only enemies of the character's force are aimed at (LuaForce::is_enemy), not any force but neutral:
# the biter, once of a friendly force, is not selected.
g.rawset(biter, "force", g.game.forces.ally)
send({"t": "shoot", "m": 1, "x": 3 * 256, "y": 0})
tick(2)
check(puppet.shooting_state.state == shooting.shooting_enemies, "shoot m=1 on a friendly force's unit does not select it")
send({"t": "shoot", "m": -1})
tick(2)
g.rawset(biter, "force", g.game.forces.enemy)
take()

enemy_chest = spawn("wooden-chest", 2.5, 2.5, force="enemy")
biter.health, enemy_chest.health = 6, 50
for e in (biter, enemy_chest):
    F["raise"]("on_entity_damaged", lua.table_from({"entity": e}))
tick(10)
hp = [m["l"] for m in of_type(take(), "hp")]
check(hp and sorted(zip(hp[-1][::2], hp[-1][1::2])) == sorted([(biter.unit_number, 60), (enemy_chest.unit_number, 500)]),
      f"hp: damaged entities near the camera with their health in thousandths: {hp[-1:]}")
enemy_chest.health = 100
tick(10)
hp = [m["l"] for m in of_type(take(), "hp")]
check(hp and hp[-1] == [biter.unit_number, 60], f"an entity back at full health drops out: {hp[-1:]}")
focus_was = g.storage.f3d.focus
g.storage.f3d.focus = lua.table_from({"x": 900, "y": 900, "r": 32})
tick(10)
hp = [m["l"] for m in of_type(take(), "hp")]
check(hp and hp[-1] == [], f"hp: a damaged entity out of the focus square isn't sent: {hp[-1:]}")
g.storage.f3d.focus = focus_was
tick(10)
hp = [m["l"] for m in of_type(take(), "hp")]
check(hp and hp[-1] == [biter.unit_number, 60], f"hp: an entity damaged earlier shows its bar again when the camera comes back: {hp[-1:]}")
unit = biter.unit_number
for e in (biter, enemy_chest):
    F["raise"]("on_entity_died", lua.table_from({"entity": e}))
    e.destroy()
tick(10)
msgs = take()
died = [(m["u"], m["p"], m["x"], m["y"]) for m in of_type(msgs, "died")]
check((unit, eid["small-biter"], 3 * 256, 0) in died, f"died: a biter's death is reported where it died: {died}")
check(any(d["p"] == eid["wooden-chest"] for d in of_type(msgs, "del")) and any(d[1] == eid["wooden-chest"] for d in died),
      "a building that dies is deleted and its death reported")
check([m["l"] for m in of_type(msgs, "hp")][-1:] == [[]], "the dead biter drops out of hp")

# K13: repair packs. With one in the hand, the left button held on a damaged building of the character's force
# within reach mends it (repair.lua): the pack's speed (2) health a unit of durability, a unit a tick, times the
# target's repair_speed_modifier (walls 2), the pack used up as it goes; its health bar (`hp`) rises with it.
main = puppet.get_main_inventory()
main.insert(lua.table_from({"name": "repair-pack", "count": 2}))
chest_r = spawn("wooden-chest", 3.5, 1.5, force="player")
wall_r = spawn("stone-wall", 4.5, 1.5, force="player")


def repair_cmd(e, **extra):
    return {"t": "repair", "u": e.unit_number, "p": eid[e.name], "x": fixed(e.position.x), "y": fixed(e.position.y),
            "item": "repair-pack", **extra}


def pack_stack():
    found = main.find_item_stack("repair-pack")  # (stack, index), or nil
    return found[0] if isinstance(found, tuple) else found


def pack():
    stack = pack_stack()
    return (stack.count, stack.durability) if stack else None


chest_r.health = 70
send(repair_cmd(chest_r))
tick(5)
msgs = take()
me = of_type(msgs, "me")
check(chest_r.health == 80 and pack() == (2, 295),
      f"K13: repairing mends 2 health a tick, a unit of the pack's durability each: {chest_r.health} {pack()}")
check(me and me[-1].get("rp") == 1 and me[-1].get("rx") == fixed(3.5) and me[-1].get("ry") == fixed(1.5),
      f"K13: me says the character repairs, and where: {me[-1:]}")
tick(15)
msgs += take()
check(chest_r.health == 100 and pack() == (2, 285), f"K13: it stops at full health, using no more: {chest_r.health} {pack()}")
check(of_type(msgs, "me") and "rp" not in of_type(msgs, "me")[-1], "K13: me no longer says it repairs once it is mended")
tick(10)
msgs += take()
hp_seen = [dict(zip(m["l"][::2], m["l"][1::2])).get(chest_r.unit_number) for m in of_type(msgs, "hp")]
check(any(v is not None and 700 <= v < 1000 for v in hp_seen) and hp_seen[-1] is None,
      f"K13: its health bar rises (one damaged before the bridge saw it too) and goes at full health: {hp_seen}")
wall_r.health = 20
send(repair_cmd(wall_r, hs=1))
tick(5)
check(wall_r.health == 40 and pack() == (2, 280), f"K13: a wall mends twice as fast (repair_speed_modifier 2): {wall_r.health} {pack()}")
send({"t": "repair"})
tick(5)
check(wall_r.health == 40 and g.storage.f3d.repair is None, f"K13: a repair without a target stops at once: {wall_r.health}")
chest_r.health = 10
send(repair_cmd(chest_r))
tick(40)
held = (chest_r.health - 10) / 2
check(held in (30, 31) and pack() == (2, 280 - held),
      f"K13: a command lasts 30 ticks unless the client repeats it: {chest_r.health} {pack()}")
pack_stack().durability = 3
chest_r.health = 50
send(repair_cmd(chest_r))
tick(5)
check(chest_r.health == 60 and pack() == (1, 298), f"K13: a pack used up, the next one goes on: {chest_r.health} {pack()}")
send({"t": "repair"})
take()
tick(30)
slots = of_type(take(), "slots")
packs = [s for s in (slots[-1]["l"]["main"] if slots else []) if s and s[0] == "repair-pack"]
check(packs == [["repair-pack", 1, "normal", -1, 993]], f"K13: a worn pack's slot carries its durability in thousandths: {packs}")
pack_stack().durability = 2
chest_r.health = 50
send(repair_cmd(chest_r))
tick(5)
check(chest_r.health == 54 and pack() is None and g.storage.f3d.repair is None,
      f"K13: the last pack used up, repairing stops: {chest_r.health} {pack()}")
main.insert(lua.table_from({"name": "repair-pack", "count": 1}))
far_chest = spawn("wooden-chest", 30.5, 1.5, force="player")
enemy_r = spawn("wooden-chest", 2.5, 3.5, force="enemy")
far_chest.health, enemy_r.health = 50, 50
send(repair_cmd(far_chest))
tick(5)
msgs = take()
check(far_chest.health == 50 and any(m.get("text") == "Out of reach" for m in of_type(msgs, "msg")),
      f"K13: out of reach it says so and mends nothing: {far_chest.health}")
send(repair_cmd(enemy_r))
tick(5)
check(enemy_r.health == 50, f"K13: another force's building isn't mended: {enemy_r.health}")
send({"t": "repair", "u": chest_r.unit_number, "p": eid["wooden-chest"], "x": fixed(3.5), "y": fixed(1.5), "item": "iron-plate"})
chest_r.health = 50
tick(5)
check(chest_r.health == 50, f"K13: only a repair tool mends: {chest_r.health}")
# N4: vehicles are mended as buildings are (Factorio repairs any entity with health of the force that
# isn't not-repairable): a car, a train's wagon; another force's car is left alone.
car_r = spawn("car", 2.5, -2.5, force="player")
wagon_r = spawn("cargo-wagon", -3.0, 2.0, force="player")
enemy_car = spawn("car", -2.5, -2.5, force="enemy")
car_r.health, wagon_r.health, enemy_car.health = car_r.max_health - 20, wagon_r.max_health - 6, 50
send(repair_cmd(car_r))
tick(15)
msgs = take()
me = of_type(msgs, "me")
check(car_r.health == car_r.max_health, f"N4: a damaged car is mended to full: {car_r.health}/{car_r.max_health}")
check(any(m.get("rp") == 1 and m.get("rx") == fixed(car_r.position.x) for m in me),
      f"N4: me says the character repairs the car, and where: {me[-2:]}")
hp_seen = [dict(zip(m["l"][::2], m["l"][1::2])).get(car_r.unit_number) for m in of_type(msgs, "hp")]
check(any(v is not None and v < 1000 for v in hp_seen), f"N4: the car's health bar rises: {hp_seen}")
send(repair_cmd(wagon_r))
tick(5)
check(wagon_r.health == wagon_r.max_health, f"N4: a train's wagon is mended: {wagon_r.health}/{wagon_r.max_health}")
send(repair_cmd(enemy_car))
tick(5)
check(enemy_car.health == 50, f"N4: another force's car isn't mended: {enemy_car.health}")
send({"t": "repair"})
for e in (car_r, wagon_r, enemy_car):
    e.destroy()
take()
main.remove(lua.table_from({"name": "repair-pack", "count": 1}))
for e in (chest_r, wall_r, far_chest, enemy_r):
    e.destroy()
take()

ammo_slots[1].name = None
send({"t": "shoot", "m": 0, "x": 0, "y": 0})
tick(10)
send({"t": "shoot", "m": 0, "x": 0, "y": 0})
tick(10)
msgs = take()
check(sum(m["text"] == "Out of ammo" for m in of_type(msgs, "msg")) == 1, "shooting without ammo says so once per press")
check(of_type(msgs, "guns")[-1:] and of_type(msgs, "guns")[-1]["l"][0][:3] == ["pistol", "", 0], "guns follows the ammo inventory")
send({"t": "shoot", "m": -1})
gun_slots[2].name, gun_slots[2].count = "submachine-gun", 1
send({"t": "gun", "i": 2})
send({"t": "gun", "i": 3})  # empty: ignored
tick(11)
guns = of_type(take(), "guns")
check(puppet.selected_gun_index == 2 and guns and guns[-1]["sel"] == 2, f"gun selects a gun slot: {guns[-1:]}")
gun_slots[2].name = None
puppet.selected_gun_index = 1
ammo_slots[1].name, ammo_slots[1].count = "firearm-magazine", 10
tick(10)

# --- what weapons fire (shots.lua) -------------------------------------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
take()
rocket = spawn("rocket", 2.0, 1.0)
beam_target = spawn("small-biter", 6.0, 0.0, force="enemy")
beam = spawn("chain-tesla-gun-beam-start", 4.0, 0.0, source=puppet, target=beam_target)
boom = spawn("grenade-explosion", -3.0, 2.0)
tick(4)
pj = of_type(take(), "pj")
rid = next((m["p"][0] for m in pj if m["p"]), None)
check(pj and pj[-1]["p"][1:] == ["rocket", 512, 256] and isinstance(rid, int),
      f"pj: a projectile in flight with its register_on_object_destroyed id and position: {pj[-1:]}")
check(pj and pj[-1]["b"][1:] == ["chain-tesla-gun-beam-start", fixed(puppet.position.x), fixed(puppet.position.y), 6 * 256, 0],
      f"pj.b: a beam from its source entity to its target (get_beam_source / get_beam_target): {pj[-1:]}")
check(sum(len(m["x"]) for m in pj) == 3 and pj[0]["x"] == ["grenade-explosion", -768, 512],
      f"pj.x: an explosion is reported once, while it lasts: {[m['x'] for m in pj]}")
rocket.position = lua.table_from({"x": 2.5, "y": 1.0})
tick(2)
rocket.destroy()
tick(2)
pj = of_type(take(), "pj")
check(pj and pj[-1]["e"] == [rid, 640, 256] and pj[-1]["p"] == [],
      f"pj.e: a projectile that is gone ended where it was last seen (on_object_destroyed): {[m['e'] for m in pj]}")
for e in (beam, boom, beam_target):
    e.destroy()
tick(2)
pj = of_type(take(), "pj")
check(len(pj) == 1 and pj[0]["p"] == [] and pj[0]["b"] == [], f"pj: one empty update when nothing is flying any more: {pj}")
tick(4)
check(not of_type(take(), "pj"), "pj: then nothing while nothing flies")
fire = spawn("fire-flame", 1.0, -2.0)
cloud = spawn("poison-cloud", -2.0, -2.0, time_to_live=900)
tick(16)
gf = of_type(take(), "gf")
fl = gf[-1]["l"] if gf else []
check(len(fl) == 10 and fl[1:5] == ["fire-flame", 256, -512, -1] and fl[6:10] == ["poison-cloud", -512, -512, 900],
      f"gf: fires and clouds on the ground with ids, a cloud's time_to_live: {gf[-1:]}")
fire.destroy()
cloud.destroy()
tick(15)
gf = of_type(take(), "gf")
check(gf and gf[-1]["l"] in ([], {}), f"gf: an empty list once they are gone: {gf[-1:]}")
tick(15)
check(not of_type(take(), "gf"), "gf: then nothing")

# /f3d-perf shots_radius: a projectile 100 tiles from the focus isn't sent at the default (48), is with it raised.
far_rocket = spawn("rocket", 100.0, 0.0)
tick(4)
pj = of_type(take(), "pj")
check(not any(m["p"] for m in pj), f"shots_radius default: a projectile 100 tiles from the focus isn't sent: {pj[-1:]}")
F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "shots_radius 128"}))
tick(4)
pj = of_type(take(), "pj")
check(any(m["p"] and m["p"][1:] == ["rocket", 100 * 256, 0] for m in pj),
      f"shots_radius 128: the projectile 100 tiles away is sent: {pj[-1:]}")
F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "shots_radius 9999"}))
check(g.storage.f3d_perf_num.shots_radius == 256, "shots_radius is capped at 256")
F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "shots_radius default"}))
tick(4)
take()
tick(4)
pj = of_type(take(), "pj")
check(not any(m["p"] for m in pj), "shots_radius default: the far projectile is not sent again")
far_rocket.destroy()
tick(2)
take()

# --- driving ------------------------------------------------------------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})  # keep-alive: the client times out after 600 ticks
riding = g.defines.riding
same = lua.eval("function(a, b) return a == b end")  # Lua identity; Python's == compares wrappers
car = next(e for e in F.surface.entities.values() if e.name == "car")  # at (3, 3), 4.2 tiles away
send({"t": "enter"})
tick(4)
me = of_type(take(), "me")[-1]
check(same(car.get_driver(), puppet) and same(puppet.vehicle, car), "enter puts the character in the driver's seat of the nearest vehicle")
check(me.get("v") == car.unit_number and me.get("vs") == 0 and (me["x"], me["y"]) == (3 * 256, 3 * 256),
      f"me carries the vehicle, its speed, and the vehicle's position: {me}")
send({"t": "drive", "a": 1, "s": 1})
tick(2)
st = puppet.riding_state
check(st.acceleration == riding.acceleration.accelerating and st.direction == riding.direction.right,
      "drive sets riding_state (accelerate, turn right)")
car.speed = 0.25
send({"t": "drive", "a": 1, "s": 0})
tick(4)
msgs = take()
check(of_type(msgs, "me")[-1].get("vs") == 250, "me.vs is the vehicle's speed in thousandths of a tile per tick")
check(sum(m["text"] == "No fuel" for m in of_type(msgs, "msg")) == 1, "driving a car with no fuel says so once per press")
tick(40)
st = puppet.riding_state
check(st.acceleration == riding.acceleration.nothing and st.direction == riding.direction.straight,
      "riding stops when the client stops repeating drive")
car.burner.inventory.insert(lua.table_from({"name": "coal", "count": 5}))
send({"t": "drive", "a": 3, "s": -1})
tick(2)
check(puppet.riding_state.acceleration == riding.acceleration.reversing and puppet.riding_state.direction == riding.direction.left,
      "drive a=3 reverses, s=-1 turns left")
send({"t": "drive", "a": 0, "s": 0})
tick(2)
check(puppet.riding_state.acceleration == riding.acceleration.nothing, "drive 0, 0 stops at once")
check(not [m for m in of_type(take(), "msg") if m["text"] == "No fuel"], "no fuel message once there is fuel")
# Opposite key brakes and holds (drive.h = 1): braking against the motion, then nothing at a stop.
acc = riding.acceleration
def brake_hold(label, key, other, speed, sign):
    """key: the held key's a (3 = S, 1 = W); other: the forward key; speed: the start, signed."""
    send({"t": "drive", "a": 0, "s": 0})
    tick(2)
    car.speed = speed
    send({"t": "drive", "a": key, "s": 0, "h": 1})
    tick(2)
    check(puppet.riding_state.acceleration == acc.braking, f"{label}: the opposite key brakes while moving")
    car.speed = sign * 0.05
    send({"t": "drive", "a": key, "s": 0, "h": 1})
    tick(2)
    check(puppet.riding_state.acceleration == acc.braking, f"{label}: still braking at low speed")
    car.speed = 0
    send({"t": "drive", "a": key, "s": 0, "h": 1})
    tick(3)
    check(puppet.riding_state.acceleration == acc.nothing, f"{label}: nothing once stopped (no reversing)")
    tick(3)
    send({"t": "drive", "a": key, "s": 0, "h": 1})
    tick(3)
    check(puppet.riding_state.acceleration == acc.nothing, f"{label}: still nothing while the key stays held")
    send({"t": "drive", "a": 0, "s": 1, "h": 1})
    tick(2)
    send({"t": "drive", "a": key, "s": 0, "h": 1})
    tick(2)
    check(puppet.riding_state.acceleration in (acc.reversing, acc.accelerating),
          f"{label}: let go and pressed again from a stop drives that way")
    send({"t": "drive", "a": 0, "s": 0, "h": 1})
    tick(2)
    send({"t": "drive", "a": key, "s": 0, "h": 1})
    tick(2)
    send({"t": "drive", "a": other, "s": 0, "h": 1})
    tick(2)
    check(puppet.riding_state.acceleration == (acc.accelerating if other == 1 else acc.reversing),
          f"{label}: the forward key drives at once from held-stopped")
brake_hold("brake-hold forward then S", 3, 1, 0.25, 1)
brake_hold("brake-hold reversing then W", 1, 3, -0.2, -1)
send({"t": "drive", "a": 0, "s": 0})
tick(2)
car.speed = 0.25
send({"t": "drive", "a": 3, "s": 0})
tick(2)
check(puppet.riding_state.acceleration == acc.reversing, "brake-hold off (no h): S while moving is Factorio's reversing, as before")
car.speed = 0
send({"t": "drive", "a": 0, "s": 0})
tick(2)
# N3: while driving, the tool bar's `guns` are the vehicle's: its guns over its ammo, its selected gun.
car_ammo = car.get_inventory(g.defines.inventory.car_ammo)
car_ammo[1].set_stack(lua.table_from({"name": "firearm-magazine", "count": 7}))
tick(11)
vg = of_type(take(), "guns")
check(vg and vg[-1].get("v") == car.unit_number and vg[-1]["sel"] == 1
      and [r[:3] for r in vg[-1]["l"]] == [["vehicle-machine-gun", "firearm-magazine", 7]],
      f"guns while driving: the car's machine gun and its ammo, with v the car: {vg[-1:]}")
send({"t": "gun", "i": 1})
tick(11)
check(car.selected_gun_index == 1, "gun while driving picks the vehicle's gun")
send({"t": "move", "from": "vammo", "fi": 1, "to": "main", "ti": 30, "n": 2})
tick(11)
vg = of_type(take(), "guns")
check(car_ammo[1].count == 5 and vg and vg[-1]["l"][0][2] == 5, f"move from vammo takes the vehicle's ammo: {vg[-1:]}")
# N3: shooting from the car: the game fires the car's gun (its rounds go down, read in 2.1.24), so me.sh and
# "Out of ammo" follow the car's ammo (/f3d-perf vehicle_ammo); its shots are turrets.lua's (`ts`, drawn by
# the client's turrets.gd), so no `shot` comes from the character's guns.
veh_biter = spawn("small-biter", car.position.x + 4, car.position.y, force="enemy")
take()
for m in (1, 0):
    send({"t": "shoot", "m": m, "x": fixed(car.position.x + 4), "y": fixed(car.position.y)})
    tick(2)
    car_ammo[1].count = car_ammo[1].count - 1  # the game fired the car's gun (a magazine: the fake has no rounds)
    tick(4)
    msgs = take()
    check(of_type(msgs, "me")[-1].get("sh") == 1, f"N3: shoot m={m} from the car: me.sh is 1 once the car's ammo goes down")
    check(not of_type(msgs, "shot"), f"N3: and no `shot` (the car's shots come in ts): {of_type(msgs, 'shot')}")
    send({"t": "shoot", "m": -1})
    send({"t": "hello", "v": 1, "sid": "s1", "w": 1})  # keep-alive: these ticks add up towards the timeout
    tick(2)
    take()
send({"t": "shoot", "m": 1, "x": fixed(car.position.x + 4), "y": fixed(car.position.y)})
tick(25)
check(of_type(take(), "me")[-1].get("sh") == 0, "N3: me.sh back to 0 once the car's ammo stops going down")
send({"t": "shoot", "m": -1})
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(2)
car_mags = car_ammo[1].count
car_ammo[1].clear()
send({"t": "shoot", "m": 1, "x": fixed(car.position.x + 4), "y": fixed(car.position.y)})
tick(4)
check(sum(m["text"] == "Out of ammo" for m in of_type(take(), "msg")) == 1,
      "N3: shooting from a car without ammo says Out of ammo, whatever the character holds")
send({"t": "shoot", "m": -1})
tick(2)
car_ammo[1].set_stack(lua.table_from({"name": "firearm-magazine", "count": car_mags}))
g.storage.f3d_perf = lua.table_from({"vehicle_ammo": False})
take()
send({"t": "shoot", "m": 1, "x": fixed(car.position.x + 4), "y": fixed(car.position.y)})
tick(2)
car_ammo[1].count = car_ammo[1].count - 1
tick(4)
check(of_type(take(), "me")[-1].get("sh") == 0, "N3: /f3d-perf vehicle_ammo off: me.sh follows the character's ammo, as before")
send({"t": "shoot", "m": -1})
tick(2)
g.storage.f3d_perf = None
veh_biter.destroy()
take()
send({"t": "enter"})
tick(4)
msgs = take()
me = of_type(msgs, "me")[-1]
check(car.get_driver() is None and puppet.vehicle is None and "v" not in me, f"enter again gets out: {me}")
tick(11)
back = of_type(msgs + take(), "guns")
check(back and "v" not in back[-1] and back[-1]["l"][0][0] == "pistol", f"out of the car the character's guns come back: {back[-1:]}")
tank = spawn("tank", puppet.position.x + 0.5, puppet.position.y, force="player")  # nearer than the car
send({"t": "enter"})
tick(4)
send({"t": "gun", "i": 2})
tick(11)
tg = of_type(take(), "guns")
check(same(puppet.vehicle, tank) and tank.selected_gun_index == 2 and tg and tg[-1]["sel"] == 2 and tg[-1].get("v") == tank.unit_number
      and [r[0] for r in tg[-1]["l"]] == ["tank-cannon", "tank-machine-gun", "tank-flamethrower"],
      f"a tank's three guns in 2.1's order, and gun i=2 selects its machine gun: {tg[-1:]}")
send({"t": "enter"})
tick(4)
tank.destroy()
take()
check(me["x"] == 5 * 256, "the character stands next to the vehicle")

other = spawn("character", 3.0, 3.0, force="player")
car.set_driver(other)
send({"t": "enter"})
tick(2)
check(same(car.get_passenger(), puppet), "with someone driving, enter takes a car's passenger seat")
send({"t": "enter"})
tick(2)
check(car.get_passenger() is None and same(car.get_driver(), other) and puppet.vehicle is None, "and gets out of it")
car.set_driver(None)
other.destroy()
# Getting out over water (a boat): the character steps to the nearest land, not into the water.
car.position = lua.table_from({"x": -45.5, "y": 3.5})
puppet.position = lua.table_from({"x": -45.0, "y": 3.0})
send({"t": "enter"})
tick(2)
send({"t": "enter"})
tick(2)
check(puppet.vehicle is None and puppet.position.x >= -40, f"getting out over water lands the character on land: {puppet.position.x}")
car.position = lua.table_from({"x": 3, "y": 3})
puppet.position = lua.table_from({"x": 0, "y": 0})
loco = spawn("locomotive", -2.0, 0.0, force="player")  # nearer than the car
wagon = spawn("cargo-wagon", -0.5, 0.0, force="player")  # nearer still, but a wagon has no seat
send({"t": "enter"})
send({"t": "drive", "a": 1, "s": 0})
tick(2)
check(same(loco.get_driver(), puppet) and loco.train.manual_mode is True and wagon.get_driver() is None,
      "driving a locomotive switches its train to manual mode (Enter skips a nearer wagon: no seat)")
send({"t": "enter"})
tick(2)
loco.destroy()
wagon.destroy()
puppet.position = lua.table_from({"x": 30, "y": 0})
send({"t": "enter"})
tick(2)
check(any(m["text"] == "No vehicle nearby" for m in of_type(take(), "msg")), "enter with nothing near says so")
puppet.position = lua.table_from({"x": 0, "y": 0})
tick(2)
take()

# --- mining a tree -------------------------------------------------------------------------
tree = [rec for rec in ents[(0, 0)] if rec[1] == eid["tree-01"]][0]
for _ in range(4):
    send({"t": "mine", "u": 0, "p": tree[1], "x": tree[2], "y": tree[3]})
    tick(10)
tick(30)  # inventory is reported every 30 ticks
msgs = take()
dels = of_type(msgs, "del")
check(any(d["p"] == eid["tree-01"] and d["x"] == tree[2] for d in dels), "mined tree is deleted on the client")
inv = of_type(msgs, "inv")
check(inv and ["wood", 5] in inv[-1]["l"], "wood lands in the inventory")

# --- J10: the character stands while it mines, and walks on once mining stops ----------------------
j10_tree = spawn("tree-01", 1.5, 1.5)
send({"t": "walk", "d": 4})
send({"t": "mine", "u": 0, "p": eid["tree-01"], "x": fixed(1.5), "y": fixed(1.5)})
tick(1)
check(g.storage.f3d.mining is not None and not puppet.walking_state.walking and g.storage.f3d.walk is not None,
      "J10: a walk held while mining doesn't move the character (kept for after)")
send({"t": "mine_stop"})
send({"t": "walk", "d": 4})
tick(1)
check(puppet.walking_state.walking and puppet.walking_state.direction == 4, "J10: the walk goes on once mining stops")
send({"t": "walk", "d": -1})
send({"t": "pickup"})
send({"t": "walk", "d": 4})
tick(1)
check(puppet.walking_state.walking, "J10: picking up with F doesn't stop the walk")
send({"t": "walk", "d": -1})
tick(1)
j10_tree.destroy()
take()

# --- mining ore down to nothing ----------------------------------------------------------------
ore = ore[0]
for _ in range(20):
    send({"t": "mine", "u": 0, "p": ore[1], "x": ore[2], "y": ore[3]})
    tick(15)
tick(30)
msgs = take()
check(of_type(msgs, "upd"), "ore amount update is sent while mining")
check(any(d["p"] == eid["iron-ore"] for d in of_type(msgs, "del")), "depleted ore is deleted")
inv = of_type(msgs, "inv")
check(inv and ["iron-ore", 2] in inv[-1]["l"], "both ore units were mined")

# --- issue #10: mining a wagon standing on a rail takes the wagon, by its unit number ------------
rail = spawn("straight-rail", 3.0, 3.0, force="player")
wagon = spawn("cargo-wagon", 3.0, 3.0, force="player")
wagon_unit = wagon.unit_number
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})  # keep-alive: the mining adds up towards the timeout
for _ in range(10):
    send({"t": "mine", "u": wagon_unit, "p": eid["cargo-wagon"], "x": fixed(3.0), "y": fixed(3.0)})
    tick(15)
tick(30)
msgs = take()
check(not wagon.valid and rail.valid, "#10: mining by unit number takes the wagon on the rail, the rail stays")
check(not any(m["text"] == "Can't mine that" for m in of_type(msgs, "msg")), "#10: no 'Can't mine that' for the wagon")
inv = of_type(msgs, "inv")
check(inv and any(row[0] == "cargo-wagon" for row in inv[-1]["l"]), f"#10: the wagon lands in the inventory: {inv[-1]['l'] if inv else None}")
rail.destroy()
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})

# --- building, rotating ----------------------------------------------------------------------
puppet.insert(lua.table_from({"name": "transport-belt", "count": 5}))
send({"t": "build", "item": "transport-belt", "x": 2 * 256 + 40, "y": 5 * 256 + 200, "d": 4})
tick(2)
msgs = take()
adds = of_type(msgs, "add")
check(adds and adds[0]["e"][1] == eid["transport-belt"] and adds[0]["e"][2:5] == [2 * 256 + 128, 5 * 256 + 128, 4],
      "built belt is snapped to the tile centre and added")
send({"t": "build", "item": "assembling-machine-1", "x": 10 * 256, "y": 10 * 256, "d": 0})
tick(2)
msgs = take()
check(any(m.get("text") == "You have no assembling-machine-1" for m in of_type(msgs, "msg")),
      "building without the item explains why")
new_belt = adds[0]["e"]
send({"t": "rotate", "u": new_belt[0], "p": new_belt[1], "x": new_belt[2], "y": new_belt[3]})
tick(2)
msgs = take()
upd = of_type(msgs, "upd")
check(upd and upd[0]["e"][4] == 8, "rotated belt now faces south")
# Undergrounds: the second one built ahead of an entrance facing the same way is its exit.
puppet.insert(lua.table_from({"name": "underground-belt", "count": 2}))
send({"t": "build", "item": "underground-belt", "x": 3 * 256 + 128, "y": 7 * 256 + 128, "d": 4})
send({"t": "build", "item": "underground-belt", "x": 6 * 256 + 128, "y": 7 * 256 + 128, "d": 4})
tick(2)
pair = sorted((e for e in F.surface.entities.values() if e.name == "underground-belt" and e.position.y == 7.5),
              key=lambda e: e.position.x)
check([e.belt_to_ground_type for e in pair] == ["input", "output"],
      f"an underground built ahead of an entrance is its exit: {[e.belt_to_ground_type for e in pair]}")
# J23: R on one end of a pair turns both (2.1.24 flips both between entrance and exit, facing back),
# and the client hears of both, though the game tells of only the one turned.
F.pair_undergrounds(pair[0], pair[1])
take()
send({"t": "rotate", "u": pair[0].unit_number, "p": eid["underground-belt"], "x": fixed(pair[0].position.x),
      "y": fixed(pair[0].position.y)})
tick(2)
turned = {u["e"][0]: (u["e"][4], u["e"][5].get("u")) for u in of_type(take(), "upd") if u["e"][1] == eid["underground-belt"]}
check(turned == {pair[0].unit_number: (12, "o"), pair[1].unit_number: (12, "i")},
      f"J23: R on an underground's entrance sends both ends turned (facing back, entrance and exit swapped): {turned}")
for e in pair:
    e.destroy()
take()
send({"t": "build", "item": "underground-belt", "x": 3 * 256 + 128, "y": 7 * 256 + 128, "d": 4, "ghost": 1})
send({"t": "build", "item": "underground-belt", "x": 6 * 256 + 128, "y": 7 * 256 + 128, "d": 4, "ghost": 1})
tick(2)
ghost_ends = [a["e"][5].get("u") for a in of_type(take(), "add") if len(a["e"]) > 5 and a["e"][5].get("gh") == eid["underground-belt"]]
check(ghost_ends == ["i", "o"], f"underground ghosts are entrance then exit, sent as extra.u: {ghost_ends}")
for e in [e for e in F.surface.entities.values() if e.name == "entity-ghost" and e.position.y == 7.5]:
    e.destroy()
take()
# A right click removes a ghost at once (I6): no mining time to wait out.
send({"t": "build", "item": "transport-belt", "x": 3 * 256 + 128, "y": 7 * 256 + 128, "d": 4, "ghost": 1})
tick(2)
belt_ghost = next(e for e in F.surface.entities.values() if e.name == "entity-ghost" and e.position.y == 7.5)
take()
send({"t": "mine", "u": belt_ghost.unit_number or 0, "p": eid["entity-ghost"], "x": fixed(3.5), "y": fixed(7.5)})
tick(1)
check(not belt_ghost.valid, "mining a ghost removes it on the next tick")
take()

# --- crafting ---------------------------------------------------------------------------------
send({"t": "craft", "recipe": "iron-gear-wheel", "n": 2})
send({"t": "craft", "recipe": "laser-turret", "n": 1})
send({"t": "craft", "recipe": "oil-processing", "n": 1})
tick(3)
msgs = take()
check(any("laser-turret" in m.get("text", "") for m in of_type(msgs, "msg")), "locked recipe is refused")
check(any("cannot be crafted by hand" in m.get("text", "") for m in of_type(msgs, "msg")), "a recipe of another machine says it can't be crafted by hand")
check(any(m.get("q") == 2 for m in of_type(msgs, "me")), "crafting queue size is reported")
send({"t": "craft", "recipe": "iron-gear-wheel", "n": 250})
tick(3)
msgs = take()
check(any(m.get("q") == 252 for m in of_type(msgs, "me")), "Shift+click's craft all is not capped at 100")
send({"t": "cancel_craft", "i": 2, "n": 250})
tick(1)
take()

# --- machine screens --------------------------------------------------------------------------
def fill(entity, role, name, count):
    F.inventories[entity][role].insert(lua.table_from({"name": name, "count": count}))


def open_cmd(entity):
    p = entity.position
    return {"t": "open", "u": entity.unit_number, "p": eid[entity.name],
            "x": int(p.x * 256 + 0.5), "y": int(p.y * 256 + 0.5)}


def guis(msgs, entity=None):
    return [m for m in of_type(msgs, "gui") if entity is None or m["u"] == entity.unit_number]


def last_inv(msgs):
    inv = of_type(msgs, "inv")
    return dict(map(tuple, inv[-1]["l"])) if inv else {}


send({"t": "hello", "v": 1, "sid": "s1", "w": 1})  # keep-alive: the client times out after 600 ticks
take()
chest = spawn("wooden-chest", 3.5, 0.5, force="player")
asm = spawn("assembling-machine-1", 4.5, -4.5, force="player")
furnace = spawn("stone-furnace", -3.0, -3.0, force="player")
lab = spawn("lab", -5.5, 3.5, force="player")
far_asm = spawn("assembling-machine-1", 20.5, 0.5, force="player")
enemy_chest = spawn("wooden-chest", 1.5, 1.5, force="enemy")
fill(chest, "chest", "iron-plate", 20)
fill(chest, "chest", "copper-plate", 3)

# A machine with fluid boxes and no inventory still has a screen (a heat exchanger, a boiler run on
# fluid): not one entity_ui's STATUS_ONLY opens anyway, as an offshore pump is.
hx = spawn("heat-exchanger", 2.5, -1.0, force="player")
send(open_cmd(hx))
tick(2)
msgs = take()
check(guis(msgs, hx) and not [m for m in of_type(msgs, "msg") if m["text"] == "Nothing to open there"],
      f"a machine with only fluid boxes opens: {[m.get('text') for m in of_type(msgs, 'msg')]}")
hx.destroy()

send(open_cmd(chest))
tick(2)
msgs = take()
g0 = guis(msgs, chest)
check(len(g0) == 1 and g0[0]["kind"] == "container" and g0[0]["p"] == eid["wooden-chest"],
      f"opening a chest sends its screen at once: {g0}")
check(g0 and g0[0]["inv"] == {"chest": [["iron-plate", 20], ["copper-plate", 3]]}, f"chest contents by role: {g0[:1]}")
check(g0 and not ({"recipe", "pr", "rl"} & set(g0[0])), "a chest has no recipe, progress or recipe list")
tick(30)
check(len(guis(take(), chest)) == 1, "the open screen is re-sent every 30 ticks")

plates = puppet.get_main_inventory().get_item_count("iron-plate")
send({"t": "take", "u": chest.unit_number, "inv": "chest", "item": "iron-plate", "n": 5})
tick(2)
msgs = take()
g1 = guis(msgs, chest)
check(g1 and g1[-1]["inv"]["chest"][0] == ["iron-plate", 15], f"take removes from the chest: {g1[-1:]}")
check(last_inv(msgs).get("iron-plate") == plates + 5, f"taken plates reach the character's inventory at once: {of_type(msgs, 'inv')}")
plates += 5
send({"t": "take", "u": chest.unit_number, "item": "copper-plate", "n": 100})
send({"t": "put", "u": chest.unit_number, "item": "wood", "n": 1})
tick(2)
msgs = take()
g2 = guis(msgs, chest)
check(g2 and dict(map(tuple, g2[-1]["inv"]["chest"])) == {"iron-plate": 15, "wood": 1},
      f"take without inv takes what there is; put adds to the chest: {g2[-1:]}")
wood = puppet.get_main_inventory().get_item_count("wood")
check(last_inv(msgs).get("copper-plate") == 3 and last_inv(msgs).get("wood", 0) == wood, f"inventory follows: {last_inv(msgs)}")
send({"t": "take", "u": 999999, "item": "iron-plate", "n": 1})
send({"t": "put", "u": chest.unit_number, "item": "laser-turret", "n": 1})
tick(2)
msgs = take()
check(guis(msgs, chest)[-1]["inv"]["chest"][0] == ["iron-plate", 15], "commands for another unit are ignored")
check(any("laser-turret" in m["text"] for m in of_type(msgs, "msg")), "putting an item you don't have explains why")

send(open_cmd(asm))
tick(2)
msgs = take()
g3 = guis(msgs, asm)
check(g3 and g3[0]["kind"] == "crafter" and "recipe" not in g3[0] and g3[0].get("pr") == 0, f"assembler screen: {g3[:1]}")
check(g3 and sorted(g3[0].get("rl", [])) == ["iron-gear-wheel", "transport-belt"],
      f"recipe list: enabled recipes in the machine's categories only: {g3[0].get('rl') if g3 else None}")
check(g3 and set(g3[0]["inv"]) == {"input", "output", "modules"}, f"assembler inventories: {g3[0]['inv'] if g3 else None}")
rg = dict(zip(g3[0].get("rl", []), g3[0].get("rg", []))) if g3 else {}
check(rg.get("transport-belt") == ["logistics", "b", "b belt", "a[transport-belt]"] and len(rg) == 2,
      f"the recipe chooser's groups ride with the list (machine_info.lua): {g3[0].get('rg') if g3 else None}")
check(g3 and "parameter-0" not in g3[0].get("rl", []), f"parameter recipes aren't in a machine's recipe chooser: {g3[0].get('rl') if g3 else None}")
check(g3 and "rd" not in g3[0] and "fixed" not in g3[0], "no recipe: no recipe details")
check(not guis(msgs, chest), "opening another entity closes the first screen")
# Opening something that doesn't open ends the open screen too: the client has moved on to it.
send(open_cmd(enemy_chest))
tick(31)
msgs = take()
check(not guis(msgs, asm) and g.storage.f3d.screen is None
      and "That belongs to another force" in [m["text"] for m in of_type(msgs, "msg")],
      f"a failed open still closes the screen that was open: {[m.get('u') for m in guis(msgs)]}")
send(open_cmd(asm))
tick(2)
take()
send({"t": "set_recipe", "u": asm.unit_number, "recipe": "oil-processing"})
send({"t": "set_recipe", "u": asm.unit_number, "recipe": "laser-turret"})
tick(2)
msgs = take()
check(sum("Can't make" in m["text"] for m in of_type(msgs, "msg")) == 2, "recipes of another category or locked ones are refused")
send({"t": "set_recipe", "u": asm.unit_number, "recipe": "iron-gear-wheel"})
tick(2)
asm.crafting_progress = 0.25
send({"t": "put", "u": asm.unit_number, "item": "iron-plate", "n": 4})
tick(2)
msgs = take()
g4 = guis(msgs, asm)
check(g4 and g4[-1].get("recipe") == "iron-gear-wheel" and g4[-1].get("pr") == 250,
      f"set_recipe, get_recipe and crafting_progress: {g4[-1:]}")
check(g4 and g4[-1]["inv"]["input"] == [["iron-plate", 4]], f"put goes where entity.insert puts it: {g4[-1:]}")
check(last_inv(msgs).get("iron-plate") == plates - 4, f"put takes from the character: {last_inv(msgs)}")
check(all("rl" not in m for m in g4), "the recipe list isn't repeated every time")
check(g4 and g4[-1].get("rd") == {"i": [["item", "iron-plate", 2]], "o": [["item", "iron-gear-wheel", 1]], "e": 0.5},
      f"the recipe's ingredients, products and time for the recipe row and slots: {g4[-1].get('rd') if g4 else None}")
send({"t": "set_recipe", "u": asm.unit_number, "recipe": ""})
tick(2)
msgs = take()
g5 = guis(msgs, asm)
check(g5 and "recipe" not in g5[-1] and g5[-1]["inv"]["input"] == [], f"an empty recipe clears it and empties the machine: {g5[-1:]}")
check(last_inv(msgs).get("iron-plate") == plates, "items the machine gives back return to the character")

g.defines.inventory.assembling_machine_input = None
g.defines.inventory.crafter_input = 2
tick(30)
g6 = guis(take(), asm)
check(g6 and "input" in g6[-1]["inv"], "inputs are found through crafter_input when assembling_machine_input is gone")
g.defines.inventory.assembling_machine_input = 2

# Crafter recipe list caching: sent on open (sc.sent == 0), skipped at RECIPE_LIST_EVERY (10)
# while unchanged, resent at the next RECIPE_LIST_EVERY when enabled recipes change, and rebuilt
# as a fallback at RECIPE_LIST_RESEND (60).
send(open_cmd(asm))
tick(2)
g_open = guis(take(), asm)
check(g_open and sorted(g_open[0].get("rl", [])) == ["iron-gear-wheel", "transport-belt"],
      f"crafter open sends initial recipe list: {g_open}")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(300)  # covers sc.sent == 1..10 (10 * INTERVAL) with unchanged force.recipes
g_unchanged = guis(take(), asm)
check(len(g_unchanged) >= 10 and all("rl" not in m and "rg" not in m for m in g_unchanged),
      f"unchanged recipe list is omitted at sc.sent == 10 (RECIPE_LIST_EVERY): {len(g_unchanged)}")
lua.execute('rawset(game.forces.player.recipes["laser-turret"], "enabled", true)')
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(300)  # covers sc.sent == 11..20 (next RECIPE_LIST_EVERY check picks up the unlock)
g_unlock = guis(take(), asm)
rl_msgs = [m for m in g_unlock if "rl" in m]
check(len(rl_msgs) == 1 and sorted(rl_msgs[0]["rl"]) == ["iron-gear-wheel", "laser-turret", "transport-belt"]
      and len(rl_msgs[0].get("rg", [])) == 3,
      f"unlocked recipe triggers rl/rg resend at next RECIPE_LIST_EVERY: {rl_msgs}")
lua.execute('rawset(game.forces.player.recipes["laser-turret"], "enabled", false)')
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(300)  # covers sc.sent == 21..30 (relocked)
g_relock = guis(take(), asm)
rl_msgs2 = [m for m in g_relock if "rl" in m]
check(len(rl_msgs2) == 1 and sorted(rl_msgs2[0]["rl"]) == ["iron-gear-wheel", "transport-belt"],
      f"relocked recipe updates rl/rg at next RECIPE_LIST_EVERY: {rl_msgs2}")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(300)  # covers sc.sent == 31..40 (unchanged)
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(300)  # covers sc.sent == 41..50 (unchanged)
g_mid = guis(take(), asm)
check(all("rl" not in m for m in g_mid), "unchanged checks at sc.sent == 40 and 50 omit rl")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(300)  # covers sc.sent == 51..60 (RECIPE_LIST_RESEND triggers fallback resend)
g_resend = [m for m in guis(take(), asm) if "rl" in m]
check(len(g_resend) == 1 and sorted(g_resend[0]["rl"]) == ["iron-gear-wheel", "transport-belt"],
      f"RECIPE_LIST_RESEND (60) resends rl/rg as UDP fallback: {g_resend}")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})

# F6: a module clicked on a building: within reach it goes in from the inventory; out of reach (or
# from the machine screen's slot) it is requested through an item request proxy, as Factorio does.
def texts(msgs):
    return [m["text"] for m in of_type(msgs, "msg")]


puppet.insert(lua.table_from({"name": "speed-module", "count": 3}))
asm_at ={"u": asm.unit_number, "p": eid["assembling-machine-1"], "x": fixed(asm.position.x), "y": fixed(asm.position.y)}
send({"t": "modreq", "item": "speed-module", **asm_at})
tick(2)
msgs = take()
mods = F.inventories[asm]["modules"]
check(mods.get_item_count("speed-module") == 1 and puppet.get_main_inventory().get_item_count("speed-module") == 2
      and asm.item_request_proxy is None, f"modreq within reach puts the module in: {texts(msgs)}")
g7 = guis(msgs, asm)
check(g7 and g7[-1]["slots"]["modules"][0] == ["speed-module", 1] and "mrq" not in g7[-1] and "far" not in g7[-1],
      f"the screen shows the module, with nothing requested: {g7[-1:]}")
send({"t": "modreq", "item": "speed-module", "s": 1, **asm_at})
send({"t": "modreq", "item": "speed-module", "s": 2, **asm_at})
tick(2)
msgs = take()
proxy = asm.item_request_proxy
plan = [(p.id.name, at.inventory, at.stack) for p in proxy.insert_plan.values() for at in p["items"].in_inventory.values()] if proxy else []
check(plan == [("speed-module", g.defines.inventory.crafter_modules, 1)] and "That slot has a module in it" in texts(msgs),
      f"modreq on a slot: the free one gets a request proxy, the filled one is refused: {plan} {texts(msgs)}")
g8 = guis(msgs, asm)
check(g8 and g8[-1].get("mrq") == ["", "speed-module"], f"gui mrq: each module slot's requested module: {g8[-1:]}")
send({"t": "modreq", "item": "productivity-module", "u": lab.unit_number, "p": eid["lab"], "x": fixed(lab.position.x), "y": fixed(lab.position.y)})
far_at = {"u": far_asm.unit_number, "p": eid["assembling-machine-1"], "x": fixed(far_asm.position.x), "y": fixed(far_asm.position.y)}
send({"t": "modreq", "item": "speed-module", **far_at})
tick(2)
said = texts(take())
far_proxy = far_asm.item_request_proxy
check(far_proxy is not None and F.inventories[far_asm]["modules"].get_item_count("speed-module") == 0
      and any("productivity isn't allowed" in t for t in said), f"out of reach a request; a lab takes no productivity: {said}")
send({"t": "modreq", "clr": 1, **far_at})
send({"t": "modreq", "clr": 1, "s": 2, **asm_at})
tick(2)
take()
check(not far_proxy.valid and asm.item_request_proxy is None, "clr takes the requests back: the proxies go")

puppet.insert(lua.table_from({"name": "coal", "count": 5}))
fill(furnace, "input", "iron-ore", 7)
fill(furnace, "output", "iron-plate", 2)
send(open_cmd(furnace))
send({"t": "put", "u": furnace.unit_number, "item": "coal", "n": 2})
tick(2)
g7 = guis(take(), furnace)
check(g7 and g7[-1]["kind"] == "furnace" and g7[-1].get("recipe") == "iron-plate" and "rl" not in g7[-1],
      f"furnace: current recipe, no recipe list: {g7[-1:]}")
check(g7 and g7[-1]["inv"] == {"input": [["iron-ore", 7]], "output": [["iron-plate", 2]], "fuel": [["coal", 2]]},
      f"furnace inventories, coal goes to the fuel slot: {g7[-1:]}")
# I26: the screen says how fast the craft goes (crafting speed 1 over iron plate's 0.5 s here).
check(g7 and g7[-1].get("pr") == 0 and g7[-1].get("ps") == 2000, f"furnace: progress and its rate: {g7[-1:]}")
# I2: hovering lists what is inside, by role, in the panel's order; a chest its contents (I26: and a
# crafter its progress and rate).
send({"t": "hinfo", "q": 21, "u": furnace.unit_number, "p": 0, "x": fixed(furnace.position.x), "y": fixed(furnace.position.y)})
send({"t": "hinfo", "q": 22, "u": chest.unit_number, "p": 0, "x": fixed(chest.position.x), "y": fixed(chest.position.y)})
tick(1)
hc = {m["q"]: m for m in of_type(take(), "hinfo")}
check(hc.get(21, {}).get("inv") == [["input", [["iron-ore", 7]]], ["output", [["iron-plate", 2]]], ["fuel", [["coal", 2]]]]
      and hc[21].get("pr") == 0 and hc[21].get("ps") == 2000,
      f"hinfo for a furnace: its input, output and fuel, its progress and rate: {hc.get(21)}")
chest_has = [[it["name"], it["count"]] for it in chest.get_inventory(1).get_contents().values()]
check(hc.get(22, {}).get("inv") == [["chest", chest_has]] and chest_has and "pr" not in hc[22],
      f"hinfo for a chest: its contents: {hc.get(22)}")
# J15: a crafter's ingredients and products a second at its speed (assembler 1's 0.5 over the gear's
# 0.5 s: a craft a second), products with its productivity; the furnace's in its hinfo (`io`).
io_asm = spawn("assembling-machine-1", 8.5, -8.5, force="player")
io_asm.set_recipe("iron-gear-wheel")
rates_of = g.package.loaded["scripts.modules"].rates
io_plain = to_py(rates_of(io_asm))
io_asm.productivity_bonus = 0.5
io_prod = to_py(rates_of(io_asm))
check(io_plain == {"i": [["item", "iron-plate", 2000]], "o": [["item", "iron-gear-wheel", 1000]]}
      and io_prod == {"i": [["item", "iron-plate", 2000]], "o": [["item", "iron-gear-wheel", 1500]]}
      and hc[22].get("io") is None and hc.get(21, {}).get("io", {}).get("o") == [["item", "iron-plate", 2000]],
      f"J15: a crafter's ingredients and products a second, with productivity, in hinfo's io: {io_plain} {io_prod} {hc.get(21, {}).get('io')}")
io_asm.destroy()
send({"t": "set_recipe", "u": furnace.unit_number, "recipe": "iron-gear-wheel"})
tick(2)
check(any("can't be changed" in m["text"] for m in of_type(take(), "msg")), "a furnace's recipe can't be set")

send(open_cmd(lab))
tick(2)
g8 = guis(take(), lab)
check(g8 and g8[-1]["kind"] == "lab" and set(g8[-1]["inv"]) == {"input", "modules"} and not ({"recipe", "pr", "rl"} & set(g8[-1])),
      f"lab: input and modules, no recipe: {g8[-1:]}")
check(g8 and g8[0].get("li") == ["automation-science-pack", "logistic-science-pack"], f"a lab's science packs: {g8[:1]}")

puppet.position = lua.table_from({"x": 30, "y": 0})
tick(31)
msgs = take()
check(any(m.get("closed") is True for m in guis(msgs, lab)) and any(m["text"] == "Out of reach" for m in of_type(msgs, "msg")),
      "walking out of reach closes the screen")
puppet.position = lua.table_from({"x": 0, "y": 0})
tick(31)
check(not guis(take()), "nothing is sent once closed")

for target, why in ((far_asm, "Out of reach"), (enemy_chest, "another force")):
    send(open_cmd(target))
    tick(2)
    msgs = take()
    check(not guis(msgs) and any(why in m["text"] for m in of_type(msgs, "msg")), f"open refused: {why}")
# D10: from the remote view (rv) a building out of reach opens where radars cover it, or near the
# character, for its settings; items stay out of reach. A headless server reveals nothing itself.
send(dict(open_cmd(far_asm), rv=1))
tick(2)
check(bool(guis(take(), far_asm)), "rv: a building out of reach but near the character opens from the remote view")
covered_asm = spawn("assembling-machine-1", 300.5, 0.5, force="player")
radar = spawn("radar", 330.5, 40.5, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": radar}))  # the bridge keeps radars from build events
bare_asm = spawn("assembling-machine-1", 600.5, 0.5, force="player")
send(dict(open_cmd(covered_asm), rv=1))
tick(2)
msgs = take()
check(bool(guis(msgs, covered_asm)), f"rv: a building in a working radar's nearby chunks opens: {of_type(msgs, 'msg')}")
send({"t": "set_recipe", "u": covered_asm.unit_number, "recipe": "iron-gear-wheel"})
send({"t": "take", "u": covered_asm.unit_number, "inv": "output", "item": "iron-gear-wheel", "n": 1})
tick(31)
msgs = take()
g_rv = guis(msgs, covered_asm)
check(g_rv and g_rv[-1].get("recipe") == "iron-gear-wheel" and any("Out of reach" in m["text"] for m in of_type(msgs, "msg")),
      f"rv: its settings change from afar, items don't move, and it stays open: {g_rv[-1:]}")
send(dict(open_cmd(bare_asm), rv=1))
tick(2)
msgs = take()
check(not guis(msgs, bare_asm) and any("roboport coverage" in m["text"] for m in of_type(msgs, "msg")),
      "rv: a building no radar (or roboport) covers doesn't open")
send(open_cmd(covered_asm))
tick(2)
msgs = take()
check(not guis(msgs, covered_asm) and any("Out of reach" in m["text"] for m in of_type(msgs, "msg")),
      "without rv (the character's own view) it is out of reach, as before")
for e in (covered_asm, radar, bare_asm):
    e.destroy()
send({"t": "close"})
# 2.1.23 opens a plain belt too (its status; tools/ui_reference rules_openable).
send({"t": "open", "u": new_belt[0], "p": new_belt[1], "x": new_belt[2], "y": new_belt[3]})
tick(2)
check(bool(guis(take())), "a belt without wires opens, as in 2.1.23")
send({"t": "close"})

send(open_cmd(chest))
tick(2)
send({"t": "close"})
tick(31)
msgs = take()
check(len(guis(msgs, chest)) == 1, "close stops the screen")
send(open_cmd(chest))
tick(2)
take()
chest.destroy()
tick(31)
msgs = take()
check([m.get("closed") for m in guis(msgs)] == [True], f"a removed entity closes the screen: {guis(msgs)}")
for e in (asm, furnace, lab, far_asm, enemy_chest):
    e.destroy()

# --- inventory slots, moving stacks, quickbar ----------------------------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})


def main_slots():
    g.storage.f3d.slots_sig = None
    tick(31)
    msgs = of_type(take(), "slots")
    return msgs[-1]["l"]["main"] if msgs else []


def slot_of(slots, name):
    return next((i + 1 for i, v in enumerate(slots) if v != 0 and v[0] == name), None)


slots = main_slots()
inv = puppet.get_main_inventory()
check(len(slots) == 80 and slots[slot_of(slots, "iron-plate") - 1][1] == inv.get_item_count("iron-plate"),
      f"slots: the main inventory slot by slot: {slots[:4]}")
wood_at = slot_of(slots, "wood")
send({"t": "move", "from": "main", "fi": wood_at, "to": "main", "ti": 80})
tick(2)
slots = [m for m in of_type(take(), "slots")][-1]["l"]["main"]
check(slots[wood_at - 1] == 0 and slots[79][0] == "wood", f"move: a whole stack to an empty slot, sent at once: {slots[79]}")
plate_at = slot_of(slots, "iron-plate")
plates = slots[plate_at - 1][1]
send({"t": "move", "from": "main", "fi": plate_at, "to": "main", "ti": 79, "n": 3})
tick(2)
slots = of_type(take(), "slots")[-1]["l"]["main"]
check(slots[78] == ["iron-plate", 3] and slots[plate_at - 1] == ["iron-plate", plates - 3], f"move n=3 splits a stack: {slots[78]}")
send({"t": "move", "from": "main", "fi": 80, "to": "main", "ti": 79})
tick(2)
slots = of_type(take(), "slots")[-1]["l"]["main"]
check(slots[78][0] == "wood" and slots[79] == ["iron-plate", 3], "moving onto a different item swaps them")
send({"t": "sort", "inv": "main"})
tick(2)
slots = of_type(take(), "slots")[-1]["l"]["main"]
names = [v[0] for v in slots if v != 0]
check(names == sorted(names) and slots[-1] == 0, f"sort merges and sorts: {names}")

box = spawn("wooden-chest", 2.5, -1.5, force="player")
send(open_cmd(box))
tick(2)
take()
coal_at = slot_of(slots, "coal")
send({"t": "move", "from": "main", "fi": coal_at, "to": "chest", "ti": 3})  # no u: ignored
tick(2)
check(not of_type(take(), "slots"), "a move into a machine needs the open screen's u")
send({"t": "move", "from": "main", "fi": coal_at, "to": "chest", "ti": 3, "u": box.unit_number})
tick(2)
msgs = take()
gui = guis(msgs, box)
check(gui and gui[-1]["slots"]["chest"][2] == ["coal", 3] and gui[-1]["slots"]["chest"][0] == 0
      and of_type(msgs, "slots")[-1]["l"]["main"][coal_at - 1] == 0,
      f"move into an open chest's slot; gui carries its slots: {gui[-1:]}")
send({"t": "move", "from": "chest", "fi": 3, "to": "main", "ti": 80, "u": box.unit_number})
tick(2)
check(of_type(take(), "slots")[-1]["l"]["main"][79] == ["coal", 3], "and back out of it")

# A slot from the chest's limit bar on still accepts manual clicks/moves (the red bar only blocks machines and insert/xfer).
F.inventories[box]["chest"].set_bar(5)
send({"t": "move", "from": "main", "fi": 80, "to": "chest", "ti": 5, "u": box.unit_number})
tick(2)
msgs = take()
gui = guis(msgs, box)
check(F.inventories[box]["chest"][5].valid_for_read is True and F.inventories[box]["chest"][5].name == "coal"
      and gui and gui[-1]["slots"]["chest"][4] == ["coal", 3],
      f"manual move onto a slot beyond the chest's limit bar succeeds: {gui[-1:]}")
send({"t": "move", "from": "chest", "fi": 5, "to": "main", "ti": 80, "u": box.unit_number})
tick(2)
take()
F.inventories[box]["chest"].set_bar(None)

# xfer: Factorio's Shift / Ctrl clicks (stack_transfers' four actions, emulated without a player)
def chest_slots():
    g.storage.f3d.screen.due = 0
    tick(2)
    gui = guis(take(), box)
    return gui[-1]["slots"]["chest"] if gui else []


box_inv = box.get_inventory(1)
inv.insert(lua.table_from({"name": "iron-plate", "count": 40}))
slots = main_slots()
plate_at = slot_of(slots, "iron-plate")
plate_n = slots[plate_at - 1][1]
plates_before = inv.get_item_count("iron-plate")
send({"t": "xfer", "from": "main", "fi": plate_at, "k": "half", "u": box.unit_number})
tick(2)
take()
check(box_inv.get_item_count("iron-plate") == plate_n // 2 and inv.get_item_count("iron-plate") == plates_before - plate_n // 2,
      f"xfer half: the smaller half of the clicked stack into the open chest ({plate_n} -> {box_inv.get_item_count('iron-plate')})")
send({"t": "xfer", "from": "main", "fi": slot_of(main_slots(), "iron-plate"), "k": "all", "u": box.unit_number})
tick(2)
take()
check(inv.get_item_count("iron-plate") == 0 and box_inv.get_item_count("iron-plate") == plates_before,
      "xfer all: every stack of the item into the chest")
shown = chest_slots()
check(sum(s[1] for s in shown if isinstance(s, list) and s[0] == "iron-plate") == plates_before,
      f"xfer all: the open chest's screen shows them ({shown[:4]})")
send({"t": "xfer", "from": "chest", "fi": 1, "k": "stack", "u": box.unit_number})
tick(2)
take()
check(inv.get_item_count("iron-plate") > 0 and box_inv.get_item_count("iron-plate") < plates_before, "xfer stack: a chest stack into the character")
send({"t": "xfer", "from": "chest", "fi": 1, "k": "all"})
tick(2)
check(not of_type(take(), "slots"), "xfer from a screen's inventory needs its u")
send({"t": "xfer", "from": "chest", "fi": len(box_inv), "k": "all", "u": box.unit_number})
tick(2)
take()
check(box_inv.is_empty(), "xfer all from an empty slot moves everything")
guns = puppet.get_inventory(g.defines.inventory.character_guns)
inv.insert(lua.table_from({"name": "pistol", "count": 1}))
had_guns = guns.get_item_count("pistol")
send({"t": "close"})
tick(2)
take()
send({"t": "xfer", "from": "main", "fi": slot_of(main_slots(), "pistol"), "k": "stack"})
tick(2)
take()
check(guns.get_item_count("pistol") == had_guns + 1,
      f"xfer with nothing open: a gun goes to the gun slots ({had_guns} -> {guns.get_item_count('pistol')})")
send({"t": "xfer", "from": "main", "fi": slot_of(main_slots(), "coal") or 1, "k": "stack"})
tick(2)
check(any("Nowhere" in m["text"] for m in of_type(take(), "msg")), "xfer with nothing open: other items stay")
send(open_cmd(box))
tick(2)
take()
send({"t": "move", "from": "main", "fi": 80, "to": "chest", "ti": 1, "u": box.unit_number})
send({"t": "close"})
tick(2)
take()
send({"t": "move", "from": "chest", "fi": 1, "to": "main", "ti": 80, "u": box.unit_number})
tick(2)
check(not of_type(take(), "slots"), "a closed screen's inventory can't be used")
box.destroy()

send({"t": "qb_set", "i": 1, "item": "transport-belt"})
send({"t": "qb_set", "i": 2, "item": "no-such-item"})
send({"t": "qb_sel", "i": 1})
send({"t": "qb_page", "p": 2})
tick(2)
qb = of_type(take(), "qb")
check(len(qb) == 3 and qb[-1]["l"][0] == "transport-belt" and qb[-1]["l"][1] == "" and qb[-1]["held"] == "transport-belt"
      and qb[-1]["sel"] == 1 and qb[-1]["p"] == 2, f"quickbar: set, select (held item), page; unknown items refused: {qb[-1:]}")

# --- recipe details, craftable counts, the crafting queue -------------------------------------------
g.storage.f3d.rdet_sig = None
g.storage.f3d.craftable_sig = None
tick(31)
msgs = take()
details = {r[0]: r for m in of_type(msgs, "rdet") for r in m["l"]}
rdet_msgs = of_type(msgs, "rdet")
check(set(details) == {"iron-gear-wheel", "iron-plate", "oil-processing", "transport-belt"},
      f"rdet: all enabled visible recipes including fluid/machine-only: {sorted(details)}")
check(rdet_msgs and rdet_msgs[0].get("hc") == ["crafting"], f"rdet: hc lists hand categories: {rdet_msgs[0].get('hc')}")
belt_r = details.get("transport-belt", [None] * 10)
check(belt_r[1] == 0.5 and belt_r[2] == ["crafting"] and belt_r[3:8] == ["logistics", "b", "belt", "b", "a[transport-belt]"]
      and belt_r[8] == [["item", "iron-gear-wheel", 1], ["item", "iron-plate", 1]] and belt_r[9] == [["item", "transport-belt", 2]],
      f"rdet: time, categories, group, subgroup, order, ingredients, products: {belt_r}")
craftable = dict(map(tuple, of_type(msgs, "craftable")[-1]["l"])) if of_type(msgs, "craftable") else {}
check(craftable.get("iron-gear-wheel") == inv.get_item_count("iron-plate") // 2,
      f"craftable: how many the character can make now: {craftable}")
# The counts are worked out again only when the inventory changes (230 recipes cost ~22 ms a time
# on the owner's save).
# A stale signature shows whether they were worked out: unchanged contents send nothing.
g.storage.f3d.craftable_sig = "stale"
tick(60)
quiet = of_type(take(), "craftable")
puppet.get_main_inventory().insert(lua.table_from({"name": "iron-plate", "count": 10}))
tick(31)  # a 30th tick that isn't the last, whatever the phase (what it queues goes out a tick later)
again = of_type(take(), "craftable")
check(not quiet and again
      and dict(map(tuple, again[-1]["l"])).get("iron-gear-wheel") == craftable.get("iron-gear-wheel", 0) + 5,
      f"craftable: not worked out again while the inventory stays the same, then again when it changes: {quiet}, {again[-1:]}")
# f3d-spread-jobs: the counts are read a slice of recipes a tick and sent when the last slice is done
# (two hand recipes here: a slice of one takes two ticks after the 30th), off: all on the 30th tick.
crafting_mod = lua.eval('package.loaded["scripts.crafting"]')
crafting_mod.craftable_slice = 1


def craftable_after(count):
    """The ticks after the next 30th tick until `craftable` comes, after `count` more plates."""
    while (g.game.tick + 1) % 30 != 0:
        tick(1)
    take()
    puppet.get_main_inventory().insert(lua.table_from({"name": "iron-plate", "count": count}))
    for t in range(1, 8):
        tick(1)
        got = of_type(take(), "craftable")
        if got:
            return t, dict(map(tuple, got[-1]["l"])).get("iron-gear-wheel")
    return None, None


have = inv.get_item_count("iron-plate")
sliced = craftable_after(10)
check(sliced[0] == 2 and sliced[1] == (have + 10) // 2,
      f"craftable, spread jobs (flush_end on): a slice a tick, flushed at end of the 2nd tick: {sliced}")
check(g.storage.f3d.craft_job is None, "craftable, spread jobs: the job is closed once sent")
g.settings["global"]["f3d-spread-jobs"] = lua.table_from({"value": False})
whole = craftable_after(10)
check(whole[0] == 1 and whole[1] == (have + 20) // 2,
      f"craftable, spread jobs off (flush_end on): all on the 30th tick, flushed same tick: {whole}")
g.storage.f3d_perf = lua.table_from({"flush_end": False})
g.settings["global"]["f3d-spread-jobs"] = lua.table_from({"value": True})
sliced_off = craftable_after(10)
check(sliced_off[0] == 3 and sliced_off[1] == (have + 30) // 2,
      f"craftable, spread jobs (flush_end off): sent when the last is done (30th tick plus two): {sliced_off}")
g.settings["global"]["f3d-spread-jobs"] = lua.table_from({"value": False})
whole_off = craftable_after(10)
check(whole_off[0] == 2 and whole_off[1] == (have + 40) // 2,
      f"craftable, spread jobs off (flush_end off): all on the 30th tick (out a tick later), as before: {whole_off}")
g.storage.f3d_perf = None
g.settings["global"]["f3d-spread-jobs"] = lua.table_from({"value": True})
crafting_mod.craftable_slice = 32
puppet.get_main_inventory().remove(lua.table_from({"name": "iron-plate", "count": 30}))
tick(30)
take()
puppet.crafting_queue_progress = 0.25
tick(10)
cq = of_type(take(), "cq")
check(cq and cq[-1]["l"] == [[1, "iron-gear-wheel", 2, 0]] and cq[-1]["pr"] == 250, f"cq: the crafting queue with progress: {cq[-1:]}")
send({"t": "cancel_craft", "i": 1, "n": 1})
tick(2)
cq = of_type(take(), "cq")
check(cq and cq[-1]["l"] == [[1, "iron-gear-wheel", 1, 0]], f"cancel_craft takes crafts off the queue: {cq[-1:]}")
send({"t": "cancel_craft", "i": 1, "n": 5})
tick(30)
cq = of_type(take(), "cq")
check([m["l"] for m in cq] == [[]], f"an empty queue is sent once: {cq}")
# ... and again every 5 s while it stays empty: `cq` is unreliable, and a lost last one left the
# client showing a finished craft.
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})  # keep-alive
tick(300)
cq = of_type(take(), "cq")
check([m["l"] for m in cq] == [[]], f"an empty queue is sent again every 5 s: {cq}")

# Finished hand-crafts go into the production statistics (2.1.23 leaves a player-less character's
# out, and with them "craft an item" research triggers such as the lab for red science, issue #7).
lua.eval("function() for i = #F.flowed, 1, -1 do F.flowed[i] = nil end end")()
send({"t": "craft", "recipe": "transport-belt", "n": 1})
send({"t": "craft", "recipe": "iron-gear-wheel", "n": 3})
tick(2)
# The game finishing crafts, as the fake shows it: entries leave the front (cancel_crafting called
# here, not through the bridge's command, so the bridge sees only a shorter queue).
finish = lua.eval("""function(gone, left)
  local c = storage.f3d.puppet
  for _ = 1, gone do local f = c.crafting_queue[1]; c.cancel_crafting({ index = f.index, count = f.count }) end
  if left then local f = c.crafting_queue[1]; c.cancel_crafting({ index = f.index, count = f.count - left }) end
end""")
flowed = lambda: [tuple(r.values()) for r in F.flowed.values()]
check(flowed() == [], f"nothing counted while the queue only grows by commands: {flowed()}")
finish(1, 2)
tick(1)
check(flowed() == [("item", "transport-belt", 2), ("item", "iron-gear-wheel", -1), ("item", "iron-plate", -1),
                   ("item", "iron-gear-wheel", 1), ("item", "iron-plate", -2)],
      f"a finished belt and one of three gears counted, products in and ingredients out: {flowed()}")
finish(1, None)
tick(1)
check(flowed()[-2:] == [("item", "iron-gear-wheel", 2), ("item", "iron-plate", -4)] and len(flowed()) == 7,
      f"the last two gears counted when the queue empties: {flowed()}")
tick(5)
check(len(flowed()) == 7, "nothing more once the queue is empty")

