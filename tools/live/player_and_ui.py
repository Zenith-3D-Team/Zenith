"""Player walking, pickup, inventory input, gear, UI parity, info, and HUD live checks."""
from __future__ import annotations

import json
import math
import time

from . import live_lib


def check_build_marks(c, hello, x, y):
    """What hover and the build cursor draw (eprops' overlay), and undergrounds built like a player's:
    the second of a pair is the exit, whose direction is the way items go."""
    ep = c.eprops or {}
    over = lambda name: (ep.get(c.proto_id(name)) or [0, 0, 0, {}])[3:4] or [{}]
    ins, robo, drill, engine = (over(n)[0] for n in ("long-handed-inserter", "roboport", "electric-mining-drill", "steam-engine"))
    live_lib.report(ins.get("ip") == [0, -2] and ins.get("id") == [0, 2.2] and robo.get("lr") == 25 and robo.get("cr") == 55
           and drill.get("mr") == 2.49 and drill.get("vp") == [0, -1.85] and drill.get("fo") == 1
           and sorted(map(tuple, engine.get("fb", []))) == [(0, -2, 0, "b"), (0, 2, 8, "b")],
           "eprops overlay: inserter_pickup/drop_position, logistic/construction_radius, mining_drill_radius, "
           "vector_to_place_result, fluidbox_prototypes pipe_connections", f"{ins} {robo} {drill} {engine}")
    live_lib.mod_lua('storage.f3d.puppet.insert({ name = "underground-belt", count = 8 })')
    fx = lambda v: int(round(v * 256))
    ug = c.proto_id("underground-belt")
    bx, by = math.floor(x), math.floor(y)
    # Each pair on its own line north of the test entities, within reach: [direction, first, second].
    pairs = [(0, (-6, -6), (-6, -9)), (8, (-4, -9), (-4, -6)), (4, (-1, -7), (2, -7)), (12, (5, -9), (2, -9))]
    built, msgs = [], []
    for d, *ends in pairs:
        for k, (dx, dy) in enumerate(ends):
            px, py = bx + dx + 0.5, by + dy + 0.5
            c.send({"t": "build", "item": "underground-belt", "x": fx(px), "y": fx(py), "d": d})
            msgs += c.pump(0.3, every=hello)
            built.append((d, k, px, py))
    msgs += c.pump(1.0, every=hello)
    adds = {(m["e"][2], m["e"][3]): m["e"] for m in live_lib.of_type(msgs, "add") if m["e"][1] == ug}
    out = live_lib.mod_lua("local o = {} for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({ name = 'underground-belt', "
                  f"area = {{ {{ {bx - 8}, {by - 10} }}, {{ {bx + 8}, {by - 5} }} }} }})) do "
                  "o[#o + 1] = e.position.x .. ',' .. e.position.y .. ',' .. e.direction .. ',' .. e.belt_to_ground_type end "
                  "rcon.print(table.concat(o, ' '))")
    game = {(float(a), float(b)): (int(d), t) for a, b, d, t in (v.split(",") for v in out.split())}
    ok = len(game) == 8
    for d, k, px, py in built:
        want = ("input", "output")[k]
        sent = adds.get((fx(px), fx(py)))
        ok = ok and game.get((px, py)) == (d, want) and sent is not None and len(sent) > 5 and sent[5].get("u") == want[0]
    live_lib.report(ok, "undergrounds built in all four directions: entrance then exit (create_entity type), both facing the "
           "way items go, sent as extra.u", f"{out} | sent {[a[2:] for a in adds.values()]}")
    # J23: R on the east pair's entrance turns both ends (the game flips a pair together and tells of
    # only the one turned): both come back turned, facing west, entrance and exit swapped.
    east_in, east_out = adds.get((fx(bx - 0.5), fx(by - 6.5))), adds.get((fx(bx + 2.5), fx(by - 6.5)))
    if east_in and east_out:
        c.send({"t": "rotate", "u": east_in[0], "p": ug, "x": east_in[2], "y": east_in[3], "rev": 0})
        turned = {m["e"][0]: (m["e"][4], m["e"][5].get("u")) for m in live_lib.of_type(c.pump(1.0, every=hello), "upd")
                  if m["e"][1] == ug and len(m["e"]) > 5}
        live_lib.report(turned.get(east_in[0]) == (12, "o") and turned.get(east_out[0]) == (12, "i"),
               "J23: R on an underground's entrance sends both ends turned (facing back, entrance and exit swapped)", str(turned))
    else:
        live_lib.report(False, "J23: the east underground pair to turn", str(list(adds)))
    live_lib.mod_lua("for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({ name = 'underground-belt', "
            f"area = {{ {{ {bx - 8}, {by - 10} }}, {{ {bx + 8}, {by - 5} }} }} }})) do e.destroy({{ raise_destroy = true }}) end")


def check_ui_parity(c, hello):
    """Factorio's world controls and entity windows (ui_actions.lua, entity_ui.lua)."""
    ug = c.proto_id("underground-belt")
    pole = c.proto_id("small-electric-pole")
    ep = c.eprops or {}
    live_lib.report(ep.get(ug, [0])[0] == 5 and ep.get(pole, [0, 0, 0])[1] == 7.5 and ep.get(pole, [0, 0, 0])[2] == 2.5,
           "eprops: underground reach (max_underground_distance), pole wire reach and supply area", f"{ep.get(ug)} {ep.get(pole)}")
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "ui parity: no clean spot found")
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    fx = lambda v: int(round(v * 256))
    out = live_lib.mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local x, y = {x}, {y}
local function put(name, dx, dy, d)
  local e = s.create_entity({{ name = name, position = {{ x + dx, y + dy }}, force = c.force, direction = d, raise_built = true }})
  return e and (e.unit_number .. " " .. e.position.x .. " " .. e.position.y) or "0 0 0"
end
local out = {{}}
out[#out + 1] = put("wooden-chest", 2.5, 0.5)
out[#out + 1] = put("assembling-machine-1", -3.5, 3.5)
out[#out + 1] = put("chemical-plant", 0.5, 3.5)
out[#out + 1] = put("fast-inserter", 2.5, -2.5)
out[#out + 1] = put("splitter", 5, -2.5)
out[#out + 1] = put("power-switch", -4, -3)
out[#out + 1] = put("gun-turret", 6, 3)
out[#out + 1] = put("small-electric-pole", -1.5, -1.5)
c.insert({{ name = "iron-plate", count = 50 }})
c.get_main_inventory().insert({{ name = "firearm-magazine", count = 10 }})
rcon.print(table.concat(out, " "))
""".replace("\n", " "))
    names = ["wooden-chest", "assembling-machine-1", "chemical-plant", "fast-inserter", "splitter", "power-switch",
             "gun-turret", "small-electric-pole"]
    vals = out.split()
    if len(vals) != 3 * len(names) or "0" in vals[0::3]:
        live_lib.report(False, "ui parity: building the test entities", out)
        return
    units = [int(v) for v in vals[0::3]]
    chest, asm_a, asm_b, ins, spl, sw, turret, pl = units
    pos = {u: (float(vals[3 * i + 1]), float(vals[3 * i + 2]), names[i]) for i, u in enumerate(units)}
    c.pump(1.0, every=hello)
    ident = lambda u: {"u": u, "p": c.proto_id(pos[u][2]), "x": fx(pos[u][0]), "y": fx(pos[u][1])}
    count_in = lambda u, item: int(live_lib.mod_lua(
        f'local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({{ force = c.force }})) do '
        f'if e.unit_number == {u} then rcon.print(e.get_item_count("{item}")) return end end rcon.print(-1)') or -1)

    # Z: one item into the chest under the mouse, then onto the ground.
    c.send({"t": "drop", "item": "iron-plate", "x": fx(pos[chest][0]), "y": fx(pos[chest][1])})
    c.pump(0.5, every=hello)
    live_lib.report(count_in(chest, "iron-plate") == 1, "drop (Z) over a chest inserts one (LuaEntity.can_insert / insert)")
    c.send({"t": "drop", "item": "iron-plate", "x": fx(x - 2), "y": fx(y)})
    c.pump(0.5, every=hello)
    out = live_lib.mod_lua(f"rcon.print(storage.f3d.puppet.surface.count_entities_filtered({{ type = 'item-entity', position = {{ {x - 2}, {y} }}, radius = 1.5 }}))")
    live_lib.report(out not in ("", "0"), "drop (Z) over nothing: spill_item_stack{allow_belts, max_radius} puts it on the ground", out)

    # Ctrl+click: a stack in (half), everything out.
    c.send({"t": "fast", **ident(chest), "item": "iron-plate", "half": 1})
    c.pump(0.5, every=hello)
    n_in = count_in(chest, "iron-plate")
    c.send({"t": "fast", **ident(chest), "half": 0})
    c.pump(0.5, every=hello)
    live_lib.report(n_in > 1 and count_in(chest, "iron-plate") == 0, "fast transfer: half a stack in, then everything out", f"{n_in} went in")

    # Shift+right / Shift+left: an assembler's recipe copied to another (copy_settings); H flips a
    # chemical plant (assembler 1 can't be flipped: the mod says so).
    live_lib.mod_lua(f'for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = "assembling-machine-1" }})) do '
            f'if e.unit_number == {asm_a} then e.set_recipe("iron-gear-wheel") end end')
    asm_c = int(live_lib.mod_lua(f'local c = storage.f3d.puppet local e = c.surface.create_entity({{ name = "assembling-machine-1", '
                        f'position = {{ {x - 3.5}, {y + 8.5} }}, force = c.force }}) rcon.print(e and e.unit_number or 0)') or 0)
    pos[asm_c] = (x - 3.5, y + 8.5, "assembling-machine-1")
    c.send({"t": "paste_settings", "f": [ident(asm_a)[k] for k in ("u", "p", "x", "y")], **ident(asm_c)})
    c.send({"t": "flip", **ident(asm_b), "v": 0})
    c.send({"t": "flip", **ident(asm_c), "v": 0})
    msgs = c.pump(0.8, every=hello)
    out = live_lib.mod_lua(f'local o = {{}} for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ force = "player" }})) do '
                  f'if e.unit_number == {asm_c} then local r = e.get_recipe() o[1] = r and r.name or "none" end '
                  f'if e.unit_number == {asm_b} then o[2] = tostring(e.mirroring) end end rcon.print(table.concat(o, " "))')
    live_lib.report(out == "iron-gear-wheel true", "paste_settings (LuaEntity.copy_settings) and flip (mirroring of a chemical plant)", out)
    live_lib.report(any(m["text"] == "This can't be flipped" for m in live_lib.of_type(msgs, "msg")), "flipping an assembler 1 is refused")

    # Alt-mode lists the assemblers' recipes.
    c.send({"t": "alt", "on": 1})
    msgs = c.pump(2.5, every=hello)
    icons = [r for m in live_lib.of_type(msgs, "ai") for r in m["l"]]
    live_lib.report([asm_a, "recipe", "iron-gear-wheel"] in icons, "alt: Alt-mode icons (get_recipe, filters)", str(icons[:6]))
    live_lib.report(all(r[0] != asm_b for r in icons) and all(isinstance(r[2], str) and not r[2].startswith("[") for r in icons),
           "alt: nothing over a machine without a recipe (the chemical plant), every icon a name", str(icons[:6]))
    c.send({"t": "alt", "on": 0})
    check_build_marks(c, hello, x, y)

    # The clipboard: copy the two assemblers, paste them further along, Alt+B makes a blueprint.
    area = {"x1": fx(x - 6), "y1": fx(y + 1), "x2": fx(x + 3), "y2": fx(y + 6)}
    c.send({"t": "copy", **area, "cut": 0, "bp": 0})
    msgs = c.pump(1.0, every=hello)
    clip = live_lib.of_type(msgs, "clip")
    live_lib.report(bool(clip) and len(clip[-1]["l"]) >= 2, "copy: create_blueprint in a script inventory, the clipboard's entities",
           str(clip[-1]["l"][:4]) if clip else "no clip")
    c.send({"t": "paste", "x": fx(x - 1), "y": fx(y + 12), "d": 0})
    msgs = c.pump(1.0, every=hello)
    ghost = c.proto_id("entity-ghost")
    ghosts = [m["e"] for m in live_lib.of_type(msgs, "add") if m["e"][1] == ghost]
    live_lib.report(len(ghosts) >= 2, "paste: the clipboard's ghosts (build_blueprint)", f"{len(ghosts)} ghosts")
    c.send({"t": "copy", **area, "cut": 0, "bp": 1})
    msgs = c.pump(1.0, every=hello)
    live_lib.report(any(m["text"] == "Blueprint added to the inventory" for m in live_lib.of_type(msgs, "msg")), "Alt+B area: a blueprint in the main inventory")
    c.send({"t": "build", "item": "wooden-chest", "x": fx(x + 9.5), "y": fx(y + 9.5), "d": 0, "ghost": 1})
    msgs = c.pump(1.0, every=hello)
    live_lib.report(any(m["e"][1] == ghost and m["e"][5].get("gh") == c.proto_id("wooden-chest") for m in live_lib.of_type(msgs, "add")),
           "build ghost = 1: an entity ghost without the item")

    # Chat and statistics.
    c.send({"t": "chat", "text": "live check says hi"})
    c.send({"t": "stats", "kind": "item", "prec": 2})
    c.send({"t": "stats", "kind": "kill", "prec": 8})
    c.send({"t": "stats", "kind": "electric", "prec": 1, **ident(pl)})
    msgs = c.pump(1.5, every=hello)
    live_lib.report(any(m["text"] == "live check says hi" for m in live_lib.of_type(msgs, "chat")), "chat: game.print and the echo")
    st = {m["kind"]: m for m in live_lib.of_type(msgs, "stats")}
    live_lib.report({"item", "kill", "electric"} <= set(st) and isinstance(st["electric"].get("st"), (list, dict)),
           "stats: item, kill and electric network statistics (LuaFlowStatistics), the accumulators' storage (st)",
           " | ".join(f"{k}: {list(v['l'])[:3]}" for k, v in st.items()))
    ef = st.get("electric", {}).get("ef")
    live_lib.report(isinstance(ef, list) and len(ef) == 6, "stats: the electric network's last update (flow_last_tick) for the summary bars",
           f"ef {ef}")

    # Entity windows: inserter, splitter, power switch, turret, chest bar.
    def screen(u, cmd=None):
        c.send({"t": "open", **ident(u)})
        if cmd:
            c.send(cmd)
        msgs = c.pump(1.0, every=hello)
        g = [m for m in live_lib.of_type(msgs, "gui") if m.get("u") == u and not m.get("closed")]
        return g[-1] if g else {}

    g = screen(ins, {"t": "set_inserter", "u": ins, "f": ["iron-plate"], "m": "blacklist", "use": 1, "st": 1})
    live_lib.report(g.get("kind") == "inserter" and g.get("ins", {}).get("f", [""])[0] == "iron-plate" and g["ins"].get("m") == "blacklist"
           and g["ins"].get("st") == 1, "inserter screen: filters, mode, use_filters, stack size override", str(g.get("ins")))
    g = screen(spl, {"t": "set_splitter", "u": spl, "i": "left", "o": "right", "f": "iron-plate"})
    live_lib.report(g.get("kind") == "splitter" and g.get("spl") == {"i": "left", "o": "right", "f": "iron-plate"},
           "splitter screen: priorities and filter", str(g.get("spl")))
    g = screen(sw, {"t": "set_switch", "u": sw, "on": 1})
    live_lib.report(g.get("kind") == "switch" and g.get("sw") == 1, "power switch screen: power_switch_state", str(g.get("sw")))
    g = screen(turret, {"t": "put", "u": turret, "item": "firearm-magazine", "n": 5})
    live_lib.report(g.get("kind") == "turret" and "turret_ammo" in g.get("slots", {}) and g["inv"].get("turret_ammo"),
           "turret screen: its ammo inventory (defines.inventory.turret_ammo)", str(g.get("inv")))
    g = screen(chest, {"t": "set_bar", "u": chest, "n": 4})
    live_lib.report(g.get("kind") == "container" and g.get("bar") == 4, "chest limit bar: get_bar / set_bar", str(g.get("bar")))
    g = screen(pl)
    live_lib.report(g.get("kind") == "pole", "a pole opens (for its network statistics)", str(g.get("kind")))
    car = int(live_lib.mod_lua(f'local c = storage.f3d.puppet local e = c.surface.create_entity({{ name = "car", position = {{ {x - 6}, {y - 6} }}, '
                      f'force = c.force }}) rcon.print(e and e.unit_number or 0)') or 0)
    pos[car] = (x - 6, y - 6, "car")
    g = screen(car)
    live_lib.report(g.get("kind") == "vehicle" and {"fuel", "trunk", "car_ammo"} <= set(g.get("slots", {})),
           "a car opens with its fuel, trunk and ammo (car_trunk, car_ammo)", str(sorted(g.get("slots", {}))))
    c.send({"t": "close"})
    c.send({"t": "inv_filter", "i": 10, "item": "iron-plate"})
    msgs = c.pump(1.0, every=hello)
    sl = live_lib.of_type(msgs, "slots")
    live_lib.report(bool(sl) and [10, "iron-plate"] in sl[-1].get("fl", []), "inv_filter: a main inventory slot filter (LuaInventory.set_filter / get_filter)",
           str(sl[-1].get("fl") if sl else None))
    c.send({"t": "inv_filter", "i": 10, "item": ""})
    c.pump(0.5, every=hello)
    live_lib.destroy_units([car])
    live_lib.mod_lua(f"local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({{ area = {{ {{ {x - 10}, {y - 10} }}, {{ {x + 12}, {y + 16} }} }}, "
            "type = { 'entity-ghost', 'item-entity' } })) do e.destroy() end")
    live_lib.destroy_units([chest, asm_a, asm_b, asm_c, ins, spl, sw, turret, pl])
    c.pump(0.5, every=hello)


def check_triggers(c, hello):
    """Issue #7: 2.x unlocks red science by a trigger (craft a lab), and a character with no player
    is left out of the production statistics that set triggers off, so a lab hand-crafted through
    the bridge never unlocked it. crafting.lua records the character's finished crafts itself."""
    live_lib.mod_lua("local c = storage.f3d.puppet local f = c.force "
            "for _, n in pairs({'steam-power', 'electronics'}) do f.technologies[n].researched = true end "
            "f.technologies['automation-science-pack'].researched = false "
            "c.insert({ name = 'iron-gear-wheel', count = 10 }) c.insert({ name = 'electronic-circuit', count = 10 }) "
            "c.insert({ name = 'transport-belt', count = 4 })")
    before = live_lib.mod_lua("local c = storage.f3d.puppet rcon.print(c.force.get_item_production_statistics(c.surface).get_input_count('lab'))")
    c.send({"t": "craft", "recipe": "lab", "n": 1})
    c.pump(4.0, every=hello)
    out = live_lib.mod_lua("local c = storage.f3d.puppet local f = c.force "
                  "rcon.print(f.get_item_production_statistics(c.surface).get_input_count('lab') .. ' ' "
                  ".. tostring(f.technologies['automation-science-pack'].researched) .. ' ' "
                  ".. tostring(f.recipes['automation-science-pack'].enabled) .. ' ' .. c.get_item_count('lab'))").split()
    live_lib.report(len(out) == 4 and int(out[0]) == int(before or 0) + 1 and out[1:3] == ["true", "true"] and int(out[3]) >= 1,
           "a hand-crafted lab counts in the production statistics and unlocks red science (issue #7)",
           f"labs counted {before} -> {out[:1]}, researched and recipe {out[1:3]}, labs held {out[3:]}")


def check_research(c, hello):
    """K23: research finishing (`rdone`, research.lua). A technology of one level researched by script
    is named once, level 0, with the tick it finished in, and an `rs` follows; an infinite one names
    the level it finished, read against LuaTechnology.level before and after (the bridge takes the
    level read in the event as the next one). Both are undone afterwards."""
    picked = live_lib.mod_lua("local f = storage.f3d.puppet.force local one, inf = {}, {} "
                     "for name, t in pairs(f.technologies) do local p = t.prototype "
                     "if t.enabled and not p.hidden then "
                     "if not t.researched and p.max_level == p.level then one[#one + 1] = name end "
                     "if p.max_level == 4294967295 then inf[#inf + 1] = name end end end "
                     "table.sort(one) table.sort(inf) rcon.print((one[1] or '-') .. ' ' .. (inf[1] or '-'))").split()
    if len(picked) != 2 or picked[0] == "-":
        live_lib.report(False, "research: a technology of one level to research by script", str(picked))
        return
    one, inf = picked
    tech = 'storage.f3d.puppet.force.technologies["%s"]'
    c.pump(0.5, every=hello)
    live_lib.mod_lua(f"{tech % one}.researched = true")
    msgs = c.pump(1.5, every=hello, until=lambda m: m.get("t") == "rdone")
    msgs += c.pump(0.5, every=hello)
    done = live_lib.of_type(msgs, "rdone")
    named = [e for m in done for e in m["l"]]
    live_lib.report(named == [[one, 0]] and len(done) == 1 and isinstance(done[0].get("tick"), int),
           "rdone: a finished research named once, level 0, with its tick (on_research_finished)", str(done)[:300])
    after = msgs[msgs.index(done[0]) + 1:] if done else []
    live_lib.report(bool(live_lib.of_type(after, "rs")), "rdone: the research status (rs) follows it", str([m["t"] for m in after][:20]))
    live_lib.mod_lua(f"{tech % one}.researched = false")
    if inf == "-":
        print("INFO research: no infinite technology in this game, its level not checked")
        return
    before = live_lib.mod_lua(f"rcon.print({tech % inf}.level)")
    if not before.isdigit():
        live_lib.report(False, "research: an infinite technology's level", f"{inf}: {before}")
        return
    c.pump(0.5, every=hello)
    # Setting researched on an infinite technology researches its level (2.1's LuaTechnology); if that
    # raises nothing, writing the level ("the same as researching the technology to the previous level").
    how = "researched = true"
    tried = live_lib.mod_lua(f"local ok, err = pcall(function() {tech % inf}.researched = true end) rcon.print(tostring(ok) .. ' ' .. tostring(err))")
    msgs = c.pump(1.5, every=hello, until=lambda m: m.get("t") == "rdone")
    if not live_lib.of_type(msgs, "rdone"):
        how = "level = level + 1"
        live_lib.mod_lua(f"{tech % inf}.level = {int(before) + 1}")
        msgs += c.pump(1.5, every=hello, until=lambda m: m.get("t") == "rdone")
    msgs += c.pump(0.3, every=hello)
    now = live_lib.mod_lua(f"rcon.print({tech % inf}.level)")
    now = int(now) if now.isdigit() else -1
    named = [e for m in live_lib.of_type(msgs, "rdone") for e in m["l"]]
    live_lib.report(named == [[inf, int(before)]] and now == int(before) + 1,
           "rdone: an infinite research names the level it finished, its level goes on",
           f"{inf}: level {before} -> {now} by {how} ({tried}), rdone {named}")
    live_lib.mod_lua(f"{tech % inf}.level = {int(before)}")


def check_walk(c, hello):
    """B7: `walk` with an angle. The mod steps each tick in one of the two 8-way directions either side
    of it (puppet.lua angle_step); in the real game the path must follow the line within a few
    hundredths of a tile at the character's own speed, and slide along a wall in the way."""
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "walk: no clean spot found", live_lib.SPOT_WHY)
        return
    # The walks go up to 25 tiles from the spot, past clean_spot's square: whatever the map put
    # there (trees, rocks, cliffs, water) would turn the character aside and fail the path checks
    # on some maps and not others, so the ground 32 tiles round is cleared first. Each walk starts
    # from the spot again: one after another they used to end some 35 tiles out, past the cleared
    # ground, where water or trees stopped the wall check (it failed on every CI run since 0.1.2)
    # and nudged the angled path off its line (0.19 tiles on 0.2.0's CI).
    spot = live_lib.mod_lua("local c = storage.f3d.puppet local s = c.surface local p = c.position "
                   "local area = { { p.x - 32, p.y - 32 }, { p.x + 32, p.y + 32 } } "
                   "for _, e in pairs(s.find_entities_filtered({ area = area, type = { 'tree', 'simple-entity', 'cliff', 'fish' } })) do e.destroy() end "
                   "local tiles = {} for _, t in pairs(s.find_tiles_filtered({ area = area, collision_mask = 'water_tile' })) do "
                   "tiles[#tiles + 1] = { name = 'landfill', position = t.position } end "
                   "if #tiles > 0 then s.set_tiles(tiles) end rcon.print(p.x .. ' ' .. p.y)")
    c.pump(0.5, every=hello)

    def back():
        live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {spot.split()[0]}, {spot.split()[1]} }})")
        c.pump(0.4, every=hello)

    def walk(msg, seconds):
        msgs = c.pump(seconds, every=(0.15, msg))
        c.send({"t": "walk", "d": -1})
        c.pump(0.4, every=hello)
        return [m for m in live_lib.of_type(msgs, "me") if m["w"] == 1]

    def speed(mes):
        """Tiles a tick between the first and last walking `me`, and the straight line's length."""
        a, b = mes[2], mes[-1]
        dist = math.hypot(b["x"] - a["x"], b["y"] - a["y"]) / 256
        return dist / max(1, b["k"] - a["k"])

    straight = speed(walk({"t": "walk", "d": 4}, 1.5))
    back()
    diagonal = speed(walk({"t": "walk", "d": 2}, 1.5))
    back()
    live_lib.report(straight > 0.1 and abs(diagonal - straight) < 0.005, "walk: Factorio's character walks diagonally at its straight speed",
           f"{straight:.4f} and {diagonal:.4f} tiles a tick")
    a = 56  # 20.16 degrees east of north
    rad = a / 1000 * 2 * math.pi
    ux, uy = math.sin(rad), -math.cos(rad)
    mes = walk({"t": "walk", "d": 2, "a": a}, 3.0)
    if len(mes) < 20:
        live_lib.report(False, "walk: walking at an angle sends me", str(len(mes)))
        return
    x0, y0 = mes[0]["x"] / 256, mes[0]["y"] / 256
    side = [abs((m["x"] / 256 - x0) * uy - (m["y"] / 256 - y0) * ux) for m in mes]
    along = [(m["x"] / 256 - x0) * ux + (m["y"] / 256 - y0) * uy for m in mes]
    dirs = {m["d"] for m in mes}
    ticks = mes[-1]["k"] - mes[0]["k"]
    # The line is drawn from the first `me`, itself up to one step's sideways drift (~0.06) off the
    # character's own line, so the path can read up to two such steps off it.
    live_lib.report(max(side) < 0.15 and dirs <= {0, 2} and all(m.get("a") == a for m in mes),
           "walk: at 20 degrees the real path keeps to the line, stepping north and north-east",
           f"{along[-1]:.1f} tiles, {max(side):.3f} tiles off the line at most, directions {sorted(dirs)}")
    live_lib.report(along[-1] / ticks > 0.9 * straight, "walk: and goes along the line at cos(the zig-zag's angle) of the straight speed or more",
           f"{along[-1] / ticks:.4f} tiles a tick along it, {along[-1] / ticks / straight:.3f} of straight")
    # A wall across the way north: the character slides east along it instead of stopping.
    x, y = c.me["x"] / 256, c.me["y"] / 256
    units = live_lib.mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local out = {{}}
for i = -2, 14 do
  local e = s.create_entity({{ name = "stone-wall", position = {{ {math.floor(x)} + i + 0.5, {math.floor(y)} - 1.5 }}, force = c.force }})
  out[#out + 1] = e and e.unit_number or 0
end
rcon.print(table.concat(out, " "))
""".replace("\n", " ")).split()
    c.pump(0.3, every=hello)
    before = (c.me["x"] / 256, c.me["y"] / 256)
    mes = walk({"t": "walk", "d": 2, "a": a}, 2.0)
    after = (c.me["x"] / 256, c.me["y"] / 256)
    late = mes[len(mes) // 2:]  # by then it has reached the wall
    east = (late[-1]["x"] - late[0]["x"]) / 256 / max(1, late[-1]["k"] - late[0]["k"])
    north = (late[0]["y"] - late[-1]["y"]) / 256
    live_lib.report(len(late) > 5 and east > 0.02 and abs(north) < 0.05,
           "walk: against a wall in the way it slides along it",
           f"{after[0] - before[0]:.2f} east and {before[1] - after[1]:.2f} north in all; at the wall {east:.4f} tiles a tick east, {north:.3f} north")
    live_lib.destroy_units([int(u) for u in units])
    stop = c.me["x"], c.me["y"]
    c.pump(0.6, every=hello)
    live_lib.report((c.me["x"], c.me["y"]) == stop and c.me["w"] == 0 and "a" not in c.me, "walk: walk -1 stops an angled walk", str(c.me)[:200])
    back()
    # J26: walking with the mining button held and the cursor ahead over a line of belts mines every belt
    # in turn, as Factorio's own mining does: the client sends only where its cursor is from the
    # character (`mine` `n`, `ox`, `oy`), the bridge's sweep follows that point each tick, and the
    # character stands while it mines.
    x, y = c.me["x"] / 256, c.me["y"] / 256
    bx, by = math.floor(x) + 2.5, math.floor(y) - 1.5
    belts = live_lib.mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local out = {{}}
for i = 0, 4 do
  local e = s.create_entity({{ name = "transport-belt", position = {{ {bx} + i, {by} }}, direction = defines.direction.east, force = c.force }})
  out[#out + 1] = e and e.unit_number or 0
end
rcon.print(table.concat(out, " "))
""".replace("\n", " ")).split()
    c.pump(0.3, every=hello)
    sweep = {"t": "mine", "n": 1, "ox": int(round((bx - x) * 256)), "oy": int(round((by - y) * 256))}
    mes = []
    for i in range(30):
        if i % 5 == 0:
            c.send(hello[1])  # the keep-alive (commands don't count towards it)
        c.send({"t": "walk", "d": 4})
        c.send(sweep)
        mes += live_lib.of_type(c.pump(0.15), "me")
        left = live_lib.mod_lua(f"rcon.print(storage.f3d.puppet.surface.count_entities_filtered({{ name = 'transport-belt', "
                       f"area = {{ {{ {bx - 0.4}, {by - 0.4} }}, {{ {bx + 4.4}, {by + 0.4} }} }} }}))")
        if left.strip() == "0":
            break
    c.send({"t": "walk", "d": -1})
    c.send({"t": "mine_stop"})
    c.pump(0.4, every=hello)
    # Moved while mining: two `me` in a row mining the same belt from different places.
    moved = [(a["k"], b["k"], a["x"], b["x"], a.get("m"), b.get("m"), a["w"], b["w"]) for a, b in zip(mes, mes[1:])
             if "m" in a and "m" in b and (a["mx"], a["my"]) == (b["mx"], b["my"]) and (a["x"], a["y"]) != (b["x"], b["y"])]
    live_lib.report(left.strip() == "0" and any("m" in m for m in mes) and not moved,
           "walk: J26, walking with the button held mines every belt of a line in turn, standing while it mines",
           f"{left.strip()} of 5 left; {sum(1 for m in mes if 'm' in m)} `me` mining; moved while mining: {moved[:4]}; "
           f"walking flag with m: {[(m['k'], m['x'], m['m'], m['w']) for m in mes if 'm' in m and m['w'] == 1][:4]}")
    live_lib.destroy_units([int(u) for u in belts])
    back()  # on the clean, watched spot, for whatever comes next


def check_pickup(c, hello):
    """Issue #18: F (`pickup`) takes the items on belts within the character's item pickup distance too, as
    Factorio's "Pick up items" does, each said at once (`pku`), with an item on the ground as before. First
    Factorio's own rule is measured on the bridge's player-less character (picking_state: whether the game picks
    up for it at all, how far, how many), printed as INFO to compare with; then the bridge's own is checked.
    The belts are a packed column east of the character, backed up against its north end, so nothing moves
    until something is taken. (No Lua comments: each snippet is sent as one line.)"""
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "pickup: no clean spot found", live_lib.SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    bx, y0 = math.floor(x) + 1.5, math.floor(y)
    reach = float(live_lib.mod_lua("rcon.print(storage.f3d.puppet.item_pickup_distance)") or 1) + 0.5  # puppet.lua's PICKUP_SLACK

    def build():
        return live_lib.mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local out = {{}}
for i = -3, 3 do
  local b = s.create_entity({{ name = "transport-belt", position = {{ {bx}, {y0} + i + 0.5 }}, direction = defines.direction.north, force = c.force }})
  if b then
    for l = 1, 2 do for q = 0.125, 0.875, 0.25 do b.get_transport_line(l).insert_at(q, {{ name = "iron-plate", count = 1 }}) end end
    out[#out + 1] = b.unit_number
  end
end
local f = s.create_entity({{ name = "transport-belt", position = {{ {bx} + 10, {y0} + 0.5 }}, direction = defines.direction.north, force = c.force }})
if f then f.get_transport_line(1).insert_at(0.5, {{ name = "iron-plate", count = 1 }}) out[#out + 1] = f.unit_number end
rcon.print(table.concat(out, " "))
""".replace("\n", " ")).split()

    def items(units):
        """{unique id: (x, y)} of the items on these belts' lanes now."""
        out = live_lib.mod_lua("local want = {} for _, u in pairs({ " + ", ".join(units) + " }) do want[u] = true end "
                      "local c = storage.f3d.puppet local p0 = c.position local out = {} "
                      "for _, e in pairs(c.surface.find_entities_filtered({ type = 'transport-belt', force = c.force, "
                      "area = { { p0.x - 16, p0.y - 16 }, { p0.x + 16, p0.y + 16 } } })) do "
                      "if want[e.unit_number] then for l = 1, 2 do local line = e.get_transport_line(l) "
                      "for _, it in pairs(line.get_detailed_contents()) do local p = line.get_line_item_position(it.position) "
                      "out[#out + 1] = it.unique_id .. ',' .. p.x .. ',' .. p.y end end end end "
                      "rcon.print(table.concat(out, ' '))")
        return {int(u): (float(a), float(b)) for u, a, b in (w.split(",") for w in out.split())}

    # Factorio's own: picking_state held on the player-less character for a second.
    units = build()
    c.pump(1.0, every=hello)
    px, py = c.me["x"] / 256, c.me["y"] / 256
    before = items(units)
    plates = live_lib.inv_count("iron-plate")
    took = live_lib.mod_lua("local ok = pcall(function() storage.f3d.puppet.picking_state = true end) rcon.print(ok and 'set' or 'refused')")
    end = time.time() + 1.0
    while time.time() < end:
        c.pump(0.1, every=hello)
        live_lib.mod_lua("pcall(function() storage.f3d.puppet.picking_state = true end)")
    live_lib.mod_lua("pcall(function() storage.f3d.puppet.picking_state = false end)")
    c.pump(0.3, every=hello)
    after = items(units)
    dist = {u: math.hypot(p[0] - px, p[1] - py) for u, p in before.items()}
    gone = [u for u in before if u not in after]
    print(f"INFO pickup: Factorio's own picking_state on the bridge's player-less character ({took}) took {len(gone)} of "
          f"{len(before)} belt items in a second (+{live_lib.inv_count('iron-plate') - plates} plates), the furthest "
          f"{max((dist[u] for u in gone), default=0):.2f} tiles off as they lay; the nearest not taken "
          f"{min((dist[u] for u in before if u in after), default=0):.2f}; item_pickup_distance {reach - 0.5}")
    live_lib.destroy_units([int(u) for u in units])
    c.pump(0.3, every=hello)

    # The bridge's own: F held for a second.
    units = build()
    ground = live_lib.mod_lua(f"local c = storage.f3d.puppet local e = c.surface.create_entity({{ name = 'item-on-ground', "
                     f"position = {{ {x} - 0.7, {y} }}, stack = {{ name = 'wood', count = 1 }} }}) rcon.print(e and 'ok' or 'none')")
    c.pump(1.0, every=hello)
    px, py = c.me["x"] / 256, c.me["y"] / 256
    before = items(units)
    near = {u for u, p in before.items() if math.hypot(p[0] - px, p[1] - py) <= reach - 0.05}
    far = {u for u, p in before.items() if p[0] > bx + 5}
    plates, wood = live_lib.inv_count("iron-plate"), live_lib.inv_count("wood")
    msgs = c.pump(1.0, every=(0.15, {"t": "pickup"}))
    msgs += c.pump(1.0, every=hello)
    after = items(units)
    recs = [r for m in live_lib.of_type(msgs, "pku") for r in m["l"]]
    on_belt = [r for r in recs if r[4]]
    taken = {r[5] for r in on_belt}
    belt_units = {int(u) for u in units}
    live_lib.report(on_belt and taken <= set(before) and all(r[0] == "iron-plate" and r[4] // 8 in belt_units and r[6] == 0 for r in on_belt),
           "pickup: F takes the items on belts in reach, each said at once (pku: its lane and unique id)",
           f"{len(on_belt)} said, {len(near)} in reach at the start; {on_belt[:2]}")
    live_lib.report(near <= taken and not taken & set(after) and far <= set(after),
           "pickup: every item in reach comes off its lane, none said taken is still there, a belt out of reach keeps its own",
           f"in reach and not said: {sorted(near - taken)[:4]}; said and still there: {sorted(taken & set(after))[:4]}")
    off = [round(math.hypot(r[2] / 256 - px, r[3] / 256 - py), 3) for r in on_belt]
    live_lib.report(off and max(off) <= reach + 0.02, "pickup: each where the game had it, within the pickup distance",
           f"furthest {max(off, default=0)} tiles, reach {reach}")
    live_lib.report(live_lib.inv_count("iron-plate") - plates == sum(r[1] for r in on_belt),
           "pickup: the inventory got what pku says, no more", f"{live_lib.inv_count('iron-plate') - plates} plates, said {sum(r[1] for r in on_belt)}")
    ground_recs = [r for r in recs if not r[4]]
    live_lib.report(ground != "ok" or (ground_recs and ground_recs[0][0] == "wood" and live_lib.inv_count("wood") == wood + 1),
           "pickup: and the item lying on the ground, said too (lane 0)", str(ground_recs[:1]))
    ks = [m["k"] for m in live_lib.of_type(msgs, "pku")]
    later_bi = [v for m in live_lib.of_type(msgs, "bi") if ks and m.get("k", 0) > max(ks) + 12 for v in m["l"][0::4]]
    if later_bi:
        live_lib.report(not taken & set(later_bi), "pickup: the belt items it took are gone from the belt items sent after",
               str(sorted(taken & set(later_bi))[:4]))
    live_lib.destroy_units([int(u) for u in units])
    c.pump(0.3, every=hello)


def check_input(c, hello):
    """Slot clicks and fast transfers as the client sends them (move, xfer, fast), compared with
    what 2.1.23's own inventory actions do (tools/ui_reference/f3d-ui-capture/rules.lua, recorded
    with LuaPlayer.cursor_transfer / cursor_split / stack_transfers in the real game)."""
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "input: no clean spot found", live_lib.SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    fx = lambda v: int(round(v * 256))
    out = live_lib.mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local x, y = {x}, {y}
local function put(name, dx, dy)
  local e = s.create_entity({{ name = name, position = {{ x + dx, y + dy }}, force = c.force, raise_built = true }})
  return e and (e.unit_number .. " " .. e.position.x .. " " .. e.position.y) or "0 0 0"
end
local out = {{}}
out[#out + 1] = put("iron-chest", 2.5, 0.5)
out[#out + 1] = put("stone-furnace", -3, 1)
out[#out + 1] = put("assembling-machine-1", 0.5, 4.5)
out[#out + 1] = put("transport-belt", 4.5, -2.5)
out[#out + 1] = put("lab", -4.5, -3.5)
rcon.print(table.concat(out, " "))
""".replace("\n", " "))
    names = ["iron-chest", "stone-furnace", "assembling-machine-1", "transport-belt", "lab"]
    vals = out.split()
    if len(vals) != 3 * len(names) or "0" in vals[0::3]:
        live_lib.report(False, "input: building the test entities", out)
        return
    units = [int(v) for v in vals[0::3]]
    chest, furnace, asm, belt, lab = units
    pos = {u: (float(vals[3 * i + 1]), float(vals[3 * i + 2]), names[i]) for i, u in enumerate(units)}
    ident = lambda u: {"u": u, "p": c.proto_id(pos[u][2]), "x": fx(pos[u][0]), "y": fx(pos[u][1])}
    c.pump(1.0, every=hello)
    entity = lambda u: (f"(function() for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ force = 'player' }})) do "
                        f"if e.unit_number == {u} then return e end end end)()")

    def main(*stacks):
        """Empties the character's main inventory and fills its first slots with these stacks."""
        parts = " ".join(f'm[{i + 1}].set_stack({{ name = "{st[0]}", count = {st[1]} }})' for i, st in enumerate(stacks) if st)
        live_lib.mod_lua(f"local m = storage.f3d.puppet.get_main_inventory() m.clear() {parts} rcon.print('ok')")

    def slots(inv="main", unit=0, n=4):
        """The first n slots of the main inventory, or of that entity's inventory (a defines.inventory name)."""
        where = "storage.f3d.puppet.get_main_inventory()" if unit == 0 else f"{entity(unit)}.get_inventory(defines.inventory.{inv})"
        got = live_lib.mod_lua(f"local i = {where} local o = {{}} for k = 1, math.min({n}, #i) do local st = i[k] "
                      f"o[k] = st.valid_for_read and (st.name .. ':' .. st.count) or '-' end rcon.print(table.concat(o, ' '))")
        return got.split()

    def first_define(*names_):
        for n in names_:
            if live_lib.mod_lua(f"rcon.print(defines.inventory['{n}'] and 'y' or 'n')") == "y":
                return n
        return names_[0]

    def totals(ss):
        out = {}
        for v in ss:
            if v != "-":
                k, n = v.rsplit(":", 1)
                out[k] = out.get(k, 0) + int(n)
        return out

    # Left click onto the same item: what fits goes, the rest stays (merge_overflow, merge_into_full).
    main(("iron-plate", 80), ("iron-plate", 50))
    c.send({"t": "move", "from": "main", "fi": 1, "to": "main", "ti": 2})
    c.pump(0.4, every=hello)
    got = slots()
    live_lib.report(got[:2] == ["iron-plate:30", "iron-plate:100"], "move onto the same item: 100 in the slot, 30 left (2.1.23: cursor 30)", str(got))
    c.send({"t": "move", "from": "main", "fi": 1, "to": "main", "ti": 2})
    c.pump(0.4, every=hello)
    got = slots()
    live_lib.report(got[:2] == ["iron-plate:30", "iron-plate:100"], "move onto a full stack of it: nothing moves (2.1.23: no swap)", str(got))

    # Shift / Ctrl clicks with the chest open (stack_transfer, stack_split, inventory_transfer, inventory_split).
    c.send({"t": "open", **ident(chest)})
    c.pump(0.5, every=hello)
    cases = [
        ("stack", 1, [("iron-plate", 37), ("iron-plate", 30)], ["-", "iron-plate:30"], {"iron-plate": 37}, "Shift+click: the stack"),
        ("half", 1, [("iron-plate", 37), ("iron-plate", 30)], ["iron-plate:19", "iron-plate:30"], {"iron-plate": 18},
         "Shift+right click: the smaller half (18 of 37)"),
        ("all", 1, [("iron-plate", 37), ("iron-plate", 30), ("copper-plate", 5)], ["-", "-", "copper-plate:5"], {"iron-plate": 67},
         "Ctrl+click: every stack of the item (67)"),
        ("allhalf", 1, [("iron-plate", 37), ("iron-plate", 30), ("copper-plate", 5)], ["iron-plate:19", "iron-plate:15", "copper-plate:5"],
         {"iron-plate": 33}, "Ctrl+right click: half of each (18 + 15)"),
        ("all", 2, [("iron-plate", 37), None, ("copper-plate", 5)], ["-", "-", "-"], {"iron-plate": 37, "copper-plate": 5},
         "Ctrl+click on an empty slot: everything"),
        ("stack", 2, [("iron-plate", 37), None, ("copper-plate", 5)], ["iron-plate:37", "-", "copper-plate:5"], {},
         "Shift+click on an empty slot: nothing"),
    ]
    for kind, fi, stacks, want_main, want_chest, why in cases:
        live_lib.mod_lua(f"{entity(chest)}.get_inventory(defines.inventory.chest).clear() rcon.print('ok')")
        main(*stacks)
        c.send({"t": "xfer", "from": "main", "fi": fi, "k": kind, "u": chest})
        c.pump(0.4, every=hello)
        got_main, got_chest = slots(), slots("chest", chest, 8)
        live_lib.report(got_main[:len(want_main)] == want_main and totals(got_chest) == want_chest,
               f"xfer {kind}: {why}", f"main {got_main} chest {got_chest}")
    live_lib.mod_lua(f"local i = {entity(chest)}.get_inventory(defines.inventory.chest) i.clear() "
            f"i[1].set_stack({{ name = 'iron-plate', count = 37 }}) i[2].set_stack({{ name = 'iron-plate', count = 30 }}) rcon.print('ok')")
    main()
    c.send({"t": "xfer", "from": "chest", "fi": 1, "k": "half", "u": chest})
    c.pump(0.4, every=hello)
    got_main, got_chest = slots(), slots("chest", chest)
    live_lib.report(got_main[0] == "iron-plate:18" and got_chest[:2] == ["iron-plate:19", "iron-plate:30"],
           "xfer half from the chest: 18 of 37 into the character", f"main {got_main} chest {got_chest}")

    # Smart insertion: ore into the furnace's source (50 of 80), coal into its fuel.
    c.send({"t": "open", **ident(furnace)})
    c.pump(0.5, every=hello)
    main(("iron-ore", 50), ("coal", 30))
    c.send({"t": "xfer", "from": "main", "fi": 1, "k": "stack", "u": furnace})
    c.send({"t": "xfer", "from": "main", "fi": 2, "k": "stack", "u": furnace})
    c.pump(0.5, every=hello)
    src = slots(first_define("furnace_source", "crafter_input"), furnace, 1)
    fuel = slots("fuel", furnace, 1)
    # (it starts smelting at once: one ore and some coal may already be used)
    n_src = int(src[0].split(":")[1]) if src and src[0].startswith("iron-ore:") else 0
    live_lib.report(48 <= n_src <= 50 and fuel and fuel[0].startswith("coal:") and slots()[:2] == ["-", "-"],
           "xfer into a furnace: a stack of ore (50) to the source, coal to the fuel (2.1.23 the same)", f"{src} {fuel} {slots()}")
    # An assembler takes what LuaEntity.insert gives it; the game's own Ctrl+click took 120 plates for gears.
    live_lib.mod_lua(f"{entity(asm)}.set_recipe('iron-gear-wheel') rcon.print('ok')")
    c.send({"t": "open", **ident(asm)})
    c.pump(0.5, every=hello)
    main(("iron-plate", 100), ("iron-plate", 100))
    c.send({"t": "xfer", "from": "main", "fi": 1, "k": "all", "u": asm})
    c.pump(0.5, every=hello)
    got = slots(first_define("assembling_machine_input", "crafter_input"), asm, 1)
    live_lib.report(bool(got) and got[0].startswith("iron-plate:"), "xfer all into an assembler (LuaEntity.insert)",
           f"{got}; the game's own Ctrl+click took 120")
    c.send({"t": "close"})
    c.pump(0.3, every=hello)

    # With nothing open: a gun to the gun slots, a plate stays.
    live_lib.mod_lua("storage.f3d.puppet.get_inventory(defines.inventory.character_guns).clear() rcon.print('ok')")
    main(("pistol", 1), ("iron-plate", 5))
    c.send({"t": "xfer", "from": "main", "fi": 1, "k": "stack"})
    c.pump(0.4, every=hello)
    guns = live_lib.mod_lua("rcon.print(storage.f3d.puppet.get_inventory(defines.inventory.character_guns).get_item_count('pistol'))")
    c.send({"t": "xfer", "from": "main", "fi": 2, "k": "stack"})
    msgs = c.pump(0.4, every=hello)
    live_lib.report(guns == "1" and slots()[1] == "iron-plate:5" and any("Nowhere" in m["text"] for m in live_lib.of_type(msgs, "msg")),
           "xfer with nothing open: a gun goes to the gun slots, a plate stays (2.1.23 the same)", f"guns {guns} {slots()}")

    # Ctrl+click on a belt: plates on, then off again; on a lab: its science packs out.
    main(("iron-plate", 10))
    c.send({"t": "fast", **ident(belt), "item": "iron-plate", "n": 10, "half": 0})
    c.pump(0.4, every=hello)
    on_belt = int(live_lib.mod_lua(f"local e = {entity(belt)} local n = 0 for i = 1, 2 do n = n + e.get_transport_line(i).get_item_count() end "
                          f"rcon.print(n)") or -1)
    left = live_lib.inv_count("iron-plate")
    c.send({"t": "fast", **ident(belt), "half": 0})
    c.pump(0.4, every=hello)
    live_lib.report(on_belt > 0 and left == 10 - on_belt and live_lib.inv_count("iron-plate") == 10,
           "fast on a belt: plates onto its lanes (insert_at_back), then all back (get_contents, remove_item)",
           f"{on_belt} went on, {left} left, {live_lib.inv_count('iron-plate')} after")
    live_lib.mod_lua(f"{entity(lab)}.insert({{ name = 'automation-science-pack', count = 10 }}) rcon.print('ok')")
    c.send({"t": "fast", **ident(lab), "half": 0})
    c.pump(0.4, every=hello)
    live_lib.report(live_lib.inv_count("automation-science-pack") == 10, "fast with an empty hand on a lab takes its science packs (lab_input)",
           str(live_lib.inv_count("automation-science-pack")))
    # A machine's output slots take nothing from the hand (Factorio: products can only be taken out);
    # transfer_stack on a furnace's result slot would take anything.
    main(("iron-plate", 20))
    live_lib.mod_lua(f"{entity(furnace)}.get_output_inventory().clear() rcon.print('ok')")
    c.send({"t": "open", **ident(furnace)})
    c.pump(0.4, every=hello)
    c.send({"t": "move", "from": "main", "fi": 1, "to": "output", "ti": 1, "u": furnace})
    msgs = c.pump(0.4, every=hello)
    res = live_lib.mod_lua(f"local st = {entity(furnace)}.get_output_inventory()[1] rcon.print(st.valid_for_read and (st.name .. ':' .. st.count) or '-')").split()
    live_lib.report(res == ["-"] and slots()[0] == "iron-plate:20",
           "move into a furnace's output slot is refused (the hand's stack stays)", f"result {res} main {slots()} {[m.get('text') for m in live_lib.of_type(msgs, 'msg')]}")
    # ...nor by swapping: a stack taken from the output slot onto a different one in the inventory.
    main(("copper-plate", 20))
    live_lib.mod_lua(f"local o = {entity(furnace)}.get_output_inventory() o.clear() o.insert({{ name = 'iron-plate', count = 5 }}) rcon.print('ok')")
    c.send({"t": "move", "from": "output", "fi": 1, "to": "main", "ti": 1, "u": furnace})
    c.pump(0.4, every=hello)
    res = live_lib.mod_lua(f"local st = {entity(furnace)}.get_output_inventory()[1] rcon.print(st.valid_for_read and (st.name .. ':' .. st.count) or '-')").split()
    live_lib.report(res == ["iron-plate:5"] and slots()[0] == "copper-plate:20",
           "move from a furnace's output slot onto a different stack does not swap it into the output", f"result {res} main {slots()}")
    live_lib.destroy_units(units)
    check_hand_stack(c, hello, x, y)


def check_hand_stack(c, hello, x, y):
    """L7: Factorio builds out of the cursor's stack. A `build` naming the main inventory slot the client's hand
    holds (`hs`) is paid from that stack, in its quality; an `hs` on a slot that holds another item is passed over
    (a normal one pays, as without it); Z (`drop`) naming the slot takes the item from that stack."""
    def stacks():
        out = live_lib.mod_lua("""local inv = storage.f3d.puppet.get_main_inventory() local at = {} for i = 1, #inv do local st = inv[i]
 if st.valid_for_read and (st.name == 'wooden-chest' or st.name == 'iron-plate') then at[#at + 1] = i .. ':' .. st.name .. ':' .. st.quality.name .. ':' .. st.count end end
 rcon.print(table.concat(at, ' '))""".replace("\n", " "))
        rows = [r.split(":") for r in out.split()]
        return {int(r[0]): (r[1], r[2], int(r[3])) for r in rows if len(r) == 4}

    made = live_lib.mod_lua("""local inv = storage.f3d.puppet.get_main_inventory() inv.clear()
 inv.insert({ name = 'wooden-chest', count = 5 }) inv.insert({ name = 'iron-plate', count = 7 })
 local ok = pcall(function() inv.insert({ name = 'wooden-chest', count = 3, quality = 'rare' }) end)
 rcon.print(ok and 'rare' or 'plain')""".replace("\n", " "))
    before = stacks()
    normal = next((i for i, s in before.items() if s[0] == "wooden-chest" and s[1] == "normal"), 0)
    rare = next((i for i, s in before.items() if s[0] == "wooden-chest" and s[1] == "rare"), 0)
    plates = next((i for i, s in before.items() if s[0] == "iron-plate"), 0)
    if not normal or not plates:
        live_lib.report(False, "L7: chests and plates in the character's inventory", f"{made} {before}")
        return
    fx = lambda v: math.floor(v * 256)

    def build(dy, hs):
        c.send({"t": "build", "item": "wooden-chest", "x": fx(x + 6.5), "y": fx(y + dy + 0.5), "d": 0, "hs": hs})
        c.pump(0.5, every=hello)
        return stacks()

    if rare:
        after = build(0, rare)
        live_lib.report(after.get(rare, ("", "", 0))[2] == 2 and after.get(normal, ("", "", 0))[2] == 5,
               "L7: a build naming the held stack's slot (hs) is paid from that stack, in its quality (a rare stack held)",
               f"{before} -> {after}")
    after = build(2, normal)
    live_lib.report(after.get(normal, ("", "", 0))[2] == 4, "L7: hs on the normal stack: that stack pays", str(after))
    after = build(4, plates)
    live_lib.report(after.get(normal, ("", "", 0))[2] == 3 and after.get(plates, ("", "", 0))[2] == 7,
           "L7: an hs naming a slot that holds another item is passed over: a normal chest pays, the plates stay", str(after))
    c.send({"t": "drop", "item": "iron-plate", "x": fx(x + 5.5), "y": fx(y - 3.5), "hs": plates})
    c.pump(0.5, every=hello)
    after = stacks()
    live_lib.report(after.get(plates, ("", "", 0))[2] == 6, "L7: Z naming the held stack's slot takes the plate from that stack", str(after))
    live_lib.mod_lua(f"""local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({{ area = {{ {{ {x} + 4, {y} - 5 }}, {{ {x} + 8, {y} + 6 }} }},
 name = {{ 'wooden-chest', 'item-on-ground' }} }})) do e.destroy({{ raise_destroy = true }}) end rcon.print('ok')""".replace("\n", " "))


def eq_of(msgs, kind):
    eqs = [m for m in live_lib.of_type(msgs, "eq") if m.get("kind") == kind]
    return eqs[-1] if eqs else None


def check_gear(c, hello):
    """The character's gear (equipment.lua, puppet.lua): its armour's equipment grid (`eq`), putting,
    moving and taking equipment, the roboport and exoskeleton switches, `me`'s shields, the
    character tab (`cinfo`), the players list (`pl`), a vehicle's grid, and dying: the countdown
    (`dead`) and the respawn at the spawn. Use a copy of a save: the armour is taken from any
    other character that wears one (the owner's save has one), else power armour is made."""
    out = live_lib.mod_lua("""
local c = storage.f3d.puppet
local mine = c.get_inventory(defines.inventory.character_armor)
local how = "worn"
if not (mine[1].valid_for_read and c.grid) then
  how = "made"
  for _, s in pairs(game.surfaces) do
    for _, o in pairs(s.find_entities_filtered({ type = "character" })) do
      if o ~= c and o.grid and #o.grid.equipment > 0 and how == "made" then
        mine[1].swap_stack(o.get_inventory(defines.inventory.character_armor)[1])
        how = "from " .. s.name
      end
    end
  end
end
if how == "made" then
  mine[1].set_stack({ name = "power-armor-mk2" })
  local g = c.grid
  for _, e in pairs({ { "fission-reactor-equipment", 0, 0 }, { "exoskeleton-equipment", 4, 0 }, { "battery-mk2-equipment", 6, 0 },
      { "night-vision-equipment", 7, 0 }, { "personal-roboport-equipment", 4, 4 } }) do
    g.put({ name = e[1], position = { e[2], e[3] } })
  end
end
c.insert({ name = "energy-shield-equipment", count = 1 })
local g = c.grid
local list = {}
for _, e in pairs(g.equipment) do list[#list + 1] = { e.name, e.position.x, e.position.y, e.shape.width, e.shape.height } end
rcon.print(helpers.table_to_json({ how = how, w = g.width, h = g.height, l = list, mv = g.movement_bonus }))
""".replace("\n", " "))
    try:
        grid = json.loads(out)
    except ValueError:
        live_lib.report(False, "gear: put power armour on the character", out[:300])
        return
    msgs = c.pump(2.5, every=hello)
    eq = eq_of(msgs, "char") or c.last.get("eq char")
    live_lib.report(eq and eq["w"] == grid["w"] and eq["h"] == grid["h"] and len(eq["l"]) == len(grid["l"])
           and sorted(r[:5] for r in eq["l"]) == sorted(grid["l"]),
           "eq: the armour's grid with every piece where it is (LuaEntity::grid, LuaEquipment position and shape)",
           f"armour {grid['how']}, {grid['w']}x{grid['h']}, {len(grid['l'])} pieces; sent {eq and len(eq['l'])}")
    if not eq:
        return
    live_lib.report(eq["mv"] >= 0 and eq["mbat"] >= eq["bat"] >= 0 and eq["gen"] >= 0 and eq["rb"] in (0, 1),
           "eq: movement bonus, battery energy, generator power and the roboport switch",
           f"mv {eq['mv']} bat {eq['bat']}/{eq['mbat']} gen {eq['gen']} W rb {eq.get('rb')} nv {eq.get('nv')}")
    info = [c.last["cinfo"]] if "cinfo" in c.last else []
    live_lib.report(info and info[-1]["reach"] > 0 and info[-1]["slots"] > 0 and info[-1]["hp"] > 0 and info[-1]["eqmv"] == eq["mv"],
           "cinfo: the character tab (reach, slots, health, the equipment's running bonus)", str(info[-1:])[:300])
    pl = [c.last["pl"]] if "pl" in c.last else []
    live_lib.report(pl and pl[-1]["u"] == c.me["u"] and len(pl[-1]["l"]) >= 1 and all(len(r) == 11 for r in pl[-1]["l"]),
           "pl: the game's players, and whose character the client plays", str(pl[-1:])[:300])

    # Make room for the shield: take the smallest piece out (into an empty slot), Shift+click the
    # shield in, check `me` shows its shield, then put everything back as it was.
    small = next((r for r in eq["l"] if r[3:5] == [2, 2]), min(eq["l"], key=lambda r: r[3] * r[4]))
    c.send({"t": "eq_take", "kind": "char", "x": small[1], "y": small[2]})
    msgs = c.pump(1.0, every=hello)
    eq2 = eq_of(msgs, "char")
    live_lib.report(eq2 and len(eq2["l"]) == len(eq["l"]) - 1 and c.inv.get(small[0], 0) >= 1,
           "eq_take: equipment out of the grid into the inventory (LuaEquipmentGrid::take)", f"took {small[0]} at {small[1]},{small[2]}")
    fi = json.loads(live_lib.mod_lua("local m = storage.f3d.puppet.get_main_inventory() local out = 0 "
                            "for i = 1, #m do if out == 0 and m[i].valid_for_read and m[i].name == 'energy-shield-equipment' then out = i end end "
                            "rcon.print(out)") or "0")
    c.send({"t": "eq_put", "kind": "char", "fi": fi})
    msgs = c.pump(1.5, every=hello)
    eq3 = eq_of(msgs, "char")
    shield = [r for r in (eq3 or {}).get("l", []) if r[0] == "energy-shield-equipment"]
    mes = [m for m in live_lib.of_type(msgs, "me") if "msd" in m]
    live_lib.report(shield and shield[0][9] > 0 and eq3["msh"] >= shield[0][9],
           "eq_put without a position: Shift+click puts it where it first fits (LuaEquipmentGrid::put)", str(shield))
    live_lib.report(mes and mes[-1]["msd"] == eq3["msh"], "me: sd and msd, the armour's shields over the health bar", str(mes[-1:])[:200])
    if shield:
        c.send({"t": "eq_take", "kind": "char", "x": shield[0][1], "y": shield[0][2]})
        c.pump(0.8, every=hello)
    fi = json.loads(live_lib.mod_lua("local m = storage.f3d.puppet.get_main_inventory() local out = 0 "
                            f"for i = 1, #m do if out == 0 and m[i].valid_for_read and m[i].name == '{small[0]}' then out = i end end "
                            "rcon.print(out)") or "0")
    c.send({"t": "eq_put", "kind": "char", "fi": fi, "x": small[1], "y": small[2]})
    msgs = c.pump(1.0, every=hello)
    eq4 = eq_of(msgs, "char")
    live_lib.report(eq4 and sorted(r[:5] for r in eq4["l"]) == sorted(r[:5] for r in eq["l"]),
           "eq_put at a position: the piece goes back where it was", f"{small[0]} at {small[1]},{small[2]}")
    # Moving: the smallest piece out again, then one of the same shape into its place.
    small = min(eq["l"], key=lambda r: r[3] * r[4])
    twin = next((r for r in eq["l"] if r[3:5] == small[3:5] and r[1:3] != small[1:3]), None)
    if twin:
        c.send({"t": "eq_take", "kind": "char", "x": small[1], "y": small[2]})
        c.pump(0.8, every=hello)
        c.send({"t": "eq_move", "kind": "char", "x": twin[1], "y": twin[2], "tx": small[1], "ty": small[2]})
        msgs = c.pump(1.0, every=hello)
        eq5 = eq_of(msgs, "char")
        moved = [r for r in (eq5 or {}).get("l", []) if r[1:3] == small[1:3]]
        live_lib.report(moved and moved[0][0] == twin[0], "eq_move: a piece moves to another place in the grid (LuaEquipmentGrid::move{...})",
               f"{twin[0]} from {twin[1]},{twin[2]} to {small[1]},{small[2]}")
        c.send({"t": "eq_move", "kind": "char", "x": small[1], "y": small[2], "tx": twin[1], "ty": twin[2]})
        c.pump(0.8, every=hello)
        fi = json.loads(live_lib.mod_lua("local m = storage.f3d.puppet.get_main_inventory() local out = 0 "
                                f"for i = 1, #m do if out == 0 and m[i].valid_for_read and m[i].name == '{small[0]}' then out = i end end "
                                "rcon.print(out)") or "0")
        c.send({"t": "eq_put", "kind": "char", "fi": fi, "x": small[1], "y": small[2]})
        c.pump(0.8, every=hello)
    else:
        live_lib.report(True, "eq_move: no two pieces of the same shape to swap places with (skipped)")
    # Alt+F and Alt+E.
    c.send({"t": "eq_toggle", "what": "roboport", "on": 0})
    c.send({"t": "eq_toggle", "what": "movement", "on": 0})
    msgs = c.pump(1.0, every=hello)
    state = live_lib.mod_lua("local c = storage.f3d.puppet rcon.print(tostring(c.allow_dispatching_robots) .. ' ' .. tostring(c.grid.inhibit_movement_bonus))")
    eq6 = eq_of(msgs, "char")
    live_lib.report(state == "false true" and eq6 and eq6["rb"] == 0 and eq6["mvon"] == 0 and eq6["mv"] == 0,
           "eq_toggle: personal roboport off (allow_dispatching_robots) and exoskeletons off (inhibit_movement_bonus)", state)
    c.send({"t": "eq_toggle", "what": "roboport", "on": 1})
    c.send({"t": "eq_toggle", "what": "movement", "on": 1})
    c.pump(1.0, every=hello)
    state = live_lib.mod_lua("local c = storage.f3d.puppet rcon.print(tostring(c.allow_dispatching_robots) .. ' ' .. tostring(c.grid.inhibit_movement_bonus))")
    live_lib.report(state == "true false", "eq_toggle: and back on", state)

    # A vehicle's grid: a tank beside the character, opened like its screen.
    out = live_lib.mod_lua("local c = storage.f3d.puppet local p = c.surface.find_non_colliding_position('tank', { c.position.x + 4, c.position.y }, 10, 0.5) "
                  "local t = p and c.surface.create_entity({ name = 'tank', position = p, force = c.force }) "
                  "c.insert({ name = 'battery-equipment', count = 1 }) "
                  "rcon.print(t and (t.unit_number .. ' ' .. math.floor(t.position.x * 256 + 0.5) .. ' ' .. math.floor(t.position.y * 256 + 0.5) .. ' ' .. tostring(t.grid and t.grid.width)) or 'none')")
    parts = out.split()
    if len(parts) == 4:
        tank = int(parts[0])
        c.send({"t": "open", "u": tank, "p": c.proto_id("tank"), "x": int(parts[1]), "y": int(parts[2])})
        msgs = c.pump(1.5, every=hello)
        veh = eq_of(msgs, "veh")
        live_lib.report(veh and veh["u"] == tank and veh["w"] > 0, "eq: an open tank's equipment grid (kind veh)", f"{veh and (veh['w'], veh['h'])}, grid {parts[3]}")
        fi = json.loads(live_lib.mod_lua("local m = storage.f3d.puppet.get_main_inventory() local out = 0 "
                                "for i = 1, #m do if out == 0 and m[i].valid_for_read and m[i].name == 'battery-equipment' then out = i end end "
                                "rcon.print(out)") or "0")
        c.send({"t": "eq_put", "kind": "veh", "u": tank, "fi": fi, "x": 0, "y": 0})
        msgs = c.pump(1.0, every=hello)
        veh = eq_of(msgs, "veh")
        live_lib.report(veh and any(r[0] == "battery-equipment" for r in veh["l"]), "eq_put into the tank's grid", str(veh and veh["l"]))
        c.send({"t": "close"})
        c.pump(0.5, every=hello)
        live_lib.destroy_units([tank])
    else:
        live_lib.report(False, "gear: build a tank", out)

    # Dying: the bridge's character waits out the character's respawn time, then comes back at the spawn.
    old = c.me["u"]
    live_lib.mod_lua("local c = storage.f3d.puppet c.die()")
    msgs = c.pump(2.0, every=hello)
    dead = live_lib.of_type(msgs, "dead")
    live_lib.report(dead and 400 < dead[0]["left"] <= 600 and "x" in dead[0], "dead: the respawn countdown after the character died",
           str(dead[:1]))
    # 600 ticks: longer than 10 s when a big save runs below 60 UPS.
    msgs = c.pump(40, every=hello, until=lambda m: m.get("t") == "welcome")
    welcome = live_lib.of_type(msgs, "welcome")
    where = live_lib.mod_lua("local c = storage.f3d.puppet local s = c.force.get_spawn_position(c.surface) "
                    "rcon.print(string.format('%.1f %s', math.sqrt((c.position.x - s.x)^2 + (c.position.y - s.y)^2), c.surface.name))")
    live_lib.report(welcome and welcome[-1]["u"] != old and float(where.split()[0]) < 16,
           "respawn: a new character at the force's spawn after the respawn time, with a new welcome", where)
    msgs = c.pump(2.0, every=hello)
    eq7 = eq_of(msgs, "char")
    live_lib.report(eq7 is not None and eq7["w"] == 0, "eq: the respawned character has no armour (it is in the corpse)", str(eq7)[:120])


def check_info(c, hello):
    """Alerts (alerts.lua), Factoriopedia (pedia.lua), the logistic networks window, statistics and
    technology details."""
    # Factoriopedia: the index and pages, from prototypes.
    c.send({"t": "pedia_index"})
    msgs = c.pump(8, every=hello, until=lambda m: m.get("t") == "pidx" and m["part"] == m["parts"])
    pidx = live_lib.of_type(msgs, "pidx")
    entries = [r for m in pidx for r in m["l"]]
    kinds = {}
    for r in entries:
        kinds[r[0]] = kinds.get(r[0], 0) + 1
    names = {(r[0], r[1]) for r in entries}
    live_lib.report(pidx and pidx[-1]["part"] == pidx[-1]["parts"] and len(pidx) == pidx[-1]["parts"]
           and {("item", "iron-plate"), ("fluid", "water"), ("technology", "automation"), ("planet", "vulcanus"),
                ("quality", "legendary"), ("entity", "small-biter"), ("tile", "water")} <= names
           and ("entity", "assembling-machine-1") not in names,
           "pidx: Factoriopedia's index (items, fluids, entities without an item, tiles, recipes, technologies, planets, qualities)",
           f"{len(entries)} entries in {len(pidx)} parts: {kinds}, {len(pidx[0].get('g', [])) if pidx else 0} groups")
    pages = [("item", "assembling-machine-2"), ("item", "iron-plate"), ("item", "coal"), ("fluid", "crude-oil"),
             ("recipe", "electronic-circuit"), ("technology", "mining-productivity-3"), ("technology", "steam-power"),
             ("entity", "small-biter"), ("tile", "water"), ("planet", "vulcanus"), ("quality", "legendary"),
             ("item", "speed-module"), ("entity", "iron-ore"), ("item", "no-such-thing")]
    for kind, name in pages:
        c.send({"t": "pedia", "kind": kind, "name": name})
    msgs = c.pump(3, every=hello)
    got = {(m["kind"], m["name"]): m for m in live_lib.of_type(msgs, "pedia")}
    d = lambda k, n: got.get((k, n), {}).get("d", {})
    am2 = d("item", "assembling-machine-2").get("entity", {})
    live_lib.report(am2.get("craft") == 0.75 and am2.get("modules") == 2 and 140000 < am2.get("energy", 0) < 160000
           and am2.get("hp") == 350 and am2.get("etype") == "electric" and "electronic-circuit" in am2.get("recipes", []),
           "pedia: a machine's speed, energy use, modules, health and recipes", str({k: am2.get(k) for k in ("craft", "modules", "energy", "drain", "hp", "poll", "res")}))
    plate = d("item", "iron-plate")
    live_lib.report(plate.get("stack") == 100 and "iron-plate" in plate.get("made", []) and "iron-gear-wheel" in plate.get("used", []),
           "pedia: an item's stack size, made by, used in", f"stack {plate.get('stack')}, made {plate.get('made')}, used {len(plate.get('used', []))}")
    coal = d("item", "coal")
    live_lib.report(coal.get("fuel") == 4000000 and "chemical" in coal.get("fcat", []) and "coal" in coal.get("mined", []),
           "pedia: fuel value and category, mined from", str({k: coal.get(k) for k in ("fuel", "fcat", "mined")}))
    ec = d("recipe", "electronic-circuit")
    live_lib.report(["item", "copper-cable", 3] in ec.get("ing", []) and "assembling-machine-1" in ec.get("made_in", [])
           and ec.get("unlocked") == ["electronics"] if ec.get("unlocked") else "assembling-machine-1" in ec.get("made_in", []),
           "pedia: a recipe's ingredients, made in, unlocked by", str({k: ec.get(k) for k in ("ing", "prod", "time", "made_in", "unlocked")}))
    mp = d("technology", "mining-productivity-3")
    sp = d("technology", "steam-power")
    live_lib.report(mp.get("max_level", 0) >= 4294967295 and mp.get("formula"), "pedia: an infinite technology's max level and cost formula",
           str({k: mp.get(k) for k in ("level", "max_level", "formula", "count", "effects")}))
    live_lib.report(sp.get("trigger") and sp["trigger"][0] != "", "pedia: a trigger technology's trigger", str(sp.get("trigger")))
    biter = d("entity", "small-biter")
    live_lib.report(biter.get("hp") == 15 and biter.get("type") == "unit", "pedia: an enemy's health and resistances", str({k: biter.get(k) for k in ("hp", "res", "speed")}))
    water = d("tile", "water")
    vul = d("planet", "vulcanus")
    leg = d("quality", "legendary")
    live_lib.report(water.get("fluid") == "water" and vul.get("props", {}).get("pressure") == 4000 and leg.get("level") == 5 and vul.get("links"),
           "pedia: a tile's fluid, a planet's properties and connections, a quality's level",
           f"water {water.get('fluid')}, vulcanus {vul.get('props')} {vul.get('links')}, legendary {leg.get('level')} {leg.get('mult')}")
    live_lib.report(d("item", "speed-module").get("module") and got.get(("item", "no-such-thing"), {}).get("found") == 0,
           "pedia: a module's effects; an unknown page answers found 0", str(d("item", "speed-module").get("module")))
    ore = d("entity", "iron-ore")
    live_lib.report(ore.get("mine") and ore["mine"][0][1] == "iron-ore", "pedia: a resource's mining result", str(ore.get("mine")))
    sizes = {k: v for k, v in c.max_size.items() if k in ("pidx", "pedia")}
    live_lib.report(max(sizes.values() or [0]) < 60000, "pedia messages fit a datagram", str(sizes))

    # Technologies: effects, levels, trigger details, saved progress.
    c.send({"t": "hello", "v": 1, "sid": c.sid, "w": 1})
    rcon_out = live_lib.mod_lua("storage.f3d.techs_dirty = true rcon.print('ok')")
    # A big save's technologies come in several parts, behind the Factoriopedia pages.
    msgs = c.pump(20, every=hello, until=lambda m: m.get("t") == "techs" and m["part"] == m["parts"])
    techs = {r[0]: r for m in live_lib.of_type(msgs, "techs") for r in m["l"]}
    infinite = [r for r in techs.values() if len(r) == 15 and r[10] == -1]
    trig = [r for r in techs.values() if len(r) == 15 and r[11]]
    unlock = techs.get("automation", [])
    essential = [r[0] for r in techs.values() if len(r) == 15 and r[14] == 1]
    live_lib.report(techs and all(len(r) == 15 for r in techs.values()) and infinite and trig and 0 < len(essential) < len(techs)
           and ["unlock-recipe", "assembling-machine-1", 0] in (unlock[8] if len(unlock) == 15 else []),
           "techs: effects, levels (infinite ones), trigger details, saved progress, essential", f"{len(techs)} technologies, "
           f"{len(essential)} essential, "
           f"{len(infinite)} infinite (e.g. {infinite[0][0] if infinite else '-'} level {infinite[0][9] if infinite else '-'}), "
           f"{len(trig)} triggered (e.g. {trig[0][0] + ' ' + str(trig[0][11]) if trig else '-'}), {rcon_out}")

    # Statistics: building counts, pollution, all surfaces, graph lines.
    c.send({"t": "stats", "kind": "build", "prec": 8})
    c.send({"t": "stats", "kind": "pollution", "prec": 4, "g": []})
    c.send({"t": "stats", "kind": "item", "prec": 4, "si": 0, "g": ["iron-plate"]})
    c.send({"t": "stats", "kind": "fluid", "prec": 9})
    msgs = c.pump(3, every=hello)
    st = {m["kind"]: m for m in live_lib.of_type(msgs, "stats")}
    live_lib.report("build" in st and "pollution" in st and "item" in st, "stats: building counts and pollution answer",
           f"build {list(st.get('build', {}).get('l') or [])[:2]}, pollution {list(st.get('pollution', {}).get('l') or [])[:2]}")
    gr = st.get("item", {}).get("gr", [])
    live_lib.report(gr and gr[0][0] == "iron-plate" and len(gr[0][1]) == 60 and st["item"].get("si") == 0,
           "stats: graph lines (60 samples of 300) summed over all surfaces", f"{gr[0][1][:6] if gr else gr}")
    live_lib.report(st.get("fluid", {}).get("prec") == 9, "stats: All (prec 9), rows by all-time totals",
           f"{list(st.get('fluid', {}).get('l') or [])[:2]}")

    # The Bonuses and Permissions windows.
    c.send({"t": "bonuses"})
    c.send({"t": "perms"})
    msgs = c.pump(2, every=hello)
    bonus = live_lib.of_type(msgs, "bonus")
    perms = live_lib.of_type(msgs, "perms")
    live_lib.report(bonus and isinstance(bonus[-1]["l"], (list, dict)), "bonus: the force's research bonuses (LuaForce modifiers, ammo, turrets)",
           f"{[r[:2] for r in (bonus[-1]['l'] if bonus and isinstance(bonus[-1]['l'], list) else [])][:8]}")
    live_lib.report(perms and any(g[0] == "Default" for g in perms[-1]["l"]), "perms: the permission groups (game.permissions.groups)",
           f"{perms[-1]['l'][:4] if perms else perms}")

    # The logistic networks window (L).
    c.send({"t": "lnets"})
    msgs = c.pump(2, every=hello)
    nets = live_lib.of_type(msgs, "lnets")
    l = nets[-1]["l"] if nets else []
    l = l if isinstance(l, list) else []  # none: table_to_json writes {}
    live_lib.report(nets, "lnets: every logistic network of the force", f"{len(l)} networks: {l[:3]}")
    if l:
        busiest = max(l, key=lambda r: r[3][1] + r[4][1])
        c.send({"t": "lnet", "id": busiest[0]})
        msgs = c.pump(2, every=hello)
        one = live_lib.of_type(msgs, "lnet")
        live_lib.report(one and one[-1]["found"] == 1 and one[-1]["log"][1] == busiest[3][1], "lnet: one network's robots and items",
               f"network {busiest[0]}: {len(one[-1].get('items', [])) if one else 0} items, first {list(one[-1].get('items', []))[:3] if one else ''}")

    # Alerts: whatever the save has, then ones made here.
    msgs = c.pump(4, every=hello)
    al = live_lib.of_type(msgs, "al")
    seen = {a[0]: a[1] for a in al[-1]["l"]} if al else {}
    live_lib.report(al, "al: the force's alerts once a second", f"in the save: {seen}")
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "alerts: no clean spot found")
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    out = live_lib.mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local x, y = {x}, {y}
local function put(name, dx, dy)
  local e = s.create_entity({{ name = name, position = {{ x + dx, y + dy }}, force = c.force, raise_built = true }})
  return e
end
local t = put("gun-turret", 4, 4)
local a = put("assembling-machine-1", -4.5, 4.5)
local hurt = put("wooden-chest", 6.5, -3.5)
local doomed = put("iron-chest", 7.5, -3.5)
local rp = put("roboport", -6, -6)
local gp = {{ x - 3.5, y - 6.5 }}
local missing = "steel-chest"
for _, name in pairs({{ "steel-chest", "rocket-silo", "nuclear-reactor", "centrifuge", "artillery-turret", "lab", "radar" }}) do
  local have = false
  for _, net in pairs(s.find_logistic_networks_by_construction_area(gp, c.force)) do
    if net.get_item_count(name) > 0 then have = true end
  end
  if not have then missing = name break end
end
local g = s.create_entity({{ name = "entity-ghost", inner_name = missing, position = gp, force = c.force }})
hurt.damage(20, game.forces.enemy)
doomed.die(game.forces.enemy)
rcon.print(t.unit_number .. " " .. a.unit_number .. " " .. hurt.unit_number .. " " .. rp.unit_number .. " " .. g.unit_number .. " " .. tostring(a.status))
""".replace("\n", " "))
    vals = out.split()
    if len(vals) < 5:
        live_lib.report(False, "alerts: building the test entities", out)
        return
    turret, asm, hurt, rp, ghost = (int(v) for v in vals[:5])
    msgs = c.pump(2.2, every=hello)
    al = live_lib.of_type(msgs, "al")
    kinds = {a[0]: a for a in al[-1]["l"]} if al else {}
    units = lambda k: [e[4] for e in kinds.get(k, [None, 0, []])[2]]
    live_lib.report(hurt in units("attack"), "al: under attack (on_entity_damaged by the enemy force)", str(kinds.get("attack", "")[:2]))
    live_lib.report(any(e[3] == "iron-chest" for e in kinds.get("destroyed", [0, 0, []])[2]), "al: destroyed (on_entity_died)",
           str(kinds.get("destroyed", "")[:2]))
    # The entity scans make a pass over every chunk at most every 10 s, spread over several seconds.
    # The turret is seen round the focus within a second (J22, status_near), the ghost only by a pass: wait for both.
    has_turret = lambda m: m.get("t") == "al" and any(a[0] == "no_ammo" and any(e[4] == turret for e in a[2]) for a in m["l"])
    has_ghost = lambda m: m.get("t") == "al" and any(a[0] in ("no_material", "no_robots") and any(e[4] == ghost for e in a[2]) for a in m["l"])
    started = time.time()
    msgs = c.pump(30, every=hello, until=lambda m: has_turret(m) and has_ghost(m))
    msgs += c.pump(1.2, every=hello)
    al = live_lib.of_type(msgs, "al")
    kinds = {a[0]: a for a in al[-1]["l"]} if al else {}
    live_lib.report(turret in units("no_ammo"), "al: a gun turret without ammo (turret_ammo inventory empty)",
           f"seen after {time.time() - started:.1f} s: {str(kinds.get('no_ammo', '')[:2])}")
    live_lib.report(asm in units("unplugged") or asm in units("no_power"), "al: a machine out of reach of poles",
           f"status {vals[5:]}; unplugged {kinds.get('unplugged', '')[:2]}")
    live_lib.report(ghost in units("no_material") or ghost in units("no_robots"),
           "al: a ghost in a roboport's construction area without its item (find_logistic_networks_by_construction_area)",
           f"no_material {[e for e in kinds.get('no_material', [0, 0, []])[2] if e[4] == ghost]}, "
           f"no_robots {[e for e in kinds.get('no_robots', [0, 0, []])[2] if e[4] == ghost]}")
    msgs = c.pump(max(1.5, 7 - (time.time() - started)), every=hello)
    al = live_lib.of_type(msgs, "al")
    kinds = {a[0]: a for a in al[-1]["l"]} if al else {}
    live_lib.report(hurt not in units("attack") and any(e[3] == "iron-chest" for e in kinds.get("destroyed", [0, 0, []])[2]),
           "al: under attack ends after 5 s, destroyed stays")
    live_lib.destroy_units([turret, asm, hurt, rp, ghost])
    live_lib.mod_lua("local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({ type = 'entity-ghost', "
            f"area = {{ {{ {x - 8}, {y - 8} }}, {{ {x + 8}, {y + 8} }} }} }})) do e.destroy() end")
    sizes = {k: v for k, v in c.max_size.items() if k in ("al", "lnets", "lnet", "stats", "techs")}
    live_lib.report(max(sizes.values() or [0]) < 60000, "info messages fit a datagram", str(sizes))


def check_hud(c, hello):
    """The HUD's data from ui-hud2: the magazine's rounds in `guns` (LuaItemStack.ammo,
    magazine_size), the character's own logistic sections (clog.sec, set_section u 0 on the
    requester LuaLogisticPoint) and its colour (set_char_color, ccol)."""
    # --- rounds left in the magazine (4, or 3 when a run before left 4) ---------------------------
    out = live_lib.mod_lua("""
local c = storage.f3d.puppet
local guns = c.get_inventory(defines.inventory.character_guns)
local ammo = c.get_inventory(defines.inventory.character_ammo)
local rounds = (ammo[1].valid_for_read and ammo[1].name == "firearm-magazine" and ammo[1].ammo == 4) and 3 or 4
guns[1].set_stack({ name = "submachine-gun", count = 1 })
ammo[1].set_stack({ name = "firearm-magazine", count = 20 })
ammo[1].ammo = rounds
c.selected_gun_index = 1
rcon.print(ammo[1].ammo .. " " .. prototypes.item["firearm-magazine"].magazine_size)
""".replace("\n", " "))
    rounds = int(out.split()[0]) if out and out.split()[0].isdigit() else 4
    msgs = c.pump(3, every=hello, until=lambda m: m.get("t") == "guns" and m["l"] and len(m["l"][0]) >= 5 and m["l"][0][3] == rounds)
    guns = live_lib.of_type(msgs, "guns")
    live_lib.report(guns and guns[-1]["l"][0][:5] == ["submachine-gun", "firearm-magazine", 20, rounds, 10],
           "guns: the magazine's rounds left and its size (LuaItemStack.ammo, magazine_size)", f"{out} {guns[-1:]}")

    # --- the character's logistic sections ---------------------------------------------------------
    live_lib.mod_lua("game.forces.player.character_logistic_requests = true rcon.print('ok')")
    c.pump(1, every=hello)
    count = live_lib.mod_lua("rcon.print(storage.f3d.puppet.get_requester_point().sections_count)")
    before = int(count) if count.isdigit() else 0
    c.send({"t": "set_section", "u": 0, "i": 0, "g": "F3D live check"})
    msgs = c.pump(3, every=hello, until=lambda m: m.get("t") == "clog" and len(m.get("sec", [])) == before + 1)
    clog = live_lib.of_type(msgs, "clog")
    live_lib.report(clog and isinstance(clog[-1].get("sec"), list) and isinstance(clog[-1].get("lgs", []), (list, dict)),
           "clog.sec: the character's logistic sections (LuaLogisticPoint.sections) and the force's groups",
           str(clog[-1:])[:300])
    new = clog[-1]["sec"][-1] if clog and clog[-1].get("sec") else {}
    live_lib.report(new.get("g") == "F3D live check", "set_section u 0 adds a section to the character in a group (add_section)", str(new))
    i = new.get("i", 0)
    c.send({"t": "set_section", "u": 0, "i": i, "on": 0, "f": [["iron-gear-wheel", "normal", 25, -1, "", -1]]})
    msgs = c.pump(3, every=hello, until=lambda m: m.get("t") == "clog" and any(x.get("i") == i and x.get("on") == 0 for x in m.get("sec", [])))
    clog = live_lib.of_type(msgs, "clog")
    sec = next((x for x in (clog[-1]["sec"] if clog else []) if x.get("i") == i), {})
    live_lib.report(sec.get("on") == 0 and sec.get("f", [[]])[0][:3] == ["iron-gear-wheel", "normal", 25],
           "set_section u 0: a character section off (LuaLogisticSection.active) with its requests", str(sec))
    c.send({"t": "set_section", "u": 0, "i": i, "del": 1})
    msgs = c.pump(3, every=hello, until=lambda m: m.get("t") == "clog" and len(m.get("sec", [])) == before)
    count = live_lib.mod_lua("rcon.print(storage.f3d.puppet.get_requester_point().sections_count)")
    live_lib.report(count == str(before), "set_section u 0 del removes it (remove_section)", count)
    live_lib.mod_lua("""for _, g in pairs(game.forces.player.get_logistic_groups()) do
  if g == "F3D live check" then pcall(function() game.forces.player.delete_logistic_group(g) end) end end rcon.print('ok')""".replace("\n", " "))

    # --- the character's colour --------------------------------------------------------------------
    was = live_lib.mod_lua("local col = storage.f3d.puppet.color rcon.print(math.floor(col.r * 255 + 0.5) .. ' ' .. math.floor(col.g * 255 + 0.5) .. ' ' .. math.floor(col.b * 255 + 0.5))")
    c.send({"t": "set_char_color", "c": [12, 200, 56]})
    msgs = c.pump(3, every=hello, until=lambda m: m.get("t") == "ccol" and m["c"] == [12, 200, 56])
    now = live_lib.mod_lua("local col = storage.f3d.puppet.color rcon.print(math.floor(col.r * 255 + 0.5) .. ' ' .. math.floor(col.g * 255 + 0.5) .. ' ' .. math.floor(col.b * 255 + 0.5))")
    live_lib.report(live_lib.of_type(msgs, "ccol") and now == "12 200 56", "set_char_color sets LuaEntity.color and ccol says so", f"{was} -> {now}")
    if was and len(was.split()) == 3:
        c.send({"t": "set_char_color", "c": [int(v) for v in was.split()]})
        c.pump(1, every=hello)
