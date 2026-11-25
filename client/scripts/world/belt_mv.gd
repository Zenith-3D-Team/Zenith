extends RefCounted
## Temporal motion-vector evaluator for belt items (item_cards.gd `belt_base = -2`).
## When TAA or AMD FSR 2.2 is active, evaluates moving belt records (bands <= max_band) and
## ping-pong lattice pre-roll pairs via C++ BeltMvNative (or GDScript fallback when disabled) so
## Godot 4.7 Forward+ generates exact per-instance motion vectors without camera-pan invalidation or
## backward wrap spikes. Standing-only lattice kinds and distant Band 2 kinds stay on GPU records.

const ItemCards := preload("res://scripts/world/item_cards.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")
const Switches := preload("res://scripts/switches.gd")

const STRIDE := ItemCards.STRIDE  # 16 floats per instance: 3x4 transform + vec4 INSTANCE_CUSTOM
const HIDE_CLOCK := 1.0e20
const SHOW_CLOCK := -1.0e20
const VRECT_MARGIN := 6.0
const WORKER_MIN_WORK := 512

static var max_band := _max_band_arg()
static var use_native := Switches.on("--belt-mv-native")


static func _max_band_arg() -> int:
	for arg in Switches.args():
		if arg.begins_with("--temporal-mv-bands="):
			var v := arg.get_slice("=", 1)
			if v == "1":
				return 1
			if v == "all" or v == "2":
				return 2
			if v == "0":
				return 0
	return 0


static func handles_kind(item_id: int) -> bool:
	return ItemCards.band_of(item_id) <= max_band


class KindState:
	var item_id := 0
	var base := -1
	var n := 0
	var cap := 0
	var inst_cap := 0
	var is_lattice := false
	var variants := 0
	var buf := PackedFloat32Array()
	var moving := PackedInt32Array()
	var dirty := true
	var last_visible := -1
	var on_records := true
	var has_written := false
	var emit := false
	var restore_to_rec := false


class EvalTask:
	var items: Array = []  # Array[KindState]
	var clock := 0.0
	var vrect := Vector4(-1.0e6, -1.0e6, 1.0e6, 1.0e6)
	var owner: RefCounted

	func _run_item(idx: int) -> void:
		owner._eval_kind(items[idx] as KindState, clock, vrect)


var _native: Variant = null
var _rec_pages: Array[PackedFloat32Array] = []
var _rec_per_page := 0
var _lat_pages: Array[PackedFloat32Array] = []
var _lat_per_page := 0
var _paths := PackedFloat32Array()
var _paths_w := 0
var _mask_tiles: Array[PackedByteArray] = []
var _mask_w := 0
var _mask_h := 0
var _mask_on := false

var _rec_kinds := {}  # item_id -> KindState
var _lat_kinds := {}  # item_id -> KindState
var _lat_known_ids := {}  # item_id -> last synced variant count (native path)
var _last_clock := -1.0e20
var _last_max_band := -1
var _was_active := false


func _init(allow_native := true) -> void:
	if allow_native and use_native and NativeLibrary.ensure() and ClassDB.class_exists(&"BeltMvNative"):
		_native = ClassDB.instantiate(&"BeltMvNative")


func has_native() -> bool:
	return _native != null


func reset() -> void:
	_last_clock = -1.0e20
	_was_active = false
	_last_max_band = -1
	_lat_known_ids.clear()
	if _native != null:
		_native.call("reset")
		return
	_rec_pages.clear()
	_rec_per_page = 0
	_lat_pages.clear()
	_lat_per_page = 0
	_paths = PackedFloat32Array()
	_paths_w = 0
	_mask_tiles.clear()
	_mask_w = 0
	_mask_h = 0
	_mask_on = false
	_rec_kinds.clear()
	_lat_kinds.clear()


func invalidate_all() -> void:
	if _native != null:
		_native.call("invalidate_all")
		return
	for ks_v in _rec_kinds.values():
		(ks_v as KindState).dirty = true
	for ks_v in _lat_kinds.values():
		(ks_v as KindState).dirty = true


func invalidate_kind(is_lattice: bool, item_id: int) -> void:
	if _native != null:
		_native.call("invalidate_kind", is_lattice, item_id)
		return
	var kinds: Dictionary = _lat_kinds if is_lattice else _rec_kinds
	var ks: KindState = kinds.get(item_id)
	if ks != null:
		ks.dirty = true


func get_buf(is_lattice: bool, item_id: int) -> PackedFloat32Array:
	if _native != null:
		return _native.call("get_buf", is_lattice, item_id) as PackedFloat32Array
	var kinds: Dictionary = _lat_kinds if is_lattice else _rec_kinds
	var ks: KindState = kinds.get(item_id)
	return ks.buf if ks != null else PackedFloat32Array()


func get_moving_count(is_lattice: bool, item_id: int) -> int:
	if _native != null:
		return int(_native.call("get_moving_count", is_lattice, item_id))
	var kinds: Dictionary = _lat_kinds if is_lattice else _rec_kinds
	var ks: KindState = kinds.get(item_id)
	return ks.moving.size() if ks != null else 0


func update_rec_pages(p: Dictionary) -> void:
	if _native != null:
		_native.call("update_rec_pages", p)
		return
	_update_pages(p, _rec_pages, _rec_kinds, false)


func update_lat_pages(p: Dictionary) -> void:
	if _native != null:
		_native.call("update_lat_pages", p)
		return
	_update_pages(p, _lat_pages, _lat_kinds, true)


func _update_pages(p: Dictionary, pages: Array[PackedFloat32Array], kinds: Dictionary, is_lat: bool) -> void:
	var list_v: Variant = p.get("pages", [])
	if not (list_v is Array):
		return
	var list := list_v as Array
	if list.is_empty():
		return
	var all := bool(p.get("all", false))
	if all:
		pages.clear()
	var touched := {}
	var per_page := _lat_per_page if is_lat else _rec_per_page
	for e_v in list:
		var e := e_v as Array
		var idx := int(e[0])
		var img := e[1] as Image
		if img == null:
			continue
		var fdata := img.get_data().to_float32_array()
		var p_cap := (img.get_width() * img.get_height()) / 4
		if p_cap > 0:
			per_page = p_cap
		if idx >= pages.size():
			pages.resize(idx + 1)
		pages[idx] = fdata
		touched[idx] = true
	if is_lat:
		_lat_per_page = per_page
	else:
		_rec_per_page = per_page
	if all or per_page <= 0:
		for ks_v in kinds.values():
			var ks := ks_v as KindState
			if handles_kind(ks.item_id):
				ks.dirty = true
		return
	for ks_v in kinds.values():
		var ks := ks_v as KindState
		if not handles_kind(ks.item_id):
			continue
		if ks.base < 0 or ks.n <= 0:
			ks.dirty = true
			continue
		var p_lo := ks.base / per_page
		var p_hi := (ks.base + ks.n - 1) / per_page
		for pi in range(p_lo, p_hi + 1):
			if touched.has(pi):
				ks.dirty = true
				break


func update_paths(img: Image) -> void:
	if img == null:
		return
	if _native != null:
		_native.call("update_paths", img)
		return
	_paths_w = img.get_width()
	_paths = img.get_data().to_float32_array()
	for ks_v in _rec_kinds.values():
		(ks_v as KindState).dirty = true


func update_mask(tiles: Array, on: bool) -> void:
	if _native != null:
		_native.call("update_mask", tiles, on)
		return
	var changed := on != _mask_on
	_mask_on = on
	if not tiles.is_empty():
		if _mask_tiles.size() != 16:
			_mask_tiles.resize(16)
		for e_v in tiles:
			var e := e_v as Array
			var ti := int(e[0])
			var img := e[1] as Image
			if img == null or ti < 0 or ti >= 16:
				continue
			_mask_w = img.get_width()
			_mask_h = img.get_height()
			_mask_tiles[ti] = img.get_data()
			changed = true
	if changed:
		for ks_v in _rec_kinds.values():
			(ks_v as KindState).dirty = true


func set_mask_on(on: bool) -> void:
	if _native != null:
		_native.call("set_mask_on", on)
		return
	if on == _mask_on:
		return
	_mask_on = on
	for ks_v in _rec_kinds.values():
		(ks_v as KindState).dirty = true


func set_rec_kind(item_id: int, base: int, n: int, cap: int) -> void:
	if _native != null:
		_native.call("set_rec_kind", item_id, base, n, cap)
		return
	_set_kind(_rec_kinds, item_id, base, n, cap, false)


func set_lat_kind(item_id: int, base: int, n: int, cap: int) -> void:
	if _native != null:
		if not _lat_known_ids.has(item_id):
			_lat_known_ids[item_id] = -1
		_native.call("set_lat_kind", item_id, base, n, cap)
		return
	_set_kind(_lat_kinds, item_id, base, n, cap, true)


func _set_kind(kinds: Dictionary, item_id: int, base: int, n: int, cap: int, is_lat: bool) -> void:
	var ks: KindState = kinds.get(item_id)
	if ks == null:
		ks = KindState.new()
		ks.item_id = item_id
		ks.is_lattice = is_lat
		kinds[item_id] = ks
	var inst_cap := cap * 2 if is_lat else cap
	if ks.base != base or ks.n != n or ks.cap != cap:
		ks.base = base
		ks.n = n
		ks.cap = cap
		ks.dirty = true
	if ks.inst_cap != inst_cap and handles_kind(item_id):
		var old_cap := ks.inst_cap
		ks.inst_cap = inst_cap
		ks.buf.resize(inst_cap * STRIDE)
		for i in range(old_cap, inst_cap):
			_hide_slot(ks.buf, i * STRIDE)
		ks.dirty = true
	else:
		ks.inst_cap = inst_cap


## Evaluates belt transforms for temporal AA when `active` is true, or restores GPU-record mode
## when transitioning back to false.
func step(clock: float, vrect: Vector4, cards: Node, lat_cards: Node, bounds: AABB, active: bool) -> void:
	var cards_ic := cards as ItemCards
	var lat_ic := lat_cards as ItemCards
	if cards_ic != null and not cards_ic.mv_buf_getter.is_valid():
		cards_ic.mv_buf_getter = func(id: int) -> PackedFloat32Array: return get_buf(false, id)
	if lat_ic != null and not lat_ic.mv_buf_getter.is_valid():
		lat_ic.mv_buf_getter = func(id: int) -> PackedFloat32Array: return get_buf(true, id)
	if not active:
		if _was_active:
			_was_active = false
			if cards != null and cards.has_method("restore_records"):
				cards.restore_records()
			if lat_cards != null and lat_cards.has_method("restore_records"):
				lat_cards.restore_records()
		return
	if not _was_active:
		_was_active = true
		invalidate_all()
	if _last_max_band != max_band:
		_last_max_band = max_band
		if _native != null:
			_native.call("set_max_band", max_band)
	if clock < _last_clock:
		invalidate_all()
	_last_clock = clock

	if _native != null:
		for kid_v in _lat_known_ids.keys():
			var kid := int(kid_v)
			if not handles_kind(kid):
				continue
			var want_vars := _lat_variants_for(lat_ic, kid)
			if int(_lat_known_ids[kid_v]) != want_vars:
				_lat_known_ids[kid_v] = want_vars
				_native.call("set_lat_variants", kid, want_vars)
		var updates: Array = _native.call("step", clock, vrect) as Array
		for u_v in updates:
			var u := u_v as Array
			var kid := int(u[0])
			var is_lat := bool(u[1])
			var target := lat_ic if is_lat else cards_ic
			if target == null:
				continue
			if bool(u[5]):
				target.restore_kind(kid)
			else:
				target.put_mv(kid, u[2] as PackedFloat32Array, int(u[3]), int(u[4]), bounds, is_lat)
		return

	var todo: Array = []
	var total_work := 0
	for ks_v in _rec_kinds.values():
		var ks := ks_v as KindState
		if ks.base < 0:
			continue
		if not handles_kind(ks.item_id):
			if ks.has_written and not ks.on_records:
				ks.on_records = true
				ks.dirty = true
				ks.last_visible = -1
				if cards_ic != null:
					cards_ic.restore_kind(ks.item_id)
			continue
		if ks.dirty or not ks.moving.is_empty() or ks.last_visible != mini(ks.n, ks.inst_cap):
			todo.append(ks)
			total_work += ks.n if ks.dirty else ks.moving.size()
	for ks_v in _lat_kinds.values():
		var ks := ks_v as KindState
		if ks.base < 0:
			continue
		if not handles_kind(ks.item_id):
			if ks.has_written and not ks.on_records:
				ks.on_records = true
				ks.dirty = true
				ks.last_visible = -1
				if lat_ic != null:
					lat_ic.restore_kind(ks.item_id)
			continue
		var want_vars := _lat_variants_for(lat_ic, ks.item_id)
		if ks.variants != want_vars:
			ks.variants = want_vars
			ks.dirty = true
		if ks.dirty or not ks.moving.is_empty() or ks.last_visible != mini(ks.n * 2, ks.inst_cap):
			todo.append(ks)
			total_work += ks.n if ks.dirty else ks.moving.size()

	if not todo.is_empty():
		var task := EvalTask.new()
		task.items = todo
		task.clock = clock
		task.vrect = vrect
		task.owner = self
		if todo.size() >= 2 and total_work >= WORKER_MIN_WORK:
			var gid := WorkerThreadPool.add_group_task(task._run_item, todo.size(), -1, true, "belt mv")
			WorkerThreadPool.wait_for_group_task_completion(gid)
		else:
			for idx in todo.size():
				task._run_item(idx)

		for ks_v in todo:
			var ks := ks_v as KindState
			if not ks.emit:
				continue
			var target := lat_ic if ks.is_lattice else cards_ic
			if target == null:
				continue
			if ks.restore_to_rec:
				target.restore_kind(ks.item_id)
			else:
				var vis := mini(ks.n * 2 if ks.is_lattice else ks.n, ks.inst_cap)
				target.put_mv(ks.item_id, ks.buf, vis, ks.inst_cap, bounds, ks.is_lattice)


static func _lat_variants_for(lat_cards: ItemCards, item_id: int) -> int:
	if lat_cards == null:
		return 0
	var band := ItemCards.band_of(item_id)
	var allow: bool = lat_cards.lattice_variants_mode != "off" and (band == 0 or lat_cards.lattice_variants_mode == "all")
	if not allow or ItemCards.variant_of(item_id) != 0:
		return 0
	return lat_cards.variant_count(ItemCards.item_of(item_id))


func _eval_kind(ks: KindState, clock: float, vrect: Vector4) -> void:
	ks.emit = false
	ks.restore_to_rec = false
	if ks.buf.size() != ks.inst_cap * STRIDE:
		var old_cap := ks.buf.size() / STRIDE
		ks.buf.resize(ks.inst_cap * STRIDE)
		for i in range(old_cap, ks.inst_cap):
			_hide_slot(ks.buf, i * STRIDE)
		ks.dirty = true
	if ks.n <= 0:
		ks.moving.clear()
		ks.dirty = false
		if ks.last_visible != 0 or not ks.on_records:
			ks.last_visible = 0
			ks.on_records = true
			ks.emit = true
		return

	# Never more slots than the buffer holds (as the native twin): n past cap writes nothing past the end.
	var target_vis := mini(ks.n * 2 if ks.is_lattice else ks.n, ks.inst_cap)
	var nw := mini(ks.n, ks.inst_cap / 2 if ks.is_lattice else ks.inst_cap)
	var need_vis_sync := ks.last_visible != target_vis
	var min_x := vrect.x - VRECT_MARGIN
	var min_z := vrect.y - VRECT_MARGIN
	var max_x := vrect.z + VRECT_MARGIN
	var max_z := vrect.w + VRECT_MARGIN

	if ks.is_lattice:
		if ks.dirty:
			var mv: Array[int] = []
			for s in nw:
				if _eval_lat_slot(ks, s, clock) != 0:
					mv.append(s)
			ks.moving = PackedInt32Array(mv)
			ks.dirty = false
			ks.has_written = true
			if ks.moving.is_empty():
				ks.restore_to_rec = true
				ks.emit = not ks.on_records or ks.last_visible != ks.n
				ks.on_records = true
				ks.last_visible = ks.n
			else:
				ks.on_records = false
				ks.last_visible = target_vis
				ks.emit = true
		else:
			var mv_cur := ks.moving
			var keep: Array[int] = []
			var shrunk := false
			var wrote_any := false
			for idx in mv_cur.size():
				var s: int = mv_cur[idx]
				if s < 0 or s >= nw:
					shrunk = true
					continue
				if _lat_slot_outside(ks, s, min_x, max_x, min_z, max_z):
					keep.append(s)
					continue
				wrote_any = true
				if _eval_lat_slot(ks, s, clock) != 0:
					keep.append(s)
				else:
					shrunk = true
			if shrunk:
				ks.moving = PackedInt32Array(keep)
			if ks.moving.is_empty():
				ks.restore_to_rec = true
				ks.emit = not ks.on_records or ks.last_visible != ks.n
				ks.on_records = true
				ks.last_visible = ks.n
			elif wrote_any or ks.on_records or need_vis_sync:
				ks.on_records = false
				ks.last_visible = target_vis
				ks.emit = true
	else:
		if ks.dirty:
			var mv: Array[int] = []
			for s in nw:
				if _eval_sim_slot(ks, s, clock) != 0:
					mv.append(s)
			ks.moving = PackedInt32Array(mv)
			ks.dirty = false
			ks.has_written = true
			if ks.moving.is_empty():
				ks.restore_to_rec = true
				ks.emit = not ks.on_records or ks.last_visible != ks.n
				ks.on_records = true
				ks.last_visible = ks.n
			else:
				ks.on_records = false
				ks.last_visible = target_vis
				ks.emit = true
		else:
			var mv_cur := ks.moving
			var keep: Array[int] = []
			var shrunk := false
			var wrote_any := false
			for idx in mv_cur.size():
				var s: int = mv_cur[idx]
				if s < 0 or s >= nw:
					shrunk = true
					continue
				if _sim_slot_outside(ks, s, min_x, max_x, min_z, max_z):
					keep.append(s)
					continue
				wrote_any = true
				if _eval_sim_slot(ks, s, clock) != 0:
					keep.append(s)
				else:
					shrunk = true
			if shrunk:
				ks.moving = PackedInt32Array(keep)
			if ks.moving.is_empty():
				ks.restore_to_rec = true
				ks.emit = not ks.on_records or ks.last_visible != ks.n
				ks.on_records = true
				ks.last_visible = ks.n
			elif wrote_any or ks.on_records or need_vis_sync:
				ks.on_records = false
				ks.last_visible = target_vis
				ks.emit = true


func _sim_slot_outside(ks: KindState, s: int, min_x: float, max_x: float, min_z: float, max_z: float) -> bool:
	var per := _rec_per_page
	if per <= 0:
		return false
	var r := ks.base + s
	var p0 := r / per
	if r < 0 or p0 >= _rec_pages.size() or (r - p0 * per) * 16 + 16 > _rec_pages[p0].size():
		return false
	var pg: PackedFloat32Array = _rec_pages[p0]
	var ro := (r - p0 * per) * 16
	if pg[ro + 13] > 0.5:
		var r_src := r + roundi(pg[ro + 12])
		var ps := r_src / per
		if r_src < 0 or ps >= _rec_pages.size() or (r_src - ps * per) * 16 + 16 > _rec_pages[ps].size():
			return false
		pg = _rec_pages[ps]
		ro = (r_src - ps * per) * 16
	if pg[ro + 11] >= 0.5:
		return false
	var ax: float = pg[ro + 0]
	var az: float = pg[ro + 2]
	var bx: float = pg[ro + 4]
	var bz: float = pg[ro + 6]
	var lo_x := minf(ax, ax + bx)
	var hi_x := maxf(ax, ax + bx)
	var lo_z := minf(az, az + bz)
	var hi_z := maxf(az, az + bz)
	return hi_x < min_x or lo_x > max_x or hi_z < min_z or lo_z > max_z


func _lat_slot_outside(ks: KindState, s: int, min_x: float, max_x: float, min_z: float, max_z: float) -> bool:
	var per := _lat_per_page
	if per <= 0:
		return false
	var r := ks.base + s
	var p0 := r / per
	if r < 0 or p0 >= _lat_pages.size() or (r - p0 * per) * 16 + 16 > _lat_pages[p0].size():
		return false
	var pg: PackedFloat32Array = _lat_pages[p0]
	var ro := (r - p0 * per) * 16
	if pg[ro + 13] > 0.5:
		var r_src := r + roundi(pg[ro + 12])
		var ps := r_src / per
		if r_src < 0 or ps >= _lat_pages.size() or (r_src - ps * per) * 16 + 16 > _lat_pages[ps].size():
			return false
		pg = _lat_pages[ps]
		ro = (r_src - ps * per) * 16
	if pg[ro + 11] >= 0.5:
		return false
	var ax: float = pg[ro + 0]
	var az: float = pg[ro + 2]
	var bx: float = pg[ro + 4]
	var bz: float = pg[ro + 6]
	var lo_x := minf(ax - bx, minf(ax, ax + bx))
	var hi_x := maxf(ax - bx, maxf(ax, ax + bx))
	var lo_z := minf(az - bz, minf(az, az + bz))
	var hi_z := maxf(az - bz, maxf(az, az + bz))
	return hi_x < min_x or lo_x > max_x or hi_z < min_z or lo_z > max_z


func _eval_sim_slot(ks: KindState, s: int, clock: float) -> int:
	var bo := s * STRIDE
	var per := _rec_per_page
	if per <= 0:
		_hide_slot(ks.buf, bo)
		return 0
	var r := ks.base + s
	var p0 := r / per
	if r < 0 or p0 >= _rec_pages.size() or (r - p0 * per) * 16 + 16 > _rec_pages[p0].size():
		_hide_slot(ks.buf, bo)
		return 0
	var pg0: PackedFloat32Array = _rec_pages[p0]
	var ro0 := (r - p0 * per) * 16
	var dx: float = pg0[ro0 + 12]
	var dy: float = pg0[ro0 + 13]
	var dz: float = pg0[ro0 + 14]
	var dw: float = pg0[ro0 + 15]
	var is_copy := dy > 0.5
	var own_cx := 1.0
	var own_cy := 0.0
	var pg := pg0
	var ro := ro0
	var ew := dw
	if is_copy:
		own_cx = pg0[ro0 + 8]
		own_cy = pg0[ro0 + 9]
		var r_src := r + roundi(dx)
		var ps := r_src / per
		if r_src < 0 or ps >= _rec_pages.size() or (r_src - ps * per) * 16 + 16 > _rec_pages[ps].size():
			_hide_slot(ks.buf, bo)
			return 0
		pg = _rec_pages[ps]
		ro = (r_src - ps * per) * 16
		ew = pg[ro + 15]
	var cw: float = pg[ro + 11]
	if cw < -0.5:
		_hide_slot(ks.buf, bo)
		return 0
	var ax: float = pg[ro + 0]
	var ay: float = pg[ro + 1]
	var az: float = pg[ro + 2]
	var aw: float = pg[ro + 3]
	var bx: float = pg[ro + 4]
	var by: float = pg[ro + 5]
	var bz: float = pg[ro + 6]
	var bw: float = pg[ro + 7]
	var base_cx: float = pg[ro + 8]
	var base_cy: float = pg[ro + 9]
	var cz: float = pg[ro + 10]
	var cx := base_cx
	var cy := base_cy
	if is_copy:
		cz += dz * dy
		cx = own_cx
		cy = own_cy
	var lh := ItemCards._lattice_hash(roundi(base_cy * 100000.0), roundi((base_cx + 2.0) * 100000.0))
	var jit := float((lh >> 16) & 65535) / 32767.5 - 1.0
	var still_moving := (bw > aw and bw > clock) or (ew > 0.0 and ew > clock) or (ew < 0.0 and -ew > clock)
	var handoff_hide := (ew > 0.0 and clock >= ew) or (ew < 0.0 and clock < -ew)
	var g := clampf((clock - aw) / (bw - aw), 0.0, 1.0) if bw > aw else 1.0
	var at_x := ax
	var at_y := ay
	var at_z := az
	var vis := not handoff_hide
	if cw < 0.5:
		at_x += bx * g
		at_y += by * g
		at_z += bz * g
	else:
		var po := _path_at(roundi(cw) - 1, g)
		if po.w < 0.5:
			vis = false
		else:
			at_x += po.x
			at_y += po.y
			at_z += po.z
	if vis and _mask_on and _mask_hit(at_x, at_z):
		vis = false
	_write_slot(ks.buf, bo, cx, cy, at_x, at_y + cz, at_z, 128.0 if is_copy else 0.0, jit, 0.0, SHOW_CLOCK if vis else HIDE_CLOCK)
	return 1 if still_moving else 0


func _eval_lat_slot(ks: KindState, s: int, clock: float) -> int:
	var bo0 := s * 2 * STRIDE
	var bo1 := bo0 + STRIDE
	var per := _lat_per_page
	if per <= 0:
		_hide_slot(ks.buf, bo0)
		_hide_slot(ks.buf, bo1)
		return 0
	var r := ks.base + s
	var p0 := r / per
	if r < 0 or p0 >= _lat_pages.size() or (r - p0 * per) * 16 + 16 > _lat_pages[p0].size():
		_hide_slot(ks.buf, bo0)
		_hide_slot(ks.buf, bo1)
		return 0
	var pg0: PackedFloat32Array = _lat_pages[p0]
	var ro0 := (r - p0 * per) * 16
	var dx: float = pg0[ro0 + 12]
	var dy: float = pg0[ro0 + 13]
	var dz: float = pg0[ro0 + 14]
	var dw: float = pg0[ro0 + 15]
	var is_copy := dy > 0.5
	var own_cx := 1.0
	var own_cy := 0.0
	var pg := pg0
	var ro := ro0
	var ex := dx
	var ey := dy
	var ez := dz
	var ew := dw
	if is_copy:
		own_cx = pg0[ro0 + 8]
		own_cy = pg0[ro0 + 9]
		var r_src := r + roundi(dx)
		var ps := r_src / per
		if r_src < 0 or ps >= _lat_pages.size() or (r_src - ps * per) * 16 + 16 > _lat_pages[ps].size():
			_hide_slot(ks.buf, bo0)
			_hide_slot(ks.buf, bo1)
			return 0
		pg = _lat_pages[ps]
		ro = (r_src - ps * per) * 16
		ex = pg[ro + 12]
		ey = pg[ro + 13]
		ez = pg[ro + 14]
		ew = pg[ro + 15]
	var cw: float = pg[ro + 11]
	if cw < -0.5:
		_hide_slot(ks.buf, bo0)
		_hide_slot(ks.buf, bo1)
		return 0
	var ax: float = pg[ro + 0]
	var ay: float = pg[ro + 1]
	var az: float = pg[ro + 2]
	var aw: float = pg[ro + 3]
	var bx: float = pg[ro + 4]
	var by: float = pg[ro + 5]
	var bz: float = pg[ro + 6]
	var bw: float = pg[ro + 7]
	var base_cx: float = pg[ro + 8]
	var base_cy: float = pg[ro + 9]
	var cz: float = pg[ro + 10]
	if is_copy:
		cz += dz * dy
	var lattice := ey < 0.5 and ez > 0.5
	var variants := ks.variants
	var copy_flag := 128.0 if is_copy else 0.0
	var pile_k := roundi(dy) if is_copy else 0

	if not lattice or ew <= 0.0:
		var g := clampf((clock - aw) / (bw - aw), 0.0, 1.0) if bw > aw else 1.0
		var at_x := ax + (bx * g if not lattice else 0.0)
		var at_y := ay + (by * g if not lattice else 0.0) + cz
		var at_z := az + (bz * g if not lattice else 0.0)
		var cx := own_cx if is_copy else base_cx
		var cy := own_cy if is_copy else base_cy
		var ivar := 0
		var jit := 0.0
		if lattice and ez > 1.5:
			var who := roundi(base_cx)
			var run := roundi(base_cy)
			var lh := ItemCards._lattice_hash(who, run)
			var turn := (float(lh % 2001) / 1000.0 - 1.0) * ItemCards.MAX_YAW + ItemCards.PILE_TURN * float(pile_k)
			cx = cos(turn)
			cy = sin(turn)
			if variants > 1:
				ivar = (lh >> 8) % variants
			jit = float((lh >> 16) & 65535) / 32767.5 - 1.0
		else:
			var lh2 := ItemCards._lattice_hash(roundi(base_cy * 100000.0), roundi((base_cx + 2.0) * 100000.0))
			jit = float((lh2 >> 16) & 65535) / 32767.5 - 1.0
		var vis := true
		if lattice and ex > 0.0 and clock >= ex:
			vis = false
		if vis and not lattice and ((ew > 0.0 and clock >= ew) or (ew < 0.0 and clock < -ew)):
			vis = false
		_write_slot(ks.buf, bo0, cx, cy, at_x, at_y, at_z, float(ivar) + copy_flag, jit, 0.0, SHOW_CLOCK if vis else HIDE_CLOCK)
		_hide_slot(ks.buf, bo1)
		var need_mv := (not lattice and ((bw > aw and bw > clock) or (ew > 0.0 and ew > clock) or (ew < 0.0 and -ew > clock))) \
			or (lattice and ex > 0.0 and ex > clock)
		return 1 if need_mv else 0

	var has_hi := bw > aw and by > 0.0
	var hi := bw + by * ew if has_hi else 1.0e30
	var lclock := clampf(clock, bw, hi) if bw > aw else clock
	var hclock := clampf(ex, bw, hi) if bw > aw else ex
	var q := (lclock - aw) / ew
	var slid := floori(q)
	var g := q - float(slid)
	var act_p := slid & 1
	var pre_p := 1 - act_p
	var act_bo := bo0 + act_p * STRIDE
	var pre_bo := bo0 + pre_p * STRIDE
	var after_stop := has_hi and clock >= hi

	# Active instance at (slid, g)
	var at_x := ax + bx * g
	var at_y := ay + cz
	var at_z := az + bz * g
	var cx := own_cx if is_copy else base_cx
	var cy := own_cy if is_copy else base_cy
	var ivar := 0
	var jit := 0.0
	if ez > 1.5:
		var who := roundi(base_cx) + slid
		var run := roundi(base_cy)
		var lh := ItemCards._lattice_hash(who, run)
		var turn := (float(lh % 2001) / 1000.0 - 1.0) * ItemCards.MAX_YAW + ItemCards.PILE_TURN * float(pile_k)
		cx = cos(turn)
		cy = sin(turn)
		if variants > 1:
			ivar = (lh >> 8) % variants
		jit = float((lh >> 16) & 65535) / 32767.5 - 1.0
	else:
		var lh2 := ItemCards._lattice_hash(roundi(base_cy * 100000.0), roundi((base_cx + 2.0) * 100000.0))
		jit = float((lh2 >> 16) & 65535) / 32767.5 - 1.0

	var vis_act := true
	if ex > 0.0 and clock >= ex and floori((lclock - aw) / ew) == floori((hclock - aw) / ew):
		vis_act = false
	if vis_act and ey < -0.5:
		var hy := -ey
		if (hy < 2.5 and g >= hy - 1.0) or (hy >= 2.5 and g < hy - 3.0):
			vis_act = false
	_write_slot(ks.buf, act_bo, cx, cy, at_x, at_y, at_z, float(ivar) + copy_flag, jit, 0.0, SHOW_CLOCK if vis_act else HIDE_CLOCK)

	# Pre-roll instance at (slid + 1, g - 1.0), hidden on the current frame and ready to step seamlessly
	if after_stop:
		_hide_slot(ks.buf, pre_bo)
		return 1 if (ex > 0.0 and ex > clock) else 0

	var next_slid := slid + 1
	var at_pre_x := ax + bx * (g - 1.0)
	var at_pre_y := ay + cz
	var at_pre_z := az + bz * (g - 1.0)
	var cx_p := cx
	var cy_p := cy
	var ivar_p := 0
	var jit_p := jit
	if ez > 1.5:
		var who_p := roundi(base_cx) + next_slid
		var run_p := roundi(base_cy)
		var lh_p := ItemCards._lattice_hash(who_p, run_p)
		var turn_p := (float(lh_p % 2001) / 1000.0 - 1.0) * ItemCards.MAX_YAW + ItemCards.PILE_TURN * float(pile_k)
		cx_p = cos(turn_p)
		cy_p = sin(turn_p)
		if variants > 1:
			ivar_p = (lh_p >> 8) % variants
		jit_p = float((lh_p >> 16) & 65535) / 32767.5 - 1.0

	_write_slot(ks.buf, pre_bo, cx_p, cy_p, at_pre_x, at_pre_y, at_pre_z, float(ivar_p) + copy_flag, jit_p, 0.0, HIDE_CLOCK)
	return 1


func _path_at(code: int, g: float) -> Vector4:
	var texels := _paths.size() / 4
	if code < 0 or texels <= 0:
		return Vector4.ZERO
	var first := code / 64
	var pieces := code - first * 64 + 1
	var f := clampf(g, 0.0, 1.0) * float(pieces)
	var i := mini(int(f), pieces - 1)
	var frac := f - float(i)
	var a := first + i
	if a < 0 or a >= texels:
		return Vector4.ZERO
	var oa := a * 4
	var b := mini(a + 1, texels - 1)
	var ob := b * 4
	return Vector4(
		lerpf(_paths[oa], _paths[ob], frac),
		lerpf(_paths[oa + 1], _paths[ob + 1], frac),
		lerpf(_paths[oa + 2], _paths[ob + 2], frac),
		lerpf(_paths[oa + 3], _paths[ob + 3], frac)
	)


func _mask_hit(at_x: float, at_z: float) -> bool:
	if _mask_w <= 0 or _mask_h <= 0 or _mask_tiles.size() != 16:
		return false
	var side := _mask_w * 4
	var cx := clampi(posmod(floori(at_x * 4.0), side), 0, side - 1)
	var side_z := _mask_h * 4  # (a tile that isn't square must not index past the 4x4)
	var cz := clampi(posmod(floori(at_z * 4.0), side_z), 0, side_z - 1)
	var tx := cx / _mask_w
	var tz := cz / _mask_h
	var layer := tz * 4 + tx
	var tile: PackedByteArray = _mask_tiles[layer]
	if tile.is_empty():
		return false
	var ti := (cz - tz * _mask_h) * _mask_w + (cx - tx * _mask_w)
	return ti >= 0 and ti < tile.size() and tile[ti] > 127


static func _write_slot(buf: PackedFloat32Array, bo: int, cx: float, cy: float, px: float, py: float, pz: float,
		c0: float, c1: float, c2: float, c3: float) -> void:
	buf[bo + 0] = cx
	buf[bo + 1] = 0.0
	buf[bo + 2] = cy
	buf[bo + 3] = px
	buf[bo + 4] = 0.0
	buf[bo + 5] = 1.0
	buf[bo + 6] = 0.0
	buf[bo + 7] = py
	buf[bo + 8] = -cy
	buf[bo + 9] = 0.0
	buf[bo + 10] = cx
	buf[bo + 11] = pz
	buf[bo + 12] = c0
	buf[bo + 13] = c1
	buf[bo + 14] = c2
	buf[bo + 15] = c3


static func _hide_slot(buf: PackedFloat32Array, bo: int) -> void:
	buf[bo + 0] = 1.0
	buf[bo + 1] = 0.0
	buf[bo + 2] = 0.0
	buf[bo + 3] = 0.0
	buf[bo + 4] = 0.0
	buf[bo + 5] = 1.0
	buf[bo + 6] = 0.0
	buf[bo + 7] = 0.0
	buf[bo + 8] = 0.0
	buf[bo + 9] = 0.0
	buf[bo + 10] = 1.0
	buf[bo + 11] = 0.0
	buf[bo + 12] = 0.0
	buf[bo + 13] = 0.0
	buf[bo + 14] = 0.0
	buf[bo + 15] = HIDE_CLOCK
