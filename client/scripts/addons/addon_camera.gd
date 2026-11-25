extends RefCounted
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const ViewPriority := preload("res://scripts/world/view_priority.gd")
## api.camera: an add-on takes Zenith's camera, moves it as it likes, and hands it back; the
## player's own view (the angled view, Factorio's view, first person, the zoom) comes back exactly
## as it was. One add-on has the camera at a time. While it does:
##   - the world loads round where the camera looks (the ground under the middle of the screen),
##     or round the character, or round a point the add-on names (set_focus);
##   - with "input" (the default) the player's own controls are off (the character stops) and the
##     add-on's camera keys work (addon_keys.gd), even where they share a key with Zenith's;
##   - Zenith takes it back by itself when it needs it (a ride to a platform starts, the game ends,
##     the add-on is switched off): `lost` says so.

## Zenith took the camera back (not after release()).
signal lost
## (1.7) Read through `mode_changed` below: the camera's mode changed (mode() before and now).
signal _mode_changed(mode: String, previous: String)

## (1.7) Signal: the camera's mode changed, within a frame of it, for every add-on (not only one
## holding the camera). A property, so the first read tells Zenith to start watching the mode
## (addon_watch.gd): until an add-on reads it, nothing is compared. Connect it as any signal.
var mode_changed: Signal:
	get:
		if not _mode_wanted:
			_mode_wanted = true
			_host.watch.want_mode(_api)
		return _mode_changed

var _mode_wanted := false
var _host
var _api
var _focus = null  # Vector2 tiles, or null: as take()'s "focus" says
var _focus_mode := "camera"
var _input := true
var _mouse := false


func _init(host, api) -> void:
	_host = host
	_api = api


## Takes the camera. Options: "input" (bool, default true: the player's controls are off and the
## add-on's camera keys on), "focus" ("camera", the default: the world loads round where the camera
## looks; "character": round the character), (1.7) "aim" ("center": with "input" false, building,
## mining, the hover and shots aim at the middle of the screen through the add-on's camera, as first
## person does) and "crosshair" (bool, default true: Zenith's dot shown while aiming at the centre).
## False when it can't now (no game, another add-on has it, a ride to a platform, VR).
func take(options := {}) -> bool:
	_input = bool(options.get("input", true))
	_focus_mode = str(options.get("focus", "camera"))
	_focus = null
	# With "input" (the default) the player's controls are off, so nothing aims: "aim" waits for false.
	var aim_center := str(options.get("aim", "")) == "center" and not _input
	return _host.take_camera(_api, _input, aim_center, bool(options.get("crosshair", true)))


## Hands the camera back to the player's view.
func release() -> void:
	_mouse = false
	_host.release_camera(_api)


func has() -> bool:
	return _host.camera_holder() == _api


## Whether the player's controls are off while this add-on has the camera.
func has_input() -> bool:
	return has() and _input


## The camera itself while this add-on has it, else null: set its transform, fov, projection,
## size, near/far and attributes (depth of field) as needed. All of it is put back on release.
func node() -> Camera3D:
	return _host.rig().camera if has() and _host.rig() != null else null


## The camera's place and turn now (also while the player has it: where to start a shot from).
func transform() -> Transform3D:
	var rig = _host.rig()
	return rig.camera.global_transform if rig != null else Transform3D.IDENTITY


func fov() -> float:
	var rig = _host.rig()
	return rig.camera.fov if rig != null else 35.0


## Where the player's own view would have the camera now (round the character), and its field of
## view: glide there before release() and the hand-back is seamless.
func player_view() -> Transform3D:
	var rig = _host.rig()
	return rig.own_view() if rig != null else Transform3D.IDENTITY


## (1.7) This add-on's camera modifier until changed: `offset` in tiles in the camera's own frame (x
## right, y up, -z forward), `turn` in radians in the camera's frame (x pitch up, y yaw left, z roll),
## turned after the offset, `fov` degrees added to the view's own. Drawn on the player's own views
## (angled, Factorio's, first person) only; all add-ons' summed and capped (1.5 tiles; 20 degrees of
## pitch and yaw, 45 of roll; the FOV by 30 and between 10 and 120). No easing: set it each frame.
## Drawn only: walking, reach and what the game does never follow it. Gone when the add-on stops or
## the game ends.
func set_modifier(offset := Vector3.ZERO, turn := Vector3.ZERO, fov := 0.0) -> void:
	_host.camera_modifier(self, offset, turn, fov)


## (1.7) The same as set_modifier().
func clear_modifier() -> void:
	set_modifier()


## (1.7) This add-on's own modifier as set: {"offset", "turn", "fov"}.
func modifier() -> Dictionary:
	return _host.camera_modifier_of(self)


func player_fov() -> float:
	var rig = _host.rig()
	if rig == null:
		return 35.0
	return rig.FIRST_PERSON_FOV if rig.first_person else 35.0


## Whether the player's view is orthographic (Factorio's view, or the setting): an add-on gliding
## back may want to end in the same projection.
func player_orthographic() -> bool:
	var rig = _host.rig()
	return rig != null and rig.view_orthographic()


## (1.7) What the camera is doing now: "angled" (the normal view), "factorio" (Factorio's view as
## F6 snapped it), "first_person", "remote" (the map's remote view, a train's camera, the view round
## a hub), "ride" (Zenith's film of a rocket or pod ride), "addon" (an add-on has it: has() says
## whether it is this one) or "vr". More may come within version 1: treat one you don't know as
## not first person. "" outside a game.
func mode() -> String:
	var rig = _host.rig()
	return str(rig.view_mode()) if rig != null else ""


## (1.7) The player's own view under an add-on's take-over, the one release() goes back to: mode()
## without "addon".
func player_mode() -> String:
	var rig = _host.rig()
	return str(rig.view_mode(true)) if rig != null else ""


func set_transform(t: Transform3D) -> void:
	var cam := node()
	if cam != null:
		cam.global_transform = t.orthonormalized()


## Puts the camera at `eye` looking at `at`.
func look_from(eye: Vector3, at: Vector3) -> void:
	var cam := node()
	if cam == null or eye.is_equal_approx(at):
		return
	var dir := (at - eye).normalized()
	var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.999 else Vector3.FORWARD
	cam.global_transform = Transform3D(Basis.looking_at(dir, up), eye)


## Where the world loads and live data is asked for while this add-on has the camera: a ground
## point (Vector2, tiles), or null for take()'s "focus" choice.
func set_focus(point) -> void:
	_focus = point if point is Vector2 else null


## The point the world loads round now (tiles).
func focus() -> Vector2:
	var rig = _host.rig()
	return rig.focus_point() if rig != null else Vector2.ZERO


## The mouse captured (hidden, its motion turns the view, as in first person) while this add-on has
## the camera; Zenith gives it back while a window or menu is open.
func capture_mouse(on: bool) -> void:
	_mouse = on


func mouse_captured() -> bool:
	return _mouse and has()


## The ground point (Vector3, on the drawn ground: an add-on's hills lift it) under a screen
## position, or null.
func ground_point(screen_pos: Vector2):
	var rig = _host.rig()
	if rig == null:
		return null
	var cam: Camera3D = rig.camera
	return GroundHeight.ray_hit(cam.project_ray_origin(screen_pos), cam.project_ray_normal(screen_pos))


## The ground point under the middle of the screen, or null when looking above the horizon.
func center_ground():
	var rig = _host.rig()
	if rig == null:
		return null
	return ground_point(rig.get_viewport().get_visible_rect().size * 0.5)


## Whether the host should subscribe a camera-origin viewing cone while this add-on holds the camera.
func _uses_cone() -> bool:
	return _focus == null and _focus_mode == "camera"


## Where the world should load round now (the host asks each frame while this add-on has it).
func _focus_point() -> Vector2:
	if _focus is Vector2:
		return _focus
	if _focus_mode == "character":
		var avatar = _host.game_node("avatar")
		if avatar is Node3D:
			return Vector2(avatar.global_position.x, avatar.global_position.z)
	var t := transform()
	if ViewPriority.camera_cone:
		var w = _host.game_node("world")
		var er := 96.0
		if w != null and is_instance_valid(w) and w.get("focus_radius") != null:
			er = float(w.get("focus_radius"))
		return ViewPriority.addon_focus_point(t, er)
	var o := t.origin
	var d := -t.basis.z
	if d.y < -0.05:
		var reach := minf(-o.y / d.y, 400.0)
		var p := o + d * reach
		return Vector2(p.x, p.z)
	var flat := Vector2(d.x, d.z)
	return Vector2(o.x, o.z) + (flat.normalized() * 60.0 if flat.length() > 0.01 else Vector2.ZERO)


func _lost() -> void:
	_mouse = false
	lost.emit()


## Every handler on `mode_changed` goes (the add-on was switched off).
func _clear_mode() -> void:
	for c: Dictionary in _mode_changed.get_connections():
		_mode_changed.disconnect(c["callable"])
	_mode_wanted = false
