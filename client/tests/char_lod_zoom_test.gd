extends SceneTree

const TestEnv := preload("res://tests/test_env.gd")
const ViewPriority := preload("res://scripts/world/view_priority.gd")
const BeltLods := preload("res://scripts/world/belt_lods.gd")
const FarChunks := preload("res://scripts/world/far_chunks.gd")
const AoZoom := preload("res://scripts/world/ao_zoom.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")

var World: Script
var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)
	else:
		print("  ok: ", what)


func _initialize() -> void:
	TestEnv.isolate("char-lod-zoom-test")
	_run.call_deferred()


class MockBeltWorld extends RefCounted:
	var lod_by_camera := false
	var _f := Vector2(100.0, 200.0)

	func focus() -> Vector2:
		return _f


class DummyRig extends Node:
	var first_person := false
	var in_remote := false

	func taken() -> bool:
		return false


func _run() -> void:
	print("--- Running char_lod_zoom_test ---")
	World = load("res://scripts/world/world.gd")
	var orig_char_lod_zoom: bool = ViewPriority.char_lod_zoom

	# 1. ViewPriority camera_zoom_distance helper
	print("\nTesting ViewPriority.camera_zoom_distance:")
	check(ViewPriority.camera_zoom_distance(null, Vector2(10, 20)) == 0.0, "null camera returns 0.0")
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.global_position = Vector3(10.0, 30.0, 20.0)
	var d30 := ViewPriority.camera_zoom_distance(cam, Vector2(10.0, 20.0))
	check(is_equal_approx(d30, 30.0), "cam at (10, 30, 20) with focus (10, 20) has distance 30.0 (got %.3f)" % d30)

	# 2. BeltLods zoom-px cap + orbit invariance + legacy fallback
	print("\nTesting BeltLods zoom-px cap and orbit invariance:")
	var mock_bworld := MockBeltWorld.new()
	cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	cam.fov = 35.0
	cam.make_current()

	# Near focus: cam distance 30 < 48 -> zoom_q == 0.0 -> _pass_zoom_px == INF
	cam.global_position = Vector3(100.0, 30.0, 20.0 + 180.0)  # focus is (100, 200)
	BeltLods._dirty = true
	BeltLods.update(mock_bworld, cam, 1.0)
	check(BeltLods._pass_zoom_px == INF, "BeltLods _pass_zoom_px is INF when cam distance < 48.0")

	# Far focus: cam distance 60 >= 48 -> zoom_q == 56.0 -> finite _pass_zoom_px
	cam.global_position = Vector3(100.0, 60.0, 200.0)
	BeltLods._dirty = true
	BeltLods.update(mock_bworld, cam, 1.0)
	var exp_px: float = (BeltLods._pass_pixels / maxf(2.0 * tan(deg_to_rad(35.0 * 0.5)), 0.001)) / 56.0
	check(is_equal_approx(BeltLods._pass_zoom_px, exp_px), "BeltLods _pass_zoom_px matches perspective formula (got %.3f, expected %.3f)" % [BeltLods._pass_zoom_px, exp_px])

	# Orbit invariance: change camera angle around focus keeping distance = 60.0
	var ang := 0.75
	cam.global_position = Vector3(100.0 + 60.0 * sin(ang), 0.0, 200.0 + 60.0 * cos(ang))
	var cam_d_orbit := ViewPriority.camera_zoom_distance(cam, mock_bworld.focus())
	check(is_equal_approx(cam_d_orbit, 60.0), "orbit camera distance to focus is 60.0 (got %.3f)" % cam_d_orbit)
	var view_before: Array = BeltLods._last_view.duplicate()
	BeltLods.update(mock_bworld, cam, 0.01)
	check(BeltLods._last_view == view_before, "BeltLods view array is 100% invariant during orbit around focus")
	check(is_equal_approx(BeltLods._pass_zoom_px, exp_px), "BeltLods _pass_zoom_px unchanged during orbit")

	# Orthogonal projection cap
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 40.0
	cam.global_position = Vector3(100.0, 60.0, 200.0)
	BeltLods._dirty = true
	BeltLods.update(mock_bworld, cam, 1.0)
	var exp_ortho: float = BeltLods._pass_pixels / 40.0
	check(is_equal_approx(BeltLods._pass_zoom_px, exp_ortho), "BeltLods _pass_zoom_px matches orthogonal formula (got %.3f, expected %.3f)" % [BeltLods._pass_zoom_px, exp_ortho])

	# Legacy fallback for BeltLods
	ViewPriority.char_lod_zoom = false
	BeltLods._dirty = true
	BeltLods.update(mock_bworld, cam, 1.0)
	check(BeltLods._pass_zoom_px == INF, "BeltLods legacy fallback: _pass_zoom_px is INF when char_lod_zoom = false")
	ViewPriority.char_lod_zoom = orig_char_lod_zoom

	# 3. World _char_zoom_y hysteresis + ortho/FOV + legacy fallback
	print("\nTesting World _char_zoom_y hysteresis and FOV/ortho:")
	var w: Node = World.new()
	root.add_child(w)
	w.lod_by_camera = false
	w._focus = Vector2(0.0, 0.0)
	cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	cam.fov = 35.0
	cam.make_current()

	# Start near: dist 20 -> 0.0
	cam.global_position = Vector3(0.0, 20.0, 0.0)
	w._update_lods(0.016)
	check(w._char_zoom_y == 0.0, "World _char_zoom_y starts at 0.0 for cam_d = 20")

	# Zooming out: dist 50 < 56 -> remains 0.0 (hysteresis)
	cam.global_position = Vector3(0.0, 50.0, 0.0)
	w._update_lods(0.016)
	check(w._char_zoom_y == 0.0, "World _char_zoom_y stays 0.0 below entry threshold 56.0 (cam_d = 50.0)")

	# Reach entry threshold: dist 60 >= 56 -> floor(60/12)*12 = 60.0
	cam.global_position = Vector3(0.0, 60.0, 0.0)
	w._update_lods(0.016)
	check(w._char_zoom_y == 60.0, "World _char_zoom_y becomes 60.0 when cam_d >= 56.0")

	# Small movement: dist 68 (abs diff 8 < 12) -> remains 60.0
	cam.global_position = Vector3(0.0, 68.0, 0.0)
	w._update_lods(0.016)
	check(w._char_zoom_y == 60.0, "World _char_zoom_y stays 60.0 for small delta (cam_d = 68.0, diff = 8)")

	# Bucket transition: dist 72 (abs diff 12 >= 12) -> floor(72/12)*12 = 72.0
	cam.global_position = Vector3(0.0, 72.0, 0.0)
	w._update_lods(0.016)
	check(w._char_zoom_y == 72.0, "World _char_zoom_y steps to 72.0 when delta >= 12.0")

	# Zooming back in: dist 50 (abs diff 22 >= 12, cam_d >= 48) -> floor(50/12)*12 = 48.0
	cam.global_position = Vector3(0.0, 50.0, 0.0)
	w._update_lods(0.016)
	check(w._char_zoom_y == 48.0, "World _char_zoom_y drops to 48.0 on zoom-in (cam_d = 50.0)")

	# Drop below 48.0 -> reset to 0.0
	cam.global_position = Vector3(0.0, 46.0, 0.0)
	w._update_lods(0.016)
	check(w._char_zoom_y == 0.0, "World _char_zoom_y resets to 0.0 when cam_d < 48.0")

	# Test reset()
	cam.global_position = Vector3(0.0, 60.0, 0.0)
	w._update_lods(0.016)
	check(w._char_zoom_y == 60.0, "World _char_zoom_y at 60.0 before reset")
	w.reset()
	check(w._char_zoom_y == 0.0, "World _char_zoom_y reset to 0.0 in reset()")

	# Legacy fallback for World
	ViewPriority.char_lod_zoom = false
	cam.global_position = Vector3(0.0, 80.0, 0.0)
	w._update_lods(0.016)
	check(w._char_zoom_y == 0.0, "World legacy fallback: _char_zoom_y stays 0.0 when char_lod_zoom = false")
	ViewPriority.char_lod_zoom = orig_char_lod_zoom
	w.queue_free()

	# 4. FarChunks char_zoom_tier_for hysteresis + _decide thresholds
	print("\nTesting FarChunks char_zoom_tier_for and _decide:")
	# Tier 0 transitions
	check(FarChunks.char_zoom_tier_for(0, 50.0) == 0, "tier 0: dist 50 -> 0")
	check(FarChunks.char_zoom_tier_for(0, 71.9) == 0, "tier 0: dist 71.9 -> 0")
	check(FarChunks.char_zoom_tier_for(0, 72.0) == 1, "tier 0: dist 72.0 -> 1")
	check(FarChunks.char_zoom_tier_for(0, 112.0) == 2, "tier 0: dist 112.0 -> 2")

	# Tier 1 transitions
	check(FarChunks.char_zoom_tier_for(1, 112.0) == 2, "tier 1: dist 112.0 -> 2")
	check(FarChunks.char_zoom_tier_for(1, 70.0) == 1, "tier 1: dist 70.0 -> 1")
	check(FarChunks.char_zoom_tier_for(1, 62.0) == 1, "tier 1: dist 62.0 -> 1")
	check(FarChunks.char_zoom_tier_for(1, 61.9) == 0, "tier 1: dist 61.9 -> 0 (drops below 62.0)")

	# Tier 2 transitions
	check(FarChunks.char_zoom_tier_for(2, 100.0) == 2, "tier 2: dist 100.0 -> 2")
	check(FarChunks.char_zoom_tier_for(2, 98.0) == 2, "tier 2: dist 98.0 -> 2")
	check(FarChunks.char_zoom_tier_for(2, 97.9) == 1, "tier 2: dist 97.9 -> 1 (drops below 98.0)")
	check(FarChunks.char_zoom_tier_for(2, 60.0) == 0, "tier 2: dist 60.0 -> 0 (drops below 62.0 directly to 0)")

	# FarChunks _decide integration
	var fc_world: Node = World.new()
	root.add_child(fc_world)
	fc_world.lod_by_camera = false
	fc_world._focus = Vector2(0.0, 0.0)

	var fc: Node = FarChunks.new()
	root.add_child(fc)
	fc.world = fc_world

	var orig_sooner: float = FarChunks.merge_sooner
	var has_sooner_arg := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--far-merge-sooner="):
			has_sooner_arg = true
	if not has_sooner_arg:
		check(is_equal_approx(orig_sooner, 1.3), "FarChunks default merge_sooner is 1.3 (got %.2f)" % orig_sooner)

	# Default merge_sooner (1.3): 140/1.3 = 107.7, 98/1.3 = 75.4, 70/1.3 = 53.8, and --far-merge-sooner=1 (1.0).
	for scale_case: Array in [[orig_sooner, "default (%.2f)" % orig_sooner], [1.0, "1.0"]]:
		FarChunks.merge_sooner = float(scale_case[0])
		var tag := str(scale_case[1])
		var s: float = clampf(fc.lod_scale * FarChunks.merge_sooner, FarChunks.LOD_SCALE_MIN, FarChunks.LOD_SCALE_MAX)
		fc.reset_decide()
		# Tier 0: dist 50.0 -> zoom_scale 1.0 -> from = 140.0 / s
		var exp0 := 140.0 / s
		cam.projection = Camera3D.PROJECTION_PERSPECTIVE
		cam.global_position = Vector3(0.0, 50.0, 0.0)
		fc._check_timer = 1.0
		fc._decide(1.0)
		check(fc._char_zoom_tier == 0, "FarChunks [%s] _char_zoom_tier is 0 at dist 50.0" % tag)
		check(is_equal_approx(fc.detail_distance(), exp0), "FarChunks [%s] detail_distance is %.1f at tier 0 (got %.1f)" % [tag, exp0, fc.detail_distance()])
		check(is_equal_approx(fc._decide_prev_from, exp0), "FarChunks [%s] _decide_prev_from recorded %.1f" % [tag, exp0])

		# Tier 1: dist 80.0 -> zoom_scale 0.70 -> from = 98.0 / s
		var exp1 := 98.0 / s
		cam.global_position = Vector3(0.0, 80.0, 0.0)
		fc._check_timer = 1.0
		fc._decide(1.0)
		check(fc._char_zoom_tier == 1, "FarChunks [%s] _char_zoom_tier is 1 at dist 80.0" % tag)
		check(is_equal_approx(fc.detail_distance(), exp1), "FarChunks [%s] detail_distance is %.1f at tier 1 (got %.1f)" % [tag, exp1, fc.detail_distance()])
		check(is_equal_approx(fc._decide_prev_from, exp1), "FarChunks [%s] _decide_prev_from updated to %.1f (row-run invalidated cleanly)" % [tag, exp1])

		# Tier 2: dist 120.0 -> zoom_scale 0.50 -> from = 70.0 / s
		var exp2 := 70.0 / s
		cam.global_position = Vector3(0.0, 120.0, 0.0)
		fc._check_timer = 1.0
		fc._decide(1.0)
		check(fc._char_zoom_tier == 2, "FarChunks [%s] _char_zoom_tier is 2 at dist 120.0" % tag)
		check(is_equal_approx(fc.detail_distance(), exp2), "FarChunks [%s] detail_distance is %.1f at tier 2 (got %.1f)" % [tag, exp2, fc.detail_distance()])
		check(is_equal_approx(fc._decide_prev_from, exp2), "FarChunks [%s] _decide_prev_from updated to %.1f" % [tag, exp2])

		# FarChunks legacy fallback
		ViewPriority.char_lod_zoom = false
		cam.global_position = Vector3(0.0, 120.0, 0.0)
		fc._check_timer = 1.0
		fc._decide(1.0)
		check(fc._char_zoom_tier == 0, "FarChunks [%s] legacy fallback: _char_zoom_tier stays 0 when char_lod_zoom = false" % tag)
		check(is_equal_approx(fc.detail_distance(), exp0), "FarChunks [%s] legacy fallback: detail_distance stays %.1f" % [tag, exp0])
		ViewPriority.char_lod_zoom = orig_char_lod_zoom
	FarChunks.merge_sooner = orig_sooner

	fc.queue_free()
	fc_world.queue_free()

	# 5. AoZoom fade when zoomed out under char anchor
	print("\nTesting AoZoom fade under character anchor:")
	var ao: Node = AoZoom.new()
	root.add_child(ao)
	var env := Environment.new()
	env.ssao_enabled = true
	env.ssao_intensity = 1.0
	ao.env = env
	var rig := DummyRig.new()
	root.add_child(rig)
	ao.rig = rig
	check(not ViewPriority.lod_by_camera(rig), "DummyRig has lod_by_camera = false")

	# Close camera: up close -> SSAO full
	var vp_h: float = ao.get_viewport().get_visible_rect().size.y
	var tiles_per_px_per_tile := 2.0 * tan(deg_to_rad(17.5)) / maxf(vp_h, 1.0)
	var close_d := AoZoom.SSAO_FULL * 0.5 / tiles_per_px_per_tile
	var far_d := AoZoom.SSAO_GONE * 2.0 / tiles_per_px_per_tile

	cam.look_at_from_position(Vector3(0, sin(deg_to_rad(50.0)) * close_d, cos(deg_to_rad(50.0)) * close_d), Vector3.ZERO)
	ao._process(0.016)
	check(ao.ssao_share > 0.95 and ao.ssao_on, "AoZoom SSAO is full close up (share = %.3f, on = %s)" % [ao.ssao_share, ao.ssao_on])

	# Far camera: far out -> SSAO fades
	cam.look_at_from_position(Vector3(0, sin(deg_to_rad(50.0)) * far_d, cos(deg_to_rad(50.0)) * far_d), Vector3.ZERO)
	ao._process(0.016)
	check(ao.tiles_per_pixel > 0.0, "AoZoom tiles_per_pixel measured on camera when char_lod_zoom = true (got %.4f)" % ao.tiles_per_pixel)
	check(ao.ssao_share < 0.05 and not ao.ssao_on, "AoZoom SSAO fades out zoomed far out (share = %.3f, on = %s)" % [ao.ssao_share, ao.ssao_on])

	# Legacy fallback: char_lod_zoom = false pins tiles_per_pixel = 0.0, ssao_share = 1.0
	ViewPriority.char_lod_zoom = false
	cam.look_at_from_position(Vector3(0, sin(deg_to_rad(50.0)) * far_d, cos(deg_to_rad(50.0)) * far_d), Vector3.ZERO)
	ao._process(0.016)
	check(ao.tiles_per_pixel == 0.0 and is_equal_approx(ao.ssao_share, 1.0), "AoZoom legacy fallback: tiles_per_pixel = 0.0 and ssao_share = 1.0 when char_lod_zoom = false")
	ViewPriority.char_lod_zoom = orig_char_lod_zoom

	ao.queue_free()
	rig.queue_free()
	cam.queue_free()

	print("\nSummary: %d fails" % fails)
	if fails == 0:
		print("PASS")
	quit(0 if fails == 0 else 1)
