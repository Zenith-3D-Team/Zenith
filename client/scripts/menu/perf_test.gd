extends Node
## Zenith's performance test (docs/PERFORMANCE-TEST.md): the main menu's "Performance test", or
## --perf-test=quick|default|extensive. It measures how smoothly Zenith runs on this PC the same way
## every time, so the numbers compare between PCs and versions: perf_game.gd makes a fixed map on a
## headless Factorio, builds a test base and starts Zenith afresh for each test with that test's
## settings preset; this script picks the tests for the mode, gathers each one's numbers and writes
## them to user://perf-tests/Zenith-perf-<version>-<mode>.txt (the PC, how it was run, a table per
## test, a CSV block for the project's tools), and keeps bench_runner.gd-shaped reports of each test
## for the debug menu's report window, each against the last run of the same mode.
##
## It replaces the PowerShell script the Windows downloads carried: nothing but Zenith runs, the PC's
## details come from Godot's own calls (processor, graphics adapter, memory, screen, system), and
## the only processes it starts or stops are its own Factorio server and Zenith.
##
##   var test := PerfTest.new()
##   test.mode = "quick"
##   add_child(test)
##   var outcome: Dictionary = await test.run()   # {ok, error, file, text, reports, exit_code}

signal progress(text: String, fraction: float)

const PerfGame := preload("res://scripts/menu/perf_game.gd")

const RESULTS_DIR := "user://perf-tests"
## id -> [name, time, what it runs]. Quick's time is measured on the project's PC (twice, 2 min
## 58 s); Default's and Extensive's are worked out from Quick's tests, not timed yet.
const MODES := {
	"quick": ["Quick", "about 3 minutes", "standing still and running laps, in the Factorio look (2 tests)"],
	"default": ["Default", "about 6 minutes (an estimate)", "the same in the Factorio look and the Cinematic look (4 tests)"],
	"extensive": ["Extensive", "about 17 minutes (an estimate)", "Default twice, plus the Low and Ultra graphics presets (12 tests)"],
}
const MODE_ORDER := ["quick", "default", "extensive"]
## Each test: [look, preset, route].
const PLANS := {
	"quick": [["factorio", "high", "stand"], ["factorio", "high", "fast"]],
	"default": [["factorio", "high", "stand"], ["cinematic", "high", "stand"], ["factorio", "high", "fast"], ["cinematic", "high", "fast"]],
	"extensive": [["factorio", "high", "stand"], ["cinematic", "high", "stand"], ["factorio", "high", "fast"], ["cinematic", "high", "fast"],
		["factorio", "low", "stand"], ["factorio", "low", "fast"], ["factorio", "ultra", "stand"], ["factorio", "ultra", "fast"],
		["factorio", "high", "stand"], ["cinematic", "high", "stand"], ["factorio", "high", "fast"], ["cinematic", "high", "fast"]],
}
const LOOKS := {"factorio": "Factorio look", "cinematic": "Cinematic look"}
const ROUTES := {"stand": "standing still", "fast": "running laps"}
## The graphics each preset sets in the test's own settings.cfg (as the earlier script set them, so
## results stay comparable; Settings.PRESETS may move on).
const PRESETS := {
	"low": {"shadows": "low", "ssao": false, "lod_quality": "low", "view_radius": 5, "entity_radius": 96, "belt_updates": 2000,
		"belt_distance": 64, "decorative_distance": 96, "decorative_density": 0.5, "grass_3d": "off", "clouds": false, "contact_shading": true},
	"high": {"shadows": "high", "ssao": false, "lod_quality": "medium", "view_radius": 10, "entity_radius": 192, "belt_updates": -1,
		"belt_distance": 160, "decorative_distance": 192, "decorative_density": 1.0, "grass_3d": "normal", "clouds": true, "contact_shading": true},
	"ultra": {"shadows": "ultra", "ssao": false, "lod_quality": "high", "view_radius": 14, "entity_radius": 256, "belt_updates": -1,
		"belt_distance": 320, "decorative_distance": 256, "decorative_density": 1.0, "grass_3d": "far", "clouds": true, "contact_shading": true},
}
## The CSV block's columns.
const CSV_KEYS := ["test", "look", "preset", "route", "frames", "p50", "p99", "worst", "over16", "over33", "over50", "gpu_p50", "gpu_p99",
	"render_cpu_p50", "process_p50", "process_p99", "draw_calls_p50", "primitives_p50", "ups", "bridge_avg", "bridge_p99", "bridge_worst", "seconds"]

## "quick", "default" or "extensive".
var mode := "default"
## perf_game.gd, or a stand-in with the same calls (the UI test's): prepare(say) -> bool,
## run_test(n, test, settings) -> Dictionary, cancel(), stop(), and `error` and `info`.
var runner: Node = null
var running := false

var _cancelled := false


## Stops the test: the running Zenith and the server end, no results file.
func cancel() -> void:
	_cancelled = true
	if runner != null:
		runner.cancel()


## Runs every test of the mode. {ok, error, file (full path), text, reports, exit_code}: exit_code 0
## when every test gave numbers, 2 when some didn't, 1 when the test stopped.
func run() -> Dictionary:
	running = true
	var started_at := Time.get_datetime_string_from_system(false, true).left(16)
	var started := Time.get_ticks_msec()
	var plan: Array = PLANS.get(mode, PLANS["default"])
	if runner == null:
		runner = PerfGame.new()
	if runner.get_parent() == null:
		add_child(runner)
	var say := func(text: String, fraction: float) -> void: progress.emit(text, fraction)
	say.call("Getting ready…", 0.0)
	var outcome := {"ok": false, "error": "", "file": "", "text": "", "reports": [], "exit_code": 1}
	if not await runner.prepare(say) or _cancelled:
		outcome["error"] = "cancelled" if _cancelled else str(runner.error)
		await runner.stop()
		running = false
		return outcome
	var results: Array = []
	for n in plan.size():
		var test: Array = plan[n]
		var what := describe(test)
		say.call("Test %d of %d: %s (about %s)…" % [n + 1, plan.size(), what, minutes(PerfGame.route_seconds(str(test[2])) + 25.0)],
			0.15 + 0.85 * n / plan.size())
		var row: Dictionary = await runner.run_test(n, test, child_settings(str(test[0]), str(test[1]), _factorio_exe()))
		if _cancelled or str(runner.error) != "":
			outcome["error"] = "cancelled" if _cancelled else str(runner.error)
			await runner.stop()
			running = false
			return outcome
		row.merge({"test": n + 1, "look": test[0], "preset": test[1], "route": test[2], "what": what}, true)
		results.append(row)
		if row.has("p50"):
			print("perf test: test %d took %s; frames p50 %.1f ms, p99 %.1f ms; %s UPS; bridge %s ms a tick" % [n + 1, minutes(float(row.get("seconds", 0.0))),
				float(row["p50"]), float(row.get("p99", 0.0)), fmt(row.get("ups")), fmt(row.get("bridge_avg"), 2)])
	say.call("Stopping Factorio…", 0.99)
	await runner.stop()
	var info: Dictionary = (runner.info as Dictionary).duplicate()
	info["took"] = (Time.get_ticks_msec() - started) / 1000.0
	info["started"] = started_at
	var text := results_text(mode, info, results, pc_lines())
	DirAccess.make_dir_recursive_absolute(RESULTS_DIR)
	var path := ProjectSettings.globalize_path(RESULTS_DIR).path_join("Zenith-perf-%s-%s.txt" % [version(), mode])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		outcome["error"] = "Couldn't write %s" % path
		running = false
		return outcome
	f.store_string(text)
	f.close()
	var reports := bench_reports(mode, results, info)
	_keep_last(mode, reports)
	running = false
	outcome.merge({"ok": true, "file": path, "text": text, "reports": reports,
		"exit_code": 0 if results.all(func(r: Dictionary) -> bool: return r.has("p50")) else 2}, true)
	return outcome


## "Factorio look, High, standing still"
static func describe(test: Array) -> String:
	return "%s, %s, %s" % [LOOKS.get(str(test[0]), str(test[0])), str(test[1]).capitalize(), ROUTES.get(str(test[2]), str(test[2]))]


## The test's own settings.cfg: the preset, full screen at the screen's resolution, vsync off, no
## FPS cap, Hold 60 UPS off, sound off, the Cinematic shaders add-on for the Cinematic look.
static func child_settings(look: String, preset: String, factorio_exe: String) -> Dictionary:
	var graphics := {"window_mode": "borderless", "resolution": "", "screen": -1, "vsync": false, "fps_cap": 0, "render_scale": 1.0,
		"antialiasing": "fxaa", "look": "factorio", "look_before": "factorio", "hold_ups": false, "render_thread": false,
		"merged_materials": false, "merge_far": true, "decoratives": true, "effects": true, "item_icons": true,
		"item_models_max": 20500, "belt_smooth": true}
	graphics.merge(PRESETS.get(preset, PRESETS["high"]), true)
	return {
		"graphics": graphics,
		"sound": {"master": 0.0},
		"interface": {"show_help": false, "debug_overlay": false},
		"factorio": {"executable": factorio_exe.replace("\\", "/"), "use_factorio_keys": false, "use_factorio_settings": false},
		"addons": {"cinematic-shaders": look == "cinematic", "terrain-elevation": false},
		"meta": {"grass_preset": true},
	}


static func version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "dev"))


static func _factorio_exe() -> String:
	return preload("res://scripts/menu/paths.gd").factorio_exe()


## This PC, from Godot's own calls: the processor, memory, graphics adapter and driver, how Zenith
## draws, the main screen, the system.
static func pc_lines() -> Array[String]:
	var memory := OS.get_memory_info()
	var gb := roundi(float(memory.get("physical", 0)) / 1073741824.0)
	var driver := OS.get_video_adapter_driver_info()
	var gpu := RenderingServer.get_video_adapter_name()
	var vendor := RenderingServer.get_video_adapter_vendor()
	if vendor != "" and not gpu.to_lower().contains(vendor.to_lower()):
		gpu += " (%s)" % vendor
	if driver.size() > 1 and str(driver[1]) != "":
		gpu += ", driver " + str(driver[1])
	var screen := DisplayServer.get_primary_screen()
	var size := DisplayServer.screen_get_size(screen)
	var hz := DisplayServer.screen_get_refresh_rate(screen)
	var system := OS.get_name()
	var build := OS.get_version()
	if system == "Windows" and build.get_slice(".", 2).to_int() >= 22000:
		system = "Windows 11"
	elif system == "Windows" and build.begins_with("10."):
		system = "Windows 10"
	elif system == "Linux":
		system = OS.get_distribution_name() if OS.get_distribution_name() != "" else "Linux"
	return [
		"  CPU:      %s (%d threads)" % [OS.get_processor_name().strip_edges(), OS.get_processor_count()],
		"  RAM:      %s" % ("%d GB" % gb if gb > 0 else "?"),
		"  GPU:      " + (gpu if gpu != "" else "?"),
		"  Zenith drew with: %s, %s renderer" % [(RenderingServer.get_current_rendering_driver_name() + " " + RenderingServer.get_video_adapter_api_version()).strip_edges(),
			RenderingServer.get_current_rendering_method()],
		"  Screen:   %d x %d at %s Hz" % [size.x, size.y, str(roundi(hz)) if hz > 0.0 else "?"],
		"  System:   %s (%s)" % [system, build],
	]


## The results file, as the earlier script wrote it.
static func results_text(mode_id: String, info: Dictionary, results: Array, pc: Array[String]) -> String:
	var stand := PerfGame.route_seconds("stand")
	var laps := PerfGame.route_seconds("fast")
	var out: Array[String] = [
		"Zenith performance test",
		"=======================",
		"",
		"Zenith %s, %s mode, run %s, took %s." % [version(), mode_id, str(info.get("started", "?")), minutes(float(info.get("took", 0.0)))],
		"",
		"This PC",
	]
	out.append_array(pc)
	out.append("  Factorio: %s %s" % [str(info.get("factorio", "?")), "with Space Age" if bool(info.get("space_age", false)) else "without Space Age"])
	out.append_array([
		"",
		"How it was run",
		"  Zenith started fresh for each test, full screen at the screen's own resolution, vsync off, no",
		"  FPS cap, Hold 60 UPS off, sound off, its own settings (the preset named in each test).",
		"  The scene: a new map (seed %d, no enemies, always noon) on a headless Factorio, with a test" % PerfGame.SEED,
		"  base of %s buildings north-west of the character: 12 belt loops and a bus full of items," % str(info.get("buildings", "?")),
		"  36 assemblers with inserters, a roboport with 50 robots flying.",
		"  Standing: %d s standing still looking at the base. Running laps: %d s of two laps round it" % [int(stand), int(laps)],
		"  at exoskeleton speed (about 30 tiles a second), new ground coming into view all the time.",
		"  Frame times are Zenith's frames during that time (the first 15 s after joining are left out).",
		"",
		"| # | Test | Frames | Middle frame | FPS | Slowest 1% | Worst | Over 16.7 ms | Over 33 ms | GPU | Draw calls | UPS | Bridge a tick | Bridge slowest 1% |",
		"|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
	])
	for r: Dictionary in results:
		var fps: Variant = null
		if r.get("p50") is float and float(r["p50"]) > 0.0:
			fps = 1000.0 / float(r["p50"])
		out.append("| %s | %s%s | %s | %s ms | %s | %s ms | %s ms | %s | %s | %s ms | %s | %s | %s ms | %s ms |" % [
			str(r.get("test", "?")), str(r.get("what", "?")), " (%s)" % r["note"] if r.has("note") else "", fmt(r.get("frames"), 0),
			fmt(r.get("p50")), fmt(fps, 0), fmt(r.get("p99")), fmt(r.get("worst")), fmt(r.get("over16"), 0), fmt(r.get("over33"), 0),
			fmt(r.get("gpu_p50")), fmt(r.get("draw_calls_p50"), 0), fmt(r.get("ups")), fmt(r.get("bridge_avg"), 2), fmt(r.get("bridge_p99"), 2)])
	out.append_array(["", "Middle frame is the median (p50), Slowest 1% the 99th percentile; GPU is the graphics card's time for a middle",
		"frame. UPS is the game's speed (60 is full speed), the bridge is the Zenith mod's time inside Factorio each tick.",
		"", "For the project's tools (one line per test):", "", ",".join(CSV_KEYS)])
	for r: Dictionary in results:
		var cells := PackedStringArray()
		for key in CSV_KEYS:
			var v: Variant = r.get(key)
			cells.append(_csv(v))
		out.append(",".join(cells))
	return "\n".join(out) + "\n"


## Each test as a bench_runner.gd report, for the debug menu's report window (debug_menu.gd).
static func bench_reports(mode_id: String, results: Array, info: Dictionary) -> Array:
	var size := DisplayServer.screen_get_size(DisplayServer.get_primary_screen())
	var reports: Array = []
	for r: Dictionary in results:
		var preset := str(r.get("preset", "high"))
		var p: Dictionary = PRESETS.get(preset, PRESETS["high"])
		var walk := PerfGame.route_seconds(str(r.get("route", "")))
		var report := {"bench": "perf-%s-%s" % [mode_id, r.get("test", 0)], "name": "Test %s: %s" % [r.get("test", "?"), r.get("what", "?")],
			"when": str(info.get("started", "")), "seconds": walk,
			"setup": {"version": version(), "preset": preset, "look": str(r.get("look", "?")), "resolution": "%dx%d" % [size.x, size.y],
				"render_scale": 1.0, "shadows": p["shadows"], "lod": p["lod_quality"], "view_radius": p["view_radius"],
				"entity_radius": p["entity_radius"], "vsync": false, "fps_cap": 0, "hold_60_ups": false, "render_thread": false}}
		for key in ["p50", "p99", "worst", "over16", "over33", "gpu_p50", "gpu_p99", "render_cpu_p50", "process_p50", "draw_calls_p50",
				"primitives_p50", "ups"]:
			if r.has(key):
				report[key] = snappedf(float(r[key]), 0.01)
		if r.has("frames") and walk > 0.0:
			report["fps"] = snappedf(float(r["frames"]) / walk, 0.1)
		if r.has("bridge_avg"):
			report["bridge_ms"] = snappedf(float(r["bridge_avg"]), 0.001)
		else:
			report["bridge_note"] = "no trace from the bridge"
		if r.has("note"):
			report["bridge_note"] = str(r["note"])
		reports.append(report)
	var last := _lasts()
	var prev: Array = last.get(mode_id, []) if last.get(mode_id) is Array else []
	for i in mini(reports.size(), prev.size()):
		if prev[i] is Dictionary and str(prev[i].get("name", "")) == str(reports[i]["name"]):
			reports[i]["previous"] = prev[i]
	return reports


static func _lasts() -> Dictionary:
	var file := RESULTS_DIR.path_join("last.json")
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(file)) if FileAccess.file_exists(file) else null
	return parsed if parsed is Dictionary else {}


## This run's reports, the previous ones for the next run of the mode.
static func _keep_last(mode_id: String, reports: Array) -> void:
	var last := _lasts()
	var kept: Array = []
	for r: Dictionary in reports:
		var copy := r.duplicate(true)
		copy.erase("previous")
		kept.append(copy)
	last[mode_id] = kept
	var f := FileAccess.open(RESULTS_DIR.path_join("last.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(last, "\t"))


## "2 min 58 s", "45 s"
static func minutes(seconds: float) -> String:
	var m := floori(seconds / 60.0)
	var s := roundi(seconds - 60.0 * m)
	if s == 60:
		m += 1
		s = 0
	return "%d s" % s if m < 1 else "%d min %d s" % [m, s]


## A number with `places` decimals, "-" when there is none.
static func fmt(v: Variant, places := 1) -> String:
	if not (v is float or v is int):
		return "-"
	return ("%." + str(places) + "f") % float(v) if places > 0 else str(roundi(float(v)))


## Up to three decimals, without trailing zeros.
static func _csv(v: Variant) -> String:
	if v is float:
		return str(int(v)) if v == floorf(v) and absf(v) < 1e15 else String.num(v, 3)
	return str(v) if v != null else ""
