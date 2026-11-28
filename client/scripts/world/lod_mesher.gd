extends RefCounted
## Builds one Distant Horizon quadtree section's solid + water ArrayMesh off the main thread.
##
## Terrain uses greedy 2D rectangular merging (capped by `max_quad_tiles` when hills are active)
## with merged shoreline banks so grazing angles never expose gaps. Buildings, cliffs, low
## structures, and ore patches use density-scaled quantized heights, greedy 2D top faces, and
## greedy 1D exposed-wall runs (culling all interior walls). Trees emit organic rotated 4-sided
## pitched crowns with deterministic world-hash jitter.

const Switches := preload("res://scripts/switches.gd")

const CAT_NONE := 0
const CAT_BUILDING := 1
const CAT_TREE := 2
const CAT_CLIFF := 3
const CAT_LOW := 4
const CAT_ORE := 5
const CAT_POLE := 6

const TILE_LAND := 0
const TILE_WATER := 1
const TILE_VOID := 2
const TILE_LAVA := 3

const WATER_Y := -0.2
const BANK_BOTTOM := -0.25
const DECK_BOTTOM := -0.55
const HEIGHT_STEP := 0.25
const DETAIL_FULL := 0
const DETAIL_MID := 1
const DETAIL_FAR := 2
const DETAIL_HORIZON := 3
const HEIGHT_STEPS := [0.25, 0.50, 1.00, 1.50]

const KIND_NORMAL := 0.0
const KIND_LAVA := 0.25
const KIND_TREE := 0.50
const KIND_GROUND := 0.75
## A cliff's block: shaded as KIND_NORMAL, seated in its terrace as the near cliffs are (lod_common.gdshaderinc).
const KIND_CLIFF := 1.0

# --- inputs -----------------------------------------------------------------------------------
var key := Vector3i.ZERO
var serial := 0
var section_origin := Vector2.ZERO
var grid_n := 0
var cell_tiles := 4.0
var tiles := PackedInt32Array()
var protos := PackedInt32Array()
var flags := PackedByteArray()
var palette: Object = null
var max_quad_tiles := INF
var detail_tier := DETAIL_FULL
var chunk_mask := 0
var solid_material: Material = null
var water_material: Material = null
var keep_arrays := false
## Per entity id, 1 for Factorio's cliffs (the palette's ent_seat; rocks share CAT_CLIFF but not this):
## their blocks get KIND_CLIFF. Set from the palette in run().
var _seat := PackedByteArray()

# --- outputs ----------------------------------------------------------------------------------
var mesh: ArrayMesh = null
## 1 when the last run() built its arrays in C++ (LodMesherNative), else 0 (GDScript).
var used_native := 0
var solid_arrays: Array = []
var water_arrays: Array = []
var solid_surface := -1
var water_surface := -1
var solid_tris := 0
var water_tris := 0
var tri_count := 0
var usec := 0


const NATIVE := "LodMesherNative"
static var _native_mode := -1  # -1 not read yet, 0 off, 1 on


## True when the C++ twin (client/native: LodMesherNative) is loaded and --native-lod-mesher isn't off.
static func native_enabled() -> bool:
	if _native_mode < 0:
		var on := true
		for a in Switches.args():
			if a.begins_with("--native-lod-mesher="):
				on = a.substr(20) != "off"
		_native_mode = 1 if on else 0
	return _native_mode == 1 and ClassDB.class_exists(NATIVE)


## Builds the section mesh (safe to execute on WorkerThreadPool).
## (--dh-sample-worker, on by default) The section's chunks as distant_horizon.gd gathered them on the
## main thread: `sample_side` x `sample_side` slots (row-major by chunk offset in the section), each null
## or [tiles, protos, flags]. When set, run() samples the grid from them first (sample_grid), on the worker.
var sample_src: Array = []
var sample_side := 0
var sample_sec_chunks := 0
var sample_level := 0
## The worker's time sampling the grid (µs), 0 when the main thread sampled it.
var sample_usec := 0


func run() -> void:
	if not sample_src.is_empty():
		var ts := Time.get_ticks_usec()
		var ec: PackedByteArray = palette.ent_cat if palette != null else PackedByteArray()
		var grid := sample_grid(grid_n, sample_sec_chunks, cell_tiles, sample_level, ec, sample_src, sample_side)
		tiles = grid[0]
		protos = grid[1]
		flags = grid[2]
		chunk_mask = int(grid[3])
		sample_src = []
		sample_usec = Time.get_ticks_usec() - ts
	var t0 := Time.get_ticks_usec()
	mesh = null
	solid_arrays = []
	water_arrays = []
	solid_surface = -1
	water_surface = -1
	solid_tris = 0
	water_tris = 0
	tri_count = 0

	var n := grid_n
	if palette == null or n <= 0 or tiles.size() != n * n:
		usec = Time.get_ticks_usec() - t0
		return

	var tile_colors: PackedColorArray = palette.tile_colors
	var tile_kind: PackedByteArray = palette.tile_kind
	var tile_rough: PackedFloat32Array = palette.tile_rough
	var ent_top: PackedColorArray = palette.ent_top_colors
	var ent_side: PackedColorArray = palette.ent_side_colors
	var ent_heights: PackedFloat32Array = palette.ent_heights
	var ent_metal: PackedFloat32Array = palette.ent_metal
	var ent_rough: PackedFloat32Array = palette.ent_rough
	var ent_cat: PackedByteArray = palette.ent_cat
	var ent_glow: PackedByteArray = palette.ent_glow
	var seat: Variant = palette.get("ent_seat")
	_seat = seat if seat is PackedByteArray else PackedByteArray()

	var sv := PackedVector3Array()
	var sc := PackedColorArray()
	var su := PackedVector2Array()
	var si := PackedInt32Array()

	var wv := PackedVector3Array()
	var wc := PackedColorArray()
	var wi := PackedInt32Array()

	used_native = 0
	if native_enabled():
		var nat: Object = ClassDB.instantiate(NATIVE)
		var res: Dictionary = nat.call("build", {
			"n": n, "cell_tiles": cell_tiles, "section_origin": section_origin,
			"max_quad_tiles": max_quad_tiles, "detail_tier": detail_tier,
			"tiles": tiles, "protos": protos, "flags": flags,
			"tile_colors": tile_colors, "tile_kind": tile_kind, "tile_rough": tile_rough,
			"ent_top": ent_top, "ent_side": ent_side, "ent_heights": ent_heights,
			"ent_metal": ent_metal, "ent_rough": ent_rough, "ent_cat": ent_cat,
			"ent_glow": ent_glow, "seat": _seat})
		if res.has("si"):
			sv = res["sv"]
			sc = res["sc"]
			su = res["su"]
			si = res["si"]
			wv = res["wv"]
			wc = res["wc"]
			wi = res["wi"]
			used_native = 1

	var max_cells := n
	if is_finite(max_quad_tiles) and max_quad_tiles > 0.0:
		max_cells = maxi(1, floori(max_quad_tiles / maxf(cell_tiles, 0.001)))

	var tier := clampi(detail_tier, DETAIL_FULL, DETAIL_HORIZON)
	var flat_pid := PackedInt32Array()
	var flat_kind := PackedByteArray()
	if used_native == 0 and tier > DETAIL_FULL and protos.size() == n * n and not ent_cat.is_empty():
		flat_pid.resize(n * n)
		flat_kind.resize(n * n)
		var cat_count := ent_cat.size()
		var h_count := ent_heights.size()
		var has_flags := flags.size() == n * n
		for i in n * n:
			var pid := protos[i]
			if pid <= 0 or pid >= cat_count:
				continue
			var cat := ent_cat[pid]
			if cat == CAT_NONE or cat == CAT_POLE:
				continue
			if cat == CAT_LOW or cat == CAT_ORE:
				if tier >= DETAIL_MID:
					flat_pid[i] = pid
					flat_kind[i] = 1
			elif cat == CAT_TREE:
				if tier >= DETAIL_FAR:
					flat_pid[i] = pid
					flat_kind[i] = 2
			else:
				if tier >= DETAIL_HORIZON:
					var raw_h := ent_heights[pid] if pid < h_count else 1.0
					var dens := (int(flags[i]) & 15) if has_flags else 15
					if raw_h < 1.5 or dens < 3:
						flat_pid[i] = pid
						flat_kind[i] = 1

	if used_native == 0:
		_mesh_terrain(n, max_cells, tier, flat_pid, flat_kind, tile_colors, tile_kind, tile_rough,
			ent_top, ent_rough, ent_glow, sv, sc, su, si, wv, wc, wi)

	if used_native == 0 and protos.size() == n * n and not ent_cat.is_empty():
		_mesh_entities(n, max_cells, tier, flat_pid, ent_top, ent_side, ent_heights, ent_metal, ent_rough,
			ent_cat, ent_glow, sv, sc, su, si)

	solid_tris = si.size() / 3
	water_tris = wi.size() / 3
	tri_count = solid_tris + water_tris

	if solid_tris > 0:
		var sa := []
		sa.resize(Mesh.ARRAY_MAX)
		sa[Mesh.ARRAY_VERTEX] = sv
		sa[Mesh.ARRAY_COLOR] = sc
		sa[Mesh.ARRAY_TEX_UV] = su
		sa[Mesh.ARRAY_INDEX] = si
		if keep_arrays:
			solid_arrays = sa
		if mesh == null:
			mesh = ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sa, [], {}, Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES)
		solid_surface = mesh.get_surface_count() - 1
		if solid_material != null:
			mesh.surface_set_material(solid_surface, solid_material)

	if water_tris > 0:
		var wa := []
		wa.resize(Mesh.ARRAY_MAX)
		wa[Mesh.ARRAY_VERTEX] = wv
		wa[Mesh.ARRAY_COLOR] = wc
		wa[Mesh.ARRAY_INDEX] = wi
		if keep_arrays:
			water_arrays = wa
		if mesh == null:
			mesh = ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, wa, [], {}, Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES)
		water_surface = mesh.get_surface_count() - 1
		if water_material != null:
			mesh.surface_set_material(water_surface, water_material)

	usec = Time.get_ticks_usec() - t0


func _mesh_terrain(n: int, max_cells: int, tier: int, flat_pid: PackedInt32Array, flat_kind: PackedByteArray,
		tile_colors: PackedColorArray, tile_kind: PackedByteArray, tile_rough: PackedFloat32Array,
		ent_top: PackedColorArray, ent_rough: PackedFloat32Array, ent_glow: PackedByteArray,
		sv: PackedVector3Array, sc: PackedColorArray, su: PackedVector2Array, si: PackedInt32Array,
		wv: PackedVector3Array, wc: PackedColorArray, wi: PackedInt32Array) -> void:
	var kinds := PackedByteArray()
	kinds.resize(n * n)
	for i in n * n:
		var tid := tiles[i]
		if tid < 0:
			kinds[i] = TILE_VOID
		elif tid < tile_kind.size():
			kinds[i] = tile_kind[tid]
		else:
			kinds[i] = TILE_LAND

	var visited := PackedByteArray()
	visited.resize(n * n)
	var ct := cell_tiles
	var has_flat := flat_pid.size() == n * n
	var has_flags := flags.size() == n * n

	for y in n:
		for x in n:
			var idx := y * n + x
			if visited[idx] != 0:
				continue
			var k := kinds[idx]
			if k == TILE_VOID:
				visited[idx] = 1
				continue
			var tid := tiles[idx]
			var check_flat := has_flat and k == TILE_LAND
			var fpid := flat_pid[idx] if check_flat else 0
			var w := 1
			while x + w < n and w < max_cells:
				var nidx := y * n + (x + w)
				if visited[nidx] != 0 or tiles[nidx] != tid:
					break
				if check_flat and flat_pid[nidx] != fpid:
					break
				w += 1
			var h := 1
			while y + h < n and h < max_cells:
				var row_ok := true
				var row_base := (y + h) * n + x
				for dx in w:
					var ridx := row_base + dx
					if visited[ridx] != 0 or tiles[ridx] != tid:
						row_ok = false
						break
					if check_flat and flat_pid[ridx] != fpid:
						row_ok = false
						break
				if not row_ok:
					break
				h += 1
			for dy in h:
				var r := (y + dy) * n + x
				for dx in w:
					visited[r + dx] = 1

			var x0 := float(x) * ct
			var z0 := float(y) * ct
			var x1 := float(x + w) * ct
			var z1 := float(y + h) * ct
			var raw_col := _tile_color(tile_colors, tid)

			if k == TILE_WATER:
				var wcol := _encode_color(raw_col, 0.2, 0.0)
				_emit_water_top(wv, wc, wi, x0, z0, x1, z1, WATER_Y, wcol)
			elif k == TILE_LAVA:
				var lcol := _encode_color(raw_col, 0.6, 0.0)
				_emit_solid_top(sv, sc, su, si, x0, z0, x1, z1, WATER_Y, lcol, Vector2(1.0, KIND_LAVA))
			else:
				var rough := tile_rough[tid] if tid >= 0 and tid < tile_rough.size() else 0.95
				var ukind := KIND_GROUND
				var uglow := 0.0
				if fpid > 0:
					var dens_f := clampf(float(int(flags[idx]) & 15) / 15.0, 0.25, 1.0) if has_flags else 1.0
					var etop := ent_top[fpid] if fpid < ent_top.size() else raw_col
					var erough := ent_rough[fpid] if fpid < ent_rough.size() else rough
					var fk := flat_kind[idx]
					var blend := clampf(0.45 + 0.40 * dens_f, 0.45, 0.85) if fk == 2 else clampf(0.35 + 0.45 * dens_f, 0.35, 0.80)
					raw_col = raw_col.lerp(etop, blend)
					rough = lerpf(rough, erough, blend)
					if fk == 2:
						ukind = KIND_TREE
					else:
						var fglow := (float(ent_glow[fpid]) / 3.0) * dens_f * 0.55 if fpid < ent_glow.size() else 0.0
						if fglow > 0.0:
							uglow = fglow
							ukind = KIND_NORMAL
				var lcol := _encode_color(raw_col, rough, 0.0)
				_emit_solid_top(sv, sc, su, si, x0, z0, x1, z1, 0.0, lcol, Vector2(uglow, ukind))

	if tier < DETAIL_HORIZON:
		_mesh_coast_banks(n, max_cells, kinds, tile_colors, tile_rough, sv, sc, su, si)


func _mesh_coast_banks(n: int, max_cells: int, kinds: PackedByteArray, tile_colors: PackedColorArray,
		tile_rough: PackedFloat32Array, sv: PackedVector3Array, sc: PackedColorArray,
		su: PackedVector2Array, si: PackedInt32Array) -> void:
	var ct := cell_tiles
	# Horizontal shore edges (North and South)
	for y in n:
		for dir: int in [-1, 1]:
			var ny := y + dir
			if ny < 0 or ny >= n:
				continue
			var x := 0
			while x < n:
				var idx := y * n + x
				if kinds[idx] != TILE_LAND:
					x += 1
					continue
				var nk := kinds[ny * n + x]
				if nk == TILE_LAND:
					x += 1
					continue
				var tid := tiles[idx]
				var run := 1
				while x + run < n and run < max_cells:
					var cidx := y * n + x + run
					if kinds[cidx] != TILE_LAND or tiles[cidx] != tid or kinds[ny * n + x + run] != nk:
						break
					run += 1
				var x0 := float(x) * ct
				var x1 := float(x + run) * ct
				var z := float(y if dir < 0 else y + 1) * ct
				var bot := DECK_BOTTOM if nk == TILE_VOID else BANK_BOTTOM
				var rough := tile_rough[tid] if tid >= 0 and tid < tile_rough.size() else 0.95
				var bcol := _encode_color(_tile_color(tile_colors, tid).darkened(0.35), rough, 0.0)
				var uv := Vector2(0.0, KIND_GROUND)
				if dir < 0:
					_emit_solid_quad(sv, sc, su, si, Vector3(x1, 0.0, z), Vector3(x0, 0.0, z),
						Vector3(x0, bot, z), Vector3(x1, bot, z), bcol, bcol, uv)
				else:
					_emit_solid_quad(sv, sc, su, si, Vector3(x0, 0.0, z), Vector3(x1, 0.0, z),
						Vector3(x1, bot, z), Vector3(x0, bot, z), bcol, bcol, uv)
				x += run

	# Vertical shore edges (West and East)
	for x in n:
		for dir: int in [-1, 1]:
			var nx := x + dir
			if nx < 0 or nx >= n:
				continue
			var y := 0
			while y < n:
				var idx := y * n + x
				if kinds[idx] != TILE_LAND:
					y += 1
					continue
				var nk := kinds[y * n + nx]
				if nk == TILE_LAND:
					y += 1
					continue
				var tid := tiles[idx]
				var run := 1
				while y + run < n and run < max_cells:
					var cidx := (y + run) * n + x
					if kinds[cidx] != TILE_LAND or tiles[cidx] != tid or kinds[(y + run) * n + nx] != nk:
						break
					run += 1
				var z0 := float(y) * ct
				var z1 := float(y + run) * ct
				var wx := float(x if dir < 0 else x + 1) * ct
				var bot := DECK_BOTTOM if nk == TILE_VOID else BANK_BOTTOM
				var rough := tile_rough[tid] if tid >= 0 and tid < tile_rough.size() else 0.95
				var bcol := _encode_color(_tile_color(tile_colors, tid).darkened(0.35), rough, 0.0)
				var uv := Vector2(0.0, KIND_GROUND)
				if dir < 0:
					_emit_solid_quad(sv, sc, su, si, Vector3(wx, 0.0, z0), Vector3(wx, 0.0, z1),
						Vector3(wx, bot, z1), Vector3(wx, bot, z0), bcol, bcol, uv)
				else:
					_emit_solid_quad(sv, sc, su, si, Vector3(wx, 0.0, z1), Vector3(wx, 0.0, z0),
						Vector3(wx, bot, z0), Vector3(wx, bot, z1), bcol, bcol, uv)
				y += run


func _mesh_entities(n: int, max_cells: int, tier: int, flat_pid: PackedInt32Array,
		ent_top: PackedColorArray, ent_side: PackedColorArray, ent_heights: PackedFloat32Array,
		ent_metal: PackedFloat32Array, ent_rough: PackedFloat32Array, ent_cat: PackedByteArray,
		ent_glow: PackedByteArray, sv: PackedVector3Array, sc: PackedColorArray,
		su: PackedVector2Array, si: PackedInt32Array) -> void:
	var cats := PackedByteArray()
	cats.resize(n * n)
	var heights := PackedFloat32Array()
	heights.resize(n * n)
	var qkeys := PackedInt32Array()
	qkeys.resize(n * n)
	var cat_count := ent_cat.size()
	var has_flags := flags.size() == n * n
	var has_flat := flat_pid.size() == n * n
	var hstep := float(HEIGHT_STEPS[clampi(tier, 0, HEIGHT_STEPS.size() - 1)])
	var has_trees := false
	var has_boxes := false
	var has_poles := false

	for i in n * n:
		var pid := protos[i]
		if pid <= 0 or pid >= cat_count:
			continue
		if has_flat and flat_pid[i] > 0:
			continue
		var cat := ent_cat[pid]
		if cat == CAT_NONE:
			continue
		if cat == CAT_POLE:
			if tier == DETAIL_FULL:
				cats[i] = CAT_POLE
				has_poles = true
			continue
		cats[i] = cat
		if cat == CAT_TREE:
			has_trees = true
			continue
		has_boxes = true
		var raw_h := ent_heights[pid] if pid < ent_heights.size() else 1.0
		var density := (int(flags[i]) & 15) if has_flags else 15
		var scaled := raw_h * (0.6 + 0.4 * float(density) / 15.0)
		var qh := 0.0
		if cat == CAT_ORE:
			qh = clampf(snappedf(scaled, 0.05), 0.10, 0.35)
		elif cat == CAT_LOW:
			qh = maxf(0.15, snappedf(scaled, 0.15))
		else:
			qh = maxf(hstep, snappedf(scaled, hstep))
		heights[i] = qh
		qkeys[i] = roundi(qh * 100.0)

	if has_boxes:
		_mesh_box_layer(n, max_cells, cats, heights, qkeys, ent_top, ent_side, ent_metal, ent_rough, ent_glow, false, sv, sc, su, si)
	if has_trees:
		if tier == DETAIL_FULL:
			_mesh_trees(n, cats, ent_top, ent_heights, ent_rough, ent_glow, sv, sc, su, si)
		else:
			_mesh_forest_blocks(n, max_cells, cats, ent_top, ent_heights, ent_rough, ent_glow, sv, sc, su, si)
	if has_poles:
		_mesh_poles(n, cats, ent_top, ent_side, ent_heights, ent_metal, ent_rough, sv, sc, su, si)


func _mesh_poles(n: int, cats: PackedByteArray, ent_top: PackedColorArray, ent_side: PackedColorArray,
		ent_heights: PackedFloat32Array, ent_metal: PackedFloat32Array, ent_rough: PackedFloat32Array,
		sv: PackedVector3Array, sc: PackedColorArray, su: PackedVector2Array, si: PackedInt32Array) -> void:
	var ct := cell_tiles
	var half := clampf(ct * 0.13, 0.18, 0.42)
	var has_flags := flags.size() == n * n
	var h_count := ent_heights.size()
	var uv := Vector2(0.0, KIND_NORMAL)
	for y in n:
		for x in n:
			var idx := y * n + x
			if cats[idx] != CAT_POLE:
				continue
			var pid := protos[idx]
			var raw_h := ent_heights[pid] if pid < h_count else 1.7
			var density := (int(flags[idx]) & 15) if has_flags else 15
			var top_h := clampf(raw_h * (0.7 + 0.3 * float(density) / 15.0), 0.9, 2.2)
			var rough := ent_rough[pid] if pid < ent_rough.size() else 0.75
			var metal := ent_metal[pid] if pid < ent_metal.size() else 0.35
			var raw_top := ent_top[pid] if pid < ent_top.size() else Color(0.03, 0.03, 0.035)
			var raw_side := ent_side[pid] if pid < ent_side.size() else raw_top * 0.72
			var tcol := _encode_color(raw_top, rough, metal)
			var scol := _encode_color(raw_side, rough, metal)
			var lx := (float(x) + 0.5) * ct
			var lz := (float(y) + 0.5) * ct
			var x0 := lx - half
			var x1 := lx + half
			var z0 := lz - half
			var z1 := lz + half
			_emit_solid_top(sv, sc, su, si, x0, z0, x1, z1, top_h, tcol, uv)
			_emit_solid_quad(sv, sc, su, si, Vector3(x1, top_h, z0), Vector3(x0, top_h, z0),
				Vector3(x0, 0.0, z0), Vector3(x1, 0.0, z0), scol, scol, uv)
			_emit_solid_quad(sv, sc, su, si, Vector3(x0, top_h, z1), Vector3(x1, top_h, z1),
				Vector3(x1, 0.0, z1), Vector3(x0, 0.0, z1), scol, scol, uv)
			_emit_solid_quad(sv, sc, su, si, Vector3(x0, top_h, z0), Vector3(x0, top_h, z1),
				Vector3(x0, 0.0, z1), Vector3(x0, 0.0, z0), scol, scol, uv)
			_emit_solid_quad(sv, sc, su, si, Vector3(x1, top_h, z1), Vector3(x1, top_h, z0),
				Vector3(x1, 0.0, z0), Vector3(x1, 0.0, z1), scol, scol, uv)


func _mesh_forest_blocks(n: int, max_cells: int, cats: PackedByteArray, ent_top: PackedColorArray,
		ent_heights: PackedFloat32Array, ent_rough: PackedFloat32Array, ent_glow: PackedByteArray,
		sv: PackedVector3Array, sc: PackedColorArray, su: PackedVector2Array, si: PackedInt32Array) -> void:
	var heights := PackedFloat32Array()
	heights.resize(n * n)
	var qkeys := PackedInt32Array()
	qkeys.resize(n * n)
	var has_flags := flags.size() == n * n
	var h_count := ent_heights.size()
	for i in n * n:
		if cats[i] != CAT_TREE:
			continue
		var pid := protos[i]
		var raw_h := ent_heights[pid] if pid < h_count else 3.5
		var density := (int(flags[i]) & 15) if has_flags else 15
		var scaled_h := raw_h * (0.65 + 0.35 * float(density) / 15.0)
		var qh := clampf(snappedf(scaled_h, 0.75), 1.25, 4.5)
		heights[i] = qh
		qkeys[i] = roundi(qh * 100.0)
	_mesh_box_layer(n, max_cells, cats, heights, qkeys, ent_top, PackedColorArray(), PackedFloat32Array(),
		ent_rough, ent_glow, true, sv, sc, su, si)


func _mesh_box_layer(n: int, max_cells: int, cats: PackedByteArray, heights: PackedFloat32Array,
		qkeys: PackedInt32Array, ent_top: PackedColorArray, ent_side: PackedColorArray,
		ent_metal: PackedFloat32Array, ent_rough: PackedFloat32Array, ent_glow: PackedByteArray,
		is_forest: bool, sv: PackedVector3Array, sc: PackedColorArray,
		su: PackedVector2Array, si: PackedInt32Array) -> void:
	var visited := PackedByteArray()
	visited.resize(n * n)
	var ct := cell_tiles
	var has_flags := flags.size() == n * n

	# Greedy 2D top faces
	for y in n:
		for x in n:
			var idx := y * n + x
			if visited[idx] != 0 or heights[idx] <= 0.0:
				continue
			var pid := protos[idx]
			var qk := qkeys[idx]
			var w := 1
			while x + w < n and w < max_cells:
				var nidx := y * n + (x + w)
				if visited[nidx] != 0 or protos[nidx] != pid or qkeys[nidx] != qk:
					break
				w += 1
			var h := 1
			while y + h < n and h < max_cells:
				var row_ok := true
				var row_base := (y + h) * n + x
				for dx in w:
					var ridx := row_base + dx
					if visited[ridx] != 0 or protos[ridx] != pid or qkeys[ridx] != qk:
						row_ok = false
						break
				if not row_ok:
					break
				h += 1
			for dy in h:
				var r := (y + dy) * n + x
				for dx in w:
					visited[r + dx] = 1

			var rough := ent_rough[pid] if pid < ent_rough.size() else (0.95 if is_forest else 0.75)
			var metal := 0.0 if is_forest else (ent_metal[pid] if pid < ent_metal.size() else 0.0)
			var dens_f := 1.0 if (is_forest or not has_flags) else clampf(float(int(flags[idx]) & 15) / 15.0, 0.2, 1.0)
			var glow := (float(ent_glow[pid]) / 3.0) * dens_f if pid < ent_glow.size() else 0.0
			var kflag := KIND_TREE if is_forest else (KIND_GROUND if cats[idx] == CAT_ORE else _box_kind(pid))
			var default_top := Color(0.16, 0.34, 0.12) if is_forest else Color(0.55, 0.55, 0.55)
			var raw_top := ent_top[pid] if pid < ent_top.size() else default_top
			var tcol := _encode_color(raw_top, rough, metal)
			_emit_solid_top(sv, sc, su, si, float(x) * ct, float(y) * ct, float(x + w) * ct, float(y + h) * ct,
				heights[idx], tcol, Vector2(glow, kflag))

	# Greedy 1D exposed walls (North/South then West/East)
	_mesh_box_walls(n, max_cells, cats, heights, qkeys, ent_top, ent_side, ent_metal, ent_rough, ent_glow,
		is_forest, true, sv, sc, su, si)
	_mesh_box_walls(n, max_cells, cats, heights, qkeys, ent_top, ent_side, ent_metal, ent_rough, ent_glow,
		is_forest, false, sv, sc, su, si)


func _mesh_box_walls(n: int, max_cells: int, cats: PackedByteArray, heights: PackedFloat32Array,
		qkeys: PackedInt32Array, ent_top: PackedColorArray, ent_side: PackedColorArray,
		ent_metal: PackedFloat32Array, ent_rough: PackedFloat32Array, ent_glow: PackedByteArray,
		is_forest: bool, is_ns: bool, sv: PackedVector3Array, sc: PackedColorArray,
		su: PackedVector2Array, si: PackedInt32Array) -> void:
	var ct := cell_tiles
	var has_flags := flags.size() == n * n
	for a in n:
		for dir: int in [-1, 1]:
			var na := a + dir
			var has_nb := na >= 0 and na < n
			var b := 0
			while b < n:
				var idx := (a * n + b) if is_ns else (b * n + a)
				var top_h := heights[idx]
				if top_h <= 0.0:
					b += 1
					continue
				var nb_idx := (na * n + b) if is_ns else (b * n + na)
				var nb_h := heights[nb_idx] if has_nb else 0.0
				if top_h <= nb_h:
					b += 1
					continue
				var pid := protos[idx]
				var qk := qkeys[idx]
				var nb_qk := qkeys[nb_idx] if has_nb else 0
				var run := 1
				while b + run < n and run < max_cells:
					var cidx := (a * n + b + run) if is_ns else ((b + run) * n + a)
					var cnb_idx := (na * n + b + run) if is_ns else ((b + run) * n + na)
					var cnb_qk := qkeys[cnb_idx] if has_nb else 0
					if protos[cidx] != pid or qkeys[cidx] != qk or cnb_qk != nb_qk:
						break
					run += 1
				var rough := ent_rough[pid] if pid < ent_rough.size() else (0.95 if is_forest else 0.75)
				var metal := 0.0 if is_forest else (ent_metal[pid] if pid < ent_metal.size() else 0.0)
				var dens_f := 1.0 if (is_forest or not has_flags) else clampf(float(int(flags[idx]) & 15) / 15.0, 0.2, 1.0)
				var glow := (float(ent_glow[pid]) / 3.0) * dens_f if pid < ent_glow.size() else 0.0
				var kflag := KIND_TREE if is_forest else (KIND_GROUND if cats[idx] == CAT_ORE else _box_kind(pid))
				var raw_side := Color(0.45, 0.45, 0.45)
				if is_forest:
					var raw_top := ent_top[pid] if pid < ent_top.size() else Color(0.16, 0.34, 0.12)
					raw_side = raw_top * 0.72
				else:
					raw_side = ent_side[pid] if pid < ent_side.size() else (ent_top[pid] if pid < ent_top.size() else Color(0.45, 0.45, 0.45))
				var scol := _encode_color(raw_side, rough, metal)
				var uv := Vector2(glow, kflag)
				var b0 := float(b) * ct
				var b1 := float(b + run) * ct
				var plane := float(a if dir < 0 else a + 1) * ct
				if is_ns:
					if dir < 0:
						_emit_solid_quad(sv, sc, su, si, Vector3(b1, top_h, plane), Vector3(b0, top_h, plane),
							Vector3(b0, nb_h, plane), Vector3(b1, nb_h, plane), scol, scol, uv)
					else:
						_emit_solid_quad(sv, sc, su, si, Vector3(b0, top_h, plane), Vector3(b1, top_h, plane),
							Vector3(b1, nb_h, plane), Vector3(b0, nb_h, plane), scol, scol, uv)
				else:
					if dir < 0:
						_emit_solid_quad(sv, sc, su, si, Vector3(plane, top_h, b0), Vector3(plane, top_h, b1),
							Vector3(plane, nb_h, b1), Vector3(plane, nb_h, b0), scol, scol, uv)
					else:
						_emit_solid_quad(sv, sc, su, si, Vector3(plane, top_h, b1), Vector3(plane, top_h, b0),
							Vector3(plane, nb_h, b0), Vector3(plane, nb_h, b1), scol, scol, uv)
				b += run


func _mesh_trees(n: int, cats: PackedByteArray, ent_top: PackedColorArray, ent_heights: PackedFloat32Array,
		ent_rough: PackedFloat32Array, ent_glow: PackedByteArray, sv: PackedVector3Array,
		sc: PackedColorArray, su: PackedVector2Array, si: PackedInt32Array) -> void:
	var ct := cell_tiles
	var has_flags := flags.size() == n * n
	for y in n:
		for x in n:
			var idx := y * n + x
			if cats[idx] != CAT_TREE:
				continue
			var pid := protos[idx]
			var lx := (float(x) + 0.5) * ct
			var lz := (float(y) + 0.5) * ct
			var wx := section_origin.x + lx
			var wz := section_origin.y + lz
			var h0 := _hash12(Vector2(wx * 0.37, wz * 0.37))
			var h1 := _hash12(Vector2(wx * 0.73 + 19.1, wz * 0.73 - 7.3))
			var h2 := _hash12(Vector2(wx * 1.13 - 41.7, wz * 1.13 + 23.9))
			var h3 := _hash12(Vector2(wx * 1.57 + 5.3, wz * 1.57 + 61.1))
			var h4 := _hash12(Vector2(wx * 2.11 - 11.9, wz * 2.11 - 31.7))

			var density := (int(flags[idx]) & 15) if has_flags else 15
			var raw_h := ent_heights[pid] if pid < ent_heights.size() else 3.5
			var y_base := 0.25
			var y_top := maxf(y_base + 0.6, raw_h * (0.65 + 0.35 * float(density) / 15.0) * (0.82 + 0.36 * h0))
			var half := ct * (0.50 + 0.08 * h2)
			var angle := h1 * (PI * 0.5)
			var ca := cos(angle)
			var sa := sin(angle)
			var ox := (h3 - 0.5) * ct * 0.16
			var oz := (h4 - 0.5) * ct * 0.16

			var base_col := ent_top[pid] if pid < ent_top.size() else Color(0.16, 0.34, 0.12)
			var col_mod := 0.86 + 0.26 * h2
			var rough := ent_rough[pid] if pid < ent_rough.size() else 0.95
			var glow := float(ent_glow[pid]) / 3.0 if pid < ent_glow.size() else 0.0
			var top_col := _encode_color(base_col * (col_mod * 1.08), rough, 0.0)
			var bot_col := _encode_color(base_col * (col_mod * 0.76), rough, 0.0)
			var uv := Vector2(glow, KIND_TREE)

			# Four rotated base corners ordered clockwise around +Y (NW -> NE -> SE -> SW)
			var r0 := Vector2(-half * ca + half * sa, -half * sa - half * ca)
			var r1 := Vector2(half * ca + half * sa, half * sa - half * ca)
			var r2 := -r0
			var r3 := -r1

			var v := sv.size()
			sv.append(Vector3(lx + ox, y_top, lz + oz))
			sv.append(Vector3(lx + r0.x, y_base, lz + r0.y))
			sv.append(Vector3(lx + r1.x, y_base, lz + r1.y))
			sv.append(Vector3(lx + r2.x, y_base, lz + r2.y))
			sv.append(Vector3(lx + r3.x, y_base, lz + r3.y))
			sc.append(top_col)
			sc.append(bot_col)
			sc.append(bot_col)
			sc.append(bot_col)
			sc.append(bot_col)
			for _k in 5:
				su.append(uv)
			si.append_array([
				v, v + 1, v + 2,
				v, v + 2, v + 3,
				v, v + 3, v + 4,
				v, v + 4, v + 1,
			])


static func _tile_color(tile_colors: PackedColorArray, tid: int) -> Color:
	return tile_colors[tid] if tid >= 0 and tid < tile_colors.size() else Color(0.35, 0.35, 0.3)


static func _encode_color(c: Color, rough: float, metal: float) -> Color:
	var rs := clampi(roundi(rough * 15.0), 0, 15)
	var ms := clampi(roundi(metal * 15.0), 0, 15)
	return Color(
		sqrt(clampf(c.r, 0.0, 1.0)),
		sqrt(clampf(c.g, 0.0, 1.0)),
		sqrt(clampf(c.b, 0.0, 1.0)),
		float(rs + 16 * ms) / 255.0
	)


static func _hash12(p: Vector2) -> float:
	var px := fposmod(p.x, 4096.0)
	var py := fposmod(p.y, 4096.0)
	var x := fposmod(px * 0.1031, 1.0)
	var y := fposmod(py * 0.1031, 1.0)
	var z := x
	var d := x * (y + 33.33) + y * (z + 33.33) + z * (x + 33.33)
	x += d
	y += d
	z += d
	return fposmod((x + y) * z, 1.0)


static func _emit_solid_top(sv: PackedVector3Array, sc: PackedColorArray, su: PackedVector2Array,
		si: PackedInt32Array, x0: float, z0: float, x1: float, z1: float, y: float,
		col: Color, uv: Vector2) -> void:
	var v := sv.size()
	sv.append(Vector3(x0, y, z0))
	sv.append(Vector3(x1, y, z0))
	sv.append(Vector3(x1, y, z1))
	sv.append(Vector3(x0, y, z1))
	sc.append(col)
	sc.append(col)
	sc.append(col)
	sc.append(col)
	su.append(uv)
	su.append(uv)
	su.append(uv)
	su.append(uv)
	si.append(v)
	si.append(v + 1)
	si.append(v + 2)
	si.append(v)
	si.append(v + 2)
	si.append(v + 3)


static func _emit_solid_quad(sv: PackedVector3Array, sc: PackedColorArray, su: PackedVector2Array,
		si: PackedInt32Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		col_top: Color, col_bot: Color, uv: Vector2) -> void:
	var v := sv.size()
	sv.append(a)
	sv.append(b)
	sv.append(c)
	sv.append(d)
	sc.append(col_top)
	sc.append(col_top)
	sc.append(col_bot)
	sc.append(col_bot)
	su.append(uv)
	su.append(uv)
	su.append(uv)
	su.append(uv)
	si.append(v)
	si.append(v + 1)
	si.append(v + 2)
	si.append(v)
	si.append(v + 2)
	si.append(v + 3)


static func _emit_water_top(wv: PackedVector3Array, wc: PackedColorArray, wi: PackedInt32Array,
		x0: float, z0: float, x1: float, z1: float, y: float, col: Color) -> void:
	var v := wv.size()
	wv.append(Vector3(x0, y, z0))
	wv.append(Vector3(x1, y, z0))
	wv.append(Vector3(x1, y, z1))
	wv.append(Vector3(x0, y, z1))
	wc.append(col)
	wc.append(col)
	wc.append(col)
	wc.append(col)
	wi.append(v)
	wi.append(v + 1)
	wi.append(v + 2)
	wi.append(v)
	wi.append(v + 2)
	wi.append(v + 3)


## A box's kind flag: KIND_CLIFF for Factorio's cliffs (the palette's ent_seat), else KIND_NORMAL.
func _box_kind(pid: int) -> float:
	return KIND_CLIFF if pid > 0 and pid < _seat.size() and _seat[pid] != 0 else KIND_NORMAL


# --- section grid sampling (distant_horizon.gd's _sample_section_grid, on the worker) ----------

## The section grid (n x n cells) from its chunks' tile, entity and flag rows: [tiles, protos, flags,
## chunk_mask]. The same cells as distant_horizon.gd `_sample_section_grid` (kept there for
## --dh-sample-worker=off); `src` as `sample_src`. Pure: reads only its arguments, so it runs on a worker.
static func sample_grid(n: int, sec_chunks: int, cell_tiles: float, level: int, ent_cat: PackedByteArray,
		src: Array, side: int) -> Array:
	var total := n * n
	var out_tiles := PackedInt32Array()
	out_tiles.resize(total)
	out_tiles.fill(-1)
	var out_protos := PackedInt32Array()
	out_protos.resize(total)
	var out_flags := PackedByteArray()
	out_flags.resize(total)
	var chunk_mask := 0
	const CHUNK := 32
	if cell_tiles <= float(CHUNK):
		var cells_per_chunk := maxi(1, roundi(float(CHUNK) / cell_tiles))
		for cy_off in sec_chunks:
			for cx_off in sec_chunks:
				var slot := cy_off * side + cx_off
				if cx_off >= side or cy_off >= side or src[slot] == null:
					continue
				var row: Array = src[slot]
				var ctiles: PackedInt32Array = row[0]
				var cprotos: PackedInt32Array = row[1]
				var cflags: PackedByteArray = row[2]
				var src_side := roundi(sqrt(float(ctiles.size())))
				if src_side <= 0:
					continue
				if level == 0:
					chunk_mask |= 1 << (cy_off * 4 + cx_off)
				if src_side <= cells_per_chunk:
					for ly in cells_per_chunk:
						var sy_src := mini(src_side - 1, (ly * src_side) / cells_per_chunk)
						var dst_row := (cy_off * cells_per_chunk + ly) * n + cx_off * cells_per_chunk
						var src_row := sy_src * src_side
						for lx in cells_per_chunk:
							var si := src_row + mini(src_side - 1, (lx * src_side) / cells_per_chunk)
							var di := dst_row + lx
							out_tiles[di] = ctiles[si]
							if si < cprotos.size():
								out_protos[di] = cprotos[si]
							if si < cflags.size():
								out_flags[di] = cflags[si]
				else:
					var block := maxi(1, src_side / cells_per_chunk)
					var tcounts := {}
					for ly in cells_per_chunk:
						var dst_row := (cy_off * cells_per_chunk + ly) * n + cx_off * cells_per_chunk
						for lx in cells_per_chunk:
							var di := dst_row + lx
							var first_tile := -1
							var first_count := 0
							var uniform := true
							var best_tile := -1
							var best_pid := 0
							var best_prio := -1
							var best_flag := 0
							var y_start := ly * block
							var x_start := lx * block
							for by in range(y_start, mini(src_side, y_start + block)):
								for bx in range(x_start, mini(src_side, x_start + block)):
									var si := by * src_side + bx
									var tid := ctiles[si]
									if tid >= 0:
										if uniform:
											if first_tile < 0:
												first_tile = tid
												first_count = 1
												best_tile = tid
											elif tid == first_tile:
												first_count += 1
											else:
												uniform = false
												tcounts.clear()
												tcounts[first_tile] = first_count
												best_tile = _majority_tile(tcounts, best_tile, tid)
										else:
											best_tile = _majority_tile(tcounts, best_tile, tid)
									if si < cprotos.size():
										var pid := cprotos[si]
										if pid > 0:
											var prio := cat_priority(ent_cat, pid)
											if prio > best_prio:
												best_prio = prio
												best_pid = pid
												best_flag = cflags[si] if si < cflags.size() else 15
							out_tiles[di] = best_tile
							out_protos[di] = best_pid
							out_flags[di] = best_flag
	else:
		var chunks_per_cell := maxi(1, roundi(cell_tiles / float(CHUNK)))
		var tcounts := {}
		for gy in n:
			for gx in n:
				var di := gy * n + gx
				var first_tile := -1
				var first_count := 0
				var uniform := true
				var best_tile := -1
				var best_pid := 0
				var best_prio := -1
				var best_flag := 0
				for dy in chunks_per_cell:
					for dx in chunks_per_cell:
						var ox := gx * chunks_per_cell + dx
						var oy := gy * chunks_per_cell + dy
						if ox >= side or oy >= side or src[oy * side + ox] == null:
							continue
						var row: Array = src[oy * side + ox]
						var ctiles: PackedInt32Array = row[0]
						var cprotos: PackedInt32Array = row[1]
						var cflags: PackedByteArray = row[2]
						var csize := ctiles.size()
						var step := maxi(1, csize / 16)
						var si := 0
						while si < csize:
							var tid := ctiles[si]
							if tid >= 0:
								if uniform:
									if first_tile < 0:
										first_tile = tid
										first_count = 1
										best_tile = tid
									elif tid == first_tile:
										first_count += 1
									else:
										uniform = false
										tcounts.clear()
										tcounts[first_tile] = first_count
										best_tile = _majority_tile(tcounts, best_tile, tid)
								else:
									best_tile = _majority_tile(tcounts, best_tile, tid)
							if si < cprotos.size():
								var pid := cprotos[si]
								if pid > 0:
									var prio := cat_priority(ent_cat, pid)
									if prio > best_prio:
										best_prio = prio
										best_pid = pid
										best_flag = cflags[si] if si < cflags.size() else 15
							si += step
				out_tiles[di] = best_tile
				out_protos[di] = best_pid
				out_flags[di] = best_flag
	return [out_tiles, out_protos, out_flags, chunk_mask]


## As distant_horizon.gd `_pick_majority_tile`.
static func _majority_tile(tcounts: Dictionary, best_tile: int, tid: int) -> int:
	if tid < 0:
		return best_tile
	var cnt := int(tcounts.get(tid, 0)) + 1
	tcounts[tid] = cnt
	if best_tile < 0:
		return tid
	var best_cnt := int(tcounts.get(best_tile, 0))
	if cnt > best_cnt:
		return tid
	if cnt == best_cnt:
		if best_tile <= 0 and tid > 0:
			return tid
		if (tid > 0 or best_tile <= 0) and tid < best_tile:
			return tid
	return best_tile


## As distant_horizon.gd `_cat_priority`: which entity wins a cell (buildings and cliffs first).
static func cat_priority(ent_cat: PackedByteArray, pid: int) -> int:
	if pid <= 0 or pid >= ent_cat.size():
		return 0
	var c := ent_cat[pid]
	match c:
		CAT_BUILDING, CAT_CLIFF:
			return 4
		CAT_TREE:
			return 3
		CAT_LOW:
			return 2
		CAT_ORE:
			return 1
	return 0
