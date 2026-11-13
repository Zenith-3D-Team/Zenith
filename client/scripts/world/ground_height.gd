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

const GLOBAL_TEX := &"f3d_ground"
const GLOBAL_RECT := &"f3d_ground_rect"
const GLOBAL_ON := &"f3d_ground_on"
## How far the hills may lift something while a new field's heights are still being measured (the
## first field only: later ones keep the last field's range until theirs is known), in tiles.
const REACH := 48.0
## The lift's range is rounded out to this (tiles), so a field moved with the character, its hills
## a little taller or lower, doesn't set every node's bounds again.
const RANGE_STEP := 0.5
## Fields up to this many texels are measured at once; bigger ones on a worker thread (768 x 768
## texels of two channels take about 17 ms).
const MEASURE_NOW := 256 * 256
const META_FLAT := &"f3d_flat_aabb"  # a node's bounds without the hills (cull_box)
const META_MARGIN := &"f3d_hill_margin"  # the margin set here, to tell it from the node's own
const META_OWN := &"f3d_own_margin"  # the node's own margin under it

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
static var _polling := false


## Sets the field: `heights` an Image of FORMAT_RF (heights in tiles) or FORMAT_RGF (red the
## ground, green the ground without its cliffs' terraces: what cliff models sit on), its first
## texel's corner at `origin` (world x, z), `tiles_per_texel` tiles a texel. Replaces any field
## before it.
static func set_field(heights: Image, origin: Vector2, tiles_per_texel: float) -> void:
	if heights == null or heights.is_empty():
		clear()
		return
	var format := heights.get_format()
	if format != Image.FORMAT_RF and format != Image.FORMAT_RGF:
		heights = heights.duplicate()
		heights.convert(Image.FORMAT_RF)
	var low_ground := heights.get_format() == Image.FORMAT_RGF
	var size := Vector2i(heights.get_width(), heights.get_height())
	if _texture != null and size == _size and _image != null and _image.get_format() == heights.get_format():
		_texture.update(heights)
	else:
		_texture = ImageTexture.create_from_image(heights)
	_image = heights
	_size = size
	_origin = origin
	_step = maxf(tiles_per_texel, 0.001)
	_on = true
	RenderingServer.global_shader_parameter_set(GLOBAL_TEX, _texture)
	RenderingServer.global_shader_parameter_set(GLOBAL_RECT, Vector4(_origin.x, _origin.y, _step, 1.0 if low_ground else 0.0))
	RenderingServer.global_shader_parameter_set(GLOBAL_ON, 1.0)
	_measure(heights)


## Back to flat ground.
static func clear() -> void:
	_on = false
	_image = null
	_field += 1  # a measuring still running is for a field gone
	RenderingServer.global_shader_parameter_set(GLOBAL_ON, 0.0)
	_set_range(0.0, 0.0)


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
## already and, while there are hills, those to come.
static func _set_range(lo: float, hi: float) -> void:
	lo = floorf(minf(lo, 0.0) / RANGE_STEP) * RANGE_STEP
	hi = ceilf(maxf(hi, 0.0) / RANGE_STEP) * RANGE_STEP
	if lo == _lo and hi == _hi:
		return
	_lo = lo
	_hi = hi
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var on := lo != 0.0 or hi != 0.0
	if on != _watching:
		_watching = on
		if on:
			_on_added = _hold
			tree.node_added.connect(_on_added)
		else:
			tree.node_added.disconnect(_on_added)
	for node in tree.root.find_children("*", "GeometryInstance3D", true, false):
		_hold(node)


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


## The field's lowest and highest lift. The first field gives everything room for REACH until its
## heights are measured; a later one keeps the last field's range meanwhile.
static func _measure(heights: Image) -> void:
	_field += 1
	var data := heights.get_data()
	if heights.get_width() * heights.get_height() <= MEASURE_NOW:
		var r := _range_of(data)
		_set_range(r.x, r.y)
		return
	if _lo == 0.0 and _hi == 0.0:
		_set_range(-REACH, REACH)
	var out := [0.0, 0.0]
	var job := func() -> void:
		var r := _range_of(data)
		out[0] = r.x
		out[1] = r.y
	# High priority: a few milliseconds of work, not queued behind the long low-priority jobs (models,
	# terrain, clutter, the add-on's own heights) that share the pool's few low-priority threads.
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
		if int(entry[2]) == _field and _on:
			_set_range(float(entry[1][0]), float(entry[1][1]))
	if _tasks.is_empty() and _polling:
		_polling = false
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null and tree.process_frame.is_connected(_poll):
			tree.process_frame.disconnect(_poll)


## Whether a field's heights are still being measured (tests).
static func measuring() -> bool:
	return not _tasks.is_empty()


## Lowest and highest of a field's floats (both channels: the cliffs' rock sits on the green one).
static func _range_of(data: PackedByteArray) -> Vector2:
	var lo := 0.0
	var hi := 0.0
	for v in data.to_float32_array():
		if v < lo:
			lo = v
		elif v > hi:
			hi = v
	return Vector2(lo, hi)


static func is_on() -> bool:
	return _on


## The square the field covers: Rect2(origin, size in tiles), or an empty Rect2 when off.
static func area() -> Rect2:
	if not _on:
		return Rect2()
	return Rect2(_origin, Vector2(_size) * _step)


## The height under a world point (x east, z south), in tiles. The same sum as the shaders'.
static func at(x: float, z: float) -> float:
	if not _on or _image == null:
		return 0.0
	# Texel centres sit at origin + (i + 0.5) * step.
	var gx := (x - _origin.x) / _step - 0.5
	var gz := (z - _origin.y) / _step - 0.5
	if gx < -0.5 or gz < -0.5 or gx > _size.x - 0.5 or gz > _size.y - 0.5:
		return 0.0
	var ix := floori(gx)
	var iz := floori(gz)
	var fx := gx - ix
	var fz := gz - iz
	var x0 := clampi(ix, 0, _size.x - 1)
	var x1 := clampi(ix + 1, 0, _size.x - 1)
	var z0 := clampi(iz, 0, _size.y - 1)
	var z1 := clampi(iz + 1, 0, _size.y - 1)
	var a := lerpf(_image.get_pixel(x0, z0).r, _image.get_pixel(x1, z0).r, fx)
	var b := lerpf(_image.get_pixel(x0, z1).r, _image.get_pixel(x1, z1).r, fx)
	return lerpf(a, b, fz)


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
