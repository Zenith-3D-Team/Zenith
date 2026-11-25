extends Node3D
## Space Age's quality on things in the world, as Factorio marks them: the quality's icon in the
## bottom-left corner of a placed entity better than normal (`extra.q` in its record), and on
## items riding belts (`bq`, ui_model.belt_quality, at the item belt_items.gd draws). One
## MultiMesh of camera-facing icons per quality; a chunk's entities are gathered again when that
## chunk changes (gathering every record in the world each time took 10-20 ms a frame in Alt-mode
## on a big save while chunks streamed), belt items every frame. Only in Alt-mode (`alt_mode`, set by factorio_ui.gd), and hidden behind
## the buildings in front of them, as Factorio's.

const WorldMirror := preload("res://scripts/world/world.gd")
const IconShader := preload("res://shaders/billboard_icon_cut.gdshader")
const Slot := preload("res://scripts/ui/factorio/slot.gd")
const Switches := preload("res://scripts/switches.gd")

const ENTITY_ICON := 0.42
const ITEM_ICON := 0.2
const ITEM_POLL_INTERVAL := 1.0 / 30.0

## --quality-marks-static-cache=off: rebuild entity quality MultiMeshes every frame instead of only on chunk changes.
static var static_cache := Switches.on("--quality-marks-static-cache")
## --quality-marks-opt=off: poll belt-item qualities every frame and allocate buffers per upload as before.
static var opt_enabled := Switches.on("--quality-marks-opt")
## Changed chunks' marks gathered a slice a frame, and a little each frame while Alt-mode is off (the
## owner's spike log: 37.8 ms in the frame Alt-mode came on). --alt-marks-sliced=off: all at once, as before.
static var sliced := Switches.on("--alt-marks-sliced")
const ON_USEC := 1500
const OFF_USEC := 300

var world: WorldMirror
var belt_items  # belt_items.gd
var model  # ui_model.gd
var alt_mode := false

var _entity_marks := {}  # quality -> [Vector3]
var _chunk_marks := {}  # chunk -> {quality -> [Vector3]}
var _layers := {}  # quality -> MultiMeshInstance3D (static entities)
var _item_layers := {}  # quality -> MultiMeshInstance3D (belt items)
var _entity_counts := {}  # quality -> int
var _entity_bufs := {}  # quality -> PackedFloat32Array
var _item_bufs := {}  # quality -> PackedFloat32Array
var _item_marks := {}  # quality -> Array[Vector3]
var _dirty := true  # every chunk
var _dirty_chunks := {}  # chunk -> true
var _entities_dirty := true
var _shown := false
var _had_item_marks := false
var _items_fresh := false
var _item_timer := 0.0
var _last_drawn_tick := -999999.0
var _last_bq_size := -1
var _wired_world: WorldMirror = null
var entity_uploads := 0  # (tests) static entity MultiMesh uploads
var item_uploads := 0  # (tests) belt-item MultiMesh upload passes


func _ready() -> void:
	_sync_world()


func _exit_tree() -> void:
	_disconnect_world()


func _disconnect_world() -> void:
	if is_instance_valid(_wired_world) and _wired_world.entities_changed.is_connected(_on_entities_changed):
		_wired_world.entities_changed.disconnect(_on_entities_changed)
	_wired_world = null


func _sync_world() -> void:
	if _wired_world == world:
		return
	_disconnect_world()
	_wired_world = world
	if world != null:
		world.entities_changed.connect(_on_entities_changed)


func _on_entities_changed(c: Vector2i) -> void:
	_dirty_chunks[c] = true


func reset() -> void:
	_entity_marks.clear()
	_chunk_marks.clear()
	_dirty_chunks.clear()
	_entity_counts.clear()
	_entity_bufs.clear()
	_item_bufs.clear()
	_item_marks.clear()
	_dirty = true
	_entities_dirty = true
	_shown = false
	_had_item_marks = false
	_items_fresh = false
	_item_timer = 0.0
	_last_drawn_tick = -999999.0
	_last_bq_size = -1
	entity_uploads = 0
	item_uploads = 0
	for mmi in _layers.values():
		(mmi as MultiMeshInstance3D).multimesh.visible_instance_count = 0
	for mmi in _item_layers.values():
		(mmi as MultiMeshInstance3D).multimesh.visible_instance_count = 0


func _layer(quality: String, into := _layers) -> MultiMeshInstance3D:
	if into.has(quality):
		return into[quality]
	var mat := ShaderMaterial.new()
	mat.shader = IconShader
	var icon := Slot.quality_icon(quality)
	if icon == null:
		var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
		img.fill(Slot.QUALITY_COLORS.get(quality, Color.WHITE))
		icon = ImageTexture.create_from_image(img)
	mat.set_shader_parameter("icon", icon)
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	quad.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = quad
	mm.instance_count = 32
	mm.visible_instance_count = 0
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	into[quality] = mmi
	return mmi


func _gather_entities(budget_usec := -1) -> void:
	if not sliced:
		budget_usec = -1
	if _dirty:
		_dirty = false
		_chunk_marks.clear()
		for c in world.chunks:
			_dirty_chunks[c] = true
	if _dirty_chunks.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var done: Array = []
	for c in _dirty_chunks:
		if budget_usec >= 0 and not done.is_empty() and Time.get_ticks_usec() - t0 > budget_usec:
			break
		done.append(c)
		_chunk_marks.erase(c)
		var cv = world.chunks.get(c)
		if cv == null:
			continue  # unloaded
		var marks := {}
		for r in cv.entities.values():
			var rec: WorldMirror.Rec = r
			var q = rec.extra.get("q")
			if q == null or str(q) == "normal":
				continue
			var proto = world.protos.entity(rec.proto_id)
			var half: Vector2 = proto.size() * 0.5 if proto != null else Vector2(0.5, 0.5)
			if rec.dir == 4 or rec.dir == 12:
				half = Vector2(half.y, half.x)
			var at := Vector3(rec.pos.x - half.x + ENTITY_ICON * 0.6, 0.35, rec.pos.y + half.y - ENTITY_ICON * 0.6)
			var list: Array = marks.get(str(q), [])
			list.append(at)
			marks[str(q)] = list
		if not marks.is_empty():
			_chunk_marks[c] = marks
	if done.size() >= _dirty_chunks.size():
		_dirty_chunks.clear()
	else:
		for c in done:
			_dirty_chunks.erase(c)
	_entity_marks.clear()
	for c in _chunk_marks:
		for q in _chunk_marks[c]:
			var list: Array = _entity_marks.get(q, [])
			list.append_array(_chunk_marks[c][q])
			_entity_marks[q] = list
	_entities_dirty = true


static func _upload_points_buf(mmi: MultiMeshInstance3D, points: Array, scale_s: float, bufs: Dictionary, key: String) -> void:
	var count := points.size()
	var mm := mmi.multimesh
	if count == 0:
		mm.visible_instance_count = 0
		return
	if mm.instance_count < count:
		mm.instance_count = maxi(count, mm.instance_count * 2)
	var cap := mm.instance_count
	var buf: PackedFloat32Array = bufs.get(key, PackedFloat32Array())
	bufs.erase(key)
	var need := cap * 12
	if buf.size() != need:
		buf.resize(need)
	for i in count:
		var p: Vector3 = points[i]
		var o := i * 12
		buf[o] = scale_s
		buf[o + 3] = p.x
		buf[o + 5] = scale_s
		buf[o + 7] = p.y
		buf[o + 10] = scale_s
		buf[o + 11] = p.z
	mm.buffer = buf
	bufs[key] = buf
	mm.visible_instance_count = count


static func _upload_points(mmi: MultiMeshInstance3D, points: Array, scale_s: float) -> void:
	var count := points.size()
	var mm := mmi.multimesh
	if count == 0:
		mm.visible_instance_count = 0
		return
	if mm.instance_count < count:
		mm.instance_count = maxi(count, mm.instance_count * 2)
	var cap := mm.instance_count
	var buf := PackedFloat32Array()
	buf.resize(cap * 12)
	for i in count:
		var p: Vector3 = points[i]
		var o := i * 12
		buf[o] = scale_s
		buf[o + 3] = p.x
		buf[o + 5] = scale_s
		buf[o + 7] = p.y
		buf[o + 10] = scale_s
		buf[o + 11] = p.z
	mm.buffer = buf
	mm.visible_instance_count = count


func _hide_all() -> void:
	for mmi in _layers.values():
		(mmi as MultiMeshInstance3D).multimesh.visible_instance_count = 0
	for mmi in _item_layers.values():
		(mmi as MultiMeshInstance3D).multimesh.visible_instance_count = 0


func _process_unpacked() -> void:
	_gather_entities()
	var marks := {}  # quality -> [[position, size]]
	for q in _entity_marks:
		var list: Array = []
		for p in _entity_marks[q]:
			list.append([p, ENTITY_ICON])
		marks[q] = list
	if belt_items != null:
		for uid in model.belt_quality:
			var p = belt_items.position_of(int(uid))
			if p == null:
				continue
			var q := str(model.belt_quality[uid])
			var list: Array = marks.get(q, [])
			list.append([(p as Vector3) + Vector3(-0.12, 0.18, 0.12), ITEM_ICON])
			marks[q] = list
	for q in _layers:
		if not marks.has(q):
			(_layers[q] as MultiMeshInstance3D).multimesh.visible_instance_count = 0
	for q in marks:
		var mmi := _layer(str(q))
		var list: Array = marks[q]
		if mmi.multimesh.instance_count < list.size():
			mmi.multimesh.instance_count = maxi(list.size(), mmi.multimesh.instance_count * 2)
		mmi.multimesh.visible_instance_count = list.size()
		for i in list.size():
			var s: float = list[i][1]
			mmi.multimesh.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3(s, s, s)), list[i][0]))
	entity_uploads += 1


func _process(delta: float) -> void:
	_sync_world()
	if world == null or model == null:
		return
	if not static_cache:
		if not alt_mode:
			_hide_all()
			return
		_process_unpacked()
		return
	if not alt_mode:
		if _shown:
			_shown = false
			_items_fresh = false
			_hide_all()
		if sliced and (_dirty or not _dirty_chunks.is_empty()):
			_gather_entities(OFF_USEC)
		return
	_gather_entities(ON_USEC)
	if _entities_dirty:
		_entities_dirty = false
		_entity_counts.clear()
		for q in _layers:
			if not _entity_marks.has(q):
				(_layers[q] as MultiMeshInstance3D).multimesh.visible_instance_count = 0
		for q in _entity_marks:
			var list: Array = _entity_marks[q]
			var qs := str(q)
			if opt_enabled:
				_upload_points_buf(_layer(qs, _layers), list, ENTITY_ICON, _entity_bufs, qs)
			else:
				_upload_points(_layer(qs, _layers), list, ENTITY_ICON)
			_entity_counts[qs] = list.size()
		entity_uploads += 1
	elif not _shown:
		for q in _layers:
			(_layers[q] as MultiMeshInstance3D).multimesh.visible_instance_count = int(_entity_counts.get(q, 0))
	_shown = true
	if belt_items == null:
		return
	var bq: Dictionary = model.belt_quality
	if not opt_enabled:
		if not bq.is_empty() or _had_item_marks:
			var item_marks := {}
			for uid in bq:
				var p = belt_items.position_of(int(uid))
				if p == null:
					continue
				var q := str(bq[uid])
				var list: Array = item_marks.get(q, [])
				list.append((p as Vector3) + Vector3(-0.12, 0.18, 0.12))
				item_marks[q] = list
			_had_item_marks = not item_marks.is_empty()
			for q in _item_layers:
				if not item_marks.has(q):
					(_item_layers[q] as MultiMeshInstance3D).multimesh.visible_instance_count = 0
			for q in item_marks:
				_upload_points(_layer(str(q), _item_layers), item_marks[q], ITEM_ICON)
			item_uploads += 1
		return
	if bq.is_empty():
		if _had_item_marks:
			_had_item_marks = false
			for mmi in _item_layers.values():
				(mmi as MultiMeshInstance3D).multimesh.visible_instance_count = 0
			item_uploads += 1
		_items_fresh = false
		_last_bq_size = 0
		return
	var dt_now: float = float(belt_items.drawn_tick()) if belt_items.has_method("drawn_tick") else -1.0
	var bq_size: int = bq.size()
	var force_poll: bool = not _items_fresh or bq_size != _last_bq_size
	_item_timer -= delta
	var tick_moved: bool = dt_now < 0.0 or not is_equal_approx(dt_now, _last_drawn_tick)
	if not force_poll and (not tick_moved or _item_timer > 0.0):
		return
	_item_timer = ITEM_POLL_INTERVAL
	_last_drawn_tick = dt_now
	_last_bq_size = bq_size
	_items_fresh = true
	for q in _item_marks:
		(_item_marks[q] as Array).clear()
	var any_items := false
	for uid in bq:
		var p = belt_items.position_of(int(uid))
		if p == null:
			continue
		var qs := str(bq[uid])
		var list: Array = _item_marks.get(qs, [])
		if list.is_empty() and not _item_marks.has(qs):
			_item_marks[qs] = list
		list.append((p as Vector3) + Vector3(-0.12, 0.18, 0.12))
		any_items = true
	_had_item_marks = any_items
	for q in _item_layers:
		var arr: Array = _item_marks.get(q, [])
		if arr.is_empty():
			(_item_layers[q] as MultiMeshInstance3D).multimesh.visible_instance_count = 0
	for q in _item_marks:
		var arr: Array = _item_marks[q]
		if arr.is_empty():
			continue
		var qs := str(q)
		_upload_points_buf(_layer(qs, _item_layers), arr, ITEM_ICON, _item_bufs, qs)
	item_uploads += 1
