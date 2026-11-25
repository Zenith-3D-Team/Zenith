extends Node3D
## Looks: how the 3D world is lit, tonemapped and graded, picked in Settings > Graphics > Look and
## open to add-ons (api.shaders, docs/ADDONS.md).
##
## A look is a Dictionary (every key optional):
##   name, description          for the settings' list
##   tonemap                    Environment.TONE_MAPPER_*; exposure, white: its exposure and white point
##   sun_energy, ambient_energy multipliers on the planet's light for the time of day (sky.gd)
##   ambient_energy_lit         the ambient's multiplier in daylight under the lighting environment (put_light_env),
##                              moving to ambient_energy by night; absent: ambient_energy. With --light-env=shader
##                              ambient_energy alone (0.2.2's)
##   ambient_tint               Color the planet's ambient colour moves towards, by ambient_tint_amount
##   sun_angle                  Vector2(pitch, yaw) in degrees: the sun held there (Factorio's shadows
##                              don't move), or absent for sky.gd's sun that crosses the sky
##   sun_noon_yaw               degrees (a DirectionalLight3D's yaw: 0 south, 90 east): where that sun stands at noon
##                              (absent: sky.gd YAW_NOON, -30, high behind the default view); it still rises
##                              in the east and sets in the west
##   factorio_lut               true: Factorio's own colour lookup for the planet and time of day
##   model_fill                 light from the camera's side on models only (Factorio's sprites are lit
##                              so), faded out by night. Off by default (owner: every model lit by the scene's
##                              sun and ambient alone): only drawn with --model-fill=on (the look's) or a number,
##                              or the debug menu's Camera fill slider; it follows the ambient the sliders set
##   fill_light                 a second sun's energy, no shadow, from the camera's side and a little above, on what
##                              stands on the ground and not the ground (Visuals.GROUND_LAYER), so shaded fronts
##                              aren't black, as Factorio's sprites are rendered with a fill (lighting-fixes step 3);
##                              faded out by night; absent or 0: none. --fill-light=off or a number wins
##   ground_specular            0-1: how much the ground, decals and grass reflect (1: as Zenith draws them)
##   ao_direct                  0-1: how much of their occlusion (their own and SSAO's) darkens models' and the ground's
##                              direct (sun and lamp) light (absent: 1, as Zenith draws them; 0: occlusion on indirect light only, with the
##                              environment's ssao_light_affect then the only SSAO on direct light)
##   roughness_min              0-1: no model's surface shinier than this (small shiny parts, bolts,
##                              arms, belt rollers, flash highlights smaller than a pixel as they move). Built-in
##                              packs and icon-coloured items only: a "pbr" pack's surfaces and a modeller's items
##                              keep the roughness their files give (--pbr-rough=floor: the floor on them too, 0.2.2)
##   texture_metal              0-1: the share of a modeller's metallic-roughness picture's metal drawn
##                              (absent: 0.1, as paint, the share every other surface gets; 1: in full).
##                              --texture-metal wins over it
##   texture_light              Vector2(sides, tops): the light balance on a "pbr" pack's pictures (model_packs.gd
##                              shading(); absent: (1, 1), as Godot's own material draws them). Factorio's
##                              part colours keep their own (0.95, 0.6): their colours have light in them
##   pbr_env                    0-2: the neutral reflection a "pbr" pack's surfaces see (shaders/pbr_env.gdshaderinc):
##                              its upper half the ambient plus this much of the sun (absent: 0.45, a rough metal
##                              about as bright as paint of its colour); --pbr-env=off or a number wins
##   pbr_metal                  0-1: the share of a "pbr" pack's metal drawn (absent: 1, in full); --pbr-metal wins
##   pbr_fill, pbr_ambient      0-2: a "pbr" pack's share of model_fill and of the ambient (absent: PBR_FILL,
##                              PBR_AMBIENT), its ambient and neutral reflection then lit by direction (brighter
##                              towards the sky and the sun, darker below; shaders/pbr_env.gdshaderinc), so the sun
##                              decides its light and shaded sides; --pbr-light=flat: all as before (1, 1, uniform)
##                              (the fill and the reflection follow the debug menu's sun and ambient sliders unless
##                              --pbr-light-scene=off)
##   env_ground                 Color, linear: the ground's albedo in the lighting environment's lower half (absent:
##                              LIGHT_ENV_GROUND), lit there by the sun on flat ground plus the ambient (put_light_env)
##   env_glow                   0-1: a wide glow towards the sun in its upper half, as a share of the sun (absent: 0)
##   roughness_limiter          Vector2(amount, limit): Godot's screen-space roughness limiter while the
##                              look is on (absent: as the project has it)
##   taa                        true: temporal anti-aliasing while the look is on, whatever Settings says
##   own_clouds                 false: Zenith's own clouds are off while the look is on (it draws its own)
##   twilight                   0-1: how much of a real sunrise and sunset it gets (sky.gd's sun that
##                              sets, its colour through the air, the ambient, the sky); absent or 0:
##                              the old sun that never sets
##   sky_twilight               0-1: the same for the sky alone (a look may hold its light still and
##                              still see the sun set); absent: as twilight
##   at_twilight, at_dawn       {environment: {}, sun: {}, params: {}}: values of those three that the
##                              look moves towards as the sun nears the horizon (at_dawn in the
##                              morning, over at_twilight's); numbers and colours only
##   fog_from_sky               0-1: how far the fog's colour takes the sky's on the sun's side at twilight
##   environment                {Environment property: value} set while the look is on
##   sun                        {DirectionalLight3D property: value}, only SUN_KEYS; its
##                              light_angular_distance (the sun's size: contact-hardening soft
##                              shadows) goes to sun_shadows.gd, which owns the sun's size and blur
##   shadow_edge                tiles: the radius of the shadows' edge on the ground (absent: 0.02,
##                              Factorio's own), the blur fitted to it (sun_shadows.gd)
##   passes                     [{shader: Shader or "res://..."/add-on path, params: {}}] full-screen passes
##
## The look in use is applied every frame after sky.gd has set the planet's light (main.gd), so its
## multipliers act on the light of that moment. Passes are full-screen quads in the transparent pass
## (shaders/look_pass.gdshaderinc): each reads the scene as it was before see-through things were
## drawn (Godot copies the screen once), so smoke, ghosts and icons stay ungraded.

const LookLuts := preload("res://scripts/world/look_luts.gd")
const SunShadows := preload("res://scripts/world/sun_shadows.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const PlanetSky := preload("res://scripts/world/sky.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const WeatherState := preload("res://scripts/world/weather_state.gd")
const REACTIVE_CLEAR_SHADER := preload("res://shaders/look_reactive_clear.gdshader")
const Switches := preload("res://scripts/switches.gd")

signal look_changed(id: String)

## On a space platform, whatever the look: no air, so no haze or fog (a look's fog, lit and seen
## against the sky, turned black space grey-blue) and no sky lighting the shade. The look's own
## values come back on the ground.
const SPACE_ENV := {"fog_enabled": false, "ambient_light_sky_contribution": 0.0}

## Properties of the sun a look may set (the rest belong to sun_shadows.gd and sky.gd).
const SUN_KEYS := ["light_angular_distance", "shadow_opacity", "light_specular", "light_indirect_energy",
	"shadow_bias", "shadow_normal_bias"]

## Measured against Factorio's own picture of the same scene at noon (tools/look/factorio_reference.py,
## a seed-123456 map in 2.1.24, Zenith's default settings): the open ground's colour 92.5/68.7/28.8
## against Factorio's 89.8/68.4/28.5, saturation 0.689 against 0.688 (Classic: 129.6/100.7/54.3,
## 0.573). What had washed the picture out: the sky's reflection on every surface (a grey-blue sheen
## on the ground, saturation 0.54 -> 0.69 without it) and the filmic tonemapper's shoulder; the
## sun's glare is a quarter of Godot's. Factorio's shadows are about half as bright as lit ground
## on screen (0.51, a quarter of its light), so the ambient is lower and the sun stronger, and they
## fall to the east, a little south, as long as the thing is tall: the sun held there.
const FACTORIO := {
	"name": "Factorio",
	"description": "Lit and coloured to match Factorio's own pictures: its shadows' angle and darkness, its colours unwashed, its colour grading per planet and time of day.",
	"tonemap": Environment.TONE_MAPPER_LINEAR, "exposure": 0.9, "white": 1.0,
	"sun_energy": 1.45, "ambient_energy": 0.36,
	# lighting-fixes step 2: the shade lit so flat ground is about 4.5:1 between sun and shadow (0.36 gave about 9:1,
	# 6.0 on screen; 0.8 measured 4.6 in scene light, 3.87 on screen through the LUT, so 0.7: about 5.1 and 4.3),
	# tuned when a camera fill nine times the ambient lit every model's shade), as Factorio's own ground in and out of a
	# shadow (a quarter of its light, above). By day; nights keep 0.36.
	"ambient_energy_lit": 0.7,
	"ambient_tint": Color(0.8, 0.8, 0.82), "ambient_tint_amount": 0.5,
	"sun_angle": Vector2(-42.0, -112.0),
	"factorio_lut": true,
	# Factorio draws no sky, so seen from low down the sun may set, restrained, while the light stays.
	"twilight": 0.0, "sky_twilight": 0.35,
	"ground_specular": 0.45, "model_fill": 1.1,
	# lighting-fixes step 3: a fill from the camera's side on what stands on the ground (not the ground), as Factorio's
	# sprites are rendered with one: models' shaded fronts were darker than the shadows they cast.
	"fill_light": 0.35,
	# The sun's highlight at half Godot's: Factorio's sprites show modest highlights (0.25 before 0.2.3, cut when the
	# only reflection was a dim blue sky; metal has no diffuse light, so its sun was that alone). --sun-specular wins.
	"sun": {"light_specular": 0.5},
	"roughness_limiter": Vector2(0.5, 0.22),
}
## Zenith's look before 0.1.4: filmic tonemapping, the sun crossing the sky.
const CLASSIC := {
	"name": "Classic Zenith",
	"description": "Zenith's look before: filmic tonemapping, a sun that crosses the sky.",
	"tonemap": Environment.TONE_MAPPER_FILMIC, "exposure": 1.0, "white": 1.0,
	"sun_energy": 1.0, "ambient_energy": 1.0,
}

## Every look, shared by the menu's settings and the game: id -> look Dictionary (add-ons' looks
## carry "owner", their add-on id), in the order they were added.
static var looks := {}
static var order: Array[String] = []
## The node drawing the game's look, while a game is on.
static var active: Node = null
## --grade-focus-uniform=off: read centre-screen depth in the grade pass on every pixel instead of passing focus distance.
static var grade_focus_uniform := Switches.on("--grade-focus-uniform")
## --fast-night-clouds=off: keep 14 sky-cloud march steps and solar scattering lookups at deep night.
static var fast_night_clouds := Switches.on("--fast-night-clouds")

## A look's texture_metal when it has none, and the menu's and model preview's (project.godot): a
## picture's metal drawn as paint, as part colours and Factorio's sprites are. In full, metal shows
## only the sky's reflection, which Zenith keeps dim and blue, so a modeller's metal read dark and blue
## where Blender shows it at about its base colour (metal-look-rd).
const TEXTURE_METAL := 0.1
## A look's texture_light when it has none, and the menu's and model preview's (project.godot): a "pbr"
## pack's base colour picture has no light in it, so its tops and sides are lit as Godot's material
## lights them (pbr-rd: Factorio's (0.95, 0.6) held his drill at 0.73 of its base colour).
const TEXTURE_LIGHT := Vector2(1.0, 1.0)
## A look's pbr_env when it has none: the sun's share in the neutral reflection of a "pbr" pack's surfaces. Set so a
## rough metal sphere draws about as bright as a paint one of the same colour in the Factorio look at noon (an
## estimate from Godot's own formulas, 0.37 at roughness 0.7 and 0.53 at 1; ui_test.gd _pbr_reference measures it).
const PBR_ENV := 0.45
## A look's pbr_metal when it has none: a "pbr" pack's metal in full, with the neutral reflection to reflect.
const PBR_METAL := 1.0
## A look's pbr_fill and pbr_ambient when it has none: a "pbr" pack's share of the look's fill light and of the
## ambient. The Factorio look's fill (1.1, from the camera's side) is about nine times its ambient, so it lit every
## side a model shows about as the sun does. Aimed at about 4:1 between the sun's side and the shade (linear, on
## screen), as Factorio's own ground in and out of a shadow (FACTORIO above) and a viewer's one sun over a dim sky, so
## a model's shade matches the shadow it casts. Measured in the Factorio look at noon (ui_test.gd _pbr_light), flat
## then with these: a matte sphere 2.16 -> 4.54, rough metal 1.44 -> 4.84, the modeller's electric drill 1.63 ->
## 4.69 and rock (iron-ore-1) 1.08 -> 2.90. The fill decides it (0.15: 6.4, 0.45: 3.6 on the sphere); the ambient
## share hardly does (0.7: 4.81, 1.5: 4.12), so it stays whole and comes down by direction instead (pbr_env.gdshaderinc:
## the sky's on tops, 0.675 of it on sides, 0.35 below).
const PBR_FILL := 0.3
const PBR_AMBIENT := 1.0
## The sun lobe's height and the downward-face ambient share of a pbr surface (pbr_env.gdshaderinc's defaults; the
## debug menu's Lighting tab moves them, f3d_pbr_tune).
const PBR_SUN_LOBE := 2.8
const PBR_GROUND := 0.35
## The lighting environment (lighting-fixes step 1): every material's ambient light and reflections come from the sky's
## cubemap, which planet_sky.gdshader draws as this environment in a game (put_light_env), not from a constant colour
## and per-shader terms. The ground's albedo there when a look gives none (linear; a sunlit dirt-and-grass mean, about
## Factorio's Nauvis ground desaturated) and the cubemap's size (a smooth two-hemisphere gradient: 32 is plenty).
const LIGHT_ENV_GROUND := Color(0.25, 0.23, 0.19)
const LIGHT_ENV_RADIANCE := Sky.RADIANCE_SIZE_32
## The fill light (fill_light): how far above the horizon it comes from, how far to the camera's right (the side away
## from the Factorio look's sun in the west), and its highlight (low: a flash's glare on metal faces otherwise).
## Night vision equipment's lift at full (apply()'s night_vision): the ambient it adds and the colour it leans to.
## 2.6: night vision lifts the night close to a dim day (owner: brighter); --night-vision-fx=old keeps 1.4.
const NIGHT_VISION_AMBIENT := 2.6
const NIGHT_VISION_AMBIENT_OLD := 1.4
const NIGHT_VISION_COLOR := Color(0.62, 0.86, 0.62)
## --tree-sheen=old (or --grass-backlight=old): trees as 0.2.2 drew them, specular 0.5-0.2 with a white sheen at
## grazing angles (the shaders' f3d_tree_matte 0).
static var tree_sheen_old: bool = Switches.has("--tree-sheen=old") or Switches.has("--grass-backlight=old")
const FILL_PITCH := 35.0
const FILL_YAW := 20.0
const FILL_SPECULAR := 0.25
## Test hooks on the lighting environment: "sky", "ground" multipliers on its halves (1 absent). Nothing saved.
static var light_env_tune := {}
## The debug menu's Lighting tab's live values (dev builds): key (model_fill, pbr_fill, pbr_ambient, pbr_env, pbr_metal,
## pbr_sun_lobe, pbr_ground, pbr_directional) -> number. They win over the look and the command line; nothing saved.
static var pbr_tune := {}
## The debug menu's other Lighting sliders (dev builds): key -> number, put on the environment and the sun at the end
## of every apply(), so they win over the look and the time of day until reset. Environment keys are the property's
## own name (ssao_radius, ssil_intensity...; ssao_enabled and ssil_enabled 0 or 1), ambient_energy is
## ambient_light_energy; the sun's: sun_energy (light_energy), shadow_bias, shadow_normal_bias. Nothing saved.
static var light_tune := {}
## The neutral reflection outside a game (the menu, the model preview; project.godot's f3d_pbr_env): the Factorio
## look's at noon on Nauvis, linear.
const PBR_ENV_REST := Vector4(0.839, 0.797, 0.732, 1.0)
## f3d_pbr_light outside a game (the menu, the model preview; project.godot): flat, the fill and ambient in full
## (w: the fill's share for the scene's ambient, whole).
const PBR_LIGHT_REST := Vector4(0.0, 1.0, 1.0, 1.0)
## Packs' own shading in effect (pack_shading()): true, each pack as its pack.json says; false, Factorio's
## everywhere. Far chunks and item models read it when they are made (far_chunks.gd, item_models.gd).
static var packs_shade := true
## The game look's texture_light now (apply()), for far chunks' bakes.
static var light_now := TEXTURE_LIGHT

var env: Environment
var sun: DirectionalLight3D
## The sun's shadows (main.gd): a look's sun size and shadow edge are handed to it, the one place
## that sets the sun's angular size, blur and pancake. Without one (tests, a scene of its own) the
## sun size goes straight onto the sun as before.
var shadows: SunShadows
var current := "factorio"

var _base_env := {}  # property -> value before the current look set it
var _base_sun := {}
var _set_env: Array = []  # properties the current look set
var _set_sun: Array = []
var _pass_nodes: Array = []  # [MeshInstance3D] of the current look
var _reactive_clear: MeshInstance3D = null  # clears RB_TEX_COLOR.a right after LookPasses under FSR 2.2
## Passes over any look (api.shaders.add_pass), kept between games: id -> {spec, owner}; their
## nodes while a game is on in _extra_nodes (id -> MeshInstance3D).
static var extras := {}
static var _next_pass := 1
var _extra_nodes := {}
var _luts := LookLuts.new()
## What at_twilight and at_dawn move between: key -> [the look's own value, at_twilight's, at_dawn's]
## (a null target leaves it to the other one). _tw_params per pass node.
var _tw_env := {}
var _tw_sun := {}
var _tw_params := {}  # MeshInstance3D -> {param: [own, at_twilight's, at_dawn's]}
var _tw_last := -1.0
var _tw_morning := false
var _fog_base = null  # the look's own fog colour, with fog_from_sky
## This frame's sun (sky.gd), for api.shaders.sun().
var sun_state := {}


var _forced := ""
## --texture-metal=full or a number (texture_metal_arg), -1 without.
var _metal_arg := -1.0
## --pbr-env's number (pbr_env_arg) and switch (pbr_env_switch), --pbr-metal's share (pbr_metal_arg), read once in
## _ready: apply() runs every frame and must not parse the command line.
var _pbr_env_arg := -1.0
var _pbr_env_on := true
var _pbr_metal_arg := -1.0
## --pbr-light: true (directional, the default) or false (flat: 0.2.2's balance on "pbr" packs), read once in _ready.
var _pbr_light_on := true
## --pbr-rough=floor: the look's roughness_min on "pbr" packs' surfaces and modellers' items too (0.2.2), read in _ready.
var _pbr_rough_floor := false
## --sun-specular=<0-2>: the sun's highlight under every look (-1 without: the look's), read in _ready.
var _sun_specular_arg := -1.0
## --pbr-light-scene: true (the default) or false (0.2.2's order), read once in _ready. On, a "pbr" pack's neutral
## reflection, ambient by direction and fill are read after the debug menu's sun and ambient sliders are put on the
## scene (light_tune), and its fill follows the ambient the sliders set, so at sun 0 and ambient 0 a pbr model is
## black but for emission and lamps. Off, they are read before (the sliders didn't reach them) and the fill is whole.
var _pbr_scene_on := true
## The share of the look's fill every model gets for the scene's ambient now (in f3d_look_model_fill; also f3d_pbr_light.w):
## the ambient energy the debug menu's slider set over the one the game had, 1 without the slider or the switch.
var _pbr_fill_scene := 1.0
## --model-fill (model_fill_arg), read once in _ready: 0 off (the default), -1 the look's own model_fill (0.2.2), or
## a number for every look.
var _model_fill_arg := 0.0
## The fill apply() last put on f3d_look_model_fill, and the sky's scene_light, for the tests (headless reads are null).
var fill_put := 0.0
## The look's fill light (fill_light): a DirectionalLight3D of its own, made in attach(); its energy apply() last put.
var fill_light: DirectionalLight3D = null
var fill_light_put := 0.0
## --fill-light: -1 the look's, else that energy for every look (0: off).
var _fill_light_arg := -1.0
var sky_put := Vector2.ONE
## --light-env: true (the sky's cubemap lights everything, the default) or false (=shader: 0.2.2's constant ambient,
## the planet's sky reflected and "pbr" packs' own terms), read in _ready.
var _light_env_sky := true
static var _shader_light_env := not light_env_switch(Switches.args()) or Switches.has("--preview-light=studio")
static var _env_shaders := {}  # Shader -> Shader compiled with #define SHADER_LIGHT_ENV
var _env_sky_mat: ShaderMaterial = null
var _env_cache := {}
## The lighting environment put_light_env last drew (linear): {sky, ground, sky_mix, gain}, for the tests.
var env_put := {}
## The environment's ambient and reflection sources as the look left them, while put_light_env holds them on the sky.
var _env_held := {}
## The fog's light as the look left it, while apply() scales it by the debug menu's sliders (released with _env_held).
var _scene_held := {}
## Environment and sun properties adjusted by active weather (released with _env_held).
var _weather_held := {}
## The scene's light this frame against what the game set, after the debug menu's sliders: x the ambient's, y the
## sun's (1 untouched, 0 at none). The fill light, the fog's light and the looks' passes (look_scene_light) follow it.
var scene_now := Vector2.ONE
## Fog density scale applied when Distant Horizon extends past 50 chunks, preventing extreme horizon white-out.
var fog_distance_scale := 1.0
## Night vision equipment's lift, 0-1 (main.gd): apply() adds its ambient before the sliders, so they hold it too.
var night_vision := 0.0
## --night-vision-fx=old: the first night vision look (ambient lift 1.4, the edge at 0.42).
static var night_vision_old: bool = Switches.has("--night-vision-fx=old")
## The roughness floors apply() last put (x built-in packs and icon items, y "pbr" packs and modellers' items), for the tests.
var rough_put := Vector2.ZERO
## The look's ao_direct _put_on last put (f3d_look_ao_direct), for the tests.
var ao_direct_put := 1.0
## The pbr globals apply() last put (_put_pbr_scene), for the tests (global_shader_parameter_get is null headless).
var pbr_put := {}
## What SPACE_ENV replaced, while in space: property -> the value it had.
var _space_saved := {}


static func _builtins() -> void:
	if not looks.has("factorio"):
		register("factorio", FACTORIO)
		register("classic", CLASSIC)


func _init() -> void:
	_builtins()


func _ready() -> void:
	name = "Looks"
	active = self
	put_tree_matte()
	for arg in Switches.args():
		if arg.begins_with("--look="):
			_forced = arg.get_slice("=", 1)
		elif arg.begins_with("--look-file="):
			load_file(arg.get_slice("=", 1))
	var args := Switches.args()
	_metal_arg = texture_metal_arg(args)
	_pbr_env_arg = pbr_env_arg(args)
	_pbr_env_on = pbr_env_switch(args)
	_pbr_metal_arg = pbr_metal_arg(args)
	_pbr_light_on = pbr_light_switch(args)
	_pbr_rough_floor = pbr_rough_floor_switch(args)
	_sun_specular_arg = sun_specular_arg(args)
	_light_env_sky = light_env_switch(args)
	_pbr_scene_on = pbr_scene_switch(args)
	_model_fill_arg = model_fill_arg(args)
	_fill_light_arg = fill_light_arg(args)
	apply_pack_shading()


func _exit_tree() -> void:
	if active == self:
		active = null
	if env != null:
		_env_release()
		_restore()
		_luts.clear(env)
	RenderingServer.global_shader_parameter_set(&"f3d_look_ground_specular", 1.0)
	put_tree_matte()
	RenderingServer.global_shader_parameter_set(&"f3d_look_ao_direct", 1.0)
	RenderingServer.global_shader_parameter_set(&"f3d_look_model_fill", 0.0)
	RenderingServer.global_shader_parameter_set(&"f3d_look_roughness_min", 0.0)
	RenderingServer.global_shader_parameter_set(&"f3d_look_roughness_min_pbr", 0.0)
	RenderingServer.global_shader_parameter_set(&"f3d_light_env", 0.0)
	RenderingServer.global_shader_parameter_set(&"f3d_look_texture_metal", TEXTURE_METAL)
	RenderingServer.global_shader_parameter_set(&"f3d_look_texture_light", TEXTURE_LIGHT)
	apply_pack_shading()
	_apply_limiter({})
	_apply_taa({})


## Starts using the scene's environment and sun (main.gd, once both are made).
func attach(e: Environment, s: DirectionalLight3D) -> void:
	env = e
	sun = s
	if fill_light == null:
		fill_light = DirectionalLight3D.new()
		fill_light.name = "FillLight"
		fill_light.shadow_enabled = false
		fill_light.light_specular = FILL_SPECULAR
		fill_light.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
		fill_light.light_cull_mask = 0xFFFFF & ~Visuals.GROUND_LAYER
		fill_light.visible = false
		add_child(fill_light)
	if _light_env_sky and e.sky != null:
		e.sky.radiance_size = LIGHT_ENV_RADIANCE
	use(_forced if _forced != "" and looks.has(_forced) else current, true)
	for id in extras:
		_show_extra(int(id))


## Adds or replaces a look. Its id must be new or the owner's own; built-in ones can't be replaced.
static func register(id: String, spec: Dictionary, owner := "") -> bool:
	if id == "" or (looks.has(id) and str(looks[id].get("owner", "")) != owner):
		return false
	var s := spec.duplicate(true)
	s["owner"] = owner
	looks[id] = s
	if not order.has(id):
		order.append(id)
	if active != null and id == active.current and active.env != null:
		active.use(id, true)
	return true


## Takes away an add-on's looks and passes (it was switched off); the look in use goes back to
## Factorio's if it was one of them.
static func remove_owner(owner: String) -> void:
	for id in order.duplicate():
		if str(looks[id].get("owner", "")) == owner:
			looks.erase(id)
			order.erase(id)
			if active != null and id == active.current:
				active.use("factorio")
	for pid in extras.keys():
		if str(extras[pid]["owner"]) == owner:
			remove_pass(int(pid))


## Looks from a JSON file ({id: look}; colours and angles as arrays, a pass's shader as a path), for
## trying looks out without an add-on: `--look-file=<file.json>` (tools/look/factorio_reference.py).
static func load_file(path: String) -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary:
		push_warning("looks: %s isn't a JSON object of looks" % path)
		return
	for id in data:
		var spec: Dictionary = data[id]
		register(str(id), from_json(spec), "file")


## A look written in JSON: arrays of 2 become Vector2, of 3 or 4 Color; the rest as written.
static func from_json(v: Variant) -> Variant:
	if v is Dictionary:
		var out := {}
		for k in v:
			out[k] = from_json(v[k])
		if out.has("tonemap"):
			out["tonemap"] = int(out["tonemap"])
		return out
	if v is Array:
		if v.size() == 2 and (v[0] is float or v[0] is int):
			return Vector2(v[0], v[1])
		if (v.size() == 3 or v.size() == 4) and (v[0] is float or v[0] is int):
			return Color(v[0], v[1], v[2], v[3] if v.size() == 4 else 1.0)
		return v.map(func(x): return from_json(x))
	return v


## [[name, id]...] for the settings' list.
static func choices() -> Array:
	_builtins()
	var out: Array = []
	for id in order:
		out.append([str(looks[id].get("name", id)), id])
	return out


## The player's choice in Settings (a `--look=` on the command line wins over it).
func use_setting(id: String) -> void:
	if _forced == "":
		use(id)


## Puts a look on: the environment and sun properties it sets, its passes, its tonemapping.
func use(id: String, force := false) -> void:
	if not looks.has(id):
		id = "factorio"
	if id == current and not force:
		return
	current = id
	if env == null:
		return
	_env_release()
	_space_back()  # the old look's own values first, so it comes off cleanly; apply() puts space back
	_restore()
	var L: Dictionary = looks[id]
	_put_on(L)
	for p in L.get("passes", []):
		var node := _make_pass(p, str(L.get("owner", "")))
		if node != null:
			_pass_nodes.append(node)
			_key_params(node, L)
	if not L.get("factorio_lut", false):
		_luts.clear(env)
	sync_pre_aa()
	look_changed.emit(id)


## What a look sets on the environment, the sun and the renderer. Each property's value before it
## is kept for _take_off.
func _put_on(L: Dictionary) -> void:
	_env_release()
	env.tonemap_mode = int(L.get("tonemap", Environment.TONE_MAPPER_LINEAR))
	env.tonemap_exposure = float(L.get("exposure", 1.0))
	env.tonemap_white = float(L.get("white", 1.0))
	RenderingServer.global_shader_parameter_set(&"f3d_look_ground_specular", float(L.get("ground_specular", 1.0)))
	put_tree_matte()
	ao_direct_put = clampf(float(L.get("ao_direct", 1.0)), 0.0, 1.0)
	RenderingServer.global_shader_parameter_set(&"f3d_look_ao_direct", ao_direct_put)
	var e: Dictionary = L.get("environment", {})
	for key in e:
		if not str(key) in env:
			continue
		_base_env[key] = env.get(key)
		env.set(key, e[key])
		_set_env.append(key)
	var s: Dictionary = L.get("sun", {})
	for key in s:
		if not SUN_KEYS.has(str(key)) or (shadows != null and str(key) == "light_angular_distance"):
			continue
		_base_sun[key] = sun.get(key)
		sun.set(key, s[key])
		_set_sun.append(key)
	if shadows != null:
		shadows.set_look(float(s.get("light_angular_distance", 0.0)), float(L.get("shadow_edge", SunShadows.EDGE)))
	_key_values(L)
	_apply_limiter(L)
	_apply_taa(L)


## Notes what at_twilight and at_dawn move, and from what: the look's own value (now on the
## environment and sun) or, for a property it doesn't set, what it was.
func _key_values(L: Dictionary) -> void:
	_tw_env = _keyed(L, "environment", env, _base_env, _set_env)
	_tw_sun = _keyed(L, "sun", sun, _base_sun, _set_sun, _sun_keys())
	_fog_base = null
	if float(L.get("fog_from_sky", 0.0)) > 0.0:
		if not _set_env.has("fog_light_color"):
			_base_env["fog_light_color"] = env.fog_light_color
			_set_env.append("fog_light_color")
		_fog_base = env.fog_light_color
	_tw_last = -1.0


## The sun's properties a look sets here: the sun's size is sun_shadows.gd's when there is one.
func _sun_keys() -> Array:
	return SUN_KEYS if shadows == null else SUN_KEYS.filter(func(k: String) -> bool: return k != "light_angular_distance")


func _keyed(L: Dictionary, group: String, target: Object, base: Dictionary, set_keys: Array, allowed: Array = []) -> Dictionary:
	var dusk: Dictionary = L.get("at_twilight", {}).get(group, {})
	var dawn: Dictionary = L.get("at_dawn", {}).get(group, {})
	var out := {}
	for key in dusk.keys() + dawn.keys():
		if out.has(key) or not str(key) in target or (not allowed.is_empty() and not allowed.has(str(key))):
			continue
		if not set_keys.has(key):
			base[key] = target.get(key)
			set_keys.append(key)
		out[key] = [target.get(key), dusk.get(key), dawn.get(key)]
	return out


## The same for a pass's uniforms; one the look doesn't give starts from the shader's own default.
func _key_params(node: MeshInstance3D, L: Dictionary) -> void:
	var dusk: Dictionary = L.get("at_twilight", {}).get("params", {})
	var dawn: Dictionary = L.get("at_dawn", {}).get("params", {})
	var m := node.material_override as ShaderMaterial
	var out := {}
	for key in dusk.keys() + dawn.keys():
		var own = m.get_shader_parameter(key)
		if own == null:
			own = RenderingServer.shader_get_parameter_default(m.shader.get_rid(), key)
		if own != null:
			out[key] = [own, dusk.get(key), dawn.get(key)]
	if not out.is_empty():
		_tw_params[node] = out


static func _blended(row: Array, t: float, morning: bool) -> Variant:
	var target = row[2] if morning and row[2] != null else row[1]
	# A dawn-only key has nothing to go to at dusk.
	return row[0] if target == null else lerp(row[0], target, t)


## Moves what the look keyed to the sun, when the sun has moved enough to show.
func _blend_keyed(L: Dictionary, t: float, morning: bool) -> void:
	t = snappedf(t, 0.005)
	if t == _tw_last and morning == _tw_morning:
		return
	_tw_last = t
	_tw_morning = morning
	for key in _tw_env:
		env.set(key, _blended(_tw_env[key], t, morning))
	for key in _tw_sun:
		sun.set(key, _blended(_tw_sun[key], t, morning))
	for node: MeshInstance3D in _tw_params:
		if is_instance_valid(node):
			var m := node.material_override as ShaderMaterial
			var rows: Dictionary = _tw_params[node]
			for key in rows:
				m.set_shader_parameter(key, _blended(rows[key], t, morning))
	if _fog_base != null and sun_state.has("fog"):
		env.fog_light_color = (_fog_base as Color).lerp(sun_state["fog"], t * float(L.get("fog_from_sky", 0.0)))


func _apply_limiter(L: Dictionary) -> void:
	var limiter = L.get("roughness_limiter")
	if limiter is Vector2:
		RenderingServer.screen_space_roughness_limiter_set_active(true, limiter.x, limiter.y)
	else:
		RenderingServer.screen_space_roughness_limiter_set_active(
			bool(ProjectSettings.get_setting("rendering/anti_aliasing/screen_space_roughness_limiter/enabled", true)),
			float(ProjectSettings.get_setting("rendering/anti_aliasing/screen_space_roughness_limiter/amount", 0.25)),
			float(ProjectSettings.get_setting("rendering/anti_aliasing/screen_space_roughness_limiter/limit", 0.18)))


func _apply_taa(L: Dictionary) -> void:
	Settings.look_taa = bool(L.get("taa", false))
	# TAA on the viewport, and SMAA out while it is on (Settings.follow_taa).
	Settings.follow_taa(get_viewport())


## How much of a sunset the look in use has, for its light and for its sky (sky.gd).
func twilight() -> float:
	return float(looks.get(current, {}).get("twilight", 0.0))


func sky_twilight() -> float:
	var L: Dictionary = looks.get(current, {})
	return float(L.get("sky_twilight", L.get("twilight", 0.0)))


## Where the look in use wants the sun that crosses the sky at noon (sky.gd noon_yaw), `fallback` if it doesn't say.
func noon_yaw(fallback: float) -> float:
	return float(looks.get(current, {}).get("sun_noon_yaw", fallback))


## Whether Zenith's own clouds are drawn under this look (the Clouds setting decides if they are).
func own_clouds() -> bool:
	return bool(looks.get(current, {}).get("own_clouds", true))


## The active look's own cloud layer parameters for volumetric passes (empty when Zenith's own
## clouds apply, `cloud_mode = 0` when the look suppresses clouds without supplying its own).
func cloud_source() -> Dictionary:
	if own_clouds():
		return {}
	var pass_list: Variant = looks.get(current, {}).get("passes", [])
	if pass_list is Array:
		for spec_val: Variant in pass_list as Array:
			if not (spec_val is Dictionary):
				continue
			var spec: Dictionary = spec_val
			var params_val: Variant = spec.get("params", {})
			if not (params_val is Dictionary):
				continue
			var params: Dictionary = params_val
			var field_val: Variant = params.get("cloud_field")
			if field_val is Texture2D and float(params.get("clouds", 0.0)) > 0.0:
				var wind_val: Variant = params.get("wind", Vector2(3.2, 1.1))
				var wind: Vector2 = wind_val if wind_val is Vector2 else Vector2(3.2, 1.1)
				var look_cov := float(params.get("cloud_cover", 0.58))
				var look_str := float(params.get("clouds", 1.0))
				if WeatherState.active and float(WeatherState.state.get("cloud_cover", -1.0)) >= 0.0:
					look_cov = clampf(float(WeatherState.state["cloud_cover"]), 0.0, 1.0)
					if look_cov <= 0.005:
						look_str = 0.0
				return {
					"cloud_mode": 2,
					"look_cloud_field": field_val,
					"look_cloud_cover": look_cov,
					"look_cloud_strength": look_str,
					"look_cloud_low": float(params.get("cloud_low", 230.0)),
					"look_cloud_high": float(params.get("cloud_high", 300.0)),
					"look_cloud_scale": float(params.get("cloud_scale", 0.009)),
					"look_cloud_period": float(params.get("cloud_period", 16.0)),
					"look_cloud_wind": wind,
				}
	return {"cloud_mode": 0}


func _take_off() -> void:
	_env_release()
	for key in _set_env:
		env.set(key, _base_env[key])
	for key in _set_sun:
		sun.set(key, _base_sun[key])
	if shadows != null:
		shadows.set_look(0.0)
	_set_env.clear()
	_set_sun.clear()


func _restore() -> void:
	_take_off()
	for n in _pass_nodes:
		n.queue_free()
	_pass_nodes.clear()
	_tw_params.clear()


## The share of a picture's metal drawn under look `L`: the command line's, else the look's texture_metal.
func texture_metal(L: Dictionary) -> float:
	if _metal_arg >= 0.0:
		return _metal_arg
	return clampf(float(L.get("texture_metal", TEXTURE_METAL)), 0.0, 1.0)


## `--texture-metal=full` (1, as before), `=paint` (0.1) or a number 0-1 among `args`; -1 without one.
static func texture_metal_arg(args: PackedStringArray) -> float:
	var out := -1.0
	for arg in args:
		if arg.begins_with("--texture-metal="):
			var v := arg.get_slice("=", 1)
			if v == "full":
				out = 1.0
			elif v == "paint":
				out = TEXTURE_METAL
			elif v.is_valid_float():
				out = clampf(v.to_float(), 0.0, 1.0)
	return out


## The neutral reflection of a "pbr" pack's surfaces now, for the shader's f3d_pbr_env (linear, as Godot lights):
## the ambient plus pbr_env of the sun as sky.gd and the look have set them this frame; alpha 0 with --pbr-env=off.
func pbr_env_now(L: Dictionary) -> Vector4:
	var k := pbr_env_k(L)
	var amb := env.ambient_light_color.srgb_to_linear() * env.ambient_light_energy
	var lit := sun.light_color.srgb_to_linear() * (sun.light_energy * k if sun.visible else 0.0)
	return Vector4(amb.r + lit.r, amb.g + lit.g, amb.b + lit.b, 1.0 if _pbr_env_on else 0.0)


## A "pbr" pack's light by direction under look `L` as sky.gd and the look have set the light this frame: {f3d_pbr_light:
## (1 by direction or 0 flat, fill share, ambient share, the fill's share for the scene's ambient), f3d_pbr_sky: the ambient (linear), f3d_pbr_sun: towards
## the sun (world space)}.
func pbr_light_now(L: Dictionary) -> Dictionary:
	var on := _pbr_light_on if not pbr_tune.has("pbr_directional") else float(pbr_tune["pbr_directional"]) > 0.5
	var share := pbr_light_shares(L)
	var amb := env.ambient_light_color.srgb_to_linear() * env.ambient_light_energy
	var to_sun := (sun.global_transform.basis.z if sun.is_inside_tree() else sun.basis.z).normalized()
	return {&"f3d_pbr_light": Vector4(1.0 if on else 0.0, share.x, share.y, _pbr_fill_scene),
		&"f3d_pbr_tune": Vector4(float(pbr_tune.get("pbr_sun_lobe", PBR_SUN_LOBE)), float(pbr_tune.get("pbr_ground", PBR_GROUND)), 0.0, 0.0),
		&"f3d_pbr_sky": Vector4(amb.r, amb.g, amb.b, 0.0), &"f3d_pbr_sun": Vector4(to_sun.x, to_sun.y, to_sun.z, 0.0)}


## A "pbr" pack's shares of the fill and the ambient under look `L` (x fill, y ambient).
func pbr_light_shares(L: Dictionary) -> Vector2:
	return Vector2(clampf(float(pbr_tune.get("pbr_fill", L.get("pbr_fill", PBR_FILL))), 0.0, 2.0),
		clampf(float(pbr_tune.get("pbr_ambient", L.get("pbr_ambient", PBR_AMBIENT))), 0.0, 2.0))


## Whether a "pbr" pack is lit by direction: `--pbr-light=flat` (or off) gives 0.2.2's balance back (the look's fill
## and ambient in full, the neutral reflection the same all round), `=directional` (or on) the default.
static func pbr_light_switch(args: PackedStringArray) -> bool:
	var on := true
	for arg in args:
		if arg.begins_with("--pbr-light="):
			var v := arg.get_slice("=", 1)
			on = not (v == "flat" or v == "off")
	return on


## `--pbr-rough=floor` (or old): the look's roughness_min on "pbr" packs and modellers' items too, as 0.2.2 had it
## on buildings; `=own` (the default) leaves them the roughness their files give.
static func pbr_rough_floor_switch(args: PackedStringArray) -> bool:
	var on := false
	for arg in args:
		if arg.begins_with("--pbr-rough="):
			var v := arg.get_slice("=", 1)
			on = v == "floor" or v == "old"
	return on


## `--sun-specular=<0-2>` among `args`: the sun's highlight under every look; -1 without one.
static func sun_specular_arg(args: PackedStringArray) -> float:
	var out := -1.0
	for arg in args:
		if arg.begins_with("--sun-specular="):
			var v := arg.get_slice("=", 1)
			out = clampf(v.to_float(), 0.0, 2.0) if v.is_valid_float() else -1.0
	return out


## Whether a "pbr" pack's extra light follows the scene's sun and ambient as the debug menu's sliders set them:
## `--pbr-light-scene=off` gives 0.2.2's order back (on otherwise).
static func pbr_scene_switch(args: PackedStringArray) -> bool:
	var on := true
	for arg in args:
		if arg.begins_with("--pbr-light-scene="):
			on = arg.get_slice("=", 1) != "off"
	return on


## The share of the look's fill a "pbr" pack gets when the ambient the game set (`game`) is `now`: 1 untouched, 0 at
## none, held to 0-2.
static func pbr_fill_scene(game: float, now: float) -> float:
	if is_equal_approx(game, now):
		return 1.0
	if game <= 1e-4:
		return 1.0 if now > 1e-4 else 0.0
	return clampf(now / game, 0.0, 2.0)


## The sun's share in the neutral reflection under look `L`: the command line's number, else the look's pbr_env.
func pbr_env_k(L: Dictionary) -> float:
	if pbr_tune.has("pbr_env"):
		return clampf(float(pbr_tune["pbr_env"]), 0.0, 2.0)
	if _pbr_env_arg >= 0.0:
		return _pbr_env_arg
	return clampf(float(L.get("pbr_env", PBR_ENV)), 0.0, 2.0)


## A "pbr" pack's metal share under look `L`: the command line's, else the look's pbr_metal.
func pbr_metal(L: Dictionary) -> float:
	if pbr_tune.has("pbr_metal"):
		return clampf(float(pbr_tune["pbr_metal"]), 0.0, 1.0)
	if _pbr_metal_arg >= 0.0:
		return _pbr_metal_arg
	return clampf(float(L.get("pbr_metal", PBR_METAL)), 0.0, 1.0)


## `--pbr-env=<number 0-2>` among `args` (the sun's share in the neutral reflection); -1 without one, or for on/off.
static func pbr_env_arg(args: PackedStringArray) -> float:
	var out := -1.0
	for arg in args:
		if arg.begins_with("--pbr-env="):
			var v := arg.get_slice("=", 1)
			out = clampf(v.to_float(), 0.0, 2.0) if v.is_valid_float() else -1.0
	return out


## Whether the neutral reflection is on: `--pbr-env=off` (the sky's reflection on "pbr" packs too, as in 0.2.2) turns
## it off, `=on` or a number on.
static func pbr_env_switch(args: PackedStringArray) -> bool:
	var on := true
	for arg in args:
		if arg.begins_with("--pbr-env="):
			on = arg.get_slice("=", 1) != "off"
	return on


## `--pbr-metal=full` (1), `=paint` (0.1, 0.2.2's) or a number 0-1 among `args`; -1 without one.
static func pbr_metal_arg(args: PackedStringArray) -> float:
	var out := -1.0
	for arg in args:
		if arg.begins_with("--pbr-metal="):
			var v := arg.get_slice("=", 1)
			if v == "full":
				out = 1.0
			elif v == "paint":
				out = TEXTURE_METAL
			elif v.is_valid_float():
				out = clampf(v.to_float(), 0.0, 1.0)
	return out


## A "pbr" pack's balance of light on its pictures under look `L` (sides, tops): the look's texture_light.
func texture_light(L: Dictionary) -> Vector2:
	var v: Variant = L.get("texture_light", TEXTURE_LIGHT)
	return (v as Vector2).clamp(Vector2.ZERO, Vector2(2.0, 2.0)) if v is Vector2 else TEXTURE_LIGHT


## `--pack-shading=factorio` (Factorio's everywhere, as before) or `=pack` (each pack as it says) among
## `args`; "" without one.
static func pack_shading_arg(args: PackedStringArray) -> String:
	var out := ""
	for arg in args:
		if arg.begins_with("--pack-shading="):
			var v := arg.get_slice("=", 1)
			if v == "factorio" or v == "old":
				out = "factorio"
			elif v == "pack" or v == "pbr":
				out = "pack"
	return out


## Whether packs' own shading is on: the command line's, else Settings' (Graphics > Advanced > Packs' own
## shading; "pack" by default).
static func pack_shading(args: PackedStringArray = Switches.args()) -> bool:
	var arg := pack_shading_arg(args)
	if arg != "":
		return arg == "pack"
	return str(Settings.get_value("graphics", "pack_shading")) != "factorio"


## Packs' own shading put in effect: the shader's f3d_pack_shading and packs_shade (at start, after
## Settings wrote, and when the game's look goes, so the menu and the model preview follow it too), and the
## neutral reflection's and pbr metal share's values outside a game (PBR_ENV_REST, the switches).
static func apply_pack_shading() -> void:
	packs_shade = pack_shading()
	RenderingServer.global_shader_parameter_set(&"f3d_pack_shading", 1.0 if packs_shade else 0.0)
	# The neutral reflection and metal share outside a game (a game's look sets both each frame, apply()).
	var args := Switches.args()
	var rest := PBR_ENV_REST
	rest.w = 1.0 if pbr_env_switch(args) else 0.0
	RenderingServer.global_shader_parameter_set(&"f3d_pbr_env", rest)
	# No sun to light by outside a game: flat, as before (a game's look sets it each frame, apply()).
	RenderingServer.global_shader_parameter_set(&"f3d_pbr_light", PBR_LIGHT_REST)
	RenderingServer.global_shader_parameter_set(&"f3d_pbr_tune", Vector4(PBR_SUN_LOBE, PBR_GROUND, 0.0, 0.0))
	var metal := pbr_metal_arg(args)
	RenderingServer.global_shader_parameter_set(&"f3d_look_pbr_metal", metal if metal >= 0.0 else PBR_METAL)


## Before Settings writes what a look may also set (ambient occlusion, brightness...): the look's
## own values come off, so what Settings writes is what comes back when the look goes. `settle` after.
func lift() -> void:
	if env != null:
		_env_release()
		_space_back()
		_take_off()


## After Settings wrote: the look the player picked, its own values winning again.
func settle(id: String) -> void:
	apply_pack_shading()
	if env == null:
		return
	var want := id if looks.has(id) else "factorio"
	if _forced == "" and want != current:
		use(want)
	else:
		_put_on(looks.get(current, {}))
	_luts.reapply(env)


func _focus_distance() -> float:
	if not grade_focus_uniform or not is_inside_tree():
		return 0.0
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return 0.0
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		return clampf(cam.size, 4.0, 600.0)
	var fwd := -cam.global_transform.basis.z
	if fwd.y < -0.02 and cam.global_position.y > 0.0:
		return clampf(cam.global_position.y / -fwd.y, 4.0, 600.0)
	return 0.0


## Once a frame, after sky.gd lit the scene for the time of day: the look's light on top.
## `daytime` 0 is noon, 0.5 midnight; `night` 0-1; `planet` the surface's planet ("" in space);
## `state` the sun now (sky.gd).
func apply(daytime: float, night: float, planet: String, space: bool, state := {}) -> void:
	if env == null:
		return
	var L: Dictionary = looks.get(current, {})
	sun_state = state
	_env_release()
	var low := float(state.get("twilight", 0.0))
	sun.light_energy *= float(L.get("sun_energy", 1.0))
	var amb_k := float(L.get("ambient_energy", 1.0))
	if _light_env_sky and L.has("ambient_energy_lit"):
		amb_k = lerpf(float(L["ambient_energy_lit"]), amb_k, clampf(night, 0.0, 1.0))
	env.ambient_light_energy *= amb_k
	if L.has("ambient_tint"):
		# A fixed tint would mute the colours of a sunset, which has its own.
		env.ambient_light_color = env.ambient_light_color.lerp(L["ambient_tint"], float(L.get("ambient_tint_amount", 1.0)) * (1.0 - low))
	_blend_keyed(L, low, bool(state.get("morning", false)))
	_space_env(space)
	if not space and WeatherState.active:
		_apply_weather_env(WeatherState.state)
	if night_vision > 0.0:
		# Factorio's night vision lifts the night (a brighter, greener ambient); its colour lookup is the LUT's.
		env.ambient_light_energy += (NIGHT_VISION_AMBIENT_OLD if night_vision_old else NIGHT_VISION_AMBIENT) * night_vision
		env.ambient_light_color = env.ambient_light_color.lerp(NIGHT_VISION_COLOR, 0.6 * night_vision)
	if L.has("sun_angle"):
		var a: Vector2 = L["sun_angle"]
		sun.rotation_degrees = Vector3(a.x, a.y, 0.0)
	var rough_min := float(L.get("roughness_min", 0.0))
	RenderingServer.global_shader_parameter_set(&"f3d_look_roughness_min", rough_min)
	RenderingServer.global_shader_parameter_set(&"f3d_look_roughness_min_pbr", rough_min if _pbr_rough_floor else 0.0)
	rough_put = Vector2(rough_min, rough_min if _pbr_rough_floor else 0.0)
	if _sun_specular_arg >= 0.0:
		sun.light_specular = _sun_specular_arg
	RenderingServer.global_shader_parameter_set(&"f3d_look_texture_metal", texture_metal(L))
	RenderingServer.global_shader_parameter_set(&"f3d_look_pbr_metal", pbr_metal(L))
	if not _pbr_scene_on:
		_pbr_fill_scene = 1.0
		_put_pbr_scene(L)
	light_now = texture_light(L)
	RenderingServer.global_shader_parameter_set(&"f3d_look_texture_light", light_now)
	if L.get("factorio_lut", false):
		_luts.update(env, "" if space else planet, daytime, night)
	for n: MeshInstance3D in _pass_nodes + _extra_nodes.values():
		var m := n.material_override as ShaderMaterial
		m.set_shader_parameter("look_daytime", daytime)
		m.set_shader_parameter("look_night", night)
		m.set_shader_parameter("look_space", 1.0 if space else 0.0)
		m.set_shader_parameter("look_focus_dist", _focus_distance())
		m.set_shader_parameter("fast_night_clouds", 1.0 if fast_night_clouds else 0.0)
		if not state.is_empty():
			m.set_shader_parameter("look_sun_height", state["height"])
			m.set_shader_parameter("look_twilight", low)
			m.set_shader_parameter("look_morning", 1.0 if state["morning"] else 0.0)
			m.set_shader_parameter("look_sun_dir", state["direction"])
			m.set_shader_parameter("look_sun_color", state["color"])
			m.set_shader_parameter("look_ambient_color", env.ambient_light_color)
	var game_ambient := env.ambient_light_energy
	var game_sun := sun.light_energy
	if not light_tune.is_empty():
		apply_light_tune(env, sun)
	scene_now = Vector2(pbr_fill_scene(game_ambient, env.ambient_light_energy), pbr_fill_scene(game_sun, sun.light_energy))
	_put_scene_fog()
	if _pbr_scene_on:
		# After the sliders: the sun and ambient a pbr model's extra light follows are the scene's own.
		_pbr_fill_scene = pbr_fill_scene(game_ambient, env.ambient_light_energy)
		_put_pbr_scene(L)
		sky_put = Vector2(_pbr_fill_scene, pbr_fill_scene(game_sun, sun.light_energy))
	else:
		sky_put = Vector2.ONE
	_put_sky_light(sky_put)
	for n: MeshInstance3D in _pass_nodes + _extra_nodes.values():
		(n.material_override as ShaderMaterial).set_shader_parameter("look_scene_light", sky_put)
	# The fill (none by default), as much of it as the scene's ambient allows.
	fill_put = model_fill(L, night) * _pbr_fill_scene
	RenderingServer.global_shader_parameter_set(&"f3d_look_model_fill", fill_put)
	_put_fill_light(L, night, space)
	put_light_env(space)


## The look's fill light this frame: its energy (fill_light, or --fill-light's) faded by night, the sun's colour by
## day, coming from behind the camera FILL_PITCH degrees above and FILL_YAW to its right, so the fronts the camera
## sees get it whichever way the camera turns, as Factorio's sprites, rendered with their fill, look from its camera.
## None in space (SPACE_ENV: no sky light there either).
func _put_fill_light(L: Dictionary, night: float, space := false) -> void:
	if fill_light == null:
		return
	var base := float(L.get("fill_light", 0.0)) if _fill_light_arg < 0.0 else _fill_light_arg
	fill_light_put = 0.0 if space else maxf(base, 0.0) * (1.0 - clampf(night, 0.0, 1.0)) * scene_now.y
	fill_light.visible = fill_light_put > 0.0
	if not fill_light.visible:
		return
	fill_light.light_energy = fill_light_put
	fill_light.light_color = sun.light_color
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var yaw := cam.global_rotation.y if cam != null else 0.0
	fill_light.global_rotation = Vector3(deg_to_rad(-FILL_PITCH), yaw + deg_to_rad(FILL_YAW), 0.0)


## --fill-light=off (or 0): no fill light under any look; a number: that energy under every look; absent: the look's.
static func fill_light_arg(args: PackedStringArray) -> float:
	var out := -1.0
	for arg in args:
		if arg.begins_with("--fill-light="):
			var v := arg.get_slice("=", 1)
			if v == "off":
				out = 0.0
			elif v == "on":
				out = -1.0
			elif v.is_valid_float():
				out = clampf(v.to_float(), 0.0, 4.0)
	return out


## The fog's own light scaled as the debug menu's sliders scale the scene's (scene_now): its colour's energy by the
## ambient's, its glow towards the sun by the sun's, so at none of either the haze is no lit veil. Untouched otherwise.
func _put_scene_fog() -> void:
	if scene_now == Vector2.ONE and is_equal_approx(fog_distance_scale, 1.0):
		return
	_scene_held = {"fog_light_energy": env.fog_light_energy, "fog_sun_scatter": env.fog_sun_scatter, "fog_density": env.fog_density}
	env.fog_light_energy *= scene_now.x
	env.fog_sun_scatter *= scene_now.y
	env.fog_density *= fog_distance_scale


## Returns `base`, or a variant compiled with SHADER_LIGHT_ENV when --light-env=shader is active.
static func shader_for(base: Shader) -> Shader:
	_static_mv_old_once()
	if not _shader_light_env or base == null:
		return base
	if _env_shaders.has(base):
		return _env_shaders[base]
	var s := Shader.new()
	var idx := base.code.find("#include ")
	s.code = (base.code.substr(0, idx) + "#define SHADER_LIGHT_ENV\n" + base.code.substr(idx)) if idx >= 0 else ("#define SHADER_LIGHT_ENV\n" + base.code)
	_env_shaders[base] = s
	return s


## Standing buildings out of FSR 2.2's / TAA's motion-vector pass (--static-mv): Godot draws every
## surface whose shader reads TIME in vertex() (or TIME and a discard in fragment()) there each frame,
## as if it moved, so factorio_material.gdshaderinc reads the world's clock (f3d_time, belt_blur.gd)
## instead, and only materials whose vertices move with time are given TIME back (timed_shader():
## worms and idle rigs; movers, robots and ragdolls have it in their own shaders).
## `--static-mv=old`: every factorio_material shader keeps TIME, as before (all of them in the pass).
const TIMED_DEFINE := "#define F3D_SHADER_TIME\n"
const STATIC_MV_SHADERS: Array[String] = [
	"res://shaders/factorio_material.gdshader",
	"res://shaders/factorio_material_alpha.gdshader",
	"res://shaders/factorio_material_clip.gdshader",
	"res://shaders/factorio_material_ore.gdshader",
	"res://shaders/factorio_material_leaf.gdshader",
]
static var _timed_shaders := {}  # base Shader -> its F3D_SHADER_TIME variant
static var _static_mv_checked := false


## Whether `--static-mv=old` is given (every model material keeps TIME, all in the motion-vector pass).
static func static_mv_old() -> bool:
	return Settings.has_arg("--static-mv=old")


## `base`, or a variant of it compiled with F3D_SHADER_TIME (TIME, not f3d_time: its vertex motion
## gets motion vectors), for materials whose vertices move with time. `base` itself when it has it.
static func timed_shader(base: Shader) -> Shader:
	if base == null or base.code.contains(TIMED_DEFINE):
		return base
	if _timed_shaders.has(base):
		return _timed_shaders[base]
	var s := Shader.new()
	var idx := base.code.find("#include ")
	s.code = (base.code.substr(0, idx) + TIMED_DEFINE + base.code.substr(idx)) if idx >= 0 else (TIMED_DEFINE + base.code)
	_timed_shaders[base] = s
	return s


## --static-mv=old: the factorio_material shaders themselves given F3D_SHADER_TIME, in place, before
## any material or variant is made from them (shader_for() is on every model material's way).
static func _static_mv_old_once() -> void:
	if _static_mv_checked:
		return
	_static_mv_checked = true
	if not static_mv_old():
		return
	for path in STATIC_MV_SHADERS:
		var sh := load(path) as Shader
		if sh == null or sh.code.contains(TIMED_DEFINE):
			continue
		var idx := sh.code.find("#include ")
		sh.code = (sh.code.substr(0, idx) + TIMED_DEFINE + sh.code.substr(idx)) if idx >= 0 else (TIMED_DEFINE + sh.code)


func _set_env_param(mat: ShaderMaterial, key: String, val: Variant) -> void:
	if mat != _env_sky_mat:
		_env_sky_mat = mat
		_env_cache.clear()
	if _env_cache.has(key):
		var prev: Variant = _env_cache[key]
		if val is float and prev is float and absf(float(val) - float(prev)) <= 1e-4:
			return
		if val is Vector2 and prev is Vector2 and (val as Vector2).distance_squared_to(prev as Vector2) <= 1e-8:
			return
		if val is Vector3 and prev is Vector3 and (val as Vector3).distance_squared_to(prev as Vector3) <= 1e-8:
			return
	_env_cache[key] = val
	mat.set_shader_parameter(key, val)


## The lighting environment drawn into the sky's cubemap from the light of this moment (after sky.gd, the look, the
## debug menu's sliders; main.gd calls it again after night vision lifts the ambient): its upper half the ambient
## (colour times energy, linear), plus the look's share of the drawn sky where the look asked for sky ambient
## (Cinematic's twilight); its lower half the ground's albedo times the sun on flat ground plus that ambient; Godot's
## ambient light and reflections then taken from it alone (source SKY, contribution 1). In space no ground: the lower
## half is the ambient's half. --light-env=shader leaves all as the look set it.
func put_light_env(space := false) -> void:
	if env == null:
		return
	var sky_mat := env.sky.sky_material as ShaderMaterial if env.sky != null else null
	RenderingServer.global_shader_parameter_set(&"f3d_light_env", 1.0 if _light_env_sky and sky_mat != null else 0.0)
	if not _light_env_sky or sky_mat == null:
		if sky_mat != null:
			_set_env_param(sky_mat, "env_on", 0.0)
		env_put = {}
		return
	var L: Dictionary = looks.get(current, {})
	# What the look asked for, before it is held on the sky: its share of the drawn sky.
	# (From the held values when there are some: a second put in a frame, night vision's, sees the forced ones.)
	var src = _env_held.get("ambient_light_source", env.ambient_light_source)
	var contrib = _env_held.get("ambient_light_sky_contribution", env.ambient_light_sky_contribution)
	var sky_mix := float(contrib) if src == Environment.AMBIENT_SOURCE_SKY else 0.0
	if _env_held.is_empty():
		_env_held = {"ambient_light_source": env.ambient_light_source, "ambient_light_sky_contribution": env.ambient_light_sky_contribution,
			"reflected_light_source": env.reflected_light_source}
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	var to_sun := (sun.global_transform.basis.z if sun.is_inside_tree() else sun.basis.z).normalized()
	var sun_lin := sun.light_color.srgb_to_linear() * (sun.light_energy if sun.visible else 0.0)
	var ks := float(light_env_tune.get("sky", 1.0))
	var kg := float(light_env_tune.get("ground", 1.0))
	var halves := env_halves(env.ambient_light_color, env.ambient_light_energy, sun_lin, to_sun, L)
	var sky: Vector3 = halves[0] * ks
	var ground: Vector3 = halves[1] * kg
	if space:
		ground = sky * 0.5
		sky_mix = 0.0
	var glow := Vector3(sun_lin.r, sun_lin.g, sun_lin.b) * clampf(float(L.get("env_glow", 0.0)), 0.0, 1.0) * ks
	var bg := maxf(env.background_energy_multiplier, 1e-3)
	_set_env_param(sky_mat, "env_on", 1.0)
	_set_env_param(sky_mat, "env_sky", sky / bg)
	_set_env_param(sky_mat, "env_ground", ground / bg)
	_set_env_param(sky_mat, "env_glow", glow / bg)
	_set_env_param(sky_mat, "env_sun_dir", to_sun)
	_set_env_param(sky_mat, "env_sky_mix", clampf(sky_mix, 0.0, 1.0) * ks)
	_set_env_param(sky_mat, "env_gain", bg)
	env_put = {"sky": sky, "ground": ground, "sky_mix": sky_mix, "gain": bg}


## The lighting environment's two halves, linear: [the upper (the ambient, `amb_color` in sRGB times `amb_energy`),
## the lower (look `L`'s ground albedo times the sun `sun_lin` on flat ground plus that ambient)].
static func env_halves(amb_color: Color, amb_energy: float, sun_lin: Color, to_sun: Vector3, L: Dictionary) -> Array:
	var amb := amb_color.srgb_to_linear() * amb_energy
	var on_ground := sun_lin * maxf(to_sun.y, 0.0)
	var g: Color = L["env_ground"] if L.get("env_ground") is Color else LIGHT_ENV_GROUND
	return [Vector3(amb.r, amb.g, amb.b),
		Vector3(g.r * (on_ground.r + amb.r), g.g * (on_ground.g + amb.g), g.b * (on_ground.b + amb.b))]


## One rig for the Model packs preview and the menu's backdrop (lighting-fixes step 6): the light look `id` gives at
## noon on `planet` with no game on, so a model there is drawn as in a game. sky.gd's noon sun and ambient on that
## planet times the look's (its ambient_energy_lit by day, its tint), its held sun (or sky.gd's noon one), its
## tonemap, exposure and sun highlight, and the lighting environment put_light_env would draw into the sky's
## cubemap. No colour lookup: Factorio's Nauvis noon is its identity. --preview-light=studio: the old lights instead.
static func noon_rig(id := "factorio", planet := "nauvis") -> Dictionary:
	_builtins()
	var L: Dictionary = looks.get(id, FACTORIO)
	var p: Dictionary = PlanetSky.PLANETS.get(planet, PlanetSky.PLANETS["nauvis"])
	var amb_color: Color = p["ambient"][0]
	if L.has("ambient_tint"):
		amb_color = amb_color.lerp(L["ambient_tint"], float(L.get("ambient_tint_amount", 1.0)))
	var amb_energy := float(p["ambient_energy"][0]) * float(L.get("ambient_energy_lit", L.get("ambient_energy", 1.0)))
	var sun_color: Color = p["sun"][0]
	var sun_energy := float(p["sun_energy"][0]) * float(L.get("sun_energy", 1.0))
	# sky.gd's noon: pitch 60, at the look's noon side.
	var rot := Vector3(-60.0, float(L.get("sun_noon_yaw", PlanetSky.YAW_NOON)), 0.0)
	if L.get("sun_angle") is Vector2:
		var a: Vector2 = L["sun_angle"]
		rot = Vector3(a.x, a.y, 0.0)
	var to_sun := Basis.from_euler(rot * (PI / 180.0)).z.normalized()
	var halves := env_halves(amb_color, amb_energy, sun_color.srgb_to_linear() * sun_energy, to_sun, L)
	var sun_keys: Dictionary = L.get("sun", {})
	return {"sun_color": sun_color, "sun_energy": sun_energy, "sun_rotation": rot, "to_sun": to_sun,
		"sun_specular": float(sun_keys.get("light_specular", 0.5)), "ambient_color": amb_color, "ambient_energy": amb_energy,
		"tonemap": int(L.get("tonemap", Environment.TONE_MAPPER_LINEAR)), "exposure": float(L.get("exposure", 1.0)),
		"white": float(L.get("white", 1.0)), "env_sky": halves[0], "env_ground": halves[1],
		"ground_specular": float(L.get("ground_specular", 1.0)), "fill_light": maxf(float(L.get("fill_light", 0.0)), 0.0)}


## Puts noon_rig()'s fill light on `fill` (a DirectionalLight3D with no shadow whose cull mask leaves the ground out),
## from the side of a camera turned `yaw` radians, as _put_fill_light in a game; hidden when the look has none.
static func put_noon_fill(fill: DirectionalLight3D, rig: Dictionary, yaw := 0.0) -> void:
	fill.light_energy = float(rig.get("fill_light", 0.0))
	fill.visible = fill.light_energy > 0.0
	fill.light_color = rig["sun_color"]
	fill.light_specular = FILL_SPECULAR
	fill.shadow_enabled = false
	fill.rotation = Vector3(deg_to_rad(-FILL_PITCH), yaw + deg_to_rad(FILL_YAW), 0.0)


## Puts noon_rig()'s `rig` on an environment and a sun outside a game: the planet sky's shader as its sky (made when
## it has none), drawing only the lighting environment into the cubemap (the background stays the environment's
## own), and Godot's ambient and reflections taken from it, as put_light_env holds them in a game.
static func put_noon_rig(e: Environment, s: DirectionalLight3D, rig: Dictionary) -> void:
	s.rotation_degrees = rig["sun_rotation"]
	s.light_color = rig["sun_color"]
	s.light_energy = float(rig["sun_energy"])
	s.light_specular = float(rig["sun_specular"])
	e.tonemap_mode = int(rig["tonemap"]) as Environment.ToneMapper
	e.tonemap_exposure = float(rig["exposure"])
	e.tonemap_white = float(rig["white"])
	e.ambient_light_color = rig["ambient_color"]
	e.ambient_light_energy = float(rig["ambient_energy"])
	var mat := e.sky.sky_material as ShaderMaterial if e.sky != null else null
	if mat == null or mat.shader != PlanetSky.SKY_SHADER:
		mat = ShaderMaterial.new()
		mat.shader = PlanetSky.SKY_SHADER
		e.sky = Sky.new()
		e.sky.sky_material = mat
	e.sky.radiance_size = LIGHT_ENV_RADIANCE
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_sky_contribution = 1.0
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	var gain := maxf(e.background_energy_multiplier, 1e-3)
	mat.set_shader_parameter("env_on", 1.0)
	mat.set_shader_parameter("env_sky", rig["env_sky"] / gain)
	mat.set_shader_parameter("env_ground", rig["env_ground"] / gain)
	mat.set_shader_parameter("env_glow", Vector3.ZERO)
	mat.set_shader_parameter("env_sun_dir", rig["to_sun"])
	mat.set_shader_parameter("env_sky_mix", 0.0)
	mat.set_shader_parameter("env_gain", gain)


## The trees' matte switch (--tree-sheen=old: 0): set while running, not only on leaving the tree.
static func put_tree_matte() -> void:
	RenderingServer.global_shader_parameter_set(&"f3d_tree_matte", tree_matte_value())


## What the global is set to (a headless renderer keeps no globals to read back).
static func tree_matte_value() -> float:
	return 0.0 if tree_sheen_old else 1.0


## The shader globals a look puts in a game, put with no game on (the menu's backdrop, the Model packs preview):
## `rig` on, the lighting environment lights every material and the ground reflects as the look says; off, the
## project's own values (the old studio light: "pbr" packs' own terms). Nothing while a game's look is on.
static func put_idle_globals(rig: Dictionary) -> void:
	if active != null:
		return
	RenderingServer.global_shader_parameter_set(&"f3d_light_env", 0.0 if rig.is_empty() else 1.0)
	put_tree_matte()
	RenderingServer.global_shader_parameter_set(&"f3d_look_ground_specular", float(rig.get("ground_specular", 1.0)))


## `--preview-light=studio` (or old): the Model packs preview and the menu's backdrop keep their own lights from before
## lighting-fixes step 6 (a studio key, fill and grey sky; the menu's late-afternoon sun); `=game` (the default) noon_rig.
static func preview_light_switch(args: PackedStringArray) -> bool:
	var on := true
	for arg in args:
		if arg.begins_with("--preview-light="):
			var v := arg.get_slice("=", 1)
			on = not (v == "studio" or v == "old")
	return on


## The ambient and reflection sources back as the look left them (put_light_env holds them on the sky each frame), so
## what a look or Settings saves and blends is its own.
func _env_release() -> void:
	if env == null:
		return
	for key in _scene_held:
		env.set(key, _scene_held[key])
	_scene_held.clear()
	for key in _weather_held:
		if key == "sun_shadow_opacity":
			if sun != null:
				sun.shadow_opacity = float(_weather_held[key])
		else:
			env.set(key, _weather_held[key])
	_weather_held.clear()
	if _env_held.is_empty():
		return
	for key in _env_held:
		env.set(key, _env_held[key])
	_env_held.clear()


func _apply_weather_env(wx: Dictionary) -> void:
	var fog_add := float(wx.get("fog_density_add", 0.0))
	var fog_amt := float(wx.get("fog_color_amount", 0.0))
	if fog_add > 0.00001 or fog_amt > 0.001:
		for k in ["fog_enabled", "fog_density", "fog_light_color", "fog_light_energy", "fog_aerial_perspective"]:
			_weather_held[k] = env.get(k)
		if fog_add > 0.00001:
			if not env.fog_enabled:
				env.fog_enabled = true
				env.fog_density = fog_add
				env.fog_light_energy = 0.7
				env.fog_aerial_perspective = 0.45
			else:
				env.fog_density = env.fog_density + fog_add
		if fog_amt > 0.001 and wx.get("fog_color") is Color:
			env.fog_light_color = env.fog_light_color.lerp(wx["fog_color"], fog_amt)
	var sh_scale := float(wx.get("shadow_opacity_scale", 1.0))
	if sh_scale < 0.999 and sun != null:
		_weather_held["sun_shadow_opacity"] = sun.shadow_opacity
		sun.shadow_opacity = clampf(sun.shadow_opacity * sh_scale, 0.0, 1.0)


## `--light-env=shader` (or old): 0.2.2's light (a constant ambient colour, the planet's sky reflected, "pbr" packs'
## own terms in their shaders); `=sky` (the default) the sky's cubemap lights everything.
static func light_env_switch(args: PackedStringArray) -> bool:
	var on := true
	for arg in args:
		if arg.begins_with("--light-env="):
			var v := arg.get_slice("=", 1)
			on = not (v == "shader" or v == "old")
	return on


## The camera fill on every model under look `L` at `night`: the debug menu's slider, else --model-fill's (the look's
## own with =on, faded out by night as before), none by default.
func model_fill(L: Dictionary, night: float) -> float:
	if pbr_tune.has("model_fill"):
		return clampf(float(pbr_tune["model_fill"]), 0.0, 4.0)
	var base := float(L.get("model_fill", 0.0)) if _model_fill_arg < 0.0 else _model_fill_arg
	return base * (1.0 - night)


## --model-fill: `on` the look's own fill (0.2.2), a number that fill for every look, `off` (the default) none.
static func model_fill_arg(args: PackedStringArray) -> float:
	var out := 0.0
	for arg in args:
		if arg.begins_with("--model-fill="):
			var v := arg.get_slice("=", 1)
			if v == "on":
				out = -1.0
			elif v == "off":
				out = 0.0
			elif v.is_valid_float():
				out = clampf(v.to_float(), 0.0, 4.0)
	return out


## The sky's own colour scaled as the debug menu's sliders scale the scene's light (planet_sky.gdshader scene_light:
## x the ambient's share, the sky and clouds; y the sun's, its disc and glow); (1, 1) untouched.
func _put_sky_light(k: Vector2) -> void:
	if env.sky != null and env.sky.sky_material is ShaderMaterial:
		_set_env_param(env.sky.sky_material as ShaderMaterial, "scene_light", k)


## A "pbr" pack's neutral reflection and light by direction (pbr_env.gdshaderinc) from the sun and ambient now.
func _put_pbr_scene(L: Dictionary) -> void:
	var now := pbr_light_now(L)
	now[&"f3d_pbr_env"] = pbr_env_now(L)
	for k: StringName in now:
		RenderingServer.global_shader_parameter_set(k, now[k])
	pbr_put = now


## The debug menu's light_tune on `e` and `s` (the keys that are theirs; the others are the menu's own business).
static func apply_light_tune(e: Environment, s: DirectionalLight3D) -> void:
	for key: String in light_tune:
		var v: float = float(light_tune[key])
		if e != null and (key.begins_with("ssao_") or key.begins_with("ssil_")):
			if key.ends_with("_enabled"):
				e.set(key, v > 0.5)
			else:
				e.set(key, v)
		elif e != null and key == "ambient_energy":
			e.ambient_light_energy = v
		elif s != null and key == "sun_energy":
			s.light_energy = v
		elif s != null and (key == "shadow_bias" or key == "shadow_normal_bias"):
			s.set(key, v)


## SPACE_ENV on in space (each frame: a look's twilight keys may have set one since), off again on
## the ground.
func _space_env(space: bool) -> void:
	if space:
		for key in SPACE_ENV:
			if env.get(key) != SPACE_ENV[key]:
				_space_saved[key] = env.get(key)
				env.set(key, SPACE_ENV[key])
	elif not _space_saved.is_empty():
		_space_back()


func _space_back() -> void:
	for key in _space_saved:
		env.set(key, _space_saved[key])
	_space_saved.clear()


## A full-screen pass over every look (api.shaders.add_pass), shown in every game until removed:
## its id for set_parameter and remove_pass, or 0 when the shader can't be used.
static func add_pass(spec: Dictionary, owner := "") -> int:
	if _shader_of(spec) == null:
		return 0
	var id := _next_pass
	_next_pass += 1
	extras[id] = {"spec": spec.duplicate(), "owner": owner}
	if active != null and active.env != null:
		active._show_extra(id)
	return id


static func remove_pass(id: int) -> void:
	extras.erase(id)
	if active != null and active._extra_nodes.has(id):
		(active._extra_nodes[id] as Node).queue_free()
		active._extra_nodes.erase(id)
		active.sync_pre_aa()


## A uniform of a pass over every look (kept for the next game too), or with id 0 of every pass of
## the look in use that declares it.
static func set_parameter(id: int, param: String, value: Variant) -> void:
	if extras.has(id):
		var params: Dictionary = extras[id]["spec"].get("params", {})
		params[param] = value
		extras[id]["spec"]["params"] = params
	if active == null:
		return
	var nodes: Array = [active._extra_nodes[id]] if active._extra_nodes.has(id) else ([] if id != 0 else active._pass_nodes)
	for n: MeshInstance3D in nodes:
		(n.material_override as ShaderMaterial).set_shader_parameter(param, value)
		# A keyed uniform goes on from its new value.
		if active._tw_params.has(n) and active._tw_params[n].has(param):
			active._tw_params[n][param][0] = value
			active._tw_last = -1.0


func _show_extra(id: int) -> void:
	if _extra_nodes.has(id) or not extras.has(id):
		return
	var node := _make_pass(extras[id]["spec"], str(extras[id]["owner"]), 16)
	if node != null:
		_extra_nodes[id] = node
		sync_pre_aa()


static func _fsr2_flag(vp: Viewport) -> float:
	if vp != null and Settings.fsr2_fixes_enabled() and vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR2:
		return 1.0
	return 0.0


func _sync_reactive_clear(vp: Viewport) -> void:
	var need := _fsr2_flag(vp) > 0.5 and (not _pass_nodes.is_empty() or not _extra_nodes.is_empty())
	if need and _reactive_clear == null:
		var m := ShaderMaterial.new()
		m.shader = REACTIVE_CLEAR_SHADER
		m.render_priority = -101
		var quad := QuadMesh.new()
		quad.size = Vector2(2.0, 2.0)
		var mi := MeshInstance3D.new()
		mi.mesh = quad
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.extra_cull_margin = 16384.0
		mi.sorting_offset = 100000.0
		mi.name = "LookReactiveClear"
		add_child(mi)
		_reactive_clear = mi
	if _reactive_clear != null:
		_reactive_clear.visible = need


func sync_pre_aa(vp: Viewport = null) -> void:
	var v := vp if vp != null else (get_viewport() if is_inside_tree() else null)
	var amt := Settings.look_pre_aa_for(v)
	var fsr2 := _fsr2_flag(v)
	for n: MeshInstance3D in _pass_nodes + _extra_nodes.values():
		var m := n.material_override as ShaderMaterial
		if m != null:
			m.set_shader_parameter("look_pre_aa", amt)
			m.set_shader_parameter("look_fsr2", fsr2)
	_sync_reactive_clear(v)


static func _shader_of(spec: Dictionary) -> Shader:
	var shader = spec.get("shader")
	if shader is String:
		shader = load(shader) if ResourceLoader.exists(shader) or FileAccess.file_exists(shader) else null
	if not shader is Shader or (shader as Shader).get_mode() != Shader.MODE_SPATIAL:
		return null
	return shader


## A pass's quad. `base` orders it: a look's own passes first (0 up), then those over every look (16
## up), each list in its order.
func _make_pass(spec: Dictionary, owner: String, base := 0) -> MeshInstance3D:
	var shader := _shader_of(spec)
	if shader == null:
		push_warning("looks: a pass from %s has no spatial shader" % (owner if owner != "" else "Zenith"))
		return null
	var m := ShaderMaterial.new()
	m.shader = shader
	# Before every other see-through thing (-101 is reserved for LookReactiveClear, cloud shadows are
	# at -100), so it reads and replaces only the solid scene; later passes draw after earlier ones.
	var n := _pass_nodes.size() if base == 0 else _extra_nodes.size()
	m.render_priority = clampi(-128 + base + int(spec.get("order", n)), -128, -102)
	var params: Dictionary = spec.get("params", {})
	for k in params:
		m.set_shader_parameter(k, params[k])
	if is_inside_tree():
		var vp := get_viewport()
		m.set_shader_parameter("look_pre_aa", Settings.look_pre_aa_for(vp))
		m.set_shader_parameter("look_fsr2", _fsr2_flag(vp))
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 16384.0  # it covers the screen wherever it is
	# First of whatever shares its priority: Godot sorts those by their distance from the camera, and
	# the quad's is the world's origin. The flat ground clutter's lowest kinds share -128 with the first
	# pass (decoratives.gd _flat_priority), and their chunks further away than the origin (most of them
	# round the spawn) were drawn first and then covered: the pass writes the solid scene from the
	# screen copy over the whole screen.
	mi.sorting_offset = -100000.0
	mi.name = "LookPass"
	add_child(mi)
	return mi
