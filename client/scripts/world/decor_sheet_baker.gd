extends Node
## GPU flat-decorative sheet baker (decoratives.gd): composites all overlapping flat decoratives in a
## chunk once inside a top-down orthographic SubViewport in Factorio's exact render-layer order,
## straightens premultiplied alpha + dilates 1 texel on the GPU, reads back asynchronously without
## stalling the frame, and builds mipmaps / optional S3TC compression on a WorkerThreadPool task.

const SHADER_BAKE := preload("res://shaders/decorative_bake.gdshader")
const SHADER_UNPREMUL := preload("res://shaders/decorative_sheet_unpremul.gdshader")

const CHUNK := 32
const IDLE_SHRINK_SEC := 10.0
const READBACK_TIMEOUT_FRAMES := 180

const STATE_IDLE := 0
const STATE_WAIT_BAKE := 1
const STATE_WAIT_UNPREMUL := 2
const STATE_WAIT_READBACK := 3


## Thread-safe mailbox passed to RenderingDevice async readback callbacks; kept standalone so a
## freed or reset baker never leaves dangling Node references on the render thread.
class ReadbackInbox:
	var mutex := Mutex.new()
	var results: Array = []
	var cancelled := false


## Worker-thread payload turning raw readback bytes into an ImageTexture (or Image when uploading on
## the main thread).
class PostJob:
	var chunk := Vector2i.ZERO
	var gen := 0
	var size := 0
	var bytes := PackedByteArray()
	var width := 0
	var height := 0
	var bgra := false
	var gpu_dilated := false
	var compress := false
	var upload_on_worker := true
	var empty := false
	var image: Image
	var texture: ImageTexture


var _bake_vp: SubViewport
var _bake_cam: Camera3D
var _bake_root: Node3D
var _unpremul_vp: SubViewport
var _unpremul_rect: ColorRect
var _unpremul_mat: ShaderMaterial

var _cur_size := 0
var _state := STATE_IDLE
var _token := 0
var _wait_frames := 0
var _idle_sec := 0.0

var _active_chunk := Vector2i.ZERO
var _active_gen := 0
var _active_size := 0
var _active_compress := false
var _active_upload := true
var _active_swapped_rb := false
const PROBE_NONE := -1
const PROBE_INVALID := 2
var _bgra_cached := -1  # -1 unknown, 0 not BGRA, 1 BGRA (viewport format, read once on the render thread)
var _probe_result := PROBE_NONE

var _inbox := ReadbackInbox.new()
var _post_jobs: Array = []  # [task_id, PostJob]
var _warned_timeout := false


static func gpu_available() -> bool:
	return DisplayServer.get_name() != "headless" and RenderingServer.get_rendering_device() != null


func is_idle() -> bool:
	return _state == STATE_IDLE


func current_size() -> int:
	return _cur_size


func busy() -> bool:
	return _state != STATE_IDLE or not _post_jobs.is_empty()


func has_pending(c: Vector2i) -> bool:
	if _state != STATE_IDLE and _active_chunk == c:
		return true
	for entry: Array in _post_jobs:
		var job: PostJob = entry[1]
		if job.chunk == c:
			return true
	return false


func start_bake(c: Vector2i, gen: int, size: int, sources: Array, compress: bool, upload_on_worker: bool) -> bool:
	if _state != STATE_IDLE or not gpu_available() or not is_inside_tree():
		return false
	_ensure_viewports(size)
	_clear_bake_root()
	_bake_cam.position = Vector3(c.x * CHUNK + CHUNK * 0.5, 10.0, c.y * CHUNK + CHUNK * 0.5)
	var bounds := AABB(Vector3(c.x * CHUNK - 16.0, -4.0, c.y * CHUNK - 16.0), Vector3(CHUNK + 32.0, 8.0, CHUNK + 32.0))
	for src in sources:
		if not (src is Array) or src.size() < 4:
			continue
		var mesh: Mesh = src[0]
		var mat: Material = src[1]
		var buf: PackedFloat32Array = src[2]
		var count := int(src[3])
		if mesh == null or mat == null or count <= 0:
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = mesh
		mm.instance_count = count
		mm.buffer = buf
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.custom_aabb = bounds
		mmi.ignore_occlusion_culling = true
		_bake_root.add_child(mmi)
	_active_chunk = c
	_active_gen = gen
	_active_size = size
	_active_compress = compress
	_active_upload = upload_on_worker
	_token += 1
	_idle_sec = 0.0
	_bake_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	_state = STATE_WAIT_BAKE
	return true


func step(delta: float, on_finished: Callable) -> void:
	_poll_post_jobs(on_finished)
	match _state:
		STATE_WAIT_BAKE:
			_clear_bake_root()
			var up_tex := _unpremul_vp.get_texture()
			var up_rid := up_tex.get_rid() if up_tex != null else RID()
			# The format is read once on the render thread (texture_get_format is render-thread only
			# with a separate render thread) and cached; the bake waits a frame for the first answer.
			if _bgra_cached < 0:
				if _probe_result == PROBE_NONE:
					RenderingServer.call_on_render_thread(_probe_format.bind(up_rid))
					if _probe_result == PROBE_NONE:
						return
				var pr := _probe_result
				_probe_result = PROBE_NONE
				if pr == PROBE_INVALID:
					_active_swapped_rb = false
				else:
					_bgra_cached = pr
					_active_swapped_rb = pr == 1
			else:
				_active_swapped_rb = _bgra_cached == 1
			_unpremul_mat.set_shader_parameter(&"swap_rb", _active_swapped_rb)
			_unpremul_mat.set_shader_parameter(&"src", _bake_vp.get_texture())
			_unpremul_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
			_state = STATE_WAIT_UNPREMUL
		STATE_WAIT_UNPREMUL:
			var vp_tex := _unpremul_vp.get_texture()
			var vp_rid := vp_tex.get_rid() if vp_tex != null else RID()
			_wait_frames = 0
			_state = STATE_WAIT_READBACK
			RenderingServer.call_on_render_thread(_request_readback.bind(vp_rid, _token, _inbox, _active_swapped_rb))
		STATE_WAIT_READBACK:
			var got: Variant = _take_inbox(_token)
			if got is Dictionary:
				var rec: Dictionary = got
				var bytes: PackedByteArray = rec.get("bytes", PackedByteArray())
				var w := int(rec.get("width", 0))
				var h := int(rec.get("height", 0))
				var bgra := bool(rec.get("bgra", false))
				if bytes.is_empty() or w <= 0 or h <= 0 or bytes.size() != w * h * 4:
					on_finished.call(_active_chunk, _active_gen, _active_size, null, true)
				else:
					var job := PostJob.new()
					job.chunk = _active_chunk
					job.gen = _active_gen
					job.size = _active_size
					job.bytes = bytes
					job.width = w
					job.height = h
					job.bgra = bgra
					job.gpu_dilated = true
					job.compress = _active_compress
					job.upload_on_worker = _active_upload
					var tid := WorkerThreadPool.add_task(post_process.bind(job), false, "decor_sheet")
					_post_jobs.append([tid, job])
				_state = STATE_IDLE
			else:
				_wait_frames += 1
				if _wait_frames > READBACK_TIMEOUT_FRAMES:
					if not _warned_timeout:
						_warned_timeout = true
						push_warning("DecorSheetBaker: async readback timed out for chunk %s" % [_active_chunk])
					on_finished.call(_active_chunk, _active_gen, _active_size, null, true)
					_state = STATE_IDLE
		STATE_IDLE:
			if _post_jobs.is_empty() and _cur_size > 4:
				_idle_sec += delta
				if _idle_sec >= IDLE_SHRINK_SEC:
					_ensure_viewports(4)


func reset() -> void:
	_inbox.mutex.lock()
	_inbox.cancelled = true
	_inbox.results.clear()
	_inbox.mutex.unlock()
	_inbox = ReadbackInbox.new()
	_token += 1
	_state = STATE_IDLE
	_wait_frames = 0
	_idle_sec = 0.0
	_clear_bake_root()


func shutdown() -> void:
	reset()
	for entry: Array in _post_jobs:
		var tid := int(entry[0])
		if tid >= 0:
			WorkerThreadPool.wait_for_task_completion(tid)
	_post_jobs.clear()


func _exit_tree() -> void:
	shutdown()


## Worker-safe processing of raw RGBA8/BGRA8 readback pixels: swaps channels if BGRA, checks for
## completely transparent sheets, dilates edge pixels into transparent neighbours, builds mipmaps,
## optionally block-compresses on editor builds, and optionally creates the GPU texture.
static func post_process(job: PostJob) -> void:
	var expected := job.width * job.height * 4
	if job.width <= 0 or job.height <= 0 or job.bytes.size() != expected:
		job.empty = true
		return
	var data := job.bytes
	if job.bgra:
		data = job.bytes.duplicate()
		for i in range(0, expected, 4):
			var tmp := data[i]
			data[i] = data[i + 2]
			data[i + 2] = tmp
	var img := Image.create_from_data(job.width, job.height, false, Image.FORMAT_RGBA8, data)
	if img == null or img.is_invisible():
		job.empty = true
		return
	if not job.gpu_dilated:
		img.fix_alpha_edges()
	img.generate_mipmaps()
	if job.compress:
		img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_GENERIC)
	if job.upload_on_worker:
		job.texture = ImageTexture.create_from_image(img)
	else:
		job.image = img


func _poll_post_jobs(on_finished: Callable) -> void:
	var kept: Array = []
	for entry: Array in _post_jobs:
		var tid := int(entry[0])
		var job: PostJob = entry[1]
		if WorkerThreadPool.is_task_completed(tid):
			WorkerThreadPool.wait_for_task_completion(tid)
			if not job.empty and job.texture == null and job.image != null:
				job.texture = ImageTexture.create_from_image(job.image)
				job.image = null
			on_finished.call(job.chunk, job.gen, job.size, job.texture, job.empty)
		else:
			kept.append(entry)
	_post_jobs = kept


func _take_inbox(token: int) -> Variant:
	_inbox.mutex.lock()
	var found: Variant = null
	var remaining: Array = []
	for item in _inbox.results:
		if item is Dictionary and int((item as Dictionary).get("token", -1)) == token:
			found = item
		elif item is Dictionary and int((item as Dictionary).get("token", -1)) > token:
			remaining.append(item)
	_inbox.results = remaining
	_inbox.mutex.unlock()
	return found


func _ensure_viewports(size: int) -> void:
	if _bake_vp == null:
		var env := Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.0, 0.0, 0.0, 0.0)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
		env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
		env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		env.tonemap_exposure = 1.0
		env.glow_enabled = false

		var w3d := World3D.new()
		w3d.environment = env

		_bake_vp = SubViewport.new()
		_bake_vp.name = "BakeVP"
		_bake_vp.own_world_3d = true
		_bake_vp.world_3d = w3d
		_bake_vp.transparent_bg = true
		_bake_vp.use_hdr_2d = true
		_bake_vp.msaa_3d = Viewport.MSAA_DISABLED
		_bake_vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		_bake_vp.scaling_3d_scale = 1.0
		_bake_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_bake_vp.size = Vector2i(size, size)

		_bake_cam = Camera3D.new()
		_bake_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		_bake_cam.size = float(CHUNK)
		_bake_cam.keep_aspect = Camera3D.KEEP_WIDTH
		_bake_cam.near = 0.05
		_bake_cam.far = 20.0
		_bake_cam.basis = Basis(Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector3(0.0, 1.0, 0.0))
		_bake_cam.current = true
		_bake_vp.add_child(_bake_cam)

		_bake_root = Node3D.new()
		_bake_root.name = "Sources"
		_bake_vp.add_child(_bake_root)
		add_child(_bake_vp)

		_unpremul_vp = SubViewport.new()
		_unpremul_vp.name = "UnpremulVP"
		_unpremul_vp.disable_3d = true
		_unpremul_vp.transparent_bg = true
		_unpremul_vp.use_hdr_2d = false
		_unpremul_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_unpremul_vp.size = Vector2i(size, size)

		_unpremul_mat = ShaderMaterial.new()
		_unpremul_mat.shader = SHADER_UNPREMUL
		_unpremul_mat.set_shader_parameter(&"src", _bake_vp.get_texture())

		_unpremul_rect = ColorRect.new()
		_unpremul_rect.position = Vector2.ZERO
		_unpremul_rect.size = Vector2(size, size)
		_unpremul_rect.color = Color.WHITE
		_unpremul_rect.material = _unpremul_mat
		_unpremul_vp.add_child(_unpremul_rect)
		add_child(_unpremul_vp)
		_cur_size = size
		return
	if _cur_size != size:
		_cur_size = size
		_bake_vp.size = Vector2i(size, size)
		_unpremul_vp.size = Vector2i(size, size)
		_unpremul_rect.size = Vector2(size, size)


func _clear_bake_root() -> void:
	if _bake_root == null:
		return
	for child: Node in _bake_root.get_children():
		_bake_root.remove_child(child)
		child.queue_free()


## Runs on the render thread (via call_on_render_thread); stores 1 (BGRA), 0 (other) or PROBE_INVALID.
func _probe_format(vp_rid: RID) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not vp_rid.is_valid():
		_probe_result = PROBE_INVALID
		return
	var rd_tex := RenderingServer.texture_get_rd_texture(vp_rid)
	if not rd_tex.is_valid():
		_probe_result = PROBE_INVALID
		return
	var fmt := rd.texture_get_format(rd_tex)
	var is_bgra := fmt.format == RenderingDevice.DATA_FORMAT_B8G8R8A8_UNORM or fmt.format == RenderingDevice.DATA_FORMAT_B8G8R8A8_SRGB
	_probe_result = 1 if is_bgra else 0


static func _request_readback(vp_rid: RID, token: int, inbox: ReadbackInbox, swapped_rb: bool = false) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not vp_rid.is_valid():
		_push_empty(token, inbox)
		return
	var rd_tex := RenderingServer.texture_get_rd_texture(vp_rid)
	if not rd_tex.is_valid():
		_push_empty(token, inbox)
		return
	var fmt := rd.texture_get_format(rd_tex)
	var bgra := fmt.format == RenderingDevice.DATA_FORMAT_B8G8R8A8_UNORM or fmt.format == RenderingDevice.DATA_FORMAT_B8G8R8A8_SRGB
	var rgba := fmt.format == RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM or fmt.format == RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB
	if not bgra and not rgba:
		push_warning("DecorSheetBaker: unexpected viewport format %d" % [fmt.format])
		_push_empty(token, inbox)
		return
	var need_swap := bgra and not swapped_rb
	var cb := _on_readback.bind(token, int(fmt.width), int(fmt.height), need_swap, inbox)
	if rd.texture_get_data_async(rd_tex, 0, cb) != OK:
		_push_empty(token, inbox)


static func _on_readback(bytes: PackedByteArray, token: int, width: int, height: int, bgra: bool, inbox: ReadbackInbox) -> void:
	inbox.mutex.lock()
	if not inbox.cancelled:
		inbox.results.append({"token": token, "bytes": bytes, "width": width, "height": height, "bgra": bgra})
	inbox.mutex.unlock()


static func _push_empty(token: int, inbox: ReadbackInbox) -> void:
	inbox.mutex.lock()
	if not inbox.cancelled:
		inbox.results.append({"token": token, "bytes": PackedByteArray(), "width": 0, "height": 0, "bgra": false})
	inbox.mutex.unlock()
