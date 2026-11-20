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

const CARD_SIZE := 0.32
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
		for mmi: MultiMeshInstance3D in _kinds.values():
			mmi.cast_shadow = _shadow_setting()
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
const CONTACT_REACH := 0.14
const CONTACT_DROP := 0.2
const CONTACT_TOP := 0.02
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
var _contact_material: ShaderMaterial
var _lod_materials := {}  # ShaderMaterial -> true: multi-surface item LOD materials receiving lod_cam
var _lod_cam_sent := Vector3.INF


## --item-models=off|on (wins over the setting for that run, for comparing).
static func configure_from_command_line() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--item-models="):
			use_models = arg.get_slice("=", 1) != "off"
		elif arg.begins_with("--belt-item-contact="):
			var v := arg.get_slice("=", 1)
			contact_allowed = v != "off"
			contact_flip = v == "flip"


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
	_kinds.clear()
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
	epoch += 1


func kind_count() -> int:
	return _kinds.size()


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


## A kind drawn from records (belt_items.gd, belt_records.gd): `cap` instances reading records `base`
## on, the first n drawn. Its buffer is only identity transforms, written when its size changes.
func put_records(item_id: int, base: int, n: int, cap: int, bounds: AABB) -> void:
	var mmi := _kind(item_id)
	var mm := mmi.multimesh
	if mm.instance_count != cap:
		mm.visible_instance_count = 0
		mm.instance_count = cap
		mm.buffer = _identity(cap)
	mm.custom_aabb = bounds
	mm.visible_instance_count = n
	mmi.set_instance_shader_parameter("belt_base", base)
	if record_tex != 0:
		mmi.set_instance_shader_parameter("belt_tex", record_tex)
	_bounded[item_id] = true
	# A packed lane's item is someone only in the shader (belt_path.gdshaderinc): each of the item's variants
	# is a kind of its own over the same records, drawing the slots whose item is its variant
	# (belt_lattice_variant; --model-variants=off: the first alone, as before).
	var variants := variant_count(item_id) if record_tex == 1 else 0
	if variants > 1 or _lat_variants.get(item_id, 0) > 1:
		mmi.set_instance_shader_parameter("belt_variants", variants)
		mmi.set_instance_shader_parameter("belt_variant", 0)
		for v in range(1, variants):
			var key := item_id + v * VARIANT_STEP
			put_records(key, base, n, cap, bounds)
			_kinds[key].set_instance_shader_parameter("belt_variants", variants)
			_kinds[key].set_instance_shader_parameter("belt_variant", v)
		_lat_variants[item_id] = variants


var _lat_variants := {}  # (record_tex 1) item id -> how many variant kinds its records are drawn with


## Every record-drawn kind's bounds: where its items can be (the square they come from).
func set_bounds(bounds: AABB) -> void:
	for id in _bounded:
		var mmi: MultiMeshInstance3D = _kinds.get(id)
		if mmi != null:
			mmi.multimesh.custom_aabb = bounds


var _bounded := {}
static var _identities := {}
## Which records texture put_records' kinds read: 0 f3d_belt_records, 1 f3d_belt_lattice (belt_lattice.gd).
var record_tex := 0


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


## The item a kind key is for (icon_key()'s keys are below zero, variant_key()'s VARIANT_STEP and up).
static func item_of(key: int) -> int:
	return key % VARIANT_STEP if key >= 0 else -key - 1


## A kind key's variant of its item's model (variant_key), 0 for the first.
static func variant_of(key: int) -> int:
	return key / VARIANT_STEP if key >= 0 else 0


## Kind keys of an item's other model variants: item id + variant * VARIANT_STEP.
const VARIANT_STEP := 1 << 20


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
	mmi.name = "Items_%s%s%s" % [item if item != "" else str(item_of(item_id)), "_icon" if item_id < 0 else "",
		"_%d" % variant_of(item_id) if variant_of(item_id) > 0 else ""]
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
	if not _lod_materials.is_empty() and is_inside_tree():
		var cam := get_viewport().get_camera_3d()
		if cam != null:
			var pos := cam.global_position
			if pos.distance_squared_to(_lod_cam_sent) > 0.0625:
				_lod_cam_sent = pos
				for m: ShaderMaterial in _lod_materials:
					m.set_shader_parameter("lod_cam", pos)
	if _loading.is_empty():
		return
	if not _dress_arg_read:
		_dress_arg_read = true
		for a in OS.get_cmdline_user_args():
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
		var mmi: MultiMeshInstance3D = _kinds.get(id)
		if mmi != null:
			tl = Time.get_ticks_usec()
			_dress(id, item, mmi)
			_prof("poll_dress", tl)
			if Probing.on and Time.get_ticks_usec() - tl > 5000:
				print("ITEMCARDS slow dress %s (%d): %d ms, model %s" % [item, id, (Time.get_ticks_usec() - tl) / 1000, _turns.has(id)])
			mmi.visible = true
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
	if model != null:
		t0 = Time.get_ticks_usec()
		var use_lod := contact and ItemModels.item_lod and ItemModels.needs_lod(model)
		mm.mesh = ItemModels.dressed_lod(model, ItemModels.ItemOwnShader, ITEM_LOD_DIST) if use_lod else ItemModels.dressed(model, ItemModels.ItemOwnShader)
		_prof("d_mesh", t0)
		t0 = Time.get_ticks_usec()
		if ItemModels.has_own(model):
			own = ItemModels.surface_materials(mm.mesh)
			if use_lod:
				var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
				var cam_pos := cam.global_position if cam != null else Vector3.ZERO
				for m: ShaderMaterial in own:
					_lod_materials[m] = true
					if cam != null:
						m.set_shader_parameter("lod_cam", cam_pos)
		else:
			material = ItemModels.material_for(model)  # its picture's own, else the one all share
		_turns[item_id] = true
		_prof("d_material", t0)
		t0 = Time.get_ticks_usec()
		var box := model.get_aabb()
		_pile[item_id] = clampf(box.size.y, 0.03, 0.2)
		if not is_zero_approx(box.position.y):
			_lift[item_id] = Vector3(0.0, -box.position.y, 0.0)  # its lowest point rests on the belt
		_prof("d_aabb", t0)
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
	var with_contact := _with_contact(mm.mesh, material, CONTACT_CARD if model == null and texture != null else 1.0)
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
	_prof("d_override", t0)


## The kind's look `mesh` with its contact box added (contact on, and allowed): a copy, so the look's own
## (shared by every node and the far lanes) is untouched, with `material` on the look's surfaces when it has
## one. `footprint`: the share of the look's box the rim goes round. Null when off.
func _with_contact(mesh: Mesh, material: Material, footprint: float) -> ArrayMesh:
	if not contact or not contact_allowed or mesh == null:
		return null
	var out: ArrayMesh
	if mesh is ArrayMesh:
		out = (mesh as ArrayMesh).duplicate() as ArrayMesh
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
