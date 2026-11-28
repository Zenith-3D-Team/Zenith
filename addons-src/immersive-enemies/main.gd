extends Node
## Immersive Enemies add-on entry point (API 1.9).
## Phase 1: Physics-driven biter, spitter, worm & nest ragdolls with 6-leg/12-leg damped-spring
##          posing, slope tumbling, building/wall collisions, explosive body splitting, burning
##          corpses that char to ash, and resting corpses that decay cleanly.
## Phase 2: Pooled MultiMesh ichor droplets (and buoyant flames/smoke/ash), terrain-aligned
##          ground splatter & bounce smears, progressive wounds, and 3D bouncing chitin/gore gibs.
## Phase 3: Reworked biter & spitter animations with tier-weighted gait, smooth turn banking,
##          lunge pitch, sharper attack boosts, and directional hit-flinch jolts.

const BiterRagdoll := preload("scripts/biter_ragdoll.gd")
const BiterGore := preload("scripts/biter_gore.gd")
const BiterAnim := preload("scripts/biter_anim.gd")
const AcidGoo := preload("scripts/acid_goo.gd")

var api
var _root: Node3D
var _ragdoll
var _gore
var _anim
var _acid

var _ragdolls_on := true
var _gore_on := true
var _gibs_on := true
var _anim_on := true
var _acid_goo_on := true
var _reworked_biters_on := true
var _blood_amount := 1.0
var _applied_biter_pack := "__unset__"

## Burst spreading (0.1.2): when many enemies die in one frame (explosives into a horde), the first
## BURST_IMMEDIATE deaths of a frame are drawn at once, as before; the rest wait in a queue that is
## drained over the next frames within BURST_BUDGET_USEC, nearest and biggest first. A body showing
## 1-3 frames late is hidden by the explosion. Deep queues draw cheaper bodies (no split parts or
## detached legs, fewer gibs). Setting "spread_deaths" off or --enemies-burst=old = all at once.
const BURST_IMMEDIATE := 2
const BURST_BUDGET_USEC := 2000
const BURST_MIN_PER_FRAME := 2
const BURST_LITE_DEPTH := 10
## Hits: the first BURST_HITS_IMMEDIATE of a frame spray at once; the rest spray from the queue, or
## not at all when the creature dies in the same burst (its death spray covers it).
const BURST_HITS_IMMEDIATE := 8
var burst_spread := true
var _hit_queue: Array = []
var _hits_now := 0
var _burst_dead: Dictionary = {}
var _death_queue: Array = []
var _queue_sorted := true
var _claimed_pending := 0
var _deaths_now := 0

## Pre-cutting (0.1.2): the first split or lost leg of a tier cuts its parts out of the model (7-25 ms
## a piece, a few hundred ms for a horde's tiers in one frame). Tiers seen alive (biter_anim.gd) get
## theirs cut ahead on a worker thread.
var _warmed: Dictionary = {}
var _warm_check := 0

## Probe hook (tests/enemies_burst_probe.gd): when `profiling`, usec per part add up in `profile`.
var profiling := false
var profile: Dictionary = {}

var _cb_damaged: Callable = Callable()
var _cb_died: Callable = Callable()
var _cb_stream: Callable = Callable()
var _cb_ground: Callable = Callable()
var _cb_setting: Callable = Callable()
var _cb_started: Callable = Callable()
var _cb_ended: Callable = Callable()


func addon_start(a) -> void:
	api = a
	if api.get("level") == null or float(api.level) < 1.9 or api.get("creatures") == null:
		api.note("needs Zenith's add-on API 1.9 (api.creatures)")
		return

	_declare_settings()

	_root = Node3D.new()
	_root.name = "ImmersiveEnemiesRoot"
	_mount_parent().add_child(_root)

	_gore = BiterGore.new(api, _root)
	_ragdoll = BiterRagdoll.new(api, _root)
	_anim = BiterAnim.new(api)
	_acid = AcidGoo.new(api, _root)

	var on_bounce_fn := func(pos: Vector3, speed: float, scale: float, is_gleba := false) -> void:
		if _gore != null and _gore_on:
			_gore.spawn_smear(pos, speed, scale, is_gleba)
	_ragdoll.on_bounce = on_bounce_fn
	var on_gleba_puddle_fn := func(pos: Vector3, scale: float) -> void:
		if _gore != null and _gore_on:
			_gore.spawn_gleba_puddle(pos, scale)
	_ragdoll.on_gleba_puddle = on_gleba_puddle_fn
	var on_decay_dust_fn := func(pos: Vector3, scale: float) -> void:
		if _gore != null and _gore_on:
			_gore.spawn_decay_dust(pos, scale)
	_ragdoll.on_decay_dust = on_decay_dust_fn
	var on_burn_flame_fn := func(pos: Vector3, scale: float, ash_phase: float) -> void:
		if _gore != null:
			_gore.spawn_burn_flame(pos, scale, ash_phase)
	_ragdoll.on_burn_flame = on_burn_flame_fn

	_apply_settings(true)

	_cb_damaged = func(info: Dictionary) -> void:
		_on_damaged(info)
	api.creatures.damaged.connect(_cb_damaged)

	_cb_died = func(info: Dictionary) -> void:
		_on_died(info)
	api.creatures.died.connect(_cb_died)

	if api.creatures.has_signal("stream_event"):
		_cb_stream = func(info: Dictionary) -> void:
			if _acid != null:
				_acid.on_stream_event(info)
		api.creatures.stream_event.connect(_cb_stream)

	if api.creatures.has_signal("ground_fx"):
		_cb_ground = func(info: Dictionary) -> void:
			if _acid != null:
				_acid.on_ground_fx(info)
		api.creatures.ground_fx.connect(_cb_ground)

	_cb_setting = func(id: String, _v: Variant) -> void:
		_on_setting_changed(id)
	api.settings.changed.connect(_cb_setting)

	_cb_started = func() -> void:
		_on_game_started()
	api.game_started.connect(_cb_started)

	_cb_ended = func() -> void:
		_on_game_ended()
	api.game_ended.connect(_cb_ended)

	var on_options := func(box: VBoxContainer) -> void:
		var active_n: int = _ragdoll.active_count() if _ragdoll != null else 0
		var settled_n: int = _ragdoll.settled_count() if _ragdoll != null else 0
		box.add_child(api.ui.label("Enemy ragdolls: %d active, %d settled" % [active_n, settled_n]))
		var clear_fn := func() -> void:
			_clear_all()
			api.ui.message("Cleared enemy ragdolls and ichor decals.")
		box.add_child(api.ui.button("Clear ragdolls & blood", clear_fn))
	api.ui.set_options(on_options)

	if api.in_game():
		_on_game_started()


func addon_stop() -> void:
	if api != null:
		if api.get("creatures") != null:
			if _cb_damaged.is_valid() and api.creatures.damaged.is_connected(_cb_damaged):
				api.creatures.damaged.disconnect(_cb_damaged)
			if _cb_died.is_valid() and api.creatures.died.is_connected(_cb_died):
				api.creatures.died.disconnect(_cb_died)
			if _cb_stream.is_valid() and api.creatures.has_signal("stream_event") and api.creatures.stream_event.is_connected(_cb_stream):
				api.creatures.stream_event.disconnect(_cb_stream)
			if _cb_ground.is_valid() and api.creatures.has_signal("ground_fx") and api.creatures.ground_fx.is_connected(_cb_ground):
				api.creatures.ground_fx.disconnect(_cb_ground)
			api.creatures.set_anim_enabled(false)
			if api.creatures.has_method("set_pack_override"):
				api.creatures.set_pack_override("big-biter", "")
				api.creatures.set_pack_override("big-spitter", "")
				api.creatures.set_pack_override("biter-spawner", "")
		if api.get("settings") != null:
			if _cb_setting.is_valid() and api.settings.changed.is_connected(_cb_setting):
				api.settings.changed.disconnect(_cb_setting)
		if _cb_started.is_valid() and api.game_started.is_connected(_cb_started):
			api.game_started.disconnect(_cb_started)
		if _cb_ended.is_valid() and api.game_ended.is_connected(_cb_ended):
			api.game_ended.disconnect(_cb_ended)

	_applied_biter_pack = "__unset__"
	if _anim != null:
		_anim.dispose()
		_anim = null
	if _acid != null:
		_acid.dispose()
		_acid = null
	if _ragdoll != null:
		_ragdoll.dispose()
		_ragdoll = null
	if _gore != null:
		_gore.dispose()
		_gore = null
	if _root != null and is_instance_valid(_root):
		var parent: Node = _root.get_parent()
		if parent != null:
			parent.remove_child(_root)
		_root.queue_free()
	_root = null
	api = null


func _process(delta: float) -> void:
	if api == null or not api.in_game():
		return
	var dt: float = minf(delta, 0.05)
	_deaths_now = 0
	_hits_now = 0
	if not _death_queue.is_empty() or not _hit_queue.is_empty():
		_drain_deaths()
	elif burst_spread and _gibs_on:
		_warm_step()
	if profiling:
		var t0: int = Time.get_ticks_usec()
		if _ragdoll != null:
			_ragdoll.step(dt)
		var t1: int = Time.get_ticks_usec()
		if _gore != null:
			_gore.step(dt)
		var t2: int = Time.get_ticks_usec()
		if _acid != null:
			_acid.step(dt)
		var t3: int = Time.get_ticks_usec()
		if _anim != null and _anim_on:
			_anim.step(dt)
		var t4: int = Time.get_ticks_usec()
		_prof("step_ragdoll", t1 - t0)
		_prof("step_gore", t2 - t1)
		_prof("step_acid", t3 - t2)
		_prof("step_anim", t4 - t3)
		return
	if _ragdoll != null:
		_ragdoll.step(dt)
	if _gore != null:
		_gore.step(dt)
	if _acid != null:
		_acid.step(dt)
	if _anim != null and _anim_on:
		_anim.step(dt)


func _prof(key: String, usec: int) -> void:
	profile[key] = int(profile.get(key, 0)) + usec


func _is_supported(proto: String) -> bool:
	return (
		proto.ends_with("-biter")
		or proto.ends_with("-spitter")
		or proto.ends_with("-worm-turret")
		or proto == "biter-spawner"
		or proto == "spitter-spawner"
		or proto.contains("-wriggler-pentapod")
		or proto.ends_with("-strafer-pentapod")
		or proto.ends_with("-stomper-pentapod")
		or proto == "gleba-spawner"
		or proto == "gleba-spawner-small"
	)


func _on_damaged(info: Dictionary) -> void:
	var proto: String = str(info.get("name", ""))
	if not _is_supported(proto):
		return
	var t0: int = Time.get_ticks_usec() if profiling else 0
	if burst_spread and _hits_now >= BURST_HITS_IMMEDIATE:
		if _ragdoll != null:
			_ragdoll.on_damaged(info)
		if _anim != null and _anim_on:
			_anim.on_damaged(info)
		if _gore != null and _gore_on:
			_hit_queue.append(info.duplicate())
	else:
		_damaged_now(info)
	_hits_now += 1
	if profiling:
		_prof("damaged", Time.get_ticks_usec() - t0)


func _damaged_now(info: Dictionary) -> void:
	var t0: int = Time.get_ticks_usec() if profiling else 0
	if _ragdoll != null:
		_ragdoll.on_damaged(info)
	var t1: int = Time.get_ticks_usec() if profiling else 0
	if _gore != null and _gore_on:
		_gore.on_damaged(info)
	var t2: int = Time.get_ticks_usec() if profiling else 0
	if _anim != null and _anim_on:
		_anim.on_damaged(info)
	if profiling:
		_prof("damaged_ragdoll", t1 - t0)
		_prof("damaged_gore", t2 - t1)
		_prof("damaged_anim", Time.get_ticks_usec() - t2)


func _on_died(info: Dictionary) -> void:
	var proto: String = str(info.get("name", ""))
	if not _is_supported(proto):
		return
	if not burst_spread or (_deaths_now < BURST_IMMEDIATE and _death_queue.is_empty()):
		if not _hit_queue.is_empty():
			_burst_dead[int(info.get("unit", 0))] = true
		_deaths_now += 1
		_die_now(info)
		return
	# A burst: claim the body now (so Zenith's own collapse and corpse stay away), draw it later.
	var entry: Dictionary = info.duplicate()
	entry["claimed"] = false
	if _ragdoll != null and _ragdolls_on and _ragdoll.can_take(proto, _claimed_pending):
		info["handled"] = true
		entry["claimed"] = true
		_claimed_pending += 1
	if _anim != null:
		_anim.on_died(int(info.get("unit", 0)))
	_burst_dead[int(info.get("unit", 0))] = true
	_death_queue.append(entry)
	_queue_sorted = false


## The same work for one death as before 0.1.2 (gore, ragdoll, animation), all at once.
func _die_now(info: Dictionary) -> void:
	var t0: int = Time.get_ticks_usec() if profiling else 0
	if _gore != null and _gore_on:
		_gore.on_died(info)
	var t1: int = Time.get_ticks_usec() if profiling else 0
	if _ragdoll != null:
		if _ragdolls_on:
			var took_over: bool = bool(_ragdoll.spawn(info))
			if took_over:
				info["handled"] = true
		else:
			_ragdoll.clear_wound(int(info.get("unit", 0)))
	var t2: int = Time.get_ticks_usec() if profiling else 0
	if _anim != null:
		_anim.on_died(int(info.get("unit", 0)))
	if profiling:
		_prof("gore", t1 - t0)
		_prof("ragdoll", t2 - t1)
		_prof("deaths", 1)


## Draws queued deaths: nearest and biggest first, at least BURST_MIN_PER_FRAME a frame, then until
## BURST_BUDGET_USEC is spent. Entries still waiting with a deep queue get cheap ("lite") bodies.
func _drain_deaths() -> void:
	if not _queue_sorted:
		_sort_queue()
	var t_start: int = Time.get_ticks_usec()
	var done := 0
	while not _hit_queue.is_empty():
		if done >= BURST_MIN_PER_FRAME and Time.get_ticks_usec() - t_start >= BURST_BUDGET_USEC:
			break
		var hit: Dictionary = _hit_queue.pop_front() as Dictionary
		if _burst_dead.has(int(hit.get("unit", 0))):
			continue
		if _gore != null and _gore_on:
			_gore.on_damaged(hit)
		done += 1
	done = 0
	while not _death_queue.is_empty():
		if done >= BURST_MIN_PER_FRAME and Time.get_ticks_usec() - t_start >= BURST_BUDGET_USEC:
			break
		var entry: Dictionary = _death_queue.pop_front() as Dictionary
		var claimed: bool = bool(entry.get("claimed", false))
		if claimed:
			_claimed_pending = maxi(0, _claimed_pending - 1)
		entry["lite"] = _death_queue.size() >= BURST_LITE_DEPTH
		_die_queued(entry, claimed)
		done += 1
	if _death_queue.is_empty() and _hit_queue.is_empty():
		_burst_dead.clear()
	if profiling:
		_prof("drain", Time.get_ticks_usec() - t_start)


func _die_queued(entry: Dictionary, claimed: bool) -> void:
	var t0: int = Time.get_ticks_usec() if profiling else 0
	if _gore != null and _gore_on:
		_gore.on_died(entry)
	var t1: int = Time.get_ticks_usec() if profiling else 0
	if _ragdoll != null:
		if claimed and _ragdolls_on:
			_ragdoll.spawn(entry)
		else:
			_ragdoll.clear_wound(int(entry.get("unit", 0)))
	if profiling:
		_prof("gore", t1 - t0)
		_prof("ragdoll", Time.get_ticks_usec() - t1)
		_prof("deaths", 1)


## Every 10 frames: asks Zenith to cut the legs and parts of one tier seen alive on a worker
## thread (api.creatures.precut, Zenith 0.3.0+; older Zenith: nothing, cut at the first split). One
## call a time: starting a tier's job, or turning its finished cuts into meshes (~2 ms).
func _warm_step() -> void:
	_warm_check += 1
	if _warm_check < 10 or _anim == null or _ragdoll == null:
		return
	_warm_check = 0
	if api == null or api.get("creatures") == null or not api.creatures.has_method("precut"):
		return
	var t0: int = Time.get_ticks_usec() if profiling else 0
	for p in _anim.seen_protos:
		var proto: String = str(p)
		if _warmed.has(proto):
			continue
		if bool(api.creatures.precut(proto, int(_ragdoll._limb_count_for(proto)))):
			_warmed[proto] = true
		break
	if profiling:
		_prof("warm", Time.get_ticks_usec() - t0)


func _sort_queue() -> void:
	_queue_sorted = true
	var focus := Vector2.ZERO
	var has_focus := false
	if api != null and api.get("world") != null and api.world.has_method("focus"):
		var f: Variant = api.world.focus()
		if f is Vector2:
			focus = f as Vector2
			has_focus = true
	for e in _death_queue:
		var ed: Dictionary = e as Dictionary
		var p: Vector3 = ed.get("pos", Vector3.ZERO) as Vector3
		var d2: float = (Vector2(p.x, p.z) - focus).length_squared() if has_focus else 0.0
		var sc: float = maxf(float(ed.get("scale", 1.0)), 0.2)
		ed["_prio"] = d2 / (sc * sc)
	var by_prio := func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["_prio"]) < float(b["_prio"])
	_death_queue.sort_custom(by_prio)


func _on_game_started() -> void:
	_warmed.clear()
	_clear_all()
	_apply_settings(true)


func _on_game_ended() -> void:
	_clear_all()


func _clear_all() -> void:
	_death_queue.clear()
	_hit_queue.clear()
	_burst_dead.clear()
	_hits_now = 0
	_claimed_pending = 0
	_deaths_now = 0
	if _ragdoll != null:
		_ragdoll.clear()
	if _gore != null:
		_gore.clear()
	if _acid != null:
		_acid.clear()
	if _anim != null:
		_anim.clear()


func _on_setting_changed(id: String) -> void:
	_apply_settings(id == "use_reworked_biters")
	if id == "use_reworked_biters":
		_warmed.clear()
	if id == "ragdolls" and not _ragdolls_on and _ragdoll != null:
		_ragdoll.clear()
	elif id == "gore" and not _gore_on and _gore != null:
		_gore.clear()
	elif id == "acid_goo" and not _acid_goo_on and _acid != null:
		_acid.clear()
	elif id == "blood_amount" and _blood_amount <= 0.001 and _gore != null:
		_gore.clear()


func _apply_settings(force_pack := false) -> void:
	if api == null or api.get("settings") == null:
		return
	_ragdolls_on = bool(api.settings.value("ragdolls"))
	_gore_on = bool(api.settings.value("gore"))
	_gibs_on = bool(api.settings.value("gibs"))
	_anim_on = bool(api.settings.value("animations"))
	_acid_goo_on = bool(api.settings.value("acid_goo"))
	_reworked_biters_on = bool(api.settings.value("use_reworked_biters"))
	_blood_amount = clampf(float(api.settings.value("blood_amount")), 0.0, 2.0)
	burst_spread = bool(api.settings.value("spread_deaths")) and not ("--enemies-burst=old" in OS.get_cmdline_user_args())

	var native_on: bool = bool(api.settings.value("use_native")) and not ("--enemies-native=off" in OS.get_cmdline_user_args())
	for sys in [_ragdoll, _gore, _acid, _anim]:
		if sys != null and "use_native" in sys:
			sys.use_native = native_on

	if _ragdoll != null:
		_ragdoll.force_mul = clampf(float(api.settings.value("ragdoll_force")), 0.5, 2.0)
		_ragdoll.max_active = clampi(int(api.settings.value("max_ragdolls")), 8, 64)
		_ragdoll.gibs_enabled = _gibs_on
		_ragdoll.set_gore_enabled(_gore_on)
		_ragdoll.set_blood_amount(_blood_amount)
	if _gore != null:
		_gore.batch_decals = burst_spread
		_gore.gore_enabled = _gore_on
		_gore.gibs_enabled = _gibs_on
		_gore.gore_level = str(api.settings.value("gore_level"))
		_gore.blood_amount = _blood_amount
	if _acid != null:
		_acid.enabled = _acid_goo_on
	if _anim != null:
		_anim.set_enabled(_anim_on)

	var want_pack: String = "builtin:placeholders" if _reworked_biters_on else ""
	if (force_pack or want_pack != _applied_biter_pack) and api.get("creatures") != null and api.creatures.has_method("set_pack_override"):
		api.creatures.set_pack_override("big-biter", want_pack)
		api.creatures.set_pack_override("big-spitter", want_pack)
		api.creatures.set_pack_override("biter-spawner", want_pack)
		_applied_biter_pack = want_pack


func _mount_parent() -> Node:
	if api != null and api.get("world") != null and api.world.has_method("node"):
		var world_node: Variant = api.world.node()
		if world_node is Node:
			return world_node as Node
	return self


func _declare_settings() -> void:
	var s = api.settings
	s.add("ragdolls", "bool", true, "Enemy ragdolls", {
		"section": "Ragdolls",
		"note": "Replace standard biter, spitter, worm, nest, and Gleba pentapod / egg-raft death collapses with 3D rigid-body ragdolls, spring/articulated legs, and burning-to-ash corpses.",
	})
	s.add("ragdoll_force", "number", 1.0, "Launch force", {
		"min": 0.5, "max": 2.0, "step": 0.05,
		"section": "Ragdolls",
		"note": "Multiplier on weapon launch impulse and tumble spin when an enemy dies.",
	})
	s.add("use_native", "bool", true, "Fast native simulation", {
		"section": "Ragdolls",
		"note": "Run the ragdolls', gore's, goo's and animations' per-frame work in Zenith's C++ library (same look). Off, or without the library (Linux, macOS, ARM64), uses the slower GDScript. --enemies-native=off turns it off from the command line.",
	})
	s.add("spread_deaths", "bool", true, "Spread death effects over frames", {
		"section": "Ragdolls",
		"note": "When many enemies die in the same frame (explosives into a horde), draw the first two at once and the rest over the next few frames, nearest and biggest first, with simpler bodies for a big crowd, so the game doesn't stutter. Off draws every death at once, as before (--enemies-burst=old).",
	})
	s.add("max_ragdolls", "number", 32, "Max active ragdolls", {
		"min": 8, "max": 64, "step": 1,
		"section": "Ragdolls",
		"note": "Maximum simultaneously simulated ragdolls (excess deaths fall back cleanly to Zenith's default corpse).",
	})

	s.add("gore", "bool", true, "Blood & splatter", {
		"section": "Blood & Gore",
		"note": "Directional ichor/hemolymph spray on hit/death for Nauvis & Gleba enemies, live & corpse wounds, ground splatter decals, and ragdoll bounce smears.",
	})
	s.add("gibs", "bool", true, "Explosive gibs", {
		"section": "Blood & Gore",
		"note": "Split biters, spitters, worms, nests, wrigglers, strafers, and egg rafts on explosive/overkill kills, detach legs/egg sacs by damage intensity, and spawn 3D bouncing chitin and gore shards.",
	})
	s.add("gore_level", "choice", "standard", "Gore level", {
		"choices": [["Low", "low"], ["Standard", "standard"], ["High", "high"]],
		"section": "Blood & Gore",
		"note": "Scales droplet, splatter, and gib counts.",
	})
	s.add("blood_amount", "number", 1.0, "Blood amount", {
		"min": 0.0, "max": 2.0, "step": 0.05,
		"section": "Blood & Gore",
		"note": "Scales blood coverage on enemies, ragdolls, puddles, droplets, and ground splatters (0 disables blood).",
	})

	s.add("acid_goo", "bool", true, "Slimy acid goo", {
		"section": "Acid & Fluids",
		"note": "Replace flat spitter, worm & stomper acid particles with 3D wobbling slime globs, splash crowns, and bubbling swamp-green ground pools.",
	})

	s.add("animations", "bool", true, "Reworked enemy animations", {
		"section": "Animations",
		"note": "Tier-weighted gait speed, turn banking, acceleration/lunge pitch, attack boost, and directional hit-flinch for biters, spitters, and Gleba wrigglers.",
	})

	s.add("use_reworked_biters", "bool", true, "Reworked enemy models", {
		"section": "Models",
		"note": "Use Zenith's reworked watertight Placeholders models for biters, spitters, worms, nests, and ragdolls.",
	})
