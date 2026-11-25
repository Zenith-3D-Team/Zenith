extends SceneTree
## Rolling stock's and cars' wheels (`anim_wheel_*`) roll about their axle, across the vehicle (the
## model's X), the top towards the front (north, -Z) as the vehicle moves forward and back as it
## reverses, by the distance over the radius (rolling without sliding): in the world (movers.gd
## _roll_wheels) for every pack's rolling stock, and in the Model packs preview's Play (anim.gd: the
## owner saw FUE5's wagon wheels spin about the vertical there).
##   godot --headless --path client -s res://tests/wheel_roll_test.gd

const ModelLibrary := preload("res://scripts/world/model_library.gd")
const Movers := preload("res://scripts/world/movers.gd")
const Anim := preload("res://scripts/world/anim.gd")
const TestEnv := preload("res://tests/test_env.gd")

const MODELS := ["locomotive@builtin:fue5", "cargo-wagon@builtin:fue5", "fluid-wagon@builtin:fue5",
	"locomotive@builtin:placeholders", "cargo-wagon@builtin:placeholders", "fluid-wagon@builtin:placeholders",
	"artillery-wagon@builtin:placeholders", "infinity-cargo-wagon@builtin:placeholders", "car@builtin:placeholders",
	"tank@builtin:placeholders"]

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _initialize() -> void:
	TestEnv.isolate("wheel-roll-test")
	_run.call_deferred()


func _run() -> void:
	var MP = ModelLibrary.ModelPacks
	MP.configure(OS.get_user_data_dir().path_join("no-packs"), [], [])
	MP.wait()
	ModelLibrary.choices_changed([])
	var layer: Movers = Movers.new()
	var wheels := 0
	for name: String in MODELS:
		var mesh := ModelLibrary.mesh_for(name)
		for i in 1200:
			if mesh != null:
				break
			await process_frame
			mesh = ModelLibrary.mesh_for(name)
		check(mesh != null, "%s: loaded" % name)
		for part: ModelLibrary.AnimPart in ModelLibrary.parts_for(name):
			if part.mesh == null or not part.kind.begins_with("wheel"):
				continue
			wheels += 1
			# Its radius measured here: half its height at rest, round its pivot (the axle).
			var lo := INF
			var hi := -INF
			for s in part.mesh.get_surface_count():
				for v: Vector3 in part.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
					lo = minf(lo, v.y)
					hi = maxf(hi, v.y)
			var r := (hi - lo) * 0.5
			check(absf(part.pivot.origin.y - (lo + hi) * 0.5) < 0.05 * r, "%s %s: its pivot on the axle: %.3f in %.3f..%.3f" % [name, part.kind, part.pivot.origin.y, lo, hi])
			check(part.axis.is_equal_approx(Vector3.RIGHT), "%s %s: turns about the model's X (across): %s" % [name, part.kind, part.axis])
			_world(layer, name, part, r)
			_preview(name, part, r)
	check(wheels >= 30, "the rolling stock's wheels found: %d" % wheels)
	_tank_differential(layer)
	_car_steer_fenders(layer)
	layer.free()
	print("wheel_roll_test: %d wheels, %s" % [wheels, "PASS" if fails == 0 else "%d FAILED" % fails])
	quit(0 if fails == 0 else 1)


## Where the wheel's top (over its axle) goes when the part is turned by `xf`.
func _top_after(part: ModelLibrary.AnimPart, xf: Transform3D, r: float) -> Vector3:
	return xf * (part.pivot.origin + Vector3(0.0, r, 0.0)) - part.pivot.origin


## In the world: a vehicle facing each way moving 0.1 tile forward, then back.
func _world(layer: Movers, name: String, part: ModelLibrary.AnimPart, r: float) -> void:
	for yaw: float in [0.0, -PI * 0.5, PI * 0.75]:
		var node := Node3D.new()
		root.add_child(node)
		node.rotation.y = yaw
		var mi := MeshInstance3D.new()
		mi.mesh = part.mesh
		mi.set_meta("wheel", part)
		node.add_child(mi)
		var m := Movers.Mover.new()
		m.node = node
		m.wheels = layer._wheels_of(node)
		var forward := -node.global_transform.basis.z
		for dir: float in [1.0, -1.0]:
			for w: Array in m.wheels:
				w[4] = 0.0
			mi.transform = Transform3D.IDENTITY
			var d := 0.1 * dir
			layer._roll_wheels(m, forward * d, 0.0, 0.016)
			var top := _top_after(part, mi.transform, r)
			# Model space: the front is -Z, so going forward the top moves to -Z.
			check(signf(-top.z) == dir and absf(top.x) < 1e-4,
				"%s %s yaw %.2f: moving %s the top turns %s: %s" % [name, part.kind, yaw, "forward" if dir > 0 else "back", "forward" if dir > 0 else "back", top])
			var angle := atan2(mi.transform.basis.y.z, mi.transform.basis.y.y)  # its turn about the axle
			check(absf(absf(angle) - absf(d) / r) < 0.1 * absf(d) / r,
				"%s %s: rolls %.4f rad for %.2f tiles, %.4f without sliding" % [name, part.kind, angle, d, d / r])
		node.free()


## In the Model packs preview's Play: a spin about its axle, forward, at the preview's rolling speed.
func _preview(name: String, part: ModelLibrary.AnimPart, r: float) -> void:
	Anim.setup_part(part)
	check(part.motion == Anim.MOTION_SPIN, "%s %s: the preview spins it: motion %d" % [name, part.kind, part.motion])
	var top := _top_after(part, part.turned(0.05 * signf(part.rate) * TAU), r)
	check(top.z < 0.0 and absf(top.x) < 1e-4, "%s %s: playing, the top turns forward: %s" % [name, part.kind, top])
	var rim := absf(part.rate) * TAU * r
	check(absf(rim - Anim.PREVIEW_ROLL_SPEED) < 0.1 * Anim.PREVIEW_ROLL_SPEED,
		"%s %s: rolls at %.2f tiles a second, %.2f" % [name, part.kind, rim, Anim.PREVIEW_ROLL_SPEED])
	for i in part.mesh.get_surface_count():
		var mat := part.mesh.surface_get_material(i) as ShaderMaterial
		if mat != null:
			check((mat.get_shader_parameter("anim_axis") as Vector3).is_equal_approx(Vector3.RIGHT) and float(mat.get_shader_parameter("anim_rate")) < 0.0,
				"%s %s: its shader turns it about X, forward: %s %s" % [name, part.kind, mat.get_shader_parameter("anim_axis"), mat.get_shader_parameter("anim_rate")])


## Pure pivot turn on the tank: right wheels (+X) roll forward (-Z top), left wheels (-X) reverse (+Z top).
func _tank_differential(layer: Movers) -> void:
	var left_part: ModelLibrary.AnimPart = null
	var right_part: ModelLibrary.AnimPart = null
	for p: ModelLibrary.AnimPart in ModelLibrary.parts_for("tank@builtin:placeholders"):
		if p.kind != "wheel_track" or p.mesh == null:
			continue
		if p.pivot.origin.x < -0.1 and left_part == null:
			left_part = p
		elif p.pivot.origin.x > 0.1 and right_part == null:
			right_part = p
	check(left_part != null and right_part != null, "tank differential: both left and right track wheels found")
	if left_part == null or right_part == null:
		return
	var node := Node3D.new()
	root.add_child(node)
	var left_mi := MeshInstance3D.new()
	left_mi.mesh = left_part.mesh
	left_mi.set_meta("wheel", left_part)
	node.add_child(left_mi)
	var right_mi := MeshInstance3D.new()
	right_mi.mesh = right_part.mesh
	right_mi.set_meta("wheel", right_part)
	node.add_child(right_mi)
	var m := Movers.Mover.new()
	m.node = node
	m.wheels = layer._wheels_of(node)
	layer._roll_wheels(m, Vector3.ZERO, 0.25, 0.016)
	var lr := left_part.wheel_radius()
	var rr := right_part.wheel_radius()
	var ltop := _top_after(left_part, left_mi.transform, lr)
	var rtop := _top_after(right_part, right_mi.transform, rr)
	check(rtop.z < -0.005 and ltop.z > 0.005,
		"tank differential left turn: right wheel forward (%s), left wheel backward (%s)" % [rtop, ltop])
	node.free()


## Front fenders (`anim_steer_front`) follow the car's front wheel steering angle.
func _car_steer_fenders(layer: Movers) -> void:
	var wheel_part: ModelLibrary.AnimPart = null
	var steer_part: ModelLibrary.AnimPart = null
	for p: ModelLibrary.AnimPart in ModelLibrary.parts_for("car@builtin:placeholders"):
		if p.kind == "wheel_front" and p.mesh != null and wheel_part == null:
			wheel_part = p
		elif p.kind == "steer_front" and p.mesh != null and steer_part == null:
			steer_part = p
	check(wheel_part != null and steer_part != null, "car steering: wheel_front and steer_front found")
	if wheel_part == null or steer_part == null:
		return
	var node := Node3D.new()
	root.add_child(node)
	var wmi := MeshInstance3D.new()
	wmi.mesh = wheel_part.mesh
	wmi.set_meta("wheel", wheel_part)
	node.add_child(wmi)
	var smi := MeshInstance3D.new()
	smi.mesh = steer_part.mesh
	smi.set_meta("steer", steer_part)
	node.add_child(smi)
	var m := Movers.Mover.new()
	m.node = node
	m.wheels = layer._wheels_of(node)
	m.steers = layer._steers_of(node)
	for _i in 10:
		layer._roll_wheels(m, Vector3(0.0, 0.0, -0.2), 0.1, 0.05)
	check(m.steer > 0.1 and smi.transform.basis.x.z < -0.05,
		"car front fender steers with front wheel (steer=%.3f, basis.x=%s)" % [m.steer, smi.transform.basis.x])
	node.free()
