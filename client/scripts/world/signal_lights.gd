extends Node3D
## Rail signal and chain signal distance glows.
## Gives every active `rail-signal` and `rail-chain-signal` (green/yellow/red/blue, from live
## `st` or chunk-snapshot `extra.sg` hints past `focus.r`) an additive billboard glow card drawn
## after screen-space grading (`SignalGlows` MultiMesh). Real `OmniLight3D`s are off by default
## (`--signal-omni-lights=on` restores the pooled LOD-tied real `OmniLight3D`s).

const ProtoDB := preload("res://scripts/world/protos.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const LampLights := preload("res://scripts/world/lamp_lights.gd")
const ViewPriority := preload("res://scripts/world/view_priority.gd")
const GLOW_SHADER := preload("res://shaders/signal_glow.gdshader")
const Switches := preload("res://scripts/switches.gd")

const REFRESH := 0.5
const ON_DARKNESS := 0.3
const DAY_GLOW := 0.25
const DAY_LIGHT := 0.0
const GLOW_INTENSITY := 0.55
const GLOW_SIZE := Vector2(0.36, 0.36)

## LOD tiers scaled from `far_chunks.detail_distance()` by Settings > Graphics > Level of detail.
const LOD_TIERS := {"low": [0.6, 24], "medium": [0.95, 48], "high": [1.25, 96], "ultra": [1.5, 128]}
const DETAIL_DIST_MIN := 24.0
const DETAIL_DIST_MAX := 220.0
const FADE_FRAC := 0.25
const MAX_LIGHTS := 48
const MAX_GLOWS := 8192
const FULL_LIGHTS := 128
const FULL_GLOWS := 32768

const LIGHT_RANGE := 2.2
const LIGHT_ATTENUATION := 2.0
const LIGHT_ENERGY := 0.15

const STATE_COLORS := {
	1: Color(0.22, 1.0, 0.25),   # green
	2: Color(1.0, 0.72, 0.12),   # yellow
	3: Color(1.0, 0.16, 0.12),   # red
	4: Color(0.26, 0.52, 1.0),   # blue
}

const RAIL_SIGNAL_OFFSETS := {
	1: Vector3(0.03, 0.34, -0.43),
	2: Vector3(0.03, 0.34, 0.0),
	3: Vector3(0.03, 0.34, 0.43),
}
const CHAIN_SIGNAL_OFFSET := Vector3(-0.19, 0.28, -0.02)

## `--signal-lights=off`: disable signal distance glows and lights.
static var disabled_by_arg := not Switches.on("--signal-lights")
## `--signal-omni-lights=on`: restore the 48-128 pooled real `OmniLight3D`s near the camera.
static var omni_lights_enabled := Switches.on("--signal-omni-lights", false)
## `--signal-skip-same=off`: every refresh walks every signal again, as before. On: a refresh whose inputs
## (signal states, signals added or gone, focus, darkness, camera, detail distance, hills, caps) are all as
## last time keeps the glows it has; one in SKIP_MAX_IN_A_ROW + 1 is still done in full, so anything not in
## that list (fog seen, the behind-cull) is at most that many refreshes late.
static var skip_same := Switches.on("--signal-skip-same")
const SKIP_MAX_IN_A_ROW := 4

var protos: ProtoDB
var world: Node3D
var far_chunks: Node
var fog: Node
var darkness := 0.0
var focus := Vector2.ZERO
var far_lights_enabled := not LampLights.legacy_lights and not disabled_by_arg

var max_lights := MAX_LIGHTS
var max_glows := MAX_GLOWS
var _lights: Array[OmniLight3D] = []
var _glows: MultiMeshInstance3D
var _lod_quality := ""
var _custom_lod_distance := 0.0
var _base_max_lights := MAX_LIGHTS
var _full_detail := false
var _detail_distance := DETAIL_DIST_MIN
var _timer := 0.25
var _lit := 0
## The kept refresh (skip_same): the inputs of the last full refresh, how many were kept since, a count of
## signals' chunks changed (entities_changed), and refreshes done in full or kept (tests and probes).
var _last_inputs: Array = []
var _skipped := 0
var _sig_serial := 0
var refreshes := 0
var refreshes_kept := 0

class SigRec:
	var unit := 0
	var kind := 0
	var pos := Vector2.ZERO
	var p1 := Vector3.ZERO
	var p2 := Vector3.ZERO
	var p3 := Vector3.ZERO
	var h1 := 0.0
	var h2 := 0.0
	var h3 := 0.0


var _signals := {}  # chunk Vector2i -> Array of SigRec
var _chunk_hills := {}  # chunk Vector2i -> GroundHeight.version()
var _is_signal := {}  # proto_id -> 0 none, 1 rail-signal, 2 rail-chain-signal
var _state_colors_lin := {}  # state int -> linear Color
var _spots := PackedVector3Array()
var _tints := PackedColorArray()
var _real_weights := PackedFloat32Array()
var _mm_buf := PackedFloat32Array()
var _cand_pos := PackedVector3Array()
var _cand_state := PackedInt32Array()
var _cand_d2 := PackedFloat32Array()
var _cand_bucket := PackedInt32Array()
var _near_order: Array[int] = []
var _far_order: Array[int] = []


func _ensure_linear_colors() -> void:
	if _state_colors_lin.is_empty():
		for k in STATE_COLORS:
			_state_colors_lin[k] = (STATE_COLORS[k] as Color).srgb_to_linear()


func _ready() -> void:
	_ensure_linear_colors()
	var quad := QuadMesh.new()
	quad.size = GLOW_SIZE
	var mat := ShaderMaterial.new()
	mat.shader = GLOW_SHADER
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = quad
	mm.instance_count = 0
	_glows = MultiMeshInstance3D.new()
	_glows.name = "SignalGlows"
	_glows.multimesh = mm
	_glows.material_override = mat
	_glows.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_glows)
	if omni_lights_enabled:
		_add_lights(MAX_LIGHTS)
	if world != null and world.has_signal("entities_changed"):
		world.entities_changed.connect(_on_entities_changed)


func _add_lights(n: int) -> void:
	while _lights.size() < n:
		var light := OmniLight3D.new()
		light.light_energy = LIGHT_ENERGY
		light.light_specular = 1.0
		light.omni_range = LIGHT_RANGE
		light.omni_attenuation = LIGHT_ATTENUATION
		light.shadow_enabled = false
		light.visible = false
		add_child(light)
		_lights.append(light)


func apply_lod_quality(quality: String, custom_distance := 0.0) -> void:
	_lod_quality = quality
	_custom_lod_distance = maxf(custom_distance, 0.0)
	if LampLights.legacy_lights or disabled_by_arg:
		_base_max_lights = MAX_LIGHTS
	else:
		var tier: Array = LOD_TIERS.get(quality, LOD_TIERS["medium"])
		_base_max_lights = int(tier[1])
	if not _full_detail:
		max_lights = _base_max_lights
		if omni_lights_enabled:
			_add_lights(max_lights)
		_timer = REFRESH * 0.5


func set_far_lights_enabled(on: bool) -> void:
	far_lights_enabled = on and not LampLights.legacy_lights and not disabled_by_arg
	if not far_lights_enabled:
		_clear_outputs()
	_timer = REFRESH * 0.5


func set_full_detail(on: bool) -> void:
	_full_detail = on
	max_lights = FULL_LIGHTS if on else _base_max_lights
	max_glows = FULL_GLOWS if on else MAX_GLOWS
	if omni_lights_enabled:
		_add_lights(max_lights)
	_timer = REFRESH if on else REFRESH * 0.5


func reset() -> void:
	_signals.clear()
	_chunk_hills.clear()
	_is_signal.clear()
	_cand_pos.resize(0)
	_cand_state.resize(0)
	_cand_d2.resize(0)
	_cand_bucket.resize(0)
	_clear_outputs()
	_timer = REFRESH * 0.5


func _clear_outputs() -> void:
	_last_inputs.clear()  # (--signal-skip-same) what was drawn is gone: the next refresh draws again
	_lit = 0
	_spots = PackedVector3Array()
	_tints = PackedColorArray()
	_real_weights = PackedFloat32Array()
	_near_order.clear()
	_far_order.clear()
	if _glows != null and _glows.multimesh != null:
		_glows.multimesh.visible_instance_count = 0
		_glows.multimesh.custom_aabb = AABB()
	for l in _lights:
		l.visible = false


func lit_count() -> int:
	return _lit


## Kept as an empty stub for `lamp_lights.gd` (`far_glows()` caller).
func far_glows() -> Array:
	return []


func _compute_detail_distance() -> float:
	if _full_detail or LampLights.legacy_lights or _lod_quality == "":
		return DETAIL_DIST_MIN if _lod_quality == "" and not _full_detail and not LampLights.legacy_lights else INF
	var ref_d := 128.0 * clampf(_custom_lod_distance / 48.0, 0.25, 3.0) if _custom_lod_distance > 0.0 else 128.0
	if far_chunks != null and far_chunks.has_method("detail_distance"):
		var fd := float(far_chunks.call("detail_distance"))
		if fd > 0.0:
			ref_d = fd
	var scale := 0.95
	if _custom_lod_distance <= 0.0:
		var tier: Array = LOD_TIERS.get(_lod_quality, LOD_TIERS["medium"])
		scale = float(tier[0])
	return clampf(ref_d * scale, DETAIL_DIST_MIN, DETAIL_DIST_MAX)


func _signal_kind(proto_id: int) -> int:
	var cached: Variant = _is_signal.get(proto_id)
	if cached != null:
		return int(cached)
	var kind := 0
	if protos != null:
		var proto: ProtoDB.EntityProto = protos.entity(proto_id)
		if proto != null:
			if proto.type == "rail-signal":
				kind = 1
			elif proto.type == "rail-chain-signal":
				kind = 2
	_is_signal[proto_id] = kind
	return kind


func _on_entities_changed(c: Vector2i) -> void:
	if world == null:
		return
	_sig_serial += 1
	var cv = world.chunks.get(c)
	if cv == null:
		_signals.erase(c)
		_chunk_hills.erase(c)
		return
	var recs: Array = []
	for rec in cv.entities.values():
		var kind := _signal_kind(rec.proto_id)
		if kind == 0:
			continue
		var proto: ProtoDB.EntityProto = protos.entity(rec.proto_id) if protos != null else null
		if proto == null:
			continue
		var sr := SigRec.new()
		sr.unit = rec.unit
		sr.kind = kind
		sr.pos = rec.pos
		var base_xf := ModelLibrary.placed(proto.name, proto.type, rec.dir, rec.extra, Vector3(rec.pos.x, 0.0, rec.pos.y))
		if kind == 1:
			sr.p1 = base_xf * (RAIL_SIGNAL_OFFSETS[1] as Vector3)
			sr.p2 = base_xf * (RAIL_SIGNAL_OFFSETS[2] as Vector3)
			sr.p3 = base_xf * (RAIL_SIGNAL_OFFSETS[3] as Vector3)
		else:
			sr.p1 = base_xf * CHAIN_SIGNAL_OFFSET
		recs.append(sr)
	if recs.is_empty():
		_signals.erase(c)
		_chunk_hills.erase(c)
	else:
		_signals[c] = recs
		_chunk_hills[c] = -1


## What a refresh draws from, to compare with the last full one's (skip_same); empty when it can't tell
## (a fogged remote view: what has been seen changes with no other sign).
func _inputs_now(cam: Camera3D) -> Array:
	if world == null or protos == null or (fog != null and fog.hiding()):
		return []
	var anim: Variant = world.get("animator")
	var serial: int = int(anim.state_serial) if anim != null and "state_serial" in anim else -1
	var bc: Variant = world.get("behind_cull")
	var bc_on: bool = bc != null and is_instance_valid(bc) and bc.is_active()
	return [serial, _sig_serial, world.chunks.size(), _signals.size(), focus, darkness, _detail_distance,
		GroundHeight.version(), GroundHeight.lift_range(), max_glows, max_lights, _full_detail,
		ViewPriority.tight_cull, bc_on, omni_lights_enabled, LampLights.legacy_lights,
		cam.global_transform if cam != null else Transform3D(),
		cam.get_frustum() if cam != null and cam.is_inside_tree() else []]


static func _lens_offset(kind: int, state: int) -> Vector3:
	if kind == 1:
		return RAIL_SIGNAL_OFFSETS.get(state, RAIL_SIGNAL_OFFSETS[3]) as Vector3
	return CHAIN_SIGNAL_OFFSET


func _cmp_cand(a: int, b: int) -> bool:
	var ba: int = _cand_bucket[a]
	var bb: int = _cand_bucket[b]
	if ba != bb:
		return ba < bb
	return _cand_d2[a] < _cand_d2[b]


func _process(delta: float) -> void:
	_timer += delta
	if _timer < REFRESH:
		return
	_timer = 0.0
	if disabled_by_arg or not far_lights_enabled:
		if _lit > 0:
			_clear_outputs()
		return
	_ensure_linear_colors()
	_near_order.clear()
	_far_order.clear()
	var cand_count := 0
	var cap := _cand_pos.size()
	var night := clampf(darkness / ON_DARKNESS, 0.0, 1.0)
	var glow_share := lerpf(DAY_GLOW, 1.0, night) * GLOW_INTENSITY
	var light_share := lerpf(DAY_LIGHT, 1.0, night)
	_detail_distance = _compute_detail_distance()
	var cam := get_viewport().get_camera_3d() if is_inside_tree() and get_viewport() != null else null
	if skip_same:
		var inputs := _inputs_now(cam)
		if _skipped < SKIP_MAX_IN_A_ROW and not inputs.is_empty() and inputs == _last_inputs:
			_skipped += 1
			refreshes_kept += 1
			return
		_last_inputs = inputs
		_skipped = 0
	refreshes += 1
	var use_frustum := not LampLights.legacy_lights and not _full_detail and cam != null
	var fctx := LampLights.frustum_context(cam) if use_frustum else {}
	var use_planes := use_frustum and not fctx.is_empty()
	var hr := GroundHeight.lift_range()
	var margin := LIGHT_RANGE + absf(hr.y - hr.x) + 4.0
	var det2 := _detail_distance * _detail_distance
	var near2 := 36.0 if ViewPriority.tight_cull else LIGHT_RANGE * LIGHT_RANGE * 4.0
	if world != null and protos != null:
		var fogging: bool = fog != null and fog.hiding()
		var bc: Variant = world.get("behind_cull")
		var check_behind: bool = ViewPriority.tight_cull and not _full_detail and bc != null and is_instance_valid(bc) and bc.is_active()
		var work_map: Dictionary = world.working
		var hills := GroundHeight.version()
		for c in _signals.keys():
			if not world.chunks.has(c):
				_signals.erase(c)
				_chunk_hills.erase(c)
				continue
			if check_behind and bc.hidden(c):
				continue
			if fogging and not fog.seen(Vector2(c) * 32.0 + Vector2(16.0, 16.0)):
				continue
			var chunk_recs: Array = _signals[c]
			if int(_chunk_hills.get(c, -1)) != hills:
				for sr_var in chunk_recs:
					var srh: SigRec = sr_var
					srh.h1 = GroundHeight.at(srh.p1.x, srh.p1.z)
					if srh.kind == 1:
						srh.h2 = GroundHeight.at(srh.p2.x, srh.p2.z)
						srh.h3 = GroundHeight.at(srh.p3.x, srh.p3.z)
				_chunk_hills[c] = hills
			for sr_var in chunk_recs:
				var sr: SigRec = sr_var
				var rec = world.entities.get(sr.unit)
				if rec == null:
					continue
				var sig_state: int = int(work_map[sr.unit]) if work_map.has(sr.unit) else int(rec.extra.get("sg", 0))
				if sig_state < 1 or sig_state > 4:
					continue
				var wpos: Vector3
				if sr.kind == 1:
					if sig_state == 1:
						wpos = Vector3(sr.p1.x, sr.p1.y + sr.h1, sr.p1.z)
					elif sig_state == 2:
						wpos = Vector3(sr.p2.x, sr.p2.y + sr.h2, sr.p2.z)
					else:
						wpos = Vector3(sr.p3.x, sr.p3.y + sr.h3, sr.p3.z)
				else:
					wpos = Vector3(sr.p1.x, sr.p1.y + sr.h1, sr.p1.z)
				var dx := wpos.x - focus.x
				var dz := wpos.z - focus.y
				var d2 := dx * dx + dz * dz
				var idx := cand_count
				if idx >= cap:
					cap = maxi(64, cap * 2)
					_cand_pos.resize(cap)
					_cand_state.resize(cap)
					_cand_d2.resize(cap)
					_cand_bucket.resize(cap)
				_cand_pos[idx] = wpos
				_cand_state[idx] = sig_state
				_cand_d2[idx] = d2
				if d2 <= det2:
					var vis := not use_planes or d2 <= near2 or LampLights.in_frustum(fctx, wpos, margin)
					_cand_bucket[idx] = 0 if vis else 1
					_near_order.append(idx)
				else:
					_cand_bucket[idx] = 2
					_far_order.append(idx)
				cand_count += 1
	if _near_order.size() > 1:
		_near_order.sort_custom(_cmp_cand)
	if not _far_order.is_empty() and _near_order.size() + _far_order.size() > max_glows:
		if use_planes:
			for fidx: int in _far_order:
				if not LampLights.in_frustum(fctx, _cand_pos[fidx], margin):
					_cand_bucket[fidx] = 3
		if _far_order.size() > 1:
			_far_order.sort_custom(_cmp_cand)
	var order: Array[int] = _near_order
	if not _far_order.is_empty():
		order.append_array(_far_order)
	var total := order.size()
	_lit = mini(total, max_glows)
	var mm := _glows.multimesh
	_spots.resize(_lit)
	_tints.resize(_lit)
	_real_weights.resize(_lit)
	if _lit > 0:
		if mm.instance_count < _lit:
			mm.instance_count = maxi(_lit, mm.instance_count * 2)
		var need_floats := mm.instance_count * 16
		if _mm_buf.size() != need_floats:
			_mm_buf.resize(need_floats)
		var min_v := Vector3(INF, INF, INF)
		var max_v := Vector3(-INF, -INF, -INF)
		for i in _lit:
			var idx: int = order[i]
			var wpos: Vector3 = _cand_pos[idx]
			var sig_state: int = _cand_state[idx]
			var lin := _state_colors_lin[sig_state] as Color
			var tint := Color(lin.r * glow_share, lin.g * glow_share, lin.b * glow_share, 1.0)
			_spots[i] = wpos
			_tints[i] = tint
			_real_weights[i] = 0.0
			var o := i * 16
			_mm_buf[o] = 1.0
			_mm_buf[o + 1] = 0.0
			_mm_buf[o + 2] = 0.0
			_mm_buf[o + 3] = wpos.x
			_mm_buf[o + 4] = 0.0
			_mm_buf[o + 5] = 1.0
			_mm_buf[o + 6] = 0.0
			_mm_buf[o + 7] = wpos.y
			_mm_buf[o + 8] = 0.0
			_mm_buf[o + 9] = 0.0
			_mm_buf[o + 10] = 1.0
			_mm_buf[o + 11] = wpos.z
			_mm_buf[o + 12] = tint.r
			_mm_buf[o + 13] = tint.g
			_mm_buf[o + 14] = tint.b
			_mm_buf[o + 15] = 1.0
			min_v = min_v.min(wpos)
			max_v = max_v.max(wpos)
		mm.buffer = _mm_buf
		mm.custom_aabb = AABB(min_v - Vector3(2.0, 2.0, 2.0), (max_v - min_v) + Vector3(4.0, 4.0, 4.0))
	else:
		mm.custom_aabb = AABB()
	mm.visible_instance_count = _lit
	if not omni_lights_enabled:
		for l in _lights:
			if l.visible:
				l.visible = false
		return
	if _lights.size() < max_lights:
		_add_lights(max_lights)
	var in_view_cut := _detail_distance
	if not LampLights.legacy_lights and not _full_detail and _lit > max_lights and max_lights > 0:
		var last_idx := mini(_lit, max_lights) - 1
		var last_cand: int = order[last_idx]
		var next_cand: int = order[max_lights]
		if _cand_bucket[last_cand] == 0 and _cand_bucket[next_cand] == 0:
			in_view_cut = minf(_detail_distance, maxf(sqrt(_cand_d2[last_cand]), 16.0))
	var max_bucket := 0 if ViewPriority.tight_cull else 1
	for i in _lights.size():
		var light := _lights[i]
		var eligible := night > 0.01 and i < _lit and i < max_lights and (_full_detail or _cand_bucket[order[i]] <= max_bucket)
		if not eligible:
			light.visible = false
			continue
		var idx: int = order[i]
		var rw := 1.0
		if not _full_detail and not LampLights.legacy_lights:
			var dist := sqrt(_cand_d2[idx])
			var cut := in_view_cut if _cand_bucket[idx] == 0 else _detail_distance
			rw = LampLights.smooth_fade(cut * (1.0 - FADE_FRAC), cut, dist)
		if rw <= 0.01:
			light.visible = false
			_real_weights[i] = 0.0
			continue
		_real_weights[i] = rw
		var wpos: Vector3 = _cand_pos[idx]
		var col := STATE_COLORS[_cand_state[idx]] as Color
		light.visible = true
		light.position = wpos + Vector3(0.0, 0.18, 0.0)
		light.light_color = col
		light.light_energy = LIGHT_ENERGY * light_share * rw
