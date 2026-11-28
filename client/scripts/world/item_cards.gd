extends Node3D
## Draws loose items: small 3D models (item_models.gd), flat icon cards lying face up for items
## without a model, or small coloured blocks when there is no icon either. One MultiMesh per
## item type, refilled from the positions it is given. Used for items on belts, on the ground
## and in inserter hands.
##
## Each instance is a turn about +Y and a position. Items on belts are drawn from records instead
## (put_records(), belt_records.gd): the shaders place each from its record and the drawn clock, so
## their instances are never written after a kind's size changes (belt_items.gd).

const ProtoDB := preload("res://scripts/world/protos.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
const ItemModels := preload("res://scripts/world/item_models.gd")
const CardShader := preload("res://shaders/item_card.gdshader")
const ContactShader := preload("res://shaders/item_contact.gdshader")
const ContactShade := preload("res://scripts/world/contact_shade.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")
const Switches := preload("res://scripts/switches.gd")

const CARD_SIZE := 0.32
## Stands in `_mv_last_hash` for "uploaded by the fast path without hashing" (BeltMv's change flag):
## hash() is never negative, so the slow path's own hash check can't match stale data.
const MV_SENT := -1
## A stack on a belt is drawn as a pile (belt_items.gd): each copy this much above the one under it.
## Icon cards lie flat, so the step is what shows the pile from the angled camera, as Factorio draws
## a stack's icons a little higher each; models and blocks pile by their own height.
const CARD_PILE := 0.07
const BLOCK_SIZE := Vector3(0.22, 0.08, 0.22)
## Every loose item turns by up to this much either way (radians), by item, so a full belt of plates
## doesn't look tiled: models, icon cards and blocks alike (owner: lone plastic bars stood square near
## and turned far, icon cards always square). One rule for every path, turn_for().
const MAX_YAW := 0.35
## A pile's copies turn this much more each, so a pile doesn't look like one tall block (owner: back
## to 0.1.2's piles after trying Factorio's neat, straight ones).
const PILE_TURN := 0.45
## Floats per instance in a MultiMesh buffer: 12 for the transform's rows, 4 of custom data.
const STRIDE := 16

var protos: ProtoDB

var _kinds := {}  # item id -> MultiMeshInstance3D
var _lift := {}  # item id -> Vector3, raises blocks so they sit on what carries them
var _turns := {}  # item id -> true when it is drawn as a model
var _pile := {}  # item id -> the step between a pile's copies (pile_step())
var _buffers := {}  # item id -> PackedFloat32Array, the MultiMesh's instances
var _materials := {}  # ShaderMaterial -> true, the ones set_paths() updates
var _paths: Texture2D = null  # set_paths(): kept across reset(), given to every new material
var _look := -1
var _models_gen := -1  # ItemModels.current_generation() when the kinds were last made
var epoch := 0  # bumped by reset(), when every buffer handed out before is gone
## Off for items on belts unless the camera is close (belt_items.gd): a shadow on an item a few
## pixels across can't be seen, and one MultiMesh a kind can't leave out the far ones, so every item
## went through the shadow pass. Lone items on the ground and in hands keep theirs.
var casts_shadow := true:
	set(value):
		if value == casts_shadow:
			return
		casts_shadow = value
		for id in _kinds:
			var mmi: MultiMeshInstance3D = _kinds[id]
			mmi.cast_shadow = _mmi_cast_shadow(int(id))
		_sync_shadow_proxies_visibility()
## The render layers of every kind's MultiMesh (GeometryInstance3D.layers). Items on belts are on
## BELT_LAYER, which the character's lantern and flashlight leave out of their shadow casters
## (avatar.gd): a kind is one MultiMesh over the whole square, so each of the lantern's six cube faces
## that touched it drew every item of it again. The sun's shadows still have them.
var render_layers := 1:
	set(value):
		if value == render_layers:
			return
		render_layers = value
		for mmi: MultiMeshInstance3D in _kinds.values():
			mmi.layers = value
		for smmi: MultiMeshInstance3D in _shadow_kinds.values():
			smmi.layers = value
## Items on belts (belt_items.gd), apart from avatar.gd's SELF_LAYER (bit 19).
const BELT_LAYER := 1 << 18
## Settings → Graphics → Item icons: off draws every item without a model as its coloured block.
static var use_icons := true
## Off when Settings → Graphics → Items in 3D is "Icons only": every item as its icon.
static var use_models := true:
	set(value):
		if value != use_models:
			use_models = value
			_look_changes += 1
static var _look_changes := 0
## Settings → Graphics → Items in 3D: the most items on belts drawn as models, nearest the focus
## first; the rest show their icon. -1 for all. belt_items.gd asks for those as icon kinds: a kind
## key below zero, -(item id + 1), is that item drawn as its icon whatever use_models says.
static var model_cap := -1
static var _card_mesh: PlaneMesh
static var _block_mesh: BoxMesh

## Contact shading under this node's items (item_contact.gdshader): a soft dark rim on the belt or ground
## round each, as the buildings' (contact_shade.gd). Set by belt_items.gd and ground_items.gd before their
## first kind; not in inserters' hands (nothing under them to touch). A kind's mesh is then a copy of its
## look with one more surface, a box round its footprint drawn as a decal by the kind's own MultiMesh, so
## it moves with its items on the GPU and costs one more instanced draw a kind, nothing a frame on the CPU.
var contact := false
## --belt-item-contact=off: no contact surfaces at all (as before); flip: on and off every
## CONTACT_FLIP seconds, for measuring (belt_items.gd --item-bench says which).
static var contact_allowed := true
static var contact_flip := false
const CONTACT_FLIP := 10.0
## How far past the footprint the rim reaches and how deep under the base the box goes (tiles; the
## shader's reach and gap_gone), and how far above the base it starts.
const CONTACT_REACH := 0.055
const CONTACT_DROP := 0.11
const CONTACT_TOP := 0.012
## Tiles per pixel at which an item's contact rim starts fading out and vanishes completely: tighter
## than buildings' AoZoom.RIM_FULL/RIM_GONE (0.06/0.14), since a 0.3-tile item's 0.06-tile rim is
## ~1 px at 20 px/tile (0.05) and full up to ~43 tiles out at 1080p (default zoom is 30 tiles).
const CONTACT_FADE_FROM := 0.025
const CONTACT_FADE_TO := 0.05
## Camera distance (tiles) past which multi-surface/see-through own-look items switch from their
## detailed own materials to a single merged opaque surface (item_models.gd dressed_lod).
const ITEM_LOD_DIST := 36.0
## An icon card's footprint for its rim: this share of the card (its picture rarely fills the corners).
const CONTACT_CARD := 0.6
## Every live node's contact material (one each: its belt_paths), for the setting and the debug sliders.
static var _contact_materials: Array[ShaderMaterial] = []
static var _contact_params := {}  # uniform -> value the debug menu set (null: the shader's own)
static var _contact_shown := true
static var _contact_anchor_on := false
static var _contact_anchor_pos := Vector3.INF
static var _contact_anchor_d1 := 28.0
var _contact_material: ShaderMaterial
var _lod_materials := {}  # ShaderMaterial -> true: non-allow_lod multi-surface item LOD materials receiving lod_cam
var _lod_cam_sent := Vector3.INF
static var _global_lod_cam_sent := Vector3.INF

## Packed-lane variant gating (--lattice-variants=close|all|off): extra ore/coal/stone lattice variants
## only render within LATTICE_VARIANTS_CLOSE tiles at LOD0 unless overridden.
const LATTICE_VARIANTS_CLOSE := 24.0
const LATTICE_VARIANTS_HYST := 2.0
static var lattice_variants_mode := _lattice_variants_arg()
var lattice_variants_active := lattice_variants_mode != "off"

## Screen-size geometric LOD thresholds (pixels per tile, capped at MAX_LOD_LINES like BeltLods.MAX_LINES).
const LOD1_BELOW_PX := 56.0
const LOD0_ABOVE_PX := 64.0
const LOD2_BELOW_PX := 16.0
const LOD1_ABOVE_PX := 19.0
const MAX_LOD_LINES := 1080.0
## Per-instance distance-banded LOD ("distance", default) vs legacy global zoom tier ("global", --item-lod-mode=global).
const LOD_DIST_PX_1 := 36.0
const LOD_DIST_PX_2 := 18.0
const LOD_QUALITY_SCALE := {"low": 0.42, "medium": 1.0, "high": 1.30, "ultra": 1.60}
const LOD_D1_MIN := 8.0
const LOD_D1_MAX := 144.0
const LOD_D2_GAP := 10.0
const LOD_D2_MAX := 260.0
const BAND_AABB_PAD := 1.5
const LOD0_FADE_RATIO := 0.60
const LOD1_FADE_RATIO := 0.70
const LOD_JITTER_SHARE := 0.14
const LOD1_JITTER_MAX := 5.0
const LOD2_JITTER_MAX := 8.0
const CHAR_LOD_D1 := 28.0  # low ~12, medium 28, high 36, ultra 49 tiles from character
const CHAR_LOD_D2 := 56.0  # low ~24, medium 56, high 73, ultra 90 tiles from character
static var lod_mode := _lod_mode_arg()
static var lod_blend := Switches.on("--item-lod-blend")
static var lod_split := Switches.on("--item-lod-split")
## Character-anchored bands (normal play) also bounded by the zoom: "zoom" (default) moves an item to the
## mid / far band once it is under LOD_DIST_PX_1 / LOD_DIST_PX_2 pixels a tile on screen, so zoomed out each
## item is drawn by its cheap band only; "all" (`--item-lod-bands=all`) keeps the flat 28 / 56 tiles around
## the character at any zoom (before: zoomed out nearly every item stayed in the full or mid band).
static var lod_bands_mode := _lod_bands_arg()
## The camera's distance is taken in steps of this many tiles, so a zoom re-bands the belts a few times.
const LOD_ZOOM_STEP := 4.0
static var lod_quality := "medium"
static var custom_lod_distance := 0.0
## Debug override (-1 = Auto, 0 = LOD0 full, 1 = LOD1 decimated, 2 = LOD2 icon/proxy).
static var forced_lod_tier := -1
var allow_lod := false
var split_bands := false
var lod_tier := 0
var _forced_lod_seen := -1
var _lod_d1 := 36.0
var _lod_d2 := 72.0
var _lod1_sq := 36.0 * 36.0
var _lod2_sq := 72.0 * 72.0
var _lod_blend_seen := lod_blend
var _lod_bounds := AABB()
var _has_lod_bounds := false
var _lod_band_mask := 7
var _lod_use_anchor := false
var _lod_anchor_pos := Vector3.INF
var _dist_lods := {}  # item id -> distance-banded LOD state dict (legacy single-MultiMesh path)
var _split_lods := {}  # kind key -> split distance-band state dict (near/mid/far separate MultiMeshes)
var _raw_models := {}  # item id -> [model: Mesh, item: String, want_contact: bool]
var _lod0_cache := {}  # item id -> [mesh: Mesh, override: Material]
var _lod1_cache := {}  # item id -> [mesh: Mesh, override: Material]
var _lod2_cache := {}  # item id -> [mesh: Mesh, override: Material]
var _lod2_waiting := {}  # item id -> item: String waiting for async icon load

## 12-triangle shadow box proxies (--item-shadow-proxy=off restores full-mesh shadows on 3D items).
static var shadow_proxy_enabled := Switches.on("--item-shadow-proxy")
var use_shadow_proxy := false
var _shadow_kinds := {}  # item id (variant 0 on lattice; every variant on simulated belts) -> MultiMeshInstance3D
var _shadow_proxied := {}  # item id -> true when detailed mesh casting is replaced by proxy
var _record_params := {}  # item id -> [base, n, cap, bounds]
var _record_counts := {}  # item id -> latest record count
var _shadow_material: ShaderMaterial
var _shadow_cam_sent := Vector3.INF
var _shadow_max_sent := -1.0
var _shadow_cam_latest := Vector3.ZERO
var _shadow_max_latest := -1.0


static func _lod_mode_arg() -> String:
	var mode := "distance"
	for arg in Switches.args():
		if arg.begins_with("--item-lod-mode="):
			var v := arg.get_slice("=", 1)
			if v == "global" or v == "distance":
				mode = v
	return mode


static func _lod_bands_arg() -> String:
	var mode := "zoom"
	for arg in Switches.args():
		if arg.begins_with("--item-lod-bands="):
			var v := arg.get_slice("=", 1)
			if v == "all" or v == "zoom":
				mode = v
	return mode


static func apply_lod_quality(quality: String, custom_distance := 0.0) -> void:
	var q := quality.to_lower()
	lod_quality = q if LOD_QUALITY_SCALE.has(q) else "medium"
	custom_lod_distance = maxf(custom_distance, 0.0)


static func _lod_scale(quality: String) -> float:
	if quality == "" and custom_lod_distance > 0.0:
		return clampf(custom_lod_distance / ModelLods.LOD_DIST_REF, 0.25, 3.0)
	var q := quality.to_lower() if quality != "" else lod_quality
	if ModelLods.old_low_lod and q == "low":
		return 0.72
	return float(LOD_QUALITY_SCALE.get(q, 1.0))


## Camera-distance LOD band cutoffs in tiles: x = LOD0->LOD1, y = LOD1->LOD2 (INF disables dropoff, 0 forces coarsening).
static func distance_thresholds(cam: Camera3D, vp_h: float, quality := "") -> Vector2:
	if not ItemModels.item_geom_lod or ModelLods.full_detail:
		return Vector2(INF, INF)
	var scale := _lod_scale(quality)
	if cam == null:
		return Vector2(36.0 * scale, 72.0 * scale)
	var lines := minf(maxf(vp_h, 1.0), MAX_LOD_LINES)
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		var px := lines / maxf(cam.size, 0.01)
		if px >= LOD_DIST_PX_1 / scale:
			return Vector2(INF, INF)
		if px >= LOD_DIST_PX_2 / scale:
			return Vector2(0.0, INF)
		return Vector2(0.0, 0.0)
	var denom := 2.0 * tan(deg_to_rad(clampf(cam.fov, 5.0, 170.0) * 0.5))
	var px_to_dist := lines / maxf(denom, 0.01)
	var d1 := clampf(px_to_dist / (LOD_DIST_PX_1 / scale), LOD_D1_MIN, LOD_D1_MAX)
	var d2 := clampf(px_to_dist / (LOD_DIST_PX_2 / scale), d1 + LOD_D2_GAP, LOD_D2_MAX)
	return Vector2(d1, d2)


## Character-anchored LOD cutoffs in tiles: x = LOD0->LOD1, y = LOD1->LOD2.
static func character_thresholds(quality := "") -> Vector2:
	if not ItemModels.item_geom_lod or ModelLods.full_detail:
		return Vector2(INF, INF)
	var scale := _lod_scale(quality)
	var d1 := clampf(CHAR_LOD_D1 * scale, LOD_D1_MIN, LOD_D1_MAX)
	var d2 := clampf(CHAR_LOD_D2 * scale, d1 + LOD_D2_GAP, LOD_D2_MAX)
	return Vector2(d1, d2)


## Character-anchored cutoffs (character_thresholds) bounded by the zoom (--item-lod-bands=zoom): an
## item `r` tiles from the character is about sqrt(r^2 + D^2) from a camera D tiles from it, so the band
## edges become the radii where that distance reaches the camera cutoffs (LOD_DIST_PX_1 / _2 pixels a tile).
## Zoomed in the character's own cutoffs win; zoomed out to under 18 px a tile every item is in the far
## band (the 10-triangle proxy box or the icon card).
static func zoom_character_thresholds(cam: Camera3D, vp_h: float, anchor: Vector3, quality := "") -> Vector2:
	var th := character_thresholds(quality)
	if lod_bands_mode != "zoom" or cam == null or not is_instance_valid(cam) or anchor == Vector3.INF or not is_finite(th.x) or not is_finite(th.y):
		return th
	var scale := _lod_scale(quality)
	var lines := minf(maxf(vp_h, 1.0), MAX_LOD_LINES)
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		var px := lines / maxf(cam.size, 0.01)
		if px < LOD_DIST_PX_2 / scale:
			return Vector2(0.0, 0.0)
		if px < LOD_DIST_PX_1 / scale:
			return Vector2(0.0, th.y)
		return th
	var cam_d := floorf(cam.global_position.distance_to(anchor) / LOD_ZOOM_STEP) * LOD_ZOOM_STEP
	var px_to_dist := lines / maxf(2.0 * tan(deg_to_rad(clampf(cam.fov, 5.0, 170.0) * 0.5)), 0.01)
	var c1 := px_to_dist / (LOD_DIST_PX_1 / scale)
	var c2 := px_to_dist / (LOD_DIST_PX_2 / scale)
	var r1 := sqrt(maxf(0.0, c1 * c1 - cam_d * cam_d))
	var r2 := sqrt(maxf(0.0, c2 * c2 - cam_d * cam_d))
	var d1 := minf(th.x, r1)
	var d2 := minf(th.y, r2)
	if d1 < 1.0:
		d1 = 0.0
	if d2 < 1.0:
		d2 = 0.0
	return Vector2(d1, maxf(d2, d1))


## Anchors item contact shadows around the character (`active = true`) or restores view-pixel fade.
static func update_contact_anchor(pos: Vector3, active: bool) -> void:
	var th := character_thresholds()
	var d1 := th.x if is_finite(th.x) and th.x > 0.0 else CHAR_LOD_D1
	if active == _contact_anchor_on and absf(d1 - _contact_anchor_d1) < 0.05 \
			and (not active or pos.distance_squared_to(_contact_anchor_pos) <= 0.0625):
		return
	_contact_anchor_on = active
	_contact_anchor_pos = pos
	_contact_anchor_d1 = d1
	var fade_to := d1
	var fade_from := d1 * 0.65
	for m in _contact_materials:
		m.set_shader_parameter("use_anchor", active)
		if active and pos != Vector3.INF:
			m.set_shader_parameter("anchor_pos", pos)
		m.set_shader_parameter("anchor_fade_from", fade_from)
		m.set_shader_parameter("anchor_fade_to", fade_to)


static func _lattice_variants_arg() -> String:
	var mode := "close"
	for arg in Switches.args():
		if arg.begins_with("--lattice-variants="):
			var v := arg.get_slice("=", 1)
			if v == "close" or v == "all" or v == "off":
				mode = v
	return mode


## --item-models=off|on, --belt-item-contact, --lattice-variants, --item-shadow-proxy, --item-lod-mode,
## --item-lod-blend, --item-lod2 (wins for that run).
static func configure_from_command_line() -> void:
	for arg in Switches.args():
		if arg.begins_with("--item-models="):
			use_models = arg.get_slice("=", 1) != "off"
		elif arg.begins_with("--belt-item-contact="):
			var v := arg.get_slice("=", 1)
			contact_allowed = v != "off"
			contact_flip = v == "flip"
		elif arg.begins_with("--lattice-variants="):
			var v := arg.get_slice("=", 1)
			if v == "close" or v == "all" or v == "off":
				lattice_variants_mode = v
		elif arg.begins_with("--item-shadow-proxy="):
			shadow_proxy_enabled = arg.get_slice("=", 1) != "off"
		elif arg.begins_with("--item-lod-mode="):
			var v := arg.get_slice("=", 1)
			if v == "global" or v == "distance":
				lod_mode = v
		elif arg.begins_with("--item-lod-blend="):
			lod_blend = arg.get_slice("=", 1) != "off"
		elif arg.begins_with("--item-lod-split="):
			lod_split = arg.get_slice("=", 1) != "off"
		elif arg.begins_with("--item-lod2="):
			var v := arg.get_slice("=", 1)
			if v == "icon" or v == "proxy":
				ItemModels.lod2_mode = v


## Pixels a 1x1 tile covers at `ref_pos` for `cam`, capped at MAX_LOD_LINES lines of `vp_h`.
static func tile_pixels(cam: Camera3D, ref_pos: Vector3, vp_h: float) -> float:
	if cam == null:
		return 64.0
	var h := minf(vp_h, MAX_LOD_LINES)
	if h <= 0.0:
		return 64.0
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		return h / maxf(cam.size, 0.01)
	var dist := maxf(cam.global_position.distance_to(ref_pos), 0.1)
	return h / (2.0 * dist * tan(deg_to_rad(cam.fov * 0.5)))


## A slight turn for one item, the same every frame: `seed` is its unique id, or anything
## else that stays put (a position on the ground, an inserter's unit number).
static func yaw_for(seed: int) -> float:
	return (posmod(hash(seed), 2001) / 1000.0 - 1.0) * MAX_YAW


## The one turn every loose item is drawn with (radians about +Y): on belts near (belt_items.gd) and
## far (belt_lanes.gd), on the ground, in hands; a model, a card or a block; `copy` its place in a
## pile (0 the bottom or a lone item), each copy PILE_TURN more than the one under it.
static func turn_for(seed: int, copy := 0) -> float:
	return yaw_for(seed) + PILE_TURN * copy


## The turn of an item on a packed lane (belt_lattice.gd, drawn by belt_path.gdshaderinc's
## belt_lattice_turn, which this follows step for step): `who` it is along its run (only its low 20 bits
## count) and the run's seed, in the same range as yaw_for and the same pile rule. A lattice's slots slide
## and wrap, so a slot can't keep a turn of its own: the item it carries is who the shader works out.
static func lattice_turn(who: int, run: int, copy := 0) -> float:
	return (float(_lattice_hash(who, run) % 2001) / 1000.0 - 1.0) * MAX_YAW + PILE_TURN * copy


## lattice_turn's and lattice_variant's hash (a shader's uint steps).
static func _lattice_hash(who: int, run: int) -> int:
	var x := ((who & 0xFFFFF) + (run & 0xFFFFFFFF) * 2654435769) & 0xFFFFFFFF
	x = x ^ (x >> 16)
	x = _mul32(x, 2146121005)
	x = x ^ (x >> 15)
	x = _mul32(x, 2221713035)
	x = x ^ (x >> 16)
	return x


## a * b modulo 2^32, as a shader's uint (a and b below 2^32; GDScript's int is 64 bits).
static func _mul32(a: int, b: int) -> int:
	return (a * (b & 0xFFFF) + (((a * (b >> 16)) & 0xFFFF) << 16)) & 0xFFFFFFFF


func reset() -> void:
	for mmi in _kinds.values():
		mmi.queue_free()
	for smmi in _shadow_kinds.values():
		smmi.queue_free()
	_kinds.clear()
	_shadow_kinds.clear()
	_shadow_proxied.clear()
	_record_params.clear()
	_record_counts.clear()
	_shadow_material = null
	_shadow_cam_sent = Vector3.INF
	_shadow_max_sent = -1.0
	_shadow_cam_latest = Vector3.ZERO
	_shadow_max_latest = -1.0
	_lift.clear()
	_turns.clear()
	_pile.clear()
	_buffers.clear()
	_materials.clear()
	_lod_materials.clear()
	_lod_cam_sent = Vector3.INF
	_loading.clear()
	_bounded.clear()
	_lat_variants.clear()
	_raw_models.clear()
	_dist_lods.clear()
	_split_lods.clear()
	_mv_buffers.clear()
	_mv_state.clear()
	_mv_deferred.clear()
	_needs_identity.clear()
	_mv_last_hash.clear()
	_fast_invalidate()
	mv_mode = false
	_lod_bounds = AABB()
	_has_lod_bounds = false
	_lod_band_mask = 7
	_lod0_cache.clear()
	_lod1_cache.clear()
	_lod2_cache.clear()
	_lod2_waiting.clear()
	lattice_variants_active = lattice_variants_mode != "off"
	lod_tier = 0
	_forced_lod_seen = -1
	_lod_blend_seen = lod_blend
	epoch += 1


func kind_count() -> int:
	return _kinds.size()


## Sum of visible_instance_count across base kinds (excludes extra lattice variant duplicates).
func visible_item_count() -> int:
	var total := 0
	for id in _kinds:
		var kid := int(id)
		if record_tex == 1 and variant_of(kid) > 0:
			continue
		if _record_counts.has(kid):
			total += int(_record_counts[kid])
		else:
			total += (_kinds[id] as MultiMeshInstance3D).multimesh.visible_instance_count
	return total


## `groups`: item id -> Array of Vector3, where each item's base (a card's centre) goes.
## `yaws`: item id -> Array of floats (radians) in the same order, from turn_for(); missing
## entries draw unturned. Nothing glides.
func draw(groups: Dictionary, yaws := {}) -> void:
	begin()
	for id in _kinds:
		if not groups.has(id):
			_kinds[id].multimesh.visible_instance_count = 0
	for id in groups:
		var positions: Array = groups[id]
		var n := positions.size()
		var buf := take(id, n)
		var turns: Array = yaws.get(id, [])
		var up := lift(id)
		var o := 0
		for i in n:
			var a: float = turns[i] if i < turns.size() else 0.0
			write(buf, o, positions[i] + up, cos(a), sin(a), Vector3.ZERO)
			o += STRIDE
		commit(id, buf, n)


# For callers that keep each item in its own slot (belt_items.gd): begin(), then per kind take()
# its buffer, write() new items' slots, clear_slot() emptied ones, move() the rest, and commit() it.
# `epoch` changes whenever the buffers are dropped (then every slot must be written again).


## Applies a change of Settings → Items in 3D (models on or off), and of an item's model file with
## the packs (ItemModels.generation): every kind is made again, dressed with the current file.
func begin() -> void:
	var gen := ItemModels.current_generation() if ItemModels.kinds_follow else _models_gen
	if _look != _look_changes or _models_gen != gen:
		_look = _look_changes
		_models_gen = gen
		reset()


## The buffer of an item kind, with room for n items. Take it out, fill it, commit it.
func take(item_id: int, n: int) -> PackedFloat32Array:
	var mm := _kind(item_id).multimesh
	if mm.instance_count < n:
		mm.visible_instance_count = 0
		mm.instance_count = maxi(n, mm.instance_count * 2)
	# Out of the dictionary while it is written, so writing doesn't copy it.
	var buf: PackedFloat32Array = _buffers.get(item_id, PackedFloat32Array())
	_buffers.erase(item_id)
	if buf.size() != mm.instance_count * STRIDE:
		buf.resize(mm.instance_count * STRIDE)
	return buf


func commit(item_id: int, buf: PackedFloat32Array, n: int) -> void:
	var mm := _kind(item_id).multimesh
	mm.buffer = buf
	mm.visible_instance_count = n
	_buffers[item_id] = buf


## Makes the kind's MultiMesh now (so lift() and turns() know it), for buffers filled elsewhere.
func prepare(item_id: int) -> void:
	_kind(item_id)


## A whole buffer filled elsewhere (belt_items.gd, on a worker thread): `cap` instances, the first
## n drawn.
func put(item_id: int, buf: PackedFloat32Array, n: int, cap: int) -> void:
	var mm := _kind(item_id).multimesh
	if mm.instance_count != cap:
		mm.visible_instance_count = 0
		mm.instance_count = cap
	mm.buffer = buf
	mm.visible_instance_count = n


func _has_visible_records(item_id: int) -> bool:
	return not _record_counts.has(item_id) or int(_record_counts[item_id]) > 0


## Syncs record buffer, bounds, visible count and shader instance parameters onto a record-drawn MultiMeshInstance3D.
func _sync_records_mmi(mmi: MultiMeshInstance3D, base: int, n: int, cap: int, bounds: AABB) -> void:
	var mm := mmi.multimesh
	if mm.instance_count != cap or _needs_identity.has(mmi):
		_needs_identity.erase(mmi)
		_mv_last_hash.erase(mmi)
		if mm.instance_count != cap:
			mm.visible_instance_count = 0
			mm.instance_count = cap
		if cap > 0:
			mm.buffer = _identity(cap)
	mm.custom_aabb = bounds
	mm.visible_instance_count = n
	mmi.set_instance_shader_parameter("belt_base", base)
	if record_tex != 0:
		mmi.set_instance_shader_parameter("belt_tex", record_tex)


func _sync_mv_mmi(mmi: MultiMeshInstance3D, buf: PackedFloat32Array, visible_count: int, cap: int, bounds: AABB) -> void:
	var mm := mmi.multimesh
	var first_mv := not _needs_identity.has(mmi)
	if mm.instance_count != cap:
		mm.visible_instance_count = 0
		mm.instance_count = cap
		first_mv = true
		_mv_last_hash.erase(mmi)
	if first_mv:
		mm.custom_aabb = bounds
		mmi.set_instance_shader_parameter("belt_base", -2)
		if record_tex != 0:
			mmi.set_instance_shader_parameter("belt_tex", record_tex)
		_needs_identity[mmi] = true
	elif mm.custom_aabb != bounds:
		mm.custom_aabb = bounds
	var skip_empty := mv_skip_clean and visible_count == 0 and mm.visible_instance_count == 0
	if not skip_empty and cap > 0 and buf.size() == cap * STRIDE:
		if not mv_skip_clean:
			RenderingServer.multimesh_set_buffer(mm.get_rid(), buf)
			mv_uploads += 1
		else:
			var sig := hash(buf)
			if first_mv or not _mv_last_hash.has(mmi) or int(_mv_last_hash[mmi]) != sig:
				RenderingServer.multimesh_set_buffer(mm.get_rid(), buf)
				mv_uploads += 1
				_mv_last_hash[mmi] = sig
	if mm.visible_instance_count != visible_count:
		mm.visible_instance_count = visible_count


func _reapply_mv(item_id: int, mmi: MultiMeshInstance3D) -> void:
	if not _mv_handles(item_id):
		return
	var mv: Variant = _mv_buffers.get(item_id)
	if not (mv is Array):
		return
	var arr := mv as Array
	var buf := PackedFloat32Array()
	if arr[0] is PackedFloat32Array:
		buf = arr[0] as PackedFloat32Array
	elif mv_buf_getter.is_valid():
		var src_id := (band_of(item_id) * BAND_STEP + item_of(item_id)) if record_tex == 1 else item_id
		buf = mv_buf_getter.call(src_id) as PackedFloat32Array
	_needs_identity.erase(mmi)
	_mv_last_hash.erase(mmi)
	_sync_mv_mmi(mmi, buf, int(arr[1]), int(arr[2]), arr[3] as AABB)


## A kind drawn from CPU-evaluated MultiMesh buffers (`belt_base = -2`, BeltMv) for temporal motion vectors.
## `changed` (BeltMv's native change flag): -1 hashes `buf` to find an unchanged one, as before; 0/1 says
## whether `buf` changed since the last put (no hash: 0 takes the same early return when the kind's buffer
## was uploaded before, and a fast upload leaves MV_SENT in `_mv_last_hash` so no real hash matches it).
## Returns 2 when BeltItemsNative's fast path uploaded `buf` (BeltMv's native put may then follow it), else 0.
func put_mv(item_id: int, buf: PackedFloat32Array, visible_count: int, cap: int, bounds: AABB, ping_pong := false, changed := -1) -> int:
	mv_mode = true
	if _fast != null and mv_buf_getter.is_valid():
		var sig := 0
		var has_sig := false
		if mv_skip_clean and visible_count > 0 and cap > 0 and buf.size() == cap * STRIDE and _kinds.has(item_id):
			var fast_mmi: MultiMeshInstance3D = _kinds[item_id]
			var same := false
			if changed < 0:
				sig = hash(buf)
				has_sig = true
				mv_hash_passes += 1
				same = _mv_last_hash.has(fast_mmi) and int(_mv_last_hash[fast_mmi]) == sig
			else:
				same = changed == 0 and _mv_last_hash.has(fast_mmi)
			if fast_mmi.visible and not _mv_deferred.has(item_id) and same \
					and fast_mmi.multimesh.instance_count == cap \
					and fast_mmi.multimesh.custom_aabb == bounds and _mv_buffers.has(item_id):
				var prev_st: Array = _mv_state.get(item_id, [])
				var prev_mask := int(prev_st[1]) if prev_st.size() > 1 else -1
				if prev_st.size() > 0 and bool(prev_st[0]) and (not _dist_lods.has(item_id) or prev_mask == _lod_band_mask):
					if fast_mmi.multimesh.visible_instance_count != visible_count:
						fast_mmi.multimesh.visible_instance_count = visible_count
					_record_counts[item_id] = maxi(visible_count / 2 if ping_pong else visible_count, 0)
					(_mv_buffers[item_id] as Array)[1] = visible_count
					return 0
		var fast: int = _fast.try_put(item_id, buf, visible_count, cap, bounds, _lod_band_mask, _fast_epoch)
		if fast != 0:
			# (Steady state, done natively: only the bookkeeping that follows the count is left.)
			_record_counts[item_id] = maxi(visible_count / 2 if ping_pong else visible_count, 0)
			(_mv_buffers[item_id] as Array)[1] = visible_count
			if fast == 2:
				mv_uploads += 1
				if mv_skip_clean and _kinds.has(item_id):
					if changed >= 0:
						_mv_last_hash[_kinds[item_id]] = MV_SENT
					else:
						_mv_last_hash[_kinds[item_id]] = sig if has_sig else hash(buf)
			return fast if changed >= 0 or not mv_skip_clean else 0
	var logical_n := visible_count / 2 if ping_pong else visible_count
	_record_counts[item_id] = maxi(logical_n, 0)
	var stored_buf: Variant = null if mv_buf_getter.is_valid() else buf
	var mv_entry := [stored_buf, visible_count, cap, bounds, ping_pong]
	var prev_state: Array = _mv_state.get(item_id, [])
	var first_entry := not _mv_buffers.has(item_id)
	_mv_buffers[item_id] = mv_entry
	var mmi := _kind(item_id)
	_bounded[item_id] = true
	var vis_nonzero := visible_count > 0
	var prev_nonzero := bool(prev_state[0]) if prev_state.size() > 0 else false
	var prev_mask := int(prev_state[1]) if prev_state.size() > 1 else -1
	if not _loading.has(item_id) and (first_entry or prev_nonzero != vis_nonzero or (_dist_lods.has(item_id) and prev_mask != _lod_band_mask)):
		if not vis_nonzero:
			mmi.visible = false
		elif _dist_lods.has(item_id):
			_apply_dist_subset(item_id)
		else:
			mmi.visible = not (record_tex == 1 and variant_of(item_id) > 0 and not lattice_variants_active)
	if not mmi.visible or _loading.has(item_id):
		_mv_deferred[item_id] = true
		if visible_count == 0 and mmi.multimesh.visible_instance_count != 0:
			mmi.multimesh.visible_instance_count = 0
	else:
		_mv_deferred.erase(item_id)
		_sync_mv_mmi(mmi, buf, visible_count, cap, bounds)
	if not _has_lod_bounds and bounds.has_volume():
		_lod_bounds = bounds
		_has_lod_bounds = true
	var band := band_of(item_id)
	var allow_lat_vars := record_tex == 1 and lattice_variants_mode != "off" and (band == 0 or lattice_variants_mode == "all")
	var variants := variant_count(item_of(item_id) if allow_lat_vars and variant_of(item_id) == 0 else -1) if allow_lat_vars else 0
	var prev_variants := int(_lat_variants.get(item_id, 0))
	var active_now := false
	if variants > 1 or prev_variants > 1:
		active_now = lattice_variants_active if lattice_variants_mode != "all" else true
		if lattice_variants_mode == "off":
			active_now = false
		var prev_var_count := int(prev_state[2]) if prev_state.size() > 2 else -1
		var prev_active := bool(prev_state[3]) if prev_state.size() > 3 else false
		if first_entry or prev_var_count != variants or prev_active != active_now:
			mmi.set_instance_shader_parameter("belt_variants", variants if active_now else 0)
			mmi.set_instance_shader_parameter("belt_variant", 0)
		for v in range(1, variants):
			var key := item_id + v * VARIANT_STEP
			_record_counts[key] = maxi(logical_n, 0)
			if not active_now or not vis_nonzero:
				_mv_buffers.erase(key)
				_mv_deferred.erase(key)
				var hidden_vm: MultiMeshInstance3D = _kinds.get(key)
				if hidden_vm != null and hidden_vm.visible:
					hidden_vm.visible = false
				continue
			var first_vm := not _mv_buffers.has(key)
			_mv_buffers[key] = mv_entry
			var vm := _kind(key)
			_bounded[key] = true
			if first_vm or prev_var_count != variants:
				vm.set_instance_shader_parameter("belt_variants", variants)
				vm.set_instance_shader_parameter("belt_variant", v)
			if not _loading.has(key):
				var entry_v: Variant = _dist_lods.get(key)
				if entry_v is Dictionary and bool((entry_v as Dictionary).get("extra_lat", false)):
					vm.visible = (_lod_band_mask & 1) != 0
				else:
					vm.visible = true
			if not vm.visible or _loading.has(key):
				_mv_deferred[key] = true
				if visible_count == 0 and vm.multimesh.visible_instance_count != 0:
					vm.multimesh.visible_instance_count = 0
			else:
				_mv_deferred.erase(key)
				_sync_mv_mmi(vm, buf, visible_count, cap, bounds)
		for v in range(maxi(variants, 1), prev_variants):
			var key := item_id + v * VARIANT_STEP
			_mv_buffers.erase(key)
			_mv_deferred.erase(key)
			var old_vm: MultiMeshInstance3D = _kinds.get(key)
			if old_vm != null:
				old_vm.visible = false
		_lat_variants[item_id] = variants
	_mv_state[item_id] = [vis_nonzero, _lod_band_mask, variants, active_now]
	if _fast != null and mv_buf_getter.is_valid() and variants <= 1 and prev_variants <= 1 and not _loading.has(item_id) 			and mmi.visible and not _mv_deferred.has(item_id) and not _needs_identity.is_empty() and _needs_identity.has(mmi) 			and cap > 0 and mmi.multimesh.instance_count == cap:
		_fast.register_kind(item_id, mmi.get_instance_id(), cap, _lod_band_mask, vis_nonzero, bounds, _fast_epoch)
	elif _fast != null:
		_fast.unregister_kind(item_id)
	return 0


## Restores one record-drawn kind (and any lattice variants) back to GPU record mode (`belt_base >= 0`).
func restore_kind(item_id: int) -> void:
	_fast_invalidate()
	_mv_buffers.erase(item_id)
	_mv_state.erase(item_id)
	_mv_deferred.erase(item_id)
	if record_tex == 1:
		var prev_v := int(_lat_variants.get(item_id, 0))
		for v in range(1, prev_v):
			var key := item_id + v * VARIANT_STEP
			_mv_buffers.erase(key)
			_mv_state.erase(key)
			_mv_deferred.erase(key)
	var rp_v: Variant = _record_params.get(item_id)
	if rp_v is Array:
		var rp := rp_v as Array
		_apply_records(item_id, int(rp[0]), int(rp[1]), int(rp[2]), rp[3] as AABB, true)


## Restores all record-drawn MultiMeshes back to GPU record mode (`belt_base >= 0`, identity buffer).
func restore_records() -> void:
	mv_mode = false
	_fast_invalidate()
	_mv_buffers.clear()
	_mv_state.clear()
	_mv_deferred.clear()
	_mv_last_hash.clear()
	for id_v in _record_params.keys():
		var kid := int(id_v)
		if record_tex == 1 and variant_of(kid) > 0:
			continue
		var rp: Array = _record_params[id_v]
		put_records(kid, int(rp[0]), int(rp[1]), int(rp[2]), rp[3] as AABB)


## A kind drawn from records (belt_items.gd, belt_records.gd): `cap` instances reading records `base`
## on, the first n drawn. Its buffer is only identity transforms, written when its size changes.
func put_records(item_id: int, base: int, n: int, cap: int, bounds: AABB) -> void:
	_apply_records(item_id, base, n, cap, bounds, false)


func _apply_records(item_id: int, base: int, n: int, cap: int, bounds: AABB, force_restore: bool) -> void:
	_record_counts[item_id] = maxi(n, 0)
	_record_params[item_id] = [base, n, cap, bounds]
	var mmi := _kind(item_id)
	var skip_mv := not force_restore and _mv_handles(item_id) and _mv_buffers.has(item_id)
	if not skip_mv:
		_sync_records_mmi(mmi, base, n, cap, bounds)
	_bounded[item_id] = true
	if not skip_mv and not _loading.has(item_id):
		if n <= 0:
			mmi.visible = false
		elif _dist_lods.has(item_id):
			_apply_dist_subset(item_id)
		else:
			mmi.visible = not (record_tex == 1 and variant_of(item_id) > 0 and not lattice_variants_active)
	if not _has_lod_bounds and bounds.has_volume():
		_lod_bounds = bounds
		_has_lod_bounds = true
	if use_shadow_proxy and not (record_tex == 1 and variant_of(item_id) > 0):
		var smmi: MultiMeshInstance3D = _shadow_kinds.get(item_id)
		if smmi != null:
			_sync_records_mmi(smmi, base, n, cap, bounds)
			smmi.visible = _shadow_proxy_vis(item_id, n)
	if skip_mv:
		return
	# A packed lane's item is someone only in the shader (belt_path.gdshaderinc): each of the item's variants
	# is a kind of its own over the same records, drawing the slots whose item is its variant
	# (belt_lattice_variant; --model-variants=off or --lattice-variants=off: the first alone).
	var band := band_of(item_id)
	var allow_lat_vars := record_tex == 1 and lattice_variants_mode != "off" and (band == 0 or lattice_variants_mode == "all")
	var variants := variant_count(item_of(item_id) if allow_lat_vars and variant_of(item_id) == 0 else -1) if allow_lat_vars else 0
	var prev_variants := int(_lat_variants.get(item_id, 0))
	if variants > 1 or prev_variants > 1:
		var active_now := lattice_variants_active if lattice_variants_mode != "all" else true
		if lattice_variants_mode == "off":
			active_now = false
		mmi.set_instance_shader_parameter("belt_variants", variants if active_now else 0)
		mmi.set_instance_shader_parameter("belt_variant", 0)
		for v in range(1, variants):
			var key := item_id + v * VARIANT_STEP
			put_records(key, base, n, cap, bounds)
			var vm: MultiMeshInstance3D = _kinds[key]
			vm.set_instance_shader_parameter("belt_variants", variants)
			vm.set_instance_shader_parameter("belt_variant", v)
			if not _loading.has(key):
				var entry_v: Variant = _dist_lods.get(key)
				if entry_v is Dictionary and bool((entry_v as Dictionary).get("extra_lat", false)):
					vm.visible = active_now and n > 0 and (_lod_band_mask & 1) != 0
				else:
					vm.visible = active_now and n > 0
		for v in range(maxi(variants, 1), prev_variants):
			var old_vm: MultiMeshInstance3D = _kinds.get(item_id + v * VARIANT_STEP)
			if old_vm != null:
				old_vm.visible = false
		_lat_variants[item_id] = variants


## Toggles extra lattice variant MultiMeshes (v >= 1) and variant 0's `belt_variants` uniform.
func set_lattice_variants_active(active: bool) -> void:
	if lattice_variants_mode == "off":
		active = false
	elif lattice_variants_mode == "all":
		active = true
	if active == lattice_variants_active:
		return
	lattice_variants_active = active
	_fast_invalidate()
	for item_id in _lat_variants:
		var variants := int(_lat_variants[item_id])
		if variants <= 1:
			continue
		var base_mmi: MultiMeshInstance3D = _kinds.get(item_id)
		if base_mmi != null:
			base_mmi.set_instance_shader_parameter("belt_variants", variants if active else 0)
		for v in range(1, variants):
			var key := int(item_id) + v * VARIANT_STEP
			var vm: MultiMeshInstance3D = _kinds.get(key)
			if vm != null and not _loading.has(key):
				var has_rec := _has_visible_records(key)
				var entry_v: Variant = _dist_lods.get(key)
				if entry_v is Dictionary and bool((entry_v as Dictionary).get("extra_lat", false)):
					vm.visible = active and has_rec and (_lod_band_mask & 1) != 0
				else:
					vm.visible = active and has_rec
				if active and has_rec and _mv_handles(key) and _mv_buffers.has(item_id):
					_mv_buffers[key] = _mv_buffers[item_id]
					_mv_deferred.erase(key)
					_reapply_mv(key, vm)
					vm.set_instance_shader_parameter("belt_variants", variants)
					vm.set_instance_shader_parameter("belt_variant", v)
				elif vm.visible and _mv_deferred.has(key):
					_mv_deferred.erase(key)
					_reapply_mv(key, vm)


var _lat_variants := {}  # (record_tex 1) item id -> how many variant kinds its records are drawn with


## Every record-drawn kind's bounds: where its items can be (the square they come from).
func set_bounds(bounds: AABB) -> void:
	if bounds.has_volume():
		_lod_bounds = bounds
		_has_lod_bounds = true
	for id in _bounded:
		var mmi: MultiMeshInstance3D = _kinds.get(id)
		if mmi != null:
			mmi.multimesh.custom_aabb = bounds
		var smmi: MultiMeshInstance3D = _shadow_kinds.get(id)
		if smmi != null:
			smmi.multimesh.custom_aabb = bounds
		if _record_params.has(id):
			(_record_params[id] as Array)[3] = bounds
		if _mv_buffers.has(id):
			(_mv_buffers[id] as Array)[3] = bounds


var _bounded := {}
static var _identities := {}
## Which records texture put_records' kinds read: 0 f3d_belt_records, 1 f3d_belt_lattice (belt_lattice.gd).
var record_tex := 0
var mv_mode := false
var mv_max_band := 1
var mv_uploads := 0
var mv_buf_getter: Callable
## (--native-belt-items=off: the old path) BeltItemsNative's steady-state put_mv, or null.
static var use_native_items := Switches.on("--native-belt-items")
## --mv-skip-clean=off: always upload MultiMesh buffers even when empty (0->0) or unchanged.
static var mv_skip_clean := Switches.on("--mv-skip-clean")
var _fast: Variant = null
var _fast_epoch := 0


func _init() -> void:
	if use_native_items and NativeLibrary.ensure() and ClassDB.class_exists(&"BeltItemsNative"):
		_fast = ClassDB.instantiate(&"BeltItemsNative")
var _mv_buffers := {}
var _mv_state := {}
var _mv_deferred := {}
var _needs_identity := {}
var _mv_last_hash := {}
## Test counter: hash(buf) passes made in put_mv's fast path.
static var mv_hash_passes := 0


## Drops what the native fast path knows (a change it can't see: kinds made again, variants toggled).
func _fast_invalidate() -> void:
	_fast_epoch += 1


func _mv_handles(item_id: int) -> bool:
	return mv_mode and band_of(item_id) <= mv_max_band


## n instances with no turn, no move (doubling copies, not a loop per instance).
static func _identity(n: int) -> PackedFloat32Array:
	var buf: PackedFloat32Array = _identities.get(n, PackedFloat32Array())
	if not buf.is_empty():
		return buf
	buf = PackedFloat32Array([1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	while buf.size() < n * STRIDE:
		buf.append_array(buf.slice(0, mini(buf.size(), n * STRIDE - buf.size())))
	_identities[n] = buf
	return buf


## What raises this kind above the position it is given (blocks stand on it).
func lift(item_id: int) -> Vector3:
	return _lift.get(item_id, Vector3.ZERO)


## How far apart a pile's copies are for this kind: a model's or block's height, a card's CARD_PILE.
func pile_step(item_id: int) -> float:
	return _pile.get(item_id, CARD_PILE)


## Whether this kind is drawn as a model (every kind turns by turn_for(), this says only which look).
func turns(item_id: int) -> bool:
	return _turns.has(item_id)


## Whether the kind has its look (model, card or block): until then lift(), pile_step() and turns()
## answer for a card, and a model still read on a thread would be taken for one.
func dressed(item_id: int) -> bool:
	return _kinds.has(item_id) and not _loading.has(item_id)


## One item's slot from `o`: turned by the angle whose cosine and sine are c and s, at p (with
## the kind's lift() added by the caller), gliding by `step`.
static func write(buf: PackedFloat32Array, o: int, p: Vector3, c: float, s: float, step: Vector3) -> void:
	buf[o] = c
	buf[o + 1] = 0.0
	buf[o + 2] = s
	buf[o + 3] = p.x
	buf[o + 4] = 0.0
	buf[o + 5] = 1.0
	buf[o + 6] = 0.0
	buf[o + 7] = p.y
	buf[o + 8] = -s
	buf[o + 9] = 0.0
	buf[o + 10] = c
	buf[o + 11] = p.z
	buf[o + 12] = step.x
	buf[o + 13] = step.y
	buf[o + 14] = step.z
	buf[o + 15] = 0.0


## Only the position and glide of a slot written before.
static func move(buf: PackedFloat32Array, o: int, p: Vector3, step: Vector3) -> void:
	buf[o + 3] = p.x
	buf[o + 7] = p.y
	buf[o + 11] = p.z
	buf[o + 12] = step.x
	buf[o + 13] = step.y
	buf[o + 14] = step.z


## An empty slot: scaled to nothing.
static func clear_slot(buf: PackedFloat32Array, o: int) -> void:
	for k in STRIDE:
		buf[o + k] = 0.0


## The texture of the belt items' paths (belt_items.gd), for every material from now on.
func set_paths(texture: Texture2D) -> void:
	_paths = texture
	for m: ShaderMaterial in _materials:
		m.set_shader_parameter("belt_paths", texture)


## The item a kind key is for (icon_key()'s keys are below zero, variant_key()'s VARIANT_STEP and up,
## distance-band split keys BAND_STEP and up).
static func band_of(key: int) -> int:
	return key / BAND_STEP if key >= 0 else 0


static func item_of(key: int) -> int:
	return (key % BAND_STEP) % VARIANT_STEP if key >= 0 else -key - 1


## A kind key's variant of its item's model (variant_key), 0 for the first.
static func variant_of(key: int) -> int:
	return (key % BAND_STEP) / VARIANT_STEP if key >= 0 else 0


static func band_key(key: int, band: int) -> int:
	return key + band * BAND_STEP if key >= 0 and band > 0 else key


## Kind keys of an item's other model variants: item id + variant * VARIANT_STEP.
const VARIANT_STEP := 1 << 20
## Kind keys for distance-band buckets (0 near, 1 mid, 2 far): base_key + band * BAND_STEP.
const BAND_STEP := 1 << 28


## The kind key that draws an item with the variant of its model (ItemModels.variant_count: its
## `<item>-1.glb`, ...) a seed picks (ModelPacks.variant_seed: a ground item's position); the item id
## itself for its first, or with models off.
func variant_key(item_id: int, seed: int) -> int:
	var n := variant_count(item_id)
	return item_id + ItemModels.ModelPacks.variant_pick(n, seed) * VARIANT_STEP if n > 1 else item_id


## How many variants item `item_id`'s model has (ItemModels.variant_count), 0 for an icon kind, a
## variant's key, with models off or the item not known yet.
func variant_count(item_id: int) -> int:
	if item_id < 0 or item_id >= VARIANT_STEP or not use_models or protos == null:
		return 0
	if _variant_counts_version != ItemModels.ModelPacks.version:
		_variant_counts.clear()
		_variant_counts_version = ItemModels.ModelPacks.version
	if not _variant_counts.has(item_id):
		var item := protos.item_name(item_id)
		if item == "":
			return 0  # not known yet: its first, asked again next time
		_variant_counts[item_id] = ItemModels.variant_count(item)
	return int(_variant_counts[item_id])


## Which of `count` variants an item on a belt is (0 for none or one): `who` it is and its run's seed, as
## its turn (lattice_turn: a simulated item's number or unique id, a packed lane's slot's item, which
## belt_path.gdshaderinc's belt_lattice_variant works out the same way), so an item keeps its variant all
## along, from simulated lane to packed lane and back.
static func lattice_variant(who: int, run: int, count: int) -> int:
	return 0 if count < 2 else (_lattice_hash(who, run) >> 8) % count


var _variant_counts := {}  # item id -> how many variants its model has (variant_key)
var _variant_counts_version := -1


## The kind key that draws an item as its icon even when it has a model.
static func icon_key(item_id: int) -> int:
	return -item_id - 1


## Main-thread time of a new kind's parts (--stutter-probe shows them as w_ic_<key>; kept only while it
## runs, Probing.on): look (its model or icon looked up, the icon index and the mods scanned the first
## time), dress (its material).
static var prof := {}
const Probing := preload("res://scripts/debug/probing.gd")


static func _prof(key: String, t0: int) -> void:
	if Probing.on:
		prof[key] = int(prof.get(key, 0)) + Time.get_ticks_usec() - t0


func _kind(item_id: int) -> MultiMeshInstance3D:
	if _kinds.has(item_id):
		return _kinds[item_id]
	var item := ""
	if protos != null:
		item = protos.item_name(item_of(item_id))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.cast_shadow = _shadow_setting()
	mmi.layers = render_layers
	mmi.name = "Items_%s%s%s%s" % [item if item != "" else str(item_of(item_id)), "_icon" if item_id < 0 else "",
		"_%d" % variant_of(item_id) if variant_of(item_id) > 0 else "",
		"_b%d" % band_of(item_id) if band_of(item_id) > 0 else ""]
	add_child(mmi)
	_kinds[item_id] = mmi
	var t0 := Time.get_ticks_usec()
	var ready := _look_ready(item, item_id < 0)
	_prof("look", t0)
	if ready:
		t0 = Time.get_ticks_usec()
		_dress(item_id, item, mmi)
		_prof("dress", t0)
	else:
		# Drawn once its model or icon is read (_process); its instances are kept meanwhile.
		mm.mesh = _card()
		mmi.visible = false
		_loading[item_id] = item
	return mmi


func _shadow_setting() -> GeometryInstance3D.ShadowCastingSetting:
	return GeometryInstance3D.SHADOW_CASTING_SETTING_ON if casts_shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _shadow_tier_ok() -> bool:
	if not allow_lod or not ItemModels.item_geom_lod:
		return true
	return forced_lod_tier <= 0 if forced_lod_tier >= 0 else (lod_mode == "distance" or lod_tier == 0)


func _mmi_cast_shadow(item_id: int) -> GeometryInstance3D.ShadowCastingSetting:
	if _shadow_proxied.has(item_id) or (not _shadow_tier_ok() and _raw_models.has(item_id)):
		return GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return _shadow_setting()


func _shadow_proxy_vis(item_id: int, n: int) -> bool:
	if not casts_shadow or n <= 0:
		return false
	if lod_mode != "distance":
		return lod_tier == 0
	if not _shadow_tier_ok():
		return false  # a forced tier above 0 (debug menu) hides the proxy, as the raw model's shadow is off too
	if split_bands and lod_split:
		var band := band_of(item_id)
		if band == 1 and is_finite(_lod_d1) and _shadow_max_latest >= 0.0 and _shadow_max_latest < _lod_d1 - BAND_AABB_PAD:
			return false
		if band >= 2 and (_shadow_max_latest < 0.0 or not is_finite(_lod_d2) or _shadow_max_latest < _lod_d2 - BAND_AABB_PAD):
			return false
	return true


func _sync_shadow_proxies_visibility() -> void:
	for item_id_var in _shadow_kinds:
		var kid := int(item_id_var)
		var smmi: MultiMeshInstance3D = _shadow_kinds[item_id_var]
		smmi.visible = _shadow_proxy_vis(kid, int(_record_counts.get(kid, 1)))


func _current_lod_cam_pos() -> Vector3:
	if _lod_use_anchor and _lod_anchor_pos != Vector3.INF:
		return _lod_anchor_pos
	if _contact_anchor_on and _contact_anchor_pos != Vector3.INF and not allow_lod:
		return _contact_anchor_pos
	if is_inside_tree():
		var cam := get_viewport().get_camera_3d()
		if cam != null:
			return cam.global_position
	return Vector3.INF


static func _set_global_lod_cam(pos: Vector3) -> void:
	if pos != Vector3.INF and pos.distance_squared_to(_global_lod_cam_sent) > 0.0625:
		_global_lod_cam_sent = pos
		RenderingServer.global_shader_parameter_set("f3d_item_lod_cam", pos)


## Kinds whose model or icon is still being read: item id -> item name.
var _loading := {}
## Icons composed on worker threads: item name -> [task id, [texture]].
static var _icon_jobs := {}


## Kinds whose model or icon came are dressed for at most this long a frame, at least one a frame
## (--item-dress-usec=N; 0, the default: all at once). Tried at 1500 for the 60-95 ms frame a join's
## first kinds made at -62,-26: no gain (one kind's dress was the frame, waiting for its shader; the
## warm-up, shader_warmup.gd, is what takes that away), and belt_items.gd writes every item again each
## time a kind is dressed, so trickling them made the belts' first load take 72 s instead of 22-23.
static var dress_usec := 0
static var _dress_arg_read := false


func _process(_delta: float) -> void:
	if contact:
		_contact_follow()
	if is_inside_tree():
		var want_global := allow_lod and ItemModels.item_geom_lod and lod_mode == "distance" and (not _dist_lods.is_empty() or not _split_lods.is_empty())
		if want_global or not _lod_materials.is_empty():
			var pos := _current_lod_cam_pos()
			if want_global:
				_set_global_lod_cam(pos)
			if not _lod_materials.is_empty() and pos != Vector3.INF and pos.distance_squared_to(_lod_cam_sent) > 0.0625:
				_lod_cam_sent = pos
				for m: ShaderMaterial in _lod_materials:
					m.set_shader_parameter("lod_cam", pos)
	if not _lod2_waiting.is_empty():
		for id in _lod2_waiting.keys():
			var item: String = _lod2_waiting[id]
			if _look_ready(item, true):
				_lod2_waiting.erase(id)
				var kid := int(id)
				if _split_lods.has(kid):
					_attach_split_lod2(kid, item)
				elif _dist_lods.has(kid):
					_attach_distance_lod2(kid, item)
				elif lod_tier == 2:
					var mmi: MultiMeshInstance3D = _kinds.get(kid)
					if mmi != null:
						_apply_lod_for(kid, mmi)
	if _loading.is_empty():
		return
	if not _dress_arg_read:
		_dress_arg_read = true
		for a in Switches.args():
			if a.begins_with("--item-dress-usec="):
				dress_usec = maxi(0, int(a.substr(18)))
	var t0 := Time.get_ticks_usec()
	var done := 0
	for id in _loading.keys():
		if dress_usec > 0 and done > 0 and Time.get_ticks_usec() - t0 > dress_usec:
			break
		var item: String = _loading[id]
		var tl := Time.get_ticks_usec()
		var ready := _look_ready(item, id < 0)
		_prof("poll_look", tl)
		if not ready:
			continue
		_loading.erase(id)
		_fast_invalidate()
		var mmi: MultiMeshInstance3D = _kinds.get(id)
		if mmi != null:
			tl = Time.get_ticks_usec()
			_dress(id, item, mmi)
			_prof("poll_dress", tl)
			if Probing.on and Time.get_ticks_usec() - tl > 5000:
				print("ITEMCARDS slow dress %s (%d): %d ms, model %s" % [item, id, (Time.get_ticks_usec() - tl) / 1000, _turns.has(id)])
			var kid := int(id)
			if _dist_lods.has(kid):
				_apply_dist_subset(kid)
			else:
				mmi.visible = _has_visible_records(kid) and not (record_tex == 1 and variant_of(kid) > 0 and not lattice_variants_active)
				if mmi.visible and _mv_deferred.has(kid):
					_mv_deferred.erase(kid)
					_reapply_mv(kid, mmi)
		done += 1


## Whether an item's look is known: its model read (or none), and without one its icon. Otherwise
## they are read on threads meanwhile: on the main thread a model or a composed icon cost 10-60 ms
## the first time an item came into view (on belts, the ground, in inserters' hands).
static func _look_ready(item: String, icon := false) -> bool:
	if item == "":
		return true
	if use_models and not icon:
		if not ItemModels.ready(item):
			return false
		if ItemModels.mesh_for(item) != null:
			return true
	if not use_icons or ItemIcons.is_cached(item):
		return true
	var job: Array = _icon_jobs.get(item, [])
	if job.is_empty():
		var tp := Time.get_ticks_usec()
		ItemIcons.prepare_for_threads()
		_prof("icons_prepare", tp)
		var holder := [null]
		var load_icon := func() -> void: holder[0] = ItemIcons.load_uncached(item)
		_icon_jobs[item] = [WorkerThreadPool.add_task(load_icon, false, "item icon"), holder]
		return false
	if not WorkerThreadPool.is_task_completed(job[0]):
		return false
	WorkerThreadPool.wait_for_task_completion(job[0])
	_icon_jobs.erase(item)
	ItemIcons.store(item, job[1][0])
	return true


## Gives a kind its model, icon card or block.
func _dress(item_id: int, item: String, mmi: MultiMeshInstance3D) -> void:
	var mm := mmi.multimesh
	var t0 := Time.get_ticks_usec()
	var model: Mesh = ItemModels.mesh_for(item, variant_of(item_id)) if use_models and item_id >= 0 else null
	var texture: Texture2D = null
	if model == null and item != "" and use_icons:
		texture = ItemIcons.texture_for(item)
	_prof("d_look", t0)
	var material: ShaderMaterial
	var own: Array = []  # an own-look model's surface materials (item_models.gd dressed)
	var geom_lod := allow_lod and ItemModels.item_geom_lod
	var dist_lod := model != null and geom_lod and lod_mode == "distance"
	var want_contact := contact and not (record_tex == 1 and variant_of(item_id) > 0) and band_of(item_id) == 0
	if model != null:
		_turns[item_id] = true
		t0 = Time.get_ticks_usec()
		var box := model.get_aabb()
		_pile[item_id] = clampf(box.size.y, 0.03, 0.2)
		if not is_zero_approx(box.position.y):
			_lift[item_id] = Vector3(0.0, -box.position.y, 0.0)  # its lowest point rests on the belt
		_prof("d_aabb", t0)
		if dist_lod:
			if split_bands and lod_split:
				_dress_split_band(item_id, item, model, mmi, box, want_contact)
			else:
				_dress_distance_lod(item_id, item, model, mmi, box, want_contact)
		else:
			t0 = Time.get_ticks_usec()
			var use_lod := not geom_lod and contact and ItemModels.item_lod and ItemModels.needs_lod(model)
			mm.mesh = ItemModels.dressed_lod(model, ItemModels.ItemOwnShader, ITEM_LOD_DIST) if use_lod else ItemModels.dressed(model, ItemModels.ItemOwnShader)
			_prof("d_mesh", t0)
			t0 = Time.get_ticks_usec()
			if ItemModels.has_own(model):
				own = ItemModels.surface_materials(mm.mesh)
				if use_lod:
					var init_pos := _current_lod_cam_pos()
					for m: ShaderMaterial in own:
						_lod_materials[m] = true
						if init_pos != Vector3.INF:
							m.set_shader_parameter("lod_cam", init_pos)
			else:
				material = ItemModels.material_for(model)  # its picture's own, else the one all share
			_prof("d_material", t0)
	elif texture != null:
		t0 = Time.get_ticks_usec()
		mm.mesh = _card()
		_prof("d_mesh", t0)
		t0 = Time.get_ticks_usec()
		material = ShaderMaterial.new()
		material.shader = CardShader
		material.set_shader_parameter("icon", texture)
		_prof("d_material", t0)
	else:
		mm.mesh = _block()
		material = ItemModels.block_material(ItemIcons.color_for(item))
		_lift[item_id] = Vector3(0.0, BLOCK_SIZE.y * 0.5, 0.0)
		_pile[item_id] = BLOCK_SIZE.y
	t0 = Time.get_ticks_usec()
	if not dist_lod:
		var with_contact := _with_contact(mm.mesh, material, CONTACT_CARD if model == null and texture != null else 1.0, want_contact)
		if with_contact != null:
			# The look's material goes on its surfaces (a MultiMesh has no per-surface override), the box's on its own.
			mm.mesh = with_contact
			mmi.material_override = null
			own.append(_contact_material)
		else:
			mmi.material_override = material  # (null for an own-look model: its surfaces carry theirs)
		if material != null:
			own.append(material)
		for m: ShaderMaterial in own:
			if _paths != null:
				m.set_shader_parameter("belt_paths", _paths)
			_materials[m] = true
	if model != null and use_shadow_proxy and shadow_proxy_enabled:
		if not (record_tex == 1 and variant_of(item_id) > 0):
			var sbox: Mesh = ItemModels.shadow_box_mesh(model)
			if sbox != null:
				var proxy_vis := _shadow_proxy_vis(item_id, int(_record_counts.get(item_id, 1)))
				var smmi: MultiMeshInstance3D = _shadow_kinds.get(item_id)
				if smmi == null:
					var smm := MultiMesh.new()
					smm.transform_format = MultiMesh.TRANSFORM_3D
					smm.use_custom_data = true
					smm.mesh = sbox
					smmi = MultiMeshInstance3D.new()
					smmi.multimesh = smm
					smmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
					smmi.layers = render_layers
					smmi.visible = proxy_vis
					smmi.material_override = _shadow_mat()
					smmi.name = "%s_shadow" % mmi.name
					add_child(smmi)
					_shadow_kinds[item_id] = smmi
				else:
					smmi.multimesh.mesh = sbox
					smmi.visible = proxy_vis
					smmi.layers = render_layers
					smmi.material_override = _shadow_mat()
				if _record_params.has(item_id):
					var rp: Array = _record_params[item_id]
					_sync_records_mmi(smmi, int(rp[0]), int(rp[1]), int(rp[2]), rp[3] as AABB)
				_shadow_proxied[item_id] = true
				mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				_sync_shadow_proxies_visibility()
			else:
				_shadow_proxied.erase(item_id)
				mmi.cast_shadow = _shadow_setting()
		else:
			_shadow_proxied[item_id] = true
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	else:
		_shadow_proxied.erase(item_id)
		mmi.cast_shadow = _shadow_setting()
	if model != null and geom_lod:
		_raw_models[item_id] = [model, item, want_contact]
		if not dist_lod:
			_lod0_cache[item_id] = [mm.mesh, mmi.material_override]
			if lod_tier != 0:
				_apply_lod_for(item_id, mmi)
		mmi.cast_shadow = _mmi_cast_shadow(item_id)
	_reapply_mv(item_id, mmi)
	_prof("d_override", t0)


static func _forced_thresholds(tier: int) -> Vector2:
	var ft := clampi(tier, 0, 2)
	if ft == 0:
		return Vector2(INF, INF)
	if ft == 1:
		return Vector2(0.0, INF)
	return Vector2(0.0, 0.0)


static func _same_dist(a: float, b: float) -> bool:
	if not is_finite(a) or not is_finite(b):
		return a == b
	return is_equal_approx(a, b)


static func _lod_jitters(d1: float, d2: float) -> Vector2:
	if not lod_blend:
		return Vector2.ZERO
	var j1 := minf(d1 * LOD_JITTER_SHARE, LOD1_JITTER_MAX) if (is_finite(d1) and d1 > 0.0) else 0.0
	var j2 := minf(d2 * LOD_JITTER_SHARE, LOD2_JITTER_MAX) if (is_finite(d2) and d2 > 0.0) else 0.0
	if is_finite(d1) and is_finite(d2) and d2 > d1:
		var cap := maxf(0.0, (d2 - d1) * 0.45)
		if j1 + j2 > cap and j1 + j2 > 0.0:
			var scale := cap / (j1 + j2)
			j1 *= scale
			j2 *= scale
	return Vector2(j1, j2)


## Updates per-instance distance-LOD uniforms and AABB band subsets across all dressed 3D kinds.
func update_distance_lod(cam: Camera3D, vp_h: float, bounds: AABB = AABB(),
		anchor_pos := Vector3.INF, use_anchor := false) -> void:
	if not allow_lod or not ItemModels.item_geom_lod or lod_mode != "distance":
		return
	if bounds.has_volume():
		_lod_bounds = bounds
		_has_lod_bounds = true
	_lod_use_anchor = use_anchor and anchor_pos != Vector3.INF
	_lod_anchor_pos = anchor_pos
	var forced := forced_lod_tier >= 0
	var forced_changed := forced_lod_tier != _forced_lod_seen
	if forced_changed:
		_forced_lod_seen = forced_lod_tier
		_sync_shadow_proxies_visibility()
	var th := _forced_thresholds(forced_lod_tier) if forced else (zoom_character_thresholds(cam, vp_h, _lod_anchor_pos) if _lod_use_anchor else distance_thresholds(cam, vp_h))
	var d1 := th.x
	var d2 := th.y
	var pos := _lod_anchor_pos if _lod_use_anchor else (cam.global_position if cam != null else Vector3.INF)
	_set_global_lod_cam(pos)
	var d_changed := not is_equal_approx(d1, _lod_d1) or not is_equal_approx(d2, _lod_d2) or lod_blend != _lod_blend_seen
	if d_changed:
		_lod_d1 = d1
		_lod_d2 = d2
		_lod_blend_seen = lod_blend
		_lod1_sq = d1 * d1 if is_finite(d1) else 0.0
		_lod2_sq = d2 * d2 if is_finite(d2) else 0.0
		for entry: Dictionary in _dist_lods.values():
			_sync_dist_entry_uniforms(entry)
		for entry: Dictionary in _split_lods.values():
			_sync_split_entry_uniforms(entry)
		if split_bands and lod_split:
			_sync_shadow_proxies_visibility()
	if _dist_lods.is_empty():
		return
	var mask := 7
	if forced:
		mask = 1 << clampi(forced_lod_tier, 0, 2)
	elif not is_finite(d1):
		mask = 1
	elif d2 <= 0.0:
		mask = 4
	elif d1 <= 0.0:
		mask = 2 if not is_finite(d2) else 6
	elif pos != Vector3.INF and _has_lod_bounds:
		var cpos := pos
		var bpos := _lod_bounds.position
		var bend := _lod_bounds.end
		var min_d := cpos.distance_to(cpos.clamp(bpos, bend))
		var far_pt := Vector3(
			bpos.x if absf(cpos.x - bpos.x) > absf(cpos.x - bend.x) else bend.x,
			bpos.y if absf(cpos.y - bpos.y) > absf(cpos.y - bend.y) else bend.y,
			bpos.z if absf(cpos.z - bpos.z) > absf(cpos.z - bend.z) else bend.z)
		var max_d := cpos.distance_to(far_pt)
		var jit_pad := _lod_jitters(d1, d2)
		var pad := BAND_AABB_PAD + maxf(jit_pad.x, jit_pad.y)
		var safe_min := maxf(0.0, min_d - pad)
		var safe_max := max_d + pad
		var b0 := safe_min < d1
		var b1 := safe_min < d2 and safe_max >= d1
		var b2 := is_finite(d2) and safe_max >= d2
		mask = (1 if b0 else 0) | (2 if b1 else 0) | (4 if b2 else 0)
		if mask == 0:
			mask = 4 if safe_min >= d2 else (2 if safe_min >= d1 else 1)
	var mask_changed := mask != _lod_band_mask
	if mask_changed:
		_lod_band_mask = mask
		for id in _dist_lods:
			_apply_dist_subset(int(id))
	elif forced_changed:
		for id in _dist_lods:
			var mmi: MultiMeshInstance3D = _kinds.get(int(id))
			if mmi != null:
				var want_shadow := _mmi_cast_shadow(int(id))
				if mmi.cast_shadow != want_shadow:
					mmi.cast_shadow = want_shadow
	if forced_changed or d_changed or mask_changed:
		_sync_shadow_proxies_visibility()


func _ensure_lod_thresholds() -> void:
	if _global_lod_cam_sent == Vector3.INF or _lod_cam_sent == Vector3.INF:
		var pos := _current_lod_cam_pos()
		_set_global_lod_cam(pos)
		if pos != Vector3.INF:
			_lod_cam_sent = pos
		if _lod_use_anchor and _lod_anchor_pos != Vector3.INF:
			var acam: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
			var avp_h: float = get_viewport().get_visible_rect().size.y if is_inside_tree() else 1080.0
			var th := zoom_character_thresholds(acam, avp_h, _lod_anchor_pos)
			_lod_d1 = th.x
			_lod_d2 = th.y
		elif is_inside_tree():
			var cam := get_viewport().get_camera_3d()
			if cam != null:
				var th := distance_thresholds(cam, get_viewport().get_visible_rect().size.y)
				_lod_d1 = th.x
				_lod_d2 = th.y
		_lod1_sq = _lod_d1 * _lod_d1 if is_finite(_lod_d1) else 0.0
		_lod2_sq = _lod_d2 * _lod_d2 if is_finite(_lod_d2) else 0.0


func _extract_mesh_surfs(src_mesh: Mesh, fixed_mat: ShaderMaterial, all_variants: bool) -> Dictionary:
	var surfs: Array = []
	var mats: Array = []
	var fixed_copy: ShaderMaterial = null
	if fixed_mat != null:
		fixed_copy = ModelLods.copy_material(fixed_mat)
		if all_variants:
			fixed_copy.set_shader_parameter("belt_lod_all_variants", true)
		if _paths != null:
			fixed_copy.set_shader_parameter("belt_paths", _paths)
		_materials[fixed_copy] = true
		mats.append(fixed_copy)
	for i in src_mesh.get_surface_count():
		var arr: Array = ModelLods.arrays_of(src_mesh, i)  # (the CPU copy when kept: no renderer read)
		var fmt: int = int(src_mesh.surface_get_format(i)) & ModelLods.CUSTOM_FORMATS
		var mat_copy: ShaderMaterial = fixed_copy
		if fixed_copy == null:
			var smat := src_mesh.surface_get_material(i) as ShaderMaterial
			if smat != null:
				mat_copy = ModelLods.copy_material(smat)
				if all_variants:
					mat_copy.set_shader_parameter("belt_lod_all_variants", true)
				if _paths != null:
					mat_copy.set_shader_parameter("belt_paths", _paths)
				_materials[mat_copy] = true
				mats.append(mat_copy)
		surfs.append([arr, mat_copy, fmt])
	return {"surfs": surfs, "mats": mats}


func _extract_b1_surfs(lod: Mesh, lod_mat_src: ShaderMaterial, all_variants: bool) -> Dictionary:
	if lod_mat_src == null and ItemModels.has_own(lod):
		var dressed_lod: Mesh = ItemModels.dressed(lod, ItemModels.ItemOwnShader)
		return _extract_mesh_surfs(dressed_lod, null, all_variants)
	var b1_fixed: ShaderMaterial = lod_mat_src if lod_mat_src != null else ItemModels.material_for(lod)
	return _extract_mesh_surfs(lod, b1_fixed, all_variants)


func _apply_b0_fade_stats(b0_surfs: Array, model: Mesh, is_own: bool, fade_albedo: bool) -> Dictionary:
	var stats := ItemModels.lod_stats(model)
	var eff_r := float(stats["eff_roughness"])
	var eff_m := float(stats["eff_metallic"])
	var tex_mean: Color = stats["tex_mean"]
	var surf_means: Array = stats["surf_tex_means"]
	var needs_own_rm_fade := is_own and ItemModels.needs_lod(model)
	var seen_m := {}
	for si in b0_surfs.size():
		var m := (b0_surfs[si] as Array)[1] as ShaderMaterial
		if m == null or seen_m.has(m):
			continue
		seen_m[m] = true
		if m.get_shader_parameter("use_orm") == true or m.get_shader_parameter("use_normal") == true or needs_own_rm_fade:
			m.set_shader_parameter("lod_roughness", eff_r)
			m.set_shader_parameter("lod_metallic", eff_m)
		if fade_albedo and m.get_shader_parameter("use_picture") == true:
			var tm: Color = surf_means[si] if (is_own and si < surf_means.size()) else tex_mean
			m.set_shader_parameter("lod_fade_albedo", true)
			m.set_shader_parameter("lod_albedo_mean", Vector3(tm.r, tm.g, tm.b))
	return stats


func _dress_split_band(item_id: int, item: String, model: Mesh, mmi: MultiMeshInstance3D, box: AABB, want_contact: bool) -> void:
	_ensure_lod_thresholds()
	var band := band_of(item_id)
	var is_own := ItemModels.has_own(model)
	var lod: Mesh = ItemModels.lod_mesh(model)
	if lod == null:
		lod = model
	var lod_mat_src: ShaderMaterial = ItemModels.lod_material_for(model)
	var same_01 := lod == model and not is_own and lod_mat_src == ItemModels.material_for(model)
	var out := ArrayMesh.new()
	var mats: Array = []
	var b1_uses_pic := false
	var b2_is_proxy := false
	var has_b2 := false
	var card_y := (box.position.y if not is_zero_approx(box.position.y) else 0.0) + 0.015
	if band == 0:
		var b0_src: Mesh = ItemModels.dressed(model, ItemModels.ItemOwnShader) if is_own else model
		var b0_fixed: ShaderMaterial = null if is_own else ItemModels.material_for(model)
		var b0_data := _extract_mesh_surfs(b0_src, b0_fixed, false)
		var b0_surfs: Array = b0_data["surfs"]
		mats = b0_data["mats"]
		var b1_pic := false
		if not same_01:
			var b1_m: ShaderMaterial = lod_mat_src if lod_mat_src != null else (null if ItemModels.has_own(lod) else ItemModels.material_for(lod))
			b1_pic = b1_m != null and b1_m.get_shader_parameter("use_picture") == true
		_apply_b0_fade_stats(b0_surfs, model, is_own, not same_01 and not b1_pic)
		_append_surfs(out, b0_surfs)
		if want_contact and contact and contact_allowed:
			var c := box.get_center()
			var contact_arr := contact_box(Vector2(c.x, c.z), Vector2(box.size.x, box.size.z) * 0.5, box.position.y)
			if not contact_arr.is_empty():
				var idx := out.get_surface_count()
				out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, contact_arr, [], {},
					Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
				out.surface_set_material(idx, _contact())
	elif band == 1:
		var b1_data := _extract_b1_surfs(lod, lod_mat_src, false)
		mats = b1_data["mats"]
		for m: ShaderMaterial in mats:
			if m.get_shader_parameter("use_picture") == true:
				b1_uses_pic = true
				break
		b2_is_proxy = ItemModels.lod2_mode == "proxy" and (b1_uses_pic or (is_own and lod == model) or ItemModels._mesh_tri_count(lod) > 12)
		if b1_uses_pic and b2_is_proxy:
			var stats := ItemModels.lod_stats(model)
			var tex_mean: Color = stats["tex_mean"]
			for m: ShaderMaterial in mats:
				if m.get_shader_parameter("use_picture") == true:
					m.set_shader_parameter("lod_fade_albedo", true)
					m.set_shader_parameter("lod_albedo_mean", Vector3(tex_mean.r, tex_mean.g, tex_mean.b))
		_append_surfs(out, b1_data["surfs"])
	else:
		var surfs: Array = []
		if ItemModels.lod2_mode == "proxy":
			var b1_m: ShaderMaterial = lod_mat_src if lod_mat_src != null else (null if ItemModels.has_own(lod) else ItemModels.material_for(lod))
			var b1_pic: bool = b1_m != null and b1_m.get_shader_parameter("use_picture") == true
			if b1_pic or is_own or ItemModels._mesh_tri_count(lod) > 12:
				var lod2 := ItemModels.lod2_mesh(model)
				var lod2_mat := ItemModels.lod2_material_for(model)
				var b2_data := _extract_mesh_surfs(lod2, lod2_mat, false)
				surfs = b2_data["surfs"]
				mats = b2_data["mats"]
				has_b2 = not surfs.is_empty()
		elif use_icons and item != "":
			if ItemIcons.is_cached(item):
				var b2_one := _make_dist_card_surface(item, card_y, false)
				if not b2_one.is_empty():
					surfs = [[b2_one[0], b2_one[1], 0]]
					mats = [b2_one[1]]
					has_b2 = true
			else:
				_look_ready(item, true)
				_lod2_waiting[item_id] = item
		if surfs.is_empty():
			var fb_data := _extract_b1_surfs(lod, lod_mat_src, false)
			surfs = fb_data["surfs"]
			mats = fb_data["mats"]
		_append_surfs(out, surfs)
	var entry := {
		"band": band,
		"mats": mats,
		"same_01": same_01,
		"b1_uses_pic": b1_uses_pic,
		"b2_is_proxy": b2_is_proxy,
		"has_b2": has_b2,
		"card_y": card_y,
	}
	_split_lods[item_id] = entry
	_sync_split_entry_uniforms(entry)
	mmi.multimesh.mesh = out
	mmi.material_override = null
	_reapply_mv(item_id, mmi)


func _dress_distance_lod(item_id: int, item: String, model: Mesh, mmi: MultiMeshInstance3D, box: AABB, want_contact: bool) -> void:
	_ensure_lod_thresholds()
	var is_own := ItemModels.has_own(model)
	var b0_src: Mesh = ItemModels.dressed(model, ItemModels.ItemOwnShader) if is_own else model
	var b0_fixed: ShaderMaterial = null if is_own else ItemModels.material_for(model)
	var b0_data := _extract_mesh_surfs(b0_src, b0_fixed, false)
	var contact_arr: Array = []
	if want_contact and contact and contact_allowed:
		var c := box.get_center()
		contact_arr = contact_box(Vector2(c.x, c.z), Vector2(box.size.x, box.size.z) * 0.5, box.position.y)
		_contact()
	var is_extra_lat := record_tex == 1 and variant_of(item_id) > 0 and lattice_variants_mode == "close"
	var is_lat_v0_close := record_tex == 1 and variant_of(item_id) == 0 and lattice_variants_mode == "close" and variant_count(item_of(item_id)) > 1
	var b1_surfs: Array = []
	var b1_mats: Array = []
	var same_01 := false
	var lod_mesh_b1: Mesh = model
	if not is_extra_lat:
		var lod: Mesh = ItemModels.lod_mesh(model)
		if lod == null:
			lod = model
		lod_mesh_b1 = lod
		var lod_mat_src: ShaderMaterial = ItemModels.lod_material_for(model)
		same_01 = not is_lat_v0_close and lod == model and not is_own and lod_mat_src == ItemModels.material_for(model)
		if not same_01:
			var b1_data := _extract_b1_surfs(lod, lod_mat_src, is_lat_v0_close)
			b1_surfs = b1_data["surfs"]
			b1_mats = b1_data["mats"]
	var b1_uses_pic := false
	for m: ShaderMaterial in b1_mats:
		if m.get_shader_parameter("use_picture") == true:
			b1_uses_pic = true
			break
	var b0_mats: Array = b0_data["mats"]
	var has_b0_pic := false
	for m: ShaderMaterial in b0_mats:
		if m.get_shader_parameter("use_picture") == true:
			has_b0_pic = true
			break
	var card_y := (box.position.y if not is_zero_approx(box.position.y) else 0.0) + 0.015
	var b2_surfs: Array = []
	var b2_mats: Array = []
	var has_b2 := false
	var b2_is_proxy := false
	if not is_extra_lat:
		if ItemModels.lod2_mode == "proxy":
			var b1_tris := ItemModels._mesh_tri_count(lod_mesh_b1) if not same_01 else ItemModels._mesh_tri_count(model)
			var b1_has_pic := b1_uses_pic or (same_01 and has_b0_pic)
			if is_lat_v0_close or b1_has_pic or is_own or b1_tris > 12:
				var lod2 := ItemModels.lod2_mesh(model)
				var lod2_mat := ItemModels.lod2_material_for(model)
				var b2_data := _extract_mesh_surfs(lod2, lod2_mat, is_lat_v0_close)
				b2_surfs = b2_data["surfs"]
				b2_mats = b2_data["mats"]
				has_b2 = not b2_surfs.is_empty()
				b2_is_proxy = has_b2
		elif use_icons and item != "":
			if ItemIcons.is_cached(item):
				var b2_one := _make_dist_card_surface(item, card_y, is_lat_v0_close)
				if not b2_one.is_empty():
					b2_surfs = [[b2_one[0], b2_one[1], 0]]
					has_b2 = true
					b2_mats.append(b2_one[1])
			else:
				_look_ready(item, true)
				_lod2_waiting[item_id] = item
	var b1_pic_effective: bool = b1_uses_pic if not is_extra_lat else (ItemModels.lod_material_for(model).get_shader_parameter("use_picture") == true)
	var fade_b0_pic: bool = (not same_01 and not b1_pic_effective) or (same_01 and b2_is_proxy and has_b2)
	var b0_surfs: Array = b0_data["surfs"]
	var stats := _apply_b0_fade_stats(b0_surfs, model, is_own, fade_b0_pic)
	var tex_mean: Color = stats["tex_mean"]
	for m: ShaderMaterial in b1_mats:
		if b1_uses_pic and b2_is_proxy and has_b2 and m.get_shader_parameter("use_picture") == true:
			m.set_shader_parameter("lod_fade_albedo", true)
			m.set_shader_parameter("lod_albedo_mean", Vector3(tex_mean.r, tex_mean.g, tex_mean.b))
	var entry := {
		"b0_surfs": b0_surfs,
		"contact_arr": contact_arr,
		"b1_surfs": b1_surfs,
		"b2_surfs": b2_surfs,
		"same_01": same_01,
		"extra_lat": is_extra_lat,
		"has_b2": has_b2,
		"b1_uses_pic": b1_uses_pic,
		"b2_is_proxy": b2_is_proxy,
		"subsets": {},
		"b0_mats": b0_mats,
		"b1_mats": b1_mats,
		"b2_mats": b2_mats,
		"item": item,
		"card_y": card_y,
		"all_variants": is_lat_v0_close,
	}
	_dist_lods[item_id] = entry
	_sync_dist_entry_uniforms(entry)
	mmi.material_override = null
	_apply_dist_subset(item_id)


func _append_surfs(out: ArrayMesh, surfs: Array) -> void:
	for s: Array in surfs:
		var idx := out.get_surface_count()
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s[0], [], {}, int(s[2]))
		if s[1] != null:
			out.surface_set_material(idx, s[1])


func _make_dist_card_surface(item: String, card_y: float, all_variants: bool) -> Array:
	var tex := ItemIcons.texture_for(item)
	if tex == null:
		return []
	var arr: Array = _card().get_mesh_arrays().duplicate(true)
	var verts := arr[Mesh.ARRAY_VERTEX] as PackedVector3Array
	for i in verts.size():
		verts[i].y += card_y
	arr[Mesh.ARRAY_VERTEX] = verts
	var mat := ShaderMaterial.new()
	mat.shader = CardShader
	mat.set_shader_parameter("icon", tex)
	if all_variants:
		mat.set_shader_parameter("belt_lod_all_variants", true)
	if _paths != null:
		mat.set_shader_parameter("belt_paths", _paths)
	_materials[mat] = true
	return [arr, mat]


func _attach_split_lod2(item_id: int, item: String) -> void:
	var entry: Variant = _split_lods.get(item_id)
	var mmi: MultiMeshInstance3D = _kinds.get(item_id)
	if mmi == null or not (entry is Dictionary):
		return
	var dict := entry as Dictionary
	if bool(dict["has_b2"]):
		return
	var surf := _make_dist_card_surface(item, float(dict["card_y"]), false)
	if surf.is_empty():
		return
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surf[0], [], {}, 0)
	out.surface_set_material(0, surf[1])
	dict["mats"] = [surf[1]]
	dict["has_b2"] = true
	_sync_split_entry_uniforms(dict)
	mmi.multimesh.mesh = out
	mmi.material_override = null
	_reapply_mv(item_id, mmi)


func _attach_distance_lod2(item_id: int, item: String) -> void:
	var entry: Variant = _dist_lods.get(item_id)
	if not (entry is Dictionary):
		return
	var dict := entry as Dictionary
	if bool(dict["has_b2"]) or bool(dict["extra_lat"]):
		return
	var surf := _make_dist_card_surface(item, float(dict["card_y"]), bool(dict["all_variants"]))
	if surf.is_empty():
		return
	dict["b2_surfs"] = [[surf[0], surf[1], 0]]
	dict["b2_is_proxy"] = false
	var mats: Array = dict["b2_mats"]
	mats.append(surf[1])
	dict["has_b2"] = true
	(dict["subsets"] as Dictionary).clear()
	_sync_dist_entry_uniforms(dict)
	_apply_dist_subset(item_id)


func _sync_split_entry_uniforms(entry: Dictionary) -> void:
	var band := int(entry["band"])
	var d1_on := is_finite(_lod_d1) and _lod_d1 > 0.0
	var d2_on := is_finite(_lod_d2) and _lod_d2 > 0.0
	var fstart := 0.0
	var fend := 0.0
	if band == 0:
		if lod_blend and d1_on and not bool(entry["same_01"]):
			fend = _lod_d1
			fstart = fend * LOD0_FADE_RATIO
	elif band == 1:
		if lod_blend and d2_on and bool(entry.get("b1_uses_pic", false)) and bool(entry.get("b2_is_proxy", false)):
			fend = _lod_d2
			fstart = fend * LOD1_FADE_RATIO
	for m: ShaderMaterial in (entry["mats"] as Array):
		m.set_shader_parameter("lod_min_sq", 0.0)
		m.set_shader_parameter("lod_max_sq", 0.0)
		m.set_shader_parameter("lod_jitter", Vector2.ZERO)
		m.set_shader_parameter("lod_fade_start", fstart)
		m.set_shader_parameter("lod_fade_end", fend)


func _sync_dist_entry_uniforms(entry: Dictionary) -> void:
	var has_b2 := bool(entry["has_b2"])
	var same_01 := bool(entry["same_01"])
	var d1_on := is_finite(_lod_d1) and _lod_d1 > 0.0
	var d2_on := has_b2 and is_finite(_lod_d2) and _lod_d2 > 0.0
	var jit := _lod_jitters(_lod_d1, _lod_d2) if lod_blend else Vector2.ZERO
	var j1 := jit.x if d1_on else 0.0
	var j2 := jit.y if d2_on else 0.0
	var b0_fade := lod_blend and ((not same_01 and d1_on) or (same_01 and d2_on))
	var b0_end := (_lod_d2 if same_01 else _lod_d1) if b0_fade else 0.0
	var b0_start := b0_end * (LOD1_FADE_RATIO if same_01 else LOD0_FADE_RATIO) if b0_fade else 0.0
	for m: ShaderMaterial in (entry["b0_mats"] as Array):
		m.set_shader_parameter("lod_min_sq", 0.0)
		m.set_shader_parameter("lod_max_sq", (_lod2_sq if d2_on else 0.0) if same_01 else (_lod1_sq if d1_on else 0.0))
		m.set_shader_parameter("lod_jitter", Vector2(0.0, j2 if same_01 else j1))
		m.set_shader_parameter("lod_fade_start", b0_start)
		m.set_shader_parameter("lod_fade_end", b0_end)
	var b1_fade := lod_blend and d2_on and bool(entry.get("b1_uses_pic", false)) and bool(entry.get("b2_is_proxy", false))
	var b1_end := _lod_d2 if b1_fade else 0.0
	var b1_start := b1_end * LOD1_FADE_RATIO if b1_fade else 0.0
	for m: ShaderMaterial in (entry["b1_mats"] as Array):
		m.set_shader_parameter("lod_min_sq", _lod1_sq if d1_on else 0.0)
		m.set_shader_parameter("lod_max_sq", _lod2_sq if d2_on else 0.0)
		m.set_shader_parameter("lod_jitter", Vector2(j1, j2))
		m.set_shader_parameter("lod_fade_start", b1_start)
		m.set_shader_parameter("lod_fade_end", b1_end)
	for m: ShaderMaterial in (entry["b2_mats"] as Array):
		m.set_shader_parameter("lod_min_sq", _lod2_sq if d2_on else 0.0)
		m.set_shader_parameter("lod_max_sq", 0.0)
		m.set_shader_parameter("lod_jitter", Vector2(j2, 0.0))


func _get_subset_mesh(entry: Dictionary, mask: int) -> ArrayMesh:
	var want_b0 := (mask & 1) != 0
	var want_b1 := (mask & 2) != 0
	var want_b2 := (mask & 4) != 0
	if bool(entry["extra_lat"]):
		if not want_b0:
			return null
		want_b1 = false
		want_b2 = false
	elif not bool(entry["has_b2"]) and want_b2:
		want_b1 = true
		want_b2 = false
	var same_01 := bool(entry["same_01"])
	var inc_b0 := (want_b0 or want_b1) if same_01 else want_b0
	var inc_b1 := false if same_01 else want_b1
	var contact_arr: Array = entry["contact_arr"]
	var inc_contact := want_b0 and not contact_arr.is_empty() and contact and contact_allowed
	var key := (1 if inc_b0 else 0) | (2 if inc_b1 else 0) | (4 if want_b2 else 0) | (8 if inc_contact else 0)
	if key == 0:
		return null
	var subsets := entry["subsets"] as Dictionary
	if subsets.has(key):
		return subsets[key] as ArrayMesh
	var out := ArrayMesh.new()
	if inc_b0:
		_append_surfs(out, entry["b0_surfs"] as Array)
	if inc_contact:
		var idx := out.get_surface_count()
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, contact_arr, [], {},
			Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
		out.surface_set_material(idx, _contact())
	if inc_b1:
		_append_surfs(out, entry["b1_surfs"] as Array)
	if want_b2:
		_append_surfs(out, entry["b2_surfs"] as Array)
	if out.get_surface_count() == 0:
		return null
	subsets[key] = out
	return out


func _apply_dist_subset(item_id: int) -> void:
	var mmi: MultiMeshInstance3D = _kinds.get(item_id)
	var entry: Variant = _dist_lods.get(item_id)
	if mmi == null or not (entry is Dictionary):
		return
	if not _has_visible_records(item_id):
		mmi.visible = false
		return
	var dict := entry as Dictionary
	if bool(dict["extra_lat"]):
		var show := (_lod_band_mask & 1) != 0 and lattice_variants_active and lattice_variants_mode != "off"
		mmi.visible = show
		if not show:
			return
	else:
		mmi.visible = true
	var mesh := _get_subset_mesh(dict, _lod_band_mask)
	if mesh == null:
		mmi.visible = false
		return
	var mesh_changed := mmi.multimesh.mesh != mesh
	if mesh_changed:
		mmi.multimesh.mesh = mesh
	if mesh_changed or _mv_deferred.has(item_id):
		_mv_deferred.erase(item_id)
		_reapply_mv(item_id, mmi)
	if mmi.material_override != null:
		mmi.material_override = null
	var want_shadow := _mmi_cast_shadow(item_id)
	if mmi.cast_shadow != want_shadow:
		mmi.cast_shadow = want_shadow


## Switches every LOD-enabled 3D model kind to `tier` (0 full, 1 simplified albedo-only, 2 icon card).
func set_lod_tier(tier: int) -> void:
	tier = clampi(tier, 0, 2)
	if not allow_lod or not ItemModels.item_geom_lod:
		tier = 0
	var forced_changed := forced_lod_tier != _forced_lod_seen
	if forced_changed:
		_forced_lod_seen = forced_lod_tier
	if tier == lod_tier:
		if forced_changed:
			_sync_shadow_proxies_visibility()
			for id in _raw_models:
				var kid := int(id)
				var mmi: MultiMeshInstance3D = _kinds.get(kid)
				if mmi != null:
					var want_shadow := _mmi_cast_shadow(kid)
					if mmi.cast_shadow != want_shadow:
						mmi.cast_shadow = want_shadow
		return
	lod_tier = tier
	_sync_shadow_proxies_visibility()
	for id in _raw_models:
		var kid := int(id)
		var mmi: MultiMeshInstance3D = _kinds.get(kid)
		if mmi != null:
			_apply_lod_for(kid, mmi)


func _apply_lod_for(item_id: int, mmi: MultiMeshInstance3D) -> void:
	if mmi == null or _dist_lods.has(item_id) or not _raw_models.has(item_id):
		return
	var entry: Array = []
	if lod_tier == 2:
		entry = _build_lod2(item_id)
		if entry.is_empty():
			entry = _build_lod1(item_id)
	elif lod_tier == 1:
		entry = _build_lod1(item_id)
	if entry.is_empty():
		entry = _lod0_cache.get(item_id, [])
	if entry.is_empty():
		return
	var mm := mmi.multimesh
	var mesh: Mesh = entry[0]
	var mat: Material = entry[1]
	if mm.mesh != mesh:
		mm.mesh = mesh
		_reapply_mv(item_id, mmi)
	if mmi.material_override != mat:
		mmi.material_override = mat
	var want_shadow := _mmi_cast_shadow(item_id)
	if mmi.cast_shadow != want_shadow:
		mmi.cast_shadow = want_shadow


func _build_lod1(item_id: int) -> Array:
	if _lod1_cache.has(item_id):
		return _lod1_cache[item_id]
	var raw: Array = _raw_models.get(item_id, [])
	if raw.is_empty():
		return []
	var model: Mesh = raw[0]
	var has_contact0 := bool(raw[2]) and contact and contact_allowed
	var lod: Mesh = ItemModels.lod_mesh(model)
	if lod == null:
		lod = model
	if not has_contact0 and lod == model and ItemModels.has_own(model):
		var entry0: Array = _lod0_cache.get(item_id, [])
		if not entry0.is_empty():
			_lod1_cache[item_id] = entry0
			return entry0
	var mat: ShaderMaterial = ItemModels.lod_material_for(model)
	if mat != null:
		if _paths != null:
			mat.set_shader_parameter("belt_paths", _paths)
		_materials[mat] = true
	elif not ItemModels.has_own(lod):
		mat = ItemModels.material_for(lod)
		if mat != null:
			if _paths != null:
				mat.set_shader_parameter("belt_paths", _paths)
			_materials[mat] = true
	if not has_contact0 and lod == model and _lod0_cache.has(item_id):
		var entry0: Array = _lod0_cache[item_id]
		var mesh0: Mesh = entry0[0]
		var over0: Material = entry0[1]
		var mat0: Material = over0 if over0 != null else (mesh0.surface_get_material(0) if mesh0 != null and mesh0.get_surface_count() > 0 else null)
		if mat == mat0:
			_lod1_cache[item_id] = entry0
			return entry0
	var entry: Array
	if mat == null and ItemModels.has_own(lod):
		var dressed_lod: Mesh = ItemModels.dressed(lod, ItemModels.ItemOwnShader)
		for m: ShaderMaterial in ItemModels.surface_materials(dressed_lod):
			if _paths != null:
				m.set_shader_parameter("belt_paths", _paths)
			_materials[m] = true
		entry = [dressed_lod, null]
	else:
		entry = [lod, mat]
	_lod1_cache[item_id] = entry
	return entry


func _build_lod2(item_id: int) -> Array:
	if _lod2_cache.has(item_id):
		return _lod2_cache[item_id]
	var raw: Array = _raw_models.get(item_id, [])
	if raw.is_empty():
		return []
	if ItemModels.lod2_mode == "proxy":
		var model: Mesh = raw[0]
		var lod2 := ItemModels.lod2_mesh(model)
		var mat := ItemModels.lod2_material_for(model)
		if mat != null:
			if _paths != null:
				mat.set_shader_parameter("belt_paths", _paths)
			_materials[mat] = true
		var entry: Array = [lod2, mat]
		_lod2_cache[item_id] = entry
		return entry
	var item: String = raw[1]
	if not use_icons or item == "":
		return []
	if not ItemIcons.is_cached(item):
		if not _look_ready(item, true):
			_lod2_waiting[item_id] = item
			return []
	var tex := ItemIcons.texture_for(item)
	if tex == null:
		_lod2_cache[item_id] = []
		return []
	var mat := ShaderMaterial.new()
	mat.shader = CardShader
	mat.set_shader_parameter("icon", tex)
	if _paths != null:
		mat.set_shader_parameter("belt_paths", _paths)
	_materials[mat] = true
	var entry: Array = [_card(), mat]
	_lod2_cache[item_id] = entry
	return entry


func _shadow_mat() -> ShaderMaterial:
	if _shadow_material == null:
		_shadow_material = ShaderMaterial.new()
		_shadow_material.shader = ItemModels.Looks.shader_for(ItemModels.ItemShadowShader)
		if _paths != null:
			_shadow_material.set_shader_parameter("belt_paths", _paths)
		if _shadow_max_latest >= 0.0:
			_shadow_cam_sent = _shadow_cam_latest
			_shadow_max_sent = _shadow_max_latest
			_shadow_material.set_shader_parameter("shadow_cam", _shadow_cam_sent)
			_shadow_material.set_shader_parameter("shadow_max_sq", maxf(_shadow_max_sent, 0.0) * maxf(_shadow_max_sent, 0.0))
		_materials[_shadow_material] = true
	return _shadow_material


## Updates the shadow proxy shader's camera cutoff when the camera moves or shadow distance changes.
func update_shadow_cam(pos: Vector3, max_dist: float) -> void:
	var max_changed := absf(max_dist - _shadow_max_latest) > 0.1
	_shadow_cam_latest = pos
	_shadow_max_latest = max_dist
	if _shadow_material != null and (pos.distance_squared_to(_shadow_cam_sent) > 0.0625 or absf(max_dist - _shadow_max_sent) > 0.1):
		_shadow_cam_sent = pos
		_shadow_max_sent = max_dist
		_shadow_material.set_shader_parameter("shadow_cam", pos)
		_shadow_material.set_shader_parameter("shadow_max_sq", maxf(max_dist, 0.0) * maxf(max_dist, 0.0))
	if max_changed and split_bands and lod_split:
		_sync_shadow_proxies_visibility()


## The kind's look `mesh` with its contact box added (contact on, allowed, and `want_contact`): a copy, so the look's own
## (shared by every node and the far lanes) is untouched, with `material` on the look's surfaces when it has
## one. `footprint`: the share of the look's box the rim goes round. Null when off.
func _with_contact(mesh: Mesh, material: Material, footprint: float, want_contact := true) -> ArrayMesh:
	if not want_contact or not contact or not contact_allowed or mesh == null:
		return null
	var out: ArrayMesh
	if mesh is ArrayMesh:
		out = ItemModels.copy_mesh(mesh) as ArrayMesh  # (from the CPU copy when kept: duplicate() reads the renderer)
	elif mesh is PrimitiveMesh:
		out = ArrayMesh.new()
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, (mesh as PrimitiveMesh).get_mesh_arrays())
	else:
		return null
	if material != null:
		for i in out.get_surface_count():
			out.surface_set_material(i, material)
	var box := mesh.get_aabb()
	var c := box.get_center()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, contact_box(Vector2(c.x, c.z),
		Vector2(box.size.x, box.size.z) * 0.5 * footprint, box.position.y), [], {},
		Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	out.surface_set_material(out.get_surface_count() - 1, _contact())
	return out


## The contact box's arrays: round a footprint (`centre` and `half` size, x and z, in the mesh's units)
## grown by CONTACT_REACH, from CONTACT_DROP under the `base` (the mesh's lowest point) to CONTACT_TOP over
## it; CUSTOM0 the footprint, UV.x the base (item_contact.gdshader). Its outside faces (the shader draws
## the front ones; no bottom: it is never seen from below).
static func contact_box(centre: Vector2, half: Vector2, base: float) -> Array:
	var e := half + Vector2(CONTACT_REACH, CONTACT_REACH)
	var lo := base - CONTACT_DROP
	var hi := base + CONTACT_TOP
	var p := PackedVector3Array()
	for y: float in [lo, hi]:
		for k: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			p.append(Vector3(centre.x + k.x * e.x, y, centre.y + k.y * e.y))
	# Clockwise seen from outside (Godot's front faces): the top's corners 4-7 go clockwise seen from above.
	var idx := PackedInt32Array([4, 5, 6, 4, 6, 7])
	for i in 4:
		var j := (i + 1) % 4
		idx.append_array([i, j, j + 4, i, j + 4, i + 4])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = p
	var uv := PackedVector2Array()
	var custom := PackedFloat32Array()
	for i in p.size():
		uv.append(Vector2(base, 0.0))
		custom.append_array([centre.x, centre.y, half.x, half.y])
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_CUSTOM0] = custom
	arrays[Mesh.ARRAY_INDEX] = idx
	return arrays


## This node's contact material (its belt_paths given by set_paths, as its looks').
func _contact() -> ShaderMaterial:
	if _contact_material == null:
		_contact_material = ShaderMaterial.new()
		_contact_material.shader = ContactShader
		_contact_material.set_shader_parameter("fade_from", CONTACT_FADE_FROM)
		_contact_material.set_shader_parameter("fade_to", CONTACT_FADE_TO)
		_contact_material.set_shader_parameter("use_anchor", _contact_anchor_on)
		if _contact_anchor_pos != Vector3.INF:
			_contact_material.set_shader_parameter("anchor_pos", _contact_anchor_pos)
		_contact_material.set_shader_parameter("anchor_fade_from", _contact_anchor_d1 * 0.65)
		_contact_material.set_shader_parameter("anchor_fade_to", _contact_anchor_d1)
		_contact_material.set_shader_parameter("reach", CONTACT_REACH)
		_contact_material.set_shader_parameter("gap_gone", CONTACT_DROP)
		_contact_material.set_shader_parameter("on", _contact_shown)
		for u in _contact_params:
			_contact_material.set_shader_parameter(u, _contact_params[u])
		# As the buildings' rims: after the decoratives, before ghosts, smoke and icons.
		_contact_material.render_priority = -1
		if _paths != null:
			_contact_material.set_shader_parameter("belt_paths", _paths)
		_materials[_contact_material] = true
		_contact_materials.append(_contact_material)
	if not _materials.has(_contact_material):
		if _paths != null:
			_contact_material.set_shader_parameter("belt_paths", _paths)
		_materials[_contact_material] = true
	return _contact_material


func _enter_tree() -> void:
	# Back in the tree after a remove (reparenting): listed again.
	if _contact_material != null and not _contact_materials.has(_contact_material):
		_contact_materials.append(_contact_material)


func _exit_tree() -> void:
	# A freed node's material must not stay in the static list (the sliders would keep setting it).
	if _contact_material != null:
		_contact_materials.erase(_contact_material)


## The debug menu's Contact strength and rim width (rim_dark, rim_falloff) on every item's rim too; null
## gives the shader's own back.
static func contact_param(uniform: String, value: Variant) -> void:
	if value == null:
		_contact_params.erase(uniform)
	else:
		_contact_params[uniform] = value
	for m in _contact_materials:
		m.set_shader_parameter(uniform, value)


## Settings > Graphics > Contact shading (ContactShade.enabled) shows and hides the items' rims too; under
## --belt-item-contact=flip they go on and off every CONTACT_FLIP seconds.
static func _contact_follow() -> void:
	var shown := ContactShade.enabled
	if contact_flip:
		shown = shown and contact_flip_on()
	if shown == _contact_shown:
		return
	_contact_shown = shown
	for m in _contact_materials:
		m.set_shader_parameter("on", shown)


## Whether items' rims are drawn now (for belt_items.gd's --item-bench).
static func contact_drawn() -> bool:
	return contact_allowed and _contact_shown


static func contact_flip_on() -> bool:
	return int(Time.get_ticks_msec() / (CONTACT_FLIP * 1000.0)) % 2 == 0


## Flat and facing up, with the top of the icon to the north.
static func _card() -> PlaneMesh:
	if _card_mesh == null:
		_card_mesh = PlaneMesh.new()
		_card_mesh.size = Vector2(CARD_SIZE, CARD_SIZE)
	return _card_mesh


static func _block() -> BoxMesh:
	if _block_mesh == null:
		_block_mesh = BoxMesh.new()
		_block_mesh.size = BLOCK_SIZE
	return _block_mesh
