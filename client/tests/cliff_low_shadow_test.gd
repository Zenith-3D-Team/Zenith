extends SceneTree
## Cliffs' rock sits on the low ground (the ground without its cliffs' terraces: model_library.gd sets
## its materials' ground_low). What stands in for it must be lifted the same way: its shadow stand-in
## (model_lods.gd) and its far merge (far_chunks.gd). Lifted by the terraced ground, a cliff's stand-in
## floated up to the terrace's height over the rock (2.2 tiles with Terrain Elevation) and its shadow
## covered the whole rock and the ground at its foot: cliffs near black in daylight.
##   godot --headless --path client -s res://tests/cliff_low_shadow_test.gd

const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const FarChunks := preload("res://scripts/world/far_chunks.gd")
const MaterialRows := preload("res://scripts/world/material_rows.gd")

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _mesh_with(material_name: String) -> ArrayMesh:
	var base := StandardMaterial3D.new()
	base.resource_name = material_name
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, ModelLibrary._factorio(base, false, false, false))
	return mesh


func _bake() -> Variant:
	var b := FarChunks.Bake.new()
	b.verts = PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)])
	b.colors = PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE])
	b.indices = PackedInt32Array([0, 1, 2])
	return b


func _init() -> void:
	# The models: a cliff's rock material sits low, a rock's and a building's don't.
	var cliff := _mesh_with("cliff-rock")
	var rock := _mesh_with("rock")
	var building := _mesh_with("steel")
	check((cliff.surface_get_material(0) as ShaderMaterial).get_shader_parameter("ground_low") == true,
		"a cliff's material has ground_low (model_library.gd)")
	check(ModelLods.sits_low(cliff), "a cliff sits on the low ground")
	check(not ModelLods.sits_low(rock) and not ModelLods.sits_low(building), "a rock and a building don't")
	# A merged material (Settings > Graphics > Merged materials): its rows are looked at.
	var merged := ArrayMesh.new()
	var arrays := cliff.surface_get_arrays(0)
	merged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	merged.surface_set_material(0, MaterialRows.make([rock.surface_get_material(0), cliff.surface_get_material(0)]))
	check(ModelLods.sits_low(merged), "a merged material with a cliff row sits low")

	# Shadow stand-ins: the cliff's is lifted by the low ground, the others' by the ground.
	var low := ModelLods.material_for(cliff)
	check(low == ModelLods.low_material() and low.get_shader_parameter("ground_low") == true,
		"a cliff's stand-in material lifts by the low ground")
	check(ModelLods.material_for(rock) == ModelLods.material(), "a rock's stand-in keeps the plain one")
	check(ModelLods.material().get_shader_parameter("ground_low") != true, "the plain stand-in lifts by the ground")
	var src := (preload("res://shaders/shadow_stand_in.gdshader") as Shader).code
	check(src.contains("uniform bool ground_low") and src.contains("ground_lift_low(VERTEX, MODEL_MATRIX, ground_low)"),
		"shadow_stand_in.gdshader seats a cliff as its model is (ground_lift_low)")
	ModelLods.low_stand_ins = false
	check(ModelLods.material_for(cliff) == ModelLods.material(), "--cliff-low-shadow=old: the plain stand-in, as before")
	ModelLods.low_stand_ins = true

	# Far merges: models on the low ground in a surface of their own, with the low material.
	var msrc := (preload("res://shaders/far_merged.gdshader") as Shader).code
	check(msrc.contains("uniform bool ground_low") and msrc.contains("ground_lift_low(VERTEX, MODEL_MATRIX, ground_low)"),
		"far_merged.gdshader seats a cliff as its model is (ground_lift_low)")
	check(FarChunks.low_material().get_shader_parameter("ground_low") == true, "the far low material has ground_low")
	check(FarChunks.sits_low(cliff) and not FarChunks.sits_low(rock), "far merges sort a cliff as low")
	var xf := [Transform3D(Basis(), Vector3(2, 0, 0)), Transform3D(Basis(), Vector3(5, 0, 0))]
	var m := FarChunks.Merge.new()
	m.material = FarChunks.material()
	m.nature_material = FarChunks.nature_material()
	m.low_material = FarChunks.low_material()
	m.crown_material = FarChunks.crown_material()
	m.groups = [[_bake(), xf, null, false, false], [_bake(), [xf[0]], null, true, false], [_bake(), xf, null, false, true]]
	m.run()
	check(m.mesh != null and m.mesh.get_surface_count() == 3, "buildings, trees and cliffs: three surfaces")
	check(m.triangles == 5, "five triangles in all")
	if m.mesh != null and m.mesh.get_surface_count() == 3:
		check(m.mesh.surface_get_material(2) == FarChunks.low_material(), "surface 2 is the cliffs'")
		check(m.mesh.surface_get_material(0) == FarChunks.material(), "surface 0 still the buildings'")
	# --cliff-fit: the model, its stand-in, its far merge and the distant horizon's block all seat a cliff by the
	# one function (ground_height.gdshaderinc ground_lift_cliff, its CPU twin GroundHeight.cliff_lift:
	# cliff_fit_test.gd), and nothing lifts by ground_low any other way.
	var inc := FileAccess.get_file_as_string("res://shaders/ground_height.gdshaderinc").replace("\r", "")
	check(inc.contains("vec3 ground_lift_cliff(vec3 v, mat4 model)") and inc.contains("cliff_seat(w.y, g.x, g.y, cliff_terrace_near(w.xz))")
		and inc.contains("return max(low + y * f, high - 0.1);") and inc.contains("float f = max(1.0, terrace * 0.5);"),
		"ground_height.gdshaderinc: ground_lift_cliff seats by cliff_seat (max(low + y f, high - 0.1), f = max(1, D / 2))")
	check(inc.contains("return low ? ground_lift_cliff(v, model) : ground_lift_of(v, model, false);"), "ground_lift_low: a cliff by ground_lift_cliff")
	check(inc.contains("if (f3d_cliff_fit < 0.5) {\n\t\treturn ground_lift_of(v, model, true);"),"--cliff-fit=off: on the low ground, as before")
	var mat := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc").replace("\r", "")
	check(mat.count("ground_lift_low(VERTEX, MODEL_MATRIX, ground_low)") == 2 and not mat.contains("ground_lift_of(VERTEX, MODEL_MATRIX, ground_low)"),
		"factorio_material.gdshaderinc seats cliffs by ground_lift_low (leaves cut and not)")
	var lod := FileAccess.get_file_as_string("res://shaders/lod_common.gdshaderinc").replace("\r", "")
	check(lod.contains("if (vkind == 4 && f3d_cliff_fit > 0.5) {\n\t\tVERTEX = ground_lift_cliff(local_v, MODEL_MATRIX);"),
		"the distant horizon's cliff blocks (kind 4) seated the same way")
	var ter := FileAccess.get_file_as_string("res://shaders/terrain_common.gdshaderinc").replace("\r", "")
	# (cliff-wall2: the global's sign picks ragged scree, positive, or the even band, --cliff-scree-look=old.)
	check(ter.contains("ground_cliff_near(world_pos.xz) * abs(f3d_cliff_tint)") and ter.contains("vec3 scree_rgb = CLIFF_SCREE;")
		and ter.contains("if (f3d_cliff_tint > 0.0 && cliff_near > 0.001) {") and ter.contains("albedo = mix(albedo, scree_rgb"),
		"the ground near cliffs tinted from the field's blue (--cliff-ground-tint; ragged, the even band with --cliff-scree-look=old)")
	print("cliff_low_shadow_test: %s" % ("PASS" if fails == 0 else "FAILS %d" % fails))
	quit(1 if fails else 0)
