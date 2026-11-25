extends RefCounted
## Dumps nearby chunks' building MultiMeshes, ModelLods state, cross-fade uniforms, bounds, and
## FarChunks / BehindCull visibility flags to a text file (`user://debug/lod-dump.txt`) so live
## invisible-building bugs can be diagnosed without guessing.

const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const FarChunks := preload("res://scripts/world/far_chunks.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const PipelineWarm := preload("res://scripts/world/pipeline_warm.gd")
const ChunkView := preload("res://scripts/world/chunk_view.gd")
const BeltLods := preload("res://scripts/world/belt_lods.gd")

const WATCH_PROTOS := [
	"biolab", "foundry", "electromagnetic-plant", "cryogenic-plant", "lab",
]


## Inspects loaded chunks within `radius` (Chebyshev, in chunks) of the focus or camera, writes a
## detailed report to `out_path`, and returns `{"ok", "path", "chunks", "anomalies", "summary", "text"}`.
static func dump(main: Node, out_path := "user://debug/lod-dump.txt", radius := 2) -> Dictionary:
	var world: Node3D = null
	if main != null and is_instance_valid(main):
		var wv: Variant = main.get("world")
		if wv is Node3D and is_instance_valid(wv):
			world = wv as Node3D
	if world == null:
		return {
			"ok": false,
			"path": out_path,
			"chunks": 0,
			"anomalies": 0,
			"summary": "LOD dump: no world",
			"text": "",
		}

	var mesh_names := _build_mesh_names()
	var focus: Vector2 = world.call("focus")
	var focus_chunk: Vector2i = world.call("chunk_of", focus)
	var vp: Viewport = world.get_viewport() if world.is_inside_tree() else null
	var cam: Camera3D = vp.get_camera_3d() if vp != null else null
	var cam_chunk := focus_chunk
	if cam != null:
		cam_chunk = world.call("chunk_of", Vector2(cam.global_position.x, cam.global_position.z))

	var lines: Array[String] = []
	_append_header(lines, world, vp, cam, focus, focus_chunk, cam_chunk, radius)

	var lod_params := _lod_view_params(world, vp, cam, focus)
	var lod_at: Vector3 = lod_params[0]
	var lod_per_tile: float = float(lod_params[1])
	var lod_flat: float = float(lod_params[2])
	lines.append("lod_eval at=(%.2f, %.2f, %.2f) per_tile=%.6f flat=%.6f" % [
		lod_at.x, lod_at.y, lod_at.z, lod_per_tile, lod_flat,
	])
	lines.append("")

	var chunks_dict: Dictionary = world.get("chunks") if world.get("chunks") is Dictionary else {}
	var coords := _collect_chunks(chunks_dict, focus_chunk, cam_chunk, radius)
	var anomaly_lines: Array[String] = []
	var watch_lines: Array[String] = []
	var fc: Variant = world.get("far_chunks")
	var bc: Variant = world.get("behind_cull")
	var dirty_dict: Dictionary = world.get("_dirty") if world.get("_dirty") is Dictionary else {}
	var partial_dict: Dictionary = world.get("_partial") if world.get("_partial") is Dictionary else {}
	var pend_dict: Dictionary = world.get("_pending") if world.get("_pending") is Dictionary else {}
	var prep_dict: Dictionary = world.get("_prep_jobs") if world.get("_prep_jobs") is Dictionary else {}
	var fades_dict: Dictionary = world.get("_lod_fades") if world.get("_lod_fades") is Dictionary else {}

	for c: Vector2i in coords:
		var cv_var: Variant = chunks_dict.get(c)
		if not (cv_var is ChunkView) or not is_instance_valid(cv_var):
			continue
		var cv := cv_var as ChunkView
		_dump_chunk(lines, anomaly_lines, watch_lines, c, cv, world, mesh_names,
			lod_at, lod_per_tile, lod_flat, fc, bc, dirty_dict, partial_dict, pend_dict, prep_dict, fades_dict)

	var text := "\n".join(PackedStringArray(lines)) + "\n"
	var ok := _write_text(out_path, text)
	print("[Zenith] LOD dump saved to %s (%d chunks, %d anomalies)" % [out_path, coords.size(), anomaly_lines.size()])

	var sum_lines: Array[String] = [
		"LOD dump -> %s (%d chunks, %d anomalies)" % [out_path, coords.size(), anomaly_lines.size()],
		"focus_chunk=%s cam_chunk=%s lod_threshold=%.2f lod_bias=%.2f distance_scale=%.2f gen=%d/%d" % [
			str(focus_chunk), str(cam_chunk), ModelLods.lod_threshold, ModelLods.lod_bias,
			ModelLods.distance_scale, ModelLods.level_generation, ModelLods.generation,
		],
	]
	if anomaly_lines.is_empty():
		sum_lines.append("Anomalies: none")
	else:
		sum_lines.append("Anomalies (first %d of %d):" % [mini(anomaly_lines.size(), 20), anomaly_lines.size()])
		for i in mini(anomaly_lines.size(), 20):
			sum_lines.append("  " + anomaly_lines[i])
	if not watch_lines.is_empty():
		sum_lines.append("Watched large buildings:")
		for wl: String in watch_lines:
			sum_lines.append("  " + wl)
	if not ok:
		sum_lines.append("WARNING: failed to write %s" % out_path)

	return {
		"ok": ok,
		"path": out_path,
		"chunks": coords.size(),
		"anomalies": anomaly_lines.size(),
		"summary": "\n".join(PackedStringArray(sum_lines)),
		"text": text,
	}


static func _write_text(out_path: String, text: String) -> bool:
	var base := out_path.get_base_dir()
	if base != "":
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(base))
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	return true


static func _build_mesh_names() -> Dictionary:
	var out := {}
	for name_v: Variant in ModelLibrary._cache:
		var mesh_v: Variant = ModelLibrary._cache[name_v]
		if not (mesh_v is Mesh):
			continue
		var m := mesh_v as Mesh
		var nm := str(name_v)
		if not out.has(m):
			out[m] = nm
		else:
			var cur := str(out[m])
			var nm_plain := not ("@" in nm)
			var cur_plain := not ("@" in cur)
			if (nm_plain and not cur_plain) or (nm_plain == cur_plain and nm.length() < cur.length()):
				out[m] = nm
	return out


static func _append_header(lines: Array[String], world: Node3D, vp: Viewport, cam: Camera3D,
		focus: Vector2, focus_chunk: Vector2i, cam_chunk: Vector2i, radius: int) -> void:
	lines.append("=== Zenith Building LOD Dump ===")
	lines.append("focus=(%.2f, %.2f) focus_chunk=%s cam_chunk=%s radius=%d" % [
		focus.x, focus.y, str(focus_chunk), str(cam_chunk), radius,
	])
	if cam != null:
		var p := cam.global_position
		var r := cam.global_rotation_degrees
		var proj := "ORTHO" if cam.projection == Camera3D.PROJECTION_ORTHOGONAL else "PERSP"
		lines.append("camera pos=(%.2f, %.2f, %.2f) rot_deg=(%.1f, %.1f, %.1f) %s fov=%.1f size=%.1f near=%.2f far=%.1f" % [
			p.x, p.y, p.z, r.x, r.y, r.z, proj, cam.fov, cam.size, cam.near, cam.far,
		])
	else:
		lines.append("camera=null")
	if vp != null:
		var vs := vp.get_visible_rect().size
		lines.append("viewport size=%dx%d scaling_mode=%d scaling_scale=%.2f mesh_lod_threshold=%.3f use_taa=%s msaa_3d=%d screen_space_aa=%d" % [
			int(vs.x), int(vs.y), int(vp.scaling_3d_mode), vp.scaling_3d_scale, vp.mesh_lod_threshold,
			str(vp.use_taa), int(vp.msaa_3d), int(vp.screen_space_aa),
		])
	else:
		lines.append("viewport=null")
	lines.append("ModelLods thresh=%.3f bias=%.3f dist_scale=%.3f custom_dist=%.1f max_lines=%.0f full_detail=%s view_lods=%s level_gen=%d gen=%d busy=%s q=%d run=%d" % [
		ModelLods.lod_threshold, ModelLods.lod_bias, ModelLods.distance_scale, ModelLods.custom_distance,
		ModelLods.max_lines, str(ModelLods.full_detail), str(ModelLods.view_lods),
		ModelLods.level_generation, ModelLods.generation, str(ModelLods.busy()),
		ModelLods._queue.size(), ModelLods._running.size(),
	])
	var w_chunks: int = (world.get("chunks") as Dictionary).size() if world.get("chunks") is Dictionary else 0
	var w_fades: int = (world.get("_lod_fades") as Dictionary).size() if world.get("_lod_fades") is Dictionary else 0
	var w_now: int = (world.get("_lod_now") as Dictionary).size() if world.get("_lod_now") is Dictionary else 0
	var w_dirty: int = (world.get("_dirty") as Dictionary).size() if world.get("_dirty") is Dictionary else 0
	var w_partial: int = (world.get("_partial") as Dictionary).size() if world.get("_partial") is Dictionary else 0
	var w_pend: int = (world.get("_pending") as Dictionary).size() if world.get("_pending") is Dictionary else 0
	var w_prep: int = (world.get("_prep_jobs") as Dictionary).size() if world.get("_prep_jobs") is Dictionary else 0
	lines.append("World lod_by_cam=%s lod_bands=%s lod_slice=%s remote_view=%s chunks=%d fades=%d now=%d dirty=%d partial=%d pend=%d prep=%d" % [
		str(world.get("lod_by_camera")), str(world.get("lod_bands_on")), str(world.get("lod_slice_on")),
		str(world.get("remote_view")), w_chunks, w_fades, w_now, w_dirty, w_partial, w_pend, w_prep,
	])
	var fc: Variant = world.get("far_chunks")
	if fc != null and is_instance_valid(fc):
		lines.append("FarChunks enabled=%s lod_scale=%.2f from=%.1f full=%.1f far_count=%s" % [
			str(fc.get("enabled")), float(fc.get("lod_scale")), float(fc.get("_pass_from")),
			float(fc.get("_pass_full")), str(fc.get("_far_count")),
		])
	var bc: Variant = world.get("behind_cull")
	if bc != null and is_instance_valid(bc):
		lines.append("BehindCull active=%s hidden=%s" % [str(bc.call("is_active")), str(bc.call("hidden_count"))])
	lines.append("GroundHeight holding=%s range=%s margin=%.2f | PipelineWarm enabled=%s pending=%d gen=%d" % [
		str(GroundHeight.holding()), str(GroundHeight.lift_range()), GroundHeight.cull_margin(),
		str(PipelineWarm.enabled), PipelineWarm.pending_count(), PipelineWarm.generation,
	])
	var pack_parts: Array[String] = []
	for pk: Dictionary in ModelPacks.active():
		pack_parts.append("%s:%s" % [str(pk.get("id", "")), ModelPacks.shading(pk)])
	lines.append("Packs=[%s] pbr_packs=%s" % [", ".join(PackedStringArray(pack_parts)), str(ModelPacks.pbr_packs)])


static func _lod_view_params(world: Node3D, vp: Viewport, cam: Camera3D, focus: Vector2) -> Array:
	var height := ModelLods.counted_lines(vp.get_visible_rect().size.y) if vp != null else 1080.0
	var per_tile := -1.0
	var flat := -1.0
	var at := Vector3(focus.x, 0.0, focus.y)
	if ModelLods.full_detail:
		flat = 0.0
		if cam != null:
			at = cam.global_position
	elif not bool(world.get("lod_by_camera")):
		per_tile = ModelLods.lod_threshold * 2.0 * tan(deg_to_rad(17.5)) / height
	elif cam != null and cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		flat = ModelLods.lod_threshold * cam.size / height
		at = cam.global_position
	elif cam != null:
		per_tile = ModelLods.lod_threshold * 2.0 * tan(deg_to_rad(cam.fov) * 0.5) / height
		at = cam.global_position
	return [at, per_tile, flat]


static func _chunk_allowed(c: Vector2i, camera: Vector3, per_tile: float, flat: float) -> float:
	if flat >= 0.0:
		return flat
	if per_tile < 0.0:
		return 0.0
	var x0 := float(c.x * ChunkView.SIZE)
	var z0 := float(c.y * ChunkView.SIZE)
	var dx := maxf(maxf(x0 - camera.x, camera.x - (x0 + float(ChunkView.SIZE))), 0.0)
	var dz := maxf(maxf(z0 - camera.z, camera.z - (z0 + float(ChunkView.SIZE))), 0.0)
	var dy := maxf(camera.y - ChunkView.LOD_HEIGHT, 0.0) if camera.y > 0.0 else -camera.y
	return sqrt(dx * dx + dy * dy + dz * dz) * per_tile


static func _collect_chunks(chunks_dict: Dictionary, focus_chunk: Vector2i, cam_chunk: Vector2i, radius: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for key_v: Variant in chunks_dict.keys():
		if not (key_v is Vector2i):
			continue
		var c := key_v as Vector2i
		var df := maxi(absi(c.x - focus_chunk.x), absi(c.y - focus_chunk.y))
		var dc := maxi(absi(c.x - cam_chunk.x), absi(c.y - cam_chunk.y))
		if df <= radius or dc <= radius:
			out.append(c)
	var by_dist := func(a: Vector2i, b: Vector2i) -> bool:
		var da := (a - focus_chunk).length_squared()
		var db := (b - focus_chunk).length_squared()
		if da != db:
			return da < db
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x
	out.sort_custom(by_dist)
	return out


static func _dump_chunk(lines: Array[String], anomaly_lines: Array[String], watch_lines: Array[String],
		c: Vector2i, cv: ChunkView, world: Node3D, mesh_names: Dictionary,
		lod_at: Vector3, lod_per_tile: float, lod_flat: float,
		fc: Variant, bc: Variant, dirty_dict: Dictionary, partial_dict: Dictionary,
		pend_dict: Dictionary, prep_dict: Dictionary, fades_dict: Dictionary) -> void:
	var allowed_now := _chunk_allowed(c, lod_at, lod_per_tile, lod_flat)
	var far_st := cv.far
	var far_node_vis := far_st.node != null and is_instance_valid(far_st.node) and far_st.node.visible
	var behind_hid := bc != null and is_instance_valid(bc) and bool(bc.call("hidden", c))
	lines.append("CHUNK (%d, %d) vis=%s loaded=%s rev=%s ret=%s bld=%s ents=%d nodes=%d lods=%d sh=%d pend=%d fading=%d partial=%s allowed=%.4f last_alw=%.4f gen=%d/%d in_fades=%s q=%s/%s/%s/%s wait_mod=%s tier=%d far=(far=%s full=%s cov=%s ph=%d hid=%d node_vis=%s) behind=%s" % [
		c.x, c.y, str(cv.visible), str(cv.loaded), str(cv.revealed), str(cv.retired), str(cv.building),
		cv.entities.size(), cv._nodes.size(), cv._lods.size(), cv._shadows.size(), cv.pending.size(),
		cv._lod_fading, str(cv.lod_partial), allowed_now, cv._lod_allowed, cv._lod_generation,
		ModelLods.level_generation, str(fades_dict.has(cv)),
		str(dirty_dict.has(c)), str(partial_dict.has(c)), str(pend_dict.has(c)), str(prep_dict.has(c)),
		str(cv.waiting_models), cv.shadow_tier, str(far_st.far), str(far_st.full), str(far_st.covers),
		far_st.phase, far_st.hidden.size(), str(far_node_vis), str(behind_hid),
	])

	var pending_keys := {}
	for pw_v: Variant in cv.pending:
		if pw_v != null and pw_v is ChunkView.Want:
			pending_keys[(pw_v as ChunkView.Want).key] = true

	var proto_counts := {}
	var proto_meshes := {}
	var missing_nodes := {}
	var protos: Variant = world.get("protos")
	if protos != null:
		for rec_v: Variant in cv.entities.values():
			if rec_v == null:
				continue
			var pid: int = int(rec_v.get("proto_id"))
			var proto: Variant = protos.call("entity", pid)
			if proto == null:
				continue
			var pname := str(proto.name)
			var ptype := str(proto.type)
			var extra_v: Variant = rec_v.get("extra")
			var extra: Dictionary = extra_v if extra_v is Dictionary else {}
			if extra.has("gh") or extra.has("tg") or extra.has("hid") or ModelLibrary.hidden(pname):
				continue
			if ModelLibrary.REMNANT_TYPES.has(ptype) or ptype == "resource" or ptype == "character" or ptype == "fish":
				continue
			if ptype == "train-stop" and extra.get("col") is Array and (extra["col"] as Array).size() >= 3:
				continue
			proto_counts[pname] = int(proto_counts.get(pname, 0)) + 1
			var cached := _cached_entity_mesh(pname, ptype, extra, int(rec_v.get("dir")))
			if bool(cached[0]) and cached[1] is Mesh:
				var emesh := cached[1] as Mesh
				proto_meshes[pname] = emesh
				if not far_st.far and far_st.full and not cv.building and not pending_keys.has(emesh):
					var pwarm_ok := not PipelineWarm.enabled or PipelineWarm._ready.has(emesh) or PipelineWarm._seen_mesh.has(emesh)
					if pwarm_ok and not cv._nodes.has(emesh):
						missing_nodes[pname] = int(missing_nodes.get(pname, 0)) + 1

	if not proto_counts.is_empty():
		var pkeys: Array = proto_counts.keys()
		pkeys.sort()
		var pparts := PackedStringArray()
		for pk_v: Variant in pkeys:
			pparts.append("%s=%d" % [str(pk_v), int(proto_counts[pk_v])])
		lines.append("  PROTOS: %s" % " ".join(pparts))

	for miss_name_v: Variant in missing_nodes:
		var miss_name := str(miss_name_v)
		var miss_line := "  ANOMALY MISSING_NODE proto=%s ents=%d" % [miss_name, int(missing_nodes[miss_name_v])]
		lines.append(miss_line)
		anomaly_lines.append("(%d,%d) MISSING_NODE proto=%s ents=%d" % [c.x, c.y, miss_name, int(missing_nodes[miss_name_v])])

	var watched_status := {}
	for wp: String in WATCH_PROTOS:
		if proto_counts.has(wp):
			watched_status[wp] = ["ents=%d%s" % [
				int(proto_counts[wp]),
				" MISSING_NODE" if missing_nodes.has(wp) else "",
			]]

	for key_v: Variant in cv._nodes:
		var label := _key_label(key_v, mesh_names)
		var mmi: MultiMeshInstance3D = cv._nodes[key_v]
		if not is_instance_valid(mmi):
			var bad_line := "  NODE %s INVALID_MMI" % label
			lines.append(bad_line)
			anomaly_lines.append("(%d,%d) %s INVALID_MMI" % [c.x, c.y, label])
			continue
		var mm: MultiMesh = mmi.multimesh
		var st: ChunkView.LodState = cv._lods.get(mmi)
		var proxy_mmi: MultiMeshInstance3D = cv._shadows.get(key_v)
		var levels: Array = ModelLods._levels.get(st.model, []) if st != null and st.model != null else []
		var mesh_tag := _mesh_tag(mm.mesh if mm != null else null, st, levels)
		var surf_info := _surface_summary(mm.mesh if mm != null else null)
		var fade_v: Variant = mmi.get_instance_shader_parameter(&"f3d_lod_fade")
		var fade_str := "unset" if fade_v == null else "%.3f" % float(fade_v)
		var rs_fade_v: Variant = RenderingServer.instance_geometry_get_shader_parameter(mmi.get_instance(), &"f3d_lod_fade")
		var rs_fade_str := "unset" if rs_fade_v == null else "%.3f" % float(rs_fade_v)
		var vi_aabb_str := str(mmi.get_aabb())
		var m_aabb_str := str(mm.mesh.get_aabb()) if mm != null and mm.mesh != null else "null"

		var xf0_str := "none"
		var cd0_str := ""
		var bad_xform := false
		if mm != null and mm.instance_count > 0:
			var xf0 := mm.get_instance_transform(0)
			var sx := xf0.basis.x.length()
			var sy := xf0.basis.y.length()
			var sz := xf0.basis.z.length()
			var fin := xf0.is_finite()
			bad_xform = not fin or sx < 1e-4 or sy < 1e-4 or sz < 1e-4
			xf0_str = "pos=(%.1f,%.1f,%.1f) scale=(%.2f,%.2f,%.2f)" % [
				xf0.origin.x, xf0.origin.y, xf0.origin.z, sx, sy, sz,
			]
			if mm.use_custom_data:
				var cd0 := mm.get_instance_custom_data(0)
				cd0_str = " cd0=(%.2f,%.2f,%.2f,%.2f)" % [cd0.r, cd0.g, cd0.b, cd0.a]

		var want_lvl := -1
		var fade_node_str := "none"
		var st_str := "no_lod"
		var mesh_mismatch := false
		if st != null:
			want_lvl = ModelLods.level_for(levels, st.level, allowed_now)
			var exp_mesh: Mesh = st.model if st.level == 0 else (levels[st.level - 1][0] as Mesh if st.level - 1 < levels.size() else null)
			mesh_mismatch = mm == null or mm.mesh != exp_mesh
			if st.fade != null and is_instance_valid(st.fade):
				var fnp: Variant = st.fade.get_instance_shader_parameter(&"f3d_lod_fade")
				fade_node_str = "vis=%s left=%.3f f=%.3f" % [
					str(st.fade.visible), st.fade_left, float(fnp) if fnp != null else -1.0,
				]
			st_str = "lvl=%d->%d/%d from_app=%s grp=%s fade=%s" % [
				st.level, want_lvl, levels.size(), str(st.from_apply), str(st.group != null), fade_node_str,
			]

		var proxy_str := "none"
		if proxy_mmi != null and is_instance_valid(proxy_mmi):
			var pmm := proxy_mmi.multimesh
			var pready := pmm != null and pmm.mesh != null and ModelLods.is_ready(pmm.mesh)
			proxy_str = "vis=%s ready=%s cnt=%d" % [
				str(proxy_mmi.visible), str(pready), pmm.instance_count if pmm != null else -1,
			]

		var far_hides := fc != null and is_instance_valid(fc) and FarChunks.hides(cv, mmi)
		var rs_fade_mismatch := rs_fade_v != null and (float(rs_fade_v) < 0.999 or (fade_v != null and absf(float(rs_fade_v) - float(fade_v)) > 0.001))
		var tags := _node_anomalies(key_v, cv, mmi, mm, st, fade_v, rs_fade_mismatch, mesh_mismatch, bad_xform, far_hides, int(surf_info[1]) > 0)
		var tag_str := "" if tags.is_empty() else " TAGS=[%s]" % ",".join(PackedStringArray(tags))

		var node_line := "  NODE %s vis=%s tree=%s mesh=%s(%s) inst=%d/%d sh=%d layers=%d fade=%s rs_f=%s aabb=%s vi_aabb=%s m_aabb=%s margin=%.2f hill=%s mm_aabb=%s [%s] %s xf0=[%s]%s proxy=[%s] far_hides=%s%s" % [
			label, str(mmi.visible), str(mmi.is_visible_in_tree()), mesh_tag, str(surf_info[0]),
			mm.visible_instance_count if mm != null else -1, mm.instance_count if mm != null else -1,
			int(mmi.cast_shadow), int(mmi.layers), fade_str, rs_fade_str, str(mmi.custom_aabb), vi_aabb_str, m_aabb_str, mmi.extra_cull_margin,
			str(mmi.has_meta(&"f3d_flat_aabb")), str(mm.custom_aabb) if mm != null else "null",
			str(surf_info[2]), st_str, xf0_str, cd0_str, proxy_str, str(far_hides), tag_str,
		]
		lines.append(node_line)
		if not tags.is_empty():
			anomaly_lines.append("(%d,%d) %s [%s] vis=%s mesh=%s fade=%s rs_f=%s inst=%d/%d %s" % [
				c.x, c.y, label, ",".join(PackedStringArray(tags)), str(mmi.visible),
				mesh_tag, fade_str, rs_fade_str, mm.visible_instance_count if mm != null else -1,
				mm.instance_count if mm != null else -1, st_str,
			])

		for wp: String in WATCH_PROTOS:
			if label == wp or label.begins_with(wp + "@") or label.begins_with(wp + "[") or (proto_meshes.has(wp) and key_v is Mesh and key_v == proto_meshes[wp]):
				var extra_tag := "" if tags.is_empty() else "!" + ",".join(PackedStringArray(tags))
				var wlist: Array = watched_status.get(wp, [])
				wlist.append("%s vis=%s %s fade=%s cnt=%d%s" % [
					label, str(mmi.visible), mesh_tag, fade_str, mm.instance_count if mm != null else -1, extra_tag,
				])
				watched_status[wp] = wlist

	for wp: String in WATCH_PROTOS:
		if watched_status.has(wp):
			var wlist: Array = watched_status[wp]
			var wparts := PackedStringArray()
			for entry_v: Variant in wlist:
				wparts.append(str(entry_v))
			watch_lines.append("(%d,%d) %s: %s" % [c.x, c.y, wp, " | ".join(wparts)])

	if not cv.pending.is_empty():
		var pnames: Array[String] = []
		for pw_v: Variant in cv.pending:
			if pw_v is ChunkView.Want:
				pnames.append(_key_label((pw_v as ChunkView.Want).key, mesh_names))
		lines.append("  PENDING=[%s]" % ", ".join(PackedStringArray(pnames)))

	var known_mmis := {}
	for mmi_v: Variant in cv._nodes.values():
		known_mmis[mmi_v] = true
	for sh_v: Variant in cv._shadows.values():
		known_mmis[sh_v] = true
	for st_v: Variant in cv._lods.values():
		if st_v is ChunkView.LodState and (st_v as ChunkView.LodState).fade != null:
			known_mmis[(st_v as ChunkView.LodState).fade] = true
	if cv.contact_node != null:
		known_mmis[cv.contact_node] = true
	for ch in cv.get_children():
		if ch is MultiMeshInstance3D and not known_mmis.has(ch):
			var och := ch as MultiMeshInstance3D
			var omm := och.multimesh
			var ofade: Variant = och.get_instance_shader_parameter(&"f3d_lod_fade")
			lines.append("  ORPHAN_MMI name=%s vis=%s cnt=%d fade=%s" % [
				och.name, str(och.visible), omm.instance_count if omm != null else -1, str(ofade),
			])


static func _cached_entity_mesh(proto_name: String, proto_type: String, extra: Dictionary, dir: int) -> Array:
	var names: Array = ModelLibrary.entity_models(proto_name, proto_type, extra, dir)
	for n_v: Variant in names:
		var mname := str(n_v)
		if not ModelLibrary._cache.has(mname):
			return [false, null]
		var cached: Variant = ModelLibrary._cache[mname]
		if cached is Mesh:
			return [true, cached as Mesh]
	return [true, null]


static func _key_label(key: Variant, mesh_names: Dictionary) -> String:
	if key is Mesh:
		var m := key as Mesh
		if mesh_names.has(m):
			return str(mesh_names[m])
		return m.resource_name if m.resource_name != "" else "mesh#%d" % m.get_instance_id()
	if key is Array:
		var arr := key as Array
		var head := _key_label(arr[0], mesh_names) if not arr.is_empty() else "empty"
		var tail: Array[String] = []
		for i in range(1, arr.size()):
			tail.append(str(arr[i]))
		return "%s[%s]" % [head, ",".join(PackedStringArray(tail))]
	return str(key)


static func _mesh_tag(mesh: Mesh, st: ChunkView.LodState, levels: Array) -> String:
	if mesh == null:
		return "null"
	if st == null:
		return "mesh"
	if mesh == st.model:
		return "L0"
	for i in levels.size():
		var lvl_entry: Array = levels[i]
		if lvl_entry[0] is Mesh and lvl_entry[0] == mesh:
			return "L%d" % (i + 1)
	return "other"


static func _surface_summary(mesh: Mesh) -> Array:
	if mesh == null:
		return [0, 1, "no_mesh"]
	var sc := mesh.get_surface_count()
	if sc == 0:
		return [0, 1, "0_surfs"]
	var empty_count := 0
	var parts: Array[String] = []
	var am := mesh as ArrayMesh
	var mat0_tag := ""
	for i in sc:
		var vlen := am.surface_get_array_len(i) if am != null else -1
		var ilen := am.surface_get_array_index_len(i) if am != null else -1
		var mat := mesh.surface_get_material(i)
		var has_mat := mat != null
		if (am != null and vlen <= 0) or not has_mat:
			empty_count += 1
		parts.append("s%d:%d/%d%s" % [i, vlen, ilen, "" if has_mat else "!nomat"])
		if i == 0 and has_mat:
			var sh_name := "mat"
			if mat is ShaderMaterial and (mat as ShaderMaterial).shader != null:
				sh_name = (mat as ShaderMaterial).shader.resource_path.get_file()
			mat0_tag = " %s(rp=%d)" % [sh_name, mat.render_priority]
	return [sc, empty_count, " ".join(PackedStringArray(parts)) + mat0_tag]


static func _node_anomalies(key: Variant, cv: ChunkView, mmi: MultiMeshInstance3D, mm: MultiMesh,
		st: ChunkView.LodState, fade_v: Variant, rs_fade_mismatch: bool, mesh_mismatch: bool, bad_xform: bool,
		far_hides: bool, empty_surf: bool) -> Array[String]:
	var tags: Array[String] = []
	var arr_key := key as Array if key is Array else []
	var is_flat_belt: bool = arr_key.size() >= 2 and str(arr_key[1]) == "flat"
	var is_belt_part: bool = cv.belt_flat and (
		cv._belt_models.has(key)
		or (not arr_key.is_empty() and cv._belt_models.has(arr_key[0]))
	)
	var intentional_hidden: bool = cv.far.far or is_flat_belt or is_belt_part
	if not mmi.visible and not intentional_hidden:
		tags.append("HIDDEN")
	if fade_v != null and float(fade_v) < 0.999:
		tags.append("FADE_LOW")
	if rs_fade_mismatch:
		tags.append("RS_FADE_MISMATCH")
	if st != null and st.fade != null:
		tags.append("STUCK_FADE")
	if mm == null or mm.instance_count == 0 or mm.visible_instance_count == 0:
		tags.append("ZERO_INST")
	if mm == null or mm.mesh == null or mm.mesh.get_surface_count() == 0:
		tags.append("NULL_MESH")
	elif empty_surf:
		tags.append("EMPTY_SURF")
	if mesh_mismatch:
		tags.append("MESH_MISMATCH")
	if bad_xform:
		tags.append("BAD_XFORM")
	if not mmi.custom_aabb.position.is_finite() or not mmi.custom_aabb.size.is_finite():
		tags.append("BAD_AABB")
	if not cv.far.far and far_hides:
		tags.append("FAR_HIDES_NEAR")
	return tags
