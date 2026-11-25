extends Node3D
## What weapons fire, drawn as Factorio draws it: each shot's muzzle flash, hit and shell casing
## (`shot`), projectiles, flamethrower streams and beams in flight with their smoke trails and
## lights, the explosions and scorch marks where they end (`pj`), and fires and clouds on the
## ground (`gf`). Everything comes from Factorio's own prototypes (data/weapon_fx.json, written by
## tools/weapon_fx_index.py) and its sprite sheets in the player's install, cut into atlases for
## sprite_fx.gd's pooled cards. Without an install nothing is drawn.
##
## A headless server makes no explosion marked only_when_visible (muzzle flashes, bullet hits, a
## rocket's explosion), so they are played here from the shot or the projectile's end; one the
## game did make (`pj.x`) is skipped when the same was just played nearby.
##
## Factorio draws in 2D, so heights are ours: a sprite's upward shift becomes height, projectiles
## fly about a tile up, streams and thrown capsules arc, artillery shells climb high.
##
## Heights are over the flat world: on an add-on's hills (ground_height.gd) sprite_fx.gd's cards are
## lifted in their shader, as the models are. The lights are placed here, so they are lifted by the
## height under them: an explosion's once as it goes off, a fire's again only when the hills change,
## a projectile's each frame it is among the lights drawn.

const SpriteFx := preload("res://scripts/fx/sprite_fx.gd")
const SoundBank := preload("res://scripts/fx/sound_bank.gd")
const Sfx := preload("res://scripts/fx/sfx.gd")
const FxSettings := preload("res://scripts/fx/fx_settings.gd")
const Avatar := preload("res://scripts/player/avatar.gd")
const MoverLayer := preload("res://scripts/world/movers.gd")
## world.gd and capsule_aim.gd are read when used, not preloaded: they name the Bridge autoload, which
## a script run on its own (the Model packs window's preview's test, model_preview_test.gd) lacks.
const WORLD_SCRIPT := "res://scripts/world/world.gd"
const CAPSULE_AIM_SCRIPT := "res://scripts/player/capsule_aim.gd"
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const TracerShader := preload("res://shaders/fx_tracer.gdshader")
const CombatLights := preload("res://scripts/fx/combat_lights.gd")
const Switches := preload("res://scripts/switches.gd")

const DATA_PATH := "res://data/weapon_fx.json"
const TICKS := 60.0
const MAX_LIGHTS := 16  # `--combat-lights=old`
## Combat lights (combat_lights.gd): the pool's size, the lights picked by how much of the screen
## they light (brightness and reach against the distance to the camera), not by the character.
const MAX_LIGHTS_NEW := 32
const MAX_FLASHES := 96
## Every explosion lights its surroundings by its size (its widest sprite, tiles): under
## EX_LIGHT_MIN_SIZE none; energy 0.8 + 0.9 a tile (1-10), reach 3 + 2.2 a tile (4-28), for 0.8 of
## its sprite's life (0.2-2 s), fading fast then slowly. The nuke's own, much bigger.
const EX_LIGHT_MIN_SIZE := 0.6
const EX_LIGHT_COLOUR := Color(1.0, 0.62, 0.3)
## Bullet hits and the muzzle flash's own sprite stay dark here (the shot's muzzle light is lit instead).
const EX_DARK := ["explosion-hit", "small-explosion-hit", "explosion-gunshot", "explosion-gunshot-small"]
const NUKE_LIGHT := [20.0, 64.0, 3.0]  # energy, reach, seconds
const EX_MERGE_RANGE := 2.5  # explosions this close within EX_MERGE_SECONDS share one light
const EX_MERGE_SECONDS := 0.15
## A shot's muzzle light, by ammo kind: [energy, reach, seconds]; one light per shooter, refreshed by
## each shot, so a burst holds it lit instead of strobing the pool.
const MUZZLE_BULLET := [3.0, 8.0, 0.08]
const MUZZLE_SHOTGUN := [4.0, 9.0, 0.1]
const MUZZLE_HEAVY := [6.0, 11.0, 0.14]  # cannon shells, rockets, artillery
const MUZZLE_COLOUR := Color(1.0, 0.72, 0.38)
## Flamethrower streams: a light where each lands and one along its arc, flickering; and the fires
## they leave, merged a few tiles apart, brighter and wider (12-16 tiles) to be seen from far out.
const STREAM_LAND_LIGHT := [3.2, 13.0]
const STREAM_MID_LIGHT := [2.0, 8.0]
const FIRE_LIGHT := [3.0, 13.0]  # energy at full alpha, reach
const FIRE_LIGHT_MAX := [4.5, 16.0]  # merged fires' cap
const FIRE_MERGE := 3.0  # tiles: fires this close share one light
const FIRE_COLOUR := Color(1.0, 0.5, 0.18)
const FLASH_MIN_RANGE := 6.0  # a flash reaches the ground round it, however small
const DEDUP_SECONDS := 0.6
const DEDUP_RANGE := 1.5
const SCORCH_SECONDS := 120.0  # the game keeps them 10 minutes; ours fade sooner
const BURNT_SECONDS := 30.0  # fire's burnt_patch_lifetime 1800 ticks
const CASING_SECONDS := 10.0  # shell-particle's life_time 600 ticks
## How near the `en` target point a mover or the character must be for acid to land on its drawn
## position (it moves between the mod's `en`, which comes every 10 ticks).
const ACID_SNAP := 2.5
const CASING_LIMIT := 60
const CASING_GRAVITY := 14.0  # tiles/s²
const MUZZLE_HEIGHT := 1.1
const FLY_HEIGHT := 0.8
const HIT_HEIGHT := 0.45
const ARTILLERY_HEIGHT := 9.0
const THROW_ARC := 1.4
const STREAM_PARTICLES := 60
const STREAM_SHOOTERS := ["fluid-turret", "turret", "car"]
## Flamethrower streams: how far from where one lands its turret or tank may stand (the turret's
## range is 30, the tank's flamethrower's 9), and the character's (the handheld one's range is 15).
const FLAME_REACH := 34.0
const HAND_FLAME_REACH := 18.0
const FLAME_SHOOTERS := ["fluid-turret", "car"]
const NEAR_SHOOTER := 2.0
## Flamethrowers' ranges (tiles): the turret's 30, the tank's 9, the handheld one's 15; a stream
## lands no farther (the guns' clamp_position), its target then pushed out to it when none is known.
const FLAME_RANGE_TURRET := 30.0
const FLAME_RANGE_TANK := 9.0
const FLAME_RANGE_HAND := 15.0
## A flame's arc: Factorio's flight (va * T² / 8 at the top, T = distance / hs ticks) times this,
## as Factorio draws a stream's height straight up the screen and our angled view (50° down)
## shortens it, and at least this much of the distance, so the tank's fast, low stream lobs too.
const FLAME_ARC_LIFT := 1.35
const FLAME_ARC_MIN := 0.12
const GROUND_CARDS := 600
const ATLAS_MAX := 4096
const CAPSULES := ["grenade", "cluster-grenade", "poison-capsule", "slowdown-capsule", "defender-capsule",
	"distractor-capsule", "destroyer-capsule", "cliff-explosives"]


class Flyer:
	var name := ""
	var kind := 0  # 0 projectile, 2 artillery shell, 3 thrown capsule
	var rec := {}
	var cards: Array = []  # [Card, width, height]
	var shadow: SpriteFx.Card
	var pos := Vector2.ZERO  # where the game last had it
	var vel := Vector2.ZERO  # tiles per second
	var at_msec := 0
	var first := Vector2.ZERO
	var near_shooter := false
	var landing := 0.0  # how far it goes, when known (the character's thrown capsules)
	var smoke_due := 0.0
	var seen := 0


## A stream entity stays where the game made it while its particles fly inside it, and the API
## says neither where it comes from nor where it goes (2.1.23): the particles are flown here,
## from the shooter's muzzle to its target at the prototype's speed, interval and arc.
class Stream:
	var name := ""
	var rec := {}
	var pos := Vector2.ZERO
	var alive := true
	var seen := 0
	var age := 0.0
	var from := Vector3.ZERO
	var to := Vector3.ZERO
	var placed := 0.0  # seconds until its ends are worked out again
	var shooter = null  # Vector3 of the turret or mover it comes from, once found
	var shooter_unit := 0  # that turret's or mover's unit number (0: none known)
	var searched := false  # no building shoots it: not looked for again
	var particles: Array = []  # [Card, age, flight seconds, from, to, arc height]
	var spawn_due := 0.0
	var custom := false
	var turret_lit := false  # its turret's or tank's nozzle found: turrets.gd lights it and its landing
	var lead := true  # the newest stream of its shooter: only it feeds particles (`--flame-streams=old`: all)
	var owner_key := ""  # its shooter, for one drawn stream a shooter ("" none known)


class Beam:
	var name := ""
	var rec := {}
	var src := -1  # what it comes from: a turret's or combat robot's unit, 0 none found, -1 not looked for
	var src_turret := false  # `src` is a turret (turrets.gd), else a mover (a combat robot)
	var from := Vector3.ZERO
	var to := Vector3.ZERO
	var cards: Array = []
	var seen := 0


class Ground:
	var name := ""
	var fire := false
	var custom := false
	var rec := {}
	var pos := Vector3.ZERO
	var cards: Array = []  # [Card, base alpha]
	var born := 0.0
	var ttl := -1.0  # seconds left, for clouds
	var fade_in := 0.5
	var fade_out := 1.0
	var gone := -1.0  # seconds fading since it left the list
	var seen := 0
	var hills := 0.0  # the hills' height under it, read at GroundHeight.version() hills_v
	var hills_v := -1


var sprites: SpriteFx
var sfx: Node  # sfx.gd
var avatar: Avatar
var movers: MoverLayer
var world: Node  # world.gd
var turrets: Node  # turrets.gd (main.gd): the game's laser and tesla beams start at a turret's emitter
var on_stream_hook: Callable = Callable()
## combat_sounds.gd (fx.gd's): capsule throws, acid streams' and the nuke's sounds; null in the turret preview.
var extra_sounds = null
var on_ground_hook: Callable = Callable()
## Where the character aims (tiles) while it shoots at a point, so its stream lands there, and
## whether it is firing a stream gun (the flamethrower); set by fx.gd.
var aim = null
var hand_stream := false
## On a space platform: no scorch marks or burnt patches (Factorio only makes them where they can
## be placed, and the owner saw them drawn on empty space, #16).
var in_space := false
## `--laser-origin=old`: the game's beams (`pj`) start over the source entity's centre, 1.2 tiles up.
static var laser_origin_old := Switches.has("--laser-origin=old")
## Acid lands where its spitter or worm is attacking (`en`, Creatures.attack_target), on the mover or
## the character there now; `--acid-aim=old` keeps the old guess (the character within 30 tiles, else
## mirrored through the shooter).
static var acid_aim_real := not (Switches.has("--acid-aim=old"))
## `--flame-origin=old`: flamethrower streams placed as acid is (from whatever stands near the
## stream entity, to the nearest enemy), which drew them from where they land (see _place_flame).
static var flame_origin_old := Switches.has("--flame-origin=old")
## `--flame-streams=old`: every live flamethrower stream entity drawn as its own arc to where the
## entity is (a turret's are made every 4 ticks a step short of the target: a fan of short arcs);
## else one stream a shooter, landing at its target, in a higher arc.
static var flame_streams_old := Switches.has("--flame-streams=old")

var data := {}
var _pools := {}  # layer key -> sprite_fx pool name, "" when its sheet is missing
## Pool key -> [task id, result, layer, cyclic, flat, capacity, fade in, fade out] while its atlas
## is made on a worker thread (_pool).
var _pending := {}
## Sheets read while making atlases, shared by the workers: file -> Image, and file -> true when it
## has no alpha channel.
static var _images := {}
static var _opaque := {}
static var _images_lock := Mutex.new()
var _flying := {}  # id -> Flyer
var _streams := {}  # id -> Stream
var _flame_lead := {}  # shooter key -> id of its newest stream (the one drawn feeding)
var _beams := {}  # id -> Beam
var _ground := {}  # id -> Ground
var _recent: Array = []  # [name, Vector2, msec]: explosions played here, to skip the game's own
var _casings: Array = []  # [Card, resting]
var _flashes: Array = []  # [position, colour, energy, range, age, life, fast fade, shooter (0: an explosion)]
var _fire_cells := {}  # Vector2i -> index in the frame's wants: fires merged (combat lights)
var _by_score := func(a: Array, b: Array) -> bool: return float(a[5]) < float(b[5])
var _lights: Array = []
var _sounds := {}  # file -> msec last played
var _pj_tick := -1
var _mark := 0
var _clock := 0.0
## How many times each explosion prototype was played (weapons_demo.gd prints it).
var played := {}

## Bullet tracers: a short, fast, additive streak from the muzzle to the hit per shot (a look of
## ours; Factorio draws none). Settings > Graphics "Bullet tracers"; `--bullet-tracers=off` wins.
static var tracers_setting := true
static var tracers_arg_off := not Switches.on("--bullet-tracers")
const MAX_TRACERS := 96
const TRACER_LIFE := 0.075  # seconds a streak takes from muzzle to hit
const TRACER_FADE := 0.03  # and then fades at the hit
const TRACER_WIDTH := 0.05  # tiles, near; wider with the camera's distance so it stays seen
const TRACER_WIDTH_FAR := 0.0045  # width per tile of camera distance
const TRACER_GAP := 0.03  # seconds between one shooter's tracers at most
const TRACER_PELLETS := 4  # a shotgun shell's streaks, of its 12-18 pellets
const TRACER_SPREAD := 0.12  # pellets' spread at the target, per tile of distance
## Ammo -> its streak's colour: yellow for firearm magazines, redder for piercing, greener for uranium.
const TRACER_COLOURS := {
	"firearm-magazine": Color(1.0, 0.8, 0.35), "piercing-rounds-magazine": Color(1.0, 0.42, 0.2),
	"uranium-rounds-magazine": Color(0.55, 1.0, 0.3), "shotgun-shell": Color(1.0, 0.75, 0.38),
	"piercing-shotgun-shell": Color(1.0, 0.45, 0.22),
}
const TRACER_DEFAULT := Color(1.0, 0.8, 0.35)
var _tracer_mmi: MultiMeshInstance3D
var _tracers: Array = []  # [from, to, age, colour], the oldest first
var _tracer_last := {}  # shooter -> _clock of its last tracer
var tracers_drawn := 0  # tracers started (for tests)


## The setting (Settings > Graphics "Bullet tracers"), main.gd's apply.
static func set_tracers(setting: bool) -> void:
	tracers_setting = setting


static func tracers_on() -> bool:
	return tracers_setting and not tracers_arg_off


## A streak from `from` to `to` (world, over flat ground; lifted by the hills here) in `ammo`'s
## colour ("": a firearm magazine's); `pellets` streaks spread round the target for a shotgun.
## At most one a TRACER_GAP per `shooter` (a unit number, 0 for none) and MAX_TRACERS at once.
func tracer(from: Vector3, to: Vector3, ammo := "", shooter := 0, pellets := 1) -> void:
	if not tracers_on() or sprites == null:
		return
	if shooter != 0:
		if _clock - float(_tracer_last.get(shooter, -1.0)) < TRACER_GAP:
			return
		_tracer_last[shooter] = _clock
		if _tracer_last.size() > 512:
			_tracer_last.clear()
	var colour: Color = TRACER_COLOURS.get(ammo, TRACER_DEFAULT)
	var a := from + Vector3(0.0, GroundHeight.at(from.x, from.z), 0.0)
	var flat := Vector2(to.x - from.x, to.z - from.z)
	for i in maxi(1, pellets):
		var end := to
		if pellets > 1:
			var side := Vector2(-flat.y, flat.x).normalized() * randf_range(-1.0, 1.0) * TRACER_SPREAD * flat.length()
			end = to + Vector3(side.x, randf_range(-0.15, 0.15), side.y)
		var b := end + Vector3(0.0, GroundHeight.at(end.x, end.z), 0.0)
		if a.distance_squared_to(b) < 0.25:
			continue
		if _tracers.size() >= MAX_TRACERS:
			_tracers.pop_front()
		_tracers.append([a, b, 0.0, colour])
		tracers_drawn += 1


## Each streak's head runs from the muzzle to the hit in TRACER_LIFE, its tail a third of the way
## behind (at most 4 tiles), then it fades at the hit: one MultiMesh of camera-facing quads.
func _update_tracers(delta: float) -> void:
	if _tracers.is_empty():
		if _tracer_mmi != null and _tracer_mmi.multimesh.visible_instance_count != 0:
			_tracer_mmi.multimesh.visible_instance_count = 0
		return
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if _tracer_mmi == null:
		_tracer_mmi = MultiMeshInstance3D.new()
		_tracer_mmi.name = "Tracers"
		_tracer_mmi.top_level = true
		_tracer_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_tracer_mmi.custom_aabb = AABB(Vector3(-1e6, -1e3, -1e6), Vector3(2e6, 2e3, 2e6))
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE
		var mat := ShaderMaterial.new()
		mat.shader = TracerShader
		mat.render_priority = 2
		quad.material = mat
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = quad
		mm.instance_count = MAX_TRACERS
		mm.visible_instance_count = 0
		_tracer_mmi.multimesh = mm
		add_child(_tracer_mmi)
		_tracer_mmi.global_transform = Transform3D.IDENTITY
	var mm := _tracer_mmi.multimesh
	var n := 0
	var keep: Array = []
	var step := minf(delta, 1.0 / 30.0)  # a slow frame doesn't end a streak before it is seen
	for t: Array in _tracers:
		t[2] = float(t[2]) + step
		var age: float = t[2]
		if age >= TRACER_LIFE + TRACER_FADE:
			continue
		keep.append(t)
		if cam == null:
			continue
		var a: Vector3 = t[0]
		var b: Vector3 = t[1]
		var span := b - a
		var dist := span.length()
		var tail_len := minf(dist * 0.33, 4.0)
		var head_k := minf(age / TRACER_LIFE, 1.0)
		var head := a + span * head_k
		var tail_d := maxf(dist * head_k - tail_len, 0.0)
		if age > TRACER_LIFE:
			tail_d = lerpf(tail_d, dist, (age - TRACER_LIFE) / TRACER_FADE)  # the tail catches up
		var tail := a + span * (tail_d / dist)
		var along := head - tail
		var length := along.length()
		if length < 0.02:
			continue
		var mid := (head + tail) * 0.5
		var x := along / length
		var view := cam.global_position - mid
		var y := x.cross(view).normalized()
		if y.length_squared() < 0.001:
			y = Vector3.UP
		var width := TRACER_WIDTH + TRACER_WIDTH_FAR * view.length()
		mm.set_instance_transform(n, Transform3D(Basis(x * length, y * width, x.cross(y).normalized()), mid))
		var colour: Color = t[3]
		mm.set_instance_color(n, Color(colour.r, colour.g, colour.b, 1.0))
		n += 1
	_tracers = keep
	mm.visible_instance_count = n


func _ready() -> void:
	var f := FileAccess.open(DATA_PATH, FileAccess.READ)
	if f != null:
		var parsed = JSON.parse_string(f.get_as_text())
		if parsed is Dictionary:
			data = parsed
	for i in (MAX_LIGHTS if CombatLights.old else MAX_LIGHTS_NEW):
		var light := OmniLight3D.new()
		light.visible = false
		light.shadow_enabled = false
		CombatLights.configure_light(light)
		add_child(light)
		_lights.append(light)


func reset() -> void:
	for f: Flyer in _flying.values():
		_drop_cards(f.cards)
		if f.shadow != null:
			sprites.kill(f.shadow)
	for b: Beam in _beams.values():
		_drop_cards(b.cards)
	for g: Ground in _ground.values():
		_drop_cards(g.cards)
	for st: Stream in _streams.values():
		_drop_cards(st.particles)
	_flying.clear()
	_streams.clear()
	_flame_lead.clear()
	_beams.clear()
	_ground.clear()
	_recent.clear()
	_tracers.clear()
	_tracer_last.clear()
	_casings.clear()
	_flashes.clear()
	for light: OmniLight3D in _lights:
		light.visible = false
		light.shadow_enabled = false
	CombatLights.clear_shadow_source(get_instance_id())
	if on_stream_hook.is_valid():
		on_stream_hook.call({"event": "reset"})
	if on_ground_hook.is_valid():
		on_ground_hook.call({"event": "reset"})


static func _is_acid_ground(name: String) -> bool:
	return name.contains("acid-splash-fire")


func status() -> String:
	return "%d flying, %d streams, %d beams, %d fires/clouds" % [_flying.size(), _streams.size(), _beams.size(), _ground.size()]


## Projectiles and streams in flight.
func flying_count() -> int:
	return _flying.size() + _streams.size()


func ground_count() -> int:
	return _ground.size()


func beam_count() -> int:
	return _beams.size()


func handle(msg: Dictionary) -> void:
	if data.is_empty() or sprites == null:
		return
	match str(msg.get("t", "")):
		"shot":
			_on_shot(msg)
		"pj":
			_on_flying(msg)
		"gf":
			_on_ground(msg)


## The explosion a prototype leaves when it dies (Factorio's dying_explosion), or "".
func dying_explosion(entity: String) -> String:
	return str(data.get("dying", {}).get(entity, ""))


## Every file an explosion's sound can play (fx.gd decodes them ahead of a fight).
func explosion_sound_files() -> Array:
	var out: Array = []
	for name in data.get("ex", {}):
		var snd = data["ex"][name].get("snd")
		if snd is Array:
			for pick in snd:
				if pick is Array and not pick.is_empty() and not out.has(str(pick[0])):
					out.append(str(pick[0]))
	return out


## True when explode(`name`) plays a sound of its own (it has drawn variations and a `snd`).
func explosion_has_sound(name: String) -> bool:
	if name == "":
		return false
	var rec: Dictionary = data.get("ex", {}).get(name, {})
	return rec.has("snd") and not rec.get("v", []).is_empty()


func gun_cooldown(gun: String) -> float:
	var rec: Dictionary = data.get("gun", {}).get(gun, {})
	return float(rec.get("cd", 15.0)) / TICKS


# --- Shots ------------------------------------------------------------------------------------------

## One round: the ammo's source effects at the muzzle (the flash), an instant hit's effects at
## the target, the railgun's beam along its line, and the gun's shell casing.
func _on_shot(msg: Dictionary) -> void:
	var unit := int(msg.get("u", 0))
	var target := Vector3(int(msg.get("x", 0)) / 256.0, HIT_HEIGHT, int(msg.get("y", 0)) / 256.0)
	var muzzle := Vector3.ZERO
	var from_avatar := avatar != null and unit == avatar.unit
	if from_avatar:
		muzzle = avatar.muzzle_position()
	else:
		var p = movers.position_of(unit) if movers != null else null
		if p == null:
			return
		var at: Vector3 = p
		muzzle = at + Vector3(0, MUZZLE_HEIGHT, 0)
	var ammo: Dictionary = data.get("ammo", {}).get(str(msg.get("a", "")), {})
	var gun: Dictionary = data.get("gun", {}).get(str(msg.get("g", "")), {})
	var dir := target - muzzle
	dir.y = 0.0
	dir = dir.normalized() if dir.length() > 0.01 else Vector3.FORWARD
	for pair in ammo.get("src", []):
		explode(str(pair[0]), muzzle, dir)
	var ammo_name := str(msg.get("a", ""))
	if not CombatLights.old:
		var light_offset := 0.3 if from_avatar else 0.75
		_muzzle_light(unit, muzzle + dir * light_offset, ammo)
	if str(ammo.get("k", "")) == "instant":
		var hit := target + Vector3(randf_range(-0.5, 0.5), 0.0, randf_range(-0.5, 0.5))
		for pair in ammo.get("tgt", []):
			explode(str(pair[0]), hit)
		if TRACER_COLOURS.has(ammo_name) or ammo_name.ends_with("-magazine"):
			tracer(muzzle + dir * 0.1, hit, ammo_name, unit)
	elif str(ammo.get("k", "")) == "projectile" and int(ammo.get("n", 0)) > 1:
		tracer(muzzle + dir * 0.1, target, ammo_name, unit, mini(int(ammo.get("n", 0)), TRACER_PELLETS))
	elif str(ammo.get("k", "")) == "line" and str(ammo.get("line", "")) != "":
		_line_explosion(str(ammo["line"]), muzzle, muzzle + dir * float(gun.get("r", 40.0)))
	var shell = gun.get("shell")
	if shell is Array and shell.size() >= 4:
		_casing(str(shell[0]), muzzle, dir, float(shell[1]), float(shell[2]), float(shell[3]))
	if avatar != null and unit == avatar.unit:
		avatar.kick(clampf(float(gun.get("cd", 15.0)) / 30.0, 0.5, 1.6))


## A shot's light at the muzzle (combat lights), whatever its source explosion: one per shooter,
## refreshed by its next shot; none when turrets.gd lights that shooter's shots itself.
func _muzzle_light(unit: int, at: Vector3, ammo: Dictionary) -> void:
	if CombatLights.strength <= 0.0:
		return
	if unit != 0 and turrets != null and turrets.has_method("lights_shots") and bool(turrets.call("lights_shots", unit)):
		return
	var kind := str(ammo.get("k", ""))
	var spec: Array = MUZZLE_BULLET
	if kind == "projectile":
		spec = MUZZLE_SHOTGUN if int(ammo.get("n", 0)) > 1 else MUZZLE_HEAVY
	elif kind == "line":
		spec = MUZZLE_HEAVY
	elif kind != "instant":
		return  # streams and beams have their own
	var pos := GroundHeight.lift(at)
	if unit != 0:
		for fl: Array in _flashes:
			if int(fl[7]) == unit:
				fl[0] = pos
				fl[2] = maxf(float(fl[2]), float(spec[0]))
				fl[3] = maxf(float(fl[3]), float(spec[1]))
				fl[4] = 0.0
				fl[5] = maxf(float(fl[5]), float(spec[2]))
				return
	if _flashes.size() < MAX_FLASHES:
		_flashes.append([pos, MUZZLE_COLOUR, float(spec[0]), float(spec[1]), 0.0, float(spec[2]), false, unit])


## Factorio's shell particle: thrown out sideways from beside the gun, spinning (5 frames), and
## left lying for 600 ticks.
func emit_casing(particle: String, muzzle: Vector3, dir: Vector3, creation := 0.3, speed := 0.1, vspeed := 0.05) -> void:
	if sprites != null and FxSettings.effects_enabled:
		_casing(particle, muzzle, dir, creation, speed, vspeed)


func _casing(particle: String, muzzle: Vector3, dir: Vector3, creation: float, speed: float, vspeed: float) -> void:
	var rec: Dictionary = data.get("pa", {}).get(particle, {})
	var layer := _pick_layer(rec.get("a", []))
	if layer.is_empty():
		return
	var pool := _pool(layer, true, false, CASING_LIMIT + 8)
	if pool == "":
		return
	var side := dir.cross(Vector3.UP).normalized()
	var at := muzzle + dir * creation * 0.5 - Vector3(0, 0.15, 0)
	var c := sprites.emit(pool, at, _width(layer), CASING_SECONDS)
	if c == null:
		return
	c.vel = (side * randf_range(0.35, 0.55) * speed + dir * randf_range(-0.01, 0.01)) * TICKS + Vector3(0, maxf(vspeed, 0.03) * TICKS * 0.5, 0)
	c.rise = -CASING_GRAVITY
	c.fps = 15.0
	_casings.append([c, false])
	while _casings.size() > CASING_LIMIT:
		var old: Array = _casings.pop_front()
		sprites.kill(old[0])


func _update_casings() -> void:
	for i in range(_casings.size() - 1, -1, -1):
		var entry: Array = _casings[i]
		var c: SpriteFx.Card = entry[0]
		if c.age >= c.life:
			_casings.remove_at(i)
		elif not entry[1] and c.pos.y <= 0.04 and c.vel.y < 0.0:
			# Lands, skids a little, and lies there.
			c.pos.y = 0.04
			c.vel = Vector3.ZERO
			c.rise = 0.0
			c.fps = 0.0
			entry[1] = true


# --- Explosions -------------------------------------------------------------------------------------

## Plays explosion prototype `name` at `at` (y is how high above the ground it happens). `dir`
## turns explosions that rotate (Factorio's `rotate`), such as the railgun's beam.
func explode(name: String, at: Vector3, dir := Vector3.ZERO) -> void:
	var rec: Dictionary = data.get("ex", {}).get(name, {})
	var variations: Array = rec.get("v", [])
	if variations.is_empty():
		return
	_recent.append([name, Vector2(at.x, at.z), Time.get_ticks_msec()])
	played[name] = int(played.get(name, 0)) + 1
	var layers: Array = variations[randi() % variations.size()]
	var life := 0.1
	for layer: Array in layers:
		var pool := _pool(layer, false, false, 48)
		if pool == "":
			continue
		var w := _width(layer)
		var h := _height(layer)
		var shift: Array = layer[7]
		var lift := -float(shift[1])
		var y := at.y + lift if at.y > 0.1 else maxf(lift, h * 0.4)
		var frames := int(layer[3])
		var speed := maxf(float(layer[5]), 0.01)
		var l := clampf(frames / (speed * TICKS), 0.05, 6.0)
		life = maxf(life, l)
		var c := sprites.emit(pool, Vector3(at.x + float(shift[0]), y, at.z), w, l, _tint(layer))
		if c != null and rec.has("rot") and dir != Vector3.ZERO:
			c.spin = _screen_angle(dir, true)
	var light = rec.get("l")
	if not CombatLights.old:
		_explosion_light(name, at, layers, light, life)
	elif light is Array and light.size() >= 3:
		var col: Array = light[2]
		_flashes.append([GroundHeight.lift(at + Vector3(0, 0.5, 0)), Color(float(col[0]), float(col[1]), float(col[2])), float(light[0]) * 3.0,
			clampf(float(light[1]) * 0.5, 2.0, 16.0), 0.0, life, false, 0])
	var smoke = rec.get("sm")
	if smoke is Array and smoke.size() >= 2:
		for i in mini(int(smoke[1]), 6):
			_smoke(str(smoke[0]), at + Vector3(randf_range(-0.3, 0.3), 0.3, randf_range(-0.3, 0.3)),
				Vector3(randf_range(-0.4, 0.4), randf_range(0.2, 0.6), randf_range(-0.4, 0.4)))
	var snd = rec.get("snd")
	if snd is Array and not snd.is_empty() and sfx != null:
		var pick: Array = snd[randi() % snd.size()]
		var file := str(pick[0])
		var now := Time.get_ticks_msec()
		if now - int(_sounds.get(file, -1000)) > 60 or Sfx.pool:
			_sounds[file] = now
			sfx.play_at(file, at, float(pick[1]), 0.05, 1.0, "Explosions", "explosion/" + name)


## An explosion Factorio stretches along a line (railgun-beam): its sprite laid end to end.
func _line_explosion(name: String, from: Vector3, to: Vector3) -> void:
	var rec: Dictionary = data.get("ex", {}).get(name, {})
	var layer := _pick_layer(rec.get("v", []))
	if layer.is_empty():
		return
	var pool := _pool(layer, false, false, 48)
	if pool == "":
		return
	var length := from.distance_to(to)
	var step := _height(layer)  # the beam runs along the sheet's tall side
	var n := clampi(ceili(length / maxf(step, 0.5)), 1, 12)
	var dir := (to - from).normalized()
	var life := clampf(int(layer[3]) / (maxf(float(layer[5]), 0.01) * TICKS), 0.05, 2.0)
	for i in n:
		var c := sprites.emit(pool, from + dir * (length * (i + 0.5) / n), _width(layer), life, _tint(layer))
		if c != null:
			c.spin = _screen_angle(dir, true)
	_recent.append([name, Vector2(from.x, from.z), Time.get_ticks_msec()])
	played[name] = int(played.get(name, 0)) + 1
	var light = rec.get("l")
	if light is Array and light.size() >= 3:
		var col: Array = light[2]
		if CombatLights.old:
			_flashes.append([GroundHeight.lift(from.lerp(to, 0.2)), Color(float(col[0]), float(col[1]), float(col[2])), float(light[0]) * 2.0, 10.0, 0.0, life, false, 0])
		elif _flashes.size() < MAX_FLASHES:
			_flashes.append([GroundHeight.lift(from.lerp(to, 0.2)), Color(float(col[0]), float(col[1]), float(col[2])), float(light[0]) * 3.0, 16.0, 0.0,
				maxf(life, 0.25), true, 0])


## An explosion's light (combat lights), by its size; a prototype light (`l`) keeps its colour and
## gets at least that size's brightness. Explosions close together at once share one light.
func _explosion_light(name: String, at: Vector3, layers: Array, light, life: float) -> void:
	if CombatLights.strength <= 0.0 or name in EX_DARK or name.contains("blood"):
		return
	var size := 0.0
	for layer: Array in layers:
		size = maxf(size, _width(layer))
	var energy := clampf(0.8 + size * 0.9, 1.0, 10.0)
	var reach := clampf(3.0 + size * 2.2, 4.0, 28.0)
	var secs := clampf(life * 0.8, 0.2, 2.0)
	var colour := EX_LIGHT_COLOUR
	if light is Array and light.size() >= 3:
		var col: Array = light[2]
		colour = Color(float(col[0]), float(col[1]), float(col[2]))
		energy = maxf(energy, float(light[0]) * 4.8)
		reach = maxf(reach, clampf(float(light[1]) * 0.8, 4.0, 28.0))
		secs = maxf(secs, 0.3)
	elif size < EX_LIGHT_MIN_SIZE:
		return
	if name == "nuke-explosion" or name.begins_with("atomic"):
		energy = maxf(energy, float(NUKE_LIGHT[0]))
		reach = maxf(reach, float(NUKE_LIGHT[1]))
		secs = maxf(secs, float(NUKE_LIGHT[2]))
	var pos := GroundHeight.lift(at + Vector3(0, 0.5 + minf(size * 0.15, 3.0), 0))
	for fl: Array in _flashes:
		if int(fl[7]) == 0 and float(fl[4]) < EX_MERGE_SECONDS and (fl[0] as Vector3).distance_to(pos) < EX_MERGE_RANGE:
			fl[2] = maxf(float(fl[2]), energy)
			fl[3] = maxf(float(fl[3]), reach)
			fl[5] = maxf(float(fl[5]), secs)
			return
	if _flashes.size() < MAX_FLASHES:
		_flashes.append([pos, colour, energy, reach, 0.0, secs, true, 0])


## A puff of a trivial smoke prototype (smoke-fast behind rockets, soft-fire-smoke over fires).
func _smoke(name: String, at: Vector3, vel: Vector3) -> void:
	var rec: Dictionary = data.get("ts", {}).get(name, {})
	var layer := _pick_layer(rec.get("a", []))
	if layer.is_empty():
		return
	var dur := maxf(float(rec.get("dur", 60)), 1.0)
	var pool := _pool(layer, true, false, 400, 0.0, clampf(float(rec.get("fade", 0)) / dur, 0.1, 0.9))
	if pool == "":
		return
	var col = rec.get("c")
	var tint := Color(float(col[0]), float(col[1]), float(col[2]), float(col[3])) if col is Array and col.size() >= 4 else Color.WHITE
	var c := sprites.emit(pool, at, _width(layer) * float(rec.get("s0", 1.0)), dur / TICKS, tint)
	if c != null:
		c.size1 = _width(layer) * float(rec.get("s1", 1.0))
		c.vel = vel
		c.fps = maxf(float(layer[5]), 0.05) * TICKS


func _played_recently(name: String, at: Vector2) -> bool:
	var now := Time.get_ticks_msec()
	for r: Array in _recent:
		if r[0] == name and now - int(r[2]) < DEDUP_SECONDS * 1000.0 and (r[1] as Vector2).distance_to(at) < DEDUP_RANGE:
			return true
	return false


## Where a projectile ended: its target's explosions and scorch marks.
func _impact(effects: Array, at: Vector2) -> void:
	for pair in effects:
		var name := str(pair[0])
		if data.get("sc", {}).has(name):
			_scorch(name, Vector3(at.x, 0.03, at.y))
		elif not _played_recently(name, at):
			explode(name, Vector3(at.x, 0.0, at.y))


func _scorch(name: String, at: Vector3) -> void:
	if in_space:
		return
	var rec: Dictionary = data.get("sc", {}).get(name, {})
	var layer := _pick_layer(rec.get("a", []))
	if layer.is_empty():
		return
	var pool := _pool(layer, false, true, 120, 0.0, 0.1)
	if pool == "":
		return
	# A tintable patch takes the ground's colour in Factorio; a dark brown reads on every tile.
	var c := sprites.emit(pool, at, _width(layer), SCORCH_SECONDS, Color(0.42, 0.36, 0.3, 0.7))
	if c != null:
		c.angle = randf() * TAU


# --- In flight --------------------------------------------------------------------------------------

func _on_flying(msg: Dictionary) -> void:
	var k := int(msg.get("k", 0))
	var dt := clampf((k - _pj_tick) / TICKS, 1.0 / TICKS, 0.5) if _pj_tick >= 0 else 2.0 / TICKS
	_pj_tick = k
	_mark += 1
	var mark := _mark
	var p := _items(msg.get("p"))
	var i := 0
	while i + 3 < p.size():
		var id := int(p[i])
		var at := Vector2(int(p[i + 2]), int(p[i + 3])) / 256.0
		if data.get("st", {}).has(str(p[i + 1])):
			var st: Stream = _streams.get(id)
			if st == null:
				st = Stream.new()
				st.name = str(p[i + 1])
				st.rec = data["st"][st.name]
				st.pos = at
				_streams[id] = st
				_place_stream(st)
				_take_lead(id, st)
				if extra_sounds != null:
					extra_sounds.stream_start(st.name, st.from if st.from != Vector3.ZERO else Vector3(at.x, MUZZLE_HEIGHT, at.y))
				st.placed = 0.25
				if on_stream_hook.is_valid():
					var sinfo := {
						"event": "start",
						"id": id,
						"name": st.name,
						"pos": st.pos,
						"from": st.from,
						"to": st.to,
						"hs": float(st.rec.get("hs", 0.35)),
						"va": float(st.rec.get("va", 0.0045)),
						"pst": float(st.rec.get("pst", 6)),
						"psi": float(st.rec.get("psi", 1)),
						"handled": false,
					}
					on_stream_hook.call(sinfo)
					if bool(sinfo.get("handled", false)):
						st.custom = true
			st.seen = mark
			i += 4
			continue
		var f: Flyer = _flying.get(id)
		if f == null:
			f = _new_flyer(str(p[i + 1]), at)
			if f != null:
				_flying[id] = f
		else:
			f.vel = (at - f.pos) / dt
		if f != null:
			f.pos = at
			f.at_msec = Time.get_ticks_msec()
			f.seen = mark
		i += 4
	var e := _items(msg.get("e"))
	i = 0
	while i + 2 < e.size():
		var id := int(e[i])
		var f: Flyer = _flying.get(id)
		if f != null:
			var end := Vector2(int(e[i + 1]), int(e[i + 2])) / 256.0 + f.vel / TICKS
			_impact(f.rec.get("hit", []), end)
			if extra_sounds != null:
				extra_sounds.projectile_end(f.name, Vector3(end.x, 0.5, end.y))
			_remove_flyer(id)
		i += 3
	for id in _flying.keys():
		var f: Flyer = _flying[id]
		if f.seen != mark:
			_remove_flyer(id)  # left the area
	for st: Stream in _streams.values():
		if st.seen != mark:
			if st.alive and extra_sounds != null:
				extra_sounds.stream_end(st.name, Vector3(st.pos.x, 0.3, st.pos.y))
			st.alive = false  # its particles still land
	var b := _items(msg.get("b"))
	i = 0
	while i + 5 < b.size():
		var id := int(b[i])
		var beam: Beam = _beams.get(id)
		if beam == null:
			beam = Beam.new()
			beam.name = str(b[i + 1])
			beam.rec = data.get("bm", {}).get(beam.name, {})
			_beams[id] = beam
		var s := Vector2(int(b[i + 2]), int(b[i + 3])) / 256.0
		var t := Vector2(int(b[i + 4]), int(b[i + 5])) / 256.0
		if beam.src < 0:
			_find_beam_source(beam, s)
		beam.from = _beam_source(beam, s)
		beam.to = Vector3(t.x, HIT_HEIGHT, t.y)
		beam.seen = mark
		i += 6
	for id in _beams.keys():
		var beam: Beam = _beams[id]
		if beam.seen != mark:
			_drop_cards(beam.cards)
			_beams.erase(id)
	var x := _items(msg.get("x"))
	i = 0
	while i + 2 < x.size():
		var name := str(x[i])
		var at := Vector2(int(x[i + 1]), int(x[i + 2])) / 256.0
		if not _played_recently(name, at):
			var rec: Dictionary = data.get("ex", {}).get(name, {})
			explode(name, Vector3(at.x, float(rec.get("h", 0.0)) * HIT_HEIGHT, at.y))
		i += 3


func _new_flyer(name: String, at: Vector2) -> Flyer:
	var f := Flyer.new()
	f.name = name
	f.pos = at
	f.first = at
	f.at_msec = Time.get_ticks_msec()
	var layers: Array
	if data.get("pr", {}).has(name):
		f.rec = data["pr"][name]
		f.kind = 2 if f.rec.has("art") else (3 if name in CAPSULES else 0)
		layers = _first_variation(f.rec.get("a", []))
	else:
		return null
	if avatar != null:
		f.near_shooter = Vector2(avatar.position.x, avatar.position.z).distance_to(at) < NEAR_SHOOTER
	if f.kind == 3 and extra_sounds != null:
		extra_sounds.throw(name, Vector3(at.x, FLY_HEIGHT, at.y))
	if f.near_shooter and f.kind == 3:
		var capsule_aim: GDScript = load(CAPSULE_AIM_SCRIPT)
		if Time.get_ticks_msec() - int(capsule_aim.get("last_msec")) < 2000:
			f.landing = at.distance_to(capsule_aim.get("last_target"))
	for layer: Array in layers:
		var pool := _pool(layer, true, false, 256, 0.0, 0.0)
		if pool == "":
			continue
		var c := sprites.emit(pool, Vector3(at.x, FLY_HEIGHT, at.y), _width(layer), 3600.0, _tint(layer))
		if c != null:
			c.fps = maxf(float(layer[5]), 0.0) * TICKS
			c.frame = 0.0
			f.cards.append([c, _width(layer), layer[7]])
	if f.kind == 2 or f.kind == 3:
		f.shadow = _shadow_card(at)
	return f


func _remove_flyer(id: int) -> void:
	var f: Flyer = _flying.get(id)
	if f == null:
		return
	_drop_cards(f.cards)
	if f.shadow != null:
		sprites.kill(f.shadow)
	_flying.erase(id)


## How high a flyer is after `d` tiles: bullets and rockets from the gun's height down towards
## the target's, capsules on an arc to where they land, artillery shells climbing.
func _flyer_height(f: Flyer, d: float) -> float:
	match f.kind:
		2:
			return 1.5 + ARTILLERY_HEIGHT * clampf(d / 12.0, 0.0, 1.0)
		3:
			var l := f.landing if f.landing > 0.5 else 10.0
			var p := clampf(d / l, 0.0, 1.0)
			return lerpf(MUZZLE_HEIGHT, 0.25, p) + THROW_ARC * 4.0 * p * (1.0 - p)
	if f.near_shooter:
		return lerpf(MUZZLE_HEIGHT, FLY_HEIGHT, clampf(d / 8.0, 0.0, 1.0))
	return FLY_HEIGHT


func _update_flyers(delta: float) -> void:
	var now := Time.get_ticks_msec()
	for f: Flyer in _flying.values():
		var ahead := clampf((now - f.at_msec) / 1000.0, 0.0, 0.1)
		var at := f.pos + f.vel * ahead
		var d := at.distance_to(f.first)
		var h := _flyer_height(f, d)
		var p3 := Vector3(at.x, h, at.y)
		var dir := Vector3(f.vel.x, 0.0, f.vel.y)
		for entry: Array in f.cards:
			var c: SpriteFx.Card = entry[0]
			c.pos = p3
			if f.kind == 0 and dir.length() > 0.01:
				c.spin = _screen_angle(dir, false)
		if f.shadow != null:
			f.shadow.pos = Vector3(at.x, 0.02, at.y)
		var smk = f.rec.get("smk")
		if smk is Array:
			for s in smk:
				f.smoke_due += float(s[1]) * delta * TICKS
				var dev: Array = s[2] if s.size() > 2 and s[2] is Array else [0.0, 0.0]
				while f.smoke_due >= 1.0:
					f.smoke_due -= 1.0
					var back := -dir.normalized() * 0.3 if dir.length() > 0.01 else Vector3.ZERO
					_smoke(str(s[0]), p3 + back + Vector3(randf_range(-1, 1) * float(dev[0]), 0.0, randf_range(-1, 1) * float(dev[1])),
						Vector3(randf_range(-0.1, 0.1), 0.15, randf_range(-0.1, 0.1)))
		f.smoke_due = minf(f.smoke_due, 4.0)


func _shadow_card(at: Vector2) -> SpriteFx.Card:
	if not sprites.has_pool("weapon-shadow"):
		var size := 32
		var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
		for y in size:
			for x in size:
				var d := Vector2(x + 0.5 - size * 0.5, y + 0.5 - size * 0.5).length() / (size * 0.5)
				image.set_pixel(x, y, Color(0, 0, 0, clampf(1.0 - d, 0.0, 1.0) * 0.6))
		sprites.add_pool("weapon-shadow", ImageTexture.create_from_image(image), Vector2.ONE, 1, 1.0, false, false, true, 64, false, 0.0, 0.0)
	return sprites.emit("weapon-shadow", Vector3(at.x, 0.02, at.y), 0.5, 3600.0)


# --- Streams ----------------------------------------------------------------------------------------

## Where a stream comes from and goes to: the character's muzzle and aim while it fires a
## flamethrower nearby; else the turret, worm or spitter next to where the game made it, at the
## nearest enemy (acid at the character).
func _place_stream(st: Stream) -> void:
	if not flame_origin_old and st.name.contains("flamethrower"):
		_place_flame(st)
		return
	var p3 := Vector3(st.pos.x, MUZZLE_HEIGHT, st.pos.y)
	if hand_stream and avatar != null and Vector2(avatar.position.x, avatar.position.z).distance_to(st.pos) < 8.0:
		st.from = avatar.muzzle_position()
		if aim != null:
			var a: Vector2 = aim
			st.to = Vector3(a.x, 0.15, a.y)
		elif avatar.aim_target != null:
			var t: Vector3 = avatar.aim_target
			st.to = Vector3(t.x, 0.15, t.z)
		else:
			st.to = st.from + (p3 - st.from) * 2.0
		return
	if st.shooter == null and not st.searched:
		var found: Array = _stream_shooter(st.pos)
		st.shooter = found[0]
		st.shooter_unit = int(found[1])
		st.searched = st.shooter == null
	var src: Vector3 = st.shooter if st.shooter != null else p3
	st.from = src
	var target = null
	if st.name.begins_with("acid"):
		if acid_aim_real:
			target = _acid_target(st.shooter_unit)
		if target == null and avatar != null and avatar.position.distance_to(src) < 30.0:
			target = avatar.position
	elif movers != null:
		target = movers.nearest_enemy(src, 30.0)
	if target != null:
		var t: Vector3 = target
		st.to = Vector3(t.x, 0.15, t.z)
	else:
		st.to = Vector3(st.pos.x * 2.0 - src.x, 0.15, st.pos.y * 2.0 - src.z)


## A flamethrower stream: from the nozzle of the gun that fires it, to where it is. Factorio makes
## the stream entity where the stream lands, not at the gun (2.1.24, a scratch server: a turret's
## streams, a new one every 4 ticks, each at its aim point then, walking from about 8 tiles out
## to the biter it burns; the character's one stream on its line of fire, short of the aim), so
## looking for the shooter right by the entity found the burning biter (an enemy within 3 tiles)
## or nothing (the stream then started where it lands, 1.1 tiles up).
func _place_flame(st: Stream) -> void:
	_place_flame_ends(st)
	if not flame_streams_old:
		_flame_landing(st)


func _place_flame_ends(st: Stream) -> void:
	st.to = Vector3(st.pos.x, 0.15, st.pos.y)
	if st.name.begins_with("handheld"):
		var near_me := avatar != null and Vector2(avatar.position.x, avatar.position.z).distance_to(st.pos) <= HAND_FLAME_REACH
		if near_me and hand_stream:
			st.owner_key = "me"
			# The character's one stream stays where it was made while the aim moves on (2.1.24: made
			# at -5.8 for an aim at -10): it lands at the aim, as before.
			st.from = avatar.muzzle_position()
			if aim != null:
				var a: Vector2 = aim
				st.to = Vector3(a.x, 0.15, a.y)
			elif avatar.aim_target != null:
				var t: Vector3 = avatar.aim_target
				st.to = Vector3(t.x, 0.15, t.z)
			return
		# Another character's: the friendly mover nearest where it lands, a step towards it.
		var other = movers.friendly_nearest(st.to, HAND_FLAME_REACH) if movers != null else null
		if other != null:
			var o: Vector3 = other
			st.from = _tip(o + Vector3(0, MUZZLE_HEIGHT, 0), st.to, 0.5)
			if st.owner_key == "":
				st.owner_key = "hand %d %d" % [roundi(o.x / 3.0), roundi(o.z / 3.0)]
		elif near_me:
			st.from = avatar.muzzle_position()
			st.owner_key = "me"
		else:
			st.from = st.to + Vector3(0, MUZZLE_HEIGHT, 0)
		return
	var layer := _turret_layer()
	var found: Array = layer.call("flame_nozzle", st.pos, FLAME_REACH) if layer != null else []
	if not found.is_empty():
		st.from = found[0]
		st.shooter_unit = int(found[1])
		st.turret_lit = true
		st.owner_key = "u%d" % st.shooter_unit
		if st.alive:
			layer.call("flame_fired", st.shooter_unit)
		return
	# A turret or tank without a moving head part (no nozzle known): its middle, out to the head's front.
	if st.shooter == null and not st.searched:
		var near: Array = _stream_shooter(st.pos, FLAME_REACH, FLAME_SHOOTERS)
		st.shooter = near[0]
		st.shooter_unit = int(near[1])
		st.searched = st.shooter == null
	if st.shooter != null:
		var sh: Vector3 = st.shooter
		st.from = _tip(sh, st.to, 1.0)
		if st.shooter_unit > 0:
			st.owner_key = "u%d" % st.shooter_unit
	else:
		st.from = st.to + Vector3(0, MUZZLE_HEIGHT, 0)


## Where a flame stream lands (not `--flame-streams=old`). Factorio makes a turret's stream entities
## a step short of its target (see _place_flame_ends), so the entity's place is only a hint:
## (a) the target the bridge sends in `ts` (a turret's shooting_target, a vehicle gunner's aim,
## turrets.gd flame_target); (b) else the enemy by the entity, past it on the line from the nozzle;
## (c) else the entity's place pushed out along that line to the gun's range. The character's own
## stream keeps landing at the aim. Never farther than the gun's range (its clamp_position).
func _flame_landing(st: Stream) -> void:
	if st.from == Vector3.ZERO:
		return
	var reach := FLAME_RANGE_HAND if st.name.begins_with("handheld") else FLAME_RANGE_TANK if st.name.begins_with("tank") else FLAME_RANGE_TURRET
	var from := Vector2(st.from.x, st.from.z)
	var to := Vector2(st.to.x, st.to.z)
	if st.owner_key != "me":
		var landing = null
		var layer := _turret_layer()
		if st.shooter_unit > 0 and layer != null and layer.has_method("flame_target"):
			landing = layer.call("flame_target", st.shooter_unit)
		if landing == null and movers != null:
			var foe = movers.nearest_enemy(st.to, 6.0)
			if foe != null:
				var f: Vector3 = foe
				if Vector2(f.x, f.z).distance_to(from) >= to.distance_to(from) - 0.5:
					landing = f
		if landing != null:
			var l: Vector3 = landing
			to = Vector2(l.x, l.z)
		elif to.distance_to(from) > 0.5:
			to = from + (to - from).normalized() * reach
	if to.distance_to(from) > reach:
		to = from + (to - from).normalized() * reach
	st.to = Vector3(to.x, 0.15, to.y)


## A new stream takes over feeding from its shooter's older ones (not `--flame-streams=old`): a
## turret makes a new stream entity every 4 ticks, each drawn from the same nozzle to the same
## target, so only the newest spawns particles; those already flying land as they were going.
func _take_lead(id: int, st: Stream) -> void:
	if flame_streams_old or st.owner_key == "" or not st.name.contains("flamethrower"):
		return
	var prev: Stream = _streams.get(int(_flame_lead.get(st.owner_key, -1)))
	if prev != null and prev != st:
		prev.lead = false
	_flame_lead[st.owner_key] = id


## The top of a stream particle's arc over the line from its start to its landing, `ticks` long:
## Factorio's flight under the stream's vertical acceleration (va * T² / 8), lifted for a flame
## (FLAME_ARC_LIFT, FLAME_ARC_MIN; `--flame-streams=old` the flight as it is).
func _arc_top(st: Stream, ticks: float) -> float:
	var top := float(st.rec.get("va", 0.003)) * ticks * ticks / 8.0
	if flame_streams_old or not st.name.contains("flamethrower"):
		return top
	var dist := Vector2(st.to.x - st.from.x, st.to.z - st.from.z).length()
	return maxf(top * FLAME_ARC_LIFT, dist * FLAME_ARC_MIN)


## `from` moved `step` tiles towards `to` along the ground.
static func _tip(from: Vector3, to: Vector3, step: float) -> Vector3:
	var flat := Vector3(to.x - from.x, 0.0, to.z - from.z)
	return from + flat.normalized() * minf(step, flat.length()) if flat.length() > 0.01 else from


## turrets.gd, through world.gd's animator (main.gd hands it there); null in the previews.
func _turret_layer() -> Node:
	if world == null:
		return null
	var anim = world.get("animator")
	if anim == null:
		return null
	var layer = anim.get("turrets")
	return layer as Node if layer is Node and (layer as Node).has_method("flame_nozzle") else null


## Where a spitter's or worm's acid lands: the point its `en` says it attacks, or the mover (a car, a
## tank) or the character standing there now, drawn where it is; null when no target is known.
func _acid_target(unit: int) -> Variant:
	if unit <= 0 or movers == null:
		return null
	var t = movers.creatures.attack_target(unit)
	if t == null:
		return null
	var at: Vector3 = t
	var best: Vector3 = at
	var best_d := ACID_SNAP
	if avatar != null:
		var d := Vector2(avatar.position.x - at.x, avatar.position.z - at.z).length()
		if d <= best_d:
			best_d = d
			best = avatar.position
	var mover = movers.friendly_nearest(at, best_d)
	if mover != null:
		best = mover
	return best


## The turret or mover a stream made at `at` comes from: [its position or null, its unit number or 0].
## Within `reach` tiles, of the `types` given (a flamethrower's: no enemies, larger reach).
func _stream_shooter(at: Vector2, reach := 4.0, types: Array = STREAM_SHOOTERS) -> Array:
	if movers != null and types == STREAM_SHOOTERS:
		var spitter: Array = movers.nearest_enemy_unit(Vector3(at.x, 0.0, at.y), 3.0)
		if not spitter.is_empty():
			var sp: Vector3 = spitter[1]
			return [sp + Vector3(0, 0.6, 0), int(spitter[0])]
	if world == null:
		return [null, 0]
	var best = null
	var best_unit := 0
	var best_d := reach
	# Only the chunks the 4-tile search reaches: this went through every entity in the world,
	# for each stream four times a second, and a spitter's acid (no building shoots it) never
	# stopped looking: 15-50 ms a frame in a 300-enemy attack on a 16,000-entity map.
	var world_script: GDScript = load(WORLD_SCRIPT)
	var lo: Vector2i = world_script.chunk_of(at - Vector2(best_d, best_d))
	var hi: Vector2i = world_script.chunk_of(at + Vector2(best_d, best_d))
	for cy in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			var cv = world.chunks.get(Vector2i(cx, cy))
			if cv == null:
				continue
			for r in cv.entities.values():
				var d: float = r.pos.distance_to(at)
				if d < best_d:
					var proto = world.protos.entity(r.proto_id)
					if proto != null and proto.type in types:
						best_d = d
						var h := 1.4
						if proto.name.contains("worm"):
							if proto.name.contains("small"):
								h = 1.3
							elif proto.name.contains("medium"):
								h = 1.8
							elif proto.name.contains("big"):
								h = 2.3
							elif proto.name.contains("behemoth"):
								h = 2.8
							else:
								h = 1.8
						best = Vector3(r.pos.x, h, r.pos.y)
						best_unit = r.unit
	return [best, best_unit]


func _update_streams(delta: float) -> void:
	for id in _streams.keys():
		var st: Stream = _streams[id]
		st.age += delta
		if st.custom:
			if not st.alive:
				if on_stream_hook.is_valid():
					on_stream_hook.call({"event": "end", "id": id, "name": st.name})
				_streams.erase(id)
				if st.owner_key != "" and int(_flame_lead.get(st.owner_key, -1)) == int(id):
					_flame_lead.erase(st.owner_key)
			continue
		st.placed -= delta
		if st.placed <= 0.0:
			st.placed = 0.25
			_place_stream(st)
		var hs := maxf(float(st.rec.get("hs", 0.25)), 0.01)
		var va := float(st.rec.get("va", 0.003))
		# Flamethrowers keep feeding their stream while they fire; acid is one burst.
		var continuous := st.name.contains("flamethrower")
		var spawning := st.alive and st.lead and (continuous or st.age * TICKS <= float(st.rec.get("pst", 2)))
		var layer := _pick_layer(st.rec.get("p", []), 0)
		var pool := _pool(layer, true, false, 512, 0.0, 0.0) if not layer.is_empty() else ""
		if spawning and pool != "":
			st.spawn_due += delta * TICKS / maxf(float(st.rec.get("psi", 2)), 1.0)
			while st.spawn_due >= 1.0 and st.particles.size() < STREAM_PARTICLES:
				st.spawn_due -= 1.0
				var ticks := Vector2(st.to.x - st.from.x, st.to.z - st.from.z).length() / hs
				var c := sprites.emit(pool, st.from, _width(layer), 60.0, _tint(layer))
				if c != null:
					c.fps = maxf(float(layer[5]), 0.05) * TICKS
					# A parabola under the stream's vertical acceleration: va * T² / 8 at the top.
					st.particles.append([c, 0.0, maxf(ticks / TICKS, 0.05), st.from, st.to, _arc_top(st, ticks) if continuous else va * ticks * ticks / 8.0])
			st.spawn_due = minf(st.spawn_due, 2.0)
		var ss := float(st.rec.get("ss", 1.0))
		var sa := float(st.rec.get("sa", 1.0))
		var w := _width(layer) if not layer.is_empty() else 1.0
		var alpha := _tint(layer).a if not layer.is_empty() else 1.0
		for i in range(st.particles.size() - 1, -1, -1):
			var part: Array = st.particles[i]
			var c: SpriteFx.Card = part[0]
			part[1] = float(part[1]) + delta
			var t := float(part[1]) / float(part[2])
			if t >= 1.0:
				sprites.kill(c)
				st.particles.remove_at(i)
				continue
			var a: Vector3 = part[3]
			var b: Vector3 = part[4]
			c.pos = a.lerp(b, t) + Vector3(0, float(part[5]) * 4.0 * t * (1.0 - t), 0)
			# Particles grow from particle_start_scale and brighten from particle_start_alpha.
			c.size0 = w * lerpf(ss, 1.0, t)
			c.size1 = c.size0
			c.color.a = alpha * lerpf(sa, 1.0, t)
		if not st.alive and st.particles.is_empty():
			_streams.erase(id)
			if st.owner_key != "" and int(_flame_lead.get(st.owner_key, -1)) == int(id):
				_flame_lead.erase(st.owner_key)


# --- Beams ------------------------------------------------------------------------------------------

## What a beam starting at `s` (the game's source entity's position) comes from: a turret drawn there
## (its emitter, turned with the head: turrets.gd muzzle_of) or a combat robot (a distractor's,
## destroyer's); not looked for with `--laser-origin=old` or when it comes from the character.
func _find_beam_source(beam: Beam, s: Vector2) -> void:
	beam.src = 0
	if laser_origin_old:
		return
	if avatar != null and Vector2(avatar.position.x, avatar.position.z).distance_to(s) < NEAR_SHOOTER:
		return
	if turrets != null and is_instance_valid(turrets):
		var unit := int(turrets.call("turret_near", s, 1.0))
		if unit > 0:
			beam.src = unit
			beam.src_turret = true
			return
	if movers != null:
		var hit: Array = movers.pick(s, 1.0, ["combat-robot"])
		if not hit.is_empty():
			beam.src = int(hit[0])
			beam.src_turret = false


## Where a beam starts now: its turret's emitter or its robot as drawn, else as before (_beam_end).
func _beam_source(beam: Beam, s: Vector2) -> Vector3:
	if beam.src > 0:
		var p = null
		if beam.src_turret:
			if turrets != null and is_instance_valid(turrets):
				p = turrets.call("muzzle_of", beam.src)
		elif movers != null:
			p = movers.position_of(beam.src)
		if p is Vector3:
			return p
	return _beam_end(s, true)


func _beam_end(at: Vector2, source: bool) -> Vector3:
	if source and avatar != null and Vector2(avatar.position.x, avatar.position.z).distance_to(at) < NEAR_SHOOTER:
		return avatar.muzzle_position()
	return Vector3(at.x, 1.2 if source else HIT_HEIGHT, at.y)


## A beam as Factorio lays it: its start at the source, body segments end to end (the head first
## and the tail last), and its ending at the target, flickering through their frames.
func _update_beams() -> void:
	for beam: Beam in _beams.values():
		if beam.src > 0:
			var p = null
			if beam.src_turret:
				if turrets != null and is_instance_valid(turrets):
					p = turrets.call("muzzle_of", beam.src)
			elif movers != null:
				p = movers.position_of(beam.src)
			if p is Vector3:
				beam.from = p  # follows the head as it turns, the robot as it flies
		var body: Array = beam.rec.get("body", [])
		if body.is_empty():
			continue
		var seg_layer := _pick_layer([body[0]])
		if seg_layer.is_empty():
			continue
		var seg := maxf(_width(seg_layer), 0.25)
		var span := beam.to - beam.from
		var length := _projected(span).length()
		var n := clampi(ceili(length / seg), 1, 40)
		var plan: Array = []  # [layer, position, width]
		if beam.rec.has("start"):
			plan.append([_pick_layer(beam.rec["start"]), beam.from, -1.0])
		for i in n:
			var parts: Array = body
			if i == 0 and beam.rec.has("head"):
				parts = beam.rec["head"]
			elif i == n - 1 and n > 1 and beam.rec.has("tail"):
				parts = beam.rec["tail"]
			plan.append([_pick_layer(parts, i), beam.from + span * ((i + 0.5) / n), length / n])
		if beam.rec.has("ending"):
			plan.append([_pick_layer(beam.rec["ending"]), beam.to, -1.0])
		while beam.cards.size() > plan.size():
			sprites.kill(beam.cards.pop_back()[0])
		var angle := _screen_angle(span, true)
		for i in plan.size():
			var item: Array = plan[i]
			var layer: Array = item[0]
			if layer.is_empty():
				continue
			var pool := _pool(layer, true, false, 256, 0.0, 0.0)
			if pool == "":
				continue
			var width := float(item[2]) if float(item[2]) > 0.0 else _width(layer)
			if i >= beam.cards.size() or beam.cards[i][1] != pool:
				var c := sprites.emit(pool, item[1], width, 3600.0, _tint(layer))
				if c == null:
					continue
				c.fps = maxf(float(layer[5]), 0.1) * TICKS
				if i < beam.cards.size():
					sprites.kill(beam.cards[i][0])
					beam.cards[i] = [c, pool]
				else:
					beam.cards.append([c, pool])
			var card: SpriteFx.Card = beam.cards[i][0]
			card.pos = item[1]
			card.size0 = width
			card.size1 = width
			card.spin = angle


# --- On the ground ----------------------------------------------------------------------------------

func _on_ground(msg: Dictionary) -> void:
	_mark += 1
	var mark := _mark
	var l := _items(msg.get("l"))
	var i := 0
	while i + 4 < l.size():
		var id := int(l[i])
		var g: Ground = _ground.get(id)
		if g == null:
			g = _new_ground(str(l[i + 1]), Vector3(int(l[i + 2]) / 256.0, 0.0, int(l[i + 3]) / 256.0), id)
			if g != null:
				_ground[id] = g
		if g != null:
			g.seen = mark
			g.gone = -1.0
			if int(l[i + 4]) >= 0:
				g.ttl = int(l[i + 4]) / TICKS
		i += 5
	for id in _ground.keys():
		var g: Ground = _ground[id]
		if g.seen != mark and g.gone < 0.0:
			g.gone = 0.0
			if g.custom and on_ground_hook.is_valid():
				on_ground_hook.call({"event": "end", "id": id, "name": g.name, "pos": g.pos, "fade_out": g.fade_out})


func _new_ground(name: String, at: Vector3, id := 0) -> Ground:
	var g := Ground.new()
	g.name = name
	g.pos = at
	g.born = _clock
	if data.get("fi", {}).has(name):
		var is_acid := _is_acid_ground(name)
		g.rec = data["fi"][name]
		g.fade_in = float(g.rec.get("fin", 30)) / TICKS
		g.fade_out = float(g.rec.get("fout", 30)) / TICKS
		if on_ground_hook.is_valid():
			var ginfo := {
				"event": "start",
				"id": id,
				"name": name,
				"pos": at,
				"fade_in": g.fade_in,
				"fade_out": g.fade_out,
				"handled": false,
			}
			on_ground_hook.call(ginfo)
			if bool(ginfo.get("handled", false)):
				g.custom = true
				g.fire = false
				return g
		g.fire = not is_acid
		var layers := _first_variation(g.rec.get("a", []), true)
		for layer: Array in layers:
			var pool := _pool(layer, true, is_acid, GROUND_CARDS, 0.0, 0.0)
			if pool == "":
				continue
			var h := _height(layer)
			var emit_pos := at + Vector3(0.0, 0.03, 0.0) if is_acid else at + Vector3(randf_range(-0.15, 0.15), maxf(-float(layer[7][1]), h * 0.42), randf_range(-0.15, 0.15))
			var c := sprites.emit(pool, emit_pos, _width(layer), 3600.0, _tint(layer))
			if c != null:
				c.fps = maxf(float(layer[5]), 0.05) * TICKS
				g.cards.append([c, clampf(float(g.rec.get("alpha", 1.0)) * 2.0, 0.5, 1.0)])
		var patch: Array = [] if in_space else _pick_layer(g.rec.get("bp", []))
		if not patch.is_empty():
			var pool := _pool(patch, false, true, 200, 0.05, 0.3)
			if pool != "":
				var c := sprites.emit(pool, at + Vector3(0, 0.025, 0), _width(patch), BURNT_SECONDS, Color(1, 1, 1, 0.85))
				if c != null:
					c.angle = randf() * TAU
		return g
	if data.get("sw", {}).has(name):
		g.rec = data["sw"][name]
		g.fade_in = 0.4
		g.fade_out = maxf(float(g.rec.get("fade", 60)) / TICKS, 0.3)
		var layer := _pick_layer(g.rec.get("a", []))
		if layer.is_empty():
			return g
		var pool := _pool(layer, true, false, GROUND_CARDS, 0.0, 0.0)
		if pool == "":
			return g
		var col = g.rec.get("c")
		var tint := Color(float(col[0]), float(col[1]), float(col[2]), float(col[3])) if col is Array and col.size() >= 4 else Color(1, 1, 1, 0.6)
		var spread: Array = g.rec.get("spr", [0, 0])
		var n := clampi(int(g.rec.get("n", 1)), 1, 16)
		var w := _width(layer)
		for k in n:
			var a := randf() * TAU
			var r := sqrt(randf())
			var off := Vector3(cos(a) * r * float(spread[0]) * 0.5, 0.0, sin(a) * r * float(spread[1]) * 0.5)
			var size := w * randf_range(0.7, 1.1)
			var c := sprites.emit(pool, at + off + Vector3(0, size * _aspect(layer) * 0.35, 0), size, 3600.0, tint)
			if c != null:
				c.fps = maxf(float(layer[5]), 0.05) * TICKS
				c.spin_rate = randf_range(-0.15, 0.15)
				g.cards.append([c, tint.a])
		return g
	return null


func _update_ground(delta: float) -> void:
	var smoke_rate := 1.5
	for id in _ground.keys():
		var g: Ground = _ground[id]
		var a := clampf((_clock - g.born) / maxf(g.fade_in, 0.01), 0.0, 1.0)
		if g.ttl >= 0.0:
			g.ttl -= delta
			a *= clampf(g.ttl / g.fade_out, 0.0, 1.0)
		if g.gone >= 0.0:
			g.gone += delta
			a *= clampf(1.0 - g.gone / g.fade_out, 0.0, 1.0)
			if g.gone >= g.fade_out:
				_drop_cards(g.cards)
				_ground.erase(id)
				continue
		for entry: Array in g.cards:
			var c: SpriteFx.Card = entry[0]
			c.color.a = float(entry[1]) * a
			c.age = minf(c.age, 3000.0)
		if g.fire and a > 0.3 and randf() < delta * smoke_rate:
			_smoke("soft-fire-smoke", g.pos + Vector3(randf_range(-0.2, 0.2), 1.0, randf_range(-0.2, 0.2)), Vector3(0.1, 0.5, 0.05))


# --- Lights -----------------------------------------------------------------------------------------

## The nearest few of everything that lights its surroundings: explosions as they burn out,
## rockets and grenades in flight, fires.
func _update_lights(delta: float) -> void:
	if not CombatLights.old:
		_update_combat_lights(delta)
		return
	var wants: Array = []  # [position, colour, energy, range, whether the hills are still to be added]
	for i in range(_flashes.size() - 1, -1, -1):
		var fl: Array = _flashes[i]
		fl[4] = float(fl[4]) + delta
		if float(fl[4]) >= float(fl[5]):
			_flashes.remove_at(i)
			continue
		var t := float(fl[4]) / float(fl[5])
		wants.append([fl[0], fl[1], float(fl[2]) * (1.0 - t), maxf(float(fl[3]), FLASH_MIN_RANGE), false])
	for f: Flyer in _flying.values():
		var l = f.rec.get("l")
		if l is Array and l.size() >= 3 and not f.cards.is_empty():
			var col: Array = l[2]
			wants.append([(f.cards[0][0] as SpriteFx.Card).pos, Color(float(col[0]), float(col[1]), float(col[2])), float(l[0]) * 1.5, clampf(float(l[1]) * 0.5, 1.5, 8.0), true])
	for g: Ground in _ground.values():
		if g.fire and not g.cards.is_empty():
			var c: SpriteFx.Card = g.cards[0][0]
			if g.hills_v != GroundHeight.version():
				g.hills_v = GroundHeight.version()
				g.hills = GroundHeight.at(g.pos.x, g.pos.z)
			wants.append([g.pos + Vector3(0, 0.8 + g.hills, 0), Color(1.0, 0.55, 0.2), 2.0 * c.color.a, 7.0, false])
	var centre := avatar.position if avatar != null else Vector3.ZERO
	if wants.size() > MAX_LIGHTS:
		wants.sort_custom(func(a, b): return (a[0] as Vector3).distance_squared_to(centre) < (b[0] as Vector3).distance_squared_to(centre))
	for i in MAX_LIGHTS:
		var light: OmniLight3D = _lights[i]
		light.shadow_enabled = false
		if i < wants.size():
			var w: Array = wants[i]
			light.position = GroundHeight.lift(w[0]) if w[4] else w[0]
			light.light_color = w[1]
			light.light_energy = w[2]
			light.omni_range = w[3]
			light.visible = true
		else:
			light.visible = false
	CombatLights.clear_shadow_source(get_instance_id())


## A fire's unsteady brightness, about 0.7 to 1.1, out of step by `phase`.
func _flicker(phase: float) -> float:
	var t := _clock + phase
	return 0.9 + 0.12 * sin(t * 23.0) + 0.08 * sin(t * 41.0)


## Combat lights: muzzle flashes, explosions, rockets and grenades in flight, flamethrower streams and
## fires, all scaled by the strength setting; the pool's lights go to those that light the most of
## the screen (brightness and reach against the distance to the camera).
func _update_combat_lights(delta: float) -> void:
	var gain := CombatLights.strength
	var wants: Array = []  # [position (lifted), colour, energy, range, unused, score]
	for i in range(_flashes.size() - 1, -1, -1):
		var fl: Array = _flashes[i]
		fl[4] = float(fl[4]) + delta
		if float(fl[4]) >= float(fl[5]):
			_flashes.remove_at(i)
			continue
		var k := 1.0 - float(fl[4]) / float(fl[5])
		if bool(fl[6]):
			k *= k  # an explosion: a bright flash, then a long dim tail
		wants.append([fl[0], fl[1], float(fl[2]) * k * gain, maxf(float(fl[3]), FLASH_MIN_RANGE), false, 0.0])
	for f: Flyer in _flying.values():
		var l = f.rec.get("l")
		if l is Array and l.size() >= 3 and not f.cards.is_empty():
			var col: Array = l[2]
			wants.append([GroundHeight.lift((f.cards[0][0] as SpriteFx.Card).pos), Color(float(col[0]), float(col[1]), float(col[2])),
				float(l[0]) * 2.5 * gain, clampf(float(l[1]) * 0.8, 3.0, 10.0), false, 0.0])
	var flames := wants.size()
	for st: Stream in _streams.values():
		if not st.alive or not st.lead or st.custom or not st.name.contains("flamethrower") or st.from == Vector3.ZERO:
			continue
		var phase := float(st.shooter_unit % 97) * 0.37 + st.pos.x * 0.3
		var land := GroundHeight.lift(st.to + Vector3(0, 1.5, 0))
		# Over the middle of the drawn arc (its top), a little under it.
		var arc := 0.0 if flame_streams_old else _arc_top(st, Vector2(st.to.x - st.from.x, st.to.z - st.from.z).length() / maxf(float(st.rec.get("hs", 0.25)), 0.01))
		var mid := GroundHeight.lift(st.from.lerp(st.to, 0.5) + Vector3(0, 0.8 + maxf(arc - 0.6, 0.0), 0))
		var near := false
		for j in range(flames, wants.size()):
			if (wants[j][0] as Vector3).distance_squared_to(mid) < 9.0:
				near = true
				break
		if near:
			continue
		wants.append([mid, FIRE_COLOUR, float(STREAM_MID_LIGHT[0]) * gain * _flicker(phase), float(STREAM_MID_LIGHT[1]), false, 0.0])
		if not st.turret_lit:
			wants.append([land, FIRE_COLOUR, float(STREAM_LAND_LIGHT[0]) * gain * _flicker(phase + 1.7), float(STREAM_LAND_LIGHT[1]), false, 0.0])
	_fire_cells.clear()
	for g: Ground in _ground.values():
		if not g.fire or g.cards.is_empty():
			continue
		var c: SpriteFx.Card = g.cards[0][0]
		var a := c.color.a
		if a <= 0.02:
			continue
		var cell := Vector2i(floori(g.pos.x / FIRE_MERGE), floori(g.pos.z / FIRE_MERGE))
		if _fire_cells.has(cell):
			var w: Array = wants[int(_fire_cells[cell])]
			w[2] = minf(float(w[2]) + float(FIRE_LIGHT[0]) * 0.35 * a * gain, float(FIRE_LIGHT_MAX[0]) * gain)
			w[3] = minf(float(w[3]) + 0.5, float(FIRE_LIGHT_MAX[1]))
			continue
		if g.hills_v != GroundHeight.version():
			g.hills_v = GroundHeight.version()
			g.hills = GroundHeight.at(g.pos.x, g.pos.z)
		_fire_cells[cell] = wants.size()
		wants.append([g.pos + Vector3(0, 1.2 + g.hills, 0), FIRE_COLOUR, float(FIRE_LIGHT[0]) * a * gain * _flicker(g.pos.x * 1.3 + g.pos.z * 0.7),
			float(FIRE_LIGHT[1]), false, 0.0])
	var count := _lights.size()
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var eye := cam.global_position if cam != null else (avatar.position if avatar != null else Vector3.ZERO)
	if wants.size() > count:
		for w: Array in wants:
			w[5] = CombatLights.light_score(w[0], eye, float(w[2]), float(w[3]))
		wants.sort_custom(_by_score)
	var shadow_candidates: Array = []
	for i in count:
		var light: OmniLight3D = _lights[i]
		if i < wants.size() and float(wants[i][2]) > 0.01:
			var w: Array = wants[i]
			light.position = w[0]
			light.light_color = w[1]
			light.light_energy = w[2]
			light.omni_range = w[3]
			light.visible = true
			var score := float(w[5]) if wants.size() > count else CombatLights.light_score(w[0], eye, float(w[2]), float(w[3]))
			shadow_candidates.append([light, score])
		else:
			light.visible = false
			light.shadow_enabled = false
	CombatLights.submit_shadow_candidates(get_instance_id(), shadow_candidates)


## The last frame's _process time, microseconds (--stutter-probe).
var process_usec := 0


func _process(delta: float) -> void:
	_clock += delta
	if sprites == null:
		return
	var t0 := Time.get_ticks_usec()
	if not _pending.is_empty():
		_finish_pools()
	var now := Time.get_ticks_msec()
	while not _recent.is_empty() and now - int(_recent[0][2]) > DEDUP_SECONDS * 1000.0:
		_recent.pop_front()
	_update_flyers(delta)
	_update_streams(delta)
	_update_beams()
	_update_tracers(delta)
	_update_ground(delta)
	_update_casings()
	_update_lights(delta)
	process_usec = Time.get_ticks_usec() - t0


# --- Sheets -----------------------------------------------------------------------------------------

## The sprite_fx pool for one layer of a Factorio animation, or "" when its sheet isn't there or
## isn't ready yet. Its atlas is made from the sheets in the install on a worker thread the first
## time it is asked for (up to 60 ms each on the main thread: a fight's first shots, explosions and
## fires, each fire variation its own, made frames of 25-60 ms), so that first effect isn't drawn.
func _pool(layer: Array, cyclic: bool, flat: bool, capacity: int, fade_in := 0.0, fade_out := 0.15) -> String:
	var key := "%s@%s:%dx%d:%d%s%s" % [str(layer[0]), str(layer[10]), int(layer[1]), int(layer[2]), int(layer[3]),
		"c" if cyclic else "", "f" if flat else ""]
	if _pools.has(key):
		return _pools[key]
	if _pending.has(key):
		return ""
	var dir := SoundBank.data_dir()
	if dir == "":
		_pools[key] = ""
		return ""
	var result: Array = []
	var task := WorkerThreadPool.add_task(_atlas.bind(dir, layer, result), false, "weapon fx atlas")
	_pending[key] = [task, result, layer, cyclic, flat, capacity, fade_in, fade_out]
	return ""


## Starts making the atlases of these prototypes (explosions, fires, clouds, smokes, scorch marks,
## projectiles: every variation) on worker threads, with the settings their effects use, so a
## fight's first shots are drawn. pools_pending() counts those still being made.
func prewarm(names: Array) -> void:
	for name in names:
		for layers in data.get("ex", {}).get(name, {}).get("v", []):
			for layer: Array in layers:
				_pool(layer, false, false, 48)
		var fire = data.get("fi", {}).get(name)
		if fire is Dictionary:
			for layers in fire.get("a", []):
				for layer: Array in layers:
					_pool(layer, true, false, GROUND_CARDS, 0.0, 0.0)
			for v in fire.get("bp", []):
				if v is Array and not v.is_empty() and v[0] is Array:
					_pool(v[0], false, true, 200, 0.05, 0.3)
		for table in ["sw", "sc"]:
			for v in data.get(table, {}).get(name, {}).get("a", []):
				if v is Array and not v.is_empty() and v[0] is Array:
					_pool(v[0], table == "sw", table == "sc", GROUND_CARDS if table == "sw" else 120, 0.0, 0.0 if table == "sw" else 0.1)
		var smoke: Dictionary = data.get("ts", {}).get(name, {})
		for v in smoke.get("a", []):
			if v is Array and not v.is_empty() and v[0] is Array:
				var dur := maxf(float(smoke.get("dur", 60)), 1.0)
				_pool(v[0], true, false, 400, 0.0, clampf(float(smoke.get("fade", 0)) / dur, 0.1, 0.9))
		for layers in data.get("pr", {}).get(name, {}).get("a", []).slice(0, 1):
			for layer: Array in layers:
				_pool(layer, true, false, 256, 0.0, 0.0)
		var stream_layer := _pick_layer(data.get("st", {}).get(name, {}).get("p", []), 0)
		if not stream_layer.is_empty():
			_pool(stream_layer, true, false, 512, 0.0, 0.0)
		var beam: Dictionary = data.get("bm", {}).get(name, {})
		for part in ["start", "head", "body", "tail", "ending"]:
			for v in beam.get(part, []):
				if v is Array and not v.is_empty() and v[0] is Array:
					_pool(v[0], true, false, 256, 0.0, 0.0)


## What a fight on Nauvis draws: turrets' and guns' flashes and hits, laser beams, flame and acid
## streams, enemies' blood and deaths, fires, scorch marks. Prewarmed once, when the first enemies
## or turrets show up (main.gd).
const FIGHT_EFFECTS := ["explosion-gunshot", "explosion-gunshot-small", "explosion-hit", "small-explosion-hit",
	"laser-beam", "laser-bubble", "flamethrower-fire-stream", "handheld-flamethrower-fire-stream", "fire-flame",
	"blood-explosion-small", "blood-explosion-big", "blood-explosion-huge", "small-biter-die", "medium-biter-die",
	"big-biter-die", "behemoth-biter-die", "small-spitter-die", "medium-spitter-die", "big-spitter-die",
	"behemoth-spitter-die", "acid-stream-spitter-small", "acid-stream-spitter-medium", "acid-stream-spitter-big",
	"acid-stream-spitter-behemoth", "acid-splash-fire-spitter-small", "acid-splash-fire-spitter-medium",
	"acid-splash-fire-spitter-big", "acid-splash-fire-spitter-behemoth", "small-scorchmark-tintable",
	"medium-scorchmark-tintable", "smoke-fast", "soft-fire-smoke", "wall-explosion"]
var _fights_warmed := false


func prewarm_fights() -> void:
	if not _fights_warmed and not data.is_empty():
		_fights_warmed = true
		prewarm(FIGHT_EFFECTS)


func pools_pending() -> int:
	return _pending.size()


## Pools whose atlases are made.
func _finish_pools() -> void:
	for key in _pending.keys():
		var p: Array = _pending[key]
		if not WorkerThreadPool.is_task_completed(p[0]):
			continue
		WorkerThreadPool.wait_for_task_completion(p[0])
		_pending.erase(key)
		var made: Array = p[1]
		if made.is_empty():
			_pools[key] = ""
			continue
		var layer: Array = p[2]
		# A sheet without an alpha channel (the tesla beams: light on black) only works added on.
		var additive: bool = int(layer[8]) == 1 or made[3]
		sprites.add_pool(key, made[0], made[1], int(made[2]), float(layer[2]) / maxf(float(layer[1]), 1.0), additive,
			p[3], p[4], p[5], int(layer[11]) == 1, p[6], p[7])
		_pools[key] = key


func _exit_tree() -> void:
	CombatLights.clear_shadow_source(get_instance_id())
	for p: Array in _pending.values():
		WorkerThreadPool.wait_for_task_completion(p[0])
	_pending.clear()


## Fills `out` with [texture, grid, frames, opaque]: the layer's frames cut from its sheet (or
## stripes) into one atlas; opaque when the sheet has no alpha channel. Runs on a worker thread.
static func _atlas(dir: String, layer: Array, out: Array) -> void:
	var w := int(layer[1])
	var h := int(layer[2])
	var n := maxi(int(layer[3]), 1)
	var line := maxi(int(layer[4]), 1)
	var offset: Array = layer[10]
	if w <= 0 or h <= 0:
		return
	var sources: Array = []  # per frame: [Image, Vector2i]
	var opaque := false
	for entry in layer[0]:
		var file := str(entry[0]) if entry is Array else str(entry)
		var across := int(entry[1]) if entry is Array else line
		var down := int(entry[2]) if entry is Array else ceili(float(n) / line)
		var image := _image(dir.path_join(file))
		if image == null:
			return
		_images_lock.lock()
		opaque = opaque or _opaque.get(dir.path_join(file), false)
		_images_lock.unlock()
		var o :=Vector2i(int(offset[0]), int(offset[1])) if not (entry is Array) else Vector2i.ZERO
		for j in across * down:
			if sources.size() >= n:
				break
			sources.append([image, o + Vector2i((j % across) * w, (j / across) * h)])
	n = sources.size()
	if n == 0:
		return
	var cols := clampi(ceili(sqrt(n * float(h) / float(w))), 1, n)
	var rows := ceili(float(n) / cols)
	var atlas := Image.create(cols * w, rows * h, false, Image.FORMAT_RGBA8)
	for i in n:
		var src: Image = sources[i][0]
		var at: Vector2i = sources[i][1]
		var rect := Rect2i(at, Vector2i(w, h)).intersection(Rect2i(Vector2i.ZERO, src.get_size()))
		if rect.size.x > 0 and rect.size.y > 0:
			atlas.blit_rect(src, rect, Vector2i((i % cols) * w, (i / cols) * h) + (rect.position - at))
	var big := maxi(atlas.get_width(), atlas.get_height())
	if big > ATLAS_MAX:
		var k := float(ATLAS_MAX) / big
		atlas.resize(maxi(1, int(atlas.get_width() * k)), maxi(1, int(atlas.get_height() * k)), Image.INTERPOLATE_BILINEAR)
	atlas.generate_mipmaps()
	out.append_array([ImageTexture.create_from_image(atlas), Vector2(cols, rows), n, opaque])


## A sheet from the install (kept for the next atlases from it); any thread.
static func _image(path: String) -> Image:
	_images_lock.lock()
	var cached: bool = _images.has(path)
	var image: Image = _images.get(path)
	_images_lock.unlock()
	if cached:
		return image
	if FileAccess.file_exists(path):
		image = Image.load_from_file(path)
		if image != null:
			var opaque := image.detect_alpha() == Image.ALPHA_NONE
			image.convert(Image.FORMAT_RGBA8)
			_images_lock.lock()
			_opaque[path] = opaque
			_images_lock.unlock()
	_images_lock.lock()
	_images[path] = image
	if _images.size() > 24:
		_images.erase(_images.keys()[0])
	_images_lock.unlock()
	return image


# --- Helpers ----------------------------------------------------------------------------------------

static func _items(v) -> Array:
	return v if v is Array else []


static func _height(layer: Array) -> float:
	return float(layer[2]) * float(layer[6]) / 32.0


static func _width(layer: Array) -> float:
	return float(layer[1]) * float(layer[6]) / 32.0


static func _aspect(layer: Array) -> float:
	return float(layer[2]) / maxf(float(layer[1]), 1.0)


static func _tint(layer: Array) -> Color:
	var t = layer[9]
	if t is Array and t.size() >= 4:
		return Color(float(t[0]), float(t[1]), float(t[2]), float(t[3]))
	return Color.WHITE


## One layer of a random variation (or variation `index`), the first that isn't light-only.
static func _pick_layer(variations, index := -1) -> Array:
	if not (variations is Array) or variations.is_empty():
		return []
	var v = variations[(index if index >= 0 else randi()) % variations.size()]
	if v is Array and not v.is_empty() and v[0] is Array:
		return v[0]
	return []


static func _first_variation(variations, random := false) -> Array:
	if not (variations is Array) or variations.is_empty():
		return []
	var v = variations[randi() % variations.size()] if random else variations[0]
	return v if v is Array else []


func _drop_cards(cards: Array) -> void:
	for entry in cards:
		sprites.kill(entry[0])
	cards.clear()


## `dir` (world) as seen on screen, as a card's spin: so the sprite's up (`along_x` false: rockets,
## pellets) or its width (`along_x`: beams) points along it.
func _screen_angle(dir: Vector3, along_x: bool) -> float:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return 0.0
	var b := cam.global_transform.basis
	var sx := dir.dot(b.x)
	var sy := dir.dot(b.y)
	return atan2(sy, sx) if along_x else atan2(-sx, sy)


## `v` with the part along the camera's view taken out: its length is how long it looks.
func _projected(v: Vector3) -> Vector3:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return v
	var view := cam.global_transform.basis.z.normalized()
	return v - view * v.dot(view)
