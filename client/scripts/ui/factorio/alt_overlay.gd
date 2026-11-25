extends Control
## Factorio's Alt-mode (Alt): over each machine in view the icon of what it is set to make or let
## through (an assembler's or furnace's recipe, an inserter's, splitter's or storage chest's
## filter), from its record's `extra.ai` (issue #9: every machine the client has loaded, kept per
## chunk in ChunkView.alt and changed by `aiu`), over each chest without such an icon what it holds
## most of (world.gd's alt_contents from `ac`, J6: up to four kinds in a grid, as Factorio's Alt-mode
## shows container contents), in rows over machines their modules, over labs their science packs,
## over ammo turrets their ammo, over cargo wagons their most-stacked kinds and over locomotives their fuel (off unless asked)
## (world.gd's alt_machines from `am`, K1, K2), and on every pipe, underground pipe, pump and
## tank the icon of the fluid in it (fluids_power.gd's `fl`). Where each goes is Factorio's own: an
## entity's icon by its prototype's icon_draw_specification (`eprops` ids: a shift from its centre
## and a scale), the rows by its icons_positioning (`eprops` isq, sequence_cells). As in Factorio the icons have no
## disc behind them, only a soft dark shadow, and are drawn flat over the world at the entity's
## position projected through the camera, sized with the zoom. Only chunks in the camera's view
## are looked at. Where icons overlap on the screen the one nearest the camera is drawn in front
## (`icon_order`): each icon goes into the first layer after every farther icon it overlaps, and each
## layer draws its shadows, then its icons picture by picture, so the canvas still batches them (a
## shadow between two icons would split every batch); icons that overlap nothing are all in the first.
##
## factorio_ui.gd sets `player` (player_input.gd: its world mirror and camera rig).

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const Slot := preload("res://scripts/ui/factorio/slot.gd")
const WorldMirror := preload("res://scripts/world/world.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const DepthIcon := preload("res://shaders/billboard_icon_depth.gdshader")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const ModGraphics := preload("res://scripts/world/mod_graphics.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const Probing := preload("res://scripts/debug/probing.gd")
const GpuShader := preload("res://shaders/alt_icons.gdshader")
const Switches := preload("res://scripts/switches.gd")

## The icon is this many tiles across (measured on Factorio's alt-mode over assemblers).
const ICON_TILES := 1.2
## Over a chest: Factorio scales a chest's icons by its prototype's icon_draw_specification, 0.7 on
## every chest of the base game (wooden to steel, the five logistic chests).
const CHEST_TILES := ICON_TILES * 0.7
const CHEST_TYPES := ["container", "logistic-container", "infinity-container", "linked-container"]
## A fluid's icon on a pipe.
const FLUID_TILES := 0.55
const FLUID_TYPES := ["pipe", "pipe-to-ground", "pump", "storage-tank", "infinity-pipe"]
## Plain pipes carry the icon only now and then, as Factorio's Alt-mode (owner's P50: one on every
## pipe covered a run). One tile in this many, on a slanted lattice (`pipe_shows_icon`).
const PIPE_ICON_EVERY := 5
const SPARSE_FLUID_TYPES := ["pipe", "infinity-pipe"]
const SHADOW := Color(0, 0, 0, 0.6)
## A module's or science pack's icon at its row's scale 1 is this many tiles across. Factorio's own
## rows fit at 1: Space Age's lab puts six packs a row at scale 0.5 and separation 1/1.1 over its
## three tiles, with its modules' row under them (larger, the rows would overflow and overlap).
const SEQUENCE_TILE := 1.0
## Its quality's mark, at the icon's bottom left, this share of its side (as in a slot).
const QUALITY_SHARE := 0.4
## Beacons draw their modules only while the mouse is on them (Factorio 2.1.8's changelog).
const HOVER_ONLY_TYPES := ["beacon"]
## --alt-icon-spec=off: every machine's own icon centred at ICON_TILES as before K1 (eprops ids unread).
static var use_spec := true
## --alt-ammo-fuel=off: no ammo over turrets, fuel over locomotives or cargo over wagons, as before (isq's "a", "f" and "c" rows unread).
## Locomotives' fuel is off by default (owner: only the wagons' cargo matters); --loco-fuel-icons=on (Bridge.loco_fuel_icons) brings it back.
static var ammo_fuel := true
## --alt-icon-order=old: every shadow first, then the icons picture by picture in the order they were
## found, whichever is nearer (an icon further off could cover a nearer one: the owner's column of
## assemblers' recipes, the farthest in front); in first person a machine's own cells at one depth.
static var icon_order := true
## The owner's "icons jitter as the camera or the character moves": which of two overlapping icons
## (and its shadow) is drawn in front came from their depth ahead of the camera, rounded to 1/256
## tile, so two at one depth (a row of chests, inserters, a machine's cells) swapped places whenever
## the camera's moving position took float noise across a rounding step, several times a second
## while panning or running. Now the order is by depth along the view from a fixed origin (the same
## for every camera position, changing only as the view turns), in 64-bit floats.
## --alt-depth-order=old: by depth from the camera as before.
static var stable_order := not Switches.has("--alt-depth-order=old")
## --alt-flat-batch=off falls back to interleaving each mark right after its icon in _flat mode.
static var flat_batch_marks := true
## --alt-cache=off restores uncached per-frame collection and unconditional redraws.
static var use_cache := Switches.on("--alt-cache")
## --alt-flat-batch-tex=off restores unbatched depth-ordered _flat icon drawing.
static var flat_batch_tex := Switches.on("--alt-flat-batch-tex")
## Where the icons are worked out and drawn (the owner's frame: ~11 ms of the main thread every frame the
## camera moved went into collect() and the canvas calls, alt-gpu). "auto" (the default): on the graphics
## card (shaders/alt_icons.gdshader) in the angled and Factorio's views, one 2D MultiMesh whose instances
## are rebuilt only when the icons change, the camera handled by the shader, so panning costs the CPU
## next to nothing; first person, the remote view's fog, --alt-cache=off, a headless run and the
## Compatibility renderer keep the CPU path. Moving wagons and a hovered beacon stay on the CPU on top.
## --alt-icons=cpu: every icon on the CPU as before; --alt-icons=gpu: the card's path even headless.
static var icons_mode := "auto"
## First person: each cell of a machine's icons sorts this much nearer the camera than the one
## before (sorting_offset), so the transparent sort puts its lower rows in front.
const QUAD_STEP := 0.001
## The inventory a row's kind shows (`eprops` isq): which of an `am` entry's two lists.
const KIND_LIST := {"m": 0, "l": 1, "a": 1, "f": 1, "c": 1}
const STOCK_KINDS := ["a", "f", "c"]
const MIN_ICON_PX := 3.0
const FLAT_BATCH_CELL := 32.0
const MAX_FLAT_BATCHES := 32
static var _args_read := false

var model
var player: Node = null
var on := false

var _shadow: Texture2D
## First person: the icons as 3D quads with the depth test on, so buildings in front hide them
## (from above, nothing stands between the camera and an icon). Pooled; a material per picture.
var _quads: Array[MeshInstance3D] = []
var _quad_holder: Node3D
var _quad_materials := {}  # Texture2D -> ShaderMaterial
var _quads_used := 0
## First person, this frame: each machine's (its icons' point across the ground) [distance its
## cells sort at, cells placed so far].
var _quad_machines := {}
## The remote view's fog (the player's remote_fog): no icons for what no radar sees (G18).
var _fog: Node = null


## Per-chunk cache of static alt-icon descriptors (rebuilt only when that chunk or its alt data changes).
class ChunkCache:
	var cv_id := 0
	var content_rev := -1
	var gh_ver := -1
	var eprops_size := -1
	var gfx_gen := -1
	var icons_ver := -1
	var use_spec := true
	var ent_anchor := PackedVector3Array()  # (c.x, flat_y + gh, c.y)
	var ent_flat_y := PackedFloat32Array()
	var ent_ref := PackedFloat32Array()
	var ent_bound := PackedFloat32Array()  # max cell reach in tiles from anchor
	var ent_cell_start := PackedInt32Array()
	var ent_cell_count := PackedInt32Array()
	var ent_hover_rec: Array = []  # WorldMirror.Rec for hover-only types (beacons), else null
	var cell_offset := PackedVector2Array()
	var cell_side := PackedFloat32Array()
	var cell_tex: Array[Texture2D] = []
	var cell_mark: Array = []  # Texture2D or null

	func clear() -> void:
		ent_anchor.clear()
		ent_flat_y.clear()
		ent_ref.clear()
		ent_bound.clear()
		ent_cell_start.clear()
		ent_cell_count.clear()
		ent_hover_rec.clear()
		cell_offset.clear()
		cell_side.clear()
		cell_tex.clear()
		cell_mark.clear()


## Cached mover unit from `alt_machines` (locomotives/wagons that move across frames).
class MovingSeq:
	var unit := 0
	var proto_id := 0
	var gfx_gen := -1
	var icons_ver := -1
	var height := 0.0
	var ref := 0.0
	var rows: Array = []  # [[PackedVector2Array offsets, PackedFloat32Array sides, Array[Texture2D], Array marks], ...]
	var lists: Array = []
	var last_pos: Variant = null
	var last_fogged := false


var _wired_world: WorldMirror = null
var _bridge_connected := false
var _bridge_alt_active := false
var _pending_aiu_units := {}  # unit -> true
var _dirty_alt_chunks := {}  # Vector2i -> true
var _alt_rev := 0
var _tex_rev := 0
var _last_gfx_gen := -1
var _last_icons_ver := -1
var _contents_dirty := true
var _machines_dirty := true
var _fluids_dirty := true

var _chunk_alt_cache := {}  # Vector2i -> ChunkCache
var _chunk_contents_cache := {}  # Vector2i -> ChunkCache
var _chunk_machines_cache := {}  # Vector2i -> ChunkCache
var _chunk_fluids_cache := {}  # Vector2i -> ChunkCache
var _moving_machines: Array[MovingSeq] = []

var _cached_ac_g := -1
var _cached_ac_bridge := -1
var _cached_ac_size := -1
var _cached_ac_gh := -1
var _cached_ac_gfx := -1
var _cached_ac_icons := -1
var _cached_ac_spec := true
var _cached_ac_eprops := -1
var _cached_ac_refs := {}  # unit -> Array ref
var _ac_missing := false

var _cached_am_g := -1
var _cached_am_bridge := -1
var _cached_am_size := -1
var _cached_am_gh := -1
var _cached_am_gfx := -1
var _cached_am_icons := -1
var _cached_am_spec := true
var _cached_am_ammo := true
var _cached_am_loco := false
var _cached_am_eprops := -1
var _cached_am_refs := {}  # unit -> Array ref
var _am_missing := false

var _cached_fl_layer: Object = null
var _cached_fl_ref: Dictionary = {}
var _cached_fl_size := -1
var _cached_fl_rebuilds := -1
var _cached_fl_gh := -1
var _cached_fl_gfx := -1
var _cached_fl_icons := -1
var _cached_fl_refs := {}  # unit -> Array ref
var _fl_missing := false
## How many times each of the three whole-map caches was rebuilt (the card's path looks at their chunks again).
var _ac_builds := 0
var _am_builds := 0
var _fl_builds := 0

## Idle state tracked in _process() to skip queue_redraw() when nothing changed.
var _was_on := false
var _idle_valid_world := false
var _idle_cam_xform := Transform3D.IDENTITY
var _idle_cam_proj := -1
var _idle_cam_size := -1.0
var _idle_cam_fov := -1.0
var _idle_vp_size := Vector2(-1.0, -1.0)
var _idle_first_person := false
var _idle_hovered: Variant = null
var _idle_world: Object = null
var _idle_alt_rev := -1
var _idle_tex_rev := -1
var _idle_gfx_gen := -1
var _idle_icons_ver := -1
var _idle_gh_ver := -1
var _idle_bridge_alt := -1
var _idle_loco_fuel := false
var _idle_chunks_size := -1
var _idle_entities_size := -1
var _idle_ac_size := -1
var _idle_ac_g := -1
var _idle_am_size := -1
var _idle_am_g := -1
var _idle_fl_layer: Object = null
var _idle_fl_size := -1
var _idle_fl_rebuilds := -1
var _idle_eprops_size := -1
var _idle_fog_key: Array = []
var _idle_flags := []
## Redraw requests issued by _process() (tests).
var redraws_queued := 0

var _in_view_chunks: Array[Vector2i] = []
var _in_view_dict := {}  # Vector2i -> bool (for uncached fallback path)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = Kit.ICON_FILTER
	# Factorio's icon shadow: a soft dark blur, darkest in the middle.
	var g := Gradient.new()
	g.set_color(0, SHADOW)
	g.set_color(1, Color(0, 0, 0, 0))
	g.add_point(0.55, Color(0, 0, 0, SHADOW.a * 0.75))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 64
	t.height = 64
	_shadow = t
	_connect_bridge()


func _exit_tree() -> void:
	if _bridge_connected and Bridge != null and Bridge.message_received.is_connected(_on_bridge_message):
		Bridge.message_received.disconnect(_on_bridge_message)
	_bridge_connected = false
	_disconnect_world()
	_gpu_free()


func _connect_bridge() -> void:
	if _bridge_connected or Bridge == null:
		return
	if not Bridge.message_received.is_connected(_on_bridge_message):
		Bridge.message_received.connect(_on_bridge_message)
	_bridge_connected = true


func _on_bridge_message(msg: Dictionary) -> void:
	var t := str(msg.get("t", ""))
	if t == "aiu":
		_bridge_alt_active = true
		var list = msg.get("l")
		if list is Array:
			for row in list:
				if row is Array and not (row as Array).is_empty():
					_pending_aiu_units[int((row as Array)[0])] = true
		_contents_dirty = true
		_alt_rev += 1
	elif t == "ac":
		_bridge_alt_active = true
		_contents_dirty = true
		_alt_rev += 1
	elif t == "am":
		_bridge_alt_active = true
		_machines_dirty = true
		_alt_rev += 1
	elif t == "fl":
		_bridge_alt_active = true
		_fluids_dirty = true
		_alt_rev += 1


func _disconnect_world() -> void:
	if is_instance_valid(_wired_world):
		if _wired_world.entities_changed.is_connected(_on_world_entities_changed):
			_wired_world.entities_changed.disconnect(_on_world_entities_changed)
		if _wired_world.alt_changed.is_connected(_on_world_alt_changed):
			_wired_world.alt_changed.disconnect(_on_world_alt_changed)
	_wired_world = null


func _sync_world(world: WorldMirror) -> void:
	if _wired_world == world:
		return
	_disconnect_world()
	_clear_caches()
	_wired_world = world
	if world != null:
		world.entities_changed.connect(_on_world_entities_changed)
		world.alt_changed.connect(_on_world_alt_changed)


func _on_world_entities_changed(c: Vector2i) -> void:
	_dirty_alt_chunks[c] = true
	if _chunk_contents_cache.has(c) or _ac_missing:
		_contents_dirty = true
	if _chunk_machines_cache.has(c) or _am_missing:
		_machines_dirty = true
	if _chunk_fluids_cache.has(c) or _fl_missing:
		_fluids_dirty = true
	_alt_rev += 1


func _on_world_alt_changed(c: Vector2i) -> void:
	_dirty_alt_chunks[c] = true
	_alt_rev += 1


func _sync_tex_version() -> void:
	var gfx_gen := ModGraphics.generation
	var icons_ver := ModelPacks.icons_version
	if gfx_gen != _last_gfx_gen or icons_ver != _last_icons_ver:
		_last_gfx_gen = gfx_gen
		_last_icons_ver = icons_ver
		_tex_rev += 1
		_contents_dirty = true
		_machines_dirty = true
		_fluids_dirty = true


func _clear_caches() -> void:
	_chunk_alt_cache.clear()
	_chunk_contents_cache.clear()
	_chunk_machines_cache.clear()
	_chunk_fluids_cache.clear()
	_moving_machines.clear()
	_dirty_alt_chunks.clear()
	_pending_aiu_units.clear()
	_contents_dirty = true
	_machines_dirty = true
	_fluids_dirty = true
	_cached_ac_refs.clear()
	_cached_am_refs.clear()
	_cached_fl_refs.clear()
	_cached_fl_layer = null
	_cached_fl_ref = {}
	_cached_ac_size = -1
	_cached_am_size = -1
	_cached_fl_size = -1
	_alt_rev += 1


static func _is_hover_only(world, hovered: Variant) -> Variant:
	if hovered == null or not (hovered is WorldMirror.Rec) or world == null:
		return null
	var r: WorldMirror.Rec = hovered
	var proto = world.protos.entity(r.proto_id)
	if proto != null and HOVER_ONLY_TYPES.has(proto.type):
		return r
	return null


static func _fog_state_key(fog: Node) -> Array:
	if fog == null or not fog.has_method("hiding") or not bool(fog.hiding()):
		return [false]
	return [true, fog.get("_origin"), fog.get("_drawn"), fog.get("_roboports_drawn"),
		fog.get("_character"), fog.get("_character_radius")]


func _process(_delta: float) -> void:
	_read_args()
	_connect_bridge()
	if not on:
		_gpu_set_live(false)
		if _was_on:
			_was_on = false
			if is_inside_tree():
				redraws_queued += 1
				queue_redraw()
		if _quads_used > 0 or (not _quads.is_empty() and _quads[0].visible):
			_quads_used = 0
			_hide_quads()
		return
	if not use_cache:
		_gpu_set_live(false)
		_was_on = true
		redraws_queued += 1
		queue_redraw()
		return
	var world = player.get("world") if player != null else null
	var rig = player.get("rig") if player != null else null
	if world is WorldMirror:
		_sync_world(world)
	if model == null or world == null or rig == null:
		_gpu_set_live(false)
		if not _was_on or _idle_valid_world:
			_was_on = true
			_idle_valid_world = false
			redraws_queued += 1
			queue_redraw()
		return
	var camera: Camera3D = rig.camera
	if camera == null:
		return
	var parent: Node = world.get_parent()
	var fluids_layer = parent.get_node_or_null("FluidsPower") if parent != null else null
	var fp := bool(rig.get("first_person"))
	var vp_size := get_viewport_rect().size if is_inside_tree() else Vector2.ZERO
	var hovered_beacon: Variant = _is_hover_only(world, player.get("hovered"))
	var fog_node: Node = player.get("remote_fog")
	var fog_key := _fog_state_key(fog_node)
	var gh_ver := GroundHeight.version()
	_sync_tex_version()
	var gfx_gen := _last_gfx_gen
	var icons_ver := _last_icons_ver
	var eprops_size: int = (model.eprops as Dictionary).size() if ("eprops" in model and model.eprops is Dictionary) else 0
	var fl_size: int = (fluids_layer.fluids as Dictionary).size() if fluids_layer != null else 0
	var fl_rebuilds: int = int(fluids_layer.window_rebuilds) if fluids_layer != null else 0
	var ac_g := int(world.get("_alt_contents_g"))
	var am_g := int(world.get("_alt_machines_g"))
	var flags := [use_spec, ammo_fuel, icon_order, layer_cap, flat_batch_marks, flat_batch_tex, use_cache, gfx_gen, icons_ver, _tex_rev]
	var gpu := _gpu_wanted(fp, fog_key)
	var switched := gpu != _gpu_live
	if switched:
		_gpu_set_live(gpu)
	if gpu:
		var t_sync := Time.get_ticks_usec()
		_gpu_camera = camera
		_gpu_sync(world, camera, fluids_layer, gh_ver, gfx_gen, icons_ver, eprops_size, [world, _alt_rev, _tex_rev,
			gh_ver, Bridge.alt_contents, Bridge.loco_fuel_icons, world.chunks.size(), world.entities.size(),
			world.alt_contents.size(), ac_g, world.alt_machines.size(), am_g, fluids_layer, fl_size, fl_rebuilds,
			eprops_size, flags])
		Probing.add("alt_sync", t_sync)
		# The camera into the shader after every script moved it this frame (deferred calls run after
		# all _process, where the CPU path's _draw ran), on the main thread whatever the thread model.
		_gpu_pre_draw.call_deferred()
	# On the card the camera is the shader's: a moved camera redraws only what stays on the CPU.
	var cpu_moves := (not gpu) or hovered_beacon != null or not _moving_machines.is_empty()
	var dirty := (not _was_on) or (not _idle_valid_world) or switched
	if not dirty:
		if fp != _idle_first_person or (cpu_moves and (camera.global_transform != _idle_cam_xform \
				or camera.projection != _idle_cam_proj or camera.size != _idle_cam_size or camera.fov != _idle_cam_fov \
				or vp_size != _idle_vp_size)):
			dirty = true
		elif hovered_beacon != _idle_hovered or fog_key != _idle_fog_key:
			dirty = true
		elif world != _idle_world or _alt_rev != _idle_alt_rev or _tex_rev != _idle_tex_rev \
				or gfx_gen != _idle_gfx_gen or icons_ver != _idle_icons_ver or gh_ver != _idle_gh_ver \
				or Bridge.alt_contents != _idle_bridge_alt or Bridge.loco_fuel_icons != _idle_loco_fuel \
				or world.chunks.size() != _idle_chunks_size or world.entities.size() != _idle_entities_size \
				or world.alt_contents.size() != _idle_ac_size or ac_g != _idle_ac_g \
				or world.alt_machines.size() != _idle_am_size or am_g != _idle_am_g \
				or fluids_layer != _idle_fl_layer or fl_size != _idle_fl_size or fl_rebuilds != _idle_fl_rebuilds \
				or eprops_size != _idle_eprops_size or flags != _idle_flags:
			dirty = true
	if not dirty and not _moving_machines.is_empty():
		var movers = player.get("movers")
		if movers != null and movers.has_method("proto_id_of"):
			for ms: MovingSeq in _moving_machines:
				var pid: int = movers.proto_id_of(ms.unit)
				var pos: Variant = movers.position_of(ms.unit) if pid > 0 else null
				var fogged: bool = movers.is_fogged(ms.unit) if pid > 0 else false
				if pid != ms.proto_id or pos != ms.last_pos or fogged != ms.last_fogged:
					dirty = true
					break
	_was_on = true
	if dirty:
		redraws_queued += 1
		queue_redraw()


func _draw() -> void:
	var t_draw := Time.get_ticks_usec()
	_draw_icons()
	Probing.add("alt_draw", t_draw)


func _draw_icons() -> void:
	collect()
	if icon_order:
		if not _layers_now:
			return
		if _flat:
			for i in _order_count:
				var idx := _order[i]
				draw_texture_rect(_shadow, _buf_shadow[idx], false)
			if flat_batch_marks and flat_batch_tex:
				for b in _flat_batches_used:
					var batch: Dictionary = _flat_batches[b]
					for tex: Texture2D in batch:
						var bucket: Array = batch[tex]
						for idx: int in bucket:
							draw_texture_rect(tex, _buf_rect[idx], false)
				for mtex: Texture2D in _flat_marks:
					var mbucket: Array = _flat_marks[mtex]
					for idx: int in mbucket:
						draw_texture_rect(mtex, _buf_mark_rect[idx], false)
			elif flat_batch_marks:
				var marks := {}  # Texture2D -> Array[int] (grouped so quality marks don't break icon batching)
				for k in _order_count:
					var i := _order[k]
					draw_texture_rect(_buf_tex[i], _buf_rect[i], false)
					_collect_mark(marks, _buf_mark[i], i)
				for mtex: Texture2D in marks:
					var bucket: Array = marks[mtex]
					for i: int in bucket:
						draw_texture_rect(mtex, _buf_mark_rect[i], false)
			else:
				for k in _order_count:  # each mark with its icon, so a farther one's stays under a nearer icon
					var i := _order[k]
					draw_texture_rect(_buf_tex[i], _buf_rect[i], false)
					if _buf_mark[i] != null:
						draw_texture_rect(_buf_mark[i], _buf_mark_rect[i], false)
			return
		for l in _layers_used:
			var layer: Array = _layers[l]
			for i in layer[0]:
				draw_texture_rect(_shadow, _buf_shadow[i], false)
			for texture in layer[1]:
				for i in layer[1][texture]:
					draw_texture_rect(texture, _buf_rect[i], false)
			for i in layer[0]:
				if _buf_mark[i] != null:
					draw_texture_rect(_buf_mark[i], _buf_mark_rect[i], false)
		return
	for rect in _shadows_direct:
		draw_texture_rect(_shadow, rect, false)
	for texture in _icons_direct:
		for rect in _icons_direct[texture]:
			draw_texture_rect(texture, rect, false)
	for texture in _marks_direct:
		for rect in _marks_direct[texture]:
			draw_texture_rect(texture, rect, false)


## Works out this frame's icons (first person: places the quads) into _shadows, _icons and _marks.
func collect() -> void:
	_read_args()
	_connect_bridge()
	_quads_used = 0
	_marks_3d = 0
	_e_count = 0
	_e_sum = 0.0
	_e_hash = 0
	_quad_machines.clear()
	_layers_now = false
	_shadows_direct.clear()
	_icons_direct.clear()
	_marks_direct.clear()
	_icons_built = false
	_marks_built = false
	drawn = 0
	if not on or model == null or player == null:
		_hide_quads()
		return
	var world = player.get("world")
	var rig = player.get("rig")
	if world == null or rig == null:
		_hide_quads()
		return
	var camera: Camera3D = rig.camera
	_in_3d = bool(rig.get("first_person"))
	_fog = player.get("remote_fog")
	var planes := camera.get_frustum()
	if not use_cache:
		_collect_uncached(world, camera, planes)
		return
	if world is WorldMirror:
		_sync_world(world)
	var vp_rect := get_viewport_rect() if is_inside_tree() else Rect2()
	var vp_w := vp_rect.size.x
	var vp_h := vp_rect.size.y
	var gh_ver := GroundHeight.version()
	_sync_tex_version()
	var gfx_gen := _last_gfx_gen
	var icons_ver := _last_icons_ver
	var eprops_size: int = (model.eprops as Dictionary).size() if ("eprops" in model and model.eprops is Dictionary) else 0
	var lift := GroundHeight.lift_range()
	_in_view_chunks.clear()
	if not _gpu_live:
		for c: Vector2i in world.chunks:
			if _chunk_in_view_lift(c, planes, lift):
				_in_view_chunks.append(c)
	_resolve_pending_aiu(world)
	_ensure_contents_cache(world, gh_ver, eprops_size, gfx_gen, icons_ver)
	_ensure_machines_cache(world, gh_ver, eprops_size, gfx_gen, icons_ver)
	var parent: Node = world.get_parent()
	var fluids_layer = parent.get_node_or_null("FluidsPower") if parent != null else null
	if fluids_layer != null:
		_ensure_fluids_cache(world, fluids_layer, gh_ver, gfx_gen, icons_ver)
	var hovered: Variant = player.get("hovered")
	var hovered_beacon: Variant = _is_hover_only(world, hovered)
	var fog_node: Node = _fog if (_fog != null and _fog.has_method("hiding") and bool(_fog.hiding())) else null
	var cam_pos := camera.global_position
	var cam_right := camera.global_basis.x
	var cam_fwd := -camera.global_basis.z
	var min_px := float(Kit.px(4))
	var max_px := float(Kit.px(40))
	if _gpu_live and hovered_beacon != null:
		# On the card everything but the hovered beacon's modules (and the movers below).
		var hb: WorldMirror.Rec = hovered_beacon
		var hb_cc: ChunkCache = _chunk_machines_cache.get(hb.chunk)
		if hb_cc != null:
			_emit_chunk_cache(world, camera, hb_cc, hovered, fog_node, cam_pos, cam_right, cam_fwd, min_px, max_px,
				vp_w, vp_h, true)
	for c: Vector2i in _in_view_chunks:
		var cv = world.chunks[c]
		var alt_cc: ChunkCache = _chunk_alt_cache.get(c)
		if _dirty_alt_chunks.has(c) or alt_cc == null or alt_cc.cv_id != cv.get_instance_id() \
				or alt_cc.content_rev != cv.content_rev or alt_cc.gh_ver != gh_ver \
				or alt_cc.gfx_gen != gfx_gen or alt_cc.icons_ver != icons_ver \
				or alt_cc.use_spec != use_spec or alt_cc.eprops_size != eprops_size:
			if alt_cc != null and alt_cc.content_rev != cv.content_rev:
				if _chunk_contents_cache.has(c) or _ac_missing:
					_contents_dirty = true
				if _chunk_machines_cache.has(c) or _am_missing:
					_machines_dirty = true
				if _chunk_fluids_cache.has(c) or _fl_missing:
					_fluids_dirty = true
				_ensure_contents_cache(world, gh_ver, eprops_size, gfx_gen, icons_ver)
				_ensure_machines_cache(world, gh_ver, eprops_size, gfx_gen, icons_ver)
				if fluids_layer != null:
					_ensure_fluids_cache(world, fluids_layer, gh_ver, gfx_gen, icons_ver)
			alt_cc = _build_chunk_alt_cache(world, c, cv, gh_ver, eprops_size, gfx_gen, icons_ver)
		if alt_cc != null:
			_emit_chunk_cache(world, camera, alt_cc, hovered, fog_node, cam_pos, cam_right, cam_fwd, min_px, max_px, vp_w, vp_h)
		var ac_cc: ChunkCache = _chunk_contents_cache.get(c)
		if ac_cc != null:
			_emit_chunk_cache(world, camera, ac_cc, hovered, fog_node, cam_pos, cam_right, cam_fwd, min_px, max_px, vp_w, vp_h)
		var am_cc: ChunkCache = _chunk_machines_cache.get(c)
		if am_cc != null:
			_emit_chunk_cache(world, camera, am_cc, hovered, fog_node, cam_pos, cam_right, cam_fwd, min_px, max_px, vp_w, vp_h)
		if fluids_layer != null:
			var fl_cc: ChunkCache = _chunk_fluids_cache.get(c)
			if fl_cc != null:
				_emit_chunk_cache(world, camera, fl_cc, hovered, fog_node, cam_pos, cam_right, cam_fwd, min_px, max_px, vp_w, vp_h)
	# Prune unloaded chunks from _chunk_alt_cache if chunks shrank.
	if _chunk_alt_cache.size() > world.chunks.size() + 16:
		for c_old in _chunk_alt_cache.keys():
			if not world.chunks.has(c_old):
				_chunk_alt_cache.erase(c_old)
	_emit_moving_machines(world, camera, planes, lift, fog_node, cam_pos, cam_right, cam_fwd, min_px, max_px, vp_w, vp_h, gfx_gen, icons_ver)
	if icon_order and not _in_3d:
		_build_layers(camera)
	drawn = _e_count + _quads_used - _marks_3d + (gpu_instances if _gpu_live else 0)
	_hide_quads()
	# Snapshot idle state after collecting so _process() can skip idle redraws.
	_was_on = true
	_idle_valid_world = true
	_idle_cam_xform = camera.global_transform
	_idle_cam_proj = camera.projection
	_idle_cam_size = camera.size
	_idle_cam_fov = camera.fov
	_idle_vp_size = vp_rect.size
	_idle_first_person = _in_3d
	_idle_hovered = hovered_beacon
	_idle_world = world
	_idle_alt_rev = _alt_rev
	_idle_tex_rev = _tex_rev
	_idle_gfx_gen = gfx_gen
	_idle_icons_ver = icons_ver
	_idle_gh_ver = gh_ver
	_idle_bridge_alt = Bridge.alt_contents
	_idle_loco_fuel = Bridge.loco_fuel_icons
	_idle_chunks_size = world.chunks.size()
	_idle_entities_size = world.entities.size()
	_idle_ac_size = world.alt_contents.size()
	_idle_ac_g = int(world.get("_alt_contents_g"))
	_idle_am_size = world.alt_machines.size()
	_idle_am_g = int(world.get("_alt_machines_g"))
	_idle_fl_layer = fluids_layer
	_idle_fl_size = (fluids_layer.fluids as Dictionary).size() if fluids_layer != null else 0
	_idle_fl_rebuilds = int(fluids_layer.window_rebuilds) if fluids_layer != null else 0
	_idle_eprops_size = eprops_size
	_idle_fog_key = _fog_state_key(_fog)
	_idle_flags = [use_spec, ammo_fuel, icon_order, layer_cap, flat_batch_marks, flat_batch_tex, use_cache, gfx_gen, icons_ver, _tex_rev]


func _collect_uncached(world, camera: Camera3D, planes: Array[Plane]) -> void:
	_in_view_dict.clear()
	for c in world.chunks:
		var cv = world.chunks[c]
		if cv.alt.is_empty():
			continue
		var vis: bool = _chunk_in_view(c, planes)
		_in_view_dict[c] = vis
		if not vis:
			continue
		for key in cv.alt:
			var r: WorldMirror.Rec = cv.alt[key]
			var icon := WorldMirror.alt_icon(r)
			if icon.is_empty():
				continue
			var textures: Array[Texture2D] = []
			for i in range(1, icon.size()):  # a filter inserter's filters, every one
				textures.append(Kit.item_icon(str(icon[i])))
			var spec := _spec_for(r)
			var tiles: float = ICON_TILES * spec[1] if not spec.is_empty() else _tiles_for(world, r)
			_draw_icon(world, camera, r, textures, tiles, spec[0] if not spec.is_empty() else Vector2.ZERO)
	_draw_contents(world, camera, planes, _in_view_dict)
	_draw_sequences(world, camera, planes, _in_view_dict)
	var parent: Node = world.get_parent()
	var fluids_layer = parent.get_node_or_null("FluidsPower") if parent != null else null
	if fluids_layer != null:
		_draw_fluids(world, camera, fluids_layer, planes, _in_view_dict)
	if icon_order and not _in_3d:
		_build_layers(camera)
	drawn = _e_count + _quads_used - _marks_3d
	_hide_quads()


func _resolve_pending_aiu(world) -> void:
	if _pending_aiu_units.is_empty():
		return
	for unit in _pending_aiu_units:
		var r: WorldMirror.Rec = world.entities.get(unit)
		if r != null:
			_dirty_alt_chunks[r.chunk] = true
	_pending_aiu_units.clear()


func _build_chunk_alt_cache(world, c: Vector2i, cv, gh_ver: int, eprops_size: int, gfx_gen: int, icons_ver: int) -> ChunkCache:
	_dirty_alt_chunks.erase(c)
	var cc: ChunkCache = _chunk_alt_cache.get(c)
	if cv.alt.is_empty():
		if cc != null:
			_chunk_alt_cache.erase(c)
		return null
	if cc == null:
		cc = ChunkCache.new()
		_chunk_alt_cache[c] = cc
	else:
		cc.clear()
	cc.cv_id = cv.get_instance_id()
	cc.content_rev = cv.content_rev
	cc.gh_ver = gh_ver
	cc.eprops_size = eprops_size
	cc.gfx_gen = gfx_gen
	cc.icons_ver = icons_ver
	cc.use_spec = use_spec
	for key in cv.alt:
		var r: WorldMirror.Rec = cv.alt[key]
		var icon := WorldMirror.alt_icon(r)
		if icon.is_empty():
			continue
		var proto = world.protos.entity(r.proto_id)
		if proto == null:
			continue
		var spec := _spec_for(r)
		var tiles: float = ICON_TILES * float(spec[1]) if not spec.is_empty() else _tiles_for(world, r)
		var shift: Vector2 = spec[0] if not spec.is_empty() else Vector2.ZERO
		var world_c := WorldMirror.selection_rect(proto, r.pos, r.dir).get_center()
		var flat_y := Visuals.height_for(proto)
		var anchor := Vector3(world_c.x, flat_y + GroundHeight.at(world_c.x, world_c.y), world_c.y)
		var start := cc.cell_tex.size()
		var count := 0
		var max_reach := 0.0
		var n_items := icon.size() - 1
		var grid_cells := grid(n_items)
		for gi in n_items:
			var tex := Kit.item_icon(str(icon[1 + gi]))
			if tex == null:
				continue
			var gc: Array = grid_cells[gi]
			var side_share := float(gc[1])
			var cell_side := side_share * tiles
			var cell_off: Vector2 = shift + ((gc[0] as Vector2) + Vector2(side_share, side_share) * 0.5 - Vector2(0.5, 0.5)) * tiles
			cc.cell_offset.append(cell_off)
			cc.cell_side.append(cell_side)
			cc.cell_tex.append(tex)
			cc.cell_mark.append(null)
			max_reach = maxf(max_reach, maxf(absf(cell_off.x), absf(cell_off.y)) + cell_side * 0.65)
			count += 1
		if count == 0:
			continue
		cc.ent_anchor.append(anchor)
		cc.ent_flat_y.append(flat_y)
		cc.ent_ref.append(tiles)
		cc.ent_bound.append(max_reach)
		cc.ent_cell_start.append(start)
		cc.ent_cell_count.append(count)
		cc.ent_hover_rec.append(null)
	return cc


func _ensure_contents_cache(world, gh_ver: int, eprops_size: int, gfx_gen: int, icons_ver: int) -> void:
	if not world.has_method("alt_contents_now"):
		_chunk_contents_cache.clear()
		return
	var contents: Dictionary = world.alt_contents_now()
	var ac_g := int(world.get("_alt_contents_g"))
	var need: bool = _contents_dirty or ac_g != _cached_ac_g or Bridge.alt_contents != _cached_ac_bridge \
		or contents.size() != _cached_ac_size or gh_ver != _cached_ac_gh \
		or gfx_gen != _cached_ac_gfx or icons_ver != _cached_ac_icons \
		or use_spec != _cached_ac_spec or eprops_size != _cached_ac_eprops
	if not need and not _bridge_alt_active and not contents.is_empty():
		for unit in contents:
			if not is_same(_cached_ac_refs.get(unit), contents[unit]):
				need = true
				break
	if not need:
		return
	_contents_dirty = false
	_ac_builds += 1
	_cached_ac_g = ac_g
	_cached_ac_bridge = Bridge.alt_contents
	_cached_ac_size = contents.size()
	_cached_ac_gh = gh_ver
	_cached_ac_gfx = gfx_gen
	_cached_ac_icons = icons_ver
	_cached_ac_spec = use_spec
	_cached_ac_eprops = eprops_size
	_chunk_contents_cache.clear()
	_cached_ac_refs.clear()
	_ac_missing = false
	if contents.is_empty():
		return
	for unit in contents:
		_cached_ac_refs[unit] = contents[unit]
		var r: WorldMirror.Rec = world.entities.get(unit)
		if r == null:
			_ac_missing = true
			continue
		if not WorldMirror.alt_icon(r).is_empty():
			continue
		var proto = world.protos.entity(r.proto_id)
		if proto == null:
			continue
		var items: Array = contents[unit]
		if items.is_empty():
			continue
		var spec := _spec_for(r)
		var tiles: float = ICON_TILES * float(spec[1]) if not spec.is_empty() else CHEST_TILES
		var shift: Vector2 = spec[0] if not spec.is_empty() else Vector2.ZERO
		var world_c := WorldMirror.selection_rect(proto, r.pos, r.dir).get_center()
		var flat_y := Visuals.height_for(proto)
		var anchor := Vector3(world_c.x, flat_y + GroundHeight.at(world_c.x, world_c.y), world_c.y)
		var cc: ChunkCache = _chunk_contents_cache.get(r.chunk)
		if cc == null:
			cc = ChunkCache.new()
			_chunk_contents_cache[r.chunk] = cc
		var start := cc.cell_tex.size()
		var count := 0
		var max_reach := 0.0
		var grid_cells := grid(items.size())
		for gi in items.size():
			var tex := Kit.item_icon(str(items[gi]))
			if tex == null:
				continue
			var gc: Array = grid_cells[gi]
			var side_share := float(gc[1])
			var cell_side := side_share * tiles
			var cell_off: Vector2 = shift + ((gc[0] as Vector2) + Vector2(side_share, side_share) * 0.5 - Vector2(0.5, 0.5)) * tiles
			cc.cell_offset.append(cell_off)
			cc.cell_side.append(cell_side)
			cc.cell_tex.append(tex)
			cc.cell_mark.append(null)
			max_reach = maxf(max_reach, maxf(absf(cell_off.x), absf(cell_off.y)) + cell_side * 0.65)
			count += 1
		if count > 0:
			cc.ent_anchor.append(anchor)
			cc.ent_flat_y.append(flat_y)
			cc.ent_ref.append(tiles)
			cc.ent_bound.append(max_reach)
			cc.ent_cell_start.append(start)
			cc.ent_cell_count.append(count)
			cc.ent_hover_rec.append(null)


func _ensure_machines_cache(world, gh_ver: int, eprops_size: int, gfx_gen: int, icons_ver: int) -> void:
	if not world.has_method("alt_machines_now"):
		_chunk_machines_cache.clear()
		_moving_machines.clear()
		return
	var shown: Dictionary = world.alt_machines_now()
	var am_g := int(world.get("_alt_machines_g"))
	var need: bool = _machines_dirty or am_g != _cached_am_g or Bridge.alt_contents != _cached_am_bridge \
		or shown.size() != _cached_am_size or gh_ver != _cached_am_gh \
		or gfx_gen != _cached_am_gfx or icons_ver != _cached_am_icons \
		or use_spec != _cached_am_spec or ammo_fuel != _cached_am_ammo \
		or Bridge.loco_fuel_icons != _cached_am_loco or eprops_size != _cached_am_eprops
	if not need and not _bridge_alt_active and not shown.is_empty():
		for unit in shown:
			if not is_same(_cached_am_refs.get(unit), shown[unit]):
				need = true
				break
	if not need:
		return
	_machines_dirty = false
	_am_builds += 1
	_cached_am_g = am_g
	_cached_am_bridge = Bridge.alt_contents
	_cached_am_size = shown.size()
	_cached_am_gh = gh_ver
	_cached_am_gfx = gfx_gen
	_cached_am_icons = icons_ver
	_cached_am_spec = use_spec
	_cached_am_ammo = ammo_fuel
	_cached_am_loco = Bridge.loco_fuel_icons
	_cached_am_eprops = eprops_size
	_chunk_machines_cache.clear()
	_moving_machines.clear()
	_cached_am_refs.clear()
	_am_missing = false
	if shown.is_empty():
		return
	var movers = player.get("movers")
	for unit in shown:
		_cached_am_refs[unit] = shown[unit]
		var r: WorldMirror.Rec = world.entities.get(unit)
		var lists: Array = shown[unit]
		if r == null:
			var ms := MovingSeq.new()
			ms.unit = int(unit)
			ms.lists = lists
			if movers != null and movers.has_method("proto_id_of"):
				_populate_moving_seq(world, movers, ms, gfx_gen, icons_ver)
			_moving_machines.append(ms)
			_am_missing = true
			continue
		var proto = world.protos.entity(r.proto_id)
		if proto == null:
			continue
		var isq = _overlay_of(r.proto_id).get("isq")
		if not (isq is Array):
			continue
		var spec := _spec_for(r)
		var ref: float = ICON_TILES * (float(spec[1]) if not spec.is_empty() else 1.0)
		var world_c := WorldMirror.selection_rect(proto, r.pos, r.dir).get_center()
		var flat_y := Visuals.height_for(proto)
		var anchor := Vector3(world_c.x, flat_y + GroundHeight.at(world_c.x, world_c.y), world_c.y)
		var hover_rec: Variant = r if HOVER_ONLY_TYPES.has(proto.type) else null
		var cc: ChunkCache = null
		for row in isq:
			if not (row is Array) or (row as Array).size() < 8:
				continue
			var kind := str(row[0])
			if not KIND_LIST.has(kind) or (STOCK_KINDS.has(kind) and not ammo_fuel) or (kind == "f" and not Bridge.loco_fuel_icons):
				continue
			var items: Array = lists[int(KIND_LIST[kind])]
			if items.is_empty():
				continue
			var cells := sequence_cells(items.size(), row)
			if cc == null:
				cc = _chunk_machines_cache.get(r.chunk)
				if cc == null:
					cc = ChunkCache.new()
					_chunk_machines_cache[r.chunk] = cc
			var start := cc.cell_tex.size()
			var count := 0
			var max_reach := 0.0
			for ci in cells.size():
				var tex := Kit.item_icon(str(items[ci][0]))
				if tex == null:
					continue
				var c_entry: Array = cells[ci]
				var cell_off: Vector2 = c_entry[0]
				var cell_side := float(c_entry[1])
				var mark: Texture2D = Slot.quality_icon(str(items[ci][1]))
				cc.cell_offset.append(cell_off)
				cc.cell_side.append(cell_side)
				cc.cell_tex.append(tex)
				cc.cell_mark.append(mark)
				max_reach = maxf(max_reach, maxf(absf(cell_off.x), absf(cell_off.y)) + cell_side * 0.65)
				count += 1
			if count > 0:
				cc.ent_anchor.append(anchor)
				cc.ent_flat_y.append(flat_y)
				cc.ent_ref.append(ref)
				cc.ent_bound.append(max_reach)
				cc.ent_cell_start.append(start)
				cc.ent_cell_count.append(count)
				cc.ent_hover_rec.append(hover_rec)


func _populate_moving_seq(world, movers, ms: MovingSeq, gfx_gen: int, icons_ver: int) -> void:
	ms.rows.clear()
	ms.proto_id = movers.proto_id_of(ms.unit)
	ms.gfx_gen = gfx_gen
	ms.icons_ver = icons_ver
	if ms.proto_id <= 0:
		return
	var proto = world.protos.entity(ms.proto_id)
	if proto == null:
		return
	var isq = _overlay_of(ms.proto_id).get("isq")
	if not (isq is Array):
		return
	ms.height = Visuals.height_for(proto)
	ms.ref = ICON_TILES
	for row in isq:
		if not (row is Array) or (row as Array).size() < 8:
			continue
		var kind := str(row[0])
		if not KIND_LIST.has(kind) or (STOCK_KINDS.has(kind) and not ammo_fuel) or (kind == "f" and not Bridge.loco_fuel_icons):
			continue
		var items: Array = ms.lists[int(KIND_LIST[kind])]
		if items.is_empty():
			continue
		var cells := sequence_cells(items.size(), row)
		var offsets := PackedVector2Array()
		var sides := PackedFloat32Array()
		var texs: Array[Texture2D] = []
		var marks: Array = []
		for ci in cells.size():
			var tex := Kit.item_icon(str(items[ci][0]))
			if tex == null:
				continue
			offsets.append(cells[ci][0] as Vector2)
			sides.append(float(cells[ci][1]))
			texs.append(tex)
			marks.append(Slot.quality_icon(str(items[ci][1])))
		if not texs.is_empty():
			ms.rows.append([offsets, sides, texs, marks])


func _ensure_fluids_cache(world, fluids_layer, gh_ver: int, gfx_gen: int, icons_ver: int) -> void:
	var fluids: Dictionary = fluids_layer.fluids
	var fl_rebuilds := int(fluids_layer.window_rebuilds)
	var need: bool = _fluids_dirty or fluids_layer != _cached_fl_layer or not is_same(_cached_fl_ref, fluids) \
		or fluids.size() != _cached_fl_size or fl_rebuilds != _cached_fl_rebuilds or gh_ver != _cached_fl_gh \
		or gfx_gen != _cached_fl_gfx or icons_ver != _cached_fl_icons
	if not need and not _bridge_alt_active and not fluids.is_empty() and fluids.size() <= 64:
		for unit in fluids:
			if not is_same(_cached_fl_refs.get(unit), fluids[unit]):
				need = true
				break
	if not need:
		return
	_fluids_dirty = false
	_fl_builds += 1
	_cached_fl_layer = fluids_layer
	_cached_fl_ref = fluids
	_cached_fl_size = fluids.size()
	_cached_fl_rebuilds = fl_rebuilds
	_cached_fl_gh = gh_ver
	_cached_fl_gfx = gfx_gen
	_cached_fl_icons = icons_ver
	_chunk_fluids_cache.clear()
	_cached_fl_refs.clear()
	_fl_missing = false
	if fluids.is_empty():
		return
	for unit in fluids:
		_cached_fl_refs[unit] = fluids[unit]
		var r: WorldMirror.Rec = world.entities.get(unit)
		if r == null:
			_fl_missing = true
			continue
		var proto = world.protos.entity(r.proto_id)
		if proto == null or not FLUID_TYPES.has(proto.type):
			continue
		if SPARSE_FLUID_TYPES.has(proto.type) and not pipe_shows_icon(Vector2i(r.pos.floor())):
			continue
		var boxes: Array = fluids[unit]
		var fluid_name := ""
		for b in boxes:
			var f := str(b.get("fluid", ""))
			if f != "" and float(b.get("amount", 0.0)) > 0.0:
				fluid_name = f
				break
		if fluid_name == "":
			continue
		var tex := Kit.item_icon(fluid_name)
		if tex == null:
			continue
		var world_c := WorldMirror.selection_rect(proto, r.pos, r.dir).get_center()
		var flat_y := Visuals.height_for(proto)
		var anchor := Vector3(world_c.x, flat_y + GroundHeight.at(world_c.x, world_c.y), world_c.y)
		var cc: ChunkCache = _chunk_fluids_cache.get(r.chunk)
		if cc == null:
			cc = ChunkCache.new()
			_chunk_fluids_cache[r.chunk] = cc
		var start := cc.cell_tex.size()
		cc.cell_offset.append(Vector2.ZERO)
		cc.cell_side.append(FLUID_TILES)
		cc.cell_tex.append(tex)
		cc.cell_mark.append(null)
		cc.ent_anchor.append(anchor)
		cc.ent_flat_y.append(flat_y)
		cc.ent_ref.append(FLUID_TILES)
		cc.ent_bound.append(FLUID_TILES * 0.65)
		cc.ent_cell_start.append(start)
		cc.ent_cell_count.append(1)
		cc.ent_hover_rec.append(null)


func _emit_chunk_cache(world, camera: Camera3D, cc: ChunkCache, hovered: Variant, fog_node: Node,
		cam_pos: Vector3, cam_right: Vector3, cam_fwd: Vector3,
		min_px: float, max_px: float, vp_w: float, vp_h: float, hover_only := false) -> void:
	var n_ent := cc.ent_anchor.size()
	if _in_3d:
		for ei in n_ent:
			var hrec: Variant = cc.ent_hover_rec[ei]
			if hrec != null and hovered != hrec:
				continue
			var at := cc.ent_anchor[ei]
			if fog_node != null and not fog_node.seen(Vector2(at.x, at.z)):
				continue
			var start := cc.ent_cell_start[ei]
			var count := cc.ent_cell_count[ei]
			var top := Vector3(at.x, cc.ent_flat_y[ei] + cc.ent_ref[ei] * 0.5, at.z)
			_place_quads_cached(world, camera, top, cc, start, count)
		return
	var cull_vp := vp_w > 0.0 and vp_h > 0.0
	for ei in n_ent:
		var hrec: Variant = cc.ent_hover_rec[ei]
		if hrec != null and hovered != hrec:
			continue
		if hover_only and hrec == null:
			continue
		var at := cc.ent_anchor[ei]
		if fog_node != null and not fog_node.seen(Vector2(at.x, at.z)):
			continue
		if camera.is_position_behind(at):
			continue
		var ref := cc.ent_ref[ei]
		var p := camera.unproject_position(at)
		var edge := camera.unproject_position(at + cam_right * ref * 0.5)
		var half := clampf(p.distance_to(edge), min_px, max_px)
		var per_tile := half * 2.0 / ref
		if cull_vp:
			var ent_pad := cc.ent_bound[ei] * per_tile
			if p.x + ent_pad < 0.0 or p.x - ent_pad > vp_w or p.y + ent_pad < 0.0 or p.y - ent_pad > vp_h:
				continue
		var depth := cam_fwd.dot(at - cam_pos)
		var key := _order_key(cam_fwd, at)
		var start := cc.ent_cell_start[ei]
		var count := cc.ent_cell_count[ei]
		for ci in range(start, start + count):
			var side := cc.cell_side[ci] * per_tile
			if side < MIN_ICON_PX:
				continue
			var mid := p + cc.cell_offset[ci] * per_tile
			var s := side * 0.65
			if cull_vp and (mid.x + s < 0.0 or mid.x - s > vp_w or mid.y + s < 0.0 or mid.y - s > vp_h):
				continue
			_push_icon(depth, mid, side, s, cc.cell_tex[ci], cc.cell_mark[ci], key)


func _emit_moving_machines(world, camera: Camera3D, planes: Array[Plane], lift: Vector2, fog_node: Node,
		cam_pos: Vector3, cam_right: Vector3, cam_fwd: Vector3,
		min_px: float, max_px: float, vp_w: float, vp_h: float, gfx_gen: int, icons_ver: int) -> void:
	if _moving_machines.is_empty():
		return
	var movers = player.get("movers")
	if movers == null or not movers.has_method("proto_id_of"):
		return
	var cull_vp := (not _in_3d) and vp_w > 0.0 and vp_h > 0.0
	for ms: MovingSeq in _moving_machines:
		var pid: int = movers.proto_id_of(ms.unit)
		if pid != ms.proto_id or ms.gfx_gen != gfx_gen or ms.icons_ver != icons_ver:
			_populate_moving_seq(world, movers, ms, gfx_gen, icons_ver)
		if ms.proto_id <= 0:
			ms.last_pos = null
			ms.last_fogged = false
			continue
		var moving: Variant = movers.position_of(ms.unit)
		var fogged: bool = movers.is_fogged(ms.unit)
		ms.last_pos = moving
		ms.last_fogged = fogged
		if not (moving is Vector3) or fogged or ms.rows.is_empty():
			continue
		var pos3: Vector3 = moving
		var chunk := Vector2i(floori(pos3.x / 32.0), floori(pos3.z / 32.0))
		if not _chunk_in_view_lift(chunk, planes, lift):
			continue
		if fog_node != null and not fog_node.seen(Vector2(pos3.x, pos3.z)):
			continue
		var at := Vector3(pos3.x, pos3.y + ms.height, pos3.z)
		if _in_3d:
			for row_data: Array in ms.rows:
				_place_quads_raw(world, camera, at + Vector3(0.0, ms.ref * 0.5, 0.0),
					row_data[0], row_data[1], row_data[2], row_data[3])
			continue
		at.y += GroundHeight.at(at.x, at.z)
		if camera.is_position_behind(at):
			continue
		var p := camera.unproject_position(at)
		var edge := camera.unproject_position(at + cam_right * ms.ref * 0.5)
		var half := clampf(p.distance_to(edge), min_px, max_px)
		var per_tile := half * 2.0 / ms.ref
		var depth := cam_fwd.dot(at - cam_pos)
		var key := _order_key(cam_fwd, at)
		for row_data: Array in ms.rows:
			var offsets: PackedVector2Array = row_data[0]
			var sides: PackedFloat32Array = row_data[1]
			var texs: Array[Texture2D] = row_data[2]
			var marks: Array = row_data[3]
			for ci in texs.size():
				var side := sides[ci] * per_tile
				if side < MIN_ICON_PX:
					continue
				var mid := p + offsets[ci] * per_tile
				var s := side * 0.65
				if cull_vp and (mid.x + s < 0.0 or mid.x - s > vp_w or mid.y + s < 0.0 or mid.y - s > vp_h):
					continue
				_push_icon(depth, mid, side, s, texs[ci], marks[ci], key)


## The sort key of an icon at `at` (stable_order): its depth along the view from the world's origin,
## worked out in 64-bit floats from the components, so it doesn't change as the camera only moves.
static func _order_key(fwd: Vector3, at: Vector3) -> float:
	var fx: float = fwd.x
	var fy: float = fwd.y
	var fz: float = fwd.z
	var ax: float = at.x
	var ay: float = at.y
	var az: float = at.z
	return fx * ax + fy * ay + fz * az


func _push_icon(depth: float, mid: Vector2, side: float, s: float, tex: Texture2D, mark: Variant, key := NAN) -> void:
	var shadow_rect := Rect2(mid - Vector2(s, s), Vector2(s, s) * 2.0)
	var rect := Rect2(mid - Vector2(side, side) * 0.5, Vector2(side, side))
	var mark_tex: Texture2D = mark if mark is Texture2D else null
	var mark_rect := Rect2()
	if mark_tex != null:
		var qs := side * QUALITY_SHARE
		mark_rect = Rect2(mid + Vector2(-side * 0.5, side * 0.5 - qs), Vector2(qs, qs))
	if not icon_order:
		_shadows_direct.append(shadow_rect)
		var rects: Array = _icons_direct.get(tex, [])
		if rects.is_empty():
			_icons_direct[tex] = rects
		rects.append(rect)
		if mark_tex != null:
			var mrects: Array = _marks_direct.get(mark_tex, [])
			if mrects.is_empty():
				_marks_direct[mark_tex] = mrects
			mrects.append(mark_rect)
	var idx := _e_count
	if idx >= _e_cap:
		_e_cap = maxi(256, _e_cap * 2)
		_buf_depth.resize(_e_cap)
		_buf_key.resize(_e_cap)
		_buf_shadow.resize(_e_cap)
		_buf_rect.resize(_e_cap)
		_buf_tex.resize(_e_cap)
		_buf_mark.resize(_e_cap)
		_buf_mark_rect.resize(_e_cap)
	_buf_depth[idx] = depth
	_buf_key[idx] = key if stable_order and not is_nan(key) else NAN
	_buf_shadow[idx] = shadow_rect
	_buf_rect[idx] = rect
	_buf_tex[idx] = tex
	_buf_mark[idx] = mark_tex
	_buf_mark_rect[idx] = mark_rect
	_e_count = idx + 1
	_e_sum += (rect.position.x + rect.position.y * 1.618 + rect.size.x * 2.414 + depth * 3.1416
		) * (1.0 + _e_count * 0.0001)
	_e_hash = _e_hash * 1000003 ^ tex.get_instance_id()
	_e_hash = _e_hash * 1000003 ^ (0 if mark_tex == null else mark_tex.get_instance_id())


static func _read_args() -> void:
	if _args_read:
		return
	_args_read = true
	use_spec = Switches.on("--alt-icon-spec")
	ammo_fuel = Switches.on("--alt-ammo-fuel")
	icon_order = not Switches.has("--alt-icon-order=old")
	flat_batch_marks = Switches.on("--alt-flat-batch")
	use_cache = Switches.on("--alt-cache")
	flat_batch_tex = Switches.on("--alt-flat-batch-tex")
	stable_order = not Switches.has("--alt-depth-order=old")
	for a in Switches.args():
		if a.begins_with("--alt-icons="):
			icons_mode = a.get_slice("=", 1)


## [shift (tiles from the centre, right and down), scale] of the entity's own icon from its
## prototype's icon_draw_specification (`eprops` ids), or [] when the bridge sent none (the default,
## or a bridge from before K1).
func _spec_for(r: WorldMirror.Rec) -> Array:
	if not use_spec or model == null:
		return []
	var ids = (_overlay_of(r.proto_id)).get("ids")
	if not (ids is Array) or ids.size() < 3:
		return []
	return [Vector2(float(ids[0]), float(ids[1])), maxf(float(ids[2]), 0.05)]


func _overlay_of(proto_id: int) -> Dictionary:
	var ep = model.eprops.get(proto_id)
	if not (ep is Dictionary):
		return {}
	var x = ep.get("x")
	return x if x is Dictionary else {}


## Whether a chunk's box (the ground up to 8 tiles) is at least partly inside the camera's frustum.
static func _chunk_in_view(c: Vector2i, planes: Array[Plane]) -> bool:
	# An add-on's hills (ground_height.gd) lift the icons with the buildings under them, by no more
	# than the field's range.
	return _chunk_in_view_lift(c, planes, GroundHeight.lift_range())


static func _chunk_in_view_lift(c: Vector2i, planes: Array[Plane], lift: Vector2) -> bool:
	var lo := Vector3(c.x * 32.0, -1.0 + lift.x, c.y * 32.0)
	var hi := lo + Vector3(32.0, 9.0 + lift.y - lift.x, 32.0)
	for plane in planes:
		# The box's corner furthest into the frustum (against the plane's outward normal).
		var n := plane.normal
		var p := Vector3(lo.x if n.x > 0.0 else hi.x, lo.y if n.y > 0.0 else hi.y, lo.z if n.z > 0.0 else hi.z)
		if plane.distance_to(p) > 0.0:
			return false
	return true


## A chest's icons are smaller than a machine's (CHEST_TILES).
static func _tiles_for(world, r: WorldMirror.Rec) -> float:
	var proto = world.protos.entity(r.proto_id)
	return CHEST_TILES if proto != null and CHEST_TYPES.has(proto.type) else ICON_TILES


## The chests' contents (J6) over those in view without an icon of their own (a requester's requests
## and a storage chest's filter come first, as in Factorio).
func _draw_contents(world, camera: Camera3D, planes: Array[Plane], in_view: Dictionary = {}) -> void:
	if not world.has_method("alt_contents_now"):
		return
	var contents: Dictionary = world.alt_contents_now()
	if contents.is_empty():
		return
	for unit in contents:
		var r: WorldMirror.Rec = world.entities.get(unit)
		if r == null or not WorldMirror.alt_icon(r).is_empty():
			continue
		if not in_view.has(r.chunk):
			in_view[r.chunk] = _chunk_in_view(r.chunk, planes)
		if not bool(in_view[r.chunk]):
			continue
		var textures: Array[Texture2D] = []
		for item in contents[unit]:
			textures.append(Kit.item_icon(str(item)))
		var spec := _spec_for(r)
		_draw_icon(world, camera, r, textures, ICON_TILES * spec[1] if not spec.is_empty() else CHEST_TILES,
			spec[0] if not spec.is_empty() else Vector2.ZERO)


## The modules in machines, the science packs in labs (K1, K2), the ammo in ammo turrets and the
## fuel in locomotives, in rows laid out by their prototype's icons_positioning (`eprops` isq); a
## beacon's only while the mouse is on it. A locomotive is a mover, not a record: its icons are
## drawn where it is drawn now.
func _draw_sequences(world, camera: Camera3D, planes: Array[Plane], in_view: Dictionary = {}) -> void:
	if not world.has_method("alt_machines_now"):
		return
	var shown: Dictionary = world.alt_machines_now()
	if shown.is_empty():
		return
	var hovered = player.get("hovered")
	var movers = player.get("movers")
	for unit in shown:
		var r: WorldMirror.Rec = world.entities.get(unit)
		var proto_id := 0
		var chunk := Vector2i.ZERO
		var moving = null  # a mover's place as drawn (Vector3)
		if r != null:
			proto_id = r.proto_id
			chunk = r.chunk
		elif movers != null and movers.has_method("proto_id_of"):
			proto_id = movers.proto_id_of(unit)
			moving = movers.position_of(unit) if proto_id > 0 else null
			if not (moving is Vector3) or movers.is_fogged(unit):
				continue
			chunk = Vector2i(floori(moving.x / 32.0), floori(moving.z / 32.0))
		else:
			continue
		var proto = world.protos.entity(proto_id)
		if proto == null or (HOVER_ONLY_TYPES.has(proto.type) and hovered != r):
			continue
		var isq = _overlay_of(proto_id).get("isq")
		if not (isq is Array):
			continue
		if not in_view.has(chunk):
			in_view[chunk] = _chunk_in_view(chunk, planes)
		if not bool(in_view[chunk]):
			continue
		var lists: Array = shown[unit]
		var spec := _spec_for(r) if r != null else []
		var ref: float = ICON_TILES * (spec[1] if not spec.is_empty() else 1.0)
		for row in isq:
			if not (row is Array) or row.size() < 8:
				continue
			var kind := str(row[0])
			if not KIND_LIST.has(kind) or (STOCK_KINDS.has(kind) and not ammo_fuel) or (kind == "f" and not Bridge.loco_fuel_icons):
				continue
			var items: Array = lists[int(KIND_LIST[kind])]
			if items.is_empty():
				continue
			var cells := sequence_cells(items.size(), row)
			var textures: Array[Texture2D] = []
			var qualities: Array[String] = []
			for i in cells.size():
				textures.append(Kit.item_icon(str(items[i][0])))
				qualities.append(str(items[i][1]))
			if r != null:
				_draw_cells(world, camera, r, textures, cells, ref, qualities)
			else:
				var at: Vector3 = moving
				_draw_cells_at(world, camera, Vector2(at.x, at.z), at.y + Visuals.height_for(proto), textures, cells, ref, qualities)


## Where Factorio's IconSequencePositioning `row` ([kind, shift x, shift y, scale, icons a row, rows,
## separation, first row's lift], `eprops` isq) puts `n` icons: [[centre (tiles from the entity's
## centre, right and down), side (tiles)], ...], at most a row's icons times its rows. Rows of up to
## `icons a row` from the top, each centred on the shift, one `scale x separation` apart both ways; a
## last row not full is centred; with several rows the first is lifted by `first row's lift` per row
## after it (the docs give the parameters, not the rule: rebuilt from 2.1's numbers, its labs and
## beacons, not measured on Factorio's screen).
static func sequence_cells(n: int, row: Array) -> Array:
	var shift := Vector2(float(row[1]), float(row[2]))
	var scale := float(row[3])
	var per_row := maxi(1, int(row[4]))
	var rows_max := maxi(1, int(row[5]))
	var step := scale * float(row[6]) * SEQUENCE_TILE
	n = mini(n, per_row * rows_max)
	var rows := ceili(float(n) / per_row)
	var top := shift.y + float(row[7]) * (rows - 1)
	var out := []
	for i in n:
		var r := i / per_row
		var in_row := mini(per_row, n - r * per_row)
		var col := i % per_row
		out.append([Vector2(shift.x + (col - (in_row - 1) * 0.5) * step, top + r * step), scale * SEQUENCE_TILE])
	return out


func _draw_fluids(world, camera: Camera3D, fluids_layer, planes: Array[Plane] = [], in_view: Dictionary = {}) -> void:
	var frustum := camera.get_frustum() if planes.is_empty() else planes
	for unit in fluids_layer.fluids:
		var r: WorldMirror.Rec = world.entities.get(unit)
		if r == null:
			continue
		if not in_view.has(r.chunk):
			in_view[r.chunk] = _chunk_in_view(r.chunk, frustum)
		if not bool(in_view[r.chunk]):
			continue
		var proto = world.protos.entity(r.proto_id)
		if proto == null or not FLUID_TYPES.has(proto.type):
			continue
		if SPARSE_FLUID_TYPES.has(proto.type) and not pipe_shows_icon(Vector2i(r.pos.floor())):
			continue
		var boxes: Array = fluids_layer.fluids[unit]
		for b in boxes:
			var fluid := str(b.get("fluid", ""))
			if fluid != "" and float(b.get("amount", 0.0)) > 0.0:
				_draw_icon(world, camera, r, [Kit.item_icon(fluid)], FLUID_TILES)
				break


## Whether a plain pipe on this tile shows its fluid. Decided by the tile alone, so an icon never
## moves when pipes are built or mined beside it; x + 2y puts one in every PIPE_ICON_EVERY tiles of
## a straight run either way, and a staircase of pipes crosses it too (x + y would miss some).
static func pipe_shows_icon(tile: Vector2i) -> bool:
	return posmod(tile.x + 2 * tile.y, PIPE_ICON_EVERY) == 0


## Cells of a grid for `n` icons in a square of side 1 (top-left corners and the cell's side), as
## Factorio fits a filter inserter's filters into the one icon's room: 2 side by side, 3 and 4 in a
## 2 x 2 square, 5 in 3 + 2; a last row that isn't full is centred.
static func grid(n: int) -> Array:
	var cols := ceili(sqrt(float(n)))
	var rows := ceili(float(n) / cols)
	var cell := 1.0 / maxi(cols, rows)
	var top := (1.0 - rows * cell) * 0.5
	var out := []
	for i in n:
		var row := i / cols
		var in_row := mini(cols, n - row * cols)
		var left := (1.0 - in_row * cell) * 0.5
		out.append([Vector2(left + (i % cols) * cell, top + row * cell), cell])
	return out


## The icons in the one icon's square of side `tiles` (grid: a filter inserter's filters, a chest's
## kinds), centred `shift` tiles from the entity's centre (its icon_draw_specification).
func _draw_icon(world, camera: Camera3D, r: WorldMirror.Rec, textures: Array[Texture2D], tiles: float, shift := Vector2.ZERO) -> void:
	if r == null or textures.is_empty():
		return
	var cells := []
	for c in grid(textures.size()):
		var side: float = float(c[1])
		cells.append([shift + ((c[0] as Vector2) + Vector2(side, side) * 0.5 - Vector2(0.5, 0.5)) * tiles, side * tiles])
	_draw_cells(world, camera, r, textures, cells, tiles)


## Draws `textures` at `cells` ([[centre (tiles from the entity's icon point, right and down on the
## screen), side (tiles)], ...]), with `qualities`' marks where not normal. `ref` is the size of the
## entity's own icon: its size on screen is held between 8 and 80 pixels, and every cell scales with it.
func _draw_cells(world, camera: Camera3D, r: WorldMirror.Rec, textures: Array[Texture2D], cells: Array, ref: float,
		qualities: Array[String] = []) -> void:
	if r == null or textures.is_empty():
		return
	var proto = world.protos.entity(r.proto_id)
	if proto == null:
		return
	_draw_cells_at(world, camera, WorldMirror.selection_rect(proto, r.pos, r.dir).get_center(), Visuals.height_for(proto),
		textures, cells, ref, qualities)


## The same over the point `c` (tiles) at `height` over the ground: a record's selection box's
## middle at its model's height, or a mover's place now.
func _draw_cells_at(world, camera: Camera3D, c: Vector2, height: float, textures: Array[Texture2D], cells: Array, ref: float,
		qualities: Array[String] = []) -> void:
	if textures.is_empty():
		return
	if _fog != null and not _fog.seen(c):
		return
	var at := Vector3(c.x, height, c.y)
	if _in_3d:
		# Lifted onto the hills by the quads' shader.
		_place_quads(world, camera, at + Vector3(0, ref * 0.5, 0), textures, cells, qualities)
		return
	# Over the building where an add-on's hills put it, not on the flat ground under the hill.
	at.y += GroundHeight.at(at.x, at.z)
	if camera.is_position_behind(at):
		return
	var p := camera.unproject_position(at)
	var edge := camera.unproject_position(at + camera.global_basis.x * ref * 0.5)
	var half := clampf(p.distance_to(edge), Kit.px(4), Kit.px(40))
	var per_tile := half * 2.0 / ref
	# How far ahead of the camera, along its view: which icon is in front where they overlap.
	var depth := -camera.global_basis.z.dot(at - camera.global_position)
	var key := _order_key(-camera.global_basis.z, at)
	for i in mini(textures.size(), cells.size()):
		if textures[i] == null:
			continue
		var side: float = float(cells[i][1]) * per_tile
		var mid: Vector2 = p + (cells[i][0] as Vector2) * per_tile
		var s := side * 0.65
		var mark: Texture2D = Slot.quality_icon(qualities[i]) if i < qualities.size() else null
		_push_icon(depth, mid, side, s, textures[i], mark, key)


var _in_3d := false
## This frame's icons one by one, in the order found: their depth ahead of the camera, shadow's and
## icon's rectangles, picture, quality mark (or null) and its rectangle.
var _e_count := 0
var _e_cap := 0
var _buf_depth := PackedFloat32Array()
## Each icon's stable sort key (_order_key), NAN where it has none or with --alt-depth-order=old.
var _buf_key := PackedFloat64Array()
var _buf_shadow: Array[Rect2] = []
var _buf_rect: Array[Rect2] = []
var _buf_tex: Array[Texture2D] = []
var _buf_mark: Array = []
var _buf_mark_rect: Array[Rect2] = []
var _e_depth: PackedFloat32Array:
	get: return _buf_depth.slice(0, _e_count)
var _e_shadow: Array[Rect2]:
	get: return _buf_shadow.slice(0, _e_count)
var _e_rect: Array[Rect2]:
	get: return _buf_rect.slice(0, _e_count)
var _e_tex: Array[Texture2D]:
	get: return _buf_tex.slice(0, _e_count)
var _e_mark: Array:
	get: return _buf_mark.slice(0, _e_count)
var _e_mark_rect: Array[Rect2]:
	get: return _buf_mark_rect.slice(0, _e_count)
var _e_sum := 0.0
## The list's pictures and marks, by their whole ids (wrapping 64-bit).
var _e_hash := 0
## The layers drawn in turn (icon_order): [entries (indices into the _e_ arrays, in sorted order),
## {Texture2D: [entry, ...]}]. No icon overlaps another of its layer. Over layer_cap icons one list
## of every entry, farthest first (`_flat`).
var _layers: Array = []
var _layers_used := 0
## Whether the layers are this frame's (collect made them, or kept last frame's).
var _layers_now := false
var _flat := false
## The screen's grid for finding overlaps, cells this many pixels square (at UI scale 1).
const LAYER_CELL := 64
## Over this many icons in view (Factorio's view zoomed out over a big base) they are drawn farthest
## first without layers: the shadows all first, then icons grouped by texture within overlap-safe
## batches (`_flat_batches`), then quality marks grouped by texture (`_flat_marks`).
static var layer_cap := 600
## What last frame's layers were made for: the camera, the viewport and the list's fingerprint.
var _layers_key := []
## Reused between frames.
var _keys := PackedInt64Array()
var _order := PackedInt32Array()
var _order_count := 0
var _layer_of := PackedInt32Array()
var _grid := {}  # int (cell) -> [entry, ...]
var _grid_used: Array[int] = []

## Reused _flat batching state.
const FLAT_MAX_BATCH_TEX := 62
var _flat_batches: Array = []  # Array[Dictionary[Texture2D -> Array[int]]]
var _flat_batches_used := 0
var _flat_marks := {}  # Texture2D -> Array[int]
var _flat_bucket_pool: Array = []
var _fb_tex_ids := {}  # Texture2D -> int
var _fb_tex_list: Array = []
var _fb_buckets: Array = []
var _fb_reach := PackedInt64Array()
var _fb_prev := PackedInt64Array()
var _fb_tex_count := 0
var _fb_grid_head := PackedInt32Array()
var _fb_grid_stamp := PackedInt32Array()
var _fb_stamp := 1
var _fb_node_i := PackedInt32Array()
var _fb_node_tid := PackedInt32Array()
var _fb_node_next := PackedInt32Array()
var _fb_node_cap := 0
var _fb_nodes_used := 0


func _acquire_bucket() -> Array:
	if not _flat_bucket_pool.is_empty():
		var b: Array = _flat_bucket_pool.pop_back()
		b.clear()
		return b
	return []


func _release_dict_buckets(d: Dictionary) -> void:
	for k in d:
		var b: Array = d[k]
		b.clear()
		_flat_bucket_pool.append(b)
	d.clear()


## Sorts this frame's icons farthest first (a machine's own cells, at one depth, in their order: its
## lower rows after the upper, as Factorio lays its rows down the picture) and puts each in the first
## layer after every icon sorted before it that it overlaps (its shadow's square is its footprint).
## Kept as they are while the camera, the viewport and the icons stay the same.
func _build_layers(camera: Camera3D) -> void:
	var n := _e_count
	var vp_size := get_viewport_rect().size if is_inside_tree() else Vector2.ZERO
	var key := [camera.global_transform, camera.projection, camera.size, camera.fov, vp_size, n, _e_sum, _e_hash,
		flat_batch_marks, flat_batch_tex]
	_layers_now = true
	if key == _layers_key:
		return
	_layers_key = key
	_layers_used = 0
	_flat = false
	_order_count = n
	if n == 0:
		_flat_batches_used = 0
		_release_dict_buckets(_flat_marks)
		return
	_keys.resize(n)
	for i in n:
		var kd: float = _buf_key[i]
		if is_nan(kd):
			kd = _buf_depth[i]
		var q := clampi(floori(kd * 256.0), -(1 << 30), 1 << 30)
		_keys[i] = (((1 << 30) - q) << 21) | i
	_keys.sort()
	if _order.size() < n:
		_order.resize(n)
	for k in n:
		_order[k] = int(_keys[k] & ((1 << 21) - 1))
	if n > layer_cap:
		_flat = true
		if flat_batch_marks and flat_batch_tex:
			_build_flat_batches(vp_size)
		return
	for g in _grid_used:
		(_grid[g] as Array).clear()
	_grid_used.clear()
	var cell := float(maxi(Kit.px(LAYER_CELL), 1))
	if _layer_of.size() < n:
		_layer_of.resize(n)
	for k in _order_count:
		var i := _order[k]
		var fp: Rect2 = _buf_shadow[i]
		var x0 := floori(fp.position.x / cell)
		var x1 := floori(fp.end.x / cell)
		var y0 := floori(fp.position.y / cell)
		var y1 := floori(fp.end.y / cell)
		var layer := 0
		for gx in range(x0, x1 + 1):
			for gy in range(y0, y1 + 1):
				var g := (gx << 20) + gy
				var list = _grid.get(g)
				if list == null:
					list = []
					_grid[g] = list
				if (list as Array).is_empty():
					_grid_used.append(g)
				for j in list:
					if _layer_of[j] >= layer and _buf_shadow[j].intersects(fp):
						layer = _layer_of[j] + 1
				list.append(i)
		_layer_of[i] = layer
		while _layers_used <= layer:
			if _layers_used == _layers.size():
				_layers.append([[], {}])
			var fresh: Array = _layers[_layers_used]
			(fresh[0] as Array).clear()
			(fresh[1] as Dictionary).clear()
			_layers_used += 1
		var into: Array = _layers[layer]
		(into[0] as Array).append(i)
		var by_tex: Dictionary = into[1]
		var same: Array = by_tex.get(_buf_tex[i], [])
		if same.is_empty():
			by_tex[_buf_tex[i]] = same
		same.append(i)


func _flush_flat_batch(batch_dict: Dictionary) -> void:
	var rem := (1 << _fb_tex_count) - 1
	while rem != 0:
		var picked := -1
		for t in _fb_tex_count:
			var bit := 1 << t
			if (rem & bit) != 0 and (_fb_prev[t] & rem) == 0:
				picked = t
				break
		if picked < 0:
			break
		batch_dict[_fb_tex_list[picked] as Texture2D] = _fb_buckets[picked]
		_fb_buckets[picked] = null
		_fb_tex_list[picked] = null
		rem &= ~(1 << picked)
	_fb_tex_count = 0
	_fb_tex_ids.clear()


## Groups `_order` into texture-batched runs using a per-batch texture dependency DAG so textures
## are emitted in valid topological occlusion order (`wrong == 0`) with minimal batch splits.
func _build_flat_batches(vp_size: Vector2) -> void:
	for b in _flat_batches_used:
		_release_dict_buckets(_flat_batches[b] as Dictionary)
	_flat_batches_used = 1
	if _flat_batches.is_empty():
		_flat_batches.append({})
	_release_dict_buckets(_flat_marks)
	if _fb_reach.size() < FLAT_MAX_BATCH_TEX:
		_fb_tex_list.resize(FLAT_MAX_BATCH_TEX)
		_fb_buckets.resize(FLAT_MAX_BATCH_TEX)
		_fb_reach.resize(FLAT_MAX_BATCH_TEX)
		_fb_prev.resize(FLAT_MAX_BATCH_TEX)
	var vp_w := vp_size.x if vp_size.x > 0.0 else 1152.0
	var vp_h := vp_size.y if vp_size.y > 0.0 else 648.0
	var cols := clampi(ceili(vp_w / FLAT_BATCH_CELL), 1, 256)
	var rows := clampi(ceili(vp_h / FLAT_BATCH_CELL), 1, 256)
	var grid_cells := cols * rows
	if _fb_grid_stamp.size() != grid_cells:
		_fb_grid_head.resize(grid_cells)
		_fb_grid_stamp.resize(grid_cells)
		_fb_grid_stamp.fill(0)
		_fb_stamp = 1
	else:
		_fb_stamp += 1
		if _fb_stamp > 1000000000:
			_fb_grid_stamp.fill(0)
			_fb_stamp = 1
	_fb_nodes_used = 0
	_fb_tex_count = 0
	_fb_tex_ids.clear()
	for k in _order_count:
		var i := _order[k]
		var mtex: Variant = _buf_mark[i]
		if mtex != null:
			var m_key: Texture2D = mtex
			var mbucket = _flat_marks.get(m_key)
			if mbucket == null:
				mbucket = _acquire_bucket()
				_flat_marks[m_key] = mbucket
			(mbucket as Array).append(i)
		var tex: Texture2D = _buf_tex[i]
		var tid: int = _fb_tex_ids.get(tex, -1)
		var fp: Rect2 = _buf_rect[i]
		var x0 := clampi(floori(fp.position.x / FLAT_BATCH_CELL), 0, cols - 1)
		var x1 := clampi(floori(fp.end.x / FLAT_BATCH_CELL), 0, cols - 1)
		var y0 := clampi(floori(fp.position.y / FLAT_BATCH_CELL), 0, rows - 1)
		var y1 := clampi(floori(fp.end.y / FLAT_BATCH_CELL), 0, rows - 1)
		var deps := 0
		if _fb_tex_count > 0:
			for gy in range(y0, y1 + 1):
				var row_off := gy * cols
				for gx in range(x0, x1 + 1):
					var cell := row_off + gx
					if _fb_grid_stamp[cell] != _fb_stamp:
						continue
					var node := _fb_grid_head[cell]
					while node >= 0:
						var j_tid := _fb_node_tid[node]
						if j_tid != tid and (deps & (1 << j_tid)) == 0:
							var j := _fb_node_i[node]
							if _buf_rect[j].intersects(fp):
								deps |= 1 << j_tid
						node = _fb_node_next[node]
		var need_flush := (tid >= 0 and (deps & _fb_reach[tid]) != 0) or (tid < 0 and _fb_tex_count >= FLAT_MAX_BATCH_TEX)
		if need_flush:
			_flush_flat_batch(_flat_batches[_flat_batches_used - 1] as Dictionary)
			var b_idx := _flat_batches_used
			_flat_batches_used += 1
			if b_idx >= _flat_batches.size():
				_flat_batches.append({})
			_fb_stamp += 1
			if _fb_stamp > 1000000000:
				_fb_grid_stamp.fill(0)
				_fb_stamp = 1
			_fb_nodes_used = 0
			tid = -1
			deps = 0
		if tid < 0:
			tid = _fb_tex_count
			_fb_tex_count += 1
			_fb_tex_ids[tex] = tid
			_fb_tex_list[tid] = tex
			_fb_buckets[tid] = _acquire_bucket()
			_fb_reach[tid] = 0
			_fb_prev[tid] = 0
		(_fb_buckets[tid] as Array).append(i)
		if deps != 0 and (deps & ~_fb_prev[tid]) != 0:
			var anc := deps
			for u in _fb_tex_count:
				if (deps & (1 << u)) != 0:
					anc |= _fb_prev[u]
			var desc := (1 << tid) | _fb_reach[tid]
			for t in _fb_tex_count:
				var bit := 1 << t
				if (anc & bit) != 0:
					_fb_reach[t] |= desc
				if (desc & bit) != 0:
					_fb_prev[t] |= anc
		for gy in range(y0, y1 + 1):
			var row_off := gy * cols
			for gx in range(x0, x1 + 1):
				var cell := row_off + gx
				if _fb_grid_stamp[cell] != _fb_stamp:
					_fb_grid_stamp[cell] = _fb_stamp
					_fb_grid_head[cell] = -1
				var n_idx := _fb_nodes_used
				_fb_nodes_used += 1
				if n_idx >= _fb_node_cap:
					_fb_node_cap = maxi(1024, _fb_node_cap * 2)
					_fb_node_i.resize(_fb_node_cap)
					_fb_node_tid.resize(_fb_node_cap)
					_fb_node_next.resize(_fb_node_cap)
				_fb_node_i[n_idx] = i
				_fb_node_tid[n_idx] = tid
				_fb_node_next[n_idx] = _fb_grid_head[cell]
				_fb_grid_head[cell] = n_idx
	_flush_flat_batch(_flat_batches[_flat_batches_used - 1] as Dictionary)


static func _collect_mark(marks: Dictionary, mtex: Variant, i: int) -> void:
	if mtex == null:
		return
	var tex: Texture2D = mtex
	var bucket: Array = marks.get(tex, [])
	if bucket.is_empty():
		marks[tex] = bucket
	bucket.append(i)


## What _draw draws, in its order: [["s" (a shadow), "i" (an icon) or "m" (a quality mark), texture,
## rect, depth ahead of the camera (icons only, else -1)], ...] (tests).
func paint_list() -> Array:
	var out := []
	if icon_order:
		if not _layers_now:
			return out
		if _flat:
			for k in _order_count:
				var i := _order[k]
				out.append(["s", _shadow, _buf_shadow[i], -1.0])
			if flat_batch_marks and flat_batch_tex:
				for b in _flat_batches_used:
					var batch: Dictionary = _flat_batches[b]
					for tex: Texture2D in batch:
						var bucket: Array = batch[tex]
						for idx: int in bucket:
							out.append(["i", tex, _buf_rect[idx], _buf_depth[idx]])
				for mtex: Texture2D in _flat_marks:
					var mbucket: Array = _flat_marks[mtex]
					for idx: int in mbucket:
						out.append(["m", mtex, _buf_mark_rect[idx], -1.0])
			elif flat_batch_marks:
				var marks := {}
				for k in _order_count:
					var i := _order[k]
					out.append(["i", _buf_tex[i], _buf_rect[i], _buf_depth[i]])
					_collect_mark(marks, _buf_mark[i], i)
				for mtex: Texture2D in marks:
					var bucket: Array = marks[mtex]
					for i: int in bucket:
						out.append(["m", mtex, _buf_mark_rect[i], -1.0])
			else:
				for k in _order_count:
					var i := _order[k]
					out.append(["i", _buf_tex[i], _buf_rect[i], _buf_depth[i]])
					if _buf_mark[i] != null:
						out.append(["m", _buf_mark[i], _buf_mark_rect[i], -1.0])
			return out
		for l in _layers_used:
			var layer: Array = _layers[l]
			for i in layer[0]:
				out.append(["s", _shadow, _buf_shadow[i], -1.0])
			for texture in layer[1]:
				for i in layer[1][texture]:
					out.append(["i", texture, _buf_rect[i], _buf_depth[i]])
			for i in layer[0]:
				if _buf_mark[i] != null:
					out.append(["m", _buf_mark[i], _buf_mark_rect[i], -1.0])
		return out
	for rect in _shadows_direct:
		out.append(["s", _shadow, rect, -1.0])
	for texture in _icons_direct:
		for i in _e_count:
			if _buf_tex[i] == texture:
				out.append(["i", texture, _buf_rect[i], _buf_depth[i]])
	for texture in _marks_direct:
		for rect in _marks_direct[texture]:
			out.append(["m", texture, rect, -1.0])
	return out


## This frame's icons: their shadows, their rectangles by picture and their quality marks by picture
## (drawn in that order under --alt-icon-order=old; lazily materialized when read under icon_order).
var _shadows_direct: Array[Rect2] = []
var _icons_direct := {}  # Texture2D -> [Rect2, ...]
var _marks_direct := {}  # Texture2D -> [Rect2, ...]
var _icons_built := false
var _marks_built := false
var _icons: Dictionary:
	get:
		if not icon_order:
			return _icons_direct
		if not _icons_built:
			_icons_built = true
			_icons_direct.clear()
			for i in _e_count:
				var tex: Texture2D = _buf_tex[i]
				var rects: Array = _icons_direct.get(tex, [])
				if rects.is_empty():
					_icons_direct[tex] = rects
				rects.append(_buf_rect[i])
		return _icons_direct
var _marks: Dictionary:
	get:
		if not icon_order:
			return _marks_direct
		if not _marks_built:
			_marks_built = true
			_marks_direct.clear()
			for i in _e_count:
				var m: Variant = _buf_mark[i]
				if m == null:
					continue
				var mtex: Texture2D = m
				var rects: Array = _marks_direct.get(mtex, [])
				if rects.is_empty():
					_marks_direct[mtex] = rects
				rects.append(_buf_mark_rect[i])
		return _marks_direct
## First person: the quads this frame used for quality marks (not counted as icons).
var _marks_3d := 0
## Icons drawn in the last frame (tests, the stutter probe).
var drawn := 0


## First person: the icons over `top` as camera-facing quads in the world, at the same cells
## (tiles right and down from `top`), their quality marks a little in front.
func _place_quads(world, camera: Camera3D, top: Vector3, textures: Array[Texture2D], cells: Array,
		qualities: Array[String] = []) -> void:
	var state := _ensure_quad_state(world, camera, top)
	var right := camera.global_basis.x
	var up := camera.global_basis.y
	var toward := camera.global_basis.z
	var ortho := camera.projection == Camera3D.PROJECTION_ORTHOGONAL
	var base := float(state[0])
	for i in mini(textures.size(), cells.size()):
		if textures[i] == null:
			continue
		var side: float = float(cells[i][1])
		var mid: Vector2 = cells[i][0]
		var at := top + right * mid.x - up * mid.y
		state[1] = int(state[1]) + 1
		var step := QUAD_STEP * int(state[1])
		_quad(at, side, textures[i], _sort_distance(camera, at, ortho) - base + step if icon_order else 0.0)
		var mark: Texture2D = Slot.quality_icon(qualities[i]) if i < qualities.size() else null
		if mark != null:
			var qs := side * QUALITY_SHARE
			var mark_at := at + right * (qs - side) * 0.5 - up * (side - qs) * 0.5 + toward * 0.02
			_quad(mark_at, qs, mark, _sort_distance(camera, mark_at, ortho) - base + step + QUAD_STEP * 0.5 if icon_order else 0.0)
			_marks_3d += 1


func _place_quads_cached(world, camera: Camera3D, top: Vector3, cc: ChunkCache, start: int, count: int) -> void:
	var state := _ensure_quad_state(world, camera, top)
	var right := camera.global_basis.x
	var up := camera.global_basis.y
	var toward := camera.global_basis.z
	var ortho := camera.projection == Camera3D.PROJECTION_ORTHOGONAL
	var base := float(state[0])
	for ci in range(start, start + count):
		var side := cc.cell_side[ci]
		var mid := cc.cell_offset[ci]
		var at := top + right * mid.x - up * mid.y
		state[1] = int(state[1]) + 1
		var step := QUAD_STEP * int(state[1])
		_quad(at, side, cc.cell_tex[ci], _sort_distance(camera, at, ortho) - base + step if icon_order else 0.0)
		var mark: Variant = cc.cell_mark[ci]
		if mark != null:
			var qs := side * QUALITY_SHARE
			var mark_at := at + right * (qs - side) * 0.5 - up * (side - qs) * 0.5 + toward * 0.02
			_quad(mark_at, qs, mark as Texture2D, _sort_distance(camera, mark_at, ortho) - base + step + QUAD_STEP * 0.5 if icon_order else 0.0)
			_marks_3d += 1


func _place_quads_raw(world, camera: Camera3D, top: Vector3, offsets: PackedVector2Array, sides: PackedFloat32Array,
		textures: Array[Texture2D], marks: Array) -> void:
	var state := _ensure_quad_state(world, camera, top)
	var right := camera.global_basis.x
	var up := camera.global_basis.y
	var toward := camera.global_basis.z
	var ortho := camera.projection == Camera3D.PROJECTION_ORTHOGONAL
	var base := float(state[0])
	for ci in textures.size():
		var side := sides[ci]
		var mid := offsets[ci]
		var at := top + right * mid.x - up * mid.y
		state[1] = int(state[1]) + 1
		var step := QUAD_STEP * int(state[1])
		_quad(at, side, textures[ci], _sort_distance(camera, at, ortho) - base + step if icon_order else 0.0)
		var mark: Variant = marks[ci]
		if mark != null:
			var qs := side * QUALITY_SHARE
			var mark_at := at + right * (qs - side) * 0.5 - up * (side - qs) * 0.5 + toward * 0.02
			_quad(mark_at, qs, mark as Texture2D, _sort_distance(camera, mark_at, ortho) - base + step + QUAD_STEP * 0.5 if icon_order else 0.0)
			_marks_3d += 1


func _ensure_quad_state(world, camera: Camera3D, top: Vector3) -> Array:
	if _quad_holder == null or not is_instance_valid(_quad_holder):
		_quad_holder = Node3D.new()
		_quad_holder.name = "AltIcons3D"
		(world as Node).get_parent().add_child(_quad_holder)
		_quads.clear()
	var ortho := camera.projection == Camera3D.PROJECTION_ORTHOGONAL
	# Godot's transparent pass sorts by the distance from the camera to each quad (ortho: its depth)
	# less its sorting_offset: every cell sorts at its machine's, a step nearer per cell, so a
	# machine's lower rows are drawn over its upper whichever way the camera looks at them.
	# A machine's rows come in calls of their own (its icon, then its modules, its packs): the
	# first's distance and the steps carry on across them, so its later rows sort nearer.
	var machine := Vector2(top.x, top.z)
	var state: Array = _quad_machines.get(machine, [])
	if state.is_empty():
		state = [_sort_distance(camera, top, ortho), 0]
		_quad_machines[machine] = state
	return state


## What Godot's transparent pass sorts a quad at `p` by (before its sorting_offset).
static func _sort_distance(camera: Camera3D, p: Vector3, ortho: bool) -> float:
	if ortho:
		return -camera.global_basis.z.dot(p - camera.global_position)
	return camera.global_position.distance_to(p)


func _quad(at: Vector3, side: float, texture: Texture2D, sort_offset := 0.0) -> void:
	if _quads_used >= _quads.size():
		var q := MeshInstance3D.new()
		var mesh := QuadMesh.new()
		mesh.size = Vector2.ONE
		q.mesh = mesh
		q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_quad_holder.add_child(q)
		_quads.append(q)
	var q := _quads[_quads_used]
	_quads_used += 1
	q.position = at
	q.sorting_offset = sort_offset
	q.scale = Vector3(side, side, side)
	q.material_override = _quad_material(texture)
	q.visible = true


func _quad_material(texture: Texture2D) -> ShaderMaterial:
	var m: ShaderMaterial = _quad_materials.get(texture)
	if m == null:
		m = ShaderMaterial.new()
		m.shader = DepthIcon
		m.set_shader_parameter("icon", texture)
		_quad_materials[texture] = m
	return m


## Hides the quads this frame didn't use (all of them out of first person).
func _hide_quads() -> void:
	for i in range(_quads_used, _quads.size()):
		_quads[i].visible = false


# --- Alt-mode's icons on the graphics card (icons_mode, shaders/alt_icons.gdshader) -----------------
## The instances: what _emit_chunk_cache works out once a frame is fixed per icon (its anchor, `ref`, cell
## offset, side, picture and mark), so it goes to the card once, when the icons change, and the shader
## places each with the camera. Chunk by chunk (GpuChunk: its icons farthest first by _order_key, a
## machine's cells in their order, as _build_layers sorts them), the chunks farthest first, all in one
## MultiMesh drawn behind this Control's own drawing (the movers and a hovered beacon, still on the CPU).
## Sorted by the view's direction from a fixed origin (stable_order), so moving the camera never changes
## the order; turning it more than GPU_RESORT_DEG, or by any amount once it stops, sorts again.
## Where icons of two chunks overlap, the nearer chunk's is in front even when the other's anchor is a
## little nearer (a tall machine across a chunk's edge): fixed by the chunks' order, so it never flickers.
## Every icon is drawn as the CPU path's layers draw it (its shadow over the farther icons, then it), also
## past layer_cap, where the CPU path draws every shadow first.

const GPU_LAYER_PX := 64
const GPU_MAX_LAYERS := 4095
const GPU_RESORT_DEG := 2.0
const GPU_FLOATS := 16  # an instance: Transform2D (8), colour (4), custom (4)
## Chunks' instances rebuilt a frame beyond those in view (µs).
const GPU_BUDGET_USEC := 1500


class GpuChunk:
	var sig := 0
	var fwd_rev := -1
	var data := PackedFloat32Array()


var _gpu_live := false
var _gpu_ci := RID()
var _gpu_mm := RID()
var _gpu_mesh: ArrayMesh = null
var _gpu_mat: ShaderMaterial = null
var _gpu_tex: Texture2DArray = null
var _gpu_tex_cap := 0
var _gpu_layer_of := {}  # Texture2D -> layer
var _gpu_images: Array[Image] = []
var _gpu_tex_from := 0  # the first layer not yet on the card
var _gpu_blank: Image = null
var _gpu_chunks := {}  # Vector2i -> GpuChunk
var _gpu_order: Array[Vector2i] = []
var _gpu_order_dirty := true
var _gpu_buffer_dirty := true
var _gpu_alloc := -1
var _gpu_fwd := Vector3.ZERO
var _gpu_fwd_rev := 0
var _gpu_prev_fwd := Vector3.ZERO
var _gpu_data_key: Array = []
var _gpu_global_key: Array = []
var _gpu_builds_key: Array = []
var _gpu_check := {}  # Vector2i -> true: chunks to look at again
var _gpu_camera: Camera3D = null
var _gpu_uniforms: Array = []
## Instances on the card, and how many times the buffer was sent (tests, the debug overlay).
var gpu_instances := 0
var gpu_uploads := 0


## Whether this frame's icons go on the card (icons_mode).
func _gpu_wanted(first_person: bool, fog_key: Array) -> bool:
	if icons_mode == "cpu" or not use_cache or first_person:
		return false
	if not fog_key.is_empty() and bool(fog_key[0]):
		return false
	if icons_mode == "gpu":
		return true
	if DisplayServer.get_name() == "headless":
		return false
	return RenderingServer.get_current_rendering_method() != "gl_compatibility"


func _gpu_set_live(v: bool) -> void:
	if v == _gpu_live:
		return
	_gpu_live = v
	if v:
		_gpu_setup()
		# Whatever the CPU path changed meanwhile: look at everything again.
		_gpu_data_key = []
		_gpu_global_key = []
		_gpu_builds_key = []
		_gpu_uniforms = []
	if _gpu_ci.is_valid():
		RenderingServer.canvas_item_set_visible(_gpu_ci, v)


func _gpu_setup() -> void:
	if _gpu_ci.is_valid() or not is_inside_tree():
		return
	if _gpu_mesh == null:
		# One quad, corners at ±1 (the shader scales it to the shadow's square).
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = PackedVector2Array([Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)])
		arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
		arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
		_gpu_mesh = ArrayMesh.new()
		_gpu_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_FLAG_USE_2D_VERTICES)
	if _gpu_mat == null:
		_gpu_mat = ShaderMaterial.new()
		_gpu_mat.shader = GpuShader
		_gpu_mat.set_shader_parameter("shadow_tex", _shadow)
		if _gpu_tex != null:
			_gpu_mat.set_shader_parameter("icons", _gpu_tex)
	_gpu_mm = RenderingServer.multimesh_create()
	RenderingServer.multimesh_set_mesh(_gpu_mm, _gpu_mesh.get_rid())
	RenderingServer.multimesh_allocate_data(_gpu_mm, 0, RenderingServer.MULTIMESH_TRANSFORM_2D, true, true)
	RenderingServer.multimesh_set_custom_aabb(_gpu_mm, AABB(Vector3(-1e7, -1e7, -1.0), Vector3(2e7, 2e7, 2.0)))
	_gpu_alloc = 0
	_gpu_ci = RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(_gpu_ci, get_canvas_item())
	RenderingServer.canvas_item_set_draw_behind_parent(_gpu_ci, true)
	RenderingServer.canvas_item_set_custom_rect(_gpu_ci, true, Rect2(-1e7, -1e7, 2e7, 2e7))
	RenderingServer.canvas_item_set_material(_gpu_ci, _gpu_mat.get_rid())
	RenderingServer.canvas_item_add_multimesh(_gpu_ci, _gpu_mm, RID())
	RenderingServer.canvas_item_set_visible(_gpu_ci, _gpu_live)
	_gpu_buffer_dirty = true


func _gpu_free() -> void:
	if _gpu_ci.is_valid():
		RenderingServer.free_rid(_gpu_ci)
	if _gpu_mm.is_valid():
		RenderingServer.free_rid(_gpu_mm)
	_gpu_ci = RID()
	_gpu_mm = RID()
	_gpu_alloc = -1
	_gpu_live = false


## Brings the card's instances up to date with the caches (a frame where nothing changed costs a few
## comparisons). Chunks in view are rebuilt at once, the rest within GPU_BUDGET_USEC a frame.
func _gpu_sync(world, camera: Camera3D, fluids_layer, gh_ver: int, gfx_gen: int, icons_ver: int, eprops_size: int,
		data_key: Array) -> void:
	if not _gpu_ci.is_valid():
		_gpu_setup()
		if not _gpu_ci.is_valid():
			return
	var fwd := (-camera.global_basis.z).normalized()
	var global_key := [world, gh_ver, gfx_gen, icons_ver, eprops_size, use_spec]
	if global_key != _gpu_global_key:
		if _gpu_global_key.size() == global_key.size() and (_gpu_global_key[2] != gfx_gen or _gpu_global_key[3] != icons_ver):
			_gpu_reset_layers()
		if _gpu_global_key.is_empty() or _gpu_global_key[0] != world:
			_gpu_chunks.clear()
			_gpu_order_dirty = true
		_gpu_global_key = global_key
		for c in world.chunks:
			_gpu_check[c] = true
		for c in _gpu_chunks:
			_gpu_check[c] = true
		_gpu_data_key = []
	if data_key != _gpu_data_key or not _dirty_alt_chunks.is_empty() or not _pending_aiu_units.is_empty():
		_gpu_data_key = data_key
		_resolve_pending_aiu(world)
		_gpu_ensure(world, fluids_layer, gh_ver, eprops_size, gfx_gen, icons_ver)
		for c in _dirty_alt_chunks:
			_gpu_check[c] = true
		for c in _chunk_alt_cache:
			var cc: ChunkCache = _chunk_alt_cache[c]
			var cv = world.chunks.get(c)
			if cv == null or cc.cv_id != cv.get_instance_id() or cc.content_rev != cv.content_rev:
				_gpu_check[c] = true
		for c in _gpu_chunks:
			if not world.chunks.has(c):
				_gpu_check[c] = true
	# The view turned: sort again.
	var turned := _gpu_fwd == Vector3.ZERO or fwd.angle_to(_gpu_fwd) > deg_to_rad(GPU_RESORT_DEG) \
		or (fwd == _gpu_prev_fwd and fwd.angle_to(_gpu_fwd) > 0.0001)
	_gpu_prev_fwd = fwd
	if turned:
		_gpu_fwd = fwd
		_gpu_fwd_rev += 1
		_gpu_order_dirty = true
		for c in _gpu_chunks:
			_gpu_check[c] = true
	if not _gpu_check.is_empty():
		var planes := camera.get_frustum()
		var lift := GroundHeight.lift_range()
		var t0 := Time.get_ticks_usec()
		var keys: Array = _gpu_check.keys()
		for c: Vector2i in keys:
			if _chunk_in_view_lift(c, planes, lift):
				_gpu_check.erase(c)
				_gpu_update_chunk(world, c, fluids_layer, gh_ver, eprops_size, gfx_gen, icons_ver)
		for c: Vector2i in keys:
			if Time.get_ticks_usec() - t0 > GPU_BUDGET_USEC:
				break
			if _gpu_check.has(c):
				_gpu_check.erase(c)
				_gpu_update_chunk(world, c, fluids_layer, gh_ver, eprops_size, gfx_gen, icons_ver)
	_gpu_flush_layers()
	if _gpu_order_dirty:
		_gpu_order_dirty = false
		_gpu_buffer_dirty = true
		_gpu_sort_chunks()
	if _gpu_buffer_dirty:
		_gpu_buffer_dirty = false
		_gpu_upload()


## The three whole-map caches (they rebuild only when their lists changed); their chunks looked at again
## after a rebuild.
func _gpu_ensure(world, fluids_layer, gh_ver: int, eprops_size: int, gfx_gen: int, icons_ver: int) -> void:
	_ensure_contents_cache(world, gh_ver, eprops_size, gfx_gen, icons_ver)
	_ensure_machines_cache(world, gh_ver, eprops_size, gfx_gen, icons_ver)
	if fluids_layer != null:
		_ensure_fluids_cache(world, fluids_layer, gh_ver, gfx_gen, icons_ver)
	var builds := [_ac_builds, _am_builds, _fl_builds, fluids_layer]
	if builds == _gpu_builds_key:
		return
	_gpu_builds_key = builds
	for d: Dictionary in [_chunk_contents_cache, _chunk_machines_cache, _chunk_fluids_cache]:
		for c in d:
			_gpu_check[c] = true
	for c in _gpu_chunks:
		_gpu_check[c] = true


## One chunk's instances, from its four caches (the alt cache rebuilt here when out of date, as collect()
## does for a chunk in view), rebuilt only when what they hold changed or the view turned.
func _gpu_update_chunk(world, c: Vector2i, fluids_layer, gh_ver: int, eprops_size: int, gfx_gen: int, icons_ver: int) -> void:
	var cv = world.chunks.get(c)
	var caches: Array = []
	if cv != null:
		var alt_cc: ChunkCache = _chunk_alt_cache.get(c)
		if _dirty_alt_chunks.has(c) or alt_cc == null or alt_cc.cv_id != cv.get_instance_id() \
				or alt_cc.content_rev != cv.content_rev or alt_cc.gh_ver != gh_ver \
				or alt_cc.gfx_gen != gfx_gen or alt_cc.icons_ver != icons_ver \
				or alt_cc.use_spec != use_spec or alt_cc.eprops_size != eprops_size:
			if alt_cc != null and alt_cc.content_rev != cv.content_rev:
				if _chunk_contents_cache.has(c) or _ac_missing:
					_contents_dirty = true
				if _chunk_machines_cache.has(c) or _am_missing:
					_machines_dirty = true
				if _chunk_fluids_cache.has(c) or _fl_missing:
					_fluids_dirty = true
				_gpu_ensure(world, fluids_layer, gh_ver, eprops_size, gfx_gen, icons_ver)
			alt_cc = _build_chunk_alt_cache(world, c, cv, gh_ver, eprops_size, gfx_gen, icons_ver)
		caches = [alt_cc, _chunk_contents_cache.get(c), _chunk_machines_cache.get(c),
			_chunk_fluids_cache.get(c) if fluids_layer != null else null]
	else:
		_chunk_alt_cache.erase(c)
		_dirty_alt_chunks.erase(c)
	var sig := 0
	var parts: Array = []
	for cc: ChunkCache in caches:
		if cc == null or cc.ent_anchor.is_empty():
			parts.append(0)
			continue
		parts.append([cc.ent_anchor, cc.ent_ref, cc.ent_cell_start, cc.ent_cell_count, cc.ent_hover_rec,
			cc.cell_offset, cc.cell_side, cc.cell_tex, cc.cell_mark].hash())
		sig = 1
	var gc: GpuChunk = _gpu_chunks.get(c)
	if sig == 0:
		if gc != null:
			_gpu_chunks.erase(c)
			_gpu_order_dirty = true
		return
	sig = parts.hash()
	if gc == null:
		gc = GpuChunk.new()
		_gpu_chunks[c] = gc
		_gpu_order_dirty = true
	if gc.sig == sig and gc.fwd_rev == _gpu_fwd_rev:
		return
	gc.sig = sig
	gc.fwd_rev = _gpu_fwd_rev
	gc.data = _gpu_fill(caches)
	_gpu_buffer_dirty = true


## A chunk's instances, farthest first (the CPU path's sort: depth by _order_key to 1/256 tile, then the
## order the icons were found in).
func _gpu_fill(caches: Array) -> PackedFloat32Array:
	var fwd := _gpu_fwd
	var keys := PackedInt64Array()
	var at_of := PackedVector3Array()
	var ref_of := PackedFloat32Array()
	var off_of := PackedVector2Array()
	var side_of := PackedFloat32Array()
	var pic_of := PackedFloat32Array()
	var n := 0
	for cc: ChunkCache in caches:
		if cc == null:
			continue
		for ei in cc.ent_anchor.size():
			if cc.ent_hover_rec[ei] != null:
				continue  # a beacon's modules: on the CPU while hovered
			var at := cc.ent_anchor[ei]
			var q := clampi(floori(_order_key(fwd, at) * 256.0), -(1 << 30), 1 << 30)
			var hi := ((1 << 30) - q) << 21
			var ref := cc.ent_ref[ei]
			var start := cc.ent_cell_start[ei]
			for ci in range(start, start + cc.ent_cell_count[ei]):
				var mark: Variant = cc.cell_mark[ci]
				var mark_layer := _gpu_layer(mark) if mark is Texture2D else -1
				keys.append(hi | n)
				at_of.append(at)
				ref_of.append(ref)
				off_of.append(cc.cell_offset[ci])
				side_of.append(cc.cell_side[ci])
				pic_of.append(float(_gpu_layer(cc.cell_tex[ci]) + 4096 * (mark_layer + 1)))
				n += 1
	keys.sort()
	var data := PackedFloat32Array()
	data.resize(n * GPU_FLOATS)
	var o := 0
	for k in n:
		var i := int(keys[k] & ((1 << 21) - 1))
		var at := at_of[i]
		var off := off_of[i]
		data[o] = 1.0
		data[o + 5] = 1.0
		data[o + 8] = off.x
		data[o + 9] = off.y
		data[o + 10] = side_of[i]
		data[o + 11] = pic_of[i]
		data[o + 12] = at.x
		data[o + 13] = at.y
		data[o + 14] = at.z
		data[o + 15] = ref_of[i]
		o += GPU_FLOATS
	return data


## The chunks farthest first along the view (their centres; ties by position, so the order is fixed).
func _gpu_sort_chunks() -> void:
	var fwd := _gpu_fwd
	var list: Array = []
	for c: Vector2i in _gpu_chunks:
		list.append([-_order_key(fwd, Vector3(c.x * 32.0 + 16.0, 0.0, c.y * 32.0 + 16.0)), c.x, c.y])
	var by_key := func(a: Array, b: Array) -> bool:
		if a[0] != b[0]:
			return a[0] < b[0]
		if a[1] != b[1]:
			return a[1] < b[1]
		return a[2] < b[2]
	list.sort_custom(by_key)
	_gpu_order.clear()
	for e: Array in list:
		_gpu_order.append(Vector2i(int(e[1]), int(e[2])))


func _gpu_upload() -> void:
	if not _gpu_mm.is_valid():
		return
	var buf := PackedFloat32Array()
	for c: Vector2i in _gpu_order:
		var gc: GpuChunk = _gpu_chunks.get(c)
		if gc != null:
			buf.append_array(gc.data)
	var n := buf.size() / GPU_FLOATS
	if n != _gpu_alloc:
		RenderingServer.multimesh_allocate_data(_gpu_mm, n, RenderingServer.MULTIMESH_TRANSFORM_2D, true, true)
		RenderingServer.multimesh_set_custom_aabb(_gpu_mm, AABB(Vector3(-1e7, -1e7, -1.0), Vector3(2e7, 2e7, 2.0)))
		_gpu_alloc = n
	if n > 0:
		RenderingServer.multimesh_set_buffer(_gpu_mm, buf)
	gpu_instances = n
	gpu_uploads += 1


## The picture's layer in the icons' texture array (added on first use, sent by _gpu_flush_layers).
func _gpu_layer(tex: Texture2D) -> int:
	var l: int = _gpu_layer_of.get(tex, -1)
	if l >= 0:
		return l
	if _gpu_images.size() >= _gpu_layer_limit():
		return 0
	l = _gpu_images.size()
	_gpu_layer_of[tex] = l
	var frame := Engine.get_process_frames()
	if frame != _gpu_read_frame:
		_gpu_read_frame = frame
		_gpu_reads = 0
	if tex != null and tex.has_meta(CPU_IMAGE_META):
		_gpu_images.append(_gpu_icon_image(tex))  # its picture on the CPU already: no read to count
	elif _gpu_reads < GPU_READS_PER_FRAME:
		_gpu_reads += 1
		_gpu_images.append(_gpu_icon_image(tex))
	else:
		# Its layer kept for it, blank until read (_gpu_read_pending): the chunks keep their layers.
		_gpu_images.append(_gpu_blank_image())
		_gpu_pending.append([l, tex])
	return l


## The meta item_icons.gd's icons keep their picture in (ItemIcons.CPU_IMAGE_META): read without the renderer.
const CPU_IMAGE_META := &"f3d_cpu_image"
## Pictures read from the card a frame at most (_gpu_icon_image: get_image() on an icon's texture reads it
## back from the GPU outside the editor, a stall each): Alt-mode turned on over a big base, or the packs'
## icons changing, would read hundreds in one frame. The rest are read in the next frames.
const GPU_READS_PER_FRAME := 16
var _gpu_read_frame := -1
var _gpu_reads := 0
var _gpu_pending: Array = []  # [layer, Texture2D] read later


## Pictures whose read waited: up to the frame's reads, into their layers (on the card when it has them).
func _gpu_read_pending() -> void:
	if _gpu_pending.is_empty():
		return
	var frame := Engine.get_process_frames()
	if frame != _gpu_read_frame:
		_gpu_read_frame = frame
		_gpu_reads = 0
	while not _gpu_pending.is_empty() and _gpu_reads < GPU_READS_PER_FRAME:
		var e: Array = _gpu_pending.pop_front()
		_gpu_reads += 1
		var l := int(e[0])
		var tex: Texture2D = e[1]
		if l >= _gpu_images.size() or not is_instance_valid(tex):
			continue
		var img := _gpu_icon_image(tex)
		_gpu_images[l] = img
		if _gpu_tex != null and l < _gpu_tex_from and l < _gpu_tex_cap:
			_gpu_tex.update_layer(img, l)


## A picture as a 64 px RGBA layer with its mipmaps (the canvas draws the icons with mipmaps too).
func _gpu_icon_image(tex: Texture2D) -> Image:
	var img: Image = null
	if tex != null and tex.has_meta(CPU_IMAGE_META):
		img = tex.get_meta(CPU_IMAGE_META) as Image  # kept by item_icons.gd: no renderer read
	elif tex != null:
		img = tex.get_image()
	if img == null or img.is_empty():
		return _gpu_blank_image()
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	if img.has_mipmaps():
		img.clear_mipmaps()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	if img.get_width() != GPU_LAYER_PX or img.get_height() != GPU_LAYER_PX:
		img.resize(GPU_LAYER_PX, GPU_LAYER_PX, Image.INTERPOLATE_LANCZOS)
	img.generate_mipmaps()
	return img


## The layers the icons' texture array may have: GPU_MAX_LAYERS + 1, or fewer when the graphics card
## allows fewer (often 2048; Vulkan only promises 256): past it create_from_images fails and every icon
## drawn on the card would vanish. Without a RenderingDevice (Compatibility), 2048.
static var _layer_limit := -1


static func _gpu_layer_limit() -> int:
	if _layer_limit < 0:
		var lim := 2048
		var rd := RenderingServer.get_rendering_device()
		if rd != null:
			lim = GPU_MAX_LAYERS + 1
			var l := int(rd.limit_get(RenderingDevice.LIMIT_MAX_TEXTURE_ARRAY_LAYERS))
			if l > 0:
				lim = mini(lim, l)
		_layer_limit = maxi(lim, 32)
	return _layer_limit


func _gpu_blank_image() -> Image:
	if _gpu_blank == null:
		_gpu_blank = Image.create_empty(GPU_LAYER_PX, GPU_LAYER_PX, true, Image.FORMAT_RGBA8)
	return _gpu_blank


## New pictures to the card: into free layers, or a new array twice the size.
func _gpu_flush_layers() -> void:
	_gpu_read_pending()
	var n := _gpu_images.size()
	if _gpu_tex_from >= n:
		return
	if _gpu_tex == null or n > _gpu_tex_cap:
		var cap := 32
		while cap < n:
			cap *= 2
		cap = mini(cap, maxi(_gpu_layer_limit(), n))
		var list: Array[Image] = []
		list.append_array(_gpu_images)
		while list.size() < cap:
			list.append(_gpu_blank_image())
		_gpu_tex = Texture2DArray.new()
		_gpu_tex.create_from_images(list)
		_gpu_tex_cap = cap
		if _gpu_mat != null:
			_gpu_mat.set_shader_parameter("icons", _gpu_tex)
	else:
		for i in range(_gpu_tex_from, n):
			_gpu_tex.update_layer(_gpu_images[i], i)
	_gpu_tex_from = n


## Mod graphics or a model pack's icons changed: every picture read again (every chunk refilled).
func _gpu_reset_layers() -> void:
	_gpu_layer_of.clear()
	_gpu_images.clear()
	_gpu_pending.clear()
	_gpu_tex_from = 0
	_gpu_tex = null
	_gpu_tex_cap = 0
	_gpu_fwd_rev += 1


## The camera, after every script moved it this frame, into the shader (only what changed).
func _gpu_pre_draw() -> void:
	if not _gpu_live or _gpu_mat == null or not is_instance_valid(_gpu_camera) or not _gpu_camera.is_inside_tree():
		return
	var cam := _gpu_camera
	var xf := cam.get_camera_transform()
	var gx := cam.global_transform
	var pv := cam.get_camera_projection() * Projection(Transform3D(xf.basis.inverse(), Vector3.ZERO))
	var vp := cam.get_viewport().get_visible_rect().size
	var vals := [pv, xf.origin, gx.basis.x, (-gx.basis.z).normalized(), gx.origin, cam.near, vp,
		Vector2(Kit.px(4), Kit.px(40))]
	if vals == _gpu_uniforms:
		return
	_gpu_uniforms = vals
	_gpu_mat.set_shader_parameter("proj_view", pv)
	_gpu_mat.set_shader_parameter("cam_pos", xf.origin)
	_gpu_mat.set_shader_parameter("cam_right", gx.basis.x)
	_gpu_mat.set_shader_parameter("cam_fwd", (-gx.basis.z).normalized())
	_gpu_mat.set_shader_parameter("eye_pos", gx.origin)
	_gpu_mat.set_shader_parameter("cam_near", cam.near)
	_gpu_mat.set_shader_parameter("vp_size", vp)
	_gpu_mat.set_shader_parameter("px_clamp", Vector2(Kit.px(4), Kit.px(40)))
