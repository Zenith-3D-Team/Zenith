extends Node
## Ambient occlusion by how close the view is (owner: "it should show when zoomed in enough to see it
## and fade at a further distance; the biggest issue is zooming out"). One number says how close: the
## tiles a pixel covers where the view looks (the ground under the middle of the screen: the angled
## view's zoom, F6's orthographic size, first person, an add-on's camera, the remote view alike). From
## it, every frame:
##
##   - Godot's SSAO (when Settings > Graphics > Ambient occlusion or a look has it on) at full strength
##     up close, fading out between SSAO_FULL and SSAO_GONE, and switched off altogether past that, so
##     a zoomed-out view pays nothing for it (the depth pre-pass writing normals was most of its cost),
##     with a margin each way so it doesn't toggle on the edge. The look's and the setting's own values
##     stay on the Environment; the faded copy goes to the renderer (RenderingServer.environment_set_ssao).
##   - The contact rims under buildings and along belts (contact_shade.gdshader) fade by the same
##     measure per pixel, between RIM_FULL and RIM_GONE (ContactShade.material() reads them).
##
## The baked occlusion of the models (their vertices' COLOR) stays at every zoom: it is smooth, so it
## neither shimmers nor costs anything far off. These are the thresholds' one place (docs/USER-GUIDE.md,
## Graphics, says what they mean for the player).

## Tiles per pixel at the view's middle. At 1080p with the angled view's 35 degree field of view a
## camera 10 tiles off is about 0.006, the default 30 tiles about 0.018, the furthest zoom (140)
## 0.08; SSAO is full to about 68 tiles off and gone by 145 (a 1440p screen's pixels are three
## quarters the size: a third further; 4K twice as far). Owner: AO "has to be clearly visible" at
## normal play zooms: it was full only to 38 tiles, then 51, and still faded a step or two out from
## the default zoom at 1080p. These hold it from the closest zoom to past twice the default; only the
## long zooms lose it (it costs the depth pre-pass's normals; Settings > Graphics > Ambient occlusion).
const SSAO_FULL := 0.04
const SSAO_GONE := 0.085
## SSAO goes off below this share of its strength and comes back on above ON_AGAIN.
const SSAO_OFF := 0.02
const SSAO_ON_AGAIN := 0.06
## The contact rims, per pixel (a rim is about 0.06 tiles wide: past RIM_GONE it is under a pixel and
## would shimmer; a building's rim reaches 0.27 tiles, two pixels at RIM_GONE). Further than SSAO's:
## they cost nothing and Factorio's own view shows them. Full to about 100 tiles off at 1080p.
const RIM_FULL := 0.06
const RIM_GONE := 0.14
## A view whose middle doesn't meet the ground (first person looking at the horizon) is measured this
## far off (tiles).
const NO_GROUND := 40.0
## The renderer is told again at least this often (seconds), in case something set the Environment's
## SSAO with unchanged values (which pushes the unfaded ones).
const REPUSH := 0.5

const SSAO_KEYS := ["ssao_enabled", "ssao_radius", "ssao_intensity", "ssao_power", "ssao_detail", "ssao_horizon",
	"ssao_sharpness", "ssao_light_affect", "ssao_ao_channel_affect"]

var env: Environment
## How much of SSAO shows (0-1), and whether it is on now (after the hysteresis).
var ssao_share := 1.0
var ssao_on := false
## The view's tiles per pixel this frame (for tests and the F4 line).
var tiles_per_pixel := 0.0
var _pushed: Array = []
var _since_push := 0.0


func _process(delta: float) -> void:
	if env == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	tiles_per_pixel = view_tiles_per_pixel(cam, get_viewport().get_visible_rect().size)
	ssao_share = 1.0 - smoothstep(SSAO_FULL, SSAO_GONE, tiles_per_pixel)
	var wanted := env.ssao_enabled
	if not wanted:
		ssao_on = false
	elif ssao_on and ssao_share < SSAO_OFF:
		ssao_on = false
	elif not ssao_on and ssao_share > SSAO_ON_AGAIN:
		ssao_on = true
	var values: Array = [wanted, ssao_on, snappedf(ssao_share, 0.01)]
	for key in SSAO_KEYS:
		values.append(env.get(key))
	_since_push += delta
	if values == _pushed and _since_push < REPUSH:
		return
	_pushed = values
	_since_push = 0.0
	var k := snappedf(ssao_share, 0.01)
	RenderingServer.environment_set_ssao(env.get_rid(), ssao_on, env.ssao_radius, env.ssao_intensity * k,
		env.ssao_power, env.ssao_detail, env.ssao_horizon, env.ssao_sharpness, env.ssao_light_affect * k,
		env.ssao_ao_channel_affect * k)


## Tiles per pixel where the view looks: orthographic, its size over the screen's height; perspective,
## at the ground (height 0) under the screen's middle, or NO_GROUND off when it doesn't meet it.
static func view_tiles_per_pixel(cam: Camera3D, screen: Vector2) -> float:
	var h := maxf(screen.y, 1.0)
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		return cam.size / h
	var origin := cam.global_position
	var forward := -cam.global_transform.basis.z
	var t := NO_GROUND
	if forward.y < -0.02 and origin.y > 0.0:
		t = minf(origin.y / -forward.y, NO_GROUND * 4.0)
	return t * 2.0 * tan(deg_to_rad(cam.fov) * 0.5) / h
