extends Node3D
## Factorio's decoratives (grass, flowers, small rocks, decals) near the camera. The mod sends them
## per chunk (`dec`, ids from `dprotos`) when the hello asks (`dc`, Settings → Graphics →
## Decoratives). Each decorative in a chunk is one MultiMeshInstance3D: every instance one of the
## decorative's pictures, read from the player's Factorio install with the regions listed in
## client/data/decoratives.json (tools/decor_index.py). Most lie flat on the ground as Factorio
## draws them; plants on the "object" layer stand up as cards turned to the camera
## (shaders/decorative.gdshader). Without an install nothing is drawn.
##
## The density setting keeps a share of them, the same ones every time (by position).
##
## A chunk is built on a worker thread (10-55 ms each on the main thread while walking, and a
## decorative's first appearance read its pictures from the install there, up to 300 ms): its
## instances' transforms are worked out into a MultiMesh buffer and new pictures loaded into an
## atlas image (BuildJob, KindData). The main thread then only makes the MultiMeshes and new
## decoratives' textures, within its slice of the frame (frame_budget.gd, `decoratives`); the
## chunk's old clutter stays until then.
##
## Grass and low plants near the character also rise into 3D (Settings > Graphics > 3D grass;
## shaders/decorative_grass.gdshader): the same pictures, atlas and instances over a small grid, one
## extra MultiMesh per chunk per decorative, only in chunks within range, casting no shadows. The first
## instances of a kind (a fixed random order) are raised, up to GRASS_CHUNK_TRIANGLES a chunk, tufts
## and bushes before carpets. Carpets (wide patches of short blades, most of a Nauvis meadow) stand up
## as clumps of blades instead (shaders/decorative_carpet.gdshader): crossed cards, each a piece of the
## patch's own picture where it has plant (_carpet_cells).
##
## Nothing grows on a player's floor or under a building (owner: "Concrete should remove all grass and
## foliage", and none round a rocket silo): Factorio removes only some of them (a tile's
## decorative_removal_probability, an entity's collision box), and its pictures reach past their
## tile. Each chunk's job makes a mask of the tiles no decorative may cover (_mask_of): floors (tiles
## an item lays, `iuse` "t", else by name: FLOOR_WORDS) and every building's tile footprint, its own
## and those of its neighbours' buildings reaching into it (_spills). Decoratives rooted there are left
## out, tufts touching it stay flat, and the mask goes into a texture the shaders read
## (decor_mask.gdshaderinc), which cuts flat pictures at the tile's edge and stands no carpet clump on
## or next to it. Building, mining or laying tiles (world.gd's entities_changed, tiles_changed) builds
## the chunk again; its nodes are only replaced when its mask or its flat tufts changed.

const ItemIcons := preload("res://scripts/world/item_icons.gd")
const ModFiles := preload("res://scripts/world/mod_files.gd")
const ModGraphics := preload("res://scripts/world/mod_graphics.gd")
const FrameBudget := preload("res://scripts/world/frame_budget.gd")
const ViewPriority := preload("res://scripts/world/view_priority.gd")
const SHADER := preload("res://shaders/decorative.gdshader")
const SHADER_FLAT := preload("res://shaders/decorative_flat.gdshader")
const SHADER_GRASS := preload("res://shaders/decorative_grass.gdshader")
const SHADER_CARPET := preload("res://shaders/decorative_carpet.gdshader")
const INDEX := "res://data/decoratives.json"

const CHUNK := 32
## Factorio's pictures: 32 pixels a tile at scale 1.
const PX_PER_TILE := 32.0
## Chunks further than this from the character (tiles, from the chunk's nearest edge) aren't drawn.
## Measured from the character, not the camera: the camera sits far back and up, so its own
## visibility range left the ground near the character bare and drew clutter behind it.
const DRAW_DISTANCE := 192.0
## Level of detail: past FULL_DISTANCE a chunk draws half its clutter, past HALF_DISTANCE a
## quarter. Each chunk's instances are in a fixed random order, so drawing the first part thins
## the clutter evenly rather than cutting it off.
const FULL_DISTANCE := 80.0
const HALF_DISTANCE := 136.0
## Decoratives on this render layer stand up (Gleba's plants, corals, icebergs); the rest (grass,
## flowers, small rocks, decals: "decals", "decorative", "floor", "ground-layer-*") lie flat.
const UPRIGHT_LAYER := "object"
## Flat decoratives lie just over the ground, in Factorio's render layer order (decals under ground
## layers under floor under decoratives). At one height, overlapping ones (biter creep over grass
## patches) fought over every pixel and flickered.
const LAYER_LIFT := {"decals": 0.010, "ground-layer-1": 0.016, "ground-layer-2": 0.019, "ground-layer-3": 0.022,
	"ground-layer-4": 0.025, "ground-layer-5": 0.028, "floor": 0.031, "decorative": 0.036}
## Within a layer, each tile's decorative a step higher or lower (fixed by its tile), so two of the
## same layer overlapping resolve the same way every frame.
const TILE_STEP := 0.0012
const TILE_STEPS := 4
## Render priorities from the lowest: flat decoratives, then raised ones, under 0 (and -1, flat effects).
const FLAT_PRIORITIES := 96
const GRASS_PRIORITIES := 31
## Floats per instance in a MultiMesh buffer: a 3x4 transform, then the custom data.
const STRIDE := 16
## 3D grass: [range in tiles, wind] per Settings > Graphics > 3D grass.
const GRASS_MODES := {"off": [0.0, false], "short": [30.0, false], "normal": [40.0, true], "far": [50.0, true]}
## The decoratives that rise: "decorative"-layer pictures of plants, by name. Rocks, decals, lichens
## and mushrooms stay flat; standing plants ("object") are cards.
const GRASS_WORDS := ["grass", "fluff", "asterisk", "croton", "pita", "bush", "fern", "reed", "shrub"]
## The triangles one chunk's raised plants may take. Tufts and bushes come first; carpets share what is
## left, and past it fewer are raised, evenly (each kind's instances are in a fixed random order), the
## rest staying flat. Sized for a real Nauvis meadow, not the mock's scatter: a grassy chunk there has
## 600-1,400 decoratives, about 600 tufts (20,000 triangles) and 500 carpets (about 160 triangles each
## as clumps, 80,000), where the first cap of 6,144 raised one plant in fourteen and the meadow looked
## flat. A clump's slot a picture doesn't use makes no triangle on screen but counts here.
const GRASS_CHUNK_TRIANGLES := 106496
## Grid cells a side: a tuft's root is its middle point, so an even number, 2 rings out from it.
const GRASS_CELLS := 4
## Wider than this (tiles) a raised decorative is a carpet, a scatter of many little clumps.
const GRASS_CARPET := 3.0
## A carpet clump's piece of its picture (tiles): across, and north to south. Stood up on its southern
## edge it is about 0.55 tile tall (CARPET_STRETCH times Factorio's own 0.45 / cot 48 degrees), varied
## 0.75-1.25 by the shader: Factorio's short blades as they would stand.
const CARPET_CLUMP := Vector2(0.5, 0.45)
const CARPET_STRETCH := 1.1
## A piece with less of its area plant than this has no clump (it keeps 96% of the plant's pixels).
const CARPET_COVER := 0.03
## Clumps a picture at most, those with most plant (Nauvis's pictures have 25-45).
const CARPET_CLUMPS := 40
## How much a raised carpet's flat picture darkens under its clumps (decorative_flat.gdshader; tufts 0.55).
const CARPET_SHADE := 0.3
## A share of a picture's area covered by the plant itself above which it is a bush (a mound of
## leaves) and not a tuft of blades arching out of a root.
const GRASS_BUSH_COVER := 0.3
## Tiles past the range that a chunk's raised plants are made in advance, hidden (one chunk a frame).
const GRASS_MARGIN := 16.0
## Pixels a tile: under GRASS_PX_OFF the plants are too small on screen for height to show.
const GRASS_PX_FULL := 24.0
const GRASS_PX_OFF := 14.0
## Floors by name, for a bridge that sent no `iuse` (and the mock): Nauvis's paths and concrete in
## every colour, landfill, Space Age's foundations, platforms and artificial or overgrown soils.
const FLOOR_WORDS := ["concrete", "stone-path", "landfill", "foundation", "platform", "artificial-", "overgrowth-"]
## Entity types that aren't buildings: decoratives grow round them (ore, trees, rocks, cliffs, biter
## bases and worms on their creep, remnants, ghosts, things that move or fly).
const NOT_BUILDINGS := {"resource": true, "tree": true, "plant": true, "simple-entity": true, "cliff": true,
	"corpse": true, "rail-remnants": true, "character-corpse": true, "item-entity": true, "entity-ghost": true,
	"tile-ghost": true, "item-request-proxy": true, "deconstructible-tile-proxy": true, "fish": true, "unit": true,
	"unit-spawner": true, "turret": true, "spider-unit": true, "spider-leg": true, "segment": true, "segmented-unit": true,
	"character": true, "car": true, "spider-vehicle": true, "locomotive": true, "cargo-wagon": true, "fluid-wagon": true,
	"artillery-wagon": true, "infinity-cargo-wagon": true, "combat-robot": true, "construction-robot": true,
	"logistic-robot": true, "capture-robot": true, "cargo-pod": true, "asteroid": true, "lightning": true,
	"explosion": true, "fire": true, "stream": true, "sticker": true, "projectile": true, "artillery-projectile": true,
	"beam": true, "smoke-with-trigger": true, "particle-source": true, "highlight-box": true, "speech-bubble": true,
	"artillery-flare": true, "temporary-container": true}
## The mask texture (decor_mask.gdshaderinc): chunks a side before it wraps, so every chunk within 16
## chunks of the focus has its own place (the furthest clutter is 320 tiles out).
const MASK_CHUNKS := 32
## How near a chunk's edge (tiles) a change in its mask can change its neighbours' tufts.
const MASK_BAND := 3


## One decorative's pictures as loaded on a worker thread: the atlas (variants side by side) and
## where each variant is in it.
class KindData:
	var name := ""
	var atlas: Image  # until its texture is made (_kind)
	var upright := false
	var lift := 0.02
	## Per variant: Vector4(u start, u width, v height, 0) in the atlas, its size in tiles and its
	## shift in tiles.
	var uvs: Array[Vector4] = []
	var sizes: Array[Vector2] = []
	var shifts: Array[Vector2] = []
	var grass_height := 0.0  # tiles; 0: stays flat
	var grass_cells := 0  # grid cells a side
	var grass_carpet := false  # a wide scatter of low lumps: raised after the tufts and bushes
	var grass_tuft := false  # blades arching out of a root; otherwise lumps where the plant is thick
	var grass_lod := 3.0  # the mipmap as coarse as the grid
	var grass_triangles := 0  # one raised instance's
	## A carpet's clumps (_carpet_cells): a row per variant, a texel per clump, and the most in a row.
	var carpet_cells: Image
	var carpet_clumps := 0


## One decorative's pictures, ready to draw (made on the main thread from its KindData).
class Kind:
	var name := ""
	var material: ShaderMaterial
	var mesh: Mesh
	var upright := false
	var grass_mesh: Mesh  # null: stays flat
	var grass_material: ShaderMaterial
	var grass_triangles := 0


## A chunk's clutter worked out on a worker thread: per decorative [name, buffer, instances, KindData,
## how many of them rise].
class BuildJob:
	var chunk := Vector2i.ZERO
	var version := 0
	var list: Array = []
	var density := 1.0
	var names := {}
	var data_dir := ""
	var groups: Array = []
	## The mask's inputs (copies or never changed after): the chunk's tile ids, 1 per floor tile id,
	## its entity records, proto id -> Vector4(tiles across, down, box centre) for buildings, the
	## neighbours' footprints reaching in [x0, y0, x1, y1, ...] and their masks (offset -> rows).
	var tiles := PackedInt32Array()
	var floors := PackedByteArray()
	var recs: Array = []
	var foot := {}
	var spill_in := PackedInt32Array()
	var near := {}
	## Only the mask may have changed (a build, a tile): the nodes stay unless it or the flat tufts did.
	var mask_only := false
	## Out: a bit per tile (row by row, lowest bit west), this chunk's footprints reaching out, and the
	## places of tufts kept flat by the mask.
	var mask := PackedInt32Array()
	var spill := PackedInt32Array()
	var edge: Array = []


## Shared between games: the index, the pictures read from it (null: none) and the decoratives
## made from them.
static var _index := {}
static var _index_generation := -1  # ModGraphics.generation the index was merged with
static var _retired: Array = []
static var _kind_data := {}
static var _kinds := {}
static var _flat_order := {}  # flat decorative -> its rank in the drawing order (_flat_priority)
static var _grass_order := {}  # raised decorative -> its rank in the drawing order (_grass_priority)
static var _grass_meshes := {}  # grid cells a side -> the grid; minus a carpet's clumps -> its mesh
static var _wind: NoiseTexture2D  # the carpets' gusts (_wind_noise)
## Worker threads read pictures one at a time (and each only once).
static var _kind_mutex := Mutex.new()

var enabled := true
var density := 1.0
## Every chunk's clutter in full out to `distance`, not thinned past FULL_DISTANCE (full_detail.gd).
var full_detail := false:
	set(on):
		full_detail = on
		_culled_distance = -1.0  # culled again on the next frame
		_shares.clear()
## Tiles from the focus to the last clutter drawn (Settings > Graphics > Decorative distance).
var distance := DRAW_DISTANCE
## Where the focus was, and the distance, when _cull last looked; it looks again past CULL_STEP tiles.
const CULL_STEP := 0.5
var _culled_at := Vector2.INF
var _culled_distance := -1.0
## Chunks still loaded (world.gd's): others are dropped now and then.
var world: Node
## The camera rig (main.gd): clutter is drawn around what it follows, the character (or the remote
## view's point); without it, everything loaded shows.
var rig: Node

var _names := {}  # id -> name
var _parts := {}  # Vector2i -> {"parts": n, "got": n, "l": flat list}
var _chunks := {}  # Vector2i -> Node3D holding that chunk's MultiMeshInstance3Ds
var _lists := {}  # Vector2i -> the chunk's last full list, to rebuild when the density changes
var _sweep := 0.0
var _built_generation := 0  # ModGraphics.generation the chunks were built with
var _shares := {}  # Vector2i -> the share of the chunk's clutter drawn now (1, 0.5, 0.25, 0)
var _versions := {}  # Vector2i -> the number of the chunk's latest build (older jobs' results are dropped)
## Builds are numbered on from game to game, so a job still running from before reset() never
## matches a new build of the same chunk.
var _last_version := 0
var _jobs: Array = []  # [task id, BuildJob], oldest first
## A world left (another surface, a factory building's door): its chunks' nodes, hidden, freed a
## few a frame. Freeing all of them at once (441 chunks of clutter) made a 35-60 ms frame.
var _freeing: Array = []
const FREE_USEC := 1000
## 3D grass (set_grass). Tiles from the character; 0: off.
var grass_range := 0.0
var grass_wind := false
var _grass_culled_range := -1.0
## Where 3D grass is centred (_grass_centre): the character, or in front of the camera while it leads
## (view_priority.gd); where _cull_grass last looked from, the offset from the character easing
## towards the camera's, and the fade that hides a jump too long to glide.
var _grass_at := Vector2.INF
var _grass_offset := Vector2.ZERO
var _grass_fade := 1.0
var _grass_lists := {}  # Vector2i -> [[Kind, buffer, instances], ...] what a chunk has to raise
var _grass := {}  # Vector2i -> Node3D holding that chunk's raised MultiMeshes
var _grass_queue: Array[Vector2i] = []  # chunks coming into range, made one a frame
var _grass_root: Node3D
var _grass_stats_at := 0.0  # --grass-stats: seconds to the next line
## Ground no decorative covers (the header). Tile names an item lays (`iuse` "t").
var _floor_names := {}
var _floor_gen := 0  # raised by each `iuse`
var _floors := PackedByteArray()  # per tile id: 1 a floor
var _foot := {}  # proto id -> Vector4(tiles across, down, box centre x, y): buildings only
var _rules_key := Vector3i(-1, -1, -1)  # tile names, entity protos and floor names they were made from
var _masks := {}  # Vector2i -> PackedInt32Array, a row of bits per tile row
var _spills := {}  # Vector2i -> PackedInt32Array: its buildings' footprints reaching out of it
var _edges := {}  # Vector2i -> the tufts its last build kept flat
var _read_revs := {}  # Vector2i -> the chunk's content_rev (chunk_view.gd) its last build read
var _restale := {}  # Vector2i -> true: build again next frame, its mask may have changed
var _full_pending := {}  # Vector2i -> true: a build with a new list is on its way
var _mask_focus := Vector2i.ZERO  # the focus's chunk: chunks within MASK_CHUNKS / 2 of it own their place
var _mask_owner := {}  # Vector2i place in the texture -> the chunk whose mask is there
var _mask_bytes := PackedByteArray()
var _mask_image: Image
var _mask_texture: ImageTexture
var _mask_dirty := false
var _connected: Node


func _init() -> void:
	_grass_root = Node3D.new()
	_grass_root.name = "Grass"
	add_child(_grass_root)
	_mask_bytes.resize(MASK_CHUNKS * MASK_CHUNKS * CHUNK * 4)


## A new game; `keep_names` on another surface of the same game, whose ids stay (the mod sends
## `dprotos` only in the handshake).
func reset(keep_names := false) -> void:
	if not keep_names:
		_names.clear()
		_floor_names.clear()
	_parts.clear()
	_lists.clear()
	_versions.clear()
	_masks.clear()
	_spills.clear()
	_edges.clear()
	_read_revs.clear()
	_restale.clear()
	_full_pending.clear()
	_mask_owner.clear()
	_mask_bytes.fill(0)
	_mask_dirty = true
	for node: Node3D in _chunks.values():
		node.visible = false
		_freeing.append(node)
	_chunks.clear()
	_grass_lists.clear()
	_grass_queue.clear()
	for node: Node3D in _grass.values():
		node.visible = false
		_freeing.append(node)
	_grass.clear()


func count() -> int:
	var n := 0
	for l in _lists.values():
		n += l.size() >> 2
	return n


func set_options(on: bool, share: float) -> void:
	var rebuild := not is_equal_approx(share, density)
	enabled = on
	density = clampf(share, 0.0, 1.0)
	visible = on
	if rebuild:
		for c in _lists.keys():
			_build(c)


## Settings > Graphics > 3D grass: a GRASS_MODES key. Nothing is rebuilt: the flat pictures already
## know which of them rise, and the raised copies come and go by range.
func set_grass(mode: String) -> void:
	var m: Array = GRASS_MODES.get(mode, GRASS_MODES["off"])
	grass_range = m[0]
	grass_wind = m[1]
	RenderingServer.global_shader_parameter_set(&"f3d_grass_wind", 1.0 if grass_wind else 0.0)
	if grass_range <= 0.0:
		RenderingServer.global_shader_parameter_set(&"f3d_grass", Vector4.ZERO)


func handle(msg: Dictionary) -> void:
	match str(msg.get("t", "")):
		"dprotos":
			for rec in _array(msg.get("l")):
				if rec is Array and rec.size() >= 2:
					_names[_int(rec[0])] = str(rec[1])
		"iuse":
			# The tiles items lay are the player's floors (ui_model.gd reads the rest of it).
			if _int(msg.get("part", 1)) == 1:
				_floor_names.clear()
			_floor_gen += 1
			for rec in _array(msg.get("l")):
				if rec is Array and rec.size() >= 3 and str(rec[1]) == "t":
					for i in range(2, mini(rec.size(), 4)):
						if rec[i] is String and rec[i] != "":
							_floor_names[rec[i]] = true
		"dec":
			var c := Vector2i(_int(msg.get("cx")), _int(msg.get("cy")))
			var part := _int(msg.get("part", 1))
			var p: Dictionary = _parts.get(c, {})
			if part == 1 or p.is_empty():
				p = {"parts": _int(msg.get("parts", 1)), "got": 0, "l": []}
				_parts[c] = p
			p["got"] = int(p["got"]) + 1
			(p["l"] as Array).append_array(_array(msg.get("l")))
			if int(p["got"]) >= int(p["parts"]):
				_parts.erase(c)
				_lists[c] = p["l"]
				_build(c)


func _process(delta: float) -> void:
	_free_some()
	if _built_generation != ModGraphics.generation:
		# A graphics list (mod_graphics.gd): every chunk's clutter is built again from it.
		_built_generation = ModGraphics.generation
		index()
		for c in _lists.keys():
			_build(c)
	_watch_world()
	if _refresh_rules():
		for c in _lists.keys():
			_restale[c] = true
	if not _restale.is_empty():
		for c: Vector2i in _restale:
			if _lists.has(c):
				_build(c, true)
		_restale.clear()
	if _jobs.is_empty():
		FrameBudget.waiting(&"decoratives", 0)
	else:
		var t0 := Time.get_ticks_usec()
		var allow := FrameBudget.grant(&"decoratives")
		if allow > 0:
			_finish_jobs(allow)
		FrameBudget.spent(&"decoratives", Time.get_ticks_usec() - t0, _jobs.size())
	_cull()
	_upload_mask()
	_make_grass_some()
	_print_grass_stats(delta)
	_sweep += delta
	if _sweep < 2.0 or world == null:
		return
	_sweep = 0.0
	for c in _lists.keys():
		if not world.chunks.has(c):
			_drop(c)


## Listens to world.gd's changes (once it is set; tests stand in a world without them).
func _watch_world() -> void:
	if world == _connected or world == null or not is_instance_valid(world):
		return
	_connected = world
	if world.has_signal("entities_changed"):
		world.entities_changed.connect(_world_changed)
	if world.has_signal("tiles_changed"):
		world.tiles_changed.connect(_world_changed)


## Something was built, mined or laid in a chunk: built again next frame if its tiles or entities
## moved on since its last build read them (every chunk drawn says entities_changed, mostly unchanged).
func _world_changed(c: Vector2i) -> void:
	if not _lists.has(c):
		return
	var cv = world.chunks.get(c)
	if not (cv is Object):
		return  # unloaded: dropped with the next sweep
	var rev = cv.get("content_rev")
	if not (rev is int) or int(_read_revs.get(c, -1)) != rev:
		_restale[c] = true


## The floors' tile ids and the buildings' footprints, again when the prototypes or `iuse` changed.
## True if they did.
func _refresh_rules() -> bool:
	var protos = world.get("protos") if world != null and is_instance_valid(world) else null
	if not (protos is Object):
		return false
	var tile_names: PackedStringArray = protos.tile_names
	var entities: Dictionary = protos.entities
	var key := Vector3i(tile_names.size(), entities.size(), _floor_gen)
	if key == _rules_key:
		return false
	_rules_key = key
	var floors := PackedByteArray()
	floors.resize(tile_names.size())
	for id in tile_names.size():
		floors[id] = 1 if is_floor(tile_names[id], _floor_names) else 0
	_floors = floors
	# A new table each time: jobs on worker threads read the one they were given.
	var foot := {}
	for id in entities:
		var p = entities[id]
		if NOT_BUILDINGS.has(p.type):
			continue
		var tiles: Vector2i = p.tile_size
		var size: Vector2 = p.size()
		var w := tiles.x if tiles.x > 0 else maxi(1, roundi(size.x))
		var h := tiles.y if tiles.y > 0 else maxi(1, roundi(size.y))
		var centre: Vector2 = p.center()
		foot[id] = Vector4(w, h, centre.x, centre.y)
	_foot = foot
	return true


## Whether nothing grows on a tile: one an item lays (`iuse`), or named like a floor without one.
static func is_floor(tile_name: String, laid: Dictionary) -> bool:
	if laid.has(tile_name):
		return true
	if tile_name.begins_with("natural-"):
		return false
	for word: String in FLOOR_WORDS:
		if tile_name.contains(word):
			return true
	return false


## The mask's place in the texture for a chunk (it wraps round MASK_CHUNKS chunks).
static func _mask_slot(c: Vector2i) -> Vector2i:
	return Vector2i(posmod(c.x, MASK_CHUNKS), posmod(c.y, MASK_CHUNKS))


## Whether a chunk is the one near the focus that its place in the texture holds.
func _mask_rightful(c: Vector2i) -> bool:
	var d := c - _mask_focus
	return d.x >= -MASK_CHUNKS / 2 and d.x < MASK_CHUNKS / 2 and d.y >= -MASK_CHUNKS / 2 and d.y < MASK_CHUNKS / 2


## A chunk's rows of bits into its place in the texture (empty: none blocked).
func _write_mask(c: Vector2i, mask: PackedInt32Array) -> void:
	var slot := _mask_slot(c)
	_mask_owner[slot] = c
	for y in CHUNK:
		var row := mask[y] if mask.size() == CHUNK else 0
		var o := ((slot.y * CHUNK + y) * MASK_CHUNKS + slot.x) * 4
		_mask_bytes[o] = row & 255
		_mask_bytes[o + 1] = (row >> 8) & 255
		_mask_bytes[o + 2] = (row >> 16) & 255
		_mask_bytes[o + 3] = (row >> 24) & 255
	_mask_dirty = true


## The focus came into another chunk: chunks now nearest it take their places in the texture back.
func _mask_follow(at: Vector2) -> void:
	var f := Vector2i(floori(at.x / CHUNK), floori(at.y / CHUNK))
	if f == _mask_focus:
		return
	_mask_focus = f
	for c: Vector2i in _masks:
		if _mask_rightful(c) and _mask_owner.get(_mask_slot(c)) != c:
			_write_mask(c, _masks[c])


## The texture again if a mask changed this frame: 128 KB, once.
func _upload_mask() -> void:
	if not _mask_dirty:
		return
	_mask_dirty = false
	if _mask_image == null:
		_mask_image = Image.create_from_data(MASK_CHUNKS, MASK_CHUNKS * CHUNK, false, Image.FORMAT_RGBA8, _mask_bytes)
		_mask_texture = ImageTexture.create_from_image(_mask_image)
		RenderingServer.global_shader_parameter_set(&"f3d_decor_mask", _mask_texture)
		RenderingServer.global_shader_parameter_set(&"f3d_decor_mask_on", 1.0)
		return
	_mask_image.set_data(MASK_CHUNKS, MASK_CHUNKS * CHUNK, false, Image.FORMAT_RGBA8, _mask_bytes)
	_mask_texture.update(_mask_image)


## Whether a map tile is blocked by the masks built so far (tests, tools).
func blocked_at(x: int, y: int) -> bool:
	var c := Vector2i(floori(x / float(CHUNK)), floori(y / float(CHUNK)))
	var mask: PackedInt32Array = _masks.get(c, PackedInt32Array())
	return mask.size() == CHUNK and ((mask[y - c.y * CHUNK] >> (x - c.x * CHUNK)) & 1) == 1


## Frees the left world's nodes within FREE_USEC a frame (at least one).
func _free_some() -> void:
	var t0 := Time.get_ticks_usec()
	while not _freeing.is_empty():
		var node: Node3D = _freeing.pop_back()
		if is_instance_valid(node):
			node.free()
		if Time.get_ticks_usec() - t0 > FREE_USEC:
			break


## How many of a left world's nodes are still to be freed (tests).
## Nothing being built: no chunk's clutter on a worker, no raised grass still to make or fading in.
func settled() -> bool:
	return _jobs.is_empty() and _grass_queue.is_empty() and _grass_fade >= 1.0 and _restale.is_empty()


## settled() for a screenshot of what `in_view` sees (a Callable(Vector2i) -> bool; full_detail.gd):
## how many of those chunks' clutter is still to come or being built, and 3D grass fading. Chunks
## off the view keep building as they arrive without holding the shot.
func pending_in(in_view: Callable) -> int:
	var n := 0 if _grass_fade >= 1.0 else 1
	for entry: Array in _jobs:
		if in_view.call((entry[1] as BuildJob).chunk):
			n += 1
	for c: Vector2i in _restale:
		if _lists.has(c) and in_view.call(c):
			n += 1
	for c: Vector2i in _grass_queue:
		if in_view.call(c):
			n += 1
	for c: Vector2i in _parts:
		if in_view.call(c):
			n += 1
	return n


func freeing_count() -> int:
	return _freeing.size()


## Shows the chunks near the focus only: one distance per chunk, again whenever the focus has moved
## a little or the distance changed; a chunk whose MultiMeshes were just made is culled alone (_replace).
func _cull() -> void:
	var focus: Node3D = rig.get("target") if rig != null and is_instance_valid(rig) else null
	if focus == null or not is_instance_valid(focus):
		return
	var at := Vector2(focus.global_position.x, focus.global_position.z)
	_mask_follow(at)
	_grass_follow(_grass_centre(at))
	if at.distance_squared_to(_culled_at) < CULL_STEP * CULL_STEP and distance == _culled_distance:
		return
	_culled_at = at
	_culled_distance = distance
	for c: Vector2i in _chunks:
		_cull_one(c, _chunks[c], at)


## One chunk's clutter shown, and how much of it, from its distance to `at`.
func _cull_one(c: Vector2i, node: Node3D, at: Vector2) -> void:
	var area := Rect2(Vector2(c) * CHUNK, Vector2(CHUNK, CHUNK))
	var near := area.get_center() + (at - area.get_center()).clamp(-area.size * 0.5, area.size * 0.5)
	var d := near.distance_to(at)
	var share := 0.0 if d > distance else (1.0 if d <= FULL_DISTANCE or full_detail else (0.5 if d <= HALF_DISTANCE else 0.25))
	node.visible = share > 0.0
	if share > 0.0 and _shares.get(c, -1.0) != share:
		_shares[c] = share
		for inst in node.get_children():
			var mm := (inst as MultiMeshInstance3D).multimesh
			mm.visible_instance_count = ceili(mm.instance_count * share)


## 3D grass's centre this frame: the character (`at`) in the normal view; in front of the camera
## while it leads (an add-on's camera, first person, the remote view: view_priority.gd). The change
## glides (GRASS_GLIDE), and a jump further than the range fades the grass down, moves, and fades
## it back up, so it never pops.
const GRASS_GLIDE := 5.0  # per second
const GRASS_FADE := 4.0  # per second
func _grass_centre(at: Vector2) -> Vector2:
	if grass_range <= 0.0:
		_grass_offset = Vector2.ZERO
		_grass_fade = 1.0
		return at
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	var goal := ViewPriority.grass_centre(rig, camera, at, grass_range) - at
	var dt := get_process_delta_time()
	if goal.distance_to(_grass_offset) > grass_range:
		_grass_fade = maxf(_grass_fade - dt * GRASS_FADE, 0.0)
		if _grass_fade <= 0.0:
			_grass_offset = goal
	else:
		_grass_offset = _grass_offset.lerp(goal, 1.0 - exp(-dt * GRASS_GLIDE))
		_grass_fade = minf(_grass_fade + dt * GRASS_FADE, 1.0)
	return at + _grass_offset


## The shaders follow the grass's centre every frame; its chunks are queued and freed again once it
## has moved CULL_STEP or the range changed.
func _grass_follow(g: Vector2) -> void:
	_grass_view(g)
	if g.distance_squared_to(_grass_at) < CULL_STEP * CULL_STEP and grass_range == _grass_culled_range:
		return
	_grass_at = g
	_grass_culled_range = grass_range
	_cull_grass(g)


## The shaders' range and centre, every frame: the flat pictures and their raised copies ease by it.
func _grass_view(at: Vector2) -> void:
	if grass_range <= 0.0:
		return
	var zoom := _grass_zoom(at) * _grass_fade
	_grass_root.visible = zoom > 0.0
	RenderingServer.global_shader_parameter_set(&"f3d_grass", Vector4(at.x, at.y, grass_range, zoom))


## 1 close enough for height to show, 0 too far out, from the pixels a tile at the focus.
func _grass_zoom(at: Vector2) -> float:
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null:
		return 1.0
	var span := camera.size
	if camera.projection != Camera3D.PROJECTION_ORTHOGONAL:
		span = 2.0 * tan(deg_to_rad(camera.fov) * 0.5) * camera.global_position.distance_to(Vector3(at.x, 0.0, at.y))
	var px := get_viewport().get_visible_rect().size.y / maxf(span, 0.01)
	return clampf((px - GRASS_PX_OFF) / (GRASS_PX_FULL - GRASS_PX_OFF), 0.0, 1.0)


## Tiles from `at` to the chunk's nearest edge.
static func _chunk_distance(c: Vector2i, at: Vector2) -> float:
	var area := Rect2(Vector2(c) * CHUNK, Vector2(CHUNK, CHUNK))
	return (area.get_center() + (at - area.get_center()).clamp(-area.size * 0.5, area.size * 0.5)).distance_to(at)


## Queues chunks coming into range and frees those well past it.
func _cull_grass(at: Vector2) -> void:
	if grass_range <= 0.0:
		_grass_queue.clear()
		for c: Vector2i in _grass.keys():
			_free_grass(c)
		return
	for c: Vector2i in _grass_lists:
		if not _grass.has(c) and not _grass_queue.has(c) and _chunk_distance(c, at) <= grass_range + GRASS_MARGIN:
			_grass_queue.append(c)
	for c: Vector2i in _grass.keys():
		var d := _chunk_distance(c, at)
		_grass[c].visible = d <= grass_range
		if d > grass_range + GRASS_MARGIN + CHUNK * 0.5:
			_free_grass(c)


## One queued chunk a frame, the nearest: each MultiMesh that starts being drawn costs the renderer
## about 0.1 ms.
func _make_grass_some() -> void:
	if _grass_queue.is_empty():
		return
	var best := 0
	for i in _grass_queue.size():
		if _chunk_distance(_grass_queue[i], _grass_at) < _chunk_distance(_grass_queue[best], _grass_at):
			best = i
	var c := _grass_queue[best]
	_grass_queue.remove_at(best)
	if _grass_lists.has(c) and not _grass.has(c):
		_make_grass(c)


## The chunk's raised MultiMeshes: the first instances of the flat ones, over a grid.
func _make_grass(c: Vector2i) -> void:
	var node := Node3D.new()
	node.name = "Grass %d,%d" % [c.x, c.y]
	# Each mesh is flat until the shader raises it (and the hills lift it): bounds that hold it all.
	var bounds := AABB(Vector3(c.x * CHUNK - 8.0, -64.0, c.y * CHUNK - 8.0), Vector3(CHUNK + 16.0, 128.0, CHUNK + 16.0))
	for g: Array in _grass_lists[c]:
		var kind: Kind = g[0]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = kind.grass_mesh
		mm.instance_count = int(g[2])
		mm.buffer = g[1]
		var inst := MultiMeshInstance3D.new()
		inst.multimesh = mm
		inst.material_override = kind.grass_material
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		inst.custom_aabb = bounds
		node.add_child(inst)
	node.visible = _chunk_distance(c, _grass_at) <= grass_range
	_grass_root.add_child(node)
	_grass[c] = node


func _free_grass(c: Vector2i) -> void:
	var node: Node3D = _grass.get(c)
	if node != null:
		node.queue_free()
		_grass.erase(c)


## What the raised plants take now, exact: {chunks, multimeshes, instances, triangles}, and the same
## for those in the camera's view (view_*).
func grass_stats() -> Dictionary:
	var out := {"chunks": 0, "multimeshes": 0, "instances": 0, "triangles": 0,
		"view_chunks": 0, "view_multimeshes": 0, "view_instances": 0, "view_triangles": 0}
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	var planes: Array = camera.get_frustum() if camera != null else []
	for c: Vector2i in _grass:
		if not _grass[c].visible:
			continue
		var area := AABB(Vector3(c.x * CHUNK - 2.0, -2.0, c.y * CHUNK - 2.0), Vector3(CHUNK + 4.0, 6.0, CHUNK + 4.0))
		var seen := camera != null
		for p: Plane in planes:
			seen = seen and not p.is_point_over(area.get_support(-p.normal))
		var instances := 0
		var triangles := 0
		for g: Array in _grass_lists.get(c, []):
			instances += int(g[2])
			triangles += int(g[2]) * (g[0] as Kind).grass_triangles
		var meshes: int = _grass[c].get_child_count()
		out["chunks"] += 1
		out["multimeshes"] += meshes
		out["instances"] += instances
		out["triangles"] += triangles
		if seen:
			out["view_chunks"] += 1
			out["view_multimeshes"] += meshes
			out["view_instances"] += instances
			out["view_triangles"] += triangles
	return out


## --grass-stats: grass_stats() every 5 seconds, to read the budget on a real base.
func _print_grass_stats(delta: float) -> void:
	_grass_stats_at -= delta
	if _grass_stats_at > 0.0 or not OS.get_cmdline_user_args().has("--grass-stats"):
		if _grass_stats_at <= 0.0:
			_grass_stats_at = 1e9
		return
	_grass_stats_at = 5.0
	# With the frame's cost: the GPU's and CPU's time for the view and every triangle it drew.
	var vp := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	var stats := grass_stats()
	stats["gpu_ms"] = snappedf(RenderingServer.viewport_get_measured_render_time_gpu(vp), 0.01)
	stats["cpu_ms"] = snappedf(RenderingServer.viewport_get_measured_render_time_cpu(vp), 0.01)
	stats["frame_triangles"] = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	stats["fps"] = Engine.get_frames_per_second()
	print("GRASS ", stats)


func _drop(c: Vector2i) -> void:
	_lists.erase(c)
	_versions.erase(c)
	_shares.erase(c)
	_parts.erase(c)
	_grass_lists.erase(c)
	_free_grass(c)
	_masks.erase(c)
	_spills.erase(c)
	_edges.erase(c)
	_read_revs.erase(c)
	_full_pending.erase(c)
	if _mask_owner.get(_mask_slot(c)) == c:
		_write_mask(c, PackedInt32Array())
		_mask_owner.erase(_mask_slot(c))
	var node: Node3D = _chunks.get(c)
	if node != null:
		node.queue_free()
		_chunks.erase(c)


## Rebuilds a chunk's MultiMeshes from its list: [id, x, y, amount, ...], x and y the tile in the
## chunk. The work is done on a worker thread (_run_job); an empty list clears the chunk at once (its
## mask is still made, for its neighbours' pictures reaching over it). `mask_only`: the list is the
## same, only the ground under it may have changed.
func _build(c: Vector2i, mask_only := false) -> void:
	_last_version += 1
	var version := _last_version
	_versions[c] = version
	var l: Array = _lists.get(c, [])
	var data_dir := ItemIcons.factorio_data_dir()
	if data_dir == "":
		_replace(c, null)
		return
	if l.is_empty():
		_replace(c, null)
		_full_pending.erase(c)
		mask_only = true
	else:
		# A build of a new list still on its way is replaced by this one: it must show.
		mask_only = mask_only and not _full_pending.has(c)
		if not mask_only:
			_full_pending[c] = true
	# The mods' folders are found here, on the main thread: found first on the worker, the search
	# loads paths.gd there while the main thread may be waiting for that worker (finish_jobs,
	# quitting), and both wait for ever. Once found, this returns at once.
	ModFiles.prepare()
	index()  # a new list's index made here, never on a worker (_kind and _flat_priority read it here)
	var job := BuildJob.new()
	job.chunk = c
	job.version = version
	job.list = l
	job.density = density
	job.names = _names.duplicate()
	job.data_dir = data_dir
	job.mask_only = mask_only
	_mask_inputs(c, job)
	_jobs.append([WorkerThreadPool.add_task(_run_job.bind(job), false, "decoratives"), job])


## What the job's mask is made from, read here on the main thread: the chunk's tiles and records
## (world.gd's), the rules, and what its neighbours' last builds left.
func _mask_inputs(c: Vector2i, job: BuildJob) -> void:
	_refresh_rules()
	job.floors = _floors
	job.foot = _foot
	var cv = world.chunks.get(c) if world != null and is_instance_valid(world) else null
	if cv is Object:
		var tiles = cv.get("tile_ids")
		if tiles is PackedInt32Array:
			job.tiles = tiles
		var entities = cv.get("entities")
		if entities is Dictionary and not _foot.is_empty():
			job.recs = entities.values()
		var rev = cv.get("content_rev")
		if rev is int:
			_read_revs[c] = rev
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var n := c + Vector2i(dx, dy)
			if n == c:
				continue
			if _spills.has(n):
				job.spill_in.append_array(_spills[n])
			if _masks.has(n):
				job.near[Vector2i(dx, dy)] = _masks[n]


## Makes the MultiMeshes of finished jobs, oldest first, for up to `usec` (at least one chunk).
func _finish_jobs(usec: int) -> void:
	var start := Time.get_ticks_usec()
	var made := 0
	while not _jobs.is_empty():
		var entry: Array = _jobs[0]
		var waited := int(entry[0]) < 0
		if not (waited or WorkerThreadPool.is_task_completed(entry[0])) or (made > 0 and Time.get_ticks_usec() - start > usec):
			return
		_jobs.pop_front()
		if not waited:
			WorkerThreadPool.wait_for_task_completion(entry[0])
		var job: BuildJob = entry[1]
		if int(_versions.get(job.chunk, -1)) != job.version:
			continue  # built again since, or dropped
		var ground_changed := _take_mask(job)
		if not job.mask_only:
			_full_pending.erase(job.chunk)
		elif not ground_changed:
			continue  # a build or a tile that changed nothing here: the nodes stay
		_replace(job.chunk, _node_for(job))
		made += 1


## A finished job's mask kept and put in the texture; neighbours whose ground or tufts it can change
## are built again. True if this chunk's mask or its flat tufts changed.
func _take_mask(job: BuildJob) -> bool:
	var c := job.chunk
	var old: PackedInt32Array = _masks.get(c, PackedInt32Array())
	var mask_changed := old != job.mask
	var edge_changed: bool = _edges.get(c, []) != job.edge
	_masks[c] = job.mask
	_edges[c] = job.edge
	var slot := _mask_slot(c)
	if mask_changed and (_mask_rightful(c) or not _mask_owner.has(slot) or _mask_owner[slot] == c):
		_write_mask(c, job.mask)
	var touched := {}
	if mask_changed:
		_band_neighbours(c, old, job.mask, touched)
	var old_spill: PackedInt32Array = _spills.get(c, PackedInt32Array())
	if old_spill != job.spill:
		_spill_neighbours(c, old_spill, touched)
		_spill_neighbours(c, job.spill, touched)
		_spills[c] = job.spill
	for n: Vector2i in touched:
		if _lists.has(n):
			_restale[n] = true
	return mask_changed or edge_changed


## Neighbours whose tufts near the shared edge a change of this chunk's mask (old to new) can reach.
static func _band_neighbours(c: Vector2i, old: PackedInt32Array, new: PackedInt32Array, touched: Dictionary) -> void:
	var west_bits := (1 << MASK_BAND) - 1
	var east_bits := west_bits << (CHUNK - MASK_BAND)
	for y in CHUNK:
		var d: int = (old[y] if old.size() == CHUNK else 0) ^ (new[y] if new.size() == CHUNK else 0)
		if d == 0:
			continue
		var dy := -1 if y < MASK_BAND else (1 if y >= CHUNK - MASK_BAND else 0)
		var sides: Array[int] = [0]
		if (d & west_bits) != 0:
			sides.append(-1)
		if (d & east_bits) != 0:
			sides.append(1)
		for dx in sides:
			if dx != 0:
				touched[c + Vector2i(dx, 0)] = true
			if dy != 0:
				touched[c + Vector2i(dx, dy)] = true


## The chunks other than `c` that footprints [x0, y0, x1, y1, ...] (ends exclusive) reach.
static func _spill_neighbours(c: Vector2i, spill: PackedInt32Array, touched: Dictionary) -> void:
	for i in range(0, spill.size() - 3, 4):
		for cy in range(floori(spill[i + 1] / float(CHUNK)), floori((spill[i + 3] - 1) / float(CHUNK)) + 1):
			for cx in range(floori(spill[i] / float(CHUNK)), floori((spill[i + 2] - 1) / float(CHUNK)) + 1):
				if Vector2i(cx, cy) != c:
					touched[Vector2i(cx, cy)] = true


## Waits for every chunk being built and shows them (tests; a world being left).
func finish_jobs() -> void:
	_wait_all()
	_finish_jobs(1 << 30)


func _exit_tree() -> void:
	_wait_all()
	_jobs.clear()


## Waits for the jobs on worker threads (each only once: their task ids become -1).
func _wait_all() -> void:
	for entry in _jobs:
		if int(entry[0]) >= 0:
			WorkerThreadPool.wait_for_task_completion(entry[0])
			entry[0] = -1


func _replace(c: Vector2i, node: Node3D) -> void:
	var old: Node3D = _chunks.get(c)
	if old != null:
		old.queue_free()
		_chunks.erase(c)
	if node != null:
		_shares.erase(c)  # set again for the new MultiMeshes
		add_child(node)
		_chunks[c] = node
		# Only this chunk culled now, from where the last pass was: every chunk's clutter arriving
		# made the next frame cull all of them, nearly every frame while walking.
		if _culled_at.is_finite():
			_cull_one(c, node, _culled_at)
	# Made together with the flat pictures: those already darken under their raised copies.
	_free_grass(c)
	if _grass_lists.has(c) and grass_range > 0.0 and _grass_at.is_finite() and _chunk_distance(c, _grass_at) <= grass_range + GRASS_MARGIN:
		_make_grass(c)


## The chunk's node with a MultiMesh per decorative from a finished job, or null if it has none.
func _node_for(job: BuildJob) -> Node3D:
	_grass_lists.erase(job.chunk)
	if job.groups.is_empty():
		return null
	var raised: Array = []
	var node := Node3D.new()
	node.name = "Decor %d,%d" % [job.chunk.x, job.chunk.y]
	for g: Array in job.groups:
		var kind := _kind(str(g[0]), g[3])
		if kind == null:
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = kind.mesh
		mm.instance_count = int(g[2])
		mm.buffer = g[1]
		var inst := MultiMeshInstance3D.new()
		inst.multimesh = mm
		inst.material_override = kind.material
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(inst)
		var rising := int(g[4])
		if rising > 0 and kind.grass_mesh != null:
			raised.append([kind, (g[1] as PackedFloat32Array).slice(0, rising * STRIDE), rising])
	if not raised.is_empty():
		_grass_lists[job.chunk] = raised
	return node


## A chunk's clutter on a worker thread: per decorative its instances' transforms and atlas
## regions, in a fixed random order (so the first part of the list, drawn far away by _cull, is an
## even thinning); new decoratives' pictures are read here too.
static func _run_job(job: BuildJob) -> void:
	var c := job.chunk
	var l := job.list
	_mask_of(job)
	var mask := job.mask
	var flat_near := _any_blocked(job)
	var groups := {}  # id -> [x, y, ...] tiles kept
	for i in range(0, l.size() - 3, 4):
		var id := _int(l[i])
		var lx := _int(l[i + 1])
		var ly := _int(l[i + 2])
		if lx >= 0 and lx < CHUNK and ly >= 0 and ly < CHUNK and ((mask[ly] >> lx) & 1) == 1:
			continue  # on a floor or under a building
		var x := c.x * CHUNK + lx
		var y := c.y * CHUNK + ly
		if job.density < 1.0 and posmod(hash(Vector2i(x, y)), 1000) >= int(job.density * 1000.0):
			continue
		if not groups.has(id):
			groups[id] = []
		groups[id].append_array([x, y])
	# The chunk's raised plants within their budget: tufts and bushes first, carpets from what is
	# left, the same share of each kind of the two.
	var stand_triangles := 0
	var carpet_triangles := 0
	for id in groups:
		var grass_data := _kind_data_for(str(job.names.get(id, "")), job.data_dir)
		if grass_data != null and grass_data.grass_height > 0.0:
			var t: int = (groups[id].size() >> 1) * grass_data.grass_triangles
			if grass_data.grass_carpet:
				carpet_triangles += t
			else:
				stand_triangles += t
	var stand_share := minf(1.0, float(GRASS_CHUNK_TRIANGLES) / maxf(stand_triangles, 1.0))
	var carpet_share := clampf(float(GRASS_CHUNK_TRIANGLES - stand_triangles) / maxf(carpet_triangles, 1.0), 0.0, 1.0)
	for id in groups:
		var name := str(job.names.get(id, ""))
		var data := _kind_data_for(name, job.data_dir)
		if data == null:
			continue
		var tiles: Array = groups[id]
		var count := tiles.size() >> 1
		var order: Array = range(count)
		order.sort_custom(func(a: int, b: int) -> bool: return hash(Vector3i(tiles[a * 2], tiles[a * 2 + 1], 5)) < hash(Vector3i(tiles[b * 2], tiles[b * 2 + 1], 5)))
		var rising := 0
		if data.grass_height > 0.0:
			rising = floori(count * (carpet_share if data.grass_carpet else stand_share))
			# A tuft reaching over a floor or a building stays flat (its picture is cut at the edge):
			# those come last, so none of them is among the raised first part.
			if flat_near and not data.grass_carpet:
				var clear: Array = []
				var edge: Array = []
				for k: int in order:
					if _tuft_blocked(job, tiles[k * 2], tiles[k * 2 + 1], data):
						edge.append(k)
						job.edge.append_array([id, tiles[k * 2], tiles[k * 2 + 1]])
					else:
						clear.append(k)
				if not edge.is_empty():
					order = clear + edge
					rising = mini(rising, clear.size())
		var buffer := PackedFloat32Array()
		buffer.resize(count * STRIDE)
		for j in count:
			var k: int = order[j]
			var x: int = tiles[k * 2]
			var y: int = tiles[k * 2 + 1]
			var v := posmod(hash(Vector3i(x, y, 11)), data.uvs.size())
			var size: Vector2 = data.sizes[v]
			var shift: Vector2 = data.shifts[v]
			var lift := data.lift + TILE_STEP * posmod(hash(Vector2i(x, y)), TILE_STEPS)
			var origin := Vector3(x + 0.5 + shift.x, lift, y + 0.5 + shift.y)
			var scale := Vector3(size.x, 1.0, size.y)
			if data.upright:
				# Standing: the picture's bottom on the ground; its shift moves it sideways only.
				origin = Vector3(x + 0.5 + shift.x, 0.0, y + 0.5)
				scale = Vector3(size.x, size.y, 1.0)
			# The transform's rows (a scale, then the place), then the atlas region as custom data.
			var o := j * STRIDE
			buffer[o] = scale.x
			buffer[o + 3] = origin.x
			buffer[o + 5] = scale.y
			buffer[o + 7] = origin.y
			buffer[o + 10] = scale.z
			buffer[o + 11] = origin.z
			buffer[o + 12] = data.uvs[v].x
			buffer[o + 13] = data.uvs[v].y
			buffer[o + 14] = data.uvs[v].z
			# Over 0.5: has a raised copy (decorative_flat.gdshader); the fraction is the plant's root.
			buffer[o + 15] = 1.0 + data.uvs[v].w if j < rising else 0.0
		job.groups.append([name, buffer, count, data, rising])


## The job's mask (the header): floor tiles, then its buildings' footprints and those of its
## neighbours reaching into it. Its own reaching out are kept for the neighbours (job.spill).
static func _mask_of(job: BuildJob) -> void:
	var c := job.chunk
	var mask := PackedInt32Array()
	mask.resize(CHUNK)
	var kinds := job.floors.size()
	if job.tiles.size() == CHUNK * CHUNK and job.floors.has(1):
		for y in CHUNK:
			var row := 0
			var o := y * CHUNK
			for x in CHUNK:
				var id := job.tiles[o + x]
				if id >= 0 and id < kinds and job.floors[id] == 1:
					row |= 1 << x
			mask[y] = row
	var area := Rect2i(c * CHUNK, Vector2i(CHUNK, CHUNK))
	for r in job.recs:
		var f = job.foot.get(r.proto_id)
		if f == null:
			continue
		var box := footprint(r.pos, r.dir, f)
		_fill(mask, box, area)
		if not area.encloses(box):
			job.spill.append_array([box.position.x, box.position.y, box.end.x, box.end.y])
	var s := job.spill_in
	for i in range(0, s.size() - 3, 4):
		_fill(mask, Rect2i(s[i], s[i + 1], s[i + 2] - s[i], s[i + 3] - s[i + 1]), area)
	job.mask = mask


## The tiles a building covers: Factorio's tile size round its box's centre, both turned with it.
## `f` is Vector4(tiles across, down, box centre x, y) for it facing north.
static func footprint(pos: Vector2, dir: int, f: Vector4) -> Rect2i:
	var w := int(f.x)
	var h := int(f.y)
	var off := Vector2(f.z, f.w)
	match posmod(dir, 16):
		4:
			off = Vector2(-off.y, off.x)
			var t := w
			w = h
			h = t
		8:
			off = -off
		12:
			off = Vector2(off.y, -off.x)
			var t := w
			w = h
			h = t
	var centre := pos + off
	return Rect2i(roundi(centre.x - w * 0.5), roundi(centre.y - h * 0.5), w, h)


## Sets a box's bits in a chunk's mask, where it overlaps the chunk's `area`.
static func _fill(mask: PackedInt32Array, box: Rect2i, area: Rect2i) -> void:
	var o := box.intersection(area)
	if o.size.x <= 0 or o.size.y <= 0:
		return
	var bits := ((1 << o.size.x) - 1) << (o.position.x - area.position.x)
	for y in range(o.position.y - area.position.y, o.end.y - area.position.y):
		mask[y] = mask[y] | bits


## Whether the job's chunk or a neighbour has any blocked tile (else no tuft needs testing).
static func _any_blocked(job: BuildJob) -> bool:
	var masks: Array = job.near.values()
	masks.append(job.mask)
	for m: PackedInt32Array in masks:
		for row in m:
			if row != 0:
				return true
	return false


## Whether a map tile is blocked, by the job's mask or its neighbours' last ones.
static func _job_blocked(job: BuildJob, x: int, y: int) -> bool:
	var d := Vector2i(floori(x / float(CHUNK)), floori(y / float(CHUNK))) - job.chunk
	var m: PackedInt32Array = job.mask if d == Vector2i.ZERO else job.near.get(d, PackedInt32Array())
	return m.size() == CHUNK and ((m[posmod(y, CHUNK)] >> posmod(x, CHUNK)) & 1) == 1


## Whether a tuft at tile (x, y) would cover a blocked tile: its picture, and south of it as far as
## its raised blades lean along Factorio's camera ray (decorative_grass.gdshader).
static func _tuft_blocked(job: BuildJob, x: int, y: int, data: KindData) -> bool:
	var v := posmod(hash(Vector3i(x, y, 11)), data.uvs.size())
	var half: Vector2 = data.sizes[v] * 0.5
	var origin: Vector2 = Vector2(x + 0.5, y + 0.5) + data.shifts[v]
	var lean := data.grass_height * 0.9 + 0.1
	for ty in range(floori(origin.y - half.y), floori(origin.y + half.y + lean) + 1):
		for tx in range(floori(origin.x - half.x), floori(origin.x + half.x) + 1):
			if _job_blocked(job, tx, ty):
				return true
	return false


## The decorative ready to draw, made from its pictures (read by the job), or null.
static func _kind(name: String, data: KindData) -> Kind:
	if name == "":
		return null
	if _kinds.has(name):
		return _kinds[name]
	var kind: Kind = null
	if data != null:
		kind = Kind.new()
		kind.name = name
		kind.upright = data.upright
		kind.material = ShaderMaterial.new()
		kind.material.shader = SHADER if kind.upright else SHADER_FLAT
		var texture := ImageTexture.create_from_image(data.atlas)
		kind.material.set_shader_parameter("atlas", texture)
		data.atlas = null  # the texture has it now; jobs only read the regions
		if data.grass_height > 0.0:
			kind.grass_triangles = data.grass_triangles
			kind.grass_material = ShaderMaterial.new()
			kind.grass_material.set_shader_parameter("atlas", texture)
			if data.grass_carpet:
				kind.grass_mesh = _carpet_mesh(data.carpet_clumps)
				kind.grass_material.shader = SHADER_CARPET
				kind.grass_material.set_shader_parameter("cells", ImageTexture.create_from_image(data.carpet_cells))
				kind.grass_material.set_shader_parameter("variants", float(data.uvs.size()))
				kind.grass_material.set_shader_parameter("stretch", CARPET_STRETCH)
				kind.grass_material.set_shader_parameter("wind_noise", _wind_noise())
				kind.material.set_shader_parameter("raised_shade", CARPET_SHADE)
			else:
				kind.grass_mesh = _grass_mesh(data.grass_cells)
				kind.grass_material.shader = SHADER_GRASS
				kind.grass_material.set_shader_parameter("height", data.grass_height)
				kind.grass_material.set_shader_parameter("mass_lod", data.grass_lod)
				kind.grass_material.set_shader_parameter("tuft", data.grass_tuft)
			kind.grass_material.render_priority = _grass_priority(name)
		if kind.upright:
			kind.material.set_shader_parameter("upright", true)
		else:
			kind.material.render_priority = _flat_priority(name)
		if kind.upright:
			var quad := QuadMesh.new()
			quad.size = Vector2.ONE
			quad.center_offset = Vector3(0.0, 0.5, 0.0)
			kind.mesh = quad
		else:
			var plane := PlaneMesh.new()
			plane.size = Vector2.ONE
			kind.mesh = plane
	_kinds[name] = kind
	return kind


## The decorative's pictures as one atlas (variants side by side), or null without any. Read once,
## on whichever thread asks first (worker threads, from _run_job).
static func _kind_data_for(name: String, data_dir: String) -> KindData:
	if name == "":
		return null
	_kind_mutex.lock()
	if not _kind_data.has(name):
		var data: KindData = null
		var entry = index().get(name)
		if entry is Dictionary and data_dir != "":
			var images: Array[Image] = []
			var pics: Array = []
			var files := {}  # path -> Image, as a sheet holds several variants
			for pic in entry.get("pics", []):
				var image := _region(pic, files)
				if image != null:
					images.append(image)
					pics.append(pic)
			if not images.is_empty():
				data = _make_kind_data(name, entry, images, pics)
		_kind_data[name] = data
	var out: KindData = _kind_data[name]
	_kind_mutex.unlock()
	return out


static func _make_kind_data(name: String, entry: Dictionary, images: Array[Image], pics: Array) -> KindData:
	var cell := Vector2i.ZERO
	for image in images:
		cell = Vector2i(maxi(cell.x, image.get_width()), maxi(cell.y, image.get_height()))
	var atlas := Image.create(cell.x * images.size(), cell.y, false, Image.FORMAT_RGBA8)
	var kind := KindData.new()
	kind.name = name
	kind.upright = str(entry.get("layer", "")) == UPRIGHT_LAYER
	kind.lift = float(LAYER_LIFT.get(str(entry.get("layer", "")), 0.036))
	for i in images.size():
		var image := images[i]
		atlas.blit_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), Vector2i(i * cell.x, 0))
		var pic: Array = pics[i]
		var pic_scale := float(pic[5])
		kind.uvs.append(Vector4(float(i * cell.x) / atlas.get_width(), float(image.get_width()) / atlas.get_width(),
			float(image.get_height()) / atlas.get_height(), 0.0))
		kind.sizes.append(Vector2(image.get_width(), image.get_height()) * pic_scale / PX_PER_TILE)
		kind.shifts.append(Vector2(float(pic[6]), float(pic[7])))
	if is_grass(name, str(entry.get("layer", ""))):
		_size_grass(kind, pics, images, _box_of(entry))
	if not kind.upright:
		atlas.fix_alpha_edges()  # blended (decorative_flat.gdshader): mipmaps without dark rims
	atlas.generate_mipmaps()
	kind.atlas = atlas
	return kind


## Whether a decorative rises into 3D near the character.
static func is_grass(name: String, layer: String) -> bool:
	if layer != "decorative":
		return false
	for word: String in GRASS_WORDS:
		if name.contains(word):
			return true
	return false


## A raised decorative's shape, from its pictures. Height: knee-high at most (the character is 2
## tiles tall). Roots: where each picture's plant is centred, left out of its baked shadow, packed in
## its region's spare number (the shader unpacks it). Carpets, wide scatters of short blades, are clumps
## of their own picture's pieces (_carpet_cells).
static func _size_grass(kind: KindData, pics: Array, images: Array[Image], box: Rect2) -> void:
	var mean := Vector2.ZERO
	for s in kind.sizes:
		mean += s / kind.sizes.size()
	var span := maxf(mean.x, mean.y)
	var carpet := span > GRASS_CARPET
	var cover := 0.0
	for i in images.size():
		var plant := _plant_of(images[i])
		cover += plant.z / images.size()
		var root := Vector2(plant.x, plant.y).clamp(Vector2(0.2, 0.2), Vector2(0.8, 0.8))
		kind.uvs[i].w = floorf(root.x * 63.0) / 64.0 + floorf(root.y * 63.0) / 4096.0
	kind.grass_carpet = carpet
	kind.grass_tuft = not carpet and cover < GRASS_BUSH_COVER
	kind.grass_cells = GRASS_CELLS
	if carpet:
		_carpet_cells(kind, pics, images, box)
		kind.grass_height = CARPET_CLUMP.y / 0.9 * CARPET_STRETCH
		kind.grass_triangles = kind.carpet_clumps * 4
		return
	kind.grass_height = clampf(0.42 * sqrt(mean.x * mean.y), 0.2, 0.7)
	kind.grass_triangles = _grid_triangles(kind.grass_cells)
	var px_per_cell := span / kind.grass_cells * PX_PER_TILE / maxf(float(pics[0][5]), 0.01)
	kind.grass_lod = maxf(log(px_per_cell) / log(2.0) - 1.0, 0.0)


## A carpet's clumps: its pictures cut into pieces CARPET_CLUMP tiles, those with plant (not just
## baked shadow) kept, the CARPET_CLUMPS with most, north first. Only pieces rooted inside the decorative's own box stand (Factorio clears that box of
## decoratives where anything is built or a path is laid), so none rise on a belt or path beside the
## patch. Into an image the shader reads: (u, v, width, height) of each piece in its picture.
static func _carpet_cells(kind: KindData, pics: Array, images: Array[Image], box: Rect2) -> void:
	var per: Array = []
	var most := 1
	var keep := box.grow(0.25)
	for i in images.size():
		var image := images[i]
		var w := image.get_width()
		var h := image.get_height()
		var px := PX_PER_TILE / maxf(float(pics[i][5]), 0.01)
		var cw := maxi(2, roundi(CARPET_CLUMP.x * px))
		var ch := maxi(2, roundi(CARPET_CLUMP.y * px))
		var found: Array = []
		for y0 in range(0, h, ch):
			for x0 in range(0, w, cw):
				var x1 := mini(w, x0 + cw)
				var y1 := mini(h, y0 + ch)
				var plant := 0.0
				var samples := 0
				for y in range(y0, y1, 2):
					for x in range(x0, x1, 2):
						var c := image.get_pixel(x, y)
						plant += c.a if maxf(c.r, maxf(c.g, c.b)) > 0.03 else 0.0
						samples += 1
				if samples == 0 or plant / samples < CARPET_COVER:
					continue
				var piece := Vector4(float(x0) / w, float(y0) / h, float(x1 - x0) / w, float(y1 - y0) / h)
				var root := kind.shifts[i] + (Vector2(piece.x + 0.5 * piece.z, piece.y + piece.w) - Vector2(0.5, 0.5)) * kind.sizes[i]
				if keep.has_point(root):
					found.append([-plant / samples, piece])
		found.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
		found = found.slice(0, CARPET_CLUMPS)
		found.sort_custom(func(a: Array, b: Array) -> bool: return (a[1] as Vector4).y < (b[1] as Vector4).y)
		per.append(found)
		most = maxi(most, found.size())
	var cells := Image.create(most, images.size(), false, Image.FORMAT_RGBAF)
	cells.fill(Color(0.0, 0.0, 0.0, 0.0))
	for i in per.size():
		for j in (per[i] as Array).size():
			var p: Vector4 = per[i][j][1]
			cells.set_pixel(j, i, Color(p.x, p.y, p.z, p.w))
	kind.carpet_cells = cells
	kind.carpet_clumps = most


## A decorative's collision box from the index (tiles round its place), or a tile's.
static func _box_of(entry: Dictionary) -> Rect2:
	var b = entry.get("box")
	if b is Array and b.size() >= 4:
		return Rect2(float(b[0]), float(b[1]), float(b[2]) - float(b[0]), float(b[3]) - float(b[1]))
	return Rect2(-0.5, -0.5, 1.0, 1.0)


## Where a picture's plant is (x, y from 0 to 1) and how much of the picture it covers (z). Its baked
## shadow is black, the plant never is. Every 4th pixel is plenty.
static func _plant_of(image: Image) -> Vector3:
	var sum := Vector2.ZERO
	var weight := 0.0
	var samples := 0
	for y in range(0, image.get_height(), 4):
		for x in range(0, image.get_width(), 4):
			var c := image.get_pixel(x, y)
			var w := c.a if maxf(c.r, maxf(c.g, c.b)) > 0.1 else 0.0
			sum += Vector2(x + 0.5, y + 0.5) * w
			weight += w
			samples += 1
	if weight <= 0.0:
		return Vector3(0.5, 0.5, 0.0)
	return Vector3(sum.x / weight / image.get_width(), sum.y / weight / image.get_height(), weight / samples)


static func _grid_triangles(cells: int) -> int:
	return cells * cells * 2


## Seamless noise the carpet shader scrolls over the meadow for its gusts, made once (main thread).
static func _wind_noise() -> NoiseTexture2D:
	if _wind == null:
		var noise := FastNoiseLite.new()
		noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		noise.frequency = 0.02
		noise.fractal_octaves = 3
		_wind = NoiseTexture2D.new()
		_wind.width = 128
		_wind.height = 128
		_wind.seamless = true
		_wind.noise = noise
	return _wind


## A carpet's mesh: `clumps` clumps of two crossed cards (decorative_carpet.gdshader), each corner's
## VERTEX (across, down the picture, which card) and UV.x its clump. Shared by size (main thread).
static func _carpet_mesh(clumps: int) -> Mesh:
	var key := -clumps
	if not _grass_meshes.has(key):
		var verts := PackedVector3Array()
		var uvs := PackedVector2Array()
		var index := PackedInt32Array()
		for i in clumps:
			for card in 2:
				var base := verts.size()
				for corner: Vector2 in [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
					verts.append(Vector3(corner.x, corner.y, card))
					uvs.append(Vector2(i, 0))
				index.append_array([base, base + 1, base + 2, base + 1, base + 3, base + 2])
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_INDEX] = index
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		_grass_meshes[key] = mesh
	return _grass_meshes[key]


## The grid raised plants are drawn on, `cells` a side, shared between decoratives (main thread).
static func _grass_mesh(cells: int) -> Mesh:
	if not _grass_meshes.has(cells):
		var plane := PlaneMesh.new()
		plane.size = Vector2.ONE
		plane.subdivide_width = cells - 1
		plane.subdivide_depth = cells - 1
		_grass_meshes[cells] = plane
	return _grass_meshes[cells]


## A flat decorative's place in the fixed drawing order: blended pictures are otherwise sorted by
## distance, and overlapping ones of two kinds would swap as the camera moves. Factorio's layer
## first (decals under ground layers under floor under decoratives), then the name, spread over the
## render priorities up to -33, so the flat clutter is drawn before raised plants and other
## see-through things (ghosts, item cards). With more kinds than priorities a few neighbours share one.
static func _flat_priority(name: String) -> int:
	if _flat_order.is_empty():
		var flat: Array = []
		for n: String in index():
			var entry: Dictionary = index()[n]
			if str(entry.get("layer", "")) != UPRIGHT_LAYER:
				flat.append([float(LAYER_LIFT.get(str(entry.get("layer", "")), 0.036)), n])
		flat.sort()
		for i in flat.size():
			_flat_order[flat[i][1]] = i
	var rank := int(_flat_order.get(name, _flat_order.size()))
	return Material.RENDER_PRIORITY_MIN + mini(rank * FLAT_PRIORITIES / maxi(_flat_order.size(), 1), FLAT_PRIORITIES - 1)


## A raised decorative's place in its own fixed order, after every flat one: of one priority, kinds
## overlapping would be sorted by distance and swap as the camera moves.
static func _grass_priority(name: String) -> int:
	if _grass_order.is_empty():
		var names: Array = []
		for n: String in index():
			if is_grass(n, str(index()[n].get("layer", ""))):
				names.append(n)
		names.sort()
		for i in names.size():
			_grass_order[names[i]] = i
	var rank := int(_grass_order.get(name, _grass_order.size()))
	return Material.RENDER_PRIORITY_MIN + FLAT_PRIORITIES + mini(rank * GRASS_PRIORITIES / maxi(_grass_order.size(), 1), GRASS_PRIORITIES - 1)


## [file, x, y, width, height, scale, shift x, shift y] -> that region of the file, or null.
## The file is Factorio's path ("base/graphics/..." in decoratives.json, "__mod__/graphics/..." in the
## bridge's list), read through mod_files.gd.
static func _region(pic: Array, files: Dictionary) -> Image:
	if pic.size() < 8:
		return null
	var path := str(pic[0])
	var image: Image = files.get(path)
	if image == null:
		image = ModFiles.load_image(path)
		if image == null:
			return null
		image.convert(Image.FORMAT_RGBA8)
		files[path] = image
	var r := Rect2i(int(pic[1]), int(pic[2]), int(pic[3]), int(pic[4])).intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	if r.size.x <= 0 or r.size.y <= 0:
		return null
	return image.get_region(r)


## tools/decor_index.py's {name: {layer, box, pics}}, with the bridge's list (mod_graphics.gd: every
## mod's decoratives) over it; empty without either. A new list drops the pictures read for names
## it has, and those found missing, so they are read again from it. Made again on the main thread
## only (_process, _build): workers (_kind_data_for, under the mutex) read the one there is, as the
## main thread's _kind and _flat_priority read _kinds and _flat_order without it.
static func index() -> Dictionary:
	if _index_generation != ModGraphics.generation and OS.get_thread_caller_id() == OS.get_main_thread_id():
		_kind_mutex.lock()  # recursive: _kind_data_for asks while holding it
		_index_generation = ModGraphics.generation
		var merged := {}
		if FileAccess.file_exists(INDEX):
			var parsed = JSON.parse_string(FileAccess.get_file_as_string(INDEX))
			if parsed is Dictionary:
				merged = parsed
		merged.merge(ModGraphics.decor, true)
		# The pictures read before stay alive (_retired) until the chunks drawn with them are built
		# again: a freed texture would draw white meanwhile.
		_retired = [_kind_data.duplicate(), _kinds.duplicate()]
		for name in _kind_data.keys():
			if _kind_data[name] == null or ModGraphics.decor.has(name):
				_kind_data.erase(name)
				_kinds.erase(name)
		_flat_order = {}
		_grass_order = {}
		_index = merged
		_kind_mutex.unlock()
	return _index


static func _array(v) -> Array:
	return v if v is Array else []


## A number from the wire, 0 for anything else (null, a list, a string).
static func _int(v) -> int:
	return int(v) if v is int or v is float else 0
