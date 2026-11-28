extends Node3D
## Sound and effects for what the bridge reports: working machines (loops, chimney smoke,
## steam), the character (footsteps by ground, dust, mining hits and sparks, gunshots and
## muzzle flashes), building, rotating and mining things out, deaths (explosions and scorch marks;
## corpses are creatures.gd's, remnants the world's), biters calling, cars and trains driving.
## Sounds and sprite sheets are Factorio's own, from the player's install (sound_bank.gd,
## sprite_fx.gd); without one it is silent and the effects are plain blobs.
##
## main.gd hands every message to handle() before routing it, so a deleted entity or a dead
## mover can still be looked up here.

const WorldMirror := preload("res://scripts/world/world.gd")
const MomentHold := preload("res://scripts/world/moment_hold.gd")
const MoverLayer := preload("res://scripts/world/movers.gd")
const WireDecode := preload("res://scripts/net/wire_decode.gd")
const CombatLayer := preload("res://scripts/world/combat.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const Avatar := preload("res://scripts/player/avatar.gd")
const CameraRig := preload("res://scripts/player/camera_rig.gd")
const Sfx := preload("res://scripts/fx/sfx.gd")
const SpriteFx := preload("res://scripts/fx/sprite_fx.gd")
const SoundBank := preload("res://scripts/fx/sound_bank.gd")
const FxSettings := preload("res://scripts/fx/fx_settings.gd")
const FxDemo := preload("res://scripts/fx/fx_demo.gd")
const WeaponFx := preload("res://scripts/fx/weapon_fx.gd")
const WeaponsDemo := preload("res://scripts/fx/weapons_demo.gd")
const Lightning := preload("res://scripts/fx/lightning.gd")
const BurnerFx := preload("res://scripts/fx/burner_fx.gd")
const FlameSound := preload("res://scripts/fx/flame_sound.gd")
const CombatSounds := preload("res://scripts/fx/combat_sounds.gd")
const StepSounds := preload("res://scripts/fx/step_sounds.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const VehicleAnim := preload("res://scripts/world/vehicle_anim.gd")
const VehicleTracks := preload("res://scripts/fx/vehicle_tracks.gd")
const Switches := preload("res://scripts/switches.gd")
const Probing := preload("res://scripts/debug/probing.gd")

const SCAN_INTERVAL := 0.25
## Machines and vehicles further than this from the listener (tiles) are not considered.
const HEARING := 40.0
const SMOKE_RANGE := 45.0
const MAX_EMITTERS := 24
const MINE_INTERVAL := 0.5
## Factorio's utility sounds for a swing at something whose prototype has no mining_sound of its own
## (J11): trees' wood, everything else the ore sound (2.1's changelog calls it the generic one).
const MINE_SOUNDS := {"wood": "core/sound/mining-wood", "ore": "core/sound/axe-mining-ore"}
## M1: what gets those defaults. Factorio's swing sounds are for trees (plants are trees too) and what grows
## out of the map (ore, rocks, fish); no building in base or Space Age has a mining_sound or a
## mining_particle, so mining one by hand is silent, without sparks, until it comes off (its mined_sound,
## else deconstruct-small/medium/large: _on_del).
const MINE_DEFAULTS := {"tree": "wood", "plant": "wood", "resource": "ore", "simple-entity": "ore", "fish": "ore"}
## The sounds of a mined thing coming off (_on_del), decoded with the swings' at the start.
const MINED_SOUNDS := ["core/sound/deconstruct-small.ogg", "core/sound/deconstruct-medium.ogg",
	"core/sound/deconstruct-large.ogg", "core/sound/deconstruct-bricks.ogg"]
## M1: `--building-swing=ore`: a building's swing plays the ore sound with its sparks, as J11 had it.
static var silent_buildings := not (Switches.has("--building-swing=ore"))
## K13: what a repair pack mending something plays, Factorio's default_manual_repair (a drill, 3.3-3.6 s
## a variation, at full volume), for what has no repair_sound of its own (stone walls and furnaces
## hammer: base/sound/manual-repair-simple, at half volume). Each plays to its end, then the next.
const REPAIR_SOUND := "core/sound/manual-repair-advanced"
## Movers a repair pack mends (player_input.gd's MINEABLE_MOVERS): their own repair sound at `rp`.
const REPAIRED_MOVERS := ["car", "spider-vehicle", "locomotive", "cargo-wagon", "fluid-wagon",
	"artillery-wagon", "infinity-cargo-wagon"]
## Space Age tile names (a part of them) -> its step sounds, first match wins.
const SPACE_AGE_STEPS := {
	"frozen-concrete": "frozen-concrete", "ice-smooth": "smooth-ice", "brash-ice": "ice", "ice": "ice",
	"snow": "icy-snow", "pumice": "rough-stone", "ash": "soft-stone", "volcanic": "hard-stone",
	"fulgoran-dunes": "soft-sand", "fulgoran-sand": "soft-sand", "fulgoran-rock": "rocky-stone",
	"fulgoran-walls": "hard-stone", "fulgoran-paving": "smooth-stone", "fulgoran-machinery": "scraps",
	"fulgoran-conduit": "scraps", "wetland": "wetland", "lowland": "slime", "midland": "soft-bark",
	"highland": "rocky-stone", "pit-rock": "semi-dry-rock",
}
## I25: machines whose working sound has accents (sound_accents), with the working animation the
## accents' frames count in: [frame_count, animation_speed] from its prototype (the rocket silo's
## "crafting" visualisation, rocket-silo-crafting-pictures.lua: 64 frames at 0.65 a tick, so its
## weld and turn accents come round every 1.6 s while it builds a rocket).
const ACCENT_ANIMS := {"rocket-silo": [64.0, 0.65]}
## I21: a step by the timer when the run cycle gives none this long (the body not animated).
const STEP_FALLBACK := 0.6
const BUILD_RANGE := 16.0
const REMNANT_SECONDS := 60.0
const WIND := Vector3(0.35, 0.0, 0.12)  # tiles per second; Factorio's smoke drifts too
const ENEMY_TYPES := ["unit", "spider-unit", "segmented-unit"]

## Smoke from working burner machines: sheet kind, chimney offset (tiles, north-facing, x east,
## y south), puffs per second, height as a fraction of the model's top, spread along y.
const EMITTERS := {
	"stone-furnace": ["smoke", Vector2(0.0, -0.25), 2.5, 0.95, 0.0],
	"steel-furnace": ["smoke", Vector2(0.4, -0.6), 2.0, 0.95, 0.0],
	"boiler": ["smoke", Vector2(-1.0, 0.25), 4.0, 1.0, 0.0],
	"burner-mining-drill": ["smoke", Vector2(0.35, -0.35), 2.0, 0.95, 0.0],
	"steam-engine": ["steam", Vector2(0.0, 0.0), 3.0, 0.9, 1.6],
	"steam-turbine": ["steam", Vector2(0.0, -1.6), 4.5, 0.95, 0.0],
	"thruster": ["thrust", Vector2(0.0, 1.1), 5.0, 0.15, 0.0],
}

const GUN_SOUNDS := {
	"pistol": "base/sound/fight/light-gunshot",
	"submachine-gun": "base/sound/fight/submachine-gunshot",
	"shotgun": "base/sound/fight/pump-shotgun",
	"combat-shotgun": "base/sound/fight/pump-shotgun",
	"rocket-launcher": "base/sound/fight/rocket-launcher",
	"flamethrower": "base/sound/fight/flamethrower-mid",
	"railgun": "space-age/sound/entity/railgun/railgun-gunshot",
}

## Loops for moving vehicles: [driving, idle with the character inside, volume].
const VEHICLE_SOUNDS := {
	"car": ["base/sound/car-engine-driving.ogg", "base/sound/car-engine.ogg", 0.6],
	"tank": ["base/sound/fight/tank-engine-driving.ogg", "base/sound/fight/tank-engine.ogg", 0.6],
	"locomotive": ["base/sound/train-engine-driving.ogg", "base/sound/train-engine.ogg", 0.6],
	"cargo-wagon": ["base/sound/train-wagon-wheels.ogg", "", 0.5],
	"fluid-wagon": ["base/sound/train-wagon-wheels.ogg", "", 0.5],
	"artillery-wagon": ["base/sound/train-wagon-wheels.ogg", "", 0.5],
}


class Tracked:
	var proto_id := 0
	var pos := Vector2.ZERO
	var scan_pos := Vector2.ZERO
	var speed := 0.0  # tiles per second
	var seen := 0
	var exhaust_due := 0.0
	var dust_due := 0.0


class Emitter:
	var pos := Vector3.ZERO
	var kind := "smoke"
	var rate := 1.0
	var spread := Vector3.ZERO  # puffs come from anywhere along this, both ways
	var due := 0.0


var world: WorldMirror
## The decoratives layer (main.gd): what the character's steps rustle through.
var decoratives: Node
var movers: MoverLayer
var combat: CombatLayer
var avatar: Avatar
var rig: CameraRig
## Optional hook called when `afx` arrives (addon_host.gd / api.creatures.damaged).
var on_damaged_hook := Callable()

var sfx := Sfx.new()
var sprites := SpriteFx.new()
## What weapons fire: shots, projectiles, beams, explosions, fires and clouds (weapon_fx.gd).
var weapons := WeaponFx.new()
## Flamethrowers' begin/loop/end sounds (turrets.gd's turrets and tank, the character's here).
var flame_sound := FlameSound.new()
var combat_sounds := CombatSounds.new()
## The combat sounds were decoded ahead (on the first combat message, _warm_combat).
var _combat_warmed := false
## Fulgora's lightning bolts (`lt`).
var lightning := Lightning.new()
## A modeller's burner inserters' wisps and crackle while they burn (burner_fx.gd).
var burners := BurnerFx.new()
## The steps' sounds from the prototypes (`steps`, step_sounds.gd); the name table below without them.
var steps := StepSounds.new()
## Persistent vehicle tread tracks and ballistic dirt/mud clods & dust plumes (vehicle_tracks.gd).
var vehicle_tracks := VehicleTracks.new()

var _tracked := {}  # unit -> Tracked, from mv
var _gun := "pistol"
var _night := 0.0
var _scan_timer := 0.0
var _emitters := {}  # unit -> Emitter
var _step_timer := 0.0
var _footfalls := 0
var _warmed := false
var _mine_timer := 0.0
var _mine_kind := ""
var _mine_sound := ""
## Entities' own mining sounds by prototype id, from `eprops` (`ms`, the bridge's data stage): J11.
var _mining_sounds := {}
## And their own repair sounds (`rsd`): K13.
var _repair_sounds := {}
var _repair_timer := 0.0
var _mine_target := Vector2(INF, INF)
var _last_mining_msec := -100000
var _last_mining_at := Vector2.ZERO
var _last_mining_progress := -1
var _shot_clock := 0.0
var _biter_wait := 0.0
var _burning := {}  # unit -> [remaining seconds, last position]
var _tops := {}  # proto name -> height of the model's top
var _states := {}  # unit -> working state last scan, for activate/deactivate sounds
var _track_proto := {}  # proto_id -> bool (true only for vehicles and enemies tracked in _scan)
## Working machines near with sound accents: unit -> [Loop, position, animation frame, proto name].
var _accents := {}


func _ready() -> void:
	FxSettings.load_settings()
	sfx.name = "Sfx"
	add_child(sfx)
	sprites.name = "Sprites"
	sprites.visible = FxSettings.effects_enabled
	add_child(sprites)
	weapons.name = "Weapons"
	weapons.sprites = sprites
	weapons.sfx = sfx
	combat_sounds.sfx = sfx
	weapons.extra_sounds = combat_sounds
	add_child(weapons)
	flame_sound.name = "FlameSound"
	add_child(flame_sound)
	lightning.name = "Lightning"
	add_child(lightning)
	vehicle_tracks.name = "VehicleTracks"
	vehicle_tracks.visible = FxSettings.effects_enabled
	add_child(vehicle_tracks)
	# After the player's input (which sets combat's aim each frame) and fx_demo.gd.
	process_priority = 2
	for arg in Switches.args():
		if arg == "--weapons-demo":
			var weapons_demo := WeaponsDemo.new()
			weapons_demo.fx = self
			add_child(weapons_demo)
		if arg.begins_with("--fx-demo"):
			var demo := FxDemo.new()
			demo.fx = self
			demo.space = arg == "--fx-demo=space"
			demo.stress = arg == "--fx-demo=stress"
			add_child(demo)


func _exit_tree() -> void:
	SoundBank.clear_cache()


## The planet the character is on, for its ambience and music; `space` on a platform.
func set_planet(planet: String, space: bool) -> void:
	sfx.ambience.set_planet(planet, space)
	weapons.in_space = space


func reset() -> void:
	_tracked.clear()
	_states.clear()
	_emitters.clear()
	burners.clear()
	sprites.clear()
	lightning.clear()
	vehicle_tracks.clear()
	sfx.stop_all()
	weapons.reset()
	_burning.clear()
	_tops.clear()
	_track_proto.clear()


## Every message from the bridge, before main.gd routes it.
func handle(msg: Dictionary) -> void:
	match str(msg.get("t", "")):
		"mv":
			_track(msg)
		"add":
			if Bridge.world_ready:
				_on_add(msg.get("e"))
		"upd":
			if Bridge.world_ready:
				_on_upd(msg.get("e"))
		"del":
			_on_del(msg)
		"mnd":
			# J20: the bridge's word that the character's mining took it, ahead of its `del` (world.gd takes the
			# record away on this, so the `del` after finds nothing to sound again).
			if int(msg.get("g", 0)) == 1 and int(msg.get("gi", 0)) == 0:
				_on_del(msg)
		"died":
			_warm_combat()
			_on_died(msg)
		"afx":
			_warm_combat()
			combat_sounds.hit(msg, avatar.unit if avatar != null else 0)
			_on_combat_fx(msg)
		"atk":
			_warm_combat()
			_on_attack(msg)
		"shot":
			_warm_combat()
			_on_shot(msg)
			weapons.handle(msg)
		"pj":
			_warm_combat()
			weapons.handle(msg)
		"gf":
			weapons.handle(msg)
		"lt":
			_on_lightning(msg)
		"guns":
			var list = msg.get("l")
			var sel := int(msg.get("sel", 1)) - 1
			if list is Array and sel >= 0 and sel < list.size() and list[sel] is Array and list[sel].size() > 0:
				_gun = str(list[sel][0])
		"eprops":
			_mining_sounds = mining_sounds_of(msg)
			_repair_sounds = mining_sounds_of(msg, "rsd")
		"welcome":
			steps.reset()  # a bridge without the list (older, or its data stage failed) sends none: the table
		"steps":
			steps.handle(msg)
		"sky":
			_night = clampf(int(msg.get("n", 0)) / 850.0, 0.0, 1.0)
			sfx.ambience.darkness = int(msg.get("n", 0)) / 1000.0
		"ui_sfx":
			var s := str(msg.get("s", ""))
			if s != "":
				Sfx.play_ui(s)


func _process(delta: float) -> void:
	if rig == null or avatar == null:
		return
	sfx.set_listener(rig.focus_point(), get_viewport().get_camera_3d(), rig.distance)
	sprites.night = _night
	weapons.avatar = avatar
	weapons.movers = movers
	weapons.world = world
	weapons.hand_stream = avatar.firing and _gun == "flamethrower"
	weapons.aim = combat.aim if combat != null and combat.aim_mode == 1 else null
	if not Bridge.world_ready or MomentHold.on:
		return  # a screenshot's moment: no new smoke, steps or sounds
	_scan_timer += delta
	if _scan_timer >= SCAN_INTERVAL:
		_scan(_scan_timer)
		_scan_timer = 0.0
	if not _warmed:
		_warmed = true
		_warm_sounds()
	_update_steps(delta)
	_update_mining(delta)
	_update_repair(delta)
	_update_accents(delta)
	_update_shots(delta)
	combat_sounds.character(delta, avatar.health, avatar.max_health, avatar.position + Vector3(0, 1, 0))
	sprites.visible = FxSettings.effects_enabled  # the Settings window can change it in the game
	vehicle_tracks.visible = FxSettings.effects_enabled
	if FxSettings.effects_enabled:
		_update_emitters(delta)
		burners.step(sprites, delta, WIND)
		_update_vehicle_fx(delta)
	_update_combat_fx(delta)


# --- What is near: machine and vehicle loops, smoke emitters, biters ----------------------------

func _scan(elapsed: float) -> void:
	var here := sfx.listener_position()
	var focus := Vector2(here.x, here.z)
	var sources: Array = []
	var emitters := {}
	var protos := world.protos
	var states := {}
	var accents := {}
	# (--stutter-probe) The scan's parts in the spike log: fx_machines, fx_burners, fx_movers, fx_loops.
	var tp := Time.get_ticks_usec() if Probing.on else 0
	for unit in world.working_near(focus, SMOKE_RANGE):
		var working := int(world.working.get(unit, 0)) == 1
		var r: WorldMirror.Rec = world.entities.get(unit)
		if r == null:
			continue
		var off := r.pos - focus
		if absf(off.x) > SMOKE_RANGE or absf(off.y) > SMOKE_RANGE:
			continue
		var proto: ProtoDB.EntityProto = protos.entity(r.proto_id)
		if proto == null or proto.type == "lamp":
			continue
		if off.length() < HEARING:
			_machine_sound(unit, r, proto, working, sources)
			states[unit] = working
			if working and ACCENT_ANIMS.has(proto.name):
				var loop := SoundBank.working_sound(proto.name)
				if loop != null and not loop.accents.is_empty():
					var was: Array = _accents.get(unit, [])
					accents[unit] = [loop, Vector3(r.pos.x, 1.0, r.pos.y), float(was[2]) if was.size() > 2 else 0.0, proto.name]
		if not working:
			continue
		if EMITTERS.has(proto.name) and emitters.size() < MAX_EMITTERS:
			var e: Emitter = _emitters.get(unit)
			if e == null:
				e = _make_emitter(r, proto)
			emitters[unit] = e
	_emitters = emitters
	_states = states
	if Probing.on:
		Probing.add("fx_machines", tp)
		tp = Time.get_ticks_usec()
	if BurnerFx.near_scan:
		burners.follow(world)
	burners.scan(world.entities, world.animator.arm_working, focus, HEARING, sources,
		_drawn_mesh, _burner_vent, world if BurnerFx.near_scan else null)
	if Probing.on:
		Probing.add("fx_burners", tp)
		tp = Time.get_ticks_usec()
	_accents = accents
	# Vehicles, from their movement since the last scan.
	var stale := Time.get_ticks_msec() - 1000
	var biters: Array = []
	for unit in _tracked.keys():
		var t: Tracked = _tracked[unit]
		if t.seen < stale:
			_tracked.erase(unit)
			continue
		t.speed = lerpf(t.speed, t.pos.distance_to(t.scan_pos) / elapsed, 0.6)
		t.scan_pos = t.pos
		if t.pos.distance_to(focus) > HEARING:
			continue
		var proto: ProtoDB.EntityProto = protos.entity(t.proto_id)
		if proto == null:
			continue
		var vkey := vehicle_sound_key(proto)
		if vkey != "":
			var spec: Array = VEHICLE_SOUNDS[vkey]
			var inside: bool = avatar != null and avatar.vehicle == int(unit)
			var at := Vector3(t.pos.x, 1.0, t.pos.y)
			var rules := SoundBank.working_sound(proto.name)
			var vehicle := {"key": "v%d" % unit, "pos": at, "group": vkey, "reach": 1.0, "own": inside,
				"per_group": rules.max_per_prototype if rules != null else 0,
				"fade_in": rules.fade_in if rules != null else 0.13, "fade_out": rules.fade_out if rules != null else 0.33}
			if t.speed > 0.4:
				vehicle["path"] = spec[0]
				vehicle["volume"] = float(spec[2]) * clampf(0.4 + t.speed / 12.0, 0.4, 1.0)
				sources.append(vehicle)
			elif inside and spec[1] != "":
				vehicle["path"] = spec[1]
				vehicle["volume"] = float(spec[2]) * 0.7
				sources.append(vehicle)
		elif ENEMY_TYPES.has(proto.type) and t.pos.distance_to(focus) < 24.0:
			biters.append([proto.name, t.pos])
		elif proto.type == "combat-robot":
			var robot := CombatSounds.robot_loop(proto.name, int(unit), Vector3(t.pos.x, 1.5, t.pos.y))
			if not robot.is_empty():
				sources.append(robot)
	if Probing.on:
		Probing.add("fx_movers", tp)
		tp = Time.get_ticks_usec()
	sfx.set_loops(sources)
	_biter_chatter(biters, elapsed)
	if Probing.on:
		Probing.add("fx_loops", tp)


## A machine near the listener: its working loop (or its idle sound while it isn't working), with
## its prototype's rules, and its activate/deactivate sound when it just started or stopped.
func _machine_sound(unit, r: WorldMirror.Rec, proto: ProtoDB.EntityProto, working: bool, sources: Array) -> void:
	var loop := SoundBank.working_sound(proto.name)
	if loop == null:
		return
	var at := Vector3(r.pos.x, 1.0, r.pos.y)
	if _states.has(unit) and bool(_states[unit]) != working:
		sfx.play_def(loop.activate if working else loop.deactivate, at, "Environment")
	var def: SoundBank.SoundDef = loop.sound if working else loop.idle
	if def == null or def.files.is_empty():
		return
	# Each machine keeps one variation (Factorio picks one per entity).
	var i := int(unit) % def.files.size()
	sources.append({"key": unit, "pos": at, "path": def.files[i], "volume": def.max_volumes[i], "reach": def.reach,
		"curve": def.attenuation, "group": proto.name, "per_group": loop.max_per_prototype,
		"fade_in": loop.fade_in, "fade_out": loop.fade_out})


## I25: each working machine's sound accents as its working animation passes their frames, as
## Factorio plays them (the frame is counted here from when it was first heard working; the game's
## own animation frame isn't sent).
func _update_accents(delta: float) -> void:
	for unit in _accents:
		var a: Array = _accents[unit]
		var loop: SoundBank.Loop = a[0]
		var anim: Array = ACCENT_ANIMS[a[3]]
		var frames: float = anim[0]
		var before: float = a[2]
		var after := before + delta * 60.0 * float(anim[1])
		for accent: Array in loop.accents:
			var f := float(accent[1])
			# Passed since the last frame, round the loop's end too.
			if (before < f and after >= f) or (after >= frames and f < after - frames):
				sfx.play_def(accent[0], a[1], "Environment")
		a[2] = fmod(after, frames)


## Where a burner inserter's wisp leaves (burner_fx.gd scan).
func _burner_vent(r) -> Vector3:
	return BurnerFx.vent_at(r.pos, Visuals.direction_yaw(r.dir))


## The mesh an inserter is drawn with (chunk_view.gd's), for burner_fx.gd: whether its burner burns.
func _drawn_mesh(r) -> Mesh:
	var proto: ProtoDB.EntityProto = world.protos.entity(r.proto_id)
	if proto == null or proto.type != "inserter" or not ModelLibrary.ready(proto.name):
		return null
	return ModelLibrary.mesh_for_entity(proto.name, proto.type, r.extra, r.dir)


func _make_emitter(r: WorldMirror.Rec, proto: ProtoDB.EntityProto) -> Emitter:
	var spec: Array = EMITTERS[proto.name]
	var e := Emitter.new()
	e.kind = spec[0]
	e.rate = spec[2]
	var yaw := Visuals.direction_yaw(r.dir)
	var off: Vector2 = spec[1]
	var local := Vector3(off.x, 0.0, off.y).rotated(Vector3.UP, yaw)
	e.pos = Vector3(r.pos.x, _top(proto) * float(spec[3]), r.pos.y) + local
	e.spread = Vector3(0.0, 0.0, float(spec[4])).rotated(Vector3.UP, yaw)
	e.due = randf()
	return e


## Biters call now and then, a few at a time, like a nest heard from nearby.
func _biter_chatter(biters: Array, elapsed: float) -> void:
	_biter_wait -= elapsed
	if biters.is_empty() or _biter_wait > 0.0:
		return
	if randf() > minf(0.6, biters.size() * 0.08):
		return
	_biter_wait = randf_range(0.6, 2.0)
	var b: Array = biters[randi() % biters.size()]
	var name: String = b[0]
	var path := _chatter_sound(name)
	var pos: Vector2 = b[1]
	sfx.play_at(path, Vector3(pos.x, 0.5, pos.y), 0.45, 0.08, 1.0, "Enemies")


## The idle call of an enemy: Factorio's `working_sound` (biter-call*, spitter-call-*), not the attack
## roars the old code used. `--combat-sound-limit=old`: the old files.
static func _chatter_sound(name: String) -> String:
	if not Sfx.combat_limits:
		if "spitter" in name:
			return "base/sound/creatures/Spiters_%d_%d.ogg" % [randi_range(1, 5), randi_range(1, 2)]
		if "behemoth" in name:
			return SoundBank.pick("base/sound/creatures/biter-roar-behemoth")
		if "big" in name:
			return SoundBank.pick("base/sound/creatures/biter-roar-big")
		if "medium" in name:
			return SoundBank.pick("base/sound/creatures/biter-roar-mid")
		return SoundBank.pick("base/sound/creatures/biter-roar")
	if "spitter" in name:
		if "behemoth" in name or "big" in name:
			return SoundBank.pick("base/sound/creatures/spitter-call-big")
		if "medium" in name:
			return SoundBank.pick("base/sound/creatures/spitter-call-med")
		return SoundBank.pick("base/sound/creatures/spitter-call-small")
	if "behemoth" in name:
		return SoundBank.pick("base/sound/creatures/biter-call-behemoth")
	if "big" in name:
		return SoundBank.pick("base/sound/creatures/biter-call-big")
	return SoundBank.pick("base/sound/creatures/biter-call")


## The sound an enemy's death makes, its prototype's `dying_sound` (units: biter-death*, spitter-death*;
## worms: worm-death*; nests: spawner-death), or "" for anything else.
static func enemy_death_prefix(proto: ProtoDB.EntityProto) -> String:
	var n: String = proto.name
	var base := "base/sound/creatures/"
	if proto.type == "unit-spawner":
		return base + "spawner-death"
	if proto.type == "turret" and "worm" in n:
		if "behemoth" in n:
			return base + "worm-death-behemoth"
		if "big" in n:
			return base + "worm-death-big"
		if "medium" in n:
			return base + "worm-death"
		return base + "worm-death-small"
	if ENEMY_TYPES.has(proto.type):
		var big := "big" in n or "behemoth" in n
		if "spitter" in n:
			if "behemoth" in n:
				return base + "spitter-death-behemoth"
			if "big" in n:
				return base + "spitter-death-big"
			if "medium" in n:
				return base + "spitter-death-mid"
			return base + "spitter-death"
		return base + ("biter-death-big" if big else "biter-death")
	return ""


func _track(msg: Dictionary) -> void:
	var list = msg.get("l")
	var now := Time.get_ticks_msec()
	if WireDecode.packed(list):
		# A binary frame's records, whole (wire_decode.gd).
		var stride := WireDecode.MV_STRIDE
		var i := 0
		while i + stride <= list.size():
			_track_one(list[i], list[i + 1], list[i + 2], list[i + 3], now)
			i += stride
		return
	if not (list is Array):
		return
	# z = 1: a record's first four numbers are the differences from the record before it (as movers.gd).
	var deltas := int(msg.get("z", 0)) == 1
	var unit := 0
	var proto := 0
	var x := 0
	var y := 0
	for rec in list:
		if not (rec is Array) or rec.size() < 4:
			continue
		if deltas:
			unit += int(rec[0])
			proto += int(rec[1])
			x += int(rec[2])
			y += int(rec[3])
		else:
			unit = int(rec[0])
			proto = int(rec[1])
			x = int(rec[2])
			y = int(rec[3])
		_track_one(unit, proto, x, y, now)


func _track_one(unit: int, proto: int, x: int, y: int, now: int) -> void:
	var wanted = _track_proto.get(proto)
	if wanted != null:
		if not bool(wanted):
			return
	elif proto > 0 and world != null and world.protos != null:
		var ep: ProtoDB.EntityProto = world.protos.entity(proto)
		if ep != null:
			var keep: bool = vehicle_sound_key(ep) != "" or ENEMY_TYPES.has(ep.type) or ep.type == "combat-robot"
			_track_proto[proto] = keep
			if not keep:
				return
	var t: Tracked = _tracked.get(unit)
	var pos := Vector2(x, y) / 256.0
	if t == null:
		t = Tracked.new()
		t.scan_pos = pos
		_tracked[unit] = t
	t.proto_id = proto
	t.pos = pos
	t.seen = now


# --- Smoke and steam ------------------------------------------------------------------------------

func _update_emitters(delta: float) -> void:
	for e: Emitter in _emitters.values():
		e.due -= delta * e.rate
		while e.due <= 0.0:
			e.due += 1.0
			_puff(e)


static func vehicle_sound_key(proto: ProtoDB.EntityProto) -> String:
	if proto == null:
		return ""
	if VEHICLE_SOUNDS.has(proto.name):
		return proto.name
	if VEHICLE_SOUNDS.has(proto.type):
		return proto.type
	return ""


## Surface kind ("grass", "dirt", "sand", "mud", "stone", "concrete", "metal", "water"), ground
## tint color, and whether the tile kicks up natural dust for a vehicle at `p`.
func _vehicle_ground(p: Vector2) -> Array:
	var ground := _ground_under(p)
	var kind := "dirt"
	var color := Color(0.42, 0.36, 0.28)
	var id := world.tile_at(floori(p.x), floori(p.y))
	if id >= 0 and id < world.protos.tile_names.size():
		if world.protos.is_water(id):
			kind = "water"
		else:
			var tile: String = world.protos.tile_names[id]
			if "concrete" in tile:
				kind = "concrete"
			elif "stone-path" in tile or "paving" in tile or "brick" in tile:
				kind = "stone"
			elif "platform" in tile or "foundation" in tile or "metal" in tile or "machinery" in tile:
				kind = "metal"
			elif "sand" in tile or "desert" in tile or "dunes" in tile:
				kind = "sand"
			elif "grass" in tile:
				kind = "grass"
			elif "mud" in tile or "wetland" in tile or "lowland" in tile:
				kind = "mud"
			color = world.protos.tile_color(id)
	if ground[1] is Color:
		color = ground[1] as Color
	elif kind != "water" and (str(ground[0]).contains("transport-belt") or str(ground[0]).contains("rails")):
		kind = "metal"
	return [kind, color, ground[1] is Color]


## Exhaust smoke, persistent tread tracks, ballistic dirt/mud clods, and wheel/track dust for
## moving, turning, and occupied idling cars & tanks.
func _update_vehicle_fx(delta: float) -> void:
	if MomentHold.on or world == null or world.protos == null:
		return
	var here := sfx.listener_position()
	var focus := Vector2(here.x, here.z)
	vehicle_tracks.tick(delta, focus)
	if not VehicleAnim.enhanced and not VehicleTracks.enabled:
		return
	for unit in _tracked.keys():
		var t: Tracked = _tracked[unit]
		if t.pos.distance_to(focus) > HEARING:
			continue
		var proto: ProtoDB.EntityProto = world.protos.entity(t.proto_id)
		if proto == null or (proto.name != "car" and proto.name != "tank"):
			continue
		var is_tank := proto.name == "tank"
		var inside: bool = avatar != null and avatar.vehicle == int(unit)
		var yaw := float(movers.yaw_of(int(unit))) if movers != null else 0.0
		var mpos: Variant = movers.position_of(int(unit)) if movers != null else null
		var vpos := Vector2((mpos as Vector3).x, (mpos as Vector3).z) if mpos is Vector3 else t.pos
		var driving := t.speed > 0.35
		var track_step := VehicleTracks.enabled and (driving or inside or vehicle_tracks.needs_step(int(unit), vpos, yaw))
		if not track_step and (not VehicleAnim.enhanced or (not driving and not inside)):
			continue
		var vground: Array = []
		if track_step:
			vground = _vehicle_ground(vpos)
			vehicle_tracks.step_vehicle(int(unit), vpos, yaw, t.speed, is_tank,
				str(vground[0]), vground[1] as Color, delta)
		if not VehicleAnim.enhanced or (not driving and not inside):
			continue
		var rot := Basis(Vector3.UP, yaw)
		var gy := GroundHeight.at(vpos.x, vpos.y)
		var base := Vector3(vpos.x, gy, vpos.y)
		var ex_rate := (2.0 if is_tank else 1.5) + clampf(t.speed * 0.45, 0.0, 5.5 if is_tank else 4.5)
		t.exhaust_due -= delta * ex_rate
		while t.exhaust_due <= 0.0:
			t.exhaust_due += 1.0
			var ex_local := Vector3(randf_range(-0.22, 0.22), 0.65, 1.42) if is_tank else Vector3(0.28, 0.55, 1.05)
			var ex_col := Color(0.28, 0.27, 0.26, 0.48) if is_tank else Color(0.45, 0.44, 0.43, 0.36)
			var puff := sprites.emit("smoke", base + rot * ex_local,
				randf_range(0.38, 0.58) if is_tank else randf_range(0.28, 0.42),
				randf_range(0.7, 1.05) if is_tank else randf_range(0.55, 0.85), ex_col)
			if puff != null:
				puff.vel = WIND + rot * Vector3(0.0, 0.0, 0.45) + Vector3(randf_range(-0.15, 0.15), randf_range(0.4, 0.8), randf_range(-0.15, 0.15))
				puff.rise = 0.25
		if t.speed <= 1.2:
			continue
		var dust_scale := 0.45 if VehicleTracks.enabled else 1.0
		var dust_rate := clampf(t.speed * 1.1, 2.0, 12.0) * dust_scale
		t.dust_due -= delta * dust_rate
		while t.dust_due <= 0.0:
			t.dust_due += 1.0
			if vground.is_empty():
				vground = _vehicle_ground(vpos)
			if not bool(vground[2]):
				continue
			var tint := (vground[1] as Color).lerp(Color(0.72, 0.68, 0.60), 0.35)
			tint.a = randf_range(0.32, 0.48) * (0.65 if VehicleTracks.enabled else 1.0)
			var side := -1.0 if randf() < 0.5 else 1.0
			var wheel_local := Vector3(side * (0.66 if is_tank else 0.56), 0.14, 1.15 if is_tank else 0.85)
			var dp := sprites.emit("dust", base + rot * wheel_local,
				randf_range(0.45, 0.72) if is_tank else randf_range(0.32, 0.52),
				randf_range(0.45, 0.75), tint)
			if dp != null:
				dp.vel = WIND * 0.5 + rot * Vector3(side * randf_range(0.15, 0.4), randf_range(0.25, 0.55), randf_range(0.2, 0.5))


func _puff(e: Emitter) -> void:
	var at := e.pos + e.spread * randf_range(-1.0, 1.0)
	if e.kind == "thrust":
		var flame := sprites.emit("hit", at, randf_range(0.25, 0.45), 0.22, Color(1.0, randf_range(0.28, 0.65), 0.08, 0.85))
		if flame != null:
			flame.vel = Vector3(randf_range(-0.2, 0.2), -randf_range(0.3, 0.8), randf_range(-0.2, 0.2))
		return
	if e.kind == "steam":
		# The smoke sheet is mid-grey; tinting above white makes it steam.
		var c := sprites.emit("smoke", at, 0.8, randf_range(2.0, 3.0), Color(1.8, 1.8, 1.85, 0.6))
		if c != null:
			c.size1 = randf_range(2.0, 2.8)
			c.vel = Vector3(randf_range(-0.2, 0.2), randf_range(0.9, 1.3), randf_range(-0.2, 0.2)) + WIND
			c.drag = 0.4
			c.spin_rate = randf_range(-0.4, 0.4)
	else:
		var c := sprites.emit("smoke", at, 0.45, randf_range(3.5, 5.0), Color(0.3, 0.29, 0.28, 0.6))
		if c != null:
			c.size1 = randf_range(2.2, 3.0)
			c.vel = Vector3(randf_range(-0.1, 0.1), randf_range(0.6, 0.9), randf_range(-0.1, 0.1))
			c.rise = 0.05
			c.drag = 0.15
			c.spin_rate = randf_range(-0.3, 0.3)
			c.vel += WIND


func _top(proto: ProtoDB.EntityProto) -> float:
	if _tops.has(proto.name):
		return _tops[proto.name]
	if not ModelLibrary.ready(proto.name):
		return Visuals.height_for(proto)  # its model is being made: asked again next time
	var mesh := ModelLibrary.mesh_for(proto.name)
	var top := mesh.get_aabb().end.y if mesh != null else Visuals.height_for(proto)
	_tops[proto.name] = top
	return top


func _on_combat_fx(msg: Dictionary) -> void:
	if on_damaged_hook.is_valid():
		_notify_damaged(msg)
	if not FxSettings.effects_enabled:
		return
	var pos := Vector3(int(msg.get("x", 0)) / 256.0, 0.04, int(msg.get("y", 0)) / 256.0)
	var unit := int(msg.get("u", 0))
	if str(msg.get("fx", "")) == "burn":
		_burning[unit] = [2.4, pos]
		for i in 5:
			var flame := sprites.emit("hit", pos + Vector3(randf_range(-0.28, 0.28), randf_range(0.25, 0.8), randf_range(-0.28, 0.28)), 0.38, 0.3, Color(1.0, randf_range(0.2, 0.55), 0.04, 0.9))
			if flame != null:
				flame.vel = Vector3(randf_range(-0.25, 0.25), randf_range(0.25, 0.7), randf_range(-0.25, 0.25))
		return
	var decal := sprites.emit("scorch", pos, randf_range(0.25, 0.55), 18.0, Color(0.65, 0.045, 0.035, 0.9))
	if decal != null:
		decal.frame = randi() % sprites.frame_count("scorch")
		decal.angle = randf() * TAU
	for i in 3:
		var drop := sprites.emit("hit", pos + Vector3(randf_range(-0.25, 0.25), randf_range(0.2, 0.65), randf_range(-0.25, 0.25)), 0.2, 0.28, Color(0.8, 0.05, 0.025, 0.85))
		if drop != null:
			drop.vel = Vector3(randf_range(-0.7, 0.7), randf_range(0.1, 0.6), randf_range(-0.7, 0.7))


func _notify_damaged(msg: Dictionary) -> void:
	var unit := int(msg.get("u", 0))
	var pos := Vector3(int(msg.get("x", 0)) / 256.0, 0.0, int(msg.get("y", 0)) / 256.0)
	var cause: Variant = Vector3(int(msg["cx"]) / 256.0, 0.0, int(msg["cy"]) / 256.0) if msg.has("cx") and msg.has("cy") else null
	var proto_name := ""
	if unit != 0:
		if _tracked.has(unit) and world != null and world.protos != null:
			var t: Tracked = _tracked[unit]
			var ep: ProtoDB.EntityProto = world.protos.entity(t.proto_id)
			if ep != null:
				proto_name = ep.name
		if proto_name == "" and movers != null and movers.creatures != null:
			proto_name = movers.creatures.name_of(unit)
		if proto_name == "" and world != null and world.entities.has(unit) and world.protos != null:
			var rec: WorldMirror.Rec = world.entities[unit]
			var ep2: ProtoDB.EntityProto = world.protos.entity(rec.proto_id)
			if ep2 != null:
				proto_name = ep2.name
	if proto_name == "" and msg.has("p") and world != null and world.protos != null:
		var ep3: ProtoDB.EntityProto = world.protos.entity(int(msg["p"]))
		if ep3 != null:
			proto_name = ep3.name
	on_damaged_hook.call({
		"unit": unit,
		"name": proto_name,
		"pos": pos,
		"cause_pos": cause,
		"damage_type": str(msg.get("dt", "")),
		"fx": str(msg.get("fx", "")),
		"dmg": int(msg.get("dmg", 0)),
		"hp": int(msg.get("hp", -1)),
		"src": str(msg.get("src", "")),
	})


func _update_combat_fx(delta: float) -> void:
	for unit in _burning.keys():
		var entry: Array = _burning[unit]
		entry[0] = float(entry[0]) - delta
		var pos: Vector3 = entry[1]
		if avatar != null and (int(unit) == 0 or int(unit) == avatar.unit):
			pos = Vector3(avatar.position.x, 0.4, avatar.position.z) + avatar.lifted()  # on the drawn body (1.7)
		elif int(unit) > 0 and movers != null:
			var moving = movers.position_of(int(unit))
			if moving is Vector3:
				pos = moving + Vector3(0, 0.35, 0)
		if randf() < delta * 8.0:
			var flame := sprites.emit("hit", pos + Vector3(randf_range(-0.25, 0.25), randf_range(0.25, 0.8), randf_range(-0.25, 0.25)), 0.34, 0.28, Color(1.0, randf_range(0.2, 0.55), 0.03, 0.88))
			if flame != null:
				flame.vel = Vector3(randf_range(-0.2, 0.2), 0.35, randf_range(-0.2, 0.2))
		if float(entry[0]) <= 0.0:
			_burning.erase(unit)


# --- The character ----------------------------------------------------------------------------------

func _update_steps(delta: float) -> void:
	# I21: a step on each footfall of the character's run cycle (character_anim.gd), so the sound
	# keeps the legs' beat at any speed, exoskeletons too; the old fixed 0.3 s timer restarted
	# whenever `walking` flickered (an angled walk's zig-zag) and drifted off the feet.
	var falls := avatar.footfalls()
	var fell := falls != _footfalls
	_footfalls = falls
	if not avatar.walking or avatar.vehicle != 0:
		_step_timer = 0.0
		return
	_step_timer += delta
	if not fell and _step_timer < STEP_FALLBACK:
		return
	var ground := avatar.ground_position()
	var surface := _ground_under(ground)
	var feet := avatar.position + avatar.lifted()  # where the feet are drawn (an add-on's lift, 1.7)
	var at := feet + Vector3(0, 0.1, 0)
	var def: SoundBank.SoundDef = surface[2]
	if def != null:
		if not _def_ready(def):
			return  # this ground's sounds are still being decoded (they all start now)
		_step_timer = 0.0
		sfx.play_def(def, at, "Walking", 1.0, "step/" + StepSounds.name_of(def), true)
	elif surface[0] == "":
		_step_timer = 0.0
		return  # a ground Factorio walks on in silence (its tile has no walking_sound)
	else:
		var sound := _pick_ready(surface[0])
		if sound == "":
			return
		_step_timer = 0.0
		sfx.play_at(sound, at, 0.5, 0.06, 1.0, "Walking", "step/" + surface[0].get_file(), true)
	if surface[3]:
		var rustle: SoundBank.SoundDef = _rustle_under(ground)
		if rustle != null and _def_ready(rustle):
			sfx.play_def(rustle, at, "Walking", 1.0, StepSounds.rustle_kind(rustle), true)
	if FxSettings.effects_enabled and surface[1] is Color:
		var tint: Color = surface[1]
		var c := sprites.emit("dust", feet + Vector3(randf_range(-0.15, 0.15), 0.15, randf_range(-0.15, 0.15)), 0.35, 0.7, Color(tint.r, tint.g, tint.b, 0.22))
		if c != null:
			c.size1 = 0.9
			c.vel = Vector3(0, 0.25, 0)


## True when every variation of `def` is decoded; starts decoding the rest. play_def picks any of them, and
## one still decoding would play nothing (the first steps on a ground lost, as _pick_ready says).
func _def_ready(def: SoundBank.SoundDef) -> bool:
	var ready := true
	for f in def.files:
		if SoundBank.stream_soon(f) == null:
			ready = false
	return ready


## The owner's 24: a plant or other decorative on the tile at `p` with a walking_sound of its own rustles as
## the character steps through it (`steps` dl). Factorio's docs don't say how it combines with the
## ground's sound: here it plays on top of the ground's step, each at its own volume, one decorative a
## step (the first listed with a sound). Null for none, with `--steps=table`, or without decoratives
## (Settings > Graphics > Decoratives off: the bridge sends none).
func _rustle_under(p: Vector2) -> Variant:
	if not is_instance_valid(decoratives) or steps.decoratives.is_empty():
		return null
	for id in decoratives.ids_at(floori(p.x), floori(p.y)):
		var d: Variant = steps.lookup(steps.decoratives, id)
		if d is SoundBank.SoundDef:
			return d
	return null


## A variation of `prefix` that is already decoded, or "" while none is. Every variation is asked
## for at once: SoundBank.pick() handed out one whose decoding had only just been started, which
## played nothing, so the first steps on a ground (and the first swing) were often silent.
func _pick_ready(prefix: String) -> String:
	var ready := PackedStringArray()
	for p in SoundBank.variants(prefix):
		if SoundBank.stream_soon(p) != null:
			ready.append(p)
	return ready[randi() % ready.size()] if ready.size() > 0 else ""


## Starts decoding the character's commonest sounds once the world is there, so the first swing
## and the first steps aren't lost to decoding.
func _warm_sounds() -> void:
	for prefix in MINE_SOUNDS.values():
		_pick_ready(prefix)
	# What mining something ends with (_on_del): since M1 a building's only sound, and the first of
	# each in a session was lost to decoding (seen with --sfx-log: the first furnace mined silent).
	for path in MINED_SOUNDS:
		SoundBank.stream_soon(path)
	for prefix in ["base/sound/walking/grass", "base/sound/walking/dirt-1", "base/sound/walking/sand",
			"base/sound/walking/concrete", "core/sound/walking/transport-belt"]:
		_pick_ready(prefix)


## [the table's sound prefix ("" for silence), dust colour or null, the prototype's sound (a SoundDef from
## `steps`) or null, whether plants there rustle] for the ground at `p`: what the character stands on
## (belts, heat pipes, rails, ore), else the tile. The prototype's sound when the bridge's list has one
## whose files are here, else the name table (step_sounds.gd says when). The dust colour is the table's.
func _ground_under(p: Vector2) -> Array:
	var r := world.pick(p)
	if r != null:
		var proto: ProtoDB.EntityProto = world.protos.entity(r.proto_id)
		if proto != null:
			if proto.type in ["transport-belt", "underground-belt", "splitter"]:
				return ["core/sound/walking/transport-belt", null, steps.utility_sound(0), false]
			if proto.type == "heat-pipe":
				var heat: Variant = steps.utility_sound(1)
				if heat != null:
					return ["", null, heat, false]
			var own: Variant = steps.lookup(steps.entities, r.proto_id)
			if "rail" in proto.type:
				return ["base/sound/walking/rails/rails", null, own if own is SoundBank.SoundDef else null, false]
			if proto.type == "resource":
				var ore := "base/sound/walking/resources/oil" if "oil" in proto.name else "base/sound/walking/resources/ore"
				if own is SoundBank.SoundDef:
					return [ore, proto.color, own, true]
				# A resource the list leaves out has no walking sound of its own: the tile's, as in Factorio.
				if not (steps.listed and not StepSounds.use_table and not steps.entities.has(r.proto_id)):
					return [ore, proto.color, null, true]
	var id := world.tile_at(floori(p.x), floori(p.y))
	if id < 0 or id >= world.protos.tile_names.size():
		return ["base/sound/walking/dirt-1", null, null, false]
	var listed: Variant = steps.lookup(steps.tiles, id)
	if listed is int:  # StepSounds.SILENT: Factorio's tile has no walking sound
		return ["", null, null, false]
	var surface := _table_ground(world.protos.tile_names[id], world.protos.is_water(id))
	var dust: Variant = world.protos.tile_color(id) if surface[1] is bool else null
	if listed is SoundBank.SoundDef:
		return ["", dust, listed, true]
	return [surface[0], dust, null, true]


## The name table, from before the bridge sent the prototypes' sounds (and `--steps=table`): [prefix,
## true for the tile's dust colour or null for none].
static func _table_ground(tile: String, water: bool) -> Array:
	if water:
		return ["base/sound/walking/shallow-water", null]
	if "refined-concrete" in tile:
		return ["base/sound/walking/refined-concrete", null]
	if "concrete" in tile or "stone-path" in tile:
		return ["base/sound/walking/concrete", null]
	# Space Age's grounds have their own steps (each tile's walking_sound): the nearest by name.
	for k in SPACE_AGE_STEPS:
		if k in tile:
			return ["space-age/sound/walking/" + SPACE_AGE_STEPS[k], true]
	if "sand" in tile or "desert" in tile:
		return ["base/sound/walking/sand", true]
	if "grass" in tile:
		return ["base/sound/walking/grass", true]
	return ["base/sound/walking/dirt-1", true]


func _update_mining(delta: float) -> void:
	# I20: the swing starts on the click (avatar.mine_hint), as in Factorio, not once the bridge's
	# first mining progress has come back a round trip and a tick or two later.
	var at := avatar.mining_for_sound()
	if at.x == INF:
		_mine_timer = 0.0  # the first swing's sound plays the frame the button goes down
		_mine_target = Vector2(INF, INF)
		_last_mining_progress = -1
		return
	_last_mining_msec = Time.get_ticks_msec()
	_last_mining_at = at
	# The bridge's place and the click's differ by a little (an entity's position, the mouse's):
	# the same target, no new first swing.
	if at.distance_to(_mine_target) > 0.6:
		_mine_target = at
		_mine_kind = _mining_kind(at)
		_mine_sound = _mining_sound(at)
	# A resource is mined over and over: each time the bar comes round, an item came out.
	if avatar.mining >= 0:
		if _mine_kind == "ore" and _last_mining_progress > avatar.mining + 30:
			sfx.play_at(SoundBank.pick("core/sound/picked-up-item"), avatar.position, 0.35, 0.05, 1.0, "Effects", "pickup", true)
		_last_mining_progress = avatar.mining
	_mine_timer -= delta
	if _mine_timer > 0.0:
		return
	if _mine_sound == "":
		return  # M1: a building without a mining_sound of its own: no swing sound, no sparks
	var sound := _pick_ready(_mine_sound)
	if sound == "":
		return  # not decoded yet: try again next frame rather than lose the first swing
	_mine_timer = MINE_INTERVAL
	var target := Vector3(at.x, 0.0, at.y)
	var toward := (avatar.position - target)
	toward.y = 0.0
	var hit := target + toward.normalized() * minf(0.5, toward.length()) + Vector3(0, 0.45, 0)
	sfx.play_at(sound, hit, 0.6, 0.06, 1.0, "Effects", "mine/" + _mine_detail(_mine_sound), true)
	if not FxSettings.effects_enabled:
		return
	if _mine_kind == "wood":
		for i in 2:
			var c := sprites.emit("dust", hit + Vector3(randf_range(-0.2, 0.2), randf_range(0.0, 0.4), randf_range(-0.2, 0.2)), 0.3, 0.6, Color(0.45, 0.33, 0.18, 0.5))
			if c != null:
				c.size1 = 0.6
				c.vel = Vector3(randf_range(-0.5, 0.5), 0.6, randf_range(-0.5, 0.5))
	else:
		var s := sprites.emit("sparks", hit, 0.5, 0.35)
		if s != null:
			s.spin = randf() * TAU
		var c := sprites.emit("dust", hit, 0.35, 0.6, Color(0.5, 0.45, 0.4, 0.35))
		if c != null:
			c.size1 = 0.8
			c.vel = Vector3(0, 0.4, 0)


## `eprops`' entities' own mining sounds (`key` "ms"), or repair sounds ("rsd"): prototype id -> sound
## (its variations' prefix).
static func mining_sounds_of(msg: Dictionary, key := "ms") -> Dictionary:
	var out := {}
	var list = msg.get("l")
	if not (list is Array):
		return out
	for rec in list:
		if rec is Array and rec.size() >= 5 and rec[4] is Dictionary and str(rec[4].get(key, "")) != "":
			out[int(rec[0])] = str(rec[4][key])
	return out


## K13: while the character repairs (`me` `rp`), the mended thing's repair sound at it, one after another.
func _update_repair(delta: float) -> void:
	if not avatar.repairing:
		_repair_timer = 0.0  # the next repair's sound starts at once
		return
	_repair_timer -= delta
	if _repair_timer > 0.0:
		return
	var prefix := repair_sound_for(_repair_proto(avatar.repair_at), _repair_sounds)
	var sound := _pick_ready(prefix)
	if sound == "":
		return  # not decoded yet: next frame
	var stream := SoundBank.stream_soon(sound)
	_repair_timer = maxf(0.2, stream.get_length() if stream != null else 1.0)
	var at := avatar.repair_at
	sfx.play_at(sound, Vector3(at.x, 0.5, at.y), 0.6 if prefix == REPAIR_SOUND else 0.3, 0.04, 1.0, "Effects", "repair")


func _repair_proto(at: Vector2) -> ProtoDB.EntityProto:
	# N4: a vehicle or wagon being mended, not the rail or ground under it.
	if movers != null:
		var id := movers.proto_near(Vector2i(roundi(at.x * 256.0), roundi(at.y * 256.0)), REPAIRED_MOVERS)
		if id != 0:
			return world.protos.entity(id)
	var r := world.pick(at)
	return world.protos.entity(r.proto_id) if r != null else null


## The repair sound for `proto` with the entities' own sounds `own`: its own where the player's install
## has the files, else Factorio's default_manual_repair.
static func repair_sound_for(proto: ProtoDB.EntityProto, own: Dictionary) -> String:
	var mine := str(own.get(proto.id, "")) if proto != null else ""
	if mine != "" and not SoundBank.variants(mine).is_empty():
		return mine
	return REPAIR_SOUND


## The swing's sound at `at`, as Factorio picks it (J11): the prototype's own mining_sound (rocks'
## stone, the stone patch's, Space Age's plants and ice), else trees' wood and the ore sound for ore,
## rocks and fish; a building's swing is silent (M1, ""). Nothing known there yet: the ore sound.
func _mining_sound(at: Vector2) -> String:
	var r := world.pick(at)
	var proto: ProtoDB.EntityProto = world.protos.entity(r.proto_id) if r != null else null
	if proto == null:
		return MINE_SOUNDS["ore"]
	return sound_for(proto, _mining_sounds)


## The swing's sound for `proto` with the entities' own sounds `own` (mining_sounds_of): its own
## where the player's install has the files, else Factorio's default for it (MINE_DEFAULTS), "" for
## none (a building).
static func sound_for(proto: ProtoDB.EntityProto, own: Dictionary) -> String:
	var mine := str(own.get(proto.id, ""))
	if mine != "" and not SoundBank.variants(mine).is_empty():
		return mine
	if not silent_buildings:
		return MINE_SOUNDS["wood"] if proto.type == "tree" else MINE_SOUNDS["ore"]
	var kind := str(MINE_DEFAULTS.get(proto.type, ""))
	return MINE_SOUNDS[kind] if kind != "" else ""


## The swing's kind's detail (api.sound): "wood" or "ore" for Zenith's defaults, else the own sound's name.
static func _mine_detail(prefix: String) -> String:
	for k: String in MINE_SOUNDS:
		if MINE_SOUNDS[k] == prefix:
			return k
	return prefix.get_file().get_basename()


## "wood" (trees), "stone" (rocks), "ore" (resources) or "other" (buildings): the swing's dust and sparks.
func _mining_kind(at: Vector2) -> String:
	var r := world.pick(at)
	var proto: ProtoDB.EntityProto = world.protos.entity(r.proto_id) if r != null else null
	if proto == null:
		return "other"
	match proto.type:
		"tree":
			return "wood"
		"simple-entity":
			return "stone"
		"resource":
			return "ore"
	return "other"


## A gun's sound for each round the bridge reports (`shot`; weapon_fx.gd draws the flash).
## Fulgora's strikes: the bolt and the prototype's sound (space-age's lightning-effect, which its
## definition makes heard from far off).
func _on_lightning(msg: Dictionary) -> void:
	var list = msg.get("l")
	if not (list is Array):
		return
	for r in list:
		if r is Array and r.size() >= 3:
			var at := Vector2(int(r[0]), int(r[1])) / 256.0
			lightning.strike(at, int(r[2]) == 1)
			sfx.play_at(SoundBank.pick("space-age/sound/explosions/lightning-effect"), Vector3(at.x, 1.0, at.y), 0.8, 0.1, 2.25)


func _on_shot(msg: Dictionary) -> void:
	var gun := str(msg.get("g", ""))
	var at := Vector3(avatar.position.x, CombatLayer.MUZZLE_HEIGHT, avatar.position.z)
	var own := int(msg.get("u", 0)) == avatar.unit
	if not own:
		var p = movers.position_of(int(msg.get("u", 0)))
		if p == null:
			return
		at = p
	if GUN_SOUNDS.has(gun):
		sfx.play_at(SoundBank.pick(GUN_SOUNDS[gun]), at, 0.55, 0.05, 1.0, "Weapons", "shot/" + gun, own)


## The flamethrower fires every tick, so no `shot` comes: its sound plays while the character
## fires it (its streams are drawn from `pj`): flame_sound.gd's begin, loop and end from the gun,
## or with `--flame-sound=old` the middle sound again every 0.5 s.
func _update_shots(delta: float) -> void:
	if not avatar.firing or combat == null or combat.aim_mode < 0 or _gun != "flamethrower":
		_shot_clock = 0.0
		return
	if not FlameSound.old:
		flame_sound.firing("hand", avatar.muzzle_position(), "handheld")
		return
	var before := _shot_clock
	_shot_clock += delta
	var interval := 0.5
	if before > 0.0 and floori(before / interval) == floori(_shot_clock / interval):
		return
	sfx.play_at(SoundBank.pick(GUN_SOUNDS["flamethrower"]), avatar.position + Vector3(0, CombatLayer.MUZZLE_HEIGHT, 0), 0.55, 0.05, 1.0, "Weapons", "shot/flamethrower", true)


# --- Building, rotating, mining out ---------------------------------------------------------------

func _on_add(e) -> void:
	if not (e is Array) or e.size() < 5:
		return
	var proto: ProtoDB.EntityProto = world.protos.entity(int(e[1]))
	if proto == null or proto.type in ["resource", "tree", "simple-entity", "fish", "item-entity"]:
		return
	var pos := Vector2(int(e[2]), int(e[3])) / 256.0
	if pos.distance_to(avatar.ground_position()) > BUILD_RANGE:
		return
	var ghost: bool = e.size() > 5 and e[5] is Dictionary and e[5].has("gh")
	var size := _size_class(proto)
	var at := Vector3(pos.x, 0.3, pos.y)
	if ghost:
		sfx.play_at("core/sound/build-ghost-%s.ogg" % size, at, 0.5, 0.0, 1.0, "Effects", "build/ghost")
		return
	sfx.play_at("core/sound/build-%s.ogg" % size, at, 0.7, 0.04, 1.0, "Effects", "build/" + proto.name)
	if FxSettings.effects_enabled:
		var s := proto.size()
		for i in clampi(int(s.x * s.y), 2, 8):
			var c := sprites.emit("dust", at + Vector3(randf_range(-0.5, 0.5) * s.x, 0.0, randf_range(-0.5, 0.5) * s.y), 0.6, 0.8, Color(0.55, 0.5, 0.42, 0.35))
			if c != null:
				c.size1 = 1.2
				c.vel = Vector3(randf_range(-0.4, 0.4), 0.3, randf_range(-0.4, 0.4))


func _on_upd(e) -> void:
	if not (e is Array) or e.size() < 5:
		return
	var unit := int(e[0])
	var key = unit if unit > 0 else WorldMirror.static_key(int(e[1]), int(e[2]), int(e[3]))
	var old: WorldMirror.Rec = world.entities.get(key)
	if old == null or old.proto_id != int(e[1]) or old.dir == int(e[4]):
		return
	if old.pos.distance_to(avatar.ground_position()) > BUILD_RANGE:
		return
	var proto: ProtoDB.EntityProto = world.protos.entity(old.proto_id)
	var size := _size_class(proto) if proto != null else "small"
	sfx.play_at("core/sound/rotate-%s.ogg" % ("big" if size == "large" else size), Vector3(old.pos.x, 0.3, old.pos.y), 0.6, 0.0, 1.0, "Effects", "rotate/" + (proto.name if proto != null else ""))


## The thing the character was mining is gone: Factorio's sound for having mined it.
func _on_del(msg: Dictionary) -> void:
	if Time.get_ticks_msec() - _last_mining_msec > 1500:
		return
	var unit := int(msg.get("u", 0))
	var key = unit if unit > 0 else WorldMirror.static_key(int(msg.get("p", 0)), int(msg.get("x", 0)), int(msg.get("y", 0)))
	var r: WorldMirror.Rec = world.entities.get(key)
	if r == null:
		return
	var proto: ProtoDB.EntityProto = world.protos.entity(r.proto_id)
	if proto == null:
		return
	if not WorldMirror.selection_rect(proto, r.pos, r.dir).grow(0.6).has_point(_last_mining_at):
		return
	var at := Vector3(r.pos.x, 0.4, r.pos.y)
	var kind := "mined/" + proto.name
	match proto.type:
		"tree":
			sfx.play_at(SoundBank.pick("core/sound/mining-wood"), at, 0.8, 0.0, 1.0, "Effects", kind)
		"simple-entity":
			sfx.play_at("core/sound/deconstruct-bricks.ogg", at, 0.7, 0.0, 1.0, "Effects", kind)
		_:
			sfx.play_at("core/sound/deconstruct-%s.ogg" % _size_class(proto), at, 0.7, 0.0, 1.0, "Effects", kind)
	if FxSettings.effects_enabled:
		for i in 4:
			var c := sprites.emit("dust", at + Vector3(randf_range(-0.4, 0.4), randf_range(0.0, 0.6), randf_range(-0.4, 0.4)), 0.6, 0.8, Color(0.5, 0.46, 0.4, 0.4))
			if c != null:
				c.size1 = 1.2
				c.vel = Vector3(randf_range(-0.5, 0.5), 0.5, randf_range(-0.5, 0.5))


static func _size_class(proto: ProtoDB.EntityProto) -> String:
	var s := maxi(proto.tile_size.x, proto.tile_size.y)
	return "small" if s <= 1 else ("medium" if s <= 3 else "large")


# --- Deaths -------------------------------------------------------------------------------------

## Every combat sound decoded ahead, on the first combat message (sfx.gd skips a file's first play
## while it decodes, and a fight's explosions are few and varied, so many first ones were silent).
## `--sound-pool=old`: not done.
func _warm_combat() -> void:
	if _combat_warmed or not Sfx.pool:
		return
	_combat_warmed = true
	var files: Array = []
	for prefix in GUN_SOUNDS.values():
		files.append_array(SoundBank.variants(prefix))
	for prefix in ["base/sound/fight/gun-turret-gunshot", "base/sound/fight/heavy-gunshot", "base/sound/fight/laser-beam",
			"base/sound/fight/tank-cannon", "base/sound/fight/rocket-launcher", "base/sound/fight/artillery-shoots",
			"space-age/sound/ammo/rocket-turret-launcher", "base/sound/creatures/biter-death", "base/sound/creatures/biter-death-big",
			"base/sound/creatures/spitter-death", "base/sound/creatures/spitter-death-mid", "base/sound/creatures/spitter-death-big",
			"base/sound/creatures/worm-death-small", "base/sound/creatures/worm-death", "base/sound/creatures/worm-death-big",
			"base/sound/creatures/spawner-death", "base/sound/fight/car-explosion", "base/sound/fight/large-explosion",
			"base/sound/fight/medium-explosion", "base/sound/small-explosion"]:
		files.append_array(SoundBank.variants(prefix))
	files.append_array(weapons.explosion_sound_files())
	CombatSounds.warm(files)


func _on_attack(msg: Dictionary) -> void:
	var proto: ProtoDB.EntityProto = world.protos.entity(int(msg.get("p", 0))) if world != null and world.protos != null else null
	if proto != null:
		combat_sounds.attack(proto.name, Vector3(int(msg.get("x", 0)) / 256.0, 0.6, int(msg.get("y", 0)) / 256.0))


func _on_died(msg: Dictionary) -> void:
	var proto: ProtoDB.EntityProto = world.protos.entity(int(msg.get("p", 0)))
	var pos := Vector2(int(msg.get("x", 0)), int(msg.get("y", 0))) / 256.0
	var at := Vector3(pos.x, 0.0, pos.y)
	if proto == null:
		return
	if proto.type == "character" and avatar != null and int(msg.get("u", 0)) == avatar.unit and avatar.unit != 0:
		combat_sounds.character_died()
	var death := enemy_death_prefix(proto)
	if not Sfx.combat_limits:
		death = ""
		if ENEMY_TYPES.has(proto.type):
			var old_big := "big" in proto.name or "behemoth" in proto.name
			death = "base/sound/creatures/biter-death-big" if old_big else "base/sound/creatures/biter-death"
	if death != "":
		sfx.play_at(SoundBank.pick(death), at, 0.6, 0.06, 1.0, "Enemies")
	if ENEMY_TYPES.has(proto.type):
		if FxSettings.effects_enabled:
			for i in 3:
				var c := sprites.emit("dust", at + Vector3(randf_range(-0.3, 0.3), 0.3, randf_range(-0.3, 0.3)), 0.5, 0.7, Color(0.42, 0.3, 0.12, 0.6))
				if c != null:
					c.size1 = 1.0
					c.vel = Vector3(randf_range(-0.6, 0.6), 0.5, randf_range(-0.6, 0.6))
			# The corpse itself is creatures.gd's (the enemy's corpse model).
		return
	if proto.type in ["tree", "character", "resource", "fish"]:
		return
	var s := proto.size()
	var extent := maxf(s.x, s.y)
	var kind := "explosion/" + proto.name
	# The entity's dying explosion carries its own sound (142 of the 185 prototypes' do), so the generic
	# one by size is only for what has none; worms and nests have their death sound above and no explosion.
	var dying := weapons.dying_explosion(proto.name)
	var own_sound: bool = Sfx.combat_limits and (death != "" or (FxSettings.effects_enabled and weapons.explosion_has_sound(dying)))
	if own_sound:
		pass
	elif proto.type == "car":
		sfx.play_at(SoundBank.pick("base/sound/fight/car-explosion"), at, 0.8, 0.0, 1.0, "Explosions", kind)
	elif extent >= 4.0:
		sfx.play_at(SoundBank.pick("base/sound/fight/large-explosion"), at, 0.8, 0.0, 1.0, "Explosions", kind)
	elif extent >= 1.5:
		sfx.play_at(SoundBank.pick("base/sound/fight/medium-explosion"), at, 0.8, 0.0, 1.0, "Explosions", kind)
	else:
		sfx.play_at(SoundBank.pick("base/sound/small-explosion"), at, 0.8, 0.0, 1.0, "Explosions", kind)
	if not FxSettings.effects_enabled:
		return
	# The entity's own dying explosion, as Factorio plays it.
	if dying != "":
		weapons.explode(dying, at)
		return
	var sheet := "explosion" if extent >= 1.5 else "small-explosion"
	var width := clampf(extent * 0.9, 1.4, 5.0)
	var aspect := 224.0 / 124.0 if sheet == "explosion" else 178.0 / 88.0
	sprites.emit(sheet, at + Vector3(0, width * aspect * 0.45, 0), width, 1.0 if sheet == "explosion" else 0.8)
	# No marks on a space platform (the owner's #16): there is no ground to burn.
	var scorch: SpriteFx.Card = null if weapons.in_space else sprites.emit("scorch", at + Vector3(0, 0.03, 0), extent + 1.2, REMNANT_SECONDS)
	if scorch != null:
		scorch.frame = randi() % sprites.frame_count("scorch")
		scorch.angle = randf() * TAU
	# What is left of it is a remnants entity in the game, streamed and drawn with the world
	# (ModelLibrary.remnant_mesh).


func status() -> String:
	return "sound %d loops %d one-shots · %d effect cards · %d smoke sources · %s" % [sfx.busy_loops(), sfx.busy_shots(), sprites.count(), _emitters.size(), weapons.status()]
