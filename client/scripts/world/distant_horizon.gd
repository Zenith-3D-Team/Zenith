extends Node3D
## Distant Horizon controller: manages LOD 0..4 quadtree sections around the camera,
## background chunk baking & section greedy-meshing on WorkerThreadPool, loaded-chunk
## mask discarding for LOD 0 (keeping Early-Z on LOD 1..4), radial horizon mist fade,
## and FrameBudget-sliced mesh installation.

const FreeLater := preload("res://scripts/world/free_later.gd")
const LodData := preload("res://scripts/world/lod_data.gd")
const LodCache := preload("res://scripts/world/lod_cache.gd")
const LodMesher := preload("res://scripts/world/lod_mesher.gd")
const TerrainTextures := preload("res://scripts/world/terrain_textures.gd")
const FrameBudget := preload("res://scripts/world/frame_budget.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const ViewPriority := preload("res://scripts/world/view_priority.gd")
const Probing := preload("res://scripts/debug/probing.gd")

const SolidShader := preload("res://shaders/lod_solid.gdshader")
const SolidMaskedShader := preload("res://shaders/lod_solid_masked.gdshader")
const WaterShader := preload("res://shaders/lod_water.gdshader")
const WaterMaskedShader := preload("res://shaders/lod_water_masked.gdshader")
const Switches := preload("res://scripts/switches.gd")

const CHUNK := 32
const MASK_SIZE := 128
const MASK_RECENTER := 16
const SECTION_CHUNKS := [4, 8, 16, 32, 64]
const RING_REACH := [24, 56, 120, 248, 512]
const RING_REACH_PRESETS := {
	"near": [16, 40, 88, 192, 512],
	"balanced": [24, 56, 120, 248, 512],
	"far": [36, 84, 168, 320, 512],
}
const QUALITY_CELL_TILES := {
	"minimal": [8.0, 16.0, 32.0, 64.0, 64.0],
	"low": [4.0, 16.0, 32.0, 64.0, 64.0],
	"medium": [4.0, 8.0, 16.0, 32.0, 64.0],
	"high": [2.0, 4.0, 8.0, 16.0, 32.0],
	"ultra": [2.0, 2.0, 4.0, 8.0, 16.0],
}
const QUALITY_DETAIL_TIERS := {
	"minimal": [1, 2, 3, 3, 3],
	"low": [0, 1, 2, 3, 3],
	"medium": [0, 1, 2, 2, 3],
	"high": [0, 0, 1, 2, 3],
	"ultra": [0, 0, 0, 1, 2],
}
const MAX_BUILD_JOBS := 6
const MAX_DISPATCH_PER_FRAME := 4
const MAX_BAKE_JOBS := 4
const BAKE_QUEUE_BUDGET_USEC := 1200
const FALLBACK_INSTALL_USEC := 1500
const LOD_SUB_INTERVAL := 0.12
const LOD_SUB_BATCH := 64
const LOD_SUB_BATCH_COARSE := 256
const LAYOUT_HYSTERESIS := 8
const CACHE_FLUSH_INTERVAL := 10.0
const MASK_UPDATE_INTERVAL := 0.08
const MASK_FADE_SECONDS := 0.30
static var seam_fade := Switches.on("--dh-seam-fade")
static var handoff_guard := Switches.on("--dh-handoff")
const MASK_GRACE_FRAMES := 2
const HANDOFF_URGENT_TTL_MSEC := 5000
const TAKEOVER_READY_KEEP_FRAMES := 120
const PALETTE_POLL_INTERVAL := 3.0
const MAP_REFRESH_INTERVAL := 15.0
const MAP_IDLE_REFRESH_INTERVAL := 60.0
const REVS_REFRESH_INTERVAL := 20.0
const SCHEDULE_BUDGET_USEC := 1500
## The palette refresh (not --dh-palette=old): main-thread time a frame for checking sections against
## the colours that changed, and how long the sorted list of sections to build is reused before the
## next scan and sort (sooner when it runs out or chunks wait to be handed over).
const PALETTE_RECHECK_USEC := 1000
const SCHED_RESORT_MSEC := 250
const SUB_SCAN_BUDGET_USEC := 4000

# --- settings & CLI switches ------------------------------------------------------------------
var enabled := false
var radius_chunks := 0
var inner_chunks := 0
var quality := "medium"
var dropoff := "balanced"
var detail_lod_enabled := true
var glow_enabled := true

# --- runtime state ----------------------------------------------------------------------------
var _save_id := ""
var _surface_index := 0
var _protos_db: Object = null
var _palette: Object = null
var _cache: Object = null
var _cache_configured := false
var _pal_tex_gen := -1
var _pal_bakes_n := -1
var _pal_timer := 0.0
## --dh-palette=old: the colour table rebuilt on the main thread and every section drawn again, the
## sections to build scanned and sorted every frame (as before the run-spikes work).
var palette_old := false
var _pal_task := -1
var _pal_job: PaletteJob = null
var _pal_recheck: Array = []  # section keys still to check against the changed ids
var _pal_changed_tiles := PackedInt32Array()
var _pal_changed_ents := PackedInt32Array()
## Palette refreshes so far: [rebuilt, sections dirtied, sections kept] (tests, the spike log).
var palette_stats := [0, 0, 0]
var _sched_list: Array = []  # SectionState, best first, reused for SCHED_RESORT_MSEC
var _sched_msec := 0
var _sched_urgent_n := 0

var _mem_chunks := {}  # Vector2i -> LodChunk (or duck-typed chunk)
var _populated_sections := {}  # Vector3i(level, sx, sy) -> true
var _baked_sig := {}  # Vector2i -> Vector3i(rev, ent_count, tile_hash)

var _sections := {}  # Vector3i -> SectionState
var _retiring := []  # Array of {node: MeshInstance3D, rect: Rect2i}
var _layout_center := Vector2i(0x7fffffff, 0)
var _layout_radius := -1
var _layout_inner := -1
var _layout_quality := ""
var _layout_dropoff := ""
var _layout_detail_lod := true
var _next_serial := 1

var _mesh_jobs := []  # Array of [task_id, LodMesher]
var _ready_meshes := []  # Array of LodMesher deferred by FrameBudget
var _bake_jobs := []  # Array of [task_id, BakeJob]
var _bake_queue: Array[Vector2i] = []
var _bake_queued := {}  # Vector2i -> Array [cx, cy, rev, tile_ids, ent_values, protos, gen]
var _bake_frame := -1
var _bake_frame_usec := 0
var _surface_gen := 0

var _loaded_chunks := {}  # Vector2i -> true
var _pending_mask := {}  # Vector2i -> int remaining update() frames before promoting into _loaded_chunks
var _mask_levels := {}  # Vector2i -> float in (0..1), actively fading chunks
var _handoff_urgent := {}  # Vector2i -> int msec timestamp of unloading chunks awaiting DH takeover
var _takeover_ready_frame := {}  # Vector2i -> int _update_frame when unmasked, uploaded, and meshed
var _pending_bakes := {}  # Vector2i -> true chunks with active BakeJob in flight
var _update_frame := 0
var is_chunk_ready_cb: Callable
var _mask_image: Image
var _mask_texture: ImageTexture
var _mask_origin := Vector2i.ZERO
var _mask_origin_sent := Vector2i(0x7fffffff, 0)
var _mask_centered := false
var _mask_dirty := true
var _mask_force_upload := true
var _mask_upload_timer := 0.0
var _lod0_vis_dirty := true
var _has_dirty_sections := true

var _solid_mat: ShaderMaterial
var _solid_masked_mat: ShaderMaterial
var _water_mat: ShaderMaterial
var _water_masked_mat: ShaderMaterial

var _horizon_color := Color(0.7, 0.8, 0.88)
var _night_level := 0.0
var _is_space := false
var _sky_tint := Color(0.50, 0.62, 0.72)
var _mat_params_dirty := true
var _sent_horizon_color := Color(-1.0, -1.0, -1.0)
var _sent_night_level := -1.0
var _sent_radius_chunks := -1
var _sent_glow_enabled := true
var _sent_is_space := false
var _sent_sky_tint := Color(-1.0, -1.0, -1.0)
var _far_pol_tex: Texture2D = null
var _far_pol_rect := Vector4(0.0, 0.0, 128.0, 0.0)
var _far_pol_ver := -1

var _sub_timer := 0.0
var _flush_timer := 0.0
var _sub_q := 0
var _handshake_sent := false
var _map_timer := 0.0
var _revs_timer := 0.0
var _was_streaming := false
var _last_want_msec := 0
var _last_lod_rx_msec := 0
var _map_q := -1
var _map_parts_seen := 0
var _map_parts_total := 0
var _map_pending := {}  # Vector2i -> true
var _charted := {}  # Vector2i -> true
var _charted_sections := {}  # Vector3i(level, sx, sy) -> true
var _charted_known := false
## Not --dh-map=old: the charted map kept as its rows' runs (`lodm`'s own shape), not one entry a
## chunk: cy -> PackedInt32Array [x0, x1, ...] half-open, sorted; chunks charted by `lod` since the
## last map one by one; whether each section holds a charted chunk, worked out when first asked.
var map_old := false
var _charted_rows := {}
var _map_pending_rows := {}
var _charted_extra := {}
var _charted_sec_cache := {}
var _cached_region_revs := {}  # Vector2i -> int
var _known_region_revs := {}  # Vector2i -> int
var _missing_chunks := {}  # Vector2i -> true
var _stale_chunks := {}  # Vector2i -> true
var _in_flight := {}  # Vector2i -> int msec
var _requested_chunks := {}  # Vector2i -> int msec
var _prefer_far_batch := false


class SectionState:
	var key := Vector3i.ZERO
	var level := 0
	var sx := 0
	var sy := 0
	var sec_chunks := 4
	var cell_tiles := 4.0
	var grid_n := 32
	var detail_tier := 0
	var dirty := true
	var has_data := false
	var complete := false
	var needs_missing_scan := true
	var built_empty := false
	var building := false
	var serial := 0
	var next_sub_msec := 0
	var node: MeshInstance3D = null
	var tri_count := 0
	var built_chunk_mask := 0
	var dist_sq := 0.0
	var in_frustum := true
	## The last build's grid and the palette it used: a palette refresh dirties the section only
	## when one of the ids whose colours changed is in it.
	var grid_tiles := PackedInt32Array()
	var grid_protos := PackedInt32Array()
	var grid_pal: Object = null


## The colour table built on a worker from LodPalette.snapshot(), and what changed from the old one.
class PaletteJob:
	var snap := {}
	var old: Object = null
	var result: Object = null
	var changes: Array = []

	func run() -> void:
		result = LodData.LodPalette.from_snapshot(snap)
		snap = {}
		changes = LodData.LodPalette.diff(old as LodData.LodPalette, result as LodData.LodPalette) \
			if old is LodData.LodPalette else [PackedInt32Array(), PackedInt32Array(), true]


class BakeRec extends RefCounted:
	var proto_id := 0
	var pos := Vector2.ZERO
	var dir := 0
	var extra := {}


class BakeJob:
	var cx := 0
	var cy := 0
	var rev := 0
	var gen := 0
	var tile_ids := PackedInt32Array()
	var entities := {}
	var protos: Object = null
	var target_res := 4
	var result: Object = null

	func run() -> void:
		result = LodData.LodChunk.bake_from_world_chunk(cx, cy, rev, tile_ids, entities, protos, target_res)


func _init() -> void:
	apply_cli_overrides()


func _ready() -> void:
	_ensure_materials()


func _exit_tree() -> void:
	finish_all()
	_flush_cache()
	_clear_sections()


## Parses `--distant-horizon=off|<chunks>`, `--lod-night-glow=off`, `--distant-horizon-quality=...`,
## `--distant-horizon-dropoff=...`, and `--distant-horizon-detail-lod=...`.
static func cli_override(args: PackedStringArray = Switches.args()) -> Dictionary:
	var out := {}
	for arg: String in args:
		if arg.begins_with("--distant-horizon="):
			var val := arg.get_slice("=", 1).to_lower()
			if val == "off" or val == "0" or val == "false":
				out["enabled"] = false
				out["radius_chunks"] = 0
			elif val.is_valid_int():
				var r := clampi(int(val), 16, 512)
				out["enabled"] = r > 0
				out["radius_chunks"] = r
		elif arg == "--lod-night-glow=off":
			out["glow_enabled"] = false
		elif arg == "--lod-night-glow=on":
			out["glow_enabled"] = true
		elif arg.begins_with("--distant-horizon-quality="):
			var q := arg.get_slice("=", 1).to_lower()
			if QUALITY_CELL_TILES.has(q):
				out["quality"] = q
		elif arg.begins_with("--distant-horizon-dropoff="):
			var d := arg.get_slice("=", 1).to_lower()
			if RING_REACH_PRESETS.has(d):
				out["dropoff"] = d
		elif arg == "--distant-horizon-detail-lod=off" or arg == "--distant-horizon-detail-lod=false" or arg == "--distant-horizon-detail-lod=0":
			out["detail_lod_enabled"] = false
		elif arg == "--distant-horizon-detail-lod=on" or arg == "--distant-horizon-detail-lod=true" or arg == "--distant-horizon-detail-lod=1":
			out["detail_lod_enabled"] = true
		elif arg == "--dh-palette=old":
			out["palette_old"] = true
		elif arg == "--dh-map=old":
			out["map_old"] = true
	return out


func apply_cli_overrides(args: PackedStringArray = Switches.args()) -> void:
	var ov := cli_override(args)
	if ov.has("enabled"):
		enabled = bool(ov["enabled"])
	if ov.has("radius_chunks"):
		radius_chunks = int(ov["radius_chunks"])
	if ov.has("glow_enabled"):
		glow_enabled = bool(ov["glow_enabled"])
	if ov.has("quality"):
		quality = str(ov["quality"])
	if ov.has("dropoff"):
		dropoff = str(ov["dropoff"])
	if ov.has("detail_lod_enabled"):
		detail_lod_enabled = bool(ov["detail_lod_enabled"])
	if ov.has("palette_old"):
		palette_old = bool(ov["palette_old"])
	if ov.has("map_old"):
		map_old = bool(ov["map_old"])


## Returns non-overlapping, gap-free LOD 0..4 sections partitioning [-radius_chunks .. +radius_chunks]
## around `center_chunk`. Each level is aligned to the next level's section stride so concentric
## rings join strictly along section edges.
static func ring_sections(center_chunk: Vector2i, p_radius_chunks: int, inner_chunks: int = 0,
		quality_name: String = "medium", dropoff_name: String = "balanced") -> Array:
	if p_radius_chunks <= 0:
		return []
	var q_key := quality_name if QUALITY_CELL_TILES.has(quality_name) else "medium"
	var d_key := dropoff_name if RING_REACH_PRESETS.has(dropoff_name) else "balanced"
	var cell_list: Array = QUALITY_CELL_TILES[q_key]
	var reach_list: Array = RING_REACH_PRESETS[d_key]
	var tier_list: Array = QUALITY_DETAIL_TIERS[q_key]

	var r0 := mini(maxi(int(reach_list[0]), inner_chunks), p_radius_chunks)
	var r1 := mini(maxi(int(reach_list[1]), r0), p_radius_chunks)
	var r2 := mini(maxi(int(reach_list[2]), r1), p_radius_chunks)
	var r3 := mini(maxi(int(reach_list[3]), r2), p_radius_chunks)
	var r4 := p_radius_chunks
	var reaches := [r0, r1, r2, r3, r4]

	var last_level := 0
	for l in range(1, 5):
		if int(reaches[l]) > int(reaches[l - 1]):
			last_level = l

	var out: Array = []
	var prev_cover := Rect2i()
	for l in range(0, last_level + 1):
		var sec := int(SECTION_CHUNKS[l])
		var align := int(SECTION_CHUNKS[l + 1]) if l < last_level else sec
		var reach := int(reaches[l])
		var raw := Rect2i(center_chunk.x - reach, center_chunk.y - reach, reach * 2 + 1, reach * 2 + 1)
		if l > 0:
			raw = raw.merge(prev_cover)
		var cover := _snap_rect(raw, align)
		var ct := float(cell_list[l])
		var gn := roundi(float(sec * CHUNK) / ct)
		var dt := int(tier_list[l])
		var sx0 := floori(float(cover.position.x) / float(sec))
		var sx1 := floori(float(cover.end.x) / float(sec))
		var sy0 := floori(float(cover.position.y) / float(sec))
		var sy1 := floori(float(cover.end.y) / float(sec))
		for sy in range(sy0, sy1):
			for sx in range(sx0, sx1):
				var cr := Rect2i(sx * sec, sy * sec, sec, sec)
				if l > 0 and prev_cover.encloses(cr):
					continue
				out.append({
					"key": Vector3i(l, sx, sy),
					"level": l,
					"sx": sx,
					"sy": sy,
					"sec_chunks": sec,
					"cell_tiles": ct,
					"grid_n": gn,
					"detail_tier": dt,
					"chunk_rect": cr,
				})
		prev_cover = cover
	return out


static func _snap_rect(r: Rect2i, step: int) -> Rect2i:
	var x0 := floori(float(r.position.x) / float(step)) * step
	var y0 := floori(float(r.position.y) / float(step)) * step
	var x1 := ceili(float(r.end.x) / float(step)) * step
	var y1 := ceili(float(r.end.y) / float(step)) * step
	return Rect2i(x0, y0, x1 - x0, y1 - y0)


func configure(save_id: String, surface_index: int, protos: Object = null, model_bakes := {}) -> void:
	_save_id = save_id
	reset_surface(surface_index, protos, model_bakes)


func reset_surface(surface_index: int, protos: Object = null, model_bakes := {}) -> void:
	finish_all()
	_flush_cache()
	_surface_gen += 1
	_surface_index = surface_index
	_clear_sections()
	_mem_chunks.clear()
	_populated_sections.clear()
	_baked_sig.clear()
	_loaded_chunks.clear()
	_pending_mask.clear()
	_mask_levels.clear()
	_handoff_urgent.clear()
	_takeover_ready_frame.clear()
	_pending_bakes.clear()
	_bake_queue.clear()
	_bake_queued.clear()
	_requested_chunks.clear()
	_missing_chunks.clear()
	_stale_chunks.clear()
	_in_flight.clear()
	_charted.clear()
	_charted_sections.clear()
	_charted_rows.clear()
	_map_pending_rows.clear()
	_charted_extra.clear()
	_charted_sec_cache.clear()
	_map_pending.clear()
	_charted_known = false
	_map_q = -1
	_map_parts_seen = 0
	_map_parts_total = 0
	_known_region_revs.clear()
	_cached_region_revs.clear()
	_handshake_sent = false
	_was_streaming = false
	_prefer_far_batch = false
	_map_timer = 0.0
	_revs_timer = 0.0
	_last_want_msec = 0
	_last_lod_rx_msec = 0
	_cache_configured = false
	_layout_radius = -1
	_layout_inner = -1
	_layout_quality = ""
	_layout_dropoff = ""
	_mask_centered = false
	_mask_origin_sent = Vector2i(0x7fffffff, 0)
	_mask_dirty = true
	_mask_force_upload = true
	_mask_upload_timer = 0.0
	_lod0_vis_dirty = true
	_has_dirty_sections = true
	_mat_params_dirty = true

	if protos != null:
		ensure_palette_and_cache(protos, model_bakes)


func ensure_palette_and_cache(protos: Object, model_bakes := {}) -> void:
	if _cache_configured or protos == null:
		return
	_protos_db = protos
	_build_palette(protos, model_bakes)
	_configure_cache_from_palette()
	for k in _sections:
		var st: SectionState = _sections[k]
		if _populated_sections.has(k):
			st.has_data = true
		if st.has_data:
			st.dirty = true
			_has_dirty_sections = true
			_bump_serial(st)


func refresh_palette_if_needed(protos: Object, model_bakes: Dictionary, dt: float) -> void:
	if not enabled or radius_chunks <= 0 or protos == null:
		return
	if not (_palette is LodData.LodPalette):
		return
	if _pal_task >= 0:
		if WorkerThreadPool.is_task_completed(_pal_task):
			WorkerThreadPool.wait_for_task_completion(_pal_task)
			_pal_task = -1
			_apply_palette_job()
		return
	_pal_timer += dt
	if _pal_timer < PALETTE_POLL_INTERVAL:
		return
	_pal_timer = 0.0
	if TerrainTextures.generation == _pal_tex_gen and model_bakes.size() < _pal_bakes_n + 8:
		return
	_protos_db = protos
	var t0 := Time.get_ticks_usec()
	var why := "tex gen %d->%d bakes %d->%d" % [_pal_tex_gen, TerrainTextures.generation, _pal_bakes_n, model_bakes.size()]
	if palette_old:
		_build_palette(protos, model_bakes)
		var n := _dirty_all_sections()
		palette_stats[0] += 1
		palette_stats[1] += n
		Probing.count("dh_palette")
		Probing.add("dh_palette", t0)
		if Probing.on:
			print("DH palette rebuilt on the main thread %.1f ms, %d sections dirty (%s)" % [(Time.get_ticks_usec() - t0) / 1000.0, n, why])
		return
	_pal_job = PaletteJob.new()
	_pal_job.snap = LodData.LodPalette.snapshot(protos, model_bakes, true)
	_pal_job.old = _palette
	_pal_tex_gen = TerrainTextures.generation
	_pal_bakes_n = model_bakes.size()
	_pal_task = WorkerThreadPool.add_task(Callable(_pal_job, "run"), false, "DH palette")
	Probing.add("dh_palette", t0)
	if Probing.on:
		print("DH palette snapshot %.1f ms, building on a worker (%s)" % [(Time.get_ticks_usec() - t0) / 1000.0, why])


## Every section with data drawn again (the old refresh; a palette whose prototypes changed).
func _dirty_all_sections() -> int:
	var n := 0
	for k in _sections:
		var st: SectionState = _sections[k]
		if st.has_data:
			st.dirty = true
			_has_dirty_sections = true
			_bump_serial(st)
			n += 1
	_pal_recheck.clear()
	_pal_changed_tiles = PackedInt32Array()
	_pal_changed_ents = PackedInt32Array()
	return n


## The worker's colour table in: kept unless the palette was replaced meanwhile (a new surface);
## only the sections holding an id whose colours changed are drawn again, checked a slice a frame
## (_recheck_palette_sections); none when nothing changed.
func _apply_palette_job() -> void:
	var job := _pal_job
	_pal_job = null
	if job == null or job.result == null or job.old != _palette:
		return
	var t0 := Time.get_ticks_usec()
	_palette = job.result
	palette_stats[0] += 1
	Probing.count("dh_palette")
	var changes: Array = job.changes
	if bool(changes[2]):
		var n := _dirty_all_sections()
		palette_stats[1] += n
		if Probing.on:
			print("DH palette from a worker: prototypes changed, %d sections dirty" % n)
		return
	var ct: PackedInt32Array = changes[0]
	var ce: PackedInt32Array = changes[1]
	if ct.is_empty() and ce.is_empty():
		palette_stats[2] += _sections.size()
		if Probing.on:
			print("DH palette from a worker: no colour changed, no section dirty")
		return
	# Changes on top of a check still going: the merged ids, every section looked at again.
	for id in ct:
		if not _pal_changed_tiles.has(id):
			_pal_changed_tiles.append(id)
	for id in ce:
		if not _pal_changed_ents.has(id):
			_pal_changed_ents.append(id)
	_pal_recheck = _sections.keys()
	Probing.add("dh_palette", t0)
	if Probing.on:
		print("DH palette from a worker: %d tile and %d entity ids changed, %d sections to check" % [ct.size(), ce.size(), _pal_recheck.size()])


## Sections whose last build holds an id whose colours changed, dirtied a slice a frame.
func _recheck_palette_sections(budget_usec := PALETTE_RECHECK_USEC) -> void:
	if _pal_recheck.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	while not _pal_recheck.is_empty():
		if Time.get_ticks_usec() - t0 >= budget_usec:
			break
		var st: SectionState = _sections.get(_pal_recheck.pop_back())
		if st == null or not st.has_data or (st.dirty and not st.building) or st.grid_pal == _palette:
			continue  # gone, empty, about to be built with the new colours, or built with them
		if st.grid_pal != null and not section_uses(st.grid_tiles, st.grid_protos, _pal_changed_tiles, _pal_changed_ents):
			palette_stats[2] += 1
			continue
		st.dirty = true
		_has_dirty_sections = true
		_bump_serial(st)
		palette_stats[1] += 1
	if _pal_recheck.is_empty():
		_pal_changed_tiles = PackedInt32Array()
		_pal_changed_ents = PackedInt32Array()
	Probing.add("dh_palette_recheck", t0)


## Whether a section's grid holds any of the tile or entity ids (native scans).
static func section_uses(tiles: PackedInt32Array, protos: PackedInt32Array, tile_ids: PackedInt32Array, ent_ids: PackedInt32Array) -> bool:
	for id in tile_ids:
		if tiles.has(id):
			return true
	for id in ent_ids:
		if protos.has(id):
			return true
	return false


func set_palette(p: Object) -> void:
	_palette = p
	for k in _sections:
		var st: SectionState = _sections[k]
		st.dirty = true
		_has_dirty_sections = true
		_bump_serial(st)


func set_cache(c: Object) -> void:
	_cache = c


func set_chunk(chunk: Object, region_rev := -1) -> void:
	if chunk == null:
		return
	var cx: int = int(chunk.cx)
	var cy: int = int(chunk.cy)
	var c := Vector2i(cx, cy)
	_mem_chunks[c] = chunk
	_in_flight.erase(c)
	_missing_chunks.erase(c)
	_stale_chunks.erase(c)
	_requested_chunks.erase(c)
	if _cache != null and chunk is LodData.LodChunk and _cache.has_method("put_chunk"):
		var ld_chunk: LodData.LodChunk = chunk
		_cache.put_chunk(ld_chunk, region_rev)
		if region_rev >= 0:
			var r := LodCache.region_of(cx, cy)
			if int(_cached_region_revs.get(r, -1)) < region_rev:
				_cached_region_revs[r] = region_rev
	_has_dirty_sections = true
	_mark_chunk_dirty(cx, cy)


func set_chunk_loaded(c: Vector2i, loaded: bool, instant := false, defer_frames := 0) -> void:
	if loaded:
		_handoff_urgent.erase(c)
		_takeover_ready_frame.erase(c)
		if _loaded_chunks.has(c):
			_pending_mask.erase(c)
			if instant and _mask_levels.has(c):
				_mask_levels.erase(c)
				_mask_dirty = true
				_mask_force_upload = true
				_lod0_vis_dirty = true
			return
		if defer_frames > 0 and not instant and handoff_guard:
			_pending_mask[c] = mini(int(_pending_mask.get(c, defer_frames)), defer_frames)
			return
		_pending_mask.erase(c)
		_loaded_chunks[c] = true
		if not instant and seam_fade:
			_mask_levels[c] = 0.05
		_mask_dirty = true
		_mask_force_upload = true
		_lod0_vis_dirty = true
	else:
		_pending_mask.erase(c)
		_takeover_ready_frame.erase(c)
		var had_fade := _mask_levels.erase(c)
		if _loaded_chunks.erase(c) or had_fade:
			_mask_dirty = true
			_mask_force_upload = true
			_lod0_vis_dirty = true


func finish_mask_fades() -> void:
	var promoted := false
	if not _pending_mask.is_empty():
		for c: Vector2i in _pending_mask.keys():
			_loaded_chunks[c] = true
			promoted = true
		_pending_mask.clear()
	if not _mask_levels.is_empty() or promoted:
		_mask_levels.clear()
		_mask_dirty = true
		_mask_force_upload = true
		_lod0_vis_dirty = true


func _tick_pending_masks() -> void:
	if _pending_mask.is_empty():
		return
	for c: Vector2i in _pending_mask.keys():
		var left := int(_pending_mask[c]) - 1
		if left > 0:
			_pending_mask[c] = left
			continue
		_pending_mask.erase(c)
		if is_chunk_ready_cb.is_valid() and not bool(is_chunk_ready_cb.call(c)):
			continue
		if not _loaded_chunks.has(c):
			_loaded_chunks[c] = true
			if seam_fade:
				_mask_levels[c] = 0.05
			_mask_dirty = true
			_mask_force_upload = true
			_lod0_vis_dirty = true


func prepare_unload_takeover(c: Vector2i, rev: int = 0, tile_ids: PackedInt32Array = PackedInt32Array(),
		entities: Dictionary = {}, protos: Object = null) -> void:
	set_chunk_loaded(c, false)
	if not handoff_guard or not enabled or radius_chunks <= 0:
		return
	_handoff_urgent[c] = Time.get_ticks_msec()
	if _get_chunk(c.x, c.y) == null and not _pending_bakes.has(c) and tile_ids.size() == CHUNK * CHUNK and protos != null:
		_baked_sig.erase(c)
		bake_world_chunk(c.x, c.y, rev, tile_ids, entities, protos)


func has_mesh_for_chunk(c: Vector2i) -> bool:
	if not enabled or radius_chunks <= 0:
		return false
	var sx0 := floori(float(c.x) / 4.0)
	var sy0 := floori(float(c.y) / 4.0)
	var k0 := Vector3i(0, sx0, sy0)
	if _sections.has(k0):
		var st0: SectionState = _sections[k0]
		if st0.node != null and is_instance_valid(st0.node):
			var lx := c.x - sx0 * 4
			var ly := c.y - sy0 * 4
			var bit := 1 << (ly * 4 + lx)
			if (st0.built_chunk_mask & bit) != 0:
				return true
	for l in range(1, 5):
		var sec := int(SECTION_CHUNKS[l])
		var kl := Vector3i(l, floori(float(c.x) / float(sec)), floori(float(c.y) / float(sec)))
		if _sections.has(kl):
			var stl: SectionState = _sections[kl]
			if stl.node != null and is_instance_valid(stl.node) and _get_chunk(c.x, c.y) != null:
				return true
	for entry: Dictionary in _retiring:
		var rect: Rect2i = entry["rect"]
		if not rect.has_point(c):
			continue
		var node: Variant = entry.get("node")
		if node == null or not is_instance_valid(node) or not (node as MeshInstance3D).visible:
			continue
		if int(entry.get("level", 1)) == 0:
			var local := c - rect.position
			var bit := 1 << (local.y * 4 + local.x)
			if (int(entry.get("chunk_mask", 0)) & bit) != 0:
				return true
		elif _get_chunk(c.x, c.y) != null:
			return true
	return false


func _is_built_void_chunk(c: Vector2i) -> bool:
	var sx0 := floori(float(c.x) / 4.0)
	var sy0 := floori(float(c.y) / 4.0)
	var k0 := Vector3i(0, sx0, sy0)
	if _sections.has(k0):
		var st0: SectionState = _sections[k0]
		if st0.built_empty and not st0.dirty and not st0.building:
			var lx := c.x - sx0 * 4
			var ly := c.y - sy0 * 4
			var bit := 1 << (ly * 4 + lx)
			if (st0.built_chunk_mask & bit) != 0:
				return true
	return false


func covers_chunk(c: Vector2i) -> bool:
	return enabled and radius_chunks > 0 and not _loaded_chunks.has(c) and has_mesh_for_chunk(c)


func _is_in_dh_range(c: Vector2i) -> bool:
	if _layout_center.x == 0x7fffffff:
		return false
	return maxi(absi(c.x - _layout_center.x), absi(c.y - _layout_center.y)) <= radius_chunks


func _mask_unmasked_uploaded(c: Vector2i) -> bool:
	if _mask_centered and _mask_origin != _mask_origin_sent:
		return false
	return not mask_has_chunk(c)


func handoff_ready(c: Vector2i) -> bool:
	if not handoff_guard or not enabled or radius_chunks <= 0:
		return true
	if _missing_chunks.has(c) or not _is_in_dh_range(c):
		return true
	if _charted_known and not is_charted(c) and _get_chunk(c.x, c.y) == null and not _pending_bakes.has(c):
		return true
	if _loaded_chunks.has(c) or _pending_mask.has(c):
		return false
	var covered := has_mesh_for_chunk(c) or _is_built_void_chunk(c)
	if _takeover_ready_frame.has(c):
		return _update_frame > int(_takeover_ready_frame[c]) and _mask_unmasked_uploaded(c) and not _lod0_vis_dirty and covered
	if _handoff_urgent.has(c):
		return false
	return _mask_unmasked_uploaded(c) and not _lod0_vis_dirty and covered


func _update_takeover_ready() -> void:
	var now := Time.get_ticks_msec()
	for c: Vector2i in _handoff_urgent.keys():
		if _loaded_chunks.has(c) or _pending_mask.has(c):
			_handoff_urgent.erase(c)
			_takeover_ready_frame.erase(c)
			continue
		var covered := has_mesh_for_chunk(c) or _is_built_void_chunk(c)
		if _mask_unmasked_uploaded(c) and not _lod0_vis_dirty and covered:
			if not _takeover_ready_frame.has(c):
				_takeover_ready_frame[c] = _update_frame
			_handoff_urgent.erase(c)
		elif now - int(_handoff_urgent[c]) >= HANDOFF_URGENT_TTL_MSEC:
			_handoff_urgent.erase(c)
	if not _takeover_ready_frame.is_empty():
		for c: Vector2i in _takeover_ready_frame.keys():
			if _update_frame - int(_takeover_ready_frame[c]) > TAKEOVER_READY_KEEP_FRAMES:
				_takeover_ready_frame.erase(c)


func mask_level(c: Vector2i) -> float:
	if not _loaded_chunks.has(c):
		return 0.0
	return float(_mask_levels.get(c, 1.0))


func _tick_mask_fades(dt: float) -> void:
	if _mask_levels.is_empty():
		return
	var step := (maxf(dt, 0.0) / MASK_FADE_SECONDS) if seam_fade else 1.0
	if step <= 0.0:
		return
	for c: Vector2i in _mask_levels.keys():
		var lvl := float(_mask_levels[c])
		var next := minf(1.0, lvl + step)
		if lvl < 0.999 and next >= 0.999:
			_lod0_vis_dirty = true
		if next >= 1.0:
			_mask_levels.erase(c)
		else:
			_mask_levels[c] = next
		_mask_dirty = true


func mask_origin() -> Vector2i:
	return _mask_origin


func mask_has_chunk(c: Vector2i) -> bool:
	if _mask_image == null:
		return false
	var local := c - _mask_origin
	if local.x < 0 or local.y < 0 or local.x >= MASK_SIZE or local.y >= MASK_SIZE:
		return false
	return _mask_image.get_pixelv(local).r > 0.01


func bake_world_chunk(cx: int, cy: int, rev: int, tile_ids: PackedInt32Array,
		entities: Dictionary, protos: Object) -> void:
	if not enabled or radius_chunks <= 0 or protos == null:
		return
	if tile_ids.size() != CHUNK * CHUNK:
		return
	var c := Vector2i(cx, cy)
	var sig := Vector3i(rev, entities.size(), int(hash(tile_ids)))
	if _baked_sig.has(c) and _baked_sig[c] == sig:
		return
	_baked_sig[c] = sig

	var frame := Engine.get_process_frames()
	if frame != _bake_frame:
		_bake_frame = frame
		_bake_frame_usec = 0
	var tiles_copy := tile_ids.duplicate()
	var ent_values: Array = entities.values()
	if _bake_jobs.size() < MAX_BAKE_JOBS and _bake_queue.is_empty() and _bake_frame_usec < BAKE_QUEUE_BUDGET_USEC:
		var t0 := Time.get_ticks_usec()
		_dispatch_bake_job(cx, cy, rev, tiles_copy, ent_values, protos, _surface_gen)
		_bake_frame_usec += Time.get_ticks_usec() - t0
		return
	var had := _bake_queued.has(c)
	_bake_queued[c] = [cx, cy, rev, tiles_copy, ent_values, protos, _surface_gen]
	if not had:
		if _handoff_urgent.has(c):
			_bake_queue.push_front(c)
		else:
			_bake_queue.append(c)
	_pending_bakes[c] = true


func _dispatch_bake_job(cx: int, cy: int, rev: int, tiles_copy: PackedInt32Array,
		ent_values: Array, protos: Object, gen: int) -> void:
	var c := Vector2i(cx, cy)
	var snap_ents := {}
	var idx := 0
	for rec_v: Variant in ent_values:
		if not (rec_v is Object):
			continue
		var rec: Object = rec_v
		var extra_v: Variant = rec.get("extra")
		if extra_v is Dictionary:
			var ed: Dictionary = extra_v
			if ed.has("gh") or ed.has("tg") or ed.has("hid"):
				continue
		var br := BakeRec.new()
		var pid_v: Variant = rec.get("proto_id")
		br.proto_id = int(pid_v) if (pid_v is int or pid_v is float) else 0
		var pos_v: Variant = rec.get("pos")
		br.pos = pos_v if pos_v is Vector2 else Vector2.ZERO
		var dir_v: Variant = rec.get("dir")
		br.dir = int(dir_v) if (dir_v is int or dir_v is float) else 0
		snap_ents[idx] = br
		idx += 1

	var job := BakeJob.new()
	job.cx = cx
	job.cy = cy
	job.rev = rev
	job.gen = gen
	job.tile_ids = tiles_copy
	job.entities = snap_ents
	job.protos = protos
	job.target_res = _base_res_for_quality()
	_pending_bakes[c] = true
	var cb := Callable(job, "run")
	var tid := WorkerThreadPool.add_task(cb, false, "DH chunk bake")
	_bake_jobs.append([tid, job])


func _drain_bake_queue() -> void:
	if _bake_queue.is_empty() or _bake_jobs.size() >= MAX_BAKE_JOBS:
		return
	var t0 := Time.get_ticks_usec()
	var dispatched := 0
	while not _bake_queue.is_empty() and _bake_jobs.size() < MAX_BAKE_JOBS:
		if dispatched > 0 and Time.get_ticks_usec() - t0 >= BAKE_QUEUE_BUDGET_USEC:
			break
		var c: Vector2i = _bake_queue.pop_front()
		var item: Variant = _bake_queued.get(c)
		_bake_queued.erase(c)
		if not (item is Array):
			_pending_bakes.erase(c)
			continue
		var arr := item as Array
		if int(arr[6]) != _surface_gen:
			_pending_bakes.erase(c)
			continue
		_dispatch_bake_job(int(arr[0]), int(arr[1]), int(arr[2]), arr[3] as PackedInt32Array, arr[4] as Array, arr[5] as Object, int(arr[6]))
		dispatched += 1


func handle(msg: Dictionary) -> void:
	if msg.is_empty():
		return
	if msg.has("si") and _surface_index >= 1 and int(msg.get("si", -1)) != _surface_index:
		return
	var t := str(msg.get("t", ""))
	if t == "lodm":
		var q := int(msg.get("q", 0))
		var part := maxi(1, int(msg.get("part", 1)))
		var parts := maxi(1, int(msg.get("parts", 1)))
		if q != _map_q:
			_map_q = q
			_map_parts_seen = 0
			_map_parts_total = parts
			_map_pending.clear()
			_map_pending_rows.clear()
		else:
			_map_parts_total = maxi(_map_parts_total, parts)
		var rows_v: Variant = msg.get("w")
		if rows_v is Array and not map_old:
			_add_map_rows(rows_v as Array)
		elif rows_v is Array:
			for row_v: Variant in rows_v as Array:
				if not (row_v is Array):
					continue
				var row := row_v as Array
				if row.size() < 3:
					continue
				var cy := int(row[0])
				var ri := 1
				while ri + 1 < row.size():
					var x0 := int(row[ri])
					var cnt := int(row[ri + 1])
					for dx in cnt:
						_map_pending[Vector2i(x0 + dx, cy)] = true
					ri += 2
		_map_parts_seen += 1
		if _map_parts_seen >= _map_parts_total and not map_old:
			_finish_map_runs()
		elif _map_parts_seen >= _map_parts_total:
			var was_known := _charted_known
			var newly_charted: Array[Vector2i] = []
			if was_known:
				for c_v: Variant in _map_pending:
					if c_v is Vector2i and not _charted.has(c_v):
						newly_charted.append(c_v as Vector2i)
			_charted = _map_pending.duplicate()
			_map_pending.clear()
			_rebuild_charted_sections()
			_charted_known = true
			if not was_known:
				for k in _sections:
					var st: SectionState = _sections[k]
					st.complete = false
					st.needs_missing_scan = true
			else:
				for nc in newly_charted:
					for l in 5:
						var sec := int(SECTION_CHUNKS[l])
						var sk := Vector3i(l, floori(float(nc.x) / float(sec)), floori(float(nc.y) / float(sec)))
						if _sections.has(sk):
							var sst: SectionState = _sections[sk]
							sst.complete = false
							sst.needs_missing_scan = true
	elif t == "lodr":
		var list_v: Variant = msg.get("l")
		if not (list_v is Array):
			return
		var list := list_v as Array
		var i := 0
		while i + 2 < list.size():
			var rx := int(list[i])
			var ry := int(list[i + 1])
			var rev := int(list[i + 2])
			var r := Vector2i(rx, ry)
			var prev := int(_known_region_revs.get(r, _cached_region_revs.get(r, -1)))
			_known_region_revs[r] = rev
			if prev >= 0 and rev != prev:
				_invalidate_region(rx, ry, rev)
			elif _cached_region_revs.has(r) and int(_cached_region_revs[r]) != rev:
				_invalidate_region(rx, ry, rev)
			i += 3
	elif t == "lod":
		_last_lod_rx_msec = Time.get_ticks_msec()
		if bool(msg.get("none", false)):
			if msg.has("cx") and msg.has("cy"):
				var mc := Vector2i(int(msg.get("cx", 0)), int(msg.get("cy", 0)))
				_in_flight.erase(mc)
				_missing_chunks[mc] = true
			return
		var ch := LodData.LodChunk.from_msg(msg)
		if ch != null:
			var r := LodCache.region_of(ch.cx, ch.cy)
			var known_rev := int(_known_region_revs.get(r, -1))
			set_chunk(ch, known_rev)
			if _charted_known:
				var cc := Vector2i(ch.cx, ch.cy)
				if map_old:
					_charted[cc] = true
				elif not is_charted(cc):
					_charted_extra[cc] = true
				_mark_charted_section(cc)


func desired_camera_far() -> float:
	if not enabled or radius_chunks <= 0:
		return 2000.0
	return maxf(2000.0, float(radius_chunks) * float(CHUNK) * 1.45 + 256.0)


func set_fog_color(c: Color) -> void:
	_horizon_color = c
	_apply_material_params()


func _covered_by_inner(cam: Camera3D, cam_chunk: Vector2i) -> bool:
	if cam == null or cam.projection != Camera3D.PROJECTION_PERSPECTIVE or inner_chunks < 2:
		return false
	if not cam.is_inside_tree() or cam.get_viewport() == null:
		return false
	var vp := cam.get_viewport().get_visible_rect().size
	if vp.x <= 0.0 or vp.y <= 0.0:
		return false
	var hr: Vector2 = GroundHeight.lift_range()
	var y_lo: float = hr.x - 4.0
	var max_dist := float(inner_chunks - 1) * float(CHUNK)
	var min_c := Vector2i(0x7fffffff, 0x7fffffff)
	var max_c := Vector2i(-0x7fffffff, -0x7fffffff)
	var centre := Vector2(float(cam_chunk.x) * float(CHUNK) + float(CHUNK) * 0.5,
		float(cam_chunk.y) * float(CHUNK) + float(CHUNK) * 0.5)
	for corner: Vector2 in [Vector2.ZERO, Vector2(vp.x, 0.0), Vector2(0.0, vp.y), vp]:
		var ro := cam.project_ray_origin(corner)
		var rd := cam.project_ray_normal(corner)
		if rd.y >= -0.05 or ro.y <= y_lo:
			return false
		var t := (y_lo - ro.y) / rd.y
		if t <= 0.0:
			return false
		var hit := ro + rd * t
		if Vector2(hit.x, hit.z).distance_to(centre) > max_dist:
			return false
		var cx := floori(hit.x / float(CHUNK))
		var cy := floori(hit.z / float(CHUNK))
		min_c.x = mini(min_c.x, cx)
		min_c.y = mini(min_c.y, cy)
		max_c.x = maxi(max_c.x, cx)
		max_c.y = maxi(max_c.y, cy)
	min_c -= Vector2i(1, 1)
	max_c += Vector2i(1, 1)
	for cy in range(min_c.y, max_c.y + 1):
		for cx in range(min_c.x, max_c.x + 1):
			var cc := Vector2i(cx, cy)
			if not _loaded_chunks.has(cc) or _mask_levels.has(cc):
				return false
	return true


func update(cam: Camera3D, p_horizon_color: Color, p_night_level: float, p_is_space: bool,
		anchor_pos := Vector3.INF, allow_hide := false) -> void:
	_horizon_color = p_horizon_color
	_night_level = clampf(p_night_level, 0.0, 1.0)
	_is_space = p_is_space

	if not enabled or radius_chunks <= 0:
		visible = false
		_handoff_urgent.clear()
		_takeover_ready_frame.clear()
		_budget_waiting(&"lod_install", 0)
		if _was_streaming:
			_send_stop()
		if _cache != null:
			if _cache.has_method("poll_write"):
				_cache.poll_write()
			if _cache.has_method("poll_reads"):
				var regs_off: Variant = _cache.poll_reads()
				if regs_off is Array and not (regs_off as Array).is_empty():
					_on_cache_regions_loaded(regs_off as Array)
		return
	_update_frame += 1
	if _cache != null:
		if _cache.has_method("poll_write"):
			_cache.poll_write()
		if _cache.has_method("poll_reads"):
			var regs_on: Variant = _cache.poll_reads()
			if regs_on is Array and not (regs_on as Array).is_empty():
				_on_cache_regions_loaded(regs_on as Array)
	_ensure_materials()
	_sync_water_tint()

	var cam_pos := Vector3.ZERO
	var frustum: Array[Plane] = []
	if cam != null:
		if cam.is_inside_tree():
			cam_pos = cam.global_position
			frustum = ViewPriority.planes(cam)
		else:
			cam_pos = cam.position
	var center_pos := anchor_pos if anchor_pos != Vector3.INF else cam_pos
	var cam_chunk := Vector2i(floori(center_pos.x / float(CHUNK)), floori(center_pos.z / float(CHUNK)))
	visible = not (ViewPriority.tight_cull and allow_hide and _covered_by_inner(cam, cam_chunk))
	var dt := get_process_delta_time() if is_inside_tree() else 0.016

	_tick_pending_masks()
	_tick_mask_fades(dt)
	_update_mask(cam_chunk, dt)
	_apply_material_params()
	_poll_bake_jobs()
	_drain_bake_queue()
	_sync_sections(cam_chunk)
	_update_lod0_visibility()
	_poll_and_install_meshes()
	if _lod0_vis_dirty:
		_update_lod0_visibility()
	_update_takeover_ready()
	_recheck_palette_sections()
	_schedule_section_builds(center_pos, frustum)

	_sub_timer += dt
	if _sub_timer >= LOD_SUB_INTERVAL:
		_sub_timer = 0.0
		_drive_lod_sub(center_pos, frustum)

	_flush_timer += dt
	if _flush_timer >= CACHE_FLUSH_INTERVAL:
		_flush_timer = 0.0
		_flush_cache_async()


func stats() -> Dictionary:
	var vis := 0
	var tris := 0
	var dirty_n := 0
	for k in _sections:
		var st: SectionState = _sections[k]
		if st.dirty:
			dirty_n += 1
		if st.node != null and st.node.visible:
			vis += 1
			tris += st.tri_count
	return {
		"enabled": enabled,
		"radius_chunks": radius_chunks,
		"quality": quality,
		"dropoff": dropoff,
		"sections": _sections.size(),
		"visible_sections": vis,
		"triangles": tris,
		"dirty": dirty_n,
		"building": _mesh_jobs.size(),
		"baking": _bake_jobs.size() + _bake_queue.size(),
		"loaded_masked": _loaded_chunks.size(),
		"cached_chunks": _mem_chunks.size(),
	}


func finish_all() -> void:
	if _pal_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_pal_task)
		_pal_task = -1
		_pal_job = null
	_pal_recheck.clear()
	_sched_list.clear()
	for entry in _mesh_jobs:
		var tid: int = int(entry[0])
		WorkerThreadPool.wait_for_task_completion(tid)
	_mesh_jobs.clear()
	_ready_meshes.clear()
	for entry in _bake_jobs:
		var tid: int = int(entry[0])
		WorkerThreadPool.wait_for_task_completion(tid)
	_bake_jobs.clear()
	_bake_queue.clear()
	_bake_queued.clear()
	_pending_bakes.clear()
	for k in _sections:
		var st: SectionState = _sections[k]
		st.building = false
	if _cache != null:
		if _cache.has_method("wait_reads"):
			_cache.wait_reads()
		if _cache.has_method("wait_write"):
			_cache.wait_write()


# --- internals --------------------------------------------------------------------------------

func _configure_cache_from_palette() -> void:
	var ph := 1
	if _palette != null:
		var ph_v: Variant = _palette.get("proto_hash")
		if ph_v is int or ph_v is float:
			ph = int(ph_v)
	if _cache == null:
		_cache = LodCache.new()
	if _save_id != "" and _cache != null and _cache.has_method("configure"):
		_cache.configure(_save_id, _surface_index, ph)
		_cache_configured = true
		if _cache.has_method("prune_disk"):
			_cache.prune_disk()
		if _cache.has_method("region_revs"):
			var revs_v: Variant = _cache.region_revs()
			if revs_v is Dictionary:
				_cached_region_revs = (revs_v as Dictionary).duplicate()
				_mark_cached_regions_populated()


func _mark_cached_regions_populated() -> void:
	for r_v: Variant in _cached_region_revs:
		if not (r_v is Vector2i):
			continue
		var r := r_v as Vector2i
		var cx0 := r.x * LodCache.REGION
		var cy0 := r.y * LodCache.REGION
		for oy in [0, 4, 8, 12]:
			for ox in [0, 4, 8, 12]:
				_mark_populated(cx0 + ox, cy0 + oy)


func _on_cache_regions_loaded(regs: Array) -> void:
	if regs.is_empty():
		return
	for r_v: Variant in regs:
		if not (r_v is Vector2i):
			continue
		var r := r_v as Vector2i
		var x0 := r.x * LodCache.REGION
		var y0 := r.y * LodCache.REGION
		var x1 := x0 + LodCache.REGION
		var y1 := y0 + LodCache.REGION
		if _cache != null and _cache.has_method("get_chunk"):
			for cy in range(y0, y1):
				for cx in range(x0, x1):
					var c := Vector2i(cx, cy)
					if _mem_chunks.has(c):
						continue
					var ch: Variant = _cache.get_chunk(cx, cy)
					if ch != null:
						_mem_chunks[c] = ch
						_mark_populated(cx, cy)
		for l in 5:
			var sec := int(SECTION_CHUNKS[l])
			var sx0 := floori(float(x0) / float(sec))
			var sx1 := floori(float(x1 - 1) / float(sec))
			var sy0 := floori(float(y0) / float(sec))
			var sy1 := floori(float(y1 - 1) / float(sec))
			for sy in range(sy0, sy1 + 1):
				for sx in range(sx0, sx1 + 1):
					var key := Vector3i(l, sx, sy)
					if _sections.has(key):
						var st: SectionState = _sections[key]
						st.dirty = true
						st.has_data = true
						st.next_sub_msec = 0
						_has_dirty_sections = true
						_bump_serial(st)


func _is_cache_region_pending(c: Vector2i) -> bool:
	if not LodCache.async_io or _cache == null or not _cache_configured or _cached_region_revs.is_empty():
		return false
	if not _cache.has_method("is_region_loaded") or not _cache.has_method("request_region"):
		return false
	var r := LodCache.region_of(c.x, c.y)
	if not _cached_region_revs.has(r):
		return false
	if _cache.is_region_loaded(r.x, r.y):
		return false
	_cache.request_region(r.x, r.y)
	return not _cache.is_region_loaded(r.x, r.y)


func _section_has_pending_cache_reads(st: SectionState) -> bool:
	if not LodCache.async_io or _cache == null or not _cache_configured or _cached_region_revs.is_empty():
		return false
	if not _cache.has_method("is_region_loaded") or not _cache.has_method("request_region"):
		return false
	var cx0 := st.sx * st.sec_chunks
	var cy0 := st.sy * st.sec_chunks
	var cx1 := cx0 + st.sec_chunks - 1
	var cy1 := cy0 + st.sec_chunks - 1
	var r0 := LodCache.region_of(cx0, cy0)
	var r1 := LodCache.region_of(cx1, cy1)
	var pending := false
	for ry in range(r0.y, r1.y + 1):
		for rx in range(r0.x, r1.x + 1):
			var r := Vector2i(rx, ry)
			if not _cached_region_revs.has(r):
				continue
			if not _cache.is_region_loaded(rx, ry):
				_cache.request_region(rx, ry)
				if not _cache.is_region_loaded(rx, ry):
					pending = true
	return pending


func _flush_cache() -> void:
	if _cache != null and _cache.has_method("flush_dirty"):
		_cache.flush_dirty()


func _flush_cache_async() -> void:
	if _cache == null:
		return
	if _cache.has_method("flush_dirty_async"):
		_cache.flush_dirty_async()
	elif _cache.has_method("flush_dirty"):
		_cache.flush_dirty()


func _invalidate_region(rx: int, ry: int, new_rev: int) -> void:
	var r := Vector2i(rx, ry)
	_cached_region_revs[r] = new_rev
	var x0 := rx * LodCache.REGION
	var y0 := ry * LodCache.REGION
	var x1 := x0 + LodCache.REGION
	var y1 := y0 + LodCache.REGION
	var reg_ready: bool = _cache != null and ((not LodCache.async_io) or not _cache.has_method("is_region_loaded") or bool(_cache.is_region_loaded(rx, ry)))
	for cy in range(y0, y1):
		for cx in range(x0, x1):
			var c := Vector2i(cx, cy)
			if not _mem_chunks.has(c) and reg_ready and _cache.has_method("get_chunk"):
				var cached_ch: Variant = _cache.get_chunk(cx, cy)
				if cached_ch != null:
					_mem_chunks[c] = cached_ch
			if _mem_chunks.has(c):
				_stale_chunks[c] = true
	if _cache != null and _cache.has_method("invalidate_region"):
		_cache.invalidate_region(rx, ry, new_rev)
	for d: Dictionary in [_requested_chunks, _missing_chunks, _in_flight, _baked_sig]:
		for c_v: Variant in d.keys():
			if c_v is Vector2i:
				var c := c_v as Vector2i
				if c.x >= x0 and c.x < x1 and c.y >= y0 and c.y < y1:
					d.erase(c)
	for l in 5:
		var sec := int(SECTION_CHUNKS[l])
		var sx0 := floori(float(x0) / float(sec))
		var sx1 := floori(float(x1 - 1) / float(sec))
		var sy0 := floori(float(y0) / float(sec))
		var sy1 := floori(float(y1 - 1) / float(sec))
		for sy in range(sy0, sy1 + 1):
			for sx in range(sx0, sx1 + 1):
				var key := Vector3i(l, sx, sy)
				if _sections.has(key):
					var st: SectionState = _sections[key]
					st.complete = false
					st.next_sub_msec = 0


func _build_palette(protos: Object, model_bakes: Dictionary) -> void:
	if protos == null:
		return
	# Duck-typed palette object passed directly in tests or callers.
	if protos.get("tile_colors") != null and protos.get("ent_top_colors") != null:
		_palette = protos
		return
	_palette = LodData.LodPalette.build(protos, model_bakes)
	_pal_tex_gen = TerrainTextures.generation
	_pal_bakes_n = model_bakes.size()


func _base_res_for_quality() -> int:
	var q_key := quality if QUALITY_CELL_TILES.has(quality) else "medium"
	var list: Array = QUALITY_CELL_TILES[q_key]
	return clampi(int(list[0]), 2, 32)


func set_pollution_far(tex: Texture2D, rect: Vector4, ver: int = -1) -> void:
	if ver >= 0 and ver == _far_pol_ver and tex == _far_pol_tex and rect == _far_pol_rect:
		return
	_far_pol_tex = tex
	_far_pol_rect = rect
	_far_pol_ver = ver
	_apply_pollution_far()


func _apply_pollution_far() -> void:
	if _solid_mat == null:
		return
	for m: ShaderMaterial in [_solid_mat, _solid_masked_mat, _water_mat, _water_masked_mat]:
		if m != null:
			m.set_shader_parameter(&"lod_far_pollution", _far_pol_tex)
			m.set_shader_parameter(&"lod_far_pollution_rect", _far_pol_rect)


func _ensure_materials() -> void:
	if _mask_image == null:
		_mask_image = Image.create(MASK_SIZE, MASK_SIZE, false, Image.FORMAT_R8)
		_mask_image.fill(Color.BLACK)
		_mask_texture = ImageTexture.create_from_image(_mask_image.duplicate() as Image)

	if _solid_mat == null:
		_solid_mat = ShaderMaterial.new()
		_solid_mat.shader = SolidShader
		_mat_params_dirty = true
	if _solid_masked_mat == null:
		_solid_masked_mat = ShaderMaterial.new()
		_solid_masked_mat.shader = SolidMaskedShader
		_solid_masked_mat.set_shader_parameter(&"loaded_mask", _mask_texture)
		_solid_masked_mat.set_shader_parameter(&"mask_size", float(MASK_SIZE))
		_solid_masked_mat.set_shader_parameter(&"mask_origin_chunk", Vector2(_mask_origin))
		_mask_origin_sent = Vector2i(0x7fffffff, 0)
		_mat_params_dirty = true
	if _water_mat == null:
		_water_mat = ShaderMaterial.new()
		_water_mat.shader = WaterShader
		_mat_params_dirty = true
	if _water_masked_mat == null:
		_water_masked_mat = ShaderMaterial.new()
		_water_masked_mat.shader = WaterMaskedShader
		_water_masked_mat.set_shader_parameter(&"loaded_mask", _mask_texture)
		_water_masked_mat.set_shader_parameter(&"mask_size", float(MASK_SIZE))
		_water_masked_mat.set_shader_parameter(&"mask_origin_chunk", Vector2(_mask_origin))
		_mask_origin_sent = Vector2i(0x7fffffff, 0)
		_mat_params_dirty = true
	_apply_pollution_far()


func _sync_water_tint() -> void:
	var wm := Visuals.water_material()
	if wm == null:
		return
	var st: Variant = wm.get_shader_parameter(&"sky_tint")
	if st is Color:
		_sky_tint = st


func _apply_material_params() -> void:
	if _solid_mat == null:
		return
	if (not _mat_params_dirty
			and _horizon_color == _sent_horizon_color
			and _night_level == _sent_night_level
			and radius_chunks == _sent_radius_chunks
			and glow_enabled == _sent_glow_enabled
			and _is_space == _sent_is_space
			and _sky_tint == _sent_sky_tint):
		return
	_mat_params_dirty = false
	_sent_horizon_color = _horizon_color
	_sent_night_level = _night_level
	_sent_radius_chunks = radius_chunks
	_sent_glow_enabled = glow_enabled
	_sent_is_space = _is_space
	_sent_sky_tint = _sky_tint

	var fade_end := maxf(float(radius_chunks) * float(CHUNK), 256.0)
	var fade_start := minf(fade_end * 0.72, fade_end - 64.0)
	fade_start = maxf(fade_start, 64.0)
	var eff_glow := 1.0 if glow_enabled else 0.0
	var space_f := 1.0 if _is_space else 0.0

	for m: ShaderMaterial in [_solid_mat, _solid_masked_mat]:
		m.set_shader_parameter(&"horizon_color", _horizon_color)
		m.set_shader_parameter(&"fade_start", fade_start)
		m.set_shader_parameter(&"fade_end", fade_end)
		m.set_shader_parameter(&"night_level", _night_level)
		m.set_shader_parameter(&"glow_strength", eff_glow)
		m.set_shader_parameter(&"is_space", space_f)

	for m: ShaderMaterial in [_water_mat, _water_masked_mat]:
		m.set_shader_parameter(&"horizon_color", _horizon_color)
		m.set_shader_parameter(&"fade_start", fade_start)
		m.set_shader_parameter(&"fade_end", fade_end)
		m.set_shader_parameter(&"night_level", _night_level)
		m.set_shader_parameter(&"is_space", space_f)
		m.set_shader_parameter(&"sky_tint", _sky_tint)


func _update_mask(cam_chunk: Vector2i, dt: float = 0.0) -> void:
	var mid := _mask_origin + Vector2i(MASK_SIZE / 2, MASK_SIZE / 2)
	var recentered := false
	if not _mask_centered or absi(cam_chunk.x - mid.x) >= MASK_RECENTER or absi(cam_chunk.y - mid.y) >= MASK_RECENTER:
		_mask_origin = cam_chunk - Vector2i(MASK_SIZE / 2, MASK_SIZE / 2)
		_mask_centered = true
		_mask_dirty = true
		recentered = true
	if not _mask_dirty:
		return
	_mask_upload_timer += dt
	if not recentered and not _mask_force_upload and not _mask_levels.is_empty() and _mask_upload_timer < MASK_UPDATE_INTERVAL:
		return
	_mask_dirty = false
	_mask_force_upload = false
	_mask_upload_timer = 0.0
	_mask_image.fill(Color.BLACK)
	var bounds := Rect2i(Vector2i.ZERO, Vector2i(MASK_SIZE, MASK_SIZE))
	for c: Vector2i in _loaded_chunks:
		var local := c - _mask_origin
		if bounds.has_point(local):
			var lvl := clampf(float(_mask_levels.get(c, 1.0)), 0.0, 1.0)
			_mask_image.set_pixelv(local, Color(lvl, 0.0, 0.0, 1.0))
	_mask_texture.update(_mask_image.duplicate() as Image)
	if _mask_origin != _mask_origin_sent:
		_mask_origin_sent = _mask_origin
		var origin_v := Vector2(_mask_origin)
		for m: ShaderMaterial in [_solid_masked_mat, _water_masked_mat]:
			m.set_shader_parameter(&"mask_origin_chunk", origin_v)
			m.set_shader_parameter(&"mask_size", float(MASK_SIZE))


func _poll_bake_jobs() -> void:
	for i in range(_bake_jobs.size() - 1, -1, -1):
		var entry: Array = _bake_jobs[i]
		var tid: int = int(entry[0])
		if not WorkerThreadPool.is_task_completed(tid):
			continue
		WorkerThreadPool.wait_for_task_completion(tid)
		_bake_jobs.remove_at(i)
		var job: BakeJob = entry[1]
		if job.gen == _surface_gen:
			_pending_bakes.erase(Vector2i(job.cx, job.cy))
			if job.result != null:
				set_chunk(job.result)


func _bump_serial(st: SectionState) -> void:
	st.serial = _next_serial
	_next_serial += 1


func _sync_sections(cam_chunk: Vector2i) -> void:
	var eff_inner := clampi(inner_chunks, 0, MASK_SIZE / 2 - 4)
	if (_layout_radius == radius_chunks and _layout_inner == eff_inner
			and _layout_quality == quality and _layout_dropoff == dropoff
			and _layout_detail_lod == detail_lod_enabled and _layout_center.x != 0x7fffffff):
		if maxi(absi(cam_chunk.x - _layout_center.x), absi(cam_chunk.y - _layout_center.y)) < LAYOUT_HYSTERESIS:
			return
	_layout_center = cam_chunk
	_layout_radius = radius_chunks
	_layout_inner = eff_inner
	_layout_quality = quality
	_layout_dropoff = dropoff
	_layout_detail_lod = detail_lod_enabled

	var desired := ring_sections(cam_chunk, radius_chunks, eff_inner, quality, dropoff)
	var keep := {}
	for spec: Dictionary in desired:
		var k: Vector3i = spec["key"]
		keep[k] = true
		var new_dt := int(spec["detail_tier"]) if detail_lod_enabled else LodMesher.DETAIL_FULL
		if _sections.has(k):
			var st: SectionState = _sections[k]
			var new_ct := float(spec["cell_tiles"])
			if not is_equal_approx(st.cell_tiles, new_ct) or st.detail_tier != new_dt:
				st.cell_tiles = new_ct
				st.grid_n = int(spec["grid_n"])
				st.detail_tier = new_dt
				st.dirty = true
				_has_dirty_sections = true
				st.complete = false
				st.needs_missing_scan = true
				st.next_sub_msec = 0
				_bump_serial(st)
		else:
			var st := SectionState.new()
			st.key = k
			st.level = int(spec["level"])
			st.sx = int(spec["sx"])
			st.sy = int(spec["sy"])
			st.sec_chunks = int(spec["sec_chunks"])
			st.cell_tiles = float(spec["cell_tiles"])
			st.grid_n = int(spec["grid_n"])
			st.detail_tier = new_dt
			st.dirty = true
			_has_dirty_sections = true
			st.has_data = _populated_sections.has(k)
			_bump_serial(st)
			_sections[k] = st

	for k in _sections.keys():
		if not keep.has(k):
			var st: SectionState = _sections[k]
			_bump_serial(st)
			if st.node != null and is_instance_valid(st.node):
				st.node.position.y = -0.02
				st.node.visible = true
				_retiring.append({
					"node": st.node,
					"rect": Rect2i(st.sx * st.sec_chunks, st.sy * st.sec_chunks, st.sec_chunks, st.sec_chunks),
					"level": st.level,
					"chunk_mask": st.built_chunk_mask,
				})
				st.node = null
			_sections.erase(k)
	_lod0_vis_dirty = true
	_has_dirty_sections = true
	_gc_retiring()


func _gc_retiring() -> void:
	for i in range(_retiring.size() - 1, -1, -1):
		var entry: Dictionary = _retiring[i]
		var node: Variant = entry.get("node")
		if node == null or not is_instance_valid(node):
			_retiring.remove_at(i)
			continue
		var rect: Rect2i = entry["rect"]
		var ready := true
		for k in _sections:
			var st: SectionState = _sections[k]
			var srect := Rect2i(st.sx * st.sec_chunks, st.sy * st.sec_chunks, st.sec_chunks, st.sec_chunks)
			if not srect.intersects(rect):
				continue
			if st.node != null and is_instance_valid(st.node):
				continue
			if not st.has_data:
				continue
			if st.built_empty and not st.dirty and not st.building:
				continue
			ready = false
			break
		if ready:
			FreeLater.node(node as MeshInstance3D)
			_retiring.remove_at(i)


func _update_lod0_visibility() -> void:
	if not _lod0_vis_dirty:
		return
	_lod0_vis_dirty = false
	if _loaded_chunks.is_empty():
		for k in _sections:
			var st: SectionState = _sections[k]
			if st.node != null and not st.node.visible:
				st.node.visible = true
		return
	for k in _sections:
		var st: SectionState = _sections[k]
		if st.node == null:
			continue
		if st.level != 0:
			if not st.node.visible:
				st.node.visible = true
			continue
		var cx0 := st.sx * st.sec_chunks
		var cy0 := st.sy * st.sec_chunks
		var all_loaded := true
		for dy in st.sec_chunks:
			for dx in st.sec_chunks:
				var cc := Vector2i(cx0 + dx, cy0 + dy)
				if not _loaded_chunks.has(cc) or float(_mask_levels.get(cc, 1.0)) < 0.999:
					all_loaded = false
					break
			if not all_loaded:
				break
		st.node.visible = not all_loaded


func _poll_and_install_meshes() -> void:
	for i in range(_mesh_jobs.size() - 1, -1, -1):
		var entry: Array = _mesh_jobs[i]
		var tid: int = int(entry[0])
		if WorkerThreadPool.is_task_completed(tid):
			WorkerThreadPool.wait_for_task_completion(tid)
			_mesh_jobs.remove_at(i)
			_ready_meshes.append(entry[1])

	if _ready_meshes.is_empty():
		_budget_waiting(&"lod_install", 0)
		_gc_retiring()
		return

	var budget_usec := _budget_grant(&"lod_install")
	var t0 := Time.get_ticks_usec()
	var installed := 0
	for idx in _ready_meshes.size():
		if idx > 0 and Time.get_ticks_usec() - t0 >= budget_usec:
			break
		# (And not one more than fits: an install's typical cost counted before it, FrameBudget.item_est, --budget-predict.)
		if not FrameBudget.fits(t0, budget_usec, idx, FrameBudget.item_est(&"lod_install")):
			break
		var job: LodMesher = _ready_meshes[idx]
		installed += 1
		if not _sections.has(job.key):
			continue
		var st: SectionState = _sections[job.key]
		st.building = false
		if st.dirty:
			_has_dirty_sections = true
		var ti := Time.get_ticks_usec()
		if job.serial != st.serial:
			if (st.node == null or not is_instance_valid(st.node)) and job.mesh != null and job.tri_count > 0:
				_install_section_mesh(st, job)
				FrameBudget.note_item(&"lod_install", Time.get_ticks_usec() - ti)
			continue
		_install_section_mesh(st, job)
		FrameBudget.note_item(&"lod_install", Time.get_ticks_usec() - ti)

	if installed > 0:
		_ready_meshes = _ready_meshes.slice(installed)

	_gc_retiring()
	var spent_usec := Time.get_ticks_usec() - t0
	_budget_spent(&"lod_install", spent_usec, _ready_meshes.size())


func _install_section_mesh(st: SectionState, job: LodMesher) -> void:
	if job.mesh == null or job.tri_count <= 0:
		st.built_empty = true
		st.built_chunk_mask = job.chunk_mask
		if not st.has_data:
			if st.node != null and is_instance_valid(st.node):
				FreeLater.node(st.node)
			st.node = null
			st.tri_count = 0
		return
	st.built_empty = false
	st.built_chunk_mask = job.chunk_mask

	var solid_m: Material = _solid_masked_mat if st.level == 0 else _solid_mat
	var water_m: Material = _water_masked_mat if st.level == 0 else _water_mat
	if job.solid_surface >= 0:
		job.mesh.surface_set_material(job.solid_surface, solid_m)
	if job.water_surface >= 0:
		job.mesh.surface_set_material(job.water_surface, water_m)

	if st.node == null or not is_instance_valid(st.node):
		var mi := MeshInstance3D.new()
		mi.name = "LOD_%d_%d_%d" % [st.level, st.sx, st.sy]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(job.section_origin.x, 0.0, job.section_origin.y)
		add_child(mi)
		st.node = mi

	st.node.mesh = job.mesh
	st.tri_count = job.tri_count
	GroundHeight.hold_mesh(st.node)
	_lod0_vis_dirty = true


func _schedule_section_builds(cam_pos: Vector3, frustum: Array[Plane]) -> void:
	if not _has_dirty_sections or _palette == null or _mesh_jobs.size() >= MAX_BUILD_JOBS:
		return
	var candidates: Array = []
	var now_ms := Time.get_ticks_msec()
	if not palette_old:
		# The last sorted list, while it lasts: a full scan and sort at most every SCHED_RESORT_MSEC.
		while not _sched_list.is_empty():
			var head: SectionState = _sched_list[0]
			if head.dirty and head.has_data and not head.building and _sections.get(head.key) == head:
				break
			_sched_list.pop_front()
		if not _sched_list.is_empty() and now_ms - _sched_msec < SCHED_RESORT_MSEC and _handoff_urgent.size() == _sched_urgent_n:
			_dispatch_sections(_sched_list)
			return
	var any_building_dirty := false
	for k in _sections:
		var st: SectionState = _sections[k]
		if not st.dirty or not st.has_data:
			continue
		if st.building:
			any_building_dirty = true
			continue
		var span := float(st.sec_chunks * CHUNK)
		var cx := (float(st.sx) + 0.5) * span
		var cz := (float(st.sy) + 0.5) * span
		var center3 := Vector3(cx, 0.0, cz)
		var dsq := cam_pos.distance_squared_to(center3)
		var in_view := true
		if not frustum.is_empty():
			var bound := span * 0.75 + 16.0
			for pl: Plane in frustum:
				if pl.distance_to(center3) > bound:
					in_view = false
					break
		st.dist_sq = dsq
		st.in_frustum = in_view
		candidates.append(st)

	if candidates.is_empty():
		if not any_building_dirty:
			_has_dirty_sections = false
		return

	var urgent_sections := {}
	for uc: Vector2i in _handoff_urgent:
		for l in 5:
			var usec := int(SECTION_CHUNKS[l])
			urgent_sections[Vector3i(l, floori(float(uc.x) / float(usec)), floori(float(uc.y) / float(usec)))] = true

	var cmp := func(a: SectionState, b: SectionState) -> bool:
		var ua := urgent_sections.has(a.key)
		var ub := urgent_sections.has(b.key)
		if ua != ub:
			return ua
		if a.in_frustum != b.in_frustum:
			return a.in_frustum
		if a.level != b.level:
			return a.level < b.level
		return a.dist_sq < b.dist_sq
	candidates.sort_custom(cmp)
	if not palette_old:
		_sched_list = candidates
		_sched_msec = now_ms
		_sched_urgent_n = _handoff_urgent.size()
	_dispatch_sections(candidates)


## Mesh jobs for the first sections of `candidates` (best first) that may be built now.
func _dispatch_sections(candidates: Array) -> void:
	var dispatched := 0
	var t_sched := Time.get_ticks_usec()
	for st: SectionState in candidates:
		if _mesh_jobs.size() >= MAX_BUILD_JOBS or dispatched >= MAX_DISPATCH_PER_FRAME:
			break
		if dispatched > 0 and Time.get_ticks_usec() - t_sched >= SCHEDULE_BUDGET_USEC:
			break
		if not st.dirty or not st.has_data or st.building or _sections.get(st.key) != st:
			continue  # built meanwhile, or replaced since the list was sorted
		if _section_has_pending_cache_reads(st):
			continue
		var grid := _sample_section_grid(st)
		var job := LodMesher.new()
		job.key = st.key
		job.serial = st.serial
		var span := float(st.sec_chunks * CHUNK)
		job.section_origin = Vector2(float(st.sx) * span, float(st.sy) * span)
		job.grid_n = st.grid_n
		job.cell_tiles = st.cell_tiles
		job.tiles = grid[0]
		job.protos = grid[1]
		job.flags = grid[2]
		job.chunk_mask = int(grid[3])
		job.palette = _palette
		job.detail_tier = st.detail_tier if detail_lod_enabled else LodMesher.DETAIL_FULL
		job.max_quad_tiles = maxf(GroundHeight.tile_step() * 4.0, 4.0) if GroundHeight.is_on() else INF

		st.dirty = false
		st.building = true
		st.grid_tiles = job.tiles
		st.grid_protos = job.protos
		st.grid_pal = _palette
		var cb := Callable(job, "run")
		var tid := WorkerThreadPool.add_task(cb, false, "DH section mesh")
		_mesh_jobs.append([tid, job])
		dispatched += 1


static func _pick_majority_tile(tcounts: Dictionary, best_tile: int, tid: int) -> int:
	if tid < 0:
		return best_tile
	var cnt := int(tcounts.get(tid, 0)) + 1
	tcounts[tid] = cnt
	if best_tile < 0:
		return tid
	var best_cnt := int(tcounts.get(best_tile, 0))
	if cnt > best_cnt:
		return tid
	if cnt == best_cnt:
		if best_tile <= 0 and tid > 0:
			return tid
		if (tid > 0 or best_tile <= 0) and tid < best_tile:
			return tid
	return best_tile


func _sample_section_grid(st: SectionState) -> Array:
	var n := st.grid_n
	var total := n * n
	var out_tiles := PackedInt32Array()
	out_tiles.resize(total)
	out_tiles.fill(-1)
	var out_protos := PackedInt32Array()
	out_protos.resize(total)
	var out_flags := PackedByteArray()
	out_flags.resize(total)

	var cx0 := st.sx * st.sec_chunks
	var cy0 := st.sy * st.sec_chunks
	var ent_cat: PackedByteArray = _palette.ent_cat if _palette != null else PackedByteArray()
	var chunk_mask := 0

	if st.cell_tiles <= float(CHUNK):
		var cells_per_chunk := maxi(1, roundi(float(CHUNK) / st.cell_tiles))
		for cy_off in st.sec_chunks:
			for cx_off in st.sec_chunks:
				var chunk: Variant = _get_chunk(cx0 + cx_off, cy0 + cy_off)
				if chunk == null:
					continue
				var ctiles: PackedInt32Array = chunk.tiles
				var cprotos: PackedInt32Array = chunk.protos
				var cflags: PackedByteArray = chunk.flags
				var src_side := roundi(sqrt(float(ctiles.size())))
				if src_side <= 0:
					continue
				if st.level == 0:
					chunk_mask |= 1 << (cy_off * 4 + cx_off)
				if src_side <= cells_per_chunk:
					for ly in cells_per_chunk:
						var sy_src := mini(src_side - 1, (ly * src_side) / cells_per_chunk)
						var dst_row := (cy_off * cells_per_chunk + ly) * n + cx_off * cells_per_chunk
						var src_row := sy_src * src_side
						for lx in cells_per_chunk:
							var si := src_row + mini(src_side - 1, (lx * src_side) / cells_per_chunk)
							var di := dst_row + lx
							out_tiles[di] = ctiles[si]
							if si < cprotos.size():
								out_protos[di] = cprotos[si]
							if si < cflags.size():
								out_flags[di] = cflags[si]
				else:
					var block := maxi(1, src_side / cells_per_chunk)
					var tcounts := {}
					for ly in cells_per_chunk:
						var dst_row := (cy_off * cells_per_chunk + ly) * n + cx_off * cells_per_chunk
						for lx in cells_per_chunk:
							var di := dst_row + lx
							var first_tile := -1
							var first_count := 0
							var uniform := true
							var best_tile := -1
							var best_pid := 0
							var best_prio := -1
							var best_flag := 0
							var y_start := ly * block
							var x_start := lx * block
							for by in range(y_start, mini(src_side, y_start + block)):
								for bx in range(x_start, mini(src_side, x_start + block)):
									var si := by * src_side + bx
									var tid := ctiles[si]
									if tid >= 0:
										if uniform:
											if first_tile < 0:
												first_tile = tid
												first_count = 1
												best_tile = tid
											elif tid == first_tile:
												first_count += 1
											else:
												uniform = false
												tcounts.clear()
												tcounts[first_tile] = first_count
												best_tile = _pick_majority_tile(tcounts, best_tile, tid)
										else:
											best_tile = _pick_majority_tile(tcounts, best_tile, tid)
									if si < cprotos.size():
										var pid := cprotos[si]
										if pid > 0:
											var prio := _cat_priority(ent_cat, pid)
											if prio > best_prio:
												best_prio = prio
												best_pid = pid
												best_flag = cflags[si] if si < cflags.size() else 15
							out_tiles[di] = best_tile
							out_protos[di] = best_pid
							out_flags[di] = best_flag
	else:
		var chunks_per_cell := maxi(1, roundi(st.cell_tiles / float(CHUNK)))
		var tcounts := {}
		for gy in n:
			for gx in n:
				var di := gy * n + gx
				var first_tile := -1
				var first_count := 0
				var uniform := true
				var best_tile := -1
				var best_pid := 0
				var best_prio := -1
				var best_flag := 0
				for dy in chunks_per_cell:
					for dx in chunks_per_cell:
						var chunk: Variant = _get_chunk(cx0 + gx * chunks_per_cell + dx, cy0 + gy * chunks_per_cell + dy)
						if chunk == null:
							continue
						var ctiles: PackedInt32Array = chunk.tiles
						var cprotos: PackedInt32Array = chunk.protos
						var cflags: PackedByteArray = chunk.flags
						var csize := ctiles.size()
						var step := maxi(1, csize / 16)
						var si := 0
						while si < csize:
							var tid := ctiles[si]
							if tid >= 0:
								if uniform:
									if first_tile < 0:
										first_tile = tid
										first_count = 1
										best_tile = tid
									elif tid == first_tile:
										first_count += 1
									else:
										uniform = false
										tcounts.clear()
										tcounts[first_tile] = first_count
										best_tile = _pick_majority_tile(tcounts, best_tile, tid)
								else:
									best_tile = _pick_majority_tile(tcounts, best_tile, tid)
							if si < cprotos.size():
								var pid := cprotos[si]
								if pid > 0:
									var prio := _cat_priority(ent_cat, pid)
									if prio > best_prio:
										best_prio = prio
										best_pid = pid
										best_flag = cflags[si] if si < cflags.size() else 15
							si += step
				out_tiles[di] = best_tile
				out_protos[di] = best_pid
				out_flags[di] = best_flag

	return [out_tiles, out_protos, out_flags, chunk_mask]


static func _cat_priority(ent_cat: PackedByteArray, pid: int) -> int:
	if pid <= 0 or pid >= ent_cat.size():
		return 0
	var c := ent_cat[pid]
	match c:
		LodMesher.CAT_BUILDING, LodMesher.CAT_CLIFF:
			return 4
		LodMesher.CAT_TREE:
			return 3
		LodMesher.CAT_LOW:
			return 2
		LodMesher.CAT_ORE:
			return 1
	return 0


func _get_chunk(cx: int, cy: int) -> Variant:
	var c := Vector2i(cx, cy)
	if _mem_chunks.has(c):
		return _mem_chunks[c]
	if _cache != null and _cache.has_method("get_chunk"):
		var ch: Variant = _cache.get_chunk(cx, cy)
		if ch != null:
			_mem_chunks[c] = ch
		return ch
	return null


func _mark_chunk_dirty(cx: int, cy: int) -> void:
	_mark_populated(cx, cy)
	for l in 5:
		var sec := int(SECTION_CHUNKS[l])
		var key := Vector3i(l, floori(float(cx) / float(sec)), floori(float(cy) / float(sec)))
		if _sections.has(key):
			var st: SectionState = _sections[key]
			st.dirty = true
			st.has_data = true
			st.next_sub_msec = 0
			_has_dirty_sections = true
			_bump_serial(st)


func _mark_populated(cx: int, cy: int) -> void:
	for l in 5:
		var sec := int(SECTION_CHUNKS[l])
		var key := Vector3i(l, floori(float(cx) / float(sec)), floori(float(cy) / float(sec)))
		_populated_sections[key] = true


func _bridge_node() -> Node:
	if is_inside_tree():
		return get_node_or_null("/root/Bridge")
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.root != null:
		return tree.root.get_node_or_null("Bridge")
	return null


static func _snap_res(cell_tiles: float) -> int:
	if cell_tiles <= 2.5:
		return 2
	if cell_tiles <= 4.5:
		return 4
	if cell_tiles <= 8.5:
		return 8
	if cell_tiles <= 16.5:
		return 16
	return 32


func _send_stop() -> void:
	_was_streaming = false
	_handshake_sent = false
	_in_flight.clear()
	var bridge := _bridge_node()
	if bridge != null and bool(bridge.get("connected")) and bridge.has_method("send"):
		bridge.send({"t": "lod_sub", "act": "stop"})


func _send_map_handshake(bridge: Node) -> void:
	_sub_q += 1
	var cmd := {"t": "lod_sub", "q": _sub_q, "act": "map"}
	if _surface_index >= 1:
		cmd["si"] = _surface_index
	bridge.send(cmd)
	if not _cached_region_revs.is_empty():
		var rg: Array = []
		for r_v: Variant in _cached_region_revs:
			if r_v is Vector2i:
				var r := r_v as Vector2i
				rg.append([r.x, r.y, int(_cached_region_revs[r])])
				if rg.size() >= 512:
					break
		if not rg.is_empty():
			var r_cmd := {"t": "lod_sub", "q": _sub_q, "act": "revs", "rg": rg}
			if _surface_index >= 1:
				r_cmd["si"] = _surface_index
			bridge.send(r_cmd)
	_handshake_sent = true
	_was_streaming = true
	_map_timer = 0.0


static func _section_cell_step(st: SectionState) -> int:
	return maxi(1, roundi(st.cell_tiles / float(CHUNK)))


func _mark_charted_section(c: Vector2i) -> void:
	for l in 5:
		var sec := int(SECTION_CHUNKS[l])
		var k := Vector3i(l, floori(float(c.x) / float(sec)), floori(float(c.y) / float(sec)))
		if map_old:
			_charted_sections[k] = true
		else:
			_charted_sec_cache[k] = true


## Whether chunk `c` is charted, as the last map (and `lod` messages since) say.
func is_charted(c: Vector2i) -> bool:
	if map_old:
		return _charted.has(c)
	if _charted_extra.has(c):
		return true
	var row: Variant = _charted_rows.get(c.y)
	return row != null and runs_have(row as PackedInt32Array, c.x)


## Whether section `k` (level, sx, sy) holds a charted chunk.
func section_charted(k: Vector3i) -> bool:
	if map_old:
		return _charted_sections.has(k)
	var v: Variant = _charted_sec_cache.get(k)
	if v != null:
		return bool(v)
	var sec := int(SECTION_CHUNKS[k.x])
	var x0 := k.y * sec
	var found := false
	for cy in range(k.z * sec, k.z * sec + sec):
		var row: Variant = _charted_rows.get(cy)
		if row != null and runs_meet(row as PackedInt32Array, x0, x0 + sec):
			found = true
			break
	_charted_sec_cache[k] = found
	return found


## Half-open runs [x0, x1, ...] sorted: whether x is in one (binary search).
static func runs_have(runs: PackedInt32Array, x: int) -> bool:
	var lo := 0
	var hi := runs.size() / 2 - 1
	while lo <= hi:
		var mid := (lo + hi) >> 1
		if x < runs[mid * 2]:
			hi = mid - 1
		elif x >= runs[mid * 2 + 1]:
			lo = mid + 1
		else:
			return true
	return false


## Whether any run meets [a, b).
static func runs_meet(runs: PackedInt32Array, a: int, b: int) -> bool:
	var lo := 0
	var hi := runs.size() / 2 - 1
	var first := runs.size() / 2  # the first run ending after a
	while lo <= hi:
		var mid := (lo + hi) >> 1
		if runs[mid * 2 + 1] > a:
			first = mid
			hi = mid - 1
		else:
			lo = mid + 1
	return first < runs.size() / 2 and runs[first * 2] < b


## [x0, x1) minus the runs: the parts of it not in them, as runs.
static func runs_subtract(x0: int, x1: int, runs: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	var at := x0
	for i in range(0, runs.size(), 2):
		var a := runs[i]
		var b := runs[i + 1]
		if b <= at:
			continue
		if a >= x1:
			break
		if a > at:
			out.append_array([at, a])
		at = maxi(at, b)
		if at >= x1:
			break
	if at < x1:
		out.append_array([at, x1])
	return out


## One `lodm` part's rows, kept as runs (a row may go on in the next part).
func _add_map_rows(rows: Array) -> void:
	for row_v: Variant in rows:
		if not (row_v is Array):
			continue
		var row := row_v as Array
		if row.size() < 3:
			continue
		var cy := int(row[0])
		var runs: PackedInt32Array = _map_pending_rows.get(cy, PackedInt32Array())
		var ri := 1
		while ri + 1 < row.size():
			var x0 := int(row[ri])
			var cnt := int(row[ri + 1])
			if cnt > 0:
				runs.append_array([x0, x0 + cnt])
			ri += 2
		_map_pending_rows[cy] = runs


## The map's last part came: its runs become the charted map; sections holding chunks charted since
## the last one are looked at again (all of them the first time), as the old per-chunk path did.
func _finish_map_runs() -> void:
	var was_known := _charted_known
	for cy_v: Variant in _map_pending_rows:
		_map_pending_rows[cy_v] = _normalized_runs(_map_pending_rows[cy_v])
	if was_known:
		for cy_v: Variant in _map_pending_rows:
			var cy := int(cy_v)
			var new_runs: PackedInt32Array = _map_pending_rows[cy_v]
			var old_runs: PackedInt32Array = _charted_rows.get(cy, PackedInt32Array())
			for i in range(0, new_runs.size(), 2):
				var fresh := runs_subtract(new_runs[i], new_runs[i + 1], old_runs)
				for j in range(0, fresh.size(), 2):
					_flag_sections_in_run(cy, fresh[j], fresh[j + 1])
	_charted_rows = _map_pending_rows
	_map_pending_rows = {}
	_charted_extra.clear()
	_charted_sec_cache.clear()
	_charted_known = true
	if not was_known:
		for k in _sections:
			var st: SectionState = _sections[k]
			st.complete = false
			st.needs_missing_scan = true


## Sections over row `cy`'s chunks x0..x1-1 at every level: their missing chunks asked for again.
func _flag_sections_in_run(cy: int, x0: int, x1: int) -> void:
	for l in 5:
		var sec := int(SECTION_CHUNKS[l])
		var sy := floori(float(cy) / float(sec))
		for sx in range(floori(float(x0) / float(sec)), floori(float(x1 - 1) / float(sec)) + 1):
			var sst: SectionState = _sections.get(Vector3i(l, sx, sy))
			if sst != null:
				sst.complete = false
				sst.needs_missing_scan = true


## Runs sorted and merged where they touch.
static func _normalized_runs(runs: PackedInt32Array) -> PackedInt32Array:
	var sorted := true
	for i in range(2, runs.size(), 2):
		if runs[i] < runs[i - 1]:
			sorted = false
			break
	if sorted:
		var touching := false
		for i in range(2, runs.size(), 2):
			if runs[i] == runs[i - 1]:
				touching = true
				break
		if not touching:
			return runs
	var pairs: Array[Vector2i] = []
	for i in range(0, runs.size(), 2):
		pairs.append(Vector2i(runs[i], runs[i + 1]))
	pairs.sort()
	var out := PackedInt32Array()
	for p in pairs:
		if not out.is_empty() and p.x <= out[out.size() - 1]:
			out[out.size() - 1] = maxi(out[out.size() - 1], p.y)
		else:
			out.append_array([p.x, p.y])
	return out


func _rebuild_charted_sections() -> void:
	_charted_sections.clear()
	for c_v: Variant in _charted:
		if not (c_v is Vector2i):
			continue
		var c := c_v as Vector2i
		_charted_sections[Vector3i(0, floori(float(c.x) / 4.0), floori(float(c.y) / 4.0))] = true
	var l0_keys: Array = _charted_sections.keys()
	for k0_v: Variant in l0_keys:
		var k0 := k0_v as Vector3i
		var sx := k0.y
		var sy := k0.z
		for l in range(1, 5):
			var sh := l
			var lx := sx >> sh if sx >= 0 else -((-sx + (1 << sh) - 1) >> sh)
			var ly := sy >> sh if sy >= 0 else -((-sy + (1 << sh) - 1) >> sh)
			_charted_sections[Vector3i(l, lx, ly)] = true


func _collect_want_batch(bucket: Array, missing_only: bool, fixed_res: int, now: int) -> Array:
	var chosen_res := fixed_res
	var batch: Array = []
	var batch_limit := LOD_SUB_BATCH_COARSE if (fixed_res >= 16) else LOD_SUB_BATCH
	var scan_t0 := Time.get_ticks_usec()
	var sections_scanned := 0

	for entry: Array in bucket:
		if batch.size() >= batch_limit:
			break
		if sections_scanned > 0 and Time.get_ticks_usec() - scan_t0 >= SUB_SCAN_BUDGET_USEC:
			break
		var st: SectionState = entry[5]
		if missing_only and not st.needs_missing_scan:
			continue
		var target_res := int(entry[3])
		var req_res := fixed_res if fixed_res > 0 else target_res
		if not missing_only and chosen_res >= 0 and target_res != chosen_res:
			continue

		sections_scanned += 1
		var cx0 := st.sx * st.sec_chunks
		var cy0 := st.sy * st.sec_chunks
		var step := _section_cell_step(st)
		var all_satisfied := true
		var any_missing_null := false
		var any_pending_cache := false
		var cooldown_skipped := 0
		var added_from_st := 0
		var hit_batch_cap := false

		for cy_off in range(0, st.sec_chunks, step):
			for cx_off in range(0, st.sec_chunks, step):
				var block_has_any := false
				var block_satisfied := false
				var block_pending_cache := false
				var pick := Vector2i(0x7fffffff, 0)
				for dy in step:
					for dx in step:
						var c := Vector2i(cx0 + cx_off + dx, cy0 + cy_off + dy)
						if _missing_chunks.has(c):
							continue
						if _charted_known and not is_charted(c):
							continue
						if _is_cache_region_pending(c):
							block_pending_cache = true
							any_pending_cache = true
							continue
						var existing: Variant = _get_chunk(c.x, c.y)
						if existing != null:
							block_has_any = true
							if not _stale_chunks.has(c) and int(existing.res) <= target_res:
								block_satisfied = true
								break
							if pick.x == 0x7fffffff or _stale_chunks.has(c):
								pick = c
						elif pick.x == 0x7fffffff:
							pick = c
					if block_satisfied:
						break
				if block_satisfied:
					continue
				if block_pending_cache:
					all_satisfied = false
					continue
				if pick.x == 0x7fffffff:
					continue
				all_satisfied = false
				if not block_has_any:
					any_missing_null = true
				if missing_only and block_has_any:
					continue
				if batch.size() >= batch_limit:
					hit_batch_cap = true
					continue
				var last_req := int(_requested_chunks.get(pick, -100000))
				if now - last_req < 10000:
					cooldown_skipped += 1
					continue
				if chosen_res < 0:
					chosen_res = req_res
					batch_limit = LOD_SUB_BATCH_COARSE if chosen_res >= 16 else LOD_SUB_BATCH
				_requested_chunks[pick] = now
				_in_flight[pick] = now
				batch.append([pick.x, pick.y])
				added_from_st += 1

		if all_satisfied and not any_pending_cache and _charted_known:
			st.complete = true
			st.needs_missing_scan = false
		elif missing_only and not any_pending_cache and not hit_batch_cap and not any_missing_null and _charted_known:
			st.needs_missing_scan = false
		if not missing_only and added_from_st == 0 and cooldown_skipped > 0 and batch.size() < batch_limit:
			st.next_sub_msec = now + 2000

	return [chosen_res, batch]


func _drive_lod_sub(cam_pos: Vector3, frustum: Array[Plane]) -> void:
	var bridge := _bridge_node()
	if bridge == null or not bool(bridge.get("connected")) or not bool(bridge.get("world_ready")) or not bool(bridge.get("lod_supported")):
		return
	if not _handshake_sent:
		_send_map_handshake(bridge)
		return

	var map_in_flight := _map_parts_total > 0 and _map_parts_seen < _map_parts_total
	if not _charted_known and map_in_flight:
		return
	if not map_in_flight:
		_map_timer += LOD_SUB_INTERVAL
		var map_wait := MAP_IDLE_REFRESH_INTERVAL if _charted_known else MAP_REFRESH_INTERVAL
		if _map_timer >= map_wait:
			_map_timer = 0.0
			_sub_q += 1
			var refresh_cmd := {"t": "lod_sub", "q": _sub_q, "act": "map"}
			if _surface_index >= 1:
				refresh_cmd["si"] = _surface_index
			bridge.send(refresh_cmd)

	_revs_timer += LOD_SUB_INTERVAL
	if _revs_timer >= REVS_REFRESH_INTERVAL:
		_revs_timer = 0.0
		var rev_source := _known_region_revs if not _known_region_revs.is_empty() else _cached_region_revs
		if not rev_source.is_empty():
			var rg: Array = []
			for r_v: Variant in rev_source:
				if r_v is Vector2i:
					var r := r_v as Vector2i
					rg.append([r.x, r.y, int(rev_source[r])])
					if rg.size() >= 512:
						break
			if not rg.is_empty():
				var revs_cmd := {"t": "lod_sub", "q": _sub_q, "act": "revs", "rg": rg}
				if _surface_index >= 1:
					revs_cmd["si"] = _surface_index
				bridge.send(revs_cmd)

	var now := Time.get_ticks_msec()
	for fc_v: Variant in _in_flight.keys():
		if now - int(_in_flight[fc_v]) >= 10000:
			_in_flight.erase(fc_v)
	if not _in_flight.is_empty():
		if now - _last_lod_rx_msec < 2000 and now - _last_want_msec < 45000:
			return
		_in_flight.clear()

	var outer_missing: Array = []
	var near_missing: Array = []
	var all_entries: Array = []
	for k in _sections:
		var st: SectionState = _sections[k]
		if st.complete or st.next_sub_msec > now:
			continue
		if _charted_known and not section_charted(k):
			st.complete = true
			st.needs_missing_scan = false
			continue
		var span := float(st.sec_chunks * CHUNK)
		var center3 := Vector3((float(st.sx) + 0.5) * span, 0.0, (float(st.sy) + 0.5) * span)
		var in_view := true
		if not frustum.is_empty():
			var bound := span * 0.75 + 16.0
			for pl: Plane in frustum:
				if pl.distance_to(center3) > bound:
					in_view = false
					break
		var has_node := st.node != null and is_instance_valid(st.node)
		var target_res := _snap_res(st.cell_tiles)
		var row := [in_view, has_node, st.level, target_res, cam_pos.distance_squared_to(center3), st]
		all_entries.append(row)
		if st.needs_missing_scan:
			if target_res >= 32:
				outer_missing.append(row)
			else:
				near_missing.append(row)

	if all_entries.is_empty():
		return

	var cmp_pass1 := func(a: Array, b: Array) -> bool:
		if bool(a[0]) != bool(b[0]):
			return bool(a[0])
		if bool(a[1]) != bool(b[1]):
			return not bool(a[1])
		return float(a[4]) < float(b[4])

	var chosen_res := -1
	var batch: Array = []
	var first_bucket := outer_missing if _prefer_far_batch else near_missing
	var second_bucket := near_missing if _prefer_far_batch else outer_missing
	var first_res := 32 if _prefer_far_batch else 16
	var second_res := 16 if _prefer_far_batch else 32

	if not first_bucket.is_empty():
		first_bucket.sort_custom(cmp_pass1)
		var res1 := _collect_want_batch(first_bucket, true, first_res, now)
		if not (res1[1] as Array).is_empty():
			chosen_res = int(res1[0])
			batch = res1[1]
			_prefer_far_batch = not _prefer_far_batch

	if batch.is_empty() and not second_bucket.is_empty():
		second_bucket.sort_custom(cmp_pass1)
		var res2 := _collect_want_batch(second_bucket, true, second_res, now)
		if not (res2[1] as Array).is_empty():
			chosen_res = int(res2[0])
			batch = res2[1]
			_prefer_far_batch = not _prefer_far_batch

	if batch.is_empty():
		var cmp_pass2 := func(a: Array, b: Array) -> bool:
			if bool(a[0]) != bool(b[0]):
				return bool(a[0])
			if int(a[2]) != int(b[2]):
				return int(a[2]) < int(b[2])
			return float(a[4]) < float(b[4])
		all_entries.sort_custom(cmp_pass2)
		var res_ref := _collect_want_batch(all_entries, false, -1, now)
		chosen_res = int(res_ref[0])
		batch = res_ref[1]

	if not batch.is_empty() and chosen_res >= 0:
		_send_lod_want(bridge, chosen_res, batch)
		_last_want_msec = now
		_last_lod_rx_msec = now
		_was_streaming = true


func _send_lod_want(bridge: Node, target_res: int, batch: Array) -> void:
	if bridge == null or not bridge.has_method("send"):
		return
	var cmd := {"t": "lod_sub", "q": _sub_q, "act": "want", "res": target_res, "c": batch}
	if _surface_index >= 1:
		cmd["si"] = _surface_index
	bridge.send(cmd)


func _clear_sections() -> void:
	for entry: Dictionary in _retiring:
		var node: Variant = entry.get("node")
		if node != null and is_instance_valid(node):
			(node as MeshInstance3D).queue_free()
	_retiring.clear()
	for k in _sections:
		var st: SectionState = _sections[k]
		_bump_serial(st)
		if st.node != null and is_instance_valid(st.node):
			st.node.queue_free()
	_sections.clear()
	_lod0_vis_dirty = true


static func _budget_grant(system: StringName) -> int:
	if FrameBudget.SYSTEMS.has(system):
		return FrameBudget.grant(system)
	return FALLBACK_INSTALL_USEC


static func _budget_spent(system: StringName, usec: int, waiting: int) -> void:
	if FrameBudget.SYSTEMS.has(system):
		FrameBudget.spent(system, usec, waiting)


static func _budget_waiting(system: StringName, n: int) -> void:
	if FrameBudget.SYSTEMS.has(system):
		FrameBudget.waiting(system, n)
