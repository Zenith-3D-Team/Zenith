## The performance warning (perf_warning.gd, perf_log.gd) in a running client against the mock (testing agent's
## probe; not part of any suite). Loads the main scene, plays normally for --normal=<s> seconds counting the log's
## entries by source and the icon's redraws, then slows the mock with /f3d-debug speed 0.8 (48 UPS) so the UPS governor
## steps for real: the icon, its count, the panel's lines, the panel open while entries arrive, the Remote view's row,
## a hidden interface, F6, the setting flipped with the panel open, Copy; back at speed 1 the steps come back, the
## entries are restored and the icon lingers 10 s. Then slowed again until "the steps bought nothing", and a new game
## (end_game, start_game) clears the log. Prints "probe:" lines and "PROBE FAILS n" at the end; exits 0 / 1.
## godot --headless --audio-driver Dummy --path client res://tests/perf_warning_probe.tscn -- --factorio-port=<mock> --port=<own>
extends Node

const PerfLog := preload("res://scripts/world/perf_log.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const UpsGovernor := preload("res://scripts/world/ups_governor.gd")
const Kit := preload("res://scripts/ui/factorio/kit.gd")

var main: Node
var fails := 0
var draws := 0
var log_calls := 0
var t0 := 0


func say(s: String) -> void:
	print("probe [%6.1f s]: %s" % [(Time.get_ticks_msec() - t0) / 1000.0, s])


func check(ok: bool, s: String) -> void:
	if not ok:
		fails += 1
	say(("ok   " if ok else "FAIL ") + s)


func _arg(prefix: String, def: float) -> float:
	var v := Settings.arg_value(prefix)
	return float(v) if v != "" else def


func _ready() -> void:
	t0 = Time.get_ticks_msec()
	get_window().size = Vector2i(1920, 1080)  # headless windows start at 64 x 64
	var watchdog := get_tree().create_timer(_arg("--time-limit=", 900.0))
	watchdog.timeout.connect(func() -> void:
		say("time limit")
		fails += 1
		_finish())
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child.call_deferred(main)
	await _run()
	_finish()


func _finish() -> void:
	say("PROBE FAILS %d" % fails)
	get_tree().quit(1 if fails > 0 else 0)


func _wait(secs: float) -> void:
	await get_tree().create_timer(secs).timeout


func _wait_for(f: Callable, secs: float, step := 0.25) -> bool:
	var until := Time.get_ticks_msec() + int(secs * 1000.0)
	while Time.get_ticks_msec() < until:
		if f.call():
			return true
		await _wait(step)
	return bool(f.call())


func _counts() -> Dictionary:
	var out := {}
	for e: Dictionary in PerfLog.entries:
		var k := "%s/%s" % [e["source"], e["key"]]
		out[k] = int(out.get(k, 0)) + 1
	return out


func _speed(x: float) -> void:
	main.hud.ui.model.command("/f3d-debug speed %s" % x)
	say("mock speed %s" % x)


func _run() -> void:
	var is_ready := func() -> bool: return Bridge.world_ready and main.get("hud") != null and main.hud.ui.perf_warning != null and main.ups_governor != null
	var ready := await _wait_for(is_ready, 60.0)
	check(ready, "the world is ready")
	if not ready:
		return
	var ui = main.hud.ui
	var pw = ui.perf_warning
	var g = main.ups_governor
	var fb: Button = ui.factorio_button
	check(g.enabled, "Hold 60 UPS on (the default)")
	pw.button.draw.connect(func() -> void: draws += 1)
	PerfLog.listen(func() -> void: log_calls += 1)
	check(not pw.has_method("_process") and not pw.is_processing() and not pw.button.is_processing(),
		"no _process on the warning or its button (pw %s, button %s)" % [pw.is_processing(), pw.button.is_processing()])

	# 1. Normal play: what the logged-only sources write, and what the icon costs while nothing changes.
	var normal := _arg("--normal=", 120.0)
	say("normal play for %d s" % normal)
	var d0 := draws
	var l0 := log_calls
	var frames0 := Engine.get_process_frames()
	var levels := {}
	var until := Time.get_ticks_msec() + int(normal * 1000.0)
	var ups_min := 999.0
	while Time.get_ticks_msec() < until:
		await _wait(1.0)
		levels[g.level] = true
		if g.ups > 0.0:
			ups_min = minf(ups_min, g.ups)
	var frames := Engine.get_process_frames() - frames0
	say("normal play: %d frames, governor levels seen %s, lowest 3 s UPS %.1f, budget now %d, Automatic cap %d" % [frames, levels.keys(), ups_min, g.budget,
		int(load("res://scripts/world/belt_lanes.gd").auto_cap)])
	say("normal play: %d log entries %s, %d log changes, %d icon redraws, icon shown %s" % [PerfLog.entries.size(), _counts(), log_calls - l0, draws - d0, pw.visible])
	for e: Dictionary in PerfLog.entries:
		say("  entry: " + PerfLog.line(e))
	check(PerfLog.entries.size() <= 6, "normal play: the logged-only sources write few entries (%d in %d s)" % [PerfLog.entries.size(), normal])
	check(draws - d0 <= log_calls - l0 + 2, "normal play: the icon redraws only when the log changes (%d redraws, %d changes)" % [draws - d0, log_calls - l0])

	# The per-call costs of what runs often: the budget's log check (each BUDGET_EVERY), the square's (each `bs`),
	# Automatic's (each change of its cap), active() at the cap.
	var lanes = main.belt_lanes
	var n := 20000
	var t := Time.get_ticks_usec()
	for i in n:
		g._log_budget()
	var us_budget := float(Time.get_ticks_usec() - t) / n
	t = Time.get_ticks_usec()
	for i in n:
		lanes.log_square()
	var us_square := float(Time.get_ticks_usec() - t) / n
	t = Time.get_ticks_usec()
	for i in n:
		PerfLog.active()
	var us_active := float(Time.get_ticks_usec() - t) / n
	say("costs with %d entries: _log_budget %.2f us, log_square %.2f us, PerfLog.active %.2f us a call" % [PerfLog.entries.size(), us_budget, us_square, us_active])

	# 2. The game slowed: the governor steps for real.
	var entries_before := PerfLog.entries.size()
	_speed(0.8)
	var lit := await _wait_for(func() -> bool: return g.level >= 1 and pw.visible, 60.0)
	check(lit and pw.count() >= 1 and pw.button.count == pw.count(), "slowed: the governor steps and the icon shows with its count (level %d, count %d, ups %.1f)" % [g.level, pw.count(), g.ups])
	var t_lit := Time.get_ticks_msec()
	ui.layout()
	check(fb.visible == ui.show_factorio.is_valid(), "the Factorio button's visibility %s" % fb.visible)
	var want_pos: Vector2 = fb.position + (Vector2(Kit.px(Kit.SLOT + 4), 0.0) if fb.visible else Vector2.ZERO)
	check(pw.position == want_pos, "the icon at %s (button %s at %s)" % [pw.position, "shown" if fb.visible else "hidden", fb.position])
	var tip = pw.button.get_meta("tip", [])
	say("tooltip: %s" % [tip])
	# The panel opened by a click, and open while more entries arrive.
	pw.button.pressed.emit()
	await get_tree().process_frame
	var rows0: int = pw._rows.get_child_count()
	say("panel at the first step:\n" + pw.rows_text())
	var more := await _wait_for(func() -> bool: return g.level >= 3, 60.0)
	await get_tree().process_frame
	var rows1: int = pw._rows.get_child_count()
	check(more and pw.is_open() and rows1 > rows0 and rows1 == PerfLog.entries.size(),
		"the panel open while entries arrive: rows %d -> %d (entries %d, level %d)" % [rows0, rows1, PerfLog.entries.size(), g.level])
	var text: String = pw.rows_text()
	say("panel at level %d:\n%s" % [g.level, text])
	var ups_rows := PerfLog.entries.filter(func(e: Dictionary) -> bool: return e["source"] == "ups")
	var good := not ups_rows.is_empty()
	for e: Dictionary in ups_rows:
		var w := PerfLog.what(e)
		good = good and w.contains(" → ") and str(e["why"]).begins_with("game at ") and str(e["time"]).length() == 8 and text.contains(w)
	check(good, "each governor entry has from → to, why and the time of day, and is in the panel")
	# Panel size: on screen, not off the right or bottom.
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var r: Rect2 = pw.panel.get_global_rect()
	say("panel rect %s in a viewport of %s" % [r, vp])
	check(r.end.x <= vp.x and r.end.y <= vp.y, "the panel fits the window")
	# Copy.
	var copy: Button = pw.panel.find_child("Copy", true, false)
	copy.pressed.emit()
	var clip := DisplayServer.clipboard_get()
	say("Copy: clipboard %d chars (headless may have no clipboard); PerfLog.text():\n%s" % [clip.length(), PerfLog.text()])
	check(clip == "" or clip == PerfLog.text(), "Copy puts the log's text on the clipboard (or headless has none)")
	check(PerfLog.text().split("\n").size() == PerfLog.entries.size(), "Copy's text has one line per entry")

	# The Remote view's row.
	ui.remote_view(Vector2(20, 20))
	await _wait(0.5)
	ui.layout()
	await get_tree().process_frame
	var in_frame: bool = ui.remote_frame.visible
	var lt: float = ui.remote_frame.left_top
	check(in_frame and pw.visible and absf(pw.position.y - fb.position.y) < 0.5 and lt >= pw.position.y + 40.0,
		"Remote view: the icon in the row under the title bar (icon %s, button %s, frame's panels start at %.0f)" % [pw.position, fb.position, lt])
	var pr: Rect2 = pw.panel.get_global_rect()
	say("Remote view: the open panel at %s; the frame's left panels start at y %.0f (the panel %s them)" % [pr, lt, "overlaps" if pr.end.y > lt else "clears"])
	ui.end_remote_view()
	await _wait(0.5)
	ui.layout()
	await get_tree().process_frame
	check(pw.position == want_pos, "after the Remote view the icon is back at %s (%s)" % [want_pos, pw.position])

	# A hidden interface (F11, an add-on's hide_interface): the icon hides with the HUD and comes back.
	var who := {"id": "perf-probe"}
	main.addons.request_hidden(who, true)
	await get_tree().process_frame
	var hidden_ok: bool = not pw.is_visible_in_tree()
	main.addons.request_hidden(who, false)
	await get_tree().process_frame
	check(hidden_ok and pw.is_visible_in_tree(), "a hidden interface hides the icon; shown again it is back")
	# F6, Factorio's view: the HUD stays, the icon with it.
	var rig = main.addons.rig()
	if rig != null and rig.has_method("toggle_factorio_view"):
		rig.toggle_factorio_view()
		await _wait(1.0)
		var f6_ok: bool = pw.is_visible_in_tree() and pw.position == want_pos
		rig.toggle_factorio_view()
		await _wait(1.0)
		check(f6_ok, "F6 (Factorio's view): the icon stays where it was")
	# The setting flipped while the panel is open.
	pw.set_open(true)
	Settings.set_value("interface", "perf_warning", false)
	await get_tree().process_frame
	var off_ok: bool = not pw.visible and not pw.is_open()
	Settings.set_value("interface", "perf_warning", true)
	await get_tree().process_frame
	check(off_ok and pw.visible and not pw.is_open(), "the setting off with the panel open closes it and hides the icon; on again the icon is back (panel closed)")
	ui.layout()

	# 3. Back at speed 1: the steps come back, each entry restored; the icon lingers 10 s.
	_speed(1.0)
	var back := await _wait_for(func() -> bool: return g.level == 0, 400.0, 0.1)
	var t_back := Time.get_ticks_msec()
	check(back, "back at speed 1: the governor back at level 0 after %.0f s" % ((t_back - t_lit) / 1000.0))
	var all_ended := true
	for e: Dictionary in PerfLog.entries:
		if e["source"] == "ups" and e["lights"]:
			all_ended = all_ended and e.has("ended_msec")
	check(all_ended and pw.count() == 0, "every governor entry ended (count %d)" % pw.count())
	var still: bool = pw.visible
	var gone := await _wait_for(func() -> bool: return not pw.visible, 20.0, 0.1)
	var linger := (Time.get_ticks_msec() - t_back) / 1000.0
	check(still and gone and linger >= 9.5 and linger <= 11.0, "the icon lingers %.1f s after the last restore (want 10)" % linger)
	pw.set_open(true)
	say("the log after the restore (Copy's text):\n" + PerfLog.text())
	var restored_lines := PerfLog.entries.filter(func(e: Dictionary) -> bool: return e["source"] == "ups" and str(e.get("ended", "")).begins_with("restored, back at 60 for"))
	check(not restored_lines.is_empty(), "restored entries say \"restored, back at 60 for N s\" (%d)" % restored_lines.size())
	pw.set_open(false)

	# 4. Slowed until the steps buy nothing: every step taken, then all back with that reason.
	if _arg("--no-gain=", 1.0) > 0.0:
		_speed(0.8)
		var gave_up := func() -> bool:
			for e: Dictionary in PerfLog.entries:
				if str(e.get("ended", "")).contains("the steps bought nothing"):
					return true
			return false
		var nothing := await _wait_for(gave_up, 300.0, 0.5)
		check(nothing, "slowed for good: the governor gives up with \"the steps bought nothing\" (level %d)" % g.level)
		_speed(1.0)
		await _wait_for(func() -> bool: return g.level == 0, 120.0)
		say("entries by source after the second slow-down: %s (%d)" % [_counts(), PerfLog.entries.size()])
		var s := ""
		for e: Dictionary in PerfLog.entries:
			if str(e.get("ended", "")).contains("bought nothing"):
				s = PerfLog.line(e)
				break
		say("e.g. " + s)

	# 5. A new game clears the log.
	var had := PerfLog.entries.size()
	main.end_game()
	await _wait(1.0)
	main.start_game()
	await _wait(1.0)
	check(had > 0 and PerfLog.entries.is_empty(), "a new game clears the log (%d -> %d)" % [had, PerfLog.entries.size()])

