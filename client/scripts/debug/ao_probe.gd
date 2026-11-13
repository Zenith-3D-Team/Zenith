extends Node
## --ao-probe=<file.txt>[@seconds]: after that many seconds (default 20) writes what each model
## MultiMesh in the world draws and whether its shading data reaches the shader: the mesh, its
## instances, shadow casting, visibility, per surface whether it has COLOR (the baked occlusion) and
## UV2, the occlusion's mean and least, and the material's vertex_data and ao_strength. For checking
## a modeller's baked occlusion and shadows (docs/SESSION-LOG.md, the AO work).

const Settings := preload("res://scripts/menu/settings.gd")

var main: Node
var out_path := ""
var seconds := 20.0


func _ready() -> void:
	await get_tree().create_timer(seconds).timeout
	var lines := PackedStringArray()
	var seen := {}
	_walk(get_tree().root, lines, seen)
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(lines) + "\n")
	print("ao probe: %d lines to %s" % [lines.size(), out_path])
	if "--ao-probe-shots" in OS.get_cmdline_user_args():
		await _shots()
		get_tree().quit()
		return
	if "--aa-probe-shots" in OS.get_cmdline_user_args():
		await _aa_shots()
		get_tree().quit()
		return
	# --ao-probe-ab=<bias>,<normal bias>: the window now and a few frames after setting those biases
	# (<file>-a.png, <file>-b.png), so the difference is the biases' alone.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ao-probe-ab="):
			var spec := arg.get_slice("=", 1)
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(out_path.get_basename() + "-a.png")
			for sun in get_tree().root.find_children("*", "DirectionalLight3D", true, false):
				(sun as DirectionalLight3D).shadow_bias = float(spec.get_slice(",", 0))
				(sun as DirectionalLight3D).shadow_normal_bias = float(spec.get_slice(",", 1))
			for k in 3:
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(out_path.get_basename() + "-b.png")
			print("ao probe: a/b saved")


## --ao-probe-shots: the window with each kind of occlusion switched off in turn (<file>-<variant>.png:
## all, no-ssao, no-contact, no-baked, none, then all again: what moves between two pictures of the same),
## each after the picture settled (TAA), with the GPU's time for the frame averaged over half a second's
## frames and SSAO's state then, into <file>-shots.txt; then quits.
const SHOT_VARIANTS := ["all", "no-ssao", "no-contact", "no-baked", "none", "all-again"]


func _shots() -> void:
	var report := PackedStringArray()
	var zoom := get_tree().root.find_child("AoZoom", true, false)
	var env: Environment = zoom.get("env") if zoom != null else null
	var ssao_was := env.ssao_enabled if env != null else false
	var baked := _baked_materials()
	var vp := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	for v: String in SHOT_VARIANTS:
		var off_ssao := v == "no-ssao" or v == "none"
		var off_contact := v == "no-contact" or v == "none"
		var off_baked := v == "no-baked" or v == "none"
		if env != null:
			env.ssao_enabled = ssao_was and not off_ssao
		for n in get_tree().root.find_children("ContactShade", "MultiMeshInstance3D", true, false):
			(n as Node3D).visible = not off_contact
		for m: ShaderMaterial in baked:
			m.set_shader_parameter("ao_strength", 0.0 if off_baked else baked[m])
		for k in 45:
			await get_tree().process_frame
		var gpu := 0.0
		for k in 30:
			await RenderingServer.frame_post_draw
			gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		get_viewport().get_texture().get_image().save_png(out_path.get_basename() + "-" + v + ".png")
		report.append("%s gpu=%.2f ms ssao_env=%s ao_zoom: %.4f tiles/px share %.2f on %s, rings %d, baked materials %d" % [v, gpu / 30.0,
			env.ssao_enabled if env != null else false, float(zoom.get("tiles_per_pixel")) if zoom else 0.0,
			float(zoom.get("ssao_share")) if zoom else 0.0, zoom.get("ssao_on") if zoom else false,
			get_tree().root.find_children("ContactShade", "MultiMeshInstance3D", true, false).size(), baked.size()])
	if env != null:
		env.ssao_enabled = ssao_was
	for m: ShaderMaterial in baked:
		m.set_shader_parameter("ao_strength", baked[m])
	var f := FileAccess.open(out_path.get_basename() + "-shots.txt", FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(report) + "\n")
	print("ao probe shots:\n" + "\n".join(report))


## --aa-probe-shots: the window under each anti-aliasing choice in turn (<file>-aa-<choice>.png), the
## setting held unsaved and applied as Settings > Graphics does, with what the root viewport then has
## (MSAA, screen-space AA, TAA) into <file>-aa.txt; then quits. Under a look with passes MSAA isn't drawn.
const AA_CHOICES := ["off", "fxaa", "smaa", "taa", "msaa4", "off-again"]


func _aa_shots() -> void:
	var report := PackedStringArray()
	var root := get_tree().root
	var was: Variant = Settings.get_value("graphics", "antialiasing")
	for choice: String in AA_CHOICES:
		Settings.set_value("graphics", "antialiasing", choice.trim_suffix("-again"), false)
		Settings.apply_antialiasing(root)
		for k in 60:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(out_path.get_basename() + "-aa-" + choice + ".png")
		report.append("%s: in effect %s, msaa_3d %d, screen_space_aa %d, use_taa %s, scaling_3d_scale %.2f mode %d, look passes %s" % [choice,
			Settings.antialiasing_in_effect(), root.msaa_3d, root.screen_space_aa, root.use_taa, root.scaling_3d_scale,
			root.scaling_3d_mode, Settings.look_draws_passes()])
	Settings.set_value("graphics", "antialiasing", was, false)
	Settings.apply_antialiasing(root)
	var f := FileAccess.open(out_path.get_basename() + "-aa.txt", FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(report) + "\n")
	print("aa probe shots:\n" + "\n".join(report))


## Every model material drawn now whose mesh has baked occlusion (vertex_data on): {material: its ao_strength}.
func _baked_materials() -> Dictionary:
	var out := {}
	for node in get_tree().root.find_children("*", "GeometryInstance3D", true, false):
		var mesh: Mesh = null
		if node is MultiMeshInstance3D and (node as MultiMeshInstance3D).multimesh != null:
			mesh = (node as MultiMeshInstance3D).multimesh.mesh
		elif node is MeshInstance3D:
			mesh = (node as MeshInstance3D).mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var m := mesh.surface_get_material(i) as ShaderMaterial
			if m == null or out.has(m) or float(m.get_shader_parameter("vertex_data") if m.get_shader_parameter("vertex_data") != null else 0.0) < 0.5:
				continue
			var s: Variant = m.get_shader_parameter("ao_strength")
			out[m] = 1.0 if s == null else float(s)
	return out


## --ao-probe-bias=<bias>,<normal bias>: the sun's shadow biases held there (to try them).
func _process(_delta: float) -> void:
	var spec := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ao-probe-bias="):
			spec = arg.get_slice("=", 1)
	if "--ao-probe-own-shadows" in OS.get_cmdline_user_args():
		# Every model casts its own shadow, the stand-ins none (to tell the two apart).
		for n in get_tree().root.find_children("*", "MultiMeshInstance3D", true, false):
			var m := n as MultiMeshInstance3D
			if m.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
				m.visible = false
			elif m.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and m.get_parent().name.begins_with("Chunk"):
				m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	if spec == "":
		return
	for sun in get_tree().root.find_children("*", "DirectionalLight3D", true, false):
		(sun as DirectionalLight3D).shadow_bias = float(spec.get_slice(",", 0))
		(sun as DirectionalLight3D).shadow_normal_bias = float(spec.get_slice(",", 1))


func _walk(node: Node, lines: PackedStringArray, seen: Dictionary) -> void:
	var sun := node as DirectionalLight3D
	if sun != null:
		lines.append("sun %s on=%s bias=%.3f normal_bias=%.3f max=%.1f splits=%.3f,%.3f,%.3f mode=%d blur=%.2f angular=%.2f opacity=%.2f atlas=%d rot=%s" % [
			sun.name, sun.shadow_enabled, sun.shadow_bias, sun.shadow_normal_bias, sun.directional_shadow_max_distance,
			sun.directional_shadow_split_1, sun.directional_shadow_split_2, sun.directional_shadow_split_3, sun.directional_shadow_mode,
			sun.shadow_blur, sun.light_angular_distance, sun.shadow_opacity,
			int(ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/size")), sun.global_rotation_degrees])
	var we := node as WorldEnvironment
	if we != null and we.environment != null:
		var e := we.environment
		lines.append("env ssao=%s radius=%.2f intensity=%.2f power=%.2f light_affect=%.2f ssil=%s" % [e.ssao_enabled, e.ssao_radius,
			e.ssao_intensity, e.ssao_power, e.ssao_light_affect, e.ssil_enabled])
	if node.name == "AoZoom":
		lines.append("ao zoom: %.4f tiles/px, ssao share %.2f, on %s" % [node.get("tiles_per_pixel"), node.get("ssao_share"), node.get("ssao_on")])
	var mmi := node as MultiMeshInstance3D
	if mmi != null and mmi.multimesh != null and mmi.multimesh.mesh != null and mmi.multimesh.instance_count > 0:
		var mesh := mmi.multimesh.mesh
		var tris := 0
		for i in mesh.get_surface_count():
			var ix: Variant = mesh.surface_get_arrays(i)[Mesh.ARRAY_INDEX]
			tris += (ix as PackedInt32Array).size() / 3 if ix != null else 0
		var line := "%s  n=%d cast=%d vis=%s parent=%s tris=%d aabb=%s at=%s" % [_name(mesh), mmi.multimesh.instance_count, mmi.cast_shadow,
			mmi.is_visible_in_tree(), str(mmi.get_parent().name), tris, mesh.get_aabb(), mmi.multimesh.get_instance_transform(0).origin]
		if mesh.has_meta(&"f3d_contact"):
			line += " feet=%s" % [mesh.get_meta(&"f3d_contact")]  # contact_shade.gd feet_of()
		var mat := mmi.material_override
		for i in mesh.get_surface_count():
			var sm: Material = mat if mat != null else mesh.surface_get_material(i)
			var fmt := (mesh as ArrayMesh).surface_get_format(i) if mesh is ArrayMesh else 0
			var desc := " | s%d color=%s uv2=%s" % [i, (fmt & Mesh.ARRAY_FORMAT_COLOR) != 0, (fmt & Mesh.ARRAY_FORMAT_TEX_UV2) != 0]
			if (fmt & Mesh.ARRAY_FORMAT_COLOR) != 0 and not seen.has([mesh, i]):
				seen[[mesh, i]] = true
				var arrays := mesh.surface_get_arrays(i)
				var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
				var total := 0.0
				var least := 1.0
				for c in colors:
					total += c.a
					least = minf(least, c.a)
				desc += " ao=%.2f/%.2f" % [total / maxf(colors.size(), 1.0), least]
			if sm is ShaderMaterial:
				var shm := sm as ShaderMaterial
				desc += " vd=%s ao_s=%s tex=%s" % [shm.get_shader_parameter("vertex_data"), shm.get_shader_parameter("ao_strength"),
					shm.get_shader_parameter("use_albedo_tex")]
			line += desc
		lines.append(line)
	for c in node.get_children():
		_walk(c, lines, seen)


static func _name(mesh: Mesh) -> String:
	if mesh.resource_name != "":
		return mesh.resource_name
	return "<%s>" % mesh.get_class()
