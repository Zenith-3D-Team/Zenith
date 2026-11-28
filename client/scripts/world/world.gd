extends Node3D
## The client's copy of the static world: terrain and entities in the chunks around the camera.
## Applies chunk snapshots and deltas from the mod and keeps the chunk subscription current.

const ProtoDB := preload("res://scripts/world/protos.gd")
const ChunkView := preload("res://scripts/world/chunk_view.gd")
const FreeLater := preload("res://scripts/world/free_later.gd")
const Anim := preload("res://scripts/world/anim.gd")
const WireDecode := preload("res://scripts/net/wire_decode.gd")
const MessageDecode := preload("res://scripts/net/message_decode.gd")
const Probing := preload("res://scripts/debug/probing.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const VisualTurns := preload("res://scripts/world/visual_turns.gd")
const BuildingModels := preload("res://scripts/world/building_models.gd")
const SpriteStandins := preload("res://scripts/world/sprite_standins.gd")
const TerrainMesher := preload("res://scripts/world/terrain_mesher.gd")
const TerrainTextures := preload("res://scripts/world/terrain_textures.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const FarChunks := preload("res://scripts/world/far_chunks.gd")
const CliffWall := preload("res://scripts/world/cliff_wall.gd")
const StallWatchdog := preload("res://scripts/debug/stall_watchdog.gd")
const FrameBudget := preload("res://scripts/world/frame_budget.gd")
const BeltBlur := preload("res://scripts/world/belt_blur.gd")
const BehindCull := preload("res://scripts/world/behind_cull.gd")
const PipelineWarm := preload("res://scripts/world/pipeline_warm.gd")
const PipeCovers := preload("res://scripts/world/pipe_covers.gd")
const ChunkDiskCache := preload("res://scripts/world/chunk_disk_cache.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const ViewPriority := preload("res://scripts/world/view_priority.gd")
const ViewAhead := preload("res://scripts/world/view_ahead.gd")
const Switches := preload("res://scripts/switches.gd")
const Wire := preload("res://scripts/util/wire.gd")

const CHUNK := 32
const SUBSCRIBE_REFRESH := 5.0  # resend the subscription now and then in case it was lost
## Chunks are asked for a few at a time, nearest the focus first, and more only once those are
## drawn: walking at a long view distance, every chunk edge crossed asked for a whole new row (29
## at Ultra), which arrived and was built together and stuttered (owner's desktop, 18 fps running).
## Legacy fixed limits when `--stream-window=legacy` is passed; by default `_stream_allowance` scales
## adaptively with view radius and frame headroom.
const STREAM_MOVING := 12
const STREAM_STILL := 32
const STREAM_STEP := 0.15
const STREAM_STEP_QUICK := 0.03  # standing, or moving sliding window refill (_all_came)
## While a screenshot loads its view (set_cover) this many: the shot is a loading screen (the picture
## held, nobody playing), and 32 at a time, each asked for again only once drawn, kept the bridge idle
## between batches (10-30 chunks a second against the ~6,600 a far view needs).
const STREAM_SHOT := 256
## Chunks kept after they leave the view (their messages as they came), so coming back needs no
## snapshot: the bridge answers `same` when the chunk hasn't changed since (its change count and
## entity count match: world.lua M.rev). The most kept, oldest dropped first, and none older than
## CACHE_AGE_MSEC (what changes without an event, a furnace's recipe from its ore, heals by then).
const CACHE_CHUNKS := 2500
const CACHE_AGE_MSEC := 600000
const MAX_CACHE_DELTAS := 64
## And no more than about this much memory, from what each kept chunk holds (estimated: its tiles,
## records and decoratives), the least recently used dropped first (I18).
const CACHE_BYTES := 256 << 20
## The area cache (I18, owner: "cache everything in an area instead of having to recheck for
## chunks"): chunks that leave the square stay built and drawn as they last were (the bridge no longer
## updates them), up to WARM_RINGS chunks past it, at most WARM_MAX (fewer with a long view:
## HOLD_TOTAL, the shader instance buffer's limit), the least recently left let go first and those
## hidden behind the camera before those in view. Walking back they are asked for at once with the
## counts their drawn copy matches (`kept`, which the bridge sends as they leave) and stay drawn; the
## bridge's `same` then costs nothing more, and only a changed one is sent and built again.
const WARM_RINGS := 6
const WARM_MAX := 1000
## Maximum milliseconds terrain stays hidden waiting for entities/far-merge before atomic reveal falls back.
const REVEAL_HOLD_MSEC := 600
const REVEAL_HOLD_DH_MSEC := 6000
const DH_UNLOAD_HOLD_MSEC := 1500
const MAX_DH_UNLOAD_HOLD := 128
const OPTIMISTIC_PER_FRAME := 6
const OPTIMISTIC_BUDGET_USEC := 2500
const TERRAIN_BUILD_BACKLOG := 12
## --warm-rings=<n>: override WARM_RINGS (clamped 0..12) for how many rings past the view square stay built.
static var warm_rings := _read_warm_rings()


static func _read_warm_rings() -> int:
	for arg: String in Switches.args():
		if arg.begins_with("--warm-rings="):
			return clampi(int(arg.substr(len("--warm-rings="))), 0, 12)
	return WARM_RINGS
## The view's direction (I18): the camera's, turned towards where the focus moves, in SECTORS steps
## so the wanted order (prio_order) and the bridge's queue (`sub` f) change only when it turns past a
## sector's edge by SECTOR_SLACK of a sector. Looking nearly straight down (Factorio's view) there is
## none: every way is in view.
const SECTORS := 8
const SECTOR_SLACK := 0.25
const VIEW_FLAT_ON := 0.35  # the camera's forward's length on the ground for a direction (and off below VIEW_FLAT_OFF)
const VIEW_FLAT_OFF := 0.25
const MOVING_SPEED := 3.0  # tiles a second the focus moves at before its way counts
## A chunk behind the view counts as further away by this (as world.lua's BEHIND): straight behind,
## twice its distance.
const BEHIND := 3
const MOVING_FOR := 1.5  # seconds after the focus last changed chunk that it counts as moving
const JUMP_CHUNKS := 3  # the focus changing chunk by more than this is a jump, not moving
const FOCUS_INTERVAL := 0.25
# Main-thread time a frame may spend rebuilding chunks' entities is their slice in frame_budget.gd
# (`build`, at least one rebuilt): a busy chunk takes 10-30 ms, and six of them in a frame made
# walking into a big base stutter.
const REBUILDS_PER_FRAME := 10
## With --frame-budget=separate (the old slices, for comparing), message handling (Bridge) and
## chunk rebuilds share this much of a frame: walking into new chunks on the owner's save, both at
## their own full allowance plus everything else made 20 ms frames. Rebuilds get what handling
## left, at least the build's floor in frame_budget.gd, so chunks keep coming.
const FRAME_WORK_USEC := 7000
# New MultiMeshes a frame may add, in their meshes' surfaces (ChunkView.Budget): what the renderer
# takes on outside any script. A chunk's MultiMeshes drawn before are filled again in place, and
# don't count.
const NEW_SURFACES := 240
# Terrain meshes take 4-6 ms each with Factorio's tile textures and transitions, and come in
# bursts (a chunk arriving also rebuilds its neighbours), so they're built on worker threads
# (terrain_mesher.gd): this many at once, chunks without ground first, nearest first. Two a frame
# on the main thread left holes for seconds on a big base and made the frames that built them slow.
const TERRAIN_JOBS := 4
## While a screenshot loads, up to this many (fewer on a machine with fewer cores): nothing else is
## played meanwhile, and a far view's thousands of chunks each need their ground before they count.
const TERRAIN_JOBS_SHOT := 12
# A chunk still empty this long after subscribing was lost along with whatever resync should
# have recovered it (a gap can't say which chunks it hit). Asking again for one still on its way
# costs nothing: the mod queues each chunk once. Not waiting for the stream to go quiet: on a
# busy base it never does, and lost chunks stayed holes for good.
const MISSING_CHUNK_MSEC := 4000
## The most chunks one `resync` names: about 12 KB, inside a datagram at any view distance.
const RESYNC_MAX := 1000
const WATCHDOG_INTERVAL := 3.0

## A chunk's entities were redrawn (something in it changed) or it was unloaded. Overlays drawn
## from entity records (wires, ghosts, marks) rebuild from this.
signal entities_changed(chunk: Vector2i)
## A record's Alt-mode arrows changed without the chunk being drawn again (`aiu` fa).
signal alt_changed(chunk: Vector2i)
## Tiles in a chunk were laid or mined (`tiles`); a snapshot's new ground comes with entities_changed.
signal tiles_changed(chunk: Vector2i)
## A ghost was hidden or shown again by the client alone (predicted.gd's remove_ghost, I6): ghosts.gd
## draws its chunk again at once, without the chunk's own rebuild.
signal ghost_hidden(chunk: Vector2i)
## Emitted once both ground and initial entity visuals (or fallback timeout) are ready for a chunk.
signal chunk_ready(chunk: Vector2i)
## A chunk's ground or entities finished drawing (used by DistantHorizon for mask & LOD baking).
signal chunk_drawn(chunk: Vector2i)
## A chunk was unloaded from the active square (`_unload`).
signal chunk_unloaded(chunk: Vector2i)


## A static entity as last reported by the server.
class Rec:
	var key  # unit number (int) or "proto:x:y" (String) for entities without one
	var unit := 0
	var proto_id := 0
	var pos := Vector2.ZERO  # tiles
	var fixed := Vector2i.ZERO  # 1/256 tiles, exactly as sent
	var dir := 0
	var extra := {}
	var chunk := Vector2i.ZERO
	## Where a line of belts begins and ends (_connect_belt). Not in `extra`: belt_paths.gd reads belts'
	## `extra` on belt_items.gd's worker, and a Dictionary mustn't be written while it is read.
	var belt_ends := 0
	## Its fluid connections with nothing connected (_cover, pipe_covers.gd): a bit per connection, by its
	## index in the prototype's `eprops` fb. Not in `extra`, as belt_ends.
	var covers := 0
	## The connections it draws (PipeCovers.ports), which `covers` picks from.
	var cover_ports: Array = []
	var cache_gen := -1
	var cache_mesh: Mesh
	var cache_parts: Array = []
	var cache_xform := Transform3D.IDENTITY
	var cache_is_belt := false
	var cache_belt_kind := ""
	var cache_rings = null  # its ContactShade rings (Array) while cache_gen holds: chunk_view.gd
	## The cache as one Array for ChunkBuildNative.collect_rows (one read instead of six): [mesh, parts, xform,
	## is_belt, belt kind, rings], set with the fields above.
	var cache_row = null


## --world-fast-add=off: classify entity prototypes and connect neighbours individually per record as before.
static var fast_add := Switches.on("--world-fast-add")
## --shadow-runs=off: rescan every chunk's shadow tier on camera motion instead of row-run boundary diffs.
static var shadow_row_runs := Switches.on("--shadow-runs")
## --sub-incremental=off: rebuild the full wanted/subscribed lists on every subscription step as before.
static var sub_incremental := Switches.on("--sub-incremental")
## --atomic-chunk-reveal=off: show terrain mesh immediately before waiting for initial entities/far-merge.
static var atomic_reveal := Switches.on("--atomic-chunk-reveal")
## --dh-handoff=off: disable Distant Horizon / regular chunk swap holding & load-underneath grace.
static var dh_handoff := Switches.on("--dh-handoff")
## --double-buffer-refresh=off: clear old entities immediately on incoming snapshot rather than staging parts first.
static var double_buffer_refresh := Switches.on("--double-buffer-refresh")
## --optimistic-cache=off: wait for server `same` before mounting cached chunks.
static var optimistic_cache := Switches.on("--optimistic-cache")
## A chunk from the cache (the disk cache's or the RAM one's) is replayed a step at a time (its chunk message, each
## entities message, its deltas, its decoratives) inside the frame budget's `hydrate` slice, the clock checked between
## steps: one dense chunk's replay in one call took 4-15 ms outside the budget (R&D run-spikes: 0.7-1.4 frames a minute
## of 22-31 ms). A chunk then appears a frame or two later. --optimistic-slice=off: whole chunks in one call, the clock
## checked only between chunks (OPTIMISTIC_BUDGET_USEC), as before.
static var optimistic_slice := Switches.on("--optimistic-slice")
## --chunk-disk-cache=off: disable persistent Zstd chunk cache under user://chunk-cache/.
static var disk_cache_enabled := Switches.on("--chunk-disk-cache")
## --stream-window=legacy|<N>: restore fixed 12/32 window or force N in-flight chunks.
static var stream_window_legacy := Switches.has("--stream-window=legacy")
static var stream_window_override := _read_stream_window_override()
## --stream-lookahead=off: disable flight velocity priority biasing.
static var stream_lookahead := Switches.on("--stream-lookahead")
## --fast-edit-rebuild=off: disables live edit chunk preemption and near-first state slicing.
static var fast_edit_rebuild := Switches.on("--fast-edit-rebuild")
## --fast-edit-coalesce=off: disables 35 ms burst coalescing on repeated live edits to the same chunk.
static var fast_edit_coalesce := not (Switches.has("--fast-edit-coalesce=off"))
const LIVE_COALESCE_MSEC := 35


static func _read_stream_window_override() -> int:
	for arg: String in Switches.args():
		if arg.begins_with("--stream-window="):
			var raw := arg.substr(len("--stream-window="))
			if raw.is_valid_int():
				return maxi(0, int(raw))
	return -1

var protos := ProtoDB.new()
## Chunks loaded around the focus, as a radius in chunks (3 -> 7x7 chunks).
var view_radius := 5
## Live updates (movers, machine states) are requested within this many tiles of the focus.
var focus_radius := 96
## The 3D remote view is on (set_remote_view).
var remote_view := false
## --live-inserter-radius=detail|view|64 (detail, the owner's choice for 0.3.1: 0.3.0's speed): how far round the focus the bridge sends live inserter hands
## (`ih`/`ie`, moving arms; past it arms rest, K12), as the focus's `ir`. `view`: the camera's visible ground,
## its farthest corner's square distance from the focus plus a margin, rounded up to a step, kept within
## 16..64 (ViewPriority.live_ir; a smaller one sent only after it stayed smaller 1 s, live_ir_settle; the bridge raises f3d-detail-radius to it, never past `r`); `64`:
## 64 (0.3.1 before this, a fixed 64-tile square); `detail`: 0, f3d-detail-radius alone (0.3.0).
static var live_inserter_mode := Switches.value("--live-inserter-radius", "detail")
## The `ir` last sent with the focus (-1: none, the camera not known yet).
var live_ir_sent := -1
## How long a smaller `ir` than live_ir_sent has been wanted (ViewPriority.live_ir_settle).
var _live_ir_low_for := 0.0
## Reference FOV for character-anchored building LODs during normal play.
const CHAR_LOD_FOV := 35.0
## When false (normal play with char_lod_anchor), building LODs measure distance from the character.
var lod_by_camera := true
var _char_zoom_y := 0.0
## The sun, whose shadow map decides which chunks cast shadows (_update_shadow_casters).
var sun: DirectionalLight3D
## Chunks that cast shadows now (for --stutter-probe and the UI test).
var shadow_casters := 0
var _shadow_key: Array = []

var chunks := {}  # Vector2i -> ChunkView
var _chunks_by_row := {}  # cy: int -> { cx: int -> ChunkView }
var _row_index_count := 0
var _has_local_pipes := false
var _batch_joins := false
var _join_walls := {}
var _join_belts := {}
var _join_pipes := {}
var _join_cargo_rects: Array = []
var entities := {}  # key -> Rec
var _ghosts := {}  # Vector2i fixed position -> key of the ghost standing there
var _ghosts_by_chunk := {}  # Vector2i chunk -> { key -> Rec }: ghosts indexed by chunk for footprint cleanup
var _tile_ghosts := {}  # Vector2i tile -> key of the tile ghost on it (extra.tg)
var _pipes := {}  # Vector2i tile -> key of the pipe or pipe-to-ground on it
var _belts := {}  # Vector2i tile -> key of what carries items on it, while a modeller's belt ends are in use
var _belt_ends_on := -1  # whether there are models of belt ends (-1: not looked yet)
var _walls := {}  # Vector2i tile -> key of the wall or gate on it
## Pipe covers (_cover): proto id -> its fluid connections (`eprops` fb, fluid_ports_from); the tile each
## connection of a record (not a pipe) is on -> its key, and the tile it leads onto -> [keys].
var _fluid_ports := {}
var _port_tiles := {}
var _port_targets := {}
var _cargo := {}  # key of a hub, cargo bay or landing pad -> Rect2i of its tiles
var _cargo_tiles := {}  # Vector2i tile -> how many of them cover it
var _cargo_ghosts := {}  # the same for ghosts of them: ghost bays join each other, built ones don't
var _cargo_ghost_tiles := {}
## Hubs, bays and pads whose record left with its unloaded chunk: key -> that chunk. Their area is
## kept, so the bays next door stay framed as last seen, and goes when the chunk is drawn again
## (_on_chunk), so one mined meanwhile no longer frames its neighbours as joined.
var _cargo_left := {}
## Keys of remnants (ModelLibrary.REMNANT_TYPES): building over one removes it in the game, which
## raises no event, so a new entity clears those under it here (_clear_remnants_under).
var _remnants := {}
var working := {}  # unit -> 0/1
## K10: lit lamps' colours (`st` `lc`): unit -> 0xRRGGBB, for the lamps that show one; a lamp without
## an entry has Factorio's plain white light. A lamp's colour is forgotten with each state the bridge
## sends for it, which sends the colour again in the same message when it has one.
var lamp_colors := {}
## K20: lit lamps set to Always on (`st` `ao`): unit -> true. They shine by day as well (lamp_lights.gd
## lights the others only when it is dark). Forgotten with each state, as the colours are.
var lamp_always := {}
## Alt-mode's chest contents (`ac`, J6): unit -> [item, more items...], the kinds it holds most of,
## most first. Only the answers to the current turning on of Alt-mode (Bridge.alt_contents) are
## kept; alt_overlay.gd draws them over chests that have no icon of their own.
var alt_contents := {}
var _alt_contents_g := 0
## Alt-mode's machine icons (`am`, K1, K2): unit -> [modules, packs], each [[item, quality], ...]
## (quality "" for normal): the modules in a machine and the science packs in a lab, in slot order;
## where the packs go, an ammo turret's ammo and a locomotive's fuel (a mover's unit, no record here).
## Kept as alt_contents is, for the current turning on of Alt-mode only; alt_overlay.gd lays them out
## by the prototype's `eprops` isq.
var alt_machines := {}
var _alt_machines_g := 0
## Machines' moving parts and glows: written as states change for the shader to move, everywhere;
## turret heads, collectors' arms and worms moved here each frame near the camera (anim.gd).
var animator := Anim.new()
## Far chunks' buildings merged into one mesh each.
var far_chunks := FarChunks.new()
## Chunks far behind the camera hidden (I18).
var behind_cull := BehindCull.new()

var _focus := Vector2.ZERO
var _subscribed_arr: Array = []
var _subscribed_lazy := false
var _subscribed_count := 0
var _subscribed: Array:
	get:
		if _subscribed_lazy:
			var out: Array = []
			if _wanted_radius >= 0:
				for offset: Vector2i in prio_order(_wanted_radius, _wanted_sector):
					var c: Vector2i = _wanted_center + offset
					if _asked.has(c):
						out.append(c)
					if out.size() >= _wanted_most:
						break
				if out.size() < _asked.size():
					for c: Vector2i in _asked:
						if not out.has(c):
							out.append(c)
			_subscribed_arr = out
			_subscribed_lazy = false
		return _subscribed_arr
	set(v):
		_subscribed_arr = v
		_subscribed_lazy = false
		_subscribed_count = v.size()
		_sub_grid_valid = false


func _subscribed_size() -> int:
	return _subscribed_count if _subscribed_lazy else _subscribed_arr.size()


var _sub_grid_valid := false
var _sub_grid_center := Vector2i(0x7fffffff, 0)
var _sub_grid_radius := -1
var _sub_rows: Array[PackedByteArray] = []
var _sub_cursor := 0
var _prio_warm_task := -1
var _prio_warm_radius := -1
var _prio_warm_out := {}
var _sub_timer := 0.0
var _stream_timer := 0.0
## When the focus last walked into the next chunk; STOOD (long ago) for a standing start. 0 counted as
## walking for the client's first 1.5 s (and the add-on test's held chunk came as 8 chunks, not 9).
const STOOD := -1000000000000
var _moved_msec := STOOD
var _focus_timer := 0.0
var _last_focus_sent := Vector2(INF, INF)
var _dirty := {}  # Vector2i -> true (a change in what it holds), false (its view alone: redraw_view)
var _dirty_live := {}  # Vector2i -> true: chunks dirtied by live add/upd/del/mined edits
var _live_prep := {}  # Vector2i -> true: live chunks mid-partial/worker/pending rebuild
var _live_built_msec := {}  # Vector2i -> msec: when a chunk last finished a live rebuild
var _marking_live := false
var _pending := {}  # Vector2i -> true: chunks built with MultiMeshes still to add (ChunkView.pending)
## J20: entities the character mined, taken away on the bridge's `mnd` (the tick it mined them) before
## their `del` comes through the reliable stream, behind the chunk snapshots queued ahead of it: key ->
## Time.get_ticks_msec(). A record of one coming meanwhile (a snapshot or `upd` read before the mining)
## is left out; its `del` ends that, or MINED_EARLY_MSEC.
var _mined_early := {}
const MINED_EARLY_MSEC := 3000
var _unloaded: Array = []  # ChunkViews no longer wanted, still to free
var _dirty_terrain := {}
var silo_positions := {}  # unit -> Vector2: rocket silos currently loaded (for terrain shaft holes and 3D shafts)
var _silo_hole_spec_seen := Vector3(0.0, 0.0, 2.60)
var _terrain_jobs := {}  # Vector2i -> [task id, TerrainMesher, ChunkView, signature, own signature]
## Terrain meshes kept by Vector3i(surface index, cx, cy): [signature, ArrayMesh, variant slots,
## its own tiles' signature], oldest first. A chunk drawn again with the same ground round it (back
## from another surface, a factory building's inside, or walking back) takes its mesh from here
## instead of a worker's 4-6 ms; the signature hashes the 3x3 chunks' tiles and the picture layers'
## layout, so a changed tile or neighbour builds it again. Only meshes with every picture loaded
## are kept.
var _terrain_cache := {}
const TERRAIN_CACHE := 1200
## Chunks drawn without some tile pictures, which were still loading: Vector2i -> missing ids.
var _waiting_gfx := {}
## Per tile id, the graphics terrain jobs use (TerrainMesher.gfx_of). Replaced, never changed,
## when more pictures are ready, as running jobs hold the old one.
var _gfx_table: Array = []
var _gfx_generation := -1
var _terrain_layout := TerrainTextures.layout
var _watchdog_timer := 0.0
## Terrain builds so far, their main-thread time and their time on worker threads (for
## --terrain-probe).
var terrain_builds := 0
var terrain_cache_hits := 0
var terrain_build_usec := 0
var terrain_worker_usec := 0
var entity_builds := 0
var entity_build_usec := 0
var _held_reveal := {}  # Vector2i -> true: terrain built, waiting for entity build / far cover before revealing
var dh_covers_chunk: Callable
var dh_handoff_ready: Callable
var _dh_unloading := {}  # ChunkView -> Array [coord: Vector2i, start_msec: int]
var _dh_unloading_by_coord := {}  # Vector2i -> Array[ChunkView]
var _staged_snap := {}  # Vector2i -> Dictionary: double-buffered snapshot replacement
var _optimistic_rv := {}  # Vector2i -> [rs, rv, n] for optimistically hydrated ChunkViews
var _optimistic_queue: Array[Vector2i] = []
var _optimistic_pending := {}  # Vector2i -> true
## The chunk being replayed from the cache in steps (optimistic_slice), or empty: {c, cv, msgs, deltas, dec, step,
## rv, n}. Dropped when the chunk goes or the bridge's own copy (or a `same`) arrives meanwhile.
var _hyd := {}
## For tests: the `hydrate` slice in µs instead of the frame budget's grant (-1).
var hydrate_test_usec := -1
var _disk_waiting := {}  # Vector2i -> true: awaiting async ChunkDiskCache region load
var _disk_cache := ChunkDiskCache.new()
var _disk_cache_sid := ""
var _disk_cache_si := -1
var _disk_cache_hash := 0
var _disk_cache_proto_ver := -1
var _disk_cache_proto_counts := Vector2i(-1, -1)
var _focus_vel := Vector2.ZERO
## Main-thread time by part of this node's _process, microseconds so far (for --stutter-probe:
## kept only while it runs, Probing.on).
var prof := {}


func _prof(key: String, t0: int) -> void:
	StallWatchdog.crumb = "world: after " + key
	if Probing.on:
		prof[key] = int(prof.get(key, 0)) + Time.get_ticks_usec() - t0


## Processes after every other script of the frame (the highest process_priority): the frame
## budget's measure of the frame's other scripts ends here (frame_budget.gd measure_frame).
class FrameEnd extends Node:
	const Budget := preload("res://scripts/world/frame_budget.gd")

	func _init() -> void:
		process_priority = 1 << 20

	func _process(_delta: float) -> void:
		Budget.frame_end()


func _ready() -> void:
	Bridge.resync_chunks = resync_list
	animator.name = "Animator"
	animator.world = self
	add_child(animator)
	far_chunks.name = "FarChunks"
	far_chunks.world = self
	add_child(far_chunks)
	behind_cull.world = self
	add_child(behind_cull)
	var frame_end := FrameEnd.new()
	frame_end.name = "FrameEnd"
	add_child(frame_end)
	PipelineWarm.attach(self)
	Bridge.welcomed.connect(_on_welcome)
	if Switches.has("--terrain-probe"):
		var probe: Node = preload("res://scripts/debug/terrain_probe.gd").new()
		probe.world = self
		add_child(probe)
	for arg in Switches.args():
		if arg.begins_with("--stutter-probe="):
			var stutter: Node = preload("res://scripts/debug/stutter_probe.gd").new()
			stutter.world = self
			stutter.out_path = arg.get_slice("=", 1)
			add_child(stutter)
		if arg.begins_with("--flicker-probe="):
			var flicker: Node = preload("res://scripts/debug/flicker_probe.gd").new()
			flicker.world = self
			flicker.out_dir = arg.get_slice("=", 1)
			add_child(flicker)


static func static_key(proto_id: int, fx: int, fy: int) -> String:
	return "%d:%d:%d" % [proto_id, fx, fy]


static func chunk_of(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / CHUNK), floori(pos.y / CHUNK))


## Forgets the world. A surface change (`surface`) keeps the prototype dictionaries; `next_surface`
## is the surface coming (its index), whose ground pictures may still be loaded. `keep_cache` preserves
## chunk and terrain caches across same-save reconnects/respawns so the bridge can answer `same`.
func reset(keep_protos := false, next_surface := -1, keep_cache := false) -> void:
	if _disk_cache.is_configured():
		_disk_cache.flush_sync()
	for jc in _prep_jobs.keys():
		_abandon_prep(jc)
	# Hidden now and freed over the next frames (_free_unloaded): freeing all 441 at once after a
	# respawn or a surface change took a quarter of a second.
	for cv in chunks.values():
		cv.visible = false
		cv.retire()
		_unloaded.append(cv)
	for cv_v: Variant in _dh_unloading.keys():
		if cv_v is Object and is_instance_valid(cv_v):
			var dcv := cv_v as ChunkView
			dcv.visible = false
			_unloaded.append(dcv)
		_unload_keys.erase(cv_v)
	_dh_unloading.clear()
	_dh_unloading_by_coord.clear()
	chunks.clear()
	_chunks_by_row.clear()
	_row_index_count = 0
	far_chunks.reset_decide()
	_lod_ahead_chunks.clear()
	_lod_ahead_points = []
	_lod_ahead_gen = -1
	behind_cull.reset()
	_shadow_key = []
	_shadow_full_key = []
	_shadow_move_key = []
	_shadow_runs.clear()
	_shadow_queued.clear()
	_shadow_fresh.clear()
	_shadow_uncounted.clear()
	_shadow_todo = []
	_shadow_next = 0
	_shadow_start = 0
	_shadow_incremental = false
	shadow_casters = 0
	_lod_fades.clear()
	_lod_now.clear()
	for band: LodBand in _lod_bands:
		band.ring = -1
	_lod_far = []
	_lod_prev_at = Vector3(INF, INF, INF)
	_char_zoom_y = 0.0
	_lod_cam_speed = 0.0
	_lod_fast_moving = false
	_live.clear()
	_warm.clear()
	entities.clear()
	_mined_early.clear()
	_ghosts.clear()
	_ghosts_by_chunk.clear()
	_tile_ghosts.clear()
	_pipes.clear()
	_has_local_pipes = false
	_port_tiles.clear()
	_port_targets.clear()
	_batch_joins = false
	_join_walls.clear()
	_join_belts.clear()
	_join_pipes.clear()
	_join_cargo_rects.clear()
	_belts.clear()
	_walls.clear()
	_cargo.clear()
	_cargo_tiles.clear()
	_cargo_ghosts.clear()
	_cargo_ghost_tiles.clear()
	_cargo_left.clear()
	_remnants.clear()
	silo_positions.clear()
	working.clear()
	_st_lists.clear()  # the old world's states that waited
	_st_at = 0
	_st_i = 0
	_st_prio_lists = 0
	_st_prio_center = Vector2i(0x7fffffff, 0)
	lamp_colors.clear()
	lamp_always.clear()
	alt_contents.clear()  # the bridge sends every chest again with the new world
	alt_machines.clear()
	_stated.clear()
	animator.reset()
	if not keep_protos:
		protos.clear()
		_fluid_ports.clear()
		_port_memo.clear()
		_drawn_memo.clear()
	if not keep_protos and not keep_cache:
		_cache.clear()  # another game, or its prototype ids: nothing kept is valid
		_cache_bytes = 0
		_terrain_cache.clear()
		TerrainTextures.forget_surfaces()
	_filling.clear()
	_subscribed = []
	_sub_rows.clear()
	_sub_cursor = 0
	_asked = {}
	_coming = {}
	_held.clear()
	clear_cover()  # a screenshot's view was of the world before
	_moved_msec = STOOD  # a new world loads as a standing start, walked into a door or not
	_dirty.clear()
	_dirty_live.clear()
	_live_prep.clear()
	_live_built_msec.clear()
	_pending.clear()
	_partial.clear()
	_dirty_terrain.clear()
	_waiting_gfx.clear()
	_held_reveal.clear()
	_staged_snap.clear()
	_optimistic_rv.clear()
	_optimistic_queue.clear()
	_optimistic_pending.clear()
	_hyd = {}
	_join_covers.clear()
	_disk_waiting.clear()
	_focus_vel = Vector2.ZERO
	_vel = Vector2.ZERO
	_vel_from = Vector2(INF, INF)
	# Every chunk drawn with the old surface's ground is gone: room for the new one's.
	TerrainTextures.trim(next_surface)
	_last_focus_sent = Vector2(INF, INF)
	live_ir_sent = -1
	_live_ir_low_for = 0.0
	_view_cone = false
	_cone_active = false
	_cone_center = Vector2i(0x7fffffff, 0)
	_cone_at = Vector3(INF, INF, INF)
	_cone_fwd = Vector3.ZERO
	_cone_lens = []
	_wanted_gen = 0
	_latency_gen = -1


func set_focus(pos: Vector2) -> void:
	_focus = pos


func focus() -> Vector2:
	return _focus


func set_view_cone(on: bool) -> void:
	_view_cone = on


func view_cone_active() -> bool:
	return _cone_active


func stream_center() -> Vector2i:
	return _sq_center if _cone_active else chunk_of(_focus)


func entity_count() -> int:
	return entities.size()


func loaded_chunk_count() -> int:
	var n := 0
	for cv in chunks.values():
		if cv.loaded:
			n += 1
	return n


func handle(msg: Dictionary) -> void:
	match str(msg.get("t", "")):
		"protos":
			protos.add_entities(Wire.array(msg.get("l")))
		"tprotos":
			protos.add_tiles(Wire.array(msg.get("l")))
		"iprotos":
			protos.add_items(Wire.array(msg.get("l")))
		"fprotos":
			protos.add_fluids(Wire.array(msg.get("l")))
		"ready":
			_subscribed = []  # subscribe on the next frame
			_sub_rows.clear()
			_sub_cursor = 0
			_asked = {}
			_coming = {}
		"chunk":
			if msg.has("same"):
				_on_same(msg)
				return
			_keep_chunk(msg)
			_on_chunk(msg)
		"ents":
			_keep_part(msg, "msgs")
			var ec := Vector2i(int(msg.get("cx", 0)), int(msg.get("cy", 0)))
			if not _replaying and _staged_snap.has(ec):
				var st: Dictionary = _staged_snap[ec]
				(st["ents"] as Array).append(msg)
				(st["parts_got"] as Dictionary)[int(msg.get("part", 1))] = true
				if (st["parts_got"] as Dictionary).size() >= int(st["parts_expected"]):
					_commit_staged(ec)
				return
			if Bridge.draining() and not _replaying and _ents_sliced(msg):
				_apply_ents_live_sliced(msg)
				return
			_apply_ents_message(msg)
		"add", "upd":
			_marking_live = fast_edit_rebuild and not _replaying
			var e = msg.get("e")
			if e is Array and e.size() >= 4:
				var tc := chunk_of(Vector2(int(e[2]), int(e[3])) / 256.0)
				if not _replaying:
					if _staged_snap.has(tc):
						(_staged_snap[tc]["deltas"] as Array).append(msg.duplicate(true))
					var unit := int(e[0])
					if unit > 0:
						var prev: Rec = entities.get(unit)
						if prev != null and prev.chunk != tc:
							_touch(prev.chunk)
					_record_delta(tc, msg)
			if str(msg.get("t", "")) == "add" and not _replaying and (VisualTurns.expecting() or VisualTurns.has_revives()):
				_claim_turn(e)
			_add(e)
			if str(msg.get("t", "")) == "add":
				_clear_remnants_under(e)
			_marking_live = false
		"del":
			_marking_live = fast_edit_rebuild and not _replaying
			var unit := int(msg.get("u", 0))
			var key = unit
			if unit <= 0:
				key = static_key(int(msg.get("p", 0)), int(msg.get("x", 0)), int(msg.get("y", 0)))
			var gone: Rec = entities.get(key)
			if unit > 0 and not _replaying:
				if gone != null and gone.extra.has("gh") and not gone.extra.has("hid"):
					var gq := VisualTurns.quarters(Bridge.save_id, unit)
					if gq > 0:
						VisualTurns.note_ghost_del(int(gone.extra["gh"]), gone.pos, gq)
				VisualTurns.forget(Bridge.save_id, unit)  # mined or destroyed: a look-only turn goes too (I9)
				BuildingModels.forget(Bridge.save_id, unit)  # and a model of its own (M8)
			if not _replaying:
				if gone != null:
					if _staged_snap.has(gone.chunk):
						(_staged_snap[gone.chunk]["deltas"] as Array).append(msg.duplicate(true))
					_record_delta(gone.chunk, msg)
				elif unit <= 0:
					var dc := chunk_of(Vector2(int(msg.get("x", 0)), int(msg.get("y", 0))) / 256.0)
					if _staged_snap.has(dc):
						(_staged_snap[dc]["deltas"] as Array).append(msg.duplicate(true))
					_record_delta(dc, msg)
			_remove(key)
			_unlink_pipes(gone)
			_mined_early.erase(key)
			_marking_live = false
		"tiles":
			_marking_live = fast_edit_rebuild and not _replaying
			_on_tiles(Wire.array(msg.get("l")))
			_marking_live = false
		"kept":
			_on_kept(msg)
		"st":
			_on_states(_list(msg.get("l")), _list(msg.get("lc")), _list(msg.get("ao")))
		"aiu":
			_on_alt_icons(Wire.array(msg.get("l")))
			_on_alt_fluids(Wire.array(msg.get("fa")))
		"ac":
			_on_alt_contents(msg)
		"am":
			_on_alt_machines(msg)


## J20: the bridge's `mnd`, the tick the character's mining took an entity: it goes now (`g` 1), as
## its `del` will take it (fx.gd has played its sound already). Nothing for ore still there or an item on
## the ground (ground_items.gd hides that itself).
func mined(msg: Dictionary) -> void:
	if int(msg.get("g", 0)) != 1 or int(msg.get("gi", 0)) == 1:
		return
	var unit := int(msg.get("u", 0))
	var key = unit if unit > 0 else static_key(int(msg.get("p", 0)), int(msg.get("x", 0)), int(msg.get("y", 0)))
	var gone: Rec = entities.get(key)
	if gone == null:
		return
	var del_msg := {"t": "del", "u": unit} if unit > 0 else {"t": "del", "p": int(msg.get("p", 0)), "x": int(msg.get("x", 0)), "y": int(msg.get("y", 0))}
	_record_delta(gone.chunk, del_msg)
	_marking_live = fast_edit_rebuild and not _replaying
	_remove(key)
	_unlink_pipes(gone)
	_marking_live = false
	_mined_early[key] = Time.get_ticks_msec()


## A snapshot into the cache (a refresh of a kept chunk replaces it).
func _keep_chunk(msg: Dictionary) -> void:
	if _replaying or msg.get("none", false) or not msg.has("rv") or not msg.has("rs"):
		return
	var c := Vector2i(int(msg.get("cx", 0)), int(msg.get("cy", 0)))
	var k := Vector3i(int(msg["rs"]), c.x, c.y)
	_cache_drop(k)
	var bytes: int = 256 + int(_list(msg.get("tiles")).size()) * 16
	_cache[k] = {"rv": int(msg["rv"]), "n": int(msg.get("n", 0)), "msgs": [msg], "deltas": [], "dec": [], "msec": Time.get_ticks_msec(),
		"b": bytes, "db": 0}
	_cache_bytes += bytes
	_filling[c] = k
	_trim_cache()


## A kept chunk out of the cache.
func _cache_drop(k: Vector3i) -> void:
	var entry: Dictionary = _cache.get(k, {})
	if entry.is_empty():
		return
	_cache_bytes -= int(entry["b"]) + int(entry["db"])
	_cache.erase(k)


## The least recently used kept chunks dropped past CACHE_CHUNKS or CACHE_BYTES.
func _trim_cache() -> void:
	while _cache.size() > CACHE_CHUNKS or (_cache_bytes > CACHE_BYTES and _cache.size() > 1):
		for oldest: Vector3i in _cache:
			_cache_drop(oldest)
			break


## Records a live delta (`add`, `upd`, `del`, `tiles`) on a kept chunk so leaving the area and
## returning can still replay the updated state once `kept` confirms the new `[rv, n]`, rather than
## permanently poisoning the cached snapshot. Falls back to `t = true` if incomplete or over budget.
func _record_delta(c: Vector2i, msg: Dictionary) -> void:
	if _replaying:
		return
	var entry: Dictionary = _cache.get(Vector3i(surface_index, c.x, c.y), {})
	if entry.is_empty() or entry.get("t", false):
		return
	if not chunks.has(c) or not _cache_whole(entry):
		entry["t"] = true
		return
	var deltas: Array = entry["deltas"]
	if deltas.size() >= MAX_CACHE_DELTAS:
		entry["t"] = true
		return
	deltas.append(msg)
	entry["pending_kept"] = true
	var bytes := 128 + (Wire.array(msg.get("l")).size() * 12 if str(msg.get("t", "")) == "tiles" else 0)
	entry["b"] = int(entry["b"]) + bytes
	_cache_bytes += bytes
	_trim_cache()


## Marks chunk `c` stale when a cacheable delta cannot be tracked on top of its snapshot.
func _touch(c: Vector2i) -> void:
	var entry: Dictionary = _cache.get(Vector3i(surface_index, c.x, c.y), {})
	if not entry.is_empty():
		entry["t"] = true


## Whether a kept chunk has every `ents` part its `chunk` said.
static func _cache_whole(entry: Dictionary) -> bool:
	var msgs: Array = entry["msgs"]
	return not msgs.is_empty() and msgs.size() == int((msgs[0] as Dictionary).get("parts", 1)) + 1


## The bridge's counts for chunks that left the square (`kept`, hello `lv`): a chunk still drawn
## (WARM_RINGS, held) now matches them, and so do its kept messages (and recorded deltas) when intact.
func _on_kept(msg: Dictionary) -> void:
	var rs := int(msg.get("rs", -1))
	var l := Wire.array(msg.get("l"))
	var now := Time.get_ticks_msec()
	for i in range(0, l.size() - 3, 4):
		var c := Vector2i(int(l[i]), int(l[i + 1]))
		var rv := int(l[i + 2])
		var n := int(l[i + 3])
		var cv: ChunkView = chunks.get(c)
		if cv != null and cv.loaded and not cv.is_incomplete():
			_live[c] = [rs, rv, n]
		var entry: Dictionary = _cache.get(Vector3i(rs, c.x, c.y), {})
		if not entry.is_empty() and not entry.get("t", false) and _cache_whole(entry):
			entry["rv"] = rv
			entry["n"] = n
			entry["msec"] = now
			entry.erase("pending_kept")
			if rs == surface_index and _disk_cache.is_configured() and (entry.get("deltas", []) as Array).is_empty():
				_disk_cache.update_counts(c.x, c.y, rv, n)


## One of a kept chunk's ents or dec messages, after its `chunk`.
func _keep_part(msg: Dictionary, list: String) -> void:
	if _replaying:
		return
	var c := Vector2i(int(msg.get("cx", 0)), int(msg.get("cy", 0)))
	var k: Vector3i = _filling.get(c, Vector3i(-1, 0, 0))
	var entry: Dictionary = _cache.get(k, {})
	if entry.is_empty():
		return
	if list == "dec" and int(msg.get("part", 1)) == 1:
		entry["dec"] = []  # decoratives sent again (changed): the new ones replace them
		_cache_bytes -= int(entry["db"])
		entry["db"] = 0
	(entry[list] as Array).append(msg)
	var field := "b" if list == "msgs" else "db"
	var bytes := 128 + (WireDecode.ents_count(msg) * 120 if list == "msgs" else Wire.array(msg.get("l")).size() * 16)
	entry[field] = int(entry[field]) + bytes
	_cache_bytes += bytes
	_trim_cache()
	if list == "msgs" and int(k.x) == surface_index and not entry.get("t", false) \
			and _cache_whole(entry) and (entry.get("deltas", []) as Array).is_empty():
		_save_to_disk_cache(c, entry)


## main.gd: a `dec` message, kept with its chunk.
func keep_dec(msg: Dictionary) -> void:
	_keep_part(msg, "dec")


## The bridge says a chunk is as the cache has it: drawn from there. Gone from the cache meanwhile,
## it is asked for again.
func _on_same(msg: Dictionary) -> void:
	var c := Vector2i(int(msg.get("cx", 0)), int(msg.get("cy", 0)))
	var rs := int(msg.get("rs", -1))
	var k := Vector3i(rs, c.x, c.y)
	var entry: Dictionary = _cache.get(k, {})
	# Still drawn as the bridge's counts say (the area cache, I18): nothing to replay or rebuild.
	var cv: ChunkView = chunks.get(c)
	var live: Array = _live.get(c, [])
	if cv != null and cv.loaded and not cv.is_incomplete() and live.size() == 3 and int(live[0]) == rs \
			and int(live[1]) == int(msg["same"]):
		ChunkView.count("live_hit")
		if not entry.is_empty():
			_cache.erase(k)
			_cache[k] = entry  # the newest again
		return
	# Optimistically hydrated chunk confirmed by server `same`: promote in place with zero rebuild.
	var opt: Variant = _optimistic_rv.get(c)
	if cv != null and cv.optimistic and opt is Array and (opt as Array).size() == 3 \
			and int(opt[0]) == rs and int(opt[1]) == int(msg["same"]):
		_live[c] = [rs, int(msg["same"]), int(opt[2])]
		cv.optimistic = false
		_optimistic_rv.erase(c)
		_optimistic_pending.erase(c)
		ChunkView.count("live_hit")
		if not entry.is_empty():
			_cache.erase(k)
			_cache[k] = entry
		return
	if entry.is_empty() or int(entry["rv"]) != int(msg["same"]):
		Bridge.send({"t": "resync", "c": [[c.x, c.y]]})
		return
	_optimistic_pending.erase(c)
	if cv != null:
		cv.optimistic = false
		_optimistic_rv.erase(c)
	ChunkView.count("cache_hit")
	_cache.erase(k)
	_cache[k] = entry  # the newest again
	_filling[c] = k
	var counts := [rs, int(msg["same"]), int(entry["n"])]
	if queued_replay and Bridge.draining():
		# Handled next, ahead of what came after `same`, the message slice stopping between them: a
		# busy chunk's dozen kept messages took 10-15 ms handled here in one go (client-cpu.md 7).
		var queue: Array = []
		for m: Dictionary in entry["msgs"]:
			queue.append([_replay_one, m])
		for m: Dictionary in entry.get("deltas", []):
			queue.append([_replay_one, m])
		if replay_dec.is_valid():
			for m: Dictionary in entry["dec"]:
				queue.append([replay_dec, m])
		queue.append([_replayed.bind(c, counts), {}])
		Bridge.requeue_front(queue)
		return
	_replaying = true
	for m: Dictionary in entry["msgs"]:
		handle(m)
	for m: Dictionary in entry.get("deltas", []):
		handle(m)
	if replay_dec.is_valid():
		for m: Dictionary in entry["dec"]:
			replay_dec.call(m)
	_replaying = false
	_replayed({}, c, counts)


## Kept chunks are replayed through Bridge's queue (`--kept-replay=inline`: inside `same`, as before).
static var queued_replay := not Switches.has("--kept-replay=inline")


## One of a kept chunk's messages, handled again (not kept again: it is the kept one).
func _replay_one(m: Dictionary) -> void:
	_replaying = true
	handle(m)
	_replaying = false


## A kept chunk's messages are all handled again: it matches the bridge's counts.
func _replayed(_msg: Dictionary, c: Vector2i, live: Array) -> void:
	if chunks.has(c):
		_live[c] = live


## [surface index, cx, cy, rv, n] for a chunk the cache has, fresh enough; empty otherwise.
func _cached_offer(c: Vector2i) -> Array:
	var entry: Dictionary = _cache.get(Vector3i(surface_index, c.x, c.y), {})
	if entry.is_empty() or entry.get("t", false) or entry.get("pending_kept", false) \
			or Time.get_ticks_msec() - int(entry["msec"]) > CACHE_AGE_MSEC:
		return []
	return [surface_index, c.x, c.y, int(entry["rv"]), int(entry["n"])]


## What to offer for a chunk asked for again: a chunk still drawn (WARM_RINGS, held) by the counts its
## drawn copy matches (its snapshot's, or `kept`'s since), else its kept messages'.
func _offer(c: Vector2i) -> Array:
	var cv: ChunkView = chunks.get(c)
	var live: Array = _live.get(c, [])
	if cv != null and cv.loaded and not cv.is_incomplete() and live.size() == 3 and int(live[0]) == surface_index:
		return [surface_index, c.x, c.y, int(live[1]), int(live[2])]
	return _cached_offer(c)


func _apply_ents_message(msg: Dictionary) -> void:
	var cv: ChunkView = chunks.get(Vector2i(int(msg.get("cx", 0)), int(msg.get("cy", 0))))
	if cv != null:
		cv.got_part(int(msg.get("part", 1)))
	if fast_add:
		_batch_joins = true
	if WireDecode.packed(msg.get("e")):
		_add_packed(msg)
	else:
		for rec in Wire.array(msg.get("e")):
			_add(rec)
	if fast_add or _batch_joins:
		_flush_joins()


## A packed `ents` message is applied ENTS_SLICE records at a time: a cache replay's step (_hydrate_step) or a live
## message handled in the message slice was one whole message, ~400 records x 13-15 µs = 5.5 ms against a 0.5-2.5 ms
## slice (FrameBudget.fits always lets the first item through). The joins are flushed at each slice's end, the part
## noted after the last. --ents-slice=off: whole messages as before (also the multi-part cache pack and the
## optimistic queue's sort below).
static var ents_slice := Switches.on("--ents-slice")
const ENTS_SLICE := 64


## How many records a packed `ents` message holds.
static func _ents_count(msg: Dictionary) -> int:
	var e: Variant = msg.get("e")
	if not WireDecode.packed(e):
		return 0
	return int(e.size() / WireDecode.ENT_STRIDE)


## Whether an `ents` message is applied in slices (ents_slice, packed, more than one slice).
static func _ents_sliced(msg: Dictionary) -> bool:
	return ents_slice and _ents_count(msg) > ENTS_SLICE


## Records [from, to) of a packed `ents` message, `xc` its `xi` cursor at `from`; returns the cursor at `to`. The last
## slice notes the part (_apply_ents_message notes it first; nothing in between reads it).
func _apply_ents_range(msg: Dictionary, from: int, to: int, xc: int) -> int:
	if fast_add:
		_batch_joins = true
	var x := _add_packed(msg, from, to, xc)
	if fast_add or _batch_joins:
		_flush_joins()
	if to >= _ents_count(msg):
		var cv: ChunkView = chunks.get(Vector2i(int(msg.get("cx", 0)), int(msg.get("cy", 0))))
		if cv != null:
			cv.got_part(int(msg.get("part", 1)))
	return x


## A live `ents` message while the bridge drains its messages: its first slice now, the others put in front of the
## messages waiting (Bridge.requeue_front), the message slice stopping between them (as `same`'s replay does). All
## queued at once, each with its `xi` cursor worked out here (_xi_cursors), the kind `replay:ents_slice`. Not for a
## message replayed (_replaying, `same`'s queue).
func _apply_ents_live_sliced(msg: Dictionary) -> void:
	var c := Vector2i(int(msg.get("cx", 0)), int(msg.get("cy", 0)))
	var n := _ents_count(msg)
	var cursors := _xi_cursors(msg, n)
	var queue: Array = []
	var cv: Variant = chunks.get(c)
	for k in range(1, cursors.size()):
		var from := k * ENTS_SLICE
		queue.append([_ents_slice_next.bind(msg, c, cv, from, mini(from + ENTS_SLICE, n), cursors[k]), {"t": "ents_slice"}])  # (kind replay:ents_slice)
	_apply_ents_range(msg, 0, mini(ENTS_SLICE, n), 0)
	Bridge.requeue_front(queue)


## The `xi` cursor _add_packed reaches at each slice's first record (0, ENTS_SLICE, ...), without adding anything: the
## cursor moves on past an `xi` entry when its record comes, and stops for good at one that is behind (out of order).
static func _xi_cursors(msg: Dictionary, n: int) -> PackedInt32Array:
	var xi: Variant = msg.get("xi", PackedInt32Array())
	var xe: Variant = msg.get("xe", [])
	if not (xe is Array) or not WireDecode.packed(xi):
		xi = PackedInt32Array()
	var nx: int = mini(xi.size(), (xe as Array).size()) if xe is Array else 0
	var out := PackedInt32Array()
	var x := 0
	var next_i := 0
	var b := 0
	while b < n:
		out.append(x)
		b += ENTS_SLICE
		while x < nx and int(xi[x]) >= next_i and int(xi[x]) < mini(b, n):
			next_i = int(xi[x]) + 1
			x += 1
		next_i = maxi(next_i, mini(b, n))
	return out


## A later slice of a live `ents` message (_apply_ents_live_sliced). Dropped when its chunk went (or came back as
## another ChunkView) meanwhile: _add_fields drops a gone chunk's records anyway.
func _ents_slice_next(_m: Dictionary, msg: Dictionary, c: Vector2i, cv: Variant, from: int, to: int, xc: int) -> void:
	var now: Variant = chunks.get(c)
	if now == null or not is_same(now, cv):
		return
	_apply_ents_range(msg, from, to, xc)


func _commit_staged(c: Vector2i) -> void:
	var st: Variant = _staged_snap.get(c)
	if not (st is Dictionary):
		return
	_staged_snap.erase(c)
	var d := st as Dictionary
	var was_replaying := _replaying
	_replaying = true
	_apply_chunk_immediate(d["chunk"] as Dictionary)
	for m: Dictionary in d["ents"]:
		_apply_ents_message(m)
	for dm: Dictionary in d["deltas"]:
		handle(dm)
	_replaying = was_replaying
	var cv: ChunkView = chunks.get(c)
	if cv != null:
		cv.optimistic = false
		_optimistic_rv.erase(c)
		cv.snapshot_msec = mini(cv.snapshot_msec, int(d.get("msec", cv.snapshot_msec)))
		_dirty[c] = true


func _on_chunk(msg: Dictionary) -> void:
	var c := Vector2i(int(msg.get("cx", 0)), int(msg.get("cy", 0)))
	var cv: ChunkView = chunks.get(c)
	if cv == null:
		return  # no longer wanted
	_optimistic_pending.erase(c)
	_disk_waiting.erase(c)
	var parts := int(msg.get("parts", 1))
	if double_buffer_refresh and not _replaying and cv.loaded and not cv.entities.is_empty() \
			and not msg.get("none", false) and parts >= 1:
		_staged_snap[c] = {
			"chunk": msg,
			"parts_expected": parts,
			"parts_got": {},
			"ents": [],
			"deltas": [],
			"msec": Time.get_ticks_msec(),
		}
		return
	_staged_snap.erase(c)
	_apply_chunk_immediate(msg)


func _apply_chunk_immediate(msg: Dictionary) -> void:
	var c := Vector2i(int(msg.get("cx", 0)), int(msg.get("cy", 0)))
	var cv: ChunkView = chunks.get(c)
	if cv == null:
		return  # no longer wanted
	if not _replaying:
		cv.optimistic = false
		_optimistic_rv.erase(c)
	for key in cv.entities.keys():
		entities.erase(key)
		_forget(key, cv.entities[key])
		if _cargo.has(key) or _cargo_ghosts.has(key):
			_remove_cargo(key)  # a bay gone while the chunk was resent must open its neighbours' sides
	cv.clear_entities()
	for key in _cargo_left.keys():
		if _cargo_left[key] == c:
			_remove_cargo(key)  # left with the chunk before: the snapshot adds it again if it's there
	var before := cv.tile_ids
	var was_loaded := cv.loaded
	if not was_loaded:
		last_arrival_msec = Time.get_ticks_msec()
	if msg.get("none", false):
		_live.erase(c)
		cv.mark_missing()
		cv.start_snapshot(0)
	else:
		if msg.has("rv") and msg.has("rs") and not (cv.optimistic and _replaying):
			_live[c] = [int(msg["rs"]), int(msg["rv"]), int(msg.get("n", 0))]
		var rle: Variant = _list(msg.get("tiles"))
		var ids: Variant = msg.get("_tiles")  # decoded on the bridge's parsing thread (message_decode.gd)
		if not (ids is PackedInt32Array) and WireDecode.packed(rle):
			ids = MessageDecode.tiles_from_runs(rle)  # (--decode-thread=off: a binary frame's runs here)
		if ids is PackedInt32Array and (ids as PackedInt32Array).size() == CHUNK * CHUNK:
			cv.set_tiles(ids)
		else:
			cv.set_tiles_rle(rle)
			msg["_tiles"] = cv.tile_ids
		if cv.tiles_msec == 0:
			cv.tiles_msec = Time.get_ticks_msec()
		cv.start_snapshot(int(msg.get("parts", 1)))
		# Start reading the pictures of new kinds of ground now, before the chunk is meshed.
		if rle.size() >= 2:
			for i in range(0, rle.size(), 2):
				var id := int(rle[i])
				if id < protos.tile_names.size() and not protos.is_void(id):
					TerrainTextures.lookup(protos.tile_names[id])
					TerrainTextures.note(surface_index, protos.tile_names[id])
		elif cv.tile_ids.size() == CHUNK * CHUNK:
			var seen_tids := {}
			for tid: int in cv.tile_ids:
				if not seen_tids.has(tid):
					seen_tids[tid] = true
					if tid < protos.tile_names.size() and not protos.is_void(tid):
						TerrainTextures.lookup(protos.tile_names[tid])
						TerrainTextures.note(surface_index, protos.tile_names[tid])
	_dirty[c] = true
	if track_latency and _wanted_at.has(c):
		_lat_arrived[c] = true  # (--stutter-probe) it can be drawn from now on
	# The mod resends every chunk now and then to heal losses; the ground rarely changed.
	if was_loaded and cv.tile_ids == before:
		if not cv.revealed and cv.has_ground():
			_on_terrain_applied(c, cv)
		return
	_dirty_terrain[c] = true
	_dirty_terrain_around(c)


## K21: a new building (or Shift-placed ghost) the player sent turned in the build cursor, one
## Factorio can't turn (the game put it down unturned), keeps the cursor's turn as a look-only one
## (visual_turns.gd), so _add draws it turned from its first record on. Also preserves a rotated
## ghost's turn when `del` arrived just before the revived building's `add`.
func _claim_turn(a) -> void:
	if not (a is Array) or a.size() < 5 or int(a[0]) <= 0 or entities.has(int(a[0])):
		return
	var unit := int(a[0])
	var proto_id := int(a[1])
	var is_ghost := false
	if a.size() > 5 and a[5] is Dictionary:
		var ex: Dictionary = a[5]
		if ex.has("tg"):
			return
		if ex.has("gh"):
			is_ghost = true
			proto_id = int(ex["gh"])
	var pos := Vector2(int(a[2]), int(a[3])) / 256.0
	if VisualTurns.expecting() and VisualTurns.claim(Bridge.save_id, unit, proto_id, pos, int(a[4])):
		return
	if not is_ghost and VisualTurns.has_revives():
		VisualTurns.claim_revive(Bridge.save_id, unit, proto_id, pos)


## [unit, proto id, x, y, direction, extra?] with x, y in 1/256 tiles.
func _add(a) -> void:
	if not (a is Array) or a.size() < 5:
		return
	_add_fields(int(a[0]), int(a[1]), int(a[2]), int(a[3]), int(a[4]), a[5] if a.size() > 5 else null)


## A binary `ents` part (wire_decode.gd): its records read straight from the packed block, WireDecode.ENT_STRIDE
## numbers each, the extras of those listed in `xi` (ascending) from `xe`. Records [from, to) (to -1: all), `xc` the
## `xi` cursor at `from` (_apply_ents_range); returns the cursor at the end.
func _add_packed(msg: Dictionary, from := 0, to := -1, xc := 0) -> int:
	var list: Variant = msg["e"]
	var xi: Variant = msg.get("xi", PackedInt32Array())
	var xe: Variant = msg.get("xe", [])
	if not (xe is Array) or not WireDecode.packed(xi):
		xi = PackedInt32Array()
	var nx: int = mini(xi.size(), (xe as Array).size()) if xe is Array else 0
	var stride := WireDecode.ENT_STRIDE
	var n: int = list.size() / stride
	var end := n if to < 0 else mini(to, n)
	var x := xc
	for i in range(from, end):
		var a := i * stride
		var extra: Variant = null
		if x < nx and int(xi[x]) == i:
			extra = xe[x]
			x += 1
		_add_fields(int(list[a]), int(list[a + 1]), int(list[a + 2]), int(list[a + 3]), int(list[a + 4]), extra)
	return x


static func _pflags(rp: ProtoDB.EntityProto) -> int:
	if rp == null:
		return 0
	if (rp.flags & ProtoDB.PF_COMPUTED) == 0:
		rp.flags = ProtoDB.flags_for_type(rp.type)
	return rp.flags


func _flush_joins() -> void:
	var tp := Time.get_ticks_usec() if Probing.on else 0
	_flush_joins_do()
	if tp > 0:
		Probing.add("add_joins", tp)  # (--stutter-probe: the batched joins with _add_fields' own)


func _flush_joins_do() -> void:
	_batch_joins = false
	var covers: Array = _join_covers.keys() if not _join_covers.is_empty() else []
	_join_covers.clear()
	if not _join_walls.is_empty():
		var seen := {}
		for tile: Vector2i in _join_walls:
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var nt := tile + Vector2i(dx, dy)
					if not seen.has(nt) and _walls.has(nt):
						seen[nt] = true
						_connect_wall(nt)
		_join_walls.clear()
	if not _join_belts.is_empty():
		var seen := {}
		for tile: Vector2i in _join_belts:
			if not seen.has(tile) and _belts.has(tile):
				seen[tile] = true
				_connect_belt(tile)
			for step: Vector2i in PIPE_STEPS:
				var nt: Vector2i = tile + step
				if not seen.has(nt) and _belts.has(nt):
					seen[nt] = true
					_connect_belt(nt)
		_join_belts.clear()
	if not _join_pipes.is_empty():
		var seen := {}
		for tile: Vector2i in _join_pipes:
			if not seen.has(tile) and _pipes.has(tile):
				seen[tile] = true
				_connect_pipe(tile)
			for step: Vector2i in PIPE_STEPS:
				var nt: Vector2i = tile + step
				if not seen.has(nt) and _pipes.has(nt):
					seen[nt] = true
					_connect_pipe(nt)
		_join_pipes.clear()
	if not _join_cargo_rects.is_empty():
		var nears: Array = []
		for rect: Rect2i in _join_cargo_rects:
			var near := rect.grow(4)
			nears.append(near)
			for corner in [near.position, near.end, Vector2i(near.position.x, near.end.y), Vector2i(near.end.x, near.position.y)]:
				var c := chunk_of(Vector2(corner))
				if chunks.has(c):
					_dirty[c] = true
		_join_cargo_rects.clear()
		for key in _cargo:
			var crect: Rect2i = _cargo[key]
			for near: Rect2i in nears:
				if near.intersects(crect):
					var r: Rec = entities.get(key)
					if r != null and (_pflags(protos.entity(r.proto_id)) & ProtoDB.PF_CARGO_BAY) != 0:
						_connect_cargo(r)
					break
	if not covers.is_empty():
		var tc := Time.get_ticks_usec() if Probing.on else 0
		for key in covers:
			var cr: Rec = entities.get(key)
			if cr != null:
				_cover(cr)
		if tc > 0:
			Probing.add("add_covers", tc)


func _add_fields(unit: int, proto_id: int, fx: int, fy: int, dir: int, extra: Variant) -> void:
	var tp := Time.get_ticks_usec() if Probing.on else 0  # (--stutter-probe: add_rec, add_pick, add_joins)
	var r := Rec.new()
	r.unit = unit
	r.proto_id = proto_id
	r.fixed = Vector2i(fx, fy)
	r.pos = Vector2(r.fixed) / 256.0
	r.dir = dir
	if extra is Dictionary:
		r.extra = extra
		if r.extra.has("pc"):
			r.extra["pc_mod"] = true
		# A cliff has no direction of its own: its piece is turned to its orientation.
		if not fast_add or r.extra.has("co"):
			var cliff = ModelLibrary.CLIFF_PIECES.get(str(r.extra.get("co", "")))
			if cliff != null:
				r.dir = int(cliff[1])
	# A building turned in Zenith alone (I9, visual_turns.gd) stands turned whatever the game says.
	if r.unit > 0 and VisualTurns.any(Bridge.save_id):
		r.dir = posmod(r.dir + 4 * VisualTurns.quarters(Bridge.save_id, r.unit), 16)
	# A building drawn with a pack's model of its own (M8, building_models.gd), whatever the order.
	if r.unit > 0 and BuildingModels.any(Bridge.save_id):
		var own := BuildingModels.pack_for(Bridge.save_id, r.unit)
		if own != "":
			r.extra[ModelLibrary.PACK_KEY] = own
	# Which of its model's variants it is drawn with (ModelLibrary.pick_variant): from its position, the
	# same on every load. Set here, before any worker can read the record's `extra`.
	r.extra[ModelLibrary.VARIANT_KEY] = ModelLibrary.ModelPacks.variant_seed(r.fixed)
	r.key = r.unit if r.unit > 0 else static_key(r.proto_id, r.fixed.x, r.fixed.y)
	if not _mined_early.is_empty() and _mined_early.has(r.key):
		if Time.get_ticks_msec() - int(_mined_early[r.key]) < MINED_EARLY_MSEC:
			return  # mined (`mnd`): this record was read before
		_mined_early.erase(r.key)
	r.chunk = chunk_of(r.pos)
	var cv: ChunkView = chunks.get(r.chunk)
	if cv == null:
		return
	if r.unit != 0 and working.has(r.unit):
		_stated_in(r.chunk)[r.unit] = true
	if entities.has(r.key):
		_remove(r.key)
	# A ghost (extra.gh) goes when its entity is built on its spot, which robots do without telling.
	if r.extra.has("tg"):
		_tile_ghosts[Vector2i(floori(r.pos.x), floori(r.pos.y))] = r.key
	var rp := protos.entity(r.proto_id)
	var is_ghost := r.extra.has("gh")
	if is_ghost:
		_ghosts[r.fixed] = r.key
		if not _ghosts_by_chunk.has(r.chunk):
			_ghosts_by_chunk[r.chunk] = {}
		(_ghosts_by_chunk[r.chunk] as Dictionary)[r.key] = r
	else:
		if not r.extra.has("tg") and _ghosts.has(r.fixed):
			var ghost: Rec = entities.get(_ghosts[r.fixed])
			if ghost != null and (int(ghost.extra.get("gh", 0)) == r.proto_id or (rp != null and rp.type != "resource" and rp.type != "tile-ghost" and not rp.type.begins_with("elevated-") and not ModelLibrary.REMNANT_TYPES.has(rp.type))):
				if not _replaying and int(ghost.extra.get("gh", 0)) == r.proto_id and ghost.unit > 0 and r.unit > 0:
					var gq := VisualTurns.quarters(Bridge.save_id, ghost.unit)
					if gq > 0:
						if VisualTurns.quarters(Bridge.save_id, r.unit) == 0:
							VisualTurns.set_quarters(Bridge.save_id, r.unit, gq)
							r.dir = posmod(r.dir + 4 * gq, 16)
						VisualTurns.forget(Bridge.save_id, ghost.unit)
				_remove(ghost.key)
		if not r.extra.has("tg") and not _ghosts_by_chunk.is_empty():
			_clear_overlapping_ghosts(r, rp)
	entities[r.key] = r
	cv.entities[r.key] = r
	cv.content_rev += 1
	if not is_ghost and r.unit > 0 and rp != null and rp.type == "rocket-silo":
		silo_positions[r.unit] = r.pos
		_dirty_silo_terrain(r.pos)
	if r.extra.has("ai") and not alt_icon(r).is_empty():
		cv.alt[r.key] = r
	if tp > 0:
		Probing.add("add_rec", tp)
		tp = Time.get_ticks_usec()
	_pick_grid_add(cv, r)
	if tp > 0:
		Probing.add("add_pick", tp)
		tp = Time.get_ticks_usec()
	if not fast_add:
		if rp != null and ModelLibrary.REMNANT_TYPES.has(rp.type):
			_remnants[r.key] = r
		_mark_dirty(r.chunk)
		if _is_pipe(r):
			_pipes[_tile_of(r)] = r.key
			_connect_pipes_around(_tile_of(r))
			_cover_towards(_tile_of(r))
		elif _has_ports(r):
			_add_ports(r)
		if _is_belt(r):
			for t in _belt_tiles(r):
				_belts[t] = r.key
				_connect_belts_around(t)
		if _is_wall(r):
			_walls[_tile_of(r)] = r.key
			_connect_walls_around(_tile_of(r))
		if _is_cargo(r):
			_add_cargo(r, false)
		elif _is_cargo_ghost(r):
			_add_cargo(r, true)
		if tp > 0:
			Probing.add("add_joins", tp)
		return
	var pf := _pflags(rp)
	if (pf & ProtoDB.PF_REMNANT) != 0:
		_remnants[r.key] = r
	_mark_dirty(r.chunk)
	if not is_ghost:
		if (pf & ProtoDB.PF_PIPE_ANY) != 0:
			var tile := _tile_of(r)
			_pipes[tile] = r.key
			if r.extra.has("pc_mod") and not _has_local_pipes:
				if (pf & ProtoDB.PF_PIPE_PLAIN) != 0 and posmod(tile.x + tile.y, 2) == 0:
					r.extra["pw"] = 1
				if not _port_targets.is_empty():
					var tc := Time.get_ticks_usec() if tp > 0 else 0
					_cover_towards(tile)
					if tc > 0:
						Probing.add("add_covers", tc)  # (--stutter-probe: inside add_joins)
			else:
				_has_local_pipes = true
				if _batch_joins:
					_join_pipes[tile] = true
				else:
					_connect_pipes_around(tile)
				if not _port_targets.is_empty():
					var tc := Time.get_ticks_usec() if tp > 0 else 0
					_cover_towards(tile)
					if tc > 0:
						Probing.add("add_covers", tc)  # (--stutter-probe: inside add_joins)
		elif _has_ports(r):
			var tc2 := Time.get_ticks_usec() if tp > 0 else 0
			_add_ports(r)
			if tc2 > 0:
				Probing.add("add_covers", tc2)
		if (pf & ProtoDB.PF_BELT) != 0:
			if _belt_ends_on < 0:
				_belt_ends_on = 1 if ModelLibrary.has_belt_ends() else 0
			if _belt_ends_on != 0:
				for t in _belt_tiles(r):
					_belts[t] = r.key
					if _batch_joins:
						_join_belts[t] = true
					else:
						_connect_belts_around(t)
		if (pf & ProtoDB.PF_WALL_ANY) != 0:
			var wtile := _tile_of(r)
			_walls[wtile] = r.key
			if _batch_joins:
				_join_walls[wtile] = true
			else:
				_connect_walls_around(wtile)
		if (pf & ProtoDB.PF_CARGO) != 0:
			_add_cargo(r, false)
	else:
		var gp := protos.entity(int(r.extra["gh"]))
		if (_pflags(gp) & ProtoDB.PF_CARGO) != 0:
			_add_cargo(r, true)
	if tp > 0:
		Probing.add("add_joins", tp)


## Alt-mode's icons that changed with no new record (issue #9, `aiu`): [unit, kind, name, more?],
## kind "" when it shows none now. Only the icon changes; the chunk isn't drawn again.
func _on_alt_icons(list: Array) -> void:
	for row in list:
		if not (row is Array) or row.size() < 2:
			continue
		var r: Rec = entities.get(int(row[0]))
		if r == null:
			continue
		var cv: ChunkView = chunks.get(r.chunk)
		if str(row[1]) == "" or row.size() < 3:
			r.extra.erase("ai")
			if cv != null:
				cv.alt.erase(r.key)
			continue
		r.extra["ai"] = row.slice(1)
		if cv != null:
			cv.alt[r.key] = r


## Chests whose Alt-mode contents changed (`ac`, J6): [unit, item, [more]?], or [unit] for none.
## An answer to an earlier turning on of Alt-mode (or one while it is off) is dropped; the first
## answer to a new one starts the list over.
func _on_alt_contents(msg: Dictionary) -> void:
	var g := int(msg.get("g", -1))
	if g <= 0 or g != Bridge.alt_contents:
		return
	if g != _alt_contents_g:
		_alt_contents_g = g
		alt_contents.clear()
	for row in Wire.array(msg.get("l")):
		if not (row is Array) or row.is_empty():
			continue
		var unit := int(row[0])
		if row.size() < 2 or str(row[1]) == "":
			alt_contents.erase(unit)
			continue
		var names: Array[String] = [str(row[1])]
		if row.size() >= 3 and row[2] is Array:
			for n in row[2]:
				names.append(str(n))
		alt_contents[unit] = names


## Alt-mode's chest contents to draw now: {} while Alt-mode is off or before the bridge answered.
func alt_contents_now() -> Dictionary:
	return alt_contents if _alt_contents_g > 0 and _alt_contents_g == Bridge.alt_contents else {}


## Machines whose modules or science packs changed (`am`, K1, K2): [unit, modules or 0, [packs]?],
## or [unit] for none; each item a name or [name, quality]; a turret's ammo and a locomotive's fuel
## come where the packs do. Kept by `g` as `ac` is.
func _on_alt_machines(msg: Dictionary) -> void:
	var g := int(msg.get("g", -1))
	if g <= 0 or g != Bridge.alt_contents:
		return
	if g != _alt_machines_g:
		_alt_machines_g = g
		alt_machines.clear()
	for row in Wire.array(msg.get("l")):
		if not (row is Array) or row.is_empty():
			continue
		var unit := int(row[0])
		var modules := _alt_items(row[1] if row.size() > 1 else null)
		var packs := _alt_items(row[2] if row.size() > 2 else null)
		if modules.is_empty() and packs.is_empty():
			alt_machines.erase(unit)
		else:
			alt_machines[unit] = [modules, packs]


## An `am` list as [[item, quality], ...] (quality "" for normal); [] for 0 or anything else.
static func _alt_items(v: Variant) -> Array:
	var out: Array = []
	if not (v is Array):
		return out
	for it in v:
		if it is Array and it.size() >= 2:
			out.append([str(it[0]), str(it[1])])
		elif it is String and it != "":
			out.append([it, ""])
	return out


## Alt-mode's machine icons to draw now: {} while Alt-mode is off or before the bridge answered.
func alt_machines_now() -> Dictionary:
	return alt_machines if _alt_machines_g > 0 and _alt_machines_g == Bridge.alt_contents else {}


## A crafting machine's recipe's fluids changed (`aiu` fa: [unit, mask], 1 in, 2 out): Alt-mode's
## machine arrows (alt_arrows.gd) follow.
func _on_alt_fluids(list: Array) -> void:
	for row in list:
		if not (row is Array) or row.size() < 2:
			continue
		var r: Rec = entities.get(int(row[0]))
		if r == null:
			continue
		# A mining drill's fluid input (bit 1: the resource under it needs fluid) draws its `-wet` part
		# (model_library.gd wet_model): its chunk is drawn again when that changes.
		if (int(r.extra.get("fa", 0)) & 1) != (int(row[1]) & 1) and ModelLibrary.drill_wet:
			var rp := protos.entity(r.proto_id)
			if rp != null and rp.type == "mining-drill":
				_dirty[r.chunk] = true
		if int(row[1]) > 0:
			r.extra["fa"] = int(row[1])
		else:
			r.extra.erase("fa")
		_cover(r)  # a drill's connections show while it takes fluid, a machine's those its recipe uses
		_cover_facing(r)  # and the machines they meet
		# L10: which fluid goes in or out where, with the mask (a bridge from before sends none).
		if row.size() >= 3 and row[2] is Array and int(row[1]) > 0:
			r.extra["fc"] = row[2]
		else:
			r.extra.erase("fc")
		r.cache_gen = -1
		alt_changed.emit(r.chunk)


## Alt-mode's icon of a record as [kind, name, more names...], or [] for none.
static func alt_icon(r: Rec) -> Array:
	var ai = r.extra.get("ai")
	if not (ai is Array) or ai.size() < 2 or str(ai[1]) == "":
		return []
	var icon := [str(ai[0]), str(ai[1])]
	if ai.size() >= 3 and ai[2] is Array:  # a filter inserter's other filters
		for f in ai[2]:
			icon.append(str(f))
	return icon


## Factorio removes remnants an entity is built over (CorpsePrototype remove_on_entity_placement).
func _clear_remnants_under(a) -> void:
	if _remnants.is_empty() or not (a is Array) or a.size() < 5:
		return
	var proto := protos.entity(int(a[1]))
	if proto == null or ModelLibrary.REMNANT_TYPES.has(proto.type) or ModelLibrary.hidden(proto.name):
		return
	var pos := Vector2(int(a[2]), int(a[3])) / 256.0
	var lo := proto.box_min
	var hi := proto.box_max
	if int(a[4]) % 8 == 4:  # east or west: the box turns
		lo = Vector2(-proto.box_max.y, proto.box_min.x)
		hi = Vector2(-proto.box_min.y, proto.box_max.x)
	var box := Rect2(pos + lo, hi - lo)
	for key in _remnants.keys():
		var r: Rec = _remnants[key]
		if box.has_point(r.pos):
			_remove(key)


## Keys are unit numbers (int) or static keys (String: static_key); == between the two is an error
## in GDScript ("Invalid operands 'int' and 'String'"), so the places a belt, pipe, wall or ghost
## holds are compared through this.
static func _same_key(held, key) -> bool:
	return typeof(held) == typeof(key) and held == key


func _remove(key) -> void:
	_remnants.erase(key)
	var r: Rec = entities.get(key)
	if r == null:
		return
	entities.erase(key)
	if r.unit > 0 and not lamp_colors.is_empty():
		lamp_colors.erase(r.unit)
	if r.unit > 0 and not lamp_always.is_empty():
		lamp_always.erase(r.unit)
	if _same_key(_ghosts.get(r.fixed), key):
		_ghosts.erase(r.fixed)
	_forget_chunk_ghost(r.chunk, key)
	var tile := Vector2i(floori(r.pos.x), floori(r.pos.y))
	if _same_key(_tile_ghosts.get(tile), key):
		_tile_ghosts.erase(tile)
	if _same_key(_pipes.get(_tile_of(r)), key):
		_pipes.erase(_tile_of(r))
		if _batch_joins:
			_join_pipes[_tile_of(r)] = true
		else:
			_connect_pipes_around(_tile_of(r))
		if not _port_targets.is_empty():
			_cover_towards(_tile_of(r))
	_remove_ports(r, true)
	for t in _belt_tiles(r):
		if _same_key(_belts.get(t), key):
			_belts.erase(t)
			if _batch_joins:
				_join_belts[t] = true
			else:
				_connect_belts_around(t)
	if _same_key(_walls.get(_tile_of(r)), key):
		_walls.erase(_tile_of(r))
		if _batch_joins:
			_join_walls[_tile_of(r)] = true
		else:
			_connect_walls_around(_tile_of(r))
	if _cargo.has(key) or _cargo_ghosts.has(key):
		_remove_cargo(key)
	if r.unit > 0 and silo_positions.has(r.unit):
		var old_silo_pos: Vector2 = silo_positions[r.unit]
		silo_positions.erase(r.unit)
		_dirty_silo_terrain(old_silo_pos)
	var cv: ChunkView = chunks.get(r.chunk)
	if cv != null:
		cv.entities.erase(key)
		cv.alt.erase(key)
		_pick_grid_remove(cv, r)
		cv.content_rev += 1
		_mark_dirty(r.chunk)


## A record that leaves with its chunk (resent, or unloaded) out of the tables kept beside
## `entities`, without redrawing its neighbours: a resent chunk adds its records again at once,
## an unloaded one isn't drawn. Cargo areas are the caller's (_on_chunk, _left_with_chunk).
func _forget(key, r: Rec) -> void:
	_remnants.erase(key)
	if _same_key(_ghosts.get(r.fixed), key):
		_ghosts.erase(r.fixed)
	_forget_chunk_ghost(r.chunk, key)
	var tile := _tile_of(r)
	if _same_key(_tile_ghosts.get(tile), key):
		_tile_ghosts.erase(tile)
	# (covers_batch: only the tables its prototype goes in, as _add_fields puts it there with --world-fast-add; every
	# table when its prototype is gone, a new welcome's protos without it: it may still stand in any of them.)
	var fp: ProtoDB.EntityProto = protos.entity(r.proto_id) if covers_batch and fast_add else null
	var pf := _pflags(fp) if fp != null else -1
	if (pf & ProtoDB.PF_PIPE_ANY) != 0 and _same_key(_pipes.get(tile), key):
		_pipes.erase(tile)
	if (pf & ProtoDB.PF_WALL_ANY) != 0 and _same_key(_walls.get(tile), key):
		_walls.erase(tile)
	_remove_ports(r, false)
	if (pf & ProtoDB.PF_BELT) != 0:
		for t in _belt_tiles(r):
			if _same_key(_belts.get(t), key):
				_belts.erase(t)
	if r.unit > 0 and silo_positions.has(r.unit):
		var old_silo_pos: Vector2 = silo_positions[r.unit]
		silo_positions.erase(r.unit)
		_dirty_silo_terrain(old_silo_pos)


## A record of an unloaded chunk leaving `entities` (_free_unloaded). A hub's or bay's area stays
## while its chunk is away (_cargo_left); if the chunk is back and drawn without it, it is gone.
func _left_with_chunk(key, r: Rec) -> void:
	_forget(key, r)
	if not (_cargo.has(key) or _cargo_ghosts.has(key)):
		return
	var back: ChunkView = chunks.get(r.chunk)
	if back != null and back.loaded:
		_remove_cargo(key)
	else:
		_cargo_left[key] = r.chunk


func _forget_chunk_ghost(c: Vector2i, key) -> void:
	var gc: Variant = _ghosts_by_chunk.get(c)
	if gc is Dictionary:
		var d: Dictionary = gc
		d.erase(key)
		if d.is_empty():
			_ghosts_by_chunk.erase(c)


static func _footprint_rect(proto: ProtoDB.EntityProto, pos: Vector2, dir: int) -> Rect2:
	var ts := proto.tile_size
	if ts.x <= 0 or ts.y <= 0:
		return Rect2()
	if posmod(int(round(dir / 4.0)), 2) == 1:
		ts = Vector2i(ts.y, ts.x)
	return Rect2(pos - Vector2(ts) * 0.5, Vector2(ts)).grow(-0.05)


func _clear_overlapping_ghosts(r: Rec, rp: ProtoDB.EntityProto) -> void:
	if rp == null or rp.type == "resource" or rp.type == "entity-ghost" or rp.type == "tile-ghost" or rp.type.begins_with("elevated-") or ModelLibrary.REMNANT_TYPES.has(rp.type):
		return
	var area := _footprint_rect(rp, r.pos, r.dir)
	if not area.has_area():
		return
	var expanded := area.grow(4.0)
	var c_lo := chunk_of(expanded.position)
	var c_hi := chunk_of(expanded.end)
	var to_remove: Array = []
	for cy in range(c_lo.y, c_hi.y + 1):
		for cx in range(c_lo.x, c_hi.x + 1):
			var gc: Variant = _ghosts_by_chunk.get(Vector2i(cx, cy))
			if not (gc is Dictionary):
				continue
			for g_key in (gc as Dictionary):
				var g: Rec = (gc as Dictionary)[g_key]
				if g == null or _same_key(g.key, r.key):
					continue
				var g_shape: ProtoDB.EntityProto = protos.entity(int(g.extra.get("gh", 0))) if g.extra.has("gh") else protos.entity(g.proto_id)
				if g_shape == null or g_shape.type.begins_with("elevated-"):
					continue
				if _footprint_rect(g_shape, g.pos, g.dir).intersects(area):
					to_remove.append(g.key)
	for g_key in to_remove:
		_remove(g_key)


## Pipes are drawn with the piece of Factorio's pipe kit that matches their connections
## (model_library.gd): `extra.pc`, a bit each for north, east, south, west (1, 2, 4, 8). The real
## mod sends it (pipe_mask in world.lua, machines included) and is trusted; for older mods and
## the mock it's worked out here from neighbouring pipes and pipes-to-ground, so a pipe ending
## at a machine shows an end cap there.
const PIPE_STEPS := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]


## Where a line of belts begins and ends, for a modeller's end pieces (ModelLibrary.belt_end_places):
## the record's `belt_ends`, per tile it stands on (two bits each: a splitter's halves are 1, 2 and 4, 8),
## 1 for nothing feeding it from behind, 2 for nothing carrying its line on in front (nothing takes its
## items, or it side-loads them onto another's side: belt_continues). Straight belts, splitters and
## undergrounds' open ends (an entrance's back, an exit's front) get them; curves only their ends. Only
## worked out when such models exist: Zenith's own belts have none.
const BELT_TYPES := ["transport-belt", "underground-belt", "linked-belt", "splitter", "lane-splitter", "loader", "loader-1x1"]
## The belt-like types that get end pieces (loaders feed and take, but have none).
const CAPPED_TYPES := ["transport-belt", "underground-belt", "linked-belt", "splitter", "lane-splitter"]


func _is_belt(r: Rec) -> bool:
	if _belt_ends_on < 0:
		_belt_ends_on = 1 if ModelLibrary.has_belt_ends() else 0
	if _belt_ends_on == 0 or r.extra.has("gh"):
		return false  # a ghost neither feeds nor takes
	var proto: ProtoDB.EntityProto = protos.entity(r.proto_id)
	return proto != null and BELT_TYPES.has(proto.type)


## The tiles it stands on: one, or two for a splitter or a long loader (centred on a tile's edge).
static func _belt_tiles(r: Rec) -> Array:
	return ModelLibrary.belt_tiles(r.pos)


func _connect_belts_around(tile: Vector2i) -> void:
	_connect_belt(tile)
	for step in PIPE_STEPS:
		_connect_belt(tile + step)


func _connect_belt(tile: Vector2i) -> void:
	var r: Rec = entities.get(_belts.get(tile, -1))
	if r == null:
		return
	var rp := protos.entity(r.proto_id)
	var pf := _pflags(rp)
	if (pf & ProtoDB.PF_BELT_CAPPED) == 0:
		return
	var step: Vector2i = PIPE_STEPS[(r.dir >> 2) & 3]
	var under := str(r.extra.get("u", "i")) if (pf & ProtoDB.PF_BELT_UNDER) != 0 else ""
	# A curve is fed from its side by what made it a curve; an underground's entrance ends under the
	# ground and its exit begins there.
	var starts := under != "o" and str(r.extra.get("s", "s")) == "s"
	var ends := under != "i"
	var mask := 0
	var tiles := _belt_tiles(r)
	for i in tiles.size():
		var t: Vector2i = tiles[i]
		if starts and not _belt_fed(r, t - step):
			mask |= 1 << (2 * i)
		if ends and not _belt_taken(r, t + step):
			mask |= 2 << (2 * i)
	if r.belt_ends != mask:
		r.belt_ends = mask
		r.cache_gen = -1
		_mark_dirty(r.chunk)


## Whether what stands on `tile` (behind r) sends its items onto r.
func _belt_fed(r: Rec, tile: Vector2i) -> bool:
	var back: Rec = entities.get(_belts.get(tile, -1))
	return back != null and back != r and belt_feeds(r.dir, protos.entity(back.proto_id).type, back.dir, str(back.extra.get("u", "")))


## Whether what stands on `tile` (in front of r) carries r's line on, so r has no end piece there.
func _belt_taken(r: Rec, tile: Vector2i) -> bool:
	var front: Rec = entities.get(_belts.get(tile, -1))
	return front != null and front != r and belt_continues(r.dir, protos.entity(front.proto_id).type, front.dir,
		str(front.extra.get("u", "")), str(front.extra.get("s", "s")))


## Whether something behind a belt going `dir` sends its items onto it.
static func belt_feeds(dir: int, type: String, other_dir: int, end: String) -> bool:
	if other_dir != dir:
		return false
	return end == "o" if type == "underground-belt" or type == "linked-belt" else true


## Whether something in front of a belt going `dir` carries its line on, so the belt ends there without
## its end piece: from behind, a belt, a splitter, a loader or an underground's entrance (not an exit's
## back); from the side, only a curve this belt makes (`shape` "l" is fed from the left as its items go,
## "r" from the right). A belt facing into the side of a straight belt, of a curve fed from its other
## side or of an underground side-loads: its items go on, but Factorio draws its ending sprite there (as
## where nothing takes them), so it gets its end piece. Head-on, nothing.
static func belt_continues(dir: int, type: String, other_dir: int, end: String, shape := "s") -> bool:
	if other_dir == dir:
		if type == "underground-belt" or type == "linked-belt":
			return end != "o"
		return true
	if type != "transport-belt":
		return false
	if shape == "l":
		return other_dir == (dir + 12) % 16
	if shape == "r":
		return other_dir == (dir + 4) % 16
	return false


func _is_pipe(r: Rec) -> bool:
	var proto: ProtoDB.EntityProto = protos.entity(r.proto_id)
	return proto != null and (proto.type == "pipe" or proto.type == "infinity-pipe" or proto.type == "pipe-to-ground" or proto.type == "heat-pipe") 		and not r.extra.has("gh")


static func _tile_of(r: Rec) -> Vector2i:
	return Vector2i(floori(r.pos.x), floori(r.pos.y))


## The pipe, pipe to ground or heat pipe on `tile`, or null.
func pipe_at(tile: Vector2i) -> Rec:
	return entities.get(_pipes.get(tile, -1))


## Pipe covers (pipe_covers.gd): the prototypes' fluid connections from the UI's `eprops` (main.gd, as they
## arrive); every record's covers worked out again.
func fluid_ports_from(eprops: Dictionary) -> void:
	_fluid_ports.clear()
	_port_memo.clear()
	_drawn_memo.clear()
	for id in eprops:
		var fb = (eprops[id] as Dictionary).get("x", {}).get("fb") if eprops[id] is Dictionary else null
		if fb is Array and not (fb as Array).is_empty():
			_fluid_ports[int(id)] = fb
	_port_tiles.clear()
	_port_targets.clear()
	var with_ports: Array = []
	for r: Rec in entities.values():
		if r.covers != 0:
			r.covers = 0
			_dirty[r.chunk] = true
		if not _is_pipe(r) and _has_ports(r):
			_note_ports(r)
			with_ports.append(r)
	for r: Rec in with_ports:
		_cover(r)


func _has_ports(r: Rec) -> bool:
	return PipeCovers.enabled and _fluid_ports.has(r.proto_id) and not r.extra.has("gh")


## Pipe covers worked out once a message (_add_ports while _batch_joins): records' fluid connections are noted as they
## come and the machines whose covers may change (added, facing one added or taken away, leading onto a pipe that
## came or went) gathered in _join_covers, each _cover'ed once in _flush_joins_do with every record of the message in.
## Each machine's _cover ran per record before (a pipe's every machine facing it, a machine's every neighbour), each
## working out its connections' tiles again (x_world_all's `add_joins` 19.9 ms for one message). Connections' turned
## offsets kept per (prototype, direction) and PipeCovers.ports per (prototype, `fa`) (_port_memo, _drawn_memo; no
## caller changes the arrays). Also _forget skips the pipe, wall and belt tables a record's prototype isn't in
## (with --world-fast-add). --covers-batch=off: as before.
static var covers_batch := Switches.on("--covers-batch")
var _join_covers := {}  # key -> true: machines to _cover when the joins are flushed
var _port_memo := {}  # Vector2i(proto id, dir) -> [[turned offset, way, index in fb], ...]
var _drawn_memo := {}  # Vector2i(proto id, fa) -> PipeCovers.ports
var _memo_protos := -1  # protos.version the memos were made for


func _check_cover_memos() -> void:
	if _memo_protos != protos.version:
		_memo_protos = protos.version
		_port_memo.clear()
		_drawn_memo.clear()


## PipeCovers.ports for a record's prototype and `fa` (memo with covers_batch). Not to be changed by the caller.
func _drawn_ports(proto_id: int, fa: int) -> Array:
	if not covers_batch:
		var proto: ProtoDB.EntityProto = protos.entity(proto_id)
		return PipeCovers.ports(_fluid_ports.get(proto_id), proto.type if proto != null else "", fa)
	_check_cover_memos()
	var k := Vector2i(proto_id, fa)
	var got: Variant = _drawn_memo.get(k)
	if got == null:
		var proto: ProtoDB.EntityProto = protos.entity(proto_id)
		got = PipeCovers.ports(_fluid_ports.get(proto_id), proto.type if proto != null else "", fa)
		_drawn_memo[k] = got
	return got


## A record's connections as tiles: [[its own tile, the tile it leads onto, index in fb], ...], all of them.
func _port_tiles_of(r: Rec) -> Array:
	if covers_batch:
		_check_cover_memos()
		var mk := Vector2i(r.proto_id, r.dir)
		var offs: Variant = _port_memo.get(mk)
		if offs == null:
			offs = _port_offsets(r.proto_id, r.dir)
			_port_memo[mk] = offs
		var res: Array = []
		for o: Array in offs:
			var at2: Vector2 = r.pos + (o[0] as Vector2)
			var own2 := Vector2i(floori(at2.x), floori(at2.y))
			res.append([own2, own2 + (o[1] as Vector2i), o[2]])
		return res
	var out: Array = []
	var fb: Array = _fluid_ports.get(r.proto_id, [])
	var turn := -Wire.direction_yaw(r.dir)
	for i in fb.size():
		var c = fb[i]
		if not (c is Array) or c.size() < 3:
			continue
		var at := r.pos + Vector2(float(c[0]), float(c[1])).rotated(turn)
		var own := Vector2i(floori(at.x), floori(at.y))
		var way := Vector2(0, -1).rotated(-Wire.direction_yaw(int(c[2]) + r.dir)).round()
		out.append([own, own + Vector2i(way), i])
	return out


## _port_tiles_of's offsets for a prototype turned `dir`: [[offset turned, the way it leads, index in fb], ...].
func _port_offsets(proto_id: int, dir: int) -> Array:
	var out: Array = []
	var fb: Array = _fluid_ports.get(proto_id, [])
	var turn := -Wire.direction_yaw(dir)
	for i in fb.size():
		var c = fb[i]
		if not (c is Array) or c.size() < 3:
			continue
		var way := Vector2(0, -1).rotated(-Wire.direction_yaw(int(c[2]) + dir)).round()
		out.append([Vector2(float(c[0]), float(c[1])).rotated(turn), Vector2i(way), i])
	return out


func _note_ports(r: Rec) -> void:
	for port: Array in _port_tiles_of(r):
		_port_tiles[port[0]] = r.key
		var keys: Array = _port_targets.get(port[1], [])
		if not keys.has(r.key):
			keys.append(r.key)
		_port_targets[port[1]] = keys


func _add_ports(r: Rec) -> void:
	_note_ports(r)
	if covers_batch and _batch_joins:
		_join_covers[r.key] = true
		_facing_keys(r)
		return
	_cover(r)
	_cover_facing(r)


## The machines _cover_facing would cover, into _join_covers.
func _facing_keys(r: Rec) -> void:
	for port: Array in _port_tiles_of(r):
		var other: Rec = entities.get(_port_tiles.get(port[1], -1))
		if other != null and other != r:
			_join_covers[other.key] = true


## A record leaving takes its connections away; `redraw`: the machines whose connections met them show
## their covers (not when it leaves with its chunk).
func _remove_ports(r: Rec, redraw: bool) -> void:
	if _fluid_ports.is_empty() or not _fluid_ports.has(r.proto_id):
		return
	for port: Array in _port_tiles_of(r):
		if _same_key(_port_tiles.get(port[0]), r.key):
			_port_tiles.erase(port[0])
		var keys: Array = _port_targets.get(port[1], [])
		keys.erase(r.key)
		if keys.is_empty():
			_port_targets.erase(port[1])
	if redraw:
		if covers_batch and _batch_joins:
			_facing_keys(r)
		else:
			_cover_facing(r)


## The machines with a connection on the tiles `r`'s connections lead onto.
func _cover_facing(r: Rec) -> void:
	for port: Array in _port_tiles_of(r):
		var other: Rec = entities.get(_port_tiles.get(port[1], -1))
		if other != null and other != r:
			_cover(other)


## The machines whose connections lead onto `tile` (a pipe built or taken away there).
func _cover_towards(tile: Vector2i) -> void:
	if covers_batch and _batch_joins:
		for bkey in _port_targets.get(tile, []):
			_join_covers[bkey] = true
		return
	for key in _port_targets.get(tile, []):
		var r: Rec = entities.get(key)
		if r != null:
			_cover(r)


## A record's `covers`: its connections drawn (PipeCovers.ports) that nothing is connected to.
func _cover(r: Rec) -> void:
	var mask := 0
	var drawn: Array = []
	if _has_ports(r) and entities.has(r.key):
		drawn = _drawn_ports(r.proto_id, int(r.extra.get("fa", 0)))
		if not drawn.is_empty():
			var tiles := _port_tiles_of(r)
			for port: Array in drawn:
				for t: Array in tiles:
					if int(t[2]) == int(port[2]) and not _port_connected(r, t[0], t[1]):
						mask |= 1 << int(port[2])
	r.cover_ports = drawn
	if r.covers != mask:
		r.covers = mask
		r.cache_gen = -1
		_mark_dirty(r.chunk)


## Whether a connection of `r` on tile `own` leading onto `next` meets something: a pipe there whose `pc`
## reaches back (the bridge's; one worked out here joins pipes alone, so any pipe), a pipe to ground facing
## it, or another machine with a connection on `next` leading back onto `own`.
func _port_connected(r: Rec, own: Vector2i, next: Vector2i) -> bool:
	var back := PIPE_STEPS.find(own - next)
	var pipe := pipe_at(next)
	if pipe != null:
		var type := protos.entity(pipe.proto_id).type
		if type == "pipe" or type == "infinity-pipe":
			return not pipe.extra.has("pc_mod") or (back >= 0 and int(pipe.extra.get("pc", 0)) & (1 << back) != 0)
		if type == "pipe-to-ground":
			return back >= 0 and pipe.dir == back * 4
		return false  # a heat pipe
	var other: Rec = entities.get(_port_tiles.get(next, -1))
	if other == null or other == r or other.extra.has("gh"):
		return false
	# Only a connection it has now (a dry drill's are none, PipeCovers.ports).
	var live := _drawn_ports(other.proto_id, int(other.extra.get("fa", 0)))
	for port: Array in _port_tiles_of(other):
		if port[0] == next and port[1] == own and live.any(func(p: Array) -> bool: return int(p[2]) == int(port[2])):
			return true
	return false


func _connect_pipes_around(tile: Vector2i) -> void:
	_connect_pipe(tile)
	for step in PIPE_STEPS:
		_connect_pipe(tile + step)


func _connect_pipe(tile: Vector2i) -> void:
	var r: Rec = entities.get(_pipes.get(tile, -1))
	if r == null:
		return
	var rp := protos.entity(r.proto_id)
	if rp == null:
		return
	var pf := _pflags(rp)
	# Factorio's window on every second straight pipe (model_library.gd pipe_window): where the floored
	# x plus the floored y is even. Set whoever works out the connections (the bridge's `pc` too).
	if posmod(tile.x + tile.y, 2) == 0 and (pf & ProtoDB.PF_PIPE_PLAIN) != 0:
		r.extra["pw"] = 1
		r.cache_gen = -1
	if r.extra.has("pc_mod"):
		return
	# Heat pipes join only heat pipes (a reactor's or heat exchanger's connections aren't known
	# here, so a heat pipe ending at one shows its end cap), fluid pipes only fluid pipes.
	var heat := (pf & ProtoDB.PF_PIPE_HEAT) != 0
	if not heat and (pf & ProtoDB.PF_PIPE_FLUID) == 0:
		return
	var mask := 0
	for i in 4:
		var other: Rec = entities.get(_pipes.get(tile + PIPE_STEPS[i], -1))
		if other == null:
			continue
		var opf := _pflags(protos.entity(other.proto_id))
		if heat != ((opf & ProtoDB.PF_PIPE_HEAT) != 0):
			continue
		# A pipe-to-ground joins only the pipe its above-ground end faces (direction 0 north,
		# 4 east, 8 south, 12 west, so facing back at this tile is the opposite of step i).
		if (opf & ProtoDB.PF_PIPE_GROUND) != 0 and other.dir != ((i + 2) % 4) * 4:
			continue
		mask |= 1 << i
	if int(r.extra.get("pc", -1)) != mask:
		r.extra["pc"] = mask
		r.cache_gen = -1
		_mark_dirty(r.chunk)


## A pipe the game took away (`del`, `mnd`): the pipes beside it whose connections the bridge sent (`pc_mod`, which
## _connect_pipe leaves alone) lose their side towards it now, so the run's last pipe is its ending piece at once,
## not a straight open at its end (FUE5's kit) until the bridge sends it again (a player-less character's mining
## raised nothing, so a bridge before /f3d-perf mined_neighbours never did). A connection always runs through the
## neighbouring tile, so the side to an emptied tile is gone whatever stood there. Not for an `upd`, which replaces a
## record in place. `--pipe-end=old`: the neighbours wait for the bridge, as before.
static var pipe_end_now := not Switches.has("--pipe-end=old")


func _unlink_pipes(gone: Rec) -> void:
	if gone == null or not pipe_end_now or not _is_pipe(gone):
		return
	var tile := _tile_of(gone)
	if _pipes.has(tile):
		return  # something stands there again
	for i in 4:
		var other: Rec = entities.get(_pipes.get(tile + PIPE_STEPS[i], -1))
		if other == null or not other.extra.has("pc_mod"):
			continue
		var pc := int(other.extra.get("pc", 0))
		var back := 1 << ((i + 2) % 4)
		if pc & back:
			other.extra["pc"] = pc & ~back
			other.cache_gen = -1
			_mark_dirty(other.chunk)


## Walls are drawn with the piece that joins their neighbours (model_library.gd, WALL_SHAPES):
## `extra.wc`, a bit each for north, east, south, west (1, 2, 4, 8), like pipes. A wall joins
## the walls next to it, and a gate that runs the same way (a gate facing north or south stands
## in a north-south wall). Bit 16: the walls to the east, south and south-east make a 2x2 block,
## and the gap in its middle is filled (Factorio's "filling" picture).
func _is_wall(r: Rec) -> bool:
	var proto: ProtoDB.EntityProto = protos.entity(r.proto_id)
	return proto != null and (proto.type == "wall" or proto.type == "gate") and not r.extra.has("gh")


func _connect_walls_around(tile: Vector2i) -> void:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			_connect_wall(tile + Vector2i(dx, dy))


func _connect_wall(tile: Vector2i) -> void:
	var r: Rec = entities.get(_walls.get(tile, -1))
	if r == null or (_pflags(protos.entity(r.proto_id)) & ProtoDB.PF_WALL) == 0:
		return
	var mask := 0
	var gmask := 0
	for i in 4:
		var other: Rec = entities.get(_walls.get(tile + PIPE_STEPS[i], -1))
		if other == null:
			continue
		var other_is_gate := (_pflags(protos.entity(other.proto_id)) & ProtoDB.PF_GATE) != 0
		if other_is_gate and (other.dir / 4) % 2 != i % 2:
			continue
		mask |= 1 << i
		if other_is_gate:
			gmask |= 1 << i
	if mask & 6 == 6:
		var corner: Rec = entities.get(_walls.get(tile + Vector2i(1, 1), -1))
		if corner != null and (_pflags(protos.entity(corner.proto_id)) & ProtoDB.PF_WALL) != 0:
			mask |= 16
	if int(r.extra.get("wc", -1)) != mask or int(r.extra.get("wg", 0)) != gmask:
		r.extra["wc"] = mask
		if gmask != 0:
			r.extra["wg"] = gmask
		else:
			r.extra.erase("wg")
		r.cache_gen = -1
		_mark_dirty(r.chunk)


## Cargo bays draw the edges of the cargo area they belong to (ModelLibrary.cargo_pieces):
## `extra.cb`, a neighbour mask for each of the bay's four 2x2 cells, from the tiles covered by
## hubs, bays and landing pads. Factorio doesn't hold bays to a 2-tile grid, so a neighbouring
## cell counts as cargo area when at least half its tiles are.
func _is_cargo(r: Rec) -> bool:
	var proto: ProtoDB.EntityProto = protos.entity(r.proto_id)
	return proto != null and ModelLibrary.CARGO_TYPES.has(proto.type) and not r.extra.has("gh")


func _is_cargo_ghost(r: Rec) -> bool:
	var proto: ProtoDB.EntityProto = protos.entity(int(r.extra.get("gh", -1)))
	return proto != null and ModelLibrary.CARGO_TYPES.has(proto.type)


func _cargo_rect(r: Rec) -> Rect2i:
	return cargo_rect(protos.entity(int(r.extra["gh"]) if r.extra.has("gh") else r.proto_id), r.pos)


## The tiles a hub, bay or landing pad at `pos` covers.
static func cargo_rect(proto: ProtoDB.EntityProto, pos: Vector2) -> Rect2i:
	var lo := Vector2i(roundi(pos.x + proto.box_min.x), roundi(pos.y + proto.box_min.y))
	var hi := Vector2i(roundi(pos.x + proto.box_max.x), roundi(pos.y + proto.box_max.y))
	return Rect2i(lo, hi - lo)


func _add_cargo(r: Rec, ghost: bool) -> void:
	if _cargo.has(r.key) or _cargo_ghosts.has(r.key):
		_remove_cargo(r.key)
	var area := _cargo_ghosts if ghost else _cargo
	var tiles := _cargo_ghost_tiles if ghost else _cargo_tiles
	var rect := _cargo_rect(r)
	area[r.key] = rect
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			tiles[Vector2i(x, y)] = int(tiles.get(Vector2i(x, y), 0)) + 1
	if _batch_joins:
		_join_cargo_rects.append(rect)
	else:
		_connect_cargo_near(rect)


func _remove_cargo(key) -> void:
	_cargo_left.erase(key)
	var ghost := _cargo_ghosts.has(key)
	var area := _cargo_ghosts if ghost else _cargo
	var tiles := _cargo_ghost_tiles if ghost else _cargo_tiles
	var rect: Rect2i = area[key]
	area.erase(key)
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var t := Vector2i(x, y)
			var left := int(tiles.get(t, 0)) - 1
			if left > 0:
				tiles[t] = left
			else:
				tiles.erase(t)
	if _batch_joins:
		_join_cargo_rects.append(rect)
	else:
		_connect_cargo_near(rect)


func _connect_cargo_near(rect: Rect2i) -> void:
	var near := rect.grow(4)
	for key in _cargo:
		if near.intersects(_cargo[key]):
			var r: Rec = entities.get(key)
			if r != null and protos.entity(r.proto_id).type == "cargo-bay":
				_connect_cargo(r)
	# Ghost bays nearby join the built ones too (ghosts.gd works theirs out when it redraws).
	for corner in [near.position, near.end, Vector2i(near.position.x, near.end.y), Vector2i(near.end.x, near.position.y)]:
		var c := chunk_of(Vector2(corner))
		if chunks.has(c):
			_mark_dirty(c)


const CARGO_AROUND := [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1),
	Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0)]


func _connect_cargo(r: Rec) -> void:
	var cb := cargo_mask(_cargo[r.key])
	if int(r.extra.get("cb", -1)) != cb:
		r.extra["cb"] = cb
		r.cache_gen = -1
		_mark_dirty(r.chunk)


## extra.cb for a bay over `rect`, from the built cargo area round it (and with `ghosts`, the ghost
## bays' too). The bay's own tiles count even before it is built, so a ghost bay and the held bay's
## preview are framed as it will be.
func cargo_mask(rect: Rect2i, ghosts := false) -> int:
	var cb := 0
	for k in 4:
		var cell := rect.position + Vector2i(k % 2, k / 2) * 2
		var mask := 0
		for b in 8:
			var at: Vector2i = cell + CARGO_AROUND[b] * 2
			var covered := 0
			for t in [at, at + Vector2i(1, 0), at + Vector2i(0, 1), at + Vector2i(1, 1)]:
				if _cargo_tiles.has(t) or rect.has_point(t) or (ghosts and _cargo_ghost_tiles.has(t)):
					covered += 1
			if covered >= 2:
				mask |= 1 << b
		cb |= mask << (8 * k)
	return cb


## Flat [x, y, tile id, ...]
func _on_tiles(list: Array) -> void:
	var changed := {}
	var by_chunk := {}
	var i := 0
	while i + 2 < list.size():
		var x := int(list[i])
		var y := int(list[i + 1])
		var tid := int(list[i + 2])
		var c := Vector2i(floori(x / float(CHUNK)), floori(y / float(CHUNK)))
		if not _replaying:
			var clist: Array = by_chunk.get(c, [])
			if clist.is_empty():
				by_chunk[c] = clist
			clist.append(x)
			clist.append(y)
			clist.append(tid)
		var cv: ChunkView = chunks.get(c)
		if cv != null:
			var local := Vector2i(x - c.x * CHUNK, y - c.y * CHUNK)
			cv.set_tile(local, tid)
			# A tile ghost goes when its tile is laid (robots don't say).
			var tg: Rec = entities.get(_tile_ghosts.get(Vector2i(x, y), -1))
			if tg != null and int(tg.extra.get("tg", 0)) == tid:
				_remove(tg.key)
			_dirty_terrain[c] = true
			# Banks and foam next door depend on tiles along this chunk's edge.
			if local.x == 0 or local.y == 0 or local.x == CHUNK - 1 or local.y == CHUNK - 1:
				_dirty_terrain_around(c)
			changed[c] = true
		i += 3
	if not _replaying:
		for c: Vector2i in by_chunk:
			var tile_msg := {"t": "tiles", "l": by_chunk[c]}
			if _staged_snap.has(c):
				(_staged_snap[c]["deltas"] as Array).append(tile_msg)
			_record_delta(c, tile_msg)
	for c: Vector2i in changed:
		tiles_changed.emit(c)


## Tile id at a world tile position, or -1 if its chunk isn't loaded (or doesn't exist).
func tile_at(x: int, y: int) -> int:
	var c := Vector2i(floori(x / float(CHUNK)), floori(y / float(CHUNK)))
	var cv: ChunkView = chunks.get(c)
	if cv == null or cv.tile_ids.size() != CHUNK * CHUNK:
		return -1
	return cv.tile_ids[(y - c.y * CHUNK) * CHUNK + (x - c.x * CHUNK)]


## A chunk's banks and shore foam depend on its neighbours' edge tiles (an unloaded neighbour
## gets banks, as it might be water), so neighbours rebuild whenever a chunk's tiles arrive or
## go. Chunks without tiles have no terrain to rebuild.
func _dirty_terrain_around(c: Vector2i) -> void:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var n := c + Vector2i(dx, dy)
			var cv: ChunkView = chunks.get(n)
			if n != c and cv != null and cv.tile_ids.size() == CHUNK * CHUNK:
				_dirty_terrain[n] = true


## Flat [unit, 0/1, ...], lit lamps' colours `lc` [unit, 0xRRGGBB or -1, ...] (K10) and which of them
## are set to Always on, `ao` [unit, 0/1, ...] (K20).
## (Each list an Array, or packed from a binary frame: wire_decode.gd.)
func _on_states(list: Variant, lc: Variant = [], ao: Variant = []) -> void:
	var colored := not lamp_colors.is_empty()
	var always := not lamp_always.is_empty()
	var i := 0
	if colored or always:
		# The lamps' colours and Always on are forgotten with each state here, in the message's order
		# (the same message sends them again), even when the states themselves wait (states_sliced).
		while i + 1 < list.size():
			var unit := int(list[i])
			if colored:
				lamp_colors.erase(unit)
			if always:
				lamp_always.erase(unit)
			i += 2
	if states_sliced and (_st_at < _st_lists.size() or list.size() > ST_INLINE * 2):
		# Behind the ones waiting, in order: the latest a unit was sent is the one it ends with.
		if list.size() >= 2:
			_st_lists.append(list)
	else:
		i = 0
		while i + 1 < list.size():
			_apply_state(int(list[i]), int(list[i + 1]))
			i += 2
	i = 0
	while i + 1 < lc.size():
		var col := int(lc[i + 1])
		if col < 0:
			lamp_colors.erase(int(lc[i]))
		else:
			lamp_colors[int(lc[i])] = col
		i += 2
	i = 0
	while i + 1 < ao.size():
		if int(ao[i + 1]) == 1:
			lamp_always[int(ao[i])] = true
		else:
			lamp_always.erase(int(ao[i]))
		i += 2


## One machine's state: `working`, its chunk's set of stated units, its placeholder's colour, its
## models' animation (anim.gd) and a switched-off belt's look.
func _apply_state(unit: int, state: int) -> void:
	var was: int = working.get(unit, -1)
	working[unit] = state
	# Models show the state through anim.gd; placeholders change colour, so rebuild.
	var r: Rec = entities.get(unit)
	if r == null:
		return
	if was < 0:
		_stated_in(r.chunk)[unit] = true
	var cv: ChunkView = chunks.get(r.chunk)
	if cv != null and cv.placeholder_keys.has(r.key):
		_dirty[r.chunk] = true
	if state != was:
		animator.state_changed(r)
		# Only one with a wire is drawn ready to stop: one set by the logistic network needs drawing again.
		if cv != null and (state == Anim.SWITCHED_OFF or was == Anim.SWITCHED_OFF) \
				and not cv.set_belt_off(unit, state == Anim.SWITCHED_OFF) and state == Anim.SWITCHED_OFF \
				and not r.extra.has("r") and not r.extra.has("g"):
			_dirty[r.chunk] = true


## --st-slice=off: each `st` message's states applied whole as it is handled, as before (a busy base's
## 1,600 states took 10-25 ms, a dropped frame each time). On: a message of more than ST_INLINE states
## waits here and is applied over the next frames within the frame budget's `states` slice, in the
## order the messages came (a unit's latest state wins), the lamps' colours at once.
static var states_sliced := Switches.on("--st-slice")
const ST_INLINE := 64
var _st_lists: Array = []  # the `l` lists waiting, oldest first
var _st_at := 0  # the list being applied
var _st_i := 0  # its next pair
var _st_prio_lists := 0
var _st_prio_center := Vector2i(0x7fffffff, 0)


## States waiting to be applied (units).
func states_waiting() -> int:
	var n := 0
	for j in range(_st_at, _st_lists.size()):
		n += int(_st_lists[j].size()) / 2
	return n - _st_i / 2


func _prioritize_states_waiting() -> void:
	if not fast_edit_rebuild or states_waiting() <= 128:
		return
	var center := stream_center()
	if _st_lists.size() == _st_prio_lists and center == _st_prio_center:
		return
	var near: Array = []
	var outer: Array = []
	for j in range(_st_at, _st_lists.size()):
		var list: Variant = _st_lists[j]
		var i := _st_i if j == _st_at else 0
		while i + 1 < list.size():
			var unit := int(list[i])
			var state := int(list[i + 1])
			i += 2
			var r: Rec = entities.get(unit)
			if r != null and maxi(absi(r.chunk.x - center.x), absi(r.chunk.y - center.y)) <= 2:
				near.append(unit)
				near.append(state)
			else:
				outer.append(unit)
				outer.append(state)
	var next_lists: Array = []
	if not near.is_empty():
		next_lists.append(near)
	if not outer.is_empty():
		next_lists.append(outer)
	_st_lists = next_lists
	_st_at = 0
	_st_i = 0
	_st_prio_lists = _st_lists.size()
	_st_prio_center = center


## Applies the states waiting within the frame budget's `states` slice (at least its floor); `most`
## states at most when above 0 (the UI test).
func _apply_states_waiting(most := 0) -> void:
	if _st_at >= _st_lists.size():
		FrameBudget.waiting(&"states", 0)
		return
	_prioritize_states_waiting()
	var t0 := Time.get_ticks_usec()
	# More than one message behind: the whole slice, so a stream of them can't pile up.
	var allow := FrameBudget.grant(&"states", 1, _st_lists.size() - _st_at > 1)
	var n := 0
	while _st_at < _st_lists.size():
		var list: Variant = _st_lists[_st_at]
		while _st_i + 1 < list.size():
			_apply_state(int(list[_st_i]), int(list[_st_i + 1]))
			_st_i += 2
			n += 1
			if n == most or ((n & 7) == 0 and Time.get_ticks_usec() - t0 > allow):
				break
		if _st_i + 1 < list.size():
			break
		_st_at += 1
		_st_i = 0
		if n == most:
			break
	if _st_at >= _st_lists.size():
		_st_lists.clear()
		_st_at = 0
		_st_prio_lists = 0
	FrameBudget.spent(&"states", Time.get_ticks_usec() - t0, _st_lists.size() - _st_at)
	_prof("states", t0)


## Applies every state waiting at once (tests; what reads `working` right after a big message).
func flush_states() -> void:
	while _st_at < _st_lists.size():
		var list: Variant = _st_lists[_st_at]
		while _st_i + 1 < list.size():
			_apply_state(int(list[_st_i]), int(list[_st_i + 1]))
			_st_i += 2
		_st_at += 1
		_st_i = 0
	_st_lists.clear()
	_st_at = 0
	_st_prio_lists = 0


## The units with a state (`working`) by their record's chunk, for what looks at machines near a
## point a few times a second (fx.gd's sounds and smoke, working_glow.gd): they went through every
## state in the world, tens of thousands on a big base, 2-5 ms each time while walking.
var _stated := {}  # Vector2i -> {unit: true}


func _stated_in(c: Vector2i) -> Dictionary:
	var units: Dictionary = _stated.get(c, {})
	if units.is_empty():
		_stated[c] = units
	return units


## Whether an entity of this type stands within `radius` tiles of `at`, in the chunks loaded.
func has_near(type: String, at: Vector2, radius: float) -> bool:
	return unit_near(type, at, radius) != 0


## The unit number of an entity of that type within `radius` tiles of `at`, 0 for none (-1 for one
## without a unit number).
func unit_near(type: String, at: Vector2, radius: float) -> int:
	var lo := chunk_of(at - Vector2(radius, radius))
	var hi := chunk_of(at + Vector2(radius, radius))
	for cy in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			var view = chunks.get(Vector2i(cx, cy))
			if view == null:
				continue
			for r: Rec in view.entities.values():
				if r.pos.distance_to(at) <= radius and protos.entity(r.proto_id).type == type:
					return r.unit if r.unit != 0 else -1
	return 0


## The units with a state whose record lies in the chunks within `radius` tiles of `at` (a square).
func working_near(at: Vector2, radius: float) -> Array:
	var out: Array = []
	var lo := chunk_of(at - Vector2(radius, radius))
	var hi := chunk_of(at + Vector2(radius, radius))
	for cy in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			var c := Vector2i(cx, cy)
			var units: Dictionary = _stated.get(c, {})
			for unit in units.keys():
				var r: Rec = entities.get(unit)
				if r == null or r.chunk != c:
					units.erase(unit)  # gone, or moved to another chunk's set
				else:
					out.append(unit)
	return out


func _process(delta: float) -> void:
	# The frame's length for the belt surfaces' smear (before the world is ready: the menu's world too).
	var tw := Time.get_ticks_usec()
	BeltBlur.frame(delta)
	_prof("x_belt_blur", tw)
	tw = Time.get_ticks_usec()
	# Nodes and meshes let go (free_later.gd), a slice a frame.
	FreeLater.step()
	_prof("x_free_later", tw)
	# A pick index nobody asked for since last frame (the mouse moved off a chunk part-built, or the
	# chunk went) has nothing waiting, or the frame budget would keep time for it for good.
	if Engine.get_process_frames() - _pick_frame > 1:
		FrameBudget.waiting(&"pick", 0)
	if not Bridge.world_ready:
		if Bridge.connected and PipelineWarm.listed > 0:
			# The save's models (pipeline_warm.gd) are read while the prototypes still come.
			PipelineWarm.poll()
			ModelLibrary.poll()
		return
	var t0 := Time.get_ticks_usec()
	_ensure_disk_cache()
	_prof("x_dc_ensure", t0)
	var td := Time.get_ticks_usec()
	_poll_disk_cache(delta)
	_prof("x_disk_cache", t0)
	_prof("x_dc_poll", td)
	t0 = Time.get_ticks_usec()
	_update_subscription(delta)
	_prof("subscribe", t0)
	t0 = Time.get_ticks_usec()
	_process_optimistic()
	_prof("x_optimistic", t0)
	t0 = Time.get_ticks_usec()
	_apply_states_waiting()
	_prof("x_states_waiting", t0)
	t0 = Time.get_ticks_usec()
	_free_unloaded()
	_prof("x_free_unloaded", t0)
	t0 = Time.get_ticks_usec()
	_update_focus(delta)
	_prof("x_focus", t0)
	t0 = Time.get_ticks_usec()
	if ModelLibrary.ModelPacks.follow_sprites():
		models_changed([])  # a graphics list came, the Factorio pack over another: its pictures may be new ones
	var models_made := ModelLibrary.poll()
	var cards_made := SpriteStandins.poll()
	if models_made or cards_made:
		# Models (or sprite stand-ins) made on worker threads are ready: draw the chunks that left
		# them out, and with new cards those drawn with placeholder boxes.
		for c in chunks:
			var cv := chunks[c] as ChunkView
			if cv.waiting_models or (cards_made and not cv.placeholder_keys.is_empty()):
				_dirty[c] = true
	if PipelineWarm.poll():
		# Models left out while their pipelines compiled (pipeline_warm.gd) can be drawn now.
		for c in chunks:
			if (chunks[c] as ChunkView).waiting_models:
				_dirty[c] = true
	_prof("models_poll", t0)
	t0 = Time.get_ticks_usec()
	_rebuild_dirty()
	_prof("x_rebuild_dirty", t0)
	t0 = Time.get_ticks_usec()
	_update_shot(delta)
	_prof("x_shot", t0)
	t0 = Time.get_ticks_usec()
	# A cut (view_ahead.gd): the camera jumped this frame (add-ons have moved it by now), so this frame's
	# far merges and levels are picked whole, without budgets or fades.
	var cut_cam := get_viewport().get_camera_3d()
	cut_frame = ViewAhead.cut_now(cut_cam.global_position if cut_cam != null else Vector3.INF)
	if cut_frame:
		var tf := Time.get_ticks_usec()
		far_chunks.settle_now()
		_cut_flush_pending(cut_cam)
		cut_far_usec = Time.get_ticks_usec() - tf
	if cut_shots != "" and ViewAhead.generation != _cut_log_gen:
		_cut_log_gen = ViewAhead.generation
		print("world: view ahead (tick %d): %s" % [Bridge.server_tick, ViewAhead.points()])
	if ViewAhead.seen and cut_shots != "":
		_cut_shot_n += 1
		_cut_shot("%02d-first" % _cut_shot_n)
		_cut_census("first")
		_cut_shot_later = CUT_SHOT_LATER
	elif _cut_shot_later > 0:
		_cut_shot_later -= 1
		if _cut_shot_later == CUT_SHOT_LATER - 1:
			_cut_census("next")
		if _cut_shot_later == 0:
			_cut_shot("%02d-later" % _cut_shot_n)
			_cut_census("later")
	_prof("x_cut", t0)
	t0 = Time.get_ticks_usec()
	_update_shadow_casters()
	_prof("shadows", t0)
	t0 = Time.get_ticks_usec()
	_update_lods(delta)
	_prof("lods", t0)
	if cut_frame and cut_shots != "":
		print("world: cut at tick %d: levels %d chunks, %d switches, %d us; far merges %d us" % [Bridge.server_tick, cut_looked, lod_switches, cut_usec, cut_far_usec])
	t0 = Time.get_ticks_usec()
	CliffWall.poll(get_viewport().get_camera_3d())
	_prof("cliff_wall", t0)
	t0 = Time.get_ticks_usec()
	_watch_for_missing(delta)
	_prof("x_watch_missing", t0)
	t0 = Time.get_ticks_usec()
	if track_latency:
		_track_latency(delta)
	_prof("x_track_latency", t0)
	_prof("x_world_all", tw)


func _ensure_disk_cache() -> void:
	var want_on: bool = disk_cache_enabled and bool(Settings.get_value("graphics", "chunk_disk_cache"))
	if not want_on:
		if _disk_cache.is_configured():
			_disk_cache.flush_sync()
			_disk_cache.configure("", -1, 0)
			_disk_cache_sid = ""
			_disk_cache_si = -1
			_disk_cache_hash = 0
			_disk_cache_proto_ver = -1
			_disk_cache_proto_counts = Vector2i(-1, -1)
		return
	if Bridge.save_id == "" or surface_index < 0 or protos == null:
		return
	var pver := protos.version
	var pcounts := Vector2i(protos.tile_names.size(), protos.entities.size())
	if _disk_cache.is_configured() and _disk_cache_sid == Bridge.save_id and _disk_cache_si == surface_index and _disk_cache_proto_ver == pver and _disk_cache_proto_counts == pcounts:
		return
	var ph := ChunkDiskCache.compute_proto_hash(protos)
	if ph == 0:
		return
	_disk_cache_proto_ver = pver
	_disk_cache_proto_counts = pcounts
	if _disk_cache.is_configured() and _disk_cache_sid == Bridge.save_id and _disk_cache_si == surface_index and _disk_cache_hash == ph:
		return
	_disk_cache.enabled = true
	_disk_cache.max_bytes = ChunkDiskCache.from_args()
	_disk_cache_sid = Bridge.save_id
	_disk_cache_si = surface_index
	_disk_cache_hash = ph
	_disk_cache.configure(Bridge.save_id, surface_index, ph)


func _poll_disk_cache(delta: float) -> void:
	var tp := Time.get_ticks_usec()
	var ready_regions := _disk_cache.poll(delta)
	_prof("x_dc_cache_poll", tp)
	if not ready_regions.is_empty():
		_disk_promote_scan = true
	if not _disk_promote_scan:
		return
	tp = Time.get_ticks_usec()
	var promoted_have: Array = []
	var promoted := 0
	var done := true
	for c: Vector2i in _disk_waiting.keys():
		if not _disk_cache.has_region_loaded(c.x, c.y):
			continue
		# A region's chunks (up to 256) promoted a slice a frame, not all in the frame it was read
		# (x_disk_cache 11.7 ms in the owner's spike log). --disk-promote-sliced=off: all at once.
		if disk_promote_sliced and promoted > 0 and Time.get_ticks_usec() - tp > DISK_PROMOTE_USEC:
			done = false
			break
		_disk_waiting.erase(c)
		var dc := _disk_cache.get_loaded_chunk(c.x, c.y)
		if dc.is_empty():
			continue
		_promote_disk_chunk(c, dc)
		promoted += 1
		var cv: ChunkView = chunks.get(c)
		if cv != null and not cv.loaded and _asked.has(c):
			if optimistic_cache and not _optimistic_pending.has(c):
				_optimistic_queue.append(c)
				_opt_queue_gen += 1
				_optimistic_pending[c] = true
			var offer := _cached_offer(c)
			if not offer.is_empty():
				promoted_have.append(offer)
	if done:
		_disk_promote_scan = false
	if not promoted_have.is_empty():
		_sub_timer = minf(_sub_timer, SUBSCRIBE_REFRESH)
	_prof("x_dc_promote", tp)


## Chunks read from disk promoted into the memory cache in slices (DISK_PROMOTE_USEC a frame, at
## least one chunk); --disk-promote-sliced=off: all of a read region's waiting chunks in one frame.
static var disk_promote_sliced := Switches.on("--disk-promote-sliced")
const DISK_PROMOTE_USEC := 1000
var _disk_promote_scan := false


func _promote_disk_chunk(c: Vector2i, dc: Dictionary) -> void:
	if surface_index < 0 or dc.is_empty():
		return
	var k := Vector3i(surface_index, c.x, c.y)
	if _cache.has(k):
		return
	var rv := int(dc.get("rv", 0))
	var n := int(dc.get("n", 0))
	var tiles_v: Variant = dc.get("tiles")
	var e_v: Variant = dc.get("e", PackedInt32Array())
	var xi_v: Variant = dc.get("xi", PackedInt32Array())
	var xe_v: Variant = dc.get("xe", [])
	var chunk_msg := {
		"t": "chunk",
		"cx": c.x,
		"cy": c.y,
		"rs": surface_index,
		"rv": rv,
		"n": n,
		"parts": 1,
		"tiles": [],
		"_tiles": tiles_v,
	}
	var ents_msg := {
		"t": "ents",
		"cx": c.x,
		"cy": c.y,
		"part": 1,
		"parts": 1,
		"e": e_v,
		"xi": xi_v,
		"xe": xe_v,
	}
	var bytes := 256 + TILES_BYTE_ESTIMATE + WireDecode.ents_count(ents_msg) * 120
	_cache[k] = {
		"rv": rv,
		"n": n,
		"msgs": [chunk_msg, ents_msg],
		"deltas": [],
		"dec": [],
		"msec": Time.get_ticks_msec(),
		"b": bytes,
		"db": 0,
	}
	_cache_bytes += bytes
	_trim_cache()


const TILES_BYTE_ESTIMATE := 4096


static func _decode_chunk_tiles(chunk_msg: Dictionary) -> PackedInt32Array:
	var existing: Variant = chunk_msg.get("_tiles")
	if existing is PackedInt32Array and (existing as PackedInt32Array).size() == CHUNK * CHUNK:
		return existing as PackedInt32Array
	var rle: Variant = chunk_msg.get("tiles", [])
	var ids: PackedInt32Array
	if WireDecode.packed(rle):
		ids = MessageDecode.tiles_from_runs(rle)
	elif rle is Array:
		ids = PackedInt32Array()
		ids.resize(CHUNK * CHUNK)
		var arr := rle as Array
		var i := 0
		var n := 0
		while i + 1 < arr.size() and n < CHUNK * CHUNK:
			var id := int(arr[i])
			var cnt := int(arr[i + 1])
			for _k in cnt:
				if n >= CHUNK * CHUNK:
					break
				ids[n] = id
				n += 1
			i += 2
	if ids.size() == CHUNK * CHUNK:
		chunk_msg["_tiles"] = ids
	return ids


static func _pack_cache_entry(entry: Dictionary, stringify_xe := true) -> Array:
	var flat: Array[int] = []
	var out_xi: Array[int] = []
	var out_xe: Array = []
	var need_64 := false
	var ent_idx := 0
	var msgs: Array = entry.get("msgs", [])
	if msgs.size() == 2:
		var m1: Dictionary = msgs[1]
		var e1_v: Variant = m1.get("e")
		if WireDecode.packed(e1_v):
			var packed_single: Variant = PackedInt64Array(e1_v) if e1_v is PackedInt64Array else PackedInt32Array(e1_v)
			var mxi1: Variant = m1.get("xi", PackedInt32Array())
			var mxe1: Variant = m1.get("xe", [])
			var xi1 := PackedInt32Array()
			if mxe1 is Array and WireDecode.packed(mxi1):
				var cnt1 := mini(mxi1.size(), (mxe1 as Array).size())
				xi1.resize(cnt1)
				for j in cnt1:
					xi1[j] = int(mxi1[j])
					out_xe.append(mxe1[j])
			var xt1: Variant = (JSON.stringify(out_xe) if not out_xe.is_empty() else "") if stringify_xe else out_xe
			return [packed_single, xi1, xt1]
	if ents_slice and msgs.size() > 2:
		var joined: Variant = _pack_joined(msgs)
		if joined != null:
			var xt_j: Variant = (JSON.stringify(joined[2]) if not (joined[2] as Array).is_empty() else "") if stringify_xe else joined[2]
			return [joined[0], joined[1], xt_j]
	for mi in range(1, msgs.size()):
		var m: Dictionary = msgs[mi]
		var e_v: Variant = m.get("e")
		if WireDecode.packed(e_v):
			if e_v is PackedInt64Array:
				need_64 = true
			var stride := WireDecode.ENT_STRIDE
			var count := int(e_v.size() / stride)
			var base_idx := ent_idx
			for idx in e_v.size():
				flat.append(int(e_v[idx]))
			var mxi: Variant = m.get("xi", PackedInt32Array())
			var mxe: Variant = m.get("xe", [])
			if mxe is Array and WireDecode.packed(mxi):
				for j in mini(mxi.size(), (mxe as Array).size()):
					out_xi.append(base_idx + int(mxi[j]))
					out_xe.append(mxe[j])
			ent_idx += count
		elif e_v is Array:
			for rec: Variant in (e_v as Array):
				if not (rec is Array) or (rec as Array).size() < 5:
					continue
				var r_arr := rec as Array
				for k in 5:
					var val := int(r_arr[k])
					if val < -2147483648 or val > 2147483647:
						need_64 = true
					flat.append(val)
				if r_arr.size() > 5 and r_arr[5] != null:
					out_xi.append(ent_idx)
					out_xe.append(r_arr[5])
				ent_idx += 1
	var packed_e: Variant
	if need_64:
		var p64 := PackedInt64Array()
		p64.resize(flat.size())
		for i in flat.size():
			p64[i] = flat[i]
		packed_e = p64
	else:
		var p32 := PackedInt32Array()
		p32.resize(flat.size())
		for i in flat.size():
			p32[i] = flat[i]
		packed_e = p32
	var xi_arr := PackedInt32Array()
	xi_arr.resize(out_xi.size())
	for i in out_xi.size():
		xi_arr[i] = out_xi[i]
	var xt: Variant = (JSON.stringify(out_xe) if not out_xe.is_empty() else "") if stringify_xe else out_xe
	return [packed_e, xi_arr, xt]


## _pack_cache_entry's parts joined with append_array when every part is packed with one width (ents_slice): [e, xi,
## xe list], the same as the record-by-record copy; null when one isn't (JSON lists, or 32- and 64-bit mixed).
static func _pack_joined(msgs: Array) -> Variant:
	var wide := (msgs[1] as Dictionary).get("e") is PackedInt64Array
	for mi in range(1, msgs.size()):
		var ev: Variant = (msgs[mi] as Dictionary).get("e")
		if not WireDecode.packed(ev) or (ev is PackedInt64Array) != wide:
			return null
	var e32 := PackedInt32Array()
	var e64 := PackedInt64Array()
	var out_xi := PackedInt32Array()
	var out_xe: Array = []
	var base := 0
	for mi in range(1, msgs.size()):
		var m: Dictionary = msgs[mi]
		var ev: Variant = m.get("e")
		if wide:
			e64.append_array(ev as PackedInt64Array)
		else:
			e32.append_array(ev as PackedInt32Array)
		var mxi: Variant = m.get("xi", PackedInt32Array())
		var mxe: Variant = m.get("xe", [])
		if mxe is Array and WireDecode.packed(mxi):
			for j in mini(mxi.size(), (mxe as Array).size()):
				out_xi.append(base + int(mxi[j]))
				out_xe.append(mxe[j])
		base += int(ev.size() / WireDecode.ENT_STRIDE)
	return [e64 if wide else e32, out_xi, out_xe]


func _save_to_disk_cache(c: Vector2i, entry: Dictionary) -> void:
	if not _disk_cache.is_configured():
		return
	var msgs: Array = entry.get("msgs", [])
	if msgs.is_empty():
		return
	var tiles := _decode_chunk_tiles(msgs[0] as Dictionary)
	if tiles.size() != CHUNK * CHUNK:
		return
	var packed := _pack_cache_entry(entry, not ChunkDiskCache.async_encode)
	if ChunkDiskCache.async_encode:
		_disk_cache.put_chunk(c.x, c.y, int(entry["rv"]), int(entry["n"]), tiles, packed[0], packed[1], "", packed[2] as Array)
	else:
		_disk_cache.put_chunk(c.x, c.y, int(entry["rv"]), int(entry["n"]), tiles, packed[0], packed[1], str(packed[2]))


func _cache_entry_for_optimistic(c: Vector2i) -> Dictionary:
	if surface_index < 0:
		return {}
	var entry: Dictionary = _cache.get(Vector3i(surface_index, c.x, c.y), {})
	if entry.is_empty() or not _cache_whole(entry):
		return {}
	return entry


## Bumped when chunks join the optimistic queue: it is sorted again only then, or when the focus's chunk or the view's
## direction changed (ents_slice; popping from the front keeps it sorted).
var _opt_queue_gen := 0
var _opt_sorted_key: Array = []


## The optimistic queue nearest first (_build_rank): one packed key a chunk, rank << 20 | index, sorted natively.
## --ents-slice=off: sort_custom every frame as before.
func _sort_optimistic_queue() -> void:
	var center := chunk_of(_focus)
	if not ents_slice:
		var cmp := func(a: Vector2i, b: Vector2i) -> bool:
			return _build_rank(a, center) < _build_rank(b, center)
		_optimistic_queue.sort_custom(cmp)
		return
	var key := [center, _wanted_f, _opt_queue_gen]
	if key == _opt_sorted_key:
		return
	var keys := PackedInt64Array()
	keys.resize(_optimistic_queue.size())
	for i in _optimistic_queue.size():
		keys[i] = (_build_rank(_optimistic_queue[i], center) << 20) | i
	keys.sort()
	var was := _optimistic_queue.duplicate()
	for i in keys.size():
		_optimistic_queue[i] = was[keys[i] & 0xfffff]
	_opt_sorted_key = key


func _process_optimistic() -> void:
	if optimistic_slice:
		_process_optimistic_sliced()
		return
	if _optimistic_queue.is_empty() or not optimistic_cache:
		_optimistic_queue.clear()
		_optimistic_pending.clear()
		return
	if _optimistic_queue.size() > OPTIMISTIC_PER_FRAME:
		_sort_optimistic_queue()
	var t0 := Time.get_ticks_usec()
	var count := 0
	while not _optimistic_queue.is_empty() and count < OPTIMISTIC_PER_FRAME:
		if count > 0 and Time.get_ticks_usec() - t0 >= OPTIMISTIC_BUDGET_USEC:
			break
		var c: Vector2i = _optimistic_queue.pop_front()
		_optimistic_pending.erase(c)
		var cv: ChunkView = chunks.get(c)
		if cv == null or cv.loaded or _staged_snap.has(c):
			continue
		var entry := _cache_entry_for_optimistic(c)
		if not entry.is_empty():
			_hydrate_optimistic(c, cv, entry)
			count += 1


## optimistic_slice: the queue's chunks replayed a step at a time inside the `hydrate` slice; a chunk left part-way
## goes on next frame (_hyd). At most OPTIMISTIC_PER_FRAME chunks begun a frame, as before.
func _process_optimistic_sliced() -> void:
	if not optimistic_cache:
		_optimistic_queue.clear()
		_optimistic_pending.clear()
		_hyd = {}
		FrameBudget.waiting(&"hydrate", 0)
		return
	if _optimistic_queue.is_empty() and _hyd.is_empty():
		FrameBudget.waiting(&"hydrate", 0)
		return
	if _optimistic_queue.size() > OPTIMISTIC_PER_FRAME:
		_sort_optimistic_queue()
	var t0 := Time.get_ticks_usec()
	var allow := hydrate_test_usec if hydrate_test_usec >= 0 else FrameBudget.grant(&"hydrate")
	var steps := 0
	var begun := 0
	while allow > 0:
		if _hyd.is_empty():
			if _optimistic_queue.is_empty() or begun >= OPTIMISTIC_PER_FRAME:
				break
			var c: Vector2i = _optimistic_queue.pop_front()
			_optimistic_pending.erase(c)
			var cv: ChunkView = chunks.get(c)
			if cv == null or cv.loaded or _staged_snap.has(c):
				continue
			var entry := _cache_entry_for_optimistic(c)
			var msgs: Array = entry.get("msgs", [])
			if msgs.is_empty():
				continue
			# Its lists as they are now: the cache's entry may grow while the replay waits between frames.
			_hyd = {"c": c, "cv": cv, "msgs": msgs.duplicate(), "deltas": (entry.get("deltas", []) as Array).duplicate(),
				"dec": (entry.get("dec", []) as Array).duplicate() if replay_dec.is_valid() else [],
				"step": 0, "rv": int(entry["rv"]), "n": int(entry["n"])}
			begun += 1
		if not _hydrate_valid():
			_hyd = {}
			continue
		var kind := _hydrate_kind()
		if not FrameBudget.fits(t0, allow, steps, FrameBudget.item_est(&"hydrate", kind)):
			break
		var ts := Time.get_ticks_usec()
		var finished := _hydrate_step()
		FrameBudget.note_item(&"hydrate", Time.get_ticks_usec() - ts, kind)
		steps += 1
		if finished:
			_hyd = {}
	FrameBudget.spent(&"hydrate", Time.get_ticks_usec() - t0, _optimistic_queue.size() + (0 if _hyd.is_empty() else 1))


## Whether the chunk replayed in steps is still the one to replay: still wanted (the same ChunkView), not filled by
## the bridge's own snapshot or `same` meanwhile (those clear `optimistic`, or stage a refresh).
func _hydrate_valid() -> bool:
	var c: Vector2i = _hyd["c"]
	var cv: ChunkView = _hyd["cv"]
	if not is_instance_valid(cv) or not is_same(chunks.get(c), cv) or _staged_snap.has(c):
		return false
	if int(_hyd["step"]) == 0:
		return not cv.loaded
	return cv.optimistic


## The next step's kind (its typical cost is looked up by it): "chunk", "ents", "delta" or "dec".
func _hydrate_kind() -> String:
	var i := int(_hyd["step"])
	var nm := (_hyd["msgs"] as Array).size()
	if i == 0:
		return "chunk"
	if i < nm:
		return "ents_slice" if _ents_sliced((_hyd["msgs"] as Array)[i] as Dictionary) else "ents"
	return "delta" if i < nm + (_hyd["deltas"] as Array).size() else "dec"


## One step of the chunk replayed from the cache; true when it was the last (the chunk is then as
## _hydrate_optimistic leaves it).
func _hydrate_step() -> bool:
	var c: Vector2i = _hyd["c"]
	var cv: ChunkView = _hyd["cv"]
	var msgs: Array = _hyd["msgs"]
	var deltas: Array = _hyd["deltas"]
	var decs: Array = _hyd["dec"]
	var i := int(_hyd["step"])
	var was_replaying := _replaying
	_replaying = true
	cv.optimistic = true
	if i == 0:
		_apply_chunk_immediate(msgs[0] as Dictionary)
	elif i < msgs.size():
		var em := msgs[i] as Dictionary
		if _ents_sliced(em):
			# ENTS_SLICE records a step, the message's place kept in _hyd (ri, xc); the step moves on after its last.
			var from := int(_hyd.get("ri", 0))
			var to := mini(from + ENTS_SLICE, _ents_count(em))
			_hyd["xc"] = _apply_ents_range(em, from, to, int(_hyd.get("xc", 0)))
			if to < _ents_count(em):
				_hyd["ri"] = to
				_replaying = was_replaying
				return false
			_hyd.erase("ri")
			_hyd.erase("xc")
		else:
			_apply_ents_message(em)
	elif i < msgs.size() + deltas.size():
		handle(deltas[i - msgs.size()] as Dictionary)
	elif i < msgs.size() + deltas.size() + decs.size() and replay_dec.is_valid():
		replay_dec.call(decs[i - msgs.size() - deltas.size()] as Dictionary)
	_replaying = was_replaying
	i += 1
	_hyd["step"] = i
	if i < msgs.size() + deltas.size() + decs.size():
		return false
	cv.optimistic = true
	_optimistic_rv[c] = [surface_index, int(_hyd["rv"]), int(_hyd["n"])]
	_dirty[c] = true
	return true


func _hydrate_optimistic(c: Vector2i, cv: ChunkView, entry: Dictionary) -> void:
	if cv == null or cv.loaded or not chunks.has(c):
		return
	Probing.count("hydrated")
	var msgs: Array = entry.get("msgs", [])
	if msgs.is_empty():
		return
	var was_replaying := _replaying
	_replaying = true
	cv.optimistic = true
	_apply_chunk_immediate(msgs[0] as Dictionary)
	for i in range(1, msgs.size()):
		_apply_ents_message(msgs[i] as Dictionary)
	for dm: Dictionary in entry.get("deltas", []):
		handle(dm)
	if replay_dec.is_valid():
		for dec_m: Dictionary in entry.get("dec", []):
			replay_dec.call(dec_m)
	_replaying = was_replaying
	cv.optimistic = true
	_optimistic_rv[c] = [surface_index, int(entry["rv"]), int(entry["n"])]
	_dirty[c] = true


## --stutter-probe: how long chunks take to appear. A chunk entering the wanted square round the
## focus is noted, and again if it comes within NEAR_RING chunks of the focus still not drawn (in
## view at the default camera); once drawn (its ground and buildings), the time it took goes to
## drawn_latency as [ms since wanted, its ring from the focus's chunk then, ms since it came near
## or -1]. undrawn() is how many wanted aren't drawn yet, near_undrawn how many of them are near.
const NEAR_RING := 2
var near_undrawn := 0
var _near_at := {}
var track_latency := false
var drawn_latency: Array = []
var _wanted_at := {}  # Vector2i -> msec it was first wanted (while not drawn)
## Of _wanted_at, the chunks that have arrived (the only ones that can be drawn): the 50 ms look
## walks these, not all of _wanted_at. At view distance 50 that held ~9,500 chunks not asked for yet,
## and walking them every 50 ms was 2.8 ms in one frame in five, inside the very numbers the probe
## reports (client-cpu.md 4).
var _lat_arrived := {}
var _latency_timer := 0.0
var _latency_center := Vector2i(0x7fffffff, 0)
var _latency_radius := -1


func _track_latency(delta: float) -> void:
	var now := Time.get_ticks_msec()
	if _wanted_center != _latency_center or _wanted_radius != _latency_radius or _wanted_gen != _latency_gen:
		var was := _latency_center
		var whole := _wanted_radius >= 0 and not _cone_active and _wanted_size() == (2 * _wanted_radius + 1) * (2 * _wanted_radius + 1) \
			and _sq_center == _wanted_center and _sq_radius == _wanted_radius and not _cover_seen.is_valid()
		if whole and _latency_radius == _wanted_radius and was.x != 0x7fffffff \
				and maxi(absi(was.x - _wanted_center.x), absi(was.y - _wanted_center.y)) <= _wanted_radius:
			# Walking: only the rows and columns the square gained and lost (about 101 a chunk crossed).
			_latency_strip(_wanted_center, was, _wanted_radius, now, true)
			_latency_strip(was, _wanted_center, _wanted_radius, now, false)
		else:
			var wanted := {}
			for c in _wanted:
				wanted[c] = true
				if not _wanted_at.has(c) and not _drawn(c):
					_latency_want(c, now)
			for c in _wanted_at.keys():
				if not wanted.has(c):
					_latency_drop(c)  # left the square before it was drawn
		_latency_center = _wanted_center
		_latency_radius = _wanted_radius
		_latency_gen = _wanted_gen
	_latency_timer += delta
	if _latency_timer < 0.05:
		return
	_latency_timer = 0.0
	for c: Vector2i in _lat_arrived.keys():
		if _drawn(c):
			var ring := maxi(absi(c.x - _wanted_center.x), absi(c.y - _wanted_center.y))
			drawn_latency.append([now - int(_wanted_at[c]), ring, now - int(_near_at[c]) if _near_at.has(c) else -1])
			_latency_drop(c)
	near_undrawn = 0
	for dy in range(-NEAR_RING, NEAR_RING + 1):
		for dx in range(-NEAR_RING, NEAR_RING + 1):
			var c := _wanted_center + Vector2i(dx, dy)
			if _wanted_at.has(c):
				near_undrawn += 1
				if not _near_at.has(c):
					_near_at[c] = now


## A chunk wanted now and not drawn: timed from `now`.
func _latency_want(c: Vector2i, now: int) -> void:
	_wanted_at[c] = now
	var cv: ChunkView = chunks.get(c)
	if cv != null and cv.loaded:
		_lat_arrived[c] = true  # kept past the square, or arrived and not built yet


func _latency_drop(c: Vector2i) -> void:
	_wanted_at.erase(c)
	_near_at.erase(c)
	_lat_arrived.erase(c)


## The chunks of the square `radius` round `center` outside the one round `other`: newly wanted
## (`add`), or no longer (not `add`).
func _latency_strip(center: Vector2i, other: Vector2i, radius: int, now: int, add: bool) -> void:
	var x0 := center.x - radius
	var x1 := center.x + radius
	for y in range(center.y - radius, center.y + radius + 1):
		if absi(y - other.y) > radius:
			for x in range(x0, x1 + 1):
				_latency_cell(Vector2i(x, y), now, add)
			continue
		# A row both squares share: only its ends past the other square's columns.
		for x in range(x0, mini(x1, other.x - radius - 1) + 1):
			_latency_cell(Vector2i(x, y), now, add)
		for x in range(maxi(x0, other.x + radius + 1), x1 + 1):
			_latency_cell(Vector2i(x, y), now, add)


func _latency_cell(c: Vector2i, now: int, add: bool) -> void:
	if not add:
		if _wanted_at.has(c):
			_latency_drop(c)
	elif not _wanted_at.has(c) and not _drawn(c):
		_latency_want(c, now)


func undrawn() -> int:
	return _wanted_at.size()


## Everything asked for is drawn and nothing is being built (full_detail.gd waits for it before a
## screenshot): no chunk dirty, part-built or waiting for its ground, every wanted chunk subscribed and
## drawn, and no level of detail cross-fading.
func settled() -> bool:
	if not (_dirty.is_empty() and _pending.is_empty() and _partial.is_empty() and _prep_jobs.is_empty() and terrain_queue_size() == 0):
		return false
	if _wanted_size() > _subscribed_size():
		return false
	var sub_check: Variant = _asked if _subscribed_lazy else _subscribed_arr
	for c in sub_check:
		if not _drawn(c):
			return false
	for cv: ChunkView in chunks.values():
		if cv.lod_fading():
			return false
	return true


## What a screenshot still waits for among the chunks `in_view` says it sees (a Callable(Vector2i)
## -> bool; full_detail.gd, the camera's view): those being built (dirty, part-built, their ground
## or buildings still to come, a level cross-fading), and those wanted but not arrived yet unless
## `given_up` (the bridge has sent nothing new for a while: it sends what it can as its work
## budget allows, and a chunk it never sends, lost or not there, mustn't hold the shot for good).
## Chunks off the view don't count: at view distance 20 most of the 1,681 are behind the camera or
## off its sides, still arriving after the shot is taken.
func unsettled_in(in_view: Callable, given_up: bool) -> int:
	var n := 0
	for c: Vector2i in _wanted:
		if not in_view.call(c):
			continue
		var cv: ChunkView = chunks.get(c)
		var arrived := cv != null and cv.loaded
		if not arrived:
			if not given_up:
				n += 1
		elif not _drawn(c) or _dirty_terrain.has(c) or _terrain_jobs.has(c) or cv.lod_fading():
			n += 1
	return n


## When a chunk last arrived for the first time (a snapshot, a cached one, or none: not generated).
## Resends of chunks already drawn don't count: the bridge refreshes them now and then for ever.
var last_arrival_msec := 0


## A gap can't say what it lost, so this guesses: chunks known to be incomplete, chunks still
## empty long after the stream went quiet, and if neither, the lost message was probably a
## change near the player, so the 3x3 chunks around the focus.
func resync_list() -> Array:
	var list: Array = []
	for cv in chunks.values():
		if _missing(cv):
			list.append([cv.coord.x, cv.coord.y])
			if list.size() >= RESYNC_MAX:
				break  # the rest on the watchdog's next look
	if list.is_empty():
		var center := chunk_of(_focus)
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var c := center + Vector2i(dx, dy)
				if chunks.has(c):
					list.append([c.x, c.y])
	return list


func _watch_for_missing(delta: float) -> void:
	_watchdog_timer += delta
	if _watchdog_timer < WATCHDOG_INTERVAL:
		return
	_watchdog_timer = 0.0
	for cv in chunks.values():
		if _missing(cv):
			Bridge.request_resync(false)
			return


## While a screenshot loads, STREAM_SHOT chunks wait in the bridge's queue and outbox for longer than
## MISSING_CHUNK_MSEC: one not come yet is guessed lost only once no chunk has come for that long, or
## every 3 s the watchdog asked for a few hundred again, and the bridge read and sent those already
## on their way twice.
func _missing(cv: ChunkView) -> bool:
	if cv.is_incomplete():
		return true
	if cv.loaded:
		return false
	var now := Time.get_ticks_msec()
	if _shot_built and now - last_arrival_msec <= MISSING_CHUNK_MSEC:
		return false
	return now - cv.created_msec > MISSING_CHUNK_MSEC


var _wanted_arr: Array = []  # the chunks round the focus, nearest first
var _wanted_lazy := false
var _wanted_count := 0
var _wanted: Array:
	get:
		if _wanted_lazy:
			var out: Array = []
			if _wanted_radius >= 0:
				for offset: Vector2i in prio_order(_wanted_radius, _wanted_sector):
					if out.size() >= _wanted_most:
						break
					out.append(_wanted_center + offset)
			_wanted_arr = out
			_wanted_lazy = false
		return _wanted_arr
	set(v):
		_wanted_arr = v
		_wanted_lazy = false
		_wanted_count = v.size()


func _wanted_size() -> int:
	return _wanted_count if _wanted_lazy else _wanted_arr.size()
var _wanted_center := Vector2i(0x7fffffff, 0)
var _wanted_radius := -1
## The square the subscription is sent as: the view's own, or one fitted round a screenshot's cover.
var _sq_center := Vector2i.ZERO
var _sq_radius := 0
var _asked := {}  # _subscribed as a set
## The chunk cache: Vector3i(surface index, cx, cy) -> {rv, n, msgs: [chunk, ents...], dec: [...],
## msec}, oldest first. _filling: chunk -> the key its ents and dec messages go to.
var _cache := {}
var _filling := {}
var _replaying := false
var _cache_bytes := 0  # the cache's estimated size (CACHE_BYTES)
## Chunk -> [surface index, rv, n]: the bridge's counts the chunk as drawn matches (its snapshot's,
## `same`'s, or `kept`'s once it left the square). Deltas don't change it: a chunk that got some while
## subscribed matches only what `kept` says when it leaves.
var _live := {}
## Chunks kept built and drawn after leaving the square (WARM_RINGS): Vector2i -> msec they left.
var _warm := {}
## The surface the bridge streams (welcome and surface `si`, set by main.gd): chunks offered from the cache.
var surface_index := -1
## Replays a cached `dec` message (main.gd: decoratives.handle).
var replay_dec := Callable()
var _coming := {}  # chunks asked for and not drawn yet
## The most chunks the bridge subscribes to (world.lua MAX_SUBSCRIPTIONS, a 101x101 square, the
## whole square of the furthest view distance): it drops the rest of a longer list, so asking for
## more left those chunks waiting in `_coming` for good, taking the places of chunks that could
## come. Past it the nearest are asked for, a rounder view.
const MAX_SUBSCRIPTIONS := 10201
## The furthest view distance (Settings > Graphics > View distance; world.lua MAX_RADIUS).
const MAX_VIEW_RADIUS := 50
## A bridge from before square subscriptions (no welcome `sq`) takes a list of at most this many.
const LIST_MAX := 625
var _wanted_most := 0
var _wanted_moved := false  # _wanted changed since the last step
var _wanted_sector := -1  # the view direction _wanted was ordered for (SECTORS; -1 none)
var _wanted_f := Vector2i.ZERO  # its sector_vector (none: zero)
var _sent_sector := -1  # and the one the last `sub` said (`f`)
var _view_on := false  # the camera looks far enough sideways for a direction (VIEW_FLAT_ON, VIEW_FLAT_OFF)
var _vel := Vector2.ZERO  # the focus's speed, smoothed (tiles a second)
var _vel_from := Vector2(INF, INF)
const CONE_TURN_DEG := 5.0
const CONE_MOVE_TILES := 16.0
var _view_cone := false
var _cone_active := false
var _cone_center := Vector2i(0x7fffffff, 0)
var _cone_at := Vector3(INF, INF, INF)
var _cone_fwd := Vector3.ZERO
var _cone_lens: Array = []
var _wanted_gen := 0
var _latency_gen := -1


## The view's direction as a sector (SECTORS; -1 for none): where the camera looks on the ground,
## turned towards where the focus moves, kept until it turns SECTOR_SLACK of a sector past the
## sector's edge. None while a screenshot's cover is on (its own order) or looking straight down.
func _view_sector(delta: float) -> int:
	if _vel_from.x != INF and delta > 0.0:
		var v := (_focus - _vel_from) / delta
		if v.length() < 120.0:  # faster is a jump
			_vel = _vel.lerp(v, clampf(delta * 4.0, 0.0, 1.0))
		else:
			_vel = Vector2.ZERO
	_vel_from = _focus
	_focus_vel = _vel
	if has_cover() or _shot_built:
		return -1
	var d := Vector2.ZERO
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null:
		var fwd := -cam.global_transform.basis.z
		var flat := Vector2(fwd.x, fwd.z)
		_view_on = flat.length() > (VIEW_FLAT_OFF if _view_on else VIEW_FLAT_ON)
		if _view_on:
			d = flat.normalized()
	if _vel.length() > MOVING_SPEED:
		if stream_lookahead and not stream_window_legacy and _vel.length() > 12.0:
			d += _vel.normalized() * 2.5
		else:
			d += _vel.normalized()
	if d.length() < 0.2:
		return -1
	var a := d.angle()
	var step := TAU / SECTORS
	if _wanted_sector >= 0 and absf(angle_difference(_wanted_sector * step, a)) <= step * (0.5 + SECTOR_SLACK):
		return _wanted_sector
	return posmod(roundi(a / step), SECTORS)


## Where a chunk stands in line to be built (smaller first): its view distance from `center`, and
## after every chunk in view when it is hidden behind the camera (behind_cull.gd).
func _build_rank(c: Vector2i, center: Vector2i) -> int:
	return distance_along(c - center, _wanted_f) + (1 << 30 if behind_cull.hidden(c) else 0)

## api.world.hold_chunks: chunks the view leaves stay drawn as they were last sent (the bridge no
## longer updates them), so a screenshot or a flight shows everything streamed so far. Only chunks
## that arrived whole are held (one still on its way would be asked for again and again). Capped:
## HOLD_MAX_CHUNKS held besides the subscribed ones (a 40 x 40 square past the view, about 1,300
## tiles across), and fewer once the computer has under HOLD_MIN_FREE bytes of memory free; past
## either the held chunks farthest from the focus go, and the log says so once.
const HOLD_MAX_CHUNKS := 1600
const HOLD_MIN_FREE := 1 << 30
## And no more than HOLD_TOTAL chunks loaded with the view's own (full detail's 41 x 41 and the 1,600
## past it): at a longer view distance fewer are held, none from 29 up. Every chunk drawn has its
## MultiMeshes, each an instance with its own shader values in Godot's one buffer for them
## (project.godot limits/global_shader_variables/buffer_size, 16 slots an instance): thousands more
## chunks overflowed it ("Too many instances using shader instance variables") and drew at 6 FPS.
const HOLD_TOTAL := 41 * 41 + HOLD_MAX_CHUNKS
## The same, for tests (0: no memory check).
var hold_min_free := HOLD_MIN_FREE
var hold := false
var _held := {}  # Vector2i -> true: chunks kept though no longer subscribed
var _hold_capped := false


## Holds the chunks the view leaves (true), or lets the held ones go at the next step (false).
func set_hold(on: bool) -> void:
	if on == hold:
		return
	hold = on
	_hold_capped = false
	_wanted_moved = true
	_stream_timer = STREAM_STEP


func held_count() -> int:
	return _held.size()


## Keeps a chunk the view left, or unloads it when it can't be held.
func _leave(c: Vector2i) -> void:
	var cv: ChunkView = chunks[c]
	if hold and cv.loaded and not cv.is_incomplete():
		_held[c] = true
		return
	_held.erase(c)
	# The area cache (warm_rings); not while a screenshot's subscription is held (it lets go as before).
	if cv.loaded and not cv.is_incomplete() and not _shot_built and not has_cover() and _warm_limit() > 0 \
			and _past_square(c) <= warm_rings:
		_warm[c] = Time.get_ticks_msec()
		return
	_unload(c)


## How many chunks chunk `c` lies past the square sent (0 or less: inside it).
func _past_square(c: Vector2i) -> int:
	return maxi(absi(c.x - _sq_center.x), absi(c.y - _sq_center.y)) - _sq_radius


const FREE_MEM_MSEC := 1000
var _free_mem_msec := -FREE_MEM_MSEC
var _free_mem_bytes := -1


func _free_memory_cached() -> int:
	if hold_min_free <= 0:
		return -1
	var now := Time.get_ticks_msec()
	if now - _free_mem_msec >= FREE_MEM_MSEC:
		_free_mem_msec = now
		_free_mem_bytes = int(OS.get_memory_info().get("available", -1))
	return _free_mem_bytes


## How many chunks may be kept past the square now (WARM_MAX, HOLD_TOTAL; memory aside).
func _warm_limit() -> int:
	if warm_rings <= 0:
		return 0
	return mini(WARM_MAX, maxi(0, HOLD_TOTAL - _wanted_size() - _held.size()))


## Lets kept chunks go: those now more than warm_rings past the square, then past the limit (fewer
## with under hold_min_free of memory) those behind the camera first, the least recently left first.
func _cap_warm() -> void:
	for c: Vector2i in _warm.keys():
		if _past_square(c) > warm_rings or not chunks.has(c):
			_warm.erase(c)
			if chunks.has(c):
				_unload(c)
	var limit := _warm_limit()
	var free := _free_memory_cached()
	if free >= 0 and free < hold_min_free:
		limit = mini(limit, int(_warm.size() * 0.75))
	if _warm.size() <= limit:
		return
	var order: Array = _warm.keys()
	var first_out := func(a: Vector2i, b: Vector2i) -> bool:
		var ha: bool = behind_cull.hidden(a)
		if ha != behind_cull.hidden(b):
			return ha
		return int(_warm[a]) < int(_warm[b])
	order.sort_custom(first_out)
	for i in _warm.size() - limit:
		var c: Vector2i = order[i]
		_warm.erase(c)
		if chunks.has(c):
			_unload(c)


## The square of chunks subscribed (chunk coordinates), or an empty Rect2i before one or from a bridge
## without square subscriptions (behind_cull.gd unload_fast: the chunks kept past it aren't drawn).
func square_chunks() -> Rect2i:
	if Bridge.square_subs <= 0 or _sq_radius <= 0:
		return Rect2i()
	return Rect2i(_sq_center - Vector2i(_sq_radius, _sq_radius), Vector2i(_sq_radius * 2 + 1, _sq_radius * 2 + 1))


## How far chunks may be loaded round the square's middle, in chunks (behind_cull.gd).
func loaded_reach() -> int:
	return _sq_radius + warm_rings + 1


## The ground whose casters can throw a shadow into the view, when the sun casts any (behind_cull.gd
## keeps it drawn).
func shadow_outline() -> PackedVector2Array:
	return _shadow_hull if _shadow_on else PackedVector2Array()


## How many chunks may be held now (HOLD_MAX_CHUNKS, HOLD_TOTAL; memory aside).
func _hold_limit() -> int:
	return mini(HOLD_MAX_CHUNKS, maxi(0, HOLD_TOTAL - _wanted_size()))


## Lets the farthest held chunks go past the cap (HOLD_MAX_CHUNKS, HOLD_TOTAL, HOLD_MIN_FREE).
func _cap_held() -> void:
	var limit := _hold_limit()
	var free := _free_memory_cached()
	if free >= 0 and free < hold_min_free:
		limit = mini(limit, int(_held.size() * 0.75))  # a quarter let go at each step until there is room
	if _held.size() <= limit:
		return
	if not _hold_capped:
		_hold_capped = true
		print("world: hold_chunks limit reached (%d held, cap %d chunks with %d in view, %d MB free): the farthest let go" % [
			_held.size(), limit, _wanted_size(), free >> 20 if free >= 0 else -1])
	var center := stream_center()
	var order: Array = _held.keys()
	order.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a - center).length_squared() > (b - center).length_squared())
	for i in _held.size() - limit:
		var c: Vector2i = order[i]
		_held.erase(c)
		if chunks.has(c):
			_unload(c)


## A screenshot's cover (full_detail.gd set_cover): the chunks its camera sees are asked for besides
## the view's own square, so a shot zoomed far out isn't cut off at the view distance round the
## focus (the camera may look far past it). The bridge takes one square (`sub` `o`, `r`, up to its
## `sq`), so the square sent is fitted round both, or round the camera's view alone when both don't
## fit, kept nearest the camera; in it only chunks in the view's square or seen are asked for, so
## none behind the camera hold up the ones in the picture. `rect` (chunks) holds what the camera
## sees, `near` is the chunk under the camera, `seen` a Callable(Vector2i) -> bool.
##
## The shot's subscription is worked out once, at the first step after set_cover (_build_shot), and
## held until clear_cover: the focus (an add-on's camera keeps gliding, the view radius full detail
## raises a frame later) no longer moves the square, so nothing the shot asked for is dropped and asked
## for again. It holds the chunks in the camera's view, nearest the camera first, and the chunks
## already loaded in the square (they stay drawn); chunks off the view not loaded yet aren't asked for.
## What the shot waits for is that fixed set (shot_progress): a chunk counts as come once it is
## drawn, and never again as to come, whatever the bridge sends after (a refresh, a chunk Factorio
## generated since); so the count only goes down. Meanwhile STREAM_SHOT chunks may be on their way,
## TERRAIN_JOBS_SHOT terrain jobs run, and the bridge is in photo mode (`photo`, photo.lua).
var _cover_rect := Rect2i()
var _cover_near := Vector2i.ZERO
var _cover_seen := Callable()
var _cover_gen := 0
var _wanted_cover_gen := 0
var _shot_built := false  # the shot's subscription is worked out and held
var _shot_set := {}  # Vector2i -> true: the chunks in the shot's view it waits for (fixed)
var _shot_left := {}  # of them, those not drawn yet
var _shot_watch := {}  # of those, the ones asked for (looked at each frame)
var _shot_dropped := 0  # given up on: the bridge sent nothing for them (_shot_give_up)
var _shot_msec := 0  # when the shot's subscription was worked out
var _photo_for := 0.0  # seconds since `photo` was last said
## `photo` is said again this often while a shot loads (the bridge lets photo mode lapse by itself
## 900 game ticks after the last).
const PHOTO_REPEAT := 4.0
## A shot's chunks that haven't come are given up once every one of them has been asked for, none
## has arrived for SHOT_QUIET_MSEC and the bridge's last work report has no chunks queued (or for
## SHOT_QUIET_LONG_MSEC without a report): the bridge has sent what it will. Before every one was
## asked for, a quiet bridge was only waiting for the client to ask (the old count let go of them
## then and took them back when the next chunk came: down and up).
const SHOT_QUIET_MSEC := 5000
const SHOT_QUIET_LONG_MSEC := 15000


func set_cover(rect: Rect2i, near: Vector2i, seen: Callable) -> void:
	_cover_rect = rect
	_cover_near = near
	_cover_seen = seen
	_cover_gen += 1
	_sub_grid_valid = false
	_sub_rows.clear()
	_sub_cursor = 0
	_stream_timer = STREAM_STEP
	_shot_built = false
	_shot_set.clear()
	_shot_left.clear()
	_shot_watch.clear()
	_shot_dropped = 0
	_photo_for = 0.0
	Bridge.send({"t": "photo", "on": 1})


func clear_cover() -> void:
	if _cover_seen.is_valid():
		_cover_seen = Callable()
		_cover_gen += 1
		_sub_grid_valid = false
		_sub_rows.clear()
		_sub_cursor = 0
		_stream_timer = STREAM_STEP
		_shot_built = false
		_shot_set.clear()
		_shot_left.clear()
		_shot_watch.clear()
		Bridge.send({"t": "photo", "on": 0})


## A screenshot's chunks (set_cover): `total` the chunks in its view it waits for (fixed when it was
## worked out), `left` those not drawn yet (it only goes down), `dropped` those given up on (the
## bridge never sent them), `building` those drawn and being built again (the bridge sent them again:
## the picture waits for that too, but it isn't "to come"), `ready` false until it is worked out (the
## first step after set_cover). {} without a cover.
func shot_progress() -> Dictionary:
	if not _cover_seen.is_valid():
		return {}
	if not _shot_built:
		return {"ready": false, "total": 0, "left": 0, "dropped": 0, "building": 0}
	var building := 0
	for queue: Dictionary in [_dirty, _partial, _pending, _prep_jobs, _dirty_terrain, _terrain_jobs]:
		for c: Vector2i in queue:
			if _shot_set.has(c) and not _shot_left.has(c):
				building += 1
	return {"ready": true, "total": _shot_set.size(), "left": _shot_left.size(), "dropped": _shot_dropped,
		"building": building}


## The shot's subscription (see set_cover), round the view's own square (`center`, `radius`) as the
## bridge takes it (`square`, up to `most` chunks for a list), worked out once.
func _build_shot(center: Vector2i, radius: int, most: int, square: bool) -> void:
	var candidates: Array = []
	if square:
		var fit := _cover_square(center, radius, Bridge.square_subs)
		_sq_center = fit[0]
		_sq_radius = fit[1]
		for offset: Vector2i in ring_order(_sq_radius):
			candidates.append(_sq_center + offset)
	else:
		for offset: Vector2i in ring_order(radius):
			if candidates.size() >= most:
				break
			candidates.append(center + offset)
	# Seen ones nearest the camera first, then those loaded. Sorted natively: distance² times 2^16
	# plus the chunk's place in `candidates` (at most 10,201).
	var keys := PackedInt64Array()
	var kept: Array = []
	for i in candidates.size():
		var c: Vector2i = candidates[i]
		if _cover_seen.call(c):
			keys.append(((c - _cover_near).length_squared() << 16) + i)
		elif chunks.has(c):
			kept.append(c)
	keys.sort()
	var next: Array = []
	for k in keys:
		var c: Vector2i = candidates[k & 0xffff]
		next.append(c)
		_shot_set[c] = true
		if not _shot_done(c):
			_shot_left[c] = true
			if _asked.has(c):
				_shot_watch[c] = true
	next.append_array(kept)
	_wanted = next
	_shot_built = true
	_shot_msec = Time.get_ticks_msec()


## Whether a chunk of the shot is drawn as it will be in the picture: arrived, its buildings built
## and its ground meshed (or ground it can't have: tiles that aren't a whole chunk).
func _shot_done(c: Vector2i) -> bool:
	return _drawn(c) and not _dirty_terrain.has(c) and not _terrain_jobs.has(c)


## Each frame of a shot: the chunks asked for that are drawn now leave what it waits for, those the
## bridge never sends are given up on (_shot_give_up), and `photo` is said again now and then.
func _update_shot(delta: float) -> void:
	if not _cover_seen.is_valid():
		return
	_photo_for += delta
	if _photo_for >= PHOTO_REPEAT:
		_photo_for = 0.0
		Bridge.send({"t": "photo", "on": 1})
	if not _shot_built:
		return
	for c: Vector2i in _shot_watch.keys():
		if _shot_done(c):
			_shot_watch.erase(c)
			_shot_left.erase(c)
	_shot_give_up()


## The shot's chunks the bridge has stopped sending are no longer waited for (see SHOT_QUIET_MSEC):
## once, for good, so the count goes down and stays down.
func _shot_give_up() -> void:
	if _shot_left.is_empty() or _shot_watch.size() < _shot_left.size():
		return  # some not asked for yet: the bridge may only be waiting for the client
	var now := Time.get_ticks_msec()
	var quiet := now - maxi(last_arrival_msec, _shot_msec)
	if quiet < SHOT_QUIET_MSEC:
		return
	var queued := -1  # unknown without a recent work report
	if Bridge.work_budget_msec > 0 and now - Bridge.work_budget_msec <= 2500:
		var q = Bridge.work_budget.get("q")
		queued = int(q.get("chunks", 0)) if q is Dictionary else 0
	if queued != 0 and quiet < SHOT_QUIET_LONG_MSEC:
		return
	var gone := 0
	for c: Vector2i in _shot_left.keys():
		var cv: ChunkView = chunks.get(c)
		if cv == null or not cv.loaded:
			_shot_left.erase(c)
			_shot_watch.erase(c)
			gone += 1
	if gone > 0:
		_shot_dropped += gone
		print("world: %d of a screenshot's chunks never came from the bridge (nothing new for %.0f s): not waited for" % [gone, quiet / 1000.0])


func has_cover() -> bool:
	return _cover_seen.is_valid()


## The square (middle, radius) that holds `rect`, at most `most` chunks from its middle each way:
## where `rect` is wider than that, the part of it nearest `near`.
static func fit_square(rect: Rect2i, near: Vector2i, most: int) -> Array:
	var r := mini(most, maxi(ceili((rect.size.x - 1) * 0.5), ceili((rect.size.y - 1) * 0.5)))
	var lo := rect.position
	var hi := rect.end - Vector2i.ONE
	var cx := clampi(near.x, mini(lo.x + r, hi.x - r), maxi(lo.x + r, hi.x - r))
	var cy := clampi(near.y, mini(lo.y + r, hi.y - r), maxi(lo.y + r, hi.y - r))
	return [Vector2i(cx, cy), maxi(r, 0)]


## The square to send while a cover is on: round the view's own square and the cover's rect, or the
## cover's alone when the two don't fit in the bridge's largest (`most`).
func _cover_square(center: Vector2i, radius: int, most: int) -> Array:
	var own := Rect2i(center - Vector2i(radius, radius), Vector2i.ONE * (radius * 2 + 1))
	var both := own.merge(_cover_rect)
	if maxi(both.size.x, both.size.y) <= most * 2 + 1:
		return fit_square(both, _cover_near, most)
	return fit_square(_cover_rect, _cover_near, most)


## The offsets of a square of chunks `radius` round its middle, nearest first (by squared distance,
## then row by row). The subscription list used to be sorted with a GDScript comparison whenever the
## focus crossed a chunk edge: 841 chunks at Ultra, 3-12 ms in one frame while walking (docs/
## PERFORMANCE-AUDIT.md 4.7). Now one pass into buckets, and only when the radius changes.
static var _ring_orders := {}


static func ring_order(radius: int) -> Array:
	var order: Array = _ring_orders.get(radius, [])
	if not order.is_empty():
		return order
	var buckets := {}  # squared distance -> offsets
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var d := dx * dx + dy * dy
			if not buckets.has(d):
				buckets[d] = []
			(buckets[d] as Array).append(Vector2i(dx, dy))
	var distances: Array = buckets.keys()
	distances.sort()
	for d in distances:
		order.append_array(buckets[d])
	_ring_orders[radius] = order
	return order


## The view direction of a sector (SECTORS round, 0 east, clockwise on the map as Factorio's y grows
## south) as integers about 256 long: `sub` f, and prio_order's.
static func sector_vector(sector: int) -> Vector2i:
	var a := sector * TAU / SECTORS
	return Vector2i(roundi(cos(a) * 256.0), roundi(sin(a) * 256.0))


## A chunk's distance from the middle for the wanted order, in chunks squared: behind the view
## (`sector`, -1 for none) it counts as further away, up to twice straight behind (BEHIND, as
## world.lua's rank_of).
static func view_distance(d: Vector2i, sector: int) -> int:
	return distance_along(d, sector_vector(sector) if sector >= 0 else Vector2i.ZERO)


## view_distance with the sector's vector (`f`, Vector2i.ZERO for none) worked out already.
static func distance_along(d: Vector2i, f: Vector2i) -> int:
	var m := d.length_squared() * 65536
	var dot := d.x * f.x + d.y * f.y
	if dot < 0:
		m += BEHIND * dot * dot
	return m >> 16


## ring_order for a view direction (I18): the same offsets, by view_distance (then row by row), so the
## chunks the camera looks at and the focus moves towards are asked for and built first. Bucketed like
## ring_order, made once per radius and sector.
static var _prio_orders := {}
static var _lead_orders := {}


static func _compute_prio_order(radius: int, sector: int) -> Array:
	var order: Array = []
	var buckets := {}
	var f := sector_vector(sector) if sector >= 0 else Vector2i.ZERO
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var d := distance_along(Vector2i(dx, dy), f)
			if not buckets.has(d):
				buckets[d] = []
			(buckets[d] as Array).append(Vector2i(dx, dy))
	var distances: Array = buckets.keys()
	distances.sort()
	for d in distances:
		order.append_array(buckets[d])
	return order


static func prio_order(radius: int, sector: int) -> Array:
	if sector < 0:
		return ring_order(radius)
	var key := radius * SECTORS + sector
	var order: Array = _prio_orders.get(key, [])
	if not order.is_empty():
		return order
	order = _compute_prio_order(radius, sector)
	_prio_orders[key] = order
	return order


static func prio_order_lead(radius: int, sector: int, lead: Vector2i) -> Array:
	if lead == Vector2i.ZERO:
		return prio_order(radius, sector)
	var key := Vector4i(radius, sector, lead.x, lead.y)
	var cached: Variant = _lead_orders.get(key)
	if cached is Array and not (cached as Array).is_empty():
		return cached as Array
	var buckets := {}
	var f := sector_vector(sector) if sector >= 0 else Vector2i.ZERO
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var off := Vector2i(dx, dy)
			var rank: int = off.length_squared() if off.length_squared() <= 4 else (4 + distance_along(off - lead, f))
			if not buckets.has(rank):
				buckets[rank] = []
			(buckets[rank] as Array).append(off)
	var distances: Array = buckets.keys()
	distances.sort()
	var out: Array = []
	for d in distances:
		out.append_array(buckets[d])
	if _lead_orders.size() > 64:
		_lead_orders.clear()
	_lead_orders[key] = out
	return out


func _poll_prio_warm() -> void:
	if _prio_warm_task < 0:
		return
	if not WorkerThreadPool.is_task_completed(_prio_warm_task):
		return
	WorkerThreadPool.wait_for_task_completion(_prio_warm_task)
	for k in _prio_warm_out:
		if not _prio_orders.has(k):
			_prio_orders[k] = _prio_warm_out[k]
	_prio_warm_out = {}
	_prio_warm_task = -1


func _maybe_warm_prio(radius: int) -> void:
	_poll_prio_warm()
	if radius < 8 or _prio_warm_task >= 0 or _prio_warm_radius == radius:
		return
	var missing: Array[int] = []
	for s in SECTORS:
		if not _prio_orders.has(radius * SECTORS + s):
			missing.append(s)
	_prio_warm_radius = radius
	if missing.is_empty():
		return
	var out := {}
	_prio_warm_out = out
	var work := func() -> void:
		for s: int in missing:
			out[radius * SECTORS + s] = _compute_prio_order(radius, s)
	_prio_warm_task = WorkerThreadPool.add_task(work, false, "prio_order")


## The subscription as `sub` carries it (docs/PROTOCOL.md, world.lua subscribe_square): per row of
## the square `radius` round `center` that has any of `list`, the row's chunk y, then runs of [first
## chunk x, count]. A list of 10,201 chunks (view distance 50) was about 120 KB, more than a
## datagram holds; a full square is about 1.5 KB this way. The bridge orders the chunks itself,
## nearest `center` first, as ring_order does.
static func square_rows(center: Vector2i, radius: int, list: Array) -> Array:
	var side := radius * 2 + 1
	var grid := PackedByteArray()
	grid.resize(side * side)
	for c: Vector2i in list:
		var dx := c.x - center.x + radius
		var dy := c.y - center.y + radius
		if dx >= 0 and dx < side and dy >= 0 and dy < side:
			grid[dy * side + dx] = 1
	var rows: Array = []
	for dy in side:
		var base := dy * side
		var end := base + side
		var row: Array = []
		# find() scans natively: a GDScript loop over every cell cost a millisecond a send at 50.
		var at := grid.find(1, base)
		while at >= 0 and at < end:
			var stop := grid.find(0, at)
			if stop < 0 or stop > end:
				stop = end
			row.append_array([center.x - radius + at - base, stop - at])
			at = grid.find(1, stop) if stop < end else -1
		if not row.is_empty():
			row.push_front(center.y - radius + dy)
			rows.append(row)
	return rows


## Same row-run format built directly from the incremental per-row byte grid (`_sub_rows`).
static func square_rows_from_rows(center: Vector2i, radius: int, row_grid: Array[PackedByteArray]) -> Array:
	var side := radius * 2 + 1
	var rows: Array = []
	for dy in side:
		var grid: PackedByteArray = row_grid[dy]
		var row: Array = []
		var at := grid.find(1, 0)
		while at >= 0:
			var stop := grid.find(0, at)
			if stop < 0:
				stop = side
			row.append_array([center.x - radius + at, stop - at])
			at = grid.find(1, stop) if stop < side else -1
		if not row.is_empty():
			row.push_front(center.y - radius + dy)
			rows.append(row)
	return rows


var _wanted_lead := Vector2i.ZERO


func _lookahead_lead(radius: int) -> Vector2i:
	if not stream_lookahead or stream_window_legacy or _shot_built or has_cover():
		return Vector2i.ZERO
	if _focus_vel.length() <= 12.0 or radius < 3:
		return Vector2i.ZERO
	var dir := _focus_vel.normalized()
	var steps := mini(3, maxi(1, radius / 2))
	return Vector2i(roundi(dir.x * float(steps)), roundi(dir.y * float(steps)))


func _stream_allowance(moving: bool, radius: int) -> int:
	if stream_window_override > 0:
		return stream_window_override
	if stream_window_legacy:
		return STREAM_MOVING if moving else STREAM_STILL
	var cap := clampi(radius * 3, 20, 48) if moving else clampi(radius * 4, 32, 64)
	if moving and (_dirty.size() + _prep_jobs.size() > 16 or FrameBudget.pool <= FrameBudget.POOL_MIN):
		cap = maxi(16, cap / 2)
	return cap


func _spawn_chunk(c: Vector2i, have: Array) -> void:
	if surface_index >= 0 and _disk_cache.is_configured() and not _cache.has(Vector3i(surface_index, c.x, c.y)):
		var dc := _disk_cache.get_loaded_chunk(c.x, c.y)
		if not dc.is_empty():
			_promote_disk_chunk(c, dc)
		elif not _disk_cache.has_region_loaded(c.x, c.y):
			_disk_cache.request_chunk(c.x, c.y)
			_disk_waiting[c] = true
	var offer := _cached_offer(c)
	if not offer.is_empty():
		have.append(offer)
	var cv := ChunkView.new()
	cv.coord = c
	cv.name = "Chunk_%d_%d" % [c.x, c.y]
	ChunkView.count("new_chunk")
	add_child(cv)
	chunks[c] = cv
	_row_add(c, cv)
	far_chunks.note_added(c)
	_shadow_fresh.append(cv)
	_shadow_uncounted[c] = true
	behind_cull.added(c, cv)
	if optimistic_cache and not _optimistic_pending.has(c):
		var opt := _cache_entry_for_optimistic(c)
		if not opt.is_empty():
			_optimistic_queue.append(c)
			_opt_queue_gen += 1
			_optimistic_pending[c] = true


func _drop_sub_cell(cx: int, cy: int) -> void:
	var c := Vector2i(cx, cy)
	_asked.erase(c)
	_coming.erase(c)
	if chunks.has(c) and (not _held.has(c) or not hold):
		_leave(c)


func _update_subscription(delta: float) -> void:
	_poll_prio_warm()
	# Held chunks never past the cap, whether or not this step goes on (the view may have grown).
	if not _held.is_empty() and (not hold or _held.size() > _hold_limit()):
		if hold:
			_cap_held()
		else:
			_wanted_moved = true  # let go: the next step unloads them
	var center := chunk_of(_focus)
	var sector := _view_sector(delta)
	# A bridge from before square subscriptions takes a list of its nearest LIST_MAX; a later one a
	# square out to its welcome's `sq`.
	var square := Bridge.square_subs > 0
	var radius := mini(view_radius, Bridge.square_subs) if square else view_radius
	var most := MAX_SUBSCRIPTIONS if square else LIST_MAX
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var cone_on := ViewPriority.cone_streaming and _view_cone and cam != null and not remote_view and not _shot_built and not _cover_seen.is_valid()
	if cone_on:
		var cam_pos := cam.global_position
		var cam_chunk := chunk_of(Vector2(cam_pos.x, cam_pos.z))
		var cone_r := ViewPriority.cone_radius(view_radius, Bridge.square_subs if square else 0)
		var vp_size := get_viewport().get_visible_rect().size
		var fwd := -cam.global_transform.basis.z
		var lens := [cam.projection, roundi(cam.fov * 10.0), roundi(cam.size * 10.0), cam.keep_aspect, roundi(vp_size.x), roundi(vp_size.y), cone_r, most]
		var cone_changed := (not _cone_active) or cam_chunk != _cone_center or cam_pos.distance_to(_cone_at) >= CONE_MOVE_TILES \
			or fwd.dot(_cone_fwd) < cos(deg_to_rad(CONE_TURN_DEG)) or lens != _cone_lens or _cover_gen != _wanted_cover_gen
		_maybe_warm_prio(cone_r)
		if cone_changed:
			if cam_chunk != _wanted_center:
				var walked := not chunks.is_empty() and maxi(absi(cam_chunk.x - _wanted_center.x), absi(cam_chunk.y - _wanted_center.y)) <= JUMP_CHUNKS
				_moved_msec = Time.get_ticks_msec() if walked else STOOD
			if _wanted_center.x != 0x7fffffff and (cam_chunk != _wanted_center or cone_r != _sq_radius):
				_recheck_coarse(_wanted_center, cam_chunk, maxi(_sq_radius, cone_r))
			_sub_grid_valid = false  # the cone sends the whole list; the incremental grid starts over after it
			_cone_active = true
			_cone_center = cam_chunk
			_cone_at = cam_pos
			_cone_fwd = fwd
			_cone_lens = lens
			_wanted_center = cam_chunk
			_wanted_radius = cone_r
			_wanted_most = most
			_wanted_cover_gen = _cover_gen
			_wanted_sector = sector
			_wanted_f = sector_vector(sector) if sector >= 0 else Vector2i.ZERO
			_sq_center = cam_chunk
			_sq_radius = cone_r
			_wanted = ViewPriority.cone_chunks(cam, vp_size, ring_order(cone_r), cone_r, most)
			_wanted_gen += 1
			_wanted_moved = true
			_stream_timer = STREAM_STEP
	else:
		var was_cone := _cone_active
		var prev_sq := _sq_radius
		if was_cone:
			_cone_active = false
			_cone_center = Vector2i(0x7fffffff, 0)
			_cone_at = Vector3(INF, INF, INF)
			_cone_fwd = Vector3.ZERO
			_cone_lens = []
			_sub_grid_valid = false
		_maybe_warm_prio(radius)
		var lead := _lookahead_lead(radius)
		# The wanted list only changes with the focus's chunk, the view radius, what the bridge takes or
		# a screenshot's cover; while a shot's is worked out, with nothing until it ends (set_cover).
		var changed := was_cone or center != _wanted_center or radius != _wanted_radius or most != _wanted_most or sector != _wanted_sector or lead != _wanted_lead
		if (changed and not _shot_built) or _cover_gen != _wanted_cover_gen:
			# Walking into the next chunks; a jump (a teleport, another surface, a factory building's
			# door) has nothing of its new square yet and loads it as a standing start does.
			if center != _wanted_center or was_cone:
				var walked := not chunks.is_empty() and maxi(absi(center.x - _wanted_center.x), absi(center.y - _wanted_center.y)) <= JUMP_CHUNKS
				_moved_msec = Time.get_ticks_msec() if walked else STOOD
				if _wanted_center.x != 0x7fffffff:
					_recheck_coarse(_wanted_center, center, maxi(prev_sq, radius))
			_wanted_center = center
			_wanted_radius = radius
			_wanted_most = most
			_wanted_cover_gen = _cover_gen
			_wanted_sector = sector
			_wanted_lead = lead
			_wanted_f = sector_vector(sector) if sector >= 0 else Vector2i.ZERO
			_sq_center = center
			_sq_radius = radius
			if _cover_seen.is_valid():
				_build_shot(center, radius, most, square)
			elif sub_incremental:
				_wanted_arr = []
				_wanted_lazy = true
				_wanted_count = mini((radius * 2 + 1) * (radius * 2 + 1), most)
				_sub_cursor = 0
			else:
				var next_w: Array = []
				for offset: Vector2i in prio_order_lead(radius, sector, lead):
					if next_w.size() >= most:
						break
					next_w.append(center + offset)
				_wanted = next_w
			_wanted_gen += 1
			_wanted_moved = true
			_stream_timer = STREAM_STEP  # the next step now: the chunks no longer wanted go at once
	_sub_timer += delta
	_stream_timer += delta
	if _stream_timer < STREAM_STEP and _sub_timer < SUBSCRIBE_REFRESH and not _all_came():
		return
	_stream_timer = 0.0
	# What was asked for and is still wanted stays; then the nearest of the rest, while fewer than
	# the allowance are on their way (asked for, not drawn yet). Worked out again only when the
	# focus crossed a chunk edge, a chunk can be added or the subscription is resent: most steps
	# while walking have nothing to do.
	var moving_now := Time.get_ticks_msec() - _moved_msec < MOVING_FOR * 1000.0
	var allowed := _stream_allowance(moving_now, radius)
	if _shot_built:
		allowed = STREAM_SHOT
	for c in _coming.keys():
		if _drawn(c) or absi(c.x - _sq_center.x) > _sq_radius or absi(c.y - _sq_center.y) > _sq_radius:
			_coming.erase(c)  # drawn, or no longer wanted (it goes below)
	var refresh := _sub_timer >= SUBSCRIBE_REFRESH
	if not (_wanted_moved or refresh or (_coming.size() < allowed and _subscribed_size() < _wanted_size())):
		return
	_wanted_moved = false
	var side := radius * 2 + 1
	var use_inc: bool = sub_incremental and square and not cone_on and not _shot_built and not _cover_seen.is_valid() and most >= side * side
	if use_inc:
		var differs := false
		var have: Array = []
		var can_shift: bool = _sub_grid_valid and _sub_grid_radius == radius and chunks.size() == _asked.size() + _warm.size() + _held.size()
		var shift := center - _sub_grid_center
		var sx: int = shift.x
		var sy: int = shift.y
		if can_shift and sx == 0 and sy == 0:
			if not hold and not _held.is_empty():
				for hc in _held.keys():
					_held.erase(hc)
					if chunks.has(hc) and not _asked.has(hc):
						_leave(hc)
		elif can_shift and absi(sx) <= radius and absi(sy) <= radius:
			if not hold and not _held.is_empty():
				for hc: Vector2i in _held.keys():
					if maxi(absi(hc.x - center.x), absi(hc.y - center.y)) > radius:
						_held.erase(hc)
						if chunks.has(hc) and not _asked.has(hc):
							_leave(hc)
			var y_keep0 := maxi(0, sy)
			var y_keep1 := mini(side, side + sy)
			var x_keep0 := maxi(0, sx)
			var x_keep1 := mini(side, side + sx)
			var ox0 := _sub_grid_center.x - radius
			var oy0 := _sub_grid_center.y - radius
			for old_dy in range(0, y_keep0):
				var r_drop: PackedByteArray = _sub_rows[old_dy]
				var at := r_drop.find(1, 0)
				while at >= 0:
					differs = true
					_drop_sub_cell(ox0 + at, oy0 + old_dy)
					at = r_drop.find(1, at + 1) if at + 1 < side else -1
			for old_dy in range(y_keep1, side):
				var r_drop: PackedByteArray = _sub_rows[old_dy]
				var at := r_drop.find(1, 0)
				while at >= 0:
					differs = true
					_drop_sub_cell(ox0 + at, oy0 + old_dy)
					at = r_drop.find(1, at + 1) if at + 1 < side else -1
			for old_dy in range(y_keep0, y_keep1):
				var r_keep: PackedByteArray = _sub_rows[old_dy]
				if x_keep0 > 0:
					var at := r_keep.find(1, 0)
					while at >= 0 and at < x_keep0:
						differs = true
						_drop_sub_cell(ox0 + at, oy0 + old_dy)
						at = r_keep.find(1, at + 1) if at + 1 < x_keep0 else -1
				if x_keep1 < side:
					var at := r_keep.find(1, x_keep1)
					while at >= 0:
						differs = true
						_drop_sub_cell(ox0 + at, oy0 + old_dy)
						at = r_keep.find(1, at + 1) if at + 1 < side else -1
			var next_rows: Array[PackedByteArray] = []
			next_rows.resize(side)
			for new_dy in side:
				var old_dy := new_dy + sy
				if old_dy < 0 or old_dy >= side:
					var empty := PackedByteArray()
					empty.resize(side)
					next_rows[new_dy] = empty
				elif sx == 0:
					next_rows[new_dy] = _sub_rows[old_dy].duplicate()
				elif sx > 0:
					var shifted := _sub_rows[old_dy].slice(sx, side)
					shifted.resize(side)
					next_rows[new_dy] = shifted
				else:
					var pad := PackedByteArray()
					pad.resize(-sx)
					pad.append_array(_sub_rows[old_dy].slice(0, side + sx))
					next_rows[new_dy] = pad
			_sub_rows = next_rows
			_sub_grid_center = center
			_sub_cursor = 0
			for dict: Dictionary in [_warm, _held]:
				for wc: Vector2i in dict.keys():
					if absi(wc.x - center.x) <= radius and absi(wc.y - center.y) <= radius:
						dict.erase(wc)
						if chunks.has(wc) and not _asked.has(wc):
							_asked[wc] = true
							_sub_rows[wc.y - center.y + radius][wc.x - center.x + radius] = 1
							differs = true
							var kept := _offer(wc)
							if not kept.is_empty():
								have.append(kept)
			if not hold and not _held.is_empty():
				for hc in _held.keys():
					_held.erase(hc)
					if chunks.has(hc) and not _asked.has(hc):
						_leave(hc)
		else:
			var new_rows: Array[PackedByteArray] = []
			new_rows.resize(side)
			for dy in side:
				var row_bytes := PackedByteArray()
				row_bytes.resize(side)
				new_rows[dy] = row_bytes
			_sub_rows = new_rows
			_sub_grid_center = center
			_sub_grid_radius = radius
			_sub_grid_valid = true
			_sub_cursor = 0
			for ac: Vector2i in _asked.keys():
				if absi(ac.x - center.x) > radius or absi(ac.y - center.y) > radius:
					_asked.erase(ac)
					differs = true
			for dict: Dictionary in [_warm, _held]:
				for wc: Vector2i in dict.keys():
					if absi(wc.x - center.x) <= radius and absi(wc.y - center.y) <= radius:
						dict.erase(wc)
						if chunks.has(wc) and not _asked.has(wc):
							_asked[wc] = true
							differs = true
							var kept := _offer(wc)
							if not kept.is_empty():
								have.append(kept)
			for ac: Vector2i in _asked:
				_sub_rows[ac.y - center.y + radius][ac.x - center.x + radius] = 1
			for cc in chunks.keys():
				if _asked.has(cc) or _warm.has(cc):
					continue
				if not _held.has(cc) or not hold:
					_leave(cc)
			for cc in _coming.keys():
				if not _asked.has(cc):
					_coming.erase(cc)
		if _coming.size() < allowed and _asked.size() < _wanted_count:
			var ord := prio_order_lead(radius, sector, _wanted_lead)
			var lim: int = mini(ord.size(), _wanted_count)
			while _sub_cursor < lim and _coming.size() < allowed:
				var c: Vector2i = center + (ord[_sub_cursor] as Vector2i)
				_sub_cursor += 1
				var dx: int = c.x - center.x + radius
				var dy: int = c.y - center.y + radius
				if _sub_rows[dy][dx] != 0:
					continue
				_sub_rows[dy][dx] = 1
				_asked[c] = true
				_coming[c] = true
				differs = true
				if not chunks.has(c):
					_spawn_chunk(c, have)
		if not _held.is_empty():
			_cap_held()
		if not _warm.is_empty():
			_cap_warm()
		var sector_sent := sector if not _shot_built and not _cover_seen.is_valid() else -1
		if differs or sector_sent != _sent_sector or _subscribed_size() != _asked.size():
			_subscribed_arr = []
			_subscribed_lazy = true
			_subscribed_count = _asked.size()
		if refresh or differs or sector_sent != _sent_sector:
			_sub_timer = 0.0
			_sent_sector = sector_sent
			var sub := {
				"t": "sub",
				"o": [_sq_center.x, _sq_center.y],
				"r": _sq_radius,
				"w": square_rows_from_rows(_sq_center, _sq_radius, _sub_rows),
			}
			if sector_sent >= 0:
				var f := sector_vector(sector_sent)
				sub["f"] = [f.x, f.y]
			if not have.is_empty():
				sub["h"] = have
			Bridge.send(sub)
		return

	_sub_grid_valid = false
	var was_asked := _asked
	# One pass in the wanted list's order, so the list comes out nearest first (the mod sends
	# chunks in this order).
	var list: Array = []
	var keep := {}
	var have: Array = []  # chunks offered from the cache
	for c in _wanted:
		if _asked.has(c):
			list.append(c)
			keep[c] = true
		elif (_held.has(c) or _warm.has(c)) and chunks.has(c):
			# Held (hold_chunks) or kept past the square (the area cache, WARM_RINGS) and wanted again:
			# asked for at once, drawn meanwhile, not let go by the held chunks' cap. Offered by the
			# counts its drawn copy matches, it is answered `same` with nothing to rebuild.
			list.append(c)
			keep[c] = true
			var kept := _offer(c)
			if not kept.is_empty():
				have.append(kept)
			if _shot_left.has(c):
				_shot_watch[c] = true
		elif _coming.size() < allowed:
			list.append(c)
			keep[c] = true
			_coming[c] = true
			if _shot_left.has(c):
				_shot_watch[c] = true
			if not chunks.has(c):
				_spawn_chunk(c, have)
	# Chunks no longer wanted leave at once; their records and nodes go over the next frames
	# (_free_unloaded). Held ones (hold_chunks) stay.
	for c in chunks.keys():
		if keep.has(c):
			_held.erase(c)
			_warm.erase(c)
		elif _warm.has(c):
			pass  # kept past the square (_cap_warm lets it go)
		elif not _held.has(c) or not hold:
			_leave(c)
	if not _held.is_empty():
		_cap_held()
	if not _warm.is_empty():
		_cap_warm()
	for c in _coming.keys():
		if not keep.has(c):
			_coming.erase(c)
	_asked = keep
	# A square is sent as rows (no order), so a list only put in another order (the view turned) is
	# the same square; its direction goes with it (`f`), and a new one is sent.
	var differs := list != _subscribed
	if square and differs and list.size() == _subscribed_size():
		differs = false
		for c in list:
			if not was_asked.has(c):
				differs = true
				break
	var sector_sent := sector if square and not _shot_built and not _cover_seen.is_valid() else -1
	if refresh or differs or sector_sent != _sent_sector:
		_sub_timer = 0.0
		_subscribed = list
		_sent_sector = sector_sent
		var sub := {"t": "sub"}
		if square:
			sub["o"] = [_sq_center.x, _sq_center.y]
			sub["r"] = _sq_radius
			sub["w"] = square_rows(_sq_center, _sq_radius, list)
			if sector_sent >= 0:
				var f := sector_vector(sector_sent)
				sub["f"] = [f.x, f.y]
		else:
			var out: Array = []
			for c in list:
				out.append([c.x, c.y])
			sub["c"] = out
		if not have.is_empty():
			sub["h"] = have
		Bridge.send(sub)


## Standing, with more to ask for: whether every chunk asked for is drawn already, so the next
## ones needn't wait for the step. Chunks the client kept (`same`) and empty ones come back within a
## frame or two, and a whole view of them waited 0.15 s for every 32 (2 s back from a factory).
func _all_came() -> bool:
	var moving := Time.get_ticks_msec() - _moved_msec < MOVING_FOR * 1000.0
	var step := STREAM_STEP_QUICK if not stream_window_legacy or not moving else STREAM_STEP * 0.5
	if _stream_timer < step or _subscribed_size() >= _wanted_size():
		return false
	var waiting := 0
	if stream_window_legacy:
		# Moving (I18): the next ones as soon as half of those on their way are drawn.
		for c in _coming:
			if not _drawn(c):
				waiting += 1
				if not moving or waiting * 2 > STREAM_MOVING:
					return false
		return true
	var allowed := _stream_allowance(moving, maxi(_wanted_radius, 1))
	var limit := int(allowed * 0.75) if moving else allowed - 1
	for c in _coming:
		if not _drawn(c):
			waiting += 1
			if waiting > limit:
				return false
	return true


## A ghost's record got or lost `hid` (predicted.gd): drawn so at once.
func hide_record(r: Rec) -> void:
	ghost_hidden.emit(r.chunk)


## Builds a chunk's entities again (a change in what it holds: its records, a record's look).
func redraw(c: Vector2i) -> void:
	if chunks.has(c):
		_dirty[c] = true


## Builds a chunk's entities again for its view alone (far_chunks.gd, when it swaps between merged and
## full; belt_lods.gd, stand-ins ready): nothing it holds changed, so the build may use the lists its
## last build kept (chunk_view.gd collect_entities `reuse`, --collect-cache). `_dirty` holds false for
## such a chunk, true (any other site) for a change in its records; a change wins over a view.
func redraw_view(c: Vector2i) -> void:
	if chunks.has(c) and not _dirty.has(c):
		_dirty[c] = false


## Whether the build of `c` about to start is for its view alone (redraw_view), else counted as a
## change in what it holds (ChunkView.draw_rev: the far gather and later builds stop using older lists).
func _build_for_view(c: Vector2i, cv: ChunkView) -> bool:
	if _dirty.get(c, true) == false and not _dirty_live.has(c):
		return true
	cv.draw_rev += 1
	return false


## M8: a building drawn with `pack`'s model ("" the usual; building_models.gd keeps it for this save),
## at once: its record takes the pack (a new `extra`, as belt_paths.gd may be reading the old one on a
## worker) and its chunk is built again, which puts it in that model's MultiMesh.
func set_building_pack(unit: int, pack: String) -> void:
	BuildingModels.choose(Bridge.save_id, unit, pack)
	var r: Rec = entities.get(unit)
	if r == null:
		return
	var x: Dictionary = r.extra.duplicate()
	if pack == "":
		x.erase(ModelLibrary.PACK_KEY)
	else:
		x[ModelLibrary.PACK_KEY] = pack
	r.extra = x
	record_edited(r)


## A record changed in place (its direction or extra edited here, not a new record from the game: a turn, a pack
## choice, a turn put back): drawn again, and its chunk's content counted as changed (content_rev: Alt-mode's quiet
## builds and caches look at it; the pick grid made again).
func record_edited(r: Rec) -> void:
	r.cache_gen = -1
	var cv: ChunkView = chunks.get(r.chunk)
	if cv != null:
		cv.content_rev += 1
		cv.pick_grid = []
	_dirty[r.chunk] = true


## M7: the packs' choices for model families changed (the Model packs window, the model chooser's
## "every one"; ModelPacks.set_choices done): those families' models are made again
## (ModelLibrary.choices_changed) and the chunks drawing any of them built again; `families` empty:
## every chunk.
func models_changed(families: Array) -> void:
	ModelLibrary.choices_changed(families)
	var wanted := {}
	for f in families:
		wanted[str(f)] = true
	for c in chunks:
		if families.is_empty() or _draws_family(chunks[c], wanted):
			_dirty[c] = true
	if not silo_positions.is_empty() and (families.is_empty() or wanted.has("rocket-silo")):
		for pos: Vector2 in silo_positions.values():
			_dirty_silo_terrain(pos)


## The cliff wall turned on or off (cliff_wall.gd set_on): the chunks with cliffs built again.
func cliff_wall_changed() -> void:
	for c in chunks:
		if (chunks[c] as ChunkView).cliff_count > 0:
			_dirty[c] = true


## Whether a chunk draws a model of one of these families: its buildings' own, their tier's base, an
## alias's, a belt's end pieces, a cargo bay's edges.
func _draws_family(cv: ChunkView, wanted: Dictionary) -> bool:
	for r: Rec in cv.entities.values():
		var proto: ProtoDB.EntityProto = protos.entity(r.proto_id)
		if proto == null:
			continue
		var names: Array = [proto.name, ModelLibrary._tier_base(proto.name), str(ModelLibrary.MODEL_ALIASES.get(proto.name, ""))]
		if r.belt_ends != 0:
			names.append(ModelLibrary.belt_end_family(proto.name, proto.type))
		if ModelLibrary.CARGO_TYPES.has(proto.type):
			names.append("cargo-bay")
		for n: String in names:
			if n != "" and wanted.has(ModelLibrary.ModelPacks.family(n)):
				return true
	return false


## Whether a chunk asked for has arrived and is drawn (its ground, and its buildings built). Tiles
## that aren't a whole chunk get no ground (_start_terrain_jobs): such a chunk is drawn without it,
## or it would hold its place on the way (_coming) and a screenshot's count for good.
func _drawn(c: Vector2i) -> bool:
	var cv: ChunkView = chunks.get(c)
	if cv == null or not cv.loaded or (not cv.has_ground() and cv.tile_ids.size() == CHUNK * CHUNK):
		return false
	if _dirty.has(c) or _pending.has(c) or _partial.has(c) or _prep_jobs.has(c) or _staged_snap.has(c):
		return false
	if cv.far.far and not cv.far.full and not cv.far.covers and not cv.entities.is_empty():
		return cv.tiles_msec > 0 and Time.get_ticks_msec() - cv.tiles_msec >= REVEAL_HOLD_MSEC
	return true


## Last reported chunk revision (`_live[c][1]`), or 0 if not tracked.
func chunk_rev(c: Vector2i) -> int:
	var info: Variant = _live.get(c)
	if info is Array and (info as Array).size() >= 2:
		return int((info as Array)[1])
	return 0


func _unload(c: Vector2i) -> void:
	var cv: ChunkView = chunks[c]
	ChunkView.count("unload")
	far_chunks.note_unloaded(cv)
	chunk_unloaded.emit(c)
	var hold_for_dh := dh_handoff and cv.visible and cv.revealed and cv.has_ground() \
		and cv.tile_ids.size() == CHUNK * CHUNK and dh_handoff_ready.is_valid() \
		and not _shot_built and not bool(dh_handoff_ready.call(c))
	if not _shadow_uncounted.erase(c) and cv.shadow_tier != ChunkView.SHADOWS_NONE:
		shadow_casters = maxi(shadow_casters - 1, 0)
	_shadow_queued.erase(c)
	_row_remove(c)
	chunks.erase(c)
	_live.erase(c)
	_warm.erase(c)
	behind_cull.removed(c)
	_dirty.erase(c)
	_dirty_live.erase(c)
	_live_prep.erase(c)
	_live_built_msec.erase(c)
	_pending.erase(c)
	_partial.erase(c)
	_abandon_prep(c)
	_dirty_terrain.erase(c)
	_waiting_gfx.erase(c)
	_held_reveal.erase(c)
	_staged_snap.erase(c)
	_optimistic_rv.erase(c)
	_optimistic_pending.erase(c)
	_disk_waiting.erase(c)
	# Its records leave `entities`, entities_changed goes out and it is freed within a time budget
	# (_free_unloaded): walking over a chunk's edge lets a whole row of 29 go at once, and a busy
	# chunk's thousands of records and 60-150 nodes took 1.5-5 ms each. It is hidden first, before
	# any of that (unload_hide).
	_unload_keys[cv] = [cv.entities.keys(), 0]
	cv.retire()
	if hold_for_dh:
		_dh_unloading[cv] = [c, Time.get_ticks_msec()]
		var arr: Array = _dh_unloading_by_coord.get(c, [])
		arr.append(cv)
		_dh_unloading_by_coord[c] = arr
		while _dh_unloading.size() > MAX_DH_UNLOAD_HOLD:
			var oldest_cv: Variant = _dh_unloading.keys()[0]
			_release_dh_unloading_entry(oldest_cv, false)
	else:
		_unloaded.append(cv)
		if unload_hide and cv.visible:
			_hide_queue.append(cv)
			_hide_sorted = false


## Unloaded chunks waiting for their records to leave `entities`: ChunkView -> [keys, next].
var _unload_keys := {}
## L14: a screenshot zoomed far out lets go of thousands of chunks at once (4,353 of the mock's 4,708
## in a 250-tile-high shot), and each stayed drawn until its records had left `entities`, at the
## unload slice's 2-3 chunks a frame: 30-40 s of the renderer drawing thousands of chunks at full
## detail (far merging is off for a shot) behind a view that no longer wants them ("easier to just
## reload the save"). Now an unloaded chunk is hidden first, farthest from the focus first, as many a
## frame as the unload slice holds (a hidden chunk costs the renderer nothing), and its records and
## nodes go after, as before. `--unload-hide=off`: drawn until its records have gone, as before.
static var unload_hide := Switches.on("--unload-hide")
var _hide_queue: Array = []  # unloaded ChunkViews still drawn, hidden from _hide_at on
const UNLOAD_HIDE_USEC := 3000
var _hide_at := 0
var _hide_sorted := true  # _hide_queue from _hide_at is farthest from the focus first


## Hides unloaded chunks still drawn, from _hide_at, for `allow` µs from `t0` (at least one): farthest
## from the focus first (sorted once a batch has come: natively, by squared distance). How many it hid.
func _hide_unloaded(t0: int, allow: int) -> int:
	if not _hide_sorted:
		_hide_sorted = true
		var rest := _hide_queue.slice(_hide_at)
		var center := stream_center()
		var keys := PackedInt64Array()
		keys.resize(rest.size())
		for i in rest.size():
			var d := 0
			if is_instance_valid(rest[i]):
				d = ((rest[i] as ChunkView).coord - center).length_squared()
			keys[i] = (d << 20) + i
		keys.sort()
		_hide_queue = []
		for j in range(keys.size() - 1, -1, -1):
			_hide_queue.append(rest[keys[j] & 0xfffff])
		_hide_at = 0
	var hidden := 0
	while _hide_at < _hide_queue.size():
		if hidden > 0 and Time.get_ticks_usec() - t0 > allow:
			break
		var cv = _hide_queue[_hide_at]
		_hide_at += 1
		if is_instance_valid(cv) and (cv as ChunkView).visible:
			(cv as ChunkView).visible = false
			hidden += 1
	if _hide_at >= _hide_queue.size():
		_hide_queue = []
		_hide_at = 0
	return hidden


## Unloaded chunks still drawn (for --stutter-probe and the UI test).
func unloaded_drawn() -> int:
	var n := 0
	for cv in _unloaded:
		if is_instance_valid(cv) and (cv as ChunkView).visible:
			n += 1
	for cv_v: Variant in _dh_unloading:
		if cv_v is Object and is_instance_valid(cv_v) and (cv_v as ChunkView).visible:
			n += 1
	return n


func _release_dh_unloading_entry(cv_v: Variant, hide_now := false) -> void:
	if not _dh_unloading.has(cv_v):
		return
	var info: Array = _dh_unloading[cv_v]
	var c: Vector2i = info[0]
	_dh_unloading.erase(cv_v)
	if _dh_unloading_by_coord.has(c):
		var list: Array = _dh_unloading_by_coord[c]
		list.erase(cv_v)
		if list.is_empty():
			_dh_unloading_by_coord.erase(c)
	if not (cv_v is Object) or not is_instance_valid(cv_v):
		_unload_keys.erase(cv_v)
		return
	var cv := cv_v as ChunkView
	if hide_now and cv.visible:
		cv.visible = false
	_unloaded.append(cv)
	if not hide_now and unload_hide and cv.visible:
		_hide_queue.append(cv)
		_hide_sorted = false


func _release_dh_unloading_at(c: Vector2i) -> void:
	if not _dh_unloading_by_coord.has(c):
		return
	var list: Array = (_dh_unloading_by_coord[c] as Array).duplicate()
	for cv_v: Variant in list:
		_release_dh_unloading_entry(cv_v, true)


func _poll_dh_unloading() -> void:
	if _dh_unloading.is_empty():
		return
	var now := Time.get_ticks_msec()
	var ready_valid := dh_handoff_ready.is_valid()
	for cv_v: Variant in _dh_unloading.keys():
		if not (cv_v is Object) or not is_instance_valid(cv_v):
			_release_dh_unloading_entry(cv_v, false)
			continue
		var cv := cv_v as ChunkView
		var info: Array = _dh_unloading[cv]
		var c: Vector2i = info[0]
		var start_msec := int(info[1])
		var rep: ChunkView = chunks.get(c)
		var rep_ready := rep != null and rep.revealed and rep.visible
		var dh_ready := (not dh_handoff) or (not ready_valid) or bool(dh_handoff_ready.call(c))
		var timed_out := now - start_msec >= DH_UNLOAD_HOLD_MSEC
		if not cv.visible or rep_ready or dh_ready or timed_out:
			_release_dh_unloading_entry(cv, rep_ready)


## Takes unloaded chunks apart within their slice of the frame (frame_budget.gd `unload`, at least
## one step): their records out of
## `entities` (only those still theirs: the chunk may have come back meanwhile), entities_changed,
## then their nodes one by one (a busy chunk's took up to 5 ms freed at once), then the chunk.
func _free_unloaded() -> void:
	_poll_dh_unloading()
	if _unloaded.is_empty():
		if not _hide_queue.is_empty():
			_hide_queue = []
			_hide_at = 0
		FrameBudget.waiting(&"unload", 0)
		return
	var t0 := Time.get_ticks_usec()
	var steps := 0
	var allow := FrameBudget.grant(&"unload")
	# (BehindCull.unload_fast) Hiding is cheap and what is still drawn costs every frame: at least
	# UNLOAD_HIDE_USEC a frame for it, whatever the pool has left.
	var hide_allow := maxi(allow, UNLOAD_HIDE_USEC) if BehindCull.unload_fast else allow
	if hide_allow > 0 and _hide_at < _hide_queue.size():
		# Hidden first, all of them before any record goes (unload_hide).
		steps += _hide_unloaded(t0, hide_allow)
	while allow > 0 and not _unloaded.is_empty():
		if steps > 0 and Time.get_ticks_usec() - t0 > allow:
			break
		var cv: ChunkView = _unloaded[0]
		if not is_instance_valid(cv):
			_unloaded.pop_front()
			_unload_keys.erase(cv)
			continue
		var job: Array = _unload_keys.get(cv, [])
		if not job.is_empty():
			var keys: Array = job[0]
			var i := int(job[1])
			while i < keys.size():
				var key = keys[i]
				var gone: Rec = cv.entities.get(key)
				if gone != null and entities.get(key) == gone:
					entities.erase(key)
					_left_with_chunk(key, gone)
				i += 1
				steps += 1
				if (i & 63) == 0 and Time.get_ticks_usec() - t0 > allow:
					break
			if i < keys.size():
				job[1] = i
				break
			_unload_keys.erase(cv)
			entities_changed.emit(cv.coord)
			steps += 1
			continue
		if cv.visible:
			cv.visible = false
		var n := cv.get_child_count()
		if n > 0:
			cv.get_child(n - 1).free()
		else:
			_unloaded.pop_front()
			cv.free()
		steps += 1
	_prof("unload_free", t0)
	FrameBudget.spent(&"unload", Time.get_ticks_usec() - t0, _unloaded.size())


## How much streaming work waits (for --stutter-probe): chunks part-way through a build, chunks
## whose shadow settings are still to be set, unloaded chunks' records still to go.
## The subscription as last sent (the debug menu's update overlays): the square's middle chunk and reach, its
## chunks in the order asked for (the view's direction first), those on their way (asked, not drawn yet), and
## the view's direction the `sub` carried (`f`; zero for none). Read only.
func subscription() -> Dictionary:
	return {"center": _sq_center, "radius": _sq_radius, "list": _subscribed, "coming": _coming,
		"f": sector_vector(_sent_sector) if _sent_sector >= 0 else Vector2i.ZERO}


func stream_queues() -> Dictionary:
	var records := 0
	for job: Array in _unload_keys.values():
		records += (job[0] as Array).size() - int(job[1])
	return {"partial": _partial.size(), "shadow": maxi(_shadow_todo.size() - _shadow_next, 0), "free_records": records}


## How far from the camera the mod streams moving things and machine states (the "Entity distance"
## setting); a change goes out at once.
func set_focus_radius(r: int) -> void:
	if r != focus_radius:
		focus_radius = r
		_last_focus_sent = Vector2(INF, INF)


## The 3D remote view is on: the mod then sends moving things only where radars see (focus `rv`).
func set_remote_view(on: bool) -> void:
	if on != remote_view:
		remote_view = on
		_last_focus_sent = Vector2(INF, INF)
		_focus_timer = FOCUS_INTERVAL


func _update_focus(delta: float) -> void:
	_focus_timer += delta
	if _focus_timer < FOCUS_INTERVAL:
		return
	var waited := _focus_timer
	_focus_timer = 0.0
	# (The live inserter radius goes with the focus, which is otherwise sent only when it moves a tile:
	# a zoom changing its step sends it too, at most every FOCUS_INTERVAL; a smaller one after 1 s.)
	var settled := ViewPriority.live_ir_settle(live_ir_sent, live_ir_now(), _live_ir_low_for, waited)
	var ir := int(settled[0])
	_live_ir_low_for = float(settled[1])
	if _focus.distance_to(_last_focus_sent) < 1.0 and ir == live_ir_sent:
		return
	_last_focus_sent = _focus
	live_ir_sent = ir
	var msg := {"t": "focus", "x": int(_focus.x * 256.0), "y": int(_focus.y * 256.0), "r": focus_radius}
	if remote_view:
		msg["rv"] = 1
	if ir >= 0:
		msg["ir"] = ir
	Bridge.send(msg)


## The focus's `ir` now (--live-inserter-radius): -1 (none sent: the bridge's 64) while `view` has no camera.
func live_ir_now() -> int:
	if live_inserter_mode == "64":
		return 64
	if live_inserter_mode == "detail":
		return 0
	var cam: Camera3D = get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return -1
	return ViewPriority.live_ir(cam, _focus)


func _chunk_visually_ready(c: Vector2i, cv: ChunkView) -> bool:
	if cv == null or not cv.loaded:
		return false
	if not cv.has_ground() and cv.tile_ids.size() == CHUNK * CHUNK:
		return false
	if cv.building or cv.waiting_models or cv.is_incomplete() or _dirty.has(c) or _partial.has(c) or _pending.has(c) or _prep_jobs.has(c) or _staged_snap.has(c):
		return false
	if cv.far.far and not cv.far.full and not cv.far.covers and not cv.entities.is_empty():
		return false
	return true


func chunk_is_visually_ready(c: Vector2i) -> bool:
	return _chunk_visually_ready(c, chunks.get(c))


func chunk_is_drawn_visible(c: Vector2i) -> bool:
	var cv: ChunkView = chunks.get(c)
	return cv != null and cv.revealed and cv.visible and cv.has_ground() and cv.tile_ids.size() == CHUNK * CHUNK


func _reveal_timeout_msec(c: Vector2i) -> int:
	if dh_handoff and dh_covers_chunk.is_valid() and bool(dh_covers_chunk.call(c)):
		return REVEAL_HOLD_DH_MSEC
	return REVEAL_HOLD_MSEC


func _reveal_chunk(c: Vector2i, cv: ChunkView) -> void:
	if cv == null or not is_instance_valid(cv):
		_held_reveal.erase(c)
		return
	_release_dh_unloading_at(c)
	var first_reveal := not cv.revealed
	cv.revealed = true
	cv.set_terrain_held(false)
	_held_reveal.erase(c)
	if first_reveal:
		chunk_ready.emit(c)
		if cv.has_ground() and cv.tile_ids.size() == CHUNK * CHUNK:
			chunk_drawn.emit(c)


func _maybe_reveal(c: Vector2i, cv: ChunkView) -> void:
	if cv == null or not is_instance_valid(cv):
		_held_reveal.erase(c)
		return
	var timed_out := cv.tiles_msec > 0 and Time.get_ticks_msec() - cv.tiles_msec >= _reveal_timeout_msec(c)
	if _chunk_visually_ready(c, cv) or not atomic_reveal or timed_out:
		if cv.has_ground() or cv.tile_ids.size() != CHUNK * CHUNK:
			_reveal_chunk(c, cv)


func _on_terrain_applied(c: Vector2i, cv: ChunkView) -> void:
	if cv == null:
		return
	var now := Time.get_ticks_msec()
	var timed_out := cv.tiles_msec > 0 and now - cv.tiles_msec >= _reveal_timeout_msec(c)
	if atomic_reveal and not cv.revealed and cv.parts_expected > 0 and not _chunk_visually_ready(c, cv) and not timed_out:
		cv.set_terrain_held(true)
		_held_reveal[c] = true
		return
	var was_revealed := cv.revealed
	_reveal_chunk(c, cv)
	if was_revealed and cv.has_ground() and cv.tile_ids.size() == CHUNK * CHUNK:
		chunk_drawn.emit(c)


func on_far_covered(c: Vector2i) -> void:
	var cv: ChunkView = chunks.get(c)
	if cv != null:
		_maybe_reveal(c, cv)


func _mark_dirty(c: Vector2i) -> void:
	_dirty[c] = true
	if _marking_live and fast_edit_rebuild and not _replaying:
		_dirty_live[c] = true


## The build queues (_rebuild_dirty's pending, part-way, live and dirty chunks, _finish_prep_jobs' finished ones) and
## the terrain jobs' are put in order with one packed key a chunk, (live ? 0 : 1) << 62 | rank << 20 | index, sorted
## natively (PackedInt64Array.sort, as _hide_unloaded): `nearer` (sort_custom) worked out _build_rank twice a comparison
## (n log n times), 1-2 ms a frame with hundreds of chunks waiting. Dirty chunks that can't be built yet (one building,
## a prep job queued, its snapshot still coming) are left out before ranking. --queue-order=old: sort_custom as before.
static var queue_order_old := Switches.has("--queue-order=old")


## `cs` (Vector2i chunks) nearest first as `nearer` puts them: live edits first, then by _build_rank, ties by place.
func _rank_order(cs: Array, center: Vector2i) -> Array:
	var keys := PackedInt64Array()
	keys.resize(cs.size())
	var live_on := fast_edit_rebuild and not (_dirty_live.is_empty() and _live_prep.is_empty())
	for i in cs.size():
		var c: Vector2i = cs[i]
		var live := live_on and (_dirty_live.has(c) or _live_prep.has(c))
		keys[i] = ((0 if live else 1) << 62) | (_build_rank(c, center) << 20) | i
	keys.sort()
	var out: Array = []
	out.resize(cs.size())
	for i in keys.size():
		out[i] = cs[keys[i] & 0xfffff]
	return out


## The dirty chunks the waiting loop of _rebuild_dirty may build now: those it would pass over (staying dirty) left
## out, so they aren't ranked; a chunk gone stays in (the loop forgets it).
func _buildable_dirty(now: int) -> Array:
	var out: Array = []
	var coalesce := fast_edit_coalesce and fast_edit_rebuild and not _dirty_live.is_empty()
	for c: Vector2i in _dirty:
		if coalesce and _dirty_live.has(c) and now - int(_live_built_msec.get(c, -1000000)) < LIVE_COALESCE_MSEC:
			continue
		var cv: ChunkView = chunks.get(c)
		if cv != null:
			if cv.building or _prep_jobs.has(c):
				continue
			if whole_snapshots and cv.is_incomplete() and now - cv.snapshot_msec < PARTS_WAIT_MSEC:
				continue
			if ents_slice and not _hyd.is_empty() and _hyd["c"] == c and is_same(_hyd["cv"], cv):
				continue
		out.append(c)
	return out


## Put `cs` in build order: _rank_order, or --queue-order=old's sort_custom(nearer).
func _build_order(cs: Array, center: Vector2i, nearer: Callable) -> Array:
	if queue_order_old:
		cs.sort_custom(nearer)
		return cs
	return _rank_order(cs, center)


func _rebuild_dirty() -> void:
	if not _staged_snap.is_empty():
		var now_s := Time.get_ticks_msec()
		for sc: Vector2i in _staged_snap.keys():
			var st: Variant = _staged_snap.get(sc)
			if st is Dictionary and now_s - int((st as Dictionary).get("msec", 0)) >= PARTS_WAIT_MSEC:
				_commit_staged(sc)
	if _batch_joins or not _join_walls.is_empty() or not _join_belts.is_empty() or not _join_pipes.is_empty() or not _join_cargo_rects.is_empty():
		_flush_joins()
	if not _abandoned_prep_tasks.is_empty():
		_reap_abandoned_prep()
	var tp := Time.get_ticks_usec()
	if protos.refresh_water():
		_terrain_cache.clear()  # what is water changed: banks and shores with it
		for c in chunks:
			_dirty_terrain[c] = true  # a mod's water, known from the graphics list that came after
	var polled := TerrainTextures.poll()
	var layout_changed := TerrainTextures.relook or _terrain_layout != TerrainTextures.layout
	if polled or layout_changed:
		if layout_changed:
			for entry: Array in _terrain_jobs.values():
				WorkerThreadPool.wait_for_task_completion(int(entry[0]))
			_terrain_jobs.clear()
			TerrainTextures.relook = false
			_terrain_layout = TerrainTextures.layout
			_terrain_cache.clear()
			var seen_ids := {}
			for c in chunks:
				var cv: ChunkView = chunks[c]
				cv.slots = PackedInt32Array()
				_dirty_terrain[c] = true
				for tid in cv.tile_ids:
					if not seen_ids.has(tid):
						seen_ids[tid] = true
						if tid >= 0 and tid < protos.tile_names.size() and not protos.is_void(tid):
							TerrainTextures.lookup(protos.tile_names[tid])
		_refresh_gfx_table()
		# Chunks drawn without a picture that is ready now are built again with it.
		for c in _waiting_gfx.keys():
			for id in _waiting_gfx[c]:
				if id < _gfx_table.size() and _gfx_table[id] != null:
					_dirty_terrain[c] = true
					_waiting_gfx.erase(c)
					break
	_prof("terrain_poll", tp)
	tp = Time.get_ticks_usec()
	_finish_terrain_jobs()
	_prof("terrain_finish", tp)
	tp = Time.get_ticks_usec()
	_start_terrain_jobs()
	_prof("terrain_start", tp)
	if not _held_reveal.is_empty():
		for hc: Vector2i in _held_reveal.keys():
			var hcv: ChunkView = chunks.get(hc)
			if hcv == null:
				_held_reveal.erase(hc)
			else:
				_maybe_reveal(hc, hcv)
	# One budget object, filled again each frame: a build part-way through holds on to it.
	var surfaces := _surfaces
	# A screenshot settling lets the frame run longer (frame_budget.gd boost): more built a frame.
	var boost := FrameBudget.BOOST if FrameBudget.boost else 1
	surfaces.left = NEW_SURFACES * boost
	var build_t0 := Time.get_ticks_usec()
	if _dirty.is_empty() and _partial.is_empty() and _pending.is_empty() and _prep_jobs.is_empty():
		FrameBudget.waiting(&"build", 0)
		return
	var granted := FrameBudget.grant(&"build")
	if FrameBudget.shared and granted <= 0:
		FrameBudget.spent(&"build", 0, _dirty.size() + _partial.size() + _pending.size() + _prep_jobs.size())
		return
	# Made only when there is something to build (it was made every frame).
	var center := stream_center()
	# Nearest first, live edits before background streaming, then focus direction, hidden ones last (I18).
	var nearer := func(a: Vector2i, b: Vector2i) -> bool:
		var a_live := fast_edit_rebuild and (_dirty_live.has(a) or _live_prep.has(a))
		var b_live := fast_edit_rebuild and (_dirty_live.has(b) or _live_prep.has(b))
		if a_live != b_live:
			return a_live
		return _build_rank(a, center) < _build_rank(b, center)
	# Chunks already built go on adding what they left for later first, nearest first.
	if not _pending.is_empty():
		tp = Time.get_ticks_usec()
		var p_allow: int
		if FrameBudget.shared:
			p_allow = granted - (tp - build_t0)
		else:
			p_allow = clampi(FRAME_WORK_USEC - Bridge.frame_handle_usec, int(FrameBudget.SYSTEMS[&"build"][2]), granted)
		var pending_until := tp + p_allow if p_allow > 0 else tp
		var order: Array = _build_order(_pending.keys(), center, nearer)
		var did_pending := false
		for c: Vector2i in order:
			if surfaces.left <= 0:
				break
			if did_pending and pending_until > 0 and Time.get_ticks_usec() > pending_until:
				break
			var pcv: ChunkView = chunks.get(c)
			if pcv != null and (pcv.building or _prep_jobs.has(c)):
				continue
			if pcv != null:
				_lod_soon(c)  # its new MultiMeshes start at the model itself
			did_pending = true
			if pcv == null or pcv.add_pending(working, animator, surfaces, pending_until):
				_pending.erase(c)
				_live_prep.erase(c)
				if pcv != null:
					_maybe_reveal(c, pcv)
		_prof("pending", tp)
	# The time for builds starts after the MultiMeshes left for later were added (as before).
	var started := Time.get_ticks_usec()
	var allowed: int
	# With the frame's work shared (frame_budget.gd) the builds take what the scheduler gives them,
	# and nothing at all when it gives nothing.
	if FrameBudget.shared:
		allowed = granted - (started - build_t0)
		if allowed <= 0:
			FrameBudget.spent(&"build", Time.get_ticks_usec() - build_t0, _dirty.size() + _partial.size() + _pending.size() + _prep_jobs.size())
			return
	else:
		# The old slice (`granted` is the build's own): what message handling left of FRAME_WORK_USEC.
		# Builds stop part-way at the deadline instead of finishing a busy chunk whatever it costs
		# (10-24 ms), so when chunks queue up they get the whole slice: as many built as before, in
		# frames of a bounded length.
		allowed = clampi(FRAME_WORK_USEC - Bridge.frame_handle_usec, int(FrameBudget.SYSTEMS[&"build"][2]), granted)
		if _dirty.size() + _partial.size() + _prep_jobs.size() > REBUILDS_PER_FRAME * boost:
			allowed = granted
	var until := started + allowed
	if not _prep_jobs.is_empty():
		_finish_prep_jobs(surfaces, until, nearer, center)
	var most := REBUILDS_PER_FRAME * boost
	var budget := most
	# Builds part-way through carry on first, nearest first.
	if not _partial.is_empty():
		var order: Array = _build_order(_partial.keys(), center, nearer)
		for c: Vector2i in order:
			if budget < most and Time.get_ticks_usec() > until:
				break
			var bcv: ChunkView = chunks.get(c)
			if bcv == null or not bcv.building:
				_partial.erase(c)
				_live_prep.erase(c)
				continue
			var phase := str(_partial[c])
			var tb := Time.get_ticks_usec()
			bcv.resume_build(until)
			budget -= 1
			if bcv.building:
				_prof("build", tb)
			else:
				_partial.erase(c)
				if phase == "collect":
					_dispatch_or_finish_prep(c, bcv, surfaces, until, tb)
				else:
					_built(c, bcv, tb)
	var now := Time.get_ticks_msec()
	var rebuilt_live := false
	if fast_edit_rebuild and not _dirty_live.is_empty():
		var live_order: Array = _dirty_live.keys()
		if live_order.size() > 1:
			live_order = _build_order(live_order, center, nearer)
		for c: Vector2i in live_order:
			if surfaces.left <= 0:
				break
			if rebuilt_live and (budget <= 0 or Time.get_ticks_usec() > until):
				break
			var cv: ChunkView = chunks.get(c)
			if cv != null:
				if cv.building or _prep_jobs.has(c):
					continue
				if whole_snapshots and cv.is_incomplete() and now - cv.snapshot_msec < PARTS_WAIT_MSEC:
					continue
				if fast_edit_coalesce and now - int(_live_built_msec.get(c, -1000000)) < LIVE_COALESCE_MSEC:
					continue
				if ents_slice and not _hyd.is_empty() and _hyd["c"] == c and is_same(_hyd["cv"], cv):
					continue  # being replayed from the cache in slices: built once its replay is done (as below)
				_live_prep[c] = true
				var t0 := Time.get_ticks_usec()
				var chunk_until := until if Time.get_ticks_usec() <= until else t0 + 2000
				cv.collect_entities(protos, working, chunk_until, _build_for_view(c, cv))
				ChunkView.count("rebuilds")
				budget -= 1
				rebuilt_live = true
				if cv.building:
					_partial[c] = "collect"
					_pending.erase(c)
					_prof("build", t0)
				else:
					_dispatch_or_finish_prep(c, cv, surfaces, chunk_until, t0)
			_dirty_live.erase(c)
			_dirty.erase(c)
	var waiting: Array = _dirty.keys() if queue_order_old else _buildable_dirty(now)
	if _dirty.size() > budget:
		# Nearest the focus first, so after a jump the buildings round the character come first.
		waiting = _build_order(waiting, center, nearer)
	for c in waiting:
		if budget <= 0 or (budget < most and Time.get_ticks_usec() > until):
			break
		# Building more now would only queue more for the renderer: wait for the next frame.
		if surfaces.left <= 0:
			break
		if fast_edit_coalesce and fast_edit_rebuild and _dirty_live.has(c) and now - int(_live_built_msec.get(c, -1000000)) < LIVE_COALESCE_MSEC:
			continue
		var cv: ChunkView = chunks.get(c)
		if cv != null:
			if cv.building or _prep_jobs.has(c):
				continue  # built again once the build part-way through or queued prep is done (it stays dirty)
			if whole_snapshots and cv.is_incomplete() and now - cv.snapshot_msec < PARTS_WAIT_MSEC:
				continue  # more of its snapshot to come: built once, with the last part (it stays dirty)
			if ents_slice and not _hyd.is_empty() and _hyd["c"] == c and is_same(_hyd["cv"], cv):
				continue  # replayed from the cache a slice at a time: built once its replay is done (it stays dirty)
			var t0 := Time.get_ticks_usec()
			# Stops part-way at the frame's deadline and carries on next frame (_partial).
			cv.collect_entities(protos, working, until, _build_for_view(c, cv))
			ChunkView.count("rebuilds")
			budget -= 1
			if cv.building:
				_partial[c] = "collect"
				_pending.erase(c)
				_prof("build", t0)
			else:
				_dispatch_or_finish_prep(c, cv, surfaces, until, t0)
		_dirty.erase(c)
	FrameBudget.spent(&"build", Time.get_ticks_usec() - build_t0, _dirty.size() + _partial.size() + _pending.size() + _prep_jobs.size())


var _surfaces := ChunkView.Budget.new(NEW_SURFACES)
var _partial := {}  # Vector2i -> String ("collect" / "apply"): chunks whose build stopped part-way
var _prep_jobs := {}  # Vector2i -> ChunkView.ChunkPrepJob
var _abandoned_prep_tasks: Array[int] = []


func _abandon_prep(c: Vector2i) -> void:
	var job: ChunkView.ChunkPrepJob = _prep_jobs.get(c)
	if job == null:
		return
	if job.task_id >= 0:
		_abandoned_prep_tasks.append(job.task_id)
	_prep_jobs.erase(c)


## Cancels an in-flight worker ChunkPrepJob for `c` if it was built merged (`job.merged`), so a
## chunk coming near again never applies a stale far-only build over its restored MultiMeshes.
func cancel_merged_prep(c: Vector2i) -> bool:
	var job: ChunkView.ChunkPrepJob = _prep_jobs.get(c)
	if job == null or not job.merged:
		return false
	var cv: ChunkView = chunks.get(c)
	if cv != null:
		cv.build_serial += 1
	_abandon_prep(c)
	return true


func _reap_abandoned_prep() -> void:
	var kept: Array[int] = []
	for tid: int in _abandoned_prep_tasks:
		if WorkerThreadPool.is_task_completed(tid):
			WorkerThreadPool.wait_for_task_completion(tid)
		else:
			kept.append(tid)
	_abandoned_prep_tasks = kept


func flush_prep_jobs() -> void:
	for tid: int in _abandoned_prep_tasks:
		WorkerThreadPool.wait_for_task_completion(tid)
	_abandoned_prep_tasks.clear()
	for c in _prep_jobs.keys():
		var job: ChunkView.ChunkPrepJob = _prep_jobs[c]
		if job != null and job.task_id >= 0:
			WorkerThreadPool.wait_for_task_completion(job.task_id)
			job.task_id = -1
	_prep_jobs.clear()


func _dispatch_or_finish_prep(c: Vector2i, cv: ChunkView, surfaces: ChunkView.Budget, until: int, t0: int) -> void:
	var job: ChunkView.ChunkPrepJob = cv._prep_pending
	cv._prep_pending = null
	if job == null or cv.retired or job.serial != cv.build_serial:
		_live_prep.erase(c)
		_prof("build", t0)
		return
	var skip_worker := fast_edit_rebuild and _live_prep.has(c) and job.total_instances < 512
	if not skip_worker and ChunkView.chunk_mm_worker and job.total_instances >= ChunkView.WORKER_MIN_INSTANCES and _prep_jobs.size() < ChunkView.prep_job_limit():
		var run_job := func() -> void:
			job.run()
		job.task_id = WorkerThreadPool.add_task(run_job, false, "chunk_prep")
		_prep_jobs[c] = job
		_pending.erase(c)
		_prof("build", t0)
		return
	job.run()
	cv.apply_prepared(job, working, animator, surfaces, until)
	if cv.building:
		_partial[c] = "apply"
		_pending.erase(c)
		_prof("build", t0)
	else:
		_built(c, cv, t0)


func _finish_prep_jobs(surfaces: ChunkView.Budget, until: int, nearer: Callable, center: Vector2i) -> void:
	var finished: Array = []
	for c in _prep_jobs:
		var job: ChunkView.ChunkPrepJob = _prep_jobs[c]
		if job == null or job.task_id < 0 or WorkerThreadPool.is_task_completed(job.task_id):
			finished.append(c)
	if finished.is_empty():
		return
	if finished.size() > 1:
		finished = _build_order(finished, center, nearer)
	var applied_any := false
	for c in finished:
		if surfaces.left <= 0 or (applied_any and Time.get_ticks_usec() > until):
			break
		var job: ChunkView.ChunkPrepJob = _prep_jobs.get(c)
		if job != null and job.task_id >= 0:
			WorkerThreadPool.wait_for_task_completion(job.task_id)
			job.task_id = -1
		_prep_jobs.erase(c)
		var cv: ChunkView = chunks.get(c)
		if job == null or cv == null or cv.retired or job.serial != cv.build_serial:
			_live_prep.erase(c)
			continue
		var t0 := Time.get_ticks_usec()
		cv.apply_prepared(job, working, animator, surfaces, until)
		applied_any = true
		if cv.building:
			_partial[c] = "apply"
			_pending.erase(c)
			_prof("build", t0)
		else:
			_built(c, cv, t0)
## A chunk's snapshot comes as its `chunk` and then `ents` parts of 120 records (world.lua
## ENTITIES_PER_MESSAGE), each marking it dirty: a busy chunk of 13 parts was built up to 13 times,
## each over everything come so far (client-cpu.md 3). It is built once its last part is in, or
## after PARTS_WAIT_MSEC (a part lost on the way: the watchdog asks again after MISSING_CHUNK_MSEC,
## and the chunk shouldn't stand empty meanwhile). `--build-parts=each` builds on every part again.
const PARTS_WAIT_MSEC := 500
static var whole_snapshots := not Switches.has("--build-parts=each")


## A chunk's build is done (started at `t0`, its last part this frame).
func _built(c: Vector2i, cv: ChunkView, t0: int) -> void:
	if _live_prep.has(c):
		_live_built_msec[c] = Time.get_ticks_msec()
	if cv.pending.is_empty():
		_pending.erase(c)
		_live_prep.erase(c)
	else:
		_pending[c] = true
	_lod_soon(c)  # new MultiMeshes start at the model itself: their levels this frame
	_prof("build", t0)
	var te := Time.get_ticks_usec()
	entities_changed.emit(c)
	var was_revealed := cv.revealed
	_maybe_reveal(c, cv)
	if was_revealed and cv.has_ground() and cv.tile_ids.size() == CHUNK * CHUNK:
		chunk_drawn.emit(c)
	_prof("changed_signal", te)
	entity_build_usec += Time.get_ticks_usec() - t0
	entity_builds += 1


# How tall the tallest things are, for how far their shadows reach (a rocket silo's top; trees
# are 4-7 tiles).
const SHADOW_CASTER_HEIGHT := 16.0
# Chunks this many rings round the character's keep their shadows' full detail (the stand-ins
# simplify there only below a pixel of error, model_lods.gd); further out they simplify sooner.
const NEAR_SHADOW_RINGS := 1
# The view moves this far (tiles), or turns about a degree, before the casters are worked out again;
# the region is grown by as much to cover it.
const SHADOW_SLACK := 4.0


## Each chunk picks its models' levels of detail (chunk_view.gd update_lods) for Settings > Graphics
## > Level of detail's pixels of error at the size of a pixel where the chunk is: in perspective a
## pixel grows with distance (the field of view over the window's height, counted on at most
## ModelLods.max_lines), in an orthographic view it is the same everywhere.
func _update_lods(delta: float) -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null and (ModelLods.full_detail or lod_by_camera):
		return
	var height := ModelLods.counted_lines(get_viewport().get_visible_rect().size.y) if is_inside_tree() else 1080.0
	var per_tile := -1.0
	var flat := -1.0
	var at := Vector3(_focus.x, 0.0, _focus.y)
	if ModelLods.full_detail:
		flat = 0.0  # every model at its own full level, wherever it is (full_detail.gd)
		if cam != null:
			at = cam.global_position
	elif not lod_by_camera:
		if ViewPriority.char_lod_zoom and cam != null:
			var cam_d := ViewPriority.camera_zoom_distance(cam, _focus)
			if cam_d < 48.0:
				_char_zoom_y = 0.0
			elif _char_zoom_y == 0.0 and cam_d >= 56.0:
				_char_zoom_y = floorf(cam_d / 12.0) * 12.0
			elif _char_zoom_y > 0.0 and absf(cam_d - _char_zoom_y) >= 12.0:
				_char_zoom_y = 0.0 if cam_d < 48.0 else floorf(cam_d / 12.0) * 12.0
			at.y = _char_zoom_y
			if _char_zoom_y > 0.0 and cam.projection == Camera3D.PROJECTION_PERSPECTIVE:
				per_tile = ModelLods.lod_threshold * 2.0 * tan(deg_to_rad(clampf(cam.fov, 5.0, 170.0) * 0.5)) / height
			elif _char_zoom_y > 0.0 and cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
				flat = ModelLods.lod_threshold * cam.size / height
				per_tile = -1.0
			else:
				per_tile = ModelLods.lod_threshold * 2.0 * tan(deg_to_rad(CHAR_LOD_FOV * 0.5)) / height
		else:
			_char_zoom_y = 0.0
			per_tile = ModelLods.lod_threshold * 2.0 * tan(deg_to_rad(CHAR_LOD_FOV * 0.5)) / height
	elif cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		flat = ModelLods.lod_threshold * cam.size / height
		at = cam.global_position
	else:
		per_tile = ModelLods.lod_threshold * 2.0 * tan(deg_to_rad(cam.fov) * 0.5) / height
		at = cam.global_position
	if delta > 0.0 and _lod_prev_at.x != INF:
		var cam_v := Vector2(at.x - _lod_prev_at.x, at.z - _lod_prev_at.z).length() / delta
		if cam_v < 500.0:
			_lod_cam_speed = lerpf(_lod_cam_speed, cam_v, clampf(delta * 4.0, 0.0, 1.0))
	else:
		_lod_cam_speed = 0.0
	_lod_prev_at = at
	_lod_fast_moving = ChunkView.should_snap_for_speed(maxf(_focus_vel.length(), _lod_cam_speed))
	if cut_frame:
		_lod_settle(at, per_tile, flat)
		return
	if lod_bands_on:
		_update_lod_bands(at, per_tile, flat, delta)
		return
	_update_lods_every(at, per_tile, flat, delta)


## The pass before the bands (`--lod-pass=every-frame`): every chunk every frame up to LOD_ALL, else
## the LOD_NEAR_RINGS round the focus every frame and LOD_SLICE of the rest.
func _update_lods_every(at: Vector3, per_tile: float, flat: float, delta: float) -> void:
	if chunks.size() <= LOD_ALL:
		for c in chunks:
			var lcv := chunks[c] as ChunkView
			# Hidden behind the camera (I18): kept at their levels until shown, then cross-faded.
			if lcv.visible or lcv.lod_fading():
				var was_snap := lcv.lod_snap
				if _lod_fast_moving:
					lcv.lod_snap = true
				lcv.update_lods(at, per_tile, flat, delta)
				lcv.lod_snap = was_snap
		return
	# A long view distance: the chunks round the focus every frame, the rest a slice a frame, each
	# given the time since its last turn (a full round's frames) for its cross-fades.
	var center := stream_center()
	for offset: Vector2i in ring_order(LOD_NEAR_RINGS):
		var near: ChunkView = chunks.get(center + offset)
		if near != null:
			var was_snap := near.lod_snap
			if _lod_fast_moving:
				near.lod_snap = true
			near.update_lods(at, per_tile, flat, delta)
			near.lod_snap = was_snap
	if _lod_next >= _lod_todo.size():
		_lod_todo = chunks.values()
		_lod_next = 0
	var round_delta := delta * ceilf(float(_lod_todo.size()) / LOD_SLICE)
	var stop := mini(_lod_next + LOD_SLICE, _lod_todo.size())
	while _lod_next < stop:
		var cv = _lod_todo[_lod_next]
		_lod_next += 1
		if not is_instance_valid(cv) or chunks.get(cv.coord) != cv:
			continue
		var c: Vector2i = cv.coord
		if maxi(absi(c.x - center.x), absi(c.y - center.y)) > LOD_NEAR_RINGS and (cv.visible or cv.lod_fading()):
			var scv := cv as ChunkView
			var was_snap := scv.lod_snap
			if _lod_fast_moving:
				scv.lod_snap = true
			scv.update_lods(at, per_tile, flat, round_delta)
			scv.lod_snap = was_snap


## Past LOD_ALL chunks (view distance 20 is 1,681) those further than LOD_NEAR_RINGS from the focus
## pick their levels of detail LOD_SLICE a frame: a call for each of 10,201 chunks every frame (view
## distance 50) was several milliseconds of the main thread. Far away a level changes slowly.
const LOD_ALL := 1700
const LOD_NEAR_RINGS := 12
const LOD_SLICE := 1500
var _lod_todo: Array = []
var _lod_next := 0


## Levels of detail by bands of rings round the camera's chunk (client-cpu.md 2). Every loaded chunk
## every frame (or 2,125 a frame past LOD_ALL) was 1.2-1.4 ms of the main thread with nothing
## changing, on laps and standing alike. A chunk only needs looking at once its allowed error could
## have moved by LOD_LOOK_AGAIN: the camera moving that share of the chunk's distance, or the pixel's
## size changing by it. So the two rings round the camera are looked at every frame, and each band
## further out once the camera moved that share of the band's nearest distance since the band was
## last looked at (near bands every few frames while walking, the far ones every few seconds),
## its rings a slice at a time within the frame budget's `lods` system, nearest band first. Standing
## still, nothing. Chunks cross-fading move on every frame, chunks just built or added to next to
## nothing, and chunks shown again by behind_cull.gd switch without a fade (nothing on screen to
## fade from). `--lod-pass=every-frame` runs the pass before this.
const LOD_BANDS := [2, 3, 4, 6, 9, 13, 19, 28, 40, 58, 84]  # band k: rings [LOD_BANDS[k], LOD_BANDS[k + 1])
## A model's levels being made changes ModelLods.level_generation (every chunk looks again): a band
## starts again for it at most this often (dozens a second while joining).
const LOD_GEN_MSEC := 250
## Most MultiMesh level switches in one frame: each switch copies the MultiMesh buffer and adds a
## cross-fade node, so a whole ring crossing a boundary in one frame spiked both this pass (22-25 ms)
## and the next frame's renderer CPU (60-88 ms; art-src/perf-plans/after.md). Bypassed under
## ModelLods.full_detail; --lod-slice=off restores unbudgeted whole-ring switches.
const LOD_SWITCH_CAP := 16
static var lod_bands_on := not Switches.has("--lod-pass=every-frame")
static var lod_slice_on := Switches.on("--lod-slice")


class LodBand:
	var lo := 0  # its rings: [lo, hi)
	var hi := 0
	var at := Vector3(INF, INF, INF)  # the camera when it was last started
	var p := -1.0  # the tiles of error a tile (or flat) then
	var ortho := false
	var gen := -1  # ModelLods.level_generation then
	var msec := -1000000
	var ring := -1  # the ring to look at next (-1: nothing to do); the far band: its index in _lod_far
	var ring_pos := 0  # next chunk index around `ring` (0 .. 8 * ring - 1)
	var center := Vector2i.ZERO  # the camera's chunk when it started
	var again := false  # due again before it finished


var _lod_bands: Array = []
var _lod_fades := {}  # ChunkView -> true: cross-fading
var _lod_now := {}  # Vector2i -> whether without a fade (shown again): looked at this frame
var _lod_far: Array = []  # the far band's chunks (past the last band's rings), when it runs
var _lod_prev_at := Vector3(INF, INF, INF)
var _lod_cam_speed := 0.0
var _lod_fast_moving := false
## Chunks looked at, level switches made, and microseconds spent this frame (for the UI test and probes).
var lod_looked := 0
var lod_switches := 0
var lod_usec := 0


## behind_cull.gd (and remote_fog.gd) showed a chunk again: its levels, without a fade, next frame.
func chunk_shown(c: Vector2i) -> void:
	if lod_bands_on:
		_lod_now[c] = true


func _lod_soon(c: Vector2i) -> void:
	if lod_bands_on and not _lod_now.has(c):
		_lod_now[c] = false


func _update_lod_bands(at: Vector3, per_tile: float, flat: float, delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	lod_looked = 0
	lod_switches = 0
	var cap_switches := lod_slice_on and not ModelLods.full_detail
	if _lod_bands.is_empty():
		for k in LOD_BANDS.size():
			var band := LodBand.new()
			band.lo = LOD_BANDS[k]
			band.hi = LOD_BANDS[k + 1] if k + 1 < LOD_BANDS.size() else 0x3fffffff
			_lod_bands.append(band)
	for cv in _lod_fades.keys():
		if not is_instance_valid(cv) or chunks.get(cv.coord) != cv:
			_lod_fades.erase(cv)
			continue
		if lod_slice_on:
			cv.advance_lod_fades(delta)
		else:
			cv.update_lods(at, per_tile, flat, delta)
		if not cv.lod_fading():
			_lod_fades.erase(cv)
	# Under full detail (a screenshot) everything at once, as the pass before.
	var allow := 0x3fffffff if ModelLods.full_detail else FrameBudget.grant(&"lods")
	if not ModelLods.full_detail and FrameBudget.shared and allow <= 0:
		lod_usec = Time.get_ticks_usec() - t0
		FrameBudget.waiting(&"lods", maxi(_lod_now.size() + 9, 9))
		return
	var t1 := Time.get_ticks_usec()
	var cam_chunk := chunk_of(Vector2(at.x, at.z))
	var near_stop := false
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if not _lod_budget_left(t1, allow, cap_switches):
				near_stop = true
				break
			_lod_cell(cam_chunk + Vector2i(dx, dy), at, per_tile, flat, false, cap_switches)
		if near_stop:
			break
	_lod_ahead(at, per_tile, flat, t1, allow, cap_switches, near_stop)
	var ortho := flat >= 0.0
	var p := flat if ortho else per_tile
	var gen := ModelLods.level_generation
	var now := Time.get_ticks_msec()
	var high := maxf(at.y - ChunkView.LOD_HEIGHT, 0.0) if at.y > 0.0 else -at.y
	# Rings past this hold no chunk: the square's reach round its middle, from the camera's chunk.
	var reach := maxi(absi(cam_chunk.x - _sq_center.x), absi(cam_chunk.y - _sq_center.y)) + loaded_reach()
	if not _held.is_empty():
		reach = 0x3fffffff
	var busy := 0
	for band: LodBand in _lod_bands:
		if band.lo > reach and band.ring < 0:
			continue
		if _lod_due(band, at, p, ortho, gen, now, high):
			if band.ring < 0:
				_lod_start(band, at, p, ortho, gen, now, cam_chunk)
			else:
				band.again = true
		if band.ring >= 0:
			busy += 1
	if _lod_now.is_empty() and busy == 0:
		lod_usec = Time.get_ticks_usec() - t0
		if lod_switches > 0 or Time.get_ticks_usec() - t1 >= 100:
			FrameBudget.spent(&"lods", lod_usec, 0)
		else:
			FrameBudget.waiting(&"lods", 0)
		return
	if not near_stop:
		for c: Vector2i in _lod_now.keys():
			if not _lod_budget_left(t1, allow, cap_switches):
				break
			var snap: bool = _lod_now[c]
			_lod_now.erase(c)
			_lod_cell(c, at, per_tile, flat, snap, cap_switches)
		for band: LodBand in _lod_bands:
			var out_of_budget := false
			while band.ring >= 0:
				if not _lod_budget_left(t1, allow, cap_switches):
					out_of_budget = true
					break
				if band.hi == 0x3fffffff:
					_lod_far_step(band, at, per_tile, flat, t1, allow, cap_switches)
				elif band.ring >= band.hi or band.ring > reach:
					band.ring = -1
					band.ring_pos = 0
				else:
					if not _lod_ring_step(band, at, per_tile, flat, t1, allow, cap_switches):
						out_of_budget = true
						break
				if band.ring < 0 and band.again:
					_lod_start(band, at, p, ortho, gen, now, cam_chunk)
			if out_of_budget:
				break
	busy = 0
	for band: LodBand in _lod_bands:
		if band.ring >= 0:
			busy += 1
	lod_usec = Time.get_ticks_usec() - t0
	FrameBudget.spent(&"lods", lod_usec, busy + _lod_now.size())


func _lod_budget_left(t1: int, allow: int, cap_switches: bool) -> bool:
	if ModelLods.full_detail:
		return true
	if cap_switches and lod_switches >= LOD_SWITCH_CAP:
		return false
	if lod_looked > 0 and Time.get_ticks_usec() - t1 > allow:
		return false
	return true


## Whether a band's chunks may need other levels than when it was last started.
func _lod_due(band: LodBand, at: Vector3, p: float, ortho: bool, gen: int, now: int, high: float) -> bool:
	if band.ortho != ortho:
		return true
	if band.gen != gen and now - band.msec >= LOD_GEN_MSEC:
		return true
	var moved := 0.0
	if band.p > 0.0:
		moved = absf(p / band.p - 1.0)
	elif p != band.p:
		return true
	if not ortho:
		# The band's nearest point: (lo - 1) chunks off the camera's chunk, and the camera's height.
		var flat_d := maxf(float(band.lo - 1) * CHUNK, 0.0)
		moved += at.distance_to(band.at) / maxf(sqrt(flat_d * flat_d + high * high), 1.0)
	return moved > ChunkView.LOD_LOOK_AGAIN


func _lod_start(band: LodBand, at: Vector3, p: float, ortho: bool, gen: int, now: int, cam_chunk: Vector2i) -> void:
	band.at = at
	band.p = p
	band.ortho = ortho
	band.gen = gen
	band.msec = now
	band.center = cam_chunk
	band.again = false
	band.ring_pos = 0
	if band.hi == 0x3fffffff:
		_lod_far = chunks.values()
		band.ring = 0
	else:
		band.ring = band.lo


## The `pos`-th chunk offset around ring `r` (0 .. 8 * r - 1), walking top, bottom, left, right edges.
static func _lod_ring_offset(r: int, pos: int) -> Vector2i:
	var horiz := 2 * r + 1
	if pos < horiz:
		return Vector2i(pos - r, -r)
	pos -= horiz
	if pos < horiz:
		return Vector2i(pos - r, r)
	pos -= horiz
	var vert := 2 * r - 1
	if pos < vert:
		return Vector2i(-r, pos - r + 1)
	pos -= vert
	return Vector2i(r, pos - r + 1)


## Steps through chunks at ring `band.ring` round `band.center`, yielding when the frame's time or
## switch budget runs out. Returns true when the ring finished.
func _lod_ring_step(band: LodBand, at: Vector3, per_tile: float, flat: float, t1: int, allow: int, cap_switches: bool) -> bool:
	var r := band.ring
	var total := 8 * r
	while band.ring_pos < total:
		if cap_switches and not _lod_budget_left(t1, allow, cap_switches):
			return false
		var offset := _lod_ring_offset(r, band.ring_pos)
		band.ring_pos += 1
		_lod_cell(band.center + offset, at, per_tile, flat, false, cap_switches)
	band.ring_pos = 0
	band.ring += 1
	return true


## The far band: loaded chunks past the last band's rings (held ones), a slice of _lod_far at a time.
func _lod_far_step(band: LodBand, at: Vector3, per_tile: float, flat: float, t1: int, allow: int, cap_switches: bool) -> void:
	var stop := mini(band.ring + 256, _lod_far.size())
	while band.ring < stop:
		if cap_switches and not _lod_budget_left(t1, allow, cap_switches):
			return
		var cv = _lod_far[band.ring]
		band.ring += 1
		if not is_instance_valid(cv) or chunks.get(cv.coord) != cv:
			continue
		var c: Vector2i = cv.coord
		if maxi(absi(c.x - band.center.x), absi(c.y - band.center.y)) >= band.lo:
			_lod_cell(c, at, per_tile, flat, false, cap_switches)
	if band.ring >= _lod_far.size():
		band.ring = -1
		_lod_far = []


func _lod_cell(c: Vector2i, at: Vector3, per_tile: float, flat: float, snap: bool, cap_switches := true) -> void:
	var cv: ChunkView = chunks.get(c)
	# Hidden behind the camera (I18): kept at their levels until shown (chunk_shown), unless a viewpoint
	# announced ahead (view_ahead.gd) is nearer: then at its levels before the camera gets there, snapped.
	if cv == null:
		return
	var ahead := false
	if not _lod_ahead_points.is_empty():
		var p := _lod_point(c, at)
		ahead = p != at
		at = p
	if not cv.visible and not ahead:
		return
	if ahead:
		_lod_ahead_chunks[c] = true
		if not cv.visible:
			snap = true
	lod_looked += 1
	if cv._lods.is_empty():
		cv.lod_last_switches = 0
		cv.lod_partial = false
		return
	var budget := maxi(LOD_SWITCH_CAP - lod_switches, 0) if cap_switches else -1
	if snap or _lod_fast_moving:
		var was_snap := cv.lod_snap
		cv.lod_snap = true
		cv.update_lods(at, per_tile, flat, 0.0, budget)
		cv.lod_snap = was_snap
	else:
		cv.update_lods(at, per_tile, flat, 0.0, budget)
	lod_switches += cv.lod_last_switches
	if cv.lod_partial:
		_lod_now[c] = snap or bool(_lod_now.get(c, false))
	if cv.lod_fading():
		_lod_fades[cv] = true


## A cut: the chunks within CUT_FLUSH_RINGS of the camera's add the MultiMeshes their build left for later
## now, without the build budget, so a merged far mesh standing for them goes (far_chunks.gd built) and the
## cliff wall shows in the cut's frame. A viewpoint announced ahead has them added under the budget before.
const CUT_FLUSH_RINGS := 2


func _cut_flush_pending(cam: Camera3D) -> void:
	if cam == null or _pending.is_empty():
		return
	var cc := chunk_of(Vector2(cam.global_position.x, cam.global_position.z))
	var budget := ChunkView.Budget.new(0x3fffffff)
	for dy in range(-CUT_FLUSH_RINGS, CUT_FLUSH_RINGS + 1):
		for dx in range(-CUT_FLUSH_RINGS, CUT_FLUSH_RINGS + 1):
			var c := cc + Vector2i(dx, dy)
			var pcv: ChunkView = chunks.get(c)
			if not _pending.has(c) or pcv == null or pcv.building or _prep_jobs.has(c):
				continue
			if pcv.add_pending(working, animator, budget):
				_pending.erase(c)
				_live_prep.erase(c)
				_maybe_reveal(c, pcv)


## The viewpoints announced ahead (view_ahead.gd) this frame, and the chunks looked at for them (looked at
## again for the camera alone once they are let go).
var _lod_ahead_points: Array[Vector3] = []
var _lod_ahead_chunks := {}
var _lod_ahead_gen := -1
## Rings round an announced viewpoint's chunk looked at for it each frame (nearest first, those already at
## their levels cost next to nothing): 6 is 192 tiles, past where far merges start at 1080p.
const LOD_AHEAD_RINGS := 6
## This frame is a cut (view_ahead.gd): far merges and levels picked whole.
var cut_frame := false
## `--cut-shots=<folder>`: the first frame drawn after each cut (cut-NN-first-new|old.png) and the one
## CUT_SHOT_LATER frames on, for comparing `--cut-lods=old` with the change (a check, off by default).
static var cut_shots := Switches.value("--cut-shots")
const CUT_SHOT_LATER := 30
var _cut_shot_n := 0
var _cut_log_gen := -1
var _cut_shot_later := 0


## What the chunks round the camera are drawn as (`--cut-shots`'s log): within 2 chunks of the camera's.
func _cut_census(what: String) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var cc := chunk_of(Vector2(cam.global_position.x, cam.global_position.z))
	var n := 0
	var missing := 0
	var unloaded := 0
	var hidden := 0
	var building := 0
	var far := 0
	var covers := 0
	var walls := [0, 0, 0]
	var wall_hidden := 0
	var no_wall := 0
	var dh := 0
	var dh_obj = dh_covers_chunk.get_object() if dh_covers_chunk.is_valid() else null
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			var c := cc + Vector2i(dx, dy)
			n += 1
			var cv: ChunkView = chunks.get(c)
			if dh_obj != null and bool(dh_covers_chunk.call(c)):
				dh += 1
			if cv == null:
				missing += 1
				continue
			if not cv.loaded:
				unloaded += 1
			if not cv.visible:
				hidden += 1
			if cv.building or _dirty.has(c) or not cv.pending.is_empty():
				building += 1
			if cv.far.far:
				far += 1
			if cv.far.covers:
				covers += 1
			var st: CliffWall.State = cv.wall
			if st.holder == null:
				if not st.cells.is_empty():
					no_wall += 1
			elif not st.holder.visible:
				wall_hidden += 1
			elif st.level >= 0:
				walls[st.level] += 1
	print("world: cut census %s (tick %d, %s): %d chunks round the camera: %d missing, %d not loaded, %d hidden, %d building or pending, %d far (%d merged mesh), wall levels %s, %d walls hidden, %d walls not built, DH covers %d" % [
		what, Bridge.server_tick, "new" if ViewAhead.on else "old", n, missing, unloaded, hidden, building, far, covers, walls, wall_hidden, no_wall, dh])


func _cut_shot(what: String) -> void:
	var path := cut_shots.path_join("cut-%s-%s.png" % [what, "new" if ViewAhead.on else "old"])
	var save := func() -> void:
		if is_inside_tree():
			var img := get_viewport().get_texture().get_image()
			if img != null:
				DirAccess.make_dir_recursive_absolute(path.get_base_dir())
				img.save_png(path)
				print("world: cut shot %s (tick %d)" % [path, Bridge.server_tick])
	RenderingServer.frame_post_draw.connect(save, CONNECT_ONE_SHOT)


## Chunks looked at by the last cut's settle and the microseconds it took (tests, probes).
var cut_looked := 0
var cut_usec := 0
var cut_far_usec := 0


## Of the camera (`at`) and the viewpoints announced ahead, the one nearest chunk `c` (as
## ChunkView.update_lods measures: the chunk up to LOD_HEIGHT).
func _lod_point(c: Vector2i, at: Vector3) -> Vector3:
	if _lod_ahead_points.is_empty():
		return at
	var lo := Vector3(c.x * CHUNK, 0.0, c.y * CHUNK)
	return ViewAhead.nearest(at, lo, lo + Vector3(CHUNK, ChunkView.LOD_HEIGHT, CHUNK))


## The chunks round each viewpoint announced ahead, nearest first, within the frame's budget; once they are
## let go, the chunks looked at for them are looked at again for the camera alone.
func _lod_ahead(at: Vector3, per_tile: float, flat: float, t1: int, allow: int, cap_switches: bool, stopped: bool) -> void:
	var gen := ViewAhead.generation
	if gen != _lod_ahead_gen:
		_lod_ahead_gen = gen
		_lod_ahead_points = ViewAhead.points()
		for c: Vector2i in _lod_ahead_chunks:
			_lod_soon(c)
		_lod_ahead_chunks.clear()
	elif not _lod_ahead_points.is_empty() and not ViewAhead.active():
		_lod_ahead_gen = -1  # ran out: let go next frame
	if _lod_ahead_points.is_empty() or stopped:
		return
	for p: Vector3 in _lod_ahead_points:
		var pc := chunk_of(Vector2(p.x, p.z))
		for r in LOD_AHEAD_RINGS + 1:
			var total := 1 if r == 0 else 8 * r
			for i in total:
				if not _lod_budget_left(t1, allow, cap_switches):
					return
				_lod_cell(pc + (Vector2i.ZERO if r == 0 else _lod_ring_offset(r, i)), at, per_tile, flat, false, cap_switches)


## A cut: every chunk's levels picked now for where the camera is (and the viewpoints announced ahead),
## without the frame budget, the switch cap or cross-fades, hidden chunks too; the bands start from here.
func _lod_settle(at: Vector3, per_tile: float, flat: float) -> void:
	var t0 := Time.get_ticks_usec()
	_lod_ahead_gen = ViewAhead.generation
	_lod_ahead_points = ViewAhead.points()
	lod_looked = 0
	lod_switches = 0
	for c: Vector2i in chunks:
		var cv := chunks[c] as ChunkView
		if cv._lods.is_empty():
			continue
		lod_looked += 1
		var was_snap := cv.lod_snap
		cv.lod_snap = true
		cv.update_lods(_lod_point(c, at), per_tile, flat, 0.0)
		cv.lod_snap = was_snap
		lod_switches += cv.lod_last_switches
		if cv.lod_fading():
			_lod_fades[cv] = true
	_lod_now.clear()
	var ortho := flat >= 0.0
	var cam_chunk := chunk_of(Vector2(at.x, at.z))
	for band: LodBand in _lod_bands:
		_lod_start(band, at, flat if ortho else per_tile, ortho, ModelLods.level_generation, Time.get_ticks_msec(), cam_chunk)
		band.ring = -1
	_lod_far = []
	cut_looked = lod_looked
	cut_usec = Time.get_ticks_usec() - t0
	lod_usec = cut_usec


func _row_add(c: Vector2i, cv: ChunkView) -> void:
	var row: Dictionary = _chunks_by_row.get(c.y, {})
	if not row.has(c.x):
		_row_index_count += 1
	row[c.x] = cv
	_chunks_by_row[c.y] = row


func _row_remove(c: Vector2i) -> void:
	var row: Dictionary = _chunks_by_row.get(c.y, {})
	if row.erase(c.x):
		_row_index_count = maxi(_row_index_count - 1, 0)
		if row.is_empty():
			_chunks_by_row.erase(c.y)


func _rebuild_row_index() -> void:
	_chunks_by_row.clear()
	_row_index_count = 0
	for c: Vector2i in chunks:
		_row_add(c, chunks[c])


func chunks_by_row() -> Dictionary:
	if _row_index_count != chunks.size():
		_rebuild_row_index()
	return _chunks_by_row


func _hull_chunk_run(hull: PackedVector2Array, ry: int) -> Vector2i:
	var span := hull_row(hull, float(ry * CHUNK), float((ry + 1) * CHUNK))
	if span.x > span.y:
		return Vector2i(1, 0)
	return Vector2i(ceili(span.x / float(CHUNK)) - 1, floori(span.y / float(CHUNK)))


func _shadow_enqueue(cv: ChunkView) -> void:
	if not _shadow_queued.has(cv.coord):
		_shadow_queued[cv.coord] = true
		_shadow_todo.append(cv)


func _enqueue_shadow_span(row: Dictionary, x0: int, x1: int) -> void:
	if x0 > x1 or row.is_empty():
		return
	if x1 - x0 + 1 <= row.size():
		for x in range(x0, x1 + 1):
			var cv = row.get(x)
			if cv != null:
				_shadow_enqueue(cv)
	else:
		for x: int in row:
			if x >= x0 and x <= x1:
				_shadow_enqueue(row[x])


func _enqueue_shadow_diff(row: Dictionary, was_run: Vector2i, now_run: Vector2i) -> void:
	var was_empty := was_run.x > was_run.y
	var now_empty := now_run.x > now_run.y
	if was_empty:
		_enqueue_shadow_span(row, now_run.x, now_run.y)
	elif now_empty:
		_enqueue_shadow_span(row, was_run.x, was_run.y)
	elif was_run.y < now_run.x or now_run.y < was_run.x:
		_enqueue_shadow_span(row, was_run.x, was_run.y)
		_enqueue_shadow_span(row, now_run.x, now_run.y)
	else:
		_enqueue_shadow_span(row, mini(was_run.x, now_run.x), maxi(was_run.x, now_run.x) - 1)
		_enqueue_shadow_span(row, mini(was_run.y, now_run.y) + 1, maxi(was_run.y, now_run.y))


func _enqueue_shadow_ring_square(center: Vector2i) -> void:
	for dy in range(-NEAR_SHADOW_RINGS, NEAR_SHADOW_RINGS + 1):
		var row: Dictionary = _chunks_by_row.get(center.y + dy, {})
		if row.is_empty():
			continue
		for dx in range(-NEAR_SHADOW_RINGS, NEAR_SHADOW_RINGS + 1):
			var cv = row.get(center.x + dx)
			if cv != null:
				_shadow_enqueue(cv)


## The sun's shadow map covers what the camera sees out to its max distance, but Godot draws every
## caster in the light's box into it, out to the horizon in the sun's direction, once per shadow
## split: on a 20,000-entity base the shadow pass drew 1,400 draw calls and 20-28 million
## triangles a frame, against 0.5 million for the view itself. Only chunks whose shadows can fall
## inside the covered ground cast any, through their models' stand-ins (model_lods.gd).
func _update_shadow_casters() -> void:
	if ModelLods.poll():
		_shadow_key = []
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var on := sun != null and sun.shadow_enabled and sun.is_visible_in_tree() and cam != null
	ChunkView.no_stand_ins = cam != null and cam.projection == Camera3D.PROJECTION_ORTHOGONAL
	var center := stream_center()
	var full_key: Array = [on, ModelLods.generation, ModelLods.lod_bias, ChunkView.no_stand_ins]
	var move_key: Array = [center]
	if on:
		var basis := cam.global_basis
		move_key.append_array([(cam.global_position / (SHADOW_SLACK * 0.5)).round(), (basis.z * 20.0).round(), (basis.x * 20.0).round(),
			roundi(cam.fov), roundi(cam.size), cam.projection, ((-sun.global_basis.z) * 20.0).round(), sun.directional_shadow_max_distance])
	if not shadow_row_runs:
		var legacy_key: Array = [on, chunks.size(), ModelLods.generation, ModelLods.lod_bias, center]
		if on:
			legacy_key.append_array(move_key.slice(1))
		if legacy_key != _shadow_key:
			_shadow_key = legacy_key
			_shadow_full_key = []
			_shadow_move_key = []
			_shadow_incremental = false
			_shadow_on = on
			_shadow_hull = shadow_region(cam, sun) if on else PackedVector2Array()
			_shadow_rows = {}
			_shadow_center = center
			_shadow_prev_center = center
			_shadow_queued.clear()
			_shadow_fresh.clear()
			_shadow_uncounted.clear()
			_shadow_runs.clear()
			var at := _shadow_start + _shadow_next if _shadow_next < _shadow_todo.size() else 0
			_shadow_todo = chunks.values()
			_shadow_start = at % maxi(_shadow_todo.size(), 1)
			_shadow_next = 0
			_shadow_count = 0
	else:
		var move_changed := move_key != _shadow_move_key
		var full_changed := _shadow_key.is_empty() or full_key != _shadow_full_key or _row_index_count != chunks.size()
		if not full_changed and not on:
			if not _shadow_fresh.is_empty():
				for fcv: ChunkView in _shadow_fresh:
					if not is_instance_valid(fcv) or chunks.get(fcv.coord) != fcv:
						continue
					fcv.set_shadow_tier(ChunkView.SHADOWS_NEAR)
					if _shadow_uncounted.erase(fcv.coord):
						shadow_casters += 1
				_shadow_fresh.clear()
			if move_changed:
				_shadow_move_key = move_key
				_shadow_key = full_key + move_key
				_shadow_center = center
				_shadow_prev_center = center
		elif not full_changed and (move_changed or not _shadow_fresh.is_empty()) and (_shadow_next >= _shadow_todo.size() or _shadow_incremental):
			_shadow_incremental = true
			_shadow_full_key = full_key
			_shadow_move_key = move_key
			_shadow_key = full_key + move_key
			_shadow_on = true
			_shadow_center = center
			if _shadow_next >= _shadow_todo.size():
				_shadow_todo = []
				_shadow_next = 0
				_shadow_start = 0
				_shadow_queued.clear()
			if move_changed:
				_shadow_hull = shadow_region(cam, sun)
				_shadow_rows = {}
				for ry: int in _chunks_by_row:
					var row: Dictionary = _chunks_by_row[ry]
					var now_run := _hull_chunk_run(_shadow_hull, ry)
					var was_run: Vector2i = _shadow_runs.get(ry, Vector2i(1, 0))
					_shadow_runs[ry] = now_run
					if now_run != was_run:
						_enqueue_shadow_diff(row, was_run, now_run)
				if _shadow_center != _shadow_prev_center:
					_enqueue_shadow_ring_square(_shadow_prev_center)
					_enqueue_shadow_ring_square(_shadow_center)
					_shadow_prev_center = _shadow_center
			if not _shadow_fresh.is_empty():
				for fcv: ChunkView in _shadow_fresh:
					if not is_instance_valid(fcv) or chunks.get(fcv.coord) != fcv:
						continue
					if not _shadow_runs.has(fcv.coord.y):
						_shadow_runs[fcv.coord.y] = _hull_chunk_run(_shadow_hull, fcv.coord.y)
					_shadow_enqueue(fcv)
				_shadow_fresh.clear()
		elif full_changed or move_changed or not _shadow_fresh.is_empty():
			_shadow_full_key = full_key
			_shadow_move_key = move_key
			_shadow_key = full_key + move_key
			_shadow_incremental = false
			_shadow_on = on
			_shadow_hull = shadow_region(cam, sun) if on else PackedVector2Array()
			_shadow_rows = {}
			_shadow_center = center
			_shadow_prev_center = center
			_shadow_queued.clear()
			_shadow_fresh.clear()
			_shadow_uncounted.clear()
			_shadow_runs.clear()
			var rows := chunks_by_row()
			if on:
				for ry: int in rows:
					_shadow_runs[ry] = _hull_chunk_run(_shadow_hull, ry)
			var at := _shadow_start + _shadow_next if _shadow_next < _shadow_todo.size() else 0
			_shadow_todo = chunks.values()
			_shadow_start = at % maxi(_shadow_todo.size(), 1)
			_shadow_next = 0
			_shadow_count = 0
	if _shadow_next >= _shadow_todo.size():
		FrameBudget.waiting(&"shadows", 0)
		return
	var size := _shadow_todo.size()
	var did := 0
	# Tests lift shadow_usec to set every chunk at once.
	var from_budget := shadow_usec == SHADOW_USEC
	var allow := FrameBudget.grant(&"shadows") if from_budget else shadow_usec
	var t0 := Time.get_ticks_usec()
	while not (from_budget and allow <= 0) and _shadow_next < size:
		if did > 0 and Time.get_ticks_usec() - t0 > allow:
			break
		var cv = _shadow_todo[(_shadow_start + _shadow_next) % size]
		_shadow_next += 1
		did += 1
		if not is_instance_valid(cv) or chunks.get(cv.coord) != cv:
			continue
		var tier := ChunkView.SHADOWS_NEAR
		if _shadow_on:
			var ring := maxi(absi(cv.coord.x - _shadow_center.x), absi(cv.coord.y - _shadow_center.y))
			if not _chunk_meets_hull(cv.coord):
				tier = ChunkView.SHADOWS_NONE
			elif ring > NEAR_SHADOW_RINGS:
				tier = ChunkView.SHADOWS_FAR
		var prev_on: bool = (cv as ChunkView).shadow_tier != ChunkView.SHADOWS_NONE
		(cv as ChunkView).set_shadow_tier(tier)
		var now_on := tier != ChunkView.SHADOWS_NONE
		if _shadow_incremental:
			if _shadow_uncounted.erase(cv.coord):
				if now_on:
					shadow_casters += 1
			elif now_on != prev_on:
				shadow_casters = maxi(shadow_casters + (1 if now_on else -1), 0)
			_shadow_queued.erase(cv.coord)
		elif now_on:
			_shadow_count += 1
	if _shadow_next >= size:
		if not _shadow_incremental:
			shadow_casters = _shadow_count
		_shadow_todo = []
		_shadow_next = 0
		_shadow_start = 0
		_shadow_queued.clear()
	FrameBudget.spent(&"shadows", Time.get_ticks_usec() - t0, maxi(_shadow_todo.size() - _shadow_next, 0))


# Main-thread time a frame for setting chunks' shadow tiers (at least one chunk).
const SHADOW_USEC := 1000
var shadow_usec := SHADOW_USEC  # tests lift it to set every chunk at once
var _shadow_on := false
var _shadow_hull := PackedVector2Array()
var _shadow_rows := {}  # chunk row -> hull_row() of _shadow_hull
var _shadow_center := Vector2i.ZERO
var _shadow_prev_center := Vector2i(1 << 29, 1 << 29)
var _shadow_full_key: Array = []
var _shadow_move_key: Array = []
var _shadow_runs := {}  # cy: int -> Vector2i(x0, x1)
var _shadow_queued := {}  # Vector2i -> true
var _shadow_fresh: Array = []
var _shadow_uncounted := {}  # Vector2i -> true
var _shadow_incremental := false
var _shadow_todo: Array = []  # chunks still to set, in no particular order
var _shadow_next := 0  # how many of _shadow_todo are done, from _shadow_start round
var _shadow_start := 0
var _shadow_count := 0


## The ground (x, z in tiles) whose casters can throw a shadow into what the camera sees within
## the sun's shadow distance: the outline of the view out to that distance, grown by the longest
## shadow (a convex polygon).
static func shadow_region(cam: Camera3D, light: DirectionalLight3D) -> PackedVector2Array:
	var far := minf(light.directional_shadow_max_distance, cam.far)
	var down := -light.global_transform.basis.z
	var points := PackedVector2Array()
	if not ViewPriority.tight_cull:
		var size := cam.get_viewport().get_visible_rect().size
		var reach := SHADOW_CASTER_HEIGHT / maxf(tan(asin(clampf(-down.y, 0.0, 1.0))), 0.25) + SHADOW_SLACK + far * 0.02
		for corner in [Vector2.ZERO, Vector2(size.x, 0.0), Vector2(0.0, size.y), size]:
			for depth in [cam.near, far]:
				var p := cam.project_position(corner, depth)
				# Grown by the reach as a square round each corner: the hull of those holds the
				# outline grown by at least the reach.
				for d in [Vector2(-reach, -reach), Vector2(reach, -reach), Vector2(-reach, reach), Vector2(reach, reach)]:
					points.append(Vector2(p.x, p.z) + d)
		return Geometry2D.convex_hull(points)
	var sun_tan := maxf(tan(asin(clampf(-down.y, 0.0, 1.0))), 0.25)
	var horiz := Vector2(-down.x, -down.z)
	var up_sun := horiz.normalized() * minf(SHADOW_CASTER_HEIGHT / sun_tan, 64.0) if horiz.length_squared() > 1e-6 else Vector2.ZERO
	var pad := SHADOW_SLACK + far * 0.02 + 2.0
	for pair: Array in ViewPriority.ground_slab_points(cam, far, -4.0, SHADOW_CASTER_HEIGHT):
		var pt: Vector2 = pair[0]
		for d in [Vector2(-pad, -pad), Vector2(pad, -pad), Vector2(-pad, pad), Vector2(pad, pad)]:
			points.append(pt + d)
		if up_sun.length_squared() > 0.01:
			var sp := pt + up_sun
			for d in [Vector2(-pad, -pad), Vector2(pad, -pad), Vector2(-pad, pad), Vector2(pad, pad)]:
				points.append(sp + d)
	return Geometry2D.convex_hull(points)


## Whether a rectangle and a convex polygon (Geometry2D.convex_hull's, closed) overlap: no
## separating axis among the rectangle's two and the polygon's edges.
static func _rect_meets_hull(rect: Rect2, hull: PackedVector2Array) -> bool:
	if hull.size() < 4:
		return false
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var middle := Vector2.ZERO
	for i in hull.size() - 1:
		lo = lo.min(hull[i])
		hi = hi.max(hull[i])
		middle += hull[i]
	if not rect.intersects(Rect2(lo, hi - lo)):
		return false
	middle /= hull.size() - 1
	var corners := [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]
	for i in hull.size() - 1:
		var edge := hull[i + 1] - hull[i]
		var normal := Vector2(edge.y, -edge.x)
		# The hull lies on its middle's side of each edge; the rectangle is outside if all its
		# corners lie beyond one.
		var inner := signf(normal.dot(middle - hull[i]))
		var outside := true
		for c in corners:
			if signf(normal.dot(c - hull[i])) != -inner:
				outside = false
				break
		if outside:
			return false
	return true


## Whether chunk `c` meets the shadow region (_rect_meets_hull's answer): the region's extent along
## each row of chunks is worked out once a pass, so each chunk is one comparison. The hull test for
## each of ~800 chunks was most of the shadow pass's time.
func _chunk_meets_hull(c: Vector2i) -> bool:
	var row: Vector2 = _shadow_rows.get(c.y, Vector2.INF)
	if row == Vector2.INF:
		row = hull_row(_shadow_hull, float(c.y * CHUNK), float(c.y * CHUNK + CHUNK))
		_shadow_rows[c.y] = row
	return row.x <= float(c.x * CHUNK + CHUNK) and row.y >= float(c.x * CHUNK)


## How far a convex polygon (Geometry2D.convex_hull's, closed) reaches along x between y0 and y1:
## (min x, max x), or (INF, -INF) where it doesn't reach. A rectangle spanning y0..y1 meets the
## polygon exactly when its x range overlaps this (the polygon's slice of the band is convex).
static func hull_row(hull: PackedVector2Array, y0: float, y1: float) -> Vector2:
	var lo := INF
	var hi := -INF
	if hull.size() < 4:
		return Vector2(lo, hi)
	for i in hull.size() - 1:
		var a := hull[i]
		var b := hull[i + 1]
		if maxf(a.y, b.y) < y0 or minf(a.y, b.y) > y1:
			continue
		var xa := a.x
		var xb := b.x
		if a.y != b.y:
			xa = lerpf(a.x, b.x, clampf((y0 - a.y) / (b.y - a.y), 0.0, 1.0))
			xb = lerpf(a.x, b.x, clampf((y1 - a.y) / (b.y - a.y), 0.0, 1.0))
		lo = minf(lo, minf(xa, xb))
		hi = maxf(hi, maxf(xa, xb))
	return Vector2(lo, hi)


func terrain_queue_size() -> int:
	return _dirty_terrain.size() + _terrain_jobs.size()


func _refresh_gfx_table() -> void:
	_gfx_generation = TerrainTextures.generation
	var table: Array = []
	table.resize(protos.tile_names.size())
	var nothing := TerrainTextures.TileGfx.new()  # empty space: never drawn
	for id in table.size():
		table[id] = nothing if protos.is_void(id) else TerrainTextures.peek(protos.tile_names[id])
	_gfx_table = table


## Past this many chunks from the focus the ground is drawn coarse (TerrainMesher.coarse): full ground
## for every chunk of a 101x101 view was gigabytes. 14 is Ultra's view distance and about how far the
## bridge's old 625 chunks reached, so nothing drawn before changes. COARSE_SLACK rings either way, so
## walking along the line doesn't build the same chunks again and again.
const COARSE_FROM := 14
const COARSE_SLACK := 2


func _wants_coarse(cv: ChunkView, c: Vector2i, center: Vector2i) -> bool:
	var ring := maxi(absi(c.x - center.x), absi(c.y - center.y))
	if cv.has_ground() and not cv.ground_coarse:
		return ring > COARSE_FROM + COARSE_SLACK
	return ring > COARSE_FROM


## The focus moved from `was` to `now`: chunks whose ground should go between full and coarse are
## built again. A step looks only at the rings either side of the line; a jump at every chunk.
func _recheck_coarse(was: Vector2i, now: Vector2i, max_r := -1) -> void:
	if maxi(view_radius, maxi(_sq_radius, max_r)) <= COARSE_FROM or chunks.is_empty():
		return
	var moved := maxi(absi(now.x - was.x), absi(now.y - was.y))
	if moved == 0 or moved > JUMP_CHUNKS:
		for c: Vector2i in chunks:
			_coarse_check(c, now)
		return
	for r in range(COARSE_FROM - moved, COARSE_FROM + COARSE_SLACK + moved + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1, 1 if absi(dy) == r else 2 * r):
				_coarse_check(now + Vector2i(dx, dy), now)


func _coarse_check(c: Vector2i, center: Vector2i) -> void:
	var cv: ChunkView = chunks.get(c)
	if cv != null and cv.has_ground() and cv.tile_ids.size() == CHUNK * CHUNK and _wants_coarse(cv, c, center) != cv.ground_coarse:
		_dirty_terrain[c] = true


## Starts terrain jobs for dirty chunks: chunks with no ground yet first (holes), then the
## nearest to the focus.
## Terrain jobs at once: TERRAIN_JOBS, or while a screenshot loads TERRAIN_JOBS_SHOT within the
## worker threads there are, leaving two for the rest (models, decoratives, far chunks).
func _terrain_job_cap() -> int:
	if _shot_built:
		return clampi(OS.get_processor_count() - 2, TERRAIN_JOBS, TERRAIN_JOBS_SHOT)
	if _dirty.size() + _partial.size() + _prep_jobs.size() >= TERRAIN_BUILD_BACKLOG:
		return 2
	return TERRAIN_JOBS


func _dirty_silo_terrain(pos: Vector2) -> void:
	if not ModelLibrary.rocket_vfx_enhanced:
		return
	var lo := Vector2i(floori((pos.x - 5.0) / float(CHUNK)), floori((pos.y - 5.0) / float(CHUNK)))
	var hi := Vector2i(floori((pos.x + 5.0) / float(CHUNK)), floori((pos.y + 5.0) / float(CHUNK)))
	for cy in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			var cc := Vector2i(cx, cy)
			if chunks.has(cc):
				_dirty_terrain[cc] = true


func _silo_holes_for_chunk(c: Vector2i) -> PackedVector3Array:
	var out := PackedVector3Array()
	if not ModelLibrary.rocket_vfx_enhanced or silo_positions.is_empty():
		return out
	var spec := ModelLibrary.silo_hole_spec("rocket-silo")
	var cut_r := maxf(spec.z + 0.06, 2.1)
	var x0 := float(c.x * CHUNK)
	var z0 := float(c.y * CHUNK)
	var x1 := x0 + float(CHUNK)
	var z1 := z0 + float(CHUNK)
	var hits: Array[Vector3] = []
	for pos: Vector2 in silo_positions.values():
		var hx := pos.x + spec.x
		var hz := pos.y + spec.y
		var near_x := clampf(hx, x0, x1)
		var near_z := clampf(hz, z0, z1)
		if Vector2(hx - near_x, hz - near_z).length() <= cut_r + 1.5:
			hits.append(Vector3(hx, hz, cut_r))
	if hits.size() > 1:
		var cmp := func(a: Vector3, b: Vector3) -> bool:
			return a.x < b.x if a.x != b.x else a.y < b.y
		hits.sort_custom(cmp)
	for h in hits:
		out.append(h)
	return out


func _start_terrain_jobs() -> void:
	if not silo_positions.is_empty():
		var spec_now := ModelLibrary.silo_hole_spec("rocket-silo")
		if spec_now != _silo_hole_spec_seen:
			_silo_hole_spec_seen = spec_now
			for pos: Vector2 in silo_positions.values():
				_dirty_silo_terrain(pos)
	var most := _terrain_job_cap()
	if _dirty_terrain.is_empty() or _terrain_jobs.size() >= most:
		return
	if _gfx_generation != TerrainTextures.generation or _gfx_table.size() != protos.tile_names.size():
		_refresh_gfx_table()
	var center := stream_center()
	var build_busy := _dirty.size() + _partial.size() + _prep_jobs.size() >= TERRAIN_BUILD_BACKLOG
	var order: Array = []
	var tkeys := PackedInt64Array()
	var tcs: Array = []
	for c: Vector2i in _dirty_terrain:
		if _terrain_jobs.has(c):
			continue  # again once the one running is done
		var cv: ChunkView = chunks.get(c)
		# Chunks without ground first, then those with it, those hidden behind the camera after both (I18).
		# When entity builds are backed up, prefer chunks whose entity snapshot is already complete.
		var rank := distance_along(c - center, _wanted_f) + (0 if cv == null or not cv.has_ground() else 10000) \
			+ (20000 if behind_cull.hidden(c) else 0) + (5000 if (build_busy and cv != null and cv.is_incomplete()) else 0)
		if queue_order_old:
			order.append([rank, c])
		else:
			tkeys.append((rank << 20) | tcs.size())
			tcs.append(c)
	if queue_order_old:
		order.sort()
	else:
		# (_rank_order's packed keys: rank << 20 | index, ties by place instead of by coordinate.)
		tkeys.sort()
		order.resize(tkeys.size())
		for i in tkeys.size():
			order[i] = [0, tcs[tkeys[i] & 0xfffff]]
	for entry in order:
		if _terrain_jobs.size() >= most:
			break
		var c: Vector2i = entry[1]
		_dirty_terrain.erase(c)
		var cv: ChunkView = chunks.get(c)
		if cv == null:
			continue
		if cv.tile_ids.size() != CHUNK * CHUNK:
			cv.clear_terrain()
			continue
		var job := TerrainMesher.new()
		job.coord = c
		job.tile_ids = cv.tile_ids
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var n: ChunkView = chunks.get(c + Vector2i(dx, dy))
				job.around.append(n.tile_ids if n != null else PackedInt32Array())
		job.colors = protos.tile_colors
		job.kind_of = protos.tile_is_water
		job.gfx_of = _gfx_table
		job.textured = TerrainTextures.active()
		job.slots = cv.slots
		job.coarse = _wants_coarse(cv, c, center)
		job.silo_holes = PackedVector3Array() if job.coarse else _silo_holes_for_chunk(c)
		var own := hash([cv.tile_ids, job.textured, TerrainTextures.layout, job.coarse, job.silo_holes])
		# Coarse ground doesn't look at its neighbours: only its own tiles change it.
		var sig := own if job.coarse else hash([job.around, job.textured, TerrainTextures.layout, job.silo_holes])
		var kept: Array = _terrain_cache.get(Vector3i(surface_index, c.x, c.y), [])
		if not kept.is_empty() and (int(kept[0]) == sig or (int(kept[3]) == own and _neighbour_missing(job.around))):
			# The same ground round it; or its own ground the same while a neighbour is still on its
			# way, which the kept mesh shows as it was (built again when the neighbour arrives, and
			# taken from here once more if that is unchanged too).
			cv.apply_kept_terrain(kept[1], kept[2], job.coarse)
			terrain_cache_hits += 1
			ChunkView.count("terrain_kept")
			_waiting_gfx.erase(c)
			_on_terrain_applied(c, cv)
			continue
		_terrain_jobs[c] = [WorkerThreadPool.add_task(job.run, false, "terrain"), job, cv, sig, own]


## A chunk's finished terrain mesh into the cache (the newest last, the oldest dropped).
func _keep_terrain(c: Vector2i, sig: int, own: int, cv: ChunkView) -> void:
	var mesh := cv.terrain_mesh()
	if mesh == null:
		return
	var k := Vector3i(surface_index, c.x, c.y)
	_terrain_cache.erase(k)
	_terrain_cache[k] = [sig, mesh, cv.slots, own]
	while _terrain_cache.size() > TERRAIN_CACHE:
		_terrain_cache.erase(_terrain_cache.keys()[0])


## Whether any of a terrain job's 8 neighbours isn't loaded (TerrainMesher.around, the chunk at 4).
static func _neighbour_missing(around: Array) -> bool:
	for i in around.size():
		if i != 4 and (around[i] as PackedInt32Array).is_empty():
			return true
	return false


## How many terrain meshes are kept (tests).
func terrain_cache_size() -> int:
	return _terrain_cache.size()


## Shows the terrain jobs that are done, within a time budget.
func _finish_terrain_jobs() -> void:
	if _terrain_jobs.is_empty():
		FrameBudget.waiting(&"terrain", 0)
		return
	var t0 := Time.get_ticks_usec()
	var allow := FrameBudget.grant(&"terrain")
	for c: Vector2i in _terrain_jobs.keys():
		if allow <= 0 or Time.get_ticks_usec() - t0 > allow:
			break
		var entry: Array = _terrain_jobs[c]
		if not WorkerThreadPool.is_task_completed(entry[0]):
			continue
		WorkerThreadPool.wait_for_task_completion(entry[0])
		_terrain_jobs.erase(c)
		var job: TerrainMesher = entry[1]
		var cv = entry[2]
		if not is_instance_valid(cv) or chunks.get(c) != cv:
			continue  # unloaded meanwhile
		var t1 := Time.get_ticks_usec()
		cv.apply_terrain(job)
		terrain_build_usec += Time.get_ticks_usec() - t1
		_prof("terrain_apply", t1)
		terrain_worker_usec += job.usec
		terrain_builds += 1
		_waiting_gfx.erase(c)
		_on_terrain_applied(c, cv)
		if job.missing.is_empty():
			_keep_terrain(c, int(entry[3]), int(entry[4]), cv)
			continue
		# Drawn in map colours where pictures are missing: read them, and build again when ready.
		_waiting_gfx[c] = job.missing
		for id in job.missing:
			if id < protos.tile_names.size() and TerrainTextures.lookup(protos.tile_names[id]) != null:
				_dirty_terrain[c] = true  # ready already
				_waiting_gfx.erase(c)
				break
	var done := 0
	for entry: Array in _terrain_jobs.values():
		if WorkerThreadPool.is_task_completed(entry[0]):
			done += 1
	FrameBudget.spent(&"terrain", Time.get_ticks_usec() - t0, done)


func _exit_tree() -> void:
	FreeLater.drop()
	_disk_cache.flush_sync()
	_disk_cache.wait_all()
	flush_prep_jobs()
	if _prio_warm_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_prio_warm_task)
		_prio_warm_task = -1
		_prio_warm_out = {}
	for entry in _terrain_jobs.values():
		WorkerThreadPool.wait_for_task_completion(entry[0])
	_terrain_jobs.clear()
	TerrainTextures.finish_all()
	ModelLods.finish_all()
	ModelLibrary.NatureLooks.finish_all()
	PipelineWarm.flush()
	set_joining(false)


## The welcome: this save's models, asked for now (pipeline_warm.gd).
func _on_welcome(msg: Dictionary) -> void:
	PipelineWarm.on_welcome(str(msg.get("sid", "")))
	_ensure_disk_cache()


## Rings round the focus the join's loading screen waits for (front_end.gd).
const JOIN_RINGS := 2


## Every chunk within `rings` of the focus has come and is drawn (the menu backdrop's recording waits
## for it: the first stream after the join's loading screen).
func square_drawn(rings: int) -> bool:
	var center := chunk_of(_focus)
	for dy in range(-rings, rings + 1):
		for dx in range(-rings, rings + 1):
			var c := center + Vector2i(dx, dy)
			var cv: ChunkView = chunks.get(c)
			if cv == null or not cv.loaded or not _drawn(c):
				return false
	return true


## What the join's loading screen still waits for (front_end.gd): chunks within JOIN_RINGS of the
## focus not drawn yet or drawn with models left out, and pipelines still compiling. Models being
## read count too while any near chunk waits for one. 0: ready to play.
func join_left() -> int:
	var n := 0
	var center := chunk_of(_focus)
	for dy in range(-JOIN_RINGS, JOIN_RINGS + 1):
		for dx in range(-JOIN_RINGS, JOIN_RINGS + 1):
			var c := center + Vector2i(dx, dy)
			var cv: ChunkView = chunks.get(c)
			if cv == null or not _drawn(c) or cv.waiting_models:
				n += 1
	if n > 0:
		n += ModelLibrary.pending_count()
	return n + PipelineWarm.pending_count()


## The join's loading screen is up: models are read on more threads meanwhile (nothing is drawn).
func set_joining(on: bool) -> void:
	ModelLibrary.load_jobs = maxi(ModelLibrary.LOAD_JOBS, OS.get_processor_count() - 2) if on else ModelLibrary.LOAD_JOBS


## The entity under a point on the ground (tiles), preferring the smallest selection box,
## and buildings over the ore underneath them.
## The model an entity is drawn with if it is ready, else null (as with no model) while it is made
## on a worker thread: the entity's chunk is drawn again, with entities_changed, once it is.
func ready_mesh(proto: ProtoDB.EntityProto, rec: Rec, dir := 0) -> Mesh:
	if ModelLibrary.entity_ready(proto.name, proto.type, rec.extra, dir):
		return ModelLibrary.mesh_for_entity(proto.name, proto.type, rec.extra, dir)
	var cv: ChunkView = chunks.get(rec.chunk)
	if cv != null:
		cv.waiting_models = true
	return null


func pick(point: Vector2) -> Rec:
	var best: Rec = null
	var best_area := INF
	var center := chunk_of(point)
	var cell := Vector2i(floori(point.x / PICK_CELL), floori(point.y / PICK_CELL))
	var reach := _pick_reach()
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var cv: ChunkView = chunks.get(center + Vector2i(dx, dy))
			if cv == null:
				continue
			# A neighbour's entities reach the point only if it is near that chunk: indexing all nine
			# chunks (a busy one takes several ms) as new ones came under the mouse while walking
			# made 10-40 ms frames.
			if (dx != 0 or dy != 0) and not Rect2(Vector2(cv.coord * CHUNK), Vector2(CHUNK, CHUNK)).grow(reach).has_point(point):
				continue
			for entry: Array in _pick_grid(cv).get(cell, []):
				if (entry[1] as Rect2).has_point(point) and float(entry[2]) < best_area and not (entry[0] as Rec).extra.has("hid"):
					best_area = entry[2]
					best = entry[0]
	return best


## Squares of the pick index, tiles.
const PICK_CELL := 2.0
## Types Factorio gives selection_priority 45 (ground_entity), under the default 50 of machines, inserters, vehicles.
const GROUND_PICK_TYPES := ["transport-belt", "underground-belt", "splitter", "lane-splitter", "loader", "loader-1x1", "linked-belt"]
## How high elevated rails ran before (--elevated-trains=old, rail_planner.gd's ELEVATED_Y), and a ramp's length.
const ELEVATED_HEIGHT := 3.0
const RAMP_LENGTH := 16.0
## The rail index's squares (tiles), and how many frames a changed chunk's index may stay as it was
## (rails rarely change, a busy chunk's other entities often: rebuilt at most every 2 s).
const RAIL_CELL := 4.0
const RAIL_REBUILD_FRAMES := 120
## How far from a rail piece's position its track reaches (tiles): half its length (Factorio's rails'
## collision boxes are generated, their prototypes' boxes are not the track) and a little more.
const RAIL_REACH := {"straight-rail": 1.7, "half-diagonal-rail": 2.5, "curved-rail-a": 2.8, "curved-rail-b": 2.75,
	"legacy-straight-rail": 1.7, "legacy-curved-rail": 4.5}


## The height of the rails at `point` for rolling stock there (H24: trains ran under elevated rails):
## up a ramp by how far along it (as the ramp's model climbs), the elevated track's height
## (ModelLibrary.ELEVATED_TRACK) on elevated rails, 0 on ground rails. Where both pass (a bridge over
## a ground line) `was` decides: the stock stays on the level it was on; with no rail found, `was`.
## Rails are found by their track's reach from a per-chunk index (_rail_grid): their selection boxes,
## which this used before, are 3.4 x 1.6 tiles even on a 16-tile ramp or a curve, so most of a ramp
## and of a curve found no rail and the stock sank to the ground.
func rail_height(point: Vector2, was: float) -> float:
	if ModelLibrary.elevated_old:
		return _rail_height_old(point, was)
	var ground := false
	var elevated := false
	var cell := Vector2i(floori(point.x / RAIL_CELL), floori(point.y / RAIL_CELL))
	var center := chunk_of(point)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var c := center + Vector2i(dx, dy)
			var cv: ChunkView = chunks.get(c)
			if cv == null:
				continue
			if (dx != 0 or dy != 0) and not Rect2(Vector2(c * CHUNK), Vector2(CHUNK, CHUNK)).grow(RAMP_LENGTH * 0.5 + 1.0).has_point(point):
				continue
			for e: Array in _rail_grid(cv).get(cell, []):
				var at: Vector2 = e[1]
				var kind := int(e[0])
				if kind == 2:
					var a := -Wire.direction_yaw(int(e[2]))
					var uphill := Vector2(sin(a), -cos(a))
					var d := point - at
					var along := d.dot(uphill)
					if absf(along) <= RAMP_LENGTH * 0.5 and absf(d.dot(Vector2(-uphill.y, uphill.x))) < 1.0:
						return ramp_track_height(along)
				elif point.distance_squared_to(at) <= float(e[2]):
					if kind == 1:
						elevated = true
					else:
						ground = true
	if elevated and (not ground or was > ModelLibrary.ELEVATED_TRACK * 0.5):
		return ModelLibrary.ELEVATED_TRACK
	if ground:
		return 0.0
	return was


## The track's height on a ramp `along` tiles uphill of its centre: tools/models/railway.py's
## ramp_height (level for the first and last tiles, nearly straight between, eased at both ends).
static func ramp_track_height(along: float) -> float:
	var t := clampf(along / RAMP_LENGTH + 0.5, 0.0, 1.0)
	t = clampf((t - 0.04) / 0.8, 0.0, 1.0)
	return ModelLibrary.ELEVATION * (0.4 * t + 0.6 * t * t * (3.0 - 2.0 * t))


## A chunk's rails and ramps by the RAIL_CELL squares their track reaches: {cell: [[kind (0 ground,
## 1 elevated, 2 ramp), position, reach squared or a ramp's direction]]}. Built when a train asks,
## again when the chunk's entities changed (at most every RAIL_REBUILD_FRAMES).
func _rail_grid(cv: ChunkView) -> Dictionary:
	var frame := Engine.get_process_frames()
	if cv.rail_grid.size() == 3 and (int(cv.rail_grid[0]) == cv.content_rev or frame - int(cv.rail_grid[1]) < RAIL_REBUILD_FRAMES):
		return cv.rail_grid[2]
	var grid := {}
	for r: Rec in cv.entities.values():
		var proto: ProtoDB.EntityProto = protos.entity(r.proto_id)
		if proto == null:
			continue
		var entry: Array
		var reach := 0.0
		if proto.type == "rail-ramp":
			entry = [2, r.pos, r.dir]
			reach = RAMP_LENGTH * 0.5
		elif ModelLibrary.RAIL_TYPES.has(proto.type):
			var base := proto.type.trim_prefix("elevated-")
			reach = float(RAIL_REACH.get(base, 2.8))
			entry = [0 if base == proto.type else 1, r.pos, reach * reach]
		else:
			continue
		var lo := Vector2i(floori((r.pos.x - reach) / RAIL_CELL), floori((r.pos.y - reach) / RAIL_CELL))
		var hi := Vector2i(floori((r.pos.x + reach) / RAIL_CELL), floori((r.pos.y + reach) / RAIL_CELL))
		for y in range(lo.y, hi.y + 1):
			for x in range(lo.x, hi.x + 1):
				var c := Vector2i(x, y)
				if not grid.has(c):
					grid[c] = []
				(grid[c] as Array).append(entry)
	cv.rail_grid = [cv.content_rev, frame, grid]
	return grid


## --elevated-trains=old: rails found by their selection boxes, elevated ones ELEVATED_HEIGHT up,
## a straight ramp, 0 where no rail was found.
func _rail_height_old(point: Vector2, was: float) -> float:
	var ground := false
	var elevated := false
	var center := chunk_of(point)
	var cell := Vector2i(floori(point.x / PICK_CELL), floori(point.y / PICK_CELL))
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var cv: ChunkView = chunks.get(center + Vector2i(dx, dy))
			if cv == null:
				continue
			for entry: Array in _pick_grid(cv).get(cell, []):
				if not (entry[1] as Rect2).has_point(point):
					continue
				var rec: Rec = entry[0]
				var proto: ProtoDB.EntityProto = protos.entity(rec.proto_id)
				if proto == null:
					continue
				if proto.type == "rail-ramp":
					var a := -Wire.direction_yaw(rec.dir)
					var uphill := Vector2(sin(a), -cos(a))
					return ELEVATED_HEIGHT * clampf((point - rec.pos).dot(uphill) / RAMP_LENGTH + 0.5, 0.0, 1.0)
				if proto.name.begins_with("elevated-"):
					elevated = true
				elif ModelLibrary.RAIL_TYPES.has(proto.type):
					ground = true
	if elevated and (not ground or was > ELEVATED_HEIGHT * 0.5):
		return ELEVATED_HEIGHT
	return 0.0


## (stand_height.gd: the belt step-up and api.world.stand_height_at) Every drawn entity whose selection box holds `point`,
## from the pick index (not ones hidden by a prediction).
func recs_at(point: Vector2) -> Array:
	var out: Array = []
	var center := chunk_of(point)
	var cell := Vector2i(floori(point.x / PICK_CELL), floori(point.y / PICK_CELL))
	var reach := _pick_reach()
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var cv: ChunkView = chunks.get(center + Vector2i(dx, dy))
			if cv == null:
				continue
			if (dx != 0 or dy != 0) and not Rect2(Vector2(cv.coord * CHUNK), Vector2(CHUNK, CHUNK)).grow(reach).has_point(point):
				continue
			for entry: Array in _pick_grid(cv).get(cell, []):
				if (entry[1] as Rect2).has_point(point) and not (entry[0] as Rec).extra.has("hid"):
					out.append(entry[0])
	return out


## Every drawn entity whose selection box intersects `rect`, backed by each chunk's pick index
## (checking only cells intersecting `rect`, not hidden by a prediction).
func entities_overlapping(rect: Rect2) -> Array:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return []
	var out: Array = []
	var seen := {}
	var reach := _pick_reach()
	var expanded := rect.grow(reach)
	var c_lo := chunk_of(expanded.position)
	var c_hi := chunk_of(expanded.end)
	var lo := Vector2i(floori(rect.position.x / PICK_CELL), floori(rect.position.y / PICK_CELL))
	var hi := Vector2i(floori(rect.end.x / PICK_CELL), floori(rect.end.y / PICK_CELL))
	for cy in range(c_lo.y, c_hi.y + 1):
		for cx in range(c_lo.x, c_hi.x + 1):
			var cv: ChunkView = chunks.get(Vector2i(cx, cy))
			if cv == null:
				continue
			var grid: Dictionary = _pick_grid(cv)
			for y in range(lo.y, hi.y + 1):
				for x in range(lo.x, hi.x + 1):
					var entries: Variant = grid.get(Vector2i(x, y))
					if not (entries is Array):
						continue
					for entry: Array in (entries as Array):
						var r: Rec = entry[0]
						if seen.has(r) or r.extra.has("hid"):
							continue
						var er: Rect2 = entry[1]
						if er.size.x > 0.0 and er.size.y > 0.0 and er.intersects(rect):
							seen[r] = true
							out.append(r)
	return out


var _reach := [-1, 0.0]  # [entity prototypes counted, the reach]


## How far any entity's selection box reaches from its position (tiles), and a cell more, as an
## entity is kept in the chunk of its position.
func _pick_reach() -> float:
	if int(_reach[0]) != protos.entities.size():
		var most := 0.0
		for proto in protos.entities.values():
			if proto != null:
				most = maxf(most, maxf(maxf(absf(proto.box_min.x), absf(proto.box_min.y)), maxf(absf(proto.box_max.x), absf(proto.box_max.y))))
		_reach = [protos.entities.size(), most + PICK_CELL]
	return float(_reach[1])


## A chunk's entities by the PICK_CELL squares their selection boxes touch, with each box and the
## area pick() ranks it by (smallest first; ore and tile ghosts under the rest). Picking used to
## test every entity in nine chunks every frame (2 ms on a busy base); entities rarely change.
## Built a slice at a time, PICK_BUILD_USEC a frame across chunks: walking with the mouse over the
## view, each new busy chunk under it took 10-27 ms to index in one frame on the owner's save. A
## chunk part-way through picks from what is indexed so far.
func _pick_grid(cv: ChunkView) -> Dictionary:
	var gen := protos.entities.size()
	if cv.pick_grid.size() == 2 and int(cv.pick_grid[0]) == gen:
		return cv.pick_grid[1]
	if cv.pick_grid.size() != 4 or int(cv.pick_grid[0]) != gen:
		cv.pick_grid = [gen, {}, cv.entities.values(), 0]  # [generation, grid, records, next]
	var frame := Engine.get_process_frames()
	if frame != _pick_frame:
		_pick_frame = frame
		_pick_spent = 0
		_pick_allow = FrameBudget.grant(&"pick")
	var started := Time.get_ticks_usec()
	var grid: Dictionary = cv.pick_grid[1]
	var recs: Array = cv.pick_grid[2]
	var i := int(cv.pick_grid[3])
	var allow := _pick_allow if pick_build_usec == PICK_BUILD_USEC else pick_build_usec
	while i < recs.size():
		if (i & 15) == 0 and _pick_spent + Time.get_ticks_usec() - started > allow:
			break
		var rec: Rec = recs[i]
		if rec != null and cv.entities.get(rec.key) == rec:
			_index_pick(grid, rec)
		i += 1
	_pick_spent += Time.get_ticks_usec() - started
	FrameBudget.spent(&"pick", Time.get_ticks_usec() - started, recs.size() - i)
	if i >= recs.size():
		cv.pick_grid = [gen, grid]
	else:
		cv.pick_grid[3] = i
	return grid


var _pick_frame := -1
var _pick_spent := 0
var _pick_allow := PICK_BUILD_USEC
const PICK_BUILD_USEC := 1500
var pick_build_usec := PICK_BUILD_USEC  # tests lift it to compare a whole index


func _pick_grid_add(cv: ChunkView, r: Rec) -> void:
	if cv.pick_grid.is_empty() or r == null:
		return
	var gen := protos.entities.size()
	if (cv.pick_grid.size() != 2 and cv.pick_grid.size() != 4) or int(cv.pick_grid[0]) != gen:
		cv.pick_grid = []
		return
	_index_pick(cv.pick_grid[1] as Dictionary, r)


func _pick_grid_remove(cv: ChunkView, r: Rec) -> void:
	if cv.pick_grid.is_empty() or r == null:
		return
	var gen := protos.entities.size()
	if (cv.pick_grid.size() != 2 and cv.pick_grid.size() != 4) or int(cv.pick_grid[0]) != gen:
		cv.pick_grid = []
		return
	var proto: ProtoDB.EntityProto = protos.entity(r.proto_id)
	if proto == null:
		return
	var rect := _pick_rect(proto, r)
	var grid: Dictionary = cv.pick_grid[1]
	var lo := Vector2i(floori(rect.position.x / PICK_CELL), floori(rect.position.y / PICK_CELL))
	var hi := Vector2i(floori(rect.end.x / PICK_CELL), floori(rect.end.y / PICK_CELL))
	for y in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			var c := Vector2i(x, y)
			var cell_val: Variant = grid.get(c)
			if not (cell_val is Array):
				continue
			var arr: Array = cell_val
			var j := arr.size() - 1
			while j >= 0:
				var entry: Array = arr[j]
				if entry[0] == r:
					arr.remove_at(j)
				j -= 1
			if arr.is_empty():
				grid.erase(c)


func _pick_rect(proto: ProtoDB.EntityProto, r: Rec) -> Rect2:
	# A ghost is picked by the box of what it will build (F6): Factorio's entity-ghost
	# prototype has a box of its own that doesn't fit it.
	var shape := proto
	if proto.type == "entity-ghost" and r.extra.has("gh"):
		var inner: ProtoDB.EntityProto = protos.entity(int(r.extra["gh"]))
		if inner != null:
			shape = inner
	return selection_rect(shape, r.pos, r.dir)


func _index_pick(grid: Dictionary, r: Rec) -> void:
	if r == null:
		return
	var proto: ProtoDB.EntityProto = protos.entity(r.proto_id)
	if proto == null:
		return
	var rect := _pick_rect(proto, r)
	var area := rect.get_area()
	if proto.type == "resource":
		area += 1000.0
	elif proto.type == "tile-ghost":
		area += 2000.0  # under everything else, like the tile it stands for
	elif GROUND_PICK_TYPES.has(proto.type) or ModelLibrary.RAIL_TYPES.has(proto.type):
		area += 500.0  # selection_priority 45 (ground_entity): belts and rails under every machine, inserter and pole
	var entry := [r, rect, area]
	var lo := Vector2i(floori(rect.position.x / PICK_CELL), floori(rect.position.y / PICK_CELL))
	var hi := Vector2i(floori(rect.end.x / PICK_CELL), floori(rect.end.y / PICK_CELL))
	for y in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			var c := Vector2i(x, y)
			if not grid.has(c):
				grid[c] = []
			(grid[c] as Array).append(entry)


## The selection box of `proto` placed at `pos` facing `dir`, in tiles. Directions between the
## four main ones are rounded to the nearest of them.
static func selection_rect(proto: ProtoDB.EntityProto, pos: Vector2, dir: int) -> Rect2:
	return box_rect(proto.box_min, proto.box_max, pos, dir)


## A box (its corners from the centre, facing north) placed at `pos` facing `dir`, in tiles.
static func box_rect(box_min: Vector2, box_max: Vector2, pos: Vector2, dir: int) -> Rect2:
	var a := box_min
	var b := box_max
	match posmod(int(round(dir / 4.0)), 4):
		1:  # east: (x, y) -> (-y, x)
			a = Vector2(-box_max.y, box_min.x)
			b = Vector2(-box_min.y, box_max.x)
		2:  # south: (x, y) -> (-x, -y)
			a = -box_max
			b = -box_min
		3:  # west: (x, y) -> (y, -x)
			a = Vector2(box_min.y, -box_max.x)
			b = Vector2(box_max.y, -box_min.x)
	return Rect2(pos + a, b - a)


## A list as JSON or a binary frame gives it (an Array, or packed: wire_decode.gd), else [].
static func _list(v: Variant) -> Variant:
	return v if v is Array or WireDecode.packed(v) else []
