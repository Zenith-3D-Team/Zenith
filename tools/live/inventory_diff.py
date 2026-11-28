"""Differential live checks of slot moves (`move`, the cursor's click), shift / ctrl transfers and hand
crafting against the game's own inventory rules (LuaInventory.can_insert, filters, bars), in every inventory
type the client's windows show. The client's cursor is a slot plus a count; every click is a `move`, so what
the game would refuse (a plate into a fuel slot, anything into a result slot, a slot beyond a chest's limit
bar, a gun into an ammo slot) the bridge has to refuse too, for the whole stack and for the right click's one."""
from __future__ import annotations

from . import live_lib

ITEMS = [
    "iron-plate", "iron-ore", "coal", "wood", "solid-fuel", "firearm-magazine", "piercing-rounds-magazine", "cannon-shell",
    "flamethrower-ammo", "rocket", "pistol", "submachine-gun", "light-armor", "heavy-armor", "automation-science-pack",
    "construction-robot", "repair-pack", "speed-module", "wooden-chest", "iron-gear-wheel", "copper-ore", "stone",
]

# key: (prototype, dx, dy, setup Lua on `e`, [(bridge role, defines.inventory name), ...])
ENTITIES = {
    "wooden-chest": ("wooden-chest", 6.5, 0.5, "", [("chest", "chest")]),
    "steel-chest": ("steel-chest", 6.5, 2.5, "", [("chest", "chest")]),
    "furnace": ("stone-furnace", -6, 1, "", [("input", "crafter_input"), ("fuel", "fuel"), ("output", "crafter_output")]),
    "assembler": ("assembling-machine-2", 0.5, 7.5, "e.set_recipe('iron-gear-wheel')",
                  [("input", "crafter_input"), ("output", "crafter_output"), ("modules", "crafter_modules")]),
    "lab": ("lab", -6.5, -5.5, "", [("input", "lab_input"), ("modules", "lab_modules")]),
    "boiler": ("boiler", 6, -3, "", [("fuel", "fuel")]),
    "turret": ("gun-turret", 3, -7, "", [("turret_ammo", "turret_ammo")]),
    "roboport": ("roboport", -7, 7, "", [("robots", "roboport_robot"), ("repair", "roboport_material")]),
    "buffer": ("buffer-chest", 9.5, 0.5, "", [("chest", "chest")]),  # (its trash slots share the role name "trash" with the character's: untested)
    "car": ("car", -2, -8, "", [("trunk", "car_trunk"), ("car_ammo", "car_ammo"), ("fuel", "fuel")]),
    "tank": ("tank", 7, 6, "", [("trunk", "car_trunk"), ("car_ammo", "car_ammo"), ("fuel", "fuel")]),
}
CHARACTER = [("guns", "character_guns"), ("ammo", "character_ammo"), ("armor", "character_armor"), ("trash", "character_trash")]


def check_inventory_diff(c, hello):
    """One section: every (entity, inventory, item) move against can_insert, then the odd rules."""
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "invdiff: no clean spot found", live_lib.SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    fx = lambda v: int(round(v * 256))
    lua = lambda code: live_lib.mod_lua(code.replace("\n", " "))
    # Make every recipe the checks use known and the research the items need available is not needed: items are given by script.
    stack_size = {item: int(lua(f"rcon.print(prototypes.item['{item}'].stack_size)") or 1) for item in ITEMS}
    import os
    only = [k for k in os.environ.get('INVDIFF_ONLY', '').split(',') if k]
    made = {}
    for key, (proto, dx, dy, setup, roles) in ENTITIES.items():
        if only and key not in only:
            continue
        out = lua(f"""
local c = storage.f3d.puppet local s = c.surface
local e = s.create_entity({{ name = '{proto}', position = {{ {x} + {dx}, {y} + {dy} }}, force = c.force, raise_built = true }})
if not e then rcon.print('0 0 0') return end
{setup}
rcon.print(e.unit_number .. ' ' .. e.position.x .. ' ' .. e.position.y)""")
        v = out.split()
        if len(v) == 3 and v[0] != "0":
            made[key] = (int(v[0]), float(v[1]), float(v[2]))
        else:
            live_lib.report(False, f"invdiff: building {proto}", out)
    c.pump(1.0, every=hello)

    def entity(u):
        return (f"(function() local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({{ position = c.position, radius = 30, force = c.force }})) do "
                f"if e.unit_number == {u} then return e end end end)()")

    def inv_expr(key, define):
        if key == "char":
            return f"storage.f3d.puppet.get_inventory(defines.inventory.{define})"
        return f"{entity(made[key][0])}.get_inventory(defines.inventory.{define})"

    def opened(key):
        if key == "char":
            return
        u, ex, ey = made[key]
        c.send({"t": "close"})
        c.pump(0.15, every=hello)
        c.send({"t": "open", "u": u, "p": c.proto_id(ENTITIES[key][0]), "x": fx(ex), "y": fx(ey)})
        c.pump(0.35, every=hello)
        scr = lua("rcon.print(storage.f3d.screen and storage.f3d.screen.unit or 'none')")
        if scr != str(u):
            live_lib.report(False, f"invdiff: the {key}'s screen opens", f"screen unit {scr}, wanted {u}")

    def clear_all(key):
        if key == "char" or key not in made:
            return
        lua(" ".join(f";{inv_expr(key, d)}.clear()" for _, d in ENTITIES[key][4]).lstrip(";") + " rcon.print('ok')")

    def stack_of(expr, i):
        return f"(function() local st = {expr}[{i}] return st.valid_for_read and (st.name .. ':' .. st.count) or '-' end)()"

    def read(expr, i):
        return lua(f"rcon.print({stack_of(expr, i)})")

    # ---- 1. move main -> inventory: the whole stack (n 0) and one (the right click), every item.
    for key, defs in [("char", CHARACTER)] + [(k, ENTITIES[k][4]) for k in made]:
        if key != "char" and key not in made:
            continue
        opened(key)
        for role, define in defs:
            exists = lua(f"local i = {inv_expr(key, define)} rcon.print(i and #i or 0)")
            if exists in ("", "0", "nil"):
                continue
            wrong = []
            for item in ITEMS:
                for n in (0, 1):
                    clear_all(key)
                    # (A furnace's source takes whatever some smelting recipe uses, by hand: can_insert also asks about its last recipe.)
                    smelt_rule = f"(function() for _, r in pairs(prototypes.recipe) do if r.categories[1] == 'smelting' and storage.f3d.puppet.force.recipes[r.name].enabled then for _, g in pairs(r.ingredients) do if g.name == '{item}' then return true end end end end return false end)()"
                    have = min(3, stack_size[item])
                    cap = 1 if role == 'modules' else 99
                    pre = lua(f"""local i = {inv_expr(key, define)} i.clear()
local m = storage.f3d.puppet.get_main_inventory() m.clear() m[1].set_stack({{ name = '{item}', count = {have} }})
rcon.print(tostring({smelt_rule if (key, role) == ('furnace', 'input') else f"i.can_insert({{ name = '{item}' }})"}))""")
                    ti = int(lua(f"""local i = {inv_expr(key, define)} i.clear() local r = i.insert({{ name = '{item}', count = 1 }}) local at = 1
for k = 1, #i do if i[k].valid_for_read then at = k end end i.clear() rcon.print(at)""") or 1)
                    cmd = {"t": "move", "from": "main", "fi": 1, "to": role, "ti": ti, "n": n}
                    if key != "char":
                        cmd["u"] = made[key][0]
                    c.send(cmd)
                    c.pump(0.18, every=hello)
                    got = read(inv_expr(key, define), ti)
                    src = read("storage.f3d.puppet.get_main_inventory()", 1)
                    moved = min(cap, n if n and n < have else have)
                    want_ok = pre == "true" and not (key in ("furnace", "assembler") and role == "output")
                    want = f"{item}:{moved}" if want_ok else "-"
                    want_src = (f"{item}:{have - moved}" if have - moved > 0 else "-") if want_ok else f"{item}:{have}"
                    if got != want or src != want_src:
                        wrong.append(f"{item}/n{n}: can_insert {pre}, slot {got}, main {src}")
            live_lib.report(not wrong, f"invdiff move {key}.{role}: every item goes in iff the game's can_insert says so (whole stack and one)",
                            "; ".join(wrong[:6]) + (f" (+{len(wrong) - 6})" if len(wrong) > 6 else ""))

    # ---- 2. take out: a stack from each role back into a main slot (n 0 whole, n half).
    for key, defs in [("char", CHARACTER)] + [(k, ENTITIES[k][4]) for k in made]:
        opened(key)
        for role, define in defs:
            if role in ("output",) and key in ("furnace",):
                pass
            exists = lua(f"local i = {inv_expr(key, define)} rcon.print(i and #i or 0)")
            if exists in ("", "0", "nil"):
                continue
            item = {"guns": "pistol", "ammo": "firearm-magazine", "armor": "light-armor", "trash": "iron-plate", "fuel": "coal",
                    "turret_ammo": "firearm-magazine", "car_ammo": "firearm-magazine", "robots": "construction-robot",
                    "repair": "repair-pack", "modules": "speed-module", "input": {"furnace": "iron-ore", "assembler": "iron-plate",
                    "lab": "automation-science-pack"}.get(key, "iron-plate"), "output": "iron-plate" if key == "furnace" else "iron-gear-wheel"}.get(role, "iron-plate")
            cnt = min(1 if role == 'modules' else 4, int(lua(f"rcon.print(prototypes.item['{item}'].stack_size)") or 1))
            for n, want in ((0, cnt), (2, 2)):
                if want > cnt or (n and cnt < 2):
                    continue
                clear_all(key)
                setup = lua(f"{inv_expr(key, define)}.clear() local r = {inv_expr(key, define)}.insert({{ name = '{item}', count = {cnt} }}) "
                            f"storage.f3d.puppet.get_main_inventory().clear() rcon.print(r)")
                at = int(lua(f"local i = {inv_expr(key, define)} local at = 1 for k = 1, #i do if i[k].valid_for_read then at = k end end rcon.print(at)") or 1)
                cmd = {"t": "move", "from": role, "fi": at, "to": "main", "ti": 1, "n": n}
                if key != "char":
                    cmd["u"] = made[key][0]
                c.send(cmd)
                msgs = c.pump(0.2, every=hello)
                src = read(inv_expr(key, define), at)
                dst = read("storage.f3d.puppet.get_main_inventory()", 1)
                live_lib.report(setup == str(cnt) and dst == f"{item}:{want}" and src == (f"{item}:{cnt - want}" if cnt - want else "-"),
                                f"invdiff take {key}.{role} n={n}: {want} of {cnt} {item} into the inventory",
                                f"setup {setup}, slot {src}, main {dst}, {[m.get('text') for m in live_lib.of_type(msgs, 'msg')]}")

    # ---- 3. slots beyond a chest's limit bar allow manual clicks (`move`), while `xfer`/insert stops at the bar.
    key = "steel-chest"
    if key in made:
        opened(key)
        lua(f"local i = {inv_expr(key, 'chest')} i.clear() i.set_bar(5) local m = storage.f3d.puppet.get_main_inventory() m.clear() m[1].set_stack({{ name = 'iron-plate', count = 10 }}) rcon.print('ok')")
        for ti in (4, 5, 6, 20):
            lua("storage.f3d.puppet.get_main_inventory()[1].set_stack({ name = 'iron-plate', count = 10 })" + f" ;{inv_expr(key, 'chest')}.clear() rcon.print('ok')")
            c.send({"t": "move", "from": "main", "fi": 1, "to": "chest", "ti": ti, "n": 0, "u": made[key][0]})
            c.pump(0.25, every=hello)
            got = read(inv_expr(key, "chest"), ti)
            live_lib.report(got == "iron-plate:10", f"invdiff steel chest bar 5: manual move to slot {ti} takes a stack", f"slot {got}")
        lua(f"local i = {inv_expr(key, 'chest')} i.clear() for k = 1, 4 do i[k].set_stack({{ name = 'iron-plate', count = 100 }}) end local m = storage.f3d.puppet.get_main_inventory() m.clear() m[1].set_stack({{ name = 'iron-plate', count = 10 }}) rcon.print('ok')")
        c.send({"t": "xfer", "from": "main", "fi": 1, "k": "stack", "u": made[key][0]})
        c.pump(0.25, every=hello)
        got5 = read(inv_expr(key, "chest"), 5)
        got_main = read("storage.f3d.puppet.get_main_inventory()", 1)
        live_lib.report(got5 == "-" and got_main == "iron-plate:10", "invdiff steel chest bar 5: xfer stops at the limit bar", f"slot 5 {got5}, main {got_main}")
        lua(f"{inv_expr(key, 'chest')}.set_bar() ;{inv_expr(key, 'chest')}.clear() rcon.print('ok')")

    # ---- 4. swaps between different items: the game swaps only if the other stack fits the slot.
    swaps = [("furnace", "fuel", "fuel", "coal", "wood", True), ("furnace", "fuel", "fuel", "coal", "iron-plate", False),
             ("furnace", "input", "crafter_input", "iron-ore", "copper-ore", True), ("furnace", "input", "crafter_input", "iron-ore", "coal", False),
             ("char", "armor", "character_armor", "light-armor", "heavy-armor", True), ("char", "armor", "character_armor", "light-armor", "iron-plate", False),
             ("char", "guns", "character_guns", "pistol", "submachine-gun", True), ("char", "guns", "character_guns", "pistol", "firearm-magazine", False),
             ("char", "ammo", "character_ammo", "firearm-magazine", "piercing-rounds-magazine", True), ("char", "ammo", "character_ammo", "firearm-magazine", "pistol", False),
             ("turret", "turret_ammo", "turret_ammo", "firearm-magazine", "piercing-rounds-magazine", True), ("turret", "turret_ammo", "turret_ammo", "firearm-magazine", "coal", False),
             ("wooden-chest", "chest", "chest", "iron-plate", "copper-ore", True)]
    for key, role, define, a, b, ok in swaps:
        if key != "char" and key not in made:
            continue
        opened(key)
        clear_all(key)
        na = min(2, int(lua(f"rcon.print(prototypes.item['{a}'].stack_size)") or 1))
        nb = min(3, int(lua(f"rcon.print(prototypes.item['{b}'].stack_size)") or 1))
        lua(f"{inv_expr(key, define)}.clear() ;{inv_expr(key, define)}[1].set_stack({{ name = '{a}', count = {na} }}) local m = storage.f3d.puppet.get_main_inventory() m.clear() m[1].set_stack({{ name = '{b}', count = {nb} }}) rcon.print('ok')")
        cmd = {"t": "move", "from": "main", "fi": 1, "to": role, "ti": 1, "n": 0}
        if key != "char":
            cmd["u"] = made[key][0]
        c.send(cmd)
        c.pump(0.25, every=hello)
        slot = read(inv_expr(key, define), 1)
        main = read("storage.f3d.puppet.get_main_inventory()", 1)
        want = (f"{b}:{nb}", f"{a}:{na}") if ok else (f"{a}:{na}", f"{b}:{nb}")
        live_lib.report((slot, main) == want, f"invdiff swap {key}.{role}: {b} over {a} {'swaps' if ok else 'is refused'}", f"slot {slot}, main {main}")

    live_lib.destroy_units([u for u, _, _ in made.values()])
    lua("storage.f3d.puppet.get_main_inventory().clear() rcon.print('ok')")
    c.send({"t": "close"})
    c.pump(0.2, every=hello)
