#!/usr/bin/env python3
"""Checks the bridge against a running headless Factorio, the way the Godot client uses it.

    powershell -ExecutionPolicy Bypass -File server\\run-server.ps1     (or server/run-headless.sh)
    python3 tools/live_check.py

Close the Godot client first: this binds the client's port (34201). It plays the client over
UDP (handshake, chunks, walking, building (turning, fast-replace, rails, quality), rotating,
mining, items on belts and on the ground, fluids, wires and power, blueprints and planners,
circuits, the map, logistics, trains, combat, vehicles, inventory slots, quickbar, crafting, research, machine
screens) and uses RCON (tools/rcon.py) for what the protocol can't show: the datagram size limit, table_to_json on an
empty table, whether world.record copes with every entity type, and how long a chunk snapshot
takes.

Every message received is checked with tools/protocol.py. Commands starting with /c run Lua in
the mod's own state (`/c __factorio-3d-bridge__ ...`), which disables achievements for the save.

A second server instance on other ports (run-server.ps1 -UdpPort/-RconPort):
    python3 tools/live_check.py --factorio-port 34210 --client-port 34211 --rcon-port 34298
`--binary`: every hello asks for binary frames (`bin`), read as the client reads them (docs/PROTOCOL.md);
`--only platforms` runs just the handshake and the space platform checks (needs Space Age);
`--only pickup` F taking items off belts and the ground (`pku`), after an INFO line on Factorio's own picking_state;
`--only ride` riding a rocket up to a platform's hub and a cargo pod down (`ride`, `land`);
`--only collectors` asteroid collectors' arms (`acol`: arm count, speed, filters, caught chunks);
`--only space` Space Age's screens (a silo launching a new platform's starter pack, the hub's
schedule and requests, landing pad, collector, module effects, quality);
`--only save` the handshake and taking over a loaded save's player (use a copy of the save:
the player's things move onto the bridge's character); `--only input` slot clicks and transfers (move, xfer, fast on belts and labs) against 2.1.23's own rules; `--only ui` the handshake and the UI parity checks (drop, fast transfer, settings, flip, clipboard,
Alt-mode, chat, statistics, inserter / splitter / switch / turret / chest bar screens); `--only gear`
the character's gear (armour grid, equipment commands and switches, the character tab, players, a
tank's grid, death and respawn; use a copy of a save: the character dies); `--only planners`
the blueprint and planner checks (exchange strings, the libraries, undo, super-forced building);
`--only circuits` the wire tools and every entity's circuit and own settings (combinators in full, lamps, speakers, pumps,
turrets, display panels); `--only build` tiles, capsules, the rail planner (its extension table too) and what drag building sends;
`--only info` the handshake and the information windows: alerts, Factoriopedia, the logistic
networks window, statistics (build counts, pollution, graphs) and technology details (best on a
copy of a busy save, which has networks, trains and research to show)); `--only alerts` the alerts the mod works out (turret
without ammo, attack, destruction, a ghost without material); `--only multi` a second client on
the same server; `--only logic` the logic, train and vehicle windows' data (always on, descriptions,
an inserter's hand, burner bars, rail signals, a stop's trains, a locomotive's name and colour, a
wagon's limit, a car's guns); `--only machines` Factorio's production windows (machine_info.lua: recipe details, the
chooser's groups, productivity, burners, drills, temperature, labs, a requester's settings);
`--only turrets` turret states (`ts`: every turret, a tank and a spidertron aiming and firing at biters);
`--only enemies` enemies' attacks (`en`) and the decals round nests; `--only mapinfo` the hover panel's beacon effects (`hinfo`) and `terr`'s surface; `--only console` the client's console
(Lua commands with its prelude over RCON, `cmd`, and /cheat, which researches everything); `--only remote` the 3D remote view leaving out moving things no radar sees (`cov`); `--only remnants` what destroyed buildings leave (extra.rm) and
linked belts' ends; `--only barrier` the error barrier (barrier.lua): a tick step and an event handler
made to fail, the game and the other steps going on (`--server-log` points at the server's
factorio-current.log when it isn't server/data's); `--only research` research finishing (`rdone`: a
technology researched by script named once, an infinite one by the level it finished); `--only join` a world
Zenith made (L13; run it on a fresh map nobody joined): freeplay's crash site turned off through its 2.1 interface,
and a hello's `pn` kept, claiming nobody when no player has that name (a player joining can't be played headless:
test_bridge.py does that against the fake API); `--only underclear` an underground pair built over belts mining the belts
between (M2: a plain run, a side-loaded one kept, pipes-to-ground over pipes, the switch off), after an INFO line on what
a script's own create_entity{fast_replace, character} does to the run; `--only vehitems` vehicles (N2: Ctrl+click into a
car, tank, spidertron, locomotive and cargo wagon and out of them; N3: the vehicle's `guns`, `gun` and `vammo` while
driving, and a printed line on whether `shoot` fires the vehicle's gun; N4: `repair` on a car and a cargo wagon);
`--only pipeend` the pipes and belts beside what the bridge's character mines (no event raised) sent again with
their new shapes: a run's ends, a corner, a T losing its branch, a cross an arm, pipes-to-ground, a pump and a tank
going, belts straightened and curved, a pipe `die`d and one a robot takes, `/f3d-perf mined_neighbours off`; walls and
heat pipes only their `del` (the client joins them).
`--only steps` the character's steps from the prototypes (`steps`:
every part, every tile, silent only where the player can't walk, the files in the install, again on a resync and a
reconnect).
`--only enemysight` a diagnostic, not in the full run: do idle biters notice the bridge's player-less character walking up
(three small biters left idle 60 tiles off, approached to 20 and 8 tiles), one shot at one of them, a small worm approached
inside its range, and the two candidate fixes tried by hand (a wander command with distraction by_enemy; a distraction
command to attack the character), then the nearest nest the map made, with the bridge's fix (/f3d-perf enemy_sight)
off and on: its biters attack the approaching character only with it on, the whole nest at once, held about 40 s while
it stands and dropping off gradually, and chasing it 150 tiles away (a real player's measured behaviour); prints raw
numbers (commands, distances, ticks, damage) per step. Steps 2-5 run with the fix off.
`--only enemysightfix` steps 1 and 6 alone. Run them on a fresh map: they destroy the enemies within 200 tiles of the spot,
and step 6 runs the game fast (speed 10) for up to 5 minutes until the nest owns 8 idle biters.
`--only link` the add-on link (`ext`, link.lua) with the fixture mod tools/mod_tests/fixtures/zenith-link-test in the
server's mods: an echo there and back, `who` naming this client's character, the caps on a flood both ways and on a
message over 4 KB, a bad channel dropped, a second client answered alone and its coming and going raised. Run it
twice, the server restarted on the saved game in between (`/server-save`, then run-server.ps1 -Save), so the second
run checks the mod's on_load path: the bridge's event ids made again on loading.
`--only sprint` the Sprint add-on's Factorio mod (addons-src/sprint/mod/zenith-sprint, with the fixture mod above, both in
the server's mods) played as the add-on would: on, held, off, the 90-tick time-out, a client dropping mid-sprint, another
mod's change to the running speed surviving; then garbage `ext`, a stranger's port and an `ext` before the welcome.
"""

import argparse
import base64
import json
import math
import os
import re
import pathlib
import socket
import sys
import time
import zlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import protocol  # noqa: E402
import rcon  # noqa: E402

# A check's text can hold any character (≥, item names): on Windows, output to a file or pipe is in
# the system's code page, and one character it lacks stopped the whole run with UnicodeEncodeError.
sys.stdout.reconfigure(errors="backslashreplace")

MOD = "__factorio-3d-bridge__"
FACTORIO_PORT, CLIENT_PORT = 34200, 34201
SECOND_CLIENT_PORT = 0  # the two-client check's second client; 0: the client port + 1
SERVER_LOG = None  # --server-log
results = []
# Seconds to wait for a `surface` message after a surface change. It is reliable and comes after
# everything queued before it, chunk snapshots too: after the remote view came back to Nauvis the
# platform's `surface` once took longer than the 3 s these waits had, the boarding check failed
# and the character, left on the platform, failed 11 checks after it (a local full run). The waits
# end as soon as it comes.
SURFACE_WAIT = 15


def report(ok, what, detail=""):
    ok = bool(ok)  # a falsy {} or [] must count as a failure too
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + what + (f"  ({detail})" if detail else ""))


def report_step_errors():
    """A step that fails no longer stops the server (barrier.lua), so a passing run has to ask."""
    status = rcon.run("/f3d-status")
    report("ERROR: step" not in status, "no step of the bridge failed",
           " | ".join(l for l in status.splitlines() if "ERROR: step" in l)[:500])


def mod_lua(code):
    """Runs Lua in the mod's state and returns what it rcon.print()s."""
    return rcon.run(f"/c {MOD} {code}").strip()


def destroy_units(units):
    """Destroys what a check made, by unit number. game.get_entity_by_unit_number only finds
    prototypes flagged get-by-unit-number (vehicles and a few more), so the character's force's
    entities are searched instead."""
    units = [str(u) for u in units if u]
    if units:
        mod_lua(f"local want = {{}} for _, u in pairs({{ {', '.join(units)} }}) do want[u] = true end "
                "local c = storage.f3d.puppet "
                "for _, e in pairs(c.surface.find_entities_filtered({ force = c.force })) do "
                "if e.valid and e.unit_number and want[e.unit_number] then e.destroy() end end")


def clear_enemies(radius=96, x=None, y=None, units=0):
    """Destroys the enemies within `radius` of (x, y), the character by default, and heals it. The
    turrets' nest spawns defenders under the artillery's shells and the shooting checks leave
    biters: one that finds the character later kills it, and its respawn starts the session over
    (a new character is a new handshake), which ends a remote view and the checks waiting on it.
    `units`: a wider radius in which the biters and spitters alone go (nests and worms stay): the
    groups already on their way from further off."""
    at = "c.position" if x is None else f"{{ {x}, {y} }}"
    wide = (f"for _, e in pairs(c.surface.find_entities_filtered({{ force = 'enemy', type = 'unit', position = {at}, radius = {units} }})) "
            "do e.destroy() end ") if units else ""
    mod_lua("local c = storage.f3d.puppet if c and c.valid then "
            f"for _, e in pairs(c.surface.find_entities_filtered({{ force = 'enemy', position = {at}, radius = {radius} }})) do e.destroy() end "
            + wide +
            "pcall(function() c.health = c.max_health end) pcall(function() c.health = c.prototype.get_max_health() end) end")


class Client:
    def __init__(self, factorio_port=34200, port=34201):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
        self.sock.bind(("127.0.0.1", port))
        self.sock.settimeout(0.05)
        self.dest = ("127.0.0.1", factorio_port)
        self.sid = f"live-{int(time.time())}"
        self.max_size = {}
        self.me = None
        self.inv = {}
        self.protos = {}
        self.proto_recs = {}  # id -> the whole `protos` record (pipevis hands them to the client's own rule)
        self.items = {}
        self.tiles = {}
        self.eprops = None
        self.quals = []
        self.iuse = {}  # (item, kind) -> `iuse` record
        self.invalid = []
        self.last = {}  # message type (eq: "eq char" / "eq veh") -> the latest one
        self.datagrams = self.binary_datagrams = 0  # received, and of them binary frames (--binary)

    def send(self, msg):
        if BINARY and msg.get("t") == "hello":
            msg = dict(msg, bin=protocol.WIRE_VERSION)  # --binary: binary frames (docs/PROTOCOL.md)
        self.sock.sendto(json.dumps(msg).encode(), self.dest)

    def pump(self, seconds, until=None, every=None):
        """Receives for up to `seconds`; returns all messages. `every` = (interval, msg) to repeat."""
        out, end, next_send = [], time.time() + seconds, 0.0
        while time.time() < end:
            if every and time.time() >= next_send:
                self.send(every[1])
                next_send = time.time() + every[0]
            try:
                data, _ = self.sock.recvfrom(65536)
            except (socket.timeout, ConnectionResetError):
                continue
            self.datagrams += 1
            self.binary_datagrams += data[:1] == bytes((protocol.WIRE_MAGIC,))
            # (One message, or for a `bin` hello binary frames: several, the `dg` one counted, not kept.)
            stop = False
            for msg in protocol.split_datagram(data):
                if msg.get("t") == "dg":
                    continue
                t = msg.get("t")
                self.max_size[t] = max(self.max_size.get(t, 0), len(data))
                problems = protocol.problems(msg)
                if problems:
                    self.invalid.append((t, problems))
                self.last[f"eq {msg.get('kind')}" if t == "eq" else t] = msg
                if t == "me":
                    self.me = msg
                elif t == "inv":
                    self.inv = {name: count for name, count in msg["l"]}
                elif t == "protos":
                    for rec in msg["l"]:
                        self.protos[rec[0]] = (rec[1], rec[2])
                        self.proto_recs[rec[0]] = rec
                elif t == "iprotos":
                    for rec in msg["l"]:
                        self.items[rec[0]] = rec[1]
                elif t == "tprotos":
                    for rec in msg["l"]:
                        self.tiles[rec[1]] = rec[0]
                elif t == "quals":
                    self.quals = msg["l"]
                elif t == "eprops":
                    self.eprops = {rec[0]: rec[1:] for rec in msg["l"]}
                elif t == "iuse":
                    for rec in msg["l"]:
                        self.iuse[(rec[0], rec[1])] = rec
                out.append(msg)
                if until and until(msg):
                    stop = True
                    break
            if stop:
                break
        return out

    def proto_id(self, name):
        return next(i for i, (n, _) in self.protos.items() if n == name)


def of_type(msgs, t):
    return [m for m in msgs if m.get("t") == t]


BINARY = False  # --binary: every hello asks for binary frames (`bin`)
SPOT_WHY = ""
WATCH_PENDING = []


def clean_spot(c, hello, half=14):
    """Moves the character to the nearest dry, empty square (2 * half tiles) and watches the chunks
    around it. Building checks need room: earlier checks leave the character wherever the car
    or train stopped (often by water, or among the cliffs), and a reused save has the owner's base and
    trees about. A character in a vehicle gets out first (it can't be teleported in one), and one
    still coming down in a cargo pod (after the planets check) is waited for. Nothing
    near the character: the nearest such square to the force's spawn. The 3x3
    chunks around the spot must all exist, since watch_around waits for their snapshots. No empty
    square within 160 tiles of either (a forest, the base the earlier checks built: 0.1.2's CI run
    found none for the alt check): the nearest square with only trees, rocks, fish and cliffs on it,
    cleared, its water filled with landfill. (No Lua comments below: the code is sent as one line.)"""
    end = time.time() + 30
    while time.time() < end and mod_lua("local c = storage.f3d.puppet local ok, pod = pcall(function() return c.cargo_pod end) "
                                        "rcon.print((not c or (ok and pod)) and 'pod' or 'free')") != "free":
        c.pump(0.5, every=hello)
    out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface
if c.vehicle then c.driving = false end
local function clean(x, y)
  local area = {{ {{ x - {half}, y - {half} }}, {{ x + {half}, y + {half} }} }}
  for dy = -1, 1 do for dx = -1, 1 do
    if not s.is_chunk_generated({{ math.floor(x / 32) + dx, math.floor(y / 32) + dy }}) then return false end
  end end
  return s.count_tiles_filtered({{ area = area, collision_mask = "water_tile", limit = 1 }}) == 0
    and s.count_entities_filtered({{ area = area, type = {{ "character", "corpse" }}, invert = true, limit = 1 }}) == 0
end
local spawn = c.force.get_spawn_position(s)
for _, o in pairs({{ c.position, spawn }}) do
  local x0, y0 = math.floor(o.x), math.floor(o.y)
  for r = 0, 160, 8 do
    for dy = -r, r, 8 do for dx = -r, r, 8 do
      if math.max(math.abs(dx), math.abs(dy)) == r and clean(x0 + dx, y0 + dy) then
        c.teleport({{ x0 + dx + 0.5, y0 + dy + 0.5 }})
        rcon.print(c.position.x .. " " .. c.position.y) return
      end
    end end
  end
end
local NATURAL = {{ "tree", "simple-entity", "fish", "cliff" }}
local function clearable(x, y)
  local area = {{ {{ x - {half}, y - {half} }}, {{ x + {half}, y + {half} }} }}
  for dy = -1, 1 do for dx = -1, 1 do
    if not s.is_chunk_generated({{ math.floor(x / 32) + dx, math.floor(y / 32) + dy }}) then return nil end
  end end
  local others = {{ "character", "corpse", "tree", "simple-entity", "fish", "cliff" }}
  return s.count_entities_filtered({{ area = area, type = others, invert = true, limit = 1 }}) == 0 and area or nil
end
for _, o in pairs({{ c.position, spawn }}) do
  local x0, y0 = math.floor(o.x), math.floor(o.y)
  for r = 0, 160, 8 do
    for dy = -r, r, 8 do for dx = -r, r, 8 do
      local area = math.max(math.abs(dx), math.abs(dy)) == r and clearable(x0 + dx, y0 + dy)
      if area then
        for _, e in pairs(s.find_entities_filtered({{ area = area, type = NATURAL }})) do e.destroy() end
        local tiles = {{}}
        for _, t in pairs(s.find_tiles_filtered({{ area = area, collision_mask = "water_tile" }})) do
          tiles[#tiles + 1] = {{ name = "landfill", position = t.position }}
        end
        if #tiles > 0 then s.set_tiles(tiles) end
        c.teleport({{ x0 + dx + 0.5, y0 + dy + 0.5 }})
        rcon.print(c.position.x .. " " .. c.position.y) return
      end
    end end
  end
end
rcon.print("none")
""".replace("\n", " "))
    global SPOT_WHY
    if out == "none" or not out:
        SPOT_WHY = f"no empty square: {out!r}"
        return False
    x, y = (float(v) for v in out.split())
    ok = watch_around(c, hello, x, y)
    SPOT_WHY = f"found ({x}, {y}); chunks watched: {ok} (still waiting for {WATCH_PENDING}; {rcon.run('/f3d-status').splitlines()[0] if not ok else ''}); me: {c.me and (c.me['x'] / 256, c.me['y'] / 256)}"
    return ok


def watch_around(c, hello, x, y):
    """Subscribes the chunks around (x, y), where the character now is, and waits for them."""
    cx, cy = int(x // 32), int(y // 32)
    wanted = [[cx + dx, cy + dy] for dy in range(-1, 2) for dx in range(-1, 2)]
    c.send({"t": "sub", "c": []})  # so every chunk below is new and comes as a snapshot
    c.send({"t": "sub", "c": wanted})
    c.send({"t": "focus", "x": int(x * 256), "y": int(y * 256), "r": 48})
    # Wait for the new chunks' snapshots: until they are through, adds queue up behind them.
    pending = {(cx_, cy_) for cx_, cy_ in wanted}
    end, again = time.time() + 20, time.time() + 4
    while pending and time.time() < end:
        if time.time() > again and len(pending) == len(wanted):
            # Nothing yet: the sub may have been lost (seen in the full run), so ask again.
            c.send({"t": "sub", "c": wanted})
            c.send({"t": "focus", "x": int(x * 256), "y": int(y * 256), "r": 48})
            again = time.time() + 4
        for m in c.pump(0.5, every=hello):
            if m.get("t") == "ents" and m["part"] == m["parts"]:
                pending.discard((m["cx"], m["cy"]))
    c.pump(0.5, every=hello)
    global WATCH_PENDING
    WATCH_PENDING = sorted(pending)
    return not pending and c.me is not None and abs(c.me["x"] / 256 - x) < 1 and abs(c.me["y"] / 256 - y) < 1


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
    did = {rec[1]: rec[0] for m in of_type(msgs, "dprotos") for rec in m["l"]}
    dec = {}
    for m in of_type(msgs, "dec"):
        dec.setdefault((m["cx"], m["cy"]), []).extend(m["l"] if isinstance(m["l"], list) else [])
    n = sum(len(v) // 4 for v in dec.values())
    report(len(did) > 20 and len(dec) == len(wanted),
           "dc: the decorative dictionary (prototypes.decorative) and each chunk's decoratives (find_decoratives_filtered)",
           f"{len(did)} prototypes, {len(dec)} of {len(wanted)} chunks, {n} decoratives")
    name = "green-carpet-grass" if "green-carpet-grass" in did else next(iter(did), "")
    tx, ty = int(x) + 6, int(y) - 6
    out = mod_lua(f"""
local s = storage.f3d.puppet.surface
s.create_decoratives({{ check_collision = false, decoratives = {{ {{ name = "{name}", position = {{ {tx}, {ty} }}, amount = 3 }} }} }})
rcon.print(#s.find_decoratives_filtered({{ area = {{ {{ {tx}, {ty} }}, {{ {tx} + 1, {ty} + 1 }} }} }}))
""".replace("\n", " "))
    c.pump(0.5, every=on)
    mod_lua(f"""
local s = storage.f3d.puppet.surface
s.destroy_decoratives({{ area = {{ {{ {tx}, {ty} }}, {{ {tx} + 1, {ty} + 1 }} }} }})
s.set_tiles({{ {{ name = "concrete", position = {{ {tx}, {ty} }} }} }}, true, true, true, true)
""".replace("\n", " "))
    msgs = c.pump(1.5, every=on)
    k = (tx // 32, ty // 32)
    again = [m for m in of_type(msgs, "dec") if (m["cx"], m["cy"]) == k]
    l = again[-1]["l"] if again and isinstance(again[-1]["l"], list) else []
    here = [l[i:i + 4] for i in range(0, len(l), 4) if (l[i + 1], l[i + 2]) == (tx - k[0] * 32, ty - k[1] * 32)]
    remaining = mod_lua(f"rcon.print(#storage.f3d.puppet.surface.find_decoratives_filtered({{ area = {{ {{ {tx}, {ty} }}, {{ {tx} + 1, {ty} + 1 }} }} }}))")
    report(out.strip().isdigit() and int(out) >= 1 and bool(again) and not here and remaining.strip() == "0",
           "a tile placed where decoratives were destroyed sends the chunk's decoratives again, without them",
           f"placed {out.strip()}, after the tile {remaining.strip()} left; {len(again)} dec for chunk {k}, {here}")
    c.send(hello[1])
    c.pump(0.5, every=hello)


def check_cliffs(c, hello):
    """Cliffs carry their cliff_orientation (extra.co), the piece the client draws: the nearest
    cliff's chunk is watched and its record compared with the game's."""
    out = mod_lua("local c = storage.f3d.puppet "
                  "local e = c.surface.find_entities_filtered({ type = 'cliff', position = c.position, radius = 400, limit = 1 })[1] "
                  "if e then rcon.print(e.position.x .. ' ' .. e.position.y .. ' ' .. e.cliff_orientation) else rcon.print('none') end")
    if out == "none" or not out:
        report(True, "cliffs: none within 400 tiles of the character, skipped")
        return
    x, y, co = out.split()
    x, y = float(x), float(y)
    cx, cy = int(x // 32), int(y // 32)
    c.send({"t": "sub", "c": []})
    c.send({"t": "sub", "c": [[cx, cy]]})
    msgs = c.pump(8, every=hello, until=lambda m: m.get("t") == "ents" and [m["cx"], m["cy"]] == [cx, cy] and m["part"] == m["parts"])
    fx, fy = int(math.floor(x * 256 + 0.5)), int(math.floor(y * 256 + 0.5))
    recs = [e for m in of_type(msgs, "ents") for e in m["e"] if e[2] == fx and e[3] == fy and e[1] == c.proto_id("cliff")]
    report(recs and len(recs[0]) > 5 and recs[0][5].get("co") == co, "a cliff's record carries its orientation (extra.co)",
           f"{co} at {x}, {y}: {recs[:1]}")


def check_alerts(c, hello):
    """Alerts without a player (scripts/alerts.lua, `al`): a turret with no ammo, a chest hit by the
    enemy and one destroyed, a ghost in a roboport's network that has none of its item. (The cloud
    session's check, moved to the info branch's alert kinds and entries [x, y, si, name, unit, item?].)"""
    out = mod_lua("""local c = storage.f3d.puppet local s = c.surface local p = c.position local made = {}
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
    mod_lua('package.loaded["__factorio-3d-bridge__/scripts/alerts.lua"].reset()')
    msgs = c.pump(4.0, every=hello)
    al = of_type(msgs, "al")
    kinds = {rec[0]: rec for rec in al[-1]["l"]} if al else {}
    report("no_ammo" in kinds, "alerts: a turret without ammo in `al` (entity.status no_ammo)", str(kinds.get("no_ammo"))[:200])
    report("attack" in kinds, "alerts: a chest hit by the enemy (on_entity_damaged's force)", str(kinds.get("attack"))[:200])
    report("destroyed" in kinds, "alerts: a chest destroyed (on_entity_died)", str(kinds.get("destroyed"))[:200])
    mat = kinds.get("no_material")
    report(bool(mat) and any(e[3] == "assembling-machine-1" for e in mat[2]),
           "alerts: a ghost in a network without its item (ghost_prototype.items_to_place_this, get_item_count)", str(mat)[:200])
    print(f"     alert kinds seen: {sorted(kinds)} (informational)")
    destroy_units(units)


def check_multi(c, hello):
    """Two clients on one server (session.lua): the second on its own port gets its own state and
    character; each sees the other's character as a mover; bye drops only it."""
    port2 = SECOND_CLIENT_PORT or CLIENT_PORT + 1
    c2 = Client(FACTORIO_PORT, port2)
    c2.sid += "-second"
    hello2 = (1.0, {"t": "hello", "v": 1, "sid": c2.sid, "w": 1})
    c.send(hello[1])
    msgs = c2.pump(6, until=lambda m: m.get("t") == "ready", every=(1.0, {"t": "hello", "v": 1, "sid": c2.sid, "w": 0}))
    welcome = of_type(msgs, "welcome")
    first_unit = c.me.get("u") if c.me else None
    report(bool(welcome) and welcome[0]["u"] != first_unit and bool(of_type(msgs, "ready")),
           "two clients: the second gets its own welcome, prototypes and character", f"{welcome[:1]}, first is {first_unit}")
    if not welcome:
        c2.sock.close()
        return
    # Earlier sections moved the first character about: put the second next to it, and both
    # clients' focus there, so each is within the other's mover radius.
    out = mod_lua(f"local s = storage.f3d_extra[{port2}] local a = storage.f3d.puppet "
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
    report(bool(of_type(msgs2, "chunk")) and not of_type(msgs1, "welcome"), "the second gets its chunks; the first carries on without a new handshake")
    seen1 = {r[0] for m in of_type(msgs1, "mv") for r in m["l"]}
    seen2 = {r[0] for m in of_type(msgs2, "mv") for r in m["l"]}
    report(welcome[0]["u"] in seen1 and first_unit in seen2, "each sees the other's character as a mover",
           f"{welcome[0]['u']} in first: {welcome[0]['u'] in seen1}, {first_unit} in second: {first_unit in seen2}")
    status = rcon.run("/f3d-status")
    report(f"another client on port {port2}" in status, "/f3d-status lists the second client", status.replace("\n", " | ")[:300])
    c2.send({"t": "bye"})
    c2.pump(0.5)
    c2.sock.close()
    out = mod_lua("local n = 0 for _ in pairs(storage.f3d_extra or {}) do n = n + 1 end local p = 0 "
                  "for sid, ch in pairs(storage.f3d_parked or {}) do if ch.valid then p = p + 1 ch.destroy() end end "
                  "storage.f3d_parked = {} rcon.print(n .. ' ' .. p)")
    report(out == "0 1", "bye drops the second client and parks its character for its return", out)
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
    report(welcome.get("ext") == 1, "link: the welcome says ext 1", str(welcome.get("ext")))
    if LINK_CH not in welcome.get("mods", {}):
        print(f"  (the fixture mod {LINK_CH} isn't on this server: copy tools/mod_tests/fixtures/{LINK_CH} into its mods)")
        report(False, "link: the fixture mod is in the game", str(sorted(welcome.get("mods", {}))))
        return
    rcon.run('/c remote.call("linktest", "reset")')
    state = link_get()
    print(f"  the fixture mod came by {state.get('came_by')}; the bridge's link() says {state.get('link')}")
    report(state.get("came_by") in ("on_init", "on_load") and state.get("link") == 1,
           "link: the fixture mod found the bridge's interface and registered for its events", str(state))

    def replies(seconds, until=None):
        return [m for m in of_type(c.pump(seconds, every=hello, until=until), "ext") if m.get("ch", "").startswith(LINK_CH)]

    token = f"t{int(time.time())}"
    t0 = time.time()
    c.send({"t": "ext", "ch": LINK_CH, "d": {"echo": token}})
    got = replies(3.0, until=lambda m: m.get("t") == "ext" and m.get("d") == {"echo": token})
    took = time.time() - t0
    report(any(m.get("d") == {"echo": token} for m in got), "link: an echo there and back", f"{took * 1000:.0f} ms")
    c.send({"t": "ext", "ch": LINK_CH + "/who", "d": {"who": 1}})
    who = [m["d"] for m in replies(3.0, until=lambda m: m.get("ch") == LINK_CH + "/who")]
    me_unit = c.me.get("u") if c.me else None
    report(who and who[-1].get("client") == CLIENT_PORT and who[-1].get("unit") == me_unit,
           "link: who names this client and its character (character(client))", f"{who[-1:]} me {me_unit}")
    before = link_get().get("n", 0)
    c.send({"t": "ext", "ch": "bad channel", "d": {"echo": 1}})
    c.send({"t": "ext", "ch": LINK_CH})
    c.send({"t": "ext", "ch": "zenith-not-a-mod-here", "d": {"echo": 1}})
    c.send({"t": "ext", "ch": LINK_CH, "d": {"echo": "x" * 4100}})
    bad = replies(1.5)
    report(not bad and link_get().get("n", 0) == before, "link: a bad channel, no data, a mod not in the game and over 4 KB dropped",
           f"{len(bad)} answers, {link_get().get('n', 0) - before} raised")
    c.pump(1.2, every=hello)  # a fresh window of 60 ticks
    c.send({"t": "ext", "ch": LINK_CH + "/flood", "d": {"flood": 100}})
    flood = replies(3.0)
    state = link_get()
    report(state.get("flood") == 60 and len(flood) == 60, "link: a mod's flood of 100 stops at the cap (60 per 60 ticks)",
           f"send took {state.get('flood')}, {len(flood)} arrived")
    c.pump(1.2, every=hello)
    c.send({"t": "ext", "ch": LINK_CH, "d": {"big": 1}})
    c.pump(1.0, every=hello)
    report(link_get().get("big") == "too big", "link: a message over 4 KB is refused (too big)", str(link_get().get("big")))
    c.pump(1.2, every=hello)
    before = link_get().get("n", 0)
    for i in range(80):
        c.send({"t": "ext", "ch": LINK_CH, "d": {"n": i}})
    c.pump(1.0, every=hello)
    took_in = link_get().get("n", 0) - before
    report(took_in == 60, "link: a client's flood of 80 in a moment: 60 raised (the cap in)", str(took_in))
    # A second client: its own messages, its own character, answered alone; its coming and going raised.
    port2 = SECOND_CLIENT_PORT or CLIENT_PORT + 1
    c2 = Client(FACTORIO_PORT, port2)
    c2.sid += "-link"
    c.send(hello[1])
    msgs = c2.pump(6, until=lambda m: m.get("t") == "ready", every=(1.0, {"t": "hello", "v": 1, "sid": c2.sid, "w": 0}))
    w2 = of_type(msgs, "welcome")
    if w2:
        hello2 = (1.0, {"t": "hello", "v": 1, "sid": c2.sid, "w": 1})
        c2.send({"t": "ext", "ch": LINK_CH + "/who", "d": {"who": 1}})
        who2 = [m["d"] for m in of_type(c2.pump(3.0, every=hello2, until=lambda m: m.get("t") == "ext"), "ext")]
        first = replies(1.0)
        report(who2 and who2[-1].get("client") == port2 and who2[-1].get("unit") == w2[0]["u"] and not first,
               "link: a second client's who names it and its character, answered to it alone", f"{who2[-1:]}, first got {len(first)}")
        c2.send({"t": "bye"})
        c2.pump(0.5)
        joined = [(e.get("client"), e.get("joined")) for e in link_get().get("clients", [])]
        report((port2, True) in joined and (port2, False) in joined, "link: the second client's coming and going raised on_client", str(joined))
        mod_lua("for sid, ch in pairs(storage.f3d_parked or {}) do if ch.valid then ch.destroy() end end storage.f3d_parked = {} rcon.print('ok')")
    else:
        report(False, "link: a second client connects")
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
        report(False, "sprint: the zenith-sprint mod is in the game and this client has a character", f"{has}, unit {unit}")
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
    report(base == 0.25 and on == 0.75 and held == 0.75, "sprint: on adds the bonus once, held for 3 s it stays",
           f"before {base}, on {on}, held {held}")
    rcon.run(f"/c local e = {char} e.character_running_speed_modifier = e.character_running_speed_modifier + 0.1")
    say({"on": False})
    off = mod()
    report(off == 0.35, "sprint: off takes only its own bonus back (another mod's +0.25 and +0.1 made meanwhile survive)", str(off))
    for bad in ({"on": "yes"}, {"on": 1}, [True], "on", {"off": True}, {"on": None}):
        say(bad, 0.1)
    c.send({"t": "ext", "ch": SPRINT_CH + "/x", "d": {"on": True}})
    c.pump(0.4, every=hello)
    report(mod() == 0.35, "sprint: messages it doesn't expect (and another topic) change nothing", str(mod()))
    say({"on": True})
    started = time.time()
    c.pump(0.9, every=hello)
    mid = mod()
    c.pump(1.2, every=hello)  # 90 ticks and the 15-tick check after the last word
    after = mod()
    report(mid == 0.85 and after == 0.35, "sprint: 90 ticks without a word end the sprint by itself",
           f"{mid} after 0.9 s, {after} after {time.time() - started:.1f} s")
    # A client dropping mid-sprint: a goodbye, then nothing more from it.
    say({"on": True})
    dropped_on = mod()
    c.send({"t": "bye"})
    c.pump(2.2)
    gone = mod()
    report(dropped_on == 0.85 and gone == 0.35, "sprint: a client dropping mid-sprint: the bonus off within 90 ticks",
           f"{dropped_on} then {gone}")
    rcon.run(f"/c local e = {char} if e then e.character_running_speed_modifier = 0 end")
    # Back again, for the link's robustness.
    msgs = c.pump(6, until=lambda m: m.get("t") == "ready", every=(1.0, {"t": "hello", "v": 1, "sid": c.sid, "w": 0}))
    report(of_type(msgs, "welcome"), "sprint: the client comes back after its goodbye")
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
    report(isinstance(got.get("n"), int) and got.get("n") <= 9, "link: garbage `ext` neither errors nor reaches a mod it isn't for",
           str(got.get("n")))
    status = rcon.run("/f3d-status")
    report("ERROR" not in status, "link: and no step failed", status.replace("\n", " | ")[:300])
    # A stranger's port (no hello) is dropped; an `ext` right after a new client's hello, before its welcome.
    rcon.run('/c remote.call("linktest", "reset")')
    stranger = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    stranger.bind(("127.0.0.1", 0))
    for _ in range(5):
        stranger.sendto(json.dumps({"t": "ext", "ch": LINK_CH, "d": {"echo": "stranger"}}).encode(), c.dest)
    c.pump(0.6, every=hello)
    report(link_get().get("n") == 0, "link: an `ext` from a port that never said hello is dropped", str(link_get().get("n")))
    port3 = (SECOND_CLIENT_PORT or CLIENT_PORT + 1) + 1
    c3 = Client(FACTORIO_PORT, port3)
    c3.sid += "-early"
    c3.send({"t": "hello", "v": 1, "sid": c3.sid, "w": 0})
    c3.send({"t": "ext", "ch": LINK_CH, "d": {"echo": "early"}})
    msgs = c3.pump(6, until=lambda m: m.get("t") == "ready", every=(1.0, {"t": "hello", "v": 1, "sid": c3.sid, "w": 0}))
    early = [m for m in of_type(msgs, "ext") if m.get("d") == {"echo": "early"}]
    w3 = of_type(msgs, "welcome")
    order = [m.get("t") for m in msgs if m.get("t") in ("welcome", "ext")]
    print(f"  INFO: an `ext` sent with a new client's first hello: {len(early)} echo back, order {order[:4]}")
    report(w3 and link_get().get("n", 0) == 0 and not early, "link: an `ext` before the client's handshake is done is dropped",
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
    errs = [m for m in of_type(c.pump(1.0, every=hello), "ext") if "err" in m]
    c.send({"t": "ext", "ch": LINK_CH, "d": {"echo": "after boom"}})
    after = [m for m in of_type(c.pump(2.0, every=hello), "ext") if m.get("d") == {"echo": "after boom"}]
    status = rcon.run("/f3d-status")
    tick = rcon.run("/c rcon.print(game.tick)").strip()
    print(f"  INFO: after a companion's handler failed: the game at tick {tick}, err {[m.get('err', '')[:160] for m in errs]},"
          f" an echo after it {'came' if after else 'did not come'};"
          f" /f3d-status: {' | '.join(l for l in status.splitlines() if 'ERROR' in l)[:300] or 'no error'}")
    report(len(errs) == 1 and errs[0].get("ch") == LINK_CH + "/boom" and "boom" in errs[0].get("err", "") and "d" not in errs[0],
           "link: a companion's failing handler: its error comes back to the add-on on its channel", str(errs)[:300])
    report(tick.isdigit() and after and "step 'link'" not in status,
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
    errs = [m for m in of_type(msgs, "ext") if "err" in m and m.get("ch") == boom_ch]
    closed = [m for m in errs if "closed" in m.get("err", "")]
    booms = [m for m in errs if "boom" in m.get("err", "")]
    print(f"  INFO: nine more booms: {len(booms)} boom errors, closing err {[m.get('err') for m in closed]}")
    report(len(booms) == 9 and len(closed) == 1 and errs[-1] is closed[0] and "10 within 60 s" in closed[0].get("err", ""),
           "link: the tenth error within a minute closes the channel and says so once, last", str([m.get("err", "")[:60] for m in errs])[:300])
    n_before = link_get().get("n", 0)
    c.send({"t": "ext", "ch": boom_ch, "d": {"boom": 1}})
    c.send({"t": "ext", "ch": boom_ch, "d": {"echo": "closed?"}})
    c.send({"t": "ext", "ch": LINK_CH, "d": {"echo": "still open"}})
    msgs = of_type(c.pump(2.0, every=hello), "ext")
    on_closed = [m for m in msgs if m.get("ch") == boom_ch]
    still = [m for m in msgs if m.get("d") == {"echo": "still open"}]
    raised_n = link_get().get("n", 0) - n_before
    status = rcon.run("/f3d-status")
    report(not on_closed and still and raised_n == 1 and "step 'link'" not in status,
           "link: then the closed channel drops quietly (nothing raised or sent), the mod's other topic still answers",
           f"on the closed channel {on_closed}, other topic {bool(still)}, raised {raised_n}")
    barrier_forget = mod_lua("local b = package.loaded['__factorio-3d-bridge__/scripts/barrier.lua'] "
                             "if b and b.forget then b.forget('link') b.forget('packet') end rcon.print('ok')")
    mod_lua("for sid, ch in pairs(storage.f3d_parked or {}) do if ch.valid then ch.destroy() end end storage.f3d_parked = {} rcon.print('ok')")
    c.pump(0.5, every=hello)


def check_remnants(c, hello):
    """Remnants (extra.rm): a destroyed assembler's and rail's remnants come as an `add` naming
    what left them, a chunk snapshot carries them too, building over them removes them in the
    game (the client drops those itself), and a linked belt's record carries its end (extra.u)."""
    if not clean_spot(c, hello):
        report(False, "remnants: no clean spot to build on")
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    ax, ay = math.floor(x) + 6.5, math.floor(y) + 0.5
    rx, ry = 2 * math.floor(x / 2) - 6, 2 * math.floor(y / 2) + 1  # rails sit on the 2x2 grid
    mod_lua(f"""
local s = storage.f3d.puppet.surface
storage.f3d_rm_am = s.create_entity({{ name = 'assembling-machine-1', position = {{ {ax}, {ay} }}, force = 'player', raise_built = true }})
storage.f3d_rm_rail = s.create_entity({{ name = 'straight-rail', position = {{ {rx}, {ry} }}, force = 'player', raise_built = true }})
rcon.print('ok')""".replace("\n", " "))
    c.pump(1.0, every=hello)
    mod_lua("storage.f3d_rm_am.die() storage.f3d_rm_rail.die() rcon.print('ok')")
    msgs = c.pump(3.0, every=hello)
    adds = [m["e"] for m in of_type(msgs, "add")]
    am, am_rm = c.proto_id("assembling-machine-1"), c.proto_id("assembling-machine-1-remnants")
    got = [e for e in adds if e[1] == am_rm]
    report(got and len(got[0]) > 5 and got[0][5].get("rm") == am,
           "a destroyed assembler's remnants come as an add naming it (extra.rm)", str(got[:1]))
    rail_rm = [e for e in adds if c.protos.get(e[1], ("", ""))[1] == "rail-remnants"]
    report(rail_rm and len(rail_rm[0]) > 5 and rail_rm[0][5].get("rm") == c.proto_id("straight-rail"),
           "a destroyed rail's remnants come as an add naming it", str(rail_rm[:1]))
    # A fresh snapshot of the chunk carries the remnants too (corpses are looked up by name).
    cx, cy = int(ax // 32), int(ay // 32)
    c.send({"t": "resync", "full": 0, "c": [[cx, cy]]})
    msgs = c.pump(6, every=hello, until=lambda m: m.get("t") == "ents" and [m["cx"], m["cy"]] == [cx, cy] and m["part"] == m["parts"])
    snap = [e for m in of_type(msgs, "ents") for e in m["e"] if e[1] == am_rm]
    report(snap and snap[0][5].get("rm") == am, "a chunk snapshot carries remnants", str(snap[:1]))
    # Building over remnants removes them in the game, without an event.
    out = mod_lua(f"""
local s = storage.f3d.puppet.surface
local e = s.create_entity({{ name = 'assembling-machine-1', position = {{ {ax}, {ay} }}, force = 'player', raise_built = true }})
local left = s.count_entities_filtered({{ position = {{ {ax}, {ay} }}, radius = 1, name = 'assembling-machine-1-remnants' }})
if e then e.destroy() end
rcon.print(tostring(left))""".replace("\n", " "))
    report(out == "0", "building over remnants removes them in the game (the client drops them on the add)", out)
    # A linked belt's end (linked_belt_type).
    out = mod_lua(f"""
local world = package.loaded['__factorio-3d-bridge__/scripts/world.lua']
local s = storage.f3d.puppet.surface
local e = s.create_entity({{ name = 'linked-belt', position = {{ {ax}, {ay + 4} }}, force = 'player' }})
if not e then rcon.print('none') return end
e.linked_belt_type = 'output'
rcon.print(helpers.table_to_json(world.record(e)))
e.destroy()""".replace("\n", " "))
    report(out.startswith("[") and '"u":"o"' in out, "a linked belt's record carries its end (extra.u)", out)


def check_turrets(c, hello):
    """Turret states (`ts`, turrets.lua): real turrets with ammo, fluid and power, a tank the
    character drives and shoots from, a spidertron and an artillery turret, with biters to the
    north (they come once the mod watches the turrets). Each turret's record has its weapon's orientation, its target and the shots counted
    from its ammo (or its hits)."""
    if not clean_spot(c, hello, half=20):
        report(False, "turrets: no clean spot to build on", SPOT_WHY)
        return
    x, y = math.floor(c.me["x"] / 256) + 0.5, math.floor(c.me["y"] / 256) + 0.5
    # The tank stands north-east of the row: Factorio's cannon shells hit the player's own
    # buildings in their way (from behind the row they killed the laser turret).
    out = mod_lua(f"""
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
        report(False, "turrets: built the row", out)
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
        mod_lua(refill)
        if i == 20 and "railgun-turret" in made:
            rail = mod_lua("local st = {} for k, v in pairs(defines.entity_status) do st[v] = k end "
                           f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'railgun-turret' }})) do "
                           f"if e.unit_number == {made['railgun-turret']} then rcon.print(st[e.status] .. ' energy ' .. e.energy .. "
                           "' ammo ' .. e.get_inventory(defines.inventory.turret_ammo).get_item_count() .. ' target ' .. tostring(e.shooting_target)) end end")
        if i == 8:
            seen = mod_lua("local out = {} for u, e in pairs(storage.f3d.turrets or {}) do "
                           "out[#out + 1] = u .. (e.valid and (':' .. e.name .. ':' .. tostring(e.health)) or ':gone') end "
                           "rcon.print(table.concat(out, ' '))")
        for m in of_type(c.pump(0.5, every=(0.2, shoot)), "ts"):
            for rec in m["l"]:
                recs.setdefault(rec[0], []).append(rec)
    names = {u: n for n, u in made.items()}

    def shots(name):
        return sum(r[2] for r in recs.get(made.get(name), []))

    def targeted(name):
        return any(len(r) == 6 for r in recs.get(made.get(name), []))

    gun = recs.get(made.get("gun-turret"), [])
    north = [r for r in gun if len(r) == 6 and (r[1] > 850 or r[1] < 150)]
    report(gun and shots("gun-turret") > 0 and north, "ts: a gun turret's shots from its ammo, its target and its weapon's "
           "orientation towards it (LuaEntity.orientation)", f"{shots('gun-turret')} shots, {gun[-3:]}")
    report(targeted("laser-turret") and shots("laser-turret") > 0, "ts: a laser turret's target and shots (its hits)",
           f"{recs.get(made.get('laser-turret'), [])[-3:]}; watched turrets: {seen}")
    report(targeted("flamethrower-turret") and shots("flamethrower-turret") > 0, "ts: a flamethrower turret's target and shots (its stream's hits)",
           str(recs.get(made.get("flamethrower-turret"), [])[-3:]))
    for name in ("rocket-turret", "tesla-turret"):
        if name in made:
            report(targeted(name) and shots(name) > 0, f"ts: a {name}'s target and shots", str(recs.get(made[name], [])[-3:]))
    if "railgun-turret" in made:
        # It aims but seldom fires here: the ammo going down once is the round it loads. Its shots
        # are counted the same way as the others' (mock-checked). Its turn_range (0.2) is where it
        # takes targets, not a stop for its head: following a biter that walked out of it the head
        # went 0.217 from north on 0.2.0's CI (783; the old check failed there). So the head is
        # checked against the target it reports: on it, within 0.02 of the bearing from the turret,
        # once raised (its orientation reads 0 while it raises, the target already set). And loosely
        # the arc: the biters come from the north-west to the row, all within 0.26 of north from here.
        rail_recs = recs.get(made["railgun-turret"], [])
        at = mod_lua("for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({ name = 'railgun-turret' })) do "
                     f"if e.unit_number == {made['railgun-turret']} then rcon.print(e.position.x .. ' ' .. e.position.y) end end").split()
        px, py = (float(v) for v in at) if len(at) == 2 else (x + 12, y + 1)

        def off_target(r):
            bearing = (math.atan2(r[4] / 256 - px, -(r[5] / 256 - py)) / (2 * math.pi)) % 1
            d = abs(r[1] / 1000 - bearing) % 1
            return min(d, 1 - d)
        aims = [off_target(r) for r in rail_recs if len(r) == 6 and r[1] != 0]
        report(any(d < 0.02 for d in aims) and all(r[1] >= 700 or r[1] <= 300 for r in rail_recs),
               "ts: a railgun turret's target, its head turned onto it (within 0.02 of its bearing), within 0.3 of its facing",
               f"{shots('railgun-turret')} shots; {sum(d < 0.02 for d in aims)} of {len(aims)} raised aims on the target "
               f"(closest {min(aims) if aims else '-'}); orientations {sorted({r[1] for r in rail_recs})}; {rail_recs[-3:]}; {rail}")
    art = recs.get(made.get("artillery-turret"), [])
    report(art and shots("artillery-turret") > 0 and any(400 < r[1] < 600 for r in art),
           "ts: an artillery turret's cannon turned south to a nest 40 tiles off (relative_turret_orientation), its shells "
           "(2.1.23 gives no shooting_target for it)",
           f"{shots('artillery-turret')} shots, {art[-2:]}")
    report(made.get("spidertron") in recs and shots("spidertron") > 0,
           "ts: a spidertron's torso (torso_orientation) and the rockets it fires by itself", f"{shots('spidertron')} shots, {recs.get(made.get('spidertron'), [])[-2:]}")
    tank = recs.get(made.get("tank"), [])
    report(tank and any(len(r) == 6 and r[3] == 1 for r in tank) and shots("tank") > 0,
           "ts: the tank the character drives: its gunner's aim (shooting_state), its cannon (gun 1) and shots from car_ammo",
           f"{shots('tank')} shots, {tank[-3:]}")
    unknown = [u for u in recs if u not in names]
    c.send({"t": "shoot", "m": -1, "x": 0, "y": 0})
    c.pump(0.3, every=hello)
    mod_lua("local c = storage.f3d.puppet if c.vehicle then c.driving = false end "
            "for _, b in pairs(storage.f3d_tur_biters or {}) do if b.valid then b.destroy() end end")
    # The row to the nest 45 tiles south and the defenders it spawned; and every biter within 400 tiles: a group
    # from further off than the 96 (the artillery reaches 224) arrives checks later (once 12 small biters killed
    # the character in the middle of the underground check, and the platform and planet checks after it lost theirs).
    clear_enemies(96, x - 10.5, y + 20, units=400)
    destroy_units(list(made.values()))
    report(True, f"turrets: cleaned up ({len(unknown)} other turrets reported nearby)", str(made))


def check_platforms(c, hello):
    """Space platforms: build one (no rocket), board it, its chunks and state, its commands, back down."""
    if "space-platform-foundation" not in c.tiles:
        report(False, "space platforms: Space Age isn't enabled on this server")
        return
    # The remote view, the modules and the map below are asked for by one session all through: once
    # (CI) a leftover biter killed the character half way, and the respawn's new session lost them.
    clear_enemies()
    out = rcon.run("/f3d-platform new").strip()
    report("built in orbit of" in out, "/f3d-platform new: force.create_space_platform + apply_starter_pack", out)
    try:
        index = int(out.split("platform ")[1].split(" ")[0])
    except (IndexError, ValueError):
        return
    is_mine = lambda m: m.get("t") == "plat" and any(p["i"] == index for p in m["l"])
    plats = [m for m in c.pump(3, every=hello, until=is_mine) if is_mine(m)]
    rec = next((p for p in plats[-1]["l"] if p["i"] == index), {}) if plats else {}
    report(rec.get("hub", 0) > 0 and rec.get("loc") == "nauvis" and plats[-1].get("on") == 0 and plats[-1].get("here") == "nauvis",
           "plat: the new platform, its hub and where it is", f"{rec} here={plats[-1].get('here') if plats else None}")

    # #5: the remote view looks at the platform from Nauvis: its world streams while the character
    # stays put; building waits; si 0 brings Nauvis back.
    psi = int(mod_lua(f'rcon.print(game.forces.player.platforms[{index}].surface.index)') or 0)
    c.send({"t": "view", "si": psi, "x": 0, "y": 0})
    msgs = c.pump(SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "surface")
    vs = of_type(msgs, "surface")
    c.send({"t": "sub", "c": [[0, 0], [-1, -1], [-1, 0], [0, -1]]})
    # #12: building from the remote view puts a ghost on that surface. A new platform's foundation
    # lies under its hub, so a patch of foundation east of it first. F6: what is chosen must be
    # buildable on a platform: a chest needs gravity (2.1.23), so an assembler.
    spot = mod_lua(f'local s = game.get_surface({psi}) local t = {{}} for x = 6, 11 do for y = -6, 2 do '
                   't[#t + 1] = { name = "space-platform-foundation", position = { x, y } } end end '
                   's.set_tiles(t) rcon.print("8,0")') or ""
    gx, gy = (int(v) for v in spot.split(",")) if "," in spot else (8, 0)
    c.send({"t": "build", "item": "assembling-machine-2", "x": gx * 256 + 128, "y": gy * 256 + 128, "d": 0})
    c.send({"t": "mine", "u": 0, "p": 0, "x": gx * 256 + 128, "y": gy * 256 + 128})
    msgs = c.pump(3, every=hello)
    vtiles = {tid for m in of_type(msgs, "chunk") if m.get("tiles") for tid in m["tiles"][0::2]}
    report(bool(vs) and vs[0].get("view") == 1 and vs[0].get("pf") == index and c.tiles["space-platform-foundation"] in vtiles
           and mod_lua("rcon.print(storage.f3d.puppet.surface.name)") == "nauvis",
           "view: the platform's chunks stream for the remote view while the character stays on Nauvis (#5)", f"{vs[:1]} tiles {sorted(vtiles)}")
    ghost = json.loads(mod_lua(f'local s = game.get_surface({psi}) local g = s.find_entities_filtered{{ghost_name = "assembling-machine-2", '
                               f'position = {{{gx} + 0.5, {gy} + 0.5}}}}[1] rcon.print(helpers.table_to_json(g and {{ g.unit_number }} or {{}}))') or "[]")
    report(len(ghost) == 1, "view: building from the remote view places a ghost on the platform (#12)", f"{spot!r} {ghost!r}")
    report(any("another surface" in m.get("text", "") for m in of_type(msgs, "msg")),
           "view: mining by hand waits while another surface is shown")
    # F6: the platform is uncharted on a headless server, so the mod's fallback check must still
    # refuse what Factorio would: a ghost over empty space, and one the platform's gravity forbids.
    c.send({"t": "build", "item": "assembling-machine-2", "x": 20 * 256 + 128, "y": 128, "d": 0})
    c.send({"t": "build", "item": "wooden-chest", "x": 6 * 256 + 128, "y": -5 * 256 + 128, "d": 0})
    msgs = c.pump(1.5, every=hello)
    said = [m["text"] for m in of_type(msgs, "msg")]
    stray = mod_lua(f'local s = game.get_surface({psi}) local n = 0 for _, g in pairs(s.find_entities_filtered{{type = "entity-ghost"}}) do '
                    'if g.ghost_name == "wooden-chest" or g.position.x > 15 then n = n + 1 g.destroy() end end rcon.print(n)')
    report(stray == "0" and "Can't place that there" in said and any("gravity" in t for t in said),
           "view: no ghost over empty space, nor a chest the platform's gravity forbids (F6)", f"{stray} stray ghosts; {said}")
    # F6: modules from the remote view, Factorio's way: a ghost's insert plan, a building's item
    # request proxy (both without a player).
    if ghost:
        at = {"u": ghost[0], "p": c.proto_id("entity-ghost"), "x": gx * 256 + 128, "y": gy * 256 + 128}
        for _ in range(3):
            c.send({"t": "modreq", "item": "speed-module", **at})
        msgs = c.pump(1.5, every=hello)
        plan = mod_lua(f'local s = game.get_surface({psi}) local g = s.find_entities_filtered{{ghost_name = "assembling-machine-2"}}[1] '
                       'local t = {} for _, p in pairs(g and g.insert_plan or {}) do for _, at in pairs(p.items.in_inventory or {}) do '
                       't[#t + 1] = p.id.name .. "@" .. at.inventory .. ":" .. at.stack end end table.sort(t) '
                       'rcon.print(table.concat(t, " ") .. " | " .. serpent.line(g and g.item_requests or {}))')
        said = [m["text"] for m in of_type(msgs, "msg")]
        report(plan.startswith("speed-module@4:0 speed-module@4:1 |") and "The module slots are full" in said,
               "modreq: modules asked for on a ghost from the remote view go in its insert plan, one per slot (F6)", f"{plan}; {said}")
    built = json.loads(mod_lua(f'local s = game.get_surface({psi}) local e = s.create_entity{{name = "assembling-machine-2", '
                               'position = {8.5, -3.5}, force = "player"} rcon.print(helpers.table_to_json(e and { e.unit_number } or {}))') or "[]")
    if built:
        at = {"u": built[0], "p": c.proto_id("assembling-machine-2"), "x": 8 * 256 + 128, "y": -3 * 256 - 128}
        c.send({"t": "modreq", "item": "productivity-module", **at})
        c.pump(1.0, every=hello)
        proxy = mod_lua(f'local s = game.get_surface({psi}) local e = s.find_entity("assembling-machine-2", {{8.5, -3.5}}) '
                        'local p = e and e.item_request_proxy rcon.print(p and serpent.line(p.item_requests) or "none")')
        report("productivity-module" in proxy, "modreq: a building on the platform gets an item request proxy (F6)", proxy)
        c.send({"t": "modreq", "clr": 1, **at})
        c.pump(1.0, every=hello)
        proxy = mod_lua(f'local s = game.get_surface({psi}) local e = s.find_entity("assembling-machine-2", {{8.5, -3.5}}) '
                        'rcon.print(e and e.item_request_proxy and "still" or "gone")')
        report(proxy == "gone", "modreq clr: the request is taken back (the proxy goes)", proxy)
    # F6: the platform's map past its generated chunks charts as unknown instead of stopping the map.
    c.send({"t": "map", "cx1": 30, "cy1": 30, "cx2": 31, "cy2": 30, "res": 8, "si": psi})
    msgs = c.pump(2, every=hello)
    charts = [m for m in of_type(msgs, "chart") if m.get("si") == psi]
    report(charts and all(m["n"] == 0 for m in charts) and not any("Map error" in m["text"] for m in of_type(msgs, "msg")),
           "map: a platform's ungenerated chunks chart as unknown, no Map error (F6)", f"{[(m['cx'], m['cy'], m['n']) for m in charts]}")
    mod_lua(f'local s = game.get_surface({psi}) for _, e in pairs(s.find_entities_filtered{{name = {{"assembling-machine-2", "entity-ghost"}}}}) do e.destroy() end')
    c.send({"t": "view", "si": 0})
    msgs = c.pump(SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "surface")
    vs = of_type(msgs, "surface")
    report(bool(vs) and vs[0].get("planet") == "nauvis" and "view" not in vs[0], "view 0: back to the character's surface", str(vs[:1]))
    c.pump(0.5, every=hello)

    c.send({"t": "plat_board", "i": index})
    msgs = c.pump(SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "surface")
    surf = of_type(msgs, "surface")
    report(bool(surf) and surf[0].get("pf") == index and "planet" not in surf[0] and not of_type(msgs, "welcome"),
           "plat_board: the character crosses to the platform (teleport to another surface), and `surface` says so",
           f"{surf[:1]} {[m['text'] for m in of_type(msgs, 'msg')][-2:]}")
    if not surf:
        # Back on Nauvis whatever happened, so the checks after this don't all fail from the platform.
        rcon.run("/f3d-platform leave nauvis")
        c.pump(SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "surface")
        return
    x, y = surf[0]["x"] / 256, surf[0]["y"] / 256
    cx, cy = int(x // 32), int(y // 32)
    wanted = [[cx + dx, cy + dy] for dy in range(-1, 2) for dx in range(-1, 2)]
    c.send({"t": "sub", "c": wanted})
    c.send({"t": "focus", "x": int(x * 256), "y": int(y * 256), "r": 48})
    msgs = c.pump(8, every=hello, until=lambda m: m.get("t") == "ents" and [m["cx"], m["cy"]] == wanted[-1] and m["part"] == m["parts"])
    tile_ids = {tid for m in of_type(msgs, "chunk") if m.get("tiles") for tid in m["tiles"][0::2]}
    want_tiles = {c.tiles["space-platform-foundation"], c.tiles["empty-space"]}
    hubs = [e for m in of_type(msgs, "ents") for e in m["e"] if e[1] == c.proto_id("space-platform-hub")]
    report(want_tiles <= tile_ids and len(hubs) == 1 and hubs[0][0] == rec.get("hub"),
           "the platform's chunks: foundation in empty space, and the hub", f"tiles {sorted(tile_ids)}, hubs {hubs}")
    start = c.me["x"] if c.me else 0
    c.pump(1.0, every=(0.15, {"t": "walk", "d": 4}))
    c.send({"t": "walk", "d": -1})
    report(c.me is not None and c.me["x"] != start, "the character walks on the platform", f"moved {(c.me['x'] - start) / 256:.2f} tiles")

    c.send({"t": "plat_sched", "i": index, "l": ["nauvis"], "c": 1})
    c.send({"t": "plat_pause", "i": index, "p": 0})
    msgs = c.pump(2.5, every=hello)
    # The last `plat`: each command answers with one at once, so the first is plat_sched's, sent
    # before plat_pause has been handled.
    rec = next((p for m in reversed(of_type(msgs, "plat")) for p in m["l"] if p["i"] == index), {})
    report(rec.get("sch") == {"c": 1, "l": ["nauvis"]} and rec.get("pa") == 0 and of_type(msgs, "plat")[-1].get("on") == index,
           "plat_sched and plat_pause 0: the schedule and pause flag (LuaSpacePlatform.schedule, paused)", str(rec))
    report(isinstance(rec.get("w"), int) and rec["w"] > 0, "plat: the platform's mass for the remote view (LuaSpacePlatform.weight, kg)",
           str(rec.get("w")))
    report("nx" not in rec, "plat: a schedule of only where it is has no next stop", str(rec))
    # H7: waiting at its stop with another next, the panel shows where it goes (nx).
    mod_lua(f'local p = game.forces.player.platforms[{index}] '
            'p.schedule = {current = 1, records = {{station = "nauvis", wait_conditions = {{type = "time", compare_type = "or", '
            'ticks = 36000}}}, {station = "vulcanus"}}}')
    msgs = c.pump(2.5, every=hello)
    rec = next((p for m in of_type(msgs, "plat") for p in m["l"] if p["i"] == index), {})
    report(rec.get("loc") == "nauvis" and rec.get("nx") == "vulcanus", "plat waiting at a stop: the next stop (H7)", str(rec))
    mod_lua(f'local p = game.forces.player.platforms[{index}] p.schedule = {{current = 1, records = {{{{station = "nauvis"}}}}}}')
    unlocked = of_type(msgs, "plat")[-1].get("dest", []) if of_type(msgs, "plat") else []
    if "vulcanus" not in unlocked:
        c.send({"t": "plat_go", "i": index, "to": "vulcanus"})
        msgs = c.pump(1.0, every=hello)
        report(any(m["text"] == "Can't travel to vulcanus" for m in of_type(msgs, "msg")), "plat_go refuses a location not unlocked yet")
    # Travelling, set by script (the starter platform has no thrusters to get anywhere).
    mod_lua(f'local p = game.forces.player.platforms[{index}] '
            'p.space_connection = prototypes.space_connection["nauvis-vulcanus"] p.distance = 0.25 p.speed = 1')
    msgs = c.pump(2.5, every=hello)
    rec = next((p for m in of_type(msgs, "plat") for p in m["l"] if p["i"] == index), {})
    # Its schedule (plat_sched above) goes to nauvis, the connection's from end: it heads back (G9).
    report(rec.get("from") == "vulcanus" and rec.get("to") == "nauvis" and 700 < rec.get("d", 0) < 800 and rec.get("len") == 15000
           and "loc" not in rec, "plat while travelling: from, to, how far, the connection's length, speed", str(rec))
    # Owner's G9: sent to the connection's from end, 2.1.23 counts distance down; plat turns it round.
    mod_lua(f'local p = game.forces.player.platforms[{index}] p.distance = 0.4 p.speed = 1 p.paused = false '
            'p.schedule = {current = 1, records = {{station = "nauvis", wait_conditions = {}, temporary = true}}}')
    msgs = c.pump(2.5, every=hello)
    recs = [p for m in of_type(msgs, "plat") for p in m["l"] if p["i"] == index and "to" in p]
    report(len(recs) >= 2 and recs[-1].get("from") == "vulcanus" and recs[-1].get("to") == "nauvis" and recs[-1]["d"] > recs[0]["d"] >= 600,
           "plat heading back along its connection: from where it left, d counting up (G9)", str(recs[:1] + recs[-1:]))
    c.send({"t": "plat_board", "i": 0})
    msgs = c.pump(1.0, every=hello)
    report(any("stopped at a planet" in m["text"] for m in of_type(msgs, "msg")) and not of_type(msgs, "surface"),
           "plat_board 0 while travelling is refused")
    mod_lua(f'local p = game.forces.player.platforms[{index}] p.space_location = "nauvis" p.paused = true')
    c.send({"t": "plat_board", "i": 0})
    msgs = c.pump(SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "surface")
    surf = of_type(msgs, "surface")
    report(bool(surf) and surf[0].get("planet") == "nauvis" and "pf" not in surf[0],
           "plat_board 0: back down to the planet the platform is stopped at", str(surf[:1]))
    out = mod_lua(f"""local p = game.forces.player.platforms[{index}] p.destroy() rcon.print(p.scheduled_for_deletion)""")
    print("     platform scheduled for deletion in", out, "ticks")
    c.pump(1.0, every=hello)  # the checks after this one sleep; keep the session fresh


def check_ride(c, hello):
    """Riding to a platform as a player does (#10, #17): into a silo's rocket with `ride`
    (launch_rocket with the character), up to the platform's hub, life in the hub (no walking,
    ghosts, the hub's screen), and down again by cargo pod with `land`. Prints the pod's states
    and when each began."""
    if "space-platform-foundation" not in c.tiles:
        report(False, "ride: Space Age isn't enabled on this server")
        return
    # Earlier sections leave biters about (the shooting and enemies checks); one that keeps
    # biting the character kills it during the ride and every section after fails.
    clear_enemies()
    out = rcon.run("/f3d-platform new").strip()
    try:
        index = int(out.split("platform ")[1].split(" ")[0])
    except (IndexError, ValueError):
        report(False, "ride: /f3d-platform new", out)
        return
    hub_u = int(mod_lua(f"rcon.print(game.forces.player.platforms[{index}].hub.unit_number)") or 0)
    if not (clean_spot(c, hello, 16) or clean_spot(c, hello, 12)):
        report(False, "ride: no clean spot for a silo", SPOT_WHY)
        return
    px, py = c.me["x"] / 256, c.me["y"] / 256
    out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface
local silo = s.create_entity({{ name = "rocket-silo", position = {{ {px + 6.5}, {py + 0.5} }}, force = c.force, raise_built = true }})
local eei = s.create_entity({{ name = "electric-energy-interface", position = {{ {px - 4}, {py + 6} }}, force = c.force }})
eei.power_production = 1e9 eei.electric_buffer_size = 1e10
local sub = s.create_entity({{ name = "substation", position = {{ {px - 1}, {py + 6} }}, force = c.force }})
local sub2 = s.create_entity({{ name = "substation", position = {{ {px + 8}, {py + 6} }}, force = c.force }})
silo.rocket_parts = silo.prototype.rocket_parts_required
rcon.print(silo.unit_number .. " " .. silo.position.x .. " " .. silo.position.y .. " " .. eei.unit_number .. " " .. sub.unit_number .. " " .. sub2.unit_number)
""".replace("\n", " "))
    try:
        silo_u, sx, sy, *power = out.split()
        silo_u, sx, sy = int(silo_u), float(sx), float(sy)
    except ValueError:
        report(False, "ride: building a powered rocket silo", out)
        return
    made = [silo_u] + [int(u) for u in power]
    status = ("local n = {} for k, v in pairs(defines.rocket_silo_status) do n[v] = k end "
              f"for _, e in pairs(game.surfaces.nauvis.find_entities_filtered({{ name = 'rocket-silo', position = {{ {sx}, {sy} }} }})) do "
              "rcon.print(n[e.rocket_silo_status]) end")
    ready, end = "", time.time() + 60
    while time.time() < end and ready != "rocket_ready":
        c.pump(1.0, every=hello)
        ready = mod_lua(status)
    report(ready == "rocket_ready", "ride: a rocket stands ready in the silo", ready)
    c.send({"t": "open", "u": silo_u, "p": c.proto_id("rocket-silo"), "x": int(sx * 256), "y": int(sy * 256)})
    c.pump(1.0, every=hello)
    c.send({"t": "ride", "u": silo_u, "to": index})

    def ride(seconds, done):
        """Follows `me` until done(me); returns [(seconds, me), ...] and the messages."""
        t0, log = time.time(), []

        def watch(m):
            if m.get("t") == "me":
                log.append((time.time() - t0, m))
                return done(m)
            return False
        return log, c.pump(seconds, every=hello, until=watch)

    def phases(log):
        out, last = [], None
        for t, m in log:
            ps = m.get("ps", "hub" if "hub" in m else "-")
            if ps != last:
                out.append((round(t, 1), ps, m.get("up")))
                last = ps
        return out

    log, msgs = ride(75, lambda m: "hub" in m)
    up = [m for _, m in log if "pod" in m and m.get("up") == 1]
    surf = of_type(msgs, "surface")
    print("     ride up:", phases(log))
    report(up and (up[0]["gx"], up[0]["gy"]) == (int(sx * 256), int(sy * 256)) and up[0]["ps"] == "awaiting_launch",
           "ride: the character is in the rocket's cargo pod, seen from the silo (me.pod, up 1)", str(up[:1]))
    climb = [(m["gy"] - m["y"]) / 256 for m in up if m.get("ps") == "ascending"]
    report(len(climb) > 10 and climb[-1] > 100, "ride: the pod climbs (its y runs north of the silo)", f"{climb[:1]} .. {climb[-1:]} tiles")
    report(bool(surf) and surf[0].get("pf") == index, "ride: the pod changes surface to the platform (`surface`)", str(surf[:1]))
    report(log and log[-1][1].get("hub") == hub_u and "pod" not in log[-1][1],
           "ride: the pod docks and the character is inside the platform's hub (me.hub)", str(log[-1:])[:300])
    if not (log and "hub" in log[-1][1]):
        destroy_units(made)
        return
    hx, hy = log[-1][1]["x"], log[-1][1]["y"]
    c.send({"t": "sub", "c": [[-1, -1], [0, -1], [-1, 0], [0, 0]]})
    c.send({"t": "focus", "x": hx, "y": hy, "r": 48})
    c.pump(2.0, every=(0.15, {"t": "walk", "d": 4}))
    c.send({"t": "walk", "d": -1})
    c.send({"t": "mine", "u": 0, "p": 0, "x": hx + 3 * 256, "y": hy})
    mod_lua('storage.f3d.puppet.insert({ name = "pipe", count = 1 })')
    # The starter pack's foundation is all under the hub but a ring a tile wide: lay a little more.
    spot = mod_lua("local s = storage.f3d.puppet.surface local tiles = {} for x = 6, 8 do for y = -1, 1 do "
                   "tiles[#tiles + 1] = { name = 'space-platform-foundation', position = { x, y } } end end s.set_tiles(tiles) "
                   "for _, t in pairs(s.find_tiles_filtered{ name = 'space-platform-foundation' }) do "
                   "local x, y = t.position.x, t.position.y if s.can_place_entity{ name = 'pipe', position = { x + 0.5, y + 0.5 }, force = 'player' } then "
                   "rcon.print(x .. ',' .. y) return end end") or ""
    gx, gy = (int(v) for v in spot.split(",")) if "," in spot else (6, 0)
    c.send({"t": "build", "item": "pipe", "x": gx * 256 + 128, "y": gy * 256 + 128, "d": 0})
    msgs = c.pump(1.5, every=hello)
    ghost = mod_lua(f"local g = storage.f3d.puppet.surface.find_entities_filtered{{ ghost_name = 'pipe', position = {{ {gx} + 0.5, {gy} + 0.5 }} }}[1] "
                    "rcon.print(g and 'ghost' or 'none') if g then g.destroy() end")
    report(c.me and (c.me["x"], c.me["y"]) == (hx, hy) and "hub" in c.me and ghost == "ghost"
           and any(m.get("text") == "Not from inside the hub" for m in of_type(msgs, "msg")),
           "in the hub: no walking or mining, building places a ghost (#17)", f"{ghost} {[m.get('text') for m in of_type(msgs, 'msg')]}")
    c.send({"t": "open", "u": hub_u, "p": c.proto_id("space-platform-hub"), "x": hx, "y": hy})
    msgs = c.pump(2, every=hello, until=lambda m: m.get("t") == "gui" and m.get("u") == hub_u)
    g = [m for m in of_type(msgs, "gui") if m.get("u") == hub_u]
    report(g and g[-1].get("kind") == "hub", "in the hub: the hub's own screen opens", str([m.get("text") for m in of_type(msgs, "msg")]))
    c.send({"t": "close"})

    c.send({"t": "land"})
    log, msgs = ride(60, lambda m: "pod" not in m and "hub" not in m)
    print("     ride down:", phases(log))
    pods = [m for _, m in log if "pod" in m]
    surf = of_type(msgs, "surface")
    texts = [m.get("text") for m in of_type(msgs, "msg")]
    leave = [m for m in pods if m.get("up") == 1]
    down = [m for m in pods if m.get("up") == 0]
    report(any(t and "in a cargo pod" in t for t in texts) and leave and (leave[0]["gx"], leave[0]["gy"]) == (hx, hy),
           "land: out of the hub into a cargo pod, seen from the hub (up 1)", f"{texts} {leave[:1]}")
    report(bool(surf) and surf[0].get("planet") == "nauvis" and down and down[-1]["ps"] == "descending",
           "land: the pod changes surface to Nauvis and comes down (up 0)", f"{surf[:1]} {down[-1:]}")
    # Factorio gives it no height: it comes in from the north (and from the side: the client ignores
    # that, drawing it straight above the spot), and the client draws what is left of its way south as height.
    falling = [m for m in down if m.get("ps") == "descending"]
    spots = [r[4:6] for m in of_type(msgs, "cp") for r in m["l"] if r[1] == "descending" and len(r) == 6]
    print("     falling:", [(m["x"] / 256, m["y"] / 256) for m in falling[::max(1, len(falling) // 6)]], "spots:", spots[-1:])
    report(len(falling) > 5 and all(b["y"] >= a["y"] for a, b in zip(falling, falling[1:])),
           "land: a falling pod only ever travels south (the client's height)", str(falling[:1] + falling[-1:]))
    report(bool(spots) and abs(spots[-1][0] - falling[-1]["x"]) < 4 * 256 and abs(spots[-1][1] - falling[-1]["y"]) < 4 * 256,
           "land: `cp` says where it lands, where it comes down", f"{spots[-1:]} {falling[-1:]}")
    fin = log[-1][1] if log else {}
    report(down and fin and "pod" not in fin and abs(fin["x"] - down[-1]["gx"]) < 4 * 256 and abs(fin["y"] - down[-1]["gy"]) < 4 * 256,
           "land: the character stands on Nauvis where the pod came down", f"{fin} {down[-1:]}")
    destroy_units(made)
    mod_lua(f"game.forces.player.platforms[{index}].destroy(1)")


def check_space(c, hello):
    """Space Age's screens (space.lua) against the real game: the space map, a rocket silo built,
    powered and launched (a new platform's starter pack, then to its hub), the hub's schedule,
    interrupts and requests from planets, asteroid chunks, what can't be built on a platform, an
    asteroid collector's filters, a landing pad's circuit settings, module effects, recipe quality
    and the quality of belt items."""
    if "space-platform-foundation" not in c.tiles:
        report(False, "space: Space Age isn't enabled on this server")
        return
    made, built, extra_platform = [], "", 0

    def open_screen(unit, name, x, y, kind):
        c.send({"t": "open", "u": unit, "p": c.proto_id(name), "x": int(x * 256), "y": int(y * 256)})
        msgs = c.pump(3, every=hello, until=lambda m: m.get("t") == "gui" and m.get("u") == unit)
        g = [m for m in of_type(msgs, "gui") if m.get("u") == unit]
        report(bool(g) and g[-1].get("kind") == kind, f"open a {name}: gui kind {kind}", str(g[-1] if g else of_type(msgs, "msg")[-2:])[:300])
        return g[-1] if g else {}

    def screen_after(unit, seconds=1.2):
        msgs = c.pump(seconds, every=hello)
        g = [m for m in of_type(msgs, "gui") if m.get("u") == unit]
        return g[-1] if g else {}, msgs

    # --- the solar system ------------------------------------------------------------------------
    c.send({"t": "smap"})
    msgs = c.pump(2, every=hello, until=lambda m: m.get("t") == "smap")
    sm = of_type(msgs, "smap")
    locs = {r[0]: r for r in sm[0]["loc"]} if sm else {}
    report(bool(sm) and "nauvis" in locs and locs["nauvis"][4] == 1 and any(0 < r[3] <= 1000 for r in sm[0]["con"]),
           "smap: space locations (prototype positions) and connections with asteroid danger",
           f"{len(locs)} locations, {len(sm[0]['con']) if sm else 0} connections, nauvis {locs.get('nauvis')}")
    report(len(locs.get("vulcanus", [])) == 9 and locs["vulcanus"][6] == 1500 and locs.get("shattered-planet", [0] * 9)[7] == 0,
           "smap: how the star map draws each place (magnitude, draw_orbit, label_orientation)",
           f"vulcanus {locs.get('vulcanus')}, shattered planet {locs.get('shattered-planet')}")

    # --- a rocket silo, powered, and its launches ----------------------------------------------
    if not (clean_spot(c, hello, 16) or clean_spot(c, hello, 12)):
        report(False, "space: no clean spot for a silo", SPOT_WHY + " on " + mod_lua("rcon.print(storage.f3d.puppet.surface.name)"))
        return
    px, py = c.me["x"] / 256, c.me["y"] / 256
    out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface
local silo = s.create_entity({{ name = "rocket-silo", position = {{ {px + 6.5}, {py + 0.5} }}, force = c.force, raise_built = true }})
local eei = s.create_entity({{ name = "electric-energy-interface", position = {{ {px - 4}, {py + 6} }}, force = c.force }})
eei.power_production = 1e9 eei.electric_buffer_size = 1e10
local sub = s.create_entity({{ name = "substation", position = {{ {px - 1}, {py + 6} }}, force = c.force }})
local sub2 = s.create_entity({{ name = "substation", position = {{ {px + 8}, {py + 6} }}, force = c.force }})
silo.rocket_parts = silo.prototype.rocket_parts_required
rcon.print(silo.unit_number .. " " .. silo.position.x .. " " .. silo.position.y .. " " .. eei.unit_number .. " " .. sub.unit_number .. " " .. sub2.unit_number)
""".replace("\n", " "))
    try:
        silo_u, sx, sy, *power = out.split()
        silo_u, sx, sy = int(silo_u), float(sx), float(sy)
        made += [silo_u] + [int(u) for u in power]
    except ValueError:
        report(False, "space: building a powered rocket silo", out)
        return
    g = open_screen(silo_u, "rocket-silo", sx, sy, "silo")
    rk = g.get("rk", {})
    # No platform in orbit: Factorio's table_to_json writes the empty list as {}.
    report(isinstance(rk.get("st"), str) and rk.get("auto") in (0, 1) and (isinstance(rk.get("to"), list) or rk.get("to") == {}),
           "the silo's screen: rocket_silo_status, send_to_orbit_automatically, platforms to launch to", str(rk))
    c.send({"t": "set_silo", "u": silo_u, "auto": 1})
    c.pump(0.5, every=hello)
    report(mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'rocket-silo', position = {{ {sx}, {sy} }} }})) do "
                   "rcon.print(tostring(e.send_to_orbit_automatically)) e.send_to_orbit_automatically = false end") == "true",
           "set_silo: send to orbit automatically")

    # A new platform waits for its starter pack; the silo launches it up.
    mod_lua('storage.f3d.puppet.insert({ name = "space-platform-starter-pack", count = 1 })')
    c.send({"t": "plat_new"})
    msgs = c.pump(2, every=hello)
    texts = [m["text"] for m in of_type(msgs, "msg")]
    out = mod_lua("local best for _, p in pairs(game.forces.player.platforms) do if p.valid and not p.hub then best = p end end "
                  "rcon.print(best and (best.index .. ' ' .. best.state .. ' ' .. (best.space_location and best.space_location.name or '?')) or 'none')")
    report(out != "none" and any(t.startswith("New platform") for t in texts), "plat_new: a platform over the planet waiting for its starter pack",
           f"{out} | {texts[-1:]}")
    new_index = int(out.split()[0]) if out != "none" else 0
    if new_index:
        made_platform = new_index
        ready = ""
        end = time.time() + 40
        while time.time() < end:
            ready = mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'rocket-silo', position = {{ {sx}, {sy} }} }})) do "
                            "local names = {} for k, v in pairs(defines.rocket_silo_status) do names[v] = k end rcon.print(names[e.rocket_silo_status]) end")
            if ready == "rocket_ready":
                break
            c.pump(1.0, every=hello)
        report(ready == "rocket_ready", "a powered silo with its parts builds a rocket (rocket_silo_status)", ready)
        if ready == "rocket_ready":
            out = mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'rocket-silo', position = {{ {sx}, {sy} }} }})) do "
                          "local inv = e.get_inventory(defines.inventory.rocket_silo_rocket) "
                          "rcon.print(inv and inv.insert({ name = 'space-platform-starter-pack', count = 1 }) or 'no rocket inventory') end")
            report(out == "1", "the starter pack goes into the rocket (rocket_silo_rocket)", out)
            early = c.pump(0.2, every=hello)
            # The game launches a rocket carrying a waiting platform's starter pack by itself.
            msgs = early + c.pump(4, every=hello, until=lambda m: m.get("t") == "rk")
            rk_msgs = of_type(msgs, "rk")
            state = mod_lua(f"local n = {{}} for k, v in pairs(defines.space_platform_state) do n[v] = k end "
                            f"rcon.print(n[game.forces.player.platforms[{new_index}].state])")
            report(bool(rk_msgs) and rk_msgs[0]["u"] == silo_u and state != "waiting_for_starter_pack",
                   "the rocket carrying the starter pack goes up by itself (rk), and the pack is on its way", f"rk {rk_msgs[:1]}, {state}")
            built = ""
            end = time.time() + 60
            while time.time() < end:
                built = mod_lua(f"local p = game.forces.player.platforms[{new_index}] rcon.print(tostring(p.hub ~= nil and p.hub.valid))")
                if built == "true":
                    break
                c.pump(1.0, every=hello)
            report(built == "true", "the starter pack arrives: the platform has its hub", built)
            if built == "true":
                mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'rocket-silo', position = {{ {sx}, {sy} }} }})) do "
                        "e.rocket_parts = e.prototype.rocket_parts_required end")
                ready = ""
                end = time.time() + 60
                while time.time() < end:
                    ready = mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'rocket-silo', position = {{ {sx}, {sy} }} }})) do "
                                    "local names = {} for k, v in pairs(defines.rocket_silo_status) do names[v] = k end rcon.print(names[e.rocket_silo_status]) end")
                    if ready == "rocket_ready":
                        break
                    c.pump(1.0, every=hello)
                mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'rocket-silo', position = {{ {sx}, {sy} }} }})) do "
                        "e.get_inventory(defines.inventory.rocket_silo_rocket).insert({ name = 'iron-plate', count = 50 }) end")
                g, _ = screen_after(silo_u)
                rocket_slots = g.get("slots", {}).get("rocket") if isinstance(g.get("slots"), dict) else None
                report(ready == "rocket_ready" and isinstance(rocket_slots, list) and ["iron-plate", 50] in rocket_slots
                       and any(t[0] == new_index for t in g.get("rk", {}).get("to", [])),
                       "a second rocket: the silo shows its cargo and the platform to launch to", f"{ready} {str(rocket_slots)[:60]} {g.get('rk')}")
                c.send({"t": "silo_launch", "u": silo_u, "to": new_index})
                msgs = c.pump(4, every=hello, until=lambda m: m.get("t") == "rk")
                rk_msgs = of_type(msgs, "rk")
                report(bool(rk_msgs) and rk_msgs[0]["u"] == silo_u, "silo_launch: launch_rocket to the platform's hub (rk)",
                       f"{rk_msgs[:1]} {[m['text'] for m in of_type(msgs, 'msg')][-2:]}")
                msgs = c.pump(6, every=hello)
                pods = [r for m in of_type(msgs, "cp") for r in m["l"]]
                report(bool(pods), "cp: the rocket's cargo pod near the silo", str(pods[:2]))
    else:
        made_platform = 0

    # --- the hub's screen ------------------------------------------------------------------------
    index = made_platform if made_platform and built == "true" else 0
    if not index:
        out = rcon.run("/f3d-platform new").strip()
        try:
            index = extra_platform = int(out.split("platform ")[1].split(" ")[0])
        except (IndexError, ValueError):
            report(False, "space: no platform for the hub checks", out)
            destroy_units(made)
            return
    c.send({"t": "close"})
    c.send({"t": "plat_board", "i": index})
    msgs = c.pump(SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "surface")
    surf = of_type(msgs, "surface")
    if not surf:
        report(False, "space: boarding the platform", str(of_type(msgs, "msg")[-2:]))
        destroy_units(made)
        return
    planet = [m for m in c.pump(1.5, every=hello) if m.get("t") == "planet"]
    x, y = surf[0]["x"] / 256, surf[0]["y"] / 256
    cx, cy = int(x // 32), int(y // 32)
    c.send({"t": "sub", "c": [[cx + dx, cy + dy] for dy in range(-1, 2) for dx in range(-1, 2)]})
    c.send({"t": "focus", "x": int(x * 256), "y": int(y * 256), "r": 48})
    c.pump(2, every=hello)
    hub = mod_lua(f"local h = game.forces.player.platforms[{index}].hub rcon.print(h.unit_number .. ' ' .. h.position.x .. ' ' .. h.position.y)").split()
    hub_u, hx, hy = int(hub[0]), float(hub[1]), float(hub[2])
    g = open_screen(hub_u, "space-platform-hub", hx, hy, "hub")
    h = g.get("hub", {})
    report(h.get("i") == index and isinstance(h.get("w"), int) and h.get("w", 0) > 0 and isinstance(h.get("th"), list)
           and isinstance(h.get("sec"), list) and "chest" in g.get("slots", {}),
           "the hub's screen: the platform, weight, thrusters, requests, inventory (hub_main)",
           f"{ {k: h.get(k) for k in ('i', 'st', 'w', 'th', 'fuel', 'prov', 'loc')} } trash={'trash' in g.get('slots', {})}")
    c.send({"t": "set_section", "u": hub_u, "i": 0, "f": [["iron-plate", "normal", 100, 400, "nauvis", 50]]})
    c.send({"t": "set_hub", "u": hub_u, "prov": 1})
    waits = [{"type": "all_requests_satisfied", "compare_type": "and"}, {"type": "time", "compare_type": "or", "ticks": 1800}]
    c.send({"t": "set_schedule", "u": hub_u, "records": [{"station": "nauvis", "wait_conditions": waits}, {"station": "nowhere"}]})
    c.send({"t": "set_interrupts", "u": hub_u, "interrupts": [
        {"name": "f3d live", "conditions": [{"type": "any_request_zero", "compare_type": "and"}], "targets": [{"station": "nauvis"}]}]})
    g, msgs = screen_after(hub_u, 1.5)
    h = g.get("hub", {})
    out = mod_lua(f"local p = game.forces.player.platforms[{index}] for _, sec in pairs(p.hub.get_logistic_sections().sections) do "
                  "for _, f in pairs(sec.filters) do if f.value and f.value.name == 'iron-plate' then "
                  "rcon.print(f.value.name .. ' ' .. f.min .. ' ' .. tostring(f.max) .. ' ' .. tostring(f.import_from and f.import_from.name) "
                  ".. ' ' .. tostring(f.minimum_delivery_count)) end end end")
    report(out == "iron-plate 100 400 nauvis 50", "set_section: a request from a planet (import_from, minimum_delivery_count) on the hub", out)
    report(any(s.get("f") == [["iron-plate", "normal", 100, 400, "nauvis", 50]] for s in h.get("sec", [])),
           "and gui.hub.sec shows it", str(h.get("sec")))
    report(h.get("prov") == 1, "set_hub: providing_to_other_platforms", str(h.get("prov")))
    sched = h.get("sched", {})
    out = mod_lua(f"local s = game.forces.player.platforms[{index}].get_schedule() local r = s.get_records() "
                  "rcon.print(#r .. ' ' .. r[1].station .. ' ' .. #r[1].wait_conditions .. ' ' .. #s.get_interrupts())")
    report(out == "1 nauvis 2 1" and [r["station"] for r in sched.get("records", [])] == ["nauvis"]
           and sched.get("interrupts", [{}])[0].get("name") == "f3d live",
           "the platform's schedule and interrupts from the hub (LuaSchedule records, wait conditions)", f"{out} | {sched}")
    errors = [m["text"] for m in of_type(msgs, "msg") if "Can't" in m["text"]]
    report(not errors, "no command was refused", str(errors))

    # Asteroid chunks near the focus, and an asteroid collector's filters.
    mod_lua(f"game.forces.player.platforms[{index}].create_asteroid_chunks({{ {{ name = 'metallic-asteroid-chunk', "
            f"position = {{ {x + 6}, {y - 3} }}, movement = {{ 0, 0.02 }} }} }})")
    msgs = c.pump(1.0, every=hello)
    ach = [r for m in of_type(msgs, "ach") for r in m["l"] if r[0] == "metallic-asteroid-chunk"]
    report(bool(ach), "ach: asteroid chunks drifting over the platform (find_asteroid_chunks_filtered)", str(ach[:3]))
    out = mod_lua(f"local c = storage.f3d.puppet local e = c.surface.create_entity({{ name = 'asteroid-collector', position = {{ {x + 5}, {y + 4} }}, "
                  "force = c.force, raise_built = true }) rcon.print(e and (e.unit_number .. ' ' .. e.position.x .. ' ' .. e.position.y) or 'none')")
    if out != "none":
        col_u, colx, coly = int(out.split()[0]), float(out.split()[1]), float(out.split()[2])
        made.append(col_u)
        g = open_screen(col_u, "asteroid-collector", colx, coly, "collector")
        c.send({"t": "set_collector", "u": col_u, "f": ["carbonic-asteroid-chunk"]})
        g, _ = screen_after(col_u)
        got = mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'asteroid-collector', position = {{ {colx}, {coly} }} }})) do "
                      "local f = e.get_filter(1) rcon.print(f and (f.name or f) or 'nil') end")
        report(got == "carbonic-asteroid-chunk" and (g.get("col", {}).get("f") or [""])[0] == "carbonic-asteroid-chunk",
               "set_collector: the chunk filter (set_filter with an asteroid chunk)", f"{got} {g.get('col')}")
    else:
        report(False, "an asteroid collector on the platform", out)

    # What can't be built here (planet.nb) and the refusal.
    nb = planet[-1].get("nb", []) if planet else []
    report(bool(nb), "planet.nb on a platform: entities its surface conditions forbid", f"{len(nb)} entities, e.g. {nb[:3]}")
    if nb:
        name = next((n for i, (n, _) in c.protos.items() if i == nb[0][0]), "")
        item = mod_lua(f"local p = prototypes.entity['{name}'] local it = p.items_to_place_this and p.items_to_place_this[1] "
                       "if it then storage.f3d.puppet.insert({ name = it.name, count = 1 }) rcon.print(it.name) else rcon.print('') end")
        if item:
            c.send({"t": "build", "item": item, "x": int((x + 2.5) * 256), "y": int((y + 3.5) * 256), "d": 0})
            msgs = c.pump(1.0, every=hello)
            texts = [m["text"] for m in of_type(msgs, "msg")]
            report(any(t.startswith("Can't build here:") for t in texts), f"building {name} on a platform says why it can't", str(texts[-2:]))
    c.send({"t": "close"})
    c.send({"t": "plat_board", "i": 0})
    c.pump(SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "surface")
    c.pump(1.0, every=hello)

    # --- a landing pad, module effects, recipe quality, belt item quality (back on the planet) ----
    if clean_spot(c, hello, 14):
        px, py = c.me["x"] / 256, c.me["y"] / 256
        out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface
local pad = s.create_entity({{ name = "cargo-landing-pad", position = {{ {px + 6}, {py} }}, force = c.force, raise_built = true }})
local asm = s.create_entity({{ name = "assembling-machine-2", position = {{ {px - 5.5}, {py + 0.5} }}, force = c.force, raise_built = true }})
asm.get_module_inventory().insert({{ name = "speed-module", count = 1 }})
local belt = s.create_entity({{ name = "transport-belt", position = {{ {px + 0.5}, {py + 4.5} }}, force = c.force, direction = defines.direction.east }})
belt.get_transport_line(1).insert_at(0.5, {{ name = "iron-plate", count = 1, quality = "rare" }})
rcon.print((pad and (pad.unit_number .. " " .. pad.position.x .. " " .. pad.position.y) or "none none none") .. " " .. asm.unit_number .. " " .. asm.position.x .. " " .. asm.position.y .. " " .. belt.unit_number)
""".replace("\n", " "))
        parts = out.split()
        if len(parts) == 7:
            if parts[0] != "none":
                pad_u, padx, pady = int(parts[0]), float(parts[1]), float(parts[2])
                made.append(pad_u)
                g = open_screen(pad_u, "cargo-landing-pad", padx, pady, "pad")
                report(isinstance(g.get("pad", {}).get("sec"), list) and "chest" in g.get("slots", {}),
                       "the landing pad's screen: requests and inventory (cargo_landing_pad_main)", str(g.get("pad")))
                c.send({"t": "set_pad", "u": pad_u, "req": 1, "read": 0})
                g, _ = screen_after(pad_u)
                got = mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'cargo-landing-pad', position = {{ {padx}, {pady} }} }})) do "
                              "local cb = e.get_control_behavior() rcon.print(tostring(cb.set_requests) .. ' ' .. tostring(cb.read_contents)) end")
                report(got == "true false" and g.get("pad", {}).get("cb", {}).get("req") == 1,
                       "set_pad: the landing pad's circuit settings (LuaCargoLandingPadControlBehavior)", f"{got} {g.get('pad', {}).get('cb')}")
            else:
                print("     (no landing pad: this surface already has its one)")
            asm_u, ax, ay = int(parts[3]), float(parts[4]), float(parts[5])
            made += [asm_u, int(parts[6])]
            g = open_screen(asm_u, "assembling-machine-2", ax, ay, "crafter")
            report(g.get("eff", {}).get("sp", 0) > 0, "a machine's module effects (LuaEntity.effects)", str(g.get("eff")))
            unlocked = mod_lua("rcon.print(tostring(game.forces.player.is_quality_unlocked('uncommon')))")
            c.send({"t": "set_recipe", "u": asm_u, "recipe": "iron-gear-wheel", "q": "uncommon"})
            g, msgs = screen_after(asm_u)
            if unlocked == "true":
                report(g.get("rq") == "uncommon" and "uncommon" in g.get("ql", []), "set_recipe with a quality (set_recipe(name, quality))", str(g.get("rq")))
            else:
                report(any(m["text"] == "That quality isn't researched" for m in of_type(msgs, "msg")),
                       "set_recipe refuses a quality not researched (is_quality_unlocked)", str([m["text"] for m in of_type(msgs, "msg")][-2:]))
            c.send({"t": "close"})
            msgs = c.pump(1.0, every=hello)
            bq = [r for m in of_type(msgs, "bq") for r in m["l"]]
            report(any(r[1] == "rare" for r in bq), "bq: a rare plate riding a belt", str(bq[:3]))
        else:
            report(False, "space: building the pad, machine and belt", out)
    destroy_units(made)
    for p in (made_platform, extra_platform):
        if p:
            mod_lua(f"game.forces.player.platforms[{p}].destroy()")
    c.pump(1.0, every=hello)


def check_collectors(c, hello):
    """Asteroid collectors' arms (`acol`, F3): a collector on a new platform's edge, powered, its
    filter set to promethium so the orbit's own chunks don't count; a still promethium chunk 6
    tiles in front is caught (`g`) where it was and lands in the output; without power the arms fold home (G10)."""
    out = rcon.run("/f3d-platform new").strip()
    try:
        index = int(out.split("platform ")[1].split(" ")[0])
    except (IndexError, ValueError):
        report(False, "collectors: /f3d-platform new", out)
        return
    c.send({"t": "plat_board", "i": index})
    msgs = c.pump(SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "surface")
    if not of_type(msgs, "surface"):
        report(False, "collectors: boarding the platform", str(of_type(msgs, "msg")[-2:]))
        return
    # A strip of foundation north of the hub, the collector on its edge facing out, a pole and an
    # electric energy interface to power it.
    out = mod_lua(f"local s = game.forces.player.platforms[{index}].surface local f = game.forces.player local t = {{}} "
                  "for x = -12, 11 do for y = -16, -6 do t[#t + 1] = { name = 'space-platform-foundation', position = { x, y } } end end "
                  "s.set_tiles(t) local col = s.create_entity({ name = 'asteroid-collector', position = { -10.5, -15.5 }, direction = defines.direction.north, force = f }) "
                  "s.create_entity({ name = 'medium-electric-pole', position = { -8.5, -14.5 }, force = f }) "
                  "s.create_entity({ name = 'electric-energy-interface', position = { -6, -13 }, force = f }) "
                  "col.set_filter(1, 'promethium-asteroid-chunk') rcon.print(col.unit_number)")
    if not out.isdigit():
        report(False, "collectors: a collector on the platform's edge", out)
        return
    col_u = int(out)
    c.send({"t": "focus", "x": int(-10.5 * 256), "y": int(-15.5 * 256), "r": 48})
    msgs = c.pump(1.5, every=hello)
    rows = [r for m in of_type(msgs, "acol") for r in m.get("l", []) if r[0] == col_u]
    report(bool(rows) and rows[-1][1] == 1 and rows[-1][2] == 200 and rows[-1][3] == 1 and rows[-1][4] == ["promethium-asteroid-chunk"],
           "acol: a collector's arms (1), arm speed (0.2 tiles a tick), moving while powered, its filter", str(rows[-1:]))
    mod_lua(f"game.forces.player.platforms[{index}].create_asteroid_chunks({{ {{ name = 'promethium-asteroid-chunk', "
            "position = { -10.5, -21.5 }, movement = { 0, 0 } } })")
    msgs = c.pump(2.0, every=hello)
    grabs = [g for m in of_type(msgs, "acol") for g in m.get("g", []) if g[0] == col_u]
    near = [g for g in grabs if g[1] == "promethium-asteroid-chunk" and abs(g[2] / 256 + 10.5) < 0.3 and abs(g[3] / 256 + 21.5) < 0.3]
    got = mod_lua(f"rcon.print(game.forces.player.platforms[{index}].surface.find_entities_filtered({{ name = 'asteroid-collector' }})[1]"
                  ".get_inventory(defines.inventory.chest).get_item_count('promethium-asteroid-chunk'))")
    report(len(near) == 1 and got == "1", "acol g: the chunk the collector caught, once, where it was, and it reached the output",
           f"{grabs} output {got}")
    # The orbit's own chunks (carbonic, metallic...) the filter leaves alone are never counted as caught.
    report(all(g[1] == "promethium-asteroid-chunk" for g in grabs), "acol g: no chunk counted that the filter leaves alone", str(grabs))
    mod_lua(f"for _, e in pairs(game.forces.player.platforms[{index}].surface.find_entities_filtered({{ name = 'electric-energy-interface' }})) do e.destroy() end")
    msgs = c.pump(2.5, every=hello)
    rows = [r for m in of_type(msgs, "acol") for r in m.get("l", []) if r[0] == col_u]
    report(bool(rows) and rows[-1][3] == 2, "acol: without power the arms fold home (2, G10)", str(rows[-1:]))
    c.send({"t": "plat_board", "i": 0})
    msgs = c.pump(SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "surface")
    msgs += c.pump(1.0, every=hello)  # the clear comes on the next 10-tick look, after `surface`
    cleared = [m for m in msgs if m.get("t") == "acol" and m.get("l") in ([], {})]
    report(bool(cleared), "acol: an empty list once the client's world leaves the platform", str(of_type(msgs, "acol")[-1:]))
    mod_lua(f"game.forces.player.platforms[{index}].destroy()")
    c.pump(1.0, every=hello)


def check_planets(c, hello):
    """The other planets (Space Age): on each, the planet data and its own streams; then landing
    from a platform in a cargo pod. Everything made is destroyed and the character goes home."""
    if "lava" not in c.tiles:
        report(False, "planets: Space Age isn't enabled on this server")
        return
    home = mod_lua("local p = storage.f3d.puppet.position rcon.print(p.x .. ' ' .. p.y)").split()
    mod_lua("storage.f3d_live_planets = {}")

    def lua(code):
        return mod_lua(code.replace("\n", " "))

    def visit(planet):
        """Teleports the character to the planet's surface; returns its position, or None."""
        lua(f"""local c = storage.f3d.puppet local pl = game.planets["{planet}"] local s = pl.surface or pl.create_surface()
s.request_to_generate_chunks({{0, 0}}, 2) s.force_generate_chunk_requests()
local p = s.find_non_colliding_position("character", {{0, 0}}, 64, 0.5) or {{x = 0, y = 0}}
c.teleport(p, s)""")
        msgs = c.pump(SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "planet" and m.get("name") == planet)
        planet_msg = of_type(msgs, "planet")
        surf = of_type(msgs, "surface")
        report(bool(planet_msg) and planet_msg[-1]["name"] == planet and "gravity" in planet_msg[-1].get("props", {})
               and planet_msg[-1].get("day", 0) > 0,
               f"{planet}: `planet` on arriving (surface.planet, get_property, ticks_per_day)", str(planet_msg[-1:])[:300])
        if not surf:
            return None
        x, y = surf[-1]["x"] / 256, surf[-1]["y"] / 256
        c.send({"t": "focus", "x": int(x * 256), "y": int(y * 256), "r": 48})
        return x, y

    def make(spec, keep=True):
        """Lua that creates an entity on the character's surface as `e` (kept for cleanup)."""
        return (f"local c = storage.f3d.puppet local s = c.surface local e = s.create_entity({spec}) "
                + ("if e then table.insert(storage.f3d_live_planets, e) end " if keep else ""))

    # Vulcanus: a demolisher, created stretched out (create_segmented_unit), seen as `seg`.
    at = visit("vulcanus")
    if at:
        x, y = at
        out = lua(f"""local s = storage.f3d.puppet.surface
local u = s.create_segmented_unit({{ name = "small-demolisher", position = {{ {x + 36}, {y} }}, extended = true }})
rcon.print(u and u.unit_number or 0)""")
        unit = int(out) if out.isdigit() else 0
        seg = [r for m in of_type(c.pump(1.0, every=hello), "seg") for r in m["l"] if r[0] == unit]
        report(unit > 0 and bool(seg) and len(seg[-1][2]) >= 8, "vulcanus: a demolisher's segments in `seg` (get_segmented_units, segments)",
               f"unit {out}, {str(seg[-1:])[:300]}")
        lua(f"for _, u in pairs(storage.f3d.puppet.surface.get_segmented_units()) do if u.unit_number == {unit} then u.destroy() end end")

    # Fulgora: a lightning rod and two strikes (execute_lightning), one on the rod, one away from it.
    # Fulgora's ruins are lightning attractors too (one stands by the spawn) and pull in strikes
    # 20 tiles off, so this happens on land where none is within 40 tiles of either strike. The
    # bolt's entity stands in the sky, so a strike on the ground is placed only within 15 tiles
    # in x and 3 in y.
    at = visit("fulgora")
    if at:
        out = lua("""local c = storage.f3d.puppet local s = c.surface
s.request_to_generate_chunks({0, 0}, 5) s.force_generate_chunk_requests()
local function clear(x, y) return s.count_entities_filtered({ position = { x, y }, radius = 40, type = "lightning-attractor" }) == 0 end
local best
for gx = -144, 144, 8 do for gy = -144, 144, 8 do
  local d = gx * gx + gy * gy
  if (not best or d < best.d) and clear(gx, gy) and clear(gx - 30, gy - 26)
      and s.can_place_entity({ name = "lightning-rod", position = { gx + 0.5, gy + 0.5 }, force = c.force }) then
    best = { d = d, x = gx + 0.5, y = gy + 0.5 }
  end
end end
if best then
  c.teleport({ best.x - 2, best.y })
  local e = s.create_entity({ name = "lightning-rod", position = { best.x, best.y }, force = c.force })
  if e then table.insert(storage.f3d_live_planets, e) end
  rcon.print(c.position.x .. " " .. c.position.y .. " " .. (e and (e.position.x .. " " .. e.position.y) or ""))
end""")
        parts = [float(v) for v in out.split()]
        if len(parts) == 4:
            x, y, rx, ry = parts
            c.send({"t": "focus", "x": int(x * 256), "y": int(y * 256), "r": 48})
            c.pump(0.5, every=hello)
            sx, sy = rx - 30, ry - 26
            lua(f'local s = storage.f3d.puppet.surface s.execute_lightning({{ name = "lightning", position = {{ {rx}, {ry} }} }}) '
                f's.execute_lightning({{ name = "lightning", position = {{ {sx}, {sy} }} }})')
            lt = [r for m in of_type(c.pump(1.5, every=hello), "lt") for r in m["l"]]
            caught = [r for r in lt if r[2] == 1 and r[:2] == [round(rx * 256), round(ry * 256)]]
            ground = [r for r in lt if r[2] == 0 and abs(r[0] / 256 - sx) <= 15.5 and abs(r[1] / 256 - sy) <= 3.5]
            report(caught and ground, "fulgora: lightning strikes in `lt`, one caught by the rod (on it), one on the ground below its bolt",
                   f"rod at {rx}, {ry}, stray at {sx}, {sy}: {lt}")
        else:
            report(False, "fulgora: lightning strikes in `lt`, one caught by the rod", f"no spot without lightning attractors near: {out}")

    # Gleba: a half-grown yumako tree, a spawner, a pentapod (kept still), spoiling fruit in the
    # inventory and an agricultural tower's screen.
    at = visit("gleba")
    if at:
        x, y = at
        out = lua(make(f'{{ name = "yumako-tree", position = {{ {x + 4}, {y + 4} }} }}')
                  + "if e then e.tick_grown = game.tick + math.floor(e.prototype.growth_ticks / 2) end "
                  + make(f'{{ name = "gleba-spawner", position = {{ {x + 28}, {y} }}, force = "enemy" }}')
                  + make(f'{{ name = "small-stomper-pentapod", position = {{ {x + 18}, {y + 18} }}, force = "enemy" }}')
                  + "if e then e.disabled_by_script = true end "
                  + make(f'{{ name = "agricultural-tower", position = {{ {x - 6}, {y + 6} }}, force = c.force }}')
                  + 'c.insert({ name = "yumako", count = 10 }) rcon.print(e and (e.unit_number .. " " .. e.position.x .. " " .. e.position.y) or "none")')
        msgs = c.pump(2.5, every=hello)
        pg = [v for m in of_type(msgs, "pg") for v in m["l"]]
        report(any(300 <= pg[i + 3] <= 700 for i in range(0, len(pg), 4)), "gleba: a half-grown plant in `pg` (tick_grown, growth_ticks)", str(pg[:12]))
        report(any(m["l"] for m in of_type(msgs, "sp")), "gleba: the spawner in `sp` (units)", str(of_type(msgs, "sp")[-1:])[:200])
        report(any(len(r[1]) == 10 for m in of_type(msgs, "legs") for r in m["l"]),
               "gleba: the pentapod's five feet in `legs` (its spider-leg entities)", str(of_type(msgs, "legs")[-1:])[:200])
        slots = of_type(msgs, "slots")
        fruit = [s for m in slots for s in m["l"].get("main", []) if isinstance(s, list) and s[0] == "yumako"]
        report(bool(fruit) and len(fruit[-1]) == 4, "gleba: spoiling fruit carries its freshness in `slots` (spoil_percent)", str(fruit[-1:]))
        parts = out.split()
        if len(parts) == 3:
            c.send({"t": "open", "u": int(parts[0]), "p": c.proto_id("agricultural-tower"),
                    "x": round(float(parts[1]) * 256), "y": round(float(parts[2]) * 256)})
            g = [m for m in c.pump(0.6, every=hello) if m.get("t") == "gui" and m.get("u") == int(parts[0])]
            report(bool(g) and isinstance(g[-1].get("ag"), dict), "gleba: an agricultural tower's screen counts its plants (owned_plants)", str(g[-1:])[:300])
            c.send({"t": "close"})
        else:
            report(False, "gleba: making the plant, spawner, pentapod and tower", out)
        lua('storage.f3d.puppet.remove_item({ name = "yumako", count = 10 })')

    # Aquilo: an inserter out of any heat (frozen, as entity.frozen says) and a heat pipe's temperature.
    at = visit("aquilo")
    if at:
        x, y = at
        out = lua(make(f'{{ name = "inserter", position = {{ {x + 3}, {y + 3} }}, force = c.force }}')
                  + "local ins = e "
                  + make(f'{{ name = "heat-pipe", position = {{ {x + 5}, {y + 3} }}, force = c.force }}')
                  + "if e then e.temperature = 300 end rcon.print(ins and (ins.unit_number .. ' ' .. tostring(ins.frozen)) or 'none')")
        msgs = c.pump(2.5, every=hello)
        fz = [v for m in of_type(msgs, "fz") for v in m["l"]]
        parts = out.split()
        if len(parts) == 2:
            frozen_now = mod_lua(f"for _, e in pairs(storage.f3d_live_planets) do if e.valid and e.unit_number == {parts[0]} then rcon.print(tostring(e.frozen)) end end")
            report((int(parts[0]) in fz) == (frozen_now == "true"), "aquilo: `fz` agrees with entity.frozen", f"frozen {frozen_now}, fz {fz}")
        heat = [v for m in of_type(msgs, "ht") for v in m["l"]]
        report(300 in heat[1::2] or any(abs(v - 300) < 30 for v in heat[1::2]), "aquilo: a heat pipe's temperature in `ht`", str(heat[:10]))

    # Home, then down from a platform the way a player goes (`land`, a cargo pod).
    lua("for _, e in pairs(storage.f3d_live_planets or {}) do if e.valid then e.destroy() end end storage.f3d_live_planets = nil")
    if len(home) == 2:
        lua(f'storage.f3d.puppet.teleport({{ {home[0]}, {home[1]} }}, game.surfaces.nauvis)')
        c.pump(SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "surface")
    out = rcon.run("/f3d-platform new").strip()
    try:
        index = int(out.split("platform ")[1].split(" ")[0])
    except (IndexError, ValueError):
        report(False, "land: build a platform to land from", out)
        return
    c.send({"t": "plat_board", "i": index})
    c.pump(SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "surface")
    c.send({"t": "land"})
    msgs = c.pump(15, every=hello, until=lambda m: m.get("t") == "surface" and m.get("planet") == "nauvis")
    texts = [m["text"] for m in of_type(msgs, "msg")]
    surf = [m for m in of_type(msgs, "surface") if m.get("planet") == "nauvis"]
    by_pod = any("in a cargo pod" in t for t in texts)
    report(bool(surf), "land: the character gets down to the planet", f"{texts}; surface {surf[:1]}")
    print(f"     land went {'by cargo pod' if by_pod else 'by the direct move'}: {texts}; cargo pods seen: {[r for m in of_type(msgs, 'cp') for r in m['l']][:3]}")
    mod_lua(f"game.forces.player.platforms[{index}].destroy()")
    c.pump(1.0, every=hello)


def check_ui_parity(c, hello):
    """Factorio's world controls and entity windows (ui_actions.lua, entity_ui.lua)."""
    ug = c.proto_id("underground-belt")
    pole = c.proto_id("small-electric-pole")
    ep = c.eprops or {}
    report(ep.get(ug, [0])[0] == 5 and ep.get(pole, [0, 0, 0])[1] == 7.5 and ep.get(pole, [0, 0, 0])[2] == 2.5,
           "eprops: underground reach (max_underground_distance), pole wire reach and supply area", f"{ep.get(ug)} {ep.get(pole)}")
    if not clean_spot(c, hello):
        report(False, "ui parity: no clean spot found")
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    fx = lambda v: int(round(v * 256))
    out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local x, y = {x}, {y}
local function put(name, dx, dy, d)
  local e = s.create_entity({{ name = name, position = {{ x + dx, y + dy }}, force = c.force, direction = d, raise_built = true }})
  return e and (e.unit_number .. " " .. e.position.x .. " " .. e.position.y) or "0 0 0"
end
local out = {{}}
out[#out + 1] = put("wooden-chest", 2.5, 0.5)
out[#out + 1] = put("assembling-machine-1", -3.5, 3.5)
out[#out + 1] = put("chemical-plant", 0.5, 3.5)
out[#out + 1] = put("fast-inserter", 2.5, -2.5)
out[#out + 1] = put("splitter", 5, -2.5)
out[#out + 1] = put("power-switch", -4, -3)
out[#out + 1] = put("gun-turret", 6, 3)
out[#out + 1] = put("small-electric-pole", -1.5, -1.5)
c.insert({{ name = "iron-plate", count = 50 }})
c.get_main_inventory().insert({{ name = "firearm-magazine", count = 10 }})
rcon.print(table.concat(out, " "))
""".replace("\n", " "))
    names = ["wooden-chest", "assembling-machine-1", "chemical-plant", "fast-inserter", "splitter", "power-switch",
             "gun-turret", "small-electric-pole"]
    vals = out.split()
    if len(vals) != 3 * len(names) or "0" in vals[0::3]:
        report(False, "ui parity: building the test entities", out)
        return
    units = [int(v) for v in vals[0::3]]
    chest, asm_a, asm_b, ins, spl, sw, turret, pl = units
    pos = {u: (float(vals[3 * i + 1]), float(vals[3 * i + 2]), names[i]) for i, u in enumerate(units)}
    c.pump(1.0, every=hello)
    ident = lambda u: {"u": u, "p": c.proto_id(pos[u][2]), "x": fx(pos[u][0]), "y": fx(pos[u][1])}
    count_in = lambda u, item: int(mod_lua(
        f'local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({{ force = c.force }})) do '
        f'if e.unit_number == {u} then rcon.print(e.get_item_count("{item}")) return end end rcon.print(-1)') or -1)

    # Z: one item into the chest under the mouse, then onto the ground.
    c.send({"t": "drop", "item": "iron-plate", "x": fx(pos[chest][0]), "y": fx(pos[chest][1])})
    c.pump(0.5, every=hello)
    report(count_in(chest, "iron-plate") == 1, "drop (Z) over a chest inserts one (LuaEntity.can_insert / insert)")
    c.send({"t": "drop", "item": "iron-plate", "x": fx(x - 2), "y": fx(y)})
    c.pump(0.5, every=hello)
    out = mod_lua(f"rcon.print(storage.f3d.puppet.surface.count_entities_filtered({{ type = 'item-entity', position = {{ {x - 2}, {y} }}, radius = 1.5 }}))")
    report(out not in ("", "0"), "drop (Z) over nothing: spill_item_stack{allow_belts, max_radius} puts it on the ground", out)

    # Ctrl+click: a stack in (half), everything out.
    c.send({"t": "fast", **ident(chest), "item": "iron-plate", "half": 1})
    c.pump(0.5, every=hello)
    n_in = count_in(chest, "iron-plate")
    c.send({"t": "fast", **ident(chest), "half": 0})
    c.pump(0.5, every=hello)
    report(n_in > 1 and count_in(chest, "iron-plate") == 0, "fast transfer: half a stack in, then everything out", f"{n_in} went in")

    # Shift+right / Shift+left: an assembler's recipe copied to another (copy_settings); H flips a
    # chemical plant (assembler 1 can't be flipped: the mod says so).
    mod_lua(f'for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = "assembling-machine-1" }})) do '
            f'if e.unit_number == {asm_a} then e.set_recipe("iron-gear-wheel") end end')
    asm_c = int(mod_lua(f'local c = storage.f3d.puppet local e = c.surface.create_entity({{ name = "assembling-machine-1", '
                        f'position = {{ {x - 3.5}, {y + 8.5} }}, force = c.force }}) rcon.print(e and e.unit_number or 0)') or 0)
    pos[asm_c] = (x - 3.5, y + 8.5, "assembling-machine-1")
    c.send({"t": "paste_settings", "f": [ident(asm_a)[k] for k in ("u", "p", "x", "y")], **ident(asm_c)})
    c.send({"t": "flip", **ident(asm_b), "v": 0})
    c.send({"t": "flip", **ident(asm_c), "v": 0})
    msgs = c.pump(0.8, every=hello)
    out = mod_lua(f'local o = {{}} for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ force = "player" }})) do '
                  f'if e.unit_number == {asm_c} then local r = e.get_recipe() o[1] = r and r.name or "none" end '
                  f'if e.unit_number == {asm_b} then o[2] = tostring(e.mirroring) end end rcon.print(table.concat(o, " "))')
    report(out == "iron-gear-wheel true", "paste_settings (LuaEntity.copy_settings) and flip (mirroring of a chemical plant)", out)
    report(any(m["text"] == "This can't be flipped" for m in of_type(msgs, "msg")), "flipping an assembler 1 is refused")

    # Alt-mode lists the assemblers' recipes.
    c.send({"t": "alt", "on": 1})
    msgs = c.pump(2.5, every=hello)
    icons = [r for m in of_type(msgs, "ai") for r in m["l"]]
    report([asm_a, "recipe", "iron-gear-wheel"] in icons, "alt: Alt-mode icons (get_recipe, filters)", str(icons[:6]))
    report(all(r[0] != asm_b for r in icons) and all(isinstance(r[2], str) and not r[2].startswith("[") for r in icons),
           "alt: nothing over a machine without a recipe (the chemical plant), every icon a name", str(icons[:6]))
    c.send({"t": "alt", "on": 0})
    check_build_marks(c, hello, x, y)

    # The clipboard: copy the two assemblers, paste them further along, Alt+B makes a blueprint.
    area = {"x1": fx(x - 6), "y1": fx(y + 1), "x2": fx(x + 3), "y2": fx(y + 6)}
    c.send({"t": "copy", **area, "cut": 0, "bp": 0})
    msgs = c.pump(1.0, every=hello)
    clip = of_type(msgs, "clip")
    report(bool(clip) and len(clip[-1]["l"]) >= 2, "copy: create_blueprint in a script inventory, the clipboard's entities",
           str(clip[-1]["l"][:4]) if clip else "no clip")
    c.send({"t": "paste", "x": fx(x - 1), "y": fx(y + 12), "d": 0})
    msgs = c.pump(1.0, every=hello)
    ghost = c.proto_id("entity-ghost")
    ghosts = [m["e"] for m in of_type(msgs, "add") if m["e"][1] == ghost]
    report(len(ghosts) >= 2, "paste: the clipboard's ghosts (build_blueprint)", f"{len(ghosts)} ghosts")
    c.send({"t": "copy", **area, "cut": 0, "bp": 1})
    msgs = c.pump(1.0, every=hello)
    report(any(m["text"] == "Blueprint added to the inventory" for m in of_type(msgs, "msg")), "Alt+B area: a blueprint in the main inventory")
    c.send({"t": "build", "item": "wooden-chest", "x": fx(x + 9.5), "y": fx(y + 9.5), "d": 0, "ghost": 1})
    msgs = c.pump(1.0, every=hello)
    report(any(m["e"][1] == ghost and m["e"][5].get("gh") == c.proto_id("wooden-chest") for m in of_type(msgs, "add")),
           "build ghost = 1: an entity ghost without the item")

    # Chat and statistics.
    c.send({"t": "chat", "text": "live check says hi"})
    c.send({"t": "stats", "kind": "item", "prec": 2})
    c.send({"t": "stats", "kind": "kill", "prec": 8})
    c.send({"t": "stats", "kind": "electric", "prec": 1, **ident(pl)})
    msgs = c.pump(1.5, every=hello)
    report(any(m["text"] == "live check says hi" for m in of_type(msgs, "chat")), "chat: game.print and the echo")
    st = {m["kind"]: m for m in of_type(msgs, "stats")}
    report({"item", "kill", "electric"} <= set(st) and isinstance(st["electric"].get("st"), (list, dict)),
           "stats: item, kill and electric network statistics (LuaFlowStatistics), the accumulators' storage (st)",
           " | ".join(f"{k}: {list(v['l'])[:3]}" for k, v in st.items()))
    ef = st.get("electric", {}).get("ef")
    report(isinstance(ef, list) and len(ef) == 6, "stats: the electric network's last update (flow_last_tick) for the summary bars",
           f"ef {ef}")

    # Entity windows: inserter, splitter, power switch, turret, chest bar.
    def screen(u, cmd=None):
        c.send({"t": "open", **ident(u)})
        if cmd:
            c.send(cmd)
        msgs = c.pump(1.0, every=hello)
        g = [m for m in of_type(msgs, "gui") if m.get("u") == u and not m.get("closed")]
        return g[-1] if g else {}

    g = screen(ins, {"t": "set_inserter", "u": ins, "f": ["iron-plate"], "m": "blacklist", "use": 1, "st": 1})
    report(g.get("kind") == "inserter" and g.get("ins", {}).get("f", [""])[0] == "iron-plate" and g["ins"].get("m") == "blacklist"
           and g["ins"].get("st") == 1, "inserter screen: filters, mode, use_filters, stack size override", str(g.get("ins")))
    g = screen(spl, {"t": "set_splitter", "u": spl, "i": "left", "o": "right", "f": "iron-plate"})
    report(g.get("kind") == "splitter" and g.get("spl") == {"i": "left", "o": "right", "f": "iron-plate"},
           "splitter screen: priorities and filter", str(g.get("spl")))
    g = screen(sw, {"t": "set_switch", "u": sw, "on": 1})
    report(g.get("kind") == "switch" and g.get("sw") == 1, "power switch screen: power_switch_state", str(g.get("sw")))
    g = screen(turret, {"t": "put", "u": turret, "item": "firearm-magazine", "n": 5})
    report(g.get("kind") == "turret" and "turret_ammo" in g.get("slots", {}) and g["inv"].get("turret_ammo"),
           "turret screen: its ammo inventory (defines.inventory.turret_ammo)", str(g.get("inv")))
    g = screen(chest, {"t": "set_bar", "u": chest, "n": 4})
    report(g.get("kind") == "container" and g.get("bar") == 4, "chest limit bar: get_bar / set_bar", str(g.get("bar")))
    g = screen(pl)
    report(g.get("kind") == "pole", "a pole opens (for its network statistics)", str(g.get("kind")))
    car = int(mod_lua(f'local c = storage.f3d.puppet local e = c.surface.create_entity({{ name = "car", position = {{ {x - 6}, {y - 6} }}, '
                      f'force = c.force }}) rcon.print(e and e.unit_number or 0)') or 0)
    pos[car] = (x - 6, y - 6, "car")
    g = screen(car)
    report(g.get("kind") == "vehicle" and {"fuel", "trunk", "car_ammo"} <= set(g.get("slots", {})),
           "a car opens with its fuel, trunk and ammo (car_trunk, car_ammo)", str(sorted(g.get("slots", {}))))
    c.send({"t": "close"})
    c.send({"t": "inv_filter", "i": 10, "item": "iron-plate"})
    msgs = c.pump(1.0, every=hello)
    sl = of_type(msgs, "slots")
    report(bool(sl) and [10, "iron-plate"] in sl[-1].get("fl", []), "inv_filter: a main inventory slot filter (LuaInventory.set_filter / get_filter)",
           str(sl[-1].get("fl") if sl else None))
    c.send({"t": "inv_filter", "i": 10, "item": ""})
    c.pump(0.5, every=hello)
    destroy_units([car])
    mod_lua(f"local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({{ area = {{ {{ {x - 10}, {y - 10} }}, {{ {x + 12}, {y + 16} }} }}, "
            "type = { 'entity-ghost', 'item-entity' } })) do e.destroy() end")
    destroy_units([chest, asm_a, asm_b, asm_c, ins, spl, sw, turret, pl])
    c.pump(0.5, every=hello)


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


def check_triggers(c, hello):
    """Issue #7: 2.x unlocks red science by a trigger (craft a lab), and a character with no player
    is left out of the production statistics that set triggers off, so a lab hand-crafted through
    the bridge never unlocked it. crafting.lua records the character's finished crafts itself."""
    mod_lua("local c = storage.f3d.puppet local f = c.force "
            "for _, n in pairs({'steam-power', 'electronics'}) do f.technologies[n].researched = true end "
            "f.technologies['automation-science-pack'].researched = false "
            "c.insert({ name = 'iron-gear-wheel', count = 10 }) c.insert({ name = 'electronic-circuit', count = 10 }) "
            "c.insert({ name = 'transport-belt', count = 4 })")
    before = mod_lua("local c = storage.f3d.puppet rcon.print(c.force.get_item_production_statistics(c.surface).get_input_count('lab'))")
    c.send({"t": "craft", "recipe": "lab", "n": 1})
    c.pump(4.0, every=hello)
    out = mod_lua("local c = storage.f3d.puppet local f = c.force "
                  "rcon.print(f.get_item_production_statistics(c.surface).get_input_count('lab') .. ' ' "
                  ".. tostring(f.technologies['automation-science-pack'].researched) .. ' ' "
                  ".. tostring(f.recipes['automation-science-pack'].enabled) .. ' ' .. c.get_item_count('lab'))").split()
    report(len(out) == 4 and int(out[0]) == int(before or 0) + 1 and out[1:3] == ["true", "true"] and int(out[3]) >= 1,
           "a hand-crafted lab counts in the production statistics and unlocks red science (issue #7)",
           f"labs counted {before} -> {out[:1]}, researched and recipe {out[1:3]}, labs held {out[3:]}")


def check_research(c, hello):
    """K23: research finishing (`rdone`, research.lua). A technology of one level researched by script
    is named once, level 0, with the tick it finished in, and an `rs` follows; an infinite one names
    the level it finished, read against LuaTechnology.level before and after (the bridge takes the
    level read in the event as the next one). Both are undone afterwards."""
    picked = mod_lua("local f = storage.f3d.puppet.force local one, inf = {}, {} "
                     "for name, t in pairs(f.technologies) do local p = t.prototype "
                     "if t.enabled and not p.hidden then "
                     "if not t.researched and p.max_level == p.level then one[#one + 1] = name end "
                     "if p.max_level == 4294967295 then inf[#inf + 1] = name end end end "
                     "table.sort(one) table.sort(inf) rcon.print((one[1] or '-') .. ' ' .. (inf[1] or '-'))").split()
    if len(picked) != 2 or picked[0] == "-":
        report(False, "research: a technology of one level to research by script", str(picked))
        return
    one, inf = picked
    tech = 'storage.f3d.puppet.force.technologies["%s"]'
    c.pump(0.5, every=hello)
    mod_lua(f"{tech % one}.researched = true")
    msgs = c.pump(1.5, every=hello, until=lambda m: m.get("t") == "rdone")
    msgs += c.pump(0.5, every=hello)
    done = of_type(msgs, "rdone")
    named = [e for m in done for e in m["l"]]
    report(named == [[one, 0]] and len(done) == 1 and isinstance(done[0].get("tick"), int),
           "rdone: a finished research named once, level 0, with its tick (on_research_finished)", str(done)[:300])
    after = msgs[msgs.index(done[0]) + 1:] if done else []
    report(bool(of_type(after, "rs")), "rdone: the research status (rs) follows it", str([m["t"] for m in after][:20]))
    mod_lua(f"{tech % one}.researched = false")
    if inf == "-":
        print("INFO research: no infinite technology in this game, its level not checked")
        return
    before = mod_lua(f"rcon.print({tech % inf}.level)")
    if not before.isdigit():
        report(False, "research: an infinite technology's level", f"{inf}: {before}")
        return
    c.pump(0.5, every=hello)
    # Setting researched on an infinite technology researches its level (2.1's LuaTechnology); if that
    # raises nothing, writing the level ("the same as researching the technology to the previous level").
    how = "researched = true"
    tried = mod_lua(f"local ok, err = pcall(function() {tech % inf}.researched = true end) rcon.print(tostring(ok) .. ' ' .. tostring(err))")
    msgs = c.pump(1.5, every=hello, until=lambda m: m.get("t") == "rdone")
    if not of_type(msgs, "rdone"):
        how = "level = level + 1"
        mod_lua(f"{tech % inf}.level = {int(before) + 1}")
        msgs += c.pump(1.5, every=hello, until=lambda m: m.get("t") == "rdone")
    msgs += c.pump(0.3, every=hello)
    now = mod_lua(f"rcon.print({tech % inf}.level)")
    now = int(now) if now.isdigit() else -1
    named = [e for m in of_type(msgs, "rdone") for e in m["l"]]
    report(named == [[inf, int(before)]] and now == int(before) + 1,
           "rdone: an infinite research names the level it finished, its level goes on",
           f"{inf}: level {before} -> {now} by {how} ({tried}), rdone {named}")
    mod_lua(f"{tech % inf}.level = {int(before)}")


def check_walk(c, hello):
    """B7: `walk` with an angle. The mod steps each tick in one of the two 8-way directions either side
    of it (puppet.lua angle_step); in the real game the path must follow the line within a few
    hundredths of a tile at the character's own speed, and slide along a wall in the way."""
    if not clean_spot(c, hello):
        report(False, "walk: no clean spot found", SPOT_WHY)
        return
    # The walks go up to 25 tiles from the spot, past clean_spot's square: whatever the map put
    # there (trees, rocks, cliffs, water) would turn the character aside and fail the path checks
    # on some maps and not others, so the ground 32 tiles round is cleared first. Each walk starts
    # from the spot again: one after another they used to end some 35 tiles out, past the cleared
    # ground, where water or trees stopped the wall check (it failed on every CI run since 0.1.2)
    # and nudged the angled path off its line (0.19 tiles on 0.2.0's CI).
    spot = mod_lua("local c = storage.f3d.puppet local s = c.surface local p = c.position "
                   "local area = { { p.x - 32, p.y - 32 }, { p.x + 32, p.y + 32 } } "
                   "for _, e in pairs(s.find_entities_filtered({ area = area, type = { 'tree', 'simple-entity', 'cliff', 'fish' } })) do e.destroy() end "
                   "local tiles = {} for _, t in pairs(s.find_tiles_filtered({ area = area, collision_mask = 'water_tile' })) do "
                   "tiles[#tiles + 1] = { name = 'landfill', position = t.position } end "
                   "if #tiles > 0 then s.set_tiles(tiles) end rcon.print(p.x .. ' ' .. p.y)")
    c.pump(0.5, every=hello)

    def back():
        mod_lua(f"storage.f3d.puppet.teleport({{ {spot.split()[0]}, {spot.split()[1]} }})")
        c.pump(0.4, every=hello)

    def walk(msg, seconds):
        msgs = c.pump(seconds, every=(0.15, msg))
        c.send({"t": "walk", "d": -1})
        c.pump(0.4, every=hello)
        return [m for m in of_type(msgs, "me") if m["w"] == 1]

    def speed(mes):
        """Tiles a tick between the first and last walking `me`, and the straight line's length."""
        a, b = mes[2], mes[-1]
        dist = math.hypot(b["x"] - a["x"], b["y"] - a["y"]) / 256
        return dist / max(1, b["k"] - a["k"])

    straight = speed(walk({"t": "walk", "d": 4}, 1.5))
    back()
    diagonal = speed(walk({"t": "walk", "d": 2}, 1.5))
    back()
    report(straight > 0.1 and abs(diagonal - straight) < 0.005, "walk: Factorio's character walks diagonally at its straight speed",
           f"{straight:.4f} and {diagonal:.4f} tiles a tick")
    a = 56  # 20.16 degrees east of north
    rad = a / 1000 * 2 * math.pi
    ux, uy = math.sin(rad), -math.cos(rad)
    mes = walk({"t": "walk", "d": 2, "a": a}, 3.0)
    if len(mes) < 20:
        report(False, "walk: walking at an angle sends me", str(len(mes)))
        return
    x0, y0 = mes[0]["x"] / 256, mes[0]["y"] / 256
    side = [abs((m["x"] / 256 - x0) * uy - (m["y"] / 256 - y0) * ux) for m in mes]
    along = [(m["x"] / 256 - x0) * ux + (m["y"] / 256 - y0) * uy for m in mes]
    dirs = {m["d"] for m in mes}
    ticks = mes[-1]["k"] - mes[0]["k"]
    # The line is drawn from the first `me`, itself up to one step's sideways drift (~0.06) off the
    # character's own line, so the path can read up to two such steps off it.
    report(max(side) < 0.15 and dirs <= {0, 2} and all(m.get("a") == a for m in mes),
           "walk: at 20 degrees the real path keeps to the line, stepping north and north-east",
           f"{along[-1]:.1f} tiles, {max(side):.3f} tiles off the line at most, directions {sorted(dirs)}")
    report(along[-1] / ticks > 0.9 * straight, "walk: and goes along the line at cos(the zig-zag's angle) of the straight speed or more",
           f"{along[-1] / ticks:.4f} tiles a tick along it, {along[-1] / ticks / straight:.3f} of straight")
    # A wall across the way north: the character slides east along it instead of stopping.
    x, y = c.me["x"] / 256, c.me["y"] / 256
    units = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local out = {{}}
for i = -2, 14 do
  local e = s.create_entity({{ name = "stone-wall", position = {{ {math.floor(x)} + i + 0.5, {math.floor(y)} - 1.5 }}, force = c.force }})
  out[#out + 1] = e and e.unit_number or 0
end
rcon.print(table.concat(out, " "))
""".replace("\n", " ")).split()
    c.pump(0.3, every=hello)
    before = (c.me["x"] / 256, c.me["y"] / 256)
    mes = walk({"t": "walk", "d": 2, "a": a}, 2.0)
    after = (c.me["x"] / 256, c.me["y"] / 256)
    late = mes[len(mes) // 2:]  # by then it has reached the wall
    east = (late[-1]["x"] - late[0]["x"]) / 256 / max(1, late[-1]["k"] - late[0]["k"])
    north = (late[0]["y"] - late[-1]["y"]) / 256
    report(len(late) > 5 and east > 0.02 and abs(north) < 0.05,
           "walk: against a wall in the way it slides along it",
           f"{after[0] - before[0]:.2f} east and {before[1] - after[1]:.2f} north in all; at the wall {east:.4f} tiles a tick east, {north:.3f} north")
    destroy_units([int(u) for u in units])
    stop = c.me["x"], c.me["y"]
    c.pump(0.6, every=hello)
    report((c.me["x"], c.me["y"]) == stop and c.me["w"] == 0 and "a" not in c.me, "walk: walk -1 stops an angled walk", str(c.me)[:200])
    back()
    # J26: walking with the mining button held and the cursor ahead over a line of belts mines every belt
    # in turn, as Factorio's own mining does: the client sends only where its cursor is from the
    # character (`mine` `n`, `ox`, `oy`), the bridge's sweep follows that point each tick, and the
    # character stands while it mines.
    x, y = c.me["x"] / 256, c.me["y"] / 256
    bx, by = math.floor(x) + 2.5, math.floor(y) - 1.5
    belts = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local out = {{}}
for i = 0, 4 do
  local e = s.create_entity({{ name = "transport-belt", position = {{ {bx} + i, {by} }}, direction = defines.direction.east, force = c.force }})
  out[#out + 1] = e and e.unit_number or 0
end
rcon.print(table.concat(out, " "))
""".replace("\n", " ")).split()
    c.pump(0.3, every=hello)
    sweep = {"t": "mine", "n": 1, "ox": int(round((bx - x) * 256)), "oy": int(round((by - y) * 256))}
    mes = []
    for i in range(30):
        if i % 5 == 0:
            c.send(hello[1])  # the keep-alive (commands don't count towards it)
        c.send({"t": "walk", "d": 4})
        c.send(sweep)
        mes += of_type(c.pump(0.15), "me")
        left = mod_lua(f"rcon.print(storage.f3d.puppet.surface.count_entities_filtered({{ name = 'transport-belt', "
                       f"area = {{ {{ {bx - 0.4}, {by - 0.4} }}, {{ {bx + 4.4}, {by + 0.4} }} }} }}))")
        if left.strip() == "0":
            break
    c.send({"t": "walk", "d": -1})
    c.send({"t": "mine_stop"})
    c.pump(0.4, every=hello)
    # Moved while mining: two `me` in a row mining the same belt from different places.
    moved = [(a["k"], b["k"], a["x"], b["x"], a.get("m"), b.get("m"), a["w"], b["w"]) for a, b in zip(mes, mes[1:])
             if "m" in a and "m" in b and (a["mx"], a["my"]) == (b["mx"], b["my"]) and (a["x"], a["y"]) != (b["x"], b["y"])]
    report(left.strip() == "0" and any("m" in m for m in mes) and not moved,
           "walk: J26, walking with the button held mines every belt of a line in turn, standing while it mines",
           f"{left.strip()} of 5 left; {sum(1 for m in mes if 'm' in m)} `me` mining; moved while mining: {moved[:4]}; "
           f"walking flag with m: {[(m['k'], m['x'], m['m'], m['w']) for m in mes if 'm' in m and m['w'] == 1][:4]}")
    destroy_units([int(u) for u in belts])
    back()  # on the clean, watched spot, for whatever comes next


def check_pickup(c, hello):
    """Issue #18: F (`pickup`) takes the items on belts within the character's item pickup distance too, as
    Factorio's "Pick up items" does, each said at once (`pku`), with an item on the ground as before. First
    Factorio's own rule is measured on the bridge's player-less character (picking_state: whether the game picks
    up for it at all, how far, how many), printed as INFO to compare with; then the bridge's own is checked.
    The belts are a packed column east of the character, backed up against its north end, so nothing moves
    until something is taken. (No Lua comments: each snippet is sent as one line.)"""
    if not clean_spot(c, hello):
        report(False, "pickup: no clean spot found", SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    bx, y0 = math.floor(x) + 1.5, math.floor(y)
    reach = float(mod_lua("rcon.print(storage.f3d.puppet.item_pickup_distance)") or 1) + 0.5  # puppet.lua's PICKUP_SLACK

    def build():
        return mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local out = {{}}
for i = -3, 3 do
  local b = s.create_entity({{ name = "transport-belt", position = {{ {bx}, {y0} + i + 0.5 }}, direction = defines.direction.north, force = c.force }})
  if b then
    for l = 1, 2 do for q = 0.125, 0.875, 0.25 do b.get_transport_line(l).insert_at(q, {{ name = "iron-plate", count = 1 }}) end end
    out[#out + 1] = b.unit_number
  end
end
local f = s.create_entity({{ name = "transport-belt", position = {{ {bx} + 10, {y0} + 0.5 }}, direction = defines.direction.north, force = c.force }})
if f then f.get_transport_line(1).insert_at(0.5, {{ name = "iron-plate", count = 1 }}) out[#out + 1] = f.unit_number end
rcon.print(table.concat(out, " "))
""".replace("\n", " ")).split()

    def items(units):
        """{unique id: (x, y)} of the items on these belts' lanes now."""
        out = mod_lua("local want = {} for _, u in pairs({ " + ", ".join(units) + " }) do want[u] = true end "
                      "local c = storage.f3d.puppet local p0 = c.position local out = {} "
                      "for _, e in pairs(c.surface.find_entities_filtered({ type = 'transport-belt', force = c.force, "
                      "area = { { p0.x - 16, p0.y - 16 }, { p0.x + 16, p0.y + 16 } } })) do "
                      "if want[e.unit_number] then for l = 1, 2 do local line = e.get_transport_line(l) "
                      "for _, it in pairs(line.get_detailed_contents()) do local p = line.get_line_item_position(it.position) "
                      "out[#out + 1] = it.unique_id .. ',' .. p.x .. ',' .. p.y end end end end "
                      "rcon.print(table.concat(out, ' '))")
        return {int(u): (float(a), float(b)) for u, a, b in (w.split(",") for w in out.split())}

    # Factorio's own: picking_state held on the player-less character for a second.
    units = build()
    c.pump(1.0, every=hello)
    px, py = c.me["x"] / 256, c.me["y"] / 256
    before = items(units)
    plates = inv_count("iron-plate")
    took = mod_lua("local ok = pcall(function() storage.f3d.puppet.picking_state = true end) rcon.print(ok and 'set' or 'refused')")
    end = time.time() + 1.0
    while time.time() < end:
        c.pump(0.1, every=hello)
        mod_lua("pcall(function() storage.f3d.puppet.picking_state = true end)")
    mod_lua("pcall(function() storage.f3d.puppet.picking_state = false end)")
    c.pump(0.3, every=hello)
    after = items(units)
    dist = {u: math.hypot(p[0] - px, p[1] - py) for u, p in before.items()}
    gone = [u for u in before if u not in after]
    print(f"INFO pickup: Factorio's own picking_state on the bridge's player-less character ({took}) took {len(gone)} of "
          f"{len(before)} belt items in a second (+{inv_count('iron-plate') - plates} plates), the furthest "
          f"{max((dist[u] for u in gone), default=0):.2f} tiles off as they lay; the nearest not taken "
          f"{min((dist[u] for u in before if u in after), default=0):.2f}; item_pickup_distance {reach - 0.5}")
    destroy_units([int(u) for u in units])
    c.pump(0.3, every=hello)

    # The bridge's own: F held for a second.
    units = build()
    ground = mod_lua(f"local c = storage.f3d.puppet local e = c.surface.create_entity({{ name = 'item-on-ground', "
                     f"position = {{ {x} - 0.7, {y} }}, stack = {{ name = 'wood', count = 1 }} }}) rcon.print(e and 'ok' or 'none')")
    c.pump(1.0, every=hello)
    px, py = c.me["x"] / 256, c.me["y"] / 256
    before = items(units)
    near = {u for u, p in before.items() if math.hypot(p[0] - px, p[1] - py) <= reach - 0.05}
    far = {u for u, p in before.items() if p[0] > bx + 5}
    plates, wood = inv_count("iron-plate"), inv_count("wood")
    msgs = c.pump(1.0, every=(0.15, {"t": "pickup"}))
    msgs += c.pump(1.0, every=hello)
    after = items(units)
    recs = [r for m in of_type(msgs, "pku") for r in m["l"]]
    on_belt = [r for r in recs if r[4]]
    taken = {r[5] for r in on_belt}
    belt_units = {int(u) for u in units}
    report(on_belt and taken <= set(before) and all(r[0] == "iron-plate" and r[4] // 8 in belt_units and r[6] == 0 for r in on_belt),
           "pickup: F takes the items on belts in reach, each said at once (pku: its lane and unique id)",
           f"{len(on_belt)} said, {len(near)} in reach at the start; {on_belt[:2]}")
    report(near <= taken and not taken & set(after) and far <= set(after),
           "pickup: every item in reach comes off its lane, none said taken is still there, a belt out of reach keeps its own",
           f"in reach and not said: {sorted(near - taken)[:4]}; said and still there: {sorted(taken & set(after))[:4]}")
    off = [round(math.hypot(r[2] / 256 - px, r[3] / 256 - py), 3) for r in on_belt]
    report(off and max(off) <= reach + 0.02, "pickup: each where the game had it, within the pickup distance",
           f"furthest {max(off, default=0)} tiles, reach {reach}")
    report(inv_count("iron-plate") - plates == sum(r[1] for r in on_belt),
           "pickup: the inventory got what pku says, no more", f"{inv_count('iron-plate') - plates} plates, said {sum(r[1] for r in on_belt)}")
    ground_recs = [r for r in recs if not r[4]]
    report(ground != "ok" or (ground_recs and ground_recs[0][0] == "wood" and inv_count("wood") == wood + 1),
           "pickup: and the item lying on the ground, said too (lane 0)", str(ground_recs[:1]))
    ks = [m["k"] for m in of_type(msgs, "pku")]
    later_bi = [v for m in of_type(msgs, "bi") if ks and m.get("k", 0) > max(ks) + 12 for v in m["l"][0::4]]
    if later_bi:
        report(not taken & set(later_bi), "pickup: the belt items it took are gone from the belt items sent after",
               str(sorted(taken & set(later_bi))[:4]))
    destroy_units([int(u) for u in units])
    c.pump(0.3, every=hello)


def check_input(c, hello):
    """Slot clicks and fast transfers as the client sends them (move, xfer, fast), compared with
    what 2.1.23's own inventory actions do (tools/ui_reference/f3d-ui-capture/rules.lua, recorded
    with LuaPlayer.cursor_transfer / cursor_split / stack_transfers in the real game)."""
    if not clean_spot(c, hello):
        report(False, "input: no clean spot found", SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    fx = lambda v: int(round(v * 256))
    out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local x, y = {x}, {y}
local function put(name, dx, dy)
  local e = s.create_entity({{ name = name, position = {{ x + dx, y + dy }}, force = c.force, raise_built = true }})
  return e and (e.unit_number .. " " .. e.position.x .. " " .. e.position.y) or "0 0 0"
end
local out = {{}}
out[#out + 1] = put("iron-chest", 2.5, 0.5)
out[#out + 1] = put("stone-furnace", -3, 1)
out[#out + 1] = put("assembling-machine-1", 0.5, 4.5)
out[#out + 1] = put("transport-belt", 4.5, -2.5)
out[#out + 1] = put("lab", -4.5, -3.5)
rcon.print(table.concat(out, " "))
""".replace("\n", " "))
    names = ["iron-chest", "stone-furnace", "assembling-machine-1", "transport-belt", "lab"]
    vals = out.split()
    if len(vals) != 3 * len(names) or "0" in vals[0::3]:
        report(False, "input: building the test entities", out)
        return
    units = [int(v) for v in vals[0::3]]
    chest, furnace, asm, belt, lab = units
    pos = {u: (float(vals[3 * i + 1]), float(vals[3 * i + 2]), names[i]) for i, u in enumerate(units)}
    ident = lambda u: {"u": u, "p": c.proto_id(pos[u][2]), "x": fx(pos[u][0]), "y": fx(pos[u][1])}
    c.pump(1.0, every=hello)
    entity = lambda u: (f"(function() for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ force = 'player' }})) do "
                        f"if e.unit_number == {u} then return e end end end)()")

    def main(*stacks):
        """Empties the character's main inventory and fills its first slots with these stacks."""
        parts = " ".join(f'm[{i + 1}].set_stack({{ name = "{st[0]}", count = {st[1]} }})' for i, st in enumerate(stacks) if st)
        mod_lua(f"local m = storage.f3d.puppet.get_main_inventory() m.clear() {parts} rcon.print('ok')")

    def slots(inv="main", unit=0, n=4):
        """The first n slots of the main inventory, or of that entity's inventory (a defines.inventory name)."""
        where = "storage.f3d.puppet.get_main_inventory()" if unit == 0 else f"{entity(unit)}.get_inventory(defines.inventory.{inv})"
        got = mod_lua(f"local i = {where} local o = {{}} for k = 1, math.min({n}, #i) do local st = i[k] "
                      f"o[k] = st.valid_for_read and (st.name .. ':' .. st.count) or '-' end rcon.print(table.concat(o, ' '))")
        return got.split()

    def first_define(*names_):
        for n in names_:
            if mod_lua(f"rcon.print(defines.inventory['{n}'] and 'y' or 'n')") == "y":
                return n
        return names_[0]

    def totals(ss):
        out = {}
        for v in ss:
            if v != "-":
                k, n = v.rsplit(":", 1)
                out[k] = out.get(k, 0) + int(n)
        return out

    # Left click onto the same item: what fits goes, the rest stays (merge_overflow, merge_into_full).
    main(("iron-plate", 80), ("iron-plate", 50))
    c.send({"t": "move", "from": "main", "fi": 1, "to": "main", "ti": 2})
    c.pump(0.4, every=hello)
    got = slots()
    report(got[:2] == ["iron-plate:30", "iron-plate:100"], "move onto the same item: 100 in the slot, 30 left (2.1.23: cursor 30)", str(got))
    c.send({"t": "move", "from": "main", "fi": 1, "to": "main", "ti": 2})
    c.pump(0.4, every=hello)
    got = slots()
    report(got[:2] == ["iron-plate:30", "iron-plate:100"], "move onto a full stack of it: nothing moves (2.1.23: no swap)", str(got))

    # Shift / Ctrl clicks with the chest open (stack_transfer, stack_split, inventory_transfer, inventory_split).
    c.send({"t": "open", **ident(chest)})
    c.pump(0.5, every=hello)
    cases = [
        ("stack", 1, [("iron-plate", 37), ("iron-plate", 30)], ["-", "iron-plate:30"], {"iron-plate": 37}, "Shift+click: the stack"),
        ("half", 1, [("iron-plate", 37), ("iron-plate", 30)], ["iron-plate:19", "iron-plate:30"], {"iron-plate": 18},
         "Shift+right click: the smaller half (18 of 37)"),
        ("all", 1, [("iron-plate", 37), ("iron-plate", 30), ("copper-plate", 5)], ["-", "-", "copper-plate:5"], {"iron-plate": 67},
         "Ctrl+click: every stack of the item (67)"),
        ("allhalf", 1, [("iron-plate", 37), ("iron-plate", 30), ("copper-plate", 5)], ["iron-plate:19", "iron-plate:15", "copper-plate:5"],
         {"iron-plate": 33}, "Ctrl+right click: half of each (18 + 15)"),
        ("all", 2, [("iron-plate", 37), None, ("copper-plate", 5)], ["-", "-", "-"], {"iron-plate": 37, "copper-plate": 5},
         "Ctrl+click on an empty slot: everything"),
        ("stack", 2, [("iron-plate", 37), None, ("copper-plate", 5)], ["iron-plate:37", "-", "copper-plate:5"], {},
         "Shift+click on an empty slot: nothing"),
    ]
    for kind, fi, stacks, want_main, want_chest, why in cases:
        mod_lua(f"{entity(chest)}.get_inventory(defines.inventory.chest).clear() rcon.print('ok')")
        main(*stacks)
        c.send({"t": "xfer", "from": "main", "fi": fi, "k": kind, "u": chest})
        c.pump(0.4, every=hello)
        got_main, got_chest = slots(), slots("chest", chest, 8)
        report(got_main[:len(want_main)] == want_main and totals(got_chest) == want_chest,
               f"xfer {kind}: {why}", f"main {got_main} chest {got_chest}")
    mod_lua(f"local i = {entity(chest)}.get_inventory(defines.inventory.chest) i.clear() "
            f"i[1].set_stack({{ name = 'iron-plate', count = 37 }}) i[2].set_stack({{ name = 'iron-plate', count = 30 }}) rcon.print('ok')")
    main()
    c.send({"t": "xfer", "from": "chest", "fi": 1, "k": "half", "u": chest})
    c.pump(0.4, every=hello)
    got_main, got_chest = slots(), slots("chest", chest)
    report(got_main[0] == "iron-plate:18" and got_chest[:2] == ["iron-plate:19", "iron-plate:30"],
           "xfer half from the chest: 18 of 37 into the character", f"main {got_main} chest {got_chest}")

    # Smart insertion: ore into the furnace's source (50 of 80), coal into its fuel.
    c.send({"t": "open", **ident(furnace)})
    c.pump(0.5, every=hello)
    main(("iron-ore", 50), ("coal", 30))
    c.send({"t": "xfer", "from": "main", "fi": 1, "k": "stack", "u": furnace})
    c.send({"t": "xfer", "from": "main", "fi": 2, "k": "stack", "u": furnace})
    c.pump(0.5, every=hello)
    src = slots(first_define("furnace_source", "crafter_input"), furnace, 1)
    fuel = slots("fuel", furnace, 1)
    # (it starts smelting at once: one ore and some coal may already be used)
    n_src = int(src[0].split(":")[1]) if src and src[0].startswith("iron-ore:") else 0
    report(48 <= n_src <= 50 and fuel and fuel[0].startswith("coal:") and slots()[:2] == ["-", "-"],
           "xfer into a furnace: a stack of ore (50) to the source, coal to the fuel (2.1.23 the same)", f"{src} {fuel} {slots()}")
    # An assembler takes what LuaEntity.insert gives it; the game's own Ctrl+click took 120 plates for gears.
    mod_lua(f"{entity(asm)}.set_recipe('iron-gear-wheel') rcon.print('ok')")
    c.send({"t": "open", **ident(asm)})
    c.pump(0.5, every=hello)
    main(("iron-plate", 100), ("iron-plate", 100))
    c.send({"t": "xfer", "from": "main", "fi": 1, "k": "all", "u": asm})
    c.pump(0.5, every=hello)
    got = slots(first_define("assembling_machine_input", "crafter_input"), asm, 1)
    report(bool(got) and got[0].startswith("iron-plate:"), "xfer all into an assembler (LuaEntity.insert)",
           f"{got}; the game's own Ctrl+click took 120")
    c.send({"t": "close"})
    c.pump(0.3, every=hello)

    # With nothing open: a gun to the gun slots, a plate stays.
    mod_lua("storage.f3d.puppet.get_inventory(defines.inventory.character_guns).clear() rcon.print('ok')")
    main(("pistol", 1), ("iron-plate", 5))
    c.send({"t": "xfer", "from": "main", "fi": 1, "k": "stack"})
    c.pump(0.4, every=hello)
    guns = mod_lua("rcon.print(storage.f3d.puppet.get_inventory(defines.inventory.character_guns).get_item_count('pistol'))")
    c.send({"t": "xfer", "from": "main", "fi": 2, "k": "stack"})
    msgs = c.pump(0.4, every=hello)
    report(guns == "1" and slots()[1] == "iron-plate:5" and any("Nowhere" in m["text"] for m in of_type(msgs, "msg")),
           "xfer with nothing open: a gun goes to the gun slots, a plate stays (2.1.23 the same)", f"guns {guns} {slots()}")

    # Ctrl+click on a belt: plates on, then off again; on a lab: its science packs out.
    main(("iron-plate", 10))
    c.send({"t": "fast", **ident(belt), "item": "iron-plate", "n": 10, "half": 0})
    c.pump(0.4, every=hello)
    on_belt = int(mod_lua(f"local e = {entity(belt)} local n = 0 for i = 1, 2 do n = n + e.get_transport_line(i).get_item_count() end "
                          f"rcon.print(n)") or -1)
    left = inv_count("iron-plate")
    c.send({"t": "fast", **ident(belt), "half": 0})
    c.pump(0.4, every=hello)
    report(on_belt > 0 and left == 10 - on_belt and inv_count("iron-plate") == 10,
           "fast on a belt: plates onto its lanes (insert_at_back), then all back (get_contents, remove_item)",
           f"{on_belt} went on, {left} left, {inv_count('iron-plate')} after")
    mod_lua(f"{entity(lab)}.insert({{ name = 'automation-science-pack', count = 10 }}) rcon.print('ok')")
    c.send({"t": "fast", **ident(lab), "half": 0})
    c.pump(0.4, every=hello)
    report(inv_count("automation-science-pack") == 10, "fast with an empty hand on a lab takes its science packs (lab_input)",
           str(inv_count("automation-science-pack")))
    destroy_units(units)
    check_hand_stack(c, hello, x, y)


def check_hand_stack(c, hello, x, y):
    """L7: Factorio builds out of the cursor's stack. A `build` naming the main inventory slot the client's hand
    holds (`hs`) is paid from that stack, in its quality; an `hs` on a slot that holds another item is passed over
    (a normal one pays, as without it); Z (`drop`) naming the slot takes the item from that stack."""
    def stacks():
        out = mod_lua("""local inv = storage.f3d.puppet.get_main_inventory() local at = {} for i = 1, #inv do local st = inv[i]
 if st.valid_for_read and (st.name == 'wooden-chest' or st.name == 'iron-plate') then at[#at + 1] = i .. ':' .. st.name .. ':' .. st.quality.name .. ':' .. st.count end end
 rcon.print(table.concat(at, ' '))""".replace("\n", " "))
        rows = [r.split(":") for r in out.split()]
        return {int(r[0]): (r[1], r[2], int(r[3])) for r in rows if len(r) == 4}

    made = mod_lua("""local inv = storage.f3d.puppet.get_main_inventory() inv.clear()
 inv.insert({ name = 'wooden-chest', count = 5 }) inv.insert({ name = 'iron-plate', count = 7 })
 local ok = pcall(function() inv.insert({ name = 'wooden-chest', count = 3, quality = 'rare' }) end)
 rcon.print(ok and 'rare' or 'plain')""".replace("\n", " "))
    before = stacks()
    normal = next((i for i, s in before.items() if s[0] == "wooden-chest" and s[1] == "normal"), 0)
    rare = next((i for i, s in before.items() if s[0] == "wooden-chest" and s[1] == "rare"), 0)
    plates = next((i for i, s in before.items() if s[0] == "iron-plate"), 0)
    if not normal or not plates:
        report(False, "L7: chests and plates in the character's inventory", f"{made} {before}")
        return
    fx = lambda v: math.floor(v * 256)

    def build(dy, hs):
        c.send({"t": "build", "item": "wooden-chest", "x": fx(x + 6.5), "y": fx(y + dy + 0.5), "d": 0, "hs": hs})
        c.pump(0.5, every=hello)
        return stacks()

    if rare:
        after = build(0, rare)
        report(after.get(rare, ("", "", 0))[2] == 2 and after.get(normal, ("", "", 0))[2] == 5,
               "L7: a build naming the held stack's slot (hs) is paid from that stack, in its quality (a rare stack held)",
               f"{before} -> {after}")
    after = build(2, normal)
    report(after.get(normal, ("", "", 0))[2] == 4, "L7: hs on the normal stack: that stack pays", str(after))
    after = build(4, plates)
    report(after.get(normal, ("", "", 0))[2] == 3 and after.get(plates, ("", "", 0))[2] == 7,
           "L7: an hs naming a slot that holds another item is passed over: a normal chest pays, the plates stay", str(after))
    c.send({"t": "drop", "item": "iron-plate", "x": fx(x + 5.5), "y": fx(y - 3.5), "hs": plates})
    c.pump(0.5, every=hello)
    after = stacks()
    report(after.get(plates, ("", "", 0))[2] == 6, "L7: Z naming the held stack's slot takes the plate from that stack", str(after))
    mod_lua(f"""local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({{ area = {{ {{ {x} + 4, {y} - 5 }}, {{ {x} + 8, {y} + 6 }} }},
 name = {{ 'wooden-chest', 'item-on-ground' }} }})) do e.destroy({{ raise_destroy = true }}) end rcon.print('ok')""".replace("\n", " "))


def check_circuits(c, hello):
    """Wire tools and every entity's circuit and own settings (wiring.lua, circuit_settings.lua,
    entity_ui.lua, circuits.lua): connect / disconnect / clear wires, gui.cc and set_cc, combinators
    in full (decider conditions and outputs, every selector mode, constant sections), lamps,
    speakers, pumps, turrets, display panels, inserters' spoil priority."""
    back = mod_lua("local p = storage.f3d.puppet.position rcon.print(p.x .. ' ' .. p.y)")
    if not clean_spot(c, hello):
        report(False, "circuits: no clean spot found")
        return
    mod_lua('local f = storage.f3d.puppet.force for _, t in pairs({ "electronics", "circuit-network" }) do '
            'if f.technologies[t] then f.technologies[t].researched = true end end rcon.print("ok")')
    x, y = c.me["x"] / 256, c.me["y"] / 256
    fx = lambda v: int(round(v * 256))
    specs = [("small-electric-pole", -3.5, -3.5, 0), ("small-electric-pole", 1.5, -3.5, 0), ("power-switch", 5, -3, 0),
             ("constant-combinator", -3.5, 0.5, 0), ("decider-combinator", -1.5, 1, 0), ("selector-combinator", 0.5, 1, 0),
             ("arithmetic-combinator", 2.5, 1, 0), ("fast-inserter", 4.5, 0.5, 0), ("small-lamp", 6.5, 0.5, 0),
             ("programmable-speaker", -3.5, 3.5, 0), ("pump", -1.5, 4, 0), ("display-panel", 0.5, 3.5, 0),
             ("gun-turret", 3, 4, 0), ("transport-belt", 5.5, 3.5, 0), ("assembling-machine-1", -6.5, 1.5, 0),
             ("straight-rail", -5, 7, 0), ("train-stop", -3, 7, 0)]
    lua = "local c = storage.f3d.puppet local s = c.surface local out = {} "
    for name, dx, dy, d in specs:
        lua += (f'local e = s.create_entity({{ name = "{name}", position = {{ {x + dx}, {y + dy} }}, direction = {d}, force = c.force, '
                f'raise_built = true }}) out[#out + 1] = e and (e.unit_number .. " " .. e.position.x .. " " .. e.position.y) or "0 0 0" ')
    lua += 'rcon.print(table.concat(out, " "))'
    vals = mod_lua(lua).split()
    if len(vals) != 3 * len(specs):
        report(False, "circuits: building the test entities", " ".join(vals))
        return
    ents = {}
    for i, (name, *_rest) in enumerate(specs):
        u = int(vals[3 * i])
        key = name if name not in ents else name + "#2"
        ents[key] = (u, float(vals[3 * i + 1]), float(vals[3 * i + 2]), name)
    report(all(v[0] for k, v in ents.items() if k != "straight-rail"), "circuits: test entities built",
           ", ".join(k for k, v in ents.items() if not v[0]))
    c.pump(1.0, every=hello)

    def end(key, mdx=0.0, mdy=0.0):
        u, ex, ey, name = ents[key]
        return {"u": u, "p": c.proto_id(name), "x": fx(ex), "y": fx(ey), "mx": fx(ex + mdx), "my": fx(ey + mdy)}

    def lua_on(key, code):
        """Runs code with `e` the test entity."""
        return mod_lua(f'local e for _, x in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ force = storage.f3d.puppet.force, '
                       f'position = {{ {ents[key][1]}, {ents[key][2]} }}, radius = 0.6 }})) do if x.unit_number == {ents[key][0]} then e = x end end '
                       f'local ids = defines.wire_connector_id {code}')

    def open_gui(key, cmd=None, wait=0.8):
        e = end(key)
        c.send({"t": "open", **{k: e[k] for k in ("u", "p", "x", "y")}})
        if cmd:
            c.send(dict(cmd, u=e["u"]))
        g = [m for m in c.pump(wait, every=hello) if m.get("t") == "gui" and m.get("u") == e["u"]]
        return g[-1] if g else {}

    # --- wires -----------------------------------------------------------------------------------
    c.send({"t": "wire", "k": "r", "a": end("constant-combinator"), "b": end("decider-combinator", 0, 0.5)})
    msgs = c.pump(0.6, every=hello)
    out = lua_on("decider-combinator", 'local k for _, x in pairs(e.surface.find_entities_filtered({ name = "constant-combinator", '
                 'position = e.position, radius = 3 })) do k = x end rcon.print(tostring(e.get_wire_connector(ids.combinator_input_red, true)'
                 '.is_connected_to(k.get_wire_connector(ids.circuit_red, true))))')
    upd = {m["e"][0] for m in of_type(msgs, "upd")}
    report(out == "true" and ents["decider-combinator"][0] in upd,
           "wire: red wire to a decider's input side (get_wire_connector, connect_to), both ends re-sent", f"{out}, upd {upd}")
    c.send({"t": "wire", "k": "r", "a": end("constant-combinator"), "b": end("decider-combinator", 0, 0.5)})
    c.pump(0.6, every=hello)
    out = lua_on("decider-combinator", 'rcon.print(#e.get_wire_connector(ids.combinator_input_red, true).connections)')
    report(out == "0", "wire: the same pair again disconnects (is_connected_to, disconnect_from)", out)
    c.send({"t": "wire", "k": "r", "a": end("constant-combinator"), "b": end("decider-combinator", 0, 0.5)})
    c.send({"t": "wire", "k": "g", "a": end("decider-combinator", 0, -0.5), "b": end("small-lamp")})
    c.pump(0.6, every=hello)
    out = lua_on("decider-combinator", 'rcon.print(#e.get_wire_connector(ids.combinator_output_green, true).connections .. " " .. '
                 '#e.get_wire_connector(ids.combinator_input_green, true).connections)')
    report(out == "1 0", "wire: a click on the side a combinator faces takes its output connector", out)
    c.send({"t": "wire", "k": "w", "a": end("small-electric-pole"), "b": end("small-electric-pole#2")})
    c.send({"t": "wire", "k": "w", "a": end("small-electric-pole#2"), "b": end("power-switch", -0.6, 0)})
    c.pump(0.6, every=hello)
    out = lua_on("power-switch", 'rcon.print(#e.get_wire_connector(ids.power_switch_left_copper, true).connections .. " " .. '
                 '#e.get_wire_connector(ids.power_switch_right_copper, true).connections)')
    report(out == "1 0", "wire: copper wire into a power switch's left side (power_switch_left_copper)", out)
    c.send({"t": "wire", "k": "w", "a": end("small-electric-pole"), "b": end("decider-combinator")})
    msgs = c.pump(0.5, every=hello)
    report(any("Copper wire" in m["text"] for m in of_type(msgs, "msg")), "wire: copper wire to a combinator is refused")
    e = end("small-electric-pole#2")
    c.send({"t": "wire_clear", **{k: e[k] for k in ("u", "p", "x", "y")}})
    c.pump(0.6, every=hello)
    out = lua_on("small-electric-pole#2", 'rcon.print(#e.get_wire_connector(ids.pole_copper, true).connections)')
    report(out == "0", "wire_clear removes a pole's copper cables (disconnect_all)", out)

    # --- generic circuit settings ------------------------------------------------------------------
    c.send({"t": "wire", "k": "r", "a": end("constant-combinator"), "b": end("fast-inserter")})
    g = open_gui("fast-inserter", wait=1.0)
    cc = g.get("cc") or {}
    report(cc.get("o") == "inserter" and cc.get("w") == 1 and cc.get("nets", {}).get("r", 0) > 0
           and cc.get("f", {}).get("circuit_hand_read_mode") in ("hold", "pulse"),
           "gui.cc: an inserter's circuit settings and red network id (get_control_behavior, network_id)", str(cc)[:300])
    c.send({"t": "set_cc", "u": ents["fast-inserter"][0], "f": {
        "circuit_enable_disable": 1, "circuit_condition": {"first_signal": {"type": "item", "name": "iron-plate"}, "comparator": "≥", "constant": 7},
        "circuit_read_hand_contents": 1, "circuit_hand_read_mode": "hold", "circuit_set_stack_size": 1,
        "circuit_stack_control_signal": {"type": "virtual", "name": "signal-S"}, "connect_to_logistic_network": 1,
        "logistic_condition": {"first_signal": {"type": "item", "name": "copper-plate"}, "comparator": "<", "constant": 100}}})
    c.pump(0.6, every=hello)
    out = lua_on("fast-inserter", 'local b = e.get_control_behavior() local cc = b.circuit_condition rcon.print(tostring(b.circuit_enable_disable) .. " " .. '
                 'cc.first_signal.name .. cc.comparator .. cc.constant .. " " .. tostring(b.circuit_hand_read_mode == defines.control_behavior.inserter.hand_read_mode.hold) .. " " .. '
                 'tostring(b.circuit_set_stack_size) .. " " .. b.circuit_stack_control_signal.name .. " " .. tostring(b.connect_to_logistic_network) .. " " .. '
                 'b.logistic_condition.first_signal.name)')
    report(out == "true iron-plate≥7 true true signal-S true copper-plate",
           "set_cc writes an inserter's enable condition, hand read mode, stack size signal, logistic condition", out)
    g = open_gui("fast-inserter")
    f = (g.get("cc") or {}).get("f", {})
    report(f.get("circuit_enable_disable") == 1 and f.get("circuit_hand_read_mode") == "hold"
           and f.get("circuit_condition", {}).get("comparator") == "≥" and f.get("circuit_condition", {}).get("ful") in (0, 1),
           "gui.cc reads them back (enum names, fulfilled)", str(f)[:300])
    c.send({"t": "set_inserter", "u": ents["fast-inserter"][0], "sp": "spoiled-first"})
    c.pump(0.5, every=hello)
    out = lua_on("fast-inserter", 'rcon.print(tostring(e.inserter_spoil_priority))')
    g = open_gui("fast-inserter")
    report(out == "spoiled-first" and (g.get("ins") or {}).get("sp") == "spoiled-first", "set_inserter: spoil priority (inserter_spoil_priority)", out)

    # Every kind of entity: its cc shape is valid (protocol.py) and has the fields of its type.
    # A belt opens only once it is on a circuit network, as in Factorio.
    c.send({"t": "wire", "k": "g", "a": end("small-lamp"), "b": end("transport-belt")})
    for key, o in (("transport-belt", "transport_belt"), ("assembling-machine-1", "assembling_machine"), ("small-lamp", "lamp"),
                   ("pump", "pump"), ("gun-turret", "turret"), ("power-switch", "generic_on_off"),
                   ("programmable-speaker", "programmable_speaker"), ("train-stop", "train_stop")):
        if not ents.get(key, (0,))[0]:
            continue
        g = open_gui(key, wait=0.6)
        cc = g.get("cc") or {}
        report(cc.get("o") == o and len(cc.get("f", {})) > 0, f"gui.cc on a {key}: {o}", str(cc)[:200])

    # --- lamp --------------------------------------------------------------------------------------
    open_gui("small-lamp", {"t": "set_color", "c": [255, 128, 0]}, wait=0.3)
    c.send({"t": "set_cc", "u": ents["small-lamp"][0], "f": {"use_colors": 1, "color_mode": "components",
                                                            "red_signal": {"type": "virtual", "name": "signal-R"}}})
    c.pump(0.5, every=hello)
    out = lua_on("small-lamp", 'local b = e.get_control_behavior() local k = e.color rcon.print(math.floor(k.r * 255 + 0.5) .. " " .. '
                 'math.floor(k.g * 255 + 0.5) .. " " .. tostring(b.use_colors) .. " " .. b.color_mode .. " " .. b.red_signal.name)')
    g = open_gui("small-lamp")
    report(out.startswith("255 128 true") and out.endswith("signal-R") and g.get("col") == [255, 128, 0],
           "lamp: colour (LuaEntity.color), use colours and colour mode (LuaLampControlBehavior)", f"{out}; col {g.get('col')}")
    if ents.get("train-stop", (0,))[0]:
        open_gui("train-stop", {"t": "set_color", "c": [0, 200, 50]}, wait=0.4)
        g = open_gui("train-stop")
        report(g.get("col") == [0, 200, 50], "train stop colour (LuaEntity.color)", str(g.get("col")))

    # --- programmable speaker ---------------------------------------------------------------------
    g = open_gui("programmable-speaker", {"t": "set_speaker", "vol": 0.5, "mode": "global", "poly": 1, "inst": 1, "note": 2,
                                          "pitch": 1, "al": {"show": 1, "map": 1, "icon": {"type": "virtual", "name": "signal-A"}, "msg": "Hello"}},
                 wait=1.0)
    spk = g.get("spk") or {}
    out = lua_on("programmable-speaker", 'local p, cp, a = e.parameters, e.get_control_behavior().circuit_parameters, e.alert_parameters '
                 'rcon.print(p.playback_volume .. " " .. p.playback_mode .. " " .. tostring(p.allow_polyphony) .. " " .. cp.instrument_id .. " " .. '
                 'cp.note_id .. " " .. tostring(cp.signal_value_is_pitch) .. " " .. tostring(a.show_alert) .. " " .. a.alert_message .. " " .. a.icon_signal_id.name)')
    report(out == "0.5 global true 1 2 true true Hello signal-A" and len(spk.get("il", [])) > 1,
           "speaker: volume, playback, polyphony, instrument, note, pitch, alert (parameters, circuit_parameters, alert_parameters)",
           f"{out}; {len(spk.get('il', []))} instruments")

    # --- pump, turret, display panel ---------------------------------------------------------------
    g = open_gui("pump", {"t": "set_pump", "f": "water"})
    out = lua_on("pump", 'local f = e.get_fluid_filter(1) rcon.print(f and f.name or "none")')
    g = open_gui("pump")
    report(out == "water" and g.get("pf") == "water", "pump: fluid filter (set_fluid_filter, get_fluid_filter)", f"{out}; pf {g.get('pf')}")
    open_gui("pump", {"t": "set_pump", "f": ""}, wait=0.4)
    out = lua_on("pump", 'local f = e.get_fluid_filter(1) rcon.print(f and f.name or "none")')
    report(out == "none", "pump: the filter clears", out)
    open_gui("gun-turret", {"t": "set_targets", "l": ["small-biter", "medium-biter"], "ign": 1}, wait=0.5)
    g = open_gui("gun-turret")
    out = lua_on("gun-turret", 'local l = {} for _, p in pairs(e.priority_targets) do l[#l + 1] = p.name end '
                 'rcon.print(table.concat(l, ",") .. " " .. tostring(e.ignore_unprioritised_targets))')
    report(out == "small-biter,medium-biter true" and (g.get("tgt") or {}).get("l") == ["small-biter", "medium-biter"],
           "turret: priority targets (set_priority_target, priority_targets, ignore_unprioritised_targets)", out)
    open_gui("gun-turret", {"t": "set_targets", "l": ["medium-biter"]}, wait=0.5)
    out = lua_on("gun-turret", 'local l = {} for _, p in pairs(e.priority_targets) do l[#l + 1] = p.name end rcon.print(table.concat(l, ","))')
    report(out == "medium-biter", "turret: removing targets (set_priority_target without an entity)", out)
    c.send({"t": "wire", "k": "r", "a": end("constant-combinator"), "b": end("display-panel")})
    msgs_def = [{"text": "Low", "icon": {"type": "item", "name": "iron-plate"},
                 "cond": {"first_signal": {"type": "item", "name": "iron-plate"}, "comparator": "<", "constant": 10}},
                {"text": "Plenty", "icon": {}, "cond": {"first_signal": {"type": "item", "name": "iron-plate"}, "comparator": "≥", "constant": 10}}]
    open_gui("display-panel", {"t": "set_panel", "text": "Iron", "icon": {"type": "item", "name": "iron-plate"}, "show": 1, "chart": 1,
                               "msgs": msgs_def}, wait=0.5)
    g = open_gui("display-panel")
    dp = g.get("dp") or {}
    out = lua_on("display-panel", 'local r = e.get_control_behavior().records rcon.print(#r .. " " .. r[1].text .. " " .. r[1].condition.comparator .. " " .. '
                 'tostring(e.display_panel_always_show) .. " " .. tostring(e.display_panel_show_in_chart))')
    report(out == "2 Low < true true" and len(dp.get("msgs", [])) == 2 and dp["msgs"][1]["text"] == "Plenty",
           "display panel: messages with conditions (records), always show, show in chart", f"{out}; {str(dp)[:200]}")

    # --- combinators in full -----------------------------------------------------------------------
    sections = [{"g": "", "on": 1, "m": 1, "s": [["item", "iron-plate", 12]]},
                {"g": "", "on": 0, "m": 3, "s": [["virtual", "signal-A", 5], ["item", "copper-plate", 2, "uncommon"]]}]
    open_gui("constant-combinator", {"t": "set_cb", "cb": {"enabled": True, "sections": sections}}, wait=0.5)
    g = open_gui("constant-combinator")
    out = lua_on("constant-combinator", 'local b = e.get_control_behavior() local s2 = b.get_section(2) '
                 'rcon.print(b.sections_count .. " " .. tostring(s2.active) .. " " .. s2.multiplier .. " " .. s2.filters[2].value.quality)')
    report(out == "2 false 3 uncommon" and (g.get("cb") or {}).get("sections") == sections,
           "constant combinator: sections (add_section, active, multiplier, quality)", f"{out}; {str((g.get('cb') or {}).get('sections'))[:200]}")
    open_gui("constant-combinator", {"t": "set_cb", "cb": {"enabled": True, "sections": sections[:1]}}, wait=0.4)
    out = lua_on("constant-combinator", 'rcon.print(e.get_control_behavior().sections_count)')
    report(out == "1", "constant combinator: remove_section", out)
    decider = {"conditions": [
        {"first_signal": {"type": "item", "name": "iron-plate"}, "comparator": ">", "constant": 5, "first_signal_networks": {"red": True, "green": False}},
        {"first_signal": {"type": "virtual", "name": "signal-A"}, "comparator": "=", "second_signal": {"type": "virtual", "name": "signal-B"},
         "compare_type": "and"},
        {"first_signal": {"type": "virtual", "name": "signal-everything"}, "comparator": "<", "constant": 100, "compare_type": "or"}],
        "outputs": [{"signal": {"type": "virtual", "name": "signal-C"}, "copy_count_from_input": False, "constant": 3},
                    {"signal": {"type": "item", "name": "iron-plate"}, "copy_count_from_input": True, "networks": {"red": False, "green": True}}]}
    open_gui("decider-combinator", {"t": "set_cb", "cb": decider}, wait=0.5)
    g = open_gui("decider-combinator", wait=1.0)
    cb = g.get("cb") or {}
    conds = cb.get("conditions", [])
    report(len(conds) == 3 and conds[1].get("compare_type") == "and" and conds[0].get("first_signal_networks", {}).get("green") is False
           and len(cb.get("outputs", [])) == 2 and cb["outputs"][1].get("networks", {}).get("red") is False,
           "decider: three conditions with and/or, networks, two outputs (parameters)", str(cb)[:300])
    sig = g.get("sig") or {}
    report(["item", "iron-plate", 12] in sig.get("r", []) and sig.get("ri", 0) > 0 and isinstance(sig.get("out"), dict),
           "decider: its input signals with the network id, and its output side (sig.out)", str(sig)[:300])
    modes = {"select": {"select_max": False, "index_constant": 2, "index_comparator": ">"},
             "count": {"count_signal": {"type": "virtual", "name": "signal-C"}},
             "random": {"random_update_interval": 30},
             "stack-size": {}, "rocket-capacity": {},
             "quality-filter": {"quality_filter": {"quality": "rare", "comparator": "≥"}},
             "quality-transfer": {"quality_source_static": {"name": "uncommon"},
                                  "quality_destination_signal": {"type": "virtual", "name": "signal-each"}},
             "time": {"game_tick_signal": {"type": "virtual", "name": "signal-T"}},
             "quality-select": {"select_highest_quality": False}}
    bad = []
    for op, extra in modes.items():
        open_gui("selector-combinator", {"t": "set_cb", "cb": {"operation": op, **extra}}, wait=0.3)
        g = open_gui("selector-combinator", wait=0.6)
        cb = g.get("cb") or {}
        if cb.get("operation") != op or any(cb.get(k) != v and not (isinstance(v, dict) and isinstance(cb.get(k), dict)
                                                                   and all(cb[k].get(kk) == vv for kk, vv in v.items()))
                                            for k, v in extra.items()):
            bad.append(f"{op}: {cb}")
    report(not bad, "selector: every mode and its settings round-trip (parameters)", "; ".join(bad)[:400])
    arith = {"first_signal": {"type": "virtual", "name": "signal-each"}, "first_signal_networks": {"red": True, "green": False},
             "operation": ">>", "second_constant": 2, "output_signal": {"type": "virtual", "name": "signal-each"}}
    open_gui("arithmetic-combinator", {"t": "set_cb", "cb": arith}, wait=0.4)
    g = open_gui("arithmetic-combinator")
    cb = g.get("cb") or {}
    report(cb.get("operation") == ">>" and cb.get("first_signal_networks", {}).get("green") is False,
           "arithmetic: each, >>, network selection", str(cb)[:200])
    c.send({"t": "close"})
    destroy_units([v[0] for v in ents.values()])
    # Back where the character was, so the checks after this one see the same place as before.
    if len(back.split()) == 2:
        bx, by = (float(v) for v in back.split())
        mod_lua(f"storage.f3d.puppet.teleport({{ {bx}, {by} }})")
        watch_around(c, hello, bx, by)


def check_logic(c, hello):
    """The logic, train and vehicle windows' data (entity_ui.lua, trains.lua, screens.lua): a lamp's
    Always on (set_lamp), a combinator's description (set_desc), an inserter's hand and a burner's
    fuel bar (ins.h, bu), a rail signal opening, a train stop's trains (stop.trs), a locomotive's
    name and colour, a cargo wagon's limit bar, a car's guns."""
    back = mod_lua("local p = storage.f3d.puppet.position rcon.print(p.x .. ' ' .. p.y)")
    if not clean_spot(c, hello):
        report(False, "logic: no clean spot found")
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    fx = lambda v: int(round(v * 256))
    # Entities with unit numbers, then rails (east-west) with a train and a stop on them.
    specs = [("small-lamp", -3.5, -3.5, 0), ("constant-combinator", -1.5, -3.5, 0), ("burner-inserter", 0.5, -3.5, 0),
             ("wooden-chest", 0.5, -4.5, 0), ("car", 4, -3, 0)]
    rails = [(-9 + 2 * i, 3) for i in range(10)]
    trainy = [("locomotive", -5, 3, 4), ("cargo-wagon", 2, 3, 4), ("train-stop", 1, 5, 4), ("rail-signal", -8.5, 4.5, 4)]
    lua = "local c = storage.f3d.puppet local s = c.surface local out = {} "
    for dx, dy in rails:
        lua += (f's.create_entity({{ name = "straight-rail", position = {{ {x + dx}, {y + dy} }}, direction = 4, force = c.force, '
                f'raise_built = true }}) ')
    for name, dx, dy, d in specs + trainy:
        lua += (f'local e = s.create_entity({{ name = "{name}", position = {{ {x + dx}, {y + dy} }}, direction = {d}, force = c.force, '
                f'raise_built = true }}) out[#out + 1] = e and (e.unit_number .. " " .. e.position.x .. " " .. e.position.y) or "0 0 0" ')
    lua += 'rcon.print(table.concat(out, " "))'
    vals = mod_lua(lua).split()
    ents = {}
    for i, (name, *_r) in enumerate(specs + trainy):
        if 3 * i + 2 < len(vals):
            ents[name] = (int(float(vals[3 * i])), float(vals[3 * i + 1]), float(vals[3 * i + 2]))
    report(len(ents) == 9 and all(v[0] for v in ents.values()), "logic: test entities built", str(ents)[:300])
    if len(ents) < 9:
        return
    c.pump(1.0, every=hello)

    def open_gui(name, cmd=None, wait=0.8):
        u, ex, ey = ents[name]
        c.send({"t": "open", "u": u, "p": c.proto_id(name), "x": fx(ex), "y": fx(ey)})
        if cmd:
            c.send(dict(cmd, u=u))
        g = [m for m in c.pump(wait, every=hello) if m.get("t") == "gui" and m.get("u") == u]
        return g[-1] if g else {}

    def lua_on(name, code):
        return mod_lua(f'local e for _, x in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = "{name}", '
                       f'position = {{ {ents[name][1]}, {ents[name][2]} }}, radius = 0.6 }})) do e = x end {code}')

    g = open_gui("small-lamp")
    report(g.get("ao") == 0, "lamp: ao (always_on) is sent", str(g)[:200])
    open_gui("small-lamp", {"t": "set_lamp", "ao": 1})
    g = open_gui("small-lamp")
    out = lua_on("small-lamp", "rcon.print(tostring(e.always_on))")
    report(out == "true" and g.get("ao") == 1, "set_lamp: Always on (LuaEntity.always_on)", out)
    open_gui("constant-combinator", {"t": "set_desc", "text": "Outpost mats"})
    g = open_gui("constant-combinator")
    out = lua_on("constant-combinator", "rcon.print(e.combinator_description)")
    report(out == "Outpost mats" and g.get("desc") == "Outpost mats", "set_desc: a combinator's description (combinator_description)", out)
    # A burner inserter with coal: its fuel bar while it burns, its hand while it carries.
    lua_on("burner-inserter", 'e.insert({ name = "coal", count = 5 }) rcon.print("ok")')
    lua_on("wooden-chest", 'e.insert({ name = "iron-plate", count = 50 }) rcon.print("ok")')
    c.pump(2.0, every=hello)
    seen_h, seen_bu = None, None
    for _ in range(12):
        g = open_gui("burner-inserter", wait=0.5)
        ins = g.get("ins") or {}
        if ins.get("h"):
            seen_h = ins["h"]
        if isinstance(g.get("bu"), int) and g["bu"] > 0:
            seen_bu = g["bu"]
        if seen_h and seen_bu:
            break
    report(seen_bu is not None, "burner inserter: bu (burner.remaining_burning_fuel / fuel_value)", str(seen_bu))
    report(seen_h is not None and seen_h[0] == "iron-plate", "inserter: ins.h (held_stack) while it carries", str(seen_h))
    g = open_gui("rail-signal")
    report(g.get("kind") == "other" and "status" in g, "rail signal: opens with its status", str(g)[:200])
    out = lua_on("locomotive", 'local stop for _, x in pairs(e.surface.find_entities_filtered({ name = "train-stop", position = e.position, radius = 12 })) do stop = x end '
                 'e.insert({ name = "coal", count = 10 }) e.color = { r = 1, g = 0.5, b = 0 } '
                 'e.train.schedule = { current = 1, records = { { station = stop.backer_name, wait_conditions = { { type = "time", ticks = 600 } } } } } '
                 'rcon.print(stop.backer_name .. "|" .. e.train.id)')
    g = open_gui("locomotive")
    tr = g.get("tr") or {}
    report(isinstance(tr.get("name"), str) and tr["name"] != "" and g.get("col") == [255, 128, 0],
           "locomotive: tr.name (backer_name) and col (LuaEntity.color)", f"{out}; {tr.get('name')} {g.get('col')}")
    open_gui("locomotive", {"t": "set_color", "c": [0, 100, 200]})
    out2 = lua_on("locomotive", 'rcon.print(math.floor(e.color.b * 255 + 0.5))')
    report(out2 == "200", "set_color on a locomotive", out2)
    # D10: from the remote view (rv) a building far away opens where a working radar covers it
    # (the mod works the coverage out: a headless server reveals nothing), for settings only.
    rx, ry = x + 320, y
    made = mod_lua(f'local c = storage.f3d.puppet local s = c.surface local f = c.force '
                   f's.request_to_generate_chunks({{ {rx}, {ry} }}, 4) s.force_generate_chunk_requests() '
                   f'for _, e in pairs(s.find_entities_filtered({{ area = {{ {{ {rx - 12}, {ry - 12} }}, {{ {rx + 12}, {ry + 12} }} }} }})) do if e.type ~= "character" then e.destroy() end end '
                   f'for _, e in pairs(s.find_entities_filtered({{ area = {{ {{ {rx + 280}, {ry - 8} }}, {{ {rx + 300}, {ry + 8} }} }} }})) do if e.type ~= "character" then e.destroy() end end '
                   f'local r = s.create_entity({{ name = "radar", position = {{ {rx}, {ry} }}, force = f, raise_built = true }}) '
                   f's.create_entity({{ name = "electric-energy-interface", position = {{ {rx + 4}, {ry} }}, force = f }}) '
                   f's.create_entity({{ name = "small-electric-pole", position = {{ {rx + 2.5}, {ry + 2.5} }}, force = f }}) '
                   f'local a = s.create_entity({{ name = "assembling-machine-2", position = {{ {rx + 1.5}, {ry + 7.5} }}, force = f }}) '
                   f'local b = s.create_entity({{ name = "assembling-machine-2", position = {{ {rx + 290.5}, {ry + 0.5} }}, force = f }}) '
                   f'rcon.print(a.unit_number .. " " .. b.unit_number .. " " .. r.unit_number)').split()
    c.pump(1.5, every=hello)
    if len(made) == 3:
        ua, ub, ur = map(int, made)
        c.send({"t": "open", "u": ua, "p": c.proto_id("assembling-machine-2"), "x": fx(rx + 1.5), "y": fx(ry + 7.5), "rv": 1})
        c.send({"t": "set_recipe", "u": ua, "recipe": "iron-gear-wheel"})
        msgs = c.pump(1.0, every=hello)
        g = [m for m in msgs if m.get("t") == "gui" and m.get("u") == ua]
        report(bool(g) and g[-1].get("recipe") == "iron-gear-wheel",
               "rv: a building 320 tiles away opens beside a working radar, and takes a recipe", f"{g[-1:]} {[m['text'] for m in msgs if m.get('t') == 'msg']}")
        c.send({"t": "open", "u": ub, "p": c.proto_id("assembling-machine-2"), "x": fx(rx + 290.5), "y": fx(ry + 0.5), "rv": 1})
        msgs = c.pump(1.0, every=hello)
        report(not [m for m in msgs if m.get("t") == "gui" and m.get("u") == ub] and any("roboport coverage" in m.get("text", "") for m in msgs if m.get("t") == "msg"),
               "rv: one no radar covers doesn't open", str([m.get("text") for m in msgs if m.get("t") == "msg"]))
        c.pump(0.5, every=hello)
        c.send({"t": "mtr"})
        mt = [m for m in c.pump(1.0, every=hello) if m.get("t") == "mtr"]
        cov = mt[0].get("cov") if mt else None
        rc = [int(rx // 32), int(ry // 32)]
        report(isinstance(cov, list) and any(cov[i:i + 2] == rc and cov[i + 2] >= 2 for i in range(0, len(cov), 3)),
               "mtr cov: the working radar's chunk and its nearby reveal distance (D12)", f"{cov} radar chunk {rc}")
        c.send({"t": "close"})
        destroy_units([ua, ub, ur])
    else:
        report(False, "rv: test buildings made", str(made))
    # D11: the map's trains (mtr): every carriage with its place, turn, size and map colour.
    c.pump(0.5, every=hello)
    c.send({"t": "mtr"})
    mtr = [m for m in c.pump(1.0, every=hello) if m.get("t") == "mtr"]
    cars = [mtr[-1]["l"][i:i + 6] for i in range(0, len(mtr[-1]["l"]), 6)] if mtr else []
    near = lambda name: next((r for r in cars if abs(r[0] - fx(ents[name][1])) < 128 and abs(r[1] - fx(ents[name][2])) < 128), None)
    loco, wagon = near("locomotive"), near("cargo-wagon")
    report(loco is not None and wagon is not None and loco[5] == 0x0064C8 and loco[3] > loco[4] > 0 and loco[2] in (250, 750),
           "mtr: the map's trains, each carriage's place, turn, size and colour", f"{len(cars)} cars; locomotive {loco}, wagon {wagon}")
    g = open_gui("train-stop", wait=1.0)
    trs = (g.get("stop") or {}).get("trs")
    report(isinstance(trs, list) and any(t[3] == ents["locomotive"][0] or t[3] == ents["cargo-wagon"][0] for t in trs),
           "train stop: trs, the trains with it in their schedule (get_train_stop_trains)", f"{out}: {trs}")
    g = open_gui("cargo-wagon")
    report(isinstance(g.get("bar"), int) and g["bar"] > 0, "cargo wagon: bar (its inventory's limit)", str(g.get("bar")))
    open_gui("cargo-wagon", {"t": "set_bar", "n": 5})
    g = open_gui("cargo-wagon")
    out = lua_on("cargo-wagon", 'rcon.print(e.get_inventory(defines.inventory.cargo_wagon).get_bar() - 1)')
    report(out == "5" and g.get("bar") == 5, "set_bar on a cargo wagon", out)
    g = open_gui("car")
    report(g.get("guns") == ["vehicle-machine-gun"], "car: guns (prototype.indexed_guns)", str(g.get("guns")))
    if any(n == "lightning-rod" for n, _ in c.protos.values()):
        out = mod_lua(f'local e = storage.f3d.puppet.surface.create_entity({{ name = "lightning-rod", position = {{ {x + 6.5}, {y - 6.5} }}, '
                      f'force = storage.f3d.puppet.force }}) rcon.print(e.unit_number .. " " .. e.position.x .. " " .. e.position.y)').split()
        if len(out) == 3:
            ents["lightning-rod"] = (int(out[0]), float(out[1]), float(out[2]))
            g = open_gui("lightning-rod")
            report(not g, "a lightning rod opens no window (entity_ui.lua NO_WINDOW, as 2.1.23)", str(g)[:200])
    c.send({"t": "close"})
    destroy_units([v[0] for v in ents.values()])
    mod_lua(f'for _, r in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = "straight-rail", '
            f'area = {{ {{ {x - 11}, {y + 1} }}, {{ {x + 13}, {y + 5} }} }} }})) do r.destroy() end rcon.print("ok")')
    if len(back.split()) == 2:
        bx, by = (float(v) for v in back.split())
        mod_lua(f"storage.f3d.puppet.teleport({{ {bx}, {by} }})")
        watch_around(c, hello, bx, by)


def check_vehicles(c, hello):
    """ui-logic2's windows (entity_ui.lua, spiders.lua, trains.lua): a tank's guns and grid, a
    spidertron's name, colour and auto targeting (veh, set_vehicle), the remote (spider_go, spd),
    artillery's auto targeting (art, set_artillery), a storage tank's pipeline and flush (pl,
    flush), train groups (set_train_group, gc, groups), and that a steam engine opens nothing."""
    back = mod_lua("local p = storage.f3d.puppet.position rcon.print(p.x .. ' ' .. p.y)")
    if not clean_spot(c, hello):
        report(False, "vehicles: no clean spot found")
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    fx = lambda v: int(round(v * 256))
    specs = [("tank", 4, -4), ("spidertron", -4, -4), ("artillery-turret", 5.5, 3.5), ("storage-tank", -4.5, 3.5),
             ("steam-engine", 0.5, -8.5)]
    lua = "local c = storage.f3d.puppet local s = c.surface local out = {} "
    for name, dx, dy in specs:
        lua += (f'local e = s.create_entity({{ name = "{name}", position = {{ {x + dx}, {y + dy} }}, force = c.force, raise_built = true }}) '
                f'out[#out + 1] = e and (e.unit_number .. " " .. e.position.x .. " " .. e.position.y) or "0 0 0" ')
    lua += 'rcon.print(table.concat(out, " "))'
    vals = mod_lua(lua).split()
    ents = {}
    for i, (name, *_r) in enumerate(specs):
        if 3 * i + 2 < len(vals) and int(float(vals[3 * i])):
            ents[name] = (int(float(vals[3 * i])), float(vals[3 * i + 1]), float(vals[3 * i + 2]))
    report(len(ents) == len(specs), "vehicles: test entities built", str(ents)[:300])
    if len(ents) < len(specs):
        return
    c.pump(1.0, every=hello)

    def open_gui(name, cmd=None, wait=0.8):
        u, ex, ey = ents[name]
        c.send({"t": "open", "u": u, "p": c.proto_id(name), "x": fx(ex), "y": fx(ey)})
        if cmd:
            c.send(dict(cmd, u=u))
        g = [m for m in c.pump(wait, every=hello) if m.get("t") == "gui" and m.get("u") == u]
        return g[-1] if g else {}

    def lua_on(name, code):
        return mod_lua(f'local e for _, x in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = "{name}", '
                       f'position = {{ {ents[name][1]}, {ents[name][2]} }}, radius = 0.6 }})) do e = x end {code}')

    g = open_gui("tank")
    report(g.get("kind") == "vehicle" and len(g.get("guns") or []) == 3 and (g.get("veh") or {}).get("grid") == 1,
           "tank: three guns (indexed_guns) and an equipment grid (veh.grid)", f"{g.get('guns')} {g.get('veh')}")
    g = open_gui("spidertron")
    veh = g.get("veh") or {}
    report(len(g.get("guns") or []) == 4 and isinstance(veh.get("at"), list) and isinstance(g.get("col"), list),
           "spidertron: four guns, auto targeting (vehicle_automatic_targeting_parameters) and colour",
           f"{g.get('guns')} {veh} {g.get('col')}")
    open_gui("spidertron", {"t": "set_vehicle", "lbl": "Live spider", "wi": 1, "wo": 0})
    open_gui("spidertron", {"t": "set_color", "c": [0, 0, 255]})
    g = open_gui("spidertron")
    out = lua_on("spidertron", 'local p = e.vehicle_automatic_targeting_parameters rcon.print(e.entity_label .. "|" .. '
                 'tostring(p.auto_target_with_gunner) .. "|" .. tostring(p.auto_target_without_gunner) .. "|" .. '
                 'math.floor(e.color.b * 255 + 0.5))')
    report(out == "Live spider|true|false|255" and (g.get("veh") or {}).get("lbl") == "Live spider",
           "set_vehicle names the spidertron and sets its targeting; set_color colours it", out)
    c.send({"t": "close"})
    su = ents["spidertron"][0]
    c.send({"t": "spider_go", "l": [su], "x": fx(x - 4), "y": fx(y - 12)})
    c.send({"t": "spider_go", "l": [su], "x": fx(x + 6), "y": fx(y - 12), "q": 1})
    spd = [m for m in c.pump(1.0, every=hello) if m.get("t") == "spd"]
    report(spd and len(spd[-1]["l"]) == 1 and len(spd[-1]["l"][0][1]) >= 1,
           "spider_go: autopilot destinations, Shift queues (spd)", str(spd[-1:])[:200])
    c.pump(4.0, every=hello)
    moved = mod_lua(f"local e = game.get_entity_by_unit_number({su}) rcon.print(math.floor(e.position.y - {ents['spidertron'][2]}))")
    report(moved.lstrip("-").isdigit() and int(moved) < -2, "and the spidertron walks there (get_entity_by_unit_number)", moved)
    g = open_gui("artillery-turret")
    report(g.get("art") == 1, "artillery turret: art (artillery_auto_targeting)", str(g.get("art")))
    open_gui("artillery-turret", {"t": "set_artillery", "on": 0})
    out = lua_on("artillery-turret", "rcon.print(tostring(e.artillery_auto_targeting))")
    report(out == "false", "set_artillery turns it off", out)
    lua_on("storage-tank", 'e.insert_fluid({ name = "water", amount = 5000 }) rcon.print("ok")')
    c.pump(0.5, every=hello)
    g = open_gui("storage-tank")
    pl = g.get("pl")
    report(isinstance(pl, list) and pl[0] == "water" and pl[1] > 0 and pl[2] >= 25000,
           "storage tank: pl, its pipeline (get_fluid_segment_fluid / capacity)", str(pl))
    open_gui("storage-tank", {"t": "flush", "pipe": 1})
    out = lua_on("storage-tank", 'local f = e.get_fluid_segment_fluid(1) rcon.print(f and f.amount or 0)')
    report(out in ("0", "0.0"), "flush with pipe 1 empties the pipeline (clear_fluid_segment_fluid)", out)
    g = open_gui("steam-engine")
    report(not g, "a steam engine opens no window, as in 2.1.23 (rules_openable)", str(g)[:150])
    # Train groups: a locomotive on rails, into a group and out.
    rails = " ".join(f's.create_entity({{ name = "straight-rail", position = {{ {x - 9 + 2 * i}, {y + 9} }}, direction = 4, force = c.force }})'
                     for i in range(8))
    out = mod_lua(f'local c = storage.f3d.puppet local s = c.surface {rails} '
                  f'local e = s.create_entity({{ name = "locomotive", position = {{ {x - 2}, {y + 9} }}, direction = 4, force = c.force, '
                  'raise_built = true }) rcon.print(e and (e.unit_number .. " " .. e.position.x .. " " .. e.position.y) or "0 0 0")').split()
    if len(out) == 3 and int(float(out[0])):
        ents["locomotive"] = (int(float(out[0])), float(out[1]), float(out[2]))
        open_gui("locomotive", {"t": "set_train_group", "g": "Live group"})
        g = open_gui("locomotive")
        tr = g.get("tr") or {}
        lg = lua_on("locomotive", "rcon.print(e.train.group)")
        report(lg == "Live group" and tr.get("gc") == 1 and ["Live group", 1] in tr.get("groups", []),
               "set_train_group: the train joins the group (LuaTrain.group); gc and groups", f"{lg} {tr.get('gc')} {tr.get('groups')}")
        open_gui("locomotive", {"t": "set_train_group", "g": ""})
        lg = lua_on("locomotive", "rcon.print(e.train.group or '')")
        report(lg == "", "and an empty name leaves it", lg)
    else:
        report(False, "vehicles: locomotive built", str(out))
    c.send({"t": "close"})
    destroy_units([v[0] for v in ents.values()])
    mod_lua(f'for _, r in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ area = {{ {{ {x - 14}, {y - 16} }}, '
            f'{{ {x + 14}, {y + 11} }} }}, name = {{ "straight-rail", "pipe", "spidertron", "locomotive" }} }})) do r.destroy() end rcon.print("ok")')
    if len(back.split()) == 2:
        bx, by = (float(v) for v in back.split())
        mod_lua(f"storage.f3d.puppet.teleport({{ {bx}, {by} }})")
        watch_around(c, hello, bx, by)


def check_mine_vehicles(c, hello):
    """Issue #10: right-click mining picks the vehicle under the mouse and sends its unit number.
    Every kind of rolling stock on a rail, and a car, a tank and a spidertron, mined by hand with
    things inside (fuel, cargo) as Factorio does: the vehicle and its contents go to the inventory,
    the rail under a wagon stays. And from the remote view `decon` with `u` marks only the wagon."""
    if not clean_spot(c, hello):
        report(False, "mine vehicles: no clean spot found", SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    rails = " ".join(f's.create_entity({{ name = "straight-rail", position = {{ {x - 21 + 2 * i}, {y + 4} }}, direction = 4, force = c.force }})'
                     for i in range(22))
    specs = [("locomotive", x - 14, y + 4, "coal", 5), ("cargo-wagon", x - 6, y + 4, "iron-plate", 20),
             ("fluid-wagon", x + 2, y + 4, None, 0), ("artillery-wagon", x + 10, y + 4, None, 0),
             ("car", x - 6, y - 6, "coal", 3), ("tank", x + 2, y - 6, "coal", 3), ("spidertron", x + 10, y - 6, None, 0)]
    lua = f"local c = storage.f3d.puppet local s = c.surface {rails} local out = {{}} "
    for name, ex, ey, item, n in specs:
        lua += (f'local e = s.create_entity({{ name = "{name}", position = {{ {ex}, {ey} }}, direction = 4, force = c.force, raise_built = true }}) '
                + (f'if e then e.insert({{ name = "{item}", count = {n} }}) end ' if item else "")
                + 'out[#out + 1] = e and (e.unit_number .. " " .. e.position.x .. " " .. e.position.y) or "0 0 0" ')
    lua += 'rcon.print(table.concat(out, " "))'
    vals = mod_lua(lua).split()
    ents = {}
    for i, (name, *_r) in enumerate(specs):
        if 3 * i + 2 < len(vals) and int(float(vals[3 * i])):
            ents[name] = (int(float(vals[3 * i])), float(vals[3 * i + 1]), float(vals[3 * i + 2]))
    report(len(ents) == len(specs), "mine vehicles: test vehicles built", str(ents)[:300])
    c.pump(1.0, every=hello)
    for name, ex, ey, item, n in specs:
        if name not in ents:
            continue
        u, px, py = ents[name]
        mod_lua(f"storage.f3d.puppet.teleport({{ {px}, {py - 3} }})")
        c.pump(0.5, every=hello)
        before = dict(c.inv)
        cmd = {"t": "mine", "u": u, "p": c.proto_id(name), "x": int(round(px * 256)), "y": int(round(py * 256))}
        msgs = c.pump(6.0, every=(0.2, cmd), until=lambda m: m.get("t") == "msg")
        c.send({"t": "mine_stop"})
        msgs += c.pump(1.0, every=hello)
        gone = mod_lua(f"local e = game.get_entity_by_unit_number({u}) rcon.print(e and e.valid and 'there' or 'gone')")
        texts = [m["text"] for m in of_type(msgs, "msg")]
        got = c.inv.get(name, 0) - before.get(name, 0)
        report(gone == "gone" and got == 1, f"#10: mining a {name} by its unit number takes it to the inventory",
               f"{gone}, +{got}, messages {texts}")
        if item:
            more = c.inv.get(item, 0) - before.get(item, 0)
            report(more == n, f"#10: and the {n} {item} inside it come too", f"+{more}")
    on_rail = mod_lua(f"rcon.print(storage.f3d.puppet.surface.count_entities_filtered({{ name = 'straight-rail', "
                      f"area = {{ {{ {x - 22}, {y + 3} }}, {{ {x + 22}, {y + 5} }} }} }}))")
    report(on_rail == "22", "#10: the rails under the mined wagons stay", on_rail)
    # Remote view: decon with u marks only the wagon, not the rail under it.
    out = mod_lua(f'local c = storage.f3d.puppet local e = c.surface.create_entity({{ name = "cargo-wagon", position = {{ {x - 6}, {y + 4} }}, '
                  f'direction = 4, force = c.force, raise_built = true }}) rcon.print(e and (e.unit_number .. " " .. e.position.x .. " " .. e.position.y) or "0 0 0")').split()
    if len(out) == 3 and int(float(out[0])):
        u, wx, wy = int(float(out[0])), float(out[1]), float(out[2])
        c.send({"t": "decon", "i": 0, "x1": int((wx - 0.1) * 256), "y1": int((wy - 0.1) * 256), "x2": int((wx + 0.1) * 256),
                "y2": int((wy + 0.1) * 256), "u": u, "p": c.proto_id("cargo-wagon")})
        c.pump(1.0, every=hello)
        marks = mod_lua(f"local s = storage.f3d.puppet.surface local w = game.get_entity_by_unit_number({u}) local n = 0 "
                        f"for _, r in pairs(s.find_entities_filtered({{ name = 'straight-rail', position = {{ {wx}, {wy} }}, radius = 3 }})) do "
                        "if r.to_be_deconstructed() then n = n + 1 end end "
                        "rcon.print(tostring(w and w.to_be_deconstructed()) .. ' ' .. n)")
        report(marks == "true 0", "#10: decon with u marks only the wagon (remote view), not the rail under it", marks)
        destroy_units([u])
    mod_lua(f'for _, r in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ area = {{ {{ {x - 23}, {y - 10} }}, '
            f'{{ {x + 23}, {y + 6} }} }}, name = {{ "straight-rail", "locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon", '
            '"car", "tank", "spidertron" } })) do r.destroy() end rcon.print("ok")')


def check_mod_graphics(c, hello, welcome):
    """Mods' graphics (docs/MOD-GRAPHICS-PLAN.md): the data stage's list in a mod-data prototype
    (prototypes.mod_data, LuaModData.get), named in the welcome with the game's mods, sent in
    parts on `gfx`. Run with the fixture mod tools/mod_tests/fixtures/zenith-gfx-test in the
    server's mods to check its own entries; without it only the base game's are checked."""
    mods = welcome.get("mods", {})
    report(isinstance(mods, dict) and mods.get("base") and mods.get("factorio-3d-bridge"),
           "modgfx: the welcome lists the game's mods (script.active_mods)", str(mods)[:200])
    fp, n = welcome.get("gf"), welcome.get("gn")
    report(isinstance(fp, str) and isinstance(n, int) and n > 0, "modgfx: the welcome names the graphics list", f"gf={fp} gn={n}")
    if not fp:
        return
    out = mod_lua('local p = prototypes.mod_data["zenith-graphics"] rcon.print(p.data_type .. " " .. p.get("n") .. " " .. p.get("b") .. " " .. p.get("fp"))')
    report(out.split()[1:2] == [str(n)] and out.split()[3:4] == [fp] and out.startswith("zenith-graphics "),
           "modgfx: prototypes.mod_data has the list, read with LuaModData.get", out)
    t0 = time.time()
    c.send({"t": "gfx", "fp": fp})
    got = {}
    msgs = c.pump(20, every=hello, until=lambda m: m.get("t") == "gfx" and (got.__setitem__(m["part"], m) or len(got) == n))
    took = time.time() - t0
    report(len(got) == n, "modgfx: every part arrives", f"{len(got)}/{n} parts in {took:.2f} s")
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
    report(icons.get("item", {}).get("iron-plate") == [["__base__/graphics/icons/iron-plate.png", 64, None, None, None]],
           "modgfx: the iron plate's icon", str(icons.get("item", {}).get("iron-plate")))
    report(tiles.get("grass-1", {}).get("main") and tiles.get("water", {}).get("water") == 1,
           "modgfx: grass's variants and water's mask", str(tiles.get("water"))[:200])
    report(len(decor) > 20, "modgfx: decoratives", str(len(decor)))
    c.send({"t": "gfx", "fp": fp, "need": [n]})
    again = [m["part"] for m in of_type(c.pump(2.0, every=hello), "gfx")]
    report(again == [n], "modgfx: a part asked for again", str(again))
    c.send({"t": "gfx", "fp": "0000000000000000"})
    report(not of_type(c.pump(1.5, every=hello), "gfx"), "modgfx: nothing for another fingerprint")
    if "zenith-gfx-test" not in mods:
        print("  (the fixture mod isn't on this server: its own entries not checked)")
        return
    t = "__zenith-gfx-test__/graphics/"
    report(icons.get("item", {}).get("zenith-test-gizmo") == [[t + "icons/gizmo.png", 64, None, None, None]],
           "modgfx: the fixture's item icon", str(icons.get("item", {}).get("zenith-test-gizmo")))
    tinted = icons.get("item", {}).get("zenith-test-tinted") or []
    report(len(tinted) == 2 and tinted[1][2] == [0, 1, 0, 1], "modgfx: its tinted layer, 0-255 read as 0-1", str(tinted))
    report(tiles.get("zenith-test-floor", {}).get("mat") == [t + "terrain/floor.png", 4, 0.5]
           and tiles["zenith-test-floor"].get("layer") == 60, "modgfx: the fixture's tile", str(tiles.get("zenith-test-floor")))
    report(ents.get("zenith-test-crate") == {"n": [[t + "entity/crate.png", 0, 0, 128, 160, 0.5, 0, -0.25, None]]},
           "modgfx: the fixture chest's picture at rest, its shadow layer left out", str(ents.get("zenith-test-crate")))
    spin = ents.get("zenith-test-spinner", {})
    report(spin.get("n") == [[t + "entity/spinner.png", 0, 0, 128, 128, 0.5, 0, 0, None, {"f": 4, "l": 4, "s": 0.25, "x": 0, "y": 0}]]
           and (spin.get("kn") or [[None] * 10])[0][0] == t + "entity/spinner-lamp.png" and spin["kn"][0][9].get("f") == 2,
           "modgfx: an animated machine's frames and what it shows while working", str(spin)[:300])
    peb = decor.get("zenith-test-pebbles", {})
    report(len(peb.get("pics", [])) == 4 and peb["pics"][3][1] == 192, "modgfx: the fixture's decorative, 4 variations",
           str(peb)[:200])


def check_alt(c, hello, keep=False):
    """Issue #9: Alt-mode's icons ride on the entity records with no cap (a 24 x 24 smelting array,
    576 furnaces, past the old 400), a furnace's icon follows the ore put in (aiu, no event), a recipe
    set from the open screen comes in aiu at once, and machines' recipes' fluids (extra.fa, aiu fa)
    and a recycler's output vector (eprops vp) for the arrows. `keep` leaves the test base standing
    (for screenshots)."""
    if not clean_spot(c, hello, half=30):
        report(False, "alt: no clean spot found", SPOT_WHY)
        return
    x0, y0 = int(c.me["x"] / 256), int(c.me["y"] / 256)
    out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local n = 0
c.force.enable_all_recipes()
for i = 0, 23 do for j = 0, 23 do
  local e = s.create_entity({{ name = "steel-furnace", position = {{ {x0} - 24 + i * 2 + 1, {y0} - 28 + j * 2 + 1 }}, force = c.force, raise_built = true }})
  if e then e.insert({{ name = "iron-ore", count = 20 }}) e.insert({{ name = "coal", count = 5 }}) n = n + 1 end
end end
rcon.print(n)""".replace("\n", " "))
    report(out == "576", "alt: a 24 x 24 smelting array built", out)
    hello_now = hello[1]
    # The chunks round the array, sent again (snapshots) with their records.
    cx0, cy0 = (x0 - 24) // 32, (y0 - 28) // 32
    wanted = [[cx, cy] for cy in range(cy0 - 1, cy0 + 3) for cx in range(cx0 - 1, cx0 + 3)]
    c.send({"t": "sub", "c": wanted})
    c.send({"t": "resync", "full": 0, "c": wanted})
    msgs = c.pump(15.0, every=(1.0, hello_now))
    icons = {}
    for m in msgs:
        if m.get("t") in ("ents", "add", "upd"):
            for e in (m["e"] if m["t"] == "ents" else [m["e"]]):
                if len(e) > 5 and isinstance(e[5], dict) and "ai" in e[5]:
                    icons[e[0]] = e[5]["ai"]
        elif m.get("t") == "aiu":
            for row in m["l"]:
                icons[row[0]] = row[1:]
    plates = [u for u, i in icons.items() if i[:2] == ["recipe", "iron-plate"]]
    report(len(plates) >= 576, "#9: every furnace of the array has its Alt-mode icon (records and aiu, no 400 cap)",
           f"{len(plates)} furnaces showing iron-plate, {len(icons)} icons in all")
    # A furnace switched to copper with no event: the watch sends it.
    out = mod_lua(f"""
local s = storage.f3d.puppet.surface
local f = s.find_entities_filtered({{ name = "steel-furnace", position = {{ {x0} - 23, {y0} - 27 }}, radius = 0.6 }})[1]
local src = defines.inventory.crafter_input or defines.inventory.furnace_source
local res = defines.inventory.crafter_output or defines.inventory.furnace_result
f.get_inventory(src).clear() f.crafting_progress = 0 f.get_inventory(res).clear()
storage.f3d_live_furnace = f
rcon.print(f.unit_number)""".replace("\n", " "))
    fu = int(out) if out.isdigit() else 0
    msgs = c.pump(5.0, every=(1.0, hello_now))
    mod_lua('storage.f3d_live_furnace.insert({ name = "copper-ore", count = 20 }) rcon.print("ok")')
    msgs += c.pump(8.0, every=(1.0, hello_now))
    rows = [r for m in msgs if m.get("t") == "aiu" for r in m["l"] if r[0] == fu]
    report(fu and rows and rows[-1][1:3] == ["recipe", "copper-plate"],
           "#9: a furnace given copper ore (no event) sends its new icon in aiu", str(rows[-2:]))
    # Machines for the arrows: a chemical plant, a refinery, an assembler with a fluid recipe, a recycler.
    specs = [("chemical-plant", -20, 24, "sulfuric-acid"), ("oil-refinery", -12, 24, "advanced-oil-processing"),
             ("assembling-machine-2", -5, 24, "electric-engine-unit"), ("recycler", 0, 24, None),
             ("assembling-machine-2", 5, 24, "iron-gear-wheel")]
    lua = "local c = storage.f3d.puppet local s = c.surface local out = {} "
    for name, dx, dy, recipe in specs:
        lua += (f'local e = s.create_entity({{ name = "{name}", position = {{ {x0 + dx}, {y0 + dy} }}, force = c.force, raise_built = true }}) '
                + (f'if e then e.set_recipe("{recipe}") end ' if recipe else "")
                + 'out[#out + 1] = e and e.unit_number or 0 ')
    lua += 'rcon.print(table.concat(out, " "))'
    units = [int(v) for v in mod_lua(lua).split()]
    msgs = c.pump(3.0, every=(1.0, hello_now))
    c.send({"t": "resync", "full": 0, "c": wanted})
    msgs += c.pump(8.0, every=(1.0, hello_now))
    fa = {}
    for m in msgs:
        if m.get("t") in ("ents", "add", "upd"):
            for e in (m["e"] if m["t"] == "ents" else [m["e"]]):
                if e[0] in units:
                    fa[e[0]] = (e[5] if len(e) > 5 else {}).get("fa", 0)
    want = [3, 3, 1, 0, 0]
    report(len(units) == 5 and [fa.get(u, -1) for u in units] == want,
           "#9 part 2: machines' recipe fluids for the arrows (extra.fa: sulfuric acid 3, refinery 3, engines 1, recycler and gears 0)",
           str([fa.get(u, -1) for u in units]))
    vp = (c.eprops or {}).get(c.proto_id("recycler"), [None] * 4)
    vp = vp[3] if len(vp) > 3 and isinstance(vp[3], dict) else {}
    report("vp" in vp and "fb" not in vp, "#9 part 2: the recycler's output side in eprops (vp)", str(vp))
    # A recipe set from the open screen comes in aiu at once (here: gears -> lubricant-free pipe).
    gu = units[4] if len(units) == 5 else 0
    mod_lua(f"storage.f3d.puppet.teleport({{ {x0 + 5}, {y0 + 21} }}) rcon.print('ok')")
    c.pump(1.0, every=(1.0, hello_now))
    c.send({"t": "open", "u": gu, "p": c.proto_id("assembling-machine-2"), "x": int((x0 + 5) * 256), "y": int((y0 + 24) * 256)})
    c.pump(0.5, every=(1.0, hello_now))
    c.send({"t": "set_recipe", "u": gu, "recipe": "pipe"})
    msgs = c.pump(2.0, every=(1.0, hello_now))
    c.send({"t": "close"})
    rows = [r for m in msgs if m.get("t") == "aiu" for r in m["l"] if r[0] == gu]
    report(rows and rows[-1][1:3] == ["recipe", "pipe"], "#9: a recipe set from the screen sends its icon in aiu", str(rows))
    check_alt_machines(c, hello_now, x0, y0)
    if not keep:
        mod_lua(f'for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ area = {{ {{ {x0 - 30}, {y0 - 30} }}, '
                f'{{ {x0 + 30}, {y0 + 30} }} }}, name = {{ "steel-furnace", "chemical-plant", "oil-refinery", "assembling-machine-2", "recycler", '
                f'"assembling-machine-3", "lab", "beacon", "gun-turret", "rocket-turret", "locomotive", "straight-rail" }} }})) do e.destroy() end rcon.print("ok")')


def check_alt_machines(c, hello_now, x0, y0):
    """K1, K2: what 2.1 says of Alt-mode's icon placement (LuaEntityPrototype.icons_positioning and
    icon_draw_specification, as eprops ids and isq), and `am` while Alt-mode is on: an assembling machine 3's
    four modules in slot order with a quality kept, a lab's packs a slot each and its two modules, a
    beacon's modules."""
    facts = mod_lua("""local out = {} for _, n in pairs({ 'assembling-machine-3', 'lab', 'beacon', 'electric-mining-drill' }) do
 local p = prototypes.entity[n] local ok, ip = pcall(function() return p.icons_positioning end)
 out[#out + 1] = n .. ' ids=' .. serpent.line(p.icon_draw_specification) .. ' ip=' .. (ok and serpent.line(ip) or 'error') end
 rcon.print(table.concat(out, ' | '))""".replace("\n", " "))
    print("  icons_positioning:", facts)
    ep = {name: (((c.eprops or {}).get(c.proto_id(name)) or [None] * 4)[3:] or [{}])[0] or {}
          for name in ("assembling-machine-3", "lab", "beacon")}
    report(ep["assembling-machine-3"].get("ids") == [0, -0.3, 1]
           and ep["assembling-machine-3"].get("isq") == [["m", 0, 0.7, 0.5, 4, 2, 1.1, -0.1]],
           "K1: eprops: the assembling machine 3's icon 0.3 up, its modules' row from Factorio's defaults", str(ep["assembling-machine-3"]))
    lab_rows = {r[0]: r for r in ep["lab"].get("isq", [])}
    report(lab_rows.get("l") == ["l", 0, 0, 0.5, 6, 2, 0.909, -0.1] and lab_rows.get("m", [None] * 3)[2] == 0.9,
           "K2: eprops: Space Age's lab, six packs a row and its modules under them", str(ep["lab"]))
    packs = ["automation-science-pack", "logistic-science-pack", "military-science-pack", "chemical-science-pack",
             "production-science-pack", "utility-science-pack", "space-science-pack"]
    pack_list = ", ".join(f'"{p}"' for p in packs)
    out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local out = {{}}
local a = s.create_entity({{ name = "assembling-machine-3", position = {{ {x0} - 12, {y0} + 14 }}, force = c.force, raise_built = true }})
local m = a.get_module_inventory()
m.insert({{ name = "speed-module-3", count = 1 }}) m.insert({{ name = "speed-module-3", count = 1, quality = "rare" }})
m.insert({{ name = "productivity-module-3", count = 2 }})
local l = s.create_entity({{ name = "lab", position = {{ {x0} - 6, {y0} + 14 }}, force = c.force, raise_built = true }})
for _, p in pairs({{ {pack_list} }}) do l.insert({{ name = p, count = 1 }}) end
l.get_module_inventory().insert({{ name = "speed-module", count = 2 }})
local b = s.create_entity({{ name = "beacon", position = {{ {x0}, {y0} + 14 }}, force = c.force, raise_built = true }})
b.get_module_inventory().insert({{ name = "speed-module-2", count = 2 }})
rcon.print(a.unit_number .. " " .. l.unit_number .. " " .. b.unit_number)""".replace("\n", " "))
    units = [int(v) for v in out.split()] if all(v.isdigit() for v in out.split()) and len(out.split()) == 3 else []
    if not units:
        report(False, "K1, K2: an assembler, a lab and a beacon with modules built", out)
        return
    c.send({"t": "altc", "on": 1, "g": 41})
    msgs = c.pump(4.0, every=(1.0, hello_now))
    c.send({"t": "altc", "on": 0})
    rows = {r[0]: r for m in msgs if m.get("t") == "am" and m.get("g") == 41 for r in m["l"]}
    a, l, b = units
    report(rows.get(a) == [a, ["speed-module-3", ["speed-module-3", "rare"], "productivity-module-3", "productivity-module-3"]],
           "K1: `am`: the assembler's four modules in slot order, the rare one's quality kept", str(rows.get(a)))
    report(rows.get(l) == [l, ["speed-module", "speed-module"], packs],
           "K2: `am`: the lab's seven packs a slot each and its two modules", str(rows.get(l)))
    report(rows.get(b) == [b, ["speed-module-2", "speed-module-2"]], "K1: `am`: the beacon's modules", str(rows.get(b)))
    check_alt_stock(c, hello_now, x0, y0)


def check_alt_stock(c, hello_now, x0, y0):
    """K1's leftover: an ammo turret's ammo and a locomotive's fuel in Alt-mode. What 2.1 says of their
    icons_positioning (the gun turret's and the locomotive's are the only two in its data; Space Age's rocket
    turret has none), eprops' isq for them, and `am`: a gun turret's magazines, a rocket turret's rockets (when
    Space Age is on), a locomotive's fuel a slot each."""
    facts = mod_lua("""local out = {} for _, n in pairs({ 'gun-turret', 'rocket-turret', 'railgun-turret', 'locomotive', 'car' }) do
 local p = prototypes.entity[n] if p then local ok, ip = pcall(function() return p.icons_positioning end)
 out[#out + 1] = n .. ' ip=' .. (ok and serpent.line(ip) or 'error') end end
 rcon.print(table.concat(out, ' | '))""".replace("\n", " "))
    print("  icons_positioning:", facts)
    names = ("gun-turret", "locomotive", "rocket-turret")
    ep = {name: (((c.eprops or {}).get(c.proto_id(name)) or [None] * 4)[3:] or [{}])[0] or {} for name in names if c.proto_id(name)}
    report(ep.get("gun-turret", {}).get("isq") == [["a", 0, -0.25, 0.5, 2, 1, 1.1, -0.1]]
           and ep.get("locomotive", {}).get("isq") == [["f", 0, 0.3, 0.5, 3, 4, 1.1, -0.1]],
           "K1: eprops: the gun turret's ammo row and the locomotive's fuel row, as 2.1's icons_positioning",
           f"{ep.get('gun-turret')} {ep.get('locomotive')}")
    if "rocket-turret" in ep:
        report(ep["rocket-turret"].get("isq") == [["a", 0, 0.7, 0.5, 4, 2, 1.1, -0.1]],
               "K1: eprops: the rocket turret (no icons_positioning) gets Factorio's defaults", str(ep["rocket-turret"]))
    # South and east of the smelting array (x0 - 24..x0 + 24, y0 - 28..y0 + 20) and the arrows' machines (y0 + 24),
    # inside the cleared square: a locomotive isn't made where its box meets a building.
    out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface
local t = s.create_entity({{ name = "gun-turret", position = {{ {x0} - 12, {y0} + 28 }}, force = c.force, raise_built = true }})
t.insert({{ name = "firearm-magazine", count = 10 }})
local bare = s.create_entity({{ name = "gun-turret", position = {{ {x0} - 8, {y0} + 28 }}, force = c.force, raise_built = true }})
local r = prototypes.entity["rocket-turret"] and s.create_entity({{ name = "rocket-turret", position = {{ {x0} - 3.5, {y0} + 28.5 }}, force = c.force, raise_built = true }})
if r then r.insert({{ name = "rocket", count = 5 }}) end
local rx, ry = math.floor(({x0} + 27) / 2) * 2 + 1, math.floor(({y0} - 6) / 2) * 2 + 1
for i = 0, 4 do s.create_entity({{ name = "straight-rail", position = {{ rx, ry + 2 * i }}, direction = defines.direction.north, force = c.force, raise_built = true }}) end
local l = s.create_entity({{ name = "locomotive", position = {{ rx, ry + 4 }}, direction = defines.direction.north, force = c.force, raise_built = true }})
if l then l.insert({{ name = "coal", count = 5 }}) l.insert({{ name = "wood", count = 3 }}) end
rcon.print(t.unit_number .. " " .. bare.unit_number .. " " .. (r and r.unit_number or 0) .. " " .. (l and l.unit_number or 0))""".replace("\n", " "))
    units = [int(v) for v in out.split()] if all(v.isdigit() for v in out.split()) and len(out.split()) == 4 else []
    if not units or not units[3]:
        report(False, "K1: gun turrets and a locomotive on rails built", out)
        return
    c.send({"t": "altc", "on": 1, "g": 42})
    msgs = c.pump(5.0, every=(1.0, hello_now))
    c.send({"t": "altc", "on": 0})
    rows = {r[0]: r for m in msgs if m.get("t") == "am" and m.get("g") == 42 for r in m["l"]}
    t, bare, r, l = units
    report(rows.get(t) == [t, 0, ["firearm-magazine"]] and bare not in rows,
           "K1: `am`: a gun turret's ammo, one icon a filled slot; none for an empty turret", f"{rows.get(t)} {rows.get(bare)}")
    if r:
        report(rows.get(r) == [r, 0, ["rocket"]], "K1: `am`: a rocket turret's rockets", str(rows.get(r)))
    fuel = (rows.get(l) or [0, 0, []])[2] if len(rows.get(l) or []) == 3 else []
    report(sorted(fuel) == ["coal", "wood"], "K1: `am`: a locomotive's fuel, a slot each", str(rows.get(l)))


def check_belt_switch(c, hello):
    """Belts run all the time; only one a network switches off stands still. A belt and a loader with a
    red wire and a false circuit condition report it (status 61; `disabled_by_control_behavior` is false
    on a belt, which isn't "updatable"), a belt with a logistic condition and no wire too, and the
    bridge sends `st` 5 for them, 0 once the condition holds; a plain belt never comes up, nor a
    splitter or an underground, which no network switches off."""
    if not clean_spot(c, hello):
        report(False, "belts off: an empty spot", SPOT_WHY)
        return
    x0, y0 = int(c.me["x"] / 256), int(c.me["y"] / 256)
    out = mod_lua(f"""
local ch = storage.f3d.puppet local s = ch.surface
local function put(name, dx, dy, built) return s.create_entity({{ name = name, position = {{ {x0} + dx + 0.5, {y0} + dy + 0.5 }}, direction = defines.direction.east, force = ch.force, raise_built = built }}) end
local red = defines.wire_connector_id.circuit_red
local comb = put('constant-combinator', -6, 5, true)
local belt = put('transport-belt', -6, 4, true)
local loader = put('loader', -3, 4, true)
local plain = put('transport-belt', -6, 7, true)
local logistic = put('transport-belt', -5, 7, true)
local splitter = put('splitter', -6, 9, true)
local under = put('underground-belt', -3, 9, true)
local no_behavior = logistic.get_control_behavior() == nil
storage.f3d_live_belts = {{ belt = belt, loader = loader, plain = plain, logistic = logistic, splitter = splitter, under = under, comb = comb }}
rcon.print(belt.unit_number .. ' ' .. loader.unit_number .. ' ' .. plain.unit_number .. ' ' .. logistic.unit_number .. ' ' .. tostring(no_behavior))""".replace("\n", " "))
    parts = out.split()
    if len(parts) != 5:
        report(False, "belts off: built", out)
        return
    belt, loader, plain, logistic = (int(v) for v in parts[:4])
    report(parts[4] == "true", "belts off: a belt with no wire has no control behaviour until asked for", parts[4])
    # The combinator's wires looked at once first: a wire added after that is what gets noticed.
    c.pump(2.0, every=hello)
    out = mod_lua(f"""
local b = storage.f3d_live_belts local belt, loader, logistic, comb = b.belt, b.loader, b.logistic, b.comb
local red = defines.wire_connector_id.circuit_red
local cond = {{ first_signal = {{ type = 'item', name = 'iron-plate' }}, comparator = '>', constant = 0 }}
for _, e in pairs({{ belt, loader }}) do
  e.get_wire_connector(red, true).connect_to(comb.get_wire_connector(red, true))
  local cb = e.get_or_create_control_behavior()
  cb.circuit_enable_disable = true
  cb.circuit_condition = cond
end
local lb = logistic.get_or_create_control_behavior()
lb.connect_to_logistic_network = true
lb.logistic_condition = cond
package.loaded['__factorio-3d-bridge__/scripts/belt_switch.lua'].configured(logistic)
rcon.print('ok')""".replace("\n", " "))
    msgs = c.pump(6.0, every=hello)
    rows = [m["l"] for m in of_type(msgs, "st")]
    states = {r[i]: r[i + 1] for r in rows for i in range(0, len(r), 2)}
    facts = mod_lua("""local b = storage.f3d_live_belts local function f(e) return e.name .. ' off=' .. tostring(e.disabled_by_control_behavior)
 .. ' status=' .. tostring(e.status) .. ' active=' .. tostring(e.active) .. ' updatable=' .. tostring(e.is_updatable) end
local cb = b.splitter.get_or_create_control_behavior()
local uok, ucb = pcall(function() return b.under.get_or_create_control_behavior() end)
rcon.print(f(b.belt) .. ' | ' .. f(b.loader) .. ' | ' .. f(b.logistic) .. ' | ' .. f(b.plain) .. ' | ' .. f(b.splitter) .. ' cb=' .. cb.object_name
 .. ' | ' .. f(b.under) .. ' cb=' .. tostring(uok and ucb and ucb.object_name) .. ' | disabled=' .. tostring(defines.entity_status.disabled_by_control_behavior))""".replace("\n", " "))
    print("  facts:", facts)
    rows_of = [f.strip() for f in facts.split("|")]
    report("status=61" in rows_of[0], "belts off: a wired belt with a false condition is status 61", rows_of[0])
    report("status=61" in rows_of[1], "belts off: a wired loader too", rows_of[1])
    report("status=61" in rows_of[2], "belts off: and a belt with a logistic condition and no wire", rows_of[2])
    report("status=1" in rows_of[3] and "status=1" in rows_of[4], "belts off: a plain belt and a splitter run", rows_of[3:5])
    report(states.get(belt) == 5 and states.get(loader) == 5 and states.get(logistic) == 5, "belts off: the bridge sends st 5 for them", states)
    report(plain not in states, "belts off: a plain belt is never mentioned", states)
    mod_lua("""local cond = { first_signal = { type = 'item', name = 'iron-plate' }, comparator = '<', constant = 1 }
local b = storage.f3d_live_belts b.belt.get_control_behavior().circuit_condition = cond b.loader.get_control_behavior().circuit_condition = cond rcon.print('ok')""".replace("\n", " "))
    msgs = c.pump(3.0, every=hello)
    states = {r[i]: r[i + 1] for r in (m["l"] for m in of_type(msgs, "st")) for i in range(0, len(r), 2)}
    report(states.get(belt) == 0 and states.get(loader) == 0, "belts off: the condition true again: st 0", states)
    mod_lua("for _, e in pairs(storage.f3d_live_belts) do e.destroy() end storage.f3d_live_belts = nil rcon.print('ok')")


def check_save(c, hello):
    """Run against a copy of a save someone played (server/saves/<copy>.zip): the bridge takes over
    that player's character, with its inventory, armour, guns, logistic requests and quickbar, and
    reads logistic chests' requests from every section."""
    players = json.loads(mod_lua("local t = {} for _, p in pairs(game.players) do t[#t + 1] = p.name end "
                                 "rcon.print(helpers.table_to_json(t))") or "[]")
    if not players:
        report(True, "save: no players in this save, so nothing to take over (a new map)")
        return
    # Hand everything back, measure the player, then take over again.
    rcon.run("/f3d-player none")
    owner = rcon.run("/f3d-player").strip()
    before = json.loads(mod_lua(SAVE_SUMMARY + "local p = game.get_player(" + json.dumps(players[0]) + ") "
                                "rcon.print(helpers.table_to_json(summary(p)))"))
    lines = rcon.run("/f3d-player " + players[0])
    after = json.loads(mod_lua(SAVE_SUMMARY + "local c = storage.f3d.puppet local p = game.get_player(" + json.dumps(players[0]) + ") "
                               "local o = summary(p) local s = summary(c) "
                               "s.left = o.items s.held = storage.f3d.held_for or 0 s.dx = c.position.x - p.physical_position.x "
                               "s.dy = c.position.y - p.physical_position.y s.surface = c.surface.name s.psurface = p.physical_surface.name "
                               "rcon.print(helpers.table_to_json(s))"))
    report(before["items"] > 0 and after["items"] >= before["items"] and after["left"] == 0 and after["held"] > 0,
           f"save: the bridge stands in for {players[0]} with their inventory",
           f"{before['items']} items in {before['kinds']} kinds before, stand-in has {after['items']}, {after['left']} left with the player")
    # (A logged-off player's main inventory keeps the slots it had while wearing the armour until
    # they log in, so only the stand-in's size is meaningful.)
    report(after["armor"] == before["armor"] and after["guns"] == before["guns"],
           "save: their armour (with its inventory bonus) and guns too",
           f"armour {after['armor']!r}, guns {after['guns']!r}, {after['main_size']} main slots")
    report(after["req"] == before["req"], "save: their logistic requests, every section", f"{before['req']} -> {after['req']}")
    report(abs(after["dx"]) < 8 and abs(after["dy"]) < 8 and after["surface"] == after["psurface"],
           "save: standing where their character was", f"{after['surface']} offset {after['dx']:.1f}, {after['dy']:.1f}")
    # The client sees it: a new handshake names the stand-in, then its slots, requests and quickbar.
    msgs = c.pump(8, every=hello, until=lambda m: m.get("t") == "ready")
    msgs += c.pump(3, every=hello)
    slots = of_type(msgs, "slots")
    main = slots[-1]["l"].get("main", []) if slots else []
    count = sum(s[1] for s in main if s)
    report(count == after["items"], "save: the client's inventory window gets those slots", f"{count} items in slots")
    clog = of_type(msgs, "clog")
    report(clog and len(clog[-1]["l"]) == after["req"], "save: the client gets the requests (clog)",
           f"{len(clog[-1]['l']) if clog else 'no clog'} requests, trash unrequested {clog[-1].get('trash') if clog else '?'}")
    qb = of_type(msgs, "qb")
    want = mod_lua("local p = game.get_player(" + json.dumps(players[0]) + ") local t = {} for i = 1, 100 do "
                   "local ok, s = pcall(p.get_quick_bar_slot, math.ceil(i / 10), (i - 1) % 10 + 1) "
                   "local n = ok and s and s.filter and s.filter.name or '' if type(n) ~= 'string' then n = n.name end t[i] = n end "
                   "rcon.print(table.concat(t, ','))")
    report(qb and ",".join(qb[-1]["l"]) == want, "save: the quickbar is the player's",
           f"{sum(1 for x in qb[-1]['l'] if x) if qb else 0} slots set, page {qb[-1].get('p') if qb else '?'}")
    # The map's surface switcher: every planet with a surface and the force's platforms, and
    # another surface's charts and tags by its index.
    surfs = of_type(msgs, "surfs")
    listed = surfs[-1]["l"] if surfs else []
    names = [r[3] or r[2] for r in listed]
    report(len(listed) >= 2 and after["surface"] in [r[1] for r in listed], "save: the map can switch between surfaces (surfs)",
           ", ".join(names))
    others = [r[1] for r in listed if r[2] == "" and r[3] == ""]
    report(all(r[4] == 0 for r in listed if r[2] == "" and r[3] == ""), "save: surfaces that are no planet nor platform listed as Other",
           ", ".join(others) or "none in this save")
    other = next((r for r in listed if r[1] != after["surface"] and r[2]), None) or next((r for r in listed if r[1] != after["surface"]), None)
    if other:
        c.send({"t": "map", "cx1": -6, "cy1": -6, "cx2": 5, "cy2": 5, "res": 8, "si": other[0]})
        got = c.pump(4, every=hello)
        charts = [m for m in of_type(got, "chart") if m.get("si") == other[0]]
        here = [m for m in of_type(got, "chart") if m.get("si") != other[0]]
        tags = [m for m in of_type(got, "tags") if m.get("si") == other[0]]
        report(charts and any(m["n"] > 0 for m in charts) and not here and tags,
               f"save: the map shows {other[3] or other[2]} from {after['surface']} (map with si)",
               f"{sum(1 for m in charts if m['n'] > 0)}/{len(charts)} chunks charted, {len(tags[-1]['l']) if tags else 0} tags")
    # Remote building: a ghost far from the character on charted ground is placed; on uncharted
    # ground it is refused.
    spot = json.loads(mod_lua(
        "local c = storage.f3d.puppet local f = c.force local s = c.surface "
        "for r = 120, 400, 40 do for _, d in pairs({{1,0},{-1,0},{0,1},{0,-1}}) do "
        "local p = { x = math.floor(c.position.x + d[1] * r) + 0.5, y = math.floor(c.position.y + d[2] * r) + 0.5 } "
        "if f.is_chunk_charted(s, { math.floor(p.x / 32), math.floor(p.y / 32) }) and s.can_place_entity({ name = 'wooden-chest', position = p, force = f }) then "
        "rcon.print(helpers.table_to_json({ p.x, p.y })) return end end end rcon.print('[]')") or "[]")
    if spot:
        c.send({"t": "build", "item": "wooden-chest", "x": int(spot[0] * 256), "y": int(spot[1] * 256), "d": 0, "ghost": 1})
        got = c.pump(1.0, every=hello)
        placed = mod_lua(f"local n = 0 for _, g in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ type = 'entity-ghost', position = {{ {spot[0]}, {spot[1]} }} }})) do "
                         "n = n + 1 g.destroy() end rcon.print(n)")
        report(placed == "1", "save: a ghost placed far away (remote view) on charted ground",
               f"at {spot}; " + "; ".join(m["text"] for m in of_type(got, "msg")))
    c.send({"t": "build", "item": "wooden-chest", "x": 900000 * 256, "y": 900000 * 256, "d": 0, "ghost": 1})
    got = c.pump(1.0, every=hello)
    report(any("uncharted" in m["text"] for m in of_type(got, "msg")), "save: and refused on uncharted ground")
    # Trains in the save: the overview lists every train; a train's window data has its schedule,
    # interrupts, cargo, fuel and stops; a stop's has its priority and circuit settings.
    want_trains = int(mod_lua("local n = 0 for _, t in pairs(game.train_manager.get_trains({ force = storage.f3d.puppet.force })) do "
                              "n = n + 1 end rcon.print(n)") or 0)
    c.send({"t": "trains_list"})
    got = c.pump(2, every=hello)
    trl = [r for m in of_type(got, "trl") for r in m["l"]]
    report(len(trl) == want_trains, "save: the trains overview (trl) lists every train of the force",
           f"{len(trl)}/{want_trains}: " + ", ".join(f"#{r[0]} {r[1]} {r[3]}" for r in trl[:4]))
    if want_trains:
        info = json.loads(mod_lua(
            "local tr = package.loaded['__factorio-3d-bridge__/scripts/trains.lua'] "
            "local t = game.train_manager.get_trains({ force = storage.f3d.puppet.force })[1] "
            "local stop = game.train_manager.get_train_stops({ force = storage.f3d.puppet.force })[1] "
            "rcon.print(helpers.table_to_json({ tr = tr.train_info(t.front_stock), stop = stop and tr.stop_info(stop) or {} }))"))
        tri, sti = info.get("tr", {}), info.get("stop", {})
        problems = protocol.train_info_problems(tri)
        report(not problems and isinstance(tri.get("sched", {}).get("records"), list) and "cargo" in tri and "fuel" in tri and tri.get("stops"),
               "save: a train's window data: schedule, interrupts, cargo, fuel, stops",
               f"{len(tri.get('sched', {}).get('records', []))} records, {len(tri.get('sched', {}).get('interrupts', []))} interrupts, "
               f"cargo {protocol._items(tri.get('cargo', []))[:2]}, fuel {tri.get('fuel')}, {len(tri.get('stops', []))} stops {problems[:2]}")
        report(isinstance(sti.get("pri"), int) and isinstance(sti.get("cb"), dict), "save: a train stop's priority and circuit settings",
               f"{sti.get('name')}: priority {sti.get('pri')}, cb {sti.get('cb')}")
        # Interrupts and a temporary stop written through the mod's commands, read back, then the
        # schedule put back as it was.
        stop_name = (tri.get("stops") or [""])[0]
        interrupt = {"name": "live-check", "inside_interrupt": False,
                     "conditions": [{"type": "fuel_item_count_any", "compare_type": "and",
                                     "condition": {"first_signal": {"type": "item", "name": "coal"}, "comparator": "<", "constant": 5}}],
                     "targets": [{"station": stop_name, "wait_conditions": [{"type": "inactivity", "compare_type": "and", "ticks": 300}]}]}
        back = json.loads(mod_lua(
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
        report(ints and ints[0].get("name") == "live-check" and ints[0].get("conditions", [{}])[0].get("type") == "fuel_item_count_any"
               and cur.get("temporary") and cur.get("station") == stop_name,
               "save: set_interrupts and a temporary stop (train_temp) work on a real train",
               f"interrupts {[i.get('name') for i in ints]}, current record {cur}")
    # Logistic chests in the save: what a machine screen shows is every active section's requests.
    chests = json.loads(mod_lua(
        "local lg = package.loaded['__factorio-3d-bridge__/scripts/logistics.lua'] local out = {} "
        "for _, s in pairs(game.surfaces) do for _, e in pairs(s.find_entities_filtered({ type = 'logistic-container', limit = 400 })) do "
        "local ok, secs = pcall(e.get_logistic_sections) if ok and secs and #out < 40 then local n = 0 "
        "for _, sec in pairs(secs.sections) do if sec.active then for _, f in pairs(sec.filters) do if f.value and f.value.name then n = n + 1 end end end end "
        "local info = lg.screen_info(e) if info and info.requests then out[#out + 1] = { n, #info.requests, secs.sections_count } end end end end "
        "rcon.print(helpers.table_to_json(out))") or "[]")
    multi = sum(1 for ch in chests if ch[2] > 1)
    report(chests and all(ch[0] == ch[1] for ch in chests), "save: requester and buffer chests show every section's requests",
           f"{len(chests)} chests, {multi} with more than one section, {sum(ch[0] for ch in chests)} requests")
    # Hand back and take over once more: nothing is lost on the way.
    rcon.run("/f3d-player none")
    back = json.loads(mod_lua(SAVE_SUMMARY + "rcon.print(helpers.table_to_json(summary(game.get_player(" + json.dumps(players[0]) + "))))"))
    report(back["items"] == after["items"] and back["armor"] == before["armor"], "save: /f3d-player none gives it all back",
           f"{back['items']} items, armour {back['armor']!r}")
    rcon.run("/f3d-player " + players[0])
    c.pump(8, every=hello, until=lambda m: m.get("t") == "ready")
    print("  players:", owner.replace("\n", " | "), "|", lines.strip().replace("\n", " | "))


def check_build_marks(c, hello, x, y):
    """What hover and the build cursor draw (eprops' overlay), and undergrounds built like a player's:
    the second of a pair is the exit, whose direction is the way items go."""
    ep = c.eprops or {}
    over = lambda name: (ep.get(c.proto_id(name)) or [0, 0, 0, {}])[3:4] or [{}]
    ins, robo, drill, engine = (over(n)[0] for n in ("long-handed-inserter", "roboport", "electric-mining-drill", "steam-engine"))
    report(ins.get("ip") == [0, -2] and ins.get("id") == [0, 2.2] and robo.get("lr") == 25 and robo.get("cr") == 55
           and drill.get("mr") == 2.49 and drill.get("vp") == [0, -1.85] and drill.get("fo") == 1
           and sorted(map(tuple, engine.get("fb", []))) == [(0, -2, 0, "b"), (0, 2, 8, "b")],
           "eprops overlay: inserter_pickup/drop_position, logistic/construction_radius, mining_drill_radius, "
           "vector_to_place_result, fluidbox_prototypes pipe_connections", f"{ins} {robo} {drill} {engine}")
    mod_lua('storage.f3d.puppet.insert({ name = "underground-belt", count = 8 })')
    fx = lambda v: int(round(v * 256))
    ug = c.proto_id("underground-belt")
    bx, by = math.floor(x), math.floor(y)
    # Each pair on its own line north of the test entities, within reach: [direction, first, second].
    pairs = [(0, (-6, -6), (-6, -9)), (8, (-4, -9), (-4, -6)), (4, (-1, -7), (2, -7)), (12, (5, -9), (2, -9))]
    built, msgs = [], []
    for d, *ends in pairs:
        for k, (dx, dy) in enumerate(ends):
            px, py = bx + dx + 0.5, by + dy + 0.5
            c.send({"t": "build", "item": "underground-belt", "x": fx(px), "y": fx(py), "d": d})
            msgs += c.pump(0.3, every=hello)
            built.append((d, k, px, py))
    msgs += c.pump(1.0, every=hello)
    adds = {(m["e"][2], m["e"][3]): m["e"] for m in of_type(msgs, "add") if m["e"][1] == ug}
    out = mod_lua("local o = {} for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({ name = 'underground-belt', "
                  f"area = {{ {{ {bx - 8}, {by - 10} }}, {{ {bx + 8}, {by - 5} }} }} }})) do "
                  "o[#o + 1] = e.position.x .. ',' .. e.position.y .. ',' .. e.direction .. ',' .. e.belt_to_ground_type end "
                  "rcon.print(table.concat(o, ' '))")
    game = {(float(a), float(b)): (int(d), t) for a, b, d, t in (v.split(",") for v in out.split())}
    ok = len(game) == 8
    for d, k, px, py in built:
        want = ("input", "output")[k]
        sent = adds.get((fx(px), fx(py)))
        ok = ok and game.get((px, py)) == (d, want) and sent is not None and len(sent) > 5 and sent[5].get("u") == want[0]
    report(ok, "undergrounds built in all four directions: entrance then exit (create_entity type), both facing the "
           "way items go, sent as extra.u", f"{out} | sent {[a[2:] for a in adds.values()]}")
    # J23: R on the east pair's entrance turns both ends (the game flips a pair together and tells of
    # only the one turned): both come back turned, facing west, entrance and exit swapped.
    east_in, east_out = adds.get((fx(bx - 0.5), fx(by - 6.5))), adds.get((fx(bx + 2.5), fx(by - 6.5)))
    if east_in and east_out:
        c.send({"t": "rotate", "u": east_in[0], "p": ug, "x": east_in[2], "y": east_in[3], "rev": 0})
        turned = {m["e"][0]: (m["e"][4], m["e"][5].get("u")) for m in of_type(c.pump(1.0, every=hello), "upd")
                  if m["e"][1] == ug and len(m["e"]) > 5}
        report(turned.get(east_in[0]) == (12, "o") and turned.get(east_out[0]) == (12, "i"),
               "J23: R on an underground's entrance sends both ends turned (facing back, entrance and exit swapped)", str(turned))
    else:
        report(False, "J23: the east underground pair to turn", str(list(adds)))
    mod_lua("for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({ name = 'underground-belt', "
            f"area = {{ {{ {bx - 8}, {by - 10} }}, {{ {bx + 8}, {by - 5} }} }} }})) do e.destroy({{ raise_destroy = true }}) end")


def eq_of(msgs, kind):
    eqs = [m for m in of_type(msgs, "eq") if m.get("kind") == kind]
    return eqs[-1] if eqs else None


def check_gear(c, hello):
    """The character's gear (equipment.lua, puppet.lua): its armour's equipment grid (`eq`), putting,
    moving and taking equipment, the roboport and exoskeleton switches, `me`'s shields, the
    character tab (`cinfo`), the players list (`pl`), a vehicle's grid, and dying: the countdown
    (`dead`) and the respawn at the spawn. Use a copy of a save: the armour is taken from any
    other character that wears one (the owner's save has one), else power armour is made."""
    out = mod_lua("""
local c = storage.f3d.puppet
local mine = c.get_inventory(defines.inventory.character_armor)
local how = "worn"
if not (mine[1].valid_for_read and c.grid) then
  how = "made"
  for _, s in pairs(game.surfaces) do
    for _, o in pairs(s.find_entities_filtered({ type = "character" })) do
      if o ~= c and o.grid and #o.grid.equipment > 0 and how == "made" then
        mine[1].swap_stack(o.get_inventory(defines.inventory.character_armor)[1])
        how = "from " .. s.name
      end
    end
  end
end
if how == "made" then
  mine[1].set_stack({ name = "power-armor-mk2" })
  local g = c.grid
  for _, e in pairs({ { "fission-reactor-equipment", 0, 0 }, { "exoskeleton-equipment", 4, 0 }, { "battery-mk2-equipment", 6, 0 },
      { "night-vision-equipment", 7, 0 }, { "personal-roboport-equipment", 4, 4 } }) do
    g.put({ name = e[1], position = { e[2], e[3] } })
  end
end
c.insert({ name = "energy-shield-equipment", count = 1 })
local g = c.grid
local list = {}
for _, e in pairs(g.equipment) do list[#list + 1] = { e.name, e.position.x, e.position.y, e.shape.width, e.shape.height } end
rcon.print(helpers.table_to_json({ how = how, w = g.width, h = g.height, l = list, mv = g.movement_bonus }))
""".replace("\n", " "))
    try:
        grid = json.loads(out)
    except ValueError:
        report(False, "gear: put power armour on the character", out[:300])
        return
    msgs = c.pump(2.5, every=hello)
    eq = eq_of(msgs, "char") or c.last.get("eq char")
    report(eq and eq["w"] == grid["w"] and eq["h"] == grid["h"] and len(eq["l"]) == len(grid["l"])
           and sorted(r[:5] for r in eq["l"]) == sorted(grid["l"]),
           "eq: the armour's grid with every piece where it is (LuaEntity::grid, LuaEquipment position and shape)",
           f"armour {grid['how']}, {grid['w']}x{grid['h']}, {len(grid['l'])} pieces; sent {eq and len(eq['l'])}")
    if not eq:
        return
    report(eq["mv"] >= 0 and eq["mbat"] >= eq["bat"] >= 0 and eq["gen"] >= 0 and eq["rb"] in (0, 1),
           "eq: movement bonus, battery energy, generator power and the roboport switch",
           f"mv {eq['mv']} bat {eq['bat']}/{eq['mbat']} gen {eq['gen']} W rb {eq.get('rb')} nv {eq.get('nv')}")
    info = [c.last["cinfo"]] if "cinfo" in c.last else []
    report(info and info[-1]["reach"] > 0 and info[-1]["slots"] > 0 and info[-1]["hp"] > 0 and info[-1]["eqmv"] == eq["mv"],
           "cinfo: the character tab (reach, slots, health, the equipment's running bonus)", str(info[-1:])[:300])
    pl = [c.last["pl"]] if "pl" in c.last else []
    report(pl and pl[-1]["u"] == c.me["u"] and len(pl[-1]["l"]) >= 1 and all(len(r) == 11 for r in pl[-1]["l"]),
           "pl: the game's players, and whose character the client plays", str(pl[-1:])[:300])

    # Make room for the shield: take the smallest piece out (into an empty slot), Shift+click the
    # shield in, check `me` shows its shield, then put everything back as it was.
    small = next((r for r in eq["l"] if r[3:5] == [2, 2]), min(eq["l"], key=lambda r: r[3] * r[4]))
    c.send({"t": "eq_take", "kind": "char", "x": small[1], "y": small[2]})
    msgs = c.pump(1.0, every=hello)
    eq2 = eq_of(msgs, "char")
    report(eq2 and len(eq2["l"]) == len(eq["l"]) - 1 and c.inv.get(small[0], 0) >= 1,
           "eq_take: equipment out of the grid into the inventory (LuaEquipmentGrid::take)", f"took {small[0]} at {small[1]},{small[2]}")
    fi = json.loads(mod_lua("local m = storage.f3d.puppet.get_main_inventory() local out = 0 "
                            "for i = 1, #m do if out == 0 and m[i].valid_for_read and m[i].name == 'energy-shield-equipment' then out = i end end "
                            "rcon.print(out)") or "0")
    c.send({"t": "eq_put", "kind": "char", "fi": fi})
    msgs = c.pump(1.5, every=hello)
    eq3 = eq_of(msgs, "char")
    shield = [r for r in (eq3 or {}).get("l", []) if r[0] == "energy-shield-equipment"]
    mes = [m for m in of_type(msgs, "me") if "msd" in m]
    report(shield and shield[0][9] > 0 and eq3["msh"] >= shield[0][9],
           "eq_put without a position: Shift+click puts it where it first fits (LuaEquipmentGrid::put)", str(shield))
    report(mes and mes[-1]["msd"] == eq3["msh"], "me: sd and msd, the armour's shields over the health bar", str(mes[-1:])[:200])
    if shield:
        c.send({"t": "eq_take", "kind": "char", "x": shield[0][1], "y": shield[0][2]})
        c.pump(0.8, every=hello)
    fi = json.loads(mod_lua("local m = storage.f3d.puppet.get_main_inventory() local out = 0 "
                            f"for i = 1, #m do if out == 0 and m[i].valid_for_read and m[i].name == '{small[0]}' then out = i end end "
                            "rcon.print(out)") or "0")
    c.send({"t": "eq_put", "kind": "char", "fi": fi, "x": small[1], "y": small[2]})
    msgs = c.pump(1.0, every=hello)
    eq4 = eq_of(msgs, "char")
    report(eq4 and sorted(r[:5] for r in eq4["l"]) == sorted(r[:5] for r in eq["l"]),
           "eq_put at a position: the piece goes back where it was", f"{small[0]} at {small[1]},{small[2]}")
    # Moving: the smallest piece out again, then one of the same shape into its place.
    small = min(eq["l"], key=lambda r: r[3] * r[4])
    twin = next((r for r in eq["l"] if r[3:5] == small[3:5] and r[1:3] != small[1:3]), None)
    if twin:
        c.send({"t": "eq_take", "kind": "char", "x": small[1], "y": small[2]})
        c.pump(0.8, every=hello)
        c.send({"t": "eq_move", "kind": "char", "x": twin[1], "y": twin[2], "tx": small[1], "ty": small[2]})
        msgs = c.pump(1.0, every=hello)
        eq5 = eq_of(msgs, "char")
        moved = [r for r in (eq5 or {}).get("l", []) if r[1:3] == small[1:3]]
        report(moved and moved[0][0] == twin[0], "eq_move: a piece moves to another place in the grid (LuaEquipmentGrid::move{...})",
               f"{twin[0]} from {twin[1]},{twin[2]} to {small[1]},{small[2]}")
        c.send({"t": "eq_move", "kind": "char", "x": small[1], "y": small[2], "tx": twin[1], "ty": twin[2]})
        c.pump(0.8, every=hello)
        fi = json.loads(mod_lua("local m = storage.f3d.puppet.get_main_inventory() local out = 0 "
                                f"for i = 1, #m do if out == 0 and m[i].valid_for_read and m[i].name == '{small[0]}' then out = i end end "
                                "rcon.print(out)") or "0")
        c.send({"t": "eq_put", "kind": "char", "fi": fi, "x": small[1], "y": small[2]})
        c.pump(0.8, every=hello)
    else:
        report(True, "eq_move: no two pieces of the same shape to swap places with (skipped)")
    # Alt+F and Alt+E.
    c.send({"t": "eq_toggle", "what": "roboport", "on": 0})
    c.send({"t": "eq_toggle", "what": "movement", "on": 0})
    msgs = c.pump(1.0, every=hello)
    state = mod_lua("local c = storage.f3d.puppet rcon.print(tostring(c.allow_dispatching_robots) .. ' ' .. tostring(c.grid.inhibit_movement_bonus))")
    eq6 = eq_of(msgs, "char")
    report(state == "false true" and eq6 and eq6["rb"] == 0 and eq6["mvon"] == 0 and eq6["mv"] == 0,
           "eq_toggle: personal roboport off (allow_dispatching_robots) and exoskeletons off (inhibit_movement_bonus)", state)
    c.send({"t": "eq_toggle", "what": "roboport", "on": 1})
    c.send({"t": "eq_toggle", "what": "movement", "on": 1})
    c.pump(1.0, every=hello)
    state = mod_lua("local c = storage.f3d.puppet rcon.print(tostring(c.allow_dispatching_robots) .. ' ' .. tostring(c.grid.inhibit_movement_bonus))")
    report(state == "true false", "eq_toggle: and back on", state)

    # A vehicle's grid: a tank beside the character, opened like its screen.
    out = mod_lua("local c = storage.f3d.puppet local p = c.surface.find_non_colliding_position('tank', { c.position.x + 4, c.position.y }, 10, 0.5) "
                  "local t = p and c.surface.create_entity({ name = 'tank', position = p, force = c.force }) "
                  "c.insert({ name = 'battery-equipment', count = 1 }) "
                  "rcon.print(t and (t.unit_number .. ' ' .. math.floor(t.position.x * 256 + 0.5) .. ' ' .. math.floor(t.position.y * 256 + 0.5) .. ' ' .. tostring(t.grid and t.grid.width)) or 'none')")
    parts = out.split()
    if len(parts) == 4:
        tank = int(parts[0])
        c.send({"t": "open", "u": tank, "p": c.proto_id("tank"), "x": int(parts[1]), "y": int(parts[2])})
        msgs = c.pump(1.5, every=hello)
        veh = eq_of(msgs, "veh")
        report(veh and veh["u"] == tank and veh["w"] > 0, "eq: an open tank's equipment grid (kind veh)", f"{veh and (veh['w'], veh['h'])}, grid {parts[3]}")
        fi = json.loads(mod_lua("local m = storage.f3d.puppet.get_main_inventory() local out = 0 "
                                "for i = 1, #m do if out == 0 and m[i].valid_for_read and m[i].name == 'battery-equipment' then out = i end end "
                                "rcon.print(out)") or "0")
        c.send({"t": "eq_put", "kind": "veh", "u": tank, "fi": fi, "x": 0, "y": 0})
        msgs = c.pump(1.0, every=hello)
        veh = eq_of(msgs, "veh")
        report(veh and any(r[0] == "battery-equipment" for r in veh["l"]), "eq_put into the tank's grid", str(veh and veh["l"]))
        c.send({"t": "close"})
        c.pump(0.5, every=hello)
        destroy_units([tank])
    else:
        report(False, "gear: build a tank", out)

    # Dying: the bridge's character waits out the character's respawn time, then comes back at the spawn.
    old = c.me["u"]
    mod_lua("local c = storage.f3d.puppet c.die()")
    msgs = c.pump(2.0, every=hello)
    dead = of_type(msgs, "dead")
    report(dead and 400 < dead[0]["left"] <= 600 and "x" in dead[0], "dead: the respawn countdown after the character died",
           str(dead[:1]))
    # 600 ticks: longer than 10 s when a big save runs below 60 UPS.
    msgs = c.pump(40, every=hello, until=lambda m: m.get("t") == "welcome")
    welcome = of_type(msgs, "welcome")
    where = mod_lua("local c = storage.f3d.puppet local s = c.force.get_spawn_position(c.surface) "
                    "rcon.print(string.format('%.1f %s', math.sqrt((c.position.x - s.x)^2 + (c.position.y - s.y)^2), c.surface.name))")
    report(welcome and welcome[-1]["u"] != old and float(where.split()[0]) < 16,
           "respawn: a new character at the force's spawn after the respawn time, with a new welcome", where)
    msgs = c.pump(2.0, every=hello)
    eq7 = eq_of(msgs, "char")
    report(eq7 is not None and eq7["w"] == 0, "eq: the respawned character has no armour (it is in the corpse)", str(eq7)[:120])


def bp_string(record):
    """Factorio's exchange string, as the game and blueprint websites write it."""
    return "0" + base64.b64encode(zlib.compress(json.dumps(record).encode(), 9)).decode()


def bp_record(text):
    return json.loads(zlib.decompress(base64.b64decode(text[1:])))


def bp_reply(c, hello, q, seconds=8.0):
    """The `bp` parts answering request q, joined: (string, first part), or ("", None)."""
    parts, first, end = {}, None, time.time() + seconds
    while time.time() < end:
        for m in c.pump(0.3, every=hello):
            if m.get("t") == "bp" and m.get("q") == q:
                parts[m["part"]] = m["s"]
                first = first or m
                if len(parts) == m["parts"]:
                    return "".join(parts[k] for k in sorted(parts)), first
    return "", first


FLIP_SETUP = """
local c = storage.f3d.puppet local s = c.surface local f = c.force
local ox, oy = OX, OY
local made = {}
local function make(name, x, y, d, extra)
  local spec = { name = name, position = { ox + x, oy + y }, direction = d or 0, force = f }
  for k, v in pairs(extra or {}) do spec[k] = v end
  local e = s.create_entity(spec)
  if e then made[#made + 1] = name end
  return e
end
make("chemical-plant", 1.5, 1.5, 0)
local sp = make("splitter", 6, 1.5, 0)
if sp then sp.splitter_output_priority = "left" sp.splitter_input_priority = "right" end
make("underground-belt", 1.5, 5.5, 4, { type = "input" })
make("underground-belt", 4.5, 5.5, 4, { type = "output" })
make("inserter", 7.5, 5.5, 4)
make("curved-rail-a", 12, 4, 0)
make("half-diagonal-rail", 8, 10, 0)
make("straight-rail", 2, 10, 2)
local st = storage.f3d.lib_cursor[1]
st.set_stack({ name = "blueprint", count = 1 })
st.create_blueprint({ surface = s, force = f, area = { { ox, oy }, { ox + 16, oy + 13 } } })
rcon.print(table.concat(made, ",") .. " | " .. tostring(st.is_blueprint_setup()))
"""

FLIP_COMPARE = """
local c = storage.f3d.puppet local s = c.surface
local function area_of(x0, x1) return { { x0, OY - 4 }, { x1, OY + 14 } } end
for _, g in pairs(s.find_entities_filtered({ area = area_of(MX0, MX1), type = "entity-ghost" })) do g.revive() end
local function find(x0, x1)
  local out = {}
  for _, e in pairs(s.find_entities_filtered({ area = area_of(x0, x1), name = { "chemical-plant", "splitter", "underground-belt", "inserter", "curved-rail-a", "half-diagonal-rail", "straight-rail" } })) do
    out[#out + 1] = e
  end
  return out
end
local a, b = find(OX - 1, OX + 17), find(MX0, MX1)
local function anchor(list) for _, e in pairs(list) do if e.name == "chemical-plant" then return e end end end
local A, B = anchor(a), anchor(b)
if not (A and B) then rcon.print("anchor missing " .. #a .. " " .. #b) return end
local function rel(e, p, o) return { x = p.x - o.position.x, y = p.y - o.position.y } end
local function close(p, q) return math.abs(p.x - q.x) < 0.01 and math.abs(p.y - q.y) < 0.01 end
local function mirror(p) return { x = -p.x, y = p.y } end
local out = {}
local function note(k, ok) out[#out + 1] = k .. "=" .. tostring(ok) end
for _, e in pairs(a) do
  local want = mirror(rel(e, e.position, A))
  local match
  for _, m in pairs(b) do
    if m.name == e.name and close(rel(m, m.position, B), want) then match = m end
  end
  local key = e.name .. (e.type == "underground-belt" and ("-" .. e.belt_to_ground_type) or "")
  if not match then
    note(key .. ".position", false)
  else
    local rail = e.type == "curved-rail-a" or e.type == "half-diagonal-rail" or e.type == "straight-rail"
    if not rail then note(key .. ".direction", match.direction == (16 - e.direction) % 16) end
    if e.name == "chemical-plant" then
      note(key .. ".mirroring", match.mirroring ~= e.mirroring)
      local pa, pb = {}, {}
      for i = 1, 8 do
        local ok, list = pcall(function() return e.get_fluid_box_pipe_connections(i) end)
        if ok and list then for _, pc in pairs(list) do pa[#pa + 1] = mirror(rel(e, pc.target_position, A)) end end
        ok, list = pcall(function() return match.get_fluid_box_pipe_connections(i) end)
        if ok and list then for _, pc in pairs(list) do pb[#pb + 1] = rel(match, pc.target_position, B) end end
      end
      local same = #pa == #pb and #pa > 0
      for _, p in pairs(pa) do
        local hit = false
        for _, q in pairs(pb) do if close(p, q) then hit = true end end
        same = same and hit
      end
      note(key .. ".pipes", same)
    elseif e.name == "splitter" then
      note(key .. ".output", match.splitter_output_priority == "right")
      note(key .. ".input", match.splitter_input_priority == "left")
    elseif e.type == "underground-belt" then
      note(key .. ".type", match.belt_to_ground_type == e.belt_to_ground_type)
      note(key .. ".pair", match.underground_belt_neighbour ~= nil)
    elseif e.name == "inserter" then
      note(key .. ".pickup", close(rel(match, match.pickup_position, B), mirror(rel(e, e.pickup_position, A))))
      note(key .. ".drop", close(rel(match, match.drop_position, B), mirror(rel(e, e.drop_position, A))))
    elseif rail then
      local ea, eb = {}, {}
      for _, d in pairs({ defines.rail_direction.front, defines.rail_direction.back }) do
        ea[#ea + 1] = mirror(rel(e, e.get_rail_end(d).location.position, A))
        eb[#eb + 1] = rel(match, match.get_rail_end(d).location.position, B)
      end
      local same = true
      for _, p in pairs(ea) do
        local hit = false
        for _, q in pairs(eb) do if close(p, q) then hit = true end end
        same = same and hit
      end
      note(key .. ".ends", same)
    end
  end
end
for _, e in pairs(a) do e.destroy() end
for _, e in pairs(b) do e.destroy() end
rcon.print(table.concat(out, " "))
"""


def check_flips(c, hello):
    """A held blueprint flipped (H): the mod mirrors its entities (planners.lua mirrored) and the
    result is compared with the original in the real game, entity by entity: positions mirrored,
    directions reflected, the chemical plant's mirroring and its pipe connections, the splitter's
    priorities swapped, the underground pair still paired, the inserter's hand positions, and a
    curved, half-diagonal and diagonal straight rail's two ends."""
    if not clean_spot(c, hello, half=18):
        report(False, "flips: no clean spot found")
        return
    x, y = round(c.me["x"] / 256), round(c.me["y"] / 256)
    ox, oy = x - 18 + (x % 2), y - 6 + (y % 2)  # rails sit on the 2-tile grid
    out = mod_lua(FLIP_SETUP.replace("OX", str(ox)).replace("OY", str(oy)).replace("\n", " "))
    report(out.endswith("true") and "curved-rail-a" in out, "flips: the original layout built and made into a blueprint", out)
    px, py = ox + 26, oy + 6  # an even spot right of it
    c.send({"t": "blueprint", "i": -1, "x": px * 256, "y": py * 256, "d": 0, "bm": 1, "m": 1})
    msgs = c.pump(1.0, every=hello)
    texts = [m["text"] for m in of_type(msgs, "msg")]
    out = mod_lua(FLIP_COMPARE.replace("OX", str(ox)).replace("OY", str(oy)).replace("MX0", str(ox + 18))
                  .replace("MX1", str(ox + 36)).replace("\n", " "))
    report(out and "false" not in out and "missing" not in out, "flips: the mirrored blueprint matches the original mirrored, entity by entity",
           out + (" | " + "; ".join(texts) if texts else ""))
    return out


def check_planner_modes(c, hello, x, y, fx, ghost):
    """Factorio's build modes for a held blueprint (`bm`: a click is normal, Shift forced), the upgrade
    planner's right-drag downgrade (`down`) and the planner window's delete button (`bp_del`)."""
    rock_at = (x - 11, y + 3)
    out = mod_lua(f"local s = storage.f3d.puppet.surface local t = s.create_entity({{ name = 'big-rock', position = {{ {rock_at[0]}, {rock_at[1]} }} }}) "
                  "rcon.print(t and 'ok' or 'no')")
    furnace = c.proto_id("stone-furnace")
    one = {"blueprint": {"item": "blueprint", "label": "One furnace", "version": (2 << 48) | (28 << 16),
                         "entities": [{"entity_number": 1, "name": "stone-furnace", "position": {"x": 0, "y": 0}}]}}
    c.send({"t": "bp_set", "q": 520, "i": -1, "s": bp_string(one)})
    c.pump(0.5, every=hello)
    rock = lambda: mod_lua(f"local t = storage.f3d.puppet.surface.find_entities_filtered({{ name = 'big-rock', position = {{ {rock_at[0]}, {rock_at[1]} }}, radius = 1.5 }})[1] "
                           "rcon.print(t and tostring(t.to_be_deconstructed()) or 'gone')")
    placed = {}
    for bm in (0, 1):
        c.send({"t": "blueprint", "i": -1, "x": fx(rock_at[0]), "y": fx(rock_at[1]), "d": 0, "bm": bm})
        msgs = c.pump(1.0, every=hello)
        placed[bm] = ([m["e"] for m in of_type(msgs, "add") if m["e"][1] == ghost and m["e"][5].get("gh") == furnace], rock(),
                      of_type(msgs, "hist"))
    report(out == "ok" and not placed[0][0] and placed[0][1] == "false",
           "blueprint bm 0 (a click): nothing over a rock, the rock left alone (build_mode.normal)", f"{len(placed[0][0])} ghosts, rock marked: {placed[0][1]}")
    report(placed[1][0] and placed[1][1] == "true", "blueprint bm 1 (Shift+click): the ghost over the rock, the rock marked (build_mode.forced)",
           f"{len(placed[1][0])} ghosts, rock marked: {placed[1][1]}")
    for _, _, hist in placed.values():
        for h in hist:
            c.send({"t": "undo", "h": h["h"]})
    c.pump(0.5, every=hello)
    mod_lua(f"for _, t in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'big-rock', position = {{ {rock_at[0]}, {rock_at[1]} }}, radius = 1.5 }})) do t.destroy() end")
    # Downgrade: an iron chest with a wooden -> iron planner dragged the other way round.
    out = mod_lua(f"local c = storage.f3d.puppet local e = c.surface.create_entity({{ name = 'iron-chest', position = {{ {x - 14.5}, {y + 2.5} }}, force = c.force }}) "
                  "rcon.print(e and e.unit_number or 0)")
    planner = {"upgrade_planner": {"item": "upgrade-planner", "version": (2 << 48) | (28 << 16), "settings": {"mappers": [
        {"index": 0, "from": {"type": "entity", "name": "wooden-chest"}, "to": {"type": "entity", "name": "iron-chest"}}]}}}
    c.send({"t": "bp_set", "q": 521, "i": -1, "s": bp_string(planner)})
    c.pump(0.5, every=hello)
    area = {"x1": fx(x - 16), "y1": fx(y + 1), "x2": fx(x - 13), "y2": fx(y + 4)}
    c.send({"t": "upgrade", "i": -1, "down": 1, "cancel": 0, **area})
    c.pump(0.8, every=hello)
    target = mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'iron-chest' }})) do "
                     f"if e.unit_number == {out or 0} then local t = e.get_upgrade_target() rcon.print(t and t.name or 'none') return end end")
    report(target == "wooden-chest", "upgrade down 1 (right-drag): marked by the reversed mappings (upgrade_area with a reversed copy)", f"target: {target}")
    c.send({"t": "upgrade", "i": -1, "cancel": 1, **area})
    c.pump(0.4, every=hello)
    destroy_units([out])
    # bp_del: a book in the inventory destroyed.
    slot = mod_lua("local c = storage.f3d.puppet c.insert({ name = 'blueprint-book', count = 1 }) local inv = c.get_main_inventory() "
                   "for i = 1, #inv do if inv[i].valid_for_read and inv[i].name == 'blueprint-book' then rcon.print(i) return end end")
    c.send({"t": "bp_del", "i": int(slot) if slot.isdigit() else 0})
    c.pump(0.4, every=hello)
    left = mod_lua(f"rcon.print(tostring(storage.f3d.puppet.get_main_inventory()[{slot if slot.isdigit() else 1}].valid_for_read))")
    report(slot.isdigit() and left == "false", "bp_del: the planner window's delete destroys the book (LuaItemStack.clear)", f"slot {slot}: {left}")
    # copy with to: the blueprint window's "Select new contents", into the same blueprint, its name kept.
    c.send({"t": "bp_set", "q": 530, "i": 0, "s": bp_string(one)})
    msgs = c.pump(1.0, every=hello, until=lambda m: m.get("t") == "bp_ok" and m.get("q") == 530)
    ok = [m for m in of_type(msgs, "bp_ok") if m["q"] == 530]
    bp_slot = ok[0]["i"] if ok else 0
    chest = mod_lua(f"local c = storage.f3d.puppet local e = c.surface.create_entity({{ name = 'wooden-chest', position = {{ {x - 18.5}, {y + 6.5} }}, force = c.force }}) "
                    "rcon.print(e and e.unit_number or 0)")
    c.send({"t": "copy", "x1": fx(x - 19), "y1": fx(y + 6), "x2": fx(x - 18), "y2": fx(y + 7), "cut": 0, "bp": 1, "to": bp_slot})
    msgs = c.pump(1.0, every=hello)
    again = [m for m in of_type(msgs, "bp_ok") if m.get("new") == 1]
    out = mod_lua(f"local s = storage.f3d.puppet.get_main_inventory()[{bp_slot or 1}] "
                  "rcon.print(tostring(s.valid_for_read and s.label) .. ' ' .. tostring(s.valid_for_read and s.is_blueprint_setup() and s.get_blueprint_entities()[1].name))")
    report(bp_slot and again and again[-1]["i"] == bp_slot and out == "One furnace wooden-chest",
           "copy to: Select new contents puts the area into the same blueprint, its name kept (create_blueprint into the stack)", f"slot {bp_slot}: {out}")
    mod_lua(f"storage.f3d.puppet.get_main_inventory()[{bp_slot or 1}].clear()")
    destroy_units([chest])


def check_planners(c, hello):
    """Blueprints and planners (planners.lua, history.lua): qualities, exchange strings in and out of
    the inventory and the cursor's library stack, the game's and the player's libraries, placing a
    pasted string as ghosts, undo and redo of blueprints, marks, settings and rotations, and
    super-forced building over a tree."""
    report(c.quals and c.quals[0][0] == "normal" and any(q[0] == "legendary" for q in c.quals),
           "quals: the qualities in order (prototypes.quality, force.is_quality_unlocked)", str(c.quals))
    c.send({"t": "bp_lib"})
    msgs = c.pump(2.0, every=hello)
    libs = {m["src"]: m for m in of_type(msgs, "bpl")}
    report("game" in libs, "bp_lib: the game's library (game.blueprints)",
           " | ".join(f"{k} ({v['who']}): {len(v['l'])} records" for k, v in libs.items()))
    if "player" in libs and libs["player"]["l"]:
        rec = libs["player"]["l"][0]
        c.send({"t": "bp_rec", "q": 501, "src": "player", "ix": rec[0]})
        data, first = bp_reply(c, hello, 501, 20.0)
        report(data and "".join(bp_record(data).keys()) in ("blueprint", "blueprint_book", "deconstruction_planner", "upgrade_planner"),
               "bp_rec: a record of the taken-over player's own library (LuaPlayer.blueprints, export_record)",
               f"{rec[1]} '{rec[2]}', {len(data)} characters in {first['parts'] if first else 0} parts")
        big = max(libs["player"]["l"], key=lambda r: 1 if r[1] == "blueprint-book" else 0)
        c.send({"t": "bp_rec", "q": 502, "src": "player", "ix": big[0], "to": -1})
        msgs = c.pump(3.0, every=hello, until=lambda m: m.get("t") == "bp_ok" and m.get("q") == 502)
        ok = [m for m in of_type(msgs, "bp_ok") if m["q"] == 502]
        report(ok and ok[0]["i"] == -1 and ok[0]["item"] == big[1], "bp_rec to -1: a player's record straight into the cursor's stack",
               f"'{big[2]}' ({big[1]})")
    if not clean_spot(c, hello):
        report(False, "planners: no clean spot found")
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    fx = lambda v: int(round(v * 256))
    ghost = c.proto_id("entity-ghost")
    # A taken-over player's personal roboports would build and remove things before they're looked at.
    robots = mod_lua("local c = storage.f3d.puppet local ok, v = pcall(function() return c.allow_dispatching_robots end) "
                     "if ok then c.allow_dispatching_robots = false end rcon.print(tostring(v))")
    # A string made the way websites and the game make them (2.0 format), pasted into the library.
    belt = {"blueprint": {"item": "blueprint", "label": "Live check line", "version": (2 << 48) | (28 << 16),
                          "icons": [{"signal": {"name": "transport-belt"}, "index": 1}],
                          "description": "Made by live_check.py",
                          "entities": [{"entity_number": n + 1, "name": "transport-belt", "position": {"x": n + 0.5, "y": 0.5},
                                        "direction": 4} for n in range(4)]
                          + [{"entity_number": 5, "name": "iron-chest", "position": {"x": 4.5, "y": 0.5}}]}}
    c.send({"t": "bp_set", "q": 510, "i": -1, "s": bp_string(belt)})
    msgs = c.pump(1.0, every=hello)
    ok = [m for m in of_type(msgs, "bp_ok") if m["q"] == 510]
    report(ok and ok[0]["i"] == -1 and ok[0]["item"] == "blueprint", "bp_set -1: a pasted blueprint string into the cursor's stack (import_stack)",
           str(ok))
    c.send({"t": "blueprint", "i": -1, "x": fx(x + 2), "y": fx(y + 6), "d": 0})
    msgs = c.pump(1.5, every=hello)
    ghosts = [m["e"] for m in of_type(msgs, "add") if m["e"][1] == ghost]
    hist = of_type(msgs, "hist")
    report(len(ghosts) == 5 and hist and hist[-1]["what"] == "blueprint",
           "blueprint -1: the pasted string's five ghosts, remembered for undo (hist)", f"{len(ghosts)} ghosts, {hist}")
    if hist:
        c.send({"t": "undo", "h": hist[-1]["h"]})
        msgs = c.pump(1.0, every=hello)
        gone = {(m["x"], m["y"]) for m in of_type(msgs, "del")}
        report(gone >= {(g[2], g[3]) for g in ghosts} and bool(ghosts), "undo: the blueprint's ghosts go (destroy{raise_destroy})",
               f"{len(gone)} removed")
        c.send({"t": "redo", "h": hist[-1]["h"]})
        msgs = c.pump(1.0, every=hello)
        again = [m["e"] for m in of_type(msgs, "add") if m["e"][1] == ghost]
        report(len(again) == 5, "redo: built again from the remembered string", f"{len(again)} ghosts")
        c.send({"t": "undo", "h": hist[-1]["h"]})
        c.pump(0.5, every=hello)
    # Into the inventory and back out: the string the game exports decodes to what went in.
    c.send({"t": "bp_set", "q": 511, "i": 0, "s": bp_string(belt)})
    msgs = c.pump(1.0, every=hello)
    ok = [m for m in of_type(msgs, "bp_ok") if m["q"] == 511]
    slot = ok[0]["i"] if ok else 0
    c.send({"t": "bp_get", "q": 512, "i": slot})
    data, _ = bp_reply(c, hello, 512)
    back = bp_record(data).get("blueprint", {}) if data else {}
    report(slot > 0 and back.get("label") == "Live check line" and len(back.get("entities", [])) == 5
           and back.get("description") == "Made by live_check.py",
           "bp_set 0 then bp_get: a new blueprint in the inventory, exported again (export_stack)", f"slot {slot}: {back.get('label')}")
    edited = {"blueprint": dict(back, label="Edited in 3D", **{"snap-to-grid": {"x": 6, "y": 2}, "absolute-snapping": True})}
    c.send({"t": "bp_set", "q": 513, "i": slot, "s": bp_string(edited)})
    c.pump(0.5, every=hello)
    out = mod_lua(f"local s = storage.f3d.puppet.get_main_inventory()[{slot}] "
                  "rcon.print(tostring(s.label) .. ' ' .. serpent.line(s.blueprint_snap_to_grid) .. ' ' .. tostring(s.blueprint_absolute_snapping))")
    report(out.startswith("Edited in 3D") and "x = 6" in out and out.endswith("true"),
           "bp_set over the slot: label, snap to grid and absolute snapping written back", out)
    mod_lua(f"storage.f3d.puppet.get_main_inventory()[{slot}].clear()")
    # A deconstruction planner made from a string, used, undone and redone.
    out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local out = {{}}
for _, p in pairs({{ {{ {x - 4.5}, {y - 4.5} }}, {{ {x - 3.5}, {y - 4.5} }} }}) do
  local e = s.create_entity({{ name = "wooden-chest", position = p, force = c.force }}) out[#out + 1] = e.unit_number
end
local a = s.create_entity({{ name = "assembling-machine-1", position = {{ {x + 4.5}, {y - 4.5} }}, force = c.force }})
local b = s.create_entity({{ name = "assembling-machine-1", position = {{ {x + 8.5}, {y - 4.5} }}, force = c.force }})
local ins = s.create_entity({{ name = "inserter", position = {{ {x + 0.5}, {y - 4.5} }}, force = c.force }})
a.set_recipe("iron-gear-wheel")
rcon.print(out[1] .. " " .. out[2] .. " " .. a.unit_number .. " " .. b.unit_number .. " " .. ins.unit_number)
""".replace("\n", " "))
    try:
        chest_a, chest_b, asm_a, asm_b, ins = (int(v) for v in out.split())
    except ValueError:
        report(False, "planners: building the test entities", out)
        return
    marked = lambda u: mod_lua(
        f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = {{ 'wooden-chest', 'inserter' }} }})) do "
        f"if e.unit_number == {u} then rcon.print(tostring(e.to_be_deconstructed())) return end end")
    mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'wooden-chest' }})) do "
            f"if e.unit_number == {chest_b} then e.order_deconstruction(e.force) end end")
    planner = {"deconstruction_planner": {"item": "deconstruction-planner", "label": "Chests only", "version": (2 << 48) | (28 << 16),
                                          "settings": {"entity_filters": [{"name": "wooden-chest", "index": 0}]}}}
    c.send({"t": "bp_set", "q": 514, "i": -1, "s": bp_string(planner)})
    c.pump(0.5, every=hello)
    area = {"x1": fx(x - 6), "y1": fx(y - 6), "x2": fx(x + 1.5), "y2": fx(y - 3)}
    c.send({"t": "decon", "i": -1, **area})
    msgs = c.pump(1.0, every=hello)
    hist = of_type(msgs, "hist")
    ins_marked = marked(ins)
    report(marked(chest_a) == "true" and ins_marked == "false" and hist and hist[-1]["what"] == "deconstruction",
           "a deconstruction planner from a string with a chest filter marks the chest, not the inserter", f"inserter {ins_marked}, {hist}")
    if hist:
        c.send({"t": "undo", "h": hist[-1]["h"]})
        c.pump(0.5, every=hello)
        report(marked(chest_a) == "false" and marked(chest_b) == "true", "undo: its own mark goes, the older one stays")
        c.send({"t": "redo", "h": hist[-1]["h"]})
        c.pump(0.5, every=hello)
        report(marked(chest_a) == "true", "redo: marked again (order_deconstruction)")
    # Owner's #20: Alt+D's shortcut and Ctrl+X's cut over ghosts. Factorio deletes them with no event.
    out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local out = {{}}
for _, p in pairs({{ {{ {x - 4.5}, {y + 8.5} }}, {{ {x + 4.5}, {y + 8.5} }} }}) do
  local g = s.create_entity({{ name = "entity-ghost", inner_name = "wooden-chest", position = p, force = c.force }}) out[#out + 1] = g.unit_number
end
rcon.print(out[1] .. " " .. out[2])
""".replace("\n", " "))
    try:
        ghost_a, ghost_b = (int(v) for v in out.split())
    except ValueError:
        report(False, "planners: making two ghosts", out)
        ghost_a = ghost_b = None
    if ghost_a:
        c.send({"t": "decon", "i": 0, "x1": fx(x - 5.5), "y1": fx(y + 7.5), "x2": fx(x - 3.5), "y2": fx(y + 9.5)})
        dels = {d["u"] for d in of_type(c.pump(1.0, every=hello), "del")}
        report(ghost_a in dels, "the deconstruction shortcut (Alt+D) deletes a ghost and sends its del", f"{dels}")
        c.send({"t": "copy", "cut": 1, "bp": 0, "x1": fx(x + 3.5), "y1": fx(y + 7.5), "x2": fx(x + 5.5), "y2": fx(y + 9.5)})
        dels = {d["u"] for d in of_type(c.pump(1.0, every=hello), "del")}
        report(ghost_b in dels, "cut (Ctrl+X) over a ghost deletes it and sends its del", f"{dels}")
    # Owner's #13: a book's icons (LuaItemStack.preview_icons) reach the inventory's slots as `ic`.
    out = mod_lua("""
local inv = storage.f3d.puppet.get_main_inventory() local st, i = inv.find_empty_stack()
st.set_stack({ name = "blueprint-book", count = 1 })
st.preview_icons = { { signal = { name = "iron-plate" }, index = 1 }, { signal = { type = "virtual", name = "signal-A" }, index = 2 } }
rcon.print(i)
""".replace("\n", " "))
    book_at = int(out) if out.isdigit() else 0
    ic = [m.get("ic") for m in of_type(c.pump(1.5, every=hello), "slots")]
    report(book_at and ic and [book_at, [["item", "iron-plate"], ["virtual", "signal-A"]]] in (ic[-1] or []),
           "a book's icons go with the inventory's slots (preview_icons -> ic)", f"slot {out}: {ic[-1:]}")
    if book_at:
        mod_lua(f"storage.f3d.puppet.get_main_inventory()[{book_at}].clear()")
    # Owner's #22: right-click on the map removes the ghost under the point (unghost).
    out = mod_lua(f"""
local c = storage.f3d.puppet
local g = c.surface.create_entity({{ name = "entity-ghost", inner_name = "assembling-machine-1", position = {{ {x + 6.5}, {y + 14.5} }}, force = c.force }})
rcon.print(g.unit_number)
""".replace("\n", " "))
    gu = int(out) if out.isdigit() else 0
    c.send({"t": "unghost", "q": 41, "x": fx(x + 7.4), "y": fx(y + 15.2)})
    msgs = c.pump(1.0, every=hello)
    answers = [(m["q"], m["n"]) for m in of_type(msgs, "unghost")]
    report(gu and answers == [(41, 1)] and gu in {d["u"] for d in of_type(msgs, "del")},
           "unghost removes the 3x3 ghost under a point near its corner and sends its del", f"{out}: {answers}")
    c.send({"t": "unghost", "q": 42, "x": fx(x + 30.5), "y": fx(y + 30.5)})
    answers = [(m["q"], m["n"]) for m in of_type(c.pump(1.0, every=hello), "unghost")]
    report(answers == [(42, 0)], "unghost where there is no ghost answers n = 0", f"{answers}")
    # Owner's C10: the map's copper wires between poles (chart ov "w").
    out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface
local a = s.create_entity({{ name = "small-electric-pole", position = {{ {x - 14.5}, {y + 18.5} }}, force = c.force }})
local b = s.create_entity({{ name = "small-electric-pole", position = {{ {x - 9.5}, {y + 18.5} }}, force = c.force }})
a.get_wire_connector(defines.wire_connector_id.pole_copper, true).connect_to(b.get_wire_connector(defines.wire_connector_id.pole_copper, true))
rcon.print(a.unit_number .. " " .. b.unit_number)
""".replace("\n", " "))
    poles = [int(v) for v in out.split()] if all(v.isdigit() for v in out.split()) and out else []
    ax, ay = x - 14.5, y + 18.5
    cx, cy = int(ax // 32), int(ay // 32)
    c.send({"t": "map", "cx1": cx - 1, "cy1": cy - 1, "cx2": cx + 1, "cy2": cy + 1, "res": 4})
    charts = of_type(c.pump(2.0, every=hello), "chart")
    wires = [r for m in charts for r in m.get("ov", []) if r[0] == "w"]
    near = lambda r: abs(r[1] - fx(ax)) <= 256 and abs(r[2] - fx(ay)) <= 256 and abs(r[3] - fx(x - 9.5)) <= 256 and abs(r[4] - fx(ay)) <= 256
    report(poles and any(near(r) for r in wires), "the map's charts carry the copper wire between two poles (ov w, poles snapped to tiles)",
           f"{out}: {wires[:4]}")
    if poles:
        destroy_units(poles)
    # Owner's C12: a chart carries its chunk's pollution (pol).
    px_, py_ = x + 40, y + 40
    mod_lua(f"local c = storage.f3d.puppet c.surface.pollute({{ {px_}, {py_} }}, 777)")
    pcx, pcy = int(px_ // 32), int(py_ // 32)
    c.send({"t": "map", "cx1": pcx, "cy1": pcy, "cx2": pcx, "cy2": pcy, "res": 32})
    pols = [m.get("pol") for m in of_type(c.pump(1.5, every=hello), "chart") if (m["cx"], m["cy"]) == (pcx, pcy)]
    report(pols and pols[-1] is not None and pols[-1] >= 700, "a chart carries its chunk's pollution (LuaSurface.get_pollution)", f"{pols}")
    # Owner's #23: a filter inserter's Alt-mode icon carries every filter.
    out = mod_lua(f"""
local c = storage.f3d.puppet
local e = c.surface.create_entity({{ name = "fast-inserter", position = {{ {x + 0.5}, {y + 11.5} }}, force = c.force }})
e.use_filters = true e.set_filter(2, "iron-plate") e.set_filter(4, "copper-plate") e.set_filter(5, "coal")
rcon.print(e.unit_number)
""".replace("\n", " "))
    fins = int(out) if out.isdigit() else 0
    c.send({"t": "alt", "on": 1})
    ai = of_type(c.pump(2.5, every=hello), "ai")
    c.send({"t": "alt", "on": 0})
    rows = [r for r in (ai[-1]["l"] if ai else []) if r[0] == fins]
    report(fins and rows == [[fins, "item", "iron-plate", ["copper-plate", "coal"]]],
           "a filter inserter's Alt-mode icon carries all its filters (get_filter 1..filter_slot_count)", f"{out}: {rows}")
    if fins:
        destroy_units([fins])
    # Settings pasted, undone through a one-entity blueprint built over it.
    asm = c.proto_id("assembling-machine-1")
    ident = lambda u, px, py, name: {"u": u, "p": c.proto_id(name), "x": fx(px), "y": fx(py)}
    c.send({"t": "paste_settings", "f": [asm_a, asm, fx(x + 4.5), fx(y - 4.5)], **ident(asm_b, x + 8.5, y - 4.5, "assembling-machine-1")})
    msgs = c.pump(1.0, every=hello)
    hist = [h for h in of_type(msgs, "hist") if h["what"] == "settings"]
    recipe = lambda u: mod_lua(
        f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'assembling-machine-1' }})) do "
        f"if e.unit_number == {u} then local r = e.get_recipe() rcon.print(r and r.name or 'none') return end end")
    report(recipe(asm_b) == "iron-gear-wheel" and hist, "paste_settings is remembered with a snapshot before and after", str(hist))
    if hist:
        c.send({"t": "undo", "h": hist[-1]["h"]})
        c.pump(0.8, every=hello)
        r_undo = recipe(asm_b)
        c.send({"t": "redo", "h": hist[-1]["h"]})
        c.pump(0.8, every=hello)
        r_redo = recipe(asm_b)
        report(r_undo == "none" and r_redo == "iron-gear-wheel", "undo / redo of pasted settings (a blueprint built over the entity)",
               f"after undo: {r_undo}, after redo: {r_redo}")
    # A rotation undone.
    d0 = mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'inserter' }})) do "
                 f"if e.unit_number == {ins} then rcon.print(e.direction) return end end")
    c.send({"t": "rotate", **ident(ins, x + 0.5, y - 4.5, "inserter"), "rev": 0})
    msgs = c.pump(0.8, every=hello)
    hist = [h for h in of_type(msgs, "hist") if h["what"] == "rotation"]
    if hist:
        c.send({"t": "undo", "h": hist[-1]["h"]})
        c.pump(0.5, every=hello)
    d1 = mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'inserter' }})) do "
                 f"if e.unit_number == {ins} then rcon.print(e.direction) return end end")
    report(hist and d0 == d1, "a rotation is remembered and undone", f"{d0} -> {d1}")
    # Super-forced build over a tree: the ghost goes there, the tree is marked for deconstruction.
    # A rock does on any planet (Vulcanus has no trees).
    out = mod_lua(f"local s = storage.f3d.puppet.surface local t = s.create_entity({{ name = 'big-rock', position = {{ {x - 6.5}, {y + 2.5} }} }}) "
                  "rcon.print(t and 'ok' or 'no')")
    c.send({"t": "build", "item": "stone-furnace", "x": fx(x - 6.5), "y": fx(y + 2.5), "d": 0, "ghost": 1, "sf": 1})
    msgs = c.pump(1.0, every=hello)
    furnace = c.proto_id("stone-furnace")
    sf = [m["e"] for m in of_type(msgs, "add") if m["e"][1] == ghost and m["e"][5].get("gh") == furnace]
    tree = mod_lua(f"local s = storage.f3d.puppet.surface local t = s.find_entities_filtered({{ name = 'big-rock', position = {{ {x - 6.5}, {y + 2.5} }}, radius = 1.5 }})[1] "
                   "rcon.print(t and tostring(t.to_be_deconstructed()) or 'gone')")
    report(out == "ok" and sf and tree == "true", "super-forced build: a ghost over a rock, the rock marked for deconstruction",
           f"rock made: {out}, ghost at {[(g[2] / 256, g[3] / 256) for g in sf]} for ({x - 6.5}, {y + 2.5}), tree marked: {tree}")
    destroy_units([chest_a, chest_b, asm_a, asm_b, ins] + [g[0] for g in sf])
    check_planner_modes(c, hello, x, y, fx, ghost)
    check_flips(c, hello)
    if robots == "true":
        mod_lua("storage.f3d.puppet.allow_dispatching_robots = true")


def game_tiles(x0, y0, x1, y1):
    """{(x, y): tile name} for a rectangle of tiles, from the game."""
    out = mod_lua(f"local s = storage.f3d.puppet.surface local o = {{}} for y = {y0}, {y1} do for x = {x0}, {x1} do "
                  "o[#o + 1] = x .. ',' .. y .. ',' .. s.get_tile(x, y).name end end rcon.print(table.concat(o, ' '))")
    return {(int(a), int(b)): n for a, b, n in (v.split(",") for v in out.split())}


def rail_path(start, d, steps):
    """Pieces from a rail end by the client's table (client/data/rail_extensions.json): `steps`
    picks which extension at each end (its index in the table's list)."""
    table = json.loads((pathlib.Path(__file__).resolve().parent.parent / "client" / "data" / "rail_extensions.json").read_text())
    pieces, pos = [], start
    for k in steps:
        e = table["ext"][str(d)][k]
        pieces.append([e[0], pos[0] + e[2], pos[1] + e[3], e[1]])
        pos, d = (pos[0] + e[5], pos[1] + e[6]), e[4]
    return pieces, pos, d


def inv_count(item):
    return int(mod_lua(f"rcon.print(storage.f3d.puppet.get_main_inventory().get_item_count('{item}'))") or 0)


def check_build_tools(c, hello):
    """Tiles (tiles.lua), capsules (capsules.lua), the rail planner (rail_planner.lua) and what drag
    building sends (undergrounds and pipes-to-ground over obstacles, poles at wire reach)."""
    iuse = c.iuse
    tid = c.tiles
    con, land, gren, cliff = (iuse.get(k) for k in (("concrete", "t"), ("landfill", "t"), ("grenade", "c"), ("cliff-explosives", "c")))
    report(con and tid["grass-1"] in con[4] and tid["water"] not in con[4] and land and tid["water"] in land[4]
           and tid["grass-1"] not in land[4] and iuse.get(("hazard-concrete", "t"), [0, 0, 0, ""])[3] == "hazard-concrete-right"
           and gren and gren[2] == "throw" and gren[3] == 15 and cliff and cliff[2:] == ["destroy-cliffs", 10, 1.5]
           and iuse.get(("rail", "r"), [0, 0, ""])[2] == "rail-support" and ("rail-ramp", "r") not in iuse
           and iuse.get(("transport-belt", "b"), [0, 0, ""])[2] == "underground-belt"
           and iuse.get(("pipe", "p"), [0, 0, ""])[2] == "pipe-to-ground",
           "iuse: place_as_tile_result (condition, tile_condition), hazard concrete's next_direction, capsule_action, "
           "the rail planner's support, related_underground_belt", f"{con and con[:4]} {land and land[:4]} {gren} {cliff}")

    if not clean_spot(c, hello, half=16):
        report(False, "build tools: no clean spot found", SPOT_WHY)
        return
    fx = lambda v: int(round(v * 256))
    x, y = c.me["x"] / 256, c.me["y"] / 256
    bx, by = math.floor(x), math.floor(y)
    mod_lua('local c = storage.f3d.puppet for _, s in pairs({ { "concrete", 20 }, { "stone-brick", 5 }, { "landfill", 5 }, '
            '{ "hazard-concrete", 5 }, { "grenade", 3 }, { "cliff-explosives", 2 }, { "raw-fish", 2 }, { "land-mine", 2 }, '
            '{ "rail", 60 }, { "rail-ramp", 1 }, { "rail-support", 6 }, { "transport-belt", 20 }, { "underground-belt", 4 }, '
            '{ "pipe", 20 }, { "pipe-to-ground", 4 }, { "small-electric-pole", 6 }, { "wooden-chest", 4 } }) do '
            'c.get_main_inventory().remove({ name = s[1], count = 100000 }) c.insert({ name = s[1], count = s[2] }) end')
    c.pump(1.0, every=hello)
    # --- what drag building sends ---------------------------------------------------------------
    # Belts east with a chest in the way: the client sends belts, then an underground over the last
    # belt before the chest and one past it; the mod makes them entrance and exit.
    dy_ = by + 2
    mod_lua(f"storage.f3d.puppet.surface.create_entity({{ name = 'wooden-chest', position = {{ {bx + 3.5}, {dy_ + 0.5} }}, force = 'player' }})")
    for k in range(0, 3):
        c.send({"t": "build", "item": "transport-belt", "x": fx(bx + k + 0.5), "y": fx(dy_ + 0.5), "d": 4})
    c.send({"t": "build", "item": "underground-belt", "x": fx(bx + 2.5), "y": fx(dy_ + 0.5), "d": 4})
    c.send({"t": "build", "item": "underground-belt", "x": fx(bx + 5.5), "y": fx(dy_ + 0.5), "d": 4})
    c.pump(1.5, every=hello)
    out = mod_lua(f"local o = {{}} for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ type = {{ 'transport-belt', 'underground-belt' }}, "
                  f"area = {{ {{ {bx}, {dy_} }}, {{ {bx + 7}, {dy_ + 1} }} }} }})) do o[#o + 1] = e.position.x - {bx} .. e.type:sub(1, 1) .. "
                  "(e.type == 'underground-belt' and e.belt_to_ground_type:sub(1, 1) or '') end table.sort(o) rcon.print(table.concat(o, ' '))")
    report(out == "0.5t 1.5t 2.5ui 5.5uo", "smart belt drag: the last belt becomes the underground entrance (fast-replace) "
           "and the one past the chest its exit", out)
    # Pipes east over a chest: pipe-to-ground facing back at the entrance, forward at the exit.
    py_ = by + 4
    mod_lua(f"storage.f3d.puppet.surface.create_entity({{ name = 'wooden-chest', position = {{ {bx + 2.5}, {py_ + 0.5} }}, force = 'player' }})")
    c.send({"t": "build", "item": "pipe", "x": fx(bx + 0.5), "y": fx(py_ + 0.5), "d": 0})
    c.send({"t": "build", "item": "pipe-to-ground", "x": fx(bx + 1.5), "y": fx(py_ + 0.5), "d": 12})
    c.send({"t": "build", "item": "pipe-to-ground", "x": fx(bx + 4.5), "y": fx(py_ + 0.5), "d": 4})
    c.send({"t": "build", "item": "pipe", "x": fx(bx + 5.5), "y": fx(py_ + 0.5), "d": 0})
    c.pump(1.5, every=hello)
    out = mod_lua(f"local s = storage.f3d.puppet.surface local a = s.find_entities_filtered({{ name = 'pipe', position = {{ {bx + 0.5}, {py_ + 0.5} }} }})[1] "
                  f"local b = s.find_entities_filtered({{ name = 'pipe', position = {{ {bx + 5.5}, {py_ + 0.5} }} }})[1] "
                  "rcon.print(a and b and tostring(a.get_fluid_segment_id(1) == b.get_fluid_segment_id(1)) or 'missing')")
    report(out == "true", "pipe drag: pipe-to-ground pair facing back (entrance) and forward (exit) joins the pipes either side "
           "into one fluid segment", out)
    # Poles along a line at the small pole's wire reach (7.5): 7 tiles apart, wired.
    ly = by - 9
    for k in (0, 7, 14):
        c.send({"t": "build", "item": "small-electric-pole", "x": fx(bx - 7 + k + 0.5), "y": fx(ly + 0.5), "d": 0})
    c.pump(1.5, every=hello)
    out = mod_lua(f"local o = {{}} for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'small-electric-pole', "
                  f"area = {{ {{ {bx - 8}, {ly} }}, {{ {bx + 9}, {ly + 1} }} }} }})) do local n = 0 "
                  "for _, con in pairs(e.get_wire_connector(defines.wire_connector_id.pole_copper, true).connections) do n = n + 1 end "
                  "o[#o + 1] = n end table.sort(o) rcon.print(table.concat(o, ' '))")
    report(out == "1 1 2", "pole drag: poles 7 tiles apart (the client's spacing at a 7.5 wire reach) connect in a line", out)
    for area in ((bx - 8, ly, bx + 9, ly + 1), (bx, dy_, bx + 7, py_ + 1)):
        mod_lua(f"local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({{ area = {{ {{ {area[0]}, {area[1]} }}, "
                f"{{ {area[2]}, {area[3]} }} }}, force = c.force }})) do if e ~= c then e.destroy() end end")

    before = game_tiles(bx + 1, by - 6, bx + 5, by - 2)

    # --- tiles ---------------------------------------------------------------------------------
    mod_lua(f"storage.f3d.puppet.surface.set_tiles({{ {{ name = 'stone-path', position = {{ {bx + 2}, {by - 5} }} }} }})")
    c.send({"t": "tile", "item": "concrete", "x": fx(bx + 2.5), "y": fx(by - 3.5), "n": 3})
    msgs = c.pump(1.5, every=hello)
    flat = [v for m in of_type(msgs, "tiles") for v in m["l"]]
    sent = {(flat[i], flat[i + 1]): flat[i + 2] for i in range(0, len(flat), 3)}
    now = game_tiles(bx + 1, by - 6, bx + 5, by - 2)
    want = {(bx + dx, by + dy) for dx in (1, 2, 3) for dy in (-5, -4, -3)}
    report(all(now[p] == "concrete" for p in want) and all(sent.get(p) == tid["concrete"] for p in want)
           and inv_count("concrete") == 11 and inv_count("stone-brick") == 6,
           "tile: a 3x3 brush of concrete (surface.set_tiles raising script_raised_set_tiles: `tiles` sent), 9 used, "
           "the stone path under it handed back", f"{sorted(set(now.values()))} sent {len(sent)} inv {inv_count('concrete')} {inv_count('stone-brick')}")
    c.send({"t": "tile", "item": "hazard-concrete", "x": fx(bx + 4.5), "y": fx(by - 2.5), "n": 1, "r": 1})
    c.pump(1.0, every=hello)
    report(game_tiles(bx + 4, by - 3, bx + 4, by - 3).get((bx + 4, by - 3)) == "hazard-concrete-right",
           "tile r: 1 lays hazard concrete's other direction (next_direction)")
    c.send({"t": "tile_mine", "x": fx(bx + 2.5), "y": fx(by - 3.5), "n": 3})
    c.send({"t": "tile_mine", "x": fx(bx + 4.5), "y": fx(by - 2.5), "n": 1})
    msgs = c.pump(1.5, every=hello)
    flat = [v for m in of_type(msgs, "tiles") for v in m["l"]]
    now = game_tiles(bx + 1, by - 6, bx + 5, by - 2)
    back = {p: now[p] for p in want}
    # Concrete over the stone path doesn't keep the path under it (set_tiles: a mineable tile over a
    # mineable one leaves the hidden tile alone), which is why the brick came back above.
    report(all(now[p] == before[p] for p in want) and inv_count("concrete") == 20 and inv_count("hazard-concrete") == 5
           and len(flat) >= 30, "tile_mine: LuaControl.mine_tile takes the concrete back and the ground it was laid on returns",
           f"{back} inv {inv_count('concrete')} sent {len(flat) // 3}")

    # Tile ghosts, and landfill on water made for the test.
    c.send({"t": "tile", "item": "concrete", "x": fx(bx - 3.5), "y": fx(by - 4.5), "n": 2, "ghost": 1})
    msgs = c.pump(1.5, every=hello)
    ghosts = [m["e"] for m in of_type(msgs, "add") if m["e"][1] == c.proto_id("tile-ghost")]
    report(len(ghosts) == 4 and all(g[5].get("tg") == tid["concrete"] for g in ghosts) and inv_count("concrete") == 20,
           "tile ghost: tile-ghost entities sent (extra.tg the tile), no items used", str(ghosts[:1]))
    c.send({"t": "tile_mine", "x": fx(bx - 3.5), "y": fx(by - 4.5), "n": 2})
    msgs = c.pump(1.0, every=hello)
    left = mod_lua(f"rcon.print(storage.f3d.puppet.surface.count_entities_filtered({{ type = 'tile-ghost', "
                   f"area = {{ {{ {bx - 6}, {by - 7} }}, {{ {bx}, {by - 2} }} }} }}))")
    report(len(of_type(msgs, "del")) >= 4 and left == "0", "tile_mine removes tile ghosts under the brush",
           f"{len(of_type(msgs, 'del'))} del, {left} left")
    mod_lua(f"storage.f3d.puppet.surface.set_tiles({{ {{ name = 'water', position = {{ {bx - 4}, {by + 3} }} }}, "
            f"{{ name = 'water', position = {{ {bx - 3}, {by + 3} }} }} }})")
    c.send({"t": "tile", "item": "landfill", "x": fx(bx - 3), "y": fx(by + 3.5), "n": 2})
    c.send({"t": "tile", "item": "concrete", "x": fx(bx - 3), "y": fx(by + 4.5), "n": 1})
    c.pump(1.5, every=hello)
    t = game_tiles(bx - 4, by + 2, bx - 3, by + 4)
    report(t[(bx - 4, by + 3)] == "landfill" and t[(bx - 3, by + 3)] == "landfill" and t[(bx - 4, by + 2)] != "landfill"
           and inv_count("landfill") == 3, "landfill only goes on the water under the brush (its condition)", str(t))

    # --- capsules and land mines ---------------------------------------------------------------
    c.send({"t": "throw", "item": "grenade", "x": fx(x + 6), "y": fx(y + 6)})
    msgs = c.pump(1.0, every=hello)
    proj = mod_lua(f"rcon.print(storage.f3d.puppet.surface.count_entities_filtered({{ type = 'projectile', position = {{ {x}, {y} }}, radius = 20 }}))")
    c.send({"t": "throw", "item": "grenade", "x": fx(x + 40), "y": fx(y)})
    msgs += c.pump(1.0, every=hello)
    report(inv_count("grenade") == 2 and any(m["text"] == "Out of range" for m in of_type(msgs, "msg")),
           "throw: a grenade at the cursor (LuaItemStack.use_capsule, one used), none out of its range", f"projectiles {proj}, inv {inv_count('grenade')}")
    out = mod_lua(f"local c = storage.f3d.puppet local e = c.surface.create_entity({{ name = 'cliff', position = {{ {bx + 6}, {by + 5} }}, "
                  "cliff_orientation = 'west-to-east' }) rcon.print(e and (e.position.x .. ' ' .. e.position.y) or 'none')")
    if out != "none":
        cx_, cy_ = (float(v) for v in out.split())
        c.send({"t": "throw", "item": "cliff-explosives", "x": fx(cx_), "y": fx(cy_)})
        c.pump(4.0, every=hello)
        left = mod_lua(f"rcon.print(storage.f3d.puppet.surface.count_entities_filtered({{ type = 'cliff', position = {{ {cx_}, {cy_} }}, radius = 3 }}))")
        report(left == "0" and inv_count("cliff-explosives") == 1, "cliff explosives thrown at a cliff blow it up",
               f"cliffs left {left}, inv {inv_count('cliff-explosives')}")
    else:
        report(False, "cliff explosives: couldn't make a cliff for the test")
    hp = mod_lua("local c = storage.f3d.puppet c.health = c.health - 60 rcon.print(c.health)")
    c.send({"t": "throw", "item": "raw-fish", "x": fx(x + 3), "y": fx(y)})
    c.pump(1.5, every=hello)
    hp2 = mod_lua("rcon.print(storage.f3d.puppet.health)")
    report(float(hp2) > float(hp) and inv_count("raw-fish") == 1, "raw fish (use-on-self) heals the character", f"{hp} -> {hp2}")
    c.send({"t": "build", "item": "land-mine", "x": fx(bx + 2.5), "y": fx(by + 6.5), "d": 0})
    c.pump(1.0, every=hello)
    report(mod_lua(f"rcon.print(storage.f3d.puppet.surface.count_entities_filtered({{ name = 'land-mine', position = {{ {bx + 2.5}, {by + 6.5} }}, radius = 1 }}))") == "1",
           "a land mine is built like any entity")

    # Super-forced build (Ctrl+Shift+click): a ghost over a tree, the tree marked for deconstruction.
    mod_lua(f"storage.f3d.puppet.surface.create_entity({{ name = 'tree-01', position = {{ {bx - 12.5}, {by + 3.5} }} }})")
    c.send({"t": "build", "item": "wooden-chest", "x": fx(bx - 12.5), "y": fx(by + 3.5), "d": 0, "ghost": 1, "sf": 1})
    c.pump(1.0, every=hello)
    out = mod_lua(f"local s = storage.f3d.puppet.surface local t = s.find_entities_filtered({{ type = 'tree', position = {{ {bx - 12.5}, {by + 3.5} }}, radius = 1 }})[1] "
                  f"rcon.print(tostring(t and t.to_be_deconstructed()) .. ' ' .. s.count_entities_filtered({{ ghost_name = 'wooden-chest', position = {{ {bx - 12.5}, {by + 3.5} }}, radius = 0.6 }}))")
    report(out == "true 1", "super-forced build: the ghost goes over the tree, which is marked for deconstruction", out)

    # --- the rail planner ----------------------------------------------------------------------
    # A straight rail east of the character, then a path from its north end: straight, curve,
    # half-diagonal, by the client's extension table; every piece must join the one before.
    rx, ry = math.floor((x + 6) / 2) * 2 + 1, math.floor((y + 8) / 2) * 2 + 1
    c.send({"t": "rails", "item": "rail", "l": [["straight-rail", fx(rx), fx(ry), 0]]})
    c.pump(0.8, every=hello)
    pieces, end, end_dir = rail_path((rx, ry - 1), 0, [0, 0, 1, 0, 2])
    names = [p[0] for p in pieces]
    rails_before = inv_count("rail")
    c.send({"t": "rails", "item": "rail", "l": [[n, fx(px), fx(py), d] for n, px, py, d in pieces]})
    msgs = c.pump(1.5, every=hello)
    out = mod_lua(f"""
local s = storage.f3d.puppet.surface local o = {{}}
for _, p in pairs({{ {', '.join(f'{{ "{n}", {px}, {py}, {d} }}' for n, px, py, d in pieces)} }}) do
  local e = s.find_entities_filtered({{ name = p[1], position = {{ p[2], p[3] }} }})[1]
  o[#o + 1] = e and (e.direction == p[4] and "ok" or "dir" .. e.direction) or "missing"
end
local first = s.find_entities_filtered({{ name = 'straight-rail', position = {{ {rx}, {ry} }} }})[1]
local en = first.get_rail_end(defines.rail_direction.front)
local n = 0
for i = 1, {len(pieces)} do if en.move_forward(defines.rail_connection_direction.straight) or en.move_forward(defines.rail_connection_direction.left) or en.move_forward(defines.rail_connection_direction.right) then n = n + 1 end end
rcon.print(table.concat(o, ",") .. " joined " .. n)
""".replace("\n", " "))
    cost = {"straight-rail": 1, "half-diagonal-rail": 2, "curved-rail-a": 3, "curved-rail-b": 3}
    report(out == ",".join(["ok"] * len(pieces)) + f" joined {len(pieces)}"
           and rails_before - inv_count("rail") == sum(cost[n] for n in names),
           "rails: the planner's path (straight, curve, half-diagonal from rail_extensions.json) is built where the client "
           "said, every piece joined to the last (LuaRailEnd.move_forward), paid in rails (items_to_place_this)",
           f"{names}: {out}, rails {rails_before} -> {inv_count('rail')}")
    # Too few rails: the rest are ghosts.
    mod_lua(f"local inv = storage.f3d.puppet.get_main_inventory() inv.remove({{ name = 'rail', count = inv.get_item_count('rail') - 2 }})")
    more, end2, _ = rail_path(end, end_dir, [0, 0, 0, 0])
    c.send({"t": "rails", "item": "rail", "l": [[n, fx(px), fx(py), d] for n, px, py, d in more]})
    msgs = c.pump(1.5, every=hello)
    adds = [m["e"] for m in of_type(msgs, "add")]
    real = [a for a in adds if a[1] != c.proto_id("entity-ghost")]
    ghosts = [a for a in adds if a[1] == c.proto_id("entity-ghost")]
    report(len(real) + len(ghosts) == len(more) and len(ghosts) >= 1 and any("placed as ghosts" in m["text"] for m in of_type(msgs, "msg")),
           "rails: past the rails in the inventory (or reach) the pieces are ghosts", f"{len(real)} built, {len(ghosts)} ghosts of {more}")
    c.send({"t": "rails", "item": "rail", "l": [["wooden-chest", fx(rx), fx(ry - 30), 0]]})
    report(any(m["text"].startswith("Can't build that") for m in of_type(c.pump(0.8, every=hello), "msg")),
           "rails: only what the planner builds (its rails and support)")

    # Elevated: a ramp from a ground rail end, elevated rails on supports. Needs the research.
    mod_lua("storage.f3d.puppet.force.rail_planner_allow_elevated_rails = true "
            "storage.f3d.puppet.insert({ name = 'rail', count = 40 })")
    ex, ey = rx - 12, ry  # clear of the character: a ramp is 4 tiles wide and 16 long
    mod_lua(f"storage.f3d.puppet.teleport({{ {ex + 2.6}, {ey - 11} }})")  # all of it within reach, beside the ramp
    ground_rail = ["straight-rail", fx(ex), fx(ey), 0]
    ramp = ["rail-ramp", fx(ex), fx(ey - 9), 0]  # the ramp's ground end is 8 south of its centre
    elev, eend, _ = rail_path((ex, ey - 17), 0, [0, 0, 0])  # elevated straight rails north of the ramp's top
    elev = [["elevated-" + n, fx(px), fx(py), d] for n, px, py, d in elev]
    support = ["rail-support", fx(ex), fx(ey - 22), 0]
    c.send({"t": "rails", "item": "rail", "l": [ground_rail, support, ramp] + elev})
    msgs = c.pump(2.0, every=hello)
    out = mod_lua(f"local s = storage.f3d.puppet.surface rcon.print(s.count_entities_filtered({{ name = {{ 'rail-ramp', "
                  f"'elevated-straight-rail', 'rail-support' }}, area = {{ {{ {ex - 3}, {ey - 30} }}, {{ {ex + 3}, {ey} }} }} }}) .. ' ' .. "
                  f"s.count_entities_filtered({{ type = 'entity-ghost', area = {{ {{ {ex - 3}, {ey - 30} }}, {{ {ex + 3}, {ey} }} }} }}))")
    report(out == f"{2 + len(elev)} 0", "rails: a ramp and elevated rails over a support, all built (supports first: an elevated "
           "rail needs one in range along the track)", f"real, ghosts: {out}; {[m['text'] for m in of_type(msgs, 'msg')]}")

    mod_lua(f"storage.f3d.puppet.teleport({{ {x}, {y} }})")
    # Leave the spot empty for the next run (the rails reach past the clean square).
    mod_lua(f"local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({{ area = {{ {{ {bx - 24}, {by - 40} }}, "
            f"{{ {bx + 24}, {by + 24} }} }}, force = c.force }})) do if e ~= c then e.destroy() end end")


def check_info(c, hello):
    """Alerts (alerts.lua), Factoriopedia (pedia.lua), the logistic networks window, statistics and
    technology details."""
    # Factoriopedia: the index and pages, from prototypes.
    c.send({"t": "pedia_index"})
    msgs = c.pump(8, every=hello, until=lambda m: m.get("t") == "pidx" and m["part"] == m["parts"])
    pidx = of_type(msgs, "pidx")
    entries = [r for m in pidx for r in m["l"]]
    kinds = {}
    for r in entries:
        kinds[r[0]] = kinds.get(r[0], 0) + 1
    names = {(r[0], r[1]) for r in entries}
    report(pidx and pidx[-1]["part"] == pidx[-1]["parts"] and len(pidx) == pidx[-1]["parts"]
           and {("item", "iron-plate"), ("fluid", "water"), ("technology", "automation"), ("planet", "vulcanus"),
                ("quality", "legendary"), ("entity", "small-biter"), ("tile", "water")} <= names
           and ("entity", "assembling-machine-1") not in names,
           "pidx: Factoriopedia's index (items, fluids, entities without an item, tiles, recipes, technologies, planets, qualities)",
           f"{len(entries)} entries in {len(pidx)} parts: {kinds}, {len(pidx[0].get('g', [])) if pidx else 0} groups")
    pages = [("item", "assembling-machine-2"), ("item", "iron-plate"), ("item", "coal"), ("fluid", "crude-oil"),
             ("recipe", "electronic-circuit"), ("technology", "mining-productivity-3"), ("technology", "steam-power"),
             ("entity", "small-biter"), ("tile", "water"), ("planet", "vulcanus"), ("quality", "legendary"),
             ("item", "speed-module"), ("entity", "iron-ore"), ("item", "no-such-thing")]
    for kind, name in pages:
        c.send({"t": "pedia", "kind": kind, "name": name})
    msgs = c.pump(3, every=hello)
    got = {(m["kind"], m["name"]): m for m in of_type(msgs, "pedia")}
    d = lambda k, n: got.get((k, n), {}).get("d", {})
    am2 = d("item", "assembling-machine-2").get("entity", {})
    report(am2.get("craft") == 0.75 and am2.get("modules") == 2 and 140000 < am2.get("energy", 0) < 160000
           and am2.get("hp") == 350 and am2.get("etype") == "electric" and "electronic-circuit" in am2.get("recipes", []),
           "pedia: a machine's speed, energy use, modules, health and recipes", str({k: am2.get(k) for k in ("craft", "modules", "energy", "drain", "hp", "poll", "res")}))
    plate = d("item", "iron-plate")
    report(plate.get("stack") == 100 and "iron-plate" in plate.get("made", []) and "iron-gear-wheel" in plate.get("used", []),
           "pedia: an item's stack size, made by, used in", f"stack {plate.get('stack')}, made {plate.get('made')}, used {len(plate.get('used', []))}")
    coal = d("item", "coal")
    report(coal.get("fuel") == 4000000 and "chemical" in coal.get("fcat", []) and "coal" in coal.get("mined", []),
           "pedia: fuel value and category, mined from", str({k: coal.get(k) for k in ("fuel", "fcat", "mined")}))
    ec = d("recipe", "electronic-circuit")
    report(["item", "copper-cable", 3] in ec.get("ing", []) and "assembling-machine-1" in ec.get("made_in", [])
           and ec.get("unlocked") == ["electronics"] if ec.get("unlocked") else "assembling-machine-1" in ec.get("made_in", []),
           "pedia: a recipe's ingredients, made in, unlocked by", str({k: ec.get(k) for k in ("ing", "prod", "time", "made_in", "unlocked")}))
    mp = d("technology", "mining-productivity-3")
    sp = d("technology", "steam-power")
    report(mp.get("max_level", 0) >= 4294967295 and mp.get("formula"), "pedia: an infinite technology's max level and cost formula",
           str({k: mp.get(k) for k in ("level", "max_level", "formula", "count", "effects")}))
    report(sp.get("trigger") and sp["trigger"][0] != "", "pedia: a trigger technology's trigger", str(sp.get("trigger")))
    biter = d("entity", "small-biter")
    report(biter.get("hp") == 15 and biter.get("type") == "unit", "pedia: an enemy's health and resistances", str({k: biter.get(k) for k in ("hp", "res", "speed")}))
    water = d("tile", "water")
    vul = d("planet", "vulcanus")
    leg = d("quality", "legendary")
    report(water.get("fluid") == "water" and vul.get("props", {}).get("pressure") == 4000 and leg.get("level") == 5 and vul.get("links"),
           "pedia: a tile's fluid, a planet's properties and connections, a quality's level",
           f"water {water.get('fluid')}, vulcanus {vul.get('props')} {vul.get('links')}, legendary {leg.get('level')} {leg.get('mult')}")
    report(d("item", "speed-module").get("module") and got.get(("item", "no-such-thing"), {}).get("found") == 0,
           "pedia: a module's effects; an unknown page answers found 0", str(d("item", "speed-module").get("module")))
    ore = d("entity", "iron-ore")
    report(ore.get("mine") and ore["mine"][0][1] == "iron-ore", "pedia: a resource's mining result", str(ore.get("mine")))
    sizes = {k: v for k, v in c.max_size.items() if k in ("pidx", "pedia")}
    report(max(sizes.values() or [0]) < 60000, "pedia messages fit a datagram", str(sizes))

    # Technologies: effects, levels, trigger details, saved progress.
    c.send({"t": "hello", "v": 1, "sid": c.sid, "w": 1})
    rcon_out = mod_lua("storage.f3d.techs_dirty = true rcon.print('ok')")
    # A big save's technologies come in several parts, behind the Factoriopedia pages.
    msgs = c.pump(20, every=hello, until=lambda m: m.get("t") == "techs" and m["part"] == m["parts"])
    techs = {r[0]: r for m in of_type(msgs, "techs") for r in m["l"]}
    infinite = [r for r in techs.values() if len(r) == 15 and r[10] == -1]
    trig = [r for r in techs.values() if len(r) == 15 and r[11]]
    unlock = techs.get("automation", [])
    essential = [r[0] for r in techs.values() if len(r) == 15 and r[14] == 1]
    report(techs and all(len(r) == 15 for r in techs.values()) and infinite and trig and 0 < len(essential) < len(techs)
           and ["unlock-recipe", "assembling-machine-1", 0] in (unlock[8] if len(unlock) == 15 else []),
           "techs: effects, levels (infinite ones), trigger details, saved progress, essential", f"{len(techs)} technologies, "
           f"{len(essential)} essential, "
           f"{len(infinite)} infinite (e.g. {infinite[0][0] if infinite else '-'} level {infinite[0][9] if infinite else '-'}), "
           f"{len(trig)} triggered (e.g. {trig[0][0] + ' ' + str(trig[0][11]) if trig else '-'}), {rcon_out}")

    # Statistics: building counts, pollution, all surfaces, graph lines.
    c.send({"t": "stats", "kind": "build", "prec": 8})
    c.send({"t": "stats", "kind": "pollution", "prec": 4, "g": []})
    c.send({"t": "stats", "kind": "item", "prec": 4, "si": 0, "g": ["iron-plate"]})
    c.send({"t": "stats", "kind": "fluid", "prec": 9})
    msgs = c.pump(3, every=hello)
    st = {m["kind"]: m for m in of_type(msgs, "stats")}
    report("build" in st and "pollution" in st and "item" in st, "stats: building counts and pollution answer",
           f"build {list(st.get('build', {}).get('l') or [])[:2]}, pollution {list(st.get('pollution', {}).get('l') or [])[:2]}")
    gr = st.get("item", {}).get("gr", [])
    report(gr and gr[0][0] == "iron-plate" and len(gr[0][1]) == 60 and st["item"].get("si") == 0,
           "stats: graph lines (60 samples of 300) summed over all surfaces", f"{gr[0][1][:6] if gr else gr}")
    report(st.get("fluid", {}).get("prec") == 9, "stats: All (prec 9), rows by all-time totals",
           f"{list(st.get('fluid', {}).get('l') or [])[:2]}")

    # The Bonuses and Permissions windows.
    c.send({"t": "bonuses"})
    c.send({"t": "perms"})
    msgs = c.pump(2, every=hello)
    bonus = of_type(msgs, "bonus")
    perms = of_type(msgs, "perms")
    report(bonus and isinstance(bonus[-1]["l"], (list, dict)), "bonus: the force's research bonuses (LuaForce modifiers, ammo, turrets)",
           f"{[r[:2] for r in (bonus[-1]['l'] if bonus and isinstance(bonus[-1]['l'], list) else [])][:8]}")
    report(perms and any(g[0] == "Default" for g in perms[-1]["l"]), "perms: the permission groups (game.permissions.groups)",
           f"{perms[-1]['l'][:4] if perms else perms}")

    # The logistic networks window (L).
    c.send({"t": "lnets"})
    msgs = c.pump(2, every=hello)
    nets = of_type(msgs, "lnets")
    l = nets[-1]["l"] if nets else []
    l = l if isinstance(l, list) else []  # none: table_to_json writes {}
    report(nets, "lnets: every logistic network of the force", f"{len(l)} networks: {l[:3]}")
    if l:
        busiest = max(l, key=lambda r: r[3][1] + r[4][1])
        c.send({"t": "lnet", "id": busiest[0]})
        msgs = c.pump(2, every=hello)
        one = of_type(msgs, "lnet")
        report(one and one[-1]["found"] == 1 and one[-1]["log"][1] == busiest[3][1], "lnet: one network's robots and items",
               f"network {busiest[0]}: {len(one[-1].get('items', [])) if one else 0} items, first {list(one[-1].get('items', []))[:3] if one else ''}")

    # Alerts: whatever the save has, then ones made here.
    msgs = c.pump(4, every=hello)
    al = of_type(msgs, "al")
    seen = {a[0]: a[1] for a in al[-1]["l"]} if al else {}
    report(al, "al: the force's alerts once a second", f"in the save: {seen}")
    if not clean_spot(c, hello):
        report(False, "alerts: no clean spot found")
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local x, y = {x}, {y}
local function put(name, dx, dy)
  local e = s.create_entity({{ name = name, position = {{ x + dx, y + dy }}, force = c.force, raise_built = true }})
  return e
end
local t = put("gun-turret", 4, 4)
local a = put("assembling-machine-1", -4.5, 4.5)
local hurt = put("wooden-chest", 6.5, -3.5)
local doomed = put("iron-chest", 7.5, -3.5)
local rp = put("roboport", -6, -6)
local gp = {{ x - 3.5, y - 6.5 }}
local missing = "steel-chest"
for _, name in pairs({{ "steel-chest", "rocket-silo", "nuclear-reactor", "centrifuge", "artillery-turret", "lab", "radar" }}) do
  local have = false
  for _, net in pairs(s.find_logistic_networks_by_construction_area(gp, c.force)) do
    if net.get_item_count(name) > 0 then have = true end
  end
  if not have then missing = name break end
end
local g = s.create_entity({{ name = "entity-ghost", inner_name = missing, position = gp, force = c.force }})
hurt.damage(20, game.forces.enemy)
doomed.die(game.forces.enemy)
rcon.print(t.unit_number .. " " .. a.unit_number .. " " .. hurt.unit_number .. " " .. rp.unit_number .. " " .. g.unit_number .. " " .. tostring(a.status))
""".replace("\n", " "))
    vals = out.split()
    if len(vals) < 5:
        report(False, "alerts: building the test entities", out)
        return
    turret, asm, hurt, rp, ghost = (int(v) for v in vals[:5])
    msgs = c.pump(2.2, every=hello)
    al = of_type(msgs, "al")
    kinds = {a[0]: a for a in al[-1]["l"]} if al else {}
    units = lambda k: [e[4] for e in kinds.get(k, [None, 0, []])[2]]
    report(hurt in units("attack"), "al: under attack (on_entity_damaged by the enemy force)", str(kinds.get("attack", "")[:2]))
    report(any(e[3] == "iron-chest" for e in kinds.get("destroyed", [0, 0, []])[2]), "al: destroyed (on_entity_died)",
           str(kinds.get("destroyed", "")[:2]))
    # The entity scans make a pass over every chunk at most every 10 s, spread over several seconds.
    # The turret is seen round the focus within a second (J22, status_near), the ghost only by a pass: wait for both.
    has_turret = lambda m: m.get("t") == "al" and any(a[0] == "no_ammo" and any(e[4] == turret for e in a[2]) for a in m["l"])
    has_ghost = lambda m: m.get("t") == "al" and any(a[0] in ("no_material", "no_robots") and any(e[4] == ghost for e in a[2]) for a in m["l"])
    started = time.time()
    msgs = c.pump(30, every=hello, until=lambda m: has_turret(m) and has_ghost(m))
    msgs += c.pump(1.2, every=hello)
    al = of_type(msgs, "al")
    kinds = {a[0]: a for a in al[-1]["l"]} if al else {}
    report(turret in units("no_ammo"), "al: a gun turret without ammo (turret_ammo inventory empty)",
           f"seen after {time.time() - started:.1f} s: {str(kinds.get('no_ammo', '')[:2])}")
    report(asm in units("unplugged") or asm in units("no_power"), "al: a machine out of reach of poles",
           f"status {vals[5:]}; unplugged {kinds.get('unplugged', '')[:2]}")
    report(ghost in units("no_material") or ghost in units("no_robots"),
           "al: a ghost in a roboport's construction area without its item (find_logistic_networks_by_construction_area)",
           f"no_material {[e for e in kinds.get('no_material', [0, 0, []])[2] if e[4] == ghost]}, "
           f"no_robots {[e for e in kinds.get('no_robots', [0, 0, []])[2] if e[4] == ghost]}")
    msgs = c.pump(max(1.5, 7 - (time.time() - started)), every=hello)
    al = of_type(msgs, "al")
    kinds = {a[0]: a for a in al[-1]["l"]} if al else {}
    report(hurt not in units("attack") and any(e[3] == "iron-chest" for e in kinds.get("destroyed", [0, 0, []])[2]),
           "al: under attack ends after 5 s, destroyed stays")
    destroy_units([turret, asm, hurt, rp, ghost])
    mod_lua("local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({ type = 'entity-ghost', "
            f"area = {{ {{ {x - 8}, {y - 8} }}, {{ {x + 8}, {y + 8} }} }} }})) do e.destroy() end")
    sizes = {k: v for k, v in c.max_size.items() if k in ("al", "lnets", "lnet", "stats", "techs")}
    report(max(sizes.values() or [0]) < 60000, "info messages fit a datagram", str(sizes))


def check_hud(c, hello):
    """The HUD's data from ui-hud2: the magazine's rounds in `guns` (LuaItemStack.ammo,
    magazine_size), the character's own logistic sections (clog.sec, set_section u 0 on the
    requester LuaLogisticPoint) and its colour (set_char_color, ccol)."""
    # --- rounds left in the magazine (4, or 3 when a run before left 4) ---------------------------
    out = mod_lua("""
local c = storage.f3d.puppet
local guns = c.get_inventory(defines.inventory.character_guns)
local ammo = c.get_inventory(defines.inventory.character_ammo)
local rounds = (ammo[1].valid_for_read and ammo[1].name == "firearm-magazine" and ammo[1].ammo == 4) and 3 or 4
guns[1].set_stack({ name = "submachine-gun", count = 1 })
ammo[1].set_stack({ name = "firearm-magazine", count = 20 })
ammo[1].ammo = rounds
c.selected_gun_index = 1
rcon.print(ammo[1].ammo .. " " .. prototypes.item["firearm-magazine"].magazine_size)
""".replace("\n", " "))
    rounds = int(out.split()[0]) if out and out.split()[0].isdigit() else 4
    msgs = c.pump(3, every=hello, until=lambda m: m.get("t") == "guns" and m["l"] and len(m["l"][0]) >= 5 and m["l"][0][3] == rounds)
    guns = of_type(msgs, "guns")
    report(guns and guns[-1]["l"][0][:5] == ["submachine-gun", "firearm-magazine", 20, rounds, 10],
           "guns: the magazine's rounds left and its size (LuaItemStack.ammo, magazine_size)", f"{out} {guns[-1:]}")

    # --- the character's logistic sections ---------------------------------------------------------
    mod_lua("game.forces.player.character_logistic_requests = true rcon.print('ok')")
    c.pump(1, every=hello)
    count = mod_lua("rcon.print(storage.f3d.puppet.get_requester_point().sections_count)")
    before = int(count) if count.isdigit() else 0
    c.send({"t": "set_section", "u": 0, "i": 0, "g": "F3D live check"})
    msgs = c.pump(3, every=hello, until=lambda m: m.get("t") == "clog" and len(m.get("sec", [])) == before + 1)
    clog = of_type(msgs, "clog")
    report(clog and isinstance(clog[-1].get("sec"), list) and isinstance(clog[-1].get("lgs", []), (list, dict)),
           "clog.sec: the character's logistic sections (LuaLogisticPoint.sections) and the force's groups",
           str(clog[-1:])[:300])
    new = clog[-1]["sec"][-1] if clog and clog[-1].get("sec") else {}
    report(new.get("g") == "F3D live check", "set_section u 0 adds a section to the character in a group (add_section)", str(new))
    i = new.get("i", 0)
    c.send({"t": "set_section", "u": 0, "i": i, "on": 0, "f": [["iron-gear-wheel", "normal", 25, -1, "", -1]]})
    msgs = c.pump(3, every=hello, until=lambda m: m.get("t") == "clog" and any(x.get("i") == i and x.get("on") == 0 for x in m.get("sec", [])))
    clog = of_type(msgs, "clog")
    sec = next((x for x in (clog[-1]["sec"] if clog else []) if x.get("i") == i), {})
    report(sec.get("on") == 0 and sec.get("f", [[]])[0][:3] == ["iron-gear-wheel", "normal", 25],
           "set_section u 0: a character section off (LuaLogisticSection.active) with its requests", str(sec))
    c.send({"t": "set_section", "u": 0, "i": i, "del": 1})
    msgs = c.pump(3, every=hello, until=lambda m: m.get("t") == "clog" and len(m.get("sec", [])) == before)
    count = mod_lua("rcon.print(storage.f3d.puppet.get_requester_point().sections_count)")
    report(count == str(before), "set_section u 0 del removes it (remove_section)", count)
    mod_lua("""for _, g in pairs(game.forces.player.get_logistic_groups()) do
  if g == "F3D live check" then pcall(function() game.forces.player.delete_logistic_group(g) end) end end rcon.print('ok')""".replace("\n", " "))

    # --- the character's colour --------------------------------------------------------------------
    was = mod_lua("local col = storage.f3d.puppet.color rcon.print(math.floor(col.r * 255 + 0.5) .. ' ' .. math.floor(col.g * 255 + 0.5) .. ' ' .. math.floor(col.b * 255 + 0.5))")
    c.send({"t": "set_char_color", "c": [12, 200, 56]})
    msgs = c.pump(3, every=hello, until=lambda m: m.get("t") == "ccol" and m["c"] == [12, 200, 56])
    now = mod_lua("local col = storage.f3d.puppet.color rcon.print(math.floor(col.r * 255 + 0.5) .. ' ' .. math.floor(col.g * 255 + 0.5) .. ' ' .. math.floor(col.b * 255 + 0.5))")
    report(of_type(msgs, "ccol") and now == "12 200 56", "set_char_color sets LuaEntity.color and ccol says so", f"{was} -> {now}")
    if was and len(was.split()) == 3:
        c.send({"t": "set_char_color", "c": [int(v) for v in was.split()]})
        c.pump(1, every=hello)


def check_machines(c, hello):
    """Factorio's production windows (machine_info.lua): recipe details, the chooser's groups,
    productivity, burners, drills, temperature, labs and a requester chest's settings."""
    if not clean_spot(c, hello):
        report(False, "machines: no clean spot found", SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    fx = lambda v: int(round(v * 256))
    out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local x, y = {x}, {y}
local function put(name, dx, dy)
  local e = s.create_entity({{ name = name, position = {{ x + dx, y + dy }}, force = c.force, raise_built = true }})
  return e
end
for ox = -1, 1 do for oy = -1, 1 do
  s.create_entity({{ name = "iron-ore", position = {{ x + 6.5 + ox, y - 4.5 + oy }}, amount = 5000 }})
end end
s.create_entity({{ name = "crude-oil", position = {{ x - 5.5, y - 4.5 }}, amount = 300000 }})
local list = {{}}
local function add(e) list[#list + 1] = e and (e.unit_number .. " " .. e.name .. " " .. e.position.x .. " " .. e.position.y) or "0 x 0 0" end
local asm = put("assembling-machine-2", 3.5, 3.5) asm.set_recipe("electronic-circuit")
asm.get_module_inventory().insert({{ name = "productivity-module", count = 2 }})
asm.get_inventory(defines.inventory.crafter_input).insert({{ name = "iron-plate", count = 5 }})
add(asm)
local furnace = put("stone-furnace", -3, 3)
furnace.insert({{ name = "coal", count = 5 }}) furnace.insert({{ name = "iron-ore", count = 10 }})
add(furnace)
local drill = put("burner-mining-drill", 6, -5) drill.insert({{ name = "coal", count = 5 }}) add(drill)
add(put("pumpjack", -5.5, -4.5))
local reactor = put("nuclear-reactor", 0.5, 9.5) add(reactor)
local lab = put("lab", -5.5, 9.5) add(lab)
lab.insert({{ name = "automation-science-pack", count = 5 }})
lab.set_stored_durability("automation-science-pack", {{ durability = 0.5, quality = "normal" }})
local req = put("requester-chest", 0.5, -2.5) add(req)
if prototypes.entity["cargo-landing-pad"] then
  local silo = put("rocket-silo", -9.5, 2.5) add(silo)
  if silo then silo.get_inventory(defines.inventory.rocket_silo_rocket).insert({{ name = "iron-plate", count = 10 }}) end
end
rcon.print(table.concat(list, ";"))
""".replace("\n", " "))
    recs = [r.split() for r in out.split(";")] if out else []
    if len(recs) not in (7, 8) or any(r[0] == "0" for r in recs):
        report(False, "machines: building the test entities", out)
        return
    units = {r[1]: (int(r[0]), float(r[2]), float(r[3])) for r in recs}

    def screen(name, seconds=1.2):
        u, ex, ey = units[name]
        c.send({"t": "open", "u": u, "p": c.proto_id(name), "x": fx(ex), "y": fx(ey)})
        msgs = c.pump(seconds, every=hello)
        g = [m for m in of_type(msgs, "gui") if m.get("u") == u and not m.get("closed")]
        # The first message carries the lists (rl, rg, li, lgs); a late one from before may come first.
        listed = [m for m in g if {"rl", "li", "lgs"} & set(m)]
        return (listed or g or [{}])[0], g[-1] if g else {}

    c.pump(2.0, every=hello)  # let the machines and the drill run a little
    first, last = screen("assembling-machine-2")
    rl = dict(zip(first.get("rl", []), first.get("rg", [])))
    report(last.get("rd", {}).get("o") == [["item", "electronic-circuit", 1]] and ["item", "copper-cable", 3] in last.get("rd", {}).get("i", []),
           "rd: the recipe's ingredients and products (LuaRecipe.ingredients / products / energy)", str(last.get("rd")))
    report(len(rl) == len(first.get("rl", [])) > 0 and rl.get("iron-gear-wheel", [""])[0] == "intermediate-products",
           "rg: each recipe's item group, subgroup and order for the chooser's tabs",
           f"{rl.get('iron-gear-wheel')} rl={first.get('rl', [])[:3]} rg={first.get('rg', [])[:2]}")
    report(last.get("pb", 0) > 0 and "bp" in last, "pb / bp: productivity bonus and bonus_progress (productivity modules)",
           f"pb={last.get('pb')} bp={last.get('bp')}")
    _, last = screen("stone-furnace")
    report(last.get("rd", {}).get("o") == [["item", "iron-plate", 1]] and 0 < last.get("bn", 0) <= 1000,
           "a furnace's recipe details and its burner's fuel left (LuaBurner.currently_burning / remaining_burning_fuel)",
           f"rd={last.get('rd')} bn={last.get('bn')}")
    _, last = screen("burner-mining-drill")
    report(last.get("mt") == "iron-ore" and "bn" in last, "a drill's mining target and burner (mining_target)",
           f"mt={last.get('mt')} mp={last.get('mp')} bn={last.get('bn')}")
    report("mp" in last, "a drill's mining progress (mining_progress or crafting_progress)", f"mp={last.get('mp')}")
    _, last = screen("pumpjack")
    report(last.get("mt") == "crude-oil" and last.get("mr", 0) > 0, "a pumpjack's yield per second (normal_resource_amount, mining_speed)",
           f"mt={last.get('mt')} mr={last.get('mr')}")
    _, last = screen("nuclear-reactor")
    report("tc" in last and last.get("tmax") == 1000, "temperature in hundredths and the heat buffer's max_temperature",
           f"tc={last.get('tc')} tmax={last.get('tmax')}")
    first, _ = screen("lab")
    report("automation-science-pack" in first.get("li", []), "li: the lab's science packs (lab_inputs)", str(first.get("li"))[:120])
    report([1, 500] in first.get("ld", []), "ld: what is left of the pack a lab started on (get_stored_durability)",
           str(first.get("ld")))
    u = units["requester-chest"][0]
    _, last = screen("requester-chest")
    lc = last.get("lc", {})
    report(lc.get("tu") == 0 and lc.get("rb") in (0, 1) and isinstance(lc.get("sec"), list),
           "lc: a requester's sections, trash unrequested (get_logistic_point) and request_from_buffers", str(lc))
    c.send({"t": "set_chest_logistics", "u": u, "tu": 1, "rb": 1})
    c.send({"t": "set_section", "u": u, "i": 0})
    _, last = screen("requester-chest")
    lc = last.get("lc", {})
    report(lc.get("tu") == 1 and lc.get("rb") == 1 and len(lc.get("sec", [])) >= 1,
           "set_chest_logistics and set_section on a chest", str(lc))
    c.send({"t": "set_section", "u": u, "i": 1, "g": "F3D live check"})
    c.pump(0.5, every=hello)
    c.send({"t": "close"})
    first, last = screen("requester-chest")
    report(last.get("lc", {}).get("sec", [{}])[0].get("g") == "F3D live check" and "F3D live check" in first.get("lgs", []),
           "set_section g: a section joins a logistic group (LuaLogisticSection.group); lgs lists the force's groups "
           "(get_logistic_groups)", f"{last.get('lc', {}).get('sec')} lgs={first.get('lgs')}")
    mod_lua('storage.f3d.puppet.force.delete_logistic_group("F3D live check")')
    if "rocket-silo" in units:
        _, last = screen("rocket-silo")
        rw = last.get("rw", [])
        report(len(rw) == 2 and rw[0] > 0 and rw[1] == 1000000 and isinstance(last.get("lc", {}).get("sec"), list)
               and last.get("rd", {}).get("o", [[None, None]])[0][1] == "rocket-part" and "pr" in last,
               "a silo: rocket weight (LuaItemPrototype.weight, default_rocket_lift_weight), its requests (rocket_silo_requester), "
               "the rocket part's recipe and progress", f"rw={rw} lc={last.get('lc')} rd={last.get('rd')} pr={last.get('pr')}")
        u_silo = units["rocket-silo"][0]
        c.send({"t": "set_chest_logistics", "u": u_silo, "tu": 1})
        _, last = screen("rocket-silo")
        report(last.get("lc", {}).get("tu") == 1, "set_chest_logistics on a silo: trash unrequested", str(last.get("lc")))
    c.send({"t": "close"})
    destroy_units([v[0] for v in units.values()])
    mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ type = 'resource', area = {{ {{ {x - 8}, {y - 8} }}, {{ {x + 8}, {y} }} }} }})) do e.destroy() end")


def check_weapons(c, hello):
    """What weapons fire (shots.lua, combat.lua's `shot`): each gun at a still biter, then capsules.
    Checks find_entities_filtered for projectiles, streams, beams, explosions, fires and clouds,
    register_on_object_destroyed as their id, on_object_destroyed for where projectiles end, and
    find_nearest_enemy for a shot's target."""
    clean_spot(c, hello, half=20)
    c.send({"t": "focus", "x": c.me["x"], "y": c.me["y"], "r": 48})
    fx = lambda v: int(round(v * 256))

    def biter(dx, dy, name="medium-biter"):
        out = mod_lua(f"""
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
            report(False, f"spawn a {name} to shoot", out)
            return None

    def arm(gun, ammo, count=20):
        mod_lua(f'local c = storage.f3d.puppet '
                f'c.get_inventory(defines.inventory.character_guns).clear() c.get_inventory(defines.inventory.character_ammo).clear() '
                f'c.get_inventory(defines.inventory.character_guns).insert({{name = "{gun}"}}) '
                f'c.get_inventory(defines.inventory.character_ammo).insert({{name = "{ammo}", count = {count}}}) '
                f'c.selected_gun_index = 1 storage.f3d.guns_sig = nil')

    def clear_units():
        mod_lua("for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({ type = 'unit', position = storage.f3d.puppet.position, radius = 30 })) do e.destroy() end")

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
        return [m[key][i:i + width] for m in of_type(msgs, "pj") for i in range(0, len(m.get(key, [])), width)]

    msgs, b = fire("submachine-gun", "firearm-magazine", seconds=1.5)
    shots = of_type(msgs, "shot")
    near = [m for m in shots if b and abs(m["x"] / 256 - b[1]) < 1.5 and abs(m["y"] / 256 - b[2]) < 1.5]
    report(len(shots) >= 5 and near and shots[0]["g"] == "submachine-gun" and shots[0]["a"] == "firearm-magazine",
           "shot: each submachine-gun shot (ammo down a round) with the gun, ammo and the target biter's position",
           f"{len(shots)} shots, {len(near)} at the biter, first {shots[:1]}")
    gaps = [b2["k"] - a["k"] for a, b2 in zip(shots, shots[1:])]
    report(gaps and min(gaps) >= 5, "shot: about one per 6 ticks, the submachine gun's cooldown", f"tick gaps {gaps[:10]}")
    xs = [m["x"][i] for m in of_type(msgs, "pj") for i in range(0, len(m.get("x", [])), 3)]
    report("explosion-gunshot" not in xs and "explosion-hit" not in xs,
           "headless: no explosion-gunshot / explosion-hit (only_when_visible), so the client plays them", str(sorted(set(xs)))[:200])

    msgs, b = fire("shotgun", "shotgun-shell", dx=6, seconds=1.0)
    pellets = [r for r in flying(msgs) if r[1] == "shotgun-pellet"]
    ids = {r[0] for r in pellets}
    ended = flying(msgs, "e", 3)
    report(len(ids) >= 10 and all(isinstance(i, int) for i in ids),
           "pj: shotgun pellets in flight, each with its register_on_object_destroyed id", f"{len(ids)} pellets")
    report(any(e[0] in ids for e in ended), "pj.e: on_object_destroyed says where pellets ended", f"{len(ended)} ended")
    moves = {}
    for r in pellets:
        moves.setdefault(r[0], []).append(r[2])
    report(any(len(set(v)) > 1 for v in moves.values()), "pj: a pellet's position changes between scans")

    msgs, b = fire("rocket-launcher", "rocket", dx=12, seconds=2.5)
    rockets = [r for r in flying(msgs) if r[1] == "rocket"]
    rids = {r[0] for r in rockets}
    report(rids and any(e[0] in rids for e in flying(msgs, "e", 3)), "pj: a rocket in flight and where it hit",
           f"{len(rockets)} positions of {len(rids)} rockets")

    msgs, b = fire("flamethrower", "flamethrower-ammo", dx=8, seconds=2.0)
    streams = [r for r in flying(msgs) if r[1] == "handheld-flamethrower-fire-stream"]
    fires = [m["l"][i:i + 5] for m in of_type(msgs, "gf") for i in range(0, len(m["l"]), 5)]
    report(streams, "pj: the hand flamethrower's stream entities", f"{len(streams)} positions")
    report(any(f[1] == "fire-flame" and f[4] == -1 for f in fires), "gf: fire-flame on the ground where the stream landed",
           str(fires[:2]))
    report(not of_type(msgs, "shot"), "shot: none for a stream gun (the stream shows it)")

    if mod_lua("rcon.print(prototypes.item['teslagun'] and 'yes' or 'no')") == "yes":
        msgs, b = fire("teslagun", "tesla-ammo", dx=7, seconds=2.0)
        beams = [r for r in flying(msgs, "b", 6) if r[1].startswith("chain-tesla-gun-beam")]
        report(beams and b and any(abs(r[4] / 256 - b[1]) < 2 and abs(r[5] / 256 - b[2]) < 2 for r in beams),
               "pj.b: the tesla gun's chain beam from the character to the biter (get_beam_source/target)",
               str(beams[:2]))
        msgs, b = fire("railgun", "railgun-ammo", dx=9, seconds=2.2)
        shots = of_type(msgs, "shot")
        report(shots and shots[0]["g"] == "railgun", "shot: the railgun's shot (its beam is only_when_visible)", str(shots[:1]))

    mod_lua('storage.f3d.puppet.insert({name = "grenade", count = 5}) storage.f3d.puppet.insert({name = "poison-capsule", count = 5})')
    x, y = c.me["x"] / 256, c.me["y"] / 256
    c.send({"t": "throw", "item": "grenade", "x": fx(x + 8), "y": fx(y + 2)})
    msgs = c.pump(2.5, every=hello)
    gren = [r for r in flying(msgs) if r[1] == "grenade"]
    xs = [m["x"][i:i + 3] for m in of_type(msgs, "pj") for i in range(0, len(m.get("x", [])), 3)]
    report(gren, "pj: a thrown grenade in flight", f"{len(gren)} positions")
    report(any(e[0] == "grenade-explosion" and abs(e[1] / 256 - x - 8) < 2 for e in xs),
           "pj.x: the grenade's explosion entity, found once where it landed", str(xs[:4]))
    report(len([e for e in xs if e[0] == "grenade-explosion"]) == 1, "pj.x: each explosion is reported once")
    c.send({"t": "throw", "item": "poison-capsule", "x": fx(x - 8), "y": fx(y)})
    msgs = c.pump(3.0, every=hello)
    clouds = [m["l"][i:i + 5] for m in of_type(msgs, "gf") for i in range(0, len(m["l"]), 5)]
    report(any(f[1] == "poison-cloud" and f[4] > 0 for f in clouds), "gf: the poison cloud with its time_to_live",
           str([f for f in clouds if f[1] == "poison-cloud"][:1]))
    mod_lua("for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({ type = {'fire', 'smoke-with-trigger'}, position = storage.f3d.puppet.position, radius = 40 })) do e.destroy() end")
    msgs = c.pump(1.0, every=hello)
    report(any(not m["l"] for m in of_type(msgs, "gf")), "gf: an empty list once the fires and clouds are gone")


def check_remote_view(c, hello):
    """The 3D remote view (focus rv = 1) shows moving things only where a working radar or the
    character sees, as Factorio's does (map.view_filter): a car and a belt item beside a powered radar
    320 tiles away are sent, the same 300 tiles further on aren't, and `cov` says what is seen
    (the radar's chunk and reveal distance, the character's place). Without rv everything is sent.
    A roboport's construction area counts as seen too (H13): with one beside the far car it is sent,
    its belt opens from the remote view, and `mrp` lists the roboport."""
    if not clean_spot(c, hello):
        report(False, "remote view: an empty spot", SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    rx, ry = x + 320, y
    out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local f = c.force
local rx, ry = {rx}, {ry}
for _, at in pairs({{ rx, rx + 300 }}) do
  s.request_to_generate_chunks({{ at, ry }}, 2)
end
s.force_generate_chunk_requests()
local made = {{}}
for _, at in pairs({{ rx, rx + 300 }}) do
  for _, e in pairs(s.find_entities_filtered({{ area = {{ {{ at - 6, ry - 6 }}, {{ at + 18, ry + 6 }} }} }})) do
    if e.type ~= "character" then e.destroy() end
  end
  for tx = at - 6, at + 18 do for ty = ry - 6, ry + 6 do
    local t = s.get_tile(tx, ty) if t.collides_with("water_tile") then s.set_tiles({{ {{ name = "grass-1", position = {{ tx, ty }} }} }}) end
  end end
  local car = s.create_entity({{ name = "car", position = {{ at + 10, ry }}, force = f }})
  local belt = s.create_entity({{ name = "transport-belt", position = {{ at + 14.5, ry + 0.5 }}, direction = defines.direction.north, force = f }})
  belt.get_transport_line(1).insert_at_back({{ name = "iron-plate", count = 1 }})
  made[#made + 1] = car.unit_number
  made[#made + 1] = belt.unit_number
end
local r = s.create_entity({{ name = "radar", position = {{ rx, ry }}, force = f, raise_built = true }})
s.create_entity({{ name = "electric-energy-interface", position = {{ rx + 4, ry }}, force = f }})
s.create_entity({{ name = "small-electric-pole", position = {{ rx + 2.5, ry + 2.5 }}, force = f }})
made[#made + 1] = r.unit_number
rcon.print(table.concat(made, " "))
""".replace("\n", " ")).split()
    if len(out) != 5:
        report(False, "remote view: a radar, cars and belts made", str(out))
        return
    car_a, belt_a, car_b, belt_b, radar = map(int, out)
    c.pump(1.5, every=hello)  # the radar powers up; the mod looks for radars at most every 5 s

    def look(at, rv, wait=2.0):
        msg = {"t": "focus", "x": int(math.floor(at * 256 + 0.5)), "y": int(math.floor(ry * 256 + 0.5)), "r": 48}
        if rv:
            msg["rv"] = 1
        c.send(msg)
        c.pump(0.3, every=hello)
        msgs = c.pump(wait, every=hello)
        cars = {r[0] for m in of_type(msgs, "mv") for r in m["l"]}
        items = [(m["l"][i + 2] / 256, m["l"][i + 3] / 256) for m in of_type(msgs, "bi") for i in range(0, len(m["l"]), 4)]
        on_belt = any(abs(ix - (at + 4.5)) < 1 and abs(iy - ry) < 2 for ix, iy in items)
        return cars, on_belt, of_type(msgs, "cov")

    c.pump(4.0, every=hello)
    cars, on_belt, cov = look(rx + 10, True, 3.0)
    rc = [int(rx // 32), int(ry // 32)]
    l = cov[-1]["l"] if cov else []
    report(car_a in cars and on_belt, "remote view: a car and a belt item beside a working radar are sent", f"{sorted(cars)[:6]} item {on_belt}")
    report(bool(cov) and any(l[i:i + 2] == rc and l[i + 2] >= 2 for i in range(0, len(l), 3))
           and abs(cov[-1].get("x", 0) / 256 - x) < 2 and cov[-1].get("cr") == 96,
           "remote view: cov lists the radar's chunk and reveal distance and the character's place", str(cov[-1:]))
    cars, on_belt, cov = look(rx + 310, True)
    report(car_b not in cars and not on_belt and bool(cov), "remote view: no car or belt item where no radar sees", f"{sorted(cars)[:6]} item {on_belt}")
    cars, on_belt, cov = look(rx + 310, False)
    report(car_b in cars and on_belt and not cov, "outside the remote view the same car and item are sent, and no cov",
           f"{sorted(cars)[:6]} item {on_belt} cov {cov[-1:]}")
    # H13: a roboport's construction area counts as seen too: a powered roboport 20 tiles south of the
    # car no radar sees, and the car is sent; `mrp` lists the roboport, and the car's belt opens.
    port = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local f = c.force
local px, py = {rx + 310}, {ry + 20}
for _, e in pairs(s.find_entities_filtered({{ area = {{ {{ px - 4, py - 4 }}, {{ px + 8, py + 4 }} }} }})) do
  if e.type ~= "character" then e.destroy() end
end
local p = s.create_entity({{ name = "roboport", position = {{ px, py }}, force = f, raise_built = true }})
local eei = s.create_entity({{ name = "electric-energy-interface", position = {{ px + 4, py }}, force = f }})
local pole = s.create_entity({{ name = "small-electric-pole", position = {{ px + 2.5, py - 2.5 }}, force = f }})
rcon.print(p.unit_number .. " " .. eei.unit_number .. " " .. pole.unit_number .. " " .. s.index .. " " .. p.position.x .. " " .. p.position.y)
""".replace("\n", " ")).split()
    port_units = []
    fx = lambda v: int(round(v * 256))  # noqa: E731
    if len(port) == 6:
        port_units = list(map(int, port[:3]))
        c.pump(1.0, every=hello)
        cars, on_belt, cov = look(rx + 310, True, 3.0)
        report(car_b in cars and on_belt, "remote view: a car and a belt item in a roboport's construction area are sent (H13)",
               f"{sorted(cars)[:6]} item {on_belt}")
        c.send({"t": "open", "u": belt_b, "p": c.proto_id("transport-belt"), "x": fx(rx + 314.5), "y": fx(ry + 0.5), "rv": 1})
        msgs = c.pump(1.0, every=hello)
        report(any(m.get("t") == "gui" and m.get("u") == belt_b for m in msgs),
               "rv: a building in a roboport's construction area opens from the remote view (H13, D10)",
               str([m.get("text") for m in msgs if m.get("t") == "msg"]))
        c.send({"t": "close"})
        c.send({"t": "mrp", "si": int(port[3]), "q": 7})
        msgs = c.pump(2.0, every=hello)
        ports = [v for m in msgs if m.get("t") == "mrp" and m.get("q") == 7 for v in m["l"]]
        last = [m for m in msgs if m.get("t") == "mrp" and m.get("q") == 7 and m.get("last") == 1]
        at = [fx(float(port[4])), fx(float(port[5]))]  # where the 4x4 roboport snapped to
        report(bool(last) and any(ports[i:i + 2] == at and ports[i + 3] > ports[i + 2] > 0 for i in range(0, len(ports), 4)),
               "mrp: the roboport with its logistic and construction radius (H13)", f"{len(ports) // 4} roboports, last {bool(last)}")
    else:
        report(False, "remote view: a roboport made", str(port))
    destroy_units([car_a, belt_a, car_b, belt_b, radar] + port_units)
    c.send({"t": "focus", "x": c.me["x"], "y": c.me["y"], "r": 48})
    c.pump(0.5, every=hello)


def check_states(c, hello):
    """States beyond working or not (`st`, movers.lua): rail and chain signals by colour, an
    accumulator charging and then discharging, a power switch on and off, a powered lamp off by day
    (status turned_off_during_daytime), set to Always on at noon lit with `ao` 1 (K20; its status
    printed) and on at midnight (working; J19). A track with a signal and
    a chain signal by it is green while empty and red once a locomotive stands in the block beyond;
    an accumulator charges from a solar panel at noon and discharges into a radar once that is gone
    (an electric energy interface won't do: it gives power at tertiary priority, as accumulators
    do, so it never charges them)."""
    clear_enemies()  # a biter left from the shooting checks kills the character in the middle (see clear_enemies)
    if not clean_spot(c, hello):
        report(False, "states: an empty spot", SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    rx, ry = 2 * math.floor(x / 2) - 8, 2 * math.floor(y / 2) + 7  # rails sit on the 2x2 grid
    out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface
local made = {{}}
for i = 0, 7 do
  s.create_entity({{ name = 'straight-rail', position = {{ {rx} + 2 * i, {ry} }}, direction = defines.direction.east, force = c.force, raise_built = true }})
end
local function signal(name, x0)
  for _, d in pairs({{ defines.direction.east, defines.direction.west }}) do
    for _, dy in pairs({{ -1.5, 1.5 }}) do
      for dx = 0, 1 do
        local p = {{ x0 + dx + 0.5, {ry} + dy }}
        if s.can_place_entity({{ name = name, position = p, direction = d, force = c.force }}) then
          return s.create_entity({{ name = name, position = p, direction = d, force = c.force, raise_built = true }})
        end
      end
    end
  end
end
local sig = signal('rail-signal', {rx} + 6)
local chain = signal('rail-chain-signal', {rx} + 2)
local px, py = math.floor({x}), math.floor({y})
storage.f3d_states_day = {{ s.daytime, s.freeze_daytime }}
s.daytime = 0 s.freeze_daytime = true
local pole = s.create_entity({{ name = 'medium-electric-pole', position = {{ px + 4.5, py - 4.5 }}, force = c.force, raise_built = true }})
local acc = s.create_entity({{ name = 'accumulator', position = {{ px + 7, py - 4 }}, force = c.force, raise_built = true }})
local sol = s.create_entity({{ name = 'solar-panel', position = {{ px + 2.5, py - 6.5 }}, force = c.force, raise_built = true }})
local switch = s.create_entity({{ name = 'power-switch', position = {{ px + 1, py - 10 }}, force = c.force, raise_built = true }})
switch.power_switch_state = true
local lamp = s.create_entity({{ name = 'small-lamp', position = {{ px + 5.5, py - 2.5 }}, force = c.force, raise_built = true }})
storage.f3d_states = {{ sig = sig, chain = chain, acc = acc, sol = sol, switch = switch, pole = pole, lamp = lamp }}
rcon.print((sig and sig.unit_number or 0) .. ' ' .. (chain and chain.unit_number or 0) .. ' ' .. acc.unit_number .. ' ' .. switch.unit_number .. ' ' .. lamp.unit_number)
""".replace("\n", " "))
    try:
        sig, chain, acc, switch, lamp = (int(v) for v in out.split())
    except ValueError:
        report(False, "states: built a track with signals, an accumulator, a power switch and a lamp", out)
        return
    report(sig and chain, "states: a rail signal and a chain signal placed by the track", out)

    def states(seconds):
        got = {}
        for m in of_type(c.pump(seconds, every=hello), "st"):
            for i in range(0, len(m["l"]), 2):
                got[m["l"][i]] = m["l"][i + 1]
        return got
    got = states(6.0)
    report(got.get(sig) == 1 and got.get(chain) == 1, "st: an empty block's rail and chain signals are green (1)",
           f"signal {got.get(sig)}, chain {got.get(chain)}")
    report(got.get(acc) == 1, "st: an accumulator charging from the network is 1 (status charging)", str(got.get(acc)))
    report(got.get(switch) == 1, "st: a power switch that is on is 1", str(got.get(switch)))
    report(got.get(lamp) == 0, "st: a powered lamp at noon is 0 (status turned_off_during_daytime)", str(got.get(lamp)))
    # K20: the lamp set to Always on at noon. Printed: the status 2.1 gives it (working, or still
    # turned_off_during_daytime, which the bridge reads past through always_on); then `st` 1 with `ao` 1,
    # which lets the client light it by day, and 0 again with Always on off.
    def lamp_msgs(seconds):
        st_got, ao_got = {}, {}
        for m in of_type(c.pump(seconds, every=hello), "st"):
            for i in range(0, len(m["l"]), 2):
                st_got[m["l"][i]] = m["l"][i + 1]
            a = m.get("ao") or []
            for i in range(0, len(a), 2):
                ao_got[a[i]] = a[i + 1]
        return st_got, ao_got
    out = mod_lua("storage.f3d_states.lamp.always_on = true rcon.print('ok')")
    st_got, ao_got = lamp_msgs(4.0)
    status = mod_lua("local l = storage.f3d_states.lamp local n = tostring(l.status) "
                     "for k, v in pairs(defines.entity_status) do if v == l.status then n = k end end "
                     "rcon.print(n .. ', always_on ' .. tostring(l.always_on))")
    print(f"  K20: a lamp set to Always on at noon reads status {status}")
    report(out == "ok" and st_got.get(lamp) == 1 and ao_got.get(lamp) == 1,
           "st: a lamp set to Always on at noon is 1 with ao 1: the client lights it by day (K20)",
           f"{out}; st {st_got.get(lamp)}, ao {ao_got.get(lamp)}; status {status}")
    out = mod_lua("storage.f3d_states.lamp.always_on = false rcon.print('ok')")
    st_got, _ = lamp_msgs(4.0)
    report(out == "ok" and st_got.get(lamp) == 0, "st: Always on turned off again at noon: 0 (K20)", f"{out}; st {st_got.get(lamp)}")
    # A locomotive in the track's blocks, the switch off, the solar panel swapped for a radar, midnight.
    out = mod_lua(f"""
local t = storage.f3d_states local s = t.acc.surface
s.daytime = 0.5
t.switch.power_switch_state = false
t.sol.destroy({{ raise_destroy = true }})
t.acc.energy = 5000000
t.radar = s.create_entity({{ name = 'radar', position = {{ t.pole.position.x - 2.5, t.pole.position.y + 2.5 }}, force = t.acc.force, raise_built = true }})
local loco
for i = 0, 7 do
  loco = s.create_entity({{ name = 'locomotive', position = {{ {rx} + 2 * i, {ry} }}, direction = defines.direction.east, force = t.acc.force }})
  if loco then break end
end
rcon.print(loco and 'ok' or 'no loco')""".replace("\n", " "))
    got = states(6.0)
    report(out == "ok" and (got.get(sig) == 3 or got.get(chain) == 3),
           "st: with a locomotive standing in its block a signal turns red (3)", f"{out}; signal {got.get(sig)}, chain {got.get(chain)}")
    report(got.get(acc) == 2, "st: the accumulator feeding a radar with the supply gone is 2 (discharging)", str(got.get(acc)))
    report(got.get(switch) == 0, "st: the power switch turned off is 0", str(got.get(switch)))
    report(got.get(lamp) == 1, "st: the lamp at midnight, fed by the accumulator, is 1 (working): the client lights it (J19)",
           str(got.get(lamp)))
    # K10: the lit lamp's colour (`st` `lc`, movers.lua). First what 2.1 reads for a lamp as built (printed:
    # LuaEntity.color, whether it has a control behaviour), then the colour set in its window, then its
    # circuit's (a constant combinator's signal-red on a red wire, Use colors on, the colour mapping).
    def lamp_colours(seconds):
        got = {}
        for m in of_type(c.pump(seconds, every=hello), "st"):
            l = m.get("lc") or []
            for i in range(0, len(l), 2):
                got[l[i]] = l[i + 1]
        return got
    col = "local function col(v) return v and string.format('%.3f,%.3f,%.3f', v.r or v[1] or -1, v.g or v[2] or -1, v.b or v[3] or -1) or 'nil' end "
    out = mod_lua(col + "local l = storage.f3d_states.lamp local ok, cb = pcall(function() return l.get_control_behavior() end) "
                  "rcon.print('LuaEntity.color ' .. col(l.color) .. ', control behaviour ' .. tostring(ok and cb ~= nil))")
    print(f"  K10: a lamp as built reads {out}")
    out = mod_lua("storage.f3d_states.lamp.color = { r = 0, g = 1, b = 0, a = 1 } rcon.print('ok')")
    got = lamp_colours(3.0)
    report(out == "ok" and got.get(lamp) == 0x00FF00, "st lc: a lit lamp's window colour (LuaEntity.color) goes to the client (K10)",
           f"{out}; lc {got.get(lamp)}")
    out = mod_lua("""local t = storage.f3d_states local l = t.lamp local s = l.surface
local cc = s.create_entity({ name = 'constant-combinator', position = { l.position.x + 2.5, l.position.y }, force = l.force, raise_built = true })
t.cc = cc
local b = cc.get_or_create_control_behavior()
local sec = (b.sections_count > 0 and b.get_section(1)) or b.add_section()
sec.set_slot(1, { value = { type = 'virtual', name = 'signal-red', quality = 'normal' }, min = 1 })
l.get_wire_connector(defines.wire_connector_id.circuit_red, true).connect_to(cc.get_wire_connector(defines.wire_connector_id.circuit_red, true))
local cb = l.get_or_create_control_behavior()
cb.use_colors = true
cb.color_mode = defines.control_behavior.lamp.color_mode.color_mapping
rcon.print('ok')""".replace("\n", " "))
    # The colour is sent once, when it changes: it can come in this first second already.
    early = lamp_colours(1.0)
    shown = mod_lua(col + "local cb = storage.f3d_states.lamp.get_control_behavior() rcon.print(col(cb and cb.color))")
    print(f"  K10: with Use colors and signal-red on its wire, LuaLampControlBehavior.color reads {shown}")
    got = {**early, **lamp_colours(3.0)}
    report(out == "ok" and got.get(lamp) == 0xFF0000,
           "st lc: with Use colors, its circuit network's colour (signal-red) instead of its window's (K10)",
           f"{out}; cb.color {shown}; lc {got.get(lamp)}")
    mod_lua("""local t = storage.f3d_states local s = t.acc.surface
for _, e in pairs(s.find_entities_filtered({ area = { { t.acc.position.x - 40, t.acc.position.y - 20 }, { t.acc.position.x + 20, t.acc.position.y + 30 } },
  type = { 'straight-rail', 'rail-signal', 'rail-chain-signal', 'locomotive', 'accumulator', 'radar', 'electric-pole', 'power-switch', 'lamp',
    'constant-combinator' } })) do
  e.destroy({ raise_destroy = true })
end
s.daytime = storage.f3d_states_day[1] s.freeze_daytime = storage.f3d_states_day[2]
storage.f3d_states = nil rcon.print('ok')""".replace("\n", " "))


def check_repair(c, hello):
    """K13: repair packs (repair.lua). First whether Factorio's own LuaControl.repair_state does anything for the
    bridge's player-less character (printed: the bridge doesn't use it), then the bridge's `repair`: a wall and a
    chest damaged by script, a repair pack in the inventory, the client's command repeated as the button is held;
    health per tick, durability used, `me` `rp`, the bar in `hp`, and nothing for another force's building."""
    clear_enemies()  # a biter left from the shooting checks kills the character in the middle (see clear_enemies)
    if not clean_spot(c, hello):
        report(False, "repair: an empty spot", SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    fx = lambda v: math.floor(v * 256 + 0.5)  # world.fixed
    pid = {v[0]: k for k, v in c.protos.items()}
    out = mod_lua(f"""local c = storage.f3d.puppet local s = c.surface
local w = s.create_entity({{ name = 'stone-wall', position = {{ {x} + 2.5, {y} + 0.5 }}, force = c.force, raise_built = true }})
local en = s.create_entity({{ name = 'wooden-chest', position = {{ {x} - 2.5, {y} + 2.5 }}, force = 'enemy', raise_built = true }})
c.get_main_inventory().insert({{ name = 'repair-pack', count = 3 }})
w.health = 100 en.health = 20
storage.f3d_repair = {{ w = w, en = en }}
rcon.print(w.unit_number .. ' ' .. en.unit_number .. ' ' .. w.max_health .. ' ' .. w.position.x .. ' ' .. w.position.y
  .. ' ' .. en.position.x .. ' ' .. en.position.y)""".replace("\n", " "))
    try:
        wall, enemy, wall_max, wx, wy, ex, ey = (float(v) for v in out.split())
        wall, enemy = int(wall), int(enemy)
    except ValueError:
        report(False, "repair: a damaged wall and an enemy chest, repair packs in the inventory", out)
        return
    # Factorio's own repair_state on the player-less character, the wall selected: does its health move?
    out = mod_lua("""local c = storage.f3d.puppet local t = storage.f3d_repair
local okc, cur = pcall(function() return c.cursor_stack end)
local oks = pcall(function() c.selected = t.w end)
local ok, err = pcall(function() c.repair_state = { repairing = true, position = t.w.position } end)
t.before = t.w.health
rcon.print('cursor_stack ' .. tostring(okc and cur ~= nil) .. ', selected ' .. tostring(oks) .. ', repair_state written ' .. tostring(ok) .. ' ' .. tostring(err or ''))""".replace("\n", " "))
    c.pump(1.0, every=hello)
    after = mod_lua("""local c = storage.f3d.puppet local t = storage.f3d_repair
local ok, st = pcall(function() return c.repair_state end)
rcon.print(string.format('health %.1f -> %.1f, repair_state reads %s', t.before, t.w.health, ok and tostring(st and st.repairing) or 'error'))
pcall(function() c.repair_state = { repairing = false, position = c.position } end)
t.w.health = 100""".replace("\n", " "))
    print(f"  K13: Factorio's repair_state for a player-less character: {out}; after a second {after}")
    report(True, "repair: repair_state's answer printed (the bridge repairs itself)", f"{out}; {after}")

    def health(name):
        try:
            return float(mod_lua(f"rcon.print(storage.f3d_repair.{name}.health)"))
        except ValueError:
            return -1.0

    def pack():
        return mod_lua("local s = storage.f3d.puppet.get_main_inventory().find_item_stack('repair-pack') "
                       "rcon.print(s and (s.count .. ' ' .. s.durability) or 'none')")
    w0 = health("w")
    pack0 = pack()
    t0 = int(mod_lua("rcon.print(game.tick)") or 0)
    cmd = {"t": "repair", "u": wall, "p": pid.get("stone-wall", 0), "x": fx(wx), "y": fx(wy), "item": "repair-pack"}
    msgs = []
    end = time.time() + 1.0
    while time.time() < end:
        c.send(cmd)
        msgs += c.pump(0.15, every=hello)
    c.send({"t": "repair"})
    msgs += c.pump(0.3, every=hello)
    w1 = health("w")
    ticks = int(mod_lua("rcon.print(game.tick)") or 0) - t0
    pack1 = pack()
    rp = [m for m in of_type(msgs, "me") if m.get("rp") == 1]
    # table_to_json writes an empty list as {}: an `hp` with no bars has no list to read.
    hp_lists = [m["l"] if isinstance(m["l"], list) else [] for m in of_type(msgs, "hp")]
    bars = [dict(zip(l[::2], l[1::2])).get(wall) for l in hp_lists]
    print(f"  K13: the wall {w0:.0f} -> {w1:.0f} of {wall_max:.0f} in about {ticks} ticks; the pack {pack0} -> {pack1}")
    report(w1 > w0 + 100 and w1 <= wall_max, "repair: the wall mends while the client repeats `repair` (4 health a tick: speed 2, modifier 2)",
           f"{w0} -> {w1} in {ticks} ticks")
    report(pack1 != pack0, "repair: the pack's durability is used", f"{pack0} -> {pack1}")
    report(rp and rp[-1].get("rx") == fx(wx) and rp[-1].get("ry") == fx(wy), "repair: me says the character repairs (rp, rx, ry)",
           str(rp[-1:]))
    report(any(b is not None for b in bars), "repair: the wall's bar is in hp while it mends", str(bars[-3:]))
    w2 = health("w")
    c.pump(1.0, every=hello)
    report(health("w") == w2, "repair: `repair` without a target stops it", f"{w2} -> {health('w')}")
    e0 = health("en")
    c.send({"t": "repair", "u": enemy, "p": pid.get("wooden-chest", 0), "x": fx(ex), "y": fx(ey), "item": "repair-pack"})
    c.pump(1.0, every=hello)
    report(health("en") == e0, "repair: another force's chest isn't mended", f"{e0} -> {health('en')}")
    mod_lua("local t = storage.f3d_repair for _, e in pairs({ t.w, t.en }) do if e.valid then e.destroy({ raise_destroy = true }) end end "
            "storage.f3d.puppet.get_main_inventory().remove({ name = 'repair-pack', count = 3 }) storage.f3d_repair = nil rcon.print('ok')")


def check_vehicle_items(c, hello):
    """N2, N3, N4: the bridge's commands on vehicles in the real game. N2: Ctrl+click (`fast`) on a car, a tank, a
    spidertron, a locomotive and a cargo wagon (LuaEntity.insert: fuel to the fuel slot, ammo to the ammo slots, the
    rest to the trunk or cargo; a locomotive takes fuel only; an empty hand takes the trunk or cargo, a locomotive's
    nothing). N3: in an armed vehicle `guns` is the vehicle's (`v`, its guns over its ammo, `sel`), `gun` picks the
    vehicle's gun, `move` to role `vammo` loads it, out of it the character's guns come back; and printed: whether
    `shoot` fires the vehicle's gun for the player-less character. N4: `repair` mends a car and a cargo wagon, not
    another force's car."""
    clear_enemies()
    back = mod_lua("local p = storage.f3d.puppet.position rcon.print(p.x .. ' ' .. p.y)")
    if not clean_spot(c, hello):
        report(False, "vehicle items: an empty spot", SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    fx = lambda v: math.floor(v * 256 + 0.5)  # world.fixed
    pid = {v[0]: k for k, v in c.protos.items()}
    rails = " ".join(f's.create_entity({{ name = "straight-rail", position = {{ {x - 11 + 2 * i}, {y + 5} }}, direction = 4, force = c.force }})'
                     for i in range(12))
    specs = [("car", x + 4, y - 3, "player"), ("tank", x - 4, y - 3, "player"), ("spidertron", x, y - 8, "player"),
             ("locomotive", x - 4, y + 5, "player"), ("cargo-wagon", x + 4, y + 5, "player"), ("car", x + 8, y + 1, "enemy"),
             ("wooden-chest", x + 4.5, y - 12.5, "enemy")]
    lua = f"local c = storage.f3d.puppet local s = c.surface {rails} local out = {{}} "
    for name, ex, ey, force in specs:
        lua += (f'local e = s.create_entity({{ name = "{name}", position = {{ {ex}, {ey} }}, direction = 4, force = "{force}", raise_built = true }}) '
                'out[#out + 1] = e and (e.unit_number .. " " .. e.position.x .. " " .. e.position.y) or "0 0 0" ')
    # The spidertron's auto targeting (on without a gunner by default) fires its rockets at the enemy car and chest.
    lua += ("local sp = out[3] and game.get_entity_by_unit_number(tonumber(out[3]:match('^%d+'))) "
            "if sp then sp.vehicle_automatic_targeting_parameters = { auto_target_without_gunner = false, auto_target_with_gunner = false } end "
            "local m = c.get_main_inventory() m.insert({ name = 'wood', count = 40 }) m.insert({ name = 'firearm-magazine', count = 40 }) "
            "m.insert({ name = 'rocket', count = 20 }) m.insert({ name = 'iron-plate', count = 200 }) m.insert({ name = 'repair-pack', count = 5 }) "
            'rcon.print(table.concat(out, " "))')
    vals = mod_lua(lua).split()
    keys = ["car", "tank", "spidertron", "locomotive", "cargo-wagon", "enemy-car", "enemy-chest"]
    ents = {}
    for i, k in enumerate(keys):
        if 3 * i + 2 < len(vals) and int(float(vals[3 * i])):
            ents[k] = (int(float(vals[3 * i])), float(vals[3 * i + 1]), float(vals[3 * i + 2]))
    report(len(ents) == len(keys), "vehicle items: a car, a tank, a spidertron, a locomotive and a cargo wagon built, "
           "another force's car and chest", str(ents)[:300])
    if len(ents) < len(keys):
        destroy_units([v[0] for v in ents.values()])
        return
    c.pump(1.0, every=hello)
    name_of = {"enemy-car": "car", "enemy-chest": "wooden-chest"}

    def target(k):
        u, ex, ey = ents[k]
        return {"u": u, "p": pid.get(name_of.get(k, k), 0), "x": fx(ex), "y": fx(ey)}

    def count(k, inv, item):
        out = mod_lua(f"local e = game.get_entity_by_unit_number({ents[k][0]}) "
                      f"local ok, i = pcall(function() return e.get_inventory(defines.inventory.{inv}) end) "
                      f"rcon.print(ok and i and i.get_item_count('{item}') or -1)")
        return int(out) if out.lstrip("-").isdigit() else -2

    def main(item):
        out = mod_lua(f"rcon.print(storage.f3d.puppet.get_main_inventory().get_item_count('{item}'))")
        return int(out) if out.isdigit() else -1

    def fast(k, item=None, n=None):
        cmd = dict(target(k), t="fast")
        if item:
            cmd.update(item=item, n=n)
        else:
            cmd["half"] = 0
        c.send(cmd)
        return c.pump(0.8, every=hello)

    # --- N2: Ctrl+click on vehicles ---
    cases = [("car", "wood", 10, "fuel"), ("car", "firearm-magazine", 10, "car_ammo"), ("car", "iron-plate", 50, "car_trunk"),
             ("tank", "wood", 10, "fuel"), ("tank", "firearm-magazine", 10, "car_ammo"), ("tank", "iron-plate", 20, "car_trunk"),
             ("spidertron", "rocket", 10, "spider_ammo"), ("spidertron", "iron-plate", 20, "spider_trunk"),
             ("locomotive", "wood", 5, "fuel"), ("cargo-wagon", "iron-plate", 50, "cargo_wagon")]
    for k, item, n, inv in cases:
        m0, v0 = main(item), count(k, inv, item)
        msgs = fast(k, item, n)
        m1, v1 = main(item), count(k, inv, item)
        texts = [m["text"] for m in of_type(msgs, "msg")]
        report(v1 - v0 == n and m0 - m1 == n, f"N2: Ctrl+click on the {k} puts {n} {item} into its {inv}",
               f"{inv} {v0} -> {v1}, main {m0} -> {m1}, {texts}, slots sent {len(of_type(msgs, 'slots'))}")
    m0 = main("iron-plate")
    msgs = fast("locomotive", "iron-plate", 10)
    texts = [m["text"] for m in of_type(msgs, "msg")]
    report(main("iron-plate") == m0 and any("Can't put" in t for t in texts),
           "N2: a locomotive refuses plates (fuel only) and nothing leaves the inventory", f"main {m0} -> {main('iron-plate')}, {texts}")
    for k, inv, n in (("car", "car_trunk", 50), ("cargo-wagon", "cargo_wagon", 50), ("spidertron", "spider_trunk", 20)):
        m0 = main("iron-plate")
        fast(k)
        report(count(k, inv, "iron-plate") == 0 and main("iron-plate") - m0 == n,
               f"N2: Ctrl+click on the {k} with an empty hand takes its {inv} out",
               f"main {m0} -> {main('iron-plate')}, left {count(k, inv, 'iron-plate')}")
    report(count("car", "fuel", "wood") == 10 and count("car", "car_ammo", "firearm-magazine") == 10,
           "N2: and leaves the car's fuel and ammo where they are",
           f"fuel {count('car', 'fuel', 'wood')} wood, ammo {count('car', 'car_ammo', 'firearm-magazine')} magazines")
    w0 = main("wood")
    msgs = fast("locomotive")
    texts = [m["text"] for m in of_type(msgs, "msg")]
    report(count("locomotive", "fuel", "wood") == 5 and main("wood") == w0,
           "N2: Ctrl+click on a locomotive with an empty hand takes nothing (no trunk; its fuel stays)",
           f"fuel 5 -> {count('locomotive', 'fuel', 'wood')}, main wood {w0} -> {main('wood')}, {texts}")
    # Burners whose fuel 2.1 hands out as inventory 1 (defines.inventory.chest is fuel too) or as their output
    # inventory (a burner drill's): an empty hand takes nothing from them either (/f3d-perf fast_take).
    burners = [("boiler", x - 8.5, y + 10), ("burner-mining-drill", x - 3, y + 10), ("burner-inserter", x + 0.5, y + 10.5)]
    mod_lua(f"storage.f3d.puppet.teleport({{ {x - 3}, {y + 7} }})")
    lua = "local c = storage.f3d.puppet local out = {} "
    for name, bx, by in burners:
        lua += (f'local e = c.surface.create_entity({{ name = "{name}", position = {{ {bx}, {by} }}, force = c.force, raise_built = true }}) '
                "if e then e.get_fuel_inventory().insert({ name = 'wood', count = 5 }) end "
                'out[#out + 1] = e and (e.unit_number .. " " .. e.position.x .. " " .. e.position.y) or "0 0 0" ')
    vals = mod_lua(lua + 'rcon.print(table.concat(out, " "))').split()
    c.pump(0.6, every=hello)
    for i, (name, _bx, _by) in enumerate(burners):
        if 3 * i + 2 >= len(vals) or not int(float(vals[3 * i])):
            report(False, f"N2: a {name} built for the empty-hand Ctrl+click", str(vals))
            continue
        u = int(float(vals[3 * i]))
        ents[name] = (u, float(vals[3 * i + 1]), float(vals[3 * i + 2]))
        w0 = main("wood")
        msgs = fast(name)
        texts = [m["text"] for m in of_type(msgs, "msg")]
        # (get_entity_by_unit_number finds vehicles and units, not buildings.)
        left = mod_lua(f"local n = -1 for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = '{name}', "
                       f"position = {{ {ents[name][1]}, {ents[name][2]} }}, radius = 0.5 }})) do "
                       "if e.unit_number == " + str(u) + " then n = e.get_fuel_inventory().get_item_count('wood') end end rcon.print(n)")
        # (A burner may have taken one into its fire meanwhile: the drill burns with nothing to mine.)
        report(left in ("4", "5") and main("wood") == w0, f"N2: Ctrl+click on a {name} with an empty hand leaves its fuel",
               f"fuel 5 -> {left}, main wood {w0} -> {main('wood')}, {texts}")
    # A lab's packs and a gun turret's ammo are taken, as before the fuel fix (Factorio's wiki only says "takes
    # anything the entity has"; whether Factorio does for these is the owner's to try).
    holders = [("lab", x + 5, y + 10.5, "lab_input", "automation-science-pack"),
               ("gun-turret", x + 9, y + 10, "turret_ammo", "firearm-magazine")]
    lua = "local c = storage.f3d.puppet local out = {} "
    for name, hx, hy, inv, item in holders:
        lua += (f'local e = c.surface.create_entity({{ name = "{name}", position = {{ {hx}, {hy} }}, force = c.force, raise_built = true }}) '
                f"if e then e.get_inventory(defines.inventory.{inv}).insert({{ name = '{item}', count = 3 }}) end "
                'out[#out + 1] = e and (e.unit_number .. " " .. e.position.x .. " " .. e.position.y) or "0 0 0" ')
    vals = mod_lua(lua + 'rcon.print(table.concat(out, " "))').split()
    mod_lua(f"storage.f3d.puppet.teleport({{ {x + 6}, {y + 7} }})")
    c.pump(0.6, every=hello)
    for i, (name, _hx, _hy, inv, item) in enumerate(holders):
        if 3 * i + 2 >= len(vals) or not int(float(vals[3 * i])):
            report(False, f"N2: a {name} built for the empty-hand Ctrl+click", str(vals))
            continue
        u = int(float(vals[3 * i]))
        ents[name] = (u, float(vals[3 * i + 1]), float(vals[3 * i + 2]))
        total = lambda: mod_lua(f"rcon.print(storage.f3d.puppet.get_item_count('{item}'))")
        t0 = total()
        msgs = fast(name)
        left = mod_lua(f"local n = -1 for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = '{name}', "
                       f"position = {{ {ents[name][1]}, {ents[name][2]} }}, radius = 0.5 }})) do "
                       f"if e.unit_number == {u} then n = e.get_inventory(defines.inventory.{inv}).get_item_count('{item}') end end rcon.print(n)")
        t1 = total()
        report(left == "0" and t0.isdigit() and t1.isdigit() and int(t1) - int(t0) >= 2,  # (2.1.24 counted 30 -> 32 once: into the ammo slots)
               f"N2: Ctrl+click on a {name} with an empty hand takes its {item}, as before",
               f"left {left}, the character's {t0} -> {t1}, {[m['text'] for m in of_type(msgs, 'msg')]}")

    # --- N3: the vehicle's guns while the character sits in it ---
    def enter(k, dx=0.0, dy=2.5):
        u, ex, ey = ents[k]
        mod_lua(f"storage.f3d.puppet.teleport({{ {ex + dx}, {ey + dy} }})")
        c.pump(0.3, every=hello)
        c.last.pop("guns", None)
        c.send({"t": "enter"})
        msgs = c.pump(1.5, every=hello)
        inside = mod_lua("local v = storage.f3d.puppet.vehicle rcon.print(v and v.unit_number or 0)")
        return inside == str(u), msgs

    def last_guns(msgs):
        g = of_type(msgs, "guns")
        return g[-1] if g else c.last.get("guns") or {}

    ok, msgs = enter("car")
    g = last_guns(msgs)
    l = g.get("l") or []
    report(ok and g.get("v") == ents["car"][0] and g.get("sel") == 1 and len(l) == 1
           and l[0][:3] == ["vehicle-machine-gun", "firearm-magazine", 10] and l[0][4] == 10 and l[0][3] > 0,
           "N3: in the car `guns` is the car's: its machine gun over its 10 magazines, rounds and magazine size, sel 1, v the car",
           f"in {ok}, {g}")
    report(c.me and c.me.get("v") == ents["car"][0], "N3: and me says the character sits in it (v)", str(c.me and c.me.get("v")))
    # move with role vammo: a stack from the main inventory into the car's ammo.
    slot = mod_lua("local m = storage.f3d.puppet.get_main_inventory() for i = 1, #m do "
                   "if m[i].valid_for_read and m[i].name == 'firearm-magazine' then rcon.print(i) return end end rcon.print(0)")
    a0 = count("car", "car_ammo", "firearm-magazine")
    c.send({"t": "move", "from": "main", "fi": int(slot) if slot.isdigit() else 0, "to": "vammo", "ti": 1, "n": 5})
    msgs = c.pump(1.0, every=hello)
    g = last_guns(msgs)
    a1 = count("car", "car_ammo", "firearm-magazine")
    report(a1 - a0 == 5 and (g.get("l") or [[0, 0, 0]])[0][2] == a1,
           "N3: move to role vammo puts 5 magazines into the car's ammo, and guns follows", f"car ammo {a0} -> {a1}, {g.get('l')}")
    # shoot: does the character's shooting_state fire the car's gun? An enemy chest under the aim point.
    rounds = lambda: mod_lua(f"local e = game.get_entity_by_unit_number({ents['car'][0]}) local s = e.get_inventory(defines.inventory.car_ammo)[1] "
                             "local ch = storage.f3d.puppet.get_inventory(defines.inventory.character_ammo)[1] "
                             "rcon.print((s.valid_for_read and (s.count * 10 + s.ammo - 10) or 0) .. ' ' .. "
                             "(ch.valid_for_read and (ch.count * 10 + ch.ammo - 10) or 0))")
    chest = lambda: mod_lua(f"local t for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'wooden-chest', force = 'enemy', "
                            f"position = {{ {ents['enemy-chest'][1]}, {ents['enemy-chest'][2]} }}, radius = 0.6 }})) do t = e end "
                            "rcon.print(t and t.health or 'gone')")
    r0, h0 = rounds(), chest()
    _u, cx_, cy_ = ents["enemy-chest"]
    shoot = {"t": "shoot", "m": 1, "x": fx(cx_), "y": fx(cy_)}
    msgs = c.pump(2.0, every=(0.2, shoot))
    c.send({"t": "shoot", "m": -1})
    msgs += c.pump(0.5, every=hello)
    r1, h1 = rounds(), chest()
    shots = of_type(msgs, "shot")
    texts = [m["text"] for m in of_type(msgs, "msg")]
    fired = r0.split()[:1] != r1.split()[:1]
    print(f"  N3: shoot (m 1, at an enemy chest 9 tiles off) from inside the car for 2 s: car, character rounds {r0} -> {r1}, "
          f"chest {h0} -> {h1}, `shot` {len(shots)} {[s.get('g') for s in shots[:2]]}, "
          f"me.sh {[m.get('sh') for m in of_type(msgs, 'me')][-3:]}, msgs {texts}")
    report(fired, "N3: `shoot` fires the car's gun for the player-less character (its rounds go down)", f"{r0} -> {r1}")
    # The bridge's side (/f3d-perf vehicle_ammo): me.sh follows the car's ammo, the car's shots come in `ts` (the client's
    # turrets.gd draws them from the car's gun) and no `shot` from the character's own guns; no "Out of ammo" while the
    # car has some.
    car_u, me_u = ents["car"][0], (c.me or {}).get("u")
    ts_shots = sum(r[2] for m in of_type(msgs, "ts") for r in (m.get("l") or []) if r and r[0] == car_u)
    report(fired and any(m.get("sh") == 1 for m in of_type(msgs, "me")), "N3: me.sh is 1 while the car's gun fires",
           f"me with sh 1: {sum(m.get('sh') == 1 for m in of_type(msgs, 'me'))} of {len(of_type(msgs, 'me'))}")
    report(fired and ts_shots > 0 and not [s for s in shots if s.get("u") == me_u],
           "N3: the car's shots come in ts (its unit, shots counted), no `shot` from the character's guns",
           f"ts shots {ts_shots}, shot {[(s.get('u'), s.get('g')) for s in shots[:3]]}")
    report("Out of ammo" not in texts, "N3: no Out of ammo while the car has ammo", str(texts))
    # m 0 (Factorio's Space: the nearest enemies) from the car: the enemy car 6 tiles off.
    r0 = rounds()
    near = {"t": "shoot", "m": 0, "x": fx(ents["car"][1]), "y": fx(ents["car"][2])}
    msgs = c.pump(2.0, every=(0.2, near))
    c.send({"t": "shoot", "m": -1})
    msgs += c.pump(0.5, every=hello)
    r1 = rounds()
    fired0 = r0.split()[:1] != r1.split()[:1]
    ts0 = sum(r[2] for m in of_type(msgs, "ts") for r in (m.get("l") or []) if r and r[0] == car_u)
    print(f"  N3: shoot m 0 from inside the car for 2 s: car, character rounds {r0} -> {r1}, ts shots {ts0}, "
          f"me with sh 1: {sum(m.get('sh') == 1 for m in of_type(msgs, 'me'))} of {len(of_type(msgs, 'me'))}")
    report(not fired0 or any(m.get("sh") == 1 for m in of_type(msgs, "me")),
           "N3: shoot m 0 from the car: when the game fires the car's gun at the nearest enemy, me.sh says so",
           "fires" if fired0 else "the game didn't fire (m 0 printed)")
    # Out of the car the character's own guns come back.
    c.last.pop("guns", None)
    c.send({"t": "enter"})
    msgs = c.pump(1.5, every=hello)
    g = last_guns(msgs)
    out = mod_lua("rcon.print(storage.f3d.puppet.vehicle and 'in' or 'out')")
    report(out == "out" and g and "v" not in g and (g.get("l") or [[""]])[0][0] == "pistol",
           "N3: out of the car the character's guns come back (no v, the pistol)", f"{out}, {g}")
    # A tank: three guns, gun 2 its cannon.
    ok, msgs = enter("tank", 0, 3.0)
    c.send({"t": "gun", "i": 2})
    msgs += c.pump(1.0, every=hello)
    g = last_guns(msgs)
    sel = mod_lua(f"rcon.print(game.get_entity_by_unit_number({ents['tank'][0]}).selected_gun_index)")
    order = mod_lua("local o = {} for _, gp in ipairs(prototypes.entity['tank'].indexed_guns) do o[#o + 1] = gp.name end "
                    "rcon.print(table.concat(o, ' '))").split()
    names = [r[0] for r in g.get("l") or []]
    # 2.1's tank: cannon, machine gun, flamethrower (indexed_guns); the magazines put in went to the machine gun's slot.
    mg = order.index("tank-machine-gun") if "tank-machine-gun" in order else 0
    report(ok and sel == "2" and g.get("sel") == 2 and g.get("v") == ents["tank"][0] and names == order
           and sorted(names) == ["tank-cannon", "tank-flamethrower", "tank-machine-gun"]
           and (g.get("l") or [])[mg:mg + 1] and g["l"][mg][1] == "firearm-magazine",
           "N3: a tank's three guns in indexed_guns' order, its magazines under the machine gun, gun i=2 selects the second "
           "(the vehicle's selected_gun_index)", f"in {ok}, sel {sel}, indexed_guns {order}, {g}")
    c.send({"t": "enter"})
    c.pump(1.0, every=hello)
    ok, msgs = enter("spidertron", 0, 2.5)
    g = last_guns(msgs)
    l = g.get("l") or []
    report(ok and g.get("v") == ents["spidertron"][0] and len(l) == 4 and l[0][1] == "rocket" and l[0][2] == 10,
           "N3: a spidertron's four rocket launchers over its spider_ammo (the 10 rockets)", f"in {ok}, {g}")
    c.send({"t": "enter"})
    c.pump(1.0, every=hello)

    # --- N4: repair packs on vehicles ---
    mod_lua(f"storage.f3d.puppet.teleport({{ {x}, {y} }}) for _, u in pairs({{ {ents['car'][0]}, {ents['cargo-wagon'][0]}, {ents['enemy-car'][0]} }}) do "
            "local e = game.get_entity_by_unit_number(u) e.health = e.max_health - 150 end")
    c.pump(0.5, every=hello)

    def health(k):
        out = mod_lua(f"local e = game.get_entity_by_unit_number({ents[k][0]}) rcon.print(e.health .. ' ' .. e.max_health)")
        try:
            h, mx = (float(v) for v in out.split())
            return h, mx
        except ValueError:
            return -1.0, -1.0

    for k in ("car", "cargo-wagon"):
        h0, mx = health(k)
        cmd = dict(target(k), t="repair", item="repair-pack")
        msgs = []
        end = time.time() + 2.0
        while time.time() < end:
            c.send(cmd)
            msgs += c.pump(0.15, every=hello)
        c.send({"t": "repair"})
        msgs += c.pump(0.3, every=hello)
        h1, _ = health(k)
        rp = [m for m in of_type(msgs, "me") if m.get("rp") == 1]
        hp_lists = [m["l"] if isinstance(m["l"], list) else [] for m in of_type(msgs, "hp")]
        bars = [dict(zip(l[::2], l[1::2])).get(ents[k][0]) for l in hp_lists]
        texts = [m["text"] for m in of_type(msgs, "msg")]
        print(f"  N4: {k}: {len(hp_lists)} hp messages, the last {hp_lists[-2:]}, rp from tick "
              f"{[m.get('k') for m in rp][:1]} to {[m.get('k') for m in rp][-1:]}")
        report(h1 == mx and h0 < mx, f"N4: `repair` mends the damaged {k} to full", f"{h0} -> {h1} of {mx}, {texts}")
        report(rp and rp[-1].get("rx") == target(k)["x"], f"N4: me says the character repairs the {k} (rp, rx)", str(rp[-1:]))
        report(any(b is not None for b in bars), f"N4: the {k}'s bar is in hp while it mends", str(bars[-3:]))
    e0, _ = health("enemy-car")
    c.send(dict(target("enemy-car"), t="repair", item="repair-pack"))
    c.pump(1.0, every=hello)
    c.send({"t": "repair"})
    report(health("enemy-car")[0] == e0, "N4: another force's car isn't mended", f"{e0} -> {health('enemy-car')[0]}")

    # Clean up: everything built, the rails, what was put in the inventory.
    mod_lua("local c = storage.f3d.puppet if c.vehicle then c.driving = false end")
    destroy_units([v[0] for k, v in ents.items() if not k.startswith("enemy")])
    mod_lua(f"local c = storage.f3d.puppet local e = game.get_entity_by_unit_number({ents['enemy-car'][0]}) if e then e.destroy() end "
            f"for _, r in pairs(c.surface.find_entities_filtered({{ area = {{ {{ {x - 14}, {y - 14} }}, {{ {x + 14}, {y + 7} }} }}, "
            "name = { 'straight-rail', 'car', 'tank', 'spidertron', 'locomotive', 'cargo-wagon', 'wooden-chest' } })) do r.destroy() end "
            "local m = c.get_main_inventory() for _, it in pairs({ { 'wood', 40 }, { 'firearm-magazine', 40 }, { 'rocket', 20 }, "
            "{ 'iron-plate', 200 }, { 'repair-pack', 5 } }) do m.remove({ name = it[1], count = it[2] }) end rcon.print('ok')")
    if len(back.split()) == 2:
        bx, by = (float(v) for v in back.split())
        mod_lua(f"storage.f3d.puppet.teleport({{ {bx}, {by} }})")
        watch_around(c, hello, bx, by)


def check_under_clear(c, hello):
    """M2: an underground pair the client builds over a run of belts mines the belts between into the character, their
    items too, as Factorio's player build does (its tips and tricks: "Any belts in between the entrance and exit of the
    underground belt will be mined automatically"), each said at once (`mnd`); pipes-to-ground over pipes the same.
    A run with a belt side-loading into it keeps its belts (only "simple" ones go), and so does one with the switch
    off. First whether a script's create_entity{fast_replace, character} does it by itself (printed: in 2.1.24 it
    doesn't, so the bridge mines them)."""
    clear_enemies()  # a biter left from the shooting checks kills the character in the middle (see clear_enemies)
    if not clean_spot(c, hello):
        report(False, "under_clear: an empty spot", SPOT_WHY)
        return
    x, y = math.floor(c.me["x"] / 256), math.floor(c.me["y"] / 256)
    fx = lambda v: math.floor(v * 256 + 0.5)  # world.fixed
    # Rows (y + dy), every lane full so nothing moves (a line backed up to its end): 2 a plain east run, 8 plates a
    # belt, 4 the same with a belt side-loading into its third,
    # 6 pipes, 8 a plain run built with the switch off, 10 the script's own create_entity (character, fast_replace),
    # -2 a plain run whose two ends are sent together (a drag's pair; within the character's reach, as the rest).
    out = mod_lua(f"""local c = storage.f3d.puppet local s = c.surface
local t = {{ rows = {{}} }}
for _, dy in pairs({{ 2, 4, 6, 8, 10, -2 }}) do
  local row = {{}}
  for i = 0, 6 do
    local e = s.create_entity({{ name = dy == 6 and 'pipe' or 'transport-belt', position = {{ {x} + i + 0.5, {y} + dy + 0.5 }},
      direction = defines.direction.east, force = c.force, raise_built = true }})
    if dy ~= 6 then
      for l = 1, 2 do for k = 0, 3 do e.get_transport_line(l).insert_at(0.125 + 0.25 * k, {{ name = 'iron-plate', count = 1 }}) end end
    end
    row[#row + 1] = e
  end
  t.rows[dy] = row
end
t.side = s.create_entity({{ name = 'transport-belt', position = {{ {x} + 2.5, {y} + 3.5 }}, direction = defines.direction.south,
  force = c.force, raise_built = true }})
c.get_main_inventory().insert({{ name = 'underground-belt', count = 10 }})
c.get_main_inventory().insert({{ name = 'pipe-to-ground', count = 2 }})
storage.f3d_m2 = t
local u = {{}} for i = 2, 5 do u[#u + 1] = t.rows[2][i].unit_number end
rcon.print(table.concat(u, ' '))""".replace("\n", " "))
    try:
        middle = {int(v) for v in out.split()}
    except ValueError:
        report(False, "under_clear: belt runs and pipes laid, undergrounds in the inventory", out)
        return
    # The script's own create_entity with the character: does the game mine the run between? (Printed.)
    own = mod_lua(f"""local c = storage.f3d.puppet local s = c.surface local t = storage.f3d_m2
local a = s.create_entity({{ name = 'underground-belt', position = {{ {x} + 0.5, {y} + 10.5 }}, direction = defines.direction.east,
  type = 'input', force = c.force, fast_replace = true, character = c }})
local b = s.create_entity({{ name = 'underground-belt', position = {{ {x} + 5.5, {y} + 10.5 }}, direction = defines.direction.east,
  type = 'output', force = c.force, fast_replace = true, character = c }})
local n = 0 for i = 2, 5 do if t.rows[10][i].valid then n = n + 1 end end
local paired = a and b and a.underground_belt_neighbour == b
for _, e in pairs({{ a, b }}) do if e and e.valid then e.destroy() end end
rcon.print('paired ' .. tostring(paired) .. ', ' .. n .. ' of 4 between still there')""".replace("\n", " "))
    print(f"  M2: a script's create_entity{{fast_replace, character}} pair over a run: {own}")
    report(True, "under_clear: what a script's own fast-replace pair does to the run printed (the bridge mines it)", own)

    def count(item):
        try:
            return int(mod_lua(f"rcon.print(storage.f3d.puppet.get_main_inventory().get_item_count('{item}'))"))
        except ValueError:
            return -1

    def build(item, dy, x0, d0, x1, d1):
        msgs = []
        for bx, d in ((x0, d0), (x1, d1)):
            c.send({"t": "build", "item": item, "x": fx(x + bx + 0.5), "y": fx(y + dy + 0.5), "d": d})
            msgs += c.pump(0.4, every=hello)
        return msgs + c.pump(1.0, every=hello)

    def alive(dy):
        return mod_lua(f"local r = {{}} for _, e in ipairs(storage.f3d_m2.rows[{dy}]) do r[#r + 1] = e.valid and '1' or '0' end "
                       "rcon.print(table.concat(r))")

    belts0, plates0 = count("transport-belt"), count("iron-plate")
    msgs = build("underground-belt", 2, 0, 4, 5, 4)
    row2 = alive(2)
    mnd = {m["u"]: m for m in of_type(msgs, "mnd") if m["u"] in middle}
    dels = {d["u"] for d in of_type(msgs, "del")}
    belts1, plates1 = count("transport-belt"), count("iron-plate")
    print(f"  M2: row {row2} (ends and the four between gone, the last kept), mnd {sorted(mnd)}, belts {belts0} -> {belts1}, "
          f"plates {plates0} -> {plates1}")
    report(row2 == "0000001", "under_clear: an underground pair over a plain run mines the four belts between", row2)
    report(set(mnd) == middle and all(m["g"] == 1 and ["transport-belt", 1] in m["l"] and ["iron-plate", 8] in m["l"]
                                      for m in mnd.values()),
           "under_clear: each is said at once (`mnd`: gone, the belt and its 8 plates to the character)", str(list(mnd.values())[:2]))
    report(middle <= dels, "under_clear: and their `del`s come", f"{sorted(middle - dels)} missing")
    report(belts1 - belts0 == 6 and plates1 - plates0 == 48,
           "under_clear: six belts (four between, the two the ends replaced) and their 48 plates in the inventory",
           f"belts +{belts1 - belts0}, plates +{plates1 - plates0}")
    build("underground-belt", 4, 0, 4, 5, 4)
    report(alive(4)[1:5] == "1111", "under_clear: a run with a belt side-loading into it keeps its belts", alive(4))
    pipes0 = count("pipe")
    build("pipe-to-ground", 6, 0, 12, 5, 4)
    row6 = alive(6)
    report(row6 == "0000001" and count("pipe") - pipes0 == 6, "under_clear: a pipe-to-ground pair over pipes mines the four between",
           f"{row6}, pipes +{count('pipe') - pipes0}")
    # M2's leftover: a drag sends both ends back to back (one datagram each, the same tick or the next): the run
    # between is mined just the same, said in the answer to the exit (what the client hides ahead of).
    for bx in (0, 5):
        c.send({"t": "build", "item": "underground-belt", "x": fx(x + bx + 0.5), "y": fx(y - 2 + 0.5), "d": 4})
    msgs = c.pump(1.5, every=hello)
    row12 = alive(-2)
    said = len([m for m in of_type(msgs, "mnd") if m.get("g") == 1 and ["transport-belt", 1] in m.get("l", [])])
    report(row12 == "0000001" and said == 4, "under_clear: both ends sent together (a drag's pair): the four between mined, an `mnd` each",
           f"{row12}, {said} mnd")
    rcon.run("/f3d-perf under_clear off")
    build("underground-belt", 8, 0, 4, 5, 4)
    rcon.run("/f3d-perf under_clear default")
    report(alive(8)[1:5] == "1111", "under_clear: /f3d-perf under_clear off keeps the run, as before", alive(8))
    check_splitter_snap(c, hello, x, y)
    mod_lua(f"""local c = storage.f3d.puppet local s = c.surface
for _, e in pairs(s.find_entities_filtered({{ area = {{ {{ {x} - 1, {y} - 5 }}, {{ {x} + 8, {y} + 12 }} }},
  type = {{ 'transport-belt', 'underground-belt', 'pipe', 'pipe-to-ground', 'splitter' }} }})) do e.destroy({{ raise_destroy = true }}) end
storage.f3d_m2 = nil rcon.print('ok')""".replace("\n", " "))


def check_splitter_snap(c, hello, x, y):
    """J9 (the owner: placing a splitter over a belt sometimes shifts it over one tile): a splitter built over a row of
    belts stands where the cursor's point snaps, as Factorio's prototype docs say for an even tile_width ("the center is
    on the tile transition") and an odd one (the tile's middle): on the tile edge nearest the cursor across, so over the
    belt under the cursor and the one on the side the cursor leans to, both replaced and given back. First what the
    game's own create_entity makes of unsnapped points (printed): the same rule in every direction."""
    own = mod_lua(f"""local c = storage.f3d.puppet local s = c.surface local n, bad = 0, 0
local function snap(v, size) if size % 2 == 1 then return math.floor(v) + 0.5 end return math.floor(v + 0.5) end
for _, d in pairs({{ defines.direction.north, defines.direction.east, defines.direction.south, defines.direction.west }}) do
  local w, h = 2, 1 if d == defines.direction.east or d == defines.direction.west then w, h = 1, 2 end
  for _, f in pairs({{ 0.004, 0.25, 0.496, 0.5, 0.504, 0.75, 0.996 }}) do for _, g in pairs({{ 0.3, 0.7 }}) do for swap = 0, 1 do
    local cx, cy = {x} + 20 + f, {y} - 4 + g if swap == 1 then cx, cy = {x} + 20 + g, {y} - 4 + f end
    local e = s.create_entity({{ name = 'splitter', position = {{ cx, cy }}, direction = d, force = c.force }}) n = n + 1
    if not e or e.position.x ~= snap(cx, w) or e.position.y ~= snap(cy, h) then bad = bad + 1 end
    if e then e.destroy() end
  end end end
end
rcon.print(n .. ' placements, ' .. bad .. ' off the rule')""".replace("\n", " "))
    print(f"  J9: the game's own create_entity snaps a splitter's point (every direction): {own}")
    report(own.endswith(" 0 off the rule"), "J9: Factorio snaps a splitter as the bridge and the client do (odd: the tile's middle, even: the nearest tile edge)", own)
    out = mod_lua(f"""local c = storage.f3d.puppet local s = c.surface local u = {{}}
for i = 0, 6 do local e = s.create_entity({{ name = 'transport-belt', position = {{ {x} + i + 0.5, {y} - 4 + 0.5 }},
  direction = defines.direction.north, force = c.force, raise_built = true }}) u[#u + 1] = e.unit_number end
c.get_main_inventory().insert({{ name = 'splitter', count = 2 }}) rcon.print(table.concat(u, ' '))""".replace("\n", " "))
    try:
        row = [int(v) for v in out.split()]
    except ValueError:
        row = []
    if len(row) != 7:
        report(False, "J9: a row of belts for the splitters", out)
        return
    c.pump(0.5, every=hello)
    fx = lambda v: math.floor(v * 256 + 0.5)
    got = []
    # The cursor in the left half of the second belt's tile, then in the right half of the fifth's: sent as the
    # client sends it (rounded down to 1/256 tile).
    for cx, want_x, under in ((x + 1.3, x + 1, row[0:2]), (x + 4.7, x + 5, row[4:6])):
        c.send({"t": "build", "item": "splitter", "x": math.floor(cx * 256), "y": math.floor((y - 4 + 0.4) * 256), "d": 0})
        msgs = c.pump(1.0, every=hello)
        adds = [a["e"][2:5] for a in of_type(msgs, "add") if a["e"][1] == c.proto_id("splitter")]
        dels = {d["u"] for d in of_type(msgs, "del")}
        got.append((adds[:1] == [[fx(want_x), fx(y - 4 + 0.5), 0]], set(under) <= dels, adds[:1], sorted(dels & set(row))))
    report(all(g[0] for g in got), "J9: a splitter over belts stands on the tile edge on the cursor's side of the belt under it",
           str([g[2] for g in got]))
    report(all(g[1] for g in got), "J9: and replaces both belts under it (their `del`s)", str([g[3] for g in got]))


def check_pipe_end(c, hello):
    """The owner's FUE5 pipe left open where its run now ends (and a T left a T): the bridge's player-less character
    mines with LuaControl.mine_entity, which raises no event, so the pipes and belts beside what it mined never had
    their shapes sent again (`pc`, a belt's `s`); `/f3d-perf mined_neighbours` queues them for the next tick. Each case
    is built, its piece removed (the bridge's `mine`, damage, a construction robot) and the neighbours' `upd` waited
    for: a run of five losing its middle (endings), a corner, a T losing its branch (a straight), a cross losing an arm
    (a T), a pipe-to-ground and a pipe beside each other, a pump and a storage tank under pipes, a belt curve
    straightened, a side-loaded belt curving once the belt behind it goes, a pipe `die`d, one a robot deconstructs, and
    the switch off (no `upd`). Walls and heat pipes are joined by the client itself (no shape from the bridge: checked),
    so only their `del` is looked for."""
    clear_enemies()
    if not clean_spot(c, hello):
        report(False, "pipe end: an empty spot", SPOT_WHY)
        return
    x, y = math.floor(c.me["x"] / 256), math.floor(c.me["y"] / 256)
    home = (x + 0.5, y + 0.5)
    area = f"{{ {{ {x} - 9, {y} + 1 }}, {{ {x} + 9, {y} + 12 }} }}"
    types = ("{ 'pipe', 'pipe-to-ground', 'pump', 'transport-belt', 'wall', 'heat-pipe', 'storage-tank', 'roboport', "
             "'electric-energy-interface', 'electric-pole', 'logistic-container', 'construction-robot', 'item-entity' }")
    N, E, S, W = 0, 4, 8, 12

    def clear():
        mod_lua(f"local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({{ area = {area}, "
                f"type = {types} }})) do e.destroy({{ raise_destroy = true }}) end rcon.print('ok')")
        c.pump(0.6, every=hello)

    def lay(parts):
        """parts: (name, dx, dy, direction) from (x, y + 2); their unit numbers and their latest records sent."""
        lines = []
        for name, dx, dy, d in parts:
            lines.append(f"u[#u + 1] = s.create_entity({{ name = '{name}', position = {{ {x} + {dx}, {y} + 2 + {dy} }}, "
                         f"direction = {d}, force = c.force, raise_built = true }}).unit_number")
        out = mod_lua("local c = storage.f3d.puppet local s = c.surface local u = {} " + " ".join(lines)
                      + " rcon.print(table.concat(u, ' '))")
        try:
            units = [int(v) for v in out.split()]
        except ValueError:
            return None, {}, out
        recs = {}
        for m in c.pump(1.0, every=hello):
            if m.get("t") in ("add", "upd") and m["e"][0] in units:
                recs[m["e"][0]] = m["e"]
        return units, recs, out

    def remove_and_watch(unit, rec, watch, how="mine"):
        """Removes `unit` (the bridge's `mine`; `die`; "robot": already ordered), then waits for every unit in `watch`
        to be sent again: ({unit: (record, seconds after the del)}, whether its del came)."""
        if how == "die":
            mod_lua(f"local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({{ area = {area} }})) do "
                    f"if e.unit_number == {unit} then e.die() end end rcon.print('ok')")
        cmd = {"t": "mine", "u": unit, "p": rec[1], "x": rec[2], "y": rec[3]} if rec else None
        t_del, got = None, {}
        end = time.time() + (30 if how == "robot" else 6)
        while time.time() < end:
            if how == "mine" and t_del is None and cmd:
                c.send(cmd)
            for m in c.pump(0.15, every=hello):
                if m.get("t") == "del" and m.get("u") == unit and t_del is None:
                    t_del = time.time()
                if m.get("t") == "upd" and m["e"][0] in watch and t_del is not None:
                    got.setdefault(m["e"][0], (m["e"], round(time.time() - t_del, 2)))
            if t_del is not None and (len(got) == len(watch) or time.time() - t_del > 1.5):
                break
        if how == "mine":
            c.send({"t": "mine_stop"})
        return got, t_del is not None

    def extra(rec, key):
        return rec[5].get(key) if rec and len(rec) > 5 and isinstance(rec[5], dict) else None

    mod_lua(f"storage.f3d.puppet.teleport({{ {home[0]}, {home[1]} }})")
    print("  pipe end: act-as-player " + mod_lua("rcon.print(tostring(settings.global['f3d-act-as-player'].value))")
          + ", players connected " + mod_lua("rcon.print(#game.connected_players)") + " (none: the bridge mines with mine_entity)")

    def pipe_case(label, parts, target, expect, how="mine"):
        """expect: {index in parts: the pc wanted after} (1 north, 2 east, 4 south, 8 west)."""
        units, recs, out = lay(parts)
        if units is None:
            report(False, f"pipe end: {label}: laid", out)
            clear()
            return
        before = {i: extra(recs.get(units[i]), "pc") for i in expect}
        got, gone = remove_and_watch(units[target], recs.get(units[target]), {units[i] for i in expect}, how)
        after = {i: (extra(got[units[i]][0], "pc") if units[i] in got else None) for i in expect}
        secs = {i: got[units[i]][1] for i in expect if units[i] in got}
        report(gone and after == expect and all(v <= 0.6 for v in secs.values()),
               f"pipe end: {label}: the neighbours sent again at once with their new shape",
               f"removed {gone}, pc before {before}, after {after} (wanted {expect}), seconds after the del {secs}")
        clear()

    pipe_case("a run of five, its middle mined", [("pipe", dx + 0.5, 0.5, N) for dx in range(-2, 3)], 2, {1: 8, 3: 2})
    pipe_case("a corner losing its south side", [("pipe", -0.5, 0.5, N), ("pipe", 0.5, 0.5, N), ("pipe", 0.5, 1.5, N)],
              2, {1: 8})
    pipe_case("a T losing its branch (the owner's T): a straight",
              [("pipe", -0.5, 0.5, N), ("pipe", 0.5, 0.5, N), ("pipe", 1.5, 0.5, N), ("pipe", 0.5, 1.5, N)], 3, {1: 10})
    pipe_case("a cross losing its north arm: a T",
              [("pipe", -0.5, 1.5, N), ("pipe", 0.5, 1.5, N), ("pipe", 1.5, 1.5, N), ("pipe", 0.5, 2.5, N),
               ("pipe", 0.5, 0.5, N)], 4, {1: 14, 0: 2, 2: 8})  # (the south arm, two tiles off, keeps its side: not sent)
    pipe_case("a pipe-to-ground mined beside a pipe",
              [("pipe", -0.5, 0.5, N), ("pipe", 0.5, 0.5, N), ("pipe-to-ground", 1.5, 0.5, W)], 2, {1: 8})
    pipe_case("a pipe mined beside a pipe-to-ground",
              [("pipe-to-ground", -0.5, 0.5, E), ("pipe", 0.5, 0.5, N), ("pipe", 1.5, 0.5, N)], 1, {0: 0, 2: 0})
    pipe_case("a pump mined under the pipes on its output",
              [("pipe", 0.5, 0.5, N), ("pipe", 0.5, 1.5, N), ("pump", 0.5, 3.0, N)], 2, {1: 1})
    pipe_case("a storage tank mined beside the pipes on its connection",
              [("storage-tank", 1.5, 2.5, N), ("pipe", -0.5, 1.5, N), ("pipe", -1.5, 1.5, N)], 0, {1: 8})
    pipe_case("a pipe destroyed by damage (die)", [("pipe", dx + 0.5, 0.5, N) for dx in range(-1, 2)], 1, {0: 0, 2: 0},
              how="die")

    # The switch off: nothing sent for the neighbours (the bug as it was).
    rcon.run("/f3d-perf mined_neighbours off")
    units, recs, out = lay([("pipe", dx + 0.5, 0.5, N) for dx in range(-2, 3)])
    if units:
        got, gone = remove_and_watch(units[2], recs.get(units[2]), {units[1], units[3]})
        report(gone and not got, "pipe end: /f3d-perf mined_neighbours off sends nothing for the neighbours, as before",
               f"removed {gone}, sent {sorted(got)}")
    else:
        report(False, "pipe end: the switch's run laid", out)
    rcon.run("/f3d-perf mined_neighbours default")
    clear()

    # Belts: a curve straightened when the belt feeding its side goes; a side-loaded belt curving once the belt behind goes.
    for label, parts, target, watch, want in (
            ("a belt curve whose feeding belt is mined is sent straight",
             [("transport-belt", -0.5, 0.5, E), ("transport-belt", 0.5, 0.5, S)], 0, 1, "straight"),
            ("a side-loaded belt whose belt behind is mined is sent as the curve it becomes",
             [("transport-belt", dx + 0.5, 0.5, E) for dx in range(-1, 2)] + [("transport-belt", 0.5, -0.5, S)], 0, 1,
             "curve")):
        units, recs, out = lay(parts)
        if units is None:
            report(False, f"pipe end: {label}: laid", out)
            clear()
            continue
        before = extra(recs.get(units[watch]), "s")
        got, gone = remove_and_watch(units[target], recs.get(units[target]), {units[watch]})
        after = extra(got[units[watch]][0], "s") if units[watch] in got else None
        ok = (before in ("l", "r") and after == "s") if want == "straight" else (before == "s" and after in ("l", "r"))
        report(gone and ok and got[units[watch]][1] <= 0.6, f"pipe end: {label}",
               f"removed {gone}, s {before} -> {after}, {got.get(units[watch], (0, None))[1]} s after the del")
        clear()

    # Walls and heat pipes: the client joins them itself; the bridge sends no shape, and the `del` is what it needs.
    for name in ("stone-wall", "heat-pipe"):
        units, recs, out = lay([(name, dx + 0.5, 0.5, N) for dx in range(-1, 2)])
        if units is None:
            report(False, f"pipe end: {name}s laid", out)
            clear()
            continue
        extras = [(recs[u][5] if len(recs[u]) > 5 else {}) if u in recs else None for u in units]
        _, gone = remove_and_watch(units[1], recs.get(units[1]), set())
        report(gone and None not in extras and all(not ("pc" in e or "wc" in e) for e in extras),
               f"pipe end: a {name} mined from a row of three: its `del` comes, and the bridge sends no shape for them "
               "(the client joins them)", f"removed {gone}, extras {extras}")
        clear()

    # A construction robot deconstructing a pipe (on_robot_mined_entity) still has its neighbours sent.
    out = mod_lua(f"""local c = storage.f3d.puppet local s = c.surface
local e = s.create_entity({{ name = 'electric-energy-interface', position = {{ {x} - 6, {y} + 9 }}, force = c.force }})
e.power_production = 1e9 e.electric_buffer_size = 1e10
s.create_entity({{ name = 'medium-electric-pole', position = {{ {x} - 4.5, {y} + 9.5 }}, force = c.force }})
local r = s.create_entity({{ name = 'roboport', position = {{ {x} - 2, {y} + 9 }}, force = c.force }})
r.get_inventory(defines.inventory.roboport_robot).insert({{ name = 'construction-robot', count = 5 }})
s.create_entity({{ name = 'storage-chest', position = {{ {x} + 1.5, {y} + 9.5 }}, force = c.force }})
rcon.print('ok')""".replace("\n", " "))
    units, recs, _ = lay([("pipe", dx + 0.5, 0.5, N) for dx in range(-1, 2)])
    if units and out == "ok":
        c.pump(2.0, every=hello)  # the roboport charges its robots
        mod_lua(f"local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({{ area = {area}, name = 'pipe' }})) do "
                f"if e.unit_number == {units[1]} then e.order_deconstruction(c.force) end end rcon.print('ok')")
        got, gone = remove_and_watch(units[1], recs.get(units[1]), {units[0], units[2]}, how="robot")
        after = {u: extra(got[u][0], "pc") for u in got}
        report(gone and after == {units[0]: 0, units[2]: 0},
               "pipe end: a pipe a construction robot deconstructs: its neighbours sent again as lone pipes",
               f"removed {gone}, after {after}")
    else:
        report(False, "pipe end: a roboport, robots and pipes laid", out)
    clear()
    mod_lua(f"storage.f3d.puppet.teleport({{ {home[0]}, {home[1]} }})")


def check_map_info(c, hello):
    """The map and hover information (G12, G20): `hinfo` for a powered beacon with two speed modules
    and the assembler it reaches (LuaEntity.effects, get_module_inventory, get_beacons,
    get_beacon_effect_receivers, the beacon's distribution_effectivity), and `terr` naming its surface."""
    if not clean_spot(c, hello):
        report(False, "map info: no clean spot found", SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local x, y = {x}, {y}
local function put(name, dx, dy)
  return s.create_entity({{ name = name, position = {{ x + dx, y + dy }}, force = c.force, raise_built = true }})
end
local power = put("electric-energy-interface", -4, 0)
put("medium-electric-pole", -2.5, 2.5)
local asm = put("assembling-machine-2", 1.5, 0.5) asm.set_recipe("iron-gear-wheel")
local beacon = put("beacon", 1.5, 3.5)
beacon.get_module_inventory().insert({{ name = "speed-module", count = 2 }})
rcon.print(asm.unit_number .. " " .. asm.position.x .. " " .. asm.position.y .. " " .. beacon.unit_number .. " "
  .. beacon.position.x .. " " .. beacon.position.y .. " " .. power.unit_number)""")
    try:
        au, ax, ay, bu, bx, by, pu = (float(v) for v in out.split())
    except ValueError:
        report(False, "map info: the beacon and assembler were built", out)
        return
    c.pump(2.0, every=hello)  # powered up, the beacon's effect reaches the assembler
    fx = lambda v: int(round(v * 256))
    c.send({"t": "hinfo", "q": 11, "u": int(au), "p": 0, "x": fx(ax), "y": fx(ay)})
    c.send({"t": "hinfo", "q": 12, "u": int(bu), "p": 0, "x": fx(bx), "y": fx(by)})
    msgs = c.pump(1.5, every=hello)
    hi = {m["q"]: m for m in of_type(msgs, "hinfo")}
    ma, mb = hi.get(11, {}), hi.get(12, {})
    report(ma.get("b") == 1 and ma.get("eff", {}).get("sp", 0) > 0 and ma.get("eff", {}).get("co", 0) > 0,
           "hinfo: an assembler reached by a beacon: the beacon count and its effects (G12)", str(ma))
    report(mb.get("m") == [["speed-module", 2]] and mb.get("n") == 1 and mb.get("de") == 1500 and mb.get("eff", {}).get("sp", 0) > 0,
           "hinfo: the beacon's modules, the machines it reaches, its effectivity and what it hands on (G12)", str(mb))
    destroy_units([int(au), int(bu), int(pu)])
    mod_lua('package.loaded["__factorio-3d-bridge__/scripts/planets.lua"].territories_soon()')
    msgs = c.pump(1.5, every=hello)
    terr = of_type(msgs, "terr")
    si = mod_lua("rcon.print(storage.f3d.puppet.surface.index)")
    report(bool(terr) and str(terr[-1].get("si")) == si, "terr names the surface its territories are on (G20)",
           f"{terr[-1:] if terr else 'no terr'} on surface {si}")


def check_enemies(c, hello):
    """Enemies' attacks (`en`, scripts/enemies.lua) and the decals round nests. Biters next to a
    wall attack it or the character (their attack command's distraction in 2.1.23), a worm shoots
    (its shooting_target), and each is listed with its target's position. A spawner and a worm
    made with spawn_decorations place Factorio's enemy decals, which reach a client that asks for
    decoratives (`dec`) with the chunk's resend."""
    if not clean_spot(c, hello):
        report(False, "enemies: an empty spot", SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    on = (1.0, dict(hello[1], dc=1))
    c.send(on[1])
    early = c.pump(2.0, every=on)
    out = mod_lua(f"""
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
        report(False, "enemies: spawned a wall, biters, a worm and a spawner", out)
        return
    made, decals = nums[:-1], nums[-1]
    biters, worm, spawner = made[1:4], made[4], made[5]
    msgs = c.pump(4.0, every=on)
    rows = [m["l"][i:i + 3] for m in of_type(msgs, "en") for i in range(0, len(m["l"]), 3)]
    attacking = {r[0]: (r[1] / 256, r[2] / 256) for r in rows}
    wall_at, me_at = (x + 8.5, y + 0.5), (c.me["x"] / 256, c.me["y"] / 256)

    def near(p, q):
        return abs(p[0] - q[0]) < 1.5 and abs(p[1] - q[1]) < 1.5
    hit = [u for u in biters if u in attacking and (near(attacking[u], wall_at) or near(attacking[u], me_at))]
    report(len(hit) >= 2, "en: biters in range of their attack target are listed with its position (distraction_command)",
           f"{len(hit)} of 3; {len(of_type(msgs, 'en'))} en, rows {rows[-6:]}")
    report(worm in attacking, "en: a worm with a shooting_target is listed", f"{attacking.get(worm)}; {sorted(attacking)[:8]}")
    did = {rec[1]: rec[0] for m in of_type(early + msgs, "dprotos") for rec in m["l"]}
    sent = set()
    for m in of_type(msgs, "dec"):
        l = m["l"] if isinstance(m["l"], list) else []
        sent.update(l[0::4])
    want = {did.get("enemy-decal"), did.get("enemy-decal-transparent")} - {None}
    report(decals > 0 and bool(want & sent), "nest decals: spawn_decorations places enemy decals and dec sends them",
           f"{decals} enemy decals on the surface, decal ids {sorted(want)} in dec: {sorted(want & sent)}")
    mod_lua(f"local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({{ force = 'enemy', "
            f"area = {{ {{ {x} - 40, {y} - 40 }}, {{ {x} + 40, {y} + 40 }} }} }})) do e.destroy() end")
    destroy_units(made[:1])
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
    set_sight = lambda on: mod_lua("storage.f3d_perf = storage.f3d_perf or {} storage.f3d_perf.enemy_sight = "
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
                out = mod_lua("local c = storage.f3d.puppet if not (c and c.valid) then rcon.print('dead') return end "
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
                mod_lua("local c = storage.f3d.puppet if c and c.valid then c.health = c.max_health end")
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
    mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ type = 'turret', force = 'enemy', "
            f"position = {{ {nx}, {ny} }}, radius = 40 }})) do e.destroy() end")
    bonus = lambda n: mod_lua(f"storage.f3d.puppet.character_health_bonus = {n} local c = storage.f3d.puppet c.health = c.max_health")
    alive = lambda: mod_lua("local c = storage.f3d.puppet rcon.print(tostring(c and c.valid and c.health > 0) .. ' ' .. "
                            "(c and c.valid and math.floor(c.position.x) or 0))")
    groups = biters()
    print(f"INFO enemysight fix: {len(groups)} nest biters, in a unit group (parent_group) {sum(r.get('grp', 0) for r in groups)}, "
          f"spawner set {sum(r.get('sp', 0) for r in groups)}")
    set_sight(False)
    mod_lua(f"storage.f3d.puppet.teleport({{ {nx - 90}, {ny} }})")
    bonus(100000)
    c.pump(1.0, every=hello)
    off = approach("fix off")
    print(f"  after the approach, alive and x: {alive()}")
    print(f"INFO enemysight fix off: first attack (distance, nearest biter, attackers, biters, s) {off}")
    report(off is None and alive().startswith("true"), "enemysight: with /f3d-perf enemy_sight off the nest's biters don't attack the character "
           "walking up to 14 tiles (as before the fix)", str(off))
    # Out again, and a while for anything stirred up to settle.
    mod_lua(f"storage.f3d.puppet.teleport({{ {nx - 90}, {ny} }}) local c = storage.f3d.puppet c.health = c.max_health")
    c.pump(20.0, every=hello)
    set_sight(True)
    on = approach("fix on")
    print(f"  after the approach, alive and x: {alive()}")
    print(f"INFO enemysight fix on: first attack (distance, nearest biter, attackers, biters, s) {on}")
    report(on is not None and on[1] is not None and on[1] <= 31,
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
        report(woke[1] > 0 and woke[0] >= 0.8 * woke[1],
               "enemysight: the whole nest wakes together, as for a real player (at least 80% of its biters)", str(woke))
    # Standing still 45 s (the health bonus kept, as in the real player's measurement): held and dropping off
    # gradually, about half by 8-10 s, a few left at 40 s; not the 3-6 s fade without the fix.
    hold = heal_watch(45, "fix on, standing") if on else None
    if hold:
        n = hold[0]
        print(f"INFO enemysight fix on, standing: attackers at 2, 5, 10, 20, 30, 40 s: {[n[i - 1] for i in (2, 5, 10, 20, 30, 40)]} "
              "(real player: 14, 11-13, 6-7, 4-5, 3-4, 1-2)")
        report(n[1] >= 1 and n[9] < n[1] and n[19] >= 1 and n[44] <= n[9],
               "enemysight: standing, the attack is held and drops off gradually (on at 20 s, fewer at 10 s than at 2 s)", str(n))
    # Walking away west 150 tiles in one-tile steps (as the measurement moved both characters): no leash, the
    # attackers keep chasing while they keep up.
    chase = []
    if on:
        start = float(alive().split()[1])
        for i in range(150):
            mod_lua("local c = storage.f3d.puppet if c and c.valid then c.teleport({ c.position.x - 1, c.position.y }) "
                    "c.health = c.max_health end")
            c.pump(0.13, every=hello)
            if i % 10 == 9:
                smp = sample(nest_units)
                chase.append((round(nx - (start - i - 1)), len(set(attacking(smp, True)))))
        print(f"INFO enemysight fix on, walking away: (tiles from the nest, attackers) {chase} (real player: 8-13 to 400 tiles)")
        report(bool(chase) and chase[-1][1] >= 1,
               f"enemysight: chasing with no leash, still attacked {chase[-1][0] if chase else '?'} tiles from the nest", str(chase))
    bonus(0)
    mod_lua(f"storage.f3d.puppet.teleport({{ {nx - 90}, {ny} }}) local c = storage.f3d.puppet c.health = c.max_health")
    c.pump(1.0, every=hello)
    return {"off": off, "on": on, "woke": woke, "hold": hold, "chase": chase,
            "grouped": sum(r.get("grp", 0) for r in groups), "biters": len(groups)}


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
    if not clean_spot(c, hello):
        report(False, "enemysight: a clean spot", SPOT_WHY)
        return
    clear_enemies(radius=200)
    # The approach runs 60 tiles east: trees, rocks, cliffs and water there would stop the walk.
    spot = mod_lua("local c = storage.f3d.puppet local s = c.surface local p = c.position "
                   "local area = { { p.x - 20, p.y - 24 }, { p.x + 100, p.y + 24 } } "
                   "for _, e in pairs(s.find_entities_filtered({ area = area, type = { 'tree', 'simple-entity', 'cliff', 'fish' } })) do e.destroy() end "
                   "local tiles = {} for _, t in pairs(s.find_tiles_filtered({ area = area, collision_mask = 'water_tile' })) do "
                   "tiles[#tiles + 1] = { name = 'landfill', position = t.position } end "
                   "if #tiles > 0 then s.set_tiles(tiles) end rcon.print(p.x .. ' ' .. p.y)")
    sx, sy = (float(v) for v in spot.split())
    c.pump(0.5, every=hello)
    set_sight = lambda on: mod_lua("storage.f3d_perf = storage.f3d_perf or {} storage.f3d_perf.enemy_sight = "
                                   + ("nil" if on else "false"))
    set_sight(False)

    def lua(code):
        return mod_lua((ES_LUA + code).replace("\n", " "))

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
        clear_enemies(radius=200)
        mod_lua(f"storage.f3d.puppet.teleport({{ {sx}, {sy} }})")
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
        mod_lua('local c = storage.f3d.puppet '
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
            before = mod_lua(ammo)
            c.send({"t": "shoot", "m": 1, "x": int(target["x"] * 256), "y": int(target["y"] * 256)})
            c.pump(0.1)
            c.send({"t": "shoot", "m": -1})
            c.pump(0.5, every=hello)
            print(f"  shot at {target['u']}: {before} -> {mod_lua(ammo)}")
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
        worm_range = float(mod_lua("rcon.print(prototypes.entity['small-worm-turret'].attack_parameters.range)"))
        print(f"  small-worm-turret attack range {worm_range}")
        worm = setup("small-worm-turret", n=1)
        c.pump(5.0, every=hello)
        show("worm after 5 s", sample(worm))
        approach(worm, worm_range + 8)
        watch(worm, 3, "worm outside range")
        approach(worm, worm_range - 3)
        worm_hit = watch(worm, 8, "worm in range")

        clear_enemies(radius=200)
        mod_lua(f"storage.f3d.puppet.teleport({{ {sx}, {sy} }}) local c = storage.f3d.puppet "
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
        watch_around(c, hello, nx - 90, ny)
        # A fresh map's nests own one biter each and spawn more on their own over the first minutes (seen live: about
        # 7 a spawner after 10 game minutes). Pollution would spawn them faster but sends them off as an attack group
        # (parent_group set, spawner lost), which enemy_sight leaves to the engine on purpose: not the sleeping nest a
        # player walks up to. So the game runs fast until the nest owns enough idle biters of its own, no pollution.
        own = f"{{ {nx}, {ny} }}"
        t0 = time.time()
        count = ("local sp = {} for _, e in pairs(s.find_entities_filtered({ type = 'unit-spawner', force = 'enemy', position = " + own
                 + ", radius = 20 })) do sp[e.unit_number] = true end local u = {} for _, e in pairs(s.find_entities_filtered({ force = 'enemy', "
                 "type = 'unit', position = " + own + ", radius = 32 })) do local cm = e.commandable local k = cm and cm.spawner "
                 "if k and k.valid and sp[k.unit_number] and not cm.parent_group then u[#u + 1] = e.unit_number end end "
                 "rcon.print(table.concat(u, ' '))")
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
        nest_units += [int(u) for u in got if int(u) not in nest_units]
        print(f"  {len(got)} idle biters of the nest's own (spawner set, no group) after {time.time() - t0:.0f} s (game speed 10 meanwhile)")
        show("nest, the character 90 tiles off", sample(nest_units))
        c.pump(20.0, every=hello)
        show("nest, 20 s later", sample(nest_units))
        fix = fix_compare(c, hello, lua, sample, show, rows_of, attacking, nest_units, nx, ny)
        nest_first = ("fix", fix)
        if old_nest:
            # The diagnostic's own approach (the switch off), from 90 tiles again.
            set_sight(False)
            mod_lua(f"storage.f3d.puppet.teleport({{ {nx - 90}, {ny} }})")
            c.pump(20.0, every=hello)
            # 26 biters on the character: a big health bonus keeps it alive between the heals (it changes no targeting).
            mod_lua("storage.f3d.puppet.character_health_bonus = 100000")
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
                    mod_lua('local c = storage.f3d.puppet '
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
                    mod_lua("local c = storage.f3d.puppet c.get_inventory(defines.inventory.character_guns).clear() "
                            "c.get_inventory(defines.inventory.character_ammo).clear() storage.f3d.guns_sig = nil")
            mod_lua("storage.f3d.puppet.character_health_bonus = 0")
            mod_lua(f"storage.f3d.puppet.teleport({{ {sx}, {sy} }}) local c = storage.f3d.puppet c.health = c.max_health")
        c.pump(1.0, every=hello)
    print(f"INFO enemysight summary (first attack: seconds into the watch, tick, attackers, hp lost): walk to 20 -> {near20}; "
          f"walk to 8 -> {near8}; one shot -> {shot}; option B -> {opt_b}; option A -> {opt_a}; worm in range -> {worm_hit}; "
          f"the map's nest (distance, ...) -> {nest_first}")
    set_sight(True)
    report(True, "enemysight: the diagnostic ran (its numbers are in the INFO lines)")


def lua_command(text):
    """The client's Lua command over RCON (console_commands.gd lua_command): game.player becomes the
    player the bridge plays, or a stand-in for its character; the prelude is the client's own."""
    prelude = " ".join(l.strip() for l in (pathlib.Path(__file__).resolve().parent.parent / "client" / "data"
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
    report(out.startswith("character "), "console: /c game.player.print answers over RCON with the bridge's character", out)
    out = rcon.run(lua_command("/c game.print(#game.players >= 0 and 'players ok')")).strip()
    report(out == "players ok", "console: game.print answers too, and game.players is untouched", out)
    out = rcon.run(lua_command("/sc game.player.no_such_field = game.player.nothing_here.x")).strip()
    report(out.startswith("Error: ") and "game.player" in out, "console: an error comes back as the answer", out)
    out = rcon.run(lua_command("/c __factorio-3d-bridge__ game.player.print(storage.f3d.puppet == game.player.character and 'mod state')")).strip()
    report(out == "mod state", "console: /c __mod__ keeps the mod's state", out)
    who = rcon.run("/sc rcon.print(remote.call('zenith', 'player') and 'player' or 'none')").strip()
    print(f"     (the bridge plays {'a LuaPlayer' if who == 'player' else 'its own character, no LuaPlayer'})")

    def ask(text, cid):
        c.send({"t": "cmd", "id": cid, "text": text})
        msgs = c.pump(3.0, every=hello, until=lambda m: m.get("t") == "cmdr" and m.get("id") == cid)
        got = [m for m in of_type(msgs, "cmdr") if m.get("id") == cid]
        return got[-1] if got else {}
    for name, cid in (("version", 901), ("seed", 902)):
        r, want = ask("/" + name, cid), rcon.run("/" + name).strip()
        report(r.get("l") == [want], f"cmd /{name}: the bridge answers as Factorio's console does", f"{r.get('l')} vs {want!r}")
    r, want = ask("/evolution", 903), rcon.run("/evolution").strip()
    report(r.get("l") and r["l"][0].split(" - ")[0] == want.split(" - ")[0] and "Evolution factor: " in r["l"][0],
           "cmd /evolution: Factorio's line", f"{r.get('l')} vs {want!r}")
    r = ask("/time", 904)
    report(r.get("l") and ("second" in r["l"][0] or "minute" in r["l"][0] or "hour" in r["l"][0]), "cmd /time", str(r.get("l")))
    r = ask("/players", 905)
    report(r.get("l") and r["l"][0].startswith("Players ("), "cmd /players", str(r.get("l")))
    r = ask("/f3d-status", 906)
    report(r.get("l") and any("client on port" in l for l in r["l"]), "cmd /f3d-status: the mod's command answers the client", str(r.get("l"))[:200])
    r = ask("/editor", 907)
    report(r.get("ok") == 0, "cmd: a command the bridge doesn't run answers ok = 0", str(r))
    # The debug menu's /f3d-debug: each change read back from the game over RCON, then put back.
    r = ask("/f3d-debug", 908)
    before = r.get("dbg", {})
    report(before.get("s") and "sp" in before, "cmd /f3d-debug: the game's state as dbg", str(r))
    ask("/f3d-debug daytime 0.5", 909)
    ask("/f3d-debug freeze on", 910)
    got = rcon.run("/sc local c = remote.call('zenith', 'character') rcon.print(string.format('%.3f %s', c.surface.daytime, tostring(c.surface.freeze_daytime)))").strip()
    report(got == "0.500 true", "cmd /f3d-debug daytime and freeze set the character's surface", got)
    ask("/f3d-debug speed 2", 911)
    got = rcon.run("/sc rcon.print(game.speed)").strip()
    report(got == "2", "cmd /f3d-debug speed sets game.speed", got)
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
    early = [m for m in of_type(paused, "cmdr") if m.get("id") == 913]
    rcon.run("/sc game.tick_paused = false")
    msgs = c.pump(0.5 if early else 5.0, every=hello, until=lambda m: m.get("t") == "cmdr" and m.get("id") == 913)
    late = [m for m in of_type(msgs, "cmdr") if m.get("id") == 913]
    answers = early + late
    report(ticks[0].startswith("true ") and ticks[0] == ticks[1] and answers and answers[-1].get("dbg", {}).get("pa") == 1,
           "cmd /f3d-debug pause: the game tick-pauses (the tick stands still over RCON), and the bridge's answer says so "
           "(pa 1), by the time RCON has resumed it",
           f"RCON {ticks}; answered {len(early)} times while paused, {len(late)} after: {str(answers[-1:])[:200]}")
    ask("/f3d-debug pause off", 915)
    r = ask("/f3d-debug", 914)
    report(r.get("dbg", {}).get("pa") == 0, "cmd /f3d-debug pause: after RCON's resume the bridge answers again, not paused", str(r)[:200])
    ask("/f3d-debug freeze %s" % ("on" if before.get("fz") == 1 else "off"), 916)
    ask("/f3d-debug daytime %s" % before.get("dt", 0.2), 917)
    if not cheat:
        return
    r = ask("/cheat", 908)
    done = rcon.run("/sc rcon.print(game.forces.player.technologies['automation'].researched)").strip()
    report(r.get("l", [""])[0] == "Researched every technology" and done == "true", "cmd /cheat researches everything", f"{r.get('l')}, automation {done}")
    if "vulcanus" in rcon.run("/sc for n in pairs(game.planets) do rcon.print(n) end"):
        r = ask("/cheat vulcanus", 909)
        where = mod_lua("rcon.print(storage.f3d.puppet.surface.name)")
        report(r.get("l") == ["Moved to vulcanus"] and where == "vulcanus", "cmd /cheat vulcanus moves the character there", f"{r.get('l')}, on {where}")
        r = ask("/cheat nauvis", 910)
        where = mod_lua("rcon.print(storage.f3d.puppet.surface.name)")
        report(where == "nauvis", "and /cheat nauvis back", f"{r.get('l')}, on {where}")


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
    path = pathlib.Path(SERVER_LOG) if SERVER_LOG else (
        pathlib.Path(__file__).resolve().parent.parent / "server" / "data" / "factorio-current.log")
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return None
    return text if SERVER_LOG or f"127.0.0.1:{FACTORIO_PORT}" in text else None


def check_barrier(c, hello):
    """The error barrier (barrier.lua): a tick step and an event handler made to fail. The game goes
    on, the other steps keep sending, the failing one is retried each tick, /f3d-status names it,
    the client is told, Factorio's log has it (at most once every 600 ticks), and a step that works
    again stops counting. The failures are forgotten afterwards, so the run's last check still sees
    only real ones."""
    before = step_errors()
    if "research" in before or "on_research_finished" in before:
        report(False, "barrier: research hadn't failed before the check", str(before)[:300])
        return
    if not clean_spot(c, hello):
        report(False, "barrier: an empty spot", SPOT_WHY)
        return
    c.pump(0.5, every=hello)
    # A tick step: research's job in a shape it can't read (as a save of another bridge might hold).
    tick0 = int(rcon.run("/sc rcon.print(game.tick)").strip())
    mod_lua("storage.f3d.techs_job = { names = false, block = 1, blocks = 2, sent = 0 } rcon.print('ok')")
    msgs = c.pump(1.2, every=(0.15, {"t": "walk", "d": 4}))
    c.send({"t": "walk", "d": -1})
    msgs += c.pump(2.0, every=hello)
    tick1 = int(rcon.run("/sc rcon.print(game.tick)").strip())
    errors = step_errors()
    n1, line = errors.get("research", (0, ""))
    report(n1 > 0 and "names" in line, "barrier: /f3d-status names the failing step and its error", line[:300])
    # (A tick the work budget has no room for techs returns before reading the job.)
    span = re.search(r"first at tick (\d+), last at tick (\d+)", line)
    span = int(span.group(2)) - int(span.group(1)) if span else 0
    report(tick1 - tick0 >= 150 and n1 >= 30 and span >= (tick1 - tick0) * 0.7,
           "barrier: the game goes on, and the failing step is tried again tick after tick",
           f"{tick1 - tick0} ticks, failed {n1} times over {span}")
    mes = of_type(msgs, "me")
    moved = math.hypot(mes[-1]["x"] - mes[0]["x"], mes[-1]["y"] - mes[0]["y"]) / 256 if mes else 0
    report(len(of_type(msgs, "sky")) >= 2 and moved > 2, "barrier: the other steps keep running (sky sent, the character walked)",
           f"{len(of_type(msgs, 'sky'))} sky, walked {moved:.1f} tiles")
    told = [m["text"] for m in of_type(msgs, "msg") if m.get("text", "").startswith("Bridge error in research")]
    report(len(told) == 1, "barrier: the client is told once, not every tick", str(told)[:200])
    log = server_log()
    if log is None:
        print("SKIP barrier: the server's log isn't on this machine (--server-log)")
    else:
        lines = [l for l in log.splitlines() if "[Zenith] ERROR in step 'research' at tick" in l
                 and tick0 <= int(re.search(r"at tick (\d+)", l).group(1)) <= tick1 + 60]
        report(1 <= len(lines) <= 1 + (tick1 - tick0) // 600 and "names" in (lines[0] if lines else ""),
               "barrier: Factorio's log has the step and its error, at most once every 600 ticks",
               f"{len(lines)} lines in {tick1 - tick0} ticks: {(lines[0] if lines else '')[:200]}")
    # Working again: the tree is sent and the count stops.
    mod_lua("storage.f3d.techs_job = nil storage.f3d.techs_dirty = true rcon.print('ok')")
    msgs = c.pump(2.0, every=hello)
    n2 = step_errors().get("research", (0, ""))[0]
    c.pump(1.0, every=hello)
    n3 = step_errors().get("research", (0, ""))[0]
    report(of_type(msgs, "techs") and n3 == n2, "barrier: once the step can run again it sends (techs) and stops failing",
           f"{len(of_type(msgs, 'techs'))} techs parts, failed {n2} then {n3} times")

    # An event handler: on_research_finished's (research.lua) calls crafting.invalidate, replaced
    # for the length of one command by one that fails. Without the barrier the error would come out
    # of `researched = true`. An infinite technology (its level under its max_level) never reads
    # researched, so the change wouldn't stand: one that can is picked.
    out = mod_lua("""
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
    report(out.startswith("true true") and n == 1 and "a handler failing" in line,
           "barrier: an event handler failing is caught, logged and listed; the game's own change stands", f"{out} | {line[:200]}")
    msgs = c.pump(1.0, every=hello)
    report(of_type(msgs, "sky") or of_type(msgs, "me"), "barrier: the bridge keeps sending after the handler failed",
           f"{len(msgs)} messages")
    mod_lua("local b = package.loaded['__factorio-3d-bridge__/scripts/barrier.lua'] "
            "b.forget('research') b.forget('on_research_finished') rcon.print('ok')")
    left = step_errors()
    report(left.keys() == before.keys(), "barrier: the check's failures are forgotten, the rest kept", str(list(left))[:200])


PIPE_STEPS = [(0, -1), (1, 0), (0, 1), (-1, 0)]
GODOT = None  # --godot


def client_pipelines(records, eprops, types):
    """N9: client/scripts/player/pipeline_marks.gd's rule in Python, on the bridge's own records: a pipe joins across its
    `pc` sides (a pipe whose `pc` has the side back, a pipe to ground facing it, a tank whose connection leads onto it);
    a pipe to ground also its open side and its underground partner (the first piece of its kind along its back within
    `under` tiles facing either way, a partner when it faces back); a tank its `eprops` fluid boxes. Anything else ends a
    pipeline. Returns {unit: pipeline number}."""
    by_unit = {r[0]: r for r in records if r[0]}
    pipes, tanks = {}, {}
    for r in by_unit.values():
        t = types.get(r[1], "")
        tx, ty = math.floor(r[2] / 256), math.floor(r[3] / 256)
        if t in ("pipe", "infinity-pipe", "pipe-to-ground"):
            pipes[(tx, ty)] = r
        elif t == "storage-tank":
            cx, cy = r[2] / 256, r[3] / 256
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    tanks[(math.floor(cx + dx), math.floor(cy + dy))] = r

    def extra(r):
        return r[5] if len(r) > 5 and isinstance(r[5], dict) else {}

    def turn(v, d):
        # 16-way direction d clockwise, as CursorOverlay.turn (quarter turns only here)
        x, y = v
        for _ in range((d // 4) % 4):
            x, y = -y, x
        return x, y

    def ports(t):
        x = ((eprops.get(t[1]) or [None] * 4)[3:] or [{}])[0] or {}
        out = []
        for c in x.get("fb") or x.get("fj") or []:
            ox, oy = turn((c[0], c[1]), t[4])
            wx, wy = turn(PIPE_STEPS[(c[2] // 4) % 4], t[4])
            own = (math.floor(t[2] / 256 + ox), math.floor(t[3] / 256 + oy))
            out.append((own, (own[0] + wx, own[1] + wy)))
        return out

    def at(tile):
        return pipes.get(tile) or tanks.get(tile)

    def side(r, tile, i, out):
        nx, ny = tile[0] + PIPE_STEPS[i][0], tile[1] + PIPE_STEPS[i][1]
        back = (i + 2) % 4
        o = at((nx, ny))
        if o is None:
            return
        t = types.get(o[1], "")
        if t in ("pipe", "infinity-pipe") and int(extra(o).get("pc", 0)) & (1 << back):
            out.append(o)
        elif t == "pipe-to-ground" and o[4] == back * 4:
            out.append(o)
        elif t == "storage-tank" and any(port[1] == tile for port in ports(o)):
            out.append(o)

    def partner(r):
        reach = int((eprops.get(r[1]) or [10])[0] or 10)
        tx, ty = math.floor(r[2] / 256), math.floor(r[3] / 256)
        sx, sy = PIPE_STEPS[(r[4] // 4) % 4]
        back = (r[4] + 8) % 16
        for k in range(1, reach + 1):
            o = pipes.get((tx - sx * k, ty - sy * k))
            if o is not None and o[1] == r[1] and o[4] in (r[4], back):
                return o if o[4] == back else None
        return None

    def neighbours(r):
        t = types.get(r[1], "")
        tile = (math.floor(r[2] / 256), math.floor(r[3] / 256))
        out = []
        if t in ("pipe", "infinity-pipe"):
            for i in range(4):
                if int(extra(r).get("pc", 0)) & (1 << i):
                    side(r, tile, i, out)
        elif t == "pipe-to-ground":
            opened = (r[4] // 4) % 4
            if "pc" not in extra(r) or int(extra(r)["pc"]) & (1 << opened):
                side(r, tile, opened, out)
            o = partner(r)
            if o is not None:
                out.append(o)
        elif t == "storage-tank":
            for own, nxt in ports(r):
                o = at(nxt)
                if o is None or o is r:
                    continue
                ot = types.get(o[1], "")
                step = (nxt[0] - own[0], nxt[1] - own[1])
                back = PIPE_STEPS.index((-step[0], -step[1]))
                if ot in ("pipe", "infinity-pipe") and int(extra(o).get("pc", 0)) & (1 << back):
                    out.append(o)
                elif ot == "pipe-to-ground" and o[4] == back * 4:
                    out.append(o)
                elif ot == "storage-tank" and any(b == (nxt, own) for b in ports(o)):
                    out.append(o)
        return out

    group, n = {}, 0
    for u, r in by_unit.items():
        if u in group or types.get(r[1], "") not in ("pipe", "infinity-pipe", "pipe-to-ground", "storage-tank"):
            continue
        n += 1
        todo = [r]
        group[u] = n
        while todo:
            for o in neighbours(todo.pop()):
                if o[0] not in group:
                    group[o[0]] = n
                    todo.append(o)
    return group


def client_own_pipelines(records, c):
    """N9: client/tests/pipeline_predict.tscn (the client's pipeline_marks.gd, headless, muted) on these records:
    {unit: pipeline number}, or None without Godot."""
    import shutil
    import subprocess
    import tempfile
    godot = GODOT or os.environ.get("GODOT") or shutil.which("godot") or shutil.which("godot4")
    if not godot:
        return None
    client = pathlib.Path(__file__).resolve().parent.parent / "client"
    with tempfile.TemporaryDirectory() as tmp:
        src, dst = pathlib.Path(tmp) / "in.json", pathlib.Path(tmp) / "out.json"
        eprops = [[k] + list(v) for k, v in (c.eprops or {}).items()]
        src.write_text(json.dumps({"protos": list(c.proto_recs.values()), "eprops": eprops, "records": records}), encoding="utf-8")
        subprocess.run([godot, "--headless", "--audio-driver", "Dummy", "--path", str(client),
                        "--log-file", str(pathlib.Path(tmp) / "godot.log"), "res://tests/pipeline_predict.tscn",
                        "--", f"--in={src}", f"--out={dst}"], capture_output=True, timeout=300)
        if not dst.exists():
            return {}
        return {int(u): n for u, n in json.loads(dst.read_text(encoding="utf-8"))["groups"].items()}


def check_pipe_vis(c, hello):
    """N9: the client's pipeline visualization (pipeline_marks.gd) finds a fluid pipeline from the bridge's records alone.
    A lab layout (pipes, an underground pair, a storage tank, a pump, a boiler with pipes at both its water connections,
    and a pipe beside the line, which the game joins to it: pipes connect on every side) is built, its chunks' records
    read, and the client's rule is compared with the game's own LuaFluidBox.get_fluid_segment_id for every pipe, pipe to
    ground and tank: the rule in Python (client_pipelines), and the client's own pipeline_marks.gd run on the same
    records (tests/pipeline_predict.tscn, when Godot is found: --godot, $GODOT or godot on PATH). A pipe without a
    segment id (nil, or an error reading it) fails. Printed: whether the boiler's pass-through joins its two pipes into
    one segment (the client stops at machines)."""
    clear_enemies()
    if not clean_spot(c, hello):
        report(False, "pipevis: an empty spot", SPOT_WHY)
        return
    x, y = math.floor(c.me["x"] / 256), math.floor(c.me["y"] / 256)
    # Row y+2: pipes x..x+2, a pipe to ground (open west) x+3, its partner (open east) x+8, a pipe x+9, a storage tank
    # x+10..x+12 by y+2..y+4 (its west connection at x+10, y+2), a pump x+13..x+14 on row y+4 off its east connection and
    # a pipe x+15 past the pump; a pipe at x+1, y+1 above the line (joined by the game: pipes join every side).
    # Row y+9: a boiler x+2..x+4 by y+8..y+9 facing north, a pipe at each end of its water box (x+1 and x+5, y+9).
    # (A segment id the game doesn't give is written "nil", an error reading it "x": both fail below.)
    out = mod_lua(f"""local c = storage.f3d.puppet local s = c.surface local d = defines.direction
local made = {{}}
local function put(name, px, py, dir, extra)
  local spec = {{ name = name, position = {{ {x} + px, {y} + py }}, direction = dir or d.north, force = c.force, raise_built = true }}
  if extra then for k, v in pairs(extra) do spec[k] = v end end
  local e = s.create_entity(spec)
  if e then made[#made + 1] = e end
  return e
end
for i = 0, 2 do put('pipe', i + 0.5, 2.5) end
put('pipe-to-ground', 3.5, 2.5, d.west)
put('pipe-to-ground', 8.5, 2.5, d.east)
put('pipe', 9.5, 2.5)
put('storage-tank', 11.5, 3.5)
put('pump', 14, 4.5, d.east)
put('pipe', 15.5, 4.5)
put('pipe', 1.5, 1.5)
put('boiler', 3.5, 9, d.north)
put('pipe', 1.5, 9.5)
put('pipe', 5.5, 9.5)
storage.f3d_n9 = made
local r = {{}}
for _, e in ipairs(made) do
  local ok, id = pcall(function() return e.get_fluid_segment_id(1) end)
  r[#r + 1] = e.unit_number .. ':' .. e.name .. ':' .. tostring(ok and id or 'x')
end
rcon.print(table.concat(r, ' '))""".replace("\n", " "))
    game = {}
    names = {}
    try:
        for part in out.split():
            u, name, seg = part.split(":")
            game[int(u)] = seg
            names[int(u)] = name
    except ValueError:
        report(False, "pipevis: the layout built, the game's segment ids read", out)
        return
    report(len(game) == 13, "pipevis: the layout built (13 entities) and the game's segment ids read", out)
    # The chunks round the spot again, each a snapshot with the records' `pc`.
    cx, cy = x // 32, y // 32
    wanted = [[cx + dx, cy + dy] for dy in range(-1, 2) for dx in range(-1, 2)]
    c.send({"t": "sub", "c": []})
    c.send({"t": "sub", "c": wanted})
    pending = {tuple(w) for w in wanted}
    records = {}
    end = time.time() + 20
    while pending and time.time() < end:
        for m in c.pump(0.5, every=hello):
            if m.get("t") == "ents":
                for e in m["e"]:
                    if e[0]:
                        records[e[0]] = e
                if m["part"] == m["parts"]:
                    pending.discard((m["cx"], m["cy"]))
            elif m.get("t") in ("add", "upd") and m["e"][0]:
                records[m["e"][0]] = m["e"]
    types = {i: t for i, (_, t) in c.protos.items()}
    group = client_pipelines(list(records.values()), c.eprops or {}, types)
    fluid = [u for u in game if types.get(records.get(u, [0, 0])[1], "") in ("pipe", "pipe-to-ground", "storage-tank")]
    report(not pending and all(u in records for u in game), "pipevis: every entity's record came with its chunk",
           f"pending {sorted(pending)}, missing {[names[u] for u in game if u not in records]}")
    no_id = [f"{names[u]} {u}: {game[u]}" for u in fluid if game[u] in ("nil", "x")]
    report(not no_id, "pipevis: the game gives every pipe, pipe to ground and tank a fluid segment id", "; ".join(no_id))

    def same_game(a, b):
        return game[a] == game[b] and game[a] not in ("nil", "x")

    def compare(groups, what):
        wrong = []
        for a in fluid:
            for b in fluid:
                if a < b and same_game(a, b) != (groups.get(a) is not None and groups.get(a) == groups.get(b)):
                    wrong.append(f"{names[a]} {a} / {names[b]} {b}: game {'same' if same_game(a, b) else 'apart'}")
        report(not wrong, f"pipevis: {what} groups every pipe, pipe to ground and tank as the game's fluid segments",
               "; ".join(wrong[:6]))
    compare(group, "the client's rule (in Python)")
    own = client_own_pipelines(list(records.values()), c)
    if own is None:
        print("  INFO N9: Godot not found (--godot, $GODOT, godot on PATH): the client's own pipeline_marks.gd not run")
    else:
        compare(own, "the client's own pipeline_marks.gd")
    boiler_pipes = [u for u in game if names[u] == "pipe"][-2:]
    if len(boiler_pipes) == 2:
        a, b = boiler_pipes
        print(f"  INFO N9: the boiler's two pipes {'share' if game[a] == game[b] else 'are apart in'} a fluid segment "
              f"(game ids {game[a]} and {game[b]}); the client {'joins' if group.get(a) == group.get(b) else 'stops at'} the boiler")
    print("  INFO N9: game segment ids:", ", ".join(f"{names[u]} {u}={game[u]}" for u in game))
    mod_lua("for _, e in ipairs(storage.f3d_n9 or {}) do if e.valid then e.destroy() end end storage.f3d_n9 = nil")


def check_join(c, hello):
    """L13: a world Zenith made (a fresh map, nobody created in it yet) played by the bridge's own character.
    Freeplay is told not to make its crash site (takeover.lua no_crash_site) through the remote interface 2.1's
    freeplay.lua has; the hello's `pn` (the client PC's Factorio account) is kept with the client and claims nobody
    while no player has that name. The join itself (a player of that name taking the character over, handing it
    back on leaving) needs a real Factorio joined as a player, which a headless run can't make."""
    facts = json.loads(mod_lua(
        "local fp = remote.interfaces.freeplay local fns = {} if fp then for k in pairs(fp) do fns[#fns + 1] = k end end "
        "table.sort(fns) local n = 0 for _ in pairs(game.players) do n = n + 1 end local s = storage.f3d "
        "rcon.print(helpers.table_to_json({ fns = fns, players = n, mp = game.is_multiplayer(), "
        "own = s.own_character ~= nil and s.own_character.valid and s.own_character == s.puppet }))"))
    print("  INFO freeplay's remote interface:", ", ".join(facts["fns"]) or "none", f"| players {facts['players']}")
    need = {"get_init_ran", "get_disable_crashsite", "set_disable_crashsite", "get_created_items"}
    report(need <= set(facts["fns"]), "join: freeplay's remote interface has what the bridge calls", sorted(need - set(facts["fns"])))
    if not need <= set(facts["fns"]):
        return
    state = json.loads(mod_lua(
        "rcon.print(helpers.table_to_json({ ran = remote.call('freeplay', 'get_init_ran') == true, "
        "off = remote.call('freeplay', 'get_disable_crashsite') == true, kit = remote.call('freeplay', 'get_created_items') }))"))
    print("  INFO freeplay: init_ran", state["ran"], "| crash site disabled", state["off"], "| created items", state["kit"])
    if facts["players"] == 0:
        report(facts["mp"] and facts["own"] and not state["ran"] and state["off"],
               "join: on a server map nobody joined yet, the bridge plays its own character and freeplay's crash site is off",
               f"{facts}, {state}")
    else:
        report(True, "join: this map has players (freeplay's intro ran already): nothing to turn off", f"{facts['players']} players")
    report(isinstance(state["kit"], dict) and state["kit"].get("iron-plate") == 8,
           "join: freeplay's created items are names to counts (what a claimed new player's character is emptied of)", state["kit"])
    named = dict(hello[1], pn="zenith-live-nobody")
    c.pump(2.0, every=(1.0, named))
    st = json.loads(mod_lua("local s = storage.f3d rcon.print(helpers.table_to_json({ pn = s.client and s.client.pn or '', "
                            "owner = s.owner_index or 0, z = s.zenith_owner or 0, "
                            "own = s.own_character ~= nil and s.own_character.valid and s.own_character == s.puppet }))"))
    report(st["pn"] == "zenith-live-nobody" and st["owner"] == 0 and st["z"] == 0 and st["own"] == facts["own"],
           "join: a hello's pn is kept with the client; with no player of that name nobody is claimed", st)
    c.pump(1.5, every=hello)
    st = json.loads(mod_lua("local s = storage.f3d rcon.print(helpers.table_to_json({ pn = s.client and s.client.pn or '' }))"))
    report(st["pn"] == "", "join: a hello without pn forgets it", st)
    switches = rcon.run("/f3d-perf")
    report("zenith_join on" in switches and "no_crash_site on" in switches, "join: /f3d-perf lists the two switches, on",
           switches.strip()[-200:])


def steps_parts(msgs):
    """The `steps` parts of one handshake, by part number, and their count as the parts say it."""
    parts = {m["part"]: m for m in of_type(msgs, "steps")}
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
    report(total is not None and sorted(parts) == list(range(1, total + 1)),
           "steps: every part of the list in the handshake", f"{sorted(parts)} of {total}")
    if not parts or total is None:
        return
    report("eprops" in kinds and kinds.index("steps") > kinds.index("eprops"), "steps: after eprops")
    report(c.max_size.get("steps", 0) <= 4096, "steps: each datagram within f3d-bytes-per-tick's floor (4096)",
           f"largest {c.max_size.get('steps')} bytes, {total} parts")
    sounds, lists, u = [], {"tl": [], "el": [], "dl": [], "al": []}, None
    for n in range(1, total + 1):
        sounds += parts[n].get("s", [])
        for k in lists:
            lists[k] += parts[n].get(k, [])
        u = parts[n].get("u", u)
    report(all(0 <= rec[1] <= len(sounds) for k in ("tl", "el", "dl") for rec in lists[k]) and u is not None
           and all(0 <= v <= len(sounds) for v in u), "steps: every name points at a listed sound (0: none)", f"{len(sounds)} sounds, u {u}")
    # The data stage's list, read back over RCON: the same tiles, rails and resources, decoratives.
    facts = json.loads(mod_lua(
        "local d = prototypes.mod_data['zenith-step-sounds'] local out = { has = d ~= nil } "
        "if d then local function n(t) local c = 0 for _ in pairs(t or {}) do c = c + 1 end return c end "
        "out.s = #d.get('s') out.tile = n(d.get('tile')) out.entity = n(d.get('entity')) out.decorative = n(d.get('decorative')) end "
        "local blocked = {} for name, p in pairs(prototypes.tile) do "
        "if p.collision_mask.layers.player then blocked[#blocked + 1] = name end end out.blocked = blocked "
        "out.tiles = 0 for _ in pairs(prototypes.tile) do out.tiles = out.tiles + 1 end "
        "rcon.print(helpers.table_to_json(out))"))
    report(facts["has"] and facts["s"] == len(sounds) and facts["tile"] == len(lists["tl"]) == facts["tiles"]
           and facts["entity"] == len(lists["el"]) and facts["decorative"] == len(lists["dl"]),
           "steps: the message carries the data stage's whole list (every tile, rails and resources, decoratives)",
           f"sounds {len(sounds)}/{facts.get('s')}, tiles {len(lists['tl'])}/{facts.get('tile')}/{facts['tiles']}, "
           f"entities {len(lists['el'])}/{facts.get('entity')}, decoratives {len(lists['dl'])}/{facts.get('decorative')}")
    names = {i: n for n, i in c.tiles.items()}
    silent = sorted(names.get(rec[0], f"#{rec[0]}") for rec in lists["tl"] if rec[1] == 0)
    walk_silent = [n for n in silent if n not in set(facts["blocked"]) and n != "tile-unknown"]
    print(f"  INFO steps: {len(sounds)} sounds in {total} parts; silent tiles: {', '.join(silent)}")
    report(not walk_silent, "steps: no tile the player can walk on is silent", walk_silent)
    data = factorio_install.find()
    data = os.path.join(data, "data") if data and os.path.isdir(os.path.join(data, "data")) else None
    if data:
        missing = []
        for key, _vol, count in sounds:
            files = key if isinstance(key, list) else (
                [f"{key}-{i}.ogg" for i in range(1, count + 1)] if not (count == 1 and os.path.exists(os.path.join(data, key + ".ogg")))
                else [key + ".ogg"])
            missing += [f for f in files if not os.path.exists(os.path.join(data, f))]
        report(not missing, "steps: every listed sound's files are in the install (read there, never copied)", missing[:5])
    # A full resync and a reconnect: the list again, whole.
    c.send({"t": "resync", "full": 1})
    again = c.pump(4.0)
    p2, t2 = steps_parts(again)
    report(t2 == total and sorted(p2) == list(range(1, total + 1)), "steps: sent again whole on a full resync", f"{sorted(p2)} of {t2}")
    c.sid = c.sid + "-again"
    again = handshake_msgs(c)
    p3, t3 = steps_parts(again)
    report(t3 == total and sorted(p3) == list(range(1, total + 1)) and p3[1].get("s") == parts[1].get("s"),
           "steps: sent again whole on a reconnect (a new sid), the same list", f"{sorted(p3)} of {t3}")
    c.pump(1.0, every=(1.0, {"t": "hello", "v": 1, "sid": c.sid, "w": 1}))


def handshake(c):
    msgs = c.pump(6, until=lambda m: m.get("t") == "ready", every=(1.0, {"t": "hello", "v": 1, "sid": c.sid, "w": 0}))
    welcome = of_type(msgs, "welcome")
    report(bool(welcome) and bool(of_type(msgs, "ready")), "handshake: welcome, prototypes, ready")
    return welcome


def check_as_player(c, hello):
    """Acting as the player (as_player.lua): with a player connected whose character the bridge plays,
    the bridge's building, rotating, opening, pasting and mining raise Factorio's own player events,
    seen by tools/mod_tests/fixtures/zenith-event-probe (a mod that counts events, which must be in the
    server's mods); with the map setting off, building raises only script_raised_built. Needs a real
    Factorio client joined as the player the bridge plays."""
    who = mod_lua("local c = storage.f3d.puppet local p = c and c.player "
                  "rcon.print(p and p.connected and (p.index .. ' ' .. p.name) or 'none') ")
    has_probe = rcon.run("/c rcon.print(remote.interfaces.probe and 'yes' or 'no')").strip() == "yes"
    if who == "none" or not has_probe:
        report(False, "as player: needs a connected player playing the bridge's character and the zenith-event-probe mod",
               f"player {who}, probe {has_probe}")
        return
    index = int(who.split()[0])
    if not clean_spot(c, hello):
        report(False, "as player: an empty spot", SPOT_WHY)
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
        return int(mod_lua(f"local e = storage.f3d.puppet.surface.find_entity('{name}', {{ {px}, {py} }}) "
                           "rcon.print(e and e.unit_number or 0)") or 0)

    def ident(name, px, py):
        return {"u": unit_at(name, px, py), "p": c.proto_id(name), "x": int(px * 256), "y": int(py * 256)}

    mod_lua("storage.f3d.puppet.insert({ name = 'transport-belt', count = 10 }) "
            "storage.f3d.puppet.insert({ name = 'assembling-machine-1', count = 2 })")
    rcon.run("/c remote.call('probe', 'reset')")
    c.send({"t": "build", "item": "transport-belt", "x": int(bx * 256), "y": int(by * 256), "d": 4})
    c.pump(1.0, every=hello)
    report(unit_at("transport-belt", bx, by) and heard("on_built_entity") and heard("on_pre_build"),
           "as player: building raises on_pre_build and on_built_entity for the player", json.dumps(probe()["c"]))
    left = mod_lua("local p = storage.f3d.puppet.player rcon.print(p.cursor_stack.valid_for_read and p.cursor_stack.name or 'empty')")
    report(left == "empty", "as player: the cursor is given back empty", left)

    c.send({"t": "rotate", **ident("transport-belt", bx, by)})
    c.pump(0.6, every=hello)
    report(heard("on_player_rotated_entity"), "as player: rotating raises on_player_rotated_entity")

    ax, ay = bx + 3.0, by + 3.0
    c.send({"t": "build", "item": "assembling-machine-1", "x": int(ax * 256), "y": int(ay * 256), "d": 0})
    c.send({"t": "build", "item": "assembling-machine-1", "x": int((ax + 4) * 256), "y": int(ay * 256), "d": 0})
    c.pump(1.0, every=hello)
    a, b = ident("assembling-machine-1", ax, ay), ident("assembling-machine-1", ax + 4, ay)
    c.send({"t": "open", **a})
    c.pump(0.6, every=hello)
    opened = mod_lua("local p = storage.f3d.puppet.player rcon.print(p.opened and p.opened.unit_number or 0)")
    report(heard("on_gui_opened") and opened == str(a["u"]), "as player: opening a machine opens it for the player (on_gui_opened)", opened)
    c.send({"t": "close"})
    c.pump(0.6, every=hello)
    report(heard("on_gui_closed"), "as player: closing it raises on_gui_closed")
    mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'assembling-machine-1' }})) do "
            f"if e.unit_number == {a['u']} then e.set_recipe('iron-gear-wheel') end end")
    c.send({"t": "paste_settings", "f": [a["u"], a["p"], a["x"], a["y"]], **b})
    c.pump(0.6, every=hello)
    report(heard("on_entity_settings_pasted"), "as player: pasting settings raises on_entity_settings_pasted")

    belt = ident("transport-belt", bx, by)
    c.pump(3.0, every=(0.2, {"t": "mine", **belt}))
    report(not unit_at("transport-belt", bx, by) and heard("on_player_mined_entity"),
           "as player: mining raises on_player_mined_entity for the player")

    # Far reach: the bridge goes by the character's real build distance (a mod's bonus too).
    fx_, fy_ = math.floor(x) + 14.5, math.floor(y) + 0.5
    c.send({"t": "build", "item": "transport-belt", "x": int(fx_ * 256), "y": int(fy_ * 256), "d": 4})
    c.pump(0.8, every=hello)
    before = unit_at("transport-belt", fx_, fy_)
    mod_lua("storage.f3d.puppet.character_build_distance_bonus = 10")
    c.send({"t": "build", "item": "transport-belt", "x": int(fx_ * 256), "y": int(fy_ * 256), "d": 4})
    c.pump(0.8, every=hello)
    report(not before and unit_at("transport-belt", fx_, fy_), "as player: 14 tiles away is out of reach, and in reach with a +10 build bonus")
    mod_lua("storage.f3d.puppet.character_build_distance_bonus = 0")

    # Only the mod that owns a setting may change it: set it in the bridge's own state.
    mod_lua('settings.global["f3d-act-as-player"] = { value = false }')
    rcon.run("/c remote.call('probe', 'reset')")
    c.send({"t": "build", "item": "transport-belt", "x": int(bx * 256), "y": int((by + 6) * 256), "d": 4})
    c.pump(1.0, every=hello)
    d = probe()["c"]
    report(unit_at("transport-belt", bx, by + 6) and not d.get("on_built_entity") and d.get("script_raised_built"),
           "as player off: the bridge builds by script (script_raised_built only)", json.dumps(d))
    mod_lua('settings.global["f3d-act-as-player"] = { value = true }')


def parse_args():
    global FACTORIO_PORT, CLIENT_PORT, SECOND_CLIENT_PORT, SERVER_LOG, GODOT, BINARY
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--factorio-port", type=int, default=FACTORIO_PORT, help="the server's --enable-lua-udp port")
    parser.add_argument("--client-port", type=int, default=CLIENT_PORT, help="the port this binds, as the client would")
    parser.add_argument("--rcon-port", type=int, default=rcon.PORT)
    parser.add_argument("--godot", help="the Godot binary for pipevis's run of the client's own rule (default: $GODOT, godot on PATH)")
    parser.add_argument("--rcon-password", help="default: server/data/rcon-password.txt")
    parser.add_argument("--second-client-port", type=int, default=0, help="the two-client check's second client (default: the client port + 1)")
    parser.add_argument("--server-log", help="the server's factorio-current.log, for the barrier check (default: server/data's, "
                                             "when it is this server's)")
    parser.add_argument("--only", choices=["platforms", "planets", "space", "ride", "collectors", "ui", "input", "cliffs", "save", "gear", "planners", "circuits", "build", "info",
                                           "alerts", "multi", "remnants", "machines", "logic", "vehicles", "hud", "turrets", "weapons", "enemies", "console", "remote", "walk", "pickup", "states", "repair", "mapinfo", "triggers", "minevehicles", "alt", "asplayer", "modgfx", "beltswitch", "barrier", "research", "join", "underclear", "vehitems", "pipeend", "pipevis", "link", "sprint", "steps", "enemysight", "enemysightfix"], help="run just these checks after the handshake")
    parser.add_argument("--binary", action="store_true", help="every hello asks for binary frames (bin): the checks read "
                        "them as the client does (protocol.py), and the end says how many datagrams came binary")
    args = parser.parse_args()
    BINARY = args.binary
    FACTORIO_PORT, CLIENT_PORT, rcon.PORT = args.factorio_port, args.client_port, args.rcon_port
    GODOT = args.godot
    rcon.PASSWORD = args.rcon_password
    SECOND_CLIENT_PORT = args.second_client_port
    SERVER_LOG = args.server_log
    return args


def main():
    args = parse_args()
    print("RCON:", rcon.run("/f3d-status").replace("\n", " | "))
    # The first /c in a save only warns that it disables achievements; get that out of the way.
    rcon.run("/c rcon.print('ok')")
    c = Client(FACTORIO_PORT, CLIENT_PORT)
    if args.only in ("platforms", "planets", "space", "ride", "collectors"):
        if handshake(c):
            hello = (1.0, {"t": "hello", "v": 1, "sid": c.sid, "w": 1})
            c.pump(1.0, every=hello)
            {"platforms": check_platforms, "planets": check_planets, "space": check_space, "ride": check_ride,
             "collectors": check_collectors}[args.only](c, hello)
            report(not c.invalid, "every message passes tools/protocol.py", str(c.invalid[:3]))
        report_step_errors()
        print(f"\n{results.count(True)} passed, {results.count(False)} failed")
        sys.exit(0 if all(results) else 1)

    if args.only == "steps":
        check_steps(c, None)
        report(not c.invalid, "every message passes tools/protocol.py", str(c.invalid[:3]))
        report_step_errors()
        print(f"\n{results.count(True)} passed, {results.count(False)} failed")
        sys.exit(0 if all(results) else 1)

    if args.only == "modgfx":
        welcome = handshake(c)
        if welcome:
            hello = (1.0, {"t": "hello", "v": 1, "sid": c.sid, "w": 1})
            c.pump(1.0, every=hello)
            check_mod_graphics(c, hello, welcome[0])
            report(not c.invalid, "every message passes tools/protocol.py", str(c.invalid[:3]))
        report_step_errors()
        print(f"\n{results.count(True)} passed, {results.count(False)} failed")
        sys.exit(0 if all(results) else 1)

    if args.only in ("link", "sprint"):
        welcome = handshake(c)
        if welcome:
            hello = (1.0, {"t": "hello", "v": 1, "sid": c.sid, "w": 1})
            c.pump(1.0, every=hello)
            if args.only == "link":
                check_link(c, hello, welcome[0])
            else:
                check_sprint(c, hello)
            report(not c.invalid, "every message passes tools/protocol.py", str(c.invalid[:3]))
        report_step_errors()
        print(f"\n{results.count(True)} passed, {results.count(False)} failed")
        sys.exit(0 if all(results) else 1)

    if args.only == "console":
        if handshake(c):
            hello = (1.0, {"t": "hello", "v": 1, "sid": c.sid, "w": 1})
            c.pump(1.0, every=hello)
            check_console(c, hello, cheat=True)
            report(not c.invalid, "every message passes tools/protocol.py", str(c.invalid[:3]))
        report_step_errors()
        print(f"\n{results.count(True)} passed, {results.count(False)} failed")
        sys.exit(0 if all(results) else 1)

    if args.only in ("cliffs", "save", "gear", "build", "alerts", "multi", "remnants", "turrets", "weapons", "enemies", "remote", "walk", "pickup", "states", "repair", "mapinfo", "triggers", "minevehicles", "alt", "beltswitch", "asplayer", "barrier", "research", "join", "underclear", "vehitems", "pipeend", "pipevis", "enemysight", "enemysightfix"):
        if handshake(c):
            hello = (1.0, {"t": "hello", "v": 1, "sid": c.sid, "w": 1})
            c.pump(1.0, every=hello)
            {"cliffs": check_cliffs, "save": check_save, "gear": check_gear, "build": check_build_tools,
             "alerts": check_alerts, "multi": check_multi, "remnants": check_remnants, "turrets": check_turrets, "weapons": check_weapons,
             "enemies": check_enemies, "remote": check_remote_view, "walk": check_walk, "pickup": check_pickup, "states": check_states,
             "repair": check_repair, "mapinfo": check_map_info, "triggers": check_triggers, "minevehicles": check_mine_vehicles, "alt": check_alt, "beltswitch": check_belt_switch, "asplayer": check_as_player,
             "barrier": check_barrier, "research": check_research, "join": check_join, "underclear": check_under_clear, "pipeend": check_pipe_end,
             "vehitems": check_vehicle_items, "pipevis": check_pipe_vis, "enemysight": check_enemy_sight,
             "enemysightfix": lambda c, h: check_enemy_sight(c, h, nest_only=True)}[args.only](c, hello)
            report(not c.invalid, "every message passes tools/protocol.py", str(c.invalid[:3]))
        report_step_errors()
        print(f"\n{results.count(True)} passed, {results.count(False)} failed")
        sys.exit(0 if all(results) else 1)

    if args.only in ("ui", "input", "planners", "circuits", "info", "machines", "logic", "vehicles", "hud"):
        if handshake(c):
            hello = (1.0, {"t": "hello", "v": 1, "sid": c.sid, "w": 1})
            c.pump(1.0, every=hello)
            {"ui": check_ui_parity, "input": check_input, "planners": check_planners, "circuits": check_circuits, "info": check_info,
             "machines": check_machines, "logic": check_logic, "vehicles": check_vehicles, "hud": check_hud}[args.only](c, hello)
            report(not c.invalid, "every message passes tools/protocol.py", str(c.invalid[:3]))
        report_step_errors()
        print(f"\n{results.count(True)} passed, {results.count(False)} failed")
        sys.exit(0 if all(results) else 1)

    # --- handshake and chunks ------------------------------------------------------------------
    msgs = c.pump(6, until=lambda m: m.get("t") == "ready", every=(1.0, {"t": "hello", "v": 1, "sid": c.sid, "w": 0}))
    early = list(msgs)
    welcome = of_type(msgs, "welcome")
    report(bool(welcome) and bool(of_type(msgs, "ready")), "handshake: welcome, prototypes, ready",
           f"{len(c.protos)} entity prototypes, multiplayer={welcome[0].get('mp') if welcome else '?'}")
    if not welcome:
        sys.exit(1)
    c.send({"t": "hello", "v": 1, "sid": c.sid, "w": 1})
    msgs = c.pump(1.0)
    early += msgs
    x, y = welcome[0]["x"] / 256, welcome[0]["y"] / 256
    cx, cy = int(x // 32), int(y // 32)
    wanted = [[cx + dx, cy + dy] for dy in range(-2, 3) for dx in range(-2, 3)]
    c.send({"t": "sub", "c": wanted})
    c.send({"t": "focus", "x": int(x * 256), "y": int(y * 256), "r": 48})
    hello = (1.0, {"t": "hello", "v": 1, "sid": c.sid, "w": 1})
    msgs = c.pump(15, every=hello, until=lambda m: m.get("t") == "ents" and [m["cx"], m["cy"]] == wanted[-1] and m["part"] == m["parts"])
    chunks = {(m["cx"], m["cy"]) for m in of_type(msgs, "chunk")}
    ents = [e for m in of_type(msgs, "ents") for e in m["e"]]
    report(len(chunks) == len(wanted), "every subscribed chunk arrives", f"{len(chunks)}/{len(wanted)} chunks, {len(ents)} entities")
    quals = of_type(early + msgs, "quals")
    report(bool(quals) and quals[-1]["l"][0][:3] == ["normal", 0, 1],
           "quals: the qualities by level, normal unlocked (prototypes.quality, is_quality_unlocked)", str(quals[-1:])[:300])
    report(not c.invalid, "every message passes tools/protocol.py", str(c.invalid[:3]))
    welcome_bin = c.last.get("welcome", {}).get("bin")
    if BINARY:
        report(welcome_bin == protocol.WIRE_VERSION and c.binary_datagrams > 0 and "mv" in c.last,
               "--binary: the welcome says bin, datagrams come as binary frames, movers among them",
               f"bin {welcome_bin}, {c.binary_datagrams} of {c.datagrams} datagrams binary")
    else:
        report(welcome_bin is None and c.binary_datagrams == 0, "without bin in the hello: JSON text only",
               f"bin {welcome_bin}, {c.binary_datagrams} binary datagrams")

    # --- decoratives --------------------------------------------------------------------------------
    check_decoratives(c, hello, x, y, wanted)

    # --- Factorio's world controls and entity windows (early, while there is room to build) -----
    check_ui_parity(c, hello)
    check_input(c, hello)
    check_planners(c, hello)
    check_circuits(c, hello)

    # --- walking -------------------------------------------------------------------------------
    c.pump(0.5, every=hello)
    start = (c.me["x"], c.me["y"])
    c.pump(1.5, every=(0.15, {"t": "walk", "d": 4}))
    moved = (c.me["x"] - start[0]) / 256
    report(moved > 3 and c.me["w"] == 1, "a player-less character walks east while walk is repeated", f"moved {moved:.2f} tiles")
    c.send({"t": "walk", "d": -1})
    c.pump(0.4, every=hello)
    stop_x = c.me["x"]
    c.pump(1.0, every=hello)
    report(c.me["x"] == stop_x and c.me["w"] == 0, "walk -1 stops it", f"drift {(c.me['x'] - stop_x) / 256:.2f} tiles")
    check_walk(c, hello)
    check_pickup(c, hello)

    # --- building and rotating -----------------------------------------------------------------
    # Start from a clean, watched spot (check_walk ends on its own, so this is usually that one).
    if not clean_spot(c, hello):
        report(False, "build: no clean spot found", SPOT_WHY)
    # The starter kit is freeplay's, which has no chests or inserters.
    mod_lua('storage.f3d.puppet.insert({name = "wooden-chest", count = 5}) storage.f3d.puppet.insert({name = "inserter", count = 5})')
    c.pump(1.0, every=hello)
    px, py = c.me["x"] / 256, c.me["y"] / 256
    chest_before = c.inv.get("wooden-chest", 0)
    bx, by = int((px + 3) * 256), int(py * 256)
    c.send({"t": "build", "item": "wooden-chest", "x": bx, "y": by, "d": 0})
    # Up to 3 s: a slow runner (CI) can still be reading what was sent before the build.
    msgs = c.pump(3.0, every=hello, until=lambda m: m.get("t") == "add" and m["e"][1] == c.proto_id("wooden-chest"))
    adds = [m["e"] for m in of_type(msgs, "add") if m["e"][1] == c.proto_id("wooden-chest")]
    report(bool(adds), "build: create_entity{raise_built=true} sends add via script_raised_built",
           "; ".join(m["text"] for m in of_type(msgs, "msg")))
    c.pump(1.0, every=hello)
    report(c.inv.get("wooden-chest", 0) == chest_before - 1, "build takes the item from the inventory",
           f"{chest_before} -> {c.inv.get('wooden-chest', 0)}")

    c.send({"t": "build", "item": "inserter", "x": bx, "y": by + 2 * 256, "d": 0})
    msgs = c.pump(3.0, every=hello, until=lambda m: m.get("t") == "add" and m["e"][1] == c.proto_id("inserter"))
    ins = [m["e"] for m in of_type(msgs, "add") if m["e"][1] == c.proto_id("inserter")]
    if ins:
        e = ins[0]
        c.send({"t": "rotate", "u": e[0], "p": e[1], "x": e[2], "y": e[3]})
        msgs = c.pump(3.0, every=hello, until=lambda m: m.get("t") == "upd" and m["e"][0] == e[0] and m["e"][4] == 4)
        upd = [m["e"] for m in of_type(msgs, "upd") if m["e"][0] == e[0]]
        report(bool(upd) and upd[-1][4] == 4, "rotate turns the inserter east and sends upd", str(upd[-1:]))
    else:
        report(False, "build an inserter to rotate", "; ".join(m["text"] for m in of_type(msgs, "msg")))

    # --- mining --------------------------------------------------------------------------------
    if adds:
        e = adds[0]
        mine = {"t": "mine", "u": e[0], "p": e[1], "x": e[2], "y": e[3]}
        msgs = c.pump(4.0, every=(0.15, mine), until=lambda m: m.get("t") == "del" and m.get("u") == e[0])
        report(any(m.get("u") == e[0] for m in of_type(msgs, "del")), "character.mine_entity works without a player",
               "; ".join(m["text"] for m in of_type(msgs, "msg")))
        c.send({"t": "mine_stop"})
        c.pump(1.0, every=hello)
        report(c.inv.get("wooden-chest", 0) == chest_before, "the mined chest is back in the inventory",
               f"{c.inv.get('wooden-chest', 0)}")

    # --- items on belts --------------------------------------------------------------------------
    # Eight belts running east, four tiles north of the character, with an iron plate put on
    # both lanes of each. They ride to the end of the line and stop there.
    px, py = c.me["x"] / 256, c.me["y"] / 256
    x0, row = int(px) - 4, int(py) - 4
    c.send({"t": "focus", "x": int(px * 256), "y": int(py * 256), "r": 48})
    out = mod_lua(f"""
local s = storage.f3d.puppet.surface local n = 0
for _, e in pairs(s.find_entities_filtered({{ area = {{ {{ {x0} - 1, {row} - 1 }}, {{ {x0} + 9, {row} + 2 }} }}, type = {{ "transport-belt", "item-entity" }} }})) do e.destroy() end
for i = 0, 7 do
  local b = s.create_entity({{ name = "transport-belt", position = {{ {x0} + i + 0.5, {row} + 0.5 }}, direction = defines.direction.east, force = "player" }})
  if b then for l = 1, 2 do if b.get_transport_line(l).insert_at_back({{ name = "iron-plate", count = 1 }}) then n = n + 1 end end end
end
rcon.print(n .. " items placed")
""".replace("\n", " "))
    msgs = c.pump(2.0, every=hello)
    frames = {}
    for m in of_type(msgs, "bi"):
        l = m["l"]
        frames.setdefault(m["k"], {}).update({l[i]: l[i + 1:i + 4] for i in range(0, len(l), 4)})
    ticks = sorted(frames)
    def row_items(frame):
        return {u: v for u, v in frame.items() if abs(v[2] / 256 - (row + 0.5)) <= 0.3 and x0 <= v[1] / 256 <= x0 + 8}

    # The first updates can come from where the focus was before; start from the first that shows
    # the test belts.
    with_row = [k for k in ticks if row_items(frames[k])]
    first = row_items(frames[with_row[0]]) if with_row else {}
    last = frames[ticks[-1]] if ticks else {}
    on_row = list(row_items(last).values())
    report(len(on_row) >= 16 and all(c.items.get(v[0]) == "iron-plate" for v in on_row),
           "bi: items on belts arrive with item ids and positions on the belt row",
           f"{out}; {len(ticks)} updates, {len(last)} items, {len(on_row)} on the row")
    squared = [m for m in of_type(msgs, "bi") if "fr" in m]
    report(squared and len(squared) == len(of_type(msgs, "bi")) and all(m["fr"] > 0 for m in squared),
           "bi: every part says the square it covers (fx, fy, fr), where the client hands over to lane icons (G16)",
           f"{[(m['fx'] / 256, m['fy'] / 256, m['fr']) for m in squared[:2]]}")
    lanes = sorted({v[2] - (row * 256 + 128) for v in on_row})
    report(lanes and min(lanes) < 0 < max(lanes), "the two lanes sit either side of the belt centre", f"y offsets {lanes} / 256")
    # #2 / B2: what each lane carries, for drawing belts far away (bfar). With no near square (n 0):
    # a chunk wholly inside the square the last `bi` covered isn't read for far lanes (G16; the
    # client draws its items), and whether the test belts' chunk was depended on where in its chunk
    # the spot fell (the 0.2.0 CI run's spot passed, the next spot over didn't). The rounds come
    # once the bridge reaches them: waited for, up to 6 s, not a fixed 2 s.
    cx0, cy0 = int((x0 + 4) // 32), int(row // 32)
    c.send({"t": "sub", "c": [[cx0 + dx, cy0 + dy] for dy in (-1, 0, 1) for dx in (-1, 0, 1)]})
    c.send({"t": "bfar", "r": 100, "n": 0})

    def our_rows(msgs):
        rows = [m["l"][i:i + 5] for m in msgs for i in range(0, len(m["l"]), 5)]
        return rows, [r for r in rows if r[1] == row * 256 + 128 and x0 * 256 <= r[0] <= (x0 + 8) * 256]
    far_msgs = []
    far_end = time.time() + 6.0
    while time.time() < far_end and len(our_rows(far_msgs)[1]) < 8:
        far_msgs += [m for m in c.pump(0.5, every=hello) if m.get("t") == "bfar"]
    rows, ours = our_rows(far_msgs)
    plate = next((i for i, n in c.items.items() if n == "iron-plate"), None)
    report(len(ours) >= 4 and all(r[2] == 4 for r in ours) and any(plate in r[3:5] for r in ours),
           "bfar: each belt's direction and what its lanes carry (LuaTransportLine.get_contents)", f"{len(rows)} belts, ours {ours[:3]}")
    counted = [m for m in far_msgs if len(m.get("c", [])) == len(m["l"]) // 5 * 2]
    our_counts = [m["c"][i // 5 * 2:i // 5 * 2 + 2] for m in far_msgs if m in counted for i in range(0, len(m["l"]), 5)
                  if m["l"][i + 1] == row * 256 + 128 and x0 * 256 <= m["l"][i] <= (x0 + 8) * 256]
    report(far_msgs and len(counted) == len(far_msgs) and our_counts and all(0 <= n <= 4 for p in our_counts for n in p) and any(sum(p) > 0 for p in our_counts),
           "bfar c: how many items each lane of each belt holds (0-4), so far belts are drawn as full as they are (G17)", f"ours {our_counts[:4]}")
    c.send({"t": "bfar", "r": 0})
    kept = [u for u in first if u in last]
    crossed = [u for u in kept if int(first[u][1] / 256) != int(last[u][1] / 256)]
    report(bool(crossed), "unique_id stays the same as an item moves onto the next belt",
           f"{len(kept)} ids in the first and last update, {len(crossed)} of them changed belt")
    # belt_items.lua works a straight belt's item positions out from where its lines start, read
    # once per update; compare with get_line_item_position for single belts facing each way.
    out = mod_lua(f"""
local s = storage.f3d.puppet.surface local bi = package.loaded["__factorio-3d-bridge__/scripts/belt_items.lua"]
local worst, n, east = 0, 0, ""
for k, d in pairs({{ defines.direction.north, defines.direction.east, defines.direction.south, defines.direction.west }}) do
  local b = s.create_entity({{ name = "transport-belt", position = {{ {x0} + 3 * k + 0.5, {row} - 5.5 }}, direction = d, force = "player" }})
  if b then
    for l = 1, 2 do for q = 0, 0.75, 0.25 do b.get_transport_line(l).insert_at(q, {{ name = "iron-plate", count = 1 }}) end end
    for _, r in pairs(bi.check_straight(b)) do worst = math.max(worst, math.abs(r[1] - r[3]), math.abs(r[2] - r[4])) n = n + 1 end
    if d == defines.direction.east then
      local line = b.get_transport_line(1) local a, z = line.get_line_item_position(0), line.get_line_item_position(1)
      east = string.format("east belt at %.2f,%.2f: line 1 position 0 at %.3f,%.3f, 1 at %.3f,%.3f", b.position.x, b.position.y, a.x, a.y, z.x, z.y)
    end
    b.destroy()
  end
end
rcon.print(n .. " " .. string.format("%.5f", worst) .. " " .. east)
""".replace("\n", " "))
    parts = out.split()[:2]
    report(len(parts) == 2 and int(parts[0]) >= 16 and float(parts[1]) < 1 / 256,
           "straight belts: items' positions worked out from the line start match get_line_item_position", out)

    # --- inserter hands and the sky ----------------------------------------------------------------
    hands = {}
    for m in of_type(msgs, "ih"):
        l = m["l"]
        hands.update({l[i]: l[i + 1:i + 4] for i in range(0, len(l), 4)})
    if ins:
        h = hands.get(ins[0][0])
        report(h is not None and abs(h[0] - ins[0][2]) <= 2 * 256 and abs(h[1] - ins[0][3]) <= 2 * 256,
               "ih: the built inserter's hand (held_stack_position) is sent near the inserter", str(h))
    sky = of_type(msgs, "sky")
    report(bool(sky) and 0 <= sky[-1]["d"] < 1000 and 0 <= sky[-1]["n"] <= 1000,
           "sky: surface.daytime and surface.darkness are sent", str(sky[-1:]))
    mod_lua(f"""
for _, b in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ area = {{ {{ {x0}, {row} }}, {{ {x0} + 8, {row} + 1 }} }}, type = "transport-belt" }})) do b.destroy() end
""".replace("\n", " "))

    # --- items on the ground ------------------------------------------------------------------------
    # Five plates spilled at the character's feet and one plate three tiles east, out of pickup
    # range. Checks find_entities_filtered{type = "item-entity"}, item-entity.stack,
    # item_pickup_distance and mine_entity on an item-entity without a player.
    px, py = c.me["x"] / 256, c.me["y"] / 256
    out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface
local spilled = s.spill_item_stack({{ position = c.position, stack = {{ name = "iron-plate", count = 5 }} }})
local far = s.create_entity({{ name = "item-on-ground", position = {{ {px} + 3, {py} }}, stack = {{ name = "iron-plate", count = 1 }} }})
rcon.print(#spilled .. " " .. (far and (far.position.x .. " " .. far.position.y .. " " .. far.stack.count) or "none") .. " " .. c.item_pickup_distance)
""".replace("\n", " "))
    try:
        n_spilled, fx, fy, far_count, pickup_distance = out.split()
        far_pos = [round(float(fx) * 256), round(float(fy) * 256)]
    except ValueError:
        n_spilled, far_pos, far_count, pickup_distance = "?", None, "?", "?"
    msgs = c.pump(1.2, every=hello)
    gi = of_type(msgs, "gi")
    lying = [gi[-1]["l"][i:i + 3] for i in range(0, len(gi[-1]["l"]), 3)] if gi else []
    plates = [r for r in lying if c.items.get(r[0]) == "iron-plate"]
    report(len(plates) >= 6 and any(r[1:] == far_pos for r in plates),
           "gi: items on the ground arrive with item ids and positions (item-entity.stack)",
           f"spill made {n_spilled} entities, far one holds {far_count}, item_pickup_distance {pickup_distance}; "
           f"{len(gi)} updates in 1.2 s, {len(lying)} items, {len(plates)} plates")
    before = c.inv.get("iron-plate", 0)
    c.pump(2.0, every=(0.15, {"t": "pickup"}))
    msgs = c.pump(1.5, every=hello)
    gi = of_type(msgs, "gi")
    lying = [gi[-1]["l"][i:i + 3] for i in range(0, len(gi[-1]["l"]), 3)] if gi else []
    left = [r for r in lying if c.items.get(r[0]) == "iron-plate"]
    report(c.inv.get("iron-plate", 0) >= before + 5 and any(r[1:] == far_pos for r in left),
           "pickup: mine_entity on item-entities within reach, without a player; the far one stays",
           f"iron plates {before} -> {c.inv.get('iron-plate', 0)}; plates still on the ground: {len(left)}; "
           + "; ".join(m["text"] for m in of_type(msgs, "msg")))
    # Not used by the mod: whether the game's own pickup (picking_state, what F does) works for a
    # character without a player. Worth knowing as an alternative.
    out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface
for _, e in pairs(s.find_entities_filtered({{ type = "item-entity", area = {{ {{ {px} - 5, {py} - 5 }}, {{ {px} + 5, {py} + 5 }} }} }})) do e.destroy() end
s.create_entity({{ name = "item-on-ground", position = c.position, stack = {{ name = "iron-plate", count = 1 }} }})
storage.f3d_probe = c.get_main_inventory().get_item_count("iron-plate")
local ok, err = pcall(function() c.picking_state = true end)
rcon.print(ok and "set" or tostring(err))
""".replace("\n", " "))
    time.sleep(0.5)
    probe = mod_lua("""
local c = storage.f3d.puppet
local n = c.get_main_inventory().get_item_count("iron-plate") - storage.f3d_probe
pcall(function() c.picking_state = false end)
for _, e in pairs(c.surface.find_entities_filtered({ type = "item-entity", position = c.position, radius = 3 })) do e.destroy() end
storage.f3d_probe = nil
rcon.print(n)
""".replace("\n", " "))
    print(f"     picking_state without a player: {out}; plates picked up in 0.5 s: {probe} (informational)")

    # --- combat ------------------------------------------------------------------------------------
    # Small biters next to the character, made inactive so they stand still, shot with a pistol:
    # one with Space (shooting_enemies), one with C at its position (shooting_selected). Checks
    # shooting_state on a player-less character, the gun and ammo inventories, selected_gun_index,
    # LuaItemStack.ammo (me.sh), max_health, on_entity_damaged with get_health_ratio, and
    # on_entity_died.
    mod_lua('local c = storage.f3d.puppet c.insert({name = "pistol", count = 1}) c.insert({name = "firearm-magazine", count = 10}) storage.f3d.guns_sig = nil')
    msgs = c.pump(0.6, every=hello)
    guns = of_type(msgs, "guns")
    slots = guns[-1]["l"] if guns else []
    report(any(s[0] == "pistol" and s[1] == "firearm-magazine" and s[2] > 0 for s in slots),
           "guns: the character's gun and ammo inventories", str(guns[-1:]))
    report(c.me.get("mhp", 0) > 0, "me.mhp: the character's max_health", str(c.me.get("mhp")))

    def biter(dx, dy):
        out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface
local p = s.find_non_colliding_position("small-biter", {{ c.position.x + {dx}, c.position.y + {dy} }}, 4, 0.5)
local b = p and s.create_entity({{ name = "small-biter", position = p, force = "enemy" }})
if b and not pcall(function() b.disabled_by_script = true end) then b.active = false end
rcon.print(b and (b.unit_number .. " " .. b.position.x .. " " .. b.position.y) or "none")
""".replace("\n", " "))
        try:
            unit, x, y = out.split()
            return int(unit), round(float(x) * 256), round(float(y) * 256)
        except ValueError:
            report(False, "spawn a small biter to shoot", out)
            return None

    def shoot_at(target, mode):
        unit, x, y = target
        msgs = c.pump(4.0, every=(0.15, {"t": "shoot", "m": mode, "x": x, "y": y}),
                      until=lambda m: m.get("t") == "died" and m.get("u") == unit)
        c.send({"t": "shoot", "m": -1})
        return msgs + c.pump(0.6, every=hello)

    px, py = c.me["x"] / 256, c.me["y"] / 256
    first = biter(6, -2)
    if first:
        msgs = shoot_at(first, 0)
        damaged = [m["l"][i + 1] for m in of_type(msgs, "hp") for i in range(0, len(m["l"]), 2) if m["l"][i] == first[0]]
        report(any(m.get("u") == first[0] for m in of_type(msgs, "died")),
               "shoot m=0: shooting_state shooting_enemies kills a biter without a player (on_entity_died -> died)",
               "; ".join(m["text"] for m in of_type(msgs, "msg")))
        report(any(m.get("sh") == 1 for m in of_type(msgs, "me")), "me.sh: the ammo count (LuaItemStack.ammo) goes down while firing")
        report(bool(damaged) and min(damaged) < 1000, "hp: on_entity_damaged and get_health_ratio report the wounded biter",
               f"health seen {damaged}")
    second = biter(5, 3)
    if second:
        msgs = shoot_at(second, 1)
        report(any(m.get("u") == second[0] for m in of_type(msgs, "died")),
               "shoot m=1: shooting_selected at a position kills the biter standing there (no `selected` entity)",
               "; ".join(m["text"] for m in of_type(msgs, "msg")))
    state = mod_lua("rcon.print(storage.f3d.puppet.shooting_state.state == defines.shooting.not_shooting)")
    report(state == "true", "shoot m=-1 sets not_shooting", state)
    mod_lua('storage.f3d.puppet.insert({name = "submachine-gun", count = 1})')
    c.send({"t": "gun", "i": 2})
    msgs = c.pump(0.6, every=hello)
    guns = of_type(msgs, "guns")
    report(bool(guns) and guns[-1]["sel"] == 2, "gun: selected_gun_index can be written", str(guns[-1:]))
    c.send({"t": "gun", "i": 1})
    mod_lua(f"""
for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ type = "unit", position = {{ {px}, {py} }}, radius = 12 }})) do e.destroy() end
""".replace("\n", " "))

    # --- vehicles -----------------------------------------------------------------------------------
    # A fuelled car next to the character: get in, drive, steer, brake, get out. Then a locomotive
    # on a short straight track. Checks set_driver / set_driver(nil) and character.vehicle for a
    # player-less character, riding_state, the vehicle's speed, and the train's manual mode.
    def vehicle_lua(code):
        return mod_lua(code.replace("\n", " "))

    def orientations(msgs, unit):
        return [r[4] for m in of_type(msgs, "mv") for r in m["l"] if r[0] == unit and len(r) > 4]

    def drive_checks(unit, what, min_move):
        c.send({"t": "enter"})
        c.pump(0.5, every=hello)
        report(c.me.get("v") == unit, f"enter: set_driver puts the player-less character in the {what}",
               f"me.v {c.me.get('v')}, expected {unit}")
        if c.me.get("v") != unit:
            return
        x0, y0 = c.me["x"], c.me["y"]
        msgs = c.pump(1.5, every=(0.15, {"t": "drive", "a": 1, "s": 0}))
        moved = ((c.me["x"] - x0) ** 2 + (c.me["y"] - y0) ** 2) ** 0.5 / 256
        report(moved > min_move and c.me.get("vs", 0) > 0, f"drive: riding_state accelerates the {what}; me follows it",
               f"moved {moved:.1f} tiles, vs {c.me.get('vs')}; " + "; ".join(m["text"] for m in of_type(msgs, "msg")))
        return msgs

    clean_spot(c, hello, half=24)  # the car drives off north, turns and brakes: room for that
    out = vehicle_lua(f"""
local c = storage.f3d.puppet local s = c.surface
local p = s.find_non_colliding_position("car", {{ c.position.x + 4, c.position.y }}, 10, 0.5)
local car = p and s.create_entity({{ name = "car", position = p, force = c.force }})
if car then
  car.get_fuel_inventory().insert({{ name = "coal", count = 20 }})
  c.teleport(s.find_non_colliding_position("character", car.position, 10, 0.5))
end
rcon.print(car and car.unit_number or "none")
""")
    car = None
    if out.isdigit():
        car = int(out)
        msgs = drive_checks(car, "car", 1.0)
        if msgs is not None:
            before = orientations(msgs, car)
            msgs = c.pump(1.0, every=(0.15, {"t": "drive", "a": 1, "s": 1}))
            after = orientations(msgs, car)
            turn = (after[-1] - before[-1] + 500) % 1000 - 500 if before and after else 0
            report(turn > 20, "drive s=1 steers the car right (clockwise)", f"orientation {before[-1:]} -> {after[-1:]}")
            c.pump(2.5, every=(0.15, {"t": "drive", "a": 2, "s": 0}))
            report(abs(c.me.get("vs", 999)) <= 2, "drive a=2 brakes to a stop", f"vs {c.me.get('vs')}")
            c.send({"t": "drive", "a": 0, "s": 0})
            c.send({"t": "enter"})
            c.pump(0.5, every=hello)
            report("v" not in c.me, "enter again: set_driver(nil) gets the character out", str(c.me))
    else:
        report(False, "place a car for the vehicle checks", out)

    out = vehicle_lua(f"""
local c = storage.f3d.puppet local s = c.surface
local x0 = 2 * math.floor(c.position.x / 2) + 1 local y0 = 2 * math.floor(c.position.y / 2) + 13
storage.f3d_live_rails = {{}}
for i = -30, 30 do
  local r = s.create_entity({{ name = "straight-rail", position = {{ x0 + 2 * i, y0 }}, direction = defines.direction.east, force = c.force }})
  if r then table.insert(storage.f3d_live_rails, r) end
end
local rails = #storage.f3d_live_rails
local loco = s.create_entity({{ name = "locomotive", position = {{ x0, y0 }}, direction = defines.direction.east, force = c.force }})
if loco then
  loco.get_fuel_inventory().insert({{ name = "coal", count = 20 }})
  c.teleport(s.find_non_colliding_position("character", loco.position, 10, 0.5))
end
rcon.print((loco and loco.unit_number or "none") .. " " .. rails)
""")
    loco = out.split()[0] if out else ""
    if loco.isdigit():
        loco = int(loco)
        if drive_checks(loco, "locomotive", 0.2) is not None:  # trains pull away slowly
            manual = vehicle_lua("rcon.print(storage.f3d.puppet.vehicle and storage.f3d.puppet.vehicle.train.manual_mode)")
            report(manual == "true", "driving a locomotive switched its train to manual mode", manual)
            c.pump(3.0, every=(0.15, {"t": "drive", "a": 2, "s": 0}))
            c.send({"t": "drive", "a": 0, "s": 0})
            c.send({"t": "enter"})
            c.pump(0.5, every=hello)
            report("v" not in c.me, "and gets out of the locomotive", str(c.me))
    else:
        report(False, "place a locomotive on a straight track for the train checks", out)
    # Only what this check made: the owner may run it on a real save.
    made = [str(u) for u in (car if isinstance(car, int) else 0, loco if isinstance(loco, int) else 0) if u]
    vehicle_lua(f"""
for _, u in pairs({{ {", ".join(made)} }}) do
  local e = game.get_entity_by_unit_number(u)
  if e and e.valid and not e.get_driver() then e.destroy() end
end
for _, r in pairs(storage.f3d_live_rails or {{}}) do if r.valid then r.destroy() end end
storage.f3d_live_rails = nil
""")

    # --- inventory slots, quickbar, crafting, research ------------------------------------------------
    # Checks LuaInventory indexing (#inv, inv[i]), LuaItemStack transfer_stack with an amount,
    # swap_stack and quality, sort_and_merge, the crafting queue API (crafting_queue,
    # crafting_queue_progress, cancel_crafting, get_craftable_count), recipe groups, ingredients and
    # products, and the force's technologies, add_research, research_queue and current_research.
    def latest(msgs, t):
        found = of_type(msgs, t)
        return found[-1] if found else None

    mod_lua("storage.f3d.slots_sig = nil")
    msgs = c.pump(0.8, every=hello)
    sl = latest(msgs, "slots")
    main = sl["l"].get("main", []) if sl else []
    totals = {}
    for v in main:
        if v:
            totals[v[0]] = totals.get(v[0], 0) + v[1]
    report(len(main) >= 80 and all(totals.get(k) == n for k, n in c.inv.items()),
           "slots: the main inventory slot by slot (#inv, inv[i]) adds up to inv", f"{len(main)} slots, roles {sorted(sl['l']) if sl else None}")
    full = [i + 1 for i, v in enumerate(main) if v and v[1] >= 2]
    empty = [i + 1 for i, v in enumerate(main) if not v]
    if full and len(empty) >= 2:
        fi, ti = full[0], empty[-1]
        item, count = main[fi - 1][0], main[fi - 1][1]
        c.send({"t": "move", "from": "main", "fi": fi, "to": "main", "ti": ti, "n": 1})
        msgs = c.pump(0.5, every=hello)
        after = latest(msgs, "slots")["l"]["main"] if latest(msgs, "slots") else main
        report(after[ti - 1] == [item, 1] and after[fi - 1] == [item, count - 1],
               "move n=1 splits a stack (transfer_stack with an amount)", f"{after[fi - 1]} / {after[ti - 1]}; "
               + "; ".join(m["text"] for m in of_type(msgs, "msg")))
        c.send({"t": "move", "from": "main", "fi": ti, "to": "main", "ti": fi})
        msgs = c.pump(0.5, every=hello)
        after = latest(msgs, "slots")["l"]["main"] if latest(msgs, "slots") else []
        report(bool(after) and after[fi - 1] == [item, count] and after[ti - 1] == 0, "and moving it back merges it", str(after[fi - 1:fi]))
        c.send({"t": "sort", "inv": "main"})
        msgs = c.pump(0.5, every=hello)
        report(not of_type(msgs, "msg"), "sort: sort_and_merge", "; ".join(m["text"] for m in of_type(msgs, "msg")))
    else:
        report(False, "need a stack of 2+ and two empty slots for the move checks", str(main[:10]))

    c.send({"t": "qb_set", "i": 1, "item": "iron-chest"})
    c.send({"t": "qb_sel", "i": 1})
    msgs = c.pump(0.5, every=hello)
    qb = latest(msgs, "qb")
    report(bool(qb) and qb["held"] == "iron-chest", "quickbar: set and select", str(qb and qb["l"][:3]))
    c.send({"t": "qb_set", "i": 1, "item": ""})
    c.send({"t": "qb_sel", "i": 0})

    mod_lua("storage.f3d.rdet_sig = nil storage.f3d.craftable_sig = nil")
    msgs = c.pump(1.0, every=hello)
    details = {r[0]: r for m in of_type(msgs, "rdet") for r in m["l"]}
    gear = details.get("iron-gear-wheel")
    report(bool(gear) and gear[8] == [["item", "iron-plate", 2]] and gear[9] == [["item", "iron-gear-wheel", 1]] and gear[3] != "",
           "rdet: recipe ingredients, products, energy, group and subgroup", f"{len(details)} recipes; {gear}")
    craftable = dict(map(tuple, latest(msgs, "craftable")["l"])) if latest(msgs, "craftable") else {}
    report(craftable.get("iron-gear-wheel", 0) == c.inv.get("iron-plate", 0) // 2,
           "craftable: get_craftable_count", f"gears {craftable.get('iron-gear-wheel')}, plates {c.inv.get('iron-plate')}")
    c.send({"t": "craft", "recipe": "iron-gear-wheel", "n": 3})
    msgs = c.pump(0.5, every=hello)
    cq = latest(msgs, "cq")
    report(bool(cq) and cq["l"] and cq["l"][0][1] == "iron-gear-wheel", "cq: crafting_queue and its progress", str(cq))
    if cq and cq["l"]:
        c.send({"t": "cancel_craft", "i": cq["l"][0][0], "n": 99})
        msgs = c.pump(0.5, every=hello)
        cq = latest(msgs, "cq")
        report(bool(cq) and not cq["l"], "cancel_craft empties the queue (cancel_crafting)", str(cq))

    # A new game has nothing researched and only trigger technologies (craft an item, build an
    # entity) available; science-pack research needs those first. The tree's states are checked
    # against the force, then, if fewer than two lab technologies are available, the trigger
    # technologies in front of the two nearest are researched (and undone afterwards).
    def tech_tree():
        mod_lua("storage.f3d.techs_dirty = true")
        msgs = c.pump(1.5, every=hello)
        return {r[0]: r for m in of_type(msgs, "techs") for r in m["l"]}

    techs = tech_tree()
    truth = mod_lua("""
local out = {}
for name, t in pairs(game.forces.player.technologies) do
  if t.researched then out[#out + 1] = name end
end
table.sort(out) rcon.print(table.concat(out, " "))
""".replace("\n", " ")).split()
    available = sorted(n for n, r in techs.items() if r[6] == 1)
    researched = sorted(n for n, r in techs.items() if r[6] == 2)
    report(len(techs) > 20 and bool(available) and set(researched) <= set(truth)
           and all(all(techs[p][6] == 2 for p in techs[n][2] if p in techs) for n in available),
           "techs: the technology tree with states (researched, prerequisites)",
           f"{len(techs)} technologies, {len(available)} available, {len(researched)} researched "
           f"(force: {len(truth)}); triggers: {sorted({r[7] for r in techs.values()} - {''})}")
    lab = sorted(n for n in available if techs[n][7] == "")
    unlocked = []
    if len(lab) < 2:
        out = mod_lua("""
local f = game.forces.player local techs = f.technologies
local function trigger(t) return t.prototype.research_trigger ~= nil end
local function missing(t, seen)
  for name, pre in pairs(t.prerequisites) do
    if not pre.researched and not seen[name] then seen[name] = pre missing(pre, seen) end
  end
  return seen
end
local picks = {}
for name, t in pairs(techs) do
  if t.enabled and not t.researched and not trigger(t) then
    local need, n, ok = missing(t, {}), 0, true
    for _, pre in pairs(need) do n = n + 1 ok = ok and trigger(pre) end
    if ok and n > 0 then picks[#picks + 1] = { name = name, n = n, need = need } end
  end
end
table.sort(picks, function(a, b) if a.n ~= b.n then return a.n < b.n end return a.name < b.name end)
local done = {}
for i = 1, math.min(2, #picks) do
  for name, pre in pairs(picks[i].need) do
    if not pre.researched then pre.research_recursive() end
  end
end
for name, t in pairs(techs) do
  if t.researched then done[#done + 1] = name end
end
table.sort(done) rcon.print(table.concat(done, " "))
""".replace("\n", " "))
        unlocked = sorted(set(out.split()) - set(truth))
        techs = tech_tree()
        lab = sorted(n for n, r in techs.items() if r[6] == 1 and r[7] == "")
        report(len(lab) >= 2 and all(techs.get(n, [0] * 7)[6] == 2 for n in unlocked),
               "techs are resent with new states when research finishes (on_research_finished)",
               f"researched by script: {unlocked}; lab technologies now available: {lab[:5]}")
    if len(lab) >= 2:
        first, second = lab[0], lab[1]
        c.send({"t": "research", "name": first})
        c.send({"t": "research", "name": second})
        # Waits for the `rs` that says so (up to 5 s): right after a resend of every technology the outbox may hold
        # the answer back past half a second (a full run's one failure).
        msgs = c.pump(5.0, until=lambda m: m.get("t") == "rs" and m.get("cur") == first and second in (m.get("q") or []),
                      every=hello)
        rs = latest(msgs, "rs")
        report(bool(rs) and rs["cur"] == first and second in rs["q"], "research: add_research starts one and queues the next", str(rs))
        c.send({"t": "research_cancel", "name": second})
        c.send({"t": "research_cancel", "name": first})
        msgs = c.pump(5.0, until=lambda m: m.get("t") == "rs" and second not in (m.get("q") or []) and m.get("cur") != first,
                      every=hello)
        rs = latest(msgs, "rs")
        report(bool(rs) and second not in rs["q"] and rs["cur"] != first,
               "research_cancel: research_queue and cancel_current_research", str(rs))
        # Finishing a technology by script raises on_research_finished: the notification and the
        # tree's resend. Undone afterwards (on_research_reversed).
        mod_lua(f'storage.f3d.puppet.force.technologies["{first}"].researched = true')
        msgs = c.pump(1.0, every=hello)
        done = [e for m in of_type(msgs, "rdone") for e in m["l"]]
        techs_now = {r[0]: r[6] for m in of_type(msgs, "techs") for r in m["l"]}
        report(done == [[first, 0]] and techs_now.get(first) == 2, "research finished: one rdone naming the tech, and the tree resent",
               f"{done[:3]}; state {techs_now.get(first)}")
        mod_lua(f'storage.f3d.puppet.force.technologies["{first}"].researched = false')
    if unlocked:
        mod_lua(f"for _, n in pairs({{ {', '.join(repr(n) for n in unlocked)} }}) do game.forces.player.technologies[n].researched = false end")

    # --- building: turning, fast-replace, rails, rolling stock, quality --------------------------------
    # Checks can_fast_replace, create_entity{fast_replace = true, spill = false} without a player
    # (and that it raises no destroy event, so the mod's own del is the only one), the rail item's
    # place_result / rails in 2.1, build_grid_size, LuaEntity.quality and quality in create_entity.
    mod_lua('local c = storage.f3d.puppet for _, s in pairs({{"transport-belt", 3}, {"fast-transport-belt", 2}, {"rail", 5}, {"locomotive", 1}}) do c.insert({name = s[1], count = s[2]}) end '
            'pcall(function() c.insert({name = "transport-belt", count = 1, quality = "uncommon"}) end)')
    report(clean_spot(c, hello), "move to a dry, empty spot for the building checks", str(c.me))
    px, py = round(c.me["x"] / 256), round(c.me["y"] / 256)
    built = []

    def build(item, dx, dy, d, **extra):
        msg = {"t": "build", "item": item, "x": (px + dx) * 256 + 128, "y": (py + dy) * 256 + 128, "d": d}
        msg.update(extra)
        c.send(msg)
        msgs = c.pump(0.6, every=hello)
        built.extend(m["e"] for m in of_type(msgs, "add"))
        return msgs

    belts = c.inv.get("transport-belt", 0)
    msgs = build("transport-belt", 3, 3, 4)
    first = of_type(msgs, "add")
    msgs = build("transport-belt", 3, 3, 8)
    upd = of_type(msgs, "upd")
    report(bool(first) and bool(upd) and upd[-1]["e"][4] == 8 and not of_type(msgs, "add"),
           "the same belt built over a belt turns it", "; ".join(m["text"] for m in of_type(msgs, "msg")))
    msgs = build("fast-transport-belt", 3, 3, 8)
    dels, adds = of_type(msgs, "del"), of_type(msgs, "add")
    c.pump(0.6, every=hello)
    report(bool(first) and len(dels) == 1 and dels[0]["u"] == first[0]["e"][0] and bool(adds)
           and c.inv.get("transport-belt", 0) == belts,
           "a fast belt fast-replaces it (one del, the old belt back in the inventory)",
           f"{len(dels)} del, adds {[a['e'][1] for a in adds]}, belts {belts} -> {c.inv.get('transport-belt', 0)}; "
           + "; ".join(m["text"] for m in of_type(msgs, "msg")))
    # A ten-tile track within reach (build_distance 10), long enough for a locomotive (six tiles).
    msgs = build("rail", 0, 6, 4)
    rails = [a["e"] for a in of_type(msgs, "add")]
    report(bool(rails) and c.protos.get(rails[0][1], ("",))[0] == "straight-rail" and rails[0][2] % 512 == 256 and rails[0][3] % 512 == 256,
           "rail builds a straight rail on the two-tile grid (odd centres)", f"{rails[:1]}; " + "; ".join(m["text"] for m in of_type(msgs, "msg")))
    for dx in (-4, -2, 2, 4):
        build("rail", dx, 6, 4)
    msgs = build("locomotive", 1, 6, 4)
    out = mod_lua(f"local l = storage.f3d.puppet.surface.find_entities_filtered({{ name = 'locomotive', position = {{ {px + 1}, {py + 6} }}, radius = 4 }})[1] "
                  "rcon.print(l and (l.unit_number .. ' ' .. l.position.x .. ' ' .. l.position.y .. ' ' .. l.orientation) or 'none')")
    report(out != "none" and float(out.split()[3]) in (0.25, 0.75), "rolling stock is put on the nearest rail, along it",
           "unit, x, y, orientation: " + out + "; " + "; ".join(m["text"] for m in of_type(msgs, "msg")))
    msgs = build("transport-belt", -3, 3, 0, q="uncommon")
    adds = [a["e"] for a in of_type(msgs, "add")]
    report(bool(adds) and len(adds[0]) == 6 and adds[0][5].get("q") == "uncommon",
           "a belt built from an uncommon stack is uncommon (create_entity quality, entity.quality)",
           f"{adds[:1]}; " + "; ".join(m["text"] for m in of_type(msgs, "msg")))
    units = [str(e[0]) for e in built if e[0]] + ([out.split()[0]] if out != "none" else [])
    destroy_units(units)

    # --- fluids, wires and power ----------------------------------------------------------------------
    # Two small poles 5 tiles apart (they connect themselves), a pipe with water written into its
    # fluid box, and an assembler with a recipe in reach of a pole but no power (nothing generates;
    # out of reach of every pole it would be pw 2, see below). Checks get_wire_connectors and
    # connections, fluid storage reads (2.1: get_fluid, get_fluid_capacity, fluids_count; there is
    # no LuaEntity.fluidbox), the no_power status, and gui status/pw.
    clean_spot(c, hello)
    px, py = round(c.me["x"] / 256), round(c.me["y"] / 256)
    out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local made = {{}}
local function at(name, dx, dy)
  local p = s.find_non_colliding_position(name, {{ {px} + dx, {py} + dy }}, 6, 1)
  local e = p and s.create_entity({{ name = name, position = p, force = c.force, raise_built = true }})
  if e then made[#made + 1] = e.unit_number end
  return e
end
local a, b = at("small-electric-pole", -4, -6), at("small-electric-pole", 1, -6)
local pipe = at("pipe", -2, -8)
if pipe then pipe.set_fluid(1, {{ name = "water", amount = 50 }}) end
local asm = at("assembling-machine-1", 3, -8)
if asm then asm.set_recipe("iron-gear-wheel") end
rcon.print(table.concat(made, " ") .. "|" .. (pipe and pipe.unit_number or 0) .. "|" .. (asm and asm.unit_number or 0)
  .. "|" .. (a and a.unit_number or 0) .. "|" .. (b and b.unit_number or 0))
""".replace("\n", " "))
    try:
        made_s, pipe_u, asm_u, pole_a, pole_b = out.split("|")
        made = made_s.split()
        pipe_u, asm_u, pole_a, pole_b = int(pipe_u), int(asm_u), int(pole_a), int(pole_b)
    except ValueError:
        report(False, "place poles, a pipe and an assembler for the fluid and power checks", out)
        made, pipe_u, asm_u, pole_a, pole_b = [], 0, 0, 0, 0
    if made:
        cx, cy = int(px // 32), int(py // 32)
        c.send({"t": "resync", "full": 0, "c": [[cx + dx, cy + dy] for dx in (-1, 0, 1) for dy in (-1, 0, 1)]})
        msgs = c.pump(2.5, every=hello)
        recs = {e[0]: e for m in of_type(msgs, "ents") for e in m["e"]}
        wires = [recs.get(u, [0] * 6)[5].get("w", []) if len(recs.get(u, [])) > 5 else [] for u in (pole_a, pole_b)]
        report(pole_b in wires[0] or pole_a in wires[1], "pole records carry copper wires (get_wire_connectors)", str(wires))
        fl = of_type(msgs, "fl")[-1]["l"] if of_type(msgs, "fl") else []
        boxes = [fl[i:i + 6] for i in range(0, len(fl), 6) if fl[i] == pipe_u]
        report(bool(boxes) and boxes[0][3] > 0, "fl: the pipe's water (get_fluid, get_fluid_capacity)", f"{boxes}")
        pw = of_type(msgs, "pw")[-1]["l"] if of_type(msgs, "pw") else []
        report(asm_u in pw[::2] and pw[pw.index(asm_u) + 1] == 0, "pw: an assembler without power (status no_power)", str(pw[:10]))
        c.send({"t": "open", "u": asm_u, "p": c.proto_id("assembling-machine-1"), "x": recs[asm_u][2], "y": recs[asm_u][3]} if asm_u in recs else {"t": "close"})
        g = [m for m in c.pump(1.0, every=hello) if m.get("t") == "gui" and m.get("u") == asm_u]
        report(bool(g) and g[-1].get("status") == "no_power" and g[-1].get("pw") == 0,
               "gui: status name and electric buffer (electric_buffer_size, energy)", str(g[-1:]))
        c.send({"t": "close"})
        destroy_units(made)

    # --- blueprints, ghosts and planners ---------------------------------------------------------------
    # A blueprint of two wooden chests is made in the character's inventory (set_blueprint_entities),
    # placed with `blueprint`, one ghost is filled in by building over it, then the chest is marked
    # for deconstruction and unmarked, and an upgrade planner (wooden -> iron chest) marks it.
    # Checks build_blueprint without a player, ghost records, ghost.revive, deconstruct_area on the
    # surface and on a planner stack, upgrade_area and the mark events.
    clean_spot(c, hello)
    px, py = round(c.me["x"] / 256), round(c.me["y"] / 256)
    out = mod_lua("""
local c = storage.f3d.puppet local inv = c.get_main_inventory()
c.insert({ name = "blueprint", count = 1 }) c.insert({ name = "deconstruction-planner", count = 1 })
c.insert({ name = "upgrade-planner", count = 1 }) c.insert({ name = "wooden-chest", count = 2 })
local slots = {}
for i = 1, #inv do
  local st = inv[i]
  if st.valid_for_read and not slots[st.name] then slots[st.name] = i end
end
local bp = inv[slots["blueprint"]]
bp.set_blueprint_entities({ { entity_number = 1, name = "wooden-chest", position = { 0, 0 } }, { entity_number = 2, name = "wooden-chest", position = { 2, 0 } } })
local up = inv[slots["upgrade-planner"]]
local ok = pcall(function()
  up.set_mapper(1, "from", { type = "entity", name = "wooden-chest" })
  up.set_mapper(1, "to", { type = "entity", name = "iron-chest" })
end)
rcon.print(slots["blueprint"] .. " " .. slots["deconstruction-planner"] .. " " .. slots["upgrade-planner"] .. " " .. tostring(ok))
""".replace("\n", " "))
    try:
        bp_slot, decon_slot, up_slot, mapper_ok = out.split()
        bp_slot, decon_slot, up_slot = int(bp_slot), int(decon_slot), int(up_slot)
    except ValueError:
        report(False, "make a blueprint and planners in the inventory", out)
        bp_slot = 0
    if bp_slot:
        gx, gy = px + 3, py + 5
        c.send({"t": "blueprint", "i": bp_slot, "x": gx * 256 + 128, "y": gy * 256 + 128, "d": 0})
        msgs = c.pump(0.8, every=hello)
        ghost_id = c.proto_id("entity-ghost")
        ghosts = [m["e"] for m in of_type(msgs, "add") if m["e"][1] == ghost_id]
        report(len(ghosts) == 2 and all(len(g) > 5 and g[5].get("gh") == c.proto_id("wooden-chest") for g in ghosts),
               "blueprint: build_blueprint without a player, ghosts sent with extra.gh", f"{ghosts}; " + "; ".join(m["text"] for m in of_type(msgs, "msg")))
        if ghosts:
            g = ghosts[0]
            c.send({"t": "build", "item": "wooden-chest", "x": g[2], "y": g[3], "d": 0})
            msgs = c.pump(0.8, every=hello)
            chests = [m["e"] for m in of_type(msgs, "add") if m["e"][1] == c.proto_id("wooden-chest")]
            report(any(d["u"] == g[0] for d in of_type(msgs, "del")) and bool(chests),
                   "building over a ghost revives it (ghost.revive)", "; ".join(m["text"] for m in of_type(msgs, "msg")))
            area = {"x1": (gx - 2) * 256, "y1": (gy - 1) * 256, "x2": (gx + 4) * 256, "y2": (gy + 2) * 256}
            if chests:
                chest = chests[0][0]
                c.send({"t": "decon", "i": 0, **area})
                msgs = c.pump(0.8, every=hello)
                upd = [m["e"] for m in of_type(msgs, "upd") if m["e"][0] == chest]
                report(bool(upd) and upd[-1][5].get("d") == 1, "decon: surface.deconstruct_area marks it; on_marked_for_deconstruction sends upd", str(upd[-1:]))
                c.send({"t": "decon", "i": decon_slot, "cancel": 1, **area})
                msgs = c.pump(0.8, every=hello)
                upd = [m["e"] for m in of_type(msgs, "upd") if m["e"][0] == chest]
                report(bool(upd) and "d" not in (upd[-1][5] if len(upd[-1]) > 5 else {}), "decon cancel with a planner stack (cancel_deconstruct_area)", str(upd[-1:]))
                c.send({"t": "upgrade", "i": up_slot, **area})
                msgs = c.pump(0.8, every=hello)
                upd = [m["e"] for m in of_type(msgs, "upd") if m["e"][0] == chest]
                report(bool(upd) and upd[-1][5].get("up") == c.proto_id("iron-chest"),
                       "upgrade: upgrade_area with a planner's mapping (set_mapper)", f"set_mapper ok: {mapper_ok}; {upd[-1:]}")
                c.send({"t": "upgrade", "i": up_slot, "cancel": 1, **area})
                c.pump(0.4, every=hello)
            units = [str(e[0]) for e in ghosts + chests if e[0]]
            destroy_units(units)

    # --- circuit network --------------------------------------------------------------------------
    # A constant combinator wired red into an arithmetic combinator: set_cb on both, then the
    # arithmetic one's screen must show the constant's signal. Checks get_control_behavior,
    # parameters, sections and filters, get_signals and the wire connector API (connect_to).
    px, py = round(c.me["x"] / 256), round(c.me["y"] / 256)
    out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface
local k = s.create_entity({{ name = "constant-combinator", position = {{ {px} + 2.5, {py} + 3.5 }}, force = c.force, raise_built = true }})
local a = s.create_entity({{ name = "arithmetic-combinator", position = {{ {px} + 4.5, {py} + 3.5 }}, direction = defines.direction.east, force = c.force, raise_built = true }})
local ok, err = pcall(function()
  local ids = defines.wire_connector_id
  k.get_wire_connector(ids.circuit_red, true).connect_to(a.get_wire_connector(ids.combinator_input_red, true))
end)
rcon.print((k and k.unit_number or 0) .. " " .. (a and a.unit_number or 0) .. " " .. tostring(ok) .. " " .. tostring(err))
""".replace("\n", " "))
    parts = out.split(" ", 3)
    const_u, arith_u = (int(parts[0]), int(parts[1])) if len(parts) >= 2 and parts[0].isdigit() else (0, 0)
    if const_u and arith_u:
        msgs = c.pump(0.6, every=hello)
        recs = {m["e"][0]: m["e"] for m in of_type(msgs, "add")}
        k_rec, a_rec = recs.get(const_u), recs.get(arith_u)
        if k_rec and a_rec:
            c.send({"t": "open", "u": const_u, "p": k_rec[1], "x": k_rec[2], "y": k_rec[3]})
            c.send({"t": "set_cb", "u": const_u, "cb": {"enabled": True, "signals": [["item", "iron-plate", 21]]}})
            g = [m for m in c.pump(1.0, every=hello) if m.get("t") == "gui" and m.get("u") == const_u]
            report(bool(g) and g[-1].get("cb", {}).get("signals") == [["item", "iron-plate", 21]],
                   "set_cb on a constant combinator (get_section, filters)", f"{g[-1:]}; " + out)
            c.send({"t": "open", "u": arith_u, "p": a_rec[1], "x": a_rec[2], "y": a_rec[3]})
            g = [m for m in c.pump(1.0, every=hello) if m.get("t") == "gui" and m.get("u") == arith_u]
            cb = g[-1].get("cb") if g else None
            report(isinstance(cb, dict), "an arithmetic combinator's parameters in gui", str(cb))
            if isinstance(cb, dict):
                cb = dict(cb, first_signal={"type": "item", "name": "iron-plate"}, second_constant=2, operation="*",
                          output_signal={"type": "item", "name": "iron-plate"})
                c.send({"t": "set_cb", "u": arith_u, "cb": cb})
            g = [m for m in c.pump(1.0, every=hello) if m.get("t") == "gui" and m.get("u") == arith_u]
            report(bool(g) and g[-1].get("cb", {}).get("operation") == "*" and ["item", "iron-plate", 21] in g[-1].get("sig", {}).get("r", []),
                   "set_cb writes parameters; sig shows the red network (get_signals)", f"{g[-1:]}; " + "; ".join(m["text"] for m in of_type(msgs, "msg")))
            c.send({"t": "close"})
        destroy_units([const_u, arith_u])
    else:
        report(False, "place two combinators for the circuit checks", out)

    # --- map --------------------------------------------------------------------------------------
    # A chart of the character's chunk and its east neighbour, then a tag added and removed over
    # the protocol and one added from the game. Checks is_chunk_charted, get_tile, map colours,
    # bounding_box, find_chart_tags, add_chart_tag, tag.destroy and the chart tag events.
    cx, cy = c.me["x"] // (256 * 32), c.me["y"] // (256 * 32)
    c.send({"t": "map", "cx1": cx, "cy1": cy, "cx2": cx + 1, "cy2": cy, "res": 4})
    msgs = c.pump(1.0, every=hello)
    charts = {(m["cx"], m["cy"]): m for m in of_type(msgs, "chart")}
    here = charts.get((cx, cy))
    errors = [m["text"] for m in of_type(msgs, "msg") if "Map error" in m["text"]]
    # A new map can put the character in a chunk of one terrain, so the east neighbour counts too.
    east = charts.get((cx + 1, cy)) or {}
    colours = {tuple(col) for m in (here or {}, east) for col in m.get("pal", [])}
    report(here is not None and here["n"] == 8 and len(colours) > 1 and not errors,
           "chart of the character's chunk: 8 x 8 pixels, more than one colour (with its neighbour)",
           f"{here and here.get('pal')}; {errors}")
    report((cx + 1, cy) in charts and of_type(msgs, "tags"), "the neighbour's chart and the tags follow",
           f"{sorted(charts)}")
    c.send({"t": "tag_add", "x": c.me["x"], "y": c.me["y"], "text": "live check", "icon": ["item", "iron-plate"]})
    tags = of_type(c.pump(0.5, every=hello), "tags")
    mine = [t for t in (tags[-1]["l"] if tags else []) if t[3] == "live check"]
    report(bool(mine) and mine[0][4:] == ["item", "iron-plate"], "tag_add puts a tag on the map (add_chart_tag)", str(tags[-1:]))
    if mine:
        c.send({"t": "tag_del", "id": mine[0][0]})
        tags = of_type(c.pump(0.5, every=hello), "tags")
        report(bool(tags) and not any(t[0] == mine[0][0] for t in tags[-1]["l"]), "tag_del removes it (destroy)", str(tags[-1:]))
    mod_lua(f"local c = storage.f3d.puppet c.force.add_chart_tag(c.surface, {{ position = c.position, text = 'from the game' }})")
    tags = of_type(c.pump(0.5, every=hello), "tags")
    game_tag = [t for t in (tags[-1]["l"] if tags else []) if t[3] == "from the game"]
    report(bool(game_tag), "a tag added in the game is sent (on_chart_tag_added)", str(tags[-1:]))
    mod_lua("local c = storage.f3d.puppet for _, t in pairs(c.force.find_chart_tags(c.surface)) do if t.text == 'from the game' then t.destroy() end end")
    c.pump(0.3, every=hello)

    # --- network data -----------------------------------------------------------------------------
    # Two pipes in a line (extra.pc from get_fluid_box_pipe_connections, the first one updated when
    # the second joins it), a lamp with no pole (pw 2: not_plugged_in_electric_network), a heat pipe
    # at 600 degrees (ht: temperature), and two poles wired by script after they were built (no
    # event; the bridge's half-second wire check sends both records).
    out = mod_lua("""
local c = storage.f3d.puppet local s = c.surface local x = math.floor(c.position.x) local y = math.floor(c.position.y)
storage.f3d_live_net = {}
local function mk(name, dx, dy) local e = s.create_entity({ name = name, position = { x + dx + 0.5, y + dy + 0.5 }, force = c.force, raise_built = true }) if e then table.insert(storage.f3d_live_net, e) end return e end
local a = mk("pipe", -4, 4) local b = mk("pipe", -3, 4)
local lamp = mk("small-lamp", -6, -4)
local heat = mk("heat-pipe", -4, 6) if heat then heat.temperature = 600 end
local pa = mk("small-electric-pole", 3, 6) local pb = mk("small-electric-pole", 7, 6)
if pa and pb then pa.get_wire_connector(defines.wire_connector_id.pole_copper, true).disconnect_from(pb.get_wire_connector(defines.wire_connector_id.pole_copper, true)) end
local u = function(e) return e and e.unit_number or 0 end
rcon.print(u(a) .. " " .. u(b) .. " " .. u(lamp) .. " " .. u(heat) .. " " .. u(pa) .. " " .. u(pb) .. " " .. tostring(lamp and lamp.is_connected_to_electric_network()))
""".replace("\n", " "))
    parts = out.split()
    if len(parts) == 7 and all(p.isdigit() and int(p) > 0 for p in parts[:6]):
        pipe_a, pipe_b, lamp_u, heat_u, pole_a, pole_b = (int(v) for v in parts[:6])
        msgs = c.pump(1.3, every=hello)
        recs = {}
        for m in msgs:
            if m.get("t") in ("add", "upd"):
                recs[m["e"][0]] = m["e"]
        report(recs.get(pipe_a, [0] * 6)[5:] == [{"pc": 2}] and recs.get(pipe_b, [0] * 6)[5:] == [{"pc": 8}],
               "pipes say which sides connect (extra.pc), and a pipe is updated when another joins it",
               f"{recs.get(pipe_a)} {recs.get(pipe_b)}")
        pw = [v for m in of_type(msgs, "pw") for v in m["l"]]
        state = dict(zip(pw[::2], pw[1::2])).get(lamp_u)
        report(state == 2 or parts[6] == "true", "pw: 2 for a lamp not connected to any pole",
               f"state {state}, connected {parts[6]}")
        ht = [v for m in of_type(msgs, "ht") for v in m["l"]]
        report(dict(zip(ht[::2], ht[1::2])).get(heat_u) == 600, "ht: a heat pipe's temperature", str(ht[:8]))
        # A script's wire raises no event: the bridge looks at the focus square in 8 strips, one every
        # 30 ticks (tracker.lua wire_strips), so it sees each wire within 4 s, measured from the wires
        # it last sent. The poles wired themselves as they were built, then the script cut them: first
        # the client's view of both (their last add or upd) is waited for to show the cut, then the
        # wire goes back and both must be updated. Each wait up to 6 s; a fixed 0.8 s passed only when
        # the poles' strip happened to come next, and wiring them back before the bridge had looked
        # left nothing to send.
        view = {}

        def note(ms):
            for m in ms:
                if m.get("t") in ("add", "upd") and m["e"][0] in (pole_a, pole_b):
                    view[m["e"][0]] = (m["e"][5:] or [{}])[0].get("w", [])

        def wait_for(cond):
            until = time.time() + 6.0
            while time.time() < until and not cond():
                note(c.pump(0.5, every=hello))
            return cond()
        note(msgs)
        cut = wait_for(lambda: pole_a in view and pole_b in view and pole_b not in view[pole_a] and pole_a not in view[pole_b])
        cut_view = dict(view)
        view.clear()
        # By the entities kept in storage: get_entity_by_unit_number doesn't find poles.
        mod_lua(f"local by = {{}} for _, e in pairs(storage.f3d_live_net) do if e.valid then by[e.unit_number] = e end end "
                f"local a, b = by[{pole_a}], by[{pole_b}] "
                "rcon.print(tostring(a.get_wire_connector(defines.wire_connector_id.pole_copper, true).connect_to("
                "b.get_wire_connector(defines.wire_connector_id.pole_copper, true))))")
        wired = wait_for(lambda: pole_b in view.get(pole_a, []) and pole_a in view.get(pole_b, []))
        report(cut and wired, "a wire cut and added again by script between two existing poles updates both within the "
               "bridge's look for wires (4 s)", f"cut {cut_view}, then {view}")
    else:
        report(False, "place pipes, a lamp, a heat pipe and poles for the network data checks", out)
    mod_lua("for _, e in pairs(storage.f3d_live_net or {}) do if e.valid then e.destroy() end end storage.f3d_live_net = nil")
    c.pump(0.3, every=hello)

    # --- logistics --------------------------------------------------------------------------------
    # A powered roboport with five logistic robots, a storage chest holding 50 iron plates and a
    # requester chest next to the character. Checks find_logistic_network_by_position (`ln`), the
    # chests' screens (logistic_mode, get_logistic_sections, get_filter / set_filter,
    # logistic_network: robot counts, get_contents), the roboport's inventories, the character's
    # requester point (`clog`, set_char_requests; it only exists with the force's
    # character_logistic_requests, turned on here) and a robot carrying plates (`rc`, robot_cargo).
    out = mod_lua("""
local c = storage.f3d.puppet local s = c.surface local x = math.floor(c.position.x) local y = math.floor(c.position.y)
storage.f3d_live_logi = {}
storage.f3d_live_charlogi = c.force.character_logistic_requests
c.force.character_logistic_requests = true
local function mk(name, dx, dy) local e = s.create_entity({ name = name, position = { x + dx, y + dy }, force = c.force, raise_built = true }) if e then table.insert(storage.f3d_live_logi, e) end return e end
local port = mk("roboport", -8, -6)
local eei = mk("electric-energy-interface", -12, -1)
local sub = mk("substation", -8, -1)
local req = mk("requester-chest", -2.5, -3.5)
local sto = mk("storage-chest", -4.5, -3.5)
if port then port.get_inventory(defines.inventory.roboport_robot).insert({ name = "logistic-robot", count = 5 }) end
if sto then sto.insert({ name = "iron-plate", count = 50 }) end
local u = function(e) return e and e.unit_number or 0 end
local p = function(e) return e and (e.position.x .. " " .. e.position.y) or "0 0" end
rcon.print(u(port) .. " " .. u(req) .. " " .. u(sto) .. " " .. p(port) .. " " .. p(req) .. " " .. p(sto))
""".replace("\n", " "))
    parts = out.split()
    if len(parts) == 9 and all(v.isdigit() and int(v) > 0 for v in parts[:3]):
        port_u, req_u, sto_u = (int(v) for v in parts[:3])
        port_xy, req_xy, sto_xy = ((round(float(parts[i]) * 256), round(float(parts[i + 1]) * 256)) for i in (3, 5, 7))
        msgs = c.pump(1.3, every=hello)
        ln = of_type(msgs, "ln")
        report(bool(ln) and ln[-1]["id"] > 0 and ln[-1]["log"][1] >= 5, "ln: the network the character stands in, with its robots", str(ln[-1:]))
        # Before anything is requested, while the robots still sit in the roboport and all 50
        # plates are in the storage chest; once the requester asks, robots fly off with them.
        c.send({"t": "open", "u": sto_u, "p": c.proto_id("storage-chest"), "x": sto_xy[0], "y": sto_xy[1]})
        c.send({"t": "set_storage_filter", "u": sto_u, "item": "iron-plate"})
        g = [m for m in c.pump(0.6, every=hello) if m.get("t") == "gui" and m.get("u") == sto_u]
        lg = g[-1].get("lg", {}) if g else {}
        report(lg.get("filter") == "iron-plate", "a storage chest's filter (set_filter, get_filter)", str(g[-1:])[:400])
        report(["iron-plate", 50] in lg.get("net", {}).get("items", []), "its network's contents (get_contents)", str(lg.get("net"))[:400])
        c.send({"t": "set_storage_filter", "u": sto_u, "item": ""})
        c.send({"t": "open", "u": port_u, "p": c.proto_id("roboport"), "x": port_xy[0], "y": port_xy[1]})
        g = [m for m in c.pump(0.6, every=hello) if m.get("t") == "gui" and m.get("u") == port_u]
        report(bool(g) and g[-1]["kind"] == "roboport" and any(s and s[0] == "logistic-robot" for s in g[-1].get("slots", {}).get("robots", [])),
               "a roboport's screen shows its robots (roboport_robot)", str(g[-1:])[:400])
        c.send({"t": "open", "u": req_u, "p": c.proto_id("requester-chest"), "x": req_xy[0], "y": req_xy[1]})
        c.send({"t": "set_requests", "u": req_u, "l": [["iron-plate", 10, -1]]})
        g = [m for m in c.pump(0.6, every=hello) if m.get("t") == "gui" and m.get("u") == req_u]
        lg = g[-1].get("lg", {}) if g else {}
        report(lg.get("mode") == "requester" and lg.get("requests") == [["iron-plate", 10, -1]],
               "a requester chest's requests, set over the protocol (get_logistic_sections, section filters)", str(lg)[:400])
        c.send({"t": "close"})
        c.send({"t": "set_char_requests", "l": [["iron-gear-wheel", 20, -1]]})
        clog = of_type(c.pump(0.6, every=hello), "clog")
        report(bool(clog) and clog[-1]["l"] == [["iron-gear-wheel", 20, -1]], "the character's requests (get_requester_point)", str(clog[-1:]))
        c.send({"t": "set_char_requests", "l": []})
        msgs = c.pump(5.0, every=hello)
        rc = [v for m in of_type(msgs, "rc") for v in m["l"]]
        carried = {rc[i + 1] for i in range(0, len(rc), 3)}
        report(any(c.items.get(i) == "iron-plate" for i in carried),
               "rc: a robot carries plates from the storage chest to the requester (robot_cargo)", str(rc[:12]))
    else:
        report(False, "place a roboport and logistic chests for the logistics checks", out)
    mod_lua("for _, e in pairs(storage.f3d_live_logi or {}) do if e.valid then e.destroy() end end storage.f3d_live_logi = nil "
            "if storage.f3d_live_charlogi ~= nil then storage.f3d.puppet.force.character_logistic_requests = storage.f3d_live_charlogi end "
            "storage.f3d_live_charlogi = nil "
            "local c = storage.f3d.puppet for _, r in pairs(c.surface.find_entities_filtered({ type = 'logistic-robot', position = c.position, radius = 40 })) do r.destroy() end")
    c.pump(0.3, every=hello)

    # --- trains -----------------------------------------------------------------------------------
    # Rails east-west north of the character, a train stop beside them, a fuelled locomotive with a
    # cargo wagon behind it. Checks the stop's name in its record (backer_name, on_entity_renamed),
    # `tr` (LuaTrain state, speed, station, path_end_stop, carriages), the train screen (2.x
    # get_schedule: current, get_records, set_records, go_to_station; manual_mode; the cargo_wagon
    # inventory) and the stop screen (trains_limit read and written, nil for none; trains_count).
    home = mod_lua("local p = storage.f3d.puppet.position rcon.print(p.x .. ' ' .. p.y)").split()
    out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface
local x0 = 2 * math.floor(c.position.x / 2) + 1 local y0 = 2 * math.floor(c.position.y / 2) - 11
storage.f3d_live_train = {{}}
local function mk(spec) spec.force = c.force spec.raise_built = true local e = s.create_entity(spec) if e then table.insert(storage.f3d_live_train, e) end return e end
for i = -14, 14 do mk({{ name = "straight-rail", position = {{ x0 + 2 * i, y0 }}, direction = defines.direction.east }}) end
local stop = mk({{ name = "train-stop", position = {{ x0 + 14, y0 + 2 }}, direction = defines.direction.east }})
if stop then stop.backer_name = "F3D live" end
local loco = mk({{ name = "locomotive", position = {{ x0, y0 }}, direction = defines.direction.east }})
local wagon = mk({{ name = "cargo-wagon", position = {{ x0 - 7, y0 }}, direction = defines.direction.east }})
if loco then loco.get_fuel_inventory().insert({{ name = "coal", count = 20 }}) end
if wagon then wagon.get_inventory(defines.inventory.cargo_wagon).insert({{ name = "iron-plate", count = 50 }}) end
c.teleport({{ x0, y0 + 4 }})
local same = loco and wagon and loco.train.id == wagon.train.id
rcon.print((stop and stop.unit_number or 0) .. " " .. (loco and loco.unit_number or 0) .. " " .. (wagon and wagon.unit_number or 0) .. " " .. (same and 1 or 0)
  .. " " .. (loco and (loco.position.x .. " " .. loco.position.y) or "0 0") .. " " .. (wagon and (wagon.position.x .. " " .. wagon.position.y) or "0 0")
  .. " " .. (stop and (stop.position.x .. " " .. stop.position.y) or "0 0"))
""".replace("\n", " "))
    parts = out.split()
    if len(parts) == 10 and all(p.lstrip("-").replace(".", "", 1).isdigit() for p in parts) and int(parts[0]) and int(parts[1]) and int(parts[2]):
        stop_u, loco_u, wagon_u, coupled = (int(v) for v in parts[:4])
        lx, ly, wx, wy, sx, sy = (round(float(v) * 256) for v in parts[4:])
        report(coupled == 1, "a cargo wagon placed 7 tiles behind a locomotive joins its train", out)
        c.send({"t": "focus", "x": lx, "y": ly, "r": 48})
        msgs = c.pump(1.2, every=hello)
        recs = [m["e"] for m in msgs if m.get("t") in ("add", "upd") and m["e"][0] == stop_u]
        report(bool(recs) and len(recs[-1]) == 6 and recs[-1][5].get("n") == "F3D live",
               "a train stop's record carries its name, also after a rename by script (on_entity_renamed)", str(recs[-2:]))
        tr = [r for m in of_type(msgs, "tr") for r in m["l"] if loco_u in r[6]]
        report(bool(tr) and wagon_u in tr[-1][6], "tr lists the train with both carriages", str(tr[-1:]))
        c.send({"t": "open", "u": loco_u, "p": c.proto_id("locomotive"), "x": lx, "y": ly})
        g = [m for m in c.pump(0.6, every=hello) if m.get("t") == "gui" and m.get("u") == loco_u]
        info = g[-1].get("tr") if g else None
        report(isinstance(info, dict) and isinstance(info.get("sched"), dict), "a locomotive opens as a train with its schedule (get_schedule)", str(g[-1:]))
        # The wagon is opened while the train still stands where it was made: once the schedule
        # runs it leaves, and open looks for the wagon where the client says it is.
        c.send({"t": "open", "u": wagon_u, "p": c.proto_id("cargo-wagon"), "x": wx, "y": wy})
        g = [m for m in c.pump(0.6, every=hello) if m.get("t") == "gui" and m.get("u") == wagon_u]
        report(bool(g) and g[-1]["kind"] == "train" and g[-1].get("inv", {}).get("cargo") == [["iron-plate", 50]],
               "a cargo wagon's screen shows its cargo (defines.inventory.cargo_wagon)", str(g[-1:]))
        c.send({"t": "open", "u": loco_u, "p": c.proto_id("locomotive"), "x": lx, "y": ly})
        c.pump(0.3, every=hello)
        records = [{"station": "F3D live", "wait_conditions": [{"type": "time", "compare_type": "or", "ticks": 120}]}]
        c.send({"t": "set_schedule", "u": loco_u, "records": records})
        c.send({"t": "train_go", "u": loco_u, "i": 1})
        c.send({"t": "train_mode", "u": loco_u, "auto": 1})
        msgs = c.pump(2.0, every=hello)
        g = [m for m in msgs if m.get("t") == "gui" and m.get("u") == loco_u]
        sched = (g[-1].get("tr") or {}).get("sched", {}) if g else {}
        errors = [m["text"] for m in of_type(msgs, "msg")]
        report(bool(sched.get("records")) and sched["records"][0].get("station") == "F3D live" and not errors,
               "set_schedule and train_go (set_records, go_to_station)", f"{sched}; {errors}")
        state = (g[-1].get("tr") or {}).get("state") if g else None
        report(bool(g) and g[-1]["tr"]["manual"] == 0 and state in ("on_the_path", "arrive_station", "wait_station"),
               "train_mode 1 runs the schedule: the train leaves for the stop", f"state {state}; {g[-1:]}")
        # The stop is 14 tiles from the character, out of reach: stand beside it.
        mod_lua(f"storage.f3d.puppet.teleport({{ {sx / 256}, {sy / 256 + 3} }})")
        c.pump(0.3, every=hello)
        c.send({"t": "open", "u": stop_u, "p": c.proto_id("train-stop"), "x": sx, "y": sy})
        c.send({"t": "set_stop", "u": stop_u, "limit": 1})
        g = [m for m in c.pump(0.6, every=hello) if m.get("t") == "gui" and m.get("u") == stop_u]
        report(bool(g) and g[-1]["kind"] == "stop" and g[-1]["stop"]["name"] == "F3D live" and g[-1]["stop"]["limit"] == 1,
               "a train stop's screen; set_stop sets the trains limit", str(g[-1:]))
        c.send({"t": "set_stop", "u": stop_u, "limit": -1})
        g = [m for m in c.pump(0.6, every=hello) if m.get("t") == "gui" and m.get("u") == stop_u]
        report(bool(g) and g[-1]["stop"]["limit"] == -1, "limit -1 removes the limit (trains_limit = nil)", str(g[-1:]))
        c.send({"t": "close"})
    else:
        report(False, "place rails, a train stop, a locomotive and a cargo wagon for the train checks", out)
    mod_lua("for _, e in pairs(storage.f3d_live_train or {}) do if e.valid then e.destroy() end end storage.f3d_live_train = nil")
    if len(home) == 2:
        mod_lua(f"storage.f3d.puppet.teleport({{ {home[0]}, {home[1]} }})")
    c.send({"t": "focus", "x": c.me["x"], "y": c.me["y"], "r": 48})
    c.pump(0.3, every=hello)

    # --- machine screens ---------------------------------------------------------------------------
    # A chest, an assembler and a furnace next to the character, opened over the protocol. Checks
    # the inventory APIs (get_inventory with defines.inventory, get_output_inventory,
    # get_fuel_inventory, entity.insert), get_recipe / set_recipe, crafting_progress, the
    # prototype's crafting categories and can_reach_entity.
    def place(name, dy):
        out = mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface
local p = s.find_non_colliding_position("{name}", {{ c.position.x + 3, c.position.y + {dy} }}, 8, 1)
local e = p and s.create_entity({{ name = "{name}", position = p, force = c.force, raise_built = true }})
rcon.print(e and (e.unit_number .. " " .. e.position.x .. " " .. e.position.y) or "none")
""".replace("\n", " "))
        try:
            unit, x, y = out.split()
            return [int(unit), c.proto_id(name), round(float(x) * 256), round(float(y) * 256)]
        except ValueError:
            report(False, f"place a {name} for the screen checks", out)
            return None

    def screen_msgs(seconds, unit):
        return [m for m in c.pump(seconds, every=hello) if m.get("t") == "gui" and m.get("u") == unit]

    def open_cmd(rec):
        return {"t": "open", "u": rec[0], "p": rec[1], "x": rec[2], "y": rec[3]}

    mod_lua('local c = storage.f3d.puppet c.insert({name = "iron-plate", count = 20}) c.insert({name = "coal", count = 10}) c.insert({name = "iron-ore", count = 10})')
    chest, asm, furnace = place("wooden-chest", -3), place("assembling-machine-1", 0), place("stone-furnace", 4)
    if chest:
        c.send(open_cmd(chest))
        g = screen_msgs(1.2, chest[0])
        report(len(g) >= 2 and g[0].get("kind") == "container" and "chest" in g[0].get("inv", {}),
               "gui: an open chest is reported twice a second with its chest inventory", str(g[:1]))
        c.send({"t": "put", "u": chest[0], "item": "iron-plate", "n": 5})
        c.send({"t": "take", "u": chest[0], "inv": "chest", "item": "iron-plate", "n": 2})
        g = screen_msgs(1.0, chest[0])
        report(bool(g) and g[-1]["inv"].get("chest") == [["iron-plate", 3]], "put and take move items (entity.insert, inventory.remove)", str(g[-1:]))
        chest_slots = g[-1].get("slots", {}).get("chest", []) if g else []
        report(len(chest_slots) >= 16 and chest_slots[0] == ["iron-plate", 3], "gui.slots: the chest slot by slot", str(chest_slots[:3]))
        c.send({"t": "move", "from": "chest", "fi": 1, "to": "chest", "ti": 5, "u": chest[0]})
        g = screen_msgs(1.0, chest[0])
        chest_slots = g[-1].get("slots", {}).get("chest", []) if g else []
        report(len(chest_slots) >= 5 and chest_slots[4] == ["iron-plate", 3] and chest_slots[0] == 0,
               "move between an open chest's slots", str(chest_slots[:6]))
        mod_lua(f'for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = "wooden-chest", position = {{ {chest[2] / 256}, {chest[3] / 256} }} }})) do e.destroy() end')
        g = screen_msgs(1.0, chest[0])
        report(any(m.get("closed") is True for m in g), "a destroyed chest closes its screen", str(g[-1:]))
    if asm:
        c.send(open_cmd(asm))
        g = screen_msgs(1.0, asm[0])
        rl = g[0].get("rl", []) if g else []
        report(bool(g) and g[0].get("kind") == "crafter" and "iron-gear-wheel" in rl and "iron-plate" not in rl,
               "gui: assembler recipe list from crafting categories (no smelting)", f"{len(rl)} recipes, inventories {list(g[0]['inv']) if g else None}")
        c.send({"t": "set_recipe", "u": asm[0], "recipe": "iron-gear-wheel"})
        c.send({"t": "put", "u": asm[0], "item": "iron-plate", "n": 4})
        g = screen_msgs(1.0, asm[0])
        report(bool(g) and g[-1].get("recipe") == "iron-gear-wheel" and "pr" in g[-1] and g[-1]["inv"].get("input") == [["iron-plate", 4]],
               "set_recipe / get_recipe / crafting_progress, and plates go to the input", str(g[-1:]))
        before = c.inv.get("iron-plate", 0)
        c.send({"t": "set_recipe", "u": asm[0], "recipe": ""})
        g = screen_msgs(1.0, asm[0])
        report(bool(g) and "recipe" not in g[-1] and c.inv.get("iron-plate", 0) == before + 4,
               "clearing the recipe gives the plates back (set_recipe's return value)", f"{before} -> {c.inv.get('iron-plate', 0)}; {g[-1:]}")
    if furnace:
        c.send(open_cmd(furnace))
        c.send({"t": "put", "u": furnace[0], "item": "coal", "n": 2})
        c.send({"t": "put", "u": furnace[0], "item": "iron-ore", "n": 3})
        g = screen_msgs(5.0, furnace[0])
        inv = g[-1]["inv"] if g else {}
        report(inv.get("fuel") in ([["coal", 2]], [["coal", 1]]),
               "furnace: coal goes to the fuel inventory (get_fuel_inventory)", str(inv))
        report(bool(g) and (g[-1].get("recipe") == "iron-plate" or inv.get("output")),
               "furnace: smelting shows its recipe or output", str(g[-1:]))
    c.send({"t": "close"})
    mod_lua(f"""
local s = storage.f3d.puppet.surface
for _, rec in pairs({{ {{ "assembling-machine-1", {asm[2] / 256 if asm else 0}, {asm[3] / 256 if asm else 0} }}, {{ "stone-furnace", {furnace[2] / 256 if furnace else 0}, {furnace[3] / 256 if furnace else 0} }} }}) do
  for _, e in pairs(s.find_entities_filtered({{ name = rec[1], position = {{ rec[2], rec[3] }} }})) do e.destroy() end
end
""".replace("\n", " "))

    sizes = ", ".join(f"{t} {n}" for t, n in sorted(c.max_size.items(), key=lambda kv: -kv[1])[:4])
    print(f"     largest datagrams by type: {sizes} bytes")
    c.send({"t": "bye"})
    time.sleep(0.3)

    # --- server-side checks over RCON ----------------------------------------------------------
    empty = rcon.run("/sc rcon.print(helpers.table_to_json({}))").strip()
    report(empty in ("[]", "{}"), "helpers.table_to_json({}) is [] or {}", f"it is {empty}")

    got = []
    for size in (8192, 16384, 32768, 60000, 65507, 65508, 100000):
        c.pump(0.2)
        reply = mod_lua(f'local ok, err = pcall(helpers.send_udp, {CLIENT_PORT}, string.rep("x", {size}), 0) rcon.print(ok and "ok" or tostring(err))')
        msgs_raw = []
        end = time.time() + 0.5
        while time.time() < end:
            try:
                data, _ = c.sock.recvfrom(1 << 20)
                if data[:1] == b"x":
                    msgs_raw.append(len(data))
            except (socket.timeout, ConnectionResetError):
                pass
        got.append(f"{size}: send {reply[:60]}, received {msgs_raw or 'nothing'}")
    print("     send_udp sizes:\n       " + "\n       ".join(got))

    out = mod_lua(r"""
local world = package.loaded["__factorio-3d-bridge__/scripts/world.lua"]
local surface = game.get_surface(1)
local failed, tried, types = {}, 0, {}
local x = 2000
for name, proto in pairs(prototypes.entity) do
  if not types[proto.type] and proto.type ~= "character" then
    local ok, e = pcall(surface.create_entity, { name = name, position = { x, 2000 }, force = "player", create_build_effect_smoke = false })
    if ok and e and e.valid then
      types[proto.type] = true
      tried = tried + 1
      local ok2, err = pcall(world.record, e)
      if not ok2 then failed[#failed + 1] = name .. ": " .. tostring(err) end
      if e.valid then e.destroy() end
    end
    x = x + 12
  end
end
rcon.print(tried .. " types tried; " .. #failed .. " failed\n" .. table.concat(failed, "\n"))
""".replace("\n", " "))
    report(" 0 failed" in out, "world.record works for every entity type that can be created", out.replace("\n", " | ")[:400])

    out = mod_lua(r"""
local world = package.loaded["__factorio-3d-bridge__/scripts/world.lua"]
local registry = package.loaded["__factorio-3d-bridge__/scripts/registry.lua"]
local surface = game.get_surface(1)
local profiler = helpers.create_profiler()
local n = 0
for cy = -2, 2 do for cx = -2, 2 do
  local x0, y0 = cx * 32, cy * 32
  for y = y0, y0 + 31 do for x = x0, x0 + 31 do registry.tile_id(surface.get_tile(x, y).name) end end
  for _, e in pairs(surface.find_entities_filtered({ area = { { x0, y0 }, { x0 + 32, y0 + 32 } }, type = registry.excluded_types(), invert = true })) do
    world.record(e) n = n + 1
  end
end end
profiler.stop()
rcon.print({"", "25 chunks, ", tostring(n), " entities: ", profiler})
""".replace("\n", " "))
    print("     snapshot timing:", out)

    # --- cliffs --------------------------------------------------------------------------------
    check_cliffs(c, hello)

    # --- tiles, capsules, the rail planner, drag building ---------------------------------------
    check_build_tools(c, hello)

    # --- mining vehicles and wagons by unit number (issue #10) -------------------------------------
    check_mine_vehicles(c, hello)

    # --- Alt-mode's icons with the records, arrows' recipe fluids (issue #9) -----------------------
    check_alt(c, hello)

    # --- alerts without a player ---------------------------------------------------------------
    check_alerts(c, hello)

    # --- two clients on one server ---------------------------------------------------------------
    check_multi(c, hello)

    # --- remnants and linked belts -------------------------------------------------------------
    check_remnants(c, hello)

    # --- turrets and vehicle guns --------------------------------------------------------------
    check_turrets(c, hello)

    # --- signals, accumulators and power switches report their states ---------------------------
    check_states(c, hello)

    # --- repair packs (K13) ---------------------------------------------------------------------
    check_repair(c, hello)

    # --- vehicles: Ctrl+click into them, their guns while driving, repair packs (N2, N3, N4) -----
    check_vehicle_items(c, hello)

    # --- an underground pair over belts mines the belts between (M2) -----------------------------
    check_under_clear(c, hello)

    # --- the pipes and belts beside what the character mines get their new shapes (the owner's FUE5 pipe end) -----
    check_pipe_end(c, hello)

    # --- space platforms (Space Age) -----------------------------------------------------------
    check_platforms(c, hello)

    # --- the other planets (Space Age) ---------------------------------------------------------
    check_planets(c, hello)

    # --- Space Age's screens: silo launches, the hub, landing pad, collector, quality -----------
    check_space(c, hello)

    # --- riding a rocket up to a platform's hub and a cargo pod down ---------------------------
    check_ride(c, hello)

    # --- asteroid collectors' arms catching chunks ----------------------------------------------
    check_collectors(c, hello)

    # /f3d-selftest: the character API checks the bridge can run by itself (the same command a
    # single-player game, which has no RCON, runs from its console).
    out = rcon.run("/f3d-selftest")
    report("PASS" in out and "FAIL" not in out, "/f3d-selftest passes on the server", out.replace("\n", " | "))

    # The bridge's own cost: /f3d-profile, then /f3d-status lists a time per module after 10 s.
    # tools/busy_base.py does the same on a dense base.
    rcon.run("/f3d-profile")
    # The modules only run while a client is connected: keep saying hello.
    c.pump(11, every=hello)
    out = rcon.run("/f3d-status")
    rcon.run("/f3d-profile")
    report("per tick" in out, "/f3d-profile: per-module script time in /f3d-status (helpers.create_profiler)",
           out.replace("\n", " | ")[:600])

    # --- the client's console (without /cheat, which would research everything) -----------------
    check_console(c, hello)

    # --- the error barrier: a step and a handler made to fail, then forgotten --------------------
    check_barrier(c, hello)

    report_step_errors()
    print(f"\n{results.count(True)} passed, {results.count(False)} failed")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
