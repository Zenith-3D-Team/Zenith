extends RefCounted
## What is drawn nearest first, up to a cap or a range (belt items' models, 3D grass), goes by the
## camera that is drawing when it isn't Zenith's own view round the character: an add-on's camera
## (the Cinematic camera's F8), first person, and the remote view. There the camera can be far from
## the character, or facing away from most of what is round it, so the models and raised grass go
## to what is in front of the camera, nearest it first. In the normal angled view the character
## (or the bridge's square round it) stays the centre, as before.

const GroundHeight := preload("res://scripts/world/ground_height.gd")
const Switches := preload("res://scripts/switches.gd")

## Tiles outside the view's edges a thing still counts as in view: no pop at the screen's edge.
const MARGIN := 3.0

## Camera-origin chunk cone for add-on / Cinematic cameras (`--camera-cone=off` restores the old
## ground-hit square).
static var camera_cone := Switches.on("--camera-cone")
## Aggressive ground-slab frustum & zoom-in culling (`--tight-cull=off` restores legacy culling).
static var tight_cull := Switches.on("--tight-cull")
## Anchor LODs, contact shadows, far merging and distant horizon around the character during normal play
## (`--lod-anchor=camera` restores legacy camera-anchored LODs and contact fades).
static var char_lod_anchor := not (Switches.has("--lod-anchor=camera"))
## The cone's chunk streaming itself (the world subscribing only to the chunks the add-on camera sees)
## is off by default: it never ran in play. `--camera-cone=on` tries it; `--camera-cone=off` also turns the
## cone's other users (add-on focus point, decoratives, behind-cull) off.
static var cone_streaming := camera_cone and (Switches.has("--camera-cone=on"))
## Scale character-anchored LODs and far-chunk merging with camera zoom distance
## (`--char-lod-zoom=off` restores flat character-anchored LODs).
static var char_lod_zoom := Switches.on("--char-lod-zoom")
const CONE_REACH_MULT := 1.6
const CONE_FOV_PAD_DEG := 12.0
const CONE_MARGIN_TILES := 32.0
const CONE_COLLAR_CHUNKS := 2
const CONE_CHUNK_BOTTOM := -32.0
const CONE_CHUNK_TOP := 64.0
const CONE_MAX_RADIUS := 50


## True when the camera itself should decide (see above). `rig` is camera_rig.gd (untyped: no
## class_name); VR keeps the headset's own rules.
static func camera_led(rig) -> bool:
	if rig == null or not is_instance_valid(rig) or not rig.has_method("taken") or rig.get("vr_view") != null:
		return false  # (tests' stand-ins for the rig have no add-on camera)
	return rig.taken() or bool(rig.first_person) or bool(rig.in_remote)


## True when LODs, contact shadows, far merging and distant horizon should follow the camera rather
## than the character (add-on/free camera, first person, remote view, or --lod-anchor=camera).
static func lod_by_camera(rig) -> bool:
	return not char_lod_anchor or camera_led(rig)


## Distance from the camera to the ground focus point (Vector3(focus.x, 0.0, focus.y)), or 0.0 if invalid.
static func camera_zoom_distance(cam: Camera3D, focus: Vector2) -> float:
	if cam == null or not is_instance_valid(cam):
		return 0.0
	return cam.global_position.distance_to(Vector3(focus.x, 0.0, focus.y))


## The camera's frustum without its far plane (Camera3D.get_frustum(): near, far, left, top, right,
## bottom, normals out), for in_view() on another thread.
static func planes(cam: Camera3D) -> Array[Plane]:
	var out: Array[Plane] = []
	if cam == null or not cam.is_inside_tree():
		return out
	var all := cam.get_frustum()
	for i in all.size():
		if i != 1:
			out.append(all[i])
	return out


## The squared distance from the camera to `p` when `p` is within `margin` tiles of its view (in
## front of the near plane, inside the sides), INF otherwise.
static func view_distance_sq(p: Vector3, cam_pos: Vector3, frustum: Array[Plane], margin: float) -> float:
	for pl in frustum:
		if pl.distance_to(p) > margin:
			return INF
	return cam_pos.distance_squared_to(p)


## The cap nearest first: for each distance (squared; INF never counts), whether it gets a model.
## Those that have one (`models`, 1) keep it within `slack` tiles past the cap's edge, so things at
## the edge don't flip back and forth. Under the cap every counted one does.
static func choose(dists: PackedFloat32Array, models: PackedByteArray, cap: int, slack: float) -> PackedByteArray:
	var want := PackedByteArray()
	want.resize(dists.size())
	var order := PackedFloat32Array()
	for d in dists:
		if d < INF:
			order.append(d)
	var limit := INF
	if cap < order.size():
		order.sort()
		limit = order[maxi(cap - 1, 0)] if cap > 0 else -1.0
	var keep := limit if limit == INF or limit < 0.0 else pow(sqrt(limit) + slack, 2.0)
	for i in dists.size():
		var d := dists[i]
		want[i] = 1 if d < INF and d <= (keep if models[i] == 1 else limit) else 0
	return want


## Where 3D grass is centred: the character in the normal view; in front of the camera when it
## leads, the range's middle half a range ahead of the nearest ground it sees, so what is close in
## front stands up first and little is spent behind it.
static func grass_centre(rig, cam: Camera3D, character: Vector2, grass_range: float) -> Vector2:
	if not camera_led(rig) or cam == null or not cam.is_inside_tree():
		return character
	var t := cam.global_transform
	var forward := -t.basis.z
	var flat := Vector2(forward.x, forward.z)
	flat = flat.normalized() if flat.length() > 0.01 else Vector2(t.basis.y.x, t.basis.y.z).normalized()
	# The nearest ground in view: under the bottom middle of the screen, or under the camera.
	var near := Vector2(t.origin.x, t.origin.z)
	var size := cam.get_viewport().get_visible_rect().size
	var o := cam.project_ray_origin(Vector2(size.x * 0.5, size.y))
	var d := cam.project_ray_normal(Vector2(size.x * 0.5, size.y))
	if d.y < -0.01 and o.y > 0.0:
		var hit := o + d * (-o.y / d.y)
		near = Vector2(hit.x, hit.z)
	return near + flat * grass_range * 0.5


## Cone reach radius in chunks (~1.6x view_radius, capped at min(50, max_sub_radius)).
static func cone_radius(view_radius: int, max_sub_radius: int) -> int:
	var cap: int = mini(CONE_MAX_RADIUS, max_sub_radius) if max_sub_radius > 0 else CONE_MAX_RADIUS
	return clampi(roundi(float(view_radius) * CONE_REACH_MULT), mini(view_radius, cap), cap)


## Outward-facing frustum planes for `cam` padded wider than the player's FOV (`pad_deg`, `margin`).
static func cone_planes(cam: Camera3D, vp_size: Vector2, far_tiles: float, pad_deg := CONE_FOV_PAD_DEG, margin := CONE_MARGIN_TILES) -> Array[Plane]:
	var aspect := vp_size.x / vp_size.y if vp_size.x > 0.0 and vp_size.y > 0.0 else 16.0 / 9.0
	var vfov_deg := cam.fov
	var ortho_h := cam.size
	if cam.keep_aspect == Camera3D.KEEP_WIDTH and vp_size.x > 0.0 and vp_size.y > 0.0:
		var r := vp_size.y / vp_size.x
		vfov_deg = rad_to_deg(2.0 * atan(tan(deg_to_rad(cam.fov) * 0.5) * r))
		ortho_h = cam.size * r
	var local: Array[Plane] = []
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		var hy := ortho_h * 0.5 * 1.2 + margin
		var hx := ortho_h * 0.5 * aspect * 1.2 + margin
		local = [Plane(Vector3.RIGHT, hx), Plane(Vector3.LEFT, hx), Plane(Vector3.UP, hy), Plane(Vector3.DOWN, hy)]
	else:
		var vfov_rad := deg_to_rad(clampf(vfov_deg, 1.0, 175.0))
		var pad_rad := deg_to_rad(pad_deg)
		var half_v := minf(vfov_rad * 0.5 + pad_rad, deg_to_rad(86.0))
		var half_h := minf(atan(tan(vfov_rad * 0.5) * aspect) + pad_rad, deg_to_rad(86.0))
		var tv := tan(half_v)
		var th := tan(half_h)
		local = [
			Plane(Vector3(1.0, 0.0, th).normalized(), margin),
			Plane(Vector3(-1.0, 0.0, th).normalized(), margin),
			Plane(Vector3(0.0, 1.0, tv).normalized(), margin),
			Plane(Vector3(0.0, -1.0, tv).normalized(), margin),
		]
	local.append(Plane(Vector3.BACK, margin - cam.near))
	local.append(Plane(Vector3.FORWARD, far_tiles + margin))
	var xf := cam.global_transform * Transform3D(Basis(), Vector3(cam.h_offset, cam.v_offset, 0.0))
	var out: Array[Plane] = []
	for p: Plane in local:
		out.append(xf * p)
	return out


## Whether the AABB `[lo, hi]` intersects the cone bounded by outward-facing `planes`.
static func cone_box_in_view(planes: Array[Plane], lo: Vector3, hi: Vector3) -> bool:
	for p: Plane in planes:
		var n := p.normal
		var nearest := Vector3(lo.x if n.x > 0.0 else hi.x, lo.y if n.y > 0.0 else hi.y, lo.z if n.z > 0.0 else hi.z)
		if p.distance_to(nearest) > 0.0:
			return false
	return true


## Height range (tiles) a chunk's box spans for the cone test: the fixed room for buildings and trees, grown by
## what the Terrain Elevation add-on's hills lift or sink the ground (GroundHeight's range; flat: unchanged).
static func cone_chunk_range() -> Vector2:
	var lift := GroundHeight.lift_range()
	return Vector2(CONE_CHUNK_BOTTOM + minf(lift.x, 0.0), CONE_CHUNK_TOP + maxf(lift.y, 0.0))


## Chunks in `ring_offsets` (sorted nearest first) within `cone_r` that overlap the padded camera cone
## or its `±CONE_COLLAR_CHUNKS` lens collar.
static func cone_chunks(cam: Camera3D, vp_size: Vector2, ring_offsets: Array, cone_r: int, max_subs: int) -> Array:
	var out: Array = []
	if cam == null or cone_r < 0 or max_subs <= 0:
		return out
	var cam_pos := cam.global_position
	var cam_chunk := Vector2i(floori(cam_pos.x / 32.0), floori(cam_pos.z / 32.0))
	var far_tiles := (float(cone_r) + 1.0) * 32.0 + maxf(cam_pos.y, 0.0) * 1.5
	var planes := cone_planes(cam, vp_size, far_tiles)
	var collar := mini(CONE_COLLAR_CHUNKS, cone_r)
	var y_range := cone_chunk_range()
	var max_d2 := floori((float(cone_r) + 0.5) * (float(cone_r) + 0.5))
	for raw_off in ring_offsets:
		var off: Vector2i = raw_off
		if off.length_squared() > max_d2:
			break
		var c := cam_chunk + off
		if maxi(absi(off.x), absi(off.y)) <= collar:
			out.append(c)
		elif cone_box_in_view(planes, Vector3(float(c.x) * 32.0, y_range.x, float(c.y) * 32.0), Vector3(float(c.x + 1) * 32.0, y_range.y, float(c.y + 1) * 32.0)):
			out.append(c)
		if out.size() >= max_subs:
			break
	return out


## Live-entity focus anchored smoothly in the near cone ahead of the camera without horizon snaps.
static func addon_focus_point(cam_xf: Transform3D, entity_radius: float) -> Vector2:
	var o := cam_xf.origin
	var cam_xz := Vector2(o.x, o.z)
	var d := -cam_xf.basis.z
	var flat := Vector2(d.x, d.z)
	var flat_len := flat.length()
	if flat_len <= 1e-4:
		return cam_xz
	var max_ahead := clampf(entity_radius * 0.75, 48.0, 160.0)
	var ahead: float
	if d.y < -1e-4 and o.y > 0.0:
		var ground_ahead := (o.y / -d.y) * flat_len
		ahead = minf(ground_ahead, max_ahead)
	else:
		ahead = max_ahead * flat_len
	return cam_xz + (flat / flat_len) * ahead


## Returns [Vector2(x, z), depth_t] pairs where camera frustum corner and top/bottom edge rays
## pass through the ground vertical slab [y_lo, y_hi], clamped to [cam.near, max_far].
static func ground_slab_points(cam: Camera3D, max_far: float, y_pad_lo := -4.0, y_pad_hi := 20.0) -> Array:
	var out: Array = []
	if cam == null:
		return out
	var hr: Vector2 = GroundHeight.lift_range()
	var y_lo: float = hr.x + y_pad_lo
	var y_hi: float = hr.y + y_pad_hi
	var size := cam.get_viewport().get_visible_rect().size
	if size.x <= 0.0 or size.y <= 0.0:
		size = Vector2(1920.0, 1080.0)
	var samples: Array[Vector2] = [
		Vector2.ZERO,
		Vector2(size.x * 0.5, 0.0),
		Vector2(size.x, 0.0),
		Vector2(0.0, size.y),
		Vector2(size.x * 0.5, size.y),
		size,
	]
	var near := maxf(cam.near, 0.05)
	var far_lim := maxf(max_far, near)
	for c: Vector2 in samples:
		var ro := cam.project_ray_origin(c)
		var rd := cam.project_ray_normal(c)
		var t0 := near
		var t1 := far_lim
		if rd.y < -1e-4 and ro.y > y_lo:
			var t_top := near if ro.y <= y_hi else (y_hi - ro.y) / rd.y
			var t_bot := (y_lo - ro.y) / rd.y
			t0 = clampf(t_top, near, far_lim)
			t1 = clampf(t_bot, t0, far_lim)
		var p0 := ro + rd * t0
		var p1 := ro + rd * t1
		out.append([Vector2(p0.x, p0.z), t0])
		out.append([Vector2(p1.x, p1.z), t1])
	return out


## Tight 2D XZ ground rectangle enclosing the camera's ground-slab intersection, expanded by `pad`.
static func ground_view_rect(cam: Camera3D, max_far: float, pad := 0.0, y_pad_lo := -4.0, y_pad_hi := 16.0) -> Rect2:
	if cam == null:
		return Rect2()
	var pts := ground_slab_points(cam, max_far, y_pad_lo, y_pad_hi)
	if pts.is_empty():
		return Rect2()
	var first: Vector2 = pts[0][0]
	var r := Rect2(first, Vector2.ZERO)
	for i in range(1, pts.size()):
		var pt: Vector2 = pts[i][0]
		r = r.expand(pt)
	if pad != 0.0:
		r = r.grow(pad)
	return r
