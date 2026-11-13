extends RefCounted
## api.view: what the window shows, for clean shots and timelapses. None of it changes the game.

var _host
var _api
const AddonRequests := preload("res://scripts/addons/addon_requests.gd")

## (API 1.6) A screenshot was written (api.view.screenshot), or couldn't be.
signal screenshot_saved(path: String, ok: bool)
## (API 1.6) A screenshot was cancelled (screenshot_cancel, or Esc while it was taken): no file.
signal screenshot_cancelled(path: String)

var _hiding := false
var _holding_daytime := false
var _full_detail := false


func _init(host, api) -> void:
	_host = host
	_api = api
	host.screenshot_saved.connect(_on_saved)
	host.screenshot_cancelled.connect(_on_cancelled)


func _on_saved(path: String, ok: bool) -> void:
	screenshot_saved.emit(path, ok)


func _on_cancelled(path: String) -> void:
	screenshot_cancelled.emit(path)


## Hides Zenith's interface (the HUD, windows, the cursor, hover outlines) for a clean shot, or
## shows it again. Add-ons' windows hide too; their overlay layer (api.ui.layer()) stays. Zenith's
## menus still open over it (Esc) and show the cursor while they do.
func hide_interface(on: bool) -> void:
	_hiding = on
	_host.request_hidden(_api, on)


func interface_hidden() -> bool:
	return _host.interface_hidden()


## Saves what a viewport shows (the window when null) as a PNG at `path` (user://... or a full
## path; folders are made). The picture is taken now (the last frame drawn) and written on a worker
## thread, so a frame every few seconds costs the game little. False when there's nothing to save.
func save_frame(path: String, viewport: Viewport = null) -> bool:
	return _host.save_frame(path, viewport)


## Frames still being written.
func frames_pending() -> int:
	return _host.frames_pending()


## The 3D world the game is drawn in, for an add-on's own SubViewport and Camera3D (a second shot
## drawn off screen, saved with save_frame); null outside a game.
func world_3d() -> World3D:
	return _host.world_3d()


## Holds the time of day as drawn (0 noon, 0.25 dusk, 0.5 midnight), for a timelapse that should
## stay in daylight; the game's own time runs on. A negative value lets it run again.
func hold_daytime(daytime: float) -> void:
	_holding_daytime = daytime >= 0.0
	_host.hold_daytime(_api, daytime)


func daytime_held() -> bool:
	return _holding_daytime


## (API 1.1) Keeps Zenith drawing for an add-on that films in the background: Zenith's window
## isn't minimised when it loses focus (Settings > Graphics' "Minimize on focus loss"; a minimised
## window draws nothing, not even an add-on's own viewport), and "Hold the game at 60 UPS" never
## caps the frame rate under `min_fps`. Zenith keeps drawing behind other windows anyway; the player
## minimising it by hand still stops it. 0 (or a negative) gives it back.
func keep_drawing(min_fps: int) -> void:
	var before := AddonRequests.drawing.duplicate()
	if min_fps > 0:
		AddonRequests.drawing[_api.id] = min_fps
	else:
		AddonRequests.drawing.erase(_api.id)
	if before != AddonRequests.drawing:
		_host.requests_changed()


func keeping_drawing() -> bool:
	return AddonRequests.drawing.has(_api.id)


func screen_size() -> Vector2:
	return _host.get_viewport().get_visible_rect().size


## (API 1.6) Everything drawn at its most (on) until it is turned off again: every draw distance and
## limit at the top of its setting (view, entity, belt items near and far, decoratives and 3D grass,
## the shadow distance), every model at its own level with no level-of-detail fades or merged far
## chunks, every lit lamp with a light, nothing held back for the game's speed (world/full_detail.gd
## lists it all). Nothing is saved: the player's settings come back as they were. It costs frames
## and the game's time while it lasts: for a shot, not to play with. While any add-on asks.
func full_detail(on: bool) -> void:
	_full_detail = on
	_host.full_detail(_api, on)


func full_detail_on() -> bool:
	return _host.full_detail_on()


## (API 1.6) Everything full detail asked for is drawn (chunks, models and their levels, decoratives
## and 3D grass, belt items' models, lamps), for an add-on that takes its own pictures. Chunks and
## their clutter count in the camera's view only; one that hasn't arrived stops counting once the
## bridge has sent no new chunk for a few seconds.
func full_detail_settled() -> bool:
	return _host.full_detail_settled()


## (API 1.6) A screenshot: hides the interface (the cursor, icons over entities, add-ons' windows
## and overlays too), turns full detail on and waits until everything is drawn (or `timeout`), takes
## the picture, puts the interface back, and writes a PNG on a worker thread. Returns where it goes
## at once ("" when another is being taken or there's no game); `screenshot_saved` says when it is
## written, and Zenith shows "Screenshot saved" with Open folder.
## `path`: a .png file, a folder, or null for user://screenshots/zenith-<n>.png (the next number).
## Options: `folder` (where, when `path` is null), `size` (a Vector2i or [w, h], up to 16384 each
## way: drawn again off screen at that size by a copy of the camera set up as the window is, the
## window's height framed; Vector2i(7680, 4320) is 8K), `scale` (1-4: the window's size times this,
## when there's no `size`; 1), `full_detail` (true), `hide_interface` (true),
## `overlays` (false: add-ons' own layers hidden too), `timeout` (seconds to wait for full detail, 20),
## `pause` (true: the Factorio game held at its slowest speed while it is taken and let go after,
## single-player too, where the console's rule lets the bridge; addons/shot_pause.gd). While it is
## taken a progress bar shows (never in the picture), the camera holds still where it was (add-ons:
## leave yours alone while screenshot_busy()), the mouse moves nothing, and Esc cancels it.
func screenshot(path: Variant = null, options: Dictionary = {}) -> String:
	return _host.screenshot(path, options)


func screenshot_busy() -> bool:
	return _host.screenshot_busy()


## (API 1.6) Stops the screenshot being taken (Esc does too): the game let go, full detail and the
## interface back, nothing written; `screenshot_cancelled` says so. False when none is being taken.
func screenshot_cancel() -> bool:
	return _host.screenshot_cancel()


func _release() -> void:
	if _host.screenshot_saved.is_connected(_on_saved):
		_host.screenshot_saved.disconnect(_on_saved)
	if _host.screenshot_cancelled.is_connected(_on_cancelled):
		_host.screenshot_cancelled.disconnect(_on_cancelled)
	if _full_detail:
		full_detail(false)
	if _hiding:
		hide_interface(false)
	if _holding_daytime:
		hold_daytime(-1.0)
	keep_drawing(0)
