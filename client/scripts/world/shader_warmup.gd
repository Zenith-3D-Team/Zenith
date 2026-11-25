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
const Switches := preload("res://scripts/switches.gd")

const WARM_FRAMES := 4
const STAGED_WARM_FRAMES := 2
const DIR := "res://shaders"
const MAX_ACTIVE_BATCHES := 2
const WARM_MAX_ACTIVE := 24
const COLD_MAX_ACTIVE_MIN := 4
const COLD_MAX_ACTIVE_MAX := 12

## Screen-space, post-effect, or overlay shaders that never draw with MultiMeshInstance3D.
const PLAIN_ONLY_SHADERS := {
	"cloud_shadows.gdshader": true,
	"god_rays.gdshader": true,
	"remote_fog.gdshader": true,
	"smog.gdshader": true,
	"cinematic_grade.gdshader": true,
	"look_reactive_clear.gdshader": true,
	"decorative_bake.gdshader": true,
	"ground_mark.gdshader": true,
	"ground_overlay.gdshader": true,
}

## Shaders whose custom vertex formats are warmed directly in `_ItemKind.SPECIAL`.
const SPECIAL_MESH_SHADERS := {
	"terrain.gdshader": true,
	"terrain_old.gdshader": true,
	"terrain_shore.gdshader": true,
	"water.gdshader": true,
	"far_merged.gdshader": true,
	"far_tree_crown.gdshader": true,
}

enum _ItemKind { SHADER, STANDARD, SPECIAL }


class _WorkItem:
	var kind: int
	var path: String
	var label: String

	func _init(k: int, p: String, l: String) -> void:
		kind = k
		path = p
		label = l


class _ActiveBatch:
	var node: Node3D
	var frames := 0

	func _init(n: Node3D) -> void:
		node = n


static var mode := _mode()
static var shaders: Array[Shader] = []  # kept: a shader freed would compile again on its next use
static var warmed_msec := -1  # how long the set-up took (--stutter-probe prints it)
static var handled_by_boot := false  # true when boot screen ran begin_staged() before main._ready()

var done_count := 0
var total_count := 0
var current_label := ""
var max_active_batches := MAX_ACTIVE_BATCHES

var _frames := 0
var _staged := false
var _staged_done := false
var _include_all := false
var _budget_ms := 25
var _staged_t0 := 0
var _baseline_pipelines := 0
var _queue: Array[_WorkItem] = []
var _queue_idx := 0
var _preload_idx := 0
var _threaded_paths := {}
var _active_batches: Array[_ActiveBatch] = []
var _shared_box: BoxMesh


static func _mode() -> String:
	for a in Switches.args():
		if a.begins_with("--warm-shaders="):
			return a.substr(15)
	return "loaded"


## Collects spatial/world `.gdshader` paths from `res://shaders` (and recursively from `extra_dirs`
## when `include_all` is true), skipping uncached `*_old.gdshader` files, deduplicated and sorted.
static func collect_paths(include_all: bool, extra_dirs: Array = []) -> Array[String]:
	var seen := {}
	_scan_shader_dir(DIR, include_all, false, seen)
	if include_all:
		for raw_dir in extra_dirs:
			var d: String = str(raw_dir).replace("\\", "/")
			if d.ends_with("/") and not d.ends_with("://"):
				d = d.trim_suffix("/")
			if d != "" and DirAccess.dir_exists_absolute(d):
				_scan_shader_dir(d, true, true, seen)
	var out: Array[String] = []
	for key in seen.keys():
		out.append(str(key))
	out.sort()
	return out


static func _scan_shader_dir(dir: String, include_all: bool, recursive: bool, seen: Dictionary) -> void:
	for f in DirAccess.get_files_at(dir):
		var file_name: String = f.trim_suffix(".remap")
		if not file_name.ends_with(".gdshader"):
			continue
		var path: String = dir.path_join(file_name)
		if file_name.ends_with("_old.gdshader") and not ResourceLoader.has_cached(path):
			continue
		if not include_all and not ResourceLoader.has_cached(path):
			continue
		seen[path] = true
	if recursive:
		for sub in DirAccess.get_directories_at(dir):
			if not sub.begins_with("."):
				_scan_shader_dir(dir.path_join(sub), include_all, true, seen)


static func _pipeline_total() -> int:
	var total := 0
	for m in [
		Performance.PIPELINE_COMPILATIONS_CANVAS,
		Performance.PIPELINE_COMPILATIONS_MESH,
		Performance.PIPELINE_COMPILATIONS_SURFACE,
		Performance.PIPELINE_COMPILATIONS_DRAW,
		Performance.PIPELINE_COMPILATIONS_SPECIALIZATION,
	]:
		total += int(Performance.get_monitor(m))
	return total


## Puts the warm-up under `parent` (and returns it), or nothing when off, handled by boot, or done already.
static func start(parent: Node) -> Node3D:
	if handled_by_boot or mode == "off" or warmed_msec >= 0:
		return null
	var node := new()
	node.name = "ShaderWarmup"
	parent.add_child(node)
	return node


## Starts time-sliced shader warm-up under `parent`, returning the node so callers can track progress.
static func begin_staged(parent: Node, include_all: bool, extra_dirs: Array = [], budget_ms: int = 25) -> Node3D:
	var node := new()
	node.name = "ShaderWarmup"
	node._staged = true
	node._include_all = include_all
	node._budget_ms = budget_ms
	if budget_ms <= 0:
		node.max_active_batches = MAX_ACTIVE_BATCHES
	elif include_all:
		node.max_active_batches = clampi(OS.get_processor_count() / 2, COLD_MAX_ACTIVE_MIN, COLD_MAX_ACTIVE_MAX)
	else:
		node.max_active_batches = WARM_MAX_ACTIVE
	node._staged_t0 = Time.get_ticks_msec()
	node._baseline_pipelines = _pipeline_total()
	node._shared_box = _box_mesh()
	for p in collect_paths(include_all, extra_dirs):
		node._queue.append(_WorkItem.new(_ItemKind.SHADER, p, p.get_file().trim_suffix(".gdshader")))
	node._queue.append(_WorkItem.new(_ItemKind.STANDARD, "", "Standard materials"))
	node._queue.append(_WorkItem.new(_ItemKind.SPECIAL, "", "Terrain & far chunks"))
	node.total_count = node._queue.size()
	node._request_lookahead()
	parent.add_child(node)
	return node


func is_done() -> bool:
	return _staged_done if _staged else _frames > WARM_FRAMES


func pipelines_compiled() -> int:
	return maxi(0, _pipeline_total() - _baseline_pipelines)


func _ready() -> void:
	if _staged:
		return
	var t0 := Time.get_ticks_msec()
	if shaders.is_empty():
		for path in collect_paths(mode == "all"):
			var s := load(path) as Shader
			if s != null and s.get_mode() == Shader.MODE_SPATIAL:
				shaders.append(s)
	var materials: Array[Material] = []
	for s in shaders:
		var m := ShaderMaterial.new()
		m.shader = s
		materials.append(m)
	materials.append_array(_standard_materials())
	var box := _box_mesh()
	for m in materials:
		_add_material_nodes(self, m, box)
	_add_special_meshes(self)
	warmed_msec = Time.get_ticks_msec() - t0
	print("Shader warm-up (%s): %d shaders, %d materials set up in %d ms" % [mode, shaders.size(), materials.size(), warmed_msec])


static func _box_mesh() -> BoxMesh:
	var box := BoxMesh.new()
	box.size = Vector3.ONE * 0.01
	return box


static func _standard_materials() -> Array[Material]:
	# The standard materials in use: boxes and cones for entities without a model, ghosts, the robots'
	# drop shadows (movers.gd).
	var shadow := StandardMaterial3D.new()
	shadow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shadow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shadow.cull_mode = BaseMaterial3D.CULL_DISABLED
	return [
		Visuals.solid_material(Color.WHITE),
		Visuals.ghost_material(Color.WHITE),
		shadow,
	]


static func _add_material_nodes(parent_node: Node3D, m: Material, box: BoxMesh) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = box
	mi.material_override = m
	parent_node.add_child(mi)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = box
	mm.instance_count = 1
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = m
	parent_node.add_child(mmi)
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
	parent_node.add_child(mmi_c)


static func _add_special_meshes(parent_node: Node3D) -> void:
	# The ground: its vertex layout (terrain_mesher.gd TerrainSurface) with the terrain and water materials.
	var ground := MeshInstance3D.new()
	ground.mesh = _ground_mesh()
	parent_node.add_child(ground)
	# Far merged chunks: compressed vertex + color layout, and crown puffs with uncompressed world UV (far_chunks.gd).
	var far := MeshInstance3D.new()
	far.mesh = _far_chunk_mesh()
	parent_node.add_child(far)
	var far_crown := MeshInstance3D.new()
	far_crown.mesh = _far_crown_mesh()
	parent_node.add_child(far_crown)


func _request_lookahead() -> void:
	var target := mini(_queue.size(), _queue_idx + max_active_batches * 2)
	while _preload_idx < target:
		var item: _WorkItem = _queue[_preload_idx]
		_preload_idx += 1
		if item.kind != _ItemKind.SHADER:
			continue
		if not item.path.begins_with("res://") or ResourceLoader.has_cached(item.path):
			continue
		if ResourceLoader.load_threaded_request(item.path, "Shader") == OK:
			_threaded_paths[item.path] = true


func _process_item(item: _WorkItem) -> Node3D:
	match item.kind:
		_ItemKind.SHADER:
			var s: Shader = null
			if _threaded_paths.has(item.path):
				var status := ResourceLoader.load_threaded_get_status(item.path)
				if status == ResourceLoader.THREAD_LOAD_LOADED or status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
					s = ResourceLoader.load_threaded_get(item.path) as Shader
				_threaded_paths.erase(item.path)
			if s == null:
				s = load(item.path) as Shader
			if s == null or s.get_mode() != Shader.MODE_SPATIAL:
				return null
			if not shaders.has(s):
				shaders.append(s)
			var fname := item.path.get_file()
			if SPECIAL_MESH_SHADERS.has(fname):
				return null
			var batch := Node3D.new()
			add_child(batch)
			var m := ShaderMaterial.new()
			m.shader = s
			if PLAIN_ONLY_SHADERS.has(fname):
				var mi := MeshInstance3D.new()
				mi.mesh = _shared_box
				mi.material_override = m
				batch.add_child(mi)
			else:
				_add_material_nodes(batch, m, _shared_box)
			return batch
		_ItemKind.STANDARD:
			var batch := Node3D.new()
			add_child(batch)
			for m in _standard_materials():
				_add_material_nodes(batch, m, _shared_box)
			return batch
		_ItemKind.SPECIAL:
			var batch := Node3D.new()
			add_child(batch)
			_add_special_meshes(batch)
			return batch
	return null


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
	var ground_materials: Array[Material] = [Visuals.terrain_material(), Visuals.water_material()]
	if not Visuals.terrain_opt_old:
		ground_materials.insert(1, Visuals.terrain_shore_material())  # the coast's, its own shader
	for m in ground_materials:
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
	if not _staged:
		_frames += 1
		if _frames > WARM_FRAMES:
			queue_free()
		return
	if _staged_done:
		return
	var still_active: Array[_ActiveBatch] = []
	for b in _active_batches:
		b.frames += 1
		if b.frames >= STAGED_WARM_FRAMES:
			if is_instance_valid(b.node):
				if b.node.get_parent() == self:
					remove_child(b.node)
				b.node.queue_free()
		else:
			still_active.append(b)
	_active_batches = still_active
	_request_lookahead()
	var frame_start := Time.get_ticks_msec()
	var processed := 0
	var limit := 1 if _budget_ms <= 0 else max_active_batches
	while _queue_idx < _queue.size() and _active_batches.size() < max_active_batches and processed < limit:
		if processed > 0 and _budget_ms > 0 and int(Time.get_ticks_msec() - frame_start) >= _budget_ms:
			break
		var item: _WorkItem = _queue[_queue_idx]
		_queue_idx += 1
		current_label = item.label
		var batch := _process_item(item)
		if batch != null:
			_active_batches.append(_ActiveBatch.new(batch))
		done_count += 1
		processed += 1
	if _queue_idx >= _queue.size() and _active_batches.is_empty():
		_staged_done = true
		warmed_msec = int(Time.get_ticks_msec() - _staged_t0)
		print("Shader warm-up (staged, %s): %d shaders, %d items set up in %d ms (%d pipelines)" % [
			"all" if _include_all else "loaded", shaders.size(), total_count, warmed_msec, pipelines_compiled()])
		set_process(false)
