"""Full-run inline live checks extracted from live_check.py main()."""
from __future__ import annotations

import socket
import sys
import time

import protocol
import rcon

from . import (
    building_and_planners,
    combat_and_enemies,
    live_lib,
    machines_and_vehicles,
    player_and_ui,
    space_and_planets,
    world_and_multi,
)


def run_handshake_and_world(c):
    """Run the full-run handshake, chunks, walking, building, belts, combat, vehicles, and machine screens."""
    # --- handshake and chunks ------------------------------------------------------------------
    msgs = c.pump(6, until=lambda m: m.get("t") == "ready", every=(1.0, {"t": "hello", "v": 1, "sid": c.sid, "w": 0}))
    early = list(msgs)
    welcome = live_lib.of_type(msgs, "welcome")
    live_lib.report(bool(welcome) and bool(live_lib.of_type(msgs, "ready")), "handshake: welcome, prototypes, ready",
           f"{len(c.protos)} entity prototypes, multiplayer={welcome[0].get('mp') if welcome else '?'}")
    if not welcome:
        sys.exit(1)
    c.send({"t": "hello", "v": 1, "sid": c.sid, "w": 1})
    msgs = c.pump(1.0)
    early += msgs
    x, y = welcome[0]["x"] / 256, welcome[0]["y"] / 256
    cx, cy = int(x // 32), int(y // 32)
    wanted = [[cx + dx, cy + dy] for dy in range(-2, 3) for dx in range(-2, 3)]
    c.send({"t": "sub", "c": wanted})
    c.send({"t": "focus", "x": int(x * 256), "y": int(y * 256), "r": 48})
    hello = (1.0, {"t": "hello", "v": 1, "sid": c.sid, "w": 1})
    msgs = c.pump(15, every=hello, until=lambda m: m.get("t") == "ents" and [m["cx"], m["cy"]] == wanted[-1] and m["part"] == m["parts"])
    chunks = {(m["cx"], m["cy"]) for m in live_lib.of_type(msgs, "chunk")}
    ents = [e for m in live_lib.of_type(msgs, "ents") for e in m["e"]]
    live_lib.report(len(chunks) == len(wanted), "every subscribed chunk arrives", f"{len(chunks)}/{len(wanted)} chunks, {len(ents)} entities")
    quals = live_lib.of_type(early + msgs, "quals")
    live_lib.report(bool(quals) and quals[-1]["l"][0][:3] == ["normal", 0, 1],
           "quals: the qualities by level, normal unlocked (prototypes.quality, is_quality_unlocked)", str(quals[-1:])[:300])
    live_lib.report(not c.invalid, "every message passes tools/protocol.py", str(c.invalid[:3]))
    welcome_bin = c.last.get("welcome", {}).get("bin")
    if live_lib.BINARY:
        live_lib.report(welcome_bin == protocol.WIRE_VERSION and c.binary_datagrams > 0 and "mv" in c.last,
               "--binary: the welcome says bin, datagrams come as binary frames, movers among them",
               f"bin {welcome_bin}, {c.binary_datagrams} of {c.datagrams} datagrams binary")
    else:
        live_lib.report(welcome_bin is None and c.binary_datagrams == 0, "without bin in the hello: JSON text only",
               f"bin {welcome_bin}, {c.binary_datagrams} binary datagrams")

    # --- decoratives --------------------------------------------------------------------------------
    world_and_multi.check_decoratives(c, hello, x, y, wanted)

    # --- Factorio's world controls and entity windows (early, while there is room to build) -----
    player_and_ui.check_ui_parity(c, hello)
    player_and_ui.check_input(c, hello)
    building_and_planners.check_planners(c, hello)
    machines_and_vehicles.check_circuits(c, hello)

    # --- walking -------------------------------------------------------------------------------
    c.pump(0.5, every=hello)
    start = (c.me["x"], c.me["y"])
    c.pump(1.5, every=(0.15, {"t": "walk", "d": 4}))
    moved = (c.me["x"] - start[0]) / 256
    live_lib.report(moved > 3 and c.me["w"] == 1, "a player-less character walks east while walk is repeated", f"moved {moved:.2f} tiles")
    c.send({"t": "walk", "d": -1})
    c.pump(0.4, every=hello)
    stop_x = c.me["x"]
    c.pump(1.0, every=hello)
    live_lib.report(c.me["x"] == stop_x and c.me["w"] == 0, "walk -1 stops it", f"drift {(c.me['x'] - stop_x) / 256:.2f} tiles")
    player_and_ui.check_walk(c, hello)
    player_and_ui.check_pickup(c, hello)

    # --- building and rotating -----------------------------------------------------------------
    # Start from a clean, watched spot (check_walk ends on its own, so this is usually that one).
    if not live_lib.clean_spot(c, hello):
        live_lib.report(False, "build: no clean spot found", live_lib.SPOT_WHY)
    # The starter kit is freeplay's, which has no chests or inserters.
    live_lib.mod_lua('storage.f3d.puppet.insert({name = "wooden-chest", count = 5}) storage.f3d.puppet.insert({name = "inserter", count = 5})')
    c.pump(1.0, every=hello)
    px, py = c.me["x"] / 256, c.me["y"] / 256
    chest_before = c.inv.get("wooden-chest", 0)
    bx, by = int((px + 3) * 256), int(py * 256)
    c.send({"t": "build", "item": "wooden-chest", "x": bx, "y": by, "d": 0})
    # Up to 3 s: a slow runner (CI) can still be reading what was sent before the build.
    msgs = c.pump(3.0, every=hello, until=lambda m: m.get("t") == "add" and m["e"][1] == c.proto_id("wooden-chest"))
    adds = [m["e"] for m in live_lib.of_type(msgs, "add") if m["e"][1] == c.proto_id("wooden-chest")]
    live_lib.report(bool(adds), "build: create_entity{raise_built=true} sends add via script_raised_built",
           "; ".join(m["text"] for m in live_lib.of_type(msgs, "msg")))
    c.pump(1.0, every=hello)
    live_lib.report(c.inv.get("wooden-chest", 0) == chest_before - 1, "build takes the item from the inventory",
           f"{chest_before} -> {c.inv.get('wooden-chest', 0)}")

    c.send({"t": "build", "item": "inserter", "x": bx, "y": by + 2 * 256, "d": 0})
    msgs = c.pump(3.0, every=hello, until=lambda m: m.get("t") == "add" and m["e"][1] == c.proto_id("inserter"))
    ins = [m["e"] for m in live_lib.of_type(msgs, "add") if m["e"][1] == c.proto_id("inserter")]
    if ins:
        e = ins[0]
        c.send({"t": "rotate", "u": e[0], "p": e[1], "x": e[2], "y": e[3]})
        msgs = c.pump(3.0, every=hello, until=lambda m: m.get("t") == "upd" and m["e"][0] == e[0] and m["e"][4] == 4)
        upd = [m["e"] for m in live_lib.of_type(msgs, "upd") if m["e"][0] == e[0]]
        live_lib.report(bool(upd) and upd[-1][4] == 4, "rotate turns the inserter east and sends upd", str(upd[-1:]))
    else:
        live_lib.report(False, "build an inserter to rotate", "; ".join(m["text"] for m in live_lib.of_type(msgs, "msg")))

    # --- mining --------------------------------------------------------------------------------
    if adds:
        e = adds[0]
        mine = {"t": "mine", "u": e[0], "p": e[1], "x": e[2], "y": e[3]}
        msgs = c.pump(4.0, every=(0.15, mine), until=lambda m: m.get("t") == "del" and m.get("u") == e[0])
        live_lib.report(any(m.get("u") == e[0] for m in live_lib.of_type(msgs, "del")), "character.mine_entity works without a player",
               "; ".join(m["text"] for m in live_lib.of_type(msgs, "msg")))
        c.send({"t": "mine_stop"})
        c.pump(1.0, every=hello)
        live_lib.report(c.inv.get("wooden-chest", 0) == chest_before, "the mined chest is back in the inventory",
               f"{c.inv.get('wooden-chest', 0)}")

    # --- items on belts --------------------------------------------------------------------------
    # Eight belts running east, four tiles north of the character, with an iron plate put on
    # both lanes of each. They ride to the end of the line and stop there.
    px, py = c.me["x"] / 256, c.me["y"] / 256
    x0, row = int(px) - 4, int(py) - 4
    c.send({"t": "focus", "x": int(px * 256), "y": int(py * 256), "r": 48})
    out = live_lib.mod_lua(f"""
    local s = storage.f3d.puppet.surface local n = 0
    for _, e in pairs(s.find_entities_filtered({{ area = {{ {{ {x0} - 1, {row} - 1 }}, {{ {x0} + 9, {row} + 2 }} }}, type = {{ "transport-belt", "item-entity" }} }})) do e.destroy() end
    for i = 0, 7 do
      local b = s.create_entity({{ name = "transport-belt", position = {{ {x0} + i + 0.5, {row} + 0.5 }}, direction = defines.direction.east, force = "player" }})
      if b then for l = 1, 2 do if b.get_transport_line(l).insert_at_back({{ name = "iron-plate", count = 1 }}) then n = n + 1 end end end
    end
    rcon.print(n .. " items placed")
    """.replace("\n", " "))
    msgs = c.pump(2.0, every=hello)
    frames = {}
    for m in live_lib.of_type(msgs, "bi"):
        l = m["l"]
        frames.setdefault(m["k"], {}).update({l[i]: l[i + 1:i + 4] for i in range(0, len(l), 4)})
    ticks = sorted(frames)
    def row_items(frame):
        return {u: v for u, v in frame.items() if abs(v[2] / 256 - (row + 0.5)) <= 0.3 and x0 <= v[1] / 256 <= x0 + 8}

    # The first updates can come from where the focus was before; start from the first that shows
    # the test belts.
    with_row = [k for k in ticks if row_items(frames[k])]
    first = row_items(frames[with_row[0]]) if with_row else {}
    last = frames[ticks[-1]] if ticks else {}
    on_row = list(row_items(last).values())
    live_lib.report(len(on_row) >= 16 and all(c.items.get(v[0]) == "iron-plate" for v in on_row),
           "bi: items on belts arrive with item ids and positions on the belt row",
           f"{out}; {len(ticks)} updates, {len(last)} items, {len(on_row)} on the row")
    squared = [m for m in live_lib.of_type(msgs, "bi") if "fr" in m]
    live_lib.report(squared and len(squared) == len(live_lib.of_type(msgs, "bi")) and all(m["fr"] > 0 for m in squared),
           "bi: every part says the square it covers (fx, fy, fr), where the client hands over to lane icons (G16)",
           f"{[(m['fx'] / 256, m['fy'] / 256, m['fr']) for m in squared[:2]]}")
    lanes = sorted({v[2] - (row * 256 + 128) for v in on_row})
    live_lib.report(lanes and min(lanes) < 0 < max(lanes), "the two lanes sit either side of the belt centre", f"y offsets {lanes} / 256")
    # #2 / B2: what each lane carries, for drawing belts far away (bfar). With no near square (n 0):
    # a chunk wholly inside the square the last `bi` covered isn't read for far lanes (G16; the
    # client draws its items), and whether the test belts' chunk was depended on where in its chunk
    # the spot fell (the 0.2.0 CI run's spot passed, the next spot over didn't). The rounds come
    # once the bridge reaches them: waited for, up to 6 s, not a fixed 2 s.
    cx0, cy0 = int((x0 + 4) // 32), int(row // 32)
    c.send({"t": "sub", "c": [[cx0 + dx, cy0 + dy] for dy in (-1, 0, 1) for dx in (-1, 0, 1)]})
    c.send({"t": "bfar", "r": 100, "n": 0})

    def our_rows(msgs):
        rows = [m["l"][i:i + 5] for m in msgs for i in range(0, len(m["l"]), 5)]
        return rows, [r for r in rows if r[1] == row * 256 + 128 and x0 * 256 <= r[0] <= (x0 + 8) * 256]
    far_msgs = []
    far_end = time.time() + 6.0
    while time.time() < far_end and len(our_rows(far_msgs)[1]) < 8:
        far_msgs += [m for m in c.pump(0.5, every=hello) if m.get("t") == "bfar"]
    rows, ours = our_rows(far_msgs)
    plate = next((i for i, n in c.items.items() if n == "iron-plate"), None)
    live_lib.report(len(ours) >= 4 and all(r[2] == 4 for r in ours) and any(plate in r[3:5] for r in ours),
           "bfar: each belt's direction and what its lanes carry (LuaTransportLine.get_contents)", f"{len(rows)} belts, ours {ours[:3]}")
    counted = [m for m in far_msgs if len(m.get("c", [])) == len(m["l"]) // 5 * 2]
    our_counts = [m["c"][i // 5 * 2:i // 5 * 2 + 2] for m in far_msgs if m in counted for i in range(0, len(m["l"]), 5)
                  if m["l"][i + 1] == row * 256 + 128 and x0 * 256 <= m["l"][i] <= (x0 + 8) * 256]
    live_lib.report(far_msgs and len(counted) == len(far_msgs) and our_counts and all(0 <= n <= 4 for p in our_counts for n in p) and any(sum(p) > 0 for p in our_counts),
           "bfar c: how many items each lane of each belt holds (0-4), so far belts are drawn as full as they are (G17)", f"ours {our_counts[:4]}")
    c.send({"t": "bfar", "r": 0})
    kept = [u for u in first if u in last]
    crossed = [u for u in kept if int(first[u][1] / 256) != int(last[u][1] / 256)]
    live_lib.report(bool(crossed), "unique_id stays the same as an item moves onto the next belt",
           f"{len(kept)} ids in the first and last update, {len(crossed)} of them changed belt")
    # belt_items.lua works a straight belt's item positions out from where its lines start, read
    # once per update; compare with get_line_item_position for single belts facing each way.
    out = live_lib.mod_lua(f"""
    local s = storage.f3d.puppet.surface local bi = package.loaded["__factorio-3d-bridge__/scripts/belt_items.lua"]
    local worst, n, east = 0, 0, ""
    for k, d in pairs({{ defines.direction.north, defines.direction.east, defines.direction.south, defines.direction.west }}) do
      local b = s.create_entity({{ name = "transport-belt", position = {{ {x0} + 3 * k + 0.5, {row} - 5.5 }}, direction = d, force = "player" }})
      if b then
    for l = 1, 2 do for q = 0, 0.75, 0.25 do b.get_transport_line(l).insert_at(q, {{ name = "iron-plate", count = 1 }}) end end
    for _, r in pairs(bi.check_straight(b)) do worst = math.max(worst, math.abs(r[1] - r[3]), math.abs(r[2] - r[4])) n = n + 1 end
    if d == defines.direction.east then
      local line = b.get_transport_line(1) local a, z = line.get_line_item_position(0), line.get_line_item_position(1)
      east = string.format("east belt at %.2f,%.2f: line 1 position 0 at %.3f,%.3f, 1 at %.3f,%.3f", b.position.x, b.position.y, a.x, a.y, z.x, z.y)
    end
    b.destroy()
      end
    end
    rcon.print(n .. " " .. string.format("%.5f", worst) .. " " .. east)
    """.replace("\n", " "))
    parts = out.split()[:2]
    live_lib.report(len(parts) == 2 and int(parts[0]) >= 16 and float(parts[1]) < 1 / 256,
           "straight belts: items' positions worked out from the line start match get_line_item_position", out)

    # --- inserter hands and the sky ----------------------------------------------------------------
    hands = {}
    for m in live_lib.of_type(msgs, "ih"):
        l = m["l"]
        hands.update({l[i]: l[i + 1:i + 4] for i in range(0, len(l), 4)})
    if ins:
        h = hands.get(ins[0][0])
        live_lib.report(h is not None and abs(h[0] - ins[0][2]) <= 2 * 256 and abs(h[1] - ins[0][3]) <= 2 * 256,
               "ih: the built inserter's hand (held_stack_position) is sent near the inserter", str(h))
    sky = live_lib.of_type(msgs, "sky")
    live_lib.report(bool(sky) and 0 <= sky[-1]["d"] < 1000 and 0 <= sky[-1]["n"] <= 1000,
           "sky: surface.daytime and surface.darkness are sent", str(sky[-1:]))
    live_lib.mod_lua(f"""
    for _, b in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ area = {{ {{ {x0}, {row} }}, {{ {x0} + 8, {row} + 1 }} }}, type = "transport-belt" }})) do b.destroy() end
    """.replace("\n", " "))

    # --- items on the ground ------------------------------------------------------------------------
    # Five plates spilled at the character's feet and one plate three tiles east, out of pickup
    # range. Checks find_entities_filtered{type = "item-entity"}, item-entity.stack,
    # item_pickup_distance and mine_entity on an item-entity without a player.
    px, py = c.me["x"] / 256, c.me["y"] / 256
    out = live_lib.mod_lua(f"""
    local c = storage.f3d.puppet local s = c.surface
    local spilled = s.spill_item_stack({{ position = c.position, stack = {{ name = "iron-plate", count = 5 }} }})
    local far = s.create_entity({{ name = "item-on-ground", position = {{ {px} + 3, {py} }}, stack = {{ name = "iron-plate", count = 1 }} }})
    rcon.print(#spilled .. " " .. (far and (far.position.x .. " " .. far.position.y .. " " .. far.stack.count) or "none") .. " " .. c.item_pickup_distance)
    """.replace("\n", " "))
    try:
        n_spilled, fx, fy, far_count, pickup_distance = out.split()
        far_pos = [round(float(fx) * 256), round(float(fy) * 256)]
    except ValueError:
        n_spilled, far_pos, far_count, pickup_distance = "?", None, "?", "?"
    msgs = c.pump(1.2, every=hello)
    gi = live_lib.of_type(msgs, "gi")
    lying = [gi[-1]["l"][i:i + 3] for i in range(0, len(gi[-1]["l"]), 3)] if gi else []
    plates = [r for r in lying if c.items.get(r[0]) == "iron-plate"]
    live_lib.report(len(plates) >= 6 and any(r[1:] == far_pos for r in plates),
           "gi: items on the ground arrive with item ids and positions (item-entity.stack)",
           f"spill made {n_spilled} entities, far one holds {far_count}, item_pickup_distance {pickup_distance}; "
           f"{len(gi)} updates in 1.2 s, {len(lying)} items, {len(plates)} plates")
    before = c.inv.get("iron-plate", 0)
    c.pump(2.0, every=(0.15, {"t": "pickup"}))
    msgs = c.pump(1.5, every=hello)
    gi = live_lib.of_type(msgs, "gi")
    lying = [gi[-1]["l"][i:i + 3] for i in range(0, len(gi[-1]["l"]), 3)] if gi else []
    left = [r for r in lying if c.items.get(r[0]) == "iron-plate"]
    live_lib.report(c.inv.get("iron-plate", 0) >= before + 5 and any(r[1:] == far_pos for r in left),
           "pickup: mine_entity on item-entities within reach, without a player; the far one stays",
           f"iron plates {before} -> {c.inv.get('iron-plate', 0)}; plates still on the ground: {len(left)}; "
           + "; ".join(m["text"] for m in live_lib.of_type(msgs, "msg")))
    # Not used by the mod: whether the game's own pickup (picking_state, what F does) works for a
    # character without a player. Worth knowing as an alternative.
    out = live_lib.mod_lua(f"""
    local c = storage.f3d.puppet local s = c.surface
    for _, e in pairs(s.find_entities_filtered({{ type = "item-entity", area = {{ {{ {px} - 5, {py} - 5 }}, {{ {px} + 5, {py} + 5 }} }} }})) do e.destroy() end
    s.create_entity({{ name = "item-on-ground", position = c.position, stack = {{ name = "iron-plate", count = 1 }} }})
    storage.f3d_probe = c.get_main_inventory().get_item_count("iron-plate")
    local ok, err = pcall(function() c.picking_state = true end)
    rcon.print(ok and "set" or tostring(err))
    """.replace("\n", " "))
    time.sleep(0.5)
    probe = live_lib.mod_lua("""
    local c = storage.f3d.puppet
    local n = c.get_main_inventory().get_item_count("iron-plate") - storage.f3d_probe
    pcall(function() c.picking_state = false end)
    for _, e in pairs(c.surface.find_entities_filtered({ type = "item-entity", position = c.position, radius = 3 })) do e.destroy() end
    storage.f3d_probe = nil
    rcon.print(n)
    """.replace("\n", " "))
    print(f"     picking_state without a player: {out}; plates picked up in 0.5 s: {probe} (informational)")

    # --- combat ------------------------------------------------------------------------------------
    # Small biters next to the character, made inactive so they stand still, shot with a pistol:
    # one with Space (shooting_enemies), one with C at its position (shooting_selected). Checks
    # shooting_state on a player-less character, the gun and ammo inventories, selected_gun_index,
    # LuaItemStack.ammo (me.sh), max_health, on_entity_damaged with get_health_ratio, and
    # on_entity_died.
    live_lib.mod_lua('local c = storage.f3d.puppet c.insert({name = "pistol", count = 1}) c.insert({name = "firearm-magazine", count = 10}) storage.f3d.guns_sig = nil')
    msgs = c.pump(0.6, every=hello)
    guns = live_lib.of_type(msgs, "guns")
    slots = guns[-1]["l"] if guns else []
    live_lib.report(any(s[0] == "pistol" and s[1] == "firearm-magazine" and s[2] > 0 for s in slots),
           "guns: the character's gun and ammo inventories", str(guns[-1:]))
    live_lib.report(c.me.get("mhp", 0) > 0, "me.mhp: the character's max_health", str(c.me.get("mhp")))

    def biter(dx, dy):
        out = live_lib.mod_lua(f"""
    local c = storage.f3d.puppet local s = c.surface
    local p = s.find_non_colliding_position("small-biter", {{ c.position.x + {dx}, c.position.y + {dy} }}, 4, 0.5)
    local b = p and s.create_entity({{ name = "small-biter", position = p, force = "enemy" }})
    if b and not pcall(function() b.disabled_by_script = true end) then b.active = false end
    rcon.print(b and (b.unit_number .. " " .. b.position.x .. " " .. b.position.y) or "none")
    """.replace("\n", " "))
        try:
            unit, x, y = out.split()
            return int(unit), round(float(x) * 256), round(float(y) * 256)
        except ValueError:
            live_lib.report(False, "spawn a small biter to shoot", out)
            return None

    def shoot_at(target, mode):
        unit, x, y = target
        msgs = c.pump(4.0, every=(0.15, {"t": "shoot", "m": mode, "x": x, "y": y}),
                      until=lambda m: m.get("t") == "died" and m.get("u") == unit)
        c.send({"t": "shoot", "m": -1})
        return msgs + c.pump(0.6, every=hello)

    px, py = c.me["x"] / 256, c.me["y"] / 256
    first = biter(6, -2)
    if first:
        msgs = shoot_at(first, 0)
        damaged = [m["l"][i + 1] for m in live_lib.of_type(msgs, "hp") for i in range(0, len(m["l"]), 2) if m["l"][i] == first[0]]
        live_lib.report(any(m.get("u") == first[0] for m in live_lib.of_type(msgs, "died")),
               "shoot m=0: shooting_state shooting_enemies kills a biter without a player (on_entity_died -> died)",
               "; ".join(m["text"] for m in live_lib.of_type(msgs, "msg")))
        live_lib.report(any(m.get("sh") == 1 for m in live_lib.of_type(msgs, "me")), "me.sh: the ammo count (LuaItemStack.ammo) goes down while firing")
        live_lib.report(bool(damaged) and min(damaged) < 1000, "hp: on_entity_damaged and get_health_ratio report the wounded biter",
               f"health seen {damaged}")
    second = biter(5, 3)
    if second:
        msgs = shoot_at(second, 1)
        live_lib.report(any(m.get("u") == second[0] for m in live_lib.of_type(msgs, "died")),
               "shoot m=1: shooting_selected at a position kills the biter standing there (no `selected` entity)",
               "; ".join(m["text"] for m in live_lib.of_type(msgs, "msg")))
    state = live_lib.mod_lua("rcon.print(storage.f3d.puppet.shooting_state.state == defines.shooting.not_shooting)")
    live_lib.report(state == "true", "shoot m=-1 sets not_shooting", state)
    live_lib.mod_lua('storage.f3d.puppet.insert({name = "submachine-gun", count = 1})')
    c.send({"t": "gun", "i": 2})
    msgs = c.pump(0.6, every=hello)
    guns = live_lib.of_type(msgs, "guns")
    live_lib.report(bool(guns) and guns[-1]["sel"] == 2, "gun: selected_gun_index can be written", str(guns[-1:]))
    c.send({"t": "gun", "i": 1})
    live_lib.mod_lua(f"""
    for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ type = "unit", position = {{ {px}, {py} }}, radius = 12 }})) do e.destroy() end
    """.replace("\n", " "))

    # --- vehicles -----------------------------------------------------------------------------------
    # A fuelled car next to the character: get in, drive, steer, brake, get out. Then a locomotive
    # on a short straight track. Checks set_driver / set_driver(nil) and character.vehicle for a
    # player-less character, riding_state, the vehicle's speed, and the train's manual mode.
    def vehicle_lua(code):
        return live_lib.mod_lua(code.replace("\n", " "))

    def orientations(msgs, unit):
        return [r[4] for m in live_lib.of_type(msgs, "mv") for r in m["l"] if r[0] == unit and len(r) > 4]

    def drive_checks(unit, what, min_move):
        c.send({"t": "enter"})
        c.pump(0.5, every=hello)
        live_lib.report(c.me.get("v") == unit, f"enter: set_driver puts the player-less character in the {what}",
               f"me.v {c.me.get('v')}, expected {unit}")
        if c.me.get("v") != unit:
            return
        x0, y0 = c.me["x"], c.me["y"]
        msgs = c.pump(1.5, every=(0.15, {"t": "drive", "a": 1, "s": 0}))
        moved = ((c.me["x"] - x0) ** 2 + (c.me["y"] - y0) ** 2) ** 0.5 / 256
        live_lib.report(moved > min_move and c.me.get("vs", 0) > 0, f"drive: riding_state accelerates the {what}; me follows it",
               f"moved {moved:.1f} tiles, vs {c.me.get('vs')}; " + "; ".join(m["text"] for m in live_lib.of_type(msgs, "msg")))
        return msgs

    live_lib.clean_spot(c, hello, half=24)  # the car drives off north, turns and brakes: room for that
    out = vehicle_lua(f"""
    local c = storage.f3d.puppet local s = c.surface
    local p = s.find_non_colliding_position("car", {{ c.position.x + 4, c.position.y }}, 10, 0.5)
    local car = p and s.create_entity({{ name = "car", position = p, force = c.force }})
    if car then
      car.get_fuel_inventory().insert({{ name = "coal", count = 20 }})
      c.teleport(s.find_non_colliding_position("character", car.position, 10, 0.5))
    end
    rcon.print(car and car.unit_number or "none")
    """)
    car = None
    if out.isdigit():
        car = int(out)
        msgs = drive_checks(car, "car", 1.0)
        if msgs is not None:
            before = orientations(msgs, car)
            msgs = c.pump(1.0, every=(0.15, {"t": "drive", "a": 1, "s": 1}))
            after = orientations(msgs, car)
            turn = (after[-1] - before[-1] + 500) % 1000 - 500 if before and after else 0
            live_lib.report(turn > 20, "drive s=1 steers the car right (clockwise)", f"orientation {before[-1:]} -> {after[-1:]}")
            c.pump(2.5, every=(0.15, {"t": "drive", "a": 2, "s": 0}))
            live_lib.report(abs(c.me.get("vs", 999)) <= 2, "drive a=2 brakes to a stop", f"vs {c.me.get('vs')}")
            c.send({"t": "drive", "a": 0, "s": 0})
            c.send({"t": "enter"})
            c.pump(0.5, every=hello)
            live_lib.report("v" not in c.me, "enter again: set_driver(nil) gets the character out", str(c.me))
    else:
        live_lib.report(False, "place a car for the vehicle checks", out)

    out = vehicle_lua(f"""
    local c = storage.f3d.puppet local s = c.surface
    local x0 = 2 * math.floor(c.position.x / 2) + 1 local y0 = 2 * math.floor(c.position.y / 2) + 13
    storage.f3d_live_rails = {{}}
    for i = -30, 30 do
      local r = s.create_entity({{ name = "straight-rail", position = {{ x0 + 2 * i, y0 }}, direction = defines.direction.east, force = c.force }})
      if r then table.insert(storage.f3d_live_rails, r) end
    end
    local rails = #storage.f3d_live_rails
    local loco = s.create_entity({{ name = "locomotive", position = {{ x0, y0 }}, direction = defines.direction.east, force = c.force }})
    if loco then
      loco.get_fuel_inventory().insert({{ name = "coal", count = 20 }})
      c.teleport(s.find_non_colliding_position("character", loco.position, 10, 0.5))
    end
    rcon.print((loco and loco.unit_number or "none") .. " " .. rails)
    """)
    loco = out.split()[0] if out else ""
    if loco.isdigit():
        loco = int(loco)
        if drive_checks(loco, "locomotive", 0.2) is not None:  # trains pull away slowly
            manual = vehicle_lua("rcon.print(storage.f3d.puppet.vehicle and storage.f3d.puppet.vehicle.train.manual_mode)")
            live_lib.report(manual == "true", "driving a locomotive switched its train to manual mode", manual)
            c.pump(3.0, every=(0.15, {"t": "drive", "a": 2, "s": 0}))
            c.send({"t": "drive", "a": 0, "s": 0})
            c.send({"t": "enter"})
            c.pump(0.5, every=hello)
            live_lib.report("v" not in c.me, "and gets out of the locomotive", str(c.me))
    else:
        live_lib.report(False, "place a locomotive on a straight track for the train checks", out)
    # Only what this check made: the owner may run it on a real save.
    made = [str(u) for u in (car if isinstance(car, int) else 0, loco if isinstance(loco, int) else 0) if u]
    vehicle_lua(f"""
    for _, u in pairs({{ {", ".join(made)} }}) do
      local e = game.get_entity_by_unit_number(u)
      if e and e.valid and not e.get_driver() then e.destroy() end
    end
    for _, r in pairs(storage.f3d_live_rails or {{}}) do if r.valid then r.destroy() end end
    storage.f3d_live_rails = nil
    """)

    # --- inventory slots, quickbar, crafting, research ------------------------------------------------
    # Checks LuaInventory indexing (#inv, inv[i]), LuaItemStack transfer_stack with an amount,
    # swap_stack and quality, sort_and_merge, the crafting queue API (crafting_queue,
    # crafting_queue_progress, cancel_crafting, get_craftable_count), recipe groups, ingredients and
    # products, and the force's technologies, add_research, research_queue and current_research.
    def latest(msgs, t):
        found = live_lib.of_type(msgs, t)
        return found[-1] if found else None

    live_lib.mod_lua("storage.f3d.slots_sig = nil")
    msgs = c.pump(0.8, every=hello)
    sl = latest(msgs, "slots")
    main = sl["l"].get("main", []) if sl else []
    totals = {}
    for v in main:
        if v:
            totals[v[0]] = totals.get(v[0], 0) + v[1]
    live_lib.report(len(main) >= 80 and all(totals.get(k) == n for k, n in c.inv.items()),
           "slots: the main inventory slot by slot (#inv, inv[i]) adds up to inv", f"{len(main)} slots, roles {sorted(sl['l']) if sl else None}")
    full = [i + 1 for i, v in enumerate(main) if v and v[1] >= 2]
    empty = [i + 1 for i, v in enumerate(main) if not v]
    if full and len(empty) >= 2:
        fi, ti = full[0], empty[-1]
        item, count = main[fi - 1][0], main[fi - 1][1]
        c.send({"t": "move", "from": "main", "fi": fi, "to": "main", "ti": ti, "n": 1})
        msgs = c.pump(0.5, every=hello)
        after = latest(msgs, "slots")["l"]["main"] if latest(msgs, "slots") else main
        live_lib.report(after[ti - 1] == [item, 1] and after[fi - 1] == [item, count - 1],
               "move n=1 splits a stack (transfer_stack with an amount)", f"{after[fi - 1]} / {after[ti - 1]}; "
               + "; ".join(m["text"] for m in live_lib.of_type(msgs, "msg")))
        c.send({"t": "move", "from": "main", "fi": ti, "to": "main", "ti": fi})
        msgs = c.pump(0.5, every=hello)
        after = latest(msgs, "slots")["l"]["main"] if latest(msgs, "slots") else []
        live_lib.report(bool(after) and after[fi - 1] == [item, count] and after[ti - 1] == 0, "and moving it back merges it", str(after[fi - 1:fi]))
        c.send({"t": "sort", "inv": "main"})
        msgs = c.pump(0.5, every=hello)
        live_lib.report(not live_lib.of_type(msgs, "msg"), "sort: sort_and_merge", "; ".join(m["text"] for m in live_lib.of_type(msgs, "msg")))
    else:
        live_lib.report(False, "need a stack of 2+ and two empty slots for the move checks", str(main[:10]))

    c.send({"t": "qb_set", "i": 1, "item": "iron-chest"})
    c.send({"t": "qb_sel", "i": 1})
    msgs = c.pump(0.5, every=hello)
    qb = latest(msgs, "qb")
    live_lib.report(bool(qb) and qb["held"] == "iron-chest", "quickbar: set and select", str(qb and qb["l"][:3]))
    c.send({"t": "qb_set", "i": 1, "item": ""})
    c.send({"t": "qb_sel", "i": 0})

    live_lib.mod_lua("storage.f3d.rdet_sig = nil storage.f3d.craftable_sig = nil")
    msgs = c.pump(1.0, every=hello)
    details = {r[0]: r for m in live_lib.of_type(msgs, "rdet") for r in m["l"]}
    gear = details.get("iron-gear-wheel")
    live_lib.report(bool(gear) and gear[8] == [["item", "iron-plate", 2]] and gear[9] == [["item", "iron-gear-wheel", 1]] and gear[3] != "",
           "rdet: recipe ingredients, products, energy, group and subgroup", f"{len(details)} recipes; {gear}")
    craftable = dict(map(tuple, latest(msgs, "craftable")["l"])) if latest(msgs, "craftable") else {}
    live_lib.report(craftable.get("iron-gear-wheel", 0) == c.inv.get("iron-plate", 0) // 2,
           "craftable: get_craftable_count", f"gears {craftable.get('iron-gear-wheel')}, plates {c.inv.get('iron-plate')}")
    c.send({"t": "craft", "recipe": "iron-gear-wheel", "n": 3})
    msgs = c.pump(0.5, every=hello)
    cq = latest(msgs, "cq")
    live_lib.report(bool(cq) and cq["l"] and cq["l"][0][1] == "iron-gear-wheel", "cq: crafting_queue and its progress", str(cq))
    if cq and cq["l"]:
        c.send({"t": "cancel_craft", "i": cq["l"][0][0], "n": 99})
        msgs = c.pump(0.5, every=hello)
        cq = latest(msgs, "cq")
        live_lib.report(bool(cq) and not cq["l"], "cancel_craft empties the queue (cancel_crafting)", str(cq))

    # A new game has nothing researched and only trigger technologies (craft an item, build an
    # entity) available; science-pack research needs those first. The tree's states are checked
    # against the force, then, if fewer than two lab technologies are available, the trigger
    # technologies in front of the two nearest are researched (and undone afterwards).
    def tech_tree():
        live_lib.mod_lua("storage.f3d.techs_dirty = true")
        msgs = c.pump(1.5, every=hello)
        return {r[0]: r for m in live_lib.of_type(msgs, "techs") for r in m["l"]}

    techs = tech_tree()
    truth = live_lib.mod_lua("""
    local out = {}
    for name, t in pairs(game.forces.player.technologies) do
      if t.researched then out[#out + 1] = name end
    end
    table.sort(out) rcon.print(table.concat(out, " "))
    """.replace("\n", " ")).split()
    available = sorted(n for n, r in techs.items() if r[6] == 1)
    researched = sorted(n for n, r in techs.items() if r[6] == 2)
    live_lib.report(len(techs) > 20 and bool(available) and set(researched) <= set(truth)
           and all(all(techs[p][6] == 2 for p in techs[n][2] if p in techs) for n in available),
           "techs: the technology tree with states (researched, prerequisites)",
           f"{len(techs)} technologies, {len(available)} available, {len(researched)} researched "
           f"(force: {len(truth)}); triggers: {sorted({r[7] for r in techs.values()} - {''})}")
    lab = sorted(n for n in available if techs[n][7] == "")
    unlocked = []
    if len(lab) < 2:
        out = live_lib.mod_lua("""
    local f = game.forces.player local techs = f.technologies
    local function trigger(t) return t.prototype.research_trigger ~= nil end
    local function missing(t, seen)
      for name, pre in pairs(t.prerequisites) do
    if not pre.researched and not seen[name] then seen[name] = pre missing(pre, seen) end
      end
      return seen
    end
    local picks = {}
    for name, t in pairs(techs) do
      if t.enabled and not t.researched and not trigger(t) then
    local need, n, ok = missing(t, {}), 0, true
    for _, pre in pairs(need) do n = n + 1 ok = ok and trigger(pre) end
    if ok and n > 0 then picks[#picks + 1] = { name = name, n = n, need = need } end
      end
    end
    table.sort(picks, function(a, b) if a.n ~= b.n then return a.n < b.n end return a.name < b.name end)
    local done = {}
    for i = 1, math.min(2, #picks) do
      for name, pre in pairs(picks[i].need) do
    if not pre.researched then pre.research_recursive() end
      end
    end
    for name, t in pairs(techs) do
      if t.researched then done[#done + 1] = name end
    end
    table.sort(done) rcon.print(table.concat(done, " "))
    """.replace("\n", " "))
        unlocked = sorted(set(out.split()) - set(truth))
        techs = tech_tree()
        lab = sorted(n for n, r in techs.items() if r[6] == 1 and r[7] == "")
        live_lib.report(len(lab) >= 2 and all(techs.get(n, [0] * 7)[6] == 2 for n in unlocked),
               "techs are resent with new states when research finishes (on_research_finished)",
               f"researched by script: {unlocked}; lab technologies now available: {lab[:5]}")
    if len(lab) >= 2:
        first, second = lab[0], lab[1]
        c.send({"t": "research", "name": first})
        c.send({"t": "research", "name": second})
        # Waits for the `rs` that says so (up to 5 s): right after a resend of every technology the outbox may hold
        # the answer back past half a second (a full run's one failure).
        msgs = c.pump(5.0, until=lambda m: m.get("t") == "rs" and m.get("cur") == first and second in (m.get("q") or []),
                      every=hello)
        rs = latest(msgs, "rs")
        live_lib.report(bool(rs) and rs["cur"] == first and second in rs["q"], "research: add_research starts one and queues the next", str(rs))
        c.send({"t": "research_cancel", "name": second})
        c.send({"t": "research_cancel", "name": first})
        msgs = c.pump(5.0, until=lambda m: m.get("t") == "rs" and second not in (m.get("q") or []) and m.get("cur") != first,
                      every=hello)
        rs = latest(msgs, "rs")
        live_lib.report(bool(rs) and second not in rs["q"] and rs["cur"] != first,
               "research_cancel: research_queue and cancel_current_research", str(rs))
        # Finishing a technology by script raises on_research_finished: the notification and the
        # tree's resend. Undone afterwards (on_research_reversed).
        live_lib.mod_lua(f'storage.f3d.puppet.force.technologies["{first}"].researched = true')
        msgs = c.pump(1.0, every=hello)
        done = [e for m in live_lib.of_type(msgs, "rdone") for e in m["l"]]
        techs_now = {r[0]: r[6] for m in live_lib.of_type(msgs, "techs") for r in m["l"]}
        live_lib.report(done == [[first, 0]] and techs_now.get(first) == 2, "research finished: one rdone naming the tech, and the tree resent",
               f"{done[:3]}; state {techs_now.get(first)}")
        live_lib.mod_lua(f'storage.f3d.puppet.force.technologies["{first}"].researched = false')
    if unlocked:
        live_lib.mod_lua(f"for _, n in pairs({{ {', '.join(repr(n) for n in unlocked)} }}) do game.forces.player.technologies[n].researched = false end")

    # --- building: turning, fast-replace, rails, rolling stock, quality --------------------------------
    # Checks can_fast_replace, create_entity{fast_replace = true, spill = false} without a player
    # (and that it raises no destroy event, so the mod's own del is the only one), the rail item's
    # place_result / rails in 2.1, build_grid_size, LuaEntity.quality and quality in create_entity.
    live_lib.mod_lua('local c = storage.f3d.puppet for _, s in pairs({{"transport-belt", 3}, {"fast-transport-belt", 2}, {"rail", 5}, {"locomotive", 1}}) do c.insert({name = s[1], count = s[2]}) end '
            'pcall(function() c.insert({name = "transport-belt", count = 1, quality = "uncommon"}) end)')
    live_lib.report(live_lib.clean_spot(c, hello), "move to a dry, empty spot for the building checks", str(c.me))
    px, py = round(c.me["x"] / 256), round(c.me["y"] / 256)
    built = []

    def build(item, dx, dy, d, **extra):
        msg = {"t": "build", "item": item, "x": (px + dx) * 256 + 128, "y": (py + dy) * 256 + 128, "d": d}
        msg.update(extra)
        c.send(msg)
        msgs = c.pump(0.6, every=hello)
        built.extend(m["e"] for m in live_lib.of_type(msgs, "add"))
        return msgs

    belts = c.inv.get("transport-belt", 0)
    msgs = build("transport-belt", 3, 3, 4)
    first = live_lib.of_type(msgs, "add")
    msgs = build("transport-belt", 3, 3, 8)
    upd = live_lib.of_type(msgs, "upd")
    live_lib.report(bool(first) and bool(upd) and upd[-1]["e"][4] == 8 and not live_lib.of_type(msgs, "add"),
           "the same belt built over a belt turns it", "; ".join(m["text"] for m in live_lib.of_type(msgs, "msg")))
    msgs = build("fast-transport-belt", 3, 3, 8)
    dels, adds = live_lib.of_type(msgs, "del"), live_lib.of_type(msgs, "add")
    c.pump(0.6, every=hello)
    live_lib.report(bool(first) and len(dels) == 1 and dels[0]["u"] == first[0]["e"][0] and bool(adds)
           and c.inv.get("transport-belt", 0) == belts,
           "a fast belt fast-replaces it (one del, the old belt back in the inventory)",
           f"{len(dels)} del, adds {[a['e'][1] for a in adds]}, belts {belts} -> {c.inv.get('transport-belt', 0)}; "
           + "; ".join(m["text"] for m in live_lib.of_type(msgs, "msg")))
    # A ten-tile track within reach (build_distance 10), long enough for a locomotive (six tiles).
    msgs = build("rail", 0, 6, 4)
    rails = [a["e"] for a in live_lib.of_type(msgs, "add")]
    live_lib.report(bool(rails) and c.protos.get(rails[0][1], ("",))[0] == "straight-rail" and rails[0][2] % 512 == 256 and rails[0][3] % 512 == 256,
           "rail builds a straight rail on the two-tile grid (odd centres)", f"{rails[:1]}; " + "; ".join(m["text"] for m in live_lib.of_type(msgs, "msg")))
    for dx in (-4, -2, 2, 4):
        build("rail", dx, 6, 4)
    msgs = build("locomotive", 1, 6, 4)
    out = live_lib.mod_lua(f"local l = storage.f3d.puppet.surface.find_entities_filtered({{ name = 'locomotive', position = {{ {px + 1}, {py + 6} }}, radius = 4 }})[1] "
                  "rcon.print(l and (l.unit_number .. ' ' .. l.position.x .. ' ' .. l.position.y .. ' ' .. l.orientation) or 'none')")
    live_lib.report(out != "none" and float(out.split()[3]) in (0.25, 0.75), "rolling stock is put on the nearest rail, along it",
           "unit, x, y, orientation: " + out + "; " + "; ".join(m["text"] for m in live_lib.of_type(msgs, "msg")))
    msgs = build("transport-belt", -3, 3, 0, q="uncommon")
    adds = [a["e"] for a in live_lib.of_type(msgs, "add")]
    live_lib.report(bool(adds) and len(adds[0]) == 6 and adds[0][5].get("q") == "uncommon",
           "a belt built from an uncommon stack is uncommon (create_entity quality, entity.quality)",
           f"{adds[:1]}; " + "; ".join(m["text"] for m in live_lib.of_type(msgs, "msg")))
    units = [str(e[0]) for e in built if e[0]] + ([out.split()[0]] if out != "none" else [])
    live_lib.destroy_units(units)

    # --- fluids, wires and power ----------------------------------------------------------------------
    # Two small poles 5 tiles apart (they connect themselves), a pipe with water written into its
    # fluid box, and an assembler with a recipe in reach of a pole but no power (nothing generates;
    # out of reach of every pole it would be pw 2, see below). Checks get_wire_connectors and
    # connections, fluid storage reads (2.1: get_fluid, get_fluid_capacity, fluids_count; there is
    # no LuaEntity.fluidbox), the no_power status, and gui status/pw.
    live_lib.clean_spot(c, hello)
    px, py = round(c.me["x"] / 256), round(c.me["y"] / 256)
    out = live_lib.mod_lua(f"""
    local c = storage.f3d.puppet local s = c.surface local made = {{}}
    local function at(name, dx, dy)
      local p = s.find_non_colliding_position(name, {{ {px} + dx, {py} + dy }}, 6, 1)
      local e = p and s.create_entity({{ name = name, position = p, force = c.force, raise_built = true }})
      if e then made[#made + 1] = e.unit_number end
      return e
    end
    local a, b = at("small-electric-pole", -4, -6), at("small-electric-pole", 1, -6)
    local pipe = at("pipe", -2, -8)
    if pipe then pipe.set_fluid(1, {{ name = "water", amount = 50 }}) end
    local asm = at("assembling-machine-1", 3, -8)
    if asm then asm.set_recipe("iron-gear-wheel") end
    rcon.print(table.concat(made, " ") .. "|" .. (pipe and pipe.unit_number or 0) .. "|" .. (asm and asm.unit_number or 0)
      .. "|" .. (a and a.unit_number or 0) .. "|" .. (b and b.unit_number or 0))
    """.replace("\n", " "))
    try:
        made_s, pipe_u, asm_u, pole_a, pole_b = out.split("|")
        made = made_s.split()
        pipe_u, asm_u, pole_a, pole_b = int(pipe_u), int(asm_u), int(pole_a), int(pole_b)
    except ValueError:
        live_lib.report(False, "place poles, a pipe and an assembler for the fluid and power checks", out)
        made, pipe_u, asm_u, pole_a, pole_b = [], 0, 0, 0, 0
    if made:
        cx, cy = int(px // 32), int(py // 32)
        c.send({"t": "resync", "full": 0, "c": [[cx + dx, cy + dy] for dx in (-1, 0, 1) for dy in (-1, 0, 1)]})
        msgs = c.pump(2.5, every=hello)
        recs = {e[0]: e for m in live_lib.of_type(msgs, "ents") for e in m["e"]}
        wires = [recs.get(u, [0] * 6)[5].get("w", []) if len(recs.get(u, [])) > 5 else [] for u in (pole_a, pole_b)]
        live_lib.report(pole_b in wires[0] or pole_a in wires[1], "pole records carry copper wires (get_wire_connectors)", str(wires))
        fl = live_lib.of_type(msgs, "fl")[-1]["l"] if live_lib.of_type(msgs, "fl") else []
        boxes = [fl[i:i + 6] for i in range(0, len(fl), 6) if fl[i] == pipe_u]
        live_lib.report(bool(boxes) and boxes[0][3] > 0, "fl: the pipe's water (get_fluid, get_fluid_capacity)", f"{boxes}")
        pw = live_lib.of_type(msgs, "pw")[-1]["l"] if live_lib.of_type(msgs, "pw") else []
        live_lib.report(asm_u in pw[::2] and pw[pw.index(asm_u) + 1] == 0, "pw: an assembler without power (status no_power)", str(pw[:10]))
        c.send({"t": "open", "u": asm_u, "p": c.proto_id("assembling-machine-1"), "x": recs[asm_u][2], "y": recs[asm_u][3]} if asm_u in recs else {"t": "close"})
        g = [m for m in c.pump(1.0, every=hello) if m.get("t") == "gui" and m.get("u") == asm_u]
        live_lib.report(bool(g) and g[-1].get("status") == "no_power" and g[-1].get("pw") == 0,
               "gui: status name and electric buffer (electric_buffer_size, energy)", str(g[-1:]))
        c.send({"t": "close"})
        live_lib.destroy_units(made)

    # --- blueprints, ghosts and planners ---------------------------------------------------------------
    # A blueprint of two wooden chests is made in the character's inventory (set_blueprint_entities),
    # placed with `blueprint`, one ghost is filled in by building over it, then the chest is marked
    # for deconstruction and unmarked, and an upgrade planner (wooden -> iron chest) marks it.
    # Checks build_blueprint without a player, ghost records, ghost.revive, deconstruct_area on the
    # surface and on a planner stack, upgrade_area and the mark events.
    live_lib.clean_spot(c, hello)
    px, py = round(c.me["x"] / 256), round(c.me["y"] / 256)
    out = live_lib.mod_lua("""
    local c = storage.f3d.puppet local inv = c.get_main_inventory()
    c.insert({ name = "blueprint", count = 1 }) c.insert({ name = "deconstruction-planner", count = 1 })
    c.insert({ name = "upgrade-planner", count = 1 }) c.insert({ name = "wooden-chest", count = 2 })
    local slots = {}
    for i = 1, #inv do
      local st = inv[i]
      if st.valid_for_read and not slots[st.name] then slots[st.name] = i end
    end
    local bp = inv[slots["blueprint"]]
    bp.set_blueprint_entities({ { entity_number = 1, name = "wooden-chest", position = { 0, 0 } }, { entity_number = 2, name = "wooden-chest", position = { 2, 0 } } })
    local up = inv[slots["upgrade-planner"]]
    local ok = pcall(function()
      up.set_mapper(1, "from", { type = "entity", name = "wooden-chest" })
      up.set_mapper(1, "to", { type = "entity", name = "iron-chest" })
    end)
    rcon.print(slots["blueprint"] .. " " .. slots["deconstruction-planner"] .. " " .. slots["upgrade-planner"] .. " " .. tostring(ok))
    """.replace("\n", " "))
    try:
        bp_slot, decon_slot, up_slot, mapper_ok = out.split()
        bp_slot, decon_slot, up_slot = int(bp_slot), int(decon_slot), int(up_slot)
    except ValueError:
        live_lib.report(False, "make a blueprint and planners in the inventory", out)
        bp_slot = 0
    if bp_slot:
        gx, gy = px + 3, py + 5
        c.send({"t": "blueprint", "i": bp_slot, "x": gx * 256 + 128, "y": gy * 256 + 128, "d": 0})
        msgs = c.pump(0.8, every=hello)
        ghost_id = c.proto_id("entity-ghost")
        ghosts = [m["e"] for m in live_lib.of_type(msgs, "add") if m["e"][1] == ghost_id]
        live_lib.report(len(ghosts) == 2 and all(len(g) > 5 and g[5].get("gh") == c.proto_id("wooden-chest") for g in ghosts),
               "blueprint: build_blueprint without a player, ghosts sent with extra.gh", f"{ghosts}; " + "; ".join(m["text"] for m in live_lib.of_type(msgs, "msg")))
        if ghosts:
            g = ghosts[0]
            c.send({"t": "build", "item": "wooden-chest", "x": g[2], "y": g[3], "d": 0})
            msgs = c.pump(0.8, every=hello)
            chests = [m["e"] for m in live_lib.of_type(msgs, "add") if m["e"][1] == c.proto_id("wooden-chest")]
            live_lib.report(any(d["u"] == g[0] for d in live_lib.of_type(msgs, "del")) and bool(chests),
                   "building over a ghost revives it (ghost.revive)", "; ".join(m["text"] for m in live_lib.of_type(msgs, "msg")))
            area = {"x1": (gx - 2) * 256, "y1": (gy - 1) * 256, "x2": (gx + 4) * 256, "y2": (gy + 2) * 256}
            if chests:
                chest = chests[0][0]
                c.send({"t": "decon", "i": 0, **area})
                msgs = c.pump(0.8, every=hello)
                upd = [m["e"] for m in live_lib.of_type(msgs, "upd") if m["e"][0] == chest]
                live_lib.report(bool(upd) and upd[-1][5].get("d") == 1, "decon: surface.deconstruct_area marks it; on_marked_for_deconstruction sends upd", str(upd[-1:]))
                c.send({"t": "decon", "i": decon_slot, "cancel": 1, **area})
                msgs = c.pump(0.8, every=hello)
                upd = [m["e"] for m in live_lib.of_type(msgs, "upd") if m["e"][0] == chest]
                live_lib.report(bool(upd) and "d" not in (upd[-1][5] if len(upd[-1]) > 5 else {}), "decon cancel with a planner stack (cancel_deconstruct_area)", str(upd[-1:]))
                c.send({"t": "upgrade", "i": up_slot, **area})
                msgs = c.pump(0.8, every=hello)
                upd = [m["e"] for m in live_lib.of_type(msgs, "upd") if m["e"][0] == chest]
                live_lib.report(bool(upd) and upd[-1][5].get("up") == c.proto_id("iron-chest"),
                       "upgrade: upgrade_area with a planner's mapping (set_mapper)", f"set_mapper ok: {mapper_ok}; {upd[-1:]}")
                c.send({"t": "upgrade", "i": up_slot, "cancel": 1, **area})
                c.pump(0.4, every=hello)
            units = [str(e[0]) for e in ghosts + chests if e[0]]
            live_lib.destroy_units(units)

    # --- circuit network --------------------------------------------------------------------------
    # A constant combinator wired red into an arithmetic combinator: set_cb on both, then the
    # arithmetic one's screen must show the constant's signal. Checks get_control_behavior,
    # parameters, sections and filters, get_signals and the wire connector API (connect_to).
    px, py = round(c.me["x"] / 256), round(c.me["y"] / 256)
    out = live_lib.mod_lua(f"""
    local c = storage.f3d.puppet local s = c.surface
    local k = s.create_entity({{ name = "constant-combinator", position = {{ {px} + 2.5, {py} + 3.5 }}, force = c.force, raise_built = true }})
    local a = s.create_entity({{ name = "arithmetic-combinator", position = {{ {px} + 4.5, {py} + 3.5 }}, direction = defines.direction.east, force = c.force, raise_built = true }})
    local ok, err = pcall(function()
      local ids = defines.wire_connector_id
      k.get_wire_connector(ids.circuit_red, true).connect_to(a.get_wire_connector(ids.combinator_input_red, true))
    end)
    rcon.print((k and k.unit_number or 0) .. " " .. (a and a.unit_number or 0) .. " " .. tostring(ok) .. " " .. tostring(err))
    """.replace("\n", " "))
    parts = out.split(" ", 3)
    const_u, arith_u = (int(parts[0]), int(parts[1])) if len(parts) >= 2 and parts[0].isdigit() else (0, 0)
    if const_u and arith_u:
        msgs = c.pump(0.6, every=hello)
        recs = {m["e"][0]: m["e"] for m in live_lib.of_type(msgs, "add")}
        k_rec, a_rec = recs.get(const_u), recs.get(arith_u)
        if k_rec and a_rec:
            c.send({"t": "open", "u": const_u, "p": k_rec[1], "x": k_rec[2], "y": k_rec[3]})
            c.send({"t": "set_cb", "u": const_u, "cb": {"enabled": True, "signals": [["item", "iron-plate", 21]]}})
            g = [m for m in c.pump(1.0, every=hello) if m.get("t") == "gui" and m.get("u") == const_u]
            live_lib.report(bool(g) and g[-1].get("cb", {}).get("signals") == [["item", "iron-plate", 21]],
                   "set_cb on a constant combinator (get_section, filters)", f"{g[-1:]}; " + out)
            c.send({"t": "open", "u": arith_u, "p": a_rec[1], "x": a_rec[2], "y": a_rec[3]})
            g = [m for m in c.pump(1.0, every=hello) if m.get("t") == "gui" and m.get("u") == arith_u]
            cb = g[-1].get("cb") if g else None
            live_lib.report(isinstance(cb, dict), "an arithmetic combinator's parameters in gui", str(cb))
            if isinstance(cb, dict):
                cb = dict(cb, first_signal={"type": "item", "name": "iron-plate"}, second_constant=2, operation="*",
                          output_signal={"type": "item", "name": "iron-plate"})
                c.send({"t": "set_cb", "u": arith_u, "cb": cb})
            g = [m for m in c.pump(1.0, every=hello) if m.get("t") == "gui" and m.get("u") == arith_u]
            live_lib.report(bool(g) and g[-1].get("cb", {}).get("operation") == "*" and ["item", "iron-plate", 21] in g[-1].get("sig", {}).get("r", []),
                   "set_cb writes parameters; sig shows the red network (get_signals)", f"{g[-1:]}; " + "; ".join(m["text"] for m in live_lib.of_type(msgs, "msg")))
            c.send({"t": "close"})
        live_lib.destroy_units([const_u, arith_u])
    else:
        live_lib.report(False, "place two combinators for the circuit checks", out)

    # --- map --------------------------------------------------------------------------------------
    # A chart of the character's chunk and its east neighbour, then a tag added and removed over
    # the protocol and one added from the game. Checks is_chunk_charted, get_tile, map colours,
    # bounding_box, find_chart_tags, add_chart_tag, tag.destroy and the chart tag events.
    cx, cy = c.me["x"] // (256 * 32), c.me["y"] // (256 * 32)
    c.send({"t": "map", "cx1": cx, "cy1": cy, "cx2": cx + 1, "cy2": cy, "res": 4})
    msgs = c.pump(1.0, every=hello)
    charts = {(m["cx"], m["cy"]): m for m in live_lib.of_type(msgs, "chart")}
    here = charts.get((cx, cy))
    errors = [m["text"] for m in live_lib.of_type(msgs, "msg") if "Map error" in m["text"]]
    # A new map can put the character in a chunk of one terrain, so the east neighbour counts too.
    east = charts.get((cx + 1, cy)) or {}
    colours = {tuple(col) for m in (here or {}, east) for col in m.get("pal", [])}
    live_lib.report(here is not None and here["n"] == 8 and len(colours) > 1 and not errors,
           "chart of the character's chunk: 8 x 8 pixels, more than one colour (with its neighbour)",
           f"{here and here.get('pal')}; {errors}")
    live_lib.report((cx + 1, cy) in charts and live_lib.of_type(msgs, "tags"), "the neighbour's chart and the tags follow",
           f"{sorted(charts)}")
    c.send({"t": "tag_add", "x": c.me["x"], "y": c.me["y"], "text": "live check", "icon": ["item", "iron-plate"]})
    tags = live_lib.of_type(c.pump(0.5, every=hello), "tags")
    mine = [t for t in (tags[-1]["l"] if tags else []) if t[3] == "live check"]
    live_lib.report(bool(mine) and mine[0][4:] == ["item", "iron-plate"], "tag_add puts a tag on the map (add_chart_tag)", str(tags[-1:]))
    if mine:
        c.send({"t": "tag_del", "id": mine[0][0]})
        tags = live_lib.of_type(c.pump(0.5, every=hello), "tags")
        live_lib.report(bool(tags) and not any(t[0] == mine[0][0] for t in tags[-1]["l"]), "tag_del removes it (destroy)", str(tags[-1:]))
    live_lib.mod_lua(f"local c = storage.f3d.puppet c.force.add_chart_tag(c.surface, {{ position = c.position, text = 'from the game' }})")
    tags = live_lib.of_type(c.pump(0.5, every=hello), "tags")
    game_tag = [t for t in (tags[-1]["l"] if tags else []) if t[3] == "from the game"]
    live_lib.report(bool(game_tag), "a tag added in the game is sent (on_chart_tag_added)", str(tags[-1:]))
    live_lib.mod_lua("local c = storage.f3d.puppet for _, t in pairs(c.force.find_chart_tags(c.surface)) do if t.text == 'from the game' then t.destroy() end end")
    c.pump(0.3, every=hello)

    # --- network data -----------------------------------------------------------------------------
    # Two pipes in a line (extra.pc from get_fluid_box_pipe_connections, the first one updated when
    # the second joins it), a lamp with no pole (pw 2: not_plugged_in_electric_network), a heat pipe
    # at 600 degrees (ht: temperature), and two poles wired by script after they were built (no
    # event; the bridge's half-second wire check sends both records).
    out = live_lib.mod_lua("""
    local c = storage.f3d.puppet local s = c.surface local x = math.floor(c.position.x) local y = math.floor(c.position.y)
    storage.f3d_live_net = {}
    local function mk(name, dx, dy) local e = s.create_entity({ name = name, position = { x + dx + 0.5, y + dy + 0.5 }, force = c.force, raise_built = true }) if e then table.insert(storage.f3d_live_net, e) end return e end
    local a = mk("pipe", -4, 4) local b = mk("pipe", -3, 4)
    local lamp = mk("small-lamp", -6, -4)
    local heat = mk("heat-pipe", -4, 6) if heat then heat.temperature = 600 end
    local pa = mk("small-electric-pole", 3, 6) local pb = mk("small-electric-pole", 7, 6)
    if pa and pb then pa.get_wire_connector(defines.wire_connector_id.pole_copper, true).disconnect_from(pb.get_wire_connector(defines.wire_connector_id.pole_copper, true)) end
    local u = function(e) return e and e.unit_number or 0 end
    rcon.print(u(a) .. " " .. u(b) .. " " .. u(lamp) .. " " .. u(heat) .. " " .. u(pa) .. " " .. u(pb) .. " " .. tostring(lamp and lamp.is_connected_to_electric_network()))
    """.replace("\n", " "))
    parts = out.split()
    if len(parts) == 7 and all(p.isdigit() and int(p) > 0 for p in parts[:6]):
        pipe_a, pipe_b, lamp_u, heat_u, pole_a, pole_b = (int(v) for v in parts[:6])
        msgs = c.pump(1.3, every=hello)
        recs = {}
        for m in msgs:
            if m.get("t") in ("add", "upd"):
                recs[m["e"][0]] = m["e"]
        live_lib.report(recs.get(pipe_a, [0] * 6)[5:] == [{"pc": 2}] and recs.get(pipe_b, [0] * 6)[5:] == [{"pc": 8}],
               "pipes say which sides connect (extra.pc), and a pipe is updated when another joins it",
               f"{recs.get(pipe_a)} {recs.get(pipe_b)}")
        pw = [v for m in live_lib.of_type(msgs, "pw") for v in m["l"]]
        state = dict(zip(pw[::2], pw[1::2])).get(lamp_u)
        live_lib.report(state == 2 or parts[6] == "true", "pw: 2 for a lamp not connected to any pole",
               f"state {state}, connected {parts[6]}")
        ht = [v for m in live_lib.of_type(msgs, "ht") for v in m["l"]]
        live_lib.report(dict(zip(ht[::2], ht[1::2])).get(heat_u) == 600, "ht: a heat pipe's temperature", str(ht[:8]))
        # A script's wire raises no event: the bridge looks at the focus square in 8 strips, one every
        # 30 ticks (tracker.lua wire_strips), so it sees each wire within 4 s, measured from the wires
        # it last sent. The poles wired themselves as they were built, then the script cut them: first
        # the client's view of both (their last add or upd) is waited for to show the cut, then the
        # wire goes back and both must be updated. Each wait up to 6 s; a fixed 0.8 s passed only when
        # the poles' strip happened to come next, and wiring them back before the bridge had looked
        # left nothing to send.
        view = {}

        def note(ms):
            for m in ms:
                if m.get("t") in ("add", "upd") and m["e"][0] in (pole_a, pole_b):
                    view[m["e"][0]] = (m["e"][5:] or [{}])[0].get("w", [])

        def wait_for(cond):
            until = time.time() + 6.0
            while time.time() < until and not cond():
                note(c.pump(0.5, every=hello))
            return cond()
        note(msgs)
        cut = wait_for(lambda: pole_a in view and pole_b in view and pole_b not in view[pole_a] and pole_a not in view[pole_b])
        cut_view = dict(view)
        view.clear()
        # By the entities kept in storage: get_entity_by_unit_number doesn't find poles.
        live_lib.mod_lua(f"local by = {{}} for _, e in pairs(storage.f3d_live_net) do if e.valid then by[e.unit_number] = e end end "
                f"local a, b = by[{pole_a}], by[{pole_b}] "
                "rcon.print(tostring(a.get_wire_connector(defines.wire_connector_id.pole_copper, true).connect_to("
                "b.get_wire_connector(defines.wire_connector_id.pole_copper, true))))")
        wired = wait_for(lambda: pole_b in view.get(pole_a, []) and pole_a in view.get(pole_b, []))
        live_lib.report(cut and wired, "a wire cut and added again by script between two existing poles updates both within the "
               "bridge's look for wires (4 s)", f"cut {cut_view}, then {view}")
    else:
        live_lib.report(False, "place pipes, a lamp, a heat pipe and poles for the network data checks", out)
    live_lib.mod_lua("for _, e in pairs(storage.f3d_live_net or {}) do if e.valid then e.destroy() end end storage.f3d_live_net = nil")
    c.pump(0.3, every=hello)

    # --- logistics --------------------------------------------------------------------------------
    # A powered roboport with five logistic robots, a storage chest holding 50 iron plates and a
    # requester chest next to the character. Checks find_logistic_network_by_position (`ln`), the
    # chests' screens (logistic_mode, get_logistic_sections, get_filter / set_filter,
    # logistic_network: robot counts, get_contents), the roboport's inventories, the character's
    # requester point (`clog`, set_char_requests; it only exists with the force's
    # character_logistic_requests, turned on here) and a robot carrying plates (`rc`, robot_cargo).
    out = live_lib.mod_lua("""
    local c = storage.f3d.puppet local s = c.surface local x = math.floor(c.position.x) local y = math.floor(c.position.y)
    storage.f3d_live_logi = {}
    storage.f3d_live_charlogi = c.force.character_logistic_requests
    c.force.character_logistic_requests = true
    local function mk(name, dx, dy) local e = s.create_entity({ name = name, position = { x + dx, y + dy }, force = c.force, raise_built = true }) if e then table.insert(storage.f3d_live_logi, e) end return e end
    local port = mk("roboport", -8, -6)
    local eei = mk("electric-energy-interface", -12, -1)
    local sub = mk("substation", -8, -1)
    local req = mk("requester-chest", -2.5, -3.5)
    local sto = mk("storage-chest", -4.5, -3.5)
    if port then port.get_inventory(defines.inventory.roboport_robot).insert({ name = "logistic-robot", count = 5 }) end
    if sto then sto.insert({ name = "iron-plate", count = 50 }) end
    local u = function(e) return e and e.unit_number or 0 end
    local p = function(e) return e and (e.position.x .. " " .. e.position.y) or "0 0" end
    rcon.print(u(port) .. " " .. u(req) .. " " .. u(sto) .. " " .. p(port) .. " " .. p(req) .. " " .. p(sto))
    """.replace("\n", " "))
    parts = out.split()
    if len(parts) == 9 and all(v.isdigit() and int(v) > 0 for v in parts[:3]):
        port_u, req_u, sto_u = (int(v) for v in parts[:3])
        port_xy, req_xy, sto_xy = ((round(float(parts[i]) * 256), round(float(parts[i + 1]) * 256)) for i in (3, 5, 7))
        msgs = c.pump(1.3, every=hello)
        ln = live_lib.of_type(msgs, "ln")
        live_lib.report(bool(ln) and ln[-1]["id"] > 0 and ln[-1]["log"][1] >= 5, "ln: the network the character stands in, with its robots", str(ln[-1:]))
        # Before anything is requested, while the robots still sit in the roboport and all 50
        # plates are in the storage chest; once the requester asks, robots fly off with them.
        c.send({"t": "open", "u": sto_u, "p": c.proto_id("storage-chest"), "x": sto_xy[0], "y": sto_xy[1]})
        c.send({"t": "set_storage_filter", "u": sto_u, "item": "iron-plate"})
        g = [m for m in c.pump(0.6, every=hello) if m.get("t") == "gui" and m.get("u") == sto_u]
        lg = g[-1].get("lg", {}) if g else {}
        live_lib.report(lg.get("filter") == "iron-plate", "a storage chest's filter (set_filter, get_filter)", str(g[-1:])[:400])
        live_lib.report(["iron-plate", 50] in lg.get("net", {}).get("items", []), "its network's contents (get_contents)", str(lg.get("net"))[:400])
        c.send({"t": "set_storage_filter", "u": sto_u, "item": ""})
        c.send({"t": "open", "u": port_u, "p": c.proto_id("roboport"), "x": port_xy[0], "y": port_xy[1]})
        g = [m for m in c.pump(0.6, every=hello) if m.get("t") == "gui" and m.get("u") == port_u]
        live_lib.report(bool(g) and g[-1]["kind"] == "roboport" and any(s and s[0] == "logistic-robot" for s in g[-1].get("slots", {}).get("robots", [])),
               "a roboport's screen shows its robots (roboport_robot)", str(g[-1:])[:400])
        c.send({"t": "open", "u": req_u, "p": c.proto_id("requester-chest"), "x": req_xy[0], "y": req_xy[1]})
        c.send({"t": "set_requests", "u": req_u, "l": [["iron-plate", 10, -1]]})
        g = [m for m in c.pump(0.6, every=hello) if m.get("t") == "gui" and m.get("u") == req_u]
        lg = g[-1].get("lg", {}) if g else {}
        live_lib.report(lg.get("mode") == "requester" and lg.get("requests") == [["iron-plate", 10, -1]],
               "a requester chest's requests, set over the protocol (get_logistic_sections, section filters)", str(lg)[:400])
        c.send({"t": "close"})
        c.send({"t": "set_char_requests", "l": [["iron-gear-wheel", 20, -1]]})
        clog = live_lib.of_type(c.pump(0.6, every=hello), "clog")
        live_lib.report(bool(clog) and clog[-1]["l"] == [["iron-gear-wheel", 20, -1]], "the character's requests (get_requester_point)", str(clog[-1:]))
        c.send({"t": "set_char_requests", "l": []})
        msgs = c.pump(5.0, every=hello)
        rc = [v for m in live_lib.of_type(msgs, "rc") for v in m["l"]]
        carried = {rc[i + 1] for i in range(0, len(rc), 3)}
        live_lib.report(any(c.items.get(i) == "iron-plate" for i in carried),
               "rc: a robot carries plates from the storage chest to the requester (robot_cargo)", str(rc[:12]))
    else:
        live_lib.report(False, "place a roboport and logistic chests for the logistics checks", out)
    live_lib.mod_lua("for _, e in pairs(storage.f3d_live_logi or {}) do if e.valid then e.destroy() end end storage.f3d_live_logi = nil "
            "if storage.f3d_live_charlogi ~= nil then storage.f3d.puppet.force.character_logistic_requests = storage.f3d_live_charlogi end "
            "storage.f3d_live_charlogi = nil "
            "local c = storage.f3d.puppet for _, r in pairs(c.surface.find_entities_filtered({ type = 'logistic-robot', position = c.position, radius = 40 })) do r.destroy() end")
    c.pump(0.3, every=hello)

    # --- trains -----------------------------------------------------------------------------------
    # Rails east-west north of the character, a train stop beside them, a fuelled locomotive with a
    # cargo wagon behind it. Checks the stop's name in its record (backer_name, on_entity_renamed),
    # `tr` (LuaTrain state, speed, station, path_end_stop, carriages), the train screen (2.x
    # get_schedule: current, get_records, set_records, go_to_station; manual_mode; the cargo_wagon
    # inventory) and the stop screen (trains_limit read and written, nil for none; trains_count).
    home = live_lib.mod_lua("local p = storage.f3d.puppet.position rcon.print(p.x .. ' ' .. p.y)").split()
    out = live_lib.mod_lua(f"""
    local c = storage.f3d.puppet local s = c.surface
    local x0 = 2 * math.floor(c.position.x / 2) + 1 local y0 = 2 * math.floor(c.position.y / 2) - 11
    storage.f3d_live_train = {{}}
    local function mk(spec) spec.force = c.force spec.raise_built = true local e = s.create_entity(spec) if e then table.insert(storage.f3d_live_train, e) end return e end
    for i = -14, 14 do mk({{ name = "straight-rail", position = {{ x0 + 2 * i, y0 }}, direction = defines.direction.east }}) end
    local stop = mk({{ name = "train-stop", position = {{ x0 + 14, y0 + 2 }}, direction = defines.direction.east }})
    if stop then stop.backer_name = "F3D live" end
    local loco = mk({{ name = "locomotive", position = {{ x0, y0 }}, direction = defines.direction.east }})
    local wagon = mk({{ name = "cargo-wagon", position = {{ x0 - 7, y0 }}, direction = defines.direction.east }})
    if loco then loco.get_fuel_inventory().insert({{ name = "coal", count = 20 }}) end
    if wagon then wagon.get_inventory(defines.inventory.cargo_wagon).insert({{ name = "iron-plate", count = 50 }}) end
    c.teleport({{ x0, y0 + 4 }})
    local same = loco and wagon and loco.train.id == wagon.train.id
    rcon.print((stop and stop.unit_number or 0) .. " " .. (loco and loco.unit_number or 0) .. " " .. (wagon and wagon.unit_number or 0) .. " " .. (same and 1 or 0)
      .. " " .. (loco and (loco.position.x .. " " .. loco.position.y) or "0 0") .. " " .. (wagon and (wagon.position.x .. " " .. wagon.position.y) or "0 0")
      .. " " .. (stop and (stop.position.x .. " " .. stop.position.y) or "0 0"))
    """.replace("\n", " "))
    parts = out.split()
    if len(parts) == 10 and all(p.lstrip("-").replace(".", "", 1).isdigit() for p in parts) and int(parts[0]) and int(parts[1]) and int(parts[2]):
        stop_u, loco_u, wagon_u, coupled = (int(v) for v in parts[:4])
        lx, ly, wx, wy, sx, sy = (round(float(v) * 256) for v in parts[4:])
        live_lib.report(coupled == 1, "a cargo wagon placed 7 tiles behind a locomotive joins its train", out)
        c.send({"t": "focus", "x": lx, "y": ly, "r": 48})
        msgs = c.pump(1.2, every=hello)
        recs = [m["e"] for m in msgs if m.get("t") in ("add", "upd") and m["e"][0] == stop_u]
        live_lib.report(bool(recs) and len(recs[-1]) == 6 and recs[-1][5].get("n") == "F3D live",
               "a train stop's record carries its name, also after a rename by script (on_entity_renamed)", str(recs[-2:]))
        tr = [r for m in live_lib.of_type(msgs, "tr") for r in m["l"] if loco_u in r[6]]
        live_lib.report(bool(tr) and wagon_u in tr[-1][6], "tr lists the train with both carriages", str(tr[-1:]))
        c.send({"t": "open", "u": loco_u, "p": c.proto_id("locomotive"), "x": lx, "y": ly})
        g = [m for m in c.pump(0.6, every=hello) if m.get("t") == "gui" and m.get("u") == loco_u]
        info = g[-1].get("tr") if g else None
        live_lib.report(isinstance(info, dict) and isinstance(info.get("sched"), dict), "a locomotive opens as a train with its schedule (get_schedule)", str(g[-1:]))
        # The wagon is opened while the train still stands where it was made: once the schedule
        # runs it leaves, and open looks for the wagon where the client says it is.
        c.send({"t": "open", "u": wagon_u, "p": c.proto_id("cargo-wagon"), "x": wx, "y": wy})
        g = [m for m in c.pump(0.6, every=hello) if m.get("t") == "gui" and m.get("u") == wagon_u]
        live_lib.report(bool(g) and g[-1]["kind"] == "train" and g[-1].get("inv", {}).get("cargo") == [["iron-plate", 50]],
               "a cargo wagon's screen shows its cargo (defines.inventory.cargo_wagon)", str(g[-1:]))
        c.send({"t": "open", "u": loco_u, "p": c.proto_id("locomotive"), "x": lx, "y": ly})
        c.pump(0.3, every=hello)
        records = [{"station": "F3D live", "wait_conditions": [{"type": "time", "compare_type": "or", "ticks": 120}]}]
        c.send({"t": "set_schedule", "u": loco_u, "records": records})
        c.send({"t": "train_go", "u": loco_u, "i": 1})
        c.send({"t": "train_mode", "u": loco_u, "auto": 1})
        msgs = c.pump(2.0, every=hello)
        g = [m for m in msgs if m.get("t") == "gui" and m.get("u") == loco_u]
        sched = (g[-1].get("tr") or {}).get("sched", {}) if g else {}
        errors = [m["text"] for m in live_lib.of_type(msgs, "msg")]
        live_lib.report(bool(sched.get("records")) and sched["records"][0].get("station") == "F3D live" and not errors,
               "set_schedule and train_go (set_records, go_to_station)", f"{sched}; {errors}")
        state = (g[-1].get("tr") or {}).get("state") if g else None
        live_lib.report(bool(g) and g[-1]["tr"]["manual"] == 0 and state in ("on_the_path", "arrive_station", "wait_station"),
               "train_mode 1 runs the schedule: the train leaves for the stop", f"state {state}; {g[-1:]}")
        # The stop is 14 tiles from the character, out of reach: stand beside it.
        live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {sx / 256}, {sy / 256 + 3} }})")
        c.pump(0.3, every=hello)
        c.send({"t": "open", "u": stop_u, "p": c.proto_id("train-stop"), "x": sx, "y": sy})
        c.send({"t": "set_stop", "u": stop_u, "limit": 1})
        g = [m for m in c.pump(0.6, every=hello) if m.get("t") == "gui" and m.get("u") == stop_u]
        live_lib.report(bool(g) and g[-1]["kind"] == "stop" and g[-1]["stop"]["name"] == "F3D live" and g[-1]["stop"]["limit"] == 1,
               "a train stop's screen; set_stop sets the trains limit", str(g[-1:]))
        c.send({"t": "set_stop", "u": stop_u, "limit": -1})
        g = [m for m in c.pump(0.6, every=hello) if m.get("t") == "gui" and m.get("u") == stop_u]
        live_lib.report(bool(g) and g[-1]["stop"]["limit"] == -1, "limit -1 removes the limit (trains_limit = nil)", str(g[-1:]))
        c.send({"t": "close"})
    else:
        live_lib.report(False, "place rails, a train stop, a locomotive and a cargo wagon for the train checks", out)
    live_lib.mod_lua("for _, e in pairs(storage.f3d_live_train or {}) do if e.valid then e.destroy() end end storage.f3d_live_train = nil")
    if len(home) == 2:
        live_lib.mod_lua(f"storage.f3d.puppet.teleport({{ {home[0]}, {home[1]} }})")
    c.send({"t": "focus", "x": c.me["x"], "y": c.me["y"], "r": 48})
    c.pump(0.3, every=hello)

    # --- machine screens ---------------------------------------------------------------------------
    # A chest, an assembler and a furnace next to the character, opened over the protocol. Checks
    # the inventory APIs (get_inventory with defines.inventory, get_output_inventory,
    # get_fuel_inventory, entity.insert), get_recipe / set_recipe, crafting_progress, the
    # prototype's crafting categories and can_reach_entity.
    def place(name, dy):
        out = live_lib.mod_lua(f"""
    local c = storage.f3d.puppet local s = c.surface
    local p = s.find_non_colliding_position("{name}", {{ c.position.x + 3, c.position.y + {dy} }}, 8, 1)
    local e = p and s.create_entity({{ name = "{name}", position = p, force = c.force, raise_built = true }})
    rcon.print(e and (e.unit_number .. " " .. e.position.x .. " " .. e.position.y) or "none")
    """.replace("\n", " "))
        try:
            unit, x, y = out.split()
            return [int(unit), c.proto_id(name), round(float(x) * 256), round(float(y) * 256)]
        except ValueError:
            live_lib.report(False, f"place a {name} for the screen checks", out)
            return None

    def screen_msgs(seconds, unit):
        return [m for m in c.pump(seconds, every=hello) if m.get("t") == "gui" and m.get("u") == unit]

    def open_cmd(rec):
        return {"t": "open", "u": rec[0], "p": rec[1], "x": rec[2], "y": rec[3]}

    live_lib.mod_lua('local c = storage.f3d.puppet c.insert({name = "iron-plate", count = 20}) c.insert({name = "coal", count = 10}) c.insert({name = "iron-ore", count = 10})')
    chest, asm, furnace = place("wooden-chest", -3), place("assembling-machine-1", 0), place("stone-furnace", 4)
    if chest:
        c.send(open_cmd(chest))
        g = screen_msgs(1.2, chest[0])
        live_lib.report(len(g) >= 2 and g[0].get("kind") == "container" and "chest" in g[0].get("inv", {}),
               "gui: an open chest is reported twice a second with its chest inventory", str(g[:1]))
        c.send({"t": "put", "u": chest[0], "item": "iron-plate", "n": 5})
        c.send({"t": "take", "u": chest[0], "inv": "chest", "item": "iron-plate", "n": 2})
        g = screen_msgs(1.0, chest[0])
        live_lib.report(bool(g) and g[-1]["inv"].get("chest") == [["iron-plate", 3]], "put and take move items (entity.insert, inventory.remove)", str(g[-1:]))
        chest_slots = g[-1].get("slots", {}).get("chest", []) if g else []
        live_lib.report(len(chest_slots) >= 16 and chest_slots[0] == ["iron-plate", 3], "gui.slots: the chest slot by slot", str(chest_slots[:3]))
        c.send({"t": "move", "from": "chest", "fi": 1, "to": "chest", "ti": 5, "u": chest[0]})
        g = screen_msgs(1.0, chest[0])
        chest_slots = g[-1].get("slots", {}).get("chest", []) if g else []
        live_lib.report(len(chest_slots) >= 5 and chest_slots[4] == ["iron-plate", 3] and chest_slots[0] == 0,
               "move between an open chest's slots", str(chest_slots[:6]))
        live_lib.mod_lua(f'for _, e in pairs(storage.f3d.puppet.surface.find_entities_filtered({{ name = "wooden-chest", position = {{ {chest[2] / 256}, {chest[3] / 256} }} }})) do e.destroy() end')
        g = screen_msgs(1.0, chest[0])
        live_lib.report(any(m.get("closed") is True for m in g), "a destroyed chest closes its screen", str(g[-1:]))
    if asm:
        c.send(open_cmd(asm))
        g = screen_msgs(1.0, asm[0])
        rl = g[0].get("rl", []) if g else []
        live_lib.report(bool(g) and g[0].get("kind") == "crafter" and "iron-gear-wheel" in rl and "iron-plate" not in rl,
               "gui: assembler recipe list from crafting categories (no smelting)", f"{len(rl)} recipes, inventories {list(g[0]['inv']) if g else None}")
        c.send({"t": "set_recipe", "u": asm[0], "recipe": "iron-gear-wheel"})
        c.send({"t": "put", "u": asm[0], "item": "iron-plate", "n": 4})
        g = screen_msgs(1.0, asm[0])
        live_lib.report(bool(g) and g[-1].get("recipe") == "iron-gear-wheel" and "pr" in g[-1] and g[-1]["inv"].get("input") == [["iron-plate", 4]],
               "set_recipe / get_recipe / crafting_progress, and plates go to the input", str(g[-1:]))
        before = c.inv.get("iron-plate", 0)
        c.send({"t": "set_recipe", "u": asm[0], "recipe": ""})
        g = screen_msgs(1.0, asm[0])
        live_lib.report(bool(g) and "recipe" not in g[-1] and c.inv.get("iron-plate", 0) == before + 4,
               "clearing the recipe gives the plates back (set_recipe's return value)", f"{before} -> {c.inv.get('iron-plate', 0)}; {g[-1:]}")
    if furnace:
        c.send(open_cmd(furnace))
        c.send({"t": "put", "u": furnace[0], "item": "coal", "n": 2})
        c.send({"t": "put", "u": furnace[0], "item": "iron-ore", "n": 3})
        g = screen_msgs(5.0, furnace[0])
        inv = g[-1]["inv"] if g else {}
        live_lib.report(inv.get("fuel") in ([["coal", 2]], [["coal", 1]]),
               "furnace: coal goes to the fuel inventory (get_fuel_inventory)", str(inv))
        live_lib.report(bool(g) and (g[-1].get("recipe") == "iron-plate" or inv.get("output")),
               "furnace: smelting shows its recipe or output", str(g[-1:]))
    c.send({"t": "close"})
    live_lib.mod_lua(f"""
    local s = storage.f3d.puppet.surface
    for _, rec in pairs({{ {{ "assembling-machine-1", {asm[2] / 256 if asm else 0}, {asm[3] / 256 if asm else 0} }}, {{ "stone-furnace", {furnace[2] / 256 if furnace else 0}, {furnace[3] / 256 if furnace else 0} }} }}) do
      for _, e in pairs(s.find_entities_filtered({{ name = rec[1], position = {{ rec[2], rec[3] }} }})) do e.destroy() end
    end
    """.replace("\n", " "))

    sizes = ", ".join(f"{t} {n}" for t, n in sorted(c.max_size.items(), key=lambda kv: -kv[1])[:4])
    print(f"     largest datagrams by type: {sizes} bytes")
    c.send({"t": "bye"})
    time.sleep(0.3)
    return hello


def run_rcon_and_tail(c, hello):
    """Run RCON server-side checks and the remaining live check suites."""
    # --- server-side checks over RCON ----------------------------------------------------------
    empty = rcon.run("/sc rcon.print(helpers.table_to_json({}))").strip()
    live_lib.report(empty in ("[]", "{}"), "helpers.table_to_json({}) is [] or {}", f"it is {empty}")

    got = []
    for size in (8192, 16384, 32768, 60000, 65507, 65508, 100000):
        c.pump(0.2)
        reply = live_lib.mod_lua(f'local ok, err = pcall(helpers.send_udp, {live_lib.CLIENT_PORT}, string.rep("x", {size}), 0) rcon.print(ok and "ok" or tostring(err))')
        msgs_raw = []
        end = time.time() + 0.5
        while time.time() < end:
            try:
                data, _ = c.sock.recvfrom(1 << 20)
                if data[:1] == b"x":
                    msgs_raw.append(len(data))
            except (socket.timeout, ConnectionResetError):
                pass
        got.append(f"{size}: send {reply[:60]}, received {msgs_raw or 'nothing'}")
    print("     send_udp sizes:\n       " + "\n       ".join(got))

    out = live_lib.mod_lua(r"""
    local world = package.loaded["__factorio-3d-bridge__/scripts/world.lua"]
    local surface = game.get_surface(1)
    local failed, tried, types = {}, 0, {}
    local x = 2000
    for name, proto in pairs(prototypes.entity) do
      if not types[proto.type] and proto.type ~= "character" then
    local ok, e = pcall(surface.create_entity, { name = name, position = { x, 2000 }, force = "player", create_build_effect_smoke = false })
    if ok and e and e.valid then
      types[proto.type] = true
      tried = tried + 1
      local ok2, err = pcall(world.record, e)
      if not ok2 then failed[#failed + 1] = name .. ": " .. tostring(err) end
      if e.valid then e.destroy() end
    end
    x = x + 12
      end
    end
    rcon.print(tried .. " types tried; " .. #failed .. " failed\n" .. table.concat(failed, "\n"))
    """.replace("\n", " "))
    live_lib.report(" 0 failed" in out, "world.record works for every entity type that can be created", out.replace("\n", " | ")[:400])

    out = live_lib.mod_lua(r"""
    local world = package.loaded["__factorio-3d-bridge__/scripts/world.lua"]
    local registry = package.loaded["__factorio-3d-bridge__/scripts/registry.lua"]
    local surface = game.get_surface(1)
    local profiler = helpers.create_profiler()
    local n = 0
    for cy = -2, 2 do for cx = -2, 2 do
      local x0, y0 = cx * 32, cy * 32
      for y = y0, y0 + 31 do for x = x0, x0 + 31 do registry.tile_id(surface.get_tile(x, y).name) end end
      for _, e in pairs(surface.find_entities_filtered({ area = { { x0, y0 }, { x0 + 32, y0 + 32 } }, type = registry.excluded_types(), invert = true })) do
    world.record(e) n = n + 1
      end
    end end
    profiler.stop()
    rcon.print({"", "25 chunks, ", tostring(n), " entities: ", profiler})
    """.replace("\n", " "))
    print("     snapshot timing:", out)

    # --- cliffs --------------------------------------------------------------------------------
    world_and_multi.check_cliffs(c, hello)

    # --- tiles, capsules, the rail planner, drag building ---------------------------------------
    building_and_planners.check_build_tools(c, hello)

    # --- mining vehicles and wagons by unit number (issue #10) -------------------------------------
    machines_and_vehicles.check_mine_vehicles(c, hello)

    # --- Alt-mode's icons with the records, arrows' recipe fluids (issue #9) -----------------------
    building_and_planners.check_alt(c, hello)

    # --- alerts without a player ---------------------------------------------------------------
    world_and_multi.check_alerts(c, hello)

    # --- two clients on one server ---------------------------------------------------------------
    world_and_multi.check_multi(c, hello)

    # --- remnants and linked belts -------------------------------------------------------------
    world_and_multi.check_remnants(c, hello)

    # --- turrets and vehicle guns --------------------------------------------------------------
    combat_and_enemies.check_turrets(c, hello)

    # --- signals, accumulators and power switches report their states ---------------------------
    machines_and_vehicles.check_states(c, hello)

    # --- repair packs (K13) ---------------------------------------------------------------------
    machines_and_vehicles.check_repair(c, hello)

    # --- vehicles: Ctrl+click into them, their guns while driving, repair packs (N2, N3, N4) -----
    machines_and_vehicles.check_vehicle_items(c, hello)

    # --- an underground pair over belts mines the belts between (M2) -----------------------------
    building_and_planners.check_under_clear(c, hello)

    # --- the pipes and belts beside what the character mines get their new shapes (the owner's FUE5 pipe end) -----
    building_and_planners.check_pipe_end(c, hello)

    # --- space platforms (Space Age) -----------------------------------------------------------
    space_and_planets.check_platforms(c, hello)

    # --- the other planets (Space Age) ---------------------------------------------------------
    space_and_planets.check_planets(c, hello)

    # --- Space Age's screens: silo launches, the hub, landing pad, collector, quality -----------
    space_and_planets.check_space(c, hello)

    # --- riding a rocket up to a platform's hub and a cargo pod down ---------------------------
    space_and_planets.check_ride(c, hello)

    # --- asteroid collectors' arms catching chunks ----------------------------------------------
    space_and_planets.check_collectors(c, hello)

    # /f3d-selftest: the character API checks the bridge can run by itself (the same command a
    # single-player game, which has no RCON, runs from its console).
    out = rcon.run("/f3d-selftest")
    live_lib.report("PASS" in out and "FAIL" not in out, "/f3d-selftest passes on the server", out.replace("\n", " | "))

    # The bridge's own cost: /f3d-profile, then /f3d-status lists a time per module after 10 s.
    # tools/busy_base.py does the same on a dense base.
    rcon.run("/f3d-profile")
    # The modules only run while a client is connected: keep saying hello.
    c.pump(11, every=hello)
    out = rcon.run("/f3d-status")
    rcon.run("/f3d-profile")
    live_lib.report("per tick" in out, "/f3d-profile: per-module script time in /f3d-status (helpers.create_profiler)",
           out.replace("\n", " | ")[:600])

    # --- the client's console (without /cheat, which would research everything) -----------------
    world_and_multi.check_console(c, hello)

    # --- the error barrier: a step and a handler made to fail, then forgotten --------------------
    world_and_multi.check_barrier(c, hello)
