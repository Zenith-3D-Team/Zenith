extends Node
## --flicker-probe=<folder>[@degrees per frame]: the tree flicker measurement (PROGRESS.md, the
## tree flicker fix): once the world has settled, turns the camera slowly (0.1 degrees a frame by
## default) for FRAMES frames, saving each frame as <folder>/f<NN>.png, then quits.
## tools/flicker_count.py counts the pixels that change and change back. Run it windowed.
##
## --flicker-probe=<folder>@pan: Factorio's view (F6, orthographic, north up) moved east exactly one
## screen pixel a frame instead. Every frame is then the one before shifted a pixel left, so
## `flicker_count.py --pan` lines them up and any pixel that still changes is real flicker (two
## flat pictures fighting over depth, shimmer, popping, crawling shadows), not the picture moving,
## which turning can't tell apart from flicker.
##
## --flicker-probe=<folder>@still: the camera stays where it is and every rendered frame is kept
## (in memory, saved once all are taken), so a flicker that flips each frame isn't sampled away
## (the modes above keep every other frame, two after each camera step). @still-90 takes 90.
## @drift: the same, the angled view turning 0.02 degrees a frame; @walk: the angled view moving
## east 0.05 tiles a frame, as when following the character. A third part sets the
## pixels of error the levels of detail (and the viewport's mesh LODs) allow for the run
## (@still-60@0: every model whole), to tell LOD changes apart.

const FRAMES := 40
const SETTLE := 25.0  # seconds after the world is ready, so models and LODs are in

## When it has saved the frames (the debug menu shows it).
signal reported(text: String)

var world  # world.gd
var out_dir := ""
var step := 0.1
var pan := false
## @still / @drift: every frame kept, the camera turning `step` a frame (0 for still).
var every_frame := false
var frames := FRAMES
var _images: Array[Image] = []
var walk := false
var lod_threshold := -1.0
## Started from the debug menu in a game already loaded: a shorter wait, and the game goes on after.
var settle := SETTLE
var quit_when_done := true

var _wait := 0.0
var _frame := -1
var _busy := false  # a frame being captured: the camera turns again only after it is saved
var _at := Vector3.ZERO


func _ready() -> void:
	var spec := out_dir.split("@")
	out_dir = spec[0]
	if spec.size() > 1:
		var mode := spec[1].get_slice("-", 0)
		if spec[1].contains("-"):
			frames = int(spec[1].get_slice("-", 1))
		pan = mode == "pan"
		if mode == "still" or mode == "drift" or mode == "walk":
			every_frame = true
			walk = mode == "walk"
			step = 0.02 if mode == "drift" else 0.0
		elif not pan:
			step = float(spec[1])
	if spec.size() > 2:
		lod_threshold = float(spec[2])
	DirAccess.make_dir_recursive_absolute(out_dir)


func _process(delta: float) -> void:
	if world == null or not Bridge.world_ready or _frame >= frames or _busy:
		return
	var rig = world.get_parent().get_parent().get("rig")
	if rig == null:
		return
	if _frame < 0:
		_wait += delta
		if _wait < settle:
			return
		_frame = 0
		if lod_threshold >= 0.0:
			get_viewport().mesh_lod_threshold = lod_threshold
			preload("res://scripts/world/model_lods.gd").lod_threshold = lod_threshold
		if walk:
			_at = rig.global_position
			rig.target = null
		if pan:
			if not rig.in_factorio_view():
				rig.toggle_factorio_view()
			# The probe places the camera itself: following the character eases, which isn't a whole pixel.
			_at = rig.global_position
			rig.target = null
	if every_frame:
		_capture_every_frame(rig)
		return
	_busy = true
	if pan:
		var cam: Camera3D = rig.camera
		_at.x += cam.size / get_viewport().get_visible_rect().size.y  # tiles per screen pixel
		rig.global_position = _at
	else:
		rig.yaw_degrees += step
		rig._yaw_goal = rig.yaw_degrees
	# Two frames drawn with the new view (the separate render thread draws a frame behind).
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png(out_dir.path_join("f%02d.png" % _frame))
	_frame += 1
	_busy = false
	if _frame >= frames:
		_finish()


## One image a frame for @still and @drift: the frame drawn last is read while this one is made.
func _capture_every_frame(rig) -> void:
	_busy = true
	rig.yaw_degrees += step
	rig._yaw_goal = rig.yaw_degrees
	if walk:
		_at.x += 0.05
		rig.global_position = _at
	await RenderingServer.frame_post_draw
	_images.append(get_viewport().get_texture().get_image())
	_frame += 1
	_busy = false
	if _frame >= frames:
		for i in _images.size():
			_images[i].save_png(out_dir.path_join("f%03d.png" % i))
		_finish()


func _finish() -> void:
	print("FLICKER saved %d frames to %s" % [frames, out_dir])
	reported.emit("Saved %d frames to %s (tools/flicker_count.py counts what flickers)" % [frames, ProjectSettings.globalize_path(out_dir)])
	if not quit_when_done:
		queue_free()
		return
	preload("res://scripts/menu/exit_guard.gd").arm()
	get_tree().quit()
