extends Node
## Far chunks merged (hierarchical LOD, docs/PERFORMANCE-PLAN.md 2). Past MERGE_FROM tiles from the
## camera a chunk's buildings are drawn as one mesh of one surface instead of a MultiMesh per model,
## per moving part and per surface (models average six surfaces, each a draw, and the shadow pass
## draws them again per split): one draw, one engine object, no moving parts. It is built on worker
## threads from each model simplified once as a whole, with the colour its materials would give each
## vertex baked in (Bake), and drawn with one shared material (far_merged.gdshader). Where the chunk's
## shadows can reach the view (world.gd's shadow tiers) the same mesh casts them.
##
## Building-like entities merge into one shared mesh (`far_merged`); trees and plants merge into
## their trunks plus an opaque puff/clustered crown surface (`far_tree_crown`, unless
## `--far-trees=off`). Ore, fish, train stops, nests and worms (moved in the shader or keeping
## their own colours/thinning) keep their MultiMeshes (KEEP_TYPES). Picking, ghosts, wires, alerts
## and the fog read world.gd's records or hide whole chunks, so they don't change.
##
## A chunk going far keeps its MultiMeshes until its merged mesh is made, then hides them (nothing is
## built); coming near again it shows them, unless something in it changed meanwhile (a build lets
## them go): then they are made again within world.gd's frame budget and the merged mesh goes once
## they are all in. A chunk first seen far isn't built in full until it comes near.

const ModelLibrary := preload("res://scripts/world/model_library.gd")
const Probing := preload("res://scripts/debug/probing.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const MaterialRows := preload("res://scripts/world/material_rows.gd")
const ModelTextures := preload("res://scripts/world/model_textures.gd")
const Looks := preload("res://scripts/world/looks.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const BeltLods := preload("res://scripts/world/belt_lods.gd")
const FrameBudget := preload("res://scripts/world/frame_budget.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const SpriteStandins := preload("res://scripts/world/sprite_standins.gd")
const MergedShader := preload("res://shaders/far_merged.gdshader")
const CrownShader := preload("res://shaders/far_tree_crown.gdshader")
const FactorioAlphaShader := preload("res://shaders/factorio_material_alpha.gdshader")
const FactorioLeafShader := preload("res://shaders/factorio_material_leaf.gdshader")
const LEAF_MEAN := 0.85

const CHUNK := 32
## A chunk is merged once its nearest point is this far from the camera (tiles), or the sun's shadow
## distance if that is further (past it shadows fade out, so the simpler shapes casting them don't
## show), but no further than MERGE_CAP, and drawn in full again once nearer than that less SLACK.
const MERGE_FROM := 128.0
## The furthest the shadow distance pushes the merge out (tiles): with Settings > Graphics > Shadow
## distance at 400 the fitted distance ran to 250-400 zoomed out, so nothing in view was merged there.
## Between the cap and the shadows' end a merged chunk casts the merged mesh's shadow, simplified by
## a pixel or two there (CELL). --far-merge-cap=<tiles> sets it, 0 as before 0.2.1 (no cap).
const MERGE_CAP := 192.0
const SLACK := 24.0
## Chunks within this distance of the focus (tiles) are always drawn in full: the character's
## surroundings animate and are what the player works on, however far the camera is pulled back.
const NEAR_FOCUS := 40.0
## Entity types left to their own MultiMeshes in far chunks (trees and plants also kept when --far-trees=off).
const KEEP_TYPES := {"train-stop": true, "resource": true, "fish": true, "unit-spawner": true,
	"turret": true, "spider-leg": true}
static var far_trees := not ("--far-trees=off" in OS.get_cmdline_user_args())
## How simple each model is merged (tiles): the simplifier's coarsest level within SIMPLIFY_ERROR, then
## its vertices clustered in CELL-sized cubes (Bake): about two pixels at MERGE_FROM in a 900-pixel
## window. Times the square root of the Level of detail setting's pixels of error (model_lods.gd
## QUALITY's first values, 1, 4 and 4: high 1, medium and low 2), as set when a model is first merged.
const SIMPLIFY_ERROR := 0.25
const CELL := 0.2
## Worker jobs at once: models baked and chunks merged (the pool also meshes terrain and loads models).
const BAKE_JOBS := 2
const MERGE_JOBS := 2
## Seconds between looks at which chunks are far (sooner when the camera moved 8 tiles). Gathering
## far chunks' entities and putting finished merges in take their slices of the frame
## (frame_budget.gd, `far_collect` and `far_install`).
const CHECK_INTERVAL := 0.5

## Where a chunk's merge stands (State.phase).
enum { IDLE, ASKED, GATHERING, WAITING, MERGING }

## Settings > Graphics > Merge far buildings.
var enabled := true
## --far-merge-from=<tiles>: merge from this distance instead (screenshots of merged buildings up close).
var merge_from := 0.0
var merge_cap := MERGE_CAP
var world  # world.gd

## Per mesh: its Bake (done or not), and whether it can be merged at all (0 no, 1 solid, 2 has leaf surface).
static var _bakes := {}
static var _bakeable := {}
static var _material: ShaderMaterial
static var _crown_material: ShaderMaterial
static var _nature_material: ShaderMaterial
## Chunks whose builds asked for a merge (built()), taken in by _collect.
static var _asked: Array = []

var _check_timer := CHECK_INTERVAL
var _last_camera := Vector3.INF
var _last_enabled := true
var _far_count := 0
## [ChunkView, serial] being gathered, gathered and waiting for their models' bakes; merges running
## [task id, Merge, ChunkView]; bakes running [task id, Bake] and waiting.
var _collecting: Array = []
var _waiting: Array = []
var _merging: Array = []
var _baking: Array = []
var _bake_queue: Array = []
## Bakes finished and chunks gathered so far, and as last looked at.
var _progress := 0
var _stamp := -1
## Main-thread and worker time spent (for the probe).
var main_usec := 0
var worker_usec := 0


## What a chunk's merged drawing stands at (ChunkView.far).
class State:
	## Wanted merged (far from the camera).
	var far := false
	## The merged mesh stands for the chunk's mergeable entities: its builds leave them out.
	var covers := false
	## Those entities have MultiMeshes now (the last build didn't leave them out): drawn, or hidden
	## (`hidden`) while the merged mesh stands for them, to be shown again without a build if the
	## chunk comes near before anything in it changes.
	var full := false
	var hidden: Array = []
	var phase := IDLE
	## Goes up with every new merge asked for: work of an older serial is dropped.
	var serial := 0
	var node: MeshInstance3D
	var triangles := 0
	## Gathering: the entities still to look at and the next one.
	var recs: Array = []
	var next := 0
	## Gathered: Mesh -> Array of Transform3D, and placeholders [Mesh, Transform3D, Color].
	var groups := {}
	var tinted: Array = []
	## Meshes of trees and plants (their solid parts merge into a surface of their own, matte: far_merged_nature).
	var nature := {}
	## In the merged mesh: Mesh -> instances, and whether it has placeholders.
	var counts := {}
	var placeholders := false
	## Looked at while waiting and found models not baked yet.
	var checked := false
	var cast := GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## A model baked for merging, once per model on a worker thread: all its surfaces as one, with the
## colour each vertex is drawn in baked in (as factorio_material.gdshaderinc works it out: part colour
## or palette, the model's tint, greying, baked occlusion), simplified as a whole (welded positions,
## so parts and surfaces collapse together, which the models' own per-surface LODs can't), each
## simplified corner taking the model's own vertex there whose normal fits best (as model_lods.gd);
## then clustered: vertices in a CELL-sized cube become one, at their average place and colour, and
## triangles left with no area go. That last step is what brings walls of separate bricks, lattice
## poles and ties of rails down: the simplifier keeps every separate piece.
class Bake:
	## Per surface: [vertices, normals, COLOR, CUSTOM1, indices, params per row ({} leaves the row
	## out), each vertex's row (CUSTOM2) or null with one row, UV (textured models)]
	var surfaces: Array = []
	## Crown surfaces (`factorio_material_leaf`): same layout plus [8] leaf_core flag.
	var crown_surfaces: Array = []
	var leaf_tints := PackedVector3Array()
	var simplify_error := SIMPLIFY_ERROR
	var cell := CELL
	var crown_cell := 1.5
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var crown_verts := PackedVector3Array()
	var crown_colors := PackedColorArray()
	var crown_indices := PackedInt32Array()
	var done := false
	var usec := 0
	## Packs' own shading as it was when this was baked (Looks.packs_shade): a "pbr" pack's colours differ.
	var shading := true

	func run() -> void:
		var t0 := Time.get_ticks_usec()
		if not surfaces.is_empty():
			var all_verts := PackedVector3Array()
			var all_normals := PackedVector3Array()
			var all_colors := PackedColorArray()
			var all_idx := PackedInt32Array()
			for s: Array in surfaces:
				_surface(s, all_verts, all_normals, all_colors, all_idx)
			surfaces = []
			var idx := all_idx
			for level: Array in _levels(all_verts, all_normals, all_idx):
				if float(level[0]) <= simplify_error:
					idx = level[1]
			var clustered := _cluster_into(all_verts, all_colors, idx, cell)
			verts = clustered[0]
			colors = clustered[1]
			indices = clustered[2]
		if not crown_surfaces.is_empty():
			_bake_crown()
			crown_surfaces = []
		usec = Time.get_ticks_usec() - t0

	## Clusters `src` vertices by `cluster_cell` and drops degenerate/duplicate triangles -> [verts, colors, indices].
	static func _cluster_into(src: PackedVector3Array, cols: PackedColorArray, idx: PackedInt32Array, cluster_cell: float) -> Array:
		var out_verts := PackedVector3Array()
		var out_colors := PackedColorArray()
		var out_indices := PackedInt32Array()
		var map := PackedInt32Array()
		map.resize(src.size())
		map.fill(-1)
		var of_cell := {}
		var sums := PackedVector3Array()
		var tints := PackedVector3Array()
		var alphas := PackedFloat32Array()
		var counts := PackedInt32Array()
		for k in idx:
			if map[k] >= 0:
				continue
			var key = Vector3i((src[k] / cluster_cell).floor()) if cluster_cell > 0.0 else k
			var at: int = of_cell.get(key, -1)
			if at < 0:
				at = counts.size()
				of_cell[key] = at
				sums.append(Vector3.ZERO)
				tints.append(Vector3.ZERO)
				alphas.append(cols[k].a)
				counts.append(0)
			map[k] = at
			sums[at] += src[k]
			tints[at] += Vector3(cols[k].r, cols[k].g, cols[k].b)
			counts[at] += 1
		# Triangles left with area, each once (keeping its winding: both sides of a plate stay).
		var used := PackedInt32Array()
		used.resize(counts.size())
		used.fill(-1)
		var seen := {}
		for t in range(0, idx.size() - 2, 3):
			var a := map[idx[t]]
			var b := map[idx[t + 1]]
			var c := map[idx[t + 2]]
			if a == b or b == c or a == c:
				continue
			var key := Vector3i(a, b, c) if a < b and a < c else (Vector3i(b, c, a) if b < c else Vector3i(c, a, b))
			if seen.has(key):
				continue
			seen[key] = true
			for v in [a, b, c]:
				if used[v] < 0:
					used[v] = out_verts.size()
					var n := float(counts[v])
					out_verts.append(sums[v] / n)
					var rgb := tints[v] / n
					out_colors.append(Color(rgb.x, rgb.y, rgb.z, alphas[v]))
				out_indices.append(used[v])
		return [out_verts, out_colors, out_indices]

	## Bakes tree crowns into closed opaque low-poly octahedron puffs (for leaf cards) or clustered
	## simplified geometry (for solid-leaf crowns like tree-06), storing pc in COLOR.a directly.
	func _bake_crown() -> void:
		var cards_by_key := {}
		var solid_verts := PackedVector3Array()
		var solid_normals := PackedVector3Array()
		var solid_colors := PackedColorArray()
		var solid_idx := PackedInt32Array()
		for s: Array in crown_surfaces:
			var sv := PackedVector3Array()
			var sn := PackedVector3Array()
			var sc := PackedColorArray()
			var si := PackedInt32Array()
			_surface(s, sv, sn, sc, si)
			var uvs := PackedVector2Array()
			if s.size() > 7 and s[7] is PackedVector2Array and (s[7] as PackedVector2Array).size() == sv.size():
				uvs = s[7]
			var all_core := bool(s[8]) if s.size() > 8 else false
			var solid_base := solid_verts.size()
			var used_solid := false
			for t in range(0, si.size() - 2, 3):
				var i0 := si[t]
				var i1 := si[t + 1]
				var i2 := si[t + 2]
				if not all_core and uvs.size() == sv.size() and uvs[i0].x >= -0.5:
					var p0 := sv[i0]
					var p1 := sv[i1]
					var p2 := sv[i2]
					var mid := (p0 + p1 + p2) / 3.0
					var half := (p1 - p0).length() * 0.35
					var d1 := uvs[i1] - uvs[i0]
					var d2 := uvs[i2] - uvs[i0]
					var det := d1.x * d2.y - d1.y * d2.x
					if absf(det) > 1e-8:
						var ax := ((p1 - p0) * d2.y - (p2 - p0) * d1.y) / det
						var ay := ((p2 - p0) * d1.x - (p1 - p0) * d2.x) / det
						mid = p0 - ax * (uvs[i0].x - 0.5) - ay * (uvs[i0].y - 0.5)
						half = 0.5 * ax.length()
					var rgb := Vector3.ZERO
					var pc_sum := 0.0
					for vi in [i0, i1, i2]:
						var c := sc[vi]
						rgb += Vector3(c.r * c.r, c.g * c.g, c.b * c.b)
						pc_sum += float(roundi(c.a * 255.0) & 15) / 15.0
					var key := Vector3i((mid * 200.0).round())
					if not cards_by_key.has(key):
						cards_by_key[key] = [mid, rgb / 3.0, pc_sum / 3.0, half, 1]
					else:
						var entry: Array = cards_by_key[key]
						entry[0] = (entry[0] as Vector3) + mid
						entry[1] = (entry[1] as Vector3) + rgb / 3.0
						entry[2] = float(entry[2]) + pc_sum / 3.0
						entry[3] = float(entry[3]) + half
						entry[4] = int(entry[4]) + 1
				else:
					if not used_solid:
						solid_verts.append_array(sv)
						solid_normals.append_array(sn)
						solid_colors.append_array(sc)
						used_solid = true
					solid_idx.append_array([i0 + solid_base, i1 + solid_base, i2 + solid_base])
		if not cards_by_key.is_empty():
			var lo := Vector3(INF, INF, INF)
			var hi := -lo
			var cards: Array = []
			for key in cards_by_key:
				var e: Array = cards_by_key[key]
				var n := float(e[4])
				var center := (e[0] as Vector3) / n
				var col_lin := ((e[1] as Vector3) / n) * LEAF_MEAN
				cards.append([center, col_lin, float(e[2]) / n, float(e[3]) / n])
				lo = lo.min(center)
				hi = hi.max(center)
			var span := hi - lo
			var step := maxf(maxf(span.x, maxf(span.y, span.z)) * 0.30, crown_cell)
			var buckets := {}
			for card: Array in cards:
				var ck := Vector3i(((card[0] as Vector3) / step).floor())
				if not buckets.has(ck):
					buckets[ck] = []
				(buckets[ck] as Array).append(card)
			var kept_keys: Array = []
			if buckets.size() <= 6:
				kept_keys = buckets.keys()
			else:
				for ck: Vector3i in buckets:
					if (buckets[ck] as Array).size() >= 4:
						kept_keys.append(ck)
				if kept_keys.is_empty():
					kept_keys = buckets.keys()
			for ck: Vector3i in kept_keys:
				var list: Array = buckets[ck]
				var blo := Vector3(INF, INF, INF)
				var bhi := -blo
				var col_sum := Vector3.ZERO
				var pc_total := 0.0
				var half_total := 0.0
				for card: Array in list:
					var cp: Vector3 = card[0]
					blo = blo.min(cp)
					bhi = bhi.max(cp)
					col_sum += card[1] as Vector3
					pc_total += float(card[2])
					half_total += float(card[3])
				var cnt := float(list.size())
				var mid := (blo + bhi) * 0.5
				var pad := maxf((half_total / cnt) * 0.75, 0.35)
				var rx := (bhi.x - blo.x) * 0.5 + pad
				var ry := (bhi.y - blo.y) * 0.5 + pad
				var rz := (bhi.z - blo.z) * 0.5 + pad
				var yaw := float(((ck.x * 73856093) ^ (ck.y * 19349663) ^ (ck.z * 83492791)) & 255) / 256.0 * 0.7854
				_emit_puff(mid, rx, ry, rz, yaw, col_sum / cnt, pc_total / cnt)
		elif not solid_idx.is_empty():
			var idx := solid_idx
			for level: Array in _levels(solid_verts, solid_normals, solid_idx):
				if float(level[0]) <= simplify_error:
					idx = level[1]
			var clustered := _cluster_into(solid_verts, solid_colors, idx, maxf(cell, 0.35))
			crown_verts = clustered[0]
			var cc: PackedColorArray = clustered[1]
			for k in cc.size():
				cc[k].a = float(roundi(cc[k].a * 255.0) & 15) / 15.0
			crown_colors = cc
			crown_indices = clustered[2]

	static func _sqrt_color(rgb: Vector3, factor: float, alpha: float) -> Color:
		return Color(sqrt(clampf(rgb.x * factor, 0.0, 1.0)), sqrt(clampf(rgb.y * factor, 0.0, 1.0)),
			sqrt(clampf(rgb.z * factor, 0.0, 1.0)), clampf(alpha, 0.0, 1.0))

	func _emit_puff(mid: Vector3, rx: float, ry: float, rz: float, yaw: float, rgb: Vector3, pc: float) -> void:
		var base := crown_verts.size()
		var c := cos(yaw)
		var s := sin(yaw)
		crown_verts.append_array([
			mid + Vector3(0.0, ry, 0.0),
			mid + Vector3(0.0, -ry, 0.0),
			mid + Vector3(rx * c, 0.0, rx * s),
			mid + Vector3(-rz * s, 0.0, rz * c),
			mid + Vector3(-rx * c, 0.0, -rx * s),
			mid + Vector3(rz * s, 0.0, -rz * c),
		])
		var top_col := _sqrt_color(rgb, 1.08, pc)
		var mid_col := _sqrt_color(rgb, 1.0, pc)
		var bot_col := _sqrt_color(rgb, 0.78, pc)
		crown_colors.append_array([top_col, bot_col, mid_col, mid_col, mid_col, mid_col])
		crown_indices.append_array([
			base, base + 2, base + 3,
			base, base + 3, base + 4,
			base, base + 4, base + 5,
			base, base + 5, base + 2,
			base + 1, base + 3, base + 2,
			base + 1, base + 4, base + 3,
			base + 1, base + 5, base + 4,
			base + 1, base + 2, base + 5,
		])

	## [[error, indices into the model's own vertices], ...], finest first, from Godot's simplifier
	## over the welded positions; [] for a model too small to bother.
	static func _levels(src: PackedVector3Array, src_normals: PackedVector3Array, idx: PackedInt32Array) -> Array:
		if idx.size() / 3 < ModelLods.MIN_TRIANGLES:
			return []
		var welded := ModelLods.ModelLodsMath.weld([[src, src_normals, idx]])
		var wv: PackedVector3Array = welded[0]
		var wi: PackedInt32Array = welded[1]
		var remap: PackedInt32Array = welded[2]
		var owners: Array = []
		owners.resize(wv.size())
		for k in remap.size():
			if owners[remap[k]] == null:
				owners[remap[k]] = []
			(owners[remap[k]] as Array).append(k)
		var sign := ModelLods.ModelLodsMath.winding(src, src_normals, idx)
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = wv
		arrays[Mesh.ARRAY_NORMAL] = ModelLods.ModelLodsMath.smooth_normals(wv, wi, sign)
		arrays[Mesh.ARRAY_INDEX] = wi
		var im := ImporterMesh.new()
		im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays)
		im.generate_lods(180.0, 180.0, [])
		var out: Array = []
		for l in im.get_surface_lod_count(0):
			var lod := im.get_surface_lod_indices(0, l)
			var mapped := PackedInt32Array()
			mapped.resize(lod.size())
			for t in range(0, lod.size() - 2, 3):
				var face := (wv[lod[t + 1]] - wv[lod[t]]).cross(wv[lod[t + 2]] - wv[lod[t]]) * sign
				for k in 3:
					var choices: Array = owners[lod[t + k]]
					var best: int = choices[0]
					if choices.size() > 1:
						var best_fit := -INF
						for v: int in choices:
							var fit := src_normals[v].dot(face)
							if fit > best_fit:
								best_fit = fit
								best = v
					mapped[t + k] = best
			out.append([im.get_surface_lod_size(0, l), mapped])
		out.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
		return out

	## One surface's vertices, normals, colours and indices onto the model's.
	static func _surface(s: Array, all_verts: PackedVector3Array, all_normals: PackedVector3Array, all_colors: PackedColorArray,
			all_idx: PackedInt32Array) -> void:
		var src: PackedVector3Array = s[0]
		var n := src.size()
		var base := all_verts.size()
		all_verts.append_array(src)
		if s[1] is PackedVector3Array and (s[1] as PackedVector3Array).size() == n:
			all_normals.append_array(s[1])
		else:
			for k in n:
				all_normals.append(Vector3.UP)
		var params: Array = s[5]
		var rows := PackedFloat32Array()
		if s[6] is PackedFloat32Array and (s[6] as PackedFloat32Array).size() == n:
			rows = s[6]
		var last := params.size() - 1
		if s[4] is PackedInt32Array and not (s[4] as PackedInt32Array).is_empty():
			var idx: PackedInt32Array = s[4]
			for t in range(0, idx.size() - 2, 3):
				# A row left out (see-through light that fades away) drops its triangles.
				if (params[clampi(int(rows[idx[t]]), 0, last) if not rows.is_empty() else 0] as Dictionary).is_empty():
					continue
				all_idx.append(idx[t] + base)
				all_idx.append(idx[t + 1] + base)
				all_idx.append(idx[t + 2] + base)
		else:
			for k in range(0, n - 2, 3):
				if (params[clampi(int(rows[k]), 0, last) if not rows.is_empty() else 0] as Dictionary).is_empty():
					continue
				all_idx.append(k + base)
				all_idx.append(k + 1 + base)
				all_idx.append(k + 2 + base)
		var vcol := PackedColorArray()
		if s[2] is PackedColorArray and (s[2] as PackedColorArray).size() == n:
			vcol = s[2]
		var c1 := PackedFloat32Array()
		if s[3] is PackedFloat32Array and (s[3] as PackedFloat32Array).size() == n * 4:
			c1 = s[3]
		var row := -1
		var albedo: Color
		var tint: Color
		var part_share := 0.0
		var tinted := false
		var desaturate := 0.0
		var value := 1.0
		var ao_strength := 1.0
		var light := 1.0
		var metallic := 0.0
		var pbr := false
		var pbr_light := Looks.TEXTURE_LIGHT
		var normals := PackedVector3Array()
		if s[1] is PackedVector3Array and (s[1] as PackedVector3Array).size() == n:
			normals = s[1]
		# A textured model (never merged, so one row): each vertex takes its texture's colour round it
		# (a small copy of it, _texture_colours).
		var tex: Image = (params[0] as Dictionary).get("tex")
		var tex_rgb := PackedVector3Array()
		if tex != null and s.size() > 7 and s[7] is PackedVector2Array and (s[7] as PackedVector2Array).size() == n:
			tex_rgb = _texture_colours(tex, s[7], s[4] if s[4] is PackedInt32Array and not (s[4] as PackedInt32Array).is_empty() else null)
		for v in n:
			var r := clampi(int(rows[v]), 0, last) if not rows.is_empty() else 0
			if r != row:
				row = r
				var p: Dictionary = params[r]
				if p.is_empty():
					p = params.filter(func(q: Dictionary) -> bool: return not q.is_empty())[0]  # unused vertices
				albedo = p["albedo"]
				tint = p["tint"]
				part_share = float(p["part_data"]) if bool(p["part_colors"]) else 0.0
				tinted = float(p["vertex_data"]) > 0.5 and not vcol.is_empty()
				desaturate = p["desaturate"]
				value = p["value"]
				ao_strength = p["ao_strength"]
				light = p["light"]
				metallic = p["metallic"]
				pbr = bool(p.get("pbr", false))
				pbr_light = p.get("pbr_light", Looks.TEXTURE_LIGHT)
			var rgb := Vector3(albedo.r, albedo.g, albedo.b)
			var pc := 0.0
			if not tex_rgb.is_empty():
				rgb *= tex_rgb[v]
				pc = 1.0
			elif pbr:
				# A "pbr" pack's material without a picture: its factor as the file says, no part colours.
				pc = 1.0
			elif part_share > 0.0 and not c1.is_empty():
				# Part colours are kept with headroom (rgb / 4, share * 0.25) unless the share is above 0.25.
				var a := c1[v * 4 + 3]
				var headroom := a <= 0.2501
				pc = clampf(a / 0.25 if headroom else a, 0.0, 1.0) * part_share
				rgb = rgb.lerp(Vector3(c1[v * 4], c1[v * 4 + 1], c1[v * 4 + 2]) * (4.0 if headroom else 1.0), pc)
			var ao := 1.0
			if tinted:
				var c := vcol[v]
				rgb *= Vector3(c.r, c.g, c.b)
				ao = c.a
			rgb *= Vector3(tint.r, tint.g, tint.b)
			var lum := rgb.dot(Vector3(0.299, 0.587, 0.114))
			rgb = rgb.lerp(Vector3(lum, lum, lum), desaturate * (1.0 - pc)) * lerpf(value, 1.0, pc)
			# As the model shader shades it (a strength above 1 is a power: textured models).
			var shade := pow(ao, ao_strength) if ao_strength > 1.0 else lerpf(1.0, ao, ao_strength)
			rgb *= lerpf(1.0, shade, 0.65) * light
			var metal := clampf(metallic * lerpf(1.0, 0.1, pc), 0.0, 1.0)
			if pbr and pc > 0.0:
				# A "pbr" pack's picture (the near shader's modeller_tex): no part colour balance in the far
				# shader (pc 0), the look's texture_light baked in by the way the vertex faces instead.
				var up := clampf(normals[v].y, 0.0, 1.0) if not normals.is_empty() else 1.0
				rgb *= lerpf(pbr_light.x, pbr_light.y, up)
				pc = 0.0
			var packed := float(roundi(pc * 15.0) + 16 * roundi(metal * 15.0)) / 255.0
			all_colors.append(Color(sqrt(clampf(rgb.x, 0.0, 1.0)), sqrt(clampf(rgb.y, 0.0, 1.0)), sqrt(clampf(rgb.z, 0.0, 1.0)), packed))


	## Each vertex's texture colour (linear) as the faces round it show it: sampled inside each face
	## using the vertex, half way to the face's middle in UV, and at the middle, averaged. A corner's
	## own texel lies on its UV island's edge, often in the atlas's padding between islands, and one
	## texel stood for the whole face a far model draws in a pixel or two.
	static func _texture_colours(tex: Image, uv: PackedVector2Array, idx: Variant) -> PackedVector3Array:
		var n := uv.size()
		var sums := PackedVector3Array()
		sums.resize(n)
		var counts := PackedInt32Array()
		counts.resize(n)
		var count: int = (idx as PackedInt32Array).size() if idx != null else n
		for t in range(0, count - 2, 3):
			var a: int = idx[t] if idx != null else t
			var b: int = idx[t + 1] if idx != null else t + 1
			var c: int = idx[t + 2] if idx != null else t + 2
			var middle := (uv[a] + uv[b] + uv[c]) / 3.0
			var at_middle := _texel(tex, middle)
			for v: int in [a, b, c]:
				sums[v] += (_texel(tex, uv[v].lerp(middle, 0.5)) + at_middle) * 0.5
				counts[v] += 1
		for v in n:
			sums[v] = sums[v] / float(counts[v]) if counts[v] > 0 else _texel(tex, uv[v])
		return sums

	static func _texel(tex: Image, at: Vector2) -> Vector3:
		var w := tex.get_width()
		var h := tex.get_height()
		var c := tex.get_pixel(posmod(int(floor(at.x * w)), w), posmod(int(floor(at.y * h)), h)).srgb_to_linear()
		return Vector3(c.r, c.g, c.b)


## A chunk's merged mesh, made on a worker thread: every instance's baked model moved into place.
## The ArrayMesh is made here too (its arrays are packed on this thread; the renderer takes them at
## its next sync), so the main thread only hands it to the chunk's MeshInstance3D.
class Merge:
	var serial := 0
	var groups: Array = []  # [Bake, Array of Transform3D, Mesh, trees' or plants' (bool)]
	var tinted: Array = []  # [Bake, Transform3D, Color]
	var material: Material
	var nature_material: Material
	var crown_material: Material
	var mesh: ArrayMesh
	var triangles := 0
	var usec := 0

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

	func run() -> void:
		var t0 := Time.get_ticks_usec()
		var all: Array = []
		var nf := 0
		var n_nf := 0
		var c_nf := 0
		for g: Array in groups:
			var bake: Bake = g[0]
			var xforms: Array = g[1]
			var is_nature: bool = g.size() > 3 and g[3]
			for xform: Transform3D in xforms:
				all.append([bake, xform, null, is_nature])
			if is_nature:
				n_nf += bake.indices.size() * xforms.size()
			else:
				nf += bake.indices.size() * xforms.size()
			c_nf += bake.crown_indices.size() * xforms.size()
		for t: Array in tinted:
			all.append(t)
			nf += (t[0] as Bake).indices.size()
		var verts := PackedVector3Array()
		var colors := PackedColorArray()
		var indices := PackedInt32Array()
		indices.resize(nf)
		var wf := 0
		# Trees' and plants' trunks and the like: the same arrays, in a surface of their own.
		var n_verts := PackedVector3Array()
		var n_colors := PackedColorArray()
		var n_indices := PackedInt32Array()
		n_indices.resize(n_nf)
		var n_wf := 0
		var c_verts := PackedVector3Array()
		var c_colors := PackedColorArray()
		var c_uvs := PackedVector2Array()
		var c_indices := PackedInt32Array()
		c_indices.resize(c_nf)
		var c_wf := 0
		for entry: Array in all:
			var bake: Bake = entry[0]
			var xform: Transform3D = entry[1]
			if not bake.indices.is_empty():
				var nat: bool = entry.size() > 3 and entry[3]
				var tv: PackedVector3Array = n_verts if nat else verts
				var tc: PackedColorArray = n_colors if nat else colors
				var ti_: PackedInt32Array = n_indices if nat else indices
				var base := tv.size()
				tv.append_array(xform * bake.verts)
				if entry[2] == null:
					tc.append_array(bake.colors)
				else:
					# Placeholders: the prototype's colour, as a square root as the bake's are.
					var tint: Color = entry[2]
					for c in bake.colors:
						tc.append(Color(c.r * sqrt(tint.r), c.g * sqrt(tint.g), c.b * sqrt(tint.b), c.a))
				var w := n_wf if nat else wf
				for k in bake.indices:
					ti_[w] = k + base
					w += 1
				# (assigned back: no matter whether packed arrays copy on assignment)
				if nat:
					n_wf = w
					n_verts = tv
					n_colors = tc
					n_indices = ti_
				else:
					wf = w
					verts = tv
					colors = tc
					indices = ti_
			if not bake.crown_indices.is_empty():
				var c_base := c_verts.size()
				c_verts.append_array(xform * bake.crown_verts)
				var ox := xform.origin.x
				var oz := xform.origin.z
				var tree_uv := Vector2(ox, oz)
				if bake.leaf_tints.is_empty():
					c_colors.append_array(bake.crown_colors)
				else:
					var seed := _hash12(tree_uv * 3.17 + Vector2(0.5, 0.5))
					var ti := clampi(int(fposmod(seed * 13.37 + 0.21, 1.0) * bake.leaf_tints.size()),
						0, bake.leaf_tints.size() - 1)
					var lt := bake.leaf_tints[ti]
					var sr := sqrt(maxf(lt.x, 0.0))
					var sg := sqrt(maxf(lt.y, 0.0))
					var sb := sqrt(maxf(lt.z, 0.0))
					for c in bake.crown_colors:
						c_colors.append(Color(c.r * sr, c.g * sg, c.b * sb, c.a))
				var u0 := c_uvs.size()
				c_uvs.resize(u0 + bake.crown_verts.size())
				for ui in range(u0, c_uvs.size()):
					c_uvs[ui] = tree_uv
				for k in bake.crown_indices:
					c_indices[c_wf] = k + c_base
					c_wf += 1
		triangles = (nf + n_nf + c_nf) / 3
		if nf >= 3 or n_nf >= 3 or c_nf >= 3:
			mesh = ArrayMesh.new()
			if nf >= 3:
				var arrays := []
				arrays.resize(Mesh.ARRAY_MAX)
				arrays[Mesh.ARRAY_VERTEX] = verts
				arrays[Mesh.ARRAY_COLOR] = colors
				arrays[Mesh.ARRAY_INDEX] = indices
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES)
				mesh.surface_set_material(mesh.get_surface_count() - 1, material)
			if n_nf >= 3:
				var n_arrays := []
				n_arrays.resize(Mesh.ARRAY_MAX)
				n_arrays[Mesh.ARRAY_VERTEX] = n_verts
				n_arrays[Mesh.ARRAY_COLOR] = n_colors
				n_arrays[Mesh.ARRAY_INDEX] = n_indices
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, n_arrays, [], {}, Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES)
				mesh.surface_set_material(mesh.get_surface_count() - 1, nature_material)
			if c_nf >= 3:
				var c_arrays := []
				c_arrays.resize(Mesh.ARRAY_MAX)
				c_arrays[Mesh.ARRAY_VERTEX] = c_verts
				c_arrays[Mesh.ARRAY_COLOR] = c_colors
				c_arrays[Mesh.ARRAY_TEX_UV] = c_uvs
				c_arrays[Mesh.ARRAY_INDEX] = c_indices
				# Uncompressed: UVs hold full float world (x, z) coordinates for far pollution sampling.
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, c_arrays, [], {}, 0)
				mesh.surface_set_material(mesh.get_surface_count() - 1, crown_material)
		groups = []
		tinted = []
		usec = Time.get_ticks_usec() - t0


static func material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = MergedShader
	return _material


## The merged material for trees' and plants' solid parts: far_merged with its `nature` switch on (matte, as near).
static func nature_material() -> ShaderMaterial:
	if _nature_material == null:
		_nature_material = ShaderMaterial.new()
		_nature_material.shader = MergedShader
		_nature_material.set_shader_parameter("nature", true)
	return _nature_material


static func crown_material() -> ShaderMaterial:
	if _crown_material == null:
		_crown_material = ShaderMaterial.new()
		_crown_material.shader = CrownShader
	return _crown_material


func _ready() -> void:
	nature_material()
	material()  # Godot sets a shader up with its first material: here rather than at the first merge
	crown_material()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--far-merge-from="):
			merge_from = float(arg.get_slice("=", 1))
		elif arg.begins_with("--far-merge-cap="):
			merge_cap = float(arg.get_slice("=", 1))


func _exit_tree() -> void:
	for entry in _baking + _merging:
		WorkerThreadPool.wait_for_task_completion(entry[0])
	_baking.clear()
	_merging.clear()


# --- Hooks from chunk_view.gd ----------------------------------------------------------------

## Whether a build of this chunk leaves out what its merged mesh draws (or is about to).
static func skips(cv) -> bool:
	var s: State = cv.far
	return s.far and (s.covers or not s.full)


static func _kept_type(proto_type: String) -> bool:
	return KEEP_TYPES.has(proto_type) or (not far_trees and (proto_type == "tree" or proto_type == "plant"))


## Whether an entity of this type drawn with `mesh` (null: a placeholder) goes in a merged mesh. With
## a graphics list a building without a model is its own picture on a card (chunk_view.gd), never a
## box, and the card stays as it is far away too.
static func merges(proto_type: String, mesh: Mesh) -> bool:
	if mesh == null:
		return not _kept_type(proto_type) and not SpriteStandins.in_use()
	return not _kept_type(proto_type) and bakeable(mesh)


## After a chunk's build (`skipped`: whether it left the merged entities out), or after it added
## MultiMeshes a build left for later (`skipped` null).
static func built(cv, skipped) -> void:
	var s: State = cv.far
	if skipped != null:
		s.full = not skipped
		if skipped:
			s.hidden = []  # the build let them go
	if s.node != null:
		if not s.far and cv.pending.is_empty():
			_drop_merged(s)  # near again, every MultiMesh in
		elif s.far and s.covers and s.full:
			_hide_full(cv)  # MultiMeshes added while the merged mesh stands for them
	if skipped != null and s.far:
		ask(cv)  # what it holds may have changed


## Hides the chunk's MultiMeshes of what its merged mesh draws, and their shadow stand-ins.
static func _hide_full(cv) -> void:
	var s: State = cv.far
	var hid := false
	for key in cv._nodes:
		var mesh = key[0] if key is Array else key
		if (mesh is Mesh and s.counts.has(mesh)) or (key is String and s.placeholders):
			var mmi: MultiMeshInstance3D = cv._nodes[key]
			if mmi.visible:
				mmi.visible = false
				s.hidden.append(mmi)
				hid = true
	if hid:
		cv._apply_shadows()


## Whether this MultiMesh is hidden behind the merged mesh (chunk_view.gd keeps its stand-in's
## shadow off then).
static func hides(cv, mmi: MultiMeshInstance3D) -> bool:
	var s: State = cv.far
	return not s.hidden.is_empty() and s.hidden.has(mmi)


static func _drop_merged(s: State) -> void:
	s.node.queue_free()
	s.node = null
	s.covers = false
	s.triangles = 0


## The shadow casting the chunk's tier gives (chunk_view.gd _apply_shadows): a merged chunk inside the
## region whose shadows reach the view casts through its one simplified mesh.
static func set_cast(cv, cast: GeometryInstance3D.ShadowCastingSetting) -> void:
	var s: State = cv.far
	s.cast = cast
	if s.node != null and s.node.cast_shadow != cast:
		s.node.cast_shadow = cast


## Gathers a far chunk again and merges it.
static func ask(cv) -> void:
	var s: State = cv.far
	s.serial += 1
	s.phase = ASKED
	_asked.append(cv)


# --- Which meshes merge, and how ---------------------------------------------------------------

## A mesh merges when its arrays are on the CPU (model_library.gd keeps them; primitive meshes make
## them there) and none of its surfaces moves in the shader (creatures' rigs) or is cut out with an
## external texture (`ALPHA_CLIP`). Leaf surfaces merge when `far_trees` is on.
static func bakeable(mesh: Mesh) -> bool:
	if not _bakeable.has(mesh):
		var kind := 1 if (mesh is PrimitiveMesh or (mesh is ArrayMesh and mesh.has_meta(ModelLods.ARRAYS_META))) else 0
		if kind != 0:
			for i in mesh.get_surface_count():
				if mesh.surface_get_primitive_type(i) != Mesh.PRIMITIVE_TRIANGLES:
					kind = 0
					break
				var sm := mesh.surface_get_material(i) as ShaderMaterial
				if sm != null:
					if sm.shader == ModelLibrary.FactorioClipShader or int(_param(sm, "rig_mode", 0)) != 0:
						kind = 0
						break
					if sm.shader == FactorioLeafShader:
						kind = 2
		_bakeable[mesh] = kind
	var k: int = _bakeable[mesh]
	return k == 1 or (k == 2 and far_trees)


static func _param(sm: ShaderMaterial, name: String, default: Variant) -> Variant:
	var v: Variant = sm.get_shader_parameter(name)
	return default if v == null else v


## What a surface's material makes of its vertices (the uniforms factorio_material reads, with its
## defaults), or {} for a surface left out: see-through light that fades away (a thruster's plume).
static func _surface_params(material: Material) -> Dictionary:
	var p := {"albedo": Color(0.2, 0.2, 0.2), "tint": Color.WHITE, "part_data": 0.0, "part_colors": true, "vertex_data": 0.0,
		"desaturate": 0.0, "value": 1.0, "ao_strength": 1.0, "light": 1.0, "metallic": 0.0}
	var sm := material as ShaderMaterial
	if sm != null:
		if sm.shader == FactorioAlphaShader and bool(_param(sm, "glow_fades", false)):
			return {}
		p["albedo"] = (_param(sm, "albedo", Color.WHITE) as Color).srgb_to_linear()
		p["tint"] = (_param(sm, "model_tint", Color.WHITE) as Color).srgb_to_linear()
		p["part_data"] = float(_param(sm, "part_data", 0.0))
		p["part_colors"] = bool(_param(sm, "part_colors", true))
		p["vertex_data"] = float(_param(sm, "vertex_data", 1.0))
		p["desaturate"] = float(_param(sm, "desaturate", 0.15))
		p["value"] = float(_param(sm, "value", 0.9))
		p["ao_strength"] = float(_param(sm, "ao_strength", 1.0))
		p["metallic"] = float(_param(sm, "metallic", 0.0))
		# A "pbr" pack's material (model_library.gd PACK_PBR_META), while packs' own shading is on.
		p["pbr"] = Looks.packs_shade and bool(_param(sm, "modeller_tex", false))
		p["pbr_light"] = Looks.light_now
		var albedo_tex: Texture2D = _param(sm, "albedo_tex", null) if bool(_param(sm, "use_albedo_tex", false)) else null
		if albedo_tex != null and albedo_tex.has_meta(ModelTextures.SMALL_META):
			p["tex"] = albedo_tex.get_meta(ModelTextures.SMALL_META)
		# Burnt remnants darken the part colours' light too; glowing parts are drawn half lit.
		p["light"] = (_param(sm, "part_light", Vector2(0.95, 0.6)) as Vector2).x / 0.95
		if bool(_param(sm, "activity_glow", false)):
			p["light"] = float(p["light"]) * 0.65
	elif material is BaseMaterial3D:
		p["albedo"] = (material as BaseMaterial3D).albedo_color.srgb_to_linear()
		p["metallic"] = (material as BaseMaterial3D).metallic
		if (material as BaseMaterial3D).vertex_color_use_as_albedo:
			p["albedo"] = Color.WHITE  # placeholders: the instance's colour comes on top
	return p


## The model's Bake when it is done; else starts it and returns null.
func _bake_for(mesh: Mesh) -> Bake:
	var bake: Bake = _bakes.get(mesh)
	if bake != null and (bake.shading == Looks.packs_shade or not bake.done):
		return bake if bake.done else null
	bake = Bake.new()
	bake.shading = Looks.packs_shade
	var coarser := sqrt(ModelLods.lod_threshold)
	bake.simplify_error = SIMPLIFY_ERROR * coarser
	bake.cell = CELL * coarser
	bake.crown_cell = 1.5 * clampf(sqrt(coarser), 1.0, 1.3)
	var kept: Array = mesh.get_meta(ModelLods.ARRAYS_META) if mesh.has_meta(ModelLods.ARRAYS_META) else []
	for i in mesh.get_surface_count():
		# A merged surface (material_rows.gd): each row's material, CUSTOM2 each vertex's row.
		var material := mesh.surface_get_material(i)
		var rows := MaterialRows.rows(material)
		var mats: Array = rows if not rows.is_empty() else [material]
		var params: Array = []
		for m in mats:
			params.append(_surface_params(m))
		if params.all(func(p: Dictionary) -> bool: return p.is_empty()):
			continue
		var a: Array = kept[i] if i < kept.size() else (mesh as PrimitiveMesh).get_mesh_arrays()
		var sm := material as ShaderMaterial
		if sm != null and sm.shader == FactorioLeafShader:
			if bake.leaf_tints.is_empty():
				for r in mats:
					var rsm := r as ShaderMaterial
					if rsm == null:
						continue
					var n_tints := clampi(int(_param(rsm, "leaf_tint_count", 0)), 0, 16)
					if n_tints <= 0:
						continue
					var raw: Variant = rsm.get_shader_parameter("leaf_tints")
					if raw is PackedVector3Array:
						bake.leaf_tints = (raw as PackedVector3Array).slice(0, n_tints)
						break
					if raw is Array:
						for k in mini(n_tints, (raw as Array).size()):
							if (raw as Array)[k] is Vector3:
								bake.leaf_tints.append((raw as Array)[k])
						break
			bake.crown_surfaces.append([a[Mesh.ARRAY_VERTEX], a[Mesh.ARRAY_NORMAL], a[Mesh.ARRAY_COLOR], a[Mesh.ARRAY_CUSTOM1],
				a[Mesh.ARRAY_INDEX], params, a[Mesh.ARRAY_CUSTOM2] if not rows.is_empty() else null, a[Mesh.ARRAY_TEX_UV],
				bool(_param(sm, "leaf_core", false))])
			continue
		bake.surfaces.append([a[Mesh.ARRAY_VERTEX], a[Mesh.ARRAY_NORMAL], a[Mesh.ARRAY_COLOR], a[Mesh.ARRAY_CUSTOM1],
			a[Mesh.ARRAY_INDEX], params, a[Mesh.ARRAY_CUSTOM2] if not rows.is_empty() else null, a[Mesh.ARRAY_TEX_UV]])
	_bakes[mesh] = bake
	_bake_queue.append(bake)
	return null


# --- Each frame ------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if world == null:
		return
	var t0 := Time.get_ticks_usec()
	# Belts small on screen drawn with their stand-ins: the same kind of choice per chunk.
	BeltLods.update(world, get_viewport().get_camera_3d() if is_inside_tree() else null, delta)
	_decide(delta)
	_collect()
	_poll_bakes()
	_start_merges()
	_install()
	var spent := Time.get_ticks_usec() - t0
	main_usec += spent
	if Probing.on:
		world.prof["far"] = int(world.prof.get("far", 0)) + spent


## Which chunks are far: from the camera, MERGE_FROM with SLACK either way, never near the focus. A
## chunk going far is gathered for merging; one coming near is built in full again.
func _decide(delta: float) -> void:
	_check_timer += delta
	if _pass_next < _pass_todo.size():
		_decide_slice()
		return
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var at := cam.global_position if cam != null else Vector3(world.focus().x, 30.0, world.focus().y)
	if _check_timer < CHECK_INTERVAL and enabled == _last_enabled and at.distance_to(_last_camera) < 8.0:
		return
	if not enabled and not _last_enabled and _far_count == 0:
		return  # off, and nothing left merged
	_check_timer = 0.0
	_last_camera = at
	_last_enabled = enabled
	_pass_at = at
	_pass_focus = world.focus()
	_pass_from = MERGE_FROM
	if world.sun != null:
		var shadows: float = world.sun.directional_shadow_max_distance
		_pass_from = maxf(_pass_from, minf(shadows, merge_cap) if merge_cap > 0.0 else shadows)
	if merge_from > 0.0:
		_pass_from = merge_from
	_far_count = 0
	_pass_todo = world.chunks.keys()
	_pass_next = 0
	_decide_slice()


## One look's chunks go through a slice a frame: at view distance 50 a look at all 10,201 at once
## took 10-20 ms. A look under way finishes before the next starts.
const DECIDE_SLICE := 1500
var _pass_todo: Array = []
var _pass_next := 0
var _pass_at := Vector3.ZERO
var _pass_focus := Vector2.ZERO
var _pass_from := MERGE_FROM


func _decide_slice() -> void:
	var at := _pass_at
	var focus := _pass_focus
	var from := _pass_from
	var stop := mini(_pass_next + DECIDE_SLICE, _pass_todo.size())
	while _pass_next < stop:
		var c: Vector2i = _pass_todo[_pass_next]
		_pass_next += 1
		var cv = world.chunks.get(c)
		if cv == null:
			continue
		var s: State = cv.far
		var rect := Rect2(Vector2(c * CHUNK), Vector2(CHUNK, CHUNK))
		var lo := Vector3(rect.position.x, 0.0, rect.position.y)
		var d := at.distance_to(at.clamp(lo, lo + Vector3(CHUNK, 8.0, CHUNK)))
		var far := s.far
		var near_focus := focus.distance_to(focus.clamp(rect.position, rect.end))
		if merge_from > 0.0 and merge_from < NEAR_FOCUS:
			near_focus = INF  # --far-merge-from under NEAR_FOCUS: merged up close, for screenshots
		if not enabled or near_focus < NEAR_FOCUS:
			far = false
		elif d > from and near_focus > NEAR_FOCUS + SLACK * 0.5:
			far = true
		elif d < from - SLACK:
			far = false
		if far:
			_far_count += 1
		if far == s.far:
			continue
		s.far = far
		cv.thin_ore()  # scattered ore: one rock a tile far away, all of them near (no build)
		if far:
			if cv.loaded:
				ask(cv)
		else:
			s.serial += 1  # whatever was on its way is dropped
			s.phase = IDLE
			if cv.building:
				# A build under way decided to leave the merged entities out: built again whole after it.
				world.redraw(c)
			if not s.hidden.is_empty():
				# Its MultiMeshes are still there: shown again, no build.
				for mmi: MultiMeshInstance3D in s.hidden:
					if is_instance_valid(mmi):
						mmi.visible = true
				s.hidden = []
				cv._apply_shadows()
				if s.node != null:
					_drop_merged(s)
			elif not s.full:
				world.redraw(c)  # its MultiMeshes are made again; the merged mesh goes once they are in


## Gathers far chunks' mergeable entities, nearest the focus first, a slice at a time (at least
## sixteen; on the main thread: the models' tables aren't for threads).
func _collect() -> void:
	if not _asked.is_empty():
		var focus: Vector2 = world.focus()
		var fresh: Array = []
		for cv in _asked:
			# A snapshot still arriving in parts is built again (and asks again) as each comes.
			if is_instance_valid(cv) and world.chunks.get(cv.coord) == cv and cv.far.phase == ASKED and not cv.is_incomplete():
				var s: State = cv.far
				s.phase = GATHERING
				s.recs = cv.entities.values()
				s.next = 0
				s.groups = {}
				s.tinted = []
				fresh.append([cv, s.serial])
		_asked.clear()
		var nearer := func(a: Array, b: Array) -> bool:
			return (Vector2(a[0].coord * CHUNK) - focus).length_squared() < (Vector2(b[0].coord * CHUNK) - focus).length_squared()
		fresh.sort_custom(nearer)
		_collecting.append_array(fresh)
	if _collecting.is_empty():
		FrameBudget.waiting(&"far_collect", 0)
		return
	var started := Time.get_ticks_usec()
	var looked := 0
	var allow := FrameBudget.grant(&"far_collect")
	while allow > 0 and not _collecting.is_empty():
		var entry: Array = _collecting[0]
		if not _current(entry, GATHERING):
			_collecting.pop_front()
			continue
		var cv = entry[0]
		var s: State = cv.far
		while s.next < s.recs.size():
			if looked >= 16 and (looked & 15) == 0 and Time.get_ticks_usec() - started > allow:
				FrameBudget.spent(&"far_collect", Time.get_ticks_usec() - started, _collecting.size())
				return
			_gather(cv, s, s.recs[s.next])
			s.next += 1
			looked += 1
		_collecting.pop_front()
		s.recs = []
		s.phase = WAITING
		s.checked = false
		_waiting.append(entry)
		_progress += 1
	FrameBudget.spent(&"far_collect", Time.get_ticks_usec() - started, _collecting.size())


## Whether a queued [ChunkView, serial] is still the chunk's latest, in `phase`.
func _current(entry: Array, phase: int) -> bool:
	var cv = entry[0]
	if not is_instance_valid(cv) or world.chunks.get(cv.coord) != cv:
		return false
	var s: State = cv.far
	return s.far and s.serial == int(entry[1]) and s.phase == phase


## One entity into its chunk's groups, as chunk_view.gd build_entities would draw it (merges() true).
func _gather(cv, s: State, rec) -> void:
	var protos = world.protos
	var proto = protos.entity(rec.proto_id)
	if proto == null or rec.extra.has("gh") or rec.extra.has("tg") or ModelLibrary.hidden(proto.name) or _kept_type(proto.type):
		return
	if rec.extra.has("hid"):
		return  # (predicted.gd clear_run, as chunk_view.gd)
	if ModelLibrary.REMNANT_TYPES.has(proto.type):
		var remnant: Array = cv._remnant(protos, proto, rec)
		if not remnant.is_empty() and bakeable(remnant[0]):
			_add(s, remnant[0], remnant[1])
		return
	if not ModelLibrary.entity_ready(proto.name, proto.type, rec.extra, rec.dir):
		return
	var mesh := ModelLibrary.mesh_for_entity(proto.name, proto.type, rec.extra, rec.dir)
	if mesh == null:
		if not merges(proto.type, null):
			return  # a card (sprite_standins.gd), drawn by the chunk itself
		var color: Color = ModelLibrary.NEUTRAL_COLOR if ModelLibrary.NEUTRAL_PROTOS.has(proto.name) else proto.color
		var shape: Mesh = Visuals.cone_mesh() if Visuals.is_cone(proto) else Visuals.box_mesh()
		s.tinted.append([shape, Visuals.placeholder_transform(proto, rec.pos, rec.dir, Visuals.height_for(proto)), color.srgb_to_linear()])
		return
	if not bakeable(mesh):
		return
	var xform: Transform3D = cv._model_transform(proto, rec)
	_add(s, mesh, xform)
	if proto.type == "tree" or proto.type == "plant":
		s.nature[mesh] = true
	var parts := ModelLibrary.parts_for_entity(proto.name, proto.type, rec.extra, rec.dir)
	for part: ModelLibrary.AnimPart in parts:
		# Parts at rest; lit parts (signal lenses) show only by state.
		if part.lit or part.mesh == null or not bakeable(part.mesh):
			continue
		_add(s, part.mesh, Transform3D(Basis.IDENTITY, xform.origin) if part.upright else xform)
	if rec.extra.has("cb"):
		for place: Array in ModelLibrary.cargo_places(int(rec.extra["cb"]), xform.origin):
			if ModelLibrary.ready(place[0]):
				var piece := ModelLibrary.mesh_for(place[0])
				if piece != null and bakeable(piece):
					_add(s, piece, Transform3D(Basis(), place[1]))
	if rec.belt_ends != 0:
		# As near (chunk_view.gd _add_belt_ends): on belts, splitters' halves and undergrounds' open ends,
		# with their moving parts at rest unless the model has them there already.
		var inverse := xform.affine_inverse()
		for place: Array in ModelLibrary.belt_end_places(proto.name, proto.type, rec.dir, rec.pos, rec.belt_ends, xform.origin.y):
			if not ModelLibrary.ready(place[0]):
				continue
			var end := ModelLibrary.mesh_for(place[0])
			if end == null or not bakeable(end):
				continue
			var at: Transform3D = place[1]
			_add(s, end, at)
			for part: ModelLibrary.AnimPart in ModelLibrary.parts_for(place[0]):
				if not part.lit and part.mesh != null and bakeable(part.mesh) and not ModelLibrary.part_doubled(part, inverse * at, parts):
					_add(s, part.mesh, at)


static func _add(s: State, mesh: Mesh, xform: Transform3D) -> void:
	if not s.groups.has(mesh):
		s.groups[mesh] = []
	(s.groups[mesh] as Array).append(xform)


## Takes in finished bakes and starts waiting ones.
func _poll_bakes() -> void:
	for i in range(_baking.size() - 1, -1, -1):
		var entry: Array = _baking[i]
		if not WorkerThreadPool.is_task_completed(entry[0]):
			continue
		WorkerThreadPool.wait_for_task_completion(entry[0])
		var bake: Bake = entry[1]
		bake.done = true
		worker_usec += bake.usec
		_baking.remove_at(i)
		_progress += 1
	while _baking.size() < BAKE_JOBS and not _bake_queue.is_empty():
		var bake: Bake = _bake_queue.pop_front()
		_baking.append([WorkerThreadPool.add_task(bake.run, false, "far bake"), bake])


## Merges gathered chunks whose models are all baked, in the order gathered (nearest first). Looked
## at again only when a bake finished or a chunk was gathered since last time.
func _start_merges() -> void:
	var stamp := _progress
	var changed := stamp != _stamp
	_stamp = stamp
	var i := 0
	while i < _waiting.size() and _merging.size() < MERGE_JOBS:
		var entry: Array = _waiting[i]
		if not _current(entry, WAITING):
			_waiting.remove_at(i)
			continue
		var s: State = entry[0].far
		if not changed and s.checked:
			i += 1
			continue
		var ready := true
		var groups: Array = []
		for mesh: Mesh in s.groups:
			var bake := _bake_for(mesh)
			if bake == null:
				ready = false
			elif ready:
				groups.append([bake, s.groups[mesh], mesh, s.nature.has(mesh)])
		var tinted: Array = []
		for t: Array in s.tinted:
			var bake := _bake_for(t[0])
			if bake == null:
				ready = false
			elif ready:
				tinted.append([bake, t[1], t[2]])
		if not ready:
			s.checked = true
			i += 1
			continue
		_waiting.remove_at(i)
		s.phase = MERGING
		var merge := Merge.new()
		merge.serial = s.serial
		merge.groups = groups
		merge.tinted = tinted
		merge.material = material()
		merge.nature_material = nature_material()
		merge.crown_material = crown_material()
		s.counts = {}
		for g: Array in groups:
			s.counts[g[2]] = (g[1] as Array).size()
		s.placeholders = not tinted.is_empty()
		s.groups = {}
		s.tinted = []
		_merging.append([WorkerThreadPool.add_task(merge.run, false, "far merge"), merge, entry[0]])


## Puts finished merges in, within its slice (at least one).
func _install() -> void:
	if _merging.is_empty():
		FrameBudget.waiting(&"far_install", 0)
		return
	var started := Time.get_ticks_usec()
	var i := 0
	var allow := FrameBudget.grant(&"far_install")
	while i < _merging.size():
		var entry: Array = _merging[i]
		if not WorkerThreadPool.is_task_completed(entry[0]):
			i += 1
			continue
		if allow <= 0 or Time.get_ticks_usec() - started > allow:
			FrameBudget.spent(&"far_install", Time.get_ticks_usec() - started, _merging.size())
			return
		WorkerThreadPool.wait_for_task_completion(entry[0])
		_merging.remove_at(i)
		_progress += 1  # a merge slot came free: chunks passed over for want of one are looked at again
		var merge: Merge = entry[1]
		worker_usec += merge.usec
		if not _current([entry[2], merge.serial], MERGING):
			continue  # gathered again since, near again, or gone
		var cv = entry[2]
		var s: State = cv.far
		s.phase = IDLE
		if s.node == null:
			s.node = MeshInstance3D.new()
			s.node.name = "Merged"
			s.node.cast_shadow = s.cast
			cv.add_child(s.node)
		s.node.mesh = merge.mesh
		GroundHeight.hold_mesh(s.node)  # on hills, room for their lift
		s.triangles = merge.triangles
		s.covers = true
		cv.count("far_merges")
		s.node.visible = true
		if s.full:
			_hide_full(cv)  # kept hidden: coming near again before anything changes shows them
	FrameBudget.spent(&"far_install", Time.get_ticks_usec() - started, _merging.size())


## [merged chunks drawn, their triangles, chunks far] now (for the probe and tests).
func census() -> Array:
	var n := 0
	var tris := 0
	var far := 0
	for cv in world.chunks.values():
		var s: State = cv.far
		if s.far:
			far += 1
		if s.node != null and s.node.visible:
			n += 1
			tris += s.triangles
	return [n, tris, far]


## The models in merged chunks drawn now by triangles: [[name, instances, triangles each], ...],
## most first (for the probe).
func models() -> Array:
	var names := {}
	for name in ModelLibrary._cache:
		if ModelLibrary._cache[name] != null:
			names[ModelLibrary._cache[name]] = name
	var by := {}
	for cv in world.chunks.values():
		var s: State = cv.far
		if s.node == null or not s.node.visible:
			continue
		for mesh in s.counts:
			by[mesh] = int(by.get(mesh, 0)) + int(s.counts[mesh])
	var rows: Array = []
	for mesh in by:
		var bake: Bake = _bakes.get(mesh)
		rows.append([str(names.get(mesh, mesh.resource_name)), by[mesh],
			(bake.indices.size() + bake.crown_indices.size()) / 3 if bake != null else 0])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return int(a[1]) * int(a[2]) > int(b[1]) * int(b[2]))
	return rows


## What the camera's view holds by kind, in draws before shadows (for the probe): [merged meshes,
## far chunks' own MultiMesh surfaces (trees, ore...), near chunks' MultiMesh surfaces].
func view_census() -> Array:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var planes: Array[Plane] = []
	if cam != null:
		planes = cam.get_frustum()
	var out := [0, 0, 0]
	for cv in world.chunks.values():
		var box := AABB(Vector3(cv.coord.x * CHUNK, 0.0, cv.coord.y * CHUNK), Vector3(CHUNK, 16.0, CHUNK))
		var seen := true
		for p: Plane in planes:
			var inner := Vector3(box.position.x if p.normal.x > 0.0 else box.end.x, box.position.y if p.normal.y > 0.0 else box.end.y,
				box.position.z if p.normal.z > 0.0 else box.end.z)
			seen = seen and not p.is_point_over(inner)
		if not seen or not cv.visible:
			continue
		var s: State = cv.far
		if s.node != null and s.node.visible:
			out[0] += 1
		for mmi: MultiMeshInstance3D in cv._instances:
			if mmi.visible and mmi.multimesh.mesh != null and mmi.multimesh.instance_count > 0:
				out[1 if s.far else 2] += mmi.multimesh.mesh.get_surface_count()
	return out


## For the F4 line: "" when no chunk is merged.
func status() -> String:
	var c := census()
	if int(c[0]) == 0:
		return ""
	return "%d far chunks merged (%dk triangles), %d far" % [c[0], int(c[1]) / 1000, c[2]]
