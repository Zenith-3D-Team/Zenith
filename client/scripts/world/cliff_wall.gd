extends RefCounted
## Nauvis's cliffs as one generated wall a chunk (cliff plan step 4; on by default, `--cliff-wall=off`
## or Settings > Graphics > "Cliffs as one wall" off for the pack's pieces).
##
## A Factorio cliff is a chain of entities on a 4x4-tile grid, each running from the middle of one edge of
## its cell to another (model_library.gd CLIFF_PIECES), the high ground on its left. The Placeholders
## pack draws each with one of five pieces and their variants (tools/models/nature/cliffs.py, the fused
## `wall` style); here the same look is generated per cell instead: the shared body (WALL_PROFILE swept
## along the cell's line), blocks of uneven width standing shoulder to shoulder with a ragged top line,
## shorter blocks in front, pale crest stones and a scree apron. Each cell is seeded by its position and
## each joint (the block standing across a cell's edge, and the body's cross-section there) by the edge's
## position, so two neighbours build the same cross-section at their shared edge and weld without either
## knowing the other: nothing walks the chain. The vertices stand `y` tiles over their model's ground as a
## piece's do, and the material's `ground_low` seats them in the terrace (ground_height.gdshaderinc
## ground_lift_cliff: the foot on the low ground, the top row on the high ground).
##
## Built per chunk on a WorkerThreadPool task (chunk_view.gd hands over its cliff cells after each
## build), put in under the frame budget (`cliff_wall`), three levels of detail picked per chunk by the
## distance to its nearest point, one shadow stand-in (the coarsest level, shadow_stand_in's low ground
## material) and, while a far merge stands for the chunk (far_chunks.gd), nothing: the merge draws the
## pack's pieces seated by the same rule. A pack other than Placeholders that draws Nauvis's cliffs wins
## (its pieces as before); other planets' cliffs are their pieces as before.

const FreeLater := preload("res://scripts/world/free_later.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const FrameBudget := preload("res://scripts/world/frame_budget.gd")
const Switches := preload("res://scripts/switches.gd")
const ViewAhead := preload("res://scripts/world/view_ahead.gd")

## The wall instead of the pieces: on by default (the setting, set_on()); `--cliff-wall=off` gives the
## pieces whatever the setting says, `--cliff-wall=on` the wall.
static var arg_on := Switches.has("--cliff-wall=on")
static var arg_off := not Switches.on("--cliff-wall")
static var on := not arg_off

## The prototype the wall draws (Nauvis's cliffs).
const PROTO := "cliff"
## As tools/models/nature/cliffs.py: the tallest rock over its ground, the body's cross-section (offset
## towards the face, height / HEIGHT) from the high side to the scree apron (segments from APRON on), the
## joint block's cross-section and how far it reaches into each cell.
const HEIGHT := 2.5
## The apron reaches 2.6 tiles out, over the whole of Terrain Elevation's low-side ramp (its 2-tile texels
## put the step's slope up to 2.2 tiles either side of the line), its outer edge tucked under the ground.
const PROFILE: Array[Vector2] = [Vector2(-1.5, 0.0), Vector2(-1.0, 0.2), Vector2(-0.55, 0.52), Vector2(-0.25, 0.7),
	Vector2(0.1, 0.72), Vector2(0.4, 0.42), Vector2(0.62, 0.12), Vector2(1.15, 0.04), Vector2(1.85, 0.02),
	Vector2(2.6, 0.0)]
const APRON := 6
## The body's quads from this cross-section point on: the back ones lie under the deck.
const BODY_FROM := 3
## The flat top (deck) behind the face, covering the high side's ramp: its cross-section from a fascia
## under the blocks' caps, the flat top (DECK_Y: the seat grows a vertex by terrace / 2, so 2 tiles over the
## low ground land exactly on a terrace's top when the terrace is 2 tiles or more), to a back lip tucked
## under the high ground (y < 0: ground_lift_cliff_wall puts it 0.1 into the ground). Without a terrace
## the deck is a 2-tile plateau with its back dropping to the ground, as the mock-up.
const DECK_Y := 2.0
const DECK: Array[Vector2] = [Vector2(0.1, 1.2), Vector2(0.03, DECK_Y), Vector2(-0.9, DECK_Y), Vector2(-2.0, DECK_Y),
	Vector2(-2.6, -0.3)]
const JOINT: Array[Vector2] = [Vector2(-0.32, -0.03), Vector2(0.58, -0.03), Vector2(0.34, 0.8), Vector2(0.14, 0.86),
	Vector2(-0.32, 0.82)]
const JOINT_W := 0.3
## The body's rings along a cell at each level (16 divisible by the rest, so the coarser levels' rings
## are the finest level's own and keep its jitter).
const RINGS := [16, 8, 4]
const LEVELS := 3
## Colours from Factorio's sprites (R&D cliff-natural-rd, as cliffs.py's WALL_* materials).
const ROCK := Color("#6a5034")
const SCREE := Color("#7a6040")
const CREST := Color("#a08a68")
## Where each level hands over to the next: tiles from the camera to the wall's nearest point, times the
## Level of detail setting's distance scale (model_lods.gd), with HYSTERESIS tiles either way.
const LEVEL_FROM := [0.0, 40.0, 96.0]
const HYSTERESIS := 4.0
## How worn a block's chamfered front edge is drawn (UV2.x: the material's bright worn edges; 1 read as a
## pale band on every block).
const EDGE_WEAR := 0.3
## Worker jobs at once.
const JOBS := 2
## Edge directions: an orientation's words, and each edge's midpoint from its cell's centre.
const EDGES := {"north": 0, "east": 1, "south": 2, "west": 3, "none": -1}
const EDGE_OFF: Array[Vector2] = [Vector2(0.0, -2.0), Vector2(2.0, 0.0), Vector2(0.0, 2.0), Vector2(-2.0, 0.0)]


## A chunk's wall (chunk_view.gd `wall`).
class State:
	## The cells last asked for (their hash) and the build that goes with them.
	var sig := 0
	var serial := 0
	var cells: Array = []
	## Drawn: a holder under the chunk, a MeshInstance3D a level and the shadow stand-in.
	var holder: Node3D
	var levels: Array[MeshInstance3D] = []
	var shadow: MeshInstance3D
	var level := -1
	var aabb := AABB()
	var triangles := 0


## One chunk's cells built off the main thread: the arrays of each level.
class Job:
	var cv  # chunk_view.gd
	var serial := 0
	var cells: Array = []
	var arrays: Array = []  # per level: Array (Mesh.ARRAY_MAX) or [] when empty
	var triangles := 0
	var usec := 0


## A job's cells built at every level (on a worker).
static func run_job(job: Job) -> void:
	var t0 := Time.get_ticks_usec()
	job.arrays.clear()
	for level in LEVELS:
		var out := Builder.new()
		for c: Array in job.cells:
			build_cell(out, c, level)
		if level == 0:
			job.triangles = out.triangles()
		job.arrays.append(out.arrays())
	job.usec = Time.get_ticks_usec() - t0


static var _queue: Array[Job] = []
static var _running: Array = []  # [task id, Job]
static var _done: Array[Job] = []
static var _drawn := {}  # State -> chunk_view.gd: walls drawn, for levels, shadows and far merges
static var _material: ShaderMaterial
static var _material_src: Material
static var _base: StandardMaterial3D
static var _pack_wins := {}  # piece -> whether a pack other than Placeholders draws it
static var _pack_generation := -1
static var built_cells := 0
static var worker_usec := 0
static var install_usec := 0


## The setting (Settings > Graphics): the wall on when it or `--cliff-wall=on` says. True when it changed.
static func set_on(setting: bool) -> bool:
	var want := (setting or arg_on) and not arg_off
	if want == on:
		return false
	on = want
	return true


## Whether a cliff record (`proto_name`, its `extra.co`) is drawn by the wall: Nauvis's cliffs with a known
## orientation, unless a pack other than Placeholders draws their piece.
static func covers(proto_name: String, extra: Dictionary) -> bool:
	if not on or proto_name != PROTO:
		return false
	var cliff = ModelLibrary.CLIFF_PIECES.get(str(extra.get("co", "")))
	if cliff == null:
		return false
	return not _pack_draws(str(cliff[0]), int(cliff[1]), str(extra["co"]))


static func _pack_draws(piece: String, dir: int, co: String) -> bool:
	if _pack_generation != ModelLibrary.generation:
		_pack_generation = ModelLibrary.generation
		_pack_wins.clear()
	if _pack_wins.has(piece):
		return bool(_pack_wins[piece])
	var from := ModelLibrary.drawing_pack(PROTO, PROTO, {"co": co}, dir)
	if from.is_empty():
		return false  # the packs aren't read yet: the wall (asked again once they are)
	var wins: bool = str(from.get("id", "")) != ModelLibrary.ModelPacks.LAST_ID
	_pack_wins[piece] = wins
	return wins


## A cliff record's cell for build_cell: [its centre (Factorio x, y in tiles), the edge it comes from, the
## edge it goes to (0 north, 1 east, 2 south, 3 west, -1 none), its seed]; [] for an unknown orientation.
static func cell(pos: Vector2, fixed: Vector2i, co: String) -> Array:
	var words := co.split("-to-")
	if words.size() != 2 or not EDGES.has(words[0]) or not EDGES.has(words[1]):
		return []
	var from := int(EDGES[words[0]])
	var to := int(EDGES[words[1]])
	if from == to or (from < 0 and to < 0):
		return []
	return [pos, from, to, seed_of(fixed.x, fixed.y, 1)]


static func seed_of(x: int, y: int, salt: int) -> int:
	var h := (x * 73856093) ^ (y * 19349663) ^ (salt * 83492791)
	h = (h ^ (h >> 13)) * 1274126177
	return (h ^ (h >> 16)) & 0x7fffffffffff


## An edge's seed: its midpoint (half tiles).
static func edge_seed(p: Vector2) -> int:
	return seed_of(roundi(p.x * 2.0), roundi(p.y * 2.0), 2)


# --- The chunk's side: asked for after each build, made on workers, put in under the budget ---------

## chunk_view.gd after reading its records: these cells are the chunk's wall now (none: no wall).
static func want(cv, cells: Array) -> void:
	var st: State = cv.wall
	var sig := hash(cells) if not cells.is_empty() else 0
	if sig == st.sig:
		return
	st.sig = sig
	st.serial += 1
	st.cells = cells
	if cells.is_empty():
		_clear(st)
		return
	var job := Job.new()
	job.cv = cv
	job.serial = st.serial
	job.cells = cells
	_queue.append(job)


static func _clear(st: State) -> void:
	if st.holder != null and is_instance_valid(st.holder):
		FreeLater.node(st.holder)
	st.holder = null
	st.levels.clear()
	st.shadow = null
	st.level = -1
	st.triangles = 0
	_drawn.erase(st)


## Whether a job's chunk still wants it.
static func _current(job: Job) -> bool:
	var cv = job.cv
	return is_instance_valid(cv) and not cv.retired and (cv.wall as State).serial == job.serial


## Each frame (world.gd): starts waiting jobs, puts finished ones in within the budget, and picks every
## drawn wall's level, shadow and whether a far merge stands for it.
static func poll(camera: Camera3D) -> void:
	for i in range(_running.size() - 1, -1, -1):
		var entry: Array = _running[i]
		if WorkerThreadPool.is_task_completed(entry[0]):
			WorkerThreadPool.wait_for_task_completion(entry[0])
			_done.append(entry[1])
			_running.remove_at(i)
	while _running.size() < JOBS and not _queue.is_empty():
		var job: Job = _queue.pop_front()
		if _current(job):
			_running.append([WorkerThreadPool.add_task(run_job.bind(job), false, "cliff wall"), job])
	if not _done.is_empty():
		var started := Time.get_ticks_usec()
		var allow := FrameBudget.grant(&"cliff_wall")
		while not _done.is_empty() and Time.get_ticks_usec() - started < allow:
			var job: Job = _done.pop_front()
			if _current(job):
				_install(job)
		FrameBudget.spent(&"cliff_wall", Time.get_ticks_usec() - started, _done.size() + _queue.size())
	_update(camera)


## Quitting or leaving a game (main.gd _exit_tree): waits for the jobs on workers (a task still running when Godot
## stops its renderer can wait for it for ever); they join the finished ones, put in as usual if still wanted.
static func wait_running() -> void:
	for entry: Array in _running:
		WorkerThreadPool.wait_for_task_completion(entry[0])
		_done.append(entry[1])
	_running.clear()


## Waits for every job and puts them all in (tests, screenshots).
static func finish_all() -> void:
	while not _queue.is_empty() or not _running.is_empty() or not _done.is_empty():
		for entry: Array in _running:
			WorkerThreadPool.wait_for_task_completion(entry[0])
			_done.append(entry[1])
		_running.clear()
		while not _queue.is_empty():
			var job: Job = _queue.pop_front()
			if _current(job):
				run_job(job)
				_done.append(job)
		while not _done.is_empty():
			var job: Job = _done.pop_front()
			if _current(job):
				_install(job)


static func busy() -> bool:
	return not _queue.is_empty() or not _running.is_empty() or not _done.is_empty()


## The wall's material: Factorio's (factorio_material) on the low ground (model_library.gd gives
## `cliff-` materials ground_low), with its colours per vertex (COLOR) and worn edges (UV2), and its own
## seat (`cliff_wall`: ground_lift_cliff_wall, the foot riding over a terrace's ramp).
static func material() -> Material:
	if _base == null:
		_base = StandardMaterial3D.new()
		_base.resource_name = "cliff-rock"
		_base.albedo_color = Color.WHITE
		_base.roughness = 0.95
	var src := ModelLibrary._factorio(_base, true, true, false)
	if src != _material_src or _material == null:
		_material_src = src
		_material = null
		if src is ShaderMaterial:
			_material = (src as ShaderMaterial).duplicate() as ShaderMaterial
			_material.set_shader_parameter("cliff_wall", true)
	return _material if _material != null else src


static func _install(job: Job) -> void:
	var t0 := Time.get_ticks_usec()
	var cv = job.cv
	var st: State = cv.wall
	_clear(st)
	built_cells += job.cells.size()
	worker_usec += job.usec
	st.holder = Node3D.new()
	st.holder.name = "CliffWall"
	var mat := material()
	var box := AABB()
	for level in LEVELS:
		var arrays: Array = job.arrays[level]
		var mi := MeshInstance3D.new()
		mi.visible = false
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if not arrays.is_empty():
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			mi.mesh = mesh
			mi.material_override = mat
			if level == 0:
				box = mesh.get_aabb()
		st.levels.append(mi)
		st.holder.add_child(mi)
	st.shadow = MeshInstance3D.new()
	st.shadow.mesh = st.levels[LEVELS - 1].mesh
	st.shadow.material_override = ModelLods.low_material() if ModelLods.low_stand_ins else ModelLods.material()
	st.shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	st.shadow.visible = false
	st.holder.add_child(st.shadow)
	# Room for the seat's stretch (a terrace of up to 8 tiles grows the rock fourfold) and the hills.
	box = box.grow(0.5)
	box.size.y = maxf(box.size.y, HEIGHT * 4.0)
	st.aabb = box
	if GroundHeight.holding():
		for mi: MeshInstance3D in st.levels:
			if mi.mesh != null:
				GroundHeight.cull_box(mi, box)
		GroundHeight.cull_box(st.shadow, box)
	st.triangles = job.triangles
	st.level = -1
	cv.add_child(st.holder)
	_drawn[st] = cv
	install_usec += Time.get_ticks_usec() - t0


static func _update(camera: Camera3D) -> void:
	if _drawn.is_empty():
		return
	var cam_at := camera.global_position if camera != null else Vector3.INF
	var at := cam_at
	var ahead := ViewAhead.active()
	var scale := maxf(ModelLods.distance_scale, 0.05)
	for st: State in _drawn.keys():
		var cv = _drawn[st]
		if not is_instance_valid(cv) or cv.retired or st.holder == null or not is_instance_valid(st.holder):
			_drawn.erase(st)
			continue
		# A far merge standing for the chunk draws its pieces (far_chunks.gd): the wall hides.
		var shown: bool = not cv.far.covers
		if st.holder.visible != shown:
			st.holder.visible = shown
		if not shown:
			continue
		var level := 0
		if at != Vector3.INF:
			# The nearer of the camera and a viewpoint announced ahead (view_ahead.gd): ready before a cut.
			at = ViewAhead.nearest(cam_at, st.aabb.position, st.aabb.end) if ahead else cam_at
			var near := Vector3(clampf(at.x, st.aabb.position.x, st.aabb.end.x), clampf(at.y, st.aabb.position.y, st.aabb.end.y),
				clampf(at.z, st.aabb.position.z, st.aabb.end.z))
			var d := at.distance_to(near) / scale
			for i in range(LEVELS - 1, 0, -1):
				var from: float = LEVEL_FROM[i] + (-HYSTERESIS if st.level >= i else HYSTERESIS)
				if d >= from:
					level = i
					break
		if level != st.level:
			for i in LEVELS:
				st.levels[i].visible = i == level
			st.level = level
		# Shadows (chunk_view.gd's tiers): the stand-in, or the wall itself where stand-ins cast nothing.
		var tier: int = cv.shadow_tier
		var stand_ins: bool = not cv._no_stand_ins
		var cast_any := tier != 0
		var stand := cast_any and stand_ins
		if st.shadow.visible != stand:
			st.shadow.visible = stand
		var own := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_any and not stand_ins else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mi := st.levels[level]
		if mi.cast_shadow != own:
			mi.cast_shadow = own


## Walls drawn and their triangles (debug).
static func census() -> Dictionary:
	var tris := 0
	for st: State in _drawn:
		tris += st.triangles
	return {"chunks": _drawn.size(), "triangles": tris, "cells": built_cells, "worker_ms": worker_usec / 1000.0,
		"install_ms": install_usec / 1000.0}


# --- One cell's geometry -------------------------------------------------------------------------

## A cell's line: from the middle of one edge to another (straight across, or a quarter circle round the
## corner the two edges share), or dying out in the middle (`none`). Factorio's x east, y south, in tiles.
class CellPath:
	var kind := 0  # 0 straight, 1 corner, 2 exit (dies at its end), 3 entrance (starts dying)
	var a := Vector2.ZERO
	var d := Vector2.ZERO
	var corner := Vector2.ZERO
	var a0 := 0.0
	var sweep := 0.0
	var length := 4.0
	var joint_start := true
	var joint_end := true
	var start_edge := Vector2.ZERO
	var end_edge := Vector2.ZERO

	func _init(centre: Vector2, from: int, to: int) -> void:
		if from >= 0:
			start_edge = centre + EDGE_OFF[from]
		if to >= 0:
			end_edge = centre + EDGE_OFF[to]
		if from < 0:  # entrance: from a tile behind the centre to the edge
			kind = 3
			d = EDGE_OFF[to] / 2.0
			a = centre - d
			length = 3.0
			joint_start = false
		elif to < 0:  # exit: from the edge 3 tiles towards the other side
			kind = 2
			d = -EDGE_OFF[from] / 2.0
			a = start_edge
			length = 3.0
			joint_end = false
		elif (from + 2) % 4 == to:
			kind = 0
			a = start_edge
			d = (end_edge - start_edge) / 4.0
			length = 4.0
		else:
			kind = 1
			corner = centre + EDGE_OFF[from] + EDGE_OFF[to]
			var v0 := start_edge - corner
			var v1 := end_edge - corner
			a0 = atan2(v0.y, v0.x)
			sweep = wrapf(atan2(v1.y, v1.x) - a0, -PI, PI)
			length = PI

	func point(t: float) -> Vector2:
		if kind == 1:
			var ang := a0 + sweep * t
			return corner + 2.0 * Vector2(cos(ang), sin(ang))
		return a + d * (length * t)

	func tangent(t: float) -> Vector2:
		if kind == 1:
			var ang := a0 + sweep * t
			return Vector2(-sin(ang), cos(ang)) * signf(sweep)
		return d

	## How much of the cliff stands here (an exit's and an entrance's open end die away).
	func scale(t: float) -> float:
		if kind == 2:
			return 1.0 - CellPath.smooth(0.35, 1.0, t)
		if kind == 3:
			return CellPath.smooth(0.0, 0.65, t)
		return 1.0

	static func smooth(a0: float, b: float, x: float) -> float:
		var t := clampf((x - a0) / (b - a0), 0.0, 1.0)
		return t * t * (3.0 - 2.0 * t)

	## Godot's point `r` tiles to the right of the line (towards the face, the low ground) at height z.
	func frame(t: float, r: float, z: float) -> Vector3:
		var tg := tangent(t)
		var p := point(t) + Vector2(-tg.y, tg.x) * r
		return Vector3(p.x, z, p.y)

	func right(t: float) -> Vector2:
		var tg := tangent(t)
		return Vector2(-tg.y, tg.x)


static func smooth(a: float, b: float, x: float) -> float:
	return CellPath.smooth(a, b, x)


## Triangles gathered for one level of a chunk: flat-shaded, coloured per vertex.
class Builder:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uv2 := PackedVector2Array()

	func triangles() -> int:
		return verts.size() / 3

	## One triangle facing `hint`'s way, in `color` (linear) lit by the sprites' shade, `edge` its worn
	## edge (UV2.x) and `part` (UV2.y) its random.
	func tri(p0: Vector3, p1: Vector3, p2: Vector3, hint: Vector3, color: Color, edge: float, part: float) -> void:
		var n := (p2 - p0).cross(p1 - p0)
		if n.length_squared() < 1e-12:
			return
		if n.dot(hint) < 0.0:
			var t := p1
			p1 = p2
			p2 = t
			n = -n
		n = n.normalized()
		for p: Vector3 in [p0, p1, p2]:
			verts.append(p)
			normals.append(n)
			# Dark at the base and in the joints, lit towards the top (cliffs.py wall_shade).
			var h := clampf(p.y / HEIGHT, 0.0, 1.0)
			var lit := 0.32 + 0.68 * minf(1.0, 0.18 + 0.5 * h + 0.4 * maxf(0.0, n.y))
			colors.append(Color(color.r * lit, color.g * lit, color.b * lit, 1.0))
			uv2.append(Vector2(edge, part))

	func quad(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, hint: Vector3, color: Color, edge := 0.0, part := 0.5) -> void:
		tri(p0, p1, p2, hint, color, edge, part)
		tri(p0, p2, p3, hint, color, edge, part)

	## A convex polygon, as a fan.
	func poly(ps: Array, hint: Vector3, color: Color, edge := 0.0, part := 0.5) -> void:
		for k in range(1, ps.size() - 1):
			tri(ps[0], ps[k], ps[k + 1], hint, color, edge, part)

	func arrays() -> Array:
		if verts.is_empty():
			return []
		var out := []
		out.resize(Mesh.ARRAY_MAX)
		out[Mesh.ARRAY_VERTEX] = verts
		out[Mesh.ARRAY_NORMAL] = normals
		out[Mesh.ARRAY_COLOR] = colors
		out[Mesh.ARRAY_TEX_UV2] = uv2
		return out


## One cell's wall at `level` (0 finest) into `out`. Deterministic by the cell's position and its edges'.
static func build_cell(out: Builder, c: Array, level: int) -> void:
	var path := CellPath.new(c[0], int(c[1]), int(c[2]))
	var cell_seed := int(c[3])
	var rock := ROCK.srgb_to_linear()
	var scree := SCREE.srgb_to_linear()
	var crest := CREST.srgb_to_linear()
	_body(out, path, cell_seed, level, rock, scree)
	_deck(out, path, cell_seed, level, rock)
	if path.joint_start:
		_joint(out, path, true, rock)
	if path.joint_end:
		_joint(out, path, false, rock)
	_blocks(out, path, cell_seed, rock, level)
	if level <= 1:
		_front_blocks(out, path, cell_seed, rock)
		_crest_stones(out, path, cell_seed, crest)
	if level == 0:
		_scree_stones(out, path, cell_seed, scree)


static func _rng(s0: int, salt: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_of(s0 & 0xffffff, s0 >> 24, salt)
	return rng


## An edge's jitter of the body's cross-section (the same from both cells that share it).
static func _edge_jitter(p: Vector2) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = edge_seed(p)
	var out := PackedFloat32Array()
	for k in PROFILE.size():
		out.append(0.0 if PROFILE[k].y == 0.0 else rng.randf_range(-0.1, 0.1))
	return out


## The body: PROFILE swept along the line, its cross-section jittered by the cell inside and by the
## shared edge at each joint.
static func _body(out: Builder, path: CellPath, cell_seed: int, level: int, rock: Color, scree: Color) -> void:
	var fine: int = RINGS[0]
	var n: int = RINGS[level]
	var every := fine / n
	var rng := _rng(cell_seed, 3)
	var inner: Array[PackedFloat32Array] = []
	for i in fine + 1:
		var row := PackedFloat32Array()
		for k in PROFILE.size():
			row.append(0.0 if PROFILE[k].y == 0.0 else rng.randf_range(-0.1, 0.1))
		inner.append(row)
	var at_start := _edge_jitter(path.start_edge) if path.joint_start else PackedFloat32Array()
	var at_end := _edge_jitter(path.end_edge) if path.joint_end else PackedFloat32Array()
	var rings: Array[PackedVector3Array] = []
	for i in range(0, fine + 1, every):
		var t := float(i) / fine
		var s := path.scale(t)
		var reach := 0.35 + 0.65 * s
		var e0 := (1.0 - smooth(0.0, 0.12, t)) if path.joint_start else 0.0
		var e1 := (1.0 - smooth(0.0, 0.12, 1.0 - t)) if path.joint_end else 0.0
		var ring := PackedVector3Array()
		for k in PROFILE.size():
			var w: float = inner[i][k] * maxf(0.0, 1.0 - e0 - e1)
			if e0 > 0.0:
				w += at_start[k] * e0
			if e1 > 0.0:
				w += at_end[k] * e1
			var h := PROFILE[k].y
			var z := maxf(0.0, h * HEIGHT * s * (1.0 + w)) - (0.06 if h == 0.0 else 0.0)
			ring.append(path.frame(t, PROFILE[k].x * reach + w, z))
		rings.append(ring)
	for j in rings.size() - 1:
		var t := (float(j) + 0.5) / (rings.size() - 1)
		var right := path.right(t)
		for k in range(BODY_FROM, PROFILE.size() - 1):
			var dr := PROFILE[k + 1].x - PROFILE[k].x
			var dz := PROFILE[k + 1].y - PROFILE[k].y
			var hint := Vector3(right.x * -dz, dr, right.y * -dz)
			out.quad(rings[j][k], rings[j][k + 1], rings[j + 1][k + 1], rings[j + 1][k], hint, scree if k >= APRON else rock, 0.0, 0.85)


## The deck: DECK swept along the line, the same at every cell's edge (no jitter there) so neighbours
## weld; inside the cell its middle row rises and falls a little. Round an inner corner its back rows
## fold past the corner's centre: they lie in the deck's plane or under the high ground.
static func _deck(out: Builder, path: CellPath, cell_seed: int, level: int, rock: Color) -> void:
	var fine: int = RINGS[0]
	var n: int = RINGS[level]
	var every := fine / n
	var rng := _rng(cell_seed, 8)
	var bumps := PackedFloat32Array()
	for i in fine + 1:
		bumps.append(rng.randf_range(-0.06, 0.1))
	var rings: Array[PackedVector3Array] = []
	for i in range(0, fine + 1, every):
		var t := float(i) / fine
		var s := path.scale(t)
		var reach := 0.35 + 0.65 * s
		var mid := 1.0 - absf(2.0 * t - 1.0)
		var ring := PackedVector3Array()
		for k in DECK.size():
			var y := DECK[k].y
			var z := y if y < 0.0 else y * s
			if k == 2:
				z += bumps[i] * smooth(0.0, 0.3, mid) * s
			ring.append(path.frame(t, DECK[k].x * reach, z))
		rings.append(ring)
	var top := rock * 1.08
	for j in rings.size() - 1:
		var t := (float(j) + 0.5) / (rings.size() - 1)
		var right := path.right(t)
		for k in DECK.size() - 1:
			# The fascia faces the low side, the top up, the lip back over the high ground.
			var hint := Vector3.UP
			if k == 0:
				hint = Vector3(right.x, 0.2, right.y)
			elif k == DECK.size() - 2:
				hint = Vector3(-right.x, 1.0, -right.y)
			out.quad(rings[j][k], rings[j][k + 1], rings[j + 1][k + 1], rings[j + 1][k], hint, rock if k == 0 else top, 0.0, 0.7)


## Half the joint block at one end, cut by the cell's edge: its size and lean from the edge's seed.
static func _joint(out: Builder, path: CellPath, at_start: bool, rock: Color) -> void:
	var t := 0.0 if at_start else 1.0
	var edge := path.start_edge if at_start else path.end_edge
	var rng := RandomNumberGenerator.new()
	rng.seed = edge_seed(edge) ^ 0x5a5a
	var tall := rng.randf_range(0.86, 1.06)
	var lean := rng.randf_range(-0.08, 0.08)
	var tangent := path.tangent(t)
	var right := path.right(t)
	var p := path.point(t)
	var inward := JOINT_W if at_start else -JOINT_W
	var rows: Array[PackedVector3Array] = []
	for along: float in [0.0, inward]:
		var q := p + tangent * along
		var row := PackedVector3Array()
		for k in JOINT.size():
			var r := JOINT[k].x + (lean * JOINT[k].y)
			var q2 := q + right * r
			var h := JOINT[k].y
			row.append(Vector3(q2.x, h * HEIGHT * tall if h > 0.0 else h, q2.y))
		rows.append(row)
	var centre := Vector3.ZERO
	for v in rows[0] + rows[1]:
		centre += v
	centre /= float(JOINT.size() * 2)
	var a := rows[0]
	var b := rows[1]
	var n := JOINT.size()
	var part := float(edge_seed(edge) % 1000) / 1000.0
	for k in n:
		var mid := (a[k] + a[(k + 1) % n] + b[k] + b[(k + 1) % n]) / 4.0
		out.quad(a[k], a[(k + 1) % n], b[(k + 1) % n], b[k], mid - centre, rock * 0.92, 0.0, part)
	var t3 := Vector3(tangent.x, 0.0, tangent.y) * (1.0 if at_start else -1.0)
	out.poly(Array(a), -t3, rock * 0.92, 0.0, part)
	out.poly(Array(b), t3, rock * 0.92, 0.0, part)


## One upright block from `a` to `b` tiles along the line (cliffs.py block): a flat front leaning back,
## a vertical crease, a chamfered front edge, a cap tipped a little or peaked.
static func _block(out: Builder, path: CellPath, a: float, b: float, r_back: float, r_front: float, lean: float, h: float,
		rng: RandomNumberGenerator, color: Color) -> void:
	var L := path.length
	var ins := rng.randf_range(0.0, 0.05) * (b - a)
	var mid := (a + b) / 2.0 + rng.randf_range(-0.15, 0.15) * (b - a)
	var bulge := rng.randf_range(0.0, 0.09)
	var cham := rng.randf_range(0.05, 0.16)
	var yaw := rng.randf_range(-0.07, 0.07)
	var hl := h * rng.randf_range(0.86, 1.08)
	var hr := h * rng.randf_range(0.86, 1.08)
	var hb := rng.randf_range(0.92, 1.02)
	var hm := maxf(hl, hr) * rng.randf_range(1.0, 1.06) if rng.randf() < 0.5 else (hl + hr) / 2.0
	var tint := rng.randf_range(0.82, 1.05)
	var part := rng.randf()
	var at := func(s: float, r: float, z: float) -> Vector3:
		return path.frame(clampf(s / L, 0.0, 1.0), r, z)
	var fronts := [r_front - yaw, r_front + bulge, r_front + yaw]
	var heights := [hl, hm, hr]
	var alongs_base := [a, mid, b]
	var alongs_top := [a + ins, mid, b - ins]
	var base_f: Array[Vector3] = []
	var top_f: Array[Vector3] = []
	var cap_f: Array[Vector3] = []
	for k in 3:
		base_f.append(at.call(alongs_base[k], fronts[k], -0.06))
		top_f.append(at.call(alongs_top[k], fronts[k] - lean, float(heights[k]) - cham))
		cap_f.append(at.call(alongs_top[k], fronts[k] - lean - cham * 0.8, heights[k]))
	var base_b: Array[Vector3] = [at.call(a, r_back, -0.06), at.call(b, r_back, -0.06)]
	var top_b: Array[Vector3] = [at.call(a + ins, r_back, hl * hb), at.call(b - ins, r_back, hr * hb)]
	var centre := Vector3.ZERO
	for v in base_f + top_f + base_b + top_b:
		centre += v
	centre /= 10.0
	var c := color * tint
	for k in 2:
		out.quad(base_f[k], base_f[k + 1], top_f[k + 1], top_f[k], (base_f[k] + top_f[k + 1]) / 2.0 - centre, c, 0.0, part)
		out.quad(top_f[k], top_f[k + 1], cap_f[k + 1], cap_f[k], (top_f[k] + cap_f[k + 1]) / 2.0 - centre, c, EDGE_WEAR, part)
	var cap := [cap_f[0], cap_f[1], cap_f[2], top_b[1], top_b[0]]
	out.poly(cap, Vector3.UP, c, 0.0, part)
	out.quad(base_b[0], base_b[1], top_b[1], top_b[0], (base_b[0] + top_b[1]) / 2.0 - centre, c, 0.0, part)
	out.poly([base_b[0], base_f[0], top_f[0], cap_f[0], top_b[0]], (base_b[0] + base_f[0] + top_b[0]) / 3.0 - centre, c, 0.0, part)
	out.poly([base_f[2], base_b[1], top_b[1], cap_f[2], top_f[2]], (base_b[1] + base_f[2] + top_b[1]) / 3.0 - centre, c, 0.0, part)


## The face: blocks shoulder to shoulder between the joints, a top line from two slow waves, per-block
## jitter and notches (cliffs.py wall).
static func _blocks(out: Builder, path: CellPath, cell_seed: int, rock: Color, _level: int) -> void:
	var rng := _rng(cell_seed, 4)
	var L := path.length
	var start := JOINT_W if path.joint_start else 0.0
	var end := L - JOINT_W if path.joint_end else L
	var ph1 := rng.randf_range(0.0, TAU)
	var ph2 := rng.randf_range(0.0, TAU)
	var a := start
	while a < end - 0.05:
		var w := 0.3 + 0.7 * pow(rng.randf(), 2.0)
		var b := end if end - (a + w) < 0.3 else a + w
		var tm := (a + b) / 2.0 / L
		var s := path.scale(tm)
		# Every block draws its numbers whether it stands or not, so the rest keep theirs.
		var jit := rng.randf_range(-0.1, 0.1)
		var notch := rng.randf() < 0.25
		var notch_k := rng.randf_range(0.6, 0.76)
		var front_k := rng.randf_range(0.4, 0.66)
		var lean_k := rng.randf_range(0.18, 0.32)
		var brng := RandomNumberGenerator.new()
		brng.seed = rng.randi()
		if s >= 0.12:
			var reach := 0.35 + 0.65 * s
			var slow := 0.86 + 0.08 * sin(TAU * tm * L / 3.1 + ph1) + 0.05 * sin(TAU * tm * L / 1.3 + ph2)
			var h := HEIGHT * s * (slow + jit)
			if notch:
				h *= notch_k
			_block(out, path, a, b, -0.34 * reach, front_k * reach, lean_k * reach, h, brng, rock)
		a = b


## Shorter blocks standing in front of the wall.
static func _front_blocks(out: Builder, path: CellPath, cell_seed: int, rock: Color) -> void:
	var rng := _rng(cell_seed, 5)
	var L := path.length
	var start := JOINT_W if path.joint_start else 0.0
	var end := L - JOINT_W if path.joint_end else L
	var lo := maxf(start, 0.4)
	var hi := minf(end, L - 0.4)
	var n := maxi(1, int(L / 1.3))
	for i in n:
		var w := rng.randf_range(0.3, 0.6)
		var a := lo + (hi - lo - w) * (i + rng.randf_range(0.1, 0.9)) / n
		var front_k := rng.randf_range(0.85, 1.05)
		var lean := rng.randf_range(0.06, 0.14)
		var hk := rng.randf_range(0.22, 0.45)
		var brng := RandomNumberGenerator.new()
		brng.seed = rng.randi()
		var tm := (a + w / 2.0) / L
		var s := path.scale(tm)
		if s < 0.3:
			continue
		var reach := 0.35 + 0.65 * s
		_block(out, path, a, a + w, 0.3 * reach, front_k * reach, lean, HEIGHT * s * hk, brng, rock * 0.8)


## Whether point q stays `margin` tiles inside the edges the cell meets (cliffs.py _inside).
static func _inside(path: CellPath, q: Vector2, margin: float) -> bool:
	if path.joint_start and (q - path.point(0.0)).dot(path.tangent(0.0)) < margin:
		return false
	if path.joint_end and (q - path.point(1.0)).dot(path.tangent(1.0)) > -margin:
		return false
	return true


## A loose stone: a box with its corners pulled about, squashed by `squash`.
static func _stone(out: Builder, at: Vector3, size: float, squash: Vector3, rng: RandomNumberGenerator, color: Color) -> void:
	var yaw := rng.randf_range(0.0, TAU)
	var basis := Basis(Vector3.UP, yaw)
	var c: Array[Vector3] = []
	for k in 8:
		var v := Vector3(-1.0 if k & 1 == 0 else 1.0, -0.4 if k & 2 == 0 else 1.0, -1.0 if k & 4 == 0 else 1.0)
		v *= Vector3(rng.randf_range(0.6, 1.0), rng.randf_range(0.6, 1.0), rng.randf_range(0.6, 1.0))
		c.append(at + basis * (v * squash * size))
	var tint := rng.randf_range(0.85, 1.08)
	var col := color * tint
	var part := rng.randf()
	# (bit 0: x, bit 1: y, bit 2: z) faces as corner lists
	for f: Array in [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]:
		var mid := (c[f[0]] + c[f[1]] + c[f[2]] + c[f[3]]) / 4.0
		out.quad(c[f[0]], c[f[1]], c[f[2]], c[f[3]], mid - at, col, 0.0, part)


## Pale boulders along the crest.
static func _crest_stones(out: Builder, path: CellPath, cell_seed: int, crest: Color) -> void:
	var rng := _rng(cell_seed, 6)
	var L := path.length
	var n := maxi(2, int(L / 0.85))
	for i in n:
		var tm := (0.35 + (L - 0.7) * (i + rng.randf_range(0.15, 0.85)) / n) / L
		var rk := rng.randf_range(-1.5, -0.35)
		var size_k := rng.randf_range(0.15, 0.24)
		var srng := RandomNumberGenerator.new()
		srng.seed = rng.randi()
		var s := path.scale(tm)
		if s < 0.3:
			continue
		var r := rk * (0.35 + 0.65 * s)
		var size := size_k * s
		var at := path.frame(tm, r, DECK_Y * s)
		if _inside(path, Vector2(at.x, at.z), size * 1.6 + 0.05):
			_stone(out, at, size, Vector3(1.2, 0.75, 1.0), srng, crest)


## Scree on the apron.
static func _scree_stones(out: Builder, path: CellPath, cell_seed: int, scree: Color) -> void:
	var rng := _rng(cell_seed, 7)
	var L := path.length
	var n := maxi(3, int(L * 2.2))
	for i in n:
		var tm := (0.3 + (L - 0.6) * (i + rng.randf()) / n) / L
		var rk := rng.randf_range(1.0, 2.2)
		var size := rng.randf_range(0.06, 0.15)
		var srng := RandomNumberGenerator.new()
		srng.seed = rng.randi()
		var s := path.scale(tm)
		if s < 0.2:
			continue
		var at := path.frame(tm, rk * (0.35 + 0.65 * s), 0.06)
		if _inside(path, Vector2(at.x, at.z), size * 1.6 + 0.05):
			_stone(out, at, size, Vector3(1.2, 0.65, 1.0), srng, scree)
