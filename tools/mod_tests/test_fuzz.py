"""Throws malformed packets at the bridge mod (against fake_factorio.lua) and checks it survives.

    python3 tools/mod_tests/test_fuzz.py [--rounds N] [--seed S]

Every command handler gets fields of the wrong type, missing, huge, negative, deeply nested or
absurd; raw payloads come truncated, binary, empty or oversized; hellos, resyncs and subs arrive
out of order and duplicated. After each batch the game ticks, because a handler that stores
garbage in `storage` would crash the next on_tick, which no pcall protects. Afterwards a normal
client must still connect, walk and get chunks.

A handler error caught by session.on_packet (a "Bridge error" msg) is allowed but counted: it is
a bug in input checking, so the report lists them.
"""

import argparse
import json
import pathlib
import random
import re
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


def from_json(text):
    try:
        data = json.loads(text)
    except (ValueError, RecursionError):
        return None
    try:
        return lua.table_from(data, recursive=True) if isinstance(data, (dict, list)) else data
    except RecursionError:
        return None


g = lua.globals()
g.F_to_json = lambda t: json.dumps(to_py(t), separators=(",", ":"))
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

# Command names and the fields the mod reads, taken from its source so new commands are fuzzed too.
SESSION = (MOD / "scripts" / "session.lua").read_text()
COMMANDS = sorted(set(re.findall(r"handlers\.([a-z_0-9]+) =", SESSION)) | set(re.findall(r"function handlers\.([a-z_0-9]+)", SESSION)))
FIELDS = sorted({f for p in (MOD / "scripts").glob("*.lua") for f in re.findall(r"\b(?:cmd|msg)\.([a-z_0-9]+)", p.read_text())})

failures = []
bridge_errors = {}


def check(cond, what):
    if not cond:
        failures.append(what)
        print("FAIL:", what)


def junk(rng, depth=0):
    """A random JSON value, biased towards the shapes that break naive code."""
    choices = [
        lambda: None, lambda: True, lambda: 0, lambda: -1, lambda: 1, lambda: rng.randint(-2**53, 2**53),
        lambda: 1e308, lambda: -1e308, lambda: 0.5, lambda: rng.uniform(-1e6, 1e6), lambda: "",
        lambda: "x" * rng.choice([1, 100, 70000]), lambda: "\u0000￿퟿", lambda: rng.choice(COMMANDS),
        lambda: "iron-plate", lambda: "transport-belt", lambda: [], lambda: {},
    ]
    if depth < 4:
        choices += [
            lambda: [junk(rng, depth + 1) for _ in range(rng.randint(0, 5))],
            lambda: {rng.choice(FIELDS + ["1", "t"]): junk(rng, depth + 1) for _ in range(rng.randint(0, 4))},
            lambda: [[junk(rng, depth + 1), junk(rng, depth + 1)] for _ in range(rng.randint(0, 3))],
        ]
    return rng.choice(choices)()


def command(rng):
    msg = {"t": rng.choice(COMMANDS)}
    for f in rng.sample(FIELDS, rng.randint(0, min(8, len(FIELDS)))):
        msg[f] = junk(rng)
    return msg


def raw(rng):
    """A payload that isn't a well-formed command."""
    good = json.dumps(command(rng))
    return rng.choice([
        "", " ", "null", "[]", "1", '"t"', "{", '{"t":', good[: rng.randint(0, len(good))], good + "}}}",
        bytes(rng.getrandbits(8) for _ in range(rng.randint(1, 200))).decode("latin-1"),
        json.dumps({"t": junk(rng)}), json.dumps({"t": "walk", "d": "x" * 60000}),
        "[" * 5000 + "]" * 5000, json.dumps([command(rng)]),
    ])


def send(payload, port=CLIENT_PORT):
    try:
        F.packet(payload if isinstance(payload, str) else json.dumps(payload), port)
    except Exception as e:  # noqa: BLE001 - anything escaping on_packet would crash the game
        check(False, f"on_packet raised for {str(payload)[:200]!r}: {str(e).splitlines()[0][:300]}")


def tick(n, what):
    for _ in range(n):
        try:
            F.tick()
        except Exception as e:  # noqa: BLE001
            check(False, f"on_tick raised after {what}: {str(e).splitlines()[0][:300]}")
            return False
    return True


BINARY = {"datagrams": 0, "mv": 0, "v3": 0}  # binary datagrams seen, and with an mv frame (roughly)


def take():
    out = []
    for item in F.take_sent().values():
        # A fuzzed hello can ask for joined datagrams (`b`): several messages, a line each; or for
        # binary frames (`bin`), which fake_factorio hands over as hex.
        data = bytes.fromhex(item[2]) if item[3] else str(item[2])
        BINARY["datagrams"] += 1 if item[3] else 0
        BINARY["mv"] += 1 if item[3] and bytes((protocol.KIND_MV, 0)) in data else 0
        BINARY["v3"] += 1 if item[3] and bytes((protocol.KIND_ENTS, protocol.FLAG_RELIABLE)) in data else 0
        for msg in protocol.split_datagram(data):
            for problem in protocol.problems(msg):
                check(False, f"protocol after fuzzing: {problem}")
            out.append(msg)
    return out


def note_errors(msgs, cmd):
    for m in msgs:
        if m.get("t") == "msg" and str(m.get("text", "")).startswith("Bridge error"):
            bridge_errors.setdefault(cmd, set()).add(m["text"].split("\n")[0][:160])


# The second half of the rounds the client simulates belts (`bs`: belt_sim.lua instead of bi) and gets
# joined, numbered datagrams of binary frames (`b`, `dq`, `bin`: transport.lua).
BS = {"on": False}


def hello(sid="fuzz", w=1):
    msg = {"t": "hello", "v": 1, "sid": sid, "w": w, "bl": 1, "bs": 1 if BS["on"] else 0}
    if BS["on"]:
        msg.update({"b": 1, "dq": 1, "bin": protocol.WIRE_VERSION})
    send(msg)


def fuzz_ext(rng, rounds=600):
    """`ext` (link.lua) with garbage channels and data: nothing escapes, and only a good channel for a
    mod in the game, with data, raises the event other mods hear."""
    g.script.active_mods["zenith-link-test"] = "0.1.0"
    lua.execute("""
    FUZZ_EXT = {}
    F.companion_on(remote.call("zenith", "on_message"), function(e) table.insert(FUZZ_EXT, e) end)
    """)
    good_channels = ["zenith-link-test", "zenith-link-test/a", "zenith-link-test/" + "é" * 20]
    deep = "[" * 3000 + "]" * 3000
    sent_good = 0
    for i in range(rounds):
        if i % 50 == 0:
            hello()
            tick(1, "an ext round's hello")
            take()
        good = rng.random() < 0.4
        ch = rng.choice(good_channels) if good else rng.choice([
            junk(rng), "", "x" * 200, "zenith-link-test/" + "y" * 120, "zenith link test", "/zenith-link-test",
            "not-loaded", "zenith-link-test/\n", 7, None, ["zenith-link-test"], {"ch": "zenith-link-test"}])
        d = rng.choice([junk(rng), junk(rng), None, "z" * rng.choice([10, 3000, 5000, 70000]), {"a": [1, 2, {"b": None}]}])
        if rng.random() < 0.05:
            payload = '{"t":"ext","ch":' + json.dumps(ch) + ',"d":' + deep + "}"
        else:
            payload = json.dumps({"t": "ext", "ch": ch, "d": d} if d is not None or rng.random() < 0.5 else {"t": "ext", "ch": ch})
        send(payload)
        if good and d is not None and len(payload.encode("utf-8")) <= 4096:
            sent_good += 1
        if not tick(rng.choice([0, 0, 1, 7]) or 0, "an ext"):
            return
        note_errors(take(), "ext")
    tick(1, "the last ext")
    raised = [to_py(e) for e in g.FUZZ_EXT.values()]
    bad = [e for e in raised if not protocol.ext_channel_ok(e.get("channel")) or e.get("data") is None
           or not str(e["channel"]).startswith("zenith-link-test")]
    check(not bad, f"ext fuzz: only good channels with data raise the event: {bad[:3]}")
    check(0 < len(raised) <= sent_good, f"ext fuzz: {len(raised)} raised of {sent_good} good ones sent (the caps drop some)")
    print(f"ext fuzz: {rounds} messages, {sent_good} good, {len(raised)} raised")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--rounds", type=int, default=3000)
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()
    rng = random.Random(args.seed)

    F.spawn("wooden-chest", 2.5, 2.5, lua.table_from({"force": "player"}))
    F.spawn("assembling-machine-1", 6.5, 6.5, lua.table_from({"force": "player"}))
    F.spawn("transport-belt", 3.5, 6.5, lua.table_from({"force": "player"}))
    F.on_init()
    hello("fuzz", 0)
    tick(3, "the first hello")
    send({"t": "sub", "c": [[0, 0], [-1, 0], [0, -1], [-1, -1]]})
    tick(5, "the first sub")
    take()

    for i in range(args.rounds):
        if i == args.rounds // 2:
            BS["on"] = True
            hello()
        kind = rng.random()
        if kind < 0.75:
            msg = command(rng)
            send(msg)
            what = msg["t"]
        elif kind < 0.9:
            send(raw(rng))
            what = "a raw payload"
        else:
            # Out of order and duplicated: hellos with other sessions or ports, resyncs, subs.
            pick = rng.choice(["hello", "resync", "sub", "dup"])
            if pick == "hello":
                send({"t": "hello", "v": junk(rng), "sid": rng.choice(["fuzz", "other", junk(rng)]), "w": junk(rng), "bin": junk(rng)},
                     rng.choice([CLIENT_PORT, CLIENT_PORT, 40000]))
                tick(1, "a stranger's hello")
                hello()  # the real client takes the session back, so the next commands count
            elif pick == "resync":
                send({"t": "resync", "full": rng.choice([0, 1, junk(rng)]), "c": junk(rng)})
            elif pick == "sub" and rng.random() < 0.5:
                send({"t": "sub", "c": [[rng.randint(-50, 50), rng.randint(-50, 50)] for _ in range(rng.randint(0, 40))]})
            elif pick == "sub":
                # A square (world.lua subscribe_square), sometimes with junk in its middle, reach or rows.
                o = [rng.randint(-3, 3), rng.randint(-3, 3)]
                r = rng.choice([0, 2, 5, 50, 1e9, -4, junk(rng)])
                rows = [[o[1] + dy] + [v for _ in range(rng.randint(0, 3)) for v in (rng.randint(-60, 60), rng.choice([1, 3, 101, 0, -2, 1e9]))]
                        for dy in range(-5, 6) if rng.random() < 0.7]
                if rng.random() < 0.2:
                    rows.append(junk(rng))
                send({"t": "sub", "o": rng.choice([o, o, o, junk(rng)]), "r": r, "w": rng.choice([rows, rows, rows, junk(rng)])})
            else:
                msg = command(rng)
                for _ in range(3):
                    send(msg)
            what = pick
        if not tick(rng.choice([1, 1, 2, 5]), what):
            break
        note_errors(take(), what)
        client = g.storage.f3d.client
        if not client or client.port != CLIENT_PORT:
            hello()  # after a bye or a stranger's hello: reconnect, so the next commands count
            tick(1, "a reconnect")
            take()

    fuzz_ext(rng)

    # The session recovers: a fresh client connects, gets the world and can walk. It says hello every
    # second until welcomed, as Zenith does: on a server a hello from a new port waits while the client
    # holding the session was heard 1.5-4 s ago (session.lua gone_client, LIVE and STALE, longer at a
    # game speed over 1). One hello and 3 ticks passed only when the fuzzing happened to end with the
    # session on this port or its holder long silent; the random commands follow the mod's handlers,
    # so new handlers moved where it ended (main failed after merging two branches that passed alone).
    waited, welcomed = 0, False
    while waited < 4000 and not welcomed:
        if waited % 60 == 0:
            hello("after-fuzz", 0)
        tick(3, "a new hello")
        waited += 3
        welcomed = any(m.get("t") == "welcome" for m in take())
    holder = g.storage.f3d.client
    check(welcomed, f"a new client gets a welcome after fuzzing (within {waited} ticks; the session's client "
                    f"{holder and (holder.sid, holder.port, holder.last_seen)} at tick {g.game.tick})")
    send({"t": "sub", "c": [[0, 0]]})
    # The handshake's stages and the chunk share the work budget a tick, which what was fuzzed may
    # have filled for a while: the chunk comes within seconds (12 ticks with seed 1), not always 6.
    waited, got = 0, False
    while waited < 300 and not got:
        tick(6, "a sub")
        waited += 6
        got = any(m.get("t") == "chunk" for m in take())
    check(got, f"and its chunk (within {waited} ticks)")
    for _ in range(3):
        send({"t": "walk", "d": 4})
        tick(3, "walking")
    c = g.storage.f3d.puppet
    walking = c and c.valid and c.walking_state
    check(bool(walking) and walking.walking and walking.direction == 4, "and walks east (walking_state)")

    check(BINARY["datagrams"] > 0 and BINARY["mv"] > 0 and BINARY["v3"] > 0,
          f"the second half's datagrams are binary frames, mv and ents (wire version 3) among them: {BINARY}")
    print(f"{args.rounds} rounds over {len(COMMANDS)} commands and {len(FIELDS)} fields (seed {args.seed})")
    for cmd, texts in sorted(bridge_errors.items()):
        print(f"  caught by on_packet in {cmd}: {sorted(texts)[0]}" + (f" (+{len(texts) - 1} more)" if len(texts) > 1 else ""))
    if failures:
        print(f"\n{len(failures)} check(s) failed")
        sys.exit(1)
    print("fuzz: the bridge survived")


if __name__ == "__main__":
    main()
