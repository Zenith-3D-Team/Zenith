extends SceneTree
## Headless unit tests for Distant Horizon LOD data, palette, chunk baker, and Zstd disk cache.
## Run:
##   godot --headless --audio-driver Dummy --path client -s res://tests/lod_data_test.gd

const TestEnv := preload("res://tests/test_env.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const TerrainTextures := preload("res://scripts/world/terrain_textures.gd")
const FarChunks := preload("res://scripts/world/far_chunks.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const Looks := preload("res://scripts/world/looks.gd")
const LodData := preload("res://scripts/world/lod_data.gd")
const LodCache := preload("res://scripts/world/lod_cache.gd")
const DistantHorizon := preload("res://scripts/world/distant_horizon.gd")

var _fails := 0


class FakeRec extends RefCounted:
	var proto_id := 0
	var pos := Vector2.ZERO
	var dir := 0
	var extra := {}

	func _init(p_id: int, p_pos: Vector2, p_dir := 0, p_extra := {}) -> void:
		proto_id = p_id
		pos = p_pos
		dir = p_dir
		extra = p_extra


func _check(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("FAIL: ", what)


func _approx(a: float, b: float, eps := 0.01) -> bool:
	return absf(a - b) <= eps


func _make_protos() -> ProtoDB:
	var db := ProtoDB.new()
	db.add_tiles([
		[1, "grass-1", 60, 120, 40],
		[2, "water", 30, 80, 160],
		[3, "concrete", 120, 120, 125],
		[4, "lava-hot", 220, 70, 20],
		[5, "empty-space", 10, 10, 15],
	])
	db.add_entities([
		[1, "assembling-machine-1", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 80, 140, 180, 3, 3],
		[2, "tree-01", "tree", -0.7, -0.7, 0.7, 0.7, 40, 130, 40, 1, 1],
		[3, "transport-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 220, 180, 40, 1, 1],
		[4, "iron-ore", "resource", -0.5, -0.5, 0.5, 0.5, 90, 120, 150, 1, 1],
		[5, "small-lamp", "lamp", -0.4, -0.4, 0.4, 0.4, 240, 240, 200, 1, 1],
		[6, "stone-furnace", "furnace", -1.0, -1.0, 1.0, 1.0, 130, 110, 100, 2, 2],
		[7, "cliff", "cliff", -1.5, -1.5, 1.5, 1.5, 110, 95, 80, 3, 3],
		[8, "straight-rail", "straight-rail", -1.0, -1.0, 1.0, 1.0, 120, 120, 120, 2, 2],
		[9, "laser-turret", "electric-turret", -1.0, -1.0, 1.0, 1.0, 200, 60, 60, 2, 2],
		[10, "chemical-plant", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 100, 180, 120, 3, 3],
		[11, "nuclear-reactor", "reactor", -2.5, -2.5, 2.5, 2.5, 80, 210, 100, 5, 5],
	])
	return db


func _initialize() -> void:
	TestEnv.isolate("lod-data-test")
	_test_from_msg_and_rle()
	_test_downsample()
	_test_bake_from_world_chunk()
	_test_palette()
	_test_palette_refresh()
	_test_cache()
	_test_async_cache_and_bake_cap()
	TestEnv.clean()
	if _fails == 0:
		print("lod_data_test: PASS")
	else:
		print("FAILS %d" % _fails)
	quit(1 if _fails > 0 else 0)


func _test_from_msg_and_rle() -> void:
	for res: int in LodData.RESOLUTIONS:
		_check(LodData.valid_res(res), "valid_res(%d)" % res)
		var n := 32 / res
		var total := n * n
		var chunk := LodData.LodChunk.from_msg({
			"cx": 3.0,
			"cy": -4.0,
			"res": float(res),
			"rv": 42.0,
			"tl": [1.0, float(total)],
			"el": [0.0, 0.0, float(total)],
		})
		_check(chunk != null, "from_msg valid at res %d" % res)
		if chunk != null:
			_check(chunk.cx == 3 and chunk.cy == -4 and chunk.res == res and chunk.rev == 42,
				"from_msg scalar float conversion at res %d" % res)
			_check(chunk.tiles.size() == total and chunk.protos.size() == total and chunk.flags.size() == total,
				"from_msg array lengths at res %d" % res)
			var tl_rle := chunk.encode_tile_rle()
			var el_rle := chunk.encode_ent_rle()
			_check(tl_rle == PackedInt32Array([1, total]), "encode_tile_rle res %d" % res)
			_check(el_rle == PackedInt32Array([0, 0, total]), "encode_ent_rle res %d" % res)

	# Multi-run RLE round-trip
	var src := LodData.LodChunk.new()
	src.cx = -2
	src.cy = 7
	src.res = 16
	src.rev = 99
	src.tiles = PackedInt32Array([1, 1, 2, 3])
	src.protos = PackedInt32Array([0, 1, 1, 5])
	src.flags = PackedByteArray([0, 0x55, 0x55, 0x7F])
	var rt := LodData.LodChunk.from_msg({
		"cx": src.cx,
		"cy": src.cy,
		"res": src.res,
		"rv": src.rev,
		"tl": Array(src.encode_tile_rle()),
		"el": Array(src.encode_ent_rle()),
	})
	_check(rt != null and rt.tiles == src.tiles and rt.protos == src.protos and rt.flags == src.flags,
		"RLE encode/decode round-trip preserves exact cell arrays")

	# Rejection / fuzz cases
	_check(not LodData.valid_res(0) and not LodData.valid_res(3) and not LodData.valid_res(64),
		"invalid resolutions rejected by valid_res")
	_check(LodData.LodChunk.from_msg({"none": true, "cx": 0, "cy": 0, "res": 8, "tl": [1, 16], "el": [0, 0, 16]}) == null,
		"from_msg returns null when none=true")
	_check(LodData.LodChunk.from_msg({"none": 1.0, "cx": 0, "cy": 0, "res": 8, "tl": [1, 16], "el": [0, 0, 16]}) == null,
		"from_msg returns null when none=1.0")
	_check(LodData.LodChunk.from_msg({"cx": 0, "cy": 0, "res": 6, "tl": [1, 16], "el": [0, 0, 16]}) == null,
		"from_msg rejects invalid res")
	_check(LodData.LodChunk.from_msg({"cx": 0, "cy": 0, "res": 8, "tl": {}, "el": {}}) == null,
		"from_msg handles empty {} Lua arrays safely")
	_check(LodData.LodChunk.from_msg({"cx": 0, "cy": 0, "res": 8, "tl": [1, 16], "el": {}}) == null,
		"from_msg rejects empty {} el array")
	_check(LodData.LodChunk.from_msg({"cx": 0, "cy": 0, "res": 8, "tl": "bad", "el": [0, 0, 16]}) == null,
		"from_msg rejects non-array tl")
	_check(LodData.LodChunk.from_msg({"cx": 0, "cy": 0, "res": 8, "tl": [1, 15], "el": [0, 0, 16]}) == null,
		"from_msg rejects short tl RLE length")
	_check(LodData.LodChunk.from_msg({"cx": 0, "cy": 0, "res": 8, "tl": [1, 17], "el": [0, 0, 16]}) == null,
		"from_msg rejects long tl RLE length")
	_check(LodData.LodChunk.from_msg({"cx": 0, "cy": 0, "res": 8, "tl": [1, 16, 2], "el": [0, 0, 16]}) == null,
		"from_msg rejects odd/truncated tl RLE")
	_check(LodData.LodChunk.from_msg({"cx": 0, "cy": 0, "res": 8, "tl": [1, 16], "el": [0, 0, 10, 1, 2]}) == null,
		"from_msg rejects truncated el RLE")
	_check(LodData.LodChunk.from_msg({"cx": 0, "cy": 0, "res": 8, "tl": [1, 0, 1, 16], "el": [0, 0, 16]}) == null,
		"from_msg rejects zero count")
	_check(LodData.LodChunk.from_msg({"cx": 0, "cy": 0, "res": 8, "tl": [1, -4], "el": [0, 0, 16]}) == null,
		"from_msg rejects negative count")
	_check(LodData.LodChunk.from_msg({"cx": 0, "cy": 0, "res": 8, "tl": [1, 1e30], "el": [0, 0, 16]}) == null,
		"from_msg rejects huge float count")
	_check(LodData.LodChunk.from_msg({"cx": 0, "cy": 0, "res": 8, "tl": [1, 16], "el": [1, 300, 16]}) == null,
		"from_msg rejects out-of-range flags")
	_check(LodData.LodChunk.from_msg({"cx": NAN, "cy": 0, "res": 8, "tl": [1, 16], "el": [0, 0, 16]}) == null,
		"from_msg rejects non-finite coordinates")
	var packed_ch := LodData.LodChunk.from_msg({
		"cx": -5, "cy": 9, "res": 8, "rv": 3,
		"tl": PackedInt32Array([2, 16]), "el": PackedInt32Array([1, 0x55, 16]),
	})
	_check(packed_ch != null and packed_ch.tiles.size() == 16 and packed_ch.protos[15] == 1,
		"from_msg accepts PackedInt32Array RLE buffers")


func _test_downsample() -> void:
	var c2 := LodData.LodChunk.new()
	c2.cx = 1
	c2.cy = 2
	c2.res = 2
	c2.rev = 11
	c2.tiles.resize(256)
	c2.protos.resize(256)
	c2.flags.resize(256)

	# Quadrant (0..7, 0..7) at res=2 mostly water (2), rest grass (1)
	for y in 16:
		for x in 16:
			var idx := y * 16 + x
			c2.tiles[idx] = 2 if (x < 8 and y < 8 and not (x == 0 and y == 0)) else 1

	# In top-left 2x2 subblock (0..1, 0..1):
	# - belt (proto 3, cat_hint 3, glow 0, density 12) at (0,0)
	# - tree (proto 2, cat_hint 2, glow 0, density 10) at (1,0)
	# - assembler (proto 1, cat_hint 1, glow 1, density 8) at (0,1)
	# - lamp (proto 5, cat_hint 1, glow 3, density 2) at (1,1)
	# Note: assembler and lamp both have building cat_hint=1, assembler has density 8 > lamp 2,
	# while max glow across subblock is 3 (from lamp)!
	c2.protos[0] = 3
	c2.flags[0] = 12 | (0 << 4) | (3 << 6)
	c2.protos[1] = 2
	c2.flags[1] = 10 | (0 << 4) | (2 << 6)
	c2.protos[16] = 1
	c2.flags[16] = 8 | (1 << 4) | (1 << 6)
	c2.protos[17] = 5
	c2.flags[17] = 2 | (3 << 4) | (1 << 6)

	_check(c2.downsample_to(2) == c2, "downsample_to same res returns self")
	_check(c2.downsample_to(1) == null, "downsample_to invalid res returns null")

	var c4 := c2.downsample_to(4)
	_check(c4 != null and c4.res == 4 and c4.tiles.size() == 64, "downsample 2->4")
	_check(c4.downsample_to(2) == null, "downsample to finer res returns null")
	if c4 != null:
		_check(c4.tiles[0] == 2, "downsample 2->4 dominant water tile preserved (3 water vs 1 grass)")
		_check(c4.protos[0] == 1, "downsample 2->4 highest-priority building with higher density wins (assembler)")
		var f0 := int(c4.flags[0])
		_check((f0 & 0x0F) == 8, "downsample 2->4 clamped avg density (32/4 = 8)")
		_check(((f0 >> 4) & 0x03) == 3, "downsample 2->4 max glow preserved (3)")
		_check(c4.protos[1] == 0 and c4.flags[1] == 0, "downsample 2->4 empty cell stays empty")

	var c8 := c4.downsample_to(8)
	_check(c8 != null and c8.res == 8 and c8.tiles.size() == 16, "downsample 4->8")
	var c16 := c8.downsample_to(16)
	_check(c16 != null and c16.res == 16 and c16.tiles.size() == 4, "downsample 8->16")
	var c32 := c16.downsample_to(32)
	_check(c32 != null and c32.res == 32 and c32.tiles.size() == 1, "downsample 16->32")
	if c32 != null:
		_check(c32.tiles[0] == 1, "downsample 16->32 dominant grass across whole chunk")
		_check(c32.protos[0] == 1, "downsample 16->32 building persists to res 32")
		_check((int(c32.flags[0]) & 0x0F) == 1, "downsample 16->32 non-zero entity density clamped >= 1")
		_check(((int(c32.flags[0]) >> 4) & 0x03) == 3, "downsample 16->32 max glow persists to res 32")

	# downsample_to with LodPalette resolves rail (prio 2) over belt (prio 1) even though both have cat_hint=3
	var db := _make_protos()
	var pal := LodData.LodPalette.build(db, {})
	var c_low := LodData.LodChunk.new()
	c_low.res = 16
	c_low.tiles = PackedInt32Array([1, 1, 1, 1])
	c_low.protos = PackedInt32Array([3, 8, 0, 0])  # belt (prio 1) high density, rail (prio 2) low density
	c_low.flags = PackedByteArray([12 | (3 << 6), 2 | (3 << 6), 0, 0])
	var c_low_32 := c_low.downsample_to(32, pal)
	_check(c_low_32 != null and c_low_32.protos[0] == 8, "downsample_to with palette prioritizes rail (prio 2) over belt (prio 1)")


func _test_bake_from_world_chunk() -> void:
	var db := _make_protos()
	_check(LodData.LodChunk.bake_from_world_chunk(0, 0, 1, PackedInt32Array(), {}, db, 2) == null,
		"bake_from_world_chunk handles empty tile_ids gracefully")
	_check(LodData.LodChunk.bake_from_world_chunk(0, 0, 1, PackedInt32Array([1, 2]), {}, db, 2) == null,
		"bake_from_world_chunk rejects short tile_ids")

	var tiles := PackedInt32Array()
	tiles.resize(1024)
	for y in 32:
		for x in 32:
			# Top-left 2x2 has 3 water (2) and 1 grass (1); bottom-right quadrant concrete (3)
			if x < 2 and y < 2 and not (x == 0 and y == 0):
				tiles[y * 32 + x] = 2
			elif x >= 16 and y >= 16:
				tiles[y * 32 + x] = 3
			else:
				tiles[y * 32 + x] = 1

	# Chunk (1, -1): world origin (32, -32)
	var ents := {
		101: FakeRec.new(1, Vector2(33.5, -30.5), 0),  # assembler 3x3 -> covers local (0..3, 0..3)
		102: FakeRec.new(3, Vector2(32.5, -31.5), 0),  # transport-belt in cell (0,0) under assembler
		103: FakeRec.new(5, Vector2(33.5, -31.5), 0),  # small-lamp in cell (0,0): glow 3
		104: FakeRec.new(2, Vector2(39.0, -25.0), 0),  # tree-01 in local (7,7) -> cell (3,3)
		105: FakeRec.new(4, Vector2(50.5, -10.5), 0),  # iron-ore in local (18.5, 21.5) -> cell (9,10)
		106: FakeRec.new(1, Vector2(40.0, -20.0), 0, {"gh": 1}),  # ghost: must be ignored
		107: FakeRec.new(1, Vector2(5.0, 5.0), 0),  # outside chunk: must be ignored
	}

	var baked := LodData.LodChunk.bake_from_world_chunk(1, -1, 7, tiles, ents, db, 2)
	_check(baked != null and baked.cx == 1 and baked.cy == -1 and baked.res == 2 and baked.rev == 7,
		"bake_from_world_chunk header")
	if baked != null:
		_check(baked.tiles[0] == 2, "bake dominant water in cell (0,0)")
		_check(baked.tiles[10 * 16 + 9] == 3, "bake concrete in bottom-right cell")
		# Cell (0,0): assembler (prio 5), lamp (prio 5), belt (prio 1)
		# Assembler overlaps 2x2 = 4.0 in cell (0,0), lamp overlaps 0.64 -> assembler wins, glow = 3!
		_check(baked.protos[0] == 1, "bake priority & overlap picks assembler in cell (0,0)")
		var f0 := int(baked.flags[0])
		_check((f0 & 0x0F) == 15, "bake cell (0,0) full coverage density 15 (got %d)" % (f0 & 0x0F))
		_check(((f0 >> 4) & 0x03) == 3, "bake cell (0,0) max glow 3 from lamp")
		_check(((f0 >> 6) & 0x03) == 1, "bake cell (0,0) cat_hint=1 for building")
		# Cell (3,3): tree-01
		var tree_idx := 3 * 16 + 3
		_check(baked.protos[tree_idx] == 2, "bake tree placed in cell (3,3)")
		_check(((int(baked.flags[tree_idx]) >> 6) & 0x03) == 2, "bake tree cat_hint=2")
		# Cell (9,10): iron-ore
		var ore_idx := 10 * 16 + 9
		_check(baked.protos[ore_idx] == 4, "bake iron-ore placed in cell (9,10)")
		_check((int(baked.flags[ore_idx]) & 0x0F) >= 1, "bake iron-ore density >= 1")
		_check(((int(baked.flags[ore_idx]) >> 6) & 0x03) == 3, "bake iron-ore cat_hint=3")
		# Ghost cell (4, 6) at local (8, 12) should be empty
		_check(baked.protos[6 * 16 + 4] == 0, "bake ignores entity ghosts")

	var baked4 := LodData.LodChunk.bake_from_world_chunk(1, -1, 7, tiles, ents, db, 4)
	_check(baked4 != null and baked4.res == 4 and baked4.tiles.size() == 64 and baked4.protos[0] == 1,
		"bake_from_world_chunk works directly at target_res=4")
	for extra_res: int in [8, 16, 32]:
		var br := LodData.LodChunk.bake_from_world_chunk(1, -1, 7, tiles, ents, db, extra_res)
		var exp_n := 32 / extra_res
		_check(br != null and br.tiles.size() == exp_n * exp_n and br.protos.size() == exp_n * exp_n,
			"bake_from_world_chunk works at target_res=%d" % extra_res)
	# Rotated rectangular entity (boiler-like 2x4 box rotated east dir=4 -> spans 4x2 instead of 2x4)
	var rdb := _make_protos()
	rdb.add_entities([[12, "boiler-rect", "boiler", -1.0, -2.0, 1.0, 2.0, 180, 120, 80, 2, 4]])
	var rect_ents := {1: FakeRec.new(12, Vector2(6.0, 4.0), 4)}
	var empty_tiles := PackedInt32Array()
	empty_tiles.resize(1024)
	empty_tiles.fill(1)
	var rbake := LodData.LodChunk.bake_from_world_chunk(0, 0, 1, empty_tiles, rect_ents, rdb, 2)
	_check(rbake != null and rbake.protos[2 * 16 + 2] == 12 and rbake.protos[2 * 16 + 3] == 12 and rbake.protos[0 * 16 + 2] == 0,
		"bake_from_world_chunk rotates rectangular selection box by dir=4")


func _test_palette() -> void:
	var db := _make_protos()
	var pal := LodData.LodPalette.build(db, {})
	_check(pal.proto_hash != 0, "palette proto_hash non-zero")
	_check(pal.tile_kind.size() == 6, "palette tile arrays sized by max tile id + 1")
	_check(pal.tile_kind[1] == 0, "grass-1 classified as land (0)")
	_check(pal.tile_kind[2] == 1, "water classified as water (1)")
	_check(pal.tile_kind[3] == 0, "concrete classified as land (0)")
	_check(pal.tile_kind[4] == 3, "lava-hot classified as lava (3)")
	_check(pal.tile_kind[5] == 2, "empty-space classified as void (2)")
	_check(_approx(pal.tile_rough[3], TerrainTextures.surface_of("concrete").x, 0.001),
		"concrete tile roughness matches TerrainTextures.surface_of")
	_check(_approx(pal.tile_rough[1], TerrainTextures.surface_of("grass-1").x, 0.001),
		"grass tile roughness matches TerrainTextures.surface_of")
	# Fallback tile color: calibrated linear scale 0.78
	var exp_grass := db.tile_color(1).srgb_to_linear()
	var scale := 0.78
	_check(_approx(pal.tile_colors[1].r, exp_grass.r * scale, 0.01) and _approx(pal.tile_colors[1].g, exp_grass.g * scale, 0.01),
		"fallback tile color matches calibrated 0.78 linear scale")
	# Lava emissive orange-red
	_check(pal.tile_colors[4].r > 0.9 and pal.tile_colors[4].g > 0.15 and pal.tile_colors[4].g < 0.5 and pal.tile_colors[4].b < 0.15,
		"lava tile color is bright orange-red emissive")

	# Entity classification, priority, glow
	_check(pal.ent_cat[1] == LodData.CAT_BUILDING and pal.ent_prio[1] == 5 and pal.ent_glow[1] == 0,
		"assembling-machine: building, prio 5, glow 0")
	_check(pal.ent_cat[2] == LodData.CAT_TREE and pal.ent_prio[2] == 3 and pal.ent_glow[2] == 0,
		"tree: tree, prio 3, glow 0")
	_check(pal.ent_cat[3] == LodData.CAT_LOW and pal.ent_prio[3] == 1 and pal.ent_glow[3] == 0,
		"transport-belt: low, prio 1, glow 0")
	_check(pal.ent_cat[4] == LodData.CAT_ORE and pal.ent_prio[4] == 1 and pal.ent_glow[4] == 0,
		"iron-ore: ore, prio 1, glow 0")
	_check(pal.ent_cat[5] == LodData.CAT_BUILDING and pal.ent_prio[5] == 5 and pal.ent_glow[5] == 3,
		"small-lamp: building, prio 5, glow 3")
	_check(pal.ent_cat[6] == LodData.CAT_BUILDING and pal.ent_glow[6] == 1,
		"stone-furnace: glow 1")
	_check(pal.ent_cat[7] == LodData.CAT_CLIFF and pal.ent_prio[7] == 4,
		"cliff: cliff, prio 4")
	_check(pal.ent_cat[8] == LodData.CAT_LOW and pal.ent_prio[8] == 2,
		"straight-rail: low, prio 2")
	_check(pal.ent_glow[9] == 0 and pal.ent_glow[10] == 0 and pal.ent_glow[11] == 2,
		"laser-turret=0, chemical-plant=0, nuclear-reactor=2")
	_check(pal.ent_heights[1] > 1.5 and pal.ent_heights[3] < 0.3,
		"fallback heights sensible from Visuals.height_for")

	# Bake override test (upper-half top color, lower-half side color, real height, metallic)
	var bake := FarChunks.Bake.new()
	bake.verts = PackedVector3Array([
		Vector3(0.0, 0.2, 0.0),
		Vector3(0.0, 3.2, 0.0),
	])
	# FarChunks.Bake stores sqrt(linear) RGB and (pc + 16*metal)/255 in alpha.
	# Lower vertex: linear (0.04, 0.09, 0.16) -> sqrt (0.2, 0.3, 0.4), metal=0/15
	# Upper vertex: linear (0.64, 0.25, 0.01) -> sqrt (0.8, 0.5, 0.1), metal=15/15 -> packed = 240/255
	bake.colors = PackedColorArray([
		Color(0.2, 0.3, 0.4, 0.0),
		Color(0.8, 0.5, 0.1, 240.0 / 255.0),
	])
	bake.done = true
	var pal_baked := LodData.LodPalette.build(db, {"assembling-machine-1": bake})
	_check(_approx(pal_baked.ent_heights[1], 3.0, 0.01), "baked real height max_y - min_y = 3.0")
	_check(_approx(pal_baked.ent_top_colors[1].r, 0.64, 0.01) and _approx(pal_baked.ent_top_colors[1].g, 0.25, 0.01),
		"baked top color from upper-half vertices")
	_check(_approx(pal_baked.ent_side_colors[1].r, 0.04, 0.01) and _approx(pal_baked.ent_side_colors[1].b, 0.16, 0.01),
		"baked side color from lower-half vertices")
	_check(_approx(pal_baked.ent_metal[1], 0.5, 0.02), "baked mean metallic = 0.5")

	# Mesh-keyed bake lookup via ModelLibrary._cache (as FarChunks._bakes)
	var dummy_mesh := BoxMesh.new()
	var prev_cache_val: Variant = ModelLibrary._cache.get("stone-furnace")
	var had_cache := ModelLibrary._cache.has("stone-furnace")
	ModelLibrary._cache["stone-furnace"] = dummy_mesh
	var furnace_bake := FarChunks.Bake.new()
	furnace_bake.verts = PackedVector3Array([Vector3(0, 0, 0), Vector3(0, 2.0, 0)])
	furnace_bake.colors = PackedColorArray([Color(0.3, 0.3, 0.3, 0.0), Color(0.9, 0.4, 0.2, 0.0)])
	var pal_mesh_bake := LodData.LodPalette.build(db, {dummy_mesh: furnace_bake})
	if had_cache:
		ModelLibrary._cache["stone-furnace"] = prev_cache_val
	else:
		ModelLibrary._cache.erase("stone-furnace")
	_check(_approx(pal_mesh_bake.ent_heights[6], 2.0, 0.01) and _approx(pal_mesh_bake.ent_top_colors[6].r, 0.81, 0.01),
		"Mesh-keyed FarChunks._bakes resolved via ModelLibrary._cache")

	# TerrainTextures loaded image (both RGBA8 and S3TC compressed mipmaps)
	var prev_gfx: Variant = TerrainTextures._gfx.get("grass-1")
	var had_gfx := TerrainTextures._gfx.has("grass-1")
	var prev_imgs_sz := TerrainTextures._images.size()
	var test_img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	test_img.fill(Color(0.5, 0.8, 0.2, 1.0))
	test_img.generate_mipmaps()
	test_img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB)
	var tgfx := TerrainTextures.TileGfx.new()
	tgfx.name = "grass-1"
	tgfx.layer = prev_imgs_sz
	TerrainTextures._images.append(test_img)
	TerrainTextures._gfx["grass-1"] = tgfx
	var pal_tex := LodData.LodPalette.build(db, {})
	TerrainTextures._images.resize(prev_imgs_sz)
	if had_gfx:
		TerrainTextures._gfx["grass-1"] = prev_gfx
	else:
		TerrainTextures._gfx.erase("grass-1")
	var exp_tex := Color(0.5, 0.8, 0.2, 1.0).srgb_to_linear()
	_check(_approx(pal_tex.tile_colors[1].r, exp_tex.r * 0.80, 0.04) and _approx(pal_tex.tile_colors[1].g, exp_tex.g * 0.80, 0.04),
		"TerrainTextures S3TC mipmap color scaled by 0.80 land gain into tile_colors")

	# Realistic palette calibration, fish skip, signal demotion, fallback sanitizer & FactorioShader guard
	var cdb := _make_protos()
	cdb.add_entities([
		[20, "fish", "fish", -0.5, -0.5, 0.5, 0.5, 0, 97, 145, 1, 1],
		[21, "rail-signal", "rail-signal", -0.5, -0.5, 0.5, 0.5, 0, 97, 145, 1, 1],
		[22, "rail-chain-signal", "rail-chain-signal", -0.5, -0.5, 0.5, 0.5, 0, 97, 145, 1, 1],
		[23, "biter-spawner", "unit-spawner", -2.5, -2.5, 2.5, 2.5, 0, 97, 145, 5, 5],
		[24, "crude-oil", "resource", -1.5, -1.5, 1.5, 1.5, 199, 51, 196, 3, 3],
		[25, "stone-wall", "wall", -0.5, -0.5, 0.5, 0.5, 204, 217, 204, 1, 1],
		[26, "splitter", "splitter", -1.0, -0.5, 1.0, 0.5, 255, 209, 0, 2, 1],
		[27, "modded-blue-machine", "modded-type", -1.0, -1.0, 1.0, 1.0, 0, 97, 145, 2, 2],
		[28, "modded-neon-entity", "modded-neon", -1.0, -1.0, 1.0, 1.0, 255, 0, 255, 2, 2],
		[29, "mod-white-part", "modded-shader", -1.0, -1.0, 1.0, 1.0, 110, 115, 120, 2, 2],
		[30, "small-electric-pole", "electric-pole", -0.5, -0.5, 0.5, 0.5, 220, 210, 180, 1, 1],
		[31, "big-electric-pole", "electric-pole", -1.0, -1.0, 1.0, 1.0, 220, 220, 220, 1, 1],
		[32, "substation", "electric-pole", -1.0, -1.0, 1.0, 1.0, 200, 210, 220, 1, 1],
	])
	var part_sh := Shader.new()
	part_sh.code = "shader_type spatial;\nuniform vec4 albedo = vec4(1.0);\nuniform float part_data = 0.0;\nvoid fragment() { ALBEDO = albedo.rgb; }\n"
	var part_mat := ShaderMaterial.new()
	part_mat.shader = part_sh
	part_mat.set_shader_parameter("albedo", Color.WHITE)
	part_mat.set_shader_parameter("part_data", 1.0)
	var part_mesh := BoxMesh.new()
	part_mesh.surface_set_material(0, part_mat)
	ModelLibrary._cache["mod-white-part"] = part_mesh
	var bright_pole_bake := FarChunks.Bake.new()
	bright_pole_bake.verts = PackedVector3Array([Vector3(0, 0, 0), Vector3(0, 5.0, 0)])
	bright_pole_bake.colors = PackedColorArray([Color(0.95, 0.95, 0.95, 0.0), Color(0.95, 0.95, 0.95, 0.0)])
	var cpal := LodData.LodPalette.build(cdb, {"small-electric-pole": bright_pole_bake})
	ModelLibrary._cache.erase("mod-white-part")

	_check(cpal.ent_cat[20] == LodData.CAT_NONE, "fish classified CAT_NONE (skipped)")
	_check(cpal.ent_cat[21] == LodData.CAT_LOW and cpal.ent_prio[21] == 1 and cpal.ent_prio[21] < cpal.ent_prio[8] and cpal.ent_glow[21] == 0,
		"rail-signal demoted below rail with glow=0")
	_check(cpal.ent_cat[22] == LodData.CAT_LOW and cpal.ent_prio[22] == 1 and cpal.ent_glow[22] == 0,
		"rail-chain-signal demoted to CAT_LOW prio=1 glow=0")
	_check(cpal.ent_top_colors[21].b < 0.25 and absf(cpal.ent_top_colors[21].r - cpal.ent_top_colors[21].b) < 0.03,
		"rail-signal uses dark iron albedo (not electric blue)")
	_check(cpal.ent_top_colors[23].r > cpal.ent_top_colors[23].b and cpal.ent_top_colors[23].r < 0.25,
		"biter-spawner uses warm dark reddish-brown albedo (not friendly blue)")
	_check(cpal.ent_top_colors[24].r < 0.05 and cpal.ent_top_colors[24].b < 0.05,
		"crude-oil uses dark oil slick albedo (not neon pink)")
	var wall_lin := cpal.ent_top_colors[25]
	var wall_lum := 0.2126 * wall_lin.r + 0.7152 * wall_lin.g + 0.0722 * wall_lin.b
	_check(wall_lum < 0.25, "stone-wall uses muted stone grey (lin lum < 0.25, not white)")
	_check(cpal.ent_top_colors[3].g < 0.20 and cpal.ent_top_colors[26].r < 0.25 and cpal.ent_top_colors[26].g < 0.20,
		"transport-belt and splitter use muted gunmetal-ochre (not bright yellow)")
	_check(absf(cpal.ent_top_colors[27].r - cpal.ent_top_colors[27].b) < 0.05 and cpal.ent_top_colors[27].b < 0.25,
		"default_friendly_color fallback sanitized to neutral steel")
	_check(cpal.ent_top_colors[28].r < 0.35 and cpal.ent_top_colors[28].g > 0.02,
		"neon magenta fallback desaturated and luminance-clamped")
	var white_lin := cpal.ent_top_colors[29]
	_check(white_lin.r < 0.40 and white_lin.g < 0.40 and white_lin.b < 0.40,
		"_sample_loaded_mesh skips ShaderMaterial with part_data=1.0 and white albedo")

	# Power pole classification, dark muted look, compact height (even with bright/tall bake), and low downsample priority
	_check(cpal.ent_cat[30] == LodData.CAT_POLE and cpal.ent_cat[31] == LodData.CAT_POLE and cpal.ent_cat[32] == LodData.CAT_POLE,
		"electric-poles classified as CAT_POLE")
	_check(cpal.ent_prio[30] == 1 and cpal.ent_prio[30] < cpal.ent_prio[8] and cpal.ent_prio[30] < cpal.ent_prio[2],
		"CAT_POLE priority stays below rails, trees, and buildings")
	var pole_lin := cpal.ent_top_colors[30]
	var pole_lum := 0.2126 * pole_lin.r + 0.7152 * pole_lin.g + 0.0722 * pole_lin.b
	_check(pole_lum < 0.10 and cpal.ent_heights[30] <= 1.51 and cpal.ent_heights[31] <= 2.11 and cpal.ent_heights[32] <= 1.71,
		"CAT_POLE uses dark muted colors and compact post heights despite bright bake (lum=%.3f h30=%.2f h31=%.2f h32=%.2f)" % [pole_lum, cpal.ent_heights[30], cpal.ent_heights[31], cpal.ent_heights[32]])
	var pc := LodData.LodChunk.new()
	pc.cx = 0
	pc.cy = 0
	pc.res = 16
	pc.tiles = PackedInt32Array([1, 1, 1, 1])
	pc.protos = PackedInt32Array([30, 8, 30, 30])
	pc.flags = PackedByteArray([15 | (3 << 6), 3 | (3 << 6), 15 | (3 << 6), 15 | (3 << 6)])
	var pc_down := pc.downsample_to(32, cpal)
	_check(pc_down != null and pc_down.protos[0] == 8,
		"downsample_to with palette prioritizes straight-rail over denser CAT_POLE")

	# NatureLooks tree color differs from placeholder p.color when tree-01 is in nature_looks.json
	_check(not _approx(pal.ent_top_colors[2].r, db.entity(2).color.srgb_to_linear().r, 0.005)
			or pal.ent_side_colors[2].r < pal.ent_top_colors[2].r,
		"NatureLooks tree tint applied for tree-01")

	# proto_hash stability & invalidation
	var pal2 := LodData.LodPalette.build(db, {})
	_check(pal.proto_hash == pal2.proto_hash, "proto_hash stable across repeated builds")
	var db_mod := _make_protos()
	db_mod.add_tiles([[6, "vulcanus-ash", 80, 75, 70]])
	var pal_mod := LodData.LodPalette.build(db_mod, {})
	_check(pal_mod.proto_hash != pal.proto_hash, "proto_hash changes when tiles change")
	var prev_shade := Looks.packs_shade
	Looks.packs_shade = not prev_shade
	var pal_shade := LodData.LodPalette.build(db, {})
	Looks.packs_shade = prev_shade
	_check(pal_shade.proto_hash != pal.proto_hash, "proto_hash changes when pack shading changes")

	# Null protos_db safe fallback
	var pal_null := LodData.LodPalette.build(null, {})
	_check(pal_null.tile_colors.size() == 1 and pal_null.ent_cat.size() == 1,
		"LodPalette.build(null) returns safe fallback palette")


## A section whose last build held these ids, built with `pal`.
func _section(key: Vector3i, tiles: Array, protos: Array, pal: Object) -> DistantHorizon.SectionState:
	var st := DistantHorizon.SectionState.new()
	st.key = key
	st.has_data = true
	st.dirty = false
	st.grid_tiles = PackedInt32Array(tiles)
	st.grid_protos = PackedInt32Array(protos)
	st.grid_pal = pal
	return st


## Runs one palette refresh to its end (the worker's job polled as main.gd does each frame).
func _refresh(dh: DistantHorizon, db: Object, bakes: Dictionary) -> void:
	dh._pal_tex_gen = -99  # as if a ground texture came: a refresh is due
	dh.refresh_palette_if_needed(db, bakes, 10.0)
	var until := Time.get_ticks_msec() + 5000
	while dh._pal_task >= 0 and Time.get_ticks_msec() < until:
		OS.delay_msec(1)
		dh.refresh_palette_if_needed(db, bakes, 0.0)
	for _i in 50:
		dh._recheck_palette_sections(1000000)


## Run-spikes step 2: the palette built on a worker; a rebuild with the same colours dirties no
## section, a changed colour only the sections holding that id; --dh-palette=old dirties them all.
func _test_palette_refresh() -> void:
	var db := _make_protos()
	var p1 := LodData.LodPalette.build(db, {})
	var p2 := LodData.LodPalette.from_snapshot(LodData.LodPalette.snapshot(db, {}))
	var d0 := LodData.LodPalette.diff(p1, p2)
	_check(p1.proto_hash == p2.proto_hash and not bool(d0[2]) and (d0[0] as PackedInt32Array).is_empty()
		and (d0[1] as PackedInt32Array).is_empty(), "snapshot + from_snapshot equals build (same hash, no diff)")
	var bake := FarChunks.Bake.new()
	bake.verts = PackedVector3Array([Vector3(0.0, 0.2, 0.0), Vector3(0.0, 3.2, 0.0)])
	bake.colors = PackedColorArray([Color(0.2, 0.3, 0.4, 0.0), Color(0.8, 0.5, 0.1, 240.0 / 255.0)])
	bake.done = true
	var baked := {"assembling-machine-1": bake}
	var d1 := LodData.LodPalette.diff(p1, LodData.LodPalette.build(db, baked))
	_check(not bool(d1[2]) and (d1[1] as PackedInt32Array) == PackedInt32Array([1]) and (d1[0] as PackedInt32Array).is_empty(),
		"diff names only the entity whose bake came (%s)" % [d1])
	for i in 2:  # the cached snapshot (the refresh's), first filling its cache, then from it
		var pc := LodData.LodPalette.from_snapshot(LodData.LodPalette.snapshot(db, baked, true))
		var dc := LodData.LodPalette.diff(LodData.LodPalette.build(db, baked), pc)
		_check(not bool(dc[2]) and (dc[0] as PackedInt32Array).is_empty() and (dc[1] as PackedInt32Array).is_empty(),
			"the cached snapshot builds the same palette (pass %d: %s)" % [i, dc])

	var dh := DistantHorizon.new()
	dh.enabled = true
	dh.radius_chunks = 32
	dh.palette_old = false
	dh._palette = p1
	var k_asm := Vector3i(0, 0, 0)
	var k_belt := Vector3i(0, 1, 0)
	var k_new := Vector3i(0, 2, 0)
	dh._sections[k_asm] = _section(k_asm, [1, 1, 3], [0, 1, 3], p1)  # an assembler in it
	dh._sections[k_belt] = _section(k_belt, [1, 2], [0, 3, 4], p1)  # belts and ore only
	dh._sections[k_new] = _section(k_new, [1], [1], null)  # never built: checked conservatively
	dh._sections[k_new].grid_pal = null
	_refresh(dh, db, {})
	_check(dh._palette != p1 and dh._palette is LodData.LodPalette, "the worker's palette is swapped in")
	var dirty_n := 0
	for k in dh._sections:
		dirty_n += 1 if (dh._sections[k] as DistantHorizon.SectionState).dirty else 0
	_check(dirty_n == 0 and int(dh.palette_stats[1]) == 0, "a rebuild with unchanged colours dirties no section (%d dirty)" % dirty_n)

	var serial_belt := (dh._sections[k_belt] as DistantHorizon.SectionState).serial
	_refresh(dh, db, baked)
	var s_asm: DistantHorizon.SectionState = dh._sections[k_asm]
	var s_belt: DistantHorizon.SectionState = dh._sections[k_belt]
	var s_new: DistantHorizon.SectionState = dh._sections[k_new]
	_check(s_asm.dirty and not s_belt.dirty and s_belt.serial == serial_belt and s_new.dirty,
		"a changed colour dirties only the sections holding it (asm %s, belts %s, never built %s)" % [s_asm.dirty, s_belt.dirty, s_new.dirty])
	_check(int(dh.palette_stats[0]) == 2, "two palettes built on the worker (%d)" % int(dh.palette_stats[0]))

	# A section built with the new palette meanwhile isn't dirtied again.
	s_asm.dirty = false
	s_asm.grid_pal = dh._palette
	dh._pal_changed_ents = PackedInt32Array([1])
	dh._pal_recheck = [k_asm]
	dh._recheck_palette_sections(1000000)
	_check(not s_asm.dirty, "a section already built with the new colours is left alone")

	# --dh-palette=old: every section with data, on the main thread.
	var dh_old := DistantHorizon.new()
	dh_old.apply_cli_overrides(PackedStringArray(["--dh-palette=old"]))
	_check(dh_old.palette_old, "--dh-palette=old parses")
	dh_old.enabled = true
	dh_old.radius_chunks = 32
	dh_old._palette = p1
	dh_old._sections[k_asm] = _section(k_asm, [1], [1], p1)
	dh_old._sections[k_belt] = _section(k_belt, [1], [3], p1)
	_refresh(dh_old, db, {})
	_check(dh_old._pal_task < 0 and (dh_old._sections[k_asm] as DistantHorizon.SectionState).dirty
		and (dh_old._sections[k_belt] as DistantHorizon.SectionState).dirty, "--dh-palette=old dirties every section, no worker")
	dh.free()
	dh_old.free()


func _test_cache() -> void:
	_check(LodCache.region_of(0, 0) == Vector2i(0, 0), "region_of(0,0)")
	_check(LodCache.region_of(15, 15) == Vector2i(0, 0), "region_of(15,15)")
	_check(LodCache.region_of(16, 0) == Vector2i(1, 0), "region_of(16,0)")
	_check(LodCache.region_of(-1, -1) == Vector2i(-1, -1), "region_of(-1,-1)")
	_check(LodCache.region_of(-16, -16) == Vector2i(-1, -1), "region_of(-16,-16)")
	_check(LodCache.region_of(-17, -1) == Vector2i(-2, -1), "region_of(-17,-1)")

	var base := ProjectSettings.globalize_path("user://lod-test-cache")
	var cache := LodCache.new()
	cache.configure("../My Save!@#", 1, 777777, base)

	# Build sample chunks in region (0, 0) and (-1, 0)
	var c0 := LodData.LodChunk.from_msg({"cx": 0, "cy": 0, "res": 2, "rv": 5, "tl": [1, 256], "el": [1, 0x5F, 4, 0, 0, 252]})
	var c1 := LodData.LodChunk.from_msg({"cx": 1, "cy": 0, "res": 8, "rv": 5, "tl": [2, 16], "el": [0, 0, 16]})
	var cm := LodData.LodChunk.from_msg({"cx": -1, "cy": 0, "res": 4, "rv": 3, "tl": [1, 64], "el": [2, 0x85, 64]})

	cache.put_chunk(c0, 10)
	cache.put_chunk(c1, 10)
	cache.put_chunk(cm, 3)

	# Keep finer res at same/older rev; replace if finer or rev advances
	var c0_coarse := LodData.LodChunk.from_msg({"cx": 0, "cy": 0, "res": 8, "rv": 5, "tl": [2, 16], "el": [0, 0, 16]})
	cache.put_chunk(c0_coarse, 10)
	_check(cache.get_chunk(0, 0).res == 2, "put_chunk keeps finer res at same rev")

	var c1_finer := LodData.LodChunk.from_msg({"cx": 1, "cy": 0, "res": 4, "rv": 5, "tl": [2, 64], "el": [0, 0, 64]})
	cache.put_chunk(c1_finer, 10)
	_check(cache.get_chunk(1, 0).res == 4, "put_chunk replaces with finer res at same rev")

	var written := cache.flush_dirty()
	_check(written == 2, "flush_dirty writes 2 dirty regions (got %d)" % written)
	_check(cache.flush_dirty() == 0, "second flush_dirty writes 0")

	# Verify compressed zlod file exists inside sanitized dir
	var sdir := base.path_join("MySave").path_join("s1")
	_check(FileAccess.file_exists(sdir.path_join("r_0_0.zlod")), "sanitized save_id path created r_0_0.zlod")
	_check(FileAccess.file_exists(sdir.path_join("r_-1_0.zlod")), "negative region r_-1_0.zlod created")

	# Empty save_id falls back to "default"
	var cache_def := LodCache.new()
	cache_def.configure("...", 0, 111, base)
	cache_def.put_chunk(LodData.LodChunk.from_msg({"cx": 0, "cy": 0, "res": 32, "rv": 1, "tl": [1, 1], "el": [0, 0, 1]}), 1)
	cache_def.flush_dirty()
	_check(FileAccess.file_exists(base.path_join("default").path_join("s0").path_join("r_0_0.zlod")),
		"empty/punctuation save_id falls back to default")

	# Clear memory and reload from Zstd disk cache
	cache.clear_memory()
	var revs := cache.region_revs()
	_check(revs.size() == 2 and int(revs.get(Vector2i(0, 0), -1)) == 10 and int(revs.get(Vector2i(-1, 0), -1)) == 3,
		"region_revs returns persisted region revs")
	var reg0 := cache.load_region_sync(0, 0)
	_check(reg0.size() == 2 and reg0.has(Vector2i(0, 0)) and reg0.has(Vector2i(1, 0)),
		"load_region_sync restores both chunks in region (0,0)")
	var got_c0 := cache.get_chunk(0, 0)
	_check(got_c0 != null and got_c0.tiles == c0.tiles and got_c0.protos == c0.protos and got_c0.flags == c0.flags,
		"disk round-trip preserves tiles, protos, flags")

	# Advancing region_rev replaces even with coarser res
	cache.put_chunk(c0_coarse, 11)
	_check(cache.get_chunk(0, 0).res == 8, "put_chunk replaces when region_rev advances")

	# proto_hash mismatch rejection
	var cache_mismatch := LodCache.new()
	cache_mismatch.configure("../My Save!@#", 1, 888888, base)
	_check(cache_mismatch.region_revs().is_empty(), "region_revs ignores mismatched proto_hash")
	_check(cache_mismatch.load_region_sync(0, 0).is_empty(), "load_region_sync rejects mismatched proto_hash")
	_check(cache_mismatch.get_chunk(0, 0) == null, "get_chunk returns null on mismatched proto_hash")

	# invalidate_region removes file & memory and rejects stale region_rev < new_rev
	cache.invalidate_region(0, 0, 12)
	_check(cache.get_chunk(0, 0) == null, "invalidate_region clears memory")
	_check(not FileAccess.file_exists(sdir.path_join("r_0_0.zlod")), "invalidate_region removes stale .zlod")
	_check(not cache.region_revs().has(Vector2i(0, 0)), "region_revs excludes invalidated region")
	cache.put_chunk(c0, 11)
	_check(cache.get_chunk(0, 0) == null, "put_chunk ignores stale region_rev < invalidated rev")
	cache.put_chunk(c0, 12)
	_check(cache.get_chunk(0, 0) != null, "put_chunk accepts region_rev >= invalidated rev")

	# Corrupt / truncated .zlod safety checks
	var corrupt_cache := LodCache.new()
	corrupt_cache.configure("corrupt-test", 0, 424242, base)
	var cdir := base.path_join("corrupt-test").path_join("s0")
	DirAccess.make_dir_recursive_absolute(cdir)
	# 1. Empty 0-byte file
	var f_empty := FileAccess.open(cdir.path_join("r_0_0.zlod"), FileAccess.WRITE)
	f_empty.close()
	_check(corrupt_cache.load_region_sync(0, 0).is_empty(), "0-byte .zlod returns empty dict safely")
	# 2. Random garbage bytes
	var f_junk := FileAccess.open(cdir.path_join("r_1_0.zlod"), FileAccess.WRITE)
	f_junk.store_string("NOT_A_ZLOD_FILE_AT_ALL")
	f_junk.close()
	_check(corrupt_cache.load_region_sync(1, 0).is_empty(), "garbage .zlod returns empty dict safely")
	# 3. Valid Zstd wrapper around truncated/bad ZLOD payload
	var f_bad_zlod := FileAccess.open_compressed(cdir.path_join("r_2_0.zlod"), FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	f_bad_zlod.store_buffer(PackedByteArray([0x5A, 0x4C, 0x4F, 0x44, 1, 0, 2, 0, 0, 0]))
	f_bad_zlod.close()
	_check(corrupt_cache.load_region_sync(2, 0).is_empty(), "truncated ZLOD header returns empty dict safely")
	# 4. Truncated compressed stream (cut valid GCMP/zstd file to 22 bytes)
	corrupt_cache.put_chunk(LodData.LodChunk.from_msg({"cx": 48, "cy": 0, "res": 2, "rv": 1, "tl": [1, 256], "el": [1, 15, 128, 0, 0, 128]}), 1)
	corrupt_cache.flush_dirty()
	var full_raw := FileAccess.get_file_as_bytes(cdir.path_join("r_3_0.zlod"))
	var f_trunc := FileAccess.open(cdir.path_join("r_3_0.zlod"), FileAccess.WRITE)
	f_trunc.store_buffer(full_raw.slice(0, mini(22, full_raw.size() / 2)))
	f_trunc.close()
	corrupt_cache.clear_memory()
	_check(corrupt_cache.load_region_sync(3, 0).is_empty(), "truncated compressed stream returns empty dict safely")
	_check(corrupt_cache.region_revs().is_empty(), "region_revs skips all corrupt/truncated files")

	# prune_disk LRU eviction (oldest mtime first, never deletes directories)
	var prune_base := ProjectSettings.globalize_path("user://lod-prune-test")
	var pcache := LodCache.new()
	pcache.configure("save-a", 0, 555, prune_base)
	pcache.put_chunk(LodData.LodChunk.from_msg({"cx": 0, "cy": 0, "res": 2, "rv": 1, "tl": [1, 256], "el": [1, 15, 128, 2, 3, 128]}), 1)
	pcache.flush_dirty()
	var old_path := prune_base.path_join("save-a").path_join("s0").path_join("r_0_0.zlod")
	var old_sz := FileAccess.get_file_as_bytes(old_path).size()
	OS.delay_msec(1100)
	pcache.put_chunk(LodData.LodChunk.from_msg({"cx": 16, "cy": 0, "res": 2, "rv": 1, "tl": [1, 256], "el": [3, 10, 200, 0, 0, 56]}), 1)
	pcache.flush_dirty()
	var new_path := prune_base.path_join("save-a").path_join("s0").path_join("r_1_0.zlod")
	var new_sz := FileAccess.get_file_as_bytes(new_path).size()

	var freed := pcache.prune_disk(new_sz)
	_check(freed == old_sz, "prune_disk freed exact old region bytes (%d vs %d)" % [freed, old_sz])
	_check(not FileAccess.file_exists(old_path), "prune_disk deleted oldest .zlod")
	_check(FileAccess.file_exists(new_path), "prune_disk kept newest .zlod")
	_check(DirAccess.dir_exists_absolute(prune_base.path_join("save-a").path_join("s0")),
		"prune_disk never deletes directories")

	# Default region_rev=-1 (as from bake_world_chunk) honors chunk.rev ordering
	var bcache := LodCache.new()
	bcache.configure("bake-rev-test", 1, 9090, base)
	bcache.put_chunk(LodData.LodChunk.from_msg({"cx": 2, "cy": 2, "res": 4, "rv": 5, "tl": [1, 64], "el": [0, 0, 64]}))
	bcache.put_chunk(LodData.LodChunk.from_msg({"cx": 2, "cy": 2, "res": 2, "rv": 4, "tl": [2, 256], "el": [0, 0, 256]}))
	_check(bcache.get_chunk(2, 2).rev == 5 and bcache.get_chunk(2, 2).res == 4,
		"put_chunk(region_rev=-1) keeps newer chunk.rev over older finer chunk")
	bcache.put_chunk(LodData.LodChunk.from_msg({"cx": 2, "cy": 2, "res": 8, "rv": 6, "tl": [2, 16], "el": [0, 0, 16]}))
	_check(bcache.get_chunk(2, 2).rev == 6 and bcache.get_chunk(2, 2).res == 8,
		"put_chunk(region_rev=-1) replaces with newer chunk.rev")
	bcache.flush_dirty()
	var brevs := bcache.region_revs()
	_check(int(brevs.get(Vector2i(0, 0), -1)) == 0,
		"put_chunk(region_rev=-1) keeps persisted region rev at 0 without mixing chunk.rev")


func _test_async_cache_and_bake_cap() -> void:
	var async_was := LodCache.async_io
	var async_base := ProjectSettings.globalize_path("user://lod-async-io-test")
	var wc := LodCache.new()
	wc.configure("async-save", 1, 777, async_base)
	LodCache.async_io = true
	var c0 := LodData.LodChunk.from_msg({
		"cx": 2, "cy": 3, "res": 2, "rv": 9,
		"tl": [1, 256],
		"el": [2, 15, 100, 0, 0, 156],
	})
	wc.put_chunk(c0, 9)
	wc.flush_dirty_async()
	wc.wait_write()

	var rc := LodCache.new()
	rc.configure("async-save", 1, 777, async_base)
	var before_load: bool = not rc.is_region_loaded(0, 0)
	var immediate_miss: Variant = rc.get_chunk(2, 3)
	var ready_regs: Array[Vector2i] = []
	for _i in 100:
		var got_regs := rc.poll_reads()
		if not got_regs.is_empty():
			ready_regs.append_array(got_regs)
			break
		if rc.is_region_loaded(0, 0):
			break
		OS.delay_msec(10)
	var reloaded := rc.get_chunk(2, 3)
	_check(before_load and immediate_miss == null and rc.is_region_loaded(0, 0)
		and reloaded != null and reloaded.rev == 9 and reloaded.tiles == c0.tiles,
		"LodCache async_io loads region in WorkerThreadPool and populates via poll_reads() (%s, %s, %s)"
		% [before_load, immediate_miss == null, reloaded != null])

	LodCache.async_io = false
	var sc := LodCache.new()
	sc.configure("async-save", 1, 777, async_base)
	var sync_c := sc.get_chunk(2, 3)
	_check(sync_c != null and sync_c.rev == 9,
		"LodCache --dh-async-io=off fallback loads region synchronously on first get_chunk()")
	LodCache.async_io = async_was
	wc.wait_reads()
	rc.wait_reads()
	sc.wait_reads()

	# DistantHorizon BakeJob concurrency cap + queue drain.
	var db := _make_protos()
	var dh := DistantHorizon.new()
	dh.enabled = true
	dh.radius_chunks = 64
	dh.quality = "medium"
	root.add_child(dh)
	dh.configure("bake-cap-save", 1, null)
	dh.ensure_palette_and_cache(db, {})
	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 200.0, 0.0)
	root.add_child(cam)
	var tiles := PackedInt32Array()
	tiles.resize(1024)
	tiles.fill(0)
	var ents := {0: FakeRec.new(1, Vector2(4.0, 4.0), 0)}
	var max_jobs_seen := 0
	for i in 10:
		dh.bake_world_chunk(i, 0, 1, tiles, ents, db)
		max_jobs_seen = maxi(max_jobs_seen, dh._bake_jobs.size())
	var stats_mid := dh.stats()
	_check(dh._bake_jobs.size() <= DistantHorizon.MAX_BAKE_JOBS and max_jobs_seen <= DistantHorizon.MAX_BAKE_JOBS
		and dh._bake_queue.size() >= 10 - DistantHorizon.MAX_BAKE_JOBS
		and int(stats_mid.get("baking", 0)) == 10,
		"DistantHorizon caps concurrent BakeJobs at %d (jobs=%d, queued=%d, total=%d)"
		% [DistantHorizon.MAX_BAKE_JOBS, dh._bake_jobs.size(), dh._bake_queue.size(), int(stats_mid.get("baking", 0))])
	for _f in 120:
		dh.update(cam, Color.WHITE, 0.016, false)
		if dh._bake_jobs.is_empty() and dh._bake_queue.is_empty():
			break
		OS.delay_msec(10)
	var baked_all := true
	for i in 10:
		if not dh._mem_chunks.has(Vector2i(i, 0)):
			baked_all = false
	_check(dh._bake_jobs.is_empty() and dh._bake_queue.is_empty() and baked_all,
		"DistantHorizon drains queued BakeJobs across update() frames until all chunks baked (%s)" % baked_all)
	dh.finish_all()
	dh.free()
	cam.free()
	db.clear()
