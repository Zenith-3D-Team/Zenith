extends SceneTree
## M2 (--native-rail-height): MoversNative.rail_heights, fed by movers.gd's copy of world.gd's per-chunk
## rail index (_rail_heights_native), against world.gd's own rail_height on a real world.gd instance.
## Chunks hold straight, half-diagonal, curved, elevated rails and ramps in all four directions, over
## negative and positive chunk coordinates; 20,000 random points with random `was` heights must give the
## same height both ways (exactly). Then two movers layers (native rails on and off) run 60 trains over
## the rails for 300 frames through _process_movers: heights and pitches equal every frame. Then a chunk's rails change (a new index) and a chunk goes away: the
## copy follows world.gd. Prints both ways' time for the lookups. Headless, no scene.
##
##   godot --headless --audio-driver Dummy --path client --log-file <abs> -s res://tests/rail_height_native_test.gd

const Movers := preload("res://scripts/world/movers.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")

const POINTS := 20000
const TYPES := ["straight-rail", "half-diagonal-rail", "curved-rail-a", "curved-rail-b", "elevated-straight-rail",
	"elevated-half-diagonal-rail", "elevated-curved-rail-a", "elevated-curved-rail-b", "legacy-straight-rail",
	"legacy-curved-rail", "rail-ramp", "assembling-machine"]

var _fails := 0
## Loaded at run time: world.gd needs the autoloads (Bridge), which a preload in a -s script runs before.
var World: Script
var ChunkView: Script
var _world: Node
var _movers: Node
var _rng := RandomNumberGenerator.new()


func _initialize() -> void:
	_rng.seed = 2417
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
		if _fails <= 20:
			print("FAIL: ", what)


func _run() -> void:
	if ModelLibrary.elevated_old:
		print("rail_height_native_test: --elevated-trains=old (GDScript only), skipped")
		quit(0)
		return
	World = load("res://scripts/world/world.gd")
	ChunkView = load("res://scripts/world/chunk_view.gd")
	_world = World.new()
	var id := 1
	for t: String in TYPES:
		var p := ProtoDB.EntityProto.new()
		p.id = id
		p.name = t
		p.type = t
		_world.protos.entities[id] = p
		id += 1
	for cy in range(-2, 2):
		for cx in range(-2, 2):
			_fill_chunk(Vector2i(cx, cy), 40)
	# Ramps in all four directions, a ground line crossing under an elevated one.
	for d in 4:
		_add(Vector2(-20.0 + d * 12.0, 6.0), TYPES.find("rail-ramp") + 1, d * 4)
	for i in 12:
		_add(Vector2(-30.0 + i * 2.0, -10.0), 1, 4)
		_add(Vector2(-30.0 + i * 2.0, -10.0), 5, 4)
	_movers = Movers.new()
	_movers.world = _world
	if not _movers._rail_native_ready():
		print("rail_height_native_test: MoversNative.rail_heights missing (DLL not rebuilt?)")
		quit(1)
		return
	_compare("random", POINTS)
	# Rails change in one chunk: world.gd builds it a new index the next time it is asked, the copy follows.
	var cv: Object = _world.chunks[Vector2i(-1, 0)]
	cv.entities.clear()
	_fill_chunk(Vector2i(-1, 0), 25)
	cv.content_rev += 1
	cv.rail_grid = []
	_compare("changed chunk", POINTS / 4)
	# A chunk goes away (unloaded): its rails no longer count.
	var gone: Node = _world.chunks[Vector2i(0, -1)]
	_world.chunks.erase(Vector2i(0, -1))
	_compare("removed chunk", POINTS / 4)
	_check(int(_movers._rail_nat.call("rail_chunk_count")) > 0, "chunks copied")
	_loop_parity()
	print("rail_height_native_test: %d failures" % _fails)
	_movers.free()
	gone.free()
	for v: Node in _world.chunks.values():
		v.free()
	_world.free()
	quit(1 if _fails > 0 else 0)


func _fill_chunk(c: Vector2i, n: int) -> void:
	for i in n:
		var at := Vector2(c * 32) + Vector2(_rng.randf_range(0.0, 32.0), _rng.randf_range(0.0, 32.0))
		at = (at * 2.0).round() * 0.5
		_add(at, _rng.randi_range(1, TYPES.size()), _rng.randi_range(0, 15))


func _add(at: Vector2, proto_id: int, dir: int) -> void:
	var c := Vector2i(floori(at.x / 32.0), floori(at.y / 32.0))
	var cv: Object = _world.chunks.get(c)
	if cv == null:
		cv = ChunkView.new()
		cv.coord = c
		_world.chunks[c] = cv
	var r: Object = World.Rec.new()
	r.key = "r:%d" % cv.entities.size()
	r.proto_id = proto_id
	r.pos = at
	r.dir = dir
	r.chunk = c
	cv.entities[r.key] = r


func _compare(label: String, n: int) -> void:
	var points := PackedVector2Array()
	var was := PackedFloat64Array()
	var levels := [0.0, ModelLibrary.ELEVATED_TRACK, 2.0, 1.5, 3.3]
	for i in n:
		points.push_back(Vector2(_rng.randf_range(-70.0, 70.0), _rng.randf_range(-70.0, 70.0)))
		was.push_back(float(levels[_rng.randi() % levels.size()]))
	var t0 := Time.get_ticks_usec()
	var want := PackedFloat64Array()
	want.resize(n)
	for i in n:
		want[i] = _world.rail_height(points[i], was[i])
	var t_gd := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	var got: PackedFloat64Array = _movers._rail_heights_native(points, was)
	var t_nat := Time.get_ticks_usec() - t0
	var diff := 0
	var nonzero := 0
	var ramps := 0
	for i in n:
		if want[i] != got[i]:
			diff += 1
			_check(false, "%s: point %s was %.2f: world %.6f native %.6f" % [label, points[i], was[i], want[i], got[i]])
		if want[i] != was[i]:
			nonzero += 1
		if want[i] > 0.0 and want[i] != ModelLibrary.ELEVATED_TRACK and want[i] != was[i]:
			ramps += 1
	_check(nonzero > n / 20, "%s: rails found under enough points (%d)" % [label, nonzero])
	_check(ramps > 0, "%s: some points on a ramp" % label)
	print("%s: %d points, %d differ, %d on rails, %d on ramps; world.rail_height %.2f us a point, native %.2f us (sync included)" \
			% [label, n, diff, nonzero, ramps, float(t_gd) / n, float(t_nat) / n])


## Two movers layers over the same world, --native-rail-height on and off: 60 rolling stock driven across
## the rails and ramps (east, west, north, south) through _process_movers; their height, rail_h and pitch
## must be equal every frame.
func _loop_parity() -> void:
	var on: Node = Movers.new()
	var off: Node = Movers.new()
	on.native_rail = true
	off.native_rail = false
	var trains := 60
	for l: Node in [on, off]:
		l.skip_still = false
		l.world = _world
		for i in trains:
			var m := Movers.Mover.new()
			m.unit = i + 1
			m.on_rails = true
			m.node = Node3D.new()
			m.node.position = _train_at(i, 0)
			m.node.rotation.y = _train_yaw(i)
			m.yaw_goal = _train_yaw(i)
			l._node_movers[m.unit] = m
	var differ := 0
	var lifted := 0
	var t_on := 0
	var t_off := 0
	for f in 300:
		for l: Node in [on, off]:
			for i in trains:
				var m: Movers.Mover = l._node_movers[i + 1]
				var p := _train_at(i, f)
				m.node.position = Vector3(p.x, m.node.position.y, p.z)
		var t0 := Time.get_ticks_usec()
		on._process_movers(1.0 / 60.0)
		t_on += Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		off._process_movers(1.0 / 60.0)
		t_off += Time.get_ticks_usec() - t0
		for i in trains:
			var a: Movers.Mover = on._node_movers[i + 1]
			var b: Movers.Mover = off._node_movers[i + 1]
			if a.node.position != b.node.position or a.node.rotation != b.node.rotation or a.rail_h != b.rail_h:
				differ += 1
				_check(false, "loop frame %d train %d: %s %s vs %s %s" % [f, i, a.node.position, a.node.rotation, b.node.position, b.node.rotation])
			if a.node.position.y > 0.01:
				lifted += 1
	_check(lifted > 100, "trains ride above the ground (%d train-frames)" % lifted)
	print("loop: 300 frames x %d trains, %d differ, %d lifted; _process_movers native %.1f us a frame, GDScript %.1f us" \
			% [trains, differ, lifted, float(t_on) / 300.0, float(t_off) / 300.0])
	for l: Node in [on, off]:
		for m: Movers.Mover in l._node_movers.values():
			m.node.free()
		l._node_movers.clear()
		l.free()


static func _train_at(i: int, f: int) -> Vector3:
	var along := fposmod(i * 7.3 + f * 0.37, 130.0) - 65.0
	var across := float((i * 13) % 120) - 60.0 + 0.5
	match i % 4:
		0:
			return Vector3(along, 0.0, across)
		1:
			return Vector3(-along, 0.0, across)
		2:
			return Vector3(across, 0.0, along)
	return Vector3(across, 0.0, -along)


static func _train_yaw(i: int) -> float:
	return [-PI * 0.5, PI * 0.5, PI, 0.0][i % 4]
