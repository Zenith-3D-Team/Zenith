"""Binary messages (transport.lua's frames, docs/PROTOCOL.md "Binary frames") against JSON text.

    python3 tools/mod_tests/test_binary.py

Runs the bridge mod twice in fake_factorio.lua, one game for a client whose hello asks for JSON and
one for a client that asks for binary frames (`bin`), through the same scenario, and checks that both
decode (tools/protocol.py) to the same messages tick by tick. Then the binary side's own checks: the
datagrams' framing and `dg` numbering, 64-bit blocks for movers past 32 bits, the map setting off, a
part string.pack refuses going as JSON text.
"""

import json
import pathlib
import struct
import sys

from lupa import lua52

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import protocol  # noqa: E402

sys.stdout.reconfigure(errors="backslashreplace")
MOD = ROOT / "mod" / "factorio-3d-bridge"
FAKE = pathlib.Path(__file__).with_name("fake_factorio.lua")
CLIENT_PORT = 34201
MAX_DATAGRAM = 65507
HELLO = {"t": "hello", "v": 1, "sid": "s1", "w": 0, "z": 1, "b": 1, "bs": 1, "dq": 1, "lv": 1}

failures = []


def check(cond, what):
    if not cond:
        failures.append(what)
        print("FAIL:", what)


class Game:
    """One fake Factorio with the bridge loaded, as test_bridge.py sets it up."""

    def __init__(self):
        lua = self.lua = lua52.LuaRuntime(unpack_returned_tuples=True)

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

        def from_json(text):
            try:
                data = json.loads(text)
            except ValueError:
                return None
            return lua.table_from(data, recursive=True)

        g = self.g = lua.globals()
        g.F_to_json = lambda t: json.dumps(to_py(t), separators=(",", ":"))
        g.F_from_json = from_json
        lua.execute(FAKE.read_text())
        g.package.path = str(MOD / "?.lua") + ";" + g.package.path
        lua.execute((MOD / "control.lua").read_text())
        lua.execute('package.loaded["scripts.barrier"].rethrow = true')
        self.F = g.F
        self.raw = []  # every datagram sent, as bytes

    def spawn(self, name, x, y, **extra):
        return self.F.spawn(name, x, y, self.lua.table_from(extra, recursive=True))

    def send(self, msg):
        self.F.packet(json.dumps(msg), CLIENT_PORT)

    lax = False  # (a test feeding the mod numbers that aren't whole: its JSON isn't checked against protocol.py)

    def tick(self):
        """One tick: its datagrams' messages."""
        self.F.tick()
        out = []
        for item in self.F.take_sent().values():
            data = bytes.fromhex(item[2]) if item[3] else item[2].encode("utf-8")
            check(item[1] == CLIENT_PORT, f"sent to port {item[1]}")
            check(len(data) <= MAX_DATAGRAM, f"datagram of {len(data)} bytes")
            self.raw.append(data)
            msgs = protocol.split_datagram(data)
            for msg in msgs if not self.lax else []:
                for problem in protocol.problems(msg):
                    check(False, f"protocol: {problem}")
            out.append(msgs)
        return out


def world(game):
    game.spawn("assembling-machine-1", 10.5, 10.5, force="player")
    game.spawn("transport-belt", 4.5, 3.5, force="player", direction=4)
    game.spawn("car", 3.0, 3.0, force="player")
    game.spawn("rocket-silo-rocket", 4.5, -6.5, force="player")  # no unit number: an id past 2^40
    # Over MOVERS_PER_MESSAGE (200): more than one part, each more than one string.pack run.
    for i in range(230):
        game.spawn("small-biter", -10.0 + (i % 20) * 0.75, -8.0 + (i // 20) * 0.75, force="enemy")
    game.F.on_init()


def frames_of(data):
    at, out = 2, []
    while at + 6 <= len(data):
        kind, flags, length = struct.unpack_from("<BBI", data, at)
        out.append((kind, at, data[at + 6:at + 6 + length]))
        at += 6 + length
    return out


def normal(msgs):
    """A datagram's messages as both clients should see them: no `dg` lines, no welcome `bin`, mv's
    records whole (a `z` client's are differences within a part)."""
    out = []
    for m in msgs:
        m = dict(m)
        if m["t"] == "dg":
            continue
        if m["t"] == "welcome":
            m.pop("bin", None)
        if m["t"] == "mv" and m.pop("z", None) == 1:
            whole, prev = [], None
            for rec in m["l"]:
                rec = [v + prev[j] if j < 4 else v for j, v in enumerate(rec)] if prev else list(rec)
                whole.append(rec)
                prev = rec
            m["l"] = whole
        out.append(m)
    return out


# One game: two games' prototype ids differ (Lua seeds its string hashing per state, so pairs' order
# does too), so the movers are sent twice on each of their ticks, as JSON text (bin cleared for the
# call) and as binary frames, and the two must decode to the same messages.
binary = Game()
world(binary)
# (Wire version 1, step 1's: mv in binary, bs and bfar still JSON text in frames; version 2 is below.)
binary.send({**HELLO, "bin": 1})
binary.lua.execute("""
local movers = package.loaded["scripts.movers"]
for i = 1, 255 do
  local name, fn = debug.getupvalue(movers.tick, i)
  if name == "send_movers" then
    BOTH_ORIGINAL, BOTH_AT = fn, i
    debug.setupvalue(movers.tick, i, function(surface, s, every)
      local c = storage.f3d.client
      local bin = c.bin
      c.bin = nil
      fn(surface, s, every)
      c.bin = bin
      fn(surface, s, every)
    end)
    break
  end
end
assert(BOTH_ORIGINAL, "movers.tick reaches send_movers")
""")

ticks = mv_ticks = mv_parts = 0
for i in range(90):
    if i == 10:
        binary.send({"t": "sub", "o": [0, 0], "r": 1, "w": [[-1, -1, 3], [0, -1, 3], [1, -1, 3]]})
    at = len(binary.raw)
    binary.tick()
    ticks += 1
    sent = binary.raw[at:]
    as_text = [m for d in sent if d[:1] != bytes((protocol.WIRE_MAGIC,)) for m in normal(protocol.split_datagram(d))]
    as_bin = [m for d in sent if d[:1] == bytes((protocol.WIRE_MAGIC,)) for m in normal(protocol.split_datagram(d))]
    check(all(m["t"] == "mv" for m in as_text), f"tick {i}: only the movers' JSON pass is text: {sorted({m['t'] for m in as_text})}")
    as_bin = [m for m in as_bin if m["t"] == "mv"]
    if as_text or as_bin:
        mv_ticks += 1
        mv_parts += len(as_bin)
    if as_text != as_bin:
        check(False, f"tick {i}: mv as JSON and as binary differ: {json.dumps(as_text)[:300]} vs {json.dumps(as_bin)[:300]}")
        break
check(mv_ticks >= 30 and mv_parts >= 2 * mv_ticks, f"the movers went out in parts: {mv_parts} binary mv parts on {mv_ticks} ticks")
check(any(len(m["l"]) == 200 for d in binary.raw for m in protocol.split_datagram(d) if m["t"] == "mv"),
      "a full part of 200 movers decodes the same")
binary.lua.execute("debug.setupvalue(package.loaded['scripts.movers'].tick, BOTH_AT, BOTH_ORIGINAL)")

# The binary datagrams: 0xF3, the wire version, frames to the end, mv in binary (kind 16), a 64-bit
# block among them (the rocket's id), and the `dg` frame last, numbered without gaps, its b the bytes
# before it.
bins = [d for d in binary.raw if d[:1] == bytes((protocol.WIRE_MAGIC,))]
welcome = [m for d in binary.raw for m in protocol.split_datagram(d) if m["t"] == "welcome"]
check(welcome and welcome[0].get("bin") == 1, f"a hello asking bin 1 is answered bin 1: {welcome[:1]}")
check(bins and all(d[:2] == bytes((protocol.WIRE_MAGIC, 1)) for d in bins), "binary datagrams start 0xF3 01 (the version answered)")
check(not any(k in (protocol.KIND_BS, protocol.KIND_BFAR) for d in bins for k, _, _ in frames_of(d)),
      "a version 1 client gets bs and bfar as JSON text")


def frames(data):
    at, out = 2, []
    while at < len(data):
        kind, flags, length = struct.unpack_from("<BBI", data, at)
        out.append((kind, at, data[at + 6:at + 6 + length]))
        at += 6 + length
    return out


kinds, widths, numbers = set(), set(), []
for d in bins:
    fs = frames(d)
    kinds |= {k for k, _, _ in fs}
    widths |= {body[16] for k, _, body in fs if k == protocol.KIND_MV}
    last_kind, last_at, last = fs[-1]
    check(last_kind == protocol.KIND_DG, f"a binary datagram ends with its dg frame (kind {last_kind})")
    if last_kind == protocol.KIND_DG:
        n, _k, b = struct.unpack("<III", last)
        check(b == last_at, f"dg's b is the bytes before it: {b} vs {last_at}")
        numbers.append(n)
check(kinds == {protocol.KIND_JSON, protocol.KIND_DG, protocol.KIND_MV}, f"frames of JSON, dg and mv: {sorted(kinds)}")
check(widths == {4, 8}, f"mv blocks of 32-bit numbers, and 64-bit for the part holding the rocket: {sorted(widths)}")
# (The movers' JSON pass sends datagrams too: the numbering runs through both kinds.)
numbers = [m["n"] for d in binary.raw for m in protocol.split_datagram(d) if m["t"] == "dg"]
check(len(numbers) == len(binary.raw) and numbers == list(range(numbers[0], numbers[0] + len(numbers))),
      f"datagrams numbered without gaps, text and binary alike: {numbers[:8]}")

# Binary costs about the bytes JSON does (fixed width against delta-coded text): reported, not checked.
# The client's fixture (client/tests/fixtures/wire_frames.json, read by tests/bridge_fuzz_test.gd): a binary
# datagram made here by protocol.py and the messages its JSON gives, so wire_decode.gd is held to the same
# reading. --write-fixture writes it again after a format change.
FIXTURE = ROOT / "client" / "tests" / "fixtures" / "wire_frames.json"
fixture_msgs = [
    {"t": "sky", "k": 7, "d": 1, "n": 0},
    {"t": "mv", "k": 7, "part": 1, "parts": 2, "p": 2, "l": [[12, 3, -2560, 768], [13, 4, 1024, -77, 250], [99999, 5, 0, 0, 0]]},
    {"t": "mv", "k": 7, "part": 2, "parts": 2, "p": 2, "l": [[2 ** 40 + 5, 6, 300, 400], [-3, 6, 2 ** 31 - 1, -2 ** 31]]},
    {"t": "mv", "k": 7, "part": 1, "parts": 1, "l": []},
    {"t": "msg", "k": 7, "text": "Station ü 東"},
    # (Lane keys past 31 bits, split into unit and line on the wire; lm's next negative: leading out.)
    {"t": "bs", "k": 7, "part": 1, "parts": 2, "p": 6, "w": 1346, "fx": -5120, "fy": 2688, "fr": 160, "ld": 1,
     "lm": [2400000001, 1, 256, 8, -4096, 2628, -3968, 2628, -3840, 2628, 0, -1,
            929, 5, 256, 8, 1, 2, 3, 4, 5, 6, 13, -2400000001],
     "sl": [2400000001, 6, 2, 501, 3, 64, 1, 502, 3, 128, 4, 929, 6, 0], "ew": [929, 6, 501, 64], "sh": [930, 6],
     "pc": [929, 6, 1, 64, 64], "pu": [929, 501, 501], "dl": [931, 2400000008], "of": [116, 1],
     "qu": [501, "rare", 502, "epic"], "sx": [116, 0, 7, 501, 0, 502, 0, 116, 0, 7, 2 ** 33 + 1, 0, 502, 0]},
    {"t": "bs", "k": 7, "part": 2, "parts": 2, "p": 6, "w": 0, "fx": -5120, "fy": 2688, "fr": 160, "dl": [16]},
    {"t": "bfar", "k": 7, "cx": -3, "cy": 2, "l": [-768, 512, 4, 12, 0, -512, 512, 4, 12, 13], "c": [4, 0, 2, 1], "h": [2, 1, 1, 1]},
    {"t": "bfar", "k": 7, "cx": 5, "cy": 5, "l": [], "c": []},
    # (Wire version 3: reliable chunk, ents and st keep their r; ents' extras as the JSON tail, ids past 32 bits
    # in a 64-bit block; st's lc and ao absent when empty.)
    {"t": "chunk", "k": 7, "r": 12, "cx": -4, "cy": 3, "parts": 2, "rs": 1, "rv": 5, "n": 3, "tiles": [7, 1000, 9, 24]},
    {"t": "ents", "k": 7, "r": 13, "cx": -4, "cy": 3, "part": 1, "parts": 2,
     "e": [[118, 27, -30592, 25728, 4, {"r": [119], "ai": ["item", "iron-gear-wheel"], "q": "rare"}], [0, 3, -31000, 26000, 0]]},
    {"t": "ents", "k": 7, "r": 14, "cx": -4, "cy": 3, "part": 2, "parts": 2, "e": [[2 ** 33 + 1, 4, -30000, 25000, 12, {"d": 1}]]},
    {"t": "st", "k": 7, "r": 15, "l": [118, 1, 119, 0], "lc": [120, 16711680, 121, -1]},
    {"t": "st", "k": 7, "r": 16, "l": []},
    {"t": "ih", "k": 7, "part": 1, "parts": 1, "p": 3, "l": [118, -30500, 25800, 12, 122, -30400, 25800, 0]},
    {"t": "rb", "k": 7, "part": 1, "parts": 2, "p": 20, "sm": 1200, "snap": 1,
     "u": [42, 7, 7, -2560, 768, 2560, -512, 0, 0, 125, 552,
           2 ** 40 + 7, 8, 5, 1024, -256, 3072, 1024, -1024, 512, 375, 40],
     "g": [91, 2 ** 40 + 9]},
    {"t": "rb", "k": 7, "part": 2, "parts": 2, "p": 20, "sm": 1200, "u": []},
]
datagram = protocol.encode_datagram([protocol.encode_message(m) for m in fixture_msgs] + [
    protocol.encode_frame(protocol.KIND_DG, struct.pack("<III", 41, 7, 0))])
check(protocol.split_datagram(datagram)[:-1] == fixture_msgs, "the fixture's datagram decodes to its messages")
fixture = {"hex": datagram.hex(), "messages": fixture_msgs, "dg": 41}
if "--write-fixture" in sys.argv:
    FIXTURE.write_text(json.dumps(fixture, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
check(FIXTURE.exists() and json.loads(FIXTURE.read_text(encoding="utf-8")) == fixture,
      f"{FIXTURE.name} is what protocol.py makes (python tools/mod_tests/test_binary.py --write-fixture)")

text_mv = sum(len(json.dumps(m, separators=(",", ":"))) for d in binary.raw if d not in bins for m in protocol.split_datagram(d) if m["t"] == "mv")
bin_mv = sum(6 + len(body) for d in bins for k, _, body in frames(d) if k == protocol.KIND_MV)
print(f"mv over {ticks} ticks: {text_mv} bytes as delta-coded JSON, {bin_mv} as binary frames")

# A part string.pack refuses (a number out of range, not whole) goes as that part's JSON text: whole
# records, no z, the same movers.
transport = binary.g.package.loaded["scripts.transport"]
saved = transport.pack_message
binary.lua.execute('package.loaded["scripts.transport"].pack_message = function() error("integer overflow") end')
got = [m for _ in range(4) for d in binary.tick() for m in d]
transport.pack_message = saved
fallback = [m for m in got if m["t"] == "mv"]
check(fallback and all("z" not in m and m["l"] for m in fallback),
      f"a part string.pack refuses goes as JSON text, whole records: {json.dumps(fallback[:1])[:200]}")
plain = [m for _ in range(4) for d in binary.tick() for m in d if m["t"] == "mv"]
units = lambda msgs: sorted(rec[0] for m in msgs[-2:] for rec in m["l"])  # noqa: E731 (one update: its two parts)
check(plain and fallback and units(fallback) == units(plain), "... the same movers as in binary")

# The map setting off: the next hello gets JSON text again (the client reads both).
binary.lua.execute('settings.global["f3d-binary-messages"].value = false')
binary.send({**HELLO, "w": 1, "bin": 1})
binary.raw = []
for _ in range(4):
    binary.tick()
check(binary.raw and not any(d[:1] == bytes((protocol.WIRE_MAGIC,)) for d in binary.raw),
      "f3d-binary-messages off: the datagrams after the next hello are JSON text")
check(binary.g.storage.f3d.client.bin is None, "... and the client's bin is cleared")
binary.lua.execute('settings.global["f3d-binary-messages"].value = true')
binary.send({**HELLO, "w": 1, "bin": 1})
binary.raw = []
for _ in range(4):
    binary.tick()
check(binary.raw and all(d[:1] == bytes((protocol.WIRE_MAGIC,)) for d in binary.raw), "on again: binary frames again")

# A hello asking for a wire version past this bridge's gets the bridge's; junk gets JSON.
binary.send({**HELLO, "w": 1, "bin": 7})
binary.tick()
check(binary.g.storage.f3d.client.bin == protocol.WIRE_VERSION, "bin 7 is answered with the bridge's version")
for junk in ("x", -1, 0, None, [1]):
    binary.send({**HELLO, "w": 1, "bin": junk})
    binary.tick()
    check(binary.g.storage.f3d.client.bin is None, f"bin {junk!r}: JSON text")

# A client that doesn't ask: JSON text, and a welcome without bin.
binary.raw = []
binary.send({k: v for k, v in HELLO.items() if k != "sid"} | {"sid": "s2"})
for _ in range(4):
    binary.tick()
check(binary.raw and not any(d[:1] == bytes((protocol.WIRE_MAGIC,)) for d in binary.raw), "a client without bin gets JSON text")
check([m for d in binary.raw for m in protocol.split_datagram(d) if m["t"] == "welcome" and "bin" not in m],
      "... and a welcome without bin")

# Wire version 2: bs (kind 17) and bfar (kind 18). belt_sim's binary twin of part_text is fed the same
# ranges, so each binary part is made a second time as text (part_text) and a third time from the lists
# turned into text (as a JSON client's lists are: string.pack reads numeric text as numbers): the text
# must decode to what the binary does, and both binaries be the same bytes.
belts = Game()
bx, by = -40, -24  # (a square round negative coordinates: fx, fy are signed)
lane_belts = [belts.spawn("transport-belt", bx + 0.5 + k, by + 0.5, force="player", direction=4) for k in range(6)]
for a, b in zip(lane_belts, lane_belts[1:]):
    belts.F.link_belts(a, b)
for k, e in enumerate(lane_belts):
    for j in range(3):
        belts.F.put_on_belt(e, 1 + j % 2, "iron-plate", 0.125 + 0.25 * j, 9000 + 4 * k + j)
belts.F.put_on_belt(lane_belts[2], 2, "iron-plate", 0.875, 9100, None, "rare")
s_in = belts.spawn("underground-belt", bx + 0.5, by + 4.5, force="player", direction=4, type="input")
s_out = belts.spawn("underground-belt", bx + 4.5, by + 4.5, force="player", direction=4, type="output")
belts.F.pair_undergrounds(s_in, s_out)
belts.spawn("splitter", bx + 3, by + 8.5, force="player", direction=4)
far_belt = belts.spawn("transport-belt", bx + 100.5, by + 0.5, force="player", direction=4)
belts.F.put_on_belt(far_belt, 1, "copper-plate", 0.5, 9200)
belts.F.on_init()
belts.lua.execute("""
local bs = package.loaded["scripts.belt_sim"]
local function up(fn, name)
  for i = 1, 255 do
    local n, v = debug.getupvalue(fn, i)
    if not n then break end
    if n == name then return v, i end
  end
end
local spool_step = up(bs.tick, "spool_step")
local part_bin, at = up(spool_step, "part_bin")
local part_text = up(spool_step, "part_text")
assert(part_bin and part_text, "spool_step reaches part_bin and part_text")
BS_TWINS = {}
debug.setupvalue(spool_step, at, function(sc, k, number, part, width)
  local body = part_bin(sc, k, number, part, width)
  local head = ',"parts":' .. sc[1] .. ',"p":' .. sc[2] .. ',"w":' .. sc[3] .. ',"fx":' .. sc[4] .. ',"fy":' .. sc[5]
    .. ',"fr":' .. sc[6] .. (sc[7] == 1 and ',"ld":1' or "")
  local copies, as_text = {}, {}
  for field, ranges in pairs(part) do
    local r2 = {}
    for r = 1, #ranges, 3 do
      local list = ranges[r]
      local c = copies[list]
      if not c then
        c = {}
        for i, v in ipairs(list) do
          c[i] = type(v) == "number" and tostring(v) or v
        end
        copies[list] = c
      end
      r2[r], r2[r + 1], r2[r + 2] = c, ranges[r + 1], ranges[r + 2]
    end
    as_text[field] = r2
  end
  BS_TWINS[#BS_TWINS + 1] = { '{"t":"bs","k":' .. k .. part_text(head, number, part) .. "}", part_bin(sc, k, number, as_text, width) == body, width }
  return body
end)
""")
belts.send({**HELLO, "bin": 2})
belts.send({"t": "focus", "x": bx * 256, "y": by * 256, "r": 48})
belts.send({"t": "bfar", "r": 200, "n": 16, "m": 0})
belts.send({"t": "sub", "c": [[1, -1], [-2, -1]]})  # (bfar reads subscribed chunks)
for i in range(240):
    if i == 120:
        # (An item id past 32 bits: its lane's part goes 64-bit.)
        belts.F.put_on_belt(lane_belts[4], 2, "iron-plate", 0.875, 2 ** 33 + 5)
        belts.send({"t": "bre", "l": [int(lane_belts[4].unit_number) * 8 + 2]})
    belts.tick()
got_bs, got_widths, got_far = [], set(), []
for d in belts.raw:
    if d[:1] != bytes((protocol.WIRE_MAGIC,)):
        continue
    check(d[1] == 2, f"a version 2 client's datagrams say version 2: {d[1]}")
    for kind, _, body in frames_of(d):
        if kind == protocol.KIND_BS:
            got_bs.append(protocol.decode_frames(protocol.encode_datagram([protocol.encode_frame(kind, body)]))[0])
            got_widths.add(body[36])
        elif kind == protocol.KIND_BFAR:
            got_far.append(protocol.decode_frames(protocol.encode_datagram([protocol.encode_frame(kind, body)]))[0])
        elif kind == protocol.KIND_JSON:
            check(json.loads(body).get("t") not in ("bs", "bfar"), "bs and bfar come only as binary frames")
twins = [belts.lua.eval(f"BS_TWINS[{i}]") for i in range(1, int(belts.lua.eval("#BS_TWINS")) + 1)]
check(len(twins) == len(got_bs) and len(got_bs) >= 20, f"bs parts sent in binary: {len(got_bs)} ({len(twins)} twins)")
same = [json.loads(t[1]) == m for t, m in zip(twins, got_bs)]
check(all(same), f"bs: each binary part decodes to its text twin: first differing at {same.index(False) if False in same else -1}")
check(all(t[2] for t in twins), "bs: lists of numbers and of their text pack to the same bytes")
check(got_widths == {4, 8}, f"bs parts of 32-bit numbers, and 64-bit for the part holding an id past 32 bits: {sorted(got_widths)}")
fields = {f for m in got_bs for f in protocol.BS_FIELDS + ("qu",) if f in m}
check({"lm", "sl", "pc", "pu", "qu"} <= fields, f"the parts held lm, sl, pc, pu and qu: {sorted(fields)}")
nexts = [m["lm"][i + 11] for m in got_bs if "lm" in m for i in range(0, len(m["lm"]), 12)]
check(any(v < 0 for v in nexts) and any(v > 0 for v in nexts), f"lm's next, a key, negative too (leading out): {sorted(set(nexts))[:8]}")
check(got_bs and got_bs[0]["fx"] < 0 and got_bs[0]["fy"] < 0, f"fx, fy negative: {got_bs[0]['fx'] if got_bs else None}")
check(got_far and all(len(m["l"]) % 5 == 0 and len(m["c"]) * 5 == len(m["l"]) * 2 for m in got_far)
      and any(m["l"] for m in got_far), f"bfar in binary: {got_far[:1]}")
bs_bytes = sum(6 + len(b) for d in belts.raw if d[:1] == bytes((protocol.WIRE_MAGIC,)) for k, _, b in frames_of(d) if k == protocol.KIND_BS)
print(f"bs: {len(got_bs)} binary parts, {sum(len(t[1]) for t in twins)} bytes as JSON, {bs_bytes} as binary frames")

# Wire version 5: bs's crossing hints (sx, /f3d-bs crossings hints, the default) as a block after qu's text, only in
# a part that has some; a version 4 client's parts never carry the block (its decoder ends a part at qu's text).
# (A lane splitter: one side, lines 1-2 its inputs, 3-4 its outputs.)
def hinted_game(version):
    game = Game()
    spl = game.spawn("lane-splitter", 3.5, 8.5, force="player", direction=4)
    game.F.put_on_belt(spl, 1, "iron-plate", 0.25, 9300)
    game.F.put_on_belt(spl, 2, "copper-plate", 0.3, 9301)
    game.F.put_on_belt(spl, 3, "iron-plate", 0.2, 9302)
    game.F.on_init()
    game.send({**HELLO, "bin": version})
    game.send({"t": "focus", "x": 3 * 256, "y": 8 * 256, "r": 48})
    for i in range(120):
        if i == 60:
            game.F.put_on_belt(spl, 4, "copper-plate", 0.4, 9303)  # (as if an item crossed into half 1's output)
        game.tick()
    msgs = []
    for d in game.raw:
        if d[:1] != bytes((protocol.WIRE_MAGIC,)):
            continue
        check(d[1] == version, f"a version {version} client's datagrams say version {version}: {d[1]}")
        for kind, _, body in frames_of(d):
            if kind == protocol.KIND_BS:
                msgs.append(protocol.decode_frames(bytes((protocol.WIRE_MAGIC, d[1])) + protocol.encode_frame(kind, body))[0])
    return msgs, int(spl.unit_number)


v5_bs, v5_unit = hinted_game(5)
v5_sx = [m["sx"][i:i + 7] for m in v5_bs if "sx" in m for i in range(0, len(m["sx"]), 7)]
check(v5_bs and not [p for m in v5_bs for p in protocol.problems(m)], f"v5: bs parts with hints are valid: {[protocol.problems(m) for m in v5_bs][:2]}")
check(any(r[0] == v5_unit and r[1] == 0 and r[3] == 9302 and r[4] == 9303 and r[5] == 9300 and r[6] == 9301 for r in v5_sx),
      f"v5: a splitter side's hint in binary: unit, side, tick, the outputs' items, the inputs' fronts: {v5_sx[-3:]}")
check(any("sx" not in m for m in v5_bs), "v5: parts without hints end at qu's text as before")
v4_bs, _ = hinted_game(4)
check(v4_bs and not any("sx" in m for m in v4_bs), f"v4: no part carries the sx block ({len(v4_bs)} parts)")
try:
    for m in v5_bs:
        if "sx" in m:
            protocol.decode_frames(protocol.encode_datagram([protocol.encode_message(m, 5)], 4))
    v4_refuses = False
except ValueError:
    v4_refuses = True
check(v4_refuses, "a version 4 datagram whose bs part ends in an sx block is refused")
check(all(protocol.decode_frames(protocol.encode_datagram([protocol.encode_message(m, 4)], 4))[0] == {k: v for k, v in m.items() if k != "sx"}
          for m in v5_bs), "v5 parts written for version 4 read back without sx")

# Wire version 3: chunk snapshots (chunk, ents: kinds 19, 20), st (21), reliable, and ih (22). Each is made twice
# in one game: send_snapshot for the binary job, then again with the client's bin cleared (the text fallback the
# same job takes when its client no longer reads binary); transport.send_states and the hands' send_hands_bin
# likewise, JSON first. Twins must decode to the same messages (r apart: each copy takes its own).
v3 = Game()
v3.spawn("assembling-machine-1", 10.5, 10.5, force="player")
v3.spawn("inserter", 12.5, 2.5, force="player", direction=4)
v3.spawn("inserter", 14.5, 2.5, force="player", direction=8)
v3.spawn("transport-belt", 4.5, 3.5, force="player", direction=4)
v3.spawn("tree-01", 20.5, 20.5)
v3.spawn("wooden-chest", 6.5, 6.5, force="player")
v3.F.on_init()
v3.lua.execute("""
local function up(fn, name)
  for i = 1, 255 do
    local n, v = debug.getupvalue(fn, i)
    if not n then break end
    if n == name then return v, i end
  end
end
local world = package.loaded["scripts.world"]
local transport = package.loaded["scripts.transport"]
local inserters = package.loaded["scripts.inserters"]
local snapshot_step = up(world.tick, "snapshot_step")
if not snapshot_step then
  for i = 1, 255 do
    local n, v = debug.getupvalue(world.tick, i)
    if not n then break end
    if type(v) == "function" then
      snapshot_step = up(v, "snapshot_step")
      if snapshot_step then break end
    end
  end
end
assert(snapshot_step, "world.tick reaches snapshot_step")
local send_snapshot, at = up(snapshot_step, "send_snapshot")
assert(send_snapshot, "snapshot_step reaches send_snapshot")
debug.setupvalue(snapshot_step, at, function(job)
  -- binary first (the job's records stay tables), then the text fallback
  send_snapshot(job)
  local c = storage.f3d.client
  local bin = c.bin
  c.bin = nil
  send_snapshot(job)
  c.bin = bin
end)
local send_states = transport.send_states
transport.send_states = function(l, lc, ao)
  local c = storage.f3d.client
  local bin = c.bin
  c.bin = nil
  send_states(l, lc, ao)
  c.bin = bin
  send_states(l, lc, ao)
end
local hands, hat = up(inserters.tick, "send_hands_bin")
assert(hands, "inserters.tick reaches send_hands_bin")
debug.setupvalue(inserters.tick, hat, function(flat, period)
  transport.send_groups("ih", flat, 4, 300, ',"p":' .. period)
  return hands(flat, period)
end)
""")
v3.send({**HELLO, "bin": 3})
v3.send({"t": "focus", "x": 10 * 256, "y": 10 * 256, "r": 48})
v3.send({"t": "sub", "c": [[0, 0], [-1, 0], [0, -1]]})
for i in range(150):
    if i == 60:
        v3.spawn("assembling-machine-1", 16.5, 16.5, force="player")
    v3.tick()
V3_KINDS = {protocol.KIND_CHUNK: "chunk", protocol.KIND_ENTS: "ents", protocol.KIND_ST: "st", protocol.KIND_IH: "ih"}
got = {t: [] for t in V3_KINDS.values()}
json_twins = {t: [] for t in V3_KINDS.values()}
for d in v3.raw:
    if d[:1] != bytes((protocol.WIRE_MAGIC,)):
        check(False, "a version 3 client gets binary datagrams only")
        continue
    check(d[1] == 3, f"a version 3 client's datagrams say version 3: {d[1]}")
    for kind, at, body in frames_of(d):
        if kind in V3_KINDS:
            m = protocol.decode_frames(protocol.encode_datagram([protocol.encode_frame(kind, body, d[at + 1])]))[0]
            check(("r" in m) == (kind != protocol.KIND_IH), f"{V3_KINDS[kind]}: reliable as its JSON is ({'r' in m})")
            got[V3_KINDS[kind]].append(m)
        elif kind == protocol.KIND_JSON:
            m = json.loads(body)
            if m.get("t") in json_twins and not ("none" in m or "same" in m):
                json_twins[m["t"]].append(m)


def bare(m):
    m = {k: v for k, v in m.items() if k not in ("r", "z")}
    if m["t"] == "st":
        m["l"] = m.get("l") or []  # (an empty Lua table's JSON is {})
    return m


# (The text twins of ih are delta-coded for this z client: undone as protocol.encode_message does.)
json_twins["ih"] = [{**m, "l": protocol._undelta(m.get("l") or [], 4)} if m.get("z") == 1 else m for m in json_twins["ih"]]
for t in V3_KINDS.values():
    b, j = [bare(m) for m in got[t]], [bare(m) for m in json_twins[t]]
    check(b == j, f"{t}: binary and JSON twins decode the same ({len(b)} vs {len(j)}): "
          f"{json.dumps(b[:1])[:300]} vs {json.dumps(j[:1])[:300]}")
check(len(got["chunk"]) >= 3 and len(got["ents"]) >= 3, f"chunk snapshots in binary: {len(got['chunk'])} chunk, {len(got['ents'])} ents")
check(any(len(e) > 5 for m in got["ents"] for e in m["e"]), "ents: some records carry extras (the JSON tail)")
check(any(len(e) == 5 for m in got["ents"] for e in m["e"]), "ents: ... and some none")
check(got["st"], f"st in binary: {len(got['st'])}")
check(got["ih"] and any(m["l"] for m in got["ih"]), f"ih in binary: {len(got['ih'])} parts")
check(all(m.get("tiles") for m in got["chunk"]), "chunk: tiles' runs as a block")
v3_bin = sum(6 + len(b) for d in v3.raw for k, _, b in frames_of(d) if k in (protocol.KIND_CHUNK, protocol.KIND_ENTS))
v3_json = sum(len(json.dumps(m, separators=(",", ":"))) for t in ("chunk", "ents") for m in json_twins[t])
print(f"v3: {len(got['chunk'])} chunk, {len(got['ents'])} ents, {len(got['st'])} st, {len(got['ih'])} ih in binary; "
      f"chunk+ents {v3_bin} bytes as frames, {v3_json} as JSON")

# A pack refusing a number (a position not whole): that snapshot goes as JSON text.
v3.lua.execute("""
local world = package.loaded["scripts.world"]
ORIG_RECORD = world.record
world.record = function(e)
  local rec = ORIG_RECORD(e)
  if rec[1] ~= 0 then rec[3] = rec[3] + 0.5 end
  return rec
end
""")
at = len(v3.raw)
v3.lax = True
v3.send({"t": "resync", "full": 0, "c": [[0, 0]]})
for i in range(40):
    v3.tick()
v3.lax = False
v3.lua.execute("package.loaded['scripts.world'].record = ORIG_RECORD")
late = [m for d in v3.raw[at:] for m in protocol.split_datagram(d)]
check(any(m["t"] == "ents" for m in late) and not any(k == protocol.KIND_ENTS for d in v3.raw[at:] for k, _, _ in frames_of(d)),
      f"a snapshot string.pack refuses goes as JSON text: {sorted({m['t'] for m in late})}")

# A hello that drops the client to version 2 with binary messages waiting starts the stream over (a new
# welcome) rather than leave a gap in r.
v3.lua.execute("""
local transport = package.loaded["scripts.transport"]
transport.send_reliable_frame(transport.KIND_ST, "st", string.pack("<BI4BI4BI4", 4, 0, 4, 0, 4, 0), 3)
""")
at = len(v3.raw)
v3.send({**HELLO, "w": 1, "bin": 2})
v3.tick()
late = [m for d in v3.raw[at:] for m in protocol.split_datagram(d)]
check(any(m["t"] == "welcome" for m in late), f"bin 3 -> 2 with binary waiting: started over {sorted({m['t'] for m in late})}")
check(not any(k in V3_KINDS for d in v3.raw[at:] if d[:1] == bytes((protocol.WIRE_MAGIC,)) for k, _, _ in frames_of(d)),
      "... and no version 3 frame goes to it after")

# Wire version 4: rb (kind 23) binary vs JSON twin, and a bin 3 client gets rb as JSON text.
v4 = Game()
chest_a = v4.spawn("wooden-chest", 8.5, 4.5, force="player")
rb1 = v4.spawn("logistic-robot", 2.5, 2.5, force="player")
rb1.orientation = 0.25
rb1.robot_order_queue = v4.lua.table_from([{"type": v4.g.defines.robot_order_type.deliver, "target": chest_a}])
rb2 = v4.spawn("construction-robot", 5.5, 5.5, force="player")
v4.F.on_init()
v4.lua.execute("""
local robots = package.loaded["scripts.robots"]
local transport = package.loaded["scripts.transport"]
local send_rb, i = nil, 1
while true do
  local name, fn = debug.getupvalue(robots.tick, i)
  if not name then break end
  if name == "send_rb" then send_rb = fn; break end
  i = i + 1
end
assert(send_rb, "robots.tick reaches send_rb")
local orig = send_rb
debug.setupvalue(robots.tick, i, function(st, out_u, out_g, tick, period, sm, snap_only)
  local c = storage.f3d.client
  local bin = c.bin
  c.bin = nil
  local keep_snap = st.need_snap
  orig(st, out_u, out_g, tick, period, sm, snap_only)
  c.bin = bin
  st.need_snap = keep_snap
  orig(st, out_u, out_g, tick, period, sm, snap_only)
end)
""")
v4.send({**HELLO, "bin": 4, "rb": 1})
v4.send({"t": "focus", "x": 5 * 256, "y": 5 * 256, "r": 48})
rb_text, rb_bin = [], []
for _ in range(12):
    v4.tick()
for d in v4.raw:
    if d[:1] != bytes((protocol.WIRE_MAGIC,)):
        for m in protocol.split_datagram(d):
            if m.get("t") == "rb":
                rb_text.append(m)
    else:
        for k, _, body in frames_of(d):
            if k == protocol.KIND_RB:
                m = protocol.decode_frames(protocol.encode_datagram([protocol.encode_frame(k, body, 0)]))[0]
                rb_bin.append(m)
check(rb_text and rb_bin and rb_text == rb_bin,
      f"v4: rb binary (kind 23) and JSON decode the same ({len(rb_bin)} vs {len(rb_text)})")
check(any(m.get("u") for m in rb_bin), "v4: binary rb carried tracked robots")

v4.raw = []
v4.send({**HELLO, "w": 1, "bin": 3, "rb": 1})
rb1.energy = 0
for _ in range(22):
    v4.tick()
check(any(m.get("t") == "rb" for d in v4.raw for m in protocol.split_datagram(d))
      and not any(k == protocol.KIND_RB for d in v4.raw if d[:1] == bytes((protocol.WIRE_MAGIC,)) for k, _, _ in frames_of(d)),
      "v4: a bin 3 client gets rb as JSON text inside frames, never kind 23")

print(f"{ticks} ticks compared, {mv_parts} binary mv parts")
if failures:
    print(f"\n{len(failures)} check(s) failed")
    sys.exit(1)
print("binary: JSON and binary decode the same")
