extends Node3D
## One 32x32-tile chunk: a terrain mesh plus its static entities, drawn with one MultiMesh per
## model (or per placeholder shape). Rebuilt whenever its contents change. A model's moving
## parts get a MultiMesh each, which the model shader (or anim.gd) moves between rebuilds (anim_groups).

const ProtoDB := preload("res://scripts/world/protos.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const Probing := preload("res://scripts/debug/probing.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const Anim := preload("res://scripts/world/anim.gd")
const TerrainMesher := preload("res://scripts/world/terrain_mesher.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const FarChunks := preload("res://scripts/world/far_chunks.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const BeltLods := preload("res://scripts/world/belt_lods.gd")
const SpriteStandins := preload("res://scripts/world/sprite_standins.gd")
const ContactShade := preload("res://scripts/world/contact_shade.gd")

const SIZE := 32
## Entity types whose models get a per-entity random turn and size (see _model_transform).
const VARIED_TYPES := {"tree": true, "simple-entity": true, "resource": true}
## How far up its model a train stop's paint starts: Factorio paints only the top (its mask over the
## girder above the rails), which on FUE5's model starts at 3 of its 4.76 tiles.
const PAINT_FROM := 0.63

var coord := Vector2i.ZERO
var tile_ids := PackedInt32Array()
## False until the chunk's snapshot has arrived (or the chunk doesn't exist on the server).
var loaded := false
var created_msec := Time.get_ticks_msec()
## When the chunk's tiles first arrived and its ground was first drawn (0: not yet).
var tiles_msec := 0
var drawn_msec := 0

var entities := {}  # key -> WorldMirror.Rec
## Raised whenever its tiles or entities change (decoratives.gd builds its mask of ground no
## decorative may cover again only when this moved).
var content_rev := 0
var alt := {}  # key -> WorldMirror.Rec: those with an Alt-mode icon (extra.ai, issue #9)
## world.gd pick()'s index of `entities` by PICK_CELL square: built when first needed, emptied
## whenever an entity comes or goes. [protos count it was built with, {cell: [[rec, rect, area]]}];
## while being built a slice a frame, [protos count, grid so far, the records, the next one].
var pick_grid: Array = []
## The snapshot being received: how many `ents` parts its header announced (-1 before any
## header), and which have arrived.
var parts_expected := -1
var parts_got := {}

## Anim.Group per moving part and per glowing model, for anim.gd.
var anim_groups: Array = []
## Keys of entities drawn as placeholders, whose colour shows the working state (a state
## change needs a rebuild; models show it through anim_groups instead).
var placeholder_keys := {}
## True when something here wasn't drawn because its model is still being made on a worker thread
## (ModelLibrary.ready): world.gd draws the chunk again once models become ready. Ghosts, wires and
## the like set it too, as they are drawn again with the chunk (entities_changed).
var waiting_models := false
## Far from the camera, the buildings are one merged mesh (far_chunks.gd).
var far := FarChunks.State.new()
## Belts drawn small on screen are drawn with their stand-ins (belt_lods.gd, which sets belt_flat).
## belt_bounds: round this chunk's belts; belt_waiting: a belt was drawn whole as its stand-in was
## still being made (belt_lods.gd builds the chunk again once it is).
var belt_flat := false
var belt_bounds := AABB()
var belt_waiting := false
## Belt models drawn here -> how many moving parts each has (hidden with the model when flat), and
## per model [[the model's and its parts' MultiMeshes], its stand-in's MultiMesh or null].
var _belt_models := {}
var _belt_pairs: Array = []
var _flat_mmis := {}
## Belts and loaders a network can switch off (a wire, or off now), so drawn with custom data:
## unit -> [[MultiMesh, instance, stopped], ...] (the model, its stand-in, a line's end pieces), for set_belt_off.
var _switches := {}

var _terrain: MeshInstance3D
## The rings of contact shading round the buildings' feet (contact_shade.gd), or null.
var contact_node: MultiMeshInstance3D
## How this chunk's things cast shadows (world.gd _update_shadow_casters): through the models'
## stand-ins (model_lods.gd), which simplify only below a pixel of error near the character
## (SHADOWS_NEAR) and sooner further out (SHADOWS_FAR), or not at all beyond where their shadows
## could fall on ground the sun's shadow map covers (SHADOWS_NONE). The shadow pass draws every
## caster in the light's long box, so far chunks cost as much there as near ones.
enum { SHADOWS_NONE, SHADOWS_FAR, SHADOWS_NEAR }
## The shadow stand-ins' GeometryInstance3D.lod_bias in SHADOWS_NEAR chunks (_apply_shadows).
const NEAR_SHADOW_LOD_BIAS := 4.0
var shadow_tier := SHADOWS_NEAR
## [model's MultiMeshInstance3D, its shadow stand-in's (shown while it is ready), the proxy]
var _shadow_pairs: Array = []
var _proxy_generation := -1
var _lod_bias := -1.0
## Models drawn here with levels of detail (model_lods.gd): their MultiMeshInstance3D -> LodState.
## Each chunk picks its models' levels itself (update_lods), by the size of a screen pixel at its
## nearest point, rather than by Godot's mesh LODs: those switched at one distance either way and
## without a fade, so a chunk's chests and inserters popped as the camera moved.
var _lods := {}
## The tiles of error allowed at the chunk's nearest point when its levels were last looked at
## (looked at again once that changes by LOD_LOOK_AGAIN), and ModelLods.level_generation then.
var _lod_allowed := -1.0
var _lod_generation := -1
var _lod_fading := 0
const LOD_LOOK_AGAIN := 0.03
## How high a chunk's buildings reach, for its nearest point to the camera (tiles).
const LOD_HEIGHT := 12.0


class LodState:
	var model: Mesh
	var level := 0  # 0: the model itself; k: ModelLods.levels(model)[k - 1]
	## While a switch cross-fades: the level before, drawn by a copy of the MultiMesh, and the
	## seconds left.
	var fade: MultiMeshInstance3D
	var fade_left := 0.0
## Each tile's texture slot (x + 64 * y), kept between rebuilds: it depends only on this chunk's
## tiles and their pictures, and neighbours arriving rebuild the terrain several times. Empty:
## work them out again (terrain_mesher.gd).
var slots := PackedInt32Array()
var _instances: Array[MultiMeshInstance3D] = []
## The MultiMeshes drawn now by what they draw (Want.key), and the models' shadow stand-ins by
## model: kept from one build to the next and filled again.
var _nodes := {}
var _shadows := {}
## What the last build still has to add (Want), taken in world.gd's order of chunks.
var pending: Array = []
## Shadow stand-ins not made yet: only chunks with some redo their shadows when more are ready.
var _unready := 0
## What chunks did this frame, for --stutter-probe (which empties it; kept only while it runs):
## {name: count}.
static var counters := {}
## Under an orthographic camera (Factorio's view, the map's remote view) the shadow stand-ins cast
## nothing in Godot 4.7 (checked against the mock: no building shadows; the models' own do), so
## the models cast their own there (world.gd sets it from the camera).
static var no_stand_ins := false
var _no_stand_ins := false


static func count(key: String, n := 1) -> void:
	if Probing.on:
		counters[key] = int(counters.get(key, 0)) + n


func set_tiles_rle(rle: Array) -> void:
	tile_ids.resize(SIZE * SIZE)
	var i := 0
	var n := 0
	while i + 1 < rle.size() and n < SIZE * SIZE:
		var id := int(rle[i])
		var count := int(rle[i + 1])
		for _k in count:
			if n >= SIZE * SIZE:
				break
			tile_ids[n] = id
			n += 1
		i += 2
	loaded = true
	slots = PackedInt32Array()
	content_rev += 1


func set_tile(local: Vector2i, id: int) -> void:
	if tile_ids.size() == SIZE * SIZE:
		tile_ids[local.y * SIZE + local.x] = id
		slots = PackedInt32Array()
		content_rev += 1


func mark_missing() -> void:
	tile_ids = PackedInt32Array()
	loaded = true
	content_rev += 1


func clear_entities() -> void:
	entities.clear()
	alt.clear()
	pick_grid = []
	content_rev += 1


func start_snapshot(parts: int) -> void:
	parts_expected = parts
	parts_got.clear()


func got_part(part: int) -> void:
	# A part we already have means a new snapshot started and its header was lost.
	if parts_got.has(part):
		parts_expected = -1
		parts_got.clear()
	parts_got[part] = true


## Some of the snapshot is known to be missing: a part, or the header in front of parts that came.
func is_incomplete() -> bool:
	if parts_expected < 0:
		return not parts_got.is_empty()
	return parts_got.size() < parts_expected


## Whether the ground drawn is the simpler one of far chunks (TerrainMesher.coarse, world.gd COARSE_FROM).
var ground_coarse := false


## Shows the terrain a TerrainMesher job built for this chunk (on a worker thread, see world.gd).
func apply_terrain(job: TerrainMesher) -> void:
	slots = job.slots if job.missing.is_empty() else PackedInt32Array()
	ground_coarse = job.coarse
	var mesh := ArrayMesh.new()
	if job.land.has_faces():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, job.land.arrays(), [], {}, TerrainMesher.TerrainSurface.FORMAT)
		mesh.surface_set_material(mesh.get_surface_count() - 1, Visuals.terrain_material())
	if job.water.has_faces():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, job.water.arrays(), [], {}, TerrainMesher.TerrainSurface.FORMAT)
		mesh.surface_set_material(mesh.get_surface_count() - 1, Visuals.water_material())
	if _terrain == null:
		_terrain = MeshInstance3D.new()
		# Flat ground shades nothing worth a shadow pass (0.14-0.5 ms of GPU on the owner's save).
		_terrain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_terrain)
	_terrain.mesh = mesh
	GroundHeight.hold_mesh(_terrain)  # on hills, room for their lift
	if drawn_msec == 0:
		drawn_msec = Time.get_ticks_msec()


## A terrain mesh kept from an earlier build of the same ground (world.gd's terrain cache): shared,
## not copied; nothing changes a mesh once it is drawn.
func apply_kept_terrain(mesh: ArrayMesh, kept_slots: PackedInt32Array, coarse := false) -> void:
	slots = kept_slots
	ground_coarse = coarse
	if _terrain == null:
		_terrain = MeshInstance3D.new()
		_terrain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_terrain)
	_terrain.mesh = mesh
	GroundHeight.hold_mesh(_terrain)  # on hills, room for their lift
	if drawn_msec == 0:
		drawn_msec = Time.get_ticks_msec()


func terrain_mesh() -> ArrayMesh:
	return _terrain.mesh as ArrayMesh if _terrain != null else null


func clear_terrain() -> void:
	if _terrain != null:
		_terrain.queue_free()
		_terrain = null


func set_shadow_tier(tier: int) -> void:
	if tier == shadow_tier and _lod_bias == ModelLods.lod_bias and _no_stand_ins == no_stand_ins:
		if _proxy_generation == ModelLods.generation:
			return
		# More stand-ins are ready somewhere: only a chunk waiting for one has anything to change.
		_proxy_generation = ModelLods.generation
		if _unready == 0:
			return
	shadow_tier = tier
	_apply_shadows()


## Sets each MultiMesh's shadow casting for the tier and the stand-ins ready now. Only what changes
## is set: Godot passes every such setting on to the renderer, which then works the instance out
## again, and setting them all on every chunk whenever another stand-in was ready made 40-55 ms
## frames on a big base.
func _apply_shadows() -> void:
	if retired:
		return
	_apply_belt_flat()
	_proxy_generation = ModelLods.generation
	_lod_bias = ModelLods.lod_bias
	_no_stand_ins = no_stand_ins
	var cast := _cast(shadow_tier != SHADOWS_NONE)
	FarChunks.set_cast(self, cast)
	# Godot picks a stand-in's LOD in the shadow pass as in the view: by the main camera's distance,
	# in screen pixels of error (Viewport.mesh_lod_threshold / lod_bias). So a fixed bias keeps the
	# shadows' error a fixed size on screen at every zoom, and far things simplify by themselves.
	# Round the character the stand-ins are finer still (NEAR_SHADOW_LOD_BIAS, or the Level of detail
	# setting's own when that is finer).
	var bias := maxf(NEAR_SHADOW_LOD_BIAS, ModelLods.lod_bias) if shadow_tier == SHADOWS_NEAR else ModelLods.lod_bias
	var stood_in := {}
	_unready = 0
	for pair in _shadow_pairs:
		var ready := ModelLods.is_ready(pair[2])
		if not ready:
			_unready += 1
		var stand_in := shadow_tier != SHADOWS_NONE and ready and not no_stand_ins and not FarChunks.hides(self, pair[0]) and (pair[0] as MultiMeshInstance3D).visible
		var proxy_mmi: MultiMeshInstance3D = pair[1]
		if proxy_mmi.visible != stand_in:
			proxy_mmi.visible = stand_in
		if proxy_mmi.lod_bias != bias:
			proxy_mmi.lod_bias = bias
		if stand_in:
			stood_in[pair[0]] = true
	for mmi in _instances:
		_set_cast(mmi, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if stood_in.has(mmi) else cast)


## belt_lods.gd: draws this chunk's belts with their stand-ins (flat) or whole.
func set_belt_flat(flat: bool) -> void:
	if flat == belt_flat or retired:
		return
	belt_flat = flat
	_apply_shadows()


## Shows either each belt model (and its moving parts) or its stand-in, by belt_flat. A pair the
## merged far mesh hides now (far_chunks.gd) is left as it is: that shows its hidden ones again
## and then calls _apply_shadows.
func _apply_belt_flat() -> void:
	for pair in _belt_pairs:
		var fulls: Array = pair[0]
		# Untyped until checked: a typed variable can't even take a freed node (retire() clears the
		# pairs first, so this is the second line of defence).
		var flat_node = pair[1]
		if typeof(flat_node) == TYPE_OBJECT and not is_instance_valid(flat_node):
			continue  # (a freed node compares equal to null, so the type says a node was there)
		if not fulls.all(func(m) -> bool: return is_instance_valid(m)):
			continue
		var flat_mmi: MultiMeshInstance3D = flat_node
		if flat_mmi != null and FarChunks.hides(self, flat_mmi):
			continue
		if fulls.any(func(m: MultiMeshInstance3D) -> bool: return FarChunks.hides(self, m)):
			continue
		var show_flat := belt_flat and flat_mmi != null
		for m: MultiMeshInstance3D in fulls:
			if m.visible == show_flat:
				m.visible = not show_flat
		if flat_mmi != null and flat_mmi.visible != show_flat:
			flat_mmi.visible = show_flat


func _exit_tree() -> void:
	BeltLods.untrack(self)


## True once world.gd has let this chunk go (unloaded, or every chunk on a surface change). It is
## then freed over the next frames a child at a time (world.gd _free_unloaded).
var retired := false


## world.gd lets this chunk go: nothing may reach its MultiMeshes any more, since they are freed one
## by one before the chunk itself. Belt levels of detail went on setting a retired chunk's belts flat
## or full and met freed ones ("previously freed instance" in _apply_belt_flat, changing surface).
func retire() -> void:
	retired = true
	BeltLods.untrack(self)
	_belt_pairs.clear()
	_flat_mmis.clear()
	_shadow_pairs.clear()
	_instances.clear()


static func _set_cast(node: GeometryInstance3D, setting: GeometryInstance3D.ShadowCastingSetting) -> void:
	if node.cast_shadow != setting:
		node.cast_shadow = setting


static func _cast(on: bool) -> GeometryInstance3D.ShadowCastingSetting:
	return GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF



## Whether there's ground to see, or the chunk has none (not generated on the server).
func has_ground() -> bool:
	return _terrain != null or (loaded and tile_ids.is_empty())


## How many new MultiMeshes the chunks built in one frame may still add, counted in their meshes'
## surfaces (world.gd refills one each frame and hands it to each chunk it builds). Godot takes on a
## MultiMesh that starts being drawn at about 0.1 ms of the renderer's time, outside any script,
## and a busy chunk has 60-150 of them: several chunks arriving in one frame made 40-90 ms frames
## while walking on a big base. What doesn't fit waits in `pending` for the next frames.
class Budget:
	var left := 0

	func _init(n: int) -> void:
		left = n


## One MultiMesh a build wants: its key in _nodes and what it draws.
class Want:
	var key  # the model's Mesh, [model, part index] for a moving part, "box" or "cone" for placeholders
	var mesh: Mesh
	var xforms: Array
	var colors: Array = []
	var material: Material
	var custom := false
	var switches: Array = []  # [instance, unit] of those a network can switch off (_switches)
	var recs: Array = []  # [rec, proto type] per instance, for its anim group
	var part: ModelLibrary.AnimPart
	var group := false  # handed to anim.gd (glowing models and moving parts)
	var paint := Color.WHITE  # a train stop's colour (_painted_wants)
	var paint_from := -1000.0


## Rebuilds the entity MultiMeshes. `working` maps unit numbers to machine working state;
## `anim` (anim.gd) gives moving parts their current angle and glows their current activity.
## A MultiMesh drawn before is filled again in place (nothing new for the renderer to take on);
## new ones are added within `budget` (none: all at once), the rest by add_pending().
## With `until_usec` (a Time.get_ticks_usec() deadline) a build that runs past it stops part-way
## (`building`) and carries on where it was when world.gd calls resume_build(): a busy chunk's records
## took up to 10-24 ms in one frame while walking (docs/PERFORMANCE-AUDIT.md 4.7). The MultiMeshes
## drawn before stay until it is done.
func build_entities(protos: ProtoDB, working: Dictionary, anim: Anim = null, budget: Budget = null, until_usec := 0) -> void:
	_until = until_usec
	anim_groups.clear()
	placeholder_keys.clear()
	waiting_models = false
	pending.clear()

	var by_model := {}  # Mesh -> Array of Transform3D
	var recs_by_model := {}  # Mesh -> Array of [rec, proto type]
	var parts_by_model := {}  # Mesh -> Array of ModelLibrary.AnimPart
	var boxes: Array[Transform3D] = []
	var box_colors: Array[Color] = []
	var cones: Array[Transform3D] = []
	var cone_colors: Array[Color] = []
	var painted := {}  # [Mesh, Color] -> [Array of Transform3D, Array of [rec, proto type], parts]
	var cap_parts := {}  # belt end pieces' moving parts: [Mesh, index] -> [Array of Transform3D, Array of [rec, proto type], part]
	var cards := {}  # sprite stand-in Mesh -> Array of Transform3D
	var card_colors := {}  # sprite stand-in Mesh -> Array of Color (running, phase)
	var merged := FarChunks.skips(self)
	_belt_models.clear()
	_switches.clear()
	var switchable := {}  # keys of belts and loaders a network can switch off
	belt_waiting = false
	var belt_kinds := {}  # belt Mesh -> its stand-in's kind (belt_lods.gd)
	var belt_lo := Vector2.INF
	var belt_hi := -Vector2.INF
	var rings: Array = []  # contact_shade.gd collect()

	var done := 0
	var t_recs := Time.get_ticks_usec()  # (--stutter-probe: the records' pass and the MultiMeshes' as c_us_*)
	for rec in entities.values():
		done += 1
		if _until > 0 and (done & 15) == 0 and Time.get_ticks_usec() > _until:
			count("us_build_recs", Time.get_ticks_usec() - t_recs)
			await _wait_for_more()
			t_recs = Time.get_ticks_usec()
		var proto: ProtoDB.EntityProto = protos.entity(rec.proto_id)
		if proto == null or rec.extra.has("gh") or rec.extra.has("tg") or ModelLibrary.hidden(proto.name):
			continue  # ghosts (and tile ghosts) are drawn by ghosts.gd
		if ModelLibrary.REMNANT_TYPES.has(proto.type):
			var remnant := _remnant(protos, proto, rec)
			if remnant.is_empty():
				waiting_models = true
				continue
			var rmesh: Mesh = remnant[0]
			if merged and FarChunks.merges(proto.type, rmesh):
				continue
			if not by_model.has(rmesh):
				by_model[rmesh] = []
				recs_by_model[rmesh] = []
				parts_by_model[rmesh] = []
			by_model[rmesh].append(remnant[1])
			recs_by_model[rmesh].append([rec, proto.type])
			continue
		if not ModelLibrary.entity_ready(proto.name, proto.type, rec.extra, rec.dir):
			waiting_models = true  # nothing drawn until its model is made (no placeholder popping up)
			continue
		var mesh := ModelLibrary.mesh_for_entity(proto.name, proto.type, rec.extra, rec.dir)
		if merged and FarChunks.merges(proto.type, mesh):
			continue
		if mesh != null and proto.type == "train-stop" and rec.extra.get("col") is Array and rec.extra["col"].size() >= 3:
			var col: Array = rec.extra["col"]
			var paint_key := [mesh, Color8(int(col[0]), int(col[1]), int(col[2]))]
			if not painted.has(paint_key):
				painted[paint_key] = [[], [], ModelLibrary.parts_for_entity(proto.name, proto.type, rec.extra, rec.dir)]
			painted[paint_key][0].append(_model_transform(proto, rec))
			painted[paint_key][1].append([rec, proto.type])
			continue
		if mesh != null:
			if not by_model.has(mesh):
				by_model[mesh] = []
				recs_by_model[mesh] = []
				parts_by_model[mesh] = ModelLibrary.parts_for_entity(proto.name, proto.type, rec.extra, rec.dir)
			by_model[mesh].append(_model_transform(proto, rec))
			recs_by_model[mesh].append([rec, proto.type])
			ContactShade.collect(rings, proto.name, proto.type, mesh, by_model[mesh][-1], proto.box_min, proto.box_max)
			if Anim.SWITCHABLE_TYPES.has(proto.type) and (rec.extra.has("r") or rec.extra.has("g") or int(working.get(rec.unit, 0)) == Anim.SWITCHED_OFF):
				switchable[rec.key] = true
			if BeltLods.TYPES.has(proto.type):
				belt_kinds[mesh] = BeltLods.kind_of(proto.type, rec.extra)
				belt_lo = belt_lo.min(rec.pos)
				belt_hi = belt_hi.max(rec.pos)
			if rec.extra.has("cb"):
				if _add_cargo_pieces(rec, by_model[mesh][-1], by_model, recs_by_model, parts_by_model):
					waiting_models = true
			if rec.belt_ends != 0:
				if _add_belt_ends(rec, proto, by_model[mesh][-1], by_model, recs_by_model, parts_by_model, cap_parts):
					waiting_models = true
			continue
		# No model: the entity's own picture from the bridge's list (a mod's building), else a box.
		var card := SpriteStandins.card(proto.name, rec.dir, proto.size(), proto.type) if proto.type != "resource" else null
		if card == null and SpriteStandins.coming(proto.name, rec.dir):
			waiting_models = true  # drawn once its picture is composed, not as a box first
			continue
		if card == null and proto.type != "resource" and SpriteStandins.in_use():
			continue  # with a graphics list, no boxes or cones: only pictures (owner's choice)
		placeholder_keys[rec.key] = true
		var height := Visuals.height_for(proto)
		if proto.type == "resource":
			height = Visuals.resource_height(int(rec.extra.get("a", 1000)))
		if card != null:
			if not cards.has(card):
				cards[card] = []
				card_colors[card] = []
			cards[card].append(SpriteStandins.transform(rec.pos))
			# Animated while the machine works (or always, for what isn't a machine); trees stay still.
			var running: bool = not VARIED_TYPES.has(proto.type) and (int(working.get(rec.unit, 0)) == 1 or not SpriteStandins.WORKING_TYPES.has(proto.type))
			card_colors[card].append(SpriteStandins.instance_color(running, rec.pos))
			continue  # the picture alone: it casts its own shadow (a box under it read as a slab)
		var color := ModelLibrary.NEUTRAL_COLOR if ModelLibrary.NEUTRAL_PROTOS.has(proto.name) else proto.color
		if working.get(rec.unit, 0) == 1:
			color = color.lightened(0.35)
		var xform := Visuals.placeholder_transform(proto, rec.pos, rec.dir, height)
		if Visuals.is_cone(proto):
			cones.append(xform)
			cone_colors.append(color)
		else:
			boxes.append(xform)
			box_colors.append(color)

	count("us_build_recs", Time.get_ticks_usec() - t_recs)
	if _until > 0 and done > 16 and Time.get_ticks_usec() > _until:
		await _wait_for_more()  # the records are read: the MultiMeshes next time
	var t_wants := Time.get_ticks_usec()
	var wants: Array[Want] = []
	for model in by_model:
		var glows := ModelLibrary.glows(model)
		var switches := _switches_in(recs_by_model[model], switchable)
		var whole := _want(model, model, by_model[model], [], null, glows or not switches.is_empty(), recs_by_model[model], null, glows)
		whole.switches = switches
		wants.append(whole)
		var parts: Array = parts_by_model[model]
		for i in parts.size():
			var part: ModelLibrary.AnimPart = parts[i]
			wants.append(_want([model, i], part.mesh, by_model[model], [], null, true, recs_by_model[model], part, true))
		if belt_kinds.has(model):
			_belt_models[model] = parts.size()
			var flat := BeltLods.stand_in(model, belt_kinds[model])
			if flat != null:
				var flat_want := _want([model, BeltLods.FLAT], flat, by_model[model], [], null, not switches.is_empty(), [], null, false)
				flat_want.switches = switches
				wants.append(flat_want)
			elif BeltLods.coming(model):
				belt_waiting = true
	for paint_key: Array in painted:
		wants.append_array(_painted_wants(paint_key, painted[paint_key]))
	for key: Array in cap_parts:
		var entry: Array = cap_parts[key]
		var cap_part: ModelLibrary.AnimPart = entry[2]
		wants.append(_want(key, cap_part.mesh, entry[0], [], null, true, entry[1], cap_part, true))
	if _belt_models.is_empty() or retired:
		BeltLods.untrack(self)
	else:
		belt_bounds = AABB(Vector3(belt_lo.x - 1.0, 0.0, belt_lo.y - 1.0), Vector3(belt_hi.x - belt_lo.x + 2.0, 1.0, belt_hi.y - belt_lo.y + 2.0))
		BeltLods.track(self)
	for card in cards:
		wants.append(_want(["card", card], card, cards[card], card_colors[card], null, false, [], null, false))
	if not boxes.is_empty():
		wants.append(_want("box", Visuals.box_mesh(), boxes, box_colors, Visuals.instance_material(), false, [], null, false))
	if not cones.is_empty():
		wants.append(_want("cone", Visuals.cone_mesh(), cones, cone_colors, Visuals.instance_material(), false, [], null, false))
	var wanted := {}
	for w in wants:
		wanted[w.key] = true
	for key in _nodes.keys():
		if not wanted.has(key):
			_drop(key)
	count("us_build_wants", Time.get_ticks_usec() - t_wants)
	var t_apply := Time.get_ticks_usec()
	for w in wants:
		if budget == null or budget.left > 0 or _nodes.has(w.key):
			_apply(w, working, anim, budget)
		else:
			pending.append(w)
	count("us_build_apply", Time.get_ticks_usec() - t_apply)
	t_apply = Time.get_ticks_usec()
	_refresh_lists()
	_apply_shadows()
	contact_node = ContactShade.apply(self, contact_node, rings)
	FarChunks.built(self, merged)
	count("us_build_finish", Time.get_ticks_usec() - t_apply)


## A build part-way through (build_entities' until_usec) waits for this, with a new deadline.
signal _more_time
## True while a build waits part-way through for resume_build().
var building := false
var _until := 0


func _wait_for_more() -> void:
	building = true
	await _more_time
	building = false


## Lets a build part-way through carry on until `until_usec`.
func resume_build(until_usec: int) -> void:
	if building:
		_until = until_usec
		_more_time.emit()


## Adds MultiMeshes a build left for later, within `budget`. True once none are left.
func add_pending(working: Dictionary, anim: Anim, budget: Budget) -> bool:
	if pending.is_empty():
		return true
	while not pending.is_empty() and budget.left > 0:
		_apply(pending.pop_front(), working, anim, budget)
	_refresh_lists()
	_apply_shadows()
	FarChunks.built(self, null)
	return pending.is_empty()


## Train stops wearing the colour `key` (H21): a MultiMesh of their own per colour in the chunk, its
## colour an instance uniform. INSTANCE_CUSTOM has no room for it: a glowing model's instances fill
## all four channels with anim.gd's timing. A chunk rarely holds more than a stop or two.
func _painted_wants(key: Array, entry: Array) -> Array[Want]:
	var model: Mesh = key[0]
	var glows := ModelLibrary.glows(model)
	var out: Array[Want] = [_want(key, model, entry[0], [], null, glows, entry[1], null, glows)]
	var parts: Array = entry[2]
	for i in parts.size():
		var part: ModelLibrary.AnimPart = parts[i]
		out.append(_want([model, key[1], i], part.mesh, entry[0], [], null, true, entry[1], part, true))
	for w in out:
		w.paint = key[1]
		w.paint_from = model.get_aabb().end.y * PAINT_FROM
	return out


func _want(key, mesh: Mesh, xforms: Array, colors: Array, material: Material, custom: bool, recs: Array,
		part: ModelLibrary.AnimPart, group: bool) -> Want:
	var w := Want.new()
	w.key = key
	w.mesh = mesh
	w.xforms = xforms
	w.colors = colors
	w.material = material
	w.custom = custom
	w.recs = recs
	w.part = part
	w.group = group
	return w


## Draws a Want: into its MultiMesh from before, or a new one (taken from `budget`).
func _apply(w: Want, working: Dictionary, anim: Anim, budget: Budget) -> void:
	var mmi: MultiMeshInstance3D = _nodes.get(w.key)
	if mmi == null:
		mmi = _new_mmi(w.material)
		_nodes[w.key] = mmi
		if budget != null:
			budget.left -= maxi(w.mesh.get_surface_count(), 1)
		count("mmi")
		count("surfaces", w.mesh.get_surface_count())
	Anim.setup_part(w.part)  # its bounds over its whole motion, before the MultiMesh takes them
	_fill(mmi.multimesh, _lod_mesh(mmi, w), w.xforms, w.colors, w.custom)
	# On hills the bounds grow in height only by what they lift (ground_height.gd), not every way.
	# Parts anim.gd moves on the CPU (turret heads turning) keep the MultiMesh's own bounds, which
	# follow them, and the margin.
	if GroundHeight.holding() and not w.group:
		GroundHeight.cull_box(mmi, _bounds(_mesh_box(w.mesh), w.xforms))
	else:
		GroundHeight.cull_box(mmi, AABB())
	if w.paint != Color.WHITE:
		mmi.set_instance_shader_parameter("f3d_paint", w.paint)
		mmi.set_instance_shader_parameter("f3d_paint_from", w.paint_from)
	if not w.switches.is_empty() and not w.group:
		_draw_switches(w, mmi.multimesh, working)
	count("instances", w.xforms.size())
	if w.group:
		_add_group(mmi.multimesh, w.part, w.xforms, w.recs, working, anim)
	if w.part == null and w.key is Mesh:
		_shadow_proxy(w.key, w.xforms, budget)
	elif ModelLods.part_has_levels(w.part):
		# Its stand-in casts its shadow at rest, as a body's does (asking for it makes its levels too):
		# rollers turning in a belt's shadow can't be seen, and the part's own shadow at full detail was
		# most of the shadow pass's triangles on a base of a modeller's belts.
		_shadow_proxy(w.mesh, w.xforms, budget, w.key)


## [instance, unit] of the records in `recs` a network can switch off.
static func _switches_in(recs: Array, switchable: Dictionary) -> Array:
	var out: Array = []
	if not switchable.is_empty():
		for i in recs.size():
			if switchable.has(recs[i][0].key):
				out.append([i, recs[i][0].unit])
	return out


## A MultiMesh with switchable belts: each instance running or stood still as its belt is now. (A
## model that glows has its instances' data from anim.gd, which says so itself.)
func _draw_switches(w: Want, mm: MultiMesh, working: Dictionary) -> void:
	for i in w.xforms.size():
		mm.set_instance_custom_data(i, Color(0.0, 0.0, 0.0, 0.0))
	for s: Array in w.switches:
		if not _switches.has(s[1]):
			_switches[s[1]] = []
		var stopped := int(working.get(s[1], 0)) == Anim.SWITCHED_OFF
		_switches[s[1]].append([mm, s[0], stopped])
		if stopped:
			mm.set_instance_custom_data(s[0], Anim.BELT_STOPPED)


## A belt or loader stops or runs again, in place. False when it isn't drawn to do that.
func set_belt_off(unit: int, off: bool) -> bool:
	var at: Array = _switches.get(unit, [])
	for s: Array in at:
		(s[0] as MultiMesh).set_instance_custom_data(s[1], Anim.BELT_STOPPED if off else Color(0.0, 0.0, 0.0, 0.0))
		s[2] = off
	return not at.is_empty()


func _new_mmi(material: Material) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.cast_shadow = _cast(shadow_tier != SHADOWS_NONE)
	if material != null:
		mmi.material_override = material
	add_child(mmi)
	return mmi


## Fills a MultiMesh with these instances, keeping its buffer when the count stays the same.
static func _fill(mm: MultiMesh, mesh: Mesh, xforms: Array, colors: Array, custom: bool) -> void:
	var with_colors := not colors.is_empty()
	if mm.use_colors != with_colors or mm.use_custom_data != custom:
		mm.instance_count = 0  # the formats change only while it is empty
		mm.use_colors = with_colors
		mm.use_custom_data = custom
	if mm.mesh != mesh:
		mm.mesh = mesh
	if mm.instance_count != xforms.size():
		mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		if with_colors:
			mm.set_instance_color(i, colors[i])


func _drop(key) -> void:
	var mmi: Node = _nodes.get(key)
	if mmi != null:
		var st: LodState = _lods.get(mmi)
		if st != null:
			_end_fade(mmi as MultiMeshInstance3D, st)
			_lods.erase(mmi)
		mmi.free()
	_nodes.erase(key)
	var shadow: Node = _shadows.get(key)
	if shadow != null:
		shadow.free()
	_shadows.erase(key)


## The mesh a Want's MultiMesh draws: for a model with levels of detail, the level its chunk is at
## (a build keeps it, so filling the MultiMesh again doesn't pop it back to the whole model).
func _lod_mesh(mmi: MultiMeshInstance3D, w: Want) -> Mesh:
	if (w.part != null and not ModelLods.part_has_levels(w.part)) or not (w.mesh is ArrayMesh) or w.key is String:
		return w.mesh
	var st: LodState = _lods.get(mmi)
	if st == null or st.model != w.mesh:
		if st != null:
			_end_fade(mmi, st)
		st = LodState.new()
		st.model = w.mesh
		_lods[mmi] = st
		_lod_allowed = -1.0  # look at the levels again
	var levels := ModelLods.levels(st.model)
	if st.level > levels.size():
		st.level = 0
	return st.model if st.level == 0 else levels[st.level - 1][0]


## Picks each model's level of detail for the camera (world.gd, every frame): `allowed_per_tile`
## is the tiles of error the view allows per tile of distance from the camera (Level of detail's
## pixels times a pixel's size there), or `allowed_flat` the tiles allowed wherever (an
## orthographic view; < 0 in perspective). Measured to the chunk's nearest point, so no model in it
## is nearer than its level was made for. Also moves cross-fades on by `delta`.
func update_lods(camera: Vector3, allowed_per_tile: float, allowed_flat: float, delta: float) -> void:
	if _lods.is_empty():
		return
	if _lod_fading > 0:
		_advance_fades(delta)
	var allowed := allowed_flat
	if allowed < 0.0:
		var x0 := coord.x * SIZE
		var z0 := coord.y * SIZE
		var dx := maxf(maxf(x0 - camera.x, camera.x - (x0 + SIZE)), 0.0)
		var dz := maxf(maxf(z0 - camera.z, camera.z - (z0 + SIZE)), 0.0)
		var dy := maxf(camera.y - LOD_HEIGHT, 0.0) if camera.y > 0.0 else -camera.y
		allowed = sqrt(dx * dx + dy * dy + dz * dz) * allowed_per_tile
	if _lod_generation == ModelLods.level_generation and _lod_allowed > 0.0 \
			and absf(allowed - _lod_allowed) <= _lod_allowed * LOD_LOOK_AGAIN:
		return
	_lod_allowed = maxf(allowed, 1e-6)
	_lod_generation = ModelLods.level_generation
	for mmi: MultiMeshInstance3D in _lods:
		var st: LodState = _lods[mmi]
		var levels := ModelLods.levels(st.model)
		var level := ModelLods.level_for(levels, st.level, allowed)
		if level != st.level:
			_switch_level(mmi, st, level, levels)


## Draws the model at `level`, the level before fading out over ModelLods.FADE_SECONDS through a
## copy of the MultiMesh (the same instances, so the same states), the new one fading in.
func _switch_level(mmi: MultiMeshInstance3D, st: LodState, level: int, levels: Array) -> void:
	var mm := mmi.multimesh
	var before := mm.mesh
	_end_fade(mmi, st)
	st.level = level
	mm.mesh = st.model if level == 0 else levels[level - 1][0]
	if ModelLods.FADE_SECONDS <= 0.0 or ModelLods.full_detail or not mmi.visible or not mmi.is_inside_tree() or mm.instance_count == 0 or before == null:
		return
	var copy := MultiMesh.new()
	copy.transform_format = mm.transform_format
	copy.use_colors = mm.use_colors
	copy.use_custom_data = mm.use_custom_data
	copy.mesh = before
	copy.instance_count = mm.instance_count
	var data := mm.buffer
	if not data.is_empty():
		copy.buffer = data
	copy.visible_instance_count = mm.visible_instance_count
	var node := MultiMeshInstance3D.new()
	node.multimesh = copy
	node.material_override = mmi.material_override
	# The level fading in casts the shadow; two would darken it.
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.custom_aabb = mmi.custom_aabb
	node.extra_cull_margin = mmi.extra_cull_margin
	node.layers = mmi.layers
	for param in [&"f3d_paint", &"f3d_paint_from"]:
		var value: Variant = mmi.get_instance_shader_parameter(param)
		if value != null:
			node.set_instance_shader_parameter(param, value)
	node.set_instance_shader_parameter(&"f3d_lod_fade", 2.0)
	add_child(node)
	mmi.set_instance_shader_parameter(&"f3d_lod_fade", 0.0)
	st.fade = node
	st.fade_left = ModelLods.FADE_SECONDS
	_lod_fading += 1


## A level of detail is cross-fading here.
func lod_fading() -> bool:
	return _lod_fading > 0


func _advance_fades(delta: float) -> void:
	for mmi: MultiMeshInstance3D in _lods:
		var st: LodState = _lods[mmi]
		if st.fade == null:
			continue
		st.fade_left -= delta
		if st.fade_left <= 0.0 or not mmi.visible:
			_end_fade(mmi, st)
			continue
		var shown := 1.0 - st.fade_left / ModelLods.FADE_SECONDS
		mmi.set_instance_shader_parameter(&"f3d_lod_fade", shown)
		st.fade.set_instance_shader_parameter(&"f3d_lod_fade", 2.0 + shown)


func _end_fade(mmi: MultiMeshInstance3D, st: LodState) -> void:
	if st.fade == null:
		return
	st.fade.free()
	st.fade = null
	_lod_fading -= 1
	if is_instance_valid(mmi):
		mmi.set_instance_shader_parameter(&"f3d_lod_fade", 1.0)


## The level each model here is drawn at (for tests): Mesh -> level.
func lod_levels() -> Dictionary:
	var out := {}
	for mmi in _lods:
		out[(_lods[mmi] as LodState).model] = (_lods[mmi] as LodState).level
	return out


## _instances and _shadow_pairs from the MultiMeshes drawn now.
func _refresh_lists() -> void:
	_instances.clear()
	if retired:
		_belt_pairs.clear()
		_flat_mmis.clear()
		_shadow_pairs.clear()
		return
	for key in _nodes:
		_instances.append(_nodes[key])
	_belt_pairs.clear()
	_flat_mmis.clear()
	for model in _belt_models:
		var fulls: Array = []
		if _nodes.has(model):
			fulls.append(_nodes[model])
		for i in int(_belt_models[model]):
			if _nodes.has([model, i]):
				fulls.append(_nodes[[model, i]])
		var flat_mmi: MultiMeshInstance3D = _nodes.get([model, BeltLods.FLAT])
		if flat_mmi != null:
			_flat_mmis[flat_mmi] = true
			# A flat belt casts its own shadow (its bed and rails are the belt's height): the full
			# model and its stand-in are hidden while it shows, and belts went shadowless once the view
			# was pulled back a little past the default zoom (BeltLods.FLAT_BELOW).
			flat_mmi.cast_shadow = _cast(shadow_tier != SHADOWS_NONE)
		_belt_pairs.append([fulls, flat_mmi])
	_shadow_pairs.clear()
	for key in _shadows:
		var proxy_mmi: MultiMeshInstance3D = _shadows[key]
		_shadow_pairs.append([_nodes[key], proxy_mmi, proxy_mmi.multimesh.mesh])


## A cargo bay's edge pieces on its 2x2 cells (ModelLibrary.cargo_pieces, extra.cb from world.gd),
## drawn unturned like Factorio's connection tileset. True while some piece's model is being made.
func _add_cargo_pieces(rec, base: Transform3D, by_model: Dictionary, recs_by_model: Dictionary, parts_by_model: Dictionary) -> bool:
	var waiting := false
	for place in ModelLibrary.cargo_places(int(rec.extra["cb"]), base.origin):
		if not ModelLibrary.ready(place[0]):
			waiting = true
			continue
		var mesh := ModelLibrary.mesh_for(place[0])
		if mesh == null:
			continue
		if not by_model.has(mesh):
			by_model[mesh] = []
			recs_by_model[mesh] = []
			parts_by_model[mesh] = []
		by_model[mesh].append(Transform3D(Basis(), place[1]))
		recs_by_model[mesh].append([rec, "cargo-bay"])
	return waiting


## A modeller's pieces where a line of belts begins or ends (belt_ends on its record, from world.gd), on a
## belt, each half of a splitter and an underground's open end. True while some piece's model is being made.
## A piece's moving parts go in `cap_parts` ([piece mesh, part index] -> [transforms, records]) rather than
## with its mesh, so a part the entity's own model already has there (a splitter's rollers) is left out on
## that entity alone.
func _add_belt_ends(rec, proto: ProtoDB.EntityProto, base: Transform3D, by_model: Dictionary, recs_by_model: Dictionary, parts_by_model: Dictionary, cap_parts: Dictionary) -> bool:
	var waiting := false
	var host_parts := ModelLibrary.parts_for_entity(proto.name, proto.type, rec.extra, rec.dir)
	var inverse := base.affine_inverse()
	for place: Array in ModelLibrary.belt_end_places(proto.name, proto.type, rec.dir, rec.pos, rec.belt_ends, base.origin.y):
		var piece: String = place[0]
		if not ModelLibrary.ready(piece):
			waiting = true
			continue
		var mesh := ModelLibrary.mesh_for(piece)
		if mesh == null:
			continue
		var at: Transform3D = place[1]
		if not by_model.has(mesh):
			by_model[mesh] = []
			recs_by_model[mesh] = []
			parts_by_model[mesh] = []
		by_model[mesh].append(at)
		recs_by_model[mesh].append([rec, proto.type])
		var parts := ModelLibrary.parts_for(piece)
		for i in parts.size():
			if ModelLibrary.part_doubled(parts[i], inverse * at, host_parts):
				continue
			var key := [mesh, i]
			if not cap_parts.has(key):
				cap_parts[key] = [[], [], parts[i]]
			cap_parts[key][0].append(at)
			cap_parts[key][1].append([rec, proto.type])
	return waiting


## The model's shadow stand-in at the same places, cast in place of the model's own shadow once ready
## (or a modeller's baked moving part's, kept under its `key`).
func _shadow_proxy(model: Mesh, xforms: Array, budget: Budget, key: Variant = null) -> void:
	var proxy := ModelLods.proxy_for(model)
	if proxy == null:
		return
	if key == null:
		key = model  # a body's MultiMesh is keyed by its model; a moving part's by [model, part]
	var mmi: MultiMeshInstance3D = _shadows.get(key)
	if mmi == null:
		count("shadow_mmi")
		mmi = _new_mmi(ModelLods.material())
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		mmi.visible = false
		_shadows[key] = mmi
		if budget != null:
			budget.left -= 1
	_fill(mmi.multimesh, proxy, xforms, [], false)
	# The proxy may still be empty: give it the model's bounds so it isn't culled once filled (and
	# room for the hills' lift, ground_height.gd).
	GroundHeight.cull_box(mmi, _bounds(model.get_aabb(), xforms))


## A mesh's bounds with what its moving parts reach (anim.gd gives a part's mesh bounds over its
## whole motion as its custom AABB, which get_aabb() leaves out).
static func _mesh_box(mesh: Mesh) -> AABB:
	var box := mesh.get_aabb()
	var am := mesh as ArrayMesh
	if am != null and am.custom_aabb.size != Vector3.ZERO:
		box = box.merge(am.custom_aabb)
	return box


## The box round every instance of a mesh with bounds `box`: worked out here rather than asked of
## the MultiMesh, which waits for the render thread when that runs on its own.
static func _bounds(box: AABB, xforms: Array) -> AABB:
	var out := AABB()
	for i in xforms.size():
		var b: AABB = (xforms[i] as Transform3D) * box
		out = b if i == 0 else out.merge(b)
	return out


## A remnant's [mesh, transform]: the model of what died (extra.rm), broken, turned the way it
## faced; else rubble the size of it, turned at random. [] while the model is still being made.
func _remnant(protos: ProtoDB, proto: ProtoDB.EntityProto, rec) -> Array:
	var src: ProtoDB.EntityProto = protos.entity(int(rec.extra.get("rm", 0)))
	var at := Vector3(rec.pos.x, 0.0, rec.pos.y)
	if src != null:
		var variant := ModelLibrary.model_name(src.name, src.type, {}, rec.dir)
		if not ModelLibrary.remnant_ready(variant):
			return []
		var mesh := ModelLibrary.remnant_mesh(variant)
		if mesh == null:
			if not ModelLibrary.remnant_ready(src.name):
				return []
			mesh = ModelLibrary.remnant_mesh(src.name)
		if mesh != null:
			var yaw := Visuals.direction_yaw(ModelLibrary.turn_dir(src.type, rec.dir, {}, src.name))
			return [mesh, Transform3D(Basis(Vector3.UP, yaw), at)]
	var size := (src if src != null else proto).size().clamp(Vector2(0.6, 0.6), Vector2(8.0, 8.0))
	var turn := float(hash(rec.fixed) & 0xffff) / 65536.0 * TAU
	return [ModelLibrary.rubble_mesh(), Transform3D(Basis(Vector3.UP, turn) * Basis.from_scale(Vector3(size.x, 1.0, size.y)), at)]


## Where a model instance goes. Trees, rocks and ore tiles have no meaningful direction, so
## each gets its own turn and size from a hash of its position (stable across rebuilds and
## sessions); otherwise a forest looks stamped from one mould. Richer ore tiles stand taller.
func _model_transform(proto: ProtoDB.EntityProto, rec) -> Transform3D:
	var at := Vector3(rec.pos.x, 0.0, rec.pos.y)
	if not VARIED_TYPES.has(proto.type):
		return ModelLibrary.placed(proto.name, proto.type, rec.dir, rec.extra, at)
	var h := hash(rec.fixed)
	var yaw := float(h & 0xffff) / 65536.0 * TAU
	var size := 0.9 + 0.2 * float((h >> 16) & 0xff) / 255.0
	var height := size
	if proto.type == "resource":
		var amount := maxf(float(rec.extra.get("a", 1000)), 1.0)
		height *= 0.6 + 0.6 * clampf(log(amount) / log(10000.0), 0.0, 1.0)
	return Transform3D(Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3(size, height, size)), at)


## A moving part's or glowing model's instances, handed to anim.gd, which sets them to where their
## entities' states have them now (most move in the shader from there).
func _add_group(mm: MultiMesh, part: ModelLibrary.AnimPart, xforms: Array, recs: Array, working: Dictionary, anim: Anim) -> void:
	var group := Anim.Group.new()
	group.mm = mm
	group.part = part
	for i in xforms.size():
		var rec = recs[i][0]
		var base: Transform3D = xforms[i]
		if part != null and part.upright:
			base = Transform3D(Basis.IDENTITY, base.origin)
		group.keys.append(rec.key)
		group.units.append(rec.unit)
		group.bases.append(base)
		group.stateful.append(1 if Anim.has_state(str(recs[i][1])) else 0)
		var custom := Anim.custom_for(rec, 1.0)
		if part != null and part.upright:
			custom.b = 0.0  # its sprite is drawn facing north
		group.customs.append(custom)
	Anim.place(group, anim, working)
	anim_groups.append(group)
