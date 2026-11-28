extends SceneTree
## Verifies Mid-Detail Belt 3D LOD (`--belt-mid-lod`):
## - Straight ("s"), curve ("l"/"r"), underground ("u"), and splitter ("x") mid-LOD builds
##   via BeltLods.mid_stand_in(), reducing triangle counts to <= 300 tris while preserving
##   raised 3D side rails, hoods/splitter silhouettes, exact bed top height, scrolling UVs,
##   and source materials/vertex data.
## - 3-tier Full -> Mid -> Flat hysteresis transitions in BeltLods.lod_at() and ChunkView
##   (_mid_mmis / _flat_mmis, moving parts, shadow proxies, set_belt_off, set_belt_flat compat).
## - `--belt-mid-lod=off` fallback restoring 2-tier Full/Flat behavior.
##
## Run headless:
##   godot --headless --audio-driver Dummy --path client -s res://tests/belt_mid_lod_test.gd
##   godot --headless --audio-driver Dummy --path client -s res://tests/belt_mid_lod_test.gd -- --belt-mid-lod=off

const TestEnv := preload("res://tests/test_env.gd")
const BeltLods := preload("res://scripts/world/belt_lods.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const MaterialRows := preload("res://scripts/world/material_rows.gd")
const ChunkView := preload("res://scripts/world/chunk_view.gd")
const Switches := preload("res://scripts/switches.gd")

var WorldMirror: Script
var _passes := 0
var _fails := 0


func _check(ok: bool, what: String) -> void:
	if ok:
		_passes += 1
		print("ok   ", what)
	else:
		_fails += 1
		print("FAIL ", what)


func _initialize() -> void:
	TestEnv.isolate("belt_mid_lod_test")
	_run.call_deferred()


func _mesh_tris(mesh: ArrayMesh) -> int:
	if mesh == null:
		return 0
	var total := 0
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		var idx: Variant = arr[Mesh.ARRAY_INDEX]
		if idx is PackedInt32Array:
			total += (idx as PackedInt32Array).size() / 3
		else:
			total += (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return total


func _surface_max_y(mesh: ArrayMesh, surf_name_substr: String) -> float:
	var best := -INF
	for s in mesh.get_surface_count():
		var mat: Material = mesh.surface_get_material(s)
		var rows := MaterialRows.rows(mat)
		var match_mat := false
		if rows.is_empty():
			match_mat = mat != null and str(mat.resource_name).to_lower().contains(surf_name_substr)
		else:
			for r in rows:
				if r != null and str(r.resource_name).to_lower().contains(surf_name_substr):
					match_mat = true
					break
		if not match_mat:
			continue
		var verts: PackedVector3Array = mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		for v in verts:
			best = maxf(best, v.y)
	return best


func _add_box(verts: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array,
		colors: PackedColorArray, indices: PackedInt32Array,
		x0: float, x1: float, y0: float, y1: float, z0: float, z1: float,
		nx: int, nz: int, col: Color) -> void:
	# Subdivided top + side faces to emulate high-detail full mesh (>= 200 tris per box).
	for ix in nx:
		var ax0 := lerpf(x0, x1, float(ix) / float(nx))
		var ax1 := lerpf(x0, x1, float(ix + 1) / float(nx))
		for iz in nz:
			var az0 := lerpf(z0, z1, float(iz) / float(nz))
			var az1 := lerpf(z0, z1, float(iz + 1) / float(nz))
			var u0 := float(ix) / float(nx)
			var u1 := float(ix + 1) / float(nx)
			var v0 := float(iz) / float(nz)
			var v1 := float(iz + 1) / float(nz)
			var base := verts.size()
			verts.append_array([
				Vector3(ax0, y1, az0), Vector3(ax1, y1, az0),
				Vector3(ax1, y1, az1), Vector3(ax0, y1, az1),
			])
			for _k in 4:
				normals.append(Vector3.UP)
				colors.append(col)
			uvs.append_array([Vector2(u0, v0), Vector2(u1, v0), Vector2(u1, v1), Vector2(u0, v1)])
			indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	# Outer left/right/front/back vertical sides.
	var sides := [
		[Vector3(x0, y0, z0), Vector3(x0, y0, z1), Vector3(x0, y1, z1), Vector3(x0, y1, z0), Vector3.LEFT],
		[Vector3(x1, y0, z1), Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3.RIGHT],
		[Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3.BACK],
		[Vector3(x1, y0, z0), Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3.FORWARD],
	]
	for sd: Array in sides:
		var base := verts.size()
		for k in 4:
			verts.append(sd[k] as Vector3)
			normals.append(sd[4] as Vector3)
			uvs.append(Vector2(0.0, 0.0))
			colors.append(col)
		indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])


func _make_synthetic_belt() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	mesh.resource_name = "synthetic-belt"
	var arrays_meta: Array = []

	# Surface 0: raised 3D side rails (tier_paint) at y=0.24 (> bed 0.18).
	var rail_mat := ShaderMaterial.new()
	rail_mat.resource_name = "tier_paint"
	var rv := PackedVector3Array()
	var rn := PackedVector3Array()
	var ruv := PackedVector2Array()
	var rc := PackedColorArray()
	var ri := PackedInt32Array()
	_add_box(rv, rn, ruv, rc, ri, -0.5, -0.4, 0.0, 0.24, -0.5, 0.5, 4, 24, Color(0.8, 0.7, 0.2, 1.0))
	_add_box(rv, rn, ruv, rc, ri, 0.4, 0.5, 0.0, 0.24, -0.5, 0.5, 4, 24, Color(0.8, 0.7, 0.2, 1.0))
	var r_arr := []
	r_arr.resize(Mesh.ARRAY_MAX)
	r_arr[Mesh.ARRAY_VERTEX] = rv
	r_arr[Mesh.ARRAY_NORMAL] = rn
	r_arr[Mesh.ARRAY_TEX_UV] = ruv
	r_arr[Mesh.ARRAY_COLOR] = rc
	r_arr[Mesh.ARRAY_INDEX] = ri
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, r_arr)
	mesh.surface_set_material(0, rail_mat)
	arrays_meta.append(r_arr)

	# Surface 1: belt bed (belt_surface) at y=0.18 with scrolling UV v in [0, 1].
	var bed_mat := ShaderMaterial.new()
	bed_mat.resource_name = "belt_surface"
	var bv := PackedVector3Array()
	var bn := PackedVector3Array()
	var buv := PackedVector2Array()
	var bc := PackedColorArray()
	var bi := PackedInt32Array()
	_add_box(bv, bn, buv, bc, bi, -0.4, 0.4, 0.0, 0.18, -0.5, 0.5, 10, 24, Color(0.35, 0.35, 0.38, 1.0))
	var b_arr := []
	b_arr.resize(Mesh.ARRAY_MAX)
	b_arr[Mesh.ARRAY_VERTEX] = bv
	b_arr[Mesh.ARRAY_NORMAL] = bn
	b_arr[Mesh.ARRAY_TEX_UV] = buv
	b_arr[Mesh.ARRAY_COLOR] = bc
	b_arr[Mesh.ARRAY_INDEX] = bi
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, b_arr)
	mesh.surface_set_material(1, bed_mat)
	arrays_meta.append(b_arr)

	mesh.set_meta(ModelLods.ARRAYS_META, arrays_meta)
	return mesh


func _test_switches_and_constants() -> void:
	var expected_on := Switches.on("--belt-mid-lod")
	_check(BeltLods.mid_enabled == expected_on,
		"BeltLods.mid_enabled matches --belt-mid-lod switch (%s)" % str(expected_on))
	_check(BeltLods.MID == &"mid" and BeltLods.FLAT == &"flat",
		"BeltLods exposes MID and FLAT StringName constants")
	_check(is_equal_approx(BeltLods.MID_BELOW, 44.0) and is_equal_approx(BeltLods.MID_FULL_ABOVE, 52.0)
		and is_equal_approx(BeltLods.FLAT_BELOW, 20.0) and is_equal_approx(BeltLods.FULL_ABOVE, 24.0),
		"BeltLods thresholds match MID_BELOW=44, MID_FULL_ABOVE=52, FLAT_BELOW=20, FULL_ABOVE=24")


func _test_synthetic_belt_mid_build() -> void:
	var synth := _make_synthetic_belt()
	var full_tris := _mesh_tris(synth)
	_check(full_tris >= 800, "synthetic full belt has %d tris (>= 800)" % full_tris)

	var first_ret := BeltLods.mid_stand_in(synth, "s")
	if not BeltLods.mid_enabled:
		_check(first_ret == null and not BeltLods.coming_mid(synth),
			"when --belt-mid-lod=off, mid_stand_in returns null and does not queue")
		return

	_check(first_ret == null and BeltLods.coming_mid(synth),
		"mid_stand_in queues worker build and reports coming_mid=true")
	BeltLods.finish_all()
	var mid := BeltLods.mid_stand_in(synth, "s")
	_check(mid != null and not BeltLods.coming_mid(synth),
		"finish_all completes mid_stand_in build")
	var mid_tris := _mesh_tris(mid)
	var red_pct := 100.0 * (1.0 - float(mid_tris) / float(full_tris))
	_check(mid_tris > 0 and mid_tris <= 300 and red_pct >= 75.0,
		"synthetic mid belt reduces tris %d -> %d (%.1f%% reduction, <= 300)" % [full_tris, mid_tris, red_pct])

	# Verify 3D raised side rails (> bed 0.18) and exact bed height (0.18).
	var rail_y := _surface_max_y(mid, "tier_paint")
	var bed_y := _surface_max_y(mid, "belt_surface")
	_check(rail_y >= 0.23 and absf(rail_y - 0.24) < 0.01,
		"synthetic mid belt preserves raised 3D side rails (y=%.3f vs 0.240)" % rail_y)
	_check(absf(bed_y - 0.18) < 0.005,
		"synthetic mid belt preserves exact bed top height (y=%.3f vs 0.180)" % bed_y)

	# Verify interpolated scrolling UVs on belt_surface surface and material sync.
	var bed_uvs: PackedVector2Array = PackedVector2Array()
	for s in mid.get_surface_count():
		var m := mid.surface_get_material(s)
		if m != null and str(m.resource_name).contains("belt_surface"):
			bed_uvs = mid.surface_get_arrays(s)[Mesh.ARRAY_TEX_UV] as PackedVector2Array
	var min_v := INF
	var max_v := -INF
	for uv in bed_uvs:
		min_v = minf(min_v, uv.y)
		max_v = maxf(max_v, uv.y)
	_check(not bed_uvs.is_empty() and min_v <= 0.05 and max_v >= 0.95,
		"synthetic mid belt preserves scrolling UVs along belt_surface (v=[%.3f, %.3f])" % [min_v, max_v])

	# Material sync (_same_materials) when source material is swapped after build.
	var new_mat := ShaderMaterial.new()
	new_mat.resource_name = "tier_paint_swapped"
	synth.surface_set_material(0, new_mat)
	var synced := BeltLods.mid_stand_in(synth, "s")
	var from := synced.get_meta(&"f3d_from", PackedInt32Array()) as PackedInt32Array
	_check(synced.surface_get_material(0) == synth.surface_get_material(int(from[0])),
		"mid_stand_in keeps materials synchronized via _same_materials")


func _test_loaded_belts_mid_build() -> void:
	var cases := [
		["transport-belt", "transport-belt", {"s": "s", ModelLibrary.PACK_KEY: "builtin:wube3dp"}, 0.01],
		["transport-belt", "transport-belt", {"s": "l", ModelLibrary.PACK_KEY: "builtin:wube3dp"}, 0.01],
		["fast-transport-belt", "transport-belt", {"s": "r", ModelLibrary.PACK_KEY: "builtin:wube3dp"}, 0.01],
		["underground-belt", "underground-belt", {"u": "i", ModelLibrary.PACK_KEY: "builtin:wube3dp"}, 0.03],
		["underground-belt", "underground-belt", {"u": "o", ModelLibrary.PACK_KEY: "builtin:wube3dp"}, 0.03],
		["splitter", "splitter", {ModelLibrary.PACK_KEY: "builtin:placeholders"}, 0.02],
	]
	var meshes: Array = []
	for c: Array in cases:
		var mesh := ModelLibrary.mesh_for_entity(c[0], c[1], c[2], 0) as ArrayMesh
		meshes.append(mesh)
		var kind := BeltLods.kind_of(c[1], c[2])
		BeltLods.stand_in(mesh, kind)
		BeltLods.mid_stand_in(mesh, kind)
	BeltLods.finish_all()

	for i in cases.size():
		var c: Array = cases[i]
		var mesh: ArrayMesh = meshes[i]
		var kind := BeltLods.kind_of(c[1], c[2])
		var flat := BeltLods.stand_in(mesh, kind)
		var mid := BeltLods.mid_stand_in(mesh, kind)
		var full_tris := _mesh_tris(mesh)
		var flat_tris := _mesh_tris(flat)
		if not BeltLods.mid_enabled:
			_check(mid == null and flat != null and flat_tris > 0,
				"--belt-mid-lod=off: %s (%s) builds flat (%d tris) and skips mid" % [c[0], kind, flat_tris])
			continue
		var mid_tris := _mesh_tris(mid)
		var red_pct := 100.0 * (1.0 - float(mid_tris) / float(full_tris))
		var top_gap := absf(mid.get_aabb().end.y - mesh.get_aabb().end.y)
		var from := mid.get_meta(&"f3d_from", PackedInt32Array()) as PackedInt32Array
		var mat_ok := not from.is_empty() and mid.surface_get_material(0) == mesh.surface_get_material(int(from[0]))
		_check(mid != null and mid_tris > 0 and mid_tris <= 300 and red_pct >= 75.0
			and top_gap <= float(c[3]) and mat_ok,
			"%s (%s): full=%d -> mid=%d (%.1f%% red, <=300), top_gap=%.4f, flat=%d" % [
				c[0], kind, full_tris, mid_tris, red_pct, top_gap, flat_tris])
		if c[1] == "transport-belt":
			var full_bed_y := _surface_max_y(mesh, "belt_surface")
			var mid_bed_y := _surface_max_y(mid, "belt_surface")
			_check(absf(mid_bed_y - full_bed_y) < 0.005,
				"%s (%s) bed top height parity: mid=%.4f vs full=%.4f" % [c[0], kind, mid_bed_y, full_bed_y])


func _test_hysteresis_transitions() -> void:
	if BeltLods.mid_enabled:
		# Perspective Full -> Mid -> Flat -> Mid -> Full with hysteresis bands.
		_check(BeltLods.lod_at(60.0, BeltLods.TIER_FULL, false, 1.0) == BeltLods.TIER_FULL,
			"perspective 60 px stays Full (0)")
		_check(BeltLods.lod_at(48.0, BeltLods.TIER_FULL, false, 1.0) == BeltLods.TIER_FULL,
			"perspective 48 px from Full stays Full (in [44, 52] hysteresis)")
		_check(BeltLods.lod_at(40.0, BeltLods.TIER_FULL, false, 1.0) == BeltLods.TIER_MID,
			"perspective 40 px (< 44) drops Full -> Mid (1)")
		_check(BeltLods.lod_at(48.0, BeltLods.TIER_MID, false, 1.0) == BeltLods.TIER_MID,
			"perspective 48 px from Mid stays Mid (in [44, 52] hysteresis)")
		_check(BeltLods.lod_at(55.0, BeltLods.TIER_MID, false, 1.0) == BeltLods.TIER_FULL,
			"perspective 55 px (> 52) rises Mid -> Full (0)")
		_check(BeltLods.lod_at(22.0, BeltLods.TIER_MID, false, 1.0) == BeltLods.TIER_MID,
			"perspective 22 px from Mid stays Mid (in [20, 24] hysteresis)")
		_check(BeltLods.lod_at(18.0, BeltLods.TIER_MID, false, 1.0) == BeltLods.TIER_FLAT,
			"perspective 18 px (< 20) drops Mid -> Flat (2)")
		_check(BeltLods.lod_at(22.0, BeltLods.TIER_FLAT, false, 1.0) == BeltLods.TIER_FLAT,
			"perspective 22 px from Flat stays Flat (in [20, 24] hysteresis)")
		_check(BeltLods.lod_at(26.0, BeltLods.TIER_FLAT, false, 1.0) == BeltLods.TIER_MID,
			"perspective 26 px (> 24) rises Flat -> Mid (1)")
		_check(BeltLods.lod_at(15.0, BeltLods.TIER_FULL, false, 1.0) == BeltLods.TIER_FLAT,
			"perspective 15 px jumps Full -> Flat (2)")
		_check(BeltLods.lod_at(55.0, BeltLods.TIER_FLAT, false, 1.0) == BeltLods.TIER_FULL,
			"perspective 55 px jumps Flat -> Full (0)")
		# Orthographic: no hysteresis gap.
		_check(BeltLods.lod_at(46.0, BeltLods.TIER_MID, true, 1.0) == BeltLods.TIER_FULL
			and BeltLods.lod_at(30.0, BeltLods.TIER_FULL, true, 1.0) == BeltLods.TIER_MID
			and BeltLods.lod_at(22.0, BeltLods.TIER_FLAT, true, 1.0) == BeltLods.TIER_MID
			and BeltLods.lod_at(18.0, BeltLods.TIER_MID, true, 1.0) == BeltLods.TIER_FLAT,
			"orthographic uses direct 3-tier cuts without hysteresis gap")
		# lod_scale scaling (1.5x -> MID_BELOW=66, MID_FULL_ABOVE=78).
		_check(BeltLods.lod_at(60.0, BeltLods.TIER_FULL, false, 1.5) == BeltLods.TIER_MID
			and BeltLods.lod_at(70.0, BeltLods.TIER_MID, false, 1.5) == BeltLods.TIER_MID
			and BeltLods.lod_at(80.0, BeltLods.TIER_MID, false, 1.5) == BeltLods.TIER_FULL,
			"lod_at scales MID thresholds by lod_scale")
	else:
		# --belt-mid-lod=off: 2-tier Full/Flat only.
		_check(BeltLods.lod_at(40.0, BeltLods.TIER_FULL, false, 1.0) == BeltLods.TIER_FULL
			and BeltLods.lod_at(26.0, BeltLods.TIER_FLAT, false, 1.0) == BeltLods.TIER_FULL
			and BeltLods.lod_at(22.0, BeltLods.TIER_FLAT, false, 1.0) == BeltLods.TIER_FLAT
			and BeltLods.lod_at(18.0, BeltLods.TIER_FULL, false, 1.0) == BeltLods.TIER_FLAT,
			"--belt-mid-lod=off keeps 2-tier Full/Flat transitions")


func _test_chunk_view_integration() -> void:
	var w: Node = WorldMirror.new()
	root.add_child(w)
	w.set_process(false)
	w.far_chunks.enabled = false
	w.protos.add_entities([
		[1, "transport-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[2, "splitter", "splitter", -1.0, -0.5, 1.0, 0.5, 200, 180, 0, 1, 1],
	])
	var c := Vector2i(3, 0)
	var cv := ChunkView.new()
	cv.coord = c
	cv.loaded = true
	w.chunks[c] = cv
	w.add_child(cv)

	var rec_cls: Variant = WorldMirror.get("Rec")
	var r_belt = rec_cls.new()
	r_belt.key = 101
	r_belt.unit = 101
	r_belt.proto_id = 1
	r_belt.pos = Vector2(c.x * 32 + 4.5, 4.5)
	r_belt.chunk = c
	r_belt.extra = {"s": "s", "r": [201], ModelLibrary.PACK_KEY: "builtin:wube3dp"}
	cv.entities[r_belt.key] = r_belt
	w.entities[r_belt.key] = r_belt

	var r_split = rec_cls.new()
	r_split.key = 102
	r_split.unit = 102
	r_split.proto_id = 2
	r_split.pos = Vector2(c.x * 32 + 7.5, 4.5)
	r_split.chunk = c
	r_split.extra = {ModelLibrary.PACK_KEY: "builtin:placeholders"}
	cv.entities[r_split.key] = r_split
	w.entities[r_split.key] = r_split

	var belt_mesh := ModelLibrary.mesh_for_entity("transport-belt", "transport-belt", {"s": "s", ModelLibrary.PACK_KEY: "builtin:wube3dp"}, 0)
	var split_mesh := ModelLibrary.mesh_for_entity("splitter", "splitter", {ModelLibrary.PACK_KEY: "builtin:placeholders"}, 0)
	BeltLods.stand_in(belt_mesh, "s")
	BeltLods.mid_stand_in(belt_mesh, "s")
	BeltLods.stand_in(split_mesh, "x")
	BeltLods.mid_stand_in(split_mesh, "x")
	BeltLods.finish_all()

	cv.build_entities(w.protos, w.working)
	var full_mmi: MultiMeshInstance3D = cv._nodes.get(belt_mesh)
	var flat_mmi: MultiMeshInstance3D = cv._nodes.get([belt_mesh, BeltLods.FLAT])
	var mid_mmi: MultiMeshInstance3D = cv._nodes.get([belt_mesh, BeltLods.MID])
	var parts: Array = cv._nodes.keys().filter(func(k) -> bool: return k is Array and k[1] is int)
	_check(full_mmi != null and flat_mmi != null and not parts.is_empty(),
		"ChunkView builds belt full, flat, and %d moving-part MultiMeshes" % parts.size())
	if BeltLods.mid_enabled:
		_check(mid_mmi != null and cv._mid_mmis.has(mid_mmi) and cv._flat_mmis.has(flat_mmi),
			"ChunkView registers _mid_mmis and _flat_mmis when mid_enabled=true")
	else:
		_check(mid_mmi == null and cv._mid_mmis.is_empty(),
			"ChunkView skips _mid_mmis when --belt-mid-lod=off")

	var cam := Camera3D.new()
	cam.fov = 50.0
	w.add_child(cam)
	var vp := cam.get_viewport()
	var pixels := vp.get_visible_rect().size.y * (vp.scaling_3d_scale if vp.scaling_3d_mode != Viewport.SCALING_3D_MODE_FSR2 else 1.0)
	var move_cam := func(px: float) -> void:
		var d := pixels / (2.0 * tan(deg_to_rad(cam.fov) * 0.5) * px)
		cam.global_position = Vector3(cv.belt_bounds.get_center().x, cv.belt_bounds.end.y + d, cv.belt_bounds.get_center().z)
		BeltLods._dirty = true
		BeltLods.update(w, cam, 1.0)

	var parts_visible := func(want_vis: bool) -> bool:
		for pk in parts:
			var pmmi: MultiMeshInstance3D = cv._nodes[pk]
			if pmmi.visible != want_vis:
				return false
		return true

	# 60 px/tile -> Full
	move_cam.call(60.0)
	_check(cv.belt_lod == BeltLods.TIER_FULL and not cv.belt_flat and full_mmi.visible and not flat_mmi.visible
		and (mid_mmi == null or not mid_mmi.visible) and parts_visible.call(true),
		"60 px/tile draws Full belts and moving parts")

	# 35 px/tile -> Mid (when enabled) or Full (when --belt-mid-lod=off)
	move_cam.call(35.0)
	if BeltLods.mid_enabled:
		var proxies_off: bool = cv._shadows.values().all(func(m: MultiMeshInstance3D) -> bool: return not m.visible)
		_check(cv.belt_lod == BeltLods.TIER_MID and not cv.belt_flat and not full_mmi.visible
			and mid_mmi.visible and not flat_mmi.visible and parts_visible.call(false) and proxies_off,
			"35 px/tile draws Mid 3D stand-ins, hides full/parts/shadow proxies, keeps belt_flat=false")
	else:
		_check(cv.belt_lod == BeltLods.TIER_FULL and not cv.belt_flat and full_mmi.visible and not flat_mmi.visible,
			"--belt-mid-lod=off keeps Full belts at 35 px/tile")

	# 12 px/tile -> Flat
	move_cam.call(12.0)
	_check(cv.belt_lod == BeltLods.TIER_FLAT and cv.belt_flat and not full_mmi.visible
		and flat_mmi.visible and (mid_mmi == null or not mid_mmi.visible) and parts_visible.call(false),
		"12 px/tile draws Flat stand-ins and hides full/mid/parts")

	# Circuit switch off propagates to all active belt LOD MultiMeshes.
	cv.set_belt_off(101, true)
	var sw_entries: Array = cv._switches.get(101, [])
	var expect_sw_count := 3 if BeltLods.mid_enabled else 2
	var all_stopped := sw_entries.size() == expect_sw_count and sw_entries.all(func(s: Array) -> bool: return bool(s[2]))
	_check(all_stopped, "set_belt_off updates custom data on all %d belt MultiMeshes" % expect_sw_count)

	# Backward-compatible set_belt_flat(bool).
	cv.set_belt_flat(false)
	_check(cv.belt_lod == BeltLods.TIER_FULL and not cv.belt_flat and full_mmi.visible,
		"set_belt_flat(false) restores Full tier")
	cv.set_belt_flat(true)
	_check(cv.belt_lod == BeltLods.TIER_FLAT and cv.belt_flat and flat_mmi.visible,
		"set_belt_flat(true) restores Flat tier")

	BeltLods.untrack(cv)
	w.queue_free()


func _run() -> void:
	WorldMirror = load("res://scripts/world/world.gd")
	_test_switches_and_constants()
	_test_synthetic_belt_mid_build()
	_test_loaded_belts_mid_build()
	_test_hysteresis_transitions()
	_test_chunk_view_integration()
	await create_timer(0.05).timeout
	TestEnv.clean()
	print("belt_mid_lod_test: %d passed, %d failed" % [_passes, _fails])
	print("FAILS: %d" % _fails)
	quit(1 if _fails > 0 else 0)
