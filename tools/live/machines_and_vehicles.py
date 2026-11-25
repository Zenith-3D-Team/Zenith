"""Circuits, logic, machines, vehicles, repair, remote view, states, and map info live checks."""
from __future__ import annotations

import math
import time

from . import live_lib


def check_circuits(c, hello):
    """Wire tools and every entity's circuit and own settings (wiring.lua, circuit_settings.lua,
    entity_ui.lua, circuits.lua): connect / disconnect / clear wires, gui.cc and set_cc, combinators
    in full (decider conditions and outputs, every selector mode, constant sections), lamps,
    speakers, pumps, turrets, display panels, inserters' spoil priority."""
    back = live_lib.mod_lua("local p = storage.f3d.puppet.position rcon.print(p.x .. ' ' .. p.y)")
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "circuits: no clean spot found")
        return
    live_lib.mod_lua('local f = storage.f3d.puppet.force for _, t in pairs({ "electronics", "circuit-network" }) do '
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
    vals = live_lib.mod_lua(lua).split()
    if len(vals) != 3 * len(specs):
        live_lib.report(False, "circuits: building the test entities", " ".join(vals))
        return
    ents = {}
    for i, (name, *_rest) in enumerate(specs):
        u = int(vals[3 * i])
        key = name if name not in ents else name + "#2"
        ents[key] = (u, float(vals[3 * i + 1]), float(vals[3 * i + 2]), name)
    live_lib.report(all(v[0] for k, v in ents.items() if k != "straight-rail"), "circuits: test entities built",
           ", ".join(k for k, v in ents.items() if not v[0]))
    c.pump(1.0, every=hello)

    def end(key, mdx=0.0, mdy=0.0):
        u, ex, ey, name = ents[key]
        return {"u": u, "p": c.proto_id(name), "x": fx(ex), "y": fx(ey), "mx": fx(ex + mdx), "my": fx(ey + mdy)}

    def lua_on(key, code):
        """Runs code with `e` the test entity."""
        return live_lib.mod_lua(f'local e for _, x in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ force = storage.f3d.puppet.force, '
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
    upd = {m["e"][0] for m in live_lib.of_type(msgs, "upd")}
    live_lib.report(out == "true" and ents["decider-combinator"][0] in upd,
           "wire: red wire to a decider's input side (get_wire_connector, connect_to), both ends re-sent", f"{out}, upd {upd}")
    c.send({"t": "wire", "k": "r", "a": end("constant-combinator"), "b": end("decider-combinator", 0, 0.5)})
    c.pump(0.6, every=hello)
    out = lua_on("decider-combinator", 'rcon.print(#e.get_wire_connector(ids.combinator_input_red, true).connections)')
    live_lib.report(out == "0", "wire: the same pair again disconnects (is_connected_to, disconnect_from)", out)
    c.send({"t": "wire", "k": "r", "a": end("constant-combinator"), "b": end("decider-combinator", 0, 0.5)})
    c.send({"t": "wire", "k": "g", "a": end("decider-combinator", 0, -0.5), "b": end("small-lamp")})
    c.pump(0.6, every=hello)
    out = lua_on("decider-combinator", 'rcon.print(#e.get_wire_connector(ids.combinator_output_green, true).connections .. " " .. '
                 '#e.get_wire_connector(ids.combinator_input_green, true).connections)')
    live_lib.report(out == "1 0", "wire: a click on the side a combinator faces takes its output connector", out)
    c.send({"t": "wire", "k": "w", "a": end("small-electric-pole"), "b": end("small-electric-pole#2")})
    c.send({"t": "wire", "k": "w", "a": end("small-electric-pole#2"), "b": end("power-switch", -0.6, 0)})
    c.pump(0.6, every=hello)
    out = lua_on("power-switch", 'rcon.print(#e.get_wire_connector(ids.power_switch_left_copper, true).connections .. " " .. '
                 '#e.get_wire_connector(ids.power_switch_right_copper, true).connections)')
    live_lib.report(out == "1 0", "wire: copper wire into a power switch's left side (power_switch_left_copper)", out)
    c.send({"t": "wire", "k": "w", "a": end("small-electric-pole"), "b": end("decider-combinator")})
    msgs = c.pump(0.5, every=hello)
    live_lib.report(any("Copper wire" in m["text"] for m in live_lib.of_type(msgs, "msg")), "wire: copper wire to a combinator is refused")
    e = end("small-electric-pole#2")
    c.send({"t": "wire_clear", **{k: e[k] for k in ("u", "p", "x", "y")}})
    c.pump(0.6, every=hello)
    out = lua_on("small-electric-pole#2", 'rcon.print(#e.get_wire_connector(ids.pole_copper, true).connections)')
    live_lib.report(out == "0", "wire_clear removes a pole's copper cables (disconnect_all)", out)

    # --- generic circuit settings ------------------------------------------------------------------
    c.send({"t": "wire", "k": "r", "a": end("constant-combinator"), "b": end("fast-inserter")})
    g = open_gui("fast-inserter", wait=1.0)
    cc = g.get("cc") or {}
    live_lib.report(cc.get("o") == "inserter" and cc.get("w") == 1 and cc.get("nets", {}).get("r", 0) > 0
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
    live_lib.report(out == "true iron-plate≥7 true true signal-S true copper-plate",
           "set_cc writes an inserter's enable condition, hand read mode, stack size signal, logistic condition", out)
    g = open_gui("fast-inserter")
    f = (g.get("cc") or {}).get("f", {})
    live_lib.report(f.get("circuit_enable_disable") == 1 and f.get("circuit_hand_read_mode") == "hold"
           and f.get("circuit_condition", {}).get("comparator") == "≥" and f.get("circuit_condition", {}).get("ful") in (0, 1),
           "gui.cc reads them back (enum names, fulfilled)", str(f)[:300])
    c.send({"t": "set_inserter", "u": ents["fast-inserter"][0], "sp": "spoiled-first"})
    c.pump(0.5, every=hello)
    out = lua_on("fast-inserter", 'rcon.print(tostring(e.inserter_spoil_priority))')
    g = open_gui("fast-inserter")
    live_lib.report(out == "spoiled-first" and (g.get("ins") or {}).get("sp") == "spoiled-first", "set_inserter: spoil priority (inserter_spoil_priority)", out)

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
        live_lib.report(cc.get("o") == o and len(cc.get("f", {})) > 0, f"gui.cc on a {key}: {o}", str(cc)[:200])

    # --- lamp --------------------------------------------------------------------------------------
    open_gui("small-lamp", {"t": "set_color", "c": [255, 128, 0]}, wait=0.3)
    c.send({"t": "set_cc", "u": ents["small-lamp"][0], "f": {"use_colors": 1, "color_mode": "components",
                                                            "red_signal": {"type": "virtual", "name": "signal-R"}}})
    c.pump(0.5, every=hello)
    out = lua_on("small-lamp", 'local b = e.get_control_behavior() local k = e.color rcon.print(math.floor(k.r * 255 + 0.5) .. " " .. '
                 'math.floor(k.g * 255 + 0.5) .. " " .. tostring(b.use_colors) .. " " .. b.color_mode .. " " .. b.red_signal.name)')
    g = open_gui("small-lamp")
    live_lib.report(out.startswith("255 128 true") and out.endswith("signal-R") and g.get("col") == [255, 128, 0],
           "lamp: colour (LuaEntity.color), use colours and colour mode (LuaLampControlBehavior)", f"{out}; col {g.get('col')}")
    if ents.get("train-stop", (0,))[0]:
        open_gui("train-stop", {"t": "set_color", "c": [0, 200, 50]}, wait=0.4)
        g = open_gui("train-stop")
        live_lib.report(g.get("col") == [0, 200, 50], "train stop colour (LuaEntity.color)", str(g.get("col")))

    # --- programmable speaker ---------------------------------------------------------------------
    g = open_gui("programmable-speaker", {"t": "set_speaker", "vol": 0.5, "mode": "global", "poly": 1, "inst": 1, "note": 2,
                                          "pitch": 1, "al": {"show": 1, "map": 1, "icon": {"type": "virtual", "name": "signal-A"}, "msg": "Hello"}},
                 wait=1.0)
    spk = g.get("spk") or {}
    out = lua_on("programmable-speaker", 'local p, cp, a = e.parameters, e.get_control_behavior().circuit_parameters, e.alert_parameters '
                 'rcon.print(p.playback_volume .. " " .. p.playback_mode .. " " .. tostring(p.allow_polyphony) .. " " .. cp.instrument_id .. " " .. '
                 'cp.note_id .. " " .. tostring(cp.signal_value_is_pitch) .. " " .. tostring(a.show_alert) .. " " .. a.alert_message .. " " .. a.icon_signal_id.name)')
    live_lib.report(out == "0.5 global true 1 2 true true Hello signal-A" and len(spk.get("il", [])) > 1,
           "speaker: volume, playback, polyphony, instrument, note, pitch, alert (parameters, circuit_parameters, alert_parameters)",
           f"{out}; {len(spk.get('il', []))} instruments")

    # --- pump, turret, display panel ---------------------------------------------------------------
    g = open_gui("pump", {"t": "set_pump", "f": "water"})
    out = lua_on("pump", 'local f = e.get_fluid_filter(1) rcon.print(f and f.name or "none")')
    g = open_gui("pump")
    live_lib.report(out == "water" and g.get("pf") == "water", "pump: fluid filter (set_fluid_filter, get_fluid_filter)", f"{out}; pf {g.get('pf')}")
    open_gui("pump", {"t": "set_pump", "f": ""}, wait=0.4)
    out = lua_on("pump", 'local f = e.get_fluid_filter(1) rcon.print(f and f.name or "none")')
    live_lib.report(out == "none", "pump: the filter clears", out)
    open_gui("gun-turret", {"t": "set_targets", "l": ["small-biter", "medium-biter"], "ign": 1}, wait=0.5)
    g = open_gui("gun-turret")
    out = lua_on("gun-turret", 'local l = {} for _, p in pairs(e.priority_targets) do l[#l + 1] = p.name end '
                 'rcon.print(table.concat(l, ",") .. " " .. tostring(e.ignore_unprioritised_targets))')
    live_lib.report(out == "small-biter,medium-biter true" and (g.get("tgt") or {}).get("l") == ["small-biter", "medium-biter"],
           "turret: priority targets (set_priority_target, priority_targets, ignore_unprioritised_targets)", out)
    open_gui("gun-turret", {"t": "set_targets", "l": ["medium-biter"]}, wait=0.5)
    out = lua_on("gun-turret", 'local l = {} for _, p in pairs(e.priority_targets) do l[#l + 1] = p.name end rcon.print(table.concat(l, ","))')
    live_lib.report(out == "medium-biter", "turret: removing targets (set_priority_target without an entity)", out)
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
    live_lib.report(out == "2 Low < true true" and len(dp.get("msgs", [])) == 2 and dp["msgs"][1]["text"] == "Plenty",
           "display panel: messages with conditions (records), always show, show in chart", f"{out}; {str(dp)[:200]}")

    # --- combinators in full -----------------------------------------------------------------------
    sections = [{"g": "", "on": 1, "m": 1, "s": [["item", "iron-plate", 12]]},
                {"g": "", "on": 0, "m": 3, "s": [["virtual", "signal-A", 5], ["item", "copper-plate", 2, "uncommon"]]}]
    open_gui("constant-combinator", {"t": "set_cb", "cb": {"enabled": True, "sections": sections}}, wait=0.5)
    g = open_gui("constant-combinator")
    out = lua_on("constant-combinator", 'local b = e.get_control_behavior() local s2 = b.get_section(2) '
                 'rcon.print(b.sections_count .. " " .. tostring(s2.active) .. " " .. s2.multiplier .. " " .. s2.filters[2].value.quality)')
    live_lib.report(out == "2 false 3 uncommon" and (g.get("cb") or {}).get("sections") == sections,
           "constant combinator: sections (add_section, active, multiplier, quality)", f"{out}; {str((g.get('cb') or {}).get('sections'))[:200]}")
    open_gui("constant-combinator", {"t": "set_cb", "cb": {"enabled": True, "sections": sections[:1]}}, wait=0.4)
    out = lua_on("constant-combinator", 'rcon.print(e.get_control_behavior().sections_count)')
    live_lib.report(out == "1", "constant combinator: remove_section", out)
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
    live_lib.report(len(conds) == 3 and conds[1].get("compare_type") == "and" and conds[0].get("first_signal_networks", {}).get("green") is False
           and len(cb.get("outputs", [])) == 2 and cb["outputs"][1].get("networks", {}).get("red") is False,
           "decider: three conditions with and/or, networks, two outputs (parameters)", str(cb)[:300])
    sig = g.get("sig") or {}
    live_lib.report(["item", "iron-plate", 12] in sig.get("r", []) and sig.get("ri", 0) > 0 and isinstance(sig.get("out"), dict),
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
    live_lib.report(not bad, "selector: every mode and its settings round-trip (parameters)", "; ".join(bad)[:400])
    arith = {"first_signal": {"type": "virtual", "name": "signal-each"}, "first_signal_networks": {"red": True, "green": False},
             "operation": ">>", "second_constant": 2, "output_signal": {"type": "virtual", "name": "signal-each"}}
    open_gui("arithmetic-combinator", {"t": "set_cb", "cb": arith}, wait=0.4)
    g = open_gui("arithmetic-combinator")
    cb = g.get("cb") or {}
    live_lib.report(cb.get("operation") == ">>" and cb.get("first_signal_networks", {}).get("green") is False,
           "arithmetic: each, >>, network selection", str(cb)[:200])
    c.send({"t": "close"})
    live_lib.destroy_units([v[0] for v in ents.values()])
    # Back where the character was, so the checks after this one see the same place as before.
    if len(back.split()) == 2:
        bx, by = (float(v) for v in back.split())
        live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {bx}, {by} }})")
        live_lib.watch_around(c, hello, bx, by)


def check_logic(c, hello):
    """The logic, train and vehicle windows' data (entity_ui.lua, trains.lua, screens.lua): a lamp's
    Always on (set_lamp), a combinator's description (set_desc), an inserter's hand and a burner's
    fuel bar (ins.h, bu), a rail signal opening, a train stop's trains (stop.trs), a locomotive's
    name and colour, a cargo wagon's limit bar, a car's guns."""
    back = live_lib.mod_lua("local p = storage.f3d.puppet.position rcon.print(p.x .. ' ' .. p.y)")
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "logic: no clean spot found")
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
    vals = live_lib.mod_lua(lua).split()
    ents = {}
    for i, (name, *_r) in enumerate(specs + trainy):
        if 3 * i + 2 < len(vals):
            ents[name] = (int(float(vals[3 * i])), float(vals[3 * i + 1]), float(vals[3 * i + 2]))
    live_lib.report(len(ents) == 9 and all(v[0] for v in ents.values()), "logic: test entities built", str(ents)[:300])
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
        return live_lib.mod_lua(f'local e for _, x in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = "{name}", '
                       f'position = {{ {ents[name][1]}, {ents[name][2]} }}, radius = 0.6 }})) do e = x end {code}')

    g = open_gui("small-lamp")
    live_lib.report(g.get("ao") == 0, "lamp: ao (always_on) is sent", str(g)[:200])
    open_gui("small-lamp", {"t": "set_lamp", "ao": 1})
    g = open_gui("small-lamp")
    out = lua_on("small-lamp", "rcon.print(tostring(e.always_on))")
    live_lib.report(out == "true" and g.get("ao") == 1, "set_lamp: Always on (LuaEntity.always_on)", out)
    open_gui("constant-combinator", {"t": "set_desc", "text": "Outpost mats"})
    g = open_gui("constant-combinator")
    out = lua_on("constant-combinator", "rcon.print(e.combinator_description)")
    live_lib.report(out == "Outpost mats" and g.get("desc") == "Outpost mats", "set_desc: a combinator's description (combinator_description)", out)
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
    live_lib.report(seen_bu is not None, "burner inserter: bu (burner.remaining_burning_fuel / fuel_value)", str(seen_bu))
    live_lib.report(seen_h is not None and seen_h[0] == "iron-plate", "inserter: ins.h (held_stack) while it carries", str(seen_h))
    g = open_gui("rail-signal")
    live_lib.report(g.get("kind") == "other" and "status" in g, "rail signal: opens with its status", str(g)[:200])
    out = lua_on("locomotive", 'local stop for _, x in pairs(e.surface.find_entities_filtered({ name = "train-stop", position = e.position, radius = 12 })) do stop = x end '
                 'e.insert({ name = "coal", count = 10 }) e.color = { r = 1, g = 0.5, b = 0 } '
                 'e.train.schedule = { current = 1, records = { { station = stop.backer_name, wait_conditions = { { type = "time", ticks = 600 } } } } } '
                 'rcon.print(stop.backer_name .. "|" .. e.train.id)')
    g = open_gui("locomotive")
    tr = g.get("tr") or {}
    live_lib.report(isinstance(tr.get("name"), str) and tr["name"] != "" and g.get("col") == [255, 128, 0],
           "locomotive: tr.name (backer_name) and col (LuaEntity.color)", f"{out}; {tr.get('name')} {g.get('col')}")
    open_gui("locomotive", {"t": "set_color", "c": [0, 100, 200]})
    out2 = lua_on("locomotive", 'rcon.print(math.floor(e.color.b * 255 + 0.5))')
    live_lib.report(out2 == "200", "set_color on a locomotive", out2)
    # D10: from the remote view (rv) a building far away opens where a working radar covers it
    # (the mod works the coverage out: a headless server reveals nothing), for settings only.
    rx, ry = x + 320, y
    made = live_lib.mod_lua(f'local c = storage.f3d.puppet local s = c.surface local f = c.force '
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
        live_lib.report(bool(g) and g[-1].get("recipe") == "iron-gear-wheel",
               "rv: a building 320 tiles away opens beside a working radar, and takes a recipe", f"{g[-1:]} {[m['text'] for m in msgs if m.get('t') == 'msg']}")
        c.send({"t": "open", "u": ub, "p": c.proto_id("assembling-machine-2"), "x": fx(rx + 290.5), "y": fx(ry + 0.5), "rv": 1})
        msgs = c.pump(1.0, every=hello)
        live_lib.report(not [m for m in msgs if m.get("t") == "gui" and m.get("u") == ub] and any("roboport coverage" in m.get("text", "") for m in msgs if m.get("t") == "msg"),
               "rv: one no radar covers doesn't open", str([m.get("text") for m in msgs if m.get("t") == "msg"]))
        c.pump(0.5, every=hello)
        c.send({"t": "mtr"})
        mt = [m for m in c.pump(1.0, every=hello) if m.get("t") == "mtr"]
        cov = mt[0].get("cov") if mt else None
        rc = [int(rx // 32), int(ry // 32)]
        live_lib.report(isinstance(cov, list) and any(cov[i:i + 2] == rc and cov[i + 2] >= 2 for i in range(0, len(cov), 3)),
               "mtr cov: the working radar's chunk and its nearby reveal distance (D12)", f"{cov} radar chunk {rc}")
        c.send({"t": "close"})
        live_lib.destroy_units([ua, ub, ur])
    else:
        live_lib.report(False, "rv: test buildings made", str(made))
    # D11: the map's trains (mtr): every carriage with its place, turn, size and map colour.
    c.pump(0.5, every=hello)
    c.send({"t": "mtr"})
    mtr = [m for m in c.pump(1.0, every=hello) if m.get("t") == "mtr"]
    cars = [mtr[-1]["l"][i:i + 6] for i in range(0, len(mtr[-1]["l"]), 6)] if mtr else []
    near = lambda name: next((r for r in cars if abs(r[0] - fx(ents[name][1])) < 128 and abs(r[1] - fx(ents[name][2])) < 128), None)
    loco, wagon = near("locomotive"), near("cargo-wagon")
    live_lib.report(loco is not None and wagon is not None and loco[5] == 0x0064C8 and loco[3] > loco[4] > 0 and loco[2] in (250, 750),
           "mtr: the map's trains, each carriage's place, turn, size and colour", f"{len(cars)} cars; locomotive {loco}, wagon {wagon}")
    g = open_gui("train-stop", wait=1.0)
    trs = (g.get("stop") or {}).get("trs")
    live_lib.report(isinstance(trs, list) and any(t[3] == ents["locomotive"][0] or t[3] == ents["cargo-wagon"][0] for t in trs),
           "train stop: trs, the trains with it in their schedule (get_train_stop_trains)", f"{out}: {trs}")
    g = open_gui("cargo-wagon")
    live_lib.report(isinstance(g.get("bar"), int) and g["bar"] > 0, "cargo wagon: bar (its inventory's limit)", str(g.get("bar")))
    open_gui("cargo-wagon", {"t": "set_bar", "n": 5})
    g = open_gui("cargo-wagon")
    out = lua_on("cargo-wagon", 'rcon.print(e.get_inventory(defines.inventory.cargo_wagon).get_bar() - 1)')
    live_lib.report(out == "5" and g.get("bar") == 5, "set_bar on a cargo wagon", out)
    g = open_gui("car")
    live_lib.report(g.get("guns") == ["vehicle-machine-gun"], "car: guns (prototype.indexed_guns)", str(g.get("guns")))
    if any(n == "lightning-rod" for n, _ in c.protos.values()):
        out = live_lib.mod_lua(f'local e = storage.f3d.puppet.surface.create_entity({{ name = "lightning-rod", position = {{ {x + 6.5}, {y - 6.5} }}, '
                      f'force = storage.f3d.puppet.force }}) rcon.print(e.unit_number .. " " .. e.position.x .. " " .. e.position.y)').split()
        if len(out) == 3:
            ents["lightning-rod"] = (int(out[0]), float(out[1]), float(out[2]))
            g = open_gui("lightning-rod")
            live_lib.report(not g, "a lightning rod opens no window (entity_ui.lua NO_WINDOW, as 2.1.23)", str(g)[:200])
    c.send({"t": "close"})
    live_lib.destroy_units([v[0] for v in ents.values()])
    live_lib.mod_lua(f'for _, r in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = "straight-rail", '
            f'area = {{ {{ {x - 11}, {y + 1} }}, {{ {x + 13}, {y + 5} }} }} }})) do r.destroy() end rcon.print("ok")')
    if len(back.split()) == 2:
        bx, by = (float(v) for v in back.split())
        live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {bx}, {by} }})")
        live_lib.watch_around(c, hello, bx, by)


def check_vehicles(c, hello):
    """ui-logic2's windows (entity_ui.lua, spiders.lua, trains.lua): a tank's guns and grid, a
    spidertron's name, colour and auto targeting (veh, set_vehicle), the remote (spider_go, spd),
    artillery's auto targeting (art, set_artillery), a storage tank's pipeline and flush (pl,
    flush), train groups (set_train_group, gc, groups), and that a steam engine opens nothing."""
    back = live_lib.mod_lua("local p = storage.f3d.puppet.position rcon.print(p.x .. ' ' .. p.y)")
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "vehicles: no clean spot found")
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
    vals = live_lib.mod_lua(lua).split()
    ents = {}
    for i, (name, *_r) in enumerate(specs):
        if 3 * i + 2 < len(vals) and int(float(vals[3 * i])):
            ents[name] = (int(float(vals[3 * i])), float(vals[3 * i + 1]), float(vals[3 * i + 2]))
    live_lib.report(len(ents) == len(specs), "vehicles: test entities built", str(ents)[:300])
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
        return live_lib.mod_lua(f'local e for _, x in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = "{name}", '
                       f'position = {{ {ents[name][1]}, {ents[name][2]} }}, radius = 0.6 }})) do e = x end {code}')

    g = open_gui("tank")
    live_lib.report(g.get("kind") == "vehicle" and len(g.get("guns") or []) == 3 and (g.get("veh") or {}).get("grid") == 1,
           "tank: three guns (indexed_guns) and an equipment grid (veh.grid)", f"{g.get('guns')} {g.get('veh')}")
    g = open_gui("spidertron")
    veh = g.get("veh") or {}
    live_lib.report(len(g.get("guns") or []) == 4 and isinstance(veh.get("at"), list) and isinstance(g.get("col"), list),
           "spidertron: four guns, auto targeting (vehicle_automatic_targeting_parameters) and colour",
           f"{g.get('guns')} {veh} {g.get('col')}")
    open_gui("spidertron", {"t": "set_vehicle", "lbl": "Live spider", "wi": 1, "wo": 0})
    open_gui("spidertron", {"t": "set_color", "c": [0, 0, 255]})
    g = open_gui("spidertron")
    out = lua_on("spidertron", 'local p = e.vehicle_automatic_targeting_parameters rcon.print(e.entity_label .. "|" .. '
                 'tostring(p.auto_target_with_gunner) .. "|" .. tostring(p.auto_target_without_gunner) .. "|" .. '
                 'math.floor(e.color.b * 255 + 0.5))')
    live_lib.report(out == "Live spider|true|false|255" and (g.get("veh") or {}).get("lbl") == "Live spider",
           "set_vehicle names the spidertron and sets its targeting; set_color colours it", out)
    c.send({"t": "close"})
    su = ents["spidertron"][0]
    c.send({"t": "spider_go", "l": [su], "x": fx(x - 4), "y": fx(y - 12)})
    c.send({"t": "spider_go", "l": [su], "x": fx(x + 6), "y": fx(y - 12), "q": 1})
    spd = [m for m in c.pump(1.0, every=hello) if m.get("t") == "spd"]
    live_lib.report(spd and len(spd[-1]["l"]) == 1 and len(spd[-1]["l"][0][1]) >= 1,
           "spider_go: autopilot destinations, Shift queues (spd)", str(spd[-1:])[:200])
    c.pump(4.0, every=hello)
    moved = live_lib.mod_lua(f"local e = game.get_entity_by_unit_number({su}) rcon.print(math.floor(e.position.y - {ents['spidertron'][2]}))")
    live_lib.report(moved.lstrip("-").isdigit() and int(moved) < -2, "and the spidertron walks there (get_entity_by_unit_number)", moved)
    g = open_gui("artillery-turret")
    live_lib.report(g.get("art") == 1, "artillery turret: art (artillery_auto_targeting)", str(g.get("art")))
    open_gui("artillery-turret", {"t": "set_artillery", "on": 0})
    out = lua_on("artillery-turret", "rcon.print(tostring(e.artillery_auto_targeting))")
    live_lib.report(out == "false", "set_artillery turns it off", out)
    lua_on("storage-tank", 'e.insert_fluid({ name = "water", amount = 5000 }) rcon.print("ok")')
    c.pump(0.5, every=hello)
    g = open_gui("storage-tank")
    pl = g.get("pl")
    live_lib.report(isinstance(pl, list) and pl[0] == "water" and pl[1] > 0 and pl[2] >= 25000,
           "storage tank: pl, its pipeline (get_fluid_segment_fluid / capacity)", str(pl))
    open_gui("storage-tank", {"t": "flush", "pipe": 1})
    out = lua_on("storage-tank", 'local f = e.get_fluid_segment_fluid(1) rcon.print(f and f.amount or 0)')
    live_lib.report(out in ("0", "0.0"), "flush with pipe 1 empties the pipeline (clear_fluid_segment_fluid)", out)
    g = open_gui("steam-engine")
    live_lib.report(not g, "a steam engine opens no window, as in 2.1.23 (rules_openable)", str(g)[:150])
    # Train groups: a locomotive on rails, into a group and out.
    rails = " ".join(f's.create_entity({{ name = "straight-rail", position = {{ {x - 9 + 2 * i}, {y + 9} }}, direction = 4, force = c.force }})'
                     for i in range(8))
    out = live_lib.mod_lua(f'local c = storage.f3d.puppet local s = c.surface {rails} '
                  f'local e = s.create_entity({{ name = "locomotive", position = {{ {x - 2}, {y + 9} }}, direction = 4, force = c.force, '
                  'raise_built = true }) rcon.print(e and (e.unit_number .. " " .. e.position.x .. " " .. e.position.y) or "0 0 0")').split()
    if len(out) == 3 and int(float(out[0])):
        ents["locomotive"] = (int(float(out[0])), float(out[1]), float(out[2]))
        open_gui("locomotive", {"t": "set_train_group", "g": "Live group"})
        g = open_gui("locomotive")
        tr = g.get("tr") or {}
        lg = lua_on("locomotive", "rcon.print(e.train.group)")
        live_lib.report(lg == "Live group" and tr.get("gc") == 1 and ["Live group", 1] in tr.get("groups", []),
               "set_train_group: the train joins the group (LuaTrain.group); gc and groups", f"{lg} {tr.get('gc')} {tr.get('groups')}")
        open_gui("locomotive", {"t": "set_train_group", "g": ""})
        lg = lua_on("locomotive", "rcon.print(e.train.group or '')")
        live_lib.report(lg == "", "and an empty name leaves it", lg)
    else:
        live_lib.report(False, "vehicles: locomotive built", str(out))
    c.send({"t": "close"})
    live_lib.destroy_units([v[0] for v in ents.values()])
    live_lib.mod_lua(f'for _, r in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ area = {{ {{ {x - 14}, {y - 16} }}, '
            f'{{ {x + 14}, {y + 11} }} }}, name = {{ "straight-rail", "pipe", "spidertron", "locomotive" }} }})) do r.destroy() end rcon.print("ok")')
    if len(back.split()) == 2:
        bx, by = (float(v) for v in back.split())
        live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {bx}, {by} }})")
        live_lib.watch_around(c, hello, bx, by)


def check_mine_vehicles(c, hello):
    """Issue #10: right-click mining picks the vehicle under the mouse and sends its unit number.
    Every kind of rolling stock on a rail, and a car, a tank and a spidertron, mined by hand with
    things inside (fuel, cargo) as Factorio does: the vehicle and its contents go to the inventory,
    the rail under a wagon stays. And from the remote view `decon` with `u` marks only the wagon."""
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "mine vehicles: no clean spot found", live_lib.SPOT_WHY)
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
    vals = live_lib.mod_lua(lua).split()
    ents = {}
    for i, (name, *_r) in enumerate(specs):
        if 3 * i + 2 < len(vals) and int(float(vals[3 * i])):
            ents[name] = (int(float(vals[3 * i])), float(vals[3 * i + 1]), float(vals[3 * i + 2]))
    live_lib.report(len(ents) == len(specs), "mine vehicles: test vehicles built", str(ents)[:300])
    c.pump(1.0, every=hello)
    for name, ex, ey, item, n in specs:
        if name not in ents:
            continue
        u, px, py = ents[name]
        live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {px}, {py - 3} }})")
        c.pump(0.5, every=hello)
        before = dict(c.inv)
        cmd = {"t": "mine", "u": u, "p": c.proto_id(name), "x": int(round(px * 256)), "y": int(round(py * 256))}
        msgs = c.pump(6.0, every=(0.2, cmd), until=lambda m: m.get("t") == "msg")
        c.send({"t": "mine_stop"})
        msgs += c.pump(1.0, every=hello)
        gone = live_lib.mod_lua(f"local e = game.get_entity_by_unit_number({u}) rcon.print(e and e.valid and 'there' or 'gone')")
        texts = [m["text"] for m in live_lib.of_type(msgs, "msg")]
        got = c.inv.get(name, 0) - before.get(name, 0)
        live_lib.report(gone == "gone" and got == 1, f"#10: mining a {name} by its unit number takes it to the inventory",
               f"{gone}, +{got}, messages {texts}")
        if item:
            more = c.inv.get(item, 0) - before.get(item, 0)
            live_lib.report(more == n, f"#10: and the {n} {item} inside it come too", f"+{more}")
    on_rail = live_lib.mod_lua(f"rcon.print(storage.f3d.puppet.surface.count_entities_filtered({{ name = 'straight-rail', "
                      f"area = {{ {{ {x - 22}, {y + 3} }}, {{ {x + 22}, {y + 5} }} }} }}))")
    live_lib.report(on_rail == "22", "#10: the rails under the mined wagons stay", on_rail)
    # Remote view: decon with u marks only the wagon, not the rail under it.
    out = live_lib.mod_lua(f'local c = storage.f3d.puppet local e = c.surface.create_entity({{ name = "cargo-wagon", position = {{ {x - 6}, {y + 4} }}, '
                  f'direction = 4, force = c.force, raise_built = true }}) rcon.print(e and (e.unit_number .. " " .. e.position.x .. " " .. e.position.y) or "0 0 0")').split()
    if len(out) == 3 and int(float(out[0])):
        u, wx, wy = int(float(out[0])), float(out[1]), float(out[2])
        c.send({"t": "decon", "i": 0, "x1": int((wx - 0.1) * 256), "y1": int((wy - 0.1) * 256), "x2": int((wx + 0.1) * 256),
                "y2": int((wy + 0.1) * 256), "u": u, "p": c.proto_id("cargo-wagon")})
        c.pump(1.0, every=hello)
        marks = live_lib.mod_lua(f"local s = storage.f3d.puppet.surface local w = game.get_entity_by_unit_number({u}) local n = 0 "
                        f"for _, r in pairs(s.find_entities_filtered({{ name = 'straight-rail', position = {{ {wx}, {wy} }}, radius = 3 }})) do "
                        "if r.to_be_deconstructed() then n = n + 1 end end "
                        "rcon.print(tostring(w and w.to_be_deconstructed()) .. ' ' .. n)")
        live_lib.report(marks == "true 0", "#10: decon with u marks only the wagon (remote view), not the rail under it", marks)
        live_lib.destroy_units([u])
    live_lib.mod_lua(f'for _, r in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ area = {{ {{ {x - 23}, {y - 10} }}, '
            f'{{ {x + 23}, {y + 6} }} }}, name = {{ "straight-rail", "locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon", '
            '"car", "tank", "spidertron" } })) do r.destroy() end rcon.print("ok")')


def check_machines(c, hello):
    """Factorio's production windows (machine_info.lua): recipe details, the chooser's groups,
    productivity, burners, drills, temperature, labs and a requester chest's settings."""
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "machines: no clean spot found", live_lib.SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    fx = lambda v: int(round(v * 256))
    out = live_lib.mod_lua(f"""
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
        live_lib.report(False, "machines: building the test entities", out)
        return
    units = {r[1]: (int(r[0]), float(r[2]), float(r[3])) for r in recs}

    def screen(name, seconds=1.2):
        u, ex, ey = units[name]
        c.send({"t": "open", "u": u, "p": c.proto_id(name), "x": fx(ex), "y": fx(ey)})
        msgs = c.pump(seconds, every=hello)
        g = [m for m in live_lib.of_type(msgs, "gui") if m.get("u") == u and not m.get("closed")]
        # The first message carries the lists (rl, rg, li, lgs); a late one from before may come first.
        listed = [m for m in g if {"rl", "li", "lgs"} & set(m)]
        return (listed or g or [{}])[0], g[-1] if g else {}

    c.pump(2.0, every=hello)  # let the machines and the drill run a little
    first, last = screen("assembling-machine-2")
    rl = dict(zip(first.get("rl", []), first.get("rg", [])))
    live_lib.report(last.get("rd", {}).get("o") == [["item", "electronic-circuit", 1]] and ["item", "copper-cable", 3] in last.get("rd", {}).get("i", []),
           "rd: the recipe's ingredients and products (LuaRecipe.ingredients / products / energy)", str(last.get("rd")))
    live_lib.report(len(rl) == len(first.get("rl", [])) > 0 and rl.get("iron-gear-wheel", [""])[0] == "intermediate-products",
           "rg: each recipe's item group, subgroup and order for the chooser's tabs",
           f"{rl.get('iron-gear-wheel')} rl={first.get('rl', [])[:3]} rg={first.get('rg', [])[:2]}")
    live_lib.report(last.get("pb", 0) > 0 and "bp" in last, "pb / bp: productivity bonus and bonus_progress (productivity modules)",
           f"pb={last.get('pb')} bp={last.get('bp')}")
    _, last = screen("stone-furnace")
    live_lib.report(last.get("rd", {}).get("o") == [["item", "iron-plate", 1]] and 0 < last.get("bn", 0) <= 1000,
           "a furnace's recipe details and its burner's fuel left (LuaBurner.currently_burning / remaining_burning_fuel)",
           f"rd={last.get('rd')} bn={last.get('bn')}")
    _, last = screen("burner-mining-drill")
    live_lib.report(last.get("mt") == "iron-ore" and "bn" in last, "a drill's mining target and burner (mining_target)",
           f"mt={last.get('mt')} mp={last.get('mp')} bn={last.get('bn')}")
    live_lib.report("mp" in last, "a drill's mining progress (mining_progress or crafting_progress)", f"mp={last.get('mp')}")
    _, last = screen("pumpjack")
    live_lib.report(last.get("mt") == "crude-oil" and last.get("mr", 0) > 0, "a pumpjack's yield per second (normal_resource_amount, mining_speed)",
           f"mt={last.get('mt')} mr={last.get('mr')}")
    _, last = screen("nuclear-reactor")
    live_lib.report("tc" in last and last.get("tmax") == 1000, "temperature in hundredths and the heat buffer's max_temperature",
           f"tc={last.get('tc')} tmax={last.get('tmax')}")
    first, _ = screen("lab")
    live_lib.report("automation-science-pack" in first.get("li", []), "li: the lab's science packs (lab_inputs)", str(first.get("li"))[:120])
    live_lib.report([1, 500] in first.get("ld", []), "ld: what is left of the pack a lab started on (get_stored_durability)",
           str(first.get("ld")))
    u = units["requester-chest"][0]
    _, last = screen("requester-chest")
    lc = last.get("lc", {})
    live_lib.report(lc.get("tu") == 0 and lc.get("rb") in (0, 1) and isinstance(lc.get("sec"), list),
           "lc: a requester's sections, trash unrequested (get_logistic_point) and request_from_buffers", str(lc))
    c.send({"t": "set_chest_logistics", "u": u, "tu": 1, "rb": 1})
    c.send({"t": "set_section", "u": u, "i": 0})
    _, last = screen("requester-chest")
    lc = last.get("lc", {})
    live_lib.report(lc.get("tu") == 1 and lc.get("rb") == 1 and len(lc.get("sec", [])) >= 1,
           "set_chest_logistics and set_section on a chest", str(lc))
    c.send({"t": "set_section", "u": u, "i": 1, "g": "F3D live check"})
    c.pump(0.5, every=hello)
    c.send({"t": "close"})
    first, last = screen("requester-chest")
    live_lib.report(last.get("lc", {}).get("sec", [{}])[0].get("g") == "F3D live check" and "F3D live check" in first.get("lgs", []),
           "set_section g: a section joins a logistic group (LuaLogisticSection.group); lgs lists the force's groups "
           "(get_logistic_groups)", f"{last.get('lc', {}).get('sec')} lgs={first.get('lgs')}")
    live_lib.mod_lua('storage.f3d.puppet.force.delete_logistic_group("F3D live check")')
    if "rocket-silo" in units:
        _, last = screen("rocket-silo")
        rw = last.get("rw", [])
        live_lib.report(len(rw) == 2 and rw[0] > 0 and rw[1] == 1000000 and isinstance(last.get("lc", {}).get("sec"), list)
               and last.get("rd", {}).get("o", [[None, None]])[0][1] == "rocket-part" and "pr" in last,
               "a silo: rocket weight (LuaItemPrototype.weight, default_rocket_lift_weight), its requests (rocket_silo_requester), "
               "the rocket part's recipe and progress", f"rw={rw} lc={last.get('lc')} rd={last.get('rd')} pr={last.get('pr')}")
        u_silo = units["rocket-silo"][0]
        c.send({"t": "set_chest_logistics", "u": u_silo, "tu": 1})
        _, last = screen("rocket-silo")
        live_lib.report(last.get("lc", {}).get("tu") == 1, "set_chest_logistics on a silo: trash unrequested", str(last.get("lc")))
    c.send({"t": "close"})
    live_lib.destroy_units([v[0] for v in units.values()])
    live_lib.mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ type = 'resource', area = {{ {{ {x - 8}, {y - 8} }}, {{ {x + 8}, {y} }} }} }})) do e.destroy() end")


def check_remote_view(c, hello):
    """The 3D remote view (focus rv = 1) shows moving things only where a working radar or the
    character sees, as Factorio's does (map.view_filter): a car and a belt item beside a powered radar
    320 tiles away are sent, the same 300 tiles further on aren't, and `cov` says what is seen
    (the radar's chunk and reveal distance, the character's place). Without rv everything is sent.
    A roboport's construction area counts as seen too (H13): with one beside the far car it is sent,
    its belt opens from the remote view, and `mrp` lists the roboport."""
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "remote view: an empty spot", live_lib.SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    rx, ry = x + 320, y
    out = live_lib.mod_lua(f"""
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
        live_lib.report(False, "remote view: a radar, cars and belts made", str(out))
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
        cars = {r[0] for m in live_lib.of_type(msgs, "mv") for r in m["l"]}
        items = [(m["l"][i + 2] / 256, m["l"][i + 3] / 256) for m in live_lib.of_type(msgs, "bi") for i in range(0, len(m["l"]), 4)]
        on_belt = any(abs(ix - (at + 4.5)) < 1 and abs(iy - ry) < 2 for ix, iy in items)
        return cars, on_belt, live_lib.of_type(msgs, "cov")

    c.pump(4.0, every=hello)
    cars, on_belt, cov = look(rx + 10, True, 3.0)
    rc = [int(rx // 32), int(ry // 32)]
    l = cov[-1]["l"] if cov else []
    live_lib.report(car_a in cars and on_belt, "remote view: a car and a belt item beside a working radar are sent", f"{sorted(cars)[:6]} item {on_belt}")
    live_lib.report(bool(cov) and any(l[i:i + 2] == rc and l[i + 2] >= 2 for i in range(0, len(l), 3))
           and abs(cov[-1].get("x", 0) / 256 - x) < 2 and cov[-1].get("cr") == 96,
           "remote view: cov lists the radar's chunk and reveal distance and the character's place", str(cov[-1:]))
    cars, on_belt, cov = look(rx + 310, True)
    live_lib.report(car_b not in cars and not on_belt and bool(cov), "remote view: no car or belt item where no radar sees", f"{sorted(cars)[:6]} item {on_belt}")
    cars, on_belt, cov = look(rx + 310, False)
    live_lib.report(car_b in cars and on_belt and not cov, "outside the remote view the same car and item are sent, and no cov",
           f"{sorted(cars)[:6]} item {on_belt} cov {cov[-1:]}")
    # H13: a roboport's construction area counts as seen too: a powered roboport 20 tiles south of the
    # car no radar sees, and the car is sent; `mrp` lists the roboport, and the car's belt opens.
    port = live_lib.mod_lua(f"""
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
        live_lib.report(car_b in cars and on_belt, "remote view: a car and a belt item in a roboport's construction area are sent (H13)",
               f"{sorted(cars)[:6]} item {on_belt}")
        c.send({"t": "open", "u": belt_b, "p": c.proto_id("transport-belt"), "x": fx(rx + 314.5), "y": fx(ry + 0.5), "rv": 1})
        msgs = c.pump(1.0, every=hello)
        live_lib.report(any(m.get("t") == "gui" and m.get("u") == belt_b for m in msgs),
               "rv: a building in a roboport's construction area opens from the remote view (H13, D10)",
               str([m.get("text") for m in msgs if m.get("t") == "msg"]))
        c.send({"t": "close"})
        c.send({"t": "mrp", "si": int(port[3]), "q": 7})
        msgs = c.pump(2.0, every=hello)
        ports = [v for m in msgs if m.get("t") == "mrp" and m.get("q") == 7 for v in m["l"]]
        last = [m for m in msgs if m.get("t") == "mrp" and m.get("q") == 7 and m.get("last") == 1]
        at = [fx(float(port[4])), fx(float(port[5]))]  # where the 4x4 roboport snapped to
        live_lib.report(bool(last) and any(ports[i:i + 2] == at and ports[i + 3] > ports[i + 2] > 0 for i in range(0, len(ports), 4)),
               "mrp: the roboport with its logistic and construction radius (H13)", f"{len(ports) // 4} roboports, last {bool(last)}")
    else:
        live_lib.report(False, "remote view: a roboport made", str(port))
    live_lib.destroy_units([car_a, belt_a, car_b, belt_b, radar] + port_units)
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
    live_lib.clear_enemies()  # a biter left from the shooting checks kills the character in the middle (see clear_enemies)
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "states: an empty spot", live_lib.SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    rx, ry = 2 * math.floor(x / 2) - 8, 2 * math.floor(y / 2) + 7  # rails sit on the 2x2 grid
    out = live_lib.mod_lua(f"""
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
        live_lib.report(False, "states: built a track with signals, an accumulator, a power switch and a lamp", out)
        return
    live_lib.report(sig and chain, "states: a rail signal and a chain signal placed by the track", out)

    def states(seconds):
        got = {}
        for m in live_lib.of_type(c.pump(seconds, every=hello), "st"):
            for i in range(0, len(m["l"]), 2):
                got[m["l"][i]] = m["l"][i + 1]
        return got
    got = states(6.0)
    live_lib.report(got.get(sig) == 1 and got.get(chain) == 1, "st: an empty block's rail and chain signals are green (1)",
           f"signal {got.get(sig)}, chain {got.get(chain)}")
    live_lib.report(got.get(acc) == 1, "st: an accumulator charging from the network is 1 (status charging)", str(got.get(acc)))
    live_lib.report(got.get(switch) == 1, "st: a power switch that is on is 1", str(got.get(switch)))
    live_lib.report(got.get(lamp) == 0, "st: a powered lamp at noon is 0 (status turned_off_during_daytime)", str(got.get(lamp)))
    # K20: the lamp set to Always on at noon. Printed: the status 2.1 gives it (working, or still
    # turned_off_during_daytime, which the bridge reads past through always_on); then `st` 1 with `ao` 1,
    # which lets the client light it by day, and 0 again with Always on off.
    def lamp_msgs(seconds):
        st_got, ao_got = {}, {}
        for m in live_lib.of_type(c.pump(seconds, every=hello), "st"):
            for i in range(0, len(m["l"]), 2):
                st_got[m["l"][i]] = m["l"][i + 1]
            a = m.get("ao") or []
            for i in range(0, len(a), 2):
                ao_got[a[i]] = a[i + 1]
        return st_got, ao_got
    out = live_lib.mod_lua("storage.f3d_states.lamp.always_on = true rcon.print('ok')")
    st_got, ao_got = lamp_msgs(4.0)
    status = live_lib.mod_lua("local l = storage.f3d_states.lamp local n = tostring(l.status) "
                     "for k, v in pairs(defines.entity_status) do if v == l.status then n = k end end "
                     "rcon.print(n .. ', always_on ' .. tostring(l.always_on))")
    print(f"  K20: a lamp set to Always on at noon reads status {status}")
    live_lib.report(out == "ok" and st_got.get(lamp) == 1 and ao_got.get(lamp) == 1,
           "st: a lamp set to Always on at noon is 1 with ao 1: the client lights it by day (K20)",
           f"{out}; st {st_got.get(lamp)}, ao {ao_got.get(lamp)}; status {status}")
    out = live_lib.mod_lua("storage.f3d_states.lamp.always_on = false rcon.print('ok')")
    st_got, _ = lamp_msgs(4.0)
    live_lib.report(out == "ok" and st_got.get(lamp) == 0, "st: Always on turned off again at noon: 0 (K20)", f"{out}; st {st_got.get(lamp)}")
    # A locomotive in the track's blocks, the switch off, the solar panel swapped for a radar, midnight.
    out = live_lib.mod_lua(f"""
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
    live_lib.report(out == "ok" and (got.get(sig) == 3 or got.get(chain) == 3),
           "st: with a locomotive standing in its block a signal turns red (3)", f"{out}; signal {got.get(sig)}, chain {got.get(chain)}")
    live_lib.report(got.get(acc) == 2, "st: the accumulator feeding a radar with the supply gone is 2 (discharging)", str(got.get(acc)))
    live_lib.report(got.get(switch) == 0, "st: the power switch turned off is 0", str(got.get(switch)))
    live_lib.report(got.get(lamp) == 1, "st: the lamp at midnight, fed by the accumulator, is 1 (working): the client lights it (J19)",
           str(got.get(lamp)))
    # K10: the lit lamp's colour (`st` `lc`, movers.lua). First what 2.1 reads for a lamp as built (printed:
    # LuaEntity.color, whether it has a control behaviour), then the colour set in its window, then its
    # circuit's (a constant combinator's signal-red on a red wire, Use colors on, the colour mapping).
    def lamp_colours(seconds):
        got = {}
        for m in live_lib.of_type(c.pump(seconds, every=hello), "st"):
            l = m.get("lc") or []
            for i in range(0, len(l), 2):
                got[l[i]] = l[i + 1]
        return got
    col = "local function col(v) return v and string.format('%.3f,%.3f,%.3f', v.r or v[1] or -1, v.g or v[2] or -1, v.b or v[3] or -1) or 'nil' end "
    out = live_lib.mod_lua(col + "local l = storage.f3d_states.lamp local ok, cb = pcall(function() return l.get_control_behavior() end) "
                  "rcon.print('LuaEntity.color ' .. col(l.color) .. ', control behaviour ' .. tostring(ok and cb ~= nil))")
    print(f"  K10: a lamp as built reads {out}")
    out = live_lib.mod_lua("storage.f3d_states.lamp.color = { r = 0, g = 1, b = 0, a = 1 } rcon.print('ok')")
    got = lamp_colours(3.0)
    live_lib.report(out == "ok" and got.get(lamp) == 0x00FF00, "st lc: a lit lamp's window colour (LuaEntity.color) goes to the client (K10)",
           f"{out}; lc {got.get(lamp)}")
    out = live_lib.mod_lua("""local t = storage.f3d_states local l = t.lamp local s = l.surface
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
    shown = live_lib.mod_lua(col + "local cb = storage.f3d_states.lamp.get_control_behavior() rcon.print(col(cb and cb.color))")
    print(f"  K10: with Use colors and signal-red on its wire, LuaLampControlBehavior.color reads {shown}")
    got = {**early, **lamp_colours(3.0)}
    live_lib.report(out == "ok" and got.get(lamp) == 0xFF0000,
           "st lc: with Use colors, its circuit network's colour (signal-red) instead of its window's (K10)",
           f"{out}; cb.color {shown}; lc {got.get(lamp)}")
    live_lib.mod_lua("""local t = storage.f3d_states local s = t.acc.surface
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
    live_lib.clear_enemies()  # a biter left from the shooting checks kills the character in the middle (see clear_enemies)
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "repair: an empty spot", live_lib.SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    fx = lambda v: math.floor(v * 256 + 0.5)  # world.fixed
    pid = {v[0]: k for k, v in c.protos.items()}
    out = live_lib.mod_lua(f"""local c = storage.f3d.puppet local s = c.surface
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
        live_lib.report(False, "repair: a damaged wall and an enemy chest, repair packs in the inventory", out)
        return
    # Factorio's own repair_state on the player-less character, the wall selected: does its health move?
    out = live_lib.mod_lua("""local c = storage.f3d.puppet local t = storage.f3d_repair
local okc, cur = pcall(function() return c.cursor_stack end)
local oks = pcall(function() c.selected = t.w end)
local ok, err = pcall(function() c.repair_state = { repairing = true, position = t.w.position } end)
t.before = t.w.health
rcon.print('cursor_stack ' .. tostring(okc and cur ~= nil) .. ', selected ' .. tostring(oks) .. ', repair_state written ' .. tostring(ok) .. ' ' .. tostring(err or ''))""".replace("\n", " "))
    c.pump(1.0, every=hello)
    after = live_lib.mod_lua("""local c = storage.f3d.puppet local t = storage.f3d_repair
local ok, st = pcall(function() return c.repair_state end)
rcon.print(string.format('health %.1f -> %.1f, repair_state reads %s', t.before, t.w.health, ok and tostring(st and st.repairing) or 'error'))
pcall(function() c.repair_state = { repairing = false, position = c.position } end)
t.w.health = 100""".replace("\n", " "))
    print(f"  K13: Factorio's repair_state for a player-less character: {out}; after a second {after}")
    live_lib.report(True, "repair: repair_state's answer printed (the bridge repairs itself)", f"{out}; {after}")

    def health(name):
        try:
            return float(live_lib.mod_lua(f"rcon.print(storage.f3d_repair.{name}.health)"))
        except ValueError:
            return -1.0

    def pack():
        return live_lib.mod_lua("local s = storage.f3d.puppet.get_main_inventory().find_item_stack('repair-pack') "
                       "rcon.print(s and (s.count .. ' ' .. s.durability) or 'none')")
    w0 = health("w")
    pack0 = pack()
    t0 = int(live_lib.mod_lua("rcon.print(game.tick)") or 0)
    cmd = {"t": "repair", "u": wall, "p": pid.get("stone-wall", 0), "x": fx(wx), "y": fx(wy), "item": "repair-pack"}
    msgs = []
    end = time.time() + 1.0
    while time.time() < end:
        c.send(cmd)
        msgs += c.pump(0.15, every=hello)
    c.send({"t": "repair"})
    msgs += c.pump(0.3, every=hello)
    w1 = health("w")
    ticks = int(live_lib.mod_lua("rcon.print(game.tick)") or 0) - t0
    pack1 = pack()
    rp = [m for m in live_lib.of_type(msgs, "me") if m.get("rp") == 1]
    # table_to_json writes an empty list as {}: an `hp` with no bars has no list to read.
    hp_lists = [m["l"] if isinstance(m["l"], list) else [] for m in live_lib.of_type(msgs, "hp")]
    bars = [dict(zip(l[::2], l[1::2])).get(wall) for l in hp_lists]
    print(f"  K13: the wall {w0:.0f} -> {w1:.0f} of {wall_max:.0f} in about {ticks} ticks; the pack {pack0} -> {pack1}")
    live_lib.report(w1 > w0 + 100 and w1 <= wall_max, "repair: the wall mends while the client repeats `repair` (4 health a tick: speed 2, modifier 2)",
           f"{w0} -> {w1} in {ticks} ticks")
    live_lib.report(pack1 != pack0, "repair: the pack's durability is used", f"{pack0} -> {pack1}")
    live_lib.report(rp and rp[-1].get("rx") == fx(wx) and rp[-1].get("ry") == fx(wy), "repair: me says the character repairs (rp, rx, ry)",
           str(rp[-1:]))
    live_lib.report(any(b is not None for b in bars), "repair: the wall's bar is in hp while it mends", str(bars[-3:]))
    w2 = health("w")
    c.pump(1.0, every=hello)
    live_lib.report(health("w") == w2, "repair: `repair` without a target stops it", f"{w2} -> {health('w')}")
    e0 = health("en")
    c.send({"t": "repair", "u": enemy, "p": pid.get("wooden-chest", 0), "x": fx(ex), "y": fx(ey), "item": "repair-pack"})
    c.pump(1.0, every=hello)
    live_lib.report(health("en") == e0, "repair: another force's chest isn't mended", f"{e0} -> {health('en')}")
    live_lib.mod_lua("local t = storage.f3d_repair for _, e in pairs({ t.w, t.en }) do if e.valid then e.destroy({ raise_destroy = true }) end end "
            "storage.f3d.puppet.get_main_inventory().remove({ name = 'repair-pack', count = 3 }) storage.f3d_repair = nil rcon.print('ok')")


def check_vehicle_items(c, hello):
    """N2, N3, N4: the bridge's commands on vehicles in the real game. N2: Ctrl+click (`fast`) on a car, a tank, a
    spidertron, a locomotive and a cargo wagon (LuaEntity.insert: fuel to the fuel slot, ammo to the ammo slots, the
    rest to the trunk or cargo; a locomotive takes fuel only; an empty hand takes the trunk or cargo, a locomotive's
    nothing). N3: in an armed vehicle `guns` is the vehicle's (`v`, its guns over its ammo, `sel`), `gun` picks the
    vehicle's gun, `move` to role `vammo` loads it, out of it the character's guns come back; and printed: whether
    `shoot` fires the vehicle's gun for the player-less character. N4: `repair` mends a car and a cargo wagon, not
    another force's car."""
    live_lib.clear_enemies()
    back = live_lib.mod_lua("local p = storage.f3d.puppet.position rcon.print(p.x .. ' ' .. p.y)")
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "vehicle items: an empty spot", live_lib.SPOT_WHY)
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
    vals = live_lib.mod_lua(lua).split()
    keys = ["car", "tank", "spidertron", "locomotive", "cargo-wagon", "enemy-car", "enemy-chest"]
    ents = {}
    for i, k in enumerate(keys):
        if 3 * i + 2 < len(vals) and int(float(vals[3 * i])):
            ents[k] = (int(float(vals[3 * i])), float(vals[3 * i + 1]), float(vals[3 * i + 2]))
    live_lib.report(len(ents) == len(keys), "vehicle items: a car, a tank, a spidertron, a locomotive and a cargo wagon built, "
           "another force's car and chest", str(ents)[:300])
    if len(ents) < len(keys):
        live_lib.destroy_units([v[0] for v in ents.values()])
        return
    c.pump(1.0, every=hello)
    name_of = {"enemy-car": "car", "enemy-chest": "wooden-chest"}

    def target(k):
        u, ex, ey = ents[k]
        return {"u": u, "p": pid.get(name_of.get(k, k), 0), "x": fx(ex), "y": fx(ey)}

    def count(k, inv, item):
        out = live_lib.mod_lua(f"local e = game.get_entity_by_unit_number({ents[k][0]}) "
                      f"local ok, i = pcall(function() return e.get_inventory(defines.inventory.{inv}) end) "
                      f"rcon.print(ok and i and i.get_item_count('{item}') or -1)")
        return int(out) if out.lstrip("-").isdigit() else -2

    def main(item):
        out = live_lib.mod_lua(f"rcon.print(storage.f3d.puppet.get_main_inventory().get_item_count('{item}'))")
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
        texts = [m["text"] for m in live_lib.of_type(msgs, "msg")]
        live_lib.report(v1 - v0 == n and m0 - m1 == n, f"N2: Ctrl+click on the {k} puts {n} {item} into its {inv}",
               f"{inv} {v0} -> {v1}, main {m0} -> {m1}, {texts}, slots sent {len(live_lib.of_type(msgs, 'slots'))}")
    m0 = main("iron-plate")
    msgs = fast("locomotive", "iron-plate", 10)
    texts = [m["text"] for m in live_lib.of_type(msgs, "msg")]
    live_lib.report(main("iron-plate") == m0 and any("Can't put" in t for t in texts),
           "N2: a locomotive refuses plates (fuel only) and nothing leaves the inventory", f"main {m0} -> {main('iron-plate')}, {texts}")
    for k, inv, n in (("car", "car_trunk", 50), ("cargo-wagon", "cargo_wagon", 50), ("spidertron", "spider_trunk", 20)):
        m0 = main("iron-plate")
        fast(k)
        live_lib.report(count(k, inv, "iron-plate") == 0 and main("iron-plate") - m0 == n,
               f"N2: Ctrl+click on the {k} with an empty hand takes its {inv} out",
               f"main {m0} -> {main('iron-plate')}, left {count(k, inv, 'iron-plate')}")
    live_lib.report(count("car", "fuel", "wood") == 10 and count("car", "car_ammo", "firearm-magazine") == 10,
           "N2: and leaves the car's fuel and ammo where they are",
           f"fuel {count('car', 'fuel', 'wood')} wood, ammo {count('car', 'car_ammo', 'firearm-magazine')} magazines")
    w0 = main("wood")
    msgs = fast("locomotive")
    texts = [m["text"] for m in live_lib.of_type(msgs, "msg")]
    live_lib.report(count("locomotive", "fuel", "wood") == 5 and main("wood") == w0,
           "N2: Ctrl+click on a locomotive with an empty hand takes nothing (no trunk; its fuel stays)",
           f"fuel 5 -> {count('locomotive', 'fuel', 'wood')}, main wood {w0} -> {main('wood')}, {texts}")
    # Burners whose fuel 2.1 hands out as inventory 1 (defines.inventory.chest is fuel too) or as their output
    # inventory (a burner drill's): an empty hand takes nothing from them either (/f3d-perf fast_take).
    burners = [("boiler", x - 8.5, y + 10), ("burner-mining-drill", x - 3, y + 10), ("burner-inserter", x + 0.5, y + 10.5)]
    live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {x - 3}, {y + 7} }})")
    lua = "local c = storage.f3d.puppet local out = {} "
    for name, bx, by in burners:
        lua += (f'local e = c.surface.create_entity({{ name = "{name}", position = {{ {bx}, {by} }}, force = c.force, raise_built = true }}) '
                "if e then e.get_fuel_inventory().insert({ name = 'wood', count = 5 }) end "
                'out[#out + 1] = e and (e.unit_number .. " " .. e.position.x .. " " .. e.position.y) or "0 0 0" ')
    vals = live_lib.mod_lua(lua + 'rcon.print(table.concat(out, " "))').split()
    c.pump(0.6, every=hello)
    for i, (name, _bx, _by) in enumerate(burners):
        if 3 * i + 2 >= len(vals) or not int(float(vals[3 * i])):
            live_lib.report(False, f"N2: a {name} built for the empty-hand Ctrl+click", str(vals))
            continue
        u = int(float(vals[3 * i]))
        ents[name] = (u, float(vals[3 * i + 1]), float(vals[3 * i + 2]))
        w0 = main("wood")
        msgs = fast(name)
        texts = [m["text"] for m in live_lib.of_type(msgs, "msg")]
        # (get_entity_by_unit_number finds vehicles and units, not buildings.)
        left = live_lib.mod_lua(f"local n = -1 for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = '{name}', "
                       f"position = {{ {ents[name][1]}, {ents[name][2]} }}, radius = 0.5 }})) do "
                       "if e.unit_number == " + str(u) + " then n = e.get_fuel_inventory().get_item_count('wood') end end rcon.print(n)")
        # (A burner may have taken one into its fire meanwhile: the drill burns with nothing to mine.)
        live_lib.report(left in ("4", "5") and main("wood") == w0, f"N2: Ctrl+click on a {name} with an empty hand leaves its fuel",
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
    vals = live_lib.mod_lua(lua + 'rcon.print(table.concat(out, " "))').split()
    live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {x + 6}, {y + 7} }})")
    c.pump(0.6, every=hello)
    for i, (name, _hx, _hy, inv, item) in enumerate(holders):
        if 3 * i + 2 >= len(vals) or not int(float(vals[3 * i])):
            live_lib.report(False, f"N2: a {name} built for the empty-hand Ctrl+click", str(vals))
            continue
        u = int(float(vals[3 * i]))
        ents[name] = (u, float(vals[3 * i + 1]), float(vals[3 * i + 2]))
        total = lambda: live_lib.mod_lua(f"rcon.print(storage.f3d.puppet.get_item_count('{item}'))")
        t0 = total()
        msgs = fast(name)
        left = live_lib.mod_lua(f"local n = -1 for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = '{name}', "
                       f"position = {{ {ents[name][1]}, {ents[name][2]} }}, radius = 0.5 }})) do "
                       f"if e.unit_number == {u} then n = e.get_inventory(defines.inventory.{inv}).get_item_count('{item}') end end rcon.print(n)")
        t1 = total()
        live_lib.report(left == "0" and t0.isdigit() and t1.isdigit() and int(t1) - int(t0) >= 2,  # (2.1.24 counted 30 -> 32 once: into the ammo slots)
               f"N2: Ctrl+click on a {name} with an empty hand takes its {item}, as before",
               f"left {left}, the character's {t0} -> {t1}, {[m['text'] for m in live_lib.of_type(msgs, 'msg')]}")

    # --- N3: the vehicle's guns while the character sits in it ---
    def enter(k, dx=0.0, dy=2.5):
        u, ex, ey = ents[k]
        live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {ex + dx}, {ey + dy} }})")
        c.pump(0.3, every=hello)
        c.last.pop("guns", None)
        c.send({"t": "enter"})
        msgs = c.pump(1.5, every=hello)
        inside = live_lib.mod_lua("local v = storage.f3d.puppet.vehicle rcon.print(v and v.unit_number or 0)")
        return inside == str(u), msgs

    def last_guns(msgs):
        g = live_lib.of_type(msgs, "guns")
        return g[-1] if g else c.last.get("guns") or {}

    ok, msgs = enter("car")
    g = last_guns(msgs)
    l = g.get("l") or []
    live_lib.report(ok and g.get("v") == ents["car"][0] and g.get("sel") == 1 and len(l) == 1
           and l[0][:3] == ["vehicle-machine-gun", "firearm-magazine", 10] and l[0][4] == 10 and l[0][3] > 0,
           "N3: in the car `guns` is the car's: its machine gun over its 10 magazines, rounds and magazine size, sel 1, v the car",
           f"in {ok}, {g}")
    live_lib.report(c.me and c.me.get("v") == ents["car"][0], "N3: and me says the character sits in it (v)", str(c.me and c.me.get("v")))
    # move with role vammo: a stack from the main inventory into the car's ammo.
    slot = live_lib.mod_lua("local m = storage.f3d.puppet.get_main_inventory() for i = 1, #m do "
                   "if m[i].valid_for_read and m[i].name == 'firearm-magazine' then rcon.print(i) return end end rcon.print(0)")
    a0 = count("car", "car_ammo", "firearm-magazine")
    c.send({"t": "move", "from": "main", "fi": int(slot) if slot.isdigit() else 0, "to": "vammo", "ti": 1, "n": 5})
    msgs = c.pump(1.0, every=hello)
    g = last_guns(msgs)
    a1 = count("car", "car_ammo", "firearm-magazine")
    live_lib.report(a1 - a0 == 5 and (g.get("l") or [[0, 0, 0]])[0][2] == a1,
           "N3: move to role vammo puts 5 magazines into the car's ammo, and guns follows", f"car ammo {a0} -> {a1}, {g.get('l')}")
    # shoot: does the character's shooting_state fire the car's gun? An enemy chest under the aim point.
    rounds = lambda: live_lib.mod_lua(f"local e = game.get_entity_by_unit_number({ents['car'][0]}) local s = e.get_inventory(defines.inventory.car_ammo)[1] "
                             "local ch = storage.f3d.puppet.get_inventory(defines.inventory.character_ammo)[1] "
                             "rcon.print((s.valid_for_read and (s.count * 10 + s.ammo - 10) or 0) .. ' ' .. "
                             "(ch.valid_for_read and (ch.count * 10 + ch.ammo - 10) or 0))")
    chest = lambda: live_lib.mod_lua(f"local t for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'wooden-chest', force = 'enemy', "
                            f"position = {{ {ents['enemy-chest'][1]}, {ents['enemy-chest'][2]} }}, radius = 0.6 }})) do t = e end "
                            "rcon.print(t and t.health or 'gone')")
    r0, h0 = rounds(), chest()
    _u, cx_, cy_ = ents["enemy-chest"]
    shoot = {"t": "shoot", "m": 1, "x": fx(cx_), "y": fx(cy_)}
    msgs = c.pump(2.0, every=(0.2, shoot))
    c.send({"t": "shoot", "m": -1})
    msgs += c.pump(0.5, every=hello)
    r1, h1 = rounds(), chest()
    shots = live_lib.of_type(msgs, "shot")
    texts = [m["text"] for m in live_lib.of_type(msgs, "msg")]
    fired = r0.split()[:1] != r1.split()[:1]
    print(f"  N3: shoot (m 1, at an enemy chest 9 tiles off) from inside the car for 2 s: car, character rounds {r0} -> {r1}, "
          f"chest {h0} -> {h1}, `shot` {len(shots)} {[s.get('g') for s in shots[:2]]}, "
          f"me.sh {[m.get('sh') for m in live_lib.of_type(msgs, 'me')][-3:]}, msgs {texts}")
    live_lib.report(fired, "N3: `shoot` fires the car's gun for the player-less character (its rounds go down)", f"{r0} -> {r1}")
    # The bridge's side (/f3d-perf vehicle_ammo): me.sh follows the car's ammo, the car's shots come in `ts` (the client's
    # turrets.gd draws them from the car's gun) and no `shot` from the character's own guns; no "Out of ammo" while the
    # car has some.
    car_u, me_u = ents["car"][0], (c.me or {}).get("u")
    ts_shots = sum(r[2] for m in live_lib.of_type(msgs, "ts") for r in (m.get("l") or []) if r and r[0] == car_u)
    live_lib.report(fired and any(m.get("sh") == 1 for m in live_lib.of_type(msgs, "me")), "N3: me.sh is 1 while the car's gun fires",
           f"me with sh 1: {sum(m.get('sh') == 1 for m in live_lib.of_type(msgs, 'me'))} of {len(live_lib.of_type(msgs, 'me'))}")
    live_lib.report(fired and ts_shots > 0 and not [s for s in shots if s.get("u") == me_u],
           "N3: the car's shots come in ts (its unit, shots counted), no `shot` from the character's guns",
           f"ts shots {ts_shots}, shot {[(s.get('u'), s.get('g')) for s in shots[:3]]}")
    live_lib.report("Out of ammo" not in texts, "N3: no Out of ammo while the car has ammo", str(texts))
    # m 0 (Factorio's Space: the nearest enemies) from the car: the enemy car 6 tiles off.
    r0 = rounds()
    near = {"t": "shoot", "m": 0, "x": fx(ents["car"][1]), "y": fx(ents["car"][2])}
    msgs = c.pump(2.0, every=(0.2, near))
    c.send({"t": "shoot", "m": -1})
    msgs += c.pump(0.5, every=hello)
    r1 = rounds()
    fired0 = r0.split()[:1] != r1.split()[:1]
    ts0 = sum(r[2] for m in live_lib.of_type(msgs, "ts") for r in (m.get("l") or []) if r and r[0] == car_u)
    print(f"  N3: shoot m 0 from inside the car for 2 s: car, character rounds {r0} -> {r1}, ts shots {ts0}, "
          f"me with sh 1: {sum(m.get('sh') == 1 for m in live_lib.of_type(msgs, 'me'))} of {len(live_lib.of_type(msgs, 'me'))}")
    live_lib.report(not fired0 or any(m.get("sh") == 1 for m in live_lib.of_type(msgs, "me")),
           "N3: shoot m 0 from the car: when the game fires the car's gun at the nearest enemy, me.sh says so",
           "fires" if fired0 else "the game didn't fire (m 0 printed)")
    # Out of the car the character's own guns come back.
    c.last.pop("guns", None)
    c.send({"t": "enter"})
    msgs = c.pump(1.5, every=hello)
    g = last_guns(msgs)
    out = live_lib.mod_lua("rcon.print(storage.f3d.puppet.vehicle and 'in' or 'out')")
    live_lib.report(out == "out" and g and "v" not in g and (g.get("l") or [[""]])[0][0] == "pistol",
           "N3: out of the car the character's guns come back (no v, the pistol)", f"{out}, {g}")
    # A tank: three guns, gun 2 its cannon.
    ok, msgs = enter("tank", 0, 3.0)
    c.send({"t": "gun", "i": 2})
    msgs += c.pump(1.0, every=hello)
    g = last_guns(msgs)
    sel = live_lib.mod_lua(f"rcon.print(game.get_entity_by_unit_number({ents['tank'][0]}).selected_gun_index)")
    order = live_lib.mod_lua("local o = {} for _, gp in ipairs(prototypes.entity['tank'].indexed_guns) do o[#o + 1] = gp.name end "
                    "rcon.print(table.concat(o, ' '))").split()
    names = [r[0] for r in g.get("l") or []]
    # 2.1's tank: cannon, machine gun, flamethrower (indexed_guns); the magazines put in went to the machine gun's slot.
    mg = order.index("tank-machine-gun") if "tank-machine-gun" in order else 0
    live_lib.report(ok and sel == "2" and g.get("sel") == 2 and g.get("v") == ents["tank"][0] and names == order
           and sorted(names) == ["tank-cannon", "tank-flamethrower", "tank-machine-gun"]
           and (g.get("l") or [])[mg:mg + 1] and g["l"][mg][1] == "firearm-magazine",
           "N3: a tank's three guns in indexed_guns' order, its magazines under the machine gun, gun i=2 selects the second "
           "(the vehicle's selected_gun_index)", f"in {ok}, sel {sel}, indexed_guns {order}, {g}")
    c.send({"t": "enter"})
    c.pump(1.0, every=hello)
    ok, msgs = enter("spidertron", 0, 2.5)
    g = last_guns(msgs)
    l = g.get("l") or []
    live_lib.report(ok and g.get("v") == ents["spidertron"][0] and len(l) == 4 and l[0][1] == "rocket" and l[0][2] == 10,
           "N3: a spidertron's four rocket launchers over its spider_ammo (the 10 rockets)", f"in {ok}, {g}")
    c.send({"t": "enter"})
    c.pump(1.0, every=hello)

    # --- N4: repair packs on vehicles ---
    live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {x}, {y} }}) for _, u in pairs({{ {ents['car'][0]}, {ents['cargo-wagon'][0]}, {ents['enemy-car'][0]} }}) do "
            "local e = game.get_entity_by_unit_number(u) e.health = e.max_health - 150 end")
    c.pump(0.5, every=hello)

    def health(k):
        out = live_lib.mod_lua(f"local e = game.get_entity_by_unit_number({ents[k][0]}) rcon.print(e.health .. ' ' .. e.max_health)")
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
        rp = [m for m in live_lib.of_type(msgs, "me") if m.get("rp") == 1]
        hp_lists = [m["l"] if isinstance(m["l"], list) else [] for m in live_lib.of_type(msgs, "hp")]
        bars = [dict(zip(l[::2], l[1::2])).get(ents[k][0]) for l in hp_lists]
        texts = [m["text"] for m in live_lib.of_type(msgs, "msg")]
        print(f"  N4: {k}: {len(hp_lists)} hp messages, the last {hp_lists[-2:]}, rp from tick "
              f"{[m.get('k') for m in rp][:1]} to {[m.get('k') for m in rp][-1:]}")
        live_lib.report(h1 == mx and h0 < mx, f"N4: `repair` mends the damaged {k} to full", f"{h0} -> {h1} of {mx}, {texts}")
        live_lib.report(rp and rp[-1].get("rx") == target(k)["x"], f"N4: me says the character repairs the {k} (rp, rx)", str(rp[-1:]))
        live_lib.report(any(b is not None for b in bars), f"N4: the {k}'s bar is in hp while it mends", str(bars[-3:]))
    e0, _ = health("enemy-car")
    c.send(dict(target("enemy-car"), t="repair", item="repair-pack"))
    c.pump(1.0, every=hello)
    c.send({"t": "repair"})
    live_lib.report(health("enemy-car")[0] == e0, "N4: another force's car isn't mended", f"{e0} -> {health('enemy-car')[0]}")

    # Clean up: everything built, the rails, what was put in the inventory.
    live_lib.mod_lua("local c = storage.f3d.puppet if c.vehicle then c.driving = false end")
    live_lib.destroy_units([v[0] for k, v in ents.items() if not k.startswith("enemy")])
    live_lib.mod_lua(f"local c = storage.f3d.puppet local e = game.get_entity_by_unit_number({ents['enemy-car'][0]}) if e then e.destroy() end "
            f"for _, r in pairs(c.surface.find_entities_filtered({{ area = {{ {{ {x - 14}, {y - 14} }}, {{ {x + 14}, {y + 7} }} }}, "
            "name = { 'straight-rail', 'car', 'tank', 'spidertron', 'locomotive', 'cargo-wagon', 'wooden-chest' } })) do r.destroy() end "
            "local m = c.get_main_inventory() for _, it in pairs({ { 'wood', 40 }, { 'firearm-magazine', 40 }, { 'rocket', 20 }, "
            "{ 'iron-plate', 200 }, { 'repair-pack', 5 } }) do m.remove({ name = it[1], count = it[2] }) end rcon.print('ok')")
    if len(back.split()) == 2:
        bx, by = (float(v) for v in back.split())
        live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {bx}, {by} }})")
        live_lib.watch_around(c, hello, bx, by)


def check_map_info(c, hello):
    """The map and hover information (G12, G20): `hinfo` for a powered beacon with two speed modules
    and the assembler it reaches (LuaEntity.effects, get_module_inventory, get_beacons,
    get_beacon_effect_receivers, the beacon's distribution_effectivity), and `terr` naming its surface."""
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "map info: no clean spot found", live_lib.SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    out = live_lib.mod_lua(f"""
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
        live_lib.report(False, "map info: the beacon and assembler were built", out)
        return
    c.pump(2.0, every=hello)  # powered up, the beacon's effect reaches the assembler
    fx = lambda v: int(round(v * 256))
    c.send({"t": "hinfo", "q": 11, "u": int(au), "p": 0, "x": fx(ax), "y": fx(ay)})
    c.send({"t": "hinfo", "q": 12, "u": int(bu), "p": 0, "x": fx(bx), "y": fx(by)})
    msgs = c.pump(1.5, every=hello)
    hi = {m["q"]: m for m in live_lib.of_type(msgs, "hinfo")}
    ma, mb = hi.get(11, {}), hi.get(12, {})
    live_lib.report(ma.get("b") == 1 and ma.get("eff", {}).get("sp", 0) > 0 and ma.get("eff", {}).get("co", 0) > 0,
           "hinfo: an assembler reached by a beacon: the beacon count and its effects (G12)", str(ma))
    live_lib.report(mb.get("m") == [["speed-module", 2]] and mb.get("n") == 1 and mb.get("de") == 1500 and mb.get("eff", {}).get("sp", 0) > 0,
           "hinfo: the beacon's modules, the machines it reaches, its effectivity and what it hands on (G12)", str(mb))
    live_lib.destroy_units([int(au), int(bu), int(pu)])
    live_lib.mod_lua('package.loaded["__factorio-3d-bridge__/scripts/planets.lua"].territories_soon()')
    msgs = c.pump(1.5, every=hello)
    terr = live_lib.of_type(msgs, "terr")
    si = live_lib.mod_lua("rcon.print(storage.f3d.puppet.surface.index)")
    live_lib.report(bool(terr) and str(terr[-1].get("si")) == si, "terr names the surface its territories are on (G20)",
           f"{terr[-1:] if terr else 'no terr'} on surface {si}")
