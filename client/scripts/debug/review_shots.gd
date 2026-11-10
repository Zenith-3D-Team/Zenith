extends Node
## Saves a set of screenshots of whatever stands where the character is, for reviewing models:
##
##   --review-shots=<dir>[@seconds]   start after that many seconds (default 12), then quit
##   --review-box=<w>,<d>,<h>         the size to frame and crop to (tiles, default 3,3,3)
##   --review-aim=<y>                 the height the side views look at (default 0.4 of the box's)
##   --review-fly=<path.json>         instead of the views: a camera flight, keyframes of [x, y, z] camera
##                                    position, [x, y, z] point looked at and frames to reach it, saved as
##                                    fly/0000.jpg... (world coordinates: Factorio x, height, Factorio y)
##   --review-views=<a,b,...>         which shots (default: all of VIEWS); `close+0.3` is the
##                                    close view 0.3 s after the shot before (machines moving)
##
## Meant for the mock with a model placed on the character's tile (the avatar and the HUD are
## hidden). Shots: Factorio's view (orthographic, north up, 48 degrees), the angled view from
## each side (north.png is the view from the north), a low side view and a close perspective one,
## each cropped to the box's outline on screen.

## yaw, pitch, distance for a 3-tile model (scaled to the box), orthographic; the cameras the
## review set uses. "factorio" is Factorio's own view and zoom.
const VIEWS := {
	"factorio": [0.0, 48.0, 0.0, true],
	"north": [180.0, 38.0, 7.0, false],
	"east": [270.0, 38.0, 7.0, false],
	"south": [0.0, 38.0, 7.0, false],
	"west": [90.0, 38.0, 7.0, false],
	"low": [30.0, 10.0, 7.0, false],
	"close": [20.0, 25.0, 4.0, false],
	"night": [0.0, 38.0, 7.0, false],  # the south view, named for shots taken at night
}
const MARGIN := 0.12

var rig: Node3D  # camera_rig.gd
var avatar: Node3D
var game: Node
var out_dir := ""
var delay := 12.0
var box := Vector3(3, 3, 3)
var aim := -1.0
var views: Array = VIEWS.keys()
var fly_path := ""


static func requested() -> bool:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--review-shots="):
			return true
	return false


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--review-shots="):
			var spec := arg.get_slice("=", 1)
			out_dir = spec.get_slice("@", 0)
			if spec.contains("@"):
				delay = float(spec.get_slice("@", 1))
		elif arg.begins_with("--review-box="):
			var p := arg.get_slice("=", 1).split(",")
			box = Vector3(float(p[0]), float(p[1]), float(p[2]))
		elif arg.begins_with("--review-aim="):
			aim = float(arg.get_slice("=", 1))
		elif arg.begins_with("--review-fly="):
			fly_path = arg.get_slice("=", 1)
		elif arg.begins_with("--review-views="):
			views = Array(arg.get_slice("=", 1).split(","))
	DirAccess.make_dir_recursive_absolute(out_dir)
	_run.call_deferred()


func _run() -> void:
	await get_tree().create_timer(delay).timeout
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	avatar.visible = false
	for layer in game.find_children("*", "CanvasLayer", true, false):
		(layer as CanvasLayer).visible = false
	var size := maxf(box.x, maxf(box.y, box.z))
	if fly_path != "":
		await _fly(JSON.parse_string(FileAccess.get_file_as_string(fly_path)))
		get_tree().quit()
		return
	for view in views:
		if str(view).begins_with("turn"):
			await _turn(int(str(view).substr(4)), size)
			continue
		var v: Array = VIEWS[str(view).get_slice("+", 0)]
		if v[3]:
			rig._saved_view = {}
			rig.toggle_factorio_view()
		else:
			var dist: float = v[2] * maxf(size, 1.5) / 3.0
			rig._snap(v[0], 0.0, dist, false)
			rig.pitch_degrees = v[1]  # below the rig's own limit for the low view
			rig._distance_goal = dist
			rig.distance = dist
		# Look at the middle of the box, not the ground under it (tall trees, poles).
		rig.target = null
		var look := box.z * 0.4 if aim < 0.0 else aim
		rig.global_position = avatar.global_position + Vector3(0.0, 0.0 if v[3] else look, 0.0)
		if str(view).contains("+"):
			await get_tree().create_timer(float(str(view).get_slice("+", 1))).timeout
		else:
			for i in 20:
				await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var image := get_viewport().get_texture().get_image()
		var rect := _crop(image.get_size())
		if rect.has_area():
			image = image.get_region(rect)
		if v[3] and image.get_height() < 400:
			# Factorio's zoom is small on screen: blow the crop up, pixels kept sharp.
			var k := ceili(400.0 / image.get_height())
			image.resize(image.get_width() * k, image.get_height() * k, Image.INTERPOLATE_NEAREST)
		var path := out_dir.path_join(str(view) + ".png")
		print("review shot %s: %s" % [path, error_string(image.save_png(path))])
	get_tree().quit()


## `turn<N>`: a turntable, N frames once round from above the angled view, saved uncropped as
## turn/000.png... (the model stays in one place on screen) to line up into a video.
func _turn(frames: int, size: float) -> void:
	frames = maxi(frames, 1)
	var dir := out_dir.path_join("turn")
	DirAccess.make_dir_recursive_absolute(dir)
	# The camera is placed by hand, the rig left still, so nothing eases or follows.
	rig.set_process(false)
	rig.set_physics_process(false)
	var camera: Camera3D = rig.camera
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.fov = 40.0
	camera.h_offset = 0.0
	camera.v_offset = 0.0
	var centre := avatar.global_position + Vector3(0.0, box.z * 0.45, 0.0)
	var dist := 1.6 * maxf(maxf(box.x, box.y), box.z) + 1.5
	var pitch := deg_to_rad(40.0)
	for i in frames:
		var yaw := TAU * i / frames
		var offset := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * dist
		camera.global_position = centre + offset
		camera.look_at(centre, Vector3.UP)
		for k in (60 if i == 0 else 2):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(dir.path_join("%03d.png" % i))
	print("review shot %s: %d frames" % [dir, frames])


## `--review-fly`: the camera flies between keyframes ({"pos": [x, y, z], "look": [x, y, z], "frames": n}),
## eased in and out at each, one frame saved per step.
func _fly(keys: Array) -> void:
	var dir := out_dir.path_join("fly")
	DirAccess.make_dir_recursive_absolute(dir)
	rig.set_process(false)
	rig.set_physics_process(false)
	var camera: Camera3D = rig.camera
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.fov = 45.0
	camera.h_offset = 0.0
	camera.v_offset = 0.0
	var v3 := func(a: Array) -> Vector3: return Vector3(float(a[0]), float(a[1]), float(a[2]))
	var n := 0
	for k in range(1, keys.size()):
		var a: Dictionary = keys[k - 1]
		var b: Dictionary = keys[k]
		var frames := int(b["frames"])
		for i in frames:
			var t := smoothstep(0.0, 1.0, float(i) / frames)
			camera.global_position = (v3.call(a["pos"]) as Vector3).lerp(v3.call(b["pos"]), t)
			camera.look_at((v3.call(a["look"]) as Vector3).lerp(v3.call(b["look"]), t), Vector3.UP)
			for f in (90 if n == 0 else 2):
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_jpg(dir.path_join("%04d.jpg" % n), 0.95)
			n += 1
	print("review shot %s: %d frames" % [dir, n])


## The box's outline on screen, with a margin, inside the image.
func _crop(image_size: Vector2i) -> Rect2i:
	var camera: Camera3D = rig.camera
	var c := avatar.global_position
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for sx in [-0.5, 0.5]:
		for sy in [0.0, 1.0]:
			for sz in [-0.5, 0.5]:
				var p := c + Vector3(sx * box.x, sy * box.z, sz * box.y)
				if camera.is_position_behind(p):
					return Rect2i(Vector2i.ZERO, image_size)
				var s := camera.unproject_position(p)
				lo = lo.min(s)
				hi = hi.max(s)
	var pad := (hi - lo) * MARGIN
	var r := Rect2(lo - pad, hi - lo + pad * 2.0)
	var scale := Vector2(image_size) / get_viewport().get_visible_rect().size
	r = Rect2(r.position * scale, r.size * scale)
	return Rect2i(r).intersection(Rect2i(Vector2i.ZERO, image_size))
