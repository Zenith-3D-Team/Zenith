extends "res://tests/addon_test_base.gd"
## Add-on test sections: shaders.

func _screenshot_mode(api, host, fake, hud_layer: CanvasLayer) -> void:
	# Held chunks: a chunk the view left stays while held (one that never arrived doesn't), and goes
	# when let go.
	var before_world = fake.world
	var w := WorldMirror.new()
	add_child(w)
	w.view_radius = 1
	w.hold_min_free = 0  # the PC's free memory doesn't decide the check
	fake.world = w
	w.set_focus(Vector2(16, 16))
	w._update_subscription(1.0)
	var kept := Vector2i(-1, -1)
	var came := w.chunks.has(kept) and w.chunks.has(Vector2i(1, 1))
	if came:
		(w.chunks[kept] as ChunkView).loaded = true
	api.world.hold_chunks(true)
	check(api.world.holding_chunks() and w.hold, "hold_chunks: the world holds its chunks")
	w.set_focus(Vector2(16 + 32 * 10, 16))
	w._update_subscription(1.0)
	check(came and w.chunks.has(kept) and not w.chunks.has(Vector2i(1, 1)) and api.world.held_chunks() == 1,
		"a chunk the camera left is kept while held, one that never arrived isn't: %d held" % api.world.held_chunks())
	check(w.chunks.has(Vector2i(10, 0)), "and the chunks round the new focus still come")
	api.world.hold_chunks(false)
	w._update_subscription(1.0)
	check(not w.chunks.has(kept) and api.world.held_chunks() == 0 and not w.hold, "let go: the held chunk is unloaded")
	_shot_settle(w)
	fake.world = before_world
	w.queue_free()

	# Full detail: the settings held at their tops without touching the file, lamps all lit, the
	# player's own back after.
	var lamps := LampLights.new()
	add_child(lamps)
	fake.lamps = lamps
	var glow := WorkingGlow.new()
	fake.working_glow = glow
	var radius_before: int = int(Settings.get_value("graphics", "view_radius"))
	var stored_before := Settings.has_value("graphics", "view_radius")
	var lod_before := str(Settings.get_value("graphics", "lod_quality"))
	var heard := []
	var listener := func(section: String, _key: String) -> void: heard.append(section)
	Settings.listen(listener)
	api.view.full_detail(true)
	check(api.view.full_detail_on() and int(Settings.get_value("graphics", "view_radius")) == 20
		and str(Settings.get_value("graphics", "lod_quality")) == "high" and int(Settings.get_value("graphics", "entity_radius")) == 256
		and int(Settings.get_value("graphics", "belt_distance")) == 640 and int(Settings.get_value("graphics", "decorative_distance")) == 320
		and str(Settings.get_value("graphics", "grass_3d")) == "far" and not bool(Settings.get_value("graphics", "merge_far")),
		"full_detail: every distance at its top (view, entity, belts, decoratives, grass), far chunks whole")
	check(ItemCards.model_cap < 0 and ModelLods.full_detail and not BeltLods.enabled and UpsGovernor.lifted,
		"Items in 3D uncapped, models at full level, no belt stand-ins, nothing held back for the UPS")
	check(lamps.max_lights == LampLights.FULL_LIGHTS and lamps._lights.size() >= LampLights.FULL_LIGHTS and glow.radius == WorkingGlow.FULL_RADIUS,
		"every lamp gets its light (%d), fires and glows far out" % lamps.max_lights)
	check(Settings.has_value("graphics", "view_radius") == stored_before and heard.size() == 1,
		"nothing written to the settings file, the listeners told once (%d)" % heard.size())
	api.view.full_detail(false)
	Settings.unlisten(listener)
	check(not api.view.full_detail_on() and int(Settings.get_value("graphics", "view_radius")) == radius_before
		and str(Settings.get_value("graphics", "lod_quality")) == lod_before and not ModelLods.full_detail and BeltLods.enabled
		and not UpsGovernor.lifted and lamps.max_lights == LampLights.MAX_LIGHTS and glow.radius == WorkingGlow.RADIUS,
		"and off: the player's own settings, levels, lamps and caps back")

	# A screenshot: the interface (and an add-on's overlay) hidden while it is taken, full detail on,
	# a file written on a worker thread, everything back.
	var sizes: Array = []
	host.test_capture = func(size: Vector2i) -> Image:
		sizes.append(size)
		return Image.create(8, 8, false, Image.FORMAT_RGB8)
	var saved := []
	api.view.screenshot_saved.connect(func(p: String, ok: bool) -> void: saved.append([p, ok]))
	var overlay: CanvasLayer = api.ui.layer()
	var folder := "user://addon-test/shots"
	var path: String = api.view.screenshot(null, {"folder": folder, "timeout": 3.0})
	check(path == folder.path_join("zenith-1.png") and api.view.screenshot_busy() and api.view.screenshot(null) == "",
		"screenshot: the next zenith-<n>.png in the folder, one at a time (%s)" % path)
	await get_tree().process_frame
	check(not hud_layer.visible and host.interface_hidden() and not overlay.visible and api.view.full_detail_on(),
		"while it is taken: the HUD and the add-on's overlay hidden, full detail on")
	check(MomentHold.on, "and the moment held: Zenith's view of time stands still")
	var t0 := Time.get_ticks_msec()
	while (api.view.screenshot_busy() or saved.is_empty()) and Time.get_ticks_msec() - t0 < 8000:
		await get_tree().process_frame
	check(not saved.is_empty() and saved[0][0] == path and bool(saved[0][1]) and FileAccess.file_exists(path),
		"the PNG is written and screenshot_saved says so: %s" % [saved])
	check(hud_layer.visible and overlay.visible and not host.interface_hidden() and not api.view.full_detail_on()
		and int(Settings.get_value("graphics", "view_radius")) == radius_before,
		"then the interface, the overlay and the player's settings are back")
	check(not MomentHold.on, "and time runs again")
	check(host._toast != null and host._toast.visible, "and \"Screenshot saved\" shows, with Open folder")
	check(AddonHost.screenshot_path(null, {"folder": folder}) == folder.path_join("zenith-2.png")
		and AddonHost.screenshot_path("user://x/y.png", {}) == "user://x/y.png", "the next one is zenith-2.png; a .png path is used as it is")
	check(sizes.size() == 1 and sizes[0] == host._window_size(), "without size or scale, the window's size (%s)" % [sizes])
	# An 8K one: the size option reaches the capture as it is.
	saved.clear()
	path = api.view.screenshot(null, {"folder": folder, "timeout": 3.0, "size": Vector2i(7680, 4320)})
	t0 = Time.get_ticks_msec()
	while (api.view.screenshot_busy() or saved.is_empty()) and Time.get_ticks_msec() - t0 < 8000:
		await get_tree().process_frame
	check(sizes.size() == 2 and sizes[1] == Vector2i(7680, 4320) and not saved.is_empty() and bool(saved[0][1]),
		"size: Vector2i(7680, 4320) is drawn at 8K (%s)" % [sizes])
	check(FullDetail.shot_aspect == 0.0 and not FrameBudget.boost, "after it the view's shape and the frame budget are back")
	check(host._progress != null and not host._progress.visible, "and its progress bar is gone")
	# Cancelled: nothing written, everything back.
	var cancelled := []
	api.view.screenshot_cancelled.connect(func(p: String) -> void: cancelled.append(p))
	saved.clear()
	path = api.view.screenshot(null, {"folder": folder, "timeout": 3.0})
	await get_tree().process_frame
	check(host._progress != null and host._progress.visible and not host._shot_layers.has(host._progress),
		"while it is taken its progress shows, on a layer the shot doesn't hide")
	check(api.view.screenshot_cancel(), "screenshot_cancel: one is being taken")
	t0 = Time.get_ticks_msec()
	while api.view.screenshot_busy() and Time.get_ticks_msec() - t0 < 8000:
		await get_tree().process_frame
	check(cancelled == [path] and saved.is_empty() and not FileAccess.file_exists(path) and sizes.size() == 2,
		"cancelled: screenshot_cancelled, no picture taken, no file (%s, %s)" % [cancelled, saved])
	check(hud_layer.visible and not host.interface_hidden() and not api.view.full_detail_on() and not host._progress.visible
		and not api.view.screenshot_cancel(), "and the interface, full detail and the progress are back as they were")
	await _shot_note_waits(api, host, folder)
	_shot_sizes()
	host.test_capture = Callable()
	fake.lamps = null
	fake.working_glow = null
	lamps.queue_free()
	glow.free()


## L15: a screenshot taken with the interface hidden (F11 is the Cinematic camera's api.view.hide_interface)
## keeps its "Screenshot saved" note until the interface comes back, then shows it for its 5 s with the newest
## shot's path; a note hidden by the interface waits again; --shot-note=old (shot_note_waits off) as before.


func _shot_note_waits(api, host, folder: String) -> void:
	var saved := []
	var heard := func(p: String, ok: bool) -> void: saved.append([p, ok])
	api.view.screenshot_saved.connect(heard)
	api.view.hide_interface(true)
	for i in 2:
		saved.clear()
		var path: String = api.view.screenshot(null, {"folder": folder, "timeout": 3.0})
		var t0 := Time.get_ticks_msec()
		while (api.view.screenshot_busy() or saved.is_empty()) and Time.get_ticks_msec() - t0 < 8000:
			await get_tree().process_frame
		check(not saved.is_empty() and bool(saved[0][1]) and host.interface_hidden() and host._toast != null
			and not host._toast.visible and host._toast_waiting and str(host._toast.get_meta("path", "")) == path,
			"L15: a shot taken with the interface hidden keeps its note waiting, not shown (%s)" % path)
	var newest := str(host._toast.get_meta("path", ""))
	host._toast_left = 0.0
	api.view.hide_interface(false)
	check(not host.interface_hidden() and host._toast.visible and not host._toast_waiting and host._toast_left == 5.0
		and newest.ends_with(".png") and str(host._toast.get_meta("path", "")) == newest,
		"and shows when the interface comes back, for its 5 s, the newest shot's (%s)" % newest)
	api.view.hide_interface(true)
	check(not host._toast.visible and host._toast_waiting, "a note on screen when the interface hides waits again")
	api.view.hide_interface(false)
	check(host._toast.visible and host._toast_left == 5.0, "and comes back with it")
	host._show_toast(false)
	host.shot_note_waits = false
	api.view.hide_interface(true)
	saved.clear()
	api.view.screenshot(null, {"folder": folder, "timeout": 3.0})
	var t1 := Time.get_ticks_msec()
	while (api.view.screenshot_busy() or saved.is_empty()) and Time.get_ticks_msec() - t1 < 8000:
		await get_tree().process_frame
	api.view.hide_interface(false)
	check(not saved.is_empty() and not host._toast.visible and not host._toast_waiting,
		"--shot-note=old: not shown, then or when the interface comes back")
	host.shot_note_waits = true
	api.view.screenshot_saved.disconnect(heard)


## The screenshot's size (API 1.6 `size`, `scale`), the MSAA it is drawn with at 8K, and its camera
## framing the window's height at another shape.


func _shot_sizes() -> void:
	var win := Vector2i(1600, 900)
	check(AddonHost.shot_size({"size": Vector2i(7680, 4320)}, win) == Vector2i(7680, 4320)
		and AddonHost.shot_size({"size": [3840, 2160]}, win) == Vector2i(3840, 2160)
		and AddonHost.shot_size({}, win) == win and AddonHost.shot_size({"scale": 2}, win) == Vector2i(3200, 1800)
		and AddonHost.shot_size({"size": Vector2i(0, 0), "scale": 4}, win) == Vector2i(6400, 3600),
		"shot_size: `size` as given (a Vector2i or [w, h]), else the window times `scale`")
	check(AddonHost.shot_size({"size": Vector2i(20000, 10000)}, win) == Vector2i(16384, 8192)
		and AddonHost.shot_size({"scale": 4}, Vector2i(5120, 2880)) == Vector2i(16384, 9216),
		"and never past Godot's 16384 a side, the shape kept")
	check(AddonHost.shot_msaa(Viewport.MSAA_4X, Vector2i(7680, 4320)) == Viewport.MSAA_2X
		and AddonHost.shot_msaa(Viewport.MSAA_8X, Vector2i(7680, 4320)) == Viewport.MSAA_2X
		and AddonHost.shot_msaa(Viewport.MSAA_4X, Vector2i(3840, 2160)) == Viewport.MSAA_4X
		and AddonHost.shot_msaa(Viewport.MSAA_DISABLED, Vector2i(7680, 4320)) == Viewport.MSAA_DISABLED,
		"8K steps 4x and 8x MSAA down to 2x (video memory); 4K keeps 4x")
	var cam := Camera3D.new()
	cam.fov = 60.0
	cam.size = 20.0
	check(FullDetail.vertical_frame(cam, Vector2(1600, 900)) == Vector2(60.0, 20.0), "a camera keeping its height is framed as it is")
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	var f := FullDetail.vertical_frame(cam, Vector2(1600, 900))
	var want := rad_to_deg(2.0 * atan(tan(deg_to_rad(30.0)) * 900.0 / 1600.0))
	check(absf(f.x - want) < 0.001 and absf(f.y - 20.0 * 900.0 / 1600.0) < 0.001,
		"one keeping its width: the window's vertical field of view and height (%s)" % f)
	cam.free()


## The screenshot's settle (full_detail.gd pending): chunks count only in the camera's view, and one
## that hasn't arrived stops counting once the bridge has sent nothing new for a while.


func _shot_settle(w) -> void:
	w.set_focus(Vector2(16, 16))
	w._update_subscription(1.0)
	var all := func(_c: Vector2i) -> bool: return true
	var one := func(c: Vector2i) -> bool: return c == Vector2i(0, 0)
	var wanted: int = w._wanted.size()
	check(wanted == 9 and w.unsettled_in(all, false) == 9 and w.unsettled_in(all, true) == 0,
		"unsettled_in: 9 wanted chunks on their way count, none once the bridge has given up (%d, %d)" % [wanted, w.unsettled_in(all, false)])
	check(w.unsettled_in(one, false) == 1, "only those in the view count")
	var before: int = w.last_arrival_msec
	w.handle({"t": "chunk", "cx": 0, "cy": 0, "none": true})
	check(w.unsettled_in(one, false) == 1 and w.last_arrival_msec >= before and w.last_arrival_msec > 0,
		"a chunk that came is noted as an arrival, and counts until it is drawn")
	check(not FullDetail.given_up(w), "the bridge has just sent one: not given up")
	w.last_arrival_msec = Time.get_ticks_msec() - FullDetail.QUIET_MSEC - 1
	FullDetail._since = w.last_arrival_msec  # full detail came on before that too
	check(FullDetail.given_up(w), "nothing new for %d ms: given up" % FullDetail.QUIET_MSEC)
	var report_before: Dictionary = Bridge.work_budget
	var report_at: int = Bridge.work_budget_msec
	Bridge.work_budget = {"q": {"chunks": 5}}
	Bridge.work_budget_msec = Time.get_ticks_msec()
	check(not FullDetail.given_up(w), "but not while the bridge's last report has chunks queued (it reads one a tick)")
	Bridge.work_budget_msec = Time.get_ticks_msec() - FullDetail.REPORT_MSEC - 1
	check(FullDetail.given_up(w), "a report that old isn't read")
	Bridge.work_budget = report_before
	Bridge.work_budget_msec = report_at
	# A screenshot's cover: the chunks its camera sees asked for besides the view's own square, in
	# one square fitted round both.
	var subs_before: int = Bridge.square_subs
	Bridge.square_subs = WorldMirror.MAX_VIEW_RADIUS
	w._update_subscription(1.0)
	var own_wanted: int = w._wanted.size()
	var east := func(c: Vector2i) -> bool: return c.x >= 5
	w.set_cover(Rect2i(Vector2i(5, -2), Vector2i(3, 5)), Vector2i(0, 0), east)
	w._update_subscription(1.0)
	var seen_in := 0
	for c: Vector2i in w._wanted:
		if c.x >= 5:
			seen_in += 1
	check(own_wanted == 9 and w._sq_center == Vector2i(3, 0) and w._sq_radius == 4 and w._wanted.size() == 9 + 27 and seen_in == 27,
		"cover: the square fitted round the view's and the camera's (%s r %d), its seen chunks asked for besides the view's 9 (%d)" % [w._sq_center, w._sq_radius, w._wanted.size()])
	w.clear_cover()
	w._update_subscription(1.0)
	check(w._wanted.size() == 9 and w._sq_center == Vector2i(0, 0) and w._sq_radius == 1, "and after it the view's own square again")
	Bridge.square_subs = subs_before
	var fit: Array = WorldMirror.fit_square(Rect2i(0, 0, 300, 5), Vector2i(290, 2), 50)
	check(fit[0] == Vector2i(249, 2) and fit[1] == 50, "a view wider than the bridge's square: its part nearest the camera (%s)" % [fit])
	var down := Camera3D.new()
	add_child(down)
	down.fov = 90.0
	down.position = Vector3(0, 100, 0)
	down.rotation_degrees = Vector3(-90, 0, 0)
	var foot := FullDetail.ground_footprint(down, Vector2(900, 900), 1.0, 3000.0)
	check(foot.position.distance_to(Vector2(-100, -100)) < 0.5 and foot.size.distance_to(Vector2(200, 200)) < 1.0,
		"ground_footprint: straight down, the square under the camera (%s)" % foot)
	down.rotation_degrees = Vector3(0, 0, 0)
	foot = FullDetail.ground_footprint(down, Vector2(900, 900), 1.0, 3000.0)
	check(foot.position.y < -2100.0 and foot.end.y <= 0.5 and absf(foot.position.x + 2121.3) < 1.0, "looking at the horizon: out to the reach along the top corners (%s)" % foot)
	down.free()
	# A screenshot's moment: the drawn clock stands still however much comes, and runs on after it.
	var clock = preload("res://scripts/world/game_clock.gd").new()
	clock.heard(100.0)
	clock.advance(0.1)
	MomentHold.begin()
	var at_hold: float = clock.advance(0.0)
	clock.advance(0.5)
	clock.heard(400.0)
	var held_at: float = clock.advance(0.5)
	var kinds_held: bool = Bridge._holding and Bridge._hold_kinds.has("mv")
	MomentHold.end()
	var after: float = clock.advance(0.1)
	check(at_hold == held_at and kinds_held and after > held_at and not Bridge._holding,
		"the moment: the clock held at %.1f through a jump to tick 400, movers' updates waiting; after it on to %.1f" % [held_at, after])
	var shots := AddonHost.default_screenshot_folder()
	check(shots == "user://screenshots" if OS.get_system_dir(OS.SYSTEM_DIR_PICTURES) == "" else (shots.get_file() == "Zenith" and not shots.begins_with("user://")),
		"screenshots go to the Pictures folder's Zenith (%s)" % shots)
	# The view: a camera at the origin looking north (-Z).
	var cam := Camera3D.new()
	add_child(cam)
	cam.fov = 70.0
	cam.far = 500.0
	var planes := FullDetail.view_planes(cam, Vector2(1600, 900), 16.0 / 9.0, 0.0)
	check(FullDetail.box_in_view(planes, Vector3(-5, -5, -105), Vector3(5, 5, -95))
		and not FullDetail.box_in_view(planes, Vector3(-5, -5, 95), Vector3(5, 5, 105))
		and not FullDetail.box_in_view(planes, Vector3(300, -5, -105), Vector3(310, 5, -95))
		and not FullDetail.box_in_view(planes, Vector3(-5, -5, -700), Vector3(5, 5, -690)),
		"view_planes: a box ahead is in view; behind, far to the side or past the far plane isn't")
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 20.0
	planes = FullDetail.view_planes(cam, Vector2(1600, 900), 16.0 / 9.0, 0.0)
	check(FullDetail.box_in_view(planes, Vector3(14, -1, -50), Vector3(16, 1, -48))
		and not FullDetail.box_in_view(planes, Vector3(20, -1, -50), Vector3(22, 1, -48))
		and FullDetail.box_in_view(FullDetail.view_planes(cam, Vector2(1600, 900), 16.0 / 9.0, 8.0), Vector3(20, -1, -50), Vector3(22, 1, -48)),
		"orthographic: within half its width (17.8 tiles) in view, past it not, but within the margin")
	planes = FullDetail.view_planes(cam, Vector2(1600, 900), 1.0, 0.0)
	check(not FullDetail.box_in_view(planes, Vector3(14, -1, -50), Vector3(16, 1, -48)), "a square shot is narrower")
	# Held chunks: never more than 1,600, nor past 3,281 loaded with the view's own.
	var wanted_before: Array = w._wanted
	w._wanted = []
	w._wanted.resize(441)
	var at_10: int = w._hold_limit()
	w._wanted.resize(3000)
	var at_27: int = w._hold_limit()
	w._wanted.resize(3721)
	var at_30: int = w._hold_limit()
	w._wanted = wanted_before
	check(at_10 == 1600 and at_27 == 281 and at_30 == 0,
		"hold_chunks' cap: 1,600 at view 10, fewer as the view grows, none at 30 (%d, %d, %d)" % [at_10, at_27, at_30])
	remove_child(cam)
	cam.free()


## The Cinematic shaders add-on (addons-src/): the add-on is the look, on while it is on, with TAA
## while its look is in use; switched off, the Factorio look and the player's own TAA come back.


func _cinematic_shaders(fake) -> void:
	var src := ProjectSettings.globalize_path("res://").path_join("../addons-src/cinematic-shaders").simplify_path()
	if not DirAccess.dir_exists_absolute(src):
		check(false, "cinematic shaders: the add-on's folder is at " + src)
		return
	var look_before = Settings.get_value("graphics", "look")
	var vp := get_viewport()
	vp.use_taa = false
	Settings.set_value("graphics", "look", "classic")
	var look_env := Environment.new()
	var look_sun := DirectionalLight3D.new()
	var game_looks := Looks.new()
	add_child(look_sun)
	add_child(game_looks)
	# The sun's shadows as main.gd has them: the look's sun size and edge go to them.
	var shadows := SunShadows.new()
	shadows.sun = look_sun
	add_child(shadows)
	shadows.set_process(false)
	game_looks.shadows = shadows
	game_looks.attach(look_env, look_sun)
	var host := AddonHost.new()
	host.autoload = false
	host.main = fake
	add_child(host)
	host.load_all([[src.get_base_dir(), "test"]])
	await get_tree().process_frame
	var m := host.find("cinematic-shaders")
	var node: Node = m.get("node")
	check(node != null, "cinematic shaders: the add-on starts: " + str(m.get("problem", "")))
	if node == null:
		host.queue_free()
		game_looks.queue_free()
		shadows.queue_free()
		look_sun.queue_free()
		return
	var ids: Array = node.api.settings.list().map(func(d: Dictionary) -> String: return str(d.get("id", "")))
	check(str(Settings.get_value("graphics", "look")) == node.LOOK and not ids.has("use"),
		"cinematic shaders: its look is put on when it starts, with no switch of its own: %s" % [ids])
	check(game_looks.current == node.LOOK and not vp.use_taa, "cinematic shaders: TAA off by default (moving parts flicker under it)")
	check(not game_looks.own_clouds(), "cinematic shaders: Zenith's own clouds are off under its look")
	check(is_equal_approx(game_looks.twilight(), 1.0) and Looks.looks[node.LOOK].has("at_twilight") and Looks.looks[node.LOOK].has("at_dawn"), "cinematic shaders: it has a sunrise and sunset")
	node.api.settings.set_value("sunset", 0.5, false)
	check(is_equal_approx(game_looks.twilight(), 0.5), "cinematic shaders: its slider scales the sunset")
	node.api.settings.set_value("sunset", 1.0, false)
	check(not node.has_method("_process"), "cinematic shaders: it no longer reaches into Zenith for the sun")
	# 0.5.1: the noon sun from the north-west (Factorio's side), not high behind the view where every side a model
	# shows the camera was lit; "Noon sun from the north-west" off gives the old one, the sun held drops it.
	var noon_new := game_looks.noon_yaw(PlanetSky.YAW_NOON)
	node.api.settings.set_value("sun_side", false, false)
	var noon_old := game_looks.noon_yaw(PlanetSky.YAW_NOON)
	node.api.settings.set_value("sun_side", true, false)
	node.api.settings.set_value("sun_moves", false, false)
	var noon_held: Dictionary = Looks.looks[node.LOOK]
	check(is_equal_approx(noon_new, node.NOON_YAW) and is_equal_approx(noon_old, PlanetSky.YAW_NOON) and not noon_held.has("sun_noon_yaw") and noon_held.has("sun_angle"),
		"cinematic shaders: the noon sun north-west by default, Zenith's with the switch off, none while held (%s, %s)" % [noon_new, noon_old])
	node.api.settings.set_value("sun_moves", true, false)
	# 0.5.2 / 0.5.3 (lighting review step 5 + tuned defaults): occlusion on indirect light by default, little on the
	# sun's (ssao_light_affect 0.15, models' and the ground's own share off through ao_direct), radius 1.7, intensity 2.45,
	# power 2.0, SSIL off; "Occlusion in sunlight too" enables direct-light occlusion with the same SSAO parameters.
	var ao_new := [game_looks.ao_direct_put, look_env.ssao_light_affect, look_env.ssao_radius, look_env.ssao_intensity, look_env.ssao_power, look_env.ssil_enabled]
	check(is_equal_approx(game_looks.ao_direct_put, 0.0) and is_equal_approx(look_env.ssao_light_affect, node.AO_SUNLIGHT)
		and is_equal_approx(look_env.ssao_radius, 1.7) and is_equal_approx(look_env.ssao_intensity, 2.45)
		and is_equal_approx(look_env.ssao_power, 2.0) and not look_env.ssil_enabled
		and _global_is(&"f3d_look_ao_direct", 0.0),
		"cinematic shaders: occlusion on indirect light by default (ao_direct, light affect, radius, intensity, power, ssil): %s" % [ao_new])
	node.api.settings.set_value("ao_sun", true, false)
	var ao_sun_vals := [game_looks.ao_direct_put, look_env.ssao_light_affect, look_env.ssao_radius, look_env.ssao_intensity, look_env.ssao_power]
	check(is_equal_approx(game_looks.ao_direct_put, 1.0) and not is_equal_approx(look_env.ssao_light_affect, node.AO_SUNLIGHT)
		and is_equal_approx(look_env.ssao_radius, 1.7) and is_equal_approx(look_env.ssao_intensity, 2.45)
		and is_equal_approx(look_env.ssao_power, 2.0),
		"cinematic shaders: Occlusion in sunlight too enables direct-light occlusion with the same SSAO parameters: %s" % [ao_sun_vals])
	node.api.settings.set_value("ao_sun", false, false)
	game_looks.use("factorio")
	check(is_equal_approx(game_looks.ao_direct_put, 1.0) and not is_equal_approx(look_env.ssao_light_affect, node.AO_SUNLIGHT),
		"cinematic shaders: the Factorio look keeps occlusion on direct light (ao_direct 1, its light affect)")
	game_looks.use(node.LOOK)
	# 0.5.0: Soft shadows are an even edge of 0.04 tiles, no sun size; shadows that soften with distance
	# (PCSS) an option, off, at a sun size of 0.5; the anti-aliasing as before (TAA off, SMAA).
	var soft_said := [shadows.sun_size, look_sun.light_angular_distance, shadows.edge]
	check(is_equal_approx(shadows.sun_size, 0.0) and is_equal_approx(look_sun.light_angular_distance, 0.0) and is_equal_approx(shadows.edge, 0.04)
		and not bool(Looks.looks[node.LOOK].get("taa", true)) and not vp.use_taa,
		"cinematic shaders: by default no sun size and an edge of 0.04 tiles, no TAA (size, angular, edge): %s" % [soft_said])
	node.api.settings.set_value("pcss", true, false)
	var pcss_said := [shadows.sun_size, look_sun.light_angular_distance, look_sun.shadow_blur, look_sun.directional_shadow_pancake_size]
	var pcss_ok := is_equal_approx(look_sun.light_angular_distance, 0.5) and is_equal_approx(look_sun.shadow_blur, 1.0) 		and is_equal_approx(look_sun.directional_shadow_pancake_size, SunShadows.pcss_pancake)
	node.api.settings.set_value("sun_size", 1.2, false)
	pcss_ok = pcss_ok and is_equal_approx(look_sun.light_angular_distance, 1.2)
	check(pcss_ok, "cinematic shaders: shadows that soften with distance give the sun its size (0.5, then 1.2), blur 1 and the short pancake: %s" % [pcss_said])
	node.api.settings.set_value("pcss", false, false)
	node.api.settings.set_value("sun_size", 0.5, false)
	node.api.settings.set_value("soft_shadows", false, false)
	check(is_equal_approx(look_sun.light_angular_distance, 0.0) and is_equal_approx(shadows.edge, SunShadows.EDGE)
		and is_equal_approx(look_sun.directional_shadow_pancake_size, SunShadows.PANCAKE),
		"cinematic shaders: Soft shadows off, Factorio's edge (0.02 tiles); the option off, no sun size")
	node.api.settings.set_value("soft_shadows", true, false)
	node.api.settings.set_value("taa", true, false)
	check(vp.use_taa, "cinematic shaders: TAA on while its look is in use, when asked for")
	game_looks.lift()
	game_looks.settle(str(Settings.get_value("graphics", "look")))
	check(vp.use_taa and not game_looks.own_clouds(), "cinematic shaders: changing a Graphics setting leaves the look's TAA and clouds as they are")
	check(Looks.looks.has(node.LOOK) and float(Looks.looks[node.LOOK].get("roughness_min", 0.0)) > 0.3,
		"cinematic shaders: its look asks for a roughness floor")
	_texture_metal(game_looks, node.LOOK)
	_pack_shading(game_looks, node.LOOK)
	_pbr_env(game_looks)
	_pbr_light(game_looks)
	_pbr_scene(game_looks)
	_model_fill(game_looks)
	_pbr_rough(game_looks, node.LOOK)
	await _light_env(node.LOOK)
	await _light_zero("factorio")
	await _light_zero(node.LOOK)
	_noon_rig()
	_fill_light()
	# 0.4.5 / 0.6.0: the clouds' pattern drawn once into a texture the grade reads, paired with
	# seamless 3D Worley volumes for volumetric raymarched clouds.
	var params: Dictionary = (Looks.looks[node.LOOK]["passes"][0] as Dictionary).get("params", {})
	var field: SubViewport = node.get_node_or_null("CloudField")
	var field_shader: Shader = null
	if field != null and field.get_child_count() > 0:
		field_shader = ((field.get_child(0) as ColorRect).material as ShaderMaterial).shader
	var s3d: Variant = params.get("cloud_shape_3d")
	var d3d: Variant = params.get("cloud_detail_3d")
	check(params.get("cloud_field") is Texture2D and is_equal_approx(float(params.get("cloud_period", 0.0)), float(node.FIELD_PERIOD))
		and field != null and field.size == Vector2i(node.FIELD_SIZE, node.FIELD_SIZE) and field.use_hdr_2d
		and field_shader != null and field_shader.get_mode() == Shader.MODE_CANVAS_ITEM,
		"cinematic shaders: its clouds read a pattern drawn once by a 16-bit viewport of its own (cloud_field.gdshader)")
	var grade_shader: Shader = null
	if not game_looks._pass_nodes.is_empty():
		var pass_mi: MeshInstance3D = game_looks._pass_nodes[0] as MeshInstance3D
		if pass_mi != null and pass_mi.material_override is ShaderMaterial:
			grade_shader = (pass_mi.material_override as ShaderMaterial).shader
	if grade_shader == null:
		var pass_def: Dictionary = Looks.looks[node.LOOK]["passes"][0] as Dictionary
		grade_shader = load(str(pass_def.get("shader", ""))) as Shader
	var grade_uniforms: Array[String] = []
	if grade_shader != null:
		for u_var in grade_shader.get_shader_uniform_list():
			if u_var is Dictionary:
				var u: Dictionary = u_var
				grade_uniforms.append(str(u.get("name", "")))
	var grade_src: String = grade_shader.code if grade_shader != null else ""
	check(grade_shader != null
		and grade_uniforms.has("cloud_volumetric") and grade_uniforms.has("cloud_steps")
		and grade_uniforms.has("cloud_shape_3d") and grade_uniforms.has("cloud_detail_3d")
		and grade_src.contains("smoothstep(1.6, 3.5") and grade_src.contains("emissive_keep"),
		"cinematic shaders: grade shader exposes volumetric cloud uniforms, HDR halo suppression, and night emissive colour guard")
	# Lightning: a stormy night's cloud (about 0.05) at a full flash (1.0) and the default Flash
	# brightness's (0.75) brightens about as the Factorio look's sky does (1.6-3.4x), never twenty
	# times (a white sky); a day cloud barely; the switch keeps the old fixed 0.8.
	var night_full: float = node.flash_ratio(0.05, 1.0)
	var night_def: float = node.flash_ratio(0.05, 0.75)
	var day_full: float = node.flash_ratio(0.8, 1.0)
	var night_old: float = node.flash_ratio(0.05, 1.0, true)
	check(grade_uniforms.has("flash_old") and grade_src.contains("flash_light(c_step, flash")
		and grade_src.contains("flash_light(c, flash") and grade_src.contains("flash_light(bare, fl")
		and not grade_src.contains("flash_glow")
		and is_equal_approx(float(params.get("flash_old", -1.0)), 0.0)
		and is_equal_approx(float(params.get("flash_cap", 0.0)), float(node.FLASH_CAP))
		and night_full > 1.6 and night_full < 4.5 and night_def > 1.6 and night_def < 3.6
		and day_full < 1.35 and night_old > 15.0 and is_equal_approx(node.flash_ratio(0.05, 0.0), 1.0),
		"cinematic shaders: a lightning flash lights clouds in proportion (night %.2fx, at Flash brightness 0.75 %.2fx, day %.2fx; old %.1fx)" % [night_full, night_def, day_full, night_old])
	node.get_script().flash_arg_old = true
	node._register()
	var flash_old_params: Dictionary = (Looks.looks[node.LOOK]["passes"][0] as Dictionary).get("params", {})
	node.get_script().flash_arg_old = false
	node._register()
	check(is_equal_approx(float(flash_old_params.get("flash_old", 0.0)), 1.0),
		"cinematic shaders: --cinematic-flash=old gives the grade the old fixed flash")
	check(is_equal_approx(float(params.get("cloud_volumetric", 0.0)), 1.0)
		and is_equal_approx(float(params.get("cloud_steps", 0.0)), 40.0)
		and is_equal_approx(float(params.get("cloud_low", 0.0)), float(node.CLOUD_LOW_VOL))
		and is_equal_approx(float(params.get("cloud_high", 0.0)), float(node.CLOUD_HIGH_VOL))
		and s3d is ImageTexture3D and d3d is ImageTexture3D
		and (s3d as ImageTexture3D).get_width() == int(node.VOL_SIZE)
		and (s3d as ImageTexture3D).get_height() == int(node.VOL_SIZE)
		and (s3d as ImageTexture3D).get_depth() == int(node.VOL_SIZE)
		and (d3d as ImageTexture3D).get_width() == int(node.VOL_SIZE)
		and (d3d as ImageTexture3D).get_height() == int(node.VOL_SIZE)
		and (d3d as ImageTexture3D).get_depth() == int(node.VOL_SIZE),
		"cinematic shaders: volumetric clouds on by default with 40 steps, 210-390 shell, and 32x32x32 3D shape/detail textures")
	var cs_on: Dictionary = game_looks.cloud_source()
	check(int(cs_on.get("cloud_mode", -1)) == 2 and cs_on.get("look_cloud_field") == params.get("cloud_field")
		and is_equal_approx(float(cs_on.get("look_cloud_cover", 0.0)), float(params.get("cloud_cover", 0.0)))
		and is_equal_approx(float(cs_on.get("look_cloud_low", 0.0)), float(node.CLOUD_LOW_VOL))
		and is_equal_approx(float(cs_on.get("look_cloud_high", 0.0)), float(node.CLOUD_HIGH_VOL)),
		"cinematic shaders: looks.cloud_source() shares mode 2 cloud_field, cover, and volumetric shell bounds while clouds are on")
	node.api.settings.set_value("cloud_quality", "low", false)
	var low_params: Dictionary = (Looks.looks[node.LOOK]["passes"][0] as Dictionary).get("params", {})
	node.api.settings.set_value("cloud_quality", "medium", false)
	var med_params: Dictionary = (Looks.looks[node.LOOK]["passes"][0] as Dictionary).get("params", {})
	node.api.settings.set_value("cloud_quality", "high", false)
	var high_params: Dictionary = (Looks.looks[node.LOOK]["passes"][0] as Dictionary).get("params", {})
	check(is_equal_approx(float(low_params.get("cloud_steps", 0.0)), 18.0)
		and is_equal_approx(float(med_params.get("cloud_steps", 0.0)), 28.0)
		and is_equal_approx(float(high_params.get("cloud_steps", 0.0)), 40.0),
		"cinematic shaders: Cloud quality sets raymarch steps (18 / 28 / 40)")
	node.api.settings.set_value("volumetric_clouds", false, false)
	var legacy_params: Dictionary = (Looks.looks[node.LOOK]["passes"][0] as Dictionary).get("params", {})
	check(is_equal_approx(float(legacy_params.get("cloud_volumetric", -1.0)), 0.0)
		and is_equal_approx(float(legacy_params.get("cloud_low", 0.0)), float(node.CLOUD_LOW_OLD))
		and is_equal_approx(float(legacy_params.get("cloud_high", 0.0)), float(node.CLOUD_HIGH_OLD))
		and not legacy_params.has("cloud_shape_3d") and not legacy_params.has("cloud_detail_3d")
		and node._shape_3d != null and node._detail_3d != null,
		"cinematic shaders: switching Volumetric clouds off restores 0.5.3 bounds and omits 3D textures while caching them")
	node.api.settings.set_value("volumetric_clouds", true, false)
	node.api.settings.set_value("clouds", 0.0, false)
	var cloudless: Dictionary = (Looks.looks[node.LOOK]["passes"][0] as Dictionary).get("params", {})
	check(not cloudless.has("cloud_field") and not cloudless.has("cloud_shape_3d") and not cloudless.has("cloud_detail_3d")
		and node.get_node_or_null("CloudField") == field and game_looks.cloud_source().is_empty(),
		"cinematic shaders: with its clouds off the grade gets no patterns, the viewport stays for later, and own_clouds restores")
	node.api.settings.set_value("clouds", 1.0, false)
	host.set_enabled("cinematic-shaders", false)
	var released_3d := node._shape_3d == null and node._detail_3d == null
	await get_tree().process_frame
	check(released_3d, "cinematic shaders: stopping the add-on releases cached 3D cloud volumes")
	check(str(Settings.get_value("graphics", "look")) == "classic" and game_looks.current == "classic" and not vp.use_taa and game_looks.own_clouds(),
		"cinematic shaders: switched off, the look it replaced, the player's own TAA (off) and Zenith's clouds come back")
	check(is_equal_approx(look_sun.light_angular_distance, 0.0) and is_equal_approx(shadows.edge, SunShadows.EDGE),
		"cinematic shaders: switched off, Zenith's own shadow edge again")
	Settings.set_value("graphics", "look", look_before)
	Settings.reset_value("graphics", "look_before")
	Settings.reset_value("addons", "cinematic-shaders")
	host.queue_free()
	game_looks.queue_free()
	shadows.queue_free()
	look_sun.queue_free()


## sky.gd's sun as pure functions (add-on API 1.5): the path, the colour through the air, the swap to
## the moon with no light on, each planet's day.
## A shader global's value is `v`, where the renderer keeps them (the headless dummy one returns none).


func _global_is(param: StringName, v: float) -> bool:
	var now: Variant = RenderingServer.global_shader_parameter_get(param)
	return now == null or is_equal_approx(float(now), v)


## 0.2.2: a modeller's metallic-roughness picture's metal drawn at the share every other surface's is
## (looks.gd texture_metal): the look's key, its default, and the command line.


func _texture_metal(game_looks: Node, cinematic: String) -> void:
	var project_value = ProjectSettings.get_setting("shader_globals/f3d_look_texture_metal", {})
	check(project_value is Dictionary and is_equal_approx(float((project_value as Dictionary).get("value", -1.0)), 0.1),
		"texture metal: the menu and model preview draw a picture's metal at 0.1 (project.godot): %s" % [project_value])
	check(is_equal_approx(Looks.TEXTURE_METAL, 0.1) and not Settings.DEFAULTS["graphics"].has("texture_metal"),
		"texture metal: 0.1 by default and removed from Settings")
	check(is_equal_approx(game_looks.texture_metal(Looks.FACTORIO), 0.1) and is_equal_approx(game_looks.texture_metal(Looks.looks[cinematic]), 0.1),
		"texture metal: the Factorio and Cinematic looks draw a picture's metal as paint (0.1)")
	check(is_equal_approx(game_looks.texture_metal({"texture_metal": 0.4}), 0.4), "texture metal: a look's own key is used")
	game_looks.apply(0.0, 0.0, "nauvis", false)
	check(_global_is(&"f3d_look_texture_metal", 0.1),
		"texture metal: the look puts its share in the shader's global")
	check(is_equal_approx(Looks.texture_metal_arg(PackedStringArray(["--texture-metal=full"])), 1.0)
		and is_equal_approx(Looks.texture_metal_arg(PackedStringArray(["--x", "--texture-metal=0.3"])), 0.3)
		and is_equal_approx(Looks.texture_metal_arg(PackedStringArray(["--texture-metal=paint"])), 0.1)
		and Looks.texture_metal_arg(PackedStringArray(["--look=classic"])) < 0.0,
		"texture metal: --texture-metal=full, =paint and a number read; none without")
	game_looks._metal_arg = 1.0
	check(is_equal_approx(game_looks.texture_metal({"texture_metal": 0.4}), 1.0), "texture metal: the command line wins over the look's key")
	game_looks.apply(0.0, 0.0, "nauvis", false)
	check(_global_is(&"f3d_look_texture_metal", 1.0),
		"texture metal: --texture-metal=full puts 1 in the shader's global")
	game_looks._metal_arg = 0.3
	check(is_equal_approx(game_looks.texture_metal(Looks.FACTORIO), 0.3), "texture metal: the command line share is used")
	game_looks._metal_arg = -1.0
	game_looks.settle(str(Settings.get_value("graphics", "look")))


## pbr-standard step 3: the neutral reflection of a "pbr" pack's surfaces (shaders/pbr_env.gdshaderinc) follows
## the light of the moment (ambient plus pbr_env of the sun, linear) and their metal is drawn in full; the menu and
## preview get the noon value; --pbr-env=off and --pbr-metal=0.1 give 0.2.2's drawing.


func _pbr_env(game_looks: Node) -> void:
	var project_env = ProjectSettings.get_setting("shader_globals/f3d_pbr_env", {})
	var project_metal = ProjectSettings.get_setting("shader_globals/f3d_look_pbr_metal", {})
	check(project_env is Dictionary and ((project_env as Dictionary).get("value") as Vector4).is_equal_approx(Looks.PBR_ENV_REST)
		and project_metal is Dictionary and is_equal_approx(float((project_metal as Dictionary).get("value", -1.0)), 1.0),
		"pbr env: the menu and preview reflect the noon value and draw metal in full (project.godot): %s, %s" % [project_env, project_metal])
	check(is_equal_approx(game_looks.pbr_env_k(Looks.FACTORIO), Looks.PBR_ENV) and is_equal_approx(game_looks.pbr_metal(Looks.FACTORIO), 1.0)
		and is_equal_approx(game_looks.pbr_env_k({"pbr_env": 0.2}), 0.2) and is_equal_approx(game_looks.pbr_metal({"pbr_metal": 0.5}), 0.5),
		"pbr env: k and metal share by default, a look's own keys used")
	# The command line is read once in _ready (apply() runs every frame): the cached values win over the look's.
	game_looks._pbr_env_arg = 0.7
	game_looks._pbr_metal_arg = 0.3
	check(is_equal_approx(game_looks.pbr_env_k(Looks.FACTORIO), 0.7) and is_equal_approx(game_looks.pbr_metal(Looks.FACTORIO), 0.3),
		"pbr env: --pbr-env's and --pbr-metal's values, read once at start, win over the look's")
	game_looks._pbr_env_arg = -1.0
	game_looks._pbr_metal_arg = -1.0
	game_looks.apply(0.0, 0.0, "nauvis", false)
	var got: Vector4 = game_looks.pbr_env_now(Looks.FACTORIO)
	var now: Variant = RenderingServer.global_shader_parameter_get(&"f3d_pbr_env")  # null headless
	var e: Environment = game_looks.env
	var s: DirectionalLight3D = game_looks.sun
	var want := e.ambient_light_color.srgb_to_linear() * e.ambient_light_energy + s.light_color.srgb_to_linear() * s.light_energy * Looks.PBR_ENV
	check(want.r > 0.0 and got.is_equal_approx(Vector4(want.r, want.g, want.b, 1.0)) and (now == null or now == got) and _global_is(&"f3d_look_pbr_metal", 1.0),
		"pbr env: the look puts this moment's ambient plus %.2f of the sun in the shader's global (%s, want %s)" % [Looks.PBR_ENV, got, want])
	check(Looks.pbr_env_switch(PackedStringArray()) and not Looks.pbr_env_switch(PackedStringArray(["--pbr-env=off"]))
		and Looks.pbr_env_switch(PackedStringArray(["--pbr-env=0.3"])) and is_equal_approx(Looks.pbr_env_arg(PackedStringArray(["--x", "--pbr-env=0.3"])), 0.3)
		and Looks.pbr_env_arg(PackedStringArray(["--pbr-env=off"])) < 0.0,
		"pbr env: --pbr-env=off turns it off, a number sets k")
	check(is_equal_approx(Looks.pbr_metal_arg(PackedStringArray(["--pbr-metal=0.1"])), 0.1) and is_equal_approx(Looks.pbr_metal_arg(PackedStringArray(["--pbr-metal=paint"])), 0.1)
		and is_equal_approx(Looks.pbr_metal_arg(PackedStringArray(["--pbr-metal=full"])), 1.0) and Looks.pbr_metal_arg(PackedStringArray()) < 0.0,
		"pbr env: --pbr-metal=0.1, =paint, =full read; none without")
	var shader_text := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc")
	var items_text := FileAccess.get_file_as_string("res://shaders/item_body.gdshaderinc") + FileAccess.get_file_as_string("res://shaders/belt_lane_model.gdshaderinc")
	check(shader_text.contains("RADIANCE = pbr_env_radiance(") and shader_text.contains("metal = m_metal * f3d_look_pbr_metal;")
		and items_text.count("RADIANCE = pbr_env_radiance(") == 2,
		"pbr env: the model and item shaders write the neutral reflection and draw a pbr pack's metal at its own share")


## pbr-light-balance: a "pbr" pack lit by direction (shaders/pbr_env.gdshaderinc): its share of the look's fill and
## ambient (pbr_fill, pbr_ambient), the ambient and the sun's direction of the moment in the shader's globals, the
## ambient and reflection by direction; --pbr-light=flat and outside a game, flat (0.2.2's balance).


func _pbr_light(game_looks: Node) -> void:
	var project_light = ProjectSettings.get_setting("shader_globals/f3d_pbr_light", {})
	check(project_light is Dictionary and ((project_light as Dictionary).get("value") as Vector4).is_equal_approx(Looks.PBR_LIGHT_REST)
		and is_equal_approx(Looks.PBR_LIGHT_REST.x, 0.0) and ProjectSettings.has_setting("shader_globals/f3d_pbr_sky")
		and ProjectSettings.has_setting("shader_globals/f3d_pbr_sun"),
		"pbr light: the menu and preview are lit flat, as before (project.godot): %s" % [project_light])
	check(game_looks.pbr_light_shares(Looks.FACTORIO).is_equal_approx(Vector2(Looks.PBR_FILL, Looks.PBR_AMBIENT))
		and Looks.PBR_FILL < 1.0 and game_looks.pbr_light_shares({"pbr_fill": 0.5, "pbr_ambient": 0.7}).is_equal_approx(Vector2(0.5, 0.7))
		and game_looks.pbr_light_shares({"pbr_fill": 9.0, "pbr_ambient": -1.0}).is_equal_approx(Vector2(2.0, 0.0)),
		"pbr light: the fill share down by default (%.2f, ambient %.2f), a look's own keys used and held to 0-2" % [Looks.PBR_FILL, Looks.PBR_AMBIENT])
	check(Looks.pbr_light_switch(PackedStringArray()) and not Looks.pbr_light_switch(PackedStringArray(["--pbr-light=flat"]))
		and not Looks.pbr_light_switch(PackedStringArray(["--x", "--pbr-light=off"])) and Looks.pbr_light_switch(PackedStringArray(["--pbr-light=directional"])),
		"pbr light: by direction by default, --pbr-light=flat (or off) flat")
	game_looks.apply(0.0, 0.0, "nauvis", false)
	var e: Environment = game_looks.env
	var s: DirectionalLight3D = game_looks.sun
	var was_sun := s.rotation_degrees
	s.rotation_degrees = Vector3(-42.0, -112.0, 0.0)  # the Factorio look's sun
	var now: Dictionary = game_looks.pbr_light_now(Looks.FACTORIO)
	var amb := e.ambient_light_color.srgb_to_linear() * e.ambient_light_energy
	var to_sun := s.global_transform.basis.z.normalized()
	s.rotation_degrees = was_sun
	var sky: Vector4 = now[&"f3d_pbr_sky"]
	var sun_dir: Vector4 = now[&"f3d_pbr_sun"]
	check((now[&"f3d_pbr_light"] as Vector4).is_equal_approx(Vector4(1.0, Looks.PBR_FILL, Looks.PBR_AMBIENT, 1.0)) and amb.r > 0.0
		and sky.is_equal_approx(Vector4(amb.r, amb.g, amb.b, 0.0)) and Vector3(sun_dir.x, sun_dir.y, sun_dir.z).is_equal_approx(to_sun) and absf(to_sun.y - sin(deg_to_rad(42.0))) < 0.01,
		"pbr light: the look puts the shares, this moment's ambient and the way to its sun (up %.2f) in the shader's globals: %s" % [to_sun.y, now])
	game_looks._pbr_light_on = false
	var flat: Dictionary = game_looks.pbr_light_now(Looks.FACTORIO)
	game_looks._pbr_light_on = true
	check(is_equal_approx((flat[&"f3d_pbr_light"] as Vector4).x, 0.0), "pbr light: --pbr-light=flat puts flat in the global")
	# The shaders: a "pbr" surface's fill at its share, its ambient and reflection by direction; flat as before.
	var env_text := FileAccess.get_file_as_string("res://shaders/pbr_env.gdshaderinc")
	var shader_text := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc")
	var items_text := FileAccess.get_file_as_string("res://shaders/item_body.gdshaderinc") + FileAccess.get_file_as_string("res://shaders/belt_lane_model.gdshaderinc")
	var fill_text := FileAccess.get_file_as_string("res://shaders/item_pbr.gdshaderinc")
	check(shader_text.contains("IRRADIANCE = pbr_irradiance(") and shader_text.contains("(mp ? pbr_fill_share() : 1.0)")
		and items_text.count("IRRADIANCE = pbr_irradiance(") == 2 and fill_text.contains("f3d_look_model_fill * pbr_fill_share()")
		and env_text.contains("return vec4(mix(up * 0.45, up, h), on);") and env_text.contains("pbr_directional() && f3d_light_env < 0.5 ? 1.0 : 0.0"),
		"pbr light: buildings, items and belt items take the fill share and the ambient by direction; flat draws as before")


## pbr-light-follows-scene: a "pbr" pack's extra light (the neutral reflection's sun and sky parts, the ambient by
## direction, the fill) follows the sun and ambient the debug menu's sliders put on the scene: at sun 0 and ambient 0
## the globals give no light; untouched, as before; --pbr-light-scene=off, the old order (the sliders didn't reach them).


func _pbr_scene(game_looks: Node) -> void:
	var e: Environment = game_looks.env
	var s: DirectionalLight3D = game_looks.sun
	var was_tune := Looks.light_tune.duplicate()
	var was_amb := e.ambient_light_energy
	var was_sun := s.light_energy
	# sky.gd lights the scene afresh each frame before apply(); nothing does here, so each apply starts from these.
	check(Looks.pbr_scene_switch(PackedStringArray()) and not Looks.pbr_scene_switch(PackedStringArray(["--x", "--pbr-light-scene=off"]))
		and Looks.pbr_scene_switch(PackedStringArray(["--pbr-light=flat"])) and Looks.pbr_light_switch(PackedStringArray(["--pbr-light-scene=off"])),
		"pbr scene: on by default, --pbr-light-scene=off turns it off (and --pbr-light is its own switch)")
	check(is_equal_approx(Looks.pbr_fill_scene(0.4, 0.4), 1.0) and is_equal_approx(Looks.pbr_fill_scene(0.4, 0.0), 0.0)
		and is_equal_approx(Looks.pbr_fill_scene(0.4, 0.2), 0.5) and is_equal_approx(Looks.pbr_fill_scene(0.4, 4.0), 2.0)
		and is_equal_approx(Looks.pbr_fill_scene(0.0, 0.3), 1.0) and is_equal_approx(Looks.pbr_fill_scene(0.0, 0.0), 1.0),
		"pbr scene: the fill's share is the ambient now over the game's (1 untouched, 0 at none, held to 2)")
	# Untouched: the fill whole and the globals the scene's light (the defaults as before).
	Looks.light_tune.clear()
	e.ambient_light_energy = was_amb
	s.light_energy = was_sun
	game_looks.apply(0.0, 0.0, "nauvis", false)
	var put: Dictionary = game_looks.pbr_put
	var light: Vector4 = put.get(&"f3d_pbr_light", Vector4.ZERO)
	var env0: Vector4 = put.get(&"f3d_pbr_env", Vector4.ZERO)
	check(is_equal_approx(light.w, 1.0) and env0.x > 0.0 and env0.is_equal_approx(game_looks.pbr_env_now(Looks.FACTORIO)),
		"pbr scene: without the sliders the fill is whole and the reflection the scene's (%s, %s)" % [light, env0])
	# Both sliders at 0: no sun lobe, no sky, no fill.
	Looks.light_tune = {"sun_energy": 0.0, "ambient_energy": 0.0}
	e.ambient_light_energy = was_amb
	s.light_energy = was_sun
	game_looks.apply(0.0, 0.0, "nauvis", false)
	put = game_looks.pbr_put
	light = put.get(&"f3d_pbr_light", Vector4.ONE)
	var env_zero: Vector4 = put.get(&"f3d_pbr_env", Vector4.ONE)
	var sky: Vector4 = put.get(&"f3d_pbr_sky", Vector4.ONE)
	check(is_zero_approx(env_zero.x) and is_zero_approx(env_zero.y) and is_zero_approx(env_zero.z) and is_equal_approx(env_zero.w, 1.0)
		and is_zero_approx(sky.x) and is_zero_approx(sky.y) and is_zero_approx(sky.z) and is_zero_approx(light.w),
		"pbr scene: sun 0 and ambient 0 put no light in the reflection, the sky or the fill (%s, %s, %s)" % [env_zero, sky, light])
	# Ambient only at 0: the reflection is the sun's lobe alone, the fill gone.
	Looks.light_tune = {"ambient_energy": 0.0}
	e.ambient_light_energy = was_amb
	s.light_energy = was_sun
	game_looks.apply(0.0, 0.0, "nauvis", false)
	put = game_looks.pbr_put
	var lit := s.light_color.srgb_to_linear() * s.light_energy * Looks.PBR_ENV
	check((put[&"f3d_pbr_env"] as Vector4).is_equal_approx(Vector4(lit.r, lit.g, lit.b, 1.0)) and lit.r > 0.0 and is_zero_approx((put[&"f3d_pbr_light"] as Vector4).w),
		"pbr scene: ambient 0 leaves the sun's part of the reflection and no fill (%s)" % [put[&"f3d_pbr_env"]])
	# The switch off: the globals are read before the sliders, as before (the sun and ambient the game set).
	Looks.light_tune = {"sun_energy": 0.0, "ambient_energy": 0.0}
	game_looks._pbr_scene_on = false
	e.ambient_light_energy = was_amb
	s.light_energy = was_sun
	game_looks.apply(0.0, 0.0, "nauvis", false)
	put = game_looks.pbr_put
	game_looks._pbr_scene_on = true
	check((put[&"f3d_pbr_env"] as Vector4).x > 0.0 and is_equal_approx((put[&"f3d_pbr_light"] as Vector4).w, 1.0),
		"pbr scene: --pbr-light-scene=off reads the light before the sliders, as before (%s)" % [put[&"f3d_pbr_env"]])
	var env_text := FileAccess.get_file_as_string("res://shaders/pbr_env.gdshaderinc")
	check(not env_text.contains("* clamp(f3d_pbr_light.w, 0.0, 2.0);"),
		"pbr scene: the shaders' fill share leaves the scene's ambient to f3d_look_model_fill (counted once)")
	Looks.light_tune = was_tune
	e.ambient_light_energy = was_amb
	s.light_energy = was_sun


## light-remove-fill (owner: "remove that default light"): the camera fill on every model, tree, item and far chunk is
## off by default; --model-fill=on brings the look's back, the debug menu's Camera fill slider sets it live, and
## whatever fill there is follows the ambient the sliders set. The sky's own colour follows the sun and ambient sliders.
## lighting-fixes step 1: the lighting environment in the sky's cubemap. A game's looks node with a sky: Godot's ambient
## and reflections held on the sky (source SKY, contribution 1) while the look's own values come back when it goes;
## the cubemap's upper half the ambient, its lower half the ground's albedo times the sun on flat ground plus the
## ambient; a look's sky ambient (Cinematic at twilight) its share of the drawn sky; "pbr" packs' own terms off
## (f3d_light_env 1); --light-env=shader leaves all as before.
## lighting-fixes step 6: the menu's backdrop and the Model packs preview are lit by Looks.noon_rig, which is what a
## game puts at noon on Nauvis under the Factorio look (sky.gd, then looks.gd apply and put_light_env), and
## put_noon_rig lights an environment from it as put_light_env does; --preview-light=studio keeps the old lights.


func _noon_rig() -> void:
	check(Looks.preview_light_switch(PackedStringArray()) and not Looks.preview_light_switch(PackedStringArray(["--preview-light=studio"])),
		"noon rig: the game's light in the preview and menu by default, --preview-light=studio the old")
	var e := Environment.new()
	var sky_node := PlanetSky.new()
	add_child(sky_node)
	var sky := Sky.new()
	sky.sky_material = sky_node.sky_material
	e.sky = sky
	e.background_mode = Environment.BG_SKY
	var s := DirectionalLight3D.new()
	add_child(s)
	var was_active: Node = Looks.active
	var lk := Looks.new()
	add_child(lk)
	lk.attach(e, s)
	lk.use("factorio", true)
	sky_node.apply(e, s, 0.0, 0.0, 0.016, false)
	lk.apply(0.0, 0.0, "nauvis", false, sky_node.state)
	var rig := Looks.noon_rig()
	var put: Dictionary = lk.env_put
	var game := [s.light_energy, s.rotation_degrees, s.light_color, s.light_specular, e.ambient_light_color, e.ambient_light_energy,
		e.tonemap_mode, e.tonemap_exposure, put.get("sky"), put.get("ground")]
	check(is_equal_approx(s.light_energy, float(rig["sun_energy"])) and s.rotation_degrees.is_equal_approx(rig["sun_rotation"])
		and s.light_color.is_equal_approx(rig["sun_color"]) and is_equal_approx(s.light_specular, float(rig["sun_specular"]))
		and e.ambient_light_color.is_equal_approx(rig["ambient_color"]) and is_equal_approx(e.ambient_light_energy, float(rig["ambient_energy"]))
		and e.tonemap_mode == int(rig["tonemap"]) and is_equal_approx(e.tonemap_exposure, float(rig["exposure"]))
		and put.get("sky") is Vector3 and (put["sky"] as Vector3).is_equal_approx(rig["env_sky"])
		and (put["ground"] as Vector3).is_equal_approx(rig["env_ground"]),
		"noon rig: the preview's and menu's light is the game's at noon on Nauvis (game %s, rig %s)" % [game, rig])
	var e2 := Environment.new()
	e2.background_mode = Environment.BG_COLOR
	var s2 := DirectionalLight3D.new()
	Looks.put_noon_rig(e2, s2, rig)
	var m2 := e2.sky.sky_material as ShaderMaterial if e2.sky != null else null
	check(m2 != null and m2.shader == PlanetSky.SKY_SHADER and float(m2.get_shader_parameter("env_on")) > 0.5
		and (m2.get_shader_parameter("env_sky") as Vector3).is_equal_approx(rig["env_sky"])
		and (m2.get_shader_parameter("env_ground") as Vector3).is_equal_approx(rig["env_ground"])
		and e2.ambient_light_source == Environment.AMBIENT_SOURCE_SKY and is_equal_approx(e2.ambient_light_sky_contribution, 1.0)
		and e2.reflected_light_source == Environment.REFLECTION_SOURCE_SKY and e2.sky.radiance_size == Looks.LIGHT_ENV_RADIANCE
		and e2.background_mode == Environment.BG_COLOR and s2.rotation_degrees.is_equal_approx(rig["sun_rotation"])
		and is_equal_approx(s2.light_energy, float(rig["sun_energy"])) and e2.tonemap_mode == Environment.TONE_MAPPER_LINEAR,
		"noon rig: put on an environment outside a game, its sky's cubemap is the lighting environment (the background its own)")
	s2.free()
	lk.queue_free()
	Looks.active = was_active
	s.queue_free()
	sky_node.queue_free()


## lighting-fixes step 3: the Factorio look's fill light, a sun of its own with no shadow on everything but the ground
## (Visuals.GROUND_LAYER: terrain, far chunks, flat decoratives), faded out by night; none in a look without the key;
## --fill-light=off or a number.


func _fill_light() -> void:
	check(is_equal_approx(Looks.fill_light_arg(PackedStringArray()), -1.0) and is_equal_approx(Looks.fill_light_arg(PackedStringArray(["--fill-light=off"])), 0.0)
		and is_equal_approx(Looks.fill_light_arg(PackedStringArray(["--fill-light=0.2"])), 0.2),
		"fill light: the look's by default, --fill-light=off none, a number that energy")
	var e := Environment.new()
	var s := DirectionalLight3D.new()
	add_child(s)
	var was_active: Node = Looks.active
	var lk := Looks.new()
	add_child(lk)
	lk.attach(e, s)
	lk.use("factorio", true)
	s.light_energy = 1.1
	lk.apply(0.0, 0.0, "nauvis", false)
	var f: DirectionalLight3D = lk.fill_light
	var want := float(Looks.FACTORIO.get("fill_light", 0.0))
	check(f != null and f.visible and is_equal_approx(f.light_energy, want) and want > 0.0 and not f.shadow_enabled
		and (f.light_cull_mask & Visuals.GROUND_LAYER) == 0 and (f.light_cull_mask & 1) != 0
		and is_equal_approx(f.global_rotation_degrees.x, -Looks.FILL_PITCH),
		"fill light: the Factorio look's by day (%.2f), no shadow, everything but the ground, from %.0f degrees up" % [want, Looks.FILL_PITCH])
	lk.apply(0.0, 1.0, "nauvis", false)
	check(not f.visible and is_equal_approx(lk.fill_light_put, 0.0), "fill light: none at night")
	lk.apply(0.0, 0.0, "nauvis", true)
	check(not f.visible, "fill light: none in space")
	lk.use("classic", true)
	lk.apply(0.0, 0.0, "nauvis", false)
	check(not f.visible, "fill light: none in a look without one (Classic)")
	lk._fill_light_arg = 0.0
	lk.use("factorio", true)
	lk.apply(0.0, 0.0, "nauvis", false)
	check(not f.visible, "fill light: none with --fill-light=off")
	lk.queue_free()
	Looks.active = was_active
	s.queue_free()


## The debug menu's Sun energy 0 and Ambient energy 0 leave nothing lit but lamps and emission, by day, at dusk and
## at night with night vision on, under look `look_id`: no ambient or sun, no fill light, no environment in the sky's
## cubemap, no fog light, the drawn sky and the look's passes (Cinematic's clouds) dark; all back when let go.


func _light_zero(look_id: String) -> void:
	var e := Environment.new()
	var sky_node := PlanetSky.new()
	add_child(sky_node)
	var sky := Sky.new()
	sky.sky_material = sky_node.sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	e.sky = sky
	e.background_mode = Environment.BG_SKY
	var s := DirectionalLight3D.new()
	add_child(s)
	var was_active: Node = Looks.active
	var was_tune := Looks.light_tune
	var lk := Looks.new()
	add_child(lk)
	lk.attach(e, s)
	lk.use(look_id, true)
	var m := sky_node.sky_material
	var state := {"twilight": 0.0, "height": 0.8, "morning": false, "direction": Vector3(0.3, 0.8, 0.5),
		"color": Color(1, 0.95, 0.9), "fog": Color(0.7, 0.75, 0.85)}
	var tick := func(night: float, twilight: float) -> void:
		e.ambient_light_energy = 0.6
		e.ambient_light_color = Color(0.75, 0.78, 0.82)
		s.light_energy = 1.1
		s.light_color = Color(1, 0.95, 0.9)
		state["twilight"] = twilight
		lk.apply(0.0, night, "nauvis", false, state)
	tick.call(0.0, 0.0)
	var fog0 := e.fog_light_energy
	var fill0 := lk.fill_light_put
	for when: Array in [[0.0, 0.0, 0.0], [0.3, 1.0, 0.0], [1.0, 0.0, 1.0]]:
		Looks.light_tune = {"sun_energy": 0.0, "ambient_energy": 0.0}
		lk.night_vision = float(when[2])
		tick.call(float(when[0]), float(when[1]))
		var put: Dictionary = lk.env_put
		var dark := put.is_empty() or ((put["sky"] as Vector3).is_zero_approx() and (put["ground"] as Vector3).is_zero_approx()
			and (m.get_shader_parameter("env_glow") as Vector3).is_zero_approx())
		var passes_dark := true
		for n: MeshInstance3D in lk._pass_nodes:
			var v = (n.material_override as ShaderMaterial).get_shader_parameter("look_scene_light")
			passes_dark = passes_dark and v is Vector2 and (v as Vector2).is_zero_approx()
		check(is_zero_approx(e.ambient_light_energy) and is_zero_approx(s.light_energy) and is_zero_approx(lk.fill_light_put)
			and not lk.fill_light.visible and dark and is_zero_approx(e.fog_light_energy) and is_zero_approx(e.fog_sun_scatter)
			and lk.sky_put.is_zero_approx() and lk.scene_now.is_zero_approx() and passes_dark,
			"light zero (%s, night %.1f, twilight %.0f, night vision %.0f): sun 0 and ambient 0 light nothing (ambient %.2f, fill %.2f, env %s, fog %.2f, sky %s)"
			% [look_id, when[0], when[1], when[2], e.ambient_light_energy, lk.fill_light_put, put, e.fog_light_energy, lk.sky_put])
	Looks.light_tune = {}
	lk.night_vision = 0.0
	tick.call(0.0, 0.0)
	check(is_equal_approx(e.fog_light_energy, fog0) and is_equal_approx(lk.fill_light_put, fill0) and lk.scene_now == Vector2.ONE
		and lk.sky_put == Vector2.ONE, "light zero (%s): let go, the fog's light (%.2f) and the fill (%.2f) are the look's again" % [look_id, fog0, fill0])
	Looks.light_tune = was_tune
	lk.queue_free()
	Looks.active = was_active
	s.queue_free()
	sky_node.queue_free()
	await get_tree().process_frame


func _light_env(look_id: String) -> void:
	check(Looks.light_env_switch(PackedStringArray()) and not Looks.light_env_switch(PackedStringArray(["--light-env=shader"]))
		and Looks.light_env_switch(PackedStringArray(["--light-env=old", "--light-env=sky"])),
		"light env: the sky's cubemap by default, --light-env=shader the old way")
	var e := Environment.new()
	var sky_node := PlanetSky.new()
	add_child(sky_node)
	var sky := Sky.new()
	sky.sky_material = sky_node.sky_material
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	e.sky = sky
	e.background_mode = Environment.BG_SKY
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.75, 0.78, 0.82)
	var s := DirectionalLight3D.new()
	add_child(s)
	var was_active: Node = Looks.active
	var lk := Looks.new()
	add_child(lk)
	lk.attach(e, s)
	lk.use("factorio", true)
	var m := sky_node.sky_material
	var tick := func(night: float) -> void:
		e.ambient_light_energy = 0.6
		e.ambient_light_color = Color(0.75, 0.78, 0.82)
		s.light_energy = 1.1
		lk.apply(0.0, night, "nauvis", false)
	tick.call(0.0)
	var lit_amb := e.ambient_light_energy
	tick.call(1.0)
	var night_amb := e.ambient_light_energy
	tick.call(0.0)
	check(is_equal_approx(lit_amb, 0.6 * float(Looks.FACTORIO["ambient_energy_lit"])) and is_equal_approx(night_amb, 0.6 * float(Looks.FACTORIO["ambient_energy"]))
		and float(Looks.FACTORIO["ambient_energy_lit"]) > float(Looks.FACTORIO["ambient_energy"]) * 1.8,
		"light env: the Factorio look's daylight ambient raised for its sun-to-shade ratio (%.3f), nights as before (%.3f)" % [lit_amb, night_amb])
	var amb := e.ambient_light_color.srgb_to_linear() * e.ambient_light_energy
	var to_sun := s.global_transform.basis.z.normalized()
	var sun_flat := s.light_color.srgb_to_linear() * s.light_energy * to_sun.y
	var g := Looks.LIGHT_ENV_GROUND
	var want_ground := Vector3(g.r * (sun_flat.r + amb.r), g.g * (sun_flat.g + amb.g), g.b * (sun_flat.b + amb.b))
	var put: Dictionary = lk.env_put
	check(sky.radiance_size == Looks.LIGHT_ENV_RADIANCE and e.ambient_light_source == Environment.AMBIENT_SOURCE_SKY
		and is_equal_approx(e.ambient_light_sky_contribution, 1.0) and e.reflected_light_source == Environment.REFLECTION_SOURCE_SKY
		and float(m.get_shader_parameter("env_on")) > 0.5,
		"light env: in a game Godot's ambient and reflections come from the sky's cubemap (size %d), drawn as the environment" % sky.radiance_size)
	check(put.has("sky") and (put["sky"] as Vector3).is_equal_approx(Vector3(amb.r, amb.g, amb.b)) and (put["ground"] as Vector3).is_equal_approx(want_ground)
		and (put["ground"] as Vector3).x > (put["sky"] as Vector3).x and is_zero_approx(float(put["sky_mix"])),
		"light env: upper half the ambient, lower half the ground lit by the sun and the ambient, no drawn sky in the Factorio look: %s" % [put])
	# Night vision (main.gd's night_vision) lifts the ambient inside apply(), so every surface sees it; a second put in
	# a frame keeps the look's drawn-sky share.
	lk.night_vision = 1.0
	tick.call(0.0)
	lk.night_vision = 0.0
	check(((lk.env_put["sky"] as Vector3).x > (put["sky"] as Vector3).x * 2.0), "light env: night vision's lifted ambient in the environment")
	lk.put_light_env(false)
	check(is_zero_approx(float(lk.env_put["sky_mix"])) and is_zero_approx(float(m.get_shader_parameter("env_sky_mix"))),
		"light env: a second put in a frame (night vision) keeps the look's drawn-sky share (%s), not the forced one" % [lk.env_put["sky_mix"]])
	# The look's own sources come back when it goes, and when a look asks for sky ambient that is its drawn-sky share.
	lk.use(look_id, true)
	tick.call(0.0)
	var cin_mix := float(lk.env_put.get("sky_mix", -1.0))
	e.background_energy_multiplier = 0.5
	e.ambient_light_sky_contribution = 0.5  # as Cinematic's twilight blends it
	lk._env_held["ambient_light_source"] = Environment.AMBIENT_SOURCE_SKY
	lk._env_held["ambient_light_sky_contribution"] = 0.5
	lk.put_light_env(false)
	lk.put_light_env(false)  # twice, as with night vision: the share stays
	check(is_zero_approx(cin_mix) and is_equal_approx(float(lk.env_put["sky_mix"]), 0.5) and is_equal_approx(float(m.get_shader_parameter("env_gain")), 0.5)
		and (m.get_shader_parameter("env_sky") as Vector3).is_equal_approx((lk.env_put["sky"] as Vector3) * 2.0),
		"light env: %s's sky ambient at twilight is its share of the drawn sky (%.2f), the background's energy undone (%s)" % [look_id, float(lk.env_put["sky_mix"]), m.get_shader_parameter("env_gain")])
	e.background_energy_multiplier = 1.0
	lk.lift()
	check(e.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR and lk._env_held.is_empty(),
		"light env: lifted, the environment's own ambient source is back (%d)" % e.ambient_light_source)
	lk.settle("factorio")
	lk.put_light_env(true)
	check(((lk.env_put["ground"] as Vector3) - (lk.env_put["sky"] as Vector3) * 0.5).length() < 1e-4,
		"light env: in space no ground, the lower half half the ambient")
	lk._light_env_sky = false
	lk._env_release()
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	tick.call(0.0)
	check(e.ambient_light_source == Environment.AMBIENT_SOURCE_COLOR and float(m.get_shader_parameter("env_on")) < 0.5 and lk.env_put.is_empty()
		and is_equal_approx(e.ambient_light_energy, 0.6 * float(Looks.FACTORIO["ambient_energy"])),
		"light env: --light-env=shader leaves the constant ambient, the drawn sky and the look's 0.2.2 ambient (%.3f)" % e.ambient_light_energy)
	remove_child(lk)
	lk.free()
	Looks.active = was_active
	s.queue_free()
	sky_node.queue_free()
	await get_tree().process_frame
	var env_text := FileAccess.get_file_as_string("res://shaders/pbr_env.gdshaderinc")
	var sky_text := FileAccess.get_file_as_string("res://shaders/planet_sky.gdshader")
	check(env_text.contains("step(f3d_light_env, 0.5)") and env_text.contains("f3d_light_env < 0.5") and sky_text.contains("AT_CUBEMAP_PASS && env_on > 0.5")
		and sky_text.contains("AT_CUBEMAP_PASS && env_on > 0.5 && env_sky_mix <= 0.0001")
		and Looks.LIGHT_ENV_RADIANCE == Sky.RADIANCE_SIZE_32
		and ProjectSettings.has_setting("shader_globals/f3d_light_env"),
		"light env: pbr packs' own RADIANCE and IRRADIANCE off while the sky lights them; the sky draws the environment in its cubemap pass (size 32 + daytime early-out)")
	# put_light_env skips redundant uniform writes when values are unchanged, and writes when they change.
	var e3 := Environment.new()
	var sky3 := Sky.new()
	var mat3 := ShaderMaterial.new()
	mat3.shader = PlanetSky.SKY_SHADER
	sky3.sky_material = mat3
	e3.sky = sky3
	e3.ambient_light_color = Color(0.75, 0.78, 0.82)
	e3.ambient_light_energy = 0.6
	var s3 := DirectionalLight3D.new()
	add_child(s3)
	var lk3 := Looks.new()
	add_child(lk3)
	lk3.attach(e3, s3)
	lk3.use("factorio", true)
	lk3.put_light_env(false)
	var sent_sky := Vector3(mat3.get_shader_parameter("env_sky"))
	var sentinel := Vector3(99.0, 99.0, 99.0)
	mat3.set_shader_parameter("env_sky", sentinel)
	lk3.put_light_env(false)  # unchanged inputs: dirty-check skips overwriting mat3
	var kept_sentinel := Vector3(mat3.get_shader_parameter("env_sky")).is_equal_approx(sentinel)
	e3.ambient_light_energy = 1.2
	lk3.put_light_env(false)  # changed input: dirty-check writes new env_sky
	var updated_sky := Vector3(mat3.get_shader_parameter("env_sky"))
	check(kept_sentinel and updated_sky.x > sent_sky.x * 1.5,
		"light env: dirty-check skips unchanged sky uniforms and updates changed ones (kept %s, was %s -> %s)" % [kept_sentinel, sent_sky, updated_sky])
	remove_child(lk3)
	lk3.free()
	s3.queue_free()
	Looks.active = was_active
	# Looks.shader_for returns the base shader by default, and compiles #define SHADER_LIGHT_ENV under --light-env=shader.
	var ModelLib := preload("res://scripts/world/model_library.gd")
	var base_sh: Shader = ModelLib.FactorioShader
	var def_sh: Shader = Looks.shader_for(base_sh)
	var was_sle := Looks._shader_light_env
	Looks._shader_light_env = true
	Looks._env_shaders.clear()
	var env_sh: Shader = Looks.shader_for(base_sh)
	var env_mat := ShaderMaterial.new()
	env_mat.shader = env_sh
	var inc_pos := env_sh.code.find("#include ")
	var def_pos := env_sh.code.find("#define SHADER_LIGHT_ENV")
	Looks._shader_light_env = was_sle
	Looks._env_shaders.clear()
	check(def_sh == base_sh and env_sh != base_sh and def_pos >= 0 and inc_pos > def_pos,
		"light env: shader_for compiles out SHADER_LIGHT_ENV by default and injects it before #include when enabled")


## lighting-fixes step 4: the look's roughness floor on built-in packs and icon items only ("pbr" packs and modellers'
## items keep their files' roughness; --pbr-rough=floor as 0.2.2), the sun's full highlight in Cinematic, half in the
## Factorio look (--sun-specular wins).


func _pbr_rough(game_looks: Node, look_id: String) -> void:
	check(not Looks.pbr_rough_floor_switch(PackedStringArray()) and Looks.pbr_rough_floor_switch(PackedStringArray(["--pbr-rough=floor"]))
		and not Looks.pbr_rough_floor_switch(PackedStringArray(["--pbr-rough=floor", "--pbr-rough=own"])),
		"pbr rough: pbr packs keep their roughness by default, --pbr-rough=floor the look's floor on them too")
	check(is_equal_approx(Looks.sun_specular_arg(PackedStringArray()), -1.0) and is_equal_approx(Looks.sun_specular_arg(PackedStringArray(["--sun-specular=0.25"])), 0.25),
		"pbr rough: --sun-specular=<n> read, none by default")
	var was_look: String = game_looks.current
	var was_floor: bool = game_looks._pbr_rough_floor
	var s: DirectionalLight3D = game_looks.sun
	game_looks.use(look_id, true)
	game_looks.apply(0.0, 0.0, "nauvis", false)
	var floor_min := float(Looks.looks[look_id].get("roughness_min", 0.0))
	check(floor_min > 0.3 and game_looks.rough_put.is_equal_approx(Vector2(floor_min, 0.0)) and is_equal_approx(s.light_specular, 1.0),
		"pbr rough: under %s the floor on built-in packs only (%s), the sun's full highlight (%.2f)" % [look_id, game_looks.rough_put, s.light_specular])
	game_looks._pbr_rough_floor = true
	game_looks.apply(0.0, 0.0, "nauvis", false)
	check(game_looks.rough_put.is_equal_approx(Vector2(floor_min, floor_min)), "pbr rough: --pbr-rough=floor puts it on pbr packs too (%s)" % [game_looks.rough_put])
	game_looks._pbr_rough_floor = was_floor
	game_looks.use("factorio", true)
	game_looks.apply(0.0, 0.0, "nauvis", false)
	check(is_equal_approx(s.light_specular, 0.5), "pbr rough: the Factorio look's sun highlight at half (%.2f)" % s.light_specular)
	game_looks._sun_specular_arg = 0.25
	game_looks.apply(0.0, 0.0, "nauvis", false)
	check(is_equal_approx(s.light_specular, 0.25), "pbr rough: --sun-specular wins over the look (%.2f)" % s.light_specular)
	game_looks._sun_specular_arg = -1.0
	game_looks.use(was_look, true)
	var mat := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc")
	var items := FileAccess.get_file_as_string("res://shaders/item_pbr.gdshaderinc") + FileAccess.get_file_as_string("res://shaders/item_body.gdshaderinc")
	check(mat.contains("mp ? f3d_look_roughness_min_pbr : f3d_look_roughness_min") and items.contains("max(rm.x, f3d_look_roughness_min_pbr)")
		and items.contains("max(roughness, f3d_look_roughness_min)"),
		"pbr rough: buildings and items take the same floors (pbr's own, built-in's the look's)")


func _model_fill(game_looks: Node) -> void:
	var e: Environment = game_looks.env
	var s: DirectionalLight3D = game_looks.sun
	var was_tune := Looks.light_tune.duplicate()
	var was_pbr := Looks.pbr_tune.duplicate()
	var was_arg: float = game_looks._model_fill_arg
	var was_amb := e.ambient_light_energy
	var was_sun := s.light_energy
	var was_look: String = game_looks.current
	# Only L's model_fill is read here (apply() looks the look up by name): the Factorio look's 1.1.
	game_looks.current = "factorio"
	var look_fill := float(Looks.FACTORIO.get("model_fill", 0.0))
	check(is_zero_approx(Looks.model_fill_arg(PackedStringArray())) and is_equal_approx(Looks.model_fill_arg(PackedStringArray(["--model-fill=on"])), -1.0)
		and is_zero_approx(Looks.model_fill_arg(PackedStringArray(["--model-fill=on", "--model-fill=off"])))
		and is_equal_approx(Looks.model_fill_arg(PackedStringArray(["--model-fill=0.5"])), 0.5),
		"model fill: off by default, =on the look's (-1), =off none, a number that fill")
	var run := func(tune: Dictionary, fill_tune: Dictionary, arg: float, night: float) -> void:
		Looks.light_tune = tune
		Looks.pbr_tune = fill_tune
		game_looks._model_fill_arg = arg
		e.ambient_light_energy = was_amb
		s.light_energy = was_sun
		game_looks.apply(0.0, night, "nauvis", false)
	run.call({}, {}, 0.0, 0.0)
	var game_amb := e.ambient_light_energy
	check(is_zero_approx(game_looks.fill_put) and game_looks.sky_put.is_equal_approx(Vector2.ONE),
		"model fill: none by default, the sky untouched (%s, %s)" % [game_looks.fill_put, game_looks.sky_put])
	run.call({}, {}, -1.0, 0.0)
	var on_noon: float = game_looks.fill_put
	run.call({}, {}, -1.0, 0.5)
	check(look_fill > 0.0 and is_equal_approx(on_noon, look_fill) and is_equal_approx(game_looks.fill_put, look_fill * 0.5),
		"model fill: --model-fill=on the look's own %.2f, faded by night as before (%.3f, %.3f)" % [look_fill, on_noon, game_looks.fill_put])
	run.call({"sun_energy": 0.0, "ambient_energy": 0.0}, {}, -1.0, 0.0)
	check(is_zero_approx(game_looks.fill_put) and game_looks.sky_put.is_zero_approx(),
		"model fill: sun 0 and ambient 0 leave no fill even with =on, and a black sky (%s, %s)" % [game_looks.fill_put, game_looks.sky_put])
	run.call({}, {"model_fill": 0.7}, 0.0, 0.0)
	var slider: float = game_looks.fill_put
	run.call({"ambient_energy": game_amb * 0.5}, {"model_fill": 0.7}, 0.0, 0.0)
	check(is_equal_approx(slider, 0.7) and is_equal_approx(game_looks.fill_put, 0.35) and is_equal_approx(game_looks.sky_put.x, 0.5)
		and is_equal_approx(game_looks.sky_put.y, 1.0),
		"model fill: the Camera fill slider sets it from 0, halved with the ambient (%.3f, %.3f, %s)" % [slider, game_looks.fill_put, game_looks.sky_put])
	var sky_text := FileAccess.get_file_as_string("res://shaders/planet_sky.gdshader")
	check(sky_text.contains("col *= scene_light.x;") and sky_text.contains("sun_strength * scene_light.y"),
		"model fill: the sky's colour and sun follow the sliders (planet_sky scene_light)")
	var keys := []
	for l: Array in load("res://scripts/ui/factorio/debug_menu.gd").LIGHT:
		keys.append(l[0])
	check(keys.has("model_fill") and keys.has("pbr_fill"), "model fill: the Lighting tab has the Camera fill slider and keeps Fill share")
	Looks.light_tune = was_tune
	Looks.pbr_tune = was_pbr
	game_looks._model_fill_arg = was_arg
	game_looks.current = was_look
	e.ambient_light_energy = was_amb
	s.light_energy = was_sun
	game_looks.apply(0.0, 0.0, "nauvis", false)


## 0.2.2: packs' own shading (pack.json "shading": "pbr", model_packs.gd shading()): a "pbr" pack's
## pictures lit by the look's texture_light ((1, 1) by default, Cinematic too), on unless Settings > Graphics >
## Advanced > Packs' own shading says Factorio's everywhere or --pack-shading=factorio, which wins.


func _pack_shading(game_looks: Node, cinematic: String) -> void:
	var project_light = ProjectSettings.get_setting("shader_globals/f3d_look_texture_light", {})
	var project_on = ProjectSettings.get_setting("shader_globals/f3d_pack_shading", {})
	check(project_light is Dictionary and (project_light as Dictionary).get("value") == Vector2(1, 1)
		and project_on is Dictionary and is_equal_approx(float((project_on as Dictionary).get("value", -1.0)), 1.0),
		"pack shading: the menu and model preview draw a pbr pack as it says, tops and sides at 1 (project.godot): %s, %s" % [project_light, project_on])
	check(Looks.TEXTURE_LIGHT == Vector2(1, 1) and str(Settings.DEFAULTS["graphics"].get("pack_shading")) == "pack",
		"pack shading: as each pack says, and (1, 1), by default")
	var was = Settings.get_value("graphics", "pack_shading")
	Settings.set_value("graphics", "pack_shading", "pack")
	game_looks.settle(str(Settings.get_value("graphics", "look")))
	check(Looks.packs_shade and game_looks.texture_light(Looks.FACTORIO) == Vector2(1, 1)
		and game_looks.texture_light(Looks.looks[cinematic]) == Vector2(1, 1),
		"pack shading: on, and the Factorio and Cinematic looks light a pbr pack's tops as Godot does (1, 1)")
	check(game_looks.texture_light({"texture_light": Vector2(0.95, 0.8)}) == Vector2(0.95, 0.8)
		and game_looks.texture_light({"texture_light": "x"}) == Vector2(1, 1),
		"pack shading: a look's own texture_light is used (a wrong type left out)")
	game_looks.apply(0.0, 0.0, "nauvis", false)
	check(_global_is(&"f3d_pack_shading", 1.0) and Looks.light_now == Vector2(1, 1), "pack shading: on in the shader's global")
	Settings.set_value("graphics", "pack_shading", "factorio")
	game_looks.settle(str(Settings.get_value("graphics", "look")))
	check(not Looks.packs_shade and _global_is(&"f3d_pack_shading", 0.0),
		"pack shading: Settings' Factorio's everywhere turns it off through settle()")
	check(Looks.pack_shading_arg(PackedStringArray(["--pack-shading=factorio"])) == "factorio"
		and Looks.pack_shading_arg(PackedStringArray(["--x", "--pack-shading=pack"])) == "pack"
		and Looks.pack_shading_arg(PackedStringArray(["--look=classic"])) == "",
		"pack shading: --pack-shading=factorio and =pack read; none without")
	check(Settings.ssao_arg(PackedStringArray(["--ssao=off"])) == "off" and Settings.ssao_arg(PackedStringArray(["--x", "--ssao=on"])) == "on"
		and Settings.ssao_arg(PackedStringArray(["--look=classic"])) == "",
		"ssao: --ssao=off and =on read; none without")
	check(Looks.pack_shading(PackedStringArray(["--pack-shading=pack"])) and not Looks.pack_shading(PackedStringArray()),
		"pack shading: the command line wins over Settings' Factorio's")
	Settings.set_value("graphics", "pack_shading", "pack")
	check(not Looks.pack_shading(PackedStringArray(["--pack-shading=factorio"])) and Looks.pack_shading(PackedStringArray()),
		"pack shading: --pack-shading=factorio wins over Settings' default")
	# In the menu, before any game (no Looks node to settle it): main.gd's settings listener puts the setting
	# in the global, so the model preview follows it (it stayed at project.godot's 1 till the first game).
	var menu: Node = (load("res://scripts/main.gd") as GDScript).new()
	var heard := Callable(menu, "_on_setting_changed")
	Settings.listen(heard)
	Looks.packs_shade = true
	RenderingServer.global_shader_parameter_set(&"f3d_pack_shading", 1.0)
	Settings.set_value("graphics", "pack_shading", "factorio")
	check(menu.get("_game") == null and not Looks.packs_shade and _global_is(&"f3d_pack_shading", 0.0),
		"pack shading: Factorio's everywhere set in the menu (no game, no Looks) puts f3d_pack_shading at 0")
	Settings.set_value("graphics", "pack_shading", "pack")
	check(Looks.packs_shade and _global_is(&"f3d_pack_shading", 1.0), "pack shading: and back on in the menu")
	Settings.unlisten(heard)
	menu.free()
	Settings.set_value("graphics", "pack_shading", was)
	game_looks.settle(str(Settings.get_value("graphics", "look")))


func _sun_model() -> void:
	check(PlanetSky.darkness_at(0.2) == 0.0 and PlanetSky.darkness_at(0.25) == 0.0 and is_equal_approx(PlanetSky.darkness_at(0.35), 0.425)
		and is_equal_approx(PlanetSky.darkness_at(0.45), 0.85) and is_equal_approx(PlanetSky.darkness_at(0.5), 0.85)
		and is_equal_approx(PlanetSky.darkness_at(0.65), 0.425) and PlanetSky.darkness_at(0.75) == 0.0,
		"sun: --sky=@daytime's darkness is Factorio's ramp")
	check(is_equal_approx(PlanetSky.sun_elevation(0.0, 0.0), PlanetSky.E_NOON) and is_equal_approx(PlanetSky.sun_elevation(0.25, 0.0), PlanetSky.E_DUSK)
		and is_equal_approx(PlanetSky.sun_elevation(0.5, 1.0), PlanetSky.E_SET), "sun: high at noon, low at dusk, under the horizon at night")
	check(PlanetSky.sun_elevation(0.38, 0.65) > 0.0 and PlanetSky.sun_elevation(0.4, 0.75) < 0.0, "sun: it crosses the horizon about 0.7 of the way into the night")
	var west := PlanetSky._towards(0.0, PlanetSky.sun_yaw(0.0, false))
	var east := PlanetSky._towards(0.0, PlanetSky.sun_yaw(0.0, true))
	check(west.x < -0.9 and west.z < 0.0 and east.x > 0.9, "sun: sets west with a little north, rises east: %s %s" % [west, east])
	check(is_equal_approx(PlanetSky.sun_yaw(PlanetSky.E_NOON, false), PlanetSky.sun_yaw(PlanetSky.E_NOON, true)), "sun: the same place at noon coming and going")
	# A look's noon in the north-west (sun_noon_yaw, cinematic-pbr-flat): the same rise and set, each the short way
	# round, so the morning crosses the north, never the south behind the view.
	var nw := -135.0
	var rise_nw := PlanetSky._towards(0.0, PlanetSky.sun_yaw(0.0, true, nw))
	var set_nw := PlanetSky._towards(0.0, PlanetSky.sun_yaw(0.0, false, nw))
	var morning_nw := PlanetSky._towards(30.0, PlanetSky.sun_yaw(30.0, true, nw))
	var noon_nw := PlanetSky._towards(PlanetSky.E_NOON, PlanetSky.sun_yaw(PlanetSky.E_NOON, true, nw))
	check(rise_nw.is_equal_approx(east) and set_nw.is_equal_approx(west) and morning_nw.z < 0.0 and noon_nw.x < 0.0 and noon_nw.z < 0.0,
		"sun: a noon in the north-west rises and sets as before, crossing the north (rise %s, set %s, morning %s, noon %s)" % [rise_nw, set_nw, morning_nw, noon_nw])
	var m_nw := PlanetSky.sun_model(PlanetSky.PLANETS["nauvis"], 0.0, 0.0, nw)
	check(is_equal_approx(float(m_nw["light_yaw"]), nw) and is_equal_approx(float(PlanetSky.sun_model(PlanetSky.PLANETS["nauvis"], 0.0, 0.0)["light_yaw"]), PlanetSky.YAW_NOON),
		"sun: the sun model's noon where the look asks, Zenith's own without")
	# The sun that never sets (a look with no twilight, or Cinematic's sunset slider at 0) takes the noon side too.
	var nw_sky := PlanetSky.new()
	add_child(nw_sky)
	var nw_sun := DirectionalLight3D.new()
	add_child(nw_sun)
	var nw_env := Environment.new()
	nw_sky.twilight = 0.0
	nw_sky.apply(nw_env, nw_sun, 0.0, 0.0, 0.0, false)
	var old_yaw := nw_sun.rotation_degrees.y
	nw_sky.noon_yaw = nw
	nw_sky.apply(nw_env, nw_sun, 0.0, 0.0, 0.0, false)
	check(is_equal_approx(old_yaw, PlanetSky.YAW_NOON) and is_equal_approx(nw_sun.rotation_degrees.y, nw),
		"sun: the sun that never sets at noon where the look asks, Zenith's own without (%s, %s)" % [old_yaw, nw_sun.rotation_degrees.y])
	nw_sky.queue_free()
	nw_sun.queue_free()
	var scatter: Color = PlanetSky.PLANETS["nauvis"]["twilight"]["scatter"]
	var noon := PlanetSky.sun_tint(scatter, PlanetSky.E_NOON)
	var gold := PlanetSky.sun_tint(scatter, 12.0)
	var red := PlanetSky.sun_tint(scatter, 0.0)
	check(noon.is_equal_approx(Color.WHITE), "sun: white at noon")
	check(gold.r > gold.g and gold.g > gold.b and gold.g > 0.55, "sun: gold 12 degrees up: %s" % gold)
	check(red.g < 0.2 and red.b < 0.05, "sun: deep red at the horizon: %s" % red)
	check(PlanetSky.twilight_at(PlanetSky.E_NOON) == 0.0 and PlanetSky.twilight_at(PlanetSky.E_SET) == 0.0 and PlanetSky.twilight_at(3.0) > 0.9, "sun: twilight peaks with the sun at the horizon")
	for planet: String in PlanetSky.PLANETS:
		var p: Dictionary = PlanetSky.PLANETS[planet]
		var at_noon := PlanetSky.sun_model(p, 0.0, 0.0)
		check((at_noon["light_color"] as Color).is_equal_approx(p["sun"][0]) and (at_noon["ambient"] as Color).is_equal_approx(p["ambient"][0])
			and is_equal_approx(float(at_noon["light_energy"]), float(p["sun_energy"][0])), "sun: %s at noon is the planet's day" % planet)
		var prev := {}
		var pops := 0
		var floors := 0
		for i in 2000:
			var d := float(i) / 2000.0
			var m := PlanetSky.sun_model(p, d, PlanetSky.darkness_at(d) / PlanetSky.FULL_DARKNESS)
			if float(m["elevation"]) >= -1.0 and float(m["light_pitch"]) < PlanetSky.LIGHT_FLOOR:
				floors += 1
			if not prev.is_empty():
				var moved := absf(wrapf(float(m["light_yaw"]) - float(prev["light_yaw"]), -180.0, 180.0))
				if moved > 15.0 and maxf(float(m["light_energy"]), float(prev["light_energy"])) > 0.001:
					pops += 1
				if absf(float(m["ambient_energy"]) - float(prev["ambient_energy"])) > 0.08:
					pops += 1
			prev = m
		check(pops == 0, "sun: %s through a whole day: no jump in the light while it shines (%d)" % [planet, pops])
		check(floors == 0, "sun: %s: the light never lower than its floor" % planet)
	var at := PlanetSky.sun_model(PlanetSky.PLANETS["gleba"], 0.34, 0.45)
	var dawn := PlanetSky.sun_model(PlanetSky.PLANETS["gleba"], 0.66, 0.45)
	check((at["sun_color"] as Color).r > (at["sun_color"] as Color).g and (dawn["sun_color"] as Color).g > (dawn["sun_color"] as Color).r,
		"sun: Gleba's dusk is rose and its dawn green: %s %s" % [at["sun_color"], dawn["sun_color"]])
	check(PlanetSky.water_tint(Color(0.7, 0.8, 0.88), Color(0.7, 0.8, 0.88)).is_equal_approx(PlanetSky.WATER_SKY), "water: by day its tint is as it was")
	var cold := PlanetSky.water_tint(Color(0.05, 0.07, 0.12), Color(0.7, 0.8, 0.88))
	check(cold.b > PlanetSky.WATER_SKY.b and absf(cold.get_luminance() - PlanetSky.WATER_SKY.get_luminance()) < 0.08, "water: at night it follows the sky's colour, not its darkness: %s" % cold)
	var points: Array = []
	for u in 500:
		points.append(LampLights.on_at(u + 1000))
	check(points.min() >= LampLights.ON_DARKNESS and points.max() <= LampLights.ALL_ON_DARKNESS and points.max() - points.min() > 0.18
		and LampLights.on_at(1234) == LampLights.on_at(1234), "lamps: each comes on at its own point between 0.3 and 0.5")


## A look's sunrise and sunset (1.5): twilight for sky.gd, at_twilight and at_dawn blended by the sun,
## the pass's sun uniforms, api.shaders.sun(), and the light left as it was without one.


func _sunset_look(api) -> void:
	var sh = api.shaders
	var env := Environment.new()
	var sun := DirectionalLight3D.new()
	var looks := Looks.new()
	var sky := PlanetSky.new()
	add_child(sun)
	add_child(looks)
	add_child(sky)
	looks.attach(env, sun)
	sky.set_planet("nauvis")
	check(looks.twilight() == 0.0 and looks.sky_twilight() > 0.0 and looks.sky_twilight() < 1.0, "sunset: the Factorio look has none on the ground and a restrained one in its sky")
	sky.twilight = 0.0
	sky.sky_twilight = 0.0
	sky.apply(env, sun, 0.35, 0.5, 0.016, false)
	var high := clampf(cos(TAU * 0.35) * 0.5 + 0.5, 0.0, 1.0)
	check(is_equal_approx(sun.rotation_degrees.x, -lerpf(20.0, 60.0, high)) and is_equal_approx(sun.light_energy, lerpf(1.1, 0.12, 0.5))
		and sun.light_color.is_equal_approx(Color(1.0, 0.97, 0.92).lerp(Color(0.6, 0.68, 0.95), 0.5)), "sunset: at twilight 0 the sun is the old one")
	var ok: bool = sh.add_look("test-addon/dusk", {"name": "Dusk", "twilight": 0.8, "exposure": 1.0,
		"environment": {"fog_density": 0.01},
		"sun": {"shadow_opacity": 1.0},
		"at_twilight": {"environment": {"tonemap_exposure": 2.0, "fog_density": 0.02}, "sun": {"shadow_opacity": 0.5}, "params": {"strength": 1.0}},
		"at_dawn": {"environment": {"fog_height": 3.0, "fog_density": 0.04}},
		"fog_from_sky": 1.0,
		"passes": [{"shader": "grey.gdshader", "params": {"strength": 0.2}}]})
	check(ok, "sunset: an add-on's look with a sunset")
	looks.use("test-addon/dusk")
	var pass_node: MeshInstance3D = looks.get_children().filter(func(n: Node) -> bool: return n is MeshInstance3D)[0]
	var m := pass_node.material_override as ShaderMaterial
	check(is_equal_approx(looks.twilight(), 0.8) and is_equal_approx(looks.sky_twilight(), 0.8), "sunset: sky_twilight follows twilight when not given")
	var fog_before := env.fog_light_color
	looks.apply(0.0, 0.0, "nauvis", false, {"elevation": 60.0, "height": 0.87, "twilight": 0.0, "morning": false, "direction": Vector3.UP, "color": Color.WHITE, "ambient": Color.GRAY, "fog": Color.RED})
	check(is_equal_approx(env.tonemap_exposure, 1.0) and is_equal_approx(env.fog_density, 0.01) and is_equal_approx(sun.shadow_opacity, 1.0)
		and is_equal_approx(float(m.get_shader_parameter("strength")), 0.2) and env.fog_light_color.is_equal_approx(fog_before), "sunset: at noon the look's own values")
	looks.apply(0.35, 0.5, "nauvis", false, {"elevation": 3.0, "height": 0.05, "twilight": 0.5, "morning": false, "direction": Vector3.LEFT, "color": Color.ORANGE, "ambient": Color.BLUE, "fog": Color.RED})
	check(is_equal_approx(env.tonemap_exposure, 1.5) and is_equal_approx(env.fog_density, 0.015) and is_equal_approx(sun.shadow_opacity, 0.75)
		and is_equal_approx(float(m.get_shader_parameter("strength")), 0.6), "sunset: at_twilight is blended by how low the sun is")
	check(env.fog_light_color.is_equal_approx(fog_before.lerp(Color.RED, 0.5)), "sunset: the fog takes the sky's colour")
	check(is_equal_approx(float(m.get_shader_parameter("look_twilight")), 0.5) and is_equal_approx(float(m.get_shader_parameter("look_sun_height")), 0.05)
		and (m.get_shader_parameter("look_sun_dir") as Vector3).is_equal_approx(Vector3.LEFT) and (m.get_shader_parameter("look_sun_color") as Color).is_equal_approx(Color.ORANGE)
		and float(m.get_shader_parameter("look_morning")) == 0.0, "sunset: passes are given the sun")
	looks.apply(0.35, 0.5, "", true, {"elevation": 3.0, "height": 0.05, "twilight": 0.5, "morning": false, "direction": Vector3.LEFT, "color": Color.ORANGE, "ambient": Color.BLUE, "fog": Color.RED})
	var in_space := float(m.get_shader_parameter("look_space"))
	looks.apply(0.35, 0.5, "nauvis", false, {"elevation": 3.0, "height": 0.05, "twilight": 0.5, "morning": false, "direction": Vector3.LEFT, "color": Color.ORANGE, "ambient": Color.BLUE, "fog": Color.RED})
	check(in_space == 1.0 and float(m.get_shader_parameter("look_space")) == 0.0,
		"passes are told when the view is on a space platform (look_space: the Cinematic clouds stay off there)")
	looks.apply(0.65, 0.5, "nauvis", false, {"elevation": 3.0, "height": 0.05, "twilight": 1.0, "morning": true, "direction": Vector3.RIGHT, "color": Color.ORANGE, "ambient": Color.BLUE, "fog": Color.RED})
	check(is_equal_approx(env.fog_density, 0.04) and is_equal_approx(env.fog_height, 3.0) and is_equal_approx(env.tonemap_exposure, 2.0) and float(m.get_shader_parameter("look_morning")) == 1.0,
		"sunset: at_dawn in the morning, over at_twilight's")
	looks.apply(0.45, 0.5, "nauvis", false, {"elevation": 3.0, "height": 0.05, "twilight": 1.0, "morning": false, "direction": Vector3.RIGHT, "color": Color.ORANGE, "ambient": Color.BLUE, "fog": Color.RED})
	check(is_equal_approx(env.fog_height, 0.0), "sunset: a dawn-only value has nothing to go to at dusk")
	var from_api: Dictionary = sh.sun()
	check(is_equal_approx(float(from_api.get("twilight", -1.0)), 1.0) and from_api.get("morning") == false, "sunset: api.shaders.sun() says where the sun is")
	sky.twilight = 1.0
	sky.sky_twilight = 1.0
	sky.apply(env, sun, 0.34, 0.45, 0.016, true)
	check(sky.state["twilight"] == 0.0, "sunset: no dusk on a space platform")
	sky.apply(env, sun, 0.34, 0.45, 0.016, false)
	check(sky.state["twilight"] > 0.5 and sun.light_color.r > sun.light_color.b * 1.5 and is_equal_approx(sun.rotation_degrees.x, -PlanetSky.LIGHT_FLOOR),
		"sunset: at dusk the light is warm and held at its floor: %s %s" % [sun.light_color, sun.rotation_degrees])
	looks.use("classic")
	check(is_equal_approx(env.fog_density, Environment.new().fog_density) and is_equal_approx(env.tonemap_exposure, 1.0) and is_equal_approx(env.fog_height, 0.0),
		"sunset: another look puts everything the sunset moved back")
	sh.remove_look("test-addon/dusk")
	sky.queue_free()
	looks.queue_free()
	sun.queue_free()
	await get_tree().process_frame


## api.shaders (1.3): an add-on's look in the Look setting's list, put on a scene's environment and
## sun (tonemapping, the light's multipliers, the held sun, environment and sun properties, its pass
## from the add-on's folder), a pass over every look, and all of it gone again with the add-on.


func _shaders(api) -> void:
	var sh = api.shaders
	var ids: Array = sh.looks().map(func(c: Array) -> String: return str(c[1]))
	check(ids.has("factorio") and ids.has("classic"), "shaders: Zenith's Factorio and Classic looks are listed: %s" % [ids])
	var env := Environment.new()
	var sun := DirectionalLight3D.new()
	var looks := Looks.new()
	add_child(sun)
	add_child(looks)
	looks.attach(env, sun)
	check(looks.current == "factorio" and env.tonemap_mode == Environment.TONE_MAPPER_LINEAR, "shaders: the Factorio look is on by default, linear tonemapping")
	looks.apply(0.0, 0.0, "nauvis", false)
	var held := sun.rotation_degrees
	check(is_equal_approx(held.x, Looks.FACTORIO["sun_angle"].x) and is_equal_approx(held.y, Looks.FACTORIO["sun_angle"].y), "shaders: Factorio's look holds the sun where Factorio's shadows fall: %s" % [held])
	var ok: bool = sh.add_look("test-addon/grey", {"name": "Grey", "tonemap": Environment.TONE_MAPPER_AGX, "exposure": 1.3,
		"sun_energy": 2.0, "environment": {"glow_enabled": true, "ssao_enabled": true}, "sun": {"light_angular_distance": 1.5, "light_energy": 9.0},
		"passes": [{"shader": "grey.gdshader", "params": {"strength": 0.25}}]})
	check(ok and sh.looks().any(func(c: Array) -> bool: return c[1] == "test-addon/grey"), "shaders: an add-on's look joins the list")
	check(not Looks.register("test-addon/grey", {}, "someone-else") and not sh.add_look("classic", {}), "shaders: nobody else's look can be replaced, nor Zenith's")
	looks.use("test-addon/grey")
	sun.light_energy = 1.0
	looks.apply(0.0, 0.0, "nauvis", false)
	var passes := looks.get_children().filter(func(n: Node) -> bool: return n is MeshInstance3D)
	check(env.tonemap_mode == Environment.TONE_MAPPER_AGX and is_equal_approx(env.tonemap_exposure, 1.3) and env.glow_enabled and env.ssao_enabled,
		"shaders: the look's tonemapping and environment are on")
	check(is_equal_approx(sun.light_energy, 2.0) and is_equal_approx(sun.light_angular_distance, 1.5), "shaders: its sun: the light doubled, soft shadows: %s %s" % [sun.light_energy, sun.light_angular_distance])
	check(passes.size() == 1 and is_equal_approx(float((passes[0].material_override as ShaderMaterial).get_shader_parameter("strength")), 0.25),
		"shaders: its pass from the add-on's folder, with its uniform: %d" % passes.size())
	sh.set_parameter(0, "strength", 0.75)
	check(passes.size() == 1 and is_equal_approx(float((passes[0].material_override as ShaderMaterial).get_shader_parameter("strength")), 0.75), "shaders: set_parameter(0) reaches the look's pass")
	var pid: int = sh.add_pass("grey.gdshader", {"strength": 0.5})
	check(pid > 0 and looks.get_children().filter(func(n: Node) -> bool: return n is MeshInstance3D).size() == 2, "shaders: a pass over every look is drawn too")
	check(sh.add_pass("res://shaders/no-such.gdshader") == 0, "shaders: a missing shader isn't a pass")
	looks.use("classic")
	await get_tree().process_frame
	check(not env.glow_enabled and not env.ssao_enabled and env.tonemap_mode == Environment.TONE_MAPPER_FILMIC and is_equal_approx(sun.light_angular_distance, 0.0),
		"shaders: another look puts the environment and sun back")
	# Zenith's shadows own the sun's size: a look's light_angular_distance reaches the sun through them,
	# with Godot's contact-hardening shadows (PCSS) as it asked.
	var fitter := SunShadows.new()
	fitter.sun = sun
	add_child(fitter)
	fitter.set_process(false)
	looks.shadows = fitter
	looks.use("test-addon/grey")
	check(is_equal_approx(fitter.sun_size, 1.5) and is_equal_approx(sun.light_angular_distance, 1.5) and is_equal_approx(sun.shadow_blur, 1.0)
		and is_equal_approx(sun.directional_shadow_pancake_size, SunShadows.pcss_pancake),
		"shaders: a look's own sun size still gives soft shadows through Zenith's shadows (size, blur, pancake): %s %s %s" % [sun.light_angular_distance, sun.shadow_blur, sun.directional_shadow_pancake_size])
	looks.use("classic")
	check(is_equal_approx(sun.light_angular_distance, 0.0) and is_equal_approx(sun.directional_shadow_pancake_size, SunShadows.PANCAKE) and is_equal_approx(fitter.edge, SunShadows.EDGE),
		"shaders: another look takes the sun size off again")
	looks.shadows = null
	fitter.queue_free()
	check(looks.get_children().filter(func(n: Node) -> bool: return n is MeshInstance3D and not n.is_queued_for_deletion()).size() == 1, "shaders: only the pass over every look is left")
	# A setting changed while the look is on is what comes back when the look goes.
	looks.use("test-addon/grey")
	looks.lift()
	check(not env.ssao_enabled, "shaders: lifted, the look's own values are off while Settings writes")
	env.ssao_enabled = true
	looks.settle("test-addon/grey")
	looks.use("classic")
	check(env.ssao_enabled, "shaders: a setting changed under a look comes back when the look goes")
	env.ssao_enabled = false
	looks.use("test-addon/grey")
	sh.clear()
	await get_tree().process_frame
	check(not Looks.looks.has("test-addon/grey") and looks.current == "factorio" and Looks.extras.is_empty()
		and looks.get_children().filter(func(n: Node) -> bool: return n is MeshInstance3D and not n.is_queued_for_deletion()).is_empty(),
		"shaders: switched off, the add-on's look and passes go and the Factorio look comes back")
	looks.queue_free()
	sun.queue_free()


## api.terrain (1.2): the height field (set, read between texels, its square, cleared, and only by
## the add-on that set it), and what the Terrain Elevation add-on reads of the world: tile kinds,
## cliffs, buildings (turned, without trees or units) and the chunks whose buildings changed.
## api.sound (1.7): an add-on's own sounds on a bus (a file from its folder, numbered variations), Zenith's
## sounds by kind replaced and muted, two add-ons stacked, the stop putting the one before back, the
## played signal, --addon-sounds=off, each call site naming its kind, and nothing kept while no add-on
## uses it. Under the Dummy driver: sfx.gd's voices and tables, not what is heard. The files are the
## test's own tones (sound_fixtures.gd).
