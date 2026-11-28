extends RefCounted
## The ground's height under the flat Factorio world, drawn only (Factorio itself stays flat).
##
## Off by default: everything sits at y = 0 as before. Something (the Terrain Elevation add-on,
## through api.terrain) gives a height field, a grid of heights in tiles over a square of the
## map; then every shader that draws the world lifts its vertices by the height under them
## (shaders/ground_height.gdshaderinc), and the few things placed on the CPU (the mouse's ground
## point, the camera's focus) ask `at()`. Both read the same grid the same way (bilinear between
## texel centres, 0 outside the square), so a building, the belt beside it and the ground under
## both agree.
##
## Static: one field for the whole client, set on the main thread.

const Switches := preload("res://scripts/switches.gd")

const GLOBAL_TEX := &"f3d_ground"
const GLOBAL_RECT := &"f3d_ground_rect"
const GLOBAL_ON := &"f3d_ground_on"
const GLOBAL_PREV := &"f3d_ground_prev"
const GLOBAL_PREV_RECT := &"f3d_ground_prev_rect"
const GLOBAL_MIX := &"f3d_ground_mix"
const GLOBAL_CLIFF_FIT := &"f3d_cliff_fit"
const GLOBAL_CLIFF_TINT := &"f3d_cliff_tint"
const GLOBAL_CLIFF_NORMAL := &"f3d_cliff_normal"
## How much the ground near a cliff turns to its scree's colour, at the most (terrain_common.gdshaderinc).
const CLIFF_TINT := 0.55
## Where a cliff's terrace is looked for round a point (terrace_near): 8 points this far out, in tiles.
const CLIFF_TAP_REACH := 3.0
## Longest fade an image's `fade_in` meta may ask for (seconds).
const FADE_MAX := 3.0
## How far a fade comes between version()'s steps.
const FADE_VERSION_STEP := 0.2
## How far the hills may lift something while a new field's heights are still being measured (the
## first field only: later ones keep the last field's range until theirs is known), in tiles.
const REACH := 48.0
## The lift's range is rounded out to this (tiles), so a field moved with the character, its hills
## a little taller or lower, doesn't set every node's bounds again.
const RANGE_STEP := 0.5
## Giving every node room walks all of them on the main thread: 6-13 ms for the mock's 3,200 at a
## small base. Room that grows is given at once (nothing lifted may be culled meanwhile); a range
## that shrinks by up to SHRINK_SLACK tiles keeps the room it has (hills a little lower where the
## field moved to, then a little taller again, walk nothing), and room that shrinks by more is
## taken back WALK_USEC of the main thread a frame. Flat again (clear) is at once.
const SHRINK_SLACK := 1.0
const WALK_USEC := 1000
## Fields up to this many texels are measured at once; bigger ones on a worker thread (768 x 768
## texels of two channels take about 17 ms).
const MEASURE_NOW := 256 * 256
const META_FLAT := &"f3d_flat_aabb"  # a node's bounds without the hills (cull_box)
const META_MARGIN := &"f3d_hill_margin"  # the margin set here, to tell it from the node's own
const META_OWN := &"f3d_own_margin"  # the node's own margin under it
## Render priority for ground-level area showcases: over flat decoratives (-128..-33), under
## raised grass (-31..-2), contact shadows (-1), building glass (0) and ghosts (1..2).
const AREA_PRIORITY := -32

static var _image: Image
static var _texture: ImageTexture
static var _origin := Vector2.ZERO  # world x, z of the grid's first texel's corner
static var _step := 1.0  # tiles per texel
static var _size := Vector2i.ZERO
static var _on := false
## The lift the field gives anything, lowest and highest (tiles, rounded out to RANGE_STEP; 0
## included, since past the field nothing is lifted): what the nodes' bounds have room for. Zero
## while flat.
static var _lo := 0.0
static var _hi := 0.0
static var _watching := false
static var _on_added := Callable()
## Measurings on worker threads: [task id, [lowest, highest] the worker writes, field number]. Never
## waited for unfinished: the main thread waiting for one (each new field waited for the last) sat
## behind every low-priority job queued before it, for as long as those took or for ever. Each is
## taken once done (_poll); only the latest field's range is used.
static var _tasks: Array = []
static var _field := 0  # numbers the fields set, so an older field's measuring is only tidied up
static var _measured_field := -1  # the number of the latest field set and measured on a worker
static var _polling := false
## Nodes still to be given the range's room, from _walk_at on (a shrink, a slice a frame).
static var _walk: Array = []
static var _walk_at := 0
## A new field fading in over the one before it (an image's `fade_in` meta, seconds): the field
## before it (null image: flat ground before it), when the fade began and how long it lasts, and
## how far it has come (1: the new field alone). Shaders mix the two the same way (the include's
## f3d_ground_mix), and so does at(). version() moves on a few times during a fade.
static var _prev_image: Image
static var _prev_texture: ImageTexture
static var _prev_origin := Vector2.ZERO
static var _prev_step := 0.0
static var _prev_size := Vector2i.ZERO
static var _mix := 1.0
static var _fade_from := 0
static var _fade_usec := 0
static var _fading := false
static var _fade_ver_mix := 0.0  # the mix when version() last moved on during the fade
## While fading, the lift range the nodes keep room for besides the new field's (the old field's),
## and the new field's own, used alone once the fade ends.
static var _keep_range := Vector2.ZERO
static var _want_range := Vector2.ZERO
## The main thread's time a frame for that walk (µs); tests set 0 (64 nodes a frame).
static var walk_usec := WALK_USEC
## A growing range's walk, a slice a frame (µs; the owner's spike log: 39 ms in one frame of a field
## from Terrain Elevation, the whole tree searched and every node given room at once, and a 60 ms draw
## after it from every instance's new bounds). Nodes not reached yet may be culled at the screen's edge
## for a few frames. --ground-walk=old: the whole tree searched again and every node given room in the
## frame the range grows, as before.
static var walk_old := Switches.has("--ground-walk=old")
const GROW_USEC := 3000
## The drawn nodes known (found once when the hills come, then each added one): walked in place of
## searching the whole tree each time the range moves. Freed ones dropped as a walk passes them.
static var _known: Array = []
static var _growing := false  # the walk running gives room for a grown range (a bigger slice)
## Cliffs seated in their terrace (cliff_seat; shaders' ground_lift_cliff). --cliff-fit=off: the rock on
## the low ground at its own height, as before.
static var cliff_fit := Switches.on("--cliff-fit")
## The ground near a cliff tinted towards its scree (a field's third channel). --cliff-ground-tint=off.
static var cliff_tint := Switches.on("--cliff-ground-tint")
## That tint as ragged scree, patchy at its edge and varied between the sprites' scree colours; with
## `--cliff-scree-look=old` the even band as before (the global's sign: negative, the old band).
static var cliff_scree_ragged := not (Switches.has("--cliff-scree-look=old"))
## The ground's shading normal (the shaders' ground_n) with the terraces' slope read where it is, not
## across the field's 2-tile texels: the flat ground in front of a cliff no longer shaded as a 33-degree
## slope (and bare of decoratives, which fade out on steep ground) a tile or two out from the rock.
## --cliff-ground-normal=old: as before.
static var cliff_normal := not (Switches.has("--cliff-ground-normal=old"))
## Each field's texture set into the shaders' globals once and then updated in place, a fade
## copying the field shown into the faded-from texture: setting a global texture again makes
## Godot update every material that reads it (the ground, every model lifted by the hills) on
## the render thread, and a fade swapped both, every time Terrain Elevation sent a field (each
## building or cliff it read). --ground-swap=old: the textures swapped as before.
static var swap_old := Switches.has("--ground-swap=old")


## Sets the field: `heights` an Image of FORMAT_RF (heights in tiles), FORMAT_RGF (red the
## ground, green the ground without its cliffs' terraces: what cliff models sit on) or FORMAT_RGBF
## (and blue how near a cliff, 0-1: the ground's tint there), its first
## texel's corner at `origin` (world x, z), `tiles_per_texel` tiles a texel. Replaces any field
## before it. An image may carry its own lowest and highest height as the meta `lift_range` (a
## Vector2, tiles): then it isn't measured (_measure), as the add-on that made it knows them.
static func set_field(heights: Image, origin: Vector2, tiles_per_texel: float) -> void:
	if heights == null or heights.is_empty():
		clear()
		return
	var given: Variant = heights.get_meta(&"lift_range") if heights.has_meta(&"lift_range") else null
	var fade: float = float(heights.get_meta(&"fade_in", 0.0)) if heights.has_meta(&"fade_in") else 0.0
	fade = clampf(fade, 0.0, FADE_MAX) if is_finite(fade) else 0.0
	var format := heights.get_format()
	if format != Image.FORMAT_RF and format != Image.FORMAT_RGF and format != Image.FORMAT_RGBF:
		heights = heights.duplicate()
		heights.convert(Image.FORMAT_RF)
	var low_ground := _has_low(heights)
	var size := Vector2i(heights.get_width(), heights.get_height())
	if fade > 0.0:
		_begin_fade(fade)
	elif _fading:
		_end_fade()
	var reused := (_texture != null and _texture.get_width() == size.x and _texture.get_height() == size.y
		and _texture.get_format() == heights.get_format())
	if reused:
		_texture.update(heights)
	else:
		_texture = ImageTexture.create_from_image(heights)
	_image = heights
	_size = size
	_origin = origin
	_step = maxf(tiles_per_texel, 0.001)
	_on = true
	if not reused or (fade > 0.0 and swap_old):  # (swap_old: a fade swaps the textures)
		RenderingServer.global_shader_parameter_set(GLOBAL_TEX, _texture)
	RenderingServer.global_shader_parameter_set(GLOBAL_RECT, Vector4(_origin.x, _origin.y, _step, 1.0 if low_ground else 0.0))
	RenderingServer.global_shader_parameter_set(GLOBAL_ON, 1.0)
	apply_cliff_switches()
	_measure(heights, given)


## The cliff switches into the shaders' globals (set_field does it; tests after changing them).
static func apply_cliff_switches() -> void:
	RenderingServer.global_shader_parameter_set(GLOBAL_CLIFF_FIT, 1.0 if cliff_fit else 0.0)
	RenderingServer.global_shader_parameter_set(GLOBAL_CLIFF_TINT, (CLIFF_TINT if cliff_scree_ragged else -CLIFF_TINT) if cliff_tint else 0.0)
	RenderingServer.global_shader_parameter_set(GLOBAL_CLIFF_NORMAL, 1.0 if cliff_normal else 0.0)


## Whether a field's green channel holds the low ground (two or three channels).
static func _has_low(image: Image) -> bool:
	return image.get_format() == Image.FORMAT_RGF or image.get_format() == Image.FORMAT_RGBF


## Back to flat ground.
static func clear() -> void:
	if _fading:
		_end_fade()
	_on = false
	_image = null
	_field += 1  # a measuring still running is for a field gone
	RenderingServer.global_shader_parameter_set(GLOBAL_ON, 0.0)
	_set_range(0.0, 0.0)


# --- fading a new field in --------------------------------------------------------------------

## The field shown now becomes the one faded from (flat ground when none), and the texture it was
## in is kept for the fade; the new field goes into the spare texture (set_field). A fade begun
## while another runs starts from the field coming in (its last few frames skipped).
static func _begin_fade(seconds: float) -> void:
	if _on and _image != null and _texture != null and not swap_old:
		# The field shown now is faded from: copied into the faded-from texture (bound once), the new
		# one updated into the texture shown (set_field), neither global set again.
		if (_prev_texture != null and _prev_texture.get_width() == _image.get_width()
				and _prev_texture.get_height() == _image.get_height() and _prev_texture.get_format() == _image.get_format()):
			_prev_texture.update(_image)
		else:
			_prev_texture = ImageTexture.create_from_image(_image)
			RenderingServer.global_shader_parameter_set(GLOBAL_PREV, _prev_texture)
		_prev_image = _image
		_prev_origin = _origin
		_prev_step = _step
		_prev_size = _size
		RenderingServer.global_shader_parameter_set(GLOBAL_PREV_RECT, Vector4(_prev_origin.x, _prev_origin.y,
			_prev_step, 1.0 if _has_low(_prev_image) else 0.0))
	elif _on and _image != null and _texture != null:
		# The field shown now is faded from; the new one goes into the spare texture (set_field
		# updates it when its size and format fit, else makes a new one).
		var spare := _prev_texture
		_prev_texture = _texture
		_prev_image = _image
		_prev_origin = _origin
		_prev_step = _step
		_prev_size = _size
		_texture = spare
		RenderingServer.global_shader_parameter_set(GLOBAL_PREV, _prev_texture)
		RenderingServer.global_shader_parameter_set(GLOBAL_PREV_RECT, Vector4(_prev_origin.x, _prev_origin.y,
			_prev_step, 1.0 if _has_low(_prev_image) else 0.0))
	else:
		_prev_image = null
		_prev_step = 0.0
		RenderingServer.global_shader_parameter_set(GLOBAL_PREV_RECT, Vector4(0.0, 0.0, 0.0, 0.0))
	_keep_range = Vector2(_lo, _hi)
	_mix = 0.0
	_fade_ver_mix = 0.0
	_fade_from = Time.get_ticks_usec()
	_fade_usec = int(seconds * 1000000.0)
	RenderingServer.global_shader_parameter_set(GLOBAL_MIX, 0.0)
	if not _fading:
		_fading = true
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null and not tree.process_frame.is_connected(_fade_on):
			tree.process_frame.connect(_fade_on)


## Once a frame while fading: how far the new field has come.
static func _fade_on() -> void:
	var t := float(Time.get_ticks_usec() - _fade_from) / float(maxi(_fade_usec, 1))
	if t >= 1.0:
		_end_fade()
		return
	# Eased: starts and ends gently, so nothing seems to jump.
	_mix = t * t * (3.0 - 2.0 * t)
	RenderingServer.global_shader_parameter_set(GLOBAL_MIX, _mix)
	# Heights read under things that stay put (lamps' lights, Alt-mode's icons) are read again
	# every FADE_VERSION_STEP of the fade, not every frame: a few steps, little work.
	if _mix - _fade_ver_mix >= FADE_VERSION_STEP:
		_fade_ver_mix = _mix
		_field += 1


## The fade done (or cut short): the new field alone, room for its range alone.
static func _end_fade() -> void:
	_fading = false
	_mix = 1.0
	_prev_image = null
	_prev_step = 0.0
	RenderingServer.global_shader_parameter_set(GLOBAL_MIX, 1.0)
	RenderingServer.global_shader_parameter_set(GLOBAL_PREV_RECT, Vector4(0.0, 0.0, 0.0, 0.0))
	_field += 1
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.process_frame.is_connected(_fade_on):
		tree.process_frame.disconnect(_fade_on)
	if _on:
		_set_range(_want_range.x, _want_range.y)


## Whether a new field is fading in now (tests).
static func fading() -> bool:
	return _fading


## A field's range for the nodes' room: while fading, the old field's kept too.
static func _use_range(lo: float, hi: float) -> void:
	_want_range = Vector2(lo, hi)
	if _fading:
		_set_range(minf(lo, _keep_range.x), maxf(hi, _keep_range.y))
	else:
		_set_range(lo, hi)


# --- culling ------------------------------------------------------------------------------------
# Godot culls each node by its flat bounds and can't see a lift done in a shader, so ground and
# buildings the hills raise into view were left out along the screen's edges. The hills only move
# things up and down, and by no more than the field's own range: a node's bounds grow by that, in
# height alone where its bounds are known (cull_box), else by a margin that size. Nothing grows
# while the ground is flat. (A 48-tile margin on everything, as before, cost ten times the draw
# calls and two to three times the frame: the view and the sun's shadow passes culled almost
# nothing nearby, and models kept their finest level of detail further out.) The shadow passes
# cull by the same bounds.

## The lift's range the nodes have room for: Vector2(lowest, highest) in tiles, (0, 0) while flat.
static func lift_range() -> Vector2:
	return Vector2(_lo, _hi)


## The margin a node without bounds of its own gets: as far as the hills move anything. 0 while flat.
static func cull_margin() -> float:
	return maxf(_hi, -_lo)


## `box` (in a node's own space, the node neither tilted nor scaled in height) grown in height by
## what the hills can lift it; the same box while flat.
static func grow(box: AABB) -> AABB:
	if _lo == 0.0 and _hi == 0.0:
		return box
	return AABB(box.position + Vector3(0.0, _lo, 0.0), box.size + Vector3(0.0, _hi - _lo, 0.0))


## Sets a node's culling bounds (`custom_aabb`) to `flat`, grown in height by the hills while there
## are any and kept so as they change: for nodes whose bounds are known (a chunk's MultiMeshes), in
## place of the margin, which grows them every way. A node given bounds here gets them only here.
## An empty `flat` gives the node its own bounds back (and the margin).
static func cull_box(node: GeometryInstance3D, flat: AABB) -> void:
	if flat.size == Vector3.ZERO:
		if not node.has_meta(META_FLAT):
			return
		node.remove_meta(META_FLAT)
		node.custom_aabb = AABB()
		if _watching:
			_set_margin(node, cull_margin())
		return
	node.set_meta(META_FLAT, flat)
	_set_margin(node, 0.0)
	node.custom_aabb = grow(flat)


## Whether the nodes have room for hills now: callers with bounds of their own give them through
## cull_box while this holds (and an empty box once it doesn't).
static func holding() -> bool:
	return _watching


## A MeshInstance3D's bounds from its mesh, grown by the hills (cull_box); its own again while flat.
## Called when its mesh changes.
static func hold_mesh(node: MeshInstance3D) -> void:
	if holding() and node.mesh != null:
		cull_box(node, node.mesh.get_aabb())
	else:
		cull_box(node, AABB())


## Rounds the range out and, when that changed, gives every drawn node room for it: those made
## already and, while there are hills, those to come. Room that grows at once, room that shrinks
## (past SHRINK_SLACK) a slice a frame.
static func _set_range(lo: float, hi: float) -> void:
	lo = floorf(minf(lo, 0.0) / RANGE_STEP) * RANGE_STEP
	hi = ceilf(maxf(hi, 0.0) / RANGE_STEP) * RANGE_STEP
	var grows := lo < _lo or hi > _hi
	var flat := lo == 0.0 and hi == 0.0
	if not grows and not flat:
		if lo - _lo <= SHRINK_SLACK:
			lo = _lo
		if _hi - hi <= SHRINK_SLACK:
			hi = _hi
	if lo == _lo and hi == _hi:
		return
	_lo = lo
	_hi = hi
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var on := lo != 0.0 or hi != 0.0
	var turned_on := false
	if on != _watching:
		_watching = on
		if on:
			turned_on = true
			_on_added = _hold_new
			tree.node_added.connect(_on_added)
		else:
			tree.node_added.disconnect(_on_added)
	if walk_old or turned_on or flat:
		_walk = tree.root.find_children("*", "GeometryInstance3D", true, false)
		_known = []
	else:
		# The nodes known, and those the last walk hadn't reached yet.
		var rest: Array = _walk.slice(_walk_at) if _walk_at < _walk.size() else []
		_walk = _known
		_walk.append_array(rest)
		_known = []
	_walk_at = 0
	_growing = grows
	if walk_old:
		_walk_step(grows or flat)
	else:
		_walk_step(flat, GROW_USEC if grows else walk_usec)
	if _walk_at < _walk.size() and not tree.process_frame.is_connected(_walk_on):
		tree.process_frame.connect(_walk_on)


## Gives the walk's nodes room for the range, all of them (`all`) or `budget` µs' worth (walk_usec).
static func _walk_step(all: bool, budget := -1) -> void:
	if budget < 0:
		budget = walk_usec
	var t0 := Time.get_ticks_usec()
	var n := _walk.size()
	var keep := _watching and not walk_old
	while _walk_at < n:
		var node: Variant = _walk[_walk_at]
		_walk_at += 1
		if is_instance_valid(node):
			_hold(node)
			if keep:
				_known.append(node)
		if not all and (_walk_at & 63) == 0 and Time.get_ticks_usec() - t0 > budget:
			return
	_walk = []
	_walk_at = 0
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.process_frame.is_connected(_walk_on):
		tree.process_frame.disconnect(_walk_on)


static func _walk_on() -> void:
	_walk_step(false, GROW_USEC if not walk_old and _walk_at < _walk.size() and _growing else walk_usec)


## A node added while there are hills: given room, and known for the next walk.
static func _hold_new(node: Node) -> void:
	if node is GeometryInstance3D:
		_hold(node)
		if not walk_old:
			_known.append(node)
			if _known.size() > _known_prune_at:
				_prune_known()


## Nodes added keep coming while the range stays (chunks streamed in and out): past twice what the
## last prune kept, the freed are dropped and a node added twice (moved to another parent) kept once.
static var _known_prune_at := 4096


static func _prune_known() -> void:
	var seen := {}
	var kept: Array = []
	for node: Variant in _known:
		if is_instance_valid(node):
			var id := (node as Object).get_instance_id()
			if not seen.has(id):
				seen[id] = true
				kept.append(node)
	_known = kept
	_known_prune_at = maxi(4096, kept.size() * 2)


## Whether nodes are still being given room a slice a frame (tests).
static func walking() -> bool:
	return _walk_at < _walk.size()


static func _hold(node: Node) -> void:
	var g := node as GeometryInstance3D
	if g == null:
		return
	if g.has_meta(META_FLAT):
		g.custom_aabb = grow(g.get_meta(META_FLAT))
	else:
		_set_margin(g, cull_margin())


## Gives a node `want` of margin for the hills over its own: a node with a bigger one of its own
## (full-screen quads) keeps it, and so does one that set its own since.
static func _set_margin(g: GeometryInstance3D, want: float) -> void:
	var own := g.extra_cull_margin
	if g.has_meta(META_MARGIN):
		if own == float(g.get_meta(META_MARGIN)):
			own = float(g.get_meta(META_OWN, 0.0))
		g.remove_meta(META_MARGIN)
		g.remove_meta(META_OWN)
	if want > own:
		g.set_meta(META_OWN, own)
		g.set_meta(META_MARGIN, want)
		g.extra_cull_margin = want
	elif g.extra_cull_margin != own:
		g.extra_cull_margin = own


## The field's lowest and highest lift: `given` (the image's `lift_range`) when it is a finite
## Vector2, else measured. Terrain Elevation gives it: its fields come every few seconds while the
## player builds, and each measuring was a 15 ms high-priority job beside the belts' own. The first
## field measured gives everything room for REACH until its heights are measured; a later one keeps
## the last field's range meanwhile.
static func _measure(heights: Image, given: Variant = null) -> void:
	_field += 1
	if given is Vector2 and is_finite(given.x) and is_finite(given.y):
		_use_range(given.x, given.y)
		return
	var data := heights.get_data()
	var channels := 3 if heights.get_format() == Image.FORMAT_RGBF else 1
	if heights.get_width() * heights.get_height() <= MEASURE_NOW:
		var r := _range_of(data, channels)
		_use_range(r.x, r.y)
		return
	if _lo == 0.0 and _hi == 0.0:
		_use_range(-REACH, REACH)
	var out := [0.0, 0.0]
	var job := func() -> void:
		var r := _range_of(data, channels)
		out[0] = r.x
		out[1] = r.y
	# High priority: a few milliseconds of work, not queued behind the long low-priority jobs (models,
	# terrain, clutter, the add-on's own heights) that share the pool's few low-priority threads.
	_measured_field = _field
	_tasks.append([WorkerThreadPool.add_task(job, true, "Ground height range"), out, _field])
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and not _polling:
		_polling = true
		tree.process_frame.connect(_poll)


## Once a frame while measurings run: takes those done, the latest field's range used.
static func _poll() -> void:
	for i in range(_tasks.size() - 1, -1, -1):
		var entry: Array = _tasks[i]
		if not WorkerThreadPool.is_task_completed(entry[0]):
			continue
		WorkerThreadPool.wait_for_task_completion(entry[0])  # done: frees it at once
		_tasks.remove_at(i)
		if int(entry[2]) == _measured_field and _on:
			_use_range(float(entry[1][0]), float(entry[1][1]))
	if _tasks.is_empty() and _polling:
		_polling = false
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null and tree.process_frame.is_connected(_poll):
			tree.process_frame.disconnect(_poll)


## Whether a field's heights are still being measured (tests).
static func measuring() -> bool:
	return not _tasks.is_empty()


## Lowest and highest of a field's floats (red and green: the cliffs' rock sits on the green one;
## with `channels` 3 the blue, how near a cliff, is no height and is skipped).
static func _range_of(data: PackedByteArray, channels := 1) -> Vector2:
	var lo := 0.0
	var hi := 0.0
	var f := data.to_float32_array()
	if channels == 3:
		for i in range(0, f.size(), 3):
			lo = minf(lo, minf(f[i], f[i + 1]))
			hi = maxf(hi, maxf(f[i], f[i + 1]))
		return Vector2(lo, hi)
	for v in f:
		if v < lo:
			lo = v
		elif v > hi:
			hi = v
	return Vector2(lo, hi)


static func is_on() -> bool:
	return _on


## Counts the fields set and cleared: a height read under something that stays put (a lamp, a
## furnace's fire, a turret) is still right while this hasn't changed, so it needn't be read again.
static func version() -> int:
	return _field


## The square the field covers: Rect2(origin, size in tiles), or an empty Rect2 when off.
static func area() -> Rect2:
	if not _on:
		return Rect2()
	return Rect2(_origin, Vector2(_size) * _step)


## Tiles per texel of the active height field (1.0 when flat).
static func tile_step() -> float:
	return _step


## The height under a world point (x east, z south), in tiles. The same sum as the shaders'.
static func at(x: float, z: float) -> float:
	if not _on or _image == null:
		return 0.0
	var h := _at_in(_image, _origin, _step, _size, x, z)
	if _mix < 1.0:
		var p := _at_in(_prev_image, _prev_origin, _prev_step, _prev_size, x, z) if _prev_image != null else 0.0
		h = lerpf(p, h, _mix)
	return h


## What at() reads, for a native twin (AltIconsNative.set_field): [on, data, format, origin, step, size, prev data,
## prev format, prev origin, prev step, prev size] (prev data empty when there is no field faded from). The mix
## goes with each read (mix_now()), as it moves every frame of a fade without version() moving.
static func sample_state() -> Array:
	var on := _on and _image != null
	var prev := on and _prev_image != null
	return [on, _image.get_data() if on else PackedByteArray(), _image.get_format() if on else Image.FORMAT_RF,
		_origin, _step, _size, _prev_image.get_data() if prev else PackedByteArray(),
		_prev_image.get_format() if prev else Image.FORMAT_RF, _prev_origin, _prev_step, _prev_size]


## The fade's mix now (1 when no fade runs): at() blends the field faded from by it.
static func mix_now() -> float:
	return _mix


## The field's three channels under a world point, as the shaders' ground3_of: (the ground, the
## ground without its cliffs' terraces, how near a cliff 0-1). A field of one channel gives its
## height twice; one of one or two channels 0 for the third.
static func at3(x: float, z: float) -> Vector3:
	if not _on or _image == null:
		return Vector3.ZERO
	var g := Vector3(_at_in(_image, _origin, _step, _size, x, z, 0), _at_in(_image, _origin, _step, _size, x, z, 1),
		_at_in(_image, _origin, _step, _size, x, z, 2))
	if _mix < 1.0:
		var p := Vector3.ZERO
		if _prev_image != null:
			p = Vector3(_at_in(_prev_image, _prev_origin, _prev_step, _prev_size, x, z, 0),
				_at_in(_prev_image, _prev_origin, _prev_step, _prev_size, x, z, 1),
				_at_in(_prev_image, _prev_origin, _prev_step, _prev_size, x, z, 2))
		g = p.lerp(g, _mix)
	return g


## Half a tile: how far either side of a point the terraces' slope is read for the ground's normal
## (the shaders' GROUND_N_TERRACE).
const GROUND_N_TERRACE := 0.5


## The ground's shading normal at a world point, the CPU twin of the shaders' ground_n: the hills'
## slope across a texel either side; with a field's low ground and `cliff_normal`, the terraces' part
## half a tile either side (read a texel out, flat ground a tile or two in front of a cliff took the
## step's slope). Up when there is no field.
static func normal(x: float, z: float) -> Vector3:
	if not _on or _image == null:
		return Vector3.UP
	var e := maxf(_step, 0.5)
	if cliff_normal and _has_low(_image):
		var s := GROUND_N_TERRACE
		var xp := at3(x + e, z)
		var xm := at3(x - e, z)
		var zp := at3(x, z + e)
		var zm := at3(x, z - e)
		var xps := at3(x + s, z)
		var xms := at3(x - s, z)
		var zps := at3(x, z + s)
		var zms := at3(x, z - s)
		var sx := (xp.y - xm.y) / (2.0 * e) + ((xps.x - xps.y) - (xms.x - xms.y)) / (2.0 * s)
		var sz := (zp.y - zm.y) / (2.0 * e) + ((zps.x - zps.y) - (zms.x - zms.y)) / (2.0 * s)
		return Vector3(-sx, 1.0, -sz).normalized()
	var dx := at(x + e, z) - at(x - e, z)
	var dz := at(x, z + e) - at(x, z - e)
	return Vector3(-dx, 2.0 * e, -dz).normalized()


## The terrace's height near a point (the shaders' cliff_terrace_near): the most of the ground less
## the low ground at 8 points CLIFF_TAP_REACH tiles round it.
static func terrace_near(x: float, z: float) -> float:
	var d := 0.0
	for k in 8:
		var a := k * TAU / 8.0
		var g := at3(x + CLIFF_TAP_REACH * cos(a), z + CLIFF_TAP_REACH * sin(a))
		d = maxf(d, g.x - g.y)
	return d


## Where a cliff's vertex `y` tiles over its model's ground stands (the shaders' cliff_seat): on the
## low ground, grown with a terrace taller than 2 tiles (never smaller than Factorio's), never more
## than 0.1 tile under the high ground. Flat ground or no cliffs near: low + y, as before.
static func cliff_seat(y: float, high: float, low: float, terrace: float) -> float:
	var f := maxf(1.0, terrace * 0.5)
	return maxf(low + y * f, high - 0.1)


## The drawn height of a cliff model's point at world (x, z), `y` tiles over its model's ground: the
## CPU twin of the shaders' ground_lift_cliff (--cliff-fit=off: on the low ground, as before).
static func cliff_lift(x: float, y: float, z: float) -> float:
	if not _on or _image == null:
		return y
	var g := at3(x, z)
	if not cliff_fit:
		return y + g.y
	return cliff_seat(y, g.x, g.y, terrace_near(x, z))


## How near a cliff the ground is (0-1, a field's third channel), as the terrain's tint reads it.
static func cliff_near(x: float, z: float) -> float:
	return at3(x, z).z


## One channel (0 red, 1 green, 2 blue) under a point, bilinear: green is red where the image has
## none, blue 0 where it has none.
static func _at_in(image: Image, origin: Vector2, step: float, size: Vector2i, x: float, z: float, channel := 0) -> float:
	# Texel centres sit at origin + (i + 0.5) * step.
	var gx := (x - origin.x) / step - 0.5
	var gz := (z - origin.y) / step - 0.5
	if gx < -0.5 or gz < -0.5 or gx > size.x - 0.5 or gz > size.y - 0.5:
		return 0.0
	var ix := floori(gx)
	var iz := floori(gz)
	var fx := gx - ix
	var fz := gz - iz
	var x0 := clampi(ix, 0, size.x - 1)
	var x1 := clampi(ix + 1, 0, size.x - 1)
	var z0 := clampi(iz, 0, size.y - 1)
	var z1 := clampi(iz + 1, 0, size.y - 1)
	if channel == 0 or (channel == 1 and not _has_low(image)):
		var a := lerpf(image.get_pixel(x0, z0).r, image.get_pixel(x1, z0).r, fx)
		var b := lerpf(image.get_pixel(x0, z1).r, image.get_pixel(x1, z1).r, fx)
		return lerpf(a, b, fz)
	if channel == 2 and image.get_format() != Image.FORMAT_RGBF:
		return 0.0
	var a2 := lerpf(image.get_pixel(x0, z0)[channel], image.get_pixel(x1, z0)[channel], fx)
	var b2 := lerpf(image.get_pixel(x0, z1)[channel], image.get_pixel(x1, z1)[channel], fx)
	return lerpf(a2, b2, fz)


## A point lifted onto the ground: its y plus the height under it.
static func lift(p: Vector3) -> Vector3:
	return Vector3(p.x, p.y + at(p.x, p.z), p.z)


## Where a ray meets the ground: the flat ground's crossing, then walked onto the hills (a few
## steps along the ray, then halving back over the crossing). Null when it points away.
static func ray_hit(from: Vector3, dir: Vector3):
	var flat = Plane(Vector3.UP, 0.0).intersects_ray(from, dir)
	if not _on or flat == null or absf(dir.y) < 0.0001:
		return flat
	# Above ground at t = 0 (the camera); march until under it, then bisect.
	var d := dir.normalized()
	var t_flat: float = (flat - from).length()
	var lo := 0.0
	var hi := -1.0
	var t := maxf(t_flat - 64.0, 0.0)
	var step := 2.0
	var limit := t_flat + 64.0
	while t <= limit:
		var p := from + d * t
		if p.y <= at(p.x, p.z):
			hi = t
			break
		lo = t
		t += step
	if hi < 0.0:
		return flat
	for i in 12:
		var mid := (lo + hi) * 0.5
		var q := from + d * mid
		if q.y <= at(q.x, q.z):
			hi = mid
		else:
			lo = mid
	var hit := from + d * hi
	return Vector3(hit.x, 0.0, hit.z)


## A material for flat marks drawn over everything (no depth test), riding on the hills: the
## vertex colour, times `picture` when given. In place of an unshaded, see-through
## StandardMaterial3D with `no_depth_test`.
static func overlay_material(priority: int, picture: Texture2D = null) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = preload("res://shaders/ground_overlay.gdshader")
	m.render_priority = priority
	if picture != null:
		m.set_shader_parameter(&"picture", picture)
		m.set_shader_parameter(&"use_picture", true)
	return m


## A material for see-through marks on the ground that what stands in front hides, riding on the
## hills: `color`, times the vertex colour when `vertex_color`, at `priority`. In place of an
## unshaded, see-through StandardMaterial3D, which the hills' lift doesn't reach (the mark ends up
## inside raised ground).
static func mark_material(color: Color, vertex_color := true, priority := 0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = preload("res://shaders/ground_mark.gdshader")
	m.render_priority = priority
	m.set_shader_parameter(&"tint", color)
	m.set_shader_parameter(&"vertex_color", vertex_color)
	return m
