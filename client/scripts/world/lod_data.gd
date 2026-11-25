extends RefCounted
## Distant Horizon LOD chunk data, RLE codecs, world-chunk baker, and material palette.
## Holds compact downsampled terrain + entity cells at resolutions 2, 4, 8, 16, or 32 tiles/cell
## and an immutable palette snapshot keyed by tile_id and proto_id.

const ProtoDB := preload("res://scripts/world/protos.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const TerrainTextures := preload("res://scripts/world/terrain_textures.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const ModGraphics := preload("res://scripts/world/mod_graphics.gd")
const Looks := preload("res://scripts/world/looks.gd")
const NatureLooks := preload("res://scripts/world/nature_looks.gd")
const Wire := preload("res://scripts/util/wire.gd")

const CHUNK := 32

const CAT_NONE := 0
const CAT_BUILDING := 1
const CAT_TREE := 2
const CAT_CLIFF := 3
const CAT_LOW := 4
const CAT_ORE := 5
const CAT_POLE := 6

const RESOLUTIONS := [2, 4, 8, 16, 32]

## Fallback priority when downsampling without a LodPalette: maps cat_hint (bits 6..7) to rank.
const _HINT_PRIO := [2, 4, 3, 1]  # 0=auto/other (incl. cliff), 1=building, 2=tree, 3=ore/rail/belt

const _RAIL_PIPE_TYPES := {
	"straight-rail": true, "half-diagonal-rail": true, "curved-rail-a": true, "curved-rail-b": true,
	"legacy-straight-rail": true, "legacy-curved-rail": true, "elevated-straight-rail": true,
	"elevated-half-diagonal-rail": true, "elevated-curved-rail-a": true, "elevated-curved-rail-b": true,
	"rail-ramp": true, "rail-support": true,
	"pipe": true, "pipe-to-ground": true, "infinity-pipe": true, "heat-pipe": true, "valve": true,
}

const _LOW_TYPES := {
	"transport-belt": true, "underground-belt": true, "splitter": true, "lane-splitter": true,
	"loader": true, "loader-1x1": true, "linked-belt": true, "inserter": true,
	"land-mine": true,
	"rail-signal": true, "rail-chain-signal": true,
	"arithmetic-combinator": true, "decider-combinator": true, "selector-combinator": true,
	"constant-combinator": true, "power-switch": true, "programmable-speaker": true,
	"display-panel": true,
}

const _SKIP_TYPES := {
	"entity-ghost": true, "tile-ghost": true, "corpse": true, "character-corpse": true,
	"rail-remnants": true, "character": true, "fish": true,
}

const _GLOW2_TYPES := {
	"reactor": true, "fusion-reactor": true, "rocket-silo": true,
}

const _GLOW1_TYPES := {
	"furnace": true, "lab": true, "heating-tower": true, "burner-generator": true,
}

const _ROCK_HINTS := ["rock", "stromatolite", "iceberg", "crater", "vulcanus-chimney"]


static func valid_res(res: int) -> bool:
	return LodChunk._valid_res(res)


class LodChunk extends RefCounted:
	var cx := 0
	var cy := 0
	var res := 8
	var rev := 0
	var tiles := PackedInt32Array()
	var protos := PackedInt32Array()
	var flags := PackedByteArray()

	static func _valid_res(r: int) -> bool:
		return r == 2 or r == 4 or r == 8 or r == 16 or r == 32

	static func _is_num(v: Variant) -> bool:
		if v is int:
			return true
		if v is float:
			return is_finite(float(v))
		return false

	static func _cat_hint_for(cat: int) -> int:
		if cat == CAT_BUILDING:
			return 1
		if cat == CAT_TREE:
			return 2
		if cat == CAT_LOW or cat == CAT_ORE or cat == CAT_POLE:
			return 3
		return 0

	static func _classify_entity(proto_name: String, proto_type: String) -> Vector3i:
		## Returns Vector3i(cat, prio, glow).
		if proto_type == "" and proto_name == "":
			return Vector3i(CAT_NONE, 0, 0)
		if _SKIP_TYPES.has(proto_type) or ProtoDB.NEVER_PLACED.has(proto_type) or ModelLibrary.hidden(proto_name):
			return Vector3i(CAT_NONE, 0, 0)
		var cat := CAT_BUILDING
		var prio := 5
		if proto_type == "resource":
			cat = CAT_ORE
			prio = 1
		elif proto_type == "tree" or proto_type == "plant":
			cat = CAT_TREE
			prio = 3
		elif proto_type == "cliff":
			cat = CAT_CLIFF
			prio = 4
		elif proto_type == "simple-entity":
			var lower := proto_name.to_lower()
			var is_rock := false
			for hint: String in _ROCK_HINTS:
				if hint in lower:
					is_rock = true
					break
			if is_rock:
				cat = CAT_CLIFF
				prio = 4
		elif _RAIL_PIPE_TYPES.has(proto_type):
			cat = CAT_LOW
			prio = 2
		elif proto_type == "electric-pole":
			cat = CAT_POLE
			prio = 1
		elif _LOW_TYPES.has(proto_type):
			cat = CAT_LOW
			prio = 1

		var glow := 0
		var lname := proto_name.to_lower()
		if proto_type == "lamp" or (proto_type == "" and "lamp" in lname):
			glow = 3
		elif _GLOW2_TYPES.has(proto_type) or "nuclear-reactor" in lname or "fusion-reactor" in lname \
				or "rocket-silo" in lname:
			glow = 2
		elif _GLOW1_TYPES.has(proto_type) or "furnace" in lname:
			glow = 1
		return Vector3i(cat, prio, glow)

	## Decodes a JSON/binary `lod` chunk message (`{"cx","cy","res","rv","tl","el"}`).
	static func from_msg(msg: Dictionary) -> LodChunk:
		var none_v: Variant = msg.get("none", false)
		if none_v:
			return null
		var res_v: Variant = msg.get("res", 0)
		if not _is_num(res_v):
			return null
		var r := int(res_v)
		if not _valid_res(r):
			return null
		var cx_v: Variant = msg.get("cx", 0)
		var cy_v: Variant = msg.get("cy", 0)
		var rv_v: Variant = msg.get("rv", 0)
		if not (_is_num(cx_v) and _is_num(cy_v) and _is_num(rv_v)):
			return null
		var tl_raw: Variant = msg.get("tl")
		var el_raw: Variant = msg.get("el")
		var tl_list: Variant = tl_raw if (tl_raw is PackedInt32Array or tl_raw is PackedInt64Array) else Wire.array(tl_raw)
		var el_list: Variant = el_raw if (el_raw is PackedInt32Array or el_raw is PackedInt64Array) else Wire.array(el_raw)
		var n := CHUNK / r
		var total := n * n
		var dec_tiles := _decode_tile_rle(tl_list, total)
		if dec_tiles.size() != total:
			return null
		var dec_ents := _decode_ent_rle(el_list, total)
		if dec_ents.is_empty():
			return null
		var c := LodChunk.new()
		c.cx = int(cx_v)
		c.cy = int(cy_v)
		c.res = r
		c.rev = int(rv_v)
		c.tiles = dec_tiles
		c.protos = dec_ents[0]
		c.flags = dec_ents[1]
		return c

	static func _decode_tile_rle(tl: Variant, total: int) -> PackedInt32Array:
		var sz := _list_size(tl)
		if sz <= 0 or sz % 2 != 0:
			return PackedInt32Array()
		var out := PackedInt32Array()
		out.resize(total)
		var pos := 0
		var i := 0
		while i < sz:
			var tid_v: Variant = tl[i]
			var cnt_v: Variant = tl[i + 1]
			if not (_is_num(tid_v) and _is_num(cnt_v)):
				return PackedInt32Array()
			var tid_f := float(tid_v)
			var cnt_f := float(cnt_v)
			if tid_f < 0.0 or tid_f > 2147483647.0 or cnt_f <= 0.0 or cnt_f > float(total - pos):
				return PackedInt32Array()
			var tid := int(tid_f)
			var cnt := int(cnt_f)
			for _k in cnt:
				out[pos] = tid
				pos += 1
			i += 2
		if pos != total:
			return PackedInt32Array()
		return out

	static func _decode_ent_rle(el: Variant, total: int) -> Array:
		var sz := _list_size(el)
		if sz <= 0 or sz % 3 != 0:
			return []
		var out_p := PackedInt32Array()
		var out_f := PackedByteArray()
		out_p.resize(total)
		out_f.resize(total)
		var pos := 0
		var i := 0
		while i < sz:
			var pid_v: Variant = el[i]
			var flg_v: Variant = el[i + 1]
			var cnt_v: Variant = el[i + 2]
			if not (_is_num(pid_v) and _is_num(flg_v) and _is_num(cnt_v)):
				return []
			var pid_f := float(pid_v)
			var flg_f := float(flg_v)
			var cnt_f := float(cnt_v)
			if pid_f < 0.0 or pid_f > 2147483647.0 or flg_f < 0.0 or flg_f > 255.0 or cnt_f <= 0.0 or cnt_f > float(total - pos):
				return []
			var pid := int(pid_f)
			var flg := int(flg_f)
			var cnt := int(cnt_f)
			for _k in cnt:
				out_p[pos] = pid
				out_f[pos] = flg
				pos += 1
			i += 3
		if pos != total:
			return []
		return [out_p, out_f]

	static func _list_size(list: Variant) -> int:
		if list is Array:
			return (list as Array).size()
		if list is PackedInt32Array:
			return (list as PackedInt32Array).size()
		if list is PackedInt64Array:
			return (list as PackedInt64Array).size()
		return 0

	## Downsamples a loaded 32x32 world chunk into a LodChunk at `target_res`.
	static func bake_from_world_chunk(cx: int, cy: int, rev: int, tile_ids: PackedInt32Array,
			entities: Dictionary, protos_db: Object, target_res := 2) -> LodChunk:
		if not _valid_res(target_res) or tile_ids.size() != CHUNK * CHUNK:
			return null
		var n := CHUNK / target_res
		var total := n * n
		var chunk := LodChunk.new()
		chunk.cx = cx
		chunk.cy = cy
		chunk.res = target_res
		chunk.rev = rev
		chunk.tiles.resize(total)
		chunk.protos.resize(total)
		chunk.flags.resize(total)

		for gy in n:
			var y0 := gy * target_res
			for gx in n:
				var x0 := gx * target_res
				var counts := {}
				var best_tid := 0
				var best_cnt := -1
				for dy in target_res:
					var row := (y0 + dy) * CHUNK + x0
					for dx in target_res:
						var tid := tile_ids[row + dx]
						var cnt := int(counts.get(tid, 0)) + 1
						counts[tid] = cnt
						if cnt > best_cnt or (cnt == best_cnt and _tile_beats(tid, best_tid)):
							best_cnt = cnt
							best_tid = tid
				chunk.tiles[gy * n + gx] = best_tid

		if entities.is_empty():
			return chunk

		var cell_area := float(target_res * target_res)
		var cov_sum := PackedFloat32Array()
		cov_sum.resize(total)
		var max_glow := PackedByteArray()
		max_glow.resize(total)
		var best_prio := PackedByteArray()
		best_prio.resize(total)
		var best_area := PackedFloat32Array()
		best_area.resize(total)
		var best_hint := PackedByteArray()
		best_hint.resize(total)
		var proto_areas: Array = []
		proto_areas.resize(total)

		var origin := Vector2(float(cx * CHUNK), float(cy * CHUNK))
		for rec_v: Variant in entities.values():
			if rec_v == null:
				continue
			var rec: Object = rec_v
			var extra_v: Variant = rec.get("extra")
			var extra: Dictionary = extra_v if extra_v is Dictionary else {}
			if extra.has("gh") or extra.has("tg") or extra.has("hid"):
				continue
			var pid_v: Variant = rec.get("proto_id")
			if not _is_num(pid_v):
				continue
			var pid := int(pid_v)
			if pid <= 0:
				continue
			var proto: Variant = protos_db.entity(pid) if protos_db != null and protos_db.has_method("entity") else null
			if proto == null:
				continue
			var pname := str(proto.name)
			var ptype := str(proto.type)
			var cls := _classify_entity(pname, ptype)
			var cat := cls.x
			if cat == CAT_NONE:
				continue
			var prio := cls.y
			var glow := cls.z
			var hint := _cat_hint_for(cat)

			var pos_v: Variant = rec.get("pos")
			var pos: Vector2 = pos_v if pos_v is Vector2 else Vector2.ZERO
			var dir_v: Variant = rec.get("dir")
			var dir := int(dir_v) if _is_num(dir_v) else 0
			var rect := _entity_rect(proto, pos, dir)
			var local := Rect2(rect.position - origin, rect.size)
			if local.end.x <= 1e-4 or local.position.x >= float(CHUNK) - 1e-4 \
					or local.end.y <= 1e-4 or local.position.y >= float(CHUNK) - 1e-4:
				continue
			var gx0 := clampi(floori((local.position.x + 1e-4) / float(target_res)), 0, n - 1)
			var gx1 := clampi(floori((local.end.x - 1e-4) / float(target_res)), 0, n - 1)
			var gy0 := clampi(floori((local.position.y + 1e-4) / float(target_res)), 0, n - 1)
			var gy1 := clampi(floori((local.end.y - 1e-4) / float(target_res)), 0, n - 1)
			for gy in range(gy0, gy1 + 1):
				var cy0 := float(gy * target_res)
				var cy1 := cy0 + float(target_res)
				var oy := maxf(0.0, minf(local.end.y, cy1) - maxf(local.position.y, cy0))
				if oy <= 0.0:
					continue
				for gx in range(gx0, gx1 + 1):
					var cx0 := float(gx * target_res)
					var cx1 := cx0 + float(target_res)
					var ox := maxf(0.0, minf(local.end.x, cx1) - maxf(local.position.x, cx0))
					var overlap := ox * oy
					if overlap <= 0.0:
						continue
					var idx := gy * n + gx
					cov_sum[idx] += overlap
					if glow > max_glow[idx]:
						max_glow[idx] = glow
					if proto_areas[idx] == null:
						proto_areas[idx] = {}
					var map: Dictionary = proto_areas[idx]
					var acc_area: float = float(map.get(pid, 0.0)) + overlap
					map[pid] = acc_area
					var cur_pid := chunk.protos[idx]
					var cur_prio := best_prio[idx]
					var cur_area := best_area[idx]
					var wins := prio > cur_prio
					if not wins and prio == cur_prio:
						if pid == cur_pid:
							best_area[idx] = acc_area
						elif acc_area > cur_area + 1e-4 or (absf(acc_area - cur_area) <= 1e-4 and (cur_pid == 0 or pid < cur_pid)):
							wins = true
					if wins:
						chunk.protos[idx] = pid
						best_prio[idx] = prio
						best_area[idx] = acc_area
						best_hint[idx] = hint

		for idx in total:
			if chunk.protos[idx] == 0:
				continue
			var frac := clampf(cov_sum[idx] / cell_area, 0.0, 1.0)
			var density := clampi(roundi(frac * 15.0), 1, 15)
			chunk.flags[idx] = (density & 0x0F) | ((max_glow[idx] & 0x03) << 4) | ((best_hint[idx] & 0x03) << 6)
		return chunk

	static func _tile_beats(a: int, b: int) -> bool:
		if b <= 0 and a > 0:
			return true
		if a <= 0 and b > 0:
			return false
		return a < b

	static func _entity_rect(proto: ProtoDB.EntityProto, pos: Vector2, dir: int) -> Rect2:
		var a := proto.box_min
		var b := proto.box_max
		if b.x <= a.x or b.y <= a.y:
			var ts := Vector2(maxf(float(proto.tile_size.x), 1.0), maxf(float(proto.tile_size.y), 1.0))
			a = -ts * 0.5
			b = ts * 0.5
		var qa := a
		var qb := b
		match posmod(int(round(float(dir) / 4.0)), 4):
			1:
				qa = Vector2(-b.y, a.x)
				qb = Vector2(-a.y, b.x)
			2:
				qa = -b
				qb = -a
			3:
				qa = Vector2(a.y, -b.x)
				qb = Vector2(b.y, -a.x)
		return Rect2(pos + qa, qb - qa)

	## Downsamples this chunk to a coarser `target_res` (returns `self` if equal, `null` if invalid/finer).
	func downsample_to(target_res: int, palette: LodPalette = null) -> LodChunk:
		if not _valid_res(target_res) or not _valid_res(res):
			return null
		if target_res == res:
			return self
		if target_res < res:
			return null
		var src_n := CHUNK / res
		var expected := src_n * src_n
		if tiles.size() != expected or protos.size() != expected or flags.size() != expected:
			return null
		var k := target_res / res
		var dst_n := CHUNK / target_res
		var total := dst_n * dst_n
		var out := LodChunk.new()
		out.cx = cx
		out.cy = cy
		out.res = target_res
		out.rev = rev
		out.tiles.resize(total)
		out.protos.resize(total)
		out.flags.resize(total)
		var sub_count := float(k * k)

		for gy in dst_n:
			var sy0 := gy * k
			for gx in dst_n:
				var sx0 := gx * k
				var tile_counts := {}
				var best_tid := 0
				var best_tcnt := -1
				var proto_scores := {}  # pid -> [prio, sum_density, count, hint]
				var best_pid := 0
				var best_prio := -1
				var best_sum_d := -1
				var best_pcnt := -1
				var best_hint := 0
				var max_glow := 0
				var sum_density := 0

				for dy in k:
					var row := (sy0 + dy) * src_n + sx0
					for dx in k:
						var sidx := row + dx
						var tid := tiles[sidx]
						var tcnt := int(tile_counts.get(tid, 0)) + 1
						tile_counts[tid] = tcnt
						if tcnt > best_tcnt or (tcnt == best_tcnt and _tile_beats(tid, best_tid)):
							best_tcnt = tcnt
							best_tid = tid

						var pid := protos[sidx]
						if pid <= 0:
							continue
						var f := int(flags[sidx])
						var dens := maxi(f & 0x0F, 1)
						var glow := (f >> 4) & 0x03
						var hint := (f >> 6) & 0x03
						sum_density += dens
						if glow > max_glow:
							max_glow = glow
						var prio := int(_HINT_PRIO[hint])
						if palette != null and pid < palette.ent_prio.size():
							prio = int(palette.ent_prio[pid])
							hint = _cat_hint_for(int(palette.ent_cat[pid]))
						var entry: Array = proto_scores.get(pid, [prio, 0, 0, hint])
						entry[1] = int(entry[1]) + dens
						entry[2] = int(entry[2]) + 1
						proto_scores[pid] = entry
						var p_sum := int(entry[1])
						var p_cnt := int(entry[2])
						var wins := prio > best_prio
						if not wins and prio == best_prio:
							if p_sum > best_sum_d:
								wins = true
							elif p_sum == best_sum_d and (p_cnt > best_pcnt or (p_cnt == best_pcnt and (best_pid == 0 or pid < best_pid))):
								wins = true
						if wins:
							best_pid = pid
							best_prio = prio
							best_sum_d = p_sum
							best_pcnt = p_cnt
							best_hint = int(entry[3])

				var didx := gy * dst_n + gx
				out.tiles[didx] = best_tid
				if best_pid > 0:
					out.protos[didx] = best_pid
					var avg_dens := clampi(roundi(float(sum_density) / sub_count), 1, 15)
					out.flags[didx] = (avg_dens & 0x0F) | ((max_glow & 0x03) << 4) | ((best_hint & 0x03) << 6)
		return out

	func encode_tile_rle() -> PackedInt32Array:
		var out := PackedInt32Array()
		if tiles.is_empty():
			return out
		var cur := tiles[0]
		var cnt := 1
		for i in range(1, tiles.size()):
			if tiles[i] == cur:
				cnt += 1
			else:
				out.append(cur)
				out.append(cnt)
				cur = tiles[i]
				cnt = 1
		out.append(cur)
		out.append(cnt)
		return out

	func encode_ent_rle() -> PackedInt32Array:
		var out := PackedInt32Array()
		if protos.is_empty():
			return out
		var n := protos.size()
		var cur_p := protos[0]
		var cur_f := flags[0] if flags.size() > 0 else 0
		var cnt := 1
		for i in range(1, n):
			var f := flags[i] if i < flags.size() else 0
			if protos[i] == cur_p and f == cur_f:
				cnt += 1
			else:
				out.append(cur_p)
				out.append(cur_f)
				out.append(cnt)
				cur_p = protos[i]
				cur_f = f
				cnt = 1
		out.append(cur_p)
		out.append(cur_f)
		out.append(cnt)
		return out


class LodPalette extends RefCounted:
	var proto_hash := 0
	var tile_colors := PackedColorArray()
	var tile_kind := PackedByteArray()
	var tile_rough := PackedFloat32Array()
	var ent_top_colors := PackedColorArray()
	var ent_side_colors := PackedColorArray()
	var ent_heights := PackedFloat32Array()
	var ent_metal := PackedFloat32Array()
	var ent_rough := PackedFloat32Array()
	var ent_cat := PackedByteArray()
	var ent_glow := PackedByteArray()
	var ent_prio := PackedByteArray()
	## 1 for Factorio's cliffs (type "cliff"), whose blocks are seated in their terrace (lod_mesher.gd KIND_CLIFF).
	var ent_seat := PackedByteArray()

	static func build(protos_db: Object, model_bakes := {}) -> LodPalette:
		return from_snapshot(snapshot(protos_db, model_bakes))

	## What build() reads from the main thread's shared state (the prototypes, the model bakes, the
	## model library's cache, the terrain textures' pictures, the packs), gathered on the main thread so
	## from_snapshot() can run on a worker (distant_horizon.gd's palette refresh). Cheap: lookups only;
	## the pictures' and meshes' sampling and the hash are left to from_snapshot().
	static func snapshot(protos_db: Object, model_bakes := {}, cached := false) -> Dictionary:
		if cached:
			return _snapshot_cached(protos_db, model_bakes)
		var tile_names: PackedStringArray = protos_db.tile_names if protos_db != null else PackedStringArray()
		var tile_is_water: PackedByteArray = protos_db.tile_is_water if protos_db != null else PackedByteArray()
		var tile_colors_src: PackedColorArray = protos_db.tile_colors if protos_db != null else PackedColorArray()
		var ent_dict: Dictionary = protos_db.entities if protos_db != null else {}
		var tile_count := maxi(1, maxi(tile_names.size(), tile_colors_src.size()))
		var tiles: Array = []  # per tile id from 1: [kind, roughness, the texture's picture or null, the fallback colour]
		tiles.resize(tile_count)
		var looks := _tile_looks(tile_names, tile_is_water, tile_count)
		for tid in range(1, tile_count):
			var tname := str(tile_names[tid]) if tid < tile_names.size() else ""
			var kind := int(looks[tid].x)
			var rough: float = looks[tid].y
			var img: Image = null
			var mc := Color.MAGENTA
			if kind != 3:
				img = _terrain_image(tname)
				if img == null:
					mc = protos_db.tile_color(tid) if protos_db != null else Color.MAGENTA
			tiles[tid] = [kind, rough, img, mc]
		var max_eid := 0
		var sorted_eids: Array[int] = []
		for key_v: Variant in ent_dict.keys():
			var eid := int(key_v)
			if eid > 0:
				sorted_eids.append(eid)
				if eid > max_eid:
					max_eid = eid
		sorted_eids.sort()
		var ents: Array = []  # [eid, proto or null, classify, bake, loaded mesh, tree look]
		for eid in sorted_eids:
			var p: ProtoDB.EntityProto = ent_dict[eid]
			if p == null:
				ents.append([eid, null, Vector3i.ZERO, null, null, {}])
				continue
			var cls := LodChunk._classify_entity(p.name, p.type)
			ents.append([eid, p, cls, _find_bake(p, model_bakes), _loaded_mesh_of(p),
				NatureLooks.tree(p.name) if cls.x == CAT_TREE else {}])
		return {"tile_names": tile_names, "tile_count": tile_count, "tile_colors_src_n": tile_colors_src.size(),
			"tiles": tiles, "max_eid": max_eid, "ents": ents, "hash_head": _hash_head()}

	## Which tile and entity ids look different in `b` than in `a`: [tile ids, entity ids, all], `all`
	## when the prototypes or their classes changed (every section is drawn again then).
	static func diff(a: LodPalette, b: LodPalette) -> Array:
		if a == null or b == null or a.proto_hash != b.proto_hash or a.tile_colors.size() != b.tile_colors.size() \
				or a.ent_cat != b.ent_cat or a.ent_prio != b.ent_prio or a.ent_top_colors.size() != b.ent_top_colors.size():
			return [PackedInt32Array(), PackedInt32Array(), true]
		var tiles := PackedInt32Array()
		for tid in a.tile_colors.size():
			if a.tile_colors[tid] != b.tile_colors[tid] or a.tile_kind[tid] != b.tile_kind[tid] or a.tile_rough[tid] != b.tile_rough[tid]:
				tiles.append(tid)
		var ents := PackedInt32Array()
		for eid in a.ent_top_colors.size():
			if a.ent_top_colors[eid] != b.ent_top_colors[eid] or a.ent_side_colors[eid] != b.ent_side_colors[eid] \
					or a.ent_heights[eid] != b.ent_heights[eid] or a.ent_metal[eid] != b.ent_metal[eid] \
					or a.ent_rough[eid] != b.ent_rough[eid] or a.ent_glow[eid] != b.ent_glow[eid] or a.ent_seat[eid] != b.ent_seat[eid]:
				ents.append(eid)
		return [tiles, ents, false]

	## Each tile's kind (0 ground, 1 water, 2 empty space, 3 lava) and roughness: Vector2(kind, roughness).
	static func _tile_looks(tile_names: PackedStringArray, tile_is_water: PackedByteArray, tile_count: int) -> Array:
		var out: Array = []
		out.resize(tile_count)
		for tid in range(1, tile_count):
			var tname := str(tile_names[tid]) if tid < tile_names.size() else ""
			var lower := tname.to_lower()
			var kind := 0
			if "lava" in lower:
				kind = 3
			elif "empty-space" in lower or (tid < tile_is_water.size() and tile_is_water[tid] == 2):
				kind = 2
			elif (tid < tile_is_water.size() and tile_is_water[tid] == 1) or TerrainTextures.is_water_tile(tname):
				kind = 1
			out[tid] = Vector2(kind, TerrainTextures.surface_of(tname).x if tname != "" else TerrainTextures.NATURAL_SURFACE.x)
		return out

	## snapshot()'s parts that stay the same between refreshes, kept (distant_horizon.gd's refresh):
	## each tile's kind and roughness (until the terrain textures' generation changes), each entity's
	## class, model name and tree look (until the prototypes, packs or look change). A refresh then
	## only looks up the bakes, loaded models and texture pictures: about 1 ms instead of 6-8.
	static var _snap_tiles_key := ""
	static var _snap_tiles: Array = []
	static var _snap_ents_key := ""
	static var _snap_ents: Array = []

	static func _snapshot_cached(protos_db: Object, model_bakes: Dictionary) -> Dictionary:
		var tile_names: PackedStringArray = protos_db.tile_names if protos_db != null else PackedStringArray()
		var tile_colors_src: PackedColorArray = protos_db.tile_colors if protos_db != null else PackedColorArray()
		var ent_dict: Dictionary = protos_db.entities if protos_db != null else {}
		var tile_count := maxi(1, maxi(tile_names.size(), tile_colors_src.size()))
		var head := _hash_head()
		var db_id := protos_db.get_instance_id() if protos_db != null else 0
		var tkey := "%d|%d|%d|%d" % [db_id, tile_count, tile_names.size(), TerrainTextures.generation]
		if tkey != _snap_tiles_key:
			_snap_tiles = _tile_looks(tile_names, protos_db.tile_is_water if protos_db != null else PackedByteArray(), tile_count)
			_snap_tiles_key = tkey
		var tiles: Array = []
		tiles.resize(tile_count)
		for tid in range(1, tile_count):
			var look: Vector2 = _snap_tiles[tid]
			var kind := int(look.x)
			var img: Image = null
			var mc := Color.MAGENTA
			if kind != 3:
				img = _terrain_image(str(tile_names[tid]) if tid < tile_names.size() else "")
				if img == null:
					mc = protos_db.tile_color(tid) if protos_db != null else Color.MAGENTA
			tiles[tid] = [kind, look.y, img, mc]
		var ekey := "%d|%d|%s" % [db_id, ent_dict.size(), head]
		if ekey != _snap_ents_key:
			var sorted_eids: Array[int] = []
			for key_v: Variant in ent_dict.keys():
				if int(key_v) > 0:
					sorted_eids.append(int(key_v))
			sorted_eids.sort()
			_snap_ents = []
			for eid in sorted_eids:
				var p: ProtoDB.EntityProto = ent_dict[eid]
				if p == null:
					_snap_ents.append([eid, null, Vector3i.ZERO, "", {}])
					continue
				var cls := LodChunk._classify_entity(p.name, p.type)
				_snap_ents.append([eid, p, cls, ModelLibrary.model_name(p.name, p.type, {}, 0),
					NatureLooks.tree(p.name) if cls.x == CAT_TREE else {}])
			_snap_ents_key = ekey
		var ents: Array = []
		var max_eid := 0
		for e: Array in _snap_ents:
			var eid := int(e[0])
			max_eid = maxi(max_eid, eid)
			var p: ProtoDB.EntityProto = e[1]
			if p == null:
				ents.append([eid, null, Vector3i.ZERO, null, null, {}])
				continue
			var mname: String = e[3]
			var mesh_v: Variant = ModelLibrary._cache.get(p.name)
			if mesh_v == null and mname != p.name:
				mesh_v = ModelLibrary._cache.get(mname)
			var bake: Variant = null
			if not model_bakes.is_empty():
				bake = model_bakes.get(p.name)
				if bake == null and mesh_v != null:
					bake = model_bakes.get(mesh_v)
			var loaded: Mesh = mesh_v if (mesh_v is Mesh and p.type != "tree" and p.type != "plant") else null
			ents.append([eid, p, e[2], bake, loaded, e[4]])
		return {"tile_names": tile_names, "tile_count": tile_count, "tile_colors_src_n": tile_colors_src.size(),
			"tiles": tiles, "max_eid": max_eid, "ents": ents, "hash_head": head}

	## build()'s work from snapshot(): touches nothing shared, so it may run on a worker thread.
	static func from_snapshot(snap: Dictionary) -> LodPalette:
		var pal := LodPalette.new()
		var tile_names: PackedStringArray = snap["tile_names"]
		var tile_count := int(snap["tile_count"])
		var tile_src_n := int(snap["tile_colors_src_n"])
		var tiles: Array = snap["tiles"]
		pal.tile_colors.resize(tile_count)
		pal.tile_kind.resize(tile_count)
		pal.tile_rough.resize(tile_count)
		pal.tile_colors[0] = Color(0.25, 0.25, 0.22, 1.0)
		pal.tile_kind[0] = 0
		pal.tile_rough[0] = TerrainTextures.NATURAL_SURFACE.x

		for tid in range(1, tile_count):
			var rec: Array = tiles[tid]
			var kind := int(rec[0])
			pal.tile_kind[tid] = kind
			pal.tile_rough[tid] = float(rec[1])

			if kind == 3:
				pal.tile_colors[tid] = Color(1.2, 0.30, 0.03, 1.0)
			else:
				var tex_col := _image_average_linear(rec[2])
				if tex_col.a >= 0.0:
					var gain := 0.95 if kind == 1 else 0.80
					pal.tile_colors[tid] = Color(tex_col.r * gain, tex_col.g * gain, tex_col.b * gain, 1.0)
				else:
					var mc: Color = rec[3]
					if mc == Color.MAGENTA and tid >= tile_src_n:
						pal.tile_colors[tid] = Color(0.25, 0.25, 0.22, 1.0)
					else:
						var lin := mc.srgb_to_linear()
						var scale := 0.78
						pal.tile_colors[tid] = Color(lin.r * scale, lin.g * scale, lin.b * scale, 1.0)

		var ent_count := int(snap["max_eid"]) + 1
		pal.ent_top_colors.resize(ent_count)
		pal.ent_side_colors.resize(ent_count)
		pal.ent_heights.resize(ent_count)
		pal.ent_metal.resize(ent_count)
		pal.ent_rough.resize(ent_count)
		pal.ent_cat.resize(ent_count)
		pal.ent_glow.resize(ent_count)
		pal.ent_prio.resize(ent_count)
		pal.ent_seat.resize(ent_count)
		pal.ent_top_colors[0] = Color.BLACK
		pal.ent_side_colors[0] = Color.BLACK
		pal.ent_heights[0] = 0.0
		pal.ent_metal[0] = 0.0
		pal.ent_rough[0] = 0.8
		pal.ent_cat[0] = CAT_NONE
		pal.ent_glow[0] = 0
		pal.ent_prio[0] = 0

		var ent_pairs := PackedStringArray()
		for e: Array in snap["ents"]:
			var eid := int(e[0])
			var p: ProtoDB.EntityProto = e[1]
			if p == null:
				continue
			ent_pairs.append("%d=%s:%s" % [eid, p.name, p.type])
			var cls: Vector3i = e[2]
			var cat := cls.x
			var prio := cls.y
			var glow := cls.z
			pal.ent_cat[eid] = cat
			pal.ent_prio[eid] = prio
			pal.ent_glow[eid] = glow
			pal.ent_seat[eid] = 1 if p.type == "cliff" else 0

			var base_h := Visuals.height_for(p)
			if cat == CAT_POLE:
				var pole_cur := _curated_entity_look(p, cat)
				if not pole_cur.is_empty():
					_apply_curated(pal, eid, cat, base_h, pole_cur)
					continue

			var baked := _sample_bake(e[3])
			if not baked.is_empty():
				pal.ent_top_colors[eid] = baked[0]
				pal.ent_side_colors[eid] = baked[1]
				pal.ent_heights[eid] = float(baked[2])
				pal.ent_metal[eid] = float(baked[3])
				pal.ent_rough[eid] = float(baked[4]) if cat != CAT_TREE else 0.95
				continue

			var curated := _curated_entity_look(p, cat)
			if not curated.is_empty():
				_apply_curated(pal, eid, cat, base_h, curated)
				continue

			var loaded := _sample_mesh(e[4])
			if not loaded.is_empty():
				pal.ent_top_colors[eid] = loaded[0]
				pal.ent_side_colors[eid] = loaded[1]
				pal.ent_heights[eid] = minf(base_h, float(loaded[2]))
				pal.ent_metal[eid] = float(loaded[3])
				pal.ent_rough[eid] = float(loaded[4]) if cat != CAT_TREE else 0.95
				continue

			pal.ent_heights[eid] = base_h
			var base := _sanitize_fallback_srgb(p.color).srgb_to_linear()
			if cat == CAT_TREE:
				var tcol := _tree_entry_linear_color(e[5], base)
				pal.ent_top_colors[eid] = tcol
				pal.ent_side_colors[eid] = Color(tcol.r * 0.65, tcol.g * 0.65, tcol.b * 0.65, 1.0)
				pal.ent_metal[eid] = 0.0
				pal.ent_rough[eid] = 0.95
			elif cat == CAT_CLIFF:
				var cliff_top := Color(base.r * 0.85, base.g * 0.85, base.b * 0.85, 1.0)
				pal.ent_top_colors[eid] = cliff_top
				pal.ent_side_colors[eid] = Color(cliff_top.r * 0.72, cliff_top.g * 0.72, cliff_top.b * 0.72, 1.0)
				pal.ent_metal[eid] = 0.0
				pal.ent_rough[eid] = 0.92
			elif cat == CAT_ORE:
				pal.ent_top_colors[eid] = base
				pal.ent_side_colors[eid] = Color(base.r * 0.82, base.g * 0.82, base.b * 0.82, 1.0)
				pal.ent_metal[eid] = 0.25 if ("iron" in p.name or "copper" in p.name or "uranium" in p.name) else 0.05
				pal.ent_rough[eid] = 0.8
			elif cat == CAT_LOW:
				pal.ent_top_colors[eid] = base
				pal.ent_side_colors[eid] = Color(base.r * 0.8, base.g * 0.8, base.b * 0.8, 1.0)
				pal.ent_metal[eid] = 0.45
				pal.ent_rough[eid] = 0.55
			else:
				pal.ent_top_colors[eid] = base
				pal.ent_side_colors[eid] = Color(base.r * 0.78, base.g * 0.78, base.b * 0.78, 1.0)
				pal.ent_metal[eid] = 0.35
				pal.ent_rough[eid] = 0.65

		pal.proto_hash = _hash_finish(str(snap["hash_head"]), tile_names, ent_pairs, (snap["ents"] as Array).size())
		return pal

	static func _compute_proto_hash(tile_names: PackedStringArray, ent_dict: Dictionary, sorted_eids: Array[int]) -> int:
		var ent_pairs := PackedStringArray()
		for eid in sorted_eids:
			var p: ProtoDB.EntityProto = ent_dict[eid]
			if p != null:
				ent_pairs.append("%d=%s:%s" % [eid, p.name, p.type])
		return _hash_finish(_hash_head(), tile_names, ent_pairs, sorted_eids.size())

	## The hash's part from shared state (packs, choices, the look), read on the main thread.
	static func _hash_head() -> String:
		var parts := PackedStringArray()
		parts.append("zlod-pal-v2")
		parts.append("shade=%d" % (1 if Looks.packs_shade else 0))
		parts.append("gfx=%s" % ModGraphics.fingerprint)
		var packs := PackedStringArray()
		for pk: Dictionary in ModelPacks.active():
			packs.append("%s:%s" % [str(pk.get("id", "")), ModelPacks.shading(pk)])
		parts.append("packs=%s" % ",".join(packs))
		if not ModelPacks.choices.is_empty():
			var ckeys := PackedStringArray()
			for k_v: Variant in ModelPacks.choices.keys():
				ckeys.append(str(k_v))
			ckeys.sort()
			var cpairs := PackedStringArray()
			for ck: String in ckeys:
				cpairs.append("%s=%s" % [ck, str(ModelPacks.choices[ck])])
			parts.append("choices=%s" % ",".join(cpairs))
		for label_map: Array in [["pbr_packs", ModelPacks.pbr_packs], ["pbr_models", ModelPacks.pbr_models]]:
			var pmap: Dictionary = label_map[1]
			if not pmap.is_empty():
				var pkeys := PackedStringArray()
				for k_v: Variant in pmap.keys():
					pkeys.append(str(k_v))
				pkeys.sort()
				var ppairs := PackedStringArray()
				for pk_name: String in pkeys:
					ppairs.append("%s=%d" % [pk_name, 1 if bool(pmap[pk_name]) else 0])
				parts.append("%s=%s" % [str(label_map[0]), ",".join(ppairs)])
		return "\n".join(parts)

	static func _hash_finish(head: String, tile_names: PackedStringArray, ent_pairs: PackedStringArray, ents_n: int) -> int:
		var parts := PackedStringArray([head])
		parts.append("tiles=%d" % tile_names.size())
		for tid in tile_names.size():
			if tile_names[tid] != "":
				parts.append("%d=%s" % [tid, tile_names[tid]])
		parts.append("ents=%d" % ents_n)
		parts.append_array(ent_pairs)
		var digest := "\n".join(parts).sha256_buffer()
		var lo := digest.decode_u32(0)
		var hi := digest.decode_u32(4) & 0x7FFFFFFF
		var h := lo | (hi << 32)
		return h if h != 0 else 1

	static func _terrain_average_linear(tile_name: String) -> Color:
		return _image_average_linear(_terrain_image(tile_name))

	## The tile's texture picture (main thread: the terrain textures' tables), null when none.
	static func _terrain_image(tile_name: String) -> Image:
		if tile_name == "":
			return null
		var gfx := TerrainTextures.peek(tile_name)
		if gfx == null or gfx.layer < 0 or gfx.layer >= TerrainTextures._images.size():
			return null
		return TerrainTextures._images[gfx.layer]

	## The picture's average colour, linear (alpha -1: none); reads only the picture (worker-safe).
	static func _image_average_linear(img: Image) -> Color:
		if img == null or img.is_empty():
			return Color(0, 0, 0, -1.0)
		var sample := img
		if img.is_compressed():
			var mips := img.get_mipmap_count()
			if mips > 0:
				var target_mip := mips
				var mw := maxi(1, img.get_width() >> mips)
				var mh := maxi(1, img.get_height() >> mips)
				for m in range(mips, -1, -1):
					var cw := maxi(1, img.get_width() >> m)
					var ch := maxi(1, img.get_height() >> m)
					if cw >= 4 and ch >= 4:
						target_mip = m
						mw = cw
						mh = ch
						break
				var off := img.get_mipmap_offset(target_mip)
				var raw := img.get_data()
				if off >= 0 and off < raw.size():
					var end := img.get_mipmap_offset(target_mip + 1) if target_mip < mips else raw.size()
					var sub := Image.create_from_data(mw, mh, false, img.get_format(), raw.slice(off, end))
					if sub != null and not sub.is_empty() and sub.decompress() == OK:
						sample = sub
			if sample.is_compressed():
				var dup := img.duplicate() as Image
				if dup == null or dup.decompress() != OK:
					return Color(0, 0, 0, -1.0)
				sample = dup
		var w := sample.get_width()
		var h := sample.get_height()
		var gx := mini(w, 8)
		var gy := mini(h, 4)
		var acc := Vector3.ZERO
		var cnt := 0
		for j in gy:
			var py := (j * h) / gy + h / (gy * 2)
			for i in gx:
				var px := (i * w) / gx + w / (gx * 2)
				var c := sample.get_pixel(clampi(px, 0, w - 1), clampi(py, 0, h - 1)).srgb_to_linear()
				acc += Vector3(c.r, c.g, c.b)
				cnt += 1
		if cnt == 0:
			return Color(0, 0, 0, -1.0)
		acc /= float(cnt)
		return Color(acc.x, acc.y, acc.z, 1.0)

	static func _tree_linear_color(proto_name: String, fallback: Color) -> Color:
		return _tree_entry_linear_color(NatureLooks.tree(proto_name), fallback)

	static func _tree_entry_linear_color(entry: Dictionary, fallback: Color) -> Color:
		if entry.is_empty():
			return fallback
		var col := fallback
		var leaves_v: Variant = entry.get("leaves")
		if leaves_v is Dictionary:
			var mean_v: Variant = (leaves_v as Dictionary).get("mean")
			if mean_v is Array and (mean_v as Array).size() >= 3:
				var mean_arr := mean_v as Array
				col = Color(float(mean_arr[0]), float(mean_arr[1]), float(mean_arr[2]), 1.0)
		var tints_v: Variant = entry.get("tints")
		if tints_v is Array and not (tints_v as Array).is_empty():
			var tsum := Vector3.ZERO
			var tcnt := 0
			for item in tints_v as Array:
				if item is Array and (item as Array).size() >= 3:
					var ta := item as Array
					tsum += Vector3(float(ta[0]), float(ta[1]), float(ta[2]))
					tcnt += 1
			if tcnt > 0:
				tsum /= float(tcnt)
				col = Color(clampf(col.r * tsum.x, 0.0, 1.0), clampf(col.g * tsum.y, 0.0, 1.0),
					clampf(col.b * tsum.z, 0.0, 1.0), 1.0)
		return col

	static func _find_bake(p: ProtoDB.EntityProto, model_bakes: Dictionary) -> Variant:
		if model_bakes.is_empty():
			return null
		if model_bakes.has(p.name):
			return model_bakes[p.name]
		var mesh: Variant = ModelLibrary._cache.get(p.name)
		if mesh == null:
			var mname := ModelLibrary.model_name(p.name, p.type, {}, 0)
			if mname != p.name:
				mesh = ModelLibrary._cache.get(mname)
		if mesh != null and model_bakes.has(mesh):
			return model_bakes[mesh]
		return null

	static func _sample_bake(bake: Variant) -> Array:
		if bake == null or not (bake is Object):
			return []
		var b: Object = bake
		var v_solid: PackedVector3Array = b.get("verts") if b.get("verts") is PackedVector3Array else PackedVector3Array()
		var c_solid: PackedColorArray = b.get("colors") if b.get("colors") is PackedColorArray else PackedColorArray()
		var v_crown: PackedVector3Array = b.get("crown_verts") if b.get("crown_verts") is PackedVector3Array else PackedVector3Array()
		var c_crown: PackedColorArray = b.get("crown_colors") if b.get("crown_colors") is PackedColorArray else PackedColorArray()
		var has_solid := not v_solid.is_empty() and c_solid.size() == v_solid.size()
		var has_crown := not v_crown.is_empty() and c_crown.size() == v_crown.size()
		if not has_solid and not has_crown:
			return []

		var min_y := INF
		var max_y := -INF
		if has_solid:
			for v in v_solid:
				min_y = minf(min_y, v.y)
				max_y = maxf(max_y, v.y)
		if has_crown:
			for v in v_crown:
				min_y = minf(min_y, v.y)
				max_y = maxf(max_y, v.y)
		var mid_y := (min_y + max_y) * 0.5
		var height := maxf(max_y - min_y, 0.05)

		var top_sum := Vector3.ZERO
		var top_n := 0
		var side_sum := Vector3.ZERO
		var side_n := 0
		var metal_sum := 0.0
		var pc_sum := 0.0
		var solid_n := 0

		if has_solid:
			for i in v_solid.size():
				var c := c_solid[i]
				var lin := Vector3(c.r * c.r, c.g * c.g, c.b * c.b)
				if v_solid[i].y >= mid_y:
					top_sum += lin
					top_n += 1
				else:
					side_sum += lin
					side_n += 1
				var packed := roundi(clampf(c.a, 0.0, 1.0) * 255.0)
				pc_sum += float(packed & 15) / 15.0
				metal_sum += float(packed >> 4) / 15.0
				solid_n += 1

		if has_crown:
			var leaf_tint := Vector3.ONE
			var lt_v: Variant = b.get("leaf_tints")
			if lt_v is PackedVector3Array and not (lt_v as PackedVector3Array).is_empty():
				var lts := lt_v as PackedVector3Array
				var tsum := Vector3.ZERO
				for t in lts:
					tsum += t
				leaf_tint = tsum / float(lts.size())
			for i in v_crown.size():
				var c := c_crown[i]
				var lin := Vector3(c.r * c.r * leaf_tint.x, c.g * c.g * leaf_tint.y, c.b * c.b * leaf_tint.z)
				if v_crown[i].y >= mid_y:
					top_sum += lin
					top_n += 1
				else:
					side_sum += lin
					side_n += 1

		var top_vec := top_sum / float(top_n) if top_n > 0 else (side_sum / float(maxi(side_n, 1)))
		var side_vec := side_sum / float(side_n) if side_n > 0 else top_vec * 0.85
		var mean_metal := metal_sum / float(solid_n) if solid_n > 0 else 0.0
		var mean_pc := pc_sum / float(solid_n) if solid_n > 0 else 0.5
		var rough := lerpf(0.65, 0.85, mean_pc)
		return [
			Color(top_vec.x, top_vec.y, top_vec.z, 1.0),
			Color(side_vec.x, side_vec.y, side_vec.z, 1.0),
			height,
			clampf(mean_metal, 0.0, 1.0),
			rough,
		]

	static func _sample_loaded_mesh(p: ProtoDB.EntityProto) -> Array:
		return _sample_mesh(_loaded_mesh_of(p))

	## The prototype's model as the model library has it loaded (main thread), null when none.
	static func _loaded_mesh_of(p: ProtoDB.EntityProto) -> Mesh:
		if p == null or p.type == "tree" or p.type == "plant":
			return null
		var mesh_v: Variant = ModelLibrary._cache.get(p.name)
		if mesh_v == null:
			var mname := ModelLibrary.model_name(p.name, p.type, {}, 0)
			if mname != p.name:
				mesh_v = ModelLibrary._cache.get(mname)
		return mesh_v if mesh_v is Mesh else null

	## A loaded model's colours (reads only the mesh and its materials).
	static func _sample_mesh(mesh: Mesh) -> Array:
		if mesh == null:
			return []
		var scount := mesh.get_surface_count()
		if scount <= 0:
			return []
		var col_sum := Vector3.ZERO
		var metal_sum := 0.0
		var rough_sum := 0.0
		var sampled := 0
		for si in scount:
			var mat := mesh.surface_get_material(si)
			if mat is BaseMaterial3D:
				var bm: BaseMaterial3D = mat
				if bm.albedo_texture != null:
					continue
				if bm.albedo_color.r > 0.92 and bm.albedo_color.g > 0.92 and bm.albedo_color.b > 0.92:
					continue
				var lin := _sanitize_fallback_srgb(bm.albedo_color).srgb_to_linear()
				col_sum += Vector3(lin.r, lin.g, lin.b)
				metal_sum += bm.metallic
				rough_sum += bm.roughness
				sampled += 1
			elif mat is ShaderMaterial:
				var sm: ShaderMaterial = mat
				var uat_v: Variant = sm.get_shader_parameter("use_albedo_tex")
				if uat_v is bool and bool(uat_v):
					continue
				var part_data_v: Variant = sm.get_shader_parameter("part_data")
				if (part_data_v is float or part_data_v is int) and float(part_data_v) > 0.5:
					continue
				if sm.get_shader_parameter("row_table") != null:
					continue
				var albedo_v: Variant = sm.get_shader_parameter("albedo")
				if not (albedo_v is Color):
					continue
				var acol: Color = albedo_v
				if acol.r > 0.92 and acol.g > 0.92 and acol.b > 0.92:
					continue
				var lin := _sanitize_fallback_srgb(acol).srgb_to_linear()
				col_sum += Vector3(lin.r, lin.g, lin.b)
				var metal_v: Variant = sm.get_shader_parameter("metallic")
				var rough_v: Variant = sm.get_shader_parameter("roughness")
				metal_sum += float(metal_v) if (metal_v is float or metal_v is int) else 0.35
				rough_sum += float(rough_v) if (rough_v is float or rough_v is int) else 0.65
				sampled += 1
		if sampled == 0:
			return []
		var top_vec := col_sum / float(sampled)
		var height := maxf(mesh.get_aabb().size.y, 0.05)
		return [
			Color(top_vec.x, top_vec.y, top_vec.z, 1.0),
			Color(top_vec.x * 0.78, top_vec.y * 0.78, top_vec.z * 0.78, 1.0),
			height,
			clampf(metal_sum / float(sampled), 0.0, 1.0),
			clampf(rough_sum / float(sampled), 0.05, 1.0),
		]

	static func _apply_curated(pal: LodPalette, eid: int, cat: int, base_h: float, curated: Array) -> void:
		var c_srgb: Color = curated[0]
		var top_lin := c_srgb.srgb_to_linear()
		var side_scale := 0.82 if cat == CAT_ORE else (0.72 if cat == CAT_POLE else 0.78)
		pal.ent_top_colors[eid] = top_lin
		pal.ent_side_colors[eid] = Color(top_lin.r * side_scale, top_lin.g * side_scale, top_lin.b * side_scale, 1.0)
		var max_h := float(curated[3])
		pal.ent_heights[eid] = minf(base_h, max_h) if max_h > 0.0 else base_h
		pal.ent_metal[eid] = float(curated[1])
		pal.ent_rough[eid] = float(curated[2])


	static func _curated_entity_look(p: ProtoDB.EntityProto, _cat: int) -> Array:
		if p == null:
			return []
		var pt := p.type
		var lname := p.name.to_lower()
		if pt == "unit-spawner":
			return [Color(0.34, 0.21, 0.18), 0.0, 0.92, 1.8]
		if pt == "turret":
			return [Color(0.38, 0.30, 0.23), 0.0, 0.88, 1.4]
		if pt == "resource":
			if "oil" in lname:
				return [Color(0.14, 0.13, 0.15), 0.10, 0.38, 0.15]
			if "uranium" in lname:
				return [Color(0.24, 0.35, 0.19), 0.15, 0.80, 0.20]
			if "copper" in lname:
				return [Color(0.46, 0.27, 0.18), 0.25, 0.78, 0.20]
			if "iron" in lname:
				return [Color(0.35, 0.41, 0.45), 0.25, 0.78, 0.20]
			if "coal" in lname:
				return [Color(0.17, 0.17, 0.18), 0.05, 0.88, 0.20]
			if "stone" in lname:
				return [Color(0.48, 0.43, 0.34), 0.05, 0.88, 0.20]
			if "sulfuric" in lname:
				return [Color(0.48, 0.45, 0.20), 0.05, 0.75, 0.25]
			if "fluorine" in lname or "lithium" in lname:
				return [Color(0.32, 0.42, 0.42), 0.05, 0.70, 0.20]
			return []
		if pt == "wall" or pt == "gate":
			return [Color(0.45, 0.44, 0.42), 0.05, 0.86, 1.4]
		if pt == "transport-belt" or pt == "underground-belt" or pt == "splitter" or pt == "lane-splitter" \
				or pt == "loader" or pt == "loader-1x1" or pt == "linked-belt":
			if "turbo" in lname:
				return [Color(0.31, 0.39, 0.27), 0.45, 0.58, 0.35]
			if "express" in lname:
				return [Color(0.27, 0.35, 0.43), 0.45, 0.58, 0.35]
			if "fast" in lname:
				return [Color(0.43, 0.26, 0.24), 0.45, 0.58, 0.35]
			return [Color(0.41, 0.36, 0.25), 0.45, 0.60, 0.35]
		if _RAIL_PIPE_TYPES.has(pt) and "rail" in pt:
			if "elevated" in pt or "ramp" in pt or "support" in pt:
				return [Color(0.44, 0.44, 0.46), 0.40, 0.65, 2.2]
			return [Color(0.35, 0.34, 0.32), 0.35, 0.72, 0.22]
		if pt == "rail-signal" or pt == "rail-chain-signal":
			return [Color(0.30, 0.31, 0.33), 0.40, 0.60, 0.45]
		if pt == "pipe" or pt == "pipe-to-ground" or pt == "infinity-pipe" or pt == "heat-pipe" \
				or pt == "valve" or pt == "pump" or pt == "offshore-pump" or pt == "storage-tank":
			return [Color(0.41, 0.42, 0.44), 0.50, 0.52, 2.2 if pt == "storage-tank" else 0.85]
		if pt == "ammo-turret" or pt == "electric-turret" or pt == "fluid-turret" or pt == "artillery-turret":
			return [Color(0.36, 0.36, 0.35), 0.45, 0.58, 1.8]
		if pt == "solar-panel":
			return [Color(0.16, 0.20, 0.25), 0.30, 0.42, 0.55]
		if pt == "accumulator":
			return [Color(0.32, 0.34, 0.36), 0.35, 0.55, 1.4]
		if pt == "roboport":
			return [Color(0.46, 0.45, 0.41), 0.30, 0.62, 2.6]
		if pt == "beacon":
			return [Color(0.28, 0.34, 0.38), 0.40, 0.55, 1.9]
		if pt == "radar":
			return [Color(0.40, 0.41, 0.40), 0.35, 0.60, 2.4]
		if pt == "assembling-machine":
			if "3" in lname:
				return [Color(0.38, 0.41, 0.34), 0.40, 0.58, 2.0]
			if "2" in lname:
				return [Color(0.33, 0.38, 0.42), 0.40, 0.58, 2.0]
			if "chemical" in lname:
				return [Color(0.42, 0.40, 0.35), 0.35, 0.60, 2.2]
			if "refinery" in lname:
				return [Color(0.40, 0.39, 0.37), 0.45, 0.55, 3.0]
			if "centrifuge" in lname:
				return [Color(0.35, 0.40, 0.34), 0.40, 0.58, 2.4]
			return [Color(0.40, 0.38, 0.35), 0.40, 0.60, 2.0]
		if pt == "furnace":
			return [Color(0.34, 0.34, 0.35), 0.40, 0.62, 2.0]
		if pt == "mining-drill":
			return [Color(0.42, 0.39, 0.34), 0.40, 0.60, 2.2]
		if pt == "boiler" or pt == "generator" or pt == "heat-exchanger" or pt == "fusion-generator":
			return [Color(0.38, 0.40, 0.41), 0.45, 0.55, 2.2]
		if pt == "reactor" or pt == "fusion-reactor" or pt == "rocket-silo":
			return [Color(0.38, 0.39, 0.40), 0.40, 0.55, 3.4]
		if pt == "lab":
			return [Color(0.38, 0.41, 0.43), 0.30, 0.55, 2.0]
		if pt == "electric-pole":
			if "small" in lname or "wood" in lname:
				return [Color(0.20, 0.15, 0.11), 0.05, 0.88, 1.5]
			if "substation" in lname:
				return [Color(0.22, 0.23, 0.25), 0.35, 0.72, 1.7]
			if "big" in lname:
				return [Color(0.18, 0.19, 0.21), 0.35, 0.75, 2.1]
			return [Color(0.19, 0.20, 0.22), 0.35, 0.75, 1.7]
		if pt == "inserter" or pt == "arithmetic-combinator" or pt == "decider-combinator" \
				or pt == "selector-combinator" or pt == "constant-combinator" or pt == "power-switch" \
				or pt == "programmable-speaker" or pt == "display-panel":
			return [Color(0.36, 0.36, 0.37), 0.35, 0.62, 0.55]
		if pt == "container" or pt == "logistic-container":
			return [Color(0.39, 0.38, 0.35), 0.35, 0.65, 0.9]
		if pt == "train-stop":
			return [Color(0.42, 0.34, 0.30), 0.35, 0.62, 1.8]
		if pt == "lamp":
			return [Color(0.46, 0.46, 0.44), 0.30, 0.55, 0.8]
		return []

	static func _sanitize_fallback_srgb(c: Color) -> Color:
		if c.r < 0.06 and c.g >= 0.28 and c.g <= 0.48 and c.b >= 0.46 and c.b <= 0.68:
			return Color(0.38, 0.40, 0.42, 1.0)
		if c.r >= 0.85 and c.g <= 0.22 and c.b <= 0.22:
			return Color(0.35, 0.22, 0.19, 1.0)
		var lum := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
		var d := Color(lerpf(lum, c.r, 0.50), lerpf(lum, c.g, 0.50), lerpf(lum, c.b, 0.50), 1.0)
		var dlum := 0.299 * d.r + 0.587 * d.g + 0.114 * d.b
		if dlum < 0.001:
			return Color(0.16, 0.16, 0.16, 1.0)
		var target := clampf(dlum, 0.14, 0.46)
		var f := target / dlum
		var out := Color(clampf(d.r * f, 0.0, 1.0), clampf(d.g * f, 0.0, 1.0), clampf(d.b * f, 0.0, 1.0), 1.0)
		var peak := maxf(out.r, maxf(out.g, out.b))
		if peak > 0.58:
			var ps := 0.58 / peak
			out = Color(out.r * ps, out.g * ps, out.b * ps, 1.0)
		return out
