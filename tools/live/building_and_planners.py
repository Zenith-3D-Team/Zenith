"""Building, blueprints, planners, alt-mode, belt switches, under-clear, and pipe live checks."""
from __future__ import annotations

import base64
import json
import math
import os
import pathlib
import shutil
import subprocess
import tempfile
import time
import zlib

import rcon

from . import live_lib

PIPE_STEPS = [(0, -1), (1, 0), (0, 1), (-1, 0)]



def check_alt(c, hello, keep=False):
    """Issue #9: Alt-mode's icons ride on the entity records with no cap (a 24 x 24 smelting array,
    576 furnaces, past the old 400), a furnace's icon follows the ore put in (aiu, no event), a recipe
    set from the open screen comes in aiu at once, and machines' recipes' fluids (extra.fa, aiu fa)
    and a recycler's output vector (eprops vp) for the arrows. `keep` leaves the test base standing
    (for screenshots)."""
    if not live_lib.clean_spot(c, hello, half=30):
        live_lib.report(False, "alt: no clean spot found", live_lib.SPOT_WHY)
        return
    x0, y0 = int(c.me["x"] / 256), int(c.me["y"] / 256)
    out = live_lib.mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local n = 0
c.force.enable_all_recipes()
for i = 0, 23 do for j = 0, 23 do
  local e = s.create_entity({{ name = "steel-furnace", position = {{ {x0} - 24 + i * 2 + 1, {y0} - 28 + j * 2 + 1 }}, force = c.force, raise_built = true }})
  if e then e.insert({{ name = "iron-ore", count = 20 }}) e.insert({{ name = "coal", count = 5 }}) n = n + 1 end
end end
rcon.print(n)""".replace("\n", " "))
    live_lib.report(out == "576", "alt: a 24 x 24 smelting array built", out)
    hello_now = hello[1]
    # The chunks round the array, sent again (snapshots) with their records.
    cx0, cy0 = (x0 - 24) // 32, (y0 - 28) // 32
    wanted = [[cx, cy] for cy in range(cy0 - 1, cy0 + 3) for cx in range(cx0 - 1, cx0 + 3)]
    c.send({"t": "sub", "c": wanted})
    c.send({"t": "resync", "full": 0, "c": wanted})
    msgs = c.pump(15.0, every=(1.0, hello_now))
    icons = {}
    for m in msgs:
        if m.get("t") in ("ents", "add", "upd"):
            for e in (m["e"] if m["t"] == "ents" else [m["e"]]):
                if len(e) > 5 and isinstance(e[5], dict) and "ai" in e[5]:
                    icons[e[0]] = e[5]["ai"]
        elif m.get("t") == "aiu":
            for row in m["l"]:
                icons[row[0]] = row[1:]
    plates = [u for u, i in icons.items() if i[:2] == ["recipe", "iron-plate"]]
    live_lib.report(len(plates) >= 576, "#9: every furnace of the array has its Alt-mode icon (records and aiu, no 400 cap)",
           f"{len(plates)} furnaces showing iron-plate, {len(icons)} icons in all")
    # A furnace switched to copper with no event: the watch sends it.
    out = live_lib.mod_lua(f"""
local s = storage.f3d.puppet.surface
local f = s.find_entities_filtered({{ name = "steel-furnace", position = {{ {x0} - 23, {y0} - 27 }}, radius = 0.6 }})[1]
local src = defines.inventory.crafter_input or defines.inventory.furnace_source
local res = defines.inventory.crafter_output or defines.inventory.furnace_result
f.get_inventory(src).clear() f.crafting_progress = 0 f.get_inventory(res).clear()
storage.f3d_live_furnace = f
rcon.print(f.unit_number)""".replace("\n", " "))
    fu = int(out) if out.isdigit() else 0
    msgs = c.pump(5.0, every=(1.0, hello_now))
    live_lib.mod_lua('storage.f3d_live_furnace.insert({ name = "copper-ore", count = 20 }) rcon.print("ok")')
    msgs += c.pump(8.0, every=(1.0, hello_now))
    rows = [r for m in msgs if m.get("t") == "aiu" for r in m["l"] if r[0] == fu]
    live_lib.report(fu and rows and rows[-1][1:3] == ["recipe", "copper-plate"],
           "#9: a furnace given copper ore (no event) sends its new icon in aiu", str(rows[-2:]))
    # Machines for the arrows: a chemical plant, a refinery, an assembler with a fluid recipe, a recycler.
    specs = [("chemical-plant", -20, 24, "sulfuric-acid"), ("oil-refinery", -12, 24, "advanced-oil-processing"),
             ("assembling-machine-2", -5, 24, "electric-engine-unit"), ("recycler", 0, 24, None),
             ("assembling-machine-2", 5, 24, "iron-gear-wheel")]
    lua = "local c = storage.f3d.puppet local s = c.surface local out = {} "
    for name, dx, dy, recipe in specs:
        lua += (f'local e = s.create_entity({{ name = "{name}", position = {{ {x0 + dx}, {y0 + dy} }}, force = c.force, raise_built = true }}) '
                + (f'if e then e.set_recipe("{recipe}") end ' if recipe else "")
                + 'out[#out + 1] = e and e.unit_number or 0 ')
    lua += 'rcon.print(table.concat(out, " "))'
    units = [int(v) for v in live_lib.mod_lua(lua).split()]
    msgs = c.pump(3.0, every=(1.0, hello_now))
    c.send({"t": "resync", "full": 0, "c": wanted})
    msgs += c.pump(8.0, every=(1.0, hello_now))
    fa = {}
    for m in msgs:
        if m.get("t") in ("ents", "add", "upd"):
            for e in (m["e"] if m["t"] == "ents" else [m["e"]]):
                if e[0] in units:
                    fa[e[0]] = (e[5] if len(e) > 5 else {}).get("fa", 0)
    want = [3, 3, 1, 0, 0]
    live_lib.report(len(units) == 5 and [fa.get(u, -1) for u in units] == want,
           "#9 part 2: machines' recipe fluids for the arrows (extra.fa: sulfuric acid 3, refinery 3, engines 1, recycler and gears 0)",
           str([fa.get(u, -1) for u in units]))
    vp = (c.eprops or {}).get(c.proto_id("recycler"), [None] * 4)
    vp = vp[3] if len(vp) > 3 and isinstance(vp[3], dict) else {}
    live_lib.report("vp" in vp and "fb" not in vp, "#9 part 2: the recycler's output side in eprops (vp)", str(vp))
    # A recipe set from the open screen comes in aiu at once (here: gears -> lubricant-free pipe).
    gu = units[4] if len(units) == 5 else 0
    live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {x0 + 5}, {y0 + 21} }}) rcon.print('ok')")
    c.pump(1.0, every=(1.0, hello_now))
    c.send({"t": "open", "u": gu, "p": c.proto_id("assembling-machine-2"), "x": int((x0 + 5) * 256), "y": int((y0 + 24) * 256)})
    c.pump(0.5, every=(1.0, hello_now))
    c.send({"t": "set_recipe", "u": gu, "recipe": "pipe"})
    msgs = c.pump(2.0, every=(1.0, hello_now))
    c.send({"t": "close"})
    rows = [r for m in msgs if m.get("t") == "aiu" for r in m["l"] if r[0] == gu]
    live_lib.report(rows and rows[-1][1:3] == ["recipe", "pipe"], "#9: a recipe set from the screen sends its icon in aiu", str(rows))
    check_alt_machines(c, hello_now, x0, y0)
    if not keep:
        live_lib.mod_lua(f'for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ area = {{ {{ {x0 - 30}, {y0 - 30} }}, '
                f'{{ {x0 + 30}, {y0 + 30} }} }}, name = {{ "steel-furnace", "chemical-plant", "oil-refinery", "assembling-machine-2", "recycler", '
                f'"assembling-machine-3", "lab", "beacon", "gun-turret", "rocket-turret", "locomotive", "straight-rail" }} }})) do e.destroy() end rcon.print("ok")')


def check_alt_machines(c, hello_now, x0, y0):
    """K1, K2: what 2.1 says of Alt-mode's icon placement (LuaEntityPrototype.icons_positioning and
    icon_draw_specification, as eprops ids and isq), and `am` while Alt-mode is on: an assembling machine 3's
    four modules in slot order with a quality kept, a lab's packs a slot each and its two modules, a
    beacon's modules."""
    facts = live_lib.mod_lua("""local out = {} for _, n in pairs({ 'assembling-machine-3', 'lab', 'beacon', 'electric-mining-drill' }) do
 local p = prototypes.entity[n] local ok, ip = pcall(function() return p.icons_positioning end)
 out[#out + 1] = n .. ' ids=' .. serpent.line(p.icon_draw_specification) .. ' ip=' .. (ok and serpent.line(ip) or 'error') end
 rcon.print(table.concat(out, ' | '))""".replace("\n", " "))
    print("  icons_positioning:", facts)
    ep = {name: (((c.eprops or {}).get(c.proto_id(name)) or [None] * 4)[3:] or [{}])[0] or {}
          for name in ("assembling-machine-3", "lab", "beacon")}
    live_lib.report(ep["assembling-machine-3"].get("ids") == [0, -0.3, 1]
           and ep["assembling-machine-3"].get("isq") == [["m", 0, 0.7, 0.5, 4, 2, 1.1, -0.1]],
           "K1: eprops: the assembling machine 3's icon 0.3 up, its modules' row from Factorio's defaults", str(ep["assembling-machine-3"]))
    lab_rows = {r[0]: r for r in ep["lab"].get("isq", [])}
    live_lib.report(lab_rows.get("l") == ["l", 0, 0, 0.5, 6, 2, 0.909, -0.1] and lab_rows.get("m", [None] * 3)[2] == 0.9,
           "K2: eprops: Space Age's lab, six packs a row and its modules under them", str(ep["lab"]))
    packs = ["automation-science-pack", "logistic-science-pack", "military-science-pack", "chemical-science-pack",
             "production-science-pack", "utility-science-pack", "space-science-pack"]
    pack_list = ", ".join(f'"{p}"' for p in packs)
    out = live_lib.mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local out = {{}}
local a = s.create_entity({{ name = "assembling-machine-3", position = {{ {x0} - 12, {y0} + 14 }}, force = c.force, raise_built = true }})
local m = a.get_module_inventory()
m.insert({{ name = "speed-module-3", count = 1 }}) m.insert({{ name = "speed-module-3", count = 1, quality = "rare" }})
m.insert({{ name = "productivity-module-3", count = 2 }})
local l = s.create_entity({{ name = "lab", position = {{ {x0} - 6, {y0} + 14 }}, force = c.force, raise_built = true }})
for _, p in pairs({{ {pack_list} }}) do l.insert({{ name = p, count = 1 }}) end
l.get_module_inventory().insert({{ name = "speed-module", count = 2 }})
local b = s.create_entity({{ name = "beacon", position = {{ {x0}, {y0} + 14 }}, force = c.force, raise_built = true }})
b.get_module_inventory().insert({{ name = "speed-module-2", count = 2 }})
rcon.print(a.unit_number .. " " .. l.unit_number .. " " .. b.unit_number)""".replace("\n", " "))
    units = [int(v) for v in out.split()] if all(v.isdigit() for v in out.split()) and len(out.split()) == 3 else []
    if not units:
        live_lib.report(False, "K1, K2: an assembler, a lab and a beacon with modules built", out)
        return
    c.send({"t": "altc", "on": 1, "g": 41})
    msgs = c.pump(4.0, every=(1.0, hello_now))
    c.send({"t": "altc", "on": 0})
    rows = {r[0]: r for m in msgs if m.get("t") == "am" and m.get("g") == 41 for r in m["l"]}
    a, l, b = units
    live_lib.report(rows.get(a) == [a, ["speed-module-3", ["speed-module-3", "rare"], "productivity-module-3", "productivity-module-3"]],
           "K1: `am`: the assembler's four modules in slot order, the rare one's quality kept", str(rows.get(a)))
    live_lib.report(rows.get(l) == [l, ["speed-module", "speed-module"], packs],
           "K2: `am`: the lab's seven packs a slot each and its two modules", str(rows.get(l)))
    live_lib.report(rows.get(b) == [b, ["speed-module-2", "speed-module-2"]], "K1: `am`: the beacon's modules", str(rows.get(b)))
    check_alt_stock(c, hello_now, x0, y0)


def check_alt_stock(c, hello_now, x0, y0):
    """K1's leftover: an ammo turret's ammo and a locomotive's fuel in Alt-mode. What 2.1 says of their
    icons_positioning (the gun turret's and the locomotive's are the only two in its data; Space Age's rocket
    turret has none), eprops' isq for them, and `am`: a gun turret's magazines, a rocket turret's rockets (when
    Space Age is on), a locomotive's fuel a slot each."""
    facts = live_lib.mod_lua("""local out = {} for _, n in pairs({ 'gun-turret', 'rocket-turret', 'railgun-turret', 'locomotive', 'car' }) do
 local p = prototypes.entity[n] if p then local ok, ip = pcall(function() return p.icons_positioning end)
 out[#out + 1] = n .. ' ip=' .. (ok and serpent.line(ip) or 'error') end end
 rcon.print(table.concat(out, ' | '))""".replace("\n", " "))
    print("  icons_positioning:", facts)
    names = ("gun-turret", "locomotive", "rocket-turret")
    ep = {name: (((c.eprops or {}).get(c.proto_id(name)) or [None] * 4)[3:] or [{}])[0] or {} for name in names if c.proto_id(name)}
    live_lib.report(ep.get("gun-turret", {}).get("isq") == [["a", 0, -0.25, 0.5, 2, 1, 1.1, -0.1]]
           and ep.get("locomotive", {}).get("isq") == [["f", 0, 0.3, 0.5, 3, 4, 1.1, -0.1]],
           "K1: eprops: the gun turret's ammo row and the locomotive's fuel row, as 2.1's icons_positioning",
           f"{ep.get('gun-turret')} {ep.get('locomotive')}")
    if "rocket-turret" in ep:
        live_lib.report(ep["rocket-turret"].get("isq") == [["a", 0, 0.7, 0.5, 4, 2, 1.1, -0.1]],
               "K1: eprops: the rocket turret (no icons_positioning) gets Factorio's defaults", str(ep["rocket-turret"]))
    # South and east of the smelting array (x0 - 24..x0 + 24, y0 - 28..y0 + 20) and the arrows' machines (y0 + 24),
    # inside the cleared square: a locomotive isn't made where its box meets a building.
    out = live_lib.mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface
local t = s.create_entity({{ name = "gun-turret", position = {{ {x0} - 12, {y0} + 28 }}, force = c.force, raise_built = true }})
t.insert({{ name = "firearm-magazine", count = 10 }})
local bare = s.create_entity({{ name = "gun-turret", position = {{ {x0} - 8, {y0} + 28 }}, force = c.force, raise_built = true }})
local r = prototypes.entity["rocket-turret"] and s.create_entity({{ name = "rocket-turret", position = {{ {x0} - 3.5, {y0} + 28.5 }}, force = c.force, raise_built = true }})
if r then r.insert({{ name = "rocket", count = 5 }}) end
local rx, ry = math.floor(({x0} + 27) / 2) * 2 + 1, math.floor(({y0} - 6) / 2) * 2 + 1
for i = 0, 4 do s.create_entity({{ name = "straight-rail", position = {{ rx, ry + 2 * i }}, direction = defines.direction.north, force = c.force, raise_built = true }}) end
local l = s.create_entity({{ name = "locomotive", position = {{ rx, ry + 4 }}, direction = defines.direction.north, force = c.force, raise_built = true }})
if l then l.insert({{ name = "coal", count = 5 }}) l.insert({{ name = "wood", count = 3 }}) end
rcon.print(t.unit_number .. " " .. bare.unit_number .. " " .. (r and r.unit_number or 0) .. " " .. (l and l.unit_number or 0))""".replace("\n", " "))
    units = [int(v) for v in out.split()] if all(v.isdigit() for v in out.split()) and len(out.split()) == 4 else []
    if not units or not units[3]:
        live_lib.report(False, "K1: gun turrets and a locomotive on rails built", out)
        return
    c.send({"t": "altc", "on": 1, "g": 42, "lf": 1})
    msgs = c.pump(5.0, every=(1.0, hello_now))
    c.send({"t": "altc", "on": 0})
    rows = {r[0]: r for m in msgs if m.get("t") == "am" and m.get("g") == 42 for r in m["l"]}
    t, bare, r, l = units
    live_lib.report(rows.get(t) == [t, 0, ["firearm-magazine"]] and bare not in rows,
           "K1: `am`: a gun turret's ammo, one icon a filled slot; none for an empty turret", f"{rows.get(t)} {rows.get(bare)}")
    if r:
        live_lib.report(rows.get(r) == [r, 0, ["rocket"]], "K1: `am`: a rocket turret's rockets", str(rows.get(r)))
    fuel = (rows.get(l) or [0, 0, []])[2] if len(rows.get(l) or []) == 3 else []
    live_lib.report(sorted(fuel) == ["coal", "wood"], "K1: `am`: a locomotive's fuel, a slot each", str(rows.get(l)))


def check_belt_switch(c, hello):
    """Belts run all the time; only one a network switches off stands still. A belt and a loader with a
    red wire and a false circuit condition report it (status 61; `disabled_by_control_behavior` is false
    on a belt, which isn't "updatable"), a belt with a logistic condition and no wire too, and the
    bridge sends `st` 5 for them, 0 once the condition holds; a plain belt never comes up, nor a
    splitter or an underground, which no network switches off."""
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "belts off: an empty spot", live_lib.SPOT_WHY)
        return
    x0, y0 = int(c.me["x"] / 256), int(c.me["y"] / 256)
    out = live_lib.mod_lua(f"""
local ch = storage.f3d.puppet local s = ch.surface
local function put(name, dx, dy, built) return s.create_entity({{ name = name, position = {{ {x0} + dx + 0.5, {y0} + dy + 0.5 }}, direction = defines.direction.east, force = ch.force, raise_built = built }}) end
local red = defines.wire_connector_id.circuit_red
local comb = put('constant-combinator', -6, 5, true)
local belt = put('transport-belt', -6, 4, true)
local loader = put('loader', -3, 4, true)
local plain = put('transport-belt', -6, 7, true)
local logistic = put('transport-belt', -5, 7, true)
local splitter = put('splitter', -6, 9, true)
local under = put('underground-belt', -3, 9, true)
local no_behavior = logistic.get_control_behavior() == nil
storage.f3d_live_belts = {{ belt = belt, loader = loader, plain = plain, logistic = logistic, splitter = splitter, under = under, comb = comb }}
rcon.print(belt.unit_number .. ' ' .. loader.unit_number .. ' ' .. plain.unit_number .. ' ' .. logistic.unit_number .. ' ' .. tostring(no_behavior))""".replace("\n", " "))
    parts = out.split()
    if len(parts) != 5:
        live_lib.report(False, "belts off: built", out)
        return
    belt, loader, plain, logistic = (int(v) for v in parts[:4])
    live_lib.report(parts[4] == "true", "belts off: a belt with no wire has no control behaviour until asked for", parts[4])
    # The combinator's wires looked at once first: a wire added after that is what gets noticed.
    c.pump(2.0, every=hello)
    out = live_lib.mod_lua(f"""
local b = storage.f3d_live_belts local belt, loader, logistic, comb = b.belt, b.loader, b.logistic, b.comb
local red = defines.wire_connector_id.circuit_red
local cond = {{ first_signal = {{ type = 'item', name = 'iron-plate' }}, comparator = '>', constant = 0 }}
for _, e in pairs({{ belt, loader }}) do
  e.get_wire_connector(red, true).connect_to(comb.get_wire_connector(red, true))
  local cb = e.get_or_create_control_behavior()
  cb.circuit_enable_disable = true
  cb.circuit_condition = cond
end
local lb = logistic.get_or_create_control_behavior()
lb.connect_to_logistic_network = true
lb.logistic_condition = cond
package.loaded['__factorio-3d-bridge__/scripts/belt_switch.lua'].configured(logistic)
rcon.print('ok')""".replace("\n", " "))
    msgs = c.pump(6.0, every=hello)
    rows = [m["l"] for m in live_lib.of_type(msgs, "st")]
    states = {r[i]: r[i + 1] for r in rows for i in range(0, len(r), 2)}
    facts = live_lib.mod_lua("""local b = storage.f3d_live_belts local function f(e) return e.name .. ' off=' .. tostring(e.disabled_by_control_behavior)
 .. ' status=' .. tostring(e.status) .. ' active=' .. tostring(e.active) .. ' updatable=' .. tostring(e.is_updatable) end
local cb = b.splitter.get_or_create_control_behavior()
local uok, ucb = pcall(function() return b.under.get_or_create_control_behavior() end)
rcon.print(f(b.belt) .. ' | ' .. f(b.loader) .. ' | ' .. f(b.logistic) .. ' | ' .. f(b.plain) .. ' | ' .. f(b.splitter) .. ' cb=' .. cb.object_name
 .. ' | ' .. f(b.under) .. ' cb=' .. tostring(uok and ucb and ucb.object_name) .. ' | disabled=' .. tostring(defines.entity_status.disabled_by_control_behavior))""".replace("\n", " "))
    print("  facts:", facts)
    rows_of = [f.strip() for f in facts.split("|")]
    live_lib.report("status=61" in rows_of[0], "belts off: a wired belt with a false condition is status 61", rows_of[0])
    live_lib.report("status=61" in rows_of[1], "belts off: a wired loader too", rows_of[1])
    live_lib.report("status=61" in rows_of[2], "belts off: and a belt with a logistic condition and no wire", rows_of[2])
    live_lib.report("status=1" in rows_of[3] and "status=1" in rows_of[4], "belts off: a plain belt and a splitter run", rows_of[3:5])
    live_lib.report(states.get(belt) == 5 and states.get(loader) == 5 and states.get(logistic) == 5, "belts off: the bridge sends st 5 for them", states)
    live_lib.report(plain not in states, "belts off: a plain belt is never mentioned", states)
    live_lib.mod_lua("""local cond = { first_signal = { type = 'item', name = 'iron-plate' }, comparator = '<', constant = 1 }
local b = storage.f3d_live_belts b.belt.get_control_behavior().circuit_condition = cond b.loader.get_control_behavior().circuit_condition = cond rcon.print('ok')""".replace("\n", " "))
    msgs = c.pump(3.0, every=hello)
    states = {r[i]: r[i + 1] for r in (m["l"] for m in live_lib.of_type(msgs, "st")) for i in range(0, len(r), 2)}
    live_lib.report(states.get(belt) == 0 and states.get(loader) == 0, "belts off: the condition true again: st 0", states)
    live_lib.mod_lua("for _, e in pairs(storage.f3d_live_belts) do e.destroy() end storage.f3d_live_belts = nil rcon.print('ok')")


def bp_string(record):
    """Factorio's exchange string, as the game and blueprint websites write it."""
    return "0" + base64.b64encode(zlib.compress(json.dumps(record).encode(), 9)).decode()


def bp_record(text):
    return json.loads(zlib.decompress(base64.b64decode(text[1:])))


def bp_reply(c, hello, q, seconds=8.0):
    """The `bp` parts answering request q, joined: (string, first part), or ("", None)."""
    parts, first, end = {}, None, time.time() + seconds
    while time.time() < end:
        for m in c.pump(0.3, every=hello):
            if m.get("t") == "bp" and m.get("q") == q:
                parts[m["part"]] = m["s"]
                first = first or m
                if len(parts) == m["parts"]:
                    return "".join(parts[k] for k in sorted(parts)), first
    return "", first


FLIP_SETUP = """
local c = storage.f3d.puppet local s = c.surface local f = c.force
local ox, oy = OX, OY
local made = {}
local function make(name, x, y, d, extra)
  local spec = { name = name, position = { ox + x, oy + y }, direction = d or 0, force = f }
  for k, v in pairs(extra or {}) do spec[k] = v end
  local e = s.create_entity(spec)
  if e then made[#made + 1] = name end
  return e
end
make("chemical-plant", 1.5, 1.5, 0)
local sp = make("splitter", 6, 1.5, 0)
if sp then sp.splitter_output_priority = "left" sp.splitter_input_priority = "right" end
make("underground-belt", 1.5, 5.5, 4, { type = "input" })
make("underground-belt", 4.5, 5.5, 4, { type = "output" })
make("inserter", 7.5, 5.5, 4)
make("curved-rail-a", 12, 4, 0)
make("half-diagonal-rail", 8, 10, 0)
make("straight-rail", 2, 10, 2)
local st = storage.f3d.lib_cursor[1]
st.set_stack({ name = "blueprint", count = 1 })
st.create_blueprint({ surface = s, force = f, area = { { ox, oy }, { ox + 16, oy + 13 } } })
rcon.print(table.concat(made, ",") .. " | " .. tostring(st.is_blueprint_setup()))
"""

FLIP_COMPARE = """
local c = storage.f3d.puppet local s = c.surface
local function area_of(x0, x1) return { { x0, OY - 4 }, { x1, OY + 14 } } end
for _, g in pairs(s.find_entities_filtered({ area = area_of(MX0, MX1), type = "entity-ghost" })) do g.revive() end
local function find(x0, x1)
  local out = {}
  for _, e in pairs(s.find_entities_filtered({ area = area_of(x0, x1), name = { "chemical-plant", "splitter", "underground-belt", "inserter", "curved-rail-a", "half-diagonal-rail", "straight-rail" } })) do
    out[#out + 1] = e
  end
  return out
end
local a, b = find(OX - 1, OX + 17), find(MX0, MX1)
local function anchor(list) for _, e in pairs(list) do if e.name == "chemical-plant" then return e end end end
local A, B = anchor(a), anchor(b)
if not (A and B) then rcon.print("anchor missing " .. #a .. " " .. #b) return end
local function rel(e, p, o) return { x = p.x - o.position.x, y = p.y - o.position.y } end
local function close(p, q) return math.abs(p.x - q.x) < 0.01 and math.abs(p.y - q.y) < 0.01 end
local function mirror(p) return { x = -p.x, y = p.y } end
local out = {}
local function note(k, ok) out[#out + 1] = k .. "=" .. tostring(ok) end
for _, e in pairs(a) do
  local want = mirror(rel(e, e.position, A))
  local match
  for _, m in pairs(b) do
    if m.name == e.name and close(rel(m, m.position, B), want) then match = m end
  end
  local key = e.name .. (e.type == "underground-belt" and ("-" .. e.belt_to_ground_type) or "")
  if not match then
    note(key .. ".position", false)
  else
    local rail = e.type == "curved-rail-a" or e.type == "half-diagonal-rail" or e.type == "straight-rail"
    if not rail then note(key .. ".direction", match.direction == (16 - e.direction) % 16) end
    if e.name == "chemical-plant" then
      note(key .. ".mirroring", match.mirroring ~= e.mirroring)
      local pa, pb = {}, {}
      for i = 1, 8 do
        local ok, list = pcall(function() return e.get_fluid_box_pipe_connections(i) end)
        if ok and list then for _, pc in pairs(list) do pa[#pa + 1] = mirror(rel(e, pc.target_position, A)) end end
        ok, list = pcall(function() return match.get_fluid_box_pipe_connections(i) end)
        if ok and list then for _, pc in pairs(list) do pb[#pb + 1] = rel(match, pc.target_position, B) end end
      end
      local same = #pa == #pb and #pa > 0
      for _, p in pairs(pa) do
        local hit = false
        for _, q in pairs(pb) do if close(p, q) then hit = true end end
        same = same and hit
      end
      note(key .. ".pipes", same)
    elseif e.name == "splitter" then
      note(key .. ".output", match.splitter_output_priority == "right")
      note(key .. ".input", match.splitter_input_priority == "left")
    elseif e.type == "underground-belt" then
      note(key .. ".type", match.belt_to_ground_type == e.belt_to_ground_type)
      note(key .. ".pair", match.underground_belt_neighbour ~= nil)
    elseif e.name == "inserter" then
      note(key .. ".pickup", close(rel(match, match.pickup_position, B), mirror(rel(e, e.pickup_position, A))))
      note(key .. ".drop", close(rel(match, match.drop_position, B), mirror(rel(e, e.drop_position, A))))
    elseif rail then
      local ea, eb = {}, {}
      for _, d in pairs({ defines.rail_direction.front, defines.rail_direction.back }) do
        ea[#ea + 1] = mirror(rel(e, e.get_rail_end(d).location.position, A))
        eb[#eb + 1] = rel(match, match.get_rail_end(d).location.position, B)
      end
      local same = true
      for _, p in pairs(ea) do
        local hit = false
        for _, q in pairs(eb) do if close(p, q) then hit = true end end
        same = same and hit
      end
      note(key .. ".ends", same)
    end
  end
end
for _, e in pairs(a) do e.destroy() end
for _, e in pairs(b) do e.destroy() end
rcon.print(table.concat(out, " "))
"""


def check_flips(c, hello):
    """A held blueprint flipped (H): the mod mirrors its entities (planners.lua mirrored) and the
    result is compared with the original in the real game, entity by entity: positions mirrored,
    directions reflected, the chemical plant's mirroring and its pipe connections, the splitter's
    priorities swapped, the underground pair still paired, the inserter's hand positions, and a
    curved, half-diagonal and diagonal straight rail's two ends."""
    if not live_lib.clean_spot(c, hello, half=18):
        live_lib.report(False, "flips: no clean spot found")
        return
    x, y = round(c.me["x"] / 256), round(c.me["y"] / 256)
    ox, oy = x - 18 + (x % 2), y - 6 + (y % 2)  # rails sit on the 2-tile grid
    out = live_lib.mod_lua(FLIP_SETUP.replace("OX", str(ox)).replace("OY", str(oy)).replace("\n", " "))
    live_lib.report(out.endswith("true") and "curved-rail-a" in out, "flips: the original layout built and made into a blueprint", out)
    px, py = ox + 26, oy + 6  # an even spot right of it
    c.send({"t": "blueprint", "i": -1, "x": px * 256, "y": py * 256, "d": 0, "bm": 1, "m": 1})
    msgs = c.pump(1.0, every=hello)
    texts = [m["text"] for m in live_lib.of_type(msgs, "msg")]
    out = live_lib.mod_lua(FLIP_COMPARE.replace("OX", str(ox)).replace("OY", str(oy)).replace("MX0", str(ox + 18))
                  .replace("MX1", str(ox + 36)).replace("\n", " "))
    live_lib.report(out and "false" not in out and "missing" not in out, "flips: the mirrored blueprint matches the original mirrored, entity by entity",
           out + (" | " + "; ".join(texts) if texts else ""))
    return out


def check_planner_modes(c, hello, x, y, fx, ghost):
    """Factorio's build modes for a held blueprint (`bm`: a click is normal, Shift forced), the upgrade
    planner's right-drag downgrade (`down`) and the planner window's delete button (`bp_del`)."""
    rock_at = (x - 11, y + 3)
    out = live_lib.mod_lua(f"local s = storage.f3d.puppet.surface local t = s.create_entity({{ name = 'big-rock', position = {{ {rock_at[0]}, {rock_at[1]} }} }}) "
                  "rcon.print(t and 'ok' or 'no')")
    furnace = c.proto_id("stone-furnace")
    one = {"blueprint": {"item": "blueprint", "label": "One furnace", "version": (2 << 48) | (28 << 16),
                         "entities": [{"entity_number": 1, "name": "stone-furnace", "position": {"x": 0, "y": 0}}]}}
    c.send({"t": "bp_set", "q": 520, "i": -1, "s": bp_string(one)})
    c.pump(0.5, every=hello)
    rock = lambda: live_lib.mod_lua(f"local t = storage.f3d.puppet.surface.find_entities_filtered({{ name = 'big-rock', position = {{ {rock_at[0]}, {rock_at[1]} }}, radius = 1.5 }})[1] "
                           "rcon.print(t and tostring(t.to_be_deconstructed()) or 'gone')")
    placed = {}
    for bm in (0, 1):
        c.send({"t": "blueprint", "i": -1, "x": fx(rock_at[0]), "y": fx(rock_at[1]), "d": 0, "bm": bm})
        msgs = c.pump(1.0, every=hello)
        placed[bm] = ([m["e"] for m in live_lib.of_type(msgs, "add") if m["e"][1] == ghost and m["e"][5].get("gh") == furnace], rock(),
                      live_lib.of_type(msgs, "hist"))
    live_lib.report(out == "ok" and not placed[0][0] and placed[0][1] == "false",
           "blueprint bm 0 (a click): nothing over a rock, the rock left alone (build_mode.normal)", f"{len(placed[0][0])} ghosts, rock marked: {placed[0][1]}")
    live_lib.report(placed[1][0] and placed[1][1] == "true", "blueprint bm 1 (Shift+click): the ghost over the rock, the rock marked (build_mode.forced)",
           f"{len(placed[1][0])} ghosts, rock marked: {placed[1][1]}")
    for _, _, hist in placed.values():
        for h in hist:
            c.send({"t": "undo", "h": h["h"]})
    c.pump(0.5, every=hello)
    live_lib.mod_lua(f"for _, t in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'big-rock', position = {{ {rock_at[0]}, {rock_at[1]} }}, radius = 1.5 }})) do t.destroy() end")
    # Downgrade: an iron chest with a wooden -> iron planner dragged the other way round.
    out = live_lib.mod_lua(f"local c = storage.f3d.puppet local e = c.surface.create_entity({{ name = 'iron-chest', position = {{ {x - 14.5}, {y + 2.5} }}, force = c.force }}) "
                  "rcon.print(e and e.unit_number or 0)")
    planner = {"upgrade_planner": {"item": "upgrade-planner", "version": (2 << 48) | (28 << 16), "settings": {"mappers": [
        {"index": 0, "from": {"type": "entity", "name": "wooden-chest"}, "to": {"type": "entity", "name": "iron-chest"}}]}}}
    c.send({"t": "bp_set", "q": 521, "i": -1, "s": bp_string(planner)})
    c.pump(0.5, every=hello)
    area = {"x1": fx(x - 16), "y1": fx(y + 1), "x2": fx(x - 13), "y2": fx(y + 4)}
    c.send({"t": "upgrade", "i": -1, "down": 1, "cancel": 0, **area})
    c.pump(0.8, every=hello)
    target = live_lib.mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'iron-chest' }})) do "
                     f"if e.unit_number == {out or 0} then local t = e.get_upgrade_target() rcon.print(t and t.name or 'none') return end end")
    live_lib.report(target == "wooden-chest", "upgrade down 1 (right-drag): marked by the reversed mappings (upgrade_area with a reversed copy)", f"target: {target}")
    c.send({"t": "upgrade", "i": -1, "cancel": 1, **area})
    c.pump(0.4, every=hello)
    live_lib.destroy_units([out])
    # bp_del: a book in the inventory destroyed.
    slot = live_lib.mod_lua("local c = storage.f3d.puppet c.insert({ name = 'blueprint-book', count = 1 }) local inv = c.get_main_inventory() "
                   "for i = 1, #inv do if inv[i].valid_for_read and inv[i].name == 'blueprint-book' then rcon.print(i) return end end")
    c.send({"t": "bp_del", "i": int(slot) if slot.isdigit() else 0})
    c.pump(0.4, every=hello)
    left = live_lib.mod_lua(f"rcon.print(tostring(storage.f3d.puppet.get_main_inventory()[{slot if slot.isdigit() else 1}].valid_for_read))")
    live_lib.report(slot.isdigit() and left == "false", "bp_del: the planner window's delete destroys the book (LuaItemStack.clear)", f"slot {slot}: {left}")
    # copy with to: the blueprint window's "Select new contents", into the same blueprint, its name kept.
    c.send({"t": "bp_set", "q": 530, "i": 0, "s": bp_string(one)})
    msgs = c.pump(1.0, every=hello, until=lambda m: m.get("t") == "bp_ok" and m.get("q") == 530)
    ok = [m for m in live_lib.of_type(msgs, "bp_ok") if m["q"] == 530]
    bp_slot = ok[0]["i"] if ok else 0
    chest = live_lib.mod_lua(f"local c = storage.f3d.puppet local e = c.surface.create_entity({{ name = 'wooden-chest', position = {{ {x - 18.5}, {y + 6.5} }}, force = c.force }}) "
                    "rcon.print(e and e.unit_number or 0)")
    c.send({"t": "copy", "x1": fx(x - 19), "y1": fx(y + 6), "x2": fx(x - 18), "y2": fx(y + 7), "cut": 0, "bp": 1, "to": bp_slot})
    msgs = c.pump(1.0, every=hello)
    again = [m for m in live_lib.of_type(msgs, "bp_ok") if m.get("new") == 1]
    out = live_lib.mod_lua(f"local s = storage.f3d.puppet.get_main_inventory()[{bp_slot or 1}] "
                  "rcon.print(tostring(s.valid_for_read and s.label) .. ' ' .. tostring(s.valid_for_read and s.is_blueprint_setup() and s.get_blueprint_entities()[1].name))")
    live_lib.report(bp_slot and again and again[-1]["i"] == bp_slot and out == "One furnace wooden-chest",
           "copy to: Select new contents puts the area into the same blueprint, its name kept (create_blueprint into the stack)", f"slot {bp_slot}: {out}")
    live_lib.mod_lua(f"storage.f3d.puppet.get_main_inventory()[{bp_slot or 1}].clear()")
    live_lib.destroy_units([chest])


def check_planners(c, hello):
    """Blueprints and planners (planners.lua, history.lua): qualities, exchange strings in and out of
    the inventory and the cursor's library stack, the game's and the player's libraries, placing a
    pasted string as ghosts, undo and redo of blueprints, marks, settings and rotations, and
    super-forced building over a tree."""
    live_lib.report(c.quals and c.quals[0][0] == "normal" and any(q[0] == "legendary" for q in c.quals),
           "quals: the qualities in order (prototypes.quality, force.is_quality_unlocked)", str(c.quals))
    c.send({"t": "bp_lib"})
    msgs = c.pump(2.0, every=hello)
    libs = {m["src"]: m for m in live_lib.of_type(msgs, "bpl")}
    live_lib.report("game" in libs, "bp_lib: the game's library (game.blueprints)",
           " | ".join(f"{k} ({v['who']}): {len(v['l'])} records" for k, v in libs.items()))
    if "player" in libs and libs["player"]["l"]:
        rec = libs["player"]["l"][0]
        c.send({"t": "bp_rec", "q": 501, "src": "player", "ix": rec[0]})
        data, first = bp_reply(c, hello, 501, 20.0)
        live_lib.report(data and "".join(bp_record(data).keys()) in ("blueprint", "blueprint_book", "deconstruction_planner", "upgrade_planner"),
               "bp_rec: a record of the taken-over player's own library (LuaPlayer.blueprints, export_record)",
               f"{rec[1]} '{rec[2]}', {len(data)} characters in {first['parts'] if first else 0} parts")
        big = max(libs["player"]["l"], key=lambda r: 1 if r[1] == "blueprint-book" else 0)
        c.send({"t": "bp_rec", "q": 502, "src": "player", "ix": big[0], "to": -1})
        msgs = c.pump(3.0, every=hello, until=lambda m: m.get("t") == "bp_ok" and m.get("q") == 502)
        ok = [m for m in live_lib.of_type(msgs, "bp_ok") if m["q"] == 502]
        live_lib.report(ok and ok[0]["i"] == -1 and ok[0]["item"] == big[1], "bp_rec to -1: a player's record straight into the cursor's stack",
               f"'{big[2]}' ({big[1]})")
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "planners: no clean spot found")
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    fx = lambda v: int(round(v * 256))
    ghost = c.proto_id("entity-ghost")
    # A taken-over player's personal roboports would build and remove things before they're looked at.
    robots = live_lib.mod_lua("local c = storage.f3d.puppet local ok, v = pcall(function() return c.allow_dispatching_robots end) "
                     "if ok then c.allow_dispatching_robots = false end rcon.print(tostring(v))")
    # A string made the way websites and the game make them (2.0 format), pasted into the library.
    belt = {"blueprint": {"item": "blueprint", "label": "Live check line", "version": (2 << 48) | (28 << 16),
                          "icons": [{"signal": {"name": "transport-belt"}, "index": 1}],
                          "description": "Made by live_check.py",
                          "entities": [{"entity_number": n + 1, "name": "transport-belt", "position": {"x": n + 0.5, "y": 0.5},
                                        "direction": 4} for n in range(4)]
                          + [{"entity_number": 5, "name": "iron-chest", "position": {"x": 4.5, "y": 0.5}}]}}
    c.send({"t": "bp_set", "q": 510, "i": -1, "s": bp_string(belt)})
    msgs = c.pump(1.0, every=hello)
    ok = [m for m in live_lib.of_type(msgs, "bp_ok") if m["q"] == 510]
    live_lib.report(ok and ok[0]["i"] == -1 and ok[0]["item"] == "blueprint", "bp_set -1: a pasted blueprint string into the cursor's stack (import_stack)",
           str(ok))
    c.send({"t": "blueprint", "i": -1, "x": fx(x + 2), "y": fx(y + 6), "d": 0})
    msgs = c.pump(1.5, every=hello)
    ghosts = [m["e"] for m in live_lib.of_type(msgs, "add") if m["e"][1] == ghost]
    hist = live_lib.of_type(msgs, "hist")
    live_lib.report(len(ghosts) == 5 and hist and hist[-1]["what"] == "blueprint",
           "blueprint -1: the pasted string's five ghosts, remembered for undo (hist)", f"{len(ghosts)} ghosts, {hist}")
    if hist:
        c.send({"t": "undo", "h": hist[-1]["h"]})
        msgs = c.pump(1.0, every=hello)
        gone = {(m["x"], m["y"]) for m in live_lib.of_type(msgs, "del")}
        live_lib.report(gone >= {(g[2], g[3]) for g in ghosts} and bool(ghosts), "undo: the blueprint's ghosts go (destroy{raise_destroy})",
               f"{len(gone)} removed")
        c.send({"t": "redo", "h": hist[-1]["h"]})
        msgs = c.pump(1.0, every=hello)
        again = [m["e"] for m in live_lib.of_type(msgs, "add") if m["e"][1] == ghost]
        live_lib.report(len(again) == 5, "redo: built again from the remembered string", f"{len(again)} ghosts")
        c.send({"t": "undo", "h": hist[-1]["h"]})
        c.pump(0.5, every=hello)
    # Into the inventory and back out: the string the game exports decodes to what went in.
    c.send({"t": "bp_set", "q": 511, "i": 0, "s": bp_string(belt)})
    msgs = c.pump(1.0, every=hello)
    ok = [m for m in live_lib.of_type(msgs, "bp_ok") if m["q"] == 511]
    slot = ok[0]["i"] if ok else 0
    c.send({"t": "bp_get", "q": 512, "i": slot})
    data, _ = bp_reply(c, hello, 512)
    back = bp_record(data).get("blueprint", {}) if data else {}
    live_lib.report(slot > 0 and back.get("label") == "Live check line" and len(back.get("entities", [])) == 5
           and back.get("description") == "Made by live_check.py",
           "bp_set 0 then bp_get: a new blueprint in the inventory, exported again (export_stack)", f"slot {slot}: {back.get('label')}")
    edited = {"blueprint": dict(back, label="Edited in 3D", **{"snap-to-grid": {"x": 6, "y": 2}, "absolute-snapping": True})}
    c.send({"t": "bp_set", "q": 513, "i": slot, "s": bp_string(edited)})
    c.pump(0.5, every=hello)
    out = live_lib.mod_lua(f"local s = storage.f3d.puppet.get_main_inventory()[{slot}] "
                  "rcon.print(tostring(s.label) .. ' ' .. serpent.line(s.blueprint_snap_to_grid) .. ' ' .. tostring(s.blueprint_absolute_snapping))")
    live_lib.report(out.startswith("Edited in 3D") and "x = 6" in out and out.endswith("true"),
           "bp_set over the slot: label, snap to grid and absolute snapping written back", out)
    live_lib.mod_lua(f"storage.f3d.puppet.get_main_inventory()[{slot}].clear()")
    # A deconstruction planner made from a string, used, undone and redone.
    out = live_lib.mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local out = {{}}
for _, p in pairs({{ {{ {x - 4.5}, {y - 4.5} }}, {{ {x - 3.5}, {y - 4.5} }} }}) do
  local e = s.create_entity({{ name = "wooden-chest", position = p, force = c.force }}) out[#out + 1] = e.unit_number
end
local a = s.create_entity({{ name = "assembling-machine-1", position = {{ {x + 4.5}, {y - 4.5} }}, force = c.force }})
local b = s.create_entity({{ name = "assembling-machine-1", position = {{ {x + 8.5}, {y - 4.5} }}, force = c.force }})
local ins = s.create_entity({{ name = "inserter", position = {{ {x + 0.5}, {y - 4.5} }}, force = c.force }})
a.set_recipe("iron-gear-wheel")
rcon.print(out[1] .. " " .. out[2] .. " " .. a.unit_number .. " " .. b.unit_number .. " " .. ins.unit_number)
""".replace("\n", " "))
    try:
        chest_a, chest_b, asm_a, asm_b, ins = (int(v) for v in out.split())
    except ValueError:
        live_lib.report(False, "planners: building the test entities", out)
        return
    marked = lambda u: live_lib.mod_lua(
        f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = {{ 'wooden-chest', 'inserter' }} }})) do "
        f"if e.unit_number == {u} then rcon.print(tostring(e.to_be_deconstructed())) return end end")
    live_lib.mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'wooden-chest' }})) do "
            f"if e.unit_number == {chest_b} then e.order_deconstruction(e.force) end end")
    planner = {"deconstruction_planner": {"item": "deconstruction-planner", "label": "Chests only", "version": (2 << 48) | (28 << 16),
                                          "settings": {"entity_filters": [{"name": "wooden-chest", "index": 0}]}}}
    c.send({"t": "bp_set", "q": 514, "i": -1, "s": bp_string(planner)})
    c.pump(0.5, every=hello)
    area = {"x1": fx(x - 6), "y1": fx(y - 6), "x2": fx(x + 1.5), "y2": fx(y - 3)}
    c.send({"t": "decon", "i": -1, **area})
    msgs = c.pump(1.0, every=hello)
    hist = live_lib.of_type(msgs, "hist")
    ins_marked = marked(ins)
    live_lib.report(marked(chest_a) == "true" and ins_marked == "false" and hist and hist[-1]["what"] == "deconstruction",
           "a deconstruction planner from a string with a chest filter marks the chest, not the inserter", f"inserter {ins_marked}, {hist}")
    if hist:
        c.send({"t": "undo", "h": hist[-1]["h"]})
        c.pump(0.5, every=hello)
        live_lib.report(marked(chest_a) == "false" and marked(chest_b) == "true", "undo: its own mark goes, the older one stays")
        c.send({"t": "redo", "h": hist[-1]["h"]})
        c.pump(0.5, every=hello)
        live_lib.report(marked(chest_a) == "true", "redo: marked again (order_deconstruction)")
    # Owner's #20: Alt+D's shortcut and Ctrl+X's cut over ghosts. Factorio deletes them with no event.
    out = live_lib.mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface local out = {{}}
for _, p in pairs({{ {{ {x - 4.5}, {y + 8.5} }}, {{ {x + 4.5}, {y + 8.5} }} }}) do
  local g = s.create_entity({{ name = "entity-ghost", inner_name = "wooden-chest", position = p, force = c.force }}) out[#out + 1] = g.unit_number
end
rcon.print(out[1] .. " " .. out[2])
""".replace("\n", " "))
    try:
        ghost_a, ghost_b = (int(v) for v in out.split())
    except ValueError:
        live_lib.report(False, "planners: making two ghosts", out)
        ghost_a = ghost_b = None
    if ghost_a:
        c.send({"t": "decon", "i": 0, "x1": fx(x - 5.5), "y1": fx(y + 7.5), "x2": fx(x - 3.5), "y2": fx(y + 9.5)})
        dels = {d["u"] for d in live_lib.of_type(c.pump(1.0, every=hello), "del")}
        live_lib.report(ghost_a in dels, "the deconstruction shortcut (Alt+D) deletes a ghost and sends its del", f"{dels}")
        c.send({"t": "copy", "cut": 1, "bp": 0, "x1": fx(x + 3.5), "y1": fx(y + 7.5), "x2": fx(x + 5.5), "y2": fx(y + 9.5)})
        dels = {d["u"] for d in live_lib.of_type(c.pump(1.0, every=hello), "del")}
        live_lib.report(ghost_b in dels, "cut (Ctrl+X) over a ghost deletes it and sends its del", f"{dels}")
    # Owner's #13: a book's icons (LuaItemStack.preview_icons) reach the inventory's slots as `ic`.
    out = live_lib.mod_lua("""
local inv = storage.f3d.puppet.get_main_inventory() local st, i = inv.find_empty_stack()
st.set_stack({ name = "blueprint-book", count = 1 })
st.preview_icons = { { signal = { name = "iron-plate" }, index = 1 }, { signal = { type = "virtual", name = "signal-A" }, index = 2 } }
rcon.print(i)
""".replace("\n", " "))
    book_at = int(out) if out.isdigit() else 0
    ic = [m.get("ic") for m in live_lib.of_type(c.pump(1.5, every=hello), "slots")]
    live_lib.report(book_at and ic and [book_at, [["item", "iron-plate"], ["virtual", "signal-A"]]] in (ic[-1] or []),
           "a book's icons go with the inventory's slots (preview_icons -> ic)", f"slot {out}: {ic[-1:]}")
    if book_at:
        live_lib.mod_lua(f"storage.f3d.puppet.get_main_inventory()[{book_at}].clear()")
    # Owner's #22: right-click on the map removes the ghost under the point (unghost).
    out = live_lib.mod_lua(f"""
local c = storage.f3d.puppet
local g = c.surface.create_entity({{ name = "entity-ghost", inner_name = "assembling-machine-1", position = {{ {x + 6.5}, {y + 14.5} }}, force = c.force }})
rcon.print(g.unit_number)
""".replace("\n", " "))
    gu = int(out) if out.isdigit() else 0
    c.send({"t": "unghost", "q": 41, "x": fx(x + 7.4), "y": fx(y + 15.2)})
    msgs = c.pump(1.0, every=hello)
    answers = [(m["q"], m["n"]) for m in live_lib.of_type(msgs, "unghost")]
    live_lib.report(gu and answers == [(41, 1)] and gu in {d["u"] for d in live_lib.of_type(msgs, "del")},
           "unghost removes the 3x3 ghost under a point near its corner and sends its del", f"{out}: {answers}")
    c.send({"t": "unghost", "q": 42, "x": fx(x + 30.5), "y": fx(y + 30.5)})
    answers = [(m["q"], m["n"]) for m in live_lib.of_type(c.pump(1.0, every=hello), "unghost")]
    live_lib.report(answers == [(42, 0)], "unghost where there is no ghost answers n = 0", f"{answers}")
    # Owner's C10: the map's copper wires between poles (chart ov "w").
    out = live_lib.mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface
local a = s.create_entity({{ name = "small-electric-pole", position = {{ {x - 14.5}, {y + 18.5} }}, force = c.force }})
local b = s.create_entity({{ name = "small-electric-pole", position = {{ {x - 9.5}, {y + 18.5} }}, force = c.force }})
a.get_wire_connector(defines.wire_connector_id.pole_copper, true).connect_to(b.get_wire_connector(defines.wire_connector_id.pole_copper, true))
rcon.print(a.unit_number .. " " .. b.unit_number)
""".replace("\n", " "))
    poles = [int(v) for v in out.split()] if all(v.isdigit() for v in out.split()) and out else []
    ax, ay = x - 14.5, y + 18.5
    cx, cy = int(ax // 32), int(ay // 32)
    c.send({"t": "map", "cx1": cx - 1, "cy1": cy - 1, "cx2": cx + 1, "cy2": cy + 1, "res": 4})
    charts = live_lib.of_type(c.pump(2.0, every=hello), "chart")
    wires = [r for m in charts for r in m.get("ov", []) if r[0] == "w"]
    near = lambda r: abs(r[1] - fx(ax)) <= 256 and abs(r[2] - fx(ay)) <= 256 and abs(r[3] - fx(x - 9.5)) <= 256 and abs(r[4] - fx(ay)) <= 256
    live_lib.report(poles and any(near(r) for r in wires), "the map's charts carry the copper wire between two poles (ov w, poles snapped to tiles)",
           f"{out}: {wires[:4]}")
    if poles:
        live_lib.destroy_units(poles)
    # Owner's C12: a chart carries its chunk's pollution (pol).
    px_, py_ = x + 40, y + 40
    live_lib.mod_lua(f"local c = storage.f3d.puppet c.surface.pollute({{ {px_}, {py_} }}, 777)")
    pcx, pcy = int(px_ // 32), int(py_ // 32)
    c.send({"t": "map", "cx1": pcx, "cy1": pcy, "cx2": pcx, "cy2": pcy, "res": 32})
    pols = [m.get("pol") for m in live_lib.of_type(c.pump(1.5, every=hello), "chart") if (m["cx"], m["cy"]) == (pcx, pcy)]
    live_lib.report(pols and pols[-1] is not None and pols[-1] >= 700, "a chart carries its chunk's pollution (LuaSurface.get_pollution)", f"{pols}")
    # Owner's #23: a filter inserter's Alt-mode icon carries every filter.
    out = live_lib.mod_lua(f"""
local c = storage.f3d.puppet
local e = c.surface.create_entity({{ name = "fast-inserter", position = {{ {x + 0.5}, {y + 11.5} }}, force = c.force }})
e.use_filters = true e.set_filter(2, "iron-plate") e.set_filter(4, "copper-plate") e.set_filter(5, "coal")
rcon.print(e.unit_number)
""".replace("\n", " "))
    fins = int(out) if out.isdigit() else 0
    c.send({"t": "alt", "on": 1})
    ai = live_lib.of_type(c.pump(2.5, every=hello), "ai")
    c.send({"t": "alt", "on": 0})
    rows = [r for r in (ai[-1]["l"] if ai else []) if r[0] == fins]
    live_lib.report(fins and rows == [[fins, "item", "iron-plate", ["copper-plate", "coal"]]],
           "a filter inserter's Alt-mode icon carries all its filters (get_filter 1..filter_slot_count)", f"{out}: {rows}")
    if fins:
        live_lib.destroy_units([fins])
    # Settings pasted, undone through a one-entity blueprint built over it.
    asm = c.proto_id("assembling-machine-1")
    ident = lambda u, px, py, name: {"u": u, "p": c.proto_id(name), "x": fx(px), "y": fx(py)}
    c.send({"t": "paste_settings", "f": [asm_a, asm, fx(x + 4.5), fx(y - 4.5)], **ident(asm_b, x + 8.5, y - 4.5, "assembling-machine-1")})
    msgs = c.pump(1.0, every=hello)
    hist = [h for h in live_lib.of_type(msgs, "hist") if h["what"] == "settings"]
    recipe = lambda u: live_lib.mod_lua(
        f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'assembling-machine-1' }})) do "
        f"if e.unit_number == {u} then local r = e.get_recipe() rcon.print(r and r.name or 'none') return end end")
    live_lib.report(recipe(asm_b) == "iron-gear-wheel" and hist, "paste_settings is remembered with a snapshot before and after", str(hist))
    if hist:
        c.send({"t": "undo", "h": hist[-1]["h"]})
        c.pump(0.8, every=hello)
        r_undo = recipe(asm_b)
        c.send({"t": "redo", "h": hist[-1]["h"]})
        c.pump(0.8, every=hello)
        r_redo = recipe(asm_b)
        live_lib.report(r_undo == "none" and r_redo == "iron-gear-wheel", "undo / redo of pasted settings (a blueprint built over the entity)",
               f"after undo: {r_undo}, after redo: {r_redo}")
    # A rotation undone.
    d0 = live_lib.mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'inserter' }})) do "
                 f"if e.unit_number == {ins} then rcon.print(e.direction) return end end")
    c.send({"t": "rotate", **ident(ins, x + 0.5, y - 4.5, "inserter"), "rev": 0})
    msgs = c.pump(0.8, every=hello)
    hist = [h for h in live_lib.of_type(msgs, "hist") if h["what"] == "rotation"]
    if hist:
        c.send({"t": "undo", "h": hist[-1]["h"]})
        c.pump(0.5, every=hello)
    d1 = live_lib.mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'inserter' }})) do "
                 f"if e.unit_number == {ins} then rcon.print(e.direction) return end end")
    live_lib.report(hist and d0 == d1, "a rotation is remembered and undone", f"{d0} -> {d1}")
    # Super-forced build over a tree: the ghost goes there, the tree is marked for deconstruction.
    # A rock does on any planet (Vulcanus has no trees).
    out = live_lib.mod_lua(f"local s = storage.f3d.puppet.surface local t = s.create_entity({{ name = 'big-rock', position = {{ {x - 6.5}, {y + 2.5} }} }}) "
                  "rcon.print(t and 'ok' or 'no')")
    c.send({"t": "build", "item": "stone-furnace", "x": fx(x - 6.5), "y": fx(y + 2.5), "d": 0, "ghost": 1, "sf": 1})
    msgs = c.pump(1.0, every=hello)
    furnace = c.proto_id("stone-furnace")
    sf = [m["e"] for m in live_lib.of_type(msgs, "add") if m["e"][1] == ghost and m["e"][5].get("gh") == furnace]
    tree = live_lib.mod_lua(f"local s = storage.f3d.puppet.surface local t = s.find_entities_filtered({{ name = 'big-rock', position = {{ {x - 6.5}, {y + 2.5} }}, radius = 1.5 }})[1] "
                   "rcon.print(t and tostring(t.to_be_deconstructed()) or 'gone')")
    live_lib.report(out == "ok" and sf and tree == "true", "super-forced build: a ghost over a rock, the rock marked for deconstruction",
           f"rock made: {out}, ghost at {[(g[2] / 256, g[3] / 256) for g in sf]} for ({x - 6.5}, {y + 2.5}), tree marked: {tree}")
    live_lib.destroy_units([chest_a, chest_b, asm_a, asm_b, ins] + [g[0] for g in sf])
    check_planner_modes(c, hello, x, y, fx, ghost)
    check_flips(c, hello)
    if robots == "true":
        live_lib.mod_lua("storage.f3d.puppet.allow_dispatching_robots = true")


def game_tiles(x0, y0, x1, y1):
    """{(x, y): tile name} for a rectangle of tiles, from the game."""
    out = live_lib.mod_lua(f"local s = storage.f3d.puppet.surface local o = {{}} for y = {y0}, {y1} do for x = {x0}, {x1} do "
                  "o[#o + 1] = x .. ',' .. y .. ',' .. s.get_tile(x, y).name end end rcon.print(table.concat(o, ' '))")
    return {(int(a), int(b)): n for a, b, n in (v.split(",") for v in out.split())}


def rail_path(start, d, steps):
    """Pieces from a rail end by the client's table (client/data/rail_extensions.json): `steps`
    picks which extension at each end (its index in the table's list)."""
    table = json.loads((live_lib.REPO / "client" / "data" / "rail_extensions.json").read_text())
    pieces, pos = [], start
    for k in steps:
        e = table["ext"][str(d)][k]
        pieces.append([e[0], pos[0] + e[2], pos[1] + e[3], e[1]])
        pos, d = (pos[0] + e[5], pos[1] + e[6]), e[4]
    return pieces, pos, d


def check_build_tools(c, hello):
    """Tiles (tiles.lua), capsules (capsules.lua), the rail planner (rail_planner.lua) and what drag
    building sends (undergrounds and pipes-to-ground over obstacles, poles at wire reach)."""
    iuse = c.iuse
    tid = c.tiles
    con, land, gren, cliff = (iuse.get(k) for k in (("concrete", "t"), ("landfill", "t"), ("grenade", "c"), ("cliff-explosives", "c")))
    live_lib.report(con and tid["grass-1"] in con[4] and tid["water"] not in con[4] and land and tid["water"] in land[4]
           and tid["grass-1"] not in land[4] and iuse.get(("hazard-concrete", "t"), [0, 0, 0, ""])[3] == "hazard-concrete-right"
           and gren and gren[2] == "throw" and gren[3] == 15 and cliff and cliff[2:5] == ["destroy-cliffs", 10, 1.5]
           and len(cliff) == 6 and cliff[5] > 0 and len(gren) == 6 and gren[5] > 0
           and iuse.get(("rail", "r"), [0, 0, ""])[2] == "rail-support" and ("rail-ramp", "r") not in iuse
           and iuse.get(("transport-belt", "b"), [0, 0, ""])[2] == "underground-belt"
           and iuse.get(("pipe", "p"), [0, 0, ""])[2] == "pipe-to-ground",
           "iuse: place_as_tile_result (condition, tile_condition), hazard concrete's next_direction, capsule_action, "
           "the rail planner's support, related_underground_belt, capsules' cooldown ticks", f"{con and con[:4]} {land and land[:4]} {gren} {cliff}")

    if not live_lib.clean_spot(c, hello, half=16):
        live_lib.report(False, "build tools: no clean spot found", live_lib.SPOT_WHY)
        return
    fx = lambda v: int(round(v * 256))
    x, y = c.me["x"] / 256, c.me["y"] / 256
    bx, by = math.floor(x), math.floor(y)
    live_lib.mod_lua('local c = storage.f3d.puppet for _, s in pairs({ { "concrete", 20 }, { "stone-brick", 5 }, { "landfill", 5 }, '
            '{ "hazard-concrete", 5 }, { "grenade", 3 }, { "cliff-explosives", 2 }, { "raw-fish", 2 }, { "land-mine", 2 }, '
            '{ "rail", 60 }, { "rail-ramp", 1 }, { "rail-support", 6 }, { "transport-belt", 20 }, { "underground-belt", 4 }, '
            '{ "pipe", 20 }, { "pipe-to-ground", 4 }, { "small-electric-pole", 6 }, { "wooden-chest", 4 } }) do '
            'c.get_main_inventory().remove({ name = s[1], count = 100000 }) c.insert({ name = s[1], count = s[2] }) end')
    c.pump(1.0, every=hello)
    # --- what drag building sends ---------------------------------------------------------------
    # Belts east with a chest in the way: the client sends belts, then an underground over the last
    # belt before the chest and one past it; the mod makes them entrance and exit.
    dy_ = by + 2
    live_lib.mod_lua(f"storage.f3d.puppet.surface.create_entity({{ name = 'wooden-chest', position = {{ {bx + 3.5}, {dy_ + 0.5} }}, force = 'player' }})")
    for k in range(0, 3):
        c.send({"t": "build", "item": "transport-belt", "x": fx(bx + k + 0.5), "y": fx(dy_ + 0.5), "d": 4})
    c.send({"t": "build", "item": "underground-belt", "x": fx(bx + 2.5), "y": fx(dy_ + 0.5), "d": 4})
    c.send({"t": "build", "item": "underground-belt", "x": fx(bx + 5.5), "y": fx(dy_ + 0.5), "d": 4})
    c.pump(1.5, every=hello)
    out = live_lib.mod_lua(f"local o = {{}} for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ type = {{ 'transport-belt', 'underground-belt' }}, "
                  f"area = {{ {{ {bx}, {dy_} }}, {{ {bx + 7}, {dy_ + 1} }} }} }})) do o[#o + 1] = e.position.x - {bx} .. e.type:sub(1, 1) .. "
                  "(e.type == 'underground-belt' and e.belt_to_ground_type:sub(1, 1) or '') end table.sort(o) rcon.print(table.concat(o, ' '))")
    live_lib.report(out == "0.5t 1.5t 2.5ui 5.5uo", "smart belt drag: the last belt becomes the underground entrance (fast-replace) "
           "and the one past the chest its exit", out)
    # Pipes east over a chest: pipe-to-ground facing back at the entrance, forward at the exit.
    py_ = by + 4
    live_lib.mod_lua(f"storage.f3d.puppet.surface.create_entity({{ name = 'wooden-chest', position = {{ {bx + 2.5}, {py_ + 0.5} }}, force = 'player' }})")
    c.send({"t": "build", "item": "pipe", "x": fx(bx + 0.5), "y": fx(py_ + 0.5), "d": 0})
    c.send({"t": "build", "item": "pipe-to-ground", "x": fx(bx + 1.5), "y": fx(py_ + 0.5), "d": 12})
    c.send({"t": "build", "item": "pipe-to-ground", "x": fx(bx + 4.5), "y": fx(py_ + 0.5), "d": 4})
    c.send({"t": "build", "item": "pipe", "x": fx(bx + 5.5), "y": fx(py_ + 0.5), "d": 0})
    c.pump(1.5, every=hello)
    out = live_lib.mod_lua(f"local s = storage.f3d.puppet.surface local a = s.find_entities_filtered({{ name = 'pipe', position = {{ {bx + 0.5}, {py_ + 0.5} }} }})[1] "
                  f"local b = s.find_entities_filtered({{ name = 'pipe', position = {{ {bx + 5.5}, {py_ + 0.5} }} }})[1] "
                  "rcon.print(a and b and tostring(a.get_fluid_segment_id(1) == b.get_fluid_segment_id(1)) or 'missing')")
    live_lib.report(out == "true", "pipe drag: pipe-to-ground pair facing back (entrance) and forward (exit) joins the pipes either side "
           "into one fluid segment", out)
    # Poles along a line at the small pole's wire reach (7.5): 7 tiles apart, wired.
    ly = by - 9
    for k in (0, 7, 14):
        c.send({"t": "build", "item": "small-electric-pole", "x": fx(bx - 7 + k + 0.5), "y": fx(ly + 0.5), "d": 0})
    c.pump(1.5, every=hello)
    out = live_lib.mod_lua(f"local o = {{}} for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'small-electric-pole', "
                  f"area = {{ {{ {bx - 8}, {ly} }}, {{ {bx + 9}, {ly + 1} }} }} }})) do local n = 0 "
                  "for _, con in pairs(e.get_wire_connector(defines.wire_connector_id.pole_copper, true).connections) do n = n + 1 end "
                  "o[#o + 1] = n end table.sort(o) rcon.print(table.concat(o, ' '))")
    live_lib.report(out == "1 1 2", "pole drag: poles 7 tiles apart (the client's spacing at a 7.5 wire reach) connect in a line", out)
    for area in ((bx - 8, ly, bx + 9, ly + 1), (bx, dy_, bx + 7, py_ + 1)):
        live_lib.mod_lua(f"local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({{ area = {{ {{ {area[0]}, {area[1]} }}, "
                f"{{ {area[2]}, {area[3]} }} }}, force = c.force }})) do if e ~= c then e.destroy() end end")

    before = game_tiles(bx + 1, by - 6, bx + 5, by - 2)

    # --- tiles ---------------------------------------------------------------------------------
    live_lib.mod_lua(f"storage.f3d.puppet.surface.set_tiles({{ {{ name = 'stone-path', position = {{ {bx + 2}, {by - 5} }} }} }})")
    c.send({"t": "tile", "item": "concrete", "x": fx(bx + 2.5), "y": fx(by - 3.5), "n": 3})
    msgs = c.pump(1.5, every=hello)
    flat = [v for m in live_lib.of_type(msgs, "tiles") for v in m["l"]]
    sent = {(flat[i], flat[i + 1]): flat[i + 2] for i in range(0, len(flat), 3)}
    now = game_tiles(bx + 1, by - 6, bx + 5, by - 2)
    want = {(bx + dx, by + dy) for dx in (1, 2, 3) for dy in (-5, -4, -3)}
    live_lib.report(all(now[p] == "concrete" for p in want) and all(sent.get(p) == tid["concrete"] for p in want)
           and live_lib.inv_count("concrete") == 11 and live_lib.inv_count("stone-brick") == 6,
           "tile: a 3x3 brush of concrete (surface.set_tiles raising script_raised_set_tiles: `tiles` sent), 9 used, "
           "the stone path under it handed back", f"{sorted(set(now.values()))} sent {len(sent)} inv {live_lib.inv_count('concrete')} {live_lib.inv_count('stone-brick')}")
    c.send({"t": "tile", "item": "hazard-concrete", "x": fx(bx + 4.5), "y": fx(by - 2.5), "n": 1, "r": 1})
    c.pump(1.0, every=hello)
    live_lib.report(game_tiles(bx + 4, by - 3, bx + 4, by - 3).get((bx + 4, by - 3)) == "hazard-concrete-right",
           "tile r: 1 lays hazard concrete's other direction (next_direction)")
    c.send({"t": "tile_mine", "x": fx(bx + 2.5), "y": fx(by - 3.5), "n": 3})
    c.send({"t": "tile_mine", "x": fx(bx + 4.5), "y": fx(by - 2.5), "n": 1})
    msgs = c.pump(1.5, every=hello)
    flat = [v for m in live_lib.of_type(msgs, "tiles") for v in m["l"]]
    now = game_tiles(bx + 1, by - 6, bx + 5, by - 2)
    back = {p: now[p] for p in want}
    # Concrete over the stone path doesn't keep the path under it (set_tiles: a mineable tile over a
    # mineable one leaves the hidden tile alone), which is why the brick came back above.
    live_lib.report(all(now[p] == before[p] for p in want) and live_lib.inv_count("concrete") == 20 and live_lib.inv_count("hazard-concrete") == 5
           and len(flat) >= 30, "tile_mine: LuaControl.mine_tile takes the concrete back and the ground it was laid on returns",
           f"{back} inv {live_lib.inv_count('concrete')} sent {len(flat) // 3}")

    # Tile ghosts, and landfill on water made for the test.
    c.send({"t": "tile", "item": "concrete", "x": fx(bx - 3.5), "y": fx(by - 4.5), "n": 2, "ghost": 1})
    msgs = c.pump(1.5, every=hello)
    ghosts = [m["e"] for m in live_lib.of_type(msgs, "add") if m["e"][1] == c.proto_id("tile-ghost")]
    live_lib.report(len(ghosts) == 4 and all(g[5].get("tg") == tid["concrete"] for g in ghosts) and live_lib.inv_count("concrete") == 20,
           "tile ghost: tile-ghost entities sent (extra.tg the tile), no items used", str(ghosts[:1]))
    c.send({"t": "tile_mine", "x": fx(bx - 3.5), "y": fx(by - 4.5), "n": 2})
    msgs = c.pump(1.0, every=hello)
    left = live_lib.mod_lua(f"rcon.print(storage.f3d.puppet.surface.count_entities_filtered({{ type = 'tile-ghost', "
                   f"area = {{ {{ {bx - 6}, {by - 7} }}, {{ {bx}, {by - 2} }} }} }}))")
    live_lib.report(len(live_lib.of_type(msgs, "del")) >= 4 and left == "0", "tile_mine removes tile ghosts under the brush",
           f"{len(live_lib.of_type(msgs, 'del'))} del, {left} left")
    live_lib.mod_lua(f"storage.f3d.puppet.surface.set_tiles({{ {{ name = 'water', position = {{ {bx - 4}, {by + 3} }} }}, "
            f"{{ name = 'water', position = {{ {bx - 3}, {by + 3} }} }} }})")
    c.send({"t": "tile", "item": "landfill", "x": fx(bx - 3), "y": fx(by + 3.5), "n": 2})
    c.send({"t": "tile", "item": "concrete", "x": fx(bx - 3), "y": fx(by + 4.5), "n": 1})
    c.pump(1.5, every=hello)
    t = game_tiles(bx - 4, by + 2, bx - 3, by + 4)
    live_lib.report(t[(bx - 4, by + 3)] == "landfill" and t[(bx - 3, by + 3)] == "landfill" and t[(bx - 4, by + 2)] != "landfill"
           and live_lib.inv_count("landfill") == 3, "landfill only goes on the water under the brush (its condition)", str(t))

    # --- capsules and land mines ---------------------------------------------------------------
    c.send({"t": "throw", "item": "grenade", "x": fx(x + 6), "y": fx(y + 6)})
    msgs = c.pump(1.0, every=hello)
    proj = live_lib.mod_lua(f"rcon.print(storage.f3d.puppet.surface.count_entities_filtered({{ type = 'projectile', position = {{ {x}, {y} }}, radius = 20 }}))")
    c.send({"t": "throw", "item": "grenade", "x": fx(x + 40), "y": fx(y)})
    msgs += c.pump(1.0, every=hello)
    live_lib.report(live_lib.inv_count("grenade") == 2 and any(m["text"] == "Out of range" for m in live_lib.of_type(msgs, "msg")),
           "throw: a grenade at the cursor (LuaItemStack.use_capsule, one used), none out of its range", f"projectiles {proj}, inv {live_lib.inv_count('grenade')}")
    # The discharge defense remote ("equipment-remote": used from a script inventory's stack, there is none in the inventory):
    # it fires the worn discharge defense, which spends its charge on an enemy in range.
    out = live_lib.mod_lua(f"""local c = storage.f3d.puppet local arm = c.get_inventory(defines.inventory.character_armor)[1]
local had = arm.valid_for_read
if not had then arm.set_stack({{ name = 'power-armor-mk2' }}) end
local g = c.grid
local eq = g.put({{ name = 'discharge-defense-equipment' }})
local bat = g.put({{ name = 'battery-mk2-equipment' }})
if not eq then rcon.print('noeq') return end
eq.energy = eq.max_energy
local b = c.surface.create_entity({{ name = 'small-biter', position = {{ {x + 5}, {y} }}, force = 'enemy' }})
storage.f3d_dd = {{ had = had, biter = b }}
rcon.print('ok ' .. eq.energy)""".replace("\n", " "))
    if out.startswith("ok"):
        c.send({"t": "throw", "item": "discharge-defense-remote", "x": fx(x + 5), "y": fx(y)})
        msgs = c.pump(2.0, every=hello)
        after = live_lib.mod_lua("local g = storage.f3d.puppet.grid local e for _, q in pairs(g.equipment) do if q.name == 'discharge-defense-equipment' then e = q end end "
                        "local b = storage.f3d_dd.biter rcon.print((e and e.energy or -1) .. ' ' .. ((b and b.valid) and b.health or 'dead'))")
        parts = after.split()
        spent = len(parts) == 2 and float(parts[0]) < float(out.split()[1])
        live_lib.report(spent and not any(m["text"].startswith("Can't use") for m in live_lib.of_type(msgs, "msg")),
               "throw: the discharge defense remote fires the worn discharge defense at an enemy (LuaItemStack.use_capsule, equipment-remote)",
               f"energy {out.split()[1]} -> {parts[:1]}, biter {parts[1:]}, msgs {[m['text'] for m in live_lib.of_type(msgs, 'msg')]}")
    else:
        live_lib.report(False, "discharge defense remote: couldn't set up the equipment grid", out[:200])
    live_lib.mod_lua("local c = storage.f3d.puppet local d = storage.f3d_dd if d then if d.biter and d.biter.valid then d.biter.destroy() end "
            "c.grid.clear() if not d.had then c.get_inventory(defines.inventory.character_armor)[1].clear() end storage.f3d_dd = nil end")
    out = live_lib.mod_lua(f"local c = storage.f3d.puppet local e = c.surface.create_entity({{ name = 'cliff', position = {{ {bx + 6}, {by + 5} }}, "
                  "cliff_orientation = 'west-to-east' }) rcon.print(e and (e.position.x .. ' ' .. e.position.y) or 'none')")
    if out != "none":
        cx_, cy_ = (float(v) for v in out.split())
        c.send({"t": "throw", "item": "cliff-explosives", "x": fx(cx_), "y": fx(cy_)})
        c.pump(4.0, every=hello)
        left = live_lib.mod_lua(f"rcon.print(storage.f3d.puppet.surface.count_entities_filtered({{ type = 'cliff', position = {{ {cx_}, {cy_} }}, radius = 3 }}))")
        live_lib.report(left == "0" and live_lib.inv_count("cliff-explosives") == 1, "cliff explosives thrown at a cliff blow it up",
               f"cliffs left {left}, inv {live_lib.inv_count('cliff-explosives')}")
    else:
        live_lib.report(False, "cliff explosives: couldn't make a cliff for the test")
    hp = live_lib.mod_lua("local c = storage.f3d.puppet c.health = c.health - 60 rcon.print(c.health)")
    c.send({"t": "throw", "item": "raw-fish", "x": fx(x + 3), "y": fx(y)})
    c.pump(1.5, every=hello)
    hp2 = live_lib.mod_lua("rcon.print(storage.f3d.puppet.health)")
    live_lib.report(float(hp2) > float(hp) and live_lib.inv_count("raw-fish") == 1, "raw fish (use-on-self) heals the character", f"{hp} -> {hp2}")
    c.send({"t": "build", "item": "land-mine", "x": fx(bx + 2.5), "y": fx(by + 6.5), "d": 0})
    c.pump(1.0, every=hello)
    live_lib.report(live_lib.mod_lua(f"rcon.print(storage.f3d.puppet.surface.count_entities_filtered({{ name = 'land-mine', position = {{ {bx + 2.5}, {by + 6.5} }}, radius = 1 }}))") == "1",
           "a land mine is built like any entity")

    # Super-forced build (Ctrl+Shift+click): a ghost over a tree, the tree marked for deconstruction.
    live_lib.mod_lua(f"storage.f3d.puppet.surface.create_entity({{ name = 'tree-01', position = {{ {bx - 12.5}, {by + 3.5} }} }})")
    c.send({"t": "build", "item": "wooden-chest", "x": fx(bx - 12.5), "y": fx(by + 3.5), "d": 0, "ghost": 1, "sf": 1})
    c.pump(1.0, every=hello)
    out = live_lib.mod_lua(f"local s = storage.f3d.puppet.surface local t = s.find_entities_filtered({{ type = 'tree', position = {{ {bx - 12.5}, {by + 3.5} }}, radius = 1 }})[1] "
                  f"rcon.print(tostring(t and t.to_be_deconstructed()) .. ' ' .. s.count_entities_filtered({{ ghost_name = 'wooden-chest', position = {{ {bx - 12.5}, {by + 3.5} }}, radius = 0.6 }}))")
    live_lib.report(out == "true 1", "super-forced build: the ghost goes over the tree, which is marked for deconstruction", out)

    # --- the rail planner ----------------------------------------------------------------------
    # A straight rail east of the character, then a path from its north end: straight, curve,
    # half-diagonal, by the client's extension table; every piece must join the one before.
    rx, ry = math.floor((x + 6) / 2) * 2 + 1, math.floor((y + 8) / 2) * 2 + 1
    c.send({"t": "rails", "item": "rail", "l": [["straight-rail", fx(rx), fx(ry), 0]]})
    c.pump(0.8, every=hello)
    pieces, end, end_dir = rail_path((rx, ry - 1), 0, [0, 0, 1, 0, 2])
    names = [p[0] for p in pieces]
    rails_before = live_lib.inv_count("rail")
    c.send({"t": "rails", "item": "rail", "l": [[n, fx(px), fx(py), d] for n, px, py, d in pieces]})
    msgs = c.pump(1.5, every=hello)
    out = live_lib.mod_lua(f"""
local s = storage.f3d.puppet.surface local o = {{}}
for _, p in pairs({{ {', '.join(f'{{ "{n}", {px}, {py}, {d} }}' for n, px, py, d in pieces)} }}) do
  local e = s.find_entities_filtered({{ name = p[1], position = {{ p[2], p[3] }} }})[1]
  o[#o + 1] = e and (e.direction == p[4] and "ok" or "dir" .. e.direction) or "missing"
end
local first = s.find_entities_filtered({{ name = 'straight-rail', position = {{ {rx}, {ry} }} }})[1]
local en = first.get_rail_end(defines.rail_direction.front)
local n = 0
for i = 1, {len(pieces)} do if en.move_forward(defines.rail_connection_direction.straight) or en.move_forward(defines.rail_connection_direction.left) or en.move_forward(defines.rail_connection_direction.right) then n = n + 1 end end
rcon.print(table.concat(o, ",") .. " joined " .. n)
""".replace("\n", " "))
    cost = {"straight-rail": 1, "half-diagonal-rail": 2, "curved-rail-a": 3, "curved-rail-b": 3}
    live_lib.report(out == ",".join(["ok"] * len(pieces)) + f" joined {len(pieces)}"
           and rails_before - live_lib.inv_count("rail") == sum(cost[n] for n in names),
           "rails: the planner's path (straight, curve, half-diagonal from rail_extensions.json) is built where the client "
           "said, every piece joined to the last (LuaRailEnd.move_forward), paid in rails (items_to_place_this)",
           f"{names}: {out}, rails {rails_before} -> {live_lib.inv_count('rail')}")
    # Too few rails: the rest are ghosts.
    live_lib.mod_lua(f"local inv = storage.f3d.puppet.get_main_inventory() inv.remove({{ name = 'rail', count = inv.get_item_count('rail') - 2 }})")
    more, end2, _ = rail_path(end, end_dir, [0, 0, 0, 0])
    c.send({"t": "rails", "item": "rail", "l": [[n, fx(px), fx(py), d] for n, px, py, d in more]})
    msgs = c.pump(1.5, every=hello)
    adds = [m["e"] for m in live_lib.of_type(msgs, "add")]
    real = [a for a in adds if a[1] != c.proto_id("entity-ghost")]
    ghosts = [a for a in adds if a[1] == c.proto_id("entity-ghost")]
    live_lib.report(len(real) + len(ghosts) == len(more) and len(ghosts) >= 1 and any("placed as ghosts" in m["text"] for m in live_lib.of_type(msgs, "msg")),
           "rails: past the rails in the inventory (or reach) the pieces are ghosts", f"{len(real)} built, {len(ghosts)} ghosts of {more}")
    c.send({"t": "rails", "item": "rail", "l": [["wooden-chest", fx(rx), fx(ry - 30), 0]]})
    live_lib.report(any(m["text"].startswith("Can't build that") for m in live_lib.of_type(c.pump(0.8, every=hello), "msg")),
           "rails: only what the planner builds (its rails and support)")

    # Elevated: a ramp from a ground rail end, elevated rails on supports. Needs the research.
    live_lib.mod_lua("storage.f3d.puppet.force.rail_planner_allow_elevated_rails = true "
            "storage.f3d.puppet.insert({ name = 'rail', count = 40 })")
    ex, ey = rx - 12, ry  # clear of the character: a ramp is 4 tiles wide and 16 long
    live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {ex + 2.6}, {ey - 11} }})")  # all of it within reach, beside the ramp
    ground_rail = ["straight-rail", fx(ex), fx(ey), 0]
    ramp = ["rail-ramp", fx(ex), fx(ey - 9), 0]  # the ramp's ground end is 8 south of its centre
    elev, eend, _ = rail_path((ex, ey - 17), 0, [0, 0, 0])  # elevated straight rails north of the ramp's top
    elev = [["elevated-" + n, fx(px), fx(py), d] for n, px, py, d in elev]
    support = ["rail-support", fx(ex), fx(ey - 22), 0]
    c.send({"t": "rails", "item": "rail", "l": [ground_rail, support, ramp] + elev})
    msgs = c.pump(2.0, every=hello)
    out = live_lib.mod_lua(f"local s = storage.f3d.puppet.surface rcon.print(s.count_entities_filtered({{ name = {{ 'rail-ramp', "
                  f"'elevated-straight-rail', 'rail-support' }}, area = {{ {{ {ex - 3}, {ey - 30} }}, {{ {ex + 3}, {ey} }} }} }}) .. ' ' .. "
                  f"s.count_entities_filtered({{ type = 'entity-ghost', area = {{ {{ {ex - 3}, {ey - 30} }}, {{ {ex + 3}, {ey} }} }} }}))")
    live_lib.report(out == f"{2 + len(elev)} 0", "rails: a ramp and elevated rails over a support, all built (supports first: an elevated "
           "rail needs one in range along the track)", f"real, ghosts: {out}; {[m['text'] for m in live_lib.of_type(msgs, 'msg')]}")

    live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {x}, {y} }})")
    # Leave the spot empty for the next run (the rails reach past the clean square).
    live_lib.mod_lua(f"local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({{ area = {{ {{ {bx - 24}, {by - 40} }}, "
            f"{{ {bx + 24}, {by + 24} }} }}, force = c.force }})) do if e ~= c then e.destroy() end end")


def check_splitter_snap(c, hello, x, y):
    """J9 (the owner: placing a splitter over a belt sometimes shifts it over one tile): a splitter built over a row of
    belts stands where the cursor's point snaps, as Factorio's prototype docs say for an even tile_width ("the center is
    on the tile transition") and an odd one (the tile's middle): on the tile edge nearest the cursor across, so over the
    belt under the cursor and the one on the side the cursor leans to, both replaced and given back. First what the
    game's own create_entity makes of unsnapped points (printed): the same rule in every direction."""
    own = live_lib.mod_lua(f"""local c = storage.f3d.puppet local s = c.surface local n, bad = 0, 0
local function snap(v, size) if size % 2 == 1 then return math.floor(v) + 0.5 end return math.floor(v + 0.5) end
for _, d in pairs({{ defines.direction.north, defines.direction.east, defines.direction.south, defines.direction.west }}) do
  local w, h = 2, 1 if d == defines.direction.east or d == defines.direction.west then w, h = 1, 2 end
  for _, f in pairs({{ 0.004, 0.25, 0.496, 0.5, 0.504, 0.75, 0.996 }}) do for _, g in pairs({{ 0.3, 0.7 }}) do for swap = 0, 1 do
    local cx, cy = {x} + 20 + f, {y} - 4 + g if swap == 1 then cx, cy = {x} + 20 + g, {y} - 4 + f end
    local e = s.create_entity({{ name = 'splitter', position = {{ cx, cy }}, direction = d, force = c.force }}) n = n + 1
    if not e or e.position.x ~= snap(cx, w) or e.position.y ~= snap(cy, h) then bad = bad + 1 end
    if e then e.destroy() end
  end end end
end
rcon.print(n .. ' placements, ' .. bad .. ' off the rule')""".replace("\n", " "))
    print(f"  J9: the game's own create_entity snaps a splitter's point (every direction): {own}")
    live_lib.report(own.endswith(" 0 off the rule"), "J9: Factorio snaps a splitter as the bridge and the client do (odd: the tile's middle, even: the nearest tile edge)", own)
    out = live_lib.mod_lua(f"""local c = storage.f3d.puppet local s = c.surface local u = {{}}
for i = 0, 6 do local e = s.create_entity({{ name = 'transport-belt', position = {{ {x} + i + 0.5, {y} - 4 + 0.5 }},
  direction = defines.direction.north, force = c.force, raise_built = true }}) u[#u + 1] = e.unit_number end
c.get_main_inventory().insert({{ name = 'splitter', count = 2 }}) rcon.print(table.concat(u, ' '))""".replace("\n", " "))
    try:
        row = [int(v) for v in out.split()]
    except ValueError:
        row = []
    if len(row) != 7:
        live_lib.report(False, "J9: a row of belts for the splitters", out)
        return
    c.pump(0.5, every=hello)
    fx = lambda v: math.floor(v * 256 + 0.5)
    got = []
    # The cursor in the left half of the second belt's tile, then in the right half of the fifth's: sent as the
    # client sends it (rounded down to 1/256 tile).
    for cx, want_x, under in ((x + 1.3, x + 1, row[0:2]), (x + 4.7, x + 5, row[4:6])):
        c.send({"t": "build", "item": "splitter", "x": math.floor(cx * 256), "y": math.floor((y - 4 + 0.4) * 256), "d": 0})
        msgs = c.pump(1.0, every=hello)
        adds = [a["e"][2:5] for a in live_lib.of_type(msgs, "add") if a["e"][1] == c.proto_id("splitter")]
        dels = {d["u"] for d in live_lib.of_type(msgs, "del")}
        got.append((adds[:1] == [[fx(want_x), fx(y - 4 + 0.5), 0]], set(under) <= dels, adds[:1], sorted(dels & set(row))))
    live_lib.report(all(g[0] for g in got), "J9: a splitter over belts stands on the tile edge on the cursor's side of the belt under it",
           str([g[2] for g in got]))
    live_lib.report(all(g[1] for g in got), "J9: and replaces both belts under it (their `del`s)", str([g[3] for g in got]))


def check_under_clear(c, hello):
    """M2: an underground pair the client builds over a run of belts mines the belts between into the character, their
    items too, as Factorio's player build does (its tips and tricks: "Any belts in between the entrance and exit of the
    underground belt will be mined automatically"), each said at once (`mnd`); pipes-to-ground over pipes the same.
    A run with a belt side-loading into it keeps its belts (only "simple" ones go), and so does one with the switch
    off. First whether a script's create_entity{fast_replace, character} does it by itself (printed: in 2.1.24 it
    doesn't, so the bridge mines them)."""
    live_lib.clear_enemies()  # a biter left from the shooting checks kills the character in the middle (see clear_enemies)
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "under_clear: an empty spot", live_lib.SPOT_WHY)
        return
    x, y = math.floor(c.me["x"] / 256), math.floor(c.me["y"] / 256)
    fx = lambda v: math.floor(v * 256 + 0.5)  # world.fixed
    # Rows (y + dy), every lane full so nothing moves (a line backed up to its end): 2 a plain east run, 8 plates a
    # belt, 4 the same with a belt side-loading into its third,
    # 6 pipes, 8 a plain run built with the switch off, 10 the script's own create_entity (character, fast_replace),
    # -2 a plain run whose two ends are sent together (a drag's pair; within the character's reach, as the rest).
    out = live_lib.mod_lua(f"""local c = storage.f3d.puppet local s = c.surface
local t = {{ rows = {{}} }}
for _, dy in pairs({{ 2, 4, 6, 8, 10, -2 }}) do
  local row = {{}}
  for i = 0, 6 do
    local e = s.create_entity({{ name = dy == 6 and 'pipe' or 'transport-belt', position = {{ {x} + i + 0.5, {y} + dy + 0.5 }},
      direction = defines.direction.east, force = c.force, raise_built = true }})
    if dy ~= 6 then
      for l = 1, 2 do for k = 0, 3 do e.get_transport_line(l).insert_at(0.125 + 0.25 * k, {{ name = 'iron-plate', count = 1 }}) end end
    end
    row[#row + 1] = e
  end
  t.rows[dy] = row
end
t.side = s.create_entity({{ name = 'transport-belt', position = {{ {x} + 2.5, {y} + 3.5 }}, direction = defines.direction.south,
  force = c.force, raise_built = true }})
c.get_main_inventory().insert({{ name = 'underground-belt', count = 10 }})
c.get_main_inventory().insert({{ name = 'pipe-to-ground', count = 2 }})
storage.f3d_m2 = t
local u = {{}} for i = 2, 5 do u[#u + 1] = t.rows[2][i].unit_number end
rcon.print(table.concat(u, ' '))""".replace("\n", " "))
    try:
        middle = {int(v) for v in out.split()}
    except ValueError:
        live_lib.report(False, "under_clear: belt runs and pipes laid, undergrounds in the inventory", out)
        return
    # The script's own create_entity with the character: does the game mine the run between? (Printed.)
    own = live_lib.mod_lua(f"""local c = storage.f3d.puppet local s = c.surface local t = storage.f3d_m2
local a = s.create_entity({{ name = 'underground-belt', position = {{ {x} + 0.5, {y} + 10.5 }}, direction = defines.direction.east,
  type = 'input', force = c.force, fast_replace = true, character = c }})
local b = s.create_entity({{ name = 'underground-belt', position = {{ {x} + 5.5, {y} + 10.5 }}, direction = defines.direction.east,
  type = 'output', force = c.force, fast_replace = true, character = c }})
local n = 0 for i = 2, 5 do if t.rows[10][i].valid then n = n + 1 end end
local paired = a and b and a.underground_belt_neighbour == b
for _, e in pairs({{ a, b }}) do if e and e.valid then e.destroy() end end
rcon.print('paired ' .. tostring(paired) .. ', ' .. n .. ' of 4 between still there')""".replace("\n", " "))
    print(f"  M2: a script's create_entity{{fast_replace, character}} pair over a run: {own}")
    live_lib.report(True, "under_clear: what a script's own fast-replace pair does to the run printed (the bridge mines it)", own)

    def count(item):
        try:
            return int(live_lib.mod_lua(f"rcon.print(storage.f3d.puppet.get_main_inventory().get_item_count('{item}'))"))
        except ValueError:
            return -1

    def build(item, dy, x0, d0, x1, d1):
        msgs = []
        for bx, d in ((x0, d0), (x1, d1)):
            c.send({"t": "build", "item": item, "x": fx(x + bx + 0.5), "y": fx(y + dy + 0.5), "d": d})
            msgs += c.pump(0.4, every=hello)
        return msgs + c.pump(1.0, every=hello)

    def alive(dy):
        return live_lib.mod_lua(f"local r = {{}} for _, e in ipairs(storage.f3d_m2.rows[{dy}]) do r[#r + 1] = e.valid and '1' or '0' end "
                       "rcon.print(table.concat(r))")

    belts0, plates0 = count("transport-belt"), count("iron-plate")
    msgs = build("underground-belt", 2, 0, 4, 5, 4)
    row2 = alive(2)
    mnd = {m["u"]: m for m in live_lib.of_type(msgs, "mnd") if m["u"] in middle}
    dels = {d["u"] for d in live_lib.of_type(msgs, "del")}
    belts1, plates1 = count("transport-belt"), count("iron-plate")
    print(f"  M2: row {row2} (ends and the four between gone, the last kept), mnd {sorted(mnd)}, belts {belts0} -> {belts1}, "
          f"plates {plates0} -> {plates1}")
    live_lib.report(row2 == "0000001", "under_clear: an underground pair over a plain run mines the four belts between", row2)
    live_lib.report(set(mnd) == middle and all(m["g"] == 1 and ["transport-belt", 1] in m["l"] and ["iron-plate", 8] in m["l"]
                                      for m in mnd.values()),
           "under_clear: each is said at once (`mnd`: gone, the belt and its 8 plates to the character)", str(list(mnd.values())[:2]))
    live_lib.report(middle <= dels, "under_clear: and their `del`s come", f"{sorted(middle - dels)} missing")
    live_lib.report(belts1 - belts0 == 6 and plates1 - plates0 == 48,
           "under_clear: six belts (four between, the two the ends replaced) and their 48 plates in the inventory",
           f"belts +{belts1 - belts0}, plates +{plates1 - plates0}")
    build("underground-belt", 4, 0, 4, 5, 4)
    live_lib.report(alive(4)[1:5] == "1111", "under_clear: a run with a belt side-loading into it keeps its belts", alive(4))
    pipes0 = count("pipe")
    build("pipe-to-ground", 6, 0, 12, 5, 4)
    row6 = alive(6)
    live_lib.report(row6 == "0000001" and count("pipe") - pipes0 == 6, "under_clear: a pipe-to-ground pair over pipes mines the four between",
           f"{row6}, pipes +{count('pipe') - pipes0}")
    # M2's leftover: a drag sends both ends back to back (one datagram each, the same tick or the next): the run
    # between is mined just the same, said in the answer to the exit (what the client hides ahead of).
    for bx in (0, 5):
        c.send({"t": "build", "item": "underground-belt", "x": fx(x + bx + 0.5), "y": fx(y - 2 + 0.5), "d": 4})
    msgs = c.pump(1.5, every=hello)
    row12 = alive(-2)
    said = len([m for m in live_lib.of_type(msgs, "mnd") if m.get("g") == 1 and ["transport-belt", 1] in m.get("l", [])])
    live_lib.report(row12 == "0000001" and said == 4, "under_clear: both ends sent together (a drag's pair): the four between mined, an `mnd` each",
           f"{row12}, {said} mnd")
    rcon.run("/f3d-perf under_clear off")
    build("underground-belt", 8, 0, 4, 5, 4)
    rcon.run("/f3d-perf under_clear default")
    live_lib.report(alive(8)[1:5] == "1111", "under_clear: /f3d-perf under_clear off keeps the run, as before", alive(8))
    check_splitter_snap(c, hello, x, y)
    live_lib.mod_lua(f"""local c = storage.f3d.puppet local s = c.surface
for _, e in pairs(s.find_entities_filtered({{ area = {{ {{ {x} - 1, {y} - 5 }}, {{ {x} + 8, {y} + 12 }} }},
  type = {{ 'transport-belt', 'underground-belt', 'pipe', 'pipe-to-ground', 'splitter' }} }})) do e.destroy({{ raise_destroy = true }}) end
storage.f3d_m2 = nil rcon.print('ok')""".replace("\n", " "))


def check_pipe_end(c, hello):
    """The owner's FUE5 pipe left open where its run now ends (and a T left a T): the bridge's player-less character
    mines with LuaControl.mine_entity, which raises no event, so the pipes and belts beside what it mined never had
    their shapes sent again (`pc`, a belt's `s`); `/f3d-perf mined_neighbours` queues them for the next tick. Each case
    is built, its piece removed (the bridge's `mine`, damage, a construction robot) and the neighbours' `upd` waited
    for: a run of five losing its middle (endings), a corner, a T losing its branch (a straight), a cross losing an arm
    (a T), a pipe-to-ground and a pipe beside each other, a pump and a storage tank under pipes, a belt curve
    straightened, a side-loaded belt curving once the belt behind it goes, a pipe `die`d, one a robot deconstructs, and
    the switch off (no `upd`). Walls and heat pipes are joined by the client itself (no shape from the bridge: checked),
    so only their `del` is looked for."""
    live_lib.clear_enemies()
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "pipe end: an empty spot", live_lib.SPOT_WHY)
        return
    x, y = math.floor(c.me["x"] / 256), math.floor(c.me["y"] / 256)
    home = (x + 0.5, y + 0.5)
    area = f"{{ {{ {x} - 9, {y} + 1 }}, {{ {x} + 9, {y} + 12 }} }}"
    types = ("{ 'pipe', 'pipe-to-ground', 'pump', 'transport-belt', 'wall', 'heat-pipe', 'storage-tank', 'roboport', "
             "'electric-energy-interface', 'electric-pole', 'logistic-container', 'construction-robot', 'item-entity' }")
    N, E, S, W = 0, 4, 8, 12

    def clear():
        live_lib.mod_lua(f"local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({{ area = {area}, "
                f"type = {types} }})) do e.destroy({{ raise_destroy = true }}) end rcon.print('ok')")
        c.pump(0.6, every=hello)

    def lay(parts):
        """parts: (name, dx, dy, direction) from (x, y + 2); their unit numbers and their latest records sent."""
        lines = []
        for name, dx, dy, d in parts:
            lines.append(f"u[#u + 1] = s.create_entity({{ name = '{name}', position = {{ {x} + {dx}, {y} + 2 + {dy} }}, "
                         f"direction = {d}, force = c.force, raise_built = true }}).unit_number")
        out = live_lib.mod_lua("local c = storage.f3d.puppet local s = c.surface local u = {} " + " ".join(lines)
                      + " rcon.print(table.concat(u, ' '))")
        try:
            units = [int(v) for v in out.split()]
        except ValueError:
            return None, {}, out
        recs = {}
        for m in c.pump(1.0, every=hello):
            if m.get("t") in ("add", "upd") and m["e"][0] in units:
                recs[m["e"][0]] = m["e"]
        return units, recs, out

    def remove_and_watch(unit, rec, watch, how="mine"):
        """Removes `unit` (the bridge's `mine`; `die`; "robot": already ordered), then waits for every unit in `watch`
        to be sent again: ({unit: (record, seconds after the del)}, whether its del came)."""
        if how == "die":
            live_lib.mod_lua(f"local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({{ area = {area} }})) do "
                    f"if e.unit_number == {unit} then e.die() end end rcon.print('ok')")
        cmd = {"t": "mine", "u": unit, "p": rec[1], "x": rec[2], "y": rec[3]} if rec else None
        t_del, got = None, {}
        end = time.time() + (30 if how == "robot" else 6)
        while time.time() < end:
            if how == "mine" and t_del is None and cmd:
                c.send(cmd)
            for m in c.pump(0.15, every=hello):
                if m.get("t") == "del" and m.get("u") == unit and t_del is None:
                    t_del = time.time()
                if m.get("t") == "upd" and m["e"][0] in watch and t_del is not None:
                    got.setdefault(m["e"][0], (m["e"], round(time.time() - t_del, 2)))
            if t_del is not None and (len(got) == len(watch) or time.time() - t_del > 1.5):
                break
        if how == "mine":
            c.send({"t": "mine_stop"})
        return got, t_del is not None

    def extra(rec, key):
        return rec[5].get(key) if rec and len(rec) > 5 and isinstance(rec[5], dict) else None

    live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {home[0]}, {home[1]} }})")
    print("  pipe end: act-as-player " + live_lib.mod_lua("rcon.print(tostring(settings.global['f3d-act-as-player'].value))")
          + ", players connected " + live_lib.mod_lua("rcon.print(#game.connected_players)") + " (none: the bridge mines with mine_entity)")

    def pipe_case(label, parts, target, expect, how="mine"):
        """expect: {index in parts: the pc wanted after} (1 north, 2 east, 4 south, 8 west)."""
        units, recs, out = lay(parts)
        if units is None:
            live_lib.report(False, f"pipe end: {label}: laid", out)
            clear()
            return
        before = {i: extra(recs.get(units[i]), "pc") for i in expect}
        got, gone = remove_and_watch(units[target], recs.get(units[target]), {units[i] for i in expect}, how)
        after = {i: (extra(got[units[i]][0], "pc") if units[i] in got else None) for i in expect}
        secs = {i: got[units[i]][1] for i in expect if units[i] in got}
        live_lib.report(gone and after == expect and all(v <= 0.6 for v in secs.values()),
               f"pipe end: {label}: the neighbours sent again at once with their new shape",
               f"removed {gone}, pc before {before}, after {after} (wanted {expect}), seconds after the del {secs}")
        clear()

    pipe_case("a run of five, its middle mined", [("pipe", dx + 0.5, 0.5, N) for dx in range(-2, 3)], 2, {1: 8, 3: 2})
    pipe_case("a corner losing its south side", [("pipe", -0.5, 0.5, N), ("pipe", 0.5, 0.5, N), ("pipe", 0.5, 1.5, N)],
              2, {1: 8})
    pipe_case("a T losing its branch (the owner's T): a straight",
              [("pipe", -0.5, 0.5, N), ("pipe", 0.5, 0.5, N), ("pipe", 1.5, 0.5, N), ("pipe", 0.5, 1.5, N)], 3, {1: 10})
    pipe_case("a cross losing its north arm: a T",
              [("pipe", -0.5, 1.5, N), ("pipe", 0.5, 1.5, N), ("pipe", 1.5, 1.5, N), ("pipe", 0.5, 2.5, N),
               ("pipe", 0.5, 0.5, N)], 4, {1: 14, 0: 2, 2: 8})  # (the south arm, two tiles off, keeps its side: not sent)
    pipe_case("a pipe-to-ground mined beside a pipe",
              [("pipe", -0.5, 0.5, N), ("pipe", 0.5, 0.5, N), ("pipe-to-ground", 1.5, 0.5, W)], 2, {1: 8})
    pipe_case("a pipe mined beside a pipe-to-ground",
              [("pipe-to-ground", -0.5, 0.5, E), ("pipe", 0.5, 0.5, N), ("pipe", 1.5, 0.5, N)], 1, {0: 0, 2: 0})
    pipe_case("a pump mined under the pipes on its output",
              [("pipe", 0.5, 0.5, N), ("pipe", 0.5, 1.5, N), ("pump", 0.5, 3.0, N)], 2, {1: 1})
    pipe_case("a storage tank mined beside the pipes on its connection",
              [("storage-tank", 1.5, 2.5, N), ("pipe", -0.5, 1.5, N), ("pipe", -1.5, 1.5, N)], 0, {1: 8})
    pipe_case("a pipe destroyed by damage (die)", [("pipe", dx + 0.5, 0.5, N) for dx in range(-1, 2)], 1, {0: 0, 2: 0},
              how="die")

    # The switch off: nothing sent for the neighbours (the bug as it was).
    rcon.run("/f3d-perf mined_neighbours off")
    units, recs, out = lay([("pipe", dx + 0.5, 0.5, N) for dx in range(-2, 3)])
    if units:
        got, gone = remove_and_watch(units[2], recs.get(units[2]), {units[1], units[3]})
        live_lib.report(gone and not got, "pipe end: /f3d-perf mined_neighbours off sends nothing for the neighbours, as before",
               f"removed {gone}, sent {sorted(got)}")
    else:
        live_lib.report(False, "pipe end: the switch's run laid", out)
    rcon.run("/f3d-perf mined_neighbours default")
    clear()

    # Belts: a curve straightened when the belt feeding its side goes; a side-loaded belt curving once the belt behind goes.
    for label, parts, target, watch, want in (
            ("a belt curve whose feeding belt is mined is sent straight",
             [("transport-belt", -0.5, 0.5, E), ("transport-belt", 0.5, 0.5, S)], 0, 1, "straight"),
            ("a side-loaded belt whose belt behind is mined is sent as the curve it becomes",
             [("transport-belt", dx + 0.5, 0.5, E) for dx in range(-1, 2)] + [("transport-belt", 0.5, -0.5, S)], 0, 1,
             "curve")):
        units, recs, out = lay(parts)
        if units is None:
            live_lib.report(False, f"pipe end: {label}: laid", out)
            clear()
            continue
        before = extra(recs.get(units[watch]), "s")
        got, gone = remove_and_watch(units[target], recs.get(units[target]), {units[watch]})
        after = extra(got[units[watch]][0], "s") if units[watch] in got else None
        ok = (before in ("l", "r") and after == "s") if want == "straight" else (before == "s" and after in ("l", "r"))
        live_lib.report(gone and ok and got[units[watch]][1] <= 0.6, f"pipe end: {label}",
               f"removed {gone}, s {before} -> {after}, {got.get(units[watch], (0, None))[1]} s after the del")
        clear()

    # Walls and heat pipes: the client joins them itself; the bridge sends no shape, and the `del` is what it needs.
    for name in ("stone-wall", "heat-pipe"):
        units, recs, out = lay([(name, dx + 0.5, 0.5, N) for dx in range(-1, 2)])
        if units is None:
            live_lib.report(False, f"pipe end: {name}s laid", out)
            clear()
            continue
        extras = [(recs[u][5] if len(recs[u]) > 5 else {}) if u in recs else None for u in units]
        _, gone = remove_and_watch(units[1], recs.get(units[1]), set())
        live_lib.report(gone and None not in extras and all(not ("pc" in e or "wc" in e) for e in extras),
               f"pipe end: a {name} mined from a row of three: its `del` comes, and the bridge sends no shape for them "
               "(the client joins them)", f"removed {gone}, extras {extras}")
        clear()

    # A construction robot deconstructing a pipe (on_robot_mined_entity) still has its neighbours sent.
    out = live_lib.mod_lua(f"""local c = storage.f3d.puppet local s = c.surface
local e = s.create_entity({{ name = 'electric-energy-interface', position = {{ {x} - 6, {y} + 9 }}, force = c.force }})
e.power_production = 1e9 e.electric_buffer_size = 1e10
s.create_entity({{ name = 'medium-electric-pole', position = {{ {x} - 4.5, {y} + 9.5 }}, force = c.force }})
local r = s.create_entity({{ name = 'roboport', position = {{ {x} - 2, {y} + 9 }}, force = c.force }})
r.get_inventory(defines.inventory.roboport_robot).insert({{ name = 'construction-robot', count = 5 }})
s.create_entity({{ name = 'storage-chest', position = {{ {x} + 1.5, {y} + 9.5 }}, force = c.force }})
rcon.print('ok')""".replace("\n", " "))
    units, recs, _ = lay([("pipe", dx + 0.5, 0.5, N) for dx in range(-1, 2)])
    if units and out == "ok":
        c.pump(2.0, every=hello)  # the roboport charges its robots
        live_lib.mod_lua(f"local c = storage.f3d.puppet for _, e in pairs(c.surface.find_entities_filtered({{ area = {area}, name = 'pipe' }})) do "
                f"if e.unit_number == {units[1]} then e.order_deconstruction(c.force) end end rcon.print('ok')")
        got, gone = remove_and_watch(units[1], recs.get(units[1]), {units[0], units[2]}, how="robot")
        after = {u: extra(got[u][0], "pc") for u in got}
        live_lib.report(gone and after == {units[0]: 0, units[2]: 0},
               "pipe end: a pipe a construction robot deconstructs: its neighbours sent again as lone pipes",
               f"removed {gone}, after {after}")
    else:
        live_lib.report(False, "pipe end: a roboport, robots and pipes laid", out)
    clear()
    live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {home[0]}, {home[1]} }})")


def client_pipelines(records, eprops, types):
    """N9: client/scripts/player/pipeline_marks.gd's rule in Python, on the bridge's own records: a pipe joins across its
    `pc` sides (a pipe whose `pc` has the side back, a pipe to ground facing it, a tank whose connection leads onto it);
    a pipe to ground also its open side and its underground partner (the first piece of its kind along its back within
    `under` tiles facing either way, a partner when it faces back); a tank its `eprops` fluid boxes. Anything else ends a
    pipeline. Returns {unit: pipeline number}."""
    by_unit = {r[0]: r for r in records if r[0]}
    pipes, tanks = {}, {}
    for r in by_unit.values():
        t = types.get(r[1], "")
        tx, ty = math.floor(r[2] / 256), math.floor(r[3] / 256)
        if t in ("pipe", "infinity-pipe", "pipe-to-ground"):
            pipes[(tx, ty)] = r
        elif t == "storage-tank":
            cx, cy = r[2] / 256, r[3] / 256
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    tanks[(math.floor(cx + dx), math.floor(cy + dy))] = r

    def extra(r):
        return r[5] if len(r) > 5 and isinstance(r[5], dict) else {}

    def turn(v, d):
        # 16-way direction d clockwise, as CursorOverlay.turn (quarter turns only here)
        x, y = v
        for _ in range((d // 4) % 4):
            x, y = -y, x
        return x, y

    def ports(t):
        x = ((eprops.get(t[1]) or [None] * 4)[3:] or [{}])[0] or {}
        out = []
        for c in x.get("fb") or x.get("fj") or []:
            ox, oy = turn((c[0], c[1]), t[4])
            wx, wy = turn(PIPE_STEPS[(c[2] // 4) % 4], t[4])
            own = (math.floor(t[2] / 256 + ox), math.floor(t[3] / 256 + oy))
            out.append((own, (own[0] + wx, own[1] + wy)))
        return out

    def at(tile):
        return pipes.get(tile) or tanks.get(tile)

    def side(r, tile, i, out):
        nx, ny = tile[0] + PIPE_STEPS[i][0], tile[1] + PIPE_STEPS[i][1]
        back = (i + 2) % 4
        o = at((nx, ny))
        if o is None:
            return
        t = types.get(o[1], "")
        if t in ("pipe", "infinity-pipe") and int(extra(o).get("pc", 0)) & (1 << back):
            out.append(o)
        elif t == "pipe-to-ground" and o[4] == back * 4:
            out.append(o)
        elif t == "storage-tank" and any(port[1] == tile for port in ports(o)):
            out.append(o)

    def partner(r):
        reach = int((eprops.get(r[1]) or [10])[0] or 10)
        tx, ty = math.floor(r[2] / 256), math.floor(r[3] / 256)
        sx, sy = PIPE_STEPS[(r[4] // 4) % 4]
        back = (r[4] + 8) % 16
        for k in range(1, reach + 1):
            o = pipes.get((tx - sx * k, ty - sy * k))
            if o is not None and o[1] == r[1] and o[4] in (r[4], back):
                return o if o[4] == back else None
        return None

    def neighbours(r):
        t = types.get(r[1], "")
        tile = (math.floor(r[2] / 256), math.floor(r[3] / 256))
        out = []
        if t in ("pipe", "infinity-pipe"):
            for i in range(4):
                if int(extra(r).get("pc", 0)) & (1 << i):
                    side(r, tile, i, out)
        elif t == "pipe-to-ground":
            opened = (r[4] // 4) % 4
            if "pc" not in extra(r) or int(extra(r)["pc"]) & (1 << opened):
                side(r, tile, opened, out)
            o = partner(r)
            if o is not None:
                out.append(o)
        elif t == "storage-tank":
            for own, nxt in ports(r):
                o = at(nxt)
                if o is None or o is r:
                    continue
                ot = types.get(o[1], "")
                step = (nxt[0] - own[0], nxt[1] - own[1])
                back = PIPE_STEPS.index((-step[0], -step[1]))
                if ot in ("pipe", "infinity-pipe") and int(extra(o).get("pc", 0)) & (1 << back):
                    out.append(o)
                elif ot == "pipe-to-ground" and o[4] == back * 4:
                    out.append(o)
                elif ot == "storage-tank" and any(b == (nxt, own) for b in ports(o)):
                    out.append(o)
        return out

    group, n = {}, 0
    for u, r in by_unit.items():
        if u in group or types.get(r[1], "") not in ("pipe", "infinity-pipe", "pipe-to-ground", "storage-tank"):
            continue
        n += 1
        todo = [r]
        group[u] = n
        while todo:
            for o in neighbours(todo.pop()):
                if o[0] not in group:
                    group[o[0]] = n
                    todo.append(o)
    return group


def client_own_pipelines(records, c):
    """N9: client/tests/pipeline_predict.tscn (the client's pipeline_marks.gd, headless, muted) on these records:
    {unit: pipeline number}, or None without Godot."""
    import shutil
    import subprocess
    import tempfile
    godot = live_lib.GODOT or os.environ.get("GODOT") or shutil.which("godot") or shutil.which("godot4")
    if not godot:
        return None
    client = live_lib.REPO / "client"
    with tempfile.TemporaryDirectory() as tmp:
        src, dst = pathlib.Path(tmp) / "in.json", pathlib.Path(tmp) / "out.json"
        eprops = [[k] + list(v) for k, v in (c.eprops or {}).items()]
        src.write_text(json.dumps({"protos": list(c.proto_recs.values()), "eprops": eprops, "records": records}), encoding="utf-8")
        subprocess.run([godot, "--headless", "--audio-driver", "Dummy", "--path", str(client),
                        "--log-file", str(pathlib.Path(tmp) / "godot.log"), "res://tests/pipeline_predict.tscn",
                        "--", f"--in={src}", f"--out={dst}"], capture_output=True, timeout=300)
        if not dst.exists():
            return {}
        return {int(u): n for u, n in json.loads(dst.read_text(encoding="utf-8"))["groups"].items()}


def check_pipe_vis(c, hello):
    """N9: the client's pipeline visualization (pipeline_marks.gd) finds a fluid pipeline from the bridge's records alone.
    A lab layout (pipes, an underground pair, a storage tank, a pump, a boiler with pipes at both its water connections,
    and a pipe beside the line, which the game joins to it: pipes connect on every side) is built, its chunks' records
    read, and the client's rule is compared with the game's own LuaFluidBox.get_fluid_segment_id for every pipe, pipe to
    ground and tank: the rule in Python (client_pipelines), and the client's own pipeline_marks.gd run on the same
    records (tests/pipeline_predict.tscn, when Godot is found: --godot, $GODOT or godot on PATH). A pipe without a
    segment id (nil, or an error reading it) fails. Printed: whether the boiler's pass-through joins its two pipes into
    one segment (the client stops at machines)."""
    live_lib.clear_enemies()
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "pipevis: an empty spot", live_lib.SPOT_WHY)
        return
    x, y = math.floor(c.me["x"] / 256), math.floor(c.me["y"] / 256)
    # Row y+2: pipes x..x+2, a pipe to ground (open west) x+3, its partner (open east) x+8, a pipe x+9, a storage tank
    # x+10..x+12 by y+2..y+4 (its west connection at x+10, y+2), a pump x+13..x+14 on row y+4 off its east connection and
    # a pipe x+15 past the pump; a pipe at x+1, y+1 above the line (joined by the game: pipes join every side).
    # Row y+9: a boiler x+2..x+4 by y+8..y+9 facing north, a pipe at each end of its water box (x+1 and x+5, y+9).
    # (A segment id the game doesn't give is written "nil", an error reading it "x": both fail below.)
    out = live_lib.mod_lua(f"""local c = storage.f3d.puppet local s = c.surface local d = defines.direction
local made = {{}}
local function put(name, px, py, dir, extra)
  local spec = {{ name = name, position = {{ {x} + px, {y} + py }}, direction = dir or d.north, force = c.force, raise_built = true }}
  if extra then for k, v in pairs(extra) do spec[k] = v end end
  local e = s.create_entity(spec)
  if e then made[#made + 1] = e end
  return e
end
for i = 0, 2 do put('pipe', i + 0.5, 2.5) end
put('pipe-to-ground', 3.5, 2.5, d.west)
put('pipe-to-ground', 8.5, 2.5, d.east)
put('pipe', 9.5, 2.5)
put('storage-tank', 11.5, 3.5)
put('pump', 14, 4.5, d.east)
put('pipe', 15.5, 4.5)
put('pipe', 1.5, 1.5)
put('boiler', 3.5, 9, d.north)
put('pipe', 1.5, 9.5)
put('pipe', 5.5, 9.5)
storage.f3d_n9 = made
local r = {{}}
for _, e in ipairs(made) do
  local ok, id = pcall(function() return e.get_fluid_segment_id(1) end)
  r[#r + 1] = e.unit_number .. ':' .. e.name .. ':' .. tostring(ok and id or 'x')
end
rcon.print(table.concat(r, ' '))""".replace("\n", " "))
    game = {}
    names = {}
    try:
        for part in out.split():
            u, name, seg = part.split(":")
            game[int(u)] = seg
            names[int(u)] = name
    except ValueError:
        live_lib.report(False, "pipevis: the layout built, the game's segment ids read", out)
        return
    live_lib.report(len(game) == 13, "pipevis: the layout built (13 entities) and the game's segment ids read", out)
    # The chunks round the spot again, each a snapshot with the records' `pc`.
    cx, cy = x // 32, y // 32
    wanted = [[cx + dx, cy + dy] for dy in range(-1, 2) for dx in range(-1, 2)]
    c.send({"t": "sub", "c": []})
    c.send({"t": "sub", "c": wanted})
    pending = {tuple(w) for w in wanted}
    records = {}
    end = time.time() + 20
    while pending and time.time() < end:
        for m in c.pump(0.5, every=hello):
            if m.get("t") == "ents":
                for e in m["e"]:
                    if e[0]:
                        records[e[0]] = e
                if m["part"] == m["parts"]:
                    pending.discard((m["cx"], m["cy"]))
            elif m.get("t") in ("add", "upd") and m["e"][0]:
                records[m["e"][0]] = m["e"]
    types = {i: t for i, (_, t) in c.protos.items()}
    group = client_pipelines(list(records.values()), c.eprops or {}, types)
    fluid = [u for u in game if types.get(records.get(u, [0, 0])[1], "") in ("pipe", "pipe-to-ground", "storage-tank")]
    live_lib.report(not pending and all(u in records for u in game), "pipevis: every entity's record came with its chunk",
           f"pending {sorted(pending)}, missing {[names[u] for u in game if u not in records]}")
    no_id = [f"{names[u]} {u}: {game[u]}" for u in fluid if game[u] in ("nil", "x")]
    live_lib.report(not no_id, "pipevis: the game gives every pipe, pipe to ground and tank a fluid segment id", "; ".join(no_id))

    def same_game(a, b):
        return game[a] == game[b] and game[a] not in ("nil", "x")

    def compare(groups, what):
        wrong = []
        for a in fluid:
            for b in fluid:
                if a < b and same_game(a, b) != (groups.get(a) is not None and groups.get(a) == groups.get(b)):
                    wrong.append(f"{names[a]} {a} / {names[b]} {b}: game {'same' if same_game(a, b) else 'apart'}")
        live_lib.report(not wrong, f"pipevis: {what} groups every pipe, pipe to ground and tank as the game's fluid segments",
               "; ".join(wrong[:6]))
    compare(group, "the client's rule (in Python)")
    own = client_own_pipelines(list(records.values()), c)
    if own is None:
        print("  INFO N9: Godot not found (--godot, $GODOT, godot on PATH): the client's own pipeline_marks.gd not run")
    else:
        compare(own, "the client's own pipeline_marks.gd")
    boiler_pipes = [u for u in game if names[u] == "pipe"][-2:]
    if len(boiler_pipes) == 2:
        a, b = boiler_pipes
        print(f"  INFO N9: the boiler's two pipes {'share' if game[a] == game[b] else 'are apart in'} a fluid segment "
              f"(game ids {game[a]} and {game[b]}); the client {'joins' if group.get(a) == group.get(b) else 'stops at'} the boiler")
    print("  INFO N9: game segment ids:", ", ".join(f"{names[u]} {u}={game[u]}" for u in game))
    live_lib.mod_lua("for _, e in ipairs(storage.f3d_n9 or {}) do if e.valid then e.destroy() end end storage.f3d_n9 = nil")


def check_build_rules(c, hello):
    """Differential of the build cursor's rules against the game (bughunt build2): eprops' `fg` (fast_replaceable_group),
    `cb` (collision box) and `wb` (water stops it) read the way player_input.gd `_blocked` does, against
    LuaSurface.can_fast_replace / can_place_entity on a scratch lake and tree."""
    ep = {n: (((c.eprops or {}).get(c.proto_id(n)) or [None] * 4)[3:] or [{}])[0] or {} for n in (
        "pipe", "pipe-to-ground", "small-electric-pole", "medium-electric-pole", "big-electric-pole", "inserter", "fast-inserter", "long-handed-inserter",
        "wooden-chest", "steel-chest", "storage-tank", "tree-01", "transport-belt", "splitter", "underground-belt", "stone-wall", "gate",
        "assembling-machine-1", "assembling-machine-2", "steel-furnace", "electric-furnace", "burner-mining-drill", "electric-mining-drill",
        "rail-signal", "rail-chain-signal")}
    fg = lambda n: ep[n].get("fg", "")
    live_lib.report(fg("small-electric-pole") == fg("medium-electric-pole") != fg("big-electric-pole") and fg("inserter") == fg("fast-inserter") != fg("long-handed-inserter")
           and fg("wooden-chest") == fg("steel-chest") and fg("rail-signal") == fg("rail-chain-signal") != "" and fg("transport-belt") == fg("splitter") == fg("underground-belt"),
           "build rules: eprops fg groups poles (small and medium, not big), inserters (not long-handed), chests, rail signals, belts",
           str({n: fg(n) for n in ep}))
    live_lib.report(ep["tree-01"].get("cb") and ep["wooden-chest"].get("wb") == 1 and "wb" not in ep["tree-01"],
           "build rules: eprops cb for a tree (its crown is selectable, not solid) and wb for a chest (water stops it)", str((ep["tree-01"], ep["wooden-chest"])))
    # The game's answers; the rule the client applies: the same non-empty group and the same tile size (belts: any size).
    pairs = [("big-electric-pole", "small-electric-pole"), ("medium-electric-pole", "small-electric-pole"), ("small-electric-pole", "medium-electric-pole"),
             ("long-handed-inserter", "inserter"), ("fast-inserter", "inserter"), ("steel-chest", "wooden-chest"), ("stone-wall", "wooden-chest"),
             ("gate", "stone-wall"), ("assembling-machine-2", "assembling-machine-1"), ("electric-furnace", "steel-furnace"),
             ("electric-mining-drill", "burner-mining-drill"), ("burner-mining-drill", "electric-mining-drill"), ("splitter", "transport-belt"),
             ("underground-belt", "transport-belt"), ("storage-tank", "pipe"), ("pipe-to-ground", "pipe")]
    sizes = live_lib.mod_lua("local o = {} for _, n in pairs({ " + ", ".join(f'"{n}"' for p in pairs for n in p) + " }) do local p = prototypes.entity[n] "
                    "o[#o + 1] = n .. '=' .. p.tile_width .. 'x' .. p.tile_height end rcon.print(table.concat(o, ' '))")
    size = dict(kv.split("=") for kv in sizes.split())
    out = live_lib.mod_lua(
        "local s = game.surfaces.nauvis local ox, oy = 100, 100 s.request_to_generate_chunks({ ox, oy }, 3) s.force_generate_chunk_requests() "
        "local o = {} for _, p in pairs({ " + ", ".join("{ '%s', '%s' }" % pr for pr in pairs) + " }) do "
        "for _, e in pairs(s.find_entities_filtered({ area = { { ox - 10, oy - 10 }, { ox + 10, oy + 10 } } })) do if e.type ~= 'character' then e.destroy() end end "
        "local b = s.create_entity({ name = p[2], position = { ox + 0.5, oy + 0.5 }, force = 'player' }) "
        "local w = prototypes.entity[p[1]].tile_width local pos = { ox + (w % 2 == 1 and 0.5 or 0), oy + (prototypes.entity[p[1]].tile_height % 2 == 1 and 0.5 or 0) } "
        "o[#o + 1] = p[1] .. '/' .. p[2] .. '=' .. tostring(s.can_fast_replace({ name = p[1], position = pos, direction = 0, force = 'player' })) end rcon.print(table.concat(o, ' '))")
    game = dict(kv.split("=") for kv in out.split())
    bad = []
    for a, b in pairs:
        want = bool(fg(a)) and fg(a) == fg(b) and (fg(a) == "transport-belt" or size.get(a) == size.get(b))
        if str(want).lower() != game.get(f"{a}/{b}"):
            bad.append((a, b, game.get(f"{a}/{b}"), want))
    live_lib.report(not bad and len(game) == len(pairs), "build rules: the client's fast-replace rule (same fg and size; belts any) matches can_fast_replace for 16 pairs",
           str(bad) + out[:200])
    # Water and a tree: collisions are the collision box and the mask, not the selection box.
    out = live_lib.mod_lua(
        "local s = game.surfaces.nauvis local ox, oy = 100, 100 "
        "for _, e in pairs(s.find_entities_filtered({ area = { { ox - 10, oy - 10 }, { ox + 10, oy + 10 } } })) do if e.type ~= 'character' then e.destroy() end end "
        "local t = {} for x = ox - 3, ox + 3 do for y = oy - 3, oy + 3 do t[#t + 1] = { name = x >= ox + 1 and 'water' or 'grass-1', position = { x, y } } end end s.set_tiles(t) "
        "s.create_entity({ name = 'tree-01', position = { ox - 2.5, oy - 2.5 } }) "
        "local function can(n, x, y) return tostring(s.can_place_entity({ name = n, position = { x, y }, direction = 0, force = 'player', build_check_type = defines.build_check_type.manual })) end "
        "rcon.print(can('wooden-chest', ox + 1.5, oy + 0.5) .. ' ' .. can('wooden-chest', ox - 2.5, oy - 3.5) .. ' ' .. can('wooden-chest', ox - 2.5, oy - 2.5) .. ' ' .. can('wooden-chest', ox - 1.5, oy - 0.5))")
    live_lib.report(out == "false true false true", "build rules: a chest on water and on a tree is refused, a tile from the tree (inside its crown's selection box) and on grass is allowed",
           out)
    live_lib.mod_lua("local s = game.surfaces.nauvis for _, e in pairs(s.find_entities_filtered({ area = { { 90, 90 }, { 110, 110 } } })) do if e.type ~= 'character' then e.destroy() end end "
            "local t = {} for x = 97, 103 do for y = 97, 103 do t[#t + 1] = { name = 'grass-1', position = { x, y } } end end s.set_tiles(t) rcon.print('ok')")
