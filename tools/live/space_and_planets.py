"""Space Age platform, ride, space screen, collector, and planet live checks."""
from __future__ import annotations

import json
import time

import rcon

from . import live_lib


def check_platforms(c, hello):
    """Space platforms: build one (no rocket), board it, its chunks and state, its commands, back down."""
    if "space-platform-foundation" not in c.tiles:
        live_lib.report(False, "space platforms: Space Age isn't enabled on this server")
        return
    # The remote view, the modules and the map below are asked for by one session all through: once
    # (CI) a leftover biter killed the character half way, and the respawn's new session lost them.
    live_lib.clear_enemies()
    out = rcon.run("/f3d-platform new").strip()
    live_lib.report("built in orbit of" in out, "/f3d-platform new: force.create_space_platform + apply_starter_pack", out)
    try:
        index = int(out.split("platform ")[1].split(" ")[0])
    except (IndexError, ValueError):
        return
    is_mine = lambda m: m.get("t") == "plat" and any(p["i"] == index for p in m["l"])
    plats = [m for m in c.pump(3, every=hello, until=is_mine) if is_mine(m)]
    rec = next((p for p in plats[-1]["l"] if p["i"] == index), {}) if plats else {}
    live_lib.report(rec.get("hub", 0) > 0 and rec.get("loc") == "nauvis" and plats[-1].get("on") == 0 and plats[-1].get("here") == "nauvis",
           "plat: the new platform, its hub and where it is", f"{rec} here={plats[-1].get('here') if plats else None}")

    # #5: the remote view looks at the platform from Nauvis: its world streams while the character
    # stays put; building waits; si 0 brings Nauvis back.
    psi = int(live_lib.mod_lua(f'rcon.print(game.forces.player.platforms[{index}].surface.index)') or 0)
    c.send({"t": "view", "si": psi, "x": 0, "y": 0})
    msgs = c.pump(live_lib.SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "surface")
    vs = live_lib.of_type(msgs, "surface")
    c.send({"t": "sub", "c": [[0, 0], [-1, -1], [-1, 0], [0, -1]]})
    # #12: building from the remote view puts a ghost on that surface. A new platform's foundation
    # lies under its hub, so a patch of foundation east of it first. F6: what is chosen must be
    # buildable on a platform: a chest needs gravity (2.1.23), so an assembler.
    spot = live_lib.mod_lua(f'local s = game.get_surface({psi}) local t = {{}} for x = 6, 11 do for y = -6, 2 do '
                   't[#t + 1] = { name = "space-platform-foundation", position = { x, y } } end end '
                   's.set_tiles(t) rcon.print("8,0")') or ""
    gx, gy = (int(v) for v in spot.split(",")) if "," in spot else (8, 0)
    c.send({"t": "build", "item": "assembling-machine-2", "x": gx * 256 + 128, "y": gy * 256 + 128, "d": 0})
    c.send({"t": "mine", "u": 0, "p": 0, "x": gx * 256 + 128, "y": gy * 256 + 128})
    msgs = c.pump(3, every=hello)
    vtiles = {tid for m in live_lib.of_type(msgs, "chunk") if m.get("tiles") for tid in m["tiles"][0::2]}
    live_lib.report(bool(vs) and vs[0].get("view") == 1 and vs[0].get("pf") == index and c.tiles["space-platform-foundation"] in vtiles
           and live_lib.mod_lua("rcon.print(storage.f3d.puppet.surface.name)") == "nauvis",
           "view: the platform's chunks stream for the remote view while the character stays on Nauvis (#5)", f"{vs[:1]} tiles {sorted(vtiles)}")
    ghost = json.loads(live_lib.mod_lua(f'local s = game.get_surface({psi}) local g = s.find_entities_filtered{{ghost_name = "assembling-machine-2", '
                               f'position = {{{gx} + 0.5, {gy} + 0.5}}}}[1] rcon.print(helpers.table_to_json(g and {{ g.unit_number }} or {{}}))') or "[]")
    live_lib.report(len(ghost) == 1, "view: building from the remote view places a ghost on the platform (#12)", f"{spot!r} {ghost!r}")
    live_lib.report(any("another surface" in m.get("text", "") for m in live_lib.of_type(msgs, "msg")),
           "view: mining by hand waits while another surface is shown")
    # F6: the platform is uncharted on a headless server, so the mod's fallback check must still
    # refuse what Factorio would: a ghost over empty space, and one the platform's gravity forbids.
    c.send({"t": "build", "item": "assembling-machine-2", "x": 20 * 256 + 128, "y": 128, "d": 0})
    c.send({"t": "build", "item": "wooden-chest", "x": 6 * 256 + 128, "y": -5 * 256 + 128, "d": 0})
    msgs = c.pump(1.5, every=hello)
    said = [m["text"] for m in live_lib.of_type(msgs, "msg")]
    stray = live_lib.mod_lua(f'local s = game.get_surface({psi}) local n = 0 for _, g in pairs(s.find_entities_filtered{{type = "entity-ghost"}}) do '
                    'if g.ghost_name == "wooden-chest" or g.position.x > 15 then n = n + 1 g.destroy() end end rcon.print(n)')
    live_lib.report(stray == "0" and "Can't place that there" in said and any("gravity" in t for t in said),
           "view: no ghost over empty space, nor a chest the platform's gravity forbids (F6)", f"{stray} stray ghosts; {said}")
    # F6: modules from the remote view, Factorio's way: a ghost's insert plan, a building's item
    # request proxy (both without a player).
    if ghost:
        at = {"u": ghost[0], "p": c.proto_id("entity-ghost"), "x": gx * 256 + 128, "y": gy * 256 + 128}
        for _ in range(3):
            c.send({"t": "modreq", "item": "speed-module", **at})
        msgs = c.pump(1.5, every=hello)
        plan = live_lib.mod_lua(f'local s = game.get_surface({psi}) local g = s.find_entities_filtered{{ghost_name = "assembling-machine-2"}}[1] '
                       'local t = {} for _, p in pairs(g and g.insert_plan or {}) do for _, at in pairs(p.items.in_inventory or {}) do '
                       't[#t + 1] = p.id.name .. "@" .. at.inventory .. ":" .. at.stack end end table.sort(t) '
                       'rcon.print(table.concat(t, " ") .. " | " .. serpent.line(g and g.item_requests or {}))')
        said = [m["text"] for m in live_lib.of_type(msgs, "msg")]
        live_lib.report(plan.startswith("speed-module@4:0 speed-module@4:1 |") and "The module slots are full" in said,
               "modreq: modules asked for on a ghost from the remote view go in its insert plan, one per slot (F6)", f"{plan}; {said}")
    built = json.loads(live_lib.mod_lua(f'local s = game.get_surface({psi}) local e = s.create_entity{{name = "assembling-machine-2", '
                               'position = {8.5, -3.5}, force = "player"} rcon.print(helpers.table_to_json(e and { e.unit_number } or {}))') or "[]")
    if built:
        at = {"u": built[0], "p": c.proto_id("assembling-machine-2"), "x": 8 * 256 + 128, "y": -3 * 256 - 128}
        c.send({"t": "modreq", "item": "productivity-module", **at})
        c.pump(1.0, every=hello)
        proxy = live_lib.mod_lua(f'local s = game.get_surface({psi}) local e = s.find_entity("assembling-machine-2", {{8.5, -3.5}}) '
                        'local p = e and e.item_request_proxy rcon.print(p and serpent.line(p.item_requests) or "none")')
        live_lib.report("productivity-module" in proxy, "modreq: a building on the platform gets an item request proxy (F6)", proxy)
        c.send({"t": "modreq", "clr": 1, **at})
        c.pump(1.0, every=hello)
        proxy = live_lib.mod_lua(f'local s = game.get_surface({psi}) local e = s.find_entity("assembling-machine-2", {{8.5, -3.5}}) '
                        'rcon.print(e and e.item_request_proxy and "still" or "gone")')
        live_lib.report(proxy == "gone", "modreq clr: the request is taken back (the proxy goes)", proxy)
    # F6: the platform's map past its generated chunks charts as unknown instead of stopping the map.
    c.send({"t": "map", "cx1": 30, "cy1": 30, "cx2": 31, "cy2": 30, "res": 8, "si": psi})
    msgs = c.pump(2, every=hello)
    charts = [m for m in live_lib.of_type(msgs, "chart") if m.get("si") == psi]
    live_lib.report(charts and all(m["n"] == 0 for m in charts) and not any("Map error" in m["text"] for m in live_lib.of_type(msgs, "msg")),
           "map: a platform's ungenerated chunks chart as unknown, no Map error (F6)", f"{[(m['cx'], m['cy'], m['n']) for m in charts]}")
    live_lib.mod_lua(f'local s = game.get_surface({psi}) for _, e in pairs(s.find_entities_filtered{{name = {{"assembling-machine-2", "entity-ghost"}}}}) do e.destroy() end')
    c.send({"t": "view", "si": 0})
    msgs = c.pump(live_lib.SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "surface")
    vs = live_lib.of_type(msgs, "surface")
    live_lib.report(bool(vs) and vs[0].get("planet") == "nauvis" and "view" not in vs[0], "view 0: back to the character's surface", str(vs[:1]))
    c.pump(0.5, every=hello)

    c.send({"t": "plat_board", "i": index})
    msgs = c.pump(live_lib.SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "surface")
    surf = live_lib.of_type(msgs, "surface")
    live_lib.report(bool(surf) and surf[0].get("pf") == index and "planet" not in surf[0] and not live_lib.of_type(msgs, "welcome"),
           "plat_board: the character crosses to the platform (teleport to another surface), and `surface` says so",
           f"{surf[:1]} {[m['text'] for m in live_lib.of_type(msgs, 'msg')][-2:]}")
    if not surf:
        # Back on Nauvis whatever happened, so the checks after this don't all fail from the platform.
        rcon.run("/f3d-platform leave nauvis")
        c.pump(live_lib.SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "surface")
        return
    x, y = surf[0]["x"] / 256, surf[0]["y"] / 256
    cx, cy = int(x // 32), int(y // 32)
    wanted = [[cx + dx, cy + dy] for dy in range(-1, 2) for dx in range(-1, 2)]
    c.send({"t": "sub", "c": wanted})
    c.send({"t": "focus", "x": int(x * 256), "y": int(y * 256), "r": 48})
    msgs = c.pump(8, every=hello, until=lambda m: m.get("t") == "ents" and [m["cx"], m["cy"]] == wanted[-1] and m["part"] == m["parts"])
    tile_ids = {tid for m in live_lib.of_type(msgs, "chunk") if m.get("tiles") for tid in m["tiles"][0::2]}
    want_tiles = {c.tiles["space-platform-foundation"], c.tiles["empty-space"]}
    hubs = [e for m in live_lib.of_type(msgs, "ents") for e in m["e"] if e[1] == c.proto_id("space-platform-hub")]
    live_lib.report(want_tiles <= tile_ids and len(hubs) == 1 and hubs[0][0] == rec.get("hub"),
           "the platform's chunks: foundation in empty space, and the hub", f"tiles {sorted(tile_ids)}, hubs {hubs}")
    start = c.me["x"] if c.me else 0
    c.pump(1.0, every=(0.15, {"t": "walk", "d": 4}))
    c.send({"t": "walk", "d": -1})
    live_lib.report(c.me is not None and c.me["x"] != start, "the character walks on the platform", f"moved {(c.me['x'] - start) / 256:.2f} tiles")

    c.send({"t": "plat_sched", "i": index, "l": ["nauvis"], "c": 1})
    c.send({"t": "plat_pause", "i": index, "p": 0})
    msgs = c.pump(2.5, every=hello)
    # The last `plat`: each command answers with one at once, so the first is plat_sched's, sent
    # before plat_pause has been handled.
    rec = next((p for m in reversed(live_lib.of_type(msgs, "plat")) for p in m["l"] if p["i"] == index), {})
    live_lib.report(rec.get("sch") == {"c": 1, "l": ["nauvis"]} and rec.get("pa") == 0 and live_lib.of_type(msgs, "plat")[-1].get("on") == index,
           "plat_sched and plat_pause 0: the schedule and pause flag (LuaSpacePlatform.schedule, paused)", str(rec))
    live_lib.report(isinstance(rec.get("w"), int) and rec["w"] > 0, "plat: the platform's mass for the remote view (LuaSpacePlatform.weight, kg)",
           str(rec.get("w")))
    live_lib.report("nx" not in rec, "plat: a schedule of only where it is has no next stop", str(rec))
    # H7: waiting at its stop with another next, the panel shows where it goes (nx).
    live_lib.mod_lua(f'local p = game.forces.player.platforms[{index}] '
            'p.schedule = {current = 1, records = {{station = "nauvis", wait_conditions = {{type = "time", compare_type = "or", '
            'ticks = 36000}}}, {station = "vulcanus"}}}')
    msgs = c.pump(2.5, every=hello)
    rec = next((p for m in live_lib.of_type(msgs, "plat") for p in m["l"] if p["i"] == index), {})
    live_lib.report(rec.get("loc") == "nauvis" and rec.get("nx") == "vulcanus", "plat waiting at a stop: the next stop (H7)", str(rec))
    live_lib.mod_lua(f'local p = game.forces.player.platforms[{index}] p.schedule = {{current = 1, records = {{{{station = "nauvis"}}}}}}')
    unlocked = live_lib.of_type(msgs, "plat")[-1].get("dest", []) if live_lib.of_type(msgs, "plat") else []
    if "vulcanus" not in unlocked:
        c.send({"t": "plat_go", "i": index, "to": "vulcanus"})
        msgs = c.pump(1.0, every=hello)
        live_lib.report(any(m["text"] == "Can't travel to vulcanus" for m in live_lib.of_type(msgs, "msg")), "plat_go refuses a location not unlocked yet")
    # Travelling, set by script (the starter platform has no thrusters to get anywhere).
    live_lib.mod_lua(f'local p = game.forces.player.platforms[{index}] '
            'p.space_connection = prototypes.space_connection["nauvis-vulcanus"] p.distance = 0.25 p.speed = 1')
    msgs = c.pump(2.5, every=hello)
    rec = next((p for m in live_lib.of_type(msgs, "plat") for p in m["l"] if p["i"] == index), {})
    # Its schedule (plat_sched above) goes to nauvis, the connection's from end: it heads back (G9).
    live_lib.report(rec.get("from") == "vulcanus" and rec.get("to") == "nauvis" and 700 < rec.get("d", 0) < 800 and rec.get("len") == 15000
           and "loc" not in rec, "plat while travelling: from, to, how far, the connection's length, speed", str(rec))
    # Owner's G9: sent to the connection's from end, 2.1.23 counts distance down; plat turns it round.
    live_lib.mod_lua(f'local p = game.forces.player.platforms[{index}] p.distance = 0.4 p.speed = 1 p.paused = false '
            'p.schedule = {current = 1, records = {{station = "nauvis", wait_conditions = {}, temporary = true}}}')
    msgs = c.pump(2.5, every=hello)
    recs = [p for m in live_lib.of_type(msgs, "plat") for p in m["l"] if p["i"] == index and "to" in p]
    live_lib.report(len(recs) >= 2 and recs[-1].get("from") == "vulcanus" and recs[-1].get("to") == "nauvis" and recs[-1]["d"] > recs[0]["d"] >= 600,
           "plat heading back along its connection: from where it left, d counting up (G9)", str(recs[:1] + recs[-1:]))
    c.send({"t": "plat_board", "i": 0})
    msgs = c.pump(1.0, every=hello)
    live_lib.report(any("stopped at a planet" in m["text"] for m in live_lib.of_type(msgs, "msg")) and not live_lib.of_type(msgs, "surface"),
           "plat_board 0 while travelling is refused")
    live_lib.mod_lua(f'local p = game.forces.player.platforms[{index}] p.space_location = "nauvis" p.paused = true')
    c.send({"t": "plat_board", "i": 0})
    msgs = c.pump(live_lib.SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "surface")
    surf = live_lib.of_type(msgs, "surface")
    live_lib.report(bool(surf) and surf[0].get("planet") == "nauvis" and "pf" not in surf[0],
           "plat_board 0: back down to the planet the platform is stopped at", str(surf[:1]))
    out = live_lib.mod_lua(f"""local p = game.forces.player.platforms[{index}] p.destroy() rcon.print(p.scheduled_for_deletion)""")
    print("     platform scheduled for deletion in", out, "ticks")
    c.pump(1.0, every=hello)  # the checks after this one sleep; keep the session fresh


def check_ride(c, hello):
    """Riding to a platform as a player does (#10, #17): into a silo's rocket with `ride`
    (launch_rocket with the character), up to the platform's hub, life in the hub (no walking,
    ghosts, the hub's screen), and down again by cargo pod with `land`. Prints the pod's states
    and when each began."""
    if "space-platform-foundation" not in c.tiles:
        live_lib.report(False, "ride: Space Age isn't enabled on this server")
        return
    # Earlier sections leave biters about (the shooting and enemies checks); one that keeps
    # biting the character kills it during the ride and every section after fails.
    live_lib.clear_enemies()
    out = rcon.run("/f3d-platform new").strip()
    try:
        index = int(out.split("platform ")[1].split(" ")[0])
    except (IndexError, ValueError):
        live_lib.report(False, "ride: /f3d-platform new", out)
        return
    hub_u = int(live_lib.mod_lua(f"rcon.print(game.forces.player.platforms[{index}].hub.unit_number)") or 0)
    if not (live_lib.clean_spot(c, hello, 16) or live_lib.clean_spot(c, hello, 12)):
        live_lib.report(False, "ride: no clean spot for a silo", live_lib.SPOT_WHY)
        return
    px, py = c.me["x"] / 256, c.me["y"] / 256
    out = live_lib.mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface
local silo = s.create_entity({{ name = "rocket-silo", position = {{ {px + 6.5}, {py + 0.5} }}, force = c.force, raise_built = true }})
local eei = s.create_entity({{ name = "electric-energy-interface", position = {{ {px - 4}, {py + 6} }}, force = c.force }})
eei.power_production = 1e9 eei.electric_buffer_size = 1e10
local sub = s.create_entity({{ name = "substation", position = {{ {px - 1}, {py + 6} }}, force = c.force }})
local sub2 = s.create_entity({{ name = "substation", position = {{ {px + 8}, {py + 6} }}, force = c.force }})
silo.rocket_parts = silo.prototype.rocket_parts_required
rcon.print(silo.unit_number .. " " .. silo.position.x .. " " .. silo.position.y .. " " .. eei.unit_number .. " " .. sub.unit_number .. " " .. sub2.unit_number)
""".replace("\n", " "))
    try:
        silo_u, sx, sy, *power = out.split()
        silo_u, sx, sy = int(silo_u), float(sx), float(sy)
    except ValueError:
        live_lib.report(False, "ride: building a powered rocket silo", out)
        return
    made = [silo_u] + [int(u) for u in power]
    status = ("local n = {} for k, v in pairs(defines.rocket_silo_status) do n[v] = k end "
              f"for _, e in pairs(game.surfaces.nauvis.find_entities_filtered({{ name = 'rocket-silo', position = {{ {sx}, {sy} }} }})) do "
              "rcon.print(n[e.rocket_silo_status]) end")
    ready, end = "", time.time() + 60
    while time.time() < end and ready != "rocket_ready":
        c.pump(1.0, every=hello)
        ready = live_lib.mod_lua(status)
    live_lib.report(ready == "rocket_ready", "ride: a rocket stands ready in the silo", ready)
    c.send({"t": "open", "u": silo_u, "p": c.proto_id("rocket-silo"), "x": int(sx * 256), "y": int(sy * 256)})
    c.pump(1.0, every=hello)
    c.send({"t": "ride", "u": silo_u, "to": index})

    def ride(seconds, done):
        """Follows `me` until done(me); returns [(seconds, me), ...] and the messages."""
        t0, log = time.time(), []

        def watch(m):
            if m.get("t") == "me":
                log.append((time.time() - t0, m))
                return done(m)
            return False
        return log, c.pump(seconds, every=hello, until=watch)

    def phases(log):
        out, last = [], None
        for t, m in log:
            ps = m.get("ps", "hub" if "hub" in m else "-")
            if ps != last:
                out.append((round(t, 1), ps, m.get("up")))
                last = ps
        return out

    log, msgs = ride(75, lambda m: "hub" in m)
    up = [m for _, m in log if "pod" in m and m.get("up") == 1]
    surf = live_lib.of_type(msgs, "surface")
    print("     ride up:", phases(log))
    live_lib.report(up and (up[0]["gx"], up[0]["gy"]) == (int(sx * 256), int(sy * 256)) and up[0]["ps"] == "awaiting_launch",
           "ride: the character is in the rocket's cargo pod, seen from the silo (me.pod, up 1)", str(up[:1]))
    climb = [(m["gy"] - m["y"]) / 256 for m in up if m.get("ps") == "ascending"]
    live_lib.report(len(climb) > 10 and climb[-1] > 100, "ride: the pod climbs (its y runs north of the silo)", f"{climb[:1]} .. {climb[-1:]} tiles")
    live_lib.report(bool(surf) and surf[0].get("pf") == index, "ride: the pod changes surface to the platform (`surface`)", str(surf[:1]))
    live_lib.report(log and log[-1][1].get("hub") == hub_u and "pod" not in log[-1][1],
           "ride: the pod docks and the character is inside the platform's hub (me.hub)", str(log[-1:])[:300])
    if not (log and "hub" in log[-1][1]):
        live_lib.destroy_units(made)
        return
    hx, hy = log[-1][1]["x"], log[-1][1]["y"]
    c.send({"t": "sub", "c": [[-1, -1], [0, -1], [-1, 0], [0, 0]]})
    c.send({"t": "focus", "x": hx, "y": hy, "r": 48})
    c.pump(2.0, every=(0.15, {"t": "walk", "d": 4}))
    c.send({"t": "walk", "d": -1})
    c.send({"t": "mine", "u": 0, "p": 0, "x": hx + 3 * 256, "y": hy})
    live_lib.mod_lua('storage.f3d.puppet.insert({ name = "pipe", count = 1 })')
    # The starter pack's foundation is all under the hub but a ring a tile wide: lay a little more.
    spot = live_lib.mod_lua("local s = storage.f3d.puppet.surface local tiles = {} for x = 6, 8 do for y = -1, 1 do "
                   "tiles[#tiles + 1] = { name = 'space-platform-foundation', position = { x, y } } end end s.set_tiles(tiles) "
                   "for _, t in pairs(s.find_tiles_filtered{ name = 'space-platform-foundation' }) do "
                   "local x, y = t.position.x, t.position.y if s.can_place_entity{ name = 'pipe', position = { x + 0.5, y + 0.5 }, force = 'player' } then "
                   "rcon.print(x .. ',' .. y) return end end") or ""
    gx, gy = (int(v) for v in spot.split(",")) if "," in spot else (6, 0)
    c.send({"t": "build", "item": "pipe", "x": gx * 256 + 128, "y": gy * 256 + 128, "d": 0})
    msgs = c.pump(1.5, every=hello)
    ghost = live_lib.mod_lua(f"local g = storage.f3d.puppet.surface.find_entities_filtered{{ ghost_name = 'pipe', position = {{ {gx} + 0.5, {gy} + 0.5 }} }}[1] "
                    "rcon.print(g and 'ghost' or 'none') if g then g.destroy() end")
    live_lib.report(c.me and (c.me["x"], c.me["y"]) == (hx, hy) and "hub" in c.me and ghost == "ghost"
           and any(m.get("text") == "Not from inside the hub" for m in live_lib.of_type(msgs, "msg")),
           "in the hub: no walking or mining, building places a ghost (#17)", f"{ghost} {[m.get('text') for m in live_lib.of_type(msgs, 'msg')]}")
    c.send({"t": "open", "u": hub_u, "p": c.proto_id("space-platform-hub"), "x": hx, "y": hy})
    msgs = c.pump(2, every=hello, until=lambda m: m.get("t") == "gui" and m.get("u") == hub_u)
    g = [m for m in live_lib.of_type(msgs, "gui") if m.get("u") == hub_u]
    live_lib.report(g and g[-1].get("kind") == "hub", "in the hub: the hub's own screen opens", str([m.get("text") for m in live_lib.of_type(msgs, "msg")]))
    c.send({"t": "close"})

    c.send({"t": "land"})
    log, msgs = ride(60, lambda m: "pod" not in m and "hub" not in m)
    print("     ride down:", phases(log))
    pods = [m for _, m in log if "pod" in m]
    surf = live_lib.of_type(msgs, "surface")
    texts = [m.get("text") for m in live_lib.of_type(msgs, "msg")]
    leave = [m for m in pods if m.get("up") == 1]
    down = [m for m in pods if m.get("up") == 0]
    live_lib.report(any(t and "in a cargo pod" in t for t in texts) and leave and (leave[0]["gx"], leave[0]["gy"]) == (hx, hy),
           "land: out of the hub into a cargo pod, seen from the hub (up 1)", f"{texts} {leave[:1]}")
    live_lib.report(bool(surf) and surf[0].get("planet") == "nauvis" and down and down[-1]["ps"] == "descending",
           "land: the pod changes surface to Nauvis and comes down (up 0)", f"{surf[:1]} {down[-1:]}")
    # Factorio gives it no height: it comes in from the north (and from the side: the client ignores
    # that, drawing it straight above the spot), and the client draws what is left of its way south as height.
    falling = [m for m in down if m.get("ps") == "descending"]
    spots = [r[4:6] for m in live_lib.of_type(msgs, "cp") for r in m["l"] if r[1] == "descending" and len(r) == 6]
    print("     falling:", [(m["x"] / 256, m["y"] / 256) for m in falling[::max(1, len(falling) // 6)]], "spots:", spots[-1:])
    live_lib.report(len(falling) > 5 and all(b["y"] >= a["y"] for a, b in zip(falling, falling[1:])),
           "land: a falling pod only ever travels south (the client's height)", str(falling[:1] + falling[-1:]))
    live_lib.report(bool(spots) and abs(spots[-1][0] - falling[-1]["x"]) < 4 * 256 and abs(spots[-1][1] - falling[-1]["y"]) < 4 * 256,
           "land: `cp` says where it lands, where it comes down", f"{spots[-1:]} {falling[-1:]}")
    fin = log[-1][1] if log else {}
    live_lib.report(down and fin and "pod" not in fin and abs(fin["x"] - down[-1]["gx"]) < 4 * 256 and abs(fin["y"] - down[-1]["gy"]) < 4 * 256,
           "land: the character stands on Nauvis where the pod came down", f"{fin} {down[-1:]}")
    live_lib.destroy_units(made)
    live_lib.mod_lua(f"game.forces.player.platforms[{index}].destroy(1)")


def check_space(c, hello):
    """Space Age's screens (space.lua) against the real game: the space map, a rocket silo built,
    powered and launched (a new platform's starter pack, then to its hub), the hub's schedule,
    interrupts and requests from planets, asteroid chunks, what can't be built on a platform, an
    asteroid collector's filters, a landing pad's circuit settings, module effects, recipe quality
    and the quality of belt items."""
    if "space-platform-foundation" not in c.tiles:
        live_lib.report(False, "space: Space Age isn't enabled on this server")
        return
    made, built, extra_platform = [], "", 0

    def open_screen(unit, name, x, y, kind):
        c.send({"t": "open", "u": unit, "p": c.proto_id(name), "x": int(x * 256), "y": int(y * 256)})
        msgs = c.pump(3, every=hello, until=lambda m: m.get("t") == "gui" and m.get("u") == unit)
        g = [m for m in live_lib.of_type(msgs, "gui") if m.get("u") == unit]
        live_lib.report(bool(g) and g[-1].get("kind") == kind, f"open a {name}: gui kind {kind}", str(g[-1] if g else live_lib.of_type(msgs, "msg")[-2:])[:300])
        return g[-1] if g else {}

    def screen_after(unit, seconds=1.2):
        msgs = c.pump(seconds, every=hello)
        g = [m for m in live_lib.of_type(msgs, "gui") if m.get("u") == unit]
        return g[-1] if g else {}, msgs

    # --- the solar system ------------------------------------------------------------------------
    c.send({"t": "smap"})
    msgs = c.pump(2, every=hello, until=lambda m: m.get("t") == "smap")
    sm = live_lib.of_type(msgs, "smap")
    locs = {r[0]: r for r in sm[0]["loc"]} if sm else {}
    live_lib.report(bool(sm) and "nauvis" in locs and locs["nauvis"][4] == 1 and any(0 < r[3] <= 1000 for r in sm[0]["con"]),
           "smap: space locations (prototype positions) and connections with asteroid danger",
           f"{len(locs)} locations, {len(sm[0]['con']) if sm else 0} connections, nauvis {locs.get('nauvis')}")
    live_lib.report(len(locs.get("vulcanus", [])) == 9 and locs["vulcanus"][6] == 1500 and locs.get("shattered-planet", [0] * 9)[7] == 0,
           "smap: how the star map draws each place (magnitude, draw_orbit, label_orientation)",
           f"vulcanus {locs.get('vulcanus')}, shattered planet {locs.get('shattered-planet')}")

    # --- a rocket silo, powered, and its launches ----------------------------------------------
    if not (live_lib.clean_spot(c, hello, 16) or live_lib.clean_spot(c, hello, 12)):
        live_lib.report(False, "space: no clean spot for a silo", live_lib.SPOT_WHY + " on " + live_lib.mod_lua("rcon.print(storage.f3d.puppet.surface.name)"))
        return
    px, py = c.me["x"] / 256, c.me["y"] / 256
    out = live_lib.mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface
local silo = s.create_entity({{ name = "rocket-silo", position = {{ {px + 6.5}, {py + 0.5} }}, force = c.force, raise_built = true }})
local eei = s.create_entity({{ name = "electric-energy-interface", position = {{ {px - 4}, {py + 6} }}, force = c.force }})
eei.power_production = 1e9 eei.electric_buffer_size = 1e10
local sub = s.create_entity({{ name = "substation", position = {{ {px - 1}, {py + 6} }}, force = c.force }})
local sub2 = s.create_entity({{ name = "substation", position = {{ {px + 8}, {py + 6} }}, force = c.force }})
silo.rocket_parts = silo.prototype.rocket_parts_required
rcon.print(silo.unit_number .. " " .. silo.position.x .. " " .. silo.position.y .. " " .. eei.unit_number .. " " .. sub.unit_number .. " " .. sub2.unit_number)
""".replace("\n", " "))
    try:
        silo_u, sx, sy, *power = out.split()
        silo_u, sx, sy = int(silo_u), float(sx), float(sy)
        made += [silo_u] + [int(u) for u in power]
    except ValueError:
        live_lib.report(False, "space: building a powered rocket silo", out)
        return
    g = open_screen(silo_u, "rocket-silo", sx, sy, "silo")
    rk = g.get("rk", {})
    # No platform in orbit: Factorio's table_to_json writes the empty list as {}.
    live_lib.report(isinstance(rk.get("st"), str) and rk.get("auto") in (0, 1) and (isinstance(rk.get("to"), list) or rk.get("to") == {}),
           "the silo's screen: rocket_silo_status, send_to_orbit_automatically, platforms to launch to", str(rk))
    c.send({"t": "set_silo", "u": silo_u, "auto": 1})
    c.pump(0.5, every=hello)
    live_lib.report(live_lib.mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'rocket-silo', position = {{ {sx}, {sy} }} }})) do "
                   "rcon.print(tostring(e.send_to_orbit_automatically)) e.send_to_orbit_automatically = false end") == "true",
           "set_silo: send to orbit automatically")

    # A new platform waits for its starter pack; the silo launches it up.
    live_lib.mod_lua('storage.f3d.puppet.insert({ name = "space-platform-starter-pack", count = 1 })')
    c.send({"t": "plat_new"})
    msgs = c.pump(2, every=hello)
    texts = [m["text"] for m in live_lib.of_type(msgs, "msg")]
    out = live_lib.mod_lua("local best for _, p in pairs(game.forces.player.platforms) do if p.valid and not p.hub then best = p end end "
                  "rcon.print(best and (best.index .. ' ' .. best.state .. ' ' .. (best.space_location and best.space_location.name or '?')) or 'none')")
    live_lib.report(out != "none" and any(t.startswith("New platform") for t in texts), "plat_new: a platform over the planet waiting for its starter pack",
           f"{out} | {texts[-1:]}")
    new_index = int(out.split()[0]) if out != "none" else 0
    if new_index:
        made_platform = new_index
        ready = ""
        end = time.time() + 40
        while time.time() < end:
            ready = live_lib.mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'rocket-silo', position = {{ {sx}, {sy} }} }})) do "
                            "local names = {} for k, v in pairs(defines.rocket_silo_status) do names[v] = k end rcon.print(names[e.rocket_silo_status]) end")
            if ready == "rocket_ready":
                break
            c.pump(1.0, every=hello)
        live_lib.report(ready == "rocket_ready", "a powered silo with its parts builds a rocket (rocket_silo_status)", ready)
        if ready == "rocket_ready":
            out = live_lib.mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'rocket-silo', position = {{ {sx}, {sy} }} }})) do "
                          "local inv = e.get_inventory(defines.inventory.rocket_silo_rocket) "
                          "rcon.print(inv and inv.insert({ name = 'space-platform-starter-pack', count = 1 }) or 'no rocket inventory') end")
            live_lib.report(out == "1", "the starter pack goes into the rocket (rocket_silo_rocket)", out)
            early = c.pump(0.2, every=hello)
            # The game launches a rocket carrying a waiting platform's starter pack by itself.
            msgs = early + c.pump(4, every=hello, until=lambda m: m.get("t") == "rk")
            rk_msgs = live_lib.of_type(msgs, "rk")
            state = live_lib.mod_lua(f"local n = {{}} for k, v in pairs(defines.space_platform_state) do n[v] = k end "
                            f"rcon.print(n[game.forces.player.platforms[{new_index}].state])")
            live_lib.report(bool(rk_msgs) and rk_msgs[0]["u"] == silo_u and state != "waiting_for_starter_pack",
                   "the rocket carrying the starter pack goes up by itself (rk), and the pack is on its way", f"rk {rk_msgs[:1]}, {state}")
            built = ""
            end = time.time() + 60
            while time.time() < end:
                built = live_lib.mod_lua(f"local p = game.forces.player.platforms[{new_index}] rcon.print(tostring(p.hub ~= nil and p.hub.valid))")
                if built == "true":
                    break
                c.pump(1.0, every=hello)
            live_lib.report(built == "true", "the starter pack arrives: the platform has its hub", built)
            if built == "true":
                live_lib.mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'rocket-silo', position = {{ {sx}, {sy} }} }})) do "
                        "e.rocket_parts = e.prototype.rocket_parts_required end")
                ready = ""
                end = time.time() + 60
                while time.time() < end:
                    ready = live_lib.mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'rocket-silo', position = {{ {sx}, {sy} }} }})) do "
                                    "local names = {} for k, v in pairs(defines.rocket_silo_status) do names[v] = k end rcon.print(names[e.rocket_silo_status]) end")
                    if ready == "rocket_ready":
                        break
                    c.pump(1.0, every=hello)
                live_lib.mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'rocket-silo', position = {{ {sx}, {sy} }} }})) do "
                        "e.get_inventory(defines.inventory.rocket_silo_rocket).insert({ name = 'iron-plate', count = 50 }) end")
                g, _ = screen_after(silo_u)
                rocket_slots = g.get("slots", {}).get("rocket") if isinstance(g.get("slots"), dict) else None
                live_lib.report(ready == "rocket_ready" and isinstance(rocket_slots, list) and ["iron-plate", 50] in rocket_slots
                       and any(t[0] == new_index for t in g.get("rk", {}).get("to", [])),
                       "a second rocket: the silo shows its cargo and the platform to launch to", f"{ready} {str(rocket_slots)[:60]} {g.get('rk')}")
                c.send({"t": "silo_launch", "u": silo_u, "to": new_index})
                msgs = c.pump(4, every=hello, until=lambda m: m.get("t") == "rk")
                rk_msgs = live_lib.of_type(msgs, "rk")
                live_lib.report(bool(rk_msgs) and rk_msgs[0]["u"] == silo_u, "silo_launch: launch_rocket to the platform's hub (rk)",
                       f"{rk_msgs[:1]} {[m['text'] for m in live_lib.of_type(msgs, 'msg')][-2:]}")
                msgs = c.pump(6, every=hello)
                pods = [r for m in live_lib.of_type(msgs, "cp") for r in m["l"]]
                live_lib.report(bool(pods), "cp: the rocket's cargo pod near the silo", str(pods[:2]))
    else:
        made_platform = 0

    # --- the hub's screen ------------------------------------------------------------------------
    index = made_platform if made_platform and built == "true" else 0
    if not index:
        out = rcon.run("/f3d-platform new").strip()
        try:
            index = extra_platform = int(out.split("platform ")[1].split(" ")[0])
        except (IndexError, ValueError):
            live_lib.report(False, "space: no platform for the hub checks", out)
            live_lib.destroy_units(made)
            return
    c.send({"t": "close"})
    c.send({"t": "plat_board", "i": index})
    msgs = c.pump(live_lib.SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "surface")
    surf = live_lib.of_type(msgs, "surface")
    if not surf:
        live_lib.report(False, "space: boarding the platform", str(live_lib.of_type(msgs, "msg")[-2:]))
        live_lib.destroy_units(made)
        return
    planet = [m for m in c.pump(1.5, every=hello) if m.get("t") == "planet"]
    x, y = surf[0]["x"] / 256, surf[0]["y"] / 256
    cx, cy = int(x // 32), int(y // 32)
    c.send({"t": "sub", "c": [[cx + dx, cy + dy] for dy in range(-1, 2) for dx in range(-1, 2)]})
    c.send({"t": "focus", "x": int(x * 256), "y": int(y * 256), "r": 48})
    c.pump(2, every=hello)
    hub = live_lib.mod_lua(f"local h = game.forces.player.platforms[{index}].hub rcon.print(h.unit_number .. ' ' .. h.position.x .. ' ' .. h.position.y)").split()
    hub_u, hx, hy = int(hub[0]), float(hub[1]), float(hub[2])
    g = open_screen(hub_u, "space-platform-hub", hx, hy, "hub")
    h = g.get("hub", {})
    live_lib.report(h.get("i") == index and isinstance(h.get("w"), int) and h.get("w", 0) > 0 and isinstance(h.get("th"), list)
           and isinstance(h.get("sec"), list) and "chest" in g.get("slots", {}),
           "the hub's screen: the platform, weight, thrusters, requests, inventory (hub_main)",
           f"{ {k: h.get(k) for k in ('i', 'st', 'w', 'th', 'fuel', 'prov', 'loc')} } trash={'trash' in g.get('slots', {})}")
    c.send({"t": "set_section", "u": hub_u, "i": 0, "f": [["iron-plate", "normal", 100, 400, "nauvis", 50]]})
    c.send({"t": "set_hub", "u": hub_u, "prov": 1})
    waits = [{"type": "all_requests_satisfied", "compare_type": "and"}, {"type": "time", "compare_type": "or", "ticks": 1800}]
    c.send({"t": "set_schedule", "u": hub_u, "records": [{"station": "nauvis", "wait_conditions": waits}, {"station": "nowhere"}]})
    c.send({"t": "set_interrupts", "u": hub_u, "interrupts": [
        {"name": "f3d live", "conditions": [{"type": "any_request_zero", "compare_type": "and"}], "targets": [{"station": "nauvis"}]}]})
    g, msgs = screen_after(hub_u, 1.5)
    h = g.get("hub", {})
    out = live_lib.mod_lua(f"local p = game.forces.player.platforms[{index}] for _, sec in pairs(p.hub.get_logistic_sections().sections) do "
                  "for _, f in pairs(sec.filters) do if f.value and f.value.name == 'iron-plate' then "
                  "rcon.print(f.value.name .. ' ' .. f.min .. ' ' .. tostring(f.max) .. ' ' .. tostring(f.import_from and f.import_from.name) "
                  ".. ' ' .. tostring(f.minimum_delivery_count)) end end end")
    live_lib.report(out == "iron-plate 100 400 nauvis 50", "set_section: a request from a planet (import_from, minimum_delivery_count) on the hub", out)
    live_lib.report(any(s.get("f") == [["iron-plate", "normal", 100, 400, "nauvis", 50]] for s in h.get("sec", [])),
           "and gui.hub.sec shows it", str(h.get("sec")))
    live_lib.report(h.get("prov") == 1, "set_hub: providing_to_other_platforms", str(h.get("prov")))
    sched = h.get("sched", {})
    out = live_lib.mod_lua(f"local s = game.forces.player.platforms[{index}].get_schedule() local r = s.get_records() "
                  "rcon.print(#r .. ' ' .. r[1].station .. ' ' .. #r[1].wait_conditions .. ' ' .. #s.get_interrupts())")
    live_lib.report(out == "1 nauvis 2 1" and [r["station"] for r in sched.get("records", [])] == ["nauvis"]
           and sched.get("interrupts", [{}])[0].get("name") == "f3d live",
           "the platform's schedule and interrupts from the hub (LuaSchedule records, wait conditions)", f"{out} | {sched}")
    errors = [m["text"] for m in live_lib.of_type(msgs, "msg") if "Can't" in m["text"]]
    live_lib.report(not errors, "no command was refused", str(errors))

    # Asteroid chunks near the focus, and an asteroid collector's filters.
    live_lib.mod_lua(f"game.forces.player.platforms[{index}].create_asteroid_chunks({{ {{ name = 'metallic-asteroid-chunk', "
            f"position = {{ {x + 6}, {y - 3} }}, movement = {{ 0, 0.02 }} }} }})")
    msgs = c.pump(1.0, every=hello)
    ach = [r for m in live_lib.of_type(msgs, "ach") for r in m["l"] if r[0] == "metallic-asteroid-chunk"]
    live_lib.report(bool(ach), "ach: asteroid chunks drifting over the platform (find_asteroid_chunks_filtered)", str(ach[:3]))
    out = live_lib.mod_lua(f"local c = storage.f3d.puppet local e = c.surface.create_entity({{ name = 'asteroid-collector', position = {{ {x + 5}, {y + 4} }}, "
                  "force = c.force, raise_built = true }) rcon.print(e and (e.unit_number .. ' ' .. e.position.x .. ' ' .. e.position.y) or 'none')")
    if out != "none":
        col_u, colx, coly = int(out.split()[0]), float(out.split()[1]), float(out.split()[2])
        made.append(col_u)
        g = open_screen(col_u, "asteroid-collector", colx, coly, "collector")
        c.send({"t": "set_collector", "u": col_u, "f": ["carbonic-asteroid-chunk"]})
        g, _ = screen_after(col_u)
        got = live_lib.mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'asteroid-collector', position = {{ {colx}, {coly} }} }})) do "
                      "local f = e.get_filter(1) rcon.print(f and (f.name or f) or 'nil') end")
        live_lib.report(got == "carbonic-asteroid-chunk" and (g.get("col", {}).get("f") or [""])[0] == "carbonic-asteroid-chunk",
               "set_collector: the chunk filter (set_filter with an asteroid chunk)", f"{got} {g.get('col')}")
    else:
        live_lib.report(False, "an asteroid collector on the platform", out)

    # What can't be built here (planet.nb) and the refusal.
    nb = planet[-1].get("nb", []) if planet else []
    live_lib.report(bool(nb), "planet.nb on a platform: entities its surface conditions forbid", f"{len(nb)} entities, e.g. {nb[:3]}")
    if nb:
        name = next((n for i, (n, _) in c.protos.items() if i == nb[0][0]), "")
        item = live_lib.mod_lua(f"local p = prototypes.entity['{name}'] local it = p.items_to_place_this and p.items_to_place_this[1] "
                       "if it then storage.f3d.puppet.insert({ name = it.name, count = 1 }) rcon.print(it.name) else rcon.print('') end")
        if item:
            c.send({"t": "build", "item": item, "x": int((x + 2.5) * 256), "y": int((y + 3.5) * 256), "d": 0})
            msgs = c.pump(1.0, every=hello)
            texts = [m["text"] for m in live_lib.of_type(msgs, "msg")]
            live_lib.report(any(t.startswith("Can't build here:") for t in texts), f"building {name} on a platform says why it can't", str(texts[-2:]))
    c.send({"t": "close"})
    c.send({"t": "plat_board", "i": 0})
    c.pump(live_lib.SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "surface")
    c.pump(1.0, every=hello)

    # --- a landing pad, module effects, recipe quality, belt item quality (back on the planet) ----
    if live_lib.clean_spot(c, hello, 14):
        px, py = c.me["x"] / 256, c.me["y"] / 256
        out = live_lib.mod_lua(f"""
local c = storage.f3d.puppet local s = c.surface
local pad = s.create_entity({{ name = "cargo-landing-pad", position = {{ {px + 6}, {py} }}, force = c.force, raise_built = true }})
local asm = s.create_entity({{ name = "assembling-machine-2", position = {{ {px - 5.5}, {py + 0.5} }}, force = c.force, raise_built = true }})
asm.get_module_inventory().insert({{ name = "speed-module", count = 1 }})
local belt = s.create_entity({{ name = "transport-belt", position = {{ {px + 0.5}, {py + 4.5} }}, force = c.force, direction = defines.direction.east }})
belt.get_transport_line(1).insert_at(0.5, {{ name = "iron-plate", count = 1, quality = "rare" }})
rcon.print((pad and (pad.unit_number .. " " .. pad.position.x .. " " .. pad.position.y) or "none none none") .. " " .. asm.unit_number .. " " .. asm.position.x .. " " .. asm.position.y .. " " .. belt.unit_number)
""".replace("\n", " "))
        parts = out.split()
        if len(parts) == 7:
            if parts[0] != "none":
                pad_u, padx, pady = int(parts[0]), float(parts[1]), float(parts[2])
                made.append(pad_u)
                g = open_screen(pad_u, "cargo-landing-pad", padx, pady, "pad")
                live_lib.report(isinstance(g.get("pad", {}).get("sec"), list) and "chest" in g.get("slots", {}),
                       "the landing pad's screen: requests and inventory (cargo_landing_pad_main)", str(g.get("pad")))
                c.send({"t": "set_pad", "u": pad_u, "req": 1, "read": 0})
                g, _ = screen_after(pad_u)
                got = live_lib.mod_lua(f"for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = 'cargo-landing-pad', position = {{ {padx}, {pady} }} }})) do "
                              "local cb = e.get_control_behavior() rcon.print(tostring(cb.set_requests) .. ' ' .. tostring(cb.read_contents)) end")
                live_lib.report(got == "true false" and g.get("pad", {}).get("cb", {}).get("req") == 1,
                       "set_pad: the landing pad's circuit settings (LuaCargoLandingPadControlBehavior)", f"{got} {g.get('pad', {}).get('cb')}")
            else:
                print("     (no landing pad: this surface already has its one)")
            asm_u, ax, ay = int(parts[3]), float(parts[4]), float(parts[5])
            made += [asm_u, int(parts[6])]
            g = open_screen(asm_u, "assembling-machine-2", ax, ay, "crafter")
            live_lib.report(g.get("eff", {}).get("sp", 0) > 0, "a machine's module effects (LuaEntity.effects)", str(g.get("eff")))
            unlocked = live_lib.mod_lua("rcon.print(tostring(game.forces.player.is_quality_unlocked('uncommon')))")
            c.send({"t": "set_recipe", "u": asm_u, "recipe": "iron-gear-wheel", "q": "uncommon"})
            g, msgs = screen_after(asm_u)
            if unlocked == "true":
                live_lib.report(g.get("rq") == "uncommon" and "uncommon" in g.get("ql", []), "set_recipe with a quality (set_recipe(name, quality))", str(g.get("rq")))
            else:
                live_lib.report(any(m["text"] == "That quality isn't researched" for m in live_lib.of_type(msgs, "msg")),
                       "set_recipe refuses a quality not researched (is_quality_unlocked)", str([m["text"] for m in live_lib.of_type(msgs, "msg")][-2:]))
            c.send({"t": "close"})
            msgs = c.pump(1.0, every=hello)
            bq = [r for m in live_lib.of_type(msgs, "bq") for r in m["l"]]
            live_lib.report(any(r[1] == "rare" for r in bq), "bq: a rare plate riding a belt", str(bq[:3]))
        else:
            live_lib.report(False, "space: building the pad, machine and belt", out)
    live_lib.destroy_units(made)
    for p in (made_platform, extra_platform):
        if p:
            live_lib.mod_lua(f"game.forces.player.platforms[{p}].destroy()")
    c.pump(1.0, every=hello)


def check_collectors(c, hello):
    """Asteroid collectors' arms (`acol`, F3): a collector on a new platform's edge, powered, its
    filter set to promethium so the orbit's own chunks don't count; a still promethium chunk 6
    tiles in front is caught (`g`) where it was and lands in the output; without power the arms fold home (G10)."""
    out = rcon.run("/f3d-platform new").strip()
    try:
        index = int(out.split("platform ")[1].split(" ")[0])
    except (IndexError, ValueError):
        live_lib.report(False, "collectors: /f3d-platform new", out)
        return
    c.send({"t": "plat_board", "i": index})
    msgs = c.pump(live_lib.SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "surface")
    if not live_lib.of_type(msgs, "surface"):
        live_lib.report(False, "collectors: boarding the platform", str(live_lib.of_type(msgs, "msg")[-2:]))
        return
    # A strip of foundation north of the hub, the collector on its edge facing out, a pole and an
    # electric energy interface to power it.
    out = live_lib.mod_lua(f"local s = game.forces.player.platforms[{index}].surface local f = game.forces.player local t = {{}} "
                  "for x = -12, 11 do for y = -16, -6 do t[#t + 1] = { name = 'space-platform-foundation', position = { x, y } } end end "
                  "s.set_tiles(t) local col = s.create_entity({ name = 'asteroid-collector', position = { -10.5, -15.5 }, direction = defines.direction.north, force = f }) "
                  "s.create_entity({ name = 'medium-electric-pole', position = { -8.5, -14.5 }, force = f }) "
                  "s.create_entity({ name = 'electric-energy-interface', position = { -6, -13 }, force = f }) "
                  "col.set_filter(1, 'promethium-asteroid-chunk') rcon.print(col.unit_number)")
    if not out.isdigit():
        live_lib.report(False, "collectors: a collector on the platform's edge", out)
        return
    col_u = int(out)
    c.send({"t": "focus", "x": int(-10.5 * 256), "y": int(-15.5 * 256), "r": 48})
    msgs = c.pump(1.5, every=hello)
    rows = [r for m in live_lib.of_type(msgs, "acol") for r in m.get("l", []) if r[0] == col_u]
    live_lib.report(bool(rows) and rows[-1][1] == 1 and rows[-1][2] == 200 and rows[-1][3] == 1 and rows[-1][4] == ["promethium-asteroid-chunk"],
           "acol: a collector's arms (1), arm speed (0.2 tiles a tick), moving while powered, its filter", str(rows[-1:]))
    live_lib.mod_lua(f"game.forces.player.platforms[{index}].create_asteroid_chunks({{ {{ name = 'promethium-asteroid-chunk', "
            "position = { -10.5, -21.5 }, movement = { 0, 0 } } })")
    msgs = c.pump(2.0, every=hello)
    grabs = [g for m in live_lib.of_type(msgs, "acol") for g in m.get("g", []) if g[0] == col_u]
    near = [g for g in grabs if g[1] == "promethium-asteroid-chunk" and abs(g[2] / 256 + 10.5) < 0.3 and abs(g[3] / 256 + 21.5) < 0.3]
    got = live_lib.mod_lua(f"rcon.print(game.forces.player.platforms[{index}].surface.find_entities_filtered({{ name = 'asteroid-collector' }})[1]"
                  ".get_inventory(defines.inventory.chest).get_item_count('promethium-asteroid-chunk'))")
    live_lib.report(len(near) == 1 and got == "1", "acol g: the chunk the collector caught, once, where it was, and it reached the output",
           f"{grabs} output {got}")
    # The orbit's own chunks (carbonic, metallic...) the filter leaves alone are never counted as caught.
    live_lib.report(all(g[1] == "promethium-asteroid-chunk" for g in grabs), "acol g: no chunk counted that the filter leaves alone", str(grabs))
    live_lib.mod_lua(f"for _, e in pairs(game.forces.player.platforms[{index}].surface.find_entities_filtered({{ name = 'electric-energy-interface' }})) do e.destroy() end")
    msgs = c.pump(2.5, every=hello)
    rows = [r for m in live_lib.of_type(msgs, "acol") for r in m.get("l", []) if r[0] == col_u]
    live_lib.report(bool(rows) and rows[-1][3] == 2, "acol: without power the arms fold home (2, G10)", str(rows[-1:]))
    c.send({"t": "plat_board", "i": 0})
    msgs = c.pump(live_lib.SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "surface")
    msgs += c.pump(1.0, every=hello)  # the clear comes on the next 10-tick look, after `surface`
    cleared = [m for m in msgs if m.get("t") == "acol" and m.get("l") in ([], {})]
    live_lib.report(bool(cleared), "acol: an empty list once the client's world leaves the platform", str(live_lib.of_type(msgs, "acol")[-1:]))
    live_lib.mod_lua(f"game.forces.player.platforms[{index}].destroy()")
    c.pump(1.0, every=hello)


def check_planets(c, hello):
    """The other planets (Space Age): on each, the planet data and its own streams; then landing
    from a platform in a cargo pod. Everything made is destroyed and the character goes home."""
    if "lava" not in c.tiles:
        live_lib.report(False, "planets: Space Age isn't enabled on this server")
        return
    home = live_lib.mod_lua("local p = storage.f3d.puppet.position rcon.print(p.x .. ' ' .. p.y)").split()
    live_lib.mod_lua("storage.f3d_live_planets = {}")

    def lua(code):
        return live_lib.mod_lua(code.replace("\n", " "))

    def visit(planet):
        """Teleports the character to the planet's surface; returns its position, or None."""
        lua(f"""local c = storage.f3d.puppet local pl = game.planets["{planet}"] local s = pl.surface or pl.create_surface()
s.request_to_generate_chunks({{0, 0}}, 2) s.force_generate_chunk_requests()
local p = s.find_non_colliding_position("character", {{0, 0}}, 64, 0.5) or {{x = 0, y = 0}}
c.teleport(p, s)""")
        msgs = c.pump(live_lib.SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "planet" and m.get("name") == planet)
        planet_msg = live_lib.of_type(msgs, "planet")
        surf = live_lib.of_type(msgs, "surface")
        live_lib.report(bool(planet_msg) and planet_msg[-1]["name"] == planet and "gravity" in planet_msg[-1].get("props", {})
               and planet_msg[-1].get("day", 0) > 0,
               f"{planet}: `planet` on arriving (surface.planet, get_property, ticks_per_day)", str(planet_msg[-1:])[:300])
        if not surf:
            return None
        x, y = surf[-1]["x"] / 256, surf[-1]["y"] / 256
        c.send({"t": "focus", "x": int(x * 256), "y": int(y * 256), "r": 48})
        return x, y

    def make(spec, keep=True):
        """Lua that creates an entity on the character's surface as `e` (kept for cleanup)."""
        return (f"local c = storage.f3d.puppet local s = c.surface local e = s.create_entity({spec}) "
                + ("if e then table.insert(storage.f3d_live_planets, e) end " if keep else ""))

    # Vulcanus: a demolisher, created stretched out (create_segmented_unit), seen as `seg`.
    at = visit("vulcanus")
    if at:
        x, y = at
        out = lua(f"""local s = storage.f3d.puppet.surface
local u = s.create_segmented_unit({{ name = "small-demolisher", position = {{ {x + 36}, {y} }}, extended = true }})
rcon.print(u and u.unit_number or 0)""")
        unit = int(out) if out.isdigit() else 0
        seg = [r for m in live_lib.of_type(c.pump(1.0, every=hello), "seg") for r in m["l"] if r[0] == unit]
        live_lib.report(unit > 0 and bool(seg) and len(seg[-1][2]) >= 8, "vulcanus: a demolisher's segments in `seg` (get_segmented_units, segments)",
               f"unit {out}, {str(seg[-1:])[:300]}")
        lua(f"for _, u in pairs(storage.f3d.puppet.surface.get_segmented_units()) do if u.unit_number == {unit} then u.destroy() end end")

    # Fulgora: a lightning rod and two strikes (execute_lightning), one on the rod, one away from it.
    # Fulgora's ruins are lightning attractors too (one stands by the spawn) and pull in strikes
    # 20 tiles off, so this happens on land where none is within 40 tiles of either strike. The
    # bolt's entity stands in the sky, so a strike on the ground is placed only within 15 tiles
    # in x and 3 in y.
    at = visit("fulgora")
    if at:
        out = lua("""local c = storage.f3d.puppet local s = c.surface
s.request_to_generate_chunks({0, 0}, 5) s.force_generate_chunk_requests()
local function clear(x, y) return s.count_entities_filtered({ position = { x, y }, radius = 40, type = "lightning-attractor" }) == 0 end
local best
for gx = -144, 144, 8 do for gy = -144, 144, 8 do
  local d = gx * gx + gy * gy
  if (not best or d < best.d) and clear(gx, gy) and clear(gx - 30, gy - 26)
      and s.can_place_entity({ name = "lightning-rod", position = { gx + 0.5, gy + 0.5 }, force = c.force }) then
    best = { d = d, x = gx + 0.5, y = gy + 0.5 }
  end
end end
if best then
  c.teleport({ best.x - 2, best.y })
  local e = s.create_entity({ name = "lightning-rod", position = { best.x, best.y }, force = c.force })
  if e then table.insert(storage.f3d_live_planets, e) end
  rcon.print(c.position.x .. " " .. c.position.y .. " " .. (e and (e.position.x .. " " .. e.position.y) or ""))
end""")
        parts = [float(v) for v in out.split()]
        if len(parts) == 4:
            x, y, rx, ry = parts
            c.send({"t": "focus", "x": int(x * 256), "y": int(y * 256), "r": 48})
            c.pump(0.5, every=hello)
            sx, sy = rx - 30, ry - 26
            lua(f'local s = storage.f3d.puppet.surface s.execute_lightning({{ name = "lightning", position = {{ {rx}, {ry} }} }}) '
                f's.execute_lightning({{ name = "lightning", position = {{ {sx}, {sy} }} }})')
            lt = [r for m in live_lib.of_type(c.pump(1.5, every=hello), "lt") for r in m["l"]]
            caught = [r for r in lt if r[2] == 1 and r[:2] == [round(rx * 256), round(ry * 256)]]
            ground = [r for r in lt if r[2] == 0 and abs(r[0] / 256 - sx) <= 15.5 and abs(r[1] / 256 - sy) <= 3.5]
            live_lib.report(caught and ground, "fulgora: lightning strikes in `lt`, one caught by the rod (on it), one on the ground below its bolt",
                   f"rod at {rx}, {ry}, stray at {sx}, {sy}: {lt}")
        else:
            live_lib.report(False, "fulgora: lightning strikes in `lt`, one caught by the rod", f"no spot without lightning attractors near: {out}")

    # Gleba: a half-grown yumako tree, a spawner, a pentapod (kept still), spoiling fruit in the
    # inventory and an agricultural tower's screen.
    at = visit("gleba")
    if at:
        x, y = at
        out = lua(make(f'{{ name = "yumako-tree", position = {{ {x + 4}, {y + 4} }} }}')
                  + "if e then e.tick_grown = game.tick + math.floor(e.prototype.growth_ticks / 2) end "
                  + make(f'{{ name = "gleba-spawner", position = {{ {x + 28}, {y} }}, force = "enemy" }}')
                  + make(f'{{ name = "small-stomper-pentapod", position = {{ {x + 18}, {y + 18} }}, force = "enemy" }}')
                  + "if e then e.disabled_by_script = true end "
                  + make(f'{{ name = "agricultural-tower", position = {{ {x - 6}, {y + 6} }}, force = c.force }}')
                  + 'c.insert({ name = "yumako", count = 10 }) rcon.print(e and (e.unit_number .. " " .. e.position.x .. " " .. e.position.y) or "none")')
        msgs = c.pump(2.5, every=hello)
        pg = [v for m in live_lib.of_type(msgs, "pg") for v in m["l"]]
        live_lib.report(any(300 <= pg[i + 3] <= 700 for i in range(0, len(pg), 4)), "gleba: a half-grown plant in `pg` (tick_grown, growth_ticks)", str(pg[:12]))
        live_lib.report(any(m["l"] for m in live_lib.of_type(msgs, "sp")), "gleba: the spawner in `sp` (units)", str(live_lib.of_type(msgs, "sp")[-1:])[:200])
        live_lib.report(any(len(r[1]) == 10 for m in live_lib.of_type(msgs, "legs") for r in m["l"]),
               "gleba: the pentapod's five feet in `legs` (its spider-leg entities)", str(live_lib.of_type(msgs, "legs")[-1:])[:200])
        slots = live_lib.of_type(msgs, "slots")
        fruit = [s for m in slots for s in m["l"].get("main", []) if isinstance(s, list) and s[0] == "yumako"]
        live_lib.report(bool(fruit) and len(fruit[-1]) == 4, "gleba: spoiling fruit carries its freshness in `slots` (spoil_percent)", str(fruit[-1:]))
        parts = out.split()
        if len(parts) == 3:
            c.send({"t": "open", "u": int(parts[0]), "p": c.proto_id("agricultural-tower"),
                    "x": round(float(parts[1]) * 256), "y": round(float(parts[2]) * 256)})
            g = [m for m in c.pump(0.6, every=hello) if m.get("t") == "gui" and m.get("u") == int(parts[0])]
            live_lib.report(bool(g) and isinstance(g[-1].get("ag"), dict), "gleba: an agricultural tower's screen counts its plants (owned_plants)", str(g[-1:])[:300])
            c.send({"t": "close"})
        else:
            live_lib.report(False, "gleba: making the plant, spawner, pentapod and tower", out)
        lua('storage.f3d.puppet.remove_item({ name = "yumako", count = 10 })')

    # Aquilo: an inserter out of any heat (frozen, as entity.frozen says) and a heat pipe's temperature.
    at = visit("aquilo")
    if at:
        x, y = at
        out = lua(make(f'{{ name = "inserter", position = {{ {x + 3}, {y + 3} }}, force = c.force }}')
                  + "local ins = e "
                  + make(f'{{ name = "heat-pipe", position = {{ {x + 5}, {y + 3} }}, force = c.force }}')
                  + "if e then e.temperature = 300 end rcon.print(ins and (ins.unit_number .. ' ' .. tostring(ins.frozen)) or 'none')")
        msgs = c.pump(2.5, every=hello)
        fz = [v for m in live_lib.of_type(msgs, "fz") for v in m["l"]]
        parts = out.split()
        if len(parts) == 2:
            frozen_now = live_lib.mod_lua(f"for _, e in pairs(storage.f3d_live_planets) do if e.valid and e.unit_number == {parts[0]} then rcon.print(tostring(e.frozen)) end end")
            live_lib.report((int(parts[0]) in fz) == (frozen_now == "true"), "aquilo: `fz` agrees with entity.frozen", f"frozen {frozen_now}, fz {fz}")
        heat = [v for m in live_lib.of_type(msgs, "ht") for v in m["l"]]
        live_lib.report(300 in heat[1::2] or any(abs(v - 300) < 30 for v in heat[1::2]), "aquilo: a heat pipe's temperature in `ht`", str(heat[:10]))

    # Home, then down from a platform the way a player goes (`land`, a cargo pod).
    lua("for _, e in pairs(storage.f3d_live_planets or {}) do if e.valid then e.destroy() end end storage.f3d_live_planets = nil")
    if len(home) == 2:
        lua(f'storage.f3d.puppet.teleport({{ {home[0]}, {home[1]} }}, game.surfaces.nauvis)')
        c.pump(live_lib.SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "surface")
    out = rcon.run("/f3d-platform new").strip()
    try:
        index = int(out.split("platform ")[1].split(" ")[0])
    except (IndexError, ValueError):
        live_lib.report(False, "land: build a platform to land from", out)
        return
    c.send({"t": "plat_board", "i": index})
    c.pump(live_lib.SURFACE_WAIT, every=hello, until=lambda m: m.get("t") == "surface")
    c.send({"t": "land"})
    msgs = c.pump(15, every=hello, until=lambda m: m.get("t") == "surface" and m.get("planet") == "nauvis")
    texts = [m["text"] for m in live_lib.of_type(msgs, "msg")]
    surf = [m for m in live_lib.of_type(msgs, "surface") if m.get("planet") == "nauvis"]
    by_pod = any("in a cargo pod" in t for t in texts)
    live_lib.report(bool(surf), "land: the character gets down to the planet", f"{texts}; surface {surf[:1]}")
    print(f"     land went {'by cargo pod' if by_pod else 'by the direct move'}: {texts}; cargo pods seen: {[r for m in live_lib.of_type(msgs, 'cp') for r in m['l']][:3]}")
    live_lib.mod_lua(f"game.forces.player.platforms[{index}].destroy()")
    c.pump(1.0, every=hello)
