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


## --item-models=off|on (wins over the setting for that run, for comparing).
static func configure_from_command_line() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--item-models="):
			use_models = arg.get_slice("=", 1) != "off"


## A slight turn for one item, the same every frame: `seed` is its unique id, or anything
## else that stays put (a position on the ground, an inserter's unit number).
static func yaw_for(seed: int) -> float:
	return (posmod(hash(seed), 2001) / 1000.0 - 1.0) * MAX_YAW


## The one turn every loose item is drawn with (radians about +Y): on belts near (belt_items.gd) and
## far (belt_lanes.gd), on the ground, in hands; a model, a card or a block; `copy` its place in a
## pile (0 the bottom or a lone item), each copy PILE_TURN more than the one under it.
static func turn_for(seed: int, copy := 0) -> float:
	return yaw_for(seed) + PILE_TURN * copy


func reset() -> void:
	for mmi in _kinds.values():
		mmi.queue_free()
	_kinds.clear()
	_lift.clear()
	_turns.clear()
	_pile.clear()
	_buffers.clear()
	_materials.clear()
	_loading.clear()
	_bounded.clear()
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


## Applies a change of Settings → Items in 3D (models on or off).
func begin() -> void:
	if _look != _look_changes:
		_look = _look_changes
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


## The item a kind key is for (icon_key()'s keys are below zero).
static func item_of(key: int) -> int:
	return key if key >= 0 else -key - 1


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
	mmi.name = "Items_%s%s" % [item if item != "" else str(item_of(item_id)), "_icon" if item_id < 0 else ""]
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


func _process(_delta: float) -> void:
	if _loading.is_empty():
		return
	for id in _loading.keys():
		var item: String = _loading[id]
		if not _look_ready(item, id < 0):
			continue
		_loading.erase(id)
		var mmi: MultiMeshInstance3D = _kinds.get(id)
		if mmi != null:
			_dress(id, item, mmi)
			mmi.visible = true


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
	var model: Mesh = ItemModels.mesh_for(item) if use_models and item_id >= 0 else null
	var texture: Texture2D = null
	if model == null and item != "" and use_icons:
		texture = ItemIcons.texture_for(item)
	var material: ShaderMaterial
	if model != null:
		mm.mesh = model
		material = ItemModels.material()
		_turns[item_id] = true
		_pile[item_id] = clampf(model.get_aabb().size.y, 0.03, 0.2)
	elif texture != null:
		mm.mesh = _card()
		material = ShaderMaterial.new()
		material.shader = CardShader
		material.set_shader_parameter("icon", texture)
	else:
		mm.mesh = _block()
		material = ItemModels.block_material(ItemIcons.color_for(item))
		_lift[item_id] = Vector3(0.0, BLOCK_SIZE.y * 0.5, 0.0)
		_pile[item_id] = BLOCK_SIZE.y
	mmi.material_override = material
	if _paths != null:
		material.set_shader_parameter("belt_paths", _paths)
	_materials[material] = true


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
