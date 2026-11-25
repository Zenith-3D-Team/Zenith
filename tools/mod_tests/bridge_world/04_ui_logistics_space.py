# Bridge test slice 04_ui_logistics_space.py (lines 5899-8190 of original test_bridge.py)
# --- Factorio's world controls and entity windows (ui_actions.lua, entity_ui.lua) -------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
take()
puppet.position = lua.table_from({"x": 0, "y": 0})
inv = puppet.get_main_inventory()

# Drop (Z): one item into the chest under the mouse, else onto the ground.
# (Clear of the car at 3, 3, which a drop over it would fill.)
box_chest = spawn("wooden-chest", 0.5, 6.5, force="player")
puppet.insert(lua.table_from({"name": "iron-plate", "count": 10}))
plates = inv.get_item_count("iron-plate")
send({"t": "drop", "item": "iron-plate", "x": fixed(0.5), "y": fixed(6.5)})
tick(2)
check(F.inventories[box_chest]["chest"].get_item_count("iron-plate") == 1 and inv.get_item_count("iron-plate") == plates - 1,
      "Z over a chest puts one item in it")
spilled = len(F.spilled)
send({"t": "drop", "item": "iron-plate", "x": fixed(5.5), "y": fixed(-1.5)})
tick(2)
check(len(F.spilled) == spilled + 1 and inv.get_item_count("iron-plate") == plates - 2, "Z over nothing drops it on the ground")
send({"t": "drop", "item": "iron-plate", "x": fixed(40), "y": 0})
tick(2)
check(any(m["text"] == "Out of reach" for m in of_type(take(), "msg")), "dropping beyond the drop distance is refused")

# Fast transfer (Ctrl+click): a stack in, everything out; half with right click.
def target_of(e):
    return {"u": e.unit_number, "p": eid[e.name], "x": fixed(e.position.x), "y": fixed(e.position.y)}

have = inv.get_item_count("iron-plate")
send({"t": "fast", **target_of(box_chest), "item": "iron-plate", "half": 1})
tick(2)
check(F.inventories[box_chest]["chest"].get_item_count("iron-plate") == 1 + math.ceil(min(have, 100) / 2),
      "Ctrl+right click puts half of a stack in")
send({"t": "fast", **target_of(box_chest), "half": 0})
tick(2)
check(F.inventories[box_chest]["chest"].get_item_count("iron-plate") == 0 and inv.get_item_count("iron-plate") == plates - 1,
      "Ctrl+click with nothing held takes everything out")
take()
have = inv.get_item_count("iron-plate")
send({"t": "fast", **target_of(box_chest), "item": "iron-plate", "n": 5, "hs": 1, "half": 0})
tick(1)
check(F.inventories[box_chest]["chest"].get_item_count("iron-plate") == 5 and inv.get_item_count("iron-plate") == have - 5,
      "Ctrl+click with the held stack's slot (hs) puts that many in, taken from the inventory")
check(len(of_type(take(), "slots")) >= 1, "a Ctrl+click sends the slots at once (the client's hand follows them)")
send({"t": "fast", **target_of(box_chest), "half": 0})
tick(2)

# L7: Factorio builds out of the cursor's stack. The client names the main inventory slot its hand holds the
# item from (`hs`), and that stack pays for a build or a Z, in its own quality; without `hs`, as before (any
# stack of the item: the fake's remove takes the last).
set_slot = lua.eval("function(inv, i, name, count, quality) inv[i].set_stack(name and { name = name, count = count, quality = quality } or nil) end")
slot_now = lua.eval("function(inv, i) local s = inv[i]; if s.valid_for_read then return s.count end return 0 end")
inv_size = lua.eval("function(inv) return #inv end")(inv)
hs_a, hs_b, hs_c = inv_size - 2, inv_size - 1, inv_size
set_slot(inv, hs_a, "wooden-chest", 3, None)
set_slot(inv, hs_b, "wooden-chest", 5, None)
set_slot(inv, hs_c, "wooden-chest", 4, "rare")
def chest_stacks():
    return [slot_now(inv, hs_a), slot_now(inv, hs_b), slot_now(inv, hs_c)]
def chest_at(x, y):
    found = list(puppet.surface.find_entities_filtered(lua.table_from({"name": "wooden-chest", "position": lua.table_from({"x": x, "y": y})})).values())
    return found[0] if found else None
take()
for k in range(3):
    send({"t": "build", "item": "wooden-chest", "x": fixed(-3.5 - k), "y": fixed(3.5), "d": 0, "hs": hs_a})
tick(2)
built_hs = [chest_at(-3.5 - k, 3.5) for k in range(3)]
check(all(built_hs) and chest_stacks() == [0, 5, 4],
      f"L7: builds naming the held stack's slot (hs) take all three from that stack: built {[bool(b) for b in built_hs]}, stacks {chest_stacks()}")
send({"t": "build", "item": "wooden-chest", "x": fixed(-3.5), "y": fixed(4.5), "d": 0, "hs": hs_a})
tick(2)
check(chest_stacks() == [0, 4, 4] and chest_at(-3.5, 4.5),
      f"L7: an hs whose stack is used up still builds, from another normal stack: {chest_stacks()}")
send({"t": "build", "item": "wooden-chest", "x": fixed(-4.5), "y": fixed(4.5), "d": 0, "hs": hs_c})
tick(2)
rare_built = chest_at(-4.5, 4.5)
check(chest_stacks() == [0, 4, 3] and rare_built and rare_built.quality.name == "rare",
      f"L7: the held stack's own quality is what is built (a rare stack held, no q sent): {chest_stacks()}")
send({"t": "build", "item": "wooden-chest", "x": fixed(-5.5), "y": fixed(4.5), "d": 0})
tick(2)
check(sum(chest_stacks()[:2]) == 3 and chest_stacks()[2] == 3 and chest_at(-5.5, 4.5) and chest_at(-5.5, 4.5).quality.name == "normal",
      f"L7: without hs a normal one pays, as before: {chest_stacks()}")
send({"t": "build", "item": "wooden-chest", "x": fixed(-6.5), "y": fixed(4.5), "d": 0, "hs": 1})
tick(2)
check(sum(chest_stacks()[:2]) == 2 and chest_at(-6.5, 4.5),
      f"L7: an hs naming a slot that holds another item is passed over: {chest_stacks()}")
for spot in [(-3.5, 3.5), (-4.5, 3.5), (-5.5, 3.5), (-3.5, 4.5), (-4.5, 4.5), (-5.5, 4.5), (-6.5, 4.5)]:
    if chest_at(*spot):
        chest_at(*spot).destroy()
set_slot(inv, hs_a, "iron-plate", 7, None)
plates_all = inv.get_item_count("iron-plate")
send({"t": "drop", "item": "iron-plate", "x": fixed(2.5), "y": fixed(2.5), "hs": hs_a})
tick(2)
check(slot_now(inv, hs_a) == 6 and inv.get_item_count("iron-plate") == plates_all - 1,
      f"L7: Z naming the held stack's slot takes the plate from that stack: {slot_now(inv, hs_a)}")
send({"t": "fast", **target_of(box_chest), "half": 0})
tick(2)
# Tiles and capsules leave the held stack too (tiles took any stack, a capsule the first found).
set_slot(inv, hs_a, "concrete", 4, None)
set_slot(inv, hs_b, "concrete", 6, None)
concrete_all = inv.get_item_count("concrete")
tile_was = F.surface.get_tile(-4, 5).name
send({"t": "tile", "item": "concrete", "x": fixed(-3.5), "y": fixed(5.5), "n": 1, "hs": hs_a})
tick(2)
check(slot_now(inv, hs_a) == 3 and slot_now(inv, hs_b) == 6 and inv.get_item_count("concrete") == concrete_all - 1,
      f"L7: a tile naming the held stack's slot is paid from that stack: {slot_now(inv, hs_a)}, {slot_now(inv, hs_b)} (was {tile_was})")
F.surface.set_tile(-4, 5, tile_was)
set_slot(inv, hs_a, None, 0, None)
set_slot(inv, hs_b, "grenade", 4, None)
grenades_all = inv.get_item_count("grenade")
thrown = len(F.capsules)
send({"t": "throw", "item": "grenade", "x": fixed(puppet.position.x + 5), "y": fixed(puppet.position.y), "hs": hs_b})
tick(2)
check(slot_now(inv, hs_b) == 3 and inv.get_item_count("grenade") == grenades_all - 1 and len(F.capsules) == thrown + 1,
      f"L7: a capsule naming the held stack's slot is thrown out of that stack: {slot_now(inv, hs_b)} of {grenades_all}")
# One rule for every command spending from the hand (puppet.held_stack / take_held): the held stack pays only
# when it is the item in the quality asked for, normal when none is given; else a stack of that quality.
puppet_mod = lua.eval('package.loaded["scripts.puppet"]')
set_slot(inv, hs_a, "wooden-chest", 3, "rare")
set_slot(inv, hs_b, "wooden-chest", 5, None)
set_slot(inv, hs_c, None, 0, None)
rule =[puppet_mod.held_stack(inv, hs_a, "wooden-chest") is None,
        puppet_mod.held_stack(inv, hs_a, "wooden-chest", "rare") is not None,
        puppet_mod.held_quality(inv, hs_a, "wooden-chest") == "rare"]
puppet_mod.take_held(inv, hs_a, "wooden-chest", 1)
rule.append(chest_stacks()[:2] == [3, 4])
puppet_mod.take_held(inv, hs_a, "wooden-chest", 1, "rare")
rule.append(chest_stacks()[:2] == [2, 4])
send({"t": "fast", **target_of(box_chest), "item": "wooden-chest", "n": 1, "q": "rare", "hs": hs_b, "half": 0})
tick(2)
rule.append(chest_stacks()[:2] == [1, 4])
check(all(rule), f"L7: the held stack pays only in the quality asked for (normal by default), else a stack of that quality: {rule}, {chest_stacks()}")
send({"t": "fast", **target_of(box_chest), "half": 0})
tick(2)
for k in (hs_a, hs_b, hs_c):
    set_slot(inv, k, None, 0, None)
take()

# N2: Ctrl+click on vehicles, as Factorio's fast transfer: a car takes fuel into its fuel slot, ammo
# into its ammo slots and anything else into its trunk; a locomotive takes fuel; a full trunk refuses;
# an empty hand takes the trunk out.
F.trunk_size = 1
fast_car = spawn("car", -4.0, 4.0, force="player")
F.trunk_size = None
fast_loco = spawn("locomotive", -8.0, 2.0, force="player")
car_invs = F.inventories[fast_car]
puppet.insert(lua.table_from({"name": "wood", "count": 40}))
inv.insert(lua.table_from({"name": "firearm-magazine", "count": 20}))  # the main inventory (the character puts ammo in its ammo slots)
puppet.insert(lua.table_from({"name": "iron-plate", "count": 200}))
take()
wood0 = inv.get_item_count("wood")
send({"t": "fast", **target_of(fast_car), "item": "wood", "n": 10})
tick(2)
check(car_invs["fuel"].get_item_count("wood") == 10 and inv.get_item_count("wood") == wood0 - 10,
      "N2: Ctrl+click on a car puts the held fuel into its fuel slot")
check(len(of_type(take(), "slots")) >= 1, "N2: and sends the slots at once, as for a building (the hand and sound follow)")
mags0 = inv.get_item_count("firearm-magazine")
send({"t": "fast", **target_of(fast_car), "item": "firearm-magazine", "n": 10})
tick(2)
check(car_invs["vehicle_ammo"].get_item_count("firearm-magazine") == 10 and inv.get_item_count("firearm-magazine") == mags0 - 10,
      "N2: ammo goes into the car's ammo slots")
plates0 = inv.get_item_count("iron-plate")
send({"t": "fast", **target_of(fast_car), "item": "iron-plate", "n": 100})
tick(2)
check(car_invs["trunk"].get_item_count("iron-plate") == 100 and inv.get_item_count("iron-plate") == plates0 - 100,
      "N2: anything else goes into the car's trunk")
take()
send({"t": "fast", **target_of(fast_car), "item": "iron-plate", "n": 100})
tick(2)
check(inv.get_item_count("iron-plate") == plates0 - 100 and car_invs["trunk"].get_item_count("iron-plate") == 100
      and any("Can't put" in m["text"] for m in of_type(take(), "msg")),
      "N2: a full trunk refuses, and nothing leaves the inventory")
wood1 = inv.get_item_count("wood")
send({"t": "fast", **target_of(fast_loco), "item": "wood", "n": 5})
tick(2)
check(F.inventories[fast_loco]["fuel"].get_item_count("wood") == 5 and inv.get_item_count("wood") == wood1 - 5,
      "N2: a locomotive takes the held fuel")
send({"t": "fast", **target_of(fast_loco), "item": "iron-plate", "n": 5})
tick(2)
check(inv.get_item_count("iron-plate") == plates0 - 100, "N2: a locomotive takes no plates (fuel only)")
send({"t": "fast", **target_of(fast_car), "half": 0})
tick(2)
check(car_invs["trunk"].get_item_count("iron-plate") == 0 and inv.get_item_count("iron-plate") == plates0,
      "N2: Ctrl+click with an empty hand takes the car's trunk out")
check(car_invs["fuel"].get_item_count("wood") == 10, "N2: and leaves the car's fuel in its fuel slot")
# An empty hand never takes fuel (/f3d-perf fast_take): in 2.1 a locomotive's get_output_inventory is its
# fuel slot, and a boiler's (an empty burnt result inventory) leaves the old fallback at inventory 1,
# defines.inventory.chest, which is also its fuel (read in 2.1.24).
fast_boiler = spawn("boiler", -7.5, 6.0, force="player")
F.inventories[fast_boiler]["fuel"].insert(lua.table_from({"name": "wood", "count": 5}))
take()
for who, ent in (("locomotive", fast_loco), ("boiler", fast_boiler)):
    wood2 = inv.get_item_count("wood")
    send({"t": "fast", **target_of(ent), "half": 0})
    tick(2)
    check(F.inventories[ent]["fuel"].get_item_count("wood") == 5 and inv.get_item_count("wood") == wood2,
          f"N2: Ctrl+click with an empty hand on a {who} leaves its fuel")
    check(any(m["text"] == "Nothing to take" for m in of_type(take(), "msg")), f"N2: and the {who} says there is nothing to take")
# A lab's packs and a turret's ammo are still taken, as before (Factorio's wiki: "takes anything the entity has";
# whether it does for these wasn't seen in Factorio).
fast_lab = spawn("lab", -5.5, 9.5, force="player")
fast_turret = spawn("gun-turret", -2.0, 8.0, force="player")
F.inventories[fast_lab]["input"].insert(lua.table_from({"name": "automation-science-pack", "count": 3}))
F.inventories[fast_turret]["turret_ammo"].insert(lua.table_from({"name": "firearm-magazine", "count": 4}))
for who, ent, role, item, n in (("lab", fast_lab, "input", "automation-science-pack", 3),
                                ("gun turret", fast_turret, "turret_ammo", "firearm-magazine", 4)):
    have = inv.get_item_count(item)
    send({"t": "fast", **target_of(ent), "half": 0})
    tick(2)
    check(F.inventories[ent][role].get_item_count(item) == 0 and (role == "turret_ammo" or inv.get_item_count(item) == have + n),  # (ammo goes to the ammo slots)
          f"N2: Ctrl+click with an empty hand still takes a {who}'s {item}: left {F.inventories[ent][role].get_item_count(item)}, main {have} -> {inv.get_item_count(item)}")
take()
fast_lab.destroy()
fast_turret.destroy()
g.storage.f3d_perf = lua.table_from({"fast_take": False})
send({"t": "fast", **target_of(fast_boiler), "half": 0})
tick(2)
check(F.inventories[fast_boiler]["fuel"].get_item_count("wood") == 0, "N2: /f3d-perf fast_take off: the boiler's fuel taken, as before")
g.storage.f3d_perf = None
take()
fast_boiler.destroy()
fast_car.destroy()
fast_loco.destroy()

# Copy and paste settings (Shift+right / left click): an assembler's recipe.
asm_a = spawn("assembling-machine-1", 6.5, 6.5, force="player")
asm_b = spawn("assembling-machine-1", 9.5, 6.5, force="player")
asm_a.set_recipe("iron-gear-wheel")
send({"t": "paste_settings", "f": [asm_a.unit_number, eid[asm_a.name], fixed(6.5), fixed(6.5)], **target_of(asm_b)})
tick(2)
check(asm_b.get_recipe() and asm_b.get_recipe()[0].name == "iron-gear-wheel", "paste_settings copies the recipe (2.x: recipe, quality)")

# Flip (H / V).
send({"t": "flip", **target_of(asm_b), "v": 0})
tick(2)
check(asm_b.mirroring is True and any(m["e"][0] == asm_b.unit_number for m in of_type(take(), "upd")), "flip mirrors the entity and sends its upd")

# Building a ghost (Shift+click) and a flipped entity.
send({"t": "build", "item": "assembling-machine-1", "x": fixed(14.5), "y": fixed(14.5), "d": 0, "ghost": 1})
tick(2)
adds = [m["e"] for m in of_type(take(), "add")]
check(any(a[1] == eid["entity-ghost"] and a[5].get("gh") == eid["assembling-machine-1"] for a in adds),
      f"build with ghost = 1 places a ghost, without the item and out of reach: {adds}")

# The clipboard: copy an area, see its entities, paste them as ghosts; cut marks the area too.
send({"t": "copy", "x1": fixed(5), "y1": fixed(5), "x2": fixed(11), "y2": fixed(8), "cut": 0, "bp": 0})
tick(2)
clip = of_type(take(), "clip")
check(clip and sorted(e[0] for e in clip[-1]["l"]) == [eid["assembling-machine-1"]] * 2, f"copy sends the clipboard's entities: {clip}")
# Owner's #21: the blueprint holds map positions; the client needs them around the copy's middle.
xs = [e[1] for e in clip[-1]["l"]] if clip else [0]
ys = [e[2] for e in clip[-1]["l"]] if clip else [0]
check(clip and abs(min(xs) + max(xs)) <= 1 and abs(min(ys) + max(ys)) <= 1 and max(map(abs, xs + ys)) < 256 * 8,
      f"the clipboard's positions are around its centre, not on the map: {clip[-1]['l'] if clip else clip}")
send({"t": "paste", "x": fixed(20.5), "y": fixed(20.5), "d": 0})
tick(2)
adds = [m["e"] for m in of_type(take(), "add") if m["e"][1] == eid["entity-ghost"]]
check(len(adds) == 2, f"paste places the clipboard's ghosts: {adds}")
send({"t": "copy", "x1": fixed(5), "y1": fixed(5), "x2": fixed(11), "y2": fixed(8), "cut": 1, "bp": 0})
tick(2)
check(F.decon_marks[asm_a] is True and F.decon_marks[asm_b] is True, "cut marks the area for deconstruction")
send({"t": "copy", "x1": fixed(14), "y1": fixed(14), "x2": fixed(27), "y2": fixed(27), "cut": 1, "bp": 0})
tick(2)
dels = {d["u"] for d in of_type(take(), "del")}
check(all(a[0] in dels for a in adds), f"cut (Ctrl+X) over ghosts removes them and sends their del (owner's #20): {dels}")
send({"t": "copy", "x1": fixed(5), "y1": fixed(5), "x2": fixed(11), "y2": fixed(8), "cut": 0, "bp": 1})
tick(2)
bp_slots = [i for i in range(1, 81) if inv[i].valid_for_read and inv[i].name == "blueprint"]
check(len(bp_slots) >= 1 and any(m["text"] == "Blueprint added to the inventory" for m in of_type(take(), "msg")),
      "Alt+B's area becomes a blueprint in the inventory")
# to: Select new contents, into that blueprint, its name kept.
inv[bp_slots[0]].label = "Keep me"
before = len([i for i in range(1, 81) if inv[i].valid_for_read and inv[i].name == "blueprint"])
send({"t": "copy", "x1": fixed(5), "y1": fixed(5), "x2": fixed(8), "y2": fixed(8), "cut": 0, "bp": 1, "to": bp_slots[0]})
tick(2)
msgs = take()
ok = of_type(msgs, "bp_ok")
after = len([i for i in range(1, 81) if inv[i].valid_for_read and inv[i].name == "blueprint"])
check(ok and ok[-1]["i"] == bp_slots[0] and ok[-1].get("new") == 1 and after == before and inv[bp_slots[0]].label == "Keep me"
      and len(inv[bp_slots[0]].get_blueprint_entities()) >= 1, f"copy with to: the same blueprint gets the new contents, its name kept: {ok}")
send({"t": "copy", "x1": fixed(-30), "y1": fixed(-30), "x2": fixed(-29), "y2": fixed(-29), "cut": 0, "bp": 0})
tick(2)
check(any(m["text"] == "Nothing to copy there" for m in of_type(take(), "msg")), "copying an empty area says so")

# Alt-mode: recipe icons near the focus, and every filter of a filter inserter (owner's #23).
fins = spawn("fast-inserter", 3.5, 3.5, force="player")
fins.set_filter(2, "iron-plate")
fins.set_filter(4, "copper-plate")
fins.set_filter(5, "coal")
send({"t": "alt", "on": 1})
tick(2)
ai = of_type(take(), "ai")
check(ai and [asm_b.unit_number, "recipe", "iron-gear-wheel"] in ai[-1]["l"], f"Alt-mode lists recipe icons: {ai[-1:]}")
check(ai and [fins.unit_number, "item", "iron-plate", ["copper-plate", "coal"]] in ai[-1]["l"],
      f"a filter inserter's Alt-mode icon carries all its filters, the first even when slot 1 is empty: {[r for r in ai[-1]['l'] if r[0] == fins.unit_number] if ai else ai}")
fins.destroy()
send({"t": "alt", "on": 0})
tick(70)
check(not of_type(take(), "ai"), "Alt-mode off stops the icons")

# Issue #9: Alt-mode's icon rides on the record (no cap, no scan); a furnace (its recipe comes from
# what is put in) and circuit-wired machines are watched, `aiu` carrying what changed; a window
# closed in the real game sends the icon too.
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
asm_r = spawn("assembling-machine-1", 14.5, 14.5, force="player")
asm_r.set_recipe("iron-gear-wheel")
alt_furnace = spawn("stone-furnace", 17.0, 14.0, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": asm_r}))
F["raise"]("script_raised_built", lua.table_from({"entity": alt_furnace}))
tick(2)
adds = {m["e"][0]: m["e"] for m in of_type(take(), "add")}
rec_asm, rec_furnace = adds.get(asm_r.unit_number), adds.get(alt_furnace.unit_number)
check(rec_asm and len(rec_asm) > 5 and rec_asm[5].get("ai") == ["recipe", "iron-gear-wheel"],
      f"#9: an assembler's record carries its Alt-mode icon (extra.ai): {rec_asm}")
check(rec_furnace and (len(rec_furnace) == 5 or "ai" not in rec_furnace[5]), f"#9: a furnace that never smelted has none: {rec_furnace}")
alt_mode_mod = g.package.loaded["scripts.alt_mode"]
check(g.storage.f3d.altw[alt_furnace.unit_number] and not g.storage.f3d.altw[asm_r.unit_number],
      "#9: the furnace is watched, the unwired assembler isn't")


def between_chunk_refreshes():
    """To 30 ticks past world.lua's periodic chunk refresh (every 300 ticks, and which chunk comes
    next is Lua's table order, different each run). A refresh of the furnace's chunk tells the
    client in its record, and the watch then has nothing to send: 250 ticks from here have none."""
    send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
    tick((30 - int(lua.eval("game.tick"))) % 300)
    send({"t": "hello", "v": 1, "sid": "s1", "w": 1})


between_chunk_refreshes()
fill(alt_furnace, "input", "iron-ore", 3)
tick(250)
aiu = [row for m in of_type(take(), "aiu") for row in m["l"]]
check([alt_furnace.unit_number, "recipe", "iron-plate"] in aiu, f"#9: the furnace taking ore sends its new icon in aiu: {aiu}")
between_chunk_refreshes()
F.inventories[alt_furnace]["input"].remove(lua.table_from({"name": "iron-ore", "count": 3}))
tick(250)
aiu = [row for m in of_type(take(), "aiu") for row in m["l"]]
check(not any(row[0] == alt_furnace.unit_number for row in aiu),
      f"J2: and keeping its last recipe's icon when the ore runs out, as Factorio (previous_recipe): {aiu}")
check(to_py(alt_mode_mod.icon(alt_furnace)) == ["recipe", "iron-plate"], "J2: an idle furnace's icon is the recipe it last made")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(250)
check(not of_type(take(), "aiu"), "#9: nothing more while nothing changes")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
asm_r.set_recipe("transport-belt")  # no event (a script, or the real game's window still open)
F["raise"]("on_gui_closed", lua.table_from({"entity": asm_r, "player_index": 1}))
tick(1)
aiu = [row for m in of_type(take(), "aiu") for row in m["l"]]
check([asm_r.unit_number, "recipe", "transport-belt"] in aiu, f"#9: a window closed in the real game sends the machine's icon: {aiu}")
# L10: 2.1 makes the machine's fluid storages from its recipe, each filtered to its fluid: which fluid goes in or out
# where rides with the mask (the fake's two storages and their connections, as 2.1.24's refinery reports them).
F.set_fluid(asm_r, 2, None)
asm_x, asm_y = asm_r.position.x, asm_r.position.y
F.fluid_conns[asm_r] = lua.table_from({
    1: {"filter": "crude-oil", "conns": [{"connection_type": "normal", "flow_direction": "input",
                                         "position": {"x": asm_x + 1, "y": asm_y + 1}, "target_position": {"x": asm_x + 1, "y": asm_y + 2}}]},
    2: {"filter": "petroleum-gas", "conns": [{"connection_type": "normal", "flow_direction": "output",
                                             "position": {"x": asm_x - 1, "y": asm_y - 1}, "target_position": {"x": asm_x - 1, "y": asm_y - 2}},
                                            {"connection_type": "underground", "flow_direction": "output",
                                             "position": {"x": asm_x, "y": asm_y}, "target_position": {"x": asm_x, "y": asm_y}}]},
}, recursive=True)
asm_r.set_recipe("oil-processing")
F["raise"]("on_gui_closed", lua.table_from({"entity": asm_r, "player_index": 1}))
tick(1)
fa = [row for m in of_type(take(), "aiu") for row in m.get("fa", [])]
l10_conns = [[1, 1, 8, "i", "crude-oil"], [-1, -1, 0, "o", "petroleum-gas"]]
check([asm_r.unit_number, 3, l10_conns] in fa,
      f"#9 part 2, L10: a recipe taking and making fluid sends its arrows' mask (fa 3) and each connection's fluid: {fa}")
l10_rec = to_py(g.package.loaded["scripts.world"].record(asm_r))
check(isinstance(l10_rec, list) and len(l10_rec) > 5 and l10_rec[5].get("fc") == l10_conns,
      f"L10: and its record carries them (fc): {l10_rec}")
g.storage.f3d_perf = lua.table_from({"fluid_icons": False})
check(g.package.loaded["scripts.alt_mode"].connections(asm_r) is None, "fluid_icons off: no connections read")
g.storage.f3d_perf = None
asm_r.set_recipe("iron-gear-wheel")
F["raise"]("on_gui_closed", lua.table_from({"entity": asm_r, "player_index": 1}))
tick(1)
fa = [row for m in of_type(take(), "aiu") for row in m.get("fa", [])]
check([asm_r.unit_number, 0] in fa, f"#9 part 2: and none again with an item recipe: {fa}")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
asm_r.destroy()
alt_furnace.destroy()
tick(250)
check(not g.storage.f3d.altw[alt_furnace.unit_number] if g.storage.f3d.altw else True, "#9: a watched machine gone is forgotten after a round")
take()

# The drill's fluid part: a mining drill with a fluid box (2.1.24 gives one over uranium ore, for its sulfuric acid)
# takes fluid in, its record's `fa` 1 (the client draws its `-wet` model); without one none. Its own box says
# (`fluids_count`), not what it mines: the box stays when the ore runs out, and an iron drill with one uranium tile in
# its area has one too.
wet_ore = spawn("uranium-ore", 60.5, 60.5, amount=500)
dry_ore = spawn("iron-ore", 70.5, 60.5, amount=500)
wet_drill = spawn("electric-mining-drill", 60.5, 60.5, force="player")
dry_drill = spawn("electric-mining-drill", 70.5, 60.5, force="player")
wet_drill.mining_target = wet_ore
dry_drill.mining_target = dry_ore
F.set_fluids_count(wet_drill, 1)
check(alt_mode_mod.arrows(wet_drill) == 1 and alt_mode_mod.arrows(dry_drill) is None,
      "a drill with a fluid box (fluids_count 1): fa 1; with none (0): nil")
F.set_fluids_count(wet_drill, 0)
check(alt_mode_mod.arrows(wet_drill) is None,
      "a drill mining uranium ore whose box is gone (fluids_count 0): nil, the box decides, not the target")
F.set_fluids_count(wet_drill, 1)
mixed_drill = spawn("electric-mining-drill", 80.5, 60.5, force="player")
mixed_ore = spawn("iron-ore", 80.5, 60.5, amount=500)
mixed_wet = spawn("uranium-ore", 81.5, 61.5, amount=500)
mixed_drill.mining_target = mixed_ore
F.set_fluids_count(mixed_drill, 1)
check(alt_mode_mod.arrows(mixed_drill) == 1,
      "the mixed area: a drill mining iron ore (no fluid needed) with one uranium tile in its area has its box: fa 1")
check(alt_mode_mod.arrows(g.F.spawn("burner-mining-drill", 90.5, 90.5, lua.table_from({"force": "player"}))) is None,
      "a burner drill, no fluid box: nil")
for e in (mixed_drill, mixed_ore, mixed_wet):
    e.destroy()
wet_rec = to_py(g.package.loaded["scripts.world"].record(wet_drill))
dry_rec = to_py(g.package.loaded["scripts.world"].record(dry_drill))
check(isinstance(wet_rec, list) and len(wet_rec) > 5 and wet_rec[5].get("fa") == 1,
      f"the wet drill's record carries fa 1: {wet_rec}")
check(isinstance(dry_rec, list) and (len(dry_rec) == 5 or "fa" not in dry_rec[5]), f"the dry drill's none: {dry_rec}")
for e in (wet_drill, dry_drill, wet_ore, dry_ore):
    e.destroy()
take()

# Placing an electric drill over uranium ore, as Factorio 2.1.24 does (measured with can_place_entity): refused with
# Factorio's own reason until the force can mine with fluid (the "Uranium mining" research), even with iron ore beside
# it; built once it can. The fake's can_place_entity holds that rule.
# (A free square within reach: earlier checks left a car, a biter and machines round the character.)
ux, uy = next((math.floor(puppet.position.x) + dx, math.floor(puppet.position.y) + dy)
              for dx in range(-7, 8) for dy in range(-7, 8)
              if not any(e.type != "resource" and abs(e.position.x - (math.floor(puppet.position.x) + dx + 0.5)) < 4
                         and abs(e.position.y - (math.floor(puppet.position.y) + dy + 0.5)) < 4 for e in F.surface.entities.values()))
u_ores = [spawn("uranium-ore", ux + dx + 0.5, uy + dy + 0.5, amount=500) for dx in (-1, 0, 1) for dy in (-1, 0, 1)]
u_iron = spawn("iron-ore", ux + 2.5, uy + 2.5, amount=500)
g.game.forces.player.mining_with_fluid = False
puppet.insert(lua.table_from({"name": "electric-mining-drill", "count": 2}))
take()
send({"t": "build", "item": "electric-mining-drill", "x": ux * 256 + 128, "y": uy * 256 + 128, "d": 0})
tick(1)
said = texts(take())
drills_at = lambda: [e for e in F.surface.entities.values() if e.name == "electric-mining-drill"
                     and abs(e.position.x - (ux + 0.5)) < 0.1 and abs(e.position.y - (uy + 0.5)) < 0.1]
check(not drills_at() and "Uranium mining not researched." in said,
      f"an electric drill over uranium ore (iron beside it) before Uranium mining: refused in Factorio's words: {said}")
g.game.forces.player.mining_with_fluid = True
send({"t": "build", "item": "electric-mining-drill", "x": ux * 256 + 128, "y": uy * 256 + 128, "d": 0})
tick(1)
said = texts(take())
check(len(drills_at()) == 1 and not any("place" in t or "Uranium" in t for t in said),
      f"and once the force can mine with fluid it is built, waiting for its sulfuric acid as in Factorio: {said}")
g.game.forces.player.mining_with_fluid = False
for e in drills_at() + u_ores + [u_iron]:
    e.destroy()
take()

# J6: Factorio's Alt-mode shows what is in a chest. While the client says Alt-mode is on (`altc`), the
# chests in the focus square are read in rounds and `ac` carries those whose icons changed: the kinds
# held most, most first, up to four; [unit] when none; nothing while off.
j6_start = int(lua.eval("game.tick"))
ac_chest = spawn("wooden-chest", 20.5, 10.5, force="player")
fill(ac_chest, "chest", "coal", 50)
fill(ac_chest, "chest", "iron-plate", 80)
fill(ac_chest, "chest", "stone", 5)
fill(ac_chest, "chest", "copper-plate", 5)
fill(ac_chest, "chest", "wood", 1)
ac_empty = spawn("wooden-chest", 21.5, 10.5, force="player")
focus_before = to_py(g.storage.f3d.focus)
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
send({"t": "focus", "x": fixed(18), "y": fixed(10), "r": 32})
tick(1)
take()
check(to_py(alt_mode_mod.contents(ac_chest)) == ["iron-plate", "coal", "copper-plate", "stone"],
      f"J6: a chest's icons are its four most held kinds, most first: {to_py(alt_mode_mod.contents(ac_chest))}")
send({"t": "altc", "on": 1, "g": 3})
tick(5)
ac_rows = {r[0]: r for m in of_type(take(), "ac") if m["g"] == 3 for r in m["l"]}
check(ac_rows.get(ac_chest.unit_number) == [ac_chest.unit_number, "iron-plate", ["coal", "copper-plate", "stone"]]
      and ac_empty.unit_number not in ac_rows,
      f"J6: Alt-mode on: `ac` lists the chests in the focus square with something in them: {ac_rows}")
F.inventories[ac_chest]["chest"].remove(lua.table_from({"name": "iron-plate", "count": 80}))
fill(ac_empty, "chest", "iron-gear-wheel", 10)
tick(70)
ac_rows = [r for m in of_type(take(), "ac") for r in m["l"]]
check(sorted(ac_rows) == sorted([[ac_chest.unit_number, "coal", ["copper-plate", "stone", "wood"]], [ac_empty.unit_number, "iron-gear-wheel"]]),
      f"J6: the next round sends only the chests that changed: {ac_rows}")
for item, n in (("coal", 50), ("stone", 5), ("copper-plate", 5), ("wood", 1)):
    F.inventories[ac_chest]["chest"].remove(lua.table_from({"name": item, "count": n}))
gone_unit = ac_empty.unit_number
ac_empty.destroy()
tick(70)
ac_rows = [r for m in of_type(take(), "ac") for r in m["l"]]
check(sorted(ac_rows) == sorted([[ac_chest.unit_number], [gone_unit]]), f"J6: an emptied chest and one gone are [unit]: {ac_rows}")
send({"t": "altc", "on": 0})
fill(ac_chest, "chest", "coal", 7)
tick(130)
check(not of_type(take(), "ac") and not g.storage.f3d.altc, "J6: Alt-mode off: no more `ac`, nothing kept")
ac_chest.destroy()
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
send({"t": "focus", "x": fixed(focus_before["x"]), "y": fixed(focus_before["y"]), "r": int(focus_before["r"])})
while (int(lua.eval("game.tick")) - j6_start) % 1200:  # the checks after keep the tick phase they were written at
    if int(lua.eval("game.tick")) % 100 == 0:
        send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
    tick(1)

# K1, K2: in the same rounds, the modules in machines and the science packs in labs (`am`): one icon
# a module in slot order with its quality when not normal, a lab's packs a slot each; [unit] when
# none; nothing read with /f3d-perf alt_machines off.
k_start = int(lua.eval("game.tick"))
am_asm = spawn("assembling-machine-1", 24.5, 4.5, force="player")
F.inventories[am_asm]["modules"].insert(lua.table_from({"name": "speed-module", "count": 1}))
F.inventories[am_asm]["modules"].insert(lua.table_from({"name": "speed-module", "count": 1, "quality": "rare"}))
am_lab = spawn("lab", 28.5, 4.5, force="player")
fill(am_lab, "input", "automation-science-pack", 5)
fill(am_lab, "input", "logistic-science-pack", 3)
am_beacon = spawn("beacon", 24.5, 16.5, force="player")
fill(am_beacon, "modules", "speed-module", 2)
am_idle = spawn("assembling-machine-1", 28.5, 16.5, force="player")
focus_before = to_py(g.storage.f3d.focus)
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
send({"t": "focus", "x": fixed(18), "y": fixed(10), "r": 32})
tick(1)
take()
send({"t": "altc", "on": 1, "g": 4})
tick(5)
am_msgs = [m for m in of_type(take(), "am") if m["g"] == 4]
am_rows = {r[0]: r for m in am_msgs for r in m["l"]}
check(am_rows.get(am_asm.unit_number) == [am_asm.unit_number, ["speed-module", ["speed-module", "rare"]]]
      and am_rows.get(am_lab.unit_number) == [am_lab.unit_number, 0, ["automation-science-pack", "logistic-science-pack"]]
      and am_rows.get(am_beacon.unit_number) == [am_beacon.unit_number, ["speed-module", "speed-module"]]
      and am_idle.unit_number not in am_rows,
      f"K1, K2: Alt-mode on: `am` lists the machines' modules (quality kept) and the lab's packs, not an empty machine: {am_rows}")
F.inventories[am_lab]["input"].remove(lua.table_from({"name": "automation-science-pack", "count": 5}))
F.inventories[am_lab]["input"].remove(lua.table_from({"name": "logistic-science-pack", "count": 3}))
fill(am_idle, "modules", "speed-module", 1)
tick(70)
am_rows = [r for m in of_type(take(), "am") for r in m["l"]]
check(sorted(am_rows, key=str) == sorted([[am_lab.unit_number], [am_idle.unit_number, ["speed-module"]]], key=str),
      f"K2: the next round sends only what changed, a lab run out of packs as [unit]: {am_rows}")
g.storage.f3d_perf = lua.table_from({"alt_machines": False})
tick(70)
am_rows = [r for m in of_type(take(), "am") for r in m["l"]]
check(sorted(am_rows, key=str) == sorted([[am_asm.unit_number], [am_beacon.unit_number], [am_idle.unit_number]], key=str),
      f"K1: /f3d-perf alt_machines off: the machines aren't read, their icons go: {am_rows}")
g.storage.f3d_perf = None
send({"t": "altc", "on": 0})
tick(70)
check(not of_type(take(), "am") and not g.storage.f3d.altc, "K1: Alt-mode off: no more `am`")
# K1's leftover: ammo turrets' ammo and locomotives' fuel in the same rounds, one icon a filled slot, where a
# lab's packs go in the row; an empty turret none; the locomotive read where it stands now; nothing read with
# /f3d-perf alt_ammo_fuel off.
am_turret = spawn("gun-turret", 20.0, 4.0, force="player")
F.inventories[am_turret]["turret_ammo"].insert(lua.table_from({"name": "firearm-magazine", "count": 10}))
am_bare = spawn("gun-turret", 20.0, 8.0, force="player")
am_loco = spawn("locomotive", 21.0, 20.0, force="player")
F.inventories[am_loco]["fuel"].insert(lua.table_from({"name": "wood", "count": 5}))
am_wagon = spawn("cargo-wagon", 21.0, 26.0, force="player")
for item, n in (("copper-plate", 50), ("iron-plate", 200), ("coal", 80), ("stone", 10), ("wood", 5), ("iron-ore", 80)):
    F.inventories[am_wagon]["cargo"].insert(lua.table_from({"name": item, "count": n}))
# Locomotives' fuel is read only when the client asks (`lf`, --loco-fuel-icons=on); wagons' cargo always.
send({"t": "altc", "on": 1, "g": 4})
tick(5)
am_rows = {r[0]: r for m in of_type(take(), "am") if m["g"] == 4 for r in m["l"]}
check(am_rows.get(am_wagon.unit_number) == [am_wagon.unit_number, 0, ["iron-plate", "coal", "iron-ore", "copper-plate"]]
      and am_loco.unit_number not in am_rows and am_turret.unit_number in am_rows,
      f"wagon items: `am` lists a cargo wagon's four most-stacked kinds, most first; no locomotive fuel without `lf`: {am_rows}")
send({"t": "altc", "on": 1, "g": 5, "lf": 1})
tick(5)
am_rows = {r[0]: r for m in of_type(take(), "am") if m["g"] == 5 for r in m["l"]}
check(am_rows.get(am_turret.unit_number) == [am_turret.unit_number, 0, ["firearm-magazine"]]
      and am_rows.get(am_loco.unit_number) == [am_loco.unit_number, 0, ["wood"]] and am_bare.unit_number not in am_rows
      and am_rows.get(am_wagon.unit_number) == [am_wagon.unit_number, 0, ["iron-plate", "coal", "iron-ore", "copper-plate"]]
      and am_rows.get(am_asm.unit_number) == [am_asm.unit_number, ["speed-module", ["speed-module", "rare"]]],
      f"K1: Alt-mode on: `am` lists a gun turret's ammo and a locomotive's fuel beside the machines, not an empty turret: {am_rows}")
F.inventories[am_turret]["turret_ammo"].remove(lua.table_from({"name": "firearm-magazine", "count": 10}))
F.inventories[am_bare]["turret_ammo"].insert(lua.table_from({"name": "firearm-magazine", "count": 3, "quality": "rare"}))
tick(70)
am_rows = [r for m in of_type(take(), "am") for r in m["l"]]
check(sorted(am_rows, key=str) == sorted([[am_turret.unit_number], [am_bare.unit_number, 0, [["firearm-magazine", "rare"]]]], key=str),
      f"K1: the next round sends only what changed: a turret out of ammo as [unit], another's ammo with its quality: {am_rows}")
g.storage.f3d_perf = lua.table_from({"alt_ammo_fuel": False})
tick(70)
am_rows = [r for m in of_type(take(), "am") for r in m["l"]]
check(sorted(am_rows, key=str) == sorted([[am_bare.unit_number], [am_loco.unit_number], [am_wagon.unit_number]], key=str),
      f"K1: /f3d-perf alt_ammo_fuel off: turrets and locomotives aren't read, their icons go, the machines' stay: {am_rows}")
g.storage.f3d_perf = None
send({"t": "altc", "on": 0})
tick(70)
take()
for e in (am_asm, am_lab, am_beacon, am_idle, am_turret, am_bare, am_loco, am_wagon):
    e.destroy()
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
send({"t": "focus", "x": fixed(focus_before["x"]), "y": fixed(focus_before["y"]), "r": int(focus_before["r"])})
while (int(lua.eval("game.tick")) - k_start) % 1200:  # the checks after keep the tick phase they were written at
    if int(lua.eval("game.tick")) % 100 == 0:
        send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
    tick(1)
take()

# Chat: the client's line goes to the game's chat; players' lines come back.
F.printed = lua.table()
send({"t": "chat", "text": "hello factory"})
tick(2)
check(any("hello factory" in str(p) and "[Zenith]" in str(p) for p in F.printed.values()), f"chat prints in the game as [Zenith]: {list(F.printed.values())}")
check(any(m["text"] == "hello factory" and m["from"] == "Zenith" for m in of_type(take(), "chat")), "and echoes to the client, from Zenith")

# Statistics.
send({"t": "stats", "kind": "item", "prec": 2})
tick(2)
st = of_type(take(), "stats")
check(st and st[-1]["l"][0][0] == "iron-plate" and st[-1]["l"][0][3] == 120, f"production statistics, most first: {st[-1:]}")
send({"t": "stats", "kind": "kill", "prec": 1})
tick(2)
st = of_type(take(), "stats")
check(st and st[-1]["kind"] == "kill" and st[-1]["l"][0][0] == "small-biter", "kill statistics")
send({"t": "stats", "kind": "build", "prec": 1})
send({"t": "stats", "kind": "pollution", "prec": 3, "si": 0, "g": []})
send({"t": "stats", "kind": "item", "prec": 2, "g": ["iron-gear-wheel"]})
tick(6)  # answered under the work budget (requests.lua), a few a tick
st = of_type(take(), "stats")
build = [m for m in st if m["kind"] == "build"]
poll = [m for m in st if m["kind"] == "pollution"]
items = [m for m in st if m["kind"] == "item"]
check(build and build[-1]["l"][0][:4] == ["transport-belt", 4, 0.2, 40] and build[-1]["si"] == 1,
      f"building counts: built and removed, on the character's surface: {build[-1:]}")
check(poll and poll[-1]["si"] == 0 and {r[0] for r in poll[-1]["l"]} == {"assembling-machine-1", "grass-1"}
      and poll[-1]["gr"] and len(poll[-1]["gr"][0][1]) == 60 and len(poll[-1]["gr"][0][2]) == 60,
      f"pollution over all surfaces, with graph lines for the busiest: {poll[-1:]}")
check(items and [g[0] for g in items[-1]["gr"]] == ["iron-gear-wheel"] and items[-1]["gr"][0][1][0] == 1,
      f"graph lines for the items asked for: {items[-1:]}")

# An electric network's statistics from one of its poles, with its accumulators' storage.
epole = spawn("small-electric-pole", 30.5, 30.5, force="player")
send(dict(open_cmd(epole), t="stats", kind="electric", prec=1))
tick(2)
st = [m for m in of_type(take(), "stats") if m["kind"] == "electric"]
check(st and {r[0] for r in st[-1]["l"]} >= {"assembling-machine-1", "steam-engine"} and "si" not in st[-1]
      and st[-1].get("st") == [["accumulator", 1250000, 2500000]],
      f"electric network statistics: consumption, production and accumulator storage (st): {st[-1:]}")
check(st and st[-1].get("ef") == [500, 1000, 500, 2000, 2500000, 5000000],
      f"and the network's last update (flow_last_tick) for the summary bars: {st[-1:]}")
epole.destroy()
send({"t": "stats", "kind": "item", "prec": 9})
tick(2)
st = of_type(take(), "stats")
check(st and st[-1]["prec"] == 9 and st[-1]["l"][0][0] == "iron-plate" and st[-1]["l"][0][3] == 120,
      f"All (prec 9): rows by all-time totals: {st[-1:]}")

# The Bonuses and Permissions windows.
send({"t": "bonuses"})
send({"t": "perms"})
tick(2)
msgs = take()
bonus = of_type(msgs, "bonus")
kinds = {r[0]: r for r in bonus[-1]["l"]} if bonus else {}
check(kinds.get("inserter_stack_size_bonus", [0, 0])[1] == 1 and kinds.get("ammo_damage:bullet", [0, 0, 0])[1:] == [0.8, ["firearm-magazine"]]
      and kinds.get("turret_attack:gun-turret", [0, 0])[1] == 0.4 and "gun_speed:bullet" not in kinds,
      f"bonus: the force's bonuses that aren't zero, with their items: {bonus[-1:]}")
perms = of_type(msgs, "perms")
check(perms and perms[-1]["l"][0][0] == "Default" and len(perms[-1]["l"]) == 2, f"perms: the permission groups and their players: {perms[-1:]}")

# Factoriopedia: the index, and pages.
send({"t": "pedia_index"})
tick(3)
pidx = of_type(take(), "pidx")
entries = [r for m in pidx for r in m["l"]]
check(pidx and pidx[0]["part"] == 1 and pidx[0]["g"] and ["item", "iron-plate"] == [r for r in entries if r[1] == "iron-plate"][0][:2]
      and any(r[0] == "technology" and r[1] == "automation" for r in entries)
      and any(r[0] == "quality" and r[1] == "normal" for r in entries)
      and any(r[0] == "planet" and r[1] == "vulcanus" for r in entries)
      and not any(r[0] == "entity" and r[1] == "transport-belt" for r in entries),
      f"pidx lists items, technologies, qualities, planets; a placed entity is on its item's page: {entries[:8]}")
send({"t": "pedia", "kind": "item", "name": "transport-belt"})
send({"t": "pedia", "kind": "recipe", "name": "iron-gear-wheel"})
send({"t": "pedia", "kind": "technology", "name": "automation"})
send({"t": "pedia", "kind": "planet", "name": "nauvis"})
send({"t": "pedia", "kind": "item", "name": "no-such-item"})
tick(6)  # answered under the work budget (requests.lua), a few a tick
pages = {(m["kind"], m["name"]): m for m in of_type(take(), "pedia")}
belt = pages.get(("item", "transport-belt"), {}).get("d", {})
check(belt.get("made") == ["transport-belt"] and belt.get("entity", {}).get("type") == "transport-belt"
      and belt.get("used") == [], f"an item's page: made by, used in, the entity it builds: {belt}")
gear = pages.get(("recipe", "iron-gear-wheel"), {}).get("d", {})
check(gear.get("ing") == [["item", "iron-plate", 2]] and gear.get("unlocked") == ["automation"]
      and "assembling-machine-1" in gear.get("made_in", []) and gear.get("time") == 0.5,
      f"a recipe's page: ingredients, made in, unlocked by: {gear}")
auto = pages.get(("technology", "automation"), {}).get("d", {})
check(auto.get("effects") == [["unlock-recipe", "iron-gear-wheel", 0]] and auto.get("cost") == [["automation-science-pack", 1]],
      f"a technology's page: {auto}")
nauvis = pages.get(("planet", "nauvis"), {}).get("d", {})
check(["vulcanus", 15000] in nauvis.get("links", []) and ["solar-system-edge", 100000] in nauvis.get("links", []),
      f"a planet's page: its connections: {nauvis}")
check(pages.get(("item", "no-such-item"), {}).get("found") == 0, "an unknown page answers found 0")

# The logistic networks window (L).
F.lnets = lua.table_from({"nauvis": lua.table_from([F.make_network(7, lua.table_from([1, 2, 3, 4]),
                                                                    lua.table_from([lua.table_from(["iron-plate", 50])]))])})
send({"t": "lnets"})
send({"t": "lnet", "id": 7})
send({"t": "lnet", "id": 99})
tick(6)  # answered under the work budget (requests.lua), a few a tick
msgs = take()
nets = of_type(msgs, "lnets")
check(nets and nets[-1]["l"] == [[7, 1, "nauvis", [1, 2], [3, 4], 0, 0, 0, 0, 0, 0, ""]], f"lnets lists every network: {nets[-1:]}")
one = {m["id"]: m for m in of_type(msgs, "lnet")}
check(one.get(7, {}).get("items") == [["iron-plate", 50]] and one.get(99, {}).get("found") == 0,
      f"lnet: one network's contents, or found 0: {one}")
F.lnets = lua.table()

# Alerts: computed for the force from events and scans.
turret = spawn("gun-turret", 6.0, 6.0, force="player")
asm_off = spawn("assembling-machine-1", 9.5, 9.5, force="player")
asm_off.status = g.defines.entity_status.no_power
asm_off.electric_network_id = None
asm_dark = spawn("assembling-machine-1", 9.5, 13.5, force="player")  # on a network with no power
asm_dark.status = g.defines.entity_status.no_power
asm_dark.electric_network_id = 3
asm_low = spawn("assembling-machine-1", 13.5, 9.5, force="player")
asm_low.status = g.defines.entity_status.low_power
hurt = spawn("wooden-chest", 12.5, 12.5, force="player")
F["raise"]("on_entity_damaged", lua.table_from({"entity": hurt, "force": g.game.forces.enemy, "final_damage_amount": 10}))
# A turret's hit: a firing cue from the turret to its target, and blood on the biter.
take()
biter = spawn("small-biter", 8.0, 8.0, force="enemy")
turret.shooting_target = biter
F["raise"]("on_entity_damaged", lua.table_from({"entity": biter, "cause": turret, "force": g.game.forces.player, "final_damage_amount": 5}))
F["raise"]("on_entity_damaged", lua.table_from({"entity": biter, "cause": turret, "force": g.game.forces.player, "final_damage_amount": 5}))
msgs = take()
tf = of_type(msgs, "tf")
check(len(tf) == 1 and tf[0]["u"] == turret.unit_number and tf[0]["x"] == 8 * 256 and set(tf[0]) <= {"t", "k", "u", "x", "y"},
      f"a turret's hit sends one firing cue per interval, aimed at its target: {tf}")
afx = of_type(msgs, "afx")
check(len(afx) == 1 and afx[0]["fx"] == "blood" and afx[0]["u"] == biter.unit_number, f"a hit biter bleeds once per interval: {afx}")
# A turret that fired and was then mined (no on_entity_died) leaves its firing throttle behind.
gone_gun = spawn("gun-turret", 4.0, 12.0, force="player")
F["raise"]("on_entity_damaged", lua.table_from({"entity": biter, "cause": gone_gun, "force": g.game.forces.player, "final_damage_amount": 5}))
gone_unit = gone_gun.unit_number
check(g.storage.f3d.turret_fire_ticks[gone_unit] is not None, "the mined turret's throttle was set")
gone_gun.destroy()
take()
# Turret states (turrets.lua): where each turret points, its target, shots counted from its ammo
# (or from its hits, for a laser), sent every 6 ticks while it has a target.
laser = spawn("laser-turret", 3.0, 6.0, force="player")
tank_ = spawn("tank", 2.0, 9.0, force="player")
tank_.relative_turret_orientation = 0.5
turret.get_inventory(g.defines.inventory.turret_ammo).insert(lua.table_from({"name": "firearm-magazine", "count": 10}))
turret.orientation = 0.25
tick(61)
take()
check(g.storage.f3d.turret_fire_ticks[gone_unit] is None and g.storage.f3d.hit_fx_ticks[biter.unit_number] is None,
      "throttles don't stay in storage once they can't matter: a mined turret's, a living biter's")
turret.get_inventory(g.defines.inventory.turret_ammo).remove(lua.table_from({"name": "firearm-magazine", "count": 2}))
F["raise"]("on_entity_damaged", lua.table_from({"entity": biter, "cause": laser, "force": g.game.forces.player, "final_damage_amount": 5}))
tick(6)
ts = {rec[0]: rec for m in of_type(take(), "ts") for rec in m["l"]}
check(ts.get(turret.unit_number) == [turret.unit_number, 250, 2, 0, 8 * 256, 8 * 256],
      f"ts: a gun turret's orientation, the shots taken from its ammo and its target: {ts}")
check(ts.get(laser.unit_number, [0, 0, 0])[2] == 1, f"ts: a laser turret's hit counts as a shot: {ts}")
turret.shooting_target = None
tick(6)
ts = {rec[0]: rec for m in of_type(take(), "ts") for rec in m["l"]}
check(turret.unit_number not in ts, f"ts: an idle turret that didn't turn isn't reported: {ts}")
tick(120)
ts = {rec[0]: rec for m in of_type(take(), "ts") for rec in m["l"]}
check(ts.get(turret.unit_number) == [turret.unit_number, 250, 0, 0], f"ts: every turret now and then, idle ones too: {ts}")
check(ts.get(tank_.unit_number) == [tank_.unit_number, 500, 0, 1], f"ts: a vehicle's turret relative to its body and its gun: {ts}")
tank_.destroy()
laser.destroy()
turret.get_inventory(g.defines.inventory.turret_ammo).remove(lua.table_from({"name": "firearm-magazine", "count": 8}))
turret.orientation = 0
F["raise"]("on_entity_died", lua.table_from({"entity": biter}))
biter.destroy()
# Combat event fields (cx, cy, dt) on died and afx:
# 1. When cause and damage_type exist: emit cx, cy, dt
attacker = spawn("gun-turret", 10.0, 10.0, force="player")
victim = spawn("small-biter", 12.0, 12.0, force="enemy")
dmg_phys = g.prototypes.damage_type["physical"]
tick(4)
take()

F["raise"]("on_entity_damaged", lua.table_from({
    "entity": victim,
    "cause": attacker,
    "damage_type": dmg_phys,
    "final_damage_amount": 5,
}))
afx_msgs = of_type(take(), "afx")
check(len(afx_msgs) == 1, f"afx sent on damage: {afx_msgs}")
check(afx_msgs[0].get("cx") == fixed(10.0) and afx_msgs[0].get("cy") == fixed(10.0),
      f"afx carries attacker cause position cx, cy: {afx_msgs}")
check(afx_msgs[0].get("dt") == "physical", f"afx carries damage type dt: {afx_msgs}")

F["raise"]("on_entity_died", lua.table_from({
    "entity": victim,
    "cause": attacker,
    "damage_type": dmg_phys,
}))
died_msgs = of_type(take(), "died")
check(len(died_msgs) == 1, f"died sent on death: {died_msgs}")
check(died_msgs[0].get("cx") == fixed(10.0) and died_msgs[0].get("cy") == fixed(10.0),
      f"died carries attacker cause position cx, cy: {died_msgs}")
check(died_msgs[0].get("dt") == "physical", f"died carries damage type dt: {died_msgs}")
victim.destroy()

# 2. When cause is absent/invalid but source exists: fall back to source for cx, cy
src_bullet = spawn("gun-turret", 14.0, 15.0, force="player")
victim2 = spawn("small-biter", 12.0, 12.0, force="enemy")
dmg_fire = g.prototypes.damage_type["fire"]
tick(4)
take()

F["raise"]("on_entity_damaged", lua.table_from({
    "entity": victim2,
    "source": src_bullet,
    "damage_type": dmg_fire,
    "final_damage_amount": 5,
}))
afx_msgs = of_type(take(), "afx")
check(len(afx_msgs) == 1, f"afx sent: {afx_msgs}")
check(afx_msgs[0].get("cx") == fixed(14.0) and afx_msgs[0].get("cy") == fixed(15.0),
      f"afx falls back to source position when cause is absent: {afx_msgs}")
check(afx_msgs[0].get("dt") == "fire", f"afx carries damage type dt: {afx_msgs}")

F["raise"]("on_entity_died", lua.table_from({
    "entity": victim2,
    "source": src_bullet,
    "damage_type": dmg_fire,
}))
died_msgs = of_type(take(), "died")
check(len(died_msgs) == 1, f"died sent: {died_msgs}")
check(died_msgs[0].get("cx") == fixed(14.0) and died_msgs[0].get("cy") == fixed(15.0),
      f"died falls back to source position when cause is absent: {died_msgs}")
check(died_msgs[0].get("dt") == "fire", f"died carries damage type dt: {died_msgs}")
victim2.destroy()
src_bullet.destroy()

# 3. When cause, source, and damage_type are absent: omit cx, cy, dt cleanly
victim3 = spawn("small-biter", 12.0, 12.0, force="enemy")
tick(4)
take()

F["raise"]("on_entity_damaged", lua.table_from({
    "entity": victim3,
    "final_damage_amount": 5,
}))
afx_msgs = of_type(take(), "afx")
check(len(afx_msgs) == 1, f"afx sent: {afx_msgs}")
check("cx" not in afx_msgs[0] and "cy" not in afx_msgs[0], f"afx omits cx, cy when cause/source absent: {afx_msgs}")
check("dt" not in afx_msgs[0], f"afx omits dt when damage_type absent: {afx_msgs}")

F["raise"]("on_entity_died", lua.table_from({
    "entity": victim3,
}))
died_msgs = of_type(take(), "died")
check(len(died_msgs) == 1, f"died sent: {died_msgs}")
check("cx" not in died_msgs[0] and "cy" not in died_msgs[0], f"died omits cx, cy when cause/source absent: {died_msgs}")
check("dt" not in died_msgs[0], f"died omits dt when damage_type absent: {died_msgs}")
victim3.destroy()
attacker.destroy()

# `atk`: an enemy unit's melee hit (cause and source the unit) is sent once per ATTACK_TICKS, with the
# attacker's prototype and position, whatever it hit (here a turret, which gets no `afx`); a hit whose
# source is something else (a turret's, a stream's) sends none.
biter_a = spawn("small-biter", 11.0, 11.0, force="enemy")
wall_a = spawn("gun-turret", 12.0, 12.0, force="player")
tick(4)
take()
for _ in range(2):
    F["raise"]("on_entity_damaged", lua.table_from({
        "entity": wall_a, "cause": biter_a, "source": biter_a,
        "damage_type": dmg_phys, "final_damage_amount": 5,
    }))
atk_msgs = of_type(take(), "atk")
check(len(atk_msgs) == 1 and atk_msgs[0].get("u") == biter_a.unit_number and atk_msgs[0].get("x") == fixed(11.0)
      and atk_msgs[0].get("y") == fixed(11.0) and isinstance(atk_msgs[0].get("p"), int),
      f"atk once per interval for a biter's bite on a building: {atk_msgs}")
tick(21)
take()
F["raise"]("on_entity_damaged", lua.table_from({
    "entity": wall_a, "cause": biter_a, "source": biter_a,
    "damage_type": dmg_phys, "final_damage_amount": 5,
}))
check(len(of_type(take(), "atk")) == 1, "atk again after ATTACK_TICKS")
tick(21)
take()
F["raise"]("on_entity_damaged", lua.table_from({
    "entity": wall_a, "cause": biter_a, "source": wall_a,
    "damage_type": dmg_phys, "final_damage_amount": 5,
}))
check(len(of_type(take(), "atk")) == 0, "no atk when the damage's source isn't the unit (a stream's acid)")
F["raise"]("on_entity_damaged", lua.table_from({
    "entity": biter_a, "cause": wall_a, "source": wall_a,
    "damage_type": dmg_phys, "final_damage_amount": 1,
}))
check(len(of_type(take(), "atk")) == 0, "no atk when a turret is the cause")
F["raise"]("on_entity_died", lua.table_from({"entity": biter_a}))
check(g.storage.f3d.attack_ticks[biter_a.unit_number] is None, "a dead attacker's atk time is dropped")
take()
biter_a.destroy()
wall_a.destroy()

# Damage intensity (dmg), remaining health (hp), and weapon/projectile source (src):
saved_next_unit = F.next_unit
# 1. Non-lethal hit emits dmg, hp, src on afx
victim4 = spawn("small-biter", 12.0, 12.0, force="enemy")
victim4.health = 80
victim4.max_health = 100
grenade_src = spawn("grenade", 10.0, 10.0, force="player")

F["raise"]("on_entity_damaged", lua.table_from({
    "entity": victim4,
    "source": grenade_src,
    "damage_type": g.prototypes.damage_type["explosion"],
    "final_damage_amount": 25,
}))
afx_msgs = of_type(take(), "afx")
check(len(afx_msgs) == 1, f"afx sent on damage: {afx_msgs}")
check(afx_msgs[0].get("dmg") == 250, f"afx carries dmg (25/100 -> 250): {afx_msgs[0]}")
check(afx_msgs[0].get("hp") == 800, f"afx carries remaining hp (80/100 -> 800): {afx_msgs[0]}")
check(afx_msgs[0].get("src") == "grenade", f"afx carries weapon source name: {afx_msgs[0]}")

# 2. Lethal overkill hit inherits dmg and src onto died on the same tick
victim4.health = 0
F["raise"]("on_entity_damaged", lua.table_from({
    "entity": victim4,
    "source": grenade_src,
    "damage_type": g.prototypes.damage_type["explosion"],
    "final_damage_amount": 200,
}))
take()
F["raise"]("on_entity_died", lua.table_from({
    "entity": victim4,
}))
died_msgs = of_type(take(), "died")
check(len(died_msgs) == 1, f"died sent: {died_msgs}")
check(died_msgs[0].get("dmg") == 2000, f"died inherits overkill dmg=2000 from lethal hit: {died_msgs[0]}")
check(died_msgs[0].get("src") == "grenade", f"died inherits src='grenade' from lethal hit: {died_msgs[0]}")
victim4.destroy()
grenade_src.destroy()

# 3. Clean omission of dmg and src when no hit preceded and source is absent
victim5 = spawn("small-biter", 12.0, 12.0, force="enemy")
F["raise"]("on_entity_died", lua.table_from({
    "entity": victim5,
}))
died_msgs = of_type(take(), "died")
check(len(died_msgs) == 1, f"died sent: {died_msgs}")
check("dmg" not in died_msgs[0], f"died omits dmg when no recent hit: {died_msgs[0]}")
check("src" not in died_msgs[0], f"died omits src when absent: {died_msgs[0]}")
victim5.destroy()

# 4. Worms (type="turret", force="enemy") and nests (type="unit-spawner", force="enemy")
# emit afx (with cx, cy, dt, dmg, hp, src) on damage and pass lethal dmg/src onto died:
attacker_src = spawn("grenade", 10.0, 10.0, force="player")

worm_victim = spawn("small-worm-turret", 12.0, 12.0, force="enemy")
worm_victim.health = 150
worm_victim.max_health = 200
take()
F["raise"]("on_entity_damaged", lua.table_from({
    "entity": worm_victim,
    "source": attacker_src,
    "damage_type": g.prototypes.damage_type["explosion"],
    "final_damage_amount": 50,
}))
worm_afx = of_type(take(), "afx")
check(len(worm_afx) == 1, f"afx sent on worm damage: {worm_afx}")
check(worm_afx[0].get("fx") == "blood", f"worm afx is blood: {worm_afx[0]}")
check(worm_afx[0].get("u") == worm_victim.unit_number, f"worm afx unit_number matches: {worm_afx[0]}")
check(worm_afx[0].get("dmg") == 250, f"worm afx carries dmg (50/200 -> 250): {worm_afx[0]}")
check(worm_afx[0].get("hp") == 750, f"worm afx carries hp (150/200 -> 750): {worm_afx[0]}")
check(worm_afx[0].get("src") == "grenade", f"worm afx carries src: {worm_afx[0]}")
check(worm_afx[0].get("dt") == "explosion", f"worm afx carries dt: {worm_afx[0]}")
check(worm_afx[0].get("cx") == fixed(10.0) and worm_afx[0].get("cy") == fixed(10.0), f"worm afx carries cx, cy: {worm_afx[0]}")

# Worm lethal hit inherits dmg and src onto died:
worm_victim.health = 0
F["raise"]("on_entity_damaged", lua.table_from({
    "entity": worm_victim,
    "source": attacker_src,
    "damage_type": g.prototypes.damage_type["explosion"],
    "final_damage_amount": 300,
}))
take()
F["raise"]("on_entity_died", lua.table_from({
    "entity": worm_victim,
}))
worm_died = of_type(take(), "died")
check(len(worm_died) == 1, f"worm died sent: {worm_died}")
check(worm_died[0].get("dmg") == 1500, f"worm died inherits lethal dmg=1500: {worm_died[0]}")
check(worm_died[0].get("src") == "grenade", f"worm died inherits lethal src='grenade': {worm_died[0]}")
worm_victim.destroy()

# Nest (unit-spawner) damage and death:
nest_victim = spawn("biter-spawner", 12.0, 12.0, force="enemy")
nest_victim.health = 400
nest_victim.max_health = 500
take()
F["raise"]("on_entity_damaged", lua.table_from({
    "entity": nest_victim,
    "source": attacker_src,
    "damage_type": g.prototypes.damage_type["explosion"],
    "final_damage_amount": 100,
}))
nest_afx = of_type(take(), "afx")
check(len(nest_afx) == 1, f"afx sent on nest damage: {nest_afx}")
check(nest_afx[0].get("fx") == "blood", f"nest afx is blood: {nest_afx[0]}")
check(nest_afx[0].get("u") == nest_victim.unit_number, f"nest afx unit_number matches: {nest_afx[0]}")
check(nest_afx[0].get("dmg") == 200, f"nest afx carries dmg (100/500 -> 200): {nest_afx[0]}")
check(nest_afx[0].get("hp") == 800, f"nest afx carries hp (400/500 -> 800): {nest_afx[0]}")
check(nest_afx[0].get("src") == "grenade", f"nest afx carries src: {nest_afx[0]}")
check(nest_afx[0].get("dt") == "explosion", f"nest afx carries dt: {nest_afx[0]}")
check(nest_afx[0].get("cx") == fixed(10.0) and nest_afx[0].get("cy") == fixed(10.0), f"nest afx carries cx, cy: {nest_afx[0]}")

# Nest lethal hit inherits dmg and src onto died:
nest_victim.health = 0
F["raise"]("on_entity_damaged", lua.table_from({
    "entity": nest_victim,
    "source": attacker_src,
    "damage_type": g.prototypes.damage_type["explosion"],
    "final_damage_amount": 600,
}))
take()
F["raise"]("on_entity_died", lua.table_from({
    "entity": nest_victim,
}))
nest_died = of_type(take(), "died")
check(len(nest_died) == 1, f"nest died sent: {nest_died}")
check(nest_died[0].get("dmg") == 1200, f"nest died inherits lethal dmg=1200: {nest_died[0]}")
check(nest_died[0].get("src") == "grenade", f"nest died inherits lethal src='grenade': {nest_died[0]}")
nest_victim.destroy()

# Player gun-turret (force="player") does NOT emit blood afx:
player_turret = spawn("gun-turret", 12.0, 12.0, force="player")
take()
F["raise"]("on_entity_damaged", lua.table_from({
    "entity": player_turret,
    "source": attacker_src,
    "damage_type": g.prototypes.damage_type["physical"],
    "final_damage_amount": 20,
}))
turret_afx = of_type(take(), "afx")
check(len(turret_afx) == 0, f"player gun-turret does NOT emit afx: {turret_afx}")
player_turret.destroy()
attacker_src.destroy()
F.next_unit = saved_next_unit
# Enemies' attacks (`en`): a biter in range of its attack target, a spitter at range and a worm's
# shooting target are listed with the target's position; one still walking to its target and one
# wandering aren't. (Each search its own, as before the movers' one search, /f3d-perf one_search, checked
# at the end: there a unit appearing shows with the movers' next search, a worm within 300 ticks.)
take()
g.storage.f3d_perf = lua.table_from({"one_search": False})
wall = spawn("stone-wall", 20.5, 6.5, force="player")
biter_at = spawn("small-biter", 21.2, 6.5, force="enemy")
biter_at.commandable.distraction_command = lua.table_from({"type": g.defines.command.attack, "target": wall})
biter_far = spawn("small-biter", 26.0, 6.5, force="enemy")
biter_far.commandable.distraction_command = lua.table_from({"type": g.defines.command.attack, "target": wall})
spitter = spawn("small-spitter", 20.5, 16.5, force="enemy")
spitter.commandable.command = lua.table_from({"type": g.defines.command.attack, "target": wall})
idle = spawn("small-biter", 22.0, 9.0, force="enemy")
idle.commandable.command = lua.table_from({"type": g.defines.command.wander})
worm = spawn("small-worm-turret", 18.0, 14.0, force="enemy")
worm.shooting_target = wall
tick(10)
en = of_type(take(), "en")
rows = sorted(tuple(en[-1]["l"][i:i + 3]) for i in range(0, len(en[-1]["l"]), 3)) if en else []
want = sorted((u, fixed(20.5), fixed(6.5)) for u in (biter_at.unit_number, spitter.unit_number, worm.unit_number))
check(len(en) == 1 and rows == want, f"en: attacking enemies and their targets, every 10 ticks: {en}")
g.storage.f3d_perf = None
for e in (biter_at, biter_far, spitter, idle, worm, wall):
    e.destroy()
tick(10)
check(not of_type(take(), "en"), "no en while nothing attacks")
# Its runs teach the budget what it costs (rate.read): a crowd near the focus is dearer than the
# job's first guess of 10 units.
crowd = [spawn("small-biter", -25.0 + i % 10, -25.0 + i // 10, force="enemy") for i in range(100)]
tick(40)
en_cost = g.storage.f3d.bud.cost["en"]
check(en_cost is not None and en_cost >= 10 and g.storage.f3d.bud.charged["en"] is None,
      f"en: its expected cost follows what it read (100 units: {en_cost})")
for e in crowd:
    e.destroy()
tick(10)
take()
doomed = spawn("wooden-chest", 13.5, 12.5, force="player")
F["raise"]("on_entity_died", lua.table_from({"entity": doomed}))
doomed.destroy()
F.construction_networks = lua.table_from([F.make_network(5, lua.table_from([0, 0, 0, 1]), lua.table())])
ghost = spawn("entity-ghost", 15.5, 12.5, force="player", inner_name="transport-belt")
F.printed = lua.table()
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})  # keep-alive: the client times out after 600 ticks
# Hit again: "under attack" lasts 300 ticks, and the weapons and enemies checks above take longer.
F["raise"]("on_entity_damaged", lua.table_from({"entity": hurt, "force": g.game.forces.enemy, "final_damage_amount": 10}))
# A pass over the entities starts at most every 600 ticks: start one now, whatever ran before.
g.package.loaded["scripts.alerts"].reset()
tick(130)
al = of_type(take(), "al")
kinds = {a[0]: a for a in al[-1]["l"]} if al else {}
check("no_ammo" in kinds and kinds["no_ammo"][2][0][3] == "gun-turret" and kinds["no_ammo"][2][0][4] == turret.unit_number,
      f"a turret without ammo: {kinds.get('no_ammo')}")
check("unplugged" in kinds and kinds["unplugged"][2][0][4] == asm_off.unit_number, f"a machine out of reach of poles: {kinds.get('unplugged')}")
check("no_power" not in kinds and "low_power" not in kinds and [e[4] for e in kinds["unplugged"][2]] == [asm_off.unit_number],
      f"no power and low power aren't alerts (Factorio has none; the icon comes from pw): {list(kinds)}")
check("attack" in kinds and kinds["attack"][2][0][4] == hurt.unit_number, f"under attack: {kinds.get('attack')}")
check("destroyed" in kinds and kinds["destroyed"][2][0][3] == "wooden-chest", f"destroyed: {kinds.get('destroyed')}")
check("no_material" in kinds and ["transport-belt", ghost.unit_number, "transport-belt"] in [e[3:] for e in kinds["no_material"][2]],
      f"a ghost in a construction area whose network lacks its item: {kinds.get('no_material')}")
check(not any("alert scan" in str(p) or "alert pass" in str(p) for p in F.printed.values()), f"no alert scan fails: {[p for p in F.printed.values() if 'alert' in str(p)]}")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(60 * 6)
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
al = of_type(take(), "al")
kinds = {a[0]: a for a in al[-1]["l"]} if al else {}
check("attack" not in kinds and "destroyed" in kinds, "under attack ends a few seconds after the last hit; destroyed stays longer")
# Owner's G19: an entity mined since the last pass leaves its alert at once, not when the next pass
# ends (seconds later on a big base), so no icon is left over empty ground.
turret.destroy()
tick(60)
al = of_type(take(), "al")
kinds = {a[0]: a for a in al[-1]["l"]} if al else {}
check("no_ammo" not in kinds and "unplugged" in kinds, f"a mined turret's alert goes before the next pass: {list(kinds)}")
for e in (asm_off, asm_dark, asm_low, hurt, ghost):
    e.destroy()
F.construction_networks = lua.table()

# Inserter, splitter, power switch, turret screens; a chest's limit bar.
fins = spawn("fast-inserter", 1.5, -1.5, force="player")
send(open_cmd(fins))
tick(2)
gui = guis(take(), fins)
check(gui and gui[-1]["kind"] == "inserter" and gui[-1]["ins"]["n"] == 5 and gui[-1]["ins"]["m"] == "whitelist",
      f"an inserter opens with its filters: {gui[-1:]}")
send({"t": "set_inserter", "u": fins.unit_number, "f": ["iron-plate", "", "nonsense"], "m": "blacklist", "use": 1, "st": 2})
tick(2)
gui = guis(take(), fins)
check(gui and gui[-1]["ins"]["f"][:3] == ["iron-plate", "", ""] and gui[-1]["ins"]["m"] == "blacklist" and gui[-1]["ins"]["use"] == 1
      and gui[-1]["ins"]["st"] == 2, f"set_inserter sets filters, mode and stack size: {gui[-1:]}")
spl = spawn("splitter", -1.0, 2.5, force="player")
send(open_cmd(spl))
send({"t": "set_splitter", "u": spl.unit_number, "i": "left", "o": "right", "f": "iron-plate"})
tick(2)
gui = guis(take(), spl)
check(gui and gui[-1]["spl"] == {"i": "left", "o": "right", "f": "iron-plate"}, f"set_splitter: {gui[-1:]}")
sw = spawn("power-switch", -3.0, -1.0, force="player")
send(open_cmd(sw))
send({"t": "set_switch", "u": sw.unit_number, "on": 1})
tick(2)
gui = guis(take(), sw)
check(gui and gui[-1]["kind"] == "switch" and gui[-1]["sw"] == 1, f"a power switch turns on: {gui[-1:]}")
turret = spawn("gun-turret", 4.0, -2.0, force="player")
send(open_cmd(turret))
puppet.insert(lua.table_from({"name": "firearm-magazine", "count": 5}))
tick(2)
gui = guis(take(), turret)
check(gui and gui[-1]["kind"] == "turret" and "turret_ammo" in gui[-1]["slots"], f"a turret shows its ammo slot: {gui[-1:]}")
send(open_cmd(box_chest))
send({"t": "set_bar", "u": box_chest.unit_number, "n": 4})
tick(2)
gui = guis(take(), box_chest)
check(gui and gui[-1].get("bar") == 4, f"a chest's limit bar: {gui[-1:]}")
send({"t": "set_inserter", "u": box_chest.unit_number, "st": 3})
tick(2)
check(any(m["text"] == "That isn't an inserter" for m in of_type(take(), "msg")), "inserter settings on a chest are refused")
send({"t": "inv_filter", "i": 7, "item": "iron-plate"})
tick(2)
sl = of_type(take(), "slots")
check(sl and sl[-1].get("fl") == [[7, "iron-plate"]], f"inv_filter sets a main inventory slot filter: {sl[-1:]}")
send({"t": "inv_filter", "i": 7, "item": ""})
tick(2)
sl = of_type(take(), "slots")
check(sl and "fl" not in sl[-1], "and an empty item clears it")
send({"t": "close"})
for e in (box_chest, asm_a, asm_b, fins, spl, sw, turret):
    e.destroy()
for e in list(F.surface.entities.values()):
    if e.type == "entity-ghost":
        e.destroy()
tick(2)
take()
# --- logistics: chests, roboports, the character's requests, networks, robot cargo -----------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(2)
take()
send({"t": "set_char_requests", "l": [["iron-plate", 1, -1]]})
tick(1)
msgs = take()
check(not of_type(msgs, "clog") and any(m["text"].startswith("No logistic requests yet") for m in of_type(msgs, "msg")),
      f"set_char_requests before the research says so: {msgs}")
g.game.forces.player.character_logistic_requests = True
tick(30)
clog = of_type(take(), "clog")
check(clog and clog[-1]["on"] == 1 and clog[-1]["trash"] == 0 and clog[-1]["l"] in ([], {}),
      f"clog: the character's requests arrive once researched: {clog}")
send({"t": "set_char_requests", "l": [["iron-plate", 100, 200], ["no-such-item", 1, 1]], "trash": 1})
tick(1)
clog = of_type(take(), "clog")
check(clog and clog[-1]["l"] == [["iron-plate", 100, 200]] and clog[-1]["trash"] == 1,
      f"set_char_requests sets requests (unknown items left out) and auto-trash: {clog}")
send({"t": "set_char_requests", "on": 0})
tick(1)
clog = of_type(take(), "clog")
check(clog and clog[-1]["on"] == 0 and clog[-1]["l"] == [["iron-plate", 100, 200]], "and turns them off, keeping them")
check(clog and [s_["f"] for s_ in clog[-1].get("sec", [])] == [[["iron-plate", "normal", 100, 200, "", -1]]],
      f"clog.sec: the character's sections one by one: {clog[-1:]}")
send({"t": "set_section", "u": 0, "i": 0, "g": "Mall"})
tick(1)
clog = of_type(take(), "clog")
check(clog and [s_["g"] for s_ in clog[-1]["sec"]] == ["", "Mall"] and isinstance(clog[-1].get("lgs"), (list, dict)),
      f"set_section u=0 adds a section to the character, in a group: {clog[-1:]}")
send({"t": "set_section", "u": 0, "i": 2, "on": 0, "f": [["iron-gear-wheel", "normal", 50, -1, "", -1]]})
tick(1)
clog = of_type(take(), "clog")
check(clog and clog[-1]["sec"][1]["on"] == 0 and clog[-1]["sec"][1]["f"][0][:3] == ["iron-gear-wheel", "normal", 50],
      f"set_section u=0 turns a character section off and sets its requests: {clog[-1:]}")
send({"t": "set_section", "u": 0, "i": 2, "del": 1})
tick(1)
clog = of_type(take(), "clog")
check(clog and len(clog[-1]["sec"]) == 1, f"set_section u=0 del removes the character's section: {clog[-1:]}")
send({"t": "set_char_color", "c": [10, 200, 30]})
tick(1)
ccol = of_type(take(), "ccol")
pc = g.storage.f3d.puppet.color
check(ccol and ccol[-1]["c"] == [10, 200, 30] and abs(pc.g - 200 / 255) < 1e-6,
      f"set_char_color sets the character's colour and ccol says so: {ccol}")

F.network = F.make_network(7, lua.table_from([3, 5, 1, 2]), lua.table_from([lua.table_from(["iron-plate", 50]), lua.table_from(["copper-plate", 80])]))
px, py = g.storage.f3d.puppet.position.x, g.storage.f3d.puppet.position.y
req = spawn("requester-chest", px + 2.5, py + 1.5, force="player")
sto = spawn("storage-chest", px + 3.5, py + 1.5, force="player")
port = spawn("roboport", px + 6.0, py + 3.0, force="player")
robot = spawn("logistic-robot", px + 1.5, py - 1.5, force="player")
robot.get_inventory(g.defines.inventory.robot_cargo).insert(lua.table_from({"name": "iron-plate", "count": 4}))
while g.game.tick % 60:
    tick(1)
msgs = take()
ln = of_type(msgs, "ln")
check(ln and ln[-1]["id"] == 7 and ln[-1]["log"] == [3, 5] and ln[-1]["con"] == [1, 2], f"ln: the network the character stands in: {ln[-1:]}")
rc = [v for m in of_type(msgs, "rc") for v in m["l"]]
check([robot.unit_number, iid["iron-plate"], 4] in [rc[i:i + 3] for i in range(0, len(rc), 3)], f"rc: what a robot near the focus carries: {rc}")

send(open_cmd(req))
send({"t": "set_requests", "u": req.unit_number, "l": [["iron-gear-wheel", 10, -1], ["wood", 5, 20]]})
tick(2)
gui = guis(take(), req)
lg = gui[-1].get("lg", {}) if gui else {}
check(lg.get("mode") == "requester" and lg.get("requests") == [["iron-gear-wheel", 10, -1], ["wood", 5, 20]],
      f"a requester chest's screen: its requests, set by set_requests: {lg}")
# Alt-mode: a mixed requester chest shows its first four requests, each a quarter of the icon (owner).
alt_mod = lua.eval('package.loaded["scripts.alt_mode"]')
icon2 = alt_mod.icon(req)
req5 = spawn("requester-chest", px + 2.5, py + 3.5, force="player")
lua.execute("""local e = ...
  local secs = e.get_logistic_sections()
  local sec = secs.get_section(1) or secs.add_section()
  local list = {}
  for _, name in ipairs({ "iron-gear-wheel", "wood", "transport-belt", "stone-furnace", "wooden-chest" }) do
    list[#list + 1] = { value = { type = "item", name = name, quality = "normal" }, min = 1 }
  end
  sec.filters = list""", req5)
icon5 = alt_mod.icon(req5)
as_list = lambda t: [t[1], t[2], list(t[3].values()) if t[3] else None] if t else None
check(as_list(icon2) == ["item", "iron-gear-wheel", ["wood"]] and as_list(icon5) == ["item", "iron-gear-wheel", ["wood", "transport-belt", "stone-furnace"]],
      f"Alt-mode: a requester chest's first four requests: {as_list(icon2)} {as_list(icon5)}")
req5.destroy()
check(lg.get("net", {}).get("items") == [["copper-plate", 80], ["iron-plate", 50]] and "trash" in gui[-1]["slots"],
      f"and its network's contents (most first) and its trash slots: {gui[-1:]}")
lc = gui[-1].get("lc", {}) if gui else {}
check(lc.get("tu") == 0 and lc.get("rb") == 0 and lc.get("sec", [{}])[0].get("f", [[None]])[0][::2] == ["iron-gear-wheel", 10, ""],
      f"lc: the requester's sections, trash unrequested and request from buffers (machine_info.lua): {lc}")
send({"t": "set_chest_logistics", "u": req.unit_number, "tu": 1, "rb": 1})
send({"t": "set_section", "u": req.unit_number, "i": 0})
tick(2)
gui = guis(take(), req)
lc = gui[-1].get("lc", {}) if gui else {}
check(lc.get("tu") == 1 and lc.get("rb") == 1 and len(lc.get("sec", [])) == 2,
      f"set_chest_logistics ticks both boxes; set_section adds a section to a chest: {lc}")
send({"t": "set_section", "u": req.unit_number, "i": 2, "g": "Bus"})
tick(2)
gui = guis(take(), req)
lc = gui[-1].get("lc", {}) if gui else {}
check([sec.get("g") for sec in lc.get("sec", [])] == ["", "Bus"], f"set_section g puts a section in a logistic group: {lc}")
send({"t": "close"})
send(open_cmd(req))
tick(2)
gui = guis(take(), req)
check(gui and "Bus" in gui[0].get("lgs", []), f"lgs: the force's logistic groups ride with the first message: {gui[:1]}")
send(open_cmd(sto))
send({"t": "set_storage_filter", "u": sto.unit_number, "item": "iron-plate"})
send({"t": "set_requests", "u": sto.unit_number, "l": [["wood", 1, -1]]})
tick(2)
msgs = take()
gui = guis(msgs, sto)
check(gui and gui[-1]["lg"]["mode"] == "storage" and gui[-1]["lg"]["filter"] == "iron-plate", f"a storage chest's filter is set and shown: {gui[-1:]}")
check(any(m["text"] == "That chest doesn't take requests" for m in of_type(msgs, "msg")), "a storage chest takes no requests")
send({"t": "set_storage_filter", "u": sto.unit_number, "item": ""})
tick(2)
gui = guis(take(), sto)
check(gui and gui[-1]["lg"]["filter"] == "", "and cleared")
send(open_cmd(port))
tick(2)
gui = guis(take(), port)
check(gui and gui[-1]["kind"] == "roboport" and {"robots", "repair"} <= set(gui[-1]["slots"]) and gui[-1]["lg"]["net"]["id"] == 7,
      f"a roboport's screen: robots, repair packs and its network: {gui[-1:]}")
send({"t": "close"})
for e in (req, sto, port, robot):
    e.destroy()
F.network = None
tick(60)
ln = of_type(take(), "ln")
check(ln and ln[-1]["id"] == 0 and "log" not in ln[-1], f"ln: id 0 outside any network: {ln[-1:]}")

# --- qualities, for cycling the one to build with ---------------------------------------------------
lua.eval("function() storage.f3d.techs_dirty = true end")()
tick(2)  # reliable: out with the next tick's flush
quals = of_type(take(), "quals")
check(quals and quals[-1]["l"] == [["normal", 0, 1, "ffffff"], ["uncommon", 1, 1, "ffffff"], ["rare", 2, 1, "ffffff"],
                                  ["epic", 3, 0, "ffffff"], ["legendary", 5, 0, "ffffff"]],
      f"quals: the qualities by level, which are unlocked, their colours; hidden ones left out: {quals[-1:]}")

# --- two clients on one server ---------------------------------------------------------------------
def sync_r(by):
    """take()'s reliable counter after a take_by_port (which doesn't keep it)."""
    global expected_r
    rs = [m["r"] for m in by.get(CLIENT_PORT, []) if "r" in m]
    if rs:
        expected_r = rs[-1] + 1


PORT_B = CLIENT_PORT + 1


def take_by_port():
    """Everything sent, by port; reliable numbering checked per client."""
    by, seq = {}, {}
    for item in F.take_sent().values():
        port, data = item[1], sent_data(item)
        for msg in protocol.split_datagram(data):
            for problem in protocol.problems(msg):
                check(False, f"protocol: {problem}")
            if "r" in msg:
                if msg["t"] == "welcome":
                    seq[port] = msg["r"]
                elif port in seq:
                    check(msg["r"] == seq[port], f"reliable gap on port {port}: {msg['r']} after {seq[port] - 1}")
                seq[port] = msg["r"] + 1
            by.setdefault(port, []).append(msg)
    return by


take()
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
send({"t": "hello", "v": 1, "sid": "b", "w": 0, "z": 1}, port=PORT_B)
tick(3)
by = take_by_port()
first, second = by.get(CLIENT_PORT, []), by.get(PORT_B, [])
a_unit = g.storage.f3d.puppet.unit_number
welcome_b = of_type(second, "welcome")
check(welcome_b and not of_type(first, "welcome") and welcome_b[0]["u"] != a_unit and of_type(second, "protos"),
      f"two clients: the second gets a welcome, prototypes and a character of its own; the first goes on: {welcome_b}")
b_state = g.storage.f3d_extra[PORT_B]
check(b_state and b_state.puppet and b_state.puppet.unit_number == welcome_b[0]["u"], "and its state lives in storage.f3d_extra by port")
send({"t": "sub", "c": [[0, 0]]}, port=PORT_B)
send({"t": "walk", "d": 4}, port=PORT_B)
tick(4)
by = take_by_port()
check(of_type(by.get(PORT_B, []), "chunk") and not of_type(by.get(CLIENT_PORT, []), "chunk"),
      "each client gets the chunks it subscribed to")
check(b_state.puppet.walking_state.walking and not g.storage.f3d.puppet.walking_state.walking,
      "each client walks its own character")
check(any(m["u"] == a_unit for m in of_type(by.get(CLIENT_PORT, []), "me")) and any(m["u"] == b_state.puppet.unit_number for m in of_type(by.get(PORT_B, []), "me")),
      "and each hears about its own character in `me`")
made = spawn("wooden-chest", 3.5, 3.5, force="player")
F["raise"]("script_raised_built", lua.table_from({"entity": made}))
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
send({"t": "hello", "v": 1, "sid": "b", "w": 1, "z": 1}, port=PORT_B)
tick(2)
by = take_by_port()
adds = {port: [m for m in of_type(msgs, "add") if m["e"][0] == made.unit_number] for port, msgs in by.items()}
check(adds.get(CLIENT_PORT) and adds.get(PORT_B), f"a building event reaches both clients: {sorted(adds)}")
# Each client's movers come from its own focus (the list found was once shared between clients).
far_car = spawn("car", 2000.5, 2000.5, force="player")
send({"t": "focus", "x": 2000 * 256, "y": 2000 * 256, "r": 32}, port=PORT_B)
send({"t": "focus", "x": int(g.storage.f3d.puppet.position.x * 256), "y": int(g.storage.f3d.puppet.position.y * 256), "r": 32})
tick(10)
take_by_port()
# And each searches only its own area when due: one shared list made every send of the other
# client search again, every few ticks.
mover_searches = lua.eval("""function(surface)
  local counter = {n = 0}
  local types = package.loaded["scripts.registry"].mover_types()
  local find = surface.find_entities_filtered
  surface.find_entities_filtered = function(f)
    if f.area and f.type == types then counter.n = counter.n + 1 end
    return find(f)
  end
  counter.restore = function() surface.find_entities_filtered = find end
  return counter
end""")(F.surface)
tick(40)
mover_searches.restore()
check(mover_searches.n <= 12, f"two clients: movers are searched for about every 8 ticks each ({mover_searches.n} in 40 ticks)")
by = take_by_port()
mv_units = {port: {rec[0] for m in of_type(msgs, "mv") for rec in m["l"]} for port, msgs in by.items()}
check(far_car.unit_number in mv_units.get(PORT_B, set()) and far_car.unit_number not in mv_units.get(CLIENT_PORT, set()),
      f"two clients: each gets the movers round its own focus ({len(mv_units.get(CLIENT_PORT, []))} / {len(mv_units.get(PORT_B, []))})")
far_car.destroy()
b_unit = b_state.puppet.unit_number
send({"t": "bye"}, port=PORT_B)
tick(1)
check(len(g.storage.f3d_extra) == 0 and g.storage.f3d.client and g.storage.f3d.client.port == CLIENT_PORT,
      "bye drops only the second client")
send({"t": "hello", "v": 1, "sid": "b", "w": 0}, port=PORT_B)
tick(3)
by = take_by_port()
check(of_type(by.get(PORT_B, []), "welcome") and of_type(by[PORT_B], "welcome")[0]["u"] == b_unit,
      "the same client coming back gets its character back")
send({"t": "bye"}, port=PORT_B)
old_subs = [[int(v) for v in k.split(",")] for k in g.storage.f3d.subs.keys()]
old_focus = {"x": int(g.storage.f3d.focus.x * 256), "y": int(g.storage.f3d.focus.y * 256), "r": int(g.storage.f3d.focus.r)}
F.multiplayer = False
send({"t": "hello", "v": 1, "sid": "c", "w": 0}, port=PORT_B + 1)
tick(1)
check(len(g.storage.f3d_extra) == 0 and g.storage.f3d.client.port == PORT_B + 1,
      "in single-player a new port takes over instead of adding a client (the game plays one character)")
send({"t": "bye"}, port=PORT_B + 1)
tick(1)
F.multiplayer = True
take_by_port()
send({"t": "hello", "v": 1, "sid": "s1", "w": 0})  # the first client again, as the tests below expect
tick(3)
send({"t": "sub", "c": old_subs})
send({"t": "focus", **old_focus})
tick(30)
take()
made.destroy()

# --- the other planets: demolishers, lightning, Gleba, Aquilo, travel --------------------------------
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(2)
take()
px, py = g.storage.f3d.puppet.position.x, g.storage.f3d.puppet.position.y
demo = F.add_segmented_unit(F.surface, "small-demolisher", "small-demolisher-segment",
                            lua.table_from([lua.table_from([px + 6, py, 0.25]), lua.table_from([px + 11, py, 0.25])]))
tick(2)
seg = [r for m in of_type(take(), "seg") for r in m["l"] if r[0] == demo.unit_number]
check(seg and seg[-1][1] == eid["small-demolisher"] and seg[-1][2] == [eid["small-demolisher-segment"], fixed(px + 6), fixed(py), 250,
                                                                     eid["small-demolisher-segment"], fixed(px + 11), fixed(py), 250],
      f"seg: a demolisher's segments in order, with their orientation: {seg[-1:]}")
F.surface.segmented = lua.table_from([])
tick(2)
seg = of_type(take(), "seg")
check(seg and seg[-1]["l"] in ([], {}), "and an empty seg once it is gone")

# A lightning entity stands where its bolt starts, 25 tiles up (y) and up to 15 aside (x) of
# where it strikes: one pulled onto the rod, one striking the ground, and one far from the focus.
# (On a planet with lightning: the fake's Nauvis has none, so it is listed here; the planets without it
# are checked at the end, /f3d-perf lightning_planets.)
F.planet_data.lightning = lua.table_from(["fulgora", "nauvis"])
forget(g.package.loaded["scripts.planets"].tick, "lightning_cache")
rod = spawn("lightning-rod", px + 10.5, py + 10.5, force="player")
bolt = spawn("lightning", px + 14.5, py + 10.5 - 24)
stray = spawn("lightning", px - 18.5, py - 12.5 - 23)
far = spawn("lightning", px + 120.5, py - 25)
# No lightning seen yet: the search idles at every 12th tick.
tick(12)
lt = [r for m in of_type(take(), "lt") for r in m["l"]]
check(sorted(lt) == sorted([[fixed(px + 10.5), fixed(py + 10.5), 1], [fixed(px - 18.5), fixed(py - 10.5), 0]]),
      f"lt: strikes near the focus on the ground below the bolt, or on the rod that caught them: {lt}")
# Lightning was seen, so the next strike is looked for at the full rate (every 3 ticks).
second = spawn("lightning", px - 4.5, py - 30.5)
while g.game.tick % 3:
    tick(1)
tick(3)
lt = [r for m in of_type(take(), "lt") for r in m["l"]]
check(lt == [[fixed(px - 4.5), fixed(py - 5.5), 0]], f"lt: once lightning was seen, strikes are looked for every 3 ticks again: {lt}")
second.destroy()
tick(3)
check(not of_type(take(), "lt"), "each strike is sent once")
for e in (bolt, stray, far):
    e.destroy()
F.planet_data.lightning = lua.table_from(["fulgora"])
forget(g.package.loaded["scripts.planets"].tick, "lightning_cache")

plant = spawn("yumako-tree", px + 4.5, py + 4.5, force="player", tick_grown=g.game.tick + 300)
tower = spawn("agricultural-tower", px + 2.5, py + 6.5, force="player")
tower.owned_plants = lua.table_from([plant])
pod = spawn("small-stomper-pentapod", px + 8.0, py - 6.0, force="enemy")
nest = spawn("gleba-spawner", px + 14.5, py - 8.5, force="enemy")
nest.units = lua.table_from([pod])
cold = spawn("inserter", px - 3.5, py + 3.5, force="player", frozen=True)
F["raise"]("on_tower_planted_seed", lua.table_from({"tower": tower, "plant": plant, "seed": lua.table_from({"name": "yumako-seed"})}))
tick(1)
check([m for m in of_type(take(), "add") if m["e"][2:4] == [fixed(px + 4.5), fixed(py + 4.5)]], "a plant the tower planted is added to the world")
while g.game.tick % 60:
    tick(1)
msgs = take()
pg = [v for m in of_type(msgs, "pg") for v in m["l"]]
groups = [pg[i:i + 4] for i in range(0, len(pg), 4)]
mine = [gr for gr in groups if gr[1:3] == [fixed(px + 4.5), fixed(py + 4.5)]]
check(mine and 400 <= mine[0][3] <= 600, f"pg: a plant halfway grown: {mine}")
sp = [v for m in of_type(msgs, "sp") for v in m["l"]]
check([nest.unit_number, 1] in [sp[i:i + 2] for i in range(0, len(sp), 2)], f"sp: a spawner and its units out: {sp}")
fz = [v for m in of_type(msgs, "fz") for v in m["l"]]
check(cold.unit_number in fz, f"fz: a frozen inserter: {fz}")
tick(4)
legs = [r for m in of_type(take(), "legs") for r in m["l"] if r[0] == pod.unit_number]
check(legs and len(legs[-1][1]) == 10 and legs[-1][1][:2] == [fixed(px + 8.0 - 3.7), fixed(py - 6.0 - 5.1)],
      f"legs: a pentapod's five feet, from the spider-leg entities after it (no get_spider_legs on a spider unit): {legs[-1:]}")
send(open_cmd(tower))
tick(2)
gui = guis(take(), tower)
check(gui and gui[-1].get("ag") == {"plants": 1, "ready": 0}, f"an agricultural tower's screen counts its plants: {gui[-1:]}")
send({"t": "close"})

puppet = g.storage.f3d.puppet
puppet.get_main_inventory().insert(lua.table_from({"name": "yumako", "count": 5}))
lua.eval("""function(inv)
  for i = 1, #inv do
    if inv[i].valid_for_read and inv[i].name == "yumako" then inv[i].spoil_percent = 0.25 end
  end
end""")(puppet.get_main_inventory())
tick(31)
slots = [m["l"]["main"] for m in of_type(take(), "slots")]
check(slots and ["yumako", 5, "normal", 750] in slots[-1], f"slots: a spoiling stack carries its freshness: {[s for s in (slots[-1] if slots else []) if s]}")
belt2 = spawn("transport-belt", px + 1.5, py + 2.5, force="player")
F.put_on_belt(belt2, 1, "yumako", 0.5, 4242, 0.5)
tick(12)
bf = [v for m in of_type(take(), "bf") for v in m["l"]]
check([4242, 500] in [bf[i:i + 2] for i in range(0, len(bf), 2)], f"bf: freshness of spoiling items on belts: {bf[:8]}")

silo = spawn("wooden-chest", px + 3.5, py - 3.5, force="player")
F["raise"]("on_rocket_launch_ordered", lua.table_from({"rocket": silo, "rocket_silo": silo}))
cargo = spawn("cargo-pod", px - 2.0, py - 2.0, force="player")
# No pod seen yet: the search idles at every 30th tick.
tick(1)
while g.game.tick % 30:
    tick(1)
msgs = take()
rk = of_type(msgs, "rk")
check(rk and rk[-1]["u"] == silo.unit_number and rk[-1]["s"] == "nauvis", f"rk: a rocket launch at a silo: {rk}")
cp = [r for m in of_type(msgs, "cp") for r in m["l"] if r[0] == cargo.unit_number]
check(cp and cp[-1][1:] == ["awaiting_launch", "invalid", ""], f"cp: a cargo pod near the focus: {cp}")
# Coming down, it says where it lands: the station's place, so the client drops it straight onto it.
pad = spawn("wooden-chest", px + 6.5, py + 2.5, force="player")
F.entity_data(cargo).cargo_pod_state = "descending"
F.entity_data(cargo).cargo_pod_destination = lua.table_from({"type": g.defines.cargo_destination.station, "station": pad})
tick(60)  # 60: the platform checks further on wait for ticks on the 60s
cp = [r for m in of_type(take(), "cp") for r in m["l"] if r[0] == cargo.unit_number]
check(cp and cp[-1][4:] == [int((px + 6.5) * 256), int((py + 2.5) * 256)], f"cp: a descending pod says where it lands: {cp[-1:]}")
F.entity_data(cargo).cargo_pod_state = "awaiting_launch"
F.entity_data(cargo).cargo_pod_destination = lua.table_from({"type": g.defines.cargo_destination.invalid})
pad.destroy()
send({"t": "land"})
tick(1)
check(any("Land from a platform" in m["text"] for m in of_type(take(), "msg")), "land on a planet is refused")
for e in (rod, plant, tower, pod, nest, cold, belt2, silo, cargo):
    e.destroy()
tick(61)
take()

# --- strangers, junk, resync ---------------------------------------------------------------------
F.packet("not json at all", CLIENT_PORT)
send({"t": "walk", "d": 0}, port=40000)
send({"t": "nonsense"})
tick(2)
check(not puppet.walking_state.walking, "commands from another port are ignored")
take()
send({"t": "resync"})
tick(10)
msgs = take()
check({(m["cx"], m["cy"]) for m in of_type(msgs, "chunk")} == {(0, 0), (1, 0), (9, 9)}, "resync resends subscribed chunks")
send({"t": "resync", "full": 0, "c": [[1, 0], [5, 5], "junk"]})
tick(10)
msgs = take()
resent = [(m["cx"], m["cy"]) for m in of_type(msgs, "chunk")]
# The mod also refreshes one subscribed chunk every 5 s, which may land in these ticks.
check((1, 0) in resent and (5, 5) not in resent and len(resent) <= 2,
      f"resync with a list resends those subscribed chunks, without waiting for the cooldown: {resent}")

# --- /f3d-status from RCON or the server console -------------------------------------------------
F.printed = lua.table()
F.command(lua.table_from({"name": "f3d-status"}))
printed = list(F.printed.values())
check(any(p.startswith("RCON [Zenith] client on port") for p in printed), "/f3d-status answers RCON")
check(any(p.startswith("STDOUT [Zenith] character at") for p in printed), "/f3d-status prints to the server console")
check(any("profiling off" in str(p) for p in printed), "/f3d-status says profiling is off")
check(not any("speaks protocol" in str(p) for p in printed), "/f3d-status says nothing of the protocol when the client's is the bridge's")
send({"t": "hello", "v": 2, "sid": "s1", "w": 1})
tick(1)
F.printed = lua.table()
F.command(lua.table_from({"name": "f3d-status"}))
check(any("the client speaks protocol 2 and this bridge 1" in str(p) for p in F.printed.values()),
      "/f3d-status says when the client speaks another protocol (its hello's v)")
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(1)
F.printed = lua.table()
F.commands["f3d-profile"](lua.table_from({"name": "f3d-profile"}))
before = F.profilers
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(601)
F.printed = lua.table()
F.command(lua.table_from({"name": "f3d-status"}))
lines = [p for p in F.printed.values()]
check(F.profilers > before and any("RCON" in str(p) for p in lines) and len(lines) > 12,
      f"with /f3d-profile on, /f3d-status reports a time for every module ({F.profilers - before} profilers, {len(lines)} lines)")
# A trace beside it (/f3d-profile trace N, as tools/bench does) times the same run: each module
# still runs once a tick (each timed its own run, so the bridge ran four times a tick).
profile_mod = lua.eval('package.loaded["scripts.profile"]')
runs = lua.eval("{n = 0}")
profile_mod.trace(3)
profile_mod.run("probe", lua.eval("function(r) r.n = r.n + 1 end"), runs)
profile_mod.run("outer", lua.eval("function(p, r) p.run('inner', function() r.n = r.n + 10 end) end"), profile_mod, runs)
profile_mod.end_tick()
check(runs.n == 11, f"profiling and a trace at once run each step once, nested ones too: {runs.n} (11 is once each)")
profile_mod.trace(0)
F.commands["f3d-profile"](lua.table_from({"name": "f3d-profile"}))
take()

# --- space platforms -------------------------------------------------------------------------------
def platform_console(parameter):
    before = len(F.printed)
    F.commands["f3d-platform"](lua.table_from({"name": "f3d-platform", "parameter": parameter}))
    return [str(p) for p in list(F.printed.values())[before:]]


def next_plat():
    """Ticks to the next platform message and returns it."""
    tick(1)
    while g.game.tick % 60:
        tick(1)
    plats = of_type(take(), "plat")
    return plats[-1] if plats else {}


send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(1)
take()
puppet = g.storage.f3d.puppet
lines = platform_console("new")
check(any("platform 1 (Platform 1) built in orbit of nauvis" in l for l in lines), f"/f3d-platform new builds a platform: {lines}")
plat = g.game.forces.player.platforms[1]
check(plat.hub is not None and plat.surface.name == "platform-1", "with the starter pack applied it has a hub and a surface")
pm = next_plat()
rec = (pm.get("l") or [{}])[0]
check(pm.get("on") == 0 and pm.get("here") == "nauvis" and pm.get("dest") == ["nauvis", "vulcanus"],
      f"plat: on a planet, with the unlocked destinations: {pm}")
check(rec.get("i") == 1 and rec.get("st") == "paused" and rec.get("loc") == "nauvis" and rec.get("hub") == plat.hub.unit_number
      and rec.get("pa") == 1 and "from" not in rec and "sch" not in rec, f"plat: a new platform waits in orbit, paused: {rec}")
check(rec.get("w") == 1250000, f"plat: the platform's mass (weight, kg) for the remote view's info panel: {rec}")
nauvis_s = g.game.planets.nauvis.surface
check(pm.get("k") == g.game.tick
      and pm.get("days") == [["nauvis", nauvis_s.ticks_per_day, round(nauvis_s.daytime * 100000) % 100000, 1 if nauvis_s.freeze_daytime else 0]],
      f"plat: the game's tick and the day of the planet in the platform's sky (its surface's ticks_per_day, daytime): {pm}")
# Its map seen from Nauvis (mtr si): a platform has no radars and is seen whole, as cov says.
send({"t": "mtr", "si": plat.surface.index})
tick(1)
plat_mtr = of_type(take(), "mtr")
check(plat_mtr and plat_mtr[0].get("all") == 1 and plat_mtr[0].get("si") == plat.surface.index,
      f"mtr on a platform's map: all = 1, the whole platform seen: {plat_mtr[:1]}")

# #5: the remote view looks at the platform from Nauvis: its world is streamed (surface, view = 1),
# world-changing commands wait, and si 0 goes back to the character's surface.
send({"t": "view", "si": plat.surface.index, "x": 3 * 256, "y": 4 * 256})
tick(2)
msgs = take()
vs = of_type(msgs, "surface")
check(vs and vs[0]["si"] == plat.surface.index and vs[0].get("view") == 1 and vs[0]["x"] == 3 * 256 and puppet.surface.name == "nauvis",
      f"view: the platform's world is streamed while the character stays on Nauvis: {vs}")
# H25: a full resync (lost packets) keeps the remote view on that surface instead of dropping back
# to the character's planet.
lua.eval("function() storage.f3d.resync_tick = -1000000 end")()
send({"t": "resync", "full": 1})
tick(2)
take()
check(lua.eval("function() return storage.f3d.view_si end")() == plat.surface.index,
      "a full resync keeps the remote view of another surface (H25)")
# #12: from the remote view, building on that surface places a ghost there (never the item),
# while what needs the character's hands still waits.
send({"t": "sub", "c": [[0, 0]]})
tick(2)
take()
send({"t": "build", "item": "wooden-chest", "x": 5 * 256 + 128, "y": 2 * 256 + 128, "d": 0})
tick(1)
msgs = take()
ghosts = [e for e in plat.surface.entities.values() if e.name == "entity-ghost" and e.ghost_name == "wooden-chest"]
check(len(ghosts) == 1 and not any(e.name == "wooden-chest" for e in plat.surface.entities.values())
      and not any(e.name == "entity-ghost" and e.ghost_name == "wooden-chest" for e in F.surface.entities.values()),
      f"view: building from the remote view puts a ghost on the shown surface: {texts(msgs)}")
check(any(m["e"][1] == eid["entity-ghost"] for m in of_type(msgs, "add")), "view: the ghost reaches the client")
# F6: the platform is uncharted (a headless server charts nothing), so the script check stands in
# for the manual one, but not over empty space or against the platform's conditions: those ghosts
# would never be built.
send({"t": "build", "item": "wooden-chest", "x": 10 * 256 + 128, "y": 2 * 256 + 128, "d": 0})
puppet.insert(lua.table_from({"name": "burner-inserter", "count": 1}))
plat.surface.props.gravity = 0  # a platform's, as in the game
send({"t": "build", "item": "burner-inserter", "x": 6 * 256 + 128, "y": 2 * 256 + 128, "d": 0})
tick(1)
plat.surface.props.gravity = 10
said = texts(take())
ghost_names = sorted(e.ghost_name for e in plat.surface.entities.values() if e.name == "entity-ghost")
check(ghost_names == ["wooden-chest"] and "Can't place that there" in said and any("gravity" in t for t in said),
      f"view: no ghost on empty space, nor one the platform's gravity forbids (F6): {ghost_names} {said}")
# F6: modules from the remote view: a ghost keeps them in its insert plan.
send({"t": "build", "item": "assembling-machine-1", "x": 5 * 256 + 128, "y": -5 * 256 - 128, "d": 0})
tick(1)
take()
am_ghost = next((e for e in plat.surface.entities.values() if e.name == "entity-ghost" and e.ghost_name == "assembling-machine-1"), None)
check(am_ghost is not None, "view: an assembler's ghost on the platform's foundation")
mod_at = {"u": am_ghost.unit_number, "p": eid["entity-ghost"], "x": fixed(am_ghost.position.x), "y": fixed(am_ghost.position.y)} if am_ghost else {}
for _ in range(3):
    send({"t": "modreq", "item": "speed-module", **mod_at})
tick(1)
said = texts(take())
plan = [(p.id.name, at.inventory, at.stack) for p in am_ghost.insert_plan.values() for at in p["items"].in_inventory.values()] if am_ghost else []
check(sorted(plan) == [("speed-module", g.defines.inventory.crafter_modules, 0), ("speed-module", g.defines.inventory.crafter_modules, 1)] and "Module requested: 2 of 2 slots" in said
      and "The module slots are full" in said, f"modreq: a ghost's insert plan gets a module per slot, no more (F6): {plan} {said}")
send({"t": "modreq", "item": "wooden-chest", **mod_at})
send({"t": "modreq", "clr": 1, "s": 1, **mod_at})
tick(1)
said = texts(take())
plan = [(p.id.name, at.stack) for p in am_ghost.insert_plan.values() for at in p["items"].in_inventory.values()] if am_ghost else []
check(plan == [("speed-module", 1)] and "That isn't a module" in said, f"modreq: clr takes a slot's request back; no chests in module slots: {plan} {said}")
# The platform's map past its generated chunks is empty, not an error (F6: get_tile there is invalid).
send({"t": "map", "si": plat.surface.index, "cx1": 10, "cy1": 10, "res": 8})
tick(2)
msgs = take()
charts = of_type(msgs, "chart")
check(charts and charts[0]["n"] == 0 and not any("Map error" in t for t in texts(msgs)),
      f"map: an ungenerated chunk of a platform charts as unknown: {charts} {texts(msgs)}")
send({"t": "mine", "u": 0, "p": 0, "x": 2 * 256, "y": 2 * 256})
tick(1)
check(any("another surface" in x for x in texts(take())), "view: mining by hand waits while another surface is shown")
check(g.storage.f3d.act_si is None, "view: the surface override ends with the command")
send({"t": "view", "si": 0})
tick(2)
vs = of_type(take(), "surface")
check(vs and vs[0]["surface"] == "nauvis" and "view" not in vs[0], f"view 0: back to the character's surface: {vs}")

send({"t": "plat_board", "i": 1})
tick(2)
msgs = take()
surf = of_type(msgs, "surface")
check(surf and surf[0]["surface"] == "platform-1" and surf[0]["pf"] == 1 and "planet" not in surf[0] and surf[0]["si"] == plat.surface.index,
      f"plat_board: the character moves to the platform and the client is told (surface): {surf}")
check(puppet.surface.name == "platform-1" and not of_type(msgs, "welcome"), "a surface change is not a new handshake")
check(len(list(g.storage.f3d.subs.items())) == 0, "the old surface's subscriptions are dropped")
send({"t": "sub", "c": [[0, 0], [-1, -1]]})
tick(6)
msgs = take()
chunk00 = [m for m in of_type(msgs, "chunk") if (m["cx"], m["cy"]) == (0, 0)]
tile_ids = set(chunk00[0]["tiles"][0::2]) if chunk00 else set()
check(tile_ids == {tile_id["space-platform-foundation"], tile_id["empty-space"]}, f"a platform chunk: foundation and empty space: {tile_ids}")
hub_recs = [e for m in of_type(msgs, "ents") for e in m["e"] if e[1] == {r[1]: r[0] for r in protos}["space-platform-hub"]]
check(len(hub_recs) == 1 and hub_recs[0][0] == plat.hub.unit_number, f"the hub is in the platform's snapshot: {hub_recs}")
pm = next_plat()
check(pm.get("on") == 1 and "here" not in pm, f"plat: on the platform, on names it: {pm}")

send({"t": "plat_go", "i": 1, "to": "vulcanus"})
send({"t": "plat_go", "i": 1, "to": "aquilo"})
send({"t": "plat_go", "i": 7, "to": "vulcanus"})
tick(1)
msgs = take()
check("Can't travel to aquilo" in texts(msgs) and "No such platform" in texts(msgs), f"plat_go refuses unknown places and platforms: {texts(msgs)}")
rec = next_plat()["l"][0]
check(rec.get("sch") == {"c": 1, "l": ["vulcanus"]} and rec.get("pa") == 0 and rec.get("st") == "waiting_at_station",
      f"plat_go: a one-stop schedule and unpaused: {rec}")
# H7: stopped, a platform names where its schedule takes it next.
check(rec.get("loc") == "nauvis" and rec.get("nx") == "vulcanus", f"plat: waiting at nauvis, the next stop: {rec}")
pdata = F.platform_data[plat]
pdata.schedule = lua.table_from({"current": 2, "records": lua.table_from([lua.table_from({"station": "vulcanus"}),
                                                                          lua.table_from({"station": "nauvis"})])})
rec = next_plat()["l"][0]
check(rec.get("nx") == "vulcanus", f"plat: waiting at its current stop, the next record: {rec}")
pdata.schedule = lua.table_from({"current": 1, "records": lua.table_from([lua.table_from({"station": "nauvis"})])})
rec = next_plat()["l"][0]
check("nx" not in rec, f"plat: a schedule of only here has no next stop: {rec}")
# Done at its stop, the schedule already on the next one (Factorio's waiting_for_departure, while
# cargo is still on its way): that one is where it goes.
pdata.schedule = lua.table_from({"current": 2, "records": lua.table_from([lua.table_from({"station": "nauvis"}),
                                                                          lua.table_from({"station": "vulcanus"})])})
rec = next_plat()["l"][0]
check(rec.get("loc") == "nauvis" and rec.get("nx") == "vulcanus" and "to" not in rec,
      f"plat: about to leave, the current record is the next stop: {rec}")
pdata.schedule = lua.table_from({"current": 1, "records": lua.table_from([lua.table_from({"station": "vulcanus"})])})
F.platform_travel(plat, "nauvis-vulcanus", 0.25, 2.5)
pm = next_plat()
rec = pm["l"][0]
days = {d[0]: d for d in pm.get("days", [])}
vday = days.get("vulcanus")
vsurf = lua.eval("function() return game.planets.vulcanus.surface end")()
# Without a surface, the prototype's day-night-cycle and the time of day from the tick.
want_v = ["vulcanus", 25000, 20000, 0] if vsurf else ["vulcanus", 5400, round(g.game.tick % 5400 / 5400 * 100000) % 100000, 0]
check(sorted(days) == ["nauvis", "vulcanus"] and vday == want_v,
      f"plat: both ends of the way have their day (vulcanus {'with' if vsurf else 'without'} a surface): {pm.get('days')}")
check(rec.get("from") == "nauvis" and rec.get("to") == "vulcanus" and rec.get("d") == 250 and rec.get("len") == 15000
      and rec.get("sp") == 150 and rec.get("st") == "on_the_path" and "loc" not in rec,
      f"plat: travelling, with the way done in thousandths and the speed in km/s: {rec}")
# Owner's G9: a platform sent the other way along its connection (to its `from` end) counts its
# distance down in 2.1.23; the journey reads from where it left to where it goes, d counting up.
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})  # keep-alive: these checks take a few seconds
pdata = F.platform_data[plat]
pdata.schedule = lua.table_from({"current": 1, "records": lua.table_from([lua.table_from({"station": "nauvis"})])})
F.platform_travel(plat, "nauvis-vulcanus", 0.75, 2.5)
rec = next_plat()["l"][0]
check(rec.get("from") == "vulcanus" and rec.get("to") == "nauvis" and rec.get("d") == 250 and rec.get("len") == 15000,
      f"plat: heading to the connection's from end, the journey is turned round: {rec}")
# A stop that is neither end (a trip of several legs): the way distance moves says it.
pdata.schedule = lua.table_from({"current": 1, "records": lua.table_from([lua.table_from({"station": "solar-system-edge"})])})
pdata.distance = 0.8
rec = next_plat()["l"][0]
check(rec.get("from") == "nauvis" and rec.get("d") == 800, f"plat: distance going up reads forwards: {rec}")
pdata.distance = 0.7
rec = next_plat()["l"][0]
check(rec.get("from") == "vulcanus" and rec.get("to") == "nauvis" and rec.get("d") == 300, f"plat: distance going down reads backwards: {rec}")
rec = next_plat()["l"][0]
check(rec.get("from") == "vulcanus" and rec.get("d") == 300, f"plat: and stays so while it stands still: {rec}")
pdata.schedule = lua.table_from({"current": 1, "records": lua.table_from([lua.table_from({"station": "vulcanus"})])})
pdata.distance = 0.25
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
send({"t": "plat_board", "i": 0})
tick(1)
check("The platform must be stopped at a planet to drop to it" in texts(take()) and puppet.surface.name == "platform-1",
      "plat_board 0 while travelling is refused")
F.platform_arrive(plat, "vulcanus")
send({"t": "plat_board", "i": 0})
tick(2)
surf = of_type(take(), "surface")
check(surf and surf[0]["surface"] == "vulcanus" and surf[0]["planet"] == "vulcanus" and "pf" not in surf[0] and puppet.surface.name == "vulcanus",
      f"plat_board 0 drops to the planet the platform is stopped at, making its surface: {surf}")
send({"t": "plat_board", "i": 1})
tick(2)
check(puppet.surface.name == "platform-1", "and plat_board takes it back up to the platform in orbit there")
planet = of_type(take(), "planet")
check(planet and planet[-1]["name"] == "space", f"planet: on a platform it is space: {planet[-1:]}")
# In the hub (where a rocket leaves it) the character can't be a passenger or move on its surface,
# so land hops it to the planet and back beside the hub first.
F.entity_data(puppet).hub = plat.hub
send({"t": "land"})
tick(1)
check(any(m["text"] == "Going down to vulcanus in a cargo pod" for m in of_type(take(), "msg")) and same(F.pod_passenger, puppet)
      and puppet.surface.name == "platform-1" and puppet.hub is None,
      "land: from inside the hub down to the planet the platform is stopped at, in a cargo pod with the character inside")
tick(2)
me = of_type(take(), "me")
pod = puppet.cargo_pod
check(pod is not None and me and me[-1].get("pod") == pod.unit_number and me[-1].get("ps") == "awaiting_launch" and me[-1].get("up") == 1
      and (me[-1].get("gx"), me[-1].get("gy")) == (fixed(plat.hub.position.x), fixed(plat.hub.position.y)) and "hub" not in me[-1],
      f"me: the pod, its state and the hub it leaves from: {me[-1:]}")
pod_data = F.entity_data(pod)
land_at = pod_data.cargo_pod_destination.position
pod_data.cargo_pod_state = "descending"
pod_data.surface = g.game.planets["vulcanus"].surface
send({"t": "walk", "d": 4})
send({"t": "mine", "u": 0, "p": 0, "x": 0, "y": 0})
tick(2)
msgs = take()
me = of_type(msgs, "me")
check(me and me[-1].get("up") == 0 and (me[-1]["gx"], me[-1]["gy"]) == (fixed(land_at.x), fixed(land_at.y)) and "Not while flying" in texts(msgs)
      and me[-1]["w"] == 0, f"me: coming down, the spot it lands on; walking and mining wait: {me[-1:]} {texts(msgs)}")
F.pod_arrive(pod)
tick(2)
msgs = take()
me = of_type(msgs, "me")
check(puppet.surface.name == "vulcanus" and me and "pod" not in me[-1] and of_type(msgs, "surface"),
      f"the pod lands and the character stands on the planet: {me[-1:]}")
send({"t": "plat_board", "i": 1})
tick(2)
take()
F["raise"]("on_space_platform_changed_state", lua.table_from({"platform": plat, "old_state": g.defines.space_platform_state.on_the_path}))
tick(1)
pst = of_type(take(), "pst")
check(pst and pst[-1]["i"] == 1 and pst[-1]["old"] == "on_the_path" and pst[-1]["loc"] == "vulcanus", f"pst: a platform arriving: {pst}")

send({"t": "plat_pause", "i": 1, "p": 1})
send({"t": "plat_sched", "i": 1, "l": ["nauvis", "vulcanus", "nowhere"], "c": 2})
tick(1)
take()
rec = next_plat()["l"][0]
check(rec.get("pa") == 1 and rec.get("st") == "paused" and rec.get("sch") == {"c": 2, "l": ["nauvis", "vulcanus"]},
      f"plat_pause and plat_sched (unknown places dropped, current record set): {rec}")
lines = platform_console("leave nauvis")
tick(2)
surf = of_type(take(), "surface")
check(any("moved to nauvis" in l for l in lines) and surf and surf[0]["planet"] == "nauvis" and puppet.surface.name == "nauvis",
      f"/f3d-platform leave <planet> brings the character home: {lines} {surf}")
send({"t": "plat_board", "i": 1})
tick(1)
check("That platform isn't in orbit here" in texts(take()) and puppet.surface.name == "nauvis",
      "plat_board refuses a platform orbiting another planet")
lines = platform_console("list")
check(any("platform 1 Platform 1: paused at vulcanus" in l for l in lines), f"/f3d-platform list: {lines}")
send({"t": "sub", "c": [[0, 0]]})
tick(3)
take()

# --- Space Age screens: space map, new platforms, silo, hub, landing pad, collector, quality ------
send({"t": "smap"})
tick(1)
sm = of_type(take(), "smap")
locs = {r[0]: r for r in (sm[0]["loc"] if sm else [])}
cons = {(r[0], r[1]): r for r in (sm[0]["con"] if sm else [])}
check(sm and locs.get("nauvis") == ["nauvis", "planet", 0, -5000, 1, 1, 1000, 1, 250] and locs.get("vulcanus", [0] * 9)[4] == 1
      and locs.get("vulcanus", [0] * 9)[6] == 1500 and locs.get("solar-system-edge", [0] * 9)[7] == 0
      and locs.get("solar-system-edge", [0] * 6)[4] == 0,
      f"smap: space locations with star map positions, unlocked and surfaces: {sm}")
check(cons.get(("nauvis", "solar-system-edge"), [0] * 4)[3] == 1000 and 0 < cons.get(("nauvis", "vulcanus"), [0] * 4)[3] < 1000
      and cons.get(("nauvis", "vulcanus"), [0] * 4)[2] == 15000, f"smap: connections with length and asteroid danger: {cons}")

send({"t": "plat_new"})
tick(1)
check("You need a space platform starter pack" in texts(take()), "plat_new needs a starter pack")
puppet.insert(lua.table_from({"name": "space-platform-starter-pack", "count": 1}))
send({"t": "plat_new"})
tick(1)
msgs = take()
plat2 = g.game.forces.player.platforms[2]
check(plat2 is not None and plat2.state == g.defines.space_platform_state.waiting_for_starter_pack and plat2.space_location.name == "nauvis"
      and puppet.get_main_inventory().get_item_count("space-platform-starter-pack") == 1,
      f"plat_new: a platform over the planet waits for the pack, which stays in the inventory: {texts(msgs)}")

pp = puppet.position
silo_e = spawn("rocket-silo", pp.x + 7.5, pp.y + 0.5, force="player")
send(open_cmd(silo_e))
tick(2)
gs = guis(take(), silo_e)
rk = gs[-1].get("rk", {}) if gs else {}
check(gs and gs[-1]["kind"] == "silo" and rk.get("st") == "building_rocket" and rk.get("auto") == 0
      and [2, "Platform 2", "waiting_for_starter_pack"] in rk.get("to", []) and "rocket" in gs[-1].get("slots", {}),
      f"a silo's screen: status, automatic launch, platforms to launch to, the rocket's cargo: {gs[-1:]}")
send({"t": "set_silo", "u": silo_e.unit_number, "auto": 1})
send({"t": "silo_launch", "u": silo_e.unit_number, "to": 2})
tick(1)
check(silo_e.send_to_orbit_automatically and "The rocket isn't ready" in texts(take()),
      "set_silo turns automatic launches on; silo_launch without a rocket ready is refused")
silo_e.rocket_silo_status = g.defines.rocket_silo_status.rocket_ready
send({"t": "silo_launch", "u": silo_e.unit_number, "to": 2})
tick(1)
take()
check(F.launched and F.launched.type == g.defines.cargo_destination.space_platform and same(F.launched.space_platform, plat2),
      "silo_launch to a platform waiting for its starter pack sends the pack to it")
plat2.apply_starter_pack()
silo_e.rocket_silo_status = g.defines.rocket_silo_status.rocket_ready
send({"t": "silo_launch", "u": silo_e.unit_number, "to": 2})
tick(1)
take()
check(F.launched.type == g.defines.cargo_destination.station and same(F.launched.station, plat2.hub),
      "silo_launch to a built platform lands at its hub")

# Riding the rocket up (#10): into its pod, up to the platform's hub, and inside the hub (#17).
send({"t": "ride", "u": silo_e.unit_number, "to": 2})
tick(1)
check("The rocket isn't ready" in texts(take()) and puppet.cargo_pod is None, "ride: no rocket ready, no ride")
silo_e.rocket_silo_status = g.defines.rocket_silo_status.rocket_ready
send({"t": "ride", "u": silo_e.unit_number, "to": 2})
tick(2)
msgs = take()
me = of_type(msgs, "me")
pod = puppet.cargo_pod
check(pod is not None and same(F.launched.station, plat2.hub) and me and me[-1].get("pod") == pod.unit_number
      and me[-1].get("up") == 1 and (me[-1]["gx"], me[-1]["gy"]) == (fixed(silo_e.position.x), fixed(silo_e.position.y)),
      f"ride: the character is in the rocket's cargo pod, seen from the silo: {me[-1:]} {texts(msgs)}")
send({"t": "ride", "u": silo_e.unit_number, "to": 2})
tick(1)
check("Not while flying" in texts(take()), "ride: one ride at a time")
F.pod_arrive(pod)
tick(2)
msgs = take()
me = of_type(msgs, "me")
surf = of_type(msgs, "surface")
check(surf and surf[0].get("pf") == 2 and me and me[-1].get("hub") == plat2.hub.unit_number and "pod" not in me[-1],
      f"the pod docks: the character is inside the platform's hub (me.hub): {surf} {me[-1:]}")
send({"t": "sub", "c": [[0, 0], [-1, -1], [-1, 0], [0, -1]]})
tick(3)
take()
at = (puppet.position.x, puppet.position.y)
send({"t": "walk", "d": 4})
tick(3)
send({"t": "walk", "d": -1})
send({"t": "mine", "u": 0, "p": 0, "x": fixed(at[0] + 3), "y": fixed(at[1])})
puppet.insert(lua.table_from({"name": "wooden-chest", "count": 1}))
chests = puppet.get_main_inventory().get_item_count("wooden-chest")
send({"t": "build", "item": "wooden-chest", "x": fixed(at[0] + 6.5), "y": fixed(at[1] + 0.5), "d": 0})
tick(2)
msgs = take()
ghosts = [e for e in puppet.surface.entities.values() if e.name == "entity-ghost"]
check((puppet.position.x, puppet.position.y) == at and "Not from inside the hub" in texts(msgs) and ghosts
      and puppet.get_main_inventory().get_item_count("wooden-chest") == chests,
      f"in the hub: no walking or mining; building places a ghost: {texts(msgs)} {len(ghosts)} ghosts")
for e in ghosts:
    e.destroy()
send({"t": "land"})
tick(2)
pod = puppet.cargo_pod
check(pod is not None and puppet.hub is None and "Going down to nauvis in a cargo pod" in texts(take()),
      "land from the hub over Nauvis: into a pod")
F.pod_arrive(pod)
puppet.teleport(lua.table_from({"x": pp.x, "y": pp.y}), F.surface)
tick(3)
take()
send({"t": "sub", "c": [[0, 0]]})
tick(3)
take()
send(open_cmd(silo_e))
tick(1)
take()
send({"t": "close"})

F.effects = lua.table_from({"quality": 0.025, "speed": -0.05})
qasm = spawn("assembling-machine-1", pp.x - 6.5, pp.y + 0.5, force="player")
F.effects = None
send(open_cmd(qasm))
send({"t": "set_recipe", "u": qasm.unit_number, "recipe": "iron-gear-wheel", "q": "uncommon"})
tick(2)
gs = guis(take(), qasm)
check(gs and gs[-1].get("rq") == "uncommon" and gs[-1].get("ql") == ["normal", "uncommon", "rare"]
      and gs[-1].get("eff") == {"q": 25, "sp": -50},
      f"a machine's screen: the recipe's quality, the qualities to choose from, module effects: {gs[-1:]}")

send({"t": "set_recipe", "u": qasm.unit_number, "recipe": "iron-gear-wheel", "q": "epic"})
tick(1)
check("That quality isn't researched" in texts(take()), "set_recipe refuses a quality the force hasn't researched")
# G12: the hover panel's beacon and module effects (`hinfo`): a machine's effects, modules and the
# beacons reaching it; a beacon's effects, modules, the machines it reaches and its effectivity.
F.effects = lua.table_from({"speed": 0.5, "consumption": 1.2})
hbeacon = spawn("beacon", qasm.position.x + 3, qasm.position.y, force="player")
F.effects = None
hbeacon.get_module_inventory().insert(lua.table_from({"name": "speed-module", "count": 2}))
send({"t": "hinfo", "q": 3, "u": qasm.unit_number, "p": 0, "x": fixed(qasm.position.x), "y": fixed(qasm.position.y)})
send({"t": "hinfo", "q": 4, "u": hbeacon.unit_number, "p": 0, "x": fixed(hbeacon.position.x), "y": fixed(hbeacon.position.y)})
send({"t": "hinfo", "q": 5, "u": 999999, "p": 0, "x": fixed(500), "y": fixed(500)})
tick(1)
hi = {m["q"]: m for m in of_type(take(), "hinfo")}
check(hi.get(3, {}).get("eff") == {"q": 25, "sp": -50} and hi[3].get("b") == 1 and "n" not in hi[3],
      f"hinfo for a machine: its effects and the beacons reaching it: {hi.get(3)}")
check(hi.get(4, {}).get("eff") == {"sp": 500, "co": 1200} and hi[4].get("m") == [["speed-module", 2]]
      and hi[4].get("n") == 1 and hi[4].get("de") == 1500,
      f"hinfo for a beacon: what it hands on, its modules, the machines it reaches, its effectivity: {hi.get(4)}")
check(hi.get(5) is not None and not any(k in hi[5] for k in ("eff", "m", "b", "n", "de", "el")),
      f"hinfo for nothing there answers with nothing: {hi.get(5)}")
# H20: what the entity info's "Consumes electricity" shows: the buffer (the Electricity bar), Max.
# consumption (75 kW and the 2.5 kW drain) and Min. consumption (the drain); a beacon here has no
# electric source in the fake, so none.
check(hi.get(3, {}).get("el") == {"e": 1000, "b": 1000, "mx": 77500, "mn": 2500} and "el" not in hi.get(4, {}),
      f"hinfo for a powered machine: its energy, buffer, max. and min. consumption: {hi.get(3)}")
# H14: a hovered roboport's links to the roboports its logistic cell is joined to (the game's
# LuaLogisticCell.neighbours): one 45 tiles away is, one 120 tiles away isn't.
rp1 = spawn("roboport", pp.x + 400, pp.y, force="player")
rp2 = spawn("roboport", pp.x + 445, pp.y + 10, force="player")
spawn("roboport", pp.x + 520, pp.y, force="player")
send({"t": "hinfo", "q": 8, "u": rp1.unit_number, "p": 0, "x": fixed(rp1.position.x), "y": fixed(rp1.position.y)})
tick(1)
hr = {m["q"]: m for m in of_type(take(), "hinfo")}.get(8, {})
check(hr.get("rn") == [fixed(rp2.position.x), fixed(rp2.position.y)],
      f"hinfo for a roboport: the roboports it links to (H14): {hr}")

send({"t": "close"})

pad = spawn("cargo-landing-pad", pp.x + 0.5, pp.y + 6.5, force="player")
send(open_cmd(pad))
tick(2)
gs = guis(take(), pad)
# Opening it makes its control behaviour, as Factorio does (circuit_settings.lua), so `cb` is there
# with everything off.
check(gs and gs[-1]["kind"] == "pad" and gs[-1].get("pad", {}).get("sec") == []
      and gs[-1]["pad"].get("cb", {}).get("req", 0) == 0 and gs[-1]["pad"].get("cb", {}).get("empty", 0) == 0
      and "chest" in gs[-1].get("slots", {}) and "trash" in gs[-1].get("slots", {}),
      f"a landing pad's screen: inventory, trash, requests, its circuit settings: {gs[-1:]}")
send({"t": "set_pad", "u": pad.unit_number, "read": 0, "req": 1})
send({"t": "set_section", "u": pad.unit_number, "i": 0, "f": [["iron-plate", "normal", 200, -1, "", -1]]})
tick(31)
gs = guis(take(), pad)
p_ = gs[-1].get("pad", {}) if gs else {}
check(p_.get("cb") == {"read": 0, "req": 1, "empty": 0} and p_.get("sec", [{}])[0].get("f") == [["iron-plate", "normal", 200, -1, "", -1]],
      f"set_pad and set_section on a landing pad: {p_}")
send({"t": "close"})

col = spawn("asteroid-collector", pp.x - 3.5, pp.y - 5.5, force="player")
send(open_cmd(col))
send({"t": "set_collector", "u": col.unit_number, "f": ["metallic-asteroid-chunk", "made-up-chunk"]})
tick(2)
gs = guis(take(), col)
check(gs and gs[-1]["kind"] == "collector" and gs[-1].get("col") == {"n": 3, "f": ["metallic-asteroid-chunk", "", ""]},
      f"an asteroid collector's chunk filters (unknown chunks cleared): {gs[-1:]}")
send({"t": "close"})

qbelt = spawn("transport-belt", pp.x + 2.5, pp.y - 2.5, force="player", direction=4)
F.put_on_belt(qbelt, 1, "iron-plate", 0.25, 77, None, "rare")
F.put_on_belt(qbelt, 2, "iron-plate", 0.5, 78)
tick(6)
bq = of_type(take(), "bq")
check(bq and bq[-1]["l"] == [[77, "rare"]], f"bq: the quality of belt items better than normal: {bq}")
qbelt.destroy()
tick(12)
bq = of_type(take(), "bq")
check(bq and bq[0]["l"] == [] and len(bq) == 1, f"bq: one empty list clears it, then nothing: {bq}")

send({"t": "plat_board", "i": 2})
tick(2)
msgs = take()
planet = of_type(msgs, "planet")
check(puppet.surface.name == "platform-2", "the character boards the new platform")
plat2.surface.props.gravity = 0
puppet.insert(lua.table_from({"name": "burner-inserter", "count": 1}))
hub = plat2.hub
hp = hub.position
send({"t": "build", "item": "burner-inserter", "x": fixed(hp.x + 5.5), "y": fixed(hp.y + 0.5), "d": 0})
tick(1)
check(any(t.startswith("Can't build here: gravity is 0") for t in texts(take())),
      "building something that needs gravity on a platform says why it can't")
nb = g.package.loaded["scripts.space"].blocked(plat2.surface)
check(to_py(nb) == [[eid["burner-inserter"], "gravity", 0.1, 1e9]], f"planet.nb: what can't be built on this surface: {to_py(nb)}")

send(open_cmd(hub))
tick(2)
gs = guis(take(), hub)
h = gs[-1].get("hub", {}) if gs else {}
check(gs and gs[-1]["kind"] == "hub" and h.get("i") == 2 and h.get("w") == 1250000 and h.get("th") == [0, 0]
      and h.get("prov") == 0 and h.get("sec") == [] and h.get("dest") == ["nauvis", "vulcanus"] and h.get("loc") == "nauvis"
      and "chest" in gs[-1].get("slots", {}) and "trash" in gs[-1].get("slots", {}),
      f"a hub's screen: its platform's state, weight, thrusters, requests, inventory and trash: {gs[-1:]}")
send({"t": "set_section", "u": hub.unit_number, "i": 0,
      "f": [["iron-plate", "uncommon", 100, 400, "vulcanus", 50], ["no-such-item", "", 1, -1, "", -1]]})
send({"t": "set_hub", "u": hub.unit_number, "prov": 1})
waits = [{"type": "all_requests_satisfied", "compare_type": "and"}, {"type": "time", "compare_type": "or", "ticks": 1800}]
send({"t": "set_schedule", "u": hub.unit_number, "records": [{"station": "vulcanus", "wait_conditions": waits}, {"station": "nowhere"}]})
send({"t": "set_interrupts", "u": hub.unit_number, "interrupts": [
    {"name": "Refuel", "conditions": [{"type": "any_request_zero", "compare_type": "and"}], "targets": [{"station": "nauvis"}]}]})
tick(31)
gs = guis(take(), hub)
h = gs[-1].get("hub", {}) if gs else {}
sec = (h.get("sec") or [{}])[0]
check(sec.get("f") == [["iron-plate", "uncommon", 100, 400, "vulcanus", 50]] and sec.get("on") == 1 and sec.get("man") == 1,
      f"set_section on a hub: a request from a planet with quality, max and a minimum delivery: {h.get('sec')}")
check(hub.providing_to_other_platforms and h.get("prov") == 1, "set_hub: provide to other platforms")
sched = h.get("sched", {})
check([r["station"] for r in sched.get("records", [])] == ["vulcanus"] and sched["records"][0]["wait_conditions"] == waits
      and sched.get("interrupts", [{}])[0].get("name") == "Refuel" and sched["interrupts"][0]["targets"][0]["station"] == "nauvis",
      f"the hub edits its platform's schedule and interrupts like a train's (unknown places dropped): {sched}")
send({"t": "set_section", "u": hub.unit_number, "i": 1, "on": 0, "m": 2})
send({"t": "set_section", "u": hub.unit_number, "i": 0})
tick(31)
gs = guis(take(), hub)
secs = gs[-1].get("hub", {}).get("sec", []) if gs else []
check(len(secs) == 2 and secs[0]["on"] == 0 and secs[0]["m"] == 2, f"set_section: off, a multiplier, a second section: {secs}")
send({"t": "set_section", "u": hub.unit_number, "i": 2, "del": 1})
tick(31)
gs = guis(take(), hub)
check(gs and len(gs[-1]["hub"]["sec"]) == 1, "set_section del removes a section")
send({"t": "set_silo", "u": hub.unit_number, "auto": 1})
tick(1)
check("That isn't a rocket silo" in texts(take()), "space commands check what the open screen is")
send({"t": "close"})

data2 = F.platform_data[plat2]
data2.chunks[1] = lua.table_from({"name": "metallic-asteroid-chunk", "position": {"x": hp.x + 10, "y": hp.y - 4},
                                  "movement": {"x": 0, "y": 0.05}}, recursive=True)
tick(10)
ach = of_type(take(), "ach")
check(ach and ach[-1]["l"] == [["metallic-asteroid-chunk", fixed(hp.x + 10), fixed(hp.y - 4), 0, 768]],
      f"ach: asteroid chunks near the focus on a platform, moving 0.05 tiles a tick: {ach}")
data2.chunks[1] = None
tick(20)
ach = of_type(take(), "ach")
check(len(ach) == 1 and ach[0]["l"] == [], f"ach: one empty list once they're gone: {ach}")
# Whether the empty list is owed is kept per client: a second client (on Nauvis, no chunks) ticking
# in turn doesn't use up the first one's.
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
send({"t": "hello", "v": 1, "sid": "ach-b", "w": 0}, port=PORT_B)
tick(3)
take_by_port()
data2.chunks[1] = lua.table_from({"name": "metallic-asteroid-chunk", "position": {"x": hp.x + 10, "y": hp.y - 4},
                                  "movement": {"x": 0, "y": 0}}, recursive=True)
tick(10)
take_by_port()
data2.chunks[1] = None
tick(20)
ach = of_type(take_by_port().get(CLIENT_PORT, []), "ach")
check(len(ach) == 1 and ach[0]["l"] == [], f"ach: the empty list reaches its client with another client connected: {ach}")
send({"t": "bye"}, port=PORT_B)
tick(1)
take_by_port()

# Asteroid collectors' arms (`acol`, F3): their arms, speed and filters, and the chunks they catch,
# seen as chunks gone from their catch circle (5 tiles in front, radius 7.5).
def made(name, x, y, **extra):
    return puppet.surface.create_entity(lua.table_from({"name": name, "position": {"x": x, "y": y}, "force": "player", **extra},
                                                       recursive=True))


acol_n = made("asteroid-collector", hp.x, hp.y - 8)
acol_r = made("asteroid-collector", hp.x + 20, hp.y, direction=4, quality="rare")
acol_r.set_filter(1, "carbonic-asteroid-chunk")
tick(60)  # the mod looks for collectors near the focus once a second
rows = {r[0]: r for m in of_type(take(), "acol") for r in m.get("l", [])}
check(rows.get(acol_n.unit_number) == [acol_n.unit_number, 1, 200, 1, []]
      and rows.get(acol_r.unit_number) == [acol_r.unit_number, 3, 300, 1, ["carbonic-asteroid-chunk"]],
      f"acol: each collector's arms and arm speed by quality, moving, its filters: {rows}")
caught_chunk = lua.table_from({"name": "metallic-asteroid-chunk", "position": {"x": hp.x + 1, "y": hp.y - 15},
                               "movement": {"x": 0.01, "y": 0}}, recursive=True)
data2.chunks[1] = caught_chunk
# Inside the east-facing collector's box but outside its circle: not caught when it goes.
data2.chunks[2] = lua.table_from({"name": "carbonic-asteroid-chunk", "position": {"x": hp.x + 33.5, "y": hp.y + 6.5},
                                  "movement": {"x": 0, "y": 0}}, recursive=True)
tick(10)
take()
caught_chunk.position = lua.table_from({"x": hp.x + 1.1, "y": hp.y - 15})
tick(10)
check(not any(m.get("g") for m in of_type(take(), "acol")), "acol: a chunk where its movement takes it isn't caught")
data2.chunks[1] = None
data2.chunks[2] = None
tick(10)
msgs = of_type(take(), "acol")
check([g for m in msgs for g in m.get("g", [])] == [[acol_n.unit_number, "metallic-asteroid-chunk", fixed(hp.x + 1.2), fixed(hp.y - 15)]],
      f"acol g: the chunk gone from a collector's circle, caught where it had drifted to (not the one outside it): {msgs}")
# A chunk the filter leaves alone isn't counted when it goes (it hit the platform, or something else took
# it): the rare collector takes only carbonic chunks.
data2.chunks[1] = lua.table_from({"name": "metallic-asteroid-chunk", "position": {"x": hp.x + 25, "y": hp.y + 1},
                                  "movement": {"x": 0, "y": 0}}, recursive=True)
tick(10)
take()
data2.chunks[1] = None
tick(10)
check(not [g for m in of_type(take(), "acol") for g in m.get("g", [])],
      "acol g: a chunk its collector's filter leaves alone isn't counted as caught when it leaves the circle")
acol_n.status = g.defines.entity_status.low_power
acol_r.status = g.defines.entity_status.disabled_by_control_behavior
tick(10)
rows = {r[0]: r for m in of_type(take(), "acol") for r in m.get("l", [])}
check(rows.get(acol_n.unit_number, [0] * 4)[2:4] == [60, 1] and rows.get(acol_r.unit_number, [0] * 4)[3] == 2,
      f"acol: low power slows the arms (unpowered_arm_speed_scale); switched off by the circuit network they fold home (2, G10): {rows}")
acol_n.destroy()
acol_r.destroy()
send({"t": "plat_board", "i": 0})
tick(2)
take()
check(puppet.surface.name == "nauvis", "and back down to Nauvis")
send({"t": "sub", "c": [[0, 0]]})
tick(3)
take()

# --- client restart and timeout ------------------------------------------------------------------
send({"t": "rate", "l": 2})
send({"t": "hello", "v": 1, "sid": "s2", "w": 0})
tick(3)
msgs = take()
check(msgs and msgs[0]["t"] == "welcome" and msgs[0]["r"] == 1, "a new client session restarts the sequence")
check(rate.level() == 0, "and starts at rate 0 (the old session's `rate` doesn't carry over)")
drop_box = spawn("wooden-chest", puppet.position.x + 1.5, puppet.position.y + 0.5, force="player")
send(open_cmd(drop_box))
tick(2)
take()
had_screen = g.storage.f3d.screen is not None
tick(700)
check(g.storage.f3d.client is None, "client is dropped after 10 s without hello")
check(had_screen and g.storage.f3d.screen is None, f"a dropped client's machine screen is closed (one was open: {had_screen})")
drop_box.destroy()
take()
tick(5)
check(take() == [], "nothing is sent after the client is dropped")
# With no client nothing empties the pipe refresh list (tracker.tick runs only with one), and it is
# saved with the game: removing a pipe then adds nothing to it.
lone_pipe = spawn("pipe", 60.5, 60.5, force="player")
F["raise"]("script_raised_destroy", lua.table_from({"entity": lone_pipe}))
lone_pipe.destroy()
tick(2)
check(len(g.storage.f3d.pipe_refresh) == 0, f"no client: a pipe removed leaves nothing queued in storage ({len(g.storage.f3d.pipe_refresh)})")

# --- /f3d-selftest and a respawn on a server -------------------------------------------------------
def selftest(**cmd):
    before = len(F.printed)
    F.commands["f3d-selftest"](lua.table_from(dict(cmd, name="f3d-selftest")))
    return [str(p) for p in list(F.printed.values())[before:]]


send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
tick(2)
take()
puppet = g.storage.f3d.puppet
chest = spawn("wooden-chest", puppet.position.x + 2, puppet.position.y + 1, force="player")
lines = selftest()
check(any("PASS the bridge's character has no player" in l for l in lines) and any("PASS character.selected can be set" in l for l in lines)
      and not any("FAIL" in l for l in lines), f"/f3d-selftest on a server: {lines}")
check(any("PASS string.pack and string.unpack (binary frames)" in l for l in lines)
      and any(("INFO binary frames: on" if BINARY else "INFO binary frames: off for this client") in l for l in lines),
      f"/f3d-selftest: string.pack round trip, and this client gets no binary frames (its hello doesn't ask): {lines[-2:]}")
chest.destroy()
old_unit = puppet.unit_number
puppet.destroy()
tick(2)
welcome = of_type(take(), "welcome")
check(welcome and welcome[-1]["u"] != old_unit and welcome[-1]["u"] == g.storage.f3d.puppet.unit_number,
      "a new character after the old one died starts over with a welcome naming it")
puppet = g.storage.f3d.puppet

