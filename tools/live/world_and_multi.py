"""World, multi-client, add-on links, saves, console, barrier, and steps live checks."""
from __future__ import annotations

import json
import math
import os
import pathlib
import re
import socket
import time
import protocol
import rcon

from . import live_lib

SAVE_SUMMARY = """
local function summary(x)
  local function inv(id) local ok, i = pcall(x.get_inventory, defines.inventory[id]) return ok and i or nil end
  local main, armor, guns = inv('character_main'), inv('character_armor'), inv('character_guns')
  local n = 0
  if main then for _, it in pairs(main.get_contents()) do n = n + it.count end end
  local req, ok, pt = 0, pcall(function() return x.get_requester_point() end)
  if ok and pt then for _, sec in pairs(pt.sections) do if sec.active then for _, f in pairs(sec.filters) do if f.value and f.value.name then req = req + 1 end end end end end
  local gun = {}
  if guns then for i = 1, #guns do gun[#gun + 1] = guns[i].valid_for_read and guns[i].name or '' end end
  return { items = n, kinds = main and #main.get_contents() or 0, armor = armor and armor[1].valid_for_read and armor[1].name or '',
    guns = table.concat(gun, ','), req = req, main_size = main and #main or 0 }
end
"""



def check_decoratives(c, hello, x, y, wanted):
    """Decoratives for a client that asks (dc): the dictionary (prototypes.decorative), every
    subscribed chunk's list (find_decoratives_filtered), and the chunk again when a tile is placed
    (set_tiles with raise_event). In 2.1.23 concrete placed with remove_colliding_decoratives
    leaves grass decoratives where they are, so they are destroyed first (destroy_decoratives,
    which raises no event): the resend after the tile event must leave them out."""
    on = (1.0, dict(hello[1], dc=1))
    c.send(on[1])
    # The chunks come again in no particular order: wait until each has sent its last part.
    left = {tuple(w) for w in wanted}

    def done(m):
        if m.get("t") == "dec" and m["part"] == m["parts"]:
            left.discard((m["cx"], m["cy"]))
        return not left
    msgs = c.pump(10, every=on, until=done)
    did = {rec[1]: rec[0] for m in live_lib.of_type(msgs, "dprotos") for rec in m["l"]}
    dec = {}
    for m in live_lib.of_type(msgs, "dec"):
        dec.setdefault((m["cx"], m["cy"]), []).extend(m["l"] if isinstance(m["l"], list) else [])
    n = sum(len(v) // 4 for v in dec.values())
    live_lib.report(len(did) > 20 and len(dec) == len(wanted),
           "dc: the decorative dictionary (prototypes.decorative) and each chunk's decoratives (find_decoratives_filtered)",
           f"{len(did)} prototypes, {len(dec)} of {len(wanted)} chunks, {n} decoratives")
    name = "green-carpet-grass" if "green-carpet-grass" in did else next(iter(did), "")
    tx, ty = int(x) + 6, int(y) - 6
    out = live_lib.mod_lua(f"""
local s = storage.f3d.puppet.surface
s.create_decoratives({{ check_collision = false, decoratives = {{ {{ name = "{name}", position = {{ {tx}, {ty} }}, amount = 3 }} }} }})
rcon.print(#s.find_decoratives_filtered({{ area = {{ {{ {tx}, {ty} }}, {{ {tx} + 1, {ty} + 1 }} }} }}))
""".replace("\n", " "))
    c.pump(0.5, every=on)
    live_lib.mod_lua(f"""
local s = storage.f3d.puppet.surface
s.destroy_decoratives({{ area = {{ {{ {tx}, {ty} }}, {{ {tx} + 1, {ty} + 1 }} }} }})
s.set_tiles({{ {{ name = "concrete", position = {{ {tx}, {ty} }} }} }}, true, true, true, true)
""".replace("\n", " "))
    msgs = c.pump(1.5, every=on)
    k = (tx // 32, ty // 32)
    again = [m for m in live_lib.of_type(msgs, "dec") if (m["cx"], m["cy"]) == k]
    l = again[-1]["l"] if again and isinstance(again[-1]["l"], list) else []
    here = [l[i:i + 4] for i in range(0, len(l), 4) if (l[i + 1], l[i + 2]) == (tx - k[0] * 32, ty - k[1] * 32)]
    remaining = live_lib.mod_lua(f"rcon.print(#storage.f3d.puppet.surface.find_decoratives_filtered({{ area = {{ {{ {tx}, {ty} }}, {{ {tx} + 1, {ty} + 1 }} }} }}))")
    live_lib.report(out.strip().isdigit() and int(out) >= 1 and bool(again) and not here and remaining.strip() == "0",
           "a tile placed where decoratives were destroyed sends the chunk's decoratives again, without them",
           f"placed {out.strip()}, after the tile {remaining.strip()} left; {len(again)} dec for chunk {k}, {here}")
    c.send(hello[1])
    c.pump(0.5, every=hello)


def check_cliffs(c, hello):
    """Cliffs carry their cliff_orientation (extra.co), the piece the client draws: the nearest
    cliff's chunk is watched and its record compared with the game's."""
    out = live_lib.mod_lua("local c = storage.f3d.puppet "
                  "local e = c.surface.find_entities_filtered({ type = 'cliff', position = c.position, radius = 400, limit = 1 })[1] "
                  "if e then rcon.print(e.position.x .. ' ' .. e.position.y .. ' ' .. e.cliff_orientation) else rcon.print('none') end")
    if out == "none" or not out:
        live_lib.report(True, "cliffs: none within 400 tiles of the character, skipped")
        return
    x, y, co = out.split()
    x, y = float(x), float(y)
    cx, cy = int(x // 32), int(y // 32)
    c.send({"t": "sub", "c": []})
    c.send({"t": "sub", "c": [[cx, cy]]})
    msgs = c.pump(8, every=hello, until=lambda m: m.get("t") == "ents" and [m["cx"], m["cy"]] == [cx, cy] and m["part"] == m["parts"])
    fx, fy = int(math.floor(x * 256 + 0.5)), int(math.floor(y * 256 + 0.5))
    recs = [e for m in live_lib.of_type(msgs, "ents") for e in m["e"] if e[2] == fx and e[3] == fy and e[1] == c.proto_id("cliff")]
    live_lib.report(recs and len(recs[0]) > 5 and recs[0][5].get("co") == co, "a cliff's record carries its orientation (extra.co)",
           f"{co} at {x}, {y}: {recs[:1]}")


def check_alerts(c, hello):
    """Alerts without a player (scripts/alerts.lua, `al`): a turret with no ammo, a chest hit by the
    enemy and one destroyed, a ghost in a roboport's network that has none of its item. (The cloud
    session's check, moved to the info branch's alert kinds and entries [x, y, si, name, unit, item?].)"""
    out = live_lib.mod_lua("""local c = storage.f3d.puppet local s = c.surface local p = c.position local made = {}
local function at(name, dx, dy, force) local e = s.create_entity({ name = name, position = { p.x + dx, p.y + dy }, force = force or c.force })
  if e then made[#made + 1] = e.unit_number end return e end
at("gun-turret", 6, 6)
local hit = at("wooden-chest", 3, -5) if hit then hit.damage(10, "enemy") end
local lost = at("wooden-chest", -3, -5) if lost then lost.die("enemy") end
at("roboport", -8, 8)
local g = s.create_entity({ name = "entity-ghost", inner_name = "assembling-machine-1", position = { p.x - 12, p.y + 8 }, force = c.force })
if g then made[#made + 1] = g.unit_number end
rcon.print(table.concat(made, " "))""".replace("\n", " "))
    units = [int(u) for u in out.split() if u.isdigit()]
    # The entity scan (turrets, ghosts) runs at most every 600 ticks: start one now.
    live_lib.mod_lua('package.loaded["__factorio-3d-bridge__/scripts/alerts.lua"].reset()')
    msgs = c.pump(4.0, every=hello)
    al = live_lib.of_type(msgs, "al")
    kinds = {rec[0]: rec for rec in al[-1]["l"]} if al else {}
    live_lib.report("no_ammo" in kinds, "alerts: a turret without ammo in `al` (entity.status no_ammo)", str(kinds.get("no_ammo"))[:200])
    live_lib.report("attack" in kinds, "alerts: a chest hit by the enemy (on_entity_damaged's force)", str(kinds.get("attack"))[:200])
    live_lib.report("destroyed" in kinds, "alerts: a chest destroyed (on_entity_died)", str(kinds.get("destroyed"))[:200])
    mat = kinds.get("no_material")
    live_lib.report(bool(mat) and any(e[3] == "assembling-machine-1" for e in mat[2]),
           "alerts: a ghost in a network without its item (ghost_prototype.items_to_place_this, get_item_count)", str(mat)[:200])
    print(f"     alert kinds seen: {sorted(kinds)} (informational)")
    live_lib.destroy_units(units)


def check_multi(c, hello):
    """Two clients on one server (session.lua): the second on its own port gets its own state and
    character; each sees the other's character as a mover; bye drops only it."""
    port2 = live_lib.SECOND_CLIENT_PORT or live_lib.CLIENT_PORT + 1
    c2 = live_lib.Client(live_lib.FACTORIO_PORT, port2)
    c2.sid += "-second"
    hello2 = (1.0, {"t": "hello", "v": 1, "sid": c2.sid, "w": 1})
    c.send(hello[1])
    msgs = c2.pump(6, until=lambda m: m.get("t") == "ready", every=(1.0, {"t": "hello", "v": 1, "sid": c2.sid, "w": 0}))
    welcome = live_lib.of_type(msgs, "welcome")
    first_unit = c.me.get("u") if c.me else None
    live_lib.report(bool(welcome) and welcome[0]["u"] != first_unit and bool(live_lib.of_type(msgs, "ready")),
           "two clients: the second gets its own welcome, prototypes and character", f"{welcome[:1]}, first is {first_unit}")
    if not welcome:
        c2.sock.close()
        return
    # Earlier sections moved the first character about: put the second next to it, and both
    # clients' focus there, so each is within the other's mover radius.
    out = live_lib.mod_lua(f"local s = storage.f3d_extra[{port2}] local a = storage.f3d.puppet "
                  "local p = a.surface.find_non_colliding_position('character', { a.position.x + 3, a.position.y }, 10, 0.5) or a.position "
                  "s.puppet.teleport(p, a.surface) rcon.print(p.x .. ' ' .. p.y)")
    try:
        x, y = (float(v) for v in out.split())
    except ValueError:
        x, y = welcome[0]["x"] / 256, welcome[0]["y"] / 256
    c2.send({"t": "sub", "c": [[int(x // 32), int(y // 32)]]})
    c2.send({"t": "focus", "x": int(x * 256), "y": int(y * 256), "r": 48})
    c.send({"t": "focus", "x": int(x * 256), "y": int(y * 256), "r": 48})
    c2.send(hello2[1])
    msgs2 = c2.pump(3, every=hello2)
    msgs1 = c.pump(1.0, every=hello)
    live_lib.report(bool(live_lib.of_type(msgs2, "chunk")) and not live_lib.of_type(msgs1, "welcome"), "the second gets its chunks; the first carries on without a new handshake")
    seen1 = {r[0] for m in live_lib.of_type(msgs1, "mv") for r in m["l"]}
    seen2 = {r[0] for m in live_lib.of_type(msgs2, "mv") for r in m["l"]}
    live_lib.report(welcome[0]["u"] in seen1 and first_unit in seen2, "each sees the other's character as a mover",
           f"{welcome[0]['u']} in first: {welcome[0]['u'] in seen1}, {first_unit} in second: {first_unit in seen2}")
    status = rcon.run("/f3d-status")
    live_lib.report(f"another client on port {port2}" in status, "/f3d-status lists the second client", status.replace("\n", " | ")[:300])
    c2.send({"t": "bye"})
    c2.pump(0.5)
    c2.sock.close()
    out = live_lib.mod_lua("local n = 0 for _ in pairs(storage.f3d_extra or {}) do n = n + 1 end local p = 0 "
                  "for sid, ch in pairs(storage.f3d_parked or {}) do if ch.valid then p = p + 1 ch.destroy() end end "
                  "storage.f3d_parked = {} rcon.print(n .. ' ' .. p)")
    live_lib.report(out == "0 1", "bye drops the second client and parks its character for its return", out)
    c.pump(0.5, every=hello)


LINK_CH = "zenith-link-test"


def link_get():
    try:
        return json.loads(rcon.run('/c rcon.print(remote.call("linktest", "get"))').strip())
    except ValueError:
        return {}


def check_link(c, hello, welcome):
    """The add-on link (link.lua, PROTOCOL.md "Messages for add-ons and their mods") against the fixture mod
    tools/mod_tests/fixtures/zenith-link-test, which answers on its channel through remote.call("zenith", ...)."""
    live_lib.report(welcome.get("ext") == 1, "link: the welcome says ext 1", str(welcome.get("ext")))
    if LINK_CH not in welcome.get("mods", {}):
        print(f"  (the fixture mod {LINK_CH} isn't on this server: copy tools/mod_tests/fixtures/{LINK_CH} into its mods)")
        live_lib.report(False, "link: the fixture mod is in the game", str(sorted(welcome.get("mods", {}))))
        return
    rcon.run('/c remote.call("linktest", "reset")')
    state = link_get()
    print(f"  the fixture mod came by {state.get('came_by')}; the bridge's link() says {state.get('link')}")
    live_lib.report(state.get("came_by") in ("on_init", "on_load") and state.get("link") == 1,
           "link: the fixture mod found the bridge's interface and registered for its events", str(state))

    def replies(seconds, until=None):
        return [m for m in live_lib.of_type(c.pump(seconds, every=hello, until=until), "ext") if m.get("ch", "").startswith(LINK_CH)]

    token = f"t{int(time.time())}"
    t0 = time.time()
    c.send({"t": "ext", "ch": LINK_CH, "d": {"echo": token}})
    got = replies(3.0, until=lambda m: m.get("t") == "ext" and m.get("d") == {"echo": token})
    took = time.time() - t0
    live_lib.report(any(m.get("d") == {"echo": token} for m in got), "link: an echo there and back", f"{took * 1000:.0f} ms")
    c.send({"t": "ext", "ch": LINK_CH + "/who", "d": {"who": 1}})
    who = [m["d"] for m in replies(3.0, until=lambda m: m.get("ch") == LINK_CH + "/who")]
    me_unit = c.me.get("u") if c.me else None
    live_lib.report(who and who[-1].get("client") == live_lib.CLIENT_PORT and who[-1].get("unit") == me_unit,
           "link: who names this client and its character (character(client))", f"{who[-1:]} me {me_unit}")
    before = link_get().get("n", 0)
    c.send({"t": "ext", "ch": "bad channel", "d": {"echo": 1}})
    c.send({"t": "ext", "ch": LINK_CH})
    c.send({"t": "ext", "ch": "zenith-not-a-mod-here", "d": {"echo": 1}})
    c.send({"t": "ext", "ch": LINK_CH, "d": {"echo": "x" * 4100}})
    bad = replies(1.5)
    live_lib.report(not bad and link_get().get("n", 0) == before, "link: a bad channel, no data, a mod not in the game and over 4 KB dropped",
           f"{len(bad)} answers, {link_get().get('n', 0) - before} raised")
    c.pump(1.2, every=hello)  # a fresh window of 60 ticks
    c.send({"t": "ext", "ch": LINK_CH + "/flood", "d": {"flood": 100}})
    flood = replies(3.0)
    state = link_get()
    live_lib.report(state.get("flood") == 60 and len(flood) == 60, "link: a mod's flood of 100 stops at the cap (60 per 60 ticks)",
           f"send took {state.get('flood')}, {len(flood)} arrived")
    c.pump(1.2, every=hello)
    c.send({"t": "ext", "ch": LINK_CH, "d": {"big": 1}})
    c.pump(1.0, every=hello)
    live_lib.report(link_get().get("big") == "too big", "link: a message over 4 KB is refused (too big)", str(link_get().get("big")))
    c.pump(1.2, every=hello)
    before = link_get().get("n", 0)
    for i in range(80):
        c.send({"t": "ext", "ch": LINK_CH, "d": {"n": i}})
    c.pump(1.0, every=hello)
    took_in = link_get().get("n", 0) - before
    live_lib.report(took_in == 60, "link: a client's flood of 80 in a moment: 60 raised (the cap in)", str(took_in))
    # A second client: its own messages, its own character, answered alone; its coming and going raised.
    port2 = live_lib.SECOND_CLIENT_PORT or live_lib.CLIENT_PORT + 1
    c2 = live_lib.Client(live_lib.FACTORIO_PORT, port2)
    c2.sid += "-link"
    c.send(hello[1])
    msgs = c2.pump(6, until=lambda m: m.get("t") == "ready", every=(1.0, {"t": "hello", "v": 1, "sid": c2.sid, "w": 0}))
    w2 = live_lib.of_type(msgs, "welcome")
    if w2:
        hello2 = (1.0, {"t": "hello", "v": 1, "sid": c2.sid, "w": 1})
        c2.send({"t": "ext", "ch": LINK_CH + "/who", "d": {"who": 1}})
        who2 = [m["d"] for m in live_lib.of_type(c2.pump(3.0, every=hello2, until=lambda m: m.get("t") == "ext"), "ext")]
        first = replies(1.0)
        live_lib.report(who2 and who2[-1].get("client") == port2 and who2[-1].get("unit") == w2[0]["u"] and not first,
               "link: a second client's who names it and its character, answered to it alone", f"{who2[-1:]}, first got {len(first)}")
        c2.send({"t": "bye"})
        c2.pump(0.5)
        joined = [(e.get("client"), e.get("joined")) for e in link_get().get("clients", [])]
        live_lib.report((port2, True) in joined and (port2, False) in joined, "link: the second client's coming and going raised on_client", str(joined))
        live_lib.mod_lua("for sid, ch in pairs(storage.f3d_parked or {}) do if ch.valid then ch.destroy() end end storage.f3d_parked = {} rcon.print('ok')")
    else:
        live_lib.report(False, "link: a second client connects")
    c2.sock.close()
    if state.get("came_by") != "on_load":
        print("  (this run's game started the fixture mod with on_init: /server-save, restart the server on that save and run"
              " --only link again to check the on_load path)")
    c.pump(0.5, every=hello)


SPRINT_CH = "zenith-sprint"


def check_sprint(c, hello):
    """The sprint pair's Factorio side (addons-src/sprint/mod/zenith-sprint, which must be in the server's mods),
    played as its add-on would: {on: true} on "zenith-sprint" adds the map setting's bonus (0.5) to this client's
    character's running speed once, however often it is said; {on: false} takes it off; 90 ticks without a word
    take it off too (a client dropping mid-sprint); what another mod adds to the modifier meanwhile survives;
    messages the mod doesn't expect change nothing. Then the link's own robustness: garbage `ext`, a stranger's
    port, an `ext` sent right after a new client's hello."""
    unit = c.me.get("u") if c.me else None
    has = rcon.run('/c rcon.print(script.active_mods["zenith-sprint"] and "yes" or "no")').strip()
    if has != "yes" or not unit:
        live_lib.report(False, "sprint: the zenith-sprint mod is in the game and this client has a character", f"{has}, unit {unit}")
        return
    char = f"game.get_entity_by_unit_number({unit})"

    def mod():
        out = rcon.run(f"/c local e = {char} rcon.print(e and e.valid and e.character_running_speed_modifier or 'gone')").strip()
        try:
            return round(float(out), 4)
        except ValueError:
            return out

    def say(d, seconds=0.3):
        c.send({"t": "ext", "ch": SPRINT_CH, "d": d})
        c.pump(seconds, every=hello)

    rcon.run(f"/c {char}.character_running_speed_modifier = 0.25")  # another mod's change, made before
    base = mod()
    say({"on": True})
    on = mod()
    for _ in range(6):  # the add-on says it again every half second while the key is held
        say({"on": True}, 0.5)
    held = mod()
    live_lib.report(base == 0.25 and on == 0.75 and held == 0.75, "sprint: on adds the bonus once, held for 3 s it stays",
           f"before {base}, on {on}, held {held}")
    rcon.run(f"/c local e = {char} e.character_running_speed_modifier = e.character_running_speed_modifier + 0.1")
    say({"on": False})
    off = mod()
    live_lib.report(off == 0.35, "sprint: off takes only its own bonus back (another mod's +0.25 and +0.1 made meanwhile survive)", str(off))
    for bad in ({"on": "yes"}, {"on": 1}, [True], "on", {"off": True}, {"on": None}):
        say(bad, 0.1)
    c.send({"t": "ext", "ch": SPRINT_CH + "/x", "d": {"on": True}})
    c.pump(0.4, every=hello)
    live_lib.report(mod() == 0.35, "sprint: messages it doesn't expect (and another topic) change nothing", str(mod()))
    say({"on": True})
    started = time.time()
    c.pump(0.9, every=hello)
    mid = mod()
    c.pump(1.2, every=hello)  # 90 ticks and the 15-tick check after the last word
    after = mod()
    live_lib.report(mid == 0.85 and after == 0.35, "sprint: 90 ticks without a word end the sprint by itself",
           f"{mid} after 0.9 s, {after} after {time.time() - started:.1f} s")
    # A client dropping mid-sprint: a goodbye, then nothing more from it.
    say({"on": True})
    dropped_on = mod()
    c.send({"t": "bye"})
    c.pump(2.2)
    gone = mod()
    live_lib.report(dropped_on == 0.85 and gone == 0.35, "sprint: a client dropping mid-sprint: the bonus off within 90 ticks",
           f"{dropped_on} then {gone}")
    rcon.run(f"/c local e = {char} if e then e.character_running_speed_modifier = 0 end")
    # Back again, for the link's robustness.
    msgs = c.pump(6, until=lambda m: m.get("t") == "ready", every=(1.0, {"t": "hello", "v": 1, "sid": c.sid, "w": 0}))
    live_lib.report(live_lib.of_type(msgs, "welcome"), "sprint: the client comes back after its goodbye")
    c.pump(0.5, every=hello)
    rcon.run('/c remote.call("linktest", "reset")')
    garbage = [
        {"t": "ext"}, {"t": "ext", "ch": None, "d": 1}, {"t": "ext", "ch": [], "d": 1}, {"t": "ext", "ch": {"a": 1}, "d": 1},
        {"t": "ext", "ch": LINK_CH, "d": {}}, {"t": "ext", "ch": LINK_CH, "d": 1e308}, {"t": "ext", "ch": LINK_CH, "d": -0.0},
        {"t": "ext", "ch": LINK_CH + "/é", "d": "ü"}, {"t": "ext", "ch": LINK_CH + "/", "d": 1},
        {"t": "ext", "ch": LINK_CH, "d": {"a": {"b": {"c": {"d": [[[[[[[[1]]]]]]]]}}}}},
        {"t": "ext", "ch": LINK_CH, "d": 1, "extra": "field", "r": 5}, {"t": "ext", "ch": "/", "d": 1},
        {"t": "ext", "ch": "../" + LINK_CH, "d": 1}, {"t": "ext", "ch": "level", "d": 1}, {"t": "ext", "ch": "base", "d": 1},
        {"t": "ext", "ch": "factorio-3d-bridge", "d": {"echo": "to the bridge"}},
    ]
    for m in garbage:
        c.send(m)
    deep = "[" * 3000 + "]" * 3000
    c.sock.sendto(('{"t":"ext","ch":"' + LINK_CH + '","d":' + deep + "}").encode(), c.dest)
    c.sock.sendto(b'{"t":"ext","ch":"zenith-link-test","d":', c.dest)
    c.sock.sendto(b"\xff\xfe\x00garbage", c.dest)
    c.pump(1.0, every=hello)
    got = link_get()
    print(f"  INFO: of the garbage, {got.get('n')} reached the fixture mod (the ones with its channel and data)")
    live_lib.report(isinstance(got.get("n"), int) and got.get("n") <= 9, "link: garbage `ext` neither errors nor reaches a mod it isn't for",
           str(got.get("n")))
    status = rcon.run("/f3d-status")
    live_lib.report("ERROR" not in status, "link: and no step failed", status.replace("\n", " | ")[:300])
    # A stranger's port (no hello) is dropped; an `ext` right after a new client's hello, before its welcome.
    rcon.run('/c remote.call("linktest", "reset")')
    stranger = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    stranger.bind(("127.0.0.1", 0))
    for _ in range(5):
        stranger.sendto(json.dumps({"t": "ext", "ch": LINK_CH, "d": {"echo": "stranger"}}).encode(), c.dest)
    c.pump(0.6, every=hello)
    live_lib.report(link_get().get("n") == 0, "link: an `ext` from a port that never said hello is dropped", str(link_get().get("n")))
    port3 = (live_lib.SECOND_CLIENT_PORT or live_lib.CLIENT_PORT + 1) + 1
    c3 = live_lib.Client(live_lib.FACTORIO_PORT, port3)
    c3.sid += "-early"
    c3.send({"t": "hello", "v": 1, "sid": c3.sid, "w": 0})
    c3.send({"t": "ext", "ch": LINK_CH, "d": {"echo": "early"}})
    msgs = c3.pump(6, until=lambda m: m.get("t") == "ready", every=(1.0, {"t": "hello", "v": 1, "sid": c3.sid, "w": 0}))
    early = [m for m in live_lib.of_type(msgs, "ext") if m.get("d") == {"echo": "early"}]
    w3 = live_lib.of_type(msgs, "welcome")
    order = [m.get("t") for m in msgs if m.get("t") in ("welcome", "ext")]
    print(f"  INFO: an `ext` sent with a new client's first hello: {len(early)} echo back, order {order[:4]}")
    live_lib.report(w3 and link_get().get("n", 0) == 0 and not early, "link: an `ext` before the client's handshake is done is dropped",
           f"raised {link_get().get('n')}, welcome {bool(w3)}")
    c3.send({"t": "bye"})
    c3.pump(0.5)
    c3.sock.close()
    stranger.close()
    # A companion's own bug: its handler fails. The bridge catches it (a client's packet never stops the
    # game), sends the error back on the channel (`ext` with `err`) and logs it naming the mod; it isn't
    # the bridge's error. (A separate topic, so the channel's 10-errors close can't touch the others.)
    rcon.run('/c remote.call("linktest", "reset")')
    c.send({"t": "ext", "ch": LINK_CH + "/boom", "d": {"boom": 1}})
    errs = [m for m in live_lib.of_type(c.pump(1.0, every=hello), "ext") if "err" in m]
    c.send({"t": "ext", "ch": LINK_CH, "d": {"echo": "after boom"}})
    after = [m for m in live_lib.of_type(c.pump(2.0, every=hello), "ext") if m.get("d") == {"echo": "after boom"}]
    status = rcon.run("/f3d-status")
    tick = rcon.run("/c rcon.print(game.tick)").strip()
    print(f"  INFO: after a companion's handler failed: the game at tick {tick}, err {[m.get('err', '')[:160] for m in errs]},"
          f" an echo after it {'came' if after else 'did not come'};"
          f" /f3d-status: {' | '.join(l for l in status.splitlines() if 'ERROR' in l)[:300] or 'no error'}")
    live_lib.report(len(errs) == 1 and errs[0].get("ch") == LINK_CH + "/boom" and "boom" in errs[0].get("err", "") and "d" not in errs[0],
           "link: a companion's failing handler: its error comes back to the add-on on its channel", str(errs)[:300])
    live_lib.report(tick.isdigit() and after and "step 'link'" not in status,
           "link: and the game and the link go on (the next message answered, no bridge error)", f"tick {tick}, echo {bool(after)}")
    # Ten errors on one channel within a minute close it for this client's session: the first boom above
    # and nine more. The tenth's own error comes back, then one saying it closed; after that the channel's
    # messages (a boom, an echo) are dropped quietly, while the mod's other topics still answer.
    boom_ch = LINK_CH + "/boom"
    msgs = []
    for _ in range(9):
        c.send({"t": "ext", "ch": boom_ch, "d": {"boom": 1}})
        msgs += c.pump(0.1, every=hello)
    msgs += c.pump(1.0, every=hello)
    errs = [m for m in live_lib.of_type(msgs, "ext") if "err" in m and m.get("ch") == boom_ch]
    closed = [m for m in errs if "closed" in m.get("err", "")]
    booms = [m for m in errs if "boom" in m.get("err", "")]
    print(f"  INFO: nine more booms: {len(booms)} boom errors, closing err {[m.get('err') for m in closed]}")
    live_lib.report(len(booms) == 9 and len(closed) == 1 and errs[-1] is closed[0] and "10 within 60 s" in closed[0].get("err", ""),
           "link: the tenth error within a minute closes the channel and says so once, last", str([m.get("err", "")[:60] for m in errs])[:300])
    n_before = link_get().get("n", 0)
    c.send({"t": "ext", "ch": boom_ch, "d": {"boom": 1}})
    c.send({"t": "ext", "ch": boom_ch, "d": {"echo": "closed?"}})
    c.send({"t": "ext", "ch": LINK_CH, "d": {"echo": "still open"}})
    msgs = live_lib.of_type(c.pump(2.0, every=hello), "ext")
    on_closed = [m for m in msgs if m.get("ch") == boom_ch]
    still = [m for m in msgs if m.get("d") == {"echo": "still open"}]
    raised_n = link_get().get("n", 0) - n_before
    status = rcon.run("/f3d-status")
    live_lib.report(not on_closed and still and raised_n == 1 and "step 'link'" not in status,
           "link: then the closed channel drops quietly (nothing raised or sent), the mod's other topic still answers",
           f"on the closed channel {on_closed}, other topic {bool(still)}, raised {raised_n}")
    barrier_forget = live_lib.mod_lua("local b = package.loaded['__factorio-3d-bridge__/scripts/barrier.lua'] "
                             "if b and b.forget then b.forget('link') b.forget('packet') end rcon.print('ok')")
    live_lib.mod_lua("for sid, ch in pairs(storage.f3d_parked or {}) do if ch.valid then ch.destroy() end end storage.f3d_parked = {} rcon.print('ok')")
    c.pump(0.5, every=hello)


def check_remnants(c, hello):
    """Remnants (extra.rm): a destroyed assembler's and rail's remnants come as an `add` naming
    what left them, a chunk snapshot carries them too, building over them removes them in the
    game (the client drops those itself), and a linked belt's record carries its end (extra.u)."""
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "remnants: no clean spot to build on")
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    ax, ay = math.floor(x) + 6.5, math.floor(y) + 0.5
    rx, ry = 2 * math.floor(x / 2) - 6, 2 * math.floor(y / 2) + 1  # rails sit on the 2x2 grid
    live_lib.mod_lua(f"""
local s = storage.f3d.puppet.surface
storage.f3d_rm_am = s.create_entity({{ name = 'assembling-machine-1', position = {{ {ax}, {ay} }}, force = 'player', raise_built = true }})
storage.f3d_rm_rail = s.create_entity({{ name = 'straight-rail', position = {{ {rx}, {ry} }}, force = 'player', raise_built = true }})
rcon.print('ok')""".replace("\n", " "))
    c.pump(1.0, every=hello)
    live_lib.mod_lua("storage.f3d_rm_am.die() storage.f3d_rm_rail.die() rcon.print('ok')")
    msgs = c.pump(3.0, every=hello)
    adds = [m["e"] for m in live_lib.of_type(msgs, "add")]
    am, am_rm = c.proto_id("assembling-machine-1"), c.proto_id("assembling-machine-1-remnants")
    got = [e for e in adds if e[1] == am_rm]
    live_lib.report(got and len(got[0]) > 5 and got[0][5].get("rm") == am,
           "a destroyed assembler's remnants come as an add naming it (extra.rm)", str(got[:1]))
    rail_rm = [e for e in adds if c.protos.get(e[1], ("", ""))[1] == "rail-remnants"]
    live_lib.report(rail_rm and len(rail_rm[0]) > 5 and rail_rm[0][5].get("rm") == c.proto_id("straight-rail"),
           "a destroyed rail's remnants come as an add naming it", str(rail_rm[:1]))
    # A fresh snapshot of the chunk carries the remnants too (corpses are looked up by name).
    cx, cy = int(ax // 32), int(ay // 32)
    c.send({"t": "resync", "full": 0, "c": [[cx, cy]]})
    msgs = c.pump(6, every=hello, until=lambda m: m.get("t") == "ents" and [m["cx"], m["cy"]] == [cx, cy] and m["part"] == m["parts"])
    snap = [e for m in live_lib.of_type(msgs, "ents") for e in m["e"] if e[1] == am_rm]
    live_lib.report(snap and snap[0][5].get("rm") == am, "a chunk snapshot carries remnants", str(snap[:1]))
    # Building over remnants removes them in the game, without an event.
    out = live_lib.mod_lua(f"""
local s = storage.f3d.puppet.surface
local e = s.create_entity({{ name = 'assembling-machine-1', position = {{ {ax}, {ay} }}, force = 'player', raise_built = true }})
local left = s.count_entities_filtered({{ position = {{ {ax}, {ay} }}, radius = 1, name = 'assembling-machine-1-remnants' }})
if e then e.destroy() end
rcon.print(tostring(left))""".replace("\n", " "))
    live_lib.report(out == "0", "building over remnants removes them in the game (the client drops them on the add)", out)
    # A linked belt's end (linked_belt_type).
    out = live_lib.mod_lua(f"""
local world = package.loaded['__factorio-3d-bridge__/scripts/world.lua']
local s = storage.f3d.puppet.surface
local e = s.create_entity({{ name = 'linked-belt', position = {{ {ax}, {ay + 4} }}, force = 'player' }})
if not e then rcon.print('none') return end
e.linked_belt_type = 'output'
rcon.print(helpers.table_to_json(world.record(e)))
e.destroy()""".replace("\n", " "))
    live_lib.report(out.startswith("[") and '"u":"o"' in out, "a linked belt's record carries its end (extra.u)", out)


def check_mod_graphics(c, hello, welcome):
    """Mods' graphics (docs/MOD-GRAPHICS-PLAN.md): the data stage's list in a mod-data prototype
    (prototypes.mod_data, LuaModData.get), named in the welcome with the game's mods, sent in
    parts on `gfx`. Run with the fixture mod tools/mod_tests/fixtures/zenith-gfx-test in the
    server's mods to check its own entries; without it only the base game's are checked."""
    mods = welcome.get("mods", {})
    live_lib.report(isinstance(mods, dict) and mods.get("base") and mods.get("factorio-3d-bridge"),
           "modgfx: the welcome lists the game's mods (script.active_mods)", str(mods)[:200])
    fp, n = welcome.get("gf"), welcome.get("gn")
    live_lib.report(isinstance(fp, str) and isinstance(n, int) and n > 0, "modgfx: the welcome names the graphics list", f"gf={fp} gn={n}")
    if not fp:
        return
    out = live_lib.mod_lua('local p = prototypes.mod_data["zenith-graphics"] rcon.print(p.data_type .. " " .. p.get("n") .. " " .. p.get("b") .. " " .. p.get("fp"))')
    live_lib.report(out.split()[1:2] == [str(n)] and out.split()[3:4] == [fp] and out.startswith("zenith-graphics "),
           "modgfx: prototypes.mod_data has the list, read with LuaModData.get", out)
    t0 = time.time()
    c.send({"t": "gfx", "fp": fp})
    got = {}
    msgs = c.pump(20, every=hello, until=lambda m: m.get("t") == "gfx" and (got.__setitem__(m["part"], m) or len(got) == n))
    took = time.time() - t0
    live_lib.report(len(got) == n, "modgfx: every part arrives", f"{len(got)}/{n} parts in {took:.2f} s")
    total = sum(len(json.dumps(m["d"], separators=(",", ":"))) for m in got.values())
    icons, tiles, decor, ents = {}, {}, {}, {}
    for m in got.values():
        ents.update(m["d"].get("ents", {}))
        for kind, names in m["d"].get("icons", {}).items():
            icons.setdefault(kind, {}).update(names)
        tiles.update(m["d"].get("tiles", {}))
        decor.update(m["d"].get("decor", {}))
    counts = {k: len(v) for k, v in icons.items()}
    print(f"  list: {n} parts, {total} bytes; icons {counts}; {len(tiles)} tiles, {len(decor)} decoratives, {len(ents)} entities' pictures")
    live_lib.report(icons.get("item", {}).get("iron-plate") == [["__base__/graphics/icons/iron-plate.png", 64, None, None, None]],
           "modgfx: the iron plate's icon", str(icons.get("item", {}).get("iron-plate")))
    live_lib.report(tiles.get("grass-1", {}).get("main") and tiles.get("water", {}).get("water") == 1,
           "modgfx: grass's variants and water's mask", str(tiles.get("water"))[:200])
    live_lib.report(len(decor) > 20, "modgfx: decoratives", str(len(decor)))
    c.send({"t": "gfx", "fp": fp, "need": [n]})
    again = [m["part"] for m in live_lib.of_type(c.pump(2.0, every=hello), "gfx")]
    live_lib.report(again == [n], "modgfx: a part asked for again", str(again))
    c.send({"t": "gfx", "fp": "0000000000000000"})
    live_lib.report(not live_lib.of_type(c.pump(1.5, every=hello), "gfx"), "modgfx: nothing for another fingerprint")
    if "zenith-gfx-test" not in mods:
        print("  (the fixture mod isn't on this server: its own entries not checked)")
        return
    t = "__zenith-gfx-test__/graphics/"
    live_lib.report(icons.get("item", {}).get("zenith-test-gizmo") == [[t + "icons/gizmo.png", 64, None, None, None]],
           "modgfx: the fixture's item icon", str(icons.get("item", {}).get("zenith-test-gizmo")))
    tinted = icons.get("item", {}).get("zenith-test-tinted") or []
    live_lib.report(len(tinted) == 2 and tinted[1][2] == [0, 1, 0, 1], "modgfx: its tinted layer, 0-255 read as 0-1", str(tinted))
    live_lib.report(tiles.get("zenith-test-floor", {}).get("mat") == [t + "terrain/floor.png", 4, 0.5]
           and tiles["zenith-test-floor"].get("layer") == 60, "modgfx: the fixture's tile", str(tiles.get("zenith-test-floor")))
    live_lib.report(ents.get("zenith-test-crate") == {"n": [[t + "entity/crate.png", 0, 0, 128, 160, 0.5, 0, -0.25, None]]},
           "modgfx: the fixture chest's picture at rest, its shadow layer left out", str(ents.get("zenith-test-crate")))
    spin = ents.get("zenith-test-spinner", {})
    live_lib.report(spin.get("n") == [[t + "entity/spinner.png", 0, 0, 128, 128, 0.5, 0, 0, None, {"f": 4, "l": 4, "s": 0.25, "x": 0, "y": 0}]]
           and (spin.get("kn") or [[None] * 10])[0][0] == t + "entity/spinner-lamp.png" and spin["kn"][0][9].get("f") == 2,
           "modgfx: an animated machine's frames and what it shows while working", str(spin)[:300])
    peb = decor.get("zenith-test-pebbles", {})
    live_lib.report(len(peb.get("pics", [])) == 4 and peb["pics"][3][1] == 192, "modgfx: the fixture's decorative, 4 variations",
           str(peb)[:200])


def check_save(c, hello):
    """Run against a copy of a save someone played (server/saves/<copy>.zip): the bridge takes over
    that player's character, with its inventory, armour, guns, logistic requests and quickbar, and
    reads logistic chests' requests from every section."""
    players = json.loads(live_lib.mod_lua("local t = {} for _, p in pairs(game.players) do t[#t + 1] = p.name end "
                                 "rcon.print(helpers.table_to_json(t))") or "[]")
    if not players:
        live_lib.report(True, "save: no players in this save, so nothing to take over (a new map)")
        return
    # Hand everything back, measure the player, then take over again.
    rcon.run("/f3d-player none")
    owner = rcon.run("/f3d-player").strip()
    before = json.loads(live_lib.mod_lua(SAVE_SUMMARY + "local p = game.get_player(" + json.dumps(players[0]) + ") "
                                "rcon.print(helpers.table_to_json(summary(p)))"))
    lines = rcon.run("/f3d-player " + players[0])
    after = json.loads(live_lib.mod_lua(SAVE_SUMMARY + "local c = storage.f3d.puppet local p = game.get_player(" + json.dumps(players[0]) + ") "
                               "local o = summary(p) local s = summary(c) "
                               "s.left = o.items s.held = storage.f3d.held_for or 0 s.dx = c.position.x - p.physical_position.x "
                               "s.dy = c.position.y - p.physical_position.y s.surface = c.surface.name s.psurface = p.physical_surface.name "
                               "rcon.print(helpers.table_to_json(s))"))
    live_lib.report(before["items"] > 0 and after["items"] >= before["items"] and after["left"] == 0 and after["held"] > 0,
           f"save: the bridge stands in for {players[0]} with their inventory",
           f"{before['items']} items in {before['kinds']} kinds before, stand-in has {after['items']}, {after['left']} left with the player")
    # (A logged-off player's main inventory keeps the slots it had while wearing the armour until
    # they log in, so only the stand-in's size is meaningful.)
    live_lib.report(after["armor"] == before["armor"] and after["guns"] == before["guns"],
           "save: their armour (with its inventory bonus) and guns too",
           f"armour {after['armor']!r}, guns {after['guns']!r}, {after['main_size']} main slots")
    live_lib.report(after["req"] == before["req"], "save: their logistic requests, every section", f"{before['req']} -> {after['req']}")
    live_lib.report(abs(after["dx"]) < 8 and abs(after["dy"]) < 8 and after["surface"] == after["psurface"],
           "save: standing where their character was", f"{after['surface']} offset {after['dx']:.1f}, {after['dy']:.1f}")
    # The client sees it: a new handshake names the stand-in, then its slots, requests and quickbar.
    msgs = c.pump(8, every=hello, until=lambda m: m.get("t") == "ready")
    msgs += c.pump(3, every=hello)
    slots = live_lib.of_type(msgs, "slots")
    main = slots[-1]["l"].get("main", []) if slots else []
    count = sum(s[1] for s in main if s)
    live_lib.report(count == after["items"], "save: the client's inventory window gets those slots", f"{count} items in slots")
    clog = live_lib.of_type(msgs, "clog")
    live_lib.report(clog and len(clog[-1]["l"]) == after["req"], "save: the client gets the requests (clog)",
           f"{len(clog[-1]['l']) if clog else 'no clog'} requests, trash unrequested {clog[-1].get('trash') if clog else '?'}")
    qb = live_lib.of_type(msgs, "qb")
    want = live_lib.mod_lua("local p = game.get_player(" + json.dumps(players[0]) + ") local t = {} for i = 1, 100 do "
                   "local ok, s = pcall(p.get_quick_bar_slot, math.ceil(i / 10), (i - 1) % 10 + 1) "
                   "local n = ok and s and s.filter and s.filter.name or '' if type(n) ~= 'string' then n = n.name end t[i] = n end "
                   "rcon.print(table.concat(t, ','))")
    live_lib.report(qb and ",".join(qb[-1]["l"]) == want, "save: the quickbar is the player's",
           f"{sum(1 for x in qb[-1]['l'] if x) if qb else 0} slots set, page {qb[-1].get('p') if qb else '?'}")
    # The map's surface switcher: every planet with a surface and the force's platforms, and
    # another surface's charts and tags by its index.
    surfs = live_lib.of_type(msgs, "surfs")
    listed = surfs[-1]["l"] if surfs else []
    names = [r[3] or r[2] for r in listed]
    live_lib.report(len(listed) >= 2 and after["surface"] in [r[1] for r in listed], "save: the map can switch between surfaces (surfs)",
           ", ".join(names))
    others = [r[1] for r in listed if r[2] == "" and r[3] == ""]
    live_lib.report(all(r[4] == 0 for r in listed if r[2] == "" and r[3] == ""), "save: surfaces that are no planet nor platform listed as Other",
           ", ".join(others) or "none in this save")
    other = next((r for r in listed if r[1] != after["surface"] and r[2]), None) or next((r for r in listed if r[1] != after["surface"]), None)
    if other:
        c.send({"t": "map", "cx1": -6, "cy1": -6, "cx2": 5, "cy2": 5, "res": 8, "si": other[0]})
        got = c.pump(4, every=hello)
        charts = [m for m in live_lib.of_type(got, "chart") if m.get("si") == other[0]]
        here = [m for m in live_lib.of_type(got, "chart") if m.get("si") != other[0]]
        tags = [m for m in live_lib.of_type(got, "tags") if m.get("si") == other[0]]
        live_lib.report(charts and any(m["n"] > 0 for m in charts) and not here and tags,
               f"save: the map shows {other[3] or other[2]} from {after['surface']} (map with si)",
               f"{sum(1 for m in charts if m['n'] > 0)}/{len(charts)} chunks charted, {len(tags[-1]['l']) if tags else 0} tags")
    # Remote building: a ghost far from the character on charted ground is placed; on uncharted
    # ground it is refused.
    spot = json.loads(live_lib.mod_lua(
        "local c = storage.f3d.puppet local f = c.force local s = c.surface "
        "for r = 120, 400, 40 do for _, d in pairs({{1,0},{-1,0},{0,1},{0,-1}}) do "
        "local p = { x = math.floor(c.position.x + d[1] * r) + 0.5, y = math.floor(c.position.y + d[2] * r) + 0.5 } "
        "if f.is_chunk_charted(s, { math.floor(p.x / 32), math.floor(p.y / 32) }) and s.can_place_entity({ name = 'wooden-chest', position = p, force = f }) then "
        "rcon.print(helpers.table_to_json({ p.x, p.y })) return end end end rcon.print('[]')") or "[]")
    if spot:
        c.send({"t": "build", "item": "wooden-chest", "x": int(spot[0] * 256), "y": int(spot[1] * 256), "d": 0, "ghost": 1})
        got = c.pump(1.0, every=hello)
        placed = live_lib.mod_lua(f"local n = 0 for _, g in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ type = 'entity-ghost', position = {{ {spot[0]}, {spot[1]} }} }})) do "
                         "n = n + 1 g.destroy() end rcon.print(n)")
        live_lib.report(placed == "1", "save: a ghost placed far away (remote view) on charted ground",
               f"at {spot}; " + "; ".join(m["text"] for m in live_lib.of_type(got, "msg")))
    c.send({"t": "build", "item": "wooden-chest", "x": 900000 * 256, "y": 900000 * 256, "d": 0, "ghost": 1})
    got = c.pump(1.0, every=hello)
    live_lib.report(any("uncharted" in m["text"] for m in live_lib.of_type(got, "msg")), "save: and refused on uncharted ground")
    # Trains in the save: the overview lists every train; a train's window data has its schedule,
    # interrupts, cargo, fuel and stops; a stop's has its priority and circuit settings.
    want_trains = int(live_lib.mod_lua("local n = 0 for _, t in pairs(game.train_manager.get_trains({ force = storage.f3d.puppet.force })) do "
                              "n = n + 1 end rcon.print(n)") or 0)
    c.send({"t": "trains_list"})
    got = c.pump(2, every=hello)
    trl = [r for m in live_lib.of_type(got, "trl") for r in m["l"]]
    live_lib.report(len(trl) == want_trains, "save: the trains overview (trl) lists every train of the force",
           f"{len(trl)}/{want_trains}: " + ", ".join(f"#{r[0]} {r[1]} {r[3]}" for r in trl[:4]))
    if want_trains:
        info = json.loads(live_lib.mod_lua(
            "local tr = package.loaded['__factorio-3d-bridge__/scripts/trains.lua'] "
            "local t = game.train_manager.get_trains({ force = storage.f3d.puppet.force })[1] "
            "local stop = game.train_manager.get_train_stops({ force = storage.f3d.puppet.force })[1] "
            "rcon.print(helpers.table_to_json({ tr = tr.train_info(t.front_stock), stop = stop and tr.stop_info(stop) or {} }))"))
        tri, sti = info.get("tr", {}), info.get("stop", {})
        problems = protocol.train_info_problems(tri)
        live_lib.report(not problems and isinstance(tri.get("sched", {}).get("records"), list) and "cargo" in tri and "fuel" in tri and tri.get("stops"),
               "save: a train's window data: schedule, interrupts, cargo, fuel, stops",
               f"{len(tri.get('sched', {}).get('records', []))} records, {len(tri.get('sched', {}).get('interrupts', []))} interrupts, "
               f"cargo {protocol._items(tri.get('cargo', []))[:2]}, fuel {tri.get('fuel')}, {len(tri.get('stops', []))} stops {problems[:2]}")
        live_lib.report(isinstance(sti.get("pri"), int) and isinstance(sti.get("cb"), dict), "save: a train stop's priority and circuit settings",
               f"{sti.get('name')}: priority {sti.get('pri')}, cb {sti.get('cb')}")
        # Interrupts and a temporary stop written through the mod's commands, read back, then the
        # schedule put back as it was.
        stop_name = (tri.get("stops") or [""])[0]
        interrupt = {"name": "live-check", "inside_interrupt": False,
                     "conditions": [{"type": "fuel_item_count_any", "compare_type": "and",
                                     "condition": {"first_signal": {"type": "item", "name": "coal"}, "comparator": "<", "constant": 5}}],
                     "targets": [{"station": stop_name, "wait_conditions": [{"type": "inactivity", "compare_type": "and", "ticks": 300}]}]}
        back = json.loads(live_lib.mod_lua(
            "local tr = package.loaded['__factorio-3d-bridge__/scripts/trains.lua'] "
            "local t = game.train_manager.get_trains({ force = storage.f3d.puppet.force })[1] local e = t.front_stock "
            "local sch = t.get_schedule() local records, interrupts, manual = sch.get_records(), sch.get_interrupts(), t.manual_mode "
            f"tr.set_interrupts(e, {{ interrupts = helpers.json_to_table({json.dumps(json.dumps([interrupt]))}) }}) "
            f"tr.temp_stop(e, {{ station = {json.dumps(stop_name)} }}) "
            "local info = tr.train_info(e) "
            "sch.set_records(records or {}) sch.set_interrupts(interrupts or {}) t.manual_mode = manual "
            "rcon.print(helpers.table_to_json(info.sched))"))
        ints = protocol._items(back.get("interrupts", []))
        recs = protocol._items(back.get("records", []))
        cur = recs[back.get("current", 1) - 1] if 0 < back.get("current", 0) <= len(recs) else {}
        live_lib.report(ints and ints[0].get("name") == "live-check" and ints[0].get("conditions", [{}])[0].get("type") == "fuel_item_count_any"
               and cur.get("temporary") and cur.get("station") == stop_name,
               "save: set_interrupts and a temporary stop (train_temp) work on a real train",
               f"interrupts {[i.get('name') for i in ints]}, current record {cur}")
    # Logistic chests in the save: what a machine screen shows is every active section's requests.
    chests = json.loads(live_lib.mod_lua(
        "local lg = package.loaded['__factorio-3d-bridge__/scripts/logistics.lua'] local out = {} "
        "for _, s in pairs(game.surfaces) do for _, e in pairs(s.find_entities_filtered({ type = 'logistic-container', limit = 400 })) do "
        "local ok, secs = pcall(e.get_logistic_sections) if ok and secs and #out < 40 then local n = 0 "
        "for _, sec in pairs(secs.sections) do if sec.active then for _, f in pairs(sec.filters) do if f.value and f.value.name then n = n + 1 end end end end "
        "local info = lg.screen_info(e) if info and info.requests then out[#out + 1] = { n, #info.requests, secs.sections_count } end end end end "
        "rcon.print(helpers.table_to_json(out))") or "[]")
    multi = sum(1 for ch in chests if ch[2] > 1)
    live_lib.report(chests and all(ch[0] == ch[1] for ch in chests), "save: requester and buffer chests show every section's requests",
           f"{len(chests)} chests, {multi} with more than one section, {sum(ch[0] for ch in chests)} requests")
    # Hand back and take over once more: nothing is lost on the way.
    rcon.run("/f3d-player none")
    back = json.loads(live_lib.mod_lua(SAVE_SUMMARY + "rcon.print(helpers.table_to_json(summary(game.get_player(" + json.dumps(players[0]) + "))))"))
    live_lib.report(back["items"] == after["items"] and back["armor"] == before["armor"], "save: /f3d-player none gives it all back",
           f"{back['items']} items, armour {back['armor']!r}")
    rcon.run("/f3d-player " + players[0])
    c.pump(8, every=hello, until=lambda m: m.get("t") == "ready")
    print("  players:", owner.replace("\n", " | "), "|", lines.strip().replace("\n", " | "))


def check_join(c, hello):
    """L13: a world Zenith made (a fresh map, nobody created in it yet) played by the bridge's own character.
    Freeplay is told not to make its crash site (takeover.lua no_crash_site) through the remote interface 2.1's
    freeplay.lua has; the hello's `pn` (the client PC's Factorio account) is kept with the client and claims nobody
    while no player has that name. The join itself (a player of that name taking the character over, handing it
    back on leaving) needs a real Factorio joined as a player, which a headless run can't make."""
    facts = json.loads(live_lib.mod_lua(
        "local fp = remote.interfaces.freeplay local fns = {} if fp then for k in pairs(fp) do fns[#fns + 1] = k end end "
        "table.sort(fns) local n = 0 for _ in pairs(game.players) do n = n + 1 end local s = storage.f3d "
        "rcon.print(helpers.table_to_json({ fns = fns, players = n, mp = game.is_multiplayer(), "
        "own = s.own_character ~= nil and s.own_character.valid and s.own_character == s.puppet }))"))
    print("  INFO freeplay's remote interface:", ", ".join(facts["fns"]) or "none", f"| players {facts['players']}")
    need = {"get_init_ran", "get_disable_crashsite", "set_disable_crashsite", "get_created_items"}
    live_lib.report(need <= set(facts["fns"]), "join: freeplay's remote interface has what the bridge calls", sorted(need - set(facts["fns"])))
    if not need <= set(facts["fns"]):
        return
    state = json.loads(live_lib.mod_lua(
        "rcon.print(helpers.table_to_json({ ran = remote.call('freeplay', 'get_init_ran') == true, "
        "off = remote.call('freeplay', 'get_disable_crashsite') == true, kit = remote.call('freeplay', 'get_created_items') }))"))
    print("  INFO freeplay: init_ran", state["ran"], "| crash site disabled", state["off"], "| created items", state["kit"])
    if facts["players"] == 0:
        live_lib.report(facts["mp"] and facts["own"] and not state["ran"] and state["off"],
               "join: on a server map nobody joined yet, the bridge plays its own character and freeplay's crash site is off",
               f"{facts}, {state}")
    else:
        live_lib.report(True, "join: this map has players (freeplay's intro ran already): nothing to turn off", f"{facts['players']} players")
    live_lib.report(isinstance(state["kit"], dict) and state["kit"].get("iron-plate") == 8,
           "join: freeplay's created items are names to counts (what a claimed new player's character is emptied of)", state["kit"])
    named = dict(hello[1], pn="zenith-live-nobody")
    c.pump(2.0, every=(1.0, named))
    st = json.loads(live_lib.mod_lua("local s = storage.f3d rcon.print(helpers.table_to_json({ pn = s.client and s.client.pn or '', "
                            "owner = s.owner_index or 0, z = s.zenith_owner or 0, "
                            "own = s.own_character ~= nil and s.own_character.valid and s.own_character == s.puppet }))"))
    live_lib.report(st["pn"] == "zenith-live-nobody" and st["owner"] == 0 and st["z"] == 0 and st["own"] == facts["own"],
           "join: a hello's pn is kept with the client; with no player of that name nobody is claimed", st)
    c.pump(1.5, every=hello)
    st = json.loads(live_lib.mod_lua("local s = storage.f3d rcon.print(helpers.table_to_json({ pn = s.client and s.client.pn or '' }))"))
    live_lib.report(st["pn"] == "", "join: a hello without pn forgets it", st)
    switches = rcon.run("/f3d-perf")
    live_lib.report("zenith_join on" in switches and "no_crash_site on" in switches, "join: /f3d-perf lists the two switches, on",
           switches.strip()[-200:])


def steps_parts(msgs):
    """The `steps` parts of one handshake, by part number, and their count as the parts say it."""
    parts = {m["part"]: m for m in live_lib.of_type(msgs, "steps")}
    total = {m["parts"] for m in parts.values()}
    return parts, (total.pop() if len(total) == 1 else None)


def handshake_msgs(c):
    """A handshake's messages: hellos until `ready`, then the rest of the stages (eprops, steps...) with the
    client's world on, as the client does."""
    msgs = c.pump(8, until=lambda m: m.get("t") == "ready", every=(1.0, {"t": "hello", "v": 1, "sid": c.sid, "w": 0}))
    c.send({"t": "hello", "v": 1, "sid": c.sid, "w": 1})
    return msgs + c.pump(4.0)


def check_steps(c, hello):
    """Step 5 task 3a: the character's steps from Factorio's own prototypes. The handshake's `steps` parts whole,
    numbered and under the outbox's budget; every tile listed, and silent only where the player can't walk (its
    collision mask has `player`); the files each listed sound names are in the install; the same list as the
    data stage's zenith-step-sounds; sent again whole on a full resync and on a reconnect (a new sid)."""
    import factorio_install
    msgs = handshake_msgs(c)
    kinds = [m.get("t") for m in msgs]
    parts, total = steps_parts(msgs)
    live_lib.report(total is not None and sorted(parts) == list(range(1, total + 1)),
           "steps: every part of the list in the handshake", f"{sorted(parts)} of {total}")
    if not parts or total is None:
        return
    live_lib.report("eprops" in kinds and kinds.index("steps") > kinds.index("eprops"), "steps: after eprops")
    live_lib.report(c.max_size.get("steps", 0) <= 4096, "steps: each datagram within f3d-bytes-per-tick's floor (4096)",
           f"largest {c.max_size.get('steps')} bytes, {total} parts")
    sounds, lists, u = [], {"tl": [], "el": [], "dl": [], "al": []}, None
    for n in range(1, total + 1):
        sounds += parts[n].get("s", [])
        for k in lists:
            lists[k] += parts[n].get(k, [])
        u = parts[n].get("u", u)
    live_lib.report(all(0 <= rec[1] <= len(sounds) for k in ("tl", "el", "dl") for rec in lists[k]) and u is not None
           and all(0 <= v <= len(sounds) for v in u), "steps: every name points at a listed sound (0: none)", f"{len(sounds)} sounds, u {u}")
    # The data stage's list, read back over RCON: the same tiles, rails and resources, decoratives.
    facts = json.loads(live_lib.mod_lua(
        "local d = prototypes.mod_data['zenith-step-sounds'] local out = { has = d ~= nil } "
        "if d then local function n(t) local c = 0 for _ in pairs(t or {}) do c = c + 1 end return c end "
        "out.s = #d.get('s') out.tile = n(d.get('tile')) out.entity = n(d.get('entity')) out.decorative = n(d.get('decorative')) end "
        "local blocked = {} for name, p in pairs(prototypes.tile) do "
        "if p.collision_mask.layers.player then blocked[#blocked + 1] = name end end out.blocked = blocked "
        "out.tiles = 0 for _ in pairs(prototypes.tile) do out.tiles = out.tiles + 1 end "
        "rcon.print(helpers.table_to_json(out))"))
    live_lib.report(facts["has"] and facts["s"] == len(sounds) and facts["tile"] == len(lists["tl"]) == facts["tiles"]
           and facts["entity"] == len(lists["el"]) and facts["decorative"] == len(lists["dl"]),
           "steps: the message carries the data stage's whole list (every tile, rails and resources, decoratives)",
           f"sounds {len(sounds)}/{facts.get('s')}, tiles {len(lists['tl'])}/{facts.get('tile')}/{facts['tiles']}, "
           f"entities {len(lists['el'])}/{facts.get('entity')}, decoratives {len(lists['dl'])}/{facts.get('decorative')}")
    names = {i: n for n, i in c.tiles.items()}
    silent = sorted(names.get(rec[0], f"#{rec[0]}") for rec in lists["tl"] if rec[1] == 0)
    walk_silent = [n for n in silent if n not in set(facts["blocked"]) and n != "tile-unknown"]
    print(f"  INFO steps: {len(sounds)} sounds in {total} parts; silent tiles: {', '.join(silent)}")
    live_lib.report(not walk_silent, "steps: no tile the player can walk on is silent", walk_silent)
    data = factorio_install.find()
    data = os.path.join(data, "data") if data and os.path.isdir(os.path.join(data, "data")) else None
    if data:
        missing = []
        for key, _vol, count in sounds:
            files = key if isinstance(key, list) else (
                [f"{key}-{i}.ogg" for i in range(1, count + 1)] if not (count == 1 and os.path.exists(os.path.join(data, key + ".ogg")))
                else [key + ".ogg"])
            missing += [f for f in files if not os.path.exists(os.path.join(data, f))]
        live_lib.report(not missing, "steps: every listed sound's files are in the install (read there, never copied)", missing[:5])
    # A full resync and a reconnect: the list again, whole.
    c.send({"t": "resync", "full": 1})
    again = c.pump(4.0)
    p2, t2 = steps_parts(again)
    live_lib.report(t2 == total and sorted(p2) == list(range(1, total + 1)), "steps: sent again whole on a full resync", f"{sorted(p2)} of {t2}")
    c.sid = c.sid + "-again"
    again = handshake_msgs(c)
    p3, t3 = steps_parts(again)
    live_lib.report(t3 == total and sorted(p3) == list(range(1, total + 1)) and p3[1].get("s") == parts[1].get("s"),
           "steps: sent again whole on a reconnect (a new sid), the same list", f"{sorted(p3)} of {t3}")
    c.pump(1.0, every=(1.0, {"t": "hello", "v": 1, "sid": c.sid, "w": 1}))


def check_as_player(c, hello):
    """Acting as the player (as_player.lua): with a player connected whose character the bridge plays,
    the bridge's building, rotating, opening, pasting and mining raise Factorio's own player events,
    seen by tools/mod_tests/fixtures/zenith-event-probe (a mod that counts events, which must be in the
    server's mods); with the map setting off, building raises only script_raised_built. Needs a real
    Factorio client joined as the player the bridge plays."""
    who = live_lib.mod_lua("local c = storage.f3d.puppet local p = c and c.player "
                  "rcon.print(p and p.connected and (p.index .. ' ' .. p.name) or 'none') ")
    has_probe = rcon.run("/c rcon.print(remote.interfaces.probe and 'yes' or 'no')").strip() == "yes"
    if who == "none" or not has_probe:
        live_lib.report(False, "as player: needs a connected player playing the bridge's character and the zenith-event-probe mod",
               f"player {who}, probe {has_probe}")
        return
    index = int(who.split()[0])
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "as player: an empty spot", live_lib.SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    bx, by = math.floor(x) + 4.5, math.floor(y) + 0.5

    def probe():
        out = rcon.run("/c rcon.print(remote.call('probe', 'get'))").strip()
        return json.loads(out) if out.startswith("{") else {"c": {}, "p": {}}

    def heard(name):
        d = probe()
        return d["c"].get(name, 0) > 0 and d["p"].get(name) == index

    def unit_at(name, px, py):
        return int(live_lib.mod_lua(f"local e = storage.f3d.puppet.surface.find_entity('{name}', {{ {px}, {py} }}) "
                           "rcon.print(e and e.unit_number or 0)") or 0)

    def ident(name, px, py):
        return {"u": unit_at(name, px, py), "p": c.proto_id(name), "x": int(px * 256), "y": int(py * 256)}

    live_lib.mod_lua("storage.f3d.puppet.insert({ name = 'transport-belt', count = 10 }) "
            "storage.f3d.puppet.insert({ name = 'assembling-machine-1', count = 2 })")
    rcon.run("/c remote.call('probe', 'reset')")
    c.send({"t": "build", "item": "transport-belt", "x": int(bx * 256), "y": int(by * 256), "d": 4})
    c.pump(1.0, every=hello)
    live_lib.report(unit_at("transport-belt", bx, by) and heard("on_built_entity") and heard("on_pre_build"),
           "as player: building raises on_pre_build and on_built_entity for the player", json.dumps(probe()["c"]))
    left = live_lib.mod_lua("local p = storage.f3d.puppet.player rcon.print(p.cursor_stack.valid_for_read and p.cursor_stack.name or 'empty')")
    live_lib.report(left == "empty", "as player: the cursor is given back empty", left)

    c.send({"t": "rotate", **ident("transport-belt", bx, by)})
    c.pump(0.6, every=hello)
    live_lib.report(heard("on_player_rotated_entity"), "as player: rotating raises on_player_rotated_entity")

    ax, ay = bx + 3.0, by + 3.0
    c.send({"t": "build", "item": "assembling-machine-1", "x": int(ax * 256), "y": int(ay * 256), "d": 0})
    c.send({"t": "build", "item": "assembling-machine-1", "x": int((ax + 4) * 256), "y": int(ay * 256), "d": 0})
    c.pump(1.0, every=hello)
    a, b = ident("assembling-machine-1", ax, ay), ident("assembling-machine-1", ax + 4, ay)
    c.send({"t": "open", **a})
    c.pump(0.6, every=hello)
    opened = live_lib.mod_lua("local p = storage.f3d.puppet.player rcon.print(p.opened and p.opened.unit_number or 0)")
    live_lib.report(heard("on_gui_opened") and opened == str(a["u"]), "as player: opening a machine opens it for the player (on_gui_opened)", opened)
    c.send({"t": "close"})
    c.pump(0.6, every=hello)
    live_lib.report(heard("on_gui_closed"), "as player: closing it raises on_gui_closed")
    live_lib.mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'assembling-machine-1' }})) do "
            f"if e.unit_number == {a['u']} then e.set_recipe('iron-gear-wheel') end end")
    c.send({"t": "paste_settings", "f": [a["u"], a["p"], a["x"], a["y"]], **b})
    c.pump(0.6, every=hello)
    live_lib.report(heard("on_entity_settings_pasted"), "as player: pasting settings raises on_entity_settings_pasted")

    belt = ident("transport-belt", bx, by)
    c.pump(3.0, every=(0.2, {"t": "mine", **belt}))
    live_lib.report(not unit_at("transport-belt", bx, by) and heard("on_player_mined_entity"),
           "as player: mining raises on_player_mined_entity for the player")

    # Far reach: the bridge goes by the character's real build distance (a mod's bonus too).
    fx_, fy_ = math.floor(x) + 14.5, math.floor(y) + 0.5
    c.send({"t": "build", "item": "transport-belt", "x": int(fx_ * 256), "y": int(fy_ * 256), "d": 4})
    c.pump(0.8, every=hello)
    before = unit_at("transport-belt", fx_, fy_)
    live_lib.mod_lua("storage.f3d.puppet.character_build_distance_bonus = 10")
    c.send({"t": "build", "item": "transport-belt", "x": int(fx_ * 256), "y": int(fy_ * 256), "d": 4})
    c.pump(0.8, every=hello)
    live_lib.report(not before and unit_at("transport-belt", fx_, fy_), "as player: 14 tiles away is out of reach, and in reach with a +10 build bonus")
    live_lib.mod_lua("storage.f3d.puppet.character_build_distance_bonus = 0")

    # Only the mod that owns a setting may change it: set it in the bridge's own state.
    live_lib.mod_lua('settings.global["f3d-act-as-player"] = { value = false }')
    rcon.run("/c remote.call('probe', 'reset')")
    c.send({"t": "build", "item": "transport-belt", "x": int(bx * 256), "y": int((by + 6) * 256), "d": 4})
    c.pump(1.0, every=hello)
    d = probe()["c"]
    live_lib.report(unit_at("transport-belt", bx, by + 6) and not d.get("on_built_entity") and d.get("script_raised_built"),
           "as player off: the bridge builds by script (script_raised_built only)", json.dumps(d))
    live_lib.mod_lua('settings.global["f3d-act-as-player"] = { value = true }')


def lua_command(text):
    """The client's Lua command over RCON (console_commands.gd lua_command): game.player becomes the
    player the bridge plays, or a stand-in for its character; the prelude is the client's own."""
    prelude = " ".join(l.strip() for l in (live_lib.REPO / "client" / "data"
                                         / "console_prelude.lua").read_text().split("\n") if l.strip())
    head, code = text.split(" ", 1)
    target = re.match(r"(__\S+__)\s+", code)
    if target:
        head, code = head + " " + target.group(1), code[target.end():]
    code = re.sub(r"\bgame\s*\.\s*player\s*\.\s*print\s*\(", "__zprint(", code)
    code = re.sub(r"\bgame\s*\.\s*print\s*\(", "__zgprint(", code)
    code = re.sub(r"\bgame\s*\.\s*player\b", "__zp", code)
    return head + " " + prelude.replace("%USER%", code + "\n")


def check_console(c, hello, cheat=False):
    """The client's console (console.lua, console_commands.gd): Lua commands over RCON with the
    client's prelude, where game.player is the bridge's player (or its character's stand-in) and
    print and errors answer RCON; and the commands the bridge runs itself (`cmd`, answered with
    `cmdr`). With `cheat` (only --only console: it researches everything), /cheat and moving to a
    planet with it."""
    out = rcon.run(lua_command("/c game.player.print(game.player.character.name .. ' ' .. game.player.surface.name)")).strip()
    live_lib.report(out.startswith("character "), "console: /c game.player.print answers over RCON with the bridge's character", out)
    out = rcon.run(lua_command("/c game.print(#game.players >= 0 and 'players ok')")).strip()
    live_lib.report(out == "players ok", "console: game.print answers too, and game.players is untouched", out)
    out = rcon.run(lua_command("/sc game.player.no_such_field = game.player.nothing_here.x")).strip()
    live_lib.report(out.startswith("Error: ") and "game.player" in out, "console: an error comes back as the answer", out)
    out = rcon.run(lua_command("/c __factorio-3d-bridge__ game.player.print(storage.f3d.puppet == game.player.character and 'mod state')")).strip()
    live_lib.report(out == "mod state", "console: /c __mod__ keeps the mod's state", out)
    who = rcon.run("/sc rcon.print(remote.call('zenith', 'player') and 'player' or 'none')").strip()
    print(f"     (the bridge plays {'a LuaPlayer' if who == 'player' else 'its own character, no LuaPlayer'})")

    def ask(text, cid):
        c.send({"t": "cmd", "id": cid, "text": text})
        msgs = c.pump(3.0, every=hello, until=lambda m: m.get("t") == "cmdr" and m.get("id") == cid)
        got = [m for m in live_lib.of_type(msgs, "cmdr") if m.get("id") == cid]
        return got[-1] if got else {}
    for name, cid in (("version", 901), ("seed", 902)):
        r, want = ask("/" + name, cid), rcon.run("/" + name).strip()
        live_lib.report(r.get("l") == [want], f"cmd /{name}: the bridge answers as Factorio's console does", f"{r.get('l')} vs {want!r}")
    r, want = ask("/evolution", 903), rcon.run("/evolution").strip()
    live_lib.report(r.get("l") and r["l"][0].split(" - ")[0] == want.split(" - ")[0] and "Evolution factor: " in r["l"][0],
           "cmd /evolution: Factorio's line", f"{r.get('l')} vs {want!r}")
    r = ask("/time", 904)
    live_lib.report(r.get("l") and ("second" in r["l"][0] or "minute" in r["l"][0] or "hour" in r["l"][0]), "cmd /time", str(r.get("l")))
    r = ask("/players", 905)
    live_lib.report(r.get("l") and r["l"][0].startswith("Players ("), "cmd /players", str(r.get("l")))
    r = ask("/f3d-status", 906)
    live_lib.report(r.get("l") and any("client on port" in l for l in r["l"]), "cmd /f3d-status: the mod's command answers the client", str(r.get("l"))[:200])
    r = ask("/editor", 907)
    live_lib.report(r.get("ok") == 0, "cmd: a command the bridge doesn't run answers ok = 0", str(r))
    # The debug menu's /f3d-debug: each change read back from the game over RCON, then put back.
    r = ask("/f3d-debug", 908)
    before = r.get("dbg", {})
    live_lib.report(before.get("s") and "sp" in before, "cmd /f3d-debug: the game's state as dbg", str(r))
    ask("/f3d-debug daytime 0.5", 909)
    ask("/f3d-debug freeze on", 910)
    got = rcon.run("/sc local c = remote.call('zenith', 'character') rcon.print(string.format('%.3f %s', c.surface.daytime, tostring(c.surface.freeze_daytime)))").strip()
    live_lib.report(got == "0.500 true", "cmd /f3d-debug daytime and freeze set the character's surface", got)
    ask("/f3d-debug speed 2", 911)
    got = rcon.run("/sc rcon.print(game.speed)").strip()
    live_lib.report(got == "2", "cmd /f3d-debug speed sets game.speed", got)
    ask("/f3d-debug speed 1", 912)
    # A tick-paused game runs no mod code: the bridge reads no packet and sends nothing until it
    # resumes, which only RCON can do (net/game_pause.gd, seen on real 2.1.24). So the pause's
    # answer comes once RCON resumes the game, saying it paused (pa 1: game_pause.gd's refused()
    # reads pa 0 as "didn't pause"); meanwhile RCON sees the tick stand still.
    c.send({"t": "cmd", "id": 913, "text": "/f3d-debug pause on"})
    paused = c.pump(3.0, every=hello, until=lambda m: m.get("t") == "cmdr" and m.get("id") == 913)
    ticks = [rcon.run("/sc rcon.print(tostring(game.tick_paused) .. ' ' .. game.tick)").strip()]
    time.sleep(0.5)
    ticks.append(rcon.run("/sc rcon.print(tostring(game.tick_paused) .. ' ' .. game.tick)").strip())
    early = [m for m in live_lib.of_type(paused, "cmdr") if m.get("id") == 913]
    rcon.run("/sc game.tick_paused = false")
    msgs = c.pump(0.5 if early else 5.0, every=hello, until=lambda m: m.get("t") == "cmdr" and m.get("id") == 913)
    late = [m for m in live_lib.of_type(msgs, "cmdr") if m.get("id") == 913]
    answers = early + late
    live_lib.report(ticks[0].startswith("true ") and ticks[0] == ticks[1] and answers and answers[-1].get("dbg", {}).get("pa") == 1,
           "cmd /f3d-debug pause: the game tick-pauses (the tick stands still over RCON), and the bridge's answer says so "
           "(pa 1), by the time RCON has resumed it",
           f"RCON {ticks}; answered {len(early)} times while paused, {len(late)} after: {str(answers[-1:])[:200]}")
    ask("/f3d-debug pause off", 915)
    r = ask("/f3d-debug", 914)
    live_lib.report(r.get("dbg", {}).get("pa") == 0, "cmd /f3d-debug pause: after RCON's resume the bridge answers again, not paused", str(r)[:200])
    ask("/f3d-debug freeze %s" % ("on" if before.get("fz") == 1 else "off"), 916)
    ask("/f3d-debug daytime %s" % before.get("dt", 0.2), 917)
    if not cheat:
        return
    r = ask("/cheat", 908)
    done = rcon.run("/sc rcon.print(game.forces.player.technologies['automation'].researched)").strip()
    live_lib.report(r.get("l", [""])[0] == "Researched every technology" and done == "true", "cmd /cheat researches everything", f"{r.get('l')}, automation {done}")
    if "vulcanus" in rcon.run("/sc for n in pairs(game.planets) do rcon.print(n) end"):
        r = ask("/cheat vulcanus", 909)
        where = live_lib.mod_lua("rcon.print(storage.f3d.puppet.surface.name)")
        live_lib.report(r.get("l") == ["Moved to vulcanus"] and where == "vulcanus", "cmd /cheat vulcanus moves the character there", f"{r.get('l')}, on {where}")
        r = ask("/cheat nauvis", 910)
        where = live_lib.mod_lua("rcon.print(storage.f3d.puppet.surface.name)")
        live_lib.report(where == "nauvis", "and /cheat nauvis back", f"{r.get('l')}, on {where}")


def step_errors():
    """/f3d-status's failing steps: name -> (times failed, the line)."""
    out = {}
    for line in rcon.run("/f3d-status").splitlines():
        m = re.search(r"ERROR: step '([^']+)' failed (\d+) time", line)
        if m:
            out[m.group(1)] = (int(m.group(2)), line)
    return out


def server_log():
    """This server's factorio-current.log, if it is on this machine: --server-log, else the repo's
    server/data one when it opened this run's UDP port (another server's log proves nothing)."""
    path = pathlib.Path(live_lib.SERVER_LOG) if live_lib.SERVER_LOG else (
        live_lib.REPO / "server" / "data" / "factorio-current.log")
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return None
    return text if live_lib.SERVER_LOG or f"127.0.0.1:{live_lib.FACTORIO_PORT}" in text else None


def check_barrier(c, hello):
    """The error barrier (barrier.lua): a tick step and an event handler made to fail. The game goes
    on, the other steps keep sending, the failing one is retried each tick, /f3d-status names it,
    the client is told, Factorio's log has it (at most once every 600 ticks), and a step that works
    again stops counting. The failures are forgotten afterwards, so the run's last check still sees
    only real ones."""
    before = step_errors()
    if "research" in before or "on_research_finished" in before:
        live_lib.report(False, "barrier: research hadn't failed before the check", str(before)[:300])
        return
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "barrier: an empty spot", live_lib.SPOT_WHY)
        return
    c.pump(0.5, every=hello)
    # A tick step: research's job in a shape it can't read (as a save of another bridge might hold).
    tick0 = int(rcon.run("/sc rcon.print(game.tick)").strip())
    live_lib.mod_lua("storage.f3d.techs_job = { names = false, block = 1, blocks = 2, sent = 0 } rcon.print('ok')")
    msgs = c.pump(1.2, every=(0.15, {"t": "walk", "d": 4}))
    c.send({"t": "walk", "d": -1})
    msgs += c.pump(2.0, every=hello)
    tick1 = int(rcon.run("/sc rcon.print(game.tick)").strip())
    errors = step_errors()
    n1, line = errors.get("research", (0, ""))
    live_lib.report(n1 > 0 and "names" in line, "barrier: /f3d-status names the failing step and its error", line[:300])
    # (A tick the work budget has no room for techs returns before reading the job.)
    span = re.search(r"first at tick (\d+), last at tick (\d+)", line)
    span = int(span.group(2)) - int(span.group(1)) if span else 0
    live_lib.report(tick1 - tick0 >= 150 and n1 >= 30 and span >= (tick1 - tick0) * 0.7,
           "barrier: the game goes on, and the failing step is tried again tick after tick",
           f"{tick1 - tick0} ticks, failed {n1} times over {span}")
    mes = live_lib.of_type(msgs, "me")
    moved = math.hypot(mes[-1]["x"] - mes[0]["x"], mes[-1]["y"] - mes[0]["y"]) / 256 if mes else 0
    live_lib.report(len(live_lib.of_type(msgs, "sky")) >= 2 and moved > 2, "barrier: the other steps keep running (sky sent, the character walked)",
           f"{len(live_lib.of_type(msgs, 'sky'))} sky, walked {moved:.1f} tiles")
    told = [m["text"] for m in live_lib.of_type(msgs, "msg") if m.get("text", "").startswith("Bridge error in research")]
    live_lib.report(len(told) == 1, "barrier: the client is told once, not every tick", str(told)[:200])
    log = server_log()
    if log is None:
        print("SKIP barrier: the server's log isn't on this machine (--server-log)")
    else:
        lines = [l for l in log.splitlines() if "[Zenith] ERROR in step 'research' at tick" in l
                 and tick0 <= int(re.search(r"at tick (\d+)", l).group(1)) <= tick1 + 60]
        live_lib.report(1 <= len(lines) <= 1 + (tick1 - tick0) // 600 and "names" in (lines[0] if lines else ""),
               "barrier: Factorio's log has the step and its error, at most once every 600 ticks",
               f"{len(lines)} lines in {tick1 - tick0} ticks: {(lines[0] if lines else '')[:200]}")
    # Working again: the tree is sent and the count stops.
    live_lib.mod_lua("storage.f3d.techs_job = nil storage.f3d.techs_dirty = true rcon.print('ok')")
    msgs = c.pump(2.0, every=hello)
    n2 = step_errors().get("research", (0, ""))[0]
    c.pump(1.0, every=hello)
    n3 = step_errors().get("research", (0, ""))[0]
    live_lib.report(live_lib.of_type(msgs, "techs") and n3 == n2, "barrier: once the step can run again it sends (techs) and stops failing",
           f"{len(live_lib.of_type(msgs, 'techs'))} techs parts, failed {n2} then {n3} times")

    # An event handler: on_research_finished's (research.lua) calls crafting.invalidate, replaced
    # for the length of one command by one that fails. Without the barrier the error would come out
    # of `researched = true`. An infinite technology (its level under its max_level) never reads
    # researched, so the change wouldn't stand: one that can is picked.
    out = live_lib.mod_lua("""
local t for _, tech in pairs(game.forces.player.technologies) do
  if not tech.researched and tech.enabled and tech.level == tech.prototype.max_level then t = tech break end end
if not t then rcon.print('none') return end
local m = package.loaded['__factorio-3d-bridge__/scripts/crafting.lua']
local orig = m.invalidate
m.invalidate = function() error('barrier check: a handler failing') end
local ok, err = pcall(function() t.researched = true end)
m.invalidate = orig
local done = t.researched
t.researched = false
rcon.print(tostring(ok) .. ' ' .. tostring(done) .. ' ' .. t.name .. ' ' .. tostring(err))
""".replace("\n", " "))
    errors = step_errors()
    n, line = errors.get("on_research_finished", (0, ""))
    live_lib.report(out.startswith("true true") and n == 1 and "a handler failing" in line,
           "barrier: an event handler failing is caught, logged and listed; the game's own change stands", f"{out} | {line[:200]}")
    msgs = c.pump(1.0, every=hello)
    live_lib.report(live_lib.of_type(msgs, "sky") or live_lib.of_type(msgs, "me"), "barrier: the bridge keeps sending after the handler failed",
           f"{len(msgs)} messages")
    live_lib.mod_lua("local b = package.loaded['__factorio-3d-bridge__/scripts/barrier.lua'] "
            "b.forget('research') b.forget('on_research_finished') rcon.print('ok')")
    left = step_errors()
    live_lib.report(left.keys() == before.keys(), "barrier: the check's failures are forgotten, the rest kept", str(list(left))[:200])
