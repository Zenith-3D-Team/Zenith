extends "res://tests/ui_test_base.gd"
## UI test sections: combat_debug.

func _turrets() -> void:
	var layer := TurretLayer.new()
	add_child(layer)
	var head: ModelLibrary.AnimPart = null
	var laser_head: ModelLibrary.AnimPart = null
	for part: ModelLibrary.AnimPart in ModelLibrary.parts_for("gun-turret"):
		if part.kind == "turret_head":
			head = part
	for part: ModelLibrary.AnimPart in ModelLibrary.parts_for("laser-turret"):
		if part.kind == "turret_head":
			laser_head = part
	check(head != null and laser_head != null, "turrets: the gun and laser turret models have their heads")
	if head == null or laser_head == null:
		layer.queue_free()
		return
	var base := Transform3D(Basis.IDENTITY, Vector3(10, 0, 10))
	var dt := 1.0 / 60.0
	var step := func(seconds: float) -> void:
		for i in int(round(seconds * 60.0)):
			layer._process(dt)
			layer.head_transform(7, head, base, dt)
			layer.head_transform(8, laser_head, base, dt)
	var folded_top := (layer.head_transform(7, head, base, 0.0) * head.mesh.get_aabb().get_center()).y
	layer.handle_states({"t": "ts", "l": [[7, 250, 0, 0, 20 * 256, 10 * 256], [8, 0, 0, 0, 10 * 256, 0]]})
	step.call(0.1)
	var st = layer.state_of(7)
	check(st != null and st.fold > 0.2 and st.fold < 1.0, "turrets: a gun turret raises once it has a target (%s)" % [st.fold if st else -1])
	layer.handle_states({"t": "ts", "l": [[7, 250, 5, 0, 20 * 256, 10 * 256], [8, 0, 1, 0, 10 * 256, 0]]})
	step.call(0.12)
	check(st.fold == 1.0 and st.fired >= 1 and st.fired <= 3, "turrets: raised in about 12 ticks (preparing_speed 0.08), then fires (%d)" % st.fired)
	var top := (layer.head_transform(7, head, base, 0.0) * head.mesh.get_aabb().get_center()).y
	check(top > folded_top, "turrets: the raised head stands higher than the folded one")
	step.call(0.5)
	check(st.fired == 5, "turrets: five reported shots drawn, one per cooldown (6 ticks): %d" % st.fired)
	check(absf(st.yaw - 0.25) < 0.01, "turrets: the head turned east at rotation_speed (%.3f)" % st.yaw)
	layer.head_transform(7, head, base, 0.0)
	check(st.forward.distance_to(Vector3.RIGHT) < 0.1 and st.muzzle.x > base.origin.x + 0.4,
		"turrets: a head aimed east has its front and shots to the east (%s, muzzle %s)" % [st.forward, st.muzzle])
	# FUE5's head is modelled with its barrels to the west: it is brought round so yaw 0 is north.
	var gun_cfg: Dictionary = TurretLayer.TURRETS["gun-turret"]
	var front := TurretLayer.head_front(head)
	check(front == (Vector3.LEFT if _theirs_in_use("gun-turret") else Vector3.FORWARD), "turrets: FUE5's gun turret's front is to the west in its model (%s)" % front)
	var at_rest: Transform3D = layer._pose(head, 0.0, 1.0, gun_cfg, 100.0)
	var north := (at_rest.basis * front).normalized()
	var muzzle: Vector3 = at_rest * layer._muzzle_point(head, st) - head.pivot.origin
	check(north.distance_to(Vector3.FORWARD) < 0.001 and muzzle.z < -0.5 and absf(muzzle.x) < 0.2,
		"turrets: at yaw 0 the gun turret's barrels point north, shots leaving their ends (%s, muzzle %s)" % [north, muzzle])
	var kick: Vector3 = layer._pose(head, 0.0, 1.0, gun_cfg, 0.0).origin - at_rest.origin
	check(kick.z > 0.01 and absf(kick.x) < 0.001, "turrets: a shot kicks a head aimed north back to the south (%s)" % kick)
	var laser = layer.state_of(8)
	check(laser != null and laser.fired == 1 and laser.beam_kind == "laser" and laser.beam_left > 0.0,
		"turrets: the laser turret holds its beam after rising (preparing_speed 0.05)")
	step.call(2.0)
	check(st.fold == 0.0 and laser.fold == 0.0 and laser.beam_left <= 0.0, "turrets: both fold away once their targets are gone")
	layer.handle_projectiles({"t": "pj"})
	layer.handle_states({"t": "ts", "l": [[8, 0, 1, 0, 10 * 256, 0]]})
	step.call(0.5)
	check(laser.fired == 2 and laser.beam_left <= 0.0, "turrets: once the game's beams come (pj), the laser fires without drawing its own beam")
	# Gone from the world (mined, destroyed, out of the area) and not heard of for a while: let go.
	var fake := GDScript.new()
	fake.source_code = "extends Node\nvar entities := {}\n"
	fake.reload()
	var w: Node = fake.new()
	w.entities[8] = true
	layer.world = w
	step.call(TurretLayer.FORGET_AFTER + TurretLayer.FORGET_INTERVAL + 0.5)
	check(layer.state_of(7) == null and layer.state_of(8) != null, "turrets: a turret gone from the world is forgotten, one still there kept")
	layer.reset(true)
	check(layer.game_beams, "turrets: another surface keeps the game's beams")
	layer.reset()
	check(not layer.game_beams, "turrets: a new game waits for its own `pj` before leaving beams to it")
	w.free()
	layer.queue_free()


## anim.gd turns turrets further from the focus than its other parts (TURRET_RADIUS, RADIUS).


func _turrets_far() -> void:
	var world := WorldMirror.new()
	add_child(world)
	var layer := TurretLayer.new()
	add_child(layer)
	var fake := FakeCollectors.new()
	add_child(fake)
	world.animator.turrets = layer
	world.animator.collectors = fake
	var head := _part_of("gun-turret", "turret_head")
	var add_group := func(coord: Vector2i, unit: int, kind: int) -> void:
		var cv: ChunkView = world.chunks.get(coord)
		if cv == null:
			cv = ChunkView.new()
			cv.coord = coord
			world.chunks[coord] = cv
			world.add_child(cv)
		var group := _anim_group(head, unit, Transform3D(Basis(), Vector3(coord.x * 32.0 + 6.5, 0.0, coord.y * 32.0 + 6.5)))
		AnimScript.place(group, world.animator, world.working)
		group.kind = kind
		cv.anim_groups.append(group)
	# The focus is at the origin: chunk 2's nearest edge is 64 tiles off, chunk 4's 128.
	add_group.call(Vector2i(2, 0), 7101, AnimScript.KIND_TURRET)
	add_group.call(Vector2i(4, 0), 7102, AnimScript.KIND_TURRET)
	add_group.call(Vector2i(2, 0), 7103, AnimScript.KIND_COLLECTOR)
	add_group.call(Vector2i(0, 0), 7104, AnimScript.KIND_COLLECTOR)
	layer.handle_states({"t": "ts", "l": [[7101, 0, 0, 0], [7102, 0, 0, 0]]})
	layer.handle_states({"t": "ts", "l": [[7101, 250, 0, 0], [7102, 250, 0, 0]]})
	for i in 10:
		world.animator._process(1.0 / 60.0)
	check(layer.state_of(7101).yaw > 0.1, "a turret 64 tiles from the focus still turns (%.3f)" % layer.state_of(7101).yaw)
	check(layer.state_of(7102).yaw == 0.0, "a turret 128 tiles from the focus is left alone")
	check(fake.calls == 10, "other moving parts are still looked after only within 40 tiles (%d calls in 10 frames)" % fake.calls)
	world.queue_free()
	layer.queue_free()
	fake.queue_free()


## A flamethrower's lights: wide enough to reach the ground round it, one over where the stream
## lands, neither casting shadows, and the landing's gone when the flame stops.


class FakeCollectors extends Node:
	var calls := 0

	func part_transform(_unit: int, _part, _base: Transform3D, _delta: float, _custom: Color) -> Transform3D:
		calls += 1
		return Transform3D.IDENTITY


func _turret_lights() -> void:
	var layer := TurretLayer.new()
	add_child(layer)
	var st = layer._state(7201)
	st.cfg = TurretLayer.TURRETS["flamethrower-turret"]
	st.target = Vector3(20.0, 0.45, 10.0)
	st.target_seen = layer._clock
	st.flame_left = 0.2
	layer._update_effects(st, 1.0 / 60.0)
	var landing: OmniLight3D = st.flame_light
	check(landing != null and landing.visible and not landing.shadow_enabled and landing.omni_range >= 6.0
		and Vector2(landing.global_position.x, landing.global_position.z).distance_to(Vector2(20.0, 10.0)) < 0.01,
		"a flame lights the ground where its stream lands")
	check(st.light != null and st.light.omni_range >= 7.0 and not st.light.shadow_enabled, "a flame's nozzle light reaches the ground round the turret")
	layer._update_effects(st, 1.0)
	layer._update_effects(st, 1.0 / 60.0)
	check(not landing.visible, "the flame's landing light goes out when the flame stops")
	layer.reset()
	layer.queue_free()


## The asteroid chunks collectors.gd reads (ui_model.gd's).


class WormWorld extends Node:
	class Rec:
		var pos := Vector2.ZERO
		var proto_id := 1
		var unit := 0

	class Chunk:
		var entities := {}

	class Protos:
		func entity(_id: int) -> ProtoDB.EntityProto:
			var e := ProtoDB.EntityProto.new()
			e.type = "turret"
			return e

	var chunks := {}
	var protos := Protos.new()

	func add_worm(at: Vector2, unit: int) -> void:
		var r := Rec.new()
		r.pos = at
		r.unit = unit
		var c := Chunk.new()
		c.entities[unit] = r
		chunks[Vector2i(floori(at.x / 32.0), floori(at.y / 32.0))] = c


class RideRig:
	var target
	var global_position := Vector3.ZERO

	func cinematic(_pitch: float, _distance: float) -> void:
		pass

	func cinematic_end() -> void:
		pass


## The owner's client log, loading an old autosave of a test map: "Out of bounds get index '-1'" at
## rockets.gd drive() from ride.gd's _rocket, eight times while the save loaded. The ride's `me` came
## before the silo's chunk, so no launch could start there and drive() read the last launch of none
## (or, with another silo's launch going, drove that one). drive() now says it couldn't and ride.gd
## asks again each frame: the ridden rocket comes once its silo is in the world. Fails on the old code
## (the other silo's launch taken).


func _ride_before_silo() -> void:
	var layer = RocketsScript.new()
	layer.model = ChunkModel.new()
	add_child(layer)
	var silo_movers := SiloMovers.new()
	silo_movers.world = SiloWorld.new()
	layer.movers = silo_movers
	silo_movers.world.silo = true
	layer._on_launch(1, Vector2(200, 200), "")  # another silo's launch, far away
	var other: Dictionary = layer._launches[0]
	silo_movers.world.silo = false  # the ridden rocket's silo isn't in the world yet
	var ride := Ride.new()
	ride.rockets = layer
	ride.rig = RideRig.new()
	add_child(ride)
	for climbed in [30, 60]:  # the pod's first height is its rest in the rocket: the second is 30 up
		ride.handle_me({"t": "me", "u": 7, "x": 2560, "y": 2560 - climbed * 256, "pod": 50, "ps": "ascending", "up": 1, "gx": 2560, "gy": 2560, "hp": 250, "q": 0})
	for i in 8:
		ride._process(1.0 / 60.0)
	check(ride.riding() and layer._launches.size() == 1 and not bool(other.get("driven", false)),
		"a ride loaded before its silo's chunk waits for it: no launch read past the list, another silo's launch not taken (%d launches)" % layer._launches.size())
	silo_movers.world.silo = true  # the chunk comes
	ride._process(1.0 / 60.0)
	var mine: Dictionary = layer._launch_at(Vector2(10, 10))
	check(layer._launches.size() == 2 and bool(mine.get("driven", false)) and not bool(other.get("driven", false)) and float(mine.get("h", 0.0)) > 0.0,
		"once the silo is there the ridden rocket starts from it and follows the game's height (%.1f)" % float(mine.get("h", 0.0)))
	ride.queue_free()
	layer.queue_free()


## Where a line of belts begins and ends: what feeds a belt from behind and what carries its line on.


func _belt_end_rules() -> void:
	check(WorldMirror.belt_feeds(0, "transport-belt", 0, "") and not WorldMirror.belt_feeds(0, "transport-belt", 4, ""),
		"belt ends: a belt behind going the same way feeds it, one going across doesn't")
	check(WorldMirror.belt_feeds(0, "underground-belt", 0, "o") and not WorldMirror.belt_feeds(0, "underground-belt", 0, "i"),
		"belt ends: an underground's exit feeds what is in front of it, an entrance doesn't")
	check(WorldMirror.belt_continues(0, "transport-belt", 0, "") and not WorldMirror.belt_continues(0, "transport-belt", 8, ""),
		"belt ends: a belt going on the same way carries the line on, one head-on doesn't")
	# Side-loading (owner, with Vasillo's belts: "the belts going into other belts should use the front part too").
	check(not WorldMirror.belt_continues(0, "transport-belt", 4, "", "s") and not WorldMirror.belt_continues(0, "transport-belt", 12, "", "s"),
		"belt ends: a belt facing into either side of a straight belt side-loads: its line ends there")
	check(WorldMirror.belt_continues(4, "transport-belt", 0, "", "l") and WorldMirror.belt_continues(12, "transport-belt", 0, "", "r"),
		"belt ends: a belt feeding a curve it makes (a left curve from the west, a right one from the east) goes on")
	check(not WorldMirror.belt_continues(12, "transport-belt", 0, "", "l") and not WorldMirror.belt_continues(4, "transport-belt", 0, "", "r"),
		"belt ends: a belt facing into a curve's other side side-loads: its line ends there")
	check(WorldMirror.belt_continues(0, "underground-belt", 0, "i") and not WorldMirror.belt_continues(0, "underground-belt", 0, "o")
		and not WorldMirror.belt_continues(0, "underground-belt", 4, "i") and not WorldMirror.belt_continues(0, "underground-belt", 12, "o"),
		"belt ends: an underground carries a line on at its entrance's back, not into an exit's back or from the side (side-loading)")
	check(WorldMirror.belt_continues(0, "splitter", 0, "") and not WorldMirror.belt_continues(0, "splitter", 4, ""),
		"belt ends: a splitter carries a line on only from behind")


## A modeller's belt ends: a lone straight belt gets both pieces in its chunk, at its tail and head in
## all four directions (they are authored running east); two belts in a line only the outer ends.


func _belt_line_ends() -> void:
	var names := {"transport-belt-start": "iron-chest", "transport-belt-end": "steel-chest"}
	for n: String in names:
		ModelLibrary._sources[n] = ModelLibrary.GLTF_SOURCE + _own_glb(names[n])
	var start := ModelLibrary.mesh_for("transport-belt-start")
	var end := ModelLibrary.mesh_for("transport-belt-end")
	ModelLibrary.mesh_for("transport-belt")
	var w := WorldMirror.new()
	add_child(w)
	w.protos = ProtoDB.new()
	w.protos.add_entities([[1, "transport-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1]])
	var c := Vector2i(0, 0)
	var cv := ChunkView.new()
	cv.coord = c
	w.chunks[c] = cv
	w.add_child(cv)
	var unit := 0
	for dir in [0, 4, 8, 12]:
		unit += 1
		cv.clear_entities()
		w.entities.clear()
		w._belts.clear()
		w._add([unit, 1, 10 * 256 + 128, 10 * 256 + 128, dir, {"s": "s"}])
		var rec = w.entities[unit]
		cv.build_entities(w.protos, {}, null)
		var step: Vector2i = WorldMirror.PIPE_STEPS[dir >> 2]
		var ahead := Vector3(step.x, 0.0, step.y)
		var centre := Vector3(10.5, 0.0, 10.5)
		# (Headless, a MultiMesh filled through its buffer doesn't give its transforms back.)
		var placed: Transform3D = cv._model_transform(w.protos.entity(1), rec) * ModelLibrary.BELT_END_FACING
		check(rec.belt_ends == 3 and not rec.extra.has("be"), "a lone belt's ends are on its record, not in `extra` (read on a worker): %d" % rec.belt_ends)
		check(cv._nodes.has(start) and cv._nodes.has(end), "a lone belt (dir %d) has both end pieces in its chunk" % dir)
		check((placed * Vector3(-0.56, 0, 0)).is_equal_approx(centre - ahead * 0.56) and (placed * Vector3(0.56, 0, 0)).is_equal_approx(centre + ahead * 0.56),
			"belt ends land at the belt's tail and head (dir %d): %s, %s" % [dir, placed * Vector3(-0.56, 0, 0), placed * Vector3(0.56, 0, 0)])
	cv.clear_entities()
	w.entities.clear()
	w._belts.clear()
	w._add([11, 1, 10 * 256 + 128, 10 * 256 + 128, 4, {"s": "s"}])
	w._add([12, 1, 11 * 256 + 128, 10 * 256 + 128, 4, {"s": "s"}])
	check(w.entities[11].belt_ends == 1 and w.entities[12].belt_ends == 2, "two belts in a line: the first only begins, the second only ends: %d, %d" % [w.entities[11].belt_ends, w.entities[12].belt_ends])
	_belt_line_ends_splitters_undergrounds(w, cv, start, end)
	_belt_side_load_ends(w, cv, end)
	w.queue_free()
	for n: String in names:
		ModelLibrary._sources.erase(n)
		ModelLibrary._cache.erase(n)
		ModelLibrary._parts.erase(n)


## The end pieces on splitters and undergrounds (owner and Vasillo: a lone splitter's belts stopped flat):
## each half of a splitter is a line's start or end of its own, an underground's open ends are, and the
## pieces sit on the half's or end's own tile facing the way items go (an exit too, though its model is
## turned round).


func _belt_line_ends_splitters_undergrounds(w, cv, start: Mesh, end: Mesh) -> void:
	w.protos.add_entities([[2, "splitter", "splitter", -0.9, -0.4, 0.9, 0.4, 200, 180, 0, 2, 1],
		[3, "underground-belt", "underground-belt", -0.4, -0.4, 0.4, 0.4, 200, 180, 0, 1, 1],
		[4, "fast-splitter", "splitter", -0.9, -0.4, 0.9, 0.4, 200, 180, 0, 2, 1]])
	for n in ["splitter", "underground-belt-input", "underground-belt-output"]:
		ModelLibrary.mesh_for(n)
	var reset := func() -> void:
		cv.clear_entities()
		w.entities.clear()
		w._belts.clear()
	# Ends of a piece placed by belt_end_places: a start's tail, an end's head (they are authored running east).
	var tips := func(places: Array) -> Array:
		var out := []
		for p: Array in places:
			var at: Transform3D = p[1]
			out.append([p[0], at * Vector3(-0.56 if str(p[0]).ends_with("-start") else 0.56, 0.0, 0.0)])
		return out
	reset.call()
	# A lone splitter going north, on tiles (9, 10) and (10, 10).
	w._add([21, 2, 10 * 256, 10 * 256 + 128, 0, {}])
	var sp = w.entities[21]
	check(sp.belt_ends == 15, "a lone splitter: both halves begin and end (4 pieces): %d" % sp.belt_ends)
	var got: Array = tips.call(ModelLibrary.belt_end_places("splitter", "splitter", 0, sp.pos, sp.belt_ends))
	var want := [["transport-belt-start", Vector3(9.5, 0, 11.06)], ["transport-belt-end", Vector3(9.5, 0, 9.94)],
		["transport-belt-start", Vector3(10.5, 0, 11.06)], ["transport-belt-end", Vector3(10.5, 0, 9.94)]]
	var same: bool = got.size() == want.size()
	for i in mini(got.size(), want.size()):
		same = same and got[i][0] == want[i][0] and (got[i][1] as Vector3).is_equal_approx(want[i][1])
	check(same, "a lone splitter's pieces sit at each half's back and front: %s" % [got])
	cv.build_entities(w.protos, {}, null)
	check(cv._nodes.has(start) and cv._nodes.has(end) and cv._nodes[start].multimesh.instance_count == 2 and cv._nodes[end].multimesh.instance_count == 2,
		"a lone splitter has two start and two end pieces in its chunk")
	var fast: Array = ModelLibrary.belt_end_places("fast-splitter", "splitter", 4, Vector2(10.5, 10.0), 15)
	check(fast.size() == 4 and fast[0][0] == "fast-transport-belt-start" and ModelLibrary.belt_end_family("turbo-underground-belt", "underground-belt") == "turbo-transport-belt",
		"a faster splitter or underground wears its tier's belt pieces: %s" % [fast])
	# Fed on its left half only: that half doesn't begin, and the belt feeding it doesn't end.
	w._add([22, 1, 9 * 256 + 128, 11 * 256 + 128, 0, {"s": "s"}])
	check(sp.belt_ends == 14 and w.entities[22].belt_ends == 1, "a splitter fed on one half: that half's start goes, the belt's end too: %d, %d" % [sp.belt_ends, w.entities[22].belt_ends])
	# Taken from on its right half by a belt going on north, on its left by a belt it bends east (a right
	# curve fed from the south); then mined, the halves end again.
	w._add([23, 1, 10 * 256 + 128, 9 * 256 + 128, 0, {"s": "s"}])
	w._add([24, 1, 9 * 256 + 128, 9 * 256 + 128, 4, {"s": "r"}])
	check(sp.belt_ends == 4, "a splitter taken from on both halves and fed on one: only the unfed half begins: %d" % sp.belt_ends)
	# The belt across in front of its left half straight (fed from behind too): that half side-loads it and ends.
	w._add([24, 1, 9 * 256 + 128, 9 * 256 + 128, 4, {"s": "s"}])
	check(sp.belt_ends == 6, "a splitter's half side-loading onto a straight belt ends there: %d" % sp.belt_ends)
	w._remove(23)
	w._remove(24)
	check(sp.belt_ends == 14, "belts in front of a splitter mined: its halves end again: %d" % sp.belt_ends)
	# A belt in front facing the splitter head-on takes nothing.
	w._add([25, 1, 10 * 256 + 128, 9 * 256 + 128, 8, {"s": "s"}])
	check(sp.belt_ends == 14, "a belt facing a splitter head-on takes nothing from it: %d" % sp.belt_ends)
	# A lone underground pair going north: the entrance begins at its back, the exit ends at its front.
	reset.call()
	w._add([31, 3, 20 * 256 + 128, 10 * 256 + 128, 0, {"u": "i"}])
	w._add([32, 3, 20 * 256 + 128, 7 * 256 + 128, 0, {"u": "o"}])
	var entrance = w.entities[31]
	var exit = w.entities[32]
	check(entrance.belt_ends == 1 and exit.belt_ends == 2, "a lone underground pair: the entrance only begins, the exit only ends: %d, %d" % [entrance.belt_ends, exit.belt_ends])
	var ug: Array = tips.call(ModelLibrary.belt_end_places("underground-belt", "underground-belt", 0, entrance.pos, entrance.belt_ends)
		+ ModelLibrary.belt_end_places("underground-belt", "underground-belt", 0, exit.pos, exit.belt_ends))
	check(ug.size() == 2 and ug[0][0] == "transport-belt-start" and (ug[0][1] as Vector3).is_equal_approx(Vector3(20.5, 0, 11.06))
		and ug[1][0] == "transport-belt-end" and (ug[1][1] as Vector3).is_equal_approx(Vector3(20.5, 0, 6.94)),
		"an underground's pieces sit on its open ends, the exit's ahead though its model is turned round: %s" % [ug])
	cv.build_entities(w.protos, {}, null)
	check(cv._nodes.has(start) and cv._nodes.has(end), "a lone underground pair has its start and end pieces in its chunk")
	# Fed by a belt behind the entrance: no start piece; an exit into a belt going on: no end piece.
	w._add([33, 1, 20 * 256 + 128, 11 * 256 + 128, 0, {"s": "s"}])
	w._add([34, 1, 20 * 256 + 128, 6 * 256 + 128, 0, {"s": "s"}])
	check(entrance.belt_ends == 0 and exit.belt_ends == 0 and w.entities[33].belt_ends == 1 and w.entities[34].belt_ends == 2,
		"an underground fed by a belt and feeding one: no pieces on it, the belts' outer ends only: %d, %d, %d, %d"
		% [entrance.belt_ends, exit.belt_ends, w.entities[33].belt_ends, w.entities[34].belt_ends])
	# A ghost belt behind feeds nothing.
	w._remove(33)
	w._add([35, 1, 20 * 256 + 128, 11 * 256 + 128, 0, {"s": "s", "gh": 1}])
	check(entrance.belt_ends == 1, "a ghost belt behind an underground doesn't feed it: %d" % entrance.belt_ends)
	# A piece's moving part the model already has in that place (a modeller's splitter's rollers) is left out.
	var roller := ModelLibrary.AnimPart.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.84, 0.23, 0.23)
	roller.mesh = box
	var theirs := ModelLibrary.AnimPart.new()
	theirs.mesh = box
	check(ModelLibrary.part_doubled(roller, Transform3D.IDENTITY, [theirs])
		and not ModelLibrary.part_doubled(roller, Transform3D(Basis(), Vector3(0, 0, 0.5)), [theirs])
		and not ModelLibrary.part_doubled(roller, Transform3D(Basis(Vector3.UP, PI / 2.0), Vector3.ZERO), [theirs]),
		"a piece's roller is left out only where the model has the same roller")
	reset.call()


## A belt facing into another's side (owner, with Vasillo's belts: "the belts going into other belts should
## use the front part too"): side-loading onto a straight belt, a curve fed from its other side or an
## underground, its line ends there and gets its end piece, where Factorio draws its ending sprite; feeding a
## curve it makes (the bridge's `upd` bends the belt in front), it goes on without one.


func _belt_side_load_ends(w, cv, end: Mesh) -> void:
	var reset := func() -> void:
		cv.clear_entities()
		w.entities.clear()
		w._belts.clear()
	var ends := func(unit: int) -> int:
		return w.entities[unit].belt_ends
	reset.call()
	# A straight belt going north on (10, 10), fed from behind, side-loaded from the west and from the east.
	w._add([41, 1, 10 * 256 + 128, 11 * 256 + 128, 0, {"s": "s"}])
	w._add([42, 1, 10 * 256 + 128, 10 * 256 + 128, 0, {"s": "s"}])
	w._add([43, 1, 9 * 256 + 128, 10 * 256 + 128, 4, {"s": "s"}])
	w._add([44, 1, 11 * 256 + 128, 10 * 256 + 128, 12, {"s": "s"}])
	check(ends.call(43) == 3 and ends.call(44) == 3,
		"belts side-loading onto a straight belt from the west and the east end there: %d, %d" % [ends.call(43), ends.call(44)])
	check(ends.call(41) == 1 and ends.call(42) == 2, "the straight run keeps its own start and end: %d, %d" % [ends.call(41), ends.call(42)])
	cv.build_entities(w.protos, {}, null)
	var placed: int = cv._nodes[end].multimesh.instance_count if cv._nodes.has(end) else 0
	check(placed == 3, "the side-loading belts' end pieces are in the chunk, with the run's own: %d" % placed)
	# A lone belt fed from its side alone bends (the bridge's `upd`): the belt feeding it goes on.
	reset.call()
	w._add([45, 1, 10 * 256 + 128, 10 * 256 + 128, 0, {"s": "s"}])
	w._add([46, 1, 9 * 256 + 128, 10 * 256 + 128, 4, {"s": "s"}])
	check(ends.call(46) == 3, "a belt facing into a straight belt's side, before it bends: an end piece: %d" % ends.call(46))
	w._add([45, 1, 10 * 256 + 128, 10 * 256 + 128, 0, {"s": "l"}])
	check(ends.call(46) == 1, "the belt in front bent into a left curve fed by it: no end piece: %d" % ends.call(46))
	w._add([47, 1, 20 * 256 + 128, 10 * 256 + 128, 0, {"s": "r"}])
	w._add([48, 1, 21 * 256 + 128, 10 * 256 + 128, 12, {"s": "s"}])
	check(ends.call(48) == 1, "a belt feeding a right curve it makes, from the east: no end piece: %d" % ends.call(48))
	# Into the left curve's other side: a side-load, an end piece; and once that makes the belt straight
	# again (fed from both sides), both side-load it and end.
	w._add([49, 1, 11 * 256 + 128, 10 * 256 + 128, 12, {"s": "s"}])
	check(ends.call(49) == 3 and ends.call(46) == 1, "a belt facing into a curve's other side ends there, the curve's feeder doesn't: %d, %d" % [ends.call(49), ends.call(46)])
	w._add([45, 1, 10 * 256 + 128, 10 * 256 + 128, 0, {"s": "s"}])
	check(ends.call(49) == 3 and ends.call(46) == 3, "fed from both sides the belt goes straight: both side-load it and end: %d, %d" % [ends.call(49), ends.call(46)])
	# Underground belts side-loaded, at an entrance and at an exit; into an entrance's back the line goes on.
	reset.call()
	w._add([51, 3, 10 * 256 + 128, 10 * 256 + 128, 0, {"u": "i"}])
	w._add([52, 1, 9 * 256 + 128, 10 * 256 + 128, 4, {"s": "s"}])
	w._add([53, 3, 20 * 256 + 128, 10 * 256 + 128, 0, {"u": "o"}])
	w._add([54, 1, 21 * 256 + 128, 10 * 256 + 128, 12, {"s": "s"}])
	w._add([55, 1, 10 * 256 + 128, 11 * 256 + 128, 0, {"s": "s"}])
	check(ends.call(52) == 3 and ends.call(54) == 3,
		"belts side-loading onto an underground's entrance and exit end there: %d, %d" % [ends.call(52), ends.call(54)])
	check(ends.call(55) == 1 and ends.call(51) == 0, "a belt into an entrance's back goes on, the entrance fed: %d, %d" % [ends.call(55), ends.call(51)])
	reset.call()


## F5: asteroid chunks drifting past a platform (rockets.gd) keep their own tumble and place when
## the next update (every 10 ticks) comes, instead of snapping.


func _asteroid_chunks() -> void:
	var cm := ChunkModel.new()
	var layer = load("res://scripts/world/rockets.gd").new()
	layer.model = cm
	add_child(layer)
	cm.set_chunks([{"name": "metallic-asteroid-chunk", "position": Vector2(10, 0), "velocity": Vector2(3, 0)}])
	layer._place_chunks()
	var mmi: MultiMeshInstance3D = layer._chunk_meshes["metallic-asteroid-chunk"]
	var before: Transform3D = mmi.multimesh.get_instance_transform(0)
	var phase_before := float(cm.asteroid_chunks[0]["phase"])
	# The game's next update has it a little further on than the client's estimate.
	cm.set_chunks([{"name": "metallic-asteroid-chunk", "position": Vector2(10.4, 0.1), "velocity": Vector2(3, 0)}])
	layer._place_chunks()
	var after: Transform3D = mmi.multimesh.get_instance_transform(0)
	check(after.origin.distance_to(before.origin) < 0.05 and after.basis.x.distance_to(before.basis.x) < 0.05,
		"an asteroid chunk's next update keeps its place and tumble (F5): moved %.3f tiles" % after.origin.distance_to(before.origin))
	# A new chunk's phase comes from its place, so an unmatched one at 10.4 would get another.
	check(is_equal_approx(float(cm.asteroid_chunks[0]["phase"]), phase_before) and cm.asteroid_chunks[0].has("offset"),
		"the chunk carries its matched phase and the gap to ease off: %.3f for %.3f" % [float(cm.asteroid_chunks[0]["phase"]), phase_before])
	# G2: a chunk whose sent movement is wrong (here none, as on a travelling platform) moves on by
	# how far it really went, so later updates land where it is drawn (each 1/6 s apart).
	cm.set_chunks([{"name": "carbonic-asteroid-chunk", "position": Vector2(20, 0), "velocity": Vector2.ZERO}])
	var offsets: Array = []
	for i in range(1, 4):
		layer._chunks_msec = Time.get_ticks_msec() - 167
		cm.set_chunks([{"name": "carbonic-asteroid-chunk", "position": Vector2(20 + 0.5 * i, 0), "velocity": Vector2.ZERO}])
		offsets.append((cm.asteroid_chunks[0]["offset"] as Vector2).length())
	check(offsets[0] > 0.4 and offsets[2] < 0.1, "asteroid chunks move on by their measured speed, not the sent one: gaps %s (G2)" % [offsets])
	# H1, H6, H11: launches only on the surface shown; a waiting rocket stands down in its silo; robots fly high.
	layer.surface = "nauvis"
	layer._on_launch(1, Vector2(5, 5), "platform-1")
	var launches_elsewhere: int = layer._launches.size()
	layer._on_launch(1, Vector2(5, 5), "nauvis")
	check(launches_elsewhere == 0 and layer._launches.size() == 1 and Visuals.flying_height("rocket-silo-rocket") < -10.0
		and Visuals.flying_height("logistic-robot") >= 2.0,
		"a launch on another surface isn't drawn here; the waiting rocket sits in its shaft; robots fly above the machines (H1, H6, H11)")
	# A rocket that arrives before its silo's chunk is hidden, and shown again once the silo is there.
	var silo_movers := SiloMovers.new()
	silo_movers.world = SiloWorld.new()
	var waiting := Node3D.new()
	waiting.position = Vector3(50, 0, 50)
	silo_movers.nodes[910] = waiting
	layer.movers = silo_movers
	layer._hide_flying_rockets()
	var hidden_first := not waiting.visible
	silo_movers.world.silo = true
	silo_movers.fogged = true
	layer._rocket_silo.clear()
	layer._hide_flying_rockets()
	var hidden_in_fog := not waiting.visible
	silo_movers.fogged = false
	layer._hide_flying_rockets()
	check(hidden_first and hidden_in_fog and waiting.visible, "a rocket seen before its silo's chunk comes back when the silo arrives, not under the fog")
	waiting.position = Vector3(50, 0, 40)
	layer._hide_flying_rockets()
	check(not waiting.visible, "a rocket that has moved off its silo stays hidden")
	# H16: a silo's rocket follows its `st`: down the shaft while the doors open, rising, then waiting.
	var rising := Node3D.new()
	rising.position = Vector3(60, 0, 60)
	silo_movers.nodes[911] = rising
	silo_movers.world.working[77] = 2
	layer._rocket_silo.clear()
	layer._hide_flying_rockets()
	layer._update_silos(0.1)
	layer._hide_flying_rockets()
	var deep := rising.position.y
	silo_movers.world.working[77] = 3
	layer._update_silos(0.1)
	layer._update_silos(3.5)
	layer._hide_flying_rockets()
	var half := rising.position.y
	layer._update_silos(4.0)
	layer._hide_flying_rockets()
	check(is_equal_approx(deep, -Visuals.ROCKET_SINK - RocketsScript.RISE_DEPTH) and half > deep + 2.0 and half < -Visuals.ROCKET_SINK - 2.0
		and is_equal_approx(rising.position.y, -Visuals.ROCKET_SINK), "a silo's rocket waits down the shaft while the doors open, then rises over 7 s (H16): %.1f, %.1f, %.1f" % [deep, half, rising.position.y])
	# The launch: engines over 5.5 s, held in the shaft until it lets go, then Factorio's climb.
	check(RocketsScript.ignition_at(0.0) == 0.0 and is_equal_approx(RocketsScript.ignition_at(RocketsScript.IGNITE_AFTER + RocketsScript.ENGINE_START), 1.0)
		and absf(RocketsScript.climb_at(5.0) - 7.0) < 0.5 and absf(RocketsScript.climb_at(20.0) - 200.0) < 15.0, "a rocket's engines take 5.5 s to start and it climbs 7 tiles in 5 s, 200 in 20 (H16)")
	silo_movers.nodes.clear()
	layer.movers = null
	for l in layer._launches:
		(l["node"] as Node3D).queue_free()
		(l["light"] as Node).queue_free()
	layer._launches.clear()
	layer._on_launch(1, Vector2(70, 70), "nauvis")
	var anim_doors = AnimScript.new()
	anim_doors.world = silo_movers.world
	anim_doors.rockets = layer
	silo_movers.world.working[77] = 0
	layer._update_launches(1.0)
	var held_open: bool = anim_doors._silo_open(77, Vector2(70, 70), false)
	var on_pad: float = (layer._launches[0]["node"] as Node3D).position.y
	layer._update_launches(RocketsScript.LIFT_AFTER - 1.5)
	var still: float = (layer._launches[0]["node"] as Node3D).position.y
	for i in 20:
		layer._update_launches(1.0)
	var doors_free: bool = not layer.in_shaft(Vector2(70, 70)) and not anim_doors._silo_open(77, Vector2(70, 70), false)
	check(held_open and is_equal_approx(on_pad, -Visuals.ROCKET_SINK) and absf(still - on_pad) < 0.01 and doors_free,
		"a launch holds its silo's doors open until it is out of the shaft, and stays put until the engines have started (H16)")
	silo_movers.world.working[77] = 2
	var opening: bool = anim_doors._silo_open(77, Vector2(5, 5), false)
	silo_movers.world.working[77] = 5
	var closing: bool = anim_doors._silo_open(77, Vector2(5, 5), true)
	silo_movers.world.working[77] = 0
	check(opening and not closing and anim_doors._silo_open(77, Vector2(5, 5), true), "a silo's doors follow its `st`, or a rocket standing there on a bridge that doesn't say (H16)")
	anim_doors.free()
	rising.free()
	layer.movers = silo_movers
	# Silos on other planets stand at their own places: a launch with no silo here isn't drawn.
	var launches_before: int = layer._launches.size()
	silo_movers.world.silo = false
	layer._on_launch(2, Vector2(90, 90), "")
	var without_silo: int = layer._launches.size()
	silo_movers.world.silo = true
	layer._on_launch(2, Vector2(90, 90), "")
	check(without_silo == launches_before and layer._launches.size() == launches_before + 1, "a launch is drawn only out of a silo the world has")
	waiting.free()
	silo_movers.world.free()
	layer.movers = null
	layer.queue_free()


## Asteroid collectors' arms (collectors.gd, F3) from `acol` and the chunks (`ach`): the head flies
## at a chunk in the catch circle at the arm's speed, takes it and pulls it in; the chain strings
## out behind it; filters and power hold it; a chunk the game says was caught draws the arm there.


func _collectors() -> void:
	var parts := {}
	for part: ModelLibrary.AnimPart in ModelLibrary.parts_for("asteroid-collector"):
		parts[part.kind] = part
	var links := parts.keys().filter(func(k: String) -> bool: return k.begins_with(CollectorLayer.LINK_PREFIX))
	check(parts.has("reach_collector_head") and parts.has("reach_collector_claw_l") and parts.has("reach_collector_claw_r")
		and links.size() == CollectorLayer.LINKS, "collectors: the model's arm has a head, two fingers and %d links (%d)" % [CollectorLayer.LINKS, links.size()])
	if not parts.has("reach_collector_head"):
		return
	var cm := ChunkModel.new()
	var layer := CollectorLayer.new()
	layer.model = cm
	add_child(layer)
	var base := Transform3D(Basis.IDENTITY, Vector3(10, 0, 20))  # facing north: the circle's centre is at (10, 15)
	var dt := 1.0 / 60.0
	var run := func(seconds: float) -> void:
		for i in int(round(seconds * 60.0)):
			layer._process(dt)
			layer.advance(5, base, dt)
	layer.handle({"t": "acol", "l": [[5, 1, 200, 1, []]]})
	var chunk := {"name": "metallic-asteroid-chunk", "position": Vector2(10, 14), "velocity": Vector2.ZERO}
	cm.set_chunks([chunk])
	var rest := base * CollectorLayer.HEAD_REST
	var far := rest.distance_to(Vector3(10, CollectorLayer.CHUNK_HEIGHT, 14))
	run.call(0.2)
	var head := layer.head_of(5)
	check(layer.arm_state(5)[0] == "reach" and absf(head.distance_to(rest) - 12.0 * 0.2) < 0.15,
		"collectors: the head flies at the chunk at the arm's speed, 0.2 tiles a tick (%.2f tiles in 0.2 s)" % head.distance_to(rest))
	var link_a: ModelLibrary.AnimPart = parts[CollectorLayer.LINK_PREFIX + "a"]
	var link_x: ModelLibrary.AnimPart = parts[CollectorLayer.LINK_PREFIX + "x"]
	var a_at := base * (layer.part_transform(5, link_a, base, 0.0) * link_a.pivot.origin)
	var x_xf: Transform3D = layer.part_transform(5, link_x, base, 0.0)
	check(a_at.distance_to(head) < 0.6 and x_xf == Transform3D.IDENTITY,
		"collectors: the first link follows just behind the head, the last stays stowed on a short reach")
	run.call((far - CollectorLayer.HEAD_RADIUS) / 12.0 - 0.2 + 0.05)
	check(layer.arm_state(5) == ["back", "metallic-asteroid-chunk"] and chunk.get("held", false),
		"collectors: the head takes the chunk when it reaches it (%.2f s for %.1f tiles) and pulls it in" % [(far - 0.6) / 12.0, far])
	run.call(far / 12.0 + 0.1)
	check(layer.arm_state(5) == ["idle", ""] and layer.head_of(5).distance_to(rest) < 0.01,
		"collectors: the arm is back at rest and the chunk dropped in")
	cm.set_chunks([])
	# A filter the chunk doesn't pass, and no power: the arm stays put.
	layer.handle({"t": "acol", "l": [[5, 1, 200, 1, ["oxide-asteroid-chunk"]]]})
	cm.set_chunks([{"name": "metallic-asteroid-chunk", "position": Vector2(12, 12), "velocity": Vector2.ZERO}])
	run.call(0.3)
	var filtered: String = layer.arm_state(5)[0]
	layer.handle({"t": "acol", "l": [[5, 1, 200, 0, []]]})
	run.call(0.3)
	check(filtered == "idle" and layer.arm_state(5)[0] == "idle", "collectors: a chunk the filters leave out, or no power, leaves the arm at rest")
	# The game says the collector caught a chunk the arm wasn't after: it reaches there and back.
	layer.handle({"t": "acol", "l": [[5, 1, 200, 1, []]]})
	cm.set_chunks([])
	layer.handle({"t": "acol", "g": [[5, "carbonic-asteroid-chunk", 7 * 256, 11 * 256]]})
	run.call(0.1)
	var st := layer.arm_state(5)
	run.call(1.2)
	check(st[0] == "reach" and (layer.arm_state(5) == ["back", "carbonic-asteroid-chunk"] or layer.arm_state(5) == ["idle", ""]),
		"collectors: g (a chunk the game caught) sends the arm there; it comes back with it (%s, then %s)" % [st, layer.arm_state(5)])
	# Better quality, more arms: the second is drawn by the layer itself.
	layer.handle({"t": "acol", "l": [[5, 2, 250, 1, []]]})
	cm.set_chunks([{"name": "metallic-asteroid-chunk", "position": Vector2(8, 13), "velocity": Vector2.ZERO},
		{"name": "oxide-asteroid-chunk", "position": Vector2(13, 13), "velocity": Vector2.ZERO}])
	run.call(0.2)
	check(layer.arm_state(5, 0)[0] == "reach" and layer.arm_state(5, 1)[0] == "reach"
		and layer.head_of(5, 0).distance_to(layer.head_of(5, 1)) > 1.0, "collectors: two arms go for two chunks at once")
	# G10: switched off (2), arms reaching out turn back and fold home; held (0) they'd stay out.
	layer.handle({"t": "acol", "l": [[5, 2, 250, 2, []]]})
	run.call(2.0)
	check(layer.arm_state(5, 0)[0] == "idle" and layer.arm_state(5, 1)[0] == "idle" and layer.head_of(5, 0).distance_to(rest) < 0.01
		and layer.head_of(5, 1).distance_to(rest) < 0.01, "collectors: switched off, the arms fold back home (G10)")
	layer.queue_free()


## fx.gd follows movers for their sounds (engines, biters) from the same `mv` as movers.gd, which
## the bridge delta-codes (z = 1) for every client that says z in its hello.
## Fulgora's strikes (`lt`, B-roll filming: 180 bolts near the camera and none drawn): fx.gd draws a
## bolt from the sky down to each, a caught one to the rod's tip, forked, gone after the prototype's
## effect_duration.


func _lightning() -> void:
	var fx := FxScript.new()
	fx.handle({"t": "lt", "l": [[10 * 256, 20 * 256, 0], [30 * 256, 5 * 256, 1]]})
	var bolts: Array = fx.lightning.bolts
	var main: PackedVector3Array = bolts[0].paths[0] if bolts.size() > 0 else PackedVector3Array()
	check(bolts.size() == 2 and main.size() == 33 and main[-1] == Vector3(10, 0, 20) and main[0].y > 25.0
		and bolts[1].paths[0][-1] == Vector3(30, 3, 5) and bolts[0].paths.size() >= 2,
		"lt: a forked bolt from the sky to each strike, a caught one to the rod's tip: %d bolts, %d points" % [bolts.size(), main.size()])
	fx.lightning._process(0.02)
	check(fx.lightning._mesh.get_surface_count() == 1, "lt: the bolts are drawn")
	fx.lightning._process(0.6)
	check(fx.lightning.bolts.is_empty() and fx.lightning._mesh.get_surface_count() == 0, "lt: and gone after 36 ticks")
	for n in [fx.sfx, fx.sprites, fx.weapons, fx.lightning, fx]:
		n.free()


func _fx_movers() -> void:
	var fx := FxScript.new()
	fx.handle({"t": "mv", "k": 10, "z": 1, "l": [[700, 3, 256, 512, 0], [1, 1, 256, -256, 0]]})
	var a = fx._tracked.get(700)
	var b = fx._tracked.get(701)
	check(a != null and b != null and a.pos == Vector2(1, 2) and b.pos == Vector2(2, 1) and a.proto_id == 3 and b.proto_id == 4,
		"fx: delta-coded movers (z 1) are followed where they are, not their differences: %s" % [fx._tracked.keys()])
	fx.handle({"t": "mv", "k": 12, "l": [[702, 5, 768, 256, 0]]})
	var c = fx._tracked.get(702)
	check(c != null and c.pos == Vector2(3, 1) and c.proto_id == 5, "fx: and plain records as they are")
	# J11: each swing plays the entity's own mining sound (`eprops` ms), else Factorio's default: wood for
	# trees and plants, the ore sound for ore, rocks and fish; M1: a building's swing is silent (its
	# mined_sound still plays as it comes off).
	fx.handle({"t": "eprops", "l": [[31, 0, 0, 0, {"ms": "core/sound/axe-mining-stone"}], [32, 0, 0, 0, {"lr": 25}], [5, 0, 7.5, 2.5]]})
	var protos := ProtoDB.new()
	protos.add_entities([[30, "tree-01", "tree", -0.4, -0.4, 0.4, 0.4, 0, 0, 0, 1, 1], [31, "huge-rock", "simple-entity", -1, -1, 1, 1, 0, 0, 0, 2, 2],
		[33, "assembling-machine-1", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 0, 0, 0, 3, 3],
		[34, "iron-ore", "resource", -0.5, -0.5, 0.5, 0.5, 0, 0, 0, 1, 1], [35, "tree-plant", "plant", -0.4, -0.4, 0.4, 0.4, 0, 0, 0, 1, 1],
		[36, "transport-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 0, 0, 0, 1, 1]])
	var own: Dictionary = fx._mining_sounds
	var rock_sound := FxScript.sound_for(protos.entity(31), own)
	check(own == {31: "core/sound/axe-mining-stone"} and FxScript.sound_for(protos.entity(30), own) == "core/sound/mining-wood"
		and FxScript.sound_for(protos.entity(35), own) == "core/sound/mining-wood"
		and FxScript.sound_for(protos.entity(34), own) == "core/sound/axe-mining-ore"
		and rock_sound == ("core/sound/axe-mining-stone" if SoundBank.data_dir() != "" else "core/sound/axe-mining-ore"),
		"J11: a swing plays the prototype's own mining sound, else trees' wood and the ore sound: %s, rock %s" % [own, rock_sound])
	var machine_sound := FxScript.sound_for(protos.entity(33), own)
	var belt_sound := FxScript.sound_for(protos.entity(36), own)
	check(machine_sound == "" and belt_sound == "",
		"M1: a building without a mining_sound of its own is mined by hand without a swing sound: '%s', '%s'" % [machine_sound, belt_sound])
	FxScript.silent_buildings = false
	machine_sound = FxScript.sound_for(protos.entity(33), own)
	FxScript.silent_buildings = true
	check(machine_sound == "core/sound/axe-mining-ore", "M1: --building-swing=ore gives it the ore sound as before: '%s'" % machine_sound)
	await _fx_steps(fx)
	# Never in the tree, so its own nodes were never made its children.
	for n in [fx.sfx, fx.sprites, fx.weapons, fx.lightning, fx]:
		n.free()


## Step 5 task 3a and the owner's 24: the character's steps from the prototypes (`steps`, step_sounds.gd):
## a listed tile's own sound, an unlisted one's from the name table, a silent one, a rail's, a resource
## without one of its own walking as its tile, a sound whose files aren't here falling back, a plant's
## rustle on top, and `--steps=table`. Sine-tone fixtures registered as the files (no install needed).


func _fx_steps(fx) -> void:
	var StepSounds = preload("res://scripts/fx/step_sounds.gd")
	var Fixtures = preload("res://tests/sound_fixtures.gd")
	var SfxScript = preload("res://scripts/fx/sfx.gd")
	var dir := "user://fx_steps"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var fixture: String = ProjectSettings.globalize_path(dir.path_join("tone.ogg"))
	var f := FileAccess.open(fixture, FileAccess.WRITE)
	f.store_buffer(Fixtures.bytes(Fixtures.SHORT))
	f.close()
	var files := ["zz-test/sound/walking/meadow-1.ogg", "zz-test/sound/walking/meadow-2.ogg", "zz-test/sound/walking/rails.ogg",
		"zz-mod/sound/rustle_a.ogg", "zz-mod/sound/rustle_b.ogg"]
	for path in files:
		SoundBank.register_file(path, fixture)
	var w := WorldMirror.new()
	w.pick_build_usec = 1 << 40
	w.protos.add_tiles([[1, "zz-meadow", 60, 90, 30], [2, "zz-sand-unlisted", 190, 160, 100], [3, "zz-lava", 200, 70, 20],
		[4, "zz-far-ground", 90, 90, 90], [5, "zz-concrete", 120, 120, 120]])
	w.protos.add_entities([[40, "zz-rail", "straight-rail", -1, -1, 1, 1, 130, 120, 110, 2, 2],
		[41, "zz-ore", "resource", -0.5, -0.5, 0.5, 0.5, 105, 130, 150, 1, 1]])
	var cv := ChunkView.new()
	var ids := PackedInt32Array()
	ids.resize(32 * 32)
	ids.fill(1)
	ids[10 * 32 + 2] = 2
	ids[10 * 32 + 3] = 3
	ids[10 * 32 + 4] = 4
	ids[10 * 32 + 5] = 5
	cv.tile_ids = ids
	w.chunks[Vector2i.ZERO] = cv
	w._add([950, 40, 20 * 256, 20 * 256, 0])  # a rail over (19-20, 19-20)
	w._add([951, 41, 8 * 256 + 128, 8 * 256 + 128, 0])  # ore on (8, 8)
	var was_world = fx.world
	fx.world = w
	var dec := DecorativeLayer.new()
	dec._lists[Vector2i.ZERO] = [7, 2, 2, 100, 8, 3, 3, 50]
	fx.decoratives = dec
	var at := func(x: int, y: int) -> Vector2: return Vector2(x + 0.5, y + 0.5)
	var before: Array = fx._ground_under(at.call(2, 2))
	fx.handle({"t": "steps", "k": 1, "r": 1, "part": 1, "parts": 2, "u": [0, 0],
		"s": [["zz-test/sound/walking/meadow", 80, 2], ["zz-test/sound/walking/rails", 60, 1],
			[["zz-mod/sound/rustle_a.ogg", "zz-mod/sound/rustle_b.ogg"], 40, 2], ["zz-test/sound/walking/not-on-this-pc", 50, 3]]})
	var half_in: bool = fx.steps.listed
	fx.handle({"t": "steps", "k": 1, "r": 2, "part": 2, "parts": 2, "tl": [[1, 1], [3, 0], [4, 4]], "el": [[40, 2]], "dl": [[7, 3]]})
	check(before[0] == "base/sound/walking/dirt-1" and before[2] == null and not half_in and fx.steps.listed,
		"steps: before the list, the name table; the list is used once its last part is in: %s" % [before])
	var meadow: Array = fx._ground_under(at.call(2, 2))
	var def = meadow[2]
	check(def != null and Array(def.files) == files.slice(0, 2) and is_equal_approx(def.min_volumes[0], 0.8)
		and meadow[1] is Color and meadow[3] == true and StepSounds.name_of(def) == "meadow",
		"steps: a listed tile plays its prototype's sound, its variations at its volume, with the table's dust: %s" % [meadow])
	var unlisted: Array = fx._ground_under(at.call(2, 10))
	check(unlisted[0] == "base/sound/walking/sand" and unlisted[2] == null, "steps: a tile the list doesn't know: the name table's: %s" % [unlisted])
	var lava: Array = fx._ground_under(at.call(3, 10))
	check(lava[0] == "" and lava[2] == null and lava[3] == false, "steps: a tile the list knows without a walking sound is silent: %s" % [lava])
	var far: Array = fx._ground_under(at.call(4, 10))
	check(far[0] == "base/sound/walking/dirt-1" and far[2] == null, "steps: a sound whose files aren't on this PC: the table's: %s" % [far])
	var rail: Array = fx._ground_under(Vector2(20.0, 20.0))
	check(rail[2] != null and Array(rail[2].files) == [files[2]] and is_equal_approx(rail[2].min_volumes[0], 0.6) and rail[3] == false,
		"steps: a rail's own walking sound, one file: %s" % [rail])
	var ore: Array = fx._ground_under(at.call(8, 8))
	check(ore[2] != null and Array(ore[2].files) == files.slice(0, 2),
		"steps: a resource the list gives no sound walks as its tile, as in Factorio: %s" % [ore])
	var rustle = fx._rustle_under(at.call(2, 2))
	var none_here = fx._rustle_under(at.call(3, 3))
	check(rustle != null and Array(rustle.files) == files.slice(3, 5) and is_equal_approx(rustle.min_volumes[0], 0.4) and none_here == null,
		"the owner's 24: a plant with a walking sound rustles (a mod's oddly named files), one without doesn't: %s" % [rustle])
	# Played: through play_def under the kind step/<its sound>, the prototype's file the one that plays (--sfx-log names it).
	var sfx = SfxScript.new()
	add_child(sfx)
	await get_tree().process_frame
	for path in files:
		SoundBank.stream(path)
	var logging := FxSettings.log_sounds
	FxSettings.log_sounds = true
	var ready: bool = fx._def_ready(def)
	sfx.play_def(def, Vector3.ZERO, "Walking", 1.0, "step/" + StepSounds.name_of(def))
	sfx.play_def(rustle, Vector3.ZERO, "Walking", 1.0, "step/" + StepSounds.name_of(rustle))
	FxSettings.log_sounds = logging
	var played: Array = []
	for shot in sfx._shots:
		if shot.path != "":
			played.append(shot.path)
	check(ready and played.size() == 2 and str(played[0]) in files.slice(0, 2) and str(played[1]) in files.slice(3, 5),
		"steps: the step and the rustle on top both play, each the prototype's file: %s" % [played])
	sfx.queue_free()
	# --steps=table: the name table as before, whatever the list says.
	StepSounds.use_table = true
	var table_meadow: Array = fx._ground_under(at.call(2, 2))
	var table_lava: Array = fx._ground_under(at.call(3, 10))
	var table_rustle = fx._rustle_under(at.call(2, 2))
	StepSounds.use_table = false
	check(table_meadow[0] == "base/sound/walking/dirt-1" and table_meadow[2] == null and table_lava[0] == "base/sound/walking/dirt-1"
		and table_rustle == null, "--steps=table: the name table, no silence and no rustle: %s, %s" % [table_meadow, table_lava])
	# A welcome (a new bridge, or an older one without the list) forgets it.
	fx.handle({"t": "welcome"})
	var after: Array = fx._ground_under(at.call(2, 2))
	check(not fx.steps.listed and after[2] == null and after[0] == "base/sound/walking/dirt-1", "steps: forgotten on a welcome: the table until a list comes")
	for path in files:
		SoundBank.register_file(path, "")
	fx.world = was_world
	fx.decoratives = null
	dec.free()
	w.free()


## What weapons fire (weapon_fx.gd): projectiles tracked by id and played out where they end,
## beams and fires coming and going with the lists, explosions the game made skipped when just
## played, and Factorio's sheets cut into pools when the install is there.


func _weapons() -> void:
	var sprites := SpriteFx.new()
	add_child(sprites)
	var wf := WeaponFx.new()
	wf.sprites = sprites
	add_child(wf)
	await get_tree().process_frame
	var installed := SoundBank.data_dir() != ""
	if not installed:
		print("skip weapons' sheets and sounds: no Factorio install")
	if installed:
		# The world's sounds decode on a worker: null on first ask, ready shortly after.
		var oggs := Array(DirAccess.get_files_at(SoundBank.data_dir().path_join("base/sound"))).filter(func(f: String) -> bool: return f.ends_with(".ogg"))
		if not oggs.is_empty():
			var ogg := "base/sound/" + str(oggs[0])
			var first := SoundBank.stream_soon(ogg)
			var until := Time.get_ticks_msec() + 5000
			while SoundBank.stream_soon(ogg) == null and Time.get_ticks_msec() < until:
				await get_tree().process_frame
			check(first == null and SoundBank.stream_soon(ogg) != null and SoundBank.stream(ogg) == SoundBank.stream_soon(ogg),
				"a world sound's first ask decodes it on a worker (null now, ready after), not on the main thread")
		# A game left while its warm-up decodes are in flight (fx.gd's _exit_tree clears the cache),
		# and another joined at once that warms the same sounds: none lost, none decoded twice, and
		# nothing left decoding (the decodes hand their streams to the main thread once done).
		var bank: Script = SoundBank
		var pending: Dictionary = bank.get("_decoding")
		var cached: Dictionary = bank.get("_streams")  # a decode done meanwhile is taken in at the next ask
		var until := Time.get_ticks_msec() + 5000
		while not pending.is_empty() and Time.get_ticks_msec() < until:
			SoundBank.stream_soon("base/sound/zenith-test-none.ogg")
			await get_tree().process_frame
		SoundBank.clear_cache()
		var left := FxScript.new()
		left._warm_sounds()
		var warming := pending.size() + cached.size()
		SoundBank.clear_cache()
		var joined := FxScript.new()
		joined._warm_sounds()
		var again := pending.size() + cached.size()
		until = Time.get_ticks_msec() + 10000
		while not pending.is_empty() and Time.get_ticks_msec() < until:
			SoundBank.stream_soon("base/sound/zenith-test-none.ogg")
			await get_tree().process_frame
		var warmed: Array[String] = []
		warmed.assign(FxScript.MINED_SOUNDS)
		for prefix: String in FxScript.MINE_SOUNDS.values():
			warmed.append_array(Array(SoundBank.variants(prefix)))
		var missing := warmed.filter(func(p: String) -> bool: return SoundBank.stream_soon(p) == null)
		check(warming >= warmed.size() and again == warming and pending.is_empty() and missing.is_empty(),
			"a game left mid warm-up and another joined: one decode per sound (%d, then %d), all landed (%d of %d), none left decoding (%d)"
			% [warming, again, warmed.size() - missing.size(), warmed.size(), pending.size()])
		for fx in [left, joined]:
			for n in [fx.sfx, fx.sprites, fx.weapons, fx.lightning, fx]:
				n.free()
	check(wf.data.get("ex", {}).has("explosion") and wf.data.get("ammo", {}).get("shotgun-shell", {}).get("n") == 12.0
		and wf.dying_explosion("small-biter") == "small-biter-die" and is_equal_approx(wf.gun_cooldown("submachine-gun"), 0.1),
		"weapon_fx.json: explosions, ammo, dying explosions and gun cooldowns from Factorio's prototypes")
	if installed:
		# Atlases are cut from the sheets on worker threads (they cost fights 25-60 ms frames on
		# the main thread): nothing on the first ask, then ready.
		var cards_before := sprites.count()
		wf.explode("explosion-hit", Vector3.ZERO)
		var none_yet := sprites.count() == cards_before and wf.pools_pending() > 0
		wf.prewarm(["explosion", "explosion-hit", "rocket", "poison-cloud", "medium-scorchmark-tintable", "small-scorchmark-tintable"])
		var until := Time.get_ticks_msec() + 10000
		while wf.pools_pending() > 0 and Time.get_ticks_msec() < until:
			await get_tree().process_frame
		wf.explode("explosion-hit", Vector3.ZERO)
		check(none_yet and wf.pools_pending() == 0 and sprites.count() > cards_before,
			"weapon effects' atlases are made on a worker thread: nothing drawn on the first ask, drawn once made")
		wf._recent.clear()
	wf.handle({"t": "pj", "k": 100, "p": [5, "rocket", 512, 0, 6, "shotgun-pellet", 0, 512], "b": [9, "laser-beam", 0, 0, 1024, 0], "x": [], "e": []})
	wf.handle({"t": "pj", "k": 102, "p": [5, "rocket", 640, 0, 6, "shotgun-pellet", 0, 1024], "b": [9, "laser-beam", 0, 0, 1024, 0], "x": [], "e": []})
	var rocket = wf._flying.get(5)
	check(wf.flying_count() == 2 and rocket != null and is_equal_approx(rocket.vel.x, 15.0) and wf.beam_count() == 1,
		"pj: projectiles tracked by id with their speed (tiles a second), a beam")
	var cards := sprites.count()
	wf.handle({"t": "pj", "k": 104, "p": [6, "shotgun-pellet", 0, 1536], "b": {}, "x": [], "e": [5, 768, 0]})
	check(wf.flying_count() == 1 and wf.beam_count() == 0, "pj.e: an ended rocket goes, and a beam missing from the list")
	if installed:
		check(sprites.count() > cards and wf._recent.size() >= 1 and wf._recent[-1][0] == "explosion",
			"the rocket's explosion and scorch mark played where it ended (only_when_visible: the server makes none)")
		wf.handle({"t": "pj", "k": 106, "p": [], "b": [], "x": ["explosion", 785, 10], "e": []})
		check(wf._recent.size() == 1, "pj.x: the game's own explosion is skipped when the same was just played there")
	wf.handle({"t": "pj", "k": 108, "p": {}, "b": {}, "x": {}, "e": {}})
	check(wf.flying_count() == 0, "an empty pj clears what flew out of the area")
	wf.handle({"t": "gf", "k": 110, "l": [11, "fire-flame", 256, 256, -1, 12, "poison-cloud", -512, 0, 600]})
	check(wf.ground_count() == 2, "gf: a fire and a cloud")
	if installed:
		check(sprites.count() > 0 and wf._ground[12].cards.size() >= 8, "a poison cloud is drawn as Factorio's 16 smoke particles (capped)")
	wf.handle({"t": "gf", "k": 125, "l": {}})
	wf._process(3.0)
	check(wf.ground_count() == 0, "fires and clouds fade out once they leave the list")
	wf.in_space = true
	var before := sprites.count()
	wf._scorch("small-scorchmark-tintable", Vector3.ZERO)
	check(sprites.count() == before, "no scorch marks on a space platform (the owner's #16)")
	wf.reset()
	wf.queue_free()
	sprites.queue_free()


## A flamethrower turret firing as the bridge reports it ends in a drawn stream: Factorio makes a
## new stream entity every 4 ticks a step short of the target, the bridge lists the live ones in `pj`
## every 2 ticks, and the client draws one stream for the turret (its newest, `--flame-streams`)
## from the nozzle to the turret's target, its particles in the air while it fires.


class FlameAnim extends Node:
	var turrets: Node


class FlameWorld extends Node:
	var animator: Node
	var chunks := {}


func _flame_streams() -> void:
	var holder := Node3D.new()
	add_child(holder)
	var sprites := SpriteFx.new()
	holder.add_child(sprites)
	var layer := TurretLayer.new()
	holder.add_child(layer)
	var anim := FlameAnim.new()
	anim.turrets = layer
	holder.add_child(anim)
	var fw := FlameWorld.new()
	fw.animator = anim
	holder.add_child(fw)
	var wf := WeaponFx.new()
	wf.sprites = sprites
	wf.world = fw
	holder.add_child(wf)
	await get_tree().process_frame
	if SoundBank.data_dir() == "":
		print("skip flamethrower streams: no Factorio install (their sheet is Factorio's)")
		holder.queue_free()
		return
	# A turret at (100, 100) aimed east at a biter 20 tiles off.
	var st = layer._state(7300)
	st.cfg = TurretLayer.TURRETS["flamethrower-turret"]
	st.muzzle = Vector3(101.0, 1.2, 100.0)
	st.forward = Vector3.RIGHT
	st.target = Vector3(120.0, 0.45, 100.0)
	st.target_seen = layer._clock
	wf.prewarm(["flamethrower-fire-stream"])
	var until := Time.get_ticks_msec() + 10000
	while wf.pools_pending() > 0 and Time.get_ticks_msec() < until:
		await get_tree().process_frame
	check(wf.pools_pending() == 0, "flamethrower streams: their atlas is made")
	# 60 ticks of fire: a new entity every 4 ticks, each living 40 ticks, walking from 8 tiles out.
	var live := {}  # id -> [x, made tick]
	var most := 0
	var drawn_frames := 0
	for tick in range(0, 61):
		if tick % 4 == 0 and tick < 48:
			live[9000 + tick] = [109.0 + minf(float(tick) * 0.25, 10.0), tick]
		for id: int in live.keys():
			if tick - int(live[id][1]) >= 40:
				live.erase(id)
		if tick % 2 == 0:
			var p: Array = []
			for id: int in live.keys():
				p.append_array([id, "flamethrower-fire-stream", roundi(float(live[id][0]) * 256.0), 100 * 256])
			wf.handle({"t": "pj", "k": 5000 + tick, "p": p, "b": [], "x": [], "e": []})
		layer._clock += 1.0 / 60.0
		st.target_seen = layer._clock
		wf._process(1.0 / 60.0)
		var n := 0
		for s: WeaponFx.Stream in wf._streams.values():
			n += s.particles.size()
		most = maxi(most, n)
		if n > 0:
			drawn_frames += 1
	var leads := 0
	var lead: WeaponFx.Stream = null
	for s: WeaponFx.Stream in wf._streams.values():
		if s.lead and s.alive:
			leads += 1
			lead = s
	check(most >= 8 and drawn_frames >= 50,
		"a firing flamethrower turret's streams are drawn: %d particles in the air at most, in %d of 61 frames" % [most, drawn_frames])
	check(WeaponFx.flame_streams_old or (leads == 1 and lead != null and lead.shooter_unit == 7300
		and Vector2(lead.from.x, lead.from.z).distance_to(Vector2(101, 100)) < 0.01
		and Vector2(lead.to.x, lead.to.z).distance_to(Vector2(120, 100)) < 0.01),
		"one stream for the turret, from its nozzle to its target (%d leads; %s -> %s)" % [leads, lead.from if lead else Vector3.ZERO, lead.to if lead else Vector3.ZERO])
	wf.reset()
	holder.queue_free()


## Acid lands on what its spitter attacks (`en`), not on the client's character: a spitter attacking a
## car 6 tiles off spits at the car where it is drawn; `--acid-aim=old` (acid_aim_real off) keeps the
## old guess, mirrored through the spitter with no character near.


func _acid_aim() -> void:
	var holder := Node3D.new()
	add_child(holder)
	var ap := ProtoDB.new()
	ap.add_entities([[8, "car", "car", -0.7, -1.0, 0.7, 1.0, 1, 1, 1, 1, 1], [12, "small-spitter", "unit", -0.2, -0.2, 0.2, 0.2, 1, 1, 1, 1, 1]])
	var layer := MoverLayer.new()
	layer.protos = ap
	holder.add_child(layer)
	# A car at (106, 100) and a spitter at (100, 100).
	layer.handle({"t": "mv", "k": 1, "l": [[9400, 8, 106 * 256, 100 * 256, 0], [9401, 12, 100 * 256, 100 * 256]]})
	layer._process(10.0)
	var wf := WeaponFx.new()
	wf.movers = layer
	holder.add_child(wf)
	var was := WeaponFx.acid_aim_real
	var place := func(real: bool) -> Vector3:
		WeaponFx.acid_aim_real = real
		var st := WeaponFx.Stream.new()
		st.name = "acid-stream-spitter-small"
		st.pos = Vector2(100.5, 100.0)  # made next to the spitter
		wf._place_stream(st)
		return st.to
	var none: Vector3 = place.call(true)
	check(Vector2(none.x, none.z).distance_to(Vector2(101.0, 100.0)) < 0.6,
		"acid with no `en` target still lands where it did (mirrored through its spitter): %s" % [none])
	# The car moved on since the mod read it: `en` says (105.5, 100.2), the car is drawn at (106, 100).
	layer.creatures.handle_attacks({"t": "en", "l": [9401, 105 * 256 + 128, 100 * 256 + 51]})
	var real: Vector3 = place.call(true)
	check(Vector2(real.x, real.z).distance_to(Vector2(106, 100)) < 0.05 and is_equal_approx(real.y, 0.15),
		"acid lands on the car its spitter attacks (`en`), where the car is drawn: %s" % [real])
	var old: Vector3 = place.call(false)
	check(Vector2(old.x, old.z).distance_to(Vector2(101.0, 100.0)) < 0.6,
		"--acid-aim=old: the old guess, mirrored through the spitter (no character near): %s" % [old])
	# A target with no mover near it (a wall, a turret): the `en` point itself.
	layer.creatures.handle_attacks({"t": "en", "l": [9401, 96 * 256, 97 * 256]})
	var wall: Vector3 = place.call(true)
	check(Vector2(wall.x, wall.z).distance_to(Vector2(96, 97)) < 0.05,
		"acid at a building lands on the `en` point: %s" % [wall])
	# A construction robot flying a tile off the wall: the acid still lands on the `en` point, not under it.
	ap.add_entities([[13, "construction-robot", "construction-robot", -0.2, -0.2, 0.2, 0.2, 1, 1, 1, 1, 1]])
	layer.handle({"t": "mv", "k": 2, "l": [[9400, 8, 106 * 256, 100 * 256, 0], [9401, 12, 100 * 256, 100 * 256], [9402, 13, 97 * 256, 97 * 256, 0]]})
	layer._process(10.0)
	var by_robot: Vector3 = place.call(true)
	check(Vector2(by_robot.x, by_robot.z).distance_to(Vector2(96, 97)) < 0.05,
		"acid at a building with a robot flying a tile off still lands on the `en` point: %s" % [by_robot])
	# A worm (a `turret` world record with a unit number, no mover) spits at the car it attacks.
	var ww := WormWorld.new()
	holder.add_child(ww)
	ww.add_worm(Vector2(80.0, 100.0), 9500)
	wf.world = ww
	layer.creatures.handle_attacks({"t": "en", "l": [9500, 105 * 256 + 128, 100 * 256 + 51]})
	var worm_st := WeaponFx.Stream.new()
	worm_st.name = "acid-stream-worm-small"
	worm_st.pos = Vector2(80.5, 100.0)
	WeaponFx.acid_aim_real = true
	wf._place_stream(worm_st)
	check(worm_st.shooter_unit == 9500 and Vector2(worm_st.to.x, worm_st.to.z).distance_to(Vector2(106, 100)) < 0.05,
		"a worm's acid lands on the car it attacks (shooter unit %d): %s" % [worm_st.shooter_unit, worm_st.to])
	WeaponFx.acid_aim_real = was
	holder.queue_free()


## The HUD and character screen as Factorio 2.1 has them (ui-hud): the top-right side menu
## (research, the 6+4 buttons, the minimap's place), the shortcut bar's chooser and new shortcuts,
## the quickbar's page chooser, the character screen's parts, chat, recipe tooltips.


func _debug_menu(hud: Hud) -> void:
	var ui = hud.ui
	var m = ui.model
	var dm = ui.debug_menu
	var was_ready: bool = Bridge.world_ready
	Bridge.world_ready = true
	Controls.define()
	sent()
	check(Controls.keys_text("debug_menu") == "Ctrl+F12" and ControlsInfo.group_of("debug_menu") == "Miscellaneous",
		"debug menu: its own control, Ctrl+F12, in Settings > Controls: %s" % Controls.keys_text("debug_menu"))
	check(not dm.is_open(), "debug menu: closed until its key")
	key(KEY_F12, false, true)
	await get_tree().process_frame
	var asked: Dictionary = sent_one("cmd")
	check(dm.is_open() and str(asked.get("text")) == "/f3d-debug", "debug menu: Ctrl+F12 opens it and asks the bridge for the game's state: %s" % asked)
	var pause: Button = dm.find_child("Pause", true, false)
	var slider: HSlider = dm.find_child("Daytime", true, false)
	check(pause != null and slider != null and pause.disabled and not slider.editable, "debug menu: the time controls are greyed until the bridge answers")
	var state := {"dt": 0.25, "fz": 0, "sp": 1, "pa": 0, "ad": 0, "s": "nauvis", "x": 2560, "y": -512, "sx": 0, "sy": 0}
	m.handle({"t": "cmdr", "id": m._command_id, "l": ["Time of day 0.250, speed 1x, on nauvis"], "dbg": state})
	var clock: Label = dm.find_child("Clock", true, false)
	var pause_note: Label = dm.find_child("PauseNote", true, false)
	# The UI test has no RCON: Pause is greyed with the reason (a paused game couldn't be resumed).
	check(pause.disabled and slider.editable and is_equal_approx(slider.value, 0.75) and clock.text == "18:00" and dm.why() == ""
		and pause_note.visible and pause_note.text.contains("RCON"),
		"debug menu: the bridge's state shows (daytime 0.25 is 18:00, three quarters along the clock slider), Pause greyed without RCON: %s %s / %s" % [clock.text, dm.why(), pause_note.text])
	check(dm.slider_of(0.0) == 0.5 and dm.slider_of(0.5) == 0.0 and is_equal_approx(dm.daytime_of(0.25), 0.75),
		"debug menu: the slider runs midnight to midnight (noon in the middle)")
	(dm.find_child("DayNoon", true, false) as Button).pressed.emit()
	check(is_equal_approx(slider.value, 0.5), "debug menu: Noon puts the slider in the middle: %s" % slider.value)
	(dm.find_child("Freeze", true, false) as CheckBox).button_pressed = true
	(dm.find_child("Speed2", true, false) as Button).pressed.emit()
	(dm.find_child("Speed0_25", true, false) as Button).pressed.emit()
	(dm.find_child("SpeedBox", true, false) as LineEdit).text = "3x"
	(dm.find_child("SpeedSet", true, false) as Button).pressed.emit()
	pause.pressed.emit()  # greyed: sends nothing
	(dm.find_child("Spot_east", true, false) as Button).pressed.emit()
	var texts: Array = sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "cmd").map(func(c: Dictionary) -> String: return str(c["text"]))
	check(texts == ["/f3d-debug daytime 0.000", "/f3d-debug freeze on", "/f3d-debug speed 2", "/f3d-debug speed 0.25", "/f3d-debug speed 3",
		"/f3d-debug teleport 510.0 -2.0"], "debug menu: presets, freeze, speeds, custom speed and a spot send /f3d-debug, Pause without RCON nothing: %s" % [texts])
	# With RCON (a stand-in main): Pause goes through the bridge with the timeout held off; the
	# bridge is silent until Resume, which runs over RCON.
	var rcon_gs := GDScript.new()
	rcon_gs.source_code = "extends Node\nvar ran: Array = []\nfunc _has_rcon() -> bool:\n\treturn true\nfunc _run_command(c: String) -> String:\n\tran.append(c)\n\treturn \"\"\n"
	rcon_gs.reload()
	var rcon_main: Node = rcon_gs.new()
	add_child(rcon_main)
	dm.main = rcon_main
	var was_connected: bool = Bridge.connected
	Bridge.connected = true  # (a pause Zenith can't resume, or with no game, is let go)
	m.handle({"t": "cmdr", "id": m._command_id, "l": [], "dbg": state})
	check(not pause.disabled and not pause_note.visible, "debug menu: with RCON, Pause works")
	pause.pressed.emit()
	var pause_cmd: Dictionary = sent_one("cmd")
	check(str(pause_cmd.get("text")) == "/f3d-debug pause on" and Bridge._quiet_by.has("debug menu") and dm.paused_here()
		and pause.text == "Resume the game" and not pause.disabled and not slider.editable and pause_note.text.contains("Resume runs over RCON"),
		"debug menu: Pause asks the bridge, holds the timeout off, and only Resume stays: %s" % pause_cmd)
	dm._refresh = 100.0
	await get_tree().process_frame
	check(sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "cmd").is_empty(), "debug menu: paused, it doesn't ask the silent bridge")
	pause.pressed.emit()
	await get_tree().process_frame
	check(rcon_main.ran == ["/sc game.tick_paused = false"] and not Bridge._quiet_by.has("debug menu") and not dm.paused_here()
		and str(sent_one("cmd").get("text")) == "/f3d-debug", "debug menu: Resume runs over RCON, lets the timeout run and asks the state: %s" % [rcon_main.ran])
	var paused := state.duplicate()
	paused["pa"] = 1
	m.handle({"t": "cmdr", "id": int(pause_cmd.get("id")), "l": ["The game is paused"], "dbg": paused})
	check(pause.text == "Pause the game", "debug menu: the pause's own answer, coming after the resume, changes nothing: %s" % pause.text)
	pause.pressed.emit()
	var elsewhere_cmd: Dictionary = sent_one("cmd")
	m.handle({"t": "cmdr", "id": int(elsewhere_cmd.get("id")), "l": ["The game is paused"], "dbg": paused})
	check(not dm.paused_here() and not Bridge._quiet_by.has("debug menu") and pause.text == "Pause the game" and str(sent_one("cmd").get("text")) == "/f3d-debug",
		"debug menu: the pause's answer while paused here means it was resumed elsewhere: the timeout runs and it asks the state")
	pause.pressed.emit()
	var refused_cmd: Dictionary = sent_one("cmd")
	m.handle({"t": "cmdr", "id": int(refused_cmd.get("id")), "l": ["Console commands are for admins in a multiplayer game"], "na": 1})
	check(not dm.paused_here() and not Bridge._quiet_by.has("debug menu") and dm.why().contains("admins"),
		"debug menu: a refused pause (not an admin) lets the timeout run again: %s" % dm.why())
	# An answer that comes late (a busy base) is still taken; one that doesn't come says why.
	var late_id: int = m.command("/f3d-debug")
	dm._asked[late_id] = [Time.get_ticks_msec() - 10000, "state"]
	dm._sent[late_id] = "state"
	await get_tree().process_frame
	check(not dm.why().contains("admins") and dm.why() != "", "debug menu: no answer in 5 s says what the link shows: %s" % dm.why())
	m.answer_read({"t": "cmdr", "id": late_id, "l": [], "dbg": state})
	check(dm.why() == "" and slider.editable, "debug menu: a late answer still shows the game's state")
	m.handle({"t": "cmdr", "id": late_id, "l": [], "dbg": paused})
	check(dm.state().get("pa", 0) == 0, "debug menu: an answer read early isn't taken again in its turn")
	dm.main = null
	rcon_main.queue_free()
	Bridge.connected = was_connected
	dm._ask("/f3d-debug", "state")
	sent()
	m.handle({"t": "cmdr", "id": m._command_id, "l": ["Console commands are for admins in a multiplayer game"], "na": 1})
	check(pause.disabled and not slider.editable and dm.why().contains("admins"), "debug menu: refused (not an admin), greyed with the reason: %s" % dm.why())
	key(KEY_ESCAPE)
	await get_tree().process_frame
	check(not dm.is_open(), "debug menu: Esc closes it")
	key(KEY_F12, false, true)
	await get_tree().process_frame
	m.handle({"t": "cmdr", "id": m._command_id, "l": [], "ok": 0})
	check(pause.disabled and dm.why().contains("older"), "debug menu: an older bridge without /f3d-debug: greyed, says why: %s" % dm.why())
	m.handle({"t": "cmdr", "id": 0, "l": [], "dbg": state})
	check(pause.disabled, "debug menu: answers it didn't ask for change nothing")
	# Tests: what asks the bridge, the overlays, the probes that need a game.
	sent()
	(dm.find_child("Test_selftest", true, false) as Button).pressed.emit()
	check(str(sent_one("cmd").get("text")) == "/f3d-selftest", "debug menu: the self-test asks the bridge")
	m.handle({"t": "cmdr", "id": m._command_id, "l": ["[Zenith] PASS the bridge has a character", "[Zenith] FAIL something"]})
	check(dm.results_text().contains("PASS the bridge has a character") and dm.results_text().contains("FAIL something"), "debug menu: the self-test's lines show: %s" % dm.results_text())
	(dm.find_child("Test_graph", true, false) as Button).button_pressed = true
	(dm.find_child("Test_counters", true, false) as Button).button_pressed = true
	check(dm.toggled_on("graph") and dm._overlay != null and dm._overlay.graph and dm._overlay.counter_text().contains("draw calls"),
		"debug menu: the frame-time graph and counters switch on")
	(dm.find_child("Test_graph", true, false) as Button).button_pressed = false
	(dm.find_child("Test_counters", true, false) as Button).button_pressed = false
	check(not dm._overlay.graph and not dm._overlay.counters, "debug menu: and off")
	(dm.find_child("Test_robots", true, false) as Button).pressed.emit()
	check(dm.results_text().contains("needs a game"), "debug menu: a probe without a game says so")
	var lod_btn: Button = dm.find_child("Test_lods", true, false)
	check(lod_btn != null, "debug menu: Dump building LODs button present")
	if lod_btn != null:
		lod_btn.pressed.emit()
		check(dm.results_text().contains("needs a game"), "debug menu: LOD dump without a game says so")
	var lw := WorldMirror.new()
	add_child(lw)
	lw.protos.add_entities([
		[1, "electromagnetic-plant", "assembling-machine", -2.0, -2.0, 2.0, 2.0, 120, 120, 200, 4, 4],
		[2, "transport-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[3, "steel-chest", "container", -0.35, -0.35, 0.35, 0.35, 200, 180, 0, 1, 1],
	])
	var em_mesh := ModelLibrary.mesh_for_entity("electromagnetic-plant", "assembling-machine", {}, 0)
	var belt_extra := {"s": "s", ModelLibrary.PACK_KEY: "builtin:wube3dp"}
	var belt_mesh := ModelLibrary.mesh_for_entity("transport-belt", "transport-belt", belt_extra, 0)
	BeltLods.stand_in(belt_mesh, "s")
	BeltLods.finish_all()
	BeltLods.stand_in(belt_mesh, "s")
	var chest_mesh := ModelLibrary.mesh_for_entity("steel-chest", "container", {}, 0)
	var lcv := ChunkView.new()
	lcv.coord = Vector2i.ZERO
	lcv.loaded = true
	lw.chunks[Vector2i.ZERO] = lcv
	lw.add_child(lcv)
	for rec_spec: Array in [
		[1, 1, Vector2(6.0, 6.0), {}],
		[2, 2, Vector2(10.5, 6.5), belt_extra],
		[3, 3, Vector2(2.5, 2.5), {}],
	]:
		var lrec := WorldMirror.Rec.new()
		lrec.key = int(rec_spec[0])
		lrec.unit = int(rec_spec[0])
		lrec.proto_id = int(rec_spec[1])
		lrec.pos = rec_spec[2] as Vector2
		lrec.extra = rec_spec[3] as Dictionary
		lrec.chunk = Vector2i.ZERO
		lcv.entities[lrec.key] = lrec
		lw.entities[lrec.key] = lrec
	await lcv.build_entities(lw.protos, {})
	var chest_mmi: MultiMeshInstance3D = lcv._nodes.get(chest_mesh)
	if chest_mmi != null:
		chest_mmi.set_instance_shader_parameter(&"f3d_lod_fade", 0.0)
	var stub_gs := GDScript.new()
	stub_gs.source_code = "extends Node\nvar world: Node3D\n"
	stub_gs.reload()
	var stub_main: Node = stub_gs.new()
	add_child(stub_main)
	stub_main.world = lw
	var dump_path := "user://debug/test-lod-dump.txt"
	var dump_res: Dictionary = LodDump.dump(stub_main, dump_path, 1)
	var dump_text: String = str(dump_res.get("text", ""))
	var dumped_nodes: int = dump_text.count("\n  NODE ")
	check(bool(dump_res.get("ok")) and int(dump_res.get("chunks")) >= 1 and int(dump_res.get("anomalies")) >= 1
		and lcv._nodes.has(em_mesh) and lcv._nodes.has([em_mesh, 0]) and lcv._nodes.has([belt_mesh, BeltLods.FLAT])
		and dumped_nodes == lcv._nodes.size()
		and dump_text.contains("PROTOS:") and dump_text.contains("electromagnetic-plant")
		and dump_text.contains("electromagnetic-plant[0]") and dump_text.contains("steel-chest")
		and dump_text.contains("FADE_LOW") and dump_text.contains("rs_f=") and dump_text.contains("vi_aabb=")
		and FileAccess.file_exists(dump_path),
		"lod dump inspects mixed mesh/part/flat keys cleanly and writes %s (chunks=%s anomalies=%s nodes=%d/%d)" % [
			dump_path, dump_res.get("chunks"), dump_res.get("anomalies"), dumped_nodes, lcv._nodes.size()])
	if lod_btn != null:
		dm.main = stub_main
		lod_btn.pressed.emit()
		check(dm.results_text().contains("LOD dump ->") and dm.results_text().contains("FADE_LOW") and dm.results_text().contains("electromagnetic-plant"),
			"debug menu: Dump building LODs writes report and shows summary: %s" % dm.results_text())
		dm.main = null
		var menu_dump := ProjectSettings.globalize_path("user://debug/lod-dump.txt")
		if FileAccess.file_exists("user://debug/lod-dump.txt"):
			DirAccess.remove_absolute(menu_dump)
	if FileAccess.file_exists(dump_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dump_path))
	stub_main.queue_free()
	lw.queue_free()
	for id in ["stand", "laps", "flyover", "zoom"]:
		check(dm.find_child("Run_" + id, true, false) != null and (dm.find_child("Run_" + id, true, false) as Button).disabled,
			"debug menu: benchmark %s listed, greyed without a game" % id)
	# A benchmark's report, against the last run of it.
	var report := {"bench": "stand", "name": "Standing still", "when": "x", "seconds": 30.0, "frames": 1800, "fps": 60.0, "p50": 11.0, "p99": 18.0,
		"worst": 30.0, "over16": 12, "over33": 0, "gpu_p50": 5.0, "gpu_p99": 7.0, "render_cpu_p50": 3.0, "process_p50": 4.0, "draw_calls_p50": 1200,
		"primitives_p50": 2100000, "ups": 60.0, "bridge_ms": -1.0, "bridge_note": "needs RCON", "setup": {"version": "0.1.4", "preset": "high", "look": "factorio",
		"resolution": "1920x1080", "render_scale": 1.0}, "previous": {"p50": 10.0, "p99": 18.0, "fps": 62.0, "ups": 60.0, "when": "y"}}
	var text: String = dm.report_text(report)
	check(text.contains("Frame time p50 (ms)") and text.contains("+10.0%") and text.contains("2.10 M") and text.contains("graphics preset high")
		and text.contains("1920x1080") and text.contains("needs RCON"), "debug menu: the report's text has the figures, the change, what ran: %s" % text)
	dm.show_report(report)
	check(dm.report_open() and dm.find_child("CopyReport", true, false) != null, "debug menu: the report window opens with Copy and Save")
	var saved: String = dm.save_report()
	check(FileAccess.file_exists(saved) and FileAccess.get_file_as_string(saved).contains("Standing still"), "debug menu: Save writes the report: %s" % saved)
	key(KEY_ESCAPE)
	await get_tree().process_frame
	check(not dm.report_open() and dm.is_open(), "debug menu: Esc closes the report first")
	key(KEY_ESCAPE)
	await get_tree().process_frame
	check(not dm.is_open(), "debug menu: then the menu")
	check(dm.clock_text(0.0) == "12:00" and dm.clock_text(0.5) == "00:00" and dm.clock_text(0.75) == "06:00", "debug menu: Factorio's day: 0 is noon")
	sent()
	Bridge.world_ready = was_ready


## The debug menu opens over an add-on's camera (the Cinematic camera's F8) and over a hidden interface
## (F11): its own layer stays shown, the mouse is wanted while it is open, and it closes as before.


func _debug_menu_over_camera(hud: Hud) -> void:
	var dm = hud.ui.debug_menu
	var layer: CanvasLayer = hud.ui.debug_layer
	check(dm.get_parent() == layer and layer.is_in_group(AddonHostScript.SHOWN_WITH_INTERFACE_HIDDEN) and layer.layer > 15,
		"debug menu: on its own layer over the HUD and add-ons' windows, kept with the interface hidden")
	var holder := Node3D.new()
	add_child(holder)
	var rig := CameraRig.new()
	holder.add_child(rig)
	var walker := Node3D.new()
	holder.add_child(walker)
	rig.target = walker
	var stand_gs := GDScript.new()
	stand_gs.source_code = "extends Node\nvar rig\nvar hud\nvar input\nvar _game\nvar front_end\nvar ride\n"
	stand_gs.reload()
	var stand: Node = stand_gs.new()
	stand.rig = rig
	stand.hud = hud
	stand._game = self
	holder.add_child(stand)
	var api_gs := GDScript.new()
	api_gs.source_code = "extends RefCounted\nvar id := \"stand-in\"\nvar camera := Cam.new()\nvar keys := Keys.new()\n" \
		+ "class Cam:\n\tfunc _focus_point() -> Vector2:\n\t\treturn Vector2(300, 300)\n\tfunc mouse_captured() -> bool:\n\t\treturn true\n\tfunc _lost() -> void:\n\t\tpass\n" \
		+ "class Keys:\n\tfunc _camera_actions() -> Array:\n\t\treturn []\n"
	api_gs.reload()
	var api = api_gs.new()
	var host := AddonHostScript.new()
	host.autoload = false
	host.main = stand
	holder.add_child(host)
	host._game_on = true
	check(host.take_camera(api, true) and rig.taken(), "debug menu: a stand-in add-on has the camera")
	key(KEY_F12, false, true)
	await get_tree().process_frame
	host._process(0.0)
	check(dm.is_open() and dm.is_visible_in_tree() and host.debug_menu_open() and host.windows_open(),
		"debug menu: Ctrl+F12 opens it while an add-on has the camera, and the host shows the mouse for it")
	key(KEY_F12, false, true)
	await get_tree().process_frame
	check(not dm.is_open() and not host.windows_open(), "debug menu: and closes it, the add-on's mouse back")
	host.request_hidden(api, true)
	check(not hud.visible and layer.visible, "debug menu: hiding the interface hides the HUD, not the menu's layer")
	# B-roll: alert icons made after an add-on hid the interface (alerts arriving later, another
	# surface) were drawn: they follow the one interface-hidden flag themselves now.
	var late_icons := AlertIconsScript.new()
	holder.add_child(late_icons)
	var power_icons := FluidsPowerScript.new()
	holder.add_child(power_icons)
	await get_tree().process_frame
	check(InterfaceStateScript.hidden() and not late_icons.visible and not (power_icons._icons as Node3D).visible,
		"hide_interface: alert and no-power icons made after the interface hid stay hidden")
	key(KEY_F12, false, true)
	await get_tree().process_frame
	check(dm.is_open() and dm.is_visible_in_tree(), "debug menu: Ctrl+F12 opens it over the hidden interface")
	key(KEY_ESCAPE)
	await get_tree().process_frame
	check(not dm.is_open(), "debug menu: Esc closes it there too")
	host.request_hidden(api, false)
	await get_tree().process_frame
	check(hud.visible and not InterfaceStateScript.hidden() and late_icons.visible and (power_icons._icons as Node3D).visible,
		"debug menu: the interface comes back, the icons with it")
	host.release_camera(api)
	host._game_on = false
	holder.queue_free()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	sent()


## Health bars are part of the interface: gone while it is hidden, back with it; --health-bars=always
## keeps them, off hides them.


func _health_bars() -> void:
	var CombatScript := preload("res://scripts/world/combat.gd")
	var gs := GDScript.new()
	gs.source_code = "extends 'res://scripts/world/combat.gd'\nfunc _bar_position(_u: int) -> Variant:\n\treturn Vector3(0, 1, 0)\n"
	gs.reload()
	var holder := Node3D.new()
	add_child(holder)
	var cam := Camera3D.new()
	holder.add_child(cam)
	cam.current = true
	var combat = gs.new()
	holder.add_child(combat)
	combat._health = {7: 0.5}
	await get_tree().process_frame
	var shown := func() -> int:
		combat._update_bars()
		return combat._fill.multimesh.visible_instance_count
	CombatScript.bars_mode = "auto"
	InterfaceStateScript.set_hidden(&"test", false)
	check(shown.call() == 1, "health bars: drawn with the interface showing")
	InterfaceStateScript.set_hidden(&"test", true)
	check(shown.call() == 0, "health bars: hidden while the interface is hidden")
	CombatScript.bars_mode = "always"
	check(shown.call() == 1, "health bars: --health-bars=always keeps them with the interface hidden")
	CombatScript.bars_mode = "off"
	InterfaceStateScript.set_hidden(&"test", false)
	check(shown.call() == 0, "health bars: --health-bars=off hides them with the interface showing")
	CombatScript.bars_mode = "auto"
	check(shown.call() == 1, "health bars: back with the interface")
	holder.queue_free()


## The build's channel (Settings.dev_tools()): a public download has no Performance test in the main
## menu and no debug menu key (none in Settings > Controls, Ctrl+F12 does nothing); a dev build and a
## checkout have both.


func _dev_tools(hud: Hud) -> void:
	var dm = hud.ui.debug_menu
	var theme_before: Theme = get_tree().root.theme
	var quit_before := get_tree().auto_accept_quit
	var fe: Node = FrontEndScript.new()
	add_child(fe)
	await get_tree().process_frame
	check(Settings.dev_tools(), "dev tools: a checkout counts as a dev build")
	for dev in [false, true]:
		Settings.dev_tools_override = 1 if dev else 0
		Controls.define()
		Settings.apply_bindings()
		var bound := InputMap.has_action("debug_menu") and Settings.bindable_actions().has("debug_menu")
		check(bound == dev and (Controls.keys_text("debug_menu") == "Ctrl+F12") == dev,
			"dev tools %s: the debug menu's key %s Settings > Controls: %s" % [dev, "in" if dev else "not in", Controls.keys_text("debug_menu")])
		key(KEY_F12, false, true)
		await get_tree().process_frame
		check(dm.is_open() == dev, "dev tools %s: Ctrl+F12 %s the debug menu" % [dev, "opens" if dev else "doesn't open"])
		# The debug line: F4 in a dev build, no key by default in a public one, still in Settings > Controls (issue #26).
		var line_was: bool = hud.ui.debug_overlay
		key(KEY_F4)
		await get_tree().process_frame
		var toggled: bool = hud.ui.debug_overlay != line_was
		check(toggled == dev and Settings.bindable_actions().has("debug_line") and Settings.keys_for("debug_line") == ([KEY_F4, 0] if dev else [0, 0]),
			"dev tools %s: F4 %s the debug line (keys %s)" % [dev, "toggles" if dev else "doesn't toggle", Settings.keys_for("debug_line")])
		if toggled:
			key(KEY_F4)
			await get_tree().process_frame
		dm.open(true)
		check(dm.is_open() == dev, "dev tools %s: the debug menu %s" % [dev, "opens" if dev else "never opens, so neither do its overlays"])
		dm.open(false)
		fe._show_main_menu()
		check((fe._page.find_child("Performancetest", true, false) is Button) == dev,
			"dev tools %s: the main menu has %s Performance test entry" % [dev, "a" if dev else "no"])
		fe._show_perf_test()
		check(fe._overlays.is_empty() != dev, "dev tools %s: the performance test %s" % [dev, "opens" if dev else "doesn't open"])
		fe._clear_overlays()
	Settings.dev_tools_override = -1
	sent()
	fe.queue_free()
	await get_tree().process_frame
	get_tree().root.theme = theme_before
	get_tree().auto_accept_quit = quit_before


## The debug menu's Updates tab (update_overlay.gd, owner: "see when and where the bridge is updating parts by
## outlining the tiles"): a kind switched on outlines what each of its messages touched (an entity's footprint,
## turned as it stands, a chunk's square, a lane's strip, a hand's spot), full at once and faded out a second
## later, then not drawn at all; a kind off draws nothing; with every kind off there is no overlay node, no
## handler on the Bridge and no belt tap; a public build (no dev tools) or no game switches none on. The states:
## how each lane is drawn (the lattice's lanes as belt_items.gd's lattice has them, the rest the simulation's,
## belts with no lane far icons or nothing) and the lattice against the simulation (standing while the
## simulation moves, pulsing once held). The legend counts updates a second. The flash shader parses; a broken
## copy doesn't.


func _update_overlays(hud: Hud) -> void:
	var dm = hud.ui.debug_menu
	var ids: Array = UpdateOverlayScript.kind_ids()
	var boxes := 0
	for id: String in ids:
		if dm.find_child("Upd_" + id, true, false) is CheckBox:
			boxes += 1
	dm._open_tab(3)
	check(dm.current_tab() == "Updates" and dm.find_child("UpdatesPage", true, false) != null and boxes == ids.size(),
		"update overlays: the debug menu's Updates tab, a switch per kind (%d of %d)" % [boxes, ids.size()])
	dm._open_tab(0)
	var was_main = dm.main
	Settings.dev_tools_override = 0
	var public_on: bool = dm.set_update_kind("add", true)
	Settings.dev_tools_override = -1
	dm.main = null
	var no_game_on: bool = dm.set_update_kind("add", true)
	check(not public_on and not no_game_on and dm.update_overlay() == null and not (dm.find_child("Upd_add", true, false) as CheckBox).button_pressed,
		"update overlays: a public build or no game switches none on (no overlay made, the box unticked)")
	# A stand-in game: a world with an assembler (3 x 3), a splitter (2 x 1) and belts, belt_items.gd, far icons.
	var w := WorldMirror.new()
	add_child(w)
	w.protos.add_entities([[1, "assembling-machine-1", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 150, 150, 150, 3, 3],
		[2, "splitter", "splitter", -0.9, -0.5, 0.9, 0.5, 200, 200, 0, 2, 1],
		[3, "transport-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 200, 200, 0, 1, 1]])
	var belts = BeltItemsScript.new()
	add_child(belts)
	belts._sync = true
	# (The states' belts and lanes well away from the rest: they count what lies within TINT_RADIUS of the focus.)
	var ox := 300.0
	var oy := 300.5
	for at: Vector2 in [Vector2(10, 10), Vector2(20, 5), Vector2(ox + 8.5, oy), Vector2(ox + 40.5, oy)]:
		var c: Vector2i = WorldMirror.chunk_of(at)
		if not w.chunks.has(c):
			var cv := ChunkView.new()
			cv.coord = c
			cv.loaded = true
			w.chunks[c] = cv
			w.add_child(cv)
	w._add([5, 1, 10 * 256 + 128, 10 * 256 + 128, 0])
	w._add([6, 2, 20 * 256 + 128, 5 * 256, 4])  # facing east: 1 x 2 on the map, on a tile's middle across, its edge along
	w._add([77, 3, roundi((ox + 8.5) * 256), roundi(oy * 256), 0])
	w._add([78, 3, roundi((ox + 40.5) * 256), roundi(oy * 256), 0])
	w.set_focus(Vector2(ox, oy))
	var lanes_gs := GDScript.new()
	lanes_gs.source_code = "extends Node\nvar covered := Vector3()\nvar distance := 160\nvar far := {}\nfunc built_chunks() -> Dictionary:\n\treturn far\n"
	lanes_gs.reload()
	var far_lanes: Node = lanes_gs.new()
	far_lanes.covered = Vector3(ox, oy, 2.0)
	far_lanes.far = {WorldMirror.chunk_of(Vector2(ox + 8.5, oy)): true}
	add_child(far_lanes)
	var stand_gs := GDScript.new()
	stand_gs.source_code = "extends Node\nvar world\nvar belt_items\nvar belt_lanes\n"
	stand_gs.reload()
	var stand: Node = stand_gs.new()
	stand.world = w
	stand.belt_items = belts
	stand.belt_lanes = far_lanes
	add_child(stand)
	dm.main = stand
	(dm.find_child("Upd_add", true, false) as CheckBox).button_pressed = true
	var ov = dm.update_overlay()
	check(ov != null and ov.get_parent() == w and ov.is_on("add") and Bridge.message_received.is_connected(Callable(ov, "on_message")) and not belts.debug_tap.is_valid(),
		"update overlays: ticking a kind makes the overlay in the world, its handler on the Bridge (no belt tap for an entity kind)")
	if ov == null:
		dm.main = was_main
		for n in [w, belts, far_lanes, stand]:
			n.queue_free()
		return
	ov.on_message({"t": "add", "e": [7, 1, 30 * 256 + 128, 12 * 256 + 128, 0]})
	ov.on_message({"t": "del", "u": 6, "p": 2, "x": 20 * 256 + 128, "y": 5 * 256})  # off: nothing
	ov._process(0.016)
	var f: Array = ov.drawn_at("add", 0)
	check(ov.drawn_count("add") == 1 and not ov.has_layer("del") and f.size() > 5 and (f[0] as Vector2).is_equal_approx(Vector2(30.5, 12.5))
		and (f[1] as Vector2).is_equal_approx(Vector2(3, 3)) and float(f[5]) > 0.95,
		"update overlays: an `add` outlines its entity's footprint at once, at full strength; `del`, off, draws nothing: %s" % [f])
	ov.time_shift += 0.5
	var half: float = ov.drawn_at("add", 0)[5]
	ov.time_shift += 0.6
	var faded: float = ov.drawn_at("add", 0)[5]
	ov._process(0.016)
	check(absf(half - 0.5) < 0.06 and faded == 0.0 and ov.drawn_count("add") == 0,
		"update overlays: a flash fades over a second, then nothing of it is drawn: %.2f, %.2f, %d drawn" % [half, faded, ov.drawn_count("add")])
	# Removed and machine states: the footprint turned as the entity stands (`del` carries no direction).
	dm.set_update_kind("del", true)
	dm.set_update_kind("st", true)
	ov.on_message({"t": "del", "u": 6, "p": 2, "x": 20 * 256 + 128, "y": 5 * 256})
	ov.on_message({"t": "st", "l": [6, 1, 999, 0]})  # 999 has no record: nothing
	ov._process(0.016)
	var d: Array = ov.drawn_at("del", 0)
	var s: Array = ov.drawn_at("st", 0)
	var turned := func(a: Array) -> bool:
		return a.size() > 2 and (a[0] as Vector2).is_equal_approx(Vector2(20.5, 5.0)) and (a[1] as Vector2).is_equal_approx(Vector2(1.8, 1.0)) \
			and absf(absf(float(a[2])) - PI / 2.0) < 0.01
	check(turned.call(d) and turned.call(s) and ov.drawn_count("st") == 1 and UpdateOverlayScript.guess_dir(Vector2i(2, 1), Vector2(20.0, 4.5)) == 0,
		"update overlays: a splitter facing east is outlined 1 x 2, from its record (`st`) and guessed from where it stood (`del`): %s / %s" % [d, s])
	dm.set_update_kind("chunk", true)
	ov.on_message({"t": "chunk", "cx": -1, "cy": 0, "tiles": [], "parts": 1})
	ov._process(0.016)
	var ch: Array = ov.drawn_at("chunk", 0)
	check(ch.size() > 3 and (ch[0] as Vector2).is_equal_approx(Vector2(-16, 16)) and float((ch[1] as Vector2).x) > 31.0 and float(ch[3]) > 0.0,
		"update overlays: a chunk snapshot outlines the chunk's square: %s" % [ch])
	# Belt lanes: placed by the lane's meta (`bs` lm) when it came while on; else by belt_items.gd's, in its debug tap.
	dm.set_update_kind("sl", true)
	dm.set_update_kind("bre", true)
	dm.set_update_kind("hand", true)
	ov.on_message({"t": "bs", "k": 10, "lm": _bs_lane(9, 1, 256, 8, 2.0, 10.0, 1.0, 10.0), "sl": [9, 10, 1, 30, 1, 200, 1]})
	ov._process(0.016)
	var sl: Array = ov.drawn_at("sl", 0)
	check(belts.debug_tap.is_valid() and sl.size() > 3 and (sl[0] as Vector2).is_equal_approx(Vector2(1.5, 10.0)) and absf(float((sl[1] as Vector2).x) - 1.0) < 0.01
		and float(sl[3]) == 0.0, "update overlays: a lane read outlines the lane, a strip from its exit to its entry; a belt kind sets belt_items.gd's tap: %s" % [sl])
	_bs_feed(belts, 1000, {"lm": _bs_lane(17, 1, 256, 8, 6.0, 12.0, 5.0, 12.0)}, 1)
	ov.on_message({"t": "bs", "k": 1001, "sl": [17, 1001, 0]})  # its meta came before the overlay heard it
	ov._process(0.016)
	var waited: int = ov.waiting_count("sl") + ov._lane_wait.size()
	_bs_feed(belts, 1001, {}, 1)  # a job: the tap places it from belt_items.gd's lanes
	ov._process(0.016)
	var late: Array = ov.drawn_at("sl", 1)
	var job_gs := GDScript.new()
	job_gs.source_code = "extends RefCounted\nvar resend := [17]\n"
	job_gs.reload()
	ov.on_belt_job(job_gs.new())
	ov.on_message({"t": "ie", "k": 5, "l": [6, 99, 5, 9, 128, 777, 1, 1, 1]})
	ov.on_message({"t": "ie", "k": 7, "l": [6, 99, 5, 9, 128, 777, 1, 1, 1]})  # the same record again: once
	ov._process(0.016)
	# (belt_items.gd's own jobs may have asked for lanes too: the stand-in job's is looked for among them.)
	var drawn_near := func(id: String, at: Vector2) -> bool:
		for i in ov.drawn_count(id):
			if (ov.drawn_at(id, i)[0] as Vector2).is_equal_approx(at):
				return true
		return false
	var put: Array = ov.drawn_at("hand", 0)
	check(waited == 1 and late.size() > 0 and (late[0] as Vector2).is_equal_approx(Vector2(5.5, 12.0)) and drawn_near.call("bre", Vector2(5.5, 12.0))
		and ov.drawn_count("hand") == 1 and (put[0] as Vector2).is_equal_approx(Vector2(1.5, 10.0)),
		"update overlays: a lane known only to belt_items.gd waits for its next job; `bre` outlines what was asked; a hand's put (`ie` 6) its item's place, once: %s %s" % [late, put])
	dm.set_update_kind("mv", true)
	ov.on_message({"t": "mv", "z": 1, "l": [[100, 1, 2560, 2560, 0], [1, 0, 256, 0, 0]]})
	ov.on_message({"t": "mv", "z": 1, "l": [[100, 1, 2560, 2560, 0]]})  # again at once: not flashed again
	ov._process(0.016)
	var mv1: Array = ov.drawn_at("mv", 1)
	check(ov.drawn_count("mv") == 2 and mv1.size() > 0 and (mv1[0] as Vector2).is_equal_approx(Vector2(11, 10)) and (mv1[1] as Vector2).is_equal_approx(Vector2(3, 3)),
		"update overlays: movers (delta-coded `mv`) at their places, each flashed at most every %.2f s: %d drawn, %s" % [UpdateOverlayScript.REFLASH, ov.drawn_count("mv"), mv1])
	# The states. How lanes are drawn: four lanes (some maybe the lattice's), a belt with no lane in a far-icon chunk, one with none.
	var lm: Array = []
	for u in range(1, 4):
		lm.append_array(_bs_lane(u * 8 + 1, 1, 256, 8, ox + u + 1.0, oy, ox + u, oy))
	lm.append_array(_bs_lane(4 * 8 + 1, 1, 256, 8, ox + 5.0, oy, ox + 4.0, oy, INF, INF, -1))
	var reads: Array = []
	for u in range(4, 0, -1):
		var n := 3 if u == 4 else 4
		reads.append_array([u * 8 + 1, 2000, n])
		for q in n:
			reads.append_array([3000 + u * 8 + q, 1, (q + (1 if u == 4 else 0)) * 64 + 32, 1])
	_bs_feed(belts, 2000, {"lm": lm, "sl": reads}, 1)
	for k in range(2001, 2008):
		_bs_feed(belts, k, {}, 1)
	dm.set_update_kind("lanes", true)
	dm.set_update_kind("frozen", true)
	ov.sample_lanes(belts._state)
	var lat := 0
	for u in range(1, 5):
		if belts._state.lat.has(u * 8 + 1):
			lat += 1
	var modes: Dictionary = ov.stats.get("lanes", {})
	check(int(modes.get("lattice", -1)) == lat and int(modes.get("sim", -1)) == 4 - lat and int(modes.get("far", -1)) == 1 and int(modes.get("none", -1)) == 1
		and ov.drawn_count("lanes") == 6, "update overlays: how lanes are drawn, as belt_items.gd has them (%d of 4 the lattice's), a belt with no lane far icons or nothing: %s, %d drawn" % [lat, modes, ov.drawn_count("lanes")])
	# The lattice against the simulation, from a stand-in state: lane 41 standing while its items move, 49 sliding while they stand.
	var lattice_gs := GDScript.new()
	lattice_gs.source_code = "extends RefCounted\nvar v := {}\nfunc drawn_speed(key: int) -> int:\n\treturn int(v.get(key, -1))\n"
	lattice_gs.reload()
	var sim_gs := GDScript.new()
	sim_gs.source_code = "extends RefCounted\nvar f := {}\nfunc lane_fronts(keys: PackedInt64Array) -> PackedInt32Array:\n\tvar out := PackedInt32Array()\n\tfor k in keys:\n\t\tout.append_array(f.get(k, PackedInt32Array([-1, 0, 0])))\n\treturn out\n"
	sim_gs.reload()
	var st_gs := GDScript.new()
	st_gs.source_code = "extends RefCounted\nvar lanes := {}\nvar lat := {}\nvar sim\nvar lattice\n"
	st_gs.reload()
	var fake = st_gs.new()
	fake.sim = sim_gs.new()
	fake.lattice = lattice_gs.new()
	for key in [41, 49, 57]:
		fake.lanes[key] = PackedInt32Array([1, 256, 8, roundi((ox + 1.0) * 256), roundi(oy * 256), roundi((ox + 0.5) * 256), roundi(oy * 256), roundi(ox * 256), roundi(oy * 256)])
		fake.lat[key] = true
	fake.lattice.v = {41: 0, 49: 8, 57: 8}
	fake.sim.f = {41: PackedInt32Array([10, 8, 3]), 49: PackedInt32Array([10, 0, 3]), 57: PackedInt32Array([10, 8, 3])}
	ov.sample_frozen(fake)
	var first: Array = ov.stats.get("frozen", [])
	ov.time_shift += 0.6
	ov.sample_frozen(fake)
	var then: Array = ov.stats.get("frozen", [])
	var pulsing := 0
	for i in ov.drawn_count("frozen"):
		if float(ov.drawn_at("frozen", i)[6]) < -1.5:
			pulsing += 1
	var classes: Array = UpdateOverlayScript.lattice_against_sim(PackedInt64Array([1, 2, 3, 4]), PackedInt32Array([0, 8, 0, -1]),
		PackedInt32Array([5, 8, 2, 5, 0, 2, -1, 0, 0, 5, 8, 2]))
	check(first == [1, 0, 1] and then == [1, 1, 1] and pulsing == 1 and Array(classes[0]) == [1] and Array(classes[1]) == [2],
		"update overlays: the lattice standing while the simulation moves (pulsing once held %.1f s) and sliding while it stands: %s then %s, %d pulsing, %s" % [UpdateOverlayScript.HELD_SEC, first, then, pulsing, classes])
	# The subscription: its square, a chunk still to come (on its way: outlined too), the view's direction.
	w._sq_center = Vector2i(9, 9)
	w._sq_radius = 3
	w._subscribed = [Vector2i(9, 9), Vector2i(12, 9)]
	w._coming = {Vector2i(12, 9): true}
	w._sent_sector = 0
	dm.set_update_kind("sub", true)
	ov._subscription()
	var square: Array = ov.drawn_at("sub", 0)
	check(ov.stats.get("sub", []) == [2, 1, 1] and ov.drawn_count("sub") == 4 and square.size() > 1
		and (square[0] as Vector2).is_equal_approx(Vector2(304, 304)) and (square[1] as Vector2).is_equal_approx(Vector2(224, 224)),
		"update overlays: the subscription's square, the chunk still to come and on its way, the view's direction: %s, %d drawn" % [ov.stats.get("sub"), ov.drawn_count("sub")])
	# The legend: a kind's updates in the last second.
	ov.roll()
	ov.on_message({"t": "st", "l": [6, 1, 5, 0, 6, 0]})
	ov.roll()
	ov._update_legend()
	var legend: String = ov.legend_text()
	check(ov.rate_of("st") == 3 and legend.contains("Machine states  3/s") and legend.contains("Lattice standing, simulation moving: 1") and legend.contains("far icons: 1"),
		"update overlays: the legend counts each kind's updates a second and the states': %s" % legend.replace("\n", " | "))
	# The flash shader parses (its uniforms are listed); a copy with an error doesn't.
	var good := Shader.new()
	good.code = FileAccess.get_file_as_string("res://shaders/update_flash.gdshader")
	var bad := Shader.new()
	bad.code = good.code.replace("ALPHA = a;", "ALPHA = a +;")
	var good_u: Array = good.get_shader_uniform_list().map(func(u: Dictionary) -> String: return str(u["name"]))
	var bad_u: Array = bad.get_shader_uniform_list()
	check(good_u.has("now") and good_u.has("fade") and good_u.has("fill") and bad_u.is_empty(),
		"update overlays: the flash shader parses (uniforms %s); a broken copy doesn't (%d)" % [good_u, bad_u.size()])
	# Every kind off: no node, no handler, no tap.
	(dm.find_child("Updates_off", true, false) as Button).pressed.emit()
	await get_tree().process_frame
	var handlers := 0
	for con: Dictionary in Bridge.message_received.get_connections():
		var o = (con["callable"] as Callable).get_object()
		if o != null and o.get_script() == UpdateOverlayScript:
			handlers += 1
	check(not is_instance_valid(ov) and dm.update_overlay() == null and handlers == 0 and not belts.debug_tap.is_valid()
		and w.find_child("UpdateOverlay", true, false) == null and not (dm.find_child("Upd_lanes", true, false) as CheckBox).button_pressed,
		"update overlays: with every kind off nothing is left (no node, no handler on the Bridge, no belt tap, boxes unticked)")
	dm.main = was_main
	for n in [w, belts, far_lanes, stand]:
		n.queue_free()
	await get_tree().process_frame


## Items in 3D's cap and 3D grass follow the camera drawing when it isn't Zenith's own view round the
## character (view_priority.gd): a camera away from the character gives the models to the items in
## its view, nearest it first, none behind it; in the normal view the square's centre decides, as before.


func _view_priority() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(640, 360)
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var cam := Camera3D.new()
	cam.fov = 35.0
	vp.add_child(cam)
	cam.global_transform = Transform3D(Basis(Vector3.RIGHT, -deg_to_rad(30.0)), Vector3(200, 20, 200))
	var planes := ViewPriority.planes(cam)
	# Five items round the character at the origin, three ahead of the camera, one behind it.
	var points: Array[Vector3] = []
	for i in 5:
		points.append(Vector3(i, 0, 0))
	points.append_array([Vector3(200, 0, 170), Vector3(200, 0, 160), Vector3(205, 0, 150), Vector3(200, 0, 230)])
	var by_cam := PackedFloat32Array()
	var by_square := PackedFloat32Array()
	var none := PackedByteArray()
	for p in points:
		by_cam.append(ViewPriority.view_distance_sq(p, cam.global_position, planes, ViewPriority.MARGIN))
		by_square.append(Vector2(p.x, p.z).distance_squared_to(Vector2.ZERO))
		none.append(0)
	var want := ViewPriority.choose(by_cam, none, 2, 1.5)
	check(Array(want) == [0, 0, 0, 0, 0, 1, 1, 0, 0],
		"Items in 3D: a camera away from the character gives the cap's models to the items in its view, nearest it first: %s" % [Array(want)])
	check(by_cam[8] == INF and by_cam[0] == INF, "nothing behind the camera or out of its view counts: %s %s" % [by_cam[8], by_cam[0]])
	check(Array(ViewPriority.choose(by_cam, none, 20000, 1.5)) == [0, 0, 0, 0, 0, 1, 1, 1, 0], "under the cap every item in view is a model, none outside")
	check(Array(ViewPriority.choose(by_square, none, 2, 1.5)) == [1, 1, 0, 0, 0, 0, 0, 0, 0], "and round the square's centre (the normal view) as before")
	var kept := PackedByteArray([0, 0, 0, 0, 0, 1, 1, 1, 0])
	var near_edge := by_cam.duplicate()
	near_edge[7] = pow(sqrt(by_cam[6]) + 1.0, 2.0)
	check(Array(ViewPriority.choose(near_edge, kept, 2, 1.5)) == [0, 0, 0, 0, 0, 1, 1, 1, 0], "a model just past the cap's edge keeps its look (no flipping)")
	var rig := CameraRig.new()
	check(not ViewPriority.camera_led(rig) and ViewPriority.grass_centre(rig, cam, Vector2(3, 4), 30.0) == Vector2(3, 4),
		"the normal view: the character leads, 3D grass is centred on it")
	rig.first_person = true
	var g := ViewPriority.grass_centre(rig, cam, Vector2(3, 4), 30.0)
	check(ViewPriority.camera_led(rig) and absf(g.x - 200.0) < 0.5 and g.y < 200.0 - 15.0 and g.y > 200.0 - 100.0,
		"first person (and an add-on's camera, the remote view): 3D grass is centred in front of the camera: %s" % g)
	rig.free()
	vp.queue_free()


## The console (chat_window.gd, console_commands.gd): each command goes where it can run, Lua
## commands' game.player is the bridge's player, Tab completes, Up and Down go back through what
## was typed, /clear, /color, /ignore.


func _console(hud: Hud) -> void:
	var ui = hud.ui
	var m = ui.model
	var chat = ui.chat
	var con = chat.console
	var old_rcon: Callable = con.rcon
	var old_has: Callable = con.has_rcon
	sent()
	check(ConsoleCommands.canonical("c") == "command" and ConsoleCommands.canonical("SC") == "silent-command"
		and ConsoleCommands.canonical("nope") == "", "console: aliases name their command")
	check(ConsoleCommands.complete("/evo") == ["/evolution ", []], "Tab completes a unique command: %s" % [ConsoleCommands.complete("/evo")])
	var many: Array = ConsoleCommands.complete("/un")
	check(str(many[0]) == "/un" and "unban" in many[1] and "unlock-tips" in many[1], "several: the shared start and the choices: %s" % [many])
	check(ConsoleCommands.complete("/cheat al") == ["/cheat al", []], "no completion past the name")
	var lua: String = ConsoleCommands.rewrite_lua("game.player.insert{name='iron-plate'} game.player.print(#game.players) game.print('x')")
	check(lua == "__zp.insert{name='iron-plate'} __zprint(#game.players) __zgprint('x')", "game.player becomes the bridge's player, game.players stays: %s" % lua)
	var cmd: String = ConsoleCommands.lua_command("/c __factorio-3d-bridge__ game.player.name")
	check(cmd.begins_with("/c __factorio-3d-bridge__ local __zr = ") and cmd.contains("pcall(function() __zp.name\n")
		and cmd.count("\n") == 1, "the prelude goes after a mod's name, on the user's first line")
	# Not connected over RCON.
	con.has_rcon = func() -> bool: return false
	var r: String = await con.run("/editor")
	check(r.contains("Ctrl+F9"), "/editor: press Ctrl+F9 for Factorio itself: %s" % r)
	r = await con.run("/kick bob")
	check(r.contains("needs RCON"), "/kick needs RCON: %s" % r)
	r = await con.run("/c game.player.print(1)")
	check(r.contains("needs RCON") and sent_one("cmd").is_empty(), "Lua never goes through the bridge")
	var answer := func(lines: Array) -> void:
		var reply := func() -> void: m.handle({"t": "cmdr", "id": m._command_id, "l": lines})
		get_tree().create_timer(0.05).timeout.connect(reply)
	answer.call(["2.1.23"])
	r = await con.run("/version")
	check(r == "2.1.23" and sent_one("cmd").get("text") == "/version", "/version without RCON: the bridge answers (cmd, cmdr): %s" % r)
	# Over RCON.
	var to_rcon: Array = []
	con.has_rcon = func() -> bool: return true
	con.rcon = func(c: String) -> String:
		to_rcon.append(c)
		return "from rcon"
	r = await con.run("/time")
	check(r == "from rcon" and to_rcon[-1] == "/time", "/time goes over RCON when there is one")
	r = await con.run("/sc game.player.surface.name")
	check(str(to_rcon[-1]).begins_with("/sc local __zr") and str(to_rcon[-1]).contains("__zp.surface.name"), "/sc goes over RCON with the prelude")
	answer.call(["Researched every technology"])
	r = await con.run("/cheat")
	check(r == "Researched every technology" and to_rcon.size() == 2, "/cheat goes to the bridge even with RCON (Factorio's does nothing there)")
	r = await con.run("/my-mods-command x")
	check(to_rcon[-1] == "/my-mods-command x", "an unknown command goes to the server")
	r = await con.run("/help")
	check(r.contains("In Factorio itself (Ctrl+F9): ") and r.contains("/editor"), "/help lists the commands by where they run")
	r = await con.run("/h mc")
	check(r.contains("how long") and r.contains("over RCON"), "/help <alias> says what it does: %s" % r)
	sent()
	await con.run("/color red")
	check(sent_one("set_char_color").get("c") == [208.0, 6.0, 0.0], "/color red sets the character's colour (Factorio's red)")
	await con.run("/color 0 255 0")
	check(sent_one("set_char_color").get("c") == [0.0, 255.0, 0.0], "/color r g b")
	r = await con.run("/color nonsense")
	check(r.begins_with("/color"), "/color without a colour says how")
	# The console line: history, Tab, /clear, /ignore.
	m.handle({"t": "chat", "from": "Grief", "text": "spam"})
	chat._refresh()
	check(_texts(chat).has("Grief: spam"), "a chat line shows")
	await con.run("/ignore Grief")
	chat._refresh()
	check(not _texts(chat).has("Grief: spam"), "/ignore hides their lines")
	await con.run("/unignore Grief")
	await con.run("/clear")
	chat._refresh()
	check(not _texts(chat).has("Grief: spam") and chat._lines.get_child_count() == 0, "/clear empties the console")
	chat._history.clear()
	await chat._submit("first")
	await chat._submit("/time")
	chat.open()
	chat._input.text = "draft"
	chat.browse(1)
	check(chat._input.text == "/time", "Up: the last line typed")
	chat.browse(1)
	chat.browse(1)
	check(chat._input.text == "first", "Up again: the one before, and no further")
	chat.browse(-1)
	chat.browse(-1)
	check(chat._input.text == "draft", "Down past the newest: the line being typed")
	chat._input.text = "/chea"
	var tab := InputEventKey.new()
	tab.physical_keycode = KEY_TAB
	tab.pressed = true
	chat._on_input_key(tab)
	check(chat._input.text == "/cheat ", "Tab on the line completes it")
	chat.close()
	con.rcon = old_rcon
	con.has_rcon = old_has
	sent()


## K1, K2: Alt-mode draws the modules in machines and the science packs in labs in rows, as the
## prototype's icons_positioning lays them out (`eprops` isq, `am`), and the machine's own icon where
## its icon_draw_specification puts it (`eprops` ids): an assembling machine 3 with four modules (2.1's
## defaults for a 3-wide machine), a lab with seven packs and two modules (Space Age's lab), a beacon's
## only while the mouse is on it, each quality's mark, first person's quads.


func _debug_sim_switches(hud: Hud) -> void:
	var dm = hud.ui.debug_menu
	var ids: Array = BeltItemsScript.LIVE.map(func(l: Array) -> String: return str(l[0]))
	dm._open_tab(dm.TABS.find("Simulation"))
	var boxes := {}
	for id: String in ids:
		var b = dm.find_child("Sim_" + id, true, false)
		if b is CheckBox:
			boxes[id] = b
	check(dm.current_tab() == "Simulation" and dm.find_child("SimulationPage", true, false) != null and boxes.size() == ids.size()
		and ids.has("early_stop") and ids.has("ahead_auto") and ids.has("rescue_seen")
		and boxes.values().all(func(b: CheckBox) -> bool: return b.button_pressed and b.tooltip_text != ""),
		"sim switches: the debug menu's Simulation tab, a ticked box with a tooltip per belt fix (%d of %d)" % [boxes.size(), ids.size()])
	# The command line's value is the start value.
	BeltItemsScript.read_flags(PackedStringArray(["--belt-draw-early-stop=off", "--belt-sim-ahead=30", "--belt-sim-rescue-seen=off"]))
	dm._sync_sim()
	var start: Label = dm.find_child("SimStart_early_stop", true, false)
	check(not boxes["early_stop"].button_pressed and not boxes["ahead_auto"].button_pressed and not boxes["rescue_seen"].button_pressed
		and boxes["early"].button_pressed and not BeltItemsScript.live_started("early_stop") and start.text == "started off" and BeltItemsScript._ahead_fixed == 30,
		"sim switches: each box starts as the command line set it (%s, fixed lead %d)" % [start.text, BeltItemsScript._ahead_fixed])
	BeltItemsScript.Job.early_stop = true
	BeltItemsScript.Job.ahead_auto = true
	BeltItemsScript.Job.ahead = BeltItemsScript.AHEAD
	BeltItemsScript.Job.rescue_seen = true
	BeltItemsScript.read_flags(PackedStringArray())
	dm._sync_sim()
	# A public build: nothing changes.
	Settings.dev_tools_override = 0
	boxes["early_stop"].button_pressed = false
	Settings.dev_tools_override = -1
	check(boxes["early_stop"].button_pressed and BeltItemsScript._live.is_empty() and BeltItemsScript.Job.early_stop,
		"sim switches: a public build switches nothing (the box goes back)")
	BeltItemsScript.Job.view_cull = false
	var was_gd: bool = BeltItemsScript.State.force_gd
	var was_dn: bool = BeltItemsScript.State.draw_native
	var twins := [[true, false]]
	if ClassDB.class_exists("BeltSimNative"):
		twins.append([false, false])
		twins.append([false, true])
	for tw: Array in twins:
		BeltItemsScript.State.force_gd = tw[0]
		BeltItemsScript.State.draw_native = tw[1]
		var items = BeltItemsScript.new()
		add_child(items)
		items._sync = true
		var ox := 0.0
		var oy := 10.0
		var lm: Array = _bs_lane(9, 1, 1024, 8, ox, oy, ox + 4.0, oy)
		_bs_feed(items, 1000, {"lm": lm, "sl": [9, 1000, 2, 10, 1, 0, 1, 11, 1, 600, 1]})
		var what := "%s, %s records" % ["belt_sim.gd" if tw[0] else "BeltSimNative", "BeltDrawNative" if items._state.draw != null else "GDScript"]
		var sim = items._state.sim
		# Every box off: nothing a job reads changes until the next job's start.
		for id: String in ids:
			boxes[id].button_pressed = false
		var waiting: bool = BeltItemsScript.Job.early_stop and BeltItemsScript.Job.ahead_auto and BeltItemsScript.Job.rescue_seen and BeltItemsScript.Job.early and BeltItemsScript.Job.take_edge 			and sim.get("rescue_seen") and sim.get("take_edge") and not BeltItemsScript.live_on("early_stop")
		var label_text: String = (dm.find_child("SimStart_early_stop", true, false) as Label).text
		_bs_feed(items, 1001, {}, 1)
		var taken: bool = not BeltItemsScript.Job.early_stop and not BeltItemsScript.Job.ahead_auto and BeltItemsScript.Job.ahead == BeltItemsScript.AHEAD and not BeltItemsScript.Job.rescue_seen 			and not BeltItemsScript.Job.early and not BeltItemsScript.Job.take_edge and sim.get("rescue_seen") == false and sim.get("take_edge") == false and BeltItemsScript._live.is_empty()
		check(waiting and taken and label_text == "started on, changed",
			"sim switches (%s): the boxes wait for the next job, which takes them into the job's statics and the simulation's own (%s %s, %s)" % [what, waiting, taken, label_text])
		# Early stop off from the menu mid-run: drawn on past the stop to the line's end, as --belt-draw-early-stop=off.
		for id: String in ids:
			if id != "early_stop":
				boxes[id].button_pressed = true
		var at_stop = null
		for k in range(1002, 1075):
			_bs_feed(items, k, {}, 1)
			if items._drawn < 1066.5:
				var drawn: float = items._drawn
				items._drawn = 1080.0
				at_stop = items.position_of(11)
				items._drawn = drawn
		var x := -1.0 if at_stop == null else (at_stop as Vector3).x
		check(x >= 0.0 and x < ox + 0.1 and BeltItemsScript.Job.ahead_auto and sim.get("rescue_seen") == true,
			"sim switches (%s): early stop off from the menu, the item drawn on past the stop (x %.3f); the rest back on" % [what, x])
		boxes["early_stop"].button_pressed = true
		_bs_feed(items, 1075, {}, 1)
		check(BeltItemsScript.Job.early_stop and BeltItemsScript._live.is_empty(), "sim switches (%s): early stop back on at the next job" % what)
		items.queue_free()
	BeltItemsScript.State.force_gd = was_gd
	BeltItemsScript.State.draw_native = was_dn
	BeltItemsScript.Job.view_cull = true
	dm._open_tab(0)


## K19 (owner's video: "belt items all of a sudden jump around ... an item reaching the end and causing it to
## check all the belts again"): a line of six belts that ends, packed with one kind from its end back, an
## inserter over belt 3 taking the front item of that belt's lane. The bridge reads the lanes round the hand on
## the take's tick and sends them before the hand's event (`bs`, then `ie`), the lane behind first, each a
## tick into closing the hole. Drawn, belt_sim.gd and its C++ twin alike: the taken item leaves and stays
## gone, 23 items are left, none ever goes back, none ends closer than a gap to another; and the lattice of the
## lanes behind stays standing while the line closes one gap (--belt-draw-lattice-settle), its slots where
## they were. With --belt-sim-take-line=off the taken item stays on the belt (the old way: the read of the
## lane behind moved it across the belt's edge and the take found nothing); with the lattice's settle off the
## lanes behind take the belt's speed for the closing (each then jumped to the map's phase and back).


func _debug_light_sliders(hud: Hud) -> void:
	var dm = hud.ui.debug_menu
	var Lk := preload("res://scripts/world/looks.gd")
	Lk.pbr_tune.clear()
	dm._open_tab(dm.TABS.find("Lighting"))
	var fill: HSlider = dm.find_child("Light_pbr_fill", true, false)
	var lobe: HSlider = dm.find_child("Light_pbr_sun_lobe", true, false)
	check(dm.current_tab() == "Lighting" and fill != null and lobe != null and is_equal_approx(fill.value, Lk.PBR_FILL) and dm.find_child("Light_pbr_metal", true, false) != null
		and dm.find_child("LightReset_pbr_env", true, false) != null and dm.find_child("Light_directional", true, false) != null,
		"lighting tab: sliders at their defaults")
	var looks = Lk.new()
	fill.value = 0.8
	lobe.value = 4.0
	dm.find_child("Light_directional", true, false).button_pressed = false
	check(is_equal_approx(looks.pbr_light_shares({}).x, 0.8) and is_equal_approx(float(Lk.pbr_tune["pbr_sun_lobe"]), 4.0)
		and dm.light_text().contains("pbr_fill=0.800") and dm.light_text().contains("pbr_directional=0")
		and is_equal_approx(looks.pbr_env_k({}), Lk.PBR_ENV),
		"lighting tab: moving a slider changes the global (%s)" % dm.light_text())
	dm.find_child("LightReset_pbr_fill", true, false).pressed.emit()
	check(is_equal_approx(fill.value, Lk.PBR_FILL) and not Lk.pbr_tune.has("pbr_fill"), "lighting tab: Reset puts the default back")
	Settings.dev_tools_override = 0
	dm.set_light("pbr_env", 0.9)
	Settings.dev_tools_override = -1
	check(not Lk.pbr_tune.has("pbr_env"), "lighting tab: a public build changes nothing")
	Lk.pbr_tune.clear()
	looks.free()


## The Lighting tab's live sliders: each moves its target (environment, sun, shadows, contact shading), Reset puts it
## back, a public build changes nothing, Copy values lists them.


func _debug_live_sliders(hud: Hud) -> void:
	var dm = hud.ui.debug_menu
	var Lk := preload("res://scripts/world/looks.gd")
	var Cs := preload("res://scripts/world/contact_shade.gd")
	Lk.light_tune.clear()
	var env := Environment.new()
	env.ssao_enabled = true
	env.ssao_radius = 0.7
	env.ssao_intensity = 1.6
	env.ssil_enabled = false
	env.ambient_light_energy = 0.6
	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.1
	sun.shadow_bias = 0.05
	sun.shadow_blur = 1.0
	var shadows = preload("res://scripts/world/sun_shadows.gd").new()
	dm.light_env = env
	dm.light_sun = sun
	dm.light_shadows = shadows
	dm._open_tab(dm.TABS.find("Lighting"))
	var bad := ""
	var moved := {"ssao_radius": [0.7, 2.0, func() -> float: return env.ssao_radius],
		"ssao_intensity": [1.6, 3.0, func() -> float: return env.ssao_intensity],
		"ssao_power": [env.ssao_power, 4.0, func() -> float: return env.ssao_power],
		"ssao_detail": [env.ssao_detail, 0.9, func() -> float: return env.ssao_detail],
		"ssao_light_affect": [env.ssao_light_affect, 0.4, func() -> float: return env.ssao_light_affect],
		"ssao_horizon": [env.ssao_horizon, 0.3, func() -> float: return env.ssao_horizon],
		"ssao_sharpness": [env.ssao_sharpness, 0.2, func() -> float: return env.ssao_sharpness],
		"ssil_radius": [env.ssil_radius, 9.0, func() -> float: return env.ssil_radius],
		"ssil_intensity": [env.ssil_intensity, 2.5, func() -> float: return env.ssil_intensity],
		"ambient_energy": [0.6, 1.9, func() -> float: return env.ambient_light_energy],
		"sun_energy": [1.1, 3.0, func() -> float: return sun.light_energy],
		"shadow_bias": [0.05, 0.4, func() -> float: return sun.shadow_bias],
		"shadow_normal_bias": [sun.shadow_normal_bias, 5.0, func() -> float: return sun.shadow_normal_bias],
		"shadow_blur": [1.0, 4.0, func() -> float: return sun.shadow_blur],
		"contact_strength": [0.47, 0.9, func() -> float: return _shader_now(Cs.material(), "rim_dark")],
		"contact_rim": [0.06, 0.12, func() -> float: return _shader_now(Cs.material(), "rim_falloff")],
		"contact_patch": [Cs.PATCH_EDGE, 0.3, func() -> float: return float(Cs.material().get_shader_parameter("patch_reach"))],
		"ground_rough": [0.0, 0.2, func() -> float: return _shader_now(Visuals.terrain_material(), "surface_roughness_add")]}
	for key: String in moved:
		var sl: HSlider = dm.find_child("Live_" + key, true, false)
		var was: float = moved[key][0]
		var reader: Callable = moved[key][2]
		if sl == null:
			bad += " " + key + "(no slider)"
			continue
		if not is_equal_approx(sl.value, was):
			bad += " %s(default %.3f not %.3f)" % [key, sl.value, was]
		sl.value = moved[key][1]
		if not is_equal_approx(reader.call(), moved[key][1]) or not Lk.light_tune.has(key):
			bad += " %s(move %.3f)" % [key, reader.call()]
		dm.find_child("LiveReset_" + key, true, false).pressed.emit()
		if not is_equal_approx(reader.call(), was) or Lk.light_tune.has(key) or not is_equal_approx(sl.value, was):
			bad += " %s(reset %.3f)" % [key, reader.call()]
	check(bad == "", "lighting tab: every live slider moves its target and Reset returns it:" + bad)
	for key: String in ["ssao_enabled", "ssil_enabled"]:
		var box: CheckBox = dm.find_child("Live_" + key, true, false)
		var before: bool = env.get(key)
		box.button_pressed = not before
		var moved_ok: bool = env.get(key) == (not before)
		var held: bool = Lk.light_tune.has(key)
		dm.find_child("LiveReset_" + key, true, false).pressed.emit()
		check(box != null and moved_ok and held and env.get(key) == before and not Lk.light_tune.has(key), "lighting tab: %s toggle moves and its Reset gives it back" % key)
		# The game's own switch (Settings > Graphics) works again: nothing re-asserts the old click.
		env.set(key, not before)
		Lk.apply_light_tune(env, sun)
		check(env.get(key) == (not before), "lighting tab: after Reset the game sets %s again" % key)
		env.set(key, before)
		dm._sync_live()
	dm.set_live("sun_energy", 2.0)
	sun.light_energy = 0.3
	Lk.apply_light_tune(env, sun)
	check(is_equal_approx(sun.light_energy, 2.0) and dm.light_text().contains("sun_energy=2.000"), "lighting tab: an override wins over the game's own value each frame (%s)" % dm.light_text())
	dm.reset_live("sun_energy")
	Settings.dev_tools_override = 0
	dm.set_live("ssao_radius", 3.3)
	Settings.dev_tools_override = -1
	check(not Lk.light_tune.has("ssao_radius") and is_equal_approx(env.ssao_radius, 0.7), "lighting tab: a public build changes nothing (live sliders)")
	Lk.light_tune.clear()
	dm.light_env = null
	dm.light_sun = null
	dm.light_shadows = null
	sun.free()
	shadows.free()


## A shader parameter's value, or the shader's own default while none is set (the engine gives no default back).


func _shader_now(m: ShaderMaterial, u: String) -> float:
	var v = m.get_shader_parameter(u)
	return float(v) if v != null else float({"rim_dark": 0.47, "rim_falloff": 0.06, "surface_roughness_add": 0.0}[u])
