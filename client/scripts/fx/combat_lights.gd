extends RefCounted
## How strongly fights light their surroundings (weapon_fx.gd's pool of lights, turrets.gd's own
## per-shooter lights): muzzle flashes, explosions, flamethrower streams and the fires they leave.
## A look of ours, brighter than Factorio's own light at night (the owner, watching a night fight).
##
## Settings > Graphics "Combat light strength" (0 none, 1 the default, up to 2) scales them all;
## `--combat-lights=old` keeps the lights as they were before (only explosions whose prototype has a
## light, the 16 nearest the character, the turrets' older flashes), and the slider is then ignored.

const Switches := preload("res://scripts/switches.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")

static var old := Switches.has("--combat-lights=old")
## `--combat-shadows=off`: disable budgeted shadows on combat & turret lights (restores unshadowed lights).
static var shadows_enabled := Switches.on("--combat-shadows")
static var strength := 1.0

## Shared per-frame shadow budget across weapon_fx.gd and turrets.gd.
const MAX_SHADOW_LIGHTS := 6
## Tuned for dual-paraboloid omni shadows at ~8-14 tile range: avoids shadow acne and wall leaks.
const SHADOW_BIAS := 0.1
const SHADOW_NORMAL_BIAS := 0.6
## Cast shadows from layer 1 buildings/walls/vehicles/enemies, excluding ground and belt item cards.
const SHADOW_CASTER_MASK := 0xFFFFFFFF & ~(Visuals.GROUND_LAYER | ItemCards.BELT_LAYER)

static var _shadow_sources := {}  # source_id (int) -> Array of [OmniLight3D, score]
static var _shadow_active: Array[OmniLight3D] = []
static var _by_shadow_score := func(a: Array, b: Array) -> bool: return float(a[1]) < float(b[1])


## The setting (main.gd's apply).
static func set_strength(v: float) -> void:
	strength = clampf(v, 0.0, 2.0)


## How much brighter than 1 the new lights are drawn (1 with `--combat-lights=old`).
static func gain() -> float:
	return 1.0 if old else strength


## Whether global Shadows in Settings > Graphics are enabled.
static func global_shadows_enabled() -> bool:
	return Settings.shadow_size() > 0


## Whether combat light shadows should cast this frame.
static func shadows_active() -> bool:
	return not old and shadows_enabled and strength > 0.0 and global_shadows_enabled()


## Applies dual-paraboloid mode, tuned biases, and caster mask to a combat/turret OmniLight3D.
static func configure_light(light: OmniLight3D) -> void:
	light.omni_shadow_mode = OmniLight3D.SHADOW_DUAL_PARABOLOID
	light.shadow_bias = SHADOW_BIAS
	light.shadow_normal_bias = SHADOW_NORMAL_BIAS
	light.shadow_caster_mask = SHADOW_CASTER_MASK


## Prominence score matching weapon_fx.gd (`_by_score`): smaller wins shadow budget slots.
static func light_score(pos: Vector3, eye: Vector3, energy: float, reach: float) -> float:
	return pos.distance_to(eye) / (maxf(reach, 0.1) * sqrt(maxf(energy, 0.01)))


## Submits one system's active lights (`[[OmniLight3D, score], ...]`) and enforces MAX_SHADOW_LIGHTS across all sources.
static func submit_shadow_candidates(source_id: int, candidates: Array) -> void:
	if candidates.is_empty():
		_shadow_sources.erase(source_id)
	else:
		_shadow_sources[source_id] = candidates
	_assign_shadows()


## Drops a system's submitted shadow candidates (on reset or tree exit).
static func clear_shadow_source(source_id: int) -> void:
	if _shadow_sources.erase(source_id):
		_assign_shadows()


## Clears all tracked shadow sources and turns off shadows on any active lights.
static func reset_shadows() -> void:
	_shadow_sources.clear()
	for light: OmniLight3D in _shadow_active:
		if is_instance_valid(light):
			light.shadow_enabled = false
	_shadow_active.clear()


## Number of valid active combat lights currently casting shadows.
static func active_shadow_count() -> int:
	var n := 0
	for light: OmniLight3D in _shadow_active:
		if is_instance_valid(light) and light.visible and light.shadow_enabled:
			n += 1
	return n


static func _assign_shadows() -> void:
	if not shadows_active():
		for light: OmniLight3D in _shadow_active:
			if is_instance_valid(light):
				light.shadow_enabled = false
		_shadow_active.clear()
		for src: Array in _shadow_sources.values():
			for entry: Array in src:
				var light: OmniLight3D = entry[0]
				if is_instance_valid(light) and light.shadow_enabled:
					light.shadow_enabled = false
		return
	var all_candidates: Array = []
	for src_id in _shadow_sources.keys():
		var list: Array = _shadow_sources[src_id]
		var alive: Array = []
		for entry: Array in list:
			var light: OmniLight3D = entry[0]
			if is_instance_valid(light) and light.visible and light.light_energy > 0.01:
				alive.append(entry)
				all_candidates.append(entry)
			elif is_instance_valid(light) and light.shadow_enabled:
				light.shadow_enabled = false
		if alive.is_empty():
			_shadow_sources.erase(src_id)
		elif alive.size() != list.size():
			_shadow_sources[src_id] = alive
	if all_candidates.size() > MAX_SHADOW_LIGHTS:
		all_candidates.sort_custom(_by_shadow_score)
	var chosen := {}
	var next_active: Array[OmniLight3D] = []
	for entry: Array in all_candidates:
		var light: OmniLight3D = entry[0]
		var id := light.get_instance_id()
		if next_active.size() >= MAX_SHADOW_LIGHTS:
			if not chosen.has(id) and light.shadow_enabled:
				light.shadow_enabled = false
			continue
		if chosen.has(id):
			continue
		chosen[id] = true
		if light.omni_shadow_mode != OmniLight3D.SHADOW_DUAL_PARABOLOID or light.shadow_caster_mask != SHADOW_CASTER_MASK:
			configure_light(light)
		if not light.shadow_enabled:
			light.shadow_enabled = true
		next_active.append(light)
	for light: OmniLight3D in _shadow_active:
		if is_instance_valid(light) and not chosen.has(light.get_instance_id()) and light.shadow_enabled:
			light.shadow_enabled = false
	_shadow_active = next_active
