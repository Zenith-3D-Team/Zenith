extends RefCounted
## Everything at its most for a shot (api.view.full_detail, api.view.screenshot; docs/ADDONS.md):
## every draw distance and limit lifted, every model at its full level, then the player's own back.
## Nothing is saved: the settings are held over the player's (Settings.hold), and the rest are
## switches on the parts that draw.
##
## Lifted while it is on:
## - Settings > Graphics held at their tops: view distance (chunks: VIEW_RADIUS, or the player's when
##   longer: a shot mustn't drop the chunks of a longer view; a screenshot also asks for every chunk
##   its camera sees, cover()), entity distance (moving things
##   and machine states), belt item distance and updates (Unlimited), Items in 3D (every item a
##   model), decoratives on at full density and distance, 3D grass Far, the shadow distance, Level
##   of detail High, and far chunks not merged (every loaded chunk drawn whole).
## - Levels of detail: every model at its own level wherever it is, switched without the cross-fade,
##   Godot's own LODs off (the viewport's mesh_lod_threshold 0), belts without their far stand-ins.
## - Decoratives drawn whole out to their distance (not thinned past 80 tiles).
## - Lights: every lit lamp glows (up to lamp_lights.gd FULL_BULBS) and the nearest FULL_LIGHTS have a
##   real light (48 otherwise); furnace fires and lab glows out to 400 tiles, with 48 lights.
## - Hold the game at 60 UPS and add-ons' lighter updates hold nothing back.
## - The camera's far plane at least FAR tiles, and the 3D resolution at least the window's.
##
## Several callers can ask at once (by reason); it ends when the last lets go.

const Settings := preload("res://scripts/menu/settings.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const BeltLods := preload("res://scripts/world/belt_lods.gd")
const UpsGovernor := preload("res://scripts/world/ups_governor.gd")

## The settings held, at the tops of their sliders (settings_window.gd, main.gd's clamps).
const HELD := {
	"lod_quality": "high",
	"merge_far": false,
	"entity_radius": 256,
	"belt_distance": 640,
	"belt_updates": 0,  # Unlimited
	"item_models_max": Settings.ITEM_MODELS_ALL,
	"decoratives": true,
	"decorative_density": 1.0,
	"decorative_distance": 320,
	"grass_3d": "far",
	"shadow_distance": 1000,
}
## The view distance (chunks) at least while it is on.
const VIEW_RADIUS := 20
## The camera sees at least this far (tiles) while it is on.
const FAR := 6000.0
## settled(): at least this long after full detail came on (the bridge sends moving things, belt
## items and chunks for the wider distances over its next updates), and this many frames in a row
## with nothing being built.
const MIN_SECONDS := 1.0
const CALM_FRAMES := 10
## pending() counts only the chunks in the camera's view (view_filter): the view grown by
## VIEW_MARGIN tiles (shadows and tall things reach in), each chunk from CHUNK_BOTTOM to CHUNK_TOP
## tiles high (hills, rockets). A wanted chunk in view that hasn't arrived stops counting once no
## new chunk has arrived for QUIET_MSEC: the bridge sends chunks as its work budget allows and has
## stopped (one it can't send, or lost, would otherwise hold every shot to its timeout).
const VIEW_MARGIN := 8.0
const CHUNK_BOTTOM := -32.0
const CHUNK_TOP := 64.0
const QUIET_MSEC := 3000
## The bridge's work report is this recent or isn't read (it comes once a second; a held game's
## seldom).
const REPORT_MSEC := 2500
## How far (tiles) from the camera a screenshot's cover reaches past the horizon: the bridge's
## largest square, 101 chunks.
const COVER_REACH := 101 * 32.0
## A screenshot's shape (width / height) while one is drawn at a size of its own (addon_host.gd): the
## view it waits for is framed like it. 0: the window's.
static var shot_aspect := 0.0

static var _by := {}  # reason -> true
static var _since := 0
static var _belt_lods_before := true
static var _far_before := -1.0
static var _camera: Camera3D
static var _scale_before := -1.0
## A screenshot's view as cover() framed it (view_filter), fixed while it waits: its decoratives are
## counted in that view, not in whatever the camera does meanwhile.
static var _shot_view := Callable()


static func is_on() -> bool:
	return not _by.is_empty()


## Turns it on or off for `reason`; `main` is main.gd (its world, lamps, decoratives, viewport).
static func request(reason: StringName, on: bool, main: Node) -> void:
	var was := is_on()
	if on:
		_by[reason] = true
	else:
		_by.erase(reason)
	if is_on() != was:
		_apply(is_on(), main)


## Everything back as it was (the game ended, the add-on host left).
static func clear(main: Node) -> void:
	if is_on():
		_by.clear()
		_apply(false, main)


static func _apply(on: bool, main: Node) -> void:
	if main != null and not is_instance_valid(main):
		main = null  # quitting: the game's nodes are gone, only the switches go back
	_since = Time.get_ticks_msec()
	ModelLods.full_detail = on
	UpsGovernor.lifted = on
	if on:
		_belt_lods_before = BeltLods.enabled
		BeltLods.enabled = false
	else:
		BeltLods.enabled = _belt_lods_before
	var vp := main.get_viewport() if main != null and main.is_inside_tree() else null
	if vp != null:
		var cam := vp.get_camera_3d()
		if on and cam != null:
			_camera = cam
			_far_before = cam.far
			cam.far = maxf(cam.far, FAR)
		elif not on and is_instance_valid(_camera) and is_equal_approx(_camera.far, maxf(_far_before, FAR)):
			_camera.far = _far_before
		if not on:
			_camera = null
		if on:
			_scale_before = vp.scaling_3d_scale
			vp.scaling_3d_scale = maxf(vp.scaling_3d_scale, 1.0)
		elif _scale_before > 0.0:
			vp.scaling_3d_scale = _scale_before
			_scale_before = -1.0
	for field in ["lamps", "working_glow"]:
		var n = _node(main, field)
		if n != null and n.has_method("set_full_detail"):
			n.set_full_detail(on)
	var decor = _node(main, "decoratives")
	if decor != null and decor.get("full_detail") != null:
		decor.full_detail = on
	if not on:
		cover(main, false)  # a screenshot's cover ends with full detail
	# Last: main.gd applies the settings again, reading the switches above (ModelLods.apply_quality).
	if on:
		var held := HELD.duplicate()
		held["view_radius"] = maxi(VIEW_RADIUS, int(Settings.get_value("graphics", "view_radius")))
		Settings.hold("graphics", held)
	else:
		Settings.release("graphics")


## Whether everything asked for is drawn: the chunks in the camera's view (built, ground meshed,
## none part-built; arrived, or the bridge has stopped sending), models (read, levels made, none
## cross-fading), the view's decoratives and 3D grass built, belt items' looks read, lamps refreshed.
## The B-roll recorder's settle checks, with the ones full detail adds.
static func settled(main: Node) -> bool:
	if Time.get_ticks_msec() - _since < int(MIN_SECONDS * 1000.0):
		return false
	return pending(main).is_empty()


## What is still being drawn in the camera's view, by name (for the log when a shot timed out): {}
## when settled. Chunks and their clutter count by how many are left; off the view they keep
## arriving and building without holding the shot.
static func pending(main: Node) -> Dictionary:
	var out := {}
	var view := _shot_view if _shot_view.is_valid() else view_filter(main)
	var world = _node(main, "world")
	var shot: Dictionary = world.shot_progress() if world != null and world.has_method("shot_progress") else {}
	if not shot.is_empty():
		# A screenshot's cover: its fixed set of chunks (world.gd set_cover), which only goes down.
		if not bool(shot.get("ready", false)):
			out["chunks_starting"] = true
		elif int(shot.get("left", 0)) > 0:
			out["chunks"] = int(shot["left"])
		elif int(shot.get("building", 0)) > 0:
			out["building"] = int(shot["building"])
	elif world != null and world.has_method("unsettled_in"):
		var left: int = world.unsettled_in(view, given_up(world))
		if left > 0:
			out["chunks"] = left
	elif world != null and world.has_method("settled") and not world.settled():
		out["chunks"] = world.chunks.size()
	if ModelLibrary.busy():
		out["models"] = true
	if ModelLods.busy():
		out["lods"] = true
	var decor = _node(main, "decoratives")
	if decor != null and decor.has_method("pending_in"):
		var left: int = decor.pending_in(view)
		if left > 0:
			out["decoratives"] = left
	elif decor != null and decor.has_method("settled") and not decor.settled():
		out["decoratives"] = true
	var belts = _node(main, "belt_items")
	if belts != null and belts.has_method("looks_pending") and belts.looks_pending() > 0:
		out["belt_items"] = belts.looks_pending()
	var lamps = _node(main, "lamps")
	if lamps != null and lamps.get("refreshed") == false:
		out["lamps"] = true
	return out


## Whether the bridge has stopped sending new chunks: none arrived for QUIET_MSEC since full detail
## came on (its wider view's chunks start coming within a fraction of a second), and its last work
## report (`wb`, once a second) has no chunks left in its queue. The bridge reads one chunk a tick by
## default (f3d-chunks-per-tick), and a client busy building the ones it has asks for no more for a
## while: neither is the bridge giving up, and a shot taken then (and the game held, which starves
## the bridge) left the rest of the view empty.
static func given_up(world: Object) -> bool:
	var last = world.get("last_arrival_msec")
	var since := maxi(int(last) if last is int else 0, _since)
	if Time.get_ticks_msec() - since < QUIET_MSEC:
		return false
	return bridge_queue() <= 0


## A screenshot's chunks (world.gd shot_progress): {} without a cover.
static func shot_progress(main: Node) -> Dictionary:
	var world = _node(main, "world")
	return world.shot_progress() if world != null and world.has_method("shot_progress") else {}


## The chunks the bridge still has to send by its last work report, if that is recent; 0 without one.
static func bridge_queue() -> int:
	if Bridge.work_budget_msec <= 0 or Time.get_ticks_msec() - Bridge.work_budget_msec > REPORT_MSEC:
		return 0
	var q = Bridge.work_budget.get("q")
	return int(q.get("chunks", 0)) if q is Dictionary else 0


## A screenshot's cover (world.gd set_cover): every chunk its camera sees asked for, besides the view's
## own square, out to the bridge's largest square. Call with the camera where the shot is framed; off
## ends it.
static func cover(main: Node, on: bool) -> void:
	var world = _node(main, "world")
	if not on:
		_shot_view = Callable()
		UpsGovernor.photo = false
	if world == null or not world.has_method("set_cover"):
		return
	if not on:
		world.clear_cover()
		return
	var vp: Viewport = main.get_viewport() if main.is_inside_tree() else null
	var cam: Camera3D = vp.get_camera_3d() if vp != null else null
	if cam == null:
		return
	var window := vp.get_visible_rect().size
	var aspect := shot_aspect if shot_aspect > 0.0 else window.x / maxf(window.y, 1.0)
	var foot := ground_footprint(cam, window, aspect, COVER_REACH)
	var lo := Vector2i(floori(foot.position.x / 32.0), floori(foot.position.y / 32.0)) - Vector2i.ONE
	var hi := Vector2i(floori(foot.end.x / 32.0), floori(foot.end.y / 32.0)) + Vector2i.ONE
	var g := cam.global_position
	var near := Vector2i(floori(g.x / 32.0), floori(g.z / 32.0))
	_shot_view = view_filter(main)
	UpsGovernor.photo = true  # the bridge's work budget may grow past its usual top meanwhile
	world.set_cover(Rect2i(lo, hi - lo + Vector2i.ONE), near, _shot_view)


## The ground (x, z in tiles) a picture `aspect` wide sees from `cam`, as a box: where its corners'
## rays meet the ground, or `reach` tiles out along them past the horizon (a look over the horizon
## sees as far as the bridge can send), and under the camera.
static func ground_footprint(cam: Camera3D, window: Vector2, aspect: float, reach: float) -> Rect2:
	var frame := vertical_frame(cam, window)
	var xf := cam.global_transform * Transform3D(Basis(), Vector3(cam.h_offset, cam.v_offset, 0.0))
	var b := xf.basis
	var points: Array[Vector2] = [Vector2(xf.origin.x, xf.origin.z)]
	var ortho := cam.projection == Camera3D.PROJECTION_ORTHOGONAL
	var hy := frame.y * 0.5 if ortho else tan(deg_to_rad(clampf(frame.x, 1.0, 179.0)) * 0.5)
	var hx := hy * aspect
	for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
		var from := xf.origin
		var dir := -b.z
		if ortho:
			from += b.x * corner.x * hx + b.y * corner.y * hy
		else:
			dir = (b.x * corner.x * hx + b.y * corner.y * hy - b.z).normalized()
		var flat := Vector2(dir.x, dir.z)
		var t := INF
		if dir.y < -0.0001:
			t = from.y / -dir.y
		var hit := Vector2(from.x, from.z) + flat * t if t != INF else Vector2.INF
		var out := Vector2(from.x, from.z) - Vector2(xf.origin.x, xf.origin.z)
		if t == INF or (hit - Vector2(xf.origin.x, xf.origin.z)).length() > reach:
			# Past the horizon, or further than the bridge sends: as far as it sends that way.
			hit = Vector2(xf.origin.x, xf.origin.z) + out + (flat.normalized() * reach if flat.length() > 0.0001 else Vector2.ZERO)
		points.append(hit)
	var box := Rect2(points[0], Vector2.ZERO)
	for p in points:
		box = box.expand(p)
	return box


## Whether a chunk is in the camera's view (as a screenshot of shot_aspect frames it): a
## Callable(Vector2i) -> bool. Without a camera every chunk is.
static func view_filter(main: Node) -> Callable:
	var vp: Viewport = main.get_viewport() if main != null and is_instance_valid(main) and main.is_inside_tree() else null
	var cam: Camera3D = vp.get_camera_3d() if vp != null else null
	if cam == null:
		var all := func(_c: Vector2i) -> bool: return true
		return all
	var window := vp.get_visible_rect().size
	var aspect := shot_aspect if shot_aspect > 0.0 else window.x / maxf(window.y, 1.0)
	var planes := view_planes(cam, window, aspect, VIEW_MARGIN)
	var seen := func(c: Vector2i) -> bool:
		return box_in_view(planes, Vector3(c.x * 32.0, CHUNK_BOTTOM, c.y * 32.0), Vector3(c.x * 32.0 + 32.0, CHUNK_TOP, c.y * 32.0 + 32.0))
	return seen


## `cam`'s vertical field of view (degrees) and orthographic height as it frames a `window` of that
## size: what a picture of another shape keeps (KEEP_HEIGHT), as games do at a fixed resolution.
static func vertical_frame(cam: Camera3D, window: Vector2) -> Vector2:
	if cam.keep_aspect == Camera3D.KEEP_HEIGHT or window.x <= 0.0 or window.y <= 0.0:
		return Vector2(cam.fov, cam.size)
	var r := window.y / window.x
	return Vector2(rad_to_deg(2.0 * atan(tan(deg_to_rad(cam.fov) * 0.5) * r)), cam.size * r)


## The planes (in the world, facing out) round what `cam` sees in a picture `aspect` wide to 1 high,
## its height framed as in the `window`, grown by `margin` tiles.
static func view_planes(cam: Camera3D, window: Vector2, aspect: float, margin: float) -> Array[Plane]:
	var frame := vertical_frame(cam, window)
	var local: Array[Plane] = []
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		var hy := frame.y * 0.5 + margin
		var hx := frame.y * 0.5 * aspect + margin
		local = [Plane(Vector3.RIGHT, hx), Plane(Vector3.LEFT, hx), Plane(Vector3.UP, hy), Plane(Vector3.DOWN, hy)]
	else:
		var t := tan(deg_to_rad(clampf(frame.x, 1.0, 179.0)) * 0.5)
		for n: Vector3 in [Vector3(1.0, 0.0, t * aspect), Vector3(-1.0, 0.0, t * aspect), Vector3(0.0, 1.0, t), Vector3(0.0, -1.0, t)]:
			local.append(Plane(n.normalized(), margin))
	local.append(Plane(Vector3.BACK, margin - cam.near))  # in front of the near plane
	local.append(Plane(Vector3.FORWARD, cam.far + margin))
	var xf := cam.global_transform * Transform3D(Basis(), Vector3(cam.h_offset, cam.v_offset, 0.0))
	var out: Array[Plane] = []
	for p in local:
		out.append(xf * p)
	return out


## Whether a box from `lo` to `hi` reaches inside every plane (view_planes).
static func box_in_view(planes: Array[Plane], lo: Vector3, hi: Vector3) -> bool:
	for p in planes:
		var n := p.normal
		var nearest := Vector3(lo.x if n.x > 0.0 else hi.x, lo.y if n.y > 0.0 else hi.y, lo.z if n.z > 0.0 else hi.z)
		if p.distance_to(nearest) > 0.0:
			return false
	return true


static func _node(main: Node, field: String):
	if main == null or not is_instance_valid(main):
		return null
	var n = main.get(field)
	return n if n is Object and is_instance_valid(n) else null
