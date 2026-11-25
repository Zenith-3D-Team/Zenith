extends SceneTree
## Immersive Enemies death-burst probe: N creatures (a mix of biter and spitter tiers) take an
## explosive hit and die in the same frame through the add-on's real entry points (main.gd's
## _on_damaged / _on_died, as api.creatures fires them), then 30 more frames run. Prints, per N and
## mode (old = all at once, new = spread over frames), the death frame's and the next 30 frames'
## time per part (damage handling, gore, ragdoll spawn, drain, each step) and the whole frame.
## Real models (Placeholders), the real api.creatures object, the native library when built.
## Run: godot --headless --audio-driver Dummy --path client --log-file <abs> --script res://tests/enemies_burst_probe.gd
##      [-- --burst=10,40,80 --mode=old,new --frames=30]

const ModelLib := preload("res://scripts/world/model_library.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")

const PROTOS := ["small-biter", "medium-biter", "big-biter", "behemoth-biter",
	"small-spitter", "medium-spitter", "big-spitter", "behemoth-spitter"]


class FakeSettings:
	extends RefCounted
	signal changed(id: String, v: Variant)
	var vals := {}

	func add(id: String, _t: String, def: Variant, _label: String, _opts := {}) -> void:
		vals[id] = def

	func value(id: String) -> Variant:
		return vals.get(id)


class FakeUi:
	extends RefCounted

	func label(_t: String) -> Control:
		return Label.new()

	func button(_t: String, _cb: Callable) -> Control:
		return Button.new()

	func set_options(_cb: Callable) -> void:
		pass

	func message(_t: String) -> void:
		pass


class FakeApi:
	extends RefCounted
	signal game_started
	signal game_ended
	var level := 1.93
	var creatures
	var settings
	var ui
	var world = null

	func in_game() -> bool:
		return true

	func note(t: String) -> void:
		print("[immersive-enemies] ", t)

	func native_class(cls: String) -> Object:
		if "--enemies-native=off" in OS.get_cmdline_user_args():
			return null
		if not NativeLibrary.ensure() or not ClassDB.class_exists(cls):
			return null
		return ClassDB.instantiate(cls)


var _main: Node
var _AddonCreatures: Script
var _api: FakeApi
var _unit := 50000
var _fails := 0


func _check(ok: bool, what: String) -> void:
	if ok:
		print("ok: ", what)
	else:
		_fails += 1
		print("FAIL: ", what)


func _arg(prefix: String, fallback: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return a.substr(prefix.length())
	return fallback


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("--- enemies_burst_probe ---")
	Engine.max_fps = 0
	OS.low_processor_usage_mode = false
	# Loaded here, not preloaded: its world.gd needs the autoloads, which a --script run adds later.
	_AddonCreatures = load("res://scripts/addons/addon_creatures.gd")
	print("native library: ", NativeLibrary.ensure() and ClassDB.class_exists("BiterRagdollNative"))
	var t_wait := Time.get_ticks_msec()
	while not ModelPacks.is_ready() and Time.get_ticks_msec() - t_wait < 20000:
		await process_frame
	_api = FakeApi.new()
	_api.settings = FakeSettings.new()
	_api.ui = FakeUi.new()
	_api.creatures = _AddonCreatures.new(null, _api)
	var src := ProjectSettings.globalize_path("res://").path_join("../addons-src/immersive-enemies/main.gd").simplify_path()
	var script: Script = load(src)
	_main = script.new()
	root.add_child(_main)
	_main.set_process(false)
	_main.addon_start(_api)
	var all_ready := true
	for p in PROTOS:
		var m: Mesh = ModelLib.mesh_for(p)
		all_ready = all_ready and m != null and ModelLib.ready(p)
	print("models ready: ", all_ready)

	var sizes: Array = []
	for s in _arg("--burst=", "10,40,80").split(","):
		sizes.append(int(s))
	var modes: PackedStringArray = _arg("--mode=", "old,new").split(",")
	var frames: int = int(_arg("--frames=", "30"))

	# Warm-up (first split/leg extraction per tier is cached; the first burst in a game pays it once).
	_main.burst_spread = false
	_main._gore.batch_decals = false
	var cold: Dictionary = await _burst(8, frames)
	print("cold first burst (old, N=8): death frame %.2f ms, handlers %.2f ms" % [cold["frame0"], cold["handlers0"]])
	# Any model finishing its load bumps ModelLibrary.generation (models stream in during play).
	ModelLib.generation += 1
	var bumped: Dictionary = await _burst(8, frames)
	print("after a model load (old, N=8): death frame %.2f ms, handlers %.2f ms" % [bumped["frame0"], bumped["handlers0"]])
	# Pre-cutting: forget every cut, let the add-on see the tiers alive, then run frames until done.
	_AddonCreatures._leg_cache.clear()
	_main._clear_all()
	_main.burst_spread = true
	_main._warmed.clear()
	for p in PROTOS:
		_main._anim.seen_protos[p] = true
	_main.profiling = true
	var warm_max := 0.0
	var frame_max := 0.0
	var warm_frames := 0
	var t_warm := Time.get_ticks_msec()
	for k in 2000:
		_main.profile = {}
		var tf := Time.get_ticks_usec()
		_main._process(1.0 / 60.0)
		frame_max = maxf(frame_max, (Time.get_ticks_usec() - tf) / 1000.0)
		await process_frame
		var w: float = int(_main.profile.get("warm", 0)) / 1000.0
		warm_max = maxf(warm_max, w)
		if w > 0.0:
			warm_frames += 1
		if _main._warmed.size() >= PROTOS.size():
			break
	_main.profiling = false
	print("pre-cut on a worker: %d tiers in %d ms, %d main-thread calls, max %.2f ms a call, max add-on frame %.2f ms" % [
		_main._warmed.size(), Time.get_ticks_msec() - t_warm, warm_frames, warm_max, frame_max])
	_check(_main._warmed.size() == PROTOS.size(), "every seen tier pre-cut on a worker")
	# The worker's cuts are the same as cutting on the spot.
	var same := true
	for key: String in ["big-biter:part:thorax", "big-biter:part:head", "big-biter:2", "big-spitter:part:abdomen", "big-spitter:7"]:
		var rec: Variant = _AddonCreatures._leg_cache.get(key)
		var parts := key.split(":")
		var direct: Variant = null
		if parts.size() == 3:
			direct = _api.creatures._extract_part_entry(parts[0], parts[2])
		else:
			direct = _api.creatures._extract_leg_entry(parts[0], int(parts[1]))
		if not (rec is Dictionary) or not (direct is Dictionary) or rec.has("none"):
			same = false
			continue
		var m1: ArrayMesh = rec["mesh"]
		var m2: ArrayMesh = direct["mesh"]
		if m1.get_surface_count() != m2.get_surface_count() or not (rec["centroid"] as Vector3).is_equal_approx(direct["centroid"]):
			same = false
			continue
		for si in m1.get_surface_count():
			if m1.surface_get_array_len(si) != m2.surface_get_array_len(si):
				same = false
	_check(same, "pre-cut meshes match cutting on the spot (surfaces, vertex counts, centroids)")
	_main._gore.batch_decals = false
	var warmed: Dictionary = await _burst(8, frames)
	print("after pre-cut (old, N=8): death frame %.2f ms, handlers %.2f ms" % [warmed["frame0"], warmed["handlers0"]])

	for mode in modes:
		for n in sizes:
			var res: Array = []
			for rep in 3:
				res.append(await _burst(n, frames, mode))
			_report(mode, n, res)
			if mode == "new":
				var last: Dictionary = res[res.size() - 1]
				_check(int(last["drained_at"]) > 0 and int(last["drained_at"]) <= 10 and _main._claimed_pending == 0,
					"N=%d: every queued death drawn within 10 frames (by %d)" % [n, int(last["drained_at"])])
	await _client_part(sizes)
	_main.addon_stop()
	_main.queue_free()
	await process_frame
	print("enemies_burst_probe: %d failed" % _fails)
	quit(1 if _fails > 0 else 0)


func _burst(n: int, frames: int, mode := "old") -> Dictionary:
	_main._clear_all()
	_main.burst_spread = mode == "new"
	_main._gore.batch_decals = mode == "new"
	for _i in 10:
		await process_frame
		_main._process(1.0 / 60.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 777 + n
	var infos: Array = []
	var centre := Vector3(20.0, 0.0, 20.0)
	for i in n:
		_unit += 1
		var proto: String = PROTOS[i % PROTOS.size()]
		var pos := centre + Vector3(rng.randf_range(-6.0, 6.0), 0.0, rng.randf_range(-6.0, 6.0))
		var cause := Vector3(0.0, 0.0, 0.0)
		infos.append({"unit": _unit, "name": proto, "pos": pos, "yaw": rng.randf_range(0.0, TAU),
			"vel": Vector3(rng.randf_range(-1.0, 1.0), 0.0, rng.randf_range(-1.0, 1.0)),
			"cause_pos": cause, "damage_type": "explosion", "dmg": 600, "hp": 0, "src": "grenade",
			"fx": "blood", "phase": 0.0, "handled": false})
	_main.profile = {}
	_main.profiling = true
	await process_frame
	# Frame 0: every hit and death arrives (as a grenade's packet would), then the add-on's frame.
	var f0 := Time.get_ticks_usec()
	for info in infos:
		_main._on_damaged(info)
	for info in infos:
		var d: Dictionary = (info as Dictionary).duplicate()
		d.erase("hp")
		d.erase("fx")
		_main._on_died(d)
	var h0 := Time.get_ticks_usec()
	_main._process(1.0 / 60.0)
	var f_end := Time.get_ticks_usec()
	await process_frame  # node adds/frees of the frame are flushed here
	var f_flush := Time.get_ticks_usec()
	var out := {"frame0": (f_flush - f0) / 1000.0, "handlers0": (h0 - f0) / 1000.0,
		"p0": (_main.profile as Dictionary).duplicate(), "frame0_addon": (f_end - f0) / 1000.0}
	var rest_max := 0.0
	var rest_sum := 0.0
	var rest_profile := {}
	var drained_at := 0
	for k in frames:
		_main.profile = {}
		var t0 := Time.get_ticks_usec()
		_main._process(1.0 / 60.0)
		await process_frame
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		rest_max = maxf(rest_max, ms)
		rest_sum += ms
		for key in _main.profile:
			rest_profile[key] = int(rest_profile.get(key, 0)) + int(_main.profile[key])
		if drained_at == 0 and _main._death_queue.is_empty():
			drained_at = k + 1
	_main.profiling = false
	out["rest_max"] = rest_max
	out["rest_avg"] = rest_sum / maxf(1.0, float(frames))
	out["rest_p"] = rest_profile
	out["drained_at"] = drained_at
	out["active"] = _main._ragdoll.active_count()
	return out


## The client's own work per enemy death on the same frame (fx.gd _on_died): a death sound from
## the pool and three dust cards. Not the add-on's; measured for the split.
func _client_part(sizes: Array) -> void:
	var SfxScript: Script = load("res://scripts/fx/sfx.gd")
	var SpriteFxScript: Script = load("res://scripts/fx/sprite_fx.gd")
	var SoundBank: Script = load("res://scripts/fx/sound_bank.gd")
	var sfx: Node = SfxScript.new()
	var sprites: Node = SpriteFxScript.new()
	root.add_child(sfx)
	root.add_child(sprites)
	await process_frame
	for n: int in sizes:
		var t_snd := 0
		var t_dust := 0
		var t0 := Time.get_ticks_usec()
		for i in n:
			var at := Vector3(20.0 + i * 0.1, 0.0, 20.0)
			var a := Time.get_ticks_usec()
			sfx.play_at(SoundBank.pick("base/sound/creatures/biter-death"), at, 0.6, 0.06, 1.0, "Enemies")
			var b := Time.get_ticks_usec()
			for k in 3:
				sprites.emit("dust", at + Vector3(randf_range(-0.3, 0.3), 0.3, randf_range(-0.3, 0.3)), 0.5, 0.7, Color(0.42, 0.3, 0.12, 0.6))
			t_snd += b - a
			t_dust += Time.get_ticks_usec() - b
		var t_frame0 := Time.get_ticks_usec()
		await process_frame
		print("CLIENT N=%d: death sounds %.2f ms, dust cards %.2f ms, next frame (their process) %.2f ms" % [
			n, t_snd / 1000.0, t_dust / 1000.0, (Time.get_ticks_usec() - t_frame0) / 1000.0])
		for _k in 90:
			await process_frame
	sfx.queue_free()
	sprites.queue_free()


func _report(mode: String, n: int, res: Array) -> void:
	# Median of three by death-frame time.
	res.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["frame0"]) < float(b["frame0"]))
	var r: Dictionary = res[1]
	var p0: Dictionary = r["p0"]
	var rp: Dictionary = r["rest_p"]
	var ms := func(d: Dictionary, k: String) -> float: return int(d.get(k, 0)) / 1000.0
	print("  damaged split (death frame): ragdoll %.2f gore %.2f anim %.2f ms" % [ms.call(p0, "damaged_ragdoll"), ms.call(p0, "damaged_gore"), ms.call(p0, "damaged_anim")])
	print("BURST mode=%s N=%d | death frame %.2f ms (handlers %.2f: damaged %.2f gore %.2f ragdoll %.2f; deaths drawn %d) steps r%.2f g%.2f a%.2f | next %d: max %.2f avg %.2f ms, drained by frame %d, deaths later %d, sums: gore %.2f ragdoll %.2f drain %.2f step_r %.2f step_g %.2f | active %d" % [
		mode, n, r["frame0"], r["handlers0"], ms.call(p0, "damaged"), ms.call(p0, "gore"), ms.call(p0, "ragdoll"),
		int(p0.get("deaths", 0)), ms.call(p0, "step_ragdoll"), ms.call(p0, "step_gore"), ms.call(p0, "step_acid"),
		30, r["rest_max"], r["rest_avg"], r["drained_at"], int(rp.get("deaths", 0)),
		ms.call(rp, "gore"), ms.call(rp, "ragdoll"), ms.call(rp, "drain"), ms.call(rp, "step_ragdoll"), ms.call(rp, "step_gore"),
		r["active"]])
