# Bridge test slice 01_world_belts_inserters.py (lines 185-1849 of original test_bridge.py)
# --- world setup ------------------------------------------------------------------------------
spawn("tree-01", 5.3, 7.9)
spawn("iron-ore", 2.5, 1.5, amount=2)
spawn("assembling-machine-1", 10.5, 10.5, force="player")
spawn("transport-belt", 40.5, 3.5, force="player", direction=4)  # chunk (1, 0)
spawn("cliff", 46.0, 10.5, cliff_orientation="north-to-west")  # chunk (1, 0)
spawn("small-biter", 6.0, 6.0, force="enemy")
spawn("car", 3.0, 3.0, force="player")
spawn("explosion", 4.0, 4.0)
spawn("assembling-machine-1-remnants", 20.5, 20.5)  # left by a destroyed assembler
spawn("small-biter-corpse", 22.0, 22.0)  # a corpse, not a remnant: not streamed
spawn("linked-belt", 24.5, 3.5, force="player", linked_belt_type="output")
F.surface.set_tile(1, 1, "concrete")

F.on_init()
tick(5)
check(take() == [], "nothing should be sent before a client says hello")

# --- handshake ----------------------------------------------------------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 0})
tick(4)  # the handshake goes out a few stages a tick under the work budget
msgs = take()
welcome = of_type(msgs, "welcome")
check(len(welcome) == 1, "one welcome after hello")
check(msgs and msgs[0]["t"] == "welcome" and msgs[0]["r"] == 1, "welcome is the first reliable message, r=1")
check(welcome and welcome[0]["u"] > 0, "welcome names the puppet character")
check(welcome and welcome[0].get("mods", {}).get("base") == "2.1.23", "the welcome lists the game's mods and versions")
check(welcome and welcome[0].get("gf") == "00c0ffee12345678" and welcome[0].get("gn") == 2,
      f"... and the graphics list's fingerprint and parts: {welcome[:1]}")
protos = [rec for m in of_type(msgs, "protos") for rec in m["l"]]
names = {rec[1]: rec for rec in protos}
check("assembling-machine-1" in names, "entity prototypes are sent")
check(names.get("assembling-machine-1", [0] * 12)[3:7] == [-1.5, -1.5, 1.5, 1.5], "prototype box is the selection box")
tprotos = [rec for m in of_type(msgs, "tprotos") for rec in m["l"]]
check({rec[1] for rec in tprotos} == {"grass-1", "water", "concrete", "stone-path", "space-platform-foundation", "empty-space"}, "tile prototypes are sent")
check(of_type(msgs, "ready"), "ready marks the end of the handshake")
eprops = of_type(msgs, "eprops")
ep = {rec[0]: rec for rec in eprops[0]["l"]} if eprops else {}
pid = {rec[1]: rec[0] for m in of_type(msgs, "protos") for rec in m["l"]}
check(ep.get(pid["underground-belt"], [0, 0])[1] == 5 and ep.get(pid["small-electric-pole"], [0, 0, 0, 0])[2:] == [7.5, 2.5],
      f"eprops gives underground reach and pole wire reach and supply area: {eprops[:1]}")
over = {name: (ep.get(pid[name]) or [0] * 5)[4:] for name in ("inserter", "roboport", "offshore-pump")}
check(over["inserter"] == [{"ip": [0, -1], "id": [0, 1.2], "rs": 0.014, "es": 0.035}] and over["roboport"] == [{"lr": 25, "cr": 55}]
      and over["offshore-pump"] == [{"fb": [[0, -0.5, 0, "o"]]}],
      f"eprops' overlay: inserter pickup and drop and hand speeds, roboport areas, fluid connections: {over}")
# N9: a storage tank's pipeline joins (`fj`, its four connections from its fluid box prototype), never `fb` (no arrows on
# tanks); a pipe and a pipe to ground carry `pc` on their records instead, and get neither.
tank_ep = ((ep.get(pid["storage-tank"]) or [0] * 5)[4:] or [{}])[0]
pipe_eps = [next((x for x in (ep.get(pid[n]) or [])[4:5] if isinstance(x, dict)), {}) for n in ("pipe", "pipe-to-ground")]
check(tank_ep.get("fj") == [[-1, -1, 0, "b"], [1, 1, 4, "b"], [1, 1, 8, "b"], [-1, -1, 12, "b"]] and "fb" not in tank_ep
      and all("fj" not in x and "fb" not in x for x in pipe_eps),
      f"N9: eprops' fj: a storage tank's four pipeline joins, no fb; none on a pipe or pipe to ground: {tank_ep} {pipe_eps}")
ore_ep = (ep.get(pid["iron-ore"]) or [0] * 5)[4:]
check(ore_ep == [{"ms": "base/sound/axe-mining-test", "rk": "basic-solid"}] and pid["tree-01"] not in ep,
      f"J11: eprops carries an entity's own mining sound (zenith-mining-sounds), none for those without: {ore_ep}")
# Step 5 task 3a: the steps' sounds (zenith-step-sounds) go after eprops, in parts each well under the
# smallest byte budget a tick (4096), the sounds first; names become ids, and a name the game hasn't is left out.
STEP_BUDGET = 4096


def steps_of(msgs):
    """The whole `steps` list from its parts: (parts, sounds, {key: [records]}, u)."""
    parts = of_type(msgs, "steps")
    sounds, lists, u, nv = [], {k: [] for k in ("tl", "el", "dl", "al")}, None, None
    for m in parts:
        sounds += m.get("s", [])
        for k in lists:
            lists[k] += m.get(k, [])
        u = m.get("u", u)
        nv = m.get("nv", nv)
    return parts, sounds, lists, u, nv


kinds = [m["t"] for m in msgs]
st_parts, st_sounds, st_lists, st_u, st_nv = steps_of(msgs)
check(len(st_parts) >= 2 and [m["part"] for m in st_parts] == list(range(1, len(st_parts) + 1))
      and all(m["parts"] == len(st_parts) for m in st_parts)
      and all(len(json.dumps(m, separators=(",", ":"))) < STEP_BUDGET for m in st_parts),
      f"steps: in numbered parts, each under {STEP_BUDGET} bytes: {[len(json.dumps(m)) for m in st_parts]}")
check("eprops" in kinds and kinds.index("steps") > kinds.index("eprops") and kinds.index("steps") < kinds.index("iuse") if "iuse" in kinds
      else "eprops" in kinds and "steps" in kinds and kinds.index("steps") > kinds.index("eprops"),
      "steps: sent after eprops, in the same handshake stage")
tid = {rec[1]: rec[0] for m in of_type(msgs, "tprotos") for rec in m["l"]}
did = {n: lua.eval(f'function() return package.loaded["scripts.registry"].decorative_id("{n}") end')() for n in ("brown-asterisk",)}
iid = lua.eval('function() return package.loaded["scripts.registry"].item_id("power-armor") end')()
step_sound = {k: dict((r[0], r[1:] if k == "al" else r[1]) for r in v) for k, v in st_lists.items()}
check(len(st_sounds) == 86 and st_sounds[0] == ["base/sound/walking/grass", 80, 10]
      and st_sounds[3] == [["my-mod/sound/clank.ogg", "my-mod/sound/clonk.ogg"], 50, 2] and st_u == [4, 0],
      f"steps: every sound once in order, a mod's files as a list; u the utility sounds: {st_sounds[:4]} {st_u}")
check(st_nv == [5, 1], f"steps: nv the night vision equipment's two sounds: {st_nv}")
check(step_sound["tl"] == {tid["grass-1"]: 1, tid["water"]: 0, tid["concrete"]: 2}
      and step_sound["el"] == {pid["straight-rail"]: 3, pid["iron-ore"]: 4}
      and step_sound["dl"] == {did["brown-asterisk"]: 5} and step_sound["al"] == {iid: [6, 0]},
      f"steps: tiles (water silent, an unknown name left out), rails and resources, decoratives, armours by id: {step_sound}")
# L8: a drill's resource categories and that it needs a resource under it; a pumpjack's output arrow shows (no
# fo: its output is always there, a burner drill's has no fluid box); crude oil marked while a pumpjack is held.
pj_ep = (ep.get(pid["pumpjack"]) or [0] * 5)[4:]
oil_ep = (ep.get(pid["crude-oil"]) or [0] * 5)[4:]
burner_ep = (ep.get(pid["burner-mining-drill"]) or [0] * 5)[4:]
check(pj_ep and pj_ep[0].get("rk") == ["basic-fluid"] and pj_ep[0].get("rr") == 1 and "fo" not in pj_ep[0]
      and pj_ep[0].get("fb") == [[1, -1, 0, "o"]] and pj_ep[0].get("mr") == 0.49,
      f"L8: the pumpjack's eprops: what it mines, needs a resource, its output shown (no fo): {pj_ep}")
check(oil_ep and oil_ep[0].get("rk") == "basic-fluid" and oil_ep[0].get("hl") == 1
      and burner_ep and burner_ep[0].get("rk") == ["basic-solid"] and "hl" not in ore_ep[0],
      f"L8: crude oil is marked for a held pumpjack (hl), ore isn't; a burner drill mines basic-solid: {oil_ep} {burner_ep}")
# A resource that needs fluid to be mined carries rf (uranium ore's sulfuric acid); ore that doesn't, none.
uran_ep = (ep.get(pid["uranium-ore"]) or [0] * 5)[4:]
check(uran_ep and uran_ep[0].get("rf") == 1 and uran_ep[0].get("rk") == "basic-solid" and "rf" not in ore_ep[0],
      f"eprops: uranium ore needs fluid to be mined (rf 1), iron ore doesn't: {uran_ep} {ore_ep}")
# K1, K2: where Alt-mode draws an entity's icon (icon_draw_specification, when not the default) and
# the rows of its modules and a lab's packs (icons_positioning; Factorio's defaults without one).
alt_ep = {name: ((ep.get(pid[name]) or [0] * 5)[4:] or [{}])[0] for name in ("assembling-machine-1", "lab", "beacon", "wooden-chest", "inserter")}
check(alt_ep["assembling-machine-1"].get("ids") == [0, -0.3, 1]
      and alt_ep["assembling-machine-1"].get("isq") == [["m", 0, 0.7, 0.5, 4, 2, 1.1, -0.1]]
      and alt_ep["lab"].get("isq") == [["m", 0, 0.9, 0.5, 4, 2, 1.1, -0.1], ["l", 0, 0, 0.5, 6, 2, 0.909, -0.1]]
      and alt_ep["beacon"].get("isq") == [["m", 0, 0, 0.5, 2, 2, 1.1, -0.3]] and "ids" not in alt_ep["lab"]
      and alt_ep["wooden-chest"].get("ids") == [0, 0, 0.7] and "isq" not in alt_ep["wooden-chest"] and "ids" not in alt_ep["inserter"],
      f"K1, K2: eprops' ids and isq: a machine's icon shift, its modules' row (defaults), a lab's packs and modules, a beacon's: {alt_ep}")
# K1's leftover: an ammo turret's ammo and a locomotive's fuel, by their icons_positioning as 2.1.24 gives them
# (the gun turret's {0, -0.25}, the locomotive's {0, 0.3} three a row); an ammo turret without one, the defaults.
stock_ep = {name: next((x for x in (ep.get(pid[name]) or [])[4:5] if isinstance(x, dict)), {}) for name in ("gun-turret", "locomotive", "car")}
alt_mode_mod0 = lua.eval('package.loaded["scripts.alt_mode"]')
plain_turret = to_py(alt_mode_mod0.sequences(lua.table_from({"name": "k1-plain-turret", "type": "ammo-turret",
                                                             "selection_box": lua.table_from([lua.table_from([-1.5, -1.5]), lua.table_from([1.5, 1.5])])})))
check(stock_ep["gun-turret"].get("isq") == [["a", 0, -0.25, 0.5, 2, 1, 1.1, -0.1]]
      and stock_ep["locomotive"].get("isq") == [["f", 0, 0.3, 0.5, 3, 4, 1.1, -0.1]] and "isq" not in stock_ep["car"]
      and plain_turret == [["a", 0, 0.7, 0.5, 4, 2, 1.1, -0.1]],
      f"K1: eprops' isq has a gun turret's ammo row and a locomotive's fuel row, an ammo turret without one the defaults, a car none: {stock_ep} {plain_turret}")
wall_ep = (ep.get(pid["stone-wall"]) or [0] * 5)[4:]
check(wall_ep and wall_ep[0].get("rsd") == "base/sound/manual-repair-simple" and "rsd" not in ((ep.get(pid["iron-ore"]) or [0] * 5)[4:] or [{}])[0],
      f"K13: eprops carries an entity's own repair sound (rsd), none for those without: {wall_ep}")
iuse = {(rec[0], rec[1]): rec for m in of_type(msgs, "iuse") for rec in m["l"]}
check(iuse.get(("repair-pack", "h")) == ["repair-pack", "h", 2, 300] and ("iron-plate", "h") not in iuse,
      f"K13: iuse: a repair tool with its speed and durability: {iuse.get(('repair-pack', 'h'))}")
tid = {rec[1]: rec[0] for rec in tprotos}
check(iuse.get(("speed-module", "m")) == ["speed-module", "m", "speed"] and ("wooden-chest", "m") not in iuse,
      f"iuse: modules and their category (F6: the client asks for them by clicking): {iuse.get(('speed-module', 'm'))}")
# Concrete goes where water doesn't collide: not on water, nor on empty space (it collides like water).
check(iuse.get(("concrete", "t")) == ["concrete", "t", "concrete", "", sorted(tid[n] for n in ("grass-1", "stone-path", "space-platform-foundation"))]
      and iuse.get(("grenade", "c")) == ["grenade", "c", "throw", 15, 0] and iuse.get(("cliff-explosives", "c")) == ["cliff-explosives", "c", "destroy-cliffs", 10, 1.5]
      and iuse.get(("rail", "r")) == ["rail", "r", "rail-support", 0] and iuse.get(("transport-belt", "b")) == ["transport-belt", "b", "underground-belt"],
      f"iuse: tiles (what they may go on), capsules, the rail planner, a belt's underground: {sorted(iuse.values())}")
inv = of_type(msgs, "inv")
check(inv and ["iron-plate", 8] in inv[0]["l"], "starter kit shows up in the inventory")
recipes = of_type(msgs, "recipes")
check(recipes and sorted(recipes[0]["l"]) == ["iron-gear-wheel", "transport-belt"],
      "recipe list has enabled hand-craftable recipes only (2.1 'categories' API)")
eid = {rec[1]: rec[0] for rec in protos}
iprotos = [rec for m in of_type(msgs, "iprotos") for rec in m["l"]]
iid = {rec[1]: rec[0] for rec in iprotos}
fid = {rec[1]: rec[0] for m in of_type(msgs, "fprotos") for rec in m["l"]}
check(set(fid) == {"water", "steam"}, f"fluid prototypes are sent: {sorted(fid)}")
check({"iron-plate", "iron-gear-wheel", "transport-belt"} <= set(iid), "item prototypes are sent")
places = {rec[1]: rec[2] for rec in iprotos if len(rec) > 2}
check(places.get("rocket") == "" and places.get("rail") == "straight-rail" and "transport-belt" not in places,
      f"#2: an item named like an entity it doesn't build (rocket, the projectile) says so with \"\": {places}")
planet = of_type(msgs, "planet")
check(planet and planet[-1]["name"] == "nauvis" and planet[-1]["props"].get("gravity") == 10 and planet[-1]["day"] == 25000
      and planet[-1]["dusk"] == 250 and [eid["heating-tower"], 12] in planet[-1]["heat"],
      f"planet: the surface's planet, properties, day and heating radii come with the handshake: {planet[-1:]}")
check(msgs.index(of_type(msgs, "iprotos")[0]) < msgs.index(of_type(msgs, "ready")[0]), "item prototypes come before ready")
check(not of_type(msgs, "clog"), "no clog before the force has character logistic requests (no requester point)")
# A save made with an older bridge (on_configuration_changed): what its storage lacks is made again.
g.storage.f3d.damaged = None
g.storage.f3d.wire_sigs = None
F.on_config(lua.table_from({"mod_changes": {}}, recursive=True))
check(g.storage.f3d.damaged is not None and g.storage.f3d.wire_sigs is not None and g.storage.f3d.client is not None,
      "on_configuration_changed makes the tables an older save lacks, and keeps the client")

# --- chunk subscription ----------------------------------------------------------------------
send({"t": "sub", "c": [[0, 0], [1, 0], [9, 9]]})
send({"t": "focus", "x": 0, "y": 0, "r": 48})
tick(25)  # long enough to include a machine-state report (every 30 ticks)
msgs = take()
chunks = {(m["cx"], m["cy"]): m for m in of_type(msgs, "chunk")}
check(set(chunks) == {(0, 0), (1, 0), (9, 9)}, f"one chunk message per subscription, got {sorted(chunks)}")
check(chunks.get((9, 9), {}).get("none") is True, "ungenerated chunk is reported as none")
c00 = chunks.get((0, 0), {})
rle = c00.get("tiles", [])
check(sum(rle[1::2]) == 1024, "tile RLE covers all 32x32 tiles")
tile_id = {rec[1]: rec[0] for rec in tprotos}
check(rle[:6] == [tile_id["grass-1"], 33, tile_id["concrete"], 1, tile_id["grass-1"], 990],
      f"tile RLE is row-major with the concrete tile at (1, 1): {rle[:6]}")
ents = {}
for m in of_type(msgs, "ents"):
    for rec in m["e"]:
        ents.setdefault((m["cx"], m["cy"]), []).append(rec)
static00 = {rec[1] for rec in ents.get((0, 0), [])}
check(static00 == {eid["tree-01"], eid["iron-ore"], eid["assembling-machine-1"], eid["assembling-machine-1-remnants"],
                   eid["linked-belt"]},
      f"chunk (0,0) holds the tree, ore, assembler, remnants and linked belt, not movers, effects or corpses: {static00}")
remnant = [rec for rec in ents.get((0, 0), []) if rec[1] == eid["assembling-machine-1-remnants"]]
check(remnant and remnant[0][0] == 0 and remnant[0][5] == {"rm": eid["assembling-machine-1"]},
      f"remnants carry what they were left by: {remnant}")
linked = [rec for rec in ents.get((0, 0), []) if rec[1] == eid["linked-belt"]]
check(linked and linked[0][5].get("u") == "o", f"a linked belt carries its end: {linked}")
# The chunk cache: a snapshot carries its change count and entity count; a client that kept the
# chunk offers them when it subscribes again and gets `same` while nothing changed there.
check(isinstance(c00.get("rv"), int) and isinstance(c00.get("rs"), int) and c00.get("n") == len(ents.get((0, 0), [])) - 1,
      f"a chunk carries its surface, change count and entity count (remnants aside): rs {c00.get('rs')} rv {c00.get('rv')} n {c00.get('n')}")
offer = [c00.get("rs"), 0, 0, c00.get("rv"), c00.get("n")]
send({"t": "sub", "c": [[1, 0], [9, 9]]})
tick(2)
take()
send({"t": "sub", "c": [[0, 0], [1, 0], [9, 9]], "h": [offer]})
tick(10)
again = [m for m in of_type(take(), "chunk") if (m["cx"], m["cy"]) == (0, 0)]
check(len(again) == 1 and again[0].get("same") == c00.get("rv") and "tiles" not in again[0],
      f"an unchanged chunk offered from the client's cache is answered with same: {again}")
lua.eval('package.loaded["scripts.world"]').bump(c00.get("rs"), lua.table_from({"x": 5, "y": 5}))
send({"t": "sub", "c": [[1, 0], [9, 9]]})
tick(2)
take()
send({"t": "sub", "c": [[0, 0], [1, 0], [9, 9]], "h": [offer]})
tick(10)
again = [m for m in of_type(take(), "chunk") if (m["cx"], m["cy"]) == (0, 0)]
check(len(again) == 1 and "same" not in again[0] and again[0].get("rv") == c00.get("rv") + 1 and again[0].get("tiles"),
      f"a chunk changed since the client kept it is sent in full, with its new count: {[{k: v for k, v in m.items() if k != 'tiles'} for m in again]}")
# I18: a client whose hello says lv is told, a tick or so after a chunk leaves its square, the counts
# its copy matches (`kept`), so it can offer them later; not when the chunk changed meanwhile.
c00_now = again[0] if again else {}
g.storage.f3d.client.lv = True
send({"t": "sub", "c": [[1, 0], [9, 9]]})
tick(3)
kept = of_type(take(), "kept")
check(len(kept) == 1 and kept[0].get("rs") == c00.get("rs") and kept[0].get("l") == [0, 0, c00_now.get("rv"), c00_now.get("n")],
      f"a chunk dropped unchanged is told as kept with its change and entity counts: {kept}")
send({"t": "sub", "c": [[0, 0], [1, 0], [9, 9]], "h": [[c00.get("rs"), 0, 0, c00_now.get("rv"), c00_now.get("n")]]})
tick(10)
again = [m for m in of_type(take(), "chunk") if (m["cx"], m["cy"]) == (0, 0)]
check(len(again) == 1 and again[0].get("same") == c00_now.get("rv"), f"and offered back with them it is answered with same: {again}")
send({"t": "sub", "c": [[1, 0], [9, 9]]})
lua.eval('package.loaded["scripts.world"]').bump(c00.get("rs"), lua.table_from({"x": 5, "y": 5}))
tick(3)
check(not of_type(take(), "kept"), "a chunk that changed after it was dropped isn't told as kept")
g.storage.f3d.client.lv = False
send({"t": "sub", "c": [[0, 0], [1, 0], [9, 9]]})
tick(10)
take()
gone = spawn("small-remnants", 12.5, 14.5)  # what a destroyed chest leaves
F["raise"]("on_post_entity_died", lua.table_from({"corpses": lua.table_from([gone])}))
tick(1)
added = [m for m in of_type(take(), "add") if m["e"][1] == eid["small-remnants"]]
check(added and added[0]["e"][5] == {"rm": 0},
      f"a death's remnants are sent as they appear; shared ones name no single source: {added}")
# The owner's "when I die I need to be able to see my corpse" (corpses.lua): a dead character's corpse
# is sent as it appears, gets a skull marker on the map, and its going (mined, emptied) sends `del` and
# takes the marker away. f3d-character-corpses off: neither.
F.charted["0,0"] = True
tags_before, tag_number_before = len(F.tags), F.tag_number
body = spawn("character-corpse", 9.5, 10.5)  # neutral, as in 2.1.24: the marker goes on the player force
F["raise"]("on_post_entity_died", lua.table_from({
    "prototype": g.prototypes.entity["character"], "position": lua.table_from({"x": 9.4, "y": 10.4}),
    "surface_index": 1, "corpses": lua.table_from([])}))
tick(1)
added = [m for m in of_type(take(), "add") if m["e"][1] == eid["character-corpse"]]
check(added and added[0]["e"][0] == 0 and added[0]["e"][2:4] == [fixed(9.5), fixed(10.5)],
      f"a character's corpse is sent as it appears, by prototype and place: {added}")
skulls = [t for t in list(F.tags.values())[tags_before:]] if len(F.tags) > tags_before else []
check(len(F.tags) == tags_before + 1 and skulls[0].icon.name == "signal-skull"
      and (skulls[0].position.x, skulls[0].position.y) == (9.5, 10.5),
      f"and marked on the map where it lies with the skull: {len(F.tags) - tags_before} new tag(s)")
F["raise"]("on_post_entity_died", lua.table_from({
    "prototype": g.prototypes.entity["character"], "position": lua.table_from({"x": 9.5, "y": 10.5}),
    "surface_index": 1, "corpses": lua.table_from([])}))
tick(1)
check(not [m for m in of_type(take(), "add") if m["e"][1] == eid["character-corpse"]] and len(F.tags) == tags_before + 1,
      "a corpse already sent isn't sent or marked again")
body.destroy()
tick(2)
gone_msgs = [m for m in of_type(take(), "del") if m.get("p") == eid["character-corpse"]]
check(gone_msgs and gone_msgs[0]["x"] == fixed(9.5) and gone_msgs[0]["u"] == 0 and len(F.tags) == tags_before,
      f"a corpse that goes (mined or emptied) is deleted and its marker removed: {gone_msgs}, tags {len(F.tags) - tags_before}")
g.settings["global"]["f3d-character-corpses"] = lua.table_from({"value": False})
body = spawn("character-corpse", 11.5, 10.5)
F["raise"]("on_post_entity_died", lua.table_from({
    "prototype": g.prototypes.entity["character"], "position": lua.table_from({"x": 11.5, "y": 10.5}),
    "surface_index": 1, "corpses": lua.table_from([])}))
tick(1)
check(not [m for m in of_type(take(), "add") if m["e"][1] == eid["character-corpse"]] and len(F.tags) == tags_before,
      "f3d-character-corpses off: a corpse is neither sent nor marked (as before)")
g.settings["global"]["f3d-character-corpses"] = lua.table_from({"value": True})
body.destroy()
tick(2)
take()
F.tag_number = tag_number_before  # (the map tag checks further on count from the first tag)
# D7: the queue follows the client's order (nearest the character first) whatever queued a chunk:
# after a jump, chunks still queued for the old place and land generated later go by distance.
queue_after = lua.eval("""function()
  local W = package.loaded["scripts.world"]
  local s = storage.f3d
  local saved_subs, saved_queue, saved_queued, saved_rank = s.subs, s.queue, s.queued, s.rank
  s.subs, s.queue, s.queued, s.rank = {}, {}, {}, {}
  W.subscribe({ { 0, 0 }, { 1, 0 }, { 2, 0 }, { 3, 0 } })
  W.subscribe({ { 3, 0 }, { 4, 0 }, { 2, 0 }, { 5, 0 }, { 1, 0 } })  -- jumped east: 0,0 dropped
  local first = table.concat(s.queue, " ")
  table.remove(s.queue, 1)  -- 3,0 sent
  s.queued["3,0"] = nil
  W.on_chunk_generated(game.surfaces[1], { x = 3, y = 0 })  -- generated again: first again
  W.enqueue("9,9")  -- not subscribed: last
  local second = table.concat(s.queue, " ")
  s.subs, s.queue, s.queued, s.rank = saved_subs, saved_queue, saved_queued, saved_rank
  return first .. "|" .. second
end""")()
check(queue_after == "3,0 4,0 2,0 5,0 1,0|3,0 4,0 2,0 5,0 1,0 9,9",
      f"the chunk queue keeps the client's nearest-first order after a jump and as chunks are generated (D7): {queue_after}")
# View distance 50: the client sends its square as rows of runs (`sub` o, r, w), not a list.
square = lua.eval("""function()
  local W = package.loaded["scripts.world"]
  local s = storage.f3d
  local saved = { s.subs, s.queue, s.queued, s.rank, s.order, s.have }
  s.subs, s.queue, s.queued, s.rank, s.order, s.have = {}, {}, {}, {}, {}, {}
  local out = {}
  -- 3x3 round (10, 10), its middle row in two runs, a row outside the square: queued nearest first,
  -- in the client's ring_order (squared distance, then row by row).
  W.subscribe_square({ 10, 10 }, 1, { { 9, 9, 3 }, { 10, 9, 1, 10, 2 }, { 11, 9, 3 }, { 30, 0, 5 } })
  out[#out + 1] = table.concat(s.queue, " ") .. "|" .. #s.order .. "|" .. s.order[1]
  -- Walked a chunk east: the west column goes, the east one comes, in order round the new middle.
  s.queue, s.queued = {}, {}
  W.subscribe_square({ 11, 10 }, 1, { { 9, 10, 3 }, { 10, 10, 3 }, { 11, 10, 3 } })
  local keys = {}
  for k in pairs(s.subs) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  out[#out + 1] = table.concat(keys, " ") .. "|" .. table.concat(s.queue, " ")
  -- The same square again changes nothing; a resend queues it all, nearest first.
  W.subscribe_square({ 11, 10 }, 1, { { 9, 10, 3 }, { 10, 10, 3 }, { 11, 10, 3 } })
  W.resend_all()
  out[#out + 1] = table.concat(s.queue, " ")
  -- I18: looking north (f), the chunks behind count as further away: south after the sides.
  s.subs, s.queue, s.queued, s.rank, s.order = {}, {}, {}, {}, {}
  s.sub_o, s.sub_r, s.sub_rows, s.sub_n = nil, nil, nil, nil
  W.subscribe_square({ 10, 10 }, 1, { { 9, 9, 3 }, { 10, 9, 3 }, { 11, 9, 3 } }, nil, { 0, -256 })
  out[#out + 1] = table.concat(s.queue, " ")
  -- Malformed ones are ignored.
  out[#out + 1] = tostring(W.subscribe_square({ "x" }, 1, {})) .. " " .. tostring(W.subscribe_square({ 0, 0 }, 0 / 0, {}))
    .. " " .. tostring(W.subscribe_square({ 0, 0 }, 1, "rows"))
  s.subs, s.queue, s.queued, s.rank, s.order, s.have = saved[1], saved[2], saved[3], saved[4], saved[5], saved[6]
  s.sub_o, s.sub_r, s.sub_rows, s.sub_n, s.sub_f = nil, nil, nil, nil, nil
  return table.concat(out, "\\n")
end""")().split("\n")
check(square[0] == "10,10 10,9 9,10 11,10 10,11 9,9 11,9 9,11 11,11|9|10,10",
      f"a square subscription queues its chunks nearest its middle first, as the client orders them: {square[0]}")
check(square[1] == "10,10 10,11 10,9 11,10 11,11 11,9 12,10 12,11 12,9|12,10 12,9 12,11",
      f"walking, a square subscription drops and adds only the columns that changed: {square[1]}")
check(square[2] == "11,10 11,9 10,10 12,10 11,11 10,9 12,9 10,11 12,11", f"resend_all keeps a square's order: {square[2]}")
check(square[3] == "10,10 10,9 9,10 11,10 9,9 11,9 10,11 9,11 11,11",
      f"with a view direction the chunks behind it are queued later (I18): {square[3]}")
check(square[4] == "false false false", f"malformed square subscriptions are ignored: {square[4]}")
belt = [rec for rec in ents.get((1, 0), []) if rec[1] == eid["transport-belt"]]
check(belt and belt[0][2:5] == [40 * 256 + 128, 3 * 256 + 128, 4] and belt[0][5] == {"s": "s"},
      "belt record: fixed-point position, direction, shape")
cliff = [rec for rec in ents.get((1, 0), []) if rec[1] == eid["cliff"]]
check(cliff and cliff[0][0] == 0 and cliff[0][5] == {"co": "north-to-west"}, f"a cliff carries its orientation: {cliff}")
ore = [rec for rec in ents.get((0, 0), []) if rec[1] == eid["iron-ore"]]
check(ore and ore[0][0] == 0 and ore[0][5] == {"a": 2}, "ore has no unit number and carries its amount")
movers = [rec for m in of_type(msgs, "mv") for rec in m["l"]]
mover_protos = {rec[1] for rec in movers}
# Owner's #9: a rocket waiting in its silo has no unit number in 2.1.23; it gets a stable id above
# every unit number.
waiting = spawn("rocket-silo-rocket", 4.5, -6.5, force="player")
tick(12)  # movers.lua searches for new movers every 8 ticks
rk_ids = [rec[0] for m in of_type(take(), "mv") for rec in m["l"] if rec[1] == eid["rocket-silo-rocket"]]
check(rk_ids and all(i == rk_ids[0] and i > 2 ** 40 for i in rk_ids), f"a rocket waiting in a silo is sent as a mover with a stable id: {rk_ids[:3]}")
waiting.destroy()
# Multiplayer: registering is game state, so only what the movers' search found is registered (on
# every peer on the same tick), never the list sent: a peer that loaded since sends from a list of
# its own until the next search, which may hold a rocket the search didn't.
mv_last = int(g.storage.f3d.mv_scan.tick)
while int(g.storage.f3d.mv_scan.tick) == mv_last:
    tick(1)
waiting2 = spawn("rocket-silo-rocket", 4.5, -12.5, force="player")
check(g.F_forget(g.package.loaded["scripts.movers"].tick, "scans"), "the movers' list can be forgotten")
tick(3)  # (the search is every 8 ticks)
own_list_reg = F.registered[waiting2]
tick(10)
rk2 = [rec[0] for m in of_type(take(), "mv") for rec in m["l"] if rec[1] == eid["rocket-silo-rocket"]]
check(own_list_reg is None and F.registered[waiting2] is not None and rk2 and rk2[-1] == 2 ** 40 + F.registered[waiting2],
      f"a mover without a unit number is registered by the search, not by a peer's own list: {own_list_reg}, then {rk2[-1:]}")
waiting2.destroy()
check(eid["small-biter"] in mover_protos and eid["car"] in mover_protos and eid["character"] in mover_protos,
      "movers stream the biter, car and puppet")
car = [rec for rec in movers if rec[1] == eid["car"]]
check(car and car[0][4] == 250, "car orientation is sent in thousandths")
check(of_type(msgs, "me"), "puppet state is streamed")
st = of_type(msgs, "st")
check(st and st[0]["l"][1] == 1, "working machines are reported")
bi = of_type(msgs, "bi")
check(bi and all(m["l"] == [] for m in bi), "belt item updates are sent, empty while no belt near the focus has items")
check(not of_type(msgs, "dec") and not of_type(msgs, "dprotos"), "no decoratives for a client that didn't ask for them (dc)")

# --- decoratives --------------------------------------------------------------------------------
F.add_decorative(F.surface, "green-carpet-grass", 3, 4, 2)
F.add_decorative(F.surface, "small-rock", 40, 5)
F.add_decorative(F.surface, "brown-asterisk", 300, 300)  # in no subscribed chunk
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "dc": 1})
tick(25)
msgs = take()
did = {rec[1]: rec[0] for m in of_type(msgs, "dprotos") for rec in m["l"]}
check(set(did) == {"green-carpet-grass", "brown-asterisk", "small-rock"}, f"dc in the hello sends the decorative dictionary: {did}")
dec = {}
for m in of_type(msgs, "dec"):
    dec.setdefault((m["cx"], m["cy"]), []).extend(m["l"])
check(dec.get((0, 0)) == [did.get("green-carpet-grass"), 3, 4, 2] and dec.get((1, 0)) == [did.get("small-rock"), 8, 5, 1]
      and set(dec) == {(0, 0), (1, 0)},
      f"and the subscribed chunks again with their decoratives (id, tile in the chunk, amount): {dec}")
lua.eval("function(s, n) local keep = {} for _, d in ipairs(s.decoratives) do if d.name ~= n then keep[#keep + 1] = d end end s.decoratives = keep end")(
    F.surface, "green-carpet-grass")
world_mod = g.package.loaded["scripts.world"]
rev_before = world_mod.rev(1, "0,0")
F["raise"]("on_player_built_tile", lua.table_from({"surface_index": 1, "tiles": lua.table_from([lua.table_from(
    {"position": lua.table_from({"x": 3, "y": 4}), "old_tile": "grass-1"})])}))
tick(30)
dec = [m for m in of_type(take(), "dec")]
check(len(dec) == 1 and (dec[0]["cx"], dec[0]["cy"]) == (0, 0) and dec[0]["l"] in ([], {}),
      f"a tile placed in a chunk sends its decoratives again (now none): {dec}")
check(world_mod.rev(1, "0,0") == rev_before + 1, f"and raises its change count once: {rev_before} -> {world_mod.rev(1, '0,0')}")
rev_before = world_mod.rev(1, "1,0")
F["raise"]("script_raised_built", lua.table_from({"entity": spawn("wooden-chest", 40.5, 5.5, force="player")}))
tick(30)
dec = [(m["cx"], m["cy"]) for m in of_type(take(), "dec")]
check(dec == [(1, 0)], f"building in a chunk sends its decoratives again: {dec}")
check(world_mod.rev(1, "1,0") == rev_before + 1, f"and raises its change count once: {rev_before} -> {world_mod.rev(1, '1,0')}")
wide_e = spawn("assembling-machine-1", 31.5, 20.5, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": wide_e}))
tick(30)
dec = sorted((m["cx"], m["cy"]) for m in of_type(take(), "dec"))
check(dec == [(0, 0), (1, 0)], f"a building over a chunk's edge sends both chunks' decoratives again: {dec}")
wide_e.destroy()
tick(90)  # 120 ticks in all: the belt checks below run on the tick phase they had
take()
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(30)
F["raise"]("script_raised_built", lua.table_from({"entity": spawn("wooden-chest", 41.5, 5.5, force="player")}))
tick(30)
check(not of_type(take(), "dec"), "a hello without dc turns decoratives off")

# --- items on belts ---------------------------------------------------------------------------
belt_e = spawn("transport-belt", 8.5, 2.5, force="player", direction=4)
under_e = spawn("underground-belt", 9.5, 2.5, force="player", direction=4)
F.put_on_belt(belt_e, 1, "iron-plate", 0.25, 7)
F.put_on_belt(belt_e, 2, "iron-gear-wheel", 0.75, 8)
F.put_on_belt(under_e, 1, "iron-plate", 0.2, 9)
F.put_on_belt(under_e, 3, "iron-plate", 0.5, 10)  # in the tunnel
far_e = spawn("transport-belt", 40.5, 10.5, force="player")  # outside the 24-tile item radius
F.put_on_belt(far_e, 1, "iron-plate", 0.5, 11)
tick(6)
msgs = take()
bi = of_type(msgs, "bi")
check(len(bi) == 1, f"one belt item update every 6 ticks, got {len(bi)}")
items = {}
for m in bi:
    l = m["l"]
    for i in range(0, len(l), 4):
        items[l[i]] = l[i + 1:i + 4]
check(set(items) == {7, 8, 9}, f"items on belts near the focus are sent, not the tunnel or far ones: {sorted(items)}")
check(all(m.get("fx") == fixed(0) and m.get("fy") == fixed(0) and m.get("fr") == 24 for m in bi),
      f"each bi part says which square it covers (focus, radius), for the hand-over to lane icons (G16): {[(m.get('fx'), m.get('fy'), m.get('fr')) for m in bi]}")
# And what reading it took (work units, w; w / p a tick): Moving belt items' Automatic keeps it
# within its share of the server's tick.
check(all(isinstance(m.get("w"), int) and m["w"] > 0 for m in bi) and len({m["w"] for m in bi}) == 1,
      f"each bi part says the update's work units (w), the same in every part: {[m.get('w') for m in bi]}")
# Line positions count from the exit edge (2.1.23): 0.25 is a quarter tile before the east edge.
check(items.get(7) == [iid["iron-plate"], 8 * 256 + 192, 580],
      f"left lane of an east belt is north of its centre: {items.get(7)}")
check(items.get(8) == [iid["iron-gear-wheel"], 8 * 256 + 64, 700],
      f"right lane is south; position 0.75 is nearer the entry edge: {items.get(8)}")
# Too many items: the square shrinks to the last whole ring round the focus instead of stopping
# wherever Factorio's belt order got to (whole patches of a dense base went bare).
belt_mod = lua.eval('package.loaded["scripts.belt_items"]')
# The cap counts each lane checked as well as the items: the belt 8 tiles out is 2 items and 2 lanes.
belt_mod.max_items = 4
tick(12)
capped = of_type(take(), "bi")
capped_items = {capped[0]["l"][i] for i in range(0, len(capped[0]["l"]), 4)} if capped else set()
check(capped_items == {7, 8} and all(m.get("fr") == 9 for m in capped),
      f"over the cap, the nearest whole rings are sent (8 tiles out) and fr says the square shrank to 9: {sorted(capped_items)} {[m.get('fr') for m in capped]}")
# The edge holds still: one more item inside it (5 against a cap of 4) keeps fr where it was rather
# than flipping to the ring before (owner: the zones went back and forth standing still).
F.put_on_belt(belt_e, 1, "iron-plate", 0.75, 77)
tick(12)
kept = of_type(take(), "bi")
F.move_on_belt(belt_e, 1, 77, None)
check(kept and all(m.get("fr") == 9 for m in kept),
      f"a count a little over the cap keeps the last edge (fr 9): {[m.get('fr') for m in kept]}")
# A cap well under what the edge holds shrinks the square.
belt_mod.max_items = 1
tick(12)
shrunk = of_type(take(), "bi")
belt_mod.max_items = 4
tick(12)
take()
check(shrunk and shrunk[-1].get("fr") < 9, f"a much smaller cap shrinks the square: {[m.get('fr') for m in shrunk]}")
belt_mod.max_items = 6000
tick(6)
plain = take()
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1})
tick(6)
coded_msgs = take()
bi = of_type(coded_msgs, "bi")
coded = {}
for m in bi:
    l, prev = m["l"], [0, 0, 0, 0]
    for i in range(0, len(l), 4):
        prev = [p + d for p, d in zip(prev, l[i:i + 4])]
        coded[prev[0]] = prev[1:]
check(bi and all(m.get("z") == 1 for m in bi) and coded == items,
      f"a client that asks for z gets the same items delta-coded: {coded}")
# An underground entrance's lines 3 and 4 run under the ground from its middle (BELT-RULES section
# 3): never read, not even an item at the tunnel's very start, on the entrance's edge (inside its box
# give or take 0.05: the client put it on the belt the underground passes under, truth-findings 7),
# and an item read on the entrance that went in isn't carried on from there (it was drawn over the
# gap); the client carries it under the ground itself.


def ids_of(msgs):
    out = set()
    for m in of_type(msgs, "bi"):
        l, prev = m["l"], [0, 0, 0, 0]
        for i in range(0, len(l), 4):
            prev = [p + d for p, d in zip(prev, l[i:i + 4])] if m.get("z") else l[i:i + 4]
            out.add(prev[0])
    return out


F.put_on_belt(under_e, 4, "iron-plate", 0.0, 4710)
F.put_on_belt(under_e, 2, "iron-plate", 0.1, 4711)
tick(6)
went_in_before = ids_of(take())
F.move_on_belt(under_e, 2, 4711, None)
F.put_on_belt(under_e, 4, "iron-plate", 0.02, 4711)
tick(6)
went_in_after = ids_of(take())
F.move_on_belt(under_e, 4, 4710, None)
F.move_on_belt(under_e, 4, 4711, None)
check(4711 in went_in_before and 4710 not in went_in_before and not ({4710, 4711} & went_in_after),
      f"an entrance's tunnel lines aren't sent, even at its edge, nor an item that went in carried on: {sorted(went_in_before & {4710, 4711})} then {sorted(went_in_after & {4710, 4711})}")


def lane_update(msgs):
    """{lane key: [unique ids]} sent in a bi update (ln runs over each part's items), and dl."""
    lanes, dropped = {}, []
    for m in of_type(msgs, "bi"):
        l, prev, ids = m["l"], [0, 0, 0, 0], []
        for i in range(0, len(l), 4):
            prev = [p + d for p, d in zip(prev, l[i:i + 4])] if m.get("z") else l[i:i + 4]
            ids.append(prev[0])
        ln, at = m.get("ln", []), 0
        for i in range(0, len(ln), 2):
            lanes.setdefault(ln[i], []).extend(ids[at:at + ln[i + 1]])
            at += ln[i + 1]
        dropped += m.get("dl", [])
    return lanes, dropped


def last_update(msgs):
    """lane_update of the latest bi update in msgs only (with lanes kept, every other round is read
    a tick early, so a change made between ticks may show one update later)."""
    bi = of_type(msgs, "bi")
    k = max((m["k"] for m in bi), default=None)
    return lane_update([m for m in msgs if m.get("t") != "bi" or m["k"] == k])


# Lanes that don't change aren't read or sent again (`bl`): checked by count and end positions,
# read once more to see they settled, then held until they change, are refreshed or dropped.
lane_e = spawn("transport-belt", 11.5, 2.5, force="player", direction=4)
F.put_on_belt(lane_e, 1, "copper-plate", 0.5, 12)
belt_mod.lane_refresh = 1000
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1})
belt_unit, under_unit, lane_unit = int(belt_e.unit_number), int(under_e.unit_number), int(lane_e.unit_number)
k1, k2, ku1, kl1 = belt_unit * 8 + 1, belt_unit * 8 + 2, under_unit * 8 + 1, lane_unit * 8 + 1
tick(6)
first, _ = lane_update(take())
check(first.get(k1) == [7] and first.get(k2) == [8] and first.get(ku1) == [9],
      f"bl: every lane is sent in full at first, its items grouped by lane (ln: unit number * 8 + line): {first}")
tick(6)
second, _ = lane_update(take())
check(second.get(k1) == [7] and second.get(ku1) == [9], f"bl: read once more unchanged, to see the lanes settled: {second}")
reads1 = F.detailed_reads
tick(6)
msgs = take()
third, dropped = lane_update(msgs)
check(not third and not dropped and F.detailed_reads == reads1 and all(m["l"] == [] for m in of_type(msgs, "bi")),
      f"bl: settled lanes are held: not read in full ({F.detailed_reads - reads1} reads), no items sent: {third}")
line1 = belt_e.get_transport_line(1)
line1.remove_item(lua.table_from({"name": "iron-plate"}))
F.put_on_belt(belt_e, 1, "iron-plate", 0.125, 7)  # the same item, moved on
tick(6)
moved, _ = lane_update(take())
check(set(moved) == {k1} and moved[k1] == [7], f"bl: a lane whose front item moved is sent again, alone: {moved}")
line1.remove_item(lua.table_from({"name": "iron-plate"}))
belt_mod.items_per_message = 1  # several parts: the emptied lane is read after the first is written
tick(12)
emptied_msgs = take()
belt_mod.items_per_message = 300
emptied, _ = last_update(emptied_msgs)
check(emptied.get(k1) == [], f"bl: a lane emptied is sent with no items (ln count 0), whichever part it falls in: {emptied}")
belt_mod.lane_refresh = 2
tick(18)  # the first round may have been read before the change
refreshed, _ = lane_update(take())
check(k2 in refreshed and ku1 in refreshed, f"bl: held lanes are read again every lane_refresh updates: {sorted(refreshed)}")
belt_mod.lane_refresh = 1000
tick(6)
take()
lane_e.destroy()
tick(12)
_, dropped = lane_update(take())
check(kl1 in dropped and k2 not in dropped, f"bl: a gone belt's lanes are dropped (dl): {dropped}")
# A full lane flowing at its belt's speed looks exactly the same whenever its items moved a whole
# number of gaps since the last check (in 2.1.23 full belts were held still on the client): such a
# check reads the lane in full. A yellow belt checked every 8 ticks: 0.25 tiles, one gap.
section_start = int(lua.eval("game.tick"))
belt_mod.lane_jitter = False
interval = g.settings["global"]["f3d-detail-interval"]
old_interval = interval.value
interval.value = 8
flow_e = spawn("transport-belt", 13.5, 2.5, force="player", direction=4)
kf = int(flow_e.unit_number) * 8 + 1
flow_uids = []


def flow_on():
    """The lane's items replaced by the next four at the same places: it moved on one gap."""
    for u in flow_uids:
        F.move_on_belt(flow_e, 1, u, None)
    base = 900 + 4 * len(flow_uids)
    flow_uids[:] = [base + j for j in range(4)]
    for j, u in enumerate(flow_uids):
        F.put_on_belt(flow_e, 1, "iron-plate", 0.25 * j, u)


take()
blind0 = belt_mod.counts.blind
flowing = []
for _ in range(5):
    flow_on()
    tick(8)
    lanes, _ = lane_update(take())
    flowing.append(sorted(lanes.get(kf, [])) == sorted(flow_uids))
check(all(flowing[1:]) and belt_mod.counts.blind > blind0,
      f"bl: a full lane flowing whole gaps between checks is read in full every update, not held: {flowing}, "
      f"{belt_mod.counts.blind - blind0} blind checks")
# And every other round starts a tick early, so the time between two checks of a lane is odd: at
# these belt speeds never a whole number of gaps.
belt_mod.lane_jitter = True
interval.value = old_interval
belt_mod.quiet_ticks = 0  # (a quiet lane would be checked every other update: below)
tick(6)
take()
checked = []
for _ in range(5):
    tick(6)
    take()
    checked.append(int(g.storage.f3d.bl[kf][6]))
gaps = [b - a for a, b in zip(checked, checked[1:])]
check(sorted(set(gaps)) == [5, 7], f"bl: a lane's checks are 5 and 7 ticks apart in turn at a 6-tick interval: {gaps}")
# A quiet lane (unchanged at its last three checks) is checked at most every 12 ticks, so at a
# 6-tick interval every other update; a change shows within those 12 ticks.
belt_mod.quiet_ticks = 12
quiet0 = belt_mod.counts.quiet
checked = []
for _ in range(8):
    tick(6)
    take()
    checked.append(int(g.storage.f3d.bl[kf][6]))
gaps = sorted(set(b - a for a, b in zip(checked, checked[1:]) if b != a))
check(belt_mod.counts.quiet > quiet0 and gaps and min(gaps) >= 11 and max(gaps) <= 13,
      f"bl: a quiet lane is checked every other update (about 12 ticks apart): {gaps}, {belt_mod.counts.quiet - quiet0} skipped")
for u in flow_uids:
    F.move_on_belt(flow_e, 1, u, None)
tick(12)
quiet_ln, _ = lane_update(take())
check(quiet_ln.get(kf) == [], f"bl: a change on a quiet lane is seen within 12 ticks: {quiet_ln.get(kf)}")
flow_e.destroy()
tick(6)
# Stacks (2.1.23: a stack inserter's stack of up to 4 is one entry on the belt, `#line` counting
# entries): bi says each stack's size by unique id (st), and a stack an inserter takes part of is
# read and sent again although nothing on the lane moved (the check counts the lane's items too).
stack_e = spawn("transport-belt", 10.5, 4.5, force="player", direction=4)
F.put_on_belt(stack_e, 1, "iron-plate", 0.5, 31, None, None, 4)
F.put_on_belt(stack_e, 1, "iron-plate", 0.75, 32)
ks1 = int(stack_e.unit_number) * 8 + 1


def stacks(msgs):
    out = {}
    for m in of_type(msgs, "bi"):
        st = m.get("st", [])
        for i in range(0, len(st) - 1, 2):
            out[st[i]] = st[i + 1]
    return out


tick(12)
msgs = take()
first_st, (first_ln, _) = stacks(msgs), last_update(msgs)
check(first_st.get(31) == 4 and 32 not in first_st and first_ln.get(ks1) == [31, 32],
      f"bi st: a stack's size by unique id, a single item not listed: {first_st} {first_ln.get(ks1)}")
tick(12)
take()
tick(6)
held_ln, _ = lane_update(take())
F.set_stack_count(stack_e, 1, 31, 2)
tick(12)
msgs = take()
taken_ln, _ = last_update(msgs)
check(ks1 not in held_ln and taken_ln.get(ks1) == [31, 32] and stacks(msgs).get(31) == 2,
      f"bl: a stack an inserter took part of is sent again with its new size: held {sorted(held_ln)}, then {taken_ln.get(ks1)} {stacks(msgs)}")
stack_e.destroy()
tick(12)
take()
# A line that moved on by whole slots looks the same on every belt (held); when one belt is read
# in full later its items are others, so the belts either side are read in full too, in the same
# update (owner: lines not moving together "over time").
la = spawn("transport-belt", 10.5, 5.5, force="player", direction=4)
lb = spawn("transport-belt", 11.5, 5.5, force="player", direction=4)
F.link_belts(la, lb)
F.put_on_belt(la, 1, "iron-plate", 0.5, 41)
F.put_on_belt(lb, 1, "iron-plate", 0.5, 42)
ka, kb = int(la.unit_number) * 8 + 1, int(lb.unit_number) * 8 + 1
tick(24)
take()
# The shuffle: 41 moves on to lb's place, a new 43 takes la's; then lb's count changes (an item added)
# so lb alone would be read.
F.move_on_belt(lb, 1, 42, None)
F.move_on_belt(la, 1, 41, None)
F.put_on_belt(lb, 1, "iron-plate", 0.5, 41)
F.put_on_belt(la, 1, "iron-plate", 0.5, 43)
tick(12)
take()
F.put_on_belt(lb, 1, "iron-plate", 0.75, 44)
tick(6)
shifted, _ = lane_update(take())
check(shifted.get(kb) == [41, 44] and shifted.get(ka) == [43],
      f"bl: a lane read in full whose items moved on has the lane behind it read in full too: {shifted}")
la.destroy()
lb.destroy()
tick(12)
take()
# Multiplayer: a held lane with quality (or spoiling) items is still read in full for what is sent,
# but whether it is hangs on module-local state (lane_special, the round's payload), which a peer
# that loaded since lacks. So that read leaves storage as the check left it: the record keeps the end
# items of its last counted read, and nothing along its line is queued to be read.
qa = spawn("transport-belt", 10.5, 6.5, force="player", direction=4)
qb = spawn("transport-belt", 11.5, 6.5, force="player", direction=4)
F.link_belts(qa, qb)
F.put_on_belt(qa, 1, "iron-plate", 0.5, 51, None, "rare")
F.put_on_belt(qb, 1, "iron-plate", 0.5, 52)
kqa, kqb = int(qa.unit_number) * 8 + 1, int(qb.unit_number) * 8 + 1
tick(24)
take()
rec_ends = [int(g.storage.f3d.bl[kqa][8]), int(g.storage.f3d.bl[kqa][9])]
# Another item at the same place (the line moved on a whole slot): the check sees nothing.
F.move_on_belt(qa, 1, 51, None)
F.put_on_belt(qa, 1, "iron-plate", 0.5, 53, None, "rare")
tick(12)
special_msgs = take()
special_ln, _ = lane_update(special_msgs)
rec_after = [int(g.storage.f3d.bl[kqa][8]), int(g.storage.f3d.bl[kqa][9])]
bq_uids = [q[0] for m in of_type(special_msgs, "bq") for q in m["l"]]
check(rec_ends == [51, 51] and rec_after == rec_ends and kqb not in special_ln,
      f"bl: a held lane read only for what is sent leaves its record and its line alone: {rec_ends} -> {rec_after}, "
      f"lanes sent {sorted(special_ln)}")
check(set(special_ln.get(kqa) or []) == {53} and 53 in bq_uids,
      f"bl: and its new item is still sent, with its quality: {special_ln.get(kqa)} {bq_uids}")
qa.destroy()
qb.destroy()
tick(12)
take()


section_ticks0 = int(lua.eval("game.tick"))
# Far lane icons aren't read where the moving items reach: chunks wholly inside the square.
send({"t": "bfar", "r": 200, "n": 64, "m": 0})
tick(24)
take()
skipped0 = belt_mod.counts.far_skipped
tick(200)
far_chunks = {(m["cx"], m["cy"]) for m in of_type(take(), "bfar")}
check(belt_mod.counts.far_skipped > skipped0 and (0, 0) not in far_chunks and (-1, 0) not in far_chunks,
      f"bfar: chunks wholly inside the moving items' square (64 tiles) aren't read or sent: {sorted(far_chunks)}")
send({"t": "bfar", "r": 0})
# (The ticks the belt group and straight run checks took once, so the periodic jobs below are
# where they were in their rounds; a hello keeps the client.)
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1})
tick(section_ticks0 + 704 - int(lua.eval("game.tick")))
take()
belt_mod.lane_refresh = 64
F.put_on_belt(belt_e, 1, "iron-plate", 0.25, 7)
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1})
tick(6)
take()

# #2 / B2: belts far away as one icon per lane (bfar), by what each lane carries, when it changes.
# Lane 2 holds one stack of 4 and one of 2 (a stack inserter's): 6 items, 4 icons piled 2 high.
F.put_on_belt(far_e, 2, "iron-plate", 0.5, 12, None, None, 4)
F.put_on_belt(far_e, 2, "iron-plate", 0.25, 13, None, None, 2)
send({"t": "bfar", "r": 200})
tick(3)
far_msgs = of_type(take(), "bfar")
far = {(m["cx"], m["cy"]): m["l"] for m in far_msgs}
far_counts = {(m["cx"], m["cy"]): m.get("c") for m in far_msgs}
far_row = next((far[(1, 0)][i:i + 5] for i in range(0, len(far.get((1, 0), [])), 5) if far[(1, 0)][i:i + 2] == [fixed(40.5), fixed(10.5)]), None)
near_row = next((far[(0, 0)][i:i + 5] for i in range(0, len(far.get((0, 0), [])), 5) if far[(0, 0)][i:i + 2] == [fixed(8.5), fixed(2.5)]), None)
check(far_row == [fixed(40.5), fixed(10.5), 0, iid["iron-plate"], iid["iron-plate"]] and near_row == [fixed(8.5), fixed(2.5), 4, iid["iron-plate"], iid["iron-gear-wheel"]],
      f"bfar: each belt's place, direction and what its two lanes carry: {far}")
near_i = next((i // 5 for i in range(0, len(far.get((0, 0), [])), 5) if far[(0, 0)][i:i + 2] == [fixed(8.5), fixed(2.5)]), None)
check(far_counts.get((1, 0)) == [1, 4] and near_i is not None and far_counts[(0, 0)][near_i * 2:near_i * 2 + 2] == [1, 1],
      f"bfar c: how many items each lane holds (at most 4), so a full belt is drawn full (G17), stacks too: {far_counts}")
far_piles = {(m["cx"], m["cy"]): m.get("h") for m in far_msgs}
check(far_piles.get((1, 0)) == [1, 2] and far_piles.get((0, 0)) is None,
      f"bfar h: how high each lane's icons are piled (6 items on 4 icons: 2), only for chunks with stacks: {far_piles}")
# A round starts at most every FAR_ROUND_TICKS (180): wait past one each time.
tick(200)
check(not of_type(take(), "bfar"), "bfar: a chunk whose lanes didn't change isn't sent again")
F.move_on_belt(far_e, 2, 12, None)
F.move_on_belt(far_e, 2, 13, None)
tick(200)
check([(m["cx"], m["cy"]) for m in of_type(take(), "bfar")] == [(1, 0)], "bfar: a chunk is sent again when what it carries changes")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1})  # keep-alive: the client goes after 600 quiet ticks
# A chunk dropped and subscribed again inside one round is sent again (the client forgot its lanes).
send({"t": "sub", "c": [[0, 0], [9, 9]]})
tick(3)
send({"t": "sub", "c": [[0, 0], [1, 0], [9, 9]]})
tick(200)
check([(m["cx"], m["cy"]) for m in of_type(take(), "bfar")] == [(1, 0)],
      "bfar: a chunk subscribed again gets its lanes again, though they didn't change (G17)")
# A chunk's belts are read over several ticks, a few a tick (one busy chunk read whole took 48 ms).
belt_mod.far_belts_per_tick = 1
send({"t": "sub", "c": [[1, 0], [9, 9]]})
tick(3)
send({"t": "sub", "c": [[0, 0], [1, 0], [9, 9]]})
steps, sent = [], []
for _ in range(400):
    cur = g.storage.f3d.far.cur
    before = (cur.key, cur.i) if cur else None
    tick()
    cur = g.storage.f3d.far.cur
    if before and cur and cur.key == before[0]:
        steps.append(cur.i - before[1])
    sent += of_type(take(), "bfar")
    if sent:
        break
far00 = [m for m in sent if (m["cx"], m["cy"]) == (0, 0)]
check(far00 and len(far00[0]["l"]) == 10 and steps and max(steps) <= 1,
      f"bfar: a chunk is read a slice of belts a tick and sent whole: steps {steps}, {far00[:1]}")
belt_mod.far_belts_per_tick = 100
# Belt-free chunks are cached in far.empty and cleared immediately when a belt is built there.
send({"t": "sub", "c": [[0, 0], [1, 0], [2, 0], [9, 9]]})
tick(200)
take()
far_empty_cached = bool(g.storage.f3d.far.empty["2,0"])
e_far_new = g.game.surfaces[1].create_entity(lua.table(name="transport-belt", position=lua.table(x=70.5, y=4.5), force="player"))
g.package.loaded["scripts.tracker"].added(e_far_new)
far_empty_cleared = g.storage.f3d.far.empty["2,0"] is None
e_far_new.destroy()
check(far_empty_cached and far_empty_cleared,
      f"bfar: belt-free chunk cached empty ({far_empty_cached}) and cleared when a belt is built ({far_empty_cleared})")
send({"t": "bfar", "r": 0})
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1})
tick(3)
send({"t": "sub", "c": [[0, 0], [9, 9]]})
tick(3)
send({"t": "sub", "c": [[0, 0], [1, 0], [9, 9]]})
tick(200)
check(not of_type(take(), "bfar"), "bfar r 0 stops it (a chunk subscribed again isn't sent)")
# Back on the 6-tick phase the belt item checks below were written for (game.tick % 6 == 4 -> 1 after +15).
tick((4 - int(lua.eval("game.tick"))) % 6)
take()
# The client's "Belt items in full" distance (bfar n) replaces the map setting for belt items.
send({"t": "bfar", "r": 0, "n": 4})
tick(6)
check(not any(m["l"] for m in of_type(take(), "bi")), "bfar n 4: no items 8 tiles away are sent")
send({"t": "bfar", "r": 0})
tick(6)
check(any(m["l"] for m in of_type(take(), "bi")), "bfar without n: back to f3d-detail-radius")
# Belt updates (bfar m): the most items and lanes an update reads before it stops at the last whole
# ring, so items move as far out as that allows (n up to MAX_NEAR) and lane icons start there.
send({"t": "bfar", "r": 0, "n": 400, "m": 50})
tick(1)
caps = [g.storage.f3d.bi_cap, g.storage.f3d.near_r]
send({"t": "bfar", "r": 0, "n": 24, "m": 6000})
tick(1)
caps += [g.storage.f3d.bi_cap]
send({"t": "bfar", "r": 0, "n": 24, "m": 0})
tick(1)
caps += [g.storage.f3d.bi_cap]
belt_mod.max_items = 4  # the mod's own cap, which Unlimited must not use
tick(11)  # with the tick above, the checks below keep the tick phase they were written for
unlimited = of_type(take(), "bi")
belt_mod.max_items = 6000
send({"t": "bfar", "r": 0})
tick(1)
check(caps == [200, 400, 6000, -1] and g.storage.f3d.bi_cap is None and unlimited and all(m.get("fr") == 24 for m in unlimited),
      f"bfar m: the client's cap of items and lanes (200 at least), n as asked (up to 640); 0 is Unlimited (every belt within n); without m the mod's own: {caps} {[m.get('fr') for m in unlimited]}")

# Belt items are read over several ticks (a round), a slice of work units a tick, and sent as one
# update stamped with the tick it is sent on: an item read early in the round is carried on to that
# tick at the speed it moved between its reads.


def bi_items(msgs):
    """{k: {unique id: [item id, x, y]}} and {k: [(uid) ...]} from bi parts, plain or delta-coded."""
    by_k, order = {}, {}
    for m in of_type(msgs, "bi"):
        l, prev = m["l"], [0, 0, 0, 0]
        for i in range(0, len(l), 4):
            rec = [p + d for p, d in zip(prev, l[i:i + 4])] if m.get("z") == 1 else l[i:i + 4]
            prev = rec
            by_k.setdefault(m["k"], {})[rec[0]] = rec[1:]
            order.setdefault(m["k"], []).append(rec[0])
    return by_k, order


take()
belt_mod.units_per_tick = 40
row = []
for i in range(12):
    e = spawn("transport-belt", 10.5 + i, 7.5, force="player", direction=4)
    F.put_on_belt(e, 1, "iron-plate", 0.2, 600 + 2 * i)
    F.put_on_belt(e, 2, "copper-plate", 0.6, 601 + 2 * i)
    row.append(e)
mover = row[0]  # ring 10: read in a round's first ticks
pos = 0.99
F.put_on_belt(mover, 2, "iron-gear-wheel", pos, 700)
truth, slices, msgs = {}, [], []
for _ in range(90):
    now = int(lua.eval("game.tick")) + 1
    pos -= 0.01
    F.move_on_belt(mover, 2, 700, pos)
    truth[now] = fixed(10.5 + (0.5 - pos))  # an east belt's line runs from its west edge to position 0 at the east
    before = belt_mod.round()
    start, units = (before.start, before.units) if before else (None, 0)
    F.tick()
    after = belt_mod.round()
    got = take()
    msgs += got
    if after:
        slices.append(after.units - (units if after.start == start else 0))
    elif of_type(got, "bi") and before:
        slices.append(None)  # sent this tick: the round is gone; its last slice was read on this tick
by_k, order = bi_items(msgs)
ks = sorted(by_k)
round_ticks = [n for n in slices if n is not None]
check(len(ks) >= 5 and max(round_ticks) <= 40 + 20 and sum(1 for n in round_ticks if n > 0) >= 2 * len(ks),
      f"bi rounds: each read over several ticks, no tick past its slice (40 units, plus the last belt): {round_ticks[:20]}")
check(all(len(order[k]) == len(set(order[k])) for k in ks) and all(set(by_k[k]) == set(by_k[ks[-1]]) for k in ks[1:]),
      f"each update has every item once: {[len(order[k]) for k in ks]}")
check({m.get("parts") for m in of_type(msgs, "bi")} == {1} and len(of_type(msgs, "bi")) == len(ks),
      "one update a round, sent on one tick")
off = [(k, by_k[k].get(700, [0, None])[1] - truth[k]) for k in ks[2:]]
check(off and all(abs(d) <= 1 for _, d in off),
      f"an item read ticks before the update is where it is on the update's tick (1/256 tiles off): {off}")
raw_off = [(k, by_k[k][700][1] - truth[k]) for k in ks[:1]]
check(raw_off and raw_off[0][1] != 0, f"(the first update, with nothing to go on, has it where it was read: {raw_off})")
gaps = {b - a for a, b in zip(ks, ks[1:])}
ps = {m.get("p") for m in of_type(msgs, "bi")}
check(gaps == ps and len(ps) == 1, f"updates come every p ticks: gaps {gaps}, p {ps}")
# An item missing from a round (it moved on to a belt read earlier, or was taken off) is carried on
# along its way once, so the client doesn't stop it, and then dropped.
last_x = by_k[ks[-1]][700][1]
F.move_on_belt(mover, 2, 700, None)
msgs = []
for _ in range(40):
    tick()
    msgs += take()
by_k, _ = bi_items(msgs)
ks = sorted(by_k)
present = [700 in by_k[k] for k in ks]
carried = [by_k[k][700][1] for k in ks if 700 in by_k[k]]
check(len(ks) >= 3 and present[0] and not any(present[2:]) and carried[-1] > last_x,
      f"an item gone from the belt is carried on for one update, then dropped: {present} {carried} (last {last_x})")
# A big round takes several of the job's ticks (m), and `rate` still stretches them.
belt_mod.units_per_tick = 6
spread = {}
for level in (0, 1):
    send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1})  # keep-alive
    send({"t": "rate", "l": level})
    tick(300)  # past the change (the old ticks a while, m settling)
    take()
    send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1})
    tick(300)
    msgs = take()
    ks = sorted({m["k"] for m in of_type(msgs, "bi")})[2:]
    spread[level] = ({b - a for a, b in zip(ks, ks[1:])}, {m.get("p") for m in of_type(msgs, "bi") if m["k"] in ks[:-1]})
check(spread[0][0] == spread[0][1] and min(spread[0][0]) > 6 and min(spread[0][0]) % 6 == 0
      and spread[1][0] == spread[1][1] and min(spread[1][0]) % 12 == 0 and min(spread[1][0]) >= min(spread[0][0]),
      f"a round that needs more ticks than the job's period takes several periods, rate 1 stretches them: {spread}")
send({"t": "rate", "l": 0})
# Parts are written as items are read; one that reaches into a ring the cap then drops is written
# again: rings 8-11 hold 7 items (each sent once, in parts of 2); ring 12 holds two belts: the first
# makes 9 (written out), the second 11, past the cap.
belt_mod.units_per_tick = 40
belt_mod.items_per_message = 2
belt_mod.max_items = 10
belt_mod.lane_weight = 0  # items alone, as these rings were laid out for
extra = spawn("transport-belt", 12.5, -3.5, force="player", direction=4)
F.put_on_belt(extra, 1, "iron-plate", 0.3, 800)
F.put_on_belt(extra, 2, "iron-plate", 0.3, 801)
row.append(extra)
g.storage.f3d.bi = None
tick(60)
by_k, order = bi_items(take())
ks = sorted(by_k)
want = {7, 8, 9, 600, 601, 602, 603}  # (700 was taken off above)
check(len(ks) > 2 and all(set(by_k[k]) == want and len(order[k]) == 7 for k in ks[1:]),  # the first round had no estimate: cut for time
      f"a round cut by the cap sends the whole rings before it, each item once: {[sorted(by_k[k]) for k in ks][1:3]}")
# A round the cap cut, still reading lanes queued along lines that moved on when its due tick comes:
# it isn't cut again. A second cut dropped what those lanes had just read and, marking the round
# short for time, let go of the edge the cap had held (fr).
g.storage.f3d.bi = None
tick(60)
take()
queued_round, cut_update = None, None
for _ in range(120):
    r = belt_mod.round()
    if r is not None and r.cut is None and queued_round is None:
        queued_round = r.start
        r.force_q = lua.table_from([lua.table_from([row[0], 1]) for _ in range(3000)])
    tick()
    cut_sent = of_type(take(), "bi")
    if queued_round is not None and cut_sent:
        cut_update = cut_sent[0]
        break
b = g.storage.f3d.bi
check(cut_update is not None and cut_update.get("fr") == 12 and b.fr == 12 and b.edge_need is not None and b.edge_need > 0,
      f"a round the cap cut isn't cut short again on its due tick: fr {cut_update and cut_update.get('fr')}, kept {b.fr}, edge_need {b.edge_need}")
belt_mod.lane_weight = 1
belt_mod.items_per_message = 300
belt_mod.max_items = 6000
# The client's Smooth belt items (`bfar` u): a round is read in one tick, so updates come every
# interval again even where the mod's own slices (40 units here) take several ticks.
send({"t": "bfar", "r": 0, "n": 24, "u": 10000000})
g.storage.f3d.bi = None
tick(60)
smooth_ps = {m.get("p") for m in of_type(take(), "bi")}
check(g.storage.f3d.bi_units == 10000000 and smooth_ps == {6}, f"bfar u: smooth belt items send an update every 6 ticks: {smooth_ps}")
work = g.storage.f3d.bi.work
check(belt_mod.read_units() < 10000000 and belt_mod.read_units() >= max(belt_mod.units_per_tick, -(-work // 5)),
      f"and spread each round over the interval's ticks ({belt_mod.read_units()} units a tick for {work}), not one tick")
# A round much bigger than the last (running from an empty stretch into a busy base): its due tick
# reads at most two slices and the update stops at the last whole ring (fr), and the next rounds,
# sized from what it would have needed, catch up (smooth read whatever was left: a 374 ms tick).
take()
# (A round already under way was sized from the last estimate: start the next from none, whatever
# tick this part begins on.)
g.storage.f3d.bi.round = None
g.storage.f3d.bi.work = 0
slice_units = belt_mod.read_units()
upto, due_reads, frs, ws = 0, [], [], []
for _ in range(30):
    tick(1)
    sent_now = of_type(take(), "bi")
    if sent_now:
        b = g.storage.f3d.bi
        cut_short = sent_now[0]["fr"] < 24
        frs.append(sent_now[0]["fr"])
        due_reads.append((b.work // 2 if cut_short else b.work) - upto)
        ws.append((sent_now[0]["w"], b.work))
        upto = 0
    r = belt_mod.round()
    if r is not None and not sent_now:
        upto = r.units
check(frs and frs[0] < 24 and frs[-1] == 24 and due_reads[0] <= 2 * slice_units + 60,
      f"a round much bigger than the last reads at most two slices ({slice_units} units) on its due tick and is cut short, "
      f"then the square grows back: fr {frs}, due-tick units {due_reads}")
check(ws and ws[0][0] >= ws[0][1] > due_reads[0],
      f"and its bi w says what it would have needed, not only what it read (Automatic's guide): (w, work) {ws}")
send({"t": "bfar", "r": 0})
check(g.storage.f3d.bi_units is None, "bfar without u: back to the mod's slices")
belt_mod.units_per_tick = 1500
for e in row:
    e.destroy()
g.storage.f3d.bi = None
tick(6)
take()

# `rate`: a server under load sends its costliest updates less often (rate.lua). Each level doubles
# the interval of the jobs at its tier and above; the character's own `me` never slows down.
rate = g.package.loaded["scripts.rate"]


def spacing(msgs, t):
    ks = sorted({m["k"] for m in of_type(msgs, t)})
    return {b - a for a, b in zip(ks, ks[1:])}, ks


# Uncapped cadence with near_rate off: mv slows 2 -> 4 -> 8 -> 16 across levels 0..3.
g.storage.f3d_perf = lua.table_from({"near_rate": False})
expected = {0: {"bi": 6, "mv": 2, "ih": 6}, 1: {"bi": 12, "mv": 4, "ih": 6},
            2: {"bi": 24, "mv": 8, "ih": 6}, 3: {"bi": 48, "mv": 16, "ih": 12}}
seen_ticks = {}
changes = []  # every bi and mv message across the level changes, in order
for level in range(4):
    send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1})  # keep-alive: 10 s without one drops the client
    send({"t": "rate", "l": level})
    tick(170)  # past the change: belt items and movers keep the old rate 120 ticks while the client eases in
    changes += [m for m in take() if m["t"] in ("bi", "mv")]
    tick(240)
    msgs = take()
    changes += [m for m in msgs if m["t"] in ("bi", "mv")]
    for t, every in expected[level].items():
        gaps, ks = spacing(msgs, t)
        seen_ticks[(level, t)] = set(ks)
        check(gaps == {every}, f"rate {level}: {t} every {every} ticks (got gaps {gaps})")
        ps = {m.get("p") for m in of_type(msgs, t)}
        check(ps == {every}, f"rate {level}: {t} says p = {every}, the ticks until the next (got {ps})")
    me_gaps, _ = spacing(msgs, "me")
    check(me_gaps == {2}, f"rate {level}: the character's me stays every 2 ticks (got {me_gaps})")
check(not (seen_ticks[(3, "bi")] & seen_ticks[(3, "ih")]) and all(k % 48 == 1 for k in seen_ticks[(3, "bi")])
      and all(k % 16 == 1 for k in seen_ticks[(3, "mv")]),
      "rate 3: stretched jobs run on ticks of their own, off the 30th and 60th")
check(all(k % 6 == 1 for k in seen_ticks[(0, "bi")]) and all(k % 2 == 1 for k in seen_ticks[(0, "mv")]),
      "rate 0: jobs keep their phase (off the ticks the once-a-second jobs share)")
# Across the changes (and back down to 0) the client is never kept waiting past what an update said
# (after a slow-down belt items and movers come at the old rate a while, already saying the new one).
send({"t": "rate", "l": 0})
tick(120)
changes += [m for m in take() if m["t"] in ("bi", "mv")]
late = []
for t in ("bi", "mv"):
    firsts = {}
    for m in changes:
        if m["t"] == t and m.get("part", 1) == 1:
            firsts.setdefault(m["k"], m.get("p"))
    ks = sorted(firsts)
    for a, b in zip(ks, ks[1:]):
        if b - a > firsts[a]:
            late.append((t, a, firsts[a], b))
check(not late, f"rate changes: each bi and mv comes no later than the last one said (late: {late[:5]})")
# With near_rate on (default) and <=150 movers, mv caps at period 4 across levels 2 and 3 (off 30th/60th).
g.storage.f3d_perf = None
for level in (2, 3):
    send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1})
    send({"t": "rate", "l": level})
    tick(170)
    take()
    tick(120)
    near_mv_msgs = take()
    mv_gaps, mv_ks = spacing(near_mv_msgs, "mv")
    mv_ps = {m.get("p") for m in of_type(near_mv_msgs, "mv")}
    check(mv_gaps == {4} and mv_ps == {4} and all(k % 4 == 1 for k in mv_ks),
          f"near_rate rate {level}: small mover count (<=150) caps mv period at 4: gaps={mv_gaps}, p={mv_ps}")
send({"t": "rate", "l": 0})
tick(120)
take()
periods = {}
for level in range(4):
    g.storage.f3d.rate = level or None
    periods[level] = {job: rate.period(job, every) for job, every in
                      (("st", 30), ("wires", 30), ("en", 10), ("seg", 2), ("life", 60), ("fp", 60), ("tr", 30), ("ts", 6), ("gi", 30), ("rc", 10))}
check(periods[0] == {"st": 30, "wires": 30, "en": 10, "seg": 2, "life": 60, "fp": 60, "tr": 30, "ts": 6, "gi": 30, "rc": 10}
      and periods[1] == periods[0]
      and periods[2] == dict(periods[0], st=60, wires=60, en=20, seg=4, life=120)
      and periods[3] == {"st": 120, "wires": 120, "en": 40, "seg": 8, "life": 240, "fp": 120, "tr": 60, "ts": 12, "gi": 60, "rc": 20},
      f"rate: tier 2 jobs slow from level 2, tier 3 from level 3, each up to its longest: {periods}")
g.storage.f3d.rate = None
# The belt simulation's own job: its updates are reads of the input spots, so they slow last and little.
bs_periods = []
for level in range(4):
    g.storage.f3d.rate = level or None
    bs_periods.append(rate.period("bs", 6))
g.storage.f3d.rate = None
check(bs_periods == [6, 6, 6, 12], f"rate: the belt simulation's job (bs) keeps 6-tick updates at levels 1-2 and goes to 12 at 3: {bs_periods}")
# Far belt lanes: rounds start less often and read fewer belts a tick, only at level 3 (perf.lua belts_last);
# off, from level 1 as before.
lane_factors, lane_factors_off = [], []
for level in range(4):
    g.storage.f3d.rate = level or None
    lane_factors.append(rate.factor("lanes"))
    g.storage.f3d_perf = lua.table_from({"belts_last": False})
    lane_factors_off.append(rate.factor("lanes"))
    g.storage.f3d_perf = None
g.storage.f3d.rate = None
check(lane_factors == [1, 1, 1, 2] and lane_factors_off == [1, 2, 4, 8],
      f"rate: far lanes slow only at level 3 (belts_last), their rounds 2, 4, 8 times apart at 1-3 off: {lane_factors} {lane_factors_off}")
send({"t": "rate", "l": 9})
tick(1)
check(rate.level() == 3, "rate: levels past 3 are 3")
send({"t": "rate", "l": -1})
tick(1)
check(rate.level() == 0, "rate: a level under 0 is 0")
F.commands["f3d-rate"](lua.table_from({"name": "f3d-rate", "parameter": "2"}))
check(rate.level() == 2, "/f3d-rate 2 sets the level from the console")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1})
tick(1)
check(rate.level() == 2, "rate: the level stays while the same client says hello")
F.commands["f3d-rate"](lua.table_from({"name": "f3d-rate", "parameter": "0"}))
# /f3d-bs: the belt simulation's switches, set at run time and said back.
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "feed_edges off"}))
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "bound 0.3"}))
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "bound lots"}))
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "nonsense on"}))
check(lua.eval("storage.f3d_bs.feed_edges") is False and lua.eval("storage.f3d_bs.bound") == 0.3
      and lua.eval("storage.f3d_bs.nonsense") is None,
      "/f3d-bs sets a switch (on/off, a number for bound) and leaves bad ones alone")
said_bs = lua.eval('package.loaded["scripts.belt_sim"]').option_command("")
check("feed_edges off (set)" in str(said_bs[1]) and "full_area on" in str(said_bs[1]) and "bound 0.3 (set)" in str(said_bs[1]),
      f"/f3d-bs with no arguments says every switch: {said_bs[1]}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "feed_edges default"}))
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "bound default"}))
check(lua.eval("storage.f3d_bs.feed_edges") is None and lua.eval("storage.f3d_bs.bound") is None,
      "/f3d-bs <name> default puts a switch back to its default")
# A word switch: area square|trace.
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "area trace"}))
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "trace_near 32"}))
said_bs = lua.eval('package.loaded["scripts.belt_sim"]').option_command("area nonsense")
check(lua.eval("storage.f3d_bs.area") == "trace" and lua.eval("storage.f3d_bs.trace_near") == 32
      and "square, trace or default" in str(said_bs[1]) and "area trace (set)" in str(said_bs[2]),
      f"/f3d-bs area takes square or trace and says so: {said_bs[1]} / {said_bs[2]}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "area default"}))
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "trace_near default"}))
check(lua.eval("storage.f3d_bs.area") is None, "/f3d-bs area default puts the square back")
take()

# D5: a client that says b gets each tick's messages joined by newlines (a datagram costs the game
# about a millisecond to send, whatever its size).
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "b": 1})
tick(1)
take()
most_batched = 0
tick(6)
msgs = take()
check(most_batched > 1 and of_type(msgs, "me") and of_type(msgs, "bi"), f"b: several messages to a datagram, each one whole: up to {most_batched}")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(1)
take()
most_batched = 0
tick(6)
take()
check(most_batched == 1, "without b, one message a datagram")


def last_frame(msgs, t):
    frames = {}
    for m in of_type(msgs, t):
        frames.setdefault(m["k"], []).append(m)
    return frames[max(frames)] if frames else []


def decode_groups(parts, width=4):
    out = []
    for m in parts:
        prev = [0] * width
        for i in range(0, len(m["l"]), width):
            group = m["l"][i:i + width]
            prev = [p + d for p, d in zip(prev, group)] if m.get("z") else group
            out.append(tuple(prev))
    return sorted(out)


def decode_records(parts):
    out = []
    for m in parts:
        prev = [0, 0, 0, 0]
        for rec in m["l"]:
            if m.get("z"):
                rec = [p + d for p, d in zip(prev, rec[:4])] + rec[4:]
                prev = rec[:4]
            out.append(tuple(rec))
    return sorted(out)


hands_plain, hands_coded = last_frame(plain, "ih"), last_frame(coded_msgs, "ih")
# (--binary: binary ih, wire version 3, is never delta-coded either.)
check(hands_coded and (BINARY or all(m.get("z") == 1 for m in hands_coded)) and decode_groups(hands_coded) == decode_groups(hands_plain),
      f"and the inserter hands: {decode_groups(hands_coded)[:3]} vs {decode_groups(hands_plain)[:3]} ({len(hands_coded)} parts)")
movers_plain, movers_coded = last_frame(plain, "mv"), last_frame(coded_msgs, "mv")
# (--binary: binary mv is never delta-coded.)
check(len(decode_records(movers_plain)) >= 2 and (BINARY or all(m.get("z") == 1 for m in movers_coded))
      and decode_records(movers_coded) == decode_records(movers_plain), f"and the movers: {decode_records(movers_coded)} vs {decode_records(movers_plain)}")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
g.settings["global"]["f3d-detail-radius"].value = 0
tick(12)
check(not of_type(take(), "bi"), "radius 0 turns belt items off")
g.settings["global"]["f3d-detail-radius"].value = 24
for e in (belt_e, under_e, far_e):
    e.destroy()

# --- inserter hands, lamps, time of day -----------------------------------------------------------
ins = spawn("inserter", 12.5, 2.5, force="player", direction=4)
# (inserters.lua keeps the square's inserters by chunk, told of builds by the tracker: the fake's
# spawn raises no event, so the build is raised here as a script's would be.)
F["raise"]("script_raised_built", lua.table_from({"entity": ins}))
lamp = spawn("small-lamp", 14.5, 2.5, force="player")
F.set_hand(ins, 12.9, 2.1, "iron-plate")
F.surface.daytime = 0.5
F.surface.darkness = 0.85
tick(60)
msgs = take()
hands = {}
for m in of_type(msgs, "ih"):
    l = m["l"]
    for i in range(0, len(l), 4):
        hands[l[i]] = l[i + 1:i + 4]
unit = ins.unit_number
check(hands.get(unit) == [int(12.9 * 256 + 0.5), int(2.1 * 256 + 0.5), iid["iron-plate"]],
      f"inserter hand position and held item are sent: {hands.get(unit)}")
F.set_hand(ins, 12.0, 2.5, None)
tick(6)
l = [m["l"] for m in of_type(take(), "ih")][-1:]
check(l and l[0][l[0].index(unit) + 3] == 0, "an empty hand is sent with item 0")
# /f3d-ih trace: the hands' debug trace (tools/inserter_check.py): off by default, then each tick's hands
# (position, count, item, status) to script-output, an inserter's description the first time it is seen,
# and a last line with what `ih` sent meanwhile; it stops itself.
said_ih = lua.eval('package.loaded["scripts.inserters"]').command("")
check("trace off" in str(said_ih[1]) and lua.eval("storage.f3d.ih_trace") is None, f"/f3d-ih says the trace is off by default: {said_ih[1]}")
F.set_hand(ins, 12.9, 2.1, "iron-plate")
F.commands["f3d-ih"](lua.table_from({"name": "f3d-ih", "parameter": "trace 7 24"}))
tick(7)
trace_lines = [json.loads(l) for l in str(F.written["f3d-ih-trace.jsonl"] or "").splitlines() if l.strip()]
heads = [l for l in trace_lines if isinstance(l, dict) and "u" in l]
rows = [l for l in trace_lines if isinstance(l, list)]
ends = [l for l in trace_lines if isinstance(l, dict) and "end" in l]
check(len(heads) == 1 and heads[0]["u"] == unit and heads[0]["n"] == "inserter" and heads[0]["x"] == 12.5,
      f"/f3d-ih trace describes an inserter the first tick it is seen: {heads[:1]}")
check(len(rows) == 7 and all(r[1:6] == [unit, int(12.9 * 256 + 0.5), int(2.1 * 256 + 0.5), 1, iid["iron-plate"]] for r in rows)
      and [r[0] for r in rows] == list(range(rows[0][0], rows[0][0] + 7)),
      f"/f3d-ih trace writes every tick's hands (position, count, item, status): {rows[:2]}")
check(len(ends) == 1 and ends[0]["ticks"] == 7 and ends[0]["ih_sends"] >= 1 and ends[0]["ih_bytes"] > 0
      and lua.eval("storage.f3d.ih_trace") is None,
      f"/f3d-ih trace ends itself with what `ih` sent meanwhile: {ends}")
F.set_hand(ins, 12.0, 2.5, None)
take()
# `ie`: the hands as events (inserters.lua), for a client whose hello says `ie` (or /f3d-ih events on):
# a sync (kind 4: count, item, status code, position) when a hand is first seen, a dropped (2:
# remaining, item, how many ticks before it may have happened, position) when its count fell, a
# picked (1) when it rose, each record in the messages of the next 6 ticks (3 of them), and no `ih`.
ins_mod = lua.eval('package.loaded["scripts.inserters"]')
F.set_hand(ins, 12.9, 2.1, "iron-plate")
F.commands["f3d-ih"](lua.table_from({"name": "f3d-ih", "parameter": "events on"}))
tick(4)
ie = of_type(take(), "ie")


def ie_records(msgs, kind=None):
    out = []
    for m in msgs:
        l = m["l"]
        for i in range(0, len(l), 9):
            if l[i + 1] == unit and (kind is None or l[i] == kind):
                out.append((m["k"], l[i:i + 9]))
    return out


syncs = ie_records(ie, 4)
check(ie and all("n" in m and m["n"] == 6 and m["p"] == 2 for m in ie)
      and syncs and syncs[0][1][3:5] == [1, iid["iron-plate"]] and syncs[0][1][6:8] == [int(12.9 * 256 + 0.5), int(2.1 * 256 + 0.5)],
      f"ie: a hand first seen gets a sync with its count, item and position: {syncs[:1]} of {len(ie)} messages")
check(all(m["k"] % 2 == 1 for m in ie) and len({k for k, _ in syncs}) >= 2,
      f"ie: messages every 2 ticks, each event in more than one of them: {[k for k, _ in syncs]}")
F.set_hand(ins, 12.0, 2.5, None)
tick(44)
ie_msgs = take()
drops = ie_records(of_type(ie_msgs, "ie"), 2)
check(drops and drops[0][1][3] == 0 and drops[0][1][4] == iid["iron-plate"] and drops[0][1][5] >= 0
      and drops[0][1][6:8] == [12 * 256, int(2.5 * 256)] and drops[0][1][2] <= drops[0][0],
      f"ie: the hand emptied: a dropped record (remaining 0, the item, the uncertainty, where): {drops[:1]}")
check(not of_type(ie_msgs, "ih"), "ie: no `ih` samples while events are sent (samples auto)")
F.set_hand(ins, 12.9, 2.1, "iron-plate")
tick(44)
picks = ie_records(of_type(take(), "ie"), 1)
check(picks and picks[0][1][3:5] == [1, iid["iron-plate"]] and picks[0][1][6:8] == [int(12.9 * 256 + 0.5), int(2.1 * 256 + 0.5)],
      f"ie: the hand filled: a picked record (count 1, the item, where): {picks[:1]}")
said = ins_mod.command("")
check(any("sending events" in str(said[i]) for i in (1, 2)), f"/f3d-ih says what is sent and the hands' states: {said[2] if len(said) > 2 else said}")
# The hello's `ie` chooses, with events and samples on auto; `/f3d-ih samples on` sends both.
F.commands["f3d-ih"](lua.table_from({"name": "f3d-ih", "parameter": "events default"}))
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "ie": 1})
tick(12)
ie_msgs = take()
check(of_type(ie_msgs, "ie") and not of_type(ie_msgs, "ih"), "ie: a hello saying `ie` gets events, no samples")
F.commands["f3d-ih"](lua.table_from({"name": "f3d-ih", "parameter": "samples on"}))
tick(12)
ie_msgs = take()
check(of_type(ie_msgs, "ih") and ie_records(of_type(ie_msgs, "ie"), 4), "ie: /f3d-ih samples on sends both (the hands synced again after the switch)")
F.commands["f3d-ih"](lua.table_from({"name": "f3d-ih", "parameter": "samples default"}))
# The trace with events: each event as a line, and the end line counts them.
F.commands["f3d-ih"](lua.table_from({"name": "f3d-ih", "parameter": "trace 9 24"}))
tick(2)
F.set_hand(ins, 12.0, 2.5, None)
tick(7)
trace_lines = [json.loads(l) for l in str(F.written["f3d-ih-trace.jsonl"] or "").splitlines() if l.strip()]
evl = [l["ev"] for l in trace_lines if isinstance(l, dict) and "ev" in l]
ends = [l for l in trace_lines if isinstance(l, dict) and "end" in l]
check(evl and all(len(e) == 9 for e in evl) and ends and ends[0].get("ie_events", 0) >= 1 and ends[0].get("checks", 0) >= 1,
      f"/f3d-ih trace writes the events it made and counts them at the end: {evl[:2]} {ends[:1]}")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1})
hello_tick = lua.eval("game.tick")
tick(12)
ie_msgs = take()
# (Datagrams from before the hello can still be on their way out: only what was made after it counts.)
check(of_type(ie_msgs, "ih") and not [m for m in of_type(ie_msgs, "ie") if m["k"] > hello_tick],
      f"ie: a hello without `ie` is back to samples: {[m['k'] for m in of_type(ie_msgs, 'ie')]} after tick {hello_tick}")
F.set_hand(ins, 12.0, 2.5, None)
take()
sky = of_type(msgs, "sky")
check(sky and sky[-1]["d"] == 500 and sky[-1]["n"] == 850, f"time of day is sent once a second: {sky[-1:]}")
lamp_states = [m["l"] for m in of_type(msgs, "st")]
check(any(lamp.unit_number in l[::2] for l in lamp_states), "a powered lamp is reported as working")


# K10: a lit lamp's colour (`st` `lc`): the colour set in its window (LuaEntity.color), or with "Use colors"
# its circuit network's (LuaLampControlBehavior.color); white is -1, Factorio's plain light. Only changes go,
# and the colour again with each state sent for it (the client forgets a lamp's colour with its state).
def lamp_colors(n):
    cols, with_state = [], []
    for i in range(n):
        if i % 100 == 0:
            send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
        tick(1)
        for m in of_type(take(), "st"):
            lc = m.get("lc") or []
            mine = [(lc[j], lc[j + 1]) for j in range(0, len(lc), 2) if lc[j] == lamp.unit_number]
            cols += mine
            with_state += [lamp.unit_number in m["l"][::2] for _ in mine]
    return cols, with_state


u = lamp.unit_number
cols, _ = lamp_colors(40)
check(cols == [], f"K10: a white lamp sends no colour: {cols}")
lamp.color = lua.table_from({"r": 1, "g": 0, "b": 0, "a": 1})
cols, _ = lamp_colors(40)
check(cols and set(cols) == {(u, 0xFF0000)}, f"K10: its window's colour is sent once it changes: {cols}")
cb = lamp.get_or_create_control_behavior()
F.lamp_signal_colors[lamp] = lua.table_from({"r": 0, "g": 0.5, "b": 1, "a": 1})
cols, _ = lamp_colors(40)
check(cols == [], f"K10: the circuit's colour counts only with Use colors on: {cols}")
cb.use_colors = True
cols, _ = lamp_colors(40)
check(cols and set(cols) == {(u, 0x0080FF)}, f"K10: with Use colors, the colour its signals make: {cols}")
cb.use_colors = False
cols, _ = lamp_colors(40)
check(cols and set(cols) == {(u, 0xFF0000)}, f"K10: Use colors off: back to its window's colour: {cols}")
lamp.color = lua.table_from({"r": 1, "g": 1, "b": 1, "a": 1})
cols, _ = lamp_colors(40)
check(cols and set(cols) == {(u, -1)}, f"K10: white again: -1, the plain light: {cols}")
lamp.color = lua.table_from({"r": 255, "g": 128, "b": 0, "a": 255})
lamp.status = g.defines.entity_status.no_power
cols, _ = lamp_colors(40)
check(cols == [] and g.storage.f3d.lamp_col[u] is None, f"K10: an unlit lamp's colour isn't read: {cols}")
lamp.status = g.defines.entity_status.working
cols, with_state = lamp_colors(40)
check(cols and set(cols) == {(u, 0xFF8000)} and all(with_state),
      f"K10: lit again, its colour (0-255 read as such) comes with its state: {cols} {with_state}")
cols, with_state = lamp_colors(80)
check(all(with_state), f"K10: an unchanged colour goes again only with its state (the round that reports everything): {cols}")
lamp.color = lua.table_from({"r": 1, "g": 1, "b": 1, "a": 1})
lamp_colors(40)


# K20: a lamp set to Always on (LuaEntity.always_on) shines by day as well. The client lights the others
# only when it is dark, so `st` `ao` says which lit lamps are always on: [unit, 1] with each state sent for
# one, [unit, 0 or 1] when that changes, nothing for a plain one. By day a plain lamp's status is
# turned_off_during_daytime (0); should 2.1 report an always-on one so too, its setting makes it lit.
def lamp_always(n):
    ao, states, with_state = [], [], []
    for i in range(n):
        if i % 100 == 0:
            send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
        tick(1)
        for m in of_type(take(), "st"):
            a = m.get("ao") or []
            mine = [(a[j], a[j + 1]) for j in range(0, len(a), 2) if a[j] == u]
            ao += mine
            with_state += [u in m["l"][::2] for _ in mine]
            states += [m["l"][j + 1] for j in range(0, len(m["l"]), 2) if m["l"][j] == u]
    return ao, states, with_state


ao, _, _ = lamp_always(40)
check(ao == [] and g.storage.f3d.lamp_ao[u] is None, f"K20: a plain lit lamp sends no ao: {ao}")
lamp.always_on = True
ao, states, _ = lamp_always(40)
check(ao and set(ao) == {(u, 1)} and not states, f"K20: Always on turned on at night: ao 1, its state unchanged: {ao} {states}")
day = g.defines.entity_status.turned_off_during_daytime
lamp.status = day
ao, states, _ = lamp_always(40)
check(not ao and 0 not in states, f"K20: by day, an always-on lamp read as turned_off_during_daytime stays lit: {ao} {states}")
lamp.always_on = False
ao, states, _ = lamp_always(40)
check(states == [0] and not ao and g.storage.f3d.lamp_ao[u] is None,
      f"K20: a plain lamp by day is 0 (turned_off_during_daytime), Always on forgotten: {ao} {states}")
lamp.always_on = True
ao, states, with_state = lamp_always(40)
check(states == [1] and set(ao) == {(u, 1)} and all(with_state),
      f"K20: Always on turned on by day: lit (1) and ao 1 with the state: {ao} {states} {with_state}")
lamp.status = g.defines.entity_status.working
ao, states, with_state = lamp_always(80)
check(set(ao) <= {(u, 1)} and all(with_state) and not [v for v in states if v != 1],
      f"K20: read as working by day (2.1's likely reading) it stays lit; ao again only with its state: {ao} {states}")
lamp.always_on = False
ao, states, _ = lamp_always(40)
check(set(ao) == {(u, 0)} and not states, f"K20: Always on turned off while it is lit (night): ao 0: {ao} {states}")
lamp.status = g.defines.entity_status.no_power
lamp.always_on = True
ao, states, _ = lamp_always(40)
check(states == [0] and not ao, f"K20: an always-on lamp without power is 0, no ao: {ao} {states}")
lamp.status = g.defines.entity_status.working
lamp.always_on = False
lamp_always(40)

# Distant lamp chunk-snapshot hints (`extra.lp`, `extra.lc`): powered white = lp 1, always-on = lp 3,
# non-white colour = lc; unpowered or unplugged lamps omit lp.
w_mod = g.package.loaded["scripts.world"]
snap_plain = to_py(w_mod.record(lamp))
check(len(snap_plain) == 6 and snap_plain[5].get("lp") == 1 and "lc" not in snap_plain[5],
      f"lamp snapshot hint: powered white lamp gets lp 1 without lc: {snap_plain}")
lamp.always_on = True
lamp.color = lua.table_from({"r": 0.25, "g": 0.5, "b": 1.0, "a": 1})
snap_colored = to_py(w_mod.record(lamp))
check(len(snap_colored) == 6 and snap_colored[5].get("lp") == 3 and isinstance(snap_colored[5].get("lc"), int) and snap_colored[5]["lc"] > 0,
      f"lamp snapshot hint: always-on coloured lamp gets lp 3 and lc: {snap_colored}")
cb.use_colors = True
snap_circuit = to_py(w_mod.record(lamp))
check(len(snap_circuit) == 6 and snap_circuit[5].get("lc") == 0x0080FF,
      f"lamp snapshot hint: circuit color overrides window color when Use colors is on: {snap_circuit}")
cb.use_colors = False
lamp.status = g.defines.entity_status.no_power
snap_nopower = to_py(w_mod.record(lamp))
check(len(snap_nopower) == 5 or "lp" not in snap_nopower[5], f"lamp snapshot hint: no_power omits lp: {snap_nopower}")
lamp.status = g.defines.entity_status.working
lamp.electric_network_id = None
snap_unplugged = to_py(w_mod.record(lamp))
check(len(snap_unplugged) == 5 or "lp" not in snap_unplugged[5], f"lamp snapshot hint: unplugged omits lp: {snap_unplugged}")
lamp.electric_network_id = 1
lamp.always_on = False
lamp.color = lua.table_from({"r": 1, "g": 1, "b": 1, "a": 1})

for e in (ins, lamp):
    e.destroy()

# Signals, accumulators and power switches report a state, not just working or not (`st`),
# and rail/chain signal snapshots carry `extra.sg` (1 green, 2 yellow, 3 red, 4 blue) past `focus.r`.
sig = spawn("rail-signal", 12.5, 4.5, force="player")
chain = spawn("rail-chain-signal", 13.5, 4.5, force="player")
sig_snap_red = to_py(w_mod.record(sig))
chain_snap_red = to_py(w_mod.record(chain))
check(len(sig_snap_red) == 6 and sig_snap_red[5].get("sg") == 3
      and len(chain_snap_red) == 6 and chain_snap_red[5].get("sg") == 3,
      f"signal snapshot hint: closed/none_open get sg=3: {sig_snap_red} {chain_snap_red}")
check("el" not in sig_snap_red[5], f"a signal on ground rails has no extra.el: {sig_snap_red}")
sig.rail_layer = g.defines.rail_layer.elevated
sig_snap_el = to_py(w_mod.record(sig))
check(len(sig_snap_el) == 6 and sig_snap_el[5].get("el") == 1 and sig_snap_el[5].get("sg") == 3,
      f"a signal on elevated rails (rail_layer) sends extra.el = 1: {sig_snap_el}")
sig.rail_layer = g.defines.rail_layer.ground
acc = spawn("accumulator", 16, 4, force="player")
switch = spawn("power-switch", 19, 4, force="player")
acc.status = g.defines.entity_status.discharging
switch.power_switch_state = True
take()
tick(30 * 10)
states = {}
for m in of_type(take(), "st"):
    for i in range(0, len(m["l"]), 2):
        states[m["l"][i]] = m["l"][i + 1]
check(states.get(sig.unit_number) == 3 and states.get(chain.unit_number) == 3 and states.get(acc.unit_number) == 2
      and states.get(switch.unit_number) == 1, f"signals send red (3), an accumulator discharging (2), a switch on (1): {states}")
sig.signal_state = g.defines.signal_state.open
chain.signal_state = g.defines.signal_state.open
chain.chain_signal_state = g.defines.chain_signal_state.partially_open
sig_snap_green = to_py(w_mod.record(sig))
chain_snap_blue = to_py(w_mod.record(chain))
check(len(sig_snap_green) == 6 and sig_snap_green[5].get("sg") == 1
      and len(chain_snap_blue) == 6 and chain_snap_blue[5].get("sg") == 4,
      f"signal snapshot hint: open gets sg=1 and partially_open chain gets sg=4: {sig_snap_green} {chain_snap_blue}")
acc.status = g.defines.entity_status.charging
switch.power_switch_state = False
tick(31)
states = {}
for m in of_type(take(), "st"):
    for i in range(0, len(m["l"]), 2):
        states[m["l"][i]] = m["l"][i + 1]
mine = {u: v for u, v in states.items() if u in (sig.unit_number, chain.unit_number, acc.unit_number, switch.unit_number)}
check(mine == {sig.unit_number: 1, chain.unit_number: 4, acc.unit_number: 1, switch.unit_number: 0},
      f"and their changes after: green (1), blue (4), charging (1), off (0): {mine}")
sig.signal_state = g.defines.signal_state.reserved
sig_snap_yellow = to_py(w_mod.record(sig))
check(len(sig_snap_yellow) == 6 and sig_snap_yellow[5].get("sg") == 2,
      f"signal snapshot hint: reserved gets sg=2: {sig_snap_yellow}")
tick(31)
check(any(l[l.index(sig.unit_number) + 1] == 2 for l in (m["l"] for m in of_type(take(), "st")) if sig.unit_number in l[::2]),
      "a reserved signal is yellow (2)")
for e in (sig, chain, acc, switch):
    e.destroy()

# Gates send their real state (perf gate_state): 0 closed, 1 opening, 2 opened, 3 closing, changes only, within
# GATE_TICKS (3) of the change; off: nothing.
def gate_states(unit):
    out = []
    for m in of_type(take(), "st"):
        for i in range(0, len(m["l"]), 2):
            if m["l"][i] == unit:
                out.append(m["l"][i + 1])
    return out
gate = spawn("gate", 10.5, 6.5, force="player")
take()
tick(31)
check(gate_states(gate.unit_number) == [0], "a gate near the focus is sent closed (0) once")
tick(31)
check(gate_states(gate.unit_number) == [], "an unchanged gate is not sent again")
gate.gate_phase = "opening"
tick(3)
got = gate_states(gate.unit_number)
check(got == [1], f"a gate starting to open is sent (1) within 3 ticks: {got}")
gate.gate_phase = "opened"
tick(3)
gate.gate_phase = "closing"
tick(3)
gate.gate_phase = "closed"
tick(3)
got = gate_states(gate.unit_number)
check(got == [2, 3, 0], f"then opened (2), closing (3), closed (0): {got}")
F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "gate_state off"}))
gate.gate_phase = "opening"
tick(31)
got = gate_states(gate.unit_number)
check(got == [] and lua.eval('storage.f3d.gates') is None, f"gate_state off: nothing sent: {got}")
F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "gate_state default"}))
tick(31)
got = gate_states(gate.unit_number)
check(got == [1], f"gate_state on again: the gate's state sent at once: {got}")
gate.destroy()
tick(11)  # (the checks after count on the 30-tick rounds' phase: 139 + 11 ticks here)
take()

# A splitter is working (its rollers turn) while items pass through it: off while empty or backed
# up, on while what its lanes hold changes between checks, and a full lane that moved on by whole
# gaps counts too (its front item's id changed, though the places read the same).
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})  # keep-alive: the client times out after 600 ticks
tick(1)
spl = spawn("splitter", 12.0, 4.5, force="player")
spl_state = [None]
def splitter_after(n=31):
    tick(n)
    for m in of_type(take(), "st"):
        l = m["l"]
        if spl.unit_number in l[::2]:
            spl_state[0] = l[l.index(spl.unit_number) + 1]
    return spl_state[0]
take()
empty = splitter_after(30 * 10)
F.put_on_belt(spl, 2, "iron-plate", 0.5, 7001)
first = splitter_after()
backed = splitter_after()
F.move_on_belt(spl, 2, 7001, 0.8)
moving = splitter_after()
stopped = splitter_after()
F.move_on_belt(spl, 2, 7001, None)
F.put_on_belt(spl, 2, "iron-plate", 0.8, 7002)
next_item = splitter_after()
F.move_on_belt(spl, 2, 7002, None)
splitter_after()
gone = splitter_after()
check((empty, first, backed, moving, stopped, next_item, gone) == (0, 0, 0, 1, 0, 1, 0),
      "a splitter works while items pass: empty 0, first seen 0, backed up 0, moving 1, stopped 0, "
      f"a new front item in the same place 1, emptied 0: {(empty, first, backed, moving, stopped, next_item, gone)}")
spl.destroy()
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})  # keep-alive: the client times out after 600 ticks
tick(1)
take()

