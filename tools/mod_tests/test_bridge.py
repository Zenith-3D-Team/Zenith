"""Runs the bridge mod's control.lua against fake_factorio.lua and checks what it sends.

    pip install lupa
    python3 tools/mod_tests/test_bridge.py

Lupa embeds Lua 5.2, the version Factorio uses. The fake API raises on unknown keys like the
real one, so wrong property reads show up here instead of as an in-game crash.
"""

import json
import math
import pathlib
import re
import struct
import sys

from lupa import lua52

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import protocol  # noqa: E402

# A FAIL line can hold any character: on Windows, output to a file or pipe is in the system's code page,
# and one character it lacks stopped the run with UnicodeEncodeError.
sys.stdout.reconfigure(errors="backslashreplace")
MOD = ROOT / "mod" / "factorio-3d-bridge"
FAKE = pathlib.Path(__file__).with_name("fake_factorio.lua")
CLIENT_PORT = 34201
# A batched datagram fills up to transport.lua's BATCH_BYTES, and the modules split their own
# messages to stay under it (mgui at 48,000); Factorio drops anything over 65,507 silently.
MAX_DATAGRAM = 60000

lua = lua52.LuaRuntime(unpack_returned_tuples=True)


def to_py(value):
    if lua52.lua_type(value) == "table":
        items = list(value.items())
        if not items:
            return []
        keys = [k for k, _ in items]
        if all(isinstance(k, (int, float)) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
            return [to_py(value[i]) for i in range(1, len(keys) + 1)]
        return {str(k): to_py(v) for k, v in items}
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return value


def to_json(table):
    return json.dumps(to_py(table), separators=(",", ":"))


def from_json(text):
    try:
        data = json.loads(text)
    except ValueError:
        return None
    return lua.table_from(data, recursive=True)


g = lua.globals()
g.F_to_json = to_json
g.F_from_json = from_json
lua.execute(FAKE.read_text())
g.package.path = str(MOD / "?.lua") + ";" + g.package.path
lua.execute((MOD / "control.lua").read_text())
# As in Factorio, `require` works only while control.lua is being loaded (a module requiring another
# from inside a function stops the game).
# The barrier round each step (barrier.lua) would swallow what these tests are here to catch.
lua.execute('package.loaded["scripts.barrier"].rethrow = true')
lua.execute('require = function(name) error("Require can not be used outside of control.lua parsing: " .. tostring(name)) end')
F = g.F

failures = []


def check(cond, what):
    if not cond:
        failures.append(what)
        print("FAIL:", what)


def tick(n=1):
    for _ in range(n):
        F.tick()


# --binary: every hello asks for binary frames (`bin`, docs/PROTOCOL.md "Binary frames"), so every check
# below reads the bridge's binary messages (mv, bs, bfar) through protocol.py's decoder instead of JSON.
BINARY = "--binary" in sys.argv
binary_kinds = set()


def send(msg, port=CLIENT_PORT):
    if BINARY and msg.get("t") == "hello" and "bin" not in msg:
        msg = {**msg, "bin": protocol.WIRE_VERSION}
    F.packet(json.dumps(msg), port)


expected_r = 1
most_batched = 0  # the most messages seen in one datagram (a client whose hello says b)


def sent_data(item):
    """A sent datagram's bytes or text: fake_factorio hands a binary one (transport.lua's frames) over as hex."""
    return bytes.fromhex(item[2]) if item[3] else item[2]


def take():
    """Everything sent since the last call. Checks ports, sizes and that reliable messages are
    numbered without gaps (a welcome restarts the numbering at 1)."""
    global expected_r
    out = []
    for item in F.take_sent().values():
        port, data = item[1], sent_data(item)
        check(port == CLIENT_PORT, f"sent to wrong port {port}")
        check(len(data) <= MAX_DATAGRAM, f"datagram too large: {len(data)} bytes")
        global most_batched
        lines = protocol.split_datagram(data)
        if isinstance(data, bytes):
            at = 2
            while at + 6 <= len(data):
                kind, _, length = struct.unpack_from("<BBI", data, at)
                binary_kinds.add(kind)
                at += 6 + length
        most_batched = max(most_batched, len(lines))
        for msg in lines:
            for problem in protocol.problems(msg):
                check(False, f"protocol: {problem}")
            if "r" in msg:
                if msg["t"] == "welcome":
                    expected_r = msg["r"]
                check(msg["r"] == expected_r, f"reliable sequence gap: got {msg['r']}, expected {expected_r} ({msg['t']})")
                expected_r = msg["r"] + 1
            out.append(msg)
    return out


def of_type(msgs, t):
    return [m for m in msgs if m.get("t") == t]


def spawn(name, x, y, **extra):
    return F.spawn(name, x, y, lua.table_from(extra, recursive=True))


def fixed(v):
    return int(math.floor(v * 256 + 0.5))


# Multiplayer: a peer that loaded the save since has none of a module's module-local state (caches,
# lists kept between ticks). forget(fn, name) empties the upvalue `name` that `fn` reaches (through
# the functions it calls, a few deep), as such a peer would have it, so a check can show that what
# goes in storage doesn't depend on it.
lua.execute("""
function F_forget(fn, name, depth)
  depth = depth or 4
  for i = 1, 255 do
    local n, v = debug.getupvalue(fn, i)
    if not n then
      return false
    end
    if n == name then
      debug.setupvalue(fn, i, type(v) == "table" and {} or nil)
      return true
    end
    if type(v) == "function" and depth > 0 and F_forget(v, name, depth - 1) then
      return true
    end
  end
  return false
end
""")


def forget(fn, name):
    return g.F_forget(fn, name)


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
# Back on the 6-tick phase the belt item checks below were written for (one tick past section_start's).
tick((1 - (int(lua.eval("game.tick")) - section_start)) % 6)
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
for e in (ins, lamp):
    e.destroy()

# Signals, accumulators and power switches report a state, not just working or not (`st`).
sig = spawn("rail-signal", 12.5, 4.5, force="player")
chain = spawn("rail-chain-signal", 13.5, 4.5, force="player")
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
tick(31)
check(any(l[l.index(sig.unit_number) + 1] == 2 for l in (m["l"] for m in of_type(take(), "st")) if sig.unit_number in l[::2]),
      "a reserved signal is yellow (2)")
for e in (sig, chain, acc, switch):
    e.destroy()

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
# In a car (puppet.vehicle; a tank or spidertron the same), and on a platform's hub (puppet.hub, stubbed).
es_car = spawn("car", cx, cy, force="player")
es_car.set_driver(es_c)
es_none_given("to a character in a vehicle (car, tank, spidertron)")
es_car.set_driver(None)
es_car.destroy()
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
send({"t": "enter"})
send({"t": "drive", "a": 1, "s": 0})
tick(2)
check(same(loco.get_driver(), puppet) and loco.train.manual_mode is True, "driving a locomotive switches its train to manual mode")
send({"t": "enter"})
tick(2)
loco.destroy()
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
tick(3)
msgs = take()
check(any("laser-turret" in m.get("text", "") for m in of_type(msgs, "msg")), "locked recipe is refused")
check(any(m.get("q") == 2 for m in of_type(msgs, "me")), "crafting queue size is reported")

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
check(set(details) == {"iron-gear-wheel", "transport-belt"}, f"rdet: enabled hand-craftable recipes only: {sorted(details)}")
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
check(sliced[0] == 3 and sliced[1] == (have + 10) // 2,
      f"craftable, spread jobs: a slice a tick, sent when the last is done (the 30th tick plus two): {sliced}")
check(g.storage.f3d.craft_job is None, "craftable, spread jobs: the job is closed once sent")
g.settings["global"]["f3d-spread-jobs"] = lua.table_from({"value": False})
whole = craftable_after(10)
check(whole[0] == 2 and whole[1] == (have + 20) // 2, f"craftable, spread jobs off: all on the 30th tick (out a tick later), as before: {whole}")
g.settings["global"]["f3d-spread-jobs"] = lua.table_from({"value": True})
crafting_mod.craftable_slice = 32
puppet.get_main_inventory().remove(lua.table_from({"name": "iron-plate", "count": 10}))
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

# --- research ---------------------------------------------------------------------------------------
lua.eval("function() storage.f3d.techs_dirty = true end")()
tick(2)
techs = {r[0]: r for m in of_type(take(), "techs") for r in m["l"]}
check(set(techs) == {"automation", "logistics", "steel-processing"}, f"techs: every shown technology: {sorted(techs)}")
check(techs.get("logistics", [0] * 8)[2:8] == [["automation"], [["automation-science-pack", 1]], 10, 10, 0, ""]
      and techs["automation"][6] == 1 and techs["steel-processing"][6] == 2,
      f"techs: prerequisites, cost, time, state (locked/available/researched): {techs.get('logistics')}")
check(len(techs.get("automation", [])) == 15 and techs["automation"][8] == [["unlock-recipe", "iron-gear-wheel", 0]]
      and techs["automation"][9:] == [1, 1, [], 0, "", 1] and techs["logistics"][14] == 0,
      f"techs: effects, level, max level, trigger detail, saved progress, formula, essential: {techs.get('automation')}")
send({"t": "research", "name": "automation"})
send({"t": "research", "name": "logistics"})
send({"t": "research", "name": "secret"})
tick(2)
msgs = take()
rs = of_type(msgs, "rs")
check(rs and rs[-1]["cur"] == "automation" and rs[-1]["q"] == ["automation", "logistics"],
      f"research starts one and queues the next (the queue's first is the current research, as Factorio's): {rs[-1:]}")
check(any(m["text"] == "Can't research secret" for m in of_type(msgs, "msg")), "hidden technologies can't be researched")
g.game.forces.player.research_progress = 0.4
send({"t": "research_cancel", "name": "logistics"})
tick(2)
rs = of_type(take(), "rs")
check(rs and rs[-1]["q"] == ["automation"] and rs[-1]["pr"] == 400, f"research_cancel takes it off the queue: {rs[-1:]}")
send({"t": "research_cancel", "name": "automation"})
tick(4)
msgs = take()
rs = of_type(msgs, "rs")
check(rs and rs[-1]["cur"] == "", "and stops the current research")
saved = {r[0]: r[12] for m in of_type(msgs, "techs") for r in m["l"]}
check(saved.get("automation") == 400, f"a stopped research's saved progress goes to the client (techs again): {saved}")
g.game.forces.player.technologies.automation.researched = True
finished_at = g.game.tick
F["raise"]("on_research_finished", lua.table_from({"research": g.game.forces.player.technologies.automation}))
tick(1)
first = take()
tick(5)
msgs = first + take()
techs = {r[0]: r[6] for m in of_type(msgs, "techs") for r in m["l"]}
check(techs.get("automation") == 2 and techs.get("logistics") == 1, f"finished research resends the tree: {techs}")
# K23: `rdone` names what finished, once (reliable), the research after it right behind (`rs`).
done = of_type(msgs, "rdone")
check(len(done) == 1 and done[0]["l"] == [["automation", 0]] and "n" not in done[0] and done[0]["tick"] == finished_at,
      f"research completed: one rdone naming the technology (level 0: it has one), its tick: {done}")
check(of_type(first, "rdone") and of_type(first, "rs") and first.index(of_type(first, "rs")[0]) > first.index(done[0]),
      f"and the research status after it in the same tick: {[m['t'] for m in first]}")
check(not [m for m in of_type(msgs, "msg") if "automation" in m.get("text", "")], "no msg as well (the client says it)")
g.game.forces.player.technologies.automation.researched = False
# Several in one tick are one message (Factorio's chime plays once for them); an infinite technology
# names the level it finished (its `level` is the next one by then); another force's research isn't
# the character's; past 100, `n` counts the rest.
lua.execute("""
local f = game.forces.player
local proto = setmetatable({ level = 3, max_level = 4294967295, hidden = false }, { __index = function(_, k) error("LuaTechnologyPrototype doesn't contain key " .. tostring(k), 2) end })
local function tech(name, force, level, researched, p)
  return setmetatable({ name = name, force = force, level = level, researched = researched, prototype = p },
    { __index = function(_, k) error("LuaTechnology doesn't contain key " .. tostring(k), 2) end })
end
storage.k23 = {
  tech("mining-productivity-3", f, 8, false, proto),
  tech("logistics", f, 1, true, f.technologies.logistics.prototype),
  tech("automation", game.forces.enemy, 1, true, f.technologies.automation.prototype),
}
""")
take()
for t in lua.eval("storage.k23").values():
    F["raise"]("on_research_finished", lua.table_from({"research": t}))
tick(1)
done = of_type(take(), "rdone")
check(len(done) == 1 and done[0]["l"] == [["mining-productivity-3", 7], ["logistics", 0]],
      f"rdone: one message a tick, an infinite level by the one finished, not another force's: {done}")
for _ in range(105):
    F["raise"]("on_research_finished", lua.table_from({"research": g.storage.k23[2]}))
tick(1)
done = of_type(take(), "rdone")
check(len(done) == 1 and len(done[0]["l"]) == 100 and done[0].get("n") == 5, f"rdone: 100 named, n the rest: {[(len(m['l']), m.get('n')) for m in done]}")
g.storage.k23 = None
tick(4)
take()
# L12: a technology whose prerequisites aren't all researched is queued after the missing ones, in order, as
# Factorio's technology screen does: 2.1.24's add_research alone refuses it, and refuses trigger technologies and an
# eighth in the queue (measured in real headless 2.1.24; the fake does the same). The owner's case: Plastics being
# researched, Advanced circuits queued behind it.
lua.execute("""
local f = game.forces.player
local T = f.technologies
local function proto(trigger)
  return { hidden = false, essential = false, effects = {}, level = 1, max_level = 1, research_trigger = trigger }
end
local function add(name, pres, trigger)
  local p = {}
  for _, n in ipairs(pres) do p[n] = T[n] end
  T[name] = F.make_tech(name, p, { prototype = proto(trigger), force = f })
  prototypes.technology[name] = T[name].prototype
end
f.research_queue = {}
add("l12-plastics", { "logistics" })
add("l12-circuits", { "l12-plastics", "automation" })
add("l12-oil", {}, { type = "mine-entity", entity = "crude-oil" })
add("l12-gas", { "l12-oil" })
add("l12-d1", {}) add("l12-d2", { "l12-d1" }) add("l12-d3", { "l12-d2" }) add("l12-d4", { "l12-d3" })
""")
take()
send({"t": "research", "name": "l12-plastics"})
tick(2)
rs = of_type(take(), "rs")
check(rs and rs[-1]["cur"] == "automation" and rs[-1]["q"] == ["automation", "logistics", "l12-plastics"],
      f"research of a locked technology: its missing prerequisites queued first, in order, then it: {rs[-1:]}")
send({"t": "research", "name": "l12-circuits"})
tick(2)
rs = of_type(take(), "rs")
check(rs and rs[-1]["q"] == ["automation", "logistics", "l12-plastics", "l12-circuits"],
      f"one whose prerequisites are queued goes behind them (Advanced circuits behind Plastics): {rs[-1:]}")
send({"t": "research", "name": "l12-gas"})
tick(2)
msgs = take()
rs = of_type(msgs, "rs")
check(rs and rs[-1]["q"] == ["automation", "logistics", "l12-plastics", "l12-circuits"]
      and any(m["text"] == "Can't research l12-gas yet: l12-oil is unlocked by doing its task" for m in of_type(msgs, "msg")),
      f"a trigger technology on the way: nothing queued, and why: {rs[-1:]}, {[m['text'] for m in of_type(msgs, 'msg')]}")
send({"t": "research", "name": "l12-d4"})
tick(2)
msgs = take()
rs = of_type(msgs, "rs")
check(rs and rs[-1]["q"] == ["automation", "logistics", "l12-plastics", "l12-circuits"]
      and any(m["text"] == "Research queue full: l12-d4 needs 3 more queued first" for m in of_type(msgs, "msg")),
      f"a chain past the queue's 7: what was queued for it comes off again: {rs[-1:]}, {[m['text'] for m in of_type(msgs, 'msg')]}")
g.storage.f3d_perf = lua.table_from({"research_chain": False})
lua.execute("game.forces.player.research_queue = {}")
send({"t": "research", "name": "l12-plastics"})
tick(2)
msgs = take()
rs = of_type(msgs, "rs")
check(rs and rs[-1]["q"] == [] and any(m["text"] == "Can't research l12-plastics yet" for m in of_type(msgs, "msg")),
      f"/f3d-perf research_chain off: add_research alone, refused as before: {rs[-1:]}")
g.storage.f3d_perf = None
lua.execute("""
local f = game.forces.player
f.research_queue = {}
for _, n in ipairs({ "l12-plastics", "l12-circuits", "l12-oil", "l12-gas", "l12-d1", "l12-d2", "l12-d3", "l12-d4" }) do
  f.technologies[n] = nil
  prototypes.technology[n] = nil
end
storage.f3d.techs_dirty = true
""")
tick(4)
take()
# A technology unlocking thousands of recipes (Space Exploration's recycling, 3,253) made one record
# of 187 KB, past a datagram, and its whole message was lost: the record keeps what fits under 30 KB
# and says how many it left out, and every message stays under 40 KB, `parts` growing to count them.
lua.execute("""
local p = game.forces.player.technologies.logistics.prototype
local many = {}
for i = 1, 3500 do many[i] = { type = "unlock-recipe", recipe = "a-rather-long-modded-recycling-recipe-" .. i } end
rawset(p, "effects", many)
""")
g.storage.f3d.techs_dirty = True
tick(4)
msgs = of_type(take(), "techs")
sizes = [len(json.dumps(m)) for m in msgs]
recs = {r[0]: r for m in msgs for r in m["l"]}
big = recs.get("logistics")
check(msgs and max(sizes) < 45000 and all(m["part"] < m["parts"] for m in msgs[:-1]) and msgs[-1]["part"] == msgs[-1]["parts"]
      and [m["part"] for m in msgs] == list(range(1, len(msgs) + 1)),
      f"techs: every message under the limit, parts counted to the last: {[(m['part'], m['parts']) for m in msgs]} {sizes}")
check(big is not None and len(big) == 16 and len(big[8]) + big[15] == 3500 and len(json.dumps(big)) < 31000 and "automation" in recs,
      f"techs: a giant record keeps what fits and says how many effects it left out: {big and (len(big), len(big[8]), big[15:])}")
lua.execute('rawset(game.forces.player.technologies.logistics.prototype, "effects", {})')
g.storage.f3d.techs_dirty = True
tick(4)
take()
# A job saved by an older bridge mid-send (part/parts, no block) is started over, not an error.
lua.execute('storage.f3d.techs_job = { names = { "automation" }, part = 1, parts = 3 }')
tick(4)
msgs = of_type(take(), "techs")
check(msgs and msgs[-1]["part"] == msgs[-1]["parts"] and g.storage.f3d.techs_job is None,
      f"techs: an older bridge's job in a save sends the tree again: {[(m['part'], m['parts']) for m in msgs]}")

# --- fast-replace, rails, rolling stock, quality ----------------------------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
take()
inv = puppet.get_main_inventory()
belts = inv.get_item_count("transport-belt")
spot = {"x": new_belt[2], "y": new_belt[3]}  # the belt built and turned south above
send({"t": "build", "item": "transport-belt", "d": 4, **spot})
tick(2)
msgs = take()
upd = of_type(msgs, "upd")
check(upd and upd[-1]["e"][4] == 4 and not of_type(msgs, "add") and inv.get_item_count("transport-belt") == belts,
      f"building a belt over the same belt turns it, for free: {upd[-1:]}")
send({"t": "build", "item": "transport-belt", "d": 4, **spot})
tick(2)
msgs = take()
check(not (of_type(msgs, "upd") or of_type(msgs, "add") or of_type(msgs, "msg")), "and over itself facing the same way does nothing")
puppet.insert(lua.table_from({"name": "fast-transport-belt", "count": 2}))
send({"t": "build", "item": "fast-transport-belt", "d": 4, **spot})
tick(2)
msgs = take()
dels, adds = of_type(msgs, "del"), of_type(msgs, "add")
check(dels and dels[0]["u"] == new_belt[0] and adds and adds[0]["e"][1] == eid["fast-transport-belt"] and adds[0]["e"][2:5] == [spot["x"], spot["y"], 4],
      f"a faster belt fast-replaces it: del then add: {dels[:1]} {adds[:1]}")
check(inv.get_item_count("fast-transport-belt") == 1 and inv.get_item_count("transport-belt") == belts + 1,
      "the fast belt is used and the old belt comes back")
# J9: a splitter stands on the tile edge between the two belts it covers: it lands where the cursor
# snaps it (the nearest tile corner across, the tile along), replacing both, each sent gone and given back.
j9_belts = [spawn("transport-belt", 1.5, 7.5, force="player"), spawn("transport-belt", 2.5, 7.5, force="player")]
j9_units = sorted(b.unit_number for b in j9_belts)
belts = inv.get_item_count("transport-belt")
puppet.insert(lua.table_from({"name": "splitter", "count": 1}))
send({"t": "build", "item": "splitter", "x": fixed(1.9), "y": fixed(7.7), "d": 0})
tick(2)
msgs = take()
adds = [a["e"] for a in of_type(msgs, "add") if a["e"][1] == eid["splitter"]]
check(sorted(d["u"] for d in of_type(msgs, "del")) == j9_units and adds and adds[0][2:5] == [fixed(2), fixed(7.5), 0]
      and inv.get_item_count("transport-belt") == belts + 2,
      f"J9: a splitter over two belts replaces both where it was aimed: {adds[:1]}, dels {[d['u'] for d in of_type(msgs, 'del')]}")
# J9: at negative coordinates the same rule (floor): a point a hair left of the tile middle at -3.5 (the client
# sends it rounded down, -897) is the tile edge at -4; the middle itself (-896, what a client cutting towards zero
# sent for that point) is the edge at -3, one tile over.
puppet.insert(lua.table_from({"name": "splitter", "count": 2}))
j9_home = {"x": puppet.position.x, "y": puppet.position.y}
puppet.teleport(lua.table_from({"x": -3.5, "y": -20.5}))
for j9_x, j9_y in ((-897, fixed(-22.3)), (-896, fixed(-24.3))):
    send({"t": "build", "item": "splitter", "x": j9_x, "y": j9_y, "d": 0})
    tick(2)
take()
puppet.teleport(lua.table_from(j9_home))
# (Read from the game: the client doesn't watch that chunk, so no `add` comes.)
j9_at = sorted(([e.position.x, e.position.y] for e in F.surface.entities.values() if e.name == "splitter" and e.position.y < -20),
               key=lambda p: -p[1])
check(j9_at == [[-4, -22.5], [-3, -24.5]],
      f"J9: left of zero a splitter sent a hair under a tile's middle stands on the edge below it, the middle itself on the edge above: {j9_at}")
for e in list(F.surface.entities.values()):
    if e.name == "splitter":
        e.destroy()
take()

# M2: an underground pair the character builds over a run of belts mines the belts between (and their items)
# into the character, as Factorio's player build does ("Any belts in between the entrance and exit of the
# underground belt will be mined automatically"); pipes-to-ground over pipes the same. Only a plain run: every
# tile between a belt the pair's way, straight, fed by nothing from the side (a pipe with no connection off the
# line); anything else and none go. The ends' own belts and their items come back too.
m2_x0 = math.floor(puppet.position.x)
m2_y0 = math.floor(puppet.position.y) + 8


M2_TYPES = ("transport-belt", "underground-belt", "pipe", "pipe-to-ground")


def m2_clear():
    for e in list(F.surface.entities.values()):
        p = e.position
        if e.valid and e.type in M2_TYPES and m2_x0 - 1 <= p.x <= m2_x0 + 8 and m2_y0 - 2 <= p.y <= m2_y0 + 2:
            e.destroy()
    take()


def m2_row(dy, name="transport-belt", n=7, d=4, items=False):
    row = [spawn(name, m2_x0 + i + 0.5, m2_y0 + dy + 0.5, force="player", direction=d) for i in range(n)]
    if items:
        for i, b in enumerate(row):
            F.put_on_belt(b, 1, "iron-plate", 0.5, 9000 + 10 * dy + i)
    return row


def m2_pair(dy, item="underground-belt", d_in=4, d_out=4, at=(0, 5)):
    puppet.insert(lua.table_from({"name": item, "count": 2}))
    for x, d in zip(at, (d_in, d_out)):
        send({"t": "build", "item": item, "x": fixed(m2_x0 + x + 0.5), "y": fixed(m2_y0 + dy + 0.5), "d": d})
    tick(2)
    return take()


m2_clear()
row = m2_row(0, items=True)
beside = m2_row(1)  # the next line over, the same way: not the pair's
middle = {b.unit_number for b in row[1:5]}
ends = {row[0].unit_number, row[5].unit_number}
belts0, plates0 = inv.get_item_count("transport-belt"), inv.get_item_count("iron-plate")
msgs = m2_pair(0)
pair = [e for e in F.surface.entities.values() if e.valid and e.name == "underground-belt" and e.position.y == m2_y0 + 0.5]
mnd = {m["u"]: m for m in of_type(msgs, "mnd")}
check(len(pair) == 2 and all(not b.valid for b in row[1:6]) and row[6].valid and all(b.valid for b in beside),
      f"M2: an underground pair over a run mines the belts between, the line beside and the belt after it stay: "
      f"{[b.valid for b in row]} {[b.valid for b in beside]}")
check(set(mnd) == middle and all(m["g"] == 1 and ["transport-belt", 1] in m["l"] and ["iron-plate", 1] in m["l"]
                                 for m in mnd.values()),
      f"M2: each belt between is said at once (`mnd`), gone, its belt and its item to the character: {sorted(mnd)}")
check({d["u"] for d in of_type(msgs, "del")} >= middle | ends,
      f"M2: their `del`s, and the ends' replaced belts': {[d['u'] for d in of_type(msgs, 'del')]}")
check(inv.get_item_count("transport-belt") == belts0 + 6 and inv.get_item_count("iron-plate") == plates0 + 6
      and inv.get_item_count("underground-belt") == 0,
      f"M2: the four between and the two the ends replaced come back with their six plates: "
      f"belts +{inv.get_item_count('transport-belt') - belts0}, plates +{inv.get_item_count('iron-plate') - plates0}")
inv_k = [m["k"] for m in of_type(msgs, "inv")]
check(bool(inv_k), f"M2: the inventory is sent at once with them: {inv_k}")

# Not a plain run: nothing between goes (the ends are still built over their belts).
m2_cases = {}
m2_clear()
side = m2_row(0)
feeder = spawn("transport-belt", m2_x0 + 2.5, m2_y0 - 0.5, force="player", direction=8)
F.link_belts(feeder, side[2])
m2_pair(0)
m2_cases["a belt fed from the side"] = [b.valid for b in side[1:5]]
m2_clear()
back = m2_row(0)
back[3].direction = 12
m2_pair(0)
m2_cases["a belt the other way"] = [b.valid for i, b in enumerate(back[1:5]) if i != 2]
m2_clear()
gap = m2_row(0)
gap[2].destroy()
m2_pair(0)
m2_cases["a gap"] = [b.valid for b in (gap[1], gap[3], gap[4])]
m2_clear()
bent = m2_row(0)
F.entity_data(bent[2]).belt_shape = "left"
m2_pair(0)
m2_cases["a curve"] = [b.valid for b in bent[1:5]]
m2_clear()
west = m2_row(0, d=12)
m2_pair(0)  # the pair goes east under belts going west
m2_cases["belts going the other way"] = [b.valid for b in west[1:5]]
for name, kept in m2_cases.items():
    check(all(kept), f"M2: {name} between keeps the run: {kept}")

# Pipes-to-ground over pipes: the same, and a branch keeps them.
m2_clear()
pipes = m2_row(0, name="pipe")
pipes0 = inv.get_item_count("pipe")
msgs = m2_pair(0, item="pipe-to-ground", d_in=12, d_out=4)
ptg = [e for e in F.surface.entities.values() if e.valid and e.name == "pipe-to-ground"]
check(len(ptg) == 2 and all(not p.valid for p in pipes[:6]) and pipes[6].valid
      and inv.get_item_count("pipe") == pipes0 + 6 and inv.get_item_count("pipe-to-ground") == 0
      and {m["u"] for m in of_type(msgs, "mnd")} == {p.unit_number for p in pipes[1:5]},
      f"M2: a pipe-to-ground pair over pipes mines the pipes between: {[p.valid for p in pipes]}, "
      f"pipes +{inv.get_item_count('pipe') - pipes0}")
m2_clear()
pipes = m2_row(0, name="pipe")
spawn("pipe", m2_x0 + 3.5, m2_y0 - 0.5, force="player")
m2_pair(0, item="pipe-to-ground", d_in=12, d_out=4)
check(all(p.valid for p in pipes[1:5]), f"M2: a pipe with a branch between keeps the pipes: {[p.valid for p in pipes]}")

# A full inventory: mined anyway, the rest spilled at the character's feet, as Factorio's build spills it.
m2_clear()
row = m2_row(0, items=True)
spilled0 = len(F.spilled)
F.inventory_space = 3
m2_pair(0)
F.inventory_space = float("inf")
check(all(not b.valid for b in row[1:5]) and len(F.spilled) > spilled0,
      f"M2: a full inventory still mines the run, the rest spilled: {len(F.spilled) - spilled0} stacks")

# /f3d-perf under_clear off: as before (the run stays, an end's items deleted with its belt).
m2_clear()
row = m2_row(0, items=True)
g.storage.f3d_perf = lua.table_from({"under_clear": False})  # (set_perf, below)
plates0 = inv.get_item_count("iron-plate")
msgs = m2_pair(0)
g.storage.f3d_perf = None
check(all(b.valid for b in row[1:5]) and not of_type(msgs, "mnd") and inv.get_item_count("iron-plate") == plates0,
      f"M2: under_clear off: the belts between stay and no `mnd`, as before: {[b.valid for b in row]}")
m2_clear()

puppet.insert(lua.table_from({"name": "rail", "count": 3}))
send({"t": "build", "item": "rail", "x": int(4.2 * 256), "y": int(3.7 * 256), "d": 0})
tick(2)
adds = of_type(take(), "add")
check(adds and adds[0]["e"][1] == eid["straight-rail"] and adds[0]["e"][2:4] == [5 * 256, 3 * 256],
      f"rail (a 2.x rail planner) builds a straight rail on the two-tile grid: {adds[:1]}")
puppet.insert(lua.table_from({"name": "locomotive", "count": 2}))
send({"t": "build", "item": "locomotive", "x": int(5.4 * 256), "y": int(3.8 * 256), "d": 12})
send({"t": "build", "item": "locomotive", "x": int(-6 * 256), "y": int(-6 * 256), "d": 0})
tick(2)
msgs = take()
locos = [e for e in F.surface.entities.values() if e.name == "locomotive"]
check(len(locos) == 1 and (locos[0].position.x, locos[0].position.y, locos[0].direction) == (5, 3, 0),
      "rolling stock goes onto the nearest rail, along it")
check(any(m["text"] == "Rolling stock goes on rails" for m in of_type(msgs, "msg")), "and not where there is no rail")
# Issue #13: a rolling stock ghost is sent facing its way (its orientation: its direction reads
# north), and when it goes (robots build the train, which is a mover and never `add`ed) its del.
locos[0].destroy()
tick(2)
take()
send({"t": "build", "item": "locomotive", "x": int(5.4 * 256), "y": int(3.8 * 256), "d": 8, "ghost": 1})
tick(2)
stock_ghosts = [m["e"] for m in of_type(take(), "add") if m["e"][1] == eid["entity-ghost"]]
check(len(stock_ghosts) == 1 and stock_ghosts[0][5].get("gh") == eid["locomotive"] and stock_ghosts[0][4] == 8,
      f"#13: a locomotive ghost is sent facing its orientation (south), not its direction: {stock_ghosts}")
stock_ghost = next(e for e in F.surface.entities.values() if e.name == "entity-ghost" and e.ghost_name == "locomotive")
stock_ghost.revive()  # what a construction robot does, raising on_robot_built_entity for a mover
tick(2)
msgs = take()
built = [e for e in F.surface.entities.values() if e.name == "locomotive"]
check(stock_ghosts and any(d["u"] == stock_ghosts[0][0] for d in of_type(msgs, "del")) and len(built) == 1
      and built[0].direction == 8, f"#13: the train built from the ghost sends the ghost's del: {of_type(msgs, 'del')}")

inv.remove(lua.table_from({"name": "transport-belt", "count": 999}))
puppet.insert(lua.table_from({"name": "transport-belt", "count": 2, "quality": "rare"}))
puppet.insert(lua.table_from({"name": "transport-belt", "count": 1}))
send({"t": "build", "item": "transport-belt", "x": int(0.5 * 256), "y": int(7.5 * 256), "d": 0, "q": "rare"})
send({"t": "build", "item": "transport-belt", "x": int(1.5 * 256), "y": int(7.5 * 256), "d": 0})
send({"t": "build", "item": "transport-belt", "x": int(2.5 * 256), "y": int(7.5 * 256), "d": 0})
tick(2)
adds = [m["e"] for m in of_type(take(), "add")]
check([a[5].get("q") for a in adds] == ["rare", None, "rare"],
      f"q picks the stack's quality; without it normal comes first, then what there is: {[a[5] for a in adds]}")
contents = {(it["name"], it["quality"]): it["count"] for it in inv.get_contents().values() if it["name"] == "transport-belt"}
check(not contents, f"each build used its own stack: {contents}")
for e in list(F.surface.entities.values()):
    if e.name in ("locomotive", "straight-rail") or (e.name == "transport-belt" and e.position.y == 7.5):
        e.destroy()

# --- tiles, capsules, the rail planner ----------------------------------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
take()
puppet.insert(lua.table_from({"name": "concrete", "count": 5}))
puppet.insert(lua.table_from({"name": "stone-brick", "count": 1}))
F.surface.set_tile(4, 3, "stone-path")
send({"t": "tile", "item": "concrete", "x": fixed(4.6), "y": fixed(3.6), "n": 2})
tick(2)
msgs = take()
flat = [v for m in of_type(msgs, "tiles") for v in m["l"]]
laid = {(flat[i], flat[i + 1]): flat[i + 2] for i in range(0, len(flat), 3)}
check(laid == {(x, y): tid["concrete"] for x in (4, 5) for y in (3, 4)} and inv.get_item_count("concrete") == 1
      and inv.get_item_count("stone-brick") == 2,
      f"tile: a 2x2 brush on the nearest corner, one concrete each, the stone path under it comes back: {laid}")
send({"t": "tile", "item": "concrete", "x": fixed(-45.5), "y": fixed(0.5), "n": 1})
send({"t": "tile", "item": "concrete", "x": fixed(4.5), "y": fixed(3.5), "n": 1})
tick(2)
check(not of_type(take(), "tiles") and inv.get_item_count("concrete") == 1, "not on water (its condition), nor on itself")
send({"t": "tile", "item": "concrete", "x": fixed(8.5), "y": fixed(12.5), "n": 3, "ghost": 1})
tick(2)
ghosts = [m["e"] for m in of_type(take(), "add") if m["e"][1] == eid["tile-ghost"]]
check(len(ghosts) == 9 and all(g[5].get("tg") == tid["concrete"] for g in ghosts) and inv.get_item_count("concrete") == 1,
      f"ghost: tile ghosts for the robots (extra.tg), no items: {ghosts[:1]}")
send({"t": "tile_mine", "x": fixed(4.5), "y": fixed(3.5), "n": 1})
send({"t": "tile_mine", "x": fixed(8.5), "y": fixed(12.5), "n": 3})
tick(2)
msgs = take()
flat = [v for m in of_type(msgs, "tiles") for v in m["l"]]
check(flat == [4, 3, tid["grass-1"]] and inv.get_item_count("concrete") == 2 and len(of_type(msgs, "del")) == 9,
      f"tile_mine: the tile back into the inventory (LuaControl.mine_tile), tile ghosts removed: {flat}")
for e in list(F.surface.entities.values()):
    if e.type == "tile-ghost":
        e.destroy()

puppet.insert(lua.table_from({"name": "grenade", "count": 2}))
send({"t": "throw", "item": "grenade", "x": fixed(puppet.position.x + 5), "y": fixed(puppet.position.y)})
send({"t": "throw", "item": "grenade", "x": fixed(puppet.position.x + 30), "y": fixed(puppet.position.y)})
tick(2)
msgs = take()
check(len(F.capsules) == 1 and F.capsules[1].name == "grenade" and inv.get_item_count("grenade") == 1
      and any(m["text"] == "Out of range" for m in of_type(msgs, "msg")),
      "throw: LuaItemStack.use_capsule at the target in range (one used), not out of range")
puppet.insert(lua.table_from({"name": "cliff-explosives", "count": 1}))
send({"t": "throw", "item": "cliff-explosives", "x": fixed(puppet.position.x + 3), "y": fixed(puppet.position.y)})
tick(2)
check(len(F.capsules) == 1 and any(m["text"] == "No cliff there" for m in of_type(take(), "msg")),
      "cliff explosives need a cliff in their radius")

inv.remove(lua.table_from({"name": "rail", "count": 999}))
puppet.insert(lua.table_from({"name": "rail", "count": 3}))
px, py = puppet.position.x, puppet.position.y
rx, ry = math.floor(px / 2) * 2 + 1, math.floor(py / 2) * 2 + 1
path = [["straight-rail", fixed(rx), fixed(ry + 6), 0], ["curved-rail-a", fixed(rx), fixed(ry + 9), 8],
        ["straight-rail", fixed(rx), fixed(ry + 24), 0]]
send({"t": "rails", "item": "rail", "l": path})
tick(2)
msgs = take()
adds = [m["e"] for m in of_type(msgs, "add")]
got = sorted((a[1], a[5].get("gh") if len(a) > 5 else None) for a in adds)
check(got == sorted([(eid["straight-rail"], None), (eid["entity-ghost"], eid["curved-rail-a"]), (eid["entity-ghost"], eid["straight-rail"])])
      and inv.get_item_count("rail") == 2 and any("2 rail pieces placed as ghosts" in m["text"] for m in of_type(msgs, "msg")),
      f"rails: the planner's pieces in order, ghosts where rails run out (a curve costs 3) or out of reach: {got}")
send({"t": "rails", "item": "rail", "l": [["assembling-machine-1", fixed(rx), fixed(ry), 0]]})
tick(2)
check(any(m["text"] == "Can't build that with rail" for m in of_type(take(), "msg")), "and nothing the planner can't build")
for e in list(F.surface.entities.values()):
    if e.type in ("straight-rail", "curved-rail-a") or (e.type == "entity-ghost" and e.ghost_name in ("straight-rail", "curved-rail-a")):
        e.destroy()

# --- fluids, wires, power ------------------------------------------------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
take()
pole_a = spawn("small-electric-pole", 14.5, 5.5, force="player")
pole_b = spawn("small-electric-pole", 18.5, 5.5, force="player")
F.connect(pole_a, pole_b, g.defines.wire_type.copper)
F.connect(pole_a, pole_b, g.defines.wire_type.red)
pipe = spawn("pipe", 12.5, 6.5, force="player")
F.set_fluid(pipe, 1, lua.table_from({"name": "water", "amount": 80, "temperature": 15}))
send({"t": "resync", "full": 0, "c": [[0, 0]]})
tick(60)
msgs = take()
recs = {r[0]: r for m in of_type(msgs, "ents") for r in m["e"]}
check(recs.get(pole_a.unit_number, [None] * 6)[5:] == [{"w": [pole_b.unit_number], "r": [pole_b.unit_number]}],
      f"pole records carry their copper and red wires by unit number: {recs.get(pole_a.unit_number)}")
fl = [m["l"] for m in of_type(msgs, "fl")]
check(fl and [pipe.unit_number, 1, fid["water"], 80, 100, 15] == fl[-1][fl[-1].index(pipe.unit_number):fl[-1].index(pipe.unit_number) + 6],
      f"fl: fluid in a pipe near the camera (box, fluid, amount, capacity, temperature): {fl[-1:]}")
power_asm = spawn("assembling-machine-1", 16.5, 9.5, force="player")
power_asm.status = g.defines.entity_status.no_power
tick(60)
pw = [m["l"] for m in of_type(take(), "pw")]
check(pw and pw[-1][pw[-1].index(power_asm.unit_number) + 1] == 0, f"pw: a machine without power: {pw[-1:]}")
power_asm.status = g.defines.entity_status.low_power
tick(60)
pw = [m["l"] for m in of_type(take(), "pw")]
check(pw and pw[-1][pw[-1].index(power_asm.unit_number) + 1] == 1, "pw: and with low power")
power_asm.status = g.defines.entity_status.working
F.set_fluid(power_asm, 1, lua.table_from({"name": "water", "amount": 50}), 200)
power_asm.energy = 500
puppet.position = lua.table_from({"x": 14, "y": 8})
send(open_cmd(power_asm))
tick(60)
msgs = take()
pw = [m["l"] for m in of_type(msgs, "pw")]
check(pw and power_asm.unit_number not in pw[-1][::2], "a powered machine drops out of pw")
gui = guis(msgs, power_asm)
check(gui and gui[-1].get("fb") == [["water", 50, 200, 15]] and gui[-1].get("status") == "working" and gui[-1].get("pw") == 500,
      f"gui: fluid boxes, status and how full the power buffer is: {gui[-1:]}")
send({"t": "close"})
puppet.position = lua.table_from({"x": 0, "y": 0})
for e in (pole_a, pole_b, pipe, power_asm):
    e.destroy()
tick(2)
take()

# --- blueprints, ghosts, planners -----------------------------------------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
take()
F.blueprint = lua.table_from([{"name": "transport-belt", "x": 0, "y": 0}, {"name": "wooden-chest", "x": 1, "y": 0}], recursive=True)
for name in ("blueprint", "deconstruction-planner", "upgrade-planner"):
    puppet.insert(lua.table_from({"name": name, "count": 1}))
inv = puppet.get_main_inventory()
size = lua.eval("function(t) return #t end")(inv)  # Python's len() skips the __len metamethod
slot = {name: next(i for i in range(1, size + 1) if inv[i].valid_for_read and inv[i].name == name)
        for name in ("blueprint", "deconstruction-planner", "upgrade-planner", "wood")}
send({"t": "blueprint", "i": slot["blueprint"], "x": int(1.5 * 256), "y": int(8.5 * 256), "d": 0})
send({"t": "blueprint", "i": slot["wood"], "x": 0, "y": 0, "d": 0})
tick(2)
msgs = take()
ghosts = [m["e"] for m in of_type(msgs, "add") if m["e"][1] == eid["entity-ghost"]]
check(sorted((g[2], g[3], g[5].get("gh")) for g in ghosts) == [(384, 2176, eid["transport-belt"]), (640, 2176, eid["wooden-chest"])],
      f"blueprint places ghosts, sent as static entities with the entity they stand for: {ghosts}")
check(any(m["text"] == "That isn't a blueprint" for m in of_type(msgs, "msg")), "a slot without a blueprint is refused")
check(F.last_build_mode == 1, "a blueprint without bm is placed forced, as older clients expect")
for bm, mode in ((0, 0), (1, 1), (2, 2)):
    send({"t": "blueprint", "i": slot["blueprint"], "x": int(1.5 * 256), "y": int(30.5 * 256), "d": 0, "bm": bm})
    tick(1)
    check(F.last_build_mode == mode, f"bm {bm}: build_mode {mode} (click normal, Shift forced, Ctrl+Shift super-forced)")
for e in list(F.surface.entities.values()):
    if e.position.y == 30.5:
        e.destroy()
take()
belt_ghost = next(g for g in ghosts if g[5]["gh"] == eid["transport-belt"])
puppet.insert(lua.table_from({"name": "transport-belt", "count": 1}))
belts = inv.get_item_count("transport-belt")
# Plates lying where the belt goes: 2.1's revive picks them up and returns them as
# array[ItemWithQualityCount], which the bridge read as name -> count and threw on.
spawn("item-on-ground", belt_ghost[2] / 256, belt_ghost[3] / 256, stack={"name": "iron-plate", "count": 3})
plates = inv.get_item_count("iron-plate")
send({"t": "build", "item": "transport-belt", "x": belt_ghost[2], "y": belt_ghost[3], "d": 0})
tick(2)
msgs = take()
check(any(d["u"] == belt_ghost[0] for d in of_type(msgs, "del")) and any(a["e"][1] == eid["transport-belt"] and a["e"][2:4] == belt_ghost[2:4] for a in of_type(msgs, "add"))
      and inv.get_item_count("transport-belt") == belts - 1, "building over a ghost revives it: the ghost's del, the belt's add")
check(inv.get_item_count("iron-plate") == plates + 3 and not any("Bridge error" in m["text"] for m in of_type(msgs, "msg")),
      f"what the revived belt collided with (2.1: an array of ItemWithQualityCount) goes to the character: "
      f"{inv.get_item_count('iron-plate') - plates} plates, {[m['text'] for m in of_type(msgs, 'msg')]}")
belt_real = next(e for e in F.surface.entities.values() if e.name == "transport-belt" and e.position.y == 8.5)
area = {"x1": 0, "y1": 8 * 256, "x2": 3 * 256, "y2": 9 * 256}
chest_ghost = next(g for g in ghosts if g[5]["gh"] == eid["wooden-chest"])
send({"t": "decon", "i": 0, **area})
tick(2)
msgs = take()
upd = [m["e"] for m in of_type(msgs, "upd") if m["e"][0] == belt_real.unit_number]
check(upd and upd[-1][5].get("d") == 1, f"decon without a planner marks the area; the record says so: {upd[-1:]}")
# Owner's #20: Factorio deletes the ghosts in the area with no event, so the client must be told.
check(any(d["u"] == chest_ghost[0] for d in of_type(msgs, "del")), f"decon (Alt+D) removes the ghosts in the area and sends their del: {of_type(msgs, 'del')}")
send({"t": "decon", "i": slot["deconstruction-planner"], "cancel": 1, **area})
tick(2)
upd = [m["e"] for m in of_type(take(), "upd") if m["e"][0] == belt_real.unit_number]
check(upd and "d" not in upd[-1][5], "a deconstruction planner's cancel unmarks it")
F.upgrades = lua.table_from({"transport-belt": "fast-transport-belt"})
send({"t": "upgrade", "i": slot["upgrade-planner"], **area})
tick(2)
upd = [m["e"] for m in of_type(take(), "upd") if m["e"][0] == belt_real.unit_number]
check(upd and upd[-1][5].get("up") == eid["fast-transport-belt"], f"upgrade marks it with its target: {upd[-1:]}")
send({"t": "upgrade", "i": slot["upgrade-planner"], "cancel": 1, **area})
send({"t": "upgrade", "i": slot["wood"], **area})
tick(2)
msgs = take()
check(any("up" not in m["e"][5] for m in of_type(msgs, "upd") if m["e"][0] == belt_real.unit_number), "cancelling the upgrade unmarks it")
check(any(m["text"] == "That isn't an upgrade planner" for m in of_type(msgs, "msg")), "a slot without an upgrade planner is refused")
# Downgrade (right-drag): the planner's mappings the other way round.
up = inv[slot["upgrade-planner"]]
up.set_mapper(1, "from", lua.table_from({"type": "entity", "name": "transport-belt"}))
up.set_mapper(1, "to", lua.table_from({"type": "entity", "name": "fast-transport-belt"}))
fast = spawn("fast-transport-belt", 0.5, 8.5)
take()
send({"t": "upgrade", "i": slot["upgrade-planner"], "down": 1, **area})
tick(2)
msgs = take()
upd = [m["e"] for m in of_type(msgs, "upd") if m["e"][0] == fast.unit_number]
check(upd and upd[-1][5].get("up") == eid["transport-belt"], f"down: 1 marks by the reversed mappings (fast belt -> belt): {upd[-1:]}")
check(not any(m["e"][0] == belt_real.unit_number and m["e"][5].get("up") for m in of_type(msgs, "upd")), "and not the plain belt")
check(up.mapper_count == 1 and up.get_mapper(1, "from").name == "transport-belt", "the planner itself keeps its mappings")
send({"t": "upgrade", "i": slot["upgrade-planner"], "cancel": 1, **area})
tick(2)
take()
# bp_del: the planner window's delete button destroys the planner; anything else stays.
puppet.insert(lua.table_from({"name": "blueprint-book", "count": 1}))
spare = next(i for i in range(1, size + 1) if inv[i].valid_for_read and inv[i].name == "blueprint-book")
# Owner's #13: the icons a book was given are drawn over it in the inventory, so they go with `slots`.
inv[spare].preview_icons = lua.eval('{{signal = {type = "virtual", name = "signal-A"}, index = 2}, {signal = {name = "iron-plate"}, index = 1}}')
tick(31)
ic = [m.get("ic") for m in of_type(take(), "slots")]
check(ic and [spare, [["item", "iron-plate"], ["virtual", "signal-A"]]] in (ic[-1] or []),
      f"slots carries a book's icons in their order (ic): {ic[-1:]}")
send({"t": "bp_del", "i": spare})
send({"t": "bp_del", "i": slot["wood"]})
tick(1)
check(not inv[spare].valid_for_read and inv[slot["wood"]].valid_for_read, "bp_del destroys a planner, not other items")
for e in list(F.surface.entities.values()):
    if e.position.y == 8.5 and e.position.x < 3:
        e.destroy()

# --- exchange strings, the library, undo, super-forced build, qualities -------------------------
take()
g.package.loaded["scripts.planners"].send_initial()  # sent at every handshake
tick(1)
quals = of_type(take(), "quals")
check(quals and [q[0] for q in quals[-1]["l"]] == ["normal", "uncommon", "rare", "epic", "legendary"]
      and quals[-1]["l"][2][2] == 1 and quals[-1]["l"][3][2] == 0,
      f"quals lists the qualities in order, unlocked ones marked, without quality-unknown: {quals[-1:]}")
inv[slot["blueprint"]].import_stack("0FAKE|blueprint|Belt and chest|transport-belt,wooden-chest")
send({"t": "bp_get", "q": 7, "i": slot["blueprint"]})
tick(2)
bp = of_type(take(), "bp")
check(len(bp) == 1 and bp[0]["q"] == 7 and bp[0]["s"].startswith("0FAKE|blueprint|Belt and chest") and bp[0]["item"] == "blueprint",
      f"bp_get exports the blueprint as its string: {bp}")
send({"t": "bp_get", "q": 8, "i": slot["wood"]})
tick(2)
bp = of_type(take(), "bp")
check(bp and bp[0]["s"] == "" and bp[0].get("err"), f"bp_get on something else says so: {bp}")
long_label = "x" * 40000
inv[slot["blueprint"]].import_stack("0FAKE|blueprint|" + long_label + "|transport-belt")
send({"t": "bp_get", "q": 9, "i": slot["blueprint"]})
tick(2)
bp = of_type(take(), "bp")
check(len(bp) == 3 and [m["part"] for m in bp] == [1, 2, 3] and all(m["parts"] == 3 for m in bp)
      and "".join(m["s"] for m in bp) == "0FAKE|blueprint|" + long_label + "|transport-belt",
      "a long string comes in parts that join up again")
inv[slot["blueprint"]].import_stack("0FAKE|blueprint|Belt and chest|transport-belt,wooden-chest")
# bp_set: a new one in the inventory, in parts; the cursor's library stack (-1)
data = "0FAKE|blueprint|From the library|transport-belt,wooden-chest"
send({"t": "bp_set", "q": 3, "i": 0, "id": 41, "part": 2, "parts": 2, "d": data[20:]})
send({"t": "bp_set", "q": 3, "i": 0, "id": 41, "part": 1, "parts": 2, "d": data[:20]})
tick(2)
ok = of_type(take(), "bp_ok")
check(ok and ok[-1]["q"] == 3 and ok[-1]["item"] == "blueprint" and inv[ok[-1]["i"]].valid_for_read
      and inv[ok[-1]["i"]].export_stack().startswith("0FAKE|blueprint|From the library"),
      f"bp_set in parts makes a new blueprint in the inventory and says which slot: {ok}")
send({"t": "bp_set", "q": 4, "i": slot["wood"], "s": data})
send({"t": "bp_set", "q": 5, "i": 0, "s": "not a blueprint string"})
tick(2)
msgs = take()
check(not of_type(msgs, "bp_ok") and any(m["text"] == "That slot holds something else" for m in of_type(msgs, "msg"))
      and any("can import" in m["text"] for m in of_type(msgs, "msg")), "bp_set refuses another item's slot and a bad string")
send({"t": "bp_set", "q": 6, "i": -1, "s": data})
tick(2)
ok = of_type(take(), "bp_ok")
check(ok and ok[-1]["i"] == -1 and g.storage.f3d.lib_cursor[1].valid_for_read, f"bp_set -1 fills the library stack in the cursor: {ok}")
send({"t": "blueprint", "i": -1, "x": fixed(2.5), "y": fixed(26.5), "d": 0})
tick(2)
msgs = take()
placed = [m["e"] for m in of_type(msgs, "add") if m["e"][1] == eid["entity-ghost"]]
hist = of_type(msgs, "hist")
check(len(placed) == 2 and hist and hist[-1]["what"] == "blueprint", f"the cursor's library blueprint places ghosts, remembered for undo: {hist}")
send({"t": "undo", "h": hist[-1]["h"] if hist else 0})
tick(2)
dels = [m["u"] for m in of_type(take(), "del")]
check(sorted(dels) == sorted(p[0] for p in placed), f"undo takes the placed ghosts away: {dels}")
send({"t": "redo", "h": hist[-1]["h"] if hist else 0})
tick(2)
again = [m["e"] for m in of_type(take(), "add") if m["e"][1] == eid["entity-ghost"]]
check(len(again) == 2, "redo places them again")
# m: 1, a held blueprint flipped: a mirrored copy is placed; the blueprint itself stays as it was.
lib = g.storage.f3d.lib_cursor[1]
lib.set_blueprint_entities(lua.table_from([
    {"entity_number": 1, "name": "transport-belt", "position": {"x": -1.5, "y": 0.5}, "direction": 4},
    {"entity_number": 2, "name": "assembling-machine-1", "position": {"x": 2.5, "y": 0.5}},
], recursive=True))
send({"t": "blueprint", "i": -1, "x": fixed(40.5), "y": fixed(40.5), "d": 0, "m": 1})
tick(2)
take()
built = {b.name: b for b in F.last_built.values()}
belt_b, asm_b2 = built.get("transport-belt"), built.get("assembling-machine-1")
check(belt_b and belt_b.position.x == 1.5 and belt_b.direction == 12 and asm_b2 and asm_b2.position.x == -2.5 and asm_b2.mirror is True,
      "m: 1 places the blueprint mirrored: x negated, east becomes west, the assembler's mirror flag set")
check(lib.get_blueprint_entities()[1].position.x == -1.5, "and the held blueprint itself is unchanged")
for e in list(F.surface.entities.values()):
    if e.position.y == 40.5 or e.position.y == 41.5 or e.position.y == 39.5:
        e.destroy()
take()
send({"t": "undo", "h": 99999})
tick(2)
check(any(m["text"] == "That can no longer be undone" for m in of_type(take(), "msg")), "an unknown undo entry is refused")
# Deconstruction marks: undo removes exactly the marks that action added.
chest_a = spawn("wooden-chest", 40.5, 40.5, force="player")
chest_b = spawn("wooden-chest", 41.5, 40.5, force="player")
chest_b.order_deconstruction("player")
send({"t": "decon", "i": 0, "x1": fixed(40), "y1": fixed(40), "x2": fixed(42), "y2": fixed(41)})
tick(2)
hist = of_type(take(), "hist")
check(hist and hist[-1]["what"] == "deconstruction" and F.decon_marks[chest_a] is True, f"decon is remembered: {hist}")
send({"t": "undo", "h": hist[-1]["h"] if hist else 0})
tick(2)
check(F.decon_marks[chest_a] is None and F.decon_marks[chest_b] is True, "undo removes its own marks and keeps the older one")
send({"t": "redo", "h": hist[-1]["h"] if hist else 0})
tick(2)
check(F.decon_marks[chest_a] is True, "redo marks it again")
send({"t": "decon", "i": 0, "cancel": 1, "x1": fixed(40), "y1": fixed(40), "x2": fixed(42), "y2": fixed(41)})
tick(2)
hist = of_type(take(), "hist")
check(hist and hist[-1]["what"] == "cancel deconstruction" and F.decon_marks[chest_b] is None, "cancelling is remembered too")
send({"t": "undo", "h": hist[-1]["h"] if hist else 0})
tick(2)
check(F.decon_marks[chest_a] is True and F.decon_marks[chest_b] is True, "undoing a cancel puts the marks back")
# Upgrade marks
belt_u = spawn("transport-belt", 44.5, 40.5, force="player")
send({"t": "upgrade", "i": slot["upgrade-planner"], "x1": fixed(44), "y1": fixed(40), "x2": fixed(45), "y2": fixed(41)})
tick(2)
hist = of_type(take(), "hist")
check(hist and hist[-1]["what"] == "upgrade" and F.upgrade_marks[belt_u] is not None, "upgrade is remembered")
send({"t": "undo", "h": hist[-1]["h"] if hist else 0})
tick(2)
check(F.upgrade_marks[belt_u] is None, "undo cancels the upgrade")
send({"t": "redo", "h": hist[-1]["h"] if hist else 0})
tick(2)
check(F.upgrade_marks[belt_u] is not None and F.upgrade_marks[belt_u].name == "fast-transport-belt", "redo marks the upgrade again, to the same target")
# Rotation
d0 = belt_u.direction
send({"t": "rotate", "u": belt_u.unit_number, "p": eid["transport-belt"], "x": fixed(44.5), "y": fixed(40.5), "rev": 0})
tick(2)
hist = of_type(take(), "hist")
check(hist and hist[-1]["what"] == "rotation" and belt_u.direction == (d0 + 4) % 16, "a rotation is remembered")
send({"t": "undo", "h": hist[-1]["h"] if hist else 0})
tick(2)
check(belt_u.direction == d0, "undo turns it back")
# Super-forced build (Ctrl+Shift+click): a ghost through a one-entity blueprint
puppet.insert(lua.table_from({"name": "wooden-chest", "count": 1}))
send({"t": "build", "item": "wooden-chest", "x": fixed(10.5), "y": fixed(26.5), "d": 0, "ghost": 1, "sf": 1})
tick(2)
msgs = take()
sf = [m["e"] for m in of_type(msgs, "add") if m["e"][1] == eid["entity-ghost"] and m["e"][5].get("gh") == eid["wooden-chest"]]
check(sf and sf[0][2:4] == [fixed(10.5), fixed(26.5)] and of_type(msgs, "hist"), f"super-forced build places a ghost there, undoably: {sf}")
# The game's and an offline player's libraries
F.game_blueprints[1] = F.make_record("blueprint", "Smelting", "0FAKE|blueprint|Smelting|stone-furnace")
F.game_blueprints[2] = F.make_record("blueprint-book", "Trains", "0FAKE|blueprint-book|Trains|")
send({"t": "bp_lib"})
tick(2)
bpl = of_type(take(), "bpl")
check(bpl and bpl[0]["src"] == "game" and bpl[0]["l"][0][:3] == [1, "blueprint", "Smelting"] and bpl[0]["l"][1][1] == "blueprint-book"
      and bpl[0]["l"][0][3] == [["item", "transport-belt"]], f"bp_lib lists the game's library: {bpl}")
send({"t": "bp_rec", "q": 11, "src": "game", "ix": 1})
tick(2)
bp = of_type(take(), "bp")
check(bp and bp[0]["s"] == "0FAKE|blueprint|Smelting|stone-furnace" and bp[0]["src"] == "game" and bp[0]["ix"] == 1,
      f"bp_rec sends a record's string: {bp}")
send({"t": "bp_rec", "q": 12, "src": "game", "ix": 2, "to": -1})
tick(2)
ok = of_type(take(), "bp_ok")
check(ok and ok[-1]["i"] == -1 and ok[-1]["item"] == "blueprint-book", f"bp_rec with to = -1 takes it into the cursor: {ok}")
send({"t": "bp_page", "i": -1, "a": 2})
tick(2)
check(g.storage.f3d.lib_cursor[1].active_index == 2, "bp_page picks the book's page")
send({"t": "bp_rec", "q": 13, "src": "player", "ix": 1})
tick(2)
bp = of_type(take(), "bp")
check(bp and bp[0]["s"] == "" and bp[0].get("err"), "without a player taken over there is no player library")
for e in (chest_a, chest_b, belt_u):
    e.destroy()
for e in list(F.surface.entities.values()):
    if e.type == "entity-ghost" and e.position.y == 26.5:
        e.destroy()
take()

# --- circuit network ------------------------------------------------------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
take()
ids = g.defines.wire_connector_id
arith = spawn("arithmetic-combinator", 4.5, 3.0, force="player")
const = spawn("constant-combinator", 6.5, 3.5, force="player")
F.signals[arith] = lua.table_from({ids.circuit_red: [{"signal": {"type": "item", "name": "iron-plate"}, "count": 40}]}, recursive=True)
send(open_cmd(arith))
tick(2)
gui = guis(take(), arith)
check(gui and gui[-1]["kind"] == "combinator" and gui[-1]["cb"].get("operation") == "*" and gui[-1]["cb"].get("second_constant") == 2,
      f"an arithmetic combinator opens with its parameters: {gui[-1:]}")
check(gui and gui[-1].get("sig") == {"r": [["item", "iron-plate", 40]], "g": []}, f"and the signals on its networks: {gui[-1:]}")
params = dict(gui[-1]["cb"]) if gui else {}
params["operation"] = "+"
send({"t": "set_cb", "u": arith.unit_number, "cb": params})
tick(2)
gui = guis(take(), arith)
check(gui and gui[-1]["cb"]["operation"] == "+" and arith.get_control_behavior().parameters.operation == "+",
      "set_cb writes the parameters back")
send(open_cmd(const))
send({"t": "set_cb", "u": const.unit_number, "cb": {"enabled": True, "signals": [["item", "iron-plate", 5], ["virtual", "signal-A", -3]]}})
tick(2)
gui = guis(take(), const)
check(gui and gui[-1]["cb"]["enabled"] is True and gui[-1]["cb"]["signals"] == [["item", "iron-plate", 5], ["virtual", "signal-A", -3]],
      f"a constant combinator's signals are set and read back: {gui[-1:]}")
# Sections: a second one, inactive with a multiplier; then back to one (the extra is removed).
two = [{"g": "", "on": 1, "m": 1, "s": [["item", "iron-plate", 5]]}, {"g": "", "on": 0, "m": 2, "s": [["virtual", "signal-B", 7, "rare"]]}]
send({"t": "set_cb", "u": const.unit_number, "cb": {"enabled": True, "sections": two}})
tick(2)
gui = guis(take(), const)
check(gui and gui[-1]["cb"]["sections"] == two and gui[-1]["cb"]["signals"] == [["item", "iron-plate", 5]],
      f"constant combinator sections (add_section, active, multiplier, quality) read back: {gui[-1:]}")
send({"t": "set_cb", "u": const.unit_number, "cb": {"enabled": False, "sections": two[:1]}})
tick(2)
gui = guis(take(), const)
check(gui and len(gui[-1]["cb"]["sections"]) == 1 and gui[-1]["cb"]["enabled"] is False, f"remove_section drops the extra one: {gui[-1:]}")
send({"t": "set_cb", "u": const.unit_number, "cb": "nonsense"})
tick(2)
check(any(m["text"] == "That isn't a combinator" for m in of_type(take(), "msg")), "bad settings are refused")
send({"t": "close"})

# Wire tools: red wire from the constant combinator to the arithmetic one's input, again to undo.
def wire_end(entity, dx=0.0, dy=0.0):
    p = entity.position
    return {"u": entity.unit_number, "p": eid[entity.name], "x": fixed(p.x), "y": fixed(p.y),
            "mx": fixed(p.x + dx), "my": fixed(p.y + dy)}


send({"t": "wire", "k": "r", "a": wire_end(const), "b": wire_end(arith, 0, 0.4)})
tick(2)
msgs = take()
red = arith.get_wire_connector(ids.combinator_input_red, False)
check(red.is_connected_to(const.get_wire_connector(ids.circuit_red, False)), "wire: a red wire connects two combinators (connect_to)")
check({m["e"][0] for m in of_type(msgs, "upd")} >= {arith.unit_number, const.unit_number}
      and arith.unit_number in of_type(msgs, "upd")[-1]["e"][5].get("r", []) + [m["e"][5].get("r", [0])[0] for m in of_type(msgs, "upd")],
      f"and both ends are sent again with their wires: {of_type(msgs, 'upd')}")
send({"t": "wire", "k": "r", "a": wire_end(const), "b": wire_end(arith, 0, 0.4)})
tick(2)
take()
check(not red.is_connected_to(const.get_wire_connector(ids.circuit_red, False)), "wire: the same pair again disconnects them")
send({"t": "wire", "k": "w", "a": wire_end(const), "b": wire_end(arith)})
tick(2)
check(any("Copper wire" in m["text"] for m in of_type(take(), "msg")), "copper wire on combinators is refused")
pole_a = spawn("small-electric-pole", -2.5, 4.5, force="player")
pole_b = spawn("small-electric-pole", 3.5, 4.5, force="player")
pole_far = spawn("small-electric-pole", 6.5, -4.5, force="player")
send({"t": "wire", "k": "w", "a": wire_end(pole_a), "b": wire_end(pole_b)})
tick(2)
take()
copper = pole_a.get_wire_connector(ids.pole_copper, False)
check(copper.is_connected_to(pole_b.get_wire_connector(ids.pole_copper, False)), "copper wire connects two poles")
F.wire_reach = 7.5
send({"t": "wire", "k": "w", "a": wire_end(pole_a), "b": wire_end(pole_far)})
tick(2)
check(any(m["text"] == "Wire can't reach that far" for m in of_type(take(), "msg")), "a wire that can't reach is refused (can_wire_reach)")
send({"t": "wire_clear", **{k: v for k, v in wire_end(pole_a).items() if k in ("u", "p", "x", "y")}})
tick(2)
msgs = take()
check(len(copper.connections) == 0 and len(pole_b.get_wire_connector(ids.pole_copper, False).connections) == 0,
      "wire_clear removes a pole's copper cables (disconnect_all)")
check(any(m["e"][0] == pole_b.unit_number for m in of_type(msgs, "upd")), "and the pole at the other end is sent again")

# Circuit settings (gui.cc / set_cc): an inserter's enable condition and read modes.
ins_c = spawn("inserter", 2.5, 6.5, force="player")
F.networks[ins_c] = lua.table_from({ids.circuit_red: lua.table_from({"network_id": 12})})
send(open_cmd(ins_c))
tick(2)
gui = guis(take(), ins_c)
cc = gui[-1].get("cc") if gui else None
check(cc and cc["o"] == "inserter" and cc["w"] == 1 and cc["nets"] == {"r": 12, "g": 0}
      and cc["f"].get("circuit_hand_read_mode") == "hold" and cc["f"].get("circuit_enable_disable") == 0,
      f"gui.cc: an inserter's circuit settings, wired to network 12: {cc}")
send({"t": "set_cc", "u": ins_c.unit_number, "f": {
    "circuit_enable_disable": 1, "circuit_condition": {"first_signal": {"type": "item", "name": "iron-plate"}, "comparator": ">", "constant": 50},
    "circuit_hand_read_mode": "pulse", "circuit_read_hand_contents": 1, "circuit_set_stack_size": 1,
    "circuit_stack_control_signal": {"type": "virtual", "name": "signal-S"}, "not_a_field": 1}})
tick(2)
gui = guis(take(), ins_c)
f = gui[-1]["cc"]["f"] if gui else {}
check(f.get("circuit_enable_disable") == 1 and f.get("circuit_condition", {}).get("first_signal") == {"type": "item", "name": "iron-plate"}
      and f["circuit_condition"].get("constant") == 50 and f.get("circuit_hand_read_mode") == "pulse"
      and f.get("circuit_stack_control_signal") == {"type": "virtual", "name": "signal-S"}, f"set_cc writes the behaviour's fields: {f}")
send({"t": "set_cc", "u": ins_c.unit_number, "f": {"circuit_stack_control_signal": {}}})
tick(2)
gui = guis(take(), ins_c)
check(gui and gui[-1]["cc"]["f"].get("circuit_stack_control_signal") in ({}, []), "an empty signal clears it")

# A lamp's colour and its circuit colour settings.
lamp_c = spawn("small-lamp", 4.5, 6.5, force="player")
send(open_cmd(lamp_c))
tick(2)
gui = guis(take(), lamp_c)
check(gui and gui[-1].get("col") == [255, 255, 255] and gui[-1]["cc"]["o"] == "lamp" and gui[-1]["cc"]["w"] == 0,
      f"a lamp opens with its colour and circuit settings: {gui[-1:]}")
send({"t": "set_color", "u": lamp_c.unit_number, "c": [255, 64, 0]})
send({"t": "set_cc", "u": lamp_c.unit_number, "f": {"use_colors": 1, "color_mode": "components", "red_signal": {"type": "virtual", "name": "signal-R"}}})
tick(2)
gui = guis(take(), lamp_c)
check(gui and gui[-1]["col"] == [255, 64, 0] and gui[-1]["cc"]["f"].get("use_colors") == 1 and gui[-1]["cc"]["f"].get("color_mode") == "components",
      f"set_color and the lamp's colour mode: {gui[-1:]}")
check(gui and gui[-1].get("ao") == 0, f"a lamp sends Always on: {gui[-1:]}")
send({"t": "set_lamp", "u": lamp_c.unit_number, "ao": 1})
tick(2)
gui = guis(take(), lamp_c)
check(gui and gui[-1].get("ao") == 1 and lamp_c.always_on, f"set_lamp turns Always on on: {gui[-1:]}")

# A rail signal opens (status only); a combinator sends and takes its description.
rsig = spawn("rail-signal", 6.5, 6.5, force="player")
send(open_cmd(rsig))
tick(2)
check(bool(guis(take(), rsig)), "a rail signal opens a window")
rod = spawn("lightning-rod", 5.5, 8.5, force="player")
send(open_cmd(rod))
tick(2)
msgs = take()
check(not guis(msgs, rod) and not [m for m in of_type(msgs, "msg") if "open" in m["text"]],
      "a lightning rod opens no window and says nothing, as in 2.1.23")
rod.destroy()
desc_c = spawn("constant-combinator", 3.5, 7.5, force="player")
send(open_cmd(desc_c))
tick(2)
gui = guis(take(), desc_c)
check(gui and gui[-1].get("desc") == "", f"a combinator sends its description: {gui[-1:]}")
send({"t": "set_desc", "u": desc_c.unit_number, "text": "Outpost"})
tick(2)
gui = guis(take(), desc_c)
check(gui and gui[-1].get("desc") == "Outpost" and desc_c.combinator_description == "Outpost", f"set_desc: {gui[-1:]}")
send({"t": "close"})
tick(1)
take()
for e in (rsig, desc_c):
    e.destroy()

# Turret priority targets.
tur_c = spawn("gun-turret", -4.0, 7.0, force="player")
send(open_cmd(tur_c))
send({"t": "set_targets", "u": tur_c.unit_number, "l": ["small-biter", "nonsense"], "ign": 1})
tick(2)
gui = guis(take(), tur_c)
check(gui and gui[-1].get("tgt") == {"l": ["small-biter"], "ign": 1}, f"set_targets: priority targets and ignore the rest: {gui[-1:]}")
send({"t": "set_targets", "u": tur_c.unit_number, "l": []})
tick(2)
gui = guis(take(), tur_c)
check(gui and gui[-1]["tgt"]["l"] in ([], {}), f"and clears them (set_priority_target without an entity): {gui[-1:]}")
send({"t": "close"})
for e in (arith, const, pole_a, pole_b, pole_far, ins_c, lamp_c, tur_c):
    e.destroy()
tick(2)
take()

# Spidertrons (entity_ui.lua veh, set_vehicle; spiders.lua spider_go / spider_q), artillery's auto
# targeting (art, set_artillery), a storage tank's pipeline and flush (pl, flush), a train's group.
spider = spawn("spidertron", -3.0, 4.0, force="player")
send(open_cmd(spider))
tick(2)
gui = guis(take(), spider)
check(gui and gui[-1].get("kind") == "vehicle" and gui[-1].get("veh") == {"grid": 0, "lbl": "", "at": [1, 0]} and gui[-1].get("col") == [255, 128, 0],
      f"a spidertron opens with its name, auto targeting and colour: {gui[-1:]}")
send({"t": "set_vehicle", "u": spider.unit_number, "lbl": "Spidey", "wi": 1})
send({"t": "set_color", "u": spider.unit_number, "c": [0, 0, 255]})
tick(2)
gui = guis(take(), spider)
check(gui and gui[-1]["veh"] == {"grid": 0, "lbl": "Spidey", "at": [1, 1]} and gui[-1]["col"] == [0, 0, 255] and spider.entity_label == "Spidey",
      f"set_vehicle names it and turns targeting with a gunner on; set_color colours it: {gui[-1:]}")
send({"t": "close"})
send({"t": "spider_go", "l": [spider.unit_number, 999999], "x": fixed(20), "y": fixed(-5)})
tick(1)
spd = of_type(take(), "spd")
check(spd and spd[-1]["l"] == [[spider.unit_number, [[fixed(20), fixed(-5)]]]], f"spider_go sends it there (autopilot_destination): {spd[-1:]}")
send({"t": "spider_go", "l": [spider.unit_number], "x": fixed(25), "y": fixed(-5), "q": 1})
send({"t": "spider_q", "l": [spider.unit_number]})
tick(1)
spd = of_type(take(), "spd")
check(spd and spd[-1]["l"][0][1] == [[fixed(20), fixed(-5)], [fixed(25), fixed(-5)]], f"Shift queues a waypoint (add_autopilot_destination): {spd[-1:]}")
send({"t": "spider_go", "l": [spider.unit_number], "x": fixed(1), "y": fixed(1)})
tick(1)
spd = of_type(take(), "spd")
check(spd and spd[-1]["l"][0][1] == [[fixed(1), fixed(1)]], f"a plain click replaces the queue: {spd[-1:]}")
spider.destroy()
art = spawn("artillery-turret", -8.5, 4.5, force="player")
send(open_cmd(art))
tick(2)
gui = guis(take(), art)
check(gui and gui[-1].get("art") == 1, f"artillery sends its auto targeting: {gui[-1:]}")
send({"t": "set_artillery", "u": art.unit_number, "on": 0})
tick(2)
gui = guis(take(), art)
check(gui and gui[-1].get("art") == 0 and art.artillery_auto_targeting is False, f"set_artillery turns it off: {gui[-1:]}")
send({"t": "close"})
art.destroy()
tank = spawn("storage-tank", -3.5, 8.5, force="player")
F.set_fluid(tank, 1, lua.table_from({"name": "crude-oil", "amount": 2000}), 25000)
F.segments[tank] = lua.table_from({"fluid": lua.table_from({"name": "crude-oil", "amount": 6000}), "capacity": 40000})
send(open_cmd(tank))
tick(2)
gui = guis(take(), tank)
check(gui and gui[-1].get("pl") == ["crude-oil", 6000, 40000], f"a storage tank sends its pipeline's contents (get_fluid_segment_fluid): {gui[-1:]}")
send({"t": "flush", "u": tank.unit_number, "pipe": 0})
tick(2)
gui = guis(take(), tank)
check(tank.get_fluid(1) is None, f"flush empties the tank (remove_fluid): {gui[-1:]}")
send({"t": "flush", "u": tank.unit_number, "pipe": 1})
tick(2)
gui = guis(take(), tank)
check(gui and gui[-1].get("pl") == ["", 0, 25000], f"flush with pipe 1 empties the pipeline (clear_fluid_segment_fluid): {gui[-1:]}")
send({"t": "close"})
tank.destroy()
tick(2)
take()

# --- map: charts and tags -------------------------------------------------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
take()
F.charted["0,0"] = True
g.storage.f3d.explored = None  # what the character charted itself, tested below
wall = spawn("stone-wall", 28.5, 28.5, force="player")
ore = spawn("iron-ore", 29.5, 28.5, amount=100)
send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 1, "cy2": 0, "res": 2})
tick(2)
msgs = take()
charts = {(m["cx"], m["cy"]): m for m in of_type(msgs, "chart")}
c00 = charts.get((0, 0))
check(c00 and c00["n"] == 16 and len(c00["px"]) == 256, f"a charted chunk comes as 16 x 16 pixels at 2 tiles each: {c00}")
check(charts.get((1, 0), {}).get("n") == 0, "a chunk not charted yet says so (n = 0)")
check(c00 and c00["pal"][c00["px"][14 * 16 + 14]] == [204, 217, 204],
      "a wall without a map colour gets Factorio's wall colour, over the ore under it")
check(c00 and [51, 128, 26] in c00["pal"], "tiles are drawn in their map colour")
check(of_type(msgs, "tags") and of_type(msgs, "tags")[-1]["l"] in ([], {}), "a map request sends the tags (none yet)")
send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 0, "cy2": 0, "res": 3})
tick(1)
c00 = [m for m in of_type(take(), "chart") if (m["cx"], m["cy"]) == (0, 0)]
check(c00 and c00[0]["n"] == 8, "an unknown resolution falls back to 4 tiles per pixel")
send({"t": "map", "cx1": -100, "cy1": -100, "cx2": 100, "cy2": 100, "res": 32})
tick(1)
check(len(g.storage.f3d.map.queue) <= 1024, "a huge request is cut to the 1024 chunks nearest its centre")
send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 0, "cy2": 0, "res": 32})
tick(2)
c00 = [m for m in of_type(take(), "chart") if (m["cx"], m["cy"]) == (0, 0)]
check(c00 and c00[0]["n"] == 1 and len(c00[0]["px"]) == 1, "32 tiles per pixel is one pixel per chunk")
wall.destroy()
ore.destroy()

# The work budget (budget.lua): a busy chunk's chart and snapshot are read in slices over several
# ticks, and no tick spends more than the budget; `budget` sets it (clamped), `wb` reports it.
start_tick = g.game.tick
send({"t": "budget", "u": 400})
tick(1)
check(g.storage.f3d.bud.limit == 400, f"budget sets the work budget: {g.storage.f3d.bud.limit}")
F.charted["-3,3"] = True
dense = [spawn("stone-wall", -95.5 + i % 32, 96.5 + i // 32, force="player") for i in range(1000)]
take()
send({"t": "map", "cx1": -3, "cy1": 3, "cx2": -3, "cy2": 3, "res": 2})
used, got, ticks = [], None, 0
while got is None and ticks < 40:
    tick(1)
    ticks += 1
    used.append(g.storage.f3d.bud.used)
    got = next((m for m in of_type(take(), "chart") if (m["cx"], m["cy"]) == (-3, 3)), None)
check(got and got["n"] == 16 and sum(1 for p in got["px"] if got["pal"][p] == [204, 217, 204]) == 256,
      f"a chart read in strips still has every wall: {got and got['pal']}")
check(ticks >= 4 and max(used) <= 400, f"a 1000-entity chart takes several ticks, none over the budget: {ticks} ticks, {used}")
old_subs = [[int(c[1]), int(c[2])] for c in g.storage.f3d.subs.values()]
send({"t": "sub", "c": old_subs + [[-3, 3]]})
used, ents, head, ticks = [], [], None, 0
while not (head and len(ents) == head.get("parts", -1)) and ticks < 200:
    tick(1)
    ticks += 1
    used.append(g.storage.f3d.bud.used)
    msgs = take()
    head = next((m for m in of_type(msgs, "chunk") if (m["cx"], m["cy"]) == (-3, 3)), head)
    ents += [m for m in of_type(msgs, "ents") if (m["cx"], m["cy"]) == (-3, 3)]
records = [rec for m in ents for rec in m["e"]]
check(head and len(records) == 1000, f"a snapshot read in strips has every entity once: {len(records)} {head}")
check(max(used) <= 400, f"no tick of the snapshot over the budget: {max(used)}")
send({"t": "sub", "c": old_subs})
for e in dense:
    e.destroy()
for u, want in ((5, 50), (10 ** 9, 20000), ("x", 20000), (500, 500)):
    send({"t": "budget", "u": u})
    tick(1)
    check(g.storage.f3d.bud.limit == want, f"budget {u!r} -> {want}: {g.storage.f3d.bud.limit}")
tick(60)
wb = of_type(take(), "wb")
check(wb and wb[-1]["b"] == 500 and wb[-1]["n"] == 60 and {"chunks", "map", "reqs", "radars", "techs"} <= set(wb[-1]["q"]),
      f"wb once a second: the budget, the units used and the queues: {wb[-1:]}")
# Periodic jobs share the tick (budget.admit): one waits while the tick already holds more than
# PERIODIC budgets' worth, runs once its slack runs out, and its expected cost follows what it read.
B = g.package.loaded["scripts.budget"]
B.set(lua.table_from({"u": 300}))
B.begin()
B.commit(560, "bi")
check(not B.admit("probe", 100), "a periodic job waits when the tick is full")
check(B.admit("probe", 100, True), "and runs when its slack is out")
B.learn("probe", 200)
check(B.estimate("probe") == 200, f"its first run sets what it is expected to cost: {B.estimate('probe')}")
B.learn("probe", 100)
check(B.estimate("probe") == 170, f"and later runs move it there: {B.estimate('probe')}")
B.begin()
B.commit(100, "bi")
check(B.admit("probe", 100) and B.left() == 300, "on a light tick it runs, and the queues keep their whole budget")
B.begin()
B.commit(50, "bi")
g.storage.f3d.bud.cost["huge"] = 5000
check(B.admit("huge", 0), "a job dearer than a whole tick runs on a tick that holds little")
B.set(lua.table_from({"u": 500}))
# The movers' search while the focus moves: again after SCAN_MOVE tiles, through the budget; at once
# after a jump.
fx0, fy0, fr0 = g.storage.f3d.focus.x, g.storage.f3d.focus.y, g.storage.f3d.focus.r
def focus_at(x):
    send({"t": "focus", "x": fixed(x), "y": fixed(fy0), "r": fr0})
focus_at(fx0)
tick(20)
# Line up just after a periodic search (every SCAN_TICKS, 8), so the two ticks below can't reach the
# next one whatever tick this part starts on (a test added earlier shifted it onto one).
last = g.storage.f3d.mv_scan.tick
for _ in range(20):
    tick(1)
    if g.storage.f3d.mv_scan.tick != last:
        break
first = g.storage.f3d.mv_scan.tick
focus_at(fx0 + 1)
tick(2)
check(g.storage.f3d.mv_scan.tick == first, "a step of the focus doesn't search the movers' area again")
focus_at(fx0 + 60)
tick(3)
check(g.storage.f3d.mv_scan.tick > first and g.storage.f3d.mv_scan.x == fx0 + 60,
      f"a jump searches it at once: {g.storage.f3d.mv_scan.x} for {fx0 + 60}")
# perfbridge2: while searches keep finding the same movers the ticks between them double, up to the
# f3d-mover-rescan setting (8: every 8 ticks, as before); a search that finds anything else goes back to 8.
g.settings["global"]["f3d-mover-rescan"] = lua.table_from({"value": 32})
movers_mod = g.package.loaded["scripts.movers"]
movers_mod.reset()
every, gaps, last = [], [], None
for _ in range(140):
    tick(1)
    t = int(g.storage.f3d.mv_scan.tick)
    if t != last:
        if last is not None:
            gaps.append(t - last)
        every.append(int(g.storage.f3d.mv_scan.every))
        last = t
check(every[:4] == [8, 16, 32, 32] and gaps[:3] == [8, 16, 32] and max(gaps) <= 32,
      f"movers: searches finding the same movers come 8, 16, then 32 ticks apart (f3d-mover-rescan 32): every {every[:5]}, gaps {gaps[:5]}")
newcomer = spawn("car", fx0 + 20, fy0 + 10, force="player")
for _ in range(40):
    tick(1)
    if int(g.storage.f3d.mv_scan.tick) != last:
        break
check(int(g.storage.f3d.mv_scan.every) == 8 and any(rec[0] == newcomer.unit_number for m in of_type(take(), "mv") for rec in m["l"]),
      f"movers: a search that finds a new mover sends it and puts the searches back to every 8 ticks: {g.storage.f3d.mv_scan.every}")
newcomer.destroy()
g.settings["global"]["f3d-mover-rescan"] = lua.table_from({"value": 8})
movers_mod.reset()
last = None
every = set()
for _ in range(40):
    tick(1)
    if g.storage.f3d.mv_scan:
        every.add(int(g.storage.f3d.mv_scan.every))
check(every == {8}, f"movers: f3d-mover-rescan 8 searches every 8 ticks, as before: {every}")
# Multiplayer: what sending the movers charges the tick (budget.commit, which decides which periodic
# jobs run) is the search's count in storage, not the module-local list: a peer that loaded since
# finds its own, later, which may hold a mover more.
# (Just after a search, so the ticks below reach no other.)
last = g.storage.f3d.mv_scan.tick
for _ in range(20):
    tick(1)
    if g.storage.f3d.mv_scan.tick != last:
        break
scan_tick = g.storage.f3d.mv_scan.tick
late_cars = [spawn("car", fx0 + 62, fy0 + dy, force="player") for dy in (0, 3)]
tick(1)
while int(g.game.tick) % 2 != 1:  # the movers' ticks (rate.lua's phase 1 at a 2-tick interval)
    tick(1)
mv_host = g.storage.f3d.bud.jobs.mv
check(forget(movers_mod.tick, "scans"), "the movers' module-local list can be forgotten (a peer that loaded since)")
tick(2)
mv_joined = g.storage.f3d.bud.jobs.mv
check(g.storage.f3d.mv_scan.tick == scan_tick and mv_host == mv_joined,
      f"mv: a send is charged the same on a peer whose own list has two cars more: {mv_host} and {mv_joined}")
mv_n = g.storage.f3d.mv_scan.n
check(mv_n is not None and mv_host == math.floor(mv_n * 0.5),
      f"mv: by the search's count in storage: {mv_host} for {g.storage.f3d.mv_scan.n} movers")
for e in late_cars:
    e.destroy()
focus_at(fx0)
tick(3)
# Every job with a slack says what it read, so its cost is learned and its charge cleared: enemies,
# items on the ground and robots' cargo stayed at their first guess.
for job in ("en", "gi", "rc"):
    g.storage.f3d.bud.cost[job] = None
tick(130)
learned = {job: g.storage.f3d.bud.cost[job] for job in ("en", "gi", "rc")}
check(None not in learned.values() and not any(g.storage.f3d.bud.charged[job] for job in learned),
      f"enemies, ground items and robots' cargo learn what they cost and clear their charge: {learned}")
# The checks below count on the tick staying in step: on to a whole number of 600 ticks.
pad = -(g.game.tick - start_tick) % 600
while pad > 0:
    send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
    tick(min(pad, 100))
    pad -= min(pad, 100)
take()

# D5: a chart is kept while its chunk looks the same, and made again once something is built there.
keep = spawn("stone-wall", 28.5, 28.5, force="player")
send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 0, "cy2": 0, "res": 2})
tick(2)
take()
keep.destroy()
chest = spawn("wooden-chest", 28.5, 28.5, force="player")  # as many entities, and no event
send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 0, "cy2": 0, "res": 2})
tick(2)
kept = [m for m in of_type(take(), "chart") if (m["cx"], m["cy"]) == (0, 0)]
check(kept and kept[0]["pal"][kept[0]["px"][14 * 16 + 14]] == [204, 217, 204],
      "a chunk with as many entities and no event since is sent from its kept chart (D5)")
F["raise"]("script_raised_built", lua.table_from({"entity": chest}))
take()
send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 0, "cy2": 0, "res": 2})
tick(2)
redone = [m for m in of_type(take(), "chart") if (m["cx"], m["cy"]) == (0, 0)]
check(redone and redone[0]["pal"][redone[0]["px"][14 * 16 + 14]] != [204, 217, 204],
      "... and charted again once something is built in it")
chest.destroy()
# perfbridge2: a chart younger than map.chart_trust ticks of a chunk nothing was built, mined or destroyed in
# since (an event) is trusted: its entities aren't counted again (the count was most of a minimap refresh's
# cost). The counts live in storage.f3d_charts, forgotten by the events, so every peer slices the job alike.
counted = []
lua.execute("""
local surface = game.surfaces[1]
F.real_count = surface.count_entities_filtered
-- (Only the charts' counts, made at a chart job's first step; world.lua's snapshots count the same way.)
rawset(surface, "count_entities_filtered", function(f)
  local m = storage.f3d and storage.f3d.map
  if m and m.job and m.job.step == -1 then
    F.counted = (F.counted or 0) + 1
  end
  return F.real_count(f)
end)
""")
def map_count_calls(res=2):
    g.F.counted = 0
    send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 0, "cy2": 0, "res": res})
    tick(2)
    take()
    return int(g.F.counted)
g.storage.f3d_charts = None  # (the charts above remembered theirs)
first_count = map_count_calls()
trusted = map_count_calls()
rec = g.storage.f3d_charts and g.storage.f3d_charts[f"1,0,0,2"]
check(first_count == 1 and trusted == 0 and rec is not None and rec[3] == "player",
      f"map: a chunk's entity count is remembered in storage and trusted for a young chart: {first_count}, {trusted}, {rec and list(rec.values())}")
quiet_chest = spawn("wooden-chest", 28.5, 28.5, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": quiet_chest}))
check(g.storage.f3d_charts["1,0,0,2"] is None and map_count_calls() == 1, "map: something built in the chunk forgets the trusted count, and it is counted again")
g.package.loaded["scripts.map"].chart_trust = 0
check(map_count_calls() == 1, "map: chart_trust 0 counts every time, as before")
g.package.loaded["scripts.map"].chart_trust = 1200
quiet_chest.destroy()
lua.execute('rawset(game.surfaces[1], "count_entities_filtered", F.real_count)')

# The map view's layers ride with the chart: poles, turrets, roboports, stops, signals, robots.
layer_ents = [spawn("small-electric-pole", 20.5, 20.5, force="player"), spawn("gun-turret", 22, 22, force="player"),
              spawn("roboport", 26, 26, force="player"), spawn("train-stop", 16, 16, force="player", backer_name="Iron"),
              spawn("rail-signal", 12.5, 12.5, force="player"), spawn("construction-robot", 10.5, 10.5, force="player"),
              spawn("gun-turret", 6, 6, force="enemy"), spawn("small-electric-pole", 40.5, 20.5, force="player")]
# (The overlay's robots are the movers' last search's (perfbridge2): search again now.)
movers_mod.reset()
tick(2)
send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 0, "cy2": 0, "res": 4})
tick(2)
c00 = [m for m in of_type(take(), "chart") if (m["cx"], m["cy"]) == (0, 0)]
ov = sorted(c00[0].get("ov", []), key=lambda r: r[0]) if c00 else []
check(["e", fixed(20.5), fixed(20.5), 2.5] in ov, f"a pole comes with its supply radius: {ov}")
check(["t", fixed(22), fixed(22), 18] in ov, "a turret with its range")
check(["l", fixed(26), fixed(26), 25, 55] in ov, "a roboport with its logistic and construction radius")
check(["s", fixed(16), fixed(16), "Iron"] in ov, "a train stop with its name")
check(["g", fixed(12.5), fixed(12.5), 1] in ov, "a rail signal with its state")
check(["b", fixed(10.5), fixed(10.5)] in ov, "a worker robot")
check(len(ov) == 6, "nothing of other forces, nothing from the next chunk")
# Owner's C10: the copper wires between poles, each once.
wired = spawn("small-electric-pole", 25.5, 20.5, force="player")
# (Built: its event forgets the chunk's chart and trusted count, as in the game; the fake's spawn is silent.)
F["raise"]("script_raised_built", lua.table_from({"entity": wired}))
layer_ents[0].get_wire_connector(5, True).connect_to(wired.get_wire_connector(5, True))
send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 0, "cy2": 0, "res": 4})
tick(2)
c00 = [m for m in of_type(take(), "chart") if (m["cx"], m["cy"]) == (0, 0)]
wires = [r for r in (c00[0].get("ov", []) if c00 else []) if r[0] == "w"]
check(wires == [["w", fixed(20.5), fixed(20.5), fixed(25.5), fixed(20.5)]], f"a copper wire between two poles, once (C10): {wires}")
layer_ents.append(wired)
for e in layer_ents:
    e.destroy()

# Owner's C12: a chart carries its chunk's pollution.
F.pollution = lua.eval('{["0,0"] = 1234.4}')
send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 1, "cy2": 0, "res": 32})
tick(2)
pols = {(m["cx"], m["cy"]): m.get("pol") for m in of_type(take(), "chart")}
check(pols.get((0, 0)) == 1234 and pols.get((1, 0)) is None, f"charts carry their chunk's pollution (pol), none where there is none: {pols}")
F.pollution = lua.eval("{}")

# Owner's I15: the chunks' pollution round the focus, every 300 ticks (pollution.lua), for trees, lakes and smog.
pol_focus = g.storage.f3d.focus
pol_cx, pol_cy = math.floor(pol_focus.x / 32), math.floor(pol_focus.y / 32)
F.pollution = lua.eval('{["%d,%d"] = 250.4, ["%d,%d"] = 12}' % (pol_cx, pol_cy, pol_cx + 1, pol_cy))
take()


def pol_wait():
    # 600 ticks, saying hello as the padding above does, so the client isn't timed out meanwhile.
    for _ in range(6):
        send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
        tick(100)


pol_wait()
pol = of_type(take(), "pol")
pol_w = pol[-1]["w"] if pol else 0
pol_n = (pol_w - 1) // 2
pol_l = pol[-1]["l"] if pol and pol_w > 0 else []
check(pol and pol_w > 0 and pol[-1]["cx"] == pol_cx - pol_n and pol[-1]["cy"] == pol_cy - pol_n and pol[-1]["md"] == 60
      and pol_l[pol_n * pol_w + pol_n] == 250 and pol_l[pol_n * pol_w + pol_n + 1] == 12 and sum(pol_l) == 262,
      f"pol: the chunks' pollution round the focus, row by row, with the tree damage threshold: {pol[-1:]}")
F.pollution = lua.eval("{}")
pol_wait()
pol = of_type(take(), "pol")
check(pol and pol[-1]["w"] == 0 and "l" not in pol[-1], f"pol: none left round the focus sends an empty square: {pol[-1:]}")

# Owner's #4: Vulcanus' demolisher territories, as their chunks, so the client draws the red borders.
F.territories = lua.eval("{{{x = 1, y = 2}, {x = 2, y = 2}}, {{x = -5, y = 0}}}")
g.package.loaded["scripts.planets"].territories_soon()
tick(1)
terr = of_type(take(), "terr")
check(terr and terr[-1]["parts"] == 1 and terr[-1]["l"] == [[1, 2, 2, 2], [-5, 0]] and terr[-1].get("si") == 1,
      f"terr: every territory's chunks, with the surface they are on (G20): {terr[-1:]}")
# I16: a territory whose demolisher was killed is cleared: left out, and counted in `c`.
F.cleared_territories = lua.eval("{[1] = true}")
g.package.loaded["scripts.planets"].territories_soon()
tick(1)
terr = of_type(take(), "terr")
check(terr and terr[-1]["l"] == [[-5, 0]] and terr[-1].get("c") == 1,
      f"terr leaves out a territory whose demolisher is dead, so its border goes (I16): {terr[-1:]}")
F.cleared_territories = lua.eval("{}")
F.territories = lua.eval("{}")
g.package.loaded["scripts.planets"].territories_soon()
tick(1)
terr = of_type(take(), "terr")
check(terr and terr[-1]["l"] == [], "a surface without territories sends an empty list (it clears them)")

# Owner's #22: right-click on the map removes the ghost there (and says so), else nothing.
map_ghost = spawn("entity-ghost", 7.5, 6.5, inner_name="wooden-chest", force="player")
gu = map_ghost.unit_number
send({"t": "unghost", "q": 7, "x": fixed(7.6), "y": fixed(6.4)})
tick(1)
msgs = take()
check(not map_ghost.valid and [m["n"] for m in of_type(msgs, "unghost")] == [1] and any(d["u"] == gu for d in of_type(msgs, "del")),
      f"unghost removes the ghost under the click and sends its del: {of_type(msgs, 'unghost')}")
send({"t": "unghost", "q": 8, "x": fixed(30.5), "y": fixed(30.5)})
tick(1)
check([(m["q"], m["n"]) for m in of_type(take(), "unghost")] == [(8, 0)], "no ghost there: n = 0, so the client adds a tag")
send({"t": "tag_add", "x": 5 * 256, "y": 6 * 256, "text": "base", "icon": ["item", "iron-plate"]})
tick(1)
tags = of_type(take(), "tags")
check(tags and tags[-1]["l"] == [[1, 5 * 256, 6 * 256, "base", "item", "iron-plate"]], f"tag_add puts a tag on the map: {tags[-1:]}")
send({"t": "tag_add", "x": 50 * 256, "y": 0, "text": "far"})
tick(1)
check(any("Can't put a tag there" in m["text"] for m in of_type(take(), "msg")), "a tag where the map isn't charted is refused")
F["raise"]("on_chart_tag_modified", lua.table_from({}))
tick(1)
check(of_type(take(), "tags"), "the tags are sent again when they change in the game")
send({"t": "tag_del", "id": 1})
tick(1)
tags = of_type(take(), "tags")
check(tags and tags[-1]["l"] in ([], {}), "tag_del removes it")

px, py = g.storage.f3d.puppet.position.x, g.storage.f3d.puppet.position.y
F.chart_requests = lua.table_from([])
tick(121)
take()
reqs = list(F.chart_requests.values())
check(reqs and reqs[0][1][1] + 96 == px and reqs[0][2][2] - 96 == py,
      "the force charts around a player-less character every 2 seconds")
# A headless server with nobody connected never carries those requests out: the chunks the
# character was near count as charted anyway.
send({"t": "map", "cx1": 1, "cy1": 0, "cx2": 1, "cy2": 0, "res": 32})
tick(1)
c10 = [m for m in of_type(take(), "chart") if (m["cx"], m["cy"]) == (1, 0)]
check(c10 and c10[0]["n"] == 1 and not F.charted["1,0"],
      f"a chunk the character has been near is charted even if the game never charted it: {c10}")
# The map's surface switcher: the surfaces it can show, and charts of a surface by index.
g.storage.f3d.surfs_sig = None
tick(1)
while g.game.tick % 300:
    tick(1)
tick(1)
surfs = of_type(take(), "surfs")
check(surfs and [1, "nauvis", "nauvis", "", 0] in surfs[-1]["l"], f"the surfaces the map can show are sent when they change: {surfs}")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})  # keep-alive: the waits above add up past the timeout
other = F.make_surface(50, "f3d-other")
g.storage.f3d.surfs_sig = None
tick(1)
while g.game.tick % 300:
    tick(1)
tick(1)
surfs = of_type(take(), "surfs")
check(surfs and surfs[-1]["l"][-1] == [50, "f3d-other", "", "", 0], f"a surface that is no planet nor platform comes last (Factorio's Other): {surfs[-1:]}")
F.game_surfaces[50] = None
send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 0, "cy2": 0, "res": 32, "si": 1})
tick(2)
msgs = take()
c00 = [m for m in of_type(msgs, "chart") if (m["cx"], m["cy"]) == (0, 0)]
check(c00 and c00[0]["si"] == 1 and of_type(msgs, "tags") and of_type(msgs, "tags")[-1]["si"] == 1,
      "a map request names its surface (si), and its charts and tags say which surface they are")
send({"t": "map", "cx1": 0, "cy1": 0, "cx2": 0, "cy2": 0, "res": 32, "si": 99})
tick(2)
c00 = [m for m in of_type(take(), "chart") if (m["cx"], m["cy"]) == (0, 0)]
check(c00 and c00[0]["si"] == 1, "an unknown surface falls back to the character's")
# Remote building: ghosts only where the map is charted, as in the game.
send({"t": "build", "item": "assembling-machine-1", "x": 5000 * 256, "y": 5000 * 256, "d": 0, "ghost": 1})
tick(1)
msgs = take()
check(any("uncharted" in m["text"] for m in of_type(msgs, "msg")), "a ghost far away on uncharted ground is refused")

# --- trains: stops, train state, schedules, wagons --------------------------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
take()
px, py = g.storage.f3d.puppet.position.x, g.storage.f3d.puppet.position.y
stop = spawn("train-stop", px + 3, py + 3, force="player", backer_name="Iron")
stop.color = lua.table_from({"r": 1, "g": 0.5, "b": 0, "a": 1})
F["raise"]("script_raised_built", lua.table_from({"entity": stop}))
tick(1)
adds = [m["e"] for m in of_type(take(), "add") if m["e"][0] == stop.unit_number]
check(adds and adds[0][5].get("n") == "Iron", f"a train stop's record has its name: {adds}")
check(adds and adds[0][5].get("col") == [255, 128, 0], f"and the colour given to it, 0-255 (H21): {adds}")
stop.color = lua.table_from({"r": 0, "g": 0, "b": 1, "a": 1})
F["raise"]("on_entity_color_changed", lua.table_from({"entity": stop}))
tick(1)
upds = [m["e"] for m in of_type(take(), "upd") if m["e"][0] == stop.unit_number]
check(upds and upds[0][5].get("col") == [0, 0, 255], f"a repainted stop sends its new colour (H21): {upds}")
loco2 = spawn("locomotive", px + 6, py + 1, force="player")
wagon = spawn("cargo-wagon", px + 6, py + 8, force="player")
rail = spawn("straight-rail", px + 20, py, force="player")
train = F.couple(loco2, wagon)
td = F.train_data[train]
td.state = g.defines.train_state.wait_station
td.station = stop
td.path_end_stop = stop
td.speed = 0.25
tick(31)  # trains are looked at once every 30 ticks, on a phase of their own
tr = [r for m in of_type(take(), "tr") for r in m["l"] if r[0] == train.id]
check(tr and tr[-1] == [train.id, "wait_station", 0, 250, stop.unit_number, "Iron", [loco2.unit_number, wagon.unit_number]],
      f"tr: a train's state, speed, stop, destination and carriages: {tr[-1:]}")

# D11: the map draws trains live; the client asks with `mtr` while a map is open.
send({"t": "mtr"})
tick(1)
mtr = of_type(take(), "mtr")
cars = mtr[-1]["l"] if mtr else []
check(mtr and mtr[-1]["parts"] == 1 and len(cars) == 12 and cars[0] == fixed(px + 6) and cars[1] == fixed(py + 1)
      and cars[3] > cars[4] > 0 and cars[5] == 0xEB1200 and cars[11] == 0x9A9A9A,
      f"mtr: each carriage's place, turn, size and map colour: {mtr[-1:]}")
send({"t": "mtr"})
tick(1)
check(not of_type(take(), "mtr"), "mtr: asks closer together than a third of a second are ignored")
# D12: only what radars (or the character) see: a train far away shows once a radar covers it, and
# the first part lists the working radars (cov) so the map dims the rest.
far_loco = spawn("locomotive", px + 400, py + 1, force="player")
tick(25)
send({"t": "mtr"})
tick(1)
m1 = of_type(take(), "mtr")
far_radar = spawn("radar", px + 420, py + 20, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": far_radar}))
tick(301)
send({"t": "mtr"})
tick(1)
m2 = of_type(take(), "mtr")
fx_far = fixed(px + 400)
check(m1 and fx_far not in m1[-1]["l"][0::6] and m1[-1].get("cov") in ([], {}),
      f"mtr: a train no radar covers isn't sent, and no radars means an empty cov: {m1[-1:]}")
rcx, rcy = math.floor((px + 420) / 32), math.floor((py + 20) / 32)
check(m2 and fx_far in m2[-1]["l"][0::6] and m2[-1].get("cov") == [rcx, rcy, 3],
      f"mtr: a working radar's chunks show their trains, and cov lists it: {m2[-1:]}")
# H13: the map's logistic layer shows every roboport on the surface (`mrp`), read from the force's
# logistic networks' cells rather than the charts the client loaded; a personal roboport's cell isn't one.
rp_near = spawn("roboport", px + 30, py + 30, force="player")
rp_far = spawn("roboport", px + 900, py - 700, force="player")
F.lnets = lua.table_from({"nauvis": lua.table_from([
    F.make_network(3, lua.table_from([0, 0, 0, 0]), lua.table(),
                   lua.table_from([F.make_cell(rp_near, 25, 55), F.make_cell(rp_far, 25, 55)])),
    F.make_network(4, lua.table_from([0, 0, 0, 0]), lua.table(), lua.table_from([F.make_cell(far_loco, 0, 10)]))])})
send({"t": "mrp", "q": 5})
tick(2)
rp = of_type(take(), "mrp")
check(rp and rp[-1].get("last") == 1 and rp[-1].get("q") == 5 and rp[-1].get("si") == 1
      and rp[-1].get("l") == [fixed(px + 30), fixed(py + 30), fixed(25), fixed(55), fixed(px + 900), fixed(py - 700), fixed(25), fixed(55)],
      f"mrp: every roboport of the surface's networks with its logistic and construction radius: {rp[-1:]}")
send({"t": "mrp", "q": 6})
tick(2)
check(not of_type(take(), "mrp"), "mrp: asks within a second for the same surface are ignored")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})  # keep-alive: the waits here add up past the timeout
# Ground in a roboport's construction area counts as seen, like a radar's (H13): the map's trains
# there, the remote view's movers and buildings to open; a mobile cell (a personal roboport) doesn't.
# Chunks are seen by their centres: these are chunk centres inside (in_x, in_x2) and past (out_x) the
# far roboport's construction square (55 tiles round px + 900, py - 700).
rx, ry = px + 900, py - 700
mid_y = math.floor(ry / 32) * 32 + 16
in_x, in_x2 = math.floor((rx + 30) / 32) * 32 + 16, math.floor((rx - 30) / 32) * 32 + 16
out_x = math.floor((rx + 90) / 32) * 32 + 16
rp_loco = spawn("locomotive", rx, ry + 10, force="player")
mobile_car = spawn("car", px - 900, py + 700, force="player")
mobile_loco = spawn("locomotive", px - 900, py + 690, force="player")
F.lnets["nauvis"][3] = F.make_network(5, lua.table_from([0, 0, 0, 0]), lua.table(),
                                      lua.table_from([F.make_cell(mobile_car, 15, 30)]))
tick(21)
send({"t": "mtr"})
tick(1)
mt = of_type(take(), "mtr")
mt_x = mt[-1]["l"][0::6] if mt else []
check(mt and fixed(rx) in mt_x and fixed(px - 900) not in mt_x,
      f"mtr: a train in a roboport's construction area is shown, one by a personal roboport isn't: {mt_x}")
rp_asm = spawn("assembling-machine-1", in_x + 0.5, mid_y + 0.5, force="player")
far_asm2 = spawn("assembling-machine-1", out_x + 0.5, mid_y + 0.5, force="player")
send(dict(open_cmd(rp_asm), rv=1))
tick(2)
check(bool(guis(take(), rp_asm)), "rv: a building in a roboport's construction area opens from the remote view (D10)")
send(dict(open_cmd(far_asm2), rv=1))
tick(2)
check(not guis(take(), far_asm2), "rv: one past the construction area doesn't")
send({"t": "close"})
rp_car = spawn("car", in_x2, mid_y)
past_car = spawn("car", out_x, mid_y)
send({"t": "focus", "x": fixed(rx), "y": fixed(ry), "r": 128, "rv": 1})
tick(61)
rp_units = {rec[0] for rec in decode_records(last_frame(take(), "mv"))}
check(rp_car.unit_number in rp_units and past_car.unit_number not in rp_units,
      f"remote view: a mover in a roboport's construction area is sent, one past it isn't: {sorted(rp_units)}")
send({"t": "focus", "x": fixed(px), "y": fixed(py), "r": 32})
tick(2)
take()
for e in (rp_loco, mobile_car, mobile_loco, rp_asm, far_asm2, rp_car, past_car):
    e.destroy()
tick(91)  # 180 ticks in all here: the checks further on wait for ticks on a phase of their own
F.lnets = lua.table()
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})  # keep-alive
send({"t": "mrp", "q": 7})
tick(2)
rp = of_type(take(), "mrp")
check(rp and rp[-1].get("q") == 7 and rp[-1].get("last") == 1 and rp[-1].get("l") in ([], {}),
      f"mrp: no networks, an empty last part: {rp[-1:]}")
# H23: switching the map to a planet centres on the force's landing pad there (`lpad`).
pad = spawn("cargo-landing-pad", px + 60, py - 40, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": pad}))
send({"t": "lpad", "si": 1, "q": 11})
tick(2)
lp = of_type(take(), "lpad")
check(lp and lp[-1].get("q") == 11 and lp[-1].get("si") == 1 and lp[-1].get("x") == fixed(px + 60) and lp[-1].get("y") == fixed(py - 40),
      f"lpad: the landing pad's position on that surface: {lp[-1:]}")
send({"t": "lpad", "si": 999, "q": 12})
tick(2)
lp = of_type(take(), "lpad")
check(lp and lp[-1].get("q") == 12 and "x" not in lp[-1], f"lpad: no such surface, no position: {lp[-1:]}")
pad.destroy()
# The 3D remote view (focus rv = 1) sends moving things only where radars or the character see,
# and `cov` about once a second; the normal view sends everything.
seen_car = spawn("car", px + 450, py + 30)  # the radar at px + 420 reveals 3 chunks round its own
unseen_car = spawn("car", px + 555, py + 30)
send({"t": "focus", "x": fixed(px + 500), "y": fixed(py), "r": 64, "rv": 1})
tick(61)
rv_msgs = take()
rv_units = {rec[0] for rec in decode_records(last_frame(rv_msgs, "mv"))}
covs = of_type(rv_msgs, "cov")
check(seen_car.unit_number in rv_units and unseen_car.unit_number not in rv_units,
      f"remote view: a mover a radar sees is sent, one no radar sees isn't: {sorted(rv_units)}")
check(covs and covs[-1]["l"] == [rcx, rcy, 3] and covs[-1]["x"] == fixed(px) and covs[-1]["cr"] == 96 and covs[-1]["si"] == 1,
      f"remote view: cov lists the radars and the character's place and radius: {covs[-1:]}")
# Multiplayer: the filter keeps radars' statuses a second (module-local), which suits what is sent;
# belt items' rounds keep the belts they found in storage, so they ask for the game as it is now.
map_mod = g.package.loaded["scripts.map"]
rv_belt = spawn("transport-belt", px + 505.5, py + 0.5, force="player", direction=4)
F.put_on_belt(rv_belt, 1, "iron-plate", 0.5, 6101)


def bi_uids(msgs):
    out = set()
    for m in of_type(msgs, "bi"):
        l, prev = m["l"], [0, 0, 0, 0]
        for i in range(0, len(l), 4):
            prev = [a + b for a, b in zip(prev, l[i:i + 4])] if m.get("z") else l[i:i + 4]
            out.add(prev[0])
    return out


tick(30)
before_off = bi_uids(take())
far_radar.status = g.defines.entity_status.no_power
tick(1)
exact_now = map_mod.view_filter(True)(px + 505, py)
tick(18)
off_msgs = take()
last_k = max((m["k"] for m in of_type(off_msgs, "bi")), default=None)
# (The first update after carries an item it no longer reads on once, where it would be.)
after_off = bi_uids([m for m in off_msgs if m.get("k") == last_k])
far_radar.status = g.defines.entity_status.working
check(6101 in before_off and exact_now is False and last_k is not None and 6101 not in after_off,
      f"remote view: belt items' rounds follow the radar's status as it is now (exact filter): before {6101 in before_off}, "
      f"exact {exact_now}, after {6101 in after_off}")
rv_belt.destroy()
send({"t": "focus", "x": fixed(px + 500), "y": fixed(py), "r": 64})
tick(61)
plain_msgs = take()
plain_units = {rec[0] for rec in decode_records(last_frame(plain_msgs, "mv"))}
check({seen_car.unit_number, unseen_car.unit_number} <= plain_units and not of_type(plain_msgs, "cov"),
      f"outside the remote view every mover is sent and no cov: {sorted(plain_units)}")
send({"t": "focus", "x": fixed(px), "y": fixed(py), "r": 32, "rv": 1})
tick(4)
near_units = {rec[0] for rec in decode_records(last_frame(take(), "mv"))}
check({loco2.unit_number, wagon.unit_number} <= near_units,
      f"remote view round the character: nothing is left out (the train beside it): {sorted(near_units)}")
send({"t": "focus", "x": fixed(px), "y": fixed(py), "r": 32})
seen_car.destroy()
unseen_car.destroy()
far_loco.destroy()
# The radars' coverage is read where a module-local cache decides (radar_coverage), so reading it
# leaves storage alone: a gone radar stays listed until M.tick prunes the lists on a tick of its own
# (checked at the end). A peer joining mid-game, its cache empty, would otherwise change storage.
far_radar_unit = far_radar.unit_number
far_radar.destroy()
radar_list = g.storage.f3d_radars[1].list
g.package.loaded["scripts.map"].covered(puppet.surface, puppet.force, lua.table_from({"x": px + 420, "y": py + 20}))
check(radar_list[far_radar_unit] is not None, "reading the radars' coverage leaves a gone radar in storage")

send(open_cmd(loco2))
tick(2)
gui = guis(take(), loco2)
check(gui and gui[-1]["kind"] == "train" and gui[-1]["tr"]["id"] == train.id and gui[-1]["tr"]["station"] == "Iron"
      and gui[-1]["tr"]["sched"]["records"] in ([], {}), f"a locomotive opens as a train with an empty schedule: {gui[-1:]}")
records = [{"station": "Iron", "wait_conditions": [{"type": "time", "compare_type": "or", "ticks": 300}]},
           {"rail": [fixed(px + 20), fixed(py)], "temporary": True}]
send({"t": "set_schedule", "u": loco2.unit_number, "records": records})
send({"t": "train_go", "u": loco2.unit_number, "i": 2})
send({"t": "train_mode", "u": loco2.unit_number, "auto": 0})
tick(2)
gui = guis(take(), loco2)
sched = gui[-1]["tr"]["sched"] if gui else {}
check(sched.get("records") == records and sched.get("current") == 2,
      f"set_schedule and train_go: records (a temporary stop's rail as a position) and the current one: {sched}")
check(train.manual_mode is True and gui[-1]["tr"]["manual"] == 1, "train_mode 0 is manual")
send({"t": "train_mode", "u": loco2.unit_number, "auto": 1})
send({"t": "set_schedule", "u": loco2.unit_number, "records": [{"wait_conditions": []}]})
send({"t": "set_stop", "u": loco2.unit_number, "name": "x"})
tick(2)
said = texts(take())
check(train.manual_mode is False, "train_mode 1 is automatic")
interrupts = [{"name": "Refuel", "conditions": [{"type": "fuel_item_count_any", "compare_type": "and",
               "condition": {"first_signal": {"type": "item", "name": "coal"}, "comparator": "<", "constant": 5}}],
               "targets": [{"station": "Iron", "wait_conditions": [{"type": "inactivity", "compare_type": "and", "ticks": 120}]}],
               "inside_interrupt": False}]
send({"t": "set_interrupts", "u": loco2.unit_number, "interrupts": interrupts})
send({"t": "train_temp", "u": loco2.unit_number, "station": "Iron"})
tick(2)
gui = guis(take(), loco2)
tri = gui[-1]["tr"] if gui else {}
sched = tri.get("sched", {})
check(sched.get("interrupts") == interrupts, f"set_interrupts: the interrupts come back in the same shape: {sched.get('interrupts')}")
check(len(sched.get("records", [])) == 3 and sched["records"][sched["current"] - 1].get("temporary") is True
      and sched["records"][sched["current"] - 1]["station"] == "Iron", f"train_temp: a temporary stop after the current one, and it goes there: {sched}")
check(tri.get("stops") == ["Iron"] and tri.get("pos") == [fixed(loco2.position.x), fixed(loco2.position.y)] and tri.get("fuel") in ([], {}),
      f"a train's screen lists the force's stops, the front's position and the fuel: {tri}")
send({"t": "trains_list"})
tick(1)
got = take()
trl = [r for m in of_type(got, "trl") for r in m["l"]]
mine = [r for r in trl if r[0] == train.id]
check(mine and mine[0][3] == "Iron" and mine[0][5] == 2 and mine[0][6] == loco2.unit_number, f"trains_list: every train of the force (trl): {trl}")
send({"t": "train_mode_id", "id": train.id, "auto": 0})
tick(1)
check(train.manual_mode is True and of_type(take(), "trl"), "train_mode_id switches a train from the overview")
# Inputs: a burst of switches lists the trains once (queued as trains_list), not once a packet.
for i in range(40):
    send({"t": "train_mode_id", "id": train.id, "auto": i % 2})
tick(1)
lists = [m for m in of_type(take(), "trl") if m["part"] == 1]
check(len(lists) == 1, f"inputs: 40 train_mode_id in a tick answer with one trains overview, not 40: {len(lists)}")
# Train groups: "Change train group" joins one (gc: trains in it, groups: the force's), Ctrl renames them all.
other = spawn("locomotive", px - 30, py + 30, force="player")
other.train.group = "Copper"
send({"t": "set_train_group", "u": loco2.unit_number, "g": "Copper"})
tick(2)
gui = guis(take(), loco2)
tri = gui[-1]["tr"] if gui else {}
check(train.group == "Copper" and tri.get("sched", {}).get("group") == "Copper" and tri.get("gc") == 2 and ["Copper", 2] in tri.get("groups", []),
      f"set_train_group: the train joins the group; gc counts its trains: {tri.get('gc')} {tri.get('groups')}")
send({"t": "set_train_group", "u": loco2.unit_number, "g": "Copper ore", "all": 1})
tick(2)
gui = guis(take(), loco2)
tri = gui[-1]["tr"] if gui else {}
check(train.group == "Copper ore" and other.train.group == "Copper ore" and ["Copper ore", 2] in tri.get("groups", [])
      and not any(g[0] == "Copper" for g in tri.get("groups", [])),
      f"and with all 1 renames the whole group: {tri.get('groups')}")
send({"t": "set_train_group", "u": loco2.unit_number, "g": ""})
tick(2)
gui = guis(take(), loco2)
check(train.group == "" and gui and gui[-1]["tr"].get("gc") is None, "an empty name leaves the group")
other.destroy()
send({"t": "train_mode_id", "id": train.id, "auto": 1})
tick(1)
take()
check(any(t.startswith("Can't set the schedule") for t in said) and "That isn't a train stop" in said,
      f"a bad schedule and a stop command on a train are refused: {said}")

F.inventories[wagon].cargo.insert(lua.table_from({"name": "iron-plate", "count": 80}))
send(open_cmd(wagon))
tick(2)
gui = guis(take(), wagon)
check(gui and gui[-1]["kind"] == "train" and gui[-1]["inv"].get("cargo") == [["iron-plate", 80]] and len(gui[-1]["slots"]["cargo"]) == 40,
      f"a cargo wagon shows its cargo: {gui[-1:]}")
check(gui and gui[-1]["tr"].get("cargo") == [["iron-plate", 80]], "and the whole train's cargo")

send(open_cmd(stop))
tick(2)
gui = guis(take(), stop)
st = gui[-1]["stop"] if gui else {}
check(gui and gui[-1]["kind"] == "stop" and st.get("name") == "Iron" and st.get("limit") == -1 and st.get("count") == 0
      and st.get("pri") == 50 and st.get("cb", {}).get("wired") == 0 and st.get("cb", {}).get("send") == 1, f"a train stop's screen (send to train is on by default): {gui[-1:]}")
send({"t": "set_stop", "u": stop.unit_number, "pri": 80, "cb": {"en": 1, "cond": {"first_signal": {"type": "item", "name": "iron-plate"},
      "comparator": ">", "constant": 10}, "limit": 1, "limit_sig": {"type": "virtual", "name": "signal-L"}, "read": 1}})
tick(2)
st = guis(take(), stop)[-1]["stop"]
cb = st["cb"]
check(stop.train_stop_priority == 80 and st["pri"] == 80 and cb["en"] == 1 and cb["cond"]["constant"] == 10
      and cb["cond"]["first_signal"]["name"] == "iron-plate" and cb["limit"] == 1 and cb["limit_sig"]["name"] == "signal-L" and cb["read"] == 1,
      f"set_stop sets the priority and the circuit settings: {st}")
send({"t": "set_stop", "u": stop.unit_number, "name": "Copper", "limit": 2})
tick(2)
msgs = take()
gui = guis(msgs, stop)
upds = [m["e"] for m in of_type(msgs, "upd") if m["e"][0] == stop.unit_number]
check(stop.backer_name == "Copper" and stop.trains_limit == 2 and gui and gui[-1]["stop"]["limit"] == 2, "set_stop renames and limits")
check(upds and upds[-1][5].get("n") == "Copper", "and the stop's record follows")
send({"t": "set_stop", "u": stop.unit_number, "limit": -1})
tick(2)
check(stop.trains_limit is None, "limit -1 removes the limit")
stop.trains_limit = 4294967295  # how 2.1 reads a stop without a limit
tick(31)
gui = guis(take(), stop)
check(gui and gui[-1]["stop"]["limit"] == -1, f"2.1's no-limit value (uint32 max) is sent as -1: {gui[-1:]}")
stop.trains_limit = None
F["raise"]("on_entity_renamed", lua.table_from({"entity": stop}))
tick(1)
check([m for m in of_type(take(), "upd") if m["e"][0] == stop.unit_number], "a rename in the game updates the record")
send({"t": "close"})
for e in (stop, loco2, wagon, rail):
    e.destroy()
tick(2)
take()

# --- network data: pipe connections, unplugged machines, heat, wires added later --------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
take()
p1 = spawn("pipe", 20.5, 25.5, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": p1}))
p2 = spawn("pipe", 21.5, 25.5, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": p2}))
tick(1)
msgs = take()
p2_add = [m["e"] for m in of_type(msgs, "add") if m["e"][0] == p2.unit_number]
p1_upd = [m["e"] for m in of_type(msgs, "upd") if m["e"][0] == p1.unit_number]
check(p2_add and p2_add[0][5].get("pc") == 8, f"a pipe's record says which sides connect (8 = west): {p2_add}")
check(p1_upd and p1_upd[-1][5].get("pc") == 2, f"building a pipe updates the pipe it joins (2 = east): {p1_upd}")
F["raise"]("script_raised_destroy", lua.table_from({"entity": p2}))
p2.destroy()
tick(2)
p1_upd = [m["e"] for m in of_type(take(), "upd") if m["e"][0] == p1.unit_number]
check(p1_upd and p1_upd[-1][5].get("pc") == 0, f"and removing it updates it again: {p1_upd}")

lamp2 = spawn("small-lamp", 22.5, 27.5, force="player")
lamp2.status = g.defines.entity_status.not_plugged_in_electric_network
# 2.1 says no_power for a consumer out of reach of every pole; it has no electric network then.
lamp3 = spawn("small-lamp", 21.5, 27.5, force="player")
lamp3.status = g.defines.entity_status.no_power
lamp3.electric_network_id = None
hot = spawn("heat-pipe", 12.5, 12.5, force="player", temperature=512.4)
# (The whole square's look every half second, as before the 0.2.1 hotfix: /f3d-perf wire_strips off. The
# strips are checked at the end.)
g.storage.f3d_perf = lua.table_from({"wire_strips": False})
pa = spawn("small-electric-pole", 24.5, 28.5, force="player")
pb = spawn("small-electric-pole", 27.5, 28.5, force="player")
for e in (pa, pb):
    F["raise"]("script_raised_built", lua.table_from({"entity": e}))
tick(1)
take()
while g.game.tick % 60:
    tick(1)
msgs = take()
pw = [v for m in of_type(msgs, "pw") for v in m["l"]]
check([lamp2.unit_number, 2] in [pw[i:i + 2] for i in range(0, len(pw), 2)], f"pw: 2 for a machine not connected to any pole: {pw}")
check([lamp3.unit_number, 2] in [pw[i:i + 2] for i in range(0, len(pw), 2)], f"pw: 2 for no_power without an electric network (2.1): {pw}")
ht = [v for m in of_type(msgs, "ht") for v in m["l"]]
check(ht == [hot.unit_number, 512], f"ht: a heat pipe's temperature: {ht}")
F.connect(pa, pb, g.defines.wire_type.copper)
tick(31)
upds = {m["e"][0]: m["e"] for m in of_type(take(), "upd")}
check(upds.get(pa.unit_number, [0] * 6)[5].get("w") == [pb.unit_number] and pb.unit_number in upds,
      f"a wire added between two existing poles updates both within half a second: {upds}")
g.storage.f3d_perf = None
for e in (p1, lamp2, lamp3, hot, pa, pb):
    e.destroy()
tick(2)
take()

# --- Factorio's world controls and entity windows (ui_actions.lua, entity_ui.lua) -------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
take()
puppet.position = lua.table_from({"x": 0, "y": 0})
inv = puppet.get_main_inventory()

# Drop (Z): one item into the chest under the mouse, else onto the ground.
# (Clear of the car at 3, 3, which a drop over it would fill.)
box_chest = spawn("wooden-chest", 0.5, 6.5, force="player")
puppet.insert(lua.table_from({"name": "iron-plate", "count": 10}))
plates = inv.get_item_count("iron-plate")
send({"t": "drop", "item": "iron-plate", "x": fixed(0.5), "y": fixed(6.5)})
tick(2)
check(F.inventories[box_chest]["chest"].get_item_count("iron-plate") == 1 and inv.get_item_count("iron-plate") == plates - 1,
      "Z over a chest puts one item in it")
spilled = len(F.spilled)
send({"t": "drop", "item": "iron-plate", "x": fixed(5.5), "y": fixed(-1.5)})
tick(2)
check(len(F.spilled) == spilled + 1 and inv.get_item_count("iron-plate") == plates - 2, "Z over nothing drops it on the ground")
send({"t": "drop", "item": "iron-plate", "x": fixed(40), "y": 0})
tick(2)
check(any(m["text"] == "Out of reach" for m in of_type(take(), "msg")), "dropping beyond the drop distance is refused")

# Fast transfer (Ctrl+click): a stack in, everything out; half with right click.
def target_of(e):
    return {"u": e.unit_number, "p": eid[e.name], "x": fixed(e.position.x), "y": fixed(e.position.y)}

have = inv.get_item_count("iron-plate")
send({"t": "fast", **target_of(box_chest), "item": "iron-plate", "half": 1})
tick(2)
check(F.inventories[box_chest]["chest"].get_item_count("iron-plate") == 1 + math.ceil(min(have, 100) / 2),
      "Ctrl+right click puts half of a stack in")
send({"t": "fast", **target_of(box_chest), "half": 0})
tick(2)
check(F.inventories[box_chest]["chest"].get_item_count("iron-plate") == 0 and inv.get_item_count("iron-plate") == plates - 1,
      "Ctrl+click with nothing held takes everything out")
take()
have = inv.get_item_count("iron-plate")
send({"t": "fast", **target_of(box_chest), "item": "iron-plate", "n": 5, "hs": 1, "half": 0})
tick(1)
check(F.inventories[box_chest]["chest"].get_item_count("iron-plate") == 5 and inv.get_item_count("iron-plate") == have - 5,
      "Ctrl+click with the held stack's slot (hs) puts that many in, taken from the inventory")
check(len(of_type(take(), "slots")) >= 1, "a Ctrl+click sends the slots at once (the client's hand follows them)")
send({"t": "fast", **target_of(box_chest), "half": 0})
tick(2)

# L7: Factorio builds out of the cursor's stack. The client names the main inventory slot its hand holds the
# item from (`hs`), and that stack pays for a build or a Z, in its own quality; without `hs`, as before (any
# stack of the item: the fake's remove takes the last).
set_slot = lua.eval("function(inv, i, name, count, quality) inv[i].set_stack(name and { name = name, count = count, quality = quality } or nil) end")
slot_now = lua.eval("function(inv, i) local s = inv[i]; if s.valid_for_read then return s.count end return 0 end")
inv_size = lua.eval("function(inv) return #inv end")(inv)
hs_a, hs_b, hs_c = inv_size - 2, inv_size - 1, inv_size
set_slot(inv, hs_a, "wooden-chest", 3, None)
set_slot(inv, hs_b, "wooden-chest", 5, None)
set_slot(inv, hs_c, "wooden-chest", 4, "rare")
def chest_stacks():
    return [slot_now(inv, hs_a), slot_now(inv, hs_b), slot_now(inv, hs_c)]
def chest_at(x, y):
    found = list(puppet.surface.find_entities_filtered(lua.table_from({"name": "wooden-chest", "position": lua.table_from({"x": x, "y": y})})).values())
    return found[0] if found else None
take()
for k in range(3):
    send({"t": "build", "item": "wooden-chest", "x": fixed(-3.5 - k), "y": fixed(3.5), "d": 0, "hs": hs_a})
tick(2)
built_hs = [chest_at(-3.5 - k, 3.5) for k in range(3)]
check(all(built_hs) and chest_stacks() == [0, 5, 4],
      f"L7: builds naming the held stack's slot (hs) take all three from that stack: built {[bool(b) for b in built_hs]}, stacks {chest_stacks()}")
send({"t": "build", "item": "wooden-chest", "x": fixed(-3.5), "y": fixed(4.5), "d": 0, "hs": hs_a})
tick(2)
check(chest_stacks() == [0, 4, 4] and chest_at(-3.5, 4.5),
      f"L7: an hs whose stack is used up still builds, from another normal stack: {chest_stacks()}")
send({"t": "build", "item": "wooden-chest", "x": fixed(-4.5), "y": fixed(4.5), "d": 0, "hs": hs_c})
tick(2)
rare_built = chest_at(-4.5, 4.5)
check(chest_stacks() == [0, 4, 3] and rare_built and rare_built.quality.name == "rare",
      f"L7: the held stack's own quality is what is built (a rare stack held, no q sent): {chest_stacks()}")
send({"t": "build", "item": "wooden-chest", "x": fixed(-5.5), "y": fixed(4.5), "d": 0})
tick(2)
check(sum(chest_stacks()[:2]) == 3 and chest_stacks()[2] == 3 and chest_at(-5.5, 4.5) and chest_at(-5.5, 4.5).quality.name == "normal",
      f"L7: without hs a normal one pays, as before: {chest_stacks()}")
send({"t": "build", "item": "wooden-chest", "x": fixed(-6.5), "y": fixed(4.5), "d": 0, "hs": 1})
tick(2)
check(sum(chest_stacks()[:2]) == 2 and chest_at(-6.5, 4.5),
      f"L7: an hs naming a slot that holds another item is passed over: {chest_stacks()}")
for spot in [(-3.5, 3.5), (-4.5, 3.5), (-5.5, 3.5), (-3.5, 4.5), (-4.5, 4.5), (-5.5, 4.5), (-6.5, 4.5)]:
    if chest_at(*spot):
        chest_at(*spot).destroy()
set_slot(inv, hs_a, "iron-plate", 7, None)
plates_all = inv.get_item_count("iron-plate")
send({"t": "drop", "item": "iron-plate", "x": fixed(2.5), "y": fixed(2.5), "hs": hs_a})
tick(2)
check(slot_now(inv, hs_a) == 6 and inv.get_item_count("iron-plate") == plates_all - 1,
      f"L7: Z naming the held stack's slot takes the plate from that stack: {slot_now(inv, hs_a)}")
send({"t": "fast", **target_of(box_chest), "half": 0})
tick(2)
# Tiles and capsules leave the held stack too (tiles took any stack, a capsule the first found).
set_slot(inv, hs_a, "concrete", 4, None)
set_slot(inv, hs_b, "concrete", 6, None)
concrete_all = inv.get_item_count("concrete")
tile_was = F.surface.get_tile(-4, 5).name
send({"t": "tile", "item": "concrete", "x": fixed(-3.5), "y": fixed(5.5), "n": 1, "hs": hs_a})
tick(2)
check(slot_now(inv, hs_a) == 3 and slot_now(inv, hs_b) == 6 and inv.get_item_count("concrete") == concrete_all - 1,
      f"L7: a tile naming the held stack's slot is paid from that stack: {slot_now(inv, hs_a)}, {slot_now(inv, hs_b)} (was {tile_was})")
F.surface.set_tile(-4, 5, tile_was)
set_slot(inv, hs_a, None, 0, None)
set_slot(inv, hs_b, "grenade", 4, None)
grenades_all = inv.get_item_count("grenade")
thrown = len(F.capsules)
send({"t": "throw", "item": "grenade", "x": fixed(puppet.position.x + 5), "y": fixed(puppet.position.y), "hs": hs_b})
tick(2)
check(slot_now(inv, hs_b) == 3 and inv.get_item_count("grenade") == grenades_all - 1 and len(F.capsules) == thrown + 1,
      f"L7: a capsule naming the held stack's slot is thrown out of that stack: {slot_now(inv, hs_b)} of {grenades_all}")
# One rule for every command spending from the hand (puppet.held_stack / take_held): the held stack pays only
# when it is the item in the quality asked for, normal when none is given; else a stack of that quality.
puppet_mod = lua.eval('package.loaded["scripts.puppet"]')
set_slot(inv, hs_a, "wooden-chest", 3, "rare")
set_slot(inv, hs_b, "wooden-chest", 5, None)
set_slot(inv, hs_c, None, 0, None)
rule =[puppet_mod.held_stack(inv, hs_a, "wooden-chest") is None,
        puppet_mod.held_stack(inv, hs_a, "wooden-chest", "rare") is not None,
        puppet_mod.held_quality(inv, hs_a, "wooden-chest") == "rare"]
puppet_mod.take_held(inv, hs_a, "wooden-chest", 1)
rule.append(chest_stacks()[:2] == [3, 4])
puppet_mod.take_held(inv, hs_a, "wooden-chest", 1, "rare")
rule.append(chest_stacks()[:2] == [2, 4])
send({"t": "fast", **target_of(box_chest), "item": "wooden-chest", "n": 1, "q": "rare", "hs": hs_b, "half": 0})
tick(2)
rule.append(chest_stacks()[:2] == [1, 4])
check(all(rule), f"L7: the held stack pays only in the quality asked for (normal by default), else a stack of that quality: {rule}, {chest_stacks()}")
send({"t": "fast", **target_of(box_chest), "half": 0})
tick(2)
for k in (hs_a, hs_b, hs_c):
    set_slot(inv, k, None, 0, None)
take()

# N2: Ctrl+click on vehicles, as Factorio's fast transfer: a car takes fuel into its fuel slot, ammo
# into its ammo slots and anything else into its trunk; a locomotive takes fuel; a full trunk refuses;
# an empty hand takes the trunk out.
F.trunk_size = 1
fast_car = spawn("car", -4.0, 4.0, force="player")
F.trunk_size = None
fast_loco = spawn("locomotive", -8.0, 2.0, force="player")
car_invs = F.inventories[fast_car]
puppet.insert(lua.table_from({"name": "wood", "count": 40}))
inv.insert(lua.table_from({"name": "firearm-magazine", "count": 20}))  # the main inventory (the character puts ammo in its ammo slots)
puppet.insert(lua.table_from({"name": "iron-plate", "count": 200}))
take()
wood0 = inv.get_item_count("wood")
send({"t": "fast", **target_of(fast_car), "item": "wood", "n": 10})
tick(2)
check(car_invs["fuel"].get_item_count("wood") == 10 and inv.get_item_count("wood") == wood0 - 10,
      "N2: Ctrl+click on a car puts the held fuel into its fuel slot")
check(len(of_type(take(), "slots")) >= 1, "N2: and sends the slots at once, as for a building (the hand and sound follow)")
mags0 = inv.get_item_count("firearm-magazine")
send({"t": "fast", **target_of(fast_car), "item": "firearm-magazine", "n": 10})
tick(2)
check(car_invs["vehicle_ammo"].get_item_count("firearm-magazine") == 10 and inv.get_item_count("firearm-magazine") == mags0 - 10,
      "N2: ammo goes into the car's ammo slots")
plates0 = inv.get_item_count("iron-plate")
send({"t": "fast", **target_of(fast_car), "item": "iron-plate", "n": 100})
tick(2)
check(car_invs["trunk"].get_item_count("iron-plate") == 100 and inv.get_item_count("iron-plate") == plates0 - 100,
      "N2: anything else goes into the car's trunk")
take()
send({"t": "fast", **target_of(fast_car), "item": "iron-plate", "n": 100})
tick(2)
check(inv.get_item_count("iron-plate") == plates0 - 100 and car_invs["trunk"].get_item_count("iron-plate") == 100
      and any("Can't put" in m["text"] for m in of_type(take(), "msg")),
      "N2: a full trunk refuses, and nothing leaves the inventory")
wood1 = inv.get_item_count("wood")
send({"t": "fast", **target_of(fast_loco), "item": "wood", "n": 5})
tick(2)
check(F.inventories[fast_loco]["fuel"].get_item_count("wood") == 5 and inv.get_item_count("wood") == wood1 - 5,
      "N2: a locomotive takes the held fuel")
send({"t": "fast", **target_of(fast_loco), "item": "iron-plate", "n": 5})
tick(2)
check(inv.get_item_count("iron-plate") == plates0 - 100, "N2: a locomotive takes no plates (fuel only)")
send({"t": "fast", **target_of(fast_car), "half": 0})
tick(2)
check(car_invs["trunk"].get_item_count("iron-plate") == 0 and inv.get_item_count("iron-plate") == plates0,
      "N2: Ctrl+click with an empty hand takes the car's trunk out")
check(car_invs["fuel"].get_item_count("wood") == 10, "N2: and leaves the car's fuel in its fuel slot")
# An empty hand never takes fuel (/f3d-perf fast_take): in 2.1 a locomotive's get_output_inventory is its
# fuel slot, and a boiler's (an empty burnt result inventory) leaves the old fallback at inventory 1,
# defines.inventory.chest, which is also its fuel (read in 2.1.24).
fast_boiler = spawn("boiler", -7.5, 6.0, force="player")
F.inventories[fast_boiler]["fuel"].insert(lua.table_from({"name": "wood", "count": 5}))
take()
for who, ent in (("locomotive", fast_loco), ("boiler", fast_boiler)):
    wood2 = inv.get_item_count("wood")
    send({"t": "fast", **target_of(ent), "half": 0})
    tick(2)
    check(F.inventories[ent]["fuel"].get_item_count("wood") == 5 and inv.get_item_count("wood") == wood2,
          f"N2: Ctrl+click with an empty hand on a {who} leaves its fuel")
    check(any(m["text"] == "Nothing to take" for m in of_type(take(), "msg")), f"N2: and the {who} says there is nothing to take")
# A lab's packs and a turret's ammo are still taken, as before (Factorio's wiki: "takes anything the entity has";
# whether it does for these wasn't seen in Factorio).
fast_lab = spawn("lab", -5.5, 9.5, force="player")
fast_turret = spawn("gun-turret", -2.0, 8.0, force="player")
F.inventories[fast_lab]["input"].insert(lua.table_from({"name": "automation-science-pack", "count": 3}))
F.inventories[fast_turret]["turret_ammo"].insert(lua.table_from({"name": "firearm-magazine", "count": 4}))
for who, ent, role, item, n in (("lab", fast_lab, "input", "automation-science-pack", 3),
                                ("gun turret", fast_turret, "turret_ammo", "firearm-magazine", 4)):
    have = inv.get_item_count(item)
    send({"t": "fast", **target_of(ent), "half": 0})
    tick(2)
    check(F.inventories[ent][role].get_item_count(item) == 0 and (role == "turret_ammo" or inv.get_item_count(item) == have + n),  # (ammo goes to the ammo slots)
          f"N2: Ctrl+click with an empty hand still takes a {who}'s {item}: left {F.inventories[ent][role].get_item_count(item)}, main {have} -> {inv.get_item_count(item)}")
take()
fast_lab.destroy()
fast_turret.destroy()
g.storage.f3d_perf = lua.table_from({"fast_take": False})
send({"t": "fast", **target_of(fast_boiler), "half": 0})
tick(2)
check(F.inventories[fast_boiler]["fuel"].get_item_count("wood") == 0, "N2: /f3d-perf fast_take off: the boiler's fuel taken, as before")
g.storage.f3d_perf = None
take()
fast_boiler.destroy()
fast_car.destroy()
fast_loco.destroy()

# Copy and paste settings (Shift+right / left click): an assembler's recipe.
asm_a = spawn("assembling-machine-1", 6.5, 6.5, force="player")
asm_b = spawn("assembling-machine-1", 9.5, 6.5, force="player")
asm_a.set_recipe("iron-gear-wheel")
send({"t": "paste_settings", "f": [asm_a.unit_number, eid[asm_a.name], fixed(6.5), fixed(6.5)], **target_of(asm_b)})
tick(2)
check(asm_b.get_recipe() and asm_b.get_recipe()[0].name == "iron-gear-wheel", "paste_settings copies the recipe (2.x: recipe, quality)")

# Flip (H / V).
send({"t": "flip", **target_of(asm_b), "v": 0})
tick(2)
check(asm_b.mirroring is True and any(m["e"][0] == asm_b.unit_number for m in of_type(take(), "upd")), "flip mirrors the entity and sends its upd")

# Building a ghost (Shift+click) and a flipped entity.
send({"t": "build", "item": "assembling-machine-1", "x": fixed(14.5), "y": fixed(14.5), "d": 0, "ghost": 1})
tick(2)
adds = [m["e"] for m in of_type(take(), "add")]
check(any(a[1] == eid["entity-ghost"] and a[5].get("gh") == eid["assembling-machine-1"] for a in adds),
      f"build with ghost = 1 places a ghost, without the item and out of reach: {adds}")

# The clipboard: copy an area, see its entities, paste them as ghosts; cut marks the area too.
send({"t": "copy", "x1": fixed(5), "y1": fixed(5), "x2": fixed(11), "y2": fixed(8), "cut": 0, "bp": 0})
tick(2)
clip = of_type(take(), "clip")
check(clip and sorted(e[0] for e in clip[-1]["l"]) == [eid["assembling-machine-1"]] * 2, f"copy sends the clipboard's entities: {clip}")
# Owner's #21: the blueprint holds map positions; the client needs them around the copy's middle.
xs = [e[1] for e in clip[-1]["l"]] if clip else [0]
ys = [e[2] for e in clip[-1]["l"]] if clip else [0]
check(clip and abs(min(xs) + max(xs)) <= 1 and abs(min(ys) + max(ys)) <= 1 and max(map(abs, xs + ys)) < 256 * 8,
      f"the clipboard's positions are around its centre, not on the map: {clip[-1]['l'] if clip else clip}")
send({"t": "paste", "x": fixed(20.5), "y": fixed(20.5), "d": 0})
tick(2)
adds = [m["e"] for m in of_type(take(), "add") if m["e"][1] == eid["entity-ghost"]]
check(len(adds) == 2, f"paste places the clipboard's ghosts: {adds}")
send({"t": "copy", "x1": fixed(5), "y1": fixed(5), "x2": fixed(11), "y2": fixed(8), "cut": 1, "bp": 0})
tick(2)
check(F.decon_marks[asm_a] is True and F.decon_marks[asm_b] is True, "cut marks the area for deconstruction")
send({"t": "copy", "x1": fixed(14), "y1": fixed(14), "x2": fixed(27), "y2": fixed(27), "cut": 1, "bp": 0})
tick(2)
dels = {d["u"] for d in of_type(take(), "del")}
check(all(a[0] in dels for a in adds), f"cut (Ctrl+X) over ghosts removes them and sends their del (owner's #20): {dels}")
send({"t": "copy", "x1": fixed(5), "y1": fixed(5), "x2": fixed(11), "y2": fixed(8), "cut": 0, "bp": 1})
tick(2)
bp_slots = [i for i in range(1, 81) if inv[i].valid_for_read and inv[i].name == "blueprint"]
check(len(bp_slots) >= 1 and any(m["text"] == "Blueprint added to the inventory" for m in of_type(take(), "msg")),
      "Alt+B's area becomes a blueprint in the inventory")
# to: Select new contents, into that blueprint, its name kept.
inv[bp_slots[0]].label = "Keep me"
before = len([i for i in range(1, 81) if inv[i].valid_for_read and inv[i].name == "blueprint"])
send({"t": "copy", "x1": fixed(5), "y1": fixed(5), "x2": fixed(8), "y2": fixed(8), "cut": 0, "bp": 1, "to": bp_slots[0]})
tick(2)
msgs = take()
ok = of_type(msgs, "bp_ok")
after = len([i for i in range(1, 81) if inv[i].valid_for_read and inv[i].name == "blueprint"])
check(ok and ok[-1]["i"] == bp_slots[0] and ok[-1].get("new") == 1 and after == before and inv[bp_slots[0]].label == "Keep me"
      and len(inv[bp_slots[0]].get_blueprint_entities()) >= 1, f"copy with to: the same blueprint gets the new contents, its name kept: {ok}")
send({"t": "copy", "x1": fixed(-30), "y1": fixed(-30), "x2": fixed(-29), "y2": fixed(-29), "cut": 0, "bp": 0})
tick(2)
check(any(m["text"] == "Nothing to copy there" for m in of_type(take(), "msg")), "copying an empty area says so")

# Alt-mode: recipe icons near the focus, and every filter of a filter inserter (owner's #23).
fins = spawn("fast-inserter", 3.5, 3.5, force="player")
fins.set_filter(2, "iron-plate")
fins.set_filter(4, "copper-plate")
fins.set_filter(5, "coal")
send({"t": "alt", "on": 1})
tick(2)
ai = of_type(take(), "ai")
check(ai and [asm_b.unit_number, "recipe", "iron-gear-wheel"] in ai[-1]["l"], f"Alt-mode lists recipe icons: {ai[-1:]}")
check(ai and [fins.unit_number, "item", "iron-plate", ["copper-plate", "coal"]] in ai[-1]["l"],
      f"a filter inserter's Alt-mode icon carries all its filters, the first even when slot 1 is empty: {[r for r in ai[-1]['l'] if r[0] == fins.unit_number] if ai else ai}")
fins.destroy()
send({"t": "alt", "on": 0})
tick(70)
check(not of_type(take(), "ai"), "Alt-mode off stops the icons")

# Issue #9: Alt-mode's icon rides on the record (no cap, no scan); a furnace (its recipe comes from
# what is put in) and circuit-wired machines are watched, `aiu` carrying what changed; a window
# closed in the real game sends the icon too.
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
asm_r = spawn("assembling-machine-1", 14.5, 14.5, force="player")
asm_r.set_recipe("iron-gear-wheel")
alt_furnace = spawn("stone-furnace", 17.0, 14.0, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": asm_r}))
F["raise"]("script_raised_built", lua.table_from({"entity": alt_furnace}))
tick(2)
adds = {m["e"][0]: m["e"] for m in of_type(take(), "add")}
rec_asm, rec_furnace = adds.get(asm_r.unit_number), adds.get(alt_furnace.unit_number)
check(rec_asm and len(rec_asm) > 5 and rec_asm[5].get("ai") == ["recipe", "iron-gear-wheel"],
      f"#9: an assembler's record carries its Alt-mode icon (extra.ai): {rec_asm}")
check(rec_furnace and (len(rec_furnace) == 5 or "ai" not in rec_furnace[5]), f"#9: a furnace that never smelted has none: {rec_furnace}")
alt_mode_mod = g.package.loaded["scripts.alt_mode"]
check(g.storage.f3d.altw[alt_furnace.unit_number] and not g.storage.f3d.altw[asm_r.unit_number],
      "#9: the furnace is watched, the unwired assembler isn't")


def between_chunk_refreshes():
    """To 30 ticks past world.lua's periodic chunk refresh (every 300 ticks, and which chunk comes
    next is Lua's table order, different each run). A refresh of the furnace's chunk tells the
    client in its record, and the watch then has nothing to send: 250 ticks from here have none."""
    send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
    tick((30 - int(lua.eval("game.tick"))) % 300)
    send({"t": "hello", "v": 1, "sid": "s1", "w": 1})


between_chunk_refreshes()
fill(alt_furnace, "input", "iron-ore", 3)
tick(250)
aiu = [row for m in of_type(take(), "aiu") for row in m["l"]]
check([alt_furnace.unit_number, "recipe", "iron-plate"] in aiu, f"#9: the furnace taking ore sends its new icon in aiu: {aiu}")
between_chunk_refreshes()
F.inventories[alt_furnace]["input"].remove(lua.table_from({"name": "iron-ore", "count": 3}))
tick(250)
aiu = [row for m in of_type(take(), "aiu") for row in m["l"]]
check(not any(row[0] == alt_furnace.unit_number for row in aiu),
      f"J2: and keeping its last recipe's icon when the ore runs out, as Factorio (previous_recipe): {aiu}")
check(to_py(alt_mode_mod.icon(alt_furnace)) == ["recipe", "iron-plate"], "J2: an idle furnace's icon is the recipe it last made")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(250)
check(not of_type(take(), "aiu"), "#9: nothing more while nothing changes")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
asm_r.set_recipe("transport-belt")  # no event (a script, or the real game's window still open)
F["raise"]("on_gui_closed", lua.table_from({"entity": asm_r, "player_index": 1}))
tick(1)
aiu = [row for m in of_type(take(), "aiu") for row in m["l"]]
check([asm_r.unit_number, "recipe", "transport-belt"] in aiu, f"#9: a window closed in the real game sends the machine's icon: {aiu}")
# L10: 2.1 makes the machine's fluid storages from its recipe, each filtered to its fluid: which fluid goes in or out
# where rides with the mask (the fake's two storages and their connections, as 2.1.24's refinery reports them).
F.set_fluid(asm_r, 2, None)
asm_x, asm_y = asm_r.position.x, asm_r.position.y
F.fluid_conns[asm_r] = lua.table_from({
    1: {"filter": "crude-oil", "conns": [{"connection_type": "normal", "flow_direction": "input",
                                         "position": {"x": asm_x + 1, "y": asm_y + 1}, "target_position": {"x": asm_x + 1, "y": asm_y + 2}}]},
    2: {"filter": "petroleum-gas", "conns": [{"connection_type": "normal", "flow_direction": "output",
                                             "position": {"x": asm_x - 1, "y": asm_y - 1}, "target_position": {"x": asm_x - 1, "y": asm_y - 2}},
                                            {"connection_type": "underground", "flow_direction": "output",
                                             "position": {"x": asm_x, "y": asm_y}, "target_position": {"x": asm_x, "y": asm_y}}]},
}, recursive=True)
asm_r.set_recipe("oil-processing")
F["raise"]("on_gui_closed", lua.table_from({"entity": asm_r, "player_index": 1}))
tick(1)
fa = [row for m in of_type(take(), "aiu") for row in m.get("fa", [])]
l10_conns = [[1, 1, 8, "i", "crude-oil"], [-1, -1, 0, "o", "petroleum-gas"]]
check([asm_r.unit_number, 3, l10_conns] in fa,
      f"#9 part 2, L10: a recipe taking and making fluid sends its arrows' mask (fa 3) and each connection's fluid: {fa}")
l10_rec = to_py(g.package.loaded["scripts.world"].record(asm_r))
check(isinstance(l10_rec, list) and len(l10_rec) > 5 and l10_rec[5].get("fc") == l10_conns,
      f"L10: and its record carries them (fc): {l10_rec}")
g.storage.f3d_perf = lua.table_from({"fluid_icons": False})
check(g.package.loaded["scripts.alt_mode"].connections(asm_r) is None, "fluid_icons off: no connections read")
g.storage.f3d_perf = None
asm_r.set_recipe("iron-gear-wheel")
F["raise"]("on_gui_closed", lua.table_from({"entity": asm_r, "player_index": 1}))
tick(1)
fa = [row for m in of_type(take(), "aiu") for row in m.get("fa", [])]
check([asm_r.unit_number, 0] in fa, f"#9 part 2: and none again with an item recipe: {fa}")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
asm_r.destroy()
alt_furnace.destroy()
tick(250)
check(not g.storage.f3d.altw[alt_furnace.unit_number] if g.storage.f3d.altw else True, "#9: a watched machine gone is forgotten after a round")
take()

# The drill's fluid part: a mining drill with a fluid box (2.1.24 gives one over uranium ore, for its sulfuric acid)
# takes fluid in, its record's `fa` 1 (the client draws its `-wet` model); without one none. Its own box says
# (`fluids_count`), not what it mines: the box stays when the ore runs out, and an iron drill with one uranium tile in
# its area has one too.
wet_ore = spawn("uranium-ore", 60.5, 60.5, amount=500)
dry_ore = spawn("iron-ore", 70.5, 60.5, amount=500)
wet_drill = spawn("electric-mining-drill", 60.5, 60.5, force="player")
dry_drill = spawn("electric-mining-drill", 70.5, 60.5, force="player")
wet_drill.mining_target = wet_ore
dry_drill.mining_target = dry_ore
F.set_fluids_count(wet_drill, 1)
check(alt_mode_mod.arrows(wet_drill) == 1 and alt_mode_mod.arrows(dry_drill) is None,
      "a drill with a fluid box (fluids_count 1): fa 1; with none (0): nil")
F.set_fluids_count(wet_drill, 0)
check(alt_mode_mod.arrows(wet_drill) is None,
      "a drill mining uranium ore whose box is gone (fluids_count 0): nil, the box decides, not the target")
F.set_fluids_count(wet_drill, 1)
mixed_drill = spawn("electric-mining-drill", 80.5, 60.5, force="player")
mixed_ore = spawn("iron-ore", 80.5, 60.5, amount=500)
mixed_wet = spawn("uranium-ore", 81.5, 61.5, amount=500)
mixed_drill.mining_target = mixed_ore
F.set_fluids_count(mixed_drill, 1)
check(alt_mode_mod.arrows(mixed_drill) == 1,
      "the mixed area: a drill mining iron ore (no fluid needed) with one uranium tile in its area has its box: fa 1")
check(alt_mode_mod.arrows(g.F.spawn("burner-mining-drill", 90.5, 90.5, lua.table_from({"force": "player"}))) is None,
      "a burner drill, no fluid box: nil")
for e in (mixed_drill, mixed_ore, mixed_wet):
    e.destroy()
wet_rec = to_py(g.package.loaded["scripts.world"].record(wet_drill))
dry_rec = to_py(g.package.loaded["scripts.world"].record(dry_drill))
check(isinstance(wet_rec, list) and len(wet_rec) > 5 and wet_rec[5].get("fa") == 1,
      f"the wet drill's record carries fa 1: {wet_rec}")
check(isinstance(dry_rec, list) and (len(dry_rec) == 5 or "fa" not in dry_rec[5]), f"the dry drill's none: {dry_rec}")
for e in (wet_drill, dry_drill, wet_ore, dry_ore):
    e.destroy()
take()

# Placing an electric drill over uranium ore, as Factorio 2.1.24 does (measured with can_place_entity): refused with
# Factorio's own reason until the force can mine with fluid (the "Uranium mining" research), even with iron ore beside
# it; built once it can. The fake's can_place_entity holds that rule.
# (A free square within reach: earlier checks left a car, a biter and machines round the character.)
ux, uy = next((math.floor(puppet.position.x) + dx, math.floor(puppet.position.y) + dy)
              for dx in range(-7, 8) for dy in range(-7, 8)
              if not any(e.type != "resource" and abs(e.position.x - (math.floor(puppet.position.x) + dx + 0.5)) < 4
                         and abs(e.position.y - (math.floor(puppet.position.y) + dy + 0.5)) < 4 for e in F.surface.entities.values()))
u_ores = [spawn("uranium-ore", ux + dx + 0.5, uy + dy + 0.5, amount=500) for dx in (-1, 0, 1) for dy in (-1, 0, 1)]
u_iron = spawn("iron-ore", ux + 2.5, uy + 2.5, amount=500)
g.game.forces.player.mining_with_fluid = False
puppet.insert(lua.table_from({"name": "electric-mining-drill", "count": 2}))
take()
send({"t": "build", "item": "electric-mining-drill", "x": ux * 256 + 128, "y": uy * 256 + 128, "d": 0})
tick(1)
said = texts(take())
drills_at = lambda: [e for e in F.surface.entities.values() if e.name == "electric-mining-drill"
                     and abs(e.position.x - (ux + 0.5)) < 0.1 and abs(e.position.y - (uy + 0.5)) < 0.1]
check(not drills_at() and "Uranium mining not researched." in said,
      f"an electric drill over uranium ore (iron beside it) before Uranium mining: refused in Factorio's words: {said}")
g.game.forces.player.mining_with_fluid = True
send({"t": "build", "item": "electric-mining-drill", "x": ux * 256 + 128, "y": uy * 256 + 128, "d": 0})
tick(1)
said = texts(take())
check(len(drills_at()) == 1 and not any("place" in t or "Uranium" in t for t in said),
      f"and once the force can mine with fluid it is built, waiting for its sulfuric acid as in Factorio: {said}")
g.game.forces.player.mining_with_fluid = False
for e in drills_at() + u_ores + [u_iron]:
    e.destroy()
take()

# J6: Factorio's Alt-mode shows what is in a chest. While the client says Alt-mode is on (`altc`), the
# chests in the focus square are read in rounds and `ac` carries those whose icons changed: the kinds
# held most, most first, up to four; [unit] when none; nothing while off.
j6_start = int(lua.eval("game.tick"))
ac_chest = spawn("wooden-chest", 20.5, 10.5, force="player")
fill(ac_chest, "chest", "coal", 50)
fill(ac_chest, "chest", "iron-plate", 80)
fill(ac_chest, "chest", "stone", 5)
fill(ac_chest, "chest", "copper-plate", 5)
fill(ac_chest, "chest", "wood", 1)
ac_empty = spawn("wooden-chest", 21.5, 10.5, force="player")
focus_before = to_py(g.storage.f3d.focus)
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
send({"t": "focus", "x": fixed(18), "y": fixed(10), "r": 32})
tick(1)
take()
check(to_py(alt_mode_mod.contents(ac_chest)) == ["iron-plate", "coal", "copper-plate", "stone"],
      f"J6: a chest's icons are its four most held kinds, most first: {to_py(alt_mode_mod.contents(ac_chest))}")
send({"t": "altc", "on": 1, "g": 3})
tick(5)
ac_rows = {r[0]: r for m in of_type(take(), "ac") if m["g"] == 3 for r in m["l"]}
check(ac_rows.get(ac_chest.unit_number) == [ac_chest.unit_number, "iron-plate", ["coal", "copper-plate", "stone"]]
      and ac_empty.unit_number not in ac_rows,
      f"J6: Alt-mode on: `ac` lists the chests in the focus square with something in them: {ac_rows}")
F.inventories[ac_chest]["chest"].remove(lua.table_from({"name": "iron-plate", "count": 80}))
fill(ac_empty, "chest", "iron-gear-wheel", 10)
tick(70)
ac_rows = [r for m in of_type(take(), "ac") for r in m["l"]]
check(sorted(ac_rows) == sorted([[ac_chest.unit_number, "coal", ["copper-plate", "stone", "wood"]], [ac_empty.unit_number, "iron-gear-wheel"]]),
      f"J6: the next round sends only the chests that changed: {ac_rows}")
for item, n in (("coal", 50), ("stone", 5), ("copper-plate", 5), ("wood", 1)):
    F.inventories[ac_chest]["chest"].remove(lua.table_from({"name": item, "count": n}))
gone_unit = ac_empty.unit_number
ac_empty.destroy()
tick(70)
ac_rows = [r for m in of_type(take(), "ac") for r in m["l"]]
check(sorted(ac_rows) == sorted([[ac_chest.unit_number], [gone_unit]]), f"J6: an emptied chest and one gone are [unit]: {ac_rows}")
send({"t": "altc", "on": 0})
fill(ac_chest, "chest", "coal", 7)
tick(130)
check(not of_type(take(), "ac") and not g.storage.f3d.altc, "J6: Alt-mode off: no more `ac`, nothing kept")
ac_chest.destroy()
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
send({"t": "focus", "x": fixed(focus_before["x"]), "y": fixed(focus_before["y"]), "r": int(focus_before["r"])})
while (int(lua.eval("game.tick")) - j6_start) % 1200:  # the checks after keep the tick phase they were written at
    if int(lua.eval("game.tick")) % 100 == 0:
        send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
    tick(1)

# K1, K2: in the same rounds, the modules in machines and the science packs in labs (`am`): one icon
# a module in slot order with its quality when not normal, a lab's packs a slot each; [unit] when
# none; nothing read with /f3d-perf alt_machines off.
k_start = int(lua.eval("game.tick"))
am_asm = spawn("assembling-machine-1", 24.5, 4.5, force="player")
F.inventories[am_asm]["modules"].insert(lua.table_from({"name": "speed-module", "count": 1}))
F.inventories[am_asm]["modules"].insert(lua.table_from({"name": "speed-module", "count": 1, "quality": "rare"}))
am_lab = spawn("lab", 28.5, 4.5, force="player")
fill(am_lab, "input", "automation-science-pack", 5)
fill(am_lab, "input", "logistic-science-pack", 3)
am_beacon = spawn("beacon", 24.5, 16.5, force="player")
fill(am_beacon, "modules", "speed-module", 2)
am_idle = spawn("assembling-machine-1", 28.5, 16.5, force="player")
focus_before = to_py(g.storage.f3d.focus)
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
send({"t": "focus", "x": fixed(18), "y": fixed(10), "r": 32})
tick(1)
take()
send({"t": "altc", "on": 1, "g": 4})
tick(5)
am_msgs = [m for m in of_type(take(), "am") if m["g"] == 4]
am_rows = {r[0]: r for m in am_msgs for r in m["l"]}
check(am_rows.get(am_asm.unit_number) == [am_asm.unit_number, ["speed-module", ["speed-module", "rare"]]]
      and am_rows.get(am_lab.unit_number) == [am_lab.unit_number, 0, ["automation-science-pack", "logistic-science-pack"]]
      and am_rows.get(am_beacon.unit_number) == [am_beacon.unit_number, ["speed-module", "speed-module"]]
      and am_idle.unit_number not in am_rows,
      f"K1, K2: Alt-mode on: `am` lists the machines' modules (quality kept) and the lab's packs, not an empty machine: {am_rows}")
F.inventories[am_lab]["input"].remove(lua.table_from({"name": "automation-science-pack", "count": 5}))
F.inventories[am_lab]["input"].remove(lua.table_from({"name": "logistic-science-pack", "count": 3}))
fill(am_idle, "modules", "speed-module", 1)
tick(70)
am_rows = [r for m in of_type(take(), "am") for r in m["l"]]
check(sorted(am_rows, key=str) == sorted([[am_lab.unit_number], [am_idle.unit_number, ["speed-module"]]], key=str),
      f"K2: the next round sends only what changed, a lab run out of packs as [unit]: {am_rows}")
g.storage.f3d_perf = lua.table_from({"alt_machines": False})
tick(70)
am_rows = [r for m in of_type(take(), "am") for r in m["l"]]
check(sorted(am_rows, key=str) == sorted([[am_asm.unit_number], [am_beacon.unit_number], [am_idle.unit_number]], key=str),
      f"K1: /f3d-perf alt_machines off: the machines aren't read, their icons go: {am_rows}")
g.storage.f3d_perf = None
send({"t": "altc", "on": 0})
tick(70)
check(not of_type(take(), "am") and not g.storage.f3d.altc, "K1: Alt-mode off: no more `am`")
# K1's leftover: ammo turrets' ammo and locomotives' fuel in the same rounds, one icon a filled slot, where a
# lab's packs go in the row; an empty turret none; the locomotive read where it stands now; nothing read with
# /f3d-perf alt_ammo_fuel off.
am_turret = spawn("gun-turret", 20.0, 4.0, force="player")
F.inventories[am_turret]["turret_ammo"].insert(lua.table_from({"name": "firearm-magazine", "count": 10}))
am_bare = spawn("gun-turret", 20.0, 8.0, force="player")
am_loco = spawn("locomotive", 21.0, 20.0, force="player")
F.inventories[am_loco]["fuel"].insert(lua.table_from({"name": "wood", "count": 5}))
am_wagon = spawn("cargo-wagon", 21.0, 26.0, force="player")
for item, n in (("copper-plate", 50), ("iron-plate", 200), ("coal", 80), ("stone", 10), ("wood", 5), ("iron-ore", 80)):
    F.inventories[am_wagon]["cargo"].insert(lua.table_from({"name": item, "count": n}))
# Locomotives' fuel is read only when the client asks (`lf`, --loco-fuel-icons=on); wagons' cargo always.
send({"t": "altc", "on": 1, "g": 4})
tick(5)
am_rows = {r[0]: r for m in of_type(take(), "am") if m["g"] == 4 for r in m["l"]}
check(am_rows.get(am_wagon.unit_number) == [am_wagon.unit_number, 0, ["iron-plate", "coal", "iron-ore", "copper-plate"]]
      and am_loco.unit_number not in am_rows and am_turret.unit_number in am_rows,
      f"wagon items: `am` lists a cargo wagon's four most-stacked kinds, most first; no locomotive fuel without `lf`: {am_rows}")
send({"t": "altc", "on": 1, "g": 5, "lf": 1})
tick(5)
am_rows = {r[0]: r for m in of_type(take(), "am") if m["g"] == 5 for r in m["l"]}
check(am_rows.get(am_turret.unit_number) == [am_turret.unit_number, 0, ["firearm-magazine"]]
      and am_rows.get(am_loco.unit_number) == [am_loco.unit_number, 0, ["wood"]] and am_bare.unit_number not in am_rows
      and am_rows.get(am_wagon.unit_number) == [am_wagon.unit_number, 0, ["iron-plate", "coal", "iron-ore", "copper-plate"]]
      and am_rows.get(am_asm.unit_number) == [am_asm.unit_number, ["speed-module", ["speed-module", "rare"]]],
      f"K1: Alt-mode on: `am` lists a gun turret's ammo and a locomotive's fuel beside the machines, not an empty turret: {am_rows}")
F.inventories[am_turret]["turret_ammo"].remove(lua.table_from({"name": "firearm-magazine", "count": 10}))
F.inventories[am_bare]["turret_ammo"].insert(lua.table_from({"name": "firearm-magazine", "count": 3, "quality": "rare"}))
tick(70)
am_rows = [r for m in of_type(take(), "am") for r in m["l"]]
check(sorted(am_rows, key=str) == sorted([[am_turret.unit_number], [am_bare.unit_number, 0, [["firearm-magazine", "rare"]]]], key=str),
      f"K1: the next round sends only what changed: a turret out of ammo as [unit], another's ammo with its quality: {am_rows}")
g.storage.f3d_perf = lua.table_from({"alt_ammo_fuel": False})
tick(70)
am_rows = [r for m in of_type(take(), "am") for r in m["l"]]
check(sorted(am_rows, key=str) == sorted([[am_bare.unit_number], [am_loco.unit_number], [am_wagon.unit_number]], key=str),
      f"K1: /f3d-perf alt_ammo_fuel off: turrets and locomotives aren't read, their icons go, the machines' stay: {am_rows}")
g.storage.f3d_perf = None
send({"t": "altc", "on": 0})
tick(70)
take()
for e in (am_asm, am_lab, am_beacon, am_idle, am_turret, am_bare, am_loco, am_wagon):
    e.destroy()
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
send({"t": "focus", "x": fixed(focus_before["x"]), "y": fixed(focus_before["y"]), "r": int(focus_before["r"])})
while (int(lua.eval("game.tick")) - k_start) % 1200:  # the checks after keep the tick phase they were written at
    if int(lua.eval("game.tick")) % 100 == 0:
        send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
    tick(1)
take()

# Chat: the client's line goes to the game's chat; players' lines come back.
F.printed = lua.table()
send({"t": "chat", "text": "hello factory"})
tick(2)
check(any("hello factory" in str(p) and "[Zenith]" in str(p) for p in F.printed.values()), f"chat prints in the game as [Zenith]: {list(F.printed.values())}")
check(any(m["text"] == "hello factory" and m["from"] == "Zenith" for m in of_type(take(), "chat")), "and echoes to the client, from Zenith")

# Statistics.
send({"t": "stats", "kind": "item", "prec": 2})
tick(2)
st = of_type(take(), "stats")
check(st and st[-1]["l"][0][0] == "iron-plate" and st[-1]["l"][0][3] == 120, f"production statistics, most first: {st[-1:]}")
send({"t": "stats", "kind": "kill", "prec": 1})
tick(2)
st = of_type(take(), "stats")
check(st and st[-1]["kind"] == "kill" and st[-1]["l"][0][0] == "small-biter", "kill statistics")
send({"t": "stats", "kind": "build", "prec": 1})
send({"t": "stats", "kind": "pollution", "prec": 3, "si": 0, "g": []})
send({"t": "stats", "kind": "item", "prec": 2, "g": ["iron-gear-wheel"]})
tick(6)  # answered under the work budget (requests.lua), a few a tick
st = of_type(take(), "stats")
build = [m for m in st if m["kind"] == "build"]
poll = [m for m in st if m["kind"] == "pollution"]
items = [m for m in st if m["kind"] == "item"]
check(build and build[-1]["l"][0][:4] == ["transport-belt", 4, 0.2, 40] and build[-1]["si"] == 1,
      f"building counts: built and removed, on the character's surface: {build[-1:]}")
check(poll and poll[-1]["si"] == 0 and {r[0] for r in poll[-1]["l"]} == {"assembling-machine-1", "grass-1"}
      and poll[-1]["gr"] and len(poll[-1]["gr"][0][1]) == 60 and len(poll[-1]["gr"][0][2]) == 60,
      f"pollution over all surfaces, with graph lines for the busiest: {poll[-1:]}")
check(items and [g[0] for g in items[-1]["gr"]] == ["iron-gear-wheel"] and items[-1]["gr"][0][1][0] == 1,
      f"graph lines for the items asked for: {items[-1:]}")

# An electric network's statistics from one of its poles, with its accumulators' storage.
epole = spawn("small-electric-pole", 30.5, 30.5, force="player")
send(dict(open_cmd(epole), t="stats", kind="electric", prec=1))
tick(2)
st = [m for m in of_type(take(), "stats") if m["kind"] == "electric"]
check(st and {r[0] for r in st[-1]["l"]} >= {"assembling-machine-1", "steam-engine"} and "si" not in st[-1]
      and st[-1].get("st") == [["accumulator", 1250000, 2500000]],
      f"electric network statistics: consumption, production and accumulator storage (st): {st[-1:]}")
check(st and st[-1].get("ef") == [500, 1000, 500, 2000, 2500000, 5000000],
      f"and the network's last update (flow_last_tick) for the summary bars: {st[-1:]}")
epole.destroy()
send({"t": "stats", "kind": "item", "prec": 9})
tick(2)
st = of_type(take(), "stats")
check(st and st[-1]["prec"] == 9 and st[-1]["l"][0][0] == "iron-plate" and st[-1]["l"][0][3] == 120,
      f"All (prec 9): rows by all-time totals: {st[-1:]}")

# The Bonuses and Permissions windows.
send({"t": "bonuses"})
send({"t": "perms"})
tick(2)
msgs = take()
bonus = of_type(msgs, "bonus")
kinds = {r[0]: r for r in bonus[-1]["l"]} if bonus else {}
check(kinds.get("inserter_stack_size_bonus", [0, 0])[1] == 1 and kinds.get("ammo_damage:bullet", [0, 0, 0])[1:] == [0.8, ["firearm-magazine"]]
      and kinds.get("turret_attack:gun-turret", [0, 0])[1] == 0.4 and "gun_speed:bullet" not in kinds,
      f"bonus: the force's bonuses that aren't zero, with their items: {bonus[-1:]}")
perms = of_type(msgs, "perms")
check(perms and perms[-1]["l"][0][0] == "Default" and len(perms[-1]["l"]) == 2, f"perms: the permission groups and their players: {perms[-1:]}")

# Factoriopedia: the index, and pages.
send({"t": "pedia_index"})
tick(3)
pidx = of_type(take(), "pidx")
entries = [r for m in pidx for r in m["l"]]
check(pidx and pidx[0]["part"] == 1 and pidx[0]["g"] and ["item", "iron-plate"] == [r for r in entries if r[1] == "iron-plate"][0][:2]
      and any(r[0] == "technology" and r[1] == "automation" for r in entries)
      and any(r[0] == "quality" and r[1] == "normal" for r in entries)
      and any(r[0] == "planet" and r[1] == "vulcanus" for r in entries)
      and not any(r[0] == "entity" and r[1] == "transport-belt" for r in entries),
      f"pidx lists items, technologies, qualities, planets; a placed entity is on its item's page: {entries[:8]}")
send({"t": "pedia", "kind": "item", "name": "transport-belt"})
send({"t": "pedia", "kind": "recipe", "name": "iron-gear-wheel"})
send({"t": "pedia", "kind": "technology", "name": "automation"})
send({"t": "pedia", "kind": "planet", "name": "nauvis"})
send({"t": "pedia", "kind": "item", "name": "no-such-item"})
tick(6)  # answered under the work budget (requests.lua), a few a tick
pages = {(m["kind"], m["name"]): m for m in of_type(take(), "pedia")}
belt = pages.get(("item", "transport-belt"), {}).get("d", {})
check(belt.get("made") == ["transport-belt"] and belt.get("entity", {}).get("type") == "transport-belt"
      and belt.get("used") == [], f"an item's page: made by, used in, the entity it builds: {belt}")
gear = pages.get(("recipe", "iron-gear-wheel"), {}).get("d", {})
check(gear.get("ing") == [["item", "iron-plate", 2]] and gear.get("unlocked") == ["automation"]
      and "assembling-machine-1" in gear.get("made_in", []) and gear.get("time") == 0.5,
      f"a recipe's page: ingredients, made in, unlocked by: {gear}")
auto = pages.get(("technology", "automation"), {}).get("d", {})
check(auto.get("effects") == [["unlock-recipe", "iron-gear-wheel", 0]] and auto.get("cost") == [["automation-science-pack", 1]],
      f"a technology's page: {auto}")
nauvis = pages.get(("planet", "nauvis"), {}).get("d", {})
check(["vulcanus", 15000] in nauvis.get("links", []) and ["solar-system-edge", 100000] in nauvis.get("links", []),
      f"a planet's page: its connections: {nauvis}")
check(pages.get(("item", "no-such-item"), {}).get("found") == 0, "an unknown page answers found 0")

# The logistic networks window (L).
F.lnets = lua.table_from({"nauvis": lua.table_from([F.make_network(7, lua.table_from([1, 2, 3, 4]),
                                                                    lua.table_from([lua.table_from(["iron-plate", 50])]))])})
send({"t": "lnets"})
send({"t": "lnet", "id": 7})
send({"t": "lnet", "id": 99})
tick(6)  # answered under the work budget (requests.lua), a few a tick
msgs = take()
nets = of_type(msgs, "lnets")
check(nets and nets[-1]["l"] == [[7, 1, "nauvis", [1, 2], [3, 4], 0, 0, 0, 0, 0, 0, ""]], f"lnets lists every network: {nets[-1:]}")
one = {m["id"]: m for m in of_type(msgs, "lnet")}
check(one.get(7, {}).get("items") == [["iron-plate", 50]] and one.get(99, {}).get("found") == 0,
      f"lnet: one network's contents, or found 0: {one}")
F.lnets = lua.table()

# Alerts: computed for the force from events and scans.
turret = spawn("gun-turret", 6.0, 6.0, force="player")
asm_off = spawn("assembling-machine-1", 9.5, 9.5, force="player")
asm_off.status = g.defines.entity_status.no_power
asm_off.electric_network_id = None
asm_dark = spawn("assembling-machine-1", 9.5, 13.5, force="player")  # on a network with no power
asm_dark.status = g.defines.entity_status.no_power
asm_dark.electric_network_id = 3
asm_low = spawn("assembling-machine-1", 13.5, 9.5, force="player")
asm_low.status = g.defines.entity_status.low_power
hurt = spawn("wooden-chest", 12.5, 12.5, force="player")
F["raise"]("on_entity_damaged", lua.table_from({"entity": hurt, "force": g.game.forces.enemy, "final_damage_amount": 10}))
# A turret's hit: a firing cue from the turret to its target, and blood on the biter.
take()
biter = spawn("small-biter", 8.0, 8.0, force="enemy")
turret.shooting_target = biter
F["raise"]("on_entity_damaged", lua.table_from({"entity": biter, "cause": turret, "force": g.game.forces.player, "final_damage_amount": 5}))
F["raise"]("on_entity_damaged", lua.table_from({"entity": biter, "cause": turret, "force": g.game.forces.player, "final_damage_amount": 5}))
msgs = take()
tf = of_type(msgs, "tf")
check(len(tf) == 1 and tf[0]["u"] == turret.unit_number and tf[0]["x"] == 8 * 256 and set(tf[0]) <= {"t", "k", "u", "x", "y"},
      f"a turret's hit sends one firing cue per interval, aimed at its target: {tf}")
afx = of_type(msgs, "afx")
check(len(afx) == 1 and afx[0]["fx"] == "blood" and afx[0]["u"] == biter.unit_number, f"a hit biter bleeds once per interval: {afx}")
# A turret that fired and was then mined (no on_entity_died) leaves its firing throttle behind.
gone_gun = spawn("gun-turret", 4.0, 12.0, force="player")
F["raise"]("on_entity_damaged", lua.table_from({"entity": biter, "cause": gone_gun, "force": g.game.forces.player, "final_damage_amount": 5}))
gone_unit = gone_gun.unit_number
check(g.storage.f3d.turret_fire_ticks[gone_unit] is not None, "the mined turret's throttle was set")
gone_gun.destroy()
take()
# Turret states (turrets.lua): where each turret points, its target, shots counted from its ammo
# (or from its hits, for a laser), sent every 6 ticks while it has a target.
laser = spawn("laser-turret", 3.0, 6.0, force="player")
tank_ = spawn("tank", 2.0, 9.0, force="player")
tank_.relative_turret_orientation = 0.5
turret.get_inventory(g.defines.inventory.turret_ammo).insert(lua.table_from({"name": "firearm-magazine", "count": 10}))
turret.orientation = 0.25
tick(61)
take()
check(g.storage.f3d.turret_fire_ticks[gone_unit] is None and g.storage.f3d.hit_fx_ticks[biter.unit_number] is None,
      "throttles don't stay in storage once they can't matter: a mined turret's, a living biter's")
turret.get_inventory(g.defines.inventory.turret_ammo).remove(lua.table_from({"name": "firearm-magazine", "count": 2}))
F["raise"]("on_entity_damaged", lua.table_from({"entity": biter, "cause": laser, "force": g.game.forces.player, "final_damage_amount": 5}))
tick(6)
ts = {rec[0]: rec for m in of_type(take(), "ts") for rec in m["l"]}
check(ts.get(turret.unit_number) == [turret.unit_number, 250, 2, 0, 8 * 256, 8 * 256],
      f"ts: a gun turret's orientation, the shots taken from its ammo and its target: {ts}")
check(ts.get(laser.unit_number, [0, 0, 0])[2] == 1, f"ts: a laser turret's hit counts as a shot: {ts}")
turret.shooting_target = None
tick(6)
ts = {rec[0]: rec for m in of_type(take(), "ts") for rec in m["l"]}
check(turret.unit_number not in ts, f"ts: an idle turret that didn't turn isn't reported: {ts}")
tick(120)
ts = {rec[0]: rec for m in of_type(take(), "ts") for rec in m["l"]}
check(ts.get(turret.unit_number) == [turret.unit_number, 250, 0, 0], f"ts: every turret now and then, idle ones too: {ts}")
check(ts.get(tank_.unit_number) == [tank_.unit_number, 500, 0, 1], f"ts: a vehicle's turret relative to its body and its gun: {ts}")
tank_.destroy()
laser.destroy()
turret.get_inventory(g.defines.inventory.turret_ammo).remove(lua.table_from({"name": "firearm-magazine", "count": 8}))
turret.orientation = 0
F["raise"]("on_entity_died", lua.table_from({"entity": biter}))
biter.destroy()
# Enemies' attacks (`en`): a biter in range of its attack target, a spitter at range and a worm's
# shooting target are listed with the target's position; one still walking to its target and one
# wandering aren't. (Each search its own, as before the movers' one search, /f3d-perf one_search, checked
# at the end: there a unit appearing shows with the movers' next search, a worm within 300 ticks.)
take()
g.storage.f3d_perf = lua.table_from({"one_search": False})
wall = spawn("stone-wall", 20.5, 6.5, force="player")
biter_at = spawn("small-biter", 21.2, 6.5, force="enemy")
biter_at.commandable.distraction_command = lua.table_from({"type": g.defines.command.attack, "target": wall})
biter_far = spawn("small-biter", 26.0, 6.5, force="enemy")
biter_far.commandable.distraction_command = lua.table_from({"type": g.defines.command.attack, "target": wall})
spitter = spawn("small-spitter", 20.5, 16.5, force="enemy")
spitter.commandable.command = lua.table_from({"type": g.defines.command.attack, "target": wall})
idle = spawn("small-biter", 22.0, 9.0, force="enemy")
idle.commandable.command = lua.table_from({"type": g.defines.command.wander})
worm = spawn("small-worm-turret", 18.0, 14.0, force="enemy")
worm.shooting_target = wall
tick(10)
en = of_type(take(), "en")
rows = sorted(tuple(en[-1]["l"][i:i + 3]) for i in range(0, len(en[-1]["l"]), 3)) if en else []
want = sorted((u, fixed(20.5), fixed(6.5)) for u in (biter_at.unit_number, spitter.unit_number, worm.unit_number))
check(len(en) == 1 and rows == want, f"en: attacking enemies and their targets, every 10 ticks: {en}")
g.storage.f3d_perf = None
for e in (biter_at, biter_far, spitter, idle, worm, wall):
    e.destroy()
tick(10)
check(not of_type(take(), "en"), "no en while nothing attacks")
# Its runs teach the budget what it costs (rate.read): a crowd near the focus is dearer than the
# job's first guess of 10 units.
crowd = [spawn("small-biter", -25.0 + i % 10, -25.0 + i // 10, force="enemy") for i in range(100)]
tick(40)
en_cost = g.storage.f3d.bud.cost["en"]
check(en_cost is not None and en_cost >= 10 and g.storage.f3d.bud.charged["en"] is None,
      f"en: its expected cost follows what it read (100 units: {en_cost})")
for e in crowd:
    e.destroy()
tick(10)
take()
doomed = spawn("wooden-chest", 13.5, 12.5, force="player")
F["raise"]("on_entity_died", lua.table_from({"entity": doomed}))
doomed.destroy()
F.construction_networks = lua.table_from([F.make_network(5, lua.table_from([0, 0, 0, 1]), lua.table())])
ghost = spawn("entity-ghost", 15.5, 12.5, force="player", inner_name="transport-belt")
F.printed = lua.table()
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})  # keep-alive: the client times out after 600 ticks
# Hit again: "under attack" lasts 300 ticks, and the weapons and enemies checks above take longer.
F["raise"]("on_entity_damaged", lua.table_from({"entity": hurt, "force": g.game.forces.enemy, "final_damage_amount": 10}))
# A pass over the entities starts at most every 600 ticks: start one now, whatever ran before.
g.package.loaded["scripts.alerts"].reset()
tick(130)
al = of_type(take(), "al")
kinds = {a[0]: a for a in al[-1]["l"]} if al else {}
check("no_ammo" in kinds and kinds["no_ammo"][2][0][3] == "gun-turret" and kinds["no_ammo"][2][0][4] == turret.unit_number,
      f"a turret without ammo: {kinds.get('no_ammo')}")
check("unplugged" in kinds and kinds["unplugged"][2][0][4] == asm_off.unit_number, f"a machine out of reach of poles: {kinds.get('unplugged')}")
check("no_power" not in kinds and "low_power" not in kinds and [e[4] for e in kinds["unplugged"][2]] == [asm_off.unit_number],
      f"no power and low power aren't alerts (Factorio has none; the icon comes from pw): {list(kinds)}")
check("attack" in kinds and kinds["attack"][2][0][4] == hurt.unit_number, f"under attack: {kinds.get('attack')}")
check("destroyed" in kinds and kinds["destroyed"][2][0][3] == "wooden-chest", f"destroyed: {kinds.get('destroyed')}")
check("no_material" in kinds and ["transport-belt", ghost.unit_number, "transport-belt"] in [e[3:] for e in kinds["no_material"][2]],
      f"a ghost in a construction area whose network lacks its item: {kinds.get('no_material')}")
check(not any("alert scan" in str(p) or "alert pass" in str(p) for p in F.printed.values()), f"no alert scan fails: {[p for p in F.printed.values() if 'alert' in str(p)]}")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(60 * 6)
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
al = of_type(take(), "al")
kinds = {a[0]: a for a in al[-1]["l"]} if al else {}
check("attack" not in kinds and "destroyed" in kinds, "under attack ends a few seconds after the last hit; destroyed stays longer")
# Owner's G19: an entity mined since the last pass leaves its alert at once, not when the next pass
# ends (seconds later on a big base), so no icon is left over empty ground.
turret.destroy()
tick(60)
al = of_type(take(), "al")
kinds = {a[0]: a for a in al[-1]["l"]} if al else {}
check("no_ammo" not in kinds and "unplugged" in kinds, f"a mined turret's alert goes before the next pass: {list(kinds)}")
for e in (asm_off, asm_dark, asm_low, hurt, ghost):
    e.destroy()
F.construction_networks = lua.table()

# Inserter, splitter, power switch, turret screens; a chest's limit bar.
fins = spawn("fast-inserter", 1.5, -1.5, force="player")
send(open_cmd(fins))
tick(2)
gui = guis(take(), fins)
check(gui and gui[-1]["kind"] == "inserter" and gui[-1]["ins"]["n"] == 5 and gui[-1]["ins"]["m"] == "whitelist",
      f"an inserter opens with its filters: {gui[-1:]}")
send({"t": "set_inserter", "u": fins.unit_number, "f": ["iron-plate", "", "nonsense"], "m": "blacklist", "use": 1, "st": 2})
tick(2)
gui = guis(take(), fins)
check(gui and gui[-1]["ins"]["f"][:3] == ["iron-plate", "", ""] and gui[-1]["ins"]["m"] == "blacklist" and gui[-1]["ins"]["use"] == 1
      and gui[-1]["ins"]["st"] == 2, f"set_inserter sets filters, mode and stack size: {gui[-1:]}")
spl = spawn("splitter", -1.0, 2.5, force="player")
send(open_cmd(spl))
send({"t": "set_splitter", "u": spl.unit_number, "i": "left", "o": "right", "f": "iron-plate"})
tick(2)
gui = guis(take(), spl)
check(gui and gui[-1]["spl"] == {"i": "left", "o": "right", "f": "iron-plate"}, f"set_splitter: {gui[-1:]}")
sw = spawn("power-switch", -3.0, -1.0, force="player")
send(open_cmd(sw))
send({"t": "set_switch", "u": sw.unit_number, "on": 1})
tick(2)
gui = guis(take(), sw)
check(gui and gui[-1]["kind"] == "switch" and gui[-1]["sw"] == 1, f"a power switch turns on: {gui[-1:]}")
turret = spawn("gun-turret", 4.0, -2.0, force="player")
send(open_cmd(turret))
puppet.insert(lua.table_from({"name": "firearm-magazine", "count": 5}))
tick(2)
gui = guis(take(), turret)
check(gui and gui[-1]["kind"] == "turret" and "turret_ammo" in gui[-1]["slots"], f"a turret shows its ammo slot: {gui[-1:]}")
send(open_cmd(box_chest))
send({"t": "set_bar", "u": box_chest.unit_number, "n": 4})
tick(2)
gui = guis(take(), box_chest)
check(gui and gui[-1].get("bar") == 4, f"a chest's limit bar: {gui[-1:]}")
send({"t": "set_inserter", "u": box_chest.unit_number, "st": 3})
tick(2)
check(any(m["text"] == "That isn't an inserter" for m in of_type(take(), "msg")), "inserter settings on a chest are refused")
send({"t": "inv_filter", "i": 7, "item": "iron-plate"})
tick(2)
sl = of_type(take(), "slots")
check(sl and sl[-1].get("fl") == [[7, "iron-plate"]], f"inv_filter sets a main inventory slot filter: {sl[-1:]}")
send({"t": "inv_filter", "i": 7, "item": ""})
tick(2)
sl = of_type(take(), "slots")
check(sl and "fl" not in sl[-1], "and an empty item clears it")
send({"t": "close"})
for e in (box_chest, asm_a, asm_b, fins, spl, sw, turret):
    e.destroy()
for e in list(F.surface.entities.values()):
    if e.type == "entity-ghost":
        e.destroy()
tick(2)
take()
# --- logistics: chests, roboports, the character's requests, networks, robot cargo -----------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(2)
take()
send({"t": "set_char_requests", "l": [["iron-plate", 1, -1]]})
tick(1)
msgs = take()
check(not of_type(msgs, "clog") and any(m["text"].startswith("No logistic requests yet") for m in of_type(msgs, "msg")),
      f"set_char_requests before the research says so: {msgs}")
g.game.forces.player.character_logistic_requests = True
tick(30)
clog = of_type(take(), "clog")
check(clog and clog[-1]["on"] == 1 and clog[-1]["trash"] == 0 and clog[-1]["l"] in ([], {}),
      f"clog: the character's requests arrive once researched: {clog}")
send({"t": "set_char_requests", "l": [["iron-plate", 100, 200], ["no-such-item", 1, 1]], "trash": 1})
tick(1)
clog = of_type(take(), "clog")
check(clog and clog[-1]["l"] == [["iron-plate", 100, 200]] and clog[-1]["trash"] == 1,
      f"set_char_requests sets requests (unknown items left out) and auto-trash: {clog}")
send({"t": "set_char_requests", "on": 0})
tick(1)
clog = of_type(take(), "clog")
check(clog and clog[-1]["on"] == 0 and clog[-1]["l"] == [["iron-plate", 100, 200]], "and turns them off, keeping them")
check(clog and [s_["f"] for s_ in clog[-1].get("sec", [])] == [[["iron-plate", "normal", 100, 200, "", -1]]],
      f"clog.sec: the character's sections one by one: {clog[-1:]}")
send({"t": "set_section", "u": 0, "i": 0, "g": "Mall"})
tick(1)
clog = of_type(take(), "clog")
check(clog and [s_["g"] for s_ in clog[-1]["sec"]] == ["", "Mall"] and isinstance(clog[-1].get("lgs"), (list, dict)),
      f"set_section u=0 adds a section to the character, in a group: {clog[-1:]}")
send({"t": "set_section", "u": 0, "i": 2, "on": 0, "f": [["iron-gear-wheel", "normal", 50, -1, "", -1]]})
tick(1)
clog = of_type(take(), "clog")
check(clog and clog[-1]["sec"][1]["on"] == 0 and clog[-1]["sec"][1]["f"][0][:3] == ["iron-gear-wheel", "normal", 50],
      f"set_section u=0 turns a character section off and sets its requests: {clog[-1:]}")
send({"t": "set_section", "u": 0, "i": 2, "del": 1})
tick(1)
clog = of_type(take(), "clog")
check(clog and len(clog[-1]["sec"]) == 1, f"set_section u=0 del removes the character's section: {clog[-1:]}")
send({"t": "set_char_color", "c": [10, 200, 30]})
tick(1)
ccol = of_type(take(), "ccol")
pc = g.storage.f3d.puppet.color
check(ccol and ccol[-1]["c"] == [10, 200, 30] and abs(pc.g - 200 / 255) < 1e-6,
      f"set_char_color sets the character's colour and ccol says so: {ccol}")

F.network = F.make_network(7, lua.table_from([3, 5, 1, 2]), lua.table_from([lua.table_from(["iron-plate", 50]), lua.table_from(["copper-plate", 80])]))
px, py = g.storage.f3d.puppet.position.x, g.storage.f3d.puppet.position.y
req = spawn("requester-chest", px + 2.5, py + 1.5, force="player")
sto = spawn("storage-chest", px + 3.5, py + 1.5, force="player")
port = spawn("roboport", px + 6.0, py + 3.0, force="player")
robot = spawn("logistic-robot", px + 1.5, py - 1.5, force="player")
robot.get_inventory(g.defines.inventory.robot_cargo).insert(lua.table_from({"name": "iron-plate", "count": 4}))
while g.game.tick % 60:
    tick(1)
msgs = take()
ln = of_type(msgs, "ln")
check(ln and ln[-1]["id"] == 7 and ln[-1]["log"] == [3, 5] and ln[-1]["con"] == [1, 2], f"ln: the network the character stands in: {ln[-1:]}")
rc = [v for m in of_type(msgs, "rc") for v in m["l"]]
check([robot.unit_number, iid["iron-plate"], 4] in [rc[i:i + 3] for i in range(0, len(rc), 3)], f"rc: what a robot near the focus carries: {rc}")

send(open_cmd(req))
send({"t": "set_requests", "u": req.unit_number, "l": [["iron-gear-wheel", 10, -1], ["wood", 5, 20]]})
tick(2)
gui = guis(take(), req)
lg = gui[-1].get("lg", {}) if gui else {}
check(lg.get("mode") == "requester" and lg.get("requests") == [["iron-gear-wheel", 10, -1], ["wood", 5, 20]],
      f"a requester chest's screen: its requests, set by set_requests: {lg}")
# Alt-mode: a mixed requester chest shows its first four requests, each a quarter of the icon (owner).
alt_mod = lua.eval('package.loaded["scripts.alt_mode"]')
icon2 = alt_mod.icon(req)
req5 = spawn("requester-chest", px + 2.5, py + 3.5, force="player")
lua.execute("""local e = ...
  local secs = e.get_logistic_sections()
  local sec = secs.get_section(1) or secs.add_section()
  local list = {}
  for _, name in ipairs({ "iron-gear-wheel", "wood", "transport-belt", "stone-furnace", "wooden-chest" }) do
    list[#list + 1] = { value = { type = "item", name = name, quality = "normal" }, min = 1 }
  end
  sec.filters = list""", req5)
icon5 = alt_mod.icon(req5)
as_list = lambda t: [t[1], t[2], list(t[3].values()) if t[3] else None] if t else None
check(as_list(icon2) == ["item", "iron-gear-wheel", ["wood"]] and as_list(icon5) == ["item", "iron-gear-wheel", ["wood", "transport-belt", "stone-furnace"]],
      f"Alt-mode: a requester chest's first four requests: {as_list(icon2)} {as_list(icon5)}")
req5.destroy()
check(lg.get("net", {}).get("items") == [["copper-plate", 80], ["iron-plate", 50]] and "trash" in gui[-1]["slots"],
      f"and its network's contents (most first) and its trash slots: {gui[-1:]}")
lc = gui[-1].get("lc", {}) if gui else {}
check(lc.get("tu") == 0 and lc.get("rb") == 0 and lc.get("sec", [{}])[0].get("f", [[None]])[0][::2] == ["iron-gear-wheel", 10, ""],
      f"lc: the requester's sections, trash unrequested and request from buffers (machine_info.lua): {lc}")
send({"t": "set_chest_logistics", "u": req.unit_number, "tu": 1, "rb": 1})
send({"t": "set_section", "u": req.unit_number, "i": 0})
tick(2)
gui = guis(take(), req)
lc = gui[-1].get("lc", {}) if gui else {}
check(lc.get("tu") == 1 and lc.get("rb") == 1 and len(lc.get("sec", [])) == 2,
      f"set_chest_logistics ticks both boxes; set_section adds a section to a chest: {lc}")
send({"t": "set_section", "u": req.unit_number, "i": 2, "g": "Bus"})
tick(2)
gui = guis(take(), req)
lc = gui[-1].get("lc", {}) if gui else {}
check([sec.get("g") for sec in lc.get("sec", [])] == ["", "Bus"], f"set_section g puts a section in a logistic group: {lc}")
send({"t": "close"})
send(open_cmd(req))
tick(2)
gui = guis(take(), req)
check(gui and "Bus" in gui[0].get("lgs", []), f"lgs: the force's logistic groups ride with the first message: {gui[:1]}")
send(open_cmd(sto))
send({"t": "set_storage_filter", "u": sto.unit_number, "item": "iron-plate"})
send({"t": "set_requests", "u": sto.unit_number, "l": [["wood", 1, -1]]})
tick(2)
msgs = take()
gui = guis(msgs, sto)
check(gui and gui[-1]["lg"]["mode"] == "storage" and gui[-1]["lg"]["filter"] == "iron-plate", f"a storage chest's filter is set and shown: {gui[-1:]}")
check(any(m["text"] == "That chest doesn't take requests" for m in of_type(msgs, "msg")), "a storage chest takes no requests")
send({"t": "set_storage_filter", "u": sto.unit_number, "item": ""})
tick(2)
gui = guis(take(), sto)
check(gui and gui[-1]["lg"]["filter"] == "", "and cleared")
send(open_cmd(port))
tick(2)
gui = guis(take(), port)
check(gui and gui[-1]["kind"] == "roboport" and {"robots", "repair"} <= set(gui[-1]["slots"]) and gui[-1]["lg"]["net"]["id"] == 7,
      f"a roboport's screen: robots, repair packs and its network: {gui[-1:]}")
send({"t": "close"})
for e in (req, sto, port, robot):
    e.destroy()
F.network = None
tick(60)
ln = of_type(take(), "ln")
check(ln and ln[-1]["id"] == 0 and "log" not in ln[-1], f"ln: id 0 outside any network: {ln[-1:]}")

# --- qualities, for cycling the one to build with ---------------------------------------------------
lua.eval("function() storage.f3d.techs_dirty = true end")()
tick(2)  # reliable: out with the next tick's flush
quals = of_type(take(), "quals")
check(quals and quals[-1]["l"] == [["normal", 0, 1, "ffffff"], ["uncommon", 1, 1, "ffffff"], ["rare", 2, 1, "ffffff"],
                                  ["epic", 3, 0, "ffffff"], ["legendary", 5, 0, "ffffff"]],
      f"quals: the qualities by level, which are unlocked, their colours; hidden ones left out: {quals[-1:]}")

# --- two clients on one server ---------------------------------------------------------------------
PORT_B = CLIENT_PORT + 1


def take_by_port():
    """Everything sent, by port; reliable numbering checked per client."""
    by, seq = {}, {}
    for item in F.take_sent().values():
        port, data = item[1], sent_data(item)
        for msg in protocol.split_datagram(data):
            for problem in protocol.problems(msg):
                check(False, f"protocol: {problem}")
            if "r" in msg:
                if msg["t"] == "welcome":
                    seq[port] = msg["r"]
                elif port in seq:
                    check(msg["r"] == seq[port], f"reliable gap on port {port}: {msg['r']} after {seq[port] - 1}")
                seq[port] = msg["r"] + 1
            by.setdefault(port, []).append(msg)
    return by


take()
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
send({"t": "hello", "v": 1, "sid": "b", "w": 0, "z": 1}, port=PORT_B)
tick(3)
by = take_by_port()
first, second = by.get(CLIENT_PORT, []), by.get(PORT_B, [])
a_unit = g.storage.f3d.puppet.unit_number
welcome_b = of_type(second, "welcome")
check(welcome_b and not of_type(first, "welcome") and welcome_b[0]["u"] != a_unit and of_type(second, "protos"),
      f"two clients: the second gets a welcome, prototypes and a character of its own; the first goes on: {welcome_b}")
b_state = g.storage.f3d_extra[PORT_B]
check(b_state and b_state.puppet and b_state.puppet.unit_number == welcome_b[0]["u"], "and its state lives in storage.f3d_extra by port")
send({"t": "sub", "c": [[0, 0]]}, port=PORT_B)
send({"t": "walk", "d": 4}, port=PORT_B)
tick(4)
by = take_by_port()
check(of_type(by.get(PORT_B, []), "chunk") and not of_type(by.get(CLIENT_PORT, []), "chunk"),
      "each client gets the chunks it subscribed to")
check(b_state.puppet.walking_state.walking and not g.storage.f3d.puppet.walking_state.walking,
      "each client walks its own character")
check(any(m["u"] == a_unit for m in of_type(by.get(CLIENT_PORT, []), "me")) and any(m["u"] == b_state.puppet.unit_number for m in of_type(by.get(PORT_B, []), "me")),
      "and each hears about its own character in `me`")
made = spawn("wooden-chest", 3.5, 3.5, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": made}))
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
send({"t": "hello", "v": 1, "sid": "b", "w": 1, "z": 1}, port=PORT_B)
tick(2)
by = take_by_port()
adds = {port: [m for m in of_type(msgs, "add") if m["e"][0] == made.unit_number] for port, msgs in by.items()}
check(adds.get(CLIENT_PORT) and adds.get(PORT_B), f"a building event reaches both clients: {sorted(adds)}")
# Each client's movers come from its own focus (the list found was once shared between clients).
far_car = spawn("car", 2000.5, 2000.5, force="player")
send({"t": "focus", "x": 2000 * 256, "y": 2000 * 256, "r": 32}, port=PORT_B)
send({"t": "focus", "x": int(g.storage.f3d.puppet.position.x * 256), "y": int(g.storage.f3d.puppet.position.y * 256), "r": 32})
tick(10)
take_by_port()
# And each searches only its own area when due: one shared list made every send of the other
# client search again, every few ticks.
mover_searches = lua.eval("""function(surface)
  local counter = {n = 0}
  local types = package.loaded["scripts.registry"].mover_types()
  local find = surface.find_entities_filtered
  surface.find_entities_filtered = function(f)
    if f.area and f.type == types then counter.n = counter.n + 1 end
    return find(f)
  end
  counter.restore = function() surface.find_entities_filtered = find end
  return counter
end""")(F.surface)
tick(40)
mover_searches.restore()
check(mover_searches.n <= 12, f"two clients: movers are searched for about every 8 ticks each ({mover_searches.n} in 40 ticks)")
by = take_by_port()
mv_units = {port: {rec[0] for m in of_type(msgs, "mv") for rec in m["l"]} for port, msgs in by.items()}
check(far_car.unit_number in mv_units.get(PORT_B, set()) and far_car.unit_number not in mv_units.get(CLIENT_PORT, set()),
      f"two clients: each gets the movers round its own focus ({len(mv_units.get(CLIENT_PORT, []))} / {len(mv_units.get(PORT_B, []))})")
far_car.destroy()
b_unit = b_state.puppet.unit_number
send({"t": "bye"}, port=PORT_B)
tick(1)
check(len(g.storage.f3d_extra) == 0 and g.storage.f3d.client and g.storage.f3d.client.port == CLIENT_PORT,
      "bye drops only the second client")
send({"t": "hello", "v": 1, "sid": "b", "w": 0}, port=PORT_B)
tick(3)
by = take_by_port()
check(of_type(by.get(PORT_B, []), "welcome") and of_type(by[PORT_B], "welcome")[0]["u"] == b_unit,
      "the same client coming back gets its character back")
send({"t": "bye"}, port=PORT_B)
old_subs = [[int(v) for v in k.split(",")] for k in g.storage.f3d.subs.keys()]
old_focus = {"x": int(g.storage.f3d.focus.x * 256), "y": int(g.storage.f3d.focus.y * 256), "r": int(g.storage.f3d.focus.r)}
F.multiplayer = False
send({"t": "hello", "v": 1, "sid": "c", "w": 0}, port=PORT_B + 1)
tick(1)
check(len(g.storage.f3d_extra) == 0 and g.storage.f3d.client.port == PORT_B + 1,
      "in single-player a new port takes over instead of adding a client (the game plays one character)")
send({"t": "bye"}, port=PORT_B + 1)
tick(1)
F.multiplayer = True
take_by_port()
send({"t": "hello", "v": 1, "sid": "s1", "w": 0})  # the first client again, as the tests below expect
tick(3)
send({"t": "sub", "c": old_subs})
send({"t": "focus", **old_focus})
tick(30)
take()
made.destroy()

# --- the other planets: demolishers, lightning, Gleba, Aquilo, travel --------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(2)
take()
px, py = g.storage.f3d.puppet.position.x, g.storage.f3d.puppet.position.y
demo = F.add_segmented_unit(F.surface, "small-demolisher", "small-demolisher-segment",
                            lua.table_from([lua.table_from([px + 6, py, 0.25]), lua.table_from([px + 11, py, 0.25])]))
tick(2)
seg = [r for m in of_type(take(), "seg") for r in m["l"] if r[0] == demo.unit_number]
check(seg and seg[-1][1] == eid["small-demolisher"] and seg[-1][2] == [eid["small-demolisher-segment"], fixed(px + 6), fixed(py), 250,
                                                                     eid["small-demolisher-segment"], fixed(px + 11), fixed(py), 250],
      f"seg: a demolisher's segments in order, with their orientation: {seg[-1:]}")
F.surface.segmented = lua.table_from([])
tick(2)
seg = of_type(take(), "seg")
check(seg and seg[-1]["l"] in ([], {}), "and an empty seg once it is gone")

# A lightning entity stands where its bolt starts, 25 tiles up (y) and up to 15 aside (x) of
# where it strikes: one pulled onto the rod, one striking the ground, and one far from the focus.
# (On a planet with lightning: the fake's Nauvis has none, so it is listed here; the planets without it
# are checked at the end, /f3d-perf lightning_planets.)
F.planet_data.lightning = lua.table_from(["fulgora", "nauvis"])
forget(g.package.loaded["scripts.planets"].tick, "lightning_cache")
rod = spawn("lightning-rod", px + 10.5, py + 10.5, force="player")
bolt = spawn("lightning", px + 14.5, py + 10.5 - 24)
stray = spawn("lightning", px - 18.5, py - 12.5 - 23)
far = spawn("lightning", px + 120.5, py - 25)
# No lightning seen yet: the search idles at every 12th tick.
tick(12)
lt = [r for m in of_type(take(), "lt") for r in m["l"]]
check(sorted(lt) == sorted([[fixed(px + 10.5), fixed(py + 10.5), 1], [fixed(px - 18.5), fixed(py - 10.5), 0]]),
      f"lt: strikes near the focus on the ground below the bolt, or on the rod that caught them: {lt}")
# Lightning was seen, so the next strike is looked for at the full rate (every 3 ticks).
second = spawn("lightning", px - 4.5, py - 30.5)
while g.game.tick % 3:
    tick(1)
tick(3)
lt = [r for m in of_type(take(), "lt") for r in m["l"]]
check(lt == [[fixed(px - 4.5), fixed(py - 5.5), 0]], f"lt: once lightning was seen, strikes are looked for every 3 ticks again: {lt}")
second.destroy()
tick(3)
check(not of_type(take(), "lt"), "each strike is sent once")
for e in (bolt, stray, far):
    e.destroy()
F.planet_data.lightning = lua.table_from(["fulgora"])
forget(g.package.loaded["scripts.planets"].tick, "lightning_cache")

plant = spawn("yumako-tree", px + 4.5, py + 4.5, force="player", tick_grown=g.game.tick + 300)
tower = spawn("agricultural-tower", px + 2.5, py + 6.5, force="player")
tower.owned_plants = lua.table_from([plant])
pod = spawn("small-stomper-pentapod", px + 8.0, py - 6.0, force="enemy")
nest = spawn("gleba-spawner", px + 14.5, py - 8.5, force="enemy")
nest.units = lua.table_from([pod])
cold = spawn("inserter", px - 3.5, py + 3.5, force="player", frozen=True)
F["raise"]("on_tower_planted_seed", lua.table_from({"tower": tower, "plant": plant, "seed": lua.table_from({"name": "yumako-seed"})}))
tick(1)
check([m for m in of_type(take(), "add") if m["e"][2:4] == [fixed(px + 4.5), fixed(py + 4.5)]], "a plant the tower planted is added to the world")
while g.game.tick % 60:
    tick(1)
msgs = take()
pg = [v for m in of_type(msgs, "pg") for v in m["l"]]
groups = [pg[i:i + 4] for i in range(0, len(pg), 4)]
mine = [gr for gr in groups if gr[1:3] == [fixed(px + 4.5), fixed(py + 4.5)]]
check(mine and 400 <= mine[0][3] <= 600, f"pg: a plant halfway grown: {mine}")
sp = [v for m in of_type(msgs, "sp") for v in m["l"]]
check([nest.unit_number, 1] in [sp[i:i + 2] for i in range(0, len(sp), 2)], f"sp: a spawner and its units out: {sp}")
fz = [v for m in of_type(msgs, "fz") for v in m["l"]]
check(cold.unit_number in fz, f"fz: a frozen inserter: {fz}")
tick(4)
legs = [r for m in of_type(take(), "legs") for r in m["l"] if r[0] == pod.unit_number]
check(legs and len(legs[-1][1]) == 10 and legs[-1][1][:2] == [fixed(px + 8.0 - 3.7), fixed(py - 6.0 - 5.1)],
      f"legs: a pentapod's five feet, from the spider-leg entities after it (no get_spider_legs on a spider unit): {legs[-1:]}")
send(open_cmd(tower))
tick(2)
gui = guis(take(), tower)
check(gui and gui[-1].get("ag") == {"plants": 1, "ready": 0}, f"an agricultural tower's screen counts its plants: {gui[-1:]}")
send({"t": "close"})

puppet = g.storage.f3d.puppet
puppet.get_main_inventory().insert(lua.table_from({"name": "yumako", "count": 5}))
lua.eval("""function(inv)
  for i = 1, #inv do
    if inv[i].valid_for_read and inv[i].name == "yumako" then inv[i].spoil_percent = 0.25 end
  end
end""")(puppet.get_main_inventory())
tick(31)
slots = [m["l"]["main"] for m in of_type(take(), "slots")]
check(slots and ["yumako", 5, "normal", 750] in slots[-1], f"slots: a spoiling stack carries its freshness: {[s for s in (slots[-1] if slots else []) if s]}")
belt2 = spawn("transport-belt", px + 1.5, py + 2.5, force="player")
F.put_on_belt(belt2, 1, "yumako", 0.5, 4242, 0.5)
tick(12)
bf = [v for m in of_type(take(), "bf") for v in m["l"]]
check([4242, 500] in [bf[i:i + 2] for i in range(0, len(bf), 2)], f"bf: freshness of spoiling items on belts: {bf[:8]}")

silo = spawn("wooden-chest", px + 3.5, py - 3.5, force="player")
F["raise"]("on_rocket_launch_ordered", lua.table_from({"rocket": silo, "rocket_silo": silo}))
cargo = spawn("cargo-pod", px - 2.0, py - 2.0, force="player")
# No pod seen yet: the search idles at every 30th tick.
tick(1)
while g.game.tick % 30:
    tick(1)
msgs = take()
rk = of_type(msgs, "rk")
check(rk and rk[-1]["u"] == silo.unit_number and rk[-1]["s"] == "nauvis", f"rk: a rocket launch at a silo: {rk}")
cp = [r for m in of_type(msgs, "cp") for r in m["l"] if r[0] == cargo.unit_number]
check(cp and cp[-1][1:] == ["awaiting_launch", "invalid", ""], f"cp: a cargo pod near the focus: {cp}")
# Coming down, it says where it lands: the station's place, so the client drops it straight onto it.
pad = spawn("wooden-chest", px + 6.5, py + 2.5, force="player")
F.entity_data(cargo).cargo_pod_state = "descending"
F.entity_data(cargo).cargo_pod_destination = lua.table_from({"type": g.defines.cargo_destination.station, "station": pad})
tick(60)  # 60: the platform checks further on wait for ticks on the 60s
cp = [r for m in of_type(take(), "cp") for r in m["l"] if r[0] == cargo.unit_number]
check(cp and cp[-1][4:] == [int((px + 6.5) * 256), int((py + 2.5) * 256)], f"cp: a descending pod says where it lands: {cp[-1:]}")
F.entity_data(cargo).cargo_pod_state = "awaiting_launch"
F.entity_data(cargo).cargo_pod_destination = lua.table_from({"type": g.defines.cargo_destination.invalid})
pad.destroy()
send({"t": "land"})
tick(1)
check(any("Land from a platform" in m["text"] for m in of_type(take(), "msg")), "land on a planet is refused")
for e in (rod, plant, tower, pod, nest, cold, belt2, silo, cargo):
    e.destroy()
tick(61)
take()

# --- strangers, junk, resync ---------------------------------------------------------------------
F.packet("not json at all", CLIENT_PORT)
send({"t": "walk", "d": 0}, port=40000)
send({"t": "nonsense"})
tick(2)
check(not puppet.walking_state.walking, "commands from another port are ignored")
take()
send({"t": "resync"})
tick(10)
msgs = take()
check({(m["cx"], m["cy"]) for m in of_type(msgs, "chunk")} == {(0, 0), (1, 0), (9, 9)}, "resync resends subscribed chunks")
send({"t": "resync", "full": 0, "c": [[1, 0], [5, 5], "junk"]})
tick(10)
msgs = take()
resent = [(m["cx"], m["cy"]) for m in of_type(msgs, "chunk")]
# The mod also refreshes one subscribed chunk every 5 s, which may land in these ticks.
check((1, 0) in resent and (5, 5) not in resent and len(resent) <= 2,
      f"resync with a list resends those subscribed chunks, without waiting for the cooldown: {resent}")

# --- /f3d-status from RCON or the server console -------------------------------------------------
F.printed = lua.table()
F.command(lua.table_from({"name": "f3d-status"}))
printed = list(F.printed.values())
check(any(p.startswith("RCON [Zenith] client on port") for p in printed), "/f3d-status answers RCON")
check(any(p.startswith("STDOUT [Zenith] character at") for p in printed), "/f3d-status prints to the server console")
check(any("profiling off" in str(p) for p in printed), "/f3d-status says profiling is off")
check(not any("speaks protocol" in str(p) for p in printed), "/f3d-status says nothing of the protocol when the client's is the bridge's")
send({"t": "hello", "v": 2, "sid": "s1", "w": 1})
tick(1)
F.printed = lua.table()
F.command(lua.table_from({"name": "f3d-status"}))
check(any("the client speaks protocol 2 and this bridge 1" in str(p) for p in F.printed.values()),
      "/f3d-status says when the client speaks another protocol (its hello's v)")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(1)
F.printed = lua.table()
F.commands["f3d-profile"](lua.table_from({"name": "f3d-profile"}))
before = F.profilers
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(601)
F.printed = lua.table()
F.command(lua.table_from({"name": "f3d-status"}))
lines = [p for p in F.printed.values()]
check(F.profilers > before and any("RCON" in str(p) for p in lines) and len(lines) > 12,
      f"with /f3d-profile on, /f3d-status reports a time for every module ({F.profilers - before} profilers, {len(lines)} lines)")
# A trace beside it (/f3d-profile trace N, as tools/bench does) times the same run: each module
# still runs once a tick (each timed its own run, so the bridge ran four times a tick).
profile_mod = lua.eval('package.loaded["scripts.profile"]')
runs = lua.eval("{n = 0}")
profile_mod.trace(3)
profile_mod.run("probe", lua.eval("function(r) r.n = r.n + 1 end"), runs)
profile_mod.run("outer", lua.eval("function(p, r) p.run('inner', function() r.n = r.n + 10 end) end"), profile_mod, runs)
profile_mod.end_tick()
check(runs.n == 11, f"profiling and a trace at once run each step once, nested ones too: {runs.n} (11 is once each)")
profile_mod.trace(0)
F.commands["f3d-profile"](lua.table_from({"name": "f3d-profile"}))
take()

# --- space platforms -------------------------------------------------------------------------------
def platform_console(parameter):
    before = len(F.printed)
    F.commands["f3d-platform"](lua.table_from({"name": "f3d-platform", "parameter": parameter}))
    return [str(p) for p in list(F.printed.values())[before:]]


def next_plat():
    """Ticks to the next platform message and returns it."""
    tick(1)
    while g.game.tick % 60:
        tick(1)
    plats = of_type(take(), "plat")
    return plats[-1] if plats else {}


send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(1)
take()
puppet = g.storage.f3d.puppet
lines = platform_console("new")
check(any("platform 1 (Platform 1) built in orbit of nauvis" in l for l in lines), f"/f3d-platform new builds a platform: {lines}")
plat = g.game.forces.player.platforms[1]
check(plat.hub is not None and plat.surface.name == "platform-1", "with the starter pack applied it has a hub and a surface")
pm = next_plat()
rec = (pm.get("l") or [{}])[0]
check(pm.get("on") == 0 and pm.get("here") == "nauvis" and pm.get("dest") == ["nauvis", "vulcanus"],
      f"plat: on a planet, with the unlocked destinations: {pm}")
check(rec.get("i") == 1 and rec.get("st") == "paused" and rec.get("loc") == "nauvis" and rec.get("hub") == plat.hub.unit_number
      and rec.get("pa") == 1 and "from" not in rec and "sch" not in rec, f"plat: a new platform waits in orbit, paused: {rec}")
check(rec.get("w") == 1250000, f"plat: the platform's mass (weight, kg) for the remote view's info panel: {rec}")
nauvis_s = g.game.planets.nauvis.surface
check(pm.get("k") == g.game.tick
      and pm.get("days") == [["nauvis", nauvis_s.ticks_per_day, round(nauvis_s.daytime * 100000) % 100000, 1 if nauvis_s.freeze_daytime else 0]],
      f"plat: the game's tick and the day of the planet in the platform's sky (its surface's ticks_per_day, daytime): {pm}")
# Its map seen from Nauvis (mtr si): a platform has no radars and is seen whole, as cov says.
send({"t": "mtr", "si": plat.surface.index})
tick(1)
plat_mtr = of_type(take(), "mtr")
check(plat_mtr and plat_mtr[0].get("all") == 1 and plat_mtr[0].get("si") == plat.surface.index,
      f"mtr on a platform's map: all = 1, the whole platform seen: {plat_mtr[:1]}")

# #5: the remote view looks at the platform from Nauvis: its world is streamed (surface, view = 1),
# world-changing commands wait, and si 0 goes back to the character's surface.
send({"t": "view", "si": plat.surface.index, "x": 3 * 256, "y": 4 * 256})
tick(2)
msgs = take()
vs = of_type(msgs, "surface")
check(vs and vs[0]["si"] == plat.surface.index and vs[0].get("view") == 1 and vs[0]["x"] == 3 * 256 and puppet.surface.name == "nauvis",
      f"view: the platform's world is streamed while the character stays on Nauvis: {vs}")
# H25: a full resync (lost packets) keeps the remote view on that surface instead of dropping back
# to the character's planet.
lua.eval("function() storage.f3d.resync_tick = -1000000 end")()
send({"t": "resync", "full": 1})
tick(2)
take()
check(lua.eval("function() return storage.f3d.view_si end")() == plat.surface.index,
      "a full resync keeps the remote view of another surface (H25)")
# #12: from the remote view, building on that surface places a ghost there (never the item),
# while what needs the character's hands still waits.
send({"t": "sub", "c": [[0, 0]]})
tick(2)
take()
send({"t": "build", "item": "wooden-chest", "x": 5 * 256 + 128, "y": 2 * 256 + 128, "d": 0})
tick(1)
msgs = take()
ghosts = [e for e in plat.surface.entities.values() if e.name == "entity-ghost" and e.ghost_name == "wooden-chest"]
check(len(ghosts) == 1 and not any(e.name == "wooden-chest" for e in plat.surface.entities.values())
      and not any(e.name == "entity-ghost" and e.ghost_name == "wooden-chest" for e in F.surface.entities.values()),
      f"view: building from the remote view puts a ghost on the shown surface: {texts(msgs)}")
check(any(m["e"][1] == eid["entity-ghost"] for m in of_type(msgs, "add")), "view: the ghost reaches the client")
# F6: the platform is uncharted (a headless server charts nothing), so the script check stands in
# for the manual one, but not over empty space or against the platform's conditions: those ghosts
# would never be built.
send({"t": "build", "item": "wooden-chest", "x": 10 * 256 + 128, "y": 2 * 256 + 128, "d": 0})
puppet.insert(lua.table_from({"name": "burner-inserter", "count": 1}))
plat.surface.props.gravity = 0  # a platform's, as in the game
send({"t": "build", "item": "burner-inserter", "x": 6 * 256 + 128, "y": 2 * 256 + 128, "d": 0})
tick(1)
plat.surface.props.gravity = 10
said = texts(take())
ghost_names = sorted(e.ghost_name for e in plat.surface.entities.values() if e.name == "entity-ghost")
check(ghost_names == ["wooden-chest"] and "Can't place that there" in said and any("gravity" in t for t in said),
      f"view: no ghost on empty space, nor one the platform's gravity forbids (F6): {ghost_names} {said}")
# F6: modules from the remote view: a ghost keeps them in its insert plan.
send({"t": "build", "item": "assembling-machine-1", "x": 5 * 256 + 128, "y": -5 * 256 - 128, "d": 0})
tick(1)
take()
am_ghost = next((e for e in plat.surface.entities.values() if e.name == "entity-ghost" and e.ghost_name == "assembling-machine-1"), None)
check(am_ghost is not None, "view: an assembler's ghost on the platform's foundation")
mod_at = {"u": am_ghost.unit_number, "p": eid["entity-ghost"], "x": fixed(am_ghost.position.x), "y": fixed(am_ghost.position.y)} if am_ghost else {}
for _ in range(3):
    send({"t": "modreq", "item": "speed-module", **mod_at})
tick(1)
said = texts(take())
plan = [(p.id.name, at.inventory, at.stack) for p in am_ghost.insert_plan.values() for at in p["items"].in_inventory.values()] if am_ghost else []
check(sorted(plan) == [("speed-module", g.defines.inventory.crafter_modules, 0), ("speed-module", g.defines.inventory.crafter_modules, 1)] and "Module requested: 2 of 2 slots" in said
      and "The module slots are full" in said, f"modreq: a ghost's insert plan gets a module per slot, no more (F6): {plan} {said}")
send({"t": "modreq", "item": "wooden-chest", **mod_at})
send({"t": "modreq", "clr": 1, "s": 1, **mod_at})
tick(1)
said = texts(take())
plan = [(p.id.name, at.stack) for p in am_ghost.insert_plan.values() for at in p["items"].in_inventory.values()] if am_ghost else []
check(plan == [("speed-module", 1)] and "That isn't a module" in said, f"modreq: clr takes a slot's request back; no chests in module slots: {plan} {said}")
# The platform's map past its generated chunks is empty, not an error (F6: get_tile there is invalid).
send({"t": "map", "si": plat.surface.index, "cx1": 10, "cy1": 10, "res": 8})
tick(2)
msgs = take()
charts = of_type(msgs, "chart")
check(charts and charts[0]["n"] == 0 and not any("Map error" in t for t in texts(msgs)),
      f"map: an ungenerated chunk of a platform charts as unknown: {charts} {texts(msgs)}")
send({"t": "mine", "u": 0, "p": 0, "x": 2 * 256, "y": 2 * 256})
tick(1)
check(any("another surface" in x for x in texts(take())), "view: mining by hand waits while another surface is shown")
check(g.storage.f3d.act_si is None, "view: the surface override ends with the command")
send({"t": "view", "si": 0})
tick(2)
vs = of_type(take(), "surface")
check(vs and vs[0]["surface"] == "nauvis" and "view" not in vs[0], f"view 0: back to the character's surface: {vs}")

send({"t": "plat_board", "i": 1})
tick(2)
msgs = take()
surf = of_type(msgs, "surface")
check(surf and surf[0]["surface"] == "platform-1" and surf[0]["pf"] == 1 and "planet" not in surf[0] and surf[0]["si"] == plat.surface.index,
      f"plat_board: the character moves to the platform and the client is told (surface): {surf}")
check(puppet.surface.name == "platform-1" and not of_type(msgs, "welcome"), "a surface change is not a new handshake")
check(len(list(g.storage.f3d.subs.items())) == 0, "the old surface's subscriptions are dropped")
send({"t": "sub", "c": [[0, 0], [-1, -1]]})
tick(6)
msgs = take()
chunk00 = [m for m in of_type(msgs, "chunk") if (m["cx"], m["cy"]) == (0, 0)]
tile_ids = set(chunk00[0]["tiles"][0::2]) if chunk00 else set()
check(tile_ids == {tile_id["space-platform-foundation"], tile_id["empty-space"]}, f"a platform chunk: foundation and empty space: {tile_ids}")
hub_recs = [e for m in of_type(msgs, "ents") for e in m["e"] if e[1] == {r[1]: r[0] for r in protos}["space-platform-hub"]]
check(len(hub_recs) == 1 and hub_recs[0][0] == plat.hub.unit_number, f"the hub is in the platform's snapshot: {hub_recs}")
pm = next_plat()
check(pm.get("on") == 1 and "here" not in pm, f"plat: on the platform, on names it: {pm}")

send({"t": "plat_go", "i": 1, "to": "vulcanus"})
send({"t": "plat_go", "i": 1, "to": "aquilo"})
send({"t": "plat_go", "i": 7, "to": "vulcanus"})
tick(1)
msgs = take()
check("Can't travel to aquilo" in texts(msgs) and "No such platform" in texts(msgs), f"plat_go refuses unknown places and platforms: {texts(msgs)}")
rec = next_plat()["l"][0]
check(rec.get("sch") == {"c": 1, "l": ["vulcanus"]} and rec.get("pa") == 0 and rec.get("st") == "waiting_at_station",
      f"plat_go: a one-stop schedule and unpaused: {rec}")
# H7: stopped, a platform names where its schedule takes it next.
check(rec.get("loc") == "nauvis" and rec.get("nx") == "vulcanus", f"plat: waiting at nauvis, the next stop: {rec}")
pdata = F.platform_data[plat]
pdata.schedule = lua.table_from({"current": 2, "records": lua.table_from([lua.table_from({"station": "vulcanus"}),
                                                                          lua.table_from({"station": "nauvis"})])})
rec = next_plat()["l"][0]
check(rec.get("nx") == "vulcanus", f"plat: waiting at its current stop, the next record: {rec}")
pdata.schedule = lua.table_from({"current": 1, "records": lua.table_from([lua.table_from({"station": "nauvis"})])})
rec = next_plat()["l"][0]
check("nx" not in rec, f"plat: a schedule of only here has no next stop: {rec}")
# Done at its stop, the schedule already on the next one (Factorio's waiting_for_departure, while
# cargo is still on its way): that one is where it goes.
pdata.schedule = lua.table_from({"current": 2, "records": lua.table_from([lua.table_from({"station": "nauvis"}),
                                                                          lua.table_from({"station": "vulcanus"})])})
rec = next_plat()["l"][0]
check(rec.get("loc") == "nauvis" and rec.get("nx") == "vulcanus" and "to" not in rec,
      f"plat: about to leave, the current record is the next stop: {rec}")
pdata.schedule = lua.table_from({"current": 1, "records": lua.table_from([lua.table_from({"station": "vulcanus"})])})
F.platform_travel(plat, "nauvis-vulcanus", 0.25, 2.5)
pm = next_plat()
rec = pm["l"][0]
days = {d[0]: d for d in pm.get("days", [])}
vday = days.get("vulcanus")
vsurf = lua.eval("function() return game.planets.vulcanus.surface end")()
# Without a surface, the prototype's day-night-cycle and the time of day from the tick.
want_v = ["vulcanus", 25000, 20000, 0] if vsurf else ["vulcanus", 5400, round(g.game.tick % 5400 / 5400 * 100000) % 100000, 0]
check(sorted(days) == ["nauvis", "vulcanus"] and vday == want_v,
      f"plat: both ends of the way have their day (vulcanus {'with' if vsurf else 'without'} a surface): {pm.get('days')}")
check(rec.get("from") == "nauvis" and rec.get("to") == "vulcanus" and rec.get("d") == 250 and rec.get("len") == 15000
      and rec.get("sp") == 150 and rec.get("st") == "on_the_path" and "loc" not in rec,
      f"plat: travelling, with the way done in thousandths and the speed in km/s: {rec}")
# Owner's G9: a platform sent the other way along its connection (to its `from` end) counts its
# distance down in 2.1.23; the journey reads from where it left to where it goes, d counting up.
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})  # keep-alive: these checks take a few seconds
pdata = F.platform_data[plat]
pdata.schedule = lua.table_from({"current": 1, "records": lua.table_from([lua.table_from({"station": "nauvis"})])})
F.platform_travel(plat, "nauvis-vulcanus", 0.75, 2.5)
rec = next_plat()["l"][0]
check(rec.get("from") == "vulcanus" and rec.get("to") == "nauvis" and rec.get("d") == 250 and rec.get("len") == 15000,
      f"plat: heading to the connection's from end, the journey is turned round: {rec}")
# A stop that is neither end (a trip of several legs): the way distance moves says it.
pdata.schedule = lua.table_from({"current": 1, "records": lua.table_from([lua.table_from({"station": "solar-system-edge"})])})
pdata.distance = 0.8
rec = next_plat()["l"][0]
check(rec.get("from") == "nauvis" and rec.get("d") == 800, f"plat: distance going up reads forwards: {rec}")
pdata.distance = 0.7
rec = next_plat()["l"][0]
check(rec.get("from") == "vulcanus" and rec.get("to") == "nauvis" and rec.get("d") == 300, f"plat: distance going down reads backwards: {rec}")
rec = next_plat()["l"][0]
check(rec.get("from") == "vulcanus" and rec.get("d") == 300, f"plat: and stays so while it stands still: {rec}")
pdata.schedule = lua.table_from({"current": 1, "records": lua.table_from([lua.table_from({"station": "vulcanus"})])})
pdata.distance = 0.25
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
send({"t": "plat_board", "i": 0})
tick(1)
check("The platform must be stopped at a planet to drop to it" in texts(take()) and puppet.surface.name == "platform-1",
      "plat_board 0 while travelling is refused")
F.platform_arrive(plat, "vulcanus")
send({"t": "plat_board", "i": 0})
tick(2)
surf = of_type(take(), "surface")
check(surf and surf[0]["surface"] == "vulcanus" and surf[0]["planet"] == "vulcanus" and "pf" not in surf[0] and puppet.surface.name == "vulcanus",
      f"plat_board 0 drops to the planet the platform is stopped at, making its surface: {surf}")
send({"t": "plat_board", "i": 1})
tick(2)
check(puppet.surface.name == "platform-1", "and plat_board takes it back up to the platform in orbit there")
planet = of_type(take(), "planet")
check(planet and planet[-1]["name"] == "space", f"planet: on a platform it is space: {planet[-1:]}")
# In the hub (where a rocket leaves it) the character can't be a passenger or move on its surface,
# so land hops it to the planet and back beside the hub first.
F.entity_data(puppet).hub = plat.hub
send({"t": "land"})
tick(1)
check(any(m["text"] == "Going down to vulcanus in a cargo pod" for m in of_type(take(), "msg")) and same(F.pod_passenger, puppet)
      and puppet.surface.name == "platform-1" and puppet.hub is None,
      "land: from inside the hub down to the planet the platform is stopped at, in a cargo pod with the character inside")
tick(2)
me = of_type(take(), "me")
pod = puppet.cargo_pod
check(pod is not None and me and me[-1].get("pod") == pod.unit_number and me[-1].get("ps") == "awaiting_launch" and me[-1].get("up") == 1
      and (me[-1].get("gx"), me[-1].get("gy")) == (fixed(plat.hub.position.x), fixed(plat.hub.position.y)) and "hub" not in me[-1],
      f"me: the pod, its state and the hub it leaves from: {me[-1:]}")
pod_data = F.entity_data(pod)
land_at = pod_data.cargo_pod_destination.position
pod_data.cargo_pod_state = "descending"
pod_data.surface = g.game.planets["vulcanus"].surface
send({"t": "walk", "d": 4})
send({"t": "mine", "u": 0, "p": 0, "x": 0, "y": 0})
tick(2)
msgs = take()
me = of_type(msgs, "me")
check(me and me[-1].get("up") == 0 and (me[-1]["gx"], me[-1]["gy"]) == (fixed(land_at.x), fixed(land_at.y)) and "Not while flying" in texts(msgs)
      and me[-1]["w"] == 0, f"me: coming down, the spot it lands on; walking and mining wait: {me[-1:]} {texts(msgs)}")
F.pod_arrive(pod)
tick(2)
msgs = take()
me = of_type(msgs, "me")
check(puppet.surface.name == "vulcanus" and me and "pod" not in me[-1] and of_type(msgs, "surface"),
      f"the pod lands and the character stands on the planet: {me[-1:]}")
send({"t": "plat_board", "i": 1})
tick(2)
take()
F["raise"]("on_space_platform_changed_state", lua.table_from({"platform": plat, "old_state": g.defines.space_platform_state.on_the_path}))
tick(1)
pst = of_type(take(), "pst")
check(pst and pst[-1]["i"] == 1 and pst[-1]["old"] == "on_the_path" and pst[-1]["loc"] == "vulcanus", f"pst: a platform arriving: {pst}")

send({"t": "plat_pause", "i": 1, "p": 1})
send({"t": "plat_sched", "i": 1, "l": ["nauvis", "vulcanus", "nowhere"], "c": 2})
tick(1)
take()
rec = next_plat()["l"][0]
check(rec.get("pa") == 1 and rec.get("st") == "paused" and rec.get("sch") == {"c": 2, "l": ["nauvis", "vulcanus"]},
      f"plat_pause and plat_sched (unknown places dropped, current record set): {rec}")
lines = platform_console("leave nauvis")
tick(2)
surf = of_type(take(), "surface")
check(any("moved to nauvis" in l for l in lines) and surf and surf[0]["planet"] == "nauvis" and puppet.surface.name == "nauvis",
      f"/f3d-platform leave <planet> brings the character home: {lines} {surf}")
send({"t": "plat_board", "i": 1})
tick(1)
check("That platform isn't in orbit here" in texts(take()) and puppet.surface.name == "nauvis",
      "plat_board refuses a platform orbiting another planet")
lines = platform_console("list")
check(any("platform 1 Platform 1: paused at vulcanus" in l for l in lines), f"/f3d-platform list: {lines}")
send({"t": "sub", "c": [[0, 0]]})
tick(3)
take()

# --- Space Age screens: space map, new platforms, silo, hub, landing pad, collector, quality ------
send({"t": "smap"})
tick(1)
sm = of_type(take(), "smap")
locs = {r[0]: r for r in (sm[0]["loc"] if sm else [])}
cons = {(r[0], r[1]): r for r in (sm[0]["con"] if sm else [])}
check(sm and locs.get("nauvis") == ["nauvis", "planet", 0, -5000, 1, 1, 1000, 1, 250] and locs.get("vulcanus", [0] * 9)[4] == 1
      and locs.get("vulcanus", [0] * 9)[6] == 1500 and locs.get("solar-system-edge", [0] * 9)[7] == 0
      and locs.get("solar-system-edge", [0] * 6)[4] == 0,
      f"smap: space locations with star map positions, unlocked and surfaces: {sm}")
check(cons.get(("nauvis", "solar-system-edge"), [0] * 4)[3] == 1000 and 0 < cons.get(("nauvis", "vulcanus"), [0] * 4)[3] < 1000
      and cons.get(("nauvis", "vulcanus"), [0] * 4)[2] == 15000, f"smap: connections with length and asteroid danger: {cons}")

send({"t": "plat_new"})
tick(1)
check("You need a space platform starter pack" in texts(take()), "plat_new needs a starter pack")
puppet.insert(lua.table_from({"name": "space-platform-starter-pack", "count": 1}))
send({"t": "plat_new"})
tick(1)
msgs = take()
plat2 = g.game.forces.player.platforms[2]
check(plat2 is not None and plat2.state == g.defines.space_platform_state.waiting_for_starter_pack and plat2.space_location.name == "nauvis"
      and puppet.get_main_inventory().get_item_count("space-platform-starter-pack") == 1,
      f"plat_new: a platform over the planet waits for the pack, which stays in the inventory: {texts(msgs)}")

pp = puppet.position
silo_e = spawn("rocket-silo", pp.x + 7.5, pp.y + 0.5, force="player")
send(open_cmd(silo_e))
tick(2)
gs = guis(take(), silo_e)
rk = gs[-1].get("rk", {}) if gs else {}
check(gs and gs[-1]["kind"] == "silo" and rk.get("st") == "building_rocket" and rk.get("auto") == 0
      and [2, "Platform 2", "waiting_for_starter_pack"] in rk.get("to", []) and "rocket" in gs[-1].get("slots", {}),
      f"a silo's screen: status, automatic launch, platforms to launch to, the rocket's cargo: {gs[-1:]}")
send({"t": "set_silo", "u": silo_e.unit_number, "auto": 1})
send({"t": "silo_launch", "u": silo_e.unit_number, "to": 2})
tick(1)
check(silo_e.send_to_orbit_automatically and "The rocket isn't ready" in texts(take()),
      "set_silo turns automatic launches on; silo_launch without a rocket ready is refused")
silo_e.rocket_silo_status = g.defines.rocket_silo_status.rocket_ready
send({"t": "silo_launch", "u": silo_e.unit_number, "to": 2})
tick(1)
take()
check(F.launched and F.launched.type == g.defines.cargo_destination.space_platform and same(F.launched.space_platform, plat2),
      "silo_launch to a platform waiting for its starter pack sends the pack to it")
plat2.apply_starter_pack()
silo_e.rocket_silo_status = g.defines.rocket_silo_status.rocket_ready
send({"t": "silo_launch", "u": silo_e.unit_number, "to": 2})
tick(1)
take()
check(F.launched.type == g.defines.cargo_destination.station and same(F.launched.station, plat2.hub),
      "silo_launch to a built platform lands at its hub")

# Riding the rocket up (#10): into its pod, up to the platform's hub, and inside the hub (#17).
send({"t": "ride", "u": silo_e.unit_number, "to": 2})
tick(1)
check("The rocket isn't ready" in texts(take()) and puppet.cargo_pod is None, "ride: no rocket ready, no ride")
silo_e.rocket_silo_status = g.defines.rocket_silo_status.rocket_ready
send({"t": "ride", "u": silo_e.unit_number, "to": 2})
tick(2)
msgs = take()
me = of_type(msgs, "me")
pod = puppet.cargo_pod
check(pod is not None and same(F.launched.station, plat2.hub) and me and me[-1].get("pod") == pod.unit_number
      and me[-1].get("up") == 1 and (me[-1]["gx"], me[-1]["gy"]) == (fixed(silo_e.position.x), fixed(silo_e.position.y)),
      f"ride: the character is in the rocket's cargo pod, seen from the silo: {me[-1:]} {texts(msgs)}")
send({"t": "ride", "u": silo_e.unit_number, "to": 2})
tick(1)
check("Not while flying" in texts(take()), "ride: one ride at a time")
F.pod_arrive(pod)
tick(2)
msgs = take()
me = of_type(msgs, "me")
surf = of_type(msgs, "surface")
check(surf and surf[0].get("pf") == 2 and me and me[-1].get("hub") == plat2.hub.unit_number and "pod" not in me[-1],
      f"the pod docks: the character is inside the platform's hub (me.hub): {surf} {me[-1:]}")
send({"t": "sub", "c": [[0, 0], [-1, -1], [-1, 0], [0, -1]]})
tick(3)
take()
at = (puppet.position.x, puppet.position.y)
send({"t": "walk", "d": 4})
tick(3)
send({"t": "walk", "d": -1})
send({"t": "mine", "u": 0, "p": 0, "x": fixed(at[0] + 3), "y": fixed(at[1])})
puppet.insert(lua.table_from({"name": "wooden-chest", "count": 1}))
chests = puppet.get_main_inventory().get_item_count("wooden-chest")
send({"t": "build", "item": "wooden-chest", "x": fixed(at[0] + 6.5), "y": fixed(at[1] + 0.5), "d": 0})
tick(2)
msgs = take()
ghosts = [e for e in puppet.surface.entities.values() if e.name == "entity-ghost"]
check((puppet.position.x, puppet.position.y) == at and "Not from inside the hub" in texts(msgs) and ghosts
      and puppet.get_main_inventory().get_item_count("wooden-chest") == chests,
      f"in the hub: no walking or mining; building places a ghost: {texts(msgs)} {len(ghosts)} ghosts")
for e in ghosts:
    e.destroy()
send({"t": "land"})
tick(2)
pod = puppet.cargo_pod
check(pod is not None and puppet.hub is None and "Going down to nauvis in a cargo pod" in texts(take()),
      "land from the hub over Nauvis: into a pod")
F.pod_arrive(pod)
puppet.teleport(lua.table_from({"x": pp.x, "y": pp.y}), F.surface)
tick(3)
take()
send({"t": "sub", "c": [[0, 0]]})
tick(3)
take()
send(open_cmd(silo_e))
tick(1)
take()
send({"t": "close"})

F.effects = lua.table_from({"quality": 0.025, "speed": -0.05})
qasm = spawn("assembling-machine-1", pp.x - 6.5, pp.y + 0.5, force="player")
F.effects = None
send(open_cmd(qasm))
send({"t": "set_recipe", "u": qasm.unit_number, "recipe": "iron-gear-wheel", "q": "uncommon"})
tick(2)
gs = guis(take(), qasm)
check(gs and gs[-1].get("rq") == "uncommon" and gs[-1].get("ql") == ["normal", "uncommon", "rare"]
      and gs[-1].get("eff") == {"q": 25, "sp": -50},
      f"a machine's screen: the recipe's quality, the qualities to choose from, module effects: {gs[-1:]}")

send({"t": "set_recipe", "u": qasm.unit_number, "recipe": "iron-gear-wheel", "q": "epic"})
tick(1)
check("That quality isn't researched" in texts(take()), "set_recipe refuses a quality the force hasn't researched")
# G12: the hover panel's beacon and module effects (`hinfo`): a machine's effects, modules and the
# beacons reaching it; a beacon's effects, modules, the machines it reaches and its effectivity.
F.effects = lua.table_from({"speed": 0.5, "consumption": 1.2})
hbeacon = spawn("beacon", qasm.position.x + 3, qasm.position.y, force="player")
F.effects = None
hbeacon.get_module_inventory().insert(lua.table_from({"name": "speed-module", "count": 2}))
send({"t": "hinfo", "q": 3, "u": qasm.unit_number, "p": 0, "x": fixed(qasm.position.x), "y": fixed(qasm.position.y)})
send({"t": "hinfo", "q": 4, "u": hbeacon.unit_number, "p": 0, "x": fixed(hbeacon.position.x), "y": fixed(hbeacon.position.y)})
send({"t": "hinfo", "q": 5, "u": 999999, "p": 0, "x": fixed(500), "y": fixed(500)})
tick(1)
hi = {m["q"]: m for m in of_type(take(), "hinfo")}
check(hi.get(3, {}).get("eff") == {"q": 25, "sp": -50} and hi[3].get("b") == 1 and "n" not in hi[3],
      f"hinfo for a machine: its effects and the beacons reaching it: {hi.get(3)}")
check(hi.get(4, {}).get("eff") == {"sp": 500, "co": 1200} and hi[4].get("m") == [["speed-module", 2]]
      and hi[4].get("n") == 1 and hi[4].get("de") == 1500,
      f"hinfo for a beacon: what it hands on, its modules, the machines it reaches, its effectivity: {hi.get(4)}")
check(hi.get(5) is not None and not any(k in hi[5] for k in ("eff", "m", "b", "n", "de", "el")),
      f"hinfo for nothing there answers with nothing: {hi.get(5)}")
# H20: what the entity info's "Consumes electricity" shows: the buffer (the Electricity bar), Max.
# consumption (75 kW and the 2.5 kW drain) and Min. consumption (the drain); a beacon here has no
# electric source in the fake, so none.
check(hi.get(3, {}).get("el") == {"e": 1000, "b": 1000, "mx": 77500, "mn": 2500} and "el" not in hi.get(4, {}),
      f"hinfo for a powered machine: its energy, buffer, max. and min. consumption: {hi.get(3)}")
# H14: a hovered roboport's links to the roboports its logistic cell is joined to (the game's
# LuaLogisticCell.neighbours): one 45 tiles away is, one 120 tiles away isn't.
rp1 = spawn("roboport", pp.x + 400, pp.y, force="player")
rp2 = spawn("roboport", pp.x + 445, pp.y + 10, force="player")
spawn("roboport", pp.x + 520, pp.y, force="player")
send({"t": "hinfo", "q": 8, "u": rp1.unit_number, "p": 0, "x": fixed(rp1.position.x), "y": fixed(rp1.position.y)})
tick(1)
hr = {m["q"]: m for m in of_type(take(), "hinfo")}.get(8, {})
check(hr.get("rn") == [fixed(rp2.position.x), fixed(rp2.position.y)],
      f"hinfo for a roboport: the roboports it links to (H14): {hr}")

send({"t": "close"})

pad = spawn("cargo-landing-pad", pp.x + 0.5, pp.y + 6.5, force="player")
send(open_cmd(pad))
tick(2)
gs = guis(take(), pad)
# Opening it makes its control behaviour, as Factorio does (circuit_settings.lua), so `cb` is there
# with everything off.
check(gs and gs[-1]["kind"] == "pad" and gs[-1].get("pad", {}).get("sec") == []
      and gs[-1]["pad"].get("cb", {}).get("req", 0) == 0 and gs[-1]["pad"].get("cb", {}).get("empty", 0) == 0
      and "chest" in gs[-1].get("slots", {}) and "trash" in gs[-1].get("slots", {}),
      f"a landing pad's screen: inventory, trash, requests, its circuit settings: {gs[-1:]}")
send({"t": "set_pad", "u": pad.unit_number, "read": 0, "req": 1})
send({"t": "set_section", "u": pad.unit_number, "i": 0, "f": [["iron-plate", "normal", 200, -1, "", -1]]})
tick(31)
gs = guis(take(), pad)
p_ = gs[-1].get("pad", {}) if gs else {}
check(p_.get("cb") == {"read": 0, "req": 1, "empty": 0} and p_.get("sec", [{}])[0].get("f") == [["iron-plate", "normal", 200, -1, "", -1]],
      f"set_pad and set_section on a landing pad: {p_}")
send({"t": "close"})

col = spawn("asteroid-collector", pp.x - 3.5, pp.y - 5.5, force="player")
send(open_cmd(col))
send({"t": "set_collector", "u": col.unit_number, "f": ["metallic-asteroid-chunk", "made-up-chunk"]})
tick(2)
gs = guis(take(), col)
check(gs and gs[-1]["kind"] == "collector" and gs[-1].get("col") == {"n": 3, "f": ["metallic-asteroid-chunk", "", ""]},
      f"an asteroid collector's chunk filters (unknown chunks cleared): {gs[-1:]}")
send({"t": "close"})

qbelt = spawn("transport-belt", pp.x + 2.5, pp.y - 2.5, force="player", direction=4)
F.put_on_belt(qbelt, 1, "iron-plate", 0.25, 77, None, "rare")
F.put_on_belt(qbelt, 2, "iron-plate", 0.5, 78)
tick(6)
bq = of_type(take(), "bq")
check(bq and bq[-1]["l"] == [[77, "rare"]], f"bq: the quality of belt items better than normal: {bq}")
qbelt.destroy()
tick(12)
bq = of_type(take(), "bq")
check(bq and bq[0]["l"] == [] and len(bq) == 1, f"bq: one empty list clears it, then nothing: {bq}")

send({"t": "plat_board", "i": 2})
tick(2)
msgs = take()
planet = of_type(msgs, "planet")
check(puppet.surface.name == "platform-2", "the character boards the new platform")
plat2.surface.props.gravity = 0
puppet.insert(lua.table_from({"name": "burner-inserter", "count": 1}))
hub = plat2.hub
hp = hub.position
send({"t": "build", "item": "burner-inserter", "x": fixed(hp.x + 5.5), "y": fixed(hp.y + 0.5), "d": 0})
tick(1)
check(any(t.startswith("Can't build here: gravity is 0") for t in texts(take())),
      "building something that needs gravity on a platform says why it can't")
nb = g.package.loaded["scripts.space"].blocked(plat2.surface)
check(to_py(nb) == [[eid["burner-inserter"], "gravity", 0.1, 1e9]], f"planet.nb: what can't be built on this surface: {to_py(nb)}")

send(open_cmd(hub))
tick(2)
gs = guis(take(), hub)
h = gs[-1].get("hub", {}) if gs else {}
check(gs and gs[-1]["kind"] == "hub" and h.get("i") == 2 and h.get("w") == 1250000 and h.get("th") == [0, 0]
      and h.get("prov") == 0 and h.get("sec") == [] and h.get("dest") == ["nauvis", "vulcanus"] and h.get("loc") == "nauvis"
      and "chest" in gs[-1].get("slots", {}) and "trash" in gs[-1].get("slots", {}),
      f"a hub's screen: its platform's state, weight, thrusters, requests, inventory and trash: {gs[-1:]}")
send({"t": "set_section", "u": hub.unit_number, "i": 0,
      "f": [["iron-plate", "uncommon", 100, 400, "vulcanus", 50], ["no-such-item", "", 1, -1, "", -1]]})
send({"t": "set_hub", "u": hub.unit_number, "prov": 1})
waits = [{"type": "all_requests_satisfied", "compare_type": "and"}, {"type": "time", "compare_type": "or", "ticks": 1800}]
send({"t": "set_schedule", "u": hub.unit_number, "records": [{"station": "vulcanus", "wait_conditions": waits}, {"station": "nowhere"}]})
send({"t": "set_interrupts", "u": hub.unit_number, "interrupts": [
    {"name": "Refuel", "conditions": [{"type": "any_request_zero", "compare_type": "and"}], "targets": [{"station": "nauvis"}]}]})
tick(31)
gs = guis(take(), hub)
h = gs[-1].get("hub", {}) if gs else {}
sec = (h.get("sec") or [{}])[0]
check(sec.get("f") == [["iron-plate", "uncommon", 100, 400, "vulcanus", 50]] and sec.get("on") == 1 and sec.get("man") == 1,
      f"set_section on a hub: a request from a planet with quality, max and a minimum delivery: {h.get('sec')}")
check(hub.providing_to_other_platforms and h.get("prov") == 1, "set_hub: provide to other platforms")
sched = h.get("sched", {})
check([r["station"] for r in sched.get("records", [])] == ["vulcanus"] and sched["records"][0]["wait_conditions"] == waits
      and sched.get("interrupts", [{}])[0].get("name") == "Refuel" and sched["interrupts"][0]["targets"][0]["station"] == "nauvis",
      f"the hub edits its platform's schedule and interrupts like a train's (unknown places dropped): {sched}")
send({"t": "set_section", "u": hub.unit_number, "i": 1, "on": 0, "m": 2})
send({"t": "set_section", "u": hub.unit_number, "i": 0})
tick(31)
gs = guis(take(), hub)
secs = gs[-1].get("hub", {}).get("sec", []) if gs else []
check(len(secs) == 2 and secs[0]["on"] == 0 and secs[0]["m"] == 2, f"set_section: off, a multiplier, a second section: {secs}")
send({"t": "set_section", "u": hub.unit_number, "i": 2, "del": 1})
tick(31)
gs = guis(take(), hub)
check(gs and len(gs[-1]["hub"]["sec"]) == 1, "set_section del removes a section")
send({"t": "set_silo", "u": hub.unit_number, "auto": 1})
tick(1)
check("That isn't a rocket silo" in texts(take()), "space commands check what the open screen is")
send({"t": "close"})

data2 = F.platform_data[plat2]
data2.chunks[1] = lua.table_from({"name": "metallic-asteroid-chunk", "position": {"x": hp.x + 10, "y": hp.y - 4},
                                  "movement": {"x": 0, "y": 0.05}}, recursive=True)
tick(10)
ach = of_type(take(), "ach")
check(ach and ach[-1]["l"] == [["metallic-asteroid-chunk", fixed(hp.x + 10), fixed(hp.y - 4), 0, 768]],
      f"ach: asteroid chunks near the focus on a platform, moving 0.05 tiles a tick: {ach}")
data2.chunks[1] = None
tick(20)
ach = of_type(take(), "ach")
check(len(ach) == 1 and ach[0]["l"] == [], f"ach: one empty list once they're gone: {ach}")
# Whether the empty list is owed is kept per client: a second client (on Nauvis, no chunks) ticking
# in turn doesn't use up the first one's.
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
send({"t": "hello", "v": 1, "sid": "ach-b", "w": 0}, port=PORT_B)
tick(3)
take_by_port()
data2.chunks[1] = lua.table_from({"name": "metallic-asteroid-chunk", "position": {"x": hp.x + 10, "y": hp.y - 4},
                                  "movement": {"x": 0, "y": 0}}, recursive=True)
tick(10)
take_by_port()
data2.chunks[1] = None
tick(20)
ach = of_type(take_by_port().get(CLIENT_PORT, []), "ach")
check(len(ach) == 1 and ach[0]["l"] == [], f"ach: the empty list reaches its client with another client connected: {ach}")
send({"t": "bye"}, port=PORT_B)
tick(1)
take_by_port()

# Asteroid collectors' arms (`acol`, F3): their arms, speed and filters, and the chunks they catch,
# seen as chunks gone from their catch circle (5 tiles in front, radius 7.5).
def made(name, x, y, **extra):
    return puppet.surface.create_entity(lua.table_from({"name": name, "position": {"x": x, "y": y}, "force": "player", **extra},
                                                       recursive=True))


acol_n = made("asteroid-collector", hp.x, hp.y - 8)
acol_r = made("asteroid-collector", hp.x + 20, hp.y, direction=4, quality="rare")
acol_r.set_filter(1, "carbonic-asteroid-chunk")
tick(60)  # the mod looks for collectors near the focus once a second
rows = {r[0]: r for m in of_type(take(), "acol") for r in m.get("l", [])}
check(rows.get(acol_n.unit_number) == [acol_n.unit_number, 1, 200, 1, []]
      and rows.get(acol_r.unit_number) == [acol_r.unit_number, 3, 300, 1, ["carbonic-asteroid-chunk"]],
      f"acol: each collector's arms and arm speed by quality, moving, its filters: {rows}")
caught_chunk = lua.table_from({"name": "metallic-asteroid-chunk", "position": {"x": hp.x + 1, "y": hp.y - 15},
                               "movement": {"x": 0.01, "y": 0}}, recursive=True)
data2.chunks[1] = caught_chunk
# Inside the east-facing collector's box but outside its circle: not caught when it goes.
data2.chunks[2] = lua.table_from({"name": "carbonic-asteroid-chunk", "position": {"x": hp.x + 33.5, "y": hp.y + 6.5},
                                  "movement": {"x": 0, "y": 0}}, recursive=True)
tick(10)
take()
caught_chunk.position = lua.table_from({"x": hp.x + 1.1, "y": hp.y - 15})
tick(10)
check(not any(m.get("g") for m in of_type(take(), "acol")), "acol: a chunk where its movement takes it isn't caught")
data2.chunks[1] = None
data2.chunks[2] = None
tick(10)
msgs = of_type(take(), "acol")
check([g for m in msgs for g in m.get("g", [])] == [[acol_n.unit_number, "metallic-asteroid-chunk", fixed(hp.x + 1.2), fixed(hp.y - 15)]],
      f"acol g: the chunk gone from a collector's circle, caught where it had drifted to (not the one outside it): {msgs}")
# A chunk the filter leaves alone isn't counted when it goes (it hit the platform, or something else took
# it): the rare collector takes only carbonic chunks.
data2.chunks[1] = lua.table_from({"name": "metallic-asteroid-chunk", "position": {"x": hp.x + 25, "y": hp.y + 1},
                                  "movement": {"x": 0, "y": 0}}, recursive=True)
tick(10)
take()
data2.chunks[1] = None
tick(10)
check(not [g for m in of_type(take(), "acol") for g in m.get("g", [])],
      "acol g: a chunk its collector's filter leaves alone isn't counted as caught when it leaves the circle")
acol_n.status = g.defines.entity_status.low_power
acol_r.status = g.defines.entity_status.disabled_by_control_behavior
tick(10)
rows = {r[0]: r for m in of_type(take(), "acol") for r in m.get("l", [])}
check(rows.get(acol_n.unit_number, [0] * 4)[2:4] == [60, 1] and rows.get(acol_r.unit_number, [0] * 4)[3] == 2,
      f"acol: low power slows the arms (unpowered_arm_speed_scale); switched off by the circuit network they fold home (2, G10): {rows}")
acol_n.destroy()
acol_r.destroy()
send({"t": "plat_board", "i": 0})
tick(2)
take()
check(puppet.surface.name == "nauvis", "and back down to Nauvis")
send({"t": "sub", "c": [[0, 0]]})
tick(3)
take()

# --- client restart and timeout ------------------------------------------------------------------
send({"t": "rate", "l": 2})
send({"t": "hello", "v": 1, "sid": "s2", "w": 0})
tick(3)
msgs = take()
check(msgs and msgs[0]["t"] == "welcome" and msgs[0]["r"] == 1, "a new client session restarts the sequence")
check(rate.level() == 0, "and starts at rate 0 (the old session's `rate` doesn't carry over)")
drop_box = spawn("wooden-chest", puppet.position.x + 1.5, puppet.position.y + 0.5, force="player")
send(open_cmd(drop_box))
tick(2)
take()
had_screen = g.storage.f3d.screen is not None
tick(700)
check(g.storage.f3d.client is None, "client is dropped after 10 s without hello")
check(had_screen and g.storage.f3d.screen is None, f"a dropped client's machine screen is closed (one was open: {had_screen})")
drop_box.destroy()
take()
tick(5)
check(take() == [], "nothing is sent after the client is dropped")
# With no client nothing empties the pipe refresh list (tracker.tick runs only with one), and it is
# saved with the game: removing a pipe then adds nothing to it.
lone_pipe = spawn("pipe", 60.5, 60.5, force="player")
F["raise"]("script_raised_destroy", lua.table_from({"entity": lone_pipe}))
lone_pipe.destroy()
tick(2)
check(len(g.storage.f3d.pipe_refresh) == 0, f"no client: a pipe removed leaves nothing queued in storage ({len(g.storage.f3d.pipe_refresh)})")

# --- /f3d-selftest and a respawn on a server -------------------------------------------------------
def selftest(**cmd):
    before = len(F.printed)
    F.commands["f3d-selftest"](lua.table_from(dict(cmd, name="f3d-selftest")))
    return [str(p) for p in list(F.printed.values())[before:]]


send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(2)
take()
puppet = g.storage.f3d.puppet
chest = spawn("wooden-chest", puppet.position.x + 2, puppet.position.y + 1, force="player")
lines = selftest()
check(any("PASS the bridge's character has no player" in l for l in lines) and any("PASS character.selected can be set" in l for l in lines)
      and not any("FAIL" in l for l in lines), f"/f3d-selftest on a server: {lines}")
check(any("PASS string.pack and string.unpack (binary frames)" in l for l in lines)
      and any(("INFO binary frames: on" if BINARY else "INFO binary frames: off for this client") in l for l in lines),
      f"/f3d-selftest: string.pack round trip, and this client gets no binary frames (its hello doesn't ask): {lines[-2:]}")
chest.destroy()
old_unit = puppet.unit_number
puppet.destroy()
tick(2)
welcome = of_type(take(), "welcome")
check(welcome and welcome[-1]["u"] != old_unit and welcome[-1]["u"] == g.storage.f3d.puppet.unit_number,
      "a new character after the old one died starts over with a welcome naming it")
puppet = g.storage.f3d.puppet

# --- the character's gear: armour grid, toggles, character info, players, death ----------------------
grid = F.make_grid(10, 10)
puppet.grid = grid
main = puppet.get_main_inventory()
main.insert(lua.table_from({"name": "energy-shield-equipment", "count": 2}))
main.insert(lua.table_from({"name": "exoskeleton-equipment", "count": 1}))
main.insert(lua.table_from({"name": "battery-equipment", "count": 1}))
gear_slots = {main[i].name: i for i in range(1, 81) if main[i].valid_for_read}
# As after a handshake: everything once.
g.storage.f3d.eq_sent = lua.table_from({})
g.storage.f3d.info_sig = None
g.storage.f3d.pl_sig = None
tick(61)
msgs = take()
eqs = [m for m in of_type(msgs, "eq") if m["kind"] == "char"]
check(eqs and eqs[-1]["w"] == 10 and eqs[-1]["h"] == 10 and eqs[-1]["l"] == [] and eqs[-1]["u"] == puppet.unit_number,
      f"eq: the character's empty 10x10 armour grid: {eqs[-1:]}")
veh = [m for m in of_type(msgs, "eq") if m["kind"] == "veh"]
check(veh and veh[-1]["w"] == 0 and veh[-1]["u"] == 0, f"eq: no vehicle grid: {veh[-1:]}")
cinfo = of_type(msgs, "cinfo")
check(cinfo and cinfo[-1]["reach"] == 100 and cinfo[-1]["craft"] == 1000 and cinfo[-1]["slots"] == 80 and cinfo[-1]["hp"] == 250,
      f"cinfo: reach, crafting speed, slots and health: {cinfo[-1:]}")
check(cinfo and cinfo[-1].get("mwf") == 0, f"cinfo: the force can't mine with fluid yet on a new map (mwf 0): {cinfo[-1:]}")
g.game.forces.player.mining_with_fluid = True
g.storage.f3d.info_sig = None  # (sent on the next tick, not waiting for its once-a-second round)
tick(1)
cinfo2 = of_type(take(), "cinfo")
check(cinfo2 and cinfo2[-1].get("mwf") == 1, f"cinfo: once it can (Uranium mining researched), mwf 1: {cinfo2[-1:]}")
g.game.forces.player.mining_with_fluid = False
pl = of_type(msgs, "pl")
check(pl and pl[-1]["me"] == 0 and pl[-1]["u"] == puppet.unit_number, f"pl: the bridge's own character plays no player: {pl[-1:]}")
send({"t": "eq_put", "kind": "char", "fi": gear_slots["energy-shield-equipment"], "x": 2, "y": 0})
send({"t": "eq_put", "kind": "char", "fi": gear_slots["exoskeleton-equipment"]})  # Shift+click: the first place it fits
send({"t": "eq_put", "kind": "char", "fi": gear_slots["energy-shield-equipment"], "x": 3, "y": 1})  # overlaps the first
send({"t": "eq_put", "kind": "char", "fi": gear_slots["battery-equipment"], "x": 9, "y": 9})  # doesn't fit at the edge
tick(1)
msgs = take()
placed = sorted((e.name, e.position.x, e.position.y) for e in grid.equipment.values())
check(placed == [("energy-shield-equipment", 2, 0), ("exoskeleton-equipment", 0, 0)],
      f"eq_put: at a position, Shift+click in the first place it fits, refusals where it overlaps or sticks out: {placed}")
check(main.get_item_count("energy-shield-equipment") == 1 and main.get_item_count("exoskeleton-equipment") == 0
      and main.get_item_count("battery-equipment") == 1, "eq_put takes one from the inventory slot only when it was placed")
check(texts(msgs).count("No room for that in the grid") == 2, f"refusals say so: {texts(msgs)}")
eqs = [m for m in of_type(msgs, "eq") if m["kind"] == "char"]
rec = {r[0]: r for r in (eqs[-1]["l"] if eqs else [])}
check(eqs and rec.get("energy-shield-equipment", [])[:6] == ["energy-shield-equipment", 2, 0, 2, 2, "normal"]
      and rec["energy-shield-equipment"][8:10] == [25, 50] and eqs[-1]["msh"] == 50 and eqs[-1]["sh"] == 25
      and eqs[-1]["mv"] == 300 and eqs[-1]["mvon"] == 1 and eqs[-1]["rb"] == 1,
      f"eq is sent at once after a change, with shields, movement bonus and the roboport switch: {eqs[-1:]}")
mes = of_type(msgs, "me") or of_type((tick(2), take())[1], "me")
check(mes and mes[-1].get("sd") == 25 and mes[-1].get("msd") == 50, f"me carries the armour's shields: {mes[-1:]}")
send({"t": "eq_move", "kind": "char", "x": 3, "y": 1, "tx": 6, "ty": 6})
send({"t": "eq_move", "kind": "char", "x": 0, "y": 0, "tx": 5, "ty": 5})  # onto the shield
tick(1)
placed = sorted((e.name, e.position.x, e.position.y) for e in grid.equipment.values())
check(placed == [("energy-shield-equipment", 6, 6), ("exoskeleton-equipment", 0, 0)],
      f"eq_move: by any cell of it, refused where it overlaps: {placed}")
empty = next(i for i in range(1, 81) if not main[i].valid_for_read)
send({"t": "eq_take", "kind": "char", "x": 7, "y": 7, "ti": empty})
tick(1)
check(len(grid.equipment) == 1 and main[empty].valid_for_read and main[empty].name == "energy-shield-equipment",
      "eq_take: by any cell, into the slot asked for")
send({"t": "eq_toggle", "what": "roboport", "on": 0})
send({"t": "eq_toggle", "what": "movement", "on": 0})
tick(1)
eqs = [m for m in of_type(take(), "eq") if m["kind"] == "char"]
check(not puppet.allow_dispatching_robots and grid.inhibit_movement_bonus and eqs and eqs[-1]["rb"] == 0 and eqs[-1]["mvon"] == 0
      and eqs[-1]["mv"] == 0, f"eq_toggle: Alt+F turns the personal roboport off, Alt+E the exoskeletons: {eqs[-1:]}")
send({"t": "eq_toggle", "what": "movement", "on": 1})
tick(1)
take()
car = F.spawn("car", puppet.position.x + 2, puppet.position.y, lua.table_from({"force": "player"}))
car.grid = F.make_grid(4, 4)
send(open_cmd(car))
tick(31)
veh = [m for m in of_type(take(), "eq") if m["kind"] == "veh"]
check(veh and veh[-1]["u"] == car.unit_number and veh[-1]["w"] == 4, f"eq: the open car's grid: {veh[-1:]}")
send({"t": "eq_put", "kind": "veh", "u": car.unit_number, "fi": gear_slots["battery-equipment"], "x": 0, "y": 0})
tick(1)
check(len(car.grid.equipment) == 1 and main.get_item_count("battery-equipment") == 0, "eq_put into a vehicle's grid")
send({"t": "close"})
tick(1)
take()
# Death: the bridge's own character waits out the respawn time, then comes back at the spawn.
dead_unit = puppet.unit_number
puppet.teleport(lua.table_from({"x": 30, "y": 30}))
F["raise"]("on_entity_died", lua.table_from({"entity": puppet}))
puppet.destroy()
tick(30)
msgs = take()
dead = of_type(msgs, "dead")
check(dead and 560 <= dead[-1]["left"] <= 600 and dead[-1]["x"] == fixed(30) and not of_type(msgs, "me") and not of_type(msgs, "welcome"),
      f"dead: while dead the client hears how long until the respawn, and where it died: {dead[-1:]}")
send({"t": "respawn"})
for _ in range(5):
    send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
    tick(100)
check(not (g.storage.f3d.puppet and g.storage.f3d.puppet.valid), "Respawn before the time is up does nothing")
take()
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(80)
msgs = take()
new = g.storage.f3d.puppet
welcome = of_type(msgs, "welcome")
check(new and new.valid and new.unit_number != dead_unit and new.position.x == 0 and new.position.y == 0
      and welcome and welcome[-1]["u"] == new.unit_number, "after the respawn time a new character at the spawn, with a welcome")
check(g.storage.f3d.respawn is None and g.storage.f3d.death is None, "and the death is forgotten")
puppet = new

# --- taking over a save's character (a single-player save on a server) -----------------------------
def player_console(parameter):
    before = len(F.printed)
    F.commands["f3d-player"](lua.table_from({"name": "f3d-player", "parameter": parameter}))
    return [str(p) for p in list(F.printed.values())[before:]]


owner = F.make_offline_player(1, "owner", 20.5, 5.5)
owner.get_main_inventory().insert(lua.table_from({"name": "iron-gear-wheel", "count": 20}))
owner.get_main_inventory().set_filter(5, "wood")
# Filters keep their quality (2.1: a name alone means normal only): a rare item, and any quality.
owner.get_main_inventory().set_filter(6, lua.table_from({"name": "iron-plate", "quality": "rare", "comparator": "="}))
owner.get_main_inventory().set_filter(7, lua.table_from({"name": "coal"}))
owner.get_inventory(g.defines.inventory.character_armor).insert(lua.table_from({"name": "light-armor", "count": 1}))
owner.get_requester_point().add_section("Main").filters = lua.table_from(
    [{"value": {"type": "item", "name": "iron-plate", "quality": "normal", "comparator": "="}, "min": 100}], recursive=True)
owner.set_quick_bar_slot(1, 1, "transport-belt")
old_puppet = puppet
lines = player_console("")
check(any("owner, not connected" in l for l in lines), f"/f3d-player lists the save's players: {lines}")
lines = player_console("owner")
stand_in = g.storage.f3d.puppet
check(stand_in != old_puppet and not old_puppet.valid and stand_in.position.x == 20.5 and stand_in.position.y == 5.5
      and g.storage.f3d.held_for == 1 and any("(playing as)" in l for l in lines),
      f"/f3d-player owner: a stand-in where the owner's character was, the old bridge character gone: {lines}")
tick(2)
msgs = take()
welcome = of_type(msgs, "welcome")
check(welcome and welcome[-1]["u"] == stand_in.unit_number and welcome[-1]["x"] == fixed(20.5),
      "a new handshake names the stand-in")
tick(60)
msgs += take()
main = stand_in.get_main_inventory()
check(main.get_item_count("iron-gear-wheel") == 20 and owner.get_main_inventory().get_item_count("iron-gear-wheel") == 0,
      "the owner's inventory moved onto the stand-in")
check(main.get_filter(5) is not None and main.get_filter(5)["name"] == "wood", "slot filters moved too")
f6, f7 = main.get_filter(6), main.get_filter(7)
check(f6 is not None and f6["name"] == "iron-plate" and f6["quality"] == "rare" and f7 is not None and f7["name"] == "coal"
      and f7["quality"] is None and owner.get_main_inventory().get_filter(6) is None,
      f"slot filters keep their quality, and any quality stays any: {dict(f6) if f6 else f6}, {dict(f7) if f7 else f7}")
armor = stand_in.get_inventory(g.defines.inventory.character_armor)
check(armor[1].valid_for_read and armor[1].name == "light-armor", "the armour moved")
check(main.get_item_count("iron-plate") >= 1, "what the old bridge character carried was kept")
clog = of_type(msgs, "clog")
check(clog and ["iron-plate", 100, -1] in clog[-1]["l"], f"the owner's logistic requests (a group section) are the stand-in's: {clog}")
qb = of_type(msgs, "qb")
check(qb and qb[-1]["l"][0] == "transport-belt", "the quickbar is the owner's")
send({"t": "set_char_requests", "l": [["iron-plate", 150, -1], ["iron-gear-wheel", 10, -1]]})
tick(1)
point = stand_in.get_requester_point()
groups = [s.group for s in point.sections.values()]
main_group = F.logistic_groups["Main"]
check(len(main_group) == 1 and main_group[1].min == 150 and groups == ["Main", ""] and point.get_section(2).filters[1].value.name == "iron-gear-wheel",
      f"editing the requests keeps each in its section, new ones in a section of their own ({groups})")
take()
# The owner joins with the real game: everything goes back, and the bridge plays their character.
real = spawn("character", 30.5, 5.5, force="player")
F.connect_player(owner, real)
tick(2)
msgs = take()
check(g.storage.f3d.puppet.unit_number == real.unit_number and not stand_in.valid and g.storage.f3d.held_for is None
      and real.get_main_inventory().get_item_count("iron-gear-wheel") == 20 and real.position.x == 20.5,
      "when the owner joins, their things move back onto their character, which stands where the stand-in was")
welcome = of_type(msgs, "welcome")
check(welcome and welcome[-1]["u"] == real.unit_number, "and the client plays it")
# The Zenith button in the real game's top-left mod buttons (zenith_button.lua), added when the
# player joins: clicking it does what Ctrl+F9 does there.
zbtn = g.game.get_player(1).gui.top["mod_gui_top_frame"]["mod_gui_inner_frame"]["f3d-zenith-button"]
check(zbtn is not None and zbtn.sprite == "f3d-zenith-gear" and zbtn.style.name == "mod_gui_button",
      "the Zenith button is in the player's top-left mod buttons, with the gear logo")
take()
F["raise"]("on_gui_click", lua.table_from({"player_index": 1, "element": zbtn}))
check(of_type(take(), "raise"), "clicking it brings the client to the front, as Ctrl+F9 does (raise)")
# C7: "Show in Zenith" in the real game brings the client playing that player to the front.
F.handlers["f3d-show-3d"](lua.table_from({"player_index": 1, "input_name": "f3d-show-3d"}))
check(of_type(take(), "raise"), "Ctrl+F9 in the real game tells the client to come to the front (raise)")
g.storage.f3d.client.raised = None  # a live Zenith's next hello clears it
# With no Zenith playing them, it asks the launcher beside Factorio (port 34209) to start one,
# from the pressing player's own machine.
kept_client = g.storage.f3d.client
g.storage.f3d.client = None
F.handlers["f3d-show-3d"](lua.table_from({"player_index": 1, "input_name": "f3d-show-3d"}))
launch = [json.loads(item[2]) for item in F.take_sent().values() if item[1] == 34209]
g.storage.f3d.client = kept_client
check(len(launch) == 1 and launch[0]["t"] == "launch",
      f"Ctrl+F9 with no client connected asks Zenith's launcher on 34209 to start Zenith ({launch})")
# The owner's bug: with no launcher running nothing answered and nothing showed. Two seconds
# without its `launching` opens the bridge's window saying what to set up.
screen = g.game.get_player(1).gui.screen
check(screen["f3d-launch-help"] is None, "no help window while the launcher still has time to answer")
tick(121)
help_win = screen["f3d-launch-help"]
kids = list(help_win.children.values()) if help_win is not None else []
field = [k.text for k in kids if k.type == "textfield"]
captions = [str(k.caption[1]) for k in kids if k.type == "label"]
check(help_win is not None and help_win.auto_centered and len(field) == 2 and "Zenith-3D-Team/Zenith/releases" in field[0]
      and "factorio-with-zenith.ps1" in field[1] and "%command%" in field[1]
      and "f3d-launch.step1" in captions and "f3d-launch.step2" in captions,
      f"no answer from the launcher: both steps, Zenith's download page and the launch options line to copy ({captions})")
close = [k for k in kids if k.type == "button"]
F["raise"]("on_gui_click", lua.table_from({"player_index": 1, "element": close[0]}))
check(screen["f3d-launch-help"] is None and not help_win.valid, "its Close button closes it")
take()
# The launcher answers from its own port: no window. A packet from any other port isn't it.
g.storage.f3d.client = None
F.handlers["f3d-show-3d"](lua.table_from({"player_index": 1, "input_name": "f3d-show-3d"}))
F.take_sent()
F.packet('{"t":"launching"}', 34199, 1)
F.packet('{"t":"launching"}', 34209, 1)
g.storage.f3d.client = kept_client
tick(121)
check(screen["f3d-launch-help"] is None and not g.storage.f3d.launch_wait[1],
      "the launcher's `launching` from 34209 clears the wait: no window")
check(any("f3d-launch.starting" in str(p) for p in F.printed.values()),
      "and the player is told Zenith is on its way (it takes a while to start and join)")
# The launcher is there but has no Zenith to start (never opened on this PC, or moved): the game
# says so, with only the step that is missing.
take()
g.storage.f3d.client = None
F.handlers["f3d-show-3d"](lua.table_from({"player_index": 1, "input_name": "f3d-show-3d"}))
F.take_sent()
F.packet('{"t":"launching","need":"zenith","moved":1}', 34209, 1)
g.storage.f3d.client = kept_client
help_win = screen["f3d-launch-help"]
kids = list(help_win.children.values()) if help_win is not None else []
field = [k.text for k in kids if k.type == "textfield"]
captions = [str(k.caption[1]) for k in kids if k.type == "label"]
check(help_win is not None and "f3d-launch.step1-moved" in captions and "f3d-launch.step2-done" in captions
      and len(field) == 1 and "releases" in field[0],
      f"the launcher has no Zenith to start (moved): the window says so at once, the launch options step done ({captions})")
help_win.destroy()
# The owner's bug: on a loaded save the key did nothing for a while, because the save keeps the
# client it was saved with and the bridge raised that gone client until the timeout. A client not
# heard from in 3 s isn't raised: the launcher is asked instead.
take()
F.take_sent()
seen = kept_client.last_seen
kept_client.last_seen = g.game.tick - 400
F.handlers["f3d-show-3d"](lua.table_from({"player_index": 1, "input_name": "f3d-show-3d"}))
launch = [json.loads(item[2]) for item in F.take_sent().values() if item[1] == 34209]
check(launch and not of_type(take(), "raise"),
      "a client from the save, silent for seconds, isn't raised: the launcher is asked to start Zenith")
kept_client.last_seen = seen
g.storage.f3d.launch_wait = None
take()
# The owner's bug, again: a save made while Zenith was connected keeps its client heard a moment
# before the save's tick, and the tick goes on from there, so it looked fresh after loading. In
# single-player a loaded game raises nobody until the client says hello after the load.
was_mp = F.multiplayer
F.multiplayer = False
F.take_sent()
kept_client.last_seen = g.game.tick
F.on_load()
F.handlers["f3d-show-3d"](lua.table_from({"player_index": 1, "input_name": "f3d-show-3d"}))
launch = [json.loads(item[2]) for item in F.take_sent().values() if item[1] == 34209]
check(launch and not of_type(take(), "raise"),
      "a save's client heard just before the save isn't raised after loading it: the launcher is asked")
g.storage.f3d.launch_wait = None
send({"t": "hello", "v": 1, "sid": kept_client.sid, "w": 1}, kept_client.port)
tick(1)
take()
F.handlers["f3d-show-3d"](lua.table_from({"player_index": 1, "input_name": "f3d-show-3d"}))
check(of_type(take(), "raise"), "once that Zenith says hello after the load, the key raises it")
check(any("f3d-launch.raising" in str(p) for p in F.printed.values()),
      "and the player is told it is switching to Zenith")
# A raised Zenith that never answers (closed, hung) is taken for gone: the player is told and the
# launcher asked, so the key never looks dead.
F.take_sent()
old_sid = kept_client.sid
g.storage.f3d.client.raised.tick = g.game.tick - 100  # pressed 100 ticks ago,
g.storage.f3d.client.last_seen = g.game.tick - 101  # and not heard from since
tick(1)
launch = [json.loads(item[2]) for item in F.take_sent().values() if item[1] == 34209]
g.storage.f3d.client.last_seen = g.game.tick
check(launch and g.storage.f3d.client is not None and g.storage.f3d.client.raised is None
      and any("f3d-launch.raise-lost" in str(p) for p in F.printed.values()),
      "a raised Zenith silent for 1.5 s isn't waited for: the player is told and the launcher asked")
g.storage.f3d.launch_wait = None
send({"t": "hello", "v": 1, "sid": old_sid, "w": 1}, kept_client.port)
tick(1)
take()
F.multiplayer = was_mp
take()
# Each player's row says what armour their character wears (the client draws its look).
g.storage.f3d.pl_sig = None
tick(60)
pl = of_type(take(), "pl")
rows = {r[1]: r for r in (pl[-1]["l"] if pl else [])}
check(len(rows.get("owner", [])) == 12 and rows["owner"][11] == "light-armor",
      f"pl: a player's row ends with their character's armour: {pl[-1:]}")
# Leave the harness as before for the single-player checks.
F.players[1] = None
F.players_by[1] = None
F.players_by["owner"] = None
puppet = real

# --- the client's console: cmd / cmdr, and the zenith remote interface -------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(1)
take()


def console(text, cid):
    send({"t": "cmd", "id": cid, "text": text})
    tick(1)
    replies = [m for m in of_type(take(), "cmdr") if m["id"] == cid]
    return replies[-1] if replies else None


r = console("/version", 1)
check(r and r["l"] == ["2.1.23"] and "ok" not in r, f"cmd /version: the bridge answers with cmdr: {r}")
r = console("/seed", 2)
check(r and r["l"] == ["123456789"], f"cmd /seed: {r}")
r = console("/time", 3)
check(r and r["l"] == ["1 hour, 2 minutes and 5 seconds"], f"cmd /time in Factorio's words: {r}")
r = console("/evolution", 4)
check(r and "Evolution factor: 0.2500. (Time 60%) (Pollution 20%) (Spawner kills 20%)" in r["l"][0], f"cmd /evolution: {r}")
r = console("/players", 5)
check(r and r["l"][0].startswith("Players ("), f"cmd /players: {r}")
r = console("/f3d-status", 6)
check(r and any(str(l).startswith("[Zenith] client on port") for l in r["l"]), f"cmd /f3d-status: its lines come back, not to RCON: {r}")
# With /f3d-profile on its lines carry profilers, which can't go into a JSON message: text only.
F.commands["f3d-profile"](lua.table_from({"name": "f3d-profile"}))
prof = lua.eval('package.loaded["scripts.profile"]')
for _ in range(600):
    prof.run("probe", lambda: None)
    prof.end_tick()
r = console("/f3d-status", 61)
check(r and all(isinstance(l, str) for l in r["l"]) and "print only in Factorio" in r["l"][-1],
      f"cmd /f3d-status with profiling on: text only, the profiler's times left to Factorio's console: {r and r['l'][-2:]}")
F.commands["f3d-profile"](lua.table_from({"name": "f3d-profile"}))
r = console("/no-such-command", 7)
check(r and r.get("ok") == 0 and r["l"] == [], f"cmd: an unknown command answers ok = 0: {r}")
r = console("/c game.print(1)", 8)
check(r and r.get("ok") == 0, "cmd: Lua is never run from a packet")
F.researched_all = False
r = console("/cheat", 9)
zenith = F.remote["zenith"]
owner = zenith.player() or g.package.loaded["scripts.puppet"].held_for()
check(F.researched_all and r and r["l"][0] == "Researched every technology"
      and (r["l"][1] == "Cheat mode on for " + owner.name if owner else "crafting still takes time" in r["l"][1]),
      f"cmd /cheat: research, and cheat mode for the character's player (none for the bridge's own): {r}")
r = console("/cheat all", 10)
check(r and r["l"][-1].startswith("Gave the character ") and not r["l"][-1].startswith("Gave the character 0 "), f"cmd /cheat all gives the kit: {r}")
r = console("/cheat nowhere", 11)
check(r and r["l"] == ["No planet or platform called nowhere"], f"cmd /cheat <unknown place>: {r}")
check(same(zenith.character(), g.storage.f3d.puppet) and zenith.name() == (owner.name if owner else None),
      "remote zenith: the client's character, and the name of its player")
# Inputs: what anything on localhost could send to Zenith's console.
before = len(g.game.forces.player.platforms)
r = console("/f3d-platform new", 12)
check(r and "not from Zenith's" in r["l"][-1] and len(g.game.forces.player.platforms) == before,
      f"inputs: /f3d-platform new from Zenith's console makes no platform: {r}")
F.server_saved = False
r = console("/server-save", 13)
first_save = F.server_saved
F.server_saved = False
r2 = console("/server-save", 14)
check(first_save and not F.server_saved and r2 and "once a minute" in r2["l"][-1],
      f"inputs: /server-save from the client saves at most once a minute: {r} {r2}")
r = console("/f3d-profile trace 99999999999", 15)
check(r and "for 36000 ticks" in r["l"][-1], f"inputs: a profile trace is ten minutes at most: {r}")
g.package.loaded["scripts.profile"].trace(0)
# Owner's rule: in a multiplayer game console commands are for admins. A packet that came in on a
# player's machine is that player's; the server's own machine (player_index 0) is the server's.
guest = F.make_offline_player(9, "guest", 0, 0)


def console_from(text, cid, who):
    F.packet(json.dumps({"t": "cmd", "id": cid, "text": text}), CLIENT_PORT, who)
    tick(1)
    replies = [m for m in of_type(take(), "cmdr") if m["id"] == cid]
    return replies[-1] if replies else None


ADMINS_ONLY = ["Console commands are for admins in a multiplayer game"]
r = console_from("/version", 16, 9)
r_cheat = console_from("/cheat all", 17, 9)
r_none = console_from("/version", 18, 42)
guest.admin = True
r_admin = console_from("/version", 19, 9)
guest.admin = False
check(r and r["l"] == ADMINS_ONLY and r_cheat and r_cheat["l"] == ADMINS_ONLY and r_none and r_none["l"] == ADMINS_ONLY,
      f"multiplayer: a player who isn't an admin (or no player) runs no console command from Zenith: {r} {r_cheat} {r_none}")
check(r_admin and r_admin["l"] == ["2.1.23"], f"multiplayer: an admin's command runs: {r_admin}")
check(r.get("na") == 1 and "na" not in r_admin, f"multiplayer: a refused command says so (na), for the debug menu's greyed controls: {r}")
r_debug = console_from("/f3d-debug speed 4", 21, 9)
check(r_debug and r_debug.get("na") == 1 and "dbg" not in r_debug and g.game.speed == 1,
      f"multiplayer: /f3d-debug from a player who isn't an admin changes nothing: {r_debug}")
# The debug menu's /f3d-debug: time of day, the cycle, speed, pause, teleport; every reply has the state.
r = console("/f3d-debug", 22)
check(r and r.get("dbg", {}).get("sp") == 1 and r["dbg"]["s"] == "nauvis" and "x" in r["dbg"] and "sx" in r["dbg"],
      f"/f3d-debug: the state comes back as dbg: {r}")
r = console("/f3d-debug daytime 1.25", 23)
check(abs(g.game.surfaces[1].daytime - 0.25) < 1e-9 and r["dbg"]["dt"] == 0.25, f"/f3d-debug daytime wraps into 0-1: {r}")
r = console("/f3d-debug freeze on", 24)
check(g.game.surfaces[1].freeze_daytime and r["dbg"]["fz"] == 1, f"/f3d-debug freeze on: {r}")
console("/f3d-debug freeze off", 25)
r = console("/f3d-debug speed 100", 26)
check(g.game.speed == 16 and r["dbg"]["sp"] == 16, f"/f3d-debug speed is held to 16x at most: {r}")
r = console("/f3d-debug speed nan", 27)
check(g.game.speed == 16 and "1 is normal" in r["l"][0], f"/f3d-debug speed: not a number changes nothing: {r}")
console("/f3d-debug speed 1", 28)
r = console("/f3d-debug pause on", 29)
check(g.game.tick_paused and r["dbg"]["pa"] == 1, f"/f3d-debug pause on: {r}")
console("/f3d-debug pause off", 30)
check(not g.game.tick_paused, "/f3d-debug pause off")
# A screenshot's hold: the slowest speed (the bridge still ticks), the speed before back on `hold off`,
# and by itself after 30 ticks if the client never says.
console("/f3d-debug speed 2", 33)
r = console("/f3d-debug hold on", 34)
check(g.game.speed == 0.01 and r["dbg"]["hd"] == 1 and r["dbg"]["sp"] == 0.01, f"/f3d-debug hold on: the slowest speed: {r}")
r = console("/f3d-debug hold on", 35)
check(g.game.speed == 0.01 and r["dbg"]["hd"] == 1, "a second hold on keeps the speed from before")
r = console("/f3d-debug hold off", 36)
check(g.game.speed == 2 and r["dbg"]["hd"] == 0, f"/f3d-debug hold off: the speed before is back: {r}")
console("/f3d-debug hold on", 37)
tick(31)
check(g.game.speed == 2 and not g.storage.f3d_hold, "a hold nobody lets go of ends by itself after 30 ticks")
console("/f3d-debug hold on", 38)
console("/f3d-debug speed 3", 39)
tick(1)
check(g.game.speed == 3 and not g.storage.f3d_hold, "a speed set during the hold is kept, and the hold ends")
g.game.tick_paused = True
r = console("/f3d-debug hold on", 40)
g.game.tick_paused = False
check(g.game.speed == 3 and not g.storage.f3d_hold and r["dbg"]["hd"] == 0, f"a paused game isn't held (it stays paused): {r}")
console("/f3d-debug speed 1", 41)
c = g.storage.f3d.puppet
home = (c.position.x, c.position.y)
r = console("/f3d-debug teleport 20 -5", 31)
check(abs(c.position.x - 20) < 1 and abs(c.position.y + 5) < 1 and r["dbg"]["x"] == round(c.position.x * 256),
      f"/f3d-debug teleport moves the character: {r} {c.position.x},{c.position.y}")
r = console("/f3d-debug teleport 1e99 0", 32)
check("tiles on the character's surface" in r["l"][0], f"/f3d-debug teleport refuses wild numbers: {r}")
c.teleport(lua.table_from({"x": home[0], "y": home[1]}))
check(console("/version", 20)["l"] == ["2.1.23"], "multiplayer: from the server's own machine the bridge's character's commands run")
# The mod's own commands typed into Factorio's console by a player who isn't an admin.
F.printed = lua.table_from([])
rate_before = g.storage.f3d.rate
F.commands["f3d-rate"](lua.table_from({"name": "f3d-rate", "player_index": 9, "parameter": "3"}))
said = list(F.printed.values())
check(any("/f3d-rate is for admins in a multiplayer game" in str(x) for x in said) and g.storage.f3d.rate == rate_before,
      f"multiplayer: the mod's own commands in Factorio's console are for admins: {said}")

# --- single-player (hybrid) mode -----------------------------------------------------------------
F.multiplayer = False
player = F.make_player(puppet)
player.set_quick_bar_slot(1, 3, "iron-plate")
send({"t": "hello", "v": 1, "sid": "sp", "w": 0})
tick(4)  # a new client starts with the default work budget
msgs = take()
check(of_type(msgs, "welcome"), "single-player handshake works (send_udp without for_player)")
check(g.storage.f3d.bud.limit == 300, "a new client doesn't keep the budget the last one set")
qb = of_type(msgs, "qb")
check(qb and qb[-1]["l"][2] == "iron-plate", "hybrid: the quickbar is the player's own")
send({"t": "qb_set", "i": 12, "item": "transport-belt"})
send({"t": "qb_page", "p": 3})
tick(1)
qb = of_type(take(), "qb")
check(F.quickbar[12] == "transport-belt" and player.get_active_quick_bar_page(1) == 3 and qb and qb[-1]["l"][11] == "transport-belt"
      and qb[-1]["p"] == 3, "hybrid: qb_set and qb_page change the player's quickbar")
send({"t": "qb_set", "i": 12, "item": ""})
tick(1)
check(F.quickbar[12] is None, "hybrid: and qb_set \"\" clears a slot")
player.set_quick_bar_slot(1, 5, "wood")
tick(31)
qb = of_type(take(), "qb")
check(qb and qb[-1]["l"][4] == "wood", "hybrid: a change made in the Factorio window is sent")
F.chart_requests = lua.table_from([])
tick(121)
take()
check(len(F.chart_requests) == 0, "hybrid: the bridge doesn't chart (the player does)")
F.charted["0,0"] = True
chest = spawn("wooden-chest", puppet.position.x + 2, puppet.position.y + 1, force="player")
check(same(F.remote["zenith"].player(), player) and F.remote["zenith"].name() == player.name,
      "hybrid: remote zenith's player is the player (game.player in the client's Lua commands)")
send({"t": "cmd", "id": 20, "text": "/cheat"})
tick(1)
take()
check(F.cheat_mode is True, "hybrid: /cheat turns the player's cheat mode on")
send({"t": "cmd", "id": 21, "text": "/cheat off"})
tick(1)
take()
check(F.cheat_mode is False, "hybrid: /cheat off turns it off")
lines = selftest(player_index=1)
check(lines and all(l.startswith("PLAYER ") for l in lines) and any("PASS the player's quickbar can be read and written" in l for l in lines)
      and any("PASS character.player is the player playing it" in l for l in lines) and not any("FAIL" in l for l in lines),
      f"/f3d-selftest in single-player, answered in the game's console: {lines}")
check(F.quickbar[100] is None, "the self-test puts the quickbar slot it borrowed back")
chest.destroy()

# Mods' windows (mod_gui.lua): a mod's window on the real player's screen is sent as a tree, again
# when it changes, and its id leaves the list when the mod closes it.
take()
window = F.player_gui.screen.add(lua.table_from({"type": "frame", "name": "informatron_main", "caption": lua.table_from(["informatron.title"]),
                                                 "direction": "vertical", "location": lua.table_from({"x": 120, "y": 80})}))
window.add(lua.table_from({"type": "label", "name": "text_1", "caption": "Hello from a mod"}))
grid = window.add(lua.table_from({"type": "table", "name": "grid", "column_count": 2}))
grid.add(lua.table_from({"type": "sprite-button", "name": "b1", "sprite": "item/iron-plate", "number": 12}))
F.player_gui.top.add(lua.table_from({"type": "sprite-button", "name": "informatron_button", "sprite": "informatron"}))
tick(31)
mg = of_type(take(), "mgui")
by_root = {m["l"][0]["r"]: m["l"][0] for m in mg if m["l"]}
win = by_root.get("screen", {})
check(win.get("i") == window.index and win.get("at") == [120, 80] and "mod" not in win
      and win["e"]["t"] == "frame" and win["e"]["c"] == ["informatron.title"] and win["e"]["d"] == "vertical"
      and win["e"]["a"][0]["c"] == "Hello from a mod" and win["e"]["a"][1]["cc"] == 2
      and win["e"]["a"][1]["a"][0]["sp"] == "item/iron-plate" and win["e"]["a"][1]["a"][0]["nu"] == 12
      and by_root.get("top", {}).get("e", {}).get("sp") == "informatron" and sorted(mg[-1]["ids"]) == sorted([window.index, by_root["top"]["i"]]),
      f"mgui: a mod's window and top button are sent as trees, with where they are: {mg}")
window.children[1].caption = "Changed"
tick(30)
mg = of_type(take(), "mgui")
check(len(mg) == 1 and mg[0]["l"][0]["i"] == window.index and mg[0]["l"][0]["e"]["a"][0]["c"] == "Changed",
      f"mgui: only the window that changed is sent again: {mg}")
tick(30)
check(not of_type(take(), "mgui"), "mgui: nothing is sent while nothing changes")
window.destroy()
tick(30)
mg = of_type(take(), "mgui")
check(mg and mg[-1]["ids"] == [by_root["top"]["i"]] and mg[-1]["l"] == [], f"mgui: a closed window leaves the list: {mg}")
# A client not drawing mods' windows (hello mg 0) costs no server time: they aren't read or sent.
# One that doesn't say gets them, as older clients always did.
lua.execute("""
function F_watch_top()
  local real = F.player_gui.top
  F_top_reads = 0
  F.player_gui.top = setmetatable({}, { __index = function(_, k) F_top_reads = F_top_reads + 1; return real[k] end })
  return function() F.player_gui.top = real end
end
""")
unwatch = g.F_watch_top()
send({"t": "hello", "v": 1, "sid": "sp", "w": 1, "mg": 0})
tick(31)
off = of_type(take(), "mgui")
check(off and off[-1]["ids"] == [] and off[-1]["l"] == [] and g.F_top_reads == 0,
      f"mgui: a client saying mg 0 is told its windows are gone, and they aren't read: {off} ({g.F_top_reads} reads)")
tick(61)
check(not of_type(take(), "mgui") and g.F_top_reads == 0, f"mgui: and then nothing is read or sent ({g.F_top_reads} reads)")
unwatch()
send({"t": "hello", "v": 1, "sid": "sp", "w": 1, "mg": 1})
tick(31)
check([m for m in of_type(take(), "mgui") if m["l"] and m["l"][0]["i"] == by_root["top"]["i"]], "mgui: turned on (mg 1), the windows are sent again")
send({"t": "hello", "v": 1, "sid": "sp", "w": 1, "mg": 0})
tick(31)
take()
send({"t": "hello", "v": 1, "sid": "sp", "w": 1})
tick(31)
check([m for m in of_type(take(), "mgui") if m["l"] and m["l"][0]["i"] == by_root["top"]["i"]], "mgui: a hello without mg gets them, as before")

# Informatron's buttons (mod_gui.lua PRESSERS): the bridge presses them through Informatron's remote
# interface (owner: clicking its window from Zenith missed nearly every time), and its page text wraps
# where Factorio wraps it.
opened_pages = []
def open_page(d):
    opened_pages.append((d["player_index"], d["interface"], d["page_name"]))
    para.caption = "Page " + d["page_name"]


F.remote["informatron"] = lua.table_from({"informatron_open_to_page": open_page})
info = F.player_gui.screen.add(lua.table_from({"type": "frame", "name": "informatron", "direction": "vertical"}))
info.get_mod = lambda *a: "informatron"
menu_b = info.add(lua.table_from({"type": "button", "name": "menu-informatron", "caption": "Informatron",
                                  "tags": lua.table_from({"root": "informatron", "interface": "informatron", "page_name": "informatron"})}))
menu_b.get_mod = lambda *a: "informatron"
close_b = info.add(lua.table_from({"type": "sprite-button", "name": "close", "sprite": "utility/close",
                                   "tags": lua.table_from({"root": "informatron", "action": "close-gui"})}))
close_b.get_mod = lambda *a: "informatron"
other_b = info.add(lua.table_from({"type": "button", "name": "other", "caption": "Not Informatron's"}))
para = info.add(lua.table_from({"type": "label", "name": "para", "caption": "A long paragraph"}))
para.style.single_line = False
para.style.maximal_width = 888
info.style.minimal_height = 800
info.style.maximal_height = 800
menu_b.style.horizontally_stretchable = True
g.game.get_player(1).opened = info
tick(31)
mg = [m for m in of_type(take(), "mgui") if m["l"] and m["l"][0]["i"] == info.index]
kids = {k["n"]: k for k in mg[-1]["l"][0]["e"]["a"]} if mg else {}
check(kids.get("menu-informatron", {}).get("ck") is True and kids.get("close", {}).get("ck") is True and "ck" not in kids.get("other", {})
      and kids["menu-informatron"].get("ix") == menu_b.index,
      f"mgui: Informatron's tagged buttons are marked ck with their index, another mod's button isn't: {kids}")
check(kids.get("para", {}).get("ml") is True and kids["para"].get("mw") == 888, f"mgui: a label Factorio wraps carries ml and mw: {kids.get('para')}")
check(mg[-1]["l"][0]["e"].get("sz") == [0, 0, 800, 800] and kids["menu-informatron"].get("hs") is True and "sz" not in kids.get("other", {}),
      f"mgui: style sizes (sz) and stretching (hs) as Factorio lays the window out: {mg[-1]['l'][0]['e'].get('sz')}")
send({"t": "mpress", "ix": menu_b.index})
tick(1)
check(opened_pages == [(1, "informatron", "informatron")], f"mpress on a menu button opens its page through Informatron's interface: {opened_pages}")
check(any(m["l"] and m["l"][0]["i"] == info.index for m in of_type(take(), "mgui")), "mpress: the windows are read again on the next tick")
send({"t": "mpress", "ix": other_b.index})
tick(1)
check(len(opened_pages) == 1, "mpress on a button no presser knows does nothing")
send({"t": "mpress", "ix": close_b.index})
tick(1)
check(g.game.get_player(1).opened is None, "mpress on Informatron's close button clears player.opened (Informatron closes on on_gui_closed)")
take()
wm = F.player_gui.screen.add(lua.table_from({"type": "frame", "name": "se_watermark_string_frame", "ignored_by_interaction": True}))
wm.add(lua.table_from({"type": "label", "name": "se_watermark_string_label", "caption": "SE 0.7.64 T602"}))
tick(31)
wmsg = [m for m in of_type(take(), "mgui") if m["l"] and m["l"][0]["i"] == wm.index]
check(wmsg and wmsg[-1]["l"][0]["e"].get("ig") is True, f"mgui: a frame clicks go through (Space Exploration's watermark) carries ig: {wmsg[-1:]}")
wm.destroy()
g.game.get_player(1).opened = None
info.destroy()
del F.remote["informatron"]
tick(31)
take()

# --- acting as the player (as_player.lua): other mods get the player events -----------------------
px, py = math.floor(puppet.position.x) + 4, math.floor(puppet.position.y) - 3


def belts_at(x, y):
    return list(puppet.surface.find_entities_filtered(lua.table_from({"name": "transport-belt", "position": lua.table_from({"x": x, "y": y})})).values())


puppet.insert(lua.table_from({"name": "transport-belt", "count": 3}))
F.player_events = lua.table_from([])
send({"t": "build", "item": "transport-belt", "x": fixed(px + 0.5), "y": fixed(py + 0.5), "d": 4})
tick(2)
take()
built = belts_at(px + 0.5, py + 0.5)
check("on_built_entity" in list(F.player_events.values()) and len(built) == 1,
      f"as player: a build goes through the player's cursor and raises on_built_entity: {list(F.player_events.values())}")
check(not player.cursor_stack.valid_for_read and puppet.get_main_inventory().get_item_count("transport-belt") >= 2,
      "as player: the cursor is empty again and the rest is back in the inventory")
# Flipped (m = 1): checked without `mirror`, which can_build_from_cursor doesn't take (the fake throws
# on it, and the old code took that error message for a yes), built with it.
def free_at(x, y):
    return not list(puppet.surface.find_entities_filtered(lua.table_from({"position": lua.table_from({"x": x, "y": y})})).values())


fx_, fy_ = next((px + 0.5 + dx, py + 0.5 + dy) for dy in (-1, -2, 1, 2) for dx in (0, -1, -2) if free_at(px + 0.5 + dx, py + 0.5 + dy))
F.player_events = lua.table_from([])
send({"t": "build", "item": "transport-belt", "x": fixed(fx_), "y": fixed(fy_), "d": 4, "m": 1})
tick(2)
take()
check("on_built_entity" in list(F.player_events.values()) and len(belts_at(fx_, fy_)) == 1
      and not player.cursor_stack.valid_for_read,
      f"as player: a flipped build is checked and built through the cursor: {list(F.player_events.values())}")
belt = built[0] if built else None
if belt:
    send({"t": "rotate", "u": belt.unit_number, "p": eid["transport-belt"], "x": fixed(belt.position.x), "y": fixed(belt.position.y)})
    tick(2)
    take()
    check("on_player_rotated_entity" in list(F.player_events.values()) and belt.direction == 8,
          "as player: rotating raises on_player_rotated_entity")
box = spawn("wooden-chest", px + 2, py, force="player")
send(open_cmd(box))
tick(2)
take()
check(same(player.opened, box) and "on_gui_opened" in list(F.player_events.values()),
      "as player: opening a machine sets the player's opened (on_gui_opened)")
send({"t": "close"})
tick(2)
take()
check(player.opened is None and "on_gui_closed" in list(F.player_events.values()), "as player: closing it closes the player's (on_gui_closed)")
if belt:
    for _ in range(6):
        send({"t": "mine", "u": belt.unit_number, "p": eid["transport-belt"], "x": fixed(belt.position.x), "y": fixed(belt.position.y)})
        tick(10)
    take()
    check("on_player_mined_entity" in list(F.player_events.values()) and not belt.valid,
          "as player: mining goes through the player (on_player_mined_entity)")
    send({"t": "mine_stop"})
box.destroy()
g.settings["global"]["f3d-act-as-player"]["value"] = False
F.player_events = lua.table_from([])
send({"t": "build", "item": "transport-belt", "x": fixed(px + 0.5), "y": fixed(py + 2.5), "d": 4})
tick(2)
take()
check(len(belts_at(px + 0.5, py + 2.5)) == 1 and len(F.player_events) == 0,
      "f3d-act-as-player off: the bridge builds by script again, no player events")
g.settings["global"]["f3d-act-as-player"]["value"] = True

check(radar_list[far_radar_unit] is None, "a gone radar leaves storage on M.tick's prune tick")

# A linked belt bends the belt beside it like any belt: building one sends that belt's record again.
bent = belts_at(px + 0.5, py + 2.5)[0]
send({"t": "sub", "c": [[math.floor(bent.position.x / 32), math.floor(bent.position.y / 32)]]})
tick(10)
take()
linked = spawn("linked-belt", px + 1.5, py + 2.5, force="player", linked_belt_type="output")
F["raise"]("script_raised_built", lua.table_from({"entity": linked}))
tick(1)
check(any(m["e"][0] == bent.unit_number for m in of_type(take(), "upd")),
      "a linked belt built beside a belt updates that belt (its shape may bend)")

# --- inputs: numbers and sizes from a packet -------------------------------------------------------
# tonumber("1e999") is inf, so a packet can carry one as a string; the tick isn't under pcall.
send({"t": "hello", "v": 1, "sid": "sp", "w": 1})
c = g.storage.f3d.puppet
for d in ("1e999", 1e300):
    send({"t": "walk", "d": d})
    try:
        tick(2)
        walked = True
    except Exception as err:  # the game would stop: the error is in on_tick
        walked = False
        print("walk tick error:", str(err).splitlines()[0])
    check(walked and not c.walking_state.walking,
          f"inputs: walk with d {d} stops instead of writing a NaN or huge direction in the tick")
send({"t": "walk", "d": -1})
old_focus = {"x": int(g.storage.f3d.focus.x * 256), "y": int(g.storage.f3d.focus.y * 256), "r": int(g.storage.f3d.focus.r)}
send({"t": "focus", "x": "1e999", "y": -1e300, "r": 32})
f = g.storage.f3d.focus
check(abs(f.x) <= 1000000 and abs(f.y) <= 1000000 and f.x == f.x,
      f"inputs: a focus far off the map is clamped to its edge: {f.x}, {f.y}")
send({"t": "focus", **old_focus})
send({"t": "shoot", "m": 1, "x": "1e999", "y": 0})
try:
    tick(2)
    shot = True
except Exception as err:
    shot = False
    print("shoot tick error:", err)
sh = g.storage.f3d.shooting
check(shot and sh and abs(sh.x) <= 1000000, f"inputs: an aim point off the map is clamped before the tick shoots at it")
send({"t": "shoot", "m": -1})
tick(1)
old_subs = [[int(v) for v in k.split(",")] for k in g.storage.f3d.subs.keys()]
send({"t": "sub", "c": [[1e300, 0], ["1e999", 1], [0, 2e9], [0, 0]], "h": [[1, 1e300, 0, 1, 1]]})
keys = list(g.storage.f3d.subs.keys())
check(keys == ["0,0"], f"inputs: chunks off the map aren't subscribed (the tick would read them): {keys}")
send({"t": "resync", "c": [[1e300, 0]]})
try:
    tick(3)
    subbed = True
except Exception as err:
    subbed = False
    print("sub tick error:", err)
check(subbed, "inputs: and the tick goes on")
send({"t": "sub", "c": old_subs})
take()
# Planners and copy over the whole map are refused: they read every entity in the area in one tick.
big = {"i": 0, "x1": -10 ** 9, "y1": -10 ** 9, "x2": 10 ** 9, "y2": 10 ** 9}
send({"t": "decon", **big})
send({"t": "copy", **big})
tick(1)
said = texts(take())
check(said.count("That area is too big (at most 2048 by 2048 tiles)") == 2,
      f"inputs: decon and copy over the whole map are refused: {said}")
# A long thin drag (a rail line, panning the remote view) is far longer than 2048 a side but small.
send({"t": "decon", "i": 0, "x1": 0, "y1": 0, "x2": 20000 * 256, "y2": 8 * 256})
tick(1)
said = texts(take())
check(not any("too big" in s for s in said), f"inputs: a long thin planner drag goes through: {said}")
# A blueprint string's parts are the client's 8000 characters at most: an upload can't hold 4096
# whole datagrams in storage.
send({"t": "bp_set", "q": 1, "i": 0, "id": 7, "part": 1, "parts": 4096, "d": "x" * 9000})
check(g.storage.f3d.bp_up is None, "inputs: a bp_set part longer than 8192 characters isn't kept")
send({"t": "bp_set", "q": 1, "i": 0, "id": 7, "part": 1, "parts": 2, "d": "x" * 8000})
check(g.storage.f3d.bp_up is not None and g.storage.f3d.bp_up.got == 1, "inputs: one of 8000 is")
g.storage.f3d.bp_up = None
# Clients that come and go with a new session id each time don't park a character each, forever.
F.multiplayer = True
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(1)
units = set()
for i in range(40):
    send({"t": "hello", "v": 1, "sid": f"churn{i}", "w": 0}, port=PORT_B)
    tick(1)
    st = g.storage.f3d_extra[PORT_B]
    if st and st.puppet:
        units.add(st.puppet.unit_number)
    send({"t": "bye"}, port=PORT_B)
    tick(1)
take_by_port()
parked = len(list(g.storage.f3d_parked.keys()))
check(parked <= 16 and len(units) <= 17,
      f"inputs: 40 clients coming and going park 16 characters at most ({parked}) and make {len(units)}, not 40")

# --- tick-cost audit: storage that grew without bound -------------------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(2)
take()
s = g.storage.f3d
B.set(lua.table_from({"u": 300}))
fxa, fya = s.focus.x, s.focus.y
# A creature hurt near the focus and never killed there (it walked off, a script removed it) kept
# its hit cue in storage: cues older than their interval go.
hurt_biter = spawn("small-biter", fxa + 3, fya + 3, force="enemy")
F["raise"]("on_entity_damaged", lua.table_from({"entity": hurt_biter, "force": g.game.forces.player, "final_damage_amount": 1}))
check(s.hit_fx_ticks[hurt_biter.unit_number] is not None, "a hit near the focus keeps its cue's tick")
hurt_biter.destroy()
tick(20)
check(s.hit_fx_ticks[hurt_biter.unit_number] is None, "hit cues older than their interval are forgotten (they only went on a death)")
# Turrets: a firing cue older than its interval goes, and a turret gone between a sweep and the
# next search (the search runs first in its tick) is no longer kept in turret_last until a handshake.
gone_turret = spawn("gun-turret", fxa + 5, fya + 5, force="player")
gone_turret.shooting_target = None
F["raise"]("on_entity_damaged", lua.table_from({"entity": hurt_biter.valid and hurt_biter or spawn("small-biter", fxa + 6, fya + 6, force="enemy"),
                                                "cause": gone_turret, "force": g.game.forces.player, "final_damage_amount": 1}))
check(s.turret_fire_ticks[gone_turret.unit_number] is not None, "a turret's hit keeps its firing cue's tick")
tick(1)
while g.game.tick % 60 != 0:  # past a search (tick % 60 == 0),
    tick(1)
while g.game.tick % 60 != 59:  # to the last sweep before the next
    tick(1)
check(s.turret_last[gone_turret.unit_number] is not None, "the turret is kept for the sweep's shot count")
gone_turret.destroy()
tick(8)
take()
check(s.turret_last[gone_turret.unit_number] is None, "a turret gone before the next search is dropped from turret_last")
check(s.turret_fire_ticks[gone_turret.unit_number] is None, "firing cues older than their interval are forgotten")
# With no client connected, a fluid entity removed (robots mining pipes on a server) was queued in
# storage until the next client's handshake.
send({"t": "bye"})
tick(1)
take()
far_pipe = spawn("pipe", fxa + 9.5, fya + 9.5, force="player")
for _ in range(5):
    F["raise"]("script_raised_destroy", lua.table_from({"entity": far_pipe}))
tick(1)
check(len(g.storage.f3d.pipe_refresh) == 0, f"no pipe refresh is queued without a client: {len(g.storage.f3d.pipe_refresh)}")
far_pipe.destroy()
send({"t": "hello", "v": 1, "sid": "s9", "w": 1})
tick(10)
take()
# Items on the ground, enemies and robots' cargo (rate.lua jobs with a slack) learn what they cost
# from what they read, as the other slack jobs do; they stayed at their first guess.
s = g.storage.f3d
B.set(lua.table_from({"u": 300}))
for i in range(30):
    spawn("small-biter", s.focus.x + 2 + i * 0.3, s.focus.y - 4, force="enemy")
tick(130)
take()
cost = to_py(g.storage.f3d.bud.cost)
check(cost.get("en", 10) != 10 and "en" in cost and "gi" in cost and "rc" in cost,
      f"en, gi and rc learn their cost from what they read: {cost}")

# --- jobs saved by an older bridge (last, so the ticks they take shift no section above) ---------
send({"t": "hello", "v": 1, "sid": "old-saves", "w": 1, "z": 1, "bl": 1})
tick(6)
take()
send({"t": "gfx", "fp": "00c0ffee12345678"})
tick(2)
gfx_parts = sorted(m["part"] for m in of_type(take(), "gfx") if m.get("fp") == "00c0ffee12345678")
check(gfx_parts == [1, 2], f"gfx: the parts of the list asked for: {gfx_parts}")
# A queue saved with other mods than the game has now (its list's fingerprint changed) would send
# the new list's parts under the old fingerprint, which the client keeps: it is dropped.
lua.execute('storage.f3d.gfx = { fp = "0123456789abcdef", n = 2, l = { 1, 2 }, at = 1 }')
tick(2)
check(not of_type(take(), "gfx") and g.storage.f3d.gfx is None, "gfx: a queue for another list (mods changed since) is dropped")
# A bridge before 0.1.2 (0.1.1, the public release) saved its round of belt items without ring_keys
# or count. The save's client is served until it times out, and if that client says hello again
# (with `bl`) its lanes are kept at once: reading the old round mid-ring indexed nil every tick,
# which stops the game. It is started over.
focus = g.storage.f3d.focus
old_belt = spawn("transport-belt", math.floor(focus.x) + 3.5, math.floor(focus.y) + 2.5, force="player", direction=4)
F.put_on_belt(old_belt, 1, "iron-plate", 0.3, 9900)
g.OLD_BELT = old_belt
lua.execute("""
local f, now = storage.f3d.focus, game.tick
storage.f3d.bi = { m = 1, dues = 0, work = 0, last = now - 3, round = {
  start = now - 2, si = OLD_BELT.surface.index, fx = f.x, fy = f.y, r = 24, target = now + 3, band = 0,
  belts = { OLD_BELT }, rings = { 0 }, i = 1, ring = 0, ring_items = 0, items = 0, units = 0 } }
OLD_BELT = nil
""")
try:
    tick(24)
    old_ok = True
except Exception as err:  # in Factorio the mod's error stops the game, and again every tick
    old_ok = False
    print("old round:", err)
old_by_k, _ = bi_items(take())
old_items = {u for items in old_by_k.values() for u in items}
check(old_ok and 9900 in old_items, f"bi: a round saved by a bridge before 0.1.2 starts over, not an error every tick: {sorted(old_items)}")
old_belt.destroy()

# Back from another surface (Factorissimo's buildings) the client offers its whole view: answers
# that need no reading (same, none) don't wait for f3d-chunks-per-tick, only a chunk to read does.
send({"t": "sub", "c": [[30, 30]]})
tick(4)
take()
send({"t": "sub", "c": [[0, 0]]})
tick(10)
kept = [m for m in of_type(take(), "chunk") if (m["cx"], m["cy"]) == (0, 0)]
send({"t": "sub", "c": [[31, 30]]})
tick(4)
take()
check(kept and kept[0].get("rv") is not None, f"a chunk to keep: {kept}")
if kept:
    offer = [kept[0]["rs"], 0, 0, kept[0]["rv"], kept[0]["n"]]
    send({"t": "sub", "c": [[0, 0], [40, 40], [41, 40], [42, 40], [1, 0], [43, 40]], "h": [offer]})
    tick(4)  # one chunk read a tick (f3d-chunks-per-tick 1): six chunks one by one took 6 ticks or more
    quick = {(m["cx"], m["cy"]): m for m in of_type(take(), "chunk")}
    check(quick.get((0, 0), {}).get("same") is not None and all(quick.get((x, 40), {}).get("none") for x in (40, 41, 42, 43))
          and quick.get((1, 0), {}).get("tiles"),
          f"a kept chunk and ungenerated ones don't wait behind the one chunk read: {sorted(quick)}")

# A belt runs all the time: only one a network switches off stands still, and only one with a wire
# or a logistic condition is looked at (belt_switch.lua), `st` state 5, 0 running again.
send({"t": "hello", "v": 1, "sid": "old-saves", "w": 1, "z": 1, "bl": 1})
wired_belt = spawn("transport-belt", 14.5, 16.5, force="player")
plain_belt = spawn("transport-belt", 15.5, 16.5, force="player")
logistic_belt = spawn("transport-belt", 16.5, 16.5, force="player")
belt_const = spawn("constant-combinator", 14.5, 18.5, force="player")
wired_belt.get_wire_connector(ids.circuit_red, True).connect_to(belt_const.get_wire_connector(ids.circuit_red, True))
logistic_belt.get_or_create_control_behavior().connect_to_logistic_network = True
for e in (wired_belt, plain_belt, logistic_belt, belt_const):
    F["raise"]("script_raised_built", lua.table_from({"entity": e}))
tick(2)
take()
watched = g.storage.f3d.beltw
check(watched and watched[wired_belt.unit_number] and watched[logistic_belt.unit_number] and not watched[plain_belt.unit_number],
      "a belt with a wire or a logistic condition is watched, a plain one isn't")


def belt_rows(ticks=35):
    tick(ticks)
    send({"t": "hello", "v": 1, "sid": "old-saves", "w": 1, "z": 1, "bl": 1})
    rows = [v for m in of_type(take(), "st") for v in m["l"]]
    return dict(zip(rows[0::2], rows[1::2]))


quiet = belt_rows()
check(wired_belt.unit_number not in quiet and plain_belt.unit_number not in quiet, f"belts running say nothing: {quiet}")
wired_belt.status = g.defines.entity_status.disabled_by_control_behavior
logistic_belt.status = g.defines.entity_status.disabled_by_control_behavior
rows = belt_rows()
check(rows.get(wired_belt.unit_number) == 5 and rows.get(logistic_belt.unit_number) == 5 and plain_belt.unit_number not in rows,
      f"switched off: st 5 for the belts that went off: {rows}")
rows = belt_rows()
check(wired_belt.unit_number not in rows, f"and only once: {rows}")
retold = {}
for _ in range(20):
    retold.update(belt_rows())
check(retold.get(wired_belt.unit_number) == 5, f"told again now and then, for a client that forgot: {retold}")
wired_belt.status = g.defines.entity_status.working
rows = belt_rows()
check(rows.get(wired_belt.unit_number) == 0, f"running again: st 0: {rows}")
logistic_belt.get_control_behavior().connect_to_logistic_network = False
F["raise"]("script_raised_built", lua.table_from({"entity": logistic_belt}))
tick(1)
rows = belt_rows(1)
check(rows.get(logistic_belt.unit_number) == 0 and not g.storage.f3d.beltw[logistic_belt.unit_number],
      f"a belt off that nothing can switch off any more is told it runs, and forgotten: {rows}")
# A wire added with no event: the combinator's next look finds it, and the belt at its end is watched.
late_belt = spawn("transport-belt", 17.5, 16.5, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": late_belt}))
tick(2)
check(not g.storage.f3d.beltw[late_belt.unit_number], "a belt with no wire yet isn't watched")
late_belt.get_wire_connector(ids.circuit_red, True).connect_to(belt_const.get_wire_connector(ids.circuit_red, True))
send({"t": "hello", "v": 1, "sid": "old-saves", "w": 1, "z": 1, "bl": 1})
# (Within a round of the wire look's strips, 8 x 30 ticks: /f3d-perf wire_strips.)
for _ in range(300):
    tick(1)
    if g.storage.f3d.beltw[late_belt.unit_number]:
        break
check(g.storage.f3d.beltw[late_belt.unit_number], "a wire put on it later, with no event, is noticed from its combinator")
take()
late_belt.destroy()
wired_belt.destroy()
plain_belt.destroy()
logistic_belt.destroy()
belt_const.destroy()
send({"t": "hello", "v": 1, "sid": "old-saves", "w": 1, "z": 1, "bl": 1})
tick(70)
check(next(iter(g.storage.f3d.beltw.items()), None) is None, "a watched belt gone is forgotten after a round")
take()

# Where a silo's rocket is, for the doors and its rise (H16).
_pp = puppet.position
silo_p = spawn("rocket-silo", _pp.x + 14.5, _pp.y + 0.5, force="player")
_rss = g.defines.rocket_silo_status
_states = []
for _status in (_rss.doors_opening, _rss.rocket_rising, _rss.rocket_ready, _rss.doors_closing, _rss.building_rocket):
    silo_p.rocket_silo_status = _status
    tick(61)
    _sent = [m["l"] for m in of_type(take(), "st")]
    _states.append(next((l[i + 1] for l in _sent for i in range(0, len(l), 2) if l[i] == silo_p.unit_number), None))
check(_states == [2, 3, 4, 5, 1], f"a silo's st says where its rocket is: doors opening 2, rising 3, up 4, closing 5, building 1: {_states}")
silo_p.destroy()

# A save made with another version of the bridge keeps its clients and their half-done jobs, in that
# version's shape: on loading it they are dropped, so the next hello starts clean. What belongs to
# the game stays.
PORT_OLD = 34277
F.multiplayer = True
send({"t": "hello", "v": 1, "sid": "old-bridge", "w": 1, "z": 1, "bl": 1})
send({"t": "hello", "v": 1, "sid": "old-extra", "w": 0}, port=PORT_OLD)
tick(3)
F.take_sent()
st = g.storage.f3d
old_unit, extra_unit = st.puppet.unit_number, g.storage.f3d_extra[PORT_OLD].puppet.unit_number
st.techs_job = "half a job from an older bridge"
st.bi = lua.table_from({"round": {"si": 1}})
st.hs_stage = 2
st.quickbar = lua.table_from({"page": 3, "sel": 0, "items": {}})
F.on_config(lua.table_from({"mod_changes": {"another-mod": {"old_version": "1.0.0", "new_version": "1.1.0"}}}, recursive=True))
check(st.client is not None and st.techs_job is not None and g.storage.f3d_extra[PORT_OLD] is not None,
      "another mod's update leaves the bridge's clients and jobs alone")
F.on_config(lua.table_from({"mod_changes": {"factorio-3d-bridge": {"old_version": "0.1.3", "new_version": "0.1.3"}}}, recursive=True))
check(st.client is not None and st.techs_job is not None, "the same version of the bridge leaves them alone")
F.on_config(lua.table_from({"mod_changes": {"factorio-3d-bridge": {"old_version": "0.1.1", "new_version": "0.1.3"}}}, recursive=True))
check(st.client is None and st.techs_job is None and st.bi is None and st.hs_stage is None,
      f"a new version of the bridge drops the save's client and half-done jobs: {st.client} {st.techs_job} {st.bi} {st.hs_stage}")
check(st.puppet.unit_number == old_unit and st.quickbar.page == 3 and st.outbox is not None and st.subs is not None,
      "and keeps the character and the quickbar, with the tables every client needs")
check(len(g.storage.f3d_extra) == 0 and g.storage.f3d_parked["old-extra"].unit_number == extra_unit,
      f"other clients are dropped too, their characters waiting for them: {len(g.storage.f3d_extra)}")
tick(5)
check(not list(F.take_sent().values()), "nothing is sent until a client says hello")
send({"t": "hello", "v": 1, "sid": "old-bridge", "w": 1, "z": 1, "bl": 1})
tick(2)
fresh = take()
welcomes = of_type(fresh, "welcome")
check(welcomes and welcomes[0]["r"] == 1, f"the client's next hello gets a fresh handshake, numbered from 1: {welcomes}")
F.multiplayer = False

# The barrier round each step (barrier.lua): a step that fails stops only itself, says so in the log
# and /f3d-status, runs once a tick whether or not it is being profiled, and writes nothing of its
# own to storage.
lua.execute("""
function F_upvalue(fn, name, depth)
  depth = depth or 4
  for i = 1, 255 do
    local n, v = debug.getupvalue(fn, i)
    if not n then
      return nil
    end
    if n == name then
      return v
    end
    if type(v) == "function" and depth > 0 then
      local found = F_upvalue(v, name, depth - 1)
      if found ~= nil then
        return found
      end
    end
  end
end
function F_fail_step(name)
  for _, step in ipairs(F_upvalue(F.handlers[defines.events.on_tick], "STEPS")) do
    if step[1] == name then
      local before = step[2]
      F_step_calls = 0
      step[2] = function()
        F_step_calls = F_step_calls + 1
        storage.f3d.half_done = (storage.f3d.half_done or 0) + 1
        error("boom in the step")
      end
      return function() step[2] = before end
    end
  end
end
function F_fail_event(name)
  local wrapper = F.handlers[defines.events[name]]
  for i = 1, 255 do
    local n, v = debug.getupvalue(wrapper, i)
    if not n then
      return nil
    end
    if n == "handler" then
      debug.setupvalue(wrapper, i, function() error("boom in the event") end)
      return function() debug.setupvalue(wrapper, i, v) end
    end
  end
end
""")
barrier = lua.eval('package.loaded["scripts.barrier"]')
barrier.rethrow = False
send({"t": "hello", "v": 1, "sid": "old-bridge", "w": 1, "z": 1, "bl": 1})
tick(20)
take()
F.printed = lua.table()
st = g.storage.f3d
restore_step = g.F_fail_step("tracker")
send({"t": "hello", "v": 1, "sid": "old-bridge", "w": 1, "z": 1, "bl": 1})
tick(30)
msgs = take()
logs = [str(p) for p in F.printed.values()]
errors = [p for p in logs if "ERROR in step 'tracker'" in p]
check(g.F_step_calls == 30 and st.half_done == 30,
      f"a failing step runs once a tick, and what it wrote before failing stays: {g.F_step_calls} {st.half_done}")
check(g.storage.f3d.client.port == CLIENT_PORT and of_type(msgs, "me"), "the game goes on: the steps after it still run for the client")
check(len(errors) == 1 and "boom in the step" in errors[0] and "tick" in errors[0],
      f"a failing step is logged with its name and error, once for the first 600 ticks: {errors}")
check(any("Bridge error in tracker" in m.get("text", "") for m in of_type(msgs, "msg")), "and the client is told")
keys_before = (set(g.storage.keys()), set(st.keys()))
barrier.call("direct", lua.eval('function() error("boom") end'))
check((set(g.storage.keys()), set(st.keys())) == keys_before, "the barrier adds nothing to storage")
take()
F.printed = lua.table()
F.command(lua.table_from({"name": "f3d-status"}))
status = [str(p) for p in F.printed.values()]
check(any("ERROR: step 'tracker' failed 30 time(s)" in p and "boom in the step" in p for p in status),
      f"/f3d-status lists a failing step: {status[:3]}")
F.printed = lua.table()
for _ in range(11):
    send({"t": "hello", "v": 1, "sid": "old-bridge", "w": 1, "z": 1, "bl": 1})
    tick(60)
take()
errors = [str(p) for p in F.printed.values() if "ERROR in step 'tracker'" in str(p)]
check(len(errors) == 1 and "more times" in errors[0], f"it keeps being logged, at most every 600 ticks: {errors}")
# Under /f3d-profile and a trace at once: still once a tick.
g.F_step_calls = 0
profile_mod = lua.eval('package.loaded["scripts.profile"]')
F.commands["f3d-profile"](lua.table_from({"name": "f3d-profile"}))
profile_mod.trace(3)
send({"t": "hello", "v": 1, "sid": "old-bridge", "w": 1, "z": 1, "bl": 1})
tick(3)
profile_mod.trace(0)
F.commands["f3d-profile"](lua.table_from({"name": "f3d-profile"}))
check(g.F_step_calls == 3, f"profiling and tracing don't run a failing step twice: {g.F_step_calls} calls in 3 ticks")
restore_step()
st.half_done = None
# An event handler: the same wall, whichever client it is for.
restore_event = g.F_fail_event("on_built_entity")
F.printed = lua.table()
F["raise"]("on_built_entity", lua.table_from({}))
check(any("ERROR in step 'on_built_entity'" in str(p) and "boom in the event" in str(p) for p in F.printed.values()),
      f"a failing event handler is caught and logged by its event's name: {list(F.printed.values())}")
restore_event()
# live_check's barrier check forgets the steps it failed on purpose; the others stay listed.
barrier.forget("on_built_entity")
barrier.forget("never-failed")
F.printed = lua.table()
F.command(lua.table_from({"name": "f3d-status"}))
listed = set(re.findall(r"ERROR: step '([^']+)'", " ".join(str(p) for p in F.printed.values())))
check(listed == {"tracker", "direct"}, f"barrier.forget drops one step from /f3d-status and keeps the rest: {listed}")
barrier.rethrow = True
take()

# --- changes made without events -----------------------------------------------------------
# A script's create_entity without raise_built and destroy() without raise_destroy raise no event:
# the chunks near the client are counted in turn (world.lua count_check), and one whose count
# changed unseen is sent again (trees cleared by a script stayed drawn, filming the B-roll).
send({"t": "sub", "c": []})
tick(2)
send({"t": "sub", "c": [[0, 0], [1, 0]]})
tick(40)
take()
quiet = spawn("tree-01", 40.5, 9.5)
tick(16)
resent = [m for m in take() if m["t"] in ("chunk", "ents") and (m["cx"], m["cy"]) == (1, 0)]
check(any(m["t"] == "chunk" and m.get("tiles") for m in resent)
      and any(rec[1] == eid["tree-01"] and rec[2] == fixed(40.5) for m in resent if m["t"] == "ents" for rec in m["e"]),
      f"a tree made by a script without an event: its chunk is counted and sent again with it: {[m['t'] for m in resent]}")
quiet.destroy()
tick(16)
resent = [m for m in take() if m["t"] in ("chunk", "ents") and (m["cx"], m["cy"]) == (1, 0)]
check(any(m["t"] == "chunk" for m in resent)
      and not any(rec[1] == eid["tree-01"] for m in resent if m["t"] == "ents" for rec in m["e"]),
      f"and destroyed without raise_destroy: its chunk is sent again without it: {[m['t'] for m in resent]}")
# (world.lua's refresh sends one subscribed chunk every 300 ticks whatever its count: a window over one
# of its ticks may hold that chunk, whatever tick the tests before have left the game at.)
count_from = int(lua.eval("game.tick"))
tick(40)
refreshed = any(t % 300 == 0 for t in range(count_from + 1, count_from + 41))
held_chunks = [m for m in take() if m["t"] == "chunk"]
check(len(held_chunks) <= (1 if refreshed else 0), f"a chunk whose count holds isn't sent again: {len(held_chunks)} (a refresh tick in the window: {refreshed})")
built = spawn("tree-01", 41.5, 9.5)
F["raise"]("script_raised_built", lua.table_from({"entity": built}))


def refresh_in(ticks):
    """Runs `ticks` ticks; whether one of them was the 300-tick refresh, which sends a chunk whatever
    its count (these checks failed whenever a test before them moved the game's tick onto one)."""
    start = int(lua.eval("game.tick"))
    tick(ticks)
    return any(t % 300 == 0 for t in range(start + 1, start + ticks + 1))


refreshed = refresh_in(16)
after_event = take()
check(of_type(after_event, "add") and len(of_type(after_event, "chunk")) <= (1 if refreshed else 0),
      f"an entity made with an event is sent as `add`, and the count starts again from there (no resend; a refresh tick: {refreshed})")
F["raise"]("script_raised_destroy", lua.table_from({"entity": built}))
built.destroy()
refreshed = refresh_in(16)
after_event = take()
check(of_type(after_event, "del") and len(of_type(after_event, "chunk")) <= (1 if refreshed else 0),
      f"and removed with one, as `del`, no resend (a refresh tick: {refreshed})")

# --- belts for a client that simulates them (`bs` in its hello, belt_sim.lua) ----------------------
def bs_of(msgs):
    """{lm: {key: [11 numbers]}, sl: {key: (tick, [[uid, item, pos, stack], ...])}, pc: {key: [tick, n,
    front, back]}, dl, of, qu, heads: [(k, fx, fy, fr)]} over the bs messages in msgs."""
    out = {"lm": {}, "sl": {}, "pc": {}, "pu": {}, "ew": {}, "sh": {}, "dl": [], "of": [], "qu": [], "heads": []}
    for m in of_type(msgs, "bs"):
        out["heads"].append((m["k"], m["fx"], m["fy"], m["fr"]))
        lm = m.get("lm", [])
        for i in range(0, len(lm), 12):
            out["lm"][lm[i]] = lm[i + 1:i + 12]
        sl, i = m.get("sl", []), 0
        while i < len(sl):
            n = sl[i + 2]
            out["sl"][sl[i]] = (sl[i + 1], [sl[i + 3 + 4 * j:i + 7 + 4 * j] for j in range(n)])
            i += 3 + 4 * n
        pc = m.get("pc", [])
        for i in range(0, len(pc), 5):
            out["pc"][pc[i]] = pc[i + 1:i + 5]
        ew = m.get("ew", [])
        for i in range(0, len(ew), 4):
            out["ew"][ew[i]] = ew[i + 1:i + 4]
        pu = m.get("pu", [])
        for i in range(0, len(pu), 3):
            out["pu"][pu[i]] = pu[i + 1:i + 3]
        sh = m.get("sh", [])
        for i in range(0, len(sh), 2):
            out["sh"][sh[i]] = sh[i + 1]
        out["dl"] += m.get("dl", [])
        out["of"] += m.get("of", [])
        out["qu"] += m.get("qu", [])
    return out


bs_mod = lua.eval('package.loaded["scripts.belt_sim"]')
bx, by = 300.5, 300.5
sb1 = spawn("transport-belt", bx, by, force="player", direction=4)
sb2 = spawn("transport-belt", bx + 1, by, force="player", direction=4)
sb3 = spawn("transport-belt", bx + 2, by, force="player", direction=4)
F.link_belts(sb1, sb2)
F.link_belts(sb2, sb3)
s_ins = spawn("inserter", bx + 1, by + 1, force="player")
s_ins.pickup_target = sb2  # sb2 is a pickup belt, sb1 the belt behind it: both watched; sb3 not
s_drop = spawn("inserter", bx + 1, by - 1, force="player")
s_drop.drop_target = sb2  # and a drop belt: s_drop holds a plate till it puts it there
F.set_hand(s_drop, bx + 1, by - 1, "iron-plate")
s_in = spawn("underground-belt", bx + 4, by, force="player", direction=4, type="input")
s_out = spawn("underground-belt", bx + 7, by, force="player", direction=4, type="output")
F.pair_undergrounds(s_in, s_out)
s_wired = spawn("transport-belt", bx, by + 3, force="player", direction=4)
s_lane = spawn("lane-splitter", bx + 3, by + 3, force="player", direction=4)
F.belt_behaviors[s_wired] = lua.table_from({"enabled": True})
# A belt leading out of the square: sx (ring 5) feeds sy, 20 tiles out (the square is 16).
sx = spawn("transport-belt", bx + 5, by + 6, force="player", direction=4)
sy = spawn("transport-belt", bx + 20, by + 6, force="player", direction=4)
F.link_belts(sx, sy)
F.put_on_belt(sx, 1, "iron-plate", 0.5, 8105)
# A belt fed from outside the square: fz, 20 tiles out, feeds fw (ring 9).
fz = spawn("transport-belt", bx + 20, by + 9, force="player", direction=12)
fw = spawn("transport-belt", bx + 5, by + 9, force="player", direction=12)
F.link_belts(fz, fw)
F.put_on_belt(fw, 1, "iron-plate", 0.5, 8120)
# A packed run over three plain belts (four items a lane, a gap apart, from a quarter gap in).
runs = [spawn("transport-belt", bx - 5 + k, by - 5, force="player", direction=4) for k in range(3)]
F.link_belts(runs[0], runs[1])
F.link_belts(runs[1], runs[2])
for k, e in enumerate(runs):
    for j in range(4):
        F.put_on_belt(e, 1, "iron-plate", 0.125 + 0.25 * j, 8130 + 4 * k + j)
F.put_on_belt(s_lane, 1, "iron-plate", 0.25, 8150)  # a lane splitter's input holding an item (sh below)
F.put_on_belt(sb1, 1, "iron-plate", 0.5, 8101)
F.put_on_belt(sb2, 1, "iron-plate", 0.25, 8102)
F.put_on_belt(sb2, 1, "iron-plate", 0.75, 8103, None, "rare")
F.put_on_belt(sb3, 2, "copper-plate", 0.5, 8104)
u1, u2, u3, ui, uo, uw = (int(e.unit_number) for e in (sb1, sb2, sb3, s_in, s_out, s_wired))
ul = int(s_lane.unit_number)
ux, uy = int(sx.unit_number), int(sy.unit_number)
bs_mod.pc_every = 1000
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1})
send({"t": "focus", "x": fixed(bx), "y": fixed(by), "r": 48})
send({"t": "bfar", "r": 0, "n": 16, "m": 0})
tick(14)
first_msgs = take()
first = bs_of(first_msgs)
keys = {u * 8 + i for u in (u1, u2, u3, uw) for i in (1, 2)} | {u * 8 + i for u in (ui, uo) for i in (1, 2, 3, 4)}
check(not of_type(first_msgs, "bi") and keys <= set(first["lm"]) and keys <= set(first["sl"]),
      f"bs: the first load sends every lane's meta (lm) and items (sl): missing lm {sorted(keys - set(first['lm']))}, sl {sorted(keys - set(first['sl']))}")
check(first["heads"] and first["heads"][-1][1:] == (fixed(bx), fixed(by), 16),
      f"bs: fx, fy, fr: the square every lane of which is loaded: {first['heads']}")
t2, items2 = first["sl"].get(u2 * 8 + 1, (None, []))
check([it[0] for it in items2] == [8102, 8103] and items2[0][1] == iid["iron-plate"] and items2[0][2] == 64 and items2[0][3] == 1
      and isinstance(t2, int) and t2 > 0 and first["qu"] == [8103, "rare"],
      f"bs sl: a lane's items front first, [uid, item, position (1/256), stack], with the tick it was read; qu: {t2} {items2} {first['qu']}")
meta = first["lm"].get(u2 * 8 + 1, [])
check(meta[:3] == [1, 256, 8] and meta[-1] == 0, f"bs lm: kind 1 (straight), length 256, step (1/256 a tick), next 0: {meta}")
# Depth first: sb3 (ring 2) is loaded before sb2 (ring 1) that feeds it, so sb2 never leads out.
check(first["sl"].get(u3 * 8 + 1, (1 << 60,))[0] <= first["sl"].get(u2 * 8 + 1, (0,))[0],
      f"bs: a belt is loaded after the belts it feeds: sb3 at {first['sl'].get(u3 * 8 + 1, (None,))[0]}, sb2 at {first['sl'].get(u2 * 8 + 1, (None,))[0]}")
# A belt feeding one outside the square leads out: its lanes' next is -1.
check(first["lm"].get(ux * 8 + 1, [0] * 11)[-1] == -1 and first["lm"].get(ux * 8 + 2, [0] * 11)[-1] == -1
      and uy * 8 + 1 not in first["lm"],
      f"bs lm: a lane leading out of the square has next -1: {first['lm'].get(ux * 8 + 1)}")
# (The older checks below look at single lanes: the reads round them come back at the end.)
bs_mod.tails = False
bs_mod.settle_around = False
lm_of = lambda k: first["lm"].get(k, [0] * 11)
check(lm_of(ui * 8 + 1)[0] == 3 and lm_of(ui * 8 + 1)[-1] == ui * 8 + 3 and lm_of(ui * 8 + 3)[0] == 4 and lm_of(ui * 8 + 3)[-1] == uo * 8 + 1
      and lm_of(uo * 8 + 3)[0] == 8 and lm_of(uo * 8 + 1)[-1] == 0,
      f"bs lm: an entrance's lines 1-2 go on into its hidden 3-4, those into the exit's 1-2: {[lm_of(k) for k in (ui * 8 + 1, ui * 8 + 3, uo * 8 + 1, uo * 8 + 3)]}")
check([lm_of(ul * 8 + i)[0] for i in (1, 2, 3, 4)] == [5, 5, 6, 6],
      f"bs lm: a lane splitter's lines 1-2 are splitter inputs (5), 3-4 outputs (6): {[lm_of(ul * 8 + i) for i in (1, 2, 3, 4)]}")
# A watched lane that changed is sent again with its read tick; an unwatched one isn't.
F.move_on_belt(sb2, 1, 8102, None)
F.move_on_belt(sb3, 2, 8104, 0.25)
tick(12)
changed = bs_of(take())
check(u2 * 8 + 1 in changed["sl"] and [it[0] for it in changed["sl"][u2 * 8 + 1][1]] == [8103]
      and changed["sl"][u2 * 8 + 1][0] > t2 and u3 * 8 + 2 not in changed["sl"] and u2 * 8 + 1 not in changed["lm"],
      f"bs: a watched lane that changed is sent (sl, its tick, no lm), an unwatched one isn't: {sorted(changed['sl'])}")
# A watched lane whose items all moved on alike, nothing coming or going, isn't sent: the client
# simulates that.
F.move_on_belt(sb1, 1, 8101, 0.375)
tick(6)
flowed = bs_of(take())
check(u1 * 8 + 1 not in flowed["sl"], f"bs: a watched lane that only flowed on isn't sent: {sorted(flowed['sl'])}")
# Drift checks: every unwatched lane's count, front and back about every pc_every updates.
bs_mod.pc_every = 1
tick(12)
drift = bs_of(take())
bs_mod.pc_every = 1000
check(drift["pc"].get(u3 * 8 + 2, [0])[1:] == [1, 64, 64] and drift["pc"].get(u3 * 8 + 1, [0])[1:] == [0, -1, -1],
      f"bs pc: [tick, count, front, back] for lanes not watched (-1, -1 when empty): {drift['pc'].get(u3 * 8 + 2)} {drift['pc'].get(u3 * 8 + 1)}")
check(drift["pu"].get(u3 * 8 + 2) == [8104, 8104] and u3 * 8 + 1 not in drift["pu"],
      f"bs pu: a packed lane's drift check carries its front and back items' ids, an empty one none: {drift['pu']}")
# pc_ids: those ids even when the accuracy extras' share (extra_units) has no room (off: only with room).
bs_mod.pc_every = 1
saved_extra = bs_mod.extra_units
bs_mod.extra_units = 0
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "pc_ids on"}))
tick(12)
drift_on = bs_of(take())
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "pc_ids default"}))
tick(12)
drift_off = bs_of(take())
bs_mod.extra_units = saved_extra
bs_mod.pc_every = 1000
check(drift_on["pu"].get(u3 * 8 + 2) == [8104, 8104] and u3 * 8 + 2 in drift_off["pc"],
      f"bs pc_ids: a packed lane's drift check carries its ids with no extra share left: {drift_on['pu']} {drift_off['pc'].get(u3 * 8 + 2)}")
# drift_watched: a watched belt's lanes get drift checks too (off: none, as before). (quiet_pc off: its checks every
# turn, as these look for one in a window; quiet_pc's own checks follow.)
bs_mod.pc_every = 1
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "quiet_pc off"}))
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "drift_watched on"}))
tick(12)
take()  # (an update's work list is made on the tick after the one before is sent)
tick(12)
dw_on = bs_of(take())
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "drift_watched off"}))
tick(12)
take()
tick(12)
dw_off = bs_of(take())
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "drift_watched default"}))
bs_mod.pc_every = 1000
check(uw * 8 + 1 in dw_on["pc"] and uw * 8 + 1 not in dw_off["pc"] and u3 * 8 + 2 in dw_off["pc"],
      f"bs drift_watched: a watched lane's drift check is sent with it on, not off; an unwatched one's either way: "
      f"{dw_on['pc'].get(uw * 8 + 1)} {dw_off['pc'].get(uw * 8 + 1)}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "quiet_pc default"}))


# quiet_pc (on by default): an unwatched belt whose drift checks keep agreeing has each next one twice as far off, up
# to quiet_pc_max ticks; any touch (a full read of its lanes, a `bre`, a watched belt behind it changing) puts it back
# to every turn. (sb3: unwatched, fed by sb2, a pickup and drop belt; tails are off here, so only the wake reaches it.)
def pc_ticks(ticks, key):
    """The ticks of `key`'s drift checks over `ticks` ticks."""
    got = []
    for j in range(ticks // 6):
        if j % 10 == 0:
            # (The same hello again: the session drops a client it hasn't heard a hello from in 600 ticks.)
            send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1})
        tick(6)
        for m in of_type(take(), "bs"):
            pc = m.get("pc", [])
            got += [pc[i + 1] for i in range(0, len(pc), 5) if pc[i] == key]
    return got


def gaps(ts):
    return [b - a for a, b in zip(ts, ts[1:])]


q_key = u3 * 8 + 2
bs_mod.pc_every = 1
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "quiet_pc_max 200"}))
take()
q_on = gaps(pc_ticks(600, q_key))
q_rec = lambda f: lua.eval(f"storage.f3d.bs.belts[{u3}].{f}")
check(len(q_on) >= 4 and all(b >= a for a, b in zip(q_on, q_on[1:])) and q_on[-1] > 2 * q_on[0]
      and max(q_on) <= 200 + 6 and q_rec("qw") == 200,
      f"bs quiet_pc: an untouched lane's drift checks come further apart each time, up to quiet_pc_max (200): gaps {q_on}, qw {q_rec('qw')}")
# A `bre` for it: read in full, back to every turn.
send({"t": "bre", "l": [q_key]})
tick(12)
take()
check(q_rec("qw") is None, f"bs quiet_pc: a lane read again for the client (bre) is woken: qw {q_rec('qw')}")
q_after = gaps(pc_ticks(60, q_key))
check(q_after and q_after[0] <= q_on[0] + 6, f"bs quiet_pc: and checked every turn again: gaps {q_after} (first quiet {q_on})")
# A watched belt behind it that changed wakes it (its tails' reach), read or not.
pc_ticks(300, q_key)
qw_before, woken0 = q_rec("qw"), int(bs_mod.counts["woken"] or 0)
F.put_on_belt(sb2, 1, "iron-plate", 0.9, 8199)
tick(66)  # (sb2, quiet, is checked again within spot_quiet_ticks)
take()
qw_now = q_rec("qw")
check(qw_before and qw_before > 48 and int(bs_mod.counts["woken"]) > woken0 and (qw_now is None or qw_now <= 48),
      f"bs quiet_pc: a watched belt behind it (sb2) that changed wakes it (its checks starting over): qw {qw_before} -> {qw_now}")
F.move_on_belt(sb2, 1, 8199, None)
tick(12)
take()
# The cap: never more than quiet_pc_max apart (0: every turn).
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "quiet_pc_max 0"}))
q_zero = gaps(pc_ticks(300, q_key))[-4:]
check(q_zero and max(q_zero) <= 12, f"bs quiet_pc_max 0: every turn: gaps {q_zero}")
# Off: every turn, as before.
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "quiet_pc_max default"}))
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "quiet_pc off"}))
q_off = gaps(pc_ticks(300, q_key))
check(q_off and max(q_off) <= 12, f"bs quiet_pc off: every turn, as before: gaps {q_off}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "quiet_pc default"}))
said_q = str(bs_mod.option_command("")[1])
check("quiet_pc on" in said_q and "quiet_pc_max 3600" in said_q, "/f3d-bs lists quiet_pc (on) and quiet_pc_max (3600: a minute)")
# A splitter set again wakes the belts after it (tracker.configured, from a paste, its window or Zenith's screen).
lua.eval('package.loaded["scripts.tracker"].configured')(s_lane)
# Step 1: full reads counted by cause, watched or not (/f3d-bs reads).
said_reads = str(bs_mod.option_command("reads")[1])
check("bs reads" in said_reads and "asked=" in said_reads and "load=" in said_reads and "pc_quiet=" in said_reads
      and int(bs_mod.counts["ru_asked"] or 0) >= 1,
      f"/f3d-bs reads: full reads by cause (watched/unwatched) and the drift checks skipped: {said_reads}")
bs_mod.pc_every = 1000
take()
# bre: lanes the client has otherwise are read in full (with their meta) in the next update made.
# (Each update's work list is made on the tick after the one before is sent: a change shows the
# update after.)
send({"t": "bre", "l": [u3 * 8 + 2]})
tick(12)
again = bs_of(take())
check([it[0] for it in again["sl"].get(u3 * 8 + 2, (0, []))[1]] == [8104] and u3 * 8 + 2 in again["lm"],
      f"bs bre: a lane asked for again is sent in full with its meta: {again['sl'].get(u3 * 8 + 2)}")
check(again["lm"].get(u3 * 8 + 2) == first["lm"].get(u3 * 8 + 2),
      f"bs bre: the meta sent again (from the lane's kept meta, perfbridge2) is the first load's: {again['lm'].get(u3 * 8 + 2)} vs {first['lm'].get(u3 * 8 + 2)}")
said_counts = bs_mod.option_command("counts")
check("bs counts" in str(said_counts[1]) and "read=" in str(said_counts[1]), f"/f3d-bs counts says what was read and checked: {said_counts[1]}")
check("extra_spread on" in str(bs_mod.option_command("")[1]), "/f3d-bs lists extra_spread (on)")
# A belt switched off by the circuit network (of), and on again.
s_wired.status = g.defines.entity_status.disabled_by_control_behavior
tick(12)
off = bs_of(take())["of"]
s_wired.status = g.defines.entity_status.working
tick(12)
on = bs_of(take())["of"]
check(off == [uw, 1] and on == [uw, 0], f"bs of: a wired belt switched off, then on: {off} {on}")
# A lane leading out is checked on every update's tick and sent when it changed at all, flowing on
# too (the client's front there moves only where the bridge's reads say).
F.move_on_belt(sx, 1, 8105, 0.25)
tick(6)
edge = bs_of(take())
heads = edge["heads"]
check(edge["ew"].get(ux * 8 + 1) == [heads[-1][0] if heads else None, 8105, 64] and ux * 8 + 1 not in edge["sl"],
      f"bs ew: a lane leading out that only flowed sends its wall, read on the update's tick: {edge['ew']} {heads}")
# Something came onto it: read in full (sl).
F.put_on_belt(sx, 1, "copper-plate", 0.75, 8107)
tick(6)
edge2 = bs_of(take())
check([it[0] for it in edge2["sl"].get(ux * 8 + 1, (None, []))[1]] == [8105, 8107],
      f"bs: a lane leading out that something came onto is sent in full: {edge2['sl'].get(ux * 8 + 1)} {edge2['ew']}")
# A lane fed from outside what is sent: checked on every update's tick with no quiet spells, and sent
# whenever it changed, its items only moving on too (what comes in at its back is news to the client).
uz, uf = int(fz.unit_number), int(fw.unit_number)
check(lua.eval(f"storage.f3d.bs.iset[{uf}]") and not lua.eval(f"storage.f3d.bs.iset[{uz}]"),
      "bs: a belt fed by one outside the square is fed from outside")
tick(6 * (bs_mod.quiet_after + 3))
take()
F.move_on_belt(fw, 1, 8120, 0.375)
tick(6)
fed = bs_of(take())
fed_heads = fed["heads"]
check([it[0] for it in fed["sl"].get(uf * 8 + 1, (None, []))[1]] == [8120]
      and fed["sl"][uf * 8 + 1][0] == (fed_heads[-1][0] if fed_heads else None),
      f"bs: a lane fed from outside that only flowed on is sent, read on the update's tick: {fed['sl'].get(uf * 8 + 1)} {fed_heads}")
F.put_on_belt(fw, 1, "copper-plate", 0.875, 8121)
tick(6)
fed2 = bs_of(take())
check([it[0] for it in fed2["sl"].get(uf * 8 + 1, (None, []))[1]] == [8120, 8121],
      f"bs: what came in at the back of a lane fed from outside is sent: {fed2['sl'].get(uf * 8 + 1)}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "feed_edges off"}))
tick(6 * (bs_mod.quiet_after + 3))
take()
F.move_on_belt(fw, 1, 8120, 0.25)
F.move_on_belt(fw, 1, 8121, 0.75)
tick(6)
fed_off = bs_of(take())
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "feed_edges on"}))
check(uf * 8 + 1 not in fed_off["sl"], f"bs: feed_edges off: a quiet lane fed from outside that only flowed isn't sent (as before): {fed_off['sl'].get(uf * 8 + 1)}")
# bre: a lane in a packed run is read with the run's belts, ahead and behind, on the same tick; two
# lanes asked on belts next to each other are read on one tick.
ur = [int(e.unit_number) for e in runs]
send({"t": "bre", "l": [ur[1] * 8 + 1]})
tick(12)
run = bs_of(take())
t_run = run["sl"].get(ur[1] * 8 + 1, (None,))[0]
check(t_run and all(run["sl"].get(u * 8 + 1, (None,))[0] == t_run for u in ur)
      and [it[0] for it in run["sl"][ur[2] * 8 + 1][1]] == [8138, 8139, 8140, 8141],
      f"bs bre: a lane is read with the packed run it belongs to on the same tick: {[run['sl'].get(u * 8 + 1) for u in ur]}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "line_rereads off"}))
send({"t": "bre", "l": [ur[1] * 8 + 1]})
tick(12)
alone = bs_of(take())
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "line_rereads on"}))
check(ur[1] * 8 + 1 in alone["sl"] and ur[0] * 8 + 1 not in alone["sl"] and ur[2] * 8 + 1 not in alone["sl"],
      f"bs: line_rereads off: a bre lane is read alone (as before): {sorted(alone['sl'])}")
bs_mod.run_belts = 0
send({"t": "bre", "l": [ur[0] * 8 + 1, ur[2] * 8 + 1, ur[1] * 8 + 2]})
tick(12)
grouped = bs_of(take())
bs_mod.run_belts = 6
t_g = [grouped["sl"].get(k, (None,))[0] for k in (ur[0] * 8 + 1, ur[2] * 8 + 1, ur[1] * 8 + 2)]
check(t_g[0] and t_g[0] == t_g[1] == t_g[2],
      f"bs bre: lanes asked on belts next to each other are read on one tick: {t_g}")
# bre_cap: at most that many asked lanes an update, the rest in the next.
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "bre_cap 2"}))
bs_mod.run_belts = 0
send({"t": "bre", "l": [ur[0] * 8 + 1, ur[1] * 8 + 1, ur[2] * 8 + 1]})
tick(18)
capped_bre = bs_of(take())
bs_mod.run_belts = 6
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "bre_cap default"}))
t_c = sorted(capped_bre["sl"].get(u * 8 + 1, (None,))[0] or 0 for u in ur)
check(t_c[0] > 0 and t_c[0] == t_c[1] < t_c[2],
      f"bs bre_cap: asked lanes over the cap wait for the next update: {t_c}")
# The client's Belt updates (bfar m, the old cap) don't bound the square: every belt within n is sent.
lua.execute("storage.f3d.bi_cap = 5 storage.f3d.bs.rescan = true")
tick(24)
capped = bs_of(take())
check(capped["heads"] and capped["heads"][-1][3] == 16 and not (keys & set(capped["dl"])),
      f"bs: bfar m doesn't bound the square: {capped['heads'][-1:]} dropped {sorted(keys & set(capped['dl']))}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "full_area off"}))
tick(24)
capped_old = bs_of(take())
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "full_area on"}))
lua.execute("storage.f3d.bi_cap = nil")
tick(24)
take()
check(capped_old["heads"] and capped_old["heads"][-1][3] < 16,
      f"bs: full_area off: the client's cap bounds the square again (as before): {capped_old['heads'][-1:]}")
# The bridge's own bound: over it, the square is cut from the outside (fr says so; the lanes past it
# go, those inside stay); well under it again, it grows back.
bs_mod.bound, bs_mod.bound_min = 1, 4
tick(6 * 12)
cut = bs_of(take())
cut_fr = cut["heads"][-1][3] if cut["heads"] else None
inner = {u * 8 + i for u in (u1, u2, u3) for i in (1, 2)}
check(cut_fr is not None and cut_fr < 16 and uf * 8 + 1 in cut["dl"] and not (inner & set(cut["dl"])),
      f"bs: over the bound the square is cut from the outside: fr {cut_fr}, dropped {sorted(cut['dl'])[:8]}")
bs_mod.bound, bs_mod.bound_min = None, 16
grown_msgs = []
for _ in range(12):  # (with the hello as keep-alive)
    send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1})
    tick(60)
    grown_msgs += take()
grown = bs_of(grown_msgs)
check(grown["heads"] and grown["heads"][-1][3] == 16 and uf * 8 + 1 in grown["lm"],
      f"bs: under the bound the square grows back: {grown['heads'][-1:]}")
# Tails: an inserter put on its drop belt (its hand holds less): the belt is checked at once though
# quiet, and the belts it feeds are read in the same update (after the input spots' checks).
# (actor_backoff off: the inserter has stood for a while, so it would be checked an update later.)
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "actor_backoff off"}))
bs_mod.tails = True
F.put_on_belt(sb2, 2, "iron-plate", 0.5, 8106)
F.set_hand(s_drop, bx + 1, by - 0.5, None)
tick(12)
tails = bs_of(take())
t_sb2 = tails["sl"].get(u2 * 8 + 2, (None,))[0]
check(t_sb2 and tails["sl"].get(u3 * 8 + 1, (None,))[0] == t_sb2 and tails["sl"].get(u3 * 8 + 2, (None,))[0] == t_sb2,
      f"bs tails: the belt a changed input spot feeds is read on the same tick: {t_sb2} {tails['sl'].get(u3 * 8 + 1)}")
# Settled: a watched lane unchanged for quiet_after checks after it changed is sent once more, and
# the belts round it (sb3 it feeds) with it.
bs_mod.settle_around = True
tick(6 * (bs_mod.quiet_after + 2))
settle = bs_of(take())
t_set = settle["sl"].get(u2 * 8 + 2, (None,))[0]
check(t_set and t_set > t_sb2 and [it[0] for it in settle["sl"][u2 * 8 + 2][1]] == [8106]
      and (settle["sl"].get(u3 * 8 + 1, (None,))[0] or 0) >= t_set,
      f"bs: a watched lane that settled is sent once more, with the belts round it: {settle['sl'].get(u2 * 8 + 2)} {settle['sl'].get(u3 * 8 + 1)}")
tick(6 * (bs_mod.quiet_after + 2))
check(u2 * 8 + 2 not in bs_of(take())["sl"], "bs: a settled lane isn't sent again while it stands")
# actor_backoff: an inserter whose hand stood for a while is checked every other update; when it
# puts on its quiet belt that is still read within two updates.
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "actor_backoff on"}))
F.set_hand(s_drop, bx + 1, by - 1, "iron-plate")
tick(6 * 10)
take()
skipped0 = bs_mod.counts.actors_skipped or 0
tick(6 * 4)
take()
skipped1 = bs_mod.counts.actors_skipped or 0
check(skipped1 - skipped0 >= 2, f"bs actor_backoff: a standing hand is checked less often: {skipped0} -> {skipped1}")
F.put_on_belt(sb2, 2, "iron-plate", 0.75, 8109)
F.set_hand(s_drop, bx + 1, by - 0.5, None)
tick(12)
late = bs_of(take())
check(8109 in [it[0] for it in late["sl"].get(u2 * 8 + 2, (None, []))[1]],
      f"bs actor_backoff: what a standing inserter put on its quiet belt is sent within two updates: {late['sl'].get(u2 * 8 + 2)}")
# (--inserter-handoff) A hello with `ie` and `ho`: a hand that put on a belt is followed by a placed record
# (6: lane key, line position, the item's unique_id, item, stack, belt), the newest item next to the hand;
# without `ho` none.
def placed_records(msgs, who):
    out = []
    for m in of_type(msgs, "ie"):
        l = list(m["l"])
        if m.get("z") == 1:
            for i in range(9, len(l)):
                l[i] += l[i - 9]  # (delta-coded: each number against the record before)
        for i in range(0, len(l), 9):
            if l[i] == 6 and l[i + 1] == who:
                out.append(l[i:i + 9])
    return out


u_sd = int(s_drop.unit_number)
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1, "ie": 2, "ho": 1})
F.set_hand(s_drop, bx + 1, by - 1, "iron-plate")
tick(30)
take()
F.put_on_belt(sb2, 2, "iron-plate", 0.9, 8112)
F.set_hand(s_drop, bx + 0.6, by + 0.234, None)
tick(12)
pl = placed_records(take(), u_sd)
check(pl and pl[0][3] == u2 * 8 + 2 and pl[0][4] == 230 and pl[0][5] == 8112 and pl[0][6] == iid["iron-plate"] and pl[0][7] == 1
      and pl[0][8] == u2,
      f"ie placed (ho): the item a hand put on its belt, by lane, line position and unique_id: {pl[:1]}")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1, "ie": 2})
F.set_hand(s_drop, bx + 1, by - 1, "iron-plate")
tick(30)
take()
F.put_on_belt(sb2, 1, "iron-plate", 0.9, 8113)
F.set_hand(s_drop, bx + 0.6, by - 0.234, None)
tick(12)
check(not placed_records(take(), u_sd), "ie placed: none for a hello without `ho`")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1})
tick(12)
take()
# hold_inputs: a splitter's input found as its last read left it is sent in `sh` with its check's tick
# (an empty one isn't); once it changed it is read (sl) instead; with the switch off, never.
take()
tick(60)
held = bs_of(take())
check(ul * 8 + 1 in held["sh"] and held["sh"][ul * 8 + 1] > first["sl"][ul * 8 + 1][0] and ul * 8 + 2 not in held["sh"]
      and ul * 8 + 3 not in held["sh"] and ul * 8 + 1 not in held["sl"],
      f"bs sh: a lane splitter's input holding what its last read had is sent in sh, its empty input and its outputs not: {held['sh']}")
F.move_on_belt(s_lane, 1, 8150, None)
tick(60)
held2 = bs_of(take())
tick(60)
held2b = bs_of(take())
check(ul * 8 + 1 in held2["sl"] and ul * 8 + 1 not in held2b["sh"],
      f"bs sh: once it changed it is read again instead (and empty, not held): {held2['sh']} {held2b['sh']} {sorted(held2['sl'])}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "hold_inputs off"}))
tick(60)
held3 = bs_of(take())
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "hold_inputs default"}))
check(not held3["sh"], f"bs sh: none with /f3d-bs hold_inputs off: {held3['sh']}")
# Something built near belts: their lanes are sent again with lm and sl.
near = spawn("inserter", bx + 2, by - 1, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": near}))
tick(12)
rebuilt = bs_of(take())
check(u3 * 8 + 1 in rebuilt["lm"] and u3 * 8 + 1 in rebuilt["sl"], f"bs: belts near something built are sent again (lm, sl): {sorted(rebuilt['lm'])}")
# The focus moves away: the lanes leave the square (dl).
send({"t": "focus", "x": fixed(bx + 200), "y": fixed(by), "r": 48})
tick(12)
gone = bs_of(take())
check(keys <= set(gone["dl"]), f"bs dl: lanes out of the square are dropped: missing {sorted(keys - set(gone['dl']))}")
# ld: 1 while the square is still loading (one belt a tick here), then left out; w the steady work.
send({"t": "focus", "x": fixed(bx), "y": fixed(by), "r": 48})
bs_mod.reset()
bs_mod.load_cap = 1
wholes = []
for _ in range(60):
    tick(1)
    if g.storage.f3d.bs is not None:
        wholes.append(bool(g.storage.f3d.bs.whole))
bs_mod.load_cap = None
ld_msgs = take()
lds = [m.get("ld") for m in of_type(ld_msgs, "bs") if m.get("part", 1) == 1]
check(lds and lds[0] == 1 and lds[-1] is None, f"bs ld: 1 while the square is still loading, then left out: {lds}")
# (far_load_cap waits for that: the square marked loaded whole once the update without ld is made, not before.)
check(wholes and not wholes[0] and wholes[-1] and wholes.index(True) > 6,
      f"far_load_cap: the square counts as loaded whole only once an update finds it so: {wholes.count(False)} ticks before")
# crossings game: a splitter's output lanes are checked on every update even while they stand (never
# quiet), so what crossed is sent within an update; with sim (the default) a standing output goes quiet.
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "bs": 1})  # (keep the session alive through the ticks below)
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "crossings game"}))
said_x = lua.eval('package.loaded["scripts.belt_sim"]').option_command("crossings nonsense")
check("game, sim or default" in str(said_x[1]) and "crossings game (set)" in str(said_x[2]),
      f"/f3d-bs crossings takes sim or game and says so: {said_x[1]} / {said_x[2]}")
take()
tick(12)
x0 = bs_mod.counts.crossings or 0
tick(6 * 8)
take()
x1 = bs_mod.counts.crossings or 0
check(x1 - x0 >= 10, f"bs crossings game: the lane splitter's standing outputs are checked every update: {x0} -> {x1}")
F.put_on_belt(s_lane, 3, "iron-plate", 0.3, 8151)  # (as if an input's item crossed into output line 3)
tick(12)
crossed = bs_of(take())
check(8151 in [it[0] for it in crossed["sl"].get(ul * 8 + 3, (None, []))[1]],
      f"bs crossings game: an item that crossed into an output is sent within an update: {crossed['sl'].get(ul * 8 + 3)}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "crossings default"}))
tick(6)
take()
x2 = bs_mod.counts.crossings or 0
tick(6 * 4)
x3 = bs_mod.counts.crossings or 0
check(x3 == x2, f"bs crossings sim: outputs aren't checked as crossings: {x2} -> {x3}")


# own_rate: the updates follow their own rate job (`bs`, tier 3, at most 12 ticks), so Hold 60 UPS's
# first levels don't make them stale (every update is a read of every input spot); off, `bi`'s as before.
# period_max (the belt-rate round): the longest period they are stretched to, 6 (never) by default, 0 the job's 12.
def bs_spacing(level, ticks):
    send({"t": "rate", "l": level})
    for _ in range(13):  # past the ease (a slow-down keeps the old ticks 120 more); the client kept alive
        tick(10)
        send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1})
    take()
    for _ in range(ticks // 10):
        tick(10)
        send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1})
    heads = [m for m in of_type(take(), "bs") if m.get("part", 1) == 1]
    ks = sorted({m["k"] for m in heads})
    return {b - a for a, b in zip(ks, ks[1:])}, {m.get("p") for m in heads}


bs_mod.pc_every = 1  # (a drift check every update, so a quiet world still sends one)
own = {level: bs_spacing(level, 150) for level in (1, 2, 3)}
check(own[1] == ({6}, {6}) and own[2] == ({6}, {6}) and own[3] == ({6}, {6}),
      f"bs own_rate, period_max 6: updates every 6 ticks at rate 1, 2 and 3, p saying so: {own}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "period_max 0"}))
own = {level: bs_spacing(level, 150) for level in (2, 3)}
check(own[2] == ({6}, {6}) and own[3] == ({12}, {12}),
      f"bs period_max 0: the job's own max, every 6 ticks at rate 2 and every 12 at 3: {own}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "period_max default"}))
tick(4)  # (the two spacings above are 560 ticks: the checks below keep their tick phase, 6 apart)
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "own_rate off"}))
old_rate = {level: bs_spacing(level, 150) for level in (1, 3)}
check(old_rate[1] == ({12}, {12}) and old_rate[3] == ({48}, {48}),
      f"bs own_rate off: the glided belt items' rate, 12 at 1 and 48 at 3, as before: {old_rate}")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "own_rate default"}))
bs_mod.pc_every = 1000
send({"t": "rate", "l": 0})


# walk_load: while the square loaded whole reaches less than walk_near tiles of the focus (walking, a
# jump), first loads get at least walk_load units a tick; standing with it all loaded, their share as before.
walk_field = [spawn("transport-belt", 2000.5 + (k % 28) - 14, 2000.5 + k // 28 - 14, force="player", direction=4)
              for k in range(784)]
for k, e in enumerate(walk_field):
    F.put_on_belt(e, 1, "iron-plate", 0.25, 90000 + 2 * k)
    F.put_on_belt(e, 2, "iron-plate", 0.75, 90001 + 2 * k)


def walk_loaded(units, ticks):
    """Belts loaded after each tick from a reset, with walk_load at `units`."""
    F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "walk_load %d" % units}))
    send({"t": "focus", "x": fixed(2000.5), "y": fixed(2000.5), "r": 48})
    bs_mod.reset()
    c0 = bs_mod.counts.loaded
    out = []
    for t in range(ticks):
        tick(1)
        if t % 3 == 2:
            send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1})
        out.append(bs_mod.counts.loaded - c0)
    take()
    return out


slow = walk_loaded(0, 30)
fast = walk_loaded(20000, 30)
# The slow run's share of the work budget, and the tick loading starts on, vary from run to run (the slow
# run loaded all 784 by its second tick in some runs), so the fast run's guarantee is what's checked: with
# walk_load the square is whole by the fourth tick.
check(fast[3] >= 784,
      f"bs walk_load: first loads get walk_load units a tick while the view isn't loaded: {slow} / {fast}")
check(not lua.eval("storage.f3d.bs.thin"), "bs walk_load: the square all loaded isn't thin")
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "walk_load default"}))


# send_cap: an update's parts are sent over the ticks after its due tick, about send_cap bytes a tick (one
# part at least), each still stamped with the update's tick; 0 sends them all on the due tick, as before.
def spooled_parts(cap, ticks):
    """[(tick, [(k, part, parts, bytes)...])] for every tick with bs parts, from a reset with send_cap at `cap`."""
    F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "send_cap %s" % cap}))
    F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "walk_load 100000"}))
    send({"t": "focus", "x": fixed(2000.5), "y": fixed(2000.5), "r": 48})
    bs_mod.reset()
    take()
    out = []
    for t in range(ticks):
        tick(1)
        rows = [(m["k"], m.get("part", 1), m.get("parts", 1), len(json.dumps(m, separators=(",", ":")))) for m in of_type(take(), "bs")]
        if rows:
            out.append((t, rows))
    F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "walk_load default"}))
    return out


burst = spooled_parts(0, 40)
spread = spooled_parts(20000, 40)
F.commands["f3d-bs"](lua.table_from({"name": "f3d-bs", "parameter": "send_cap default"}))
big = [rows for _, rows in burst if len(rows) >= 3]
check(big and all(len({k for k, _, _, _ in rows}) == 1 and len(rows) == rows[0][2] for rows in big),
      f"bs send_cap 0: every update's parts go out on its due tick: {[(t, len(r)) for t, r in burst]}")
per_tick = [sum(b for _, _, _, b in rows) for _, rows in spread]
check(spread and max(per_tick) < 20000 + MAX_DATAGRAM / 2,
      f"bs send_cap 20000: a tick sends at most the cap and one part more: {per_tick}")
ks = {}
for t, rows in spread:
    for k, part, parts, _ in rows:
        ks.setdefault(k, {"parts": parts, "got": set(), "ticks": set()})
        ks[k]["got"].add(part)
        ks[k]["ticks"].add(t)
whole = [k for k, v in ks.items() if len(v["got"]) == v["parts"]]
check(len(whole) >= len(ks) - 1 and any(len(v["ticks"]) >= 2 for v in ks.values()),
      f"bs send_cap: every part of an update arrives, over more than one tick, stamped with its update's tick: {[(k, v['parts'], sorted(v['ticks'])) for k, v in ks.items()]}")
order = [k for _, rows in spread for k, _, _, _ in rows]
check(order == sorted(order), "bs send_cap: parts go out oldest update first")
for e in walk_field:
    e.destroy()
send({"t": "focus", "x": fixed(bx), "y": fixed(by), "r": 48})
bs_mod.reset()
tick(12)
take()
# Two simulating clients on one server (multiplayer: storage.f3d is swapped per client): each gets
# the lanes round its own focus. (Both clients' rounds start on the same ticks, and one update being
# built, module-local, was keyed by that tick alone: the first client sent both clients' lanes and the
# second nothing.)
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1})
tick(12)
take()
was_mp = F.multiplayer
F.multiplayer = True  # (in single-player a hello from another port takes the one client's place)


def sync_r(by):
    """take()'s reliable counter after a take_by_port (which doesn't keep it)."""
    global expected_r
    rs = [m["r"] for m in by.get(CLIENT_PORT, []) if "r" in m]
    if rs:
        expected_r = rs[-1] + 1


ox, oy = 600.5, 600.5
other = [spawn("transport-belt", ox + k, oy, force="player", direction=4) for k in range(3)]
F.link_belts(other[0], other[1])
F.link_belts(other[1], other[2])
F.put_on_belt(other[1], 1, "iron-plate", 0.5, 8201)
other_ins = spawn("inserter", ox + 1, oy + 1, force="player")
other_ins.pickup_target = other[1]  # (watched: a change there is read)
other_keys = {int(e.unit_number) * 8 + i for e in other for i in (1, 2)}
send({"t": "hello", "v": 1, "sid": "b", "w": 0, "z": 1, "bl": 1, "bs": 1}, port=PORT_B)
tick(2)
send({"t": "focus", "x": fixed(ox), "y": fixed(oy), "r": 48}, port=PORT_B)
send({"t": "bfar", "r": 0, "n": 16, "m": 0}, port=PORT_B)
tick(30)
by_port = take_by_port()
sync_r(by_port)
bs_a, bs_b = bs_of(by_port.get(CLIENT_PORT, [])), bs_of(by_port.get(PORT_B, []))
check(other_keys <= set(bs_b["lm"]) and other_keys <= set(bs_b["sl"]) and not (other_keys & set(bs_a["lm"]))
      and not (set(bs_a["lm"]) & set(bs_b["lm"])),
      f"bs: two simulating clients each get the lanes round their own focus: second missing {sorted(other_keys - set(bs_b['lm']))}, first got {sorted(other_keys & set(bs_a['lm']))}")
# And an update after the first loads: a change at the second client's belts reaches it (its
# inserter took, so the input spot is woken; quiet, it is checked only every spot_quiet_ticks).
F.move_on_belt(other[1], 1, 8201, 0.25)
F.put_on_belt(other[1], 2, "copper-plate", 0.5, 8202)
F.set_hand(other_ins, ox + 1, oy + 0.5, "iron-plate")
tick(12)
by_port = take_by_port()
sync_r(by_port)
bs_b2 = bs_of(by_port.get(PORT_B, []))
ko = int(other[1].unit_number) * 8 + 2
check(8202 in [it[0] for it in bs_b2["sl"].get(ko, (None, []))[1]] and bs_b2["heads"],
      f"bs: the second client's updates carry its own changes: {bs_b2['sl'].get(ko)} {bs_b2['heads'][-1:]}")
send({"t": "bye"}, port=PORT_B)
tick(1)
take()
# The same for two clients that don't simulate (`bi`, main's 0.1.4 client with kept lanes): bi's one
# update being built was module-local by tick too, so two such clients' rounds on one tick sent both
# clients both clients' items.
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 0, "bl": 1})
send({"t": "hello", "v": 1, "sid": "b", "w": 0, "z": 0, "bl": 1}, port=PORT_B)
tick(2)
send({"t": "focus", "x": fixed(ox), "y": fixed(oy), "r": 48}, port=PORT_B)
send({"t": "bfar", "r": 0, "n": 16, "m": 0}, port=PORT_B)
tick(30)
by_port = take_by_port()
sync_r(by_port)


def bi_lanes(msgs):
    """The lane keys named by `ln` over the bi messages, and the unique ids of their items."""
    keys, ids = set(), set()
    for m in of_type(msgs, "bi"):
        ln = m.get("ln", [])
        keys |= {ln[i] for i in range(0, len(ln), 2)}
        items = m.get("l", [])
        ids |= {items[i] for i in range(0, len(items), 4)}
    return keys, ids


bi_a, bi_b = bi_lanes(by_port.get(CLIENT_PORT, [])), bi_lanes(by_port.get(PORT_B, []))
check(8201 in bi_b[1] and 8201 not in bi_a[1] and not (other_keys & bi_a[0]) and 8106 in bi_a[1] and 8106 not in bi_b[1],
      f"bi: two kept-lane clients each get the items round their own focus: first {sorted(bi_a[1])[:6]}, second {sorted(bi_b[1])[:6]}")
send({"t": "bye"}, port=PORT_B)
tick(1)
take()
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1})
tick(12)
take()
F.multiplayer = was_mp
# The actors (inserters and drills using loaded belts) and the chunk caches (bs.bc, bs.bt) follow the
# square: those round belts that left it are forgotten when the scan is taken, and found again when
# it comes back. (They only ever grew as the focus moved, and every actor was checked every update.)
far_belt = spawn("transport-belt", bx + 200, by, force="player", direction=4)
far_ins = spawn("inserter", bx + 200, by + 1, force="player")
far_ins.pickup_target = far_belt
u_far, u_sins, u_sdrop, u_fins = int(far_belt.unit_number), int(s_ins.unit_number), int(s_drop.unit_number), int(far_ins.unit_number)
bs_keys = lua.eval("function(name) local t = {} for k in pairs(storage.f3d.bs[name] or {}) do t[#t + 1] = k end table.sort(t) return t end")
actors_now = lambda: set(to_py(bs_keys("actors")))
chunks_now = lambda name: set(to_py(bs_keys(name)))
check({u_sins, u_sdrop} <= actors_now(), f"bs: the inserters using the loaded belts are actors: {sorted(actors_now())}")
send({"t": "focus", "x": fixed(bx + 200), "y": fixed(by), "r": 48})
tick(30)
take()
far_ck = (int(math.floor((bx + 200) / 32)) + 32768) * 65536 + int(math.floor(by / 32)) + 32768
near_ck = (int(math.floor(bx / 32)) + 32768) * 65536 + int(math.floor(by / 32)) + 32768
check(not ({u_sins, u_sdrop} & actors_now()) and u_fins in actors_now()
      and near_ck not in chunks_now("bc") and near_ck not in chunks_now("bt") and far_ck in chunks_now("bc")
      and u_far in set(to_py(bs_keys("belts"))),
      f"bs: actors and chunk caches round belts that left the square are forgotten: actors {sorted(actors_now())}, bc {sorted(chunks_now('bc'))}, bt {sorted(chunks_now('bt'))}")
send({"t": "focus", "x": fixed(bx), "y": fixed(by), "r": 48})
tick(30)
back = bs_of(take())
alist_now = lambda: set(to_py(lua.eval("function() local t = {} for _, u in ipairs(storage.f3d.bs.alist) do t[#t + 1] = u end return t end")()))
check({u_sins, u_sdrop} <= actors_now() and u_fins not in actors_now() and u2 * 8 + 1 in back["lm"],
      f"bs: back in the square, its belts' actors are found again: {sorted(actors_now())}")
# (And listed again, so they are checked: the list is made again without the forgotten ones, else
# the seen set kept them off it for good.)
check({u_sins, u_sdrop} <= alist_now() and u_fins not in alist_now(),
      f"bs: actors found again are listed again for their checks: {sorted(alist_now())}")
F.set_hand(s_drop, bx + 1, by - 1, "iron-plate")  # (its hand held nothing: a change)
F.put_on_belt(sb2, 2, "iron-plate", 0.9, 8203)  # (behind the lane's items: the fake lists them as put)
tick(18)  # (actor_backoff: a hand that stood is checked every other update, so within two)
woke_back = bs_of(take())
check(8203 in [it[0] for it in woke_back["sl"].get(u2 * 8 + 2, (None, []))[1]],
      f"bs: an actor found again wakes its belt when it acts: {woke_back['sl'].get(u2 * 8 + 2)}")
far_belt.destroy()
far_ins.destroy()
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1})
send({"t": "bfar", "r": 0})
tick(6)
check(of_type(take(), "bi") and lua.eval("storage.f3d.bs") is None, "bs: a client that stops saying bs gets bi again")

# A square `sub` over the wire (what the client sends), after a list one: the chunks it adds come
# nearest its middle first, the ones it keeps aren't sent again, the rest are dropped. Last, so the
# checks above keep their phase of the periodic jobs.
send({"t": "sub", "c": [[0, 0], [1, 0], [9, 9]]})
tick(60)
# (Clear of what sends a subscribed chunk again whatever the client asks, so the check doesn't depend on the
# tick the tests above leave the game at: the 300-tick refresh, and the count of a chunk whose entities the
# tests above changed without an event, which came as a kept chunk sent again.)
world_mod = lua.eval('package.loaded["scripts.world"]')
saved_count_interval = world_mod.count_interval
world_mod.count_interval = 0
while g.game.tick % 300 != 150:  # (the refresh's chunk sent well before, the next one well after)
    tick(1)
take()
send({"t": "sub", "o": [0, 0], "r": 1, "w": [[-1, -1, 3], [0, -1, 3], [1, -1, 3]]})
tick(60)
got = [(m["cx"], m["cy"]) for m in of_type(take(), "chunk")]
check(sorted(got) == sorted({(x, y) for x in (-1, 0, 1) for y in (-1, 0, 1)} - {(0, 0), (1, 0)}) and got[:1] == [(0, -1)]
      and g.storage.f3d.subs["9,9"] is None,
      f"a square `sub` over the wire adds its new chunks nearest first and drops what it leaves out: {got}")
world_mod.count_interval = saved_count_interval

# D6 (last: its ticks would shift the periodic jobs' phase for the checks above): a client that says dq
# gets every datagram numbered: its last line is {"t":"dg","n":N,"k":tick,"b":bytes before it}, N counting
# up without gaps, so the client can count the datagrams the OS dropped. (JSON lines even with --binary: bin 0;
# binary datagrams' dg frame is test_binary.py's.)
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "b": 1, "dq": 1, "bin": 0})
tick(1)
take()
raw = []
for _ in range(6):
    tick(1)
    for item in F.take_sent().values():
        raw.append(item[2])
numbers = []
for data in raw:
    lines = data.split("\n")
    tail = json.loads(lines[-1])
    check(tail.get("t") == "dg" and isinstance(tail.get("n"), int), f"dq: a datagram's last line is its dg number: {lines[-1][:80]}")
    check(tail.get("b") == len(data) - len(lines[-1]) - 1, f"dq: dg.b is the bytes before the dg line: {tail.get('b')} vs {len(data) - len(lines[-1]) - 1}")
    check(len(data) <= MAX_DATAGRAM, f"dq: datagram too large with the dg line: {len(data)} bytes")
    numbers.append(tail.get("n"))
check(len(numbers) >= 6 and numbers == list(range(numbers[0], numbers[0] + len(numbers))), f"dq: datagrams numbered without gaps: {numbers[:12]}")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "b": 1})
tick(1)
take()
tick(3)
for item in F.take_sent().values():
    check('"t":"dg"' not in item[2], "without dq, no dg line")

# --- the 0.2.1 performance hotfix (perf.lua's /f3d-perf switches; belt_sim.lua's housekeeping, /f3d-bs) ----
# Last, as its ticks would shift the periodic jobs' phases for the checks above.
perf_mod = g.package.loaded["scripts.perf"]
world_mod = g.package.loaded["scripts.world"]
transport_mod = g.package.loaded["scripts.transport"]


def set_perf(**switches):
    g.storage.f3d_perf = lua.table_from(switches) if switches else None


hello_now = {"t": "hello", "v": 1, "sid": "s1", "w": 1, "b": 1}


def say(**flags):
    """The hello these checks keep sending (a client unheard for 600 ticks is dropped)."""
    global hello_now
    hello_now = dict({"t": "hello", "v": 1, "sid": "s1", "w": 1}, **flags)
    send(hello_now)


def alive(n=1):
    for _ in range(n):
        if g.game.tick % 100 == 0:
            send(hello_now)
        tick(1)


def no_empty_dicts(v):
    """helpers.table_to_json writes an empty table as {}, the text as []: the client reads both alike."""
    if isinstance(v, dict):
        return {k: no_empty_dicts(x) for k, x in v.items()} if v else []
    if isinstance(v, list):
        return [no_empty_dicts(x) for x in v]
    return v


# 1. Chunk snapshots written as text: the same messages as before, field for field.
odd = spawn("train-stop", 50.0, 20.0, force="player", backer_name='Stop "A" \\ é\n[item=iron-plate]')
F.add_decorative(F.surface, "small-rock", 41, 6, 3)
say(b=1, dc=1)
send({"t": "sub", "c": [[0, 0], [1, 0], [2, 0], [9, 9]]})
alive(40)
take()


def chunk_msgs(text):
    set_perf(chunk_text=text)
    send({"t": "resync", "c": [[0, 0], [1, 0], [2, 0], [9, 9]]})
    alive(40)
    out = {}
    for m in take():
        if m.get("t") in ("chunk", "ents", "dec"):
            m = no_empty_dicts({k: v for k, v in m.items() if k not in ("r", "k")})
            out[(m["t"], m["cx"], m["cy"], m.get("part"))] = m
    return out


as_text, as_tables = chunk_msgs(True), chunk_msgs(False)
set_perf()
check(as_text == as_tables and ("ents", 1, 0, 1) in as_text and ("dec", 1, 0, 1) in as_text and ("chunk", 9, 9, None) in as_text,
      f"chunk_text: chunk, ents and dec written as text are the messages table_to_json wrote: "
      f"{sorted(set(as_text) ^ set(as_tables))} {[k for k in as_text if as_text.get(k) != as_tables.get(k)][:3]}")
stop_rec = [r for r in as_text.get(("ents", 1, 0, 1), {}).get("e", []) if r[0] == odd.unit_number]
check(stop_rec and stop_rec[0][5].get("n") == 'Stop "A" \\ é\n[item=iron-plate]',
      f"chunk_text: a name with quotes, a backslash, a newline and a non-ASCII letter comes through: {stop_rec}")
odd.destroy()
extras = json.loads(lua.eval(r"""function()
  local t = package.loaded["scripts.transport"]
  return t.json_object({ n = 'a"b\\c' .. string.char(1) .. "\t", w = { 3, 1, 2 }, col = { 255, 0, 10 }, d = 1,
    ai = { "item", "iron-plate" }, x = 0.5, big = 2 ^ 40 + 3, neg = -7, e = {}, ok = true })
end""")())
check(extras == {"n": 'a"b\\c\x01\t', "w": [3, 1, 2], "col": [255, 0, 10], "d": 1, "ai": ["item", "iron-plate"], "x": 0.5,
                 "big": 2 ** 40 + 3, "neg": -7, "e": [], "ok": True},
      f"chunk_text: a record's extras key by key, as JSON: {extras}")
check(lua.eval('function() return package.loaded["scripts.world"].record_text({ 5, 2, 256, -512, 4 }) end')() == "[5,2,256,-512,4]",
      "chunk_text: a record without extras is its five numbers")

# 7. The chunk queue: taken from its head (no table.remove shifting it), compacted as it goes; a long
# square queue put in a new order over ticks (requeue_slices), ending in the order it had at once.
queue_check = lua.eval("""function()
  local W = package.loaded["scripts.world"]
  local s = storage.f3d
  local saved = { s.subs, s.queue, s.queued, s.rank, s.order, s.have, s.sub_o, s.sub_r, s.sub_rows, s.sub_n, s.sub_f, s.rq, s.snap }
  local out = {}
  local rows = {}
  for cy = -20, 20 do
    rows[#rows + 1] = { cy, -20, 41 }
  end
  local function fresh()
    s.subs, s.queue, s.queued, s.rank, s.order, s.have = {}, {}, {}, {}, {}, {}
    s.sub_o, s.sub_r, s.sub_rows, s.sub_n, s.sub_f, s.rq, s.snap = nil, nil, nil, nil, nil, nil, nil
  end
  local function from_head()
    local t = {}
    for i = s.queue.h or 1, #s.queue do
      t[#t + 1] = s.queue[i]
    end
    return table.concat(t, " ")
  end
  local function finish()
    local steps = 0
    while s.rq do
      W.requeue_step(s, 1024)
      steps = steps + 1
    end
    return steps
  end
  -- Ordered at once (requeue_slices off) and over ticks: the same order.
  storage.f3d_perf = { requeue_slices = false }
  fresh()
  W.subscribe_square({ 0, 0 }, 20, rows, nil, { 256, 0 })
  W.subscribe_square({ 0, 0 }, 20, rows, nil, { 0, 256 })
  local at_once = from_head()
  storage.f3d_perf = nil
  fresh()
  W.subscribe_square({ 0, 0 }, 20, rows, nil, { 256, 0 })
  finish()
  local before = from_head()
  W.subscribe_square({ 0, 0 }, 20, rows, nil, { 0, 256 })
  out[#out + 1] = tostring(s.rq ~= nil and from_head() == before)  -- the packet handler only starts the job
  local steps = finish()
  out[#out + 1] = tostring(from_head() == at_once) .. " " .. steps
  -- Chunks taken while the job deals, one queued again meanwhile: the new order less those taken.
  W.subscribe_square({ 0, 0 }, 20, rows, nil, { -256, 0 })
  local taken = {}
  for i = 1, 5 do
    taken[i] = W.take_next()
  end
  W.requeue_step(s, 300)
  W.enqueue(taken[3])
  finish()
  storage.f3d_perf = { requeue_slices = false }
  local got = from_head()
  local s2 = {}
  fresh()
  W.subscribe_square({ 0, 0 }, 20, rows, nil, { -256, 0 })
  local want = {}
  local skip = { [taken[1]] = true, [taken[2]] = true, [taken[4]] = true, [taken[5]] = true }
  for i = s.queue.h or 1, #s.queue do
    if not skip[s.queue[i]] then
      want[#want + 1] = s.queue[i]
    end
  end
  out[#out + 1] = tostring(got == table.concat(want, " "))
  -- Taken from the head: the list kept until COMPACT_AT have gone, then made again.
  local n0 = W.queued_count()
  for i = 1, 1100 do
    W.take_next()
  end
  out[#out + 1] = tostring(W.queued_count() == n0 - 1100 and (s.queue.h or 1) <= 1024 and #s.queue - (s.queue.h or 1) + 1 == n0 - 1100)
  storage.f3d_perf = nil
  s.subs, s.queue, s.queued, s.rank, s.order, s.have = saved[1], saved[2], saved[3], saved[4], saved[5], saved[6]
  s.sub_o, s.sub_r, s.sub_rows, s.sub_n, s.sub_f, s.rq, s.snap = saved[7], saved[8], saved[9], saved[10], saved[11], saved[12], saved[13]
  return table.concat(out, "|")
end""")().split("|")
check(queue_check[0] == "true", "requeue_slices: a new view direction starts the job; the packet handler doesn't order the queue")
check(queue_check[1].startswith("true ") and int(queue_check[1].split()[1]) > 1,
      f"requeue_slices: over {queue_check[1].split()[-1]} steps the queue ends in the order it had at once")
check(queue_check[2] == "true", "requeue_slices: chunks taken meanwhile are left out, one queued again meanwhile goes in by its rank")
check(queue_check[3] == "true", "the chunk queue is taken from its head, made again past 1024 taken")

# 4. Wires in strips: each strip a run, every wire within a round (8 x 30 ticks); a wire added between
# two poles updates both.
say(b=1)
send({"t": "focus", "x": fixed(20), "y": fixed(20), "r": 64})
send({"t": "sub", "c": [[0, 0], [1, 0], [0, 1], [1, 1]]})
wa = spawn("small-electric-pole", 24.5, 40.5, force="player")
wb = spawn("small-electric-pole", 27.5, 40.5, force="player")
for e in (wa, wb):
    F["raise"]("script_raised_built", lua.table_from({"entity": e}))
strips_seen = set()
for _ in range(300):
    alive(1)
    strips_seen.add(g.storage.f3d.wire_strip)
take()
check({1, 2, 3, 4, 5, 6, 7, 8} <= strips_seen and g.storage.f3d.wire_sigs[wa.unit_number] is not None,
      f"wire_strips: the square's eight strips in turn, each pole's wires noted: {sorted(x for x in strips_seen if x)}")
F.connect(wa, wb, g.defines.wire_type.copper)
wire_upd = {}
for _ in range(300):
    alive(1)
    wire_upd.update({m["e"][0]: m["e"] for m in of_type(take(), "upd")})
    if wa.unit_number in wire_upd and wb.unit_number in wire_upd:
        break
check(wire_upd.get(wa.unit_number, [0] * 6)[5].get("w") == [wb.unit_number] and wb.unit_number in wire_upd,
      f"wire_strips: a wire added between two poles updates both within a round of strips: {sorted(wire_upd)}")
wa_unit = wa.unit_number
wa.destroy()
wb.destroy()
alive(300)
take()
check(g.storage.f3d.wire_sigs[wa_unit] is None, "wire_strips: a pole gone is forgotten when its strip comes round")
# A wire a script takes away right after building, before the strips' first look at the poles: the
# wires their records were sent with are the last look (tracker.lua note_wires), so the change is
# sent; it was taken as the start and never sent (live_check's poles passed only when their strip
# came round in time).
wc = spawn("small-electric-pole", 24.5, 44.5, force="player")
wd = spawn("small-electric-pole", 27.5, 44.5, force="player")
F.connect(wc, wd, g.defines.wire_type.copper)
for e in (wc, wd):
    F["raise"]("script_raised_built", lua.table_from({"entity": e}))
alive(1)
added = {m["e"][0]: m["e"] for m in of_type(take(), "add")}
wc.get_wire_connector(ids.pole_copper, False).disconnect_from(wd.get_wire_connector(ids.pole_copper, False))
cut = {}
for _ in range(300):
    alive(1)
    cut.update({m["e"][0]: m["e"] for m in of_type(take(), "upd")})
    if wc.unit_number in cut and wd.unit_number in cut:
        break
check(added.get(wc.unit_number, [0] * 6)[5:] == [{"w": [wd.unit_number]}] and wd.unit_number in cut
      and not (cut.get(wc.unit_number, [0] * 6)[5:] or [{}])[0].get("w"),
      f"wire_strips: a wire cut right after building, before the strips' first look, updates both: {added.get(wc.unit_number)} {cut}")
wc_unit = wc.unit_number
F["raise"]("script_raised_destroy", lua.table_from({"entity": wc}))
check(g.storage.f3d.wire_sigs[wc_unit] is None, "a pole removed is forgotten by the wire look at once")
wc.destroy()
wd.destroy()
alive(2)
take()

# 6. Machine states: near ones every round, far ones a strip a round (each every 120 ticks), what was
# sent kept across rounds.
max_focus = g.settings["global"]["f3d-max-focus-radius"]
saved_max_focus = max_focus.value
max_focus.value = 192
send({"t": "focus", "x": fixed(20), "y": fixed(20), "r": 150})
near_m = spawn("assembling-machine-1", 30.5, 20.5, force="player")
far_m = spawn("assembling-machine-1", 120.5, 20.5, force="player")
for e in (near_m, far_m):
    e.status = g.defines.entity_status.working
alive(150)
take()
for e in (near_m, far_m):
    e.status = g.defines.entity_status.no_power
st_first = {}
# Whether the far machine's state is kept between its strip's turns: from its first send, until a round
# reports everything again (every 300 ticks: its strip sends it again later; seen as the near one sent
# again, a tick after), whatever tick the tests before have left the game at.
far_kept = None
far_lost = []
for t in range(1, 151):
    alive(1)
    rows = [v for m in of_type(take(), "st") for v in m["l"]]
    sent_now = dict(zip(rows[0::2], rows[1::2]))
    if near_m.unit_number in sent_now and near_m.unit_number in st_first:
        far_kept = False
        if far_lost and far_lost[-1] == t - 1:
            far_lost.pop()  # (the round's messages go out on the tick after it read)
    for u, v in zip(rows[0::2], rows[1::2]):
        st_first.setdefault(u, (t, v))
    if far_m.unit_number in sent_now:
        far_kept = True
    if far_kept and g.storage.f3d.working[far_m.unit_number] != 0:
        far_lost.append(t)
check(st_first.get(near_m.unit_number, (99, None))[0] <= 31 and st_first.get(near_m.unit_number, (0, 1))[1] == 0,
      f"states_near: a machine within 64 tiles is sent within a round: {st_first.get(near_m.unit_number)}")
check(st_first.get(far_m.unit_number, (999, None))[0] <= 125 and st_first.get(far_m.unit_number, (0, 1))[1] == 0,
      f"states_near: one further out within four rounds: {st_first.get(far_m.unit_number)}")
check(far_kept is not None and not far_lost, f"states_near: what was sent of a far machine is kept between its strip's turns: {far_lost[:3]}")
st_at = g.storage.f3d.st_at
check(st_at is not None and st_at[near_m.unit_number] == 0 and st_at[far_m.unit_number] in (1, 2, 3, 4),
      "states_near: the near machine is read with the near square, the far one with its strip of the rest")
near_m.destroy()
far_m.destroy()
max_focus.value = saved_max_focus
send({"t": "focus", "x": fixed(20), "y": fixed(20), "r": 64})

# 5. Lightning on a planet without it (Nauvis in the fake): looked for every 300 ticks, not 12.
pp = g.storage.f3d.focus
while g.game.tick % 300 != 10:
    alive(1)
take()
g.storage.f3d.planets_busy = lua.table_from({})
nauvis_bolt = spawn("lightning", pp.x + 2.5, pp.y + 2.5 - 25)
lt_ticks = []
for _ in range(299):
    alive(1)
    if of_type(take(), "lt"):
        lt_ticks.append(g.game.tick % 300)
# (Once it found one it looks every 3 ticks for a while, and this bolt stays: sent again as each strike
# is forgotten. The first look is the one that counts.)
check(lt_ticks[:1] in ([5], [6]) and len(lt_ticks) <= 3,
      f"lightning_planets: on a planet without lightning a strike is looked for every 300 ticks: {lt_ticks}")
nauvis_bolt.destroy()
set_perf(lightning_planets=False)
g.storage.f3d.planets_busy = lua.table_from({})
second_bolt = spawn("lightning", pp.x - 2.5, pp.y + 2.5 - 25)
lt_seen = False
for _ in range(13):
    alive(1)
    lt_seen = lt_seen or bool(of_type(take(), "lt"))
check(lt_seen, "lightning_planets off: every 12 ticks on any surface, as before")
second_bolt.destroy()
set_perf()

# 2 and 3. A belt-simulating client: far lanes, the watched belts' order, quiet belts before `valid`, the
# scan's step.
qx, qy = -47.5, -47.5
q_belts = [spawn("transport-belt", qx + k, qy, force="player", direction=4) for k in range(6)]
for k in range(5):
    F.link_belts(q_belts[k], q_belts[k + 1])
q_ins = [spawn("inserter", qx + k, qy + 1, force="player") for k in (1, 3)]
q_ins[0].pickup_target = q_belts[1]
q_ins[1].drop_target = q_belts[3]
q_split = spawn("splitter", qx + 2, qy - 4, force="player", direction=4)
lone = spawn("transport-belt", qx + 20, qy, force="player", direction=4)  # in chunk (-1, -2), 20 tiles out
F.put_on_belt(lone, 1, "iron-plate", 0.5, 9301)
saved_spot_quiet = bs_mod.spot_quiet_ticks
bs_mod.spot_quiet_ticks = 6000
say(z=1, bl=1, bs=1)
send({"t": "focus", "x": fixed(qx), "y": fixed(qy), "r": 64})
send({"t": "sub", "c": [[cx, cy] for cx in range(-3, 1) for cy in range(-3, 1)]})
send({"t": "bfar", "r": 40, "n": 40, "m": 0})
alive(60)
take()
cover = to_py(lua.eval('function() return package.loaded["scripts.belt_sim"].covered() end')())
check(cover and cover[2] == 40, f"far_lanes: once loaded the simulation covers its whole square: {cover}")


def far_round():
    far = g.storage.f3d.far
    far.started, far.cur, far.next = None, None, 1
    far.queue, far.sent = lua.table_from([]), lua.table_from({})
    out = []
    for _ in range(10):
        alive(1)
        out += [(m["cx"], m["cy"]) for m in of_type(take(), "bfar")]
    return out, len(g.storage.f3d.far.queue)


far_on, queued_on = far_round()
set_perf(far_lanes=False)
far_off, queued_off = far_round()
set_perf()
check(far_on == [] and queued_on == 0 and (-1, -2) in far_off and queued_off > 0,
      f"far_lanes: a simulating client whose square reaches the far distance gets no far lanes read (off: {far_off}, {queued_off} chunks)")
# The watched belts' order without a Lua comparator: the same list as the sort's.
order_on = to_py(bs_mod.watch_list())
g.storage.f3d_bs = lua.table_from({"watch_nosort": False})
order_off = to_py(bs_mod.watch_list())
g.storage.f3d_bs = None
spots = {int(q_belts[k].unit_number) for k in (0, 1, 3)}
check(order_on == order_off and len(order_on) >= 4 and set(order_on[:3]) == spots and int(q_split.unit_number) in order_on,
      f"watch_nosort: the watched belts in the sort's order, input spots first: {order_on} vs {order_off}")
# A quiet watched belt is passed over before its `valid` is read: one gone without an event is dropped
# when its check comes up (off: at once).
gone_unit = int(q_belts[1].unit_number)
q_belts[1].destroy()
alive(12)
dl_on = bs_of(take())["dl"]
still = g.storage.f3d.bs.belts[gone_unit] is not None
g.storage.f3d_bs = lua.table_from({"quiet_first": False})
alive(12)
dl_off = bs_of(take())["dl"]
g.storage.f3d_bs = None
check(still and gone_unit * 8 + 1 not in dl_on and gone_unit * 8 + 1 in dl_off,
      f"quiet_first: a quiet watched belt gone without an event waits for its check (off: dropped at once): {dl_on} / {dl_off}")
bs_mod.spot_quiet_ticks = saved_spot_quiet
# First loads of belts past walk_near: LOAD_MIN (400) a tick while the tick's budget is in use (here 250 of
# 300 units), their share when it is idle; off, their share either way. Only once the client's square has
# been loaded whole (b.whole): a join's first load takes its share, busy or not.
bsst, bud = g.storage.f3d.bs, g.storage.f3d.bud
saved_load = (bsst.load_i, bsst.thin, bsst.whole, bud.used, bud.limit)
bsst.load_i, bsst.thin, bsst.whole, bud.limit = 1, None, True, 300
bud.jobs.bsload = 0
g.storage.f3d_bs = lua.table_from({"walk_near": 0})
bud.used = 0
idle_limit = bs_mod.load_limit_now()
bud.used = 250
busy_limit = bs_mod.load_limit_now()
bsst.whole = None
busy_first = bs_mod.load_limit_now()
bsst.whole = True
g.storage.f3d_bs = lua.table_from({"walk_near": 0, "far_load_cap": False})
busy_off = bs_mod.load_limit_now()
g.storage.f3d_bs = None
bsst.load_i, bsst.thin, bsst.whole, bud.used, bud.limit = saved_load
check(idle_limit == 3000 and busy_limit == 400 and busy_off == 1000,
      f"far_load_cap: loads past walk_near take LOAD_MIN unless the budget is idle: idle {idle_limit}, busy {busy_limit}, off {busy_off}")
check(busy_first == 1000,
      f"far_load_cap: not before the client's square was first loaded whole (a join loads at its share): {busy_first}")
# A new scan once the focus moved r / 32 tiles (here 96 / 32 = 3), not every tile.
send({"t": "bfar", "r": 0, "n": 96, "m": 0})
alive(12)
for _ in range(600):
    alive(1)
    if g.storage.f3d.bs.scanning is None:
        break
take()
moved0 = int(bs_mod.counts.scan_moved)
send({"t": "focus", "x": fixed(qx + 2), "y": fixed(qy), "r": 64})
alive(13)
moved1 = int(bs_mod.counts.scan_moved)
send({"t": "focus", "x": fixed(qx + 4), "y": fixed(qy), "r": 64})
for _ in range(90):
    alive(1)
    if int(bs_mod.counts.scan_moved) > moved0:
        break
moved2 = int(bs_mod.counts.scan_moved)
take()
check(moved1 == moved0 and moved2 == moved0 + 1, f"scan_step: no new scan for 2 tiles at 96, one for 4: {moved0} {moved1} {moved2}")
send({"t": "bfar", "r": 0})
for e in q_belts + q_ins + [q_split, lone]:
    if e.valid:
        e.destroy()
alive(6)
take()

# --- the round after the hotfix (bridge.md changes 8-15), each its own switch ---------------------------
# 15. Records by prototype: the same record, natural entities reading their deconstruction mark alone.
rec_ents = [spawn("tree-01", 70.5, 70.5), spawn("iron-ore", 71.5, 70.5, amount=7),
            spawn("cliff", 73.0, 70.5, cliff_orientation="west-to-east"), spawn("assembling-machine-1", 76.5, 70.5, force="player"),
            spawn("transport-belt", 79.5, 70.5, force="player", direction=4), spawn("small-electric-pole", 81.5, 70.5, force="player")]
F.decon_marks[rec_ents[0]] = True
record_of = lua.eval('function(e) return package.loaded["scripts.world"].record(e) end')
recs_on = [to_py(record_of(e)) for e in rec_ents]
set_perf(records_by_prototype=False)
recs_off = [to_py(record_of(e)) for e in rec_ents]
set_perf()
check(recs_on == recs_off and recs_on[0][5] == {"d": 1} and recs_on[1][5] == {"a": 7} and recs_on[2][5] == {"co": "west-to-east"},
      f"records_by_prototype: the same records, a marked tree's mark, ore's amount, a cliff's piece: {recs_on} vs {recs_off}")
for e in rec_ents:
    e.destroy()

# 14. The alerts pass passes over chunks it found none of the force's machines in, until something is built
# there or every tenth pass; and steps once a tick whatever the clients.
alerts_mod = g.package.loaded["scripts.alerts"]


def unplugged_at(msg, x, y):
    for kind, _, shown in msg["l"]:
        if kind == "unplugged" and any(r[0] == fixed(x) and r[1] == fixed(y) for r in shown):
            return True
    return False


def alerts_now(skip_recheck):
    """M.current() on a pass that isn't (or is) one of the tenth that look in empty chunks too."""
    while (alerts_mod.pass_count() + 1) % 10 == 0 if skip_recheck else (alerts_mod.pass_count() + 1) % 10 != 0:
        alerts_mod.current()
    return to_py(alerts_mod.current())


# (From a pass that looked in every chunk: the next nine pass over the empty ones, whatever passes the
# tests before have run.)
while alerts_mod.pass_count() % 10 != 0:
    alerts_mod.current()
alerts_now(True)
empties = int(alerts_mod.empty_chunks())
dark = spawn("assembling-machine-1", 100.5, -90.5, force="player")
dark.status = g.defines.entity_status.no_power
dark.electric_network_id = None
unseen = unplugged_at(alerts_now(True), 100.5, -90.5)
F["raise"]("script_raised_built", lua.table_from({"entity": dark}))
seen_after_build = unplugged_at(alerts_now(True), 100.5, -90.5)
check(empties > 10 and not unseen and seen_after_build,
      f"alerts_quiet: chunks with none of the force's machines are passed over ({empties}) until something is built there: {unseen} {seen_after_build}")
dark.destroy()
set_perf(alerts_quiet=False)
dark2 = spawn("assembling-machine-1", 100.5, -80.5, force="player")
dark2.status = g.defines.entity_status.no_power
dark2.electric_network_id = None
check(unplugged_at(alerts_now(True), 100.5, -80.5), "alerts_quiet off: every chunk every pass, as before")
dark2.destroy()
set_perf()
# alerts_quiet waits PASS_INTERVAL (600 ticks) after a pass finishes before starting the next.
alerts_mod.current()
p_after = int(alerts_mod.pass_count())
alive(300)
p_mid = int(alerts_mod.pass_count())
alive(320)
p_next = int(alerts_mod.pass_count())
check(p_mid == p_after and p_next > p_after,
      f"alerts_quiet: waits PASS_INTERVAL after a pass finishes ({p_after} -> {p_mid} -> {p_next})")

# J5: round the focus the unplugged icon comes from fluids_power's read and the build events, not the pass
# over every surface (10-40 s late on a big base): a machine built out of every pole's reach is listed the
# tick after, gone the tick after a pole reaches it, and a machine that loses its pole without an event is
# listed by the next read (once a second).
j5_start = int(g.game.tick)
j5_focus = to_py(g.storage.f3d.focus)
send({"t": "focus", "x": fixed(40), "y": fixed(40), "r": 32})
alive(130)
while (int(g.game.tick) + 29) % 60 != 1:  # just past the once-a-second `al`: the next one only for a change
    alive(1)
take()
lone = spawn("assembling-machine-1", 45.5, 45.5, force="player")
lone.status = g.defines.entity_status.no_power
lone.electric_network_id = None
F["raise"]("script_raised_built", lua.table_from({"entity": lone}))
alive(8)  # (an `al` for a change waits 6 ticks after the last)
al_built = of_type(take(), "al")
check(len(al_built) >= 1 and unplugged_at(al_built[0], 45.5, 45.5),
      f"J5: a machine built out of every pole's reach round the focus is unplugged in an `al` the tick after: {al_built}")
lone.electric_network_id = 7
lone.status = g.defines.entity_status.working
j5_pole = spawn("small-electric-pole", 47.5, 45.5, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": j5_pole}))
alive(8)
al_pole = of_type(take(), "al")
check(al_pole and not unplugged_at(al_pole[-1], 45.5, 45.5),
      f"J5: and no longer once a pole reaches it, at once: {al_pole}")
lone.electric_network_id = None
lone.status = g.defines.entity_status.no_power
alive(75)
al_read = of_type(take(), "al")
check(al_read and unplugged_at(al_read[-1], 45.5, 45.5), f"J5: a pole gone without an event: the next read lists it: {al_read[-1:]}")
lone.destroy()
j5_pole.destroy()
send({"t": "focus", "x": fixed(j5_focus["x"]), "y": fixed(j5_focus["y"]), "r": int(j5_focus["r"])})
while (int(g.game.tick) - j5_start) % 1200:  # the checks after keep the tick phase they were written at
    alive(1)
take()

# The ninth list's delays (J20-J22, J27, J28): turrets out of ammo, machines out of fuel and drills with nothing to
# mine round the focus come from the once-a-second power read and the reads after building or moving items, not the
# alerts' pass (J5's way); what the character mines is said at once (`mnd`); a belt it puts items on or takes them off
# has its lanes read in the next belt update.
j9_start = int(g.game.tick)
j9_focus = to_py(g.storage.f3d.focus)
j9_pup = g.storage.f3d.puppet
j9_was = to_py(j9_pup.position)
j9_pup.position = lua.table_from({"x": 40, "y": 40})
send({"t": "focus", "x": fixed(40), "y": fixed(40), "r": 32})
near_id = lua.eval("function() return tostring(storage.f3d.al_near) end")


def until_read():
    """Ticks on to the one the once-a-second read (fluids_power, alerts' listener) has just run on."""
    was = near_id()
    for _ in range(130):
        alive(1)
        if near_id() != was:
            return True
    return False


def kinds_in(msgs):
    al = of_type(msgs, "al")
    return {kind: [r[4] for r in shown] for kind, _, shown in al[-1]["l"]} if al else None


until_read()
alive(8)
take()
# J22: a turret built without ammo: in `no_ammo` within the ticks after (it is read again itself), not at the
# next read or pass; ammo put in by Ctrl+click takes it off as soon (the buildings in reach are read 2 ticks on).
j9_tur = spawn("gun-turret", 44.0, 44.0, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": j9_tur}))
alive(8)
k = kinds_in(take())
check(k is not None and j9_tur.unit_number in k.get("no_ammo", []),
      f"J22: a turret built without ammo round the focus is out of ammo in an `al` within 8 ticks: {k}")
until_read()
alive(10)
take()
j9_pup.get_main_inventory().insert(lua.table_from({"name": "firearm-magazine", "count": 10}))  # (insert would take it to the ammo slots)
send(dict(target_of(j9_tur), t="fast", item="firearm-magazine", n=5))
alive(8)
k = kinds_in(take())
check(k is not None and j9_tur.unit_number not in k.get("no_ammo", []),
      f"J22: and off it within 8 ticks after a Ctrl+click puts ammo in (not at the next read): {k}")
# J28: a furnace that runs out of fuel without an event: the next read lists it; fuel put in by Ctrl+click: off
# within a few ticks.
j9_fur = spawn("stone-furnace", 46.0, 40.0, force="player")
j9_fur.status = g.defines.entity_status.no_fuel
until_read()
alive(8)
k = kinds_in(take())
check(k is not None and j9_fur.unit_number in k.get("no_fuel", []), f"J28: a furnace out of fuel round the focus, by the next read: {k}")
alive(10)
take()
j9_fur.status = g.defines.entity_status.working
j9_pup.insert(lua.table_from({"name": "coal", "count": 10}))
send(dict(target_of(j9_fur), t="fast", item="coal", n=5))
alive(8)
k = kinds_in(take())
check(k is not None and j9_fur.unit_number not in k.get("no_fuel", []),
      f"J28: and off it within 8 ticks after a Ctrl+click puts fuel in: {k}")
# J27: a drill with nothing left to mine (no_minable_resources): `depleted`, by the next read.
j9_drill = spawn("burner-mining-drill", 50.0, 44.0, force="player")
j9_drill.status = g.defines.entity_status.no_minable_resources
until_read()
alive(8)
k = kinds_in(take())
check(k is not None and j9_drill.unit_number in k.get("depleted", []),
      f"J27: a drill with nothing left to mine round the focus is `depleted`: {k}")
# status_near off: those kinds from the pass alone, as before (the read lists none of them).
set_perf(status_near=False)
until_read()
off_near = g.storage.f3d.al_near
check(len(list(off_near.d.keys())) == 0 and len(list(off_near.a.keys())) == 0,
      "status_near off: the read lists no depleted drills or turrets out of ammo")
set_perf()
for e in (j9_tur, j9_fur, j9_drill):
    e.destroy()
alive(2)
take()

# L11: a pipeline over Factorio's extent limit (pipeline_overextended): one entity of its segment in `al` `pipeline`
# the tick after a pipe is built round the focus (not at the pass), the segment's entity nearest the line 320 tiles
# in from its far edge (where a pump would split it); its pipes' hinfo says the extent and the status; gone once
# mended; the pass finds it too; pipe_alerts off: none.
l11 = [spawn("pipe", 36.5 + i, 48.5, force="player") for i in range(4)]
l11_box = {"left_top": {"x": 30.2, "y": 48.2}, "right_bottom": {"x": 358.8, "y": 48.8}}
for p_ in l11:
    F.segments[p_] = lua.table_from({"id": 77, "box": l11_box}, recursive=True)
    p_.status = g.defines.entity_status.pipeline_overextended
until_read()
alive(8)
take()
F["raise"]("script_raised_built", lua.table_from({"entity": l11[3]}))
alive(8)
k = kinds_in(take())
check(k is not None and k.get("pipeline") == [l11[2].unit_number],
      f"L11: an overextended pipeline is one `pipeline` alert the ticks after a pipe is built, on its pipe nearest the cut "
      f"(358.8 - 320 = 38.8: the third): {k}")
send({"t": "hinfo", "q": 61, "u": l11[0].unit_number, "p": 0, "x": fixed(l11[0].position.x), "y": fixed(l11[0].position.y)})
tick(2)
hp_ = {m["q"]: m for m in of_type(take(), "hinfo")}.get(61, {})
check(hp_.get("pl") == [329, 320] and hp_.get("ox") == 1 and "el" not in hp_,
      f"L11: a pipe's hinfo: its pipeline's extent over the limit and overextended: {hp_}")
check(any(kind == "pipeline" and shown for kind, _, shown in to_py(alerts_mod.current())["l"]),
      "L11: the alerts' pass lists it too")
for p_ in l11:
    p_.status = g.defines.entity_status.working
F["raise"]("script_raised_built", lua.table_from({"entity": l11[0]}))
alive(8)
k = kinds_in(take())
check(k is not None and "pipeline" not in k, f"L11: mended (a pump split it), it goes at once: {k}")
for p_ in l11:
    p_.status = g.defines.entity_status.pipeline_overextended
set_perf(pipe_alerts=False)
F["raise"]("script_raised_built", lua.table_from({"entity": l11[1]}))
alive(70)
k = kinds_in(take())
check(k is not None and "pipeline" not in k and not any(kind == "pipeline" for kind, _, _ in to_py(alerts_mod.current())["l"]),
      f"pipe_alerts off: no pipeline alert, from the spots or the pass: {k}")
set_perf()
for p_ in l11:
    p_.destroy()
alive(2)
take()

# L6: a resource's hinfo has its amount now; the map's `rpatch` sums the patch under the point (ore within its search
# radius of each other, 3 tiles: a gap of 2 joins, one 5 away doesn't), its tiles as runs a row; an infinite one's
# yields in percent of its normal amount; nothing where there is no charted resource.
l6_ore = [spawn("iron-ore", 60.5 + i, 60.5, amount=100 + i) for i in range(3)]
l6_ore.append(spawn("iron-ore", 65.5, 60.5, amount=1000))  # 3 tiles from the last: joins
l6_far = spawn("iron-ore", 72.5, 60.5, amount=5000)  # 7 tiles on: another patch
l6_oil = [spawn("crude-oil", 60.5, 70.5, amount=150000), spawn("crude-oil", 70.5, 70.5, amount=300000)]
F.charted["1,1"] = True
F.charted["1,2"] = True
F.charted["2,1"] = True
F.charted["2,2"] = True
send({"t": "hinfo", "q": 62, "u": 0, "p": eid["iron-ore"], "x": fixed(60.5), "y": fixed(60.5)})
send({"t": "rpatch", "q": 63, "x": fixed(61.2), "y": fixed(60.7)})
send({"t": "rpatch", "q": 64, "x": fixed(70.0), "y": fixed(71.0)})
send({"t": "rpatch", "q": 65, "x": fixed(10.5), "y": fixed(90.5)})
tick(4)
msgs = take()
hr6 = {m["q"]: m for m in of_type(msgs, "hinfo")}.get(62, {})
rp = {m["q"]: m for m in of_type(msgs, "rpatch")}
check(hr6.get("ra") == 100, f"L6: a resource's hinfo says its amount now: {hr6}")
ore_patch = rp.get(63, {})
check(ore_patch.get("n") == "iron-ore" and ore_patch.get("a") == 100 + 101 + 102 + 1000 and ore_patch.get("c") == 4
      and ore_patch.get("o") == [[60, 60, 3, 65, 1]] and "y" not in ore_patch,
      f"L6: rpatch sums the ore patch under the point, within its search radius, and outlines its tiles: {ore_patch}")
oil_patch = rp.get(64, {})
check(oil_patch.get("n") == "crude-oil" and oil_patch.get("c") == 2 and oil_patch.get("y") == 150
      and oil_patch.get("o") == [[69, 59, 3, 69, 3], [70, 59, 3, 69, 3], [71, 59, 3, 69, 3]],
      f"L6: crude oil wells 10 apart are one field (radius 12), its yields summed (50% + 100%), each well's 3x3 outlined: {oil_patch}")
check(rp.get(65) is not None and set(rp[65]) <= {"t", "q", "k"}, f"L6: no resource there: only q: {rp.get(65)}")
for e in l6_ore + [l6_far] + l6_oil:
    e.destroy()

# J20: mining sends `mnd` the tick it finishes, before the `del` (which waits in the reliable outbox), with what the
# character got, and the inventory at once.
j9_belt = spawn("transport-belt", 41.5, 40.5, force="player", direction=4)
for _ in range(5):
    send(dict(target_of(j9_belt), t="mine"))
    alive(15)
msgs = take()
mnd = [m for m in of_type(msgs, "mnd") if m["u"] == j9_belt.unit_number] if not j9_belt.valid else []
check(not j9_belt.valid and len(mnd) == 1 and mnd[0]["g"] == 1 and ["transport-belt", 1] in mnd[0]["l"]
      and mnd[0]["x"] == fixed(41.5) and mnd[0]["p"] == eid["transport-belt"],
      f"J20: a mined belt is said at once: gone, its place, the belt back in the inventory: {mnd}")
# (`inv` is reliable: stamped when the outbox sends it, the tick after.)
check(bool(mnd) and any(mnd[0]["k"] <= m["k"] <= mnd[0]["k"] + 1 and any(row[0] == "transport-belt" for row in m["l"])
                        for m in of_type(msgs, "inv")),
      f"J20: the inventory goes with it, not at its 30-tick report: {[m['k'] for m in of_type(msgs, 'inv')]} {mnd[:1]}")
j9_ore = spawn("iron-ore", 40.5, 41.5, amount=5)
for _ in range(10):  # (the fake's ore takes 1 s / 0.5: 120 ticks a unit)
    send(dict(target_of(j9_ore), t="mine"))
    alive(15)
ore_mnd = [m for m in of_type(take(), "mnd") if m["p"] == eid["iron-ore"]]
check(ore_mnd and ore_mnd[0]["g"] == 0 and ore_mnd[0]["l"] == [["iron-ore", 1]],
      f"J20: ore mined by hand: a unit at a time, the patch still there: {ore_mnd[:2]}")
j9_ore.destroy()
set_perf(mined_now=False)
j9_belt2 = spawn("transport-belt", 41.5, 40.5, force="player", direction=4)
for _ in range(5):
    send(dict(target_of(j9_belt2), t="mine"))
    alive(15)
check(not j9_belt2.valid and not of_type(take(), "mnd"), "mined_now off: no `mnd`, as before")
set_perf()

# J21: a belt the character puts an item on (Ctrl+click) or drops one on (Z) has its lanes asked for again (read in
# the next belt update, as a client's `bre`), not left to its drift check.
lua.execute("""
F_resent = {}
local bs = package.loaded["scripts.belt_sim"]
F_resend_real = bs.resend
bs.resend = function(cmd)
  for _, k in ipairs(cmd.l) do
    F_resent[#F_resent + 1] = k
  end
  return F_resend_real(cmd)
end
""")
j9_put = spawn("transport-belt", 42.5, 41.5, force="player", direction=4)
j9_pup.insert(lua.table_from({"name": "iron-plate", "count": 10}))
send(dict(target_of(j9_put), t="fast", item="iron-plate", n=1))
alive(1)
lanes = sorted(int(v) for v in g.F_resent.values())
unit8 = int(j9_put.unit_number) * 8
check(lanes == [unit8 + 1, unit8 + 2], f"J21: a Ctrl+click onto a belt asks for its lanes again: {lanes} (unit {j9_put.unit_number})")
lua.execute("F_resent = {}")
send({"t": "drop", "item": "iron-plate", "x": fixed(42.5), "y": fixed(41.5)})
alive(1)
lanes = sorted(int(v) for v in g.F_resent.values())
check(lanes == [unit8 + 1, unit8 + 2], f"J21: so does Z over a belt: {lanes}")
lua.execute("F_resent = {}")
set_perf(put_lanes=False)
send(dict(target_of(j9_put), t="fast", item="iron-plate", n=1))
alive(1)
check(len(list(g.F_resent.values())) == 0, "put_lanes off: nothing asked, as before")
set_perf()

# drop_put: Z onto a belt tells the item at once as a put with no inserter (`ie` kind 6, unit 0: lane, place, id) for a
# client whose hello says `ho`, and wakes the belt's drift checks (quiet_pc); off: the lanes' read alone, as before.
def z_put_records(msgs):
    out = []
    for m in of_type(msgs, "ie"):
        l = list(m["l"])
        if m.get("z") == 1:
            for i in range(9, len(l)):
                l[i] += l[i - 9]
        for i in range(0, len(l), 9):
            if l[i] == 6 and l[i + 1] == 0:
                out.append(l[i:i + 9])
    return out


# (The client's `ie` and `ho` set as its hello would, without a new hello: one resends what a later check counts.)
dz_t0 = int(g.game.tick)
g.storage.f3d.client.ie, g.storage.f3d.client.ho = True, True
dz_belt = spawn("transport-belt", 43.5, 41.5, force="player", direction=4)
dz_unit = int(dz_belt.unit_number)
g.F_dz_belt = dz_belt
lua.execute("""
local surface = game.surfaces[1]
F_spill_real = surface.spill_item_stack
surface.spill_item_stack = function(p)
  -- (the game's spill with allow_belts: onto the belt under it, with the newest unique id)
  F.next_item_id = (F.next_item_id or 9000) + 1
  F.put_on_belt(F_dz_belt, 1, p.stack.name, 0.4, F.next_item_id)
  return {}
end
""")
alive(70)
take()
# (A quiet belt's record, as belt_sim.lua keeps it, its next drift check 1800 ticks off: there only while the drop is
# handled, the packet being handled at once.)
def quiet_drop():
    g.storage.f3d.bs.belts[dz_unit] = lua.table_from({"qw": 1800, "ql": g.game.tick})
    send({"t": "drop", "item": "iron-plate", "x": fixed(43.5), "y": fixed(41.5)})
    rec = g.storage.f3d.bs.belts[dz_unit]
    g.storage.f3d.bs.belts[dz_unit] = None
    return rec.qw, rec.ql


qd = quiet_drop()
alive(3)
zp = z_put_records(take())
check(len(zp) >= 1 and zp[0][3] // 8 == dz_unit and zp[0][3] % 8 == 1 and zp[0][5] == int(g.F.next_item_id)
      and zp[0][6] == iid["iron-plate"] and zp[0][7] == 1 and zp[0][8] == dz_unit,
      f"drop_put: Z onto a belt is told at once as a put with no inserter (lane, place, id): {zp[:1]} (unit {dz_unit})")
check(qd == (None, None), f"drop_put: and its quiet belt's drift checks come every turn again: {qd}")
alive(10)
take()  # (each record goes again in the next messages)
set_perf(drop_put=False)
qd = quiet_drop()
alive(3)
check(not z_put_records(take()) and qd[0] == 1800, f"drop_put off: no put told, the belt left quiet, as before: {qd}")
set_perf()
g.storage.f3d.client.ho = None
alive(10)
take()
send({"t": "drop", "item": "iron-plate", "x": fixed(43.5), "y": fixed(41.5)})
alive(3)
check(not z_put_records(take()), "drop_put: none for a hello without `ho`")
lua.execute("game.surfaces[1].spill_item_stack = F_spill_real")
g.storage.f3d.client.ie = None
alive((30 - (int(g.game.tick) - dz_t0) % 30) % 30)  # (the checks below keep the inventory's 30-tick phase)
take()

# Issue #18: F takes the items on belts within the character's item pickup distance too, as Factorio's "Pick up
# items": all in range a tick, nearest first, each said at once (`pku`: where it was, its lane and unique id), the
# lanes taken from asked for again (J21's way); an underground's tunnel and a belt out of reach keep theirs.
pk_was = to_py(j9_pup.position)
j9_pup.position = lua.table_from({"x": 60, "y": 50})
alive(1)
take()
pk_belt = spawn("transport-belt", 60.5, 50.5, force="player", direction=4)
pk_far = spawn("transport-belt", 63.5, 50.5, force="player", direction=4)
pk_under = spawn("underground-belt", 59.5, 49.5, force="player", direction=4, type="input")
# (The fake's lines run east here: line position p is at x + 0.5 - p, lines 1 and 2 0.234 north and south of
# the middle; an underground's lines 3 and 4 run on into the tunnel, x + 0.5 + p.)
F.put_on_belt(pk_belt, 1, "iron-plate", 0.1, 18001)                       # 0.94 off
F.put_on_belt(pk_belt, 1, "iron-gear-wheel", 0.75, 18002, None, None, 3)  # a stack of 3, 0.37 off: first
F.put_on_belt(pk_belt, 2, "copper-plate", 0.75, 18003)                    # 0.78 off
F.put_on_belt(pk_far, 1, "iron-plate", 0.5, 18004)                        # 3.5 off: out of reach
F.put_on_belt(pk_under, 1, "copper-plate", 0.3, 18005)                    # 0.79 off
F.put_on_belt(pk_under, 3, "iron-plate", 0.1, 18006)                      # under the ground, 0.74 off


def pk_uids(e, line):
    return sorted(int(it.unique_id) for it in e.get_transport_line(line).get_detailed_contents().values())


pk_inv = j9_pup.get_main_inventory()
pk_names = ("iron-plate", "iron-gear-wheel", "copper-plate")
pk_before = {n: int(pk_inv.get_item_count(n)) for n in pk_names}
lua.execute("F_resent = {}")
send({"t": "pickup"})
alive(1)
pk_msgs = take()
pku = of_type(pk_msgs, "pku")
pk_l = pku[0]["l"] if len(pku) == 1 else []
pk_unit = {"b": int(pk_belt.unit_number) * 8, "u": int(pk_under.unit_number) * 8}
check([r[5] for r in pk_l] == [18002, 18003, 18005, 18001]
      and [r[4] for r in pk_l] == [pk_unit["b"] + 1, pk_unit["b"] + 2, pk_unit["u"] + 1, pk_unit["b"] + 1]
      and [r[0] for r in pk_l] == ["iron-gear-wheel", "copper-plate", "copper-plate", "iron-plate"]
      and [r[1] for r in pk_l] == [3, 1, 1, 1] and all(r[6] == 0 and r[7] == iid[r[0]] for r in pk_l),
      f"issue #18: F takes every belt item in reach in one tick, nearest first, said at once by lane and id (pku): {pk_l}")
check(pk_l and pk_l[0][2:4] == [fixed(60.25), fixed(50.5 - 0.234)] and pk_l[2][2:4] == [fixed(59.7), fixed(49.5 - 0.234)]
      and pku[0]["k"] == int(g.game.tick),
      f"issue #18: each where the game had it that tick (get_line_item_position), on the tick taken: {[r[2:4] for r in pk_l]}")
check(pk_uids(pk_belt, 1) == [] and pk_uids(pk_belt, 2) == [] and pk_uids(pk_under, 1) == []
      and pk_uids(pk_under, 3) == [18006] and pk_uids(pk_far, 1) == [18004],
      "issue #18: they are off their lanes; an underground's tunnel and a belt out of reach keep theirs")
check([int(pk_inv.get_item_count(n)) - pk_before[n] for n in pk_names] == [1, 3, 2],
      "issue #18: and in the inventory, a stack as its count")
pk_resent = sorted(int(v) for v in g.F_resent.values())
check(pk_resent == sorted([pk_unit["b"] + 1, pk_unit["b"] + 2] + [pk_unit["u"] + i for i in range(1, 5)]),
      f"issue #18: the belts taken from have their lanes asked for again (read in the next belt update): {pk_resent}")
alive(1)  # (the reliable outbox goes out at the start of the next tick)
pk_msgs += take()
check(of_type(pk_msgs, "inv") and of_type(pk_msgs, "slots"), "issue #18: the inventory and slots are sent at once")
# A stack the inventory takes part of: the rest stays on the belt, said (left); then full, said once.
alive(40)
take()
F.inventory_space = 2
F.put_on_belt(pk_belt, 1, "iron-gear-wheel", 0.75, 18010, None, None, 3)
for _ in range(3):
    send({"t": "pickup"})
    alive(9)
pk_msgs = take()
pk_l = [r for m in of_type(pk_msgs, "pku") for r in m["l"]]
pk_left = [it for it in pk_belt.get_transport_line(1).get_detailed_contents().values()]
check(pk_l == [["iron-gear-wheel", 2, fixed(60.25), fixed(50.5 - 0.234), pk_unit["b"] + 1, 18010, 1, iid["iron-gear-wheel"]]]
      and len(pk_left) == 1 and int(pk_left[0].stack.count) == 1
      and len([m for m in of_type(pk_msgs, "msg") if m["text"] == "Inventory full"]) == 1,
      f"issue #18: with room for two of a stack of three, two come off (left 1), then full, said once: {pk_l}")
F.inventory_space = float("inf")
alive(40)
send({"t": "pickup"})
alive(1)
take()
# A game whose belt stack reference doesn't take the item (F.belt_stack_writes false): the lane gives one up by name,
# and what is said is the item the lane gave up, not the one aimed at; nothing is made.
F.belt_stack_writes = False
F.put_on_belt(pk_belt, 1, "iron-plate", 0.75, 18020)  # the nearest
F.put_on_belt(pk_belt, 1, "iron-plate", 0.1, 18021)   # (the fake's lane gives up its last one by name)
plates0 = int(pk_inv.get_item_count("iron-plate"))
send({"t": "pickup"})
alive(1)
pk_l = [r for m in of_type(take(), "pku") for r in m["l"]]
check(pk_l and pk_l[0][5] == 18021 and pk_l[0][2] == fixed(60.9) and pk_uids(pk_belt, 1) == [18020]
      and int(pk_inv.get_item_count("iron-plate")) == plates0 + 1,
      f"issue #18: a reference that takes nothing: the lane's own name removal, said as the item it took, one plate got: {pk_l}")
alive(1)
check(pk_uids(pk_belt, 1) == [] and int(pk_inv.get_item_count("iron-plate")) == plates0 + 2,
      "issue #18: and the next tick the other, no more plates than came off")
F.belt_stack_writes = None
alive(40)
take()
# belt_pickup off: the ground only, as before.
set_perf(belt_pickup=False)
F.put_on_belt(pk_belt, 2, "copper-plate", 0.75, 18030)
pk_ground = spawn("item-on-ground", 60.3, 49.8, stack={"name": "wood", "count": 1})
for _ in range(2):
    send({"t": "pickup"})
    alive(9)
pk_msgs = take()
check(not pk_ground.valid and pk_uids(pk_belt, 2) == [18030] and not of_type(pk_msgs, "pku"),
      "belt_pickup off: F takes the ground's items, not the belt's, and says nothing (as before)")
set_perf()
alive(40)
send({"t": "pickup"})
alive(1)
pk_l = [r for m in of_type(take(), "pku") for r in m["l"]]
check(pk_l and pk_l[0][5] == 18030 and pk_uids(pk_belt, 2) == [], f"belt_pickup back on: the belt's item comes off: {pk_l}")
alive(40)
take()
# pickup_stop (the owner: F picked on for almost a second after it was let go): F let go ends the pickup at once;
# an old client that never sends it keeps picking until HOLD_TICKS (30) after its last `pickup`; switched off, ignored.
send({"t": "pickup"})
alive(1)
take()
send({"t": "pickup_stop"})
alive(1)
F.put_on_belt(pk_belt, 2, "copper-plate", 0.75, 18040)
ps_ground = spawn("item-on-ground", 60.3, 49.8, stack={"name": "wood", "count": 1})
alive(40)
ps_msgs = take()
check(pk_uids(pk_belt, 2) == [18040] and ps_ground.valid and not of_type(ps_msgs, "pku"),
      "pickup_stop: after F is let go nothing more is picked, off a belt or the ground")
send({"t": "pickup"})
alive(10)
ps_l = [r for m in of_type(take(), "pku") for r in m["l"]]
check(ps_l and pk_uids(pk_belt, 2) == [] and not ps_ground.valid,
      f"pickup_stop: held again, both picked: {ps_l}")
F.put_on_belt(pk_belt, 2, "copper-plate", 0.75, 18041)
alive(10)
check(pk_uids(pk_belt, 2) == [], "pickup_stop: an old client (no stop) still picks 20 ticks after its last pickup")
alive(20)
F.put_on_belt(pk_belt, 2, "copper-plate", 0.75, 18042)
alive(5)
check(pk_uids(pk_belt, 2) == [18042], "pickup_stop: and stops once HOLD_TICKS have passed, as before")
send({"t": "pickup"})
alive(1)
take()
set_perf(pickup_stop=False)
send({"t": "pickup"})
alive(1)
send({"t": "pickup_stop"})
alive(1)
F.put_on_belt(pk_belt, 2, "copper-plate", 0.75, 18043)
alive(5)
check(pk_uids(pk_belt, 2) == [], "pickup_stop off: the stop ignored, picking on until HOLD_TICKS, as before")
set_perf()
alive(40)
take()
# pickup_stop, the owner's case measured (belts-pickup-test): the client's own cadence (a `pickup` every 9 ticks
# while F is held, `pickup_stop` on release), the packets a tick or two late, a belt fed an item every tick under the
# character; what the game picks after F is let go, an old client (no stop) against a new one.
PS_UID = [18100]


def ps_run(stop, delay, release, ticks=60):
    """Holds F from client tick 0 to `release`; returns [(ticks after release, items)] for each pku after it."""
    due = {}
    for t in range(0, release, 9):
        due.setdefault(t + delay, []).append({"t": "pickup"})
    if stop:
        due.setdefault(release + delay, []).append({"t": "pickup_stop"})
    after = []
    for t in range(ticks):
        for m in due.get(t, []):
            send(m)
        PS_UID[0] += 1
        F.put_on_belt(pk_belt, 2, "copper-plate", 0.75, PS_UID[0])
        alive(1)
        for m in of_type(take(), "pku"):
            if t >= release:
                after.append((t - release, len(m["l"])))
    return after


ps_res = {}
for ps_delay in (1, 2):
    for ps_rel in (27, 31, 35):  # let go right after a repeat, between two, just before the next
        for ps_stop in (False, True):
            ps_res[(ps_delay, ps_rel, ps_stop)] = ps_run(ps_stop, ps_delay, ps_rel)
            alive(40)
            take()
for k, v in sorted(ps_res.items()):
    print(f"  pickup_stop measured: delay {k[0]}, let go at {k[1]}, stop {k[2]}: last pick "
          f"+{max([a for a, _ in v], default=-1)} ticks, {sum(n for _, n in v)} items after F was let go")
check(all(max([a for a, _ in v], default=-1) <= k[0] for k, v in ps_res.items() if k[2]),
      "pickup_stop measured: with the stop, nothing is picked later than the packet's own delay after F is let go")
check(all(sum(n for _, n in v) <= k[0] for k, v in ps_res.items() if k[2]),
      "pickup_stop measured: with the stop, at most an item a tick of the packet's delay after F is let go")
check(all(max([a for a, _ in v], default=-1) >= 20 for k, v in ps_res.items() if not k[2]),
      "pickup_stop measured: an old client (no stop) picks on 20 ticks and more (as before, for old clients)")
# The inventory of a pick just before the stop still reaches the client (a pick's report waits PICK_REPORT_TICKS).
send({"t": "pickup"})
alive(1)
take()
F.put_on_belt(pk_belt, 2, "copper-plate", 0.75, 18190)
alive(1)
take()
F.put_on_belt(pk_belt, 2, "copper-plate", 0.75, 18191)
alive(1)
ps_m = take()
send({"t": "pickup_stop"})
alive(8)
ps_m += take()
check(of_type(ps_m, "pku") and pk_uids(pk_belt, 2) == [], "pickup_stop: the item picked the tick before the stop is said")
check([m for m in ps_m if m.get("t") in ("inv", "slots")],
      f"pickup_stop: its inventory still sent soon after the stop: {[m.get('t') for m in ps_m]}")
alive(40)
take()
# A stop with no pickup going: quietly nothing.
send({"t": "pickup_stop"})
alive(2)
check(g.storage.f3d.pickup is None and not of_type(take(), "msg"), "pickup_stop with no pickup going: quietly nothing")
# F held with the inventory full: said once; let go and pressed again, once more.
F.inventory_space = 0
for _ in range(3):
    PS_UID[0] += 1
    F.put_on_belt(pk_belt, 2, "copper-plate", 0.75, PS_UID[0])
    send({"t": "pickup"})
    alive(9)
ps_full = [m for m in of_type(take(), "msg") if m["text"] == "Inventory full"]
check(len(ps_full) == 1, f"pickup_stop: F held with the inventory full says so once: {len(ps_full)}")
send({"t": "pickup_stop"})
alive(2)
send({"t": "pickup"})
alive(9)
ps_full = [m for m in of_type(take(), "msg") if m["text"] == "Inventory full"]
check(len(ps_full) == 1, f"pickup_stop: pressed again, said once more: {len(ps_full)}")
send({"t": "pickup_stop"})
F.inventory_space = float("inf")
alive(40)
take()
# Mining held at the same time: the stop leaves the mining alone.
ps_tree = spawn("tree-01", 61.5, 51.5)
send({"t": "mine", "u": 0, "p": eid["tree-01"], "x": fixed(61.5), "y": fixed(51.5)})
send({"t": "pickup"})
alive(1)
ps_mining = g.storage.f3d.mining
send({"t": "pickup_stop"})
send({"t": "mine", "u": 0, "p": eid["tree-01"], "x": fixed(61.5), "y": fixed(51.5)})
alive(1)
check(ps_mining is not None and g.storage.f3d.mining is not None and g.storage.f3d.pickup is None,
      f"pickup_stop: mining held at the same time goes on, the pickup ends ({ps_mining is not None})")
send({"t": "mine_stop"})
alive(2)
if ps_tree.valid:
    ps_tree.destroy()
take()
# Two clients: one's stop leaves the other's pickup going (storage.f3d is swapped per client).
ps_mp = F.multiplayer
F.multiplayer = True  # (in single-player a hello from another port takes the one client's place)
send(hello_now)  # (A heard just now, so B's hello is a second client, not A's restart)
alive(1)
send({"t": "hello", "v": 1, "sid": "ps-b", "w": 0}, port=PORT_B)
alive(3)
take_by_port()
send({"t": "pickup"})
send({"t": "pickup"}, port=PORT_B)
alive(1)
ps_b = g.storage.f3d_extra[PORT_B]
ps_ok = g.storage.f3d.pickup is not None and ps_b.pickup is not None
send({"t": "pickup_stop"}, port=PORT_B)
alive(1)
check(ps_ok and g.storage.f3d.pickup is not None and ps_b.pickup is None,
      "pickup_stop, two clients: B's stop ends B's pickup, A's goes on")
send({"t": "pickup"}, port=PORT_B)
alive(1)
send({"t": "pickup_stop"})
alive(1)
check(g.storage.f3d.pickup is None and ps_b.pickup is not None, "pickup_stop, two clients: A's stop leaves B's going")
send({"t": "pickup_stop"}, port=PORT_B)
send({"t": "bye"}, port=PORT_B)
alive(3)
take_by_port()
F.multiplayer = ps_mp
alive(40)
take()
for e in (pk_belt, pk_far, pk_under):
    e.destroy()
j9_pup.position = lua.table_from({"x": pk_was["x"], "y": pk_was["y"]})
lua.execute('package.loaded["scripts.belt_sim"].resend = F_resend_real')
j9_put.destroy()
j9_pup.position = lua.table_from({"x": j9_was["x"], "y": j9_was["y"]})
send({"t": "focus", "x": fixed(j9_focus["x"]), "y": fixed(j9_focus["y"]), "r": int(j9_focus["r"])})
while (int(g.game.tick) - j9_start) % 1200:  # the checks after keep the tick phase they were written at
    alive(1)
take()

# 9. Moving things from one search: cargo pods, rolling stock and enemy units from the movers' search, not a
# search each of the same square; worms every 300 ticks.
say(b=1)
send({"t": "focus", "x": fixed(20), "y": fixed(20), "r": 64})
alive(2)
take()
os_wall = spawn("stone-wall", 30.5, 26.5, force="player")
os_biter = spawn("small-biter", 31.2, 26.5, force="enemy")
os_biter.commandable.distraction_command = lua.table_from({"type": g.defines.command.attack, "target": os_wall})
os_pod = spawn("cargo-pod", 24.0, 22.0, force="player")
os_loco = spawn("locomotive", 34.0, 30.0, force="player")


def one_search_round():
    F.finds = lua.table_from({})
    got = {"cp": False, "tr": False, "en": False}
    for _ in range(130):
        alive(1)
        for m in take():
            if m.get("t") == "cp" and any(r[0] == os_pod.unit_number for r in m["l"]):
                got["cp"] = True
            if m.get("t") == "tr" and any(os_loco.unit_number in r[6] for r in m["l"]):
                got["tr"] = True
            if m.get("t") == "en" and os_biter.unit_number in m["l"][0::3]:
                got["en"] = True
    finds = to_py(F.finds) or {}
    F.finds = None
    return got, finds


got_on, finds_on = one_search_round()
set_perf(one_search=False)
got_off, finds_off = one_search_round()
set_perf()
own = ("cargo-pod", "locomotive,cargo-wagon", "unit,turret", "spider-unit,spider-vehicle")  # (the types the fake has)
check(all(got_on.values()) and all(got_off.values()),
      f"one_search: cargo pods, trains and attacking enemies are sent either way: {got_on} / {got_off}")
check(not any(finds_on.get(k) for k in own) and finds_on.get("turret", 0) <= 1 and all(finds_off.get(k) for k in own),
      f"one_search: no search of their own for pods, trains and units (worms every 300 ticks): {finds_on} / off {finds_off}")
for e in (os_wall, os_biter, os_pod, os_loco):
    e.destroy()

# 12. The two-call lane check (/f3d-bs two_call, off by default): count and front as the record has them,
# unchanged; a front that moved is seen at once; the back moving alone is seen at the full check, every 4th.
tc_belt = spawn("transport-belt", 90.5, 90.5, force="player", direction=4)
F.put_on_belt(tc_belt, 1, "iron-plate", 0.25, 9401)
F.put_on_belt(tc_belt, 1, "iron-plate", 0.75, 9402)
tc_line = tc_belt.get_transport_line(1)
tc_rec = lua.table_from([2, fixed(0.25), fixed(0.75), 2])
two_call = bs_mod.two_call_line
tc_rec[15] = 0
seen = [list(two_call(tc_line, tc_rec))]
F.move_on_belt(tc_belt, 1, 9402, 0.625)
seen += [list(two_call(tc_line, tc_rec)) for _ in range(3)]
F.move_on_belt(tc_belt, 1, 9401, 0.125)
seen += [list(two_call(tc_line, tc_rec))]
check(seen[0] == [2, 64, 192, 2] and seen[1] == [2, 64, 192, 2] and seen[2] == [2, 64, 192, 2] and seen[3] == [2, 64, 160, 2]
      and seen[4] == [2, 32, 160, 2],
      f"two_call: unchanged by count and front, the back alone seen at every 4th check, a front that moved at once: {seen}")
tc_belt.destroy()

# 8. Far belts checked in turn (/f3d-bs far_tier, off by default): within far_ring every update, beyond it a
# cursor over the far actors and watched belts, far_units an update; a far inserter that acts still gets its
# belt read, a few updates later.
fx0, fy0 = -60.5, 60.5
ft_belts = [spawn("transport-belt", fx0 + k, fy0, force="player", direction=4) for k in range(12)]
for k in range(11):
    F.link_belts(ft_belts[k], ft_belts[k + 1])
ft_ins = [spawn("inserter", fx0 + k, fy0 + 1, force="player") for k in range(12)]
for k in range(12):
    ft_ins[k].pickup_target = ft_belts[k]
for k in range(12):
    F.put_on_belt(ft_belts[k], 1, "iron-plate", 0.5, 9500 + k)
say(z=1, bl=1, bs=1)
send({"t": "focus", "x": fixed(fx0), "y": fixed(fy0), "r": 64})
send({"t": "bfar", "r": 0, "n": 16, "m": 0})
g.storage.f3d_bs = lua.table_from({"far_tier": True, "far_ring": 4, "far_units": 8})
alive(60)
take()
far_before = int(bs_mod.counts.far_checks or 0)
ft = g.storage.f3d.bs.ft
far_units_list = set(to_py(ft.units)) if ft else set()
check(ft is not None and int(ft_belts[10].unit_number) in far_units_list and int(ft_ins[10].unit_number) in far_units_list
      and int(ft_belts[1].unit_number) not in far_units_list and int(ft_belts[1].unit_number) in set(to_py(ft.near_w)),
      f"far_tier: watched belts and inserters past far_ring go in the far list, nearer ones stay near: {sorted(far_units_list)}")
# The far inserter takes the plate: its belt is read within a few updates (12 actors and belts, a few a time).
F.move_on_belt(ft_belts[10], 1, 9510, None)
F.set_hand(ft_ins[10], fx0 + 10, fy0 + 0.5, "iron-plate")
key10 = int(ft_belts[10].unit_number) * 8 + 1
read_at = None
for upd in range(1, 21):
    alive(6)
    if key10 in bs_of(take())["sl"]:
        read_at = upd
        break
far_after = int(bs_mod.counts.far_checks or 0)
check(read_at is not None and read_at > 1 and far_after > far_before,
      f"far_tier: a far inserter's take is read after a few updates, not at once: update {read_at}, {far_after - far_before} far checks")
# Zero-alloc far_split keeps deterministic ascending unit-number order when two actors share a far belt,
# skips downstream tail catch-up on far belts while keeping near tails, skips far bre read_runs, and orders
# asked bre groups nearest-first.
ft_ins_tie = spawn("inserter", fx0 + 10, fy0 - 1, force="player")
ft_ins_tie.pickup_target = ft_belts[10]
F.set_hand(ft_ins[10], fx0 + 10, fy0 + 0.5, None)
F.set_hand(ft_ins[1], fx0 + 1, fy0 + 0.5, None)
for b_i, base_id in [(0, 9600), (1, 9610), (2, 9620), (9, 9630), (10, 9640), (11, 9650)]:
    F.move_on_belt(ft_belts[b_i], 1, 9500 + b_i, None)
    for s_idx, pos in enumerate((0.1, 0.35, 0.6, 0.85)):
        F.put_on_belt(ft_belts[b_i], 1, "iron-plate", pos, base_id + s_idx)
g.storage.f3d_bs = lua.table_from({"far_tier": True, "far_ring": 4, "far_units": 200})
bs_mod.reset()
alive(60)
take()
ft2 = g.storage.f3d.bs.ft
ft_u = list(to_py(ft2.units)) if ft2 else []
ft_k = list(to_py(ft2.kinds)) if ft2 else []
u10, u_ins10, u_tie = int(ft_belts[10].unit_number), int(ft_ins[10].unit_number), int(ft_ins_tie.unit_number)
p_lo, p_hi, p_b10 = ft_u.index(min(u_ins10, u_tie)), ft_u.index(max(u_ins10, u_tie)), ft_u.index(u10)
check(p_lo < p_hi < p_b10 and ft_k[p_lo] == 7 and ft_k[p_hi] == 7 and ft_k[p_b10] == 3,
      f"far_split tie-break puts both actors ascending before their far belt: {(p_lo, p_hi, p_b10)}")
tail_0 = int(bs_mod.counts.r_tail or 0)
F.move_on_belt(ft_belts[10], 1, 9640, None)
F.set_hand(ft_ins[10], fx0 + 10, fy0 + 0.5, "iron-plate")
alive(6)
take()
tail_far = int(bs_mod.counts.r_tail or 0)
F.move_on_belt(ft_belts[1], 1, 9610, None)
F.set_hand(ft_ins[1], fx0 + 1, fy0 + 0.5, "iron-plate")
alive(6)
take()
tail_near = int(bs_mod.counts.r_tail or 0)
check(tail_far == tail_0 and tail_near > tail_0,
      f"far_tier skips far tail catch-up ({tail_0} -> {tail_far}) while near belts still catch up (-> {tail_near})")
key1 = int(ft_belts[1].unit_number) * 8 + 1
r_run0 = int(bs_mod.counts.r_run or 0)
send({"t": "bre", "l": [key10]})
alive(6)
take()
r_run_far = int(bs_mod.counts.r_run or 0)
send({"t": "bre", "l": [key1]})
alive(6)
take()
r_run_near = int(bs_mod.counts.r_run or 0)
check(r_run_far == r_run0 and r_run_near > r_run0,
      f"far bre skips read_runs ({r_run0} -> {r_run_far}) while near bre runs read_runs (-> {r_run_near})")
while g.storage.f3d.bs.round is not None:
    alive(1)
take()
send({"t": "bre", "l": [key10, key1]})
alive(1)
q_groups = []
rnd = g.storage.f3d.bs.round
if rnd:
    for seg in to_py(rnd.q):
        if seg[0] == 2:
            q_groups = seg[1]
            break
check(len(q_groups) >= 2 and key1 in q_groups[0] and key10 in q_groups[1],
      f"bre groups ordered nearest-first by scan index despite far sent first: {q_groups}")
alive(6)
take()
ft_ins_tie.destroy()
g.storage.f3d_bs = None
for e in ft_belts + ft_ins:
    e.destroy()
say(b=1)
alive(6)
take()

# 13. Decoratives by distance: a client that says how far it draws them (hello dd) gets a chunk's `dec` only
# within dd + 64 tiles of its square's middle; the others once the middle brings them inside.
F.add_decorative(F.surface, "small-rock", 100, 100, 2)
rows7 = [[cy, -3, 7] for cy in range(-3, 4)]
send({"t": "sub", "c": [[0, 0]]})
alive(10)
say(b=1, dc=1, dd=32)
send({"t": "sub", "o": [0, 0], "r": 3, "w": rows7})
alive(120)
dec_first = {(m["cx"], m["cy"]) for m in of_type(take(), "dec")}
check((0, 0) in dec_first and (3, 0) in dec_first and (3, 3) not in dec_first and (-3, -3) not in dec_first,
      f"dec_distance: decoratives only for chunks within dd + 64 tiles of the square's middle: {sorted(dec_first)}")
send({"t": "sub", "o": [2, 2], "r": 3, "w": [[cy, -1, 7] for cy in range(-1, 6)]})
alive(60)
dec_moved = [m for m in of_type(take(), "dec") if (m["cx"], m["cy"]) == (3, 3)]
check(dec_moved and dec_moved[-1]["l"] == [did.get("small-rock"), 4, 4, 2],
      f"dec_distance: a chunk held back gets its decoratives once the middle brings it inside: {dec_moved}")
say(b=1, dc=1)
send({"t": "sub", "o": [0, 0], "r": 3, "w": rows7})
alive(10)
send({"t": "resync", "c": [[-3, -3]]})
alive(60)
check([m for m in of_type(take(), "dec") if (m["cx"], m["cy"]) == (-3, -3)],
      "dec_distance: without dd every chunk's decoratives, as before")
say(b=1)
alive(6)
take()

# 11. Minimap charts sent only when they changed: each chart carries its stamp (st); asked again with the
# stamps the client holds (map h), an unchanged chunk is answered `same` with its live parts, a changed one
# with its picture.
F.charted["0,0"] = True
F.charted["1,0"] = True


def charts_for(h=None):
    msg = {"t": "map", "cx1": 0, "cy1": 0, "cx2": 1, "cy2": 0, "res": 4}
    if h is not None:
        msg["h"] = h
    send(msg)
    alive(12)
    return {(m["cx"], m["cy"]): m for m in of_type(take(), "chart")}


first = charts_for()
stamps = [[cx, cy, m["st"]] for (cx, cy), m in first.items() if "st" in m]
check(len(stamps) == 2 and all(m["n"] == 8 for m in first.values()), f"chart_same: each chart carries its stamp: {stamps}")
same = charts_for(stamps)
check(all("same" in m and "px" not in m for m in same.values()) and len(same) == 2,
      f"chart_same: asked with the stamps it holds, unchanged chunks come back as same: {[sorted(m) for m in same.values()]}")
# (Multiplayer: whether it is `same` comes from storage, not the module-local picture cache, which a peer that
# loaded since hasn't got: without it the chunk is read again and still answered `same`.)
check(forget(g.package.loaded["scripts.map"].tick, "chart_cache"), "the chart cache can be forgotten")
same_fresh = charts_for(stamps)
check(all("same" in m for m in same_fresh.values()) and len(same_fresh) == 2,
      f"chart_same: the answer doesn't depend on the module-local cache: {[sorted(m) for m in same_fresh.values()]}")
changed = spawn("stone-wall", 40.5, 8.5, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": changed}))
alive(1)
take()
again = charts_for(stamps)
check("same" in again.get((0, 0), {}) and "px" in again.get((1, 0), {}) and again[(1, 0)].get("st") not in (None, stamps[0][2], stamps[1][2]),
      f"chart_same: a chunk built in since comes with its new picture and stamp: {[(k, sorted(m)) for k, m in again.items()]}")
set_perf(chart_same=False)
off = charts_for(stamps)
set_perf()
check(all("px" in m and "st" not in m for m in off.values()), "chart_same off: the pictures every time, as before")
changed.destroy()

# A Zenith that quits without a goodbye (a crash, killed) and starts again before the bridge's 10 s
# timeout comes back with a new session id, often from another port: it got a second character at
# the spawn. Now it takes the silent client's place and character, where it stood.
PORT_C = PORT_B + 2
was_mp = F.multiplayer
F.multiplayer = True


def keep_first_alive(n):
    """n ticks with the first client saying hello every second, as a live Zenith does."""
    for _ in range(n // 60):
        send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
        tick(60)
    send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
    tick(n % 60)


send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
send({"t": "hello", "v": 1, "sid": "b", "w": 0}, port=PORT_B)
tick(3)
b_char = g.storage.f3d_extra[PORT_B].puppet
b_was = {"x": b_char.position.x, "y": b_char.position.y}
b_char.teleport(lua.table_from({"x": 40.5, "y": -12.5}))
keep_first_alive(120)  # b silent for 2 s: maybe a hitch
take_by_port()
send({"t": "hello", "v": 1, "sid": "b-again", "w": 0}, port=PORT_C)
tick(3)
by = take_by_port()
check(not of_type(by.get(PORT_C, []), "welcome") and g.storage.f3d_extra[PORT_C] is None and g.storage.f3d_extra[PORT_B] is not None,
      f"restart: a new port's hello waits while a client is silent 2 s (neither heard lately nor gone): {sorted(by)}")
keep_first_alive(150)  # b silent past 4 s: gone
send({"t": "hello", "v": 1, "sid": "b-again", "w": 0}, port=PORT_C)
tick(3)
by = take_by_port()
welcome_c = of_type(by.get(PORT_C, []), "welcome")
check(welcome_c and welcome_c[0]["u"] == b_char.unit_number and welcome_c[0]["x"] == fixed(40.5) and welcome_c[0]["y"] == fixed(-12.5)
      and g.storage.f3d_extra[PORT_B] is None and g.storage.f3d_extra[PORT_C] is not None
      and g.storage.f3d_extra[PORT_C].client.sid == "b-again" and g.storage.f3d.client.port == CLIENT_PORT,
      f"restart: a second client's Zenith back on another port gets its own character where it stood, not a new one at the spawn: {welcome_c[:1]}")
send({"t": "bye"}, port=PORT_C)
tick(1)
b_char.teleport(lua.table_from(b_was))
# The first client: its Zenith restarts on another port while the save's character waits for it.
a_char = g.storage.f3d.puppet
a_was = {"x": a_char.position.x, "y": a_char.position.y}
a_char.teleport(lua.table_from({"x": -126.5, "y": -18.5}))
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(250)
take_by_port()
send({"t": "hello", "v": 1, "sid": "s1-again", "w": 0}, port=PORT_C)
tick(3)
by = take_by_port()
welcome_c = of_type(by.get(PORT_C, []), "welcome")
check(welcome_c and welcome_c[0]["u"] == a_char.unit_number and welcome_c[0]["x"] == fixed(-126.5) and welcome_c[0]["y"] == fixed(-18.5)
      and g.storage.f3d.client.port == PORT_C and len(g.storage.f3d_extra) == 0,
      f"restart: the first client's Zenith back on another port takes its place and character, where it stood: {welcome_c[:1]}")
# A client heard within the last second is alive: the new port is another Zenith, with a character of its own.
send({"t": "hello", "v": 1, "sid": "s1-again", "w": 1}, port=PORT_C)
tick(30)
send({"t": "hello", "v": 1, "sid": "d", "w": 0}, port=PORT_B)
tick(3)
by = take_by_port()
welcome_d = of_type(by.get(PORT_B, []), "welcome")
check(welcome_d and welcome_d[0]["u"] != a_char.unit_number and g.storage.f3d.client.port == PORT_C and g.storage.f3d_extra[PORT_B] is not None,
      f"restart: a new port beside a live client is a second client, as before: {welcome_d[:1]}")
send({"t": "bye"}, port=PORT_B)
send({"t": "bye"}, port=PORT_C)
tick(1)
# The debug menu's speed: at 4x a live Zenith's hellos are 240 ticks apart, so 300 ticks silent is still alive.
g.game.speed = 4
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(300)
take_by_port()
send({"t": "hello", "v": 1, "sid": "e", "w": 0}, port=PORT_B)
tick(3)
by = take_by_port()
check(of_type(by.get(PORT_B, []), "welcome") and g.storage.f3d.client.port == CLIENT_PORT and g.storage.f3d_extra[PORT_B] is not None,
      "restart: at 4x speed a client silent 300 ticks (1.25 s) is alive, and the new port a second client")
send({"t": "bye"}, port=PORT_B)
g.game.speed = 1
tick(1)
a_char.teleport(lua.table_from(a_was))
take_by_port()
send(hello_now)
F.multiplayer = was_mp
tick(1)

# --- target_spots (/f3d-bs, on): a drill's or inserter's belt found by its spot -------------------------------
# In 2.1 a drill has no drop_target until it first puts something out, and a replaced target is a dead entity
# until then; belt_sim.lua reads a chunk's targets once and keeps them (bs.bt). So a drill placed before its belt,
# or a belt replaced under a running drill, left the belt unwatched for good: its items reached the client only
# through drift checks and asks. Last, as its ticks would shift the periodic jobs' phases for the checks above.
def drain():
    """What was sent, without take()'s numbering checks: the restart checks above leave a second client's
    reliable messages to this port."""
    out = []
    for item in F.take_sent().values():
        out += protocol.split_datagram(sent_data(item))
    return out


bs_t = lua.eval('package.loaded["scripts.belt_sim"]')
check("target_spots on" in str(bs_t.option_command("")[1]), "/f3d-bs lists target_spots (on)")
watched_of = lua.eval("function(u) local b = storage.f3d.bs; local r = b and b.belts[u]; return (r and r[4]) and true or false end")
actor_of = lua.eval("function(u) local b = storage.f3d.bs; return (b and b.actors[u] ~= nil) and true or false end")
retry_of = lua.eval("function(u) local b = storage.f3d.bs; return (b and b.retry and b.retry[u] ~= nil) and true or false end")
tx, ty = 1500.5, 330.5
tick(2)
drain()
send({"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1})
send({"t": "focus", "x": fixed(tx), "y": fixed(ty + 10), "r": 48})
send({"t": "bfar", "r": 0, "n": 24, "m": 0})
tick(30)
drain()


ts_hello = {"t": "hello", "v": 1, "sid": "s1", "w": 1, "z": 1, "bl": 1, "bs": 1}


def keep(n):
    """n ticks, the client saying hello every 100 (it would time out)."""
    for _ in range(n):
        if g.game.tick % 100 == 0:
            send(ts_hello)
        tick(1)


def drill_then_belt(y, wait=180, raise_belt=True):
    """A drill (no drop_target, as the game has it) dropping on the tile at (tx, y), its belt (two tiles) laid
    `wait` ticks later. Returns (drill, first belt, second belt)."""
    d = spawn("burner-mining-drill", tx - 1.5, y + 0.5, force="player")
    d.drop_position = lua.table_from({"x": tx - 0.2, "y": y - 0.2})
    F["raise"]("script_raised_built", lua.table_from({"entity": d}))
    keep(wait)
    b1 = spawn("transport-belt", tx, y, force="player", direction=4)
    b2 = spawn("transport-belt", tx + 1, y, force="player", direction=4)
    F.link_belts(b1, b2)
    if raise_belt:
        F["raise"]("script_raised_built", lua.table_from({"entity": b1}))
        F["raise"]("script_raised_built", lua.table_from({"entity": b2}))
    return d, b1, b2


# Off: as before, the drill's belt isn't watched and the drill is no actor.
bs_t.option_command("target_spots off")
d_off, b_off, _ = drill_then_belt(ty)
tick(30)
drain()
check(not watched_of(int(b_off.unit_number)) and not actor_of(int(d_off.unit_number)),
      "target_spots off: a drill placed before its belt (no drop_target yet) leaves the belt unwatched, as before")
bs_t.option_command("target_spots default")
# On: a drill placed, its belt laid 3 s later: the belt on its drop spot is its input spot.
d_on, b_on, b_on2 = drill_then_belt(ty + 4)
tick(30)
on_msgs = bs_of(drain())
check(watched_of(int(b_on.unit_number)) and actor_of(int(d_on.unit_number)) and not watched_of(int(b_on2.unit_number)),
      f"target_spots: a drill placed before its belt (no drop_target yet) has the belt on its drop spot watched: "
      f"{watched_of(int(b_on.unit_number))} {actor_of(int(d_on.unit_number))}")
# Its progress going round wakes the belt, whose new item goes in `sl` on that update.
d_on.mining_progress = 0.5
tick(12)
drain()
d_on.mining_progress = 0.1
F.put_on_belt(b_on, 1, "iron-ore", 0.5, 8601)
tick(12)
woke = bs_of(drain())
check(8601 in [it[0] for it in woke["sl"].get(int(b_on.unit_number) * 8 + 1, (None, []))[1]],
      f"target_spots: the drill's output on its belt is sent at once: {woke['sl'].get(int(b_on.unit_number) * 8 + 1)}")
# drill_tails (on): a drill whose item ran off its drop belt before the drill's check showed it had put out: the belt
# its drop belt feeds is read too (off, as before: only the drop belt, where the item no longer is).
tails_got = {}
for flag, uid in (("off", 8603), ("default", 8602)):
    bs_t.option_command("drill_tails " + flag)
    d_on.mining_progress = 0.6
    keep(12)
    drain()
    d_on.mining_progress = 0.2
    F.put_on_belt(b_on2, 1, "iron-ore", 0.3, uid)
    keep(12)
    got_t = bs_of(drain())
    tails_got[flag] = uid in [it[0] for it in got_t["sl"].get(int(b_on2.unit_number) * 8 + 1, (None, []))[1]]
check(tails_got == {"off": False, "default": True},
      f"drill_tails: a drill's item already past its drop belt at the drill's check is read on the next belt (off: not): {tails_got}")
# A belt replaced under a running drill: the game's drop_target is the old belt, dead until the drill puts again.
d_run = spawn("burner-mining-drill", tx - 1.5, ty + 8.5, force="player")
d_run.drop_position = lua.table_from({"x": tx - 0.2, "y": ty + 7.8})
r1 = spawn("transport-belt", tx, ty + 8, force="player", direction=4)
r2 = spawn("transport-belt", tx + 1, ty + 8, force="player", direction=4)
F.link_belts(r1, r2)
d_run.drop_target = r1
for e in (d_run, r1, r2):
    F["raise"]("script_raised_built", lua.table_from({"entity": e}))
tick(30)
drain()
check(watched_of(int(r1.unit_number)) and actor_of(int(d_run.unit_number)), "target_spots: a running drill's belt is watched")
F["raise"]("script_raised_destroy", lua.table_from({"entity": r1}))
r1.destroy()
r1b = spawn("transport-belt", tx, ty + 8, force="player", direction=4)
F.link_belts(r1b, r2)
F["raise"]("script_raised_built", lua.table_from({"entity": r1b}))
tick(30)
drain()
check(watched_of(int(r1b.unit_number)) and actor_of(int(d_run.unit_number)),
      f"target_spots: a belt replaced under a running drill (its drop_target the dead belt) is watched: {watched_of(int(r1b.unit_number))}")
# A drill with nothing on its drop spot is looked at again; a belt laid there without an event is found.
d_late, b_late, _ = drill_then_belt(ty + 12, wait=30, raise_belt=False)
check(retry_of(int(d_late.unit_number)), "target_spots: a drill with no target and no belt on its spot is listed to look at again")
keep(1300)
drain()
check(watched_of(int(b_late.unit_number)) and actor_of(int(d_late.unit_number)) and not retry_of(int(d_late.unit_number)),
      f"target_spots: a belt laid on a drill's spot without an event is found by the look again: "
      f"{watched_of(int(b_late.unit_number))} {actor_of(int(d_late.unit_number))}")
for e in (d_off, b_off, d_on, b_on, b_on2, d_run, r1b, r2, d_late, b_late):
    if e.valid:
        e.destroy()
send(hello_now)
tick(1)
drain()

# --- J26: mining sweeps -------------------------------------------------------------------------------
# As 2.1.24's own mining does (measured with a player-less character's mining_state and
# update_selected_entity): the target is what is under the cursor; a new one starts from nothing, none
# keeps the progress without mining, the same one again goes on; the character stands while it mines.
# The client says where its cursor is from the character (ox, oy) and the bridge follows that point
# each tick, so walking with the button held along a line of belts mines every belt in turn.
sw = g.storage.f3d
is_same = lua.eval("function(a, b) return a == b end")  # (`same` is a chart check's by now)
sweep_home = puppet.position
sx, sy = 600.0, 600.0
puppet.teleport(lua.table_from({"x": sx, "y": sy}))
send({"t": "mine_stop"})
tick(1)
F.walk_moves = True
line = [spawn("transport-belt", sx + 2.5 + i, sy - 1.5, force="player", direction=4) for i in range(3)]
moved_while_mining = []
mined_by = None
for t in range(400):
    if t % 9 == 0:  # as the client repeats them
        send({"t": "walk", "d": 4})
        send({"t": "mine", "n": 1, "ox": fixed(2.5), "oy": fixed(-1.5)})
    m = sw.mining
    target = m.entity if m is not None and not m.paused else None
    x0 = puppet.position.x
    tick(1)
    if target is not None and sw.mining is not None and is_same(sw.mining.entity, target) and puppet.position.x != x0:
        moved_while_mining.append(t)
    if all(not b.valid for b in line):
        mined_by = t
        break
send({"t": "walk", "d": -1})
send({"t": "mine_stop"})
tick(1)
F.walk_moves = False
check(mined_by is not None and not moved_while_mining,
      f"J26: walking with the button held mines every belt of a line in turn, standing while it mines: "
      f"mined by tick {mined_by}, moved while mining at {moved_while_mining[:5]}")
# A mouse sweep, standing: off the belt the progress waits (and the character may walk), back on it
# it goes on; on another belt it starts again.
puppet.teleport(lua.table_from({"x": sx, "y": sy}))
pa = spawn("transport-belt", sx + 2.5, sy - 1.5, force="player", direction=4)
pb = spawn("transport-belt", sx + 3.5, sy - 1.5, force="player", direction=4)
on_a = {"t": "mine", "u": pa.unit_number, "p": eid["transport-belt"], "x": fixed(sx + 2.5), "y": fixed(sy - 1.5),
        "ox": fixed(2.5), "oy": fixed(-1.5)}
send(on_a)
tick(30)
half = sw.mining.progress
send({"t": "mine", "n": 1, "ox": fixed(2.5), "oy": fixed(3.5)})
send({"t": "walk", "d": 4})
tick(1)
paused = sw.mining is not None and sw.mining.paused and sw.mining.progress == half and puppet.walking_state.walking
tick(8)
send({"t": "walk", "d": -1})
send(on_a)
tick(1)
resumed = sw.mining is not None and is_same(sw.mining.entity, pa) and not sw.mining.paused and sw.mining.progress > half
check(paused and resumed, f"J26: off the target the progress waits and the walk goes on, back on it mining goes on: {half} {paused} {resumed}")
tick(10)
send({"t": "mine", "u": pb.unit_number, "p": eid["transport-belt"], "x": fixed(sx + 3.5), "y": fixed(sy - 1.5),
      "ox": fixed(3.5), "oy": fixed(-1.5)})
tick(1)
check(pa.valid and is_same(sw.mining.entity, pb) and sw.mining.progress < half,
      f"J26: another target under the cursor starts from nothing, the last left as it was: {sw.mining.progress}")
# The client's view is a few ticks behind: a `mine` for the belt just mined (gone) keeps the one the
# point has reached.
send({"t": "mine", "u": 999999, "p": eid["transport-belt"], "x": fixed(sx + 9.5), "y": fixed(sy - 1.5),
      "ox": fixed(3.5), "oy": fixed(-1.5)})
tick(1)
check(sw.mining is not None and is_same(sw.mining.entity, pb), "J26: a `mine` for something gone keeps the sweep's target")
send({"t": "mine_stop"})
tick(1)
check(sw.mining is None and sw.mine_at is None, "J26: letting go ends the sweep")
for e in (pa, pb):
    if e.valid:
        e.destroy()
puppet.teleport(sweep_home)
drain()

# --- K16: built_now (/f3d-bs, on): a belt built, replaced, removed or turned is worked out the next tick ------------
# Before, a new belt waited for the round's start, any scan in progress and a scan of its own, each reading at most
# two chunks a tick whose lists had expired: at a belt item distance of 320 it reached the client up to 200 ticks
# after it was built (640: 550), the line it extended standing in Zenith meanwhile. Every chunk list of the square
# is made to have expired here (as a while after the last scan), and a scan begun, before each build.
bs_k = lua.eval('package.loaded["scripts.belt_sim"]')
check("built_now on" in str(bs_k.option_command("")[1]), "/f3d-bs lists built_now (on)")
kx, ky = 2500.5, 330.5
send(ts_hello)
send({"t": "focus", "x": fixed(kx), "y": fixed(ky + 2), "r": 192})
send({"t": "bfar", "r": 320, "n": 320, "m": 0})
k_line = [spawn("transport-belt", kx + i, ky, force="player", direction=4) for i in range(4)]
for a_, b_ in zip(k_line, k_line[1:]):
    F.link_belts(a_, b_)
for i_, e_ in enumerate(k_line):
    F.put_on_belt(e_, 1, "iron-plate", 0.5, 8700 + i_)
k_in = spawn("underground-belt", kx, ky + 6, force="player", direction=4, type="input")
for e_ in k_line + [k_in]:
    F["raise"]("script_raised_built", lua.table_from({"entity": e_}))
keep(120)
drain()
k_loaded = lua.eval("function(u) local b = storage.f3d.bs; return (b and b.belts[u]) and true or false end")
check(all(k_loaded(int(e_.unit_number)) for e_ in k_line + [k_in]), "K16: the test's belts are loaded")


def k_expire():
    lua.execute("storage.f3d.bs.bc = {}; storage.f3d.bs.rescan = true")
    keep(7)
    drain()


def k_wait(keys, n=300, field="lm"):
    """Ticks until one of `keys` is in a `bs` message's `field`, and what came: (ticks, bs_of of that tick)."""
    t0 = g.game.tick
    for _ in range(n):
        keep(1)
        got = bs_of(drain())
        if any(k_ in (got[field] if field != "dl" else set(got["dl"])) for k_ in keys):
            return g.game.tick - t0, got
    return None, None


k_built = {}
for flag, x_ in (("off", 4), ("default", 5)):
    bs_k.option_command("built_now " + flag)
    k_expire()
    e_ = spawn("transport-belt", kx + x_, ky, force="player", direction=4)
    F.link_belts(k_line[-1], e_)
    k_line.append(e_)
    t_built = g.game.tick
    F["raise"]("script_raised_built", lua.table_from({"entity": e_}))
    u_ = int(e_.unit_number)
    ticks_, got_ = k_wait([u_ * 8 + 1])
    k_built[flag] = (ticks_, got_["sl"].get(u_ * 8 + 1, (None,))[0] - t_built if got_ else None)
    keep(30)
    drain()
check(k_built["default"][0] is not None and k_built["default"][0] <= 7 and k_built["default"][1] in (0, 1)
      and (k_built["off"][0] is None or k_built["off"][0] > 30),
      f"K16 built_now: a belt built comes in the next update, read on its tick (off: after the scans): "
      f"(ticks to its lm, its read's tick after the build) {k_built}")
u_new = int(k_line[-1].unit_number)
gone_new = []
for _ in range(80):
    keep(10)
    gone_new += bs_of(drain())["dl"]
check(k_loaded(u_new) and u_new * 8 + 1 not in gone_new,
      f"K16 built_now: the scans that began before it keep it loaded: {k_loaded(u_new)}, dl {gone_new}")
# A belt replaced (a fast-replace raises nothing for the old one): the old lanes leave as the new come.
k_expire()
old_ = k_line[2]
u_old = int(old_.unit_number)
old_.destroy()
rep_ = spawn("transport-belt", kx + 2, ky, force="player", direction=4)
F.link_belts(k_line[1], rep_)
F.link_belts(rep_, k_line[3])
k_line[2] = rep_
F["raise"]("script_raised_built", lua.table_from({"entity": rep_}))
ticks_, got_ = k_wait([int(rep_.unit_number) * 8 + 1])
check(ticks_ is not None and ticks_ <= 7 and u_old * 8 + 1 in got_["dl"] and u_old * 8 + 2 in got_["dl"],
      f"K16 built_now: a belt replaced: the new one's lanes in the next update, the old one's gone with them: {ticks_} "
      f"{got_['dl'] if got_ else None}")
# A belt removed: its lanes leave in the next update.
k_expire()
rm_ = k_line[-1]
u_rm = int(rm_.unit_number)
F["raise"]("script_raised_destroy", lua.table_from({"entity": rm_}))
rm_.destroy()
k_line.pop()
ticks_, got_ = k_wait([u_rm * 8 + 1], field="dl")
check(ticks_ is not None and ticks_ <= 7, f"K16 built_now: a belt removed leaves (dl) in the next update: {ticks_}")
# A belt turned: read again with its meta in the next update.
k_expire()
k_line[0].direction = 0
F["raise"]("on_player_rotated_entity", lua.table_from({"entity": k_line[0]}))
ticks_, got_ = k_wait([int(k_line[0].unit_number) * 8 + 1])
check(ticks_ is not None and ticks_ <= 7, f"K16 built_now: a belt turned is read again (lm) in the next update: {ticks_}")
# An underground exit built 9 tiles from its entrance (past forget_touched's reach round the exit): the entrance is
# read again with it, its hidden lines going on into the exit's (off: not, as before).
k_pair = {}
for flag, dx_ in (("off", 9), ("default", 9)):
    bs_k.option_command("built_now " + flag)
    k_expire()
    out_ = spawn("underground-belt", kx + dx_, ky + 6, force="player", direction=4, type="output")
    F.pair_undergrounds(k_in, out_)
    F["raise"]("script_raised_built", lua.table_from({"entity": out_}))
    ui_ = int(k_in.unit_number)
    ticks_, got_ = k_wait([ui_ * 8 + 3], n=24)
    k_pair[flag] = (ticks_, (got_["lm"].get(ui_ * 8 + 3) or [0])[-1] == int(out_.unit_number) * 8 + 1 if got_ else None)
    F["raise"]("script_raised_destroy", lua.table_from({"entity": out_}))
    out_.destroy()
    k_in.underground_belt_neighbour = None
    keep(30)
    drain()
check(k_pair["default"][0] is not None and k_pair["default"][0] <= 7 and k_pair["default"][1] and k_pair["off"][0] is None,
      f"K16 built_now: an underground's other end is read again when one is built, its hidden lines going on into the "
      f"exit (off: not): {k_pair}")
# The client's ug_guard keys an entrance's dead end off its hidden lines' next: an exit built for an existing entrance
# and then removed must each send the entrance's hidden lines again with their new next (its meta is cached till the
# belt is loaded again: next_of). Built 9 tiles off (past forget_touched's reach round the exit): next = the exit's
# line 1; removed: next 0 (no exit), not the old exit's key nor minus it.
bs_k.option_command("built_now default")
k_expire()
ue_out = spawn("underground-belt", kx + 9, ky + 6, force="player", direction=4, type="output")
F.pair_undergrounds(k_in, ue_out)
F["raise"]("script_raised_built", lua.table_from({"entity": ue_out}))
ue_u, ue_in = int(ue_out.unit_number), int(k_in.unit_number)
t_b, got_b = k_wait([ue_in * 8 + 3], n=24)
nx_b = (got_b["lm"].get(ue_in * 8 + 3) or [None])[-1] if got_b else None
keep(20)
drain()
F["raise"]("script_raised_destroy", lua.table_from({"entity": ue_out}))
ue_out.destroy()
k_in.underground_belt_neighbour = None
t_r, got_r = k_wait([ue_in * 8 + 3], n=24)
nx_r = (got_r["lm"].get(ue_in * 8 + 3) or [None])[-1] if got_r else None
keep(30)
drain()
check(t_b is not None and nx_b == ue_u * 8 + 1 and t_r is not None and t_r <= 7 and nx_r == 0,
      f"an underground exit built for an entrance sends the entrance's hidden lines with next its line 1 "
      f"({t_b} ticks: {nx_b}, want {ue_u * 8 + 1}), and removed again with next 0 ({t_r} ticks: {nx_r})")
# K22: the character mines a belt with no player (Factorio raises nothing then): its lanes leave in the next update
# (/f3d-perf mined_tell; off: as before, not until a check of it happened to come round).
k22 = {}
k22_home = puppet.position
g.settings["global"]["f3d-act-as-player"]["value"] = False  # (a headless server's character: no player to mine as)
for flag, dy_ in (("off", 12), ("default", 14)):
    F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "mined_tell " + flag}))
    mb_ = spawn("transport-belt", kx + 3.5, ky + dy_ + 0.5, force="player", direction=4)
    F.put_on_belt(mb_, 1, "iron-plate", 0.5, 8790 + dy_)
    F["raise"]("script_raised_built", lua.table_from({"entity": mb_}))
    keep(30)
    drain()
    um_ = int(mb_.unit_number)
    puppet.teleport(lua.table_from({"x": kx + 1.5, "y": ky + dy_ + 0.5}))
    mine_ = {"t": "mine", "u": um_, "p": eid["transport-belt"], "x": fixed(kx + 3.5), "y": fixed(ky + dy_ + 0.5),
             "ox": fixed(2.0), "oy": fixed(0.0)}
    t_mined = None
    gone_at = None
    for t_ in range(400):
        if t_ % 9 == 0 and mb_.valid:
            send(mine_)
        keep(1)
        if t_mined is None and not mb_.valid:
            t_mined = g.game.tick
        if (um_ * 8 + 1) in bs_of(drain())["dl"]:
            gone_at = g.game.tick
            break
    send({"t": "mine_stop"})
    keep(1)
    k22[flag] = (t_mined is not None, None if gone_at is None or t_mined is None else gone_at - t_mined)
F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "mined_tell default"}))
g.settings["global"]["f3d-act-as-player"]["value"] = True
puppet.teleport(k22_home)
check(k22["default"][0] and k22["default"][1] is not None and k22["default"][1] <= 7
      and k22["off"][0] and (k22["off"][1] is None or k22["off"][1] > 7),
      f"K22 mined_tell: a belt the character mines leaves the belt simulation (dl) in the next update (off: later): "
      f"(mined, ticks from its mining to its dl) {k22}")
# The owner's FUE5 pipe left open at its end: the character mines the middle of a run of five pipes with no player
# (Factorio raises nothing then): the two pipes beside it are sent again (`upd`) the tick after with their new
# connections, now the run's endings (pc 8 and 2) (/f3d-perf mined_neighbours; off: never, their records kept the side
# to the mined pipe and the client drew them as straights, open at the end in FUE5's kit).
pe = {}
pe_home = puppet.position
# (records go only for subscribed chunks: the pipes' chunk added to what this client has, put back after)
pe_subs = [[int(c) for c in k.split(",")] for k in to_py(lua.eval(
    "function() local o = {} for k in pairs(storage.f3d.subs) do o[#o + 1] = k end return o end")())]
pe_chunk = [int((kx + 1.5) // 32), int((ky + 20.5) // 32)]
send({"t": "sub", "c": pe_subs + [pe_chunk]})
keep(10)
drain()
g.settings["global"]["f3d-act-as-player"]["value"] = False
for flag, dy_ in (("off", 18), ("default", 20)):
    F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "mined_neighbours " + flag}))
    run_ = []
    for i_ in range(5):
        p_ = spawn("pipe", kx + 1.5 + i_, ky + dy_ + 0.5, force="player")
        F["raise"]("script_raised_built", lua.table_from({"entity": p_}))
        run_.append(p_)
    keep(5)
    drain()
    mid_ = run_[2]
    puppet.teleport(lua.table_from({"x": kx + 3.5, "y": ky + dy_ - 1.5}))
    mine_ = {"t": "mine", "u": int(mid_.unit_number), "p": eid["pipe"], "x": fixed(kx + 3.5), "y": fixed(ky + dy_ + 0.5),
             "ox": fixed(0.0), "oy": fixed(2.0)}
    t_mined, got_ = None, {}
    for t_ in range(300):
        if t_ % 9 == 0 and mid_.valid:
            send(mine_)
        keep(1)
        if t_mined is None and not mid_.valid:
            t_mined = g.game.tick
        for m_ in of_type(drain(), "upd"):
            if t_mined is not None and m_["e"][0] in (run_[1].unit_number, run_[3].unit_number):
                got_[m_["e"][0]] = (m_["e"][5].get("pc"), g.game.tick - t_mined)
        if t_mined is not None and (len(got_) == 2 or g.game.tick - t_mined > 30):
            break
    send({"t": "mine_stop"})
    keep(1)
    pe[flag] = (t_mined is not None, got_.get(run_[1].unit_number), got_.get(run_[3].unit_number))
    for p_ in run_:
        if p_.valid:
            p_.destroy()
    keep(2)
    drain()
# The owner's second picture: a T whose branch was mined stayed a T, its open mouth showing. A T, a cross and a
# corner each lose one arm (the north one) to the character's mining: the pipe in the middle is sent again without it.
pe_shape = {}
for name_, cx_, arms_, want_ in (("T", kx + 10.5, ((1, 0), (-1, 0)), 10), ("cross", kx + 14.5, ((1, 0), (-1, 0), (0, 1)), 14),
                                 ("corner", kx + 18.5, ((1, 0),), 2)):
    cy_ = ky + 20.5
    mid_ = spawn("pipe", cx_, cy_, force="player")
    F["raise"]("script_raised_built", lua.table_from({"entity": mid_}))
    others_ = []
    for ax_, ay_ in arms_ + ((0, -1),):
        p_ = spawn("pipe", cx_ + ax_, cy_ + ay_, force="player")
        F["raise"]("script_raised_built", lua.table_from({"entity": p_}))
        others_.append(p_)
    north_ = others_[-1]
    keep(5)
    drain()
    puppet.teleport(lua.table_from({"x": cx_ - 2.0, "y": cy_ - 1.0}))
    mine_ = {"t": "mine", "u": int(north_.unit_number), "p": eid["pipe"], "x": fixed(cx_), "y": fixed(cy_ - 1.0),
             "ox": fixed(2.0), "oy": fixed(0.0)}
    t_mined, got_ = None, None
    for t_ in range(300):
        if t_ % 9 == 0 and north_.valid:
            send(mine_)
        keep(1)
        if t_mined is None and not north_.valid:
            t_mined = g.game.tick
        for m_ in of_type(drain(), "upd"):
            if t_mined is not None and m_["e"][0] == mid_.unit_number:
                got_ = (m_["e"][5].get("pc"), g.game.tick - t_mined)
        if t_mined is not None and (got_ is not None or g.game.tick - t_mined > 30):
            break
    send({"t": "mine_stop"})
    keep(1)
    pe_shape[name_] = (t_mined is not None, want_, got_)
    for p_ in [mid_] + others_:
        if p_.valid:
            p_.destroy()
    keep(2)
    drain()
check(all(v[0] and v[2] is not None and v[2][0] == v[1] and v[2][1] <= 3 for v in pe_shape.values()),
      f"mined_neighbours: a T, a cross and a corner losing their north arm to the character's mining are sent again "
      f"without it the tick after: (mined, want pc, (pc, ticks)) {pe_shape}")
F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": "mined_neighbours default"}))
g.settings["global"]["f3d-act-as-player"]["value"] = True
puppet.teleport(pe_home)
send({"t": "sub", "c": pe_subs})
keep(5)
drain()
check(pe["default"][0] and pe["default"][1] is not None and pe["default"][1][0] == 8 and pe["default"][1][1] <= 3
      and pe["default"][2] is not None and pe["default"][2][0] == 2 and pe["default"][2][1] <= 3
      and pe["off"][0] and pe["off"][1] is None and pe["off"][2] is None,
      f"mined_neighbours: the pipes beside one the character mines with no player are sent again as endings "
      f"(west 8, east 2) the tick after (off: not at all): (mined, (pc, ticks) west, east) {pe}")
bs_k.option_command("built_now off")
keep(13)
check(g.storage.f3d.bs.fresh is None, "K16 built_now off: nothing kept for it")
bs_k.option_command("built_now default")
for e_ in k_line + [k_in]:
    if e_.valid:
        e_.destroy()
send(hello_now)
tick(1)
drain()

# --- E31: lane_next (/f3d-bs, on): every lane's `lm` next as the game's belt connections, sent again when it changes ---
# The client's copy of the belts stops a lane's front items at its end when its next is 0 and no lane follows (the line
# ends there), and holds them at the bridge's reads when it is negative (it leads out of what is sent). Found at the end
# of the owner's bus: lanes said -1 though the belt they feed was sent, and 0 though it wasn't. A belt loading read its
# feeders' lanes again without their meta (the -1 stayed: first loads chain at most 4 rings out, so a line going
# outwards had every fourth ring loaded before its next, and walking did the same at the square's edge each step); a
# belt leaving had its feeders' -1 sent only with the next round's reload; a reload after a catch-up's read in the same
# tick lost its lm (a curve straightened kept its old shape); a splitter's lanes all said -1 when one half's belt
# wasn't loaded. The view below is the client's: each lane's last lm, dropped with its dl, checked after every update.
bs_n = lua.eval('package.loaded["scripts.belt_sim"]')
check("lane_next on" in str(bs_n.option_command("")[1]), "/f3d-bs lists lane_next (on)")
nx0, ny0 = 3500.5, 330.5
ln_view, ln_kind, ln_bad = {}, {}, []
ln_belts, ln_split = [], {}


def ln_links(e):
    links = F.belt_links[e]
    outs = links and links.outputs
    return [outs[i] for i in range(1, len(outs) + 1) if outs[i].valid] if outs else []


def ln_held(u):
    return any(u * 8 + j in ln_view for j in range(1, 9))


def ln_truth():
    """Lanes the client holds whose next isn't the game's: [(key, next, wanted)]."""
    bad = []
    for e in ln_belts:
        if not e.valid:
            continue
        u = int(e.unit_number)
        outs = ln_links(e)
        for i in range(1, int(e.get_max_transport_line_index()) + 1):
            key = u * 8 + i
            if key not in ln_view:
                continue
            explicit, target, leaves = 0, None, True
            if e.type == "underground-belt" and e.belt_to_ground_type == "input":
                if i <= 2:
                    explicit, leaves = key + 2, False
                elif e.underground_belt_neighbour:
                    target = e.underground_belt_neighbour
                    explicit = int(target.unit_number) * 8 + i - 2
            elif e.type == "splitter":
                leaves = i > 4
                target = ln_split.get((u, i))
            else:
                target = outs[0] if outs else None
            want = explicit
            if leaves and target is not None and not ln_held(int(target.unit_number)):
                want = -explicit if explicit else -1
            if ln_view[key] != want:
                bad.append((key, ln_view[key], want))
    return bad


def ln_run(n, label):
    for _ in range(n):
        keep(1)
        msgs = drain()
        done = False
        for m in of_type(msgs, "bs"):
            lm = m.get("lm", [])
            for i in range(0, len(lm), 12):
                ln_view[lm[i]], ln_kind[lm[i]] = lm[i + 11], lm[i + 1]
            for k_ in m.get("dl", []):
                ln_view.pop(k_, None)
            done = done or m.get("part") == m.get("parts")
        if done:
            bad = ln_truth()
            if bad:
                ln_bad.append((label, g.game.tick, bad))


def ln_add(e):
    ln_belts.append(e)
    F["raise"]("script_raised_built", lua.table_from({"entity": e}))
    return e


def ln_world():
    """A line east across the square's edge (dx 10-21, the square 16), an underground pair across it (dx 14 to 18),
    a line ending inside, a splitter on the edge whose left half's belt is inside and right half's outside."""
    ln_belts.clear()
    ln_split.clear()
    line_ = [ln_add(spawn("transport-belt", nx0 + 10 + k, ny0, force="player", direction=4)) for k in range(12)]
    for a_, b_ in zip(line_, line_[1:]):
        F.link_belts(a_, b_)
    ui_ = ln_add(spawn("underground-belt", nx0 + 14, ny0 + 3, force="player", direction=4, type="input"))
    uo_ = ln_add(spawn("underground-belt", nx0 + 18, ny0 + 3, force="player", direction=4, type="output"))
    F.pair_undergrounds(ui_, uo_)
    ua_ = ln_add(spawn("transport-belt", nx0 + 19, ny0 + 3, force="player", direction=4))
    F.link_belts(uo_, ua_)
    end_ = [ln_add(spawn("transport-belt", nx0 + k, ny0 - 4, force="player", direction=4)) for k in range(3)]
    for a_, b_ in zip(end_, end_[1:]):
        F.link_belts(a_, b_)
    sp_ = ln_add(spawn("splitter", nx0 + 15.5, ny0 + 6, force="player", direction=0, lines=8))
    left_ = ln_add(spawn("transport-belt", nx0 + 15, ny0 + 5, force="player", direction=0))
    right_ = ln_add(spawn("transport-belt", nx0 + 16, ny0 + 5, force="player", direction=0))
    feed_ = ln_add(spawn("transport-belt", nx0 + 15, ny0 + 7, force="player", direction=0))
    F.link_belts(feed_, sp_)
    F.link_belts(sp_, left_)
    F.link_belts(sp_, right_)
    for i in (5, 6, 7, 8):
        ln_split[(int(sp_.unit_number), i)] = left_ if i <= 6 else right_
    return line_, ui_, uo_, end_, sp_


def ln_scenario():
    """Loads, grows, shrinks and walks the square over ln_world(); returns {step: lanes otherwise after it}."""
    ln_view.clear()
    ln_bad.clear()
    send(ts_hello)
    send({"t": "focus", "x": fixed(nx0), "y": fixed(ny0), "r": 48})
    send({"t": "bfar", "r": 0, "n": 16, "m": 0})
    line_, ui_, uo_, end_, sp_ = ln_world()
    out = {}
    ln_run(40, "load")
    out["load"] = ln_truth()
    out["split"] = [ln_view.get(int(sp_.unit_number) * 8 + i) for i in range(5, 9)]
    send({"t": "bfar", "r": 0, "n": 20, "m": 0})
    ln_run(40, "grown")
    out["grown"] = ln_truth()
    out["pair"] = ln_view.get(int(ui_.unit_number) * 8 + 3)
    send({"t": "bfar", "r": 0, "n": 16, "m": 0})
    ln_run(40, "shrunk")
    out["shrunk"] = ln_truth()
    for k_ in list(range(1, 9)) + list(range(7, -1, -1)):
        send({"t": "focus", "x": fixed(nx0 + k_), "y": fixed(ny0), "r": 48})
        ln_run(12, "walk")
    ln_run(40, "walked")
    out["walked"] = ln_truth()
    # Built: a belt inside fed nothing, then one outside it feeds (it leads out), then that one removed (0 again).
    e1_ = ln_add(spawn("transport-belt", nx0 + 15, ny0 + 8, force="player", direction=4))
    ln_run(20, "built")
    e2_ = spawn("transport-belt", nx0 + 16, ny0 + 8, force="player", direction=4)
    F.link_belts(e1_, e2_)
    ln_add(e2_)
    ln_run(20, "built")
    out["built_out"] = (ln_truth(), ln_view.get(int(e1_.unit_number) * 8 + 1))
    F["raise"]("script_raised_destroy", lua.table_from({"entity": e2_}))
    e2_.destroy()
    ln_run(20, "removed")
    out["removed"] = (ln_truth(), ln_view.get(int(e1_.unit_number) * 8 + 1))
    # A curve straightened by a belt built behind it: the new belt's catch-up reads it on the tick its reload sends
    # its new meta.
    cv_ = ln_add(spawn("transport-belt", nx0 + 5, ny0 + 10, force="player", direction=4))
    lua.eval("function(e) F.datas[e].belt_shape = 'left' end")(cv_)
    F["raise"]("script_raised_built", lua.table_from({"entity": cv_}))
    ln_run(30, "curve")
    F.put_on_belt(cv_, 1, "iron-plate", 0.5, 9901)
    ln_run(30, "curve")
    ln_kind.pop(int(cv_.unit_number) * 8 + 1, None)
    bh_ = spawn("transport-belt", nx0 + 4, ny0 + 10, force="player", direction=4)
    F.link_belts(bh_, cv_)
    lua.eval("function(e) F.datas[e].belt_shape = 'straight' end")(cv_)
    ln_add(bh_)
    ln_run(30, "curve")
    out["straightened"] = ln_kind.get(int(cv_.unit_number) * 8 + 1)
    out["updates"] = list(ln_bad)
    for e_ in ln_belts:
        if e_.valid:
            e_.destroy()
    send({"t": "bfar", "r": 0, "n": 24, "m": 0})
    ln_run(30, "cleared")
    return out


fix0 = int(bs_n.counts["next_fix"] or 0)
ln_off = None
for flag in ("off", "default"):
    bs_n.option_command("lane_next " + flag)
    got_n = ln_scenario()
    if flag == "off":
        ln_off = got_n
check(ln_off["load"] and ln_off["grown"] and ln_off["straightened"] is None and ln_off["split"] == [-1, -1, -1, -1],
      f"lane_next off, as before: lanes kept -1 once their next loaded, the curve kept its meta, every splitter lane -1: "
      f"{ln_off['load']} {ln_off['grown']} {ln_off['straightened']} {ln_off['split']}")
check(not got_n["load"] and not got_n["grown"] and not got_n["shrunk"] and not got_n["walked"],
      f"lane_next: every lane's next as the game's connections after the first load, the square grown (its next loaded), "
      f"shrunk (its next gone) and walked over: {[(k_, got_n[k_]) for k_ in ('load', 'grown', 'shrunk', 'walked')]}")
check(not got_n["updates"], f"lane_next: ... at the end of every update, a lane's new next in the update its next came or "
      f"left in: {got_n['updates'][:3]}")
check(got_n["split"] == [0, 0, -1, -1], f"lane_next: a splitter's lanes each by their half's belt: {got_n['split']}")
check(got_n["pair"] is not None and got_n["pair"] > 0,
      f"lane_next: an entrance's hidden lines go on into its exit once it loads (minus its key before): {got_n['pair']}")
check(not got_n["built_out"][0] and got_n["built_out"][1] == -1 and not got_n["removed"][0] and got_n["removed"][1] == 0,
      f"lane_next: a belt built outside the square, fed from inside, makes its feeder lead out; removed, the feeder's "
      f"line ends there (0): {got_n['built_out']} {got_n['removed']}")
check(got_n["straightened"] == 1, f"lane_next: a curve straightened by a belt built behind it is sent again as straight "
      f"(kind 1), the reload's lm no longer lost to the catch-up's read that tick: {got_n['straightened']}")
check(int(bs_n.counts["next_fix"] or 0) == fix0,
      f"lane_next: no lane found told otherwise by the looks (every change sent where it happened): "
      f"{int(bs_n.counts['next_fix'] or 0) - fix0}")
# Multiplayer: what each lane's next was told (storage) goes the same on a peer without the round's payload (one that
# loaded the save mid-round sends nothing of it): the line across the edge, its next loaded with the payload forgotten.
ln_told = lua.eval("""function()
  local b = storage.f3d.bs
  local bad, n = 0, 0
  for key, lr in pairs(b.lanes) do
    local unit, i = math.floor((key - 1) / 8), (key - 1) % 8 + 1
    local r = b.belts[unit]
    local u = r and r[15] and r[15][i]
    if u ~= nil then
      n = n + 1
      if lr[16] ~= (u ~= 0 and b.belts[u] == nil) then
        bad = bad + 1
      end
    end
  end
  return bad, n
end""")
send(ts_hello)
send({"t": "focus", "x": fixed(nx0), "y": fixed(ny0), "r": 48})
send({"t": "bfar", "r": 0, "n": 16, "m": 0})
peer_line = ln_world()[0]
ln_run(40, "peer")
ln_view.clear()
bs_n.load_cap = 20  # (a belt or so a tick: the loads go on over the round's ticks, each without its payload)
send({"t": "bfar", "r": 0, "n": 20, "m": 0})
keep(1)
for _ in range(11):
    check(forget(bs_n.tick, "pays"), "the belt simulation's payloads can be forgotten (a peer that loaded mid-round)")
    keep(1)
ln_run(1, "peer")
bs_n.load_cap = None
told_bad, told_n = ln_told()
ln_loaded = lua.eval("function(u) return storage.f3d.bs.belts[u] ~= nil end")
unsent = [e_ for e_ in peer_line[6:10] if ln_loaded(int(e_.unit_number)) and not ln_held(int(e_.unit_number))]
check(unsent and told_n > 20 and told_bad == 0,
      f"lane_next: each lane's next as told, in storage, follows the belts loading without the payload too "
      f"({len(unsent)} belts loaded unsent): {told_bad} of {told_n} otherwise")
for e_ in ln_belts:
    if e_.valid:
        e_.destroy()
bs_n.option_command("lane_next default")
# --- ins_driven (/f3d-bs, off): an inserter's belts read when its hand takes or puts, not looked at every update -------
# The owner's idea: a belt watched for its inserters alone (a pickup belt, the belt behind it, a drop belt) needs a read
# only when a hand took or put there, which the inserter's own check (every update, its hand's count) shows. A drill's
# drop belt stays watched (drills tell nothing), and off is as before.
bs_i = lua.eval('package.loaded["scripts.belt_sim"]')
check("ins_driven off" in str(bs_i.option_command("")[1]), "/f3d-bs lists ins_driven (off)")
ix, iy = 2700.5, 330.5
i_line = [spawn("transport-belt", ix + i, iy, force="player", direction=4) for i in range(4)]
for a_, b_ in zip(i_line, i_line[1:]):
    F.link_belts(a_, b_)
i_take = spawn("inserter", ix + 2, iy + 1, force="player")
i_take.pickup_target = i_line[2]  # i_line[2] its pickup belt, i_line[1] the belt behind it
i_put_belt = spawn("transport-belt", ix, iy + 4, force="player", direction=4)
i_put = spawn("inserter", ix, iy + 3, force="player")
i_put.drop_target = i_put_belt
F.set_hand(i_put, ix, iy + 3, "iron-plate")
i_drill_belt = spawn("transport-belt", ix + 4, iy + 6, force="player", direction=4)
i_drill = spawn("burner-mining-drill", ix + 2.5, iy + 6.5, force="player")
i_drill.drop_target = i_drill_belt
for e_ in i_line + [i_take, i_put_belt, i_put, i_drill_belt, i_drill]:
    F["raise"]("script_raised_built", lua.table_from({"entity": e_}))
i_hello = dict(ts_hello)


def i_keep(n):
    for _ in range(n):
        if g.game.tick % 100 == 0:
            send(i_hello)
        tick(1)


send(i_hello)
send({"t": "focus", "x": fixed(ix), "y": fixed(iy + 2), "r": 48})
send({"t": "bfar", "r": 0, "n": 24, "m": 0})
i_keep(120)
drain()
i_rec = lua.eval("function(u, k) local b = storage.f3d.bs; local r = b and b.belts[u]; return r and r[k] or false end")
u_pick, u_behind, u_put, u_drill = (int(e_.unit_number) for e_ in (i_line[2], i_line[1], i_put_belt, i_drill_belt))
check(all(i_rec(u_, 4) for u_ in (u_pick, u_behind, u_put, u_drill)),
      "ins_driven: the pickup belt, the belt behind it, the drop belt and the drill's belt are watched")
check(i_rec(u_pick, 16) and i_rec(u_behind, 16) and i_rec(u_put, 16) and not i_rec(u_drill, 16),
      "ins_driven: those an inserter uses are watched for inserters alone, the drill's belt not")


def i_sent_after(keys, n):
    """Ticks until a `sl` of one of `keys` comes, at most n: (ticks or None, the read's tick)."""
    t0 = g.game.tick
    for _ in range(n):
        i_keep(1)
        got = bs_of(drain())["sl"]
        for k_ in keys:
            if k_ in got:
                return g.game.tick - t0, got[k_][0]
    return None, None


# Off, as before: an item coming onto the pickup belt with no hand moving is read at the lane's next look (a lane that
# stood is looked at every spot_quiet_ticks, 60, then in the next update).
I_LOOK = 60 + 13
F.put_on_belt(i_line[2], 1, "iron-plate", 0.5, 8901)
off_seen = i_sent_after([u_pick * 8 + 1], I_LOOK)
check(off_seen[0] is not None, f"ins_driven off: a pickup belt's change is read at its next look, as before: {off_seen}")
watch_off = [int(u_) for u_ in to_py(bs_i.watch_list()) or []]
check(u_pick in watch_off and u_drill in watch_off, "ins_driven off: the pickup belt and the drill's belt in the watch list")
# On: the pickup belt and the belt behind it out of the watch list, the drill's belt in it.
bs_i.option_command("ins_driven on")
i_keep(13)
drain()
watch_on = [int(u_) for u_ in to_py(bs_i.watch_list()) or []]
check(u_pick not in watch_on and u_behind not in watch_on and u_put not in watch_on and u_drill in watch_on,
      f"ins_driven on: the belts watched for inserters alone leave the watch list, the drill's belt stays: "
      f"{[u_ in watch_on for u_ in (u_pick, u_behind, u_put, u_drill)]}")
# An item coming onto the pickup belt with no hand moving: not read, past the look it would have had (the client
# simulates it) ...
F.put_on_belt(i_line[2], 2, "copper-plate", 0.5, 8902)
before_pick = i_sent_after([u_pick * 8 + 1, u_pick * 8 + 2], I_LOOK)
check(before_pick[0] is None, f"ins_driven on: a pickup belt isn't read while no hand takes there: {before_pick}")
# ... until the hand takes one: then the pickup belt and the belt behind it are read in the next update, on a tick
# at or after the take.
F.move_on_belt(i_line[2], 2, 8902, None)
F.set_hand(i_take, ix + 2, iy + 0.5, "copper-plate")
t_take = g.game.tick
t0_ = g.game.tick
got_pick, got_behind = None, None
for _ in range(20):
    i_keep(1)
    sl_ = bs_of(drain())["sl"]
    if got_pick is None and u_pick * 8 + 2 in sl_:
        got_pick = (g.game.tick - t0_, sl_[u_pick * 8 + 2][0] - t_take, len(sl_[u_pick * 8 + 2][1]))
    if got_behind is None and (u_behind * 8 + 1 in sl_ or u_behind * 8 + 2 in sl_):
        got_behind = g.game.tick - t0_
    if got_pick and got_behind:
        break
check(got_pick is not None and got_pick[0] <= 13 and got_pick[1] >= 0 and got_pick[2] == 0 and got_behind is not None,
      f"ins_driven on: a take reads the pickup belt (its lane empty now) and the belt behind it in the next update: "
      f"(ticks, read after the take, items) {got_pick}, the belt behind {got_behind}")
check(int(bs_i.counts.ins_takes or 0) >= 1, "ins_driven on: the take counted")
# After the take the pickup belt is watched as before for its window (ins_window updates, or until it settles): the
# items behind closing up the hole are read as they come ...
F.put_on_belt(i_line[2], 2, "copper-plate", 0.75, 8907)
closing = i_sent_after([u_pick * 8 + 2], 13)
check(closing[0] is not None, f"ins_driven on: a pickup belt is read as it changes in the window after a take: {closing}")
# ... and once the window is over, not any more.
i_keep(6 * int(bs_i.OPTIONS.ins_window) + 13)
drain()
F.put_on_belt(i_line[2], 2, "copper-plate", 0.25, 8908)
after_win = i_sent_after([u_pick * 8 + 2], I_LOOK)
check(after_win[0] is None, f"ins_driven on: and not after its window: {after_win}")
# A put on the drop belt: read in the next update (a client without `ho` isn't told the item itself).
F.set_hand(i_put, ix, iy + 3.5, None)
F.put_on_belt(i_put_belt, 1, "iron-plate", 0.5, 8903)
put_seen = i_sent_after([u_put * 8 + 1], 20)
check(put_seen[0] is not None and put_seen[0] <= 13, f"ins_driven on: a put reads the drop belt in the next update: {put_seen}")
# ins_ho (on): a client taking `ie` and `ho` is told the item itself (PLACED), so the put isn't read.
# (After the window the last put watched the drop belt for: ins_window updates, or until it settled.)
i_hello = dict(ts_hello, ie=1, ho=1)
send(i_hello)
F.set_hand(i_put, ix, iy + 3, "iron-plate")
i_keep(6 * int(bs_i.OPTIONS.ins_window) + 13)
drain()
told0 = int(bs_i.counts.ins_told or 0)
F.set_hand(i_put, ix, iy + 3.5, None)
F.put_on_belt(i_put_belt, 1, "iron-plate", 0.25, 8904)
put_told = i_sent_after([u_put * 8 + 1], 20)
check(put_told[0] is None and int(bs_i.counts.ins_told or 0) == told0 + 1,
      f"ins_ho: a put for a client told the item itself (ie, ho) isn't read: {put_told}, told {int(bs_i.counts.ins_told or 0) - told0}")
i_hello = dict(ts_hello)
send(i_hello)
# The drill's belt stays watched: an item coming onto it (no progress gone round) is read in the next update.
F.put_on_belt(i_drill_belt, 1, "iron-ore", 0.5, 8905)
drill_seen = i_sent_after([u_drill * 8 + 1], I_LOOK)
check(drill_seen[0] is not None,
      f"ins_driven on: a drill's belt is still watched (a change read at its next look): {drill_seen}")
# Off again: the pickup belt is back in the watch list, its change read in the next update.
bs_i.option_command("ins_driven default")
i_keep(7)
drain()
F.put_on_belt(i_line[2], 1, "iron-plate", 0.25, 8906)
back_seen = i_sent_after([u_pick * 8 + 1], I_LOOK)
check(u_pick in [int(u_) for u_ in to_py(bs_i.watch_list()) or []] and back_seen[0] is not None,
      f"ins_driven default: back as before, the pickup belt watched again: {back_seen}")
for e_ in i_line + [i_take, i_put_belt, i_put, i_drill_belt, i_drill]:
    if e_.valid:
        e_.destroy()
send(hello_now)
tick(1)
drain()

# --- L13: a world Zenith made, joined from Factorio ----------------------------------------------
# Each scenario on a fresh game (a runtime of its own, nobody in it yet, freeplay as the scenario):
# the helpers above read the module's `lua`, `g` and `F`, so they follow.
def fresh_world(freeplay=True, multiplayer=True):
    global lua, g, F, expected_r
    lua = lua52.LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    g.F_to_json = to_json
    g.F_from_json = from_json
    lua.execute(FAKE.read_text())
    g.package.path = str(MOD / "?.lua") + ";" + g.package.path
    lua.execute((MOD / "control.lua").read_text())
    lua.execute('package.loaded["scripts.barrier"].rethrow = true')
    lua.execute('require = function(name) error("Require can not be used outside of control.lua parsing: " .. tostring(name)) end')
    F = g.F
    F.multiplayer = multiplayer
    if freeplay:
        F.add_freeplay()
    F.on_init()
    expected_r = 1


def same(a, b):
    # (Lua objects through lupa compare as Python objects: entities by their unit numbers.)
    return a is not None and b is not None and a.valid and b.valid and a.unit_number == b.unit_number


def perf_cmd(parameter):
    F.commands["f3d-perf"](lua.table_from({"name": "f3d-perf", "parameter": parameter}))


def item_count(c, name):
    n = c.get_main_inventory().get_item_count(name)
    for inv in (g.defines.inventory.character_guns, g.defines.inventory.character_ammo):
        n += c.get_inventory(inv).get_item_count(name)
    return n


def kit_counts(c):
    return {n: item_count(c, n) for n in ("iron-plate", "wood", "pistol", "firearm-magazine", "burner-mining-drill", "stone-furnace")}


# The owner's video: a new game made in Zenith's menu, Zenith playing it on the headless server.
fresh_world()
zen_hello = {"t": "hello", "v": 1, "sid": "z1", "w": 1, "pn": "zen"}
send(zen_hello)
tick(4)
take()
own = g.storage.f3d.puppet
check(own and own.valid and same(g.storage.f3d.own_character, own) and not g.storage.f3d.owner_index,
      "L13: on a new server game the bridge plays its own character")
check(F.freeplay.disable_crashsite is True and not F.freeplay.init_ran,
      f"L13: freeplay is told not to make its crash site, before anyone joined ({F.freeplay.disable_crashsite})")
check(g.storage.f3d.client.pn == "zen", "L13: the hello's pn (this Zenith's Factorio account) is kept with the client")
own.teleport(lua.table_from({"x": 40.5, "y": 12.5}))
own.get_main_inventory().insert(lua.table_from({"name": "iron-gear-wheel", "count": 30}))
own.get_inventory(g.defines.inventory.character_armor).insert(lua.table_from({"name": "light-armor", "count": 1}))
send({"t": "qb_set", "i": 1, "item": "transport-belt"})
tick(1)
before_kit = kit_counts(own)
own_unit = own.unit_number
take()
# A stranger joins first: a character of their own, with freeplay's kit; the bridge keeps its own.
stranger, stranger_char = F.create_player(2, "stranger", 0.5, 0.5)
send(zen_hello)
tick(2)
check(same(g.storage.f3d.puppet, own) and same(stranger.character, stranger_char) and stranger_char.valid
      and not g.storage.f3d.owner_index and kit_counts(stranger_char)["iron-plate"] == 8,
      "L13: a stranger who joins gets a character of their own (and freeplay's kit); the bridge keeps playing its own")
check(F.freeplay.crash_sites == 0 and F.freeplay.init_ran,
      f"L13: freeplay's first player made no crash site in the base ({F.freeplay.crash_sites})")
take()
# The owner presses Ctrl+F9: their Factorio joins as "zen" (the name the hello said).
zen, fresh = F.create_player(3, "zen", 0.5, 0.5)
fresh.insert(lua.table_from({"name": "coal", "count": 5}))  # what another mod gave a new player
check(g.storage.f3d.owner_index == 3 and g.storage.f3d.zenith_owner == 3, "L13: the player of the hello's name is claimed on joining")
tick(2)
msgs = take()
check(same(zen.character, own) and same(g.storage.f3d.puppet, own) and own.valid and own.unit_number == own_unit
      and own.position.x == 40.5 and own.position.y == 12.5 and own.player.index == 3,
      "L13: they take over the character Zenith was playing, where it was (the same entity)")
check(not fresh.valid, "L13: the character the game gave them on joining is gone")
check(own.get_main_inventory().get_item_count("iron-gear-wheel") == 30
      and own.get_inventory(g.defines.inventory.character_armor)[1].valid_for_read,
      "L13: with Zenith's inventory and armour")
check(kit_counts(own) == before_kit, f"L13: and no second starting kit ({before_kit} -> {kit_counts(own)})")
check(own.get_main_inventory().get_item_count("coal") == 5, "L13: what else the new character had comes along")
qb = zen.get_quick_bar_slot(1, 1)
check(qb is not None and qb.filter.name == "transport-belt", "L13: Zenith's quickbar becomes the player's")
check(not of_type(msgs, "welcome") and g.storage.f3d.held_for is None and g.storage.f3d.own_character is None,
      "L13: the client goes on with the same character (no new handshake)")
g.storage.f3d.pl_sig = None
tick(60)
pl = of_type(take(), "pl")
check(pl and pl[-1]["me"] == 3 and pl[-1]["u"] == own_unit, f"L13: the players list says the client plays that player: {pl[-1:]}")
send(zen_hello)
tick(1)
take()
F.handlers["f3d-show-3d"](lua.table_from({"player_index": 3, "input_name": "f3d-show-3d"}))
check(of_type(take(), "raise"), "L13: Ctrl+F9 in their Factorio brings Zenith to the front again (raise)")
g.storage.f3d.client.raised = None
F.handlers["f3d-show-3d"](lua.table_from({"player_index": 2, "input_name": "f3d-show-3d"}))
sent = [(item[1], json.loads(item[2].split("\n")[0])) for item in F.take_sent().values()]
check(not any(m.get("t") == "raise" for _, m in sent) and any(port == 34209 for port, _ in sent),
      f"L13: the stranger's Ctrl+F9 doesn't (their own launcher is asked to start a Zenith): {sent}")
g.storage.f3d.launch_wait = None
check(same(stranger.character, stranger_char) and stranger_char.valid, "L13: the stranger keeps their character")
# They leave: the bridge stands in for them where they were, with their things, as for a save's player.
own.teleport(lua.table_from({"x": 44.5, "y": 14.5}))
F.disconnect_player(zen)
send(zen_hello)
tick(2)
msgs = take()
stand_in = g.storage.f3d.puppet
check(stand_in and stand_in.valid and stand_in.unit_number != own_unit and g.storage.f3d.held_for == 3
      and stand_in.position.x == 44.5 and stand_in.position.y == 14.5,
      "L13: when they leave, the bridge stands in for them where they left")
check(stand_in and stand_in.get_main_inventory().get_item_count("iron-gear-wheel") == 30
      and stand_in.get_inventory(g.defines.inventory.character_armor)[1].valid_for_read,
      "L13: holding their things")
welcome = of_type(msgs, "welcome")
check(welcome and welcome[-1]["u"] == stand_in.unit_number, "L13: and the client plays the stand-in")
# Back from Factorio: their own character returns and takes it all back.
back = spawn("character", 44.5, 14.5, force="player")
F.connect_player(zen, back)
send(zen_hello)
tick(2)
check(same(g.storage.f3d.puppet, back) and not stand_in.valid and g.storage.f3d.held_for is None
      and back.get_main_inventory().get_item_count("iron-gear-wheel") == 30,
      "L13: when they come back their character takes it all back, and the client plays it")
take()
# Should 2.1 keep a logged-off character's LuaEntity valid, the bridge leaves it alone: it isn't the bridge's.
kept = F.disconnect_player(zen, True)
send(zen_hello)
tick(2)
take()
check(kept.valid and not same(g.storage.f3d.puppet, kept) and g.storage.f3d.held_for == 3,
      "L13: a logged-off character that stays valid isn't emptied or removed: the bridge stands in beside it")
F.connect_player(zen, kept)
send(zen_hello)
tick(2)
take()
check(same(g.storage.f3d.puppet, kept) and kept.get_main_inventory().get_item_count("iron-gear-wheel") == 30,
      "L13: and it takes the things back when they return")

# Factorio joined before Zenith connected: the hello's name finds them already in the game.
fresh_world()
send({"t": "hello", "v": 1, "sid": "z2", "w": 1})
tick(4)
own = g.storage.f3d.puppet
own.teleport(lua.table_from({"x": 30.5, "y": 8.5}))
own_unit = own.unit_number
send({"t": "bye"})
tick(1)
take()
zen, mine = F.create_player(1, "zen", 0.5, 0.5)
tick(120)
check(same(zen.character, mine) and not g.storage.f3d.owner_index, "L13: with no Zenith connected a player joining isn't claimed")
send({"t": "hello", "v": 1, "sid": "z3", "w": 1, "pn": "zen"})
tick(4)
take()
check(g.storage.f3d.owner_index == 1 and same(zen.character, own) and own.valid and own.unit_number == own_unit
      and own.position.x == 30.5 and not mine.valid,
      "L13: Zenith's hello naming them claims them then: they take over its character")
check(own.get_main_inventory().get_item_count("pistol") + own.get_inventory(g.defines.inventory.character_guns).get_item_count("pistol") == 2,
      "L13: claimed later, what their own character held (freeplay's kit too) all comes along")

# The switches off (`/f3d-perf zenith_join off`, `no_crash_site off`): as before L13.
fresh_world()
perf_cmd("zenith_join off")
perf_cmd("no_crash_site off")
send(zen_hello)
tick(4)
take()
own = g.storage.f3d.puppet
check(F.freeplay.disable_crashsite is None, "L13 off: freeplay's crash site left to freeplay")
zen, mine = F.create_player(1, "zen", 0.5, 0.5)
send(zen_hello)
tick(2)
take()
check(F.freeplay.crash_sites == 1 and same(zen.character, mine) and same(g.storage.f3d.puppet, own) and not g.storage.f3d.owner_index,
      "L13 off: the first player gets freeplay's crash site and a character of their own, as before")
# Should the game refuse to hand the character over, the old way: its things onto theirs, where it was.
perf_cmd("zenith_join default")
own.teleport(lua.table_from({"x": 25.5, "y": 6.5}))
own.get_main_inventory().insert(lua.table_from({"name": "iron-gear-wheel", "count": 7}))
own_at = (25.5, 6.5)
F.refuse_set_controller = True
send(dict(zen_hello, pn="zen2"))
tick(1)
zen2, mine2 = F.create_player(2, "zen2", 0.5, 0.5)
send(dict(zen_hello, pn="zen2"))
tick(2)
msgs = take()
check(same(g.storage.f3d.puppet, mine2) and not own.valid and (mine2.position.x, mine2.position.y) == own_at
      and mine2.get_main_inventory().get_item_count("iron-gear-wheel") == 7 and of_type(msgs, "welcome"),
      "L13: set_controller refused: the bridge's character's things move onto theirs, where it stood, and the client plays it")
F.refuse_set_controller = False

# Single-player with the mod: its player was created before any client, freeplay's intro is its own.
fresh_world(multiplayer=False)
sp_char = spawn("character", 0.5, 0.5, force="player")
F.make_player(sp_char)
send({"t": "hello", "v": 1, "sid": "s9", "w": 1, "pn": "player"})
tick(4)
take()
check(F.freeplay.disable_crashsite is None and not g.package.loaded["scripts.takeover"].no_crash_site(),
      "L13: single-player keeps freeplay's intro (the bridge never turns its crash site off there)")
check(same(g.storage.f3d.puppet, sp_char) and not g.storage.f3d.zenith_owner, "L13: and its player plays as before")

# Step 5 task 3a: the steps' list comes again with a full resync and with a client's new hello (a reconnect).
lua.eval("function() storage.f3d.resync_tick = -1000000 end")()
take()
send({"t": "resync", "full": 1})
tick(6)
again = steps_of(take())
tick(130)  # a welcome goes again at most every 2 s
send({"t": "hello", "v": 1, "sid": "steps-again", "w": 0})
tick(6)
rehello = steps_of(take())
# (A new world here: ids may differ, so the lists are compared by the sounds they point at.)
def step_shape(lists):
    return {k: sorted(r[1:] for r in v) for k, v in lists.items()}


check(again[1] == st_sounds and step_shape(again[2]) == step_shape(st_lists) and rehello[1] == st_sounds
      and step_shape(rehello[2]) == step_shape(st_lists) and len(again[0]) == len(st_parts) == len(rehello[0]),
      f"steps: sent again whole on a full resync and a reconnect: {len(again[0])} and {len(rehello[0])} parts")
# --- the link between add-ons and their mods (link.lua, `ext`) ------------------------------------
# A fake companion mod: it listens to the bridge's events, answers `echo` and `who`, and notes clients.
fresh_world(multiplayer=True)
g.script.active_mods["zenith-link-test"] = "0.1.0"
LINK_CH = "zenith-link-test"
lua.execute("""
LINK = {msgs = {}, clients = {}, sends = {}, first = {}}
F.companion_on(remote.call("zenith", "on_message"), function(e)
  table.insert(LINK.msgs, e)
  local d = e.data
  if type(d) == "table" and d.echo ~= nil then
    local ok, why = remote.call("zenith", "send", e.client, e.channel, {echo = d.echo})
    table.insert(LINK.sends, {ok = ok, why = why})
  elseif type(d) == "table" and d.who then
    local c = remote.call("zenith", "character", e.client)
    -- (Called from the handler: the first client's state is storage.f3d, never another's swapped in.)
    table.insert(LINK.first, storage.f3d.client.port)
    remote.call("zenith", "send", e.client, e.channel, {unit = c and c.unit_number or 0, p = e.player_index or 0})
  end
end)
F.companion_on(remote.call("zenith", "on_client"), function(e) table.insert(LINK.clients, e) end)
""")
LINK = g.LINK
ev_msg, ev_client = F.remote.zenith.on_message(), F.remote.zenith.on_client()
check(isinstance(ev_msg, int) and isinstance(ev_client, int) and ev_msg != ev_client and F.remote.zenith.link() == 1,
      f"link: the interface hands out two generated event ids and its version ({ev_msg}, {ev_client})")


def ext(d, ch=LINK_CH, port=CLIENT_PORT, machine=0, **more):
    F.packet(json.dumps({"t": "ext", "ch": ch, "d": d, **more}), port, machine)


def link_count():
    return len(list(LINK.msgs.values()))


send({"t": "hello", "v": 1, "sid": "lk", "w": 0})
tick(3)
msgs = take()
welcome = of_type(msgs, "welcome")
check(welcome and welcome[0].get("ext") == 1, f"link: the welcome says ext 1: {welcome[:1] and welcome[0].get('ext')}")
joins = [to_py(e) for e in LINK.clients.values()]
check(len(joins) == 1 and joins[0]["client"] == CLIENT_PORT and joins[0]["joined"] is True,
      f"link: a client's first hello raises on_client (joined): {joins}")
check(same(F.remote.zenith.character(), g.storage.f3d.puppet) and same(F.remote.zenith.character(CLIENT_PORT), g.storage.f3d.puppet)
      and F.remote.zenith.character(CLIENT_PORT + 99) is None,
      "link: character() as before, character(client) that client's, nil for no such client")
ext({"echo": "hi"}, machine=3)
tick(1)
got = to_py(LINK.msgs[1])
check(got and got["client"] == CLIENT_PORT and got["channel"] == LINK_CH and got["data"] == {"echo": "hi"} and got["machine"] == 3
      and got["name"] == ev_msg,
      f"link: an `ext` arrives as the event with client, channel, data and the machine it came in on: {got}")
replies = of_type(take(), "ext")
check(replies and replies[-1]["ch"] == LINK_CH and replies[-1]["d"] == {"echo": "hi"} and isinstance(replies[-1].get("k"), int),
      f"link: the mod's send reaches the client as `ext` (stamped with the tick): {replies}")
ext("a string", ch=LINK_CH + "/state/x")
ext([1, 2, 3])
tick(1)
check(link_count() == 3 and to_py(LINK.msgs[2])["channel"] == LINK_CH + "/state/x" and to_py(LINK.msgs[3])["data"] == [1, 2, 3],
      f"link: topics after the mod's name, strings and lists as data: {[to_py(m) for m in LINK.msgs.values()][1:]}")
before = link_count()
ext({"echo": 1}, ch="not-in-this-game")
ext({"echo": 1}, ch="bad channel")
ext({"echo": 1}, ch=5)
ext({"echo": 1}, ch="")
ext({"echo": 1}, ch=LINK_CH + "/" + "x" * 130)
ext({"echo": 1}, ch=LINK_CH + "/a\nb")
ext({"echo": 1}, ch="/" + LINK_CH)
F.packet(json.dumps({"t": "ext", "ch": LINK_CH}), CLIENT_PORT)  # no d
ext("x" * 4100)  # over 4 KB
ext({"echo": 1}, port=40000)  # not a connected client
tick(1)
check(link_count() == before and not of_type(take(), "ext"),
      f"link: refused, nothing raised: a mod not in the game, bad channels, no data, over 4 KB, another port ({link_count() - before})")
check(not any("Bridge error" in str(m) for m in g.F.printed.values()), "link: and none of it an error")
tick(60)
for i in range(70):
    ext({"n": i})
tick(1)
take()
check(link_count() - before == 60, f"link: a client's flood is capped at 60 messages per 60 ticks ({link_count() - before})")
tick(60)
ext({"n": 70})
tick(1)
check(link_count() - before == 61, "link: and the window opens again 60 ticks later")
before = link_count()
for i in range(10):
    ext("y" * 3900)
tick(1)
check(link_count() - before == 8, f"link: and at 32 KB per 60 ticks ({link_count() - before} of 10 near-4 KB messages)")
tick(61)
take()
results = lua.eval("""function(port)
  local out = {}
  for i = 1, 70 do
    out[#out + 1] = select(1, remote.call("zenith", "send", port, "zenith-link-test", {i = i})) and 1 or 0
  end
  local _, big = remote.call("zenith", "send", port, "zenith-link-test", string.rep("z", 4100))
  local _, chan = remote.call("zenith", "send", port, "no spaces", 1)
  local _, who = remote.call("zenith", "send", 1, "zenith-link-test", 1)
  local _, many = remote.call("zenith", "send", port, "zenith-link-test", 1)
  local _, nan = remote.call("zenith", "send", port, "zenith-link-test", 0/0)
  return {sum = out, big = big, chan = chan, who = who, many = many, nan = nan}
end""")(CLIENT_PORT)
sent_ok = sum(results.sum.values())
tick(1)
outs = of_type(take(), "ext")
check(sent_ok == 60 and len(outs) == 60 and results.many == "too many",
      f"link: send is capped at 60 a client per 60 ticks too ({sent_ok} true, {len(outs)} sent, then {results.many})")
check(results.big == "too big" and results.chan == "bad channel" and results.who == "no such client" and results.nan == "bad data",
      f"link: send refuses too big, a bad channel, no such client, data that isn't JSON: {results.big}, {results.chan}, {results.who}, {results.nan}")
# Two clients: each message names its own client, and an answer reaches only it.
tick(61)
take()
send({"t": "hello", "v": 1, "sid": "lk", "w": 1})  # the first client still there
send({"t": "hello", "v": 1, "sid": "lk2", "w": 0}, port=PORT_B)
tick(3)
take_by_port()
joins = [to_py(e) for e in LINK.clients.values()]
check(len(joins) == 2 and joins[1]["client"] == PORT_B and joins[1]["joined"] is True, f"link: a second client joins: {joins}")
b_puppet = g.storage.f3d_extra[PORT_B].puppet
ext({"who": 1}, port=PORT_B)
tick(1)
by = take_by_port()
got = to_py(LINK.msgs[link_count()])
b_ext, a_ext = of_type(by.get(PORT_B, []), "ext"), of_type(by.get(CLIENT_PORT, []), "ext")
check(got["client"] == PORT_B and b_ext and b_ext[-1]["d"]["unit"] == b_puppet.unit_number and not a_ext,
      f"link: the second client's message names it; character(client) is its character; the answer goes to it alone: {b_ext}, {a_ext}")
check(list(LINK.first.values()) == [CLIENT_PORT], f"link: a mod's handler runs with the first client's state in place: {list(LINK.first.values())}")
listed = to_py(F.remote.zenith.clients())
check([c["client"] for c in listed] == [CLIENT_PORT, PORT_B], f"link: clients() lists both, the first first: {listed}")
check(F.remote.zenith.send(PORT_B, LINK_CH, lua.table_from({"to": "b"})), "link: send to the second client")
tick(1)
by = take_by_port()
check(of_type(by.get(PORT_B, []), "ext") and not of_type(by.get(CLIENT_PORT, []), "ext"), "link: reaches only it")
send({"t": "bye"}, port=PORT_B)
tick(1)
joins = [to_py(e) for e in LINK.clients.values()]
check(len(joins) == 3 and joins[2]["client"] == PORT_B and joins[2]["joined"] is False, f"link: a goodbye raises on_client (left): {joins}")
check(F.remote.zenith.send(PORT_B, LINK_CH, 1) == (False, "no such client"), "link: and send to it is refused")
# A client that times out leaves too (raised after the tick's clients are served).
tick(700)
joins = [to_py(e) for e in LINK.clients.values()]
check(joins[-1]["client"] == CLIENT_PORT and joins[-1]["joined"] is False, f"link: a client timing out raises on_client (left): {joins[-1]}")
check(len(list(LINK.sends.values())) >= 1 and all(s.ok for s in LINK.sends.values()), "link: the echoes were sent")

# --- the link's determinism (testing agent): every storage write on the link's path inside an event ---
# Multiplayer: every peer must end each event with the same storage, and nothing between events may change
# it (a remote.call outside an event, a list carried over to the next event and lost in a save). Each
# event handler is wrapped: storage's fingerprint is taken when it returns and compared when the next one
# starts, and link.lua's list of events to raise must be empty when it returns. A companion mod's handler
# notes which event it ran in and sends from inside it.
fresh_world(multiplayer=True)
g.script.active_mods["zenith-link-test"] = "0.1.0"
lua.execute(r"""
DET = {outside = 0, left_pending = 0, events = 0, ran_in = {}, sent = {}}
local function fp(v, seen, out)
  local t = type(v)
  if t ~= "table" then
    out[#out + 1] = t .. ":" .. tostring(v)
    return
  end
  if getmetatable(v) ~= nil then  -- a LuaObject (the fake's strict tables)
    local ok, u = pcall(function() return v.unit_number end)
    out[#out + 1] = "obj:" .. tostring(ok and u or "?")
    return
  end
  if seen[v] then
    out[#out + 1] = "seen:" .. seen[v]
    return
  end
  seen.n = (seen.n or 0) + 1
  seen[v] = seen.n
  local keys = {}
  for k in pairs(v) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b) return type(a) .. tostring(a) < type(b) .. tostring(b) end)
  out[#out + 1] = "{"
  for _, k in ipairs(keys) do
    fp(k, seen, out)
    out[#out + 1] = "="
    fp(v[k], seen, out)
  end
  out[#out + 1] = "}"
end
function DET.fingerprint()
  local out = {}
  fp(storage, {}, out)
  return table.concat(out, ",")
end
local link = package.loaded["scripts.link"]
local function pending_count()
  local i = 1
  while true do
    local name, val = debug.getupvalue(link.raise, i)
    if not name then
      return -1
    elseif name == "pending" then
      return #val
    end
    i = i + 1
  end
end
DET.pending_count = pending_count
local function wrap(fn, name)
  return function(...)
    if DET.after and DET.fingerprint() ~= DET.after then
      DET.outside = DET.outside + 1
    end
    DET.in_event = name
    fn(...)
    DET.in_event = nil
    DET.events = DET.events + 1
    if pending_count() ~= 0 then
      DET.left_pending = DET.left_pending + 1
    end
    DET.after = DET.fingerprint()
  end
end
for _, name in ipairs({"on_tick", "on_udp_packet_received"}) do
  local id = defines.events[name]
  F.handlers[id] = wrap(F.handlers[id], name)
end
F.on_config = wrap(F.on_config, "on_configuration_changed")
F.companion_on(remote.call("zenith", "on_message"), function(e)
  table.insert(DET.ran_in, "msg:" .. tostring(DET.in_event))
  storage.companion_n = (storage.companion_n or 0) + 1  -- the companion's own write, inside the event
  local ok, why = remote.call("zenith", "send", e.client, e.channel, {echo = e.data})
  table.insert(DET.sent, ok and "ok" or why)
end)
F.companion_on(remote.call("zenith", "on_client"), function(e)
  table.insert(DET.ran_in, (e.joined and "join:" or "left:") .. tostring(DET.in_event))
end)
""")
DET = g.DET
check(DET.pending_count() == 0, f"link determinism: the guard finds link.lua's list of events to raise ({DET.pending_count()})")
send({"t": "hello", "v": 1, "sid": "det", "w": 0})
tick(5)
take()
check(g.storage.f3d.link is None, "link cost while unused: no link state in storage before a first ext")
# A read from outside any event (a companion's on_load, RCON) changes nothing.
DET.after = DET.fingerprint()
F.remote.zenith.link(), F.remote.zenith.on_message(), F.remote.zenith.on_client(), F.remote.zenith.clients()
F.remote.zenith.character(CLIENT_PORT), F.remote.zenith.player(CLIENT_PORT), F.remote.zenith.name(CLIENT_PORT)
F.remote.zenith.character(CLIENT_PORT + 99)
check(DET.fingerprint() == DET.after, "link determinism: the interface's reads outside an event leave storage alone")
for i in range(5):
    F.packet(json.dumps({"t": "ext", "ch": "zenith-link-test", "d": {"i": i}}), CLIENT_PORT)
F.packet("{not json", CLIENT_PORT)
F.packet(json.dumps({"t": "ext", "ch": "zenith-link-test/x", "d": None}), CLIENT_PORT)
tick(2)
check(g.storage.f3d.link is not None and g.storage.f3d.link.i == 5, f"link determinism: the caps' counters live in storage ({g.storage.f3d.link and g.storage.f3d.link.i})")
send({"t": "hello", "v": 1, "sid": "det2", "w": 0}, port=PORT_B)
tick(3)
F.packet(json.dumps({"t": "ext", "ch": "zenith-link-test", "d": "b"}), PORT_B)
tick(1)
check(g.storage.f3d_extra[PORT_B].link is not None and g.storage.f3d_extra[PORT_B].link.i == 1,
      "link determinism: a second client's counters in its own state in storage")
send({"t": "bye"}, port=PORT_B)
tick(700)  # the first client times out
F.on_config(lua.table_from({"mod_changes": {"factorio-3d-bridge": {"old_version": "0.1.1", "new_version": "0.1.3"}}}, recursive=True))
ran_in = list(DET.ran_in.values())
sent = list(DET.sent.values())
check(DET.outside == 0, f"link determinism: no storage write between events ({DET.outside} events found storage changed since the last)")
check(DET.left_pending == 0, f"link determinism: the list of events to raise is empty after every event ({DET.left_pending} of {DET.events})")
check(ran_in.count("msg:on_udp_packet_received") == 6 and all(r.split(":")[1] != "nil" for r in ran_in),
      f"link determinism: every companion handler ran inside an event: {ran_in}")
check("join:on_udp_packet_received" in ran_in and ran_in.count("left:on_udp_packet_received") == 1 and "left:on_tick" in ran_in,
      f"link determinism: joins in the hello's packet, a goodbye in its packet, a time-out in on_tick: {ran_in}")
check(sent == ["ok"] * 6, f"link determinism: a companion's send from inside its handler: {sent}")
# The guard itself: a write between events is caught.
before = DET.outside
g.storage.f3d.det_probe = 1
tick(1)
check(DET.outside == before + 1, "link determinism: (the guard catches a storage write made between events)")
g.storage.f3d.det_probe = None

# --- the link: a companion mod's error, the handshake, the bridge's own name, on_configuration_changed ---
# A companion handler that throws is the companion's error, caught per event: the game goes on, the
# error is logged naming the mod and sent back to the add-on (`ext` with `err`), the other events in
# the same raise still arrive, and 10 errors within a minute close the channel for that client's session.
fresh_world(multiplayer=True)
g.script.active_mods["zenith-link-test"] = "0.1.0"
lua.execute("""
ERR = {msgs = {}, clients = {}, boom_client = false}
F.companion_on(remote.call("zenith", "on_message"), function(e)
  if type(e.data) == "table" and e.data.boom then
    error("boom " .. tostring(e.data.boom))
  end
  table.insert(ERR.msgs, e.data)
end)
F.companion_on(remote.call("zenith", "on_client"), function(e)
  if ERR.boom_client and e.client == ERR.boom_client then
    error("on_client boom")
  end
  table.insert(ERR.clients, e)
end)
""")
ERR = g.ERR
LINK_MOD = g.package.loaded["scripts.link"]
send({"t": "hello", "v": 1, "sid": "er", "w": 0})
# An `ext` before the client's handshake is done is dropped.
ext({"early": 1})
check(len(list(ERR.msgs.values())) == 0 and g.F.printed is not None, "link: an `ext` before the client's handshake is done is dropped")
tick(5)
take()
ext({"ok": 1}, ch="factorio-3d-bridge")
ext({"ok": 1}, ch="factorio-3d-bridge/x")
tick(1)
check(len(list(ERR.msgs.values())) == 0 and LINK_MOD.channel_mod("factorio-3d-bridge") is None,
      "link: the bridge's own name isn't a channel")
check(F.remote.zenith.send(CLIENT_PORT, "factorio-3d-bridge", 1) == (False, "bad channel"), "link: nor for a mod's send")


def err_lines():
    return [str(m) for m in g.F.printed.values() if "handler failed" in str(m)]


# Three events in one raise, the middle one failing: the first and the third arrive.
logged_before = len(err_lines())
lua.eval("""function(port, ch)
  local link = package.loaded["scripts.link"]
  link.from_packet({payload = "{}", player_index = 0})
  link.receive({ch = ch, d = {n = 1}}, port)
  link.receive({ch = ch, d = {boom = 1}}, port)
  link.receive({ch = ch, d = {n = 3}}, port)
  link.raise()
end""")(CLIENT_PORT, LINK_CH)
got = [to_py(d) for d in ERR.msgs.values()]
check(got == [{"n": 1}, {"n": 3}], f"link: a companion's error loses none of the other events in that raise: {got}")
lines = err_lines()
check(len(lines) == logged_before + 1 and "zenith-link-test" in lines[-1] and "channel " + LINK_CH in lines[-1] and "boom 1" in lines[-1],
      f"link: the error is logged naming the mod and the channel: {lines[-1:]}")
errs = [m for m in of_type(take(), "ext") if "err" in m]
check(len(errs) == 1 and errs[0]["ch"] == LINK_CH and "boom 1" in errs[0]["err"] and "d" not in errs[0],
      f"link: and sent back to the add-on on its channel as `ext` with `err`: {errs}")
check(not any("Bridge error" in str(m) for m in g.F.printed.values()), "link: a companion's error isn't the bridge's")
# From a packet: the game goes on (the test runs with barrier.rethrow on: nothing reached the barrier).
for i in range(2, 10):
    ext({"boom": i})
    tick(1)
errs = [m for m in of_type(take(), "ext") if "err" in m]
check(len(errs) == 8 and not any("closed" in m["err"] for m in errs), f"link: 9 errors, each sent back, the channel still open ({len(errs)})")
ext({"n": 4})
tick(1)
check(to_py(list(ERR.msgs.values())[-1]) == {"n": 4}, "link: and still raised after 9 errors")
check(len(err_lines()) == 5, f"link: only the first few errors are logged in full ({len(err_lines())})")
ext({"boom": 10})
tick(1)
errs = [m for m in of_type(take(), "ext") if "err" in m]
check(len(errs) == 2 and "boom 10" in errs[0]["err"] and "closed after repeated errors" in errs[1]["err"] and errs[1]["ch"] == LINK_CH,
      f"link: the 10th error within a minute closes the channel, and the add-on hears so: {errs}")
check(any("is closed after repeated errors" in str(m) and LINK_CH in str(m) for m in g.F.printed.values()), "link: said in the log too")
check(g.storage.f3d.link_closed and g.storage.f3d.link_closed[LINK_CH], "link: the closed channel is in the client's state in storage")
n_before = len(list(ERR.msgs.values()))
ext({"n": 5})
ext({"boom": 11})
tick(1)
check(len(list(ERR.msgs.values())) == n_before and not of_type(take(), "ext"), "link: a closed channel's messages are dropped, quietly")
ext({"n": 6}, ch=LINK_CH + "/other")
tick(1)
check(to_py(list(ERR.msgs.values())[-1]) == {"n": 6}, "link: another channel of the same mod still works")
# A long error's text is trimmed to 1000 bytes at a character's start (é is two bytes in UTF-8).
lua.execute("""F.companion_on(remote.call("zenith", "on_message"), function(e)
  if e.data == "long" then error(string.rep("\\195\\169", 900), 0) end
end)""")
take()
ext("long", ch=LINK_CH + "/long")
tick(1)
long_err = [m for m in of_type(take(), "ext") if "err" in m]
check(len(long_err) == 1 and long_err[0]["err"].endswith("...") and set(long_err[0]["err"][:-3]) == {"é"}
      and len(long_err[0]["err"].encode("utf-8")) <= 1000, f"link: a long error trimmed at a character: {[len(m['err']) for m in long_err]}")
# Spread out: 9 errors, a minute, then a 10th: the count starts over.
for i in range(9):
    ext({"boom": i}, ch=LINK_CH + "/slow")
    tick(1)
take()
for _ in range(12):  # a minute, the client saying hello as it does
    tick(300)
    send({"t": "hello", "v": 1, "sid": "er", "w": 1})
take()
ext({"boom": 99}, ch=LINK_CH + "/slow")
tick(1)
slow = [m for m in of_type(take(), "ext") if "err" in m]
check(len(slow) == 1 and "boom 99" in slow[0]["err"] and not (g.storage.f3d.link_closed and g.storage.f3d.link_closed[LINK_CH + "/slow"]),
      f"link: 10 errors spread over more than a minute don't close it: {slow}")
# The client's next session opens it again.
send({"t": "bye"})
tick(1)
send({"t": "hello", "v": 1, "sid": "er2", "w": 0})
tick(5)
take()
ext({"n": 7})
tick(1)
check(to_py(list(ERR.msgs.values())[-1]) == {"n": 7}, "link: the client's next session opens it again")

# on_configuration_changed: the clients a new bridge dropped are raised on the first tick after it,
# not inside it (a companion's on_configuration_changed runs after the bridge's), from storage, the
# failing one losing none of the others.
send({"t": "hello", "v": 1, "sid": "er3", "w": 0}, port=PORT_B)
tick(5)
take_by_port()
left_before = [to_py(e) for e in ERR.clients.values() if not e.joined]
ERR.boom_client = CLIENT_PORT
F.on_config(lua.table_from({"mod_changes": {"factorio-3d-bridge": {"old_version": "0.1.1", "new_version": "0.1.3"}}}, recursive=True))
left_now = [to_py(e) for e in ERR.clients.values() if not e.joined]
later = g.storage.f3d_link_later
check(left_now == left_before and later is not None and len(list(later.values())) == 2,
      f"link: on_configuration_changed raises nothing; its clients' leaving waits in storage ({left_now[len(left_before):]})")
tick(1)
left_now = [to_py(e) for e in ERR.clients.values() if not e.joined]
check(g.storage.f3d_link_later is None and [e["client"] for e in left_now[len(left_before):]] == [PORT_B],
      f"link: raised on the first tick; the one whose handler failed loses none of the others: {left_now[len(left_before):]}")
ERR.boom_client = False

if BINARY:
    check({protocol.KIND_MV, protocol.KIND_BS, protocol.KIND_BFAR} <= binary_kinds,
          f"--binary: mv, bs and bfar came as binary frames: kinds {sorted(binary_kinds)}")

if failures:
    print(f"\n{len(failures)} check(s) failed")
    sys.exit(1)
print("all bridge checks passed" + (" (binary frames)" if BINARY else ""))
