"""Differential live check of hand crafting through the bridge's `craft` / `cancel_craft` against the game's own
queue rules (LuaControl.begin_crafting, cancel_crafting, get_craftable_count)."""
from __future__ import annotations

from . import live_lib


def check_crafting_diff(c, hello):
    lua = lambda code: live_lib.mod_lua(code.replace("\n", " "))

    def give(**items):
        parts = " ".join(f"m.insert({{ name = '{k.replace('_', '-')}', count = {v} }})" for k, v in items.items())
        lua(f"local c = storage.f3d.puppet local m = c.get_main_inventory() pcall(function() c.cancel_crafting({{ index = 1, count = 1000000 }}) end) m.clear() {parts} rcon.print('ok')")

    def clear_queue():
        lua("local c = storage.f3d.puppet for i = 1, 40 do if c.crafting_queue_size > 0 then pcall(function() c.cancel_crafting({ index = 1, count = 1000000 }) end) end end "
            "rcon.print(c.crafting_queue_size)")

    def queue():
        return lua("local c = storage.f3d.puppet local o = {} for _, q in pairs(c.crafting_queue or {}) do "
                   "o[#o + 1] = q.index .. ':' .. q.recipe .. '*' .. q.count .. (q.prerequisite and 'p' or '') end rcon.print(table.concat(o, ' '))")

    def totals():
        return lua("local c = storage.f3d.puppet local t = {} for _, it in pairs(c.get_main_inventory().get_contents()) do "
                   "t[#t + 1] = it.name .. '=' .. it.count end table.sort(t) rcon.print(table.concat(t, ' '))")

    lua("local f = storage.f3d.puppet.force for _, n in pairs({ 'inserter', 'electronic-circuit', 'iron-gear-wheel', 'copper-cable', 'plastic-bar', "
        "'rocket-control-unit', 'utility-science-pack', 'basic-oil-processing', 'firearm-magazine', 'pistol', 'sulfur' }) do "
        "if f.recipes[n] then f.recipes[n].enabled = true end end rcon.print('ok')")
    clear_queue()
    lua("storage.f3d.puppet.character_crafting_speed_modifier = -0.99 rcon.print('slow')")  # (nothing finishes while the checks look)

    # 1. The craftable counts the client is sent against the game's own, with intermediates counted.
    give(iron_plate=10, copper_plate=10)
    msgs = c.pump(2.5, every=hello)
    sent = {}
    for m in live_lib.of_type(msgs, "craftable"):
        sent = {r[0]: r[1] for r in m.get("l", [])}
    game = lua("""local c = storage.f3d.puppet local cats = c.prototype.crafting_categories local o = {}
for name, r in pairs(c.force.recipes) do local hand = false for _, k in pairs(r.categories) do if cats[k] then hand = true end end
  if r.enabled and not r.hidden and hand then
  local n = c.get_craftable_count(name) if n > 0 then o[#o + 1] = name .. '=' .. n end end end
table.sort(o) rcon.print(table.concat(o, ' '))""")
    want = dict(p.split("=") for p in game.split())
    got = {k: str(v) for k, v in sent.items()}
    live_lib.report(bool(sent) and want == got, "crafting: the craftable counts sent are the game's get_craftable_count (intermediates counted)",
                    f"game {sorted(want.items())[:8]} sent {sorted(got.items())[:8]}")
    live_lib.report(got.get("inserter") == "2", "crafting: 10 iron + 10 copper make 2 inserters through gear and circuit", str(got.get("inserter")))

    # 2. Crafting with intermediates queues them first; cancelling everything gives back exactly the ingredients.
    before = totals()
    c.send({"t": "craft", "recipe": "inserter", "n": 2})
    c.pump(0.5, every=hello)
    q = queue()
    live_lib.report(("copper-cable" in q or "electronic-circuit" in q) and "iron-gear-wheel" in q and q.split()[-1].endswith("inserter*2"),
                    "crafting: an inserter queues its gear and circuit (and cable) in front, the inserter last", q)
    live_lib.report(totals() != before, "crafting: queuing takes the ingredients out of the inventory at once", totals())
    for _ in range(8):
        qs = queue().split()
        if not qs:
            break
        c.send({"t": "cancel_craft", "i": int(qs[0].split(":")[0]), "n": 1000})
        c.pump(0.3, every=hello)
    live_lib.report(queue() == "" and totals() == before, "crafting: cancelling every entry returns exactly the ingredients", f"{queue()!r} {totals()} vs {before}")

    # 2b. Cancelling part of an entry returns that part's ingredients.
    give(iron_plate=20)
    c.send({"t": "craft", "recipe": "iron-gear-wheel", "n": 10})
    c.pump(0.4, every=hello)
    c.send({"t": "cancel_craft", "i": 1, "n": 4})
    c.pump(0.4, every=hello)
    live_lib.report(queue().startswith("1:iron-gear-wheel*6") and "iron-plate=8" in totals(),
                    "crafting: cancelling 4 of 10 gears leaves 6 queued and gives back 8 plates", f"{queue()} {totals()}")
    clear_queue()

    # 3. More than the inventory holds: the queue takes only what is craftable.
    give(iron_plate=6)
    c.send({"t": "craft", "recipe": "iron-gear-wheel", "n": 50})
    c.pump(0.5, every=hello)
    live_lib.report(queue() == "1:iron-gear-wheel*3", "crafting: 50 gears from 6 plates queue 3", queue())
    clear_queue()

    # 4. A recipe the hand can't craft: nothing queued, a message that says so, no script error.
    give(coal=50, iron_plate=50, copper_plate=50)
    for name in ("plastic-bar", "sulfur", "basic-oil-processing"):
        c.send({"t": "craft", "recipe": name, "n": 1})
        msgs = c.pump(0.5, every=hello)
        texts = [m.get("text") for m in live_lib.of_type(msgs, "msg")]
        live_lib.report(queue() == "" and texts == ["This recipe cannot be crafted by hand."], f"crafting: {name} is not hand-craftable: nothing queued and the message says so", f"{queue()!r} {texts}")

    lua("storage.f3d.puppet.character_crafting_speed_modifier = 0 rcon.print('normal')")
    # 5. The product has no room: the game spills it at the character's feet, nothing vanishes.
    lua("""local c = storage.f3d.puppet local m = c.get_main_inventory() m.clear()
for i = 2, #m do m[i].set_stack({ name = 'pistol', count = 1 }) end m[1].set_stack({ name = 'iron-plate', count = 100 })
for _, e in pairs(c.surface.find_entities_filtered({ name = 'item-on-ground', position = c.position, radius = 20 })) do e.destroy() end rcon.print('ok')""")
    c.send({"t": "craft", "recipe": "iron-gear-wheel", "n": 2})
    for _ in range(12):
        c.pump(0.5, every=hello)
        if queue() == "":
            break
    c.pump(0.5, every=hello)
    held = lua("local c = storage.f3d.puppet rcon.print(c.get_main_inventory().get_item_count('iron-gear-wheel'))")
    ground = lua("""local c = storage.f3d.puppet local n = 0
for _, e in pairs(c.surface.find_entities_filtered({ name = 'item-on-ground', position = c.position, radius = 20 })) do
  if e.stack.name == 'iron-gear-wheel' then n = n + e.stack.count end end rcon.print(n)""")
    live_lib.report(int(held or 0) + int(ground or 0) == 2 or queue() != "",
                    "crafting: with the inventory full the crafted gears are in it or on the ground (2 in all), or still queued: none vanishes",
                    f"held {held} ground {ground} queue {queue()!r}")
    lua("local c = storage.f3d.puppet c.get_main_inventory().clear() "
        "for _, e in pairs(c.surface.find_entities_filtered({ name = 'item-on-ground', position = c.position, radius = 20 })) do e.destroy() end rcon.print('ok')")

    # 6. Speed: 10 gears are 5 s of crafting at speed 1 (300 ticks).
    give(iron_plate=20)
    t0 = int(lua("rcon.print(game.tick)"))
    c.send({"t": "craft", "recipe": "iron-gear-wheel", "n": 10})
    done = None
    for _ in range(60):
        c.pump(0.25, every=hello)
        if queue() == "":
            done = int(lua("rcon.print(game.tick)")) - t0
            break
    speed = lua("rcon.print(storage.f3d.puppet.character_crafting_speed_modifier)")
    live_lib.report(done is not None and 290 <= done <= 330, "crafting: 10 gears take about 300 ticks at crafting speed 1", f"{done} ticks (modifier {speed})")
    lua("storage.f3d.puppet.get_main_inventory().clear() rcon.print('ok')")
