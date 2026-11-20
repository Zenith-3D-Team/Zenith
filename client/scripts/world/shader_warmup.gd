extends Node3D
## Uses the world's shaders once while the client starts (--warm-shaders=loaded|all|off; loaded). A shader's
## variants compile on worker threads from when it is loaded, and the first material that uses it waits
## for them to finish (the renderer updates the material on the main thread): on a join at -62,-26 the
## first item kind drawn as a model waited 53 ms, the first robot 120 ms (two shaders), the first chunk's
## clutter 100-115 ms (its kinds' two or three shaders), the character 59 ms, each in the frame it
## appeared, on a 4-core PC also running the server and the belt worker. Here each shader gets a material
## on a tiny box and on a one-instance MultiMesh in the tree for WARM_FRAMES frames, and the ground's own
## vertex layout its two materials, so the waits and the surfaces' pipeline precompiles happen before the
## world shows. `loaded`: the shaders the scripts preloaded (the world's); `all`: every spatial shader in
## res://shaders, which loads about fifteen more (effects, ghosts, passes) and had the worker threads
## compiling their variants for half a minute into the join, starving the models, clutter and terrain
## jobs (the world appeared 29 s late, the belts' first load took 80 s); off: nothing. The shaders used
## stay loaded.

const Visuals := preload("res://scripts/world/visuals.gd")
const TerrainMesher := preload("res://scripts/world/terrain_mesher.gd")
const FarChunks := preload("res://scripts/world/far_chunks.gd")

const WARM_FRAMES := 4
const DIR := "res://shaders"

static var mode := _mode()
static var shaders: Array[Shader] = []  # kept: a shader freed would compile again on its next use
static var warmed_msec := -1  # how long the set-up took (--stutter-probe prints it)
var _frames := 0


static func _mode() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--warm-shaders="):
			return a.substr(15)
	return "loaded"


## Puts the warm-up under `parent` (and returns it), or nothing when off or done already.
static func start(parent: Node) -> Node3D:
	if mode == "off" or warmed_msec >= 0:
		return null
	var node := new()
	node.name = "ShaderWarmup"
	parent.add_child(node)
	return node


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	if shaders.is_empty():
		for f in DirAccess.get_files_at(DIR):
			var name := f.trim_suffix(".remap")
			if not name.ends_with(".gdshader"):
				continue
			if mode != "all" and not ResourceLoader.has_cached(DIR.path_join(name)):
				continue  # not loaded yet: its compile would compete with the join's own work
			var s := load(DIR.path_join(name)) as Shader
			if s != null and s.get_mode() == Shader.MODE_SPATIAL:
				shaders.append(s)
	var materials: Array[Material] = []
	for s in shaders:
		var m := ShaderMaterial.new()
		m.shader = s
		materials.append(m)
	# The standard materials in use: boxes and cones for entities without a model, ghosts, the robots'
	# drop shadows (movers.gd).
	materials.append(Visuals.solid_material(Color.WHITE))
	materials.append(Visuals.ghost_material(Color.WHITE))
	var shadow := StandardMaterial3D.new()
	shadow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shadow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shadow.cull_mode = BaseMaterial3D.CULL_DISABLED
	materials.append(shadow)
	var box := BoxMesh.new()
	box.size = Vector3.ONE * 0.01
	for m in materials:
		var mi := MeshInstance3D.new()
		mi.mesh = box
		mi.material_override = m
		add_child(mi)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = box
		mm.instance_count = 1
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = m
		add_child(mmi)
		# Also warm MULTIMESH_HAS_COLOR (tints, custom-painted/placeholder variants).
		var mm_c := MultiMesh.new()
		mm_c.transform_format = MultiMesh.TRANSFORM_3D
		mm_c.use_colors = true
		mm_c.use_custom_data = true
		mm_c.mesh = box
		mm_c.instance_count = 1
		var mmi_c := MultiMeshInstance3D.new()
		mmi_c.multimesh = mm_c
		mmi_c.material_override = m
		add_child(mmi_c)
	# The ground: its vertex layout (terrain_mesher.gd TerrainSurface) with the terrain and water materials.
	var ground := MeshInstance3D.new()
	ground.mesh = _ground_mesh()
	add_child(ground)
	# Far merged chunks: compressed vertex + color layout, and crown puffs with uncompressed world UV (far_chunks.gd).
	var far := MeshInstance3D.new()
	far.mesh = _far_chunk_mesh()
	add_child(far)
	var far_crown := MeshInstance3D.new()
	far_crown.mesh = _far_crown_mesh()
	add_child(far_crown)
	warmed_msec = Time.get_ticks_msec() - t0
	print("Shader warm-up (%s): %d shaders, %d materials set up in %d ms" % [mode, shaders.size(), materials.size(), warmed_msec])


## One quad in the ground's layout, a surface per material.
static func _ground_mesh() -> ArrayMesh:
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0, 0, 0), Vector3(0.01, 0, 0), Vector3(0.01, 0, 0.01), Vector3(0, 0, 0.01)])
	a[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
	a[Mesh.ARRAY_COLOR] = PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE])
	a[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	a[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	var custom := PackedFloat32Array()
	custom.resize(16)
	a[Mesh.ARRAY_CUSTOM0] = custom
	a[Mesh.ARRAY_CUSTOM1] = custom.duplicate()
	a[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh := ArrayMesh.new()
	for m in [Visuals.terrain_material(), Visuals.water_material()]:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a, [], {}, TerrainMesher.TerrainSurface.FORMAT)
		mesh.surface_set_material(mesh.get_surface_count() - 1, m)
	return mesh


## One triangle in far_chunks.gd's compressed vertex-color layout.
static func _far_chunk_mesh() -> ArrayMesh:
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0, 0, 0), Vector3(0.01, 0, 0), Vector3(0, 0, 0.01)])
	a[Mesh.ARRAY_COLOR] = PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE])
	a[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a, [], {}, Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES)
	mesh.surface_set_material(0, FarChunks.material())
	return mesh


## One triangle in far_chunks.gd's tree-crown layout (uncompressed float world UV).
static func _far_crown_mesh() -> ArrayMesh:
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0, 0, 0), Vector3(0.01, 0, 0), Vector3(0, 0, 0.01)])
	a[Mesh.ARRAY_COLOR] = PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE])
	a[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	a[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a, [], {}, 0)
	mesh.surface_set_material(0, FarChunks.crown_material())
	return mesh


func _process(_delta: float) -> void:
	_frames += 1
	if _frames > WARM_FRAMES:
		queue_free()
