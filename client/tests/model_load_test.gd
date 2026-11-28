extends SceneTree
## Every model made the new way (its .glb parsed and merged on a worker thread, model_library.gd
## Load) against the old way (the imported scene flattened with SurfaceTool, one surface per
## material): the new mesh has one surface per shader (solid, see-through, leaf cards: one material
## per model, material_rows.gd), and each old surface is one row of it, with the same triangles,
## vertex data and material values (the row in the merged material's table); the same bounds and
## moving parts. Also checks that ready() doesn't block and poll() finishes the jobs, and that
## the materials changed by name after loading (tiers, belts, remnants, tints) change only their
## rows. Run headless:
##   godot --headless --path client -s res://tests/model_load_test.gd [-- name ...]
## Prints "MODEL LOAD FAILS: 0" when all match; quits with 1 otherwise.

const Anim := preload("res://scripts/world/anim.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const MaterialRows := preload("res://scripts/world/material_rows.gd")
const TestEnv := preload("res://tests/test_env.gd")

## How far a corner's value may drift between the two ways, on average, by array.
const PER_CORNER := {Mesh.ARRAY_NORMAL: 0.03}
var _fails := 0
var _checked := 0
var _surfaces_before := 0
var _surfaces_after := 0


func _initialize() -> void:
	TestEnv.isolate("model-load-test")  # configure() keeps its packs' copies check in user://
	var names: Array = OS.get_cmdline_user_args()
	if names == ["walls"]:  # the stone walls' layout alone
		_wall_layout_check()
		print("MODEL LOAD FAILS: %d" % _fails)
		TestEnv.clean()
		quit(1 if _fails > 0 else 0)
		return
	if names.is_empty():
		# Every built-in pack's models (model_packs.gd BUILTIN), as <pack>/<name>.
		for pack: String in ModelLibrary.ModelPacks.BUILTIN:
			for f in DirAccess.get_files_at(ModelLibrary.ModelPacks.BUILTIN_DIR + pack):
				if f.ends_with(".glb"):
					names.append(pack + "/" + f.get_basename())
		print("MODEL LOAD: %d models in %d built-in packs" % [names.size(), ModelLibrary.ModelPacks.BUILTIN.size()])
	else:
		# A bare name is our own model (Wube3DP's, else Placeholders'), "<pack>/<name>" a pack's.
		for i in names.size():
			if not str(names[i]).contains("/"):
				var wube := "wube3dp/" + str(names[i])
				names[i] = wube if FileAccess.file_exists(ModelLibrary.ModelPacks.BUILTIN_DIR + wube + ".glb") else "placeholders/" + str(names[i])
	# Both settings: merged materials (one surface per shader) and a surface per material.
	for name in names:
		_compare(str(name), true)
		_compare(str(name), false)
	ModelLibrary.merge_materials = true
	if OS.get_cmdline_user_args().is_empty():
		_edits_check()
		_wall_layout_check()
	_async_check()


func _fail(what: String) -> void:
	_fails += 1
	if _fails <= 60:
		print("FAIL ", what)


func _compare(name: String, combine: bool) -> void:
	var res_path := ModelLibrary.ModelPacks.BUILTIN_DIR + name + ".glb"
	var old_parts: Array = []
	var root := (load(res_path) as PackedScene).instantiate()
	var old := ModelLibrary._flatten(root, old_parts)
	root.free()
	var load := ModelLibrary.Load.new()
	load.path = res_path
	load.combine = combine
	load.run()
	if not load.ok:
		_fail("%s: the glb didn't parse" % name)
		return
	var new_parts: Array = []
	var new := ModelLibrary._commit_load(load, new_parts)
	_checked += 1 if combine else 0
	if load.bake.get("animated", false):
		_compare_baked(name, old, old_parts, new, new_parts, combine)
		return
	_same_mesh(name, old, new, combine)
	_same_parts(name, old_parts, new_parts, combine)


func _same_parts(name: String, old_parts: Array, new_parts: Array, combine: bool) -> void:
	if old_parts.size() != new_parts.size():
		_fail("%s: %d moving parts, was %d" % [name, new_parts.size(), old_parts.size()])
		return
	for i in old_parts.size():
		var a: ModelLibrary.AnimPart = old_parts[i]
		var b: ModelLibrary.AnimPart = new_parts[i]
		if a.kind != b.kind or not a.pivot.is_equal_approx(b.pivot) or a.axis != b.axis or a.slide != b.slide or a.upright != b.upright or a.lit != b.lit:
			_fail("%s: part %d is %s at %s, was %s at %s" % [name, i, b.kind, b.pivot, a.kind, a.pivot])
		_same_mesh("%s part %s" % [name, a.kind], a.mesh, b.mesh, combine)


func _compare_baked(name: String, old: Mesh, old_parts: Array, new: Mesh, new_parts: Array, combine: bool) -> void:
	var baked_parts: Array = []
	var other_parts: Array = []
	for p: ModelLibrary.AnimPart in new_parts:
		if p.kind == "baked":
			baked_parts.append(p)
		else:
			other_parts.append(p)
	if baked_parts.is_empty():
		_fail("%s: animated model produced no baked part" % name)
		return
	_same_parts(name, old_parts, other_parts, combine)

	if combine:
		_surfaces_before += old.get_surface_count() if old != null else 0
		_surfaces_after += new.get_surface_count() if new != null else 0
		for bp: ModelLibrary.AnimPart in baked_parts:
			_surfaces_after += bp.mesh.get_surface_count() if bp.mesh != null else 0

	var old_tris := _mesh_tris(old)
	var new_tris := _mesh_tris(new)
	var box := new.get_aabb() if new != null else AABB()
	var has_box := new != null
	for bp: ModelLibrary.AnimPart in baked_parts:
		if bp.bake.is_empty() or bp.mesh == null:
			_fail("%s: baked part missing bake or mesh" % name)
			return
		new_tris += _mesh_tris(bp.mesh)
		var pbox := _baked_rest_aabb(bp.mesh, bp.bake)
		box = box.merge(pbox) if has_box else pbox
		has_box = true
		for s in bp.mesh.get_surface_count():
			var arrays := bp.mesh.surface_get_arrays(s)
			if arrays[Mesh.ARRAY_CUSTOM3] == null:
				_fail("%s: baked part surface %d missing ARRAY_CUSTOM3" % [name, s])
	if new_tris != old_tris:
		_fail("%s: baked split has %d triangles, was %d" % [name, new_tris, old_tris])
	if old != null and has_box:
		var old_box := old.get_aabb()
		var tol := maxf(old_box.size.length() * 0.002, 0.002)
		if not _close(old_box.position, box.position, tol) or not _close(old_box.size, box.size, tol):
			_fail("%s: baked rest bounds %s, was %s" % [name, box, old_box])

	# Shader / textured parity between old surfaces and split (body + baked_parts) surfaces.
	var old_kinds := {}
	if old != null:
		for i in old.get_surface_count():
			var m := old.surface_get_material(i) as ShaderMaterial
			old_kinds[[m.shader, _textured(m)]] = true
	var split_meshes: Array = []
	if new != null:
		split_meshes.append(new)
	for bp: ModelLibrary.AnimPart in baked_parts:
		if bp.mesh != null:
			split_meshes.append(bp.mesh)
	var seen_kinds := {}
	for sm: Mesh in split_meshes:
		for r: Array in _rows_of(sm):
			var rm := r[2] as ShaderMaterial
			var key := [rm.shader, _textured(rm)]
			if not old_kinds.has(key):
				_fail("%s: split surface %s has unexpected shader/texture kind" % [name, rm.resource_name])
			seen_kinds[key] = true
	if seen_kinds.size() != old_kinds.size():
		_fail("%s: split meshes cover %d material kinds, expected %d" % [name, seen_kinds.size(), old_kinds.size()])


static func _mesh_tris(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var total := 0
	for i in mesh.get_surface_count():
		total += _triangles(mesh.surface_get_arrays(i))
	return total


static func _baked_rest_aabb(mesh: Mesh, bake: Dictionary) -> AABB:
	var image: Image = bake.get("image")
	if image == null:
		return mesh.get_aabb()
	var box := AABB()
	var first := true
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var skin: Variant = arrays[Mesh.ARRAY_CUSTOM3]
		if not (skin is PackedFloat32Array):
			var sb := mesh.get_aabb()
			box = sb if first else box.merge(sb)
			first = false
			continue
		var c3 := skin as PackedFloat32Array
		for v in verts.size():
			var m := Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO)
			var total := 0.0
			for k in 4:
				if v * 4 + k >= c3.size():
					break
				var code := c3[v * 4 + k]
				var w := fposmod(code, 1.0) / 0.999
				if w <= 0.0:
					continue
				var j := int(floor(code))
				var r0 := image.get_pixel(j * 3, 0)
				var r1 := image.get_pixel(j * 3 + 1, 0)
				var r2 := image.get_pixel(j * 3 + 2, 0)
				m.basis.x += w * Vector3(r0.r, r1.r, r2.r)
				m.basis.y += w * Vector3(r0.g, r1.g, r2.g)
				m.basis.z += w * Vector3(r0.b, r1.b, r2.b)
				m.origin += w * Vector3(r0.a, r1.a, r2.a)
				total += w
			var p := verts[v] if total <= 0.0 else (m * verts[v]) / total
			if first:
				box = AABB(p, Vector3.ZERO)
				first = false
			else:
				box = box.expand(p)
	return box


static func _textured(m: ShaderMaterial) -> bool:
	return m.get_shader_parameter("use_albedo_tex") == true or m.get_shader_parameter("use_orm_tex") == true


## The new mesh's surfaces as rows: [[surface, row, its material (the row's), the merged one], ...].
static func _rows_of(mesh: Mesh) -> Array:
	var out: Array = []
	for j in mesh.get_surface_count():
		var m := mesh.surface_get_material(j) as ShaderMaterial
		var rows := MaterialRows.rows(m)
		if rows.is_empty():
			out.append([j, -1, m, m])
		else:
			for r in rows.size():
				out.append([j, r, rows[r], m])
	return out


func _same_mesh(what: String, old: Mesh, new: Mesh, combine: bool) -> void:
	if (old == null) != (new == null):
		_fail("%s: mesh %s, was %s" % [what, new, old])
		return
	if old == null:
		return
	if combine:
		_surfaces_before += old.get_surface_count()
		_surfaces_after += new.get_surface_count()
	# Merged: one surface per shader, and one per textured material (never merged); else as before.
	var expected := old.get_surface_count()
	if combine:
		var shaders := {}
		var textured := 0
		for i in old.get_surface_count():
			var m := old.surface_get_material(i) as ShaderMaterial
			if _textured(m):
				textured += 1
			else:
				shaders[m.shader] = true
		expected = shaders.size() + textured
	if new.get_surface_count() != expected:
		_fail("%s: %d surfaces, %d expected (merged %s)" % [what, new.get_surface_count(), expected, combine])
	var tolerance := maxf(old.get_aabb().size.length() * 0.002, 0.002)
	if not _close(old.get_aabb().position, new.get_aabb().position, tolerance) or not _close(old.get_aabb().size, new.get_aabb().size, tolerance):
		_fail("%s: bounds %s, was %s" % [what, new.get_aabb(), old.get_aabb()])
	# Old surfaces, in order, are the new rows of their shader, in order.
	var rows := _rows_of(new)
	var used := {}
	var arrays_cache := {}
	for i in old.get_surface_count():
		var ma := old.surface_get_material(i) as ShaderMaterial
		var found: Array = []
		for k in rows.size():
			if not used.has(k) and (rows[k][2] as ShaderMaterial).shader == ma.shader and _textured(rows[k][2]) == _textured(ma):
				found = rows[k]
				used[k] = true
				break
		if found.is_empty():
			_fail("%s surface %d: no row for %s" % [what, i, ma.resource_name])
			continue
		var mb: ShaderMaterial = found[2]
		var merged: ShaderMaterial = found[3]
		if mb.resource_name != ma.resource_name:
			_fail("%s surface %d: row %s, was %s" % [what, i, mb.resource_name, ma.resource_name])
			continue
		for p in ["vertex_data", "edge_data", "view_data", "part_data", "activity_glow", "albedo", "emission_energy"]:
			if str(ma.get_shader_parameter(p)) != str(mb.get_shader_parameter(p)):
				_fail("%s surface %d: %s %s, was %s" % [what, i, p, mb.get_shader_parameter(p), ma.get_shader_parameter(p)])
		if int(found[1]) >= 0:
			_same_row(what + " surface %d" % i, ma, merged, int(found[1]))
		var j: int = found[0]
		if not arrays_cache.has(j):
			arrays_cache[j] = new.surface_get_arrays(j)
		var a := old.surface_get_arrays(i)
		var b: Array = arrays_cache[j]
		var ta := _triangles(a)
		var corners := _corners(b, int(found[1]))
		if corners.size() / 3 != ta:
			_fail("%s surface %d: %d triangles, was %d" % [what, i, corners.size() / 3, ta])
			continue
		# Vertex data compared as sums over the triangles' corners (vertices may be split or
		# ordered differently): positions, normals, colours, UV2, part colours. The import stores
		# positions in 16 bits and welds corners of zero-area triangles to neighbours with other
		# normals, so the sums may drift a little per corner (PER_CORNER). A row's missing array is
		# zeros in the merged surface: its material says so (vertex_data and the rest).
		for t in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_COLOR, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_CUSTOM1]:
			if a[t] == null:
				continue
			if b[t] == null:
				_fail("%s surface %d: array %d missing" % [what, i, t])
				continue
			var sa := _corner_sum(a, t, _corners(a, -1))
			var sb := _corner_sum(b, t, corners)
			var allowed := maxf(ta * 3 * (tolerance if t == Mesh.ARRAY_VERTEX else float(PER_CORNER.get(t, 0.01))), 0.01)
			if sa.distance_to(sb) > allowed:
				_fail("%s surface %d: array %d sums to %s, was %s" % [what, i, t, sb, sa])


## The merged material's table row `r` holds what the old material gave its surface.
func _same_row(what: String, old: ShaderMaterial, merged: ShaderMaterial, r: int) -> void:
	if int(merged.get_shader_parameter("material_rows")) != MaterialRows.rows(merged).size():
		_fail("%s: material_rows %s for %d rows" % [what, merged.get_shader_parameter("material_rows"), MaterialRows.rows(merged).size()])
	var got := _row(merged, r)
	var want := MaterialRows.row_vectors(old)
	for k in want.size():
		if not got[k].is_equal_approx(want[k]):
			_fail("%s: row %d vec4 %d is %s, was %s" % [what, r, k, got[k], want[k]])
	# A few straight from the old material's own uniforms.
	var albedo: Color = old.get_shader_parameter("albedo") if old.get_shader_parameter("albedo") != null else Color.WHITE
	var lin := albedo.srgb_to_linear()
	var rough: Variant = old.get_shader_parameter("roughness")
	var part := float(old.get_shader_parameter("part_data")) if bool(old.get_shader_parameter("part_colors")) else 0.0
	if not Vector3(got[0].x, got[0].y, got[0].z).is_equal_approx(Vector3(lin.r, lin.g, lin.b)) \
			or (rough != null and not is_equal_approx(got[2].x, float(rough))) or not is_equal_approx(got[3].x, part):
		_fail("%s: row %d albedo %s roughness %s part %s, was %s %s %s" % [what, r, got[0], got[2].x, got[3].x, lin, rough, part])


## Row `r` of a merged material's table.
static func _row(merged: ShaderMaterial, r: int) -> Array:
	var table: Array = merged.get_shader_parameter("material_table")
	return table.slice(r * MaterialRows.ROW_SIZE, (r + 1) * MaterialRows.ROW_SIZE)


static func _close(a: Vector3, b: Vector3, tolerance: float) -> bool:
	return absf(a.x - b.x) <= tolerance and absf(a.y - b.y) <= tolerance and absf(a.z - b.z) <= tolerance


static func _triangles(arrays: Array) -> int:
	if arrays[Mesh.ARRAY_INDEX] != null and not (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).is_empty():
		return (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	return (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3


## The triangles' corners (vertex indices) of a surface, only those of row `row` (CUSTOM2) when it
## isn't -1. A triangle's corners must share their row.
func _corners(arrays: Array, row: int) -> PackedInt32Array:
	var all := PackedInt32Array()
	if arrays[Mesh.ARRAY_INDEX] != null and not (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).is_empty():
		all = arrays[Mesh.ARRAY_INDEX]
	else:
		all.resize((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
		for k in all.size():
			all[k] = k
	if row < 0:
		return all
	var rows: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM2]
	var out := PackedInt32Array()
	for t in range(0, all.size() - 2, 3):
		var r := int(rows[all[t]])
		if r != int(rows[all[t + 1]]) or r != int(rows[all[t + 2]]):
			_fail("a triangle's corners are in rows %d, %d, %d" % [r, rows[all[t + 1]], rows[all[t + 2]]])
		if r == row:
			out.append(all[t])
			out.append(all[t + 1])
			out.append(all[t + 2])
	return out


## The sum of an array's values over these corners, as a Vector4.
static func _corner_sum(arrays: Array, t: int, corners: PackedInt32Array) -> Vector4:
	var data = arrays[t]
	var count := (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var per: int = data.size() / maxi(count, 1)
	var sum := Vector4.ZERO
	for c in corners:
		match typeof(data):
			TYPE_PACKED_VECTOR3_ARRAY:
				var v: Vector3 = data[c]
				sum += Vector4(v.x, v.y, v.z, 0.0)
			TYPE_PACKED_VECTOR2_ARRAY:
				var v: Vector2 = data[c]
				sum += Vector4(v.x, v.y, 0.0, 0.0)
			TYPE_PACKED_COLOR_ARRAY:
				var v: Color = data[c]
				sum += Vector4(v.r, v.g, v.b, v.a)
			TYPE_PACKED_FLOAT32_ARRAY:
				for k in mini(per, 4):
					sum[k] += data[c * per + k]
			TYPE_PACKED_BYTE_ARRAY:
				for k in mini(per, 4):
					sum[k] += data[c * per + k] / 255.0
	return sum


## The row of `material` (merged) whose row material is named `row_name`, or -1.
static func _row_named(material: Material, row_name: String) -> int:
	var rows := MaterialRows.rows(material)
	for r in rows.size():
		if (rows[r] as ShaderMaterial).resource_name.contains(row_name):
			return r
	return -1


## Materials changed by name after loading change only their rows (material_rows.gd edit).
func _edits_check() -> void:
	# The row uniforms' defaults, read from the include's code (headless has no renderer to ask).
	MaterialRows._value(ShaderMaterial.new(), "grain")
	var kinds := {"albedo": TYPE_COLOR, "emission": TYPE_COLOR, "grime_color": TYPE_COLOR, "edge_color": TYPE_COLOR,
		"rust_color": TYPE_COLOR, "dust_color": TYPE_COLOR, "part_weathering": TYPE_VECTOR4,
		"part_light": TYPE_VECTOR2, "activity_glow": TYPE_BOOL, "part_colors": TYPE_BOOL, "glow_fades": TYPE_BOOL,
		"skin_mode": TYPE_INT, "skin_tint2": TYPE_COLOR, "emission_from_paint": TYPE_BOOL,
		"glow_keeps_albedo": TYPE_BOOL, "modeller_tex": TYPE_BOOL, "wet_rock": TYPE_BOOL,
		"organic_surface": TYPE_INT}
	for u: String in MaterialRows.ROW_PARAMS:
		var d: Variant = MaterialRows._defaults.get(u)
		if typeof(d) != int(kinds.get(u, TYPE_FLOAT)):
			_fail("the default of %s is %s" % [u, d])
	if MaterialRows._defaults.get("grime_color") != Color(0.13, 0.11, 0.09) or not is_equal_approx(float(MaterialRows._defaults.get("grain", 0.0)), 0.08) \
			or MaterialRows._defaults.get("part_weathering") != Vector4(0.4, 0.2, 0.6, 0.1) or MaterialRows._defaults.get("albedo") != Color(1, 1, 1, 1):
		_fail("the row uniforms' defaults misread: %s" % MaterialRows._defaults)
	# A tier's paint: the row recoloured, no sprite or part colours there. Placeholders' express splitter is its
	# splitter repainted (FUE5's, above it, has a model per tier), so both come from that pack.
	var base := ModelLibrary.mesh_for("splitter@builtin:placeholders")
	var tier := ModelLibrary.mesh_for("express-splitter@builtin:placeholders")
	var bm := base.surface_get_material(0) as ShaderMaterial
	var tm := tier.surface_get_material(0) as ShaderMaterial
	var paint := _row_named(tm, ModelLibrary.TIER_MATERIAL)
	if paint < 0 or MaterialRows.rows(bm).size() != MaterialRows.rows(tm).size():
		_fail("the express splitter's paint isn't a row of its one material (%d rows)" % MaterialRows.rows(tm).size())
	else:
		var colour: Color = ModelLibrary.TIER_TINTS["express-splitter"][1]
		var lin := colour.srgb_to_linear()
		var a: Vector4 = _row(tm, paint)[0]
		var d: Vector4 = _row(tm, paint)[3]
		if not Vector3(a.x, a.y, a.z).is_equal_approx(Vector3(lin.r, lin.g, lin.b)) or d.x != 0.0:
			_fail("the express splitter's paint row: albedo %s, part colours %s" % [a, d.x])
		for r in MaterialRows.rows(tm).size():
			if r != paint and _row(tm, r) != _row(bm, r):
				_fail("the express splitter's row %d changed with the paint" % r)
		if MaterialRows.rows(bm)[paint] == MaterialRows.rows(tm)[paint]:
			_fail("the tier's paint row is the base's own material, not a copy")
	# A belt's moving surface: its row flagged, the speed and chevron the model's (Wube3DP's, drawn slats:
	# FUE5's, above it, is textured and never merged).
	var belt := ModelLibrary.mesh_for("fast-transport-belt@builtin:wube3dp").surface_get_material(0) as ShaderMaterial
	var moving := _row_named(belt, ModelLibrary.BELT_MATERIAL)
	if moving < 0:
		_fail("the fast belt's moving surface isn't a row")
	else:
		var flags := int((_row(belt, moving)[1] as Vector4).w)
		var others := 0
		for r in MaterialRows.rows(belt).size():
			if r != moving and int((_row(belt, r)[1] as Vector4).w) & MaterialRows.FLAG_BELT:
				others += 1
		if (flags & MaterialRows.FLAG_BELT) == 0 or others > 0 or not is_equal_approx(float(belt.get_shader_parameter("belt_speed")), 3.75) \
				or belt.get_shader_parameter("belt_chevron") != ModelLibrary.BELT_CHEVRONS["fast-"]:
			_fail("the fast belt: belt flag %d (others %d), speed %s, chevron %s" % [flags, others, belt.get_shader_parameter("belt_speed"), belt.get_shader_parameter("belt_chevron")])
	# The infinity pipe: the pipe tinted as a whole.
	var pipe := ModelLibrary.mesh_for("infinity-pipe").surface_get_material(0) as ShaderMaterial
	if pipe.get_shader_parameter("model_tint") != ModelLibrary.WHOLE_TINTS["infinity-pipe"][1]:
		_fail("the infinity pipe's tint is %s" % pipe.get_shader_parameter("model_tint"))
	# A remnant: every row burnt (no sprite, no glow, darker), the model's sprite and motion off.
	var burnt := ModelLibrary._burnt(ModelLibrary.mesh_for("burner-mining-drill@builtin:placeholders").surface_get_material(0)) as ShaderMaterial
	var all_burnt := MaterialRows.rows(burnt).size() > 1
	for r in MaterialRows.rows(burnt).size():
		var flags := int((_row(burnt, r)[1] as Vector4).w)
		var tone: Vector4 = _row(burnt, r)[4]
		all_burnt = all_burnt and (flags & MaterialRows.FLAG_GLOW) == 0 and is_equal_approx(tone.w, 0.45)
	if not all_burnt or burnt.get_shader_parameter("activity_glow") != false or burnt.get_shader_parameter("animated") != false:
		_fail("the burner drill's remnant isn't burnt in every row (%d rows)" % MaterialRows.rows(burnt).size())
	var tower := ModelLibrary.mesh_for("heating-tower")
	var tower_burnt := ModelLibrary._burnt(tower.surface_get_material(0)) as ShaderMaterial
	if not is_equal_approx(float(tower_burnt.get_shader_parameter("value")), 0.45) \
			or float(tower_burnt.get_shader_parameter("emission_energy")) != 0.0 \
			or tower_burnt.get_shader_parameter("activity_glow") != false \
			or tower_burnt.get_shader_parameter("animated") != false:
		_fail("the heating tower's remnant isn't darkened with glow and motion off")
	if not ModelLibrary.glows(tower):
		_fail("the heating tower's fire doesn't count as glowing")
	if ModelLibrary.organic_surface_kind("chitin_big") != 2 or ModelLibrary.organic_surface_kind("flesh_biter") != 1 \
			or ModelLibrary.organic_surface_kind("steel_dark") != 0 or ModelLibrary.organic_surface_kind("flesh_biter", true) != 0 \
			or ModelLibrary.organic_surface_kind("flesh_eye") != 0 or ModelLibrary.organic_surface_kind("cliff-gleba-flesh-root") != 0:
		_fail("organic_surface_kind classification mismatch")
	for biter_id in ["big-biter@builtin:placeholders", "big-biter@builtin:wube3dp"]:
		var biter_mesh := ModelLibrary.mesh_for(biter_id)
		var biter_mat := biter_mesh.surface_get_material(0) as ShaderMaterial
		var chitin_row := _row_named(biter_mat, "chitin_big")
		var flesh_row := _row_named(biter_mat, "flesh_biter")
		var leg_row := _row_named(biter_mat, "flesh_leg")
		if chitin_row < 0 or flesh_row < 0 or leg_row < 0:
			_fail("%s missing expected organic material rows" % biter_id)
		else:
			var cf := int((_row(biter_mat, chitin_row)[1] as Vector4).w)
			var ff := int((_row(biter_mat, flesh_row)[1] as Vector4).w)
			var lf := int((_row(biter_mat, leg_row)[1] as Vector4).w)
			if (cf & MaterialRows.FLAG_ORGANIC_CHITIN) == 0 or (ff & MaterialRows.FLAG_ORGANIC_FLESH) == 0 \
					or (lf & MaterialRows.FLAG_ORGANIC_FLESH) == 0:
				_fail("%s organic row flags wrong: chitin=%d flesh=%d leg=%d" % [biter_id, cf, ff, lf])
	for r in MaterialRows.rows(bm).size():
		var bf := int((_row(bm, r)[1] as Vector4).w)
		if (bf & (MaterialRows.FLAG_ORGANIC_FLESH | MaterialRows.FLAG_ORGANIC_CHITIN)) != 0:
			_fail("splitter row %d unexpectedly flagged organic (%d)" % [r, bf])
	# S10: dead sprite-projection uniforms and varyings removed from factorio_material.gdshaderinc.
	var shader_names := {}
	for u: Dictionary in (belt.shader as Shader).get_shader_uniform_list():
		shader_names[str(u["name"])] = true
	for dead in ["sprite_cells", "sprite_tex", "depth_on", "depth_tex"]:
		if shader_names.has(dead):
			_fail("dead sprite-projection uniform %s still present in factorio_material shader" % dead)


## FUE5's stone walls laid out as the world draws them (world.gd _connect_wall's mask, model_name):
## a ring, an L, a T, a cross, a lone wall and a 2x2 block. Every tile asks for the shape its
## neighbours make and gets FUE5's file of that name (no other pack's piece mixed in); each piece
## reaches the tile edges it joins and stops short of the others; its ends are closed (FUE5's cuts
## were open underneath, so a lone pillar's, an end's and a corner's showed the inside); and an arm
## across the hub (a corner's, a T's) runs over the hub's narrow top (it began past it: a gap).
func _wall_layout_check() -> void:
	var tiles := {}
	for x in 5:
		for y in 5:
			if x == 0 or x == 4 or y == 0 or y == 4:
				tiles[Vector2i(x, y)] = true
	for i in 4:
		tiles[Vector2i(8, i)] = true
		tiles[Vector2i(8 + i, 3)] = true
	for i in 5:
		tiles[Vector2i(14 + i, 0)] = true
		tiles[Vector2i(22, i)] = true
		tiles[Vector2i(20 + i, 2)] = true
	for i in range(1, 4):
		tiles[Vector2i(16, i)] = true
	tiles[Vector2i(27, 2)] = true
	for d in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
		tiles[Vector2i(30, 1) + d] = true
	var steps := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	ModelLibrary.ModelPacks.configure("", [], [])
	ModelLibrary.ModelPacks.wait()  # the built-in packs checked for copies of Factorio's files first
	var shapes := {}
	for t: Vector2i in tiles:
		var mask := 0
		for i in 4:
			if tiles.has(t + steps[i]):
				mask |= 1 << i
		if mask & 6 == 6 and tiles.has(t + Vector2i(1, 1)):
			mask |= 16
		var name := ModelLibrary.model_name("stone-wall", "wall", {"wc": mask})
		var path := ModelLibrary.ModelPacks.find(name, true)
		if path != ModelLibrary.ModelPacks.BUILTIN_DIR + "fue5/" + name + ".glb":
			_fail("wall at %s (mask %d): %s drawn from %s, not FUE5's" % [t, mask, name, path])
		shapes[name] = mask
	for name: String in shapes:
		var load := ModelLibrary.Load.new()
		load.path = ModelLibrary.ModelPacks.BUILTIN_DIR + "fue5/" + name + ".glb"
		load.run()
		if not load.ok:
			_fail("%s: didn't parse" % name)
			continue
		var mesh := ModelLibrary._commit_load(load, [])
		var mask: int = shapes[name]
		var box := mesh.get_aabb()
		# Sides north, east, south, west: glTF -z, +x, +z, -x. A fill block reaches past east and south.
		var reach := [-box.position.z, box.end.x, box.end.z, -box.position.x]
		for i in 4:
			var joined := mask & (1 << i) != 0
			if mask & 16 and (i == 1 or i == 2):
				continue
			if joined and absf(float(reach[i]) - 0.5) > 0.01:
				_fail("%s: reaches %.3f towards side %d it joins, not the tile edge" % [name, float(reach[i]), i])
			if not joined and float(reach[i]) > 0.45:
				_fail("%s: reaches %.3f towards side %d it doesn't join" % [name, float(reach[i]), i])
		var tris := PackedVector3Array()
		var edges := {}
		for j in mesh.get_surface_count():
			var a := mesh.surface_get_arrays(j)
			var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var ix := PackedInt32Array(a[Mesh.ARRAY_INDEX]) if a[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(v.size()))
			for k in ix:
				tris.append(v[k])
			for k in range(0, ix.size(), 3):
				for e in 3:
					var p := Vector3i((v[ix[k + e]] * 1000.0).round())
					var q := Vector3i((v[ix[k + (e + 1) % 3]] * 1000.0).round())
					var key := "%s%s" % [p, q] if str(p) < str(q) else "%s%s" % [q, p]
					if not edges.has(key):
						edges[key] = [p, q, 0]
					edges[key][2] += 1
		# Open edges above the plate off the tile's edges (where the neighbour's piece meets this one):
		# an end left open. A few hairline ones where the budget's decimation met a seam are let be.
		var open := 0
		for key: String in edges:
			var entry: Array = edges[key]
			if int(entry[2]) != 1:
				continue
			var p: Vector3i = entry[0]
			var q: Vector3i = entry[1]
			var on_edge := false
			for c in [0, 2]:
				if absi(absi(p[c]) - 500) <= 2 and absi(absi(q[c]) - 500) <= 2:
					on_edge = true
			if p.y > 150 and q.y > 150 and not on_edge:
				open += 1
		if open > 24:
			_fail("%s: %d open edges on its ends (the inside shows)" % [name, open])
		# A hub runs east-west when the piece joins east or west; an arm north or south then crosses it
		# and must cover the hub's narrow top between its middle (0.1 out) and its end (0.272 out).
		if mask & 10 != 0:
			for i in [0, 2]:
				if mask & (1 << i) == 0:
					continue
				# Straight down at the middle of that stretch: the wall's top, not the ground.
				var at := Vector3(0.0, 0.0, -0.19 if i == 0 else 0.19)
				var top := -1.0
				for k in range(0, tris.size(), 3):
					var y := _height_at(tris[k], tris[k + 1], tris[k + 2], at)
					top = maxf(top, y)
				if top < 1.0:
					_fail("%s: nothing over the hub's top towards side %d: a gap at the joint" % [name, i])
	print("WALL LAYOUT: %d wall shapes checked" % shapes.size())


## The height where a vertical line through `at` (x, z) crosses triangle a b c, -1 when it misses.
static func _height_at(a: Vector3, b: Vector3, c: Vector3, at: Vector3) -> float:
	var d := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
	if absf(d) < 1e-9:
		return -1.0
	var u := ((b.z - c.z) * (at.x - c.x) + (c.x - b.x) * (at.z - c.z)) / d
	var v := ((c.z - a.z) * (at.x - c.x) + (a.x - c.x) * (at.z - c.z)) / d
	if u < 0.0 or v < 0.0 or u + v > 1.0:
		return -1.0
	return u * a.y + v * b.y + (1.0 - u - v) * c.y


class _AnimWorld:
	extends Node
	var chunks := {}
	var working := {}
	var entities := {}


class _AnimChunk:
	extends RefCounted
	var anim_groups: Array = []


class _AnimRec:
	extends RefCounted
	var chunk := Vector2i.ZERO
	var key := 999


## All three assembling machines resolve to rebuilt Placeholders PBR models, expose CYCLES parts with valid
## swept custom_aabb, bind PBR maps + status glow, and toggle working state 0 -> 1 via Anim.
func _assembling_machines_anim_check() -> void:
	var expected := {
		"assembling-machine-1": [8, ModelLibrary.ModelPacks.BUILTIN_DIR + "placeholders/assembling-machine-1.glb"],
		"assembling-machine-2": [9, ModelLibrary.ModelPacks.BUILTIN_DIR + "placeholders/assembling-machine-2.glb"],
		"assembling-machine-3": [10, ModelLibrary.ModelPacks.BUILTIN_DIR + "placeholders/assembling-machine-3.glb"],
	}
	var fake_world := _AnimWorld.new()
	var fake_chunk := _AnimChunk.new()
	fake_world.chunks[Vector2i.ZERO] = fake_chunk
	var anim := Anim.new()
	anim.world = fake_world
	var host := Node3D.new()
	host.add_child(anim)
	get_root().add_child(host)
	var rec := _AnimRec.new()
	for name: String in expected.keys():
		var spec: Array = expected[name]
		var min_parts := int(spec[0])
		var want_path := str(spec[1])
		var resolved := ModelLibrary.ModelPacks.find(name, true)
		if resolved != want_path:
			_fail("%s: default pack resolved to %s, expected %s" % [name, resolved, want_path])
		var mesh := ModelLibrary.mesh_for(name)
		if mesh == null:
			_fail("%s: mesh_for returned null" % name)
			continue
		var has_glow := false
		var has_pbr := false
		for i in mesh.get_surface_count():
			var mat := mesh.surface_get_material(i) as ShaderMaterial
			if mat == null:
				continue
			if mat.get_shader_parameter("activity_glow") == true:
				has_glow = true
			if mat.get_shader_parameter("use_albedo_tex") == true and mat.get_shader_parameter("use_orm_tex") == true and mat.get_shader_parameter("use_normal_tex") == true and mat.get_shader_parameter("modeller_tex") == true:
				has_pbr = true
		if not has_glow:
			_fail("%s: missing activity_glow status light surface" % name)
		if not has_pbr:
			_fail("%s: missing full PBR texture uniforms (albedo/orm/normal/modeller_tex)" % name)
		var parts := ModelLibrary.parts_for(name)
		if parts.size() != min_parts:
			_fail("%s: expected %d moving parts, got %d" % [name, min_parts, parts.size()])
		fake_chunk.anim_groups.clear()
		fake_world.working[999] = 0
		anim.reset()
		for pi in parts.size():
			var p: ModelLibrary.AnimPart = parts[pi]
			Anim.setup_part(p)
			if p.motion != Anim.MOTION_CYCLE or p.rate <= 0.0:
				_fail("%s: part %s has motion=%d rate=%.3f (expected MOTION_CYCLE)" % [name, p.kind, p.motion, p.rate])
			if not (p.mesh is ArrayMesh) or (p.mesh as ArrayMesh).custom_aabb.get_volume() <= 0.0:
				_fail("%s: part %s missing swept custom_aabb" % [name, p.kind])
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_custom_data = true
			mm.mesh = p.mesh
			mm.instance_count = 1
			mm.set_instance_transform(0, p.turned(0.0))
			mm.set_instance_custom_data(0, Color.BLACK)
			var g := Anim.Group.new()
			g.mm = mm
			g.part = p
			g.keys = [999]
			g.units = PackedInt64Array([999])
			g.bases = [p.turned(0.0)]
			g.stateful = PackedByteArray([1])
			g.customs = PackedColorArray([Color.BLACK])
			fake_chunk.anim_groups.append(g)
			Anim.place(g, anim, fake_world.working)
		fake_world.working[999] = 1
		anim.state_changed(rec)
		for g: Anim.Group in fake_chunk.anim_groups:
			var custom := g.mm.get_instance_custom_data(0)
			var flags := int(floor(-custom.b - 1.0))
			if (flags & 1) == 0:
				_fail("%s: anim.state_changed did not enable working bit on part %s (custom=%s)" % [name, g.part.kind, str(custom)])
				break
	anim.reset()
	host.queue_free()
	fake_world.queue_free()


## ready() starts a job and returns at once; poll() finishes it; the mesh is the one mesh_for gives.
func _async_check() -> void:
	var name := "assembling-machine-2"
	var t0 := Time.get_ticks_usec()
	var first := ModelLibrary.ready(name)
	var asked_usec := Time.get_ticks_usec() - t0
	if first:
		_fail("ready(%s) was true before any job ran" % name)
	if asked_usec > 3000:
		_fail("ready() took %d us: it should only queue a job" % asked_usec)
	var gen := ModelLibrary.generation
	var frames := 0
	while not ModelLibrary.ready(name) and frames < 600:
		ModelLibrary.poll()
		frames += 1
		OS.delay_msec(5)
	if frames >= 600:
		_fail("the job for %s never finished" % name)
	elif ModelLibrary.generation == gen:
		_fail("generation didn't go up when %s was ready" % name)
	var mesh := ModelLibrary.mesh_for(name)
	if mesh == null or not mesh.has_meta(ModelLods.ARRAYS_META):
		_fail("%s has no CPU arrays kept" % name)
	# Its remnant is broken up on a worker thread too, the same as done on the spot.
	var waited := 0
	while not ModelLibrary.remnant_ready(name) and waited < 600:
		ModelLibrary.poll()
		waited += 1
		OS.delay_msec(5)
	var remnant := ModelLibrary.remnant_mesh(name)
	var direct := {}
	var src := ModelLibrary.mesh_for(name) as ArrayMesh
	ModelLibrary._broken_arrays(ModelLibrary._surfaces_of(src), maxf(src.get_aabb().end.y, 0.1), hash(name), direct)
	var same := remnant != null and remnant.get_surface_count() == direct.size()
	if same:
		var k := 0
		for i in direct.keys():
			same = same and _triangles(remnant.surface_get_arrays(k)) == _triangles(direct[i])
			k += 1
	if not same:
		_fail("the remnant made on a worker thread differs from one made directly (%s surfaces, %d direct, waited %d)" % [remnant.get_surface_count() if remnant else -1, direct.size(), waited])
	# A tier made from a ready base, and a model with no file: ready at once.
	if not ModelLibrary.ready("no-such-model-anywhere"):
		_fail("a model with no file wasn't ready at once")
	_assembling_machines_anim_check()
	print("MODEL LOAD checked %d models | surfaces %d -> %d | ready() %d us | job done after %d polls | FAILS: %d"
		% [_checked, _surfaces_before, _surfaces_after, asked_usec, frames, _fails])
	print("MODEL LOAD FAILS: %d" % _fails)
	TestEnv.clean()
	quit(1 if _fails > 0 else 0)
