extends Node
## The debug menu's benchmarks (debug_menu.gd), run in the game being played: each one settles for a
## moment, then measures every frame while it stands, runs laps, flies the camera or zooms, and ends
## with a report (finished). The frames are kept in the stutter probe's columns so its summarize()
## works them out the same way (p50, p99, worst, frames over 16.7 and 33 ms, GPU and render CPU,
## scripts, draw calls, triangles); the laps are its `fast` route and standing its `stand` (the
## routes tools/bench/compare_builds.py runs), and the game's UPS is counted as the UPS probe does,
## server ticks over real seconds. The bridge's cost per tick comes from /f3d-profile and
## /f3d-status over RCON, as the tools read it: its profilers print only in Factorio, so without
## RCON (single-player beside Factorio) the report says so.

signal progress(text: String)
signal finished(report: Dictionary)

const StutterProbe := preload("res://scripts/debug/stutter_probe.gd")
const Settings := preload("res://scripts/menu/settings.gd")

## id -> [name, what it does]. The order is the menu's.
const BENCHES := {
	"stand": ["Standing still", "30 s where the character stands: the steady cost of the view (the stutter probe's \"stand\")"],
	"laps": ["Laps", "Two laps of a loop round where the character stands, at the speed it runs (66 s; exoskeletons make it the \"fast\" route of tools/bench/compare_builds.py). Keep your hands off the keys"],
	"flyover": ["Camera flyover", "The camera flies a circle 100 tiles round the character, 45 tiles up, for 30 s: chunks stream in and out under it"],
	"zoom": ["Zoom out and back", "The view zooms out to the furthest zoom (Settings > Camera) over 10 s, holds 5 s and comes back over 10 s"],
}
const SETTLE := 2.0
const WALK_REPEAT := 0.15
const FLY_RADIUS := 100.0
const FLY_HEIGHT := 45.0
const FLY_SECONDS := 30.0
const ZOOM_OUT := 10.0
const ZOOM_HOLD := 5.0
const RCON_WAIT_MSEC := 3000

var main  # main.gd
var kind := ""

var _t := 0.0
var _measuring := false
var _frames: Array = []
var _last_usec := 0
var _start_tick := 0
var _start_msec := 0
var _start_pos := Vector2.ZERO
var _walked := 0.0
var _last_pos := Vector2.ZERO
var _route: Array = []
var _leg := 0
var _leg_left := 0.0
var _walk_timer := 0.0
var _zoom_from := 0.0
var _fly_center := Vector2.ZERO
var _done := false
var _times := false  # the renderer's measured times can be read (not with the render thread on its own)
var _profiling_was_off := false
var _rcon_note := ""


## The benchmark's length after settling, in seconds.
static func seconds_of(id: String) -> float:
	match id:
		"stand":
			return float(StutterProbe.ROUTES["stand"][0][1])
		"laps":
			var s := 0.0
			for leg in StutterProbe.ROUTES["fast"]:
				s += float(leg[1])
			return s
		"flyover":
			return FLY_SECONDS
		"zoom":
			return ZOOM_OUT * 2.0 + ZOOM_HOLD
	return 0.0


func _ready() -> void:
	process_priority = 1000  # last in the frame, as the stutter probe: the counters hold this frame's work
	_times = ProjectSettings.get_setting("rendering/driver/threads/thread_model", 1) != 2
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), _times)
	_route = StutterProbe.ROUTES["fast"] if kind == "laps" else []
	_start_bridge_profile()


func _process(delta: float) -> void:
	if _done:
		return
	if main == null or not Bridge.world_ready:
		cancel("the game went away")
		return
	_t += delta
	var left := SETTLE + seconds_of(kind) - _t
	if Engine.get_process_frames() % 15 == 0:
		progress.emit("%s: %s" % [BENCHES[kind][0], "settling" if _t < SETTLE else "%d s left" % ceili(left)])
	if _t < SETTLE:
		_last_usec = Time.get_ticks_usec()
		return
	if not _measuring:
		_measuring = true
		_start_tick = Bridge.server_tick
		_start_msec = Time.get_ticks_msec()
		_start_pos = main.avatar.ground_position()
		_last_pos = _start_pos
		_begin()
	_drive(delta, _t - SETTLE)
	var now := Time.get_ticks_usec()
	var vp := get_viewport().get_viewport_rid()
	var at: Vector2 = main.avatar.ground_position()
	_walked += at.distance_to(_last_pos)
	_last_pos = at
	# The stutter probe's columns (summarize() reads 0, 1-5, 6, 7, 12, 14, 16, 17).
	_frames.append([(now - _last_usec) / 1000.0, 0.0, 0.0, 0.0, 0.0, 0.0,
		RenderingServer.viewport_get_measured_render_time_cpu(vp) if _times else -1.0,
		RenderingServer.viewport_get_measured_render_time_gpu(vp) if _times else -1.0,
		0, snappedf(at.x, 0.1), snappedf(at.y, 0.1), Bridge.server_tick,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, {},
		0, int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))])
	_last_usec = now
	if left <= 0.0:
		_finish()


## Stops early: everything put back, no report.
func cancel(why := "cancelled") -> void:
	if _done:
		return
	_done = true
	_end()
	progress.emit("%s %s" % [BENCHES.get(kind, ["Benchmark"])[0], why])
	finished.emit({})
	queue_free()


func _begin() -> void:
	var rig = main.rig
	match kind:
		"flyover":
			_fly_center = _start_pos
			rig.take_over()
		"zoom":
			_zoom_from = rig._distance_goal


func _drive(delta: float, t: float) -> void:
	var rig = main.rig
	match kind:
		"laps":
			if _leg >= _route.size():
				return
			if _leg_left <= 0.0:
				_leg_left = float(_route[_leg][1])
				_walk_timer = 0.0
			_walk_timer -= delta
			if _walk_timer <= 0.0:
				Bridge.send({"t": "walk", "d": int(_route[_leg][0])})
				_walk_timer = WALK_REPEAT
			_leg_left -= delta
			if _leg_left <= 0.0:
				_leg += 1
				if _leg >= _route.size():
					Bridge.send({"t": "walk", "d": -1})
		"flyover":
			var a := t / FLY_SECONDS * TAU
			var ground := _fly_center + Vector2(cos(a), sin(a)) * FLY_RADIUS
			# Looking ahead along the circle and down at the ground 40 tiles in front.
			var ahead := _fly_center + Vector2(cos(a + 0.45), sin(a + 0.45)) * FLY_RADIUS
			rig.taken_focus = ground
			var eye := Vector3(ground.x, FLY_HEIGHT, ground.y)
			rig.camera.global_transform = Transform3D(Basis.IDENTITY, eye).looking_at(Vector3(ahead.x, 0.0, ahead.y), Vector3.UP)
		"zoom":
			var far: float = rig.max_distance
			var f := clampf(t / ZOOM_OUT, 0.0, 1.0) if t < ZOOM_OUT + ZOOM_HOLD else clampf(1.0 - (t - ZOOM_OUT - ZOOM_HOLD) / ZOOM_OUT, 0.0, 1.0)
			rig._distance_goal = lerpf(_zoom_from, far, smoothstep(0.0, 1.0, f))


## Puts back what the benchmark took: the walk, the camera, the zoom.
func _end() -> void:
	if main == null:
		return
	var rig = main.rig
	match kind:
		"laps":
			Bridge.send({"t": "walk", "d": -1})
		"flyover":
			if rig.taken():
				rig.hand_back()
		"zoom":
			if _zoom_from > 0.0:
				rig._distance_goal = _zoom_from
	if _profiling_was_off and _has_rcon():
		main._run_command("/f3d-profile")  # off again, as it was


func _finish() -> void:
	_done = true
	var secs := maxf((Time.get_ticks_msec() - _start_msec) / 1000.0, 0.001)
	var ups := (Bridge.server_tick - _start_tick) / secs
	var s: Dictionary = StutterProbe.summarize(_frames)
	var report := {
		"bench": kind, "name": BENCHES[kind][0], "when": Time.get_datetime_string_from_system(false, true),
		"seconds": snappedf(secs, 0.1), "frames": s["frames"], "fps": snappedf(s["frames"] / secs, 0.1),
		"p50": snappedf(s["p50"], 0.01), "p99": snappedf(s["p99"], 0.01), "worst": snappedf(s["worst"], 0.01),
		"over16": s["over16"], "over33": s["over33"],
		"gpu_p50": s["gpu_p50"] if _times else -1.0, "gpu_p99": s["gpu_p99"] if _times else -1.0,
		"render_cpu_p50": s["render_cpu_p50"] if _times else -1.0, "process_p50": s["process_p50"],
		"draw_calls_p50": int(s["draw_calls_p50"]), "primitives_p50": int(s["primitives_p50"]),
		"ups": snappedf(ups, 0.1), "setup": setup(),
	}
	if kind == "laps":
		report["walked"] = snappedf(_walked, 1.0)
		report["speed"] = snappedf(_walked / secs, 0.1)
	_end()
	await _bridge_cost(report)
	finished.emit(report)
	queue_free()


## What was running: Zenith's version, the graphics preset and the settings that weigh most, the
## window, the game's speed (from the debug menu's last state).
func setup() -> Dictionary:
	var size := get_viewport().get_visible_rect().size
	return {"version": str(ProjectSettings.get_setting("application/config/version", "?")), "preset": Settings.preset_now(),
		"look": str(Settings.get_value("graphics", "look")), "resolution": "%dx%d" % [int(size.x), int(size.y)],
		"render_scale": snappedf(get_viewport().scaling_3d_scale, 0.01), "shadows": str(Settings.get_value("graphics", "shadows")),
		"lod": str(Settings.get_value("graphics", "lod_quality")), "view_radius": int(main.world.view_radius),
		"entity_radius": int(main.world.focus_radius), "vsync": bool(Settings.get_value("graphics", "vsync")),
		"fps_cap": Engine.max_fps, "hold_60_ups": bool(main.ups_governor.enabled) if main.ups_governor != null else false,
		"render_thread": not _times}


func _has_rcon() -> bool:
	return main != null and main.has_method("_has_rcon") and main._has_rcon()


## Turns the bridge's profiler on over RCON (it averages each module over 10 s), unless it was on.
func _start_bridge_profile() -> void:
	if not _has_rcon():
		_rcon_note = "needs RCON: the bridge's profiler prints only in Factorio (start the server from Zenith's menu, or /f3d-profile and /f3d-status in Factorio's console)"
		return
	var status: String = await main._run_command("/f3d-status")
	if status.contains("profiling off"):
		_profiling_was_off = true
		await main._run_command("/f3d-profile")


## The bridge's time per tick by module (/f3d-status over RCON, tools/profile_log.py's lines) and
## its work budget (through the bridge, any game).
func _bridge_cost(report: Dictionary) -> void:
	report["bridge_ms"] = -1.0
	report["bridge_note"] = _rcon_note
	if _has_rcon():
		var text: String = await main._run_command("/f3d-status")
		var re := RegEx.create_from_string("\\[Zenith\\] (\\S+): Duration: ([0-9.]+) ?ms per tick")
		var total := 0.0
		var parts: Array = []
		for m in re.search_all(text):
			var ms := float(m.get_string(2))
			total += ms
			parts.append([m.get_string(1), snappedf(ms, 0.001)])
		parts.sort_custom(func(a: Array, b: Array) -> bool: return a[1] > b[1])
		if parts.is_empty():
			report["bridge_note"] = "the profiler had no average yet" if text.contains("first average") else "no profile in /f3d-status"
		else:
			report["bridge_ms"] = snappedf(total, 0.001)
			report["bridge_modules"] = parts.slice(0, 6)
			report["bridge_note"] = ""
	var model = main.hud.ui.model if main.hud != null else null
	if model != null:
		var lines: Array = await _ask_bridge(model, "/f3d-status")
		for l in lines:
			if str(l).contains("work budget"):
				report["budget"] = str(l).trim_prefix("[Zenith] ")


func _ask_bridge(model, text: String) -> Array:
	var got: Array = []
	var id: int = model.command(text)
	var on_answer := func(answer_id: int, lines: Array, _known: bool) -> void:
		if answer_id == id and got.is_empty():
			got.append(lines)
	model.command_answered.connect(on_answer)
	var started := Time.get_ticks_msec()
	while got.is_empty() and Time.get_ticks_msec() - started < RCON_WAIT_MSEC:
		await get_tree().process_frame
	model.command_answered.disconnect(on_answer)
	return got[0] if not got.is_empty() else []
