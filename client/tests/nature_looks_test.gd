extends SceneTree
## Trees and rocks varied as Factorio varies them (scripts/world/nature_looks.gd): variations picked
## by the prototypes' weights, standing ones scaled to their pictures, fallen ones laid on the
## ground, rocks one of their pictures' sizes; a tree's leaf materials given its prototype's
## colours, and its leaf cards the atlas of its leaves (built from a picture of our own here, and
## from the Factorio install's when there is one); the leaf shader's new uniforms there.
##   godot --headless --path client -s res://tests/nature_looks_test.gd [-- --dump=<dir>]
## --dump writes the atlases made from the install into <dir> (keep them out of the repo: they are
## made of Factorio's pictures), to compare with tools/models/nature/tree_sprites.py's.

const NatureLooks := preload("res://scripts/world/nature_looks.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
const LeafShader := preload("res://shaders/factorio_material_leaf.gdshader")
const SolidShader := preload("res://shaders/factorio_material.gdshader")
const MaterialRows := preload("res://scripts/world/material_rows.gd")
const TestEnv := preload("res://tests/test_env.gd")
const Looks := preload("res://scripts/world/looks.gd")
const FarChunks := preload("res://scripts/world/far_chunks.gd")

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _init() -> void:
	TestEnv.isolate("nature-looks-test")
	ItemIcons.factorio_data_dir()
	var dump := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--dump="):
			dump = a.substr(7)
	_data()
	_weights()
	_placed()
	_synthetic_atlas()
	_shader()
	_matte()
	_synthetic_grain()
	_dressed(dump)
	# Loading the trees starts their leaf atlases and grain on workers, which _dressed waits for only
	# with an install. Without one Godot quit with them still running and crashed on its way out, after
	# PASS (CI's exit code; 0xC0000005 on Windows): waited for here, as world.gd does when the game quits.
	NatureLooks.finish_all()
	ModelLods.finish_all()
	print("nature_looks_test: %s" % ("PASS" if fails == 0 else "FAILS %d" % fails))
	quit(1 if fails else 0)


## The trees' matte switch (--tree-sheen=old) reaches the shaders' global while running, and the far merged
## mesh's trees and plants get a material of their own with the matte on, buildings' staying as they were.
func _matte() -> void:
	var was := Looks.tree_sheen_old
	Looks.tree_sheen_old = false
	check(is_equal_approx(Looks.tree_matte_value(), 1.0), "tree matte 1 by default")
	Looks.tree_sheen_old = true
	check(is_equal_approx(Looks.tree_matte_value(), 0.0), "--tree-sheen=old: the value is 0")
	Looks.put_tree_matte()  # the call the running paths make (_ready, _put_on, put_idle_globals): no error
	Looks.put_idle_globals({})
	Looks.tree_sheen_old = was
	Looks.put_tree_matte()
	var nat := FarChunks.nature_material()
	var bld := FarChunks.material()
	check(nat != bld and nat.shader == bld.shader, "far trees' material is its own, on the merged shader")
	check(bool(nat.get_shader_parameter("nature")), "far trees' material has nature on")
	check(not bool(bld.get_shader_parameter("nature") if bld.get_shader_parameter("nature") != null else false), "far buildings' material has nature off")


func _data() -> void:
	for name in ["tree-01", "tree-05", "tree-08-brown", "tree-09-red"]:
		var e := NatureLooks.tree(name)
		check(not e.is_empty(), "%s has an entry" % name)
		check((e.get("weights", []) as Array).size() == (e.get("shapes", []) as Array).size(), "%s: a weight per shape" % name)
		check((e.get("tints", []) as Array).size() >= 2, "%s: its colours" % name)
	var e01 := NatureLooks.tree("tree-01")
	var fallen := 0
	for s: Array in e01.get("shapes", []):
		if float(s[2]) > 0.0:
			fallen += 1
	check(fallen == 2, "tree-01's k and l are fallen (%d)" % fallen)
	check(NatureLooks.tree("tree-06").get("leaves") == null, "tree-06 (strands, no cards) has no leaf atlas")


## Factorio's weights: a-h 1, i-j 0.3, k-l 0.05 (tree-01): a fallen tree about 1 in 87.
func _weights() -> void:
	var e := NatureLooks.tree("tree-01")
	var counts := PackedInt32Array()
	counts.resize(12)
	var n := 87000
	for i in n:
		counts[NatureLooks.variation(e, (float(i) + 0.5) / float(n))] += 1
	check(absf(counts[0] / float(n) - 1.0 / 8.7) < 0.002, "variation a grows 1 in 8.7 (%d)" % counts[0])
	check(absf((counts[10] + counts[11]) / float(n) - 0.1 / 8.7) < 0.001, "fallen ones 1 in 87 (%d)" % (counts[10] + counts[11]))
	check(NatureLooks.variation(e, 0.0) == 0 and NatureLooks.variation(e, 0.99999) == 11, "the ends of the range")


func _placed() -> void:
	var at := Vector3(10.0, 0.0, -4.0)
	var standing := 0
	var lying := 0
	var heights := []
	for i in 4000:
		var h := hash(Vector2i(i * 97, i * 31))
		var t: Variant = NatureLooks.placed("tree-01", h, at)
		check(t is Transform3D, "a tree is placed")
		if not t is Transform3D:
			return
		var up := (t as Transform3D).basis * Vector3.UP
		if up.normalized().y > 0.9:
			standing += 1
			heights.append(up.length())
			check((t as Transform3D).origin.is_equal_approx(at), "a standing tree stands where it grows")
		else:
			lying += 1
			check(up.normalized().y < 0.2, "a fallen tree lies on the ground (its up %.2f)" % up.normalized().y)
			check(absf((t as Transform3D).origin.y) < 1e-4 and (t as Transform3D).origin.distance_to(at) > 0.5,
				"its root end lies behind it, on the ground")
	heights.sort()
	check(lying > 10 and lying < 120, "about 1 in 87 lies (%d of 4000)" % lying)
	check(heights[0] < 0.8 and heights[heights.size() - 1] > 0.97, "heights from the young ones' (%.2f) to the tallest (%.2f)" % [heights[0], heights[heights.size() - 1]])
	var rock: Variant = NatureLooks.placed("big-rock", hash(Vector2i(3, 4)), at)
	check(rock is Transform3D and ((rock as Transform3D).basis * Vector3.UP).normalized().y > 0.99, "a rock stands")
	check(NatureLooks.placed("tree-unknown", 1234, at) == null, "a tree without data: placed as before")
	check(NatureLooks.placed("iron-chest", 1234, at) == null, "not a tree or rock: placed as before")


## A picture of our own: leaves (bright) and gaps (dark) in a checker, a half see-through shadow.
func _synthetic_atlas() -> void:
	var img := Image.create(120, 120, false, Image.FORMAT_RGBA8)
	for y in 120:
		for x in 120:
			var leaf := ((x / 3) + (y / 3)) % 2 == 0
			var c := Color(0.5, 0.7, 0.3, 1.0) if leaf else Color(0.15, 0.22, 0.1, 1.0)
			if x > 100:
				c = Color(0.05, 0.05, 0.05, 0.5)  # the trunk's shadow: no leaf
			img.set_pixel(x, y, c)
	var mean := Color(0.5, 0.7, 0.3).srgb_to_linear()
	var leaves := {"file": "", "patch": 36, "patches": [[30, 30], [60, 60], [90, 40]], "mean": [mean.r, mean.g, mean.b]}
	var atlas := NatureLooks.atlas(leaves, img)
	check(atlas != null and atlas.get_width() == 144 and atlas.get_height() == 144, "a 4 x 4 atlas of 36-texel patches")
	if atlas == null:
		return
	check(atlas.has_mipmaps(), "mipmapped")
	var kept := 0
	var corner := atlas.get_pixel(0, 0).a
	var lum := 0.0
	for y in 36:
		for x in 36:
			var c := atlas.get_pixel(x, y)
			if c.a >= 0.5:
				kept += 1
				lum += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
	check(corner < 0.01, "a patch's corner is cut away")
	check(kept > 200 and kept < 1000, "about the leaves kept in a patch (%d of 1296)" % kept)
	check(absf(lum / maxi(kept, 1) - 0.5) < 0.08, "the leaves kept average half (the shader doubles it): %.3f" % (lum / maxi(kept, 1)))
	var mid := atlas.get_pixel(18 + 36 * 2, 18)
	check(mid.a >= 0 and true, "patch 3 made")
	check(NatureLooks.atlas({"patches": []}, img) == null, "no patches: no atlas")


func _shader() -> void:
	var names := {}
	for u: Dictionary in LeafShader.get_shader_uniform_list():
		names[str(u["name"])] = true
	for u in ["leaf_atlas", "leaf_atlas_cells", "leaf_atlas_texels", "leaf_detail", "leaf_tints", "leaf_tint_count", "leaf_core",
			"nature_grain"]:
		check(names.has(u), "the leaf shader has %s (it compiled)" % u)
	var solid := {}
	for u: Dictionary in SolidShader.get_shader_uniform_list():
		solid[str(u["name"])] = true
	check(solid.has("nature_grain") and not solid.has("leaf_atlas"), "the solid shader has nature_grain, not the leaves' (it compiled)")


## Grain from a picture of our own: stripes, mirrored out to the layer.
func _synthetic_grain() -> void:
	var img := Image.create(40, 40, false, Image.FORMAT_RGBA8)
	for y in 40:
		for x in 40:
			var v := 0.3 + 0.4 * float((x / 2) % 2)
			img.set_pixel(x, y, Color(v, v * 0.8, v * 0.6, 1.0))
	var layers := NatureLooks.grain_layers([{"file": "a", "rect": [4, 4, 16, 24]}, {"file": "a", "rect": [0, 0, 40, 40]}], 64, {"a": img})
	check(layers.size() == 2, "a layer for each region")
	if layers.size() != 2:
		return
	var a: Image = layers[0]
	check(a.get_width() == 64 and a.get_height() == 64 and a.has_mipmaps(), "64 x 64, mipmapped")
	var lum := 0.0
	for y in 64:
		for x in 64:
			var c := a.get_pixel(x, y)
			lum += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
	check(absf(lum / 4096.0 - 0.5) < 0.03, "a mean of a half (the shader doubles it): %.3f" % (lum / 4096.0))
	# Mirrored: texel 16 is texel 15 again, 17 is 14.
	check(a.get_pixel(16, 3).is_equal_approx(a.get_pixel(15, 3)) and a.get_pixel(17, 3).is_equal_approx(a.get_pixel(14, 3)), "mirrored past the region")
	check(NatureLooks.grain_layers([{"file": "missing", "rect": [0, 0, 4, 4]}], 64, {}).is_empty(), "a missing picture: no grain at all")


## The real models: their leaf materials dressed with their colours, and (with an install) the atlas.
func _dressed(dump: String) -> void:
	for name in ["tree-05", "tree-08-brown"]:
		var mesh := ModelLibrary.mesh_for(name) as ArrayMesh
		check(mesh != null, "%s loads" % name)
		if mesh == null:
			continue
		var cards := 0
		for i in mesh.get_surface_count():
			var m := mesh.surface_get_material(i) as ShaderMaterial
			if m != null and m.shader == LeafShader and m.get_shader_parameter("leaf_core") != true:
				cards += 1
				check(int(m.get_shader_parameter("leaf_tint_count")) == (NatureLooks.tree(name).tints as Array).size(),
					"%s's leaf cards have its colours" % name)
		check(cards == 1, "%s has its leaf cards" % name)
	if ItemIcons.factorio_data_dir() == "":
		print("nature_looks_test: no Factorio install, the atlas from its pictures not checked")
		return
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 20000:
		NatureLooks.poll()
		if NatureLooks._jobs.is_empty():
			break
		OS.delay_msec(20)
	var mesh := ModelLibrary.mesh_for("tree-05") as ArrayMesh
	var dressed := false
	for i in mesh.get_surface_count():
		var m := mesh.surface_get_material(i) as ShaderMaterial
		if m != null and m.get_shader_parameter("leaf_atlas") is Texture2D:
			dressed = float(m.get_shader_parameter("leaf_atlas_cells")) == 4.0
	check(dressed, "tree-05's leaf cards wear the atlas of its leaves")
	var rock := ModelLibrary.mesh_for("big-rock") as ArrayMesh
	var grained := false
	for i in rock.get_surface_count():
		var m := rock.surface_get_material(i) as ShaderMaterial
		if m != null and float(m.get_shader_parameter("nature_grain")) > 1.0:
			grained = true
	check(grained, "big-rock's stone has its grain")
	var bark := false
	for i in mesh.get_surface_count():
		var m := mesh.surface_get_material(i) as ShaderMaterial
		if m == null:
			continue
		for row: ShaderMaterial in MaterialRows.rows(m):
			if row.resource_name == "bark-05" and float(row.get_shader_parameter("nature_grain")) > 1.0:
				bark = true
		if m.resource_name == "bark-05" and float(m.get_shader_parameter("nature_grain")) > 1.0:
			bark = true
	check(bark, "tree-05's bark has its grain")
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 20000 and not NatureLooks._grain_job.is_empty():
		NatureLooks.poll()
		OS.delay_msec(20)
	check(NatureLooks._grain_texture != null and NatureLooks._grain_texture.get_layers() == (NatureLooks._grain.layers as Array).size(),
		"the grain layers made from the install")
	if dump != "":
		DirAccess.make_dir_recursive_absolute(dump)
		for name in ["tree-01", "tree-05", "tree-09"]:
			var ta := Time.get_ticks_usec()
			var a := NatureLooks.atlas(NatureLooks.tree(name).leaves)
			print("nature_looks_test: %s's atlas in %.0f ms" % [name, (Time.get_ticks_usec() - ta) / 1000.0])
			if a != null:
				a.clear_mipmaps()
				a.save_png(dump.path_join("gd-atlas-%s.png" % name))
		var tg := Time.get_ticks_usec()
		var layers := NatureLooks.grain_layers(NatureLooks._grain.layers, int(NatureLooks._grain.size))
		print("nature_looks_test: %d grain layers in %.0f ms" % [layers.size(), (Time.get_ticks_usec() - tg) / 1000.0])
		for i in layers.size():
			var g: Image = layers[i]
			g.clear_mipmaps()
			g.save_png(dump.path_join("gd-grain-%d.png" % i))
		print("nature_looks_test: atlases and grain in ", dump)
