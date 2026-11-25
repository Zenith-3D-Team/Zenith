extends Node
## Pipelines for things that show up only on a click, a hover or a setting change, built once while the
## client starts instead of in the frame they first draw (the stutter-live report: Alt-mode switched
## on 20-77 ms, 55-62 pipelines built while drawing on a render setting change, hover 18-42 ms in
## `in_highlights`). Godot builds a pipeline when something using it first enters a view; here a tiny
## 64x64 SubViewport (own world, rendered a few frames, then freed) holds:
##   - the hover marks as they are drawn (an ImmediateMesh of vertex colours with ground_overlay's and
##     ground_mark's materials, and the picture variant the fluid icons use),
##   - Alt-mode's card shader (alt_icons.gdshader) on a 2D MultiMesh,
##   - a lit box under an Environment with SSAO, SSIL, glow, colour adjustments, fog and a shadowed sun,
##     so the effects' own pipelines are made too (the settings turn these on and off).
## The renderer's pipelines depend on the viewport's formats, so what a differently set up main view
## still builds is left (to be measured: switching Alt-mode on and a setting in a window).
## `--pipe-warm-extra=off`: nothing (as before). Not in a headless run.

const HoverShaderWarm := preload("res://scripts/world/ground_height.gd")
const AltShader := preload("res://shaders/alt_icons.gdshader")
const Switches := preload("res://scripts/switches.gd")

const WARM_FRAMES := 4

static var done := false

var done_count := 0
var total_count := 3
var current_label := ""

var _frames := 0
var _staged := false
var _staged_done := false
var _phase := 0
var _hold_frames := 0
var _vp: SubViewport


## Puts the warm-up under `parent`; nothing when off, headless or done already.
static func start(parent: Node) -> Node:
	if done or DisplayServer.get_name() == "headless" or not Switches.on("--pipe-warm-extra"):
		return null
	done = true
	var node := new()
	node.name = "RenderWarm"
	parent.add_child(node)
	return node


## Starts 3-phase staged pipeline warm-up under `parent`; returns null when off, headless or done already.
static func begin_staged(parent: Node) -> Node:
	if done or DisplayServer.get_name() == "headless" or "--pipe-warm-extra=off" in OS.get_cmdline_user_args():
		return null
	var node := new()
	node.name = "RenderWarm"
	node._staged = true
	parent.add_child(node)
	return node


func is_done() -> bool:
	return _staged_done if _staged else _frames > WARM_FRAMES


func _ready() -> void:
	_vp = _create_viewport()
	add_child(_vp)
	if _staged:
		return
	_setup_post_effects(_vp)
	_setup_hover_and_fluid(_vp)
	_setup_alt_icons(_vp)
	print("Render warm-up: hover marks, Alt-mode card shader, post effects set up")


static func _create_viewport() -> SubViewport:
	var vp := SubViewport.new()
	vp.size = Vector2i(64, 64)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	return vp


static func _setup_post_effects(vp: SubViewport) -> void:
	# 3D: a lit, shadowed box under every post effect the settings switch.
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.ssao_enabled = true
	env.ssil_enabled = true
	env.glow_enabled = true
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.1
	env.fog_enabled = true
	env.fog_density = 0.001
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	vp.add_child(world_env)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 2, 4)
	cam.rotation_degrees = Vector3(-25, 0, 0)
	vp.add_child(cam)
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.rotation_degrees = Vector3(-50, 30, 0)
	vp.add_child(sun)
	var box := MeshInstance3D.new()
	box.mesh = BoxMesh.new()
	vp.add_child(box)
	var floor_mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(8, 8)
	floor_mi.mesh = plane
	floor_mi.position = Vector3(0, -0.5, 0)
	vp.add_child(floor_mi)


static func _setup_hover_and_fluid(vp: SubViewport) -> void:
	# The hover marks' vertex-colour surface with the three materials they use.
	var white := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	white.fill(Color.WHITE)
	var materials: Array[Material] = [
		HoverShaderWarm.overlay_material(10),
		HoverShaderWarm.overlay_material(10, ImageTexture.create_from_image(white)),
		HoverShaderWarm.mark_material(Color.WHITE, true, HoverShaderWarm.AREA_PRIORITY),
	]
	for m in materials:
		var im := ImmediateMesh.new()
		im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
		for p in [Vector3(-0.5, 0, 0), Vector3(0.5, 0, 0), Vector3(0, 0, 0.5)]:
			im.surface_set_color(Color(1, 1, 1, 0.5))
			im.surface_set_uv(Vector2(p.x, p.z))
			im.surface_add_vertex(p)
		im.surface_end()
		var mi := MeshInstance3D.new()
		mi.mesh = im
		mi.material_override = m
		mi.position = Vector3(0, 0.6, 0)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		vp.add_child(mi)
	# The quad the fluid icons use (a QuadMesh lying flat with the overlay shader and a picture).
	var quad := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.orientation = PlaneMesh.FACE_Y
	quad.mesh = qm
	quad.material_override = materials[1]
	quad.position = Vector3(0, 0.6, 0)
	vp.add_child(quad)


static func _setup_alt_icons(vp: SubViewport) -> void:
	# Alt-mode's icons: one quad an icon in a 2D MultiMesh, with the card shader (alt_overlay.gd _gpu_setup).
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector2Array([Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var amesh := ArrayMesh.new()
	amesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_FLAG_USE_2D_VERTICES)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = amesh
	mm.instance_count = 1
	mm.set_instance_transform_2d(0, Transform2D(0.0, Vector2(32, 32)))
	var mmi := MultiMeshInstance2D.new()
	mmi.multimesh = mm
	var amat := ShaderMaterial.new()
	amat.shader = AltShader
	mmi.material = amat
	vp.add_child(mmi)


func _process(_delta: float) -> void:
	if not _staged:
		_frames += 1
		if _frames > WARM_FRAMES:
			queue_free()
		return
	if _staged_done:
		return
	match _phase:
		0:
			current_label = "Post-processing effects"
			_setup_post_effects(_vp)
			_phase = 1
			done_count = 1
		1:
			current_label = "Hover & fluid overlays"
			_setup_hover_and_fluid(_vp)
			_phase = 2
			done_count = 2
		2:
			current_label = "Alt-mode GPU icons"
			_setup_alt_icons(_vp)
			_phase = 3
			done_count = 3
			_hold_frames = 0
		3:
			_hold_frames += 1
			if _hold_frames >= WARM_FRAMES:
				done = true
				_staged_done = true
				if _vp != null and is_instance_valid(_vp):
					if _vp.get_parent() == self:
						remove_child(_vp)
					_vp.queue_free()
					_vp = null
				print("Render warm-up (staged): hover marks, Alt-mode card shader, post effects set up")
				set_process(false)
