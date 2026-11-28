extends SceneTree
## (rel-031-restarms) A resting inserter arm (past the bridge's live radius: `--live-inserter-radius=detail`, 24 tiles,
## 0.3.1's default) must look as its live idle arm would: for each way an arm is drawn (a model's rig, Wube's pieces,
## Factorio's pictures, the placeholder arm of an inserter with no arm model) one inserter is drawn live and idle at its
## pickup, then its live arm goes (out of the radius) and it rests; the test asserts the two use the same meshes, the
## same MultiMeshInstance3D settings (shadow casting, lod_bias, material override, visibility range, transparency,
## layers, colours on/off) and the same transforms and colours. Shadows also in a FAR shadow-tier chunk on Medium (a live
## arm always casts; `--rest-arm-shadows=tier` drops them there, as before) and the old stick (`--rest-arm-basic=stick`).
## Then 300 resting arms counted both ways (MultiMeshes, instances, shadow casters) for the cost.
## (rel-031-restbatch) Regions (`--rest-arms-region`): 300 arms in 12 chunks and 2,000 arms in 40 chunks drawn per region
## and per chunk, the same instances per mesh both ways; a live arm's hand-over, a chunk unloaded, a whole region gone,
## the shadow rule per region (any chunk), a pack change's clear and the switch flipped at run time; region rebuild µs.
## The arms' GDScript path (native off) so the live buffers can be read back (`_upload_bufs`); the native path's parity
## with it is inserter_rest_index_test's and inserter_loop_native_test's.
## Run: godot --headless --audio-driver Dummy --path client --log-file <abs> --script res://tests/inserter_rest_look_test.gd

const Swing := preload("res://scripts/world/inserter_swing.gd")
const Arms := preload("res://scripts/world/inserter_arms.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const ModelRig := preload("res://scripts/world/model_rig.gd")
const ViewPriority := preload("res://scripts/world/view_priority.gd")

const TOL := 1e-4
const CHUNK := Vector2i(0, 0)
## proto id -> [name, mode tag]; every one ends in "inserter" but the placeholder's (ModelLibrary.rig_name).
const KINDS := {1: ["test-rig-inserter", "rig"], 2: ["test-model-inserter", "model"], 3: ["test-sprite-inserter", "sprite"],
	4: ["test-modded-arm", "basic"]}

var failures := 0
var passes := 0


class Rec:
	var pos := Vector2.ZERO
	var proto_id := 1
	var dir := 0
	var extra := {}
	var unit := 0
	var key: Variant = 0
	var chunk := Vector2i.ZERO


class StubWorld extends Node3D:
	signal entities_changed(chunk: Vector2i)
	var entities := {}
	var chunks := {}
	var behind_cull: Object = null


## behind_cull.gd's face the arms read: on, which chunks are hidden, and its signal.
class StubCull extends RefCounted:
	signal chunk_visibility_changed(c: Vector2i, drawn: bool)
	var on := true
	var off_chunks := {}
	func is_active() -> bool:
		return on
	func hidden(c: Vector2i) -> bool:
		return off_chunks.has(c)
	func set_hidden(c: Vector2i, h: bool) -> void:
		if h:
			off_chunks[c] = true
		else:
			off_chunks.erase(c)
		chunk_visibility_changed.emit(c, not h)


class StubChunk:
	var entities := {}
	var shadow_tier := 2


class StubBelts extends Node3D:
	var t := -1.0
	func drawn_tick() -> float:
		return t
	func item_height() -> float:
		return 0.0


func check(cond: bool, what: String) -> void:
	if cond:
		passes += 1
	else:
		failures += 1
		print("FAIL ", what)


func _initialize() -> void:
	print("--- Running inserter_rest_look_test ---")
	Arms.native_inserters = false
	Arms.native_pose = false
	Arms.native_loop = false
	Arms.native_swing = false
	Arms.native_ingest = false
	Arms.native_ingest2 = false
	Arms.fast_upload = true
	Arms.belt_clock = true
	Arms.handoff = true
	Arms.events = true
	Arms.events_items = false
	Arms.rest_arms = true
	Arms.rest_box_fallback = false
	Arms.rest_shadows_live = true
	Arms.rest_basic_live = true
	Arms.sprite_arms = true
	var saved_region := Arms.rest_region
	Arms.rest_region = 4
	var ld = ModelLibrary.Load.new()
	ld.path = ProjectSettings.globalize_path("res://tests/fixtures/rig_inserter.glb")
	ld.rig_wanted = true
	ld.run()
	if ld.rig.is_empty():
		check(false, "the test rig is read as an arm rig")
	else:
		_look(ModelLibrary._commit_rig(ld.rig, "test-rig-inserter"))
		for region in [0, 4]:
			Arms.rest_region = region
			_cost(ModelLibrary._commit_rig(ld.rig, "test-rig-inserter"))
		_regions(ModelLibrary._commit_rig(ld.rig, "test-rig-inserter"))
	Arms.rest_region = saved_region
	print("inserter_rest_look_test: %s (%d passed, %d failed)" % ["PASS" if failures == 0 else "FAIL", passes, failures])
	quit(1 if failures > 0 else 0)


func _protos() -> ProtoDB:
	var protos := ProtoDB.new()
	for id: int in KINDS:
		var p := ProtoDB.EntityProto.new()
		p.id = id
		p.name = KINDS[id][0]
		p.type = "inserter"
		p.color = Color(0.8, 0.5, 0.1) if id != 4 else Color(0.2, 0.45, 0.8)
		protos.entities[id] = p
		protos.entities_by_name[p.name] = p
	return protos


## An arms layer (its placeholder parts made by _ready) with the stub models in its caches, as
## _rig_for / _pieces_for / _sprite_set_for make them once their models are read.
func _arms(world: StubWorld, protos: ProtoDB, rig: Dictionary, pictures: Dictionary, pieces: Array) -> Arms:
	var arms := Arms.new()
	arms._ready()  # (kept out of the tree, stepped by hand: the placeholder's parts made here)
	arms.protos = protos
	arms.world = world
	var ends := {"x": {"ip": [0, -1], "id": [0, 1.2], "rs": 0.014, "es": 0.035}}
	arms.eprops = {1: ends, 2: ends, 3: ends, 4: ends}
	arms._native_tried = true
	var ver := ModelLibrary.ModelPacks.version
	arms._rigs_packs = ver
	arms._parts_packs = ver
	arms._sprite_version = ver
	arms._rest_pack_ver = ver
	# Rig: its part MultiMeshes as _rig_for makes them.
	var entry := rig.duplicate()
	var mmis: Array = []
	for p in ModelRig.Part.size():
		var m: Variant = (rig["meshes"] as Array)[p]
		if m == null:
			mmis.append(null)
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = m
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		arms.add_child(mmi)
		mmis.append(mmi)
	entry["mmis"] = mmis
	arms._rigs[KINDS[1][0]] = entry
	# Wube's pieces: no rig, its three pieces as _pieces_for makes them.
	arms._rigs[KINDS[2][0]] = {}
	var piece_mmis: Array = []
	for m: Mesh in pieces:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = m
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		arms.add_child(mmi)
		piece_mmis.append(mmi)
	arms._model_parts[KINDS[2][0]] = piece_mmis
	# Pictures (the Factorio pack's): as _sprite_set_for.
	arms._rigs[KINDS[3][0]] = {}
	arms._sprite_known[KINDS[3][0]] = pictures
	arms._sprite_mmis[KINDS[3][0]] = arms._sprite_instances(KINDS[3][0], pictures, "")
	# A mod's inserter with no arm model: the placeholder arm (Mode.BASIC).
	arms._rigs[KINDS[4][0]] = {}
	arms._model_parts[KINDS[4][0]] = null
	for id: int in KINDS:
		if id != 3:
			arms._sprite_known[KINDS[id][0]] = {}
	arms.belts = StubBelts.new()
	arms.add_child(arms.belts)
	return arms


## The settings that decide how a MultiMeshInstance3D looks, as text.
static func _looks(mmi: MultiMeshInstance3D) -> String:
	return "cast %d lod_bias %.2f override %s vis %.1f..%.1f mode %d transp %.2f layers %d gi %d colours %s" % [
		mmi.cast_shadow, mmi.lod_bias, str(mmi.material_override.get_instance_id()) if mmi.material_override != null else "none",
		mmi.visibility_range_begin, mmi.visibility_range_end, mmi.visibility_range_fade_mode, mmi.transparency, mmi.layers,
		mmi.gi_mode, mmi.multimesh.use_colors]


## The live arms' MultiMeshes drawing something: Mesh -> [mmi, buffer (its visible instances), stride].
func _live_draws(arms: Arms) -> Dictionary:
	var out := {}
	var all: Array = []
	for entry: Variant in arms._rigs.values():
		if entry is Dictionary:
			for mmi: Variant in (entry as Dictionary).get("mmis", []):
				if mmi != null:
					all.append(mmi)
	for pieces: Variant in arms._model_parts.values():
		if pieces != null:
			all.append_array(pieces)
	for mmis: Array in arms._sprite_mmis.values():
		all.append_array(mmis)
	all.append_array(arms._parts)
	for mmi: MultiMeshInstance3D in all:
		var mm := mmi.multimesh
		var n := mm.visible_instance_count
		if n <= 0:
			continue
		var stride := 16 if mm.use_colors else 12
		var buf: PackedFloat32Array = arms._upload_bufs.get(mm.get_rid(), PackedFloat32Array())
		out[mm.mesh] = [mmi, buf.slice(0, n * stride), stride]
	return out


## The resting arms' MultiMeshes drawing something, for the chunk: Mesh -> [mmi, buffer, stride].
func _rest_draws(arms: Arms, pending: Dictionary, sprites: Dictionary) -> Dictionary:
	var out := {}
	var chunk_mmis: Dictionary = arms._rest_3d_mmis.get(CHUNK, {})
	for m: Variant in pending:
		var mmi: MultiMeshInstance3D = chunk_mmis.get(m)
		var stride := 16 if arms._rest_basic_meshes.has(m) else 12
		out[m] = [mmi, pending[m], stride]
	for model: String in sprites:
		var mmis: Array = arms._sprite_rest_mmis.get(model, [])
		for p in mmis.size():
			var buf: PackedFloat32Array = sprites[model][p]
			if buf.is_empty():
				continue
			var mmi: MultiMeshInstance3D = mmis[p]
			out[mmi.multimesh.mesh] = [mmi, buf, 12]
	return out


static func _sorted(buf: PackedFloat32Array, stride: int) -> PackedFloat32Array:
	var rows: Array = []
	for i in range(0, buf.size(), stride):
		rows.append(buf.slice(i, i + stride))
	var before := func(a: PackedFloat32Array, b: PackedFloat32Array) -> bool:
		for k in a.size():
			if absf(a[k] - b[k]) > 1e-3:
				return a[k] < b[k]
		return false
	rows.sort_custom(before)
	var out := PackedFloat32Array()
	for r: PackedFloat32Array in rows:
		out.append_array(r)
	return out


static func _max_diff(x: PackedFloat32Array, y: PackedFloat32Array) -> float:
	if x.size() != y.size():
		return INF
	var worst := 0.0
	for i in x.size():
		worst = maxf(worst, absf(x[i] - y[i]))
	return worst


func _event(arms: Arms, k: int, ev: int, unit: int, at: Vector2) -> void:
	arms.handle_events({"t": "ie", "k": k, "n": 6, "p": 2, "part": 1, "parts": 1,
		"l": [ev, unit, k, 0, 0, 0, roundi(at.x), roundi(at.y), 0]})


func _frame(arms: Arms, t: float) -> void:
	(arms.belts as StubBelts).t = t
	arms._process(1.0 / 60.0)
	arms.sync_arms()


func _look(rig: Dictionary) -> void:
	var protos := _protos()
	var world := StubWorld.new()
	root.add_child(world)
	var cv := StubChunk.new()
	cv.shadow_tier = 1  # (a FAR chunk: past the ring round the character, as an inserter past 24 tiles mostly is)
	world.chunks[CHUNK] = cv
	var quads: Array = []
	for i in 3:
		var q := QuadMesh.new()
		quads.append(q)
	var pictures := {"meshes": quads, "widths": [0.55, 0.3, 0.34], "files": ["a", "b", "c"]}
	var pieces: Array = [BoxMesh.new(), BoxMesh.new(), BoxMesh.new()]
	var arms := _arms(world, protos, rig, pictures, pieces)
	var units := {}  # unit -> proto id
	var at_picks := {}
	var u := 100
	for id: int in KINDS:
		for dir in [0, 4]:
			u += 1
			var rec := Rec.new()
			rec.unit = u
			rec.proto_id = id
			rec.pos = Vector2(4.5 + u % 20, 6.5 + 3 * (id % 5))
			rec.dir = dir
			rec.chunk = CHUNK
			world.entities[u] = rec
			cv.entities[u] = rec
			units[u] = id
			var pick := Vector2(0, -1).rotated(PI * dir / 8.0)
			at_picks[u] = (rec.pos + pick) * 256.0
	var saved_quality := ModelLods.quality_name
	for quality: String in ["medium", "high"]:
		ModelLods.quality_name = quality
		# Live and idle at the pickup (the bridge's SYNC with an empty hand), a few frames.
		var k := 100
		for unit: int in units:
			_event(arms, k, Swing.Ev.SYNC, unit, at_picks[unit])
		for f in 4:
			_frame(arms, float(k + f))
		check(arms.count() == units.size(), "%s: every arm live (%d of %d)" % [quality, arms.count(), units.size()])
		var live := _live_draws(arms)
		# Out of the live radius: GONE, and it rests.
		k = 120
		for unit: int in units:
			_event(arms, k, Swing.Ev.GONE, unit, Vector2.ZERO)
		_frame(arms, float(k))
		check(arms.count() == 0 and arms.rest_rig_count == 2 and arms.rest_model_count == 2 and arms.sprite_rest_count == 2
			and arms.rest_basic_count == 2 and arms.rest_count == 0,
			"%s: every arm rests the way it was live (rig %d, Wube %d, pictures %d, placeholder %d, stick %d)" % [quality,
			arms.rest_rig_count, arms.rest_model_count, arms.sprite_rest_count, arms.rest_basic_count, arms.rest_count])
		arms._rest_chunk(CHUNK)  # (the chunk's buffers again: the flush let them go)
		var rest := _rest_draws(arms, arms._rest_3d_pending.get(CHUNK, {}), arms._rest_sprites.get(CHUNK, {}))
		arms._rest_3d_pending.erase(CHUNK)
		arms._rest_3d_upload.erase(CHUNK)
		var tags := {}
		for m: Variant in live:
			tags[m] = "?"
		check(live.size() == rest.size(), "%s: as many meshes drawn resting (%d) as live (%d)" % [quality, rest.size(), live.size()])
		var worst := 0.0
		for m: Variant in live:
			var lv: Array = live[m]
			var name := (lv[0] as Node).name
			check(rest.has(m), "%s: %s's mesh drawn resting too" % [quality, name])
			if not rest.has(m):
				continue
			var rv: Array = rest[m]
			check(rv[0] != null, "%s: %s's resting MultiMesh made" % [quality, name])
			if rv[0] == null:
				continue
			var a := _looks(lv[0])
			var b := _looks(rv[0])
			check(a == b, "%s: %s looks the same resting (live: %s / resting: %s)" % [quality, name, a, b])
			check(int(lv[2]) == int(rv[2]), "%s: %s instance layout %d vs %d floats" % [quality, name, lv[2], rv[2]])
			var d := _max_diff(_sorted(lv[1], lv[2]), _sorted(rv[1], rv[2]))
			worst = maxf(worst, d)
			check(d < TOL, "%s: %s's transforms and colours resting equal live (%d vs %d floats, max diff %s)" % [quality, name,
				(lv[1] as PackedFloat32Array).size(), (rv[1] as PackedFloat32Array).size(), d])
		print("%s: %d meshes compared, max diff %s" % [quality, live.size(), worst])
	# The old rules behind their switches: FAR chunk on Medium drops resting shadows (tier); NONE never casts (no ground
	# in view its shadow could fall on); the old stick for the placeholder.
	ModelLods.quality_name = "medium"
	Arms.rest_shadows_live = false
	arms._sync_rest_3d_shadow(CHUNK)
	var casts := 0
	for mmi: Variant in (arms._rest_3d_mmis.get(CHUNK, {}) as Dictionary).values():
		if (mmi as MultiMeshInstance3D).visible and (mmi as MultiMeshInstance3D).cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			casts += 1
	check(casts == 0, "--rest-arm-shadows=tier: a FAR chunk's resting arms cast nothing on Medium, as before (%d casting)" % casts)
	Arms.rest_shadows_live = true
	cv.shadow_tier = 0
	check(arms._rest_3d_cast_shadow(CHUNK) == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "a NONE-tier chunk's resting arms cast nothing")
	cv.shadow_tier = 1
	arms._sync_rest_3d_shadow(CHUNK)
	Arms.rest_basic_live = false
	_frame(arms, 130.0)
	check(arms.rest_basic_count == 0 and arms.rest_count == 2, "--rest-arm-basic=stick: the placeholder rests as the old stick (%d stick, %d placeholder)" % [
		arms.rest_count, arms.rest_basic_count])
	Arms.rest_basic_live = true
	ModelLods.quality_name = saved_quality
	arms.free()
	world.queue_free()


## 300 resting arms (rig and placeholder halves) over 12 FAR chunks on Medium: MultiMeshes, instances and shadow casters
## with the live look (default) and with the old rules (--rest-arm-shadows=tier, --rest-arm-basic=stick).
func _cost(rig: Dictionary) -> void:
	var protos := _protos()
	var world := StubWorld.new()
	root.add_child(world)
	var chunks: Array = []
	for i in 12:
		var c := Vector2i(i % 4, i / 4)
		var cv := StubChunk.new()
		cv.shadow_tier = 1
		world.chunks[c] = cv
		chunks.append(c)
	var quads: Array = [QuadMesh.new(), QuadMesh.new(), QuadMesh.new()]
	var arms := _arms(world, protos, rig, {"meshes": quads, "widths": [0.5, 0.3, 0.3], "files": ["a", "b", "c"]},
		[BoxMesh.new(), BoxMesh.new(), BoxMesh.new()])
	for i in 300:
		var c: Vector2i = chunks[i % chunks.size()]
		var rec := Rec.new()
		rec.unit = 1000 + i
		rec.proto_id = 1 if i < 150 else 4
		rec.pos = Vector2(c.x * 32 + 2.5 + (i / 12) % 28, c.y * 32 + 2.5 + (i % 7) * 4)
		rec.chunk = c
		world.entities[rec.unit] = rec
		world.chunks[c].entities[rec.unit] = rec
	var saved_quality := ModelLods.quality_name
	ModelLods.quality_name = "medium"
	var lines := []
	for old in [false, true]:
		Arms.rest_shadows_live = not old
		Arms.rest_basic_live = not old
		for c: Vector2i in chunks:
			arms._rest_dirty[c] = true
		arms._rest_now.clear()
		for f in 60:
			_frame(arms, 200.0 + f)
			if arms._rest_dirty.is_empty() and f >= 2:
				break
		arms._rest_wait = 0.0  # (put together now, not at the next REST_REFRESH)
		_frame(arms, 300.0)
		for k: Vector2i in arms._rest_3d_mmis:
			arms._sync_rest_3d_shadow(k)
		var mmis := 0
		var instances := 0
		var casters := 0
		for d: Variant in arms._rest_3d_mmis.values():
			for mmi: Variant in (d as Dictionary).values():
				var node := mmi as MultiMeshInstance3D
				if node == null or not node.visible:
					continue
				mmis += 1
				instances += node.multimesh.visible_instance_count
				if node.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
					casters += 1
		var sticks := 0
		for mmi: Variant in arms._rest_chunk_mmis.values():
			var node := mmi as MultiMeshInstance3D
			if node != null and node.visible and node.multimesh.visible_instance_count > 0:
				mmis += 1
				sticks += node.multimesh.visible_instance_count
		var line := "region %s, %s: 300 resting arms (150 rig, 150 placeholder) in 12 FAR chunks on Medium: %d MultiMeshes (draws), %d 3D instances + %d stick boxes, %d shadow casters (shadow-pass draws)" % [
			str(Arms.rest_region) if Arms.rest_region > 1 else "off", "old rules (tier, stick)" if old else "live look (default)", mmis, instances, sticks, casters]
		print(line)
		lines.append([mmis, instances, sticks, casters])
		check(arms.rest_rig_count == 150, "cost: 150 rig arms rest (%d)" % arms.rest_rig_count)
	check(int(lines[0][3]) > 0 and int(lines[1][3]) == 0, "cost: the live look casts shadows in FAR chunks on Medium, the old rules none")
	Arms.rest_shadows_live = true
	Arms.rest_basic_live = true
	ModelLods.quality_name = saved_quality
	arms.free()
	world.queue_free()


## (rel-031-restbatch) The rows (stride floats each) every resting 3D MultiMesh draws, per mesh, sorted; and the count of
## MultiMeshInstance3Ds drawing something.
func _rest_rows(arms: Arms) -> Array:
	var per_mesh := {}
	var mmis := 0
	for d: Variant in arms._rest_3d_mmis.values():
		for m: Variant in (d as Dictionary):
			var node := (d as Dictionary)[m] as MultiMeshInstance3D
			if node == null or not node.visible or node.multimesh.visible_instance_count == 0:
				continue
			mmis += 1
			var stride := 16 if arms._rest_basic_meshes.has(m) else 12
			var buf := node.multimesh.buffer
			var into: PackedFloat32Array = per_mesh.get(m, PackedFloat32Array())
			into.append_array(buf.slice(0, node.multimesh.visible_instance_count * stride))
			per_mesh[m] = into
	for m: Variant in per_mesh:
		per_mesh[m] = _sorted(per_mesh[m], 16 if arms._rest_basic_meshes.has(m) else 12)
	return [mmis, per_mesh]


func _settle(arms: Arms, t: float) -> void:
	for f in 400:
		_frame(arms, t + f * 0.01)
		if arms._rest_dirty.is_empty() and arms._rest_now.is_empty() and f >= 2:
			break
	arms._rest_wait = 0.0
	_frame(arms, t + 5.0)


func _scene(world: StubWorld, chunks: Array, n: int) -> void:
	for i in n:
		var c: Vector2i = chunks[i % chunks.size()]
		var rec := Rec.new()
		rec.unit = 5000 + i
		var j := i / chunks.size()
		rec.proto_id = [1, 2, 4][(i + j) % 3]  # (every chunk a mix)
		rec.pos = Vector2(c.x * 32 + 1.5 + (j * 3) % 30, c.y * 32 + 1.5 + ((j * 3) / 30) * 2 % 30)
		rec.dir = [0, 4, 8, 12][j % 4]
		rec.chunk = c
		world.entities[rec.unit] = rec
		world.chunks[c].entities[rec.unit] = rec


func _regions(rig: Dictionary) -> void:
	var saved_quality := ModelLods.quality_name
	ModelLods.quality_name = "medium"
	for scene: Array in [[12, 4, 300, Vector2i(-2, -1), [0, 4]], [40, 8, 2000, Vector2i.ZERO, [0, 2, 4, 8]]]:
		var n_chunks: int = scene[0]
		var n_arms: int = scene[2]
		var origin: Vector2i = scene[3]
		var results := {}
		for region: int in scene[4]:
			Arms.rest_region = region
			var protos := _protos()
			var world := StubWorld.new()
			root.add_child(world)
			var chunks: Array = []
			for i in n_chunks:
				var c := Vector2i(i % int(scene[1]), i / int(scene[1])) + origin  # (300: negative chunks too, floor keys)
				var cv := StubChunk.new()
				cv.shadow_tier = 1
				world.chunks[c] = cv
				chunks.append(c)
			_scene(world, chunks, n_arms)
			var arms := _arms(world, protos, rig, {"meshes": [QuadMesh.new(), QuadMesh.new(), QuadMesh.new()],
				"widths": [0.5, 0.3, 0.3], "files": ["a", "b", "c"]}, [BoxMesh.new(), BoxMesh.new(), BoxMesh.new()])
			_settle(arms, 100.0)
			var rows := _rest_rows(arms)
			results[region] = rows
			var arms_drawn := arms.rest_3d_count + arms.rest_basic_count
			var line := "%d resting arms in %d chunks, %s: %d MultiMeshInstance3Ds" % [n_arms, n_chunks,
				"per region (%dx%d)" % [region, region] if region > 1 else "per chunk", int(rows[0])]
			if region > 1:
				# Upload cost: every region put together from its chunks' kept buffers, and the biggest region alone.
				for c: Vector2i in arms._rest_3d_bufs:
					arms._rest_3d_pending[c] = arms._rest_3d_bufs[c]
					arms._rest_3d_upload[c] = true
				arms._flush_rest_3d_chunks()
				var all_us := arms.rest_3d_region_usec
				var big := Vector2i.ZERO
				var big_n := 0
				for k: Vector2i in arms._rest_3d_region_chunks:
					var nk := (arms._rest_3d_region_chunks[k] as Dictionary).size()
					if nk > big_n:
						big_n = nk
						big = k
				var c1: Vector2i = (arms._rest_3d_region_chunks[big] as Dictionary).keys()[0]
				arms._rest_3d_pending[c1] = arms._rest_3d_bufs[c1]
				arms._rest_3d_upload[c1] = true
				arms._flush_rest_3d_chunks()
				line += "; rebuild all %d regions %d us, one %d-chunk region (%d arms) %d us" % [arms._rest_3d_region_chunks.size(),
					all_us, big_n, big_n * n_arms / n_chunks, arms.rest_3d_region_usec]
			print(line)
			check(arms_drawn == n_arms, "%d arms: every arm rests (%d)" % [n_arms, arms_drawn])
			if (region == 2 or region == 4) and n_arms == 2000:
				_region_cases(arms, world, chunks, rig, region)
			arms.free()
			world.queue_free()
		var a: Array = results[0]
		var b: Array = results[4]
		for r: int in results:
			if r > 1 and r != 4:
				check(int((results[r] as Array)[0]) < int(a[0]), "%d arms, region %d: fewer MultiMeshes than per chunk" % [n_arms, r])
		check(int(b[0]) < int(a[0]), "%d arms: fewer MultiMeshes per region (%d) than per chunk (%d)" % [n_arms, b[0], a[0]])
		var pa: Dictionary = a[1]
		var pb: Dictionary = b[1]
		var same := pa.size() == pb.size()
		var worst := 0.0
		for m: Variant in pa:
			if not pb.has(m):
				same = false
				continue
			var d := _max_diff(pa[m], pb[m])
			worst = maxf(worst, d)
			same = same and d < TOL
		# (meshes are the same objects only within one arms layer: the rig's are shared, the pieces' and placeholder's
		# made per layer, so compare those by count of floats per kind)
		if not same:
			var sa := []
			var sb := []
			for m: Variant in pa:
				sa.append((pa[m] as PackedFloat32Array).size())
			for m: Variant in pb:
				sb.append((pb[m] as PackedFloat32Array).size())
			sa.sort()
			sb.sort()
			same = sa == sb and worst < TOL
			check(same, "%d arms: same instances per mesh per region as per chunk (%s vs %s floats, max diff %s)" % [n_arms, sa, sb, worst])
		else:
			check(true, "")
	ModelLods.quality_name = saved_quality


## (regions 2 and 4, 2,000 arms) The region's behaviour as the per chunk's: behind-cull, hand-over, unload, shadows,
## clear, switch flip.
func _region_cases(arms: Arms, world: StubWorld, chunks: Array, rig: Dictionary, region: int) -> void:
	var total := func() -> int:
		var t := 0
		for d: Variant in arms._rest_3d_mmis.values():
			for mmi: Variant in (d as Dictionary).values():
				var node := mmi as MultiMeshInstance3D
				if node != null and node.visible:
					t += node.multimesh.visible_instance_count
		return t
	var before: int = total.call()
	var c0: Vector2i = chunks[0]
	for c: Vector2i in arms._rest_3d_bufs:
		arms._rest_3d_pending[c] = arms._rest_3d_bufs[c]
		arms._rest_3d_upload[c] = true
	arms._flush_rest_3d_chunks()
	check(total.call() == before, "rebuilt regions draw the same instances (%d vs %d)" % [total.call(), before])
	_behind_cull_cases(arms, world, region)
	check(total.call() == before, "region %d: behind-cull undone, every instance drawn again (%d)" % [region, total.call()])
	# Live hand-over: a rig arm goes live, the region drops its resting arm that same frame; it rests again when gone.
	var unit := 5000  # (i 0: proto 1, the rig, in chunks[0])
	var rec: Rec = world.entities[unit]
	var rigs_before := arms.rest_rig_count
	_event(arms, 500, Swing.Ev.SYNC, unit, (rec.pos + Vector2(0, -1)) * 256.0)
	_frame(arms, 500.0)
	check(arms.count() == 1 and arms.rest_rig_count == rigs_before - 1, "hand-over: the live arm's resting one gone the same frame (%d live, rig %d -> %d)" % [
		arms.count(), rigs_before, arms.rest_rig_count])
	var parts := 0
	for p in ModelRig.Part.size():
		if (rig["meshes"] as Array)[p] != null:
			parts += 1
	check(total.call() == before - parts, "hand-over: the region draws %d instances fewer (%d vs %d)" % [parts, total.call(), before])
	_event(arms, 510, Swing.Ev.GONE, unit, Vector2.ZERO)
	_frame(arms, 510.0)
	_frame(arms, 510.1)
	check(arms.count() == 0 and arms.rest_rig_count == rigs_before and total.call() == before, "hand-over: back at rest the same frame (%d instances)" % total.call())
	# Shadows: a region casts if any of its chunks would.
	var k := arms._rest_3d_key(c0)
	var members: Array = (arms._rest_3d_region_chunks[k] as Dictionary).keys()
	for c: Vector2i in members:
		world.chunks[c].shadow_tier = 0
	check(arms._rest_3d_key_cast(k) == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "shadows: a region of NONE chunks casts nothing")
	world.chunks[members[-1]].shadow_tier = 1
	check(arms._rest_3d_key_cast(k) == GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "shadows: one FAR chunk casting makes the region cast")
	Arms.rest_shadows_live = false
	check(arms._rest_3d_key_cast(k) == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "shadows: --rest-arm-shadows=tier, a FAR chunk on Medium: the region casts nothing")
	world.chunks[members[0]].shadow_tier = 2
	check(arms._rest_3d_key_cast(k) == GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "shadows: tier, a NEAR chunk makes the region cast")
	Arms.rest_shadows_live = true
	arms._sync_rest_3d_shadow(k)
	for mmi: Variant in (arms._rest_3d_mmis[k] as Dictionary).values():
		check((mmi as MultiMeshInstance3D).cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "shadows: the region's MultiMeshes follow")
	for c: Vector2i in members:
		world.chunks[c].shadow_tier = 1
	# A chunk unloaded: the region keeps the others'.
	var gone_rigs := 0
	for u: Variant in world.chunks[c0].entities:
		if (world.chunks[c0].entities[u] as Rec).proto_id != 3:
			gone_rigs += 1
	var drawn_before := arms.rest_3d_count + arms.rest_basic_count
	world.chunks.erase(c0)
	world.entities_changed.emit(c0)
	_settle(arms, 600.0)
	check(arms.rest_3d_count + arms.rest_basic_count == drawn_before - gone_rigs and not arms._rest_3d_bufs.has(c0)
		and not (arms._rest_3d_region_chunks[k] as Dictionary).has(c0), "unload: the chunk's arms gone, its region's others kept (%d -> %d)" % [
		drawn_before, arms.rest_3d_count + arms.rest_basic_count])
	# A whole region unloaded: its MultiMeshes freed.
	for c: Vector2i in members:
		if world.chunks.has(c):
			world.chunks.erase(c)
			world.entities_changed.emit(c)
	_settle(arms, 700.0)
	check(not arms._rest_3d_mmis.has(k) and not arms._rest_3d_region_chunks.has(k), "unload: a region with no chunk left has no MultiMeshes")
	var left: int = total.call()
	var left_mmis := int(_rest_rows(arms)[0])
	# A pack change's clear: put together again the same.
	arms._clear_rest_3d_mmis()
	for c: Vector2i in world.chunks:
		arms._rest_dirty[c] = true
	_settle(arms, 800.0)
	check(total.call() == left and int(_rest_rows(arms)[0]) == left_mmis, "clear: the regions put together again (%d instances, %d MultiMeshes)" % [total.call(), left_mmis])
	# The switch flipped at run time: per chunk, then regions again, the same instances.
	Arms.rest_region = 0
	arms._rest_3d_upload[world.chunks.keys()[0]] = true
	_settle(arms, 900.0)
	arms._flush_rest_3d_chunks()
	var per_chunk_mmis := int(_rest_rows(arms)[0])
	check(total.call() == left and per_chunk_mmis > left_mmis, "switch off at run time: per chunk again (%d MultiMeshes, %d instances)" % [per_chunk_mmis, total.call()])
	Arms.rest_region = region
	arms._rest_3d_upload[world.chunks.keys()[0]] = true
	arms._flush_rest_3d_chunks()
	_settle(arms, 1000.0)
	check(total.call() == left and int(_rest_rows(arms)[0]) == left_mmis, "switch on at run time: regions again (%d MultiMeshes)" % int(_rest_rows(arms)[0]))


## (review item 1) Behind-cull with regions on: chunk (0,0) is its own region key (floor(0 / n) == 0), and hiding it
## alone must keep its region shown while another of its chunks is in view; the region hides when all its chunks do.
func _behind_cull_cases(arms: Arms, world: StubWorld, region: int) -> void:
	var saved_tight := ViewPriority.tight_cull
	ViewPriority.tight_cull = true
	var bc := StubCull.new()
	world.behind_cull = bc
	arms._connect_rest_behind()
	var k := arms._rest_3d_key(Vector2i.ZERO)
	var shown := func() -> int:
		var n := 0
		for m: Variant in (arms._rest_3d_mmis.get(k, {}) as Dictionary).values():
			if (m as MultiMeshInstance3D).visible:
				n += 1
		return n
	var members: Array = (arms._rest_3d_region_chunks.get(k, {}) as Dictionary).keys()
	var all_n: int = shown.call()
	check(k == Vector2i.ZERO and members.size() > 1 and all_n > 0, "region %d: chunk (0,0) is its own region key with %d chunks (%d MultiMeshes)" % [
		region, members.size(), all_n])
	bc.set_hidden(Vector2i.ZERO, true)
	check(shown.call() == all_n, "region %d: chunk (0,0) behind the camera, a neighbour in view: its region stays shown (%d of %d)" % [
		region, shown.call(), all_n])
	for c: Vector2i in members:
		bc.set_hidden(c, true)
	check(shown.call() == 0, "region %d: every chunk of the region behind the camera: the region hides (%d shown)" % [region, shown.call()])
	bc.set_hidden(members[-1] if members[-1] != Vector2i.ZERO else members[0], false)
	check(shown.call() == all_n, "region %d: one chunk back in view: the region shows again (%d)" % [region, shown.call()])
	for c: Vector2i in members:
		bc.set_hidden(c, false)
	bc.on = false
	world.behind_cull = null
	ViewPriority.tight_cull = saved_tight
