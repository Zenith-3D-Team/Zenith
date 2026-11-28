extends RefCounted
## Rail signal & train stop attachment snapping, tile outlines, and hybrid signal block overlays
## (C1): straight/simple rail runs compute blocks client-side with zero bridge traffic; junctions
## and crossings query the bridge (`rblk`) and cache results per rail chunk revision.

const RailPlanner := preload("res://scripts/player/rail_planner.gd")
const CursorOverlay := preload("res://scripts/player/cursor_overlay.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const WorldMirror := preload("res://scripts/world/world.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const Switches := preload("res://scripts/switches.gd")

## --rail-signal-blocks=off: disable signal-block segment overlays and bridge `rblk` queries.
static var enabled := not (Switches.has("--rail-signal-blocks=off"))
## (rel-031-fix3) Each query starts with one already-answered rail of every cached block id in view
## (an anchor); a reply giving an anchor another id renames every cached rail of the old id, so one
## block asked about in two queries stays one id. --rblk-anchors=off: no anchors, ids as replied.
static var anchors_on := not (Switches.has("--rblk-anchors=off"))
## At most this many anchors a batch (the rest is the rails still to ask).
const MAX_ANCHORS := 32

const SIGNAL_TYPES := ["rail-signal", "rail-chain-signal"]
const ATTACHMENT_TYPES := ["rail-signal", "rail-chain-signal", "train-stop"]
const ALL_RAILS := [
	"straight-rail", "half-diagonal-rail", "curved-rail-a", "curved-rail-b",
	"legacy-straight-rail", "legacy-curved-rail",
	"elevated-straight-rail", "elevated-half-diagonal-rail", "elevated-curved-rail-a", "elevated-curved-rail-b",
	"rail-ramp",
]
const STRAIGHT_RAILS := {
	"straight-rail": true,
	"elevated-straight-rail": true,
	"legacy-straight-rail": true,
}
const NON_BLOCKING_TYPES := {
	"resource": true,
	"tile-ghost": true,
	"corpse": true,
	"rail-remnants": true,
	"item-entity": true,
}

const SNAP_RADIUS_SIGNAL := 3.5
const SNAP_RADIUS_STOP := 4.0
const OUTLINE_RADIUS := 16.0
const MAX_OUTLINES := 64
const BLOCK_RADIUS := 24.0
const MAX_QUERY_UNITS := 128
const QUERY_COOLDOWN_MSEC := 300

const SPOT_FILL := Color(0.25, 0.9, 0.35, 0.18)
const SPOT_EDGE := Color(0.25, 0.9, 0.35, 0.85)
const SPOT_ACTIVE_EDGE := Color(0.45, 1.0, 0.55, 0.98)

const BLOCK_COLORS := [
	Color(0.15, 0.92, 0.95, 0.85),
	Color(0.95, 0.88, 0.15, 0.85),
	Color(0.95, 0.25, 0.85, 0.85),
	Color(0.25, 0.55, 1.0, 0.85),
	Color(1.0, 0.55, 0.12, 0.85),
	Color(0.65, 0.35, 1.0, 0.85),
	Color(0.30, 0.95, 0.45, 0.85),
	Color(1.0, 0.45, 0.65, 0.85),
]

## Incremented whenever a bridge `rblk` reply arrives, invalidating highlight cache.
var version := 0
var _bridge_cache := {}  # unit -> [block_id, rev_sig]
var _pending_rev := {}  # unit -> rev_sig sent with the query
var _last_query_units: Array = []
var _last_query_rev: Array = []
var _last_query_msec := 0


func _init() -> void:
	Bridge.message_received.connect(_on_message)


static func is_rail_attachment(proto_type: String) -> bool:
	return ATTACHMENT_TYPES.has(proto_type)


func clear() -> void:
	_bridge_cache.clear()
	_pending_rev.clear()
	_last_query_units = []
	_last_query_rev = []
	_last_query_msec = 0
	version += 1


func _on_message(msg: Dictionary) -> void:
	var t := str(msg.get("t", ""))
	if t == "welcome" or t == "surface":
		clear()
		return
	if t != "rblk":
		return
	var rows: Variant = msg.get("b")
	if not (rows is Array):
		return
	var changed := false
	# (anchors_on) old id -> new id, from rails already answered at this same chunk revision whose
	# reply gives them another id: the same block both times (the bridge's reply is consistent), so
	# every cached rail of the old id takes the new one.
	var rename := {}
	for row in (rows as Array):
		if row is Array and (row as Array).size() >= 2:
			var r_arr: Array = row
			var u := int(r_arr[0])
			var bid := int(r_arr[1])
			var sig: Variant = _pending_rev.get(u, _last_query_rev)
			if anchors_on:
				var had: Variant = _bridge_cache.get(u)
				if had != null and (had as Array)[1] == sig and int((had as Array)[0]) != bid:
					rename[int((had as Array)[0])] = bid
			_bridge_cache[u] = [bid, sig]
			changed = true
	if not rename.is_empty():
		for cu in _bridge_cache:
			var entry: Array = _bridge_cache[cu]
			var old_id := int(entry[0])
			if rename.has(old_id):
				entry[0] = int(rename[old_id])
	if changed:
		version += 1


static func _elevated_y() -> float:
	return 3.0 if ModelLibrary.elevated_old else ModelLibrary.ELEVATED_TRACK


## Lightweight attachment snap without block overlay computation (for drag_build).
func snap_spot(world: WorldMirror, placed: ProtoDB.EntityProto, at: Vector2, build_dir: int, ghost_mode: bool, eprops: Dictionary = {}) -> Dictionary:
	return _compute(world, placed, at, build_dir, ghost_mode, false, eprops)


## Full snap + attachment tile outlines + hybrid signal block overlays (for player_input highlights).
func snap_and_marks(world: WorldMirror, placed: ProtoDB.EntityProto, at: Vector2, build_dir: int, ghost_mode: bool, eprops: Dictionary = {}) -> Dictionary:
	return _compute(world, placed, at, build_dir, ghost_mode, true, eprops)


func _compute(world: WorldMirror, placed: ProtoDB.EntityProto, at: Vector2, build_dir: int, ghost_mode: bool, with_marks: bool, eprops: Dictionary = {}) -> Dictionary:
	if world == null or placed == null or not is_rail_attachment(placed.type):
		return {"snapped": false, "pos": at, "dir": build_dir, "el": 0, "valid": false, "refusal": "", "marks": []}
	var is_stop := placed.type == "train-stop"
	var scan_radius := maxf(OUTLINE_RADIUS, BLOCK_RADIUS if with_marks and enabled else OUTLINE_RADIUS) + 8.0
	var gathered := _gather_rails_and_signals(world, at, scan_radius, ghost_mode)
	var all_rails: Array = gathered[0]
	var real_rails: Array = gathered[1]
	var real_signals: Array = gathered[2]

	var spots := _collect_spots(world, all_rails, is_stop, ghost_mode, eprops)
	var snap_r := SNAP_RADIUS_STOP if is_stop else SNAP_RADIUS_SIGNAL
	var snap_r_sq := snap_r * snap_r

	var best_free: Dictionary = {}
	var best_free_d := snap_r_sq
	var best_occ: Dictionary = {}
	var best_occ_d := snap_r_sq

	for sp: Dictionary in spots:
		var spos: Vector2 = sp["pos"]
		var d2 := spos.distance_squared_to(at)
		if d2 > snap_r_sq:
			continue
		var status := int(sp["status"])
		if status == 0:
			if best_free.is_empty() or d2 < best_free_d - 0.0001 or (absf(d2 - best_free_d) <= 0.0001 and int(sp["dir"]) == build_dir):
				best_free = sp
				best_free_d = d2
		elif status == 1:
			if best_occ.is_empty() or d2 < best_occ_d:
				best_occ = sp
				best_occ_d = d2

	var snapped := false
	var out_pos := at
	var out_dir := build_dir
	var out_el := 0
	var valid := false
	var refusal := ""
	if not best_occ.is_empty() and (best_free.is_empty() or best_occ_d < best_free_d - 0.0001):
		snapped = true
		out_pos = best_occ["pos"]
		out_dir = int(best_occ["dir"])
		out_el = int(best_occ["el"])
		valid = false
		refusal = "Spot is occupied"
	elif not best_free.is_empty():
		snapped = true
		out_pos = best_free["pos"]
		out_dir = int(best_free["dir"])
		out_el = int(best_free["el"])
		valid = true
	else:
		refusal = "Must be placed next to a rail"

	var marks: Array = []
	if with_marks:
		if enabled:
			marks.append_array(_block_marks(world, real_rails, real_signals, at))
		marks.append_array(_outline_marks(spots, at, is_stop, snapped and valid, out_pos, out_el))

	return {
		"snapped": snapped,
		"pos": out_pos,
		"dir": out_dir,
		"el": out_el,
		"valid": valid,
		"refusal": refusal,
		"marks": marks,
	}


func _gather_rails_and_signals(world: WorldMirror, at: Vector2, radius: float, include_ghosts: bool) -> Array:
	var all_rails: Array = []
	var real_rails: Array = []
	var real_signals: Array = []
	var c_min := WorldMirror.chunk_of(at - Vector2(radius, radius))
	var c_max := WorldMirror.chunk_of(at + Vector2(radius, radius))
	var r_sq := radius * radius
	for cy in range(c_min.y, c_max.y + 1):
		for cx in range(c_min.x, c_max.x + 1):
			var cv = world.chunks.get(Vector2i(cx, cy))
			if cv == null:
				continue
			for r in cv.entities.values():
				var rec: WorldMirror.Rec = r
				if rec.pos.distance_squared_to(at) > r_sq:
					continue
				var proto: ProtoDB.EntityProto = world.protos.entity(rec.proto_id)
				if proto == null:
					continue
				var is_ghost := proto.type == "entity-ghost"
				var eff_proto: ProtoDB.EntityProto = proto
				if is_ghost:
					if not rec.extra.has("gh"):
						continue
					eff_proto = world.protos.entity(int(rec.extra["gh"]))
					if eff_proto == null:
						continue
				if ALL_RAILS.has(eff_proto.type):
					if not is_ghost:
						real_rails.append([rec, eff_proto])
						all_rails.append([rec, eff_proto])
					elif include_ghosts:
						all_rails.append([rec, eff_proto])
				elif not is_ghost and SIGNAL_TYPES.has(eff_proto.type):
					real_signals.append(rec)
	return [all_rails, real_rails, real_signals]


func _collect_spots(world: WorldMirror, rails: Array, is_stop: bool, ghost_mode: bool, eprops: Dictionary = {}) -> Array:
	var data: Dictionary = RailPlanner.data()
	var signals_table: Dictionary = data.get("signals", {})
	var seen := {}
	var out: Array = []
	for pair in rails:
		var rec: WorldMirror.Rec = pair[0]
		var proto: ProtoDB.EntityProto = pair[1]
		if is_stop:
			if proto.type != "straight-rail" and proto.type != "legacy-straight-rail":
				continue
			var candidates: Array = []
			if posmod(rec.dir, 8) == 0:
				candidates = [[rec.pos + Vector2(2.0, 0.0), 0], [rec.pos + Vector2(-2.0, 0.0), 8]]
			elif posmod(rec.dir, 8) == 4:
				candidates = [[rec.pos + Vector2(0.0, 2.0), 4], [rec.pos + Vector2(0.0, -2.0), 12]]
			for cand in candidates:
				var spos: Vector2 = cand[0]
				var sdir := int(cand[1])
				var key := "%d,%d,%d,0" % [roundi(spos.x * 2.0), roundi(spos.y * 2.0), sdir]
				if seen.has(key):
					continue
				seen[key] = true
				var st := _spot_status(world, spos, true, 0, ghost_mode, eprops)
				out.append({"pos": spos, "dir": sdir, "el": 0, "status": st})
		else:
			for end_info in _ends_for(proto.type, rec.dir, rec.pos):
				var end_pos: Vector2 = end_info[0]
				var edir := int(end_info[1])
				var el := int(end_info[2])
				var sig_list: Variant = signals_table.get(str(edir), [])
				if not (sig_list is Array):
					continue
				for s in (sig_list as Array):
					if not (s is Array) or (s as Array).size() < 3:
						continue
					var sa: Array = s
					var spos := end_pos + Vector2(float(sa[0]), float(sa[1]))
					var sdir := int(sa[2])
					var key := "%d,%d,%d,%d" % [roundi(spos.x * 2.0), roundi(spos.y * 2.0), sdir, el]
					if seen.has(key):
						continue
					seen[key] = true
					var st := _spot_status(world, spos, false, el, ghost_mode, eprops)
					out.append({"pos": spos, "dir": sdir, "el": el, "status": st})
	return out


## Returns [[end_pos: Vector2, end_dir: int, layer: int (0 ground, 1 elevated)], ...].
static func _ends_for(rail_type: String, dir: int, pos: Vector2) -> Array:
	var out: Array = []
	if rail_type == "rail-ramp":
		var ramp_ends: Variant = RailPlanner.data().get("ramp", [])
		if ramp_ends is Array:
			var turns := posmod(dir, 16) / 4
			for e in (ramp_ends as Array):
				if e is Array and (e as Array).size() >= 4:
					var ea: Array = e
					var off := Vector2(float(ea[0]), float(ea[1]))
					for _t in turns:
						off = Vector2(-off.y, off.x)
					out.append([pos + off, posmod(int(ea[2]) + dir, 16), int(ea[3])])
		return out
	var el := 1 if rail_type.begins_with("elevated-") else 0
	var base := RailPlanner.base_name(rail_type)
	if base == "legacy-straight-rail":
		base = "straight-rail"
	elif base == "legacy-curved-rail":
		base = "curved-rail-a"
	var ends_table: Dictionary = RailPlanner.data().get("ends", {})
	var key := "%s/%d" % [base, dir]
	var raw: Variant = ends_table.get(key)
	if raw == null and (base == "straight-rail" or base == "half-diagonal-rail"):
		raw = ends_table.get("%s/%d" % [base, posmod(dir, 8)])
	if raw is Array:
		for e in (raw as Array):
			if e is Array and (e as Array).size() >= 3:
				var ea: Array = e
				out.append([pos + Vector2(float(ea[0]), float(ea[1])), int(ea[2]), el])
	return out


static func _solid_rect(proto: ProtoDB.EntityProto, pos: Vector2, dir: int, eprops: Dictionary) -> Rect2:
	var ep: Variant = eprops.get(proto.id)
	if ep is Dictionary:
		var x: Variant = (ep as Dictionary).get("x")
		if x is Dictionary:
			var cb: Variant = (x as Dictionary).get("cb")
			if cb is Array and (cb as Array).size() == 4:
				var cba: Array = cb
				return WorldMirror.box_rect(Vector2(float(cba[0]), float(cba[1])), Vector2(float(cba[2]), float(cba[3])), pos, dir)
	return WorldMirror.selection_rect(proto, pos, dir)


static func _ramp_blocks_spot(r: WorldMirror.Rec, spos: Vector2, half: Vector2) -> bool:
	var uphill := CursorOverlay.dir_vector(r.dir)
	var side := Vector2(-uphill.y, uphill.x)
	var rel := spos - r.pos
	var along := absf(rel.dot(uphill))
	var across := absf(rel.dot(side))
	return across < 0.7 + half.x and along < 7.95 + half.y


func _spot_status(world: WorldMirror, spos: Vector2, is_stop: bool, el: int, ghost_mode: bool, eprops: Dictionary = {}) -> int:
	var half := Vector2(0.95, 0.95) if is_stop else Vector2(0.45, 0.45)
	var box := Rect2(spos - half, half * 2.0)
	if el == 0:
		for ty in range(floori(box.position.y), floori(box.end.y - 0.0001) + 1):
			for tx in range(floori(box.position.x), floori(box.end.x - 0.0001) + 1):
				var tid := world.tile_at(tx, ty)
				if tid >= 0 and (world.protos.is_water(tid) or world.protos.is_void(tid)):
					return 2
	for r: WorldMirror.Rec in world.entities_overlapping(box):
		var op: ProtoDB.EntityProto = world.protos.entity(r.proto_id)
		if op == null or NON_BLOCKING_TYPES.has(op.type):
			continue
		if op.type == "entity-ghost":
			if not ghost_mode or not r.extra.has("gh"):
				continue
			var gp: ProtoDB.EntityProto = world.protos.entity(int(r.extra["gh"]))
			if gp == null:
				continue
			var g_el := 1 if r.extra.has("el") or gp.type.begins_with("elevated-") else 0
			if g_el == el:
				if (not is_stop and SIGNAL_TYPES.has(gp.type)) or (is_stop and gp.type == "train-stop"):
					if r.pos.distance_squared_to(spos) < 0.04:
						return 1
					if _solid_rect(gp, r.pos, r.dir, eprops).intersects(box):
						return 2
			continue
		if op.type == "rail-ramp":
			if _ramp_blocks_spot(r, spos, half):
				return 2
			continue
		var other_el := 1 if r.extra.has("el") or op.type.begins_with("elevated-") else 0
		if other_el != el:
			continue
		if ALL_RAILS.has(op.type):
			# Factorio 2.1 rails have a 3.4 x 1.6 selection_rect that overhangs adjacent signal/stop tiles.
			# Only block if the rail's actual track footprint overlaps the spot (never its adjacent spots).
			if STRAIGHT_RAILS.has(op.type) and posmod(r.dir, 4) == 0:
				if WorldMirror.box_rect(Vector2(-0.7, -0.99), Vector2(0.7, 0.99), r.pos, r.dir).intersects(box):
					return 2
			elif r.pos.distance_squared_to(spos) < 0.81:
				return 2
			continue
		if (not is_stop and SIGNAL_TYPES.has(op.type)) or (is_stop and op.type == "train-stop"):
			if r.pos.distance_squared_to(spos) < 0.04:
				return 1
			if _solid_rect(op, r.pos, r.dir, eprops).intersects(box):
				return 2
			continue
		if _solid_rect(op, r.pos, r.dir, eprops).intersects(box):
			return 2
	return 0


func _outline_marks(spots: Array, at: Vector2, is_stop: bool, has_active: bool, active_pos: Vector2, active_el: int) -> Array:
	var near: Array = []
	var r_sq := OUTLINE_RADIUS * OUTLINE_RADIUS
	for sp: Dictionary in spots:
		if int(sp["status"]) != 0:
			continue
		var spos: Vector2 = sp["pos"]
		var d2 := spos.distance_squared_to(at)
		if d2 <= r_sq:
			near.append([d2, spos, int(sp["el"])])
	var cmp_near := func(a: Array, b: Array) -> bool:
		return float(a[0]) < float(b[0])
	near.sort_custom(cmp_near)
	var half := Vector2(0.9, 0.9) if is_stop else Vector2(0.42, 0.42)
	var el_y := _elevated_y()
	var marks: Array = []
	var seen_tiles := {}
	for entry in near:
		if marks.size() >= MAX_OUTLINES:
			break
		var spos: Vector2 = entry[1]
		var sel := int(entry[2])
		var tile_key := "%d,%d,%d" % [roundi(spos.x * 2.0), roundi(spos.y * 2.0), sel]
		if seen_tiles.has(tile_key):
			continue
		seen_tiles[tile_key] = true
		var is_active := has_active and sel == active_el and spos.distance_squared_to(active_pos) < 0.04
		var y := el_y if sel == 1 else 0.0
		marks.append(CursorOverlay.area(Rect2(spos - half, half * 2.0), SPOT_FILL, SPOT_ACTIVE_EDGE if is_active else SPOT_EDGE, y, true))
	return marks


func _block_marks(world: WorldMirror, real_rails: Array, real_signals: Array, at: Vector2) -> Array:
	if real_rails.is_empty():
		return []
	var rails: Array = []
	for pair in real_rails:
		var rec: WorldMirror.Rec = pair[0]
		var proto: ProtoDB.EntityProto = pair[1]
		var lim := BLOCK_RADIUS + (8.0 if proto.type == "rail-ramp" else 0.0)
		if rec.pos.distance_squared_to(at) <= lim * lim:
			rails.append(pair)
	if rails.is_empty():
		return []

	var signal_lookup := {}  # "x2,y2,el" -> true
	for sig: WorldMirror.Rec in real_signals:
		var sel := 1 if sig.extra.has("el") else 0
		var sk := "%d,%d,%d" % [roundi(sig.pos.x * 2.0), roundi(sig.pos.y * 2.0), sel]
		signal_lookup[sk] = true

	var signals_table: Dictionary = RailPlanner.data().get("signals", {})
	var n := rails.size()
	var rail_ends: Array = []  # per rail index: [[end_pos, edir, el, signaled], ...]
	var by_joint := {}  # "x2,y2,el" -> [[rail_idx, edir, signaled], ...]
	var is_complex := []
	is_complex.resize(n)
	is_complex.fill(false)

	for i in n:
		var rec: WorldMirror.Rec = rails[i][0]
		var proto: ProtoDB.EntityProto = rails[i][1]
		var ends := _ends_for(proto.type, rec.dir, rec.pos)
		var info_list: Array = []
		for e in ends:
			var epos: Vector2 = e[0]
			var edir := int(e[1])
			var el := int(e[2])
			var has_sig := false
			var sig_list: Variant = signals_table.get(str(edir), [])
			if sig_list is Array:
				for s in (sig_list as Array):
					if s is Array and (s as Array).size() >= 2:
						var sa: Array = s
						var spos := epos + Vector2(float(sa[0]), float(sa[1]))
						var sk := "%d,%d,%d" % [roundi(spos.x * 2.0), roundi(spos.y * 2.0), el]
						if signal_lookup.has(sk):
							has_sig = true
							break
			info_list.append([epos, edir, el, has_sig])
			var jk := "%d,%d,%d" % [roundi(epos.x * 2.0), roundi(epos.y * 2.0), el]
			if not by_joint.has(jk):
				by_joint[jk] = []
			(by_joint[jk] as Array).append([i, edir, has_sig])
		rail_ends.append(info_list)

	# Build adjacency lists and detect forks/merges.
	var open_adj: Array = []
	var sig_adj: Array = []
	var direct_neighbors: Array = []
	for i in n:
		open_adj.append([])
		sig_adj.append([])
		direct_neighbors.append({})

	for jk in by_joint:
		var list: Array = by_joint[jk]
		var dir_counts := {}
		for entry in list:
			var d := int(entry[1])
			dir_counts[d] = int(dir_counts.get(d, 0)) + 1
		var fork_here := list.size() > 2
		if not fork_here:
			for d in dir_counts:
				if int(dir_counts[d]) > 1:
					fork_here = true
					break
		if fork_here:
			for entry in list:
				is_complex[int(entry[0])] = true
		for a_idx in list.size():
			var ea: Array = list[a_idx]
			var ia := int(ea[0])
			var da := int(ea[1])
			var sa := bool(ea[2])
			for b_idx in range(a_idx + 1, list.size()):
				var eb: Array = list[b_idx]
				var ib := int(eb[0])
				var db := int(eb[1])
				var sb := bool(eb[2])
				if posmod(da + 8, 16) != db:
					continue
				(direct_neighbors[ia] as Dictionary)[ib] = true
				(direct_neighbors[ib] as Dictionary)[ia] = true
				if sa or sb:
					(sig_adj[ia] as Array).append(ib)
					(sig_adj[ib] as Array).append(ia)
				else:
					(open_adj[ia] as Array).append(ib)
					(open_adj[ib] as Array).append(ia)

	# Detect crossings / non-connected rails within 3 tiles on another axis.
	for i in n:
		var ri: WorldMirror.Rec = rails[i][0]
		var pi: ProtoDB.EntityProto = rails[i][1]
		var ri_ramp := pi.type == "rail-ramp"
		var eli := 1 if pi.type.begins_with("elevated-") else 0
		for j in range(i + 1, n):
			var pj: ProtoDB.EntityProto = rails[j][1]
			var rj_ramp := pj.type == "rail-ramp"
			var elj := 1 if pj.type.begins_with("elevated-") else 0
			if not ri_ramp and not rj_ramp and eli != elj:
				continue
			var rj: WorldMirror.Rec = rails[j][0]
			if ri.pos.distance_squared_to(rj.pos) > 9.0:
				continue
			if (direct_neighbors[i] as Dictionary).has(j):
				continue
			var same_straight := (pi.type == "straight-rail" or pi.type == "legacy-straight-rail") \
				and (pj.type == "straight-rail" or pj.type == "legacy-straight-rail") and posmod(ri.dir, 8) == posmod(rj.dir, 8)
			var same_elev_straight := pi.type == "elevated-straight-rail" and pj.type == "elevated-straight-rail" and posmod(ri.dir, 8) == posmod(rj.dir, 8)
			if not same_straight and not same_elev_straight:
				is_complex[i] = true
				is_complex[j] = true

	# BFS connected components on open_adj.
	var comp_id := []
	comp_id.resize(n)
	comp_id.fill(-1)
	var comp_complex: Array = []
	var comp_rails: Array = []
	for i in n:
		if comp_id[i] >= 0:
			continue
		var cid := comp_complex.size()
		var queue: Array[int] = [i]
		comp_id[i] = cid
		var head := 0
		var cpx := false
		var members: Array[int] = []
		while head < queue.size():
			var cur := queue[head]
			head += 1
			members.append(cur)
			if bool(is_complex[cur]):
				cpx = true
			for nb in (open_adj[cur] as Array):
				var nbi := int(nb)
				if comp_id[nbi] < 0:
					comp_id[nbi] = cid
					queue.append(nbi)
		comp_complex.append(cpx)
		comp_rails.append(members)

	# Hybrid: query bridge `rblk` ONLY for components with junctions/crossings, cached per chunk rev.
	var query_units: Array = []
	var chunk_set := {}
	for cid in comp_complex.size():
		if not bool(comp_complex[cid]):
			continue
		for idx in (comp_rails[cid] as Array):
			var rec: WorldMirror.Rec = rails[int(idx)][0]
			if rec.unit > 0:
				query_units.append(rec.unit)
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var cc := rec.chunk + Vector2i(dx, dy)
					if world.chunks.has(cc):
						chunk_set[cc] = true

	var chunk_rev_sig: Array = []
	if not query_units.is_empty():
		query_units.sort()
		var ckeys := chunk_set.keys()
		var cmp_chunk := func(a: Vector2i, b: Vector2i) -> bool:
			return a.y < b.y or (a.y == b.y and a.x < b.x)
		ckeys.sort_custom(cmp_chunk)
		for cc: Vector2i in ckeys:
			var cv = world.chunks.get(cc)
			chunk_rev_sig.append([cc.x, cc.y, int(cv.content_rev) if cv != null else -1])

		var missing: Array = []
		for u in query_units:
			var ui := int(u)
			var cached: Variant = _bridge_cache.get(ui)
			if cached == null or (cached as Array)[1] != chunk_rev_sig:
				missing.append(ui)

		if not missing.is_empty():
			var now := Time.get_ticks_msec()
			var batch: Array = []
			if anchors_on:
				# One answered rail of each cached block id in view first (query_units is sorted).
				var anchored := {}
				for u in query_units:
					if anchored.size() >= MAX_ANCHORS:
						break
					var cached_a: Variant = _bridge_cache.get(int(u))
					if cached_a != null and (cached_a as Array)[1] == chunk_rev_sig:
						var aid := int((cached_a as Array)[0])
						if not anchored.has(aid):
							anchored[aid] = true
							batch.append(int(u))
			batch.append_array(missing.slice(0, MAX_QUERY_UNITS - batch.size()))
			if batch != _last_query_units or chunk_rev_sig != _last_query_rev or (now - _last_query_msec) > QUERY_COOLDOWN_MSEC:
				for u in batch:
					_pending_rev[int(u)] = chunk_rev_sig
				_last_query_units = batch
				_last_query_rev = chunk_rev_sig
				_last_query_msec = now
				Bridge.send({"t": "rblk", "u": batch})

	# Final block key per rail.
	var block_keys: Array[String] = []
	for i in n:
		var cid := int(comp_id[i])
		var rec: WorldMirror.Rec = rails[i][0]
		if bool(comp_complex[cid]) and rec.unit > 0 and _bridge_cache.has(rec.unit):
			var cached: Array = _bridge_cache[rec.unit]
			if cached[1] == chunk_rev_sig:
				block_keys.append("b:%d" % int(cached[0]))
				continue
		block_keys.append("c:%d" % cid)

	# Graph-color adjacent blocks separated by signals so neighbors get distinct colors.
	var blk_adj := {}
	for i in n:
		var bi := block_keys[i]
		if not blk_adj.has(bi):
			blk_adj[bi] = {}
		for j in (sig_adj[i] as Array):
			var bj := block_keys[int(j)]
			if bi != bj:
				(blk_adj[bi] as Dictionary)[bj] = true

	var blk_color := {}
	var sorted_blks := blk_adj.keys()
	sorted_blks.sort()
	var pal_n := BLOCK_COLORS.size()
	for bk in sorted_blks:
		var used := {}
		for nbk in (blk_adj[bk] as Dictionary):
			if blk_color.has(nbk):
				used[int(blk_color[nbk])] = true
		var pref := posmod(str(bk).hash(), pal_n)
		var chosen := pref
		if used.has(pref):
			for k in pal_n:
				var try_c := posmod(pref + k, pal_n)
				if not used.has(try_c):
					chosen = try_c
					break
		blk_color[bk] = chosen

	var el_y := _elevated_y()
	var marks: Array = []
	for i in n:
		var rec: WorldMirror.Rec = rails[i][0]
		var proto: ProtoDB.EntityProto = rails[i][1]
		var ends: Array = rail_ends[i]
		if ends.size() < 2:
			continue
		var p0: Vector2 = ends[0][0]
		var p1: Vector2 = ends[1][0]
		var y0 := el_y if int(ends[0][2]) == 1 else 0.0
		var y1 := el_y if int(ends[1][2]) == 1 else 0.0
		var col: Color = BLOCK_COLORS[int(blk_color.get(block_keys[i], 0))]
		var base := RailPlanner.base_name(proto.type)
		if base == "curved-rail-a" or base == "curved-rail-b" or base == "legacy-curved-rail":
			var ym := (y0 + y1) * 0.5
			marks.append(CursorOverlay.line(p0, rec.pos, col, 0.42, y0, ym))
			marks.append(CursorOverlay.line(rec.pos, p1, col, 0.42, ym, y1))
		else:
			marks.append(CursorOverlay.line(p0, p1, col, 0.42, y0, y1))
	return marks
