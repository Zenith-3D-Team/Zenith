# Regression checks for the 21 reported bugs + bonus checks (mod side: #6, #7, #9, #14, #15, #17, #20, #21).
reg = g.package.loaded["scripts.registry"]
eid_of = lambda name: int(reg.entity_id(name))
puppet = g.storage.f3d.puppet
puppet.teleport(lua.table_from({"x": 325.0, "y": 325.0}), F.surface)
F.charted["10,10"] = True
pp = puppet.position
send({"t": "hello", "v": 1, "sid": "s1", "w": 1})
send({"t": "sub", "c": [[10, 10]]})
send({"t": "focus", "x": fixed(pp.x), "y": fixed(pp.y), "r": 64})
tick(5)
take()

# --- Bugs #6 & #20: paste_settings copies compatible rotation (guarding collision) and emits ui_sfx ---
ins_src = spawn("inserter", pp.x + 2.5, pp.y + 0.5, force="player", direction=4)
ins_dst = spawn("inserter", pp.x + 4.5, pp.y + 0.5, force="player", direction=0)
send({"t": "paste_settings", "f": [ins_src.unit_number, eid_of(ins_src.name), fixed(pp.x + 2.5), fixed(pp.y + 0.5)], **target_of(ins_dst)})
tick(2)
msgs = take()
sfx = [m["s"] for m in of_type(msgs, "ui_sfx")]
upds = [m["e"] for m in of_type(msgs, "upd") if m["e"][0] == ins_dst.unit_number]
check(ins_dst.direction == 4 and upds and upds[-1][4] == 4,
      f"#6: paste_settings copies rotatable entity direction and sends upd: dir={ins_dst.direction}, upd={upds[-1:]}")
check("entity-settings-pasted" in sfx, f"#20: successful paste_settings emits entity-settings-pasted ui_sfx: {sfx}")

# Cross-type square compatible rotation (fast-inserter -> inserter).
fins_src = spawn("fast-inserter", pp.x + 2.5, pp.y + 2.5, force="player", direction=12)
send({"t": "paste_settings", "f": [fins_src.unit_number, eid_of(fins_src.name), fixed(pp.x + 2.5), fixed(pp.y + 2.5)], **target_of(ins_dst)})
tick(2)
take()
check(ins_dst.direction == 12, f"#6: paste_settings copies direction across compatible square types: dir={ins_dst.direction}")

# Non-square rotation collision guard: 2x1 splitter rotated east->north when north overlaps an obstacle.
sp_src = spawn("splitter", pp.x + 10.0, pp.y + 0.5, force="player", direction=0)
sp_dst = spawn("splitter", pp.x + 14.5, pp.y + 2.0, force="player", direction=4)
sp_blk = spawn("wooden-chest", pp.x + 15.0, pp.y + 2.0, force="player")
send({"t": "paste_settings", "f": [sp_src.unit_number, eid_of(sp_src.name), fixed(pp.x + 10.0), fixed(pp.y + 0.5)], **target_of(sp_dst)})
tick(2)
take()
check(sp_dst.direction == 4, f"#6: non-square paste_settings skips rotation when rotated footprint collides: dir={sp_dst.direction}")

# Missing target emits cannot-build sound.
send({"t": "paste_settings", "f": [ins_src.unit_number, eid_of(ins_src.name), fixed(pp.x + 2.5), fixed(pp.y + 0.5)],
      "u": 9999999, "p": eid_of("inserter"), "x": fixed(pp.x + 50), "y": fixed(pp.y + 50)})
tick(2)
msgs = take()
check([m["s"] for m in of_type(msgs, "ui_sfx")] == ["cannot-build"],
      f"#20: paste_settings to missing target emits cannot-build ui_sfx: {of_type(msgs, 'ui_sfx')}")
for e in (ins_src, ins_dst, fins_src, sp_src, sp_dst, sp_blk):
    e.destroy()
tick(2)
take()

# --- Bug #7: Alt-mode on placed entity-ghosts and clipboard entries ---
am_ghost = spawn("entity-ghost", pp.x + 5.5, pp.y + 5.5, force="player", inner_name="assembling-machine-1", recipe="oil-processing")
mod_ghost = spawn("entity-ghost", pp.x + 10.5, pp.y + 5.5, force="player", inner_name="assembling-machine-1",
                  item_requests=lua.table_from({"speed-module": 2, "productivity-module": 1}))
F["raise"]("script_raised_built", lua.table_from({"entity": am_ghost}))
F["raise"]("script_raised_built", lua.table_from({"entity": mod_ghost}))
tick(2)
msgs = take()
am_add = [m["e"] for m in of_type(msgs, "add") if m["e"][0] == am_ghost.unit_number]
mod_add = [m["e"] for m in of_type(msgs, "add") if m["e"][0] == mod_ghost.unit_number]
check(am_add and am_add[0][5].get("ai") == ["recipe", "oil-processing"] and am_add[0][5].get("fa") == 3,
      f"#7: placed assembler ghost carries recipe ai and fluid fa in add extra: {am_add}")
check(mod_add and mod_add[0][5].get("ai") and mod_add[0][5]["ai"][0] == "item",
      f"#7: ghost with item_requests carries item ai in add extra: {mod_add}")

# Clipboard copy includes recipe ai and fluid mask in the 5th element.
asm_clip = spawn("assembling-machine-1", pp.x + 5.5, pp.y + 15.5, force="player")
asm_clip.set_recipe("oil-processing")
send({"t": "copy", "x1": fixed(pp.x + 3), "y1": fixed(pp.y + 13), "x2": fixed(pp.x + 8), "y2": fixed(pp.y + 18), "cut": 0, "bp": 0})
tick(2)
clips = of_type(take(), "clip")
check(clips and len(clips[-1]["l"]) == 1 and len(clips[-1]["l"][0]) == 5
      and clips[-1]["l"][0][4].get("ai") == ["recipe", "oil-processing"] and clips[-1]["l"][0][4].get("fa") == 3,
      f"#7: clipboard clip entry preserves ai and fa in extra: {clips[-1:]}")
for e in (am_ghost, mod_ghost, asm_clip):
    e.destroy()
tick(2)
take()

# --- Bug #9: Machine-only craft rejected on server while listed in rdet ---
q_before = puppet.crafting_queue_size
send({"t": "craft", "recipe": "oil-processing", "n": 1})
tick(2)
msgs = take()
check(puppet.crafting_queue_size == q_before and any("cannot be crafted by hand" in t.lower() for t in texts(msgs)),
      f"#9: crafting machine-only recipe by hand is refused: msgs={texts(msgs)}")

# --- Bug #14: Take items from inserter hand and conveyor belt lanes ---
inv = puppet.get_main_inventory()
for i in range(1, 81):
    inv[i].clear()
take_ins = spawn("inserter", pp.x + 2.5, pp.y + 0.5, force="player", direction=0)
take_ins.held_stack.set_stack(lua.table_from({"name": "iron-plate", "count": 4}))
send(open_cmd(take_ins))
tick(2)
take()
send({"t": "take", "u": take_ins.unit_number, "inv": "hand", "item": "iron-plate", "n": 2})
tick(2)
take()
check(inv.get_item_count("iron-plate") == 2 and take_ins.held_stack.valid_for_read and take_ins.held_stack.count == 2,
      f"#14: screens.take inv=hand takes 2 from inserter held_stack: inv={inv.get_item_count('iron-plate')}, held={take_ins.held_stack.count}")

send({"t": "xfer", "from": "hand", "fi": 1, "k": "half", "u": take_ins.unit_number})
tick(2)
take()
check(inv.get_item_count("iron-plate") == 3 and take_ins.held_stack.count == 1,
      f"#14: xfer hand half takes 1 from inserter held_stack: inv={inv.get_item_count('iron-plate')}")

send({"t": "fast", **target_of(take_ins)})
tick(2)
take()
check(inv.get_item_count("iron-plate") == 4 and not take_ins.held_stack.valid_for_read,
      f"#14: ui_actions.fast takes remaining stack from inserter hand: inv={inv.get_item_count('iron-plate')}")

# Move from main slot to inserter hand and back.
slot_iron = next(i for i in range(1, 81) if inv[i].valid_for_read and inv[i].name == "iron-plate")
send({"t": "move", "from": "main", "fi": slot_iron, "to": "hand", "ti": 1, "n": 1, "u": take_ins.unit_number})
tick(2)
take()
check(take_ins.held_stack.valid_for_read and take_ins.held_stack.name == "iron-plate" and inv.get_item_count("iron-plate") == 3,
      f"#14: move main->hand puts item in inserter hand: inv={inv.get_item_count('iron-plate')}")
empty_slot = next(i for i in range(1, 81) if not inv[i].valid_for_read)
send({"t": "move", "from": "hand", "fi": 1, "to": "main", "ti": empty_slot, "u": take_ins.unit_number})
tick(2)
take()
check(not take_ins.held_stack.valid_for_read and inv.get_item_count("iron-plate") == 4,
      f"#14: move hand->main takes item back out of inserter hand: inv={inv.get_item_count('iron-plate')}")
send({"t": "close"})

# Belt window gui.bl + take/move/xfer on belt_1 / belt_2.
take_belt = spawn("transport-belt", pp.x + 3.5, pp.y + 0.5, force="player", direction=4)
F.put_on_belt(take_belt, 1, "copper-plate", 0.2, 8101)
F.put_on_belt(take_belt, 1, "iron-plate", 0.6, 8102)
F.put_on_belt(take_belt, 2, "coal", 0.4, 8103)
send(open_cmd(take_belt))
tick(2)
b_guis = guis(take(), take_belt)
check(b_guis and "bl" in b_guis[-1] and len(b_guis[-1]["bl"]) == 2
      and [it["name"] for it in b_guis[-1]["bl"][0]] == ["copper-plate", "iron-plate"]
      and [it["name"] for it in b_guis[-1]["bl"][1]] == ["coal"],
      f"#14: transport-belt gui sends bl=[lane1, lane2]: {b_guis[-1:]}")

send({"t": "take", "u": take_belt.unit_number, "inv": "belt_1", "item": "copper-plate", "n": 1})
tick(2)
take()
check(inv.get_item_count("copper-plate") == 1 and take_belt.get_transport_line(1).get_item_count() == 1 and take_belt.get_transport_line(2).get_item_count() == 1,
      f"#14: screens.take inv=belt_1 takes only from lane 1: copper={inv.get_item_count('copper-plate')}")

empty_slot = next(i for i in range(1, 81) if not inv[i].valid_for_read)
send({"t": "move", "from": "belt_1", "fi": 1, "to": "main", "ti": empty_slot, "u": take_belt.unit_number})
tick(2)
take()
check(inv.get_item_count("iron-plate") == 5 and take_belt.get_transport_line(1).get_item_count() == 0,
      f"#14: move belt_1->main takes lane 1 item into slot: iron={inv.get_item_count('iron-plate')}")

send({"t": "xfer", "from": "belt_2", "fi": 1, "k": "stack", "u": take_belt.unit_number})
tick(2)
take()
check(inv.get_item_count("coal") == 1 and take_belt.get_transport_line(2).get_item_count() == 0,
      f"#14: xfer belt_2 stack takes lane 2 item: coal={inv.get_item_count('coal')}")
send({"t": "close"})
for e in (take_ins, take_belt):
    e.destroy()
tick(2)
take()

# --- Bug #15: Personal roboport (mobile cell) construction alerts are suppressed ---
alerts_mod = lua.eval('package.loaded["scripts.alerts"]')
F.lnets = lua.table()
ghost_mob = spawn("entity-ghost", 12.5, 12.5, force="player", inner_name="wooden-chest")
F.lnets["nauvis"] = lua.table()
F.lnets["nauvis"][1] = F.make_network(0, lua.table_from([0, 0, 0, 0]), lua.table(),
                                      lua.table_from([F.make_cell(puppet, 450, 500)]))
alerts_mod.reset()
al_mob = to_py(alerts_mod.current())
kinds_mob = {k[0]: k for k in al_mob.get("l", [])}
check("no_material" not in kinds_mob and "no_robots" not in kinds_mob,
      f"#15: mobile personal roboport network suppresses construction alerts: {al_mob}")

robo_stat = spawn("roboport", 14.5, 14.5, force="player")
F.lnets["nauvis"][2] = F.make_network(0, lua.table_from([0, 0, 0, 0]), lua.table(),
                                      lua.table_from([F.make_cell(robo_stat, 25, 55)]))
alerts_mod.reset()
al_stat = to_py(alerts_mod.current())
kinds_stat = {k[0]: k for k in al_stat.get("l", [])}
check("no_material" in kinds_stat,
      f"#15: stationary roboport network emits construction alert for ghost: {al_stat}")
F.lnets = lua.table()
for e in (ghost_mob, robo_stat):
    e.destroy()
tick(2)
take()

# --- Bugs #17 & #21: as_player fast-replace perpendicular belt & destroy_colliding_ghosts ---
# Bug #21 via building.lua (no player): 3x3 assembler built over two 1x1 ghosts removes both ghosts.
g_sub1 = spawn("entity-ghost", pp.x + 2.5, pp.y + 2.5, force="player", inner_name="wooden-chest")
g_sub2 = spawn("entity-ghost", pp.x + 3.5, pp.y + 3.5, force="player", inner_name="transport-belt")
g_out = spawn("entity-ghost", pp.x + 6.5, pp.y + 2.5, force="player", inner_name="wooden-chest")
F["raise"]("script_raised_built", lua.table_from({"entity": g_sub1}))
F["raise"]("script_raised_built", lua.table_from({"entity": g_sub2}))
F["raise"]("script_raised_built", lua.table_from({"entity": g_out}))
tick(2)
take()
u_sub1, u_sub2 = g_sub1.unit_number, g_sub2.unit_number
inv.insert(lua.table_from({"name": "assembling-machine-1", "count": 1}))
send({"t": "build", "item": "assembling-machine-1", "x": fixed(pp.x + 3.5), "y": fixed(pp.y + 3.5), "d": 0})
tick(5)
msgs = take()
dels = {m["u"] for m in of_type(msgs, "del")}
adds = [m["e"] for m in of_type(msgs, "add") if m["e"][1] == eid_of("assembling-machine-1")]
check(adds and not g_sub1.valid and not g_sub2.valid and g_out.valid
      and u_sub1 in dels and u_sub2 in dels,
      f"#21: building 3x3 assembler over ghosts destroys overlapping ghosts and keeps non-overlapping ones: adds={adds}, valid={(g_sub1.valid, g_sub2.valid, g_out.valid)}, dels={dels}, u={(u_sub1, u_sub2)}, msgs={texts(msgs)}")
for e in [e for e in F.surface.entities.values() if e.unit_number != puppet.unit_number and e.type != "resource"]:
    e.destroy()
tick(2)
take()

# Bugs #17 & #21 via as_player.lua (with a player attached).
fake_player = F.make_player(puppet)
puppet.player = fake_player
inv.insert(lua.table_from({"name": "transport-belt", "count": 1}))
inv.insert(lua.table_from({"name": "fast-transport-belt", "count": 1}))
inv.insert(lua.table_from({"name": "assembling-machine-1", "count": 1}))
b_existing = spawn("transport-belt", pp.x + 2.5, pp.y + 0.5, force="player", direction=0)
F["raise"]("script_raised_built", lua.table_from({"entity": b_existing}))
tick(2)
take()
send({"t": "build", "item": "fast-transport-belt", "x": fixed(pp.x + 2.5), "y": fixed(pp.y + 0.5), "d": 4})
tick(5)
msgs = take()
fast_adds = [m["e"] for m in of_type(msgs, "add") if m["e"][1] == eid_of("fast-transport-belt")]
check(fast_adds and fast_adds[-1][4] == 4,
      f"#17 (as_player): fast-replacing belt uses clicked direction 4: {fast_adds}")

g_over = spawn("entity-ghost", pp.x + 5.5, pp.y + 0.5, force="player", inner_name="wooden-chest")
F["raise"]("script_raised_built", lua.table_from({"entity": g_over}))
tick(2)
take()
u_over = g_over.unit_number
send({"t": "build", "item": "assembling-machine-1", "x": fixed(pp.x + 6.5), "y": fixed(pp.y + 0.5), "d": 0})
tick(5)
msgs = take()
dels = {m["u"] for m in of_type(msgs, "del")}
check(not g_over.valid and u_over in dels,
      f"#21 (as_player): building over ghost emits del for colliding ghost: dels={dels}")

puppet.player = None
for e in [e for e in F.surface.entities.values() if e.unit_number != puppet.unit_number and e.type != "resource"]:
    e.destroy()

# Zero-footprint entity (construction-robot with tile_width=0, tile_height=0) built over a ghost preserves the ghost.
robot_proto = g.prototypes.entity["construction-robot"]
old_tw, old_th = robot_proto.tile_width, robot_proto.tile_height
robot_proto.tile_width = 0
robot_proto.tile_height = 0
inv.insert(lua.table_from({"name": "construction-robot", "count": 2}))
g_keep = spawn("entity-ghost", pp.x + 2.5, pp.y + 0.5, force="player", inner_name="wooden-chest")
F["raise"]("script_raised_built", lua.table_from({"entity": g_keep}))
tick(2)
take()
send({"t": "build", "item": "construction-robot", "x": fixed(pp.x + 2.5), "y": fixed(pp.y + 0.5), "d": 0})
tick(3)
msgs = take()
check(g_keep.valid and g_keep.unit_number not in {m["u"] for m in of_type(msgs, "del")},
      f"building 0-footprint construction-robot over entity-ghost preserves the ghost: valid={g_keep.valid}")
send({"t": "build", "item": "construction-robot", "x": fixed(pp.x + 3.5), "y": fixed(pp.y + 0.5), "d": 0, "ghost": 1, "sf": 1})
tick(2)
take()
robot_proto.tile_width, robot_proto.tile_height = old_tw, old_th
for e in [e for e in F.surface.entities.values() if e.unit_number != puppet.unit_number and e.type != "resource"]:
    e.destroy()

for i in range(1, 81):
    inv[i].clear()

# --- Batch 2 #2: Turret ammo-take false-fire guard (turret_ammo_check) -----------------------------
tur_guard = spawn("gun-turret", pp.x + 3.0, pp.y + 3.0, force="player")
t_inv = tur_guard.get_inventory(g.defines.inventory.turret_ammo)
t_inv.insert(lua.table_from({"name": "firearm-magazine", "count": 5}))
tur_guard.shooting_target = None
tick(65)  # REFRESH=60 picks up turret; SWEEP=6 records rounds=5
take()
t_inv.remove(lua.table_from({"name": "firearm-magazine", "count": 5}))  # player takes ammo out while turret has no target
tick(8)
ts_guard = [rec for m in of_type(take(), "ts") for rec in m["l"] if rec[0] == tur_guard.unit_number]
last_entry = g.storage.f3d.turret_last[tur_guard.unit_number]
check(last_entry is not None and last_entry.rounds == 0 and all(rec[2] == 0 for rec in ts_guard),
      f"B2#2: removing ammo from idle turret emits 0 shots when turret_ammo_check is on: last={last_entry and last_entry.rounds} ts={ts_guard}")

# With turret_ammo_check disabled, old behavior reports ammo drop as shots.
g.storage.f3d_perf = lua.table_from({"turret_ammo_check": False})
t_inv.insert(lua.table_from({"name": "firearm-magazine", "count": 5}))
tick(8)
take()
t_inv.remove(lua.table_from({"name": "firearm-magazine", "count": 5}))
tick(8)
ts_old = [rec for m in of_type(take(), "ts") for rec in m["l"] if rec[0] == tur_guard.unit_number]
check(any(rec[2] > 0 for rec in ts_old),
      f"B2#2: turret_ammo_check=false restores raw ammo-delta shot reporting: {ts_old}")

# Active target firing works and caps delta at MAX_AMMO_SHOTS_PER_SWEEP (8).
g.storage.f3d_perf = None
biter_tgt = spawn("small-biter", pp.x + 8.0, pp.y + 3.0, force="enemy")
t_inv.insert(lua.table_from({"name": "firearm-magazine", "count": 20}))
tur_guard.shooting_target = biter_tgt
tick(8)
take()
t_inv.remove(lua.table_from({"name": "firearm-magazine", "count": 15}))  # drop 15 rounds while actively targeting
tick(8)
ts_active = [rec for m in of_type(take(), "ts") for rec in m["l"] if rec[0] == tur_guard.unit_number]
check(any(rec[2] == 8 for rec in ts_active),
      f"B2#2: active target ammo drop reports capped shots (8): {ts_active}")
biter_tgt.destroy()
tur_guard.destroy()
tick(2)
take()

# rel-031-live: guns that never name a target (artillery: no shooting_target in 2.1.x; a spidertron's
# rockets fired by itself) count their ammo drop as shots while one of their projectiles flies near
# them, and not when the ammo is taken out by hand (turret_ammo_check on).
for gname, ammo, shell in (("artillery-turret", "artillery-shell", "artillery-projectile"), ("spidertron", "rocket", "rocket")):
    gun_e = spawn(gname, pp.x + 6.0, pp.y + 6.0, force="player")
    g_inv = gun_e.get_inventory(g.defines.inventory.artillery_turret_ammo if gname == "artillery-turret" else g.defines.inventory.spider_ammo)
    g_inv.insert(lua.table_from({"name": ammo, "count": 5}))
    tick(65)
    take()
    g_inv.remove(lua.table_from({"name": ammo, "count": 1}))  # taken out by hand: no projectile
    tick(8)
    by_hand = [rec for m in of_type(take(), "ts") for rec in m["l"] if rec[0] == gun_e.unit_number]
    check(all(rec[2] == 0 for rec in by_hand), f"rel-031-live: {gname}'s ammo taken out by hand isn't shots: {by_hand}")
    g_inv.remove(lua.table_from({"name": ammo, "count": 1}))  # fired: its projectile leaves it
    proj = spawn(shell, pp.x + 9.0, pp.y + 6.0, force="player")
    tick(8)
    fired = [rec for m in of_type(take(), "ts") for rec in m["l"] if rec[0] == gun_e.unit_number]
    check(sum(rec[2] for rec in fired) == 1, f"rel-031-live: {gname}'s shot with its projectile in flight is counted: {fired}")
    proj.destroy()
    g_inv.remove(lua.table_from({"name": ammo, "count": 1}))
    proj = spawn(shell, pp.x + 9.0, pp.y + 6.0, force="enemy")  # someone else's
    tick(8)
    other = [rec for m in of_type(take(), "ts") for rec in m["l"] if rec[0] == gun_e.unit_number]
    check(all(rec[2] == 0 for rec in other), f"rel-031-live: another force's projectile doesn't make {gname}'s drop shots: {other}")
    proj.destroy()
    gun_e.destroy()
    tick(2)
    take()

# --- Batch 2 #4: Alt-mode pipe/fluid range (alt_fluid_range) --------------------------------------
far_pipe = spawn("pipe", pp.x + 40.5, pp.y + 0.5, force="player")
F.set_fluid(far_pipe, 1, lua.table_from({"name": "water", "amount": 50.0, "temperature": 15}))
send({"t": "focus", "x": fixed(pp.x), "y": fixed(pp.y), "r": 64})
send({"t": "alt", "on": 0})
tick(65)
fl_no_alt = [m["l"][i] for m in of_type(take(), "fl") for i in range(0, len(m.get("l", [])), 6)]
check(far_pipe.unit_number not in fl_no_alt,
      f"B2#4: without Alt-mode, fluid beyond detail radius (24) is excluded: {fl_no_alt}")
send({"t": "alt", "on": 1})
tick(65)
fl_alt_on = [m["l"][i] for m in of_type(take(), "fl") for i in range(0, len(m.get("l", [])), 6)]
check(far_pipe.unit_number in fl_alt_on,
      f"B2#4: with Alt-mode on, alt_fluid_range expands fluid range to focus radius (64): {fl_alt_on}")
g.storage.f3d_perf = lua.table_from({"alt_fluid_range": False})
tick(65)
fl_alt_old = [m["l"][i] for m in of_type(take(), "fl") for i in range(0, len(m.get("l", [])), 6)]
check(far_pipe.unit_number not in fl_alt_old,
      f"B2#4: alt_fluid_range=false restores detail-radius clamp under Alt-mode: {fl_alt_old}")
g.storage.f3d_perf = None
send({"t": "alt", "on": 0})
far_pipe.destroy()
tick(2)
take()

# --- Batch 2 #8: screens.set_bar refreshes GUI immediately ----------------------------------------
bar_box = spawn("wooden-chest", pp.x + 2.5, pp.y + 0.5, force="player")
send(open_cmd(bar_box))
tick(2)
take()
send({"t": "set_bar", "u": bar_box.unit_number, "n": 4})
tick(1)
bar_guis = guis(take(), bar_box)
check(bar_guis and bar_guis[-1].get("bar") == 4,
      f"B2#8: set_bar immediately refreshes open gui with new bar: {bar_guis[-1:]}")
send({"t": "close"})
bar_box.destroy()
tick(2)
take()

# --- Batch 3 C1: rail_blocks edge cases & snap_to_rail ghost snapping -------------------------------
send({"t": "rblk", "u": []})
send({"t": "rblk", "u": [9999991, 9999992]})
tick(1)
rblk_empty = of_type(take(), "rblk")
check(len(rblk_empty) == 2 and all(m["b"] == [] for m in rblk_empty),
      f"C1: rblk handles empty and unknown unit lists cleanly: {rblk_empty}")

# rail-signal ghost snaps next to a straight-rail ghost via building.lua snap_to_rail.
rail_gh = spawn("entity-ghost", pp.x + 6.0, pp.y + 6.0, force="player", inner_name="straight-rail", direction=0)
inv.insert(lua.table_from({"name": "rail-signal", "count": 1}))
send({"t": "build", "item": "rail-signal", "x": fixed(pp.x + 6.0), "y": fixed(pp.y + 6.0), "d": 0, "ghost": 1})
tick(3)
msgs = take()
sig_gh_adds = [m["e"] for m in of_type(msgs, "add") if m["e"][1] == eid_of("entity-ghost") and m["e"][5].get("gh") == eid_of("rail-signal")]
check(len(sig_gh_adds) == 1,
      f"C1: rail-signal ghost snaps to nearby straight-rail ghost when built: {sig_gh_adds}")
for e in [e for e in F.surface.entities.values() if e.unit_number != puppet.unit_number and e.type != "resource"]:
    e.destroy()
for i in range(1, 81):
    inv[i].clear()
tick(2)
take()

# --- Batch 3 C5: non-crafter entity-ghost opens + clearing recipe on assembler ghost --------------
furn_gh = spawn("entity-ghost", pp.x + 4.0, pp.y + 4.0, force="player", inner_name="stone-furnace")
send({"t": "open", "u": furn_gh.unit_number, "p": eid_of("entity-ghost"), "x": fixed(pp.x + 4.0), "y": fixed(pp.y + 4.0)})
tick(2)
fg_guis = [m for m in of_type(take(), "gui") if m.get("u") == furn_gh.unit_number]
check(fg_guis and fg_guis[-1].get("gh") == 1 and fg_guis[-1].get("p") == eid_of("stone-furnace") and fg_guis[-1].get("kind") == "furnace",
      f"C5: stone-furnace entity-ghost opens with gh=1 and furnace kind: {fg_guis[-1:]}")
send({"t": "close"})
asm_gh = spawn("entity-ghost", pp.x + 8.0, pp.y + 4.0, force="player", inner_name="assembling-machine-1", recipe="iron-gear-wheel")
send({"t": "open", "u": asm_gh.unit_number, "p": eid_of("entity-ghost"), "x": fixed(pp.x + 8.0), "y": fixed(pp.y + 4.0)})
tick(2)
take()
send({"t": "set_recipe", "u": asm_gh.unit_number, "recipe": ""})
tick(2)
ag_guis = [m for m in of_type(take(), "gui") if m.get("u") == asm_gh.unit_number]
check(ag_guis and ag_guis[-1].get("recipe") is None,
      f"C5: set_recipe '' clears recipe on entity-ghost: {ag_guis[-1:]}")
send({"t": "close"})
furn_gh.destroy()
asm_gh.destroy()
tick(2)
take()

# --- Batch 3 C6: Fluid-input-only assembler omits spare output arrow (fa=1, no 'o' in fc) ----------
lua.execute("""
local r = game.forces.player.recipes["iron-gear-wheel"]
local rec = {
  name = "test-fluid-in-only",
  enabled = true,
  category = "crafting",
  ingredients = { { type = "fluid", name = "crude-oil", amount = 50 }, { type = "item", name = "iron-plate", amount = 1 } },
  products = { { type = "item", name = "iron-gear-wheel", amount = 1 } },
  energy = 0.5,
  hidden = false,
  prototype = r.prototype,
}
game.forces.player.recipes["test-fluid-in-only"] = rec
prototypes.recipe["test-fluid-in-only"] = rec
local ap = prototypes.entity["assembling-machine-1"]
rawset(ap, "_saved_fb", ap.fluidbox_prototypes)
rawset(ap, "fluidbox_prototypes", {
  { production_type = "input", pipe_connections = {
    { connection_type = "normal", flow_direction = "input", direction = 0, positions = { { x = 0, y = -1 } } },
  } },
  { production_type = "output", pipe_connections = {
    { connection_type = "normal", flow_direction = "output", direction = 8, positions = { { x = 0, y = 1 } } },
  } },
})
""")
asm_in = spawn("assembling-machine-1", pp.x + 5.5, pp.y + 10.5, force="player")
ax, ay = asm_in.position.x, asm_in.position.y
F.set_fluids_count(asm_in, 1)
F.fluid_conns[asm_in] = lua.table_from({
    1: {"filter": "crude-oil", "conns": [
        {"connection_type": "normal", "flow_direction": "input", "position": {"x": ax, "y": ay - 1}, "target_position": {"x": ax, "y": ay - 2}},
        {"connection_type": "normal", "flow_direction": "output", "position": {"x": ax, "y": ay + 1}, "target_position": {"x": ax, "y": ay + 2}},
    ]},
}, recursive=True)
asm_in.set_recipe("test-fluid-in-only")
alt_mode = g.package.loaded["scripts.alt_mode"]
fa_in = alt_mode.arrows(asm_in)
fc_in = to_py(alt_mode.connections(asm_in))
check(fa_in == 1 and isinstance(fc_in, list) and len(fc_in) == 1 and fc_in[0][3] == "i",
      f"C6: fluid-input-only assembler has fa=1 and excludes unused output connection: fa={fa_in} fc={fc_in}")
send({"t": "copy", "x1": fixed(ax - 2), "y1": fixed(ay - 2), "x2": fixed(ax + 2), "y2": fixed(ay + 2), "cut": 0, "bp": 0})
tick(2)
clips_c6 = of_type(take(), "clip")
check(clips_c6 and clips_c6[-1]["l"][0][4].get("fa") == 1
      and len(clips_c6[-1]["l"][0][4].get("fc", [])) == 1
      and clips_c6[-1]["l"][0][4]["fc"][0][3] == "i",
      f"C6: clip_extra preserves fa=1 and filters unused output from fc: {clips_c6[-1:]}")
asm_in.destroy()
lua.execute("""
local ap = prototypes.entity["assembling-machine-1"]
rawset(ap, "fluidbox_prototypes", ap._saved_fb)
rawset(ap, "_saved_fb", nil)
prototypes.recipe["test-fluid-in-only"] = nil
game.forces.player.recipes["test-fluid-in-only"] = nil
""")
tick(2)
take()

# --- Batch 3 C8: Lone pipe ghost sends pc=0 in add extra -------------------------------------------
pipe_gh = spawn("entity-ghost", pp.x + 2.5, pp.y + 8.5, force="player", inner_name="pipe")
F["raise"]("script_raised_built", lua.table_from({"entity": pipe_gh}))
tick(2)
pipe_adds = [m["e"] for m in of_type(take(), "add") if m["e"][0] == pipe_gh.unit_number]
check(pipe_adds and pipe_adds[0][5].get("pc") == 0,
      f"C8: lone pipe ghost carries explicit pc=0 in add extra: {pipe_adds}")
pipe_gh.destroy()
tick(2)
take()

# --- Batch 3 C11: rdet part 1 sends cm (category -> crafting machines) ------------------------------
send({"t": "hello", "v": 1, "sid": "s_rdet_c11", "w": 1})
rdet_msgs = []
for _ in range(20):
    tick(1)
    rdet_msgs.extend(of_type(take(), "rdet"))
rdet_p1 = next((m for m in rdet_msgs if m.get("part") == 1), None)
check(rdet_p1 is not None and isinstance(rdet_p1.get("cm"), dict)
      and "assembling-machine-1" in rdet_p1["cm"].get("crafting", [])
      and "character" not in rdet_p1["cm"].get("crafting", []),
      f"C11: rdet part 1 includes cm mapping crafting->machines without character: {rdet_p1 and rdet_p1.get('cm')}")

# --- Batch 3 C12: All-inventory sort (chest, cargo, trunk, trash; invalid ignored) -----------------
sort_box = spawn("wooden-chest", pp.x + 2.5, pp.y + 0.5, force="player")
b_inv = F.inventories[sort_box]["chest"]
b_inv[1].set_stack(lua.table_from({"name": "iron-plate", "count": 5}))
b_inv[3].set_stack(lua.table_from({"name": "copper-plate", "count": 3}))
b_inv[5].set_stack(lua.table_from({"name": "iron-plate", "count": 7}))
send(open_cmd(sort_box))
tick(2)
take()
send({"t": "sort", "inv": "chest", "u": sort_box.unit_number})
tick(2)
take()
check(b_inv[1].valid_for_read and b_inv[1].count + (b_inv[2].count if b_inv[2].valid_for_read else 0) >= 10
      and not b_inv[5].valid_for_read,
      "C12: sort inv=chest sorts and merges stacks in open chest")
send({"t": "close"})

sort_car = spawn("car", pp.x + 5.5, pp.y + 0.5, force="player")
c_inv = F.inventories[sort_car]["trunk"]
c_inv[2].set_stack(lua.table_from({"name": "coal", "count": 4}))
c_inv[6].set_stack(lua.table_from({"name": "coal", "count": 6}))
send(open_cmd(sort_car))
tick(2)
take()
send({"t": "sort", "inv": "trunk", "u": sort_car.unit_number})
tick(2)
take()
check(c_inv[1].valid_for_read and c_inv[1].name == "coal" and c_inv[1].count == 10 and not c_inv[6].valid_for_read,
      "C12: sort inv=trunk sorts and merges car trunk")
send({"t": "close"})

sort_wagon = spawn("cargo-wagon", pp.x + 9.0, pp.y + 0.5, force="player")
w_inv = F.inventories[sort_wagon]["cargo"]
w_inv[2].set_stack(lua.table_from({"name": "stone", "count": 2}))
w_inv[5].set_stack(lua.table_from({"name": "stone", "count": 3}))
send(open_cmd(sort_wagon))
tick(2)
take()
send({"t": "sort", "inv": "cargo", "u": sort_wagon.unit_number})
tick(2)
take()
check(w_inv[1].valid_for_read and w_inv[1].name == "stone" and w_inv[1].count == 5 and not w_inv[5].valid_for_read,
      "C12: sort inv=cargo sorts and merges cargo-wagon")
send({"t": "close"})

trash_inv = puppet.get_inventory(g.defines.inventory.character_trash)
trash_inv[3].set_stack(lua.table_from({"name": "wood", "count": 3}))
trash_inv[6].set_stack(lua.table_from({"name": "wood", "count": 4}))
send({"t": "sort", "inv": "trash"})
tick(2)
take()
check(trash_inv[1].valid_for_read and trash_inv[1].name == "wood" and trash_inv[1].count == 7 and not trash_inv[6].valid_for_read,
      "C12: sort inv=trash sorts and merges character trash")
send({"t": "sort", "inv": "fuel", "u": sort_car.unit_number})  # non-sortable role ignored safely
tick(1)
take()

for i in range(1, len(trash_inv) + 1):
    trash_inv[i].clear()
for e in (sort_box, sort_car, sort_wagon):
    e.destroy()

# --- Item #4: Lua snap_to_rail supports odd & all 16 directions for rail signals --------------------
send({"t": "sub", "c": [[10, 10]]})
send({"t": "focus", "x": fixed(pp.x), "y": fixed(pp.y), "r": 64})
tick(3)
take()
hd_rail = spawn("half-diagonal-rail", pp.x + 6.0, pp.y + 6.0, force="player", direction=1)
inv.insert(lua.table_from({"name": "rail-signal", "count": 2}))
send({"t": "build", "item": "rail-signal", "x": fixed(pp.x + 6.5), "y": fixed(pp.y + 6.5), "d": 1})
tick(3)
msgs = take()
odd_sig_adds = [m["e"] for m in of_type(msgs, "add") if m["e"][1] == eid_of("rail-signal")]
check(len(odd_sig_adds) == 1 and odd_sig_adds[0][4] == 1,
      f"Item #4: snap_to_rail preserves odd direction 1 on rail-signal beside half-diagonal-rail: {odd_sig_adds}")
for e in [e for e in F.surface.entities.values() if e.unit_number != puppet.unit_number and e.type != "resource"]:
    e.destroy()
for i in range(1, 81):
    inv[i].clear()
tick(2)
take()

# --- Item #16: Lua ghost wet-drill detection (fa=1 and fc fluid over uranium-ore, none over iron) ---
u_ore = spawn("uranium-ore", pp.x + 12.5, pp.y + 12.5, force="neutral", amount=5000)
i_ore = spawn("iron-ore", pp.x + 22.5, pp.y + 12.5, force="neutral", amount=5000)
# Give electric-mining-drill a normal pipe connection on its fluidbox so ghost_connections also emits fc.
lua.execute("""
local dp = prototypes.entity["electric-mining-drill"]
rawset(dp, "_saved_fb16", dp.fluidbox_prototypes)
rawset(dp, "fluidbox_prototypes", {
  { production_type = "input-output", pipe_connections = {
    { connection_type = "normal", flow_direction = "input-output", direction = 12, positions = { { x = -1, y = 0 } } },
  } },
})
""")
wet_gh = spawn("entity-ghost", pp.x + 12.5, pp.y + 12.5, force="player", inner_name="electric-mining-drill", direction=0)
dry_gh = spawn("entity-ghost", pp.x + 22.5, pp.y + 12.5, force="player", inner_name="electric-mining-drill", direction=0)
burn_gh = spawn("entity-ghost", pp.x + 12.5, pp.y + 12.5, force="player", inner_name="burner-mining-drill", direction=0)
F["raise"]("script_raised_built", lua.table_from({"entity": wet_gh}))
F["raise"]("script_raised_built", lua.table_from({"entity": dry_gh}))
F["raise"]("script_raised_built", lua.table_from({"entity": burn_gh}))
tick(2)
msgs = take()
wet_add = [m["e"] for m in of_type(msgs, "add") if m["e"][0] == wet_gh.unit_number]
dry_add = [m["e"] for m in of_type(msgs, "add") if m["e"][0] == dry_gh.unit_number]
burn_add = [m["e"] for m in of_type(msgs, "add") if m["e"][0] == burn_gh.unit_number]
check(bool(wet_add) and wet_add[0][5].get("fa") == 1
      and any(c[4] == "sulfuric-acid" for c in wet_add[0][5].get("fc", [])),
      f"Item #16: ghost electric-mining-drill over uranium-ore emits fa=1 and sulfuric-acid fc: {wet_add}")
check(bool(dry_add) and dry_add[0][5].get("fa") is None and dry_add[0][5].get("fc") is None,
      f"Item #16: ghost electric-mining-drill over iron-ore omits fa and fc: {dry_add}")
check(bool(burn_add) and burn_add[0][5].get("fa") is None,
      f"Item #16: ghost burner-mining-drill over uranium-ore omits fa: {burn_add}")
lua.execute("""
local dp = prototypes.entity["electric-mining-drill"]
rawset(dp, "fluidbox_prototypes", dp._saved_fb16)
rawset(dp, "_saved_fb16", nil)
""")
for e in (wet_gh, dry_gh, burn_gh, u_ore, i_ore):
    e.destroy()
tick(2)
take()

# --- Other #1: Lua inserters.put_by_hand immediately flushes `ie` packet on the same tick -----------
send({"t": "hello", "v": 1, "sid": "s_zdrop_flush", "w": 1, "ie": 1, "ho": 1})
tick(5)
take()
z_belt = spawn("transport-belt", pp.x + 2.5, pp.y + 0.5, force="player", direction=4)
F.put_on_belt(z_belt, 1, "iron-plate", 0.5, 9101)
ins_mod = g.package.loaded["scripts.inserters"]
got_put = ins_mod.put_by_hand(z_belt, pp.x + 2.5, pp.y + 0.5)
flush_msgs = take()  # BEFORE advancing any tick: must already be flushed to UDP!
ie_flush = of_type(flush_msgs, "ie")
has_drop_ev = any(
    len(m["l"]) >= 9 and m["l"][i] == 6 and m["l"][i + 1] == 0 and m["l"][i + 5] == 9101
    for m in ie_flush for i in range(0, len(m["l"]), 9)
)
check(got_put == 1 and has_drop_ev,
      f"Other #1: put_by_hand flushes ie EV_PLACED (kind=6, unit=0, uid=9101) immediately without waiting for timer: got={got_put}, ie={ie_flush}")
z_belt.destroy()
tick(2)
take()

# --- Other #2: Lua planners.lua clipboard i == -2 export and optional `to` slot save ----------------
for i in range(1, 81):
    inv[i].clear()
clip_src = spawn("wooden-chest", pp.x + 3.5, pp.y + 0.5, force="player")
send({"t": "copy", "x1": fixed(pp.x + 2.0), "y1": fixed(pp.y - 1.0), "x2": fixed(pp.x + 5.0), "y2": fixed(pp.y + 2.0), "cut": 0, "bp": 0})
tick(2)
take()
# Export clipboard string (i == -2, no `to`).
send({"t": "bp_get", "q": 901, "i": -2})
tick(2)
bp_clip_msgs = of_type(take(), "bp")
check(len(bp_clip_msgs) == 1 and bp_clip_msgs[0].get("q") == 901 and bp_clip_msgs[0].get("i") == -2
      and bp_clip_msgs[0].get("item") == "blueprint" and bool(bp_clip_msgs[0].get("s")),
      f"Other #2: bp_get i=-2 exports clipboard blueprint string: {bp_clip_msgs}")
# Save clipboard directly into first empty slot (to=0).
send({"t": "bp_get", "q": 902, "i": -2, "to": 0})
tick(2)
ok_to0 = of_type(take(), "bp_ok")
check(len(ok_to0) == 1 and ok_to0[0].get("q") == 902 and ok_to0[0].get("i") == 1
      and ok_to0[0].get("item") == "blueprint" and inv[1].valid_for_read and inv[1].name == "blueprint"
      and inv[1].is_blueprint_setup(),
      f"Other #2: bp_get i=-2 to=0 saves clipboard into first empty main slot 1: {ok_to0}")
# Save clipboard directly into specific empty slot (to=5).
send({"t": "bp_get", "q": 903, "i": -2, "to": 5})
tick(2)
ok_to5 = of_type(take(), "bp_ok")
check(len(ok_to5) == 1 and ok_to5[0].get("q") == 903 and ok_to5[0].get("i") == 5
      and inv[5].valid_for_read and inv[5].name == "blueprint" and inv[5].is_blueprint_setup(),
      f"Other #2: bp_get i=-2 to=5 saves clipboard into main slot 5: {ok_to5}")
# Saving into occupied slot 5 returns an error without overwriting.
send({"t": "bp_get", "q": 904, "i": -2, "to": 5})
tick(2)
err_occ = of_type(take(), "bp")
check(len(err_occ) == 1 and err_occ[0].get("q") == 904 and "empty" in str(err_occ[0].get("err", "")).lower(),
      f"Other #2: bp_get i=-2 to=occupied slot returns error: {err_occ}")
# Saving into cursor stack (to=-1).
send({"t": "bp_get", "q": 905, "i": -2, "to": -1})
tick(2)
ok_cur = of_type(take(), "bp_ok")
check(len(ok_cur) == 1 and ok_cur[0].get("q") == 905 and ok_cur[0].get("i") == -1
      and ok_cur[0].get("item") == "blueprint",
      f"Other #2: bp_get i=-2 to=-1 copies clipboard into cursor stack: {ok_cur}")
# Guard non-numeric `to` (must error, not save to slot 0) and `bp_del` on `i == -2` (must not wipe clipboard).
inv[1].clear()
send({"t": "bp_get", "q": 906, "i": -2, "to": "bad"})
tick(2)
err_bad_to = of_type(take(), "bp")
check(len(err_bad_to) == 1 and err_bad_to[0].get("q") == 906 and "invalid" in str(err_bad_to[0].get("err", "")).lower()
      and not inv[1].valid_for_read,
      f"Other #2: bp_get with non-numeric `to` errors cleanly instead of coercing to slot 0: {err_bad_to}")
send({"t": "bp_del", "i": -2})
tick(2)
take()
send({"t": "bp_get", "q": 907, "i": -2})
tick(2)
after_del = of_type(take(), "bp")
check(len(after_del) == 1 and bool(after_del[0].get("s")) and not after_del[0].get("err"),
      f"Other #2: bp_del i=-2 does not clear clipboard: {after_del}")
clip_src.destroy()

# --- Item #3 review: fluid-wagon hinfo sends live fl fluid boxes ----------------------------------
fw_rail = spawn("straight-rail", pp.x + 6.0, pp.y + 4.0, force="player", direction=0)
fw_ent = spawn("fluid-wagon", pp.x + 6.0, pp.y + 4.0, force="player", direction=0)
F.set_fluids_count(fw_ent, 1)
F.set_fluid(fw_ent, 1, lua.table_from({"name": "crude-oil", "amount": 12000.0, "temperature": 25.0}), 50000.0)
send({"t": "hinfo", "q": 910, **target_of(fw_ent)})
tick(2)
fw_hinfo = [m for m in of_type(take(), "hinfo") if m.get("q") == 910]
check(len(fw_hinfo) == 1 and fw_hinfo[0].get("fl") == [{"fluid": "crude-oil", "amount": 12000, "capacity": 50000, "temperature": 25}],
      f"Item #3: hinfo for fluid-wagon sends live fl boxes: {fw_hinfo}")
fw_ent.destroy()
fw_rail.destroy()
for i in range(1, 81):
    inv[i].clear()

send({"t": "sub", "c": []})
tick(2)
take()
