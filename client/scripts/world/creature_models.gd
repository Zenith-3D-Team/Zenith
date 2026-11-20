extends RefCounted
## Nauvis's creatures as models: which model each prototype uses, at what size and colour, and
## the limb data the material animates them with.
##
## Factorio draws small, medium, big and behemoth biters (spitters, worms) from one sprite sheet,
## scaled and tinted. So does this: each family has one model, built at the big tier's size from
## Wube's printable model (tools/models/wube_recipes.py), and the other tiers are that model
## scaled (its geometry, so the sprite projection and the limbs scale with it) with the tier's
## colour on its carapace (Factorio's mask tint). Pose variants follow the same names:
## `<tier>-biter-attack`, `<tier>-biter-corpse`.
##
## Limbs move in the vertex shader (factorio_material.gdshaderinc, rig_*): every vertex carries
## its limb and how much it follows it (UV), and res://data/creature_rigs.json (written by
## tools/models/wube_rig.py) has each limb's joint, axes and gait, and its knee and the walk's bend
## (tools/models/creature_gait.py, fitted to Factorio's run sheets). Walking creatures get their
## gait phase from creatures.gd through INSTANCE_CUSTOM; worms and spawners run on their own. A
## walking model also carries the legs of its attack and corpse poses (res://data/creature_poses.json,
## tools/models/creature_pose.py), so a biter rears into its bite and a dying one's legs fold into its
## corpse's in the shader, on the walking model (POSE_SLOTS).
##
## Skins (res://data/creature_skins.json, tools/models/creature_skin.py): the part colours of a
## creature are sampled per vertex from its sprites, and on its tinted material they are Factorio's
## mask layers, which each tier's own tints colour as Factorio draws them (`masks`: two masks and
## two tints, biters and spitters; `mask`: one mask over the part colours, worms, spawners and Gleba's
## wriggler, tools/models/space_skin.py). Space Age's others (`colour`) carry it all in their part
## colours (pentapods and shells are a model per tier, their tier's tints blended in). A family
## without a skin keeps one colour per tier on its carapace (ALIASES).

const ModelLods := preload("res://scripts/world/model_lods.gd")
const MaterialRows := preload("res://scripts/world/material_rows.gd")
const RIGS_PATH := "res://data/creature_rigs.json"
const POSES_PATH := "res://data/creature_poses.json"
const SKINS_PATH := "res://data/creature_skins.json"
## The poses a walking model blends into, in the shader's slot order (rig_pose, RIG_POSES).
const POSE_SLOTS := ["-attack", "-corpse", "-corpse-1", "-corpse-2", "-corpse-3"]
## INSTANCE_CUSTOM.a for a pose: 2 + slot + amount * this (factorio_material.gdshaderinc RIG_POSE_SCALE).
const POSE_SCALE := 0.999
## Material name fragments that take the tier's colour.
const TINTED := ["chitin", "flesh_worm", "flesh_spawner_dome"]
## Demolishers' lava (tools/models/vulcanus.py): its .glb glows 2.5 times a bright red (the crust 0.6
## times a dark one), over part colours that already are the sprite's lava (space_skin.py): 4 to 7
## times the sprite's brightness, a red glare. Factorio paints its lava in (the demolisher has no glow
## layer), so here it shines by its own paint, this share of it: about the sprite's brightness in
## daylight, still lava on its shaded side. The crust doesn't glow (the sprite's is dark).
const PAINT_GLOW := {"lava_demolisher": 0.4, "lava_demolisher_dim": 0.0}

## The creatures' look before their glow was taken off (--creature-glow=old): worms' and spawners'
## unmasked parts in the tier's colour four times over (skin_mode 3), demolishers' lava at its .glb's
## emission.
static var old_glow := false
static var _args_read := false

## Prototype name -> [model it is drawn with, scale, carapace colour or null].
## Scales from Factorio's enemy-constants.lua. Biters' and spitters' colours were sampled from
## each tier's run sprite with both mask layers tinted as Factorio draws them (the lit 30 % of
## the carapace, tools/models/creature_score.py's sheets); the big tiers take theirs too, as
## their models' own carapace came out too purple. Worms' were sampled the same way from the
## prepared sprite's plates (the mask layer tinted as Factorio draws it); spawners' are their mask
## tint as it shows on the sprite.
const ALIASES := {
	"small-biter": ["big-biter", 0.5, Color(0.435, 0.347, 0.201)],
	"medium-biter": ["big-biter", 0.7, Color(0.399, 0.251, 0.261)],
	"big-biter": ["big-biter", 1.0, Color(0.175, 0.311, 0.368)],
	"behemoth-biter": ["big-biter", 1.2, Color(0.264, 0.389, 0.081)],
	"small-spitter": ["big-spitter", 0.5, Color(0.442, 0.347, 0.158)],
	"medium-spitter": ["big-spitter", 0.7, Color(0.436, 0.253, 0.271)],
	"big-spitter": ["big-spitter", 1.0, Color(0.227, 0.279, 0.319)],
	"behemoth-spitter": ["big-spitter", 1.2, Color(0.28, 0.347, 0.066)],
	"small-worm-turret": ["big-worm-turret", 0.65, Color(0.303, 0.213, 0.147)],
	"medium-worm-turret": ["big-worm-turret", 0.83, Color(0.316, 0.169, 0.144)],
	"big-worm-turret": ["big-worm-turret", 1.0, Color(0.275, 0.195, 0.175)],
	"behemoth-worm-turret": ["big-worm-turret", 1.2, Color(0.272, 0.212, 0.132)],
	"spitter-spawner": ["biter-spawner", 1.0, Color(0.8, 0.45, 0.45)],
	# Gleba's wrigglers (tools/models/gleba.py): the run sprite at 0.36 / 0.48 / 0.6. Their skin
	# (tools/models/space_skin.py) lays each tier's tint over the mask as Factorio does; these
	# colours are only for a model without it: the legs in the tier's tint, lit.
	"small-wriggler-pentapod": ["big-wriggler-pentapod", 0.6, Color(0.258, 0.247, 0.064)],
	"medium-wriggler-pentapod": ["big-wriggler-pentapod", 0.8, Color(0.374, 0.219, 0.071)],
	"big-wriggler-pentapod": ["big-wriggler-pentapod", 1.0, Color(0.315, 0.143, 0.097)],
	# The premature ones a dying stomper or strafer lets out: the same pictures, scale and tints in
	# Factorio (make_wriggler), only losing health over time. Without these they were orange boxes.
	"small-wriggler-pentapod-premature": ["big-wriggler-pentapod", 0.6, Color(0.258, 0.247, 0.064)],
	"medium-wriggler-pentapod-premature": ["big-wriggler-pentapod", 0.8, Color(0.374, 0.219, 0.071)],
	"big-wriggler-pentapod-premature": ["big-wriggler-pentapod", 1.0, Color(0.315, 0.143, 0.097)],
	# Factorio draws the small Gleba spawner's corpse with the big one's picture at a third of
	# its scale (0.3 against 0.9).
	"gleba-spawner-small-corpse": ["gleba-spawner-corpse", 1.0 / 3.0, null],
}
## Pose variants of a family share its tiers: "small-biter-attack" is "big-biter-attack" at 0.5.
const POSES := ["-attack", "-corpse", "-corpse-1", "-corpse-2", "-corpse-3"]

static var _rigs := {}
static var _loaded := false
static var _poses := {}
static var _poses_loaded := false
static var _skins := {}
static var _skins_loaded := false
static var _slots := {}  # pose model -> pose_slot()


## The model file a prototype (or pose variant) is drawn with, or "" when it is its own.
static func base_model(name: String) -> String:
	var alias = _alias(name)
	if alias is Array:
		return str(alias[0])
	return ""


## [model, scale, tint] for an aliased name (a tier, or a tier's pose variant), or null.
static func _alias(name: String):
	if ALIASES.has(name):
		return ALIASES[name]
	for pose in POSES:
		if name.ends_with(pose):
			var tier := name.trim_suffix(pose)
			if ALIASES.has(tier):
				var a: Array = ALIASES[tier]
				return [str(a[0]) + pose, a[1], a[2]]
	return null


## True for prototypes creatures.gd draws (walking ones: biters, spitters, characters).
static func walks(name: String) -> bool:
	var model := base_model(name)
	if model == "":
		model = name
	return rig(model).get("mode", "") in ["walk", "pose"]


## The limb table of a model (creature_rigs.json), or {}.
static func rig(model: String) -> Dictionary:
	if not _loaded:
		_loaded = true
		var text := FileAccess.get_file_as_string(RIGS_PATH)
		var parsed = JSON.parse_string(text) if text != "" else null
		if parsed is Dictionary:
			_rigs = parsed
	var entry = _rigs.get(model)
	return entry if entry is Dictionary else {}


## Called by model_library.gd on a freshly flattened model: scales a tier's copy, tints its
## carapace, and gives its materials the limb data. Returns the mesh to use.
static func prepare(mesh: ArrayMesh, name: String) -> ArrayMesh:
	if mesh == null:
		return mesh
	var found = _alias(name)
	var alias: Array = found if found is Array else []
	var model := name if alias.is_empty() else str(alias[0])
	var limbs := rig(model)
	var scale := 1.0 if alias.is_empty() else float(alias[1])
	_read_args()
	if not old_glow:
		_paint_glow(mesh)
	# A skin without tiers (Space Age's pentapods, shells, spawners, demolishers: `colour`) is all in
	# the model's own part colours: nothing to do here.
	if alias.is_empty() and limbs.is_empty() and (skin_of(_unposed(model)).get("tiers", {}) as Dictionary).is_empty():
		return mesh
	var tint = null if alias.is_empty() else alias[2]
	var out := _scaled(mesh, scale) if scale != 1.0 else mesh
	# The skin of the family (its tier's tints), else one colour on the carapace.
	var skin := skin_of(_unposed(model))
	var tints: Variant = (skin.get("tiers", {}) as Dictionary).get(_unposed(name))
	var masks := str(skin.get("mode", "")) == "masks"
	var skinned: Array = skin.get("materials", []) if tints is Array else []
	# The carapace's rows of a merged material (material_rows.gd), or a surface's own material.
	var carapace := func(m: ShaderMaterial) -> bool:
		if not skinned.is_empty():
			return skinned.any(func(n: String) -> bool: return m.resource_name.contains(n))
		return tint != null and _tinted(m.resource_name)
	var recolour := func(m: ShaderMaterial) -> void:
		var albedo: Color = m.get_shader_parameter("albedo")
		if skinned.is_empty():
			m.set_shader_parameter("albedo", Color(tint, albedo.a))
			m.set_shader_parameter("part_colors", false)  # sampled from the big tier's sprite
			return
		# The skin's colours are linear; the material's albedo and second tint are sRGB colours.
		var t: Array = tints
		m.set_shader_parameter("albedo", Color(_linear_colour(t[0]).linear_to_srgb(), albedo.a))
		var second := _linear_colour(t[1])
		m.set_shader_parameter("skin_tint2", Color(second.linear_to_srgb(), float((t[1] as Array)[3])))
		m.set_shader_parameter("skin_mode", 1 if masks else (3 if old_glow else 2))
		m.set_shader_parameter("part_colors", true)
	var glowing := func(m: ShaderMaterial) -> void: m.set_shader_parameter("activity_glow", true)
	for i in out.get_surface_count():
		var material := out.surface_get_material(i) as ShaderMaterial
		if material == null:
			continue
		var copy := ModelLods.copy_material(MaterialRows.edit(material, carapace, recolour) as ShaderMaterial)
		if not limbs.is_empty():
			if str(limbs.get("mode", "")) == "worm":
				# Bent and raised in the shader from the instance's state (anim.gd sets it,
				# through the same custom data a machine's glow uses).
				copy = MaterialRows.edit_all(copy, glowing) as ShaderMaterial
			_set_rig(copy, limbs, scale, model)
			if str(limbs.get("mode", "")) == "worm":
				copy.set_shader_parameter("rig_mode", 4)
				copy.set_shader_parameter("worm_height", out.get_aabb().end.y)
		out.surface_set_material(i, copy)
	return out


static func _read_args() -> void:
	if _args_read:
		return
	_args_read = true
	for a in OS.get_cmdline_user_args():
		if a == "--creature-glow=old":
			old_glow = true


## The lava's materials (PAINT_GLOW) shine by their own paint instead of their .glb's emission.
static func _paint_glow(mesh: ArrayMesh) -> void:
	var lava := func(m: ShaderMaterial) -> bool: return PAINT_GLOW.has(m.resource_name)
	var by_paint := func(m: ShaderMaterial) -> void:
		m.set_shader_parameter("emission", Color.WHITE)
		m.set_shader_parameter("emission_energy", float(PAINT_GLOW[m.resource_name]))
		m.set_shader_parameter("emission_from_paint", true)
	for i in mesh.get_surface_count():
		var material := mesh.surface_get_material(i)
		var changed := MaterialRows.edit(material, lava, by_paint)
		if changed != material:
			mesh.surface_set_material(i, changed)


## A family's skin (creature_skins.json): {mode, materials, tiers: {tier: tints}}, or {}.
static func skin_of(model: String) -> Dictionary:
	if not _skins_loaded:
		_skins_loaded = true
		var text := FileAccess.get_file_as_string(SKINS_PATH) if FileAccess.file_exists(SKINS_PATH) else ""
		var parsed = JSON.parse_string(text) if text != "" else null
		if parsed is Dictionary:
			_skins = parsed
	var entry = _skins.get(model)
	return entry if entry is Dictionary else {}


## A name without its pose suffix ("small-biter-corpse-2" -> "small-biter").
static func _unposed(name: String) -> String:
	for i in range(POSES.size() - 1, -1, -1):
		if name.ends_with(POSES[i]):
			return name.trim_suffix(POSES[i])
	return name


static func _linear_colour(values: Variant) -> Color:
	var a: Array = values
	return Color(float(a[0]), float(a[1]), float(a[2]))


## The legs of a walking model's poses (creature_poses.json), in POSE_SLOTS order: [[swing, lift,
## knee] per limb] or [] where the family has no such pose.
static func poses_of(model: String) -> Array:
	if not _poses_loaded:
		_poses_loaded = true
		var text := FileAccess.get_file_as_string(POSES_PATH)
		var parsed = JSON.parse_string(text) if text != "" else null
		if parsed is Dictionary:
			_poses = parsed
	var out := []
	for suffix in POSE_SLOTS:
		var entry = _poses.get(model + suffix)
		out.append(entry.get("legs", []) if entry is Dictionary else [])
	return out


## The shader's pose slot of a pose model ("small-biter-corpse-2" -> 3), or -1 when its family's
## walking model has no legs for it (then the pose model is drawn instead). Asked every frame for
## every attacking creature: worked out once per name.
static func pose_slot(pose_model: String) -> int:
	var known: Variant = _slots.get(pose_model)
	if known != null:
		return int(known)
	var slot := -1
	for k in range(POSE_SLOTS.size() - 1, -1, -1):
		var suffix: String = POSE_SLOTS[k]
		if pose_model.ends_with(suffix):
			var walker := pose_model.trim_suffix(suffix)
			var family := base_model(walker)
			var legs: Array = poses_of(family if family != "" else walker)[k]
			slot = k if not legs.is_empty() else -1
			break
	_slots[pose_model] = slot
	return slot


static func _tinted(material_name: String) -> bool:
	for fragment in TINTED:
		if material_name.contains(fragment):
			return true
	return false


static func _set_rig(material: ShaderMaterial, limbs: Dictionary, scale: float, model: String) -> void:
	if str(limbs.get("mode", "")) == "pose":
		# A skeleton (the character): every bone at rest until someone poses it
		# (character_pose.gd, on its own copy of the materials).
		var rows: Array[Vector4] = []
		for i in 16:
			rows.append_array([Vector4(1, 0, 0, 0), Vector4(0, 1, 0, 0), Vector4(0, 0, 1, 0)])
		material.set_shader_parameter("rig_mode", 3)
		material.set_shader_parameter("rig_bone", rows)
		return
	var joints := PackedVector3Array()
	var swings := PackedVector3Array()
	var lifts := PackedVector3Array()
	var gaits: Array[Vector4] = []
	for limb in limbs.get("limbs", []):
		var j: Array = limb["joint"]
		var s: Array = limb["swing"]
		var l: Array = limb["lift"]
		var g: Array = limb["gait"]
		# glTF -> Godot keeps the axes (both y up, -z north).
		joints.append(Vector3(float(j[0]), float(j[1]), float(j[2])) * scale)
		swings.append(Vector3(float(s[0]), float(s[1]), float(s[2])))
		lifts.append(Vector3(float(l[0]), float(l[1]), float(l[2])))
		gaits.append(Vector4(float(g[0]), float(g[1]), float(g[2]), float(g[3])))
	while joints.size() < 12:
		joints.append(Vector3.ZERO)
		swings.append(Vector3.UP)
		lifts.append(Vector3.RIGHT)
		gaits.append(Vector4.ZERO)
	material.set_shader_parameter("rig_mode", 2 if str(limbs.get("mode", "walk")) == "idle" else 1)
	material.set_shader_parameter("rig_rate", float(limbs.get("rate", 1.0)))
	material.set_shader_parameter("rig_joint", joints)
	material.set_shader_parameter("rig_swing", swings)
	material.set_shader_parameter("rig_lift", lifts)
	material.set_shader_parameter("rig_gait", gaits)
	if str(limbs.get("mode", "walk")) != "walk":
		return
	# Knees and the walk's bend (creature_gait.py), the body standing on them, and the poses the legs
	# blend into (creature_pose.py), in the order of the limbs above.
	var knees: Array[Vector4] = []
	var bends: Array[Vector4] = []
	for limb in limbs.get("limbs", []):
		var k: Array = limb.get("knee", [0, 0, 0])
		var b: Array = limb.get("bend", [0, 0, 0])
		knees.append(Vector4(float(k[0]) * scale, float(k[1]) * scale, float(k[2]) * scale, float(limb.get("reach", 0.0)) * scale))
		bends.append(Vector4(float(b[0]), float(b[1]), float(b[2]), 0.0))
	while knees.size() < 12:
		knees.append(Vector4.ZERO)
		bends.append(Vector4.ZERO)
	material.set_shader_parameter("rig_knee", knees)
	material.set_shader_parameter("rig_bend", bends)
	var body: Array = limbs.get("body", [0, 0, 0])
	material.set_shader_parameter("rig_body", Vector3(float(body[0]) * scale, float(body[1]), float(body[2]) * scale))
	var poses: Array[Vector4] = []
	for legs: Array in poses_of(model):
		for i in 12:
			var l: Array = legs[i] if i < legs.size() else [0, 0, 0]
			poses.append(Vector4(float(l[0]), float(l[1]), float(l[2]), 0.0))
	material.set_shader_parameter("rig_pose", poses)


## A copy of the mesh with every vertex scaled about the origin (normals unchanged).
static func _scaled(mesh: ArrayMesh, scale: float) -> ArrayMesh:
	var out := ArrayMesh.new()
	var kept: Array = []
	for i in mesh.get_surface_count():
		var arrays := ModelLods.arrays_of(mesh, i)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for k in verts.size():
			verts[k] *= scale
		arrays[Mesh.ARRAY_VERTEX] = verts
		# Keep the custom channels' formats (the baked views in CUSTOM0); the copy is uncompressed.
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, mesh.surface_get_format(i) & ~Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES)
		out.surface_set_material(i, mesh.surface_get_material(i))
		out.surface_set_name(i, mesh.surface_get_name(i))
		kept.append(arrays)
	out.set_meta(ModelLods.ARRAYS_META, kept)
	return out
