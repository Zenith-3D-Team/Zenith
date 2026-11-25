extends SceneTree
## Verifies budgeted combat & turret light shadows (combat_lights.gd, weapon_fx.gd, turrets.gd),
## positional shadow atlas prerequisites, muzzle offset clear of the barrel, night-time chunk
## shadow casters, and vehicle cast_shadow defaults.
##
## Run headless:
##   godot --headless --audio-driver Dummy --path client -s res://tests/combat_shadows_test.gd

const TestEnv := preload("res://tests/test_env.gd")
const CombatLights := preload("res://scripts/fx/combat_lights.gd")
const WeaponFx := preload("res://scripts/fx/weapon_fx.gd")
const SpriteFx := preload("res://scripts/fx/sprite_fx.gd")
const TurretLayer := preload("res://scripts/world/turrets.gd")
const ChunkView := preload("res://scripts/world/chunk_view.gd")
const MoverLayer := preload("res://scripts/world/movers.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")
const Avatar := preload("res://scripts/player/avatar.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const Switches := preload("res://scripts/switches.gd")

var _fails := 0


class MockAvatar extends Avatar:
	var muzzle := Vector3(1.0, 1.2, 2.0)

	func _ready() -> void:
		_lantern.free()
		_flashlight.free()

	func muzzle_position() -> Vector3:
		return muzzle


func _check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		_fails += 1


func _initialize() -> void:
	TestEnv.isolate("combat-shadows-test")
	_run.call_deferred()


func _count_shadow_lights(wf: WeaponFx, turrets: TurretLayer) -> int:
	var n := 0
	for l: OmniLight3D in wf._lights:
		if l.visible and l.shadow_enabled:
			n += 1
	for st in turrets._states.values():
		if st.light != null and st.light.visible and st.light.shadow_enabled:
			n += 1
		if st.flame_light != null and st.flame_light.visible and st.flame_light.shadow_enabled:
			n += 1
	return n


func _run() -> void:
	var orig_shadows_enabled := CombatLights.shadows_enabled
	var orig_strength := CombatLights.strength
	var orig_old := CombatLights.old
	CombatLights.old = false
	CombatLights.strength = 1.0
	CombatLights.shadows_enabled = true
	Settings.hold("graphics", {"shadows": "high"})

	# 1. Positional shadow atlas prerequisites on Forward+ viewport
	var atlas_setting := int(ProjectSettings.get_setting("rendering/lights_and_shadows/positional_shadow/atlas_size"))
	var vp_atlas := root.positional_shadow_atlas_size
	var q0 := root.get_positional_shadow_atlas_quadrant_subdiv(0)
	var q1 := root.get_positional_shadow_atlas_quadrant_subdiv(1)
	var q2 := root.get_positional_shadow_atlas_quadrant_subdiv(2)
	_check(atlas_setting >= 2048 and vp_atlas >= 2048 and q0 >= 1 and q1 >= 2 and q2 >= 3,
		"positional shadow atlas enabled and sized for dual-paraboloid omni lights (setting=%d vp=%d q=%d/%d/%d)" % [atlas_setting, vp_atlas, q0, q1, q2])

	# 2. Default switch & --combat-shadows=off behaviour
	_check(orig_shadows_enabled == true, "CombatLights.shadows_enabled defaults to true")
	Switches.set_test_args(PackedStringArray(["--combat-shadows=off"]))
	_check(not Switches.on("--combat-shadows"), "--combat-shadows=off disables combat shadows switch")
	Switches.set_test_args(PackedStringArray())
	_check(Switches.on("--combat-shadows"), "Switches.on('--combat-shadows') defaults to true when absent")
	Switches.reset_cache()

	# 3. Budgeted shadows across weapon_fx.gd + turrets.gd under 20+ active flashes
	var holder := Node3D.new()
	root.add_child(holder)
	var cam := Camera3D.new()
	holder.add_child(cam)
	cam.current = true
	cam.global_position = Vector3(0.0, 18.0, 12.0)
	cam.look_at(Vector3.ZERO, Vector3.UP)

	var sprites := SpriteFx.new()
	holder.add_child(sprites)
	var wf := WeaponFx.new()
	wf.sprites = sprites
	holder.add_child(wf)
	var turrets := TurretLayer.new()
	holder.add_child(turrets)

	# 14 turret flashes (close and far) + 12 weapon_fx flashes (close and far) = 26 active lights
	for i in 14:
		var st = turrets._state(1000 + i)
		st.cfg = TurretLayer.TURRETS["gun-turret"]
		st.muzzle = Vector3(float(i) * 4.0, 1.2, 0.0)
		st.forward = Vector3.FORWARD
		turrets._flash(st, Color(1.0, 0.75, 0.35), 2.5 if i < 3 else 1.5)
	for i in 12:
		wf._muzzle_light(2000 + i, Vector3(float(i) * 5.0 + 1.0, 1.1, 2.0), {"k": "projectile"})

	turrets._process(1.0 / 60.0)
	wf._update_lights(1.0 / 60.0)

	var active_shadows := _count_shadow_lights(wf, turrets)
	_check(active_shadows == CombatLights.MAX_SHADOW_LIGHTS and active_shadows <= CombatLights.MAX_SHADOW_LIGHTS,
		"combined shadowed lights capped at MAX_SHADOW_LIGHTS (%d / %d) under 26 active flashes" % [active_shadows, CombatLights.MAX_SHADOW_LIGHTS])

	# Verify dual-paraboloid mode, tuned bias, and caster mask on shadowed lights
	var mode_ok := true
	var bias_ok := true
	var mask_ok := true
	var checked_shadowed := 0
	var all_lights: Array[OmniLight3D] = []
	for l: OmniLight3D in wf._lights:
		if l.visible:
			all_lights.append(l)
	for st in turrets._states.values():
		if st.light != null and st.light.visible:
			all_lights.append(st.light)
	for l: OmniLight3D in all_lights:
		if l.shadow_enabled:
			checked_shadowed += 1
			if l.omni_shadow_mode != OmniLight3D.SHADOW_DUAL_PARABOLOID:
				mode_ok = false
			if l.shadow_bias < 0.05 or l.shadow_normal_bias < 0.3:
				bias_ok = false
			if (l.shadow_caster_mask & 1) == 0 or (l.shadow_caster_mask & Visuals.GROUND_LAYER) != 0 or (l.shadow_caster_mask & ItemCards.BELT_LAYER) != 0:
				mask_ok = false
	_check(checked_shadowed == CombatLights.MAX_SHADOW_LIGHTS and mode_ok and bias_ok and mask_ok,
		"shadowed lights use DUAL_PARABOLOID, tuned biases, and layer-1 mask excluding ground/belts: mode=%s bias=%s mask=%s" % [mode_ok, bias_ok, mask_ok])

	# Closest bright turret (#0 at x=0) should beat distant turret (#13 at x=52)
	var st_near = turrets.state_of(1000)
	var st_far = turrets.state_of(1013)
	_check(st_near.light.shadow_enabled and not st_far.light.shadow_enabled,
		"priority gives shadow slot to near prominent flash over distant flash")

	# 4. --combat-shadows=off & global Shadows = "off" disable all combat shadows
	CombatLights.shadows_enabled = false
	turrets._process(1.0 / 60.0)
	wf._update_lights(1.0 / 60.0)
	_check(_count_shadow_lights(wf, turrets) == 0, "CombatLights.shadows_enabled=false disables all combat shadows")

	CombatLights.shadows_enabled = true
	Settings.hold("graphics", {"shadows": "off"})
	turrets._process(1.0 / 60.0)
	wf._update_lights(1.0 / 60.0)
	_check(_count_shadow_lights(wf, turrets) == 0, "Settings Shadows='off' disables all combat shadows")

	Settings.hold("graphics", {"shadows": "high"})
	turrets._process(1.0 / 60.0)
	wf._update_lights(1.0 / 60.0)
	_check(_count_shadow_lights(wf, turrets) == CombatLights.MAX_SHADOW_LIGHTS,
		"re-enabling global Shadows restores budgeted combat shadows (%d)" % _count_shadow_lights(wf, turrets))

	# 5. Muzzle offset clear of barrel tip
	var st_offset: TurretLayer.TurretState = turrets._state(1500)
	st_offset.cfg = TurretLayer.TURRETS["gun-turret"]
	st_offset.muzzle = Vector3(10.0, 1.2, 10.0)
	st_offset.forward = Vector3(1.0, 0.0, 0.0)
	turrets._flash(st_offset, Color.WHITE, 2.0)
	turrets._update_effects(st_offset, 1.0 / 60.0)
	var expect_pos: Vector3 = st_offset.muzzle + st_offset.forward * TurretLayer.MUZZLE_LIGHT_OFFSET
	_check(st_offset.light.global_position.is_equal_approx(expect_pos),
		"turret muzzle light nudged +%.2f along st.forward (%s == %s)" % [TurretLayer.MUZZLE_LIGHT_OFFSET, st_offset.light.global_position, expect_pos])

	# WeaponFx shot muzzle offset for avatar
	var mock_av := MockAvatar.new()
	mock_av.unit = 555
	holder.add_child(mock_av)
	wf.avatar = mock_av
	wf._flashes.clear()
	wf._on_shot({"t": "shot", "u": mock_av.unit, "a": "firearm-magazine", "g": "submachine-gun", "x": 10 * 256, "y": 2 * 256})
	var shot_pos: Vector3 = wf._flashes[0][0] if not wf._flashes.is_empty() else Vector3.ZERO
	_check(not wf._flashes.is_empty() and shot_pos.distance_to(mock_av.muzzle) >= 0.29,
		"weapon_fx avatar shot light positioned clear of gun tip (dist=%.2f)" % shot_pos.distance_to(mock_av.muzzle))

	# 6. Night-time chunk/wall shadow caster verification
	var WorldScript: Script = load("res://scripts/world/world.gd")
	var w = WorldScript.new()
	holder.add_child(w)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40.0, -30.0, 0.0)
	sun.directional_shadow_max_distance = 120.0
	sun.light_energy = 0.12  # night
	sun.shadow_enabled = true
	holder.add_child(sun)
	w.sun = sun
	w.shadow_usec = 1 << 40
	var cv := ChunkView.new()
	cv.coord = Vector2i.ZERO
	var wall_mmi := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.mesh = Visuals.box_mesh()
	wall_mmi.multimesh = mm
	cv._instances.append(wall_mmi)
	cv.add_child(wall_mmi)
	w.chunks[Vector2i.ZERO] = cv
	w.add_child(cv)
	w._update_shadow_casters()
	_check(cv.shadow_tier == ChunkView.SHADOWS_NEAR and wall_mmi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
		"night-time chunk near camera stays SHADOWS_NEAR and keeps cast_shadow ON (tier=%d)" % cv.shadow_tier)
	# Even if sun is hidden or sun.shadow_enabled turns false, world.gd keeps near chunks casting
	sun.visible = false
	w._update_shadow_casters()
	_check(cv.shadow_tier == ChunkView.SHADOWS_NEAR and wall_mmi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
		"hidden sun fallback keeps chunk SHADOWS_NEAR and wall cast_shadow ON")

	# 7. Vehicle cast_shadow default in movers.gd
	var ml := MoverLayer.new()
	holder.add_child(ml)
	var car_proto := ProtoDB.EntityProto.new()
	car_proto.name = "car"
	car_proto.type = "car"
	car_proto.box_min = Vector2(-0.7, -1.0)
	car_proto.box_max = Vector2(0.7, 1.0)
	var car_node := ml._make_node(car_proto)
	var car_casts := true
	for child in car_node.get_children():
		var mi := child as MeshInstance3D
		if mi != null and mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			car_casts = false
	car_node.free()
	_check(car_casts, "vehicle (car) meshes keep cast_shadow enabled")

	# Cleanup
	wf.reset()
	turrets.reset()
	CombatLights.reset_shadows()
	CombatLights.shadows_enabled = orig_shadows_enabled
	CombatLights.strength = orig_strength
	CombatLights.old = orig_old
	Settings.release("graphics")
	holder.queue_free()
	await process_frame

	print("COMBAT SHADOWS FAILS: %d" % _fails)
	TestEnv.clean()
	quit(1 if _fails > 0 else 0)
