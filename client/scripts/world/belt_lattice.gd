extends RefCounted
## --belt-draw-lattice: lanes the game has packed are drawn packed (owner's concession). Items on a belt
## sit 0.25 tile apart, so a lane full of one kind drawn as a row of that item every 0.25 tile, at any
## phase, has each of the game's items within 0.125 tile of one drawn: such a lane needs no simulated
## positions or ids, only "full, kind X". (tools: the lattice job's rescore of the every-tick capture at
## -62,-26: 97% of the game's items were on lanes full of one kind, and 96% of what the simulation
## missed was on them; docs/BELT-SIM-PLAN.md.)
##
## Which lanes: those the bridge's last read of the lane (`sl`) found full of one kind, while its drift
## checks (`pc`) after say it is still full (full: as many items as whole gaps fit in its length, every gap
## at most 66). A lane read with gaps or two kinds, or checked short, is drawn from the simulation again.
## Underground lines under the ground, loaders and other lanes keep the simulation's items.
##
## How: each such lane in view gets a lattice: one record a slot, every 64 (1/256 tile) from the
## simulation's front item on the lane (its phase), sliding at that item's speed: the record's texel 3
## holds the lattice's period (ticks per gap) and the shader takes the drawn clock modulo it, so a
## moving lattice costs nothing until its speed changes (the simulation's front item standing or moving at
## two checks in a row: a stop-and-go lane is drawn as it was) or its phase drifts DRIFT off the
## simulation's. A speed change keeps the lattice where it is drawn, so it never jumps; any phase draws a
## full lane within 0.125 tile of the game's items, so the phase is only made again for a big drift.
## The simulation's items on those lanes stay simulated, but the shader hides every item record whose
## place falls in a cell of the lanes' mask (CELLS a tile, MASK cells a side, wrapping): a lane's
## centre line marks its cells, so an item gliding off a lattice lane onto a loose one shows again.
## The lattice has its own records (f3d_belt_lattice) and its own MultiMeshes (item_cards.gd with
## record_tex 1), the same for the GDScript and the C++ records paths: it is made in GDScript from the
## messages, the lane meta and BeltSim.lane_fronts (the C++ simulation's when loaded).
##
## Stacks: a lane's slots are piles as high as the stacks its last read (`sl`) found most often (a stack
## inserter's bus is stacks of 4 throughout): each slot has STACK records, the slot's own and a copy per
## step above it, the copies pointing at the slot's record as belt_items.gd's piles do (texel 3: the slot
## from the copy, its step k, the kind's pile step; texel 2 its own turn, PILE_TURN more each from the
## slot's yaw, cards and blocks too), so they slide with the slot and the mask never hides them.

const BeltRecords := preload("res://scripts/world/belt_records.gd")
const BeltSim := preload("res://scripts/world/belt_sim.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")

const GAP := 64
const CELLS := 4
const MASK := 2048
## A drawn lattice whose phase is this far (1/256) off the simulation's front item, or whose speed
## differs, is made again.
const DRIFT := 24
## Checks in a row a new speed must be seen at before the lattice takes it.
const SPEED_CHECKS := 2
## Records hold this much below their item's lift, as the items' do (belt_items.gd LAYER_STEP).
const LAYER_STEP := 0.006
const LAYERS := 4
## Lanes longer than this (1/256) are never drawn as a lattice (a belt's lanes are at most 2 tiles; a
## message with another length is malformed: its slots and mask cells would run to millions).
const MAX_LENGTH := 1024
## Lanes are drawn when their middle is within the camera's view grown by VIEW_KEEP (tiles); that ground
## is planned again when the view leaves it.
const VIEW_KEEP := 12.0
## A drawn lattice's phase is checked against the simulation's every SLICES updates (a slice of the lanes
## each), and at once when the bridge reads or checks the lane.
const SLICES := 2
## As belt_items.gd's: a stack is at most this many, each copy above turned PILE_TURN more.
const MAX_STACK := 4
const PILE_TURN := 0.45

## --belt-draw-lattice=off: every lane drawn from the simulation (as before).
static var on := true
## On (the default; --belt-draw-lattice=sim: off): a straight lane's (and an underground's visible
## half's) lattice has the map's phase, a function of where its exit is and the tick alone (items at
## tau = v * t mod 64 along its way), so the lanes of a run agree whenever each was written and wherever
## the drawn clock is; curves and splitters keep the simulation's front item's phase. Live at -62,-26
## (2 runs each): 95.7 / 95.2% visible, 2.4 / 2.5% phantoms against the simulation's phase's 94.5 / 91.9%,
## 3.5 / 3.6% (its errors were at lane ends, neighbours' phases disagreeing).
static var world := true
## --belt-draw-lattice-pile=off: every slot one item, whatever the lane's stacks (as the first cut: a bus
## of stacks of 4 drawn flat).
static var piles := true
## (unison) On (the default): every drawn lane's speed is checked against the simulation's every job,
## and a new speed is taken at once, so the lanes of a run that starts or stops moving all change in the
## same job the simulation's own records do (the map's phase then keeps their lattices in step). Off
## (--belt-draw-lattice-unison=off, as before): a slice of the lanes a job (SLICES) and a new speed only
## at SPEED_CHECKS checks in a row, so neighbouring lanes changed speed jobs apart: at each lane boundary
## the sliding lane's slots opened and closed a gap of up to 0.25 tile against the standing one (the
## owner's "shimmer of small gaps" as a backed-up line starts moving), and at the run's ends the
## simulation's items moved away from the standing lattice for two jobs.
static var unison := true

class Lane:
	var item := 0
	var kind_key := 0
	var slots := PackedInt32Array()
	var r0 := 0  # its phase: the front slot's line position on tick t0
	var t0 := 0
	var v := 0
	var pend_v := -1  # a new speed seen at pend_n checks in a row
	var pend_n := 0
	var cells := PackedInt32Array()
	var stack := 1  # records a slot: ln.slots[k * stack + j] is slot k's copy j (0: its own record)


class LKind:
	var base := -1
	var cap := 0
	var top := 0
	var free: Array[int] = []
	var told := Vector3i(-1, -1, -1)


var info := {}  # lane key -> [full (bool), item id (-1: none or mixed), stack (the read's most common)]
var drawn := {}  # lane key -> Lane
var kinds := {}  # kind key -> LKind
var records := BeltRecords.new()
var mask: Image = null
var mask_n := PackedByteArray()  # lanes marking each cell
var mask_dirty := false
var lanes_n := 0  # lanes drawn after the last update
var slots_n := 0
var want := {}  # lane key -> item: lanes to draw (full of one kind, in the planned ground)
var undrawn := {}  # lane keys wanted but not drawn yet (their look not known yet)
var dirty := {}  # lane keys read, checked or dropped since the last update
var mids := {}  # lane key -> Vector2: its middle (tiles)
var planned := Rect2()
var planned_all := false
var planned_any := false
var round_no := 0
var planned_cap := -2


## A lane read in full (`sl`): items as [uid, item id, pos, stack] four a lane item, front first.
func note_read(key: int, length: int, items: PackedInt64Array) -> void:
	var n := items.size() / 4
	if n == 0:
		info[key] = [false, -1, 1]
		dirty[key] = true
		return
	dirty[key] = true
	var item := int(items[1])
	var full := n >= maxi(1, length / GAP)
	var counts := PackedInt32Array()
	counts.resize(MAX_STACK + 1)
	for j in n:
		counts[clampi(int(items[j * 4 + 3]), 1, MAX_STACK)] += 1
		if j == 0:
			continue
		if int(items[j * 4 + 1]) != item:
			info[key] = [false, -1, 1]
			return
		if int(items[j * 4 + 2]) - int(items[j * 4 - 2]) > GAP + 2:
			full = false
	var stack := 1
	for c in range(2, MAX_STACK + 1):
		if counts[c] > counts[stack]:
			stack = c
	info[key] = [full, item, stack]


## A lane's drift check (`pc`): count, smallest and largest position.
func note_check(key: int, length: int, count: int, front: int, back: int) -> void:
	var e: Array = info.get(key, [false, -1, 1])
	e[0] = count >= maxi(1, length / GAP) and count <= length / GAP + 2 and back - front <= (GAP + 2) * (count - 1)
	info[key] = e
	dirty[key] = true


func drop(key: int) -> void:
	info.erase(key)
	mids.erase(key)
	dirty[key] = true


## Whether any lane is drawn as a lattice now (belt_items.gd: the update runs while any is, the switch off too).
func has_drawn() -> bool:
	return not drawn.is_empty()


## The update after a job's simulation: lanes in or out of the lattice, phases made again. Returns
## {written: [[kind key, base, n, cap], ...], pages, mask (Image or null), unknown: [kind keys]}; with
## `dump`, dump_ids / dump_recs / dump_gone as belt_items.gd's --belt-draw-dump writes them.
func update(job_state, sim, tick: int, view: Rect2, view_all: bool, known: Dictionary, model_cap: int, full: bool,
		dump: bool) -> Dictionary:
	var lanes: Dictionary = job_state.lanes
	var res := {"written": [], "unknown": [], "dump_ids": PackedInt64Array(), "dump_recs": PackedFloat32Array(),
		"dump_gone": PackedInt64Array(), "mask": null, "dump_on": dump}
	records.base = job_state.records.base
	# Which lanes to draw: all again when the planned ground or the look changed, else only those the
	# bridge said something about.
	var replan := full or view_all != planned_all or not planned_any or (not view_all and not planned.encloses(view)) 		or model_cap != planned_cap
	var look_at: Array
	if replan:
		planned_cap = model_cap
		planned = view.grow(VIEW_KEEP)
		planned_all = view_all
		planned_any = true
		want.clear()
		undrawn.clear()
		look_at = info.keys()
		for key: int in drawn:
			if not info.has(key):
				look_at.append(key)
	else:
		look_at = dirty.keys()
	# (A lane's stacks change only with a read: a drawn lane checked for its phase alone keeps its own.)
	var heard := dirty
	dirty = {}
	var check := {}  # lanes to draw or check now
	for key: int in look_at:
		var item := _wanted(job_state, key, lanes)
		if item < 0:
			want.erase(key)
			undrawn.erase(key)
		else:
			want[key] = item
			check[key] = true
			if not drawn.has(key):
				undrawn[key] = true
	var unknown := {}
	for key: int in (drawn.keys() if replan else look_at):
		if not drawn.has(key):
			continue
		var ln: Lane = drawn[key]
		if not want.has(key) or want[key] != ln.item or ln.kind_key != _kind_key(want[key], model_cap):
			_remove(key, res)
			if want.has(key):
				undrawn[key] = true
	# A slice of the drawn lanes has its phase checked against the simulation's each update.
	round_no += 1
	var slice := round_no % SLICES
	for key: int in drawn:
		if unison or posmod(key >> 3, SLICES) == slice:
			check[key] = true
	for key: int in undrawn:
		check[key] = true
	var keys := PackedInt64Array()
	for key: int in check:
		if want.has(key):
			keys.append(key)
	var fronts: PackedInt32Array = sim.lane_fronts(keys) if not keys.is_empty() else PackedInt32Array()
	var base: float = records.base
	for q in keys.size():
		var key := keys[q]
		var item: int = want[key]
		var kk := _kind_key(item, model_cap)
		var look: Array = known.get(kk, [])
		if look.is_empty():
			unknown[kk] = true
			continue
		var m: PackedInt32Array = lanes[key]
		var f := fronts[q * 3]
		var v := fronts[q * 3 + 1]
		var has := fronts[q * 3 + 2] > 0
		var ln: Lane = drawn.get(key)
		var wl := world and (m[0] == BeltSim.STRAIGHT or m[0] == BeltSim.UG_VISIBLE)
		var st := _stack_of(key) if ln == null or replan or heard.has(key) else ln.stack
		# (A lane whose stacks changed is made again with its new piles, its phase as a new lane's.)
		if ln != null and ln.stack == st:
			if not has:
				continue  # (the simulation has none there: the lattice goes on as it was)
			var pred := posmod(ln.r0 - ln.v * (tick - ln.t0), GAP)
			if v != ln.v:
				if v == ln.pend_v:
					ln.pend_n += 1
				else:
					ln.pend_v = v
					ln.pend_n = 1
				if ln.pend_n < (1 if unison else SPEED_CHECKS):
					continue
				# (Its new speed from where it is drawn now; the map's phase at it, world.)
				ln.pend_n = 0
				ln.r0 = posmod(_world_phase(m) - v * tick, GAP) if wl else pred
				ln.v = v
				ln.t0 = tick
				_write_lane(job_state, key, ln, m, look, base, res, st)
				continue
			ln.pend_n = 0
			if wl:
				continue  # (the map's phase: nothing drifts)
			var off := absi(pred - posmod(f, GAP))
			if mini(off, GAP - off) <= DRIFT:
				continue
		elif ln == null:
			ln = Lane.new()
			ln.item = item
			ln.kind_key = kk
			drawn[key] = ln
			undrawn.erase(key)
			_mark(job_state, key, ln, 1)
		if wl:
			ln.v = v if has else 0
			ln.r0 = posmod(_world_phase(m) - ln.v * tick, GAP)
		elif has:
			ln.r0 = posmod(f, GAP)
			ln.v = v
		else:
			ln.r0 = _world_phase(m)
			ln.v = 0
		ln.t0 = tick
		_write_lane(job_state, key, ln, m, look, base, res, st)
	for kk in kinds:
		var kd: LKind = kinds[kk]
		var told := Vector3i(kd.base, kd.top, kd.cap)
		if full or told != kd.told:
			kd.told = told
			res["written"].append([kk, kd.base, kd.top, kd.cap])
	res["unknown"] = unknown.keys()
	res["pages"] = records.take_pages()
	if mask_dirty:
		mask_dirty = false
		res["mask"] = mask
	lanes_n = drawn.size()
	slots_n = 0
	for kk in kinds:
		slots_n += (kinds[kk] as LKind).top - (kinds[kk] as LKind).free.size()
	return res


## How high a lane's piles are drawn: its last read's most common stack (1 with --belt-draw-lattice-pile=off).
func _stack_of(key: int) -> int:
	if not piles:
		return 1
	var e: Array = info.get(key, [])
	return clampi(int(e[2]), 1, MAX_STACK) if e.size() > 2 else 1


## The item a lane is drawn as a lattice of, or -1: full of one kind, of a kind drawn so, in the planned
## ground.
func _wanted(job_state, key: int, lanes: Dictionary) -> int:
	if not on:
		return -1
	var e: Array = info.get(key, [])
	if e.is_empty() or not e[0] or int(e[1]) < 0:
		return -1
	var m: PackedInt32Array = lanes.get(key, PackedInt32Array())
	if m.is_empty() or not _drawn_kind(m[0]) or m[1] <= 0 or m[1] > MAX_LENGTH:
		return -1
	if not planned_all:
		var mid: Vector2
		if mids.has(key):
			mid = mids[key]
		else:
			var p := _point(job_state, key, m[1] * 0.5)
			mid = Vector2(p.x, p.z)
			mids[key] = mid
		if not planned.has_point(mid):
			return -1
	return int(e[1])


static func _drawn_kind(kind: int) -> bool:
	return kind == BeltSim.STRAIGHT or kind == BeltSim.CURVE or kind == BeltSim.UG_VISIBLE or kind == BeltSim.SPLIT_IN \
		or kind == BeltSim.SPLIT_OUT


## Its kind key as belt_items.gd's: the item, or its icon past an Items in 3D cap.
static func _kind_key(item: int, model_cap: int) -> int:
	return item if model_cap < 0 else ItemCards.icon_key(item)


## A lane the simulation has no item on: a lattice fixed to the map along its exit's direction, so the
## lanes of a straight run agree.
static func _world_phase(m: PackedInt32Array) -> int:
	var dx := m[3] - m[5]
	var dy := m[4] - m[6]
	var tau: int
	if absi(dx) >= absi(dy):
		tau = m[3] if dx > 0 else -m[3]
	else:
		tau = m[4] if dy > 0 else -m[4]
	return posmod(tau, GAP)


func _remove(key: int, res: Dictionary) -> void:
	var ln: Lane = drawn[key]
	drawn.erase(key)
	var kd: LKind = kinds.get(ln.kind_key)
	for i in ln.slots.size():
		if kd != null:
			records.hide(kd.base + ln.slots[i])
			kd.free.append(ln.slots[i])
		if i % ln.stack == 0:
			res["dump_gone"].append(_uid(key, i / ln.stack))
	_unmark(ln)


static func _uid(key: int, k: int) -> int:
	return -(key * 8 + k + 1)


## The lane's slots: one record each, every GAP from its phase; sliding a gap a period, or standing.
## A moving lane's slot k cycles within its own gap of the lane, [64k, 64k + 64), so a lane's lattice
## never runs past its ends onto the next lane's (whose phase can differ): ceil(length / 64) slots, the
## last one's gap reaching past a curve's entry. A standing lane's slots stand on its phase.
## With stacks of `stack`, each slot is a pile: its record and stack - 1 copies pointing at it (written
## when placed: they follow the slot's record wherever it is written again).
func _write_lane(job_state, key: int, ln: Lane, m: PackedInt32Array, look: Array, base: float, res: Dictionary,
		stack := 1) -> void:
	var length := m[1]
	if length <= 0 or length > MAX_LENGTH:
		return
	var moving := ln.v > 0
	var n := 0
	if moving:
		n = maxi(1, ceili(float(length) / GAP))
	else:
		var q := ln.r0
		while q < length:
			n += 1
			q += GAP
	var kd: LKind = kinds.get(ln.kind_key)
	if kd == null:
		kd = LKind.new()
		kinds[ln.kind_key] = kd
	if stack != ln.stack:
		# (Its piles' height changed: every slot placed again.)
		while not ln.slots.is_empty():
			_drop_slot(key, ln, kd, res)
		ln.stack = stack
	var st := ln.stack
	while ln.slots.size() > n * st:
		_drop_slot(key, ln, kd, res)
	var placed := ln.slots.size()
	while ln.slots.size() < n * st:
		var s: int
		if not kd.free.is_empty():
			s = kd.free.pop_back()
		else:
			s = kd.top
			kd.top += 1
			if kd.top > kd.cap or kd.base < 0:
				var cap := BeltRecords.MIN_RUN
				while cap < kd.top:
					cap *= 2
				var nb := records.alloc(cap)
				if kd.base >= 0:
					records.copy(kd.base, nb, kd.cap)
					records.release(kd.base, kd.cap)
				for i in range(kd.cap, cap):
					records.hide(nb + i)
				kd.base = nb
				kd.cap = cap
		ln.slots.append(s)
	var lift: Vector3 = look[0]
	var pile_step := float(look[2]) if look.size() > 2 else 0.07
	var period := float(GAP) / float(ln.v) if moving else 0.0
	var ends := _ends(job_state, key, length)
	# (Its clock from where slot k is at 64k + r0 on tick t0: the shader's fract() starts at (64 - r0) / 64.)
	var t_start := float(ln.t0) - base
	if moving:
		t_start -= float(GAP - ln.r0) / float(GAP) * period
	# (Taken out while written: written through a second reference, the whole array was copied each lane.)
	var d := records.data
	records.data = PackedFloat32Array()
	for k in n:
		var top := float(GAP * (k + 1)) if moving else float(ln.r0 + GAP * k)
		var p := _along(job_state, key, top, length, ends)
		var to := _along(job_state, key, float(GAP * k), length, ends) if moving else p
		var uid := _uid(key, k)
		# Turned as every item is (ItemCards.turn_for), icon cards too.
		var a := ItemCards.turn_for(uid)
		var c := cos(a)
		var s := sin(a)
		var r := kd.base + ln.slots[k * st]
		var o := r * BeltRecords.FLOATS
		d[o] = p.x
		d[o + 1] = p.y
		d[o + 2] = p.z
		d[o + 3] = t_start
		if period > 0.0:
			d[o + 4] = to.x - p.x
			d[o + 5] = 0.0
			d[o + 6] = to.z - p.z
		else:
			d[o + 4] = 0.0
			d[o + 5] = 0.0
			d[o + 6] = 0.0
		d[o + 7] = t_start
		d[o + 8] = c
		d[o + 9] = s
		d[o + 10] = lift.y + LAYER_STEP * (posmod(uid, LAYERS))
		d[o + 11] = 0.0 if p.w >= 0.5 else BeltRecords.HIDDEN
		d[o + 12] = 0.0
		d[o + 13] = 0.0
		d[o + 14] = 1.0  # a lattice slot (not masked)
		d[o + 15] = period
		records.dirty[r / BeltRecords.PER_PAGE] = true
		# Its pile's copies, when placed: the slot's yaw (the stable seed of its lane and place, turned or
		# not) and PILE_TURN more each, k pile steps up, read from the slot's record by the shader.
		for j in range(1, st):
			var i := k * st + j
			if i < placed:
				continue
			var rc := kd.base + ln.slots[i]
			var oc := rc * BeltRecords.FLOATS
			var ca := ItemCards.turn_for(uid, j)
			for q in BeltRecords.FLOATS:
				d[oc + q] = 0.0
			d[oc + 8] = cos(ca)
			d[oc + 9] = sin(ca)
			d[oc + 12] = float(r - rc)
			d[oc + 13] = float(j)
			d[oc + 14] = pile_step
			records.dirty[rc / BeltRecords.PER_PAGE] = true
		if bool(res["dump_on"]):
			res["dump_ids"].append_array(PackedInt64Array([uid, ln.item, st, key, ln.r0 + GAP * k, ln.t0, ln.v, 0]))
			res["dump_recs"].append_array(d.slice(o, o + BeltRecords.FLOATS))
	records.data = d


## The lane's last record let go (hidden, its slot free); a slot's own record's going is dumped.
func _drop_slot(key: int, ln: Lane, kd: LKind, res: Dictionary) -> void:
	var i := ln.slots.size() - 1
	var s := ln.slots[i]
	records.hide(kd.base + s)
	kd.free.append(s)
	if i % ln.stack == 0:
		res["dump_gone"].append(_uid(key, i / ln.stack))
	ln.slots.resize(i)


## A lane's exit and entry and the way items go there: [exit, direction there, entry, direction there].
static func _ends(job_state, key: int, length: int) -> Array:
	var exit := _point(job_state, key, 0.0)
	var ahead := _point(job_state, key, minf(32.0, float(length)))
	var entry := _point(job_state, key, float(length))
	var behind := _point(job_state, key, maxf(0.0, float(length) - 32.0))
	return [exit, Vector2(exit.x - ahead.x, exit.z - ahead.z).normalized(), entry,
		Vector2(behind.x - entry.x, behind.z - entry.z).normalized()]


## _point, carried on straight past either end.
static func _along(job_state, key: int, pos: float, length: int, ends: Array) -> Vector4:
	if pos < 0.0:
		var e: Vector4 = ends[0]
		var dv: Vector2 = ends[1]
		return Vector4(e.x - dv.x * pos / 256.0, e.y, e.z - dv.y * pos / 256.0, e.w)
	if pos > float(length):
		var e: Vector4 = ends[2]
		var dv: Vector2 = ends[3]
		var past := (pos - float(length)) / 256.0
		return Vector4(e.x - dv.x * past, e.y, e.z - dv.y * past, e.w)
	return _point(job_state, key, pos)


## Where line position `pos` of lane `key` is: belt_items.gd's Job._point.
static func _point(job_state, key: int, pos: float) -> Vector4:
	var m: PackedInt32Array = job_state.lanes.get(key, PackedInt32Array())
	if m.is_empty():
		return Vector4(0.0, job_state.height, 0.0, 0.0)
	var f := clampf(pos / float(maxi(m[1], 1)), 0.0, 1.0)
	var x: float
	var y: float
	if m[0] == BeltSim.CURVE and job_state.arcs.has(key) and not (job_state.arcs[key] as PackedFloat64Array).is_empty():
		var arc: PackedFloat64Array = job_state.arcs[key]
		var a := arc[3] + arc[4] * f
		x = arc[0] + cos(a) * arc[2]
		y = arc[1] + sin(a) * arc[2]
	else:
		x = lerpf(float(m[3]), float(m[7]), f)
		y = lerpf(float(m[4]), float(m[8]), f)
	return Vector4(x / 256.0, job_state.height, y / 256.0, 0.0 if m[0] == BeltSim.UG_HIDDEN else 1.0)


## The mask's cells along a lane's centre line (sampled every 1/32 tile).
func _mark(job_state, key: int, ln: Lane, _add: int) -> void:
	if mask == null:
		mask = Image.create(MASK, MASK, false, Image.FORMAT_R8)
		mask_n = PackedByteArray()
		mask_n.resize(MASK * MASK)
	var m: PackedInt32Array = job_state.lanes[key]
	var length := clampi(m[1], 0, MAX_LENGTH)
	var seen := {}
	var steps := maxi(1, length / 8)
	for j in steps + 1:
		var p := _point(job_state, key, float(length) * j / steps)
		var cx := posmod(floori(p.x * CELLS), MASK)
		var cz := posmod(floori(p.z * CELLS), MASK)
		var c := cz * MASK + cx
		if seen.has(c):
			continue
		seen[c] = true
		ln.cells.append(c)
		if mask_n[c] < 255:
			mask_n[c] += 1
		if mask_n[c] == 1:
			mask.set_pixel(cx, cz, Color(1.0, 0.0, 0.0))
			mask_dirty = true


func _unmark(ln: Lane) -> void:
	for c in ln.cells:
		if mask_n[c] > 0:
			mask_n[c] -= 1
			if mask_n[c] == 0:
				mask.set_pixel(c % MASK, c / MASK, Color(0.0, 0.0, 0.0))
				mask_dirty = true
	ln.cells = PackedInt32Array()


## Every lane given up (the lattice switched off, a reset): records hidden, the mask cleared.
func clear(res_gone: PackedInt64Array) -> void:
	var res := {"dump_gone": res_gone}
	for key: int in drawn.keys():
		_remove(key, res)
