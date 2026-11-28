"""Differential live checks of the train schedule commands against the real game (bughunt trains2): every pre-Space-Age
wait condition the client's schedule editor offers survives set_schedule into the game's records, a rename of a stop
against the schedule, a temporary stop to a missing station, trains limit.
Run: python tools/live_check.py --only traindiff"""
from __future__ import annotations

from . import live_lib

WAITS = [
    {"type": "time", "compare_type": "or", "ticks": 1800},
    {"type": "full", "compare_type": "and"},
    {"type": "empty", "compare_type": "or"},
    {"type": "not_empty", "compare_type": "or"},
    {"type": "robots_inactive", "compare_type": "or"},
    {"type": "inactivity", "compare_type": "or", "ticks": 300},
    {"type": "passenger_present", "compare_type": "or"},
    {"type": "passenger_not_present", "compare_type": "or"},
    {"type": "fuel_full", "compare_type": "or"},
    {"type": "destination_full_or_no_path", "compare_type": "or"},
    {"type": "item_count", "compare_type": "and", "condition": {"first_signal": {"type": "item", "name": "iron-plate"}, "comparator": "<", "constant": 100}},
    {"type": "fluid_count", "compare_type": "or", "condition": {"first_signal": {"type": "fluid", "name": "water"}, "comparator": ">", "constant": 50}},
    {"type": "circuit", "compare_type": "or", "condition": {"first_signal": {"type": "virtual", "name": "signal-A"}, "comparator": "=", "constant": 1}},
    {"type": "fuel_item_count_all", "compare_type": "or", "condition": {"first_signal": {"type": "item", "name": "coal"}, "comparator": "<", "constant": 5}},
    {"type": "fuel_item_count_any", "compare_type": "or", "condition": {"first_signal": {"type": "item", "name": "coal"}, "comparator": "<", "constant": 5}},
    {"type": "item_count", "compare_type": "or", "condition": {"comparator": "<", "constant": 0}},
]
OTHER = [{"type": "specific_destination_full", "compare_type": "or", "station": "TD one"},
         {"type": "specific_destination_not_full", "compare_type": "or", "station": "TD one"},
         {"type": "at_station", "compare_type": "or", "station": "TD one"},
         {"type": "not_at_station", "compare_type": "or", "station": "TD one"},
         {"type": "damage_taken", "compare_type": "or", "damage": 1000}]


def check_trains_diff(c, hello):
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "traindiff: no clean spot found", live_lib.SPOT_WHY)
        return
    lua = lambda code: live_lib.mod_lua(code.replace("\n", " "))
    out = lua(f"""
local c = storage.f3d.puppet local s = c.surface
local x0 = 2 * math.floor(c.position.x / 2) + 1 local y0 = 2 * math.floor(c.position.y / 2) - 11
storage.f3d_traindiff = {{}}
local function mk(spec) spec.force = c.force spec.raise_built = true local e = s.create_entity(spec) if e then table.insert(storage.f3d_traindiff, e) end return e end
for i = -14, 14 do mk({{ name = "straight-rail", position = {{ x0 + 2 * i, y0 }}, direction = defines.direction.east }}) end
local stop = mk({{ name = "train-stop", position = {{ x0 + 14, y0 + 2 }}, direction = defines.direction.east }})
stop.backer_name = "TD one"
local loco = mk({{ name = "locomotive", position = {{ x0, y0 }}, direction = defines.direction.east }})
loco.get_fuel_inventory().insert({{ name = "coal", count = 20 }})
local wagon = mk({{ name = "cargo-wagon", position = {{ x0 - 7, y0 }}, direction = defines.direction.east }})
c.teleport({{ x0, y0 + 4 }})
rcon.print(stop.unit_number .. ' ' .. loco.unit_number .. ' ' .. loco.position.x .. ' ' .. loco.position.y .. ' ' .. wagon.unit_number .. ' ' .. wagon.position.x .. ' ' .. wagon.position.y)""")
    p = out.split()
    if len(p) != 7:
        live_lib.report(False, "traindiff: building", out)
        return
    stop_u, loco_u = int(p[0]), int(p[1])
    lx, ly = round(float(p[2]) * 256), round(float(p[3]) * 256)

    wagon_u = int(p[4])
    wx, wy = round(float(p[5]) * 256), round(float(p[6]) * 256)
    # 0. cargo wagon slot filters (middle click, inv_filter with the wagon's unit).
    c.send({"t": "open", "u": wagon_u, "p": c.proto_id("cargo-wagon"), "x": wx, "y": wy})
    c.pump(0.4, every=hello)
    c.send({"t": "inv_filter", "u": wagon_u, "i": 3, "item": "coal"})
    g = [m for m in c.pump(0.5, every=hello) if m.get("t") == "gui" and m.get("u") == wagon_u]
    live_lib.report(g and g[-1].get("wfl") == [[3, "coal"]], "traindiff cargo wagon: a slot filter set and reported (wfl)", str(g[-1:] and g[-1].get("wfl")))
    held = lua(f"local e for _, x in pairs(storage.f3d_traindiff) do if x.valid and x.unit_number == {wagon_u} then e = x end end local inv = e.get_inventory(defines.inventory.cargo_wagon) rcon.print(tostring(inv.get_filter(3)) .. ' ' .. inv.insert({{ name = 'iron-plate', count = 5000 }}))")
    print("INFO game: filter 3 and iron inserted:", held)
    c.send({"t": "inv_filter", "u": wagon_u, "i": 3, "item": ""})
    g = [m for m in c.pump(0.5, every=hello) if m.get("t") == "gui" and m.get("u") == wagon_u]
    live_lib.report(g and not g[-1].get("wfl"), "traindiff cargo wagon: the filter cleared", str(g[-1:] and g[-1].get("wfl")))

    def opened():
        c.send({"t": "close"})
        c.pump(0.15, every=hello)
        c.send({"t": "open", "u": loco_u, "p": c.proto_id("locomotive"), "x": lx, "y": ly})
        return c.pump(0.5, every=hello)

    def recs():
        return lua(f"local e for _, x in pairs(storage.f3d_traindiff) do if x.valid and x.unit_number == {loco_u} then e = x end end "
                   "local out = {} for i, r in pairs(e.train.get_schedule().get_records()) do local w = {} "
                   "for _, wc in pairs(r.wait_conditions or {}) do w[#w + 1] = wc.type .. '/' .. wc.compare_type .. '/' .. (wc.ticks or '-') .. '/' .. "
                   "(wc.condition and (wc.condition.comparator .. (wc.condition.constant or 'nil') .. (wc.condition.first_signal and wc.condition.first_signal.name or '')) or '-') end "
                   "out[#out + 1] = (r.station or 'RAIL') .. (r.temporary and '(t)' or '') .. '=' .. table.concat(w, ',') end rcon.print(table.concat(out, ';'))")

    opened()
    errs = []
    # 1. each wait condition on its own.
    for w in WAITS:
        c.send({"t": "set_schedule", "u": loco_u, "records": [{"station": "TD one", "wait_conditions": [w]}]})
        msgs = c.pump(0.3, every=hello)
        errs = [m["text"] for m in live_lib.of_type(msgs, "msg")]
        got = recs()
        live_lib.report(not errs and got.startswith("TD one=" + w["type"] + "/" + w["compare_type"]), f"traindiff wait {w['type']}: held by the game", f"{got} {errs}")
    for w in OTHER:
        c.send({"t": "set_schedule", "u": loco_u, "records": [{"station": "TD one", "wait_conditions": [w]}]})
        msgs = c.pump(0.3, every=hello)
        print("INFO", w["type"], "->", recs(), [m["text"] for m in live_lib.of_type(msgs, "msg")])
    # 2. AND / OR combination.
    c.send({"t": "set_schedule", "u": loco_u, "records": [{"station": "TD one", "wait_conditions": [
        {"type": "time", "compare_type": "or", "ticks": 60}, {"type": "full", "compare_type": "and"}, {"type": "inactivity", "compare_type": "or", "ticks": 120}]}]})
    c.pump(0.3, every=hello)
    got = recs()
    live_lib.report(got == "TD one=time/or/60/-,full/and/-/-,inactivity/or/120/-", "traindiff and/or kept in order", got)
    # 3. rename of the stop: the game's schedule.
    c.send({"t": "set_schedule", "u": loco_u, "records": [{"station": "TD one", "wait_conditions": [{"type": "time", "compare_type": "or", "ticks": 60}]}]})
    c.pump(0.3, every=hello)
    lua(f"for _, x in pairs(storage.f3d_traindiff) do if x.valid and x.unit_number == {stop_u} then x.backer_name = 'TD two' end end")
    c.pump(0.3, every=hello)
    print("INFO after script rename:", recs())
    # 4. a temporary stop to a missing station, in the game.
    opened()
    c.send({"t": "train_temp", "u": loco_u, "station": "TD nowhere"})
    msgs = c.pump(0.5, every=hello)
    print("INFO temp to missing:", recs(), [m.get("text") for m in live_lib.of_type(msgs, "msg")])
    # 5. current record kept on edit.
    c.send({"t": "set_schedule", "u": loco_u, "records": [
        {"station": "TD two", "wait_conditions": [{"type": "time", "compare_type": "or", "ticks": 60}]},
        {"station": "TD one", "wait_conditions": [{"type": "time", "compare_type": "or", "ticks": 60}]}]})
    c.pump(0.3, every=hello)
    c.send({"t": "train_mode", "u": loco_u, "auto": 0})
    c.send({"t": "train_go", "u": loco_u, "i": 2})
    c.pump(0.3, every=hello)
    cur = lua(f"local e for _, x in pairs(storage.f3d_traindiff) do if x.valid and x.unit_number == {loco_u} then e = x end end rcon.print(e.train.get_schedule().current .. ' ' .. tostring(e.train.manual_mode))")
    print("INFO go_to on manual train (current, manual):", cur)
    
    lua("for _, e in pairs(storage.f3d_traindiff or {}) do if e.valid then e.destroy() end end storage.f3d_traindiff = nil")
