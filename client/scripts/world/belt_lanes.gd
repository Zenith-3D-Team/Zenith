extends Node3D
## Items on belts far away (#2, B2): past the area where belt_items.gd draws every item, each lane
## of each belt is drawn as flat icons of what it carries, the way Factorio's zoomed-out view
## reads. The mod sends what each lane carries per chunk when it changes (`bfar`), out to the
## "Belt items far away" distance, which this asks for (`bfar` command). One MultiMesh per chunk per
## item; the shader leaves out the belts belt_items.gd draws the real items of: each icon carries its
## belt's centre, and a belt whose centre lies in the square the items were read round has no
## icons, so the two hand over belt by belt with nothing drawn twice (a 2-tile overlap drew items
## twice there).
##
## A lane is drawn with as many icons as it holds items (`bfar` c, up to 4 a belt), so a full belt
## reads full (G17), piled when stack inserters put more items on it than that (`bfar` h). A chunk full of belts is thousands of icons: their buffers are worked out on a
## worker thread (Job), and the MultiMeshes made from them within a few milliseconds a frame. An
## item's icon not loaded yet is loaded on a worker too (IconJob), and its chunks wait for it: a
## tinted icon is composed pixel by pixel, which is what made one message take 30 ms (D6's probe).

const ProtoDB := preload("res://scripts/world/protos.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
const FrameBudget := preload("res://scripts/world/frame_budget.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const LaneInset := preload("res://scripts/world/belt_lane_inset.gd")
const WorldMirror := preload("res://scripts/world/world.gd")
const LaneShader := preload("res://shaders/belt_lane_icon.gdshader")
const LaneModelShader := preload("res://shaders/belt_lane_model.gdshader")
const ItemCards := preload("res://scripts/world/item_cards.gd")
const ItemModels := preload("res://scripts/world/item_models.gd")
const Looks := preload("res://scripts/world/looks.gd")
const PerfLog := preload("res://scripts/world/perf_log.gd")

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
## A far pile's copies turn this much more each, as near ones (ItemCards.turn_for).
const PILE_TURN := ItemCards.PILE_TURN
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
const AUTO_START := 6000.0
static var auto_cap := AUTO_START
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
func heard_work(per_tick: float, loading := false) -> void:
	bridge_work = per_tick if bridge_work < 0.0 else bridge_work + (per_tick - bridge_work) * 0.25
	bridge_loading = loading


## The bridge's own bound on its belt square (belt_sim.lua: cut while the belts' work is over their share of
## the budget) in the performance log, without the icon: `covered` under `near` while it isn't loading, as
## _auto reads it, for SQUARE_HOLD_MSEC (a square growing to a distance just raised isn't a cut).
const SQUARE_HOLD_MSEC := 3000
var _cut_since := -1


func log_square() -> void:
	var cut := not bridge_loading and covered.z >= 0.0 and near > 0 and covered.z < float(near) - 0.5
	if not cut:
		_cut_since = -1
		if PerfLog.is_open("square", "square"):
			PerfLog.restore("square", "square", "back at %d tiles" % near)
		return
	if _cut_since < 0:
		_cut_since = PerfLog.now()
	if PerfLog.now() - _cut_since < SQUARE_HOLD_MSEC:
		return
	var side := str(roundi(covered.z))
	if not PerfLog.is_open("square", "square"):
		PerfLog.note("square", "square", "the bridge's belt square %s tiles", str(near), side,
			"the bridge's belt work over its share of the budget", false)
	elif covered.z < float(PerfLog.find_open("square", "square")["to"]):
		PerfLog.lower("square", "square", side)


## The bridge is still loading the square (`bs` ld): Automatic waits (its frames and the game run
## slower meanwhile, and a cap changed now drops and loads thousands of lanes again).
var bridge_loading := false


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
## panning (G16). z < 0 (not known) falls back to `near` round `focus`.
var covered := Vector3(0.0, 0.0, -1.0)
## Make each message's icons at once on the main thread (tests).
var sync := false

var _chunks := {}  # Vector2i -> Node3D (a MultiMeshInstance3D per item)
## Counts the chunks made and dropped: belt_items.gd lists built_chunks() for its jobs only when it moved.
var chunks_ver := 0
## belt_items.gd's hand-over (hand_over()): chunks whose icons stay hidden while near items still
## wait in them, and item ids whose near look isn't made yet (their icons aren't left out).
var _held := {}
var _unknown := {}
var _materials := {}  # item id -> ShaderMaterial
var _model_materials := {}  # item id -> ShaderMaterial for its far model (models())
var _own_models := {}  # item id -> [its model, the model dressed for far belts] (item_models.gd dressed)
var _steps := {}  # item id -> its model's pile step (its height), once its model is read
var _variants := {}  # item id -> how many variants its model has (2 or more), learnt with its step
var _models := false  # models() when the chunks were last made: a change makes them all again
var _models_gen := 0  # ItemModels.current_generation() when they were: a change makes them again too
var _quad := QuadMesh.new()
var _height := 0.2
var _height_known := false
var _lane := LANE  # (_belt_height) the belt's pack's lane offset, belt_lane_inset.gd
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
	## Far models: item id -> how many variants its model has (ItemCards.variant_count), for items with 2 or more:
	## each icon is drawn as the variant its place picks, in a MultiMesh of that variant's (key item + v VARIANT_STEP).
	var variants := {}
	## Each lane's distance from its belt's centre line: the belt's pack's (belt_lane_inset.gd), else Factorio's.
	var lane := LANE
	var results: Array = []  # [chunk, {item id: PackedFloat32Array of TRANSFORM_3D + custom instances}, steps]

	func run() -> void:
		for m: Array in msgs:
			results.append([m[0], build(m[1], m[2], height, m[3], steps, curves, variants, lane), steps])

	## The seed of a far icon's turn (ItemCards.turn_for): its belt's centre (1/256 tile, as `l`), its
	## lane and its place on it, so it stays put while the lane's icons do.
	static func slot_seed(x: int, y: int, lane: int, j: int) -> int:
		return hash(Vector3i(x, y, lane * 4 + j))

	## `l` [x, y, direction, lane 1 item, lane 2 item, ...]; `counts` [lane 1, lane 2, ...] per
	## belt, or empty (an older mod: one icon a lane); `piles` the same for how high each lane's
	## stacks are, or empty (no stacks); `lane` each lane's distance from the belt's centre line (a pack's
	## belt_lane_offset: both lanes nearer the middle, a curve's about its middle radius). Arrays from JSON, or packed
	## from a binary frame (wire_decode.gd).
	static func build(l, counts, height: float, piles = [], steps = null, curves := {}, variants := {},
			lane_off := LANE) -> Dictionary:
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
				if steps != null and (steps as Dictionary).has(item):
					step = float(steps[item])
				var nv := int(variants.get(item, 0))
				var buf: PackedFloat32Array = by_item.get(item, PackedFloat32Array()) if nv < 2 else PackedFloat32Array()
				var o := buf.size()
				buf.resize(o + n * high * STRIDE)
				var side := at + right * (lane_off if lane == 1 else -lane_off)
				for j in n:
					# Spread evenly along the belt, as items ride; lying flat and upright, as Factorio's.
					var p := side + ahead * ((j + 0.5) / n - 0.5)
					if turn_way != 0:
						p = curve_point(at, (int(l[i + 2]) >> 2) & 3, turn_way, lane, (j + 0.5) / n, lane_off)
					# Turned as every item is (ItemCards.turn_for), icons and models alike, a pile's
					# copies more; seeded by its place (bfar sends no unique ids).
					var place := slot_seed(int(l[i]), int(l[i + 1]), lane, j)
					for h in high:
						var k := o + (j * high + h) * STRIDE
						var a2 := ItemCards.turn_for(place, h)
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
					if nv >= 2:
						# Its variant by its place too (its kind's buffer gets the slot's copies).
						var key := item + ItemCards.lattice_variant(place, 0, nv) * ItemCards.VARIANT_STEP
						var vb: PackedFloat32Array = by_item.get(key, PackedFloat32Array())
						vb.append_array(buf.slice(o + j * high * STRIDE, o + (j + 1) * high * STRIDE))
						by_item[key] = vb
				if nv < 2:
					by_item[item] = buf
			row += 1
		return by_item

	## A point `f` (0 to 1) along a curve's lane: a quarter circle about the curve's inner corner,
	## from the edge items come in at (as belt_paths.gd's arc pieces). d: the way the belt faces (0-3
	## from north), way: 1 turning right, -1 left; lane 0 the left lane, 1 the right, `lane_off` from the middle.
	static func curve_point(at: Vector2, d: int, way: int, lane: int, f: float, lane_off := LANE) -> Vector2:
		var t := (d + 3) % 4 if way > 0 else (d + 1) % 4  # the way items come in
		var corner: Vector2 = at - AHEADS[t] * 0.5 + AHEADS[d] * 0.5
		var v: Vector2 = at - AHEADS[t] * 0.5 + RIGHTS[t] * (lane_off if lane == 1 else -lane_off) - corner
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


## --belt-lanes-dump=<file> (a diagnostic, tools/belt_quirks.py): a JSON line each time a chunk's icons
## are made ("c", "i": item id -> [icon x, z, belt x, z, ...]) or dropped ("d"), the shader's square
## and distance change ("p": [centre x, y, near, far], "held", "unknown"), and every DUMP_CAM_USEC the
## camera's whole ground view ("g": its four corners, not cut at belt_items.gd's VIEW_FAR), each with
## the time ("u", Time.get_ticks_usec, as draw.bin.apply.jsonl's).
var _dump: FileAccess = null
var _dump_cam_usec := 0
const DUMP_CAM_USEC := 250000


func _dump_line(d: Dictionary) -> void:
	d["u"] = Time.get_ticks_usec()
	_dump.store_line(JSON.stringify(d))


func _dump_cam() -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return
	var vp := get_viewport().get_visible_rect().size
	var g: Array = []
	for c in [Vector2.ZERO, Vector2(vp.x, 0.0), vp, Vector2(0.0, vp.y)]:
		var ro := cam.project_ray_origin(c)
		var n := cam.project_ray_normal(c)
		var hit: Vector3
		if n.y < -1e-4 and (0.0 - ro.y) / n.y <= 4000.0:
			hit = ro + n * ((0.0 - ro.y) / n.y)
		else:
			var h := Vector2(n.x, n.z)
			h = h.normalized() if h.length() > 1e-6 else Vector2(1.0, 0.0)
			hit = Vector3(ro.x + h.x * 4000.0, 0.0, ro.z + h.y * 4000.0)
		g.append_array([snappedf(hit.x, 0.01), snappedf(hit.z, 0.01)])
	_dump_line({"g": g, "cam": [snappedf(cam.global_position.x, 0.01), snappedf(cam.global_position.y, 0.01), snappedf(cam.global_position.z, 0.01)],
		"fps": Engine.get_frames_per_second(), "process_ms": snappedf(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, 0.01)})


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--belt-lanes-dump="):
			_dump = FileAccess.open(a.substr(len("--belt-lanes-dump=")), FileAccess.WRITE)
	_quad.size = Vector2(ICON, ICON)
	_quad.orientation = PlaneMesh.FACE_Y
	# The first material made with the lane shader cost 21 ms on the main thread (Godot sets the
	# shader up then; seen on a real base): made here at start-up, as model_library.gd's warm_up().
	_material(0)
	_model_material(0)
	_models_gen = ItemModels.current_generation()
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
	_cut_since = -1
	bridge_work = -1.0
	bridge_loading = false
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
	_follow_models()
	# Only when what they say changed: three parameters on every item's material every frame (each
	# queues the material's uniforms to be sent again), while the square moves once an update.
	if [hand_over_centre(), near_edge(), distance, _materials.size(), _model_materials.size(), _own_models.size()] != _params_key:
		_set_params()
	if _dump != null and Time.get_ticks_usec() - _dump_cam_usec >= DUMP_CAM_USEC:
		_dump_cam_usec = Time.get_ticks_usec()
		_dump_cam()
		_dump.flush()


## Automatic: once a second, from the frames' time over the last second or two (their slowest
## tenth) against the frame's budget (16.7 ms, or the FPS cap's when it is lower) and the game's
## UPS: room to spare raises the cap a fifth, frames running long or the game slowing lowers it a
## fifth. Not while a game loads (its frames are long for other reasons).
func _auto(delta: float) -> void:
	if not Bridge.world_ready or bridge_loading:
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
	var why := ""
	if slow > budget * 1.05 or (ups > 0.0 and ups < 57.0) or bridge_work > AUTO_WORK * 1.25:
		auto_cap = maxf(auto_cap * 0.8, AUTO_MIN)
		why = ("frames at %.1f ms" % slow) if slow > budget * 1.05 else (("game at %.1f UPS" % ups) if ups > 0.0 and ups < 57.0
			else "the bridge's belt work at %d units a tick" % roundi(bridge_work))
	elif slow < budget * 0.8 and (ups <= 0.0 or ups >= 59.0) and bridge_work * 1.2 <= AUTO_WORK and binding:
		auto_cap = minf(auto_cap * 1.2, AUTO_MAX)
	if auto_cap != was:
		cap = cap_of(minf(auto_cap, updates_hold))
	log_auto(why, binding)


## Automatic's cap in the performance log (perf_log.gd), without the icon (it moves all the time by design):
## one entry on a cut under half its start, the lowest kept, restored once back over half. The cap grows
## back only while it binds, so on a base with few belts in reach it can stay low at 60 UPS for good with
## every item still moving: the entry ends once it hasn't bound for AUTO_FREE_MSEC ("held" would be untrue
## there; a ceiling worded as held back forever reads as a lasting cut), and a new one opens if it binds
## again while under half. Called on each decision (`why` the cut's reason, "" when none).
const AUTO_FREE_MSEC := 5000
static var _auto_free_since := -1


static func log_auto(why: String, binding := true) -> void:
	var half := AUTO_START * 0.5
	var open := PerfLog.find_open("belts", "auto")
	if auto_cap >= half:
		_auto_free_since = -1
		if not open.is_empty():
			PerfLog.restore("belts", "auto", "back over %d" % int(half))
		return
	if why == "" and not binding:
		if open.is_empty():
			return
		if _auto_free_since < 0:
			_auto_free_since = PerfLog.now()
		if PerfLog.now() - _auto_free_since >= AUTO_FREE_MSEC:
			_auto_free_since = -1
			PerfLog.finish("belts", "auto", "nothing held back now, every belt item in reach moves under %d" % int(auto_cap))
		return
	_auto_free_since = -1
	if open.is_empty():
		PerfLog.note("belts", "auto", "moving belt items (Automatic) %s", str(int(AUTO_START)), str(int(auto_cap)),
			why if why != "" else "the belt items in reach are more than it", false)
	elif auto_cap < float(open["to"]):
		PerfLog.lower("belts", "auto", str(int(auto_cap)))


## Items in 3D turned models on or off, or an item's model file changed with the packs
## (ItemModels.generation): every chunk is made again (an int compare otherwise).
func _follow_models() -> void:
	var gen := ItemModels.current_generation() if ItemModels.kinds_follow else _models_gen
	if _models == models() and _models_gen == gen:
		return
	_models = models()
	_models_gen = gen
	_steps.clear()  # (a pile's step is its model's height: read again from the new one)
	_variants.clear()
	for c in _latest:
		if sync:
			var m: Array = _latest[c]
			_make(c, Job.build(m[0], m[1], _belt_height(), m[2] if m.size() > 2 else [], null, {}, {}, _lane))
		else:
			_pending[c] = _latest[c]


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
	_params_key = [centre, edge, distance, _materials.size(), _model_materials.size(), _own_models.size()]
	if _dump != null:
		var held: Array = []
		for c in _held:
			held.append_array([c.x, c.y])
		_dump_line({"p": [centre.x, centre.y, edge, float(distance)], "held": held, "unknown": _unknown.keys()})
	for mats: Dictionary in [_materials, _model_materials]:
		for item in mats:
			var m: ShaderMaterial = mats[item]
			m.set_shader_parameter("focus", centre)
			m.set_shader_parameter("near", -1.0 if _unknown.has(ItemCards.item_of(int(item))) else edge)
			m.set_shader_parameter("far", float(distance))
	for item in _own_models:
		var pair: Array = _own_models[item]
		for m: ShaderMaterial in ItemModels.surface_materials(pair[1]):
			m.set_shader_parameter("focus", centre)
			m.set_shader_parameter("near", -1.0 if _unknown.has(ItemCards.item_of(int(item))) else edge)
			m.set_shader_parameter("far", float(distance))


## Called by belt_items.gd in the frame its job's result is drawn: the square its items cover,
## the chunks where items still wait for their icons, and the kinds it doesn't draw yet.
func hand_over(square: Vector3, held: Dictionary, unknown: Array) -> void:
	covered = square
	log_square()
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
## A message's list as JSON's Array or a binary frame's packed one (wire_decode.gd); [] when it is neither.
static func _list(v: Variant) -> Variant:
	return v if v is Array or v is PackedInt32Array or v is PackedInt64Array else []


func handle(msg: Dictionary) -> void:
	var c := Vector2i(int(msg.get("cx", 0)), int(msg.get("cy", 0)))
	var l = _list(msg.get("l"))
	var counts = _list(msg.get("c"))
	var piles = _list(msg.get("h"))
	if l.is_empty():
		_latest.erase(c)
	else:
		_latest[c] = [l, counts, piles]
	if sync:
		_make(c, Job.build(l, counts, _belt_height(), piles, null, {}, {}, _lane))
		return
	_pending[c] = [l, counts, piles]


## Just over the belt model's top, once the model is made (on a worker thread: making it here at
## start-up cost 5-15 ms on the main thread); a little under it until then.
func _belt_height() -> float:
	if not _height_known and ModelLibrary.ready("transport-belt"):
		_height_known = true
		var belt := ModelLibrary.mesh_for("transport-belt")
		if belt != null:
			var pack := ModelPacks.pack_of(ModelLibrary.source_of("transport-belt"))
			_height = LaneInset.item_height(pack, belt.get_aabb().end.y, 0.03)
			_lane = LaneInset.wanted(pack)
	return _height


func _start() -> void:
	var job := Job.new()
	job.height = _belt_height()
	job.lane = _lane
	if _models:
		job.steps = _steps.duplicate()
		job.variants = _variants.duplicate()
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
		for key in by_item:
			var item := ItemCards.item_of(int(key))
			if _models and protos != null:
				var name := protos.item_name(item)
				if not ItemModels.ready(name):
					missing = true  # its model is read on a thread meanwhile
				elif not _steps.has(item):
					var mesh := ItemModels.mesh_for(name)
					if mesh != null:
						_steps[item] = clampf(mesh.get_aabb().size.y, 0.03, 0.2)
						var nv := ItemModels.variant_count(name)
						if nv >= 2:
							_variants[item] = nv
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
	var had := _chunks.has(c)
	_drop(c, false)
	if by_item.is_empty() or (world != null and not world.chunks.has(c)):
		if had:
			chunks_ver += 1
		return
	var node := Node3D.new()
	node.name = "Lanes %d,%d" % [c.x, c.y]
	for key in by_item:
		var buf: PackedFloat32Array = by_item[key]
		var item := ItemCards.item_of(int(key))
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		var model: Mesh = null
		if _models and protos != null:
			model = ItemModels.mesh_for(protos.item_name(item), ItemCards.variant_of(int(key)))
		var own := ItemModels.has_own(model)
		var use_simple := own and ItemModels.item_lod and ItemModels.needs_lod(model)
		var drawn: Mesh = ItemModels.simple_mesh(model) if use_simple else ((_own_model(int(key), model) if own else model) if model != null else _quad)
		mm.mesh = drawn
		mm.instance_count = buf.size() / STRIDE
		mm.buffer = buf
		var inst := MultiMeshInstance3D.new()
		inst.multimesh = mm
		if not own or use_simple:
			inst.material_override = _model_material(int(key), drawn) if model != null else _material(item)
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(inst)
	node.visible = not _held.has(c)
	add_child(node)
	if _dump != null:
		var icons := {}
		for item in by_item:
			var buf: PackedFloat32Array = by_item[item]
			var flat: Array = icons.get(str(ItemCards.item_of(int(item))), [])  # (an item's variants: one entry)
			for k in range(0, buf.size(), STRIDE):
				flat.append_array([snappedf(buf[k + 3], 0.01), snappedf(buf[k + 11], 0.01), snappedf(buf[k + 12], 0.01), snappedf(buf[k + 13], 0.01)])
			icons[str(ItemCards.item_of(int(item)))] = flat
		_dump_line({"c": [c.x, c.y], "i": icons})
	if not had:
		chunks_ver += 1
	_chunks[c] = node


## How many lane icons a chunk has (tests).
func icons_in(c: Vector2i) -> int:
	var node: Node3D = _chunks.get(c)
	var n := 0
	if node != null:
		for inst in node.get_children():
			n += (inst as MultiMeshInstance3D).multimesh.instance_count
	return n


func _drop(c: Vector2i, count := true) -> void:
	var node: Node3D = _chunks.get(c)
	if node != null:
		node.queue_free()
		_chunks.erase(c)
		if count:
			chunks_ver += 1
		if _dump != null:
			_dump_line({"d": [c.x, c.y]})


## A kind's model material (one per kind, shared by its MultiMeshes): a modeller's item model with a
## picture drawn with it, as the modeller made it (item_models.gd material_for).
func _model_material(item: int, model: Mesh = null) -> ShaderMaterial:
	var tex := ItemModels.picture(model)
	var exp_val := 1.0 if (tex != null or ItemModels.is_simple(model)) else ItemModels.EXPOSURE
	if _model_materials.has(item):
		var had: ShaderMaterial = _model_materials[item]
		if had.get_shader_parameter("picture") == tex and is_equal_approx(float(had.get_shader_parameter("exposure")), exp_val):
			return had
	var m := ShaderMaterial.new()
	m.shader = Looks.shader_for(LaneModelShader)
	m.set_shader_parameter("exposure", exp_val)
	if tex != null:
		m.set_shader_parameter("picture", tex)
		m.set_shader_parameter("use_picture", true)
		ItemModels.set_pbr(m, model)
	m.set_shader_parameter("focus", hand_over_centre())
	m.set_shader_parameter("near", near_edge())
	m.set_shader_parameter("far", float(distance))
	_model_materials[item] = m
	return m


## An own-look item model (item_models.gd has_own) dressed for far belts: its surfaces each with its file's
## material, as the lane model shader draws it (one per kind; _set_params keeps their square and distance).
func _own_model(item: int, model: Mesh) -> Mesh:
	if _own_models.has(item):
		var had: Array = _own_models[item]
		if had[0] == model:
			return had[1]
	var dressed := ItemModels.dressed(model, LaneModelShader)
	for m: ShaderMaterial in ItemModels.surface_materials(dressed):
		m.set_shader_parameter("focus", hand_over_centre())
		m.set_shader_parameter("near", near_edge())
		m.set_shader_parameter("far", float(distance))
	_own_models[item] = [model, dressed]
	return dressed


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
