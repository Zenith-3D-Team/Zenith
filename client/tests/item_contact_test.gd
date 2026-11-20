extends SceneTree
## Contact shading under loose items (item_cards.gd contact, item_contact.gdshader): a kind of a node with
## contact on (items on belts, on the ground) draws one more surface, a box round its look's footprint
## from under its base to just over it, faces outward (Godot's front faces are clockwise), with the node's
## contact material, while the look's own surfaces keep the look's material and the look's mesh, shared,
## is untouched; a node without it (inserters' hands) and --belt-item-contact=off draw the look alone, as
## before. The setting and the debug menu's sliders reach the material.
##   godot --headless --audio-driver Dummy --path client -s res://tests/item_contact_test.gd

const ItemCards := preload("res://scripts/world/item_cards.gd")
const ContactShade := preload("res://scripts/world/contact_shade.gd")
const TestEnv := preload("res://tests/test_env.gd")

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _init() -> void:
	TestEnv.isolate("item-contact-test")
	# The shader parses (Godot's own front end, headless), with what item_cards.gd and the debug menu set.
	var names := ItemCards.ContactShader.get_shader_uniform_list().map(func(u: Dictionary) -> String: return str(u["name"]))
	for n in ["on", "rim_dark", "rim_falloff", "reach", "gap_gone", "fade_from", "fade_to", "belt_paths"]:
		check(names.has(n), "item_contact.gdshader parses, with %s" % n)

	# An item without a look known (no protos): its block, on a node with contact on.
	var cards := ItemCards.new()
	cards.contact = true
	root.add_child(cards)
	var mmi := cards._kind(7)
	var mesh := mmi.multimesh.mesh
	check(mesh is ArrayMesh and mesh.get_surface_count() == 2, "contact on: the look and its box (%d surfaces)" % mesh.get_surface_count())
	check(mmi.material_override == null, "no override (it would cover the box too)")
	var look := mesh.surface_get_material(0)
	check(look != null and not (look is ShaderMaterial and (look as ShaderMaterial).shader == ItemCards.ContactShader),
		"the look's surface keeps the look's material")
	var box_mat := mesh.surface_get_material(1) as ShaderMaterial
	check(box_mat != null and box_mat.shader == ItemCards.ContactShader, "the box has the contact material")
	check(ItemCards._block().get_surface_count() == 1, "the shared block mesh untouched")
	if mesh.get_surface_count() == 2:
		_check_box(mesh, Vector2(ItemCards.BLOCK_SIZE.x, ItemCards.BLOCK_SIZE.z) * 0.5, -ItemCards.BLOCK_SIZE.y * 0.5, "block")
	cards.set_paths(ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBAF)))
	check(box_mat != null and box_mat.get_shader_parameter("belt_paths") != null, "the box gets the belts' paths")

	# A modeller's look of two surfaces with materials of their own: kept, the box added after them.
	var own := ArrayMesh.new()
	for i in 2:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-0.1, 0, -0.05), Vector3(0.1, 0, -0.05), Vector3(0.1, 0.1 * (i + 1), 0.15)])
		own.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		own.surface_set_material(i, StandardMaterial3D.new())
	var with := cards._with_contact(own, null, 1.0)
	check(with != null and with.get_surface_count() == 3, "an own look: its two surfaces and the box")
	if with != null and with.get_surface_count() == 3:
		check(with.surface_get_material(0) == own.surface_get_material(0) and with.surface_get_material(1) == own.surface_get_material(1),
			"an own look keeps its surfaces' materials")
		_check_box(with, Vector2(0.1, 0.1), 0.0, "own look", Vector2(0.0, 0.05))
	check(own.get_surface_count() == 2, "the look's own mesh untouched")
	var card := cards._with_contact(ItemCards._card(), null, ItemCards.CONTACT_CARD)
	if card != null:
		_check_box(card, Vector2.ONE * ItemCards.CARD_SIZE * 0.5 * ItemCards.CONTACT_CARD, 0.0, "icon card")

	# Inserters' hands (contact off) and --belt-item-contact=off: the look alone, the override as before.
	var hands := ItemCards.new()
	root.add_child(hands)
	var h := hands._kind(7)
	check(h.multimesh.mesh.get_surface_count() == 1 and h.material_override != null, "contact off: the look alone, overridden")
	ItemCards.contact_allowed = false
	var off := ItemCards.new()
	off.contact = true
	root.add_child(off)
	var o := off._kind(7)
	check(o.multimesh.mesh.get_surface_count() == 1 and o.material_override != null, "--belt-item-contact=off: the look alone")
	ItemCards.contact_allowed = true

	# Settings > Graphics > Contact shading, and the debug menu's sliders.
	ContactShade.enabled = false
	cards._process(0.0)
	check(box_mat != null and box_mat.get_shader_parameter("on") == false, "Contact shading off hides the items' rims")
	check(not ItemCards.contact_drawn(), "the bench says they're off")
	ContactShade.enabled = true
	cards._process(0.0)
	check(box_mat != null and box_mat.get_shader_parameter("on") == true, "and on shows them")
	ItemCards.contact_param("rim_dark", 0.3)
	check(box_mat != null and is_equal_approx(float(box_mat.get_shader_parameter("rim_dark")), 0.3), "the strength slider reaches them")
	var later := ItemCards.new()
	later.contact = true
	root.add_child(later)
	var lm := later._kind(7).multimesh.mesh.surface_get_material(1) as ShaderMaterial
	check(lm != null and is_equal_approx(float(lm.get_shader_parameter("rim_dark")), 0.3), "a node made later gets the slider's value")
	ItemCards.contact_param("rim_dark", null)

	# Phase 2: tighter item contact fade thresholds, single belt_place() call per vertex, early fragment discard.
	check(box_mat != null and is_equal_approx(float(box_mat.get_shader_parameter("fade_from")), ItemCards.CONTACT_FADE_FROM)
		and is_equal_approx(float(box_mat.get_shader_parameter("fade_to")), ItemCards.CONTACT_FADE_TO)
		and ItemCards.CONTACT_FADE_TO <= 0.06,
		"item contact fade thresholds are tightened for small items (%.3f..%.3f)" % [ItemCards.CONTACT_FADE_FROM, ItemCards.CONTACT_FADE_TO])
	var shader_src := FileAccess.get_file_as_string("res://shaders/item_contact.gdshader")
	var belt_calls := 0
	for line in shader_src.split("\n"):
		var code := line.get_slice("//", 0)
		belt_calls += code.count("belt_place(")
	check(belt_calls == 1,
		"item_contact.gdshader calls belt_place() once per vertex (found %d)" % belt_calls)
	var disc_at := shader_src.find("if (gap < min_gap || gap >= gap_gone)")
	var exp_at := shader_src.find("exp(-dd / k)")
	check(disc_at > 0 and exp_at > disc_at,
		"item_contact.gdshader discards out-of-gap fragments before exp()/pow()")

	print("item_contact_test: %s" % ("PASS" if fails == 0 else "%d FAILED" % fails))
	TestEnv.clean()
	quit(1 if fails > 0 else 0)


## The last surface is the contact box: round `half` (+ CONTACT_REACH) about `centre`, from CONTACT_DROP
## under `base` to CONTACT_TOP over it, every face outward, its CUSTOM0 the footprint and UV.x the base.
func _check_box(mesh: Mesh, half: Vector2, base: float, what: String, centre := Vector2.ZERO) -> void:
	var a := mesh.surface_get_arrays(mesh.get_surface_count() - 1)
	var p: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
	var lo := Vector3.INF
	var hi := -Vector3.INF
	for v in p:
		lo = lo.min(v)
		hi = hi.max(v)
	var e := half + Vector2.ONE * ItemCards.CONTACT_REACH
	check(lo.distance_to(Vector3(centre.x - e.x, base - ItemCards.CONTACT_DROP, centre.y - e.y)) < 1e-4
		and hi.distance_to(Vector3(centre.x + e.x, base + ItemCards.CONTACT_TOP, centre.y + e.y)) < 1e-4,
		"%s: the box round its footprint (%s to %s)" % [what, lo, hi])
	var mid := (lo + hi) * 0.5
	var outward := 0
	for t in range(0, idx.size(), 3):
		var v0 := p[idx[t]]
		var v1 := p[idx[t + 1]]
		var v2 := p[idx[t + 2]]
		# Clockwise seen from outside: (v2 - v0) x (v1 - v0) points out.
		if (v2 - v0).cross(v1 - v0).dot((v0 + v1 + v2) / 3.0 - mid) > 0.0:
			outward += 1
	check(idx.size() == 30 and outward == 10, "%s: the top and four sides, all facing out (%d of %d)" % [what, outward, idx.size() / 3])
	var custom: PackedFloat32Array = a[Mesh.ARRAY_CUSTOM0]
	var uv: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
	check(custom.size() == p.size() * 4 and Vector4(custom[0], custom[1], custom[2], custom[3]).is_equal_approx(Vector4(centre.x, centre.y, half.x, half.y)),
		"%s: CUSTOM0 the footprint" % what)
	check(uv.size() == p.size() and is_equal_approx(uv[0].x, base), "%s: UV.x the base" % what)
