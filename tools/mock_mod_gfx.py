"""The mock's graphics list (`gfx`, docs/PROTOCOL.md), as the bridge's data stage makes it
(mod/factorio-3d-bridge/scripts/gfx_extract.lua), for `mock_server.py --mod-gfx`.

The mock's world has no modded prototypes, so the list points some of its own at the fixture mod's
pictures (tools/mod_tests/fixtures/zenith-gfx-test): the iron gear wheel's icon is the fixture's
gizmo, grass-1 is its floor, the iron chest has its crate picture. A windowed client started with
--factorio-mods=tools/mod_tests/fixtures shows them, which says the whole path works: welcome,
asking, parts, the cache, mod_files.gd and the icons, tiles and pictures read from the mod.
"""

import hashlib
import json

FIXTURE = "zenith-gfx-test"
P = "__zenith-gfx-test__/graphics/"

LIST = {
    "icons": {
        "item": {
            "iron-gear-wheel": [[P + "icons/gizmo.png", 64, None, None, None]],
            "zenith-test-tinted": [[P + "icons/tinted-base.png", 64, None, None, None],
                                   [P + "icons/tinted-mask.png", 64, [0, 1, 0, 1], None, None]],
        },
    },
    "tiles": {
        "grass-1": {"mat": [P + "terrain/floor.png", 4, 0.5], "layer": 26, "group": "ground-natural", "water": 0,
                    "map": [0, 0.7, 1]},
    },
    "decor": {
        "zenith-test-pebbles": {"layer": "decorative", "box": [-0.5, -0.5, 0.5, 0.5],
                                "pics": [[P + "decorative/pebbles.png", i * 64, 0, 64, 64, 0.5, 0, 0] for i in range(4)]},
    },
    "ents": {
        "iron-chest": {"n": [[P + "entity/crate.png", 0, 0, 128, 160, 0.5, 0, -0.25, None]]},
    },
}


def parts():
    """The list in parts, one section each (as the bridge's would be for a small list)."""
    return [{sec: val} for sec, val in LIST.items()]


def fingerprint():
    return hashlib.sha1(json.dumps(LIST, sort_keys=True).encode()).hexdigest()[:16]


class Sender:
    """Answers `gfx` {fp, need?}: a part a tick."""

    def __init__(self):
        self.queue = []

    def welcome_fields(self, msg):
        msg["mods"] = {"base": "2.1.24", "factorio-3d-bridge": "mock", FIXTURE: "1.0.0"}
        msg["gf"] = fingerprint()
        msg["gn"] = len(parts())
        return msg

    def ask(self, msg):
        if msg.get("fp") != fingerprint():
            return
        n = len(parts())
        need = msg.get("need")
        if isinstance(need, list) and need:
            self.queue = [i for i in need if isinstance(i, int) and 1 <= i <= n]
        else:
            self.queue = list(range(1, n + 1))

    def tick(self, send_now):
        if self.queue:
            i = self.queue.pop(0)
            send_now({"t": "gfx", "fp": fingerprint(), "part": i, "parts": len(parts()), "d": parts()[i - 1]})
