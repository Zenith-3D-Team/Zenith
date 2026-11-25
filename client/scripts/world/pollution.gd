extends Node3D
## What Factorio's pollution does to the land (owner's I15), from the bridge's `pol` (pollution.lua:
## each chunk's pollution round the focus, every five seconds) and distant charted chunks'
## `map_pollution`. One texel a chunk round the view (`128 x 128` RGBA8), read by the shaders
## through pollution.gdshaderinc: R = dying trees/green lakes, G = local smog, B = CPU-blurred
## aloft smog canopy. Nothing where there is no pollution, and nothing on a space platform (the
## bridge sends none there, and a change of surface switches to that surface's cached state). The
## smog's pass is drawn only while a chunk it can read for the camera holds smog (smog_in_view).
##
## Levels ease towards each update over EASE seconds, so a tree doesn't drop its leaves in one
## frame when the numbers come in, and the smog thickens and thins gently.

const Settings := preload("res://scripts/menu/settings.gd")
const PlanetSky := preload("res://scripts/world/sky.gd")
const SMOG_SHADER := preload("res://shaders/smog.gdshader")
const Switches := preload("res://scripts/switches.gd")
const PRIORITY := 3
## --smog-look=old: keep 0.2.2's flat 5-tile ground layer instead of volumetric ground-to-sky smog.
static var old_look: bool = Switches.has("--smog-look=old")
## --smog-cache=off: disable persistent distant pollution caching and per-surface cache.
static var cache_enabled: bool = Switches.on("--smog-cache")
const GLOBAL_TEX := &"f3d_pollution"
const GLOBAL_RECT := &"f3d_pollution_rect"
## Chunks a side of the texture (4,096 tiles), centred near the view; the bridge sends 25 x 25.
const SIZE := 128
## Re-centred when the view gets this many chunks from the texture's middle.
const RECENTRE := 24
## Maximum distant chunks kept in the per-surface pollution cache.
const CACHE_MAX_CHUNKS := 65536
## Coarse distant horizon pollution grid (256 x 256 cells of 4 x 4 chunks -> +-512 chunks).
const FAR_SIZE := 256
const FAR_CELL_CHUNKS := 4
const CACHE_MAGIC := "ZPOL"
const CACHE_VERSION := 1
const FLUSH_INTERVAL := 30.0
## Separable blur radius (chunks) for the elevated aloft smog canopy (B channel).
const ALOFT_RADIUS := 2
## Fallback half-width (chunks) cleared when `pol` sends `w = 0` without an active `_live_rect`.
const LIVE_CLEAR_RADIUS := 8
## Seconds to ease a chunk from its old level to the new one.
const EASE := 4.0
## How often the texture is written while levels ease (a few hundred pixels a write).
const WRITE_EVERY := 0.25
## Trees: unharmed up to the map's tree damage threshold (`md`, Factorio's
## min_pollution_to_damage_trees, 60 by default), bare at BARE times it. Factorio damages trees over
## time above the threshold; the chunks round a factory, which sit far above it for hours, are the
## ones whose trees are dead, so the level grows with the logarithm of the pollution.
const BARE := 15.0
## Smog: none below SMOG_FROM, thickest at SMOG_FULL (Factorio's pollution map turns deep red there).
const SMOG_FROM := 40.0
const SMOG_FULL := 4000.0
## The least smog a chunk's texel can hold above 0 (half the 8-bit texture's first step: a level
## under it is written as 0). The pass draws nothing where every texel it reads is 0, but even one
## step shows in first person, where a ray runs hundreds of tiles through the layer.
const SMOG_SHOWN := 0.5 / 255.0
## How far under the lowest ground the smog's layer reaches (smog.gdshader: a tile, and a margin).
const LAYER_BELOW := 1.5
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const SafeDelete := preload("res://scripts/safe_delete.gd")

var _image := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
var _texture: ImageTexture
var _far_image := Image.create(FAR_SIZE, FAR_SIZE, false, Image.FORMAT_R8)
var _far_texture: ImageTexture
var _far_origin := Vector2i(-(FAR_SIZE * FAR_CELL_CHUNKS) / 2, -(FAR_SIZE * FAR_CELL_CHUNKS) / 2)
var _far_version := 0
var _far_cur := PackedByteArray()
var _far_prev := PackedByteArray()
var _noise_tex: ImageTexture
var _origin := Vector2i.ZERO
var _damage := 60.0
## Chunk -> Vector2(dying, smog) as the last `pol`/chart says, and as drawn now (easing towards it).
var _target := {}
var _shown := {}
var _raw := {}
var _live_rect := Rect2i()
var _focus_chunk := Vector2i.ZERO
var _surface_index := -1
var _surface_cache := {}
var _cache_enabled := cache_enabled
var _base_dir := "user://pollution-cache"
var _save_id := ""
var _dirty_disk := false
var _flush_timer := 0.0
var _write_task := -1
var _write_job: CacheWriteJob = null
var _local_grid := PackedFloat32Array()
var _blur_tmp := PackedFloat32Array()
var _easing := false
var _write_timer := 0.0
var _redraw := true
var _quad := MeshInstance3D.new()
var _material := ShaderMaterial.new()
var _strength := 0.0
## Chunks whose texel holds smog (as last written), their bounds, and a count of the writes that
## changed them; whether the view has any of them, for the view's chunks and the write it was found for.
var _smog_chunks: Array[Vector2i] = []
var _smog_bounds := Rect2i()
var _smog_version := 0
var _seen := false
var _seen_rect := Rect2i()
var _seen_version := -1
var _volumetric := true
var _cloud_cache := {}


class CacheWriteJob:
	var abs_dir := ""
	var abs_path := ""
	var payload := PackedByteArray()
	var remove_file := false

	func run() -> void:
		if remove_file:
			if FileAccess.file_exists(abs_path) and not SafeDelete.is_link(abs_path):
				DirAccess.remove_absolute(abs_path)
			return
		if DirAccess.make_dir_recursive_absolute(abs_dir) != OK:
			return
		var abs_tmp := abs_path + ".tmp.%d" % OS.get_process_id()
		var ok := false
		var f := FileAccess.open_compressed(abs_tmp, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
		if f != null:
			f.store_buffer(payload)
			ok = f.get_error() == OK
			f.close()
		if ok:
			var err := DirAccess.rename_absolute(abs_tmp, abs_path)
			if err != OK:
				if FileAccess.file_exists(abs_path) and not SafeDelete.is_link(abs_path):
					DirAccess.remove_absolute(abs_path)
					err = DirAccess.rename_absolute(abs_tmp, abs_path)
				if err != OK:
					ok = false
		if not ok:
			if FileAccess.file_exists(abs_tmp):
				DirAccess.remove_absolute(abs_tmp)
			var fd := FileAccess.open_compressed(abs_path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
			if fd != null:
				fd.store_buffer(payload)
				fd.close()


func _ensure_textures() -> void:
	if _texture == null:
		_image.fill(Color(0.0, 0.0, 0.0, 1.0))
		_texture = ImageTexture.create_from_image(_image.duplicate() as Image)
	if _far_texture == null:
		_far_image.fill(Color.BLACK)
		_far_texture = ImageTexture.create_from_image(_far_image.duplicate() as Image)
		_far_prev.resize(FAR_SIZE * FAR_SIZE)
		_far_prev.fill(0)
		_far_cur.resize(FAR_SIZE * FAR_SIZE)
		_far_cur.fill(0)


func _ready() -> void:
	_local_grid.resize(SIZE * SIZE)
	_blur_tmp.resize(SIZE * SIZE)
	_ensure_textures()
	RenderingServer.global_shader_parameter_set(GLOBAL_TEX, _texture)
	RenderingServer.global_shader_parameter_set(GLOBAL_RECT, Vector4(0.0, 0.0, 32.0, 0.0))
	_material.shader = SMOG_SHADER
	_noise_tex = _build_noise_texture()
	if _noise_tex != null:
		_material.set_shader_parameter("smog_noise", _noise_tex)
	# After the see-through things (ghosts, smoke, item cards, effects: up to 2), before God rays (4)
	# and the remote view's fog (5), which covers it, and the cursor's build preview and name tags (10).
	_material.render_priority = PRIORITY
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	_quad.mesh = quad
	_quad.material_override = _material
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_quad.extra_cull_margin = 16384.0  # it covers the screen wherever it is
	_quad.name = "Smog"
	_quad.visible = false
	add_child(_quad)
	set_volumetric(not old_look)
	_read_setting()
	Settings.listen(_on_setting)


func _exit_tree() -> void:
	flush_cache()
	PlanetSky.clear_cloud_uniforms(_material, _cloud_cache)
	_material.set_shader_parameter("smog_noise", null)
	_noise_tex = null
	RenderingServer.global_shader_parameter_set(GLOBAL_RECT, Vector4(0.0, 0.0, 32.0, 0.0))


static func _build_noise_texture() -> ImageTexture:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	noise.frequency = 0.032
	noise.seed = 17
	var img: Image = noise.get_seamless_image(128, 128, false, false, 0.25)
	if img != null and not img.is_empty():
		img.generate_mipmaps()
		return ImageTexture.create_from_image(img)
	return null


func set_cache_enabled(on: bool) -> void:
	_cache_enabled = on


func is_cache_enabled() -> bool:
	return _cache_enabled


func cached_chunk_count() -> int:
	return _target.size()


func has_cached_chunk(chunk: Vector2i) -> bool:
	return _target.has(chunk)


func far_texture() -> ImageTexture:
	_ensure_textures()
	return _far_texture


func far_rect() -> Vector4:
	return Vector4(float(_far_origin.x * 32), float(_far_origin.y * 32), float(FAR_CELL_CHUNKS * 32),
		0.0 if _shown.is_empty() else 1.0)


func far_version() -> int:
	return _far_version


func _set_chunk_level(c: Vector2i, p: float, level: Vector2) -> void:
	if p > 0.0 and level != Vector2.ZERO:
		var was_shown := _shown.has(c)
		var prev: Variant = _target.get(c)
		var changed := not (prev is Vector2) or (prev as Vector2) != level
		_raw[c] = p
		_target[c] = level
		if not was_shown:
			_shown[c] = level
			_redraw = true
			_write_timer = 0.0
			_dirty_disk = true
		elif changed:
			_easing = true
			_dirty_disk = true
	elif _target.has(c) or _raw.has(c) or _shown.has(c):
		_raw.erase(c)
		_target.erase(c)
		_easing = true
		_dirty_disk = true


func _update_damage(new_damage: float) -> void:
	var prev_damage := _damage
	_damage = maxf(1.0, new_damage)
	if is_equal_approx(prev_damage, _damage):
		return
	for old_c: Vector2i in _raw.keys():
		var old_p := float(_raw[old_c])
		var lvl := levels(old_p, _damage)
		if lvl != Vector2.ZERO:
			_target[old_c] = lvl
			if not _shown.has(old_c):
				_shown[old_c] = lvl
				_redraw = true
				_write_timer = 0.0
		else:
			_target.erase(old_c)
			_raw.erase(old_c)
	_easing = true
	_dirty_disk = true


## `pol` from the bridge: the live square round the focus (`w` 0: clear live area).
func handle(msg: Dictionary) -> void:
	var w := int(msg.get("w", 0))
	if not _cache_enabled:
		_target.clear()
		_raw.clear()
		_live_rect = Rect2i()
		if w > 0:
			_damage = maxf(1.0, float(msg.get("md", 60)))
			var cx := int(msg.get("cx", 0))
			var cy := int(msg.get("cy", 0))
			var l: Variant = msg.get("l")
			var values: Array = l if l is Array else []
			for i in mini(values.size(), w * w):
				var p := float(values[i])
				if p > 0.0:
					var c := Vector2i(cx + i % w, cy + i / w)
					var level := levels(p, _damage)
					if level != Vector2.ZERO:
						_raw[c] = p
						_target[c] = level
						if not _shown.has(c):
							_shown[c] = level
							_redraw = true
							_write_timer = 0.0
		_easing = true
		return

	if w > 0:
		_update_damage(float(msg.get("md", _damage)))
		var cx := int(msg.get("cx", 0))
		var cy := int(msg.get("cy", 0))
		_live_rect = Rect2i(cx, cy, w, w)
		var l: Variant = msg.get("l")
		var values: Array = l if l is Array else []
		for i in mini(values.size(), w * w):
			var c := Vector2i(cx + i % w, cy + i / w)
			var p := float(values[i])
			_set_chunk_level(c, p, levels(p, _damage))
		_trim_cache()
	else:
		var has_live := _live_rect.size != Vector2i.ZERO
		var focus_rect := Rect2i(
			_focus_chunk - Vector2i(LIVE_CLEAR_RADIUS, LIVE_CLEAR_RADIUS),
			Vector2i(LIVE_CLEAR_RADIUS * 2 + 1, LIVE_CLEAR_RADIUS * 2 + 1))
		for c: Vector2i in _target.keys():
			if (has_live and _live_rect.has_point(c)) or focus_rect.has_point(c):
				_target.erase(c)
				_raw.erase(c)
				_dirty_disk = true
	_easing = true


## Sparse background sweep (`pols`) of charted chunks outside the live `pol` square.
func handle_sparse(msg: Dictionary) -> void:
	if not _cache_enabled:
		return
	_update_damage(float(msg.get("md", _damage)))
	var l: Variant = msg.get("l")
	if not (l is Array):
		return
	var vals: Array = l
	for i in range(0, vals.size() - 2, 3):
		var c := Vector2i(int(vals[i]), int(vals[i + 1]))
		if _live_rect.has_point(c):
			continue
		var p := float(vals[i + 2])
		_set_chunk_level(c, p, levels(p, _damage))
	_trim_cache()


## Updates a distant charted chunk's pollution outside the authoritative live `pol` square.
func ingest_chart_pollution(chunk: Vector2i, amount: float) -> void:
	if not _cache_enabled or _live_rect.has_point(chunk):
		return
	_set_chunk_level(chunk, amount, levels(amount, _damage))
	if amount > 0.0:
		_trim_cache()


## Ingests all charted chunks' cached pollution from `ui_model.map_pollution`.
func sync_map_pollution(map_pol: Dictionary) -> void:
	if not _cache_enabled or map_pol.is_empty():
		return
	for k: Variant in map_pol:
		if k is Vector2i:
			ingest_chart_pollution(k as Vector2i, float(map_pol[k]))


static func _sanitize_save_id(save_id: String) -> String:
	var out := ""
	for i in save_id.length():
		var code := save_id.unicode_at(i)
		var ok := (code >= 48 and code <= 57) \
			or (code >= 65 and code <= 90) \
			or (code >= 97 and code <= 122) \
			or code == 95 or code == 45
		if ok:
			out += save_id.substr(i, 1)
	if out.length() > 64:
		out = out.substr(0, 64)
	return out if out != "" else "default"


func _cache_file_path(si: int) -> String:
	if _save_id == "" or si < 0:
		return ""
	return _base_dir.path_join(_save_id).path_join("s%d.zpol" % si)


func configure(save_id: String, surface_index: int, base_dir := "user://pollution-cache") -> void:
	flush_cache()
	var safe := _sanitize_save_id(save_id) if save_id != "" else ""
	if safe != _save_id or base_dir != _base_dir:
		clear()
	_base_dir = base_dir
	_save_id = safe
	_surface_index = maxi(0, surface_index)
	_dirty_disk = false
	_flush_timer = 0.0
	if _cache_enabled and _save_id != "":
		_load_disk_cache(_surface_index)
	_redraw = true
	_write_timer = 0.0
	_write()


func poll_cache_write() -> void:
	if _write_task >= 0 and WorkerThreadPool.is_task_completed(_write_task):
		WorkerThreadPool.wait_for_task_completion(_write_task)
		_write_task = -1
		_write_job = null


func wait_cache_write() -> void:
	if _write_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_write_task)
		_write_task = -1
		_write_job = null


func _prepare_cache_write_job() -> CacheWriteJob:
	var rel := _cache_file_path(_surface_index)
	if rel == "":
		return null
	var abs_dir := ProjectSettings.globalize_path(_base_dir.path_join(_save_id))
	if SafeDelete.is_link(abs_dir):
		return null
	var abs_path := ProjectSettings.globalize_path(rel)
	if SafeDelete.is_link(abs_path):
		return null
	var job := CacheWriteJob.new()
	job.abs_dir = abs_dir
	job.abs_path = abs_path
	if _raw.is_empty():
		job.remove_file = true
		return job
	var buf := PackedByteArray()
	buf.resize(16 + _raw.size() * 12)
	var magic := CACHE_MAGIC.to_ascii_buffer()
	for i in 4:
		buf[i] = magic[i]
	buf.encode_u32(4, CACHE_VERSION)
	buf.encode_float(8, _damage)
	buf.encode_u32(12, _raw.size())
	var off := 16
	for c: Vector2i in _raw:
		buf.encode_s32(off, c.x)
		buf.encode_s32(off + 4, c.y)
		buf.encode_float(off + 8, float(_raw[c]))
		off += 12
	job.payload = buf
	return job


func flush_cache_async() -> void:
	if _write_task >= 0:
		poll_cache_write()
	if _write_task >= 0 or not _cache_enabled or _save_id == "" or _surface_index < 0 or not _dirty_disk:
		return
	_dirty_disk = false
	var job := _prepare_cache_write_job()
	if job == null:
		return
	_write_job = job
	_write_task = WorkerThreadPool.add_task(Callable(job, "run"), false, "pollution_cache_write")


func flush_cache() -> void:
	wait_cache_write()
	if not _cache_enabled or _save_id == "" or _surface_index < 0 or not _dirty_disk:
		return
	_dirty_disk = false
	var job := _prepare_cache_write_job()
	if job != null:
		job.run()


func _load_disk_cache(si: int) -> bool:
	var rel := _cache_file_path(si)
	if rel == "":
		return false
	var abs_path := ProjectSettings.globalize_path(rel)
	if not FileAccess.file_exists(abs_path) or SafeDelete.is_link(abs_path):
		return false
	var f := FileAccess.open_compressed(abs_path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		return false
	var hdr := f.get_buffer(16)
	if hdr.size() < 16 or hdr.slice(0, 4).get_string_from_ascii() != CACHE_MAGIC:
		f.close()
		return false
	if hdr.decode_u32(4) != CACHE_VERSION:
		f.close()
		return false
	_damage = maxf(1.0, hdr.decode_float(8))
	var cnt := hdr.decode_u32(12)
	if cnt > 262144:
		f.close()
		return false
	var buf := f.get_buffer(cnt * 12)
	f.close()
	if buf.size() < int(cnt * 12):
		return false
	for i in cnt:
		var off := i * 12
		var c := Vector2i(buf.decode_s32(off), buf.decode_s32(off + 4))
		var p := buf.decode_float(off + 8)
		if p > 0.0:
			var lvl := levels(p, _damage)
			if lvl != Vector2.ZERO:
				_raw[c] = p
				_target[c] = lvl
				_shown[c] = lvl
	_dirty_disk = false
	return true


## Switches active surface, preserving per-surface cached pollution when `keep_cache` is true.
func set_surface(si: int, keep_cache := true) -> void:
	if not keep_cache:
		clear()
		_surface_index = si
		_write()
		return
	if si == _surface_index:
		return
	flush_cache()
	if _surface_index >= 0 and _cache_enabled:
		if _raw.is_empty():
			_surface_cache.erase(_surface_index)
		else:
			_surface_cache[_surface_index] = {"damage": _damage, "raw": _raw.duplicate()}
	_target.clear()
	_shown.clear()
	_raw.clear()
	_live_rect = Rect2i()
	_smog_chunks = []
	_smog_version += 1
	_easing = false
	_redraw = true
	_write_timer = 0.0
	_dirty_disk = false
	_flush_timer = 0.0
	_surface_index = si
	if _cache_enabled and si >= 0 and _surface_cache.has(si):
		var saved: Dictionary = _surface_cache[si]
		_damage = maxf(1.0, float(saved.get("damage", _damage)))
		var raw_dict: Variant = saved.get("raw")
		if raw_dict is Dictionary:
			for k: Variant in raw_dict as Dictionary:
				if k is Vector2i:
					var c: Vector2i = k
					var p := float((raw_dict as Dictionary)[k])
					if p > 0.0:
						var level := levels(p, _damage)
						if level != Vector2.ZERO:
							_raw[c] = p
							_target[c] = level
							_shown[c] = level
	elif _cache_enabled and si >= 0 and _save_id != "":
		_load_disk_cache(si)
	_write()


## A new game or full reset: wipes active and per-surface pollution immediately.
func clear() -> void:
	wait_cache_write()
	_target.clear()
	_shown.clear()
	_raw.clear()
	_surface_cache.clear()
	_live_rect = Rect2i()
	_smog_chunks = []
	_smog_version += 1
	_easing = false
	_redraw = true
	_write_timer = 0.0
	_dirty_disk = false
	_flush_timer = 0.0


func _trim_cache() -> void:
	if _target.size() <= CACHE_MAX_CHUNKS:
		return
	var focus := _focus_chunk
	var by_dist := func(a: Vector2i, b: Vector2i) -> bool:
		return a.distance_squared_to(focus) > b.distance_squared_to(focus)
	var keys: Array = _target.keys()
	keys.sort_custom(by_dist)
	var drop := _target.size() - CACHE_MAX_CHUNKS
	for i in drop:
		var c: Vector2i = keys[i]
		_target.erase(c)
		_raw.erase(c)


## (dying, smog), each 0 to 1, for `p` pollution on a map whose trees take damage from `damage`.
static func levels(p: float, damage: float) -> Vector2:
	var dying := clampf(log(p / damage) / log(BARE), 0.0, 1.0) if p > damage else 0.0
	var smog := 0.0
	if p > SMOG_FROM:
		smog = clampf(log(p / SMOG_FROM) / log(SMOG_FULL / SMOG_FROM), 0.0, 1.0)
	return Vector2(dying, smog)


func set_volumetric(on: bool) -> void:
	_volumetric = on
	_material.set_shader_parameter("volumetric", 1.0 if on else 0.0)


func is_volumetric() -> bool:
	return _volumetric


## Every frame: the view's focus (tiles), the game's darkness (0 day to about 0.85 at night),
## delta seconds, and optional atmosphere snapshot for volumetric scattering and cloud shadows.
func update(at: Vector2, darkness: float, delta: float, atmo := {}) -> void:
	var chunk := Vector2i(floori(at.x / 32.0), floori(at.y / 32.0))
	_focus_chunk = chunk
	var middle := _origin + Vector2i(SIZE / 2, SIZE / 2)
	if absi(chunk.x - middle.x) > RECENTRE or absi(chunk.y - middle.y) > RECENTRE:
		_origin = chunk - Vector2i(SIZE / 2, SIZE / 2)
		_redraw = true
	var far_half := (FAR_SIZE * FAR_CELL_CHUNKS) / 2
	var far_mid := _far_origin + Vector2i(far_half, far_half)
	if absi(chunk.x - far_mid.x) > 32 or absi(chunk.y - far_mid.y) > 32:
		_far_origin = Vector2i(
			floori(float(chunk.x - far_half) / float(FAR_CELL_CHUNKS)) * FAR_CELL_CHUNKS,
			floori(float(chunk.y - far_half) / float(FAR_CELL_CHUNKS)) * FAR_CELL_CHUNKS)
		_redraw = true
	if _easing:
		_ease(delta)
	_write_timer -= delta
	if _redraw and _write_timer <= 0.0:
		_write_timer = WRITE_EVERY
		_redraw = false
		_write()
	poll_cache_write()
	if _dirty_disk:
		_flush_timer += delta
		if _flush_timer >= FLUSH_INTERVAL and _write_task < 0:
			_flush_timer = 0.0
			flush_cache_async()
	_material.set_shader_parameter("light", clampf(1.0 - darkness * 0.9, 0.12, 1.0))
	var space := bool(atmo.get("space", false))
	# Only while smog can show in view: the pass reads the depth and does its sums on every pixel
	# before discarding them (estimated at 0.1 ms at 4K), and any pollution in the bridge's 25 x 25
	# chunks round the focus kept it on wherever the view was.
	_quad.visible = _strength > 0.001 and not space and smog_in_view()
	if _quad.visible:
		_material.set_shader_parameter("ground_range", GroundHeight.lift_range())
		if not atmo.is_empty():
			var raw_sun: Variant = atmo.get("sun_dir", Vector3(0.0, 0.7, -0.7))
			var sun_dir: Vector3 = raw_sun if raw_sun is Vector3 else Vector3(0.0, 0.7, -0.7)
			var raw_sun_color: Variant = atmo.get("sun_color", Color.WHITE)
			var sun_color: Color = raw_sun_color if raw_sun_color is Color else Color.WHITE
			var raw_amb_color: Variant = atmo.get("ambient_color", Color(0.75, 0.78, 0.82))
			var amb_color: Color = raw_amb_color if raw_amb_color is Color else Color(0.75, 0.78, 0.82)
			var raw_scene: Variant = atmo.get("scene_light", Vector2.ONE)
			var scene_light: Vector2 = raw_scene if raw_scene is Vector2 else Vector2.ONE
			_material.set_shader_parameter("sun_dir", sun_dir)
			_material.set_shader_parameter("sun_color", sun_color)
			_material.set_shader_parameter("ambient_color", amb_color)
			_material.set_shader_parameter("sun_strength", float(atmo.get("sun_strength", 1.0)))
			_material.set_shader_parameter("twilight", float(atmo.get("twilight", 0.0)))
			_material.set_shader_parameter("scene_light", scene_light)
			PlanetSky.apply_cloud_uniforms(_material, atmo, _cloud_cache)


## Whether a chunk the smog pass can read for the camera now holds smog.
func smog_in_view() -> bool:
	if _smog_chunks.is_empty():
		return false
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return true
	var pad := 2 if _volumetric else 1
	var view: Variant = view_chunks(cam, get_viewport().get_visible_rect().size, GroundHeight.lift_range().x - LAYER_BELOW, pad)
	if not (view is Rect2i):
		return true
	var rect: Rect2i = view
	if rect == _seen_rect and _seen_version == _smog_version:
		return _seen
	_seen_rect = rect
	_seen_version = _smog_version
	_seen = false
	if rect.intersects(_smog_bounds):
		for c in _smog_chunks:
			if rect.has_point(c):
				_seen = true
				break
	return _seen


## The chunks the smog pass can read for this camera: every pixel's ray is cut to the layer before
## its pollution is read, so what it reads lies between the camera and where the screen's corners
## meet the layer's bottom (`low`); and `pad` chunks round that, as the pass reads between chunk
## centres and blurred aloft smog overhangs chunk edges. null when a corner doesn't come down to
## it (the horizon in view): anything may then show.
static func view_chunks(cam: Camera3D, screen: Vector2, low: float, pad := 1) -> Variant:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p: Vector2 in [Vector2.ZERO, Vector2(screen.x, 0.0), Vector2(0.0, screen.y), screen]:
		var origin := cam.project_ray_origin(p)
		var ray := cam.project_ray_normal(p)
		if origin.y <= low or ray.y > -0.01:
			return null
		var hit := origin + ray * ((low - origin.y) / ray.y)
		for q: Vector2 in [Vector2(origin.x, origin.z), Vector2(hit.x, hit.z)]:
			lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
			hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
	var a := Vector2i(floori(lo.x / 32.0) - pad, floori(lo.y / 32.0) - pad)
	var b := Vector2i(floori(hi.x / 32.0) + pad, floori(hi.y / 32.0) + pad)
	return Rect2i(a, b - a + Vector2i.ONE)


## Moves every shown level towards its target; those that reach 0 are let go.
func _ease(delta: float) -> void:
	var step := delta / EASE
	var moving := false
	for c in _target:
		if not _shown.has(c):
			_shown[c] = Vector2.ZERO
	for c in _shown.keys():
		var now: Vector2 = _shown[c]
		var want: Vector2 = _target.get(c, Vector2.ZERO)
		if now == want:
			if want == Vector2.ZERO:
				_shown.erase(c)
			continue
		var next := Vector2(move_toward(now.x, want.x, step), move_toward(now.y, want.y, step))
		_shown[c] = next
		moving = true
	_easing = moving
	_redraw = true


## The shown levels into the RGBA8 texture (R dying, G local smog, B blurred aloft smog). Writes a
## copy, as remote_fog.gd does: with the renderer on its own thread the upload happens there later.
func _write() -> void:
	_ensure_textures()
	_image.fill(Color(0.0, 0.0, 0.0, 1.0))
	if _far_cur.size() != FAR_SIZE * FAR_SIZE:
		_far_cur.resize(FAR_SIZE * FAR_SIZE)
	if _far_prev.size() != FAR_SIZE * FAR_SIZE:
		_far_prev.resize(FAR_SIZE * FAR_SIZE)
		_far_prev.fill(0)
	_far_cur.fill(0)
	var want_smog := _strength > 0.001
	if want_smog:
		if _local_grid.size() != SIZE * SIZE:
			_local_grid.resize(SIZE * SIZE)
		if _blur_tmp.size() != SIZE * SIZE:
			_blur_tmp.resize(SIZE * SIZE)
		_local_grid.fill(0.0)
	var bounds := Rect2i(Vector2i.ZERO, Vector2i(SIZE, SIZE))
	var smoggy: Array[Vector2i] = []
	var smog_bounds := Rect2i()
	var has_smog := false
	var min_x := SIZE
	var min_y := SIZE
	var max_x := -1
	var max_y := -1
	for c: Vector2i in _shown:
		var v: Vector2 = _shown[c]
		var fx := floori(float(c.x - _far_origin.x) / float(FAR_CELL_CHUNKS))
		var fy := floori(float(c.y - _far_origin.y) / float(FAR_CELL_CHUNKS))
		if fx >= 0 and fx < FAR_SIZE and fy >= 0 and fy < FAR_SIZE:
			var b := roundi(clampf(v.x, 0.0, 1.0) * 255.0)
			var fidx := fy * FAR_SIZE + fx
			if b > _far_cur[fidx]:
				_far_cur[fidx] = b
		var local := c - _origin
		if bounds.has_point(local):
			_image.set_pixelv(local, Color(v.x, v.y, 0.0, 1.0))
			if want_smog:
				_local_grid[local.y * SIZE + local.x] = v.y
				if v.y >= SMOG_SHOWN:
					has_smog = true
					min_x = mini(min_x, local.x)
					min_y = mini(min_y, local.y)
					max_x = maxi(max_x, local.x)
					max_y = maxi(max_y, local.y)
	if has_smog:
		var bx0 := maxi(0, min_x - ALOFT_RADIUS)
		var by0 := maxi(0, min_y - ALOFT_RADIUS)
		var bx1 := mini(SIZE - 1, max_x + ALOFT_RADIUS)
		var by1 := mini(SIZE - 1, max_y + ALOFT_RADIUS)
		var weights: Array[float] = [0.12, 0.22, 0.32, 0.22, 0.12]
		for y in range(by0, by1 + 1):
			var row_off := y * SIZE
			for x in range(bx0, bx1 + 1):
				var hsum := 0.0
				for k in range(-ALOFT_RADIUS, ALOFT_RADIUS + 1):
					var sx := x + k
					if sx >= 0 and sx < SIZE:
						hsum += weights[k + ALOFT_RADIUS] * _local_grid[row_off + sx]
				_blur_tmp[row_off + x] = hsum
		for y in range(by0, by1 + 1):
			var row_off := y * SIZE
			for x in range(bx0, bx1 + 1):
				var vsum := 0.0
				for k in range(-ALOFT_RADIUS, ALOFT_RADIUS + 1):
					var sy := y + k
					if sy >= by0 and sy <= by1:
						vsum += weights[k + ALOFT_RADIUS] * _blur_tmp[sy * SIZE + x]
				var local_g := _local_grid[row_off + x]
				var aloft := clampf(maxf(local_g * 0.72, vsum * 1.18), 0.0, 1.0)
				if local_g >= SMOG_SHOWN or aloft >= SMOG_SHOWN:
					var col := _image.get_pixel(x, y)
					col.b = aloft
					col.a = 1.0
					_image.set_pixel(x, y, col)
					var c := _origin + Vector2i(x, y)
					smog_bounds = Rect2i(c, Vector2i.ONE) if smoggy.is_empty() else smog_bounds.merge(Rect2i(c, Vector2i.ONE))
					smoggy.append(c)
	if smoggy != _smog_chunks:
		_smog_chunks = smoggy
		_smog_bounds = smog_bounds
		_smog_version += 1
	_texture.update(_image.duplicate() as Image)
	if _far_cur != _far_prev:
		_far_image.set_data(FAR_SIZE, FAR_SIZE, false, Image.FORMAT_R8, _far_cur)
		_far_prev = _far_cur.duplicate()
		_far_texture.update(_far_image.duplicate() as Image)
		_far_version += 1
	var on := 0.0 if _shown.is_empty() else 1.0
	RenderingServer.global_shader_parameter_set(GLOBAL_RECT, Vector4(_origin.x * 32.0, _origin.y * 32.0, 32.0, on))


## The Smog setting as drawn now, 0 to 1 (settings_probe.gd reads it).
func strength() -> float:
	return _strength


func _on_setting(section: String, key: String) -> void:
	if section == "graphics" and key == "smog":
		_read_setting()


func _read_setting() -> void:
	var prev := _strength
	_strength = clampf(float(Settings.get_value("graphics", "smog")), 0.0, 1.0)
	_material.set_shader_parameter("strength", _strength)
	if (prev <= 0.001) != (_strength <= 0.001):
		_redraw = true
		_write_timer = 0.0
