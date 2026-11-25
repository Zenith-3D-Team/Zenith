extends Node3D
## The debug menu's bridge update overlays (debug_menu.gd, its Updates tab; dev builds only): where and when
## the bridge updates the world. Each kind of update outlines, on the ground, the chunk, tiles, entity or belt
## lane it touched as it arrives, fading out over FADE seconds; each kind has its own switch and colour, and a
## legend at the left lists the kinds on with their updates a second. Three kinds show a state instead of
## flashing: the subscription (the square, the chunks still to come in the order asked for, those on their
## way), how each belt lane is drawn now (the simulation's items, the lattice, far icons, nothing) and the
## lattice against the simulation (a packed lane drawn standing while the simulation moves its items: the
## frozen lanes; and the other way round).
##
## Free when off: the menu makes this node for the first kind switched on and frees it with the last, so
## with none on there is no node, no handler and no per-frame work. On: one handler on Bridge.message_received
## (kinds that are off return at once), one MultiMesh per kind on, an instance written only when its flash is
## drawn (the fading is update_flash.gdshader's, on the overlay's clock), at most WRITES_PER_FRAME a kind a
## frame. The belt kinds read belt_items.gd's state through its debug tap, called after each job when no job
## runs; the state kinds are worked out again a few times a second, round the focus only (TINT_RADIUS).
## Everything is drawn over buildings (no depth test) and lifted onto the hills (ground_height.gdshaderinc).

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const WireDecode := preload("res://scripts/net/wire_decode.gd")
const FlashShader := preload("res://shaders/update_flash.gdshader")
const Wire := preload("res://scripts/util/wire.gd")

const FADE := 1.0
const LIFT := 0.06
## Flashes a kind keeps; the oldest (faded most) are written over.
const CAP := 4096
## Flashes written a frame per kind; the rest wait their turn (at most QUEUE_MAX).
const WRITES_PER_FRAME := 512
const QUEUE_MAX := 8192
## A mover, hand, item on the ground or fluid box is flashed again at most this often (mv every 2 ticks would
## otherwise draw one solid mark).
const REFLASH := 0.25
const LINE := 0.07  # an entity's or tile's outline (tiles)
const CHUNK_LINE := 0.35
const LANE_W := 0.14  # a lane's strip
const SPOT := 0.4  # a hand's, a mover's smallest, an item's square
## The state kinds, worked out again this often (seconds), round the focus.
const LANES_EVERY := 1.0
const FROZEN_EVERY := 0.25
const SUB_EVERY := 0.5
const TINT_RADIUS := 64.0
## The subscription shows at most this many chunks still to come (the front of the stream).
const SUB_SHOWN := 512
## A lane flash whose lane isn't known yet waits this long for belt_items.gd's next job, then outlines its belt.
const LANE_WAIT_MSEC := 600
## A lane the lattice draws standing while the simulation moves it, this long or longer, pulses.
const HELD_SEC := 0.5
const HUGE := AABB(Vector3(-1.0e6, -1000.0, -1.0e6), Vector3(2.0e6, 2000.0, 2.0e6))
const BELT_TYPES := ["transport-belt", "underground-belt", "linked-belt", "splitter", "lane-splitter", "loader", "loader-1x1"]
## belt_sim.gd's kind of an underground entrance's hidden line: under the ground, its items not drawn.
const HIDDEN_LINE := 4

## [id, name, colour, what it outlines]; a row of two is a group's heading.
const KINDS := [
	["", "Chunks"],
	["chunk", "Chunk snapshots", Color(1.0, 0.84, 0.2), "`chunk` and its `ents` parts: the chunk's square as each arrives (the bridge's periodic resend too)"],
	["kept", "Kept chunks", Color(0.3, 0.85, 1.0), "`same` (drawn from the client's copy) and `kept` (the counts of chunks that left the square, confirmed)"],
	["sub", "Subscription (state)", Color(0.78, 0.55, 1.0), "The square asked for (`sub`), the chunks still to come in the order asked for (brightest first), those on their way outlined, and the view's direction"],
	["tiles", "Tiles", Color(0.9, 0.58, 0.3), "`tiles`: each tile laid or mined"],
	["dec", "Decoratives", Color(0.55, 0.8, 0.35), "`dec`: a chunk's grass, flowers and rocks sent again"],
	["bfar", "Far belt icons", Color(0.62, 0.55, 0.85), "`bfar`: a chunk's far lane icons read and sent"],
	["", "Entities"],
	["add", "Built", Color(0.3, 0.95, 0.4), "`add`: the entity's footprint"],
	["del", "Removed", Color(1.0, 0.3, 0.25), "`del`"],
	["upd", "Changed", Color(1.0, 0.7, 0.2), "`upd`: rotated, a new recipe, settings"],
	["mnd", "Mined by hand", Color(1.0, 0.35, 0.9), "`mnd`: the tick the character's mining took it"],
	["st", "Machine states", Color(0.4, 0.7, 1.0), "`st`: machines that started or stopped, signals, lamps, silos, belts switched off"],
	["", "Belts"],
	["lm", "Lanes loaded", Color(0.2, 0.5, 1.0), "`bs` lm: a lane's meta, as it is first loaded or changes"],
	["sl", "Lanes read", Color(0.25, 1.0, 0.8), "`bs` sl (read in full), ew (moved on), sh (a splitter's input held)"],
	["dl", "Lanes dropped", Color(1.0, 0.45, 0.15), "`bs` dl: out of the square, or the belt gone"],
	["pc", "Drift checks", Color(0.95, 0.95, 0.5), "`bs` pc: a lane's count, front and back checked"],
	["bre", "Lanes asked for", Color(1.0, 0.5, 0.72), "`bre`: lanes the client asks to be read again (its simulation disagreed)"],
	["hand", "Takes and hand-offs", Color(1.0, 0.62, 0.05), "`ie` picks and drops at belts and the items hands put on them (`ho`), F's `pku`: the hand, the belt, the item's place"],
	["lanes", "How lanes are drawn (state)", Color(0.35, 0.9, 0.45), "Each lane round the focus: the simulation's items, the lattice (packed), far icons, or nothing drawn"],
	["frozen", "Lattice against simulation (state)", Color(1.0, 0.1, 0.5), "A packed lane the lattice draws standing while the simulation moves its items (pulsing once held for half a second), or sliding while they stand"],
	["", "Moving things"],
	["mv", "Movers", Color(0.72, 0.95, 0.3), "`mv`: each mover as it is sent (every 2 ticks within the focus radius; flashed at most 4 times a second)"],
	["ih", "Inserter hands", Color(0.85, 0.55, 1.0), "`ih` samples and `ie` events: the hand"],
	["gi", "Items on the ground", Color(0.92, 0.92, 0.92), "`gi`"],
	["", "Other"],
	["power", "Fluids, heat and power", Color(0.2, 0.85, 0.85), "`fl`, `ht`, `pw`: the entities read once a second"],
	["al", "Alerts", Color(1.0, 0.15, 0.15), "`al`: an alert new since the last list, where it is"],
	["alt", "Alt-mode rounds", Color(0.95, 0.85, 0.7), "`ac`, `am`, `aiu`: chests' and machines' Alt-mode icons that changed"],
]
## Kinds drawn as a state, made again whole, not flashed.
const STILL := {"sub": true, "lanes": true, "frozen": true}
## Kinds that read belt_items.gd's state after its jobs (and lane flashes waiting for their lane).
const BELT_KINDS := {"lm": true, "sl": true, "dl": true, "pc": true, "bre": true, "hand": true, "lanes": true, "frozen": true}
const LANE_COLORS := {"sim": Color(0.35, 0.9, 0.45), "lattice": Color(0.3, 0.55, 1.0), "far": Color(0.68, 0.55, 0.85), "none": Color(0.9, 0.2, 0.2)}
const LANE_NAMES := {"sim": "simulated items", "lattice": "lattice (packed)", "far": "far icons", "none": "nothing drawn"}
const FROZEN_COLORS := {"stands": Color(1.0, 0.1, 0.5), "slides": Color(1.0, 0.82, 0.1)}


class Layer:
	var id := ""
	var node: MultiMeshInstance3D
	var mm: MultiMesh
	var color := Color.WHITE
	var still := false
	var queue := PackedFloat32Array()  # flashes to write, six floats each: x, z, width, depth, angle, outline
	var next := 0
	var used := 0
	var last := -100.0  # when the newest flash was written
	var seen := {}  # spot -> when it was last flashed (REFLASH)
	## What each instance is, as written (the headless renderer keeps no instance data): a flash's seven floats
	## (x, z, width, depth, angle, outline, born), a state's eleven (_set_still).
	var mirror := PackedFloat32Array()


var world  # world.gd
var belt_items  # belt_items.gd, or null
var belt_lanes  # belt_lanes.gd, or null
## (tests) Seconds added to the overlay's clock.
var time_shift := 0.0
## The state kinds' counts, for the legend (and tests): lanes {mode: n}, frozen [standing, held, sliding],
## sub [asked, on their way, still to come].
var stats := {}

var _on := {}
var _layers := {}  # kind id -> Layer
var _t0 := Time.get_ticks_usec()
var _mat: ShaderMaterial
var _quad := PlaneMesh.new()
var _counts := {}  # kind id -> updates since the last roll
var _rates := {}  # kind id -> updates in the last second
var _roll_at := 1.0
var _lane_geo := {}  # lane key -> [x0, y0, xm, ym, x1, y1 (tiles), length (1/256)]
var _lane_wait: Array = []  # [kind id, lane key, msec, line position or -1]
var _ie_seen := {}
var _alerts_before := {}
var _lanes_at := -100.0
var _frozen_at := -100.0
var _sub_at := -100.0
var _sub_key: Array = []
var _held := {}  # lane key -> when the lattice was first seen standing against the simulation
var _belt_lists := {}  # chunk -> [its content_rev then, its belts' records]
var _lane_kinds := false  # a kind that flashes lanes is on: `bs` lm is kept for their places
var _surface := -2
var _wired_bridge := false
var _wired_belts := false
var _legend: CanvasLayer
var _legend_box: VBoxContainer
var _legend_rows: Array = []  # [Label, kind id, part]
var _legend_at := -100.0


func _init() -> void:
	_quad.size = Vector2.ONE
	_mat = ShaderMaterial.new()
	_mat.shader = FlashShader
	_mat.render_priority = 12
	_mat.set_shader_parameter(&"fade", FADE)


func _ready() -> void:
	if world != null and is_instance_valid(world):
		_surface = int(world.surface_index)
	set_process(not _on.is_empty())


func _exit_tree() -> void:
	_on.clear()
	_wire()


static func color_of(id: String) -> Color:
	for k in KINDS:
		if k.size() > 2 and str(k[0]) == id:
			return k[2]
	return Color.WHITE


static func name_of(id: String) -> String:
	for k in KINDS:
		if k.size() > 2 and str(k[0]) == id:
			return str(k[1])
	return id


## The kinds there are, in the menu's order (no headings).
static func kind_ids() -> Array:
	var out: Array = []
	for k in KINDS:
		if k.size() > 2:
			out.append(str(k[0]))
	return out


func set_kind(id: String, on: bool) -> void:
	if on == _on.has(id) or not kind_ids().has(id):
		return
	if on:
		_on[id] = true
		_layer(id)
		_counts[id] = 0
	else:
		_on.erase(id)
		var l: Layer = _layers.get(id)
		if l != null:
			l.node.queue_free()
			_layers.erase(id)
		_rates.erase(id)
		_counts.erase(id)
		stats.erase(id)
		if id == "frozen":
			_held.clear()
		if id == "sub":
			_sub_key = []
	_wire()
	set_process(not _on.is_empty())
	_make_legend()


func is_on(id: String) -> bool:
	return _on.has(id)


func any_on() -> bool:
	return not _on.is_empty()


func kinds_on() -> Array:
	return _on.keys()


## The handlers on only while a kind needs them.
func _wire() -> void:
	var bridge_wanted := false
	var belts_wanted := false
	_lane_kinds = false
	for id: String in _on:
		if not STILL.has(id):
			bridge_wanted = true
		if BELT_KINDS.has(id):
			belts_wanted = true
			_lane_kinds = _lane_kinds or not STILL.has(id)
	if bridge_wanted != _wired_bridge:
		_wired_bridge = bridge_wanted
		if bridge_wanted:
			Bridge.message_received.connect(on_message)
		elif Bridge.message_received.is_connected(on_message):
			Bridge.message_received.disconnect(on_message)
	belts_wanted = belts_wanted and belt_items != null and is_instance_valid(belt_items)
	if belts_wanted != _wired_belts:
		_wired_belts = belts_wanted
		if belt_items != null and is_instance_valid(belt_items):
			belt_items.debug_tap = Callable(self, "on_belt_job") if belts_wanted else Callable()
	if not belts_wanted:
		_lane_wait.clear()


func _layer(id: String) -> Layer:
	var l: Layer = _layers.get(id)
	if l != null:
		return l
	l = Layer.new()
	l.id = id
	l.still = STILL.has(id)
	l.color = color_of(id)
	l.mm = MultiMesh.new()
	l.mm.transform_format = MultiMesh.TRANSFORM_3D
	l.mm.use_colors = true
	l.mm.use_custom_data = true
	l.mm.mesh = _quad
	if not l.still:
		l.mm.instance_count = CAP
		l.mm.visible_instance_count = 0
		l.mirror.resize(CAP * 7)
		for i in CAP:
			l.mm.set_instance_color(i, l.color)
	l.node = MultiMeshInstance3D.new()
	l.node.name = "Updates_" + id
	l.node.multimesh = l.mm
	l.node.material_override = _mat
	l.node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	l.node.custom_aabb = HUGE
	add_child(l.node)
	_layers[id] = l
	return l


func _now() -> float:
	return (Time.get_ticks_usec() - _t0) / 1000000.0 + time_shift


func _count(id: String, n := 1) -> void:
	_counts[id] = int(_counts.get(id, 0)) + n


# --- drawing ---------------------------------------------------------------------------------------

## A flash of kind `id`: a rectangle at c (Factorio's x, y in tiles), size (tiles), turned by angle (as
## Factorio's directions turn: clockwise on the map), outlined `line` wide (0: filled).
func _rect(id: String, c: Vector2, size: Vector2, angle: float, line: float) -> void:
	var l: Layer = _layers.get(id)
	if l == null or l.queue.size() >= QUEUE_MAX * 6:
		return
	l.queue.append_array(PackedFloat32Array([c.x, c.y, size.x, size.y, angle, line]))


## Whether a spot of a frequent kind may flash again now (REFLASH).
func _fresh(id: String, spot) -> bool:
	var l: Layer = _layers.get(id)
	if l == null:
		return false
	var t := _now()
	if t - float(l.seen.get(spot, -100.0)) < REFLASH:
		return false
	if l.seen.size() > 20000:
		l.seen.clear()
	l.seen[spot] = t
	return true


static func _xf(cx: float, cz: float, w: float, d: float, a: float) -> Transform3D:
	var ca := cos(a)
	var sa := sin(a)
	return Transform3D(Basis(Vector3(ca * w, 0.0, sa * w), Vector3.UP, Vector3(-sa * d, 0.0, ca * d)), Vector3(cx, LIFT, cz))


func _drain(l: Layer, t: float) -> void:
	var n := mini(l.queue.size() / 6, WRITES_PER_FRAME)
	if n == 0:
		if l.used > 0 and t - l.last > FADE + 0.05:
			# All faded: nothing left to draw until the next flash.
			l.used = 0
			l.next = 0
			l.mm.visible_instance_count = 0
		return
	var q := l.queue
	for j in n:
		var o := j * 6
		var i := l.next
		l.mm.set_instance_transform(i, _xf(q[o], q[o + 1], q[o + 2], q[o + 3], q[o + 4]))
		l.mm.set_instance_custom_data(i, Color(t, q[o + 2], q[o + 3], q[o + 5]))
		for k in 6:
			l.mirror[i * 7 + k] = q[o + k]
		l.mirror[i * 7 + 6] = t
		l.next = (i + 1) % CAP
		l.used = mini(l.used + 1, CAP)
	l.queue = q.slice(n * 6)
	l.mm.visible_instance_count = l.used
	l.last = t


## A state kind's instances, made again whole: `out` holds 11 floats each (x, z, width, depth, angle,
## outline, r, g, b, a, born: -1 stays, -2 pulses).
func _set_still(id: String, out: PackedFloat32Array) -> void:
	var l: Layer = _layers.get(id)
	if l == null:
		return
	var n := out.size() / 11
	var buf := PackedFloat32Array()
	buf.resize(n * 20)
	for i in n:
		var o := i * 11
		var b := i * 20
		var w := out[o + 2]
		var d := out[o + 3]
		var ca := cos(out[o + 4])
		var sa := sin(out[o + 4])
		buf[b] = ca * w
		buf[b + 2] = -sa * d
		buf[b + 3] = out[o]
		buf[b + 5] = 1.0
		buf[b + 7] = LIFT
		buf[b + 8] = sa * w
		buf[b + 10] = ca * d
		buf[b + 11] = out[o + 1]
		for k in 4:
			buf[b + 12 + k] = out[o + 6 + k]
		buf[b + 16] = out[o + 10]
		buf[b + 17] = w
		buf[b + 18] = d
		buf[b + 19] = out[o + 5]
	l.mm.instance_count = n
	if n > 0:
		l.mm.buffer = buf
	l.mirror = out
	l.last = _now()


static func _still(out: PackedFloat32Array, c: Vector2, size: Vector2, angle: float, line: float, col: Color, born: float) -> void:
	out.append_array(PackedFloat32Array([c.x, c.y, size.x, size.y, angle, line, col.r, col.g, col.b, col.a, born]))


## An entity's selection box from its prototype, turned by its direction (16-way): [centre, size, angle].
## Without a direction (`del`, `mnd` carry none), guessed from where it stands (guess_dir).
func _footprint(proto_id: int, pos: Vector2, dir: int, dir_known := true) -> Array:
	var p = world.protos.entity(proto_id) if world != null else null
	if p == null:
		return [pos, Vector2(0.9, 0.9), 0.0]
	if not dir_known:
		dir = guess_dir(p.tile_size, pos)
	var a := -Wire.direction_yaw(dir)
	var lo: Vector2 = p.box_min
	var hi: Vector2 = p.box_max
	return [pos + ((lo + hi) * 0.5).rotated(a), (hi - lo).max(Vector2(0.3, 0.3)), a]


## A building's direction from where it stands, for those whose sides differ in evenness (a splitter, a
## boiler, a pump): a north-facing one stands on a tile's middle across where its width is odd, on a
## tile's edge where it is even; turned a quarter it is the other way round. 0 when that can't tell.
static func guess_dir(tile_size: Vector2i, pos: Vector2) -> int:
	if (tile_size.x & 1) == (tile_size.y & 1):
		return 0
	var centred := absf(fposmod(pos.x, 1.0) - 0.5) < 0.25
	return 0 if centred == ((tile_size.x & 1) == 1) else 4


func _entity(id: String, proto_id: int, pos: Vector2, dir: int, dir_known := true) -> void:
	var f := _footprint(proto_id, pos, dir, dir_known)
	_rect(id, f[0], f[1], f[2], LINE)


## By unit number, from the entity's record (none: its chunk isn't loaded, nothing drawn). True if drawn.
func _unit(id: String, unit: int) -> bool:
	var r = world.entities.get(unit) if world != null and unit > 0 else null
	if r == null:
		return false
	_entity(id, r.proto_id, r.pos, r.dir)
	return true


func _chunk(id: String, c: Vector2i) -> void:
	_rect(id, Vector2(c) * 32.0 + Vector2(16.0, 16.0), Vector2(31.4, 31.4), 0.0, CHUNK_LINE)


func _point(id: String, x: int, y: int, size := SPOT) -> void:
	_rect(id, Vector2(x, y) / 256.0, Vector2(size, size), 0.0, LINE)


## A lane (belt_sim.gd's key: the belt's unit x 8 + line) as a strip along it, or at line position `pos`
## (1/256 from its exit end) a spot. A lane not known yet waits for belt_items.gd's next job.
func _lane(id: String, key: int, pos := -1) -> void:
	var g: Array = _lane_geo.get(key, [])
	if g.is_empty():
		if _lane_wait.size() < 4096:
			_lane_wait.append([id, key, Time.get_ticks_msec(), pos])
		return
	_draw_lane(id, g, pos)


func _draw_lane(id: String, g: Array, pos: int) -> void:
	var p0 := Vector2(float(g[0]), float(g[1]))
	var pm := Vector2(float(g[2]), float(g[3]))
	var p1 := Vector2(float(g[4]), float(g[5]))
	if pos >= 0:
		_rect(id, lane_point(g, pos), Vector2(0.3, 0.3), 0.0, LINE)
		return
	# A curve by its middle; a straight lane in one strip.
	if pm.distance_to((p0 + p1) * 0.5) > 0.05:
		_strip(id, p0, pm)
		_strip(id, pm, p1)
	else:
		_strip(id, p0, p1)


func _strip(id: String, a: Vector2, b: Vector2) -> void:
	var d := b - a
	_rect(id, (a + b) * 0.5, Vector2(maxf(d.length(), 0.1), LANE_W), atan2(d.y, d.x), 0.0)


static func _still_lane(out: PackedFloat32Array, g: Array, col: Color, born: float, width := LANE_W) -> void:
	var p0 := Vector2(float(g[0]), float(g[1]))
	var pm := Vector2(float(g[2]), float(g[3]))
	var p1 := Vector2(float(g[4]), float(g[5]))
	var parts := [[p0, pm], [pm, p1]] if pm.distance_to((p0 + p1) * 0.5) > 0.05 else [[p0, p1]]
	for s in parts:
		var a: Vector2 = s[0]
		var b: Vector2 = s[1]
		var d := b - a
		_still(out, (a + b) * 0.5, Vector2(maxf(d.length(), 0.1), width), atan2(d.y, d.x), 0.0, col, born)


## Where line position `pos` (1/256, 0 the exit end) is on a lane: along its two halves.
static func lane_point(g: Array, pos: int) -> Vector2:
	var p0 := Vector2(float(g[0]), float(g[1]))
	var pm := Vector2(float(g[2]), float(g[3]))
	var p1 := Vector2(float(g[4]), float(g[5]))
	var f := clampf(float(pos) / maxf(float(g[6]), 1.0), 0.0, 1.0)
	return p0.lerp(pm, f * 2.0) if f < 0.5 else pm.lerp(p1, f * 2.0 - 1.0)


## A lane's place from its meta (belt_items.gd State.lanes: kind, length, step, x0, y0, xm, ym, x1, y1).
static func geo_of_meta(m: PackedInt32Array) -> Array:
	return [m[3] / 256.0, m[4] / 256.0, m[5] / 256.0, m[6] / 256.0, m[7] / 256.0, m[8] / 256.0, float(m[1])]


## Lane flashes waiting for their lane: from `lanes` (belt_items.gd's, read in its debug tap) when it has
## them, else their belt's footprint once they have waited LANE_WAIT_MSEC (or at once from the tap: the lane
## isn't loaded, or was dropped in the job just done).
func _resolve(lanes) -> void:
	if _lane_wait.is_empty():
		return
	var now := Time.get_ticks_msec()
	var keep: Array = []
	for w: Array in _lane_wait:
		var key: int = w[1]
		var g: Array = _lane_geo.get(key, [])
		if g.is_empty() and lanes != null and lanes.has(key):
			g = geo_of_meta(lanes[key])
			_lane_geo[key] = g
		if not g.is_empty():
			_draw_lane(str(w[0]), g, int(w[3]))
		elif lanes != null or now - int(w[2]) > LANE_WAIT_MSEC:
			_unit(str(w[0]), (key - 1) >> 3)
		else:
			keep.append(w)
	_lane_wait = keep


func _process(_delta: float) -> void:
	var t := _now()
	_mat.set_shader_parameter(&"now", t)
	if world != null and is_instance_valid(world) and int(world.surface_index) != _surface:
		# Another surface: what was known of this one's lanes and belts is no longer drawn.
		_surface = int(world.surface_index)
		_lane_geo.clear()
		_belt_lists.clear()
		_alerts_before.clear()
		_held.clear()
	for id: String in _layers:
		var l: Layer = _layers[id]
		if not l.still:
			_drain(l, t)
	_resolve(null)
	if _on.has("sub") and t - _sub_at >= SUB_EVERY:
		_sub_at = t
		_subscription()
	if t >= _roll_at:
		roll()
	if t - _legend_at >= 0.5:
		_legend_at = t
		_update_legend()


## The last second's counts become the legend's rates.
func roll() -> void:
	_rates = _counts.duplicate()
	for id in _counts:
		_counts[id] = 0
	_roll_at = _now() + 1.0


func rate_of(id: String) -> int:
	return int(_rates.get(id, 0))


# --- messages --------------------------------------------------------------------------------------

func on_message(msg: Dictionary) -> void:
	var t := str(msg.get("t", ""))
	match t:
		"chunk":
			var c := Vector2i(int(msg.get("cx", 0)), int(msg.get("cy", 0)))
			var id := "kept" if msg.has("same") else "chunk"
			if _on.has(id):
				_count(id)
				_chunk(id, c)
		"ents", "dec", "bfar":
			var id := "chunk" if t == "ents" else t
			if _on.has(id):
				_count(id)
				_chunk(id, Vector2i(int(msg.get("cx", 0)), int(msg.get("cy", 0))))
		"kept":
			if _on.has("kept"):
				var l := _list(msg.get("l"))
				for i in range(0, l.size() - 3, 4):
					_count("kept")
					_chunk("kept", Vector2i(int(l[i]), int(l[i + 1])))
		"tiles":
			if _on.has("tiles"):
				var l := _list(msg.get("l"))
				for i in range(0, l.size() - 2, 3):
					_count("tiles")
					_rect("tiles", Vector2(int(l[i]) + 0.5, int(l[i + 1]) + 0.5), Vector2(0.92, 0.92), 0.0, LINE)
		"add", "upd":
			var e = msg.get("e")
			if _on.has(t) and e is Array and (e as Array).size() >= 5:
				_count(t)
				_entity(t, int(e[1]), Vector2(int(e[2]), int(e[3])) / 256.0, int(e[4]))
		"del", "mnd":
			if _on.has(t):
				_count(t)
				_entity(t, int(msg.get("p", 0)), Vector2(int(msg.get("x", 0)), int(msg.get("y", 0))) / 256.0, 0, false)
		"st":
			if _on.has("st"):
				var l := _list(msg.get("l"))
				for i in range(0, l.size() - 1, 2):
					_count("st")
					_unit("st", int(l[i]))
		"bs":
			if _lane_kinds:
				_belts(WireDecode.plain(msg))
		"pku":
			if _on.has("hand"):
				for r in _list(msg.get("l")):
					if r is Array and (r as Array).size() >= 5:
						_count("hand")
						_point("hand", int(r[2]), int(r[3]), 0.3)
						if int(r[4]) > 0:
							_lane("hand", int(r[4]))
		"ie":
			if _on.has("hand") or _on.has("ih"):
				_hand_events(msg)
		"ih":
			if _on.has("ih"):
				var l := _list(msg.get("l"))
				var deltas := int(msg.get("z", 0)) == 1
				var v := [0, 0, 0, 0]
				for i in range(0, l.size() - 3, 4):
					for j in 4:
						v[j] = v[j] + int(l[i + j]) if deltas else int(l[i + j])
					_count("ih")
					if _fresh("ih", int(v[0])):
						_point("ih", int(v[1]), int(v[2]))
		"mv":
			if _on.has("mv"):
				_movers(msg)
		"gi":
			if _on.has("gi"):
				var l := _list(msg.get("l"))
				for i in range(0, l.size() - 2, 3):
					_count("gi")
					var at := Vector2i(int(l[i + 1]), int(l[i + 2]))
					if _fresh("gi", at):
						_point("gi", at.x, at.y, 0.3)
		"fl", "pw", "ht":
			if _on.has("power"):
				var l := _list(msg.get("l"))
				var step := 6 if t == "fl" else 2
				for i in range(0, l.size() - step + 1, step):
					_count("power")
					var unit := int(l[i])
					if _fresh("power", unit):
						_unit("power", unit)
		"al":
			if _on.has("al"):
				_alerts(msg)
		"ac", "am", "aiu":
			if _on.has("alt"):
				for r in _list(msg.get("l")):
					if r is Array and not (r as Array).is_empty():
						_count("alt")
						_unit("alt", int(r[0]))


static func _list(v) -> Array:
	if WireDecode.packed(v):
		return Array(v)  # (a binary frame's list: st, ih, chunk tiles)
	return v if v is Array else []


func _belts(msg: Dictionary) -> void:
	var lm = msg.get("lm")
	if lm is Array:
		var a: Array = lm
		for i in range(0, a.size() - 11, 12):
			var key := int(a[i])
			_lane_geo[key] = [int(a[i + 4]) / 256.0, int(a[i + 5]) / 256.0, int(a[i + 6]) / 256.0, int(a[i + 7]) / 256.0,
				int(a[i + 8]) / 256.0, int(a[i + 9]) / 256.0, float(int(a[i + 2]))]
			if _on.has("lm"):
				_count("lm")
				_lane("lm", key)
	if _on.has("sl"):
		var sl := _list(msg.get("sl"))
		var i := 0
		while i + 2 < sl.size():
			_count("sl")
			_lane("sl", int(sl[i]))
			i += 3 + maxi(int(sl[i + 2]), 0) * 4
		var ew := _list(msg.get("ew"))
		for j in range(0, ew.size() - 3, 4):
			_count("sl")
			_lane("sl", int(ew[j]))
		var sh := _list(msg.get("sh"))
		for j in range(0, sh.size() - 1, 2):
			_count("sl")
			_lane("sl", int(sh[j]))
	if _on.has("pc"):
		var pc := _list(msg.get("pc"))
		for i in range(0, pc.size() - 4, 5):
			_count("pc")
			_lane("pc", int(pc[i]))
	var dl := _list(msg.get("dl"))
	if not dl.is_empty():
		for key in dl:
			if _on.has("dl"):
				_count("dl")
				_lane("dl", int(key))
			elif _lane_geo.has(int(key)):
				_lane_geo.erase(int(key))


## `ie`: inserters' hand events, nine numbers a record, each sent in three messages (taken once here).
func _hand_events(msg: Dictionary) -> void:
	var l := _list(msg.get("l"))
	var deltas := int(msg.get("z", 0)) == 1
	var v := [0, 0, 0, 0, 0, 0, 0, 0, 0]
	if _ie_seen.size() > 8192:
		_ie_seen.clear()
	for i in range(0, l.size() - 8, 9):
		for j in 9:
			v[j] = v[j] + int(l[i + j]) if deltas else int(l[i + j])
		var kind: int = v[0]
		var seen := Vector4i(kind, int(v[1]), int(v[2]), int(v[3]))
		if _ie_seen.has(seen):
			continue
		_ie_seen[seen] = true
		if _on.has("ih") and kind != 5 and kind != 6:
			_count("ih")
			if _fresh("ih", int(v[1])):
				_point("ih", int(v[6]), int(v[7]))
		if not _on.has("hand"):
			continue
		if (kind == 1 or kind == 2) and v[8] > 0:
			# A pick from a belt or a drop onto one: the hand and the belt.
			_count("hand")
			_point("hand", int(v[6]), int(v[7]))
			_unit("hand", int(v[8]))
		elif kind == 6:
			# An item a hand put on a belt (`ho`): its place on the lane.
			_count("hand")
			_lane("hand", int(v[3]), int(v[4]))


func _movers(msg: Dictionary) -> void:
	var deltas := int(msg.get("z", 0)) == 1
	var unit := 0
	var proto := 0
	var x := 0
	var y := 0
	for rec in _list(WireDecode.mv_records(msg)):  # (a binary frame's packed records, whole)
		if not (rec is Array) or (rec as Array).size() < 4:
			continue
		var r: Array = rec
		if deltas:
			unit += int(r[0])
			proto += int(r[1])
			x += int(r[2])
			y += int(r[3])
		else:
			unit = int(r[0])
			proto = int(r[1])
			x = int(r[2])
			y = int(r[3])
		_count("mv")
		if not _fresh("mv", unit):
			continue
		var side := SPOT
		var p = world.protos.entity(proto) if world != null else null
		if p != null:
			var s: Vector2 = p.box_max - p.box_min
			side = clampf(maxf(s.x, s.y), SPOT, 8.0)
		_point("mv", x, y, side)


## `al`: the force's whole list once a second; only an alert not in the last list flashes (on this surface).
func _alerts(msg: Dictionary) -> void:
	var now := {}
	var si: int = int(world.surface_index) if world != null else -1
	for a in _list(msg.get("l")):
		if not (a is Array) or (a as Array).size() < 3:
			continue
		for e in _list(a[2]):
			if not (e is Array) or (e as Array).size() < 5:
				continue
			_count("al")
			var key := "%s:%d:%d:%d" % [str(a[0]), int(e[0]), int(e[1]), int(e[2])]
			now[key] = true
			if _alerts_before.has(key) or (int(e[2]) > 0 and si >= 0 and int(e[2]) != si):
				continue
			if not _unit("al", int(e[4])):
				_point("al", int(e[0]), int(e[1]), 1.2)
	_alerts_before = now


# --- belt_items.gd's state (its debug tap) ---------------------------------------------------------

## belt_items.gd's debug tap: a job was just applied, none runs, so its state may be read here.
func on_belt_job(job) -> void:
	if belt_items == null or not is_instance_valid(belt_items):
		return
	var st = belt_items.get("_state")
	if st == null:
		return
	var lanes: Dictionary = st.lanes
	if _on.has("bre") and job != null:
		var re = job.get("resend")
		if re is Array:
			for key in re:
				_count("bre")
				_lane("bre", int(key))
	_resolve(lanes)
	var t := _now()
	if _on.has("lanes") and t - _lanes_at >= LANES_EVERY:
		_lanes_at = t
		sample_lanes(st)
	if _on.has("frozen") and t - _frozen_at >= FROZEN_EVERY:
		_frozen_at = t
		sample_frozen(st)


func _focus() -> Vector2:
	return world.focus() if world != null and is_instance_valid(world) else Vector2.ZERO


## How each lane round the focus is drawn now (belt_items.gd's State: its lanes and the lattice's): the
## simulation's items, or the lattice; and belts with no lane loaded: far icons (outside the square the items
## are simulated in, in a chunk belt_lanes.gd draws), or nothing. Call only when no belt job runs.
func sample_lanes(st) -> void:
	var focus := _focus()
	var r2 := TINT_RADIUS * TINT_RADIUS
	var lanes: Dictionary = st.lanes
	var lat: Dictionary = st.lat
	var out := PackedFloat32Array()
	var n := {"sim": 0, "lattice": 0, "far": 0, "none": 0}
	var loaded := {}
	for key: int in lanes:
		var m: PackedInt32Array = lanes[key]
		if Vector2(m[5], m[6]).distance_squared_to(focus * 256.0) > r2 * 65536.0:
			continue
		loaded[(key - 1) >> 3] = true
		if m[0] == HIDDEN_LINE:
			continue
		var g := geo_of_meta(m)
		_lane_geo[key] = g
		var mode := "lattice" if lat.has(key) else "sim"
		n[mode] += 1
		var col: Color = LANE_COLORS[mode]
		col.a = 0.55
		_still_lane(out, g, col, -1.0)
	var cov := Vector3(0.0, 0.0, -1.0)
	var far := {}
	if belt_lanes != null and is_instance_valid(belt_lanes):
		cov = belt_lanes.covered
		if int(belt_lanes.distance) > 0:
			far = belt_lanes.built_chunks()
	for r in belts_near(focus):
		if loaded.has(r.unit):
			continue
		var pos: Vector2 = r.pos
		var outside := cov.z < 0.0 or absf(pos.x - cov.x) >= cov.z or absf(pos.y - cov.y) >= cov.z
		var mode := "far" if outside and far.has(r.chunk) else "none"
		n[mode] += 1
		var f := _footprint(r.proto_id, pos, r.dir)
		var col: Color = LANE_COLORS[mode]
		col.a = 0.4
		_still(out, f[0], (f[1] as Vector2) * 0.8, f[2], 0.0, col, -1.0)
	stats["lanes"] = n
	_set_still("lanes", out)


## The belts (records) in the loaded chunks within TINT_RADIUS of `at`, kept per chunk until its entities change.
func belts_near(at: Vector2) -> Array:
	var out: Array = []
	if world == null or not is_instance_valid(world):
		return out
	var c0: Vector2i = world.chunk_of(at - Vector2(TINT_RADIUS, TINT_RADIUS))
	var c1: Vector2i = world.chunk_of(at + Vector2(TINT_RADIUS, TINT_RADIUS))
	var r2 := TINT_RADIUS * TINT_RADIUS
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			var c := Vector2i(cx, cy)
			var cv = world.chunks.get(c)
			if cv == null or not cv.loaded:
				continue
			var ents: Dictionary = cv.entities
			var kept: Array = _belt_lists.get(c, [])
			var rev := int(cv.content_rev)
			if kept.is_empty() or int(kept[0]) != rev:
				var belts: Array = []
				for key in ents:
					var r = ents[key]
					var p = world.protos.entity(r.proto_id)
					if p != null and BELT_TYPES.has(p.type) and r.unit > 0:
						belts.append(r)
				kept = [rev, belts]
				_belt_lists[c] = kept
			for r in kept[1]:
				var pos: Vector2 = r.pos
				if pos.distance_squared_to(at) <= r2:
					out.append(r)
	return out


## The lattice against the simulation, for the lanes the lattice draws round the focus: standing while the
## simulation's front item on the lane moves (the frozen lanes), or sliding while it stands. Call only when no
## belt job runs.
func sample_frozen(st) -> void:
	var focus := _focus()
	var r2 := TINT_RADIUS * TINT_RADIUS * 65536.0
	var lanes: Dictionary = st.lanes
	var keys := PackedInt64Array()
	for key: int in st.lat:
		var m: PackedInt32Array = lanes.get(key, PackedInt32Array())
		if m.size() >= 9 and Vector2(m[5], m[6]).distance_squared_to(focus * 256.0) <= r2:
			keys.append(key)
	var fronts: PackedInt32Array = st.sim.lane_fronts(keys) if not keys.is_empty() else PackedInt32Array()
	var lattice = st.lattice
	var native: bool = lattice.has_method("drawn_speed")
	var speeds := PackedInt32Array()
	speeds.resize(keys.size())
	for q in keys.size():
		if native:
			speeds[q] = int(lattice.drawn_speed(keys[q]))
		else:
			var ln = lattice.drawn.get(keys[q])
			speeds[q] = int(ln.v) if ln != null else -1
	var res := lattice_against_sim(keys, speeds, fronts)
	var t := _now()
	var stands: PackedInt64Array = res[0]
	var still := {}
	var held := 0
	var out := PackedFloat32Array()
	for key in stands:
		still[key] = true
		if not _held.has(key):
			_held[key] = t
		var long := t - float(_held[key]) >= HELD_SEC
		if long:
			held += 1
		var g := geo_of_meta(lanes[key])
		var col: Color = FROZEN_COLORS["stands"]
		_still_lane(out, g, col if long else Color(col, 0.55), -2.0 if long else -1.0, LANE_W * 2.0)
	for key in _held.keys():
		if not still.has(key):
			_held.erase(key)
	var slides: PackedInt64Array = res[1]
	for key in slides:
		_still_lane(out, geo_of_meta(lanes[key]), FROZEN_COLORS["slides"], -1.0, LANE_W * 2.0)
	stats["frozen"] = [stands.size(), held, slides.size()]
	_set_still("frozen", out)


## Which lattice lanes disagree with the simulation: `lattice_v` each lane's lattice speed (1/256 a tick; -1:
## not drawn), `fronts` belt_sim.gd lane_fronts' three numbers a lane (front position, -1 none; speed; items).
## [standing while the simulation moves them, sliding while they stand], each PackedInt64Array of keys.
static func lattice_against_sim(keys: PackedInt64Array, lattice_v: PackedInt32Array, fronts: PackedInt32Array) -> Array:
	var stands := PackedInt64Array()
	var slides := PackedInt64Array()
	for q in keys.size():
		if q >= lattice_v.size() or fronts.size() < q * 3 + 3:
			break
		var lv := lattice_v[q]
		if lv < 0 or fronts[q * 3] < 0:
			continue
		var sv := fronts[q * 3 + 1]
		if lv == 0 and sv > 0:
			stands.append(keys[q])
		elif lv > 0 and sv == 0:
			slides.append(keys[q])
	return [stands, slides]


## The subscription (world.gd subscription()): its square, the chunks still to come in the order asked for,
## brightest first (at most SUB_SHOWN), those on their way outlined, and the view's direction from the middle.
func _subscription() -> void:
	if world == null or not is_instance_valid(world) or not world.has_method("subscription"):
		return
	var s: Dictionary = world.subscription()
	var list: Array = s["list"]
	var coming: Dictionary = s["coming"]
	var centre: Vector2i = s["center"]
	var radius: int = s["radius"]
	var f: Vector2i = s["f"]
	var key := [centre, radius, list.size(), coming.size(), world.loaded_chunk_count(), f]
	if key == _sub_key:
		return
	_sub_key = key
	var col := color_of("sub")
	var out := PackedFloat32Array()
	var mid := Vector2(centre) * 32.0 + Vector2(16.0, 16.0)
	var side := (radius * 2 + 1) * 32.0
	_still(out, mid, Vector2(side, side), 0.0, 0.8, col, -1.0)
	var to_come := 0
	var shown := 0
	for c: Vector2i in list:
		var cv = world.chunks.get(c)
		if cv != null and cv.loaded:
			continue
		to_come += 1
		if shown >= SUB_SHOWN:
			continue
		var a := lerpf(0.45, 0.06, float(shown) / SUB_SHOWN)
		var at := Vector2(c) * 32.0 + Vector2(16.0, 16.0)
		_still(out, at, Vector2(30.0, 30.0), 0.0, 0.0, Color(col, a), -1.0)
		if coming.has(c):
			_still(out, at, Vector2(30.0, 30.0), 0.0, 0.5, Color(col, 0.9), -1.0)
		shown += 1
	if f != Vector2i.ZERO:
		var d := Vector2(f).normalized() * radius * 32.0
		_still(out, mid + d * 0.5, Vector2(maxf(d.length(), 1.0), 1.5), atan2(d.y, d.x), 0.0, Color(col, 0.8), -1.0)
	stats["sub"] = [list.size(), coming.size(), to_come]
	_set_still("sub", out)


# --- tests -----------------------------------------------------------------------------------------

## Flashes of a kind drawn now (written, not faded, or a state's instances).
func drawn_count(id: String) -> int:
	var l: Layer = _layers.get(id)
	if l == null:
		return 0
	return l.mirror.size() / 11 if l.still else l.used


## Flashes of a kind still waiting to be written.
func waiting_count(id: String) -> int:
	var l: Layer = _layers.get(id)
	return 0 if l == null else l.queue.size() / 6


## Instance i of a kind: [centre (Factorio's x, y), size, angle, outline, colour, alpha now (as the shader fades
## it), when it was drawn (-1 stays, -2 pulses)].
func drawn_at(id: String, i: int) -> Array:
	var l: Layer = _layers.get(id)
	if l == null or i < 0 or i >= drawn_count(id):
		return []
	var m := l.mirror
	var o := i * (11 if l.still else 7)
	var born: float = m[o + 10] if l.still else m[o + 6]
	var col := Color(m[o + 6], m[o + 7], m[o + 8], m[o + 9]) if l.still else l.color
	var a := 1.0
	if born >= 0.0:
		a = clampf(1.0 - (_now() - born) / FADE, 0.0, 1.0)
	return [Vector2(m[o], m[o + 1]), Vector2(m[o + 2], m[o + 3]), m[o + 4], m[o + 5], col, a, born]


func has_layer(id: String) -> bool:
	return _layers.has(id)


# --- the legend ------------------------------------------------------------------------------------

func _make_legend() -> void:
	if _on.is_empty():
		if _legend != null:
			_legend.queue_free()
			_legend = null
		_legend_rows = []
		return
	if _legend == null:
		_legend = CanvasLayer.new()
		_legend.name = "UpdatesLegend"
		_legend.layer = 114
		add_child(_legend)
		var panel := PanelContainer.new()
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var bg := StyleBoxFlat.new()
		bg.bg_color = Color(0, 0, 0, 0.6)
		bg.set_content_margin_all(Kit.px(8))
		panel.add_theme_stylebox_override("panel", bg)
		panel.position = Kit.pxv(12, 560)
		_legend.add_child(panel)
		_legend_box = VBoxContainer.new()
		_legend_box.add_theme_constant_override("separation", Kit.px(2))
		_legend_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(_legend_box)
	for c in _legend_box.get_children():
		_legend_box.remove_child(c)
		c.queue_free()
	_legend_rows = []
	_legend_box.add_child(_legend_label("Bridge updates (each fades in %d s)" % int(FADE), Color(1.0, 0.9, 0.75)))
	for id: String in kind_ids():
		if not _on.has(id):
			continue
		var parts: Array = [""]
		if id == "lanes":
			parts = LANE_COLORS.keys()
		elif id == "frozen":
			parts = FROZEN_COLORS.keys()
		for part: String in parts:
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", Kit.px(6))
			row.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var sw := ColorRect.new()
			sw.color = LANE_COLORS[part] if id == "lanes" else (FROZEN_COLORS[part] if id == "frozen" else color_of(id))
			sw.custom_minimum_size = Kit.pxv(12, 12)
			sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(sw)
			var label := _legend_label("", Color(1, 1, 1))
			row.add_child(label)
			_legend_box.add_child(row)
			_legend_rows.append([label, id, part])
	_update_legend()


func _legend_label(text: String, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", Kit.font("semibold"))
	l.add_theme_font_size_override("font_size", Kit.px(13))
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", Kit.px(3))
	return l


func _update_legend() -> void:
	for r: Array in _legend_rows:
		(r[0] as Label).text = legend_line(str(r[1]), str(r[2]))


## A legend row's text: a kind's name and its updates a second, or a state's counts.
func legend_line(id: String, part := "") -> String:
	match id:
		"lanes":
			var n: Dictionary = stats.get("lanes", {})
			return "%s: %d" % [LANE_NAMES[part], int(n.get(part, 0))]
		"frozen":
			var f: Array = stats.get("frozen", [0, 0, 0])
			if part == "stands":
				return "Lattice standing, simulation moving: %d (%d for over %.1f s)" % [f[0], f[1], HELD_SEC]
			return "Lattice sliding, simulation standing: %d" % f[2]
		"sub":
			var s: Array = stats.get("sub", [0, 0, 0])
			return "Subscription: %d chunks asked, %d on their way, %d still to come" % [s[0], s[1], s[2]]
	return "%s  %d/s" % [name_of(id), rate_of(id)]


## The legend as text (tests).
func legend_text() -> String:
	var lines: Array = []
	for r: Array in _legend_rows:
		lines.append(legend_line(str(r[1]), str(r[2])))
	return "\n".join(PackedStringArray(lines))
