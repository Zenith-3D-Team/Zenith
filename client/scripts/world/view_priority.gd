extends RefCounted
## What is drawn nearest first, up to a cap or a range (belt items' models, 3D grass), goes by the
## camera that is drawing when it isn't Zenith's own view round the character: an add-on's camera
## (the Cinematic camera's F8), first person, and the remote view. There the camera can be far from
## the character, or facing away from most of what is round it, so the models and raised grass go
## to what is in front of the camera, nearest it first. In the normal angled view the character
## (or the bridge's square round it) stays the centre, as before.

## Tiles outside the view's edges a thing still counts as in view: no pop at the screen's edge.
const MARGIN := 3.0


## True when the camera itself should decide (see above). `rig` is camera_rig.gd (untyped: no
## class_name); VR keeps the headset's own rules.
static func camera_led(rig) -> bool:
	if rig == null or not is_instance_valid(rig) or not rig.has_method("taken") or rig.get("vr_view") != null:
		return false  # (tests' stand-ins for the rig have no add-on camera)
	return rig.taken() or bool(rig.first_person) or bool(rig.in_remote)


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
