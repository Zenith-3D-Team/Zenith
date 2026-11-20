#!/usr/bin/env python3
"""Writes client/data/entity_pictures.json: each entity's picture as Factorio draws it at rest, in the
bridge's graphics-list form (`ents`), for the Factorio pack's cards when no game has sent its list
(the main menu's Model packs window, an old bridge). Read from Factorio's own prototype data with the
bridge's own data-stage code (mod/.../scripts/gfx_extract.lua entity_entries, run here in Lua 5.2 by
lupa), so offline and in a game the cards are composed from the same layers.

    python tools/entity_pictures_index.py [--dump data-raw-dump.json] [--factorio DIR] [--out FILE]

Without --dump it runs `factorio --dump-data` (as tools/icon_index.py). Only file names and numbers
are kept: the pictures are read from the player's install at runtime (sprite_standins.gd).

Format: {name: {"n": layers, "e"/"s"/"w": layers where they differ, "kn"...: what it adds while
working}}, a layer [file ("__base__/graphics/..."), x, y, w, h, scale, shift x, shift y (tiles),
tint or null, anim?] (docs/PROTOCOL.md, `gfx`).
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import icon_index  # noqa: E402

OUT = os.path.join(icon_index.REPO, "client", "data", "entity_pictures.json")
MOD = os.path.join(icon_index.REPO, "mod", "factorio-3d-bridge")
# Only the mods Zenith's own entities come from: a player's other mods come with a game's list.
MODS = ("__base__/", "__core__/", "__space-age__/", "__quality__/", "__elevated-rails__/")


def to_lua(lua, v):
    if isinstance(v, dict):
        t = lua.table()
        for k, x in v.items():
            t[k] = to_lua(lua, x)
        return t
    if isinstance(v, list):
        t = lua.table()
        for i, x in enumerate(v):
            t[i + 1] = to_lua(lua, x)
        return t
    return v


def from_lua(lua, null, v):
    if v is None or v == null:
        return None
    if lua.eval("type")(v) != "table":
        return v
    n = lua.eval("function(t) return #t end")(v)
    if n > 0:
        return [from_lua(lua, null, v[i]) for i in range(1, n + 1)]
    return {str(k): from_lua(lua, null, x) for k, x in v.items()}


def files(rec):
    for layers in rec.values():
        for layer in layers:
            yield layer[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump")
    ap.add_argument("--factorio")
    ap.add_argument("--out", default=OUT)
    a = ap.parse_args()
    if a.dump:
        with open(a.dump, encoding="utf-8") as f:
            raw = json.load(f)
    else:
        raw = icon_index.dump(a.factorio or icon_index.FACTORIO)
    import lupa.lua52 as lupa
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute("package.path = [[%s/?.lua;]] .. package.path" % MOD.replace("\\", "/"))
    ex = lua.eval('require("scripts.gfx_extract")')
    entries = lua.table()
    ex.entity_entries(to_lua(lua, raw), entries)
    out = {}
    for i in range(1, len(entries) + 1):
        e = entries[i]
        rec = from_lua(lua, ex.NULL, e[4])
        if rec and all(str(f).startswith(MODS) for f in files(rec)):
            out[str(e[3])] = rec
    with open(a.out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(out, f, separators=(",", ":"), sort_keys=True)
        f.write("\n")
    print("%d entities' pictures -> %s (%d KB)" % (len(out), a.out, os.path.getsize(a.out) // 1024))


if __name__ == "__main__":
    main()
