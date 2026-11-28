extends "res://tests/ui_test_base.gd"
## UI test sections: backdrop.

func _menu_backdrop() -> void:
	var cam_was := get_viewport().get_camera_3d()
	var file := "user://ui-test-backdrop.json.gz"
	var list_was := _backdrop_list_folder("user://ui-test-backdrops")
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(MOCK_MENU_WORLD))
	var source: Array = parsed["messages"]
	var view := Transform3D(Basis(Vector3.UP, 0.6) * Basis(Vector3.RIGHT, -0.8), Vector3(20.0, 30.0, 40.0))
	var cam := Camera3D.new()
	cam.fov = 40.0
	add_child(cam)
	cam.global_transform = view
	var camera: Dictionary = BackdropRecorderScript.camera_dict(cam)
	cam.queue_free()
	var rec: Node = BackdropRecorderScript.new()
	rec.path = file
	add_child(rec)
	rec.set_process(false)
	var outcome: Array = []
	rec.done.connect(func(p: String) -> void: outcome.append(p))
	rec.failed.connect(func(r: String) -> void: outcome.append("failed: " + r))
	check(not rec.record(Vector2(16, 16), camera), "backdrop: nothing to record before the handshake's prototypes")
	DirAccess.remove_absolute(file)
	_feed_backdrop(rec, source, true)
	Bridge.capture.clear()
	check(rec.record(Vector2(16, 16), camera, {"save": "ui-test-save", "puppet": 900}), "backdrop: a recording starts")
	var asked: Array = Bridge.capture.map(func(t: String) -> Variant: return JSON.parse_string(t)).filter(func(m: Variant) -> bool: return m is Dictionary and m.get("t") == "resync")
	check(asked.size() == 1 and int(asked[0].get("full", 1)) == 0 and not asked[0].has("c"),
		"backdrop: it asks for every chunk again (resync full 0): %s" % [Bridge.capture])
	# A chunk out of the square, and its entities, come too.
	rec.on_message({"t": "chunk", "cx": 6, "cy": 6, "parts": 1, "tiles": [], "k": 1})
	rec.on_message({"t": "ents", "cx": 6, "cy": 6, "part": 1, "parts": 1, "e": [], "k": 1})
	_feed_backdrop(rec, source, false)
	check(outcome == [file], "backdrop: recorded once the square's chunks are in and its seconds are up: %s" % [outcome])
	var snap: Dictionary = BackdropRecorderScript.read(file)
	var messages: Array = snap.get("messages", [])
	var kinds := {}
	var chunks: Array = []
	var puppet_seen := false
	var dts: Array = []
	for m: Dictionary in messages:
		var t := str(m.get("t"))
		kinds[t] = int(kinds.get(t, 0)) + 1
		if t == "chunk":
			chunks.append(Vector2i(int(m["cx"]), int(m["cy"])))
		if t == "mv":
			for r in m.get("l", []):
				puppet_seen = puppet_seen or int(r[0]) == 900
		dts.append(float(m.get("dt", -1.0)))
	var sorted := dts.duplicate()
	sorted.sort()
	var raw := JSON.stringify(snap).length()
	print("backdrop: the mock's snapshot: %d messages, %d KB raw, %d KB in the file, kinds %s" % [messages.size(), raw / 1024,
		FileAccess.open(file, FileAccess.READ).get_length() / 1024, kinds])
	check(int(snap.get("v", 0)) == 1 and str(snap.get("save")) == "ui-test-save" and int(snap.get("puppet", 0)) == 900
		and snap.get("center") == [16.0, 16.0] and (snap.get("camera", {}) as Dictionary).get("fov") == 40.0,
		"backdrop: the file has its version, save, puppet, centre and camera")
	var in_square: bool = chunks.all(func(c: Vector2i) -> bool: return absi(c.x) <= 2 and absi(c.y) <= 2)
	check(chunks.size() == 25 and in_square and int(kinds.get("ents", 0)) == 36, "backdrop: only the square's 25 chunks and their entities are kept: %d chunks" % chunks.size())
	check(int(kinds.get("protos", 0)) == 3 and int(kinds.get("iprotos", 0)) == 2 and kinds.has("tprotos") and kinds.has("fprotos"),
		"backdrop: the handshake's prototypes are in it")
	check(int(kinds.get("mv", 0)) > 100 and not puppet_seen and kinds.has("bs") and kinds.has("ih") and not kinds.has("fl"),
		"backdrop: the live updates are kept, the player's own character left out of the movers")
	check(dts == sorted and float(dts[-1]) > 5.0 and float(dts[-1]) <= BackdropRecorderScript.LIVE_SECONDS + 0.01,
		"backdrop: the messages' dt rises over the recorded seconds: last %.2f" % float(dts[-1]))
	var again := "user://ui-test-backdrop-2.json.gz"
	check(BackdropRecorderScript.write(again, snap) and JSON.stringify(BackdropRecorderScript.read(again)) == JSON.stringify(snap)
		and not FileAccess.file_exists(again + ".tmp"), "backdrop: write and read give the snapshot back the same")
	# Written again over the file with a .tmp left from an earlier run (an old client killed mid-write), the JSON
	# given made already (_finish's way): the new snapshot read back, the old .tmp gone (testing agent, the second recording).
	var stale := FileAccess.open(again + ".tmp", FileAccess.WRITE)
	stale.store_string("not gzip: left over")
	stale.close()
	var snap2 := snap.duplicate()
	snap2["save"] = "second"
	check(BackdropRecorderScript.write(again, snap2, JSON.stringify(snap2)) and str(BackdropRecorderScript.read(again).get("save")) == "second"
		and not FileAccess.file_exists(again + ".tmp"), "backdrop: a second write over the file and a stale .tmp gives the new snapshot, no .tmp left")
	DirAccess.remove_absolute(again)
	var dm: Dictionary = BackdropRecorderScript.without_unit({"t": "mv", "z": 1, "l": [[5, 1, 100, 100], [895, 0, 10, 10], [1, 2, 0, 0, 7]]}, 900)
	check(dm.get("l") == [[5, 1, 100, 100], [901, 3, 110, 110, 7]] and not dm.has("z"),
		"backdrop: a delta-coded mv without the character is written out plain: %s" % [dm.get("l")])
	# The menu draws it, the camera at the saved view.
	var path_was: String = MenuBackgroundScript.snapshot_path
	MenuBackgroundScript.snapshot_path = file
	Settings.set_value("interface", "backdrop", "snapshot")
	var bg: Node = MenuBackgroundScript.new()
	add_child(bg)
	check(bg.source == "snapshot" and bg.world.entities.size() > 50 and bg.camera.global_transform.is_equal_approx(view)
		and bg._movers.puppet_unit == 900 and is_equal_approx(bg.camera.fov, 40.0),
		"backdrop: the menu draws the snapshot (%d entities) from the saved view" % bg.world.entities.size())
	# lighting-fixes step 6: lit as a game at noon under the Factorio look (looks.gd noon_rig), not its own light.
	var bg_suns: Array = bg.find_children("*", "DirectionalLight3D", false, false)
	var bg_rig := LooksScript.noon_rig()
	var bg_env: Environment = bg._env
	var bg_fill: DirectionalLight3D = bg._fill
	check(bg_suns.size() == 2 and (bg_suns[0] as DirectionalLight3D).rotation_degrees.is_equal_approx(bg_rig["sun_rotation"])
		and bg_fill != null and is_equal_approx(bg_fill.light_energy, float(bg_rig["fill_light"])) and (bg_fill.light_cull_mask & Visuals.GROUND_LAYER) == 0
		and bg_env.ambient_light_source == Environment.AMBIENT_SOURCE_SKY and bg_env.tonemap_mode == int(bg_rig["tonemap"])
		and bg_env.sky != null and float((bg_env.sky.sky_material as ShaderMaterial).get_shader_parameter("env_on")) > 0.5,
		"backdrop: lit as a game at noon (the Factorio look's sun and fill light, the sky cubemap's environment, its tonemapping)")
	remove_child(bg)
	bg.queue_free()
	# The built-in world (the owner's snapshot, from its saved view): the setting, --menu-backdrop=default,
	# a missing file, a broken file.
	var shipped: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MenuBackgroundScript.DATA))
	var shipped_view = BackdropRecorderScript.camera_transform(shipped.get("camera"))
	var builtin := func(why: String) -> void:
		var b: Node = MenuBackgroundScript.new()
		add_child(b)
		check(b.source == "default" and b.world.entities.size() > 50 and shipped_view != null and b._view == shipped_view
			and b.camera.global_transform.is_equal_approx(shipped_view), "backdrop: the built-in world with %s, from its saved view" % why)
		remove_child(b)
		b.queue_free()
	Settings.set_value("interface", "backdrop", "default")
	builtin.call("backdrop = default")
	Settings.set_value("interface", "backdrop", "snapshot")
	MenuBackgroundScript.force_default = true
	builtin.call("--menu-backdrop=default")
	MenuBackgroundScript.force_default = false
	MenuBackgroundScript.snapshot_path = "user://ui-test-no-backdrop.json.gz"
	builtin.call("the file missing")
	MenuBackgroundScript.snapshot_path = "user://ui-test-broken-backdrop.json.gz"
	_write(MenuBackgroundScript.snapshot_path, "not a snapshot")
	builtin.call("a broken file")
	DirAccess.remove_absolute(MenuBackgroundScript.snapshot_path)
	MenuBackgroundScript.snapshot_path = file
	# The default as shipped (0.2.2: the owner's snapshot): its entities, its 5 x 5 chunks' ground made, no
	# text the owner typed (tools/make_menu_backdrop.py), and the old drift behind --menu-backdrop-camera=drift.
	Settings.set_value("interface", "backdrop", "default")
	var shown_default: Node = MenuBackgroundScript.new()
	add_child(shown_default)
	var grounds := 0
	for i in 300:
		await get_tree().process_frame
		grounds = 0
		for c in shown_default.world.chunks:
			if shown_default.world.chunks[c].has_ground() and not shown_default.world.chunks[c].tile_ids.is_empty():
				grounds += 1
		if grounds >= 25 and shown_default.world.terrain_queue_size() == 0:
			break
	var stops: Array = []
	for m in shipped["messages"]:
		if m is Dictionary and m.get("t") == "ents":
			for e in m["e"]:
				if e is Array and e.size() > 5 and e[5] is Dictionary and e[5].has("n"):
					stops.append(e[5]["n"])
	check(shown_default.source == "default" and shown_default.world.entities.size() > 300 and grounds == 25
		and not shipped.has("save") and not shipped.has("taken") and stops.all(func(n: Variant) -> bool: return n == "Train stop"),
		"backdrop: the shipped default draws %d entities on %d chunks of ground; no save name, stop names %s" % [shown_default.world.entities.size(), grounds, stops])
	remove_child(shown_default)
	shown_default.queue_free()
	MenuBackgroundScript.camera_drift = true
	var drifting: Node = MenuBackgroundScript.new()
	add_child(drifting)
	check(drifting.source == "default" and drifting._view == null, "backdrop: --menu-backdrop-camera=drift: the default's camera drifts as before 0.2.2")
	MenuBackgroundScript.camera_drift = false
	remove_child(drifting)
	drifting.queue_free()
	Settings.set_value("interface", "backdrop", "snapshot")

	# The menus: Menu backdrop's window on the main menu, its choices, the Esc menu's button.
	var fe: Node = FrontEndScript.new()
	add_child(fe)
	await get_tree().process_frame
	var stand := GDScript.new()
	stand.source_code = "extends Node\nvar hud = null\nvar addons = null\nvar world = null\nvar rig = null\nvar avatar = null\nvar backdrop_recorder = null\nfunc set_game_input(_on: bool) -> void:\n\tpass\n"
	stand.reload()
	var fake_main: Node = stand.new()
	fe.add_child(fake_main)
	fe.main = fake_main
	fe._show_background(true)
	var bg_was: Node = fe._background
	check(bg_was != null and bg_was.source == "snapshot", "backdrop: the main menu shows the snapshot")
	fe._show_main_menu()
	var names: Array = fe._page.find_child("Buttons", true, false).get_children().map(func(b: Node) -> String: return b.name)
	check(names.find("Menubackdrop") == names.find("Modelpacks") + 1, "backdrop: the main menu has Menu backdrop after Model packs: %s" % [names])
	var open := fe._page.find_child("Menubackdrop", true, false) as Button
	if open != null:
		open.pressed.emit()
	var window: Node = fe._overlays.back() if not fe._overlays.is_empty() else null
	var shown: String = (window.find_child("Shown", true, false) as Label).text if window != null and window.name == "MenuBackdrop" else ""
	check(shown.contains("Shown now: \"ui-test-save, ") and shown.contains("Esc > Use this view as the menu backdrop")
		and window.find_child("ChooseFromAWorld", true, false) != null, "backdrop: its window says what is shown and how to record one: %s" % shown)
	var reset := _backdrop_use(window, "Default")
	if reset != null:
		reset.pressed.emit()
	window = fe._overlays.back() if not fe._overlays.is_empty() else null
	check(Settings.get_value("interface", "backdrop") == "default" and fe._background != bg_was and fe._background.source == "default"
		and window != null and (window.find_child("Shown", true, false) as Label).text.begins_with("Shown now: Zenith's own factory"),
		"backdrop: Default backdrop resets the setting and the background is made again")
	# The snapshot put into the list: its Use shows it.
	var listed_id: String = BackdropListScript.new_id(1700000000)
	DirAccess.copy_absolute(file, BackdropListScript.path_of(listed_id))
	BackdropListScript.add(listed_id, "Listed one", 1700000000)
	fe._pop_overlay()
	fe._show_backdrop_window()
	window = fe._overlays.back()
	var mine := _backdrop_use(window, listed_id)
	if mine != null:
		mine.pressed.emit()
	check(Settings.get_value("interface", "backdrop") == listed_id and fe._background.source == "snapshot", "backdrop: a listed one's Use brings it back")
	var choose := fe._overlays.back().find_child("ChooseFromAWorld", true, false) as Button
	choose.pressed.emit()
	check(fe._overlays.is_empty() and fe._page.name == "Worlds", "backdrop: Choose from a world opens Load game")
	# A Model packs change: the background made again; no change: the same.
	bg_was = fe._background
	fe._show_model_packs()
	var packs: Node = fe._overlays.back().find_child("ModelPacksWindow", true, false)
	packs.closed.emit()
	check(fe._background == bg_was, "backdrop: the Model packs window closed with nothing changed keeps the background")
	await get_tree().process_frame
	fe._show_model_packs()
	packs = fe._overlays.back().find_child("ModelPacksWindow", true, false)
	ModelPacksScript.version += 1
	packs.closed.emit()
	ModelPacksScript.version -= 1
	check(fe._background != bg_was and fe._background != null and fe._overlays.is_empty(), "backdrop: a Model packs change makes the background again")
	fe._show_background(false)
	await get_tree().process_frame
	# The Esc menu's button and its recording, with stand-ins for the game's camera rig and character.
	var rig_script := GDScript.new()
	rig_script.source_code = "extends Node3D\nvar camera := Camera3D.new()\nfunc _ready() -> void:\n\tadd_child(camera)\nfunc focus_point() -> Vector2:\n\treturn Vector2(16, 16)\n"
	rig_script.reload()
	var rig: Node3D = rig_script.new()
	fake_main.add_child(rig)
	rig.camera.global_transform = view
	var rec2: Node = BackdropRecorderScript.new()
	rec2.path = file
	fake_main.add_child(rec2)
	rec2.set_process(false)
	fake_main.rig = rig
	fake_main.backdrop_recorder = rec2
	fe.state = FrontEndScript.State.PLAYING
	Settings.set_value("interface", "backdrop", "default")
	_feed_backdrop(rec2, source, true)
	fe._toggle_esc_menu()
	var use := fe._esc_menu.find_child("UseAsBackdrop", true, false) as Button
	var names_esc: Array = use.get_parent().get_children().map(func(b: Node) -> String: return b.name) if use != null else []
	check(use != null and use.text == "Use this view as the menu backdrop" and not use.disabled and names_esc.find("UseAsBackdrop") == names_esc.find("ModelPacks") + 1,
		"backdrop: the Esc menu has Use this view as the menu backdrop, beside Model packs")
	if use != null:
		use.pressed.emit()
	check(fe._esc_menu == null and fe._recording_backdrop and rec2.recording() and not fe._progress.is_empty()
		and (fe._progress["label"] as Label).text == "Recording the view…", "backdrop: it records behind a progress box")
	_feed_backdrop(rec2, source, false)
	var said: Node = fe._overlays.back() if not fe._overlays.is_empty() else null
	var recorded_id := str(Settings.get_value("interface", "backdrop"))
	check(not fe._recording_backdrop and fe._progress.is_empty() and said != null and _texts(said).has("Saved. It shows at the main menu.")
		and BackdropListScript.valid_id(recorded_id) and recorded_id != listed_id and FileAccess.file_exists(BackdropListScript.path_of(recorded_id))
		and not BackdropRecorderScript.read(BackdropListScript.path_of(recorded_id)).is_empty(),
		"backdrop: then says it is saved, adds it to the list and shows it at the main menu (%s)" % recorded_id)
	fe._clear_overlays()
	fe.state = FrontEndScript.State.MENU
	fe.main = null
	fe.queue_free()
	rec.queue_free()
	MenuBackgroundScript.snapshot_path = path_was
	Settings.reset_value("interface", "backdrop")
	DirAccess.remove_absolute(file)
	_backdrop_list_folder("", list_was)
	TerrainTextures.forget_surfaces()  # the menu worlds' ground, noted under surface -1 (_terrain's trim checks after)
	if cam_was != null:
		cam_was.make_current()
	await get_tree().process_frame


## The recorded messages to a backdrop recorder: the handshake's prototypes (`protos`), or the rest
## with the clock moved on as they came, then on until it is done.


func _feed_backdrop(rec: Node, source: Array, protos: bool) -> void:
	var last := 0.0
	for m: Dictionary in source:
		var proto: bool = BackdropRecorderScript.PROTO_KINDS.has(str(m.get("t")))
		if proto != protos:
			continue
		if not protos:
			rec.advance(maxf(0.0, float(m.get("dt", 0.0)) - last))
			last = maxf(last, float(m.get("dt", 0.0)))
		rec.on_message(m)
	if not protos:
		for i in 40:
			if not rec.recording():
				break
			rec.advance(0.25)
		rec.wait_written()

## Feeds the mock's updates as _feed_backdrop() does, `extras` once the square's first chunk is in,
## then runs the recording to its end and waits for the write: [the longest advance() in µs, the wait
## for the write after the last one in µs, all on_message() calls in µs, the longest one in µs].


func _backdrop_feed_with(rec: Node, source: Array, extras: Array) -> Array:
	var last := 0.0
	var injected := false
	var longest := 0
	var fed_total := 0
	var fed_worst := 0
	for m: Dictionary in source:
		if BackdropRecorderScript.PROTO_KINDS.has(str(m.get("t"))):
			continue
		var t0 := Time.get_ticks_usec()
		rec.advance(maxf(0.0, float(m.get("dt", 0.0)) - last))
		longest = maxi(longest, Time.get_ticks_usec() - t0)
		last = maxf(last, float(m.get("dt", 0.0)))
		var f0 := Time.get_ticks_usec()
		rec.on_message(m)
		var f1 := Time.get_ticks_usec() - f0
		fed_total += f1
		fed_worst = maxi(fed_worst, f1)
		if not injected and float(rec._started) >= 0.0:
			injected = true
			for x: Dictionary in extras:
				var x0 := Time.get_ticks_usec()
				rec.on_message(x)
				var x1 := Time.get_ticks_usec() - x0
				fed_total += x1
				fed_worst = maxi(fed_worst, x1)
	for i in 40:
		if not rec.recording() or rec.writing():
			break
		var t0 := Time.get_ticks_usec()
		rec.advance(0.25)
		longest = maxi(longest, Time.get_ticks_usec() - t0)
	var t1 := Time.get_ticks_usec()
	rec.wait_written()
	return [longest, Time.get_ticks_usec() - t1, fed_total, fed_worst]


## Feeds the mock's updates and runs the recording till its file is being written (not waited for):
## whether the write is under way.


func _backdrop_feed_to_write(rec: Node, source: Array) -> bool:
	var last := 0.0
	for m: Dictionary in source:
		if BackdropRecorderScript.PROTO_KINDS.has(str(m.get("t"))):
			continue
		rec.advance(maxf(0.0, float(m.get("dt", 0.0)) - last))
		last = maxf(last, float(m.get("dt", 0.0)))
		rec.on_message(m)
	for i in 40:
		if rec.writing() or not rec.recording():
			break
		rec.advance(0.25)
	return rec.writing()


## `bs` messages of `count` straight lanes at (x, y) (1/256 tile), `n` items each, 500 lanes a message.


func _backdrop_lanes(x: int, y: int, count: int, n: int, k: int, base: int) -> Array:
	var out: Array = []
	var uid := base * 100
	for start in range(0, count, 500):
		var lm: Array = []
		var sl: Array = []
		for j in range(start, mini(count, start + 500)):
			var key := (base + j) * 8 + 1
			lm.append_array([key, 1, 256, 8, x + 256, y, x + 128, y, x, y, 0, 0])
			sl.append_array([key, k, n])
			for q in n:
				uid += 1
				sl.append_array([uid, 3, q * 7, 1])
		out.append({"t": "bs", "k": k, "p": 4, "lm": lm, "sl": sl})
	return out


## The JSON text's length in a gzip file (as written: its numbers as ints).


func _raw_len(file: String) -> int:
	var f := FileAccess.open_compressed(file, FileAccess.READ, FileAccess.COMPRESSION_GZIP)
	return f.get_as_text().length() if f != null else -1


## A JSON list with its numbers as ints (nested lists too), for comparing with ints.


func _ints(v: Variant) -> Variant:
	if v is Array:
		return (v as Array).map(func(e: Variant) -> Variant: return _ints(e))
	if v is float:
		return int(v)
	return v


## The backdrop's harder cases (testing pass): another spot and an ortho camera, a file of another
## version, no camera, an empty or chunk-less messages list, an entity its prototypes lack, the 8 MB
## cap, cancel, twice, a game started over, the resync sent again, the 30 s timeout, leaving the game
## while recording, and the setting kept in settings.cfg.


func _menu_backdrop_cases() -> void:
	var cam_was := get_viewport().get_camera_3d()
	# The Esc menu's recordings here all go to one listed file, `file` (--menu-backdrop-save=overwrite, with
	# it in use): the cases below were written for one file, overwritten (the list: _menu_backdrop_list).
	var list_was := _backdrop_list_folder("user://ui-test-backdrops-cases")
	BackdropListScript.overwrite = true
	var cases_id := "ui-test-cases"
	var file := BackdropListScript.path_of(cases_id)
	var path_was: String = MenuBackgroundScript.snapshot_path
	MenuBackgroundScript.snapshot_path = file
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(MOCK_MENU_WORLD))
	var source: Array = parsed["messages"]
	var draw := func() -> Node:
		var b: Node = MenuBackgroundScript.new()
		add_child(b)
		return b
	var drop := func(b: Node) -> void:
		remove_child(b)
		b.queue_free()
	var outcome: Array = []
	var rec: Node = BackdropRecorderScript.new()
	rec.path = file
	add_child(rec)
	rec.set_process(false)
	rec.done.connect(func(p: String) -> void: outcome.append(p))
	rec.failed.connect(func(r: String) -> void: outcome.append("failed: " + r))
	_feed_backdrop(rec, source, true)

	# Another spot (negative chunks) with an ortho camera: the mock's square moved by (-4, 2) chunks.
	var shift := Vector2i(-4, 2)
	var moved := _backdrop_moved(source, shift)
	var spot := Vector2(16 - 128, 16 + 64)
	check(BackdropRecorderScript.chunk_of(spot) == shift and BackdropRecorderScript.chunk_of(Vector2(-0.5, -32.5)) == Vector2i(-1, -2),
		"backdrop cases: chunk_of rounds down for negative tiles")
	var ortho := Camera3D.new()
	add_child(ortho)
	ortho.projection = Camera3D.PROJECTION_ORTHOGONAL
	ortho.size = 40.0
	var view := Transform3D(Basis(Vector3.UP, -2.2) * Basis(Vector3.RIGHT, -1.1), Vector3(spot.x + 10.0, 50.0, spot.y - 20.0))
	ortho.global_transform = view
	var camera: Dictionary = BackdropRecorderScript.camera_dict(ortho)
	ortho.queue_free()
	check(rec.record(spot, camera, {"save": "far-spot", "puppet": 0}), "backdrop cases: a recording at another spot starts")
	check(not rec.record(spot, camera, {}), "backdrop cases: a second record while one runs is refused")
	for m: Dictionary in moved:
		rec.on_message(m)
	for i in 40:
		if not rec.recording():
			break
		rec.advance(0.25)
	rec.wait_written()
	check(outcome == [file], "backdrop cases: the far spot is recorded: %s" % [outcome])
	var snap: Dictionary = BackdropRecorderScript.read(file)
	var chunks: Array = (snap.get("messages", []) as Array).filter(func(m: Dictionary) -> bool: return m.get("t") == "chunk")
	var all_moved: bool = chunks.all(func(m: Dictionary) -> bool: return absi(int(m["cx"]) - shift.x) <= 2 and absi(int(m["cy"]) - shift.y) <= 2)
	check(chunks.size() == 25 and all_moved and (snap.get("camera", {}) as Dictionary).get("proj") == "orthogonal"
		and is_equal_approx(float((snap.get("camera", {}) as Dictionary).get("size", 0.0)), 40.0),
		"backdrop cases: its 25 chunks round (-4, 2) and the ortho camera are in the file (%d chunks)" % chunks.size())
	Settings.set_value("interface", "backdrop", "snapshot")
	var bg: Node = draw.call()
	var near := 0
	for key in bg.world.entities:
		if (bg.world.entities[key].pos as Vector2).distance_to(spot) < 120.0:
			near += 1
	check(bg.source == "snapshot" and bg.camera.projection == Camera3D.PROJECTION_ORTHOGONAL and is_equal_approx(bg.camera.size, 40.0)
		and bg.camera.global_transform.is_equal_approx(view) and bg._center == spot and near > 50 and near == bg.world.entities.size(),
		"backdrop cases: the menu draws the far spot (%d of %d entities round it) from the ortho view" % [near, bg.world.entities.size()])
	# The sway: a quarter period on, the view turned SWAY_DEGREES about the upright through the spot.
	bg._time = (PI / 2.0) / MenuBackgroundScript.SWAY_SPEED
	bg._place_camera()
	var pivot := Vector3(spot.x, 0.0, spot.y)
	var a := Vector2(view.basis.z.x, view.basis.z.z).angle_to(Vector2(bg.camera.transform.basis.z.x, bg.camera.transform.basis.z.z))
	var flat := func(v: Vector3) -> float: return Vector2(v.x - pivot.x, v.z - pivot.z).length()
	check(absf(absf(rad_to_deg(a)) - MenuBackgroundScript.SWAY_DEGREES) < 0.01 and absf(float(flat.call(bg.camera.transform.origin)) - float(flat.call(view.origin))) < 0.001
		and is_equal_approx(bg.camera.transform.origin.y, view.origin.y), "backdrop cases: the sway turns %.2f° about the spot, same height and distance" % rad_to_deg(a))
	drop.call(bg)

	# A file of another version: the built-in world. One with no camera: drawn with the drift.
	var later := snap.duplicate()
	later["v"] = BackdropRecorderScript.VERSION + 1
	BackdropRecorderScript.write(file, later)
	check(BackdropRecorderScript.read(file).is_empty(), "backdrop cases: a file of another version doesn't read")
	bg = draw.call()
	check(bg.source == "default" and bg._view != null and bg.world.entities.size() > 50, "backdrop cases: the built-in world (from its saved view) for a file of another version")
	drop.call(bg)
	var no_cam := snap.duplicate()
	no_cam.erase("camera")
	BackdropRecorderScript.write(file, no_cam)
	bg = draw.call()
	check(bg.source == "snapshot" and bg._view == null and bg.world.entities.size() > 50, "backdrop cases: a snapshot without a camera is drawn with the drift")
	drop.call(bg)
	# An empty messages list, or one without a chunk (hand-edited files): unreadable, the built-in world.
	var only_protos: Array = (snap["messages"] as Array).filter(func(m: Dictionary) -> bool: return m.get("t") != "chunk")
	for messages: Array in [[], only_protos]:
		BackdropRecorderScript.write(file, {"v": 1, "center": [0, 0], "messages": messages})
		check(BackdropRecorderScript.read(file).is_empty(), "backdrop cases: a snapshot of %d messages, no chunk, doesn't read" % messages.size())
		bg = draw.call()
		await get_tree().process_frame
		check(bg.source == "default" and bg.world.entities.size() > 50 and is_instance_valid(bg),
			"backdrop cases: the built-in world for a snapshot of %d messages, no chunk (source %s, %d entities)" % [messages.size(), bg.source, bg.world.entities.size()])
		drop.call(bg)
	# An entity the prototypes lack (a modded save's): a record, drawn as a box, no error.
	var modded := snap.duplicate(true)
	var px := int((spot.x + 3.5) * 256.0)
	var py := int((spot.y + 3.5) * 256.0)
	(modded["messages"] as Array).append({"t": "ents", "cx": shift.x, "cy": shift.y, "part": 1, "parts": 1, "k": 1, "dt": 0.5, "e": [[77777, 9999, px, py, 4]]})
	BackdropRecorderScript.write(file, modded)
	bg = draw.call()
	await get_tree().process_frame
	await get_tree().process_frame
	check(bg.source == "snapshot" and bg.world.entities.has(77777), "backdrop cases: an entity of a prototype the file lacks is kept (drawn as a box)")
	drop.call(bg)

	# The cap: a square over 8 MB of JSON is kept to 3 x 3 chunks.
	outcome.clear()
	check(rec.record(Vector2(16, 16), camera, {}), "backdrop cases: a recording for the cap starts")
	var pad := "x".repeat(BackdropRecorderScript.MAX_BYTES + 1024)
	for m: Dictionary in source:
		if BackdropRecorderScript.PROTO_KINDS.has(str(m.get("t"))):
			continue
		var copy := m
		if m.get("t") == "ents" and int(m["cx"]) == 2 and int(m["cy"]) == 2:
			copy = m.duplicate()
			copy["pad"] = pad
		rec.on_message(copy)
	for i in 40:
		if not rec.recording():
			break
		rec.advance(0.25)
	rec.wait_written()
	snap = BackdropRecorderScript.read(file)
	chunks = (snap.get("messages", []) as Array).filter(func(m: Dictionary) -> bool: return m.get("t") == "chunk")
	var size := FileAccess.open(file, FileAccess.READ).get_length() if FileAccess.file_exists(file) else -1
	var raw := _raw_len(file)
	var in3: bool = chunks.all(func(m: Dictionary) -> bool: return absi(int(m["cx"])) <= 1 and absi(int(m["cy"])) <= 1)
	check(outcome == [file] and chunks.size() == 9 and in3 and raw < BackdropRecorderScript.MAX_BYTES,
		"backdrop cases: over 8 MB the square is kept to 3 x 3 (%d chunks, %d KB raw, %d KB file)" % [chunks.size(), raw / 1024, size / 1024])
	var tiles_ok := true
	for m: Dictionary in snap.get("messages", []):
		if m.get("t") == "tiles":
			var l: Array = m["l"]
			for i in range(0, l.size() - 2, 3):
				var d := BackdropRecorderScript.chunk_of(Vector2(float(l[i]), float(l[i + 1])))
				tiles_ok = tiles_ok and absi(d.x) <= 1 and absi(d.y) <= 1
	check(tiles_ok, "backdrop cases: the capped file's tiles are within 3 x 3 too")
	# (Stability pass) and its live updates: movers and belt lanes within 3 x 3 as well.
	var live_in3 := true
	var lanes_in3 := 0
	for m: Dictionary in snap.get("messages", []):
		if m.get("t") == "mv":
			for r: Array in m["l"]:
				var d := BackdropRecorderScript._chunk_256(int(r[2]), int(r[3]))
				live_in3 = live_in3 and absi(d.x) <= 1 and absi(d.y) <= 1
		elif m.get("t") == "bs" and m.has("lm"):
			var lm3: Array = m["lm"]
			for i in range(0, lm3.size() - 11, 12):
				var d := BackdropRecorderScript._chunk_256(int(lm3[i + 6]), int(lm3[i + 7]))
				live_in3 = live_in3 and absi(d.x) <= 1 and absi(d.y) <= 1
				lanes_in3 += 1
	check(live_in3 and lanes_in3 > 0, "backdrop cases: the capped file's movers and belt lanes are within 3 x 3 too (%d lanes)" % lanes_in3)

	# The live kinds cut to the square as they come (stability pass): the mock's updates with the same
	# kinds 10 chunks off mixed in; only the square's are kept, a lane leading out is marked so, and the
	# menu still runs the belts from the file.
	var k0 := 0
	var unit_in := 0
	for m: Dictionary in source:
		if k0 == 0 and m.get("t") == "bs":
			k0 = int(m.get("k", 0))
		if unit_in == 0 and m.get("t") == "ents" and int(m["cx"]) == 0 and int(m["cy"]) == 0:
			for e: Array in m["e"]:
				if unit_in == 0 and int(e[0]) != 0:
					unit_in = int(e[0])
	var far := 10 * 32 * 256
	var t16 := 16 * 256
	var key_a := 70001 * 8 + 1
	var key_b := 70003 * 8 + 1
	var key_c := 70005 * 8 + 1
	var key_e := 70007 * 8 + 1
	# A: inside; B: 10 chunks off; C: inside, going on into B; E: at the square's east edge (tile 95.5).
	var lm := [key_a, 1, 256, 8, t16 + 256, t16, t16 + 128, t16, t16, t16, 0, 0,
		key_b, 1, 256, 8, far + t16 + 256, t16, far + t16 + 128, t16, far + t16, t16, 0, 0,
		key_c, 1, 256, 8, t16, t16 + 512, t16 - 128, t16 + 512, t16 - 256, t16 + 512, 0, key_b,
		key_e, 1, 256, 8, 96 * 256, t16, 96 * 256 - 128, t16, 95 * 256, t16, 0, 0]
	var extras: Array = [
		{"t": "mv", "k": k0, "z": 1, "l": [[11, 1, t16, t16], [1, 0, far, 0]]},
		{"t": "ih", "k": k0, "z": 1, "l": [21, t16, t16, 3, 1, far, 0, 0]},
		{"t": "gi", "k": k0, "l": [5, t16, t16, 6, t16 + far, t16]},
		{"t": "st", "l": [unit_in, 1, 999999, 1], "lc": [unit_in, 255, 999999, 255]},
		{"t": "bs", "k": k0, "p": 4, "lm": lm, "sl": [key_a, k0, 1, 501, 3, 64, 1, key_b, k0, 1, 502, 3, 64, 1],
			"qu": [501, "rare", 502, "rare"], "pc": [key_a, k0, 1, 64, 64, key_b, k0, 1, 64, 64], "of": [70001, 1, 70003, 1],
			"ew": [key_b, k0, 502, 64], "dl": [key_b]},
	]
	outcome.clear()
	DirAccess.remove_absolute(file)
	check(rec.record(Vector2(16, 16), camera, {}), "backdrop cut: a recording starts")
	_backdrop_feed_with(rec, source, extras)
	snap = BackdropRecorderScript.read(file)
	var by_kind := {}
	for m: Dictionary in snap.get("messages", []):
		var t := str(m.get("t"))
		if not by_kind.has(t):
			by_kind[t] = []
		(by_kind[t] as Array).append(m)
	var has_rec := func(t: String, want: Callable) -> bool:
		return (by_kind.get(t, []) as Array).any(want)
	var mv_ok: bool = has_rec.call("mv", func(m: Dictionary) -> bool: return _ints(m["l"]).has([11, 1, t16, t16])) \
		and not has_rec.call("mv", func(m: Dictionary) -> bool: return m.has("z") or (m["l"] as Array).any(func(r: Array) -> bool: return int(r[2]) >= far))
	var ih_ok: bool = has_rec.call("ih", func(m: Dictionary) -> bool: return _ints(m["l"]) == [21, t16, t16, 3]) \
		and not has_rec.call("ih", func(m: Dictionary) -> bool: return m.has("z") or _ints(m["l"]).has(22))
	var gi_ok: bool = has_rec.call("gi", func(m: Dictionary) -> bool: return _ints(m["l"]) == [5, t16, t16]) \
		and not has_rec.call("gi", func(m: Dictionary) -> bool: return _ints(m["l"]).has(6))
	var st_ok: bool = has_rec.call("st", func(m: Dictionary) -> bool: return _ints(m["l"]) == [unit_in, 1] and _ints(m["lc"]) == [unit_in, 255])
	var mine: Array = (by_kind.get("bs", []) as Array).filter(func(m: Dictionary) -> bool: return m.has("qu"))
	var bs_ok := mine.size() == 1
	if bs_ok:
		var b: Dictionary = mine[0]
		var want_lm: Array = lm.slice(0, 12) + lm.slice(24, 36) + lm.slice(36, 48)
		want_lm[23] = -key_b  # C goes on into B, outside: leads out into it
		want_lm[35] = -1  # E's exit end is at the square's edge
		bs_ok = _ints(b["lm"]) == want_lm and _ints(b["sl"]) == [key_a, k0, 1, 501, 3, 64, 1] and _ints(b["qu"]) == [501, "rare"] \
			and _ints(b["pc"]) == [key_a, k0, 1, 64, 64] and _ints(b["of"]) == [70001, 1] and _ints(b["ew"]) == [] and _ints(b["dl"]) == []
		if not bs_ok:
			print("backdrop cut: bs kept as %s" % [b])
	check(outcome == [file] and mv_ok and ih_ok and gi_ok and st_ok and bs_ok,
		"backdrop cut: only the square's live updates are kept (mv %s, ih %s, gi %s, st %s, bs %s; %s)" % [mv_ok, ih_ok, gi_ok, st_ok, bs_ok, outcome])
	# The menu runs the file's belts: items on them, and the drawn tick moving on.
	bg = draw.call()
	var items := 0
	var tick0 := -1.0
	var tick1 := -1.0
	var t_start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t_start < 4000:
		await get_tree().process_frame
		items = maxi(items, bg._belt_items.count())
		if tick0 < 0.0 and bg._belt_items.drawn_tick() >= 0.0:
			tick0 = bg._belt_items.drawn_tick()
		tick1 = bg._belt_items.drawn_tick()
	check(bg.source == "snapshot" and items > 0 and tick0 >= 0.0 and tick1 > tick0 + 10.0,
		"backdrop cut: the menu runs the cut file's belts (%d items, ticks %.0f -> %.0f)" % [items, tick0, tick1])
	drop.call(bg)

	# A busy base's belt state, 10 chunks off (about 10 MB of JSON as it comes): cut as it comes, the
	# square kept whole at 5 x 5 well under the cap.
	var lanes_far: Array = _backdrop_lanes(far + t16, t16, 13000, 36, k0, 900000)
	var fed := 0
	for m: Dictionary in lanes_far:
		fed += JSON.stringify(m).length()
	outcome.clear()
	check(rec.record(Vector2(16, 16), camera, {}), "backdrop cap: a recording with a far busy belt state starts")
	var far_timing: Array = _backdrop_feed_with(rec, source, lanes_far)
	# (Review item 3) the cut on the main thread as the messages come: all on_message() calls and the worst one.
	print("backdrop cap: on_message over %d KB of far belt state: %.1f ms in all, the worst call %.2f ms" % [fed / 1024, int(far_timing[2]) / 1000.0, int(far_timing[3]) / 1000.0])
	snap = BackdropRecorderScript.read(file)
	chunks = (snap.get("messages", []) as Array).filter(func(m: Dictionary) -> bool: return m.get("t") == "chunk")
	raw = _raw_len(file)
	size = FileAccess.open(file, FileAccess.READ).get_length() if FileAccess.file_exists(file) else -1
	check(fed > BackdropRecorderScript.MAX_BYTES and outcome == [file] and chunks.size() == 25 and raw < 1024 * 1024,
		"backdrop cap: %d KB of far belt state fed, the 5 x 5 file %d KB raw, %d KB gzip (%d chunks)" % [fed / 1024, raw / 1024, size / 1024, chunks.size()])

	# The same inside the 3 x 3: over the cap at 5 x 5 and at 3 x 3, so a still picture (no live
	# updates); made on the worker: no advance() that ended the recording took long, `done` came once.
	var lanes_in: Array = _backdrop_lanes(t16, t16, 13000, 36, k0, 1900000)
	outcome.clear()
	check(rec.record(Vector2(16, 16), camera, {}), "backdrop cap: a recording with a busy belt state in the square starts")
	var timing: Array = _backdrop_feed_with(rec, source, lanes_in)
	for i in 5:
		rec.advance(0.25)
	snap = BackdropRecorderScript.read(file)
	chunks = (snap.get("messages", []) as Array).filter(func(m: Dictionary) -> bool: return m.get("t") == "chunk")
	var live_left := (snap.get("messages", []) as Array).filter(func(m: Dictionary) -> bool: return BackdropRecorderScript.LIVE.has(str(m.get("t"))))
	raw = _raw_len(file)
	check(outcome == [file] and chunks.size() == 9 and live_left.is_empty() and raw < BackdropRecorderScript.MAX_BYTES,
		"backdrop cap: over the cap at 3 x 3 too, a still picture (%d chunks, %d live updates, %d KB raw; %s)" % [chunks.size(), live_left.size(), raw / 1024, outcome])
	check(int(timing[0]) < 50000 and int(timing[1]) > int(timing[0]),
		"backdrop worker: the frame that ended the recording took %.1f ms, the write %.0f ms after it on the worker" % [int(timing[0]) / 1000.0, int(timing[1]) / 1000.0])

	# Cancel halfway: nothing written, no signal; then a new recording works.
	DirAccess.remove_absolute(file)
	outcome.clear()
	rec.record(Vector2(16, 16), camera, {})
	var half := source.size() / 2
	for i in half:
		if not BackdropRecorderScript.PROTO_KINDS.has(str(source[i].get("t"))):
			rec.on_message(source[i])
	rec.advance(3.0)
	rec.cancel()
	for i in range(half, source.size()):
		rec.on_message(source[i])
	for i in 200:
		rec.advance(0.25)
	check(not rec.recording() and outcome.is_empty() and not FileAccess.file_exists(file) and not FileAccess.file_exists(file + ".tmp"),
		"backdrop cases: cancelled halfway, nothing written and nothing said: %s" % [outcome])
	# (Review item 1) cancelled while the file is written: the flag stays on the recorder (the worker's
	# Dictionary has all its keys from the start and isn't touched), no signal, `_job` emptied; the
	# progress reaches 1.0 only once the write is under way.
	var fractions: Array = []
	var on_progress := func(f: float) -> void: fractions.append([f, rec.writing()])
	rec.progress.connect(on_progress)
	rec.record(Vector2(16, 16), camera, {})
	var mid_write: bool = _backdrop_feed_to_write(rec, source)
	var job_keys: Array = (rec._job as Dictionary).keys()
	rec.cancel()
	var flagged: bool = rec._write_cancelled and not (rec._job as Dictionary).has("cancelled")
	rec.wait_written()
	rec.progress.disconnect(on_progress)
	var full_only_writing: bool = not fractions.is_empty() and fractions.back() == [1.0, true] \
		and fractions.all(func(p: Array) -> bool: return float(p[0]) < 1.0 or p[1] == true)
	check(mid_write and flagged and outcome.is_empty() and (rec._job as Dictionary).is_empty() and not rec._write_cancelled and not rec.writing()
		and job_keys.has("raw") and job_keys.has("count") and job_keys.has("ok") and job_keys.has("kept") and full_only_writing,
		"backdrop cases: cancelled during the write: no signal, the job let go, its keys there up front (%s): %s" % [job_keys, outcome])
	rec.record(Vector2(16, 16), camera, {})
	_feed_backdrop(rec, source, false)
	check(outcome == [file], "backdrop cases: and the next recording after it is done as usual: %s" % [outcome])
	DirAccess.remove_absolute(file)
	outcome.clear()
	# Twice in a row: the second replaces the first.
	rec.record(Vector2(16, 16), camera, {"save": "first"})
	_feed_backdrop(rec, source, false)
	rec.record(spot, camera, {"save": "second"})
	for m: Dictionary in moved:
		rec.on_message(m)
	for i in 40:
		if not rec.recording():
			break
		rec.advance(0.25)
	rec.wait_written()
	snap = BackdropRecorderScript.read(file)
	check(outcome == [file, file] and snap.get("save") == "second" and snap.get("center") == [spot.x, spot.y],
		"backdrop cases: recorded twice, the second replaces the first: %s" % [outcome])
	# The game started over (a new handshake) while recording: it fails, says why.
	outcome.clear()
	rec.record(Vector2(16, 16), camera, {})
	Bridge.welcomed.emit({})
	check(not rec.recording() and outcome.size() == 1 and str(outcome[0]).contains("started over"),
		"backdrop cases: a new handshake while recording fails it: %s" % [outcome])
	check(not rec.record(Vector2(16, 16), camera, {}), "backdrop cases: and the next waits for the new prototypes")
	_feed_backdrop(rec, source, true)
	# The bridge ignores a resync within 2 s of the last one: with no chunk of the square by
	# RETRY_AFTER, record()'s resync is sent once more, and the recording then completes.
	var capture_was = Bridge.capture
	Bridge.capture = []
	var resyncs := func() -> int:
		var n := 0
		for text in Bridge.capture:
			var c = JSON.parse_string(text)
			if c is Dictionary and c.get("t") == "resync" and int(c.get("full", -1)) == 0:
				n += 1
		return n
	outcome.clear()
	rec.record(Vector2(16, 16), camera, {})
	var first: int = resyncs.call()
	for i in 9:
		rec.advance(0.25)
	var before: int = resyncs.call()
	rec.advance(0.25)
	var at: int = resyncs.call()
	for i in 4:
		rec.advance(0.25)
	check(first == 1 and before == 1 and at == 2 and resyncs.call() == 2,
		"backdrop cases: the first resync unanswered, a second goes at %.1f s, once (%d, %d, %d, %d)" % [BackdropRecorderScript.RETRY_AFTER, first, before, at, resyncs.call()])
	_feed_backdrop(rec, source, false)
	check(outcome == [file] and resyncs.call() == 2, "backdrop cases: answered after the retry, the recording completes: %s" % [outcome])
	# The 30 s timeout when the chunks never come at all: one retry only, then fails.
	Bridge.capture.clear()
	outcome.clear()
	rec.record(Vector2(16, 16), camera, {})
	for i in 130:
		if not rec.recording():
			break
		rec.advance(0.25)
	check(outcome.size() == 1 and str(outcome[0]).contains("30 s") and resyncs.call() == 2,
		"backdrop cases: no chunks in 30 s: fails after one retry (%d resyncs): %s" % [resyncs.call(), outcome])
	Bridge.capture = capture_was

	# The front end: Cancel in the progress box, then leaving the game while recording.
	var fe: Node = FrontEndScript.new()
	add_child(fe)
	await get_tree().process_frame
	var stand := GDScript.new()
	stand.source_code = "extends Node\nvar hud = null\nvar addons = null\nvar world = null\nvar rig = null\nvar avatar = null\nvar backdrop_recorder = null\nvar input_calls: Array = []\nfunc set_game_input(on: bool) -> void:\n\tinput_calls.append(on)\nfunc end_game() -> void:\n\tbackdrop_recorder.cancel()\n"
	stand.reload()
	var fake_main: Node = stand.new()
	fe.add_child(fake_main)
	fe.main = fake_main
	var rig_script := GDScript.new()
	rig_script.source_code = "extends Node3D\nvar camera := Camera3D.new()\nfunc _ready() -> void:\n\tadd_child(camera)\nfunc focus_point() -> Vector2:\n\treturn Vector2(16, 16)\n"
	rig_script.reload()
	var rig: Node3D = rig_script.new()
	fake_main.add_child(rig)
	remove_child(rec)
	fake_main.add_child(rec)
	fake_main.rig = rig
	fake_main.backdrop_recorder = rec
	Settings.set_value("interface", "backdrop", cases_id)
	DirAccess.remove_absolute(file)
	outcome.clear()
	fe.state = FrontEndScript.State.PLAYING
	fe._toggle_esc_menu()
	(fe._esc_menu.find_child("UseAsBackdrop", true, false) as Button).pressed.emit()
	var cancel: Button = null
	if not fe._progress.is_empty():
		for b: Node in (fe._progress["root"] as Node).find_children("*", "Button", true, false):
			if (b as Button).text.to_lower().contains("cancel"):
				cancel = b
	check(cancel != null and fe._recording_backdrop and fake_main.input_calls.back() == false, "backdrop cases: the progress box has Cancel, game input off: %s" % [fake_main.input_calls])
	if cancel != null:
		cancel.pressed.emit()
	_feed_backdrop(rec, source, false)
	check(not fe._recording_backdrop and not rec.recording() and fe._progress.is_empty() and outcome.is_empty() and not FileAccess.file_exists(file)
		and fake_main.input_calls.back() == true and Settings.get_value("interface", "backdrop") == cases_id,
		"backdrop cases: Cancel stops it, nothing saved, game input back: %s" % [fake_main.input_calls])
	fe._clear_overlays()
	# Once the file is being written Cancel is greyed (it couldn't stop the file being replaced).
	fe._toggle_esc_menu()
	(fe._esc_menu.find_child("UseAsBackdrop", true, false) as Button).pressed.emit()
	var box_cancel: Button = fe._progress.get("cancel") as Button
	var cancel_on_recording: bool = box_cancel != null and not box_cancel.disabled
	var writing_now: bool = _backdrop_feed_to_write(rec, source)
	var cancel_greyed: bool = box_cancel != null and box_cancel.disabled and not fe._progress.is_empty()
	rec.wait_written()
	check(cancel_on_recording and writing_now and cancel_greyed and outcome == [file] and not fe._recording_backdrop,
		"backdrop cases: Cancel works while recording, greyed while the file is written: %s" % [outcome])
	fe._clear_overlays()
	DirAccess.remove_absolute(file)
	Settings.set_value("interface", "backdrop", cases_id)
	outcome.clear()
	# Leaving the game halfway: nothing saved, nothing said after, the main menu shown.
	fe._toggle_esc_menu()
	(fe._esc_menu.find_child("UseAsBackdrop", true, false) as Button).pressed.emit()
	for i in 30:
		if not BackdropRecorderScript.PROTO_KINDS.has(str(source[i].get("t"))):
			rec.on_message(source[i])
	await fe._leave_game(false)
	_feed_backdrop(rec, source, false)
	var said: Array = fe._overlays.map(func(o: Node) -> Array: return _texts(o))
	check(not rec.recording() and not fe._recording_backdrop and outcome.is_empty() and not FileAccess.file_exists(file) and fe.state == FrontEndScript.State.MENU
		and str(said).find("Saved") < 0 and str(said).find("recorded") < 0, "backdrop cases: leaving the game while recording stops it, nothing saved or said: %s" % [said])
	# The owner's freeze (a second recording in one game, a snapshot already there): a file from
	# before (a restart) read by the Menu backdrop window, then two recordings in a row, each done,
	# the second replacing the first; a press while one records does nothing (the button greyed, no
	# second resync); a recording that stops without a word gives the game's input back. (On the old
	# code the button wasn't greyed and the front end waited on, input off: those two fail there.)
	fe._clear_overlays()
	fe.main = fake_main
	fe.state = FrontEndScript.State.PLAYING
	Bridge.capture = []
	BackdropListScript.entries()  # (the earlier recordings' name dropped from the list: their file was deleted above)
	BackdropRecorderScript.write(file, {"v": 1, "center": [0.0, 0.0], "taken": 1, "save": "before",
		"messages": [{"t": "chunk", "cx": 0, "cy": 0, "dt": 0.0}]})
	fe._show_backdrop_window()
	var window_said := str(_texts(fe._overlays.back()))
	fe._clear_overlays()
	var saves: Array = []
	var greyed: Array = []
	for name in ["first", "second"]:
		outcome.clear()
		fe.session_address = name
		fe._toggle_esc_menu()
		(fe._esc_menu.find_child("UseAsBackdrop", true, false) as Button).pressed.emit()
		# Pressed again while it records: greyed, and nothing happens if it fires anyway.
		fe._toggle_esc_menu()
		var again := fe._esc_menu.find_child("UseAsBackdrop", true, false) as Button
		greyed.append(again.disabled)
		again.pressed.emit()
		fe._close_esc_menu()
		_feed_backdrop(rec, source, false)
		saves.append([outcome.duplicate(), str(BackdropRecorderScript.read(file).get("save", "")), fe._recording_backdrop])
	check(window_said.contains("before") and saves == [[[file], "first", false], [[file], "second", false]] and resyncs.call() == 2
		and not FileAccess.file_exists(file + ".tmp") and Settings.get_value("interface", "backdrop") == cases_id and BackdropListScript.entries().map(func(e: Dictionary) -> String: return str(e["id"])) == [cases_id],
		"backdrop cases: a snapshot there before, then two recordings in one game (--menu-backdrop-save=overwrite): both done, the second replaces the first: %s, %d resyncs, listed %s" % [saves, resyncs.call(), BackdropListScript.entries().map(func(e: Dictionary) -> String: return str(e["id"]))])
	check(greyed == [true, true], "backdrop cases: the button is greyed while a recording runs, a press then sends nothing: %s" % [greyed])
	# Stopped without a word (as a script error in its end would): the box goes, the input comes back.
	fe._clear_overlays()
	fe._toggle_esc_menu()
	(fe._esc_menu.find_child("UseAsBackdrop", true, false) as Button).pressed.emit()
	var was_on: bool = fe._recording_backdrop
	rec._recording = false
	await get_tree().process_frame
	await get_tree().process_frame
	check(was_on and not fe._recording_backdrop and fe._progress.is_empty() and fake_main.input_calls.back() == true,
		"backdrop cases: a recording that stops without done or failed gives the game back: %s" % [fake_main.input_calls.slice(-3)])
	# The owner's freeze: a second recording in one game, the first's file there, at the owner's size
	# (about 700 messages): each time the done path runs to its end (Saved shown, the input back).
	fe._clear_overlays()
	var big: Array = []
	for m: Dictionary in source:
		if str(m.get("t")) == "mv" and big.size() < 260:
			var copy: Dictionary = m.duplicate(true)
			var l: Array = []
			for i in 60:
				l.append_array(copy["l"])
			copy["l"] = l
			big.append(copy)
	var big_saves: Array = []
	for name in ["third", "fourth"]:
		fe._clear_overlays()
		fe.session_address = name
		fe._toggle_esc_menu()
		(fe._esc_menu.find_child("UseAsBackdrop", true, false) as Button).pressed.emit()
		_backdrop_feed_with(rec, source, big)
		var snap_big := BackdropRecorderScript.read(file)
		var said_big: Node = fe._overlays.back() if not fe._overlays.is_empty() else null
		big_saves.append([str(snap_big.get("save", "")), (snap_big.get("messages", []) as Array).size(), FileAccess.open(file, FileAccess.READ).get_length() / 1024,
			said_big != null and _texts(said_big).has("Saved. It shows at the main menu."), fe._recording_backdrop, fake_main.input_calls.back()])
	print("backdrop cases: the owner's size twice: %s" % [big_saves])
	check(big_saves.size() == 2 and big_saves.all(func(b: Array) -> bool: return int(b[1]) >= 500 and b[3] == true and b[4] == false and b[5] == true)
		and big_saves[0][0] == "third" and big_saves[1][0] == "fourth",
		"backdrop cases: two recordings of the owner's size in one game, the first's file there: each saved, Saved shown, the input back: %s" % [big_saves])
	check(((load("res://scripts/main.gd") as GDScript).get_script_constant_map().get("MENU_ONLY_SETTINGS", []) as Array).has("backdrop"), "backdrop cases: the game's settings listener leaves interface/backdrop to the menu")
	# The join still loading (the view's square not drawn yet): the button greyed, a press refused.
	fe._clear_overlays()
	var world_script := GDScript.new()
	world_script.source_code = "extends Node\nvar drawn := false\nfunc square_drawn(_r: int) -> bool:\n\treturn drawn\n"
	world_script.reload()
	var stub_world: Node = world_script.new()
	fake_main.add_child(stub_world)
	fake_main.world = stub_world
	fe._played_seconds = 0.0
	Bridge.capture = []
	fe._toggle_esc_menu()
	var loading_button := fe._esc_menu.find_child("UseAsBackdrop", true, false) as Button
	var greyed_loading := loading_button.disabled
	fe._record_backdrop()
	var refused_said: Node = fe._overlays.back() if not fe._overlays.is_empty() else null
	check(greyed_loading and not fe._recording_backdrop and not rec.recording() and Bridge.capture.is_empty() and refused_said != null
		and str(_texts(refused_said)).contains("still loading"), "backdrop cases: while the join loads the button is greyed and a press is refused")
	fe._clear_overlays()
	# (Review item 2) the Esc menu left open: greyed while loading, enabled within a check of the square drawn.
	fe._toggle_esc_menu()
	var open_button := fe._esc_menu.find_child("UseAsBackdrop", true, false) as Button
	fe._process(0.3)
	var still_grey := open_button.disabled
	stub_world.drawn = true
	fe._process(0.3)
	check(still_grey and not open_button.disabled and open_button.tooltip_text == FrontEndScript.BACKDROP_RECORD_TIP and fe._esc_menu != null,
		"backdrop cases: with the Esc menu left open the button is enabled once the square is drawn (%s)" % open_button.tooltip_text)
	fe._close_esc_menu()
	stub_world.drawn = false
	fe._played_seconds = 0.0
	stub_world.drawn = true
	fe._toggle_esc_menu()
	var loaded_button := fe._esc_menu.find_child("UseAsBackdrop", true, false) as Button
	check(not loaded_button.disabled, "backdrop cases: once the view's chunks are drawn it can be recorded")
	fe._close_esc_menu()
	stub_world.drawn = false
	fe._played_seconds = 25.0
	fe._toggle_esc_menu()
	check(not (fe._esc_menu.find_child("UseAsBackdrop", true, false) as Button).disabled, "backdrop cases: and 20 s into the game whatever (a view at the map's edge)")
	fe._close_esc_menu()
	fake_main.world = null
	stub_world.queue_free()
	Bridge.capture = capture_was
	DirAccess.remove_absolute(file)
	fe._show_background(false)
	fe._clear_overlays()
	fe.main = null
	fe.queue_free()

	# The setting kept in settings.cfg (a restart reads it back).
	Settings.set_value("interface", "backdrop", "snapshot")
	var cfg := ConfigFile.new()
	cfg.load(Settings.path)
	var kept = cfg.get_value("interface", "backdrop", "")
	Settings.use_file(Settings.path)
	check(kept == "snapshot" and Settings.get_value("interface", "backdrop") == "snapshot" and MenuBackgroundScript.wants_snapshot(),
		"backdrop cases: the choice is in %s and read back after a restart" % Settings.path.get_file())
	MenuBackgroundScript.force_default = true
	check(not MenuBackgroundScript.wants_snapshot(), "backdrop cases: --menu-backdrop=default overrules it")
	MenuBackgroundScript.force_default = false

	rec.queue_free()
	Settings.reset_value("interface", "backdrop")
	MenuBackgroundScript.snapshot_path = path_was
	DirAccess.remove_absolute(file)
	_backdrop_list_folder("", list_was)
	# The menu worlds drawn here (and in _menu_backdrop) noted their ground under surface -1; a game's
	# handshake forgets it (world.gd clear), so the later sections start as after one (_terrain's trim).
	print("backdrop cases: ground noted on surfaces %s: forgotten" % [TerrainTextures._seen_on.keys()])
	TerrainTextures.forget_surfaces()
	if cam_was != null:
		cam_was.make_current()
	await get_tree().process_frame


## The mock's chunks and entities (no prototypes, no live updates) moved by `d` chunks.


func _backdrop_moved(source: Array, d: Vector2i) -> Array:
	var out: Array = []
	for m: Dictionary in source:
		var t := str(m.get("t"))
		if t != "chunk" and t != "ents":
			continue
		var c: Dictionary = m.duplicate(true)
		c["cx"] = int(c["cx"]) + d.x
		c["cy"] = int(c["cy"]) + d.y
		if t == "ents":
			for e in c.get("e", []):
				e[2] = int(e[2]) + d.x * 32 * 256
				e[3] = int(e[3]) + d.y * 32 * 256
		out.append(c)
	return out


## M5: a save loads with its own mods and those turned on in the Mods window, kept apart from the
## server's mod-list.json (each load's --sync-mods rewrote that file to the save's mods, so the
## window's choices were lost); Load game's Sync mods with save loads exactly the save's. The parts
## after Factorio's --sync-mods, on a list shaped as it writes one; a stand-in for the launcher's
## start (the real server's load paths: the session log's M5 line).


func _menu_backdrop_list() -> void:
	var cam_was := get_viewport().get_camera_3d()
	var list_was := _backdrop_list_folder("user://ui-test-backdrops-list")
	var dir: String = BackdropListScript.dir
	var opened: Array = []
	var stand_in := func(p: String) -> int:
		opened.append(p)
		return OK
	BackdropListScript.shell_open = stand_in
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(MOCK_MENU_WORLD))
	var source: Array = parsed["messages"]

	# The default as shipped (the owner's space platform over Aquilo since 0.3.1, tools/make_menu_backdrop.py):
	# a busy platform with its camera, space and its planet, nothing typed (no save, time, name or stop names),
	# and the two cuts that change nothing drawn: no chunk's decoded `_tiles`, every inserter hands' list
	# delta-coded. (0.2.2's Nauvis factory had over 40 `ents` and 4000 entities; this one 25 and 787.)
	var shipped: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MenuBackgroundScript.DATA))
	var kinds := {}
	var tiles_left := 0
	var plain_ih := 0
	var typed: Array = []
	for m in shipped["messages"]:
		var t := str(m.get("t"))
		kinds[t] = int(kinds.get(t, 0)) + 1
		if m.has("_tiles"):
			tiles_left += 1
		if t == "ih" and int(m.get("z", 0)) != 1:
			plain_ih += 1
		if t == "ents":
			for e in m["e"]:
				if e is Array and e.size() > 5 and e[5] is Dictionary:
					for key in ["n", "label", "tag", "txt"]:
						if (e[5] as Dictionary).has(key):
							typed.append([key, e[5][key]])
	check(not shipped.has("save") and not shipped.has("taken") and not shipped.has("name") and typed.is_empty()
		and BackdropRecorderScript.camera_transform(shipped.get("camera")) != null and int(kinds.get("chunk", 0)) == 25
		and int(kinds.get("ents", 0)) >= 25 and int(kinds.get("bs", 0)) > 50 and int(kinds.get("ih", 0)) > 50 and tiles_left == 0 and plain_ih == 0
		and shipped.get("space") == true and str(shipped.get("planet")) == "aquilo",
		"backdrop list: the shipped default: 25 chunks, its camera, live belts and hands, space over Aquilo, no typed text %s, no _tiles (%d), ih delta-coded (%d plain): %s" % [typed, tiles_left, plain_ih, kinds])
	Settings.set_value("interface", "backdrop", "default")
	var shown_default: Node = MenuBackgroundScript.new()
	add_child(shown_default)
	var arms := 0
	for i in 120:
		await get_tree().process_frame
		arms = shown_default._arms.count()
		if arms > 0 and shown_default._belt_items.count() > 0:
			break
	check(shown_default.source == "default" and shown_default.world.entities.size() >= 700 and arms > 0 and shown_default._belt_items.count() > 0,
		"backdrop list: the shipped default draws %d entities, %d inserter arms (their delta-coded hands read), %d belt items" % [shown_default.world.entities.size(), arms, shown_default._belt_items.count()])
	remove_child(shown_default)
	shown_default.queue_free()

	# Two recordings from the Esc menu, of two games: two entries, newest first.
	var fe: Node = FrontEndScript.new()
	add_child(fe)
	await get_tree().process_frame
	var stand := GDScript.new()
	stand.source_code = "extends Node\nvar hud = null\nvar addons = null\nvar world = null\nvar rig = null\nvar avatar = null\nvar backdrop_recorder = null\nfunc set_game_input(_on: bool) -> void:\n\tpass\n"
	stand.reload()
	var fake_main: Node = stand.new()
	fe.add_child(fake_main)
	fe.main = fake_main
	var rig_script := GDScript.new()
	rig_script.source_code = "extends Node3D\nvar camera := Camera3D.new()\nfunc _ready() -> void:\n\tadd_child(camera)\nfunc focus_point() -> Vector2:\n\treturn Vector2(16, 16)\n"
	rig_script.reload()
	var rig: Node3D = rig_script.new()
	fake_main.add_child(rig)
	var rec: Node = BackdropRecorderScript.new()
	fake_main.add_child(rec)
	rec.set_process(false)
	fake_main.rig = rig
	fake_main.backdrop_recorder = rec
	_feed_backdrop(rec, source, true)
	fe.state = FrontEndScript.State.PLAYING
	var ids: Array = []
	for game in ["Alpha game", "Beta game"]:
		fe._clear_overlays()
		fe.session_address = game
		fe._toggle_esc_menu()
		(fe._esc_menu.find_child("UseAsBackdrop", true, false) as Button).pressed.emit()
		_feed_backdrop(rec, source, false)
		ids.append(str(Settings.get_value("interface", "backdrop")))
	fe._clear_overlays()
	fe.state = FrontEndScript.State.MENU
	var entries: Array = BackdropListScript.entries()
	var names: Array = entries.map(func(e: Dictionary) -> String: return str(e["name"]))
	var files: Array = entries.map(func(e: Dictionary) -> String: return str(e["path"]).get_file())
	check(entries.size() == 2 and ids[0] != ids[1] and str(entries[0]["id"]) == ids[1] and str(entries[1]["id"]) == ids[0]
		and str(names[0]).begins_with("Beta game, ") and str(names[1]).begins_with("Alpha game, ")
		and files.all(func(f: String) -> bool: return f.begins_with("backdrop-") and not f.to_lower().contains("game"))
		and str(BackdropRecorderScript.read(str(entries[0]["path"])).get("name", "")) == names[0],
		"backdrop list: two recordings give two entries, newest first, named from their saves and the time (in the file, not its name): %s %s" % [names, files])

	# The window: Default, then the two; the one in use (the newest) marked.
	fe._show_main_menu()
	fe._show_background(true)
	fe._show_backdrop_window()
	var window: Node = fe._overlays.back()
	var rows: Array = (window.find_child("Buttons", true, false) as Node).get_children()
	var row_names: Array = rows.map(func(r: Node) -> String: return str(r.name))
	var marked: Array = rows.filter(func(r: Node) -> bool: return r.get_meta("in_use", false)).map(func(r: Node) -> String: return str(r.name))
	var use_b := _backdrop_use(window, ids[1])
	var other_b := _backdrop_use(window, ids[0])
	check(row_names == ["Default", ids[1], ids[0]] and marked == [ids[1]] and use_b != null and use_b.disabled and use_b.text == "In use"
		and other_b != null and not other_b.disabled and other_b.text == "Use"
		and window.find_child("OpenFolder", true, false) != null and (window.find_child("Shown", true, false) as Label).text.contains("Beta game, ")
		and fe._background.source == "snapshot",
		"backdrop list: the window lists Default and both, the one in use marked: %s, marked %s" % [row_names, marked])
	# Rename: Enter in the name's box; an empty name keeps the old one.
	var name_box := (window.find_child("Buttons", true, false) as Node).get_node(ids[0]).get_node("Name") as LineEdit
	name_box.text = "  My base  "
	name_box.text_submitted.emit(name_box.text)
	var renamed: String = BackdropListScript.name_of(ids[0])
	name_box.text = ""
	name_box.text_submitted.emit("")
	check(renamed == "My base" and BackdropListScript.name_of(ids[0]) == "My base" and BackdropListScript.rename("nope", "x") == false,
		"backdrop list: a name changed in its box is kept, an empty one isn't: %s" % renamed)
	# Use: the other one shown, marked in the window made again.
	var bg_was: Node = fe._background
	other_b.pressed.emit()
	window = fe._overlays.back()
	check(Settings.get_value("interface", "backdrop") == ids[0] and fe._background != bg_was and fe._background.source == "snapshot"
		and _backdrop_use(window, ids[0]).disabled and not _backdrop_use(window, ids[1]).disabled
		and (window.find_child("Shown", true, false) as Label).text.contains("\"My base\""),
		"backdrop list: Use shows it behind the menu and marks it")
	# Delete asks first: Cancel keeps it; Delete deletes it, and the one in use goes back to Default.
	var del := (window.find_child("Buttons", true, false) as Node).get_node(ids[0]).get_node("Delete") as Button
	del.pressed.emit()
	var ask: Node = fe._overlays.back()
	var asked := " ".join(PackedStringArray(_texts(ask)))
	var cancel_b: Button = null
	var confirm_b: Button = null
	for b: Node in ask.find_children("*", "Button", true, false):
		if (b as Button).text == "Cancel":
			cancel_b = b
		elif (b as Button).text == "Delete":
			confirm_b = b
	check(asked.contains("Delete \"My base\"?") and cancel_b != null and confirm_b != null and confirm_b.theme_type_variation == "FRedButton"
		and FileAccess.file_exists(BackdropListScript.path_of(ids[0])), "backdrop list: Delete asks first (Factorio's red confirm): %s" % asked)
	cancel_b.pressed.emit()
	check(FileAccess.file_exists(BackdropListScript.path_of(ids[0])) and BackdropListScript.entries().size() == 2, "backdrop list: Cancel keeps it")
	window = fe._overlays.back()
	((window.find_child("Buttons", true, false) as Node).get_node(ids[0]).get_node("Delete") as Button).pressed.emit()
	ask = fe._overlays.back()
	for b: Node in ask.find_children("*", "Button", true, false):
		if (b as Button).text == "Delete":
			(b as Button).pressed.emit()
			break
	window = fe._overlays.back()
	rows = (window.find_child("Buttons", true, false) as Node).get_children()
	check(not FileAccess.file_exists(BackdropListScript.path_of(ids[0])) and BackdropListScript.entries().size() == 1
		and Settings.get_value("interface", "backdrop") == "default" and fe._background.source == "default"
		and rows.map(func(r: Node) -> String: return str(r.name)) == ["Default", ids[1]] and (rows[0] as Node).get_meta("in_use", false),
		"backdrop list: Delete deletes the file and its entry; the one in use was it, so Default shows and is marked")
	# Use on the other, then Default.
	_backdrop_use(window, ids[1]).pressed.emit()
	window = fe._overlays.back()
	var after_use := str(Settings.get_value("interface", "backdrop"))
	_backdrop_use(window, "Default").pressed.emit()
	window = fe._overlays.back()
	check(after_use == ids[1] and Settings.get_value("interface", "backdrop") == "default" and fe._background.source == "default"
		and _backdrop_use(window, "Default").disabled and (window.find_child("Shown", true, false) as Label).text.begins_with("Shown now: Zenith's own factory"),
		"backdrop list: Default's Use puts Zenith's own back, marked")
	# A broken file in the list: the menu falls back to Default, which the window marks, and says so.
	var broken := "backdrop-20000101-000000"
	_write(BackdropListScript.path_of(broken), "not a snapshot")
	BackdropListScript.add(broken, "Broken one", 946684800)
	fe._pop_overlay()
	fe._show_backdrop_window()
	window = fe._overlays.back()
	_backdrop_use(window, broken).pressed.emit()
	window = fe._overlays.back()
	check(Settings.get_value("interface", "backdrop") == broken and fe._background.source == "default" and _backdrop_use(window, "Default").disabled
		and not _backdrop_use(window, broken).disabled and (window.find_child("Shown", true, false) as Label).text.contains("\"Broken one\" can't be read"),
		"backdrop list: a broken file falls back to Default (marked), the window says it can't be read")
	# A setting naming a file that isn't there (deleted by hand), or no id at all: Default.
	for v in ["backdrop-19990101-000000", "../escape", "snapshot"]:
		Settings.set_value("interface", "backdrop", v)
		var b: Node = MenuBackgroundScript.new()
		add_child(b)
		check(b.source == "default", "backdrop list: the setting %s with no file: Default" % v)
		remove_child(b)
		b.queue_free()
	# Open folder: the folder handed to the file manager (a stand-in here).
	DirAccess.remove_absolute(BackdropListScript.path_of(broken))
	fe._pop_overlay()
	fe._show_backdrop_window()
	window = fe._overlays.back()
	(window.find_child("OpenFolder", true, false) as Button).pressed.emit()
	check(opened == [ProjectSettings.globalize_path(dir)] and DirAccess.dir_exists_absolute(dir), "backdrop list: Open folder opens %s in the file manager: %s" % [dir, opened])
	fe._clear_overlays()
	fe._show_background(false)

	# The one file from before 0.2.2, in use ("snapshot"): moved into the list once, named from its save.
	var snap := {"v": 1, "center": [0.0, 0.0], "taken": 1700000000, "save": "Old save", "messages": [{"t": "chunk", "cx": 0, "cy": 0, "dt": 0.0}]}
	BackdropRecorderScript.write(BackdropListScript.old_path, snap)
	Settings.set_value("interface", "backdrop", "snapshot")
	var b0: Node = MenuBackgroundScript.new()
	add_child(b0)
	var moved: Array = BackdropListScript.entries()
	var moved_id := str(Settings.get_value("interface", "backdrop"))
	check(b0.source == "snapshot" and not FileAccess.file_exists(BackdropListScript.old_path) and moved.size() == 2 and moved_id == str(moved[1]["id"])
		and str(moved[1]["name"]).begins_with("Old save, 2023-11-1") and BackdropListScript.valid_id(moved_id)
		and str(BackdropRecorderScript.read(str(moved[1]["path"])).get("save", "")) == "Old save",
		"backdrop list: the old file moved into the list, named from its save, in use as it was: %s" % [moved.map(func(e: Dictionary) -> String: return str(e["name"]))])
	remove_child(b0)
	b0.queue_free()
	check(BackdropListScript.migrate() == "" and BackdropListScript.entries().size() == 2, "backdrop list: moved once only")
	# One without a save, not in use: "Saved backdrop", the setting left as it was; a copy that couldn't
	# remove the old file (held open) isn't made again.
	BackdropRecorderScript.write(BackdropListScript.old_path, {"v": 1, "center": [0.0, 0.0], "messages": []})
	Settings.set_value("interface", "backdrop", "default")
	var second := BackdropListScript.migrate()
	check(second != "" and BackdropListScript.name_of(second) == "Saved backdrop" and Settings.get_value("interface", "backdrop") == "default"
		and BackdropListScript.entries().size() == 3, "backdrop list: an old file without a save is named \"Saved backdrop\"; not in use, it isn't put in use")
	BackdropRecorderScript.write(BackdropListScript.old_path, {"v": 1, "center": [0.0, 0.0], "messages": []})
	var cfg := ConfigFile.new()
	cfg.load(dir.path_join(BackdropListScript.INDEX))
	cfg.set_value(BackdropListScript.MIGRATED, "stamp", BackdropListScript._stamp(BackdropListScript.old_path))
	cfg.save(dir.path_join(BackdropListScript.INDEX))
	check(BackdropListScript.migrate() == "" and BackdropListScript.entries().size() == 3, "backdrop list: an old file already copied (its time noted) isn't copied again")
	DirAccess.remove_absolute(BackdropListScript.old_path)
	# A file dropped into the folder by hand: listed, named from inside it.
	BackdropRecorderScript.write(dir.path_join("backdrop-friend.json.gz"), {"v": 1, "center": [0.0, 0.0], "name": "A friend's base", "taken": 1600000000, "messages": [{"t": "chunk", "cx": 0, "cy": 0, "dt": 0.0}]})
	check(BackdropListScript.name_of("backdrop-friend") == "A friend's base" and BackdropListScript.entries().size() == 4, "backdrop list: a file dropped into the folder is listed by the name inside it")

	fe.main = null
	fe.queue_free()
	Settings.reset_value("interface", "backdrop")
	_backdrop_list_folder("", list_was)
	TerrainTextures.forget_surfaces()
	if cam_was != null:
		cam_was.make_current()
	await get_tree().process_frame


## The backdrop list (backdrop_list.gd) in a folder of the test's own, emptied: its old file's place
## beside it, overwrite off. With "" and what it returned: that folder emptied and all put back.


func _backdrop_list_folder(dir: String, was := []) -> Array:
	if dir == "":
		_backdrop_empty_folder(BackdropListScript.dir)
		DirAccess.remove_absolute(BackdropListScript.old_path)
		BackdropListScript.dir = was[0]
		BackdropListScript.old_path = was[1]
		BackdropListScript.overwrite = was[2]
		BackdropListScript.shell_open = was[3]
		return []
	var out := [BackdropListScript.dir, BackdropListScript.old_path, BackdropListScript.overwrite, BackdropListScript.shell_open]
	BackdropListScript.dir = dir
	BackdropListScript.old_path = dir + "-old.json.gz"
	BackdropListScript.overwrite = false
	_backdrop_empty_folder(dir)
	DirAccess.remove_absolute(BackdropListScript.old_path)
	DirAccess.make_dir_recursive_absolute(dir)
	return out


func _backdrop_empty_folder(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)


## A row's Use button in the Menu backdrop window ("Default", or a backdrop's id).


func _backdrop_use(window: Node, row: String) -> Button:
	var list: Node = window.find_child("Buttons", true, false) if window != null else null
	var r: Node = list.get_node_or_null(row) if list != null else null
	return r.get_node_or_null("Use") as Button if r != null else null


## After the menu drew a snapshot backdrop, a new game's ground has its textures: the game's tile ids
## differ from the snapshot's (the owner's "never loaded any ground texture", every tile flat).


func _menu_backdrop_ground() -> void:
	var cam_was := get_viewport().get_camera_3d()
	var file := "user://ui-test-backdrop-ground.json.gz"
	var path_was: String = MenuBackgroundScript.snapshot_path
	MenuBackgroundScript.snapshot_path = file
	var parsed: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MOCK_MENU_WORLD))
	var source: Array = parsed["messages"]
	parsed["v"] = 1
	parsed["camera"] = {"xf": [1, 0, 0, 0, 0.7, 0.7, 0, -0.7, 0.7, 16.0, 30.0, 40.0], "fov": 40.0, "proj": "perspective", "size": 10.0}
	check(BackdropRecorderScript.write(file, parsed), "backdrop ground: a snapshot file to draw")
	Settings.hold("interface", {"backdrop": "snapshot"})
	var menu: Node = MenuBackgroundScript.new()
	add_child(menu)
	for i in 120:
		await get_tree().process_frame
		if menu.world.terrain_queue_size() == 0 and TerrainTextures._pending.is_empty() and TerrainTextures._upload.is_empty() and i > 10:
			break
	check(str(menu.source) == "snapshot", "backdrop ground: the menu draws the snapshot")
	var menu_layers := TerrainTextures.layer_count()
	# The game starts (front_end _enter_game): the menu's background goes.
	remove_child(menu)
	menu.queue_free()
	Settings.release("interface")
	# Game 2: the same ground under other prototype ids (its tprotos in reverse order).
	var tiles: Array = []
	for m: Dictionary in source:
		if m["t"] == "tprotos":
			tiles = m["l"]
	var n := tiles.size()
	var remap := {}
	var game_tiles: Array = []
	for row: Array in tiles:
		var new_id := n + 1 - int(row[0])
		remap[int(row[0])] = new_id
		var r := row.duplicate()
		r[0] = new_id
		game_tiles.append(r)
	var world: Node = WorldMirror.new()
	world.name = "GameWorld"
	world.view_radius = 2
	add_child(world)
	world.reset()
	world.set_focus(Vector2(16, 16))
	world._update_subscription(0.0)
	var used := {}
	for m: Dictionary in source:
		var t := str(m["t"])
		if t in ["mv", "bs", "ih", "gi"]:
			continue
		var msg := m.duplicate(true)
		if t == "tprotos":
			msg["l"] = game_tiles
		elif t == "chunk":
			var ids: Array = msg.get("tiles", [])
			for i in range(0, ids.size(), 2):  # (id, count) pairs
				ids[i] = int(remap.get(int(ids[i]), int(ids[i])))
				if remap.has(n + 1 - int(ids[i])):
					used[int(ids[i])] = true
		world.handle(msg)
	for i in 300:
		await get_tree().process_frame
		world._rebuild_dirty()  # (world.gd builds by itself only once Bridge.world_ready)
		if world.terrain_queue_size() == 0 and TerrainTextures._pending.is_empty() and TerrainTextures._upload.is_empty() and world._waiting_gfx.is_empty() and i > 10:
			break
	var flat: Array = []
	var textured := ItemIcons.find_data_dir() != "" and not TerrainTextures.disabled
	for id: int in used:
		var name: String = world.protos.tile_names[id]
		var g = TerrainTextures.peek(name)
		if textured and not world.protos.is_void(id) and (g == null or g.layer < 0) and TerrainTextures.lookup(name) == null:
			flat.append(name)
	print("backdrop ground: the menu's %d layers, the game's %d; data %s; waiting %s; generation %d" % [menu_layers,
		TerrainTextures.layer_count(), textured, world._waiting_gfx.keys(), TerrainTextures.generation])
	check(world._waiting_gfx.is_empty(), "backdrop ground: no chunk of the game left waiting for a picture: %s" % [world._waiting_gfx])
	check(flat.is_empty(), "backdrop ground: every kind of the game's ground has its picture: %s" % [flat])
	if textured:
		check(TerrainTextures.active() and Visuals.terrain_material().get_shader_parameter("textured") == true
			and Visuals.terrain_material().get_shader_parameter("tiles") != null, "backdrop ground: the terrain material has the tile layers")
		var gfx_ok := true
		for id: int in used:
			if not world.protos.is_void(id):
				var g = world._gfx_table[id] if id < world._gfx_table.size() else null
				gfx_ok = gfx_ok and g != null and g.name == world.protos.tile_names[id]
		check(gfx_ok, "backdrop ground: the game's tile ids point at their own pictures, not the snapshot's")
	else:
		print("skip backdrop ground's pictures: no Factorio install (or terrain textures off)")
	remove_child(world)
	world.queue_free()
	await get_tree().process_frame
	TerrainTextures.forget_surfaces()  # (as the next game's handshake does: _terrain's trim reads them)
	MenuBackgroundScript.snapshot_path = path_was
	DirAccess.remove_absolute(file)
	if cam_was != null:
		cam_was.make_current()


## The debug menu's Lighting tab: moving a slider changes Looks' global, Reset puts the default back, a public build
## changes nothing, Copy values gives the numbers.
