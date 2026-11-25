extends SceneTree
## Vehicle model subparts and enhanced car/tank animations (`vehicle_anim.gd`, `movers.gd`,
## `turrets.gd`, `vehicle_lights.gd`), including `--vehicle-anim=old` fallback:
##   godot --headless --audio-driver Dummy --path client -s res://tests/vehicle_anim_test.gd

const Avatar := preload("res://scripts/player/avatar.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const Movers := preload("res://scripts/world/movers.gd")
const VehicleAnim := preload("res://scripts/world/vehicle_anim.gd")
const VehicleLights := preload("res://scripts/world/vehicle_lights.gd")
const VehicleTracks := preload("res://scripts/fx/vehicle_tracks.gd")
const Turrets := preload("res://scripts/world/turrets.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const TestEnv := preload("res://tests/test_env.gd")

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _initialize() -> void:
	TestEnv.isolate("vehicle-anim-test")
	_run.call_deferred()


func _run() -> void:
	var MP = ModelLibrary.ModelPacks
	MP.configure(OS.get_user_data_dir().path_join("no-packs"), [], [])
	MP.wait()
	ModelLibrary.choices_changed([])
	for name: String in ["car", "tank", "car@builtin:placeholders", "tank@builtin:placeholders"]:
		var mesh := ModelLibrary.mesh_for(name)
		for _i in 1200:
			if mesh != null:
				break
			await process_frame
			mesh = ModelLibrary.mesh_for(name)
		check(mesh != null, "%s: loaded" % name)

	_check_parts()

	var holder := Node3D.new()
	root.add_child(holder)
	var protos := ProtoDB.new()
	protos.add_entities([
		[8, "car", "car", -0.7, -1.0, 0.7, 1.0, 1, 1, 1, 1, 1],
		[9, "tank", "car", -0.9, -1.3, 0.9, 1.3, 1, 1, 1, 2, 3],
	])
	var movers := Movers.new()
	movers.protos = protos
	holder.add_child(movers)
	var vehicles: VehicleAnim = movers.vehicles
	var turrets := Turrets.new()
	turrets.movers = movers
	holder.add_child(turrets)

	VehicleAnim.enhanced = true
	movers.handle({"t": "mv", "k": 1, "l": [[900, 8, 10 * 256, 10 * 256, 0], [901, 9, 20 * 256, 10 * 256, 0]]})
	movers._process(1.0 / 60.0)

	var car_node := movers.node_of(900)
	var tank_node := movers.node_of(901)
	check(car_node != null and tank_node != null, "car and tank mover nodes created and dressed")
	if car_node != null and tank_node != null:
		_check_tank_treads(vehicles, tank_node, 901)
		_check_car_physics(vehicles, car_node, 900)
		_check_tank_turret_and_recoil(vehicles, turrets, tank_node, 901)
		_check_lights_and_glow(movers, 901)
		_check_headlight_glare(movers, 900, 901)
		_check_headlight_storm()

	_check_old_flag(holder, movers, protos)
	_check_vehicle_tracks(holder)

	holder.free()
	print("vehicle_anim_test: %s" % ("PASS" if fails == 0 else "%d FAILED" % fails))
	quit(0 if fails == 0 else 1)


func _check_parts() -> void:
	var car_kinds := {}
	for p: ModelLibrary.AnimPart in ModelLibrary.parts_for("car@builtin:placeholders"):
		car_kinds[p.kind] = int(car_kinds.get(p.kind, 0)) + 1
	check(int(car_kinds.get("wheel_front", 0)) == 2 and int(car_kinds.get("wheel_rear", 0)) == 2
		and int(car_kinds.get("steer_front", 0)) == 2 and int(car_kinds.get("engine_fan", 0)) == 1
		and int(car_kinds.get("headlight", 0)) == 1 and int(car_kinds.get("turret_head", 0)) == 1
		and int(car_kinds.get("turret_barrel", 0)) == 1,
		"car parts: %s" % [car_kinds])

	var tank_kinds := {}
	var tread_l_part: ModelLibrary.AnimPart = null
	for p: ModelLibrary.AnimPart in ModelLibrary.parts_for("tank@builtin:placeholders"):
		tank_kinds[p.kind] = int(tank_kinds.get(p.kind, 0)) + 1
		if p.kind == "tread_l":
			tread_l_part = p
	check(int(tank_kinds.get("wheel_track", 0)) == 14 and int(tank_kinds.get("tread_l", 0)) == 1
		and int(tank_kinds.get("tread_r", 0)) == 1 and int(tank_kinds.get("headlight", 0)) == 1
		and int(tank_kinds.get("turret_head", 0)) == 1 and int(tank_kinds.get("turret_barrel", 0)) == 1
		and int(tank_kinds.get("turret_coax", 0)) == 1,
		"tank parts: %s" % [tank_kinds])

	var cleat := VehicleAnim.extract_top_cleat(tread_l_part)
	check(cleat != null and cleat.get_surface_count() >= 1,
		"tank extract_top_cleat builds non-empty ArrayMesh (%s surfaces)" % (cleat.get_surface_count() if cleat != null else 0))


func _check_tank_treads(vehicles: VehicleAnim, tank_node: Node3D, unit: int) -> void:
	var rig: VehicleAnim.Rig = vehicles._rigs.get(unit)
	check(rig != null and rig.track_l_mm != null and rig.track_r_mm != null, "tank rig attached with left & right track MultiMeshes")
	if rig == null or rig.track_l_mm == null or rig.track_r_mm == null:
		return
	check(rig.track_l_mm.multimesh.instance_count == VehicleAnim.TANK_CLEATS
		and rig.track_r_mm.multimesh.instance_count == VehicleAnim.TANK_CLEATS,
		"tank treads: %d cleats per side" % rig.track_l_mm.multimesh.instance_count)
	var static_hidden := true
	for key in ["tread_l", "tread_r"]:
		for pair in rig.parts.get(key, []):
			if (pair[0] as MeshInstance3D).visible:
				static_hidden = false
	check(static_hidden, "static tread_l/tread_r meshes hidden when enhanced closed-loop MultiMeshes active")
	var mm := rig.track_l_mm.multimesh
	var perim := VehicleAnim.track_perimeter()
	var top_seen := false
	var bot_seen := false
	for i in VehicleAnim.TANK_CLEATS:
		var y := VehicleAnim.track_sample(perim * float(i) / float(VehicleAnim.TANK_CLEATS)).y
		if y > 0.55:
			top_seen = true
		elif y < 0.15:
			bot_seen = true
	check(top_seen and bot_seen and mm.mesh != null and mm.mesh.get_surface_count() >= 1,
		"tank cleats loop around top (>0.55) and bottom (<0.15) runs (perim=%.3f surfaces=%d)" % [
			perim, mm.mesh.get_surface_count() if mm.mesh != null else 0])

	# Pure CCW left pivot turn: left tread goes back (< 0), right tread goes forward (> 0).
	var p0_l: Vector3 = rig.track_l_mm.get_meta("cleat0_origin", Vector3.ZERO)
	var p0_r: Vector3 = rig.track_r_mm.get_meta("cleat0_origin", Vector3.ZERO)
	rig.last = tank_node.position
	rig.last_yaw = tank_node.rotation.y
	tank_node.rotation.y += 0.25
	vehicles._animate(0.05)
	var p1_l: Vector3 = rig.track_l_mm.get_meta("cleat0_origin", Vector3.ZERO)
	var p1_r: Vector3 = rig.track_r_mm.get_meta("cleat0_origin", Vector3.ZERO)
	check(rig.left_travel < -0.1 and rig.right_travel > 0.1
		and not p0_l.is_equal_approx(p1_l) and not p0_r.is_equal_approx(p1_r),
		"tank differential pivot turn: left=%.3f (%s->%s) right=%.3f (%s->%s)" % [
			rig.left_travel, p0_l, p1_l, rig.right_travel, p0_r, p1_r])


func _check_car_physics(vehicles: VehicleAnim, car_node: Node3D, unit: int) -> void:
	var rig: VehicleAnim.Rig = vehicles._rigs.get(unit)
	check(rig != null and rig.parts.has("engine_fan"), "car rig attached with engine_fan part")
	if rig == null or not rig.parts.has("engine_fan"):
		return
	var fan_mi: MeshInstance3D = rig.parts["engine_fan"][0][0]
	var fan_xf0 := fan_mi.transform
	car_node.rotation.y = 0.0
	rig.last = car_node.position
	rig.last_yaw = car_node.rotation.y
	rig.prev_speed = 0.0
	rig.pitch = 0.0
	rig.pitch_vel = 0.0
	rig.roll = 0.0
	rig.roll_vel = 0.0

	# Forward acceleration (-Z in model space): nose lifts (pitch > 0) and engine fan turns.
	for _i in 3:
		car_node.position += Vector3(0.0, 0.0, -0.5)
		vehicles._animate(0.05)
	check(rig.pitch > 0.001, "car acceleration pitches nose up (pitch=%.5f)" % rig.pitch)
	check(not fan_xf0.basis.is_equal_approx(fan_mi.transform.basis), "car engine fan rotates")

	# Hard braking: forward velocity drops to 0 -> nose dives (pitch drops).
	var pitch_before_brake := rig.pitch
	for _i in 4:
		vehicles._animate(0.05)
	check(rig.pitch < pitch_before_brake and rig.pitch < 0.0, "car braking pitches nose down (%.5f -> %.5f)" % [pitch_before_brake, rig.pitch])

	# Left turn while moving forward: centrifugal body roll leans right (roll < 0).
	rig.pitch = 0.0
	rig.pitch_vel = 0.0
	rig.roll = 0.0
	rig.roll_vel = 0.0
	for _i in 3:
		var fwd := -car_node.global_transform.basis.z
		car_node.position += fwd * 0.4
		car_node.rotation.y += 0.15
		vehicles._animate(0.05)
	check(rig.roll < -0.001, "car left turn leans outward right (roll=%.5f)" % rig.roll)


func _check_tank_turret_and_recoil(vehicles: VehicleAnim, turrets: Turrets, tank_node: Node3D, unit: int) -> void:
	var rig: VehicleAnim.Rig = vehicles._rigs.get(unit)
	if rig == null:
		return
	rig.pitch = 0.0
	rig.pitch_vel = 0.0
	rig.roll = 0.0
	rig.roll_vel = 0.0
	tank_node.rotation.y = 0.0

	var head_mi: MeshInstance3D = rig.parts["turret_head"][0][0]
	var barrel_mi: MeshInstance3D = rig.parts["turret_barrel"][0][0]
	var coax_mi: MeshInstance3D = rig.parts["turret_coax"][0][0]

	# Gun 1 = tank-cannon: should recoil turret_barrel + rock hull, leaving turret_head & turret_coax un-recoiled.
	turrets.handle_states({"t": "ts", "l": [[unit, 0, 1, 1]]})
	turrets._process(0.02)
	turrets._process(0.02)
	vehicles._animate(0.02)
	var cannon_muzzle := turrets.state_of(unit).muzzle
	check(barrel_mi.transform.origin.z > 0.05 and absf(coax_mi.transform.origin.z) < 0.01
		and absf(head_mi.transform.origin.z) < 0.05,
		"tank cannon shot recoils turret_barrel only (barrel.z=%.3f, coax.z=%.3f, head.z=%.3f)" % [
			barrel_mi.transform.origin.z, coax_mi.transform.origin.z, head_mi.transform.origin.z])
	check(absf(rig.pitch) > 0.001, "tank cannon shot rocks hull via impulse (pitch=%.5f)" % rig.pitch)

	# Decay chassis rock over time.
	var p_peak := absf(rig.pitch)
	for _i in 30:
		vehicles._animate(0.05)
	check(absf(rig.pitch) < p_peak * 0.25, "tank cannon hull rock settles back (peak=%.5f -> %.5f)" % [p_peak, absf(rig.pitch)])

	# Wait out cannon recoil and fire Gun 2 = tank-machine-gun: coax recoils & uses distinct muzzle.
	for _i in 30:
		turrets._process(0.05)
	turrets.handle_states({"t": "ts", "l": [[unit, 0, 1, 2]]})
	turrets._process(0.02)
	turrets._process(0.02)
	var mg_muzzle := turrets.state_of(unit).muzzle
	check(coax_mi.transform.origin.z > 0.005 and absf(barrel_mi.transform.origin.z) < 0.01,
		"tank MG shot recoils turret_coax independently (coax.z=%.3f, barrel.z=%.3f)" % [
			coax_mi.transform.origin.z, barrel_mi.transform.origin.z])
	check(cannon_muzzle.distance_to(mg_muzzle) > 0.2,
		"cannon & coax have distinct muzzles: %s vs %s" % [cannon_muzzle, mg_muzzle])


func _check_lights_and_glow(movers: Movers, tank_unit: int) -> void:
	var tm = movers._movers.get(tank_unit)
	check(tm != null and tm.lights != null and not tm.headlight_meshes.is_empty(),
		"tank mover has VehicleLights and anim_headlight mesh")
	if tm == null or tm.lights == null or tm.headlight_meshes.is_empty():
		return
	var cones := VehicleLights.lights_of(tm.lights)
	var rot0 := absf((cones[0].get_parent() as Node3D).rotation.y) if cones.size() > 0 and cones[0].get_parent() != null else 0.0
	check(cones.size() == 2 and cones[0].light_color.b > 0.7 and rot0 > 0.05,
		"tank VehicleLights uses near-white splayed cones (b=%.2f, rotY=%.3f)" % [
			cones[0].light_color.b if cones.size() > 0 else 0.0,
			rot0])
	movers.set_night(1.0)
	movers.driven = 0
	movers._light_vehicles()
	var g_off := float(tm.headlight_meshes[0].get_instance_shader_parameter("f3d_glow"))
	movers.driven = tank_unit
	movers._light_vehicles()
	var g_on := float(tm.headlight_meshes[0].get_instance_shader_parameter("f3d_glow"))
	check(is_zero_approx(g_off) and g_on > 0.5, "anim_headlight glow syncs with VehicleLights (off=%.2f, on=%.2f)" % [g_off, g_on])


## Trailer: a car and a tank driven by others (not ours) towards the camera at night showed no lamp,
## glare or cone. Now: moving, they light; lenses glow, glare cards at the lamps' front; off by day;
## --headlight-glare=off as before (only ours lights, no glare).
func _check_headlight_glare(movers: Movers, car_unit: int, tank_unit: int) -> void:
	movers.driven = 0
	movers.set_night(1.0)
	var units := [car_unit, tank_unit]
	for unit: int in units:  # standing a long while (the checks before nudged the car)
		movers._movers.get(unit).light_moved = -1.0e9
		movers._movers.get(unit).light_seen = Vector3.INF
	movers._light_vehicles()
	for unit: int in units:
		var m = movers._movers.get(unit)
		check(m != null and not m.lights.visible, "unit %d: standing, nobody of ours in it: dark" % unit)
	# Both drive south a few tiles (towards a camera south of them).
	for step in range(1, 6):
		movers.handle({"t": "mv", "k": 10 + step, "l": [[car_unit, 8, 10 * 256, (10 + step) * 256, 500],
			[tank_unit, 9, 20 * 256, (10 + step) * 256, 500]]})
		for _i in 4:
			movers._process(1.0 / 60.0)
	for unit: int in units:
		var m = movers._movers.get(unit)
		var name := "car" if unit == car_unit else "tank"
		var cones := VehicleLights.lights_of(m.lights)
		var glares := VehicleLights.glares_of(m.lights)
		var glow := float(m.headlight_meshes[0].get_instance_shader_parameter("f3d_glow")) if not m.headlight_meshes.is_empty() else 0.0
		check(m.lights.visible and cones.size() == 2 and cones[0].light_energy > 0.1,
			"%s: driven by another at night, its cones are on (%.2f)" % [name, cones[0].light_energy if cones.size() > 0 else 0.0])
		check(glow > 0.5, "%s: lens glows (%.2f)" % [name, glow])
		# The car's headlight part spans both lamps (two cards), the tank's is one lamp mid-front.
		var front_ok := glares.size() == (2 if unit == car_unit else 1)
		for g in glares:
			var at: Vector3 = m.node.to_local(g.global_position)
			front_ok = front_ok and at.z < -0.5 and at.y > 0.2 and float(g.get_instance_shader_parameter("glow")) > 0.5 \
					and g.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		check(front_ok, "%s: glare cards at the lamps' front, lit, no shadow (%s)" % [name,
			[m.node.to_local(glares[0].global_position)] if glares.size() > 0 else []])
		var shadows := 0
		for l in cones:
			if l.shadow_enabled and l.shadow_caster_mask != 0:
				shadows += 1
		check(shadows == 0, "%s: no shadow-casting light added" % name)
	# By day: dark.
	movers.set_night(0.0)
	movers._light_vehicles()
	for unit: int in units:
		check(not movers._movers.get(unit).lights.visible, "unit %d: by day no headlights" % unit)
	# --headlight-glare=off: a vehicle someone else drives stays dark, no glare cards on a new one.
	VehicleLights.glare_enabled = false
	movers.set_night(1.0)
	movers._light_vehicles()
	check(not movers._movers.get(car_unit).lights.visible, "--headlight-glare=off: another's car stays dark")
	var rig := VehicleLights.build("car")
	VehicleLights.place_glare(rig, [] as Array[MeshInstance3D])
	check(VehicleLights.glares_of(rig).is_empty(), "--headlight-glare=off: no glare cards")
	rig.free()
	VehicleLights.glare_enabled = true
	var glare_mat := VehicleLights.glare_material(Color(1.0, 1.0, 0.8))
	var uname := func(u: Dictionary) -> String: return str(u.get("name", ""))
	var glare_uniforms: Array = glare_mat.shader.get_shader_uniform_list().map(uname)
	check(glare_mat != null and glare_mat.shader != null and glare_uniforms.has("pull") and glare_uniforms.has("tint"),
		"glare shader compiles cleanly with pull and tint uniforms (%s)" % [glare_uniforms])
	check(VehicleLights.GLARE_SHADER.contains("pull * smoothstep(")
		and VehicleLights.GLARE_SHADER.contains("smoothstep(0.0, 0.25, facing)")
		and not VehicleLights.GLARE_SHADER.contains("centre + to_cam * pull "),
		"glare shader scales pull with facing and fades core to 0 when dot(fwd, to_cam) <= 0")


## A thunderstorm's dimmed sun at dusk lights the lamps: the screen is dark though the game's night is low.
func _check_headlight_storm() -> void:
	var storm := {"sun_energy_scale": 0.4}
	check(Avatar.beam(VehicleLights.screen_night(0.1, {})) < 0.01, "storm: no weather, the game's night 0.1 leaves lamps off")
	check(Avatar.beam(VehicleLights.screen_night(0.1, storm)) > 0.8, "storm: dimmed sun lights the lamps at night 0.1")
	check(is_equal_approx(VehicleLights.screen_night(0.9, storm), 0.9), "storm: a darker game night is kept")
	VehicleLights.storm_enabled = false
	check(is_equal_approx(VehicleLights.screen_night(0.1, storm), 0.1), "--headlight-storm=off: the game's night alone")
	VehicleLights.storm_enabled = true


func _check_old_flag(holder: Node3D, movers: Movers, protos: ProtoDB) -> void:
	VehicleAnim.enhanced = false
	var old_vehicles := VehicleAnim.new()
	holder.add_child(old_vehicles)
	var old_node := movers._make_node(protos.entity(9))
	holder.add_child(old_node)
	old_vehicles.attach(902, old_node, "tank")
	var old_rig: VehicleAnim.Rig = old_vehicles._rigs.get(902)
	check(old_rig != null and old_rig.track_l_mm == null and old_rig.track_r_mm == null,
		"--vehicle-anim=old: no closed-loop track MultiMeshes attached")
	var static_visible := true
	if old_rig != null:
		for key in ["tread_l", "tread_r"]:
			for pair in old_rig.parts.get(key, []):
				if not (pair[0] as MeshInstance3D).visible:
					static_visible = false
	check(static_visible, "--vehicle-anim=old: static tread meshes remain visible")
	old_vehicles.impulse(902, Vector3.BACK, 1.0)
	old_node.position += Vector3(0.0, 0.0, -0.5)
	old_vehicles._animate(0.05)
	check(old_vehicles.chassis_xform(902).is_equal_approx(Transform3D.IDENTITY)
		and (old_rig == null or is_zero_approx(old_rig.pitch)),
		"--vehicle-anim=old: chassis stays IDENTITY and impulse is a no-op")
	VehicleAnim.enhanced = true


func _check_vehicle_tracks(holder: Node3D) -> void:
	var was_enabled := VehicleTracks.enabled
	VehicleTracks.enabled = true
	var vt := VehicleTracks.new()
	holder.add_child(vt)
	vt._ensure_meshes()

	# 1. Disabled state: step_vehicle() is a no-op and both MultiMeshes stay hidden.
	VehicleTracks.enabled = false
	vt.step_vehicle(700, Vector2(10.0, 10.0), 0.0, 5.0, true, "grass", Color(0.28, 0.36, 0.18), 0.1)
	vt.step_vehicle(700, Vector2(10.0, 8.5), 0.0, 5.0, true, "grass", Color(0.28, 0.36, 0.18), 0.2)
	vt.tick(0.05, Vector2(10.0, 8.5))
	check(vt._vehicles.is_empty() and vt._track_used == 0 and vt._dirt_used == 0
		and not vt._tracks_mmi.visible and not vt._dirt_mmi.visible
		and vt._tracks_mm.visible_instance_count == 0 and vt._dirt_mm.visible_instance_count == 0,
		"vehicle tracks: disabled state is a no-op and keeps both MultiMeshes hidden")

	# 2. Natural ground ("grass"): tank stamps tread tracks and kicks up dirt clods/dust.
	VehicleTracks.enabled = true
	vt.step_vehicle(701, Vector2(10.0, 10.0), 0.0, 5.0, true, "grass", Color(0.28, 0.36, 0.18), 0.1)
	vt.step_vehicle(701, Vector2(10.0, 9.0), 0.0, 5.0, true, "grass", Color(0.28, 0.36, 0.18), 0.2)
	vt.tick(0.016, Vector2(10.0, 9.0))
	check(vt._tracks_mmi.visible and vt._track_used > 0 and vt._tracks_mm.visible_instance_count > 0
		and vt._dirt_mmi.visible and vt._dirt_used > 0 and vt._dirt_mm.visible_instance_count > 0,
		"vehicle tracks: tank on grass stamps treads (%d) and kicks up dirt (%d)" % [vt._track_used, vt._dirt_used])

	# 3. Paved ground ("concrete"): stamps faint tracks, kicks up zero new dirt clods.
	var tracks_before_paved: int = vt._track_used
	var dirt_used_before_paved: int = vt._dirt_used
	var dirt_cursor_before_paved: int = vt._dirt_cursor
	vt.step_vehicle(701, Vector2(10.0, 8.0), 0.0, 5.0, true, "concrete", Color(0.45, 0.45, 0.45), 0.2)
	check(vt._track_used > tracks_before_paved
		and vt._dirt_used == dirt_used_before_paved and vt._dirt_cursor == dirt_cursor_before_paved,
		"vehicle tracks: concrete stamps tracks (%d->%d) with zero new dirt (%d)" % [
			tracks_before_paved, vt._track_used, vt._dirt_used - dirt_used_before_paved])

	# 4. Teleport guard (> 6.0 tile jump): resets without emitting tracks or dirt.
	var tracks_before_tp: int = vt._track_used
	var track_cursor_before_tp: int = vt._track_cursor
	var dirt_before_tp: int = vt._dirt_used
	var dirt_cursor_before_tp: int = vt._dirt_cursor
	vt.step_vehicle(701, Vector2(20.0, 8.0), 0.0, 5.0, true, "grass", Color(0.28, 0.36, 0.18), 0.2)
	var tp_st := vt._vehicles.get(701) as VehicleTracks.TrackState
	check(vt._track_used == tracks_before_tp and vt._track_cursor == track_cursor_before_tp
		and vt._dirt_used == dirt_before_tp and vt._dirt_cursor == dirt_cursor_before_tp
		and tp_st != null and is_zero_approx(tp_st.left_dist) and is_zero_approx(tp_st.right_dist) and is_zero_approx(tp_st.dirt_dist),
		"vehicle tracks: >6.0 tile teleport resets state without emitting tracks or dirt")

	# 5. Idle timeout (tick 15.0s): hides both MultiMeshes when tracks/particles expire.
	vt.tick(15.0, Vector2(20.0, 8.0))
	check(not vt._tracks_mmi.visible and not vt._dirt_mmi.visible
		and vt._tracks_mm.visible_instance_count == 0 and vt._dirt_mm.visible_instance_count == 0,
		"vehicle tracks: idle timeout hides both MultiMeshes")

	# 6. clear() resets trackers and hides both MultiMeshes.
	vt.step_vehicle(701, Vector2(20.0, 7.0), 0.0, 5.0, true, "grass", Color(0.28, 0.36, 0.18), 0.2)
	vt.step_vehicle(701, Vector2(20.0, 6.0), 0.0, 5.0, true, "grass", Color(0.28, 0.36, 0.18), 0.2)
	vt.tick(0.016, Vector2(20.0, 6.0))
	var active_before_clear: bool = vt._tracks_mmi.visible and vt._dirt_mmi.visible and not vt._vehicles.is_empty()
	vt.clear()
	check(active_before_clear and vt._vehicles.is_empty()
		and vt._track_used == 0 and vt._track_cursor == 0
		and vt._dirt_used == 0 and vt._dirt_cursor == 0
		and not vt._tracks_mmi.visible and not vt._dirt_mmi.visible
		and vt._tracks_mm.visible_instance_count == 0 and vt._dirt_mm.visible_instance_count == 0,
		"vehicle tracks: clear() resets trackers and hides both MultiMeshes")

	holder.remove_child(vt)
	vt.free()
	VehicleTracks.enabled = was_enabled
