"""Shared Lua 5.2 fake-Factorio harness for tools/mod_tests/test_bridge.py."""
from __future__ import annotations

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
passes = 0


def check(cond, what):
    global passes
    if cond:
        passes += 1
    else:
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

