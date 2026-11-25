extends RefCounted
## Factorio's own tile graphics on the ground, read at runtime from the player's install like the
## item icons and model sprites (nothing of Wube's is copied into this repo):
##
##   <data>/base/prototypes/tile/tiles.lua (and space-age's)   which picture, variant sizes,
##                                                             weights and layer each tile has
##   <data>/<mod>/graphics/terrain/*.png                       the pictures
##
## Each tile type that appears in a loaded chunk gets one layer of a Texture2DArray, repacked from
## Factorio's sheet into the same slot layout (64 px per tile, 32 x 16 slots):
##   rows 0-7   4x4 variants, 8 per row      (or material backgrounds: concrete, landfill...)
##   rows 8-9   2x2 variants, 16 per row
##   row 10     1x1 variants
## chunk_view.gd picks a variant for every tile the way Factorio does (bigger blocks where the
## whole aligned block is that tile and a roll passes, weighted variants) and puts its slot in the
## tile's UVs. Without an install, or for a tile whose graphics can't be read, layer() is -1 and
## the shaders keep the map colour with procedural detail.

const ItemIcons := preload("res://scripts/world/item_icons.gd")
const ModFiles := preload("res://scripts/world/mod_files.gd")
const ModGraphics := preload("res://scripts/world/mod_graphics.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const Switches := preload("res://scripts/switches.gd")

const PX := 64  # Factorio's high-resolution tiles: 64 px each (scale 0.5 of 128 px/tile)
const COLS := 32
const ROWS := 16
const MAX_LAYERS := 96  # the shaders' per-layer table
const CACHE_DIR := "user://tex-cache"
const CACHE_VERSION := 1
const CACHE_KEEP := 96
## A surface change drops every layer once this many are in use, so a session that visits every
## planet doesn't run out (each planet needs 15-55 kinds of ground) and leave the last one bare.
const TRIM_LAYERS := 40
## Factorio's ground pictures are on average about this much brighter than the tiles' map colours
## (Nauvis water 0.9x, grass 1.4x).
const MAP_TO_GROUND := 1.2
## Sky reflected by Factorio's "wetland-water" shaders' tiles, against water's 1.
const MURKY_REFLECT := 0.25
## Rows of the slot layout, by variant size.
const ROW_4 := 0
const ROW_2 := 8
const ROW_1 := 10
## Where each variant size starts in a tile_variations_template sheet (tiles.lua).
const TEMPLATE_Y := {1: 0, 2: 128, 4: 320}
## Draw order between layer groups (Factorio's: water, water-overlay, then ground): artificial
## floors go over natural ground whatever their layer, and Gleba's lowlands (water-overlay) under
## its midlands.
const GROUP_RANK := {"water": 0, "water-overlay": 1, "zero": 2, "ground-natural": 2, "ground-artificial": 3}
## Collision masks of tiles drawn as water (lowered, with the water shader and a shore): water,
## shallow water (Gleba's wetlands, Nauvis' mud) and Aquilo's ammoniacal ocean.
const WATER_MASKS := ["tile_collision_masks.water(", "tile_collision_masks.shallow_water(", "tile_collision_masks.ammoniacal_ocean("]
## The same without an install (the mock's tiles), besides any name with "water" in it.
const WATER_NAMES := ["ammoniacal-ocean", "ammoniacal-ocean-2", "gleba-deep-lake"]

## The ground's surface by tile family (owner: paving and ground glared pale with the sun low behind the
## scene): [name part, roughness, specular], the first part found in the tile's name wins; anything else
## is NATURAL_SURFACE. Ground is never metal. Specular stays low because Godot's Fresnel brings back most of
## the sun's highlight at grazing angles unless F0 (0.16 x specular^2) is tiny; roughness alone doesn't
## stop it. Water has its own shader. terrain_mesher.gd puts each tile's into CUSTOM1.w (surface_code),
## terrain.gdshader reads it; --ground-rough=off draws 0.2.2's (one value for natural ground, one for floors).
const SURFACES := [
	["refined-hazard-concrete", 0.88, 0.12], ["refined-concrete", 0.88, 0.12],
	["hazard-concrete", 0.9, 0.1], ["concrete", 0.9, 0.1],
	["stone-path", 0.92, 0.08], ["landfill", 0.95, 0.05],
	["space-platform-foundation", 0.85, 0.15], ["foundation", 0.9, 0.08], ["ice-platform", 0.85, 0.12],
	["ice-smooth", 0.8, 0.15], ["ice", 0.88, 0.1], ["artificial", 0.93, 0.06],
]
const NATURAL_SURFACE := Vector2(0.95, 0.05)  # grass, dirt, sand, desert, volcanic rock...
const NATURAL_CODE := 95.05  # surface_code(NATURAL_SURFACE)


## A tile's [roughness, specular] (SURFACES).
static func surface_of(tile_name: String) -> Vector2:
	for row in SURFACES:
		if tile_name.contains(row[0]):
			return Vector2(row[1], row[2])
	return NATURAL_SURFACE


## The surface as one float for a vertex: roughness in hundredths plus the specular (under 1); 0: none.
static func surface_code(surface: Vector2) -> float:
	return roundf(clampf(surface.x, 0.01, 1.0) * 100.0) + clampf(surface.y, 0.0, 0.99)


## How one tile type is drawn.
class TileGfx:
	var name := ""
	var name_hash := 0
	var layer := -1  # Texture2DArray layer, -1: no graphics, use the map colour
	## Factorio's draw order: higher tiles' edges spread over lower neighbours.
	var priority := 0
	## Natural ground spreads soft edges over lower neighbours; artificial floors stay crisp.
	var spills := false
	var water := false
	## Variant sizes, largest first: [size, probability, weights (cumulative), count].
	var sizes: Array = []
	## material_background tiles (concrete): variant size in tiles and how many there are.
	var material := Vector2i.ZERO
	var material_count := 0
	## Multiplies the picture: a copy of water with its own effect colour (the ammoniacal ocean).
	var tint := Color.WHITE
	## How much sky the water shader shows in it (1: water; murky swamps less).
	var reflect := 1.0
	## [roughness, specular] (SURFACES), as surface_code for the mesh.
	var surface: float = NATURAL_CODE

	## The slot (in tiles) of the variant tile (x, y) of the world shows, decided per aligned block
	## so the result is the same in every chunk rebuild and session. (lx, ly) is the tile in its
	## chunk and `uniform[size]` which of the chunk's aligned blocks are all one tile.
	func slot(x: int, y: int, lx: int, ly: int, uniform: Dictionary) -> Vector2i:
		if material_count > 0:
			var bx := floori(float(x) / material.x)
			var by := floori(float(y) / material.y)
			var v := posmod(hash(Vector3i(bx, by, 7001)), material_count)
			var per_row := COLS / material.x
			return Vector2i((v % per_row) * material.x + x - bx * material.x, (v / per_row) * material.y + y - by * material.y)
		for entry in sizes:
			var s: int = entry[0]
			var ox := floori(float(x) / s) * s
			var oy := floori(float(y) / s) * s
			if s > 1:
				var flags: PackedByteArray = uniform[s]
				if flags[(ly / s) * (32 / s) + lx / s] == 0 or _roll(ox, oy, s, 1) >= float(entry[1]):
					continue
			var v := _pick(entry[2], _roll(ox, oy, s, 2))
			var sub := Vector2i(x - ox, y - oy)
			match s:
				4:
					return Vector2i((v % 8) * 4, ROW_4 + (v / 8) * 4) + sub
				2:
					return Vector2i(v * 2, ROW_2) + sub
				_:
					return Vector2i(v, ROW_1)
		return Vector2i(0, ROW_1)

	func _roll(ox: int, oy: int, s: int, salt: int) -> float:
		return float(hash(Vector4i(ox, oy, s * 16 + salt, name_hash)) & 0xffffff) / 16777216.0

	static func _pick(cumulative: PackedFloat32Array, r: float) -> int:
		var total := cumulative[cumulative.size() - 1]
		for i in cumulative.size():
			if r * total < cumulative[i]:
				return i
		return cumulative.size() - 1

	## (first row, variant width, height, count) for the shaders, which sample this tile's
	## texture by world position where it spreads into a neighbour.
	func shader_info() -> Color:
		if material_count > 0:
			return Color(0, material.x, material.y, material_count)
		# The plain 1x1 variants: the big ones carry features (flowers, dry patches) that would
		# be cut off by the transition mask.
		for entry in sizes:
			if entry[0] == 1:
				return Color(ROW_1, 1, 1, entry[3])
		for entry in sizes:
			if entry[0] == 4:
				return Color(ROW_4, 4, 4, entry[3])
		return Color(ROW_1, 1, 1, 1)


static var _defs := {}  # tile name -> Lua block of its prototype, read once
static var _defs_read := false
static var _water := {}  # tile name -> true: its collision mask is water's (WATER_MASKS)
static var _layer_of := {}  # tile name -> its `layer`, worked out with the file's constants
static var _tint_of := {}  # tile name -> Color, for copies of a water tile with another map colour
static var _effects := {}  # tile-effect name -> its Lua block, for water shaders with a picture
static var _gfx := {}  # tile name -> TileGfx
static var _images: Array[Image] = []
static var _array: Texture2DArray
static var _infos := PackedColorArray()
static var _reflects := PackedFloat32Array()
static var _pbr_images: Array[Image] = []
static var _pbr_metas := PackedColorArray()  # parallel to _images: (pbr_layer or -1, flags, normal_strength, height_strength)
static var _pbr_array: Texture2DArray
static var _pbr_room := 0
static var _pbr_uploaded := 0
static var _dirty := false
## Whether the ground's pictures are compressed (S3TC/BC1): 1 yes, 0 no. Only an editor build can:
## in Godot 4.7.2 etcpak's compressors (BC1-3, ETC) are registered only with TOOLS_ENABLED, and CVTT
## (BPTC) and Betsy (on the GPU) only in templates built with cvtt_export_templates or
## betsy_export_templates, which the official ones aren't. Image.compress() has nothing to call in an
## exported game: it logged `Parameter "_image_compress_bc_func" is null` and failed, so the export
## is never asked. There each layer is kept as RGBA8, the format Godot's renderer turns RGB8 into on
## every upload anyway (texture_storage.cpp; 2.8 ms a layer on the main thread, and every layer again
## when the array grows): 11.2 MB a layer on the GPU with its mipmaps (2048 x 1024) against 1.4 MB
## compressed, and 11.2 MB in _images against 1.4. A base's 35-45 kinds of ground: about 0.5 GB of
## video memory and as much RAM, against 70 and 60 MB.
static var _compress := 1 if OS.has_feature("editor") else 0
## --plain-terrain keeps the procedural ground even with an install (for comparisons).
static var disabled := Switches.has("--plain-terrain")
static var disk_cache := Switches.on("--tex-cache")
static var cache_hits := 0
static var _data_stamp := ""
static var _cache_dir_made := false
static var _cache_mutex := Mutex.new()
static var _cache_writes := 0
## The array on the GPU is made with room for ARRAY_ROOM layers (grown ARRAY_STEP at a time when
## full), and a new kind of ground is written into its layer alone (update_layer): one picture's
## upload, 2-3 ms. Making the whole array again from every picture loaded, on each new kind of
## ground, was 56-114 ms on the main thread once 35-45 kinds were in (the 0.2.0 base's worst
## frames standing, a third of its slow frames on laps; client-cpu.md 1). The spare layers hold
## copies of the first picture and are never sampled. Uncompressed pictures (an exported game, see
## _compress) are 8 times the size, so then the room is only ARRAY_STEP_PLAIN past what is loaded.
## `--terrain-layers=rebuild` makes the whole array again on each new picture, as before.
const ARRAY_ROOM := 48
const ARRAY_STEP := 16
const ARRAY_STEP_PLAIN := 4
static var rebuild_layers := Switches.has("--terrain-layers=rebuild")
static var _room := 0  # layers the array on the GPU has (0: none made since the last trim)
static var _uploaded := 0  # of _images, how many are in it
## Arrays made and single layers written (for tests and probes).
static var arrays_made := 0
static var layers_written := 0


## Pictures being read on worker threads: tile name -> [task id, TileGfx, holder]. A TileGfx is
## only handed out once it is final, so terrain jobs on other threads never see one change.
static var _pending := {}
static var _loaded := {}  # unused legacy placeholder; per-task holders carry loaded images
static var _loaded_mutex := Mutex.new()
static var _abandoned_tasks: Array[int] = []
static var _packs_version := -1  # ModelPacks.tiles_version last synced
## Goes up whenever lookup() can answer more tiles than before.
static var generation := 0
## Goes up when tiles' layers change under meshes already built (a trim, or a graphics list that
## gives pictures to tiles drawn in map colours): world.gd's kept terrain meshes are then stale.
static var layout := 0
static var _list_generation := 0  # ModGraphics.generation last seen
## Set when a new list dropped tiles drawn in map colours: world.gd builds every chunk's ground
## again (and clears it), as those chunks aren't waiting for a picture.
static var relook := false
static var _changed := false
## A new array goes on the GPU from a worker thread (--terrain-upload-thread=on, the default): the
## renderer takes the upload on the calling thread, so making it from 20-40 layers (1.4 MB each,
## compressed, with mipmaps) on the main thread was a 90-100 ms frame once a join at -62,-26. (Since
## the array has room (ARRAY_ROOM), a new array is made only when it is full; a single new layer is
## still written on the main thread, update_layer.) A tile whose layer is in an array still being
## made stays unknown (lookup() null, _staged) until that array is in use, so no ground is built with
## a layer the bound array lacks. off: made on the main thread.
static var upload_thread := Switches.on("--terrain-upload-thread")
static var _upload: Array = []  # [task id, [Texture2DArray or null], infos, reflects, layers] while a worker makes the next array
static var _staged := {}  # tile name -> TileGfx: published, its layer in an array not yet in use


static func _sync_packs() -> void:
	if _packs_version < 0:
		ModelPacks.active()
		_packs_version = ModelPacks.tiles_version
		return
	if _packs_version == ModelPacks.tiles_version:
		return
	_packs_version = ModelPacks.tiles_version
	_reload_all()


static func _reload_all() -> void:
	if _gfx.is_empty() and _pending.is_empty() and _staged.is_empty() and _images.is_empty() and _array == null and _upload.is_empty():
		return
	if not _upload.is_empty():
		WorkerThreadPool.wait_for_task_completion(int(_upload[0]))
		_upload = []
	for entry: Array in _pending.values():
		_abandoned_tasks.append(int(entry[0]))
	_pending.clear()
	_staged.clear()
	_gfx.clear()
	_images.clear()
	_infos = PackedColorArray()
	_reflects = PackedFloat32Array()
	_pbr_images.clear()
	_pbr_metas = PackedColorArray()
	_pbr_array = null
	_pbr_room = 0
	_pbr_uploaded = 0
	_array = null
	_room = 0
	_uploaded = 0
	_dirty = false
	Visuals.set_terrain_param(&"textured", false)
	Visuals.set_terrain_param(&"has_tile_pbr", false)
	Visuals.water_material().set_shader_parameter("textured", false)
	_changed = true
	relook = true
	generation += 1
	layout += 1


## The graphics for a tile, or null while its picture is being read (on a worker thread: reading
## and compressing one takes 50-350 ms, which on the main thread was a hitch for every new kind
## of ground). Draw it in its map colour meanwhile and ask again after `generation` changes.
static func lookup(tile_name: String) -> TileGfx:
	_sync_packs()
	var g: TileGfx = _gfx.get(tile_name)
	if g != null or _pending.has(tile_name) or _staged.has(tile_name):
		return g
	g = TileGfx.new()
	g.name = tile_name
	g.name_hash = tile_name.hash()
	g.water = is_water_tile(tile_name)
	g.surface = surface_code(surface_of(tile_name))
	var block := ""
	if not disabled and ItemIcons.factorio_data_dir() != "":
		_read_defs()
		block = _defs.get(tile_name, "")
	var fp := ModGraphics.fingerprint
	var comp_req := _compress
	var rec := _record(tile_name)
	var pack_src := {}
	if not disabled:
		pack_src = ModelPacks.tile_source(tile_name, false)
		if pack_src.is_empty() and rec.is_empty() and block == "":
			pack_src = ModelPacks.tile_source(tile_name, true)
	var pack_files: Array = pack_src.get("files", [])
	var pack_maps: Dictionary = pack_src.get("maps", {})
	var spec: Dictionary = pack_src.get("spec", {})
	if not rec.is_empty():
		var group := str(rec.get("group", "ground-natural"))
		g.water = g.water or int(rec.get("water", 0)) == 1
		g.priority = int(GROUP_RANK.get(group, 2)) * 1000 + int(rec.get("layer", 0))
		g.spills = group in ["ground-natural", "zero", "water-overlay"]
	elif block != "":
		var group := _str(block, "layer_group", "water" if g.water else "ground-natural")
		g.priority = int(GROUP_RANK.get(group, 2)) * 1000 + int(_layer_of.get(tile_name, 0))
		g.spills = group in ["ground-natural", "zero", "water-overlay"]
	elif not pack_files.is_empty():
		if g.water:
			g.priority = 0
			g.spills = false
		elif surface_of(tile_name) != NATURAL_SURFACE:
			g.priority = int(GROUP_RANK["ground-artificial"]) * 1000
			g.spills = false
		else:
			g.priority = int(GROUP_RANK["ground-natural"]) * 1000
			g.spills = true
	if not pack_src.is_empty() and (spec.has("roughness") or spec.has("specular")):
		var base_surf := surface_of(tile_name)
		var r := float(spec.get("roughness", base_surf.x))
		var s := float(spec.get("specular", base_surf.y))
		g.surface = surface_code(Vector2(r, s))
	if not pack_files.is_empty():
		if _images.size() + _pending.size() >= MAX_LAYERS:
			push_warning("Terrain textures: no room for %s (%d kinds of ground in use)" % [tile_name, MAX_LAYERS])
			_gfx[tile_name] = g
			_changed = true
			return g
		var holder: Array = [null, null, 0, 1.0, 1.0]
		_pending[tile_name] = [WorkerThreadPool.add_task(_load_pack.bind(g, pack_files, block, spec, comp_req, holder, pack_maps)), g, holder]
		return null
	if not rec.is_empty():
		# The bridge's list (mod_graphics.gd): a mod's tile, read from the mod's own files.
		if _images.size() + _pending.size() >= MAX_LAYERS:
			push_warning("Terrain textures: no room for %s (%d kinds of ground in use)" % [tile_name, MAX_LAYERS])
			_gfx[tile_name] = g
			_changed = true
			return g
		var holder: Array = [null, null, 0, 1.0, 1.0]
		_pending[tile_name] = [WorkerThreadPool.add_task(_load_record.bind(g, rec, fp, comp_req, holder, pack_maps, spec)), g, holder]
		return null
	if block != "":
		g.tint = _tint_of.get(tile_name, Color.WHITE)
	if block == "" or _images.size() + _pending.size() >= MAX_LAYERS:
		if block != "":
			push_warning("Terrain textures: no room for %s (%d kinds of ground in use)" % [tile_name, MAX_LAYERS])
		_gfx[tile_name] = g
		_changed = true
		return g
	var holder: Array = [null, null, 0, 1.0, 1.0]
	_pending[tile_name] = [WorkerThreadPool.add_task(_load.bind(g, block, comp_req, holder, pack_maps, spec)), g, holder]
	return null


## Whether a tile is drawn as water: by its collision mask in Factorio's definitions, else by name.
static func is_water_tile(tile_name: String) -> bool:
	if "water" in tile_name or tile_name in WATER_NAMES:
		return true
	var rec := _record(tile_name)
	if not rec.is_empty():
		return int(rec.get("water", 0)) == 1
	if disabled or ItemIcons.factorio_data_dir() == "":
		return false
	_read_defs()
	return _water.has(tile_name)


## After a surface change, once the chunks drawn with them are gone: forgets every layer if many
## are in use, so the new surface's ground has room. Pictures still being read land in the new
## table. True if it dropped them. A surface seen before (`next_surface`, note()) whose ground
## fits beside the layers loaded keeps them: going in and out of a Factorissimo building (Nauvis'
## 39 kinds of ground with Space Exploration, the factory floor's 4) dropped and read them all
## again on every door, and its terrain meshes kept (world.gd) with them.
static func trim(next_surface := -1) -> bool:
	if _images.size() < TRIM_LAYERS:
		return false
	var seen: Dictionary = _seen_on.get(next_surface, {})
	if not seen.is_empty():
		var more := 0
		for tile_name in seen:
			if not _gfx.has(tile_name) and not _pending.has(tile_name):
				more += 1
		if _images.size() + _pending.size() + more <= MAX_LAYERS:
			return false
	if not _upload.is_empty():
		WorkerThreadPool.wait_for_task_completion(int(_upload[0]))  # an array of the old layers
		_upload = []
	_staged.clear()
	_gfx.clear()
	_images.clear()
	_infos = PackedColorArray()
	_reflects = PackedFloat32Array()
	_pbr_images.clear()
	_pbr_metas = PackedColorArray()
	_pbr_array = null
	_pbr_room = 0
	_pbr_uploaded = 0
	Visuals.set_terrain_param(&"has_tile_pbr", false)
	_room = 0  # the next commit makes a new array (a loading moment: the surface changed)
	_uploaded = 0
	_changed = true
	generation += 1
	layout += 1
	return true


## The kinds of ground each surface has shown: surface index -> {tile name: true}.
static var _seen_on := {}


## A chunk of `surface` has this kind of ground (world.gd, as chunks arrive).
static func note(surface: int, tile_name: String) -> void:
	var seen: Dictionary = _seen_on.get(surface, {})
	if seen.is_empty():
		_seen_on[surface] = seen
	seen[tile_name] = true


## Another game: no surface's ground is known.
static func forget_surfaces() -> void:
	_seen_on.clear()


## How many layers are in use (for tests).
static func layer_count() -> int:
	return _images.size()


## The graphics for a tile if lookup() has them ready, without starting anything.
static func peek(tile_name: String) -> TileGfx:
	return _gfx.get(tile_name)


## The bridge's record for a tile when it should be drawn from it: a tile the game's own Lua files
## don't define (a mod's), or one a mod has given pictures from outside the built-in mods. The
## built-in tiles keep the path tuned for them (copies of water, frozen floors). {} for none.
static func _record(tile_name: String) -> Dictionary:
	return {} if disabled else _mod_tile_record(tile_name)


static func _mod_tile_record(tile_name: String) -> Dictionary:
	var rec: Variant = ModGraphics.tiles.get(tile_name)
	if not rec is Dictionary:
		return {}
	var r := rec as Dictionary
	# Whether the game's own files define it decides which path draws it, so read them first:
	# is_water_tile() asks before lookup() has, and a built-in tile taken for a mod's got the list's
	# water flag (empty space round every platform drawn as water).
	if ItemIcons.factorio_data_dir() != "":
		_read_defs()
	if _defs.has(tile_name):
		var first := ""
		if r.get("mat") is Array:
			first = str(r.mat[0])
		elif r.get("main") is Array and not (r.main as Array).is_empty():
			first = str(r.main[0][0])
		if ModFiles.split(first)[0] in ModFiles.BUILT_IN:
			return {}
	return r


static func _def_cache_key(g: TileGfx, block: String, comp_req: int) -> String:
	return "%d|def|%s|%d|%s|%s|%s" % [CACHE_VERSION, g.name, comp_req, str(g.tint), _data_stamp, block]


static func _rec_cache_key(g: TileGfx, rec: Dictionary, fp: String, comp_req: int) -> String:
	return "%d|rec|%s|%d|%s|%s" % [CACHE_VERSION, g.name, comp_req, fp, JSON.stringify(rec)]


static func _pack_cache_key(g: TileGfx, files: Array, spec: Dictionary, comp_req: int) -> String:
	var fparts := PackedStringArray()
	for f: Variant in files:
		var p := str(f)
		fparts.append("%s:%d:%d" % [p, FileAccess.get_size(p), FileAccess.get_modified_time(p)])
	return "%d|pack|%s|%d|%s|%s" % [CACHE_VERSION, g.name, comp_req, JSON.stringify(spec), "|".join(fparts)]


static func _cache_path(tile_name: String, key_hash: String) -> String:
	return CACHE_DIR.path_join("terrain-%s-%s.bin" % [tile_name.validate_filename(), key_hash.substr(0, 16)])


static func _read_tile_cache(g: TileGfx, key: String, comp_req: int) -> Image:
	if not disk_cache or key == "":
		return null
	var key_hash := key.sha256_text()
	var path := _cache_path(g.name, key_hash)
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var raw: Variant = f.get_var(false)
	f.close()
	if not (raw is Dictionary):
		return null
	var d := raw as Dictionary
	if int(d.get("v", 0)) != CACHE_VERSION or str(d.get("k", "")) != key_hash:
		return null
	var w := int(d.get("w", 0))
	var h := int(d.get("h", 0))
	var fmt := int(d.get("fmt", -1))
	var raw_len := int(d.get("raw_len", 0))
	var raw_data: Variant = d.get("data")
	if w <= 0 or h <= 0 or fmt < 0 or raw_len <= 0 or not (raw_data is PackedByteArray):
		return null
	if (comp_req == 0 and fmt != Image.FORMAT_RGBA8) or (comp_req != 0 and fmt == Image.FORMAT_RGBA8):
		return null
	var packed: PackedByteArray = raw_data
	var bytes: PackedByteArray = packed.decompress(raw_len, FileAccess.COMPRESSION_FASTLZ) if int(d.get("comp", 0)) == 1 else packed
	if bytes.size() != raw_len:
		return null
	var img := Image.create_from_data(w, h, bool(d.get("mip", true)), fmt as Image.Format, bytes)
	if img == null or img.is_empty():
		return null
	var raw_sizes: Variant = d.get("sizes")
	var raw_mat: Variant = d.get("mat")
	g.sizes = raw_sizes if raw_sizes is Array else []
	g.material = raw_mat if raw_mat is Vector2i else Vector2i.ZERO
	g.material_count = int(d.get("mat_n", 0))
	g.reflect = float(d.get("ref", 1.0))
	_loaded_mutex.lock()
	cache_hits += 1
	_loaded_mutex.unlock()
	return img


static func _write_tile_cache(g: TileGfx, key: String, img: Image) -> void:
	if not disk_cache or key == "" or img == null or img.is_empty():
		return
	_cache_mutex.lock()
	if not _cache_dir_made:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
		_cache_dir_made = true
	_cache_mutex.unlock()
	var key_hash := key.sha256_text()
	var path := _cache_path(g.name, key_hash)
	var tmp := path + ".tmp." + str(OS.get_thread_caller_id())
	var raw := img.get_data()
	var comp := 0
	var payload := raw
	if img.get_format() == Image.FORMAT_RGBA8:
		var z := raw.compress(FileAccess.COMPRESSION_FASTLZ)
		if not z.is_empty() and z.size() < raw.size():
			payload = z
			comp = 1
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	var entry := {
		"v": CACHE_VERSION, "k": key_hash,
		"w": img.get_width(), "h": img.get_height(), "fmt": int(img.get_format()), "mip": img.has_mipmaps(),
		"comp": comp, "raw_len": raw.size(), "data": payload,
		"sizes": g.sizes, "mat": g.material, "mat_n": g.material_count, "ref": g.reflect,
	}
	f.store_var(entry, false)
	var ok := f.get_error() == OK
	f.close()
	var abs_tmp := ProjectSettings.globalize_path(tmp)
	var abs_path := ProjectSettings.globalize_path(path)
	if not ok or DirAccess.rename_absolute(abs_tmp, abs_path) != OK:
		if FileAccess.file_exists(tmp):
			DirAccess.remove_absolute(abs_tmp)
		return
	_cache_mutex.lock()
	_cache_writes += 1
	_cache_mutex.unlock()


static func _prune_tile_cache() -> void:
	_cache_mutex.lock()
	var writes := _cache_writes
	_cache_writes = 0
	_cache_mutex.unlock()
	if writes <= 0 or not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(CACHE_DIR)):
		return
	var files: Array = []
	for fname in DirAccess.get_files_at(CACHE_DIR):
		if fname.begins_with("terrain-") and fname.ends_with(".bin"):
			files.append([FileAccess.get_modified_time(CACHE_DIR.path_join(fname)), fname])
	if files.size() <= CACHE_KEEP:
		return
	files.sort()
	while files.size() > CACHE_KEEP:
		var oldest: String = str(files.pop_front()[1])
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CACHE_DIR.path_join(oldest)))


static func _load_record(g: TileGfx, rec: Dictionary, fp := "", comp_req := _compress, holder := [], maps := {}, spec := {}) -> void:
	var t0 := Time.get_ticks_msec()
	var from_cache := true
	var image := _read_tile_cache(g, _rec_cache_key(g, rec, fp, comp_req), comp_req)
	if image == null:
		from_cache = false
		image = _build_layer_from_record(g, rec)
		if image != null:
			var actual_comp := 0 if image.get_format() == Image.FORMAT_RGBA8 else 1
			_write_tile_cache(g, _rec_cache_key(g, rec, fp, actual_comp), image)
	if image != null and not maps.is_empty():
		_build_pbr_layer(g, maps, spec, holder)
	if not holder.is_empty():
		holder[0] = image
	if image != null:
		print_verbose("Terrain: %s from %s (layer %d, %d ms)" % [g.name, "disk cache" if from_cache else "its mod's graphics", g.priority, Time.get_ticks_msec() - t0])


static func _load_pack(g: TileGfx, files: Array, block: String, spec: Dictionary, comp_req := _compress, holder := [], maps := {}) -> void:
	var t0 := Time.get_ticks_msec()
	var from_cache := true
	var image := _read_tile_cache(g, _pack_cache_key(g, files, spec, comp_req), comp_req)
	if image == null:
		from_cache = false
		image = _build_layer_from_pack(g, files, block, spec)
		if image != null:
			var actual_comp := 0 if image.get_format() == Image.FORMAT_RGBA8 else 1
			_write_tile_cache(g, _pack_cache_key(g, files, spec, actual_comp), image)
	if image != null and not maps.is_empty():
		_build_pbr_layer(g, maps, spec, holder)
	if not holder.is_empty():
		holder[0] = image
	if image != null:
		print_verbose("Terrain: %s from %s (layer %d, %d ms)" % [g.name, "disk cache" if from_cache else "model pack", g.priority, Time.get_ticks_msec() - t0])


static func _load_pack_image(path: String) -> Image:
	var img: Image = null
	if path.begins_with("res://") and not FileAccess.file_exists(path):
		var tex := load(path) as Texture2D
		if tex != null:
			img = tex.get_image()
	else:
		img = Image.load_from_file(path)
	if img == null or img.is_empty():
		return null
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	return img


static func _pbr_cache_key(g: TileGfx, maps: Dictionary, spec: Dictionary) -> String:
	var parts := PackedStringArray()
	for kind: String in ["normal", "height", "roughness"]:
		var files: Variant = maps.get(kind)
		if files is Array:
			for f: Variant in files:
				var p := str(f)
				parts.append("%s:%s:%d:%d" % [kind, p, FileAccess.get_size(p), FileAccess.get_modified_time(p)])
	var sp := {
		"flip_x": bool(spec.get("normal_flip_x", false)),
		"flip_y": bool(spec.get("normal_flip_y", false)),
		"count": int(spec.get("count", 1)),
		"size": spec.get("size", []),
		"sizes": g.sizes,
		"mat": [g.material.x, g.material.y, g.material_count],
	}
	return "%d|pbr|%s|%s|%s" % [CACHE_VERSION, g.name, JSON.stringify(sp), "|".join(parts)]


static func _read_pbr_cache(tile_name: String, key: String) -> Array:
	if not disk_cache or key == "":
		return []
	var key_hash := key.sha256_text()
	var path := _cache_path(tile_name + "-pbr", key_hash)
	if not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var raw: Variant = f.get_var(false)
	f.close()
	if not (raw is Dictionary):
		return []
	var d := raw as Dictionary
	if int(d.get("v", 0)) != CACHE_VERSION or str(d.get("k", "")) != key_hash:
		return []
	var w := int(d.get("w", 0))
	var h := int(d.get("h", 0))
	var raw_len := int(d.get("raw_len", 0))
	var raw_data: Variant = d.get("data")
	if w <= 0 or h <= 0 or raw_len <= 0 or not (raw_data is PackedByteArray):
		return []
	var packed: PackedByteArray = raw_data
	var bytes: PackedByteArray = packed.decompress(raw_len, FileAccess.COMPRESSION_FASTLZ) if int(d.get("comp", 0)) == 1 else packed
	if bytes.size() != raw_len:
		return []
	var img := Image.create_from_data(w, h, bool(d.get("mip", true)), Image.FORMAT_RGBA8, bytes)
	if img == null or img.is_empty():
		return []
	return [img, int(d.get("pflags", 0))]


static func _write_pbr_cache(tile_name: String, key: String, img: Image, pflags: int) -> void:
	if not disk_cache or key == "" or img == null or img.is_empty():
		return
	_cache_mutex.lock()
	if not _cache_dir_made:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
		_cache_dir_made = true
	_cache_mutex.unlock()
	var key_hash := key.sha256_text()
	var path := _cache_path(tile_name + "-pbr", key_hash)
	var tmp := path + ".tmp." + str(OS.get_thread_caller_id())
	var raw := img.get_data()
	var comp := 0
	var payload := raw
	var z := raw.compress(FileAccess.COMPRESSION_FASTLZ)
	if not z.is_empty() and z.size() < raw.size():
		payload = z
		comp = 1
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	var entry := {
		"v": CACHE_VERSION, "k": key_hash, "pflags": pflags,
		"w": img.get_width(), "h": img.get_height(), "mip": img.has_mipmaps(),
		"comp": comp, "raw_len": raw.size(), "data": payload,
	}
	f.store_var(entry, false)
	var ok := f.get_error() == OK
	f.close()
	var abs_tmp := ProjectSettings.globalize_path(tmp)
	var abs_path := ProjectSettings.globalize_path(path)
	if not ok or DirAccess.rename_absolute(abs_tmp, abs_path) != OK:
		if FileAccess.file_exists(tmp):
			DirAccess.remove_absolute(abs_tmp)
		return
	_cache_mutex.lock()
	_cache_writes += 1
	_cache_mutex.unlock()


## Repacks optional -normal, -height, and -roughness maps into one linear 2048 x 1024 RGBA8
## companion layer aligned to g's slot layout (RG = XY normal, B = roughness, A = height).
static func _build_pbr_layer(g: TileGfx, maps: Dictionary, spec: Dictionary, holder: Array) -> void:
	if maps.is_empty() or holder.size() < 5:
		return
	var pbr_key := _pbr_cache_key(g, maps, spec)
	var cached := _read_pbr_cache(g.name, pbr_key)
	var norm_strength := clampf(float(spec.get("normal_strength", 1.0)), 0.0, 4.0)
	var height_strength := clampf(float(spec.get("height_strength", 1.0)), 0.0, 4.0)
	if cached.size() == 2:
		holder[1] = cached[0]
		holder[2] = cached[1]
		holder[3] = norm_strength
		holder[4] = height_strength
		return
	var n_img: Image = _repack_map_into_slots(g, maps.get("normal", []), spec, true) if maps.has("normal") else null
	var h_img: Image = _repack_map_into_slots(g, maps.get("height", []), spec, false) if maps.has("height") else null
	var r_img: Image = _repack_map_into_slots(g, maps.get("roughness", []), spec, false) if maps.has("roughness") else null
	var flags := (1 if n_img != null else 0) | (2 if h_img != null else 0) | (4 if r_img != null else 0)
	if flags == 0:
		return
	var lw := COLS * PX
	var lh := ROWS * PX
	var total := lw * lh * 4
	var out_bytes := PackedByteArray()
	out_bytes.resize(total)
	var n_bytes := n_img.get_data() if n_img != null else PackedByteArray()
	var h_bytes := h_img.get_data() if h_img != null else PackedByteArray()
	var r_bytes := r_img.get_data() if r_img != null else PackedByteArray()
	var flip_x := bool(spec.get("normal_flip_x", false))
	var flip_y := bool(spec.get("normal_flip_y", false))
	var has_n := not n_bytes.is_empty()
	var has_h := not h_bytes.is_empty()
	var has_r := not r_bytes.is_empty()
	var o := 0
	while o < total:
		if has_n:
			var nx := n_bytes[o]
			var ny := n_bytes[o + 1]
			out_bytes[o] = 255 - nx if flip_x else nx
			out_bytes[o + 1] = 255 - ny if flip_y else ny
		else:
			out_bytes[o] = 128
			out_bytes[o + 1] = 128
		out_bytes[o + 2] = r_bytes[o] if has_r else 255
		out_bytes[o + 3] = h_bytes[o] if has_h else 128
		o += 4
	var pbr := Image.create_from_data(lw, lh, false, Image.FORMAT_RGBA8, out_bytes)
	pbr.generate_mipmaps()
	_write_pbr_cache(g.name, pbr_key, pbr, flags)
	holder[1] = pbr
	holder[2] = flags
	holder[3] = norm_strength
	holder[4] = height_strength


static func _clamp_template_slot_borders(layer: Image, dst: Vector2i, sw: int, clamp_top: bool, clamp_bottom: bool, clamp_right: bool) -> void:
	if sw < 4:
		return
	if clamp_top:
		layer.blit_rect(layer, Rect2i(dst.x, dst.y + 1, sw, 1), Vector2i(dst.x, dst.y))
	if clamp_bottom:
		layer.blit_rect(layer, Rect2i(dst.x, dst.y + sw - 2, sw, 1), Vector2i(dst.x, dst.y + sw - 1))
	if clamp_right:
		layer.blit_rect(layer, Rect2i(dst.x + sw - 2, dst.y, 1, sw), Vector2i(dst.x + sw - 1, dst.y))


static func _repack_map_into_slots(g: TileGfx, files: Array, spec: Dictionary, is_normal: bool) -> Image:
	if files.is_empty():
		return null
	var images: Array[Image] = []
	for f: Variant in files:
		var im := _load_pack_image(str(f))
		if im != null:
			images.append(im)
	if images.is_empty():
		return null
	var layer := Image.create_empty(COLS * PX, ROWS * PX, false, Image.FORMAT_RGBA8)
	if not g.sizes.is_empty():
		if images.size() == 1 and _is_template_sheet(images[0]) and not spec.has("size") and not spec.has("count"):
			var sheet := images[0]
			sheet.convert(Image.FORMAT_RGB8)
			sheet.convert(Image.FORMAT_RGBA8)
			var any := false
			for entry: Array in g.sizes:
				var s := int(entry[0])
				var cnt := int(entry[3])
				var y: int = TEMPLATE_Y[s]
				cnt = mini(cnt, mini(16, sheet.get_width() / (s * PX)))
				if y + s * PX > sheet.get_height() or cnt <= 0:
					continue
				var sw := s * PX
				for v in cnt:
					var dst := _slot_px(s, v)
					layer.blit_rect(sheet, Rect2i(v * sw, y, sw, sw), dst)
					if is_normal:
						_clamp_template_slot_borders(layer, dst, sw, y > 0, s < 4, v == cnt - 1 and cnt * sw < sheet.get_width())
				any = true
			if not any:
				return null
			_fill_empty_slots(layer)
			return layer
		var im0: Image = images[0].duplicate()
		var wf := float(im0.get_width()) / float(PX)
		var hf := float(im0.get_height()) / float(PX)
		if wf > float(COLS) or hf > float(ROWS):
			var scale_down := minf(float(COLS) / wf, float(ROWS) / hf)
			wf *= scale_down
			hf *= scale_down
		var w := clampi(roundi(wf), 1, COLS)
		var h := clampi(roundi(hf), 1, ROWS)
		if spec.has("size"):
			var sz: Array = spec["size"]
			w = clampi(int(sz[0]), 1, COLS)
			h = clampi(int(sz[1]), 1, ROWS)
		var target_w := w * PX
		var target_h := h * PX
		if im0.get_width() != target_w or im0.get_height() != target_h:
			var interp := Image.INTERPOLATE_LANCZOS if (im0.get_width() > target_w or im0.get_height() > target_h) else Image.INTERPOLATE_BILINEAR
			im0.resize(target_w, target_h, interp)
		im0.convert(Image.FORMAT_RGB8)
		im0.convert(Image.FORMAT_RGBA8)
		layer.blit_rect(im0, Rect2i(0, 0, target_w, target_h), Vector2i.ZERO)
		_tile_fill_layer(layer, target_w, target_h)
		return layer
	if g.material_count > 0:
		var w := clampi(g.material.x, 1, COLS)
		var h := clampi(g.material.y, 1, ROWS)
		if images.size() == 1:
			var cnt := int(spec.get("count", 1))
			if cnt <= 1 and g.material_count > 1 and images[0].get_width() >= images[0].get_height() * g.material_count:
				cnt = g.material_count
			if cnt > 1:
				var strip := images[0]
				var sw := strip.get_width() / cnt
				var sh := strip.get_height()
				if sw > 0 and sh > 0:
					var sliced: Array[Image] = []
					for i in cnt:
						sliced.append(strip.get_region(Rect2i(i * sw, 0, sw, sh)))
					images = sliced
		var per_row := COLS / w
		var target_w := w * PX
		var target_h := h * PX
		for v in g.material_count:
			var im: Image = images[v % images.size()].duplicate()
			if im.get_width() != target_w or im.get_height() != target_h:
				var interp := Image.INTERPOLATE_LANCZOS if (im.get_width() > target_w or im.get_height() > target_h) else Image.INTERPOLATE_BILINEAR
				im.resize(target_w, target_h, interp)
			im.convert(Image.FORMAT_RGB8)
			im.convert(Image.FORMAT_RGBA8)
			layer.blit_rect(im, Rect2i(0, 0, target_w, target_h), Vector2i((v % per_row) * w, (v / per_row) * h) * PX)
		if g.material_count == 1:
			_tile_fill_layer(layer, target_w, target_h)
		else:
			_fill_empty_slots(layer)
		return layer
	return null


static func _build_layer_from_pack(g: TileGfx, files: Array, block: String, spec: Dictionary) -> Image:
	var images: Array[Image] = []
	for f: Variant in files:
		var im := _load_pack_image(str(f))
		if im != null:
			images.append(im)
	if images.is_empty():
		return null
	var layer := Image.create_empty(COLS * PX, ROWS * PX, false, Image.FORMAT_RGBA8)
	# Mode A: Factorio-style template sheet (1x1, 2x2, 4x4 rows).
	if images.size() == 1 and _is_template_sheet(images[0]) and not spec.has("size") and not spec.has("count"):
		var sheet: Image = images[0]
		var max_size := int(_num(block, "max_size", 4)) if block != "" else 4
		var default_probs := {4: 0.4, 2: 0.6, 1: 1.0}
		var any := false
		for s in [4, 2, 1]:
			if s > max_size:
				continue
			var opts: Array = _size_options(block, s) if block != "" else [float(default_probs[s]), PackedFloat32Array()]
			var weights: PackedFloat32Array = opts[1]
			var count := weights.size() if not weights.is_empty() else 16
			var y: int = TEMPLATE_Y[s]
			count = mini(count, mini(16, sheet.get_width() / (s * PX)))
			if y + s * PX > sheet.get_height() or count <= 0:
				continue
			for v in count:
				layer.blit_rect(sheet, Rect2i(v * s * PX, y, s * PX, s * PX), _slot_px(s, v))
			g.sizes.append([s, opts[0], _cumulative(weights, count), count])
			any = true
		if not any:
			return null
		_fill_empty_slots(layer)
		return _finish_layer(layer)
	# Mode B: Horizontal strip of `count` variants in one image.
	if images.size() == 1 and int(spec.get("count", 1)) > 1:
		var strip: Image = images[0]
		var cnt := int(spec["count"])
		var sw := strip.get_width() / cnt
		var sh := strip.get_height()
		if sw <= 0 or sh <= 0:
			return null
		var sliced: Array[Image] = []
		for i in cnt:
			sliced.append(strip.get_region(Rect2i(i * sw, 0, sw, sh)))
		images = sliced
	# Mode C: Seamless texture or multi-variant list packed into material_background slots.
	var w := 1
	var h := 1
	if spec.has("size"):
		var sz: Array = spec["size"]
		w = clampi(int(sz[0]), 1, COLS)
		h = clampi(int(sz[1]), 1, ROWS)
	else:
		var img0: Image = images[0]
		var wf := float(img0.get_width()) / float(PX)
		var hf := float(img0.get_height()) / float(PX)
		if wf > float(COLS) or hf > float(ROWS):
			var scale_down := minf(float(COLS) / wf, float(ROWS) / hf)
			wf *= scale_down
			hf *= scale_down
		w = clampi(roundi(wf), 1, COLS)
		h = clampi(roundi(hf), 1, ROWS)
		if images.size() > 1:
			while (COLS / w) * (ROWS / h) < images.size() and (w > 1 or h > 1):
				if w >= h and w > 1:
					w = maxi(1, w / 2)
				elif h > 1:
					h = maxi(1, h / 2)
	var per_row := COLS / w
	var max_slots := per_row * (ROWS / h)
	var count := mini(images.size(), max_slots)
	if count <= 0:
		return null
	var target_w := w * PX
	var target_h := h * PX
	for v in count:
		var im: Image = images[v].duplicate()
		if im.get_width() != target_w or im.get_height() != target_h:
			var interp := Image.INTERPOLATE_LANCZOS if (im.get_width() > target_w or im.get_height() > target_h) else Image.INTERPOLATE_BILINEAR
			im.resize(target_w, target_h, interp)
		# Keep alpha solid so _fill_empty_slots never mistakes a translucent pixel for an empty slot.
		im.convert(Image.FORMAT_RGB8)
		im.convert(Image.FORMAT_RGBA8)
		layer.blit_rect(im, Rect2i(0, 0, target_w, target_h), Vector2i((v % per_row) * w, (v / per_row) * h) * PX)
	g.material = Vector2i(w, h)
	g.material_count = count
	if count == 1:
		_tile_fill_layer(layer, target_w, target_h)
	else:
		_fill_empty_slots(layer)
	return _finish_layer(layer)


## Repeats a single `(0, 0, bw, bh)` seamless block across the whole layer so mipmaps and filtering
## wrap cleanly past the block's edges.
static func _tile_fill_layer(layer: Image, bw: int, bh: int) -> void:
	var lw := COLS * PX
	var lh := ROWS * PX
	for y in range(0, lh, bh):
		for x in range(0, lw, bw):
			if x == 0 and y == 0:
				continue
			layer.blit_rect(layer, Rect2i(0, 0, mini(bw, lw - x), mini(bh, lh - y)), Vector2i(x, y))


## One layer from the bridge's record (gfx_extract.lua's tile format), as _build_layer does from
## the Lua files. Pictures drawn at another scale than Factorio's usual 0.5 (64 px a tile) are
## resized to it.
static func _build_layer_from_record(g: TileGfx, rec: Dictionary) -> Image:
	var layer := Image.create_empty(COLS * PX, ROWS * PX, false, Image.FORMAT_RGBA8)
	if rec.get("fx") is String:
		var effect := _sheet(str(rec.fx))
		var mc := Color.BLACK
		if rec.get("map") is Array and (rec.map as Array).size() >= 3:
			mc = Color(float(rec.map[0]), float(rec.map[1]), float(rec.map[2]))
		if effect != null and _effect_into(g, layer, effect, mc):
			return _finish_layer(layer)
	var any := false
	if rec.get("mat") is Array and (rec.mat as Array).size() >= 2:
		var m: Array = rec.mat
		var sheet := _scaled(_sheet(str(m[0])), float(m[2]) if m.size() > 2 else 0.5)
		var count := int(m[1])
		if sheet == null or count <= 0:
			return null
		var w := sheet.get_width() / count / PX
		var h := sheet.get_height() / PX
		if w <= 0 or h <= 0 or w > COLS or h > ROWS:
			return null
		var per_row := COLS / w
		count = mini(count, per_row * (ROWS / h))
		for v in count:
			layer.blit_rect(sheet, Rect2i(v * w * PX, 0, w * PX, h * PX), Vector2i((v % per_row) * w, (v / per_row) * h) * PX)
		g.material = Vector2i(w, h)
		g.material_count = count
		any = true
	elif rec.get("main") is Array:
		var by_size := {}
		for e in rec.main:
			if e is Array and (e as Array).size() >= 8:
				var sz := int(e[2])
				if sz in [1, 2, 4] and not by_size.has(sz):
					by_size[sz] = e
		var sheets := {}
		for sz in [4, 2, 1]:
			if not by_size.has(sz):
				continue
			var e: Array = by_size[sz]
			var scale := float(e[8]) if e.size() > 8 else 1.0
			var key := "%s@%s" % [e[0], scale]
			if not sheets.has(key):
				sheets[key] = _scaled(_sheet(str(e[0])), scale)
			var sheet: Image = sheets[key]
			if sheet == null:
				continue
			var k := 2.0 * scale  # source pixels to ours
			var count := mini(16, int(e[1]))
			var x0 := roundi(float(e[3]) * k)
			var y0 := roundi(float(e[4]) * k)
			var line := maxi(1, int(e[5]))
			var placed := 0
			for v in count:
				var src := Vector2i(x0 + (v % line) * sz * PX, y0 + (v / line) * sz * PX)
				if src.x + sz * PX > sheet.get_width() or src.y + sz * PX > sheet.get_height():
					break
				layer.blit_rect(sheet, Rect2i(src, Vector2i(sz, sz) * PX), _slot_px(sz, v))
				placed += 1
			if placed > 0:
				var weights := PackedFloat32Array()
				if e[7] is Array:
					for wv in e[7]:
						weights.append(float(wv))
				g.sizes.append([sz, float(e[6]) if sz > 1 else 1.0, _cumulative(weights, placed), placed])
				any = true
	if not any:
		return null
	_fill_empty_slots(layer)
	return _finish_layer(layer)


## A sheet drawn at `scale` brought to Factorio's usual 0.5 (64 px a tile).
static func _scaled(sheet: Image, scale: float) -> Image:
	if sheet == null or is_equal_approx(scale, 0.5) or scale <= 0.0:
		return sheet
	var k := 2.0 * scale
	sheet.resize(maxi(1, roundi(sheet.get_width() * k)), maxi(1, roundi(sheet.get_height() * k)), Image.INTERPOLATE_BILINEAR)
	return sheet


static func _load(g: TileGfx, block: String, comp_req := _compress, holder := [], maps := {}, spec := {}) -> void:
	var t0 := Time.get_ticks_msec()
	var from_cache := true
	var image := _read_tile_cache(g, _def_cache_key(g, block, comp_req), comp_req)
	if image == null:
		from_cache = false
		image = _build_layer(g, block)
		if image != null:
			var actual_comp := 0 if image.get_format() == Image.FORMAT_RGBA8 else 1
			_write_tile_cache(g, _def_cache_key(g, block, actual_comp), image)
	if image != null and not maps.is_empty():
		_build_pbr_layer(g, maps, spec, holder)
	if not holder.is_empty():
		holder[0] = image
	if image != null:
		print_verbose("Terrain: %s from %s (layer %d, %d ms)" % [g.name, "disk cache" if from_cache else "Factorio's graphics", g.priority, Time.get_ticks_msec() - t0])


## Hands out the pictures read since the last call and puts them on the GPU. Main thread, once a
## frame. True when lookup() can answer more tiles than before.
static func poll() -> bool:
	_sync_packs()
	for i in range(_abandoned_tasks.size() - 1, -1, -1):
		if WorkerThreadPool.is_task_completed(_abandoned_tasks[i]):
			WorkerThreadPool.wait_for_task_completion(_abandoned_tasks[i])
			_abandoned_tasks.remove_at(i)
	if _list_generation != ModGraphics.generation:
		# A graphics list arrived: tiles drawn in their map colour so far may have pictures now.
		_list_generation = ModGraphics.generation
		for tile_name in _gfx.keys():
			if (_gfx[tile_name] as TileGfx).layer < 0:
				_gfx.erase(tile_name)
				_changed = true
				relook = true
				layout += 1
	for tile_name in _pending.keys():
		var entry: Array = _pending[tile_name]
		var task := int(entry[0])
		if not WorkerThreadPool.is_task_completed(task):
			continue
		_publish(tile_name, task, entry[2] as Array)
	commit()
	_prune_tile_cache()
	var changed := _changed
	_changed = false
	if changed:
		generation += 1
	return changed


## Waits for the pictures still being read (before quitting).
static func finish_all() -> void:
	for task in _abandoned_tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	_abandoned_tasks.clear()
	for tile_name in _pending.keys():
		var entry: Array = _pending[tile_name]
		_publish(tile_name, int(entry[0]), entry[2] as Array)
	commit(true)


static func _publish(tile_name: String, task: int, holder: Array) -> void:
	WorkerThreadPool.wait_for_task_completion(task)
	var g: TileGfx = _pending[tile_name][1]
	_pending.erase(tile_name)
	var image: Image = holder[0] if not holder.is_empty() else null
	if image == null:
		g.sizes = []
		g.material_count = 0
	else:
		g.layer = _images.size()
		_images.append(image)
		_infos.append(g.shader_info())
		_reflects.append(g.reflect)
		var pbr_img: Image = holder[1] if holder.size() >= 2 else null
		if pbr_img != null:
			var pbr_idx := _pbr_images.size()
			_pbr_images.append(pbr_img)
			var pflags := int(holder[2]) if holder.size() >= 3 else 0
			var ns := float(holder[3]) if holder.size() >= 4 else 1.0
			var hs := float(holder[4]) if holder.size() >= 5 else 1.0
			_pbr_metas.append(Color(float(pbr_idx), float(pflags), ns, hs))
		else:
			_pbr_metas.append(Color(-1.0, 0.0, 1.0, 1.0))
		_dirty = true
		if upload_thread:
			_staged[tile_name] = g  # known once the array with its layer is in use (commit)
			return
	_gfx[tile_name] = g
	_changed = true


## Puts newly loaded layers on the GPU: each into its own layer of the array in use (update_layer, here:
## one picture's upload, 2-3 ms), or, when that array is full (or none is made yet), a new array with
## room for more, made on a worker thread (upload_thread) and taken into use once it is done (`wait`:
## now, before quitting or in tests), else made here and now. A tile whose layer the array in use
## doesn't have yet stays staged (lookup() null) until it does.
static func commit(wait := false) -> void:
	while true:
		if not _upload.is_empty():
			if not (wait or WorkerThreadPool.is_task_completed(int(_upload[0]))):
				return
			WorkerThreadPool.wait_for_task_completion(int(_upload[0]))
			var holder: Array = _upload[1]
			if holder[0] != null:
				_take_array(holder[0], int(_upload[5]), int(_upload[4]))
				if holder.size() >= 2 and holder[1] != null:
					_take_pbr_array(holder[1], int(_upload[8]), int(_upload[7]))
				_apply(_upload[2], _upload[3], _upload[6])
			_release(int(_upload[4]))
			_upload = []
		if not _dirty or _images.is_empty():
			return
		_dirty = false
		# (Only while no array is being made: the worker reads the pictures it was given.)
		for i in range(_uploaded, _images.size()):
			if not _fit(i):
				_plain_all()  # (a picture that wouldn't compress after others did: rare)
				break
		var need_albedo := rebuild_layers or _room < _images.size() or _uploaded > _images.size()
		var need_pbr := not _pbr_images.is_empty() and (_pbr_array == null or rebuild_layers or _pbr_room < _pbr_images.size() or _pbr_uploaded > _pbr_images.size())
		if not need_albedo and not need_pbr:
			for i in range(_uploaded, _images.size()):
				_array.update_layer(_images[i], i)
				layers_written += 1
			_uploaded = _images.size()
			for i in range(_pbr_uploaded, _pbr_images.size()):
				_pbr_array.update_layer(_pbr_images[i], i)
			_pbr_uploaded = _pbr_images.size()
			_apply(_infos, _reflects, _pbr_metas)
			_release(_uploaded)
			return
		if not need_albedo and need_pbr:
			for i in range(_uploaded, _images.size()):
				_array.update_layer(_images[i], i)
				layers_written += 1
			_uploaded = _images.size()
			var pbr_layers := _pbr_layers_with_room()
			if not upload_thread:
				var parr := Texture2DArray.new()
				if _make_array(parr, pbr_layers):
					_take_pbr_array(parr, pbr_layers.size(), _pbr_images.size())
					_apply(_infos, _reflects, _pbr_metas)
				_release(_uploaded)
				return
			var holder: Array = [_array, Texture2DArray.new()]
			_upload = [WorkerThreadPool.add_task(_upload_task.bind(holder, [], pbr_layers), false, "terrain pbr layers"),
				holder, _infos.duplicate(), _reflects.duplicate(), _images.size(), _room,
				_pbr_metas.duplicate(), _pbr_images.size(), pbr_layers.size()]
			if not wait:
				return
			continue
		var layers := _layers_with_room()
		var pbr_layers: Array[Image] = []
		if need_pbr:
			pbr_layers = _pbr_layers_with_room()
		if not upload_thread:
			var arr := Texture2DArray.new()
			if _make_array(arr, layers):
				_take_array(arr, layers.size(), _images.size())
				if need_pbr:
					var parr := Texture2DArray.new()
					if _make_array(parr, pbr_layers):
						_take_pbr_array(parr, pbr_layers.size(), _pbr_images.size())
				elif _pbr_array != null:
					for i in range(_pbr_uploaded, _pbr_images.size()):
						_pbr_array.update_layer(_pbr_images[i], i)
					_pbr_uploaded = _pbr_images.size()
				_apply(_infos, _reflects, _pbr_metas)
			return
		var holder: Array = [Texture2DArray.new(), Texture2DArray.new() if need_pbr else null]
		if not need_pbr and _pbr_array != null:
			for i in range(_pbr_uploaded, _pbr_images.size()):
				_pbr_array.update_layer(_pbr_images[i], i)
			_pbr_uploaded = _pbr_images.size()
		_upload = [WorkerThreadPool.add_task(_upload_task.bind(holder, layers, pbr_layers), false, "terrain layers"),
			holder, _infos.duplicate(), _reflects.duplicate(), _images.size(), layers.size(),
			_pbr_metas.duplicate(), _pbr_images.size(), pbr_layers.size() if need_pbr else _pbr_room]
		if not wait:
			return


## The tiles whose layers the array in use has (below `layers`) are known from now on.
static func _release(layers: int) -> void:
	for tile_name in _staged.keys():
		if (_staged[tile_name] as TileGfx).layer < layers:
			_gfx[tile_name] = _staged[tile_name]
			_staged.erase(tile_name)
			_changed = true


## A worker's part: the array made from the layers it was given (null in `holder` if that failed).
static func _upload_task(holder: Array, images: Array, pbr_images: Array = []) -> void:
	if not images.is_empty():
		if not _make_array(holder[0], images):
			holder[0] = null
	if not pbr_images.is_empty() and holder.size() >= 2 and holder[1] != null:
		if not _make_array(holder[1], pbr_images):
			holder[1] = null


static func _make_array(arr: Texture2DArray, images: Array) -> bool:
	var err := arr.create_from_images(images)
	if err != OK:
		push_warning("Terrain textures: %s" % error_string(err))
		return false
	return true


## The array in use and the layers' table go to the ground's materials.
static func _apply(layer_infos: PackedColorArray, layer_reflects: PackedFloat32Array, pbr_metas := PackedColorArray()) -> void:
	# Vectors, not Colors: a Color array would be converted from sRGB on the way in.
	var infos := PackedVector4Array()
	infos.resize(MAX_LAYERS)
	for i in layer_infos.size():
		var c := layer_infos[i]
		infos[i] = Vector4(c.r, c.g, c.b, c.a)
	var pbrs := PackedVector4Array()
	pbrs.resize(MAX_LAYERS)
	pbrs.fill(Vector4(-1.0, 0.0, 1.0, 1.0))
	for i in mini(pbr_metas.size(), MAX_LAYERS):
		var c := pbr_metas[i]
		pbrs[i] = Vector4(c.r, c.g, c.b, c.a)
	# The coast's material has them too (Visuals.set_terrain_param); the water's own.
	Visuals.set_terrain_param(&"tiles", _array)
	Visuals.set_terrain_param(&"tile_info", infos)
	Visuals.set_terrain_param(&"textured", true)
	Visuals.set_terrain_param(&"tile_pbr", pbrs)
	var has_pbr := _pbr_array != null and not _pbr_images.is_empty()
	Visuals.set_terrain_param(&"has_tile_pbr", has_pbr)
	if has_pbr:
		Visuals.set_terrain_param(&"tiles_pbr", _pbr_array)
	var water := Visuals.water_material()
	water.set_shader_parameter("tiles", _array)
	water.set_shader_parameter("tile_info", infos)
	water.set_shader_parameter("textured", true)
	var reflects := layer_reflects.duplicate()
	reflects.resize(MAX_LAYERS)
	Visuals.water_material().set_shader_parameter("tile_reflect", reflects)


static func _pbr_layers_with_room() -> Array[Image]:
	var step := ARRAY_STEP_PLAIN
	var room := _pbr_images.size()
	if not rebuild_layers:
		room = _pbr_images.size() + step
		room = mini(room, MAX_LAYERS)
	var layers: Array[Image] = _pbr_images.duplicate()
	while layers.size() < room:
		layers.append(_pbr_images[0])
	return layers


static func _take_pbr_array(array: Texture2DArray, room: int, n: int) -> void:
	_pbr_array = array
	_pbr_room = room
	_pbr_uploaded = n


## Every picture loaded and room for more (copies of the first, never sampled): a new array's layers.
static func _layers_with_room() -> Array[Image]:
	var step := ARRAY_STEP if _images[0].is_compressed() else ARRAY_STEP_PLAIN
	var room := _images.size()
	if not rebuild_layers:
		room = ARRAY_ROOM if _images[0].is_compressed() else _images.size() + step
		while room < _images.size():
			room += step
		room = mini(room, MAX_LAYERS)
	var layers: Array[Image] = _images.duplicate()
	while layers.size() < room:
		layers.append(_images[0])
	return layers


## A new array in use: `room` layers, the first `n` of _images.
static func _take_array(array: Texture2DArray, room: int, n: int) -> void:
	if _array != array:
		arrays_made += 1
	_array = array
	_room = room
	_uploaded = n
	if arrays_made == 1 and _array == array and not OS.has_feature("editor"):
		print("Terrain textures: the ground's pictures are kept uncompressed (this build has no texture compressor): "
			+ "about 11 MB of video memory a kind of ground")


## Layer `i` in the first one's format, which every layer of the array shares. False if it can't be.
static func _fit(i: int) -> bool:
	var image: Image = _images[i]
	var format := _images[0].get_format()
	if image.get_format() == format:
		return true
	if _images[0].is_compressed():
		if not image.is_compressed():
			image.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB)
		return image.get_format() == format
	if image.is_compressed():
		image.decompress()
	image.convert(format)
	return image.get_format() == format


## Every layer uncompressed (the pictures read before one that wouldn't compress were), in a new
## array at the next commit.
static func _plain_all() -> void:
	push_warning("Terrain textures: a ground picture couldn't be compressed; all are kept uncompressed")
	_compress = 0
	for image in _images:
		if image.is_compressed():
			image.decompress()
		image.convert(Image.FORMAT_RGBA8)
	_room = 0


## Whether any of Factorio's tile pictures are in use (the shore is built differently then).
static func active() -> bool:
	return _array != null


## Fraction of a layer per slot, for UVs.
static func slot_uv() -> Vector2:
	return Vector2(1.0 / COLS, 1.0 / ROWS)


# --- reading Factorio's definitions -------------------------------------------------------------

static func _read_defs() -> void:
	if _defs_read:
		return
	_defs_read = true
	var data := ItemIcons.factorio_data_dir()
	if data != "":
		var info := data.path_join("base/info.json")
		var fi := FileAccess.open(info, FileAccess.READ)
		var info_sz := fi.get_length() if fi != null else 0
		if fi != null:
			fi.close()
		_data_stamp = "%s|%d|%d" % [info, info_sz, FileAccess.get_modified_time(info)]
	var files: Array[String] = [data.path_join("base/prototypes/tile/tiles.lua")]
	var sa := data.path_join("space-age/prototypes/tile")
	if DirAccess.dir_exists_absolute(sa):
		for f in DirAccess.get_files_at(sa):
			if f.ends_with(".lua"):
				files.append(sa.path_join(f))
	var re := RegEx.create_from_string("(?m)^\\s*name\\s*=\\s*\"([^\"]+)\"")
	# `gleba_tile_offset = 32` at the top of a file, used as `layer = gleba_tile_offset + 8`.
	var const_re := RegEx.create_from_string("(?m)^\\s*(?:local\\s+)?([A-Za-z_]\\w*)\\s*=\\s*(-?\\d+)\\s*$")
	var layer_re := RegEx.create_from_string("\\blayer\\s*=\\s*([\\w\\s+\\-]+?)\\s*(?:,|\\n)")
	# `local x = table.deepcopy(data.raw.tile["water"])`, then `x.name = "ammoniacal-ocean"`.
	var copy_re := RegEx.create_from_string("local\\s+(\\w+)\\s*=\\s*table\\.deepcopy\\(\\s*data\\.raw\\.tile\\[\"([^\"]+)\"\\]\\s*\\)")
	# A tile-effect names its shader right after its name; its block may run on into script that
	# mentions variants.
	var effect_re := RegEx.create_from_string("^\\s*name\\s*=\\s*\"[^\"]+\"\\s*,\\s*shader\\s*=")
	var copies: Array = []
	var frozen: Array[String] = []
	for path in files:
		var text := FileAccess.get_file_as_string(path)
		var consts := {}
		for m in const_re.search_all(text):
			consts[m.get_string(1)] = int(m.get_string(2))
		var found := re.search_all(text)
		for i in found.size():
			var end := found[i + 1].get_start() if i + 1 < found.size() else text.length()
			var block := text.substr(found[i].get_start(), end - found[i].get_start())
			var tile_name := found[i].get_string(1)
			if effect_re.search(block) != null:
				if not _effects.has(tile_name) and "image_textures" in block:
					_effects[tile_name] = block
			elif not _defs.has(tile_name) and "variants" in block:
				_defs[tile_name] = block
				var lm := layer_re.search(block)
				if lm != null:
					_layer_of[tile_name] = _sum(lm.get_string(1), consts)
				for mask in WATER_MASKS:
					if mask in block:
						_water[tile_name] = true
		for m in copy_re.search_all(text):
			var v := m.get_string(1)
			var nm := RegEx.create_from_string("\\b%s\\.name\\s*=\\s*\"([^\"]+)\"" % v).search(text)
			if nm != null:
				var ec := RegEx.create_from_string("\\b%s\\.map_color\\s*=\\s*\\{([^}]*)\\}" % v).search(text)
				copies.append([nm.get_string(1), m.get_string(2), ec.get_string(1) if ec != null else ""])
		# Aquilo's floors are made by `frozen_concrete("concrete", ...)`: the floor one layer up,
		# with its frozen picture (8 material variants).
		for m in RegEx.create_from_string("(?m)^frozen_concrete\\(\\s*\"([^\"]+)\"").search_all(text):
			var floor_name := m.get_string(1)
			frozen.append(floor_name)
	for floor_name: String in frozen:
		var base: String = _defs.get(floor_name, "")
		var frozen_name := "frozen-" + floor_name
		if base == "" or _defs.has(frozen_name):
			continue
		_defs[frozen_name] = 'name = "%s", layer_group = "%s", variants = material_background("__space-age__/graphics/terrain/aquilo/%s.png", 8)' % [
			frozen_name, _str(base, "layer_group", "ground-artificial"), frozen_name]
		_layer_of[frozen_name] = int(_layer_of.get(floor_name, 0)) + 1
	# A copy draws with its original's pictures. Factorio's water shader colours it by its own
	# effect colour; the map colour says how that looks, so the picture is shifted by the ratio of
	# the two map colours (the ammoniacal ocean is a dark indigo copy of water).
	for c in copies:
		var src: String = c[1]
		if _defs.has(c[0]) or not _defs.has(src):
			continue
		_defs[c[0]] = _defs[src]
		_layer_of[c[0]] = _layer_of.get(src, 0)
		if _water.has(src):
			_water[c[0]] = true
		var own := _rgb(c[2])
		var theirs := RegEx.create_from_string("\\bmap_color\\s*=\\s*\\{([^}]*)\\}").search(_defs[src])
		var base := _rgb(theirs.get_string(1)) if theirs != null else Color.BLACK
		if own != Color.BLACK and base.r > 0.0 and base.g > 0.0 and base.b > 0.0:
			_tint_of[c[0]] = Color(minf(own.r / base.r, 4.0), minf(own.g / base.g, 4.0), minf(own.b / base.b, 4.0))


## `32 + 8`, `gleba_tile_offset+8`: names from the file's constants.
static func _sum(expr: String, consts: Dictionary) -> int:
	var total := 0
	var sign := 1
	for part in expr.replace("+", " + ").replace("-", " - ").split(" ", false):
		if part == "+":
			sign = 1
		elif part == "-":
			sign = -1
		else:
			total += sign * (int(part) if part.is_valid_int() else int(consts.get(part, 0)))
			sign = 1
	return total


## The inside of `key = { ... }` in a block, "" if it has none.
static func _str_table(block: String, key: String) -> String:
	var m := RegEx.create_from_string("\\b%s\\s*=\\s*\\{([^}]*)\\}" % key).search(block)
	return m.get_string(1) if m != null else ""


## "{21, 147, 167}" or "{r = 46, g = 45, b = 51}" as a Color (0-255 or 0-1, as Factorio reads
## them), black if it isn't one.
static func _rgb(body: String) -> Color:
	var n: Array[float] = []
	for part in body.split(","):
		var v := part.get_slice("=", part.get_slice_count("=") - 1).strip_edges()
		if v.is_valid_float():
			n.append(float(v))
	if n.size() < 3:
		return Color.BLACK
	var k := 255.0 if n[0] > 1.0 or n[1] > 1.0 or n[2] > 1.0 else 1.0
	return Color(n[0] / k, n[1] / k, n[2] / k)


static func _num(block: String, key: String, default: float) -> float:
	var m := RegEx.create_from_string("\\b%s\\s*=\\s*(-?[\\d.]+)" % key).search(block)
	return float(m.get_string(1)) if m != null else default


static func _str(block: String, key: String, default: String) -> String:
	var m := RegEx.create_from_string("\\b%s\\s*=\\s*\"([^\"]+)\"" % key).search(block)
	return m.get_string(1) if m != null else default


static func _sheet(lua_path: String, tint := Color.WHITE) -> Image:
	var image := ModFiles.load_image(lua_path)
	if image == null:
		return null
	image.convert(Image.FORMAT_RGBA8)
	if tint != Color.WHITE:
		# Only copies of water have a tint, and water's sheets are small (512 x 64 to 512 x 256).
		var data := image.get_data()
		var k := [tint.r, tint.g, tint.b]
		for i in data.size():
			if i % 4 != 3:
				data[i] = mini(255, int(data[i] * k[i % 4]))
		image.set_data(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8, data)
	return image


## Whether a sheet is laid out as a tile_variations_template (1x1, 2x2 and 4x4 rows).
static func _is_template_sheet(sheet: Image) -> bool:
	return sheet.get_height() == TEMPLATE_Y[4] + 4 * PX and sheet.get_width() >= 16 * PX


## One layer in the slot layout from the tile's definition, or null if it can't be read.
static func _build_layer(g: TileGfx, block: String) -> Image:
	var layer := Image.create_empty(COLS * PX, ROWS * PX, false, Image.FORMAT_RGBA8)
	var any := false
	var mat := RegEx.create_from_string("material_background\\s*(?:\\(\\s*\"([^\"]+)\"\\s*,\\s*(\\d+)|=\\s*\\{[^}]*?picture\\s*=\\s*\"([^\"]+)\"[^}]*?count\\s*=\\s*(\\d+))").search(block)
	var template := RegEx.create_from_string("\\w*template\\w*\\(\\s*\"([^\"]+)\"").search(block)
	var main := RegEx.create_from_string("main\\s*=\\s*\\{").search(block)
	var effect := _effect_picture(block)
	if effect != null and _effect_into(g, layer, effect, _rgb(_str_table(block, "map_color"))):
		return _finish_layer(layer)
	if mat != null:
		var sheet := _sheet(mat.get_string(1) if mat.get_string(1) != "" else mat.get_string(3))
		var count := int(mat.get_string(2) if mat.get_string(2) != "" else mat.get_string(4))
		if sheet == null or count <= 0:
			return null
		var w := sheet.get_width() / count / PX
		var h := sheet.get_height() / PX
		if w <= 0 or h <= 0 or w > COLS or h > ROWS:
			return null
		var per_row := COLS / w
		count = mini(count, per_row * (ROWS / h))
		for v in count:
			layer.blit_rect(sheet, Rect2i(v * w * PX, 0, w * PX, h * PX), Vector2i((v % per_row) * w, (v / per_row) * h) * PX)
		g.material = Vector2i(w, h)
		g.material_count = count
		any = true
	var template_sheet: Image = null
	if mat == null and template != null:
		template_sheet = _sheet(template.get_string(1), g.tint)
		if template_sheet == null:
			return null
	elif mat == null and main != null:
		# Gleba's wetlands name one 1x1 picture of a whole template sheet (Factorio draws them
		# through the water shader's own texture): read all of its variants, or every tile of
		# the swamp shows the same square.
		var only := RegEx.create_from_string("\\{\\s*picture\\s*=\\s*\"([^\"]+)\"([^{}]*)\\}").search_all(block.substr(main.get_start()))
		if only.size() == 1 and int(_num(only[0].get_string(2), "count", 1)) == 1:
			var sheet := _sheet(only[0].get_string(1), g.tint)
			if sheet != null and _is_template_sheet(sheet):
				template_sheet = sheet
	if template_sheet != null:
		var sheet := template_sheet
		var max_size := int(_num(block, "max_size", 4))
		for s in [4, 2, 1]:
			if s > max_size:
				continue
			var opts := _size_options(block, s)
			var weights: PackedFloat32Array = opts[1]
			var count := weights.size() if not weights.is_empty() else 16
			var y: int = TEMPLATE_Y[s]
			count = mini(count, mini(16, sheet.get_width() / (s * PX)))
			if y + s * PX > sheet.get_height() or count <= 0:
				continue
			for v in count:
				layer.blit_rect(sheet, Rect2i(v * s * PX, y, s * PX, s * PX), _slot_px(s, v))
			g.sizes.append([s, opts[0], _cumulative(weights, count), count])
			any = true
	elif mat == null and main != null:
		var entries := RegEx.create_from_string("\\{\\s*picture\\s*=\\s*\"([^\"]+)\"([^{}]*)\\}").search_all(block.substr(main.get_start()))
		var by_size := {}
		for e in entries:
			var s := int(_num(e.get_string(2), "size", 1))
			if s in [1, 2, 4] and not by_size.has(s):
				by_size[s] = e
		for s in [4, 2, 1]:
			if not by_size.has(s):
				continue
			var e: RegExMatch = by_size[s]
			var sheet := _sheet(e.get_string(1), g.tint)
			if sheet == null:
				continue
			var props := e.get_string(2)
			var count := mini(16, int(_num(props, "count", 1)))
			var x0 := int(_num(props, "x", 0))
			var y0 := int(_num(props, "y", 0))
			var line := int(_num(props, "line_length", count))
			var placed := 0
			for v in count:
				var src := Vector2i(x0 + (v % maxi(line, 1)) * s * PX, y0 + (v / maxi(line, 1)) * s * PX)
				if src.x + s * PX > sheet.get_width() or src.y + s * PX > sheet.get_height():
					break
				layer.blit_rect(sheet, Rect2i(src, Vector2i(s, s) * PX), _slot_px(s, v))
				placed += 1
			if placed > 0:
				g.sizes.append([s, _num(props, "probability", 1.0), _cumulative(PackedFloat32Array(), placed), placed])
				any = true
	if not any:
		return null
	_fill_empty_slots(layer)
	return _finish_layer(layer)


## Gleba's wetlands and Aquilo's brash ice: Factorio draws them with its water shader from one
## seamless picture (2048 x 1024: 32 x 16 tiles, the whole layer). False if it doesn't fit.
static func _effect_into(g: TileGfx, layer: Image, effect: Image, map_color: Color) -> bool:
	var w := mini(effect.get_width() / PX, COLS)
	var h := mini(effect.get_height() / PX, ROWS)
	if w <= 0 or h <= 0:
		return false
	# Several tiles share a picture and the shader sets each one's shade (light and dark dead
	# skin, the deep lake): their map colours say how light, so the picture is scaled to that
	# (Factorio's ground draws about MAP_TO_GROUND times its map colour).
	var target := _luma(map_color) * MAP_TO_GROUND
	var own := _mean_luma(effect)
	if target > 0.0 and own > 0.0:
		effect.adjust_bcs(clampf(target / own, 0.3, 1.5), 1.0, 1.0)
	layer.blit_rect(effect, Rect2i(0, 0, w * PX, h * PX), Vector2i.ZERO)
	g.material = Vector2i(w, h)
	g.material_count = 1
	g.reflect = MURKY_REFLECT
	# No _fill_empty_slots: the picture fills the layer, and its alpha (a mask for Factorio's
	# shader, often under a half) would pass for empty slots.
	return true


## The picture of the tile's effect, when that is a "wetland-water" water shader with one.
static func _effect_picture(block: String) -> Image:
	var effect_name := _str(block, "effect", "")
	var effect: String = _effects.get(effect_name, "")
	if effect == "" or not "wetland-water" in effect:
		return null
	var m := RegEx.create_from_string("image_textures\\s*=\\s*\\{\\s*\\{\\s*filename\\s*=\\s*\"([^\"]+)\"").search(effect)
	return _sheet(m.get_string(1)) if m != null else null


static func _luma(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b


## Average brightness of a picture, from a 64 x 64 grid of its pixels.
static func _mean_luma(image: Image) -> float:
	var total := 0.0
	for j in 64:
		for i in 64:
			total += _luma(image.get_pixel(i * image.get_width() / 64, j * image.get_height() / 64))
	return total / 4096.0


static func _finish_layer(layer: Image) -> Image:
	layer.convert(Image.FORMAT_RGB8)  # opaque: the sheets' alpha isn't drawn
	if _compress == 0:
		layer.convert(Image.FORMAT_RGBA8)  # uncompressed, as the GPU holds it (see _compress)
	layer.generate_mipmaps()
	if _compress != 0:
		# On the CPU (project.godot: rendering/textures/vram_compression/compress_with_gpu=false).
		# Godot 4.7.2's GPU compressor (Betsy) runs as a pool task that, while it waits, can run
		# this very task on its own thread, which then waits for Betsy for ever: the client froze
		# loading or quitting, no CPU used (on 4 threads all of Zenith's tasks share one slot).
		var err := layer.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_SRGB)
		_compress = 1 if err == OK else 0
		if err != OK:
			layer.convert(Image.FORMAT_RGBA8)
	return layer


## Unused slots get copies of used ones, so filtering and mipmaps at the edges of the variants
## pull in more of the same ground rather than black.
static func _fill_empty_slots(layer: Image) -> void:
	var filled := PackedByteArray()
	filled.resize(COLS * ROWS)
	var first := -1
	for i in COLS * ROWS:
		if layer.get_pixel((i % COLS) * PX + PX / 2, (i / COLS) * PX + PX / 2).a > 0.5:
			filled[i] = 1
			if first < 0:
				first = i
	for row in ROWS:
		for col in COLS:
			var i := row * COLS + col
			if filled[i] == 1:
				continue
			var src := -1
			for k in range(1, COLS):
				if filled[row * COLS + posmod(col - k, COLS)] == 1:
					src = row * COLS + posmod(col - k, COLS)
					break
			if src < 0:
				src = i - COLS if row > 0 else first
			layer.blit_rect(layer, Rect2i((src % COLS) * PX, (src / COLS) * PX, PX, PX), Vector2i(col, row) * PX)
			filled[i] = 1


static func _slot_px(s: int, v: int) -> Vector2i:
	match s:
		4:
			return Vector2i((v % 8) * 4, ROW_4 + (v / 8) * 4) * PX
		2:
			return Vector2i(v * 2, ROW_2) * PX
	return Vector2i(v, ROW_1) * PX


## [probability, weights] of one size in a tile_variations_template's options: `[2] = {
## probability = 0.91, weights = {...} }`. Size 1 always fits; bigger sizes default to never.
static func _size_options(block: String, s: int) -> Array:
	var m := RegEx.create_from_string("\\[%d\\]\\s*=\\s*\\{([^{}]*(?:\\{[^{}]*\\})?[^{}]*)\\}" % s).search(block)
	if m == null:
		return [1.0 if s == 1 else 0.0, PackedFloat32Array()]
	var body := m.get_string(1)
	var weights := PackedFloat32Array()
	var w := RegEx.create_from_string("weights\\s*=\\s*\\{([^}]*)\\}").search(body)
	if w != null:
		for part in w.get_string(1).split(","):
			if part.strip_edges() != "":
				weights.append(float(part.strip_edges()))
	return [_num(body, "probability", 1.0), weights]


static func _cumulative(weights: PackedFloat32Array, count: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var total := 0.0
	for i in count:
		total += weights[i] if i < weights.size() else 1.0
		out.append(total)
	return out


## Sorted list of every tile name known from Factorio's definitions and active mods' graphics list.
static func known_tile_names() -> Array:
	if ItemIcons.factorio_data_dir() != "":
		_read_defs()
	var seen := {}
	for k in _defs:
		seen[str(k)] = true
	for k in ModGraphics.tiles:
		seen[str(k)] = true
	var out := seen.keys()
	out.sort()
	return out


## Whether Factorio's definitions or the active mods' graphics list defines `tile_name`.
static func has_tile_def(tile_name: String) -> bool:
	if ItemIcons.factorio_data_dir() != "":
		_read_defs()
		if _defs.has(tile_name):
			return true
	return ModGraphics.tiles.has(tile_name)


## Swatch preview (up to 128 x 128, FORMAT_RGBA8) of Factorio's or a mod's own tile picture
## (ignoring --plain-terrain so Model packs can preview it), or null without an install/mod.
static func preview_image(tile_name: String) -> Image:
	if ItemIcons.factorio_data_dir() != "":
		_read_defs()
	var mod_rec := _mod_tile_record(tile_name)
	if not mod_rec.is_empty():
		var mod_img := _preview_from_record(mod_rec)
		if mod_img != null:
			return mod_img
	if ItemIcons.factorio_data_dir() == "":
		return null
	var block := str(_defs.get(tile_name, ""))
	if block == "":
		return null
	return _preview_from_block(block, _tint_of.get(tile_name, Color.WHITE))


## Swatch preview (up to 128 x 128, FORMAT_RGBA8) from a model pack's tile file list, spec, and optional PBR maps.
static func pack_preview_image(files: Array, spec := {}, maps := {}) -> Image:
	var show_files := files
	if show_files.is_empty() and not maps.is_empty():
		for kind: String in ["normal", "height", "roughness"]:
			var mf: Variant = maps.get(kind)
			if mf is Array and not (mf as Array).is_empty():
				show_files = mf as Array
				break
	if show_files.is_empty():
		return null
	var img := _load_pack_image(str(show_files[0]))
	if img == null or img.is_empty():
		return null
	if show_files.size() == 1 and _is_template_sheet(img) and not spec.has("size") and not spec.has("count"):
		if img.get_height() >= TEMPLATE_Y[2] + 2 * PX and img.get_width() >= 2 * PX:
			img = img.get_region(Rect2i(0, TEMPLATE_Y[2], 2 * PX, 2 * PX))
		else:
			img = img.get_region(Rect2i(0, 0, mini(PX, img.get_width()), mini(PX, img.get_height())))
	elif show_files.size() == 1 and int(spec.get("count", 1)) > 1:
		var cnt := int(spec["count"])
		var sw := img.get_width() / cnt
		if sw > 0:
			img = img.get_region(Rect2i(0, 0, sw, img.get_height()))
	elif img.get_width() != img.get_height():
		var side := mini(img.get_width(), img.get_height())
		img = img.get_region(Rect2i((img.get_width() - side) / 2, (img.get_height() - side) / 2, side, side))
	return _fit_preview_swatch(img)


static func _preview_from_record(rec: Dictionary) -> Image:
	if rec.get("fx") is String:
		var effect := _sheet(str(rec.fx))
		if effect != null:
			var r := Rect2i(0, 0, mini(128, effect.get_width()), mini(128, effect.get_height()))
			return _fit_preview_swatch(effect.get_region(r))
	if rec.get("mat") is Array and (rec.mat as Array).size() >= 2:
		var m: Array = rec.mat
		var sheet := _scaled(_sheet(str(m[0])), float(m[2]) if m.size() > 2 else 0.5)
		var count := maxi(1, int(m[1]))
		if sheet != null:
			var w := maxi(1, sheet.get_width() / count)
			return _fit_preview_swatch(sheet.get_region(Rect2i(0, 0, mini(w, sheet.get_width()), sheet.get_height())))
	if rec.get("main") is Array:
		for e in rec.main:
			if e is Array and (e as Array).size() >= 6:
				var scale := float(e[8]) if (e as Array).size() > 8 else 1.0
				var sheet := _scaled(_sheet(str(e[0])), scale)
				if sheet == null:
					continue
				var sz := clampi(int(e[2]), 1, 4)
				var k := 2.0 * scale
				var x0 := clampi(roundi(float(e[3]) * k), 0, maxi(0, sheet.get_width() - 1))
				var y0 := clampi(roundi(float(e[4]) * k), 0, maxi(0, sheet.get_height() - 1))
				var sw := mini(sz * PX, sheet.get_width() - x0)
				var sh := mini(sz * PX, sheet.get_height() - y0)
				if sw > 0 and sh > 0:
					return _fit_preview_swatch(sheet.get_region(Rect2i(x0, y0, sw, sh)))
	return null


static func _preview_from_block(block: String, tint: Color) -> Image:
	var effect := _effect_picture(block)
	if effect != null:
		return _fit_preview_swatch(effect.get_region(Rect2i(0, 0, mini(128, effect.get_width()), mini(128, effect.get_height()))))
	var mat := RegEx.create_from_string("material_background\\s*(?:\\(\\s*\"([^\"]+)\"\\s*,\\s*(\\d+)|=\\s*\\{[^}]*?picture\\s*=\\s*\"([^\"]+)\"[^}]*?count\\s*=\\s*(\\d+))").search(block)
	if mat != null:
		var sheet := _sheet(mat.get_string(1) if mat.get_string(1) != "" else mat.get_string(3))
		var count := maxi(1, int(mat.get_string(2) if mat.get_string(2) != "" else mat.get_string(4)))
		if sheet != null:
			var w := maxi(1, sheet.get_width() / count)
			return _fit_preview_swatch(sheet.get_region(Rect2i(0, 0, mini(w, sheet.get_width()), sheet.get_height())))
	var template := RegEx.create_from_string("\\w*template\\w*\\(\\s*\"([^\"]+)\"").search(block)
	var main := RegEx.create_from_string("main\\s*=\\s*\\{").search(block)
	var template_sheet: Image = null
	if template != null:
		template_sheet = _sheet(template.get_string(1), tint)
	elif main != null:
		var only := RegEx.create_from_string("\\{\\s*picture\\s*=\\s*\"([^\"]+)\"([^{}]*)\\}").search_all(block.substr(main.get_start()))
		if only.size() == 1 and int(_num(only[0].get_string(2), "count", 1)) == 1:
			var sheet := _sheet(only[0].get_string(1), tint)
			if sheet != null and _is_template_sheet(sheet):
				template_sheet = sheet
	if template_sheet != null:
		if template_sheet.get_height() >= TEMPLATE_Y[2] + 2 * PX and template_sheet.get_width() >= 2 * PX:
			return _fit_preview_swatch(template_sheet.get_region(Rect2i(0, TEMPLATE_Y[2], 2 * PX, 2 * PX)))
		return _fit_preview_swatch(template_sheet.get_region(Rect2i(0, 0, mini(PX, template_sheet.get_width()), mini(PX, template_sheet.get_height()))))
	if main != null:
		var entries := RegEx.create_from_string("\\{\\s*picture\\s*=\\s*\"([^\"]+)\"([^{}]*)\\}").search_all(block.substr(main.get_start()))
		for e in entries:
			var sheet := _sheet(e.get_string(1), tint)
			if sheet == null:
				continue
			var props := e.get_string(2)
			var s := clampi(int(_num(props, "size", 1)), 1, 4)
			var x0 := clampi(int(_num(props, "x", 0)), 0, maxi(0, sheet.get_width() - 1))
			var y0 := clampi(int(_num(props, "y", 0)), 0, maxi(0, sheet.get_height() - 1))
			var sw := mini(s * PX, sheet.get_width() - x0)
			var sh := mini(s * PX, sheet.get_height() - y0)
			if sw > 0 and sh > 0:
				return _fit_preview_swatch(sheet.get_region(Rect2i(x0, y0, sw, sh)))
	return null


static func _fit_preview_swatch(img: Image) -> Image:
	if img == null or img.is_empty():
		return null
	var out := img.duplicate() as Image
	if out.is_compressed():
		out.decompress()
	out.convert(Image.FORMAT_RGBA8)
	var w := out.get_width()
	var h := out.get_height()
	if w > 128 or h > 128:
		var scale := minf(128.0 / float(w), 128.0 / float(h))
		out.resize(maxi(1, roundi(w * scale)), maxi(1, roundi(h * scale)), Image.INTERPOLATE_LANCZOS)
	return out
