#!/usr/bin/env python3
"""Makes the main menu's built-in backdrop, client/data/menu_world.json, from a player's backdrop snapshot.

    python tools/make_menu_backdrop.py <snapshot> [--dump data-raw-dump.json] [--factorio DIR] [--check]

The snapshot is what the Esc menu's "Use this view as the menu backdrop" writes (a file in user://backdrops/,
user://menu-backdrop.json.gz before 0.2.2; backdrop_recorder.gd: Godot's compressed-file format, or plain JSON). The default shipped since 0.2.2 was
recorded that way in a vanilla Space Age game. Before it can ship:

- every prototype name in it (entities and their types, tiles, items and the entities they build, fluids,
  resource categories, the mods of its sounds' files) is checked against vanilla Factorio's data.raw, from
  `factorio --dump-data` with no other mods (base, space-age, quality, elevated-rails, recycler, core; as
  tools/icon_index.py runs it) or --dump. A prototype row of any other mod is dropped with what uses it
  (its entities, its eprops), and listed; so are the names entities carry (Alt-mode's icon `ai`: recipes, items,
  fluids, signals; the fluids of `fc`): a field naming something else is left out of its entity;
- what the player typed is taken out: the save's name, the backdrop's name and the time it was taken are left out,
  and a train stop's name becomes "Train stop" (the rest of the file is numbers and prototype names);
- every string field left is listed by where it is, with how many and a few values, for the release check.

Whole numbers are written without ".0" (Godot wrote every number as a float). Two more cuts that change nothing
the menu draws: a chunk's `_tiles` (its tiles as the client decoded them, which the recorder kept with the message;
the menu reads `tiles`) is left out, and the inserter hands (`ih`) are delta-coded (`z` 1, as the bridge sends them
to a client that asks; the menu's inserter layer reads both). --check writes nothing.
The menu draws the result as menu_background.gd's default, from the snapshot's saved camera view.
"""

import argparse
import collections
import json
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), "client", "data", "menu_world.json")
VANILLA_MODS = ("core", "base", "space-age", "quality", "elevated-rails", "recycler")
STOP_NAME = "Train stop"
LEFT_OUT = ("save", "taken", "name")


def read_snapshot(path):
    with open(path, "rb") as f:
        b = f.read()
    if b[:4] != b"GCPF":
        return json.loads(b)
    # FileAccess.open_compressed: "GCPF", mode, block size, raw size, each block's size, the blocks.
    mode, block, total = struct.unpack_from("<III", b, 4)
    n = (total + block - 1) // block if total else 0
    sizes = struct.unpack_from("<%dI" % n, b, 16)
    off = 16 + 4 * n
    out = bytearray()
    for s in sizes:
        if mode == 3:
            out += zlib.decompress(b[off:off + s], 16 + 15)  # gzip
        elif mode == 1:
            out += zlib.decompress(b[off:off + s], -15)  # deflate
        else:
            raise SystemExit("%s: compression mode %d isn't read here (gzip or deflate)" % (path, mode))
        off += s
    return json.loads(bytes(out))


def whole(v):
    if isinstance(v, float) and v.is_integer() and abs(v) < 2 ** 53:
        return int(v)
    if isinstance(v, list):
        return [whole(x) for x in v]
    if isinstance(v, dict):
        return {k: whole(x) for k, x in v.items()}
    return v


def delta_coded(l, width):
    """A flat list of `width`-number records as differences from the record before (`z` 1)."""
    out = []
    prev = [0] * width
    for i in range(0, len(l) - width + 1, width):
        for j in range(width):
            out.append(l[i + j] - prev[j])
            prev[j] = l[i + j]
    return out


def clean(snap, raw):
    by_type = {t: set(v) for t, v in raw.items()}
    every = set().union(*by_type.values())
    items = set().union(*(set(v) for v in raw.values() if any(isinstance(p, dict) and "stack_size" in p for p in v.values())))
    # Alt-mode icon types (`ai`) -> the names they may hold.
    icon_names = {"item": items, "fluid": by_type.get("fluid", set()), "recipe": by_type.get("recipe", set()),
                  "virtual-signal": by_type.get("virtual-signal", set()), "entity": every}

    def vanilla_icon(ai):
        if not isinstance(ai, list) or len(ai) < 2:
            return True
        names = [ai[1]] + (ai[2] if len(ai) > 2 and isinstance(ai[2], list) else [])
        allowed = icon_names.get(ai[0], every)
        return all(n in allowed for n in names if isinstance(n, str) and n != "")

    def vanilla_fluids(fc):
        fluids = by_type.get("fluid", set())
        return all(not (isinstance(c, list) and len(c) > 4 and c[4] not in ("", None) and c[4] not in fluids) for c in fc or [])
    dropped = collections.defaultdict(list)
    gone_protos = set()
    messages = []
    for m in snap["messages"]:
        t = m.get("t")
        if t in ("protos", "tprotos", "iprotos", "fprotos"):
            keep = []
            for r in m.get("l", []):
                name = r[1]
                if t == "protos":
                    ok = r[2] in by_type and name in by_type[r[2]]
                elif t == "tprotos":
                    ok = name in by_type.get("tile", ())
                elif t == "fprotos":
                    ok = name in by_type.get("fluid", ())
                else:
                    ok = name in items and (len(r) < 3 or r[2] == "" or r[2] in every)
                if ok:
                    keep.append(r)
                else:
                    dropped[t].append(name)
                    if t == "protos":
                        gone_protos.add(int(r[0]))
            m = dict(m, l=keep)
        elif t == "eprops":
            keep = []
            for r in m.get("l", []):
                o = r[4] if len(r) > 4 and isinstance(r[4], dict) else {}
                rk = o.get("rk")
                cats = [rk] if isinstance(rk, str) else (rk or [])
                bad = [c for c in cats if c not in by_type.get("resource-category", ())]
                bad += [o[k] for k in ("ms", "rsd") if k in o and o[k].split("/")[0] not in VANILLA_MODS]
                if int(r[0]) in gone_protos or bad:
                    dropped["eprops"].append(r[0] if not bad else bad)
                else:
                    keep.append(r)
            m = dict(m, l=keep)
        elif t == "ents":
            keep = []
            for e in m.get("e", []):
                if int(e[1]) in gone_protos:
                    dropped["ents"].append(e[0])
                    continue
                if len(e) > 5 and isinstance(e[5], dict):
                    o = dict(e[5])
                    if "n" in o:
                        o["n"] = STOP_NAME
                    if "ai" in o and not vanilla_icon(o["ai"]):
                        dropped["ai"].append(o.pop("ai"))
                    if "fc" in o and not vanilla_fluids(o["fc"]):
                        dropped["fc"].append(o.pop("fc"))
                    e = e[:5] + [o] + e[6:]
                keep.append(e)
            m = dict(m, e=keep)
        elif t == "chunk":
            m = {k: v for k, v in m.items() if k != "_tiles"}
        messages.append(m)
    out = whole({k: v for k, v in snap.items() if k not in LEFT_OUT})
    out["messages"] = whole(messages)
    for m in out["messages"]:
        if m.get("t") == "ih" and int(m.get("z", 0)) != 1 and isinstance(m.get("l"), list):
            m["l"] = delta_coded(m["l"], 4)
            m["z"] = 1
    return out, dropped


def strings(data):
    """Every string in the file: where (message kind and key path) -> Counter of values."""
    found = collections.defaultdict(collections.Counter)

    def walk(v, where):
        if isinstance(v, str):
            found[where][v] += 1
        elif isinstance(v, list):
            for x in v:
                walk(x, where + "[]")
        elif isinstance(v, dict):
            for k, x in v.items():
                walk(x, where + "." + k)

    for k, v in data.items():
        if k != "messages":
            walk(v, k)
    for m in data["messages"]:
        for k, v in m.items():
            walk(v, "messages(%s).%s" % (m.get("t"), k))
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("snapshot")
    ap.add_argument("--dump", help="a data-raw-dump.json from vanilla Factorio (else it is made)")
    ap.add_argument("--factorio", help="the install (else tools/factorio_install.py finds it)")
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--check", action="store_true", help="write nothing")
    args = ap.parse_args()
    if args.dump:
        with open(args.dump, encoding="utf-8") as f:
            raw = json.load(f)
    else:
        sys.path.insert(0, HERE)
        import icon_index
        raw = icon_index.dump(args.factorio or icon_index.FACTORIO)
    snap = read_snapshot(args.snapshot)
    left_out = {k: snap[k] for k in LEFT_OUT if k in snap}
    data, dropped = clean(snap, raw)
    print("left out:", json.dumps(left_out))
    print("dropped (not vanilla):", json.dumps(dropped) if dropped else "nothing")
    for where, c in sorted(strings(data).items()):
        print("  %-40s %5d (%d distinct) %s" % (where, sum(c.values()), len(c), ", ".join(list(c)[:4])))
    text = json.dumps(data, separators=(",", ":"))
    print("%d messages, %d bytes, %s" % (len(data["messages"]), len(text), dict(collections.Counter(m["t"] for m in data["messages"]))))
    if not args.check:
        with open(args.out, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        print("wrote", args.out)


if __name__ == "__main__":
    main()
