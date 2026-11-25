extends Node3D
## One 32x32-tile chunk: a terrain mesh plus its static entities, drawn with one MultiMesh per
## model (or per placeholder shape). Rebuilt whenever its contents change. A model's moving
## parts get a MultiMesh each, which the model shader (or anim.gd) moves between rebuilds (anim_groups).

const FreeLater := preload("res://scripts/world/free_later.gd")
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
const PipelineWarm := preload("res://scripts/world/pipeline_warm.gd")
const NatureLooks := preload("res://scripts/world/nature_looks.gd")
const PipeCovers := preload("res://scripts/world/pipe_covers.gd")
const ViewPriority := preload("res://scripts/world/view_priority.gd")
const CliffWall := preload("res://scripts/world/cliff_wall.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")
const Switches := preload("res://scripts/switches.gd")

const SIZE := 32
## Entity types whose models get a per-entity random turn and size (see _model_transform).
const VARIED_TYPES := {"tree": true, "simple-entity": true, "resource": true}
## How far up its model a train stop's paint starts: Factorio paints only the top (its mask over the
## girder above the rails), which on FUE5's model starts at 3 of its 4.76 tiles.
const PAINT_FROM := 0.63
## --build-rec-cache=off: resolve every entity's model, transform, and moving parts fresh on every
## rebuild instead of reusing the static lookup cached on Rec.
static var build_rec_cache := Switches.on("--build-rec-cache")
## --chunk-mm-worker=off: pack MultiMesh buffers, instance bounds, and contact-shade rings on the main
## thread as before rather than in a WorkerThreadPool task when total instances >= WORKER_MIN_INSTANCES.
static var chunk_mm_worker := Switches.on("--chunk-mm-worker")
const WORKER_MIN_INSTANCES := 48
const CHUNK_PREP_JOBS := 4


static func prep_job_limit() -> int:
	return clampi(OS.get_processor_count() - 2, CHUNK_PREP_JOBS, 8)

var coord := Vector2i.ZERO
var tile_ids := PackedInt32Array()
## False until the chunk's snapshot has arrived (or the chunk doesn't exist on the server).
var loaded := false
## True once both ground and initial entity visuals (or fallback timeout) are ready to reveal cleanly.
var revealed := false
var _terrain_held := false
## True while this chunk displays optimistic cached data ahead of server confirmation.
var optimistic := false
var created_msec := Time.get_ticks_msec()
## When the chunk's tiles first arrived and its ground was first drawn (0: not yet).
var tiles_msec := 0
var drawn_msec := 0

var entities := {}  # key -> WorldMirror.Rec
## Raised whenever its tiles or entities change (decoratives.gd builds its mask of ground no
## decorative may cover again only when this moved).
var content_rev := 0
var build_serial := 0
var _prep_pending: ChunkPrepJob
var alt := {}  # key -> WorldMirror.Rec: those with an Alt-mode icon (extra.ai, issue #9)
## world.gd pick()'s index of `entities` by PICK_CELL square: built when first needed, emptied
## whenever an entity comes or goes. [protos count it was built with, {cell: [[rec, rect, area]]}];
## while being built a slice a frame, [protos count, grid so far, the records, the next one].
var pick_grid: Array = []
## world.gd rail_height()'s index of the chunk's rails and ramps: [content_rev, frame built, {cell: entries}].
var rail_grid: Array = []
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
## Its cliffs as one generated wall (cliff_wall.gd, --cliff-wall=on), and how many cliffs its last build read.
var wall := CliffWall.State.new()
var cliff_count := 0
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
## Scattered ore's rock models drawn here (ModelLibrary.ore_rocks) -> how many of their instances are
## every tile's first rock (they come first: rank by rank), what a far chunk shows (thin_ore).
var _ore_near := {}

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
## --shadow-small=old: every model casts at every tier, as before. On (default): models under
## FLAT_TOP tiles high cast nothing, and under FAR_SMALL_TOP nothing in SHADOWS_FAR chunks
## (too_low_to_cast), fewer draw calls in the sun's shadow pass (the owner's 1,353).
static var shadow_small := not (Switches.has("--shadow-small=old"))
const FLAT_TOP := 0.08
const FAR_SMALL_TOP := 0.55
## Mesh's instance id -> the top of its box with its moving parts' reach (too_low_to_cast), kept for good: meshes
## are few and their boxes don't change.
static var _tops := {}
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
## Set by world.gd while it looks at a chunk just shown again (behind_cull.gd): a switch then needs
## no cross-fade, as nothing of the chunk was on screen to fade from.
var lod_snap := false
## Set when update_lods stopped early on its per-frame switch cap, so world.gd resumes this chunk
## next frame; lod_last_switches counts the level switches made in that call.
var lod_partial := false
var lod_last_switches := 0
const LOD_LOOK_AGAIN := 0.03
## How high a chunk's buildings reach, for its nearest point to the camera (tiles).
const LOD_HEIGHT := 12.0
## --lod-cpu-copy=off: read `mm.buffer` back from RenderingServer on LOD cross-fades as before.
static var lod_cpu_copy := Switches.on("--lod-cpu-copy")
## --render-reads=old: a LOD switch with no CPU copy of its instances reads them back from the RenderingServer
## (`mm.buffer`, `get_instance_transform`) as before; else it switches without the cross-fade (each read waits for
## the render thread when it runs on its own: frames of 15 -> 76 ms).
static var lod_no_readback := not Switches.has("--render-reads=old")
## --lod-mesh-touch=off: skip re-writing instance 0's transform after a LOD `MultiMesh.mesh` swap
## (Godot 4.7 Forward+ FSR2/TAA motion-vector workaround).
static var lod_mesh_touch := Switches.on("--lod-mesh-touch")
## --lod-fade-moving=off: keep cross-fading LOD transitions even while moving fast.
static var lod_fade_moving := Switches.on("--lod-fade-moving")
const LOD_SNAP_SPEED := 12.0


static func should_snap_for_speed(speed_tiles_per_sec: float) -> bool:
	return lod_fade_moving and speed_tiles_per_sec > LOD_SNAP_SPEED


class LodState:
	var model: Mesh
	var level := 0  # 0: the model itself; k: ModelLods.levels(model)[k - 1]
	## While a switch cross-fades: the level before, drawn by a copy of the MultiMesh, and the
	## seconds left.
	var fade: MultiMeshInstance3D
	var fade_left := 0.0
	var from_apply := false
	var xforms: Array = []
	var colors: Array = []
	var custom := false
	var group: Anim.Group
	var switches: Array = []
	var buffer := PackedFloat32Array()
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


## set_tiles_rle's result, decoded already (message_decode.gd, on the bridge's parsing thread).
func set_tiles(ids: PackedInt32Array) -> void:
	tile_ids = ids
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
	build_serial += 1
	_prep_pending = null


func start_snapshot(parts: int) -> void:
	parts_expected = parts
	parts_got.clear()
	snapshot_msec = Time.get_ticks_msec()


## When the snapshot being received started (world.gd builds the chunk once its last part is in).
var snapshot_msec := 0


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

## The chunk's baked flat decoratives drawn by the ground's own shader (decoratives.gd, terrain_common.gdshaderinc):
## the land and shore surfaces of the terrain mesh, and the chunk's own copies of their materials that
## carry the sheet. Set on the MeshInstance3D, never on the mesh: a kept mesh is shared with other builds.
var _land_surface_idx := -1
var _shore_surface_idx := -1
var _decor_sheet_tex: ImageTexture
var _decor_raised_shade := 0.0
var _decor_chunk_origin := Vector2.ZERO
var _decor_shown := true
var _decor_land_mat: ShaderMaterial
var _decor_shore_mat: ShaderMaterial


func set_terrain_held(held: bool) -> void:
	_terrain_held = held
	if _terrain != null:
		_terrain.visible = not held


## Shows the terrain a TerrainMesher job built for this chunk (on a worker thread, see world.gd).
func apply_terrain(job: TerrainMesher) -> void:
	slots = job.slots if job.missing.is_empty() else PackedInt32Array()
	ground_coarse = job.coarse
	var mesh := ArrayMesh.new()
	var t0 := Time.get_ticks_usec() if Probing.on else 0
	_land_surface_idx = -1
	_shore_surface_idx = -1
	if job.land.has_faces():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, job.land.arrays(), [], {}, TerrainMesher.TerrainSurface.FORMAT)
		mesh.surface_set_material(mesh.get_surface_count() - 1, Visuals.terrain_material())
		_land_surface_idx = mesh.get_surface_count() - 1
	if job.shore.has_faces():
		# The coast, with its own shader: it cuts the shore with `discard`, which the land's has none of.
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, job.shore.arrays(), [], {}, TerrainMesher.TerrainSurface.FORMAT)
		mesh.surface_set_material(mesh.get_surface_count() - 1, Visuals.terrain_shore_material())
		_shore_surface_idx = mesh.get_surface_count() - 1 if Visuals.terrain_shore_material() != Visuals.terrain_material() else -1
	if job.water.has_faces():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, job.water.arrays(), [], {}, TerrainMesher.TerrainSurface.FORMAT)
		mesh.surface_set_material(mesh.get_surface_count() - 1, Visuals.water_material())
	if Probing.on:
		Probing.add("ta_surfaces", t0)
		t0 = Time.get_ticks_usec()
	if _terrain == null:
		_terrain = MeshInstance3D.new()
		# Flat ground shades nothing worth a shadow pass (0.14-0.5 ms of GPU on the owner's save).
		_terrain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_terrain.layers = Visuals.GROUND_LAYER
		add_child(_terrain)
	_terrain.visible = not _terrain_held
	_terrain.mesh = mesh
	if Probing.on:
		Probing.add("ta_mesh_set", t0)
		t0 = Time.get_ticks_usec()
	GroundHeight.hold_mesh(_terrain)  # on hills, room for their lift
	_reapply_decor_sheet()
	if Probing.on:
		Probing.add("ta_hold", t0)
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
		_terrain.layers = Visuals.GROUND_LAYER
		add_child(_terrain)
	_terrain.visible = not _terrain_held
	_terrain.mesh = mesh
	_find_ground_surfaces(mesh)
	GroundHeight.hold_mesh(_terrain)  # on hills, room for their lift
	_reapply_decor_sheet()
	if drawn_msec == 0:
		drawn_msec = Time.get_ticks_msec()


## Which of a kept mesh's surfaces are the ground's land and shore (by material).
func _find_ground_surfaces(mesh: ArrayMesh) -> void:
	_land_surface_idx = -1
	_shore_surface_idx = -1
	var land_mat := Visuals.terrain_material()
	var shore_mat := Visuals.terrain_shore_material()
	for i in mesh.get_surface_count():
		var m := mesh.surface_get_material(i)
		if m == land_mat:
			_land_surface_idx = i
		elif m == shore_mat:
			_shore_surface_idx = i


## Whether the chunk's ground can draw its decorative sheet itself: its full (not far) terrain is drawn, with
## a land surface, and not --terrain-opt=old (whose one shader has no sheet).
func can_composite_decor() -> bool:
	return not Visuals.terrain_opt_old and _terrain != null and _terrain.mesh != null and not ground_coarse and _land_surface_idx >= 0


func has_decor_sheet() -> bool:
	return _decor_sheet_tex != null


## The ground draws `tex` (decoratives.gd's baked sheet for this chunk, `origin` its north-west corner in
## tiles) with `raised_shade` for the plants under their 3D copies. False (nothing set) when it can't now.
func set_decor_sheet(tex: ImageTexture, raised_shade: float, origin: Vector2) -> bool:
	if tex == null or not can_composite_decor():
		clear_decor_sheet()
		return false
	_decor_sheet_tex = tex
	_decor_raised_shade = raised_shade
	_decor_chunk_origin = origin
	_apply_decor_sheet()
	return true


## Hides the composited sheet while the chunk's decoratives are out of range or behind the camera (it follows
## decoratives.gd's chunk node), shows it again.
func set_decor_sheet_visible(shown: bool) -> void:
	if shown == _decor_shown:
		return
	_decor_shown = shown
	for m in [_decor_land_mat, _decor_shore_mat]:
		if m != null:
			(m as ShaderMaterial).set_shader_parameter(&"has_decor_sheet", shown)


func clear_decor_sheet() -> void:
	_decor_sheet_tex = null
	if _decor_land_mat == null and _decor_shore_mat == null:
		return
	_decor_land_mat = null
	_decor_shore_mat = null
	_clear_surface_overrides()


func _clear_surface_overrides() -> void:
	if _terrain != null and _terrain.mesh != null:
		for i in _terrain.mesh.get_surface_count():
			_terrain.set_surface_override_material(i, null)


## The terrain mesh was replaced: the sheet goes on its new surfaces, or off if it can't be drawn there.
func _reapply_decor_sheet() -> void:
	if _decor_land_mat != null or _decor_shore_mat != null:
		_clear_surface_overrides()  # a mesh swap keeps the old surfaces' overrides by index
	if _decor_sheet_tex == null:
		return
	if can_composite_decor():
		_apply_decor_sheet()
	else:
		clear_decor_sheet()


func _apply_decor_sheet() -> void:
	if _decor_land_mat == null:
		_decor_land_mat = Visuals.make_chunk_terrain_material(Visuals.terrain_material())
	_set_decor_params(_decor_land_mat)
	_terrain.set_surface_override_material(_land_surface_idx, _decor_land_mat)
	if _shore_surface_idx >= 0:
		if _decor_shore_mat == null:
			_decor_shore_mat = Visuals.make_chunk_terrain_material(Visuals.terrain_shore_material())
		_set_decor_params(_decor_shore_mat)
		_terrain.set_surface_override_material(_shore_surface_idx, _decor_shore_mat)
	else:
		_decor_shore_mat = null


func _set_decor_params(m: ShaderMaterial) -> void:
	m.set_shader_parameter(&"decor_sheet", _decor_sheet_tex)
	m.set_shader_parameter(&"decor_chunk_origin", _decor_chunk_origin)
	m.set_shader_parameter(&"decor_raised_shade", _decor_raised_shade)
	m.set_shader_parameter(&"has_decor_sheet", _decor_shown)


func terrain_mesh() -> ArrayMesh:
	return _terrain.mesh as ArrayMesh if _terrain != null else null


func clear_terrain() -> void:
	if _terrain != null:
		FreeLater.node(_terrain)  # hidden now, freed in a later frame's slice
		_terrain = null
	_land_surface_idx = -1
	_shore_surface_idx = -1
	_decor_sheet_tex = null
	_decor_land_mat = null
	_decor_shore_mat = null


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
	var quiet := {}  # (shadow_small) too low to cast at this tier: neither it nor its stand-in casts
	if shadow_small and shadow_tier != SHADOWS_NONE:
		var belts := {}
		for bp: Array in _belt_pairs:
			for m in bp[0]:
				belts[m] = true
			if bp[1] != null:
				belts[bp[1]] = true
		# Bodies only (keyed by their Mesh): a moving part's mesh can sit low in its own space and
		# be drawn high by its instances.
		for key in _nodes:
			if not (key is Mesh):
				continue
			var mmi: MultiMeshInstance3D = _nodes[key]
			if not belts.has(mmi) and too_low_to_cast(key, shadow_tier):
				quiet[mmi] = true
	_unready = 0
	for pair in _shadow_pairs:
		var ready := ModelLods.is_ready(pair[2])
		if not ready:
			_unready += 1
		var stand_in := shadow_tier != SHADOWS_NONE and ready and not no_stand_ins and not quiet.has(pair[0]) and not FarChunks.hides(self, pair[0]) and (pair[0] as MultiMeshInstance3D).visible
		var proxy_mmi: MultiMeshInstance3D = pair[1]
		if proxy_mmi.visible != stand_in:
			proxy_mmi.visible = stand_in
		if proxy_mmi.lod_bias != bias:
			proxy_mmi.lod_bias = bias
		if stand_in:
			stood_in[pair[0]] = true
	for mmi in _instances:
		_set_cast(mmi, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if stood_in.has(mmi) or quiet.has(mmi) else cast)


## Whether a model (a MultiMesh's body) reaches too little above the ground for its shadow to be worth a
## draw in the shadow pass at this tier (shadow_small): under FLAT_TOP everywhere (decals, plates,
## rails' ties: their shadow is under themselves), under FAR_SMALL_TOP in SHADOWS_FAR chunks (past
## the ring round the character a half-tile-high thing's shadow is a few pixels, but each kind of
## model costs a draw call in the shadow map all the same). Belts are left out by the caller (their
## shadows going was seen and reported). The top is the model's box with its moving parts' reach.
static func too_low_to_cast(mesh: Mesh, tier: int) -> bool:
	if mesh == null:
		return false
	var id := mesh.get_instance_id()
	var top: float = _tops.get(id, NAN)
	if is_nan(top):
		top = _mesh_box(mesh).end.y
		_tops[id] = top
	if top < FLAT_TOP:
		return true
	return tier == SHADOWS_FAR and top < FAR_SMALL_TOP


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
	## The first of a model's MultiMeshes (its parts and stand-in follow): a build may stop for the
	## frame before it, never between a model and its parts, which share instance order.
	var starts := false
	var paint := Color.WHITE  # a train stop's colour (_painted_wants)
	var paint_from := -1000.0
	var buf := PackedFloat32Array()
	var stride := 12
	var custom_off := 12
	var with_colors := false
	var upright := false
	var use_buf := false
	var pack_lod_buf := false
	var compute_bounds := false
	var bounds_done := false
	var mesh_box := AABB()
	var body_bounds := AABB()
	var shadow_proxy: Mesh
	var shadow_key: Variant
	var shadow_box := AABB()
	var shadow_buf := PackedFloat32Array()
	var shadow_bounds := AABB()
	var shadow_bounds_done := false


class ChunkPrepJob:
	var coord := Vector2i.ZERO
	var serial := 0
	var task_id := -1
	var wants: Array[Want] = []
	var wanted := {}
	var rings: Array = []
	var patch_reach := 0.0
	var merged: Variant
	var placeholder_keys := {}
	var ore_near := {}
	var belt_models := {}
	var has_belts := false
	var belt_bounds := AABB()
	var waiting_models := false
	var belt_waiting := false
	var total_instances := 0
	var contact_prep: ContactShade.Prepared
	var done := false

	## --native-chunk-build=off: the packing and bounds loops in GDScript, not ChunkBuildNative.
	static var native_chunk_build := Switches.on("--native-chunk-build")
	static var _chunk_native: Object  # a stateless ChunkBuildNative, shared by the worker threads
	static var _chunk_native_tried := false

	static func chunk_native() -> Object:
		if not _chunk_native_tried:
			_chunk_native_tried = true
			if native_chunk_build and NativeLibrary.ensure() and ClassDB.class_exists(&"ChunkBuildNative"):
				_chunk_native = ClassDB.instantiate(&"ChunkBuildNative")
		return _chunk_native

	static func pack_buffer(xforms: Array, colors: Array, custom: bool, upright: bool) -> PackedFloat32Array:
		var nat: Object = chunk_native()
		if nat != null:
			return nat.pack_buffer(xforms, colors, custom, upright)
		return pack_buffer_gd(xforms, colors, custom, upright)

	static func pack_buffer_gd(xforms: Array, colors: Array, custom: bool, upright: bool) -> PackedFloat32Array:
		var n: int = xforms.size()
		if n == 0:
			return PackedFloat32Array()
		var with_colors: bool = not colors.is_empty()
		var stride: int = 12 + (4 if with_colors else 0) + (4 if custom else 0)
		var out := PackedFloat32Array()
		out.resize(n * stride)
		for i in n:
			var t: Transform3D = xforms[i]
			var off: int = i * stride
			if upright:
				out[off + 0] = 1.0
				out[off + 3] = t.origin.x
				out[off + 5] = 1.0
				out[off + 7] = t.origin.y
				out[off + 10] = 1.0
				out[off + 11] = t.origin.z
			else:
				var b: Basis = t.basis
				var o: Vector3 = t.origin
				out[off + 0] = b.x.x
				out[off + 1] = b.y.x
				out[off + 2] = b.z.x
				out[off + 3] = o.x
				out[off + 4] = b.x.y
				out[off + 5] = b.y.y
				out[off + 6] = b.z.y
				out[off + 7] = o.y
				out[off + 8] = b.x.z
				out[off + 9] = b.y.z
				out[off + 10] = b.z.z
				out[off + 11] = o.z
			if with_colors:
				var c: Color = colors[i]
				out[off + 12] = c.r
				out[off + 13] = c.g
				out[off + 14] = c.b
				out[off + 15] = c.a
		return out

	static func box_bounds(box: AABB, xforms: Array) -> AABB:
		var nat: Object = chunk_native()
		if nat != null:
			return nat.box_bounds(box, xforms)
		return box_bounds_gd(box, xforms)

	static func box_bounds_gd(box: AABB, xforms: Array) -> AABB:
		var out := AABB()
		for i in xforms.size():
			var b: AABB = (xforms[i] as Transform3D) * box
			out = b if i == 0 else out.merge(b)
		return out

	func run() -> void:
		for w: Want in wants:
			var n: int = w.xforms.size()
			if n > 0:
				if w.use_buf or w.pack_lod_buf:
					w.buf = pack_buffer(w.xforms, w.colors, w.custom, w.upright)
				if w.compute_bounds or w.use_buf:
					w.body_bounds = box_bounds(w.mesh_box, w.xforms)
					w.bounds_done = true
			if w.shadow_proxy != null:
				if n > 0:
					w.shadow_buf = pack_buffer(w.xforms, [], false, false)
					w.shadow_bounds = box_bounds(w.shadow_box, w.xforms)
					w.shadow_bounds_done = true
		contact_prep = ContactShade.prepare(rings, patch_reach)
		done = true


## Packs MultiMesh instance rows (3x4 transform, optional color, optional zeroed custom data).
static func pack_multimesh_buffer(xforms: Array, colors: Array, custom: bool, upright := false) -> PackedFloat32Array:
	return ChunkPrepJob.pack_buffer(xforms, colors, custom, upright)


## Rebuilds the entity MultiMeshes. `working` maps unit numbers to machine working state;
## `anim` (anim.gd) gives moving parts their current angle and glows their current activity.
## A MultiMesh drawn before is filled again in place (nothing new for the renderer to take on);
## new ones are added within `budget` (none: all at once), the rest by add_pending().
## With `until_usec` (a Time.get_ticks_usec() deadline) a build that runs past it stops part-way
## (`building`) and carries on where it was when world.gd calls resume_build(): a busy chunk's records
## took up to 10-24 ms in one frame while walking (docs/PERFORMANCE-AUDIT.md 4.7). The MultiMeshes
## drawn before stay until it is done.
func build_entities(protos: ProtoDB, working: Dictionary, anim: Anim = null, budget: Budget = null, until_usec := 0) -> void:
	await collect_entities(protos, working, until_usec)
	if _prep_pending == null:
		return
	var job := _prep_pending
	_prep_pending = null
	if chunk_mm_worker:
		job.run()
	await apply_prepared(job, working, anim, budget, until_usec)


## Reads entity records and resolves models/Wants on the main thread, storing the resulting
## ChunkPrepJob in `_prep_pending` so a worker (or inline run()) can pack buffers before apply_prepared().
func collect_entities(protos: ProtoDB, working: Dictionary, until_usec := 0) -> void:
	_until = until_usec
	build_serial += 1
	var my_serial := build_serial
	_prep_pending = null
	pending.clear()

	var by_model := {}  # Mesh -> Array of Transform3D
	ChunkPrepJob.chunk_native()  # made here on the main thread, before a worker packs with it
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
	var col_belt_models := {}
	var col_placeholder_keys := {}
	var col_waiting_models := false
	var col_belt_waiting := false
	var switchable := {}  # keys of belts and loaders a network can switch off
	var belt_kinds := {}  # belt Mesh -> its stand-in's kind (belt_lods.gd)
	var belt_lo := Vector2.INF
	var belt_hi := -Vector2.INF
	var rings: Array = []  # contact_shade.gd collect()
	var scattered := {}  # ore rock Mesh -> per rank, Array of [Transform3D, rec]
	var wall_cells: Array = []  # cliff_wall.gd cell()s: Nauvis's cliffs drawn as one wall
	var cliffs := 0

	var done := 0
	var t_recs := Time.get_ticks_usec()  # (--stutter-probe: the records' pass and the MultiMeshes' as c_us_*)
	for rec in entities.values():
		done += 1
		if _until > 0 and (done & 15) == 0 and Time.get_ticks_usec() > _until:
			count("us_build_recs", Time.get_ticks_usec() - t_recs)
			await _wait_for_more()
			if retired or my_serial != build_serial:
				return
			t_recs = Time.get_ticks_usec()
		var proto: ProtoDB.EntityProto = protos.entity(rec.proto_id)
		if proto == null or rec.extra.has("gh") or rec.extra.has("tg") or ModelLibrary.hidden(proto.name):
			continue  # ghosts (and tile ghosts) are drawn by ghosts.gd
		if rec.extra.has("hid"):
			continue  # a belt the build of an underground pair mines, until the game says so (predicted.gd clear_run)
		if proto.type == "cliff":
			cliffs += 1
			if CliffWall.covers(proto.name, rec.extra):
				var wcell := CliffWall.cell(rec.pos, rec.fixed, str(rec.extra["co"]))
				if not wcell.is_empty():
					wall_cells.append(wcell)
					# (Its piece still loaded: a far merge draws it, far_chunks.gd.)
					ModelLibrary.entity_ready(proto.name, proto.type, rec.extra, rec.dir)
					continue
		if ModelLibrary.REMNANT_TYPES.has(proto.type):
			var remnant := _remnant(protos, proto, rec)
			if remnant.is_empty():
				col_waiting_models = true
				continue
			var rmesh: Mesh = remnant[0]
			if merged and FarChunks.merges(proto.type, rmesh):
				continue
			if not PipelineWarm.mesh_ready(rmesh):
				col_waiting_models = true  # its pipelines compiling (pipeline_warm.gd): drawn in a moment
				continue
			if not by_model.has(rmesh):
				by_model[rmesh] = []
				recs_by_model[rmesh] = []
				parts_by_model[rmesh] = []
			by_model[rmesh].append(remnant[1])
			recs_by_model[rmesh].append([rec, proto.type])
			continue
		if proto.type == "resource" and ModelLibrary.ORE_STAGES.has(proto.name):
			var rocks: Variant = ModelLibrary.ore_rocks(proto.name)
			if rocks == null:
				col_waiting_models = true
				continue
			if not (rocks as Array).is_empty():
				if not _scatter_ore(rec, proto.name, rocks, scattered):
					col_waiting_models = true
				continue
		var has_rec_cache: bool = "cache_gen" in rec
		if build_rec_cache and has_rec_cache and int(rec.cache_gen) == ModelLibrary.generation and rec.cache_mesh != null \
				and not rec.extra.has("cb") and not (rec.extra.has("fa") and proto.type == "mining-drill") \
				and rec.covers == 0 and rec.belt_ends == 0:
			var cmesh: Mesh = rec.cache_mesh
			if merged and FarChunks.merges(proto.type, cmesh):
				continue
			if not PipelineWarm.model_ready(cmesh, proto.name, proto.type, rec.extra, rec.dir):
				col_waiting_models = true
				continue
			if not by_model.has(cmesh):
				by_model[cmesh] = []
				recs_by_model[cmesh] = []
				parts_by_model[cmesh] = rec.cache_parts
			var cxform: Transform3D = rec.cache_xform
			by_model[cmesh].append(cxform)
			recs_by_model[cmesh].append([rec, proto.type])
			ContactShade.collect(rings, proto.name, proto.type, cmesh, cxform, proto.box_min, proto.box_max, Vector2(proto.tile_size))
			if Anim.SWITCHABLE_TYPES.has(proto.type) and (rec.extra.has("r") or rec.extra.has("g") or int(working.get(rec.unit, 0)) == Anim.SWITCHED_OFF):
				switchable[rec.key] = true
			if rec.cache_is_belt:
				belt_kinds[cmesh] = rec.cache_belt_kind
				belt_lo = belt_lo.min(rec.pos)
				belt_hi = belt_hi.max(rec.pos)
			continue
		var t_ready := Time.get_ticks_usec() if Probing.on else 0
		var ready := ModelLibrary.entity_ready(proto.name, proto.type, rec.extra, rec.dir)
		if Probing.on:
			Probing.add("cb_ready", t_ready)  # (--stutter-probe: the models asked for, w_cb_ready)
		if not ready:
			col_waiting_models = true  # nothing drawn until its model is made (no placeholder popping up)
			continue
		var mesh := ModelLibrary.mesh_for_entity(proto.name, proto.type, rec.extra, rec.dir)
		if merged and FarChunks.merges(proto.type, mesh):
			continue
		if mesh != null and not PipelineWarm.model_ready(mesh, proto.name, proto.type, rec.extra, rec.dir):
			col_waiting_models = true  # its pipelines compiling (pipeline_warm.gd): drawn in a moment, not in a frozen frame
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
			var mparts: Array = ModelLibrary.parts_for_entity(proto.name, proto.type, rec.extra, rec.dir)
			var mxform: Transform3D = _model_transform(proto, rec)
			if not by_model.has(mesh):
				by_model[mesh] = []
				recs_by_model[mesh] = []
				parts_by_model[mesh] = mparts
			by_model[mesh].append(mxform)
			recs_by_model[mesh].append([rec, proto.type])
			ContactShade.collect(rings, proto.name, proto.type, mesh, mxform, proto.box_min, proto.box_max, Vector2(proto.tile_size))
			if Anim.SWITCHABLE_TYPES.has(proto.type) and (rec.extra.has("r") or rec.extra.has("g") or int(working.get(rec.unit, 0)) == Anim.SWITCHED_OFF):
				switchable[rec.key] = true
			var is_belt: bool = BeltLods.TYPES.has(proto.type)
			var belt_kind: String = BeltLods.kind_of(proto.type, rec.extra) if is_belt else ""
			if is_belt:
				belt_kinds[mesh] = belt_kind
				belt_lo = belt_lo.min(rec.pos)
				belt_hi = belt_hi.max(rec.pos)
			if build_rec_cache and has_rec_cache and not rec.extra.has("cb") \
					and not (rec.extra.has("fa") and proto.type == "mining-drill") \
					and rec.covers == 0 and rec.belt_ends == 0:
				rec.cache_gen = ModelLibrary.generation
				rec.cache_mesh = mesh
				rec.cache_parts = mparts
				rec.cache_xform = mxform
				rec.cache_is_belt = is_belt
				rec.cache_belt_kind = belt_kind
			if rec.extra.has("cb"):
				if _add_cargo_pieces(rec, mxform, by_model, recs_by_model, parts_by_model):
					col_waiting_models = true
			if rec.extra.has("fa") and proto.type == "mining-drill":
				if _add_wet(rec, proto, mxform, by_model, recs_by_model, parts_by_model):
					col_waiting_models = true
			if rec.covers != 0:
				if _add_covers(rec, proto, mxform, by_model, recs_by_model, parts_by_model):
					col_waiting_models = true
			if rec.belt_ends != 0:
				if _add_belt_ends(rec, proto, mxform, by_model, recs_by_model, parts_by_model, cap_parts):
					col_waiting_models = true
			continue
		# No model: the entity's own picture from the bridge's list (a mod's building), else a box.
		var t_card := Time.get_ticks_usec() if Probing.on else 0
		var card := SpriteStandins.card(proto.name, rec.dir, proto.size(), proto.type) if proto.type != "resource" else null
		if Probing.on:
			Probing.add("cb_card", t_card)
		if card == null and SpriteStandins.coming(proto.name, rec.dir):
			col_waiting_models = true  # drawn once its picture is composed, not as a box first
			continue
		if card != null and not PipelineWarm.mesh_ready(card):
			col_waiting_models = true
			continue
		if card == null and proto.type != "resource" and SpriteStandins.in_use():
			continue  # with a graphics list, no boxes or cones: only pictures (owner's choice)
		col_placeholder_keys[rec.key] = true
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
	cliff_count = cliffs
	if not wall_cells.is_empty() or wall.sig != 0:
		wall_cells.sort_custom(func(a: Array, b: Array) -> bool: return int(a[3]) < int(b[3]))
		CliffWall.want(self, wall_cells)
	var col_ore_near := {}
	for rock: Mesh in scattered:
		if not by_model.has(rock):
			by_model[rock] = []
			recs_by_model[rock] = []
			parts_by_model[rock] = []
		var ranks: Array = scattered[rock]
		for rank in ranks.size():
			for entry: Array in ranks[rank]:
				by_model[rock].append(entry[0])
				recs_by_model[rock].append([entry[1], "resource"])
			if rank == 0:
				col_ore_near[rock] = (by_model[rock] as Array).size()
	if _until > 0 and done > 16 and Time.get_ticks_usec() > _until:
		await _wait_for_more()  # the records are read: the MultiMeshes next time
		if retired or my_serial != build_serial:
			return
	var t_wants := Time.get_ticks_usec()
	var wants: Array[Want] = []
	for model in by_model:
		var glows := ModelLibrary.glows(model)
		var switches := _switches_in(recs_by_model[model], switchable)
		var whole := _want(model, model, by_model[model], [], null, glows or not switches.is_empty(), recs_by_model[model], null, glows)
		whole.switches = switches
		whole.starts = true
		wants.append(whole)
		var parts: Array = parts_by_model[model]
		for i in parts.size():
			var part: ModelLibrary.AnimPart = parts[i]
			wants.append(_want([model, i], part.mesh, by_model[model], [], null, true, recs_by_model[model], part, true))
		if belt_kinds.has(model):
			col_belt_models[model] = parts.size()
			var flat := BeltLods.stand_in(model, belt_kinds[model])
			if flat != null:
				var flat_want := _want([model, BeltLods.FLAT], flat, by_model[model], [], null, not switches.is_empty(), [], null, false)
				flat_want.switches = switches
				wants.append(flat_want)
			elif BeltLods.coming(model):
				col_belt_waiting = true
	for paint_key: Array in painted:
		wants.append_array(_painted_wants(paint_key, painted[paint_key]))
	for key: Array in cap_parts:
		var entry: Array = cap_parts[key]
		var cap_part: ModelLibrary.AnimPart = entry[2]
		wants.append(_want(key, cap_part.mesh, entry[0], [], null, true, entry[1], cap_part, true))
	for card in cards:
		wants.append(_want(["card", card], card, cards[card], card_colors[card], null, false, [], null, false))
	if not boxes.is_empty():
		wants.append(_want("box", Visuals.box_mesh(), boxes, box_colors, Visuals.instance_material(), false, [], null, false))
	if not cones.is_empty():
		wants.append(_want("cone", Visuals.cone_mesh(), cones, cone_colors, Visuals.instance_material(), false, [], null, false))
	var wanted := {}
	var total_instances := 0
	var hold_ground := GroundHeight.holding()
	for w in wants:
		wanted[w.key] = true
		if w.part == null and (w.key is String or (w.key is Array and w.key[0] is String)):
			w.starts = true  # cards, boxes, cones
		Anim.setup_part(w.part)  # main thread only: updates shared part bounds before worker packs
		w.upright = w.part != null and w.part.upright
		w.with_colors = not w.colors.is_empty()
		w.stride = 12 + (4 if w.with_colors else 0) + (4 if w.custom else 0)
		w.custom_off = 12 + (4 if w.with_colors else 0)
		var has_lods := _want_has_lods(w)
		w.use_buf = not w.group and w.switches.is_empty() and not has_lods
		w.pack_lod_buf = not w.group and w.switches.is_empty() and has_lods
		w.compute_bounds = hold_ground and (ViewPriority.tight_cull or not w.group)
		if w.compute_bounds or w.use_buf:
			w.mesh_box = _mesh_box(w.mesh)
		var smodel: Mesh = w.key if (w.part == null and w.key is Mesh) else (w.mesh if ModelLods.part_has_levels(w.part) else null)
		if smodel != null:
			w.shadow_proxy = ModelLods.proxy_for(smodel)
			if w.shadow_proxy != null:
				w.shadow_key = w.key
				w.shadow_box = smodel.get_aabb()
		total_instances += w.xforms.size()
	waiting_models = col_waiting_models
	belt_waiting = col_belt_waiting
	count("us_build_wants", Time.get_ticks_usec() - t_wants)

	var job := ChunkPrepJob.new()
	job.coord = coord
	job.serial = my_serial
	job.wants = wants
	job.wanted = wanted
	job.rings = rings
	job.patch_reach = ContactShade.patch_ring_reach()
	job.merged = merged
	job.placeholder_keys = col_placeholder_keys
	job.ore_near = col_ore_near
	job.belt_models = col_belt_models
	job.has_belts = not col_belt_models.is_empty()
	if job.has_belts:
		job.belt_bounds = AABB(Vector3(belt_lo.x - 1.0, 0.0, belt_lo.y - 1.0), Vector3(belt_hi.x - belt_lo.x + 2.0, 1.0, belt_hi.y - belt_lo.y + 2.0))
	job.waiting_models = col_waiting_models
	job.belt_waiting = col_belt_waiting
	job.total_instances = total_instances
	_prep_pending = job


## Applies a completed ChunkPrepJob (whose MultiMesh buffers, bounds, and ContactShade matrices
## were packed off-thread or inline) within the frame deadline and MultiMesh creation budget.
func apply_prepared(job: ChunkPrepJob, working: Dictionary, anim: Anim = null, budget: Budget = null, until_usec := 0) -> void:
	if job == null or retired or job.serial != build_serial:
		return
	_until = until_usec
	anim_groups.clear()
	placeholder_keys = job.placeholder_keys
	_ore_near = job.ore_near
	_belt_models = job.belt_models
	_switches.clear()
	pending.clear()
	waiting_models = job.waiting_models
	belt_waiting = job.belt_waiting
	if not job.has_belts or retired:
		BeltLods.untrack(self)
	else:
		belt_bounds = job.belt_bounds
		BeltLods.track(self)
	for key in _nodes.keys():
		if not job.wanted.has(key):
			_drop(key)
	var t_apply := Time.get_ticks_usec()
	var applied := 0
	var listed := false
	for w in job.wants:
		# The MultiMeshes stop at the deadline too (between models): filling a busy chunk's 60-150
		# ran to the end whatever it cost, 171 overruns a laps run, the worst 11 ms against a 6 ms
		# grant (client-cpu.md 6). Those filled stay drawn with the new instances, the rest with the old.
		if apply_deadline and _until > 0 and w.starts and applied > 0 and Time.get_ticks_usec() > _until:
			count("us_build_apply", Time.get_ticks_usec() - t_apply)
			if not listed:
				listed = true
				_refresh_lists()  # none of the dropped ones left in the lists while it waits
			await _wait_for_more()
			if retired or job.serial != build_serial:
				return
			t_apply = Time.get_ticks_usec()
			applied = 0
		if budget == null or budget.left > 0 or _nodes.has(w.key):
			if chunk_mm_worker:
				_apply_prepared(w, working, anim, budget)
			else:
				_apply(w, working, anim, budget)
			applied += 1
		else:
			pending.append(w)
	count("us_build_apply", Time.get_ticks_usec() - t_apply)
	if apply_deadline and _until > 0 and applied > 0 and Time.get_ticks_usec() > _until:
		if not listed:
			_refresh_lists()
		await _wait_for_more()  # the lists, shadows and contact rings next time
		if retired or job.serial != build_serial:
			return
	t_apply = Time.get_ticks_usec()
	_refresh_lists()
	_apply_shadows()
	if job.contact_prep != null:
		contact_node = ContactShade.apply_prepared(self, contact_node, job.contact_prep)
	else:
		contact_node = ContactShade.apply(self, contact_node, job.rings)
	FarChunks.built(self, job.merged)
	count("us_build_finish", Time.get_ticks_usec() - t_apply)


## A build part-way through (build_entities' until_usec) waits for this, with a new deadline.
signal _more_time
## Builds stop at their deadline between models' MultiMeshes too, not only in the records' pass
## (`--build-apply-deadline=off`: the MultiMeshes all filled in one go, as before).
static var apply_deadline := Switches.on("--build-apply-deadline")
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


## Adds MultiMeshes a build left for later, within `budget` (and optional `until_usec` deadline). True once none are left.
func add_pending(working: Dictionary, anim: Anim, budget: Budget, until_usec := 0) -> bool:
	if pending.is_empty():
		return true
	var did := false
	while not pending.is_empty() and budget.left > 0:
		if did and until_usec > 0 and Time.get_ticks_usec() > until_usec:
			break
		var w: Want = pending.pop_front()
		if chunk_mm_worker:
			_apply_prepared(w, working, anim, budget)
		else:
			_apply(w, working, anim, budget)
		did = true
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
	out[0].starts = true
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
	_thin(mmi.multimesh, w.key if w.part == null else null)
	# On hills the bounds grow in height only by what they lift (ground_height.gd), not every way.
	# Parts anim.gd moves on the CPU (turret heads turning) keep the MultiMesh's own bounds, which
	# follow them, and the margin.
	if GroundHeight.holding() and (ViewPriority.tight_cull or not w.group):
		GroundHeight.cull_box(mmi, _bounds(_mesh_box(w.mesh), w.xforms))
	else:
		GroundHeight.cull_box(mmi, AABB())
	if w.paint != Color.WHITE:
		mmi.set_instance_shader_parameter("f3d_paint", w.paint)
		mmi.set_instance_shader_parameter("f3d_paint_from", w.paint_from)
	if not w.switches.is_empty() and not w.group:
		_draw_switches(w, mmi.multimesh, working)
	count("instances", w.xforms.size())
	var group: Anim.Group = null
	if w.group:
		group = _add_group(mmi.multimesh, w.part, w.xforms, w.recs, working, anim)
	var st: LodState = _lods.get(mmi)
	if st != null:
		st.from_apply = true
		st.xforms = w.xforms
		st.colors = w.colors
		st.custom = w.custom
		st.group = group
		st.switches = w.switches if not w.group else []
		st.buffer = PackedFloat32Array()
	if w.part == null and w.key is Mesh:
		_shadow_proxy(w.key, w.xforms, budget)
	elif ModelLods.part_has_levels(w.part):
		# Its stand-in casts its shadow at rest, as a body's does (asking for it makes its levels too):
		# rollers turning in a belt's shadow can't be seen, and the part's own shadow at full detail was
		# most of the shadow pass's triangles on a base of a modeller's belts.
		_shadow_proxy(w.mesh, w.xforms, budget, w.key)


func _fill_buffer(mm: MultiMesh, mesh: Mesh, n: int, with_colors: bool, custom: bool, buf: PackedFloat32Array, bounds := AABB()) -> void:
	if mm.transform_format != MultiMesh.TRANSFORM_3D or mm.use_colors != with_colors or mm.use_custom_data != custom:
		mm.instance_count = 0
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = with_colors
		mm.use_custom_data = custom
	if mm.instance_count != n:
		mm.instance_count = n
	mm.custom_aabb = AABB(bounds.position, bounds.size.max(Vector3(0.01, 0.01, 0.01))) if n > 0 else AABB()
	if mm.mesh != mesh:
		mm.mesh = mesh
	if n > 0 and not buf.is_empty():
		mm.buffer = buf


func _apply_prepared(w: Want, working: Dictionary, anim: Anim, budget: Budget) -> void:
	var mmi: MultiMeshInstance3D = _nodes.get(w.key)
	if mmi == null:
		mmi = _new_mmi(w.material)
		_nodes[w.key] = mmi
		if budget != null:
			budget.left -= maxi(w.mesh.get_surface_count(), 1)
		count("mmi")
		count("surfaces", w.mesh.get_surface_count())
	var group: Anim.Group = null
	var st_buf := PackedFloat32Array()
	if not w.use_buf:
		# MultiMeshes mutated per-instance or on LOD mesh switch keep CPU data_cache.
		_fill(mmi.multimesh, _lod_mesh(mmi, w), w.xforms, w.colors, w.custom)
		_thin(mmi.multimesh, w.key if w.part == null else null)
		if w.compute_bounds:
			if not w.bounds_done and not w.xforms.is_empty():
				w.body_bounds = ChunkPrepJob.box_bounds(w.mesh_box, w.xforms)
				w.bounds_done = true
			GroundHeight.cull_box(mmi, w.body_bounds)
		else:
			GroundHeight.cull_box(mmi, AABB())
		if w.paint != Color.WHITE:
			mmi.set_instance_shader_parameter("f3d_paint", w.paint)
			mmi.set_instance_shader_parameter("f3d_paint_from", w.paint_from)
		if not w.switches.is_empty() and not w.group:
			_draw_switches(w, mmi.multimesh, working)
		if w.group:
			group = _add_group(mmi.multimesh, w.part, w.xforms, w.recs, working, anim)
		if w.pack_lod_buf:
			if w.buf.is_empty() and not w.xforms.is_empty():
				w.buf = ChunkPrepJob.pack_buffer(w.xforms, w.colors, w.custom, w.upright)
			st_buf = w.buf
	else:
		if w.buf.is_empty() and not w.xforms.is_empty():
			w.buf = ChunkPrepJob.pack_buffer(w.xforms, w.colors, w.custom, w.upright)
		if not w.bounds_done and not w.xforms.is_empty():
			if w.mesh_box.size == Vector3.ZERO:
				w.mesh_box = _mesh_box(w.mesh)
			w.body_bounds = ChunkPrepJob.box_bounds(w.mesh_box, w.xforms)
			w.bounds_done = true
		_fill_buffer(mmi.multimesh, _lod_mesh(mmi, w), w.xforms.size(), w.with_colors, w.custom, w.buf, w.body_bounds)
		_thin(mmi.multimesh, w.key if w.part == null else null)
		GroundHeight.cull_box(mmi, w.body_bounds if w.compute_bounds else AABB())
		if w.paint != Color.WHITE:
			mmi.set_instance_shader_parameter("f3d_paint", w.paint)
			mmi.set_instance_shader_parameter("f3d_paint_from", w.paint_from)
		st_buf = w.buf
	count("instances", w.xforms.size())
	var st: LodState = _lods.get(mmi)
	if st != null:
		st.from_apply = true
		st.xforms = w.xforms
		st.colors = w.colors
		st.custom = w.custom
		st.group = group
		st.switches = w.switches if not w.group else []
		st.buffer = st_buf
	if w.shadow_proxy != null:
		_shadow_proxy_buf(w, budget)


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
	if mm.custom_aabb != AABB():
		mm.custom_aabb = AABB()
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
		if far != null and not far.hidden.is_empty():
			far.hidden.erase(mmi)  # far_chunks.gd's list of MultiMeshes hidden behind the merged mesh
		mmi.free()
	_nodes.erase(key)
	var shadow: Node = _shadows.get(key)
	if shadow != null:
		shadow.free()
	_shadows.erase(key)


static func _want_has_lods(w: Want) -> bool:
	return not ((w.part != null and not ModelLods.part_has_levels(w.part)) or not (w.mesh is ArrayMesh) or w.key is String)


## The mesh a Want's MultiMesh draws: for a model with levels of detail, the level its chunk is at
## (a build keeps it, so filling the MultiMesh again doesn't pop it back to the whole model).
func _lod_mesh(mmi: MultiMeshInstance3D, w: Want) -> Mesh:
	if not _want_has_lods(w):
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
## is nearer than its level was made for. Also moves cross-fades on by `delta`. When
## `switch_budget >= 0`, stops after that many level switches and sets `lod_partial` without
## updating `_lod_allowed` so the caller finishes this chunk on the next frame.
func update_lods(camera: Vector3, allowed_per_tile: float, allowed_flat: float, delta: float, switch_budget := -1) -> void:
	lod_last_switches = 0
	if _lods.is_empty():
		lod_partial = false
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
	if not lod_partial and _lod_generation == ModelLods.level_generation and _lod_allowed > 0.0 \
			and absf(allowed - _lod_allowed) <= _lod_allowed * LOD_LOOK_AGAIN:
		return
	lod_partial = false
	for mmi: MultiMeshInstance3D in _lods:
		var st: LodState = _lods[mmi]
		var levels := ModelLods.levels(st.model)
		var level := ModelLods.level_for(levels, st.level, allowed)
		if level != st.level:
			if switch_budget >= 0 and lod_last_switches >= switch_budget:
				lod_partial = true
				return
			_switch_level(mmi, st, level, levels)
			lod_last_switches += 1
	_lod_allowed = maxf(allowed, 1e-6)
	_lod_generation = ModelLods.level_generation


## Moves active cross-fades on by `delta` without switching any model's level (world.gd _lod_fades).
func advance_lod_fades(delta: float) -> void:
	if _lod_fading > 0:
		_advance_fades(delta)


## Draws the model at `level`, the level before fading out over ModelLods.FADE_SECONDS through a
## copy of the MultiMesh (the same instances, so the same states), the new one fading in.
func _switch_level(mmi: MultiMeshInstance3D, st: LodState, level: int, levels: Array) -> void:
	var mm := mmi.multimesh
	var before := mm.mesh
	_end_fade(mmi, st)
	st.level = level
	mm.mesh = st.model if level == 0 else levels[level - 1][0]
	if lod_mesh_touch and mm.instance_count > 0:
		_touch_after_mesh_swap(mm, st)
	if lod_snap:
		return
	if ModelLods.FADE_SECONDS <= 0.0 or ModelLods.full_detail or not mmi.visible or not mmi.is_inside_tree() or mm.instance_count == 0 or before == null:
		return
	var copy := MultiMesh.new()
	copy.transform_format = mm.transform_format
	if lod_cpu_copy and not st.buffer.is_empty() and st.group == null and st.switches.is_empty():
		copy.use_colors = mm.use_colors
		copy.use_custom_data = mm.use_custom_data
		copy.instance_count = mm.instance_count
		copy.custom_aabb = mm.custom_aabb
		copy.mesh = before
		copy.buffer = st.buffer
		count("lod_cpu_copies")
	elif lod_cpu_copy and st.from_apply:
		var xforms: Array = _lod_xforms(st)
		_fill(copy, before, xforms, st.colors, st.custom)
		if st.custom:
			if st.group != null:
				for i in mini(copy.instance_count, st.group.customs.size()):
					copy.set_instance_custom_data(i, st.group.customs[i])
			else:
				for i in copy.instance_count:
					copy.set_instance_custom_data(i, Color(0.0, 0.0, 0.0, 0.0))
				for s: Array in st.switches:
					for entry: Array in _switches.get(s[1], []):
						if entry[0] == mm and int(entry[1]) == int(s[0]) and bool(entry[2]):
							copy.set_instance_custom_data(int(s[0]), Anim.BELT_STOPPED)
							break
		count("lod_cpu_copies")
	elif lod_no_readback:
		count("lod_readbacks_skipped")
		return  # no CPU copy: switched at once, not read back for a cross-fade
	else:
		copy.use_colors = mm.use_colors
		copy.use_custom_data = mm.use_custom_data
		copy.mesh = before
		copy.instance_count = mm.instance_count
		var data := mm.buffer
		if not data.is_empty():
			copy.buffer = data
		count("lod_buffer_readbacks")
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


static func _lod_xforms(st: LodState) -> Array:
	if st == null:
		return []
	if st.group != null:
		return st.group.drawn if not st.group.drawn.is_empty() else st.group.bases
	return st.xforms


## Re-writes instance 0's transform on the same frame as `mm.mesh = ...`: in Godot 4.7 Forward+
## with motion vectors (FSR2 or TAA), swapping `MultiMesh.mesh` without touching an instance that
## frame causes a later `set_instance_custom_data` / `set_instance_transform` (e.g.
## Anim.state_changed on working buildings or splitters) to zero every instance's transform.
static func _touch_after_mesh_swap(mm: MultiMesh, st: LodState) -> void:
	var xforms: Array = _lod_xforms(st)
	var xf0: Transform3D
	if not xforms.is_empty():
		xf0 = xforms[0] as Transform3D
	elif lod_no_readback:
		var b := st.buffer if st != null else PackedFloat32Array()
		if b.size() < 12:
			return  # no CPU copy of instance 0: not read back from the renderer
		# A TRANSFORM_3D buffer's row-major 3x4: basis columns' x, origin x; then y; then z.
		xf0 = Transform3D(Vector3(b[0], b[4], b[8]), Vector3(b[1], b[5], b[9]), Vector3(b[2], b[6], b[10]),
			Vector3(b[3], b[7], b[11]))
	else:
		xf0 = mm.get_instance_transform(0)
	mm.set_instance_transform(0, xf0)
	count("lod_mesh_touches")


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


## A drill's fluid part (ModelLibrary.wet_model: `<drill>-wet`, while the resource under it needs fluid) over the
## drill at its own place. True while its model is being made.
func _add_wet(rec, proto: ProtoDB.EntityProto, base: Transform3D, by_model: Dictionary, recs_by_model: Dictionary, parts_by_model: Dictionary) -> bool:
	var name := ModelLibrary.wet_model(proto.name, proto.type, rec.extra, rec.dir)
	if name == "":
		return false
	if not ModelLibrary.ready(name):
		return true
	var mesh := ModelLibrary.mesh_for(name)
	if mesh == null:
		return false
	if not PipelineWarm.mesh_ready(mesh):
		return true
	if not by_model.has(mesh):
		by_model[mesh] = []
		recs_by_model[mesh] = []
		parts_by_model[mesh] = ModelLibrary.parts_for(name)
	by_model[mesh].append(base)
	recs_by_model[mesh].append([rec, proto.type])
	return false


## Pipe covers (pipe_covers.gd) on a machine's connections with nothing connected (its record's `covers`,
## world.gd _cover), from the pack that draws it. True while the cover is being made.
func _add_covers(rec, proto: ProtoDB.EntityProto, base: Transform3D, by_model: Dictionary, recs_by_model: Dictionary, parts_by_model: Dictionary) -> bool:
	var name := PipeCovers.model_for(ModelLibrary.drawing_pack(proto.name, proto.type, rec.extra, rec.dir))
	if name == "":
		return false
	if not ModelLibrary.ready(name):
		return true
	if name.begins_with(PipeCovers.ENDING + "@") and not ModelLibrary.ready(PipeCovers.STRAIGHT + name.substr(PipeCovers.ENDING.length())):
		return true
	var made := PipeCovers.cover(name, func(n: String) -> Mesh: return ModelLibrary.mesh_for(n))
	if made.is_empty():
		return false
	var mesh: Mesh = made[0]
	if not PipelineWarm.mesh_ready(mesh):
		return true
	if not by_model.has(mesh):
		by_model[mesh] = []
		recs_by_model[mesh] = []
		parts_by_model[mesh] = []
	# At the entity's position, turned as its model (a model's placement offset isn't its connections').
	var at := Transform3D(base.basis, Vector3(rec.pos.x, base.origin.y, rec.pos.y))
	for place: Transform3D in PipeCovers.places(rec.cover_ports, rec.covers, at):
		by_model[mesh].append(place)
		recs_by_model[mesh].append([rec, proto.type])
	return false


## An ore tile's rocks (ModelLibrary.ore_rock_places) into `scattered`, per model and rank. False while a
## rock's pipelines are being compiled (pipeline_warm.gd): drawn in a moment, the tile whole.
func _scatter_ore(rec, ore: String, rocks: Array, scattered: Dictionary) -> bool:
	for rock: Mesh in rocks:
		if not PipelineWarm.mesh_ready(rock):
			return false
	var places := ModelLibrary.ore_rock_places(rec.fixed, Vector3(rec.pos.x, 0.0, rec.pos.y), int(rec.extra.get("a", 1000)), rocks.size(), ore)
	for rank in places.size():
		var rock: Mesh = rocks[int(places[rank][0])]
		if not scattered.has(rock):
			scattered[rock] = []
		var ranks: Array = scattered[rock]
		while ranks.size() <= rank:
			ranks.append([])
		(ranks[rank] as Array).append([places[rank][1], rec])
	return true


## A far chunk shows one rock an ore tile (its scattered ore's first rank), a near one all: in place, no build
## (far_chunks.gd, when the chunk goes far or comes near).
func thin_ore() -> void:
	for rock: Mesh in _ore_near:
		for table: Dictionary in [_nodes, _shadows]:
			var mmi: MultiMeshInstance3D = table.get(rock)
			if mmi != null:
				_thin(mmi.multimesh, rock)


## Sets a MultiMesh's visible count: a scattered ore model's (`key`) in a far chunk its first rank's.
func _thin(mm: MultiMesh, key: Variant) -> void:
	var shown := -1
	if key is Mesh and _ore_near.has(key) and far.far:
		shown = mini(int(_ore_near[key]), mm.instance_count)
	if mm.visible_instance_count != shown:
		mm.visible_instance_count = shown


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
		# Each surface its own stand-in material (a tree's crown its leaf one: ModelLods.leaf_material()).
		mmi = _new_mmi(null)
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		mmi.visible = false
		_shadows[key] = mmi
		if budget != null:
			budget.left -= 1
	_fill(mmi.multimesh, proxy, xforms, [], false)
	_thin(mmi.multimesh, key)
	# The proxy may still be empty: give it the model's bounds so it isn't culled once filled (and
	# room for the hills' lift, ground_height.gd).
	GroundHeight.cull_box(mmi, _bounds(model.get_aabb(), xforms))


func _shadow_proxy_buf(w: Want, budget: Budget) -> void:
	var key: Variant = w.shadow_key
	var mmi: MultiMeshInstance3D = _shadows.get(key)
	if mmi == null:
		count("shadow_mmi")
		mmi = _new_mmi(null)
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		mmi.visible = false
		_shadows[key] = mmi
		if budget != null:
			budget.left -= 1
	if w.shadow_buf.is_empty() and not w.xforms.is_empty():
		w.shadow_buf = ChunkPrepJob.pack_buffer(w.xforms, [], false, false)
	if not w.shadow_bounds_done and not w.xforms.is_empty():
		w.shadow_bounds = ChunkPrepJob.box_bounds(w.shadow_box, w.xforms)
		w.shadow_bounds_done = true
	_fill_buffer(mmi.multimesh, w.shadow_proxy, w.xforms.size(), false, false, w.shadow_buf, w.shadow_bounds)
	_thin(mmi.multimesh, key)
	GroundHeight.cull_box(mmi, w.shadow_bounds)


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
	return ChunkPrepJob.box_bounds(box, xforms)


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
	if proto.type != "resource":
		# Nauvis's trees and rocks: Factorio's variations, sizes and fallen trees (nature_looks.gd).
		var looks: Variant = NatureLooks.placed(proto.name, h, at)
		if looks != null:
			return looks
	var yaw := float(h & 0xffff) / 65536.0 * TAU
	var size := 0.9 + 0.2 * float((h >> 16) & 0xff) / 255.0
	var height := size
	if proto.type == "resource":
		var amount := maxf(float(rec.extra.get("a", 1000)), 1.0)
		height *= 0.6 + 0.6 * clampf(log(amount) / log(10000.0), 0.0, 1.0)
	return Transform3D(Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3(size, height, size)), at)


func _build_group(part: ModelLibrary.AnimPart, xforms: Array, recs: Array) -> Anim.Group:
	var group := Anim.Group.new()
	group.part = part
	var upright: bool = part != null and part.upright
	for i in xforms.size():
		var rec = recs[i][0]
		var base: Transform3D = xforms[i]
		if upright:
			base = Transform3D(Basis.IDENTITY, base.origin)
		group.keys.append(rec.key)
		group.units.append(rec.unit)
		group.bases.append(base)
		group.stateful.append(Anim.state_source(str(recs[i][1])))
		group.hint_sg.append(clampi(int(rec.extra.get("sg", 0)), 0, 255))
		var custom := Anim.custom_for(rec, 1.0)
		if upright:
			custom.b = 0.0  # its sprite is drawn facing north
		group.customs.append(custom)
	return group


## A moving part's or glowing model's instances, handed to anim.gd, which sets them to where their
## entities' states have them now (most move in the shader from there).
func _add_group(mm: MultiMesh, part: ModelLibrary.AnimPart, xforms: Array, recs: Array, working: Dictionary, anim: Anim) -> Anim.Group:
	var group := _build_group(part, xforms, recs)
	group.mm = mm
	Anim.place(group, anim, working)
	anim_groups.append(group)
	return group
