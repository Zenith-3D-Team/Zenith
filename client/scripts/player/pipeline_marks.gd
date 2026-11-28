extends Node3D
## Factorio 2.1's fluid pipeline visualization (N9): a mark at each joint of a fluid pipeline, tinted to
## the fluid in it (white when empty), red when the pipeline is over its extent (L11's
## pipeline_overextended, default_pipeline_extent 320), and dashes along an underground pair's run.
## Factorio draws it (its interface settings, on by default):
## - "Show fluid pipeline visualization when selected" (2.1.24): the hovered fluid entity's pipelines (a pipe's,
##   or those on a pump's, boiler's or machine's connections);
## - "Show fluid pipeline visualization" (Alt-mode only since 2.1.7): with a fluid-related entity held,
##   every pipeline in view.
## The pictures are Factorio's utility sprites fluid_visualization_connection_both_ways and _underground
## (core/graphics/fluid-visualization/, read from the player's install; plain drawn ones without it).
## Factorio's own one-way chevron (fluid_visualization_connection) isn't drawn: the bridge doesn't say
## which way fluid flows, so every joint takes the both-ways mark.
##
## A pipeline is found in the client (no protocol change): from a pipe, across its `pc` sides; from a
## pipe to ground, its open side and its underground partner (UndergroundPairs.partner); a storage
## tank's connections from its `eprops` fluid boxes (`fj`, the joins the bridge sends for tanks). It stops at pumps and machines, which Factorio's
## fluid system makes segments of their own (tools/live_check.py --only pipevis compares it with
## LuaEntity.get_fluid_segment_id). Found a slice a frame (FrameBudget "pipelines"), at most CAP
## entities, kept until a chunk it touched changes (ChunkView.content_rev). Each pipeline is one mesh
## built once, its colour a material tint.
##
## `--pipeline-vis=off`: nothing drawn, as before (docs/RUNNING.md).

const ProtoDB := preload("res://scripts/world/protos.gd")
const WorldMirror := preload("res://scripts/world/world.gd")
const ChunkView := preload("res://scripts/world/chunk_view.gd")
const CursorOverlay := preload("res://scripts/player/cursor_overlay.gd")
const UndergroundPairs := preload("res://scripts/world/underground_pairs.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const FluidsPowerLayer := preload("res://scripts/world/fluids_power.gd")
const FrameBudget := preload("res://scripts/world/frame_budget.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const Switches := preload("res://scripts/switches.gd")

static var on := Switches.on("--pipeline-vis")
static var show_pipe_joints := Switches.has("--pipeline-joints=old")
## `--alt-pipe-range=old`: limit Alt-mode pipeline scanning to the old RADIUS := 2 chunk box.
static var wide_range := not (Switches.has("--alt-pipe-range=old"))

## What a pipeline is made of in the client; anything else with fluid (pumps, machines) ends it.
const PIPE_TYPES := ["pipe", "infinity-pipe", "pipe-to-ground", "storage-tank"]
## Held, these show every pipeline in Alt-mode (Factorio's show_fluid_visualization_when_in_cursor;
## the bridge doesn't send that flag, so: these, or anything with fluid boxes in its `eprops`).
const HELD_TYPES := ["pipe", "infinity-pipe", "pipe-to-ground", "storage-tank", "pump", "offshore-pump"]
const CAP := 4000
## Entities a search goes through each frame however little of its slice is left (about 0.3 ms).
const MIN_STEP := 32
## Chunks either side of the cursor's whose pipelines show in Alt-mode (pole_coverage.gd's window).
const RADIUS := 2
## Pipelines kept found but not shown, before the oldest are let go.
const KEEP := 48
## Factorio's pictures are 48 and 64 pixels at scale 0.5 (utility-sprites.lua): 0.75 and 1 tile.
const JOINT_SIZE := 0.75
const UNDER_SIZE := 1.0
const LIFT := 0.05
## The red of an overextended pipeline. Factorio's data doesn't give it; its alert red, approximated.
const OVEREXTENDED := Color(0.93, 0.16, 0.12)
const EMPTY := Color(1.0, 1.0, 1.0, 0.9)
const JOINT_PICTURE := "core/graphics/fluid-visualization/connection-both-ways.png"
const UNDER_PICTURE := "core/graphics/fluid-visualization/connection-underground.png"

var world: WorldMirror
## fluids_power.gd, for the fluid in each pipeline (`fl`); null: every pipeline white.
var fluids_power: FluidsPowerLayer

var _segs: Array = []  # Seg, most recently shown last
var _owner := {}  # entity key -> Flood (finished or being found)
var _seg_of := {}  # Flood -> Seg
var _job: Flood = null
var _roots: Array = []  # Rec: pipelines asked for this frame, not found yet
var _window := {}  # Vector2i -> [ChunkView instance id, content_rev, [Rec...]]: the pipes of the Alt-mode window
## What the last frame was worked out from: a frame with the same (the hover, the held item, the cursor's
## chunk, the red, the fluids, every chunk the shown pipelines and the window read) does nothing.
var _last_sig: Array = []
var _last_chunks: Array = []
var _last_fluids = null
var _watch := {}  # Vector2i -> true: the chunks the shown pipelines read
var _want := {}  # Seg -> true: the pipelines asked for (shown)
var _want_list: Array = []
## The units the `pipeline` alerts are on, worked out when the alerts change (alerts_heard, or another list).
var _red_units := {}
var _alerts_ref = null
var _alerts_dirty := true
## The most entities one pipeline is found to (CAP; the UI test lowers it).
var cap := CAP
## Pipelines made so far (the UI test: none made again while nothing changes).
var made_count := 0
var _deferred := false  # the running search is found and its mesh waits for this frame (once)
## For the UI test: pipelines shown now, and how long the last frame's finding took (µs).
var shown: Array = []
var last_usec := 0
static var _pictures := {}
static var _tank_chunks := {}  # ChunkView instance id -> [content_rev, whether it holds a storage tank]


## A pipeline found from one entity: its entities, the joints between them ([centre, axis]), the
## underground pairs' runs ([end, end]) and the chunks it read, to tell when it is stale.
class Flood:
	extends RefCounted
	var world: WorldMirror
	var eprops: Dictionary
	var cap := CAP
	var queue: Array = []
	var head := 0
	var queued := {}  # key -> true
	var done_keys := {}  # key -> true
	var nodes: Array = []
	var units := {}  # unit -> true
	var joints: Array = []
	var unders: Array = []
	var chunks := {}  # Vector2i -> [instance id, content_rev], [-1, -1] when not loaded
	var capped := false
	## Its marks as they are found, so a big pipeline's mesh costs no frame of its own: the joints' quads
	## and the underground runs' (vertices, UVs, indices).
	var jv := PackedVector3Array()
	var juv := PackedVector2Array()
	var ji := PackedInt32Array()
	var uv3 := PackedVector3Array()
	var uuv := PackedVector2Array()
	var ui := PackedInt32Array()
	## key -> Flood: the marks' index of which pipeline holds what, filled as it goes (null: none).
	var owner = null
	## Floods that held some of its entities before it (asymmetric connections): their pipelines go.
	var displaced := {}
	## key -> the Flood that held it before this one took it, put back if this one is dropped unfinished.
	var prev_owner := {}

	func _init(w: WorldMirror, props: Dictionary, root: WorldMirror.Rec, limit: int) -> void:
		world = w
		eprops = props
		cap = limit
		queue.append(root)
		queued[root.key] = true

	func finished() -> bool:
		return capped or head >= queue.size()

	func _note(at: Vector2) -> void:
		var c := WorldMirror.chunk_of(at)
		if chunks.has(c):
			return
		var cv: ChunkView = world.chunks.get(c)
		chunks[c] = [cv.get_instance_id(), cv.content_rev] if cv != null else [-1, -1]

	## Whether a chunk it read has changed since (or come or gone).
	func stale() -> bool:
		for c: Vector2i in chunks:
			var seen: Array = chunks[c]
			var cv: ChunkView = world.chunks.get(c)
			if cv == null:
				if int(seen[0]) != -1:
					return true
			elif int(seen[0]) != cv.get_instance_id() or int(seen[1]) != int(cv.content_rev):
				return true
		return false


## One pipeline drawn.
class Seg:
	extends RefCounted
	var flood: Flood
	var mesh: MeshInstance3D
	var materials: Array = []
	var fluids_ref = null
	var fluid := ""
	var color := Color(0, 0, 0, 0)


## The pipeline `rec` is in, found whole at once (the UI test, live_check's twin): a Flood.
static func segment_from(w: WorldMirror, rec: WorldMirror.Rec, eprops: Dictionary, cap := CAP) -> Flood:
	var f := Flood.new(w, eprops, rec, cap)
	step(f, 1 << 62)
	return f


## Works on `f` until `deadline` (Time.get_ticks_usec()); true when its pipeline is whole (or capped).
static func step(f: Flood, deadline: int) -> bool:
	# At least MIN_STEP entities a call, so a frame whose slice is already spent still moves it on.
	var from := f.head
	while f.head < f.queue.size():
		if f.nodes.size() >= f.cap:
			f.capped = true
			return true
		var r: WorldMirror.Rec = f.queue[f.head]
		f.head += 1
		f.done_keys[r.key] = true
		f.nodes.append(r)
		if f.owner != null:
			var before = f.owner.get(r.key)
			if before != null and before != f:
				f.displaced[before] = true
				f.prev_owner[r.key] = before
			f.owner[r.key] = f
		if r.unit > 0:
			f.units[r.unit] = true
		f._note(r.pos)
		for n: Array in neighbours(f.world, f.eprops, r, f):
			var o: WorldMirror.Rec = n[0]
			f._note(n[2])
			# A pipeline found to its cap holds what it reached: this one ends there (its joint is that one's),
			# so a pipeline over the cap isn't found again and again from its far pipes, each taking the other's.
			if f.owner != null:
				var held = f.owner.get(o.key)
				if held != null and held != f and (held as Flood).capped:
					continue
			if not f.done_keys.has(o.key):
				if str(n[1]) == "u":
					f.unders.append([r.pos, o.pos])
					var d: Vector2 = o.pos - r.pos
					var axis := d.normalized()
					for k in range(1, roundi(d.length())):
						_quad_into(f, true, r.pos + axis * k, axis, UNDER_SIZE * 0.5)
				else:
					f.joints.append([n[2], n[3]])
					if show_pipe_joints:
						_quad_into(f, false, n[2], (n[3] as Vector2).normalized(), JOINT_SIZE * 0.5)
			if not f.queued.has(o.key):
				f.queued[o.key] = true
				f.queue.append(o)
		if (f.head & 7) == 0 and f.head - from >= MIN_STEP and Time.get_ticks_usec() > deadline:
			return false
	return true


static func is_pipe(w: WorldMirror, r: WorldMirror.Rec) -> bool:
	if r == null or r.extra.has("gh"):
		return false
	var p: ProtoDB.EntityProto = w.protos.entity(r.proto_id)
	return p != null and PIPE_TYPES.has(p.type)


## Whether holding `proto` shows every pipeline in Alt-mode.
static func held_shows(proto: ProtoDB.EntityProto, eprops: Dictionary) -> bool:
	if proto == null:
		return false
	return HELD_TYPES.has(proto.type) or eprops.get(proto.id, {}).get("x", {}).has("fb")


static func _tile(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x), floori(p.y))


static func _type(w: WorldMirror, r: WorldMirror.Rec) -> String:
	var p: ProtoDB.EntityProto = w.protos.entity(r.proto_id) if r != null else null
	return p.type if p != null and not r.extra.has("gh") else ""


## The entities `r` shares its fluid with: [other, "j" a joint or "u" an underground pair, the joint's
## centre, its axis (from `r` towards the other)]. `f`: the flood, which notes every chunk looked into
## (one not loaded too), so a pipeline whose far end's chunk comes later is found again with it.
static func neighbours(w: WorldMirror, eprops: Dictionary, r: WorldMirror.Rec, f: Flood = null) -> Array:
	var out: Array = []
	var t := _type(w, r)
	match t:
		"pipe", "infinity-pipe":
			var mask := int(r.extra.get("pc", 0))
			# The client's own masks (world.gd, no `pc` from the bridge) join pipes alone: a tank whose
			# connection leads onto this pipe is looked for on the other sides.
			var own_mask := not r.extra.has("pc_mod")
			for i in 4:
				if mask & (1 << i):
					_side(w, eprops, r, _tile(r.pos), i, out, false, f)
				elif own_mask:
					_side(w, eprops, r, _tile(r.pos), i, out, true, f)
		"pipe-to-ground":
			var open := (r.dir >> 2) & 3
			# The bridge's `pc` says whether its open end is connected; the client's own (none) tries it.
			if not r.extra.has("pc_mod") or int(r.extra.get("pc", 0)) & (1 << open):
				_side(w, eprops, r, _tile(r.pos), open, out, false, f)
			var reach := int(eprops.get(r.proto_id, {}).get("under", 10.0))
			if f != null:
				var back := -Vector2(WorldMirror.PIPE_STEPS[open])
				for k in range(1, reach + 1):
					f._note(r.pos + back * k)
			var other := UndergroundPairs.partner(w, r, reach)
			if other != null and not other.extra.has("gh"):
				out.append([other, "u", (r.pos + other.pos) * 0.5, (other.pos - r.pos).normalized()])
		"storage-tank":
			for port: Array in tank_ports(w, eprops, r):
				var own: Vector2i = port[0]
				var next: Vector2i = port[1]
				var d := next - own
				var at := (Vector2(own) + Vector2(next)) * 0.5 + Vector2(0.5, 0.5)
				if f != null:
					f._note(Vector2(next))
				var o: WorldMirror.Rec = _at_tile(w, next)
				if o == null:
					continue
				var ot := _type(w, o)
				if ot == "pipe" or ot == "infinity-pipe":
					# The client's own masks join pipes alone; the bridge's say whether it reaches the tank.
					if not o.extra.has("pc_mod") or int(o.extra.get("pc", 0)) & (1 << _index(-d)):
						out.append([o, "j", at, Vector2(d)])
				elif ot == "pipe-to-ground":
					if _index(-d) * 4 == o.dir:
						out.append([o, "j", at, Vector2(d)])
				elif ot == "storage-tank" and o != r:
					for back: Array in tank_ports(w, eprops, o):
						if back[0] == next and back[1] == own:
							out.append([o, "j", at, Vector2(d)])
							break
	return out


## A pipe's (or a pipe to ground's) side `i` (0 north, 1 east, 2 south, 3 west).
static func _side(w: WorldMirror, eprops: Dictionary, r: WorldMirror.Rec, tile: Vector2i, i: int, out: Array,
		tank_only := false, f: Flood = null) -> void:
	var step: Vector2i = WorldMirror.PIPE_STEPS[i]
	var next := tile + step
	if f != null and not tank_only:
		f._note(Vector2(next))
	var back := (i + 2) % 4
	var at := Vector2(tile) + Vector2(0.5, 0.5) + Vector2(step) * 0.5
	if tank_only and not _tanks_round(w, next):
		return
	var o: WorldMirror.Rec = _at_tile(w, next)
	if o == null:
		return
	var t := _type(w, o)
	if tank_only and t != "storage-tank":
		return
	match t:
		"pipe", "infinity-pipe":
			if int(o.extra.get("pc", 0)) & (1 << back):
				out.append([o, "j", at, Vector2(step)])
		"pipe-to-ground":
			if o.dir == back * 4:
				out.append([o, "j", at, Vector2(step)])
		"storage-tank":
			for port: Array in tank_ports(w, eprops, o):
				if port[1] == tile:
					out.append([o, "j", at, Vector2(step)])
					return


## The pipe on `tile`, else the building over it, else null.
static func _at_tile(w: WorldMirror, tile: Vector2i) -> WorldMirror.Rec:
	var o: WorldMirror.Rec = w.pipe_at(tile)
	if o != null:
		return o
	return w.pick(Vector2(tile) + Vector2(0.5, 0.5))


## Whether a storage tank may stand on `tile`: one in its chunk, or in the chunk next to it when the tile
## is within a tank's reach of that edge. Per chunk and content_rev, so a line of pipes doesn't pick
## round every tile for tanks (only the client's own masks need it).
static func _tanks_round(w: WorldMirror, tile: Vector2i) -> bool:
	var c := WorldMirror.chunk_of(Vector2(tile))
	var inner := Vector2i(posmod(tile.x, 32), posmod(tile.y, 32))
	for dy in range(-1 if inner.y < 2 else 0, 2 if inner.y > 29 else 1):
		for dx in range(-1 if inner.x < 2 else 0, 2 if inner.x > 29 else 1):
			var cv: ChunkView = w.chunks.get(c + Vector2i(dx, dy))
			if cv == null:
				continue
			var seen: Array = _tank_chunks.get(cv.get_instance_id(), [])
			if seen.is_empty() or int(seen[0]) != int(cv.content_rev):
				var any := false
				for r: WorldMirror.Rec in cv.entities.values():
					if _type(w, r) == "storage-tank":
						any = true
						break
				if _tank_chunks.size() > 4096:
					_tank_chunks.clear()
				seen = [cv.content_rev, any]
				_tank_chunks[cv.get_instance_id()] = seen
			if bool(seen[1]):
				return true
	return false


static func _index(step: Vector2i) -> int:
	return WorldMirror.PIPE_STEPS.find(step)


## A storage tank's connections: [its own tile, the tile outside it the connection leads onto], from
## its `eprops` fluid boxes ([dx, dy, way, flow], turned as it stands): `fb`, else `fj` (the bridge's
## pipeline joins for tanks, which show no arrows; a bridge without `fj`: none, the marks stop at the tank).
static func tank_ports(w: WorldMirror, eprops: Dictionary, t: WorldMirror.Rec) -> Array:
	var out: Array = []
	var x: Dictionary = eprops.get(t.proto_id, {}).get("x", {})
	var fb = x.get("fb", x.get("fj"))
	if not (fb is Array):
		return out
	for c in fb:
		if not (c is Array) or c.size() < 3:
			continue
		var own: Vector2 = t.pos + CursorOverlay.turn(Vector2(float(c[0]), float(c[1])), t.dir)
		var way := CursorOverlay.dir_vector(int(c[2]) + t.dir).round()
		out.append([_tile(own), _tile(own + way)])
	return out


## The pipelines on a fluid entity's connections (a pump, a boiler, a machine): the pipe, pipe to ground or
## tank each connection leads onto, from the record's `fc` (L10) or its `eprops` fluid boxes.
static func connection_pipes(w: WorldMirror, eprops: Dictionary, r: WorldMirror.Rec) -> Array:
	var out: Array = []
	if r == null or r.extra.has("gh"):
		return out
	var spots: Array = []
	var fc = r.extra.get("fc")
	if fc is Array and not (fc as Array).is_empty():
		for c in fc:
			if c is Array and c.size() >= 3:
				spots.append(r.pos + Vector2(float(c[0]), float(c[1])) + CursorOverlay.dir_vector(int(c[2])))
	else:
		var fb = eprops.get(r.proto_id, {}).get("x", {}).get("fb")
		if fb is Array:
			for c in fb:
				if c is Array and c.size() >= 3:
					spots.append(r.pos + CursorOverlay.turn(Vector2(float(c[0]), float(c[1])), r.dir)
						+ CursorOverlay.dir_vector(int(c[2]) + r.dir))
	for at: Vector2 in spots:
		var o: WorldMirror.Rec = _at_tile(w, _tile(at))
		if o != null and o != r and is_pipe(w, o) and not out.has(o):
			out.append(o)
	return out


## Called each frame by player_input.gd: `hovered` (its pipeline, or a fluid entity's on its connections),
## `held` the placed entity in the cursor, `at` the cursor on the ground (null: none), `hover_info` the
## `hinfo` answer (its `ox`), `alerts` the model's `al` lists (their `pipeline`). A frame with nothing
## changed costs a look at the chunks it read; the rest is under FrameBudget's "pipelines".
func update(hovered: WorldMirror.Rec, held: ProtoDB.EntityProto, alt_mode: bool, at, eprops: Dictionary,
		hover_info: Dictionary, alerts: Array) -> void:
	var t0 := Time.get_ticks_usec()
	if not on or world == null:
		shown = []
		_last_sig = []
		_hide_all()
		last_usec = Time.get_ticks_usec() - t0
		return
	var hover_ok := hovered != null and bool(Settings.get_value("interface", "fluid_vis_selected"))
	var held_ok := alt_mode and at is Vector2 and held_shows(held, eprops) and bool(Settings.get_value("interface", "fluid_vis"))
	if _alerts_dirty or not is_same(alerts, _alerts_ref):
		_alerts_dirty = false
		_alerts_ref = alerts
		_red_units = {}
		for a in alerts:
			if a is Dictionary and str(a.get("kind", "")) == "pipeline":
				for e in a.get("entities", []):
					if e is Dictionary and int(e.get("unit", 0)) > 0:
						_red_units[int(e["unit"])] = true
	var red_units := _red_units
	var ox_unit := 0
	if hover_ok and hovered.unit > 0 and int(hover_info.get("u", 0)) == hovered.unit and hover_info.has("ox"):
		ox_unit = hovered.unit
	var cursor_chunk = WorldMirror.chunk_of(at) if held_ok else null
	var fl = fluids_power.fluids if fluids_power != null else null
	var sig := [hovered.key if hover_ok else null, held_ok, cursor_chunk, red_units.keys(), ox_unit]
	var idle := _job == null and _roots.is_empty()
	var changed := sig != _last_sig or not is_same(fl, _last_fluids) or _chunks_sig(cursor_chunk) != _last_chunks
	# A chunk the running search read changed under it: worked out again (_drop_stale drops it, its root comes back).
	if not changed and _job != null and _job.stale():
		changed = true
	if idle and not changed:
		last_usec = Time.get_ticks_usec() - t0
		return
	var deadline := t0 + FrameBudget.grant(&"pipelines")
	var found_from := _want_list.size()
	if changed:
		# What is asked for, worked out again only when something changed; while pipelines are still being
		# found the same roots carry on from the frame before.
		_drop_stale()
		var roots: Array = []
		if hover_ok:
			if is_pipe(world, hovered):
				roots.append(hovered)
			else:
				roots.append_array(connection_pipes(world, eprops, hovered))
		if held_ok:
			roots.append_array(_window_pipes(at))
		_want = {}
		_want_list = []
		_roots = []
		var job_wanted := false
		for r: WorldMirror.Rec in roots:
			var owner = _owner.get(r.key)
			var seg: Seg = _seg_of.get(owner) if owner != null else null
			if seg != null:
				if not _want.has(seg):
					_want[seg] = true
					_want_list.append(seg)
			elif _job != null and _job.queued.has(r.key):
				job_wanted = true
			else:
				_roots.append(r)
		# A pipeline being found that nothing asks for any more is dropped.
		if _job != null and not job_wanted:
			_drop_job()
		found_from = 0
	_find(_want, _want_list, eprops, deadline)
	for k in range(found_from, _want_list.size()):
		var seg: Seg = _want_list[k]
		var red := ox_unit != 0 and seg.flood.units.has(ox_unit)
		if not red:
			for u in red_units:
				if seg.flood.units.has(u):
					red = true
					break
		_tint(seg, red)
	if changed:
		# Shown last: the oldest unshown are let go first.
		var rest: Array = []
		for seg: Seg in _segs:
			var show := _want.has(seg)
			seg.mesh.visible = show
			if not show:
				rest.append(seg)
		rest.append_array(_want_list)
		_segs = rest
		_watch = {}
	else:
		for k in range(found_from, _want_list.size()):
			(_want_list[k] as Seg).mesh.visible = true
	while _segs.size() > KEEP + _want_list.size():
		_forget(_segs[0])
	for k in range(0 if changed else found_from, _want_list.size()):
		for c: Vector2i in (_want_list[k] as Seg).flood.chunks:
			_watch[c] = true
	shown = _want_list
	_last_sig = sig
	_last_fluids = fl
	_last_chunks = _chunks_sig(cursor_chunk)
	# A pipeline finished on chunks that changed while it was found: looked at again next frame.
	for k in range(found_from, _want_list.size()):
		if (_want_list[k] as Seg).flood.stale():
			_last_chunks = []
			break
	last_usec = Time.get_ticks_usec() - t0
	FrameBudget.spent(&"pipelines", last_usec, _roots.size() + (1 if _job != null else 0))


func _in_wide_window(c: Vector2i, cursor_chunk: Vector2i, focus_chunk: Vector2i, radius: int) -> bool:
	return (absi(c.x - cursor_chunk.x) <= radius and absi(c.y - cursor_chunk.y) <= radius) \
		or (absi(c.x - focus_chunk.x) <= radius and absi(c.y - focus_chunk.y) <= radius)


## Each chunk the shown pipelines and the Alt-mode window read, as [instance id, content_rev] (-1 not loaded).
func _chunks_sig(cursor_chunk) -> Array:
	var out: Array = []
	var look := _watch
	if cursor_chunk is Vector2i:
		look = _watch.duplicate()
		var cc: Vector2i = cursor_chunk
		if wide_range:
			var r := maxi(RADIUS, int(world.view_radius))
			var fc := WorldMirror.chunk_of(world.focus())
			for c: Vector2i in world.chunks:
				if _in_wide_window(c, cc, fc, r):
					look[c] = true
		else:
			for dy in range(-RADIUS, RADIUS + 1):
				for dx in range(-RADIUS, RADIUS + 1):
					look[cc + Vector2i(dx, dy)] = true
	for c: Vector2i in look:
		var cv: ChunkView = world.chunks.get(c)
		out.append(cv.get_instance_id() if cv != null else -1)
		out.append(int(cv.content_rev) if cv != null else -1)
	return out


## Finds what is asked for until `deadline`, the hovered pipeline first.
func _find(want: Dictionary, want_list: Array, eprops: Dictionary, deadline: int) -> void:
	var i := 0
	while true:
		if _job == null:
			while i < _roots.size() and _owner.has((_roots[i] as WorldMirror.Rec).key):
				var owned: Seg = _seg_of.get(_owner[(_roots[i] as WorldMirror.Rec).key])
				if owned != null and not want.has(owned):
					want[owned] = true
					want_list.append(owned)
				i += 1
			if i >= _roots.size():
				break
			_job = Flood.new(world, eprops, _roots[i], cap)
			_job.owner = _owner
			i += 1
		if not step(_job, deadline):
			break
		# Found, but too little of the slice left for its mesh (about 50 µs a thousand vertices with letting go of the search, measured headless):
		# made next frame, first (step() returns at once then).
		var verts := _job.jv.size() + _job.uv3.size()
		if not _deferred and verts > 4000 and Time.get_ticks_usec() + verts / 20 > deadline:
			_deferred = true
			break
		_deferred = false
		var seg := _made(_job)
		_job = null
		if not want.has(seg):
			want[seg] = true
			want_list.append(seg)
		if Time.get_ticks_usec() > deadline:
			break
	# What is left for the next frames (those found meanwhile are passed over then).
	_roots = _roots.slice(i)


func _made(f: Flood) -> Seg:
	var s := Seg.new()
	s.flood = f
	s.mesh = MeshInstance3D.new()
	s.mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mesh := ArrayMesh.new()
	for part: Array in [[f.jv, f.juv, f.ji, JOINT_PICTURE, "joint"], [f.uv3, f.uuv, f.ui, UNDER_PICTURE, "under"]]:
		if (part[0] as PackedVector3Array).is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = part[0]
		arrays[Mesh.ARRAY_TEX_UV] = part[1]
		arrays[Mesh.ARRAY_INDEX] = part[2]
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var m := GroundHeight.overlay_material(9, picture(str(part[3]), str(part[4])))
		mesh.surface_set_material(mesh.get_surface_count() - 1, m)
		s.materials.append(m)
	s.mesh.mesh = mesh
	add_child(s.mesh)
	_segs.append(s)
	_seg_of[f] = s
	made_count += 1
	# A pipeline found before that shares entities with this one (connections seen from one side only) goes:
	# its marks would be drawn twice.
	for old in f.displaced:
		var gone: Seg = _seg_of.get(old)
		if gone != null and gone != s:
			_forget(gone)
	_shed(f)
	return s


## Lets go of what only the search needed (about 1-1.5 MB at 4,000 entities), keeping its entities, units
## and the chunks it read: what showing it, its red and its staleness need.
static func _shed(f: Flood) -> void:
	f.queue = []
	f.queued = {}
	f.done_keys = {}
	f.joints = []
	f.unders = []
	f.jv = PackedVector3Array()
	f.juv = PackedVector2Array()
	f.ji = PackedInt32Array()
	f.uv3 = PackedVector3Array()
	f.uuv = PackedVector2Array()
	f.ui = PackedInt32Array()
	f.displaced = {}
	f.prev_owner = {}
	f.head = 0


## A quad centred on `c`, `h` either side, the picture standing on `a` (its top along it), into `f`'s
## joints' or underground runs' arrays.
static func _quad_into(f: Flood, under: bool, c: Vector2, a: Vector2, h: float) -> void:
	var r := Vector2(-a.y, a.x)
	var corners := [c + a * h - r * h, c + a * h + r * h, c - a * h + r * h, c - a * h - r * h]
	var base := f.uv3.size() if under else f.jv.size()
	for i in 4:
		var p: Vector2 = corners[i]
		var v := Vector3(p.x, LIFT, p.y)
		var t := Vector2(1.0 if i == 1 or i == 2 else 0.0, 1.0 if i >= 2 else 0.0)
		if under:
			f.uv3.append(v)
			f.uuv.append(t)
		else:
			f.jv.append(v)
			f.juv.append(t)
	var idx := [base, base + 1, base + 2, base, base + 2, base + 3]
	for k in idx:
		if under:
			f.ui.append(k)
		else:
			f.ji.append(k)


## Factorio's picture from the install, else one drawn here (white, to be tinted).
static func picture(path: String, kind: String) -> Texture2D:
	if _pictures.has(path):
		return _pictures[path]
	var tex := FluidsPowerLayer.core_texture(path)
	if tex == null:
		tex = _drawn(kind)
	_pictures[path] = tex
	return tex


## Without an install: a chevron each way for a joint, two dashed lines for an underground run.
static func _drawn(kind: String) -> Texture2D:
	var n := 32
	var image := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var on_px := false
			var fx := (x + 0.5) / n - 0.5
			var fy := (y + 0.5) / n
			if kind == "under":
				on_px = absf(absf(fx) - 0.34) < 0.06 and fmod(fy * 4.0, 1.0) < 0.55
			else:
				for apex: float in [0.18, 0.82]:
					var dirn := 1.0 if apex < 0.5 else -1.0
					var arm := (fy - apex) * dirn - absf(fx) * 0.9
					on_px = on_px or (absf(arm) < 0.07 and absf(fx) < 0.32 and (fy - apex) * dirn > -0.02)
			image.set_pixel(x, y, Color(1, 1, 1, 1) if on_px else Color(1, 1, 1, 0))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


func _tint(s: Seg, red: bool) -> void:
	var fl: Dictionary = fluids_power.fluids if fluids_power != null else {}
	if not is_same(fl, s.fluids_ref):
		s.fluids_ref = fl
		s.fluid = ""
		# Over the smaller of the two: `fl` holds only what is round the focus, a pipeline may be thousands.
		var keys = fl.keys() if fl.size() < s.flood.units.size() else s.flood.units.keys()
		for u in keys:
			if not s.flood.units.has(u):
				continue
			var boxes = fl.get(u)
			if boxes is Array:
				for b in boxes:
					if b is Dictionary and str(b.get("fluid", "")) != "" and int(b.get("amount", 0)) > 0:
						s.fluid = str(b["fluid"])
						break
			if s.fluid != "":
				break
	var c := OVEREXTENDED if red else EMPTY
	if not red and s.fluid != "":
		c = world.protos.fluid_colors.get(s.fluid, EMPTY)
		c.a = 0.9
	if c != s.color:
		s.color = c
		for m: ShaderMaterial in s.materials:
			m.set_shader_parameter(&"tint", c)


func _window_pipes(at: Vector2) -> Array:
	var c := WorldMirror.chunk_of(at)
	var out: Array = []
	var kept := {}
	var chunks_in_win: Array[Vector2i] = []
	if wide_range:
		var r := maxi(RADIUS, int(world.view_radius))
		var fc := WorldMirror.chunk_of(world.focus())
		for at_c: Vector2i in world.chunks:
			if _in_wide_window(at_c, c, fc, r):
				chunks_in_win.append(at_c)
	else:
		for dy in range(-RADIUS, RADIUS + 1):
			for dx in range(-RADIUS, RADIUS + 1):
				chunks_in_win.append(c + Vector2i(dx, dy))
	for at_c: Vector2i in chunks_in_win:
		var cv: ChunkView = world.chunks.get(at_c)
		if cv == null:
			continue
		var seen: Array = _window.get(at_c, [])
		if seen.is_empty() or int(seen[0]) != cv.get_instance_id() or int(seen[1]) != int(cv.content_rev):
			var pipes: Array = []
			for r: WorldMirror.Rec in cv.entities.values():
				if is_pipe(world, r):
					pipes.append(r)
			seen = [cv.get_instance_id(), cv.content_rev, pipes]
		kept[at_c] = seen
		out.append_array(seen[2])
	_window = kept
	return out


func _drop_stale() -> void:
	for s: Seg in _segs.duplicate():
		if s.flood.stale():
			_forget(s)
	if _job != null and _job.stale():
		_drop_job()


func _forget(s: Seg) -> void:
	_segs.erase(s)
	_seg_of.erase(s.flood)
	_unown(s.flood)
	if is_instance_valid(s.mesh):
		s.mesh.queue_free()


func _drop_job() -> void:
	for r: WorldMirror.Rec in _job.nodes:
		if _owner.get(r.key) == _job:
			var before = _job.prev_owner.get(r.key)
			if before != null and _seg_of.has(before):
				_owner[r.key] = before
			else:
				_owner.erase(r.key)
	_job = null
	_deferred = false


## The `pipeline` alerts changed (ui_model.gd's alerts_changed): their units are worked out again.
func alerts_heard() -> void:
	_alerts_dirty = true


func _unown(f: Flood) -> void:
	for r: WorldMirror.Rec in f.nodes:
		if _owner.get(r.key) == f:
			_owner.erase(r.key)


func _hide_all() -> void:
	for s: Seg in _segs:
		s.mesh.visible = false
