extends Node3D
## Items on belts far away: past the area where belt_items.gd draws every item, each lane
## of each belt is drawn as flat icons of what it carries, the way Factorio's zoomed-out view
## reads. The mod sends what each lane carries per chunk when it changes (`bfar`), out to the
## "Belt items far away" distance, which this asks for (`bfar` command). One MultiMesh per chunk per
## item; the shader leaves out the belts belt_items.gd draws the real items of: each icon carries its
## belt's centre, and a belt whose centre lies in the square the items were read round has no
## icons, so the two hand over belt by belt with nothing drawn twice (a 2-tile overlap drew items
## twice there).
##
## A lane is drawn with as many icons as it holds items (`bfar` c, up to 4 a belt), so a full belt
## reads full, piled when stack inserters put more items on it than that (`bfar` h). A chunk full of belts is thousands of icons: their buffers are worked out on a
## worker thread (Job), and the MultiMeshes made from them within a few milliseconds a frame. An
## item's icon not loaded yet is loaded on a worker too (IconJob), and its chunks wait for it: a
## tinted icon is composed pixel by pixel, which is what made one message take 30 ms (D6's probe).

const ProtoDB := preload("res://scripts/world/protos.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
const FrameBudget := preload("res://scripts/world/frame_budget.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const WorldMirror := preload("res://scripts/world/world.gd")
const LaneShader := preload("res://shaders/belt_lane_icon.gdshader")
const LaneModelShader := preload("res://shaders/belt_lane_model.gdshader")
const ItemCards := preload("res://scripts/world/item_cards.gd")
const ItemModels := preload("res://scripts/world/item_models.gd")

## Before the mod says which square it read (an older mod), lane icons start this far inside the
## distance round the focus, so there is no gap.
const NEAR_OVERLAP := 2.0
## Floats per icon in a MultiMesh buffer: its transform (12) and custom data (its belt's centre).
const STRIDE := 16
## As big as the items' cards near the focus (item_cards.gd), so the hand-over doesn't show.
const ICON := 0.32
## A lane's centre is this far either side of the belt's (measured in 2.1.23).
const LANE := 0.234
## A pile's copies: as belt_items.gd piles an icon card's (ItemCards.CARD_PILE).
const PILE := 0.07
const AHEADS := [Vector2(0, -1), Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0)]
const RIGHTS := [Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0), Vector2(0, -1)]
## A far model pile's copies turn this much more each (belt_items.gd's PILE_TURN).
const PILE_TURN := 0.45
## Neighbouring icons on a full lane overlap: every other one sits this much higher, so they don't
## fight over the pixels they share (as belt_items.gd's LAYER_STEP).
const LAYER_STEP := 0.006
## Main-thread time a frame may spend making chunks' MultiMeshes: its slice in frame_budget.gd
## (`lanes`).

var protos: ProtoDB
var world: WorldMirror
## Tiles from the focus; 0 draws nothing. Sent to the mod when it changes or after a (re)connect.
var distance := 160
## Tiles from the focus within which the mod may send items on belts moving (belt_items.gd draws
## them), sent with the `bfar` command (n): the Belt item distance, up to MOVING_MAX. How far they
## really move is as far as `cap` allows: the most items and lanes an update reads (Moving belt items,
## `bfar` m), ring by ring from the focus; the mod says where it stopped (bi fr) and the icons
## start there.
var near := 24
const MOVING_MAX := 640
## 0: Unlimited (every item within `near` moves).
var cap := 6000
var _sent_cap := -1
## Moving belt items. Unlimited (0) as a number the UPS governor's caps compare with (it may still hold
## it back while the game runs slow, as it does every distance).
const UNLIMITED := 1.0e9


## Moving belt items' Automatic (the setting -1): the cap follows the room the frames and the game
## have, a rolling value worked out in _auto() between AUTO_MIN and AUTO_MAX.
const AUTO := -1
const AUTO_MIN := 1000.0
const AUTO_MAX := 48000.0
static var auto_cap := 6000.0
## Set by main.gd: Automatic is chosen, the UPS governor's hold on the cap, the governor (its UPS).
var auto := false
var updates_hold := UNLIMITED
var governor: Node = null
var _frames := PackedFloat32Array()  # frame times (ms) since the last decision
var _auto_t := 0.0
## And the server's tick: reading the moving items costs the bridge work units (about 2 us each on
## the owner's PC), which each update reports (`bi` w, set here as units a tick by belt_items.gd; -1
## before the mod says). Automatic grows the cap only while a fifth more would still fit AUTO_WORK
## units a tick, and shrinks it once the reading runs a quarter over. (With the frames and the game's
## speed alone as its guide it grew while they had room, and reading belts costs about what it reads:
## on Zenith Test at the busy belts 6,000 items took about 1,200 units a tick, 48,000 about 9,200,
## 17 ms. 0.1.2 had a fixed 6,000; standing there the bridge went from 7.1 ms a tick in 0.1.2 to 12.9
## in 0.1.3.) 1,500 a tick, about 3 ms there, is a little more than those 6,000 items.
const AUTO_WORK := 1500.0
var bridge_work := -1.0


## An update's work a tick (belt_items.gd, from bi w / p), smoothed over a few updates: with lanes
## kept, quiet lanes are checked every other update, so one update's figure goes up and down.
func heard_work(per_tick: float) -> void:
	bridge_work = per_tick if bridge_work < 0.0 else bridge_work + (per_tick - bridge_work) * 0.25


## The value a knob works with for the setting `v` (0: Unlimited, -1: Automatic's value now).
static func cap_wanted(v: float) -> float:
	if v < 0.0:
		return auto_cap
	return UNLIMITED if v <= 0.0 else v


## What is sent (`bfar` m) for a knob's value: 0 for Unlimited, else at least 500.
static func cap_of(v: float) -> int:
	if v <= 0.0 or v >= UNLIMITED:
		return 0
	return clampi(int(v), 500, 100000)
## Every item on belts read in one tick each update (settings.gd belt_smooth): sent as `u`, the
## mod's units a tick (belt_items.lua); off, the mod's own slices.
var smooth := true
const SMOOTH_UNITS := 10000000
var _sent_smooth := -1
var focus := Vector2.ZERO
## The square belt_items.gd's items were read round (its covered()): lane icons start at its edge,
## so the two hand over where the items stop, not round the camera, which runs ahead of them while
## panning. z < 0 (not known) falls back to `near` round `focus`.
var covered := Vector3(0.0, 0.0, -1.0)
## Make each message's icons at once on the main thread (tests).
var sync := false

var _chunks := {}  # Vector2i -> Node3D (a MultiMeshInstance3D per item)
## belt_items.gd's hand-over (hand_over()): chunks whose icons stay hidden while near items still
## wait in them, and item ids whose near look isn't made yet (their icons aren't left out).
var _held := {}
var _unknown := {}
var _materials := {}  # item id -> ShaderMaterial
var _model_materials := {}  # item id -> ShaderMaterial for its far model (models())
var _steps := {}  # item id -> its model's pile step (its height), once its model is read
var _models := false  # models() when the chunks were last made: a change makes them all again
var _quad := QuadMesh.new()
var _height := 0.2
var _height_known := false
var _sent := -1
var _sent_near := -1
var _pending := {}  # Vector2i -> [l, c]: the latest message per chunk not yet given to a job
## The latest message per chunk, kept while the chunk is subscribed: the mod sends a chunk's lanes
## only when they change, and a message that arrives before the chunk itself is loaded can't be
## drawn yet, so it is drawn from here when the chunk arrives (else a steady belt stayed bare).
var _latest := {}  # Vector2i -> [l, c]
var _done: Array = []  # [chunk, buffers by item] from finished jobs, still to be made into nodes
var _job: Job = null
var _task := -1
var _icons_wanted := {}  # item id -> name: icons for the next IconJob
var _icon_job: IconJob = null
var _icon_task := -1
## The longest a frame spent making chunks' nodes, microseconds (probes).
var worst_apply_usec := 0


## One batch of chunks' icons, worked out on a worker thread: buffers only, no nodes.
class Job:
	var msgs: Array = []  # [chunk, l, c, h]
	var height := 0.2
	## Far models (models()): item id -> a pile's step for items whose model is known, laid out as
	## belt_items.gd lays its models (a slight turn each, piles by the model's height, turning).
	var steps = null
	## Curved belts in the chunks: Vector2i belt centre (1/256 tile, as `l`) -> 1 turning right,
	## -1 left; their lanes' items lie along the lane's quarter circle (belt_paths.gd's arcs).
	var curves := {}
	var results: Array = []  # [chunk, {item id: PackedFloat32Array of TRANSFORM_3D + custom instances}, steps]

	func run() -> void:
		for m: Array in msgs:
			results.append([m[0], build(m[1], m[2], height, m[3], steps, curves), steps])

	## `l` [x, y, direction, lane 1 item, lane 2 item, ...]; `counts` [lane 1, lane 2, ...] per
	## belt, or empty (an older mod: one icon a lane); `piles` the same for how high each lane's
	## stacks are, or empty (no stacks).
	static func build(l: Array, counts: Array, height: float, piles: Array = [], steps = null, curves := {}) -> Dictionary:
		var by_item := {}  # item id -> PackedFloat32Array
		var row := 0
		for i in range(0, l.size() - 4, 5):
			var at := Vector2(int(l[i]), int(l[i + 1])) / 256.0
			var a := int(l[i + 2]) / 16.0 * TAU
			var right := Vector2(cos(a), sin(a))
			var ahead := Vector2(sin(a), -cos(a))
			var turn_way := int(curves.get(Vector2i(int(l[i]), int(l[i + 1])), 0))
			for lane in 2:
				var item := int(l[i + 3 + lane])
				if item == 0:
					continue
				var n := 1
				if row * 2 + lane < counts.size():
					n = clampi(int(counts[row * 2 + lane]), 1, 4)
				var high := 1
				if row * 2 + lane < piles.size():
					high = clampi(int(piles[row * 2 + lane]), 1, 4)
				var step := PILE
				var turn := false
				if steps != null and (steps as Dictionary).has(item):
					step = float(steps[item])
					turn = true
				var buf: PackedFloat32Array = by_item.get(item, PackedFloat32Array())
				var o := buf.size()
				buf.resize(o + n * high * STRIDE)
				var side := at + right * (LANE if lane == 1 else -LANE)
				for j in n:
					# Spread evenly along the belt, as items ride; lying flat and upright, as Factorio's.
					var p := side + ahead * ((j + 0.5) / n - 0.5)
					if turn_way != 0:
						p = curve_point(at, (int(l[i + 2]) >> 2) & 3, turn_way, lane, (j + 0.5) / n)
					# Models turn a little each, as near ones (ItemCards.yaw_for), and a pile's copies more.
					var yaw := ItemCards.yaw_for(hash(Vector3i(int(l[i]), int(l[i + 1]), lane * 4 + j))) if turn else 0.0
					for h in high:
						var k := o + (j * high + h) * STRIDE
						var a2 := yaw + PILE_TURN * h if turn else 0.0
						var c := cos(a2)
						var sn := sin(a2)
						buf[k] = c
						buf[k + 2] = sn
						buf[k + 3] = p.x
						buf[k + 5] = 1.0
						buf[k + 7] = height + LAYER_STEP * (j % 2) + step * h
						buf[k + 8] = -sn
						buf[k + 10] = c
						buf[k + 11] = p.y
						# The belt's centre, which decides whether the icon or the belt's real items show.
						buf[k + 12] = at.x
						buf[k + 13] = at.y
				by_item[item] = buf
			row += 1
		return by_item

	## A point `f` (0 to 1) along a curve's lane: a quarter circle about the curve's inner corner,
	## from the edge items come in at (as belt_paths.gd's arc pieces). d: the way the belt faces (0-3
	## from north), way: 1 turning right, -1 left; lane 0 the left lane, 1 the right.
	static func curve_point(at: Vector2, d: int, way: int, lane: int, f: float) -> Vector2:
		var t := (d + 3) % 4 if way > 0 else (d + 1) % 4  # the way items come in
		var corner: Vector2 = at - AHEADS[t] * 0.5 + AHEADS[d] * 0.5
		var v: Vector2 = at - AHEADS[t] * 0.5 + RIGHTS[t] * (LANE if lane == 1 else -LANE) - corner
		var a := v.angle() + way * f * PI * 0.5
		return corner + Vector2(cos(a), sin(a)) * v.length()

	## How many icons a chunk's buffers hold.
	static func icon_count(by_item: Dictionary) -> int:
		var n := 0
		for item in by_item:
			n += (by_item[item] as PackedFloat32Array).size() / STRIDE
		return n


## Item icons loaded from the install on a worker thread, past ItemIcons' cache.
class IconJob:
	var names := {}  # item id -> name
	var textures := {}  # item id -> Texture2D or null

	func run() -> void:
		for item in names:
			textures[item] = ItemIcons.load_uncached(names[item])


func _ready() -> void:
	_quad.size = Vector2(ICON, ICON)
	_quad.orientation = PlaneMesh.FACE_Y
	# The first material made with the lane shader cost 21 ms on the main thread (Godot sets the
	# shader up then; seen on a real base): made here at start-up, as model_library.gd's warm_up().
	_material(0)
	_model_material(0)
	if world != null:
		world.entities_changed.connect(func(c: Vector2i) -> void:
			if not world.chunks.has(c):
				_pending.erase(c)
				_latest.erase(c)
				_drop(c)
			elif not _chunks.has(c) and not _pending.has(c) and _latest.has(c):
				_pending[c] = _latest[c])


func _exit_tree() -> void:
	_finish()
	_finish_icons()


func reset() -> void:
	_finish()
	_finish_icons()
	_icons_wanted.clear()
	_pending.clear()
	_latest.clear()
	_done.clear()
	for c in _chunks.keys():
		_drop(c)
	covered = Vector3(0.0, 0.0, -1.0)
	bridge_work = -1.0
	_sent = -1
	_sent_near = -1
	_sent_smooth = -1
	_sent_cap = -1


func _process(_delta: float) -> void:
	if auto:
		_auto(_delta)
	if not Bridge.world_ready:
		_sent = -1
	elif _sent != distance or _sent_near != near or _sent_smooth != int(smooth) or _sent_cap != cap:
		_sent = distance
		_sent_near = near
		_sent_smooth = int(smooth)
		_sent_cap = cap
		Bridge.send({"t": "bfar", "r": distance, "n": near, "m": cap, "u": SMOOTH_UNITS if smooth else 0})
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		_finish()
	if _task < 0 and not _pending.is_empty():
		_start()
	if _icon_task >= 0 and WorkerThreadPool.is_task_completed(_icon_task):
		_finish_icons()
	if _icon_task < 0 and not _icons_wanted.is_empty():
		_start_icons()
	if _done.is_empty():
		FrameBudget.waiting(&"lanes", 0)
	else:
		var t0 := Time.get_ticks_usec()
		var allow := FrameBudget.grant(&"lanes")
		if allow > 0:
			_apply_some(allow)
		FrameBudget.spent(&"lanes", Time.get_ticks_usec() - t0, _done.size())
	if _models != models():
		_models = models()
		for c in _latest:
			_pending[c] = _latest[c]
	# Only when what they say changed: three parameters on every item's material every frame (each
	# queues the material's uniforms to be sent again), while the square moves once an update.
	if [hand_over_centre(), near_edge(), distance, _materials.size(), _model_materials.size()] != _params_key:
		_set_params()


## Automatic: once a second, from the frames' time over the last second or two (their slowest
## tenth) against the frame's budget (16.7 ms, or the FPS cap's when it is lower) and the game's
## UPS: room to spare raises the cap a fifth, frames running long or the game slowing lowers it a
## fifth. Not while a game loads (its frames are long for other reasons).
func _auto(delta: float) -> void:
	if not Bridge.world_ready:
		_frames.clear()
		_auto_t = 0.0
		return
	_frames.append(delta * 1000.0)
	_auto_t += delta
	if _auto_t < 1.0 or _frames.size() < 20:
		return
	_auto_t = 0.0
	var sorted := _frames.duplicate()
	sorted.sort()
	var slow := sorted[int(sorted.size() * 0.9)]
	_frames.clear()
	var budget := 1000.0 / 60.0
	if Engine.max_fps > 0 and Engine.max_fps < 60:
		budget = 1000.0 / Engine.max_fps
	var ups := float(governor.get("ups")) if governor != null and is_instance_valid(governor) else 0.0
	var was := auto_cap
	# And it grows only while it is what stops the reading (the mod's square, bi fr, inside the belt
	# item distance): in an empty stretch it grew to 48,000 for nothing, and the first busy belts after
	# it were read 100,000 units at once (a 673 ms tick on Zenith Test).
	var binding := covered.z < 0.0 or covered.z < float(near) - 0.5
	if slow > budget * 1.05 or (ups > 0.0 and ups < 57.0) or bridge_work > AUTO_WORK * 1.25:
		auto_cap = maxf(auto_cap * 0.8, AUTO_MIN)
	elif slow < budget * 0.8 and (ups <= 0.0 or ups >= 59.0) and bridge_work * 1.2 <= AUTO_WORK and binding:
		auto_cap = minf(auto_cap * 1.2, AUTO_MAX)
	if auto_cap != was:
		cap = cap_of(minf(auto_cap, updates_hold))


## Far belts' items drawn as their small models: Items in 3D is
## All (with a cap the items past it are icons, and the far ones are past it).
static func models() -> bool:
	return ItemCards.use_models and ItemCards.model_cap < 0


## Every icon material's square and distance (an item belt_items.gd doesn't draw yet: no square).
## What _set_params last set: [centre, edge, distance, materials, model materials].
var _params_key: Array = []


func _set_params() -> void:
	var centre := hand_over_centre()
	var edge := near_edge()
	_params_key = [centre, edge, distance, _materials.size(), _model_materials.size()]
	for mats: Dictionary in [_materials, _model_materials]:
		for item in mats:
			var m: ShaderMaterial = mats[item]
			m.set_shader_parameter("focus", centre)
			m.set_shader_parameter("near", -1.0 if _unknown.has(int(item)) else edge)
			m.set_shader_parameter("far", float(distance))


## Called by belt_items.gd in the frame its job's result is drawn: the square its items cover,
## the chunks where items still wait for their icons, and the kinds it doesn't draw yet.
func hand_over(square: Vector3, held: Dictionary, unknown: Array) -> void:
	covered = square
	var was := _held
	_held = held
	for c in was:
		if not held.has(c) and _chunks.has(c):
			(_chunks[c] as Node3D).visible = true
	for c in held:
		if _chunks.has(c):
			(_chunks[c] as Node3D).visible = false
	_unknown = {}
	for item in unknown:
		_unknown[int(item)] = true
	_set_params()


## The chunks whose icons are made (for belt_items.gd's job: items wait only where there are none).
func built_chunks() -> Dictionary:
	var out := {}
	for c in _chunks:
		out[c] = true
	return out


## Where lane icons start: belts whose centre is this far or further from hand_over_centre() in x or
## y (the square's half side, as the mod picks the belts it reads: belt_items.lua find_band).
func near_edge() -> float:
	if covered.z >= 0.0:
		return covered.z
	return maxf(0.0, float(near) - NEAR_OVERLAP)


## The centre of that square.
func hand_over_centre() -> Vector2:
	return Vector2(covered.x, covered.y) if covered.z >= 0.0 else focus


## Chunks waiting for a job or to be made into nodes (tests, probes).
func waiting() -> int:
	return _pending.size() + _done.size() + (_job.msgs.size() if _job != null else 0)


## `bfar` {cx, cy, l: [x, y, direction, lane 1 item, lane 2 item, ...], c: [lane 1 count, ...]}.
## Kept for the next job; a newer message for the same chunk replaces it.
func handle(msg: Dictionary) -> void:
	var c := Vector2i(int(msg.get("cx", 0)), int(msg.get("cy", 0)))
	var l: Array = msg.get("l") if msg.get("l") is Array else []
	var counts: Array = msg.get("c") if msg.get("c") is Array else []
	var piles: Array = msg.get("h") if msg.get("h") is Array else []
	if l.is_empty():
		_latest.erase(c)
	else:
		_latest[c] = [l, counts, piles]
	if sync:
		_make(c, Job.build(l, counts, _belt_height(), piles))
		return
	_pending[c] = [l, counts, piles]


## Just over the belt model's top, once the model is made (on a worker thread: making it here at
## start-up cost 5-15 ms on the main thread); a little under it until then.
func _belt_height() -> float:
	if not _height_known and ModelLibrary.ready("transport-belt"):
		_height_known = true
		var belt := ModelLibrary.mesh_for("transport-belt")
		if belt != null:
			_height = belt.get_aabb().end.y + 0.03
	return _height


func _start() -> void:
	var job := Job.new()
	job.height = _belt_height()
	if _models:
		job.steps = _steps.duplicate()
	for c in _pending:
		var m: Array = _pending[c]
		_curves_of(c, job.curves)
		job.msgs.append([c, m[0], m[1], m[2] if m.size() > 2 else []])
	_pending.clear()
	_job = job
	_task = WorkerThreadPool.add_task(job.run, false, "belt lanes")


## A chunk's curved belts into `out` (Job.curves).
func _curves_of(c: Vector2i, out: Dictionary) -> void:
	if world == null or not world.chunks.has(c):
		return
	for r: WorldMirror.Rec in world.chunks[c].entities.values():
		var shape = r.extra.get("s") if r.extra != null else null
		if shape is String and (shape == "l" or shape == "r"):
			out[Vector2i(roundi(r.pos.x * 256.0), roundi(r.pos.y * 256.0))] = 1 if shape == "r" else -1


## Waits for the running job and queues what it made.
func _finish() -> void:
	if _task < 0:
		return
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	_done.append_array(_job.results)
	_job = null


func _start_icons() -> void:
	ItemIcons.prepare_for_threads()
	_icon_job = IconJob.new()
	_icon_job.names = _icons_wanted
	_icons_wanted = {}
	_icon_task = WorkerThreadPool.add_task(_icon_job.run, false, "belt lane icons")


func _finish_icons() -> void:
	if _icon_task < 0:
		return
	WorkerThreadPool.wait_for_task_completion(_icon_task)
	_icon_task = -1
	for item in _icon_job.textures:
		ItemIcons.store(_icon_job.names[item], _icon_job.textures[item])
		_material(int(item))
	_icon_job = null


## Makes finished chunks' nodes for up to `usec`, at least one chunk. A chunk with an item whose
## icon isn't loaded yet waits for IconJob (later chunks wait behind it, so a newer message for the
## same chunk can't be overtaken).
func _apply_some(usec: int) -> void:
	var start := Time.get_ticks_usec()
	while not _done.is_empty():
		var r: Array = _done[0]
		var by_item: Dictionary = r[1]
		var missing := false
		var relay := false
		for item in by_item:
			if _models and protos != null:
				var name := protos.item_name(int(item))
				if not ItemModels.ready(name):
					missing = true  # its model is read on a thread meanwhile
				elif not _steps.has(item):
					var mesh := ItemModels.mesh_for(name)
					if mesh != null:
						_steps[item] = clampf(mesh.get_aabb().size.y, 0.03, 0.2)
				if _steps.has(item) and (r.size() < 3 or r[2] == null or not (r[2] as Dictionary).has(item)):
					relay = true  # laid out before its model was known: again, as a model
			if not _materials.has(item):
				var name := protos.item_name(int(item)) if protos != null else ""
				if name == "" or ItemIcons.is_cached(name):
					_material(int(item))
				else:
					missing = true
					if _icon_job == null or not _icon_job.names.has(item):
						_icons_wanted[item] = name
		if missing:
			return
		_done.pop_front()
		if relay:
			if _latest.has(r[0]):
				_pending[r[0]] = _latest[r[0]]
			continue
		_make(r[0], by_item)
		var spent := Time.get_ticks_usec() - start
		worst_apply_usec = maxi(worst_apply_usec, spent)
		if spent >= usec:
			return


func _make(c: Vector2i, by_item: Dictionary) -> void:
	_drop(c)
	if by_item.is_empty() or (world != null and not world.chunks.has(c)):
		return
	var node := Node3D.new()
	node.name = "Lanes %d,%d" % [c.x, c.y]
	for item in by_item:
		var buf: PackedFloat32Array = by_item[item]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		var model: Mesh = null
		if _models and protos != null:
			model = ItemModels.mesh_for(protos.item_name(int(item)))
		mm.mesh = model if model != null else _quad
		mm.instance_count = buf.size() / STRIDE
		mm.buffer = buf
		var inst := MultiMeshInstance3D.new()
		inst.multimesh = mm
		inst.material_override = _model_material(int(item)) if model != null else _material(int(item))
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(inst)
	node.visible = not _held.has(c)
	add_child(node)
	_chunks[c] = node


## How many lane icons a chunk has (tests).
func icons_in(c: Vector2i) -> int:
	var node: Node3D = _chunks.get(c)
	var n := 0
	if node != null:
		for inst in node.get_children():
			n += (inst as MultiMeshInstance3D).multimesh.instance_count
	return n


func _drop(c: Vector2i) -> void:
	var node: Node3D = _chunks.get(c)
	if node != null:
		node.queue_free()
		_chunks.erase(c)


func _model_material(item: int) -> ShaderMaterial:
	if _model_materials.has(item):
		return _model_materials[item]
	var m := ShaderMaterial.new()
	m.shader = LaneModelShader
	m.set_shader_parameter("exposure", ItemModels.EXPOSURE)
	m.set_shader_parameter("focus", hand_over_centre())
	m.set_shader_parameter("near", near_edge())
	m.set_shader_parameter("far", float(distance))
	_model_materials[item] = m
	return m


func _material(item: int) -> ShaderMaterial:
	if _materials.has(item):
		return _materials[item]
	var m := ShaderMaterial.new()
	m.shader = LaneShader
	var name := protos.item_name(item) if protos != null else ""
	var tex := ItemIcons.texture_for(name) if name != "" else null
	if tex != null:
		m.set_shader_parameter("icon", tex)
	m.set_shader_parameter("focus", hand_over_centre())
	m.set_shader_parameter("near", near_edge())
	m.set_shader_parameter("far", float(distance))
	_materials[item] = m
	return m
