"""Shared UDP client, RCON helpers, and spot utilities for tools/live_check.py."""
from __future__ import annotations

import json
import pathlib
import socket
import sys
import time

REPO = pathlib.Path(__file__).resolve().parents[2]
TOOLS = REPO / "tools"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import protocol  # noqa: E402
import rcon  # noqa: E402

MOD = "__factorio-3d-bridge__"
FACTORIO_PORT, CLIENT_PORT = 34200, 34201
SECOND_CLIENT_PORT = 0
SERVER_LOG = None
GODOT = None
BINARY = False
SPOT_WHY = ""
WATCH_PENDING: list = []
results: list[bool] = []
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



def handshake(c):
    msgs = c.pump(6, until=lambda m: m.get("t") == "ready", every=(1.0, {"t": "hello", "v": 1, "sid": c.sid, "w": 0}))
    welcome = of_type(msgs, "welcome")
    report(bool(welcome) and bool(of_type(msgs, "ready")), "handshake: welcome, prototypes, ready")
    return welcome



def inv_count(item):
    return int(mod_lua(f"rcon.print(storage.f3d.puppet.get_main_inventory().get_item_count('{item}'))") or 0)

