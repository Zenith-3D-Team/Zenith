extends RefCounted
## Pipelines compiled before anything draws them (client-cpu.md 12). The 0.2-0.9 s frames while
## joining were Godot compiling a new model's pipelines inside its draw: 6 frames of 174-781 ms in
## a join's first 17 s, two a laps run.
##
## Godot 4.7.2 (renderer_rd/forward_clustered) builds a new instance's surface cache for every
## instance in the scene, seen or not, and queues the pipelines it can need (colour, depth, shadow,
## normal-roughness...) on its worker threads from there; a draw stalls only when its pipeline isn't
## compiled yet. Pipelines belong to the shader and the mesh's vertex format, not to the mesh or
## the material instance. So a mesh whose surfaces bring a (shader, vertex format) not seen yet gets
## a one-instance MultiMesh far below the world, out of every view and shadow split, and chunks
## leave the model out until it has been there HOLD_MSEC and WARM_FRAMES frames (ready()), as they
## do while it is being read: drawn a moment later, never a frozen frame. The model's levels of
## detail and shadow stand-in are warmed the same way once made (not waited for).
##
## Each save's models are kept by name (user://seen-models/<save id>.json) and asked for at the
## welcome, so they are read while the join's loading screen is up (world.gd join_left, front_end.gd).
## `--pipeline-warm=off` draws models as soon as they are made, as before; `--pipeline-warm=<msec>`
## sets HOLD_MSEC. Off headless (nothing is drawn: tests build chunks and look at them at once) unless
## `--pipeline-warm=on`.

const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")

const HOLD_MSEC := 300
const WARM_FRAMES := 3
## Where the warming instances stand: far under the world, so no camera or shadow split meets them.
const FAR := Vector3(0.0, -20000.0, 0.0)
const SAVE_DIR := "user://seen-models"
const SAVE_EVERY_MSEC := 60000
## Levels and stand-ins looked at for new pipelines at most this often (level_generation moves
## dozens of times a second while joining).
const EXTRAS_MSEC := 250

static var enabled := true
static var hold_msec := HOLD_MSEC
static var _args_read := false

static var _root: Node3D
static var _known := {}  # key -> true: its pipelines compiled (been in the scene long enough)
static var _pending := {}  # key -> [MultiMeshInstance3D, process frame, msec] while they compile
static var _users := {}  # MultiMeshInstance3D -> how many keys still wait on it
static var _ready := {}  # Mesh -> true: every surface (and moving part) of the mesh is warm
static var _models := {}  # of those, the models chunks draw (their levels and stand-ins warmed too)
static var _extras := {}  # model Mesh -> [levels warmed, stand-in warmed]
static var _extras_gen := -1
static var _extras_msec := 0
## Goes up whenever pipelines became ready (world.gd draws the chunks that left models out again).
static var generation := 0
## For probes and the UI test: warming instances made, and models left out for it.
static var instances_made := 0
static var models_held := 0

## This save's models: the save id, model name -> true, whether the list changed since written.
static var _save_id := ""
static var _seen := {}
static var _seen_mesh := {}  # Mesh -> true: ready and its names noted on this save
static var _seen_dirty := false
static var _saved_msec := 0
## How many names the save's list asked for at the welcome, and those not asked for yet: fed to
## ModelLibrary while it has few jobs waiting (poll), so the models the first chunks ask for don't
## queue behind a whole base's list.
static var listed := 0
static var _preload: Array[String] = []
static var _preload_warm: Array[String] = []
static var _preload_warm_i := 0


static func _read_args() -> void:
	_args_read = true
	enabled = DisplayServer.get_name() != "headless"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--pipeline-warm="):
			var v := arg.get_slice("=", 1)
			if v == "off":
				enabled = false
			elif v == "on":
				enabled = true
			elif v.is_valid_int():
				enabled = true
				hold_msec = maxi(0, int(v))


## The node the warming instances go under (world.gd, in the world's scene).
static func attach(parent: Node3D) -> void:
	if not _args_read:
		_read_args()
	if _root != null and is_instance_valid(_root):
		_root.queue_free()
	_root = Node3D.new()
	_root.name = "PipelineWarm"
	parent.add_child(_root)
	# What was warming under the last world went with it: compiling had started, so it counts.
	for key in _pending:
		_known[key] = true
	_pending.clear()
	_users.clear()


## Whether a chunk may draw this entity's model now: its own surfaces and its moving parts' have
## pipelines already (or long enough to have compiled them). Starts warming them if not. Notes the
## model as seen on this save either way.
static func model_ready(mesh: Mesh, proto_name: String, proto_type: String, extra: Dictionary, dir: int) -> bool:
	if mesh == null or _seen_mesh.has(mesh):
		return true
	if not _args_read:
		_read_args()
	_note(proto_name)
	var variant := ModelLibrary.model_name(proto_name, proto_type, extra, dir)
	if variant != proto_name:
		_note(variant)
	if not enabled:
		_seen_mesh[mesh] = true
		return true
	if not _ready.has(mesh):
		var parts := ModelLibrary.parts_for_entity(proto_name, proto_type, extra, dir)
		var warm := _mesh_ready(mesh, null)
		for part in parts:
			if part.mesh != null and not _mesh_ready(part.mesh, null):
				warm = false
		if not warm:
			models_held += 1
			return false
		_ready[mesh] = true
		_models[mesh] = true
		for part in parts:
			if part.mesh != null:
				_models[part.mesh] = true
	_seen_mesh[mesh] = true
	return true


## model_ready() for a mesh without moving parts or a name to note (remnants, sprite cards).
static func mesh_ready(mesh: Mesh) -> bool:
	if mesh == null or _ready.has(mesh):
		return true
	if not _args_read:
		_read_args()
	if not enabled or _mesh_ready(mesh, null):
		_ready[mesh] = true
		return true
	models_held += 1
	return false


## Whether a mesh's surfaces (drawn with `override`, or their own materials) are warm; starts the ones
## that aren't.
static func _mesh_ready(mesh: Mesh, override: Material) -> bool:
	if _root == null or not is_instance_valid(_root):
		return true  # no world to warm in (tests): nothing waits
	var missing: Array[String] = []
	for i in mesh.get_surface_count():
		var key := _key(mesh, i, override)
		if not _known.has(key) and not missing.has(key):
			missing.append(key)
	if missing.is_empty():
		return true
	var mmi: MultiMeshInstance3D = null
	for key in missing:
		if _pending.has(key):
			continue
		if mmi == null:
			mmi = _instance(mesh, override)
		_pending[key] = [mmi, Engine.get_process_frames(), Time.get_ticks_msec()]
		_users[mmi] = int(_users.get(mmi, 0)) + 1
	return false


## What a surface's pipelines depend on: its shader (a ShaderMaterial's; another material counts as
## its own) and next passes, and its vertex format.
static func _key(mesh: Mesh, i: int, override: Material) -> String:
	var m: Material = override if override != null else mesh.surface_get_material(i)
	var key := ""
	var depth := 0
	while m != null and depth < 4:
		var who: Object = m
		if m is ShaderMaterial and (m as ShaderMaterial).shader != null:
			who = (m as ShaderMaterial).shader
		key += "%d:" % who.get_instance_id()
		m = m.next_pass
		depth += 1
	if mesh is ArrayMesh:
		key += "f%d" % (mesh as ArrayMesh).surface_get_format(i)
	else:
		key += "m%d" % mesh.get_instance_id()
	return key


static func _instance(mesh: Mesh, override: Material) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = 1
	mm.set_instance_transform(0, Transform3D(Basis.IDENTITY, FAR))
	mm.set_instance_custom_data(0, Color(0.0, 0.0, 0.0, 0.0))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	if override != null:
		mmi.material_override = override
	_root.add_child(mmi)
	instances_made += 1
	return mmi


## Once a frame (world.gd): pipelines given long enough count as compiled, their instances go; the
## models' levels and stand-ins made since are warmed. True when some became ready.
static func poll() -> bool:
	var changed := false
	if not _pending.is_empty():
		var frame := Engine.get_process_frames()
		var now := Time.get_ticks_msec()
		for key: String in _pending.keys():
			var entry: Array = _pending[key]
			if frame - int(entry[1]) < WARM_FRAMES or now - int(entry[2]) < hold_msec:
				continue
			_pending.erase(key)
			_known[key] = true
			changed = true
			var mmi: MultiMeshInstance3D = entry[0]
			var left := int(_users.get(mmi, 1)) - 1
			if left > 0:
				_users[mmi] = left
			else:
				_users.erase(mmi)
				if is_instance_valid(mmi):
					mmi.queue_free()
	if enabled and (ModelLods.level_generation != _extras_gen) and Time.get_ticks_msec() - _extras_msec >= EXTRAS_MSEC:
		_extras_gen = ModelLods.level_generation
		_extras_msec = Time.get_ticks_msec()
		_warm_extras()
	var asked := 0
	while not _preload.is_empty() and asked < 32 and ModelLibrary.pending_count() < ModelLibrary.load_jobs + 2:
		var pre_name: String = _preload.pop_back()
		ModelLibrary.ready(pre_name)  # read on a worker from now (a name without a model: nothing)
		_preload_warm.append(pre_name)
		asked += 1
	if enabled and _root != null and is_instance_valid(_root) and not _preload_warm.is_empty():
		_warm_preloaded()
	if Time.get_ticks_msec() - _saved_msec > SAVE_EVERY_MSEC:
		flush()
	if changed:
		generation += 1
	return changed


## The ready models' levels of detail and shadow stand-ins, made on workers since: warmed (nothing
## waits for them; their pipelines are mostly the models' own, met already).
static func _warm_extras() -> void:
	for mesh: Mesh in _models:
		var done: Array = _extras.get(mesh, [0, false])
		var levels := ModelLods.levels(mesh)
		if levels.size() > int(done[0]):
			for level: Array in levels:
				_mesh_ready(level[0], null)
			done[0] = levels.size()
		if not bool(done[1]):
			var proxy := ModelLods.proxy_for(mesh)
			if proxy == null:
				done[1] = true
			elif ModelLods.is_ready(proxy) and proxy.get_surface_count() > 0:
				_mesh_ready(proxy, null)
				done[1] = true
		_extras[mesh] = done


## Warms pipelines of save-preloaded models once their workers finish, before the player reaches them.
static func _warm_preloaded() -> void:
	var checked := 0
	var limit := mini(_preload_warm.size(), 8)
	while checked < limit and not _preload_warm.is_empty():
		_preload_warm_i = _preload_warm_i % _preload_warm.size()
		var n := _preload_warm[_preload_warm_i]
		checked += 1
		if ModelLibrary.ready(n):
			_preload_warm.remove_at(_preload_warm_i)
			var mesh := ModelLibrary.mesh_for(n)
			if mesh != null:
				_mesh_ready(mesh, null)
				_models[mesh] = true
				for part in ModelLibrary.parts_for(n):
					if part.mesh != null:
						_mesh_ready(part.mesh, null)
						_models[part.mesh] = true
		else:
			_preload_warm_i += 1


## Pipelines still being given their time.
static func pending_count() -> int:
	return _pending.size()


# --- each save's models -------------------------------------------------------------------------

static func _note(name: String) -> void:
	if _save_id != "" and not _seen.has(name):
		_seen[name] = true
		_seen_dirty = true


static func _path(save_id: String) -> String:
	return SAVE_DIR.path_join(save_id.validate_filename() + ".json")


## The welcome: this save's models from its list, read on workers from now on (poll) while the
## join's loading screen is up.
static func on_welcome(save_id: String) -> void:
	if not _args_read:
		_read_args()
	if save_id == _save_id:
		return
	flush()
	_save_id = save_id
	_seen = {}
	_seen_mesh = {}
	_seen_dirty = false
	listed = 0
	_preload.clear()
	_preload_warm.clear()
	_preload_warm_i = 0
	if save_id == "" or not FileAccess.file_exists(_path(save_id)):
		return
	var names = JSON.parse_string(FileAccess.get_file_as_string(_path(save_id)))
	if not (names is Array):
		return
	for n in names:
		if n is String:
			_seen[n] = true
			_preload.append(n)
			listed += 1
	_preload.reverse()  # (taken from the back: in the list's order)


## Writes this save's list if it changed (also every SAVE_EVERY_MSEC, and when the world goes).
static func flush() -> void:
	_saved_msec = Time.get_ticks_msec()
	if not _seen_dirty or _save_id == "":
		return
	_seen_dirty = false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SAVE_DIR))
	var file := FileAccess.open(_path(_save_id), FileAccess.WRITE)
	if file == null:
		return
	var names: Array = _seen.keys()
	names.sort()
	file.store_string(JSON.stringify(names))
	file.close()
