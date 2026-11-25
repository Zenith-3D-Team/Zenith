extends Node3D
## The angled view: a camera close behind and above the character that follows it, rotates in 90°
## steps (or freely with the middle mouse button), tilts, and zooms with the wheel.
## Settings → Camera (settings.gd) picks the view a game starts in, the mouse look speed and
## whether it is inverted; --camera=... wins over the setting.

const MIN_DISTANCE := 6.0
## The furthest zoom by default; Settings > Camera > Furthest zoom changes it (owner's H19).
const MAX_DISTANCE := 140.0
const MAX_ZOOM_RANGE := Vector2(60.0, 400.0)
# Below 20° the far edge of the loaded chunks comes into view; above 85° yaw stops making sense.
const MIN_PITCH := 20.0
const MAX_PITCH := 85.0
## Factorio's own view: orthographic, north up, looking down at the angle its sprites were
## rendered at (fitted in tools/models/compare.py), at its default zoom of 32 px per tile.
const FACTORIO_PITCH := 48.0
const FACTORIO_PX_PER_TILE := 32.0
## Orthographic size per unit of distance (see _process).
const ORTHO_SCALE := 0.65
## First person: eye height of the 1.7-tile character, field of view, mouse look speed.
const EYE_HEIGHT := 1.55
const FIRST_PERSON_FOV := 75.0
## First person with Settings > Camera > Projection in first person orthographic: tiles seen high.
const FIRST_PERSON_ORTHO_SIZE := 12.0
const LOOK_DEGREES_PER_PIXEL := 0.15
const Settings := preload("res://scripts/menu/settings.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const Switches := preload("res://scripts/switches.gd")

## Issue #17: on an add-on's hills the view's centre stayed at the flat height under the character, so
## the character stood off the screen's centre (zoomed in at a low tilt on a 3-tile hill, off the screen)
## and the camera went into the ground; on flat ground the centre was the feet, and the follow trailed a
## running character by about a tile. Now the character's body is the centre at every zoom, tilt and
## projection, on the hills too (owner: "should just always be in the middle"), the camera tilts up over
## ground that would come between, and it is on the character as it moves. `--camera-focus=off`: the
## camera as before.
static var focus_fix := Switches.on("--camera-focus")
## L1 (the owner's playtest): zoomed, turned or tilted out of Factorio's view (F6), the view stayed
## orthographic, Factorio's, while F7 flipped the normal view's setting (still perspective), so its
## first press said "Normal view: orthographic" and changed nothing; it took two. Now leaving Factorio's
## view that way puts the normal view's own projection back (Settings > Camera, as I19 has it), and F7
## always switches what is on screen and says so: in Factorio's view itself it leaves it where it is,
## in the other projection. `--f6-leave=old`: the view stays orthographic and F7 there as before.
static var f6_leave_fix := not (Switches.has("--f6-leave=old"))
## The 1.7-tile character's middle over its feet: the view's centre.
const BODY_MID := 0.85
## The default zoom: the up and down glide below is as tight on screen at every zoom as there.
const DEFAULT_DISTANCE := 30.0
## Up and down the centre glides a little (per second at the default zoom, faster zoomed in) so the
## hills' small kinks don't jolt the view; running up a slope the character stays within about 1% of
## the screen's height of the middle.
const VERTICAL_RATE := 12.0
## A goal further than this from the last frame's (tiles: another target, a jump) is glided to at
## FOLLOW_RATE; nearer (a walk, a run, a drive) the centre stays on it.
const JUMP := 8.0
## The camera stays this far over the ground under it (its near plane, 0.5 out, never reaches into a
## hill), and the line from it to the character's body this far over the ground between (tiles).
const CLEARANCE := 1.25
const SIGHT_CLEARANCE := 0.25
## Where on that line the ground is looked at, from the body (0) to the camera (1).
const SIGHT_SAMPLES := [0.2, 0.4, 0.6, 0.8]
## How fast a lift over the ground eases off once the ground falls away (per second); it rises at once.
const LIFT_EASE := 3.0
## How fast the view glides over to a new target or after a jump (per second).
const FOLLOW_RATE := 8.0

## Seeing the world through the character's eyes (F5). The mouse is captured and looks around;
## building and mining aim at the middle of the screen (aim_position).
var first_person := false
## Mouse look speed (a multiple of LOOK_DEGREES_PER_PIXEL) and -1 when inverted (Settings).
var look_speed := 1.0
var look_sign := 1.0
var _look_yaw := 0.0
var _look_pitch := 10.0  # degrees below the horizon
var _crosshair: CanvasLayer

var target: Node3D
## 45° looks across the grid diagonally, like an isometric game; 0° is Factorio's north-up view.
var yaw_degrees := 45.0
var pitch_degrees := 50.0
var distance := 30.0
var orthographic := false
var camera := Camera3D.new()
## How far the wheel zooms out (Settings > Camera > Furthest zoom).
var max_distance := MAX_DISTANCE
## A `--camera=` view's distance (0: none): Furthest zoom reaches at least that far for the run, so
## the view starts and stays where it was asked for.
var _arg_distance := 0.0
## In the remote view (factorio_ui.gd sets it), the map's own projection applies instead of
## `orthographic` (owner's H17: Settings > Camera, one for the map and one for the normal view).
var in_remote := false
var remote_orthographic := true
## First person's own projection (owner's I19: each view keeps the one set in Settings, and only F7
## changes it, in the view it is used in).
var first_person_orthographic := false
## A remote view opened by zooming into the map: zooming out to this distance and once more goes
## back to the map (issue #4, as Factorio 2.0 does); INF otherwise. factorio_ui.gd sets it.
var map_handoff_distance := INF

## The wheel zoomed out past map_handoff_distance.
signal zoomed_out_to_map
## Emitted whenever the camera switches between perspective and orthographic projection.
signal projection_changed(orthographic: bool)

## VR (scripts/vr/vr_session.gd): the headset's camera, which then decides which way is forward
## for walking, and the controller's laser as [origin, direction], which then stands in for the
## mouse's ray.
var vr_view: Node3D
var vr_pointer: Array = []
## VR tabletop: the ground point at the table's centre, where chunks load and live data is asked
## for (focus_point), even when the table shows somewhere away from the character.
var vr_focus := Vector2.INF

var _yaw_goal := 45.0
var _distance_goal := 30.0
## The view to go back to when Factorio's view is toggled off; empty when it isn't on.
var _saved_view := {}
## The character that was told to hide its body for first person: told again when it ends, even if
## the camera follows something else by then (the map's remote view swaps `target`).
var _first_person_body: Node3D
## Factorio's view as last snapped to: [yaw, pitch, distance].
var _factorio_snap: Array = []
## A ride's camera (scripts/world/ride.gd): the view to go back to, empty when none is on, and the
## pitch it eases towards.
var _cine_saved := {}
var _cine_pitch := 50.0
## After a ride: the pitch the view is easing back to (NAN once there), so it doesn't cut.
var _settle_pitch := NAN
## An add-on's camera (scripts/addons/addon_host.gd): while one has it, the camera stays where the
## add-on puts it (top level, in world space) and the rig itself stands at `taken_focus`, so
## focus_point() (where chunks load and live data is asked for) follows the add-on's shot. What
## the camera was before, to put back: empty while no add-on has it.
var _taken := {}
var taken_focus := Vector2.INF
var taken_cone := false
## The ground's hold on the camera (focus_fix): the lowest pitch that keeps it over the hills in
## perspective, and in an orthographic view the tiles it stands back along its axis instead (which
## changes nothing seen, so Factorio's view keeps its angle). Both rise at once and ease off.
var _ground_pitch := 0.0
var _ground_back := 0.0
## The follow (focus_fix): the last goal, its height as glided, and what is left of a glide after a jump
## (the view's centre is the goal plus this, fading).
var _last_goal := Vector3.INF
var _goal_y := 0.0
var _glide := Vector3.ZERO
## (Add-on API 1.7) Add-ons' camera modifiers (api.camera.set_modifier): a bob, a sway, a shake, a
## kick of the FOV, summed and capped by addon_host.gd and drawn on top of the player's own view in the
## angled view, Factorio's view and first person, never in a ride's film, the remote view, VR or an
## add-on's take-over. Drawn only: walking reads the view from before them (ground_forward), and the
## first-person pick reaches no further from a moved eye (modifier_reach). `--camera-modifiers=off`:
## the rig ignores them.
static var modifiers_on := Switches.on("--camera-modifiers")
var _mod_offset := Vector3.ZERO
var _mod_turn := Vector3.ZERO
var _mod_fov := 0.0
var _mod_on := false
## Whether this frame's camera has the modifier on it, its own transform from before it, and that
## transform's basis in the world as the engine works it out (walking reads it: the very value it reads
## without a modifier, to the bit).
var _mod_shown := false
var _base := Transform3D.IDENTITY
var _base_world := Basis.IDENTITY
## (1.7) An add-on's take({"aim": "center"}): building, mining and the hover aim at the middle of the
## screen, as in first person (aims_center).
var _taken_aim_center := false


func _ready() -> void:
	camera.fov = 35.0
	camera.near = 0.5
	camera.far = 2000.0
	add_child(camera)
	camera.make_current()
	configure_from(Switches.args())
	_centre_now()
	# --camera=factorio starts in Factorio's view (handy for screenshots).
	if Switches.has("--camera=factorio"):
		toggle_factorio_view.call_deferred()
	# --camera=first-person starts in the character's eyes (for screenshots).
	if Switches.has("--camera=first-person"):
		toggle_first_person.call_deferred()
	apply_settings()
	if not Settings.has_arg("--camera="):
		match str(Settings.get_value("camera", "default_view")):
			"factorio":
				toggle_factorio_view.call_deferred()
			"first_person":
				toggle_first_person.call_deferred()


## Mouse look speed and inversion, and the projection, from the settings (called again when they
## change). A `--camera=` view keeps its own projection; in Factorio's view the setting applies on
## leaving it.
func apply_settings() -> void:
	look_speed = clampf(float(Settings.get_value("camera", "look_sensitivity")), 0.05, 10.0)
	look_sign = -1.0 if bool(Settings.get_value("camera", "invert_y")) else 1.0
	max_distance = maxf(clampf(float(Settings.get_value("camera", "max_zoom")), MAX_ZOOM_RANGE.x, MAX_ZOOM_RANGE.y), _arg_distance)
	_distance_goal = minf(_distance_goal, max_distance)
	remote_orthographic = bool(Settings.get_value("camera", "map_orthographic"))
	first_person_orthographic = bool(Settings.get_value("camera", "first_person_orthographic"))
	if Settings.has_arg("--camera="):
		return
	var ortho := bool(Settings.get_value("camera", "orthographic"))
	if not _saved_view.is_empty():
		_saved_view["ortho"] = ortho
	# First person entered from Factorio's view goes back to it: its orthographic is kept too.
	if not in_factorio_view() and not (first_person and not _saved_view.is_empty()):
		orthographic = ortho


func _process(delta: float) -> void:
	if _view_anchor != null:
		_view_anchor.visible = view_mode() == "first_person"
	_left_factorio_view()
	if not _taken.is_empty():
		if taken_focus != Vector2.INF:
			global_position = _follow(Vector3(taken_focus.x, 0.0, taken_focus.y))
		return
	if first_person:
		# Locked to the character: any lag would feel like a lurching head.
		if target != null:
			global_position = GroundHeight.lift(target.global_position + _lifted(target))
		var look := Basis(Vector3.UP, deg_to_rad(_look_yaw)) * Basis(Vector3.RIGHT, -deg_to_rad(_look_pitch))
		camera.transform = Transform3D(look, Vector3(0.0, EYE_HEIGHT, 0.0))
		# Set only when it differs: Camera3D's setters don't check, and each one updates the
		# rendering server's camera and emits property_list_changed.
		if first_person_orthographic:
			_set_projection(Camera3D.PROJECTION_ORTHOGONAL)
			if not is_equal_approx(camera.size, FIRST_PERSON_ORTHO_SIZE):
				camera.size = FIRST_PERSON_ORTHO_SIZE
		else:
			_set_projection(Camera3D.PROJECTION_PERSPECTIVE)
		_modify()
		return
	if target != null:
		# A ride's camera goes up with the rocket; only the view on foot stays level.
		if focus_fix and not in_cinematic():
			_follow_body(delta)
		else:
			var to := target.global_position if in_cinematic() else _follow(target.global_position)
			global_position = global_position.lerp(to, 1.0 - exp(-delta * FOLLOW_RATE))
			_last_goal = Vector3.INF  # back on the character after a ride, glided over from here
	yaw_degrees = lerpf(yaw_degrees, _yaw_goal, 1.0 - exp(-delta * 10.0))
	# A ride's camera moves slowly, as a film's would.
	var rate := 1.6 if not _cine_saved.is_empty() else 10.0
	distance = lerpf(distance, _distance_goal, 1.0 - exp(-delta * rate))
	if not _cine_saved.is_empty():
		pitch_degrees = lerpf(pitch_degrees, _cine_pitch, 1.0 - exp(-delta * rate))
	elif not is_nan(_settle_pitch):
		pitch_degrees = lerpf(pitch_degrees, _settle_pitch, 1.0 - exp(-delta * 3.0))
		if absf(pitch_degrees - _settle_pitch) < 0.05:
			pitch_degrees = _settle_pitch
			_settle_pitch = NAN
	_hold_over_ground(delta)
	var turn := Basis(Vector3.UP, deg_to_rad(yaw_degrees)) * Basis(Vector3.RIGHT, -deg_to_rad(shown_pitch()))
	camera.transform = Transform3D(turn, turn * Vector3(0.0, 0.0, distance + _ground_back))
	if view_orthographic():
		_set_projection(Camera3D.PROJECTION_ORTHOGONAL)
		camera.size = distance * ORTHO_SCALE
	else:
		_set_projection(Camera3D.PROJECTION_PERSPECTIVE)
	_modify()


func _set_projection(proj: Camera3D.ProjectionType) -> void:
	if camera.projection == proj:
		return
	camera.projection = proj
	projection_changed.emit(proj == Camera3D.PROJECTION_ORTHOGONAL)


## (1.7) The add-ons' modifier, already summed and capped (addon_host.gd), drawn from the next _process.
func set_modifier(offset: Vector3, turn: Vector3, fov: float) -> void:
	_mod_offset = offset
	_mod_turn = turn
	_mod_fov = fov
	_mod_on = modifiers_on and (offset != Vector3.ZERO or turn != Vector3.ZERO or fov != 0.0)


## The view's own field of view, without a modifier: first person's or the angled view's.
func _own_fov() -> float:
	return FIRST_PERSON_FOV if first_person else 35.0


## The modifier on top of the transform _process has just built from nothing (so it never adds up over
## frames), in the player's three views only; elsewhere the add-on's number is kept for afterwards. The
## field of view goes back to the view's own when the last modifier goes. Orthographic views keep theirs.
func _modify() -> void:
	if not _mod_on and not _mod_shown:
		return
	_mod_shown = _mod_on and not in_cinematic() and not in_remote and vr_view == null
	var fov := _own_fov()
	if _mod_shown:
		_base = camera.transform
		_base_world = camera.global_transform.basis
		var t := _base
		t.origin += t.basis * _mod_offset
		t.basis = t.basis * Basis.from_euler(_mod_turn)
		camera.transform = t
		if not view_orthographic():
			fov = clampf(fov + _mod_fov, 10.0, 120.0)
	if not is_equal_approx(camera.fov, fov):  # Camera3D's setter doesn't check (see first person's)
		camera.fov = fov


## (1.7) How far the modifier moves the eye from where the player's view has it (tiles): the
## first-person pick's reach is cut by it, so a moved eye never picks further than an unmoved one.
func modifier_reach() -> float:
	return _mod_offset.length() if _mod_shown else 0.0


## Whether the view in use is drawn orthographic: first person's, the map's remote view's or the
## angled view's setting (Factorio's view is the angled view held orthographic).
func view_orthographic() -> bool:
	if first_person:
		return first_person_orthographic
	return remote_orthographic if in_remote else orthographic


## In Factorio's view (toggle_factorio_view) as it was snapped to, with the view before it to go
## back to. Turned, tilted or zoomed since, it isn't any more (the view before is still kept).
func in_factorio_view() -> bool:
	return not _saved_view.is_empty() and not first_person and orthographic and _factorio_snap == [_yaw_goal, pitch_degrees, _distance_goal]


## L1: turned, tilted or zoomed out of Factorio's view, the normal view's own projection is back (the
## view before is still kept, so F6 snaps to Factorio's again and once more goes back to it, G5).
## Called wherever the view is moved, and each frame for whatever else moves it.
func _left_factorio_view() -> void:
	if not f6_leave_fix or _saved_view.is_empty() or first_person or not orthographic or in_cinematic():
		return
	if _factorio_snap != [_yaw_goal, pitch_degrees, _distance_goal]:
		orthographic = bool(_saved_view["ortho"])


## Jumps straight to Factorio's view centred on the character, or back to the view before it.
## Owner's G5: F6 sometimes took several presses. Turning, tilting or zooming in Factorio's view
## (a nudge of the middle mouse, the wheel) left it marked as on, so the next press went back to
## the view before instead of snapping, and in first person the snap didn't show at all. Now a
## press snaps whenever the view isn't exactly Factorio's, and goes back only from it.
func toggle_factorio_view() -> void:
	if in_factorio_view():
		leave_factorio_view()
		return
	var was_first_person := first_person
	if first_person:
		toggle_first_person()
	if _saved_view.is_empty():
		_saved_view = {"yaw": _yaw_goal, "pitch": pitch_degrees, "distance": _distance_goal, "ortho": orthographic,
			"first_person": was_first_person}
	# Ground tiles in Factorio are FACTORIO_PX_PER_TILE apart on screen vertically too; through a
	# camera pitched down by FACTORIO_PITCH a tile spans sin(pitch) of its length.
	var tiles_high := get_viewport().get_visible_rect().size.y / FACTORIO_PX_PER_TILE
	var size := tiles_high * sin(deg_to_rad(FACTORIO_PITCH))
	_snap(360.0 * roundf(_yaw_goal / 360.0), FACTORIO_PITCH, size / ORTHO_SCALE, true)
	_factorio_snap = [_yaw_goal, pitch_degrees, _distance_goal]
	_centre_now()


## Back to the view before Factorio's, if Factorio's (as snapped to, or changed since) is on.
func leave_factorio_view() -> void:
	if not _saved_view.is_empty():
		_snap(_saved_view["yaw"], _saved_view["pitch"], _saved_view["distance"], _saved_view["ortho"])
		var back_to_first_person: bool = _saved_view.get("first_person", false)
		_saved_view = {}
		if back_to_first_person and not first_person:
			toggle_first_person()


func _snap(yaw: float, pitch: float, dist: float, ortho: bool) -> void:
	_yaw_goal = yaw
	yaw_degrees = yaw
	_settle_pitch = NAN
	pitch_degrees = pitch
	_distance_goal = clampf(dist, MIN_DISTANCE, max_distance)
	distance = _distance_goal
	orthographic = ortho
	# A jump to a view (F6 and back): the ground's hold is worked out again for it, not eased over.
	_ground_pitch = 0.0
	_ground_back = 0.0


## F7 (owner's H17): flips the projection of the view in use, first person, the map's remote view
## or the normal view, and keeps it as that view's setting, so Settings shows it (I19). It flips what
## is on screen (L1): in Factorio's view (F6), orthographic, the normal view goes perspective where it
## stands, out of Factorio's view (F6 snaps back to it). Returns a line saying what it is now.
## `--f6-leave=old`: Factorio's view stays orthographic and F7 there changes only the normal view's.
func toggle_projection() -> String:
	_left_factorio_view()
	var key := "first_person_orthographic" if first_person else ("map_orthographic" if in_remote else "orthographic")
	var ortho := not view_orthographic() if f6_leave_fix else not bool(Settings.get_value("camera", key))
	var factorio_view := in_factorio_view()
	# The setting's listeners (apply_settings) read it back into the view, Factorio's view kept.
	Settings.set_value("camera", key, ortho)
	var kind := "orthographic" if ortho else "perspective"
	if first_person:
		first_person_orthographic = ortho
		return "First person: " + kind
	if in_remote:
		remote_orthographic = ortho
		return "Map view: " + kind
	if not _saved_view.is_empty():
		_saved_view["ortho"] = ortho
	if factorio_view and not f6_leave_fix:
		return "Normal view: %s (Factorio's view stays orthographic)" % kind
	orthographic = ortho
	return "Normal view: " + kind


## `--camera=<yaw>,<pitch>,<distance>[,ortho]` starts with that view, for repeatable screenshots
## (`--camera=0,48,14,ortho` is close to Factorio's own view). `args`: the command line's.
func configure_from(args: PackedStringArray) -> void:
	for arg in args:
		if not arg.begins_with("--camera=") or arg in ["--camera=factorio", "--camera=first-person"]:
			continue
		var parts := arg.get_slice("=", 1).split(",")
		if parts.size() >= 3:
			_yaw_goal = float(parts[0])
			yaw_degrees = _yaw_goal
			pitch_degrees = clampf(float(parts[1]), MIN_PITCH, MAX_PITCH)
			_distance_goal = clampf(float(parts[2]), MIN_DISTANCE, MAX_ZOOM_RANGE.y)
			distance = _distance_goal
			_arg_distance = _distance_goal
		orthographic = parts.size() >= 4 and parts[3] == "ortho"


## A ride's camera (ride.gd): eases to this pitch and distance, out of first person and Factorio's
## view, until cinematic_end() puts the view back.
func cinematic(pitch: float, dist: float) -> void:
	if _cine_saved.is_empty():
		_cine_saved = {"pitch": pitch_degrees, "distance": _distance_goal, "factorio": in_factorio_view(), "fp": first_person}
		if first_person:
			toggle_first_person()
		if in_factorio_view():
			toggle_factorio_view()
	_cine_pitch = pitch
	_distance_goal = clampf(dist, MIN_DISTANCE, max_distance)


func cinematic_end() -> void:
	if _cine_saved.is_empty():
		return
	var saved := _cine_saved
	_cine_saved = {}
	_distance_goal = float(saved["distance"])
	if bool(saved["factorio"]) or bool(saved["fp"]):
		pitch_degrees = float(saved["pitch"])
	else:
		_settle_pitch = float(saved["pitch"])
	if bool(saved["factorio"]):
		toggle_factorio_view()
	if bool(saved["fp"]):
		toggle_first_person()


func in_cinematic() -> bool:
	return not _cine_saved.is_empty()


## An add-on takes the camera: from now on it moves it (`camera`, in world space) until
## hand_back(). The player's own view (first person, Factorio's view, zoom) is kept as it was.
## (1.7) `aim_center`: the player's controls aim at the middle of the screen meanwhile (aims_center),
## with Zenith's dot when `crosshair`.
func take_over(aim_center := false, crosshair := true) -> void:
	if not _taken.is_empty():
		_set_taken_aim(aim_center, crosshair)
		return
	# The view's own FOV, not a modifier's: hand_back puts the player's view back as it was.
	_taken = {"fov": _own_fov() if _mod_shown else camera.fov, "near": camera.near, "far": camera.far, "projection": camera.projection,
		"size": camera.size, "attributes": camera.attributes, "keep_aspect": camera.keep_aspect,
		"crosshair": _crosshair != null and _crosshair.visible}
	var at := camera.global_transform
	camera.top_level = true
	camera.global_transform = at
	if _crosshair != null:
		_crosshair.visible = false
	_mod_shown = false  # the add-on's camera now: the modifier waits for the hand-back
	_set_taken_aim(aim_center, crosshair)


func _set_taken_aim(aim_center: bool, crosshair: bool) -> void:
	_taken_aim_center = aim_center
	if aim_center and crosshair:
		_show_crosshair(true)
	elif _crosshair != null:
		_crosshair.visible = false


## The camera back to the player's view exactly as it was, round the character again.
func hand_back() -> void:
	if _taken.is_empty():
		return
	var t := _taken
	_taken = {}
	_taken_aim_center = false
	taken_focus = Vector2.INF
	taken_cone = false
	camera.top_level = false
	camera.fov = float(t["fov"])
	camera.near = float(t["near"])
	camera.far = float(t["far"])
	_set_projection(int(t["projection"]) as Camera3D.ProjectionType)
	camera.size = float(t["size"])
	camera.attributes = t["attributes"]
	camera.keep_aspect = t["keep_aspect"]
	if _crosshair != null:
		_crosshair.visible = bool(t["crosshair"])  # an add-on's dot (aim_center) goes with it
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if first_person else Input.MOUSE_MODE_VISIBLE
	_centre_now()
	_process(0.0)  # the camera in its place now, not a frame late


func taken() -> bool:
	return not _taken.is_empty()


func use_view_cone() -> bool:
	return taken() and taken_cone


## (Add-on API 1.7) api.character's `view` point: a child of the camera (no frame of lag), made on first
## use, shown only in the player's own first person (not while an add-on, a ride, VR or the remote view
## has the camera). A viewmodel's anchor: it clips into walls and takes the FOV kick with the world.
var _view_anchor: Node3D


func view_anchor() -> Node3D:
	if _view_anchor == null:
		_view_anchor = Node3D.new()
		_view_anchor.name = "AddonView"
		camera.add_child(_view_anchor)
		_view_anchor.visible = view_mode() == "first_person"
	return _view_anchor


## What the camera is doing now, for add-ons (api.camera.mode): "addon", "vr", "ride", "remote",
## "first_person", "factorio" or "angled", the first that holds. `own`: the player's own view under
## an add-on's take-over (api.camera.player_mode). Remote is above first person, which stays on while
## a remote view is open with the rig at the remote point. Reads only: nothing here moves the view.
func view_mode(own := false) -> String:
	if not own and taken():
		return "addon"
	if vr_view != null:
		return "vr"
	if in_cinematic():
		return "ride"
	if in_remote:
		return "remote"
	if first_person:
		return "first_person"
	return "factorio" if in_factorio_view() else "angled"


## Where the player's own view would put the camera now, round the character (an add-on glides
## there before handing the camera back).
func own_view() -> Transform3D:
	var at := target.global_position if target != null else global_position
	if first_person:
		var look := Basis(Vector3.UP, deg_to_rad(_look_yaw)) * Basis(Vector3.RIGHT, -deg_to_rad(_look_pitch))
		# On the hills, where _process puts first person's eyes (and an add-on's lift, 1.7).
		at += _lifted(target)
		return Transform3D(look, (GroundHeight.lift(at) if focus_fix else at) + Vector3(0.0, EYE_HEIGHT, 0.0))
	if not focus_fix:
		var flat := Basis(Vector3.UP, deg_to_rad(_yaw_goal)) * Basis(Vector3.RIGHT, -deg_to_rad(pitch_degrees))
		return Transform3D(flat, at + flat * Vector3(0.0, 0.0, _distance_goal))
	if target != null:
		at = _focus_goal()
	var turn := Basis(Vector3.UP, deg_to_rad(_yaw_goal)) * Basis(Vector3.RIGHT, -deg_to_rad(shown_pitch()))
	return Transform3D(turn, at + turn * Vector3(0.0, 0.0, _distance_goal + _ground_back))


## Into the character's eyes, facing the way the camera faced, or back out to the view before.
func toggle_first_person() -> void:
	first_person = not first_person
	if first_person:
		_look_yaw = yaw_degrees
		_look_pitch = 10.0
		camera.fov = FIRST_PERSON_FOV
		camera.near = 0.05
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		camera.fov = 35.0
		camera.near = 0.5
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_show_crosshair(first_person)
	if first_person:
		if target != null and target.has_method("set_first_person"):
			_first_person_body = target
			target.set_first_person(true)
	elif is_instance_valid(_first_person_body):
		_first_person_body.set_first_person(false)
		_first_person_body = null


## Mouse look in first person, from a mouse motion in pixels.
func look(relative: Vector2) -> void:
	_look_yaw -= relative.x * LOOK_DEGREES_PER_PIXEL * look_speed
	_look_pitch = clampf(_look_pitch + relative.y * LOOK_DEGREES_PER_PIXEL * look_speed * look_sign, -85.0, 85.0)


## (1.7) Whether the player aims at the middle of the screen: in first person, or while an add-on has
## the camera with take({"aim": "center"}). The one place player_input.gd asks.
func aims_center() -> bool:
	return first_person or (taken() and _taken_aim_center)


## Where the player aims on screen: the cursor, or the crosshair in first person (or an add-on's
## camera aiming at the centre).
func aim_position() -> Vector2:
	if aims_center():
		return get_viewport().get_visible_rect().size * 0.5
	return get_viewport().get_mouse_position()


## Windows (inventory, machine screens) need the cursor; first person gives it back while one is
## open and takes it again when they close.
func set_cursor_needed(needed: bool) -> void:
	if first_person:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if needed else Input.MOUSE_MODE_CAPTURED


func _show_crosshair(show: bool) -> void:
	if _crosshair == null:
		_crosshair = CanvasLayer.new()
		var root := CenterContainer.new()
		root.set_anchors_preset(Control.PRESET_FULL_RECT)
		root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var dot := ColorRect.new()
		dot.custom_minimum_size = Vector2(4, 4)
		dot.color = Color(1, 1, 1, 0.85)
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(dot)
		_crosshair.add_child(root)
		add_child(_crosshair)
	_crosshair.visible = show


func rotate_step(steps: int) -> void:
	_yaw_goal += 90.0 * steps


func rotate_free(degrees: float) -> void:
	_yaw_goal += degrees
	yaw_degrees += degrees


func tilt(degrees: float) -> void:
	_settle_pitch = NAN
	pitch_degrees = clampf(pitch_degrees + degrees, MIN_PITCH, MAX_PITCH)


func zoom(factor: float) -> void:
	# The map's remote view zooms out to its own distance (Settings > Camera), past Furthest zoom.
	var far := map_handoff_distance if map_handoff_distance != INF else max_distance
	if factor > 1.0 and map_handoff_distance != INF and _distance_goal >= far - 0.01:
		zoomed_out_to_map.emit()
		return
	_distance_goal = clampf(_distance_goal * factor, MIN_DISTANCE, far)


## Where the camera's focus sat over a point before issue #17, and still does with --camera-focus=off
## and for an add-on's shot (where chunks load): level at the flat world's height (owner: "camera
## elevation on terrain off"), or on an add-on's hills with the old setting camera.follow_hills saved on.
static func _follow(p: Vector3) -> Vector3:
	if bool(Settings.get_value("camera", "follow_hills")):
		return GroundHeight.lift(p)
	return Vector3(p.x, 0.0, p.z)


## The view's centre straight onto the target, without the glide (the start, Factorio's view, a
## hand-back).
func _centre_now() -> void:
	if target == null:
		return
	if focus_fix and not in_cinematic():
		global_position = _focus_goal()
		_last_goal = global_position
		_goal_y = global_position.y
		_glide = Vector3.ZERO
	else:
		global_position = _follow(target.global_position)


## The view's centre (focus_fix): the character's body where it is drawn, on the hills and in the air
## (mech armour's flight), at every zoom, tilt and projection; in the map's remote view the ground there.
func _focus_goal() -> Vector3:
	var p := target.global_position
	if not in_remote:
		var up := _lifted(target)
		p += Vector3(up.x, 0.0, up.z)  # its height comes in view_lift()
	var y := p.y + GroundHeight.at(p.x, p.z)
	if not in_remote:
		y += BODY_MID
		if target.has_method("view_lift"):
			y += float(target.view_lift())  # the avatar: flight and camera lifts, not the belt step-up
		elif target.has_method("drawn_lift"):
			y += float(target.drawn_lift())
	return Vector3(p.x, y, p.z)


## (Add-on API 1.7) The camera's part of the character's lift (avatar.gd camera_lift()): only add-ons'
## lifts set with `camera` move the eye and the centre; the body's other lifts (the belt step-up, an
## add-on's without `camera`) leave the view still. Zero for any other target.
static func _lifted(t: Node) -> Vector3:
	if t != null and t.has_method("camera_lift"):
		return t.camera_lift()
	return Vector3.ZERO


## The view's centre on the character (focus_fix). Across the ground it stays on it: the drawn walk is
## even already (avatar.gd), and the glide it had trailed a running character by about a tile, a sixth
## of the screen's width zoomed all the way in. Up and down it glides a little (VERTICAL_RATE). A jump
## (another target, the remote view left, a teleport) is glided over from where the view was.
func _follow_body(delta: float) -> void:
	var goal := _focus_goal()
	if _last_goal == Vector3.INF or goal.distance_to(_last_goal) > JUMP:
		_glide = global_position - goal
		_goal_y = goal.y
	_last_goal = goal
	var zoom_in := maxf(1.0, DEFAULT_DISTANCE / maxf(distance, 0.1))
	_goal_y = lerpf(_goal_y, goal.y, 1.0 - exp(-delta * VERTICAL_RATE * zoom_in))
	_glide *= exp(-delta * FOLLOW_RATE)
	if _glide.length() < 0.001:
		_glide = Vector3.ZERO
	global_position = Vector3(goal.x, _goal_y, goal.z) + _glide


## The pitch the view is drawn at: the player's, or higher where the ground would come between.
func shown_pitch() -> float:
	return maxf(pitch_degrees, _ground_pitch)


## Keeps the camera over an add-on's hills (focus_fix): in perspective at least CLEARANCE over the
## ground under it and the line from it to the character's body SIGHT_CLEARANCE over the ground between,
## by tilting up as far as that needs, round the same centre, so the character stays on it (games raise
## the camera or pull it in; pulling in at the closest zoom would put it in the character). In an
## orthographic view it stands back along its axis instead, which changes nothing seen: Factorio's view
## keeps its angle. Up at once, eased off as the ground falls away, so walking over hills it neither dips
## into them nor jumps.
func _hold_over_ground(delta: float) -> void:
	var pitch_need := 0.0
	var back_need := 0.0
	if focus_fix and _cine_saved.is_empty() and GroundHeight.is_on():
		if view_orthographic():
			back_need = _back_needed()
		else:
			pitch_need = _pitch_needed(_focus_goal() if target != null else global_position)
	var ease := 1.0 - exp(-delta * LIFT_EASE)
	if view_orthographic():
		_ground_pitch = 0.0  # an orthographic view keeps its angle (Factorio's view its 48 degrees)
	elif pitch_need > pitch_degrees:
		_ground_pitch = maxf(pitch_need, lerpf(maxf(_ground_pitch, pitch_degrees), pitch_need, ease))
	elif _ground_pitch > pitch_degrees + 0.05:
		_ground_pitch = lerpf(_ground_pitch, pitch_degrees, ease)
	else:
		_ground_pitch = 0.0  # none: the player's tilt is drawn as it is
	_ground_back = maxf(back_need, lerpf(_ground_back, back_need, ease))
	if _ground_back < 0.01:
		_ground_back = 0.0


## The lowest pitch from the player's up to MAX_PITCH that clears the hills (_clear_at), or 0 when the
## player's own does (nearly every frame: one look at the ground under the camera and four on the way).
func _pitch_needed(body: Vector3) -> float:
	var lo := pitch_degrees
	if _clear_at(body, lo):
		return 0.0
	var hi := lo
	var found := false
	while hi < MAX_PITCH:
		hi = minf(hi + 5.0, MAX_PITCH)
		if _clear_at(body, hi):
			found = true
			break
		lo = hi
	if not found:
		return maxf(MAX_PITCH, pitch_degrees)
	for i in 7:  # to 0.04 degrees
		var mid := (lo + hi) * 0.5
		if _clear_at(body, mid):
			hi = mid
		else:
			lo = mid
	return hi


## Whether the perspective camera at `pitch` is CLEARANCE over the ground under it and the line from
## it to `body` SIGHT_CLEARANCE over the ground along the way.
func _clear_at(body: Vector3, pitch: float) -> bool:
	var turn := Basis(Vector3.UP, deg_to_rad(yaw_degrees)) * Basis(Vector3.RIGHT, -deg_to_rad(pitch))
	var eye := global_position + turn * Vector3(0.0, 0.0, distance)
	if eye.y < GroundHeight.at(eye.x, eye.z) + CLEARANCE:
		return false
	for s: float in SIGHT_SAMPLES:
		var q := body.lerp(eye, s)
		if q.y < GroundHeight.at(q.x, q.z) + SIGHT_CLEARANCE:
			return false
	return true


## Orthographic: how far back along its axis the camera stands so its near plane, as wide and high as
## the view, is over the hills (0 when it is where it is).
func _back_needed() -> float:
	if _near_clear(0.0):
		return 0.0
	var lo := 0.0
	var hi := 0.0
	var step := 4.0
	var found := false
	while hi < 400.0:
		hi += step
		if _near_clear(hi):
			found = true
			break
		lo = hi
		step *= 1.5
	if not found:
		return hi
	for i in 6:
		var mid := (lo + hi) * 0.5
		if _near_clear(mid):
			hi = mid
		else:
			lo = mid
	return hi


func _near_clear(back: float) -> bool:
	var turn := Basis(Vector3.UP, deg_to_rad(yaw_degrees)) * Basis(Vector3.RIGHT, -deg_to_rad(pitch_degrees))
	var half_h := distance * ORTHO_SCALE * 0.5
	var size := get_viewport().get_visible_rect().size if is_inside_tree() else Vector2(16.0, 9.0)
	var half_w := half_h * size.x / maxf(size.y, 1.0)
	var near := global_position + turn * Vector3(0.0, 0.0, distance + back - camera.near)
	# Its bottom edge (left, middle, right) and the top's middle, the lowest and the furthest back.
	for corner: Vector3 in [Vector3(-half_w, -half_h, 0.0), Vector3(0.0, -half_h, 0.0), Vector3(half_w, -half_h, 0.0), Vector3(0.0, half_h, 0.0)]:
		var q := near + turn * corner
		if q.y < GroundHeight.at(q.x, q.z) + SIGHT_CLEARANCE:
			return false
	return true


## Where the camera looks, on the ground (tiles).
func focus_point() -> Vector2:
	if vr_focus != Vector2.INF:
		return vr_focus
	return Vector2(global_position.x, global_position.z)


## Camera forward and right flattened onto the ground, for camera-relative movement. An add-on's
## modifier is left out (_view_basis): a sway or a shake must never bend the `walk` sent to the game.
func ground_forward() -> Vector3:
	var basis := _view_basis()
	var f := -basis.z
	f.y = 0.0
	if f.length() < 0.01:  # looking straight down (an add-on's overhead shot): screen up is forward
		f = basis.y
		f.y = 0.0
	return f.normalized()


func ground_right() -> Vector3:
	var r := _view_basis().x
	r.y = 0.0
	return r.normalized()


func _view_basis() -> Basis:
	if vr_view != null:
		return vr_view.global_transform.basis
	if _mod_shown:
		return _base_world
	return camera.global_transform.basis


## The point on the ground under a screen position, or null.
func ground_point(screen_pos: Vector2):
	var r := ray(screen_pos)
	# On hills (ground_height.gd) the ray is walked onto the ground drawn; flat, the plane y = 0.
	return GroundHeight.ray_hit(r[0], r[1])


## [origin, direction] of the ray under a screen position: the mouse's, or the VR laser.
func ray(screen_pos: Vector2) -> Array:
	if vr_pointer.size() == 2:
		return vr_pointer
	return [camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos)]
