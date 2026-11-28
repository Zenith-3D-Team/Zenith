extends SceneTree
## Headless unit + micro-benchmark test for SpriteFx and WeaponFx performance optimizations (`--fx-opt`).
## Run:
##   godot --headless --audio-driver Dummy --path client --log-file <abs-log> -s res://tests/weapon_fx_perf_test.gd

const SpriteFx := preload("res://scripts/fx/sprite_fx.gd")
const WeaponFx := preload("res://scripts/fx/weapon_fx.gd")
const MomentHold := preload("res://scripts/world/moment_hold.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const Switches := preload("res://scripts/switches.gd")

var passes := 0
var fails := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(cond: bool, msg: String) -> void:
	if cond:
		passes += 1
	else:
		fails += 1
		print("FAIL: %s" % msg)


func _run() -> void:
	var saved_fx_opt_sprite := SpriteFx.fx_opt
	var saved_fx_opt_weapon := WeaponFx.fx_opt
	var saved_hold := MomentHold.on

	_test_sprite_fx_api_and_lifecycle()
	await _test_weapon_fx_culling_parity()
	await _bench_sprite_fx_1200_cards()
	await _bench_weapon_fx_200_projectiles()

	SpriteFx.fx_opt = saved_fx_opt_sprite
	WeaponFx.fx_opt = saved_fx_opt_weapon
	MomentHold.on = saved_hold
	GroundHeight.clear()

	print("weapon_fx_perf_test: %d passed, %d failed" % [passes, fails])
	print("FAILS: %d" % fails)
	quit(1 if fails > 0 else 0)


func _test_sprite_fx_api_and_lifecycle() -> void:
	SpriteFx.fx_opt = true
	MomentHold.on = false
	var sprites := SpriteFx.new()
	root.add_child(sprites)

	_check(sprites.emit("nonexistent-sheet", Vector3.ZERO, 1.0, 1.0) == null,
		"emit returns null for unknown sheet")
	_check(sprites.count() == 0, "initial count is 0")

	# Card field tweakability + buffer reflection.
	var c := sprites.emit("smoke", Vector3(1.0, 2.0, 3.0), 1.5, 2.0, Color(0.8, 0.6, 0.4, 1.0))
	_check(c != null, "emit returns Card handle")
	c.vel = Vector3(2.0, 0.0, -4.0)
	c.rise = 4.0
	c.drag = 0.5
	c.spin_rate = 1.5
	c.size1 = 3.5
	c.fps = 20.0
	c.frame = 3.0
	c.angle = 0.75
	sprites._process(0.5)

	var pool = sprites._pools["smoke"]
	_check(pool.cards.size() == 1 and pool.shown == 1 and pool.mm.visible_instance_count == 1,
		"after 0.5s process: card alive and shown in MultiMesh")
	_check(is_equal_approx(c.age, 0.5), "card age advanced by delta")
	_check(c.pos.x > 1.5 and c.pos.y > 2.0 and c.pos.z < 2.0, "card velocity and rise updated pos")
	_check(is_equal_approx(c.spin, 0.75), "card spin_rate updated spin")
	var buf: PackedFloat32Array = pool.buffer
	_check(is_equal_approx(buf[3], c.pos.x) and is_equal_approx(buf[7], c.pos.y) and is_equal_approx(buf[11], c.pos.z),
		"MultiMesh buffer pos matches Card.pos")
	_check(is_equal_approx(buf[18], c.spin), "MultiMesh buffer spin matches Card.spin")
	_check(buf[0] > 1.5 and buf[0] < 3.0, "MultiMesh buffer width interpolated between size0 and size1")

	# Flat decal angle + buffer check.
	var decal := sprites.emit("scorch", Vector3(5.0, 0.03, 6.0), 2.0, 10.0)
	decal.angle = 1.2
	sprites._process(0.016)
	var scorch_pool = sprites._pools["scorch"]
	_check(scorch_pool.shown == 1 and is_equal_approx(scorch_pool.buffer[0], cos(1.2) * 2.0),
		"flat decal writes rotated matrix into MultiMesh buffer")

	# kill() expires card immediately on next _process.
	sprites.kill(c)
	sprites._process(0.016)
	_check(pool.cards.is_empty() and pool.shown == 0 and pool.mm.visible_instance_count == 0,
		"kill() removes card and resets visible_instance_count to 0")

	# MomentHold skip & dirty wakeup on emit/kill.
	var held_card := sprites.emit("dust", Vector3(2.0, 1.0, 2.0), 1.0, 2.0)
	sprites._process(0.1)
	MomentHold.on = true
	var age_before := held_card.age
	sprites._process(0.5)
	_check(is_equal_approx(held_card.age, age_before), "MomentHold freezes card age")
	var held_card2 := sprites.emit("dust", Vector3(3.0, 1.0, 3.0), 1.0, 2.0)
	sprites._process(0.5)
	var dust_pool = sprites._pools["dust"]
	_check(dust_pool.shown == 2, "MomentHold still updates buffer when a new card is emitted")
	sprites.kill(held_card2)
	sprites._process(0.5)
	_check(dust_pool.shown == 1, "MomentHold still updates buffer when a card is killed")
	MomentHold.on = false

	# Capacity overwrite (O(1) cursor) and swap-and-pop expiry.
	sprites.clear()
	_check(sprites.count() == 0 and dust_pool.shown == 0, "clear() empties all pools")
	for i in range(450):
		var sc := sprites.emit("smoke", Vector3(float(i), 0.5, 0.0), 1.0, 1.0 if i % 2 == 0 else 5.0)
		if sc != null and i % 2 == 0:
			sc.age = 0.9
	_check(sprites.count() == 400, "capacity cap enforced at 400 with O(1) cursor overwrite")
	sprites._process(0.2)
	_check(sprites.count() < 400 and sprites.count() > 0, "swap-and-pop expires partial batch cleanly")

	# Clear again and verify legacy capacity overwrite (--fx-opt=off).
	sprites.clear()
	SpriteFx.fx_opt = false
	for i in range(420):
		sprites.emit("smoke", Vector3(float(i), 0.5, 0.0), 1.0, 5.0)
	_check(sprites.count() == 400, "legacy capacity cap enforced at 400")

	SpriteFx.fx_opt = true
	sprites.queue_free()


func _ensure_synthetic_pools(sprites: SpriteFx, wf: WeaponFx) -> void:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 1.0, 1.0, 0.8))
	var tex := ImageTexture.create_from_image(img)
	# Register synthetic pools for every layer referenced by rocket / flamethrower / laser / smoke-fast / fire-flame.
	for pname in ["rocket", "explosive-rocket"]:
		var pr: Dictionary = wf.data.get("pr", {}).get(pname, {})
		for layers in pr.get("a", []).slice(0, 1):
			for layer: Array in layers:
				_force_pool(sprites, wf, layer, true, false, 256, 0.0, 0.0, tex)
	for sname in ["smoke-fast", "soft-fire-smoke"]:
		var ts: Dictionary = wf.data.get("ts", {}).get(sname, {})
		var dur := maxf(float(ts.get("dur", 60)), 1.0)
		for v in ts.get("a", []):
			if v is Array and not v.is_empty() and v[0] is Array:
				_force_pool(sprites, wf, v[0], true, false, 400, 0.0, clampf(float(ts.get("fade", 0)) / dur, 0.1, 0.9), tex)
	for stname in ["flamethrower-fire-stream", "acid-stream-spitter-small"]:
		var st: Dictionary = wf.data.get("st", {}).get(stname, {})
		for v in st.get("p", []).slice(0, 1):
			if v is Array and not v.is_empty() and v[0] is Array:
				_force_pool(sprites, wf, v[0], true, false, 512, 0.0, 0.0, tex)
	var beam: Dictionary = wf.data.get("bm", {}).get("laser-beam", {})
	for part in ["start", "head", "body", "tail", "ending"]:
		for v in beam.get(part, []):
			if v is Array and not v.is_empty() and v[0] is Array:
				_force_pool(sprites, wf, v[0], true, false, 256, 0.0, 0.0, tex)


func _force_pool(sprites: SpriteFx, wf: WeaponFx, layer: Array, cyclic: bool, flat: bool, capacity: int,
		fade_in: float, fade_out: float, tex: Texture2D) -> void:
	var key := "%s@%s:%dx%d:%d%s%s" % [str(layer[0]), str(layer[10]), int(layer[1]), int(layer[2]), int(layer[3]),
		"c" if cyclic else "", "f" if flat else ""]
	if not sprites.has_pool(key):
		sprites.add_pool(key, tex, Vector2.ONE, maxi(int(layer[3]), 1), float(layer[2]) / maxf(float(layer[1]), 1.0),
			int(layer[8]) == 1, cyclic, flat, capacity, int(layer[11]) == 1, fade_in, fade_out)
	wf._pools[key] = key


func _make_camera(holder: Node3D) -> Camera3D:
	var cam := Camera3D.new()
	cam.fov = 50.0
	cam.near = 0.5
	cam.far = 400.0
	holder.add_child(cam)
	cam.global_position = Vector3(0.0, 23.0, 19.3)
	cam.look_at(Vector3.ZERO, Vector3.UP)
	cam.current = true
	return cam


func _test_weapon_fx_culling_parity() -> void:
	var holder := Node3D.new()
	root.add_child(holder)
	_make_camera(holder)
	var sprites := SpriteFx.new()
	holder.add_child(sprites)
	var wf := WeaponFx.new()
	wf.sprites = sprites
	holder.add_child(wf)
	await process_frame
	_ensure_synthetic_pools(sprites, wf)

	# 1. Near on-screen rocket: trail count must match between fx_opt off and on.
	var counts := []
	for opt_val: bool in [false, true]:
		SpriteFx.fx_opt = opt_val
		WeaponFx.fx_opt = opt_val
		wf.reset()
		sprites.clear()
		var p: Array = [101, "rocket", 0, 0]
		wf.handle({"t": "pj", "k": 100, "p": p, "b": [], "x": [], "e": []})
		for f in range(15):
			wf.handle({"t": "pj", "k": 100 + (f + 1) * 2, "p": [101, "rocket", (f + 1) * 128, 0], "b": [], "x": [], "e": []})
			wf._process(1.0 / 60.0)
			sprites._process(1.0 / 60.0)
		counts.append(sprites.count())
	_check(counts[0] == counts[1] and counts[0] > 1,
		"near on-screen projectile trail parity: off=%d, on=%d" % [counts[0], counts[1]])

	# 2. Off-screen rocket (far behind camera at z = +200): culled when fx_opt is on.
	SpriteFx.fx_opt = true
	WeaponFx.fx_opt = true
	wf.reset()
	sprites.clear()
	wf.handle({"t": "pj", "k": 200, "p": [201, "rocket", 0, 200 * 256], "b": [], "x": [], "e": []})
	var rocket_layers: int = wf._flying[201].cards.size()
	for f in range(15):
		wf.handle({"t": "pj", "k": 200 + (f + 1) * 2, "p": [201, "rocket", (f + 1) * 64, 200 * 256], "b": [], "x": [], "e": []})
		wf._process(1.0 / 60.0)
		sprites._process(1.0 / 60.0)
	_check(rocket_layers > 0 and sprites.count() == rocket_layers,
		"off-screen rocket emits 0 smoke trail cards (only rocket's own %d cards: %d)" % [rocket_layers, sprites.count()])

	holder.queue_free()
	await process_frame


func _bench_sprite_fx_1200_cards() -> void:
	var holder := Node3D.new()
	root.add_child(holder)
	var sprites := SpriteFx.new()
	holder.add_child(sprites)
	await process_frame

	var counts_per_sheet := [
		["smoke", 400],
		["flame-stream", 400],
		["dust", 160],
		["bullet-hit", 96],
		["sparks", 64],
		["hit", 48],
		["small-explosion", 32],
	]
	var results := {}
	for opt_val: bool in [false, true]:
		SpriteFx.fx_opt = opt_val
		sprites.clear()
		var idx := 0
		for pair: Array in counts_per_sheet:
			var sh: String = pair[0]
			var cnt: int = int(pair[1])
			for j in range(cnt):
				var c := sprites.emit(sh, Vector3(float(idx % 40) - 20.0, 0.8, float(idx / 40) - 15.0), 1.0, 10.0)
				if c != null:
					c.vel = Vector3(0.2, 0.3, -0.1)
					c.rise = 0.05
					c.drag = 0.1
					c.spin_rate = 0.4
					c.size1 = 1.8
				idx += 1
		# Warmup 5 frames to avoid one-shot JIT/material-uniform spikes.
		for _w in range(5):
			sprites._process(1.0 / 60.0)
		var times: Array = []
		var total_usec := 0
		var max_usec := 0
		for f in range(60):
			var t0 := Time.get_ticks_usec()
			sprites._process(1.0 / 60.0)
			var dt := Time.get_ticks_usec() - t0
			times.append(dt)
			total_usec += dt
			max_usec = maxi(max_usec, dt)
		times.sort()
		results[opt_val] = [total_usec / 60.0 / 1000.0, float(times[30]) / 1000.0, max_usec / 1000.0, sprites.count()]

	var off_r: Array = results[false]
	var on_r: Array = results[true]
	print("BENCH SpriteFx 1200 cards (60 frames): --fx-opt=off avg=%.3f ms (p50=%.3f, max=%.3f ms, n=%d) | --fx-opt=on avg=%.3f ms (p50=%.3f, max=%.3f ms, n=%d)"
		% [off_r[0], off_r[1], off_r[2], off_r[3], on_r[0], on_r[1], on_r[2], on_r[3]])
	_check(float(on_r[1]) < 0.8,
		"SpriteFx 1200 cards < 0.8 ms/frame headless (p50=%.3f ms, avg=%.3f ms)" % [float(on_r[1]), float(on_r[0])])

	holder.queue_free()
	await process_frame


func _bench_weapon_fx_200_projectiles() -> void:
	var holder := Node3D.new()
	root.add_child(holder)
	_make_camera(holder)
	var sprites := SpriteFx.new()
	holder.add_child(sprites)
	var wf := WeaponFx.new()
	wf.sprites = sprites
	holder.add_child(wf)
	await process_frame
	_ensure_synthetic_pools(sprites, wf)

	# Enable a synthetic height field so GroundHeight caching is exercised too.
	var h_img := Image.create(128, 128, false, Image.FORMAT_RF)
	h_img.fill(Color(0.5, 0.0, 0.0, 1.0))
	GroundHeight.set_field(h_img, Vector2(-128.0, -128.0), 2.0)

	var results := {}
	for opt_val: bool in [false, true]:
		SpriteFx.fx_opt = opt_val
		WeaponFx.fx_opt = opt_val
		wf.reset()
		sprites.clear()

		# Seed 1,200 background sprite cards + 170 rockets (mix of near on-screen & distant/off-screen) + 30 streams + 15 beams = 200 projectiles/streams.
		for i in range(1200):
			var c := sprites.emit("dust" if i % 2 == 0 else "sparks", Vector3(float(i % 50) - 25.0, 0.5, float(i / 50) - 12.0), 0.6, 5.0)
			if c != null:
				c.vel = Vector3(0.1, 0.2, 0.1)

		var p_list: Array = []
		var b_list: Array = []
		for i in range(170):
			var on_screen := i < 60
			var x := (float(i % 15) - 7.0) * 2.0 if on_screen else (float(i % 20) - 10.0) * 10.0
			var z := (float(i / 15) - 2.0) * 3.0 if on_screen else 90.0 + float(i) * 0.8
			p_list.append_array([1000 + i, "rocket", roundi(x * 256.0), roundi(z * 256.0)])
		for i in range(30):
			var sx := (float(i % 10) - 5.0) * 3.0
			var sz := (float(i / 10) - 1.0) * 4.0
			p_list.append_array([2000 + i, "flamethrower-fire-stream", roundi(sx * 256.0), roundi(sz * 256.0)])
		for i in range(15):
			var bx := (float(i % 5) - 2.0) * 4.0
			b_list.append_array([3000 + i, "laser-beam", roundi(bx * 256.0), -2560, roundi((bx + 1.0) * 256.0), 1280])

		var total_wf_usec := 0
		var total_sp_usec := 0
		var max_total_usec := 0
		var tot_times: Array = []
		for frame in range(65):
			if frame % 2 == 0:
				for i in range(170):
					p_list[i * 4 + 2] = int(p_list[i * 4 + 2]) + 32
				wf.handle({"t": "pj", "k": 100 + frame, "p": p_list, "b": b_list, "x": [], "e": []})
			var t0 := Time.get_ticks_usec()
			wf._process(1.0 / 60.0)
			var t1 := Time.get_ticks_usec()
			sprites._process(1.0 / 60.0)
			var t2 := Time.get_ticks_usec()
			if frame < 5:
				continue
			total_wf_usec += t1 - t0
			total_sp_usec += t2 - t1
			var tot := t2 - t0
			tot_times.append(tot)
			max_total_usec = maxi(max_total_usec, tot)

		tot_times.sort()
		results[opt_val] = [
			total_wf_usec / 60.0 / 1000.0,
			total_sp_usec / 60.0 / 1000.0,
			(total_wf_usec + total_sp_usec) / 60.0 / 1000.0,
			float(tot_times[30]) / 1000.0,
			max_total_usec / 1000.0,
			wf.flying_count(),
			sprites.count(),
		]

	var off_r: Array = results[false]
	var on_r: Array = results[true]
	print("BENCH WeaponFx 200 proj/streams + 1200 cards (60 frames):")
	print("  --fx-opt=off: weapon_fx=%.3f ms, sprite_fx=%.3f ms, total=%.3f ms (p50=%.3f, max=%.3f ms, flying=%d, cards=%d)"
		% [off_r[0], off_r[1], off_r[2], off_r[3], off_r[4], off_r[5], off_r[6]])
	print("  --fx-opt=on : weapon_fx=%.3f ms, sprite_fx=%.3f ms, total=%.3f ms (p50=%.3f, max=%.3f ms, flying=%d, cards=%d)"
		% [on_r[0], on_r[1], on_r[2], on_r[3], on_r[4], on_r[5], on_r[6]])

	_check(int(on_r[5]) == 200, "200 active projectiles/streams tracked (%d)" % int(on_r[5]))
	_check(float(on_r[3]) <= float(off_r[3]),
		"optimized p50 frame time (%.3f ms) <= --fx-opt=off (%.3f ms)" % [float(on_r[3]), float(off_r[3])])

	wf.reset()
	holder.queue_free()
	await process_frame
