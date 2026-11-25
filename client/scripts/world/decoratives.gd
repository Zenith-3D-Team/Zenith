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
## A chunk is built on a worker thread (D6: 10-55 ms each on the main thread while walking, and a
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

const NativeLibrary := preload("res://scripts/native_library.gd")
const FreeLater := preload("res://scripts/world/free_later.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
const ItemModels := preload("res://scripts/world/item_models.gd")
const ModFiles := preload("res://scripts/world/mod_files.gd")
const ModGraphics := preload("res://scripts/world/mod_graphics.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const FrameBudget := preload("res://scripts/world/frame_budget.gd")
const ViewPriority := preload("res://scripts/world/view_priority.gd")
const Probing := preload("res://scripts/debug/probing.gd")
const DecorSheetBaker := preload("res://scripts/world/decor_sheet_baker.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const WeatherState := preload("res://scripts/world/weather_state.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const SHADER := preload("res://shaders/decorative.gdshader")
const SHADER_FLAT := preload("res://shaders/decorative_flat.gdshader")
const SHADER_SHEET := preload("res://shaders/decorative_sheet.gdshader")
const SHADER_GRASS := preload("res://shaders/decorative_grass.gdshader")
const SHADER_CARPET := preload("res://shaders/decorative_carpet.gdshader")
const SHADER_MODEL := preload("res://shaders/decorative_model.gdshader")
const Switches := preload("res://scripts/switches.gd")
const Wire := preload("res://scripts/util/wire.gd")
## --grass-backlight=old: the ground plants' 0.2.2 specular and roughness, which glared white with the sun
## low behind them (decorative_grass.gdshaderinc plant_specular).
static var old_sheen_on: bool = Switches.has("--grass-backlight=old")
## --grass-opt=old: the ground plants' shaders from before the GPU optimisation (3D tufts and bushes blended
## in the transparent pass, carpet density 0.45/0.35, flat pictures with specular): the *_old.gdshader
## copies. --grass-backlight=old needs them too (the optimised shaders have no specular to bring back).
static var grass_opt_old: bool = Switches.has("--grass-opt=old")
static var legacy_shaders: bool = grass_opt_old or old_sheen_on
## --decor-composite=off: each chunk's baked flat-decorative sheet is a blended FlatSheet mesh over the ground,
## as before, not drawn by the ground's own shader (terrain_common.gdshaderinc, chunk_view.gd set_decor_sheet).
## The legacy plant shaders (--grass-opt=old, --grass-backlight=old) keep the separate sheets too.
static var decor_composite: bool = Switches.on("--decor-composite") and not legacy_shaders
const SHADER_FLAT_OLD := "res://shaders/decorative_flat_old.gdshader"
const SHADER_SHEET_OLD := "res://shaders/decorative_sheet_old.gdshader"
const SHADER_GRASS_OLD := "res://shaders/decorative_grass_old.gdshader"
const SHADER_CARPET_OLD := "res://shaders/decorative_carpet_old.gdshader"
## --grass-zoom-lines=raw: measure 3D grass pixel zoom on raw viewport lines instead of capping with ModelLods.
static var grass_cap_lines := not (Switches.has("--grass-zoom-lines=raw"))
## --decor-nodes=<n>: at most about n new decorative MultiMeshes put in a frame (whole chunks; the
## first chunk of a frame always goes in). Default 96; 0 no cap, as before (only the time slice).
## The owner's spike log: frames with 580-810 nodes appearing at once drew for 55-92 ms.
static var nodes_per_frame := _nodes_arg()


static func _nodes_arg() -> int:
	for a in Switches.args():
		if a.begins_with("--decor-nodes="):
			return maxi(int(a.get_slice("=", 1)), 0)
	return 96


const INDEX := "res://data/decoratives.json"

const CHUNK := 32
## Factorio's pictures: 32 pixels a tile at scale 1.
const PX_PER_TILE := 32.0
## Chunks further than this from the character (tiles, from the chunk's nearest edge) aren't drawn.
## Measured from the character, not the camera: the camera sits far back and up, so its own
## visibility range left the ground near the character bare and drew clutter behind it.
const DRAW_DISTANCE := 192.0
## Level of detail (B9): past FULL_DISTANCE a chunk draws half its clutter, past HALF_DISTANCE a
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
## Render priorities from the lowest: flat decoratives (-128..-33), ground area showcases
## (-32, GroundHeight.AREA_PRIORITY), then raised grass (-31..-2), under -1 (flat effects) and 0.
const FLAT_PRIORITIES := 96
const GRASS_PRIORITIES := 30
## Baked flat decorative chunk sheet (decor_sheet_baker.gd): flattens all flat MultiMeshes per chunk
## into one lit layer, sized by distance with a hysteresis band to avoid thrashing while walking.
const SHEET_LIFT := 0.024
const SHEET_PRIORITY := Material.RENDER_PRIORITY_MIN + FLAT_PRIORITIES - 1
const SHEET_NEAR_DIST := 24.0
const SHEET_MID_DIST := 80.0
const SHEET_HYSTERESIS := 16.0
const SHEET_SIZE_NEAR := 1024
const SHEET_SIZE_MID_COMPRESSED := 512
const SHEET_SIZE_MID_PLAIN := 512
const SHEET_SIZE_FAR := 256
## Sparse self-contained chunks with fewer flat instances than this (and no neighbor overhangs) keep
## their raw flat MultiMeshes instead of paying full-chunk transparent overdraw and a bake/readback.
const SHEET_MIN_FLAT := 24
## Tier-resize-only sheet re-bakes pause while focus moves faster than this (tiles/s) and stay paused
## for SHEET_MOVE_SETTLE_SEC after slowing down, eliminating mid-run SubViewport readbacks.
const SHEET_MOVE_FREEZE_SPEED := 6.0
const SHEET_MOVE_SETTLE_SEC := 0.5
const SHEET_HILLS_CELLS := 31
const FLAT_SHADE_TUFT := 0.55
const META_FLAT := &"f3d_flat"
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
	var kind: Kind  # made from it (_kind), on the main thread
	var texture: ImageTexture  # made with the atlas on the worker (texture_thread), else by _kind
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
	var carpet_texture: ImageTexture
	var carpet_clumps := 0
	var model_paths := PackedStringArray()
	var model_scale := 1.0
	var model_height_scale := 1.0
	var model_shift := Vector2.ZERO
	var model_rigid := false
	var has_flat := true
	## DecorNative's inputs, made once from the arrays above (nat_ready last).
	var nat_uvs := PackedFloat32Array()
	var nat_sizes := PackedFloat32Array()
	var nat_shifts := PackedFloat32Array()
	var nat_ready := false


## A decorative's atlas goes on the GPU on the worker thread that read its pictures
## (--decor-texture-thread=on, the default): made on the main thread when a chunk's clutter was put
## in, the first chunk's twenty-odd new kinds made a 115-135 ms frame once a join at -62,-26 (an
## atlas is up to a few MB with its mipmaps, and the renderer takes the upload on the calling thread).
## off: made by _kind on the main thread, as before.
static var texture_thread := Switches.on("--decor-texture-thread")
## --decor-parallel-load=off: holds _kind_mutex across decorative picture loading (one worker at a
## time, blocking main-thread index() swaps) as before.
static var parallel_kind_load := Switches.on("--decor-parallel-load")
## --native-decor=off: the per-decorative loops of a chunk's build (placement, order, instance buffers) stay
## in GDScript; else DecorNative (native/belt_sim/src/decor_native.cpp) does them when the library is there.
static var native_decor := Switches.on("--native-decor")
## Made once on the main thread (_build); its methods keep no state, so workers share it.
static var _decor_native: Object = null
## --decor-sheet=off: keeps flat decoratives as overlapping MultiMeshInstance3Ds per chunk.
static var sheet_enabled := Switches.on("--decor-sheet")
## Block-compress baked decorative sheets only when opted in via --decor-sheet-compress=on in
## editor builds (Image.compress S3TC fans across all WorkerThreadPool threads).
static var sheet_compress := OS.has_feature("editor") and (Switches.has("--decor-sheet-compress=on"))


## One decorative's pictures, ready to draw (made on the main thread from its KindData).
class Kind:
	var name := ""
	var material: ShaderMaterial
	var bake_material: ShaderMaterial
	var mesh: Mesh
	var upright := false
	var grass_mesh: Mesh  # null: stays flat
	var grass_material: ShaderMaterial
	var grass_triangles := 0
	var is_model := false
	var model_meshes: Array[Mesh] = []
	var model_materials: Array[ShaderMaterial] = []


## A chunk's clutter worked out on a worker thread: per decorative [name, buffer, instances, KindData,
## how many of them rise], plus edge overhangs reaching into adjacent chunks.
class BuildJob:
	var chunk := Vector2i.ZERO
	var version := 0
	var list: Array = []
	var density := 1.0
	var names := {}
	var groups: Array = []
	var edge_groups: Array = []  # [name, edge_buffer, edge_count, KindData]
	var edge_dirs := 0  # bitmask for dx, dy in -1..1
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
static var _packs_version := -1  # ModelPacks.decor_version last synced
static var _retired: Array = []
static var _kind_data := {}  # name -> KindData (null: no pictures), each holding the Kind made from it
static var _model_tris_cache := {}  # glb path -> int triangle count (guarded by _kind_mutex)
static var _model_mesh_cache := {}  # glb path -> [mtime, Mesh] (main thread only)
static var _flat_order := {}  # flat decorative -> its rank in the drawing order (_flat_priority)
static var _grass_order := {}  # raised decorative -> its rank in the drawing order (_grass_priority)
static var _grass_meshes := {}  # grid cells a side -> the grid; minus a carpet's clumps -> its mesh
static var _sheet_mesh_flat: PlaneMesh
static var _sheet_mesh_hills: PlaneMesh
static var _wind: NoiseTexture2D  # the carpets' gusts (_wind_noise)
## Worker threads read pictures one at a time (and each only once) under --decor-parallel-load=off.
static var _kind_mutex := Mutex.new()
## Per-decorative locks so workers load different decoratives in parallel without duplicating the
## same name, and without holding _kind_mutex across I/O (lock order: per-name lock -> _kind_mutex).
static var _kind_locks := {}  # name -> Mutex

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
var _built_packs_version := -1  # ModelPacks.decor_version the chunks were built with
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
## L14: the chunks the world let go are dropped every 2 s (_process's sweep), and after a screenshot zoomed
## far out that was the clutter of 4,000 chunks queued to be freed at once: 32,000 nodes, a 95-100 ms frame
## at the end of the sweep's frame. They go into _freeing too, freed FREE_USEC a frame (_free_some).
## `--unload-hide=off`: queue_free as before.
static var drop_sliced := Switches.on("--unload-hide")
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
var _relist: Array[Vector2i] = []  # a new graphics list's rebuild, nearest first (_build_some)
var _relist_at := 0
const BUILDS_MIN := 4
var _full_pending := {}  # Vector2i -> true: a build with a new list is on its way
var _mask_focus := Vector2i.ZERO  # the focus's chunk: chunks within MASK_CHUNKS / 2 of it own their place
var _mask_owner := {}  # Vector2i place in the texture -> the chunk whose mask is there
var _mask_bytes := PackedByteArray()
var _mask_image: Image
var _mask_texture: ImageTexture
var _mask_dirty := false
var _connected: Node
var _baker: Node
var _flat_groups := {}  # Vector2i -> Array of [Kind, buffer, count]
var _edge_flat := {}  # Vector2i -> Array of [Kind, edge_buffer, edge_count]
var _edge_dirs := {}  # Vector2i -> int direction bitmask of overhanging edges
var _sheet_gen := {}  # Vector2i -> int, bumped on each chunk rebuild or drop
var _sheet_size := {}  # Vector2i -> int baked texture resolution (0 if unbaked)
var _sheet_shade := {}  # Vector2i -> float weighted raised_shade for this chunk
var _sheet_tex := {}  # Vector2i -> ImageTexture: the chunk's baked sheet, drawn by its ground or a FlatSheet
var _composited := {}  # Vector2i -> true: that chunk's ground (chunk_view.gd) draws the sheet
var _composite_tick := 0
var _bake_dirty := {}  # Vector2i -> true: chunk sheet needs (re)baking or resize
var _sheet_content_dirty := {}  # Vector2i -> true: chunk sheet content/overhang changed (not resize-only)
var _sheet_move_pos := Vector2.INF
var _sheet_move_hold := 0.0
var _sheet_hills := false


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
	_drops.clear()
	_versions.clear()
	_masks.clear()
	_spills.clear()
	_edges.clear()
	_read_revs.clear()
	_restale.clear()
	_relist = []
	_relist_at = 0
	_full_pending.clear()
	_mask_owner.clear()
	_mask_bytes.fill(0)
	_mask_dirty = true
	_flat_groups.clear()
	_edge_flat.clear()
	_edge_dirs.clear()
	_drop_composites()
	_sheet_gen.clear()
	_sheet_size.clear()
	_sheet_shade.clear()
	_bake_dirty.clear()
	_sheet_content_dirty.clear()
	_sheet_move_pos = Vector2.INF
	_sheet_move_hold = 0.0
	if _baker != null:
		_baker.reset()
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
	# The sheets the ground draws itself go with the layer.
	RenderingServer.global_shader_parameter_set(&"f3d_decor_composite_on", 1.0 if on else 0.0)
	if rebuild:
		for c in _lists.keys():
			_build(c)


## Settings > Graphics > 3D grass: a GRASS_MODES key. Nothing is rebuilt: the flat pictures already
## know which of them rise, and the raised copies come and go by range.
func set_grass(mode: String) -> void:
	var m: Array = GRASS_MODES.get(mode, GRASS_MODES["off"])
	grass_range = m[0]
	grass_wind = m[1]
	WeatherState.base_grass_wind = grass_wind
	RenderingServer.global_shader_parameter_set(&"f3d_grass_wind", WeatherState.grass_wind_value())
	if grass_range <= 0.0:
		RenderingServer.global_shader_parameter_set(&"f3d_grass", Vector4.ZERO)


func handle(msg: Dictionary) -> void:
	match str(msg.get("t", "")):
		"dprotos":
			for rec in Wire.array(msg.get("l")):
				if rec is Array and rec.size() >= 2:
					_names[_int(rec[0])] = str(rec[1])
		"iuse":
			# The tiles items lay are the player's floors (ui_model.gd reads the rest of it).
			if _int(msg.get("part", 1)) == 1:
				_floor_names.clear()
			_floor_gen += 1
			for rec in Wire.array(msg.get("l")):
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
			(p["l"] as Array).append_array(Wire.array(msg.get("l")))
			if int(p["got"]) >= int(p["parts"]):
				_parts.erase(c)
				_lists[c] = p["l"]
				_build(c)


func _process(delta: float) -> void:
	var tp := Time.get_ticks_usec()
	_free_some()
	Probing.add("dc_free", tp)
	tp = Time.get_ticks_usec()
	_sync_packs()
	if _built_packs_version < 0:
		_built_packs_version = _packs_version
	if _built_generation != ModGraphics.generation or _built_packs_version != _packs_version:
		# A graphics list or model packs' decoratives changed: rebuild chunks nearest focus first.
		_built_generation = ModGraphics.generation
		_built_packs_version = _packs_version
		index()
		_relist = _near_first(_lists.keys())
		_relist_at = 0
	_watch_world()
	if _refresh_rules():
		for c in _lists.keys():
			_restale[c] = true
	Probing.add("dc_build", tp)
	var t0 := Time.get_ticks_usec()
	if _jobs.is_empty() and _restale.is_empty() and _relist_at >= _relist.size():
		FrameBudget.waiting(&"decoratives", 0)
	else:
		var allow := FrameBudget.grant(&"decoratives")
		_build_some(t0, allow)
		Probing.add("dc_build", t0)
		var tf := Time.get_ticks_usec()
		if allow > 0 and not _jobs.is_empty():
			_finish_jobs(maxi(allow - (tf - t0), 0))
		FrameBudget.spent(&"decoratives", Time.get_ticks_usec() - t0, _jobs.size() + _restale.size() + _relist.size() - _relist_at)
		Probing.add("dc_finish", tf)
	tp = Time.get_ticks_usec()
	_cull()
	Probing.add("dc_cull", tp)
	tp = Time.get_ticks_usec()
	_step_sheets(delta)
	Probing.add("dc_sheet", tp)
	tp = Time.get_ticks_usec()
	_upload_mask()
	Probing.add("dc_mask", tp)
	tp = Time.get_ticks_usec()
	_make_grass_some()
	Probing.add("dc_grass", tp)
	_print_grass_stats(delta)
	_sweep += delta
	if _sweep >= 2.0 and world != null and _drops.is_empty():
		_sweep = 0.0
		for c in _lists.keys():
			if not world.chunks.has(c):
				if drop_sliced:
					_drops.append(c)
				else:
					_drop(c)
	if not _drops.is_empty():
		tp = Time.get_ticks_usec()
		_drop_some()
		Probing.add("dc_drop", tp)


## The chunks the sweep found gone, dropped FREE_USEC a frame (drop_sliced): after a screenshot zoomed far
## out dropping all 4,000 in the sweep's frame was 30 ms. One that came back meanwhile stays.
var _drops: Array = []


func _drop_some() -> void:
	var t0 := Time.get_ticks_usec()
	while not _drops.is_empty():
		var c: Vector2i = _drops.pop_back()
		if world == null or not is_instance_valid(world) or not world.chunks.has(c):
			_drop(c)
		if Time.get_ticks_usec() - t0 > FREE_USEC:
			break


## Chunks to build again, a slice a frame (at least BUILDS_MIN, else half the decoratives' slice):
## those whose mask may have changed (_restale), then a graphics list's rebuild (_relist).
func _build_some(t0: int, allow: int) -> void:
	var built := 0
	for c: Vector2i in _restale.keys():
		if built >= BUILDS_MIN and Time.get_ticks_usec() - t0 > allow / 2:
			return
		_restale.erase(c)
		if _lists.has(c):
			_build(c, true)
			built += 1
	while _relist_at < _relist.size():
		if built >= BUILDS_MIN and Time.get_ticks_usec() - t0 > allow / 2:
			return
		var c := _relist[_relist_at]
		_relist_at += 1
		if _lists.has(c):
			_build(c)
			built += 1
	_relist = []
	_relist_at = 0


func _focus_xz() -> Vector2:
	if rig == null or not is_instance_valid(rig):
		return Vector2.INF
	if ViewPriority.camera_cone and rig.has_method("taken") and rig.taken() and rig.has_method("focus_point"):
		return rig.focus_point()
	var focus: Node3D = rig.get("target")
	if focus == null or not is_instance_valid(focus):
		return Vector2.INF
	return Vector2(focus.global_position.x, focus.global_position.z)


## Chunks nearest the camera's target first: bucketed by distance, not sorted with a GDScript
## comparison (thousands of chunks at a long view).
func _near_first(list: Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var at_xz := _focus_xz()
	if not at_xz.is_finite() or list.size() < 2:
		out.assign(list)
		return out
	var at := Vector2i(floori(at_xz.x / 32.0), floori(at_xz.y / 32.0))
	var buckets := {}
	for c: Vector2i in list:
		var d := (c - at).length_squared()
		if not buckets.has(d):
			buckets[d] = []
		(buckets[d] as Array).append(c)
	var distances: Array = buckets.keys()
	distances.sort()
	for d in distances:
		for c: Vector2i in buckets[d]:
			out.append(c)
	return out


## Listens to world.gd's changes (once it is set; tests stand in a world without them).
var _behind_watched: Object = null


func _watch_world() -> void:
	_watch_behind()
	if world == _connected or world == null or not is_instance_valid(world):
		return
	_connected = world
	if world.has_signal("entities_changed"):
		world.entities_changed.connect(_world_changed)
	if world.has_signal("tiles_changed"):
		world.tiles_changed.connect(_world_changed)


func _watch_behind() -> void:
	if world == null or not is_instance_valid(world):
		return
	var bc: Variant = world.get("behind_cull")
	if bc == _behind_watched or bc == null or not is_instance_valid(bc):
		return
	_behind_watched = bc
	if bc.has_signal("chunk_visibility_changed"):
		bc.chunk_visibility_changed.connect(_on_behind_visibility)


func _behind_hidden(c: Vector2i) -> bool:
	if not ViewPriority.tight_cull or world == null or not is_instance_valid(world):
		return false
	var bc: Variant = world.get("behind_cull")
	return bc != null and is_instance_valid(bc) and bc.is_active() and bc.hidden(c)


func _on_behind_visibility(c: Vector2i, drawn: bool) -> void:
	var node: Node3D = _chunks.get(c)
	if node != null:
		if not drawn:
			node.visible = false
		elif _culled_at.is_finite():
			_cull_one(c, node, _culled_at)
		else:
			node.visible = true
		_composite_visible(c, node.visible)
	var gnode: Node3D = _grass.get(c)
	if gnode != null:
		if not drawn:
			gnode.visible = false
		elif _grass_at.is_finite():
			gnode.visible = _grass_chunk_visible(c, _grass_at)


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


## The decoratives on a map tile (their ids, as `dec` lists them, whatever share is drawn): what the
## character's steps rustle through (fx.gd, the steps' sounds). Empty where no list came.
func ids_at(x: int, y: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var c := Vector2i(floori(x / float(CHUNK)), floori(y / float(CHUNK)))
	var list: Array = _lists.get(c, [])
	var lx := x - c.x * CHUNK
	var ly := y - c.y * CHUNK
	for i in range(0, list.size() - 3, 4):
		if _int(list[i + 1]) == lx and _int(list[i + 2]) == ly:
			out.append(_int(list[i]))
	return out


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
	return _jobs.is_empty() and _grass_queue.is_empty() and _grass_fade >= 1.0 and _restale.is_empty() and _relist_at >= _relist.size() \
		and not (_baker != null and (_baker.busy() or _has_eligible_bake()))


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
	for i in range(_relist_at, _relist.size()):
		if _lists.has(_relist[i]) and in_view.call(_relist[i]):
			n += 1
	for c: Vector2i in _grass_queue:
		if in_view.call(c):
			n += 1
	for c: Vector2i in _parts:
		if in_view.call(c):
			n += 1
	if _baker != null:
		for c: Vector2i in _bake_dirty:
			if _lists.has(c) and in_view.call(c):
				n += 1
		if _baker.busy():
			for c: Vector2i in _chunks:
				if in_view.call(c) and _baker.has_pending(c):
					n += 1
	return n


func freeing_count() -> int:
	return _freeing.size()


## Shows the chunks near the focus only: one distance per chunk, again whenever the focus has moved
## a little or the distance changed; a chunk whose MultiMeshes were just made is culled alone (_replace).
func _cull() -> void:
	_watch_behind()
	var at := _focus_xz()
	if not at.is_finite():
		return
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
	node.visible = share > 0.0 and not _behind_hidden(c)
	_composite_visible(c, node.visible)
	if share > 0.0 and _shares.get(c, -1.0) != share:
		_shares[c] = share
		for inst in node.get_children():
			if inst is MultiMeshInstance3D:
				var mm := (inst as MultiMeshInstance3D).multimesh
				mm.visible_instance_count = ceili(mm.instance_count * share)
	if sheet_enabled and share > 0.0 and _sheet_size.has(c):
		var want := sheet_size_for(c, at, int(_sheet_size[c]))
		if want != int(_sheet_size[c]):
			_bake_dirty[c] = true


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


func _grass_chunk_visible(c: Vector2i, at: Vector2, planes: Array[Plane] = []) -> bool:
	if _chunk_distance(c, at) > grass_range or _behind_hidden(c):
		return false
	if planes.is_empty():
		return true
	var area := GroundHeight.grow(AABB(Vector3(c.x * CHUNK - 2.0, -2.0, c.y * CHUNK - 2.0), Vector3(CHUNK + 4.0, 6.0, CHUNK + 4.0)))
	for p: Plane in planes:
		if p.is_point_over(area.get_support(-p.normal)):
			return false
	return true


## The shaders' range and centre, every frame: the flat pictures and their raised copies ease by it.
func _grass_view(at: Vector2) -> void:
	if grass_range <= 0.0:
		return
	var zoom := _grass_zoom(at) * _grass_fade
	_grass_root.visible = zoom > 0.0
	RenderingServer.global_shader_parameter_set(&"f3d_grass", Vector4(at.x, at.y, grass_range, zoom))
	if zoom > 0.0 and ViewPriority.tight_cull and not _grass.is_empty() and world != null and is_instance_valid(world):
		var bc: Variant = world.get("behind_cull")
		if bc != null and is_instance_valid(bc) and bc.is_active():
			var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
			var planes: Array[Plane] = ViewPriority.planes(camera) if camera != null else []
			for c: Vector2i in _grass:
				_grass[c].visible = _grass_chunk_visible(c, at, planes)


## 1 close enough for height to show, 0 too far out, from the pixels a tile at the focus.
func _grass_zoom(at: Vector2) -> float:
	if rig != null and not ViewPriority.lod_by_camera(rig):
		return 1.0
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null:
		return 1.0
	var span := camera.size
	if camera.projection != Camera3D.PROJECTION_ORTHOGONAL:
		span = 2.0 * tan(deg_to_rad(camera.fov) * 0.5) * camera.global_position.distance_to(Vector3(at.x, 0.0, at.y))
	var lines := get_viewport().get_visible_rect().size.y
	if grass_cap_lines:
		lines = ModelLods.counted_lines(lines)
	var px := lines / maxf(span, 0.01)
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
		_grass[c].visible = _grass_chunk_visible(c, at)
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
	var flat_bounds := AABB(Vector3(c.x * CHUNK - 8.0, -2.0, c.y * CHUNK - 8.0), Vector3(CHUNK + 16.0, 6.0, CHUNK + 16.0))
	var legacy_bounds := AABB(Vector3(c.x * CHUNK - 8.0, -64.0, c.y * CHUNK - 8.0), Vector3(CHUNK + 16.0, 128.0, CHUNK + 16.0))
	for g: Array in _grass_lists[c]:
		var kind: Kind = g[0]
		var mesh_use: Mesh = kind.grass_mesh
		var mat_use: ShaderMaterial = kind.grass_material
		if kind.is_model and g.size() >= 4:
			var vi := int(g[3])
			if vi >= 0 and vi < kind.model_meshes.size():
				mesh_use = kind.model_meshes[vi]
				mat_use = kind.model_materials[vi]
		if mesh_use == null or mat_use == null:
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = mesh_use
		mm.instance_count = int(g[2])
		mm.buffer = g[1]
		var inst := MultiMeshInstance3D.new()
		inst.multimesh = mm
		inst.material_override = mat_use
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		inst.layers = Visuals.GROUND_LAYER  # ground cover: the fill light leaves it (looks.gd fill_light)
		if ViewPriority.tight_cull:
			GroundHeight.cull_box(inst, flat_bounds)
		else:
			inst.custom_aabb = legacy_bounds
		node.add_child(inst)
	node.visible = _grass_chunk_visible(c, _grass_at)
	_grass_root.add_child(node)
	_grass[c] = node


func _free_grass(c: Vector2i) -> void:
	var node: Node3D = _grass.get(c)
	if node != null:
		FreeLater.node(node)
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
		var flat_area := AABB(Vector3(c.x * CHUNK - 2.0, -2.0, c.y * CHUNK - 2.0), Vector3(CHUNK + 4.0, 6.0, CHUNK + 4.0))
		var area := GroundHeight.grow(flat_area) if ViewPriority.tight_cull else flat_area
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
	if _grass_stats_at > 0.0 or not Switches.has("--grass-stats"):
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
	_clear_flat_sheet_state(c)
	_sheet_gen.erase(c)
	if _mask_owner.get(_mask_slot(c)) == c:
		_write_mask(c, PackedInt32Array())
		_mask_owner.erase(_mask_slot(c))
	var node: Node3D = _chunks.get(c)
	if node != null:
		_chunks.erase(c)
		if drop_sliced:
			node.visible = false
			_freeing.append(node)  # freed FREE_USEC a frame, the last dropped first (_free_some)
		else:
			FreeLater.node(node)


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
	if data_dir == "" and not ModelPacks.has_any_decoratives() and ModGraphics.decor.is_empty():
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
	_ensure_native()
	index()  # a new list's index made here, never on a worker (_kind and _flat_priority read it here)
	var job := BuildJob.new()
	job.chunk = c
	job.version = version
	job.list = l
	job.density = density
	job.names = _names.duplicate()
	job.mask_only = mask_only
	_mask_inputs(c, job)
	_jobs.append([WorkerThreadPool.add_task(_run_job.bind(job), false, "decoratives"), job])


static func _ensure_native() -> void:
	if native_decor and _decor_native == null and NativeLibrary.ensure() and ClassDB.class_exists(&"DecorNative"):
		_decor_native = ClassDB.instantiate(&"DecorNative")


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
func _finish_jobs(usec: int, node_cap := -1) -> void:
	var start := Time.get_ticks_usec()
	var made := 0
	var nodes := 0
	var cap := nodes_per_frame if node_cap < 0 else node_cap
	while not _jobs.is_empty():
		var entry: Array = _jobs[0]
		var waited := int(entry[0]) < 0
		if not (waited or WorkerThreadPool.is_task_completed(entry[0])) or (made > 0 and Time.get_ticks_usec() - start > usec):
			return
		if made > 0 and cap > 0 and nodes >= cap:
			return  # the rest next frame: each new MultiMesh is work for the render thread
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
		var built := _node_for(job)
		if built != null:
			nodes += built.get_child_count()
		_replace(job.chunk, built)
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
	_finish_jobs(1 << 30, 0)


func _exit_tree() -> void:
	_wait_all()
	_jobs.clear()
	if _baker != null:
		_baker.shutdown()


## Waits for the jobs on worker threads (each only once: their task ids become -1).
func _wait_all() -> void:
	for entry in _jobs:
		if int(entry[0]) >= 0:
			WorkerThreadPool.wait_for_task_completion(entry[0])
			entry[0] = -1


func _replace(c: Vector2i, node: Node3D) -> void:
	var old: Node3D = _chunks.get(c)
	if old != null and node != null and sheet_enabled and _flat_groups.has(c) and not _chunk_fully_blocked(c):
		var kept_sheet: MeshInstance3D = old.get_node_or_null("FlatSheet") as MeshInstance3D
		if kept_sheet != null:
			old.remove_child(kept_sheet)
			node.add_child(kept_sheet)
	if old != null:
		FreeLater.node(old)
		_chunks.erase(c)
	if node == null:
		_clear_flat_sheet_state(c)
	else:
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
	var c := job.chunk
	_grass_lists.erase(c)
	if job.groups.is_empty():
		return null
	var raised: Array = []
	var flat_list: Array = []
	var shade_sum := 0.0
	var rising_total := 0
	var old_chunk: Node3D = _chunks.get(c)
	var has_existing_sheet := sheet_enabled and not _chunk_fully_blocked(c) and old_chunk != null and not old_chunk.is_queued_for_deletion() and (old_chunk.get_node_or_null("FlatSheet") != null or _composited.has(c))
	var node := Node3D.new()
	node.name = "Decor %d,%d" % [c.x, c.y]
	var flat_bounds := AABB(Vector3(c.x * CHUNK - 8.0, -2.0, c.y * CHUNK - 8.0), Vector3(CHUNK + 16.0, 6.0, CHUNK + 16.0))
	for g: Array in job.groups:
		var tk := Time.get_ticks_usec()
		var kind := _kind(str(g[0]), g[3])
		Probing.add("dc_kinds", tk)
		if kind == null:
			continue
		var is_flat := not kind.upright
		if is_flat and kind.mesh != null:
			flat_list.append([kind, g[1], int(g[2])])
		if is_flat and has_existing_sheet:
			pass  # keep the chunk's existing FlatSheet drawn until its updated sheet finishes baking
		elif is_flat and kind.mesh == null:
			pass  # 3D grass model without a 2D flat fallback picture (e.g. no Factorio install)
		elif kind.upright and kind.is_model:
			var buckets: Array = g[5] if g.size() >= 6 else []
			for vi in mini(buckets.size(), kind.model_meshes.size()):
				var bentry: Array = buckets[vi]
				var bcnt := int(bentry[1])
				if bcnt <= 0 or kind.model_meshes[vi] == null:
					continue
				tk = Time.get_ticks_usec()
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.use_custom_data = true
				mm.mesh = kind.model_meshes[vi]
				mm.instance_count = bcnt
				mm.buffer = bentry[0]
				var inst := MultiMeshInstance3D.new()
				inst.multimesh = mm
				inst.material_override = kind.model_materials[vi]
				inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				if ViewPriority.tight_cull:
					GroundHeight.cull_box(inst, flat_bounds)
				node.add_child(inst)
				Probing.add("dc_multimeshes", tk)
		else:
			tk = Time.get_ticks_usec()
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
			if is_flat:
				inst.layers = Visuals.GROUND_LAYER  # lying flat: ground, which the fill light leaves (looks.gd fill_light)
				inst.set_meta(META_FLAT, true)
			node.add_child(inst)
			Probing.add("dc_multimeshes", tk)
		var rising := int(g[4])
		if rising > 0 and kind.grass_mesh != null:
			var data: KindData = g[3]
			if kind.is_model and g.size() >= 6:
				var mbuckets: Array = g[5]
				var added_model := false
				for vi in mini(mbuckets.size(), kind.model_meshes.size()):
					var bentry: Array = mbuckets[vi]
					var bcnt := int(bentry[1])
					if bcnt > 0 and kind.model_meshes[vi] != null:
						raised.append([kind, bentry[0], bcnt, vi])
						added_model = true
				if not added_model:
					raised.append([kind, (g[1] as PackedFloat32Array).slice(0, rising * STRIDE), rising])
			else:
				raised.append([kind, (g[1] as PackedFloat32Array).slice(0, rising * STRIDE), rising])
			shade_sum += float(rising) * (CARPET_SHADE if data.grass_carpet else FLAT_SHADE_TUFT)
			rising_total += rising
	if not raised.is_empty():
		_grass_lists[c] = raised
	var edge_list: Array = []
	for eg: Array in job.edge_groups:
		var ekind := _kind(str(eg[0]), eg[3])
		if ekind != null and not ekind.upright:
			edge_list.append([ekind, eg[1], int(eg[2])])
	var shade := shade_sum / rising_total if rising_total > 0 else 0.0
	_record_flat_sheet_state(c, flat_list, edge_list, job.edge_dirs if not edge_list.is_empty() else 0, shade, has_existing_sheet and not flat_list.is_empty())
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
	var nat: Object = _decor_native
	if nat != null:
		var placed: Dictionary = nat.call("place", PackedInt32Array(l), c.x, c.y, mask, job.density)
		var pids: PackedInt32Array = placed["ids"]
		var ptiles: Array = placed["tiles"]
		for pi in pids.size():
			groups[pids[pi]] = ptiles[pi]
	for i in (range(0, l.size() - 3, 4) if nat == null else range(0)):
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
		var grass_data := _kind_data_for(str(job.names.get(id, "")))
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
		var data := _kind_data_for(name)
		if data == null:
			continue
		var tiles = groups[id]
		var count: int = tiles.size() >> 1
		if nat != null:
			_fill_native(nat, job, name, data, tiles, flat_near, carpet_share if data.grass_carpet else stand_share, id)
			continue
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
		var edge_floats: Array = []
		var edge_mask := 0
		var x0_c := float(c.x * CHUNK)
		var z0_c := float(c.y * CHUNK)
		var x1_c := x0_c + CHUNK
		var z1_c := z0_c + CHUNK
		var has_models := not data.model_paths.is_empty()
		var model_count := data.model_paths.size()
		var bucket_arrs: Array = []
		if has_models:
			for _vi in model_count:
				bucket_arrs.append([])
		for j in count:
			var k: int = order[j]
			var x: int = tiles[k * 2]
			var y: int = tiles[k * 2 + 1]
			var v := posmod(hash(Vector3i(x, y, 11)), maxi(data.uvs.size(), 1))
			var size: Vector2 = data.sizes[v] if v < data.sizes.size() else Vector2.ONE
			var shift: Vector2 = data.shifts[v] if v < data.shifts.size() else Vector2.ZERO
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
			var uv4: Vector4 = data.uvs[v] if v < data.uvs.size() else Vector4.ZERO
			buffer[o + 12] = uv4.x
			buffer[o + 13] = uv4.y
			buffer[o + 14] = uv4.z
			# Over 0.5: has a raised copy (decorative_flat.gdshader); the fraction is the plant's root.
			buffer[o + 15] = 1.0 + uv4.w if j < rising else 0.0
			if has_models and (data.upright or j < rising):
				var mv := posmod(hash(Vector3i(x, y, 19)), model_count)
				var ang := float(hash(Vector3i(x, y, 23)) & 0xffff) / 65536.0 * TAU
				var cs := cos(ang)
				var sn := sin(ang)
				var js := (0.86 + 0.28 * (float(hash(Vector3i(x, y, 29)) & 0xffff) / 65536.0)) * data.model_scale
				var jy := js * data.model_height_scale
				var phase := float(hash(Vector3i(x, y, 31)) & 0xffff) / 65536.0
				var mox := float(x) + 0.5 + data.model_shift.x
				var moz := float(y) + 0.5 + data.model_shift.y
				var barr: Array = bucket_arrs[mv]
				barr.append_array([
					cs * js, 0.0, sn * js, mox,
					0.0, jy, 0.0, 0.0,
					-sn * js, 0.0, cs * js, moz,
					phase, 0.0, 0.0, 0.0])
			if not data.upright and data.has_flat:
				var min_x := origin.x - scale.x * 0.5
				var max_x := origin.x + scale.x * 0.5
				var min_z := origin.z - scale.z * 0.5
				var max_z := origin.z + scale.z * 0.5
				var ddx0 := -1 if min_x < x0_c else 0
				var ddx1 := 1 if max_x > x1_c else 0
				var ddy0 := -1 if min_z < z0_c else 0
				var ddy1 := 1 if max_z > z1_c else 0
				if ddx0 != 0 or ddx1 != 0 or ddy0 != 0 or ddy1 != 0:
					for dy in range(ddy0, ddy1 + 1):
						for dx in range(ddx0, ddx1 + 1):
							if dx != 0 or dy != 0:
								edge_mask |= _dir_bit(dx, dy)
					edge_floats.append_array([
						scale.x, 0.0, 0.0, origin.x,
						0.0, scale.y, 0.0, origin.y,
						0.0, 0.0, scale.z, origin.z,
						buffer[o + 12], buffer[o + 13], buffer[o + 14], buffer[o + 15]])
		if has_models:
			var buckets: Array = []
			for barr: Array in bucket_arrs:
				buckets.append([PackedFloat32Array(barr), barr.size() / STRIDE])
			job.groups.append([name, buffer, count, data, rising, buckets])
		else:
			job.groups.append([name, buffer, count, data, rising])
		if not edge_floats.is_empty():
			job.edge_groups.append([name, PackedFloat32Array(edge_floats), edge_floats.size() / STRIDE, data])
			job.edge_dirs |= edge_mask


## One kind's instances through DecorNative: the same as the loop in _run_job (order, raised first part,
## buffer, edge list, model buckets), appended to the job's groups.
static func _fill_native(nat: Object, job: BuildJob, name: String, data: KindData, tiles: PackedInt32Array, flat_near: bool, share: float, id: int) -> void:
	if not data.nat_ready:
		var uv := PackedFloat32Array()
		for u: Vector4 in data.uvs:
			uv.append_array([u.x, u.y, u.z, u.w])
		var sz := PackedFloat32Array()
		for v: Vector2 in data.sizes:
			sz.append_array([v.x, v.y])
		var sh := PackedFloat32Array()
		for v: Vector2 in data.shifts:
			sh.append_array([v.x, v.y])
		data.nat_uvs = uv
		data.nat_sizes = sz
		data.nat_shifts = sh
		data.nat_ready = true
	var count := tiles.size() >> 1
	var rising := 0
	if data.grass_height > 0.0:
		rising = floori(count * share)
	var blocks: Array = []
	if flat_near and data.grass_height > 0.0 and not data.grass_carpet:
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				blocks.append(job.mask if dx == 0 and dy == 0 else job.near.get(Vector2i(dx, dy), PackedInt32Array()))
	var cfg := {
		"cx": job.chunk.x, "cy": job.chunk.y, "upright": data.upright, "has_flat": data.has_flat,
		"lift": data.lift, "grass_height": data.grass_height, "grass_carpet": data.grass_carpet,
		"rising": rising, "flat_near": flat_near and not blocks.is_empty(),
		"model_count": data.model_paths.size(), "model_scale": data.model_scale,
		"model_hs": data.model_height_scale, "model_shift": data.model_shift,
	}
	var r: Dictionary = nat.call("fill_group", tiles, cfg, data.nat_uvs, data.nat_sizes, data.nat_shifts, blocks)
	rising = int(r["rising"])
	var buffer: PackedFloat32Array = r["buffer"]
	var edge_tiles: PackedInt32Array = r["edge_tiles"]
	for i in range(0, edge_tiles.size() - 1, 2):
		job.edge.append_array([id, edge_tiles[i], edge_tiles[i + 1]])
	if data.model_paths.size() > 0:
		var buckets: Array = []
		for barr: PackedFloat32Array in r["buckets"]:
			buckets.append([barr, barr.size() / STRIDE])
		job.groups.append([name, buffer, count, data, rising, buckets])
	else:
		job.groups.append([name, buffer, count, data, rising])
	var edge_floats: PackedFloat32Array = r["edge_floats"]
	if not edge_floats.is_empty():
		job.edge_groups.append([name, edge_floats, edge_floats.size() / STRIDE, data])
		job.edge_dirs |= int(r["edge_mask"])


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


## The decorative ready to draw, made from its pictures (read by the job), or null. Made once per
## KindData and kept on it: a job started before a new graphics list (mod_graphics.gd) finishes with the
## old list's KindData, whose atlas went into its first Kind. A cache by name, which the new list
## empties, made a second Kind from the spent atlas ("Invalid image: null", six of them in a cold join)
## and kept that one, without a picture, for the session.
static func _is_rigid_decor(name: String) -> bool:
	for word: String in ["stump", "coral", "barnacle", "ruin", "iceberg", "fungus", "rock"]:
		if name.contains(word):
			return true
	return false


static func _cached_model_tris(path: String, fallback: int) -> int:
	_kind_mutex.lock()
	var t := int(_model_tris_cache.get(path, fallback))
	_kind_mutex.unlock()
	return t


static func _mesh_tris(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var total := 0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var idx: Variant = arrays[Mesh.ARRAY_INDEX]
		if idx is PackedInt32Array and not (idx as PackedInt32Array).is_empty():
			total += (idx as PackedInt32Array).size() / 3
		elif arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array:
			total += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return total


static func _read_decor_mesh(path: String) -> Mesh:
	var mtime := FileAccess.get_modified_time(path)
	var cached: Variant = _model_mesh_cache.get(path)
	if cached is Array and (cached as Array).size() >= 2 and int((cached as Array)[0]) == mtime:
		return (cached as Array)[1] as Mesh
	var mesh := ItemModels.read(path)
	if mesh != null:
		_model_mesh_cache[path] = [mtime, mesh]
		var tris := _mesh_tris(mesh)
		if tris > 0:
			_kind_mutex.lock()
			_model_tris_cache[path] = tris
			_kind_mutex.unlock()
	return mesh


static func _kind(name: String, data: KindData) -> Kind:
	if name == "" or data == null:
		return null
	if data.kind != null:
		return data.kind
	var kind: Kind = null
	var has_models := not data.model_paths.is_empty()
	if data.atlas != null or has_models:
		kind = Kind.new()
		kind.name = name
		kind.upright = data.upright
		var texture: ImageTexture = null
		if data.atlas != null and data.has_flat:
			var t0 := Time.get_ticks_usec()
			kind.material = ShaderMaterial.new()
			kind.material.shader = SHADER if kind.upright else _plant_shader(SHADER_FLAT, SHADER_FLAT_OLD)
			if old_sheen_on:
				kind.material.set_shader_parameter(&"old_sheen", true)
			Probing.add("dc_k_material", t0)
			t0 = Time.get_ticks_usec()
			texture = data.texture if data.texture != null else ImageTexture.create_from_image(data.atlas)
			Probing.add("dc_k_texture", t0)
			t0 = Time.get_ticks_usec()
			kind.material.set_shader_parameter("atlas", texture)
			Probing.add("dc_k_param", t0)
			data.atlas = null  # the texture has it now; jobs only read the regions
			data.texture = null
			t0 = Time.get_ticks_usec()
			if kind.upright:
				kind.material.set_shader_parameter("upright", true)
				var quad := QuadMesh.new()
				quad.size = Vector2.ONE
				quad.center_offset = Vector3(0.0, 0.5, 0.0)
				kind.mesh = quad
			else:
				var prio := _flat_priority(name)
				kind.material.render_priority = prio
				kind.bake_material = ShaderMaterial.new()
				kind.bake_material.shader = DecorSheetBaker.SHADER_BAKE
				kind.bake_material.set_shader_parameter("atlas", texture)
				kind.bake_material.render_priority = prio
				var plane := PlaneMesh.new()
				plane.size = Vector2.ONE
				kind.mesh = plane
			Probing.add("dc_k_priority", t0)
		if has_models:
			var first_tris := 0
			for p: String in data.model_paths:
				var m := _read_decor_mesh(p)
				var mat := ShaderMaterial.new()
				mat.shader = SHADER_MODEL
				mat.set_shader_parameter(&"grass_mode", not kind.upright)
				mat.set_shader_parameter(&"sway_enabled", not data.model_rigid)
				mat.set_shader_parameter(&"follow_slope", (not kind.upright) and data.grass_carpet)
				mat.set_shader_parameter(&"exposure", 0.85)
				if old_sheen_on:
					mat.set_shader_parameter(&"old_sheen", true)
				if m != null and m.has_meta(ItemModels.PICTURE_META):
					mat.set_shader_parameter(&"use_picture", true)
					mat.set_shader_parameter(&"picture", m.get_meta(ItemModels.PICTURE_META))
				kind.model_meshes.append(m)
				kind.model_materials.append(mat)
				if first_tris <= 0 and m != null:
					first_tris = _mesh_tris(m)
			if not kind.model_meshes.is_empty() and kind.model_meshes[0] != null:
				kind.is_model = true
				if not kind.upright:
					kind.grass_mesh = kind.model_meshes[0]
					kind.grass_material = kind.model_materials[0]
					kind.grass_triangles = maxi(first_tris, data.grass_triangles)
					if kind.material != null:
						kind.material.set_shader_parameter("raised_shade", CARPET_SHADE if data.grass_carpet else 0.0)
		elif data.grass_height > 0.0 and texture != null:
			var tg := Time.get_ticks_usec()
			kind.grass_triangles = data.grass_triangles
			kind.grass_material = ShaderMaterial.new()
			kind.grass_material.set_shader_parameter("atlas", texture)
			if old_sheen_on:
				kind.grass_material.set_shader_parameter(&"old_sheen", true)
			if data.grass_carpet:
				kind.grass_mesh = _carpet_mesh(data.carpet_clumps)
				kind.grass_material.shader = _plant_shader(SHADER_CARPET, SHADER_CARPET_OLD)
				var cells_tex: ImageTexture = data.carpet_texture if data.carpet_texture != null else ImageTexture.create_from_image(data.carpet_cells)
				kind.grass_material.set_shader_parameter("cells", cells_tex)
				data.carpet_texture = null
				kind.grass_material.set_shader_parameter("variants", float(data.uvs.size()))
				kind.grass_material.set_shader_parameter("stretch", CARPET_STRETCH)
				kind.grass_material.set_shader_parameter("wind_noise", _wind_noise())
				kind.material.set_shader_parameter("raised_shade", CARPET_SHADE)
			else:
				kind.grass_mesh = _grass_mesh(data.grass_cells)
				kind.grass_material.shader = _plant_shader(SHADER_GRASS, SHADER_GRASS_OLD)
				kind.grass_material.set_shader_parameter("height", data.grass_height)
				kind.grass_material.set_shader_parameter("mass_lod", data.grass_lod)
				kind.grass_material.set_shader_parameter("tuft", data.grass_tuft)
			kind.grass_material.render_priority = _grass_priority(name)
			Probing.add("dc_k_grass", tg)
	data.kind = kind
	return kind


## The decorative's pictures as one atlas (variants side by side), or null without any. Read once,
## on whichever thread asks first (worker threads, from _run_job). Each picture is read through
## model_packs.gd first (when a pack overrides it), else mod_files.gd (install / mods).
static func _kind_data_for(name: String) -> KindData:
	if name == "":
		return null
	_sync_packs()
	index()
	if not parallel_kind_load:
		_kind_mutex.lock()
		if not _kind_data.has(name):
			_kind_data[name] = _load_kind_data(name, _index.get(name))
		var legacy_out: KindData = _kind_data[name]
		_kind_mutex.unlock()
		return legacy_out
	_kind_mutex.lock()
	if _kind_data.has(name):
		var cached: KindData = _kind_data[name]
		_kind_mutex.unlock()
		return cached
	var k_lock: Mutex = _kind_locks.get(name)
	if k_lock == null:
		k_lock = Mutex.new()
		_kind_locks[name] = k_lock
	_kind_mutex.unlock()
	k_lock.lock()
	_kind_mutex.lock()
	if _kind_data.has(name):
		var found: KindData = _kind_data[name]
		_kind_mutex.unlock()
		k_lock.unlock()
		return found
	var entry: Variant = _index.get(name)
	var gen := _index_generation
	var pver := _packs_version
	_kind_mutex.unlock()
	var data := _load_kind_data(name, entry)
	_kind_mutex.lock()
	if _index_generation == gen and _packs_version == pver:
		if not _kind_data.has(name):
			_kind_data[name] = data
		else:
			data = _kind_data[name]
	_kind_mutex.unlock()
	k_lock.unlock()
	return data


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


static func _load_install_kind_data(name: String, entry: Dictionary) -> KindData:
	var images: Array[Image] = []
	var pics: Array = []
	var files := {}  # path -> Image, as a sheet holds several variants
	for pic in entry.get("pics", []):
		var image := _region(pic, files)
		if image != null:
			images.append(image)
			pics.append(pic)
	return _make_kind_data(name, entry, images, pics) if not images.is_empty() else null


static func _load_kind_data(name: String, entry: Variant) -> KindData:
	var pack_src := ModelPacks.decor_source(name, false)
	if pack_src.is_empty() and not (entry is Dictionary):
		pack_src = ModelPacks.decor_source(name, true)
	var base_entry: Dictionary = entry if entry is Dictionary else {}
	if not pack_src.is_empty():
		var spec: Dictionary = pack_src.get("spec", {})
		if bool(spec.get("hide", false)):
			return null
		var files: Array = pack_src.get("files", [])
		var mods: Array = pack_src.get("models", [])
		var pimages: Array[Image] = []
		for f: Variant in files:
			var im := _load_pack_image(str(f))
			if im != null:
				pimages.append(im)
		if not mods.is_empty():
			var layer := str(spec.get("layer", base_entry.get("layer", "decorative")))
			var upright := layer == UPRIGHT_LAYER
			var raises: bool = bool(spec["grass"]) if spec.has("grass") else is_grass(name, layer)
			if not upright and not raises:
				upright = true
			var mshift := Vector2.ZERO
			if spec.get("shift") is Array and (spec["shift"] as Array).size() >= 2:
				var sa: Array = spec["shift"]
				mshift = Vector2(float(sa[0]), float(sa[1]))
			var mscale := maxf(float(spec.get("scale", 1.0)), 0.05)
			if not upright and raises:
				var kd: KindData = null
				if not pimages.is_empty():
					kd = _make_pack_kind_data(name, base_entry, pimages, spec)
				elif not base_entry.is_empty():
					kd = _load_install_kind_data(name, base_entry)
				if kd == null:
					kd = KindData.new()
					kd.name = name
					kd.upright = false
					kd.has_flat = false
					kd.lift = float(LAYER_LIFT.get(layer, 0.036))
					kd.uvs.append(Vector4.ZERO)
					kd.sizes.append(Vector2.ONE)
					kd.shifts.append(mshift)
				kd.model_paths = PackedStringArray(mods)
				var style := str(spec.get("grass_style", "auto"))
				kd.grass_carpet = (style == "carpet") or (style == "auto" and name.contains("carpet"))
				kd.grass_height = maxf(float(spec.get("grass_height", 0.35)), 0.05)
				kd.grass_triangles = _cached_model_tris(str(mods[0]), 64 if kd.grass_carpet else 36)
				kd.model_scale = mscale
				kd.model_height_scale = (float(spec["grass_height"]) / 0.35) if spec.has("grass_height") else 1.0
				kd.model_rigid = _is_rigid_decor(name)
				kd.model_shift = mshift
				return kd
			var ukd := KindData.new()
			ukd.name = name
			ukd.upright = true
			ukd.has_flat = false
			ukd.lift = float(LAYER_LIFT.get(layer, 0.036))
			ukd.model_paths = PackedStringArray(mods)
			ukd.model_scale = mscale
			ukd.model_rigid = _is_rigid_decor(name)
			ukd.model_shift = mshift
			for _m in mods.size():
				ukd.uvs.append(Vector4.ZERO)
				ukd.sizes.append(Vector2.ONE)
				ukd.shifts.append(mshift)
			return ukd
		if not pimages.is_empty():
			return _make_pack_kind_data(name, base_entry, pimages, spec)
	if not (entry is Dictionary):
		return null
	return _load_install_kind_data(name, base_entry)


static func _make_pack_kind_data(name: String, base_entry: Dictionary, images: Array[Image], spec: Dictionary) -> KindData:
	var cell := Vector2i.ZERO
	for image in images:
		cell = Vector2i(maxi(cell.x, image.get_width()), maxi(cell.y, image.get_height()))
	var atlas := Image.create(cell.x * images.size(), cell.y, false, Image.FORMAT_RGBA8)
	var kind := KindData.new()
	kind.name = name
	var layer := str(spec.get("layer", base_entry.get("layer", "decorative")))
	kind.upright = layer == UPRIGHT_LAYER
	kind.lift = float(LAYER_LIFT.get(layer, 0.036))
	var mean_span := 0.0
	var base_pics: Variant = base_entry.get("pics")
	if base_pics is Array and not (base_pics as Array).is_empty():
		for bp: Variant in (base_pics as Array):
			if bp is Array and (bp as Array).size() >= 6:
				var psc := float((bp as Array)[5])
				mean_span += maxf(float((bp as Array)[3]) * psc / PX_PER_TILE, float((bp as Array)[4]) * psc / PX_PER_TILE)
		mean_span /= float((base_pics as Array).size())
	var shift := Vector2.ZERO
	if spec.get("shift") is Array and (spec["shift"] as Array).size() >= 2:
		var sa: Array = spec["shift"]
		shift = Vector2(float(sa[0]), float(sa[1]))
	var synth_pics: Array = []
	var mean_size := Vector2.ZERO
	for i in images.size():
		var image := images[i]
		atlas.blit_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), Vector2i(i * cell.x, 0))
		var iw := float(maxi(image.get_width(), 1))
		var ih := float(maxi(image.get_height(), 1))
		var size := Vector2.ZERO
		var pic_scale := 0.5
		if spec.has("size"):
			var sz: Array = spec["size"]
			size = Vector2(float(sz[0]), float(sz[1]))
			pic_scale = maxf(size.x * PX_PER_TILE / iw, size.y * PX_PER_TILE / ih)
		elif spec.has("scale"):
			pic_scale = float(spec["scale"])
			size = Vector2(iw, ih) * pic_scale / PX_PER_TILE
		elif mean_span > 0.0:
			pic_scale = mean_span * PX_PER_TILE / maxf(iw, ih)
			size = Vector2(iw, ih) * pic_scale / PX_PER_TILE
		else:
			pic_scale = 0.5
			size = Vector2(iw, ih) * pic_scale / PX_PER_TILE
		kind.uvs.append(Vector4(float(i * cell.x) / atlas.get_width(), iw / atlas.get_width(),
			ih / atlas.get_height(), 0.0))
		kind.sizes.append(size)
		kind.shifts.append(shift)
		mean_size += size / float(images.size())
		synth_pics.append(["", 0, 0, int(iw), int(ih), pic_scale, shift.x, shift.y])
	var raises: bool = bool(spec["grass"]) if spec.has("grass") else is_grass(name, layer)
	if raises and not kind.upright:
		var box := _box_of(base_entry) if base_entry.has("box") else Rect2(-mean_size * 0.5, mean_size)
		_size_grass(kind, synth_pics, images, box, spec)
	if not kind.upright:
		atlas.fix_alpha_edges()
	atlas.generate_mipmaps()
	kind.atlas = atlas
	if texture_thread:
		kind.texture = ImageTexture.create_from_image(atlas)
		if kind.carpet_cells != null:
			kind.carpet_texture = ImageTexture.create_from_image(kind.carpet_cells)
	return kind


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
	if texture_thread:
		kind.texture = ImageTexture.create_from_image(atlas)
		if kind.carpet_cells != null:
			kind.carpet_texture = ImageTexture.create_from_image(kind.carpet_cells)
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
static func _size_grass(kind: KindData, pics: Array, images: Array[Image], box: Rect2, spec := {}) -> void:
	var mean := Vector2.ZERO
	for s in kind.sizes:
		mean += s / kind.sizes.size()
	var span := maxf(mean.x, mean.y)
	var style := str(spec.get("grass_style", "auto"))
	var carpet := (style == "carpet") if style != "auto" else (span > GRASS_CARPET)
	var cover := 0.0
	for i in images.size():
		var plant := _plant_of(images[i])
		cover += plant.z / images.size()
		var root := Vector2(plant.x, plant.y).clamp(Vector2(0.2, 0.2), Vector2(0.8, 0.8))
		kind.uvs[i].w = floorf(root.x * 63.0) / 64.0 + floorf(root.y * 63.0) / 4096.0
	kind.grass_carpet = carpet
	if style == "tuft":
		kind.grass_tuft = true
	elif style == "bush":
		kind.grass_tuft = false
	else:
		kind.grass_tuft = not carpet and cover < GRASS_BUSH_COVER
	kind.grass_cells = GRASS_CELLS
	if carpet:
		_carpet_cells(kind, pics, images, box)
		kind.grass_height = float(spec["grass_height"]) if spec.has("grass_height") else (CARPET_CLUMP.y / 0.9 * CARPET_STRETCH)
		kind.grass_triangles = kind.carpet_clumps * 4
		return
	kind.grass_height = float(spec["grass_height"]) if spec.has("grass_height") else clampf(0.42 * sqrt(mean.x * mean.y), 0.2, 0.7)
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
		var packs_used := ModelPacks.has_any_decoratives()
		for n: String in index():
			var entry: Dictionary = index()[n]
			var layer := str(entry.get("layer", ""))
			if packs_used:
				var src := ModelPacks.decor_source(n, true)
				if not src.is_empty():
					layer = str((src.get("spec", {}) as Dictionary).get("layer", layer))
			if layer != UPRIGHT_LAYER:
				flat.append([float(LAYER_LIFT.get(layer, 0.036)), n])
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
		var packs_used := ModelPacks.has_any_decoratives()
		for n: String in index():
			var layer := str(index()[n].get("layer", ""))
			var raises := is_grass(n, layer)
			if packs_used:
				var src := ModelPacks.decor_source(n, true)
				if not src.is_empty():
					var sp: Dictionary = src.get("spec", {})
					layer = str(sp.get("layer", layer))
					raises = bool(sp["grass"]) if sp.has("grass") else is_grass(n, layer)
			if raises and layer != UPRIGHT_LAYER:
				names.append(n)
		names.sort()
		for i in names.size():
			_grass_order[names[i]] = i
	var rank := int(_grass_order.get(name, _grass_order.size()))
	return Material.RENDER_PRIORITY_MIN + FLAT_PRIORITIES + 1 + mini(rank * GRASS_PRIORITIES / maxi(_grass_order.size(), 1), GRASS_PRIORITIES - 1)


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


static func _sync_packs() -> void:
	if _packs_version < 0:
		ModelPacks.active()
		_packs_version = ModelPacks.decor_version
		return
	if _packs_version == ModelPacks.decor_version:
		return
	_packs_version = ModelPacks.decor_version
	_kind_mutex.lock()
	# Keep previously built textures alive in _retired while chunks rebuild on worker threads.
	_retired = [_kind_data.duplicate()]
	_kind_data.clear()
	_flat_order = {}
	_grass_order = {}
	_model_tris_cache.clear()
	_kind_mutex.unlock()
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		_model_mesh_cache.clear()


## tools/decor_index.py's {name: {layer, box, pics}}, with the bridge's list (mod_graphics.gd: every
## mod's decoratives) over it; empty without either. A new list drops the pictures read for names
## it has, and those found missing, so they are read again from it. Made again on the main thread
## only (_process, _build): workers (_kind_data_for, under the mutex) read the one there is, as the
## main thread's _kind and _flat_priority read their KindData's Kind and _flat_order without it.
static func index() -> Dictionary:
	_sync_packs()
	if _index_generation != ModGraphics.generation and OS.get_thread_caller_id() == OS.get_main_thread_id():
		var target_gen := ModGraphics.generation
		var merged := {}
		if FileAccess.file_exists(INDEX):
			var parsed = JSON.parse_string(FileAccess.get_file_as_string(INDEX))
			if parsed is Dictionary:
				merged = parsed
		merged.merge(ModGraphics.decor, true)
		_kind_mutex.lock()
		_index_generation = target_gen
		# The pictures read before (each KindData with its Kind) stay alive (_retired) until the chunks
		# drawn with them are built again: a freed texture would draw white meanwhile.
		_retired = [_kind_data.duplicate()]
		for name in _kind_data.keys():
			if _kind_data[name] == null or ModGraphics.decor.has(name):
				_kind_data.erase(name)
		_flat_order = {}
		_grass_order = {}
		_index = merged
		_kind_mutex.unlock()
	return _index


## A number from the wire, 0 for anything else (null, a list, a string).
static func _int(v) -> int:
	return int(v) if v is int or v is float else 0


static func _dir_bit(dx: int, dy: int) -> int:
	return 1 << ((dy + 1) * 3 + (dx + 1))


## Sheet resolution for a chunk from its edge distance to the focus, with a hysteresis band around
## thresholds so walking near a boundary does not repeatedly re-bake at alternating sizes.
static func sheet_size_for(c: Vector2i, at: Vector2, current_size: int = 0, compressed: bool = sheet_compress) -> int:
	if not at.is_finite():
		return SHEET_SIZE_MID_PLAIN
	var d := _chunk_distance(c, at)
	var mid := SHEET_SIZE_MID_COMPRESSED if compressed else SHEET_SIZE_MID_PLAIN
	if current_size <= 0:
		if d <= SHEET_NEAR_DIST:
			return SHEET_SIZE_NEAR
		return mid if d <= SHEET_MID_DIST else SHEET_SIZE_FAR
	if current_size >= SHEET_SIZE_NEAR:
		if d <= SHEET_NEAR_DIST + SHEET_HYSTERESIS:
			return SHEET_SIZE_NEAR
		return mid if d <= SHEET_MID_DIST else SHEET_SIZE_FAR
	if current_size > SHEET_SIZE_FAR:
		if d <= SHEET_NEAR_DIST:
			return SHEET_SIZE_NEAR
		if d > SHEET_MID_DIST + SHEET_HYSTERESIS:
			return SHEET_SIZE_FAR
		return mid
	if d <= SHEET_NEAR_DIST:
		return SHEET_SIZE_NEAR
	return mid if d <= SHEET_MID_DIST else SHEET_SIZE_FAR


static func _edges_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		var ea: Array = a[i]
		var eb: Array = b[i]
		if (ea[0] as Kind).name != (eb[0] as Kind).name or int(ea[2]) != int(eb[2]):
			return false
		if (ea[1] as PackedFloat32Array) != (eb[1] as PackedFloat32Array):
			return false
	return true


## The optimised shader, or with --grass-opt=old (or --grass-backlight=old) the legacy copy at old_path.
static func _plant_shader(optimised: Shader, old_path: String) -> Shader:
	if legacy_shaders:
		return load(old_path) as Shader
	return optimised


static func _sheet_mesh(hills: bool) -> PlaneMesh:
	if hills:
		if _sheet_mesh_hills == null:
			_sheet_mesh_hills = PlaneMesh.new()
			_sheet_mesh_hills.size = Vector2(CHUNK, CHUNK)
			_sheet_mesh_hills.subdivide_width = SHEET_HILLS_CELLS
			_sheet_mesh_hills.subdivide_depth = SHEET_HILLS_CELLS
		return _sheet_mesh_hills
	if _sheet_mesh_flat == null:
		_sheet_mesh_flat = PlaneMesh.new()
		_sheet_mesh_flat.size = Vector2(CHUNK, CHUNK)
	return _sheet_mesh_flat


func _chunk_fully_blocked(c: Vector2i) -> bool:
	var mask: PackedInt32Array = _masks.get(c, PackedInt32Array())
	if mask.size() != CHUNK:
		return false
	for row: int in mask:
		if (row & 0xFFFFFFFF) != 0xFFFFFFFF:
			return false
	return true


static func _flat_instance_count(flat_list: Array) -> int:
	var n := 0
	for entry: Array in flat_list:
		n += int(entry[2])
	return n


func _mark_overhang_neighbors(c: Vector2i, mask: int) -> void:
	if mask == 0 or not sheet_enabled:
		return
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			if (mask & _dir_bit(dx, dy)) == 0:
				continue
			var n := c + Vector2i(dx, dy)
			if _lists.has(n) and not _chunk_fully_blocked(n):
				_bake_dirty[n] = true
				_sheet_content_dirty[n] = true


func _has_neighbor_overhang(c: Vector2i) -> bool:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var n := c + Vector2i(dx, dy)
			if (int(_edge_dirs.get(n, 0)) & _dir_bit(-dx, -dy)) != 0:
				return true
	return false


func _record_flat_sheet_state(c: Vector2i, flat_list: Array, edge_list: Array, new_dirs: int, shade: float, keep_sheet := false) -> void:
	var old_edges: Array = _edge_flat.get(c, [])
	var old_dirs := int(_edge_dirs.get(c, 0))
	if flat_list.is_empty():
		_flat_groups.erase(c)
	else:
		_flat_groups[c] = flat_list
	if edge_list.is_empty() or new_dirs == 0:
		_edge_flat.erase(c)
		_edge_dirs.erase(c)
		new_dirs = 0
	else:
		_edge_flat[c] = edge_list
		_edge_dirs[c] = new_dirs
	_sheet_shade[c] = shade
	_sheet_gen[c] = int(_sheet_gen.get(c, 0)) + 1
	if not keep_sheet:
		_sheet_size.erase(c)
	if sheet_enabled and (old_dirs != new_dirs or not _edges_equal(old_edges, edge_list)):
		_mark_overhang_neighbors(c, old_dirs | new_dirs)
	if _chunk_fully_blocked(c):
		_sheet_size.erase(c)
		_bake_dirty.erase(c)
		_sheet_content_dirty.erase(c)
		return
	var neighbor_in := _has_neighbor_overhang(c)
	var want_sheet := neighbor_in or (not flat_list.is_empty() and (keep_sheet or new_dirs != 0 or _flat_instance_count(flat_list) >= SHEET_MIN_FLAT))
	if sheet_enabled and want_sheet:
		_bake_dirty[c] = true
		_sheet_content_dirty[c] = true
	else:
		_bake_dirty.erase(c)
		_sheet_content_dirty.erase(c)
		_drop_composite(c)
		_sheet_size.erase(c)


func _clear_flat_sheet_state(c: Vector2i) -> void:
	_drop_composite(c)
	var old_dirs := int(_edge_dirs.get(c, 0))
	_flat_groups.erase(c)
	_edge_flat.erase(c)
	_edge_dirs.erase(c)
	_sheet_shade.erase(c)
	_sheet_size.erase(c)
	_sheet_gen[c] = int(_sheet_gen.get(c, 0)) + 1
	if sheet_enabled and old_dirs != 0:
		_mark_overhang_neighbors(c, old_dirs)
	if sheet_enabled and _lists.has(c) and not _chunk_fully_blocked(c) and _has_neighbor_overhang(c):
		_bake_dirty[c] = true
		_sheet_content_dirty[c] = true
	else:
		_bake_dirty.erase(c)
		_sheet_content_dirty.erase(c)


func _collect_sheet_sources(c: Vector2i) -> Array:
	var out: Array = []
	for entry: Array in _flat_groups.get(c, []):
		var kind: Kind = entry[0]
		if kind != null and kind.bake_material != null:
			out.append([kind.mesh, kind.bake_material, entry[1], entry[2]])
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var n := c + Vector2i(dx, dy)
			if (int(_edge_dirs.get(n, 0)) & _dir_bit(-dx, -dy)) == 0:
				continue
			for e: Array in _edge_flat.get(n, []):
				var ekind: Kind = e[0]
				if ekind != null and ekind.bake_material != null:
					out.append([ekind.mesh, ekind.bake_material, e[1], e[2]])
	return out


func _sync_sheet_hills() -> void:
	if _sheet_hills == GroundHeight._on:
		return
	_sheet_hills = GroundHeight._on
	var m := _sheet_mesh(_sheet_hills)
	for node: Node3D in _chunks.values():
		for ch: Node in node.get_children():
			if ch is MeshInstance3D and ch.get_meta(META_FLAT, false):
				(ch as MeshInstance3D).mesh = m


func _update_sheet_move(delta: float) -> void:
	var at := _focus_xz()
	if not at.is_finite() or delta <= 0.0:
		_sheet_move_hold = maxf(_sheet_move_hold - maxf(delta, 0.0), 0.0)
		return
	if _sheet_move_pos.is_finite():
		var speed := at.distance_to(_sheet_move_pos) / delta
		if speed >= SHEET_MOVE_FREEZE_SPEED:
			_sheet_move_hold = SHEET_MOVE_SETTLE_SEC
		else:
			_sheet_move_hold = maxf(_sheet_move_hold - delta, 0.0)
	_sheet_move_pos = at


func _has_eligible_bake() -> bool:
	for c: Vector2i in _bake_dirty:
		if not _lists.has(c) or _chunk_fully_blocked(c):
			continue
		if _sheet_size.has(c) and not _sheet_content_dirty.has(c) and _sheet_move_hold > 0.0:
			continue
		if not _culled_at.is_finite() or _chunk_distance(c, _culled_at) <= distance:
			return true
	return false


func _step_sheets(delta: float) -> void:
	_sync_sheet_hills()
	_update_sheet_move(delta)
	_sync_composites()
	if not sheet_enabled or not enabled or not DecorSheetBaker.gpu_available():
		return
	if _baker == null and is_inside_tree():
		_baker = DecorSheetBaker.new()
		_baker.name = "DecorSheetBaker"
		add_child(_baker)
	if _baker == null:
		return
	_baker.step(delta, _apply_sheet)
	if not _baker.is_idle() or _bake_dirty.is_empty():
		return
	var best_c := Vector2i.ZERO
	var best_score := 1e18
	var found := false
	var cur_vp := int(_baker.current_size())
	for c: Vector2i in _bake_dirty.keys():
		if not _lists.has(c):
			_bake_dirty.erase(c)
			_sheet_content_dirty.erase(c)
			continue
		if _chunk_fully_blocked(c):
			_bake_dirty.erase(c)
			_sheet_content_dirty.erase(c)
			if _sheet_size.has(c):
				_apply_sheet(c, int(_sheet_gen.get(c, 0)), 0, null, true)
			continue
		var d := _chunk_distance(c, _culled_at) if _culled_at.is_finite() else 0.0
		if _culled_at.is_finite() and d > distance + CHUNK:
			continue
		var has_sheet := _sheet_size.has(c)
		var content_dirty := _sheet_content_dirty.has(c)
		var c_want := sheet_size_for(c, _culled_at, int(_sheet_size.get(c, 0)))
		if has_sheet and not content_dirty:
			if c_want == int(_sheet_size[c]):
				_bake_dirty.erase(c)
				continue
			if _sheet_move_hold > 0.0:
				continue
		var score := d + (10000.0 if has_sheet else 0.0) - (8.0 if c_want == cur_vp else 0.0)
		if score < best_score:
			best_score = score
			best_c = c
			found = true
	if not found:
		return
	_bake_dirty.erase(best_c)
	_sheet_content_dirty.erase(best_c)
	var gen := int(_sheet_gen.get(best_c, 0))
	var sources := _collect_sheet_sources(best_c)
	if sources.is_empty():
		_apply_sheet(best_c, gen, 0, null, true)
		return
	var want := sheet_size_for(best_c, _culled_at, int(_sheet_size.get(best_c, 0)))
	_baker.start_bake(best_c, gen, want, sources, sheet_compress, texture_thread)


func _apply_sheet(c: Vector2i, gen: int, size: int, texture: ImageTexture, empty: bool) -> void:
	if int(_sheet_gen.get(c, -1)) != gen or not _lists.has(c):
		return
	var node: Node3D = _chunks.get(c)
	var existing_sheet: MeshInstance3D = null
	if node != null:
		for ch: Node in node.get_children():
			if ch.get_meta(META_FLAT, false):
				if not empty and texture != null and existing_sheet == null and ch is MeshInstance3D and not (ch is MultiMeshInstance3D):
					existing_sheet = ch as MeshInstance3D
				else:
					node.remove_child(ch)
					ch.queue_free()
	if empty or texture == null:
		_drop_composite(c)
		_sheet_size.erase(c)
		if node != null and node.get_child_count() == 0:
			_chunks.erase(c)
			FreeLater.node(node)
		return
	if node == null:
		node = Node3D.new()
		node.name = "Decor %d,%d" % [c.x, c.y]
		add_child(node)
		_chunks[c] = node
	_sheet_tex[c] = texture
	if _try_composite(c, texture):
		# The ground draws it: no separate sheet.
		if existing_sheet != null:
			node.remove_child(existing_sheet)
			existing_sheet.queue_free()
		_finish_sheet(c, node, size)
		return
	_uncomposite(c)
	if existing_sheet != null:
		var mat := existing_sheet.material_override as ShaderMaterial
		if mat == null:
			mat = ShaderMaterial.new()
			mat.shader = _plant_shader(SHADER_SHEET, SHADER_SHEET_OLD)
			if old_sheen_on:
				mat.set_shader_parameter(&"old_sheen", true)
			mat.render_priority = SHEET_PRIORITY
			existing_sheet.material_override = mat
		mat.set_shader_parameter(&"sheet", texture)
		mat.set_shader_parameter(&"raised_shade", float(_sheet_shade.get(c, 0.0)))
		existing_sheet.mesh = _sheet_mesh(_sheet_hills)
	else:
		var mat := ShaderMaterial.new()
		mat.shader = _plant_shader(SHADER_SHEET, SHADER_SHEET_OLD)
		if old_sheen_on:
			mat.set_shader_parameter(&"old_sheen", true)
		mat.set_shader_parameter(&"sheet", texture)
		mat.set_shader_parameter(&"raised_shade", float(_sheet_shade.get(c, 0.0)))
		mat.render_priority = SHEET_PRIORITY
		var inst := MeshInstance3D.new()
		inst.name = "FlatSheet"
		inst.set_meta(META_FLAT, true)
		inst.mesh = _sheet_mesh(_sheet_hills)
		inst.material_override = mat
		inst.position = Vector3(c.x * CHUNK + CHUNK * 0.5, SHEET_LIFT, c.y * CHUNK + CHUNK * 0.5)
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		inst.layers = Visuals.GROUND_LAYER
		if ViewPriority.tight_cull:
			GroundHeight.cull_box(inst, AABB(Vector3(-CHUNK * 0.5, -1.0, -CHUNK * 0.5), Vector3(CHUNK, 2.5, CHUNK)))
		else:
			inst.custom_aabb = AABB(Vector3(-CHUNK * 0.5, -64.0, -CHUNK * 0.5), Vector3(CHUNK, 128.0, CHUNK))
		node.add_child(inst)
	_finish_sheet(c, node, size)


func _finish_sheet(c: Vector2i, node: Node3D, size: int) -> void:
	_sheet_size[c] = size
	if _culled_at.is_finite():
		_cull_one(c, node, _culled_at)
	elif _behind_hidden(c):
		node.visible = false
	_composite_visible(c, node.visible)


## The chunk's ground draws `texture` itself (--decor-composite=off, a coarse or missing ground, or no
## chunk view: it can't, and a FlatSheet is drawn).
func _try_composite(c: Vector2i, texture: ImageTexture) -> bool:
	var cv: Object = _chunk_view(c)
	if not decor_composite or cv == null or not cv.has_method("set_decor_sheet"):
		return false
	if not cv.set_decor_sheet(texture, float(_sheet_shade.get(c, 0.0)), Vector2(c) * float(CHUNK)):
		_composited.erase(c)
		return false
	_composited[c] = true
	return true


## The chunk's ground stops drawing its sheet (a FlatSheet takes over, or the sheet is gone).
func _uncomposite(c: Vector2i) -> void:
	if _composited.erase(c):
		var cv: Object = _chunk_view(c)
		if cv != null and cv.has_method("clear_decor_sheet"):
			cv.clear_decor_sheet()


func _drop_composite(c: Vector2i) -> void:
	_uncomposite(c)
	_sheet_tex.erase(c)


func _drop_composites() -> void:
	for c: Vector2i in _composited.keys():
		_uncomposite(c)
	_composited.clear()
	_sheet_tex.clear()


func _composite_visible(c: Vector2i, shown: bool) -> void:
	if _composited.has(c):
		var cv: Object = _chunk_view(c)
		if cv != null and cv.has_method("set_decor_sheet_visible"):
			cv.set_decor_sheet_visible(shown)


func _chunk_view(c: Vector2i) -> Object:
	if world == null or not is_instance_valid(world):
		return null
	var cv = world.chunks.get(c)
	return cv if cv is Object and is_instance_valid(cv) else null


## A chunk's ground meshes in and out (built later than its sheet, rebuilt, far and coarse again): the sheet
## moves between the ground's own shader and a FlatSheet to suit, a few times a second.
func _sync_composites() -> void:
	_composite_tick += 1
	if _composite_tick % 6 != 0 or _sheet_tex.is_empty():
		return
	for c: Vector2i in _sheet_tex.keys():
		var cv: Object = _chunk_view(c)
		if cv == null or not cv.has_method("can_composite_decor"):
			continue
		var want: bool = decor_composite and cv.can_composite_decor()
		var have: bool = _composited.has(c) and cv.has_decor_sheet()
		if want != have or (_composited.has(c) and not have):
			_apply_sheet(c, int(_sheet_gen.get(c, 0)), int(_sheet_size.get(c, 0)), _sheet_tex[c], false)


## Sorted list of every decorative known from Factorio's index and active mods' graphics list.
static func known_decor_names() -> Array:
	var idx := index()
	var seen := {}
	if ItemIcons.factorio_data_dir() != "" or not ModGraphics.decor.is_empty():
		for k in idx:
			seen[str(k)] = true
	else:
		return []
	var out := seen.keys()
	out.sort()
	return out


## Whether Factorio's definitions or the active mods' graphics list defines `decor_name`.
static func has_decor_def(decor_name: String) -> bool:
	var idx := index()
	if ModGraphics.decor.has(decor_name):
		return true
	return ItemIcons.factorio_data_dir() != "" and idx.has(decor_name)


## Swatch preview (up to 128 x 128, FORMAT_RGBA8) of Factorio's or a mod's own decorative picture.
static func preview_image(decor_name: String) -> Image:
	var entry: Variant = index().get(decor_name)
	if not (entry is Dictionary):
		return null
	if not ModGraphics.decor.has(decor_name) and ItemIcons.factorio_data_dir() == "":
		return null
	var files := {}
	for pic in (entry as Dictionary).get("pics", []):
		if pic is Array:
			var img := _region(pic as Array, files)
			if img != null and not img.is_empty():
				return _fit_preview_swatch(img)
	return null


## Swatch preview (up to 128 x 128, FORMAT_RGBA8) from a model pack's decorative file list.
static func pack_preview_image(files: Array) -> Image:
	if files.is_empty():
		return null
	var img := _load_pack_image(str(files[0]))
	return _fit_preview_swatch(img)


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
