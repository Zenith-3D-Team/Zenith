# Live inserter radius (rel-031-arms): the focus's optional `ir` (the client's view, --live-inserter-radius)
# raises f3d-detail-radius for live hands (`ih`/`ie`), never past the focus radius; no `ir` keeps 0.3.1's
# 64-tile floor, `ir` 0 the detail radius alone, a bad `ir` is no `ir`.
ins_mod = g.package.loaded["scripts.inserters"]
gl = g.settings["global"]
max_was, detail_was = gl["f3d-max-focus-radius"].value, gl["f3d-detail-radius"].value
gl["f3d-max-focus-radius"].value = 192
gl["f3d-detail-radius"].value = 24
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(3)
take()


def live_r(focus):
    send({"t": "focus", "x": 0, "y": 0, **focus})
    tick(1)
    return int(ins_mod.live_radius()), g.storage.f3d.focus.ir


for focus, want, what in (
        ({"r": 96}, 64, "no ir: the 64-tile floor (older clients)"),
        ({"r": 96, "ir": 0}, 24, "ir 0: f3d-detail-radius alone"),
        ({"r": 96, "ir": 40}, 40, "ir 40: 40 tiles"),
        ({"r": 96, "ir": 16}, 24, "ir under the detail radius: the detail radius"),
        ({"r": 48, "ir": 128}, 48, "ir past focus.r: focus.r"),
        ({"r": 96, "ir": 200}, 64, "ir above 128: ignored (64 floor)"),
        ({"r": 96, "ir": -8}, 64, "negative ir: ignored"),
        ({"r": 96, "ir": 40.5}, 64, "fractional ir: ignored"),
        ({"r": 96, "ir": "40"}, 64, "string ir: ignored")):
    got, stored = live_r(focus)
    check(got == want, f"live inserter radius, {what}: {got} (want {want}, stored ir {stored})")

# What the radius does: an inserter 40 tiles out has a live hand under the floor and ir 48, none with ir 0.
far_ins = spawn("inserter", 40.5, 0.5, force="player", direction=4)
F["raise"]("script_raised_built", lua.table_from({"entity": far_ins}))
F.set_hand(far_ins, 40.9, 0.1, "iron-plate")


def far_hand(focus):
    send({"t": "focus", "x": 0, "y": 0, **focus})
    tick(30)
    seen = False
    for m in of_type(take(), "ih"):
        l = m["l"]
        seen = seen or any(l[i] == far_ins.unit_number for i in range(0, len(l), 4))
    return seen


check(far_hand({"r": 96, "ir": 48}), "ir 48: the inserter 40 tiles out sends its hand")
check(not far_hand({"r": 96, "ir": 0}) and int(ins_mod.live_radius()) == 24, "ir 0 (shrunk): the inserter 40 tiles out sends no hand")
check(far_hand({"r": 96}), "no ir (grown back to the 64 floor): the inserter 40 tiles out sends its hand again")
far_ins.destroy()
gl["f3d-max-focus-radius"].value, gl["f3d-detail-radius"].value = max_was, detail_was
send({"t": "focus", "x": 0, "y": 0, "r": 48})
tick(2)
take()
