extends Node
## Soak driver (test tool, tools/bench/soak): plays the phases of a steps file (--soak=<steps.json>)
## inside the client with synthetic input only (no real mouse or keys) and records, to
## --soak-out=<file.jsonl>, every frame's length by phase, the renderer's CPU and GPU times, the
## frames over 25/50/100/250 ms (with the time, phase and the last step), and memory every 30 s.
## Console commands to the server go out through tools/rcon.py in a separate process (never blocking
## a frame). Started from tools/bench/soak/soak.py; based on the overnight verify driver's step player.
##
## Lines (JSON, one each): {"k":"start"} {"k":"phase","name"} {"k":"spike","ms","phase","step","gpu","cpu"}
## {"k":"mem",...} {"k":"sum","phase",...,"frames":[tenths of a ms]} {"k":"note","text"}.

const Probing := preload("res://scripts/debug/probing.gd")

var api
var main: Node
var rig
var hud
var ui
var world
var input
var avatar

var _steps: Array = []
var _at := 0
var _out: FileAccess = null
var _py := ""
var _tools := ""
var _rcon_port := 0
var vars := {}

# Recorder
var _phase := "boot"
var _step_name := ""
var _last_usec := 0
var _frames := PackedInt32Array()  # tenths of a ms, this phase
var _gpu := PackedFloat32Array()
var _cpu := PackedFloat32Array()
var _phase_start := 0
var _mem_left := 0.0
var _vp_rid := RID()
const SPIKE_MS := 25.0
const MEM_EVERY := 30.0


func addon_start(a) -> void:
	api = a
	var path := ""
	var out := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--soak="):
			path = arg.substr(7)
		elif arg.begins_with("--soak-out="):
			out = arg.substr(11)
		elif arg.begins_with("--soak-py="):
			_py = arg.substr(10)
		elif arg.begins_with("--soak-tools="):
			_tools = arg.substr(13)
		elif arg.begins_with("--soak-rcon="):
			_rcon_port = int(arg.substr(12))
	if path == "" or out == "":
		return
	_out = FileAccess.open(out, FileAccess.WRITE)
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Array):
		note("can't read steps from %s" % path)
		return
	_steps = parsed
	_vp_rid = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp_rid, true)
	_emit({"k": "start", "steps": _steps.size(), "unix": Time.get_unix_time_from_system(), "msec": Time.get_ticks_msec(),
		"adapter": RenderingServer.get_video_adapter_name(), "win": str(get_window().size)})
	_phase_start = Time.get_ticks_msec()
	_last_usec = Time.get_ticks_usec()
	_run.call_deferred()


func note(text: String) -> void:
	print("[soak] " + text)
	_emit({"k": "note", "text": text, "msec": Time.get_ticks_msec(), "phase": _phase})


func _emit(d: Dictionary) -> void:
	if _out != null:
		_out.store_line(JSON.stringify(d))
		_out.flush()


func _process(delta: float) -> void:
	if _out == null:
		return
	var now := Time.get_ticks_usec()
	var ms := (now - _last_usec) / 1000.0
	_last_usec = now
	_frames.append(mini(int(ms * 10.0), 2000000000))
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(_vp_rid)
	var cpu := RenderingServer.viewport_get_measured_render_time_cpu(_vp_rid)
	_gpu.append(gpu)
	_cpu.append(cpu)
	var pl := _pipelines()
	var pl_frame := pl - _pl_prev
	_pl_prev = pl
	if ms > SPIKE_MS:
		_emit({"k": "spike", "ms": snappedf(ms, 0.1), "msec": Time.get_ticks_msec(), "unix": Time.get_unix_time_from_system(),
			"phase": _phase, "step": _step_name, "gpu": snappedf(gpu, 0.1), "cpu": snappedf(cpu, 0.1),
			"pl": pl, "pl_frame": pl_frame})
	_mem_left -= delta
	if _mem_left <= 0.0:
		# Every 2 s for the first 3 minutes (the join's growth), then every MEM_EVERY.
		_mem_left = 2.0 if Time.get_ticks_msec() < 180000 else MEM_EVERY
		_mem()


var _pl_prev := 0


## Pipelines compiled so far (the engine's counters; the frame's own is the difference from the last frame's).
func _pipelines() -> int:
	return int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_DRAW)) + int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SPECIALIZATION)) 		+ int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_MESH)) + int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SURFACE)) 		+ int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_CANVAS))


func _mem() -> void:
	var d := {"k": "mem", "msec": Time.get_ticks_msec(), "unix": Time.get_unix_time_from_system(), "phase": _phase,
		"static_mb": snappedf(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, 0.1),
		"video_mb": snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1),
		"tex_mb": snappedf(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0, 0.1),
		"buf_mb": snappedf(Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0, 0.1),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"orphans": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"draws": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"prims": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"objs_drawn": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"fps": Performance.get_monitor(Performance.TIME_FPS)}
	if world != null:
		var ents = world.get("entities")
		if ents is Dictionary:
			d["entities"] = (ents as Dictionary).size()
	if api != null and api.in_game():
		d["chunks"] = api.world.chunks().size()
	_emit(d)


func _close_phase() -> void:
	var n := _frames.size()
	if n == 0:
		return
	var sorted := _frames.duplicate()
	sorted.sort()
	var g := _gpu.duplicate()
	g.sort()
	var c := _cpu.duplicate()
	c.sort()
	var total := 0
	var over := [0, 0, 0, 0]
	for v in _frames:
		total += v
		if v > 250:
			over[0] += 1
		if v > 500:
			over[1] += 1
		if v > 1000:
			over[2] += 1
		if v > 2500:
			over[3] += 1
	_emit({"k": "sum", "phase": _phase, "frames_n": n, "secs": (Time.get_ticks_msec() - _phase_start) / 1000.0,
		"fps": n / maxf(total / 10000.0, 0.001),
		"p50": sorted[n / 2] / 10.0, "p95": sorted[mini(n - 1, int(n * 0.95))] / 10.0,
		"p99": sorted[mini(n - 1, int(n * 0.99))] / 10.0, "max": sorted[n - 1] / 10.0,
		"over25": over[0], "over50": over[1], "over100": over[2], "over250": over[3],
		"gpu_p50": snappedf(g[n / 2], 0.01), "gpu_p95": snappedf(g[mini(n - 1, int(n * 0.95))], 0.01),
		"cpu_p50": snappedf(c[n / 2], 0.01), "cpu_p95": snappedf(c[mini(n - 1, int(n * 0.95))], 0.01),
		"msec": Time.get_ticks_msec(), "unix": Time.get_unix_time_from_system(), "frames": Array(_frames)})
	_frames = PackedInt32Array()
	_gpu = PackedFloat32Array()
	_cpu = PackedFloat32Array()


func _set_phase(name: String) -> void:
	_close_phase()
	_mem()
	_phase = name
	_phase_start = Time.get_ticks_msec()
	_emit({"k": "phase", "name": name, "msec": _phase_start, "unix": Time.get_unix_time_from_system()})
	print("[soak] phase %s" % name)


func _bind() -> bool:
	main = get_tree().current_scene
	if main == null:
		return false
	rig = main.get("rig")
	hud = main.get("hud")
	world = main.get("world")
	input = main.get("input")
	avatar = main.get("avatar")
	ui = hud.get("ui") if hud != null else null
	return rig != null and hud != null and world != null and ui != null


func _run() -> void:
	_set_phase("join")
	while _at < _steps.size():
		var step: Dictionary = _steps[_at]
		_at += 1
		_step_name = "%d:%s" % [_at, str(step.get("do", ""))]
		await _step(step)
	_close_phase()
	note("done")


func _wait_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _secs(s: float) -> void:
	await get_tree().create_timer(s, true, false, true).timeout


func _rcon(cmd: String) -> void:
	if _py == "" or _rcon_port == 0:
		note("rcon: no --soak-py/--soak-rcon")
		return
	OS.create_process(_py, [_tools.path_join("rcon.py"), "--port", str(_rcon_port), cmd])


func _step(step: Dictionary) -> void:
	var what := str(step.get("do", ""))
	if step.has("note"):
		note(str(step["note"]))
	match what:
		"phase":
			_set_phase(str(step["name"]))
		"wait":
			await _secs(float(step.get("s", 1.0)))
		"wait_game":
			var limit := float(step.get("timeout", 240.0))
			var t := 0.0
			while t < limit:
				if api.in_game() and _bind() and not api.world.character().is_empty() and api.world.chunks().size() >= int(step.get("chunks", 9)):
					break
				await _secs(0.25)
				t += 0.25
			_bind()
			note("game on after %.1f s, %d chunks" % [t, api.world.chunks().size() if api.in_game() else 0])
			_emit({"k": "joined", "secs": t, "msec": Time.get_ticks_msec(), "unix": Time.get_unix_time_from_system()})
			await _secs(float(step.get("settle", 3.0)))
		"key":
			await _key(step)
		"camera":
			_bind()
			if step.has("yaw"):
				rig.set("_yaw_goal", float(step["yaw"]))
			if step.has("dist"):
				rig.set("_distance_goal", float(step["dist"]))
			if step.has("pitch"):
				rig.pitch_degrees = float(step["pitch"])
			await _wait_frames(2)
		"spin":
			# The view turned steadily, `deg` degrees a second for `s` seconds.
			_bind()
			var t := 0.0
			var rate := float(step.get("deg", 90.0))
			var limit := float(step.get("s", 4.0))
			while t < limit:
				var dt := get_process_delta_time()
				rig.yaw_degrees = fmod(float(rig.yaw_degrees) + rate * dt, 360.0)
				rig.set("_yaw_goal", rig.yaw_degrees)
				await get_tree().process_frame
				t += dt
		"zoom":
			# Zoom goal to `dist` (or the farthest allowed with "max"), then `hold` seconds.
			_bind()
			var dist = step.get("dist", 18.0)
			var goal: float = float(rig.get("max_distance")) if str(dist) == "max" else float(dist)
			rig.set("_distance_goal", goal)
			await _secs(float(step.get("hold", 3.0)))
		"rcon":
			_rcon(str(step["cmd"]))
			await _wait_frames(1)
		"lua":
			_rcon("/c __factorio-3d-bridge__ " + str(step["code"]))
			await _wait_frames(1)
		"py":
			# A tool run beside the client (not waited for): {"do":"py","args":["attack_wave.py","--wave","40"]}.
			var a: Array = step["args"]
			var args := PackedStringArray()
			args.append(_tools.path_join(str(a[0])))
			for i in range(1, a.size()):
				args.append(str(a[i]))
			OS.create_process(_py, args)
			await _wait_frames(1)
		"eval":
			var v = _eval(str(step["expr"]))
			if step.has("as"):
				vars[str(step["as"])] = v
			note("%s = %s" % [str(step.get("label", step["expr"])), str(v).left(400)])
		"weather":
			var w := get_tree().root.find_child("Addon_immersive_weather", true, false)
			if w == null or w.get("director") == null:
				note("weather: add-on not running")
			else:
				w.director.transition_to(str(step["id"]))
				note("weather -> %s" % str(step["id"]))
		"mem":
			_mem()
		"quit":
			_close_phase()
			note("quitting")
			_emit({"k": "end", "msec": Time.get_ticks_msec(), "unix": Time.get_unix_time_from_system()})
			await _wait_frames(2)
			get_tree().quit()
		_:
			note("unknown step %s" % what)


func _mod(name: String, down: bool) -> void:
	var code := KEY_SHIFT
	match name:
		"ctrl":
			code = KEY_CTRL
		"alt":
			code = KEY_ALT
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = down
	ev.shift_pressed = down and name == "shift"
	ev.ctrl_pressed = down and name == "ctrl"
	ev.alt_pressed = down and name == "alt"
	Input.parse_input_event(ev)


func _key(step: Dictionary) -> void:
	var code := OS.find_keycode_from_string(str(step["key"]))
	if code == KEY_NONE:
		note("unknown key %s" % str(step["key"]))
		return
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = true
	ev.alt_pressed = code == KEY_ALT
	Input.parse_input_event(ev)
	await _secs(float(step.get("hold", 0.05)))
	var ev2 := InputEventKey.new()
	ev2.keycode = code
	ev2.physical_keycode = code
	ev2.pressed = false
	Input.parse_input_event(ev2)
	await _wait_frames(2)


func _eval(text: String):
	_bind()
	var e := Expression.new()
	var names := ["main", "rig", "hud", "ui", "world", "input", "avatar", "api", "Bridge", "vars", "tree"]
	var values := [main, rig, hud, ui, world, input, avatar, api, Bridge, vars, get_tree()]
	if e.parse(text, PackedStringArray(names)) != OK:
		note("eval parse error: %s in %s" % [e.get_error_text(), text])
		return null
	var v = e.execute(values, self, true)
	if e.has_execute_failed():
		note("eval failed: %s in %s" % [e.get_error_text(), text])
		return null
	return v


## Helpers for eval (Expression can't assign).
func put(obj: Object, prop: String, value) -> bool:
	obj.set(prop, value)
	return true


func node(name: String) -> Node:
	return get_tree().root.find_child(name, true, false)


## The first entity of a prototype type's position (Factorio tiles) or [] (driving phase).
func first_of_type(t: String) -> Array:
	for unit in world.entities:
		var r = world.entities[unit]
		var p = world.protos.entity(r.proto_id)
		if p != null and str(p.type) == t:
			return [r.pos.x, r.pos.y, unit]
	return []
