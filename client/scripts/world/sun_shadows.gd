extends Node
## The sun's shadow map fitted to the ground the camera sees (Settings > Graphics > Shadows).
##
## Godot draws every shadow caster in the light's box once per split, and the splits cover the
## camera's view out to directional_shadow_max_distance whether or not there is anything to see
## there. From the angled view the ground runs out at the top of the screen about 40 tiles from
## the camera, so a fixed 150 with four splits drew one split of air by the camera and two of
## casters under the ground beyond the view (and world.gd let every chunk out there cast). Here
## the distance follows the camera: just past the furthest ground in view (the shadows fade out
## beyond the top of the screen), on a ladder of steps so zooming changes it now and then, not
## every frame. The nearest ground in view is then at least half as far as the furthest, so one
## map covers it all as sharply as the splits did (a 4096 map over the default view: 55 texels a
## tile, against 41 to 102 before), drawing the casters once instead of in three splits. Only
## when the view reaches far beyond the nearest ground (first person, a low tilt) do Godot's own
## cascades take over, out to the quality's cap.
##
## Measured on a copy of the owner's save at the busy belts (High, the default view, noon), against
## the fixed 150 tiles and four splits on an 8192 atlas: the sun's shadows cost 3.7 ms of GPU and
## 1.0 ms of render CPU a frame; one fitted 4096 map costs 2.2 and 0.7 ms less (shadow draws 1,270
## -> 390, triangles 1.5 -> 0.5 million). A second split cost more than it saved (each is drawn in
## full), and so did 8192 (+1.4 ms for sharper shadows than before).

## Ultra's filter: Soft High's 16 PCF taps on the 8192 map; PCSS caps at Soft Medium (12 + 12 taps
## instead of 24 + 24) to keep contact-hardening shadows affordable.
const ULTRA_FILTER := RenderingServer.SHADOW_QUALITY_SOFT_HIGH
const PCSS_MAX_FILTER := RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM

## Per quality: splits (1 = one map; 2 or 4), the splits when the view reaches far (first
## person), the shadow atlas, the furthest the shadows reach (tiles from the camera), where they
## start to fade (a fraction of the distance), whether neighbouring splits blend, the soft filter
## (RenderingServer.ShadowQuality) and, Low only, a fixed blur (Light3D.shadow_blur): the others'
## blur is fitted to the map's texels a tile (blur_for), so a shadow's edge keeps one width on the
## ground. "items": how far the camera may be from the belt items round the character for their
## models to cast shadows (belt_items.gd shadows_within; 0 none: Low).
##
## The owner: shadows "very unstable and flickering around the edges especially when moving ...
## extremely blurry with holes even when zoomed in". High and Ultra had Soft Low's 4 taps spread over a
## blur, grainy without temporal anti-aliasing (Godot's docs: Soft Medium or higher against the dither),
## and the Cinematic look's sun size (1.4 degrees, PCSS) searched for blockers over some 200 texels with
## 8 taps, missing thin casters (holes) and hard at contacts. Now: Soft Medium (8 taps) on High and
## Soft High (16 taps PCF, capped at Soft Medium under PCSS) on Ultra, the blur fitted, and PCSS only
## when a look asks for it. No screen-space anti-aliasing cleans shadow
## noise (only TAA or FSR2 average it, and both ghost on belts and arms), so the filter leaves none to clean.
const QUALITY := {
	"low": {"splits": 1, "horizon_splits": 2, "atlas": 2048, "cap": 80.0, "fade": 0.8, "blend": false, "filter": RenderingServer.SHADOW_QUALITY_SOFT_VERY_LOW, "blur": 1.0, "items": 0.0},
	"medium": {"splits": 1, "horizon_splits": 2, "atlas": 4096, "cap": 110.0, "fade": 0.8, "blend": false, "filter": RenderingServer.SHADOW_QUALITY_SOFT_LOW, "items": 18.0},
	"high": {"splits": 1, "horizon_splits": 4, "atlas": 4096, "cap": 150.0, "fade": 0.8, "blend": false, "filter": RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM, "items": 25.0},
	"ultra": {"splits": 1, "horizon_splits": 4, "atlas": 8192, "cap": 200.0, "fade": 0.8, "blend": true, "filter": ULTRA_FILTER, "items": 35.0},
}
## --shadow-filter=old: each quality's filter and fixed blur before (Soft Low's 4 taps on High and Ultra,
## High blurred 0.6 texels), the look's sun size passed straight through at any quality, pancake 20.
const OLD_FILTER := {
	"low": {"filter": RenderingServer.SHADOW_QUALITY_SOFT_VERY_LOW, "blur": 1.0},
	"medium": {"filter": RenderingServer.SHADOW_QUALITY_SOFT_LOW, "blur": 1.0},
	"high": {"filter": RenderingServer.SHADOW_QUALITY_SOFT_LOW, "blur": 0.6},
	"ultra": {"filter": RenderingServer.SHADOW_QUALITY_SOFT_LOW, "blur": 1.0},
}
static var old_filter := "--shadow-filter=old" in OS.get_cmdline_user_args()
## The PCF filter's radius in texels at shadow_blur 1 for each soft filter quality: Godot's own
## (renderer_scene_render_rd.cpp, directional_soft_shadow_filter_set_quality, 4.7.2).
const QUALITY_RADIUS := {
	RenderingServer.SHADOW_QUALITY_HARD: 1.0, RenderingServer.SHADOW_QUALITY_SOFT_VERY_LOW: 1.5,
	RenderingServer.SHADOW_QUALITY_SOFT_LOW: 2.0, RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM: 2.0,
	RenderingServer.SHADOW_QUALITY_SOFT_HIGH: 3.0, RenderingServer.SHADOW_QUALITY_SOFT_ULTRA: 4.0,
}
## A shadow edge's radius on the ground, in tiles, when the look gives none (`shadow_edge`): Factorio's
## own, measured on its HR shadow sprites (a 10-90% edge of 1-2 px at 64 px a tile). Never under
## MIN_TEXELS of the map (its stair-steps and the crawl of a turning light would show), never over the
## filter's own radius (grain).
const EDGE := 0.02
const MIN_TEXELS := 1.0
## The blur is set again only when the fit moves it by more than this (a fraction).
const BLUR_STEP := 0.05
## The shadow camera's pancake (DirectionalLight3D.directional_shadow_pancake_size): Godot's 20 tiles,
## and 8 while the sun has a size (PCSS): its blocker search reaches from the pixel to the pancake's
## near plane, so a shorter one is a smaller, denser search (fewer holes). --shadow-pancake=<tiles>
## sets the PCSS one.
const PANCAKE := 20.0
const PCSS_PANCAKE := 8.0
static var pcss_pancake := _pancake_arg()
## The view reaches "far" (cascades, horizon_splits) once the shadows' distance is this many times
## the nearest ground in view; back to one map below the second figure. The distance compared is
## what the view needs (its furthest ground over the fade, at most the cap), not the ladder's step:
## the step never goes under MIN_DISTANCE, which zoomed right in was more than four times the
## nearest ground, so the ordinary close view got cascades (half the texels on Low and Medium, a
## hard seam by the character on High).
const FAR_RATIO := 4.0
const NEAR_RATIO := 3.5
## The shortest distance (zoomed right in) and the ladder's step: each is this much longer. Zoomed
## right in the ground in view ends 10-22 tiles from the camera; 32 spread the map over a sphere
## about 26 tiles across (74 texels a tile on 4096, against some 570 screen pixels a tile at 4K).
const MIN_DISTANCE := 12.0
const OLD_MIN_DISTANCE := 32.0
const STEP := 1.15
## A shorter step is only taken once the view needs this much less than it (so zooming back and
## forth across a step doesn't flip it).
const HYSTERESIS := 0.9
const BeltItems := preload("res://scripts/world/belt_items.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const MODES := {1: DirectionalLight3D.SHADOW_ORTHOGONAL, 2: DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS, 4: DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS}
## --legacy-render: the shadows as they were before (a fixed 150 tiles, four splits, two on Low;
## and model_lods.gd's levels of detail), for comparisons.
const LEGACY_ATLAS := {"low": 2048, "medium": 4096, "high": 8192, "ultra": 8192}
static var legacy := "--legacy-render" in OS.get_cmdline_user_args()
## --soft-shadow-atlas=<size> (off by default: the quality's own map; 4096 measured): while the sun has an angular
## size (a look's soft shadows, the Cinematic look's) its shadow map is at most this big. The penumbra
## blurs away what Ultra's 8192 map adds, and on it the soft filter's blocker search and taps (8 + 8 a
## lit pixel, on every layer of blended ground clutter) land twice as many texels apart, which the GPU's
## texture cache handles worse. Measured at 4K on the owner's desktop under the Cinematic look at Ultra:
## 1.5 ms less, a still the same (art-src/perf-plans/after.md 5); nothing at Low and High, whose maps
## are 4096 or less. Off by default again (owner): close up on the character the soft shadows' edges came
## out stair-stepped at 4096. The stutter probe's "soft shadow atlas <size>" sets it for one step.
const SOFT_ATLAS_DEFAULT := 0
static var soft_atlas_cap := _soft_atlas_arg()
## --shadow-fit=old: the fit as it was before the shadows' stability work: the far test against the
## ladder's distance, the ground measured at y = 0 under a camera riding the hills (each hill walked
## over could flip the mode or the distance step, every shadow popping as the map moved), a
## 32-tile shortest distance, and split fractions set in one-map mode too.
static var old_fit := "--shadow-fit=old" in OS.get_cmdline_user_args()
## The furthest ground is measured against a plane this far under the ground at the screen's
## centre (with hills on), so the valleys beyond it keep their shadows.
const VALLEY := 1.5


static func _pancake_arg() -> float:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shadow-pancake="):
			return maxf(float(arg.get_slice("=", 1)), 0.1)
	return PCSS_PANCAKE


static func _soft_atlas_arg() -> int:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--soft-shadow-atlas="):
			return maxi(int(arg.get_slice("=", 1)), 0)  # ("off" reads as 0)
	return SOFT_ATLAS_DEFAULT

var sun: DirectionalLight3D
var quality := "high"
var spec: Dictionary = QUALITY["high"]
## Settings > Graphics > Shadow distance: the furthest the shadows reach, tiles from the camera, in
## place of the quality's cap; 0 (Automatic) keeps the quality's. The shadows still stop just past
## the ground in view: this only lets them go further when zoomed out (and spreads the same map
## over more ground, so they are softer), or stops them sooner.
var distance_cap := 0.0
## The ground in view now: [nearest, furthest] depth from the camera (furthest INF: the horizon).
var view_depths := Vector2.ZERO
## Whether the view reaches far now (Godot's cascades rather than one map).
var far_view := false
## The shadow atlas set now (atlas_for), 0 before the first.
var atlas := 0
## The sun's size in degrees a look asks for (looks.gd, its sun's light_angular_distance): above 0 the
## sun gets it, and Godot's contact-hardening soft shadows (PCSS); 0 the fitted PCF edge. sun_shadows.gd
## owns the sun's angular size, blur and pancake (set_look).
var sun_size := 0.0
## The look's shadow edge on the ground, tiles (looks.gd, `shadow_edge`).
var edge := EDGE
## The stutter probe's "blur <x>": a fixed shadow_blur in place of the fitted one (0: fitted).
var blur_override := 0.0
## The nearest split's texels a tile at the last fit (0 before one).
var texels := 0.0
## The stutter probe's "soft <quality>": a soft filter (RenderingServer.ShadowQuality) in place of the
## spec's, the blur fitted to its radius (-1: the spec's).
var filter_override := -1
var _applied_filter := -1


func _ready() -> void:
	process_priority = 10  # after the camera rig has moved the camera this frame


## Settings > Graphics > Shadows: off, low, medium, high, ultra.
func apply_quality(q: String) -> void:
	quality = q if QUALITY.has(q) else "high"
	if legacy:
		apply_legacy()
		return
	set_process(true)
	apply_spec(spec_for(quality))


## A quality's QUALITY entry, with the old filter and blur under --shadow-filter=old.
static func spec_for(q: String) -> Dictionary:
	if not old_filter:
		return QUALITY[q]
	var s: Dictionary = (QUALITY[q] as Dictionary).duplicate()
	s.merge(OLD_FILTER[q], true)
	return s


## The shadows as they were before this fitting (--legacy-render, --probe-variants' "legacy render").
func apply_legacy() -> void:
	set_process(false)
	if sun == null:
		return
	RenderingServer.directional_shadow_atlas_set_size(int(LEGACY_ATLAS[quality]), true)
	RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_LOW)
	sun.directional_shadow_max_distance = 150.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if quality == "low" else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_split_1 = 0.1
	sun.directional_shadow_split_2 = 0.2
	sun.directional_shadow_split_3 = 0.5
	sun.directional_shadow_fade_start = 0.8
	sun.directional_shadow_blend_splits = false
	sun.shadow_blur = 1.0
	sun.light_angular_distance = sun_size
	sun.directional_shadow_pancake_size = PANCAKE


## Sets the shadows from a QUALITY entry (or one like it: --probe-variants' "fit ...").
func apply_spec(s: Dictionary) -> void:
	spec = s
	BeltItems.shadows_within = float(spec.get("items", 25.0))
	if sun == null:
		return
	apply_atlas(true)
	sun.directional_shadow_blend_splits = bool(spec["blend"])
	sun.directional_shadow_fade_start = float(spec["fade"])
	_applied_filter = filter_now()
	RenderingServer.directional_soft_shadow_filter_set_quality(_applied_filter)
	_fit(true)
	apply_soft(true)


## The soft filter in effect: the probe's override, else the spec's (capped at PCSS_MAX_FILTER under PCSS).
func filter_now() -> int:
	if filter_override >= 0:
		return filter_override
	var f := int(spec["filter"])
	if sun_size > 0.0 and not old_filter:
		return mini(f, PCSS_MAX_FILTER)
	return f


## The stutter probe's "soft <quality>" (-1: back to the spec's): the filter set and the blur refitted
## to its radius, so the edge on the ground keeps its width.
func set_filter_override(q: int) -> void:
	filter_override = q
	if sun == null or legacy:
		return
	_applied_filter = filter_now()
	RenderingServer.directional_soft_shadow_filter_set_quality(_applied_filter)
	apply_soft(true)


## What a look asks of the shadows (looks.gd): the sun's size in degrees (0: none, PCF) and the edge's
## radius on the ground in tiles.
func set_look(size: float, edge_tiles := EDGE) -> void:
	sun_size = maxf(size, 0.0)
	edge = edge_tiles if edge_tiles > 0.0 else EDGE
	if sun != null:
		if legacy:
			sun.light_angular_distance = sun_size
			return
		if soft_atlas_cap > 0:
			apply_atlas(false)
		apply_soft(true)


## The sun's angular size, blur and pancake for the look and the fit now. `force`: the blur set even
## when it moved by less than BLUR_STEP.
func apply_soft(force := false) -> void:
	if sun == null or legacy:
		return
	var f := filter_now()
	if force or f != _applied_filter:
		_applied_filter = f
		RenderingServer.directional_soft_shadow_filter_set_quality(f)
	var pcss := sun_size > 0.0
	if not is_equal_approx(sun.light_angular_distance, sun_size):
		sun.light_angular_distance = sun_size
	var pancake := pcss_pancake if pcss and not old_filter else PANCAKE
	if not is_equal_approx(sun.directional_shadow_pancake_size, pancake):
		sun.directional_shadow_pancake_size = pancake
	var blur := blur_now(spec, pcss, edge, texels, f)
	if blur_override > 0.0:
		blur = blur_override
	if force or absf(blur - sun.shadow_blur) > sun.shadow_blur * BLUR_STEP:
		sun.shadow_blur = blur


## The shadow_blur for a spec: its fixed blur when it has one (Low; every quality under
## --shadow-filter=old), 1.0 under PCSS (there it scales the blocker search), else fitted to `filter`
## (-1: the spec's).
static func blur_now(s: Dictionary, pcss: bool, edge_tiles: float, texels_a_tile: float, filter := -1) -> float:
	if s.has("blur"):
		return float(s["blur"])
	if pcss:
		return 1.0
	return blur_for(edge_tiles, texels_a_tile, filter if filter >= 0 else int(s["filter"]))


## The blur that draws an edge `edge_tiles` wide (radius, on the ground) on a map of `texels_a_tile`:
## its radius in texels, at least MIN_TEXELS and at most the filter's own radius, as a fraction of
## that radius (shadow_blur scales it).
static func blur_for(edge_tiles: float, texels_a_tile: float, filter: int) -> float:
	var radius := float(QUALITY_RADIUS.get(filter, 2.0))
	return clampf(edge_tiles * texels_a_tile, MIN_TEXELS, radius) / radius


func _process(_delta: float) -> void:
	_fit(false)


## The atlas for the spec and the sun now, set when it changed (or `force`).
func apply_atlas(force: bool) -> void:
	if sun == null:
		return
	var want := atlas_for(spec, sun_size)
	if force or want != atlas:
		atlas = want
		RenderingServer.directional_shadow_atlas_set_size(want, true)


## The shadow atlas for a QUALITY entry: its own, or at most soft_atlas_cap while the sun has an
## angular size (soft shadows).
static func atlas_for(s: Dictionary, angular_distance: float) -> int:
	var size := int(s["atlas"])
	if soft_atlas_cap > 0 and angular_distance > 0.0:
		return mini(size, soft_atlas_cap)
	return size


func _fit(force: bool) -> void:
	if sun == null or not sun.shadow_enabled:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	_fit_view(cam, force)
	# The edge's width on the ground: the blur follows the map's texels a tile (zooming moves the
	# distance and so the texels; a fixed blur doubled the edge between ladder steps). Kept current under
	# PCSS too (the blur ignores it there, but the probe prints it and PCSS going off uses it at once).
	if not old_filter and not spec.has("blur"):
		texels = texels_per_tile(cam, sun, atlas if atlas > 0 else int(spec["atlas"]))
	apply_soft(force)


func _fit_view(cam: Camera3D, force: bool) -> void:
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		view_depths = ground_depths(cam)
		_fit_ortho(force)
		return
	if old_fit:
		view_depths = ground_depths(cam)
	else:
		# Measured from the ground the camera looks at, which rides the hills with it: from y = 0 a
		# walk over hills changed the depths as much as zooming did.
		view_depths = ground_depths(cam, centre_ground(cam), VALLEY if GroundHeight.is_on() else 0.0)
	var cap := cap_for(spec, distance_cap)
	var fade := float(spec["fade"])
	var want := distance_for(view_depths.y, cap, -1.0 if force else sun.directional_shadow_max_distance, fade)
	if want != sun.directional_shadow_max_distance or force:
		sun.directional_shadow_max_distance = want
	# Looking far (the horizon, a low tilt) the nearest ground is many times nearer than the
	# furthest, which one map can't cover sharply: Godot's own cascades then. Judged by what the
	# view needs, not the ladder's step (which has a floor).
	far_view = reaches_far(view_depths, want if old_fit else minf(view_depths.y / fade, cap), far_view)
	var count := int(spec["horizon_splits"]) if far_view else int(spec["splits"])
	var mode: DirectionalLight3D.ShadowMode = MODES[count]
	var mode_changed := sun.directional_shadow_mode != mode
	if mode_changed:
		sun.directional_shadow_mode = mode
	if count == 1 and not old_fit:
		return  # one map: the fractions mean nothing
	var splits := split_fractions(Vector2(0.0, INF) if far_view else view_depths, want, count, float(spec.get("split_at", 0.5)))
	# Only when they move by more than a little: each change shifts the splits' texel grid.
	if force or mode_changed or absf(splits.x - sun.directional_shadow_split_1) > 0.02 or absf(splits.y - sun.directional_shadow_split_2) > 0.02 \
			or absf(splits.z - sun.directional_shadow_split_3) > 0.02:
		sun.directional_shadow_split_1 = splits.x
		sun.directional_shadow_split_2 = splits.y
		sun.directional_shadow_split_3 = splits.z


## Under an orthographic camera (Factorio's view, F6; the map's remote view) Godot's one fitted map
## and fitted splits drew no shadows of buildings at all (only of robots, whose MultiMeshes have a
## huge box): its directional shadow fitting assumes a perspective view. The fixed cascades from
## before the fitting draw them (seen against the mock and real 2.1.24), so they are used there.
func _fit_ortho(force: bool) -> void:
	var want := minf(cap_for(spec, distance_cap), 150.0)
	var mode := DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if quality == "low" else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	far_view = false
	if force or sun.directional_shadow_max_distance != want or sun.directional_shadow_mode != mode:
		sun.directional_shadow_max_distance = want
		sun.directional_shadow_mode = mode
		sun.directional_shadow_split_1 = 0.1
		sun.directional_shadow_split_2 = 0.2
		sun.directional_shadow_split_3 = 0.5


## Texels a tile in the nearest split, as Godot fits it: a sphere round the camera's frustum from its
## near plane to the split's end, over the atlas (half of it on one axis in split modes). `last`: the
## furthest split's instead (a split mode's coarsest, over the far part of the view).
static func texels_per_tile(cam: Camera3D, light: DirectionalLight3D, atlas_size: int, last := false) -> float:
	var d := light.directional_shadow_max_distance
	var one := light.directional_shadow_mode == DirectionalLight3D.SHADOW_ORTHOGONAL
	var start := cam.near
	var end := d if one else d * light.directional_shadow_split_1
	if last and not one:
		start = d * (light.directional_shadow_split_1 if light.directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS else light.directional_shadow_split_3)
		end = d
	var size := cam.get_viewport().get_visible_rect().size
	var aspect := size.x / maxf(size.y, 1.0)
	var basis := cam.global_basis
	var ortho := cam.projection == Camera3D.PROJECTION_ORTHOGONAL
	var t := tan(deg_to_rad(cam.fov * 0.5))
	var pts: Array[Vector3] = []
	for z: float in [start, end]:
		var h := cam.size * 0.5 if ortho else z * t
		for sx: float in [-1.0, 1.0]:
			for sy: float in [-1.0, 1.0]:
				pts.append(cam.global_position + basis * Vector3(sx * h * aspect, sy * h, -z))
	var centre := Vector3.ZERO
	for p in pts:
		centre += p / pts.size()
	var r := 0.0
	for p in pts:
		r = maxf(r, centre.distance_to(p))
	return float(atlas_size) * (1.0 if one else 0.5) / (2.0 * maxf(r, 0.001))


## The nearest and furthest ground the camera sees, as depths along its view: from the rays through
## the screen's corners and edges' middles to the plane y = `ground_y` (the furthest to one `below`
## lower). The furthest is INF when a ray along the top edge doesn't come down to the ground (the
## horizon is in view).
static func ground_depths(cam: Camera3D, ground_y := 0.0, below := 0.0) -> Vector2:
	var size := cam.get_viewport().get_visible_rect().size
	var forward := -cam.global_basis.z
	var nearest := INF
	var furthest := 0.0
	var low := ground_y - below
	for p: Vector2 in [Vector2.ZERO, Vector2(size.x * 0.5, 0.0), Vector2(size.x, 0.0), Vector2(0.0, size.y), Vector2(size.x * 0.5, size.y), size]:
		var origin := cam.project_ray_origin(p)
		var ray := cam.project_ray_normal(p)
		if origin.y <= ground_y or ray.y > -0.02:
			furthest = INF
			nearest = minf(nearest, maxf(cam.near, 0.0))
			continue
		var hit := origin + ray * ((ground_y - origin.y) / ray.y)
		nearest = minf(nearest, (hit - cam.global_position).dot(forward))
		var far_hit := origin + ray * ((low - origin.y) / ray.y)
		furthest = maxf(furthest, (far_hit - cam.global_position).dot(forward))
	return Vector2(nearest, furthest)


## The ground's height where the ray through the screen's centre meets the hills (Terrain
## Elevation's field); 0 on flat ground or when the ray misses.
static func centre_ground(cam: Camera3D) -> float:
	if not GroundHeight.is_on():
		return 0.0
	var size := cam.get_viewport().get_visible_rect().size
	var hit: Variant = GroundHeight.ray_hit(cam.project_ray_origin(size * 0.5), cam.project_ray_normal(size * 0.5))
	if hit == null:
		return 0.0
	var at: Vector3 = hit
	return GroundHeight.at(at.x, at.z)


## The shadow distance for ground in view out to `furthest`: past it by the fade (Godot's shadows
## fade out from `fade` of the distance on, so the fade starts past the top of the screen), on the
## The shadows' cap: the setting's distance when one is chosen, else the quality's.
static func cap_for(s: Dictionary, chosen: float) -> float:
	return chosen if chosen > 0.0 else float(s["cap"])


## ladder (MIN_DISTANCE x STEP^n), at most `cap`. `current` (-1: none) is kept while the view needs
## a little less than it.
static func distance_for(furthest: float, cap: float, current: float, fade := 0.8) -> float:
	var need := minf(furthest / fade, cap)
	var step := OLD_MIN_DISTANCE if old_fit else MIN_DISTANCE
	while step < need and step < cap:
		step *= STEP
	step = minf(snappedf(step, 0.1), cap)
	if current > 0.0 and step < current and need > current / STEP * HYSTERESIS and current <= cap:
		return current
	return step


## Whether shadows out to `distance` reach far beyond the nearest ground in view (`depths`, from
## ground_depths), so cascades beat one map; `now` is the answer so far (hysteresis).
static func reaches_far(depths: Vector2, distance: float, now: bool) -> bool:
	if depths.y == INF:
		return true
	return distance > depths.x * (NEAR_RATIO if now else FAR_RATIO)


## Where the splits end, as fractions of the distance (DirectionalLight3D.directional_shadow_split_*):
## the ground in view shared out between them (two splits meet `at` of the way from its nearest to
## its furthest). With the horizon in view, Godot's defaults.
static func split_fractions(depths: Vector2, distance: float, splits: int, at := 0.5) -> Vector3:
	if depths.y == INF or distance <= 0.0:
		return Vector3(0.1, 0.2, 0.5)
	var start := clampf(depths.x / distance, 0.0, 0.9)
	var end := clampf(depths.y / distance, start + 0.05, 1.0)
	if splits == 2:
		return Vector3(lerpf(start, end, at), 0.2, 0.5)
	return Vector3(lerpf(start, end, 0.25), lerpf(start, end, 0.5), lerpf(start, end, 0.75))
