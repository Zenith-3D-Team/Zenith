extends RefCounted
## Fast belts' surfaces smeared over the way they move in a frame, so their slats and chevrons
## slide instead of blinking from place to place (factorio_material.gdshaderinc belt_smear, whose
## constants these mirror). Turbo's slats move exactly half their period a frame at 60 fps, and an
## express chevron jumps more than its own 0.08-tile stroke; without TAA nothing blends frames. The
## shader needs the frame's length, which it has no built-in for: world.gd sets it every frame
## (f3d_frame_dt), 0 where nothing should smear.
##
## Kept short (owner: fast belts looked blurry in motion): SHUTTER frames' travel, from a smoothed
## frame length that never counts more than a 60 fps frame, so a hitch doesn't smear a whole belt
## flat; none while TAA is on (it blends frames itself, and blurs moving belts already: Godot has no
## motion vectors for a scrolling surface), and none on a screenshot's frames (sharp_frames()).

## Frames' travel the smear spans: one frame's box stops express and turbo belts strobing and keeps
## most of their detail (two, as before, washed fast belts out).
const SHUTTER := 1.0
## ... but at least this share of a slat period: red's quarter-period step still strobed on 8% of
## its moving pixels with one frame's box, 0.36 stops it (0.1% at 0.34 before).
const MIN := 0.36
## Shares of a slat period stepped in a frame between which the smear fades in: yellow belts at
## 60 fps step 0.125 and are drawn as before; red 0.25, express 0.375 and turbo 0.5 fully smeared.
const FROM := 0.13
const TO := 0.2
## The slats' period in tiles (the shader's BELT_PERIOD).
const PERIOD := 0.25
## The longest frame the smear counts: a slower frame (30 fps, a hitch, a breakpoint) smears no more
## than a 60 fps frame does.
const MAX_DT := 1.0 / 60.0
## Share of each new frame's length the smoothed one takes, so one odd frame barely moves it.
const SMOOTHING := 0.1

const Settings := preload("res://scripts/menu/settings.gd")

## The frame length last given to the shaders (0: no smear this frame).
static var frame_dt := 0.0
## The smoothed frame length (capped at MAX_DT), whether or not it is given to the shaders.
static var _smooth := -1.0
## --no-belt-smear: belts drawn as before the smear (0 a frame), for comparing.
static var _off := -1
## The process frame before which belts aren't smeared (sharp_frames()).
static var _sharp_until := 0


## Tiles a belt of `speed` tiles a second is smeared over in a frame of `dt` seconds, as the shader
## works it out; 0 for a slow or stopped belt.
static func smear(speed: float, dt: float) -> float:
	var moved := absf(speed) * clampf(dt, 0.0, MAX_DT)
	return maxf(moved * SHUTTER, MIN * PERIOD) * smoothstep(FROM * PERIOD, TO * PERIOD, moved)


## No smear on this frame and the next `frames - 1` (a screenshot or a captured frame: one picture
## shows nothing moving, so a smeared belt only looks blurred). Takes effect at once.
static func sharp_frames(frames := 2) -> void:
	_sharp_until = maxi(_sharp_until, Engine.get_process_frames() + frames)
	frame_dt = 0.0
	RenderingServer.global_shader_parameter_set(&"f3d_frame_dt", 0.0)


## Whether belts are drawn without the smear this frame: --no-belt-smear, sharp_frames() or TAA.
static func sharp_now() -> bool:
	if _off < 0:
		_off = 1 if OS.get_cmdline_user_args().has("--no-belt-smear") else 0
	return _off == 1 or Engine.get_process_frames() < _sharp_until or Settings.taa_on()


## This frame's length for the shaders (`delta`: under --fixed-fps it is 1/fps, as TIME's step).
static func frame(delta: float) -> void:
	var capped := clampf(delta, 0.0, MAX_DT)
	_smooth = capped if _smooth < 0.0 else lerpf(_smooth, capped, SMOOTHING)
	frame_dt = 0.0 if sharp_now() else _smooth
	RenderingServer.global_shader_parameter_set(&"f3d_frame_dt", frame_dt)
