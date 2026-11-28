"""Differential live checks of the character's gear and combat controls against the real game (bughunt combat2):
which ammo a gun fires (the game's own pairing against the bridge's `guns` list), the turret priority list the
client edits against LuaEntity.priority_targets, and putting every equipment into every armour grid at the edge
cells against the game's own placement rules.
Run: python tools/live_check.py --only combdiff"""
from __future__ import annotations

from . import live_lib


def check_combat_diff(c, hello):
    if not live_lib.clean_spot(c, hello, half=20):
        live_lib.report(False, "combdiff: no clean spot found", live_lib.SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    fx = lambda v: int(round(v * 256))
    lua = lambda code: live_lib.mod_lua(code.replace("\n", " "))
    c.send({"t": "focus", "x": c.me["x"], "y": c.me["y"], "r": 48})

    # ---- 1. the ammo a gun fires: ammo only in slot 2 / the wrong ammo in slot 1.
    def rounds():
        return lua("""local a = storage.f3d.puppet.get_inventory(defines.inventory.character_ammo)
local t = {} for i = 1, #a do t[#t + 1] = a[i].valid_for_read and (a[i].name .. ':' .. a[i].count) or '-' end rcon.print(table.concat(t, ' '))""")

    def fire_with(guns, ammo, label):
        lua(f"""local c = storage.f3d.puppet
local gi = c.get_inventory(defines.inventory.character_guns) gi.clear()
local ai = c.get_inventory(defines.inventory.character_ammo) ai.clear()
for i, n in pairs({{ {guns} }}) do gi[i].set_stack({{ name = n }}) end
for i, a in pairs({ammo}) do ai[i].set_stack({{ name = a[1], count = a[2] }}) end
c.selected_gun_index = 1 storage.f3d.guns_sig = nil rcon.print('ok')""")
        out = lua("""local c = storage.f3d.puppet local s = c.surface
local p = s.find_non_colliding_position('medium-biter', { c.position.x + 7, c.position.y }, 4, 0.5)
local b = s.create_entity({ name = 'medium-biter', position = p, force = 'enemy' }) b.disabled_by_script = true
rcon.print(b.position.x .. ' ' .. b.position.y)""")
        bx, by = (float(v) for v in out.split())
        before = rounds()
        msgs = c.pump(0.6, every=hello)
        guns = [m for m in live_lib.of_type(msgs, "guns")]
        g0 = guns[-1] if guns else c.last.get("guns")
        msgs = c.pump(1.2, every=(0.15, {"t": "shoot", "m": 1, "x": fx(bx), "y": fx(by)}))
        c.send({"t": "shoot", "m": -1})
        msgs += c.pump(0.8, every=hello)
        after = rounds()
        lua("for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({ type = 'unit', position = storage.f3d.puppet.position, radius = 30 })) do e.destroy() end rcon.print('ok')")
        hint = [m.get("text") for m in live_lib.of_type(msgs, "msg")]
        print(f"  INFO {label}: ammo {before} -> {after}; guns msg {g0 and g0.get('l')}; messages {hint}")
        return before, after, g0, hint

    b, a, g0, hint = fire_with('"pistol"', '{ [2] = { "firearm-magazine", 10 } }', "pistol, magazines only in ammo slot 2")
    live_lib.report(True, "INFO: a pistol with ammo only in slot 2 " + ("fires it (the game looks across slots)" if a != b else "does not fire (paired slots)"),
                    f"{b} -> {a}; guns[0] {g0 and g0['l'][0]}; {hint}")
    b, a, g0, hint = fire_with('"pistol"', '{ { "flamethrower-ammo", 5 }, { "firearm-magazine", 10 } }', "pistol, flamethrower ammo in slot 1 + magazines in slot 2")
    live_lib.report(True, "INFO: pistol, wrong ammo in 1 and magazines in 2", f"{b} -> {a}; guns[0] {g0 and g0['l'][0]}; {hint}")
    lua("local c = storage.f3d.puppet c.get_inventory(defines.inventory.character_guns).clear() c.get_inventory(defines.inventory.character_ammo).clear() rcon.print('ok')")

    # ---- 2. the turret priority list the client's picker edits: the game against what the client sent.
    out = lua(f"""local c = storage.f3d.puppet local e = c.surface.create_entity({{ name = 'gun-turret', position = {{ {x} + 6, {y} - 6 }}, force = c.force, raise_built = true }})
rcon.print(e.unit_number .. ' ' .. e.position.x .. ' ' .. e.position.y)""")
    u, ex, ey = out.split()
    u = int(u)
    proto = c.proto_id("gun-turret")
    cases = {
        "a wooden chest in the list": ["small-biter", "wooden-chest", "medium-biter"],
        "the same enemy twice": ["small-biter", "small-biter"],
        "eleven entries": ["small-biter", "medium-biter", "big-biter", "behemoth-biter", "small-spitter", "medium-spitter", "big-spitter",
                           "behemoth-spitter", "small-worm-turret", "medium-worm-turret", "big-worm-turret"],
    }
    for label, names in cases.items():
        c.send({"t": "close"})
        c.pump(0.1, every=hello)
        c.send({"t": "open", "u": u, "p": proto, "x": fx(float(ex)), "y": fx(float(ey))})
        c.pump(0.3, every=hello)
        c.send({"t": "set_targets", "u": u, "l": names})
        msgs = c.pump(0.6, every=hello)
        got = lua(f"""local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({{ position = c.position, radius = 30, name = 'gun-turret' }})) do
if e.unit_number == {u} then local l = {{}} for _, p in pairs(e.priority_targets) do l[#l + 1] = p.name end rcon.print(table.concat(l, ',')) end end""")
        said = [m.get("text") for m in live_lib.of_type(msgs, "msg")]
        live_lib.report(got == ",".join(names), f"turret targets: {label}: the game keeps what the client sent",
                        f"sent {names}, game {got!r}, messages {said}")
    c.send({"t": "close"})
    live_lib.destroy_units([u])

    # ---- 3. equipment into every armour grid, at the edge cell and past it.
    armors = ["modular-armor", "power-armor", "power-armor-mk2"]
    out = lua("""local t = {} for n, it in pairs(prototypes.item) do local r = it.place_as_equipment_result if r then t[#t + 1] = n .. '=' .. r.name end end table.sort(t) rcon.print(table.concat(t, ' '))""")
    items = [p.split("=") for p in out.split()]
    wrong = []
    for armor in armors:
        for item, eqname in items:
            if eqname == "electric-energy-interface-equipment":
                continue  # (a debug piece: stack size 1)
            lua(f"""local c = storage.f3d.puppet local a = c.get_inventory(defines.inventory.character_armor) a[1].clear() a[1].set_stack({{ name = '{armor}' }}) rcon.print('ok')""")
            sw, sh_, w, h = (int(v) for v in lua(f"""local g = storage.f3d.puppet.grid local p = prototypes.equipment['{eqname}'] rcon.print(p.shape.width .. ' ' .. p.shape.height .. ' ' .. g.width .. ' ' .. g.height)""").split())
            for px, py in ((w - sw, h - sh_), (w - sw + 1, h - sh_), (w - sw, h - sh_ + 1)):
                want = lua(f"""local g = storage.f3d.puppet.grid g.clear() local ok, r = pcall(g.put, {{ name = '{eqname}', position = {{ {px}, {py} }} }}) g.clear() rcon.print(tostring(ok and r ~= nil))""") == "true"
                lua("local c = storage.f3d.puppet local m = c.get_main_inventory() m.clear() m[1].set_stack({ name = '%s', count = 2 }) c.grid.clear() rcon.print('ok')" % item)
                c.send({"t": "eq_put", "kind": "char", "fi": 1, "x": px, "y": py})
                c.pump(0.2, every=hello)
                res = lua("local g = storage.f3d.puppet.grid local e = g.get({ x = %d, y = %d }) local m = storage.f3d.puppet.get_main_inventory()[1] "
                          "rcon.print((e and e.name or '-') .. ' ' .. (m.valid_for_read and m.count or 0))" % (px, py))
                nm, left = res.split()
                placed = nm == eqname
                if placed != want or (placed and left != "1") or (not placed and left != "2"):
                    wrong.append(f"{armor}/{item} at {px},{py}: placed {nm}, {left} left, the game's put {want}")
    live_lib.report(not wrong, "eq_put: every equipment fits an armour grid exactly where the game's rules say (edge cells), one item used",
                    "; ".join(wrong[:6]) + (f" (+{len(wrong) - 6})" if len(wrong) > 6 else ""))
    lua("local c = storage.f3d.puppet c.get_inventory(defines.inventory.character_armor).clear() c.get_main_inventory().clear() rcon.print('ok')")
    c.pump(0.3, every=hello)
