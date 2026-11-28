"""Differential live checks of the numbers entity windows (`gui`) and hover tooltips (`hinfo`) show, against
what the game itself does: a crafter's measured speed (`ps`) and products (`io`, with modules, a beacon and
productivity), the status name, fluid boxes, burner fuel left, the electricity numbers, a drill's progress."""
from __future__ import annotations

from . import live_lib


def check_info_diff(c, hello):
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "infodiff: no clean spot found", live_lib.SPOT_WHY)
        return
    x, y = c.me["x"] / 256, c.me["y"] / 256
    fx = lambda v: int(round(v * 256))
    lua = lambda code: live_lib.mod_lua(code.replace("\n", " "))
    out = lua(f"""
local c = storage.f3d.puppet local s = c.surface local x, y = {x}, {y}
local function put(name, dx, dy, dir)
  return s.create_entity({{ name = name, position = {{ x + dx, y + dy }}, force = c.force, direction = dir, raise_built = true }})
end
local d = {{}}
d.power = put('electric-energy-interface', 1, 4)
d.power.power_production = 2000000 d.power.power_usage = 0 d.power.electric_buffer_size = 20000000
d.pole = put('medium-electric-pole', 0.5, 0.5)
d.asm = put('assembling-machine-2', -3.5, 0.5) d.asm.set_recipe('iron-gear-wheel')
d.lab = put('lab', 0.5, -3.5)
d.beacon = put('beacon', -3.5, 4.5)
for dx = -2, 2 do for dy = -2, 2 do s.create_entity({{ name = 'iron-ore', position = {{ math.floor(x + 4.5) + 0.5 + dx, math.floor(y + 0.5) + 0.5 + dy }}, amount = 5000 }}) end end
d.drill = put('electric-mining-drill', 4.5, 0.5, defines.direction.east)
d.chest = s.create_entity({{ name = 'steel-chest', position = d.drill.drop_position, force = c.force }})
d.furnace = put('stone-furnace', -7, -7)
d.boiler = put('boiler', 6, -8)
d.engine = put('steam-engine', 6, -12, defines.direction.north)
d.tank = put('storage-tank', 10, -3)
d.pipe = put('pipe', 10, -6)
d.solar = put('solar-panel', 7, 6)
d.acc = put('accumulator', 8, 4)
local o = {{}}
for k, e in pairs(d) do o[#o + 1] = k .. '=' .. (e and e.unit_number or 'nil') .. ',' .. (e and e.position.x or 0) .. ',' .. (e and e.position.y or 0) end
rcon.print(table.concat(o, ' '))""")
    ents = {}
    for part in out.split():
        k, v = part.split("=")
        if v.startswith("nil"):
            live_lib.report(False, f"infodiff: building {k}", out)
            continue
        u, ex, ey = v.split(",")
        ents[k] = (int(float(u)), float(ex), float(ey))
    c.pump(1.0, every=hello)

    def E(k):
        return (f"(function() for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ position = {{ {ents[k][1]}, {ents[k][2]} }}, radius = 2 }})) "
                f"do if e.unit_number == {ents[k][0]} then return e end end end)()")

    def gui(k, secs=0.8):
        u, ex, ey = ents[k]
        c.send({"t": "close"})
        c.pump(0.1, every=hello)
        c.send({"t": "open", "u": u, "p": c.proto_id(lua(f"rcon.print({E(k)}.name)")), "x": fx(ex), "y": fx(ey)})
        g = [m for m in c.pump(secs, every=hello) if m.get("t") == "gui" and m.get("u") == u]
        return g[-1] if g else {}

    def hover(k, q=1):
        u, ex, ey = ents[k]
        c.send({"t": "hinfo", "q": q, "u": u, "p": 0, "x": fx(ex), "y": fx(ey)})
        h = [m for m in c.pump(0.8, every=hello) if m.get("t") == "hinfo" and m.get("q") == q]
        return h[-1] if h else {}

    def status_of(k):
        return lua(f"local e = {E(k)} for n, v in pairs(defines.entity_status) do if v == e.status then rcon.print(n) return end end rcon.print('none')")

    num = lambda s: float(s) if s not in ("", "nil") else None

    # ---- 1. A powered assembler with modules and a beacon: status, progress rate, productivity, products a second.
    lua(f"""local a = {E('asm')} a.get_module_inventory().insert({{ name = 'productivity-module', count = 2 }})
;{E('beacon')}.get_module_inventory().insert({{ name = 'speed-module', count = 2 }})
a.insert({{ name = 'iron-plate', count = 200 }}) rcon.print('ok')""")
    c.pump(2.0, every=hello)
    g = gui("asm")
    live_lib.report(g.get("status") == status_of("asm") == "working", "infodiff: a running assembler's status name",
                    f"gui {g.get('status')}, game {status_of('asm')}")
    game = lua(f"local a = {E('asm')} rcon.print(a.crafting_speed .. ' ' .. a.get_recipe().energy .. ' ' .. a.productivity_bonus)").split()
    speed, energy, pb_game = (float(v) for v in game)
    t = []
    for _ in range(5):
        t.append(tuple(num(v) for v in lua(f"rcon.print({E('asm')}.crafting_progress .. ' ' .. game.tick)").split()))
        c.pump(0.15, every=hello)
    rates = []
    for (p0, t0), (p1, t1) in zip(t, t[1:]):
        if t1 > t0:
            dp = p1 - p0
            if dp < 0:
                dp += 1
            rates.append(dp / ((t1 - t0) / 60) * 1000)
    ps = g.get("ps")
    live_lib.report(ps is not None and rates and abs(sum(rates) / len(rates) - ps) <= max(30, ps * 0.15),
                    "infodiff: the assembler's `ps` (progress a second) is the measured craft progress rate with modules and beacon",
                    f"ps {ps}, measured {[round(r) for r in rates]}, speed {speed}, energy {energy}")
    live_lib.report(g.get("pb", 0) == round(pb_game * 1000), "infodiff: the productivity bonus shown is the game's productivity_bonus",
                    f"gui pb {g.get('pb')}, game {pb_game}")

    h = hover("asm")
    lua(f"local a = {E('asm')} a.get_output_inventory().clear() rcon.print(game.tick)")
    t0 = int(lua("rcon.print(game.tick)"))
    c.pump(8.0, every=hello)
    made = int(lua(f"rcon.print({E('asm')}.get_output_inventory().get_item_count('iron-gear-wheel'))"))
    dt = (int(lua("rcon.print(game.tick)")) - t0) / 60
    io = h.get("io", {}).get("o", [])
    rate = io[0][2] / 1000 if io else None
    live_lib.report(rate is not None and abs(made / dt - rate) <= max(0.35, rate * 0.12),
                    "infodiff: the hover panel's products a second match the gears the assembler really made (speed, beacon and productivity)",
                    f"io {io}, made {made} in {dt:.1f}s = {made / dt:.2f}/s, prod {pb_game}")
    el = h.get("el")
    game_el = lua(f"local a = {E('asm')} rcon.print(a.electric_buffer_size .. ' ' .. a.electric_drain * 60)").split()
    live_lib.report(bool(el) and abs(el["b"] - float(game_el[0])) <= 1 and el["mn"] == round(float(game_el[1])) and el["mx"] >= el["mn"],
                    "infodiff: the hover electricity buffer size and min consumption (drain)", f"hinfo {el}, game {game_el}")

    # ---- 2. The status name for each state against e.status.
    cases = {}
    lua(f";{E('asm')}.clear_items_inside() rcon.print('ok')")
    c.pump(1.2, every=hello)
    cases["asm no ingredients"] = ("asm", gui("asm"), status_of("asm"))
    lua(f"local a = {E('asm')} a.insert({{ name = 'iron-plate', count = 100 }}) a.get_output_inventory().insert({{ name = 'iron-gear-wheel', count = 100 }}) rcon.print('ok')")
    c.pump(1.2, every=hello)
    cases["asm output full"] = ("asm", gui("asm"), status_of("asm"))
    lua(f"local a = {E('asm')} a.get_output_inventory().clear() a.insert({{ name = 'iron-plate', count = 100 }}) {E('power')}.power_production = 1000 rcon.print('ok')")
    c.pump(2.5, every=hello)
    cases["asm low power"] = ("asm", gui("asm"), status_of("asm"))
    lua(f"local p = {E('power')} p.power_production = 0 p.electric_buffer_size = 1 p.energy = 0 rcon.print('ok')")
    c.pump(2.5, every=hello)
    cases["asm no power"] = ("asm", gui("asm"), status_of("asm"))
    cases["lab no power"] = ("lab", gui("lab"), status_of("lab"))
    cases["drill no power"] = ("drill", gui("drill"), status_of("drill"))
    cases["furnace no ingredients"] = ("furnace", gui("furnace"), status_of("furnace"))
    lua(f"local f = {E('furnace')} f.get_fuel_inventory().insert({{ name = 'coal', count = 5 }}) f.insert({{ name = 'iron-ore', count = 5 }}) rcon.print('ok')")
    c.pump(1.5, every=hello)
    cases["furnace working"] = ("furnace", gui("furnace"), status_of("furnace"))
    lua(f"local f = {E('furnace')} f.get_fuel_inventory().clear() f.remaining_burning_fuel = 0 f.insert({{ name = 'iron-ore', count = 5 }}) rcon.print('ok')")
    c.pump(1.5, every=hello)
    cases["furnace no fuel"] = ("furnace", gui("furnace"), status_of("furnace"))
    lua(f";{E('asm')}.order_deconstruction(game.forces.player) rcon.print('ok')")
    cases["asm marked for deconstruction"] = ("asm", gui("asm"), status_of("asm"))
    lua(f";{E('asm')}.cancel_deconstruction(game.forces.player) rcon.print('ok')")
    for name, (k, g, want) in cases.items():
        live_lib.report(g.get("status") == want, f"infodiff: status of {name}: the gui's name is the game's", f"gui {g.get('status')}, game {want}")

    # ---- 3. Burner fuel left.
    lua(f"local f = {E('furnace')} f.get_fuel_inventory().insert({{ name = 'coal', count = 5 }}) f.insert({{ name = 'iron-ore', count = 50 }}) rcon.print('ok')")
    c.pump(4, every=hello)
    g = gui("furnace")
    game = lua(f"local f = {E('furnace')} rcon.print(f.burner.remaining_burning_fuel .. ' ' .. f.burner.currently_burning.name.name)").split()
    left = float(game[0]) / 4000000
    live_lib.report(g.get("bn") is not None and abs(g["bn"] / 1000 - left) < 0.15, "infodiff: burner fuel left (bn) is remaining_burning_fuel / fuel_value",
                    f"gui bn {g.get('bn')}, game {left:.3f} of {game[1]}")

    # ---- 4. A drill: mining target and progress, the resource's amount, nothing to mine.
    lua(f"local p = {E('power')} p.electric_buffer_size = 20000000 p.power_production = 2000000 rcon.print('ok')")
    c.pump(3.0, every=hello)
    g = gui("drill")
    game = lua(f"local d = {E('drill')} local t = d.mining_target rcon.print(d.mining_progress .. ' ' .. (t and t.name or 'nil') .. ' st' .. (function() for n, v in pairs(defines.entity_status) do if v == d.status then return n end end end)() .. ' res' .. #d.surface.find_entities_filtered({{ position = d.position, radius = 3, type = 'resource' }}))").split()
    if len(game) < 2:
        game = ["0", "nil"]
    live_lib.report(g.get("mt") == game[1] and g.get("mp") is not None and abs(g["mp"] / 1000 - float(game[0])) < 0.35,
                    "infodiff: a drill's mining target and progress", f"gui mt {g.get('mt')} mp {g.get('mp')}, game {game}")
    tgt = lua(f"local t = {E('drill')}.mining_target if not t then rcon.print('0 0 0') return end rcon.print(t.position.x .. ' ' .. t.position.y .. ' ' .. t.amount)").split()
    c.send({"t": "hinfo", "q": 21, "u": 0, "p": c.proto_id("iron-ore"), "x": fx(float(tgt[0])), "y": fx(float(tgt[1]))})
    h = [m for m in c.pump(0.8, every=hello) if m.get("t") == "hinfo" and m.get("q") == 21]
    live_lib.report(bool(h) and abs(h[-1].get("ra", -1) - float(tgt[2])) <= 5, "infodiff: a resource's amount shown is the game's", f"hinfo {h}, game {tgt}")
    lua("storage.f3d.puppet.force.mining_drill_productivity_bonus = 0.2 rcon.print('ok')")
    c.pump(1.5, every=hello)
    g = gui("drill")
    game = lua(f"rcon.print({E('drill')}.productivity_bonus)")
    live_lib.report(g.get("pb") == 200 and abs(float(game) - 0.2) < 0.001, "infodiff: a drill's productivity bonus includes the force's mining productivity research",
                    f"gui pb {g.get('pb')}, game {game}")
    lua("storage.f3d.puppet.force.mining_drill_productivity_bonus = 0 rcon.print('ok')")
    lua(f"for _, r in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ position = {{ {ents['drill'][1]}, {ents['drill'][2]} }}, radius = 6, type = 'resource' }})) do r.destroy() end rcon.print('ok')")
    c.pump(2, every=hello)
    g = gui("drill")
    want = status_of("drill")
    live_lib.report(g.get("status") == want == "no_minable_resources", "infodiff: a drill with nothing under it: no_minable_resources", f"gui {g.get('status')}, game {want}")

    # ---- 5. Fluids: boiler water, steam in a tank and an engine, the pipeline's contents.
    lua(f"""local b = {E('boiler')} b.get_fuel_inventory().insert({{ name = 'coal', count = 5 }}) b.insert_fluid({{ name = 'water', amount = 150 }})
;{E('tank')}.insert_fluid({{ name = 'steam', amount = 321, temperature = 250 }})
;{E('engine')}.insert_fluid({{ name = 'steam', amount = 17, temperature = 165 }}) rcon.print('ok')""")
    c.pump(2.0, every=hello)
    for k in ("boiler", "tank"):
        g = gui(k)
        want = lua(f"""local e = {E(k)} local o = {{}} for i = 1, e.fluids_count do local f = e.get_fluid(i) o[#o + 1] = (f and (f.name .. ':' .. math.floor(f.amount + 0.5) .. ':' .. math.floor(f.temperature + 0.5)) or '-') .. '/' .. math.floor(e.get_fluid_capacity(i) + 0.5) end rcon.print(table.concat(o, ' '))""")
        got = " ".join((f"{b[0]}:{b[1]}:{b[3]}" if b[0] else "-") + f"/{b[2]}" for b in g.get("fb", []))
        ok = len(got.split()) == len(want.split())
        if ok:
            for a, b in zip(got.split(), want.split()):
                (fa, ca), (fb, cb) = a.split("/"), b.split("/")
                pa, pb = fa.split(":"), fb.split(":")
                ok = ok and ca == cb and pa[0] == pb[0] and (pa[0] == "-" or (abs(int(pa[1]) - int(pb[1])) <= 40 and abs(int(pa[2]) - int(pb[2])) <= 5))
        live_lib.report(ok, f"infodiff: {k}'s fluid boxes (fluid, amount, temperature, capacity) are the game's", f"gui {got}, game {want}")
    g = gui("tank")
    gp = g.get("pl")
    want = lua(f"local e = {E('tank')} local f = e.get_fluid_segment_fluid(1) rcon.print(e.get_fluid_segment_capacity(1) .. ' ' .. (f and f.amount or 0))").split()
    live_lib.report(bool(gp) and abs(gp[2] - float(want[0])) <= 1 and abs(gp[1] - float(want[1])) <= 12,
                    "infodiff: the pipeline contents (pl) are the game's fluid segment", f"gui {gp}, game {want}")

    # ---- 6. Every other entity: the status name and the electric buffer fill.
    for k in ("acc", "boiler", "lab", "beacon", "pole"):
        g = gui(k)
        want = status_of(k)
        pw = lua(f"local e = {E(k)} local ok, s = pcall(function() return e.electric_buffer_size end) rcon.print(ok and s and s > 0 and (e.energy / s) or 'nil')")
        live_lib.report(g.get("status") == (want if want != "none" else None), f"infodiff: {k}'s status name", f"gui {g.get('status')}, game {want}")
        if pw not in ("nil", ""):
            live_lib.report(g.get("pw") is not None and abs(g["pw"] / 1000 - float(pw)) < 0.1, f"infodiff: {k}'s electric buffer fill (pw)", f"gui {g.get('pw')}, game {pw}")

    live_lib.destroy_units([u for (u, _, _) in ents.values()])
    c.send({"t": "close"})
    c.pump(0.3, every=hello)
