extends "res://tests/ui_test_base.gd"
## UI test sections: world_anim.

func _binary_movers() -> void:
	const WireDecode := preload("res://scripts/net/wire_decode.gd")
	var holder := Node3D.new()
	add_child(holder)
	var vp := ProtoDB.new()
	vp.add_entities([[8, "car", "car", -0.7, -1.0, 0.7, 1.0, 1, 1, 1, 1, 1], [11, "small-biter", "unit", -0.2, -0.2, 0.2, 0.2, 1, 1, 1, 1, 1]])
	var recs := [[970, 8, 20 * 256, 20 * 256, 250], [971, 11, 22 * 256 + 17, 19 * 256 - 3], [2199023255557, 11, -5 * 256, 3 * 256]]
	var coded: Array = [recs[0]]
	for i in range(1, recs.size()):
		coded.append([recs[i][0] - recs[i - 1][0], recs[i][1] - recs[i - 1][1], recs[i][2] - recs[i - 1][2], recs[i][3] - recs[i - 1][3]]
			+ (recs[i].slice(4) as Array))
	var packed := PackedInt64Array()
	for r: Array in recs:
		packed.append_array([r[0], r[1], r[2], r[3], r[4] if r.size() > 4 else WireDecode.NO_ORIENTATION])
	var layers: Array = []
	for list: Variant in [coded, packed]:
		var layer := MoverLayer.new()
		layer.protos = vp
		holder.add_child(layer)
		var msg := {"t": "mv", "k": 1, "part": 1, "parts": 1, "p": 2, "l": list}
		if list is Array:
			msg["z"] = 1
		layer.handle(msg)
		layer._process(1.0 / 60.0)
		layers.append(layer)
	var seen: Array = []
	for layer: Node in layers:
		var got: Array = []
		for unit: int in [970, 971, 2199023255557]:
			var m = layer._movers.get(unit)
			got.append([unit, m.proto_id, m.fixed, m.oriented, snappedf(m.yaw_goal, 0.001)] if m != null else [unit])
		seen.append(got)
	check(seen[0] == seen[1] and seen[0][0].size() == 5 and seen[0][0][3] == true and seen[0][1][3] == false,
		"binary frames: movers from a packed list are those from JSON's records (orientation or none): %s vs %s" % [seen[0], seen[1]])
	check(WireDecode.mv_records({"l": packed}) == recs, "binary frames: mv_records gives a packed list as JSON's whole records")
	holder.queue_free()


## Simulated worker robots (`rb`, wire version 4): two-leg flight interpolation, Leg 1 -> Leg 2
## automatic turn and cargo flip, charging orbit, smooth error blend, epoch migration, non-clobbering
## clock updates, grid sweep, promotion/removal, and legacy `mv` TELEPORT fix.


func _robot_sim() -> void:
	const MoverRecordsScript := preload("res://scripts/world/mover_records.gd")
	const WireDecode := preload("res://scripts/net/wire_decode.gd")
	var recs: MoverRecordsScript = MoverRecordsScript.new()
	var slot := recs.alloc()
	recs.frame(100.0, 60.0, 0.0)
	# 1. Leg 1 -> Leg 2 flight, cargo flip (SIM_NEXT_CARGO), and yaw turn.
	# Leg 1: (0,0) -> (10,0) in 10 ticks (100..110), empty cargo. Leg 2: (10,0) -> (10,10) in 10 ticks (110..120), carrying cargo.
	recs.write_sim(slot, Vector2(0.0, 0.0), Vector2(10.0, 0.0), Vector2(10.0, 10.0), Vector2.ZERO,
		100.0, 110.0, 120.0, MoverRecordsScript.ANIMATED | MoverRecordsScript.BUILDER | MoverRecordsScript.SIM_NEXT_CARGO,
		1.5, 100.0, -PI * 0.5, -PI * 0.5, PI, 0.0, 0.0, 0.5, 0.0, 0.0, 0.0, 8.0, 0.0, 1.0)
	recs.frame(105.0, 60.0, 1.0 / 60.0)
	var st1 := recs.state(slot)
	var pos1: Vector3 = st1["pos"]
	check(absf(pos1.x - 5.0) < 0.02 and absf(pos1.z) < 0.02 and (int(st1["flags"]) & MoverRecordsScript.CARGO) == 0,
		"rb shader mirror: Leg 1 halfway empty at (5,0): %s flags=%d" % [pos1, int(st1["flags"])])
	recs.frame(115.0, 60.0, 1.0 / 60.0)
	var st2 := recs.state(slot)
	var pos2: Vector3 = st2["pos"]
	var anim2 := MoverRecordsScript.robot_anim(st2)
	check(absf(pos2.x - 10.0) < 0.02 and absf(pos2.z - 5.0) < 0.02 and (int(st2["flags"]) & MoverRecordsScript.CARGO) != 0 and int(anim2.z) == 1,
		"rb shader mirror: Leg 2 automatically flips cargo lamp on at (10,5): %s anim=%s" % [pos2, anim2])
	# 2. Charging HOVER vs SIM_WORKING HOVER (only SIM_WORKING extends repair arms).
	var slot_chg := recs.alloc()
	var slot_wrk := recs.alloc()
	recs.write_sim(slot_chg, Vector2(2.0, 2.0), Vector2(2.0, 2.0), Vector2(2.0, 2.0), Vector2.ZERO,
		100.0, 100.0, 100.0, MoverRecordsScript.ANIMATED | MoverRecordsScript.BUILDER,
		1.5, 100.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 8.0, 0.0, 0.0)
	recs.write_sim(slot_wrk, Vector2(4.0, 4.0), Vector2(4.0, 4.0), Vector2(4.0, 4.0), Vector2.ZERO,
		100.0, 100.0, 100.0, MoverRecordsScript.ANIMATED | MoverRecordsScript.BUILDER | MoverRecordsScript.SIM_WORKING,
		1.5, 100.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 8.0, 0.0, 0.0)
	recs.frame(160.0, 60.0, 1.0)
	var anim_chg := MoverRecordsScript.robot_anim(recs.state(slot_chg))
	var anim_wrk := MoverRecordsScript.robot_anim(recs.state(slot_wrk))
	check(int(anim_chg.z) == 0 and anim_chg.w < 0.01 and int(anim_wrk.z) == 2 and anim_wrk.w > 0.3,
		"rb construction robot extends arms only with SIM_WORKING: chg=%s wrk=%s" % [anim_chg, anim_wrk])
	# 3. SIM_ORBIT circular path + tangent speed + blend_err decay + EPOCH migration preservation.
	var slot_orb := recs.alloc()
	recs.write_sim(slot_orb, Vector2(2.0, 0.0), Vector2(0.0, 0.0), Vector2(0.0, 0.0), Vector2(0.0, 0.0),
		16380.0, 16380.0, 16380.0, MoverRecordsScript.ANIMATED | MoverRecordsScript.SIM_ORBIT,
		1.5, 16380.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 2.0, 0.05, 0.0, 8.0, 0.0, 0.1)
	recs.frame(16382.0, 60.0, 1.0 / 30.0)
	var before_ep := recs.state(slot_orb)
	recs.frame(16390.0, 60.0, 1.0 / 60.0)  # triggers epoch 1 migration
	recs.frame(16390.0, 60.0, 0.0)
	var after_ep := recs.state(slot_orb)
	var orb_r := Vector2((after_ep["pos"] as Vector3).x, (after_ep["pos"] as Vector3).z).length()
	check(absf(orb_r - 2.0) < 0.02 and float(after_ep["speed"]) > 1.0 and absf(float(after_ep["speed"]) - float(before_ep["speed"])) < 0.05,
		"rb ORBIT keeps radius=2 and speed across EPOCH migration: r=%.3f speed=%.2f" % [orb_r, float(after_ep["speed"])])
	var slot_err := recs.alloc()
	recs.write_sim(slot_err, Vector2(10.0, 0.0), Vector2(10.0, 0.0), Vector2(10.0, 0.0), Vector2(2.0, 0.0),
		16390.0, 16390.0, 16390.0, MoverRecordsScript.ANIMATED, 1.5, 16390.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 8.0, 0.0, 0.0)
	recs.frame(16390.0, 60.0, 0.0)
	var err0 := recs.position(slot_err).x
	recs.frame(16420.0, 60.0, 0.5)
	var err1 := recs.position(slot_err).x
	check(absf(err0 - 12.0) < 0.05 and absf(err1 - 10.0) < 0.1,
		"rb blend_err starts at offset and decays cleanly: %.2f -> %.2f" % [err0, err1])

	# 4. Full MoverLayer integration: packed & JSON rb, non-clobbering clock, promotion from mv, grid sweep, gone & snap, legacy TELEPORT fix.
	for name in ["logistic-robot", "construction-robot"]:
		ModelLibrary.mesh_for(name)
	var p := ProtoDB.new()
	p.add_entities([
		[5, "logistic-robot", "logistic-robot", -0.2, -0.2, 0.2, 0.2, 1, 1, 1, 1, 1],
		[6, "construction-robot", "construction-robot", -0.2, -0.2, 0.2, 0.2, 1, 1, 1, 1, 1],
		[8, "car", "car", -0.7, -1.0, 0.7, 1.0, 1, 1, 1, 1, 1],
	])
	var holder := Node3D.new()
	add_child(holder)
	var layer := MoverLayer.new()
	layer.protos = p
	layer.eprops = {5: {"x": {"spd": 0.05, "low": 0.2}}, 6: {"x": {"spd": 0.06, "low": 0.2}}}
	holder.add_child(layer)
	# Seed car on mv (p=2), then verify rb with p=20 does not inflate clock.gap.
	layer.handle({"t": "mv", "k": 100, "part": 1, "parts": 1, "p": 2, "l": [[10, 8, 0, 0, 0], [500, 5, 0, 0, 250]]})
	layer._process(1.0 / 60.0)
	var prev_slot: int = layer._movers[500].slot
	var u_packed := PackedInt64Array([
		500, 5, 100, 0, 0, 30 * 256, 0, 0, 0, 250, 0,  # promoted from mv, flying 30 tiles east at 0.05 tpt
		501, 6, 100, 10 * 256, 10 * 256, 10 * 256, 10 * 256, 0, 0, 0, 2 | 128,  # hovering working
	])
	layer.handle_robots({"t": "rb", "k": 100, "part": 1, "parts": 1, "p": 20, "sm": 1000, "u": u_packed})
	check(layer.clock.gap <= 2.5 and layer._movers[500].slot == prev_slot and layer._movers[500].sim,
		"rb keeps clock.gap at mv cadence (%.2f) and promotes mv robot reusing slot %d" % [layer.clock.gap, prev_slot])
	# Advance 200 ticks (unit 500 travels ~10 tiles east); grid sweep moves robot_near across cells.
	for step_i in 200:
		layer.handle_robots({"t": "rb", "k": 101 + step_i, "part": 1, "parts": 1, "p": 20, "sm": 1000, "u": []})
		layer._process(1.0 / 60.0)
	var p500: Variant = layer.position_of(500)
	var pos_500: Vector3 = p500 if p500 is Vector3 else Vector3.ZERO
	check(p500 is Vector3 and pos_500.x > 8.5 and layer.robot_near(Vector3(pos_500.x, 0.0, pos_500.z), 1.5),
		"rb grid sweep tracks flying robot across cells: at %s" % [p500])
	# Immediate gone removes 501; snap=1 empty resets all sim movers.
	layer.handle_robots({"t": "rb", "k": 501, "part": 1, "parts": 1, "p": 20, "sm": 1000, "u": [], "g": PackedInt32Array([501])})
	check(not layer._movers.has(501) and layer._movers.has(500), "rb gone removes only named robot immediately")
	layer.handle_robots({"t": "rb", "k": 502, "part": 1, "parts": 1, "p": 20, "sm": 1000, "snap": 1, "u": []})
	check(not layer._movers.has(500) and layer._sim_movers.is_empty(), "rb snap=1 empty u clears simulated robots")
	# JSON rb message matches packed rb record state cleanly.
	layer.handle_robots({"t": "rb", "k": 503, "part": 1, "parts": 1, "p": 20, "sm": 1000,
		"u": [502, 5, 503, 0, 0, 10 * 256, 0, 0, 0, 250, 8]})
	layer._process(1.0 / 60.0)
	var m_json: MoverLayer.Mover = layer._movers.get(502)
	check(m_json != null and m_json.sim and (m_json.sim_flags & 8) != 0, "rb accepts JSON u arrays seamlessly")
	# Legacy mv TELEPORT fix: 18 tiles jumped after 20 sleeping ticks must NOT trigger fresh teleport reset.
	layer.handle({"t": "mv", "k": 510, "part": 1, "parts": 1, "p": 2, "l": [[600, 5, 0, 0, 250]]})
	for k in range(512, 530, 2):
		layer.handle({"t": "mv", "k": k, "part": 1, "parts": 1, "p": 2, "l": [[600, 5, 0, 0, 250]]})
	layer.handle({"t": "mv", "k": 530, "part": 1, "parts": 1, "p": 2, "l": [[600, 5, 18 * 256, 0, 250]]})
	var m_fast: MoverLayer.Mover = layer._movers.get(600)
	check(m_fast != null and m_fast.ticks.size() >= 2,
		"legacy mv TELEPORT fix preserves history on 18-tile limbo jump: ticks=%d" % (m_fast.ticks.size() if m_fast else -1))

	# 5. Personal roboport return FOLLOW (RB_RETURNING) tracking + 2-stage hover/shrink DockAnim + opt-outs.
	layer.puppet_unit = 999
	layer.avatar_pos = Vector3(12.0, 0.0, 4.0)
	layer.handle_robots({"t": "rb", "k": 540, "part": 1, "parts": 1, "p": 20, "sm": 1000,
		"u": [700, 6, 540, 6 * 256, 4 * 256, 12 * 256, 4 * 256, 999, 0, 250, 4 | 1024]})
	layer._process(1.0 / 60.0)
	layer.avatar_pos = Vector3(14.0, 0.0, 5.0)
	layer._process(1.0 / 60.0)
	var m_ret: MoverLayer.Mover = layer._movers.get(700)
	check(m_ret != null and m_ret.sim_follow_unit == 999 and m_ret.sim_end1.distance_to(Vector2(14.0, 5.0)) < 0.05,
		"rb personal return FOLLOW updates target per frame toward moving avatar: end1=%s" % [m_ret.sim_end1 if m_ret else Vector2.ZERO])
	layer.handle_robots({"t": "rb", "k": 545, "part": 1, "parts": 1, "p": 20, "sm": 1000, "u": [], "g": [700]})
	check(layer.docking_count() == 1 and not layer._movers.has(700),
		"rb gone while RB_FOLLOW | RB_RETURNING spawns DockAnim: count=%d" % layer.docking_count())
	for _s in 3:
		layer._process(0.05)  # hover stage
	var d_hover: MoverLayer.DockAnim = layer._docking[0] if layer.docking_count() == 1 else null
	var h_scale: float = d_hover.node.scale.x if d_hover != null and is_instance_valid(d_hover.node) else -1.0
	var h_y: float = d_hover.node.position.y if d_hover != null and is_instance_valid(d_hover.node) else -1.0
	check(d_hover != null and h_scale > 0.95 and h_y > 1.8,
		"DockAnim stage 1 lifts to hover above character before shrinking: scale=%.2f y=%.2f" % [h_scale, h_y])
	for _s in 6:
		layer._process(0.05)  # into dive + shrink stage (0.15 + 0.30 = 0.45s)
	var d_dive: MoverLayer.DockAnim = layer._docking[0] if layer.docking_count() == 1 else null
	var d_scale: float = d_dive.node.scale.x if d_dive != null and is_instance_valid(d_dive.node) else 99.0
	check(d_dive != null and d_scale < 0.85,
		"DockAnim stage 2 shrinks robot diving into character back: scale=%.2f" % d_scale)
	for _s in 8:
		layer._process(0.05)
	check(layer.docking_count() == 0, "DockAnim cleans up after finishing: count=%d" % layer.docking_count())

	# Negative cases: logistic robot without RB_RETURNING, snap=1 removal, and --robot-dock-anim=off.
	layer.handle_robots({"t": "rb", "k": 550, "part": 1, "parts": 1, "p": 20, "sm": 1000,
		"u": [701, 5, 550, 12 * 256, 4 * 256, 14 * 256, 5 * 256, 999, 0, 250, 4]})
	layer._process(1.0 / 60.0)
	layer.handle_robots({"t": "rb", "k": 551, "part": 1, "parts": 1, "p": 20, "sm": 1000, "u": [], "g": [701]})
	check(layer.docking_count() == 0, "logistic FOLLOW without RB_RETURNING does NOT spawn DockAnim")
	layer.handle_robots({"t": "rb", "k": 552, "part": 1, "parts": 1, "p": 20, "sm": 1000,
		"u": [702, 6, 552, 12 * 256, 4 * 256, 14 * 256, 5 * 256, 999, 0, 250, 4 | 1024]})
	layer._process(1.0 / 60.0)
	layer.handle_robots({"t": "rb", "k": 553, "part": 1, "parts": 1, "p": 20, "sm": 1000, "snap": 1, "u": []})
	check(layer.docking_count() == 0, "snap=1 eviction does NOT spawn DockAnim")
	layer.dock_anim_enabled = false
	layer.handle_robots({"t": "rb", "k": 554, "part": 1, "parts": 1, "p": 20, "sm": 1000,
		"u": [703, 6, 554, 12 * 256, 4 * 256, 14 * 256, 5 * 256, 999, 0, 250, 4 | 1024]})
	layer._process(1.0 / 60.0)
	layer.handle_robots({"t": "rb", "k": 555, "part": 1, "parts": 1, "p": 20, "sm": 1000, "u": [], "g": [703]})
	check(layer.docking_count() == 0, "dock_anim_enabled=false disables DockAnim")
	layer.dock_anim_enabled = true

	# 6. Charging sparks (`RB_CHARGING`): logistic & construction robots emit roboport-charge arcs and cyan sparks when hovering/docked.
	var fx_sprites := SpriteFx.new()
	holder.add_child(fx_sprites)
	layer.vehicles.sprites = fx_sprites
	layer.handle_robots({"t": "rb", "k": 560, "part": 1, "parts": 1, "p": 20, "sm": 1000,
		"u": [
			710, 5, 560, 8 * 256, 8 * 256, 8 * 256, 8 * 256, 0, 0, 250, 2 | 256,
			711, 6, 560, 10 * 256, 8 * 256, 10 * 256, 8 * 256, 0, 0, 250, 2 | 256,
		]})
	for _s in 3:
		layer._process(0.12)
	fx_sprites._process(0.016)
	var arc_pool = fx_sprites._pools["roboport-charge"]
	var spk_pool = fx_sprites._pools["sparks"]
	check(arc_pool.cards.size() > 0 and spk_pool.cards.size() > 0,
		"RB_CHARGING HOVER emits roboport-charge arcs and sparks: arcs=%d sparks=%d" % [arc_pool.cards.size(), spk_pool.cards.size()])

	fx_sprites.clear()
	layer.handle_robots({"t": "rb", "k": 562, "part": 1, "parts": 1, "p": 20, "sm": 1000,
		"u": [
			710, 5, 562, 8 * 256, 8 * 256, 12 * 256, 8 * 256, 0, 0, 250, 1 | 256,
			711, 6, 562, 10 * 256, 8 * 256, 10 * 256, 8 * 256, 0, 0, 250, 3,
		]})
	for _s in 3:
		layer._process(0.12)
	check(fx_sprites.count() == 0, "FLY_DIR | RB_CHARGING and ORBIT without CHARGING emit no sparks: count=%d" % fx_sprites.count())

	layer.handle_robots({"t": "rb", "k": 564, "part": 1, "parts": 1, "p": 20, "sm": 1000,
		"u": [710, 5, 564, 8 * 256, 8 * 256, 8 * 256, 8 * 256, 0, 0, 250, 2]})
	for _s in 3:
		layer._process(0.12)
	check(fx_sprites.count() == 0, "Clearing RB_CHARGING stops charging sparks: count=%d" % fx_sprites.count())

	layer.robots.charge_sparks_enabled = false
	layer.handle_robots({"t": "rb", "k": 566, "part": 1, "parts": 1, "p": 20, "sm": 1000,
		"u": [710, 5, 566, 8 * 256, 8 * 256, 8 * 256, 8 * 256, 0, 0, 250, 2 | 256]})
	for _s in 3:
		layer._process(0.12)
	check(fx_sprites.count() == 0, "charge_sparks_enabled=false disables charging sparks")
	layer.robots.charge_sparks_enabled = true
	layer.vehicles.sprites = null
	holder.queue_free()


## Binary frames' wire version 3 (wire_decode.gd): an `ents` part read from its packed block with its extras
## (xi, xe) makes the same records as JSON's; a chunk's packed tiles' runs (no parsing thread) its ground; `st`'s
## packed lists apply, sliced too; plain() gives the JSON form back.


func _binary_world() -> void:
	const WireDecode := preload("res://scripts/net/wire_decode.gd")
	var json_recs := [[5100, 4, 3 * 256 + 128, 2 * 256 + 128, 4, {"d": 1, "q": "rare"}], [0, 4, 6 * 256, 7 * 256, 0],
		[5101, 4, 9 * 256 + 128, 1 * 256 + 128, 8, {"ai": ["item", "iron-plate"]}]]
	var flat := PackedInt64Array()
	for r: Array in json_recs:
		flat.append_array(r.slice(0, 5))
	var bin_msg := {"t": "ents", "k": 1, "r": 4, "cx": 0, "cy": 0, "part": 1, "parts": 1, "e": flat,
		"xi": PackedInt32Array([0, 2]), "xe": [{"d": 1, "q": "rare"}, {"ai": ["item", "iron-plate"]}]}
	var plain := WireDecode.plain(bin_msg.duplicate(true))  # (before the world adds its own keys to the extras)
	var seen: Array = []
	for msg: Dictionary in [{"t": "ents", "k": 1, "r": 4, "cx": 0, "cy": 0, "part": 1, "parts": 1, "e": json_recs.duplicate(true)}, bin_msg]:
		var w := WorldMirror.new()
		add_child(w)
		w.protos.add_entities([[4, "small-lamp", "lamp", -0.5, -0.5, 0.5, 0.5, 200, 200, 160, 1, 1]])
		w.chunks[Vector2i.ZERO] = ChunkView.new()
		w.handle(msg)
		var got: Array = []
		for key: Variant in w.entities:
			var r = w.entities[key]
			got.append([r.unit, r.proto_id, r.fixed, r.dir, str(r.extra.get("q", "")), r.extra.has("d"), r.extra.has("ai")])
		got.sort()
		seen.append(got)
		w.queue_free()
	check(seen[0] == seen[1] and seen[0].size() == 3, "binary ents: records from the packed block and their extras are JSON's: %s vs %s" % seen)
	check(str(plain["e"]) == str(json_recs) and not plain.has("xi") and WireDecode.ents_count(bin_msg) == 3,
		"binary ents: plain() gives JSON's records back: %s" % [plain["e"]])
	# The chunk's runs packed, read on the main thread (--decode-thread=off has no _tiles).
	var w := WorldMirror.new()
	add_child(w)
	w.protos.add_entities([[4, "small-lamp", "lamp", -0.5, -0.5, 0.5, 0.5, 200, 200, 160, 1, 1]])
	w.chunks[Vector2i(2, 1)] = ChunkView.new()
	w.handle({"t": "chunk", "k": 1, "r": 1, "cx": 2, "cy": 1, "parts": 1, "rs": 1, "rv": 1, "n": 0, "tiles": PackedInt32Array([3, 1000, 5, 24])})
	var tiles: PackedInt32Array = (w.chunks[Vector2i(2, 1)] as ChunkView).tile_ids
	check(tiles.size() == 1024 and tiles[0] == 3 and tiles[999] == 3 and tiles[1000] == 5,
		"binary chunk: packed tiles' runs give the ground: %d %s" % [tiles.size(), tiles.slice(998, 1002) if tiles.size() == 1024 else tiles])
	# st's lists packed: applied, the lamp's colour; a big one waits and is applied sliced.
	w.chunks[Vector2i.ZERO] = ChunkView.new()
	var big := PackedInt32Array()
	for j in 100:
		w._add([6000 + j, 4, (j % 30) * 256 + 128, (j / 30) * 256 + 128, 0])
		big.append_array([6000 + j, 1])
	var was_sliced := WorldMirror.states_sliced
	WorldMirror.states_sliced = true
	w.handle({"t": "st", "k": 1, "r": 2, "l": PackedInt32Array([6000, 0]), "lc": PackedInt32Array([6000, 0x00FF00])})
	var small := int(w.working.get(6000, -1)) == 0 and int(w.lamp_colors.get(6000, -1)) == 0x00FF00
	w.handle({"t": "st", "k": 1, "r": 3, "l": big})
	var waited := w.states_waiting() == 100
	w.flush_states()
	WorldMirror.states_sliced = was_sliced
	check(small and waited and int(w.working.get(6099, -1)) == 1, "binary st: packed lists applied, a big one sliced: %s %s" % [small, waited])
	w.queue_free()


## Binary frames' `bs` and `bfar` (wire version 2): a part with a lane key past 31 bits (sent as unit and line),
## lm's next leading out, qu, read back by wire_decode.gd as its JSON, and the belt job and the far lanes' job
## making the same of the packed lists as of JSON's.


func _binary_belts() -> void:
	const WireDecode := preload("res://scripts/net/wire_decode.gd")
	const WireEncode := preload("res://tests/wire_encode.gd")
	var big := 300000000 * 8 + 1
	var key_b := 929
	var msg := {"t": "bs", "k": 100, "part": 1, "parts": 1, "p": 6, "w": 50, "fx": -5120, "fy": 2688, "fr": 16,
		"lm": [big, 1, 256, 8, -4096, 2628, -3968, 2628, -3840, 2628, 0, key_b,
			key_b, 1, 256, 8, -3840, 2628, -3712, 2628, -3584, 2628, 0, -1],
		"sl": [big, 100, 2, 501, 3, 64, 1, 502, 3, 192, 2, key_b, 100, 1, 503, 3, 128, 1],
		"pc": [key_b, 100, 1, 128, 128], "qu": [501, "rare"], "of": [116, 1]}
	var got := WireEncode.round_trip(msg)
	check(not got.is_empty() and got.get("sl") is PackedInt64Array and WireDecode.plain(got) == msg,
		"binary frames: a bs part reads back as its JSON (keys past 31 bits, next leading out, qu): %s" % [WireDecode.plain(got)])
	# Wire version 5: a part's crossing hints (sx) as a block after qu's text; a part without them ends there as before
	# (versions 2-4 read it unchanged); a version 4 datagram with the block is refused (the bridge sends sx from 5 only).
	var msg5 := msg.duplicate(true)
	msg5["sx"] = [116, 0, 100, 501, 0, 502, 0, 116, 0, 100, 503, 0, 502, 0]
	var got5 := WireEncode.round_trip(msg5, 5)
	check(got5.get("sx") is PackedInt64Array and WireDecode.plain(got5) == msg5,
		"binary frames v5: a bs part's crossing hints read back: %s" % [WireDecode.plain(got5)])
	check(WireDecode.plain(WireEncode.round_trip(msg, 5)) == msg and WireDecode.plain(WireEncode.round_trip(msg, 4)) == msg
		and not WireEncode.round_trip(msg, 4).has("sx"), "binary frames: a bs part without hints reads the same at versions 4 and 5")
	var v4 := WireEncode.datagram([msg5], 5)
	v4[1] = 4
	check(int(WireDecode.read(v4)[3]) == 1, "binary frames: a version 4 datagram's bs part ending in an sx block is refused")
	var was_gd5: bool = BeltItemsScript.State.force_gd
	BeltItemsScript.State.force_gd = true
	var job5 = BeltItemsScript.Job.new()
	job5.state = BeltItemsScript.State.new()
	job5._handle(got5)
	var hinted: Dictionary = job5.state.sim._sx
	BeltItemsScript.State.force_gd = was_gd5
	check(hinted.size() == 1 and (hinted[232] as PackedInt64Array).size() == 10,
		"binary frames v5: the belt job queues a part's crossing hints in the simulation (unit 116 side 0, two records): %s" % [hinted])
	var was_gd: bool = BeltItemsScript.State.force_gd
	BeltItemsScript.State.force_gd = true
	var seen: Array = []
	for m: Dictionary in [msg, got]:
		var job = BeltItemsScript.Job.new()
		job.state = BeltItemsScript.State.new()
		job._handle(m)
		job.state.sim.step_to(101)
		var st: Array = job.state.sim.items_state()
		seen.append([job.state.lanes_raw.keys(), job.state.lanes_raw.values(), st[0], st[1], st[2]])
	BeltItemsScript.State.force_gd = was_gd
	check(seen[0] == seen[1] and (seen[0][2] as PackedInt64Array).size() == 3,
		"binary frames: the belt job makes the same lanes and items of a packed bs part as of its JSON: %s vs %s" % [seen[0], seen[1]])
	var far := {"t": "bfar", "k": 100, "cx": -2, "cy": 1, "l": [-768, 512, 4, 1, 0, -512, 512, 4, 1, 1], "c": [4, 0, 2, 1], "h": [2, 1, 1, 1]}
	var far_got := WireEncode.round_trip(far)
	check(far_got.get("l") is PackedInt32Array and WireDecode.plain(far_got) == far,
		"binary frames: a bfar chunk reads back as its JSON: %s" % [WireDecode.plain(far_got)])
	var built: Array = []
	for m: Dictionary in [far, far_got]:
		var b: Dictionary = BeltLanesScript.Job.build(m["l"], m["c"], 0.2, m["h"])
		var flat: Array = []
		for item: Variant in b:
			flat.append([item, Array(b[item])])
		built.append(flat)
	check(built[0] == built[1] and not built[0].is_empty(), "binary frames: far lane icons from packed lists are those from JSON's")


func _terrain() -> void:
	var db := ProtoDB.new()
	db.add_tiles([[0, "ammoniacal-ocean", 15, 13, 25], [1, "gleba-deep-lake", 18, 37, 51], [2, "snow-flat", 190, 194, 197], [3, "water", 51, 83, 95]])
	check(db.is_water(0) and db.is_water(1) and not db.is_water(2) and db.is_water(3), "Aquilo's ocean and Gleba's deep lake are water, snow isn't")
	# 0.1.3's graphics list marked every tile with `water_tile` in its mask as water, and empty space,
	# lava and out-of-map have it too: the empty space round every platform was drawn as water.
	var kept_tiles := ModGraphics.tiles
	ModGraphics.tiles = {"empty-space": {"main": [["__space-age__/graphics/terrain/empty-space.png", 1, 1, 0, 0, 1, 1, null, 1]], "water": 1},
		"lava": {"main": [["__space-age__/graphics/terrain/lava.png", 1, 1, 0, 0, 1, 1, null, 1]], "water": 1}}
	var space := ProtoDB.new()
	space.add_tiles([[0, "empty-space", 0, 0, 0], [1, "lava", 200, 60, 0]])
	check(space.is_void(0) and not space.is_water(0), "empty space is space, not water, whatever the graphics list says")
	if ItemIcons.find_data_dir() != "" and not TerrainTextures.disabled:
		check(not space.is_water(1), "a tile the game's own files define (lava) keeps the client's rule, not the list's flag")
	ModGraphics.tiles = kept_tiles
	# A mod's pond is water by the graphics list's record, and the list comes after `tprotos`.
	var modded := ProtoDB.new()
	modded.add_tiles([[0, "zz-mod-pond", 40, 60, 90], [1, "grass-1", 60, 90, 30]])
	check(not modded.is_water(0) and not modded.refresh_water(), "a mod's pond before the list: land, and nothing to redo")
	ModGraphics.tiles = {"zz-mod-pond": {"mat": ["__zz-mod__/graphics/pond.png", 4, 0.5], "water": 1}}
	ModGraphics.generation += 1
	check(modded.refresh_water() and modded.is_water(0) and not modded.is_water(1), "once the list is applied it is water")
	check(not modded.refresh_water(), "and is worked out once a list")
	ModGraphics.tiles = kept_tiles
	ModGraphics.generation += 1
	check(TerrainTextures._sum("gleba_lowland_tile_offset+4", {"gleba_lowland_tile_offset": 32}) == 36
		and TerrainTextures._sum("aquilo_tile_offset_frozen + 2", {"aquilo_tile_offset_frozen": 50}) == 52
		and TerrainTextures._sum("7", {}) == 7, "a tile's layer from its file's constants")
	check(TerrainTextures._rgb("r = 46, g = 45, b = 51").is_equal_approx(Color8(46, 45, 51))
		and TerrainTextures._rgb("15, 13, 25 ").is_equal_approx(Color8(15, 13, 25)), "map colours both ways Factorio writes them")
	if ItemIcons.find_data_dir() != "" and not TerrainTextures.disabled:
		var names := ["lowland-olive-blubber", "midland-cracked-lichen", "wetland-yumako", "wetland-light-dead-skin", "wetland-dead-skin",
			"gleba-deep-lake", "brash-ice", "ammoniacal-ocean", "snow-flat", "ice-smooth", "frozen-concrete"]
		for n in names:
			TerrainTextures.lookup(n)
		TerrainTextures.finish_all()
		var g := {}
		for n in names:
			g[n] = TerrainTextures.peek(n)
		var all := true
		for n in names:
			all = all and g[n] != null and g[n].layer >= 0
		check(all, "every Gleba and Aquilo tile tried has a picture: %s" % [names.filter(func(n): return g[n] == null or g[n].layer < 0)])
		if all:
			check(g["lowland-olive-blubber"].priority < g["midland-cracked-lichen"].priority and g["lowland-olive-blubber"].spills
				and g["snow-flat"].priority != g["ice-smooth"].priority,
				"lowlands lie under midlands and blend; snow and smooth ice no longer share one priority (hard square edges)")
			check(TerrainTextures.is_water_tile("wetland-yumako") and g["wetland-yumako"].water and g["brash-ice"].water and g["ammoniacal-ocean"].water,
				"wetlands, brash ice and the ammoniacal ocean are drawn as water")
			check(g["wetland-yumako"].material == Vector2i(32, 16) and g["brash-ice"].material == Vector2i(32, 16)
				and g["wetland-yumako"].reflect < 1.0, "swamps and brash ice wear their water shader's whole picture, murky")
			var light: Image = TerrainTextures._images[g["wetland-light-dead-skin"].layer].duplicate()
			var dark: Image = TerrainTextures._images[g["wetland-dead-skin"].layer].duplicate()
			var brash: Image = TerrainTextures._images[g["brash-ice"].layer].duplicate()
			for im: Image in [light, dark, brash]:
				if im.is_compressed():
					im.decompress()
			check(TerrainTextures._mean_luma(light) > TerrainTextures._mean_luma(dark), "light dead skin is lighter than dead skin, as their map colours")
			var repeats := 0
			for i in 31:
				if brash.get_region(Rect2i(i * 64, 0, 64, 64)).get_data() == brash.get_region(Rect2i(i * 64 + 64, 0, 64, 64)).get_data():
					repeats += 1
			check(repeats == 0, "brash ice isn't one square repeated (its low alpha passed for empty slots): %d" % repeats)
			var ocean: TerrainTextures.TileGfx = g["ammoniacal-ocean"]
			check(ocean.tint.b < 0.5 and ocean.tint.r < 0.5, "the ammoniacal ocean is water's picture darkened to its map colour: %s" % ocean.tint)
	else:
		print("skip G11/G14's tile pictures: no Factorio install (or terrain textures off)")
	# A session that visits every planet runs out of layers unless a surface change makes room.
	var gen := TerrainTextures.generation
	while TerrainTextures.layer_count() < TerrainTextures.TRIM_LAYERS:
		TerrainTextures._images.append(Image.create_empty(4, 4, false, Image.FORMAT_RGB8))
		TerrainTextures._infos.append(Color(0, 1, 1, 1))
		TerrainTextures._reflects.append(1.0)
	check(TerrainTextures.trim() and TerrainTextures.layer_count() == 0 and TerrainTextures.generation > gen
		and TerrainTextures.peek("snow-flat") == null, "a surface change with many layers in use drops them all")
	check(not TerrainTextures.trim(), "and with few in use keeps them")


## An add-on's hills in culling (ground_height.gd): Godot culls by flat bounds, so things the hills
## lift need room, but only as much as the field's own range (a 48-tile margin on everything cost
## ten times the draw calls): bounds known (a chunk's MultiMeshes, its ground) grow in height only,
## other nodes get a margin of the hills' reach, and nothing grows while the ground is flat.


func _hill_culling() -> void:
	var G := preload("res://scripts/world/ground_height.gd")
	G.clear()
	var plain := MeshInstance3D.new()
	plain.mesh = BoxMesh.new()
	var quad := MeshInstance3D.new()
	quad.extra_cull_margin = 16384.0
	add_child(plain)
	add_child(quad)
	var ground := MeshInstance3D.new()
	add_child(ground)
	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(32, 32)
	ground.mesh = ground_mesh
	G.hold_mesh(ground)
	check(G.lift_range() == Vector2.ZERO and G.cull_margin() == 0.0 and not G.holding() and plain.extra_cull_margin == 0.0
		and ground.custom_aabb == AABB(), "flat: no room for hills on anything")
	var zeros := Image.create(8, 8, false, Image.FORMAT_RF)
	G.set_field(zeros, Vector2(-8, -8), 2.0)
	check(G.is_on() and G.lift_range() == Vector2.ZERO and plain.extra_cull_margin == 0.0 and not G.holding(),
		"a field without hills grows nothing")
	# Red the ground up to 4.9 tiles, green (the cliffs' low ground) down to -1.05: rounded out to half tiles.
	var hills := Image.create(8, 8, false, Image.FORMAT_RGF)
	for y in 8:
		for x in 8:
			hills.set_pixel(x, y, Color(x * 0.7, -0.15 * y, 0.0))
	G.set_field(hills, Vector2(-8, -8), 2.0)
	check(G.lift_range() == Vector2(-1.5, 5.0) and is_equal_approx(G.cull_margin(), 5.0) and G.holding(),
		"the room is the field's own range, both channels, rounded out: %s" % [G.lift_range()])
	var late := MeshInstance3D.new()
	add_child(late)
	check(plain.extra_cull_margin == 5.0 and late.extra_cull_margin == 5.0 and quad.extra_cull_margin == 16384.0,
		"nodes made before and after get a margin of the hills' reach (not 48 tiles), a bigger margin stays: %.1f %.1f" % [plain.extra_cull_margin, late.extra_cull_margin])
	G.hold_mesh(ground)
	var flat_ground := ground_mesh.get_aabb()
	check(ground.custom_aabb == AABB(flat_ground.position + Vector3(0, -1.5, 0), flat_ground.size + Vector3(0, 6.5, 0)) and ground.extra_cull_margin == 0.0,
		"the ground's bounds grow in height only, by the range, with no margin: %s" % [ground.custom_aabb])
	# A chunk's MultiMesh: the box round its instances, taller by the range and no wider.
	var protos := ProtoDB.new()
	protos.add_entities([[1, "zz-test-box", "container", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1]])
	var cv := ChunkView.new()
	add_child(cv)
	for i in 2:
		var r := WorldMirror.Rec.new()
		r.key = i + 1
		r.unit = i + 1
		r.proto_id = 1
		r.pos = Vector2(1.5 + i * 20.0, 3.5)
		cv.entities[r.key] = r
	cv.build_entities(protos, {})
	var box: MultiMeshInstance3D = cv._nodes.get("box")
	var flat_box: AABB = box.get_meta(G.META_FLAT, AABB()) if box != null else AABB()
	# The two boxes' centres are 20 tiles apart: the flat box spans both, and only its height grows.
	check(box != null and box.custom_aabb == G.grow(flat_box) and box.extra_cull_margin == 0.0
		and flat_box.size.x > 20.0 and flat_box.size.x < 22.0 and flat_box.position.y >= -0.01
		and is_equal_approx(box.custom_aabb.size.x, flat_box.size.x) and is_equal_approx(box.custom_aabb.size.y, flat_box.size.y + 6.5),
		"a chunk's MultiMesh is culled by its instances' box grown in height only: %s from %s" % [box.custom_aabb if box != null else AABB(), flat_box])
	# The edge bug this room is for: ground just below the bottom of an angled view, its flat box out
	# of the frustum, lifted 5 tiles into it, is kept by its grown box and lost by the flat one.
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 20, 20)
	cam.look_at(Vector3.ZERO)
	var planes := cam.get_frustum()
	var in_view := func(b: AABB) -> bool:
		for plane: Plane in planes:
			var n := plane.normal
			var p := Vector3(b.position.x if n.x > 0.0 else b.end.x, b.position.y if n.y > 0.0 else b.end.y, b.position.z if n.z > 0.0 else b.end.z)
			if plane.distance_to(p) > 0.0:
				return false
		return true
	var edge_z := 0.0
	while in_view.call(AABB(Vector3(-1, 0, edge_z), Vector3(2, 0.1, 2))) and edge_z < 40.0:
		edge_z += 0.25
	var below := AABB(Vector3(-1, 0, edge_z + 0.5), Vector3(2, 0.1, 2))
	var lifted_into: bool = in_view.call(AABB(below.position + Vector3(0, 5.0, 0), below.size))
	check(not in_view.call(below) and lifted_into and in_view.call(G.grow(below)),
		"ground below the view's bottom edge, lifted into it, is kept by its grown box (flat at z %.1f)" % edge_z)
	cam.queue_free()
	# A node setting its own margin since keeps it; a taller field grows the bounds again.
	late.extra_cull_margin = 9.0
	var taller := hills.duplicate()
	taller.set_pixel(3, 3, Color(7.2, 0.0, 0.0))
	G.set_field(taller, Vector2(-8, -8), 2.0)
	check(G.lift_range() == Vector2(-1.5, 7.5) and plain.extra_cull_margin == 7.5 and late.extra_cull_margin == 9.0
		and box.custom_aabb == G.grow(flat_box), "a taller field: margins and bounds follow it, a node's own bigger margin stays")
	# A field the size of Terrain Elevation's is measured on a worker; meanwhile the last range holds.
	var big := Image.create(300, 300, false, Image.FORMAT_RF)
	big.fill(Color(2.2, 0.0, 0.0))
	G.set_field(big, Vector2(-300, -300), 2.0)
	var still := G.lift_range()
	var frames := 0
	while G.lift_range() == still and frames < 120:
		await get_tree().process_frame
		frames += 1
	# Room that shrinks is taken back a slice a frame.
	while G.walking() and frames < 240:
		await get_tree().process_frame
		frames += 1
	check(still == Vector2(-1.5, 7.5) and G.lift_range() == Vector2(0.0, 2.5) and plain.extra_cull_margin == 2.5,
		"a big field is measured on a worker, the last range kept meanwhile: %s after %d frames" % [G.lift_range(), frames])
	# Hills a little lower (the field moved on) keep the room they have: no node walked (6-13 ms on a
	# small base's 3,200 nodes, every time the range wobbled half a tile).
	var lower := Image.create(8, 8, false, Image.FORMAT_RF)
	lower.fill(Color(1.8, 0.0, 0.0))
	G.set_field(lower, Vector2(-8, -8), 2.0)
	check(G.lift_range() == Vector2(0.0, 2.5) and not G.walking() and plain.extra_cull_margin == 2.5,
		"hills a little lower keep their room: %s" % [G.lift_range()])
	# Much lower: the room is taken back a slice of the main thread a frame (64 nodes a frame here).
	var many: Array = []
	for i in 200:
		var m := MeshInstance3D.new()
		add_child(m)
		many.append(m)
	G.walk_usec = 0
	var flatter := Image.create(8, 8, false, Image.FORMAT_RF)
	flatter.fill(Color(0.3, 0.0, 0.0))
	G.set_field(flatter, Vector2(-8, -8), 2.0)
	var spread := 0
	while G.walking() and spread < 120:
		await get_tree().process_frame
		spread += 1
	G.walk_usec = G.WALK_USEC
	check(G.lift_range() == Vector2(0.0, 0.5) and spread >= 2 and not G.walking() and plain.extra_cull_margin == 0.5
		and many.all(func(m) -> bool: return (m as MeshInstance3D).extra_cull_margin == 0.5),
		"much lower hills give the room back over %d frames, to every node" % spread)
	for m: Node in many:
		m.queue_free()
	await _hills_never_wait(G, big)
	G.clear()
	check(G.lift_range() == Vector2.ZERO and not G.holding() and plain.extra_cull_margin == 0.0 and late.extra_cull_margin == 9.0
		and quad.extra_cull_margin == 16384.0 and box.custom_aabb == flat_box and ground.custom_aabb == flat_ground,
		"flat again: the margins go (a node's own stays) and the bounds shrink back to the flat ones")
	cv.build_entities(protos, {})
	G.hold_mesh(ground)
	check(box.custom_aabb == AABB() and ground.custom_aabb == AABB(), "and built again while flat, they're the nodes' own bounds")
	for n: Node in [plain, quad, ground, late, cv]:
		n.queue_free()


## The freeze after Ctrl+F9 on the owner's save: each new field (Terrain Elevation sends one every 2 s
## or so) waited on the main thread for the last one's measuring, a low-priority task, which queues
## behind every low-priority job before it on the pool's few low-priority threads (30% of them).
## With those threads all held, the main thread waited for ever. Here every low-priority thread is
## held on a semaphore while fields come one after another: none may wait, and the latest field's
## range still arrives.


func _hills_never_wait(G, big: Image) -> void:
	var held := Semaphore.new()
	var hogs: Array[int] = []
	for i in OS.get_processor_count():
		hogs.append(WorkerThreadPool.add_task(func() -> void: held.wait(), false, "test: low-priority thread held"))
	var t0 := Time.get_ticks_msec()
	var tall := Image.create(300, 300, false, Image.FORMAT_RF)
	tall.fill(Color(3.2, 0.0, 0.0))
	for i in 4:
		G.set_field(big if i % 2 == 0 else tall, Vector2(-300, -300), 2.0)
	var set_ms := Time.get_ticks_msec() - t0
	var frames := 0
	while G.measuring() and frames < 120:
		await get_tree().process_frame
		frames += 1
	check(set_ms < 1000 and not G.measuring() and G.lift_range() == Vector2(0.0, 3.5),
		"hills: fields one after another never wait for the last one's measuring, even with every low-priority thread held (%d ms, %d frames, %s)" % [set_ms, frames, G.lift_range()])
	G.clear()
	G.set_field(big, Vector2(-300, -300), 2.0)
	G.clear()
	frames = 0
	while G.measuring() and frames < 120:
		await get_tree().process_frame
		frames += 1
	check(G.lift_range() == Vector2.ZERO and not G.holding(), "hills: a field cleared while measured stays cleared when its measuring ends")
	for i in hogs.size():
		held.post()
	for task in hogs:
		WorkerThreadPool.wait_for_task_completion(task)


## Factorissimo's buildings: every door is a surface change, and going back must not rebuild
## everything it had seconds before. The left world's clutter is freed a few nodes a frame (all at
## once made a 35-60 ms frame), terrain meshes come back from the cache when the ground round them
## is the same, and the ground's pictures stay loaded when the surface coming back fits beside them.


func _surface_change() -> void:
	var decor := DecorativeLayer.new()
	add_child(decor)
	var nodes: Array = []
	for i in 40:
		var n := Node3D.new()
		for k in 3:
			n.add_child(MultiMeshInstance3D.new())
		decor.add_child(n)
		decor._chunks[Vector2i(i, 0)] = n
		nodes.append(n)
	decor.reset(true)
	var hidden := nodes.all(func(n) -> bool: return is_instance_valid(n) and not (n as Node3D).visible)
	check(hidden and decor._chunks.is_empty() and decor.freeing_count() == 40, "a world left hides its clutter at once and frees it later")
	var frames := 0
	while decor.freeing_count() > 0 and frames < 100:
		decor._free_some()
		frames += 1
	check(nodes.all(func(n) -> bool: return not is_instance_valid(n)), "and frees it over the next frames (%d)" % frames)
	decor.queue_free()
	# Terrain meshes kept: the same ground round a chunk takes the kept mesh, other ground is built.
	var w := WorldMirror.new()
	add_child(w)
	w.surface_index = 5
	w.protos.add_tiles([[0, "zz-test-ground", 90, 90, 90], [1, "zz-test-other", 30, 30, 30]])
	var ids := PackedInt32Array()
	ids.resize(32 * 32)
	var place := func(tiles: PackedInt32Array) -> ChunkView:
		var cv := ChunkView.new()
		cv.coord = Vector2i.ZERO
		cv.loaded = true
		cv.tile_ids = tiles
		w.chunks[Vector2i.ZERO] = cv
		w.add_child(cv)
		w._dirty_terrain[Vector2i.ZERO] = true
		return cv
	var first: ChunkView = place.call(ids)
	w._start_terrain_jobs()
	var entry: Array = w._terrain_jobs.get(Vector2i.ZERO, [])
	check(entry.size() == 5, "a chunk's ground is built on a worker")
	if entry.size() == 5:
		WorkerThreadPool.wait_for_task_completion(entry[0])
		w._terrain_jobs.erase(Vector2i.ZERO)
		first.apply_terrain(entry[1])
		w._keep_terrain(Vector2i.ZERO, int(entry[3]), int(entry[4]), first)  # as if every picture were loaded
		check(w.terrain_cache_size() == 1, "and its mesh kept")
		w.reset(true, 5)
		w.surface_index = 5
		var back: ChunkView = place.call(ids.duplicate())
		var hits := w.terrain_cache_hits
		w._start_terrain_jobs()
		check(not w._terrain_jobs.has(Vector2i.ZERO) and w.terrain_cache_hits == hits + 1 and back.terrain_mesh() == first.terrain_mesh(),
			"back on the surface, the same chunk takes its kept mesh without a worker's job")
		# lighting-fixes step 3: the ground on its own render layer, which the look's fill light leaves.
		check(back._terrain != null and back._terrain.layers == Visuals.GROUND_LAYER and first._terrain.layers == Visuals.GROUND_LAYER,
			"the chunks' ground on Visuals.GROUND_LAYER, kept or built")
		w.reset(true, 5)
		w.surface_index = 5
		var changed := ids.duplicate()
		changed[100] = 1
		place.call(changed)
		w._start_terrain_jobs()
		check(w._terrain_jobs.has(Vector2i.ZERO), "a tile changed since: built again")
		w.reset(true, 6)
		w.surface_index = 6
		place.call(ids.duplicate())
		w._start_terrain_jobs()
		check(w._terrain_jobs.has(Vector2i.ZERO), "the same chunk on another surface: built, not taken from the first")
		for e: Array in w._terrain_jobs.values():
			WorkerThreadPool.wait_for_task_completion(e[0])
		w._terrain_jobs.clear()
	w.reset()
	check(w.terrain_cache_size() == 0, "another game forgets the kept meshes")
	# Same-save reconnect (keep_cache = true) clears protos cleanly while preserving _cache and _terrain_cache.
	w.surface_index = 5
	w.protos.add_tiles([[0, "zz-test-ground", 90, 90, 90]])
	w.handle({"t": "chunk", "cx": 0, "cy": 0, "rs": 5, "rv": 3, "n": 0, "parts": 0, "tiles": [0, 1024]})
	w._terrain_cache[Vector3i(5, 0, 0)] = [1, ArrayMesh.new(), [], 1]
	check(w._offer(Vector2i.ZERO) == [5, 0, 0, 3, 0] and w.terrain_cache_size() == 1,
		"chunk & terrain cache populated before same-save reconnect")
	w.reset(false, 5, true)
	check(w.protos.tile_names.is_empty() and w._offer(Vector2i.ZERO) == [5, 0, 0, 3, 0] and w.terrain_cache_size() == 1,
		"keep_cache preserves kept chunk messages & terrain cache while resetting protos")
	# Non-poisoning chunk delta cache: add/upd/del/tiles deltas stay replayable on top of the kept snapshot
	# once `kept` confirms the updated [rv, n], while `_cached_offer` blocks unconfirmed entries (`pending_kept`).
	w.reset()
	w.surface_index = 1
	w.protos.add_tiles([[0, "zz-test-ground", 90, 90, 90]])
	w.protos.add_entities([[1, "wooden-chest", 1.0, 1.0, 0, "container"]])
	var dcv := ChunkView.new()
	dcv.coord = Vector2i.ZERO
	w.chunks[Vector2i.ZERO] = dcv
	w.add_child(dcv)
	w.handle({"t": "chunk", "cx": 0, "cy": 0, "rs": 1, "rv": 1, "n": 1, "parts": 1, "tiles": [0, 1024]})
	w.handle({"t": "ents", "cx": 0, "cy": 0, "part": 1, "e": [[10, 1, 256, 256, 0]]})
	w.handle({"t": "add", "e": [11, 1, 512, 512, 0]})
	check(w._cached_offer(Vector2i.ZERO).is_empty(),
		"delta-touched chunk refuses _cached_offer until `kept` confirms the updated [rv, n]")
	w.handle({"t": "kept", "rs": 1, "l": [0, 0, 2, 2]})
	check(w._cached_offer(Vector2i.ZERO) == [1, 0, 0, 2, 2],
		"`kept` promotes delta-tracked chunk back into offerable _cache with updated [rv, n]")
	w._unload(Vector2i.ZERO)
	w._remove(10)
	w._remove(11)
	check(w._offer(Vector2i.ZERO) == [1, 0, 0, 2, 2] and not w.entities.has(10),
		"unloaded chunk still offers [1, 0, 0, 2, 2] from _cache after deltas")
	var dcv2 := ChunkView.new()
	dcv2.coord = Vector2i.ZERO
	w.chunks[Vector2i.ZERO] = dcv2
	w.add_child(dcv2)
	var was_qr := WorldMirror.queued_replay
	WorldMirror.queued_replay = false
	w.handle({"t": "chunk", "cx": 0, "cy": 0, "rs": 1, "rv": 2, "same": 2})
	WorldMirror.queued_replay = was_qr
	check(w.entities.has(10) and w.entities.has(11) and dcv2.entities.has(10) and dcv2.entities.has(11),
		"replaying delta-tracked chunk on `same` restores both original snapshot entities and live deltas")
	for di in WorldMirror.MAX_CACHE_DELTAS:
		w.handle({"t": "add", "e": [100 + di, 1, 768, 768, 0]})
	w.handle({"t": "kept", "rs": 1, "l": [0, 0, 99, 99]})
	check(w._cached_offer(Vector2i.ZERO).is_empty(),
		"exceeding MAX_CACHE_DELTAS falls back to marking the cache entry stale")
	w.reset()
	w.queue_free()
	# MapCache + UiModel.set_character_surface() stash pages & preserve map_stamps across surface changes.
	var mm: UiModel = UiModel.new()
	var mc := MapCache.new(mm)
	mm.set_character_surface(1)
	mm.handle({"t": "chart", "si": 1, "cx": 2, "cy": 3, "n": 1, "st": 101, "pal": [[10, 20, 30]], "px": [0]})
	mm.set_character_surface(2)
	check(mc._stash.has(1) and not mc.is_charted(Vector2i(2, 3))
		and (mm.map_stamps.get(1, {}) as Dictionary).get(Vector2i(2, 3), 0) == 101,
		"switching character surface stashes previous surface charts and preserves map_stamps")
	mm.handle({"t": "chart", "si": 2, "cx": 4, "cy": 5, "n": 1, "st": 202, "pal": [[40, 50, 60]], "px": [0]})
	mm.set_character_surface(1)
	check(mc.is_charted(Vector2i(2, 3)) and mc._stash.has(2)
		and (mm.map_stamps.get(1, {}) as Dictionary).get(Vector2i(2, 3), 0) == 101
		and (mm.map_stamps.get(2, {}) as Dictionary).get(Vector2i(4, 5), 0) == 202,
		"returning to previous surface restores stashed map pages and keeps stamps for both surfaces")
	# Factoriopedia disk cache (user://pedia-cache/<gf>.bin): persists groups/index/static pages,
	# skips force-dependent kinds (recipe/technology) and unfound entries, serves cached pages with 0 Bridge.send calls.
	var was_pedia_cache := PediaCache.enabled
	PediaCache.enabled = true
	var pfp := "zz-test-pedia-fp"
	var ppath := ProjectSettings.globalize_path(PediaCache.cache_path(pfp))
	DirAccess.remove_absolute(ppath)
	var pm1: UiModel = UiModel.new()
	pm1.set_pedia_fingerprint(pfp)
	pm1.handle({"t": "pidx", "part": 1, "parts": 1, "g": [["logistics", "a"]],
		"l": [["entity", "iron-chest", "logistics", "storage", "a"]]})
	pm1.handle({"t": "pedia", "kind": "entity", "name": "iron-chest", "found": 1, "d": {"hp": 200}})
	pm1.handle({"t": "pedia", "kind": "recipe", "name": "iron-plate", "found": 1, "d": {"time": 3.2}})
	pm1.handle({"t": "pedia", "kind": "technology", "name": "optics", "found": 1, "d": {"cost": 10}})
	pm1.handle({"t": "pedia", "kind": "item", "name": "missing-item", "found": 0, "d": {}})
	pm1.flush_pedia_cache(true)
	var disk_loaded := PediaCache.load_for(pfp)
	check(disk_loaded.get("index", []).size() == 1
		and (disk_loaded.get("pages", {}) as Dictionary).has("entity/iron-chest")
		and not (disk_loaded.get("pages", {}) as Dictionary).has("recipe/iron-plate")
		and not (disk_loaded.get("pages", {}) as Dictionary).has("technology/optics")
		and not (disk_loaded.get("pages", {}) as Dictionary).has("item/missing-item"),
		"PediaCache saves static pages & index while excluding recipe, technology, and unfound entries")
	var pm2: UiModel = UiModel.new()
	pm2.set_pedia_fingerprint(pfp)
	sent()
	var cached_page := pm2.pedia_page("entity", "iron-chest")
	check(cached_page.get("found", false) and int(cached_page.get("d", {}).get("hp", 0)) == 200 and sent().is_empty(),
		"UiModel loads cached Factoriopedia page on matching fingerprint with 0 Bridge.send calls")
	DirAccess.remove_absolute(ppath)
	PediaCache.enabled = was_pedia_cache
	# The ground's pictures: Nauvis with Space Exploration has 39 kinds, a factory floor 4 more, and
	# past TRIM_LAYERS every door dropped them all and read them again.
	TerrainTextures.trim()
	var names: Array = []
	while TerrainTextures.layer_count() < TerrainTextures.TRIM_LAYERS + 3:
		var n := "zz-test-layer-%d" % TerrainTextures.layer_count()
		TerrainTextures._images.append(Image.create_empty(4, 4, false, Image.FORMAT_RGB8))
		TerrainTextures._infos.append(Color(0, 1, 1, 1))
		TerrainTextures._reflects.append(1.0)
		var g := TerrainTextures.TileGfx.new()
		g.layer = names.size()
		TerrainTextures._gfx[n] = g
		names.append(n)
	for n in names.slice(0, 39):
		TerrainTextures.note(1, n)
	for n in names.slice(39):
		TerrainTextures.note(3, n)
	var layout := TerrainTextures.layout
	check(not TerrainTextures.trim(1) and not TerrainTextures.trim(3) and TerrainTextures.layer_count() == names.size() and TerrainTextures.layout == layout,
		"going back to a surface whose ground is loaded keeps the layers (and the meshes built with them)")
	TerrainTextures.note(4, "zz-test-not-loaded")
	for i in TerrainTextures.MAX_LAYERS:
		TerrainTextures.note(4, "zz-test-not-loaded-%d" % i)
	check(TerrainTextures.trim(4) and TerrainTextures.layer_count() == 0 and TerrainTextures.layout > layout,
		"a surface whose ground doesn't fit beside them makes room")
	TerrainTextures.forget_surfaces()
	# Disk cache for repacked & mipmapped tile layers (user://tex-cache/): round-trips pixels, sizes, and metadata.
	var was_disk := TerrainTextures.disk_cache
	TerrainTextures.disk_cache = true
	var tex_img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	tex_img.fill(Color(0.25, 0.5, 0.75, 1.0))
	tex_img.set_pixel(17, 29, Color(0.9, 0.2, 0.1, 1.0))
	tex_img.generate_mipmaps()
	var g_src := TerrainTextures.TileGfx.new()
	g_src.name = "zz-test-disk-tile"
	g_src.tint = Color(0.8, 0.9, 1.0)
	g_src.sizes = [[1, 1.0, PackedFloat32Array([1.0]), 1]]
	g_src.material = Vector2i(2, 2)
	g_src.material_count = 4
	g_src.reflect = 0.25
	var tkey := TerrainTextures._def_cache_key(g_src, "variants = {}", 0)
	var thash := tkey.sha256_text()
	var tpath := TerrainTextures._cache_path(g_src.name, thash)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tpath))
	var hits_before := TerrainTextures.cache_hits
	TerrainTextures._write_tile_cache(g_src, tkey, tex_img)
	var g_dst := TerrainTextures.TileGfx.new()
	g_dst.name = g_src.name
	g_dst.tint = g_src.tint
	var loaded_img := TerrainTextures._read_tile_cache(g_dst, tkey, 0)
	var missed_img := TerrainTextures._read_tile_cache(g_dst, TerrainTextures._def_cache_key(g_src, "variants = {changed}", 0), 0)
	check(loaded_img != null and loaded_img.get_width() == 64 and loaded_img.get_height() == 64 and loaded_img.has_mipmaps()
		and loaded_img.get_pixel(17, 29).is_equal_approx(tex_img.get_pixel(17, 29))
		and loaded_img.get_data() == tex_img.get_data()
		and g_dst.material == Vector2i(2, 2) and g_dst.material_count == 4 and is_equal_approx(g_dst.reflect, 0.25)
		and g_dst.sizes.size() == 1 and TerrainTextures.cache_hits == hits_before + 1 and missed_img == null,
		"terrain tile disk cache round-trips FastLZ-compressed RGBA8 pixels, mipmaps, metadata, and misses on key change")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tpath))
	TerrainTextures.disk_cache = was_disk
	TerrainTextures._cache_writes = 0


## Full screen's Resolution scales to the monitor: the sums, as no real full screen exists headless.


func _tree_crowns() -> void:
	var loaded := func(name: String, combine: bool) -> ArrayMesh:
		var l := ModelLibrary.Load.new()
		l.path = _own_glb(name)
		l.combine = combine
		l.run()
		return ModelLibrary._commit_load(l, []) as ArrayMesh
	var leaf_shader := load("res://shaders/factorio_material_leaf.gdshader") as Shader
	var merged: ArrayMesh = loaded.call("tree-05", true)
	var leaf_surface := -1
	var bark_rows := []
	for i in merged.get_surface_count():
		var sm := merged.surface_get_material(i) as ShaderMaterial
		if sm != null and sm.shader == leaf_shader:
			leaf_surface = i
		elif sm != null:
			bark_rows = ModelLibrary.MaterialRows.rows(sm).map(func(r: Material) -> String: return r.resource_name)
	var leaf_mat := merged.surface_get_material(maxi(leaf_surface, 0)) as ShaderMaterial
	var leaf_rows: Array = ModelLibrary.MaterialRows.rows(leaf_mat).map(func(r: Material) -> String: return r.resource_name)
	check(leaf_surface >= 0 and leaf_rows.size() == 2 and str(leaf_rows[0]).begins_with("leafcard") and str(leaf_rows[1]).begins_with("leaf-shadow")
		and not bark_rows.any(func(n: String) -> bool: return n.begins_with("leaf")),
		"merged, a tree's cores share its leaf cards' surface, not the bark's (%s; bark %s)" % [leaf_rows, bark_rows])
	# A leaf row edited (nature_looks.gd gives them the prototype's colours): leaf_core stays the core row's.
	var edited := ModelLibrary.MaterialRows.edit(leaf_mat, func(m: ShaderMaterial) -> bool: return m.shader == leaf_shader,
		func(m: ShaderMaterial) -> void: m.set_shader_parameter("leaf_tint_count", 0)) as ShaderMaterial
	check(edited != null and edited.get_shader_parameter("leaf_core") != true, "an edited merged crown doesn't make every card a core")
	var uvs: PackedVector2Array = ModelLods.arrays_of(merged, maxi(leaf_surface, 0))[Mesh.ARRAY_TEX_UV]
	var cores := 0
	var cards := 0
	for uv in uvs:
		if uv.x < -0.5:
			cores += 1
		elif uv.x >= 0.0 and uv.x <= 1.0:
			cards += 1
	check(cores > 0 and cards > 0 and cores + cards == uvs.size(), "cores carry UV -1, cards 0-1 (%d, %d of %d)" % [cores, cards, uvs.size()])
	# The shadow stand-in: the wood welded as before, the crown its own surface; card view LODs drop whole cards.
	var plain: ArrayMesh = loaded.call("tree-05", false)
	var tri_count := func(arrays: Array) -> int:
		var idx: Variant = arrays[Mesh.ARRAY_INDEX]
		return (idx as PackedInt32Array).size() / 3 if idx != null else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	for case_idx in 2:
		var src_mesh := plain if case_idx == 0 else merged
		var job := ModelLods._job_for(src_mesh)
		check(job != null and not job.crown.is_empty() and job.tree_cards and job.view_lods == ModelLods.tree_lods and not job.proxy_lods,
			"a tree's stand-in job knows its crown")
		if job == null:
			continue
		job.run()
		var kinds := {}
		for uv in job.crown_uvs:
			kinds[int(uv.y)] = true
		check(job.crown_vertices.size() > 0 and job.crown_vertices.size() == job.crown_uvs.size() and kinds.has(0) and kinds.has(1)
			and job.indices.size() >= 3, "its crown cast apart from its wood, cards and cores marked (%s)" % [kinds.keys()])
		job.run_levels()
		check(job.levels.size() == ModelLods.TREE_LOD_TIERS.size(),
			"tree-05 (%s) gets %d card-level LOD tiers (%d)" % ["merged" if case_idx == 1 else "plain", ModelLods.TREE_LOD_TIERS.size(), job.levels.size()])
		if job.levels.size() == ModelLods.TREE_LOD_TIERS.size():
			var full_tris := 0
			for si in src_mesh.get_surface_count():
				var a0 := ModelLods.arrays_of(src_mesh, si)
				full_tris += int(tri_count.call(a0))
			var prev_tris := full_tris
			var mono := true
			var attrs_ok := true
			var has_core := true
			var l1_card_tris := 0
			for li in job.levels.size():
				var lvl: Array = job.levels[li]
				var lvl_tris := 0
				var per_surf: Array = lvl[1]
				for si in per_surf.size():
					var arr: Array = per_surf[si]
					lvl_tris += int(tri_count.call(arr))
					if job.crown.has(si) and not bool(job.crown[si]):
						var luvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
						var lnorms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
						var luv2: Variant = arr[Mesh.ARRAY_TEX_UV2]
						attrs_ok = attrs_ok and luv2 is PackedVector2Array and (luv2 as PackedVector2Array).size() == luvs.size()
						var surf_core := false
						var lidx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
						var surf_cards := 0
						for vi in luvs.size():
							var u := luvs[vi]
							if u.x < -0.5:
								surf_core = true
							else:
								attrs_ok = attrs_ok and u.x >= -0.01 and u.x <= 1.01 and u.y >= -0.01 and u.y <= 1.01
							attrs_ok = attrs_ok and absf(lnorms[vi].length() - 1.0) < 0.05
						for t in range(0, lidx.size(), 3):
							if luvs[lidx[t]].x >= -0.5:
								surf_cards += 1
						if li == 0:
							l1_card_tris += surf_cards
						if case_idx == 1:
							has_core = has_core and surf_core
				mono = mono and lvl_tris < prev_tris
				prev_tris = lvl_tris
			check(mono and prev_tris < int(full_tris * 0.30) and l1_card_tris == 666 and attrs_ok and has_core,
				"tree-05 (%s) LODs shrink cards cleanly with quads, UVs, UV2 seeds, normals and cores preserved (%d -> %d tris, L1 cards %d)" % [
					"merged" if case_idx == 1 else "plain", full_tris, prev_tris, l1_card_tris])
	var was_tree_lods := ModelLods.tree_lods
	ModelLods.tree_lods = false
	var off_job := ModelLods._job_for(plain)
	check(off_job != null and not off_job.view_lods, "--tree-lod=off disables card view LODs")
	ModelLods.tree_lods = was_tree_lods
	var card := PackedVector3Array()
	var card_uv := PackedVector2Array()
	var square := []
	square.resize(Mesh.ARRAY_MAX)
	square[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(0, 1, 0)])
	square[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	square[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([Vector2(0, 0.25), Vector2(0, 0.25), Vector2(0, 0.25), Vector2(0, 0.25)])
	square[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	ModelLods.Job.crown_arrays(square, false, card, card_uv)
	var expected_scale := ModelLods.Job.CARD_SHADOW_DECIMATED if ModelLods.tree_shadow_decimate else ModelLods.Job.CARD_SHADOW
	var expected_verts := 6 if ModelLods.Job.quad_shadows else 15
	var rad_dist := card[0].distance_to(Vector3(0.5, 0.5, 0)) if not card.is_empty() else 0.0
	check(card.size() == expected_verts and (ModelLods.Job.quad_shadows or (rad_dist >= 0.41 * expected_scale and rad_dist <= 0.50 * expected_scale))
		and is_equal_approx(card_uv[0].x, 0.25) and card_uv[0].y == 0.0,
		"a card's stand-in emits rounded polygon fan around its middle with its seed (%d, %s)" % [card.size(), card[0]])
	var was_quad := ModelLods.Job.quad_shadows
	ModelLods.Job.quad_shadows = true
	var qcard := PackedVector3Array()
	var qcard_uv := PackedVector2Array()
	ModelLods.Job.crown_arrays(square, false, qcard, qcard_uv)
	check(qcard.size() == 6 and qcard[0].is_equal_approx(Vector3(0.5, 0.5, 0) + Vector3(-0.5, -0.5, 0) * expected_scale)
		and is_equal_approx(qcard_uv[0].x, 0.25) and qcard_uv[0].y == 0.0,
		"with --tree-shadow-shape=old, a card's stand-in is drawn in as a quad (%s)" % [qcard[0]])
	var was_dec := ModelLods.tree_shadow_decimate
	ModelLods.tree_shadow_decimate = false
	var card_full := PackedVector3Array()
	var card_full_uv := PackedVector2Array()
	ModelLods.Job.crown_arrays(square, false, card_full, card_full_uv)
	ModelLods.tree_shadow_decimate = was_dec
	ModelLods.Job.quad_shadows = was_quad
	check(card_full.size() == 6 and card_full[0].is_equal_approx(Vector3(0.5, 0.5, 0) + Vector3(-0.5, -0.5, 0) * ModelLods.Job.CARD_SHADOW),
		"a card's quad stand-in uses CARD_SHADOW when decimation is disabled (%s)" % [card_full[0]])
	check(load("res://shaders/shadow_stand_in_leaf.gdshader") is Shader and ModelLods.leaf_material().shader != ModelLods.material().shader,
		"the crown's stand-in has a shader of its own that drops what pollution took")
	# tree-06's strands: the leaves' shader, UV -2, solid leaves in the stand-in.
	var weeping: ArrayMesh = loaded.call("tree-06", false)
	var strands := false
	for i in weeping.get_surface_count():
		var sm := weeping.surface_get_material(i) as ShaderMaterial
		if sm != null and sm.resource_name.begins_with("leaf-0") and sm.shader == leaf_shader:
			var suv: PackedVector2Array = ModelLods.arrays_of(weeping, i)[Mesh.ARRAY_TEX_UV]
			strands = suv.size() > 0 and suv[0].x < -1.5
	check(strands, "tree-06's hanging leaves are drawn with the leaves' shader, marked solid leaves, so pollution takes them")
	# K4: the spruce's green cap (material leaf-01, a solid cone pollution never took) is gone.
	var spruce: ArrayMesh = loaded.call("tree-01", false)
	var cap := false
	for i in spruce.get_surface_count():
		var m := spruce.surface_get_material(i)
		cap = cap or (m != null and m.resource_name == "leaf-01")
	check(not cap, "a bare (polluted) spruce keeps no green cone on its top")
	var include_text := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc")
	check(include_text.contains("float leaf_kind = leaf_core ? 1.0 : (UV.x < -1.5 ? 2.0 : (UV.x < -0.5 ? 1.0 : 0.0));"),
		"the leaves' shader tells cores and solid leaves from cards by their UV")
	# Bug #22 (double-arm inserter): _update_rest duplicates `live` instead of aliasing the caller's map.
	var ArmsScript := preload("res://scripts/world/inserter_arms.gd")
	var arms_w := WorldMirror.new()
	var arms := ArmsScript.new()
	arms.world = arms_w
	add_child(arms)
	var live_map := {42: Vector2i.ZERO}
	arms._update_rest(live_map, 0.016)
	live_map.clear()
	check(arms._rest_live.has(42) and arms._rest_live.get(42) == Vector2i.ZERO,
		"#22: InserterArms._update_rest duplicates live map so mutating caller's dict preserves _rest_live")
	arms.queue_free()
	arms_w.free()


func _creature_motion() -> void:
	var names := ["small-biter", "behemoth-biter", "big-spitter", "medium-worm-turret", "spitter-spawner", "biter-spawner",
		"small-biter-corpse", "small-biter-corpse-1", "small-biter-corpse-2", "small-biter-corpse-3"]
	for n in names:
		ModelLibrary.mesh_for(n)
	var until := Time.get_ticks_msec() + 20000
	while not names.all(func(n: String) -> bool: return ModelLibrary.ready(n)) and Time.get_ticks_msec() < until:
		ModelLibrary.poll()
		await get_tree().process_frame
	# The rows (or surfaces' own materials) of a model whose material name contains `part`.
	var rows_of := func(model: String, part: String) -> Array:
		var out := []
		var mesh := ModelLibrary.mesh_for(model) as Mesh
		if mesh == null:
			return out
		for i in mesh.get_surface_count():
			var m := mesh.surface_get_material(i) as ShaderMaterial
			var list: Array = ModelLibrary.MaterialRows.rows(m)
			for r in (list if not list.is_empty() else [m]):
				if r != null and (r as ShaderMaterial).resource_name.contains(part):
					out.append(r)
		return out
	var skins := {}
	for pair in [["small-biter", "chitin"], ["behemoth-biter", "chitin"], ["big-spitter", "chitin"], ["medium-worm-turret", "flesh_worm"],
			["spitter-spawner", "flesh_spawner_dome"], ["biter-spawner", "flesh_spawner_dome"], ["small-biter-corpse-2", "chitin"]]:
		var found: Array = rows_of.call(pair[0], pair[1])
		var r: ShaderMaterial = found[0] if not found.is_empty() else null
		skins[pair[0]] = [r.get_shader_parameter("skin_mode"), r.get_shader_parameter("albedo"), r.get_shader_parameter("skin_tint2")] \
			if r != null else [-1, Color.BLACK, Color.BLACK]
	var tier := func(n: String, k: int) -> Color:
		var t: Array = CreatureModels.skin_of(CreatureModels.base_model(n) if CreatureModels.base_model(n) != "" else n)["tiers"][n][k]
		return Color(float(t[0]), float(t[1]), float(t[2])).linear_to_srgb()
	var masks_ok: bool = int(skins["small-biter"][0]) == 1 \
		and (skins["small-biter"][1] as Color).is_equal_approx(Color(tier.call("small-biter", 0), 1.0)) \
		and is_equal_approx((skins["small-biter"][2] as Color).a, 0.7) and int(skins["behemoth-biter"][0]) == 1 \
		and not (skins["behemoth-biter"][1] as Color).is_equal_approx(skins["small-biter"][1]) and int(skins["big-spitter"][0]) == 1 \
		and int(skins["small-biter-corpse-2"][0]) == 1
	var mask_ok: bool = int(skins["medium-worm-turret"][0]) == 2 and int(skins["spitter-spawner"][0]) == 2 \
		and int(skins["biter-spawner"][0]) == 2 and is_equal_approx((skins["spitter-spawner"][2] as Color).a, 1.0) \
		and is_equal_approx((skins["biter-spawner"][2] as Color).a, 0.5)
	check(masks_ok and mask_ok, "each tier's carapace is its sprite's masks under the tier's own tints (two for biters and spitters, one over the colours for worms and spawners): %s" % [skins])
	# A merged material's table carries the skin: flags 16 or 32, the second tint where the emission was.
	var flags_ok := true
	for n in ["small-biter", "medium-worm-turret"]:
		for r: ShaderMaterial in rows_of.call(n, "chitin" if n.contains("biter") else "flesh_worm"):
			var v: Array[Vector4] = ModelLibrary.MaterialRows.row_vectors(r)
			flags_ok = flags_ok and int(v[1].w) & (16 if n.contains("biter") else 32) != 0 and v[5].w > 0.0
	check(flags_ok, "the skin's mode and second tint reach a merged material's table")
	# Where a worm's or spawner's mask doesn't reach (COLOR (1, 1, 1), the skin tool's "no mask": a
	# worm's mouth, a spawner's sacs), no tier colour: the shader takes the blue off red and green
	# (skin_mode 2). --creature-glow=old (CreatureModels.old_glow) keeps 0.2.1's glow, mode 3 (flags 48).
	var fresh := func(name: String, combine: bool) -> ArrayMesh:
		var l := ModelLibrary.Load.new()
		l.path = _own_glb(name)
		l.combine = combine
		l.run()
		return ModelLibrary._commit_load(l, []) as ArrayMesh
	var unmasked_white := 0
	var worm_parts: ArrayMesh = fresh.call("big-worm-turret", false)
	for i in (worm_parts.get_surface_count() if worm_parts != null else 0):
		var sm := worm_parts.surface_get_material(i)
		if sm == null or not sm.resource_name.contains("flesh_worm"):
			continue
		var cols: Variant = ModelLods.arrays_of(worm_parts, i)[Mesh.ARRAY_COLOR]
		if cols is PackedColorArray:
			for c: Color in cols:
				if c.r > 0.999 and c.g > 0.999 and c.b > 0.999:
					unmasked_white += 1
	var mode_of := func(mesh: ArrayMesh, part: String) -> Array:
		for i in (mesh.get_surface_count() if mesh != null else 0):
			var m := mesh.surface_get_material(i) as ShaderMaterial
			var list: Array = ModelLibrary.MaterialRows.rows(m)
			for r in (list if not list.is_empty() else [m]):
				if r != null and (r as ShaderMaterial).resource_name.contains(part):
					return [int(r.get_shader_parameter("skin_mode")), int(ModelLibrary.MaterialRows.row_vectors(r)[1].w) & 48]
		return [-1, 0]
	var glow_now: Array = mode_of.call(CreatureModels.prepare(fresh.call("big-worm-turret", true), "big-worm-turret"), "flesh_worm")
	CreatureModels.old_glow = true
	var glow_old: Array = mode_of.call(CreatureModels.prepare(fresh.call("biter-spawner", true), "spitter-spawner"), "flesh_spawner_dome")
	CreatureModels.old_glow = false
	var include_text := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc")
	check(unmasked_white > 0 and glow_now == [2, 32] and glow_old == [3, 48]
		and include_text.contains("float unmasked = m_skin == 3 ? 0.0 : COLOR.b;")
		and include_text.contains("m_skin = (row_flag(e.w, 16.0) ? 1 : 0) + (row_flag(e.w, 32.0) ? 2 : 0);"),
		"where a worm's or spawner's mask doesn't reach (%d of the worm's vertices) it takes no tier colour (mode %s); --creature-glow=old keeps the glow (%s)"
		% [unmasked_white, glow_now, glow_old])
	# Knees, the walk's bend and the poses' legs on the walking model's material, at the tier's size.
	var walk := (ModelLibrary.mesh_for("small-biter") as Mesh).surface_get_material(0) as ShaderMaterial
	var knees: Array = walk.get_shader_parameter("rig_knee") if walk != null else []
	var poses: Array = walk.get_shader_parameter("rig_pose") if walk != null else []
	var rig: Dictionary = CreatureModels.rig("big-biter")
	var reach := float((rig["limbs"][0] as Dictionary).get("reach", 0.0))
	check(knees.size() == 12 and is_equal_approx((knees[0] as Vector4).w, reach * 0.5) and poses.size() == 60
		and poses.slice(0, 6).any(func(p: Vector4) -> bool: return p != Vector4.ZERO)
		and poses.slice(12, 18).any(func(p: Vector4) -> bool: return p != Vector4.ZERO),
		"a walking model carries its knees (scaled with the tier) and its attack and corpse poses' legs: %s %s" % [knees.slice(0, 1), reach])
	check(CreatureModels.pose_slot("small-biter-attack") == 0 and CreatureModels.pose_slot("behemoth-spitter-corpse-3") == 4
		and CreatureModels.pose_slot("medium-biter-corpse") == 1 and CreatureModels.pose_slot("small-worm-turret-corpse") == -1,
		"pose models map to the walking model's pose slots, none for a worm")
	# Factorio's bite: the walk's stance at its first and last frames, the pose at frame 5 of 11; the
	# spitter's 14 frames forward and back, the stance at the turn.
	check(is_zero_approx(Creatures._bite_amount(0.0)) and is_equal_approx(Creatures._bite_amount(5.0 / 11.0), 1.0)
		and is_zero_approx(Creatures._bite_amount(9.0 / 11.0)) and is_equal_approx(Creatures._rise_amount(0.5), 1.0)
		and is_zero_approx(Creatures._rise_amount(0.0)), "the bite and the spit follow Factorio's attack frames")
	# A biting biter is drawn with its walking model, its legs and body blended into the bite.
	var heap := Creatures.new()
	add_child(heap)
	var node := Node3D.new()
	node.position = Vector3(3, 0, 3)
	heap.add(55, "small-biter", node)
	heap.handle_attacks({"l": [55, roundi(4.0 * 256), roundi(3.0 * 256)]})
	var models := {}
	var most := 0.0
	for f in 40:
		heap._process(1.0 / 60.0)
		var c = heap._creatures.get(55)
		if c != null and not c.drawn.is_empty():
			models[c.drawn_model] = true
			var a: float = c.drawn[15]
			if a >= 2.0 and a < 3.0:
				most = maxf(most, (a - 2.0) / CreatureModels.POSE_SCALE)
	check(models.keys() == ["small-biter"] and most > 0.9,
		"a biting biter is drawn with its walking model, its legs blended into the bite (%.2f of the way at most): %s" % [most, models.keys()])
	# One that dies folds its legs into its corpse's as it falls.
	heap.remove(55, true)
	var d = heap._dying[0] if not heap._dying.is_empty() else null
	var code := Creatures._pose_code(d.corpse, 1.0) if d != null else 0.0
	check(d != null and code >= 3.0 and code < 7.0 and is_equal_approx(code - floorf(code), CreatureModels.POSE_SCALE),
		"a dying biter's legs fold into its corpse's (pose code %.3f for %s)" % [code, d.corpse if d != null else ""])
	node.free()
	heap.queue_free()
	# Regression: pack or per-model PBR overrides on Wube3DP / Placeholders never turn untextured
	# CUSTOM1 creatures glossy/unweathered or overwrite CUSTOM1 skin masks with the raw tier tint.
	var saved_merge := ModelLibrary.merge_materials
	var saved_pbr_packs := ModelPacksScript.pbr_packs.duplicate()
	var saved_pbr_models := ModelPacksScript.pbr_models.duplicate()
	ModelPacksScript.set_pbr_overrides({"builtin:wube3dp": true, "builtin:placeholders": true}, {
		"builtin:wube3dp|big-biter": true, "builtin:wube3dp|big-spitter": true,
		"builtin:wube3dp|biter-spawner": true, "builtin:placeholders|big-worm-turret": true,
		"builtin:placeholders|big-wriggler-pentapod": true,
	})
	var pbr_leak := ""
	for merge in [false, true]:
		ModelLibrary.merge_materials = merge
		ModelLibrary.choices_changed([], "*")
		for pair in [
			["behemoth-biter", "chitin_big", 1],
			["big-spitter", "chitin_spitter", 1],
			["medium-worm-turret", "flesh_worm", 2],
			["medium-worm-turret", "belly_worm", 0],
			["biter-spawner", "flesh_spawner_dome", 2],
			["big-wriggler-pentapod", "chitin_wriggler_leg", 2],
		]:
			var mname := str(pair[0])
			var mat_part := str(pair[1])
			var want_skin := int(pair[2])
			var found: Array = rows_of.call(mname, mat_part)
			if found.is_empty():
				pbr_leak = "%s missing %s (merge=%s)" % [mname, mat_part, merge]
				break
			for r: ShaderMaterial in found:
				var mtex: Variant = r.get_shader_parameter("modeller_tex")
				var flags := int(ModelLibrary.MaterialRows.row_vectors(r)[1].w)
				var grain_v: Variant = r.get_shader_parameter("grain")
				var grime_v: Variant = r.get_shader_parameter("grime")
				var rust_v: Variant = r.get_shader_parameter("rust")
				var part_colors_v: Variant = r.get_shader_parameter("part_colors")
				var part_data_v: Variant = r.get_shader_parameter("part_data")
				var skin_v: Variant = r.get_shader_parameter("skin_mode")
				var grain_val := float(grain_v) if grain_v != null else -1.0
				var grime_val := float(grime_v) if grime_v != null else -1.0
				var rust_val := float(rust_v) if rust_v != null else -1.0
				var part_val := float(part_data_v) if part_data_v != null else 0.0
				var skin_got := int(skin_v) if skin_v != null else 0
				if mtex == true or (flags & ModelLibrary.MaterialRows.FLAG_MODELLER_TEX) != 0 \
						or grain_val <= 0.0 or grime_val <= 0.0 or rust_val > 0.0 \
						or part_colors_v != true or part_val < 0.99 or skin_got != want_skin:
					pbr_leak = "%s/%s (merge=%s): mtex=%s flags=%d grain=%s grime=%s rust=%s skin=%s" % [
						mname, mat_part, merge, mtex, flags, grain_v, grime_v, rust_v, skin_got]
					break
			if pbr_leak != "":
				break
		if pbr_leak != "":
			break
	var alias_hit := ModelLibrary.mesh_for("behemoth-biter") != null and ModelLibrary.choices_changed(["big-biter"]) \
		and not ModelLibrary._cache.has("behemoth-biter")
	ModelLibrary.merge_materials = saved_merge
	ModelPacksScript.set_pbr_overrides(saved_pbr_packs, saved_pbr_models)
	ModelLibrary.choices_changed([], "*")
	var mat_inc := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc")
	check(pbr_leak == "" and alias_hit and mat_inc.contains("if (m_skin > 0 && !(use_albedo_tex && !merged)) {"),
		"untextured CUSTOM1 creatures stay matte, weathered and skinned even with PBR toggles on (%s, alias=%s)" % [pbr_leak, alias_hit])


## Space Age's creatures (I23's second part): Gleba's wriggler is one model under each tier's own tint
## over its mask (skin_mode 2, creature_skins.json from tools/models/space_skin.py), with knees fitted
## to its run and its strike and corpse poses blended on the walking model; pentapods, shells, Gleba's
## spawners and demolishers carry their skins in their own part colours (`colour`: nothing is done to
## them on load but the demolishers' lava, which shines by its own paint). A wriggler's corpse lies
## Factorio's minute without Nauvis's blood, and the Gleba spawners breathe on Factorio's 5 s loop.


func _space_creatures() -> void:
	var names := ["small-wriggler-pentapod", "big-wriggler-pentapod", "medium-wriggler-pentapod-corpse", "big-wriggler-pentapod-corpse",
		"big-stomper-pentapod"]
	for n in names:
		ModelLibrary.mesh_for(n)
	var until := Time.get_ticks_msec() + 20000
	while not names.all(func(n: String) -> bool: return ModelLibrary.ready(n)) and Time.get_ticks_msec() < until:
		ModelLibrary.poll()
		await get_tree().process_frame
	var legs_of := func(model: String) -> ShaderMaterial:
		var mesh := ModelLibrary.mesh_for(model) as Mesh
		if mesh == null:
			return null
		for i in mesh.get_surface_count():
			var m := mesh.surface_get_material(i) as ShaderMaterial
			var list: Array = ModelLibrary.MaterialRows.rows(m)
			for r in (list if not list.is_empty() else [m]):
				if r != null and (r as ShaderMaterial).resource_name.contains("chitin_wriggler_leg"):
					return r
		return null
	var tier := func(n: String, k: int) -> Array:
		return CreatureModels.skin_of("big-wriggler-pentapod").get("tiers", {}).get(n, [[0, 0, 0, 0], [0, 0, 0, 0]])[k]
	var looks := {}
	for n in ["small-wriggler-pentapod", "big-wriggler-pentapod", "medium-wriggler-pentapod-corpse"]:
		var r: ShaderMaterial = legs_of.call(n)
		looks[n] = [r.get_shader_parameter("skin_mode"), r.get_shader_parameter("albedo"), r.get_shader_parameter("skin_tint2")] \
			if r != null else [-1, Color.BLACK, Color.BLACK]
	var small_t: Array = tier.call("small-wriggler-pentapod", 0)
	var small_srgb := Color(float(small_t[0]), float(small_t[1]), float(small_t[2])).linear_to_srgb()
	check(int(looks["small-wriggler-pentapod"][0]) == 2 and int(looks["big-wriggler-pentapod"][0]) == 2
		and int(looks["medium-wriggler-pentapod-corpse"][0]) == 2
		and (looks["small-wriggler-pentapod"][1] as Color).is_equal_approx(Color(small_srgb, 1.0))
		and not (looks["small-wriggler-pentapod"][1] as Color).is_equal_approx(looks["big-wriggler-pentapod"][1])
		and is_equal_approx((looks["small-wriggler-pentapod"][2] as Color).a, float(tier.call("small-wriggler-pentapod", 1)[3])),
		"each wriggler tier's legs and back are its sprite's mask under the tier's own tint, its corpse too: %s" % [looks])
	var stomper := ModelLibrary.mesh_for("big-stomper-pentapod") as ArrayMesh
	var kept: Material = stomper.surface_get_material(0) if stomper != null else null
	if stomper != null:
		CreatureModels.prepare(stomper, "big-stomper-pentapod")
	check(stomper != null and stomper.surface_get_material(0) == kept
		and str(CreatureModels.skin_of("big-stomper-pentapod").get("mode", "")) == "colour"
		and str(CreatureModels.skin_of("demolisher-head").get("mode", "")) == "colour",
		"pentapods and demolishers carry their skins in their part colours: their materials are left as they load")
	# The demolishers' lava shines by its own paint (the sprite's lava), PAINT_GLOW of it, not its .glb's
	# 2.5 times a bright red; the crust over it not at all. --creature-glow=old: the .glb's glow.
	var lava_of := func(mesh: ArrayMesh) -> Dictionary:
		var out := {}
		for i in (mesh.get_surface_count() if mesh != null else 0):
			var m := mesh.surface_get_material(i) as ShaderMaterial
			var list: Array = ModelLibrary.MaterialRows.rows(m)
			for r in (list if not list.is_empty() else [m]):
				var rn := (r as ShaderMaterial).resource_name if r != null else ""
				if CreatureModels.PAINT_GLOW.has(rn):
					var e: Variant = r.get_shader_parameter("emission_energy")
					var p: Variant = r.get_shader_parameter("emission_from_paint")
					out[rn] = [p is bool and bool(p), float(e) if e != null else 0.0,
						int(ModelLibrary.MaterialRows.row_vectors(r)[1].w) & 64]
		return out
	var paint_glows := func(found: Dictionary, name: String, share: float) -> bool:
		var v: Array = found.get(name, [false, -1.0, 0])
		return v[0] == true and is_equal_approx(float(v[1]), share) and int(v[2]) == 64
	var tail_names := ["demolisher-tail"]
	ModelLibrary.mesh_for("demolisher-tail")
	var wait_tail := Time.get_ticks_msec() + 20000
	while not tail_names.all(func(n: String) -> bool: return ModelLibrary.ready(n)) and Time.get_ticks_msec() < wait_tail:
		ModelLibrary.poll()
		await get_tree().process_frame
	var lava_now: Dictionary = lava_of.call(ModelLibrary.mesh_for("demolisher-tail") as ArrayMesh)
	var raw_tail := ModelLibrary.Load.new()
	raw_tail.path = _own_glb("demolisher-tail")
	raw_tail.run()
	CreatureModels.old_glow = true
	var lava_old: Dictionary = lava_of.call(CreatureModels.prepare(ModelLibrary._commit_load(raw_tail, []) as ArrayMesh, "demolisher-tail"))
	CreatureModels.old_glow = false
	var old_lava: Array = lava_old.get("lava_demolisher", [true, 0.0, 64])
	check(paint_glows.call(lava_now, "lava_demolisher", float(CreatureModels.PAINT_GLOW["lava_demolisher"]))
		and paint_glows.call(lava_now, "lava_demolisher_dim", 0.0)
		and old_lava[0] == false and float(old_lava[1]) > 2.0 and int(old_lava[2]) == 0,
		"a demolisher's lava shines by its own paint, its crust not at all (%s); --creature-glow=old keeps the .glb's glow (%s)"
		% [lava_now, lava_old])
	check(is_equal_approx(float(CreatureModels.rig("gleba-spawner").get("rate", 0.0)), 0.2)
		and is_equal_approx(float(CreatureModels.rig("gleba-spawner-small").get("rate", 0.0)), 0.2),
		"Gleba's spawners breathe on Factorio's loop: 16 frames forward and back at 0.1 a tick, 5 s")
	# Knees from the run sheets and the strike's and corpse's legs on the walking model, at the tier's size.
	var walk := (ModelLibrary.mesh_for("small-wriggler-pentapod") as Mesh).surface_get_material(0) as ShaderMaterial \
		if ModelLibrary.mesh_for("small-wriggler-pentapod") != null else null
	var knees: Array = walk.get_shader_parameter("rig_knee") if walk != null else []
	var poses: Array = walk.get_shader_parameter("rig_pose") if walk != null else []
	var reach := float((CreatureModels.rig("big-wriggler-pentapod")["limbs"][0] as Dictionary).get("reach", 0.0))
	check(reach > 0.0 and knees.size() == 12 and is_equal_approx((knees[0] as Vector4).w, reach * 0.6) and poses.size() == 60
		and poses.slice(0, 5).any(func(p: Vector4) -> bool: return p != Vector4.ZERO)
		and poses.slice(12, 17).any(func(p: Vector4) -> bool: return p != Vector4.ZERO),
		"a wriggler carries its knees (scaled with the tier) and its strike's and corpse's legs: %s" % [knees.slice(0, 1)])
	check(CreatureModels.pose_slot("small-wriggler-pentapod-attack") == 0
		and CreatureModels.pose_slot("medium-wriggler-pentapod-premature-corpse") == 1,
		"a wriggler's strike and corpse map to the walking model's pose slots")
	var top := Creatures.WRIGGLER_STRIKE_TOP
	var back := Creatures.WRIGGLER_STRIKE_BACK
	check(is_zero_approx(Creatures._bite_amount(0.0, top, back)) and is_equal_approx(Creatures._bite_amount(3.0 / 19.0, top, back), 1.0)
		and is_zero_approx(Creatures._bite_amount(12.0 / 19.0, top, back)), "the wriggler's strike follows its 19 frames")
	# A striking wriggler is its walking model with its legs blended into the strike; a dead one folds
	# into its corpse, which lies a minute without Nauvis's blood puddle.
	var heap := Creatures.new()
	add_child(heap)
	var node := Node3D.new()
	node.position = Vector3(3, 0, 3)
	heap.add(56, "big-wriggler-pentapod", node)
	heap.handle_attacks({"l": [56, roundi(4.0 * 256), roundi(3.0 * 256)]})
	var models := {}
	var most := 0.0
	for f in 40:
		heap._process(1.0 / 60.0)
		var c = heap._creatures.get(56)
		if c != null and not c.drawn.is_empty():
			models[c.drawn_model] = true
			var a: float = c.drawn[15]
			if a >= 2.0 and a < 3.0:
				most = maxf(most, (a - 2.0) / CreatureModels.POSE_SCALE)
	check(models.keys() == ["big-wriggler-pentapod"] and most > 0.9,
		"a striking wriggler is drawn with its walking model, its legs blended into the strike (%.2f): %s" % [most, models.keys()])
	heap.remove(56, true)
	var d = heap._dying[0] if not heap._dying.is_empty() else null
	var code := Creatures._pose_code(d.corpse, 1.0) if d != null else 0.0
	check(d != null and d.corpse == "big-wriggler-pentapod-corpse" and code >= 3.0 and code < 4.0,
		"a dying wriggler's legs fold into its corpse's (pose code %.3f)" % code)
	for f in 90:
		heap._process(1.0 / 60.0)
	var lying: Array = heap._corpses.filter(func(k) -> bool: return k.model == "big-wriggler-pentapod-corpse")
	check(lying.size() == 1 and is_equal_approx(lying[0].life, Creatures.WRIGGLER_CORPSE_SECONDS) and lying[0].puddle == -1,
		"a wriggler's corpse lies Factorio's minute, without Nauvis's blood")
	node.free()
	heap.queue_free()


## Machines' moving parts and glow move in the model shader from their state (anim.gd setup_part
## and _write, factorio_material.gdshaderinc anim_vertex and anim_glow), written only when it
## changes. The shader's pose, worked out here the shader's way, follows what anim.gd did every
## frame before (spinning, cycling, rocking, pistons, the power switch, hatches, lit lamps, glow
## fading), nothing is written while nothing changes, `st` changes reach it, and a new epoch of the
## shader's clock moves the state over without a jump.


func _gpu_anim() -> void:
	var anim := AnimScript.new()
	add_child(anim)
	var dt := 1.0 / 1000.0  # the old per-frame sums at a fine step, so they meet the exact sums
	# [model, part kind, working from, working until]
	# Assembling machine 1: the rebuilt Placeholders model is drawn first (its own gears), Wube3DP's with
	# --assembler-models=old.
	var am1_gear := "am1_gear_cw" if ModelPacksScript.prefer_builtin_assemblers else "gear_am1_w"
	var cases := [["burner-mining-drill", "spin_drill", 0.5, 2.5], ["steam-engine", "spin_flywheel", 0.3, 1.6],
		["assembling-machine-1", am1_gear, 0.2, 2.0], ["oil-refinery", "yoke_refinery", 0.4, 2.2],
		["recycler", "slide_recycler_panel", 0.5, 1.5], ["pumpjack", "rock_beam", 0.25, 2.0],
		["offshore-pump", "bob_b", 0.5, 2.5], ["power-switch", "switch", 0.5, 0.8],
		["rocket-silo", "door_silo_e", 0.2, 3.0], ["rail-signal", "lit_green", 0.5, 2.0]]
	var unit := 9000
	var swapped: Array[String] = []
	for case in cases:
		var part := _part_of(str(case[0]), str(case[1]))
		# Models replaced by another project's (the FUE5 pack's) may not have our moving parts:
		# our own model is checked then.
		if part == null and _theirs_in_use(str(case[0])):
			_ours([case[0]])
			swapped.append(str(case[0]))
			part = _part_of(str(case[0]), str(case[1]))
		if part == null:
			check(false, "%s has a %s part" % [case[0], case[1]])
			continue
		unit += 1
		var working := {unit: 0}
		var base := Transform3D(Basis(Vector3.UP, 0.3), Vector3(10.5, 0.0, 20.5))
		var group := _anim_group(part, unit, base)
		AnimScript.place(group, anim, working)
		var corners: Array[Vector3] = []
		var box := part.mesh.get_aabb()
		for k in 8:
			corners.append(box.get_endpoint(k))
		var worst := 0.0
		var old_at := 0.0  # the old accumulators: radians, loops, piston phase, how far open
		var speed := 0.0
		var started := false
		var t := 0.0
		var sample := 0.25
		var c: Dictionary = ModelLibrary.CYCLES.get(part.kind, {})
		while t < 4.0:
			var on := t + dt > float(case[2]) and t + dt <= float(case[3])
			if on != (int(working[unit]) == 1):
				working[unit] = 1 if on else 0
				if part.kind == "door_silo_e":
					anim._linear(anim._state(unit), part, true, on)  # what _hatch does with a rocket near
				anim._write(group, 0, working)  # what state_changed does
			anim._process(dt)
			t += dt
			# The old way, one frame of dt.
			var amount := 0.0
			var goal := 1.0 if on else 0.0
			if on or started:
				started = true
				speed += (goal - speed) * (1.0 - exp(-dt / (AnimScript.SPIN_UP if on else AnimScript.SPIN_DOWN)))
				if not on and speed < 0.01:
					speed = 0.0
			match AnimScript.kind_of(group):
				AnimScript.KIND_TIMED:
					if not started:
						amount = 0.0
					elif not c.is_empty():
						old_at = fposmod(old_at + speed * dt / float(c.get("period", 1.0)), 1.0)
						var loop := old_at + float(c.get("phase", 0.0))
						amount = 0.5 - 0.5 * cos(loop * TAU)
						match c.get("wave", "out"):
							"swing":
								amount = sin(loop * TAU)
							"spin":
								amount = fposmod(loop, 1.0)
						amount *= float(c.get("angle", 1.0))
					elif part.kind.begins_with("rock_"):
						old_at = fposmod(old_at - speed * AnimScript.SPIN_SPEEDS["spin_crank"] * TAU * dt, TAU)
						amount = AnimScript.ROCK_AMPLITUDE * sin(old_at)
					elif AnimScript.BOB_PHASE.has(part.kind):
						old_at = fposmod(old_at + speed * float(AnimScript.BOB_SPEEDS.get(part.model, 1.0)) * TAU * dt, TAU)
						amount = (0.5 - 0.5 * cos(old_at + float(AnimScript.BOB_PHASE[part.kind]))) * minf(speed * 3.0, 1.0)
					else:
						old_at = fposmod(old_at - speed * AnimScript._turns(part.model, part.kind) * TAU * dt, TAU)
						amount = old_at
				AnimScript.KIND_SWITCH:
					old_at = move_toward(old_at, goal, AnimScript.SWITCH_SPEED * dt)
					amount = old_at
				AnimScript.KIND_HATCH:
					old_at = move_toward(old_at, goal, dt / float(ModelLibrary.HATCHES[part.kind].get("time", 1.0)))
					amount = old_at
				AnimScript.KIND_LIT:
					amount = 1.0 if on else 0.0
			if t >= sample:
				sample += 0.25
				var old_xf := base * part.turned(amount)
				for v in corners:
					worst = maxf(worst, (old_xf * v).distance_to(base * _shader_part_pos(part, group.customs[0], anim.clock(), v)))
		check(worst < 0.03, "%s's %s moves in the shader as anim.gd turned it every frame (worst %.4f tiles apart over 4 s)" % [case[0], case[1], worst])
	_restore_models(swapped)
	# A furnace's fire fades in and out with its working state, as it did frame by frame.
	var furnace := ModelLibrary.mesh_for("stone-furnace")
	var glow_group := _anim_group(null, 9500, Transform3D(Basis(), Vector3(4.0, 0.0, 4.0)), furnace)
	var glow_work := {9500: 0}
	AnimScript.place(glow_group, anim, glow_work)
	var level := 0.0
	var glow_worst := 0.0
	var glow_peak := 0.0
	var gt := 0.0
	while gt < 3.0:
		var lit := gt + dt > 0.5 and gt + dt <= 1.5
		if lit != (int(glow_work[9500]) == 1):
			glow_work[9500] = 1 if lit else 0
			anim._write(glow_group, 0, glow_work)
		anim._process(dt)
		gt += dt
		var goal := 1.0 if lit else 0.0
		level += (goal - level) * (1.0 - exp(-dt / (AnimScript.GLOW_UP if goal > level else AnimScript.GLOW_DOWN)))
		var shader_level := _shader_glow(glow_group.customs[0], anim.clock())
		glow_worst = maxf(glow_worst, absf(level - shader_level))
		glow_peak = maxf(glow_peak, shader_level)
	check(AnimScript.kind_of(glow_group) == AnimScript.KIND_GLOW and glow_worst < 0.02 and glow_peak > 0.95,
		"a furnace's fire glows in the shader as anim.gd eased it every frame (worst %.4f apart, up to %.2f)" % [glow_worst, glow_peak])
	# A roboport's door opens when its group next looks and finds a robot near, then the shader
	# slides it: nothing is written between looks. FUE5's roboport has no doors: ours is checked.
	var door_swapped := _theirs_in_use("roboport")
	if door_swapped:
		_ours(["roboport"])
	var door := _part_of("roboport", "door_n")
	var robots := FakeRobots.new()
	anim.movers = robots
	check(door != null, "the roboport has a door_n part")
	if door != null:
		_check_roboport_door(anim, door)
	if door_swapped:
		_restore_models(["roboport"])
	robots.queue_free()
	anim.queue_free()
	await _gpu_anim_world()


func _check_roboport_door(anim: AnimScript, door: ModelLibrary.AnimPart) -> void:
	var door_group := _anim_group(door, 9700, Transform3D(Basis(), Vector3(30.0, 0.0, 30.0)))
	AnimScript.place(door_group, anim, {})
	var shut := door_group.customs[0]
	for k in 12:  # 0.2 s: past the group's first look
		anim._roboport(door_group, 1.0 / 60.0)
	var opened := door_group.customs[0]
	var door_writes := anim.writes
	for k in 30:
		anim._process(1.0 / 60.0)
		anim._roboport(door_group, 1.0 / 60.0)
	var top := door.mesh.get_aabb().get_endpoint(7)
	var slid := _shader_part_pos(door, door_group.customs[0], anim.clock(), top) - top
	check(floori(-shut.b - 1.0) % 2 == 0 and floori(-opened.b - 1.0) % 2 == 1 and anim.writes == door_writes
		and slid.distance_to(door.slide * AnimScript.DOOR_TRAVEL) < 0.01,
		"a roboport's door opens for a robot near at its group's look and slides open in the shader (%s, %d writes after)" % [slid, anim.writes - door_writes])


## The moving part of `kind` in the model `model`, or null.


func _gpu_anim_world() -> void:
	# In a world: `st` reaches the parts, nothing is written frame to frame, and a new epoch moves
	# every state onto the newer clock without a jump.
	var world := WorldMirror.new()
	add_child(world)
	var cv := ChunkView.new()
	cv.coord = Vector2i(0, 0)
	world.chunks[cv.coord] = cv
	world.add_child(cv)
	var rec := WorldMirror.Rec.new()
	rec.key = 9600
	rec.unit = 9600
	rec.pos = Vector2(5.5, 5.5)
	world.entities[9600] = rec
	var drill: ModelLibrary.AnimPart = null
	for p: ModelLibrary.AnimPart in ModelLibrary.parts_for("burner-mining-drill"):
		if p.kind == "spin_drill":
			drill = p
	var dgroup := _anim_group(drill, 9600, Transform3D(Basis(), Vector3(5.5, 0.0, 5.5)))
	AnimScript.place(dgroup, world.animator, world.working)
	cv.anim_groups.append(dgroup)
	world._on_states([9600, 1])
	var on_custom := dgroup.customs[0]
	var writes: int = world.animator.writes
	for k in 30:
		world.animator._process(1.0 / 60.0)
	check(floori(-on_custom.b - 1.0) % 2 == 1 and world.animator.writes == writes and dgroup.customs[0] == on_custom,
		"`st` turns a drill's part on in its custom data, and half a second of frames writes nothing (%d writes)" % (world.animator.writes - writes))
	var probe := drill.mesh.get_aabb().get_endpoint(7)
	world.animator._time = AnimScript.EPOCH - 0.004
	world.animator._process(0.0)
	var even_custom := dgroup.customs[0]
	world.animator._process(0.008)  # into the next epoch: migrated this frame
	# Where the drill is drawn now from its state on the odd clock, and from its state on the even
	# one (still running for an epoch): the same place.
	var after := _shader_part_pos(drill, dgroup.customs[0], world.animator.clock(), probe)
	var unmoved := _shader_part_pos(drill, even_custom, world.animator.clock(), probe)
	var parity := floori((-dgroup.customs[0].b - 1.0) / 2.0) % 2
	check(parity == 1 and dgroup.epoch == 1 and after.distance_to(unmoved) < 0.005 and after.distance_to(probe) > 0.0,
		"a new epoch of the shader's clock moves the drill onto the odd clock without a jump (%.5f tiles)" % after.distance_to(unmoved))
	world.queue_free()


## A gate opens for the client's own character and friendly vehicles, not for the focus an add-on's
## camera moves to where it looks, nor for flying robots; `--gate-open=old` (anim.gd gate_old) brings the
## old rule back (the focus opens it, robots count).


func _gate_open() -> void:
	var swapped := _theirs_in_use("gate")
	if swapped:
		_ours(["gate"])
	var part: ModelLibrary.AnimPart = null
	for p: ModelLibrary.AnimPart in ModelLibrary.parts_for("gate"):
		if p.kind == "gate_door" or p.kind == "baked":
			part = p
			break
	check(part != null, "the gate has a door part")
	if part == null:
		if swapped:
			_restore_models(["gate"])
		return
	var anim := AnimScript.new()
	add_child(anim)
	var near := FakeFriendly.new()
	anim.movers = near
	var gate := Vector2(50.5, 50.5)
	var group := _anim_group(part, 9800, Transform3D(Basis(), Vector3(gate.x, 0.0, gate.y)))
	check(AnimScript.kind_of(group) == AnimScript.KIND_GATE, "a gate's door is looked after as a gate")
	AnimScript.place(group, anim, {})
	var was_old := AnimScript.gate_old
	var far := Vector2(500.0, 500.0)
	# Half a second of frames (past a few of the group's looks) with the focus and the character given;
	# whether the door is then opening.
	var run := func(focus: Vector2, character: Vector2) -> bool:
		anim.character_at = character
		for k in 30:
			anim._time += 1.0 / 60.0
			anim._gates(group, focus, 1.0 / 60.0)
		return bool(anim._linear(anim._state(9800), part, false, false)[2])
	AnimScript.gate_old = false
	var camera_on_gate: bool = run.call(gate, far)
	var camera_no_char: bool = run.call(gate, Vector2.INF)
	var char_at_gate: bool = run.call(far, gate + Vector2(1.5, 0.0))
	var char_gone: bool = run.call(gate, far)
	near.vehicle = true
	var vehicle_near: bool = run.call(far, far)
	near.vehicle = false
	near.robot = true
	var robot_near: bool = run.call(far, far)
	check(not camera_on_gate and not camera_no_char and char_at_gate and not char_gone and vehicle_near and not robot_near,
		"a gate opens for the character and a friendly vehicle near, not for a camera looking at it or a robot (camera %s/%s, character %s, gone %s, vehicle %s, robot %s)"
		% [camera_on_gate, camera_no_char, char_at_gate, char_gone, vehicle_near, robot_near])
	AnimScript.gate_old = true
	var old_robot: bool = run.call(far, far)
	near.robot = false
	var old_shut: bool = run.call(far, gate)
	var old_camera: bool = run.call(gate, far)
	check(old_robot and not old_shut and old_camera,
		"--gate-open=old: the focus opens a gate (where the character is doesn't) and robots do (robot %s, focus away %s, focus on it %s)"
		% [old_robot, old_shut, old_camera])
	AnimScript.gate_old = was_old
	# Real states from the bridge (`st`, perf gate_state; anim.gd _gate_real): the doors follow them, the guess
	# isn't used for that gate; one without a state still guesses; --gate-state=guess guesses whatever is sent.
	AnimScript.gate_old = false
	var was_guess := AnimScript.gate_guess
	AnimScript.gate_guess = false
	near.vehicle = false
	near.robot = false
	var real_world := SiloWorld.new()
	anim.world = real_world
	var real_at := Vector2(60.5, 50.5)
	var real_group := _anim_group(part, 9801, Transform3D(Basis(), Vector3(real_at.x, 0.0, real_at.y)))
	AnimScript.place(real_group, anim, {})
	var amount := func(unit: int) -> float:
		return AnimScript._amount(anim._linear(anim._state(unit), part, false, false), part, anim._time)
	var frames := func(n: int, g: AnimScript.Group, character: Vector2) -> void:
		anim.character_at = character
		for k in n:
			anim._time += 1.0 / 60.0
			anim._gates(g, far, 1.0 / 60.0)
	real_world.working[9801] = AnimScript.GATE_OPENED
	frames.call(1, real_group, far)
	var seen_open: float = amount.call(9801)
	real_world.working[9801] = AnimScript.GATE_CLOSING
	frames.call(3, real_group, real_at)
	var closing_part: float = amount.call(9801)
	frames.call(27, real_group, real_at)
	var closed_by_state: float = amount.call(9801)
	real_world.working[9801] = AnimScript.GATE_OPENING
	frames.call(3, real_group, far)
	var opening_part: float = amount.call(9801)
	frames.call(27, real_group, far)
	var opened_by_state: float = amount.call(9801)
	real_world.working[9801] = AnimScript.GATE_CLOSED
	frames.call(1, real_group, far)
	var closed_at_once: float = amount.call(9801)
	var full := part.phase
	check(is_equal_approx(seen_open, full) and closing_part > 0.0 and closing_part < full and closed_by_state == 0.0
		and opening_part > 0.0 and opening_part < full and is_equal_approx(opened_by_state, full) and closed_at_once == 0.0,
		"a gate with a real state follows it: seen opened at once %s, closing %s then shut %s with the character at it, opening %s then open %s with nothing near, closed at once %s (full %s)"
		% [seen_open, closing_part, closed_by_state, opening_part, opened_by_state, closed_at_once, full])
	frames.call(30, group, gate + Vector2(1.5, 0.0))
	var unstated_guess := bool(anim._linear(anim._state(9800), part, false, false)[2])
	AnimScript.gate_guess = true
	real_world.working[9801] = AnimScript.GATE_OPENED
	frames.call(30, real_group, far)
	var guessed_shut := not bool(anim._linear(anim._state(9801), part, false, false)[2])
	frames.call(30, real_group, real_at)
	var guessed_open := bool(anim._linear(anim._state(9801), part, false, false)[2])
	check(unstated_guess and guessed_shut and guessed_open,
		"a gate with no state still guesses (%s); --gate-state=guess guesses whatever is sent (shut with nothing near %s, open for the character %s)"
		% [unstated_guess, guessed_shut, guessed_open])
	AnimScript.gate_guess = was_guess
	anim.world = null
	real_world.free()
	if swapped:
		_restore_models(["gate"])
	near.queue_free()
	anim.queue_free()
	_gate_real_movers()


## The real movers.gd under gates: friendly_near sees a car and a flying robot, and skips the robot when asked.


func _gate_real_movers() -> void:
	var p := ProtoDB.new()
	p.add_entities([
		[5, "logistic-robot", "logistic-robot", -0.2, -0.2, 0.2, 0.2, 1, 1, 1, 1, 1],
		[8, "car", "car", -0.7, -1.0, 0.7, 1.0, 1, 1, 1, 1, 1],
	])
	var holder := Node3D.new()
	add_child(holder)
	var layer := MoverLayer.new()
	layer.protos = p
	holder.add_child(layer)
	layer.handle({"t": "mv", "k": 100, "part": 1, "parts": 1, "p": 2, "l": [[10, 8, 100 * 256, 100 * 256, 0], [11, 5, 200 * 256, 200 * 256, 0]]})
	layer._process(1.0 / 60.0)
	var at_car := Vector3(100.0, 0.0, 100.0)
	var at_robot := Vector3(200.0, 0.0, 200.0)
	var car_default: bool = layer.friendly_near(at_car, 4.0)
	var car_no_robots: bool = layer.friendly_near(at_car, 4.0, false)
	var robot_default: bool = layer.friendly_near(at_robot, 4.0)
	var robot_skipped: bool = layer.friendly_near(at_robot, 4.0, false)
	var empty: bool = layer.friendly_near(Vector3(300.0, 0.0, 300.0), 4.0)
	check(car_default and car_no_robots and robot_default and not robot_skipped and not empty,
		"movers.friendly_near: a car counts either way, a flying robot only when robots is true (car %s/%s, robot %s/%s, empty %s)"
		% [car_default, car_no_robots, robot_default, robot_skipped, empty])
	# The guess's reach grows with a vehicle's speed (friendly_near_moving): the car driven 1 tile in 2 ticks
	# (30 tiles a second) opens a gate 10 tiles ahead with 0.4 s of lead (12 tiles); standing, only within 4.
	var still_far: bool = layer.friendly_near_moving(Vector3(110.0, 0.0, 100.0), 4.0, 0.4, false)
	layer.handle({"t": "mv", "k": 102, "part": 1, "parts": 1, "p": 2, "l": [[10, 8, 101 * 256, 100 * 256, 0]]})
	layer._process(1.0 / 60.0)
	var car_speed: float = MoverLayer.speed_of(layer._movers[10])
	var fast_far: bool = layer.friendly_near_moving(Vector3(111.0, 0.0, 100.0), 4.0, 0.4, false)
	var fast_fixed: bool = layer.friendly_near(Vector3(111.0, 0.0, 100.0), 4.0, false)
	var fast_too_far: bool = layer.friendly_near_moving(Vector3(120.0, 0.0, 100.0), 4.0, 0.4, false)
	check(not still_far and absf(car_speed - 30.0) < 0.01 and fast_far and not fast_fixed and not fast_too_far,
		"movers.friendly_near_moving: a standing car's reach is 4 (%s), driven at %.1f tiles/s 0.4 s of travel (10 tiles %s, fixed reach %s, 19 tiles %s)"
		% [still_far, car_speed, fast_far, fast_fixed, fast_too_far])
	# main.gd feeds anim.gd the avatar's ground position, not the focus an add-on's camera moves.
	var main_src := FileAccess.get_file_as_string("res://scripts/main.gd")
	check(main_src.contains("world.animator.character_at = avatar.ground_position() if avatar.unit != 0 and not _viewing_away else Vector2.INF")
		and not main_src.contains("character_at = char_focus") and not main_src.contains("character_at = rig"),
		"main.gd sets the gates' character from the avatar (none when unit 0 or the remote view is on another surface)")
	holder.queue_free()


## movers.gd's answer to gates: a friendly vehicle near or not, a robot near or not (counted only when asked).


class FakeFriendly extends Node:
	var vehicle := false
	var robot := false

	func friendly_near(_from: Vector3, _range: float, robots := true) -> bool:
		return vehicle or (robots and robot)


## movers.gd's answer to roboports: a robot is always near.


class FakeRobots extends Node:
	func robot_near(_from: Vector3, _radius: float) -> bool:
		return true


## A Group of one instance of `part` (or a glowing model's `mesh`), as chunk_view.gd makes them.


static func _shader_part_pos(part: ModelLibrary.AnimPart, c: Color, clock: Vector2, v: Vector3) -> Vector3:
	var m := part.mesh.surface_get_material(0) as ShaderMaterial
	var mode := int(m.get_shader_parameter("anim_mode"))
	if mode == 0 or c.b >= -0.5:
		return v
	var code := -c.b - 1.0
	var flags := floori(code)
	var s0 := code - flags
	var on := flags % 2 == 1
	var dt := maxf((clock.y if floori(flags / 2.0) % 2 == 1 else clock.x) - c.r, 0.0)
	if mode == 5:
		return v if on else v * 0.001
	var amount := float(m.get_shader_parameter("anim_amount"))
	var x := 0.0
	if mode == 6:
		x = move_toward(c.g, float(m.get_shader_parameter("anim_open")) if on else 0.0, float(m.get_shader_parameter("anim_speed")) * dt) * amount
	else:
		var goal := 1.0 if on else 0.0
		var tau := 0.35 if on else 0.9
		var e := exp(-dt / tau)
		var speed := goal + (s0 - goal) * e
		var loops := c.g + float(m.get_shader_parameter("anim_rate")) * (goal * dt + (s0 - goal) * tau * (1.0 - e))
		if mode == 1:
			x = fposmod(loops, 1.0) * TAU
		elif mode == 2:
			var wave := int(m.get_shader_parameter("anim_wave"))
			x = (sin(loops * TAU) if wave == 1 else (fposmod(loops, 1.0) if wave == 2 else 0.5 - 0.5 * cos(loops * TAU))) * amount
		elif mode == 3:
			x = amount * sin(loops * TAU)
		else:
			x = (0.5 - 0.5 * cos(loops * TAU)) * minf(speed * 3.0, 1.0)
	var slide: Vector3 = m.get_shader_parameter("anim_slide")
	if slide != Vector3.ZERO:
		return v + slide * x
	var a: Vector3 = m.get_shader_parameter("anim_axis")
	var pivot := Transform3D(m.get_shader_parameter("anim_pivot") as Projection)
	var p := Transform3D(m.get_shader_parameter("anim_unpivot") as Projection) * v
	p = p * cos(x) + a.cross(p) * sin(x) + a * a.dot(p) * (1.0 - cos(x))
	return pivot * p


## How much the model shader has a timed glowing instance glow (anim_glow, a static model's).


static func _shader_glow(c: Color, clock: Vector2) -> float:
	var flags := floori(-c.b - 1.0)
	var dt := maxf((clock.y if floori(flags / 2.0) % 2 == 1 else clock.x) - c.r, 0.0)
	var goal := 1.0 if floori(flags / 4.0) % 2 == 1 else 0.0
	return goal + (c.a - goal) * exp(-dt / (AnimScript.GLOW_UP if goal > 0.5 else AnimScript.GLOW_DOWN))

## A lane's meta for a `bs` lm (12 integers): exit (ex, ey) and entry (nx, ny) in tiles, its middle
## halfway (a curve's middle is given).
