extends Node3D
## Items on belts near the camera. The mod sends every item's position a few times a second
## (`bi`). Each item, tracked by its unique id, glides from where it is drawn to its new position
## over the time until the next update, so it is drawn one update behind the game.
##
## It glides along its lane (belt_paths.gd): round a curve, through a splitter, out of sight in an
## underground, onto the lane it is side-loaded onto. Gliding in a straight line from one update to
## the next took items off the belts wherever the two weren't on one straight lane (owner's
## play-test: items floating across curves, over splitters and undergrounds, over buildings). The
## belts round the square the items come from are indexed from world.gd's records on the job's
## thread, chunk by chunk as they change.
##
## Lanes that didn't change aren't sent again (`bl` in the hello; belt_items.lua): each part says
## which lane its items came from (`ln`), and an item whose lane wasn't in an update stays where it
## is until its lane comes again or is dropped (`dl`). On a busy base most lanes are backed up and
## hold still, so the mod reads and sends only the few that move.
##
## Thousands of items can be in view, so they are placed on the GPU from records (belt_records.gd,
## belt_path.gdshaderinc): where an item is at one tick, how far it goes (straight, or along its
## lane's path) by another, its turn and lift. Each item keeps its own ticks, so the CPU writes a
## record only when an update changes the item's motion: an item an update finds where its record
## has it (going on, or standing) costs nothing, a steady item's record runs on along its straight
## run past its target (OPEN_UPDATES), and a lane held (not sent) is never looked at. Items missing
## from an update are found from the lanes it sent (State.lane_items), not by looking at every item.
## set_motion() and remove_item() give items' motion from outside (a client-side belt flow).

## The hand-over to the far lane icons (belt_lanes.gd, `lanes`) never leaves a belt bare and
## never draws it twice (owner): an item that falls outside the square an update covers stays,
## held where it is, until its chunk's icons are made (and at most KEEP_UPDATES updates), and the
## icons of a chunk that still has such items stay hidden; both change when a job's result is
## drawn, in the same frame, as does the square the icons are hidden in. Items of a kind whose look
## isn't made yet aren't drawn, so their icons stay shown inside the square until it is.
##
## A stack (a stack inserter puts up to 4 items in one place on a belt: one entry, one unique id;
## `bi` st says its size) is drawn as a pile, as Factorio draws it: the item and up to three more
## copies, each a step higher (the kind's pile_step()), each in a slot of its own (Layer) that
## follows the item's glide.
##
## The work of an update (decoding it, routing the items it changes, writing their records) runs
## on a worker thread (Job), on State that only the job touches while it runs. The main thread
## queues messages, starts a job with them, uploads the record pages it wrote and gives the kinds'
## sizes to the MultiMeshes in a later frame; every frame it only sets the drawn clock.

const ProtoDB := preload("res://scripts/world/protos.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const GameClock := preload("res://scripts/world/game_clock.gd")
const BeltPaths := preload("res://scripts/world/belt_paths.gd")
const WorldMirror := preload("res://scripts/world/world.gd")
const BeltRecords := preload("res://scripts/world/belt_records.gd")

## An item missing from this many updates in a row was taken off the belt; out of sight in an
## underground (the mod sends only what is inside a belt), it comes up at the exit: 120 updates is
## 12 seconds, under the longest underground at a yellow belt's speed.
const MISSING_FRAMES := 2
const MISSING_HIDDEN := 120
## Just above a placeholder belt (0.15 tall), when there is no belt model.
const PLACEHOLDER_HEIGHT := 0.16
## Neighbouring items on a lane are closer than a card is wide, so their cards overlap; at one
## height they fought over every pixel they share (red and green circuits flickering along a belt).
## Each item sits a step higher or lower by its id, so an overlap always resolves the same way.
const LAYER_STEP := 0.006
const LAYERS := 4
## Further than an item travels between updates: it was moved some other way, so don't glide. A turbo
## belt carries an item 1.5 tiles in the 12 ticks between updates on a busy base (belt_items.lua).
const SNAP_DISTANCE := 2.0
## A turbo belt's speed, tiles a tick, with some to spare: when the mod is slowed down (`rate`) the
## updates are further apart (bi p, up to 48 ticks: 6 tiles), so the snap distance grows with them.
const FASTEST_BELT := 0.15
## Ticks behind one gap behind the game's clock items are drawn at, for messages a frame or two late.
const DRAW_MARGIN := 2.0
## And for the job that works an update out: its result is drawn a few frames after the update came
## (on the owner's save a job took 60-140 ms, 4-8 ticks), and until then the items had reached the
## last update's places and stood still, then jumped on (owner: items "laggy", stopping). The
## margin grows to the ticks jobs take (eased: what is drawn slows down meanwhile, never back) and
## shrinks slowly once they are quicker; the glide an update starts begins where it will be drawn.
const JOB_MARGIN_MAX := 30.0
## The margin is this many times the ticks jobs take: the next job's result is drawn a job after
## this one's, so with one the glides of items that don't run on (at a run's end, on curves) ended
## before it came and they stood, then jumped on (jobs of 200 ms, replayed: 1,284 jumps against
## 136 at 1.5; on Zenith Test's 100 ms jobs, live, the same as with one).
static var margin_jobs := 1.5
## Items reach this far past the square an update covers (a belt on its edge is read whole).
const SQUARE_SLACK := 1.0
const STRIDE := ItemCards.STRIDE
const ON_LANE := BeltPaths.ON_LANE
## Belts are indexed this far past the square the items come from (an underground's exit beyond it).
const INDEX_MARGIN := 14.0
## The paths' texture: this many points a row, rows a power of two, at most MAX_ROWS (the code in
## an instance's custom data must stay an exact float: under 2^24).
const PATH_WIDTH := 1024
const MAX_ROWS := 256
## An item still under the ground: two points there, not shown.
const HIDDEN := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
## An item kept outside the square for its chunk's icons (see above) goes after this many updates
## whatever happens (a chunk whose icons never come: no far lanes there).
const KEEP_UPDATES := 40
## An update that finds an item where its record has it then (tiles) leaves the record as it is: an
## item going on as before, or standing, costs no write.
const KEEP_RECORD := 0.01
## A steady item (its glide as fast as the belt moved it) goes on along its straight run past where
## the update put it, this many updates' worth (at most to the run's end), so the next updates that
## find it on its way write nothing; under OPEN_LEFT left, its record is made longer. The game's next
## update comes before the drawn clock reaches the place (items are drawn one update behind), so an
## item that stopped meanwhile is stopped before it is drawn past where it stood.
const OPEN_UPDATES := 8.0
const OPEN_LEFT := 3.0
## How far (tiles) an opened record may move the glide's start to run through the update's place at
## the belt's speed: under this the step can't be seen.
const OPEN_JUMP := 0.03
## Factorio's belt speeds (tiles a tick: 15, 30, 45, 60 items a second). An item's speed from two
## updates' places, each to 1/256 tile, is off by up to 0.0007 tiles a tick, which over an open
## record's 48 ticks is more than KEEP_RECORD; within 3% of one of these it is that one.
const BELT_SPEEDS := [0.03125, 0.0625, 0.09375, 0.125]
## Items in 3D's cap is worked out again at least every this many jobs.
const CAP_EVERY := 4
## The lane items given by set_motion() are in: never sent by the mod, never counted missing.
const EXTERNAL := -2
## Factorio's max_belt_stack_size (utility constants): the highest pile.
const MAX_STACK := 4
## How close behind the item in front an item on a belt's lane stops (Factorio's item spacing).
const GAP := 0.25
## An item that waited this many updates at a plain lane's front, with room in the watched lane in
## front which was sent each time without it, isn't coming: taken off there (an inserter took it
## between the mod's looks) or never there (a guess that ran ahead).
const STUCK_UPDATES := 3
## Less than this far (tiles) is standing for an item on a plain lane: the slowest belt moves an
## item 0.03 tiles a tick.
const STANDING := 0.02
## Factorio's position step on a belt's lane (FFF #176, belt-public-rules: a straight lane is 256).
const STEP := 1.0 / 256.0
## A drift check (bi pc) agrees within this (tiles), and the way the lane's belt moves while it was
## read early and until the next update; a lane asked for again isn't asked again within ASK_AGAIN.
const DRIFT := 0.06
const ASK_AGAIN := 8
## A pile's copies turn this much more each, so a pile of models doesn't look like one tall block
## (owner: back to 0.1.2's piles after trying Factorio's neat, straight ones).
const PILE_TURN := 0.45
## Tiles past the Items in 3D cap's edge a model stays a model (no flipping at the edge).
const CAP_SLACK := 1.5
## How near (tiles) a new item must be to where a missing one would be now to be that item (Job's
## _adopt()): under half a full lane's gap, so it never takes its neighbour's place.
const ADOPT_DISTANCE := 0.12
## A job's glides begin at its fold tick, where each item will be drawn when its result is: it stops
## there and goes on to the update's place. Drawn before the drawn clock reached that tick (the job
## was quicker than _job_ticks, or the clock slowed meanwhile: its margin growing, a longer gap eased
## in), every item it changed jumped ahead to its fold place and stood there until the clock caught up
## (owner: items "jump around"; on Zenith Test's busy belts 7 ticks ahead, 0.2-0.5 tiles, each job).
## So a finished job's result waits for the drawn clock to reach its fold tick (within FOLD_SLACK
## ticks, under a frame), at most HOLD_USEC.
const FOLD_SLACK := 0.25
## The drawn clock's least pace (game ticks a tick) while its gap and margin grow.
const MIN_PACE := 0.25
const HOLD_USEC := 400000
## Ticks a glide whose update was older than its fold tick takes to catch up (Job._write()).
const CATCH_TICKS := 2.0


class Item:
	var uid := 0  # its unique id (state.items' key)
	var item_id := 0
	var key := 0  # its kind: item_id, or ItemCards.icon_key() past the Items in 3D cap (_cap_models())
	var c := 1.0  # cosine and sine of its turn
	var s := 0.0
	var from := Vector3.ZERO  # where it was drawn when the last update began
	var step := Vector3.ZERO  # how far it glides until the next
	var slot := -1  # in its kind's MultiMesh, or -1 before it has one
	var seen := -1  # the update (State.frame) it was last in
	var missed := 0  # updates missed in a row
	var lane := 0  # the lane (bi ln key) it was last sent in, 0 none: held while that lane isn't sent
	var hint: BeltPaths.Belt = null  # the belt `from` is on, where the next route starts looking
	## Its glide along its lane's path when that isn't straight: points (x, y, z offsets from
	## `from`, and 1 where it shows), the route's pieces and length (where it is part way).
	var path := PackedFloat32Array()
	var segs: Array = []
	var length := 0.0
	## Tiles a tick along its lane in its last glide that wasn't along a known run (to carry it on
	## under the ground: it reaches an underground's entrance off its run).
	var speed := 0.0
	## Under the ground: which lane of its entrance (hint) it is on, and how far along the hidden
	## stretch (-1 not known), so it is carried on without looking for it.
	var under_lane := 0
	var under_s := -1.0
	## On a run of straight belts (graph generation `run_gen`, else -1): whether it runs north-south
	## (else east-west), and the stretch of that axis from where the item joined it to the run's end.
	## While it stays on that line (belts face 4 ways: its other coordinate stays put) and within
	## the stretch, it glides straight without looking anything up: most of a dense base's items,
	## every update.
	var run_z := false
	var run_min := 0.0
	var run_max := 0.0
	var run_gen := -1
	## The stack's size (bi st, 1 when not listed) and its copies above it, one Layer each.
	var count := 1
	var layers: Array = []
	var kept := 0  # updates it has been kept outside the square, waiting for its chunk's icons
	## Its glide in the last update it was in, when straight: what it goes on with in an update
	## it is missing from (carry_missing()).
	var last_step := Vector3.ZERO
	## Its path's place in the paths' texture in the _write() numbered code_at (its layers share it).
	var code := 0.0
	var code_at := -1
	## Where the last update put it, on which tick, and how fast it went there (tiles a tick): where
	## it would be now, for handing it over to an item that takes its place (Job._adopt()).
	var target := Vector3.ZERO
	var target_tick := -1
	var vel := Vector3.ZERO
	## Updates in a row it waited on a plain lane's front with room in the watched lane in front,
	## which was sent without it (_move_plains()).
	var stuck := 0
	## Its record's ticks: it is at `from` at t_from and `from` + `step` (or along `path`) at t_to,
	## and stands there after. t_to < 0: planned in the job that is running, to arrive at its last
	## update's tick (Job._write()). An item is folded (`from` moved where it is drawn at the job's
	## fold tick, step 0) only when an update changes it (Job._fold(), once an update): one the
	## update leaves alone keeps its record.
	var t_from := 0.0
	var t_to := 0.0
	var folded := -1  # the update (State.frame) it was last folded in
	var open := false  # its record runs on past its target along its straight run (OPEN_UPDATES)
	var dirty := false  # its record needs writing (State.dirty lists it)
	var in_lane := false  # in State.lane_items[lane]
	var stamp := 0  # the _write() its record was last written in (written once a job)


## A lane the mod sends as a group (`bi` bg, belt_items.lua): packed end to end with items of one
## kind, a gap apart. The mod says where its front item is when it moves (`bm`); its items are made
## here, in each update it moved in (or was sent in), a gap apart from there to the lane's end.
class Group:
	var item_id := 0
	var stack := 1
	var at0 := Vector2.ZERO  # where line position 0 is (where items leave)
	var at1 := Vector2.ZERO  # and 1 (where they come in)
	var gap := 0.25
	var v := 0.0  # the belt's speed, line positions a tick
	var front := 0.0  # its front item's line position, below one gap
	## How far its items have gone (line positions) since it was made: an item's slot (its unique
	## id) stays the same as it moves along.
	var moved := 0.0
	var speed := -1.0  # line positions a tick in its last move (-1: none yet, taken as the belt's)
	var moved_at := -1  # the tick of that move
	var went := 0.0  # and how far it went then (line positions)
	## Sent or moved since its items were last made. A group that didn't move isn't made again: its
	## items are held where they are, as a lane not sent is (most of a busy base's groups, most
	## updates: making them all again was half of a job's time on the owner's save).
	var dirty := true
	var stood := true  # its items were told they stand still (_stand_group_items) since it last moved


## A plain lane (`bi` pl, belt_items.lua's straight runs): a straight belt's lane in a line of
## straight belts facing one way that nothing but the lanes either side puts items on or takes them
## off. The mod sends its items once (and again now and then) and moves them no more: they are moved
## here (Job._move_plains()), as Factorio moves them, at the belt's speed until they are a gap behind
## the item in front, or behind the lane in front's hindmost item. What the watched lanes either side
## hold (sent whenever their check changes, held when it doesn't) says what came in and what went on.
class Plain:
	var up := 0  # the lane behind's key
	var down := 0  # and the one in front's
	var at0 := Vector2.ZERO  # where line position 0 is (where items leave)
	var at1 := Vector2.ZERO  # and 1 (where they come in)
	var v := 0.0  # the belt's speed, line positions a tick


## One copy in a pile, k steps above its item, in a slot of the item's kind.
class Layer:
	var it: Item
	var k := 1
	var slot := -1
	var stamp := 0
	var c := 1.0
	var s := 0.0


class Kind:
	var slots := []  # Item or null, by slot
	var free: Array[int] = []  # empty slots below slots.size()
	var fresh := []  # Items or Layers whose records must be written (new in their slot)
	var emptied: Array[int] = []  # slots to hide
	var base := -1  # its run of records (BeltRecords), one a slot, cap of them
	var cap := 0
	var told := Vector3i(-1, -1, -1)  # base, slots drawn and cap the main thread was last given
	var lift := Vector3.ZERO  # item_cards.gd's lift(), turns() and pile_step() for this kind, once known
	var turns := false
	var pile := 0.07
	var known := false


## Everything the jobs work on. The main thread reads it only while no job runs.
class State:
	var items := {}  # unique id -> Item
	var kinds := {}  # kind key (Item.key) -> Kind
	var frame := 0  # updates begun
	var tick := -1  # the game tick of the update being received
	var height := PLACEHOLDER_HEIGHT
	## The square the mod read the update round (bi fx, fy, fr): centre x, y and half side in
	## tiles; z < 0 before a mod that says so has sent one.
	var square := Vector3(0.0, 0.0, -1.0)
	## Ticks until the next update (bi p), or 0 when the mod doesn't say.
	var period := 0
	var snap := SNAP_DISTANCE
	var graph := BeltPaths.Graph.new()
	## Lane key -> the update (frame) it was last sent in. An item of a lane not sent in an update
	## is held: it stays where it is, not counted missing.
	var lane_frame := {}
	## Chunks with items kept outside the square, waiting for their far icons (Job.held_chunks).
	var held_chunks := {}
	## Lane key -> Group, for the lanes the mod sends as groups.
	var groups := {}
	## The update whose items were last made for the groups and handed over (Job._end_update()), and
	## the tick of the update before the one being received.
	var ended_tick := -1
	var last_tick := -1
	## Unique ids of the items new in the update being received.
	var fresh_ids: Array = []
	## Of those, groups' new items not made yet: unique id -> [item id, place, lane key, stack,
	## velocity]. Most are the item in front taking its next lane (_adopt() hands it over), so an
	## Item is made only for those that take no one's place (making each and then dropping it was
	## the largest part of a busy base's groups).
	var pending := {}
	## Lane key -> Plain for the lanes the mod has the client move (bi pl), and the lanes the update
	## being received names in ln and in pl (a lane in ln and not pl is no longer plain).
	var plains := {}
	var ln_now := {}
	var pl_now := {}
	## The plain lanes' chains (_chains()): each from its front lane back, and lane key -> [chain,
	## place in it]; made again when plains changes (plains_gen).
	var chains: Array = []
	var chain_of := {}
	var plains_gen := 0
	var chains_gen := -1
	## Chains whose items all stood still at their last pass and that nothing has touched since (no
	## lane of theirs, nor the lanes either side, sent): not gone through, their items held (_held()).
	## On the save at its busy belts most chains are backed up, most updates.
	var asleep := {}
	## Plain lanes' drift checks in the update being received (bi pc, flat), and lane key -> the update
	## it was last asked for again (`bre`), so it isn't asked again before it could have come.
	var checks_now: Array = []
	var asked := {}
	## The items' records (belt_records.gd), and the items whose records must be written.
	var records := BeltRecords.new()
	var dirty: Array = []
	## Items with a path drawn from the paths' texture, which is made again each job: their records
	## are written each job (the few that turn). Unique id -> Item.
	var pathed := {}
	## The items seen in the update being received, and those missing from the last (carry_missing()).
	var seen_now: Array = []
	var missing_now: Array = []
	## The drawn tick when the running job's result will be drawn: where folded items are taken from.
	var fold_tick := 0.0
	## Lane key -> {Item: true}: the items last sent in each lane (0: in none), so an update looks only
	## at the lanes it sent (_missing_pass()), never at every item.
	var lane_items := {}
	var sent_now: Array = []  # lanes sent in the update being received (bi ln, groups made)
	var missing_set := {}  # Item -> true: missing from an update, still counted
	var kept := {}  # Item -> true: outside the square, waiting for their chunk's far icons
	var capped_square := Vector3(0.0, 0.0, -2.0)  # the square Items in 3D's cap was last worked out for
	var cap_jobs := 0
	var capped_at := -2  # the cap (ItemCards.model_cap) then


## One job: the messages queued since the last, applied to State on a worker thread.
class Job:
	var state: State
	var msgs: Array = []
	## How far the items will be along their glide when the result is drawn: an update that begins
	## folds it into where each item is (it stops where it is drawn and glides on from there).
	var fold := 0.0
	var fold_tick := 0.0  # the drawn tick then, where the new glide starts
	var started_usec := 0  # when the main thread started it
	var done_usec := 0  # when the main thread saw it finished (its result may wait: HOLD_USEC)
	var full := false  # every slot written again (the MultiMeshes were dropped)
	var known := {}  # kind key -> [lift, turns, pile step] for kinds item_cards.gd has made
	var model_cap := -1  # ItemCards.model_cap when the job was made
	var watch: Array = []  # unique ids whose positions position_of() wants
	var watch_all := false  # every item's (belt_path_probe.gd: items new this update too)
	## Chunks whose far icons are made (belt_lanes.gd), or null with far icons off: items outside
	## the square go at once.
	var far_built = null
	var kinds = null  # belt prototypes (BeltPaths.Graph.kinds) when they changed
	var index: Array = []  # [chunk, its entity records, whole] to index
	var drops: Array = []  # chunks no longer indexed
	# Results
	var began := false  # an update began: its glide starts when the result is drawn
	var updates := 0  # updates begun after one already received
	var first_tick := -1  # the tick of the first update begun, and of the last one
	var last_tick := -1
	var prev_tick := -1  # the tick before the first one begun
	var written: Array = []  # [kind key, first record, items drawn, capacity] for kinds whose run changed
	var pages := {}  # BeltRecords.take_pages(): record pages to upload
	var clock_base := -1.0  # the records' ticks are from this tick
	var kept_records := 0  # items an update found where their records had them (nothing written)
	var handle_usec := 0  # decoding the messages and updating their items (less _end_update())
	var missing_usec := 0  # finding the missing items (_missing_pass()), handing over (_adopt())
	var adopt_usec := 0
	var cap_usec := 0  # Items in 3D's cap
	var records_written := 0
	var unknown: Array = []  # item ids whose looks item_cards.gd must make first
	var count := 0
	var positions := {}  # unique id -> [from, step, path]
	var square := Vector3(0.0, 0.0, -1.0)
	var paths: Image = null  # the paths' points, when some item has one
	var usec := 0  # how long run() took
	var index_usec := 0  # of which indexing belts
	var write_usec := 0  # and writing the buffers
	var updated := 0  # items in the job's messages (those not routed, fresh or put somewhere went on along a known run)
	var fresh := 0  # items new to the client, and items missing from an update
	var missing := 0
	var held := 0  # items kept in place because their lane wasn't sent (bl)
	var adopted := 0  # items handed over to the item that took their place (_adopt())
	var group_lanes := {}  # the groups' lanes (_lane_cell()), this update, for _glide_in()
	var glided_in := 0  # groups' new items that took no one's place, glided in from behind (_adopt())
	var groups := 0  # lanes sent as groups
	var plains := 0  # and as plain lanes, moved here
	var held_chunks := {}  # chunks with items kept outside the square, waiting for their icons
	## Glides by how they went: belts not known (straight, as before), straight along a lane, along a
	## lane's path, put where they are (not reachable), and moved too far to glide.
	var routes := PackedInt32Array([0, 0, 0, 0, 0])
	var moved := 0  # items moved here along plain lanes (_move_plains())
	var resend: Array = []  # plain lanes whose drift check differed from what is here (`bre`)
	var drifted := 0
	## Plain chains' items let go, by why: sent again without it, chain full, into a group, stuck.
	var let_go := PackedInt32Array([0, 0, 0, 0])
	var plain_lanes := 0
	var plain_usec := 0
	var chains_usec := 0  # of which making the chains again
	var route_usec := 0  # of which routing items not on a known run, and folding glides as updates begin
	var fold_usec := 0
	var end_usec := 0  # making the groups' items and handing items over (_end_update), and carrying missing ones on
	var groups_usec := 0  # of which making the groups' items
	static var debug_delay_usec := 0
	var carry_usec := 0
	static var hidden_path := PackedFloat32Array(HIDDEN)  # shared, never written to
	var gen := -1  # the graph's generation in this job (the belts don't change while it runs)
	static var _writes := 0  # numbers each _write(), for Item.code_at
	var _spare: Array = []  # groups' items left out of the update (_missing_pass())
	var latest := {}  # lane key -> the tick of the last update in this job that sends it (_find_latest())
	var passed := 0  # items passed over: their lane comes again later in the job

	func run() -> void:
		var t0 := Time.get_ticks_usec()
		state.fold_tick = fold_tick
		prev_tick = state.tick
		var g := state.graph
		if kinds != null:
			g.kinds = kinds
		for c in drops:
			g.drop(c)
		for e: Array in index:
			g.index(e[0], e[1], e[2])
		gen = g.generation
		index_usec = Time.get_ticks_usec() - t0
		var th := Time.get_ticks_usec()
		_find_latest()
		for msg: Dictionary in msgs:
			_handle(msg)
		handle_usec = Time.get_ticks_usec() - th - end_usec
		if state.tick >= 0 and state.ended_tick != state.tick:
			_end_update()
		var tc := Time.get_ticks_usec()
		if began:
			carry_missing()
			var tm := Time.get_ticks_usec()
			# Items in 3D's cap: when the square moved, else every CAP_EVERY jobs (new items come as
			# models meanwhile; sorting every item each job cost 15 ms at 24,000 items).
			if model_cap != state.capped_at or (model_cap >= 0 and (state.square != state.capped_square or state.cap_jobs >= CAP_EVERY)):
				state.capped_square = state.square
				state.capped_at = model_cap
				state.cap_jobs = 0
				_cap_models()
			state.cap_jobs += 1
			cap_usec = Time.get_ticks_usec() - tm
		carry_usec = Time.get_ticks_usec() - tc - cap_usec
		var t1 := Time.get_ticks_usec()
		_write()
		write_usec = Time.get_ticks_usec() - t1
		count = state.items.size()
		groups = state.groups.size()
		plains = state.plains.size()
		square = state.square
		held_chunks = state.held_chunks.duplicate()
		for uid in (state.items.keys() if watch_all else watch):
			var it: Item = state.items.get(uid)
			if it != null:
				positions[uid] = [it.from, it.step, it.path, it.t_from, it.t_to]
		clock_base = state.records.base
		if debug_delay_usec > 0:
			OS.delay_usec(debug_delay_usec)  # (belt_stream_replay.gd --job-delay: a slower PC's jobs)
		usec = Time.get_ticks_usec() - t0

	## A job behind the game holds several updates: a lane's items are applied only from the last
	## update that sent it (earlier sendings are passed over, as held), so a job costs what the latest
	## state costs, not that times the updates it holds (lanes: `bl`, bi ln).
	func _find_latest() -> void:
		latest = {}
		var ticks := {}
		for msg: Dictionary in msgs:
			if msg.get("t") == "bi":
				ticks[int(msg.get("k", 0))] = true
		if ticks.size() < 2:
			return
		for msg: Dictionary in msgs:
			var ln = msg.get("ln")
			if msg.get("t") != "bi" or not (ln is Array):
				continue
			var k := int(msg.get("k", 0))
			for j in range(0, (ln as Array).size() - 1, 2):
				var key := int(ln[j])
				if int(latest.get(key, -1)) < k:
					latest[key] = k

	## One part of an update: {t: "bi", k: tick, part, parts, l: [unique id, item id, x, y, ...]}.
	## With z = 1 (we ask for it in the hello) every number is the difference from the item before it.
	func _handle(msg: Dictionary) -> void:
		if msg.get("t") == "motion":
			_motion(msg)
			return
		var k := int(msg.get("k", 0))
		var sq := state.square
		if msg.has("fr"):
			sq = Vector3(int(msg.get("fx", 0)) / 256.0, int(msg.get("fy", 0)) / 256.0, int(msg.get("fr", 0)))
		if k != state.tick:
			if state.records.base < 0.0:
				state.records.base = float(k) - 600.0  # folds may come a little before the first tick
			if state.tick >= 0 and state.ended_tick != state.tick:
				_end_update()
			state.last_tick = state.tick
			var tb := Time.get_ticks_usec()
			_begin_frame(sq)
			fold_usec += Time.get_ticks_usec() - tb
			state.tick = k
			if first_tick < 0:
				first_tick = k
			last_tick = k
			state.period = int(msg.get("p", 0))
			state.snap = maxf(SNAP_DISTANCE, state.period * FASTEST_BELT)
		state.square = sq
		var list = msg.get("l")
		if not (list is Array):
			return
		var deltas := int(msg.get("z", 0)) == 1
		# Which lane each run of items came from: [key, count, ...]; every lane named was sent now.
		var ln = msg.get("ln")
		var by_lane := ln is Array
		var run := 0
		var left := 0
		var lane := 0
		if by_lane:
			for j in range(0, (ln as Array).size() - 1, 2):
				# Sent as items: no longer a group.
				state.groups.erase(int(ln[j]))
				state.ln_now[int(ln[j])] = true
				if int(latest.get(int(ln[j]), k)) > k:
					continue  # sent again later in this job: held here
				state.lane_frame[int(ln[j])] = state.frame
				state.sent_now.append(int(ln[j]))
		var pl = msg.get("pl")
		if pl is Array:
			_add_plains(pl)
		var pc = msg.get("pc")
		if pc is Array:
			state.checks_now.append_array(pc)
		var dl = msg.get("dl")
		if dl is Array and not (dl as Array).is_empty():
			_drop_lanes(dl)
		# Moves before groups: a group sent again (a refresh) comes with its move when it moved.
		var bm = msg.get("bm")
		if bm is Array:
			for j in range(0, (bm as Array).size() - 2, 3):
				var g: Group = state.groups.get(int(bm[j]))
				if g != null:
					_move_group(g, int(bm[j + 1]) / 256.0, k, int(bm[j + 2]))
		var bg = msg.get("bg")
		if bg is Array:
			_add_groups(bg)
		# Stacks' sizes by unique id; every item of the part not listed is a single one.
		var sizes := {}
		var st = msg.get("st")
		if st is Array:
			for j in range(0, (st as Array).size() - 1, 2):
				sizes[int(st[j])] = int(st[j + 1])
		var uid := 0
		var item_id := 0
		var x := 0
		var y := 0
		var i := 0
		var height := state.height
		var items := state.items
		var frame := state.frame
		var t := float(k)
		var open_left := OPEN_LEFT * maxf(state.period, 6.0)
		var no_kept := state.kept.is_empty()
		var no_sizes := sizes.is_empty()
		while i + 3 < list.size():
			if deltas:
				uid += int(list[i])
				item_id += int(list[i + 1])
				x += int(list[i + 2])
				y += int(list[i + 3])
			else:
				uid = int(list[i])
				item_id = int(list[i + 1])
				x = int(list[i + 2])
				y = int(list[i + 3])
			if by_lane:
				while left == 0 and run + 1 < (ln as Array).size():
					lane = int(ln[run])
					left = int(ln[run + 1])
					run += 2
				if left > 0:
					left -= 1
				else:
					lane = 0
				if lane != 0 and int(latest.get(lane, k)) > k:
					passed += 1
					i += 4
					continue
			var pos := Vector3(x / 256.0, height + LAYER_STEP * posmod(uid, LAYERS), y / 256.0)
			var n := 1 if no_sizes else clampi(int(sizes.get(uid, 1)), 1, MAX_STACK)
			i += 4
			# Most items, most updates: going on as their record says (_update()'s KEEP_RECORD case
			# and _set_count() with nothing to do, worked out here without their calls).
			var it: Item = items.get(uid)
			if it != null and no_kept and it.in_lane and it.lane == lane and it.folded != frame and it.t_to >= 0.0 				and it.item_id == item_id and it.count == n and it.layers.size() == n - 1 and it.slot >= 0 and it.path.is_empty() 				and (not it.open or it.t_to - k >= open_left):
				var rp := it.from
				if it.step != Vector3.ZERO:
					rp += it.step * (1.0 if it.t_to <= it.t_from else clampf((t - it.t_from) / (it.t_to - it.t_from), 0.0, 1.0))
				if rp.distance_squared_to(pos) < KEEP_RECORD * KEEP_RECORD:
					it.seen = frame
					it.missed = 0
					if it.target_tick >= 0 and k > it.target_tick:
						var went := pos - it.target
						it.vel = _belt_speed(went / float(k - it.target_tick)) if went.length() < state.snap else Vector3.ZERO
					it.last_step = pos - it.target
					it.target = pos
					it.target_tick = k
					kept_records += 1
					continue
			it = _update(uid, item_id, pos, lane)
			_set_count(it, n)
		updated += list.size() / 4

	## Items the update left out go on at their last pace along the straight run they are on,
	## instead of stopping. The bridge reads
	## belts over several ticks on a busy base (Smooth belt items off, which Hold 60 UPS does under
	## load), so an item moving from a belt read later to one read earlier is in neither reading; it
	## stopped for an update and then jumped to where it was (owner: items "stop and jump around").
	## An item that was in the update keeps its new glide as its pace for next time. Held items
	## (their lane not sent: bl) stay still, as their belt is.
	func carry_missing() -> void:
		for it: Item in state.seen_now:
			if it.seen == state.frame and it.folded == state.frame:
				it.last_step = it.step if it.path.is_empty() else Vector3.ZERO
		for it: Item in state.missing_now:
			if it.seen != state.frame and state.items.get(it.uid) == it and it.path.is_empty() and not _under(it) 					and _stays_on_run(it, it.from + it.last_step):
				it.step = it.last_step
				_mark(it)

	## Whether `to` is still on the straight run of belts the item is on (a known run, this graph):
	## carried on past its end it would leave the belt where it turns.
	func _stays_on_run(it: Item, to: Vector3) -> bool:
		if state.graph.tiles.is_empty():
			return true  # belts not known (tests): items glide straight anyway
		if it.run_gen != gen:
			return false
		if it.run_z:
			return absf(to.x - it.from.x) <= ON_LANE and to.z >= it.run_min and to.z <= it.run_max
		return absf(to.z - it.from.z) <= ON_LANE and to.x >= it.run_min and to.x <= it.run_max

	## Whether an item missing from the last update was held there: its lane wasn't sent, and the
	## item was in that lane's last sending (one that left the lane since is missing).
	func _held(it: Item) -> bool:
		if state.plains.has(it.lane):
			# Moved here (_move_plains()): held only on a chain asleep; else one not moved is gone.
			var c = state.chain_of.get(it.lane)
			return c != null and state.asleep.has(int(c[0]))
		var f = state.lane_frame.get(it.lane)
		return f != null and int(f) != state.frame and it.seen >= int(f)

	## Lanes no longer read (out of the square, their belt gone): their items go at once.
	func _drop_lanes(keys: Array) -> void:
		var drop := {}
		for k in keys:
			drop[int(k)] = true
			state.lane_frame.erase(int(k))
			state.groups.erase(int(k))
			if state.plains.erase(int(k)):
				state.plains_gen += 1
		var gone: Array = []
		for k in drop:
			var members: Dictionary = state.lane_items.get(k, {})
			for it: Item in members.keys():
				if _wait_for_icons(it, _at(it, state.fold_tick)):
					_set_lane(it, 0)
					state.kept[it] = true
				else:
					gone.append(it.uid)
		for uid in gone:
			_remove(uid)

	## `pl`: [lane key, the lane behind's key, the one in front's, x, y of line position 0, x, y of 1
	## (1/256 tile), the belt's speed (line positions a tick, 1/65536), ...]: lanes whose items are
	## moved here from now on (their items come in ln as any lane's).
	func _add_plains(pl: Array) -> void:
		for j in range(0, pl.size() - 7, 8):
			var key := int(pl[j])
			var p := Plain.new()
			p.up = int(pl[j + 1])
			p.down = int(pl[j + 2])
			p.at0 = Vector2(int(pl[j + 3]), int(pl[j + 4])) / 256.0
			p.at1 = Vector2(int(pl[j + 5]), int(pl[j + 6])) / 256.0
			p.v = int(pl[j + 7]) / 65536.0
			var old: Plain = state.plains.get(key)
			if old == null or old.up != p.up or old.down != p.down:
				state.plains_gen += 1
			state.plains[key] = p
			state.pl_now[key] = true

	## Whether an item outside the square stays (held) until its chunk's far icons are made.
	func _wait_for_icons(it: Item, at: Vector3) -> bool:
		if far_built == null or it.kept >= KEEP_UPDATES:
			return false
		var c := Vector2i(floori(at.x / 32.0), floori(at.z / 32.0))
		if (far_built as Dictionary).has(c):
			return false
		state.held_chunks[c] = true
		return true

	## `bg`: [lane key, item id, x, y of line position 0, x, y of 1 (1/256 tile), front item's line
	## position (1/256), gap (1/256), belt speed (line positions a tick, 1/65536), stack size, ...].
	## A lane sent again as a group (a refresh) goes on from where it was, its items kept; its front
	## is put where the mod says only if they differ (moves missed: bi isn't sent again).
	func _add_groups(bg: Array) -> void:
		for j in range(0, bg.size() - 9, 10):
			var key := int(bg[j])
			var front := int(bg[j + 6]) / 256.0
			var gap := int(bg[j + 7]) / 256.0
			var g: Group = state.groups.get(key)
			var again := g != null and is_equal_approx(g.gap, gap)
			if not again:
				g = Group.new()
				g.gap = gap
				g.front = front
				state.groups[key] = g
			g.item_id = int(bg[j + 1])
			g.at0 = Vector2(int(bg[j + 2]), int(bg[j + 3])) / 256.0
			g.at1 = Vector2(int(bg[j + 4]), int(bg[j + 5])) / 256.0
			g.v = int(bg[j + 8]) / 65536.0
			g.stack = clampi(int(bg[j + 9]), 1, MAX_STACK)
			g.dirty = true
			if again and not is_equal_approx(g.front, front):
				g.moved += fposmod(g.front - front, gap)
				g.front = front

	## `bm`: the group's front item is at `front` now (tick k), `since` ticks after the mod last
	## looked (0: not said, since the update before). It moved some way, which the place says to
	## within whole gaps (packed, it looks the same): the way nearest its last pace that the belt's
	## speed allows in that time.
	func _move_group(g: Group, front: float, k: int, since := 0) -> void:
		var dt := float(since)
		if since <= 0:
			dt = float(maxi(1, k - state.last_tick)) if state.last_tick >= 0 else float(maxi(1, state.period))
		var part := fposmod(g.front - front, g.gap)
		var most := g.v * dt
		var guess := (g.speed if g.speed >= 0.0 else g.v) * dt
		var whole := clampi(roundi((guess - part) / g.gap), 0, maxi(0, floori((most - part) / g.gap + 0.01)))
		var went := part + whole * g.gap
		g.moved += went
		g.front = front
		g.speed = went / dt
		g.moved_at = k
		g.went = went
		g.dirty = true

	## Once an update has all come: the items of the groups that moved or were sent made where they
	## are now (the others held where they are, Group.dirty), then items handed over where one took
	## another's place, and the groups' items no longer on their lanes taken off.
	func _end_update() -> void:
		var te := Time.get_ticks_usec()
		state.ended_tick = state.tick
		var sq := state.square
		var edge := sq.z + SQUARE_SLACK
		var outside: Array = []
		group_lanes = {}
		var tg := Time.get_ticks_usec()
		for key in state.groups:
			var g: Group = state.groups[key]
			var mid := (g.at0 + g.at1) * 0.5
			group_lanes[_lane_cell(mid, g.at0 - g.at1)] = true
			if sq.z >= 0.0 and (absf(mid.x - sq.x) > edge or absf(mid.y - sq.y) > edge):
				outside.append(key)
			elif g.dirty:
				g.dirty = false
				g.stood = false
				_make_group_items(int(key), g)
			elif not g.stood:
				g.stood = true
				_stand_group_items(int(key), g)
		groups_usec += Time.get_ticks_usec() - tg
		for key in outside:
			state.groups.erase(key)
		# Lanes sent as items and not as plain lanes are watched again (something was built there).
		for key in state.ln_now:
			if not state.pl_now.has(key):
				if state.plains.erase(key):
					state.plains_gen += 1
		var tp := Time.get_ticks_usec()
		_move_plains()
		_drift_checks()
		plain_usec += Time.get_ticks_usec() - tp
		state.ln_now = {}
		state.pl_now = {}
		var tm := Time.get_ticks_usec()
		_missing_pass()
		var ta := Time.get_ticks_usec()
		missing_usec += ta - tm
		_adopt()
		adopt_usec += Time.get_ticks_usec() - ta
		state.fresh_ids = []
		end_usec += Time.get_ticks_usec() - te

	## Items on plain lanes moved on to the update's tick, as Factorio moves them (Plain). A line of
	## plain lanes (a chain: each lane the next one's lane behind) is taken from its front: each item
	## goes on at its belt's speed for the ticks since it was last placed, but stops GAP behind the
	## item in front, and the front one GAP behind the hindmost item of the watched lane in front, and
	## never into it: it goes on there when that lane's sending has it (by its unique id). An item gone
	## from the watched lane behind a chain since that lane's last sending went on into the chain (the
	## mod makes the lane behind an inserter's pickup lane watched, so nothing else takes them). An
	## item a plain lane's sending has is where the mod says; one it doesn't have isn't there.
	func _move_plains() -> void:
		var plains := state.plains
		if plains.is_empty():
			return
		if state.chains_gen != state.plains_gen:
			var tc := Time.get_ticks_usec()
			_chains()
			chains_usec += Time.get_ticks_usec() - tc
		var k := state.tick
		var frame := state.frame
		var chains: Array = state.chains
		var chain_of: Dictionary = state.chain_of
		var n := chains.size()
		# Each chain's items, flat: where each is along it (lane m's line positions plus m), its id and
		# the ticks it goes on for (0: where the mod says, or put there already). (Arrays, not packed
		# ones: those are copied when appended to through another array.)
		var on: Array = []
		on.resize(n)
		var ahead := {}  # a watched lane's key -> the chain in front of which it is
		var behind := {}  # a watched lane's key -> the chain behind which it is
		for ci in n:
			var ch: PackedInt64Array = chains[ci]
			ahead[(plains[ch[0]] as Plain).down] = ci
			behind[(plains[ch[ch.size() - 1]] as Plain).up] = ci
		# Chains something touched this update wake up.
		var asleep: Dictionary = state.asleep
		for key in state.ln_now.keys() + state.sent_now:
			for c in [chain_of.get(key), ahead.get(key), behind.get(key)]:
				if c != null:
					asleep.erase(int(c[0]) if c is Array else int(c))
		var since := k - state.last_tick if state.last_tick >= 0 else 0
		var backs := {}  # chain -> the hindmost item of the watched lane in front, in the chain's line positions
		var lane_frame := state.lane_frame
		var lane_items: Dictionary = state.lane_items
		# Only the lanes of chains awake, and the watched lanes either side of them (State.lane_items):
		# a chain asleep costs nothing.
		for ci in n:
			if asleep.has(ci):
				continue
			var ch: PackedInt64Array = chains[ci]
			var list: Array = []
			for m in ch.size():
				var lane: int = ch[m]
				var members = lane_items.get(lane)
				if members == null:
					continue
				var pl: Plain = plains[lane]
				var d := pl.at1 - pl.at0
				var sent := int(lane_frame.get(lane, -1)) == frame
				for it: Item in (members as Dictionary).keys():
					if not it.path.is_empty() and it.path[it.path.size() - 1] < 0.5:
						continue
					var dt := 0
					if it.seen != frame:
						# (At most since the last update: an item held on a chain asleep stood till now.)
						dt = mini(k - it.target_tick, since) if since > 0 else k - it.target_tick
						if sent:
							# Its lane was sent again without it (the mod reads a chain's lanes again
							# together: its sample, or asked for again): not on the chain any more, or it
							# would be listed in another of its lanes (truth-findings 5).
							let_go[0] += 1
							_set_lane(it, 0)
							continue
					# (In Factorio's steps, 1/256 tile: belts move 8, 16, 24 or 32 a tick and items stop
					# 64 apart, so a chain worked out in steps stays on them, exactly, update after update.)
					list.append(snappedf((it.target.x - pl.at0.x) * d.x + (it.target.z - pl.at0.y) * d.y, STEP) + m)
					list.append(it.uid)
					list.append(dt)
			var head: Plain = plains[ch[0]]
			# (One not in the watched lane's last sending isn't there.)
			var front_members = lane_items.get(head.down)
			if front_members != null:
				var f := int(lane_frame.get(head.down, -1))
				for it: Item in front_members:
					if it.seen >= f:
						backs[ci] = maxf(float(backs.get(ci, -INF)), snappedf(_line_pos(head, it.target), STEP))
			var tail: Plain = plains[ch[ch.size() - 1]]
			var back_members = lane_items.get(tail.up)
			if back_members != null and int(lane_frame.get(tail.up, -1)) == frame:
				var m := ch.size() - 1
				for it: Item in (back_members as Dictionary).keys():
					if it.seen == frame or (not it.path.is_empty() and it.path[it.path.size() - 1] < 0.5):
						continue
					# Gone from the watched lane behind (a group's item too: it left the group's front): on
					# into the chain, from where it was.
					var s := snappedf(minf(_line_pos(tail, it.target) - tail.v * (k - it.target_tick), 1.0 - STEP), STEP) + m
					# (-1: placed there now, never held as standing.)
					list.append_array([s, it.uid, -1])
					_set_lane(it, ch[m])
					it.missed = 0
			if not list.is_empty():
				on[ci] = list
		var height := state.height
		for ci in n:
			if on[ci] == null:
				asleep[ci] = true
				continue
			if asleep.has(ci):
				continue
			var ch: PackedInt64Array = chains[ci]
			var flat: Array = on[ci]
			var stirred := false
			plain_lanes += ch.size()
			# Front first: sorted by place (to 1/4096 tile), the item's index in the low bits.
			var order := PackedFloat64Array()
			order.resize(flat.size() / 3)
			for j in order.size():
				order[j] = floorf(maxf(float(flat[j * 3]), -1.0) * 4096.0 + 4096.0) * 65536.0 + j
			order.sort()
			var head: Plain = plains[ch[0]]
			var room := 0.0
			var back = backs.get(ci)
			if back != null:
				room = maxf(0.0, float(back) + GAP)
			# The lane in front outside the square (which shrank under the chain) and not known here:
			# what it holds isn't known, so the chain's items wait where they are (a backed-up chain ran
			# on into the gap and was put back by its drift check, again and again: 60-90% of the items
			# missing on such lanes with a small square).
			var hold := false
			if not (lane_frame.has(head.down) or state.groups.has(head.down)):
				var next := (head.at0 + head.at1) * 0.5 + (head.at0 - head.at1)
				var sq := state.square
				hold = sq.z >= 0.0 and maxf(absf(next.x - sq.x), absf(next.y - sq.y)) >= sq.z
			# The lane in front sent with room by more than a step (its hindmost item further on than a gap).
			var sent_room := (back == null or float(back) + GAP < -STEP) and int(lane_frame.get(head.down, -1)) == frame
			# (A group that moved: one only sent again, its refresh, took nothing in.)
			var ahead_group: Group = state.groups.get(head.down)
			var into_group := ahead_group != null and ahead_group.moved_at == k
			# As many as the group's move made room for (one at least): its back went on by that much;
			# one only when the chain's front item stood (backed up behind the group: a group's move
			# is taken at its last pace, the belt's at first, so a backed-up group's moves read as
			# whole gaps at full speed). (Every one wanting past the room went in before: a backed-up
			# chain behind a group that moved lost all its items whose pace since the last update would
			# take them a gap on, asked for again by its drift check, lost again: 40% of the items
			# missing on such lanes.)
			var into_left := maxi(1, roundi(ahead_group.went / maxf(ahead_group.gap, 0.01))) if into_group else 0
			var first_in := true
			var front := room - GAP
			var top := ch.size() - STEP
			for o in order:
				var j := int(fmod(o, 65536.0)) * 3
				var s: float = flat[j]
				var uid: int = flat[j + 1]
				var dt: int = flat[j + 2]
				var it: Item = state.items[uid]
				if dt == 0 and it.seen == frame and int(lane_frame.get(it.lane, -1)) == frame:
					front = s  # where the mod says
					it.stuck = 0
					stirred = true
					continue
				var m := clampi(floori(s), 0, ch.size() - 1)
				var pl: Plain = plains[ch[m]]
				var want := s if hold else s - pl.v * maxf(dt, 0)
				var was := s
				if front + GAP > top + 0.5 * STEP:
					# No room left on the chain behind the items in front (it is fuller here than in the
					# game: something came in faster than the chain went on). Not piled up on the last
					# one: let go (missing, or taken over by place, _adopt()).
					let_go[1] += 1
					_set_lane(it, 0)
					stirred = true
					continue
				s = minf(maxf(want, front + GAP), top)
				# Going on into a group's lane that moved: the group's own item that came in takes it over
				# by place (_adopt()). (No other "stuck" rule: the mod looks at the lanes either side of a
				# chain every update, so one waiting at the front is waiting; taking such items off froze
				# or dropped ones that only waited: truth-findings 2, 3.)
				if into_left > 0 and front + GAP <= room + 0.0001 and want < room - 0.01:
					if first_in and it.vel == Vector3.ZERO:
						into_left = 1
					first_in = false
					into_left -= 1
					stirred = true
					let_go[2] += 1
					_set_lane(it, 0)
					continue
				# A phantom (one kept wrongly) at the front, with room in the lane in front, which was sent
				# without it STUCK_UPDATES times in a row of its sendings, isn't coming: let go. Counted only
				# on those sendings, never reset by updates that didn't send it (truth-findings 2, 3).
				if front + GAP <= room + 0.0001 and want < room - 0.01:
					if sent_room:
						it.stuck += 1
						if it.stuck >= STUCK_UPDATES:
							stirred = true
							let_go[3] += 1
							_set_lane(it, 0)
							continue
				else:
					it.stuck = 0
				front = s
				m = clampi(floori(s), 0, ch.size() - 1)
				if dt >= 0 and absf(s - was) < STANDING and it.lane == ch[m] and it.path.is_empty():
					# Standing (most of a busy base's plain lanes are backed up): held where it is. (The
					# lane in front's items come a little apart from update to update, the mod carrying
					# them on by their pace: moving a backed-up chain by that much was 92% of its moves.)
					s = was
					it.seen = frame
					it.missed = 0
					it.vel = Vector3.ZERO
					it.target_tick = k
					# A record still running on (opened while it moved, OPEN_UPDATES) is stopped where it
					# stands, as a group's standing items are (truth-findings 1: drawn gliding on up to 48
					# ticks through a backed-up queue).
					if it.open or it.t_to > float(k):
						_fold(it)
						it.step = it.target - it.from
					continue
				pl = plains[ch[m]]
				var q := pl.at0 + (pl.at1 - pl.at0) * (s - m)
				var to := Vector3(q.x, height + LAYER_STEP * posmod(uid, LAYERS), q.y)
				moved += 1
				stirred = true
				# Through _update(): an item going on as its record says writes nothing (KEEP_RECORD),
				# one that changed pace is folded and its record written again (belt_records.gd).
				_update(uid, it.item_id, to, ch[m])
			if not stirred:
				asleep[ci] = true

	## `pc`: [lane key, stacks, front and back items' line positions (1/256), ticks read before the
	## update's tick, ...]: a plain lane as the mod checked it. One that has otherwise here (another
	## count, or no item near its front or back place, its own lane and the lanes either side taken
	## together: an item near a lane's end may be on either side of it) is asked for again (resend).
	func _drift_checks() -> void:
		var c: Array = state.checks_now
		state.checks_now = []
		for j in range(0, c.size() - 4, 5):
			var key := int(c[j])
			var pl: Plain = state.plains.get(key)
			if pl == null or (state.asked.has(key) and state.frame - int(state.asked[key]) < ASK_AGAIN):
				continue
			var n := int(c[j + 1])
			var p1 := int(c[j + 2]) / 256.0
			var pn := int(c[j + 3]) / 256.0
			var tol := DRIFT + pl.v * (int(c[j + 4]) + maxf(state.period, 1.0))
			# Its items all standing here: where they stand, to a gap (a fast belt's pace took the
			# tolerance to a whole lane, so a backed-up express chain drawn 1.5 tiles off was never
			# asked for again: 98% of the items missing on such a lane; to DRIFT, ten times as many
			# lanes were asked for again, a job a third longer walking).
			var still := true
			for it: Item in state.lane_items.get(key, {}):
				if it.vel != Vector3.ZERO:
					still = false
					break
			if still:
				tol = minf(tol, GAP)
			var strict := 0
			var loose := 0
			var near1 := n == 0
			var near_n := n == 0
			for lane in [key, pl.up, pl.down]:
				for it: Item in state.lane_items.get(lane, {}):
					var s := _line_pos(pl, it.target)
					if s >= tol and s < 1.0 - tol:
						strict += 1
					if s >= -tol and s < 1.0 + tol:
						loose += 1
						near1 = near1 or absf(s - p1) <= tol
						near_n = near_n or absf(s - pn) <= tol
			if n < strict or n > loose or not near1 or not near_n:
				resend.append(key)
				state.asked[key] = state.frame
		drifted += resend.size()

	## The plain lanes' chains: each line of plain lanes (each the next one's lane behind) from its
	## front lane, whose lane in front isn't plain, back.
	func _chains() -> void:
		var plains := state.plains
		# Chains asleep stay asleep, by their front lane, when others change (a plain lane at the
		# square's edge comes and goes as the edge does: making them all again woke every chain, every
		# update; one that changed has a lane in this update's sending, which wakes it).
		var sleeping := {}
		for ci in state.asleep:
			if int(ci) < state.chains.size():
				sleeping[(state.chains[ci] as PackedInt64Array)[0]] = true
		state.chains = []
		state.chain_of = {}
		state.asleep = {}
		state.chains_gen = state.plains_gen
		for key in plains:
			var head: Plain = plains[key]
			if plains.has(head.down):
				continue
			var ch := PackedInt64Array([int(key)])
			var ci := state.chains.size()
			state.chain_of[key] = [ci, 0]
			var at: Plain = head
			while plains.has(at.up) and (plains[at.up] as Plain).down == ch[ch.size() - 1] and not state.chain_of.has(at.up):
				state.chain_of[at.up] = [ci, ch.size()]
				ch.append(at.up)
				at = plains[at.up]
			if sleeping.has(ch[0]):
				state.asleep[ci] = true
			state.chains.append(ch)

	## Where a point is along a plain lane, in its line positions (beyond 0 in the lane in front, past
	## 1 in the lane behind: they run on in line).
	static func _line_pos(pl: Plain, p: Vector3) -> float:
		var d := pl.at1 - pl.at0
		return (Vector2(p.x, p.z) - pl.at0).dot(d) / maxf(d.length_squared(), 0.0001)

	## The group's items on the update's tick: from its front item, a gap apart, to the lane's end.
	## An item's unique id is its slot along the group (negative, apart from the mod's), so it glides
	## on as the group moves; one that leaves the lane is handed over to whatever takes its place on
	## the next (_adopt()), or taken off.
	func _make_group_items(key: int, g: Group) -> void:
		var first := roundi((g.moved + g.front) / g.gap)
		var along := g.at0 - g.at1  # the way items go, a line position's length
		var vel := Vector3.ZERO
		if g.moved_at == state.tick:
			vel = Vector3(along.x, 0.0, along.y) * g.speed
		var height := state.height
		var s := first
		var p := g.front
		var items := state.items
		var frame := state.frame
		var tick := state.tick
		var t := float(tick)
		var open_left := OPEN_LEFT * maxf(state.period, 6.0)
		var no_kept := state.kept.is_empty()
		# (Plain lanes look at the lanes either side, a group's among them, before _adopt(): its new
		# items are made at once there.)
		var defer := state.plains.is_empty()
		while p < 1.0 - 0.001:
			var at := g.at0 + (g.at1 - g.at0) * p
			var uid := -(1 + key * 1048576 + posmod(s, 1048576))
			var pos := Vector3(at.x, height + LAYER_STEP * posmod(uid, LAYERS), at.y)
			s += 1
			p += g.gap
			# Most of a busy base's group items, most updates: on their lane, going on as their record
			# says (_update()'s KEEP_RECORD case, worked out here without its calls: thousands an update).
			var it: Item = items.get(uid)
			if it != null and no_kept and it.in_lane and it.lane == key and it.folded != frame and it.t_to >= 0.0 				and it.item_id == g.item_id and it.count == g.stack and it.layers.size() == g.stack - 1 and it.slot >= 0 				and it.path.is_empty() and (not it.open or it.t_to - tick >= open_left):
				var rp := it.from
				if it.step != Vector3.ZERO:
					rp += it.step * (1.0 if it.t_to <= it.t_from else clampf((t - it.t_from) / (it.t_to - it.t_from), 0.0, 1.0))
				it.seen = frame
				it.missed = 0
				if rp.distance_squared_to(pos) < KEEP_RECORD * KEEP_RECORD:
					it.last_step = pos - it.target
					it.target = pos
					it.target_tick = tick
					it.vel = vel
					kept_records += 1
					continue
				# Its pace changed (a creeping lane): folded and on along its run, as _update() would.
				it.target = pos
				it.target_tick = tick
				state.seen_now.append(it)
				_fold(it)
				if not _on_run(it, pos):
					var tg := Time.get_ticks_usec()
					_glide(it, pos)
					route_usec += Time.get_ticks_usec() - tg
				it.vel = vel
				continue
			if it == null and defer:
				fresh += 1
				state.pending[uid] = [g.item_id, pos, key, g.stack, vel]
				state.fresh_ids.append(uid)
				continue
			it = _update(uid, g.item_id, pos, key)
			_set_count(it, g.stack)
			it.vel = vel
		state.lane_frame[key] = state.frame
		state.sent_now.append(key)

	## A group that moved and now stands: its items glide the rest of the way to where the last
	## update put them (this update began with them where they were drawn, short of it: made again,
	## as every group was each update, they went on there) and stand there from this update on (no
	## pace left for _adopt() to carry them on by when they go missing later).
	func _stand_group_items(key: int, g: Group) -> void:
		var s := roundi((g.moved + g.front) / g.gap)
		var p := g.front
		while p < 1.0 - 0.001:
			var it: Item = state.items.get(-(1 + key * 1048576 + posmod(s, 1048576)))
			if it != null:
				_fold(it)
				it.vel = Vector3.ZERO
				it.target_tick = state.tick
				if it.path.is_empty():
					it.step = it.target - it.from
			s += 1
			p += g.gap

	## Hands items over where one took another's place: an item new in this update that is where an
	## item missing from it would be by now (the same kind) is that item, which glides on to it
	## rather than one vanishing and the other appearing. So an item keeps moving where a group's
	## lane meets another (a group's item leaving its lane, the next lane's taking over), where a lane
	## becomes a group or stops being one, and where an item the mod carried on meets a group's.
	## Then the groups' own items that weren't made this update are taken off.
	func _adopt() -> void:
		var grid := {}
		var spare: Array = _spare  # groups' items missing from this update (_missing_pass())
		var newly := {}
		for uid in state.fresh_ids:
			newly[uid] = true
		var k := state.tick
		# Seen: only one the mod carried on (in no lane) may be another's place now; and those missing.
		var cands: Array = []
		for it: Item in state.lane_items.get(0, {}):
			if it.seen == state.frame and it.uid >= 0 and not newly.has(it.uid):
				cands.append(it)
		for it: Item in state.missing_now:
			if not _under(it):
				cands.append(it)
		for uid in spare:
			var it: Item = state.items.get(uid)
			if it != null and not _under(it):
				cands.append(it)
		# (Each with its Item: a candidate's id doesn't change while they are matched, but for those
		# taken, which `used` has.)
		for it: Item in cands:
			var at := it.target + it.vel * float(k - it.target_tick) if it.target_tick >= 0 else _at(it, state.fold_tick)
			var cell := Vector2i(floori(at.x * 2.0), floori(at.z * 2.0))
			var list = grid.get(cell)
			if list == null:
				grid[cell] = [it.uid, at, it]
			else:
				(list as Array).append_array([it.uid, at, it])
		var used := {}
		var handed := {}
		if not grid.is_empty():
			var pending := state.pending
			for uid in state.fresh_ids:
				var f: Item = state.items.get(uid)
				var wait = pending.get(uid) if f == null else null
				if f == null and wait == null:
					continue
				var p: Vector3 = f.target if f != null else wait[1]
				var item_id: int = f.item_id if f != null else wait[0]
				var cx := floori(p.x * 2.0)
				var cz := floori(p.z * 2.0)
				# Only the cells next to it that are within ADOPT_DISTANCE (cells are half a tile).
				var ex := p.x * 2.0 - cx
				var ez := p.z * 2.0 - cz
				var x0 := -1 if ex < ADOPT_DISTANCE * 2.0 else 0
				var x1 := 1 if ex > 1.0 - ADOPT_DISTANCE * 2.0 else 0
				var z0 := -1 if ez < ADOPT_DISTANCE * 2.0 else 0
				var z1 := 1 if ez > 1.0 - ADOPT_DISTANCE * 2.0 else 0
				var best := -1
				var best_d := ADOPT_DISTANCE * ADOPT_DISTANCE
				for dx in range(x0, x1 + 1):
					for dz in range(z0, z1 + 1):
						var list = grid.get(Vector2i(cx + dx, cz + dz))
						if list == null:
							continue
						var c: Array = list
						for j in range(0, c.size(), 3):
							var other: int = c[j]
							if other == uid or (c[j + 2] as Item).item_id != item_id or used.has(other):
								continue
							var at: Vector3 = c[j + 1]
							var d := (at.x - p.x) * (at.x - p.x) + (at.z - p.z) * (at.z - p.z)
							if d < best_d:
								best_d = d
								best = other
				if best != -1:
					used[best] = true
					if f != null:
						_hand_over(uid, f, best)
					else:
						pending.erase(uid)
						_hand_over_to(uid, best, wait[2], wait[3], wait[1], wait[4])
					handed[uid] = true
		# Groups' new items that took no one's place are made now, as they came.
		if not state.pending.is_empty():
			var ids: Array = state.fresh_ids
			var n := ids.size()
			for i in n:
				var wait = state.pending.get(ids[i])
				if wait != null:
					var f := _update(int(ids[i]), wait[0], wait[1], wait[2])
					_set_count(f, wait[3])
					f.vel = wait[4]
					fresh -= 1  # (counted when it came)
			ids.resize(n)  # (_update() listed them again)
			state.pending.clear()
		# A group's new item that took no one's place, on a group that moved, came from behind: it
		# glides in from where it was, along the groups' lanes behind it, rather than standing still a
		# whole update where it appeared (its group moved further than ADOPT_DISTANCE leaves room
		# for, or the item it follows wasn't drawn).
		var dt := float(k - state.last_tick) if state.last_tick >= 0 else 0.0
		if dt > 0.0:
			for uid in state.fresh_ids:
				if uid >= 0 or handed.has(uid):
					continue
				var f: Item = state.items.get(uid)
				if f != null and f.vel != Vector3.ZERO and f.path.is_empty():
					_glide_in(f, f.vel * dt)
		for uid in spare:
			if not used.has(uid) and state.items.has(uid):
				_remove(uid)
		_spare = []

	## After an update has come: the items of the lanes it sent (and of none) that it left out, and
	## those missing before, are missing (MISSING_FRAMES updates, then gone; under the ground longer);
	## outside the square they go at once, or wait for their chunk's far icons. Groups' own items left
	## out are spare (_adopt()). Lanes not sent hold their items: nothing is looked at for them.
	func _missing_pass() -> void:
		var f := state.frame
		var cands := {}
		for key in state.sent_now:
			for it: Item in state.lane_items.get(key, {}):
				if it.seen != f:
					cands[it] = true
		for it: Item in state.lane_items.get(0, {}):
			if it.seen != f and not state.kept.has(it):
				cands[it] = true
		for it: Item in state.missing_set:
			if it.seen != f and state.items.get(it.uid) == it:
				cands[it] = true
		state.missing_set = {}
		state.missing_now = []
		state.sent_now = []
		var sq := state.square
		var edge := sq.z + SQUARE_SLACK
		var gone: Array = []
		for it: Item in cands:
			if it.lane != 0 and _held(it):
				continue
			var at := _at(it, state.fold_tick)
			if sq.z >= 0.0 and (absf(at.x - sq.x) > edge or absf(at.z - sq.y) > edge):
				if _wait_for_icons(it, at):
					_set_lane(it, 0)
					state.kept[it] = true
					it.seen = f
					it.missed = 0
				else:
					gone.append(it.uid)
				continue
			if it.uid < 0:
				_spare.append(it.uid)
				continue
			it.missed += 1
			missing += 1
			_fold(it)
			if _under(it):
				_carry_under(it)
			elif it.speed > 0.0 and _entrance_ahead(it):
				_carry_into_ground(it)
			if it.missed > (MISSING_HIDDEN if _under(it) else MISSING_FRAMES):
				gone.append(it.uid)
			else:
				state.missing_set[it] = true
				state.missing_now.append(it)
		for uid in gone:
			_remove(uid)

	## An item's motion given from outside the mod's positions (set_motion(), remove_item()): it is at
	## `at` on tick `k` and goes along its lane at `v` tiles a tick to `stop` (or that far along the belts
	## it is on), where it stands; its record says so and nothing is written again until the next
	## call. Such an item is in the EXTERNAL lane: updates never count it missing.
	func _motion(msg: Dictionary) -> void:
		var uid := int(msg.get("u", 0))
		if bool(msg.get("gone", false)):
			_remove(uid)
			return
		var item_id := int(msg.get("i", 0))
		var at: Vector3 = msg.get("at", Vector3.ZERO)
		var stop: Vector3 = msg.get("stop", at)
		var k := float(msg.get("k", 0))
		var v := maxf(float(msg.get("v", 0.0)), 0.0)
		if state.records.base < 0.0:
			state.records.base = k - 600.0
		at.y = state.height + LAYER_STEP * posmod(uid, LAYERS)
		stop.y = at.y
		var it: Item = state.items.get(uid)
		if it == null:
			it = Item.new()
			it.uid = uid
			it.item_id = item_id
			it.key = item_id
			var a := ItemCards.yaw_for(uid)
			it.c = cos(a)
			it.s = sin(a)
			state.items[uid] = it
			_place(it)
		elif it.item_id != item_id:
			_unplace(it)
			it.item_id = item_id
			it.key = item_id
			_place(it)
		_set_lane(it, EXTERNAL)
		state.kept.erase(it)
		state.missing_set.erase(it)
		it.from = at
		it.step = Vector3.ZERO
		it.path = PackedFloat32Array()
		it.segs = []
		it.run_gen = -1
		it.open = false
		it.folded = state.frame
		it.seen = state.frame
		it.missed = 0
		it.target = stop
		it.target_tick = int(k)
		it.vel = Vector3.ZERO
		var length := 0.0
		if at.distance_to(stop) > 0.001:
			var r := state.graph.route(Vector2(at.x, at.z), Vector2(stop.x, stop.z), it.hint, at.distance_to(stop) * 2.0 + 2.0)
			match r.kind:
				BeltPaths.PATH:
					it.step = Vector3(r.end.x - at.x, 0.0, r.end.y - at.z)
					it.path = state.graph.points(r, at)
					it.segs = r.segs
					it.length = r.length
					it.hint = r.belt
					length = r.length
				BeltPaths.LINE, BeltPaths.SNAP:
					it.step = Vector3(r.end.x - at.x, 0.0, r.end.y - at.z)
					it.hint = r.belt
					length = it.step.length()
				_:
					it.step = stop - at
					length = it.step.length()
		it.t_from = k
		it.t_to = k + (length / v if v > 0.0 else 0.0)
		if v <= 0.0:
			it.from += it.step
			it.step = Vector3.ZERO
			it.path = PackedFloat32Array()
		it.speed = v
		_set_count(it, int(msg.get("n", 1)))
		_mark(it)

	## An item off the layer: out of its slots, its lane, the lists.
	func _remove(uid: int) -> void:
		var it: Item = state.items.get(uid)
		if it == null:
			return
		_unplace(it)
		_set_lane(it, -1)
		state.items.erase(uid)
		state.pathed.erase(it)
		state.missing_set.erase(it)
		state.kept.erase(it)

	## The lane an item was last sent in (-1: none, it is leaving).
	func _set_lane(it: Item, lane: int) -> void:
		if it.lane == lane and lane >= 0 and it.in_lane:
			return
		if it.in_lane:
			var old: Dictionary = state.lane_items.get(it.lane, {})
			old.erase(it)
			if old.is_empty():
				state.lane_items.erase(it.lane)
			it.in_lane = false
		if lane < 0:
			return
		it.lane = lane
		var members: Dictionary = state.lane_items.get(lane, {})
		if members.is_empty():
			state.lane_items[lane] = members
		members[it] = true
		it.in_lane = true

	## Where an item is drawn at tick t, as its record has it.
	static func _at(it: Item, t: float) -> Vector3:
		if it.t_to < 0.0 or (it.step == Vector3.ZERO and it.path.is_empty()):
			return it.from
		var g := 1.0 if it.t_to <= it.t_from else clampf((t - it.t_from) / (it.t_to - it.t_from), 0.0, 1.0)
		if it.path.is_empty():
			return it.from + it.step * g
		var o := BeltPaths.path_at(it.path, g)
		return it.from + Vector3(o.x, o.y, o.z)

	## The update changes the item: it stops where it is drawn at the fold tick and waits for its new
	## glide (planned now, to arrive at the job's last update: t_to -1, set in _write()). Once an
	## update; one planned earlier in this job (never drawn) stays where it began.
	func _fold(it: Item) -> void:
		if it.folded == state.frame:
			return
		it.folded = state.frame
		_mark(it)
		var t := 0.0
		if it.t_to >= 0.0:
			t = 1.0 if it.t_to <= it.t_from else clampf((state.fold_tick - it.t_from) / (it.t_to - it.t_from), 0.0, 1.0)
		if it.path.is_empty():
			it.from += it.step * t
		elif not it.segs.is_empty():
			var o := BeltPaths.path_at(it.path, t)
			it.from += Vector3(o.x, o.y, o.z)
			var cur := BeltPaths.Graph.along(it.segs, it.length, t)
			if not cur.is_empty():
				it.hint = cur[0]
				it.under_lane = cur[1]
				it.under_s = cur[3] if int(cur[2]) == 1 else -1.0
			it.path = hidden_path if o.w < 0.5 else PackedFloat32Array()
			it.segs = []
			if o.w < 0.5:
				it.run_gen = -1  # under the ground, in line with the exit's lane: not on it yet
		# (else HIDDEN: it stays where it is, out of sight)
		it.step = Vector3.ZERO
		it.t_from = state.fold_tick
		it.t_to = -1.0
		it.open = false

	func _mark(it: Item) -> void:
		if not it.dirty:
			it.dirty = true
			state.dirty.append(it)

	## The middle of the lane of a straight belt that a point on it is on, items going `way` (an
	## axis), as a key: the same for every point along that lane.
	static func _lane_cell(p: Vector2, way: Vector2) -> Vector2i:
		if absf(way.x) > absf(way.y):
			return Vector2i(floori(p.x), roundi(p.y * 8.0))
		return Vector2i(roundi(p.x * 8.0), floori(p.y))

	## A new item glides in over `went` (straight, along its lane) to where it is, from as far back as
	## the groups' lanes behind it go that way: not across a curve or a splitter behind, nor over a
	## lane sent as items (its own items are drawn there; on the layout's source belts that drew
	## items where the game had none).
	func _glide_in(f: Item, went: Vector3) -> void:
		var dist := went.length()
		if dist < 0.001:
			return
		var back := Vector2(-went.x, -went.z) / dist
		var at := Vector2(f.from.x, f.from.z)
		var reach := 0.0
		while reach < dist:
			if not group_lanes.has(_lane_cell(at + back * minf(reach + 0.125, dist), back)):
				break
			reach = minf(reach + 0.125, dist)
		if reach <= 0.0:
			return
		var step := Vector3(-back.x, 0.0, -back.y) * reach
		f.from -= step
		f.step = step
		f.run_gen = -1
		glided_in += 1

	## The item `old` takes the new item's place (and id): it glides on from where it is drawn.
	func _hand_over(uid: int, f: Item, old: int) -> void:
		var m: Item = state.items[old]
		_fold(m)
		var lane := f.lane
		_unplace(f)
		_set_lane(f, -1)
		state.pathed.erase(f)
		state.items.erase(old)
		state.missing_set.erase(m)
		state.kept.erase(m)
		state.items[uid] = m
		m.uid = uid
		m.seen = state.frame
		m.missed = 0
		m.kept = 0
		_set_lane(m, lane)
		_set_count(m, f.count)
		_glide(m, f.target)
		m.target = f.target
		m.target_tick = state.tick
		m.vel = f.vel
		adopted += 1

	## _hand_over() for a group's new item not made (State.pending): the item `old` takes its id, its
	## lane `lane`, a stack of `count`, and glides on to `pos` at `vel`.
	func _hand_over_to(uid: int, old: int, lane: int, count: int, pos: Vector3, vel: Vector3) -> void:
		var m: Item = state.items[old]
		_fold(m)
		state.items.erase(old)
		state.missing_set.erase(m)
		state.kept.erase(m)
		state.items[uid] = m
		m.uid = uid
		m.seen = state.frame
		m.missed = 0
		m.kept = 0
		_set_lane(m, lane)
		_set_count(m, count)
		if _on_run(m, pos):
			# (As _glide()'s straight route would leave it: its pace and the belt it reaches.)
			m.speed = m.step.length() / maxf(state.period, 1.0)
			var b = state.graph.belt_at(Vector2(pos.x, pos.z))
			if b != null:
				m.hint = b
		else:
			_glide(m, pos)
		m.target = pos
		m.target_tick = state.tick
		m.vel = vel
		adopted += 1

	## An item folded this update going on along the straight run of belts it is on to `pos` (as
	## _update() does, without a route): its step set, or false when pos is off its run.
	func _on_run(it: Item, pos: Vector3) -> bool:
		if it.run_gen != gen or not it.path.is_empty():
			return false
		if it.run_z:
			if absf(pos.x - it.from.x) <= ON_LANE and pos.z >= it.run_min and pos.z <= it.run_max:
				it.step = Vector3(0.0, 0.0, pos.z - it.from.z)
				return true
		elif absf(pos.z - it.from.z) <= ON_LANE and pos.x >= it.run_min and pos.x <= it.run_max:
			it.step = Vector3(pos.x - it.from.x, 0.0, 0.0)
			return true
		return false

	func _update(uid: int, item_id: int, pos: Vector3, lane := 0) -> Item:
		var it: Item = state.items.get(uid)
		if it != null:
			_set_lane(it, lane)
			if not state.kept.is_empty():
				state.kept.erase(it)
		if it == null:
			it = Item.new()
			it.uid = uid
			_set_lane(it, lane)
			it.folded = state.frame
			it.t_from = state.fold_tick
			it.t_to = -1.0
			_mark(it)
			it.item_id = item_id
			it.key = item_id
			it.from = pos
			var a := ItemCards.yaw_for(uid)
			it.c = cos(a)
			it.s = sin(a)
			state.items[uid] = it
			_place(it)
			_settle(it)
			fresh += 1
			it.missed = 0
			it.seen = state.frame
			it.target = pos
			it.target_tick = state.tick
			state.fresh_ids.append(uid)
			return it
		it.seen = state.frame
		it.missed = 0
		var before := it.target
		if it.target_tick >= 0 and state.tick > it.target_tick:
			var went := pos - it.target
			it.vel = _belt_speed(went / float(state.tick - it.target_tick)) if went.length() < state.snap else Vector3.ZERO
		it.target = pos
		it.target_tick = state.tick
		# Where its record has it at this update's tick: there (going on as before, or standing), its
		# record stays as it is, nothing written (most items, most updates). An open record near its
		# end is made longer (planned again).
		if it.folded != state.frame and it.t_to >= 0.0 and it.item_id == item_id and it.path.is_empty() and it.slot >= 0 				and _at(it, float(state.tick)).distance_squared_to(pos) < KEEP_RECORD * KEEP_RECORD 				and (not it.open or it.t_to - state.tick >= OPEN_LEFT * maxf(state.period, 6.0)):
			it.last_step = pos - before
			kept_records += 1
			return it
		state.seen_now.append(it)
		_fold(it)
		if it.item_id != item_id:
			_unplace(it)
			it.item_id = item_id
			it.key = item_id
			_place(it)
		# Most of a dense base's items, every update: on along the run of straight belts it is on,
		# its lane known, nothing looked up (worked out here, not in _glide: this runs thousands of
		# times an update). An item with a path has no run.
		if it.run_gen == gen:
			if it.run_z:
				if absf(pos.x - it.from.x) <= ON_LANE and pos.z >= it.run_min and pos.z <= it.run_max:
					it.step = Vector3(0.0, 0.0, pos.z - it.from.z)
					return it
			elif absf(pos.z - it.from.z) <= ON_LANE and pos.x >= it.run_min and pos.x <= it.run_max:
				it.step = Vector3(pos.x - it.from.x, 0.0, 0.0)
				return it
		var tg := Time.get_ticks_usec()
		_glide(it, pos)
		route_usec += Time.get_ticks_usec() - tg
		return it

	## A stack of n: its pile has n - 1 copies above it, each in a slot of its kind.
	func _set_count(it: Item, n: int) -> void:
		n = clampi(n, 1, MAX_STACK)
		it.count = n
		if it.slot < 0 or it.layers.size() == n - 1:
			return
		var kind: Kind = state.kinds[it.key]
		while it.layers.size() > n - 1:
			var gone: Layer = it.layers.pop_back()
			kind.slots[gone.slot] = null
			kind.free.append(gone.slot)
			kind.emptied.append(gone.slot)
			gone.slot = -1
		while it.layers.size() < n - 1:
			var layer := Layer.new()
			layer.it = it
			layer.k = it.layers.size() + 1
			var a := atan2(it.s, it.c) + PILE_TURN * layer.k
			layer.c = cos(a)
			layer.s = sin(a)
			_put(kind, layer)
			it.layers.append(layer)

	## From where the item is drawn to `pos`: along its lane, or (belts not known there) straight.
	## Along its lanes it goes as far as they lead to pos, which may be further than a glide would
	## go when the mod's guess left the lane; moved some other way, it is put there.
	func _glide(it: Item, pos: Vector3) -> void:
		# Under the ground (HIDDEN) it may come up at an exit further away than a glide would go.
		# (Most items have no path: nothing to make or clear for them, thousands an update.)
		var under := false
		var g := state.graph
		if not it.path.is_empty():
			under = it.path[it.path.size() - 1] < 0.5
			it.path = PackedFloat32Array()
			it.segs = []
		it.run_gen = -1
		var far := it.from.distance_to(pos)
		var r := g.route(Vector2(it.from.x, it.from.z), Vector2(pos.x, pos.z), it.hint, maxf(state.snap, far) * 1.6)
		if r.kind == BeltPaths.NONE and (under or far >= state.snap):
			it.from = pos
			it.step = Vector3.ZERO
			_settle(it)
			routes[4] += 1
			return
		routes[r.kind] += 1
		match r.kind:
			BeltPaths.LINE:
				it.step = Vector3(r.end.x - it.from.x, 0.0, r.end.y - it.from.z)
				it.hint = r.belt
				it.speed = it.step.length() / maxf(state.period, 1.0)
				_keep_run(it, r, Vector2(it.from.x, it.from.z))
				if r.belt != null and not BeltPaths.Graph.shows(r.belt, r.part):
					it.path = hidden_path  # still under the ground
					it.under_lane = r.lane
					it.under_s = r.s
			BeltPaths.PATH:
				it.step = Vector3(r.end.x - it.from.x, 0.0, r.end.y - it.from.z)
				it.path = g.points(r, it.from)
				it.segs = r.segs
				it.length = r.length
				it.hint = r.belt
				it.speed = r.length / maxf(state.period, 1.0)
				_keep_run(it, r, r.end)
			BeltPaths.SNAP:
				it.from = Vector3(r.end.x, pos.y, r.end.y)
				it.step = Vector3.ZERO
				it.hint = null
				_settle(it)
			_:
				it.step = pos - it.from
				it.hint = null

	## A route that ends on a straight piece of lane: the item glides on along it without a look
	## while it stays on its line, from `at` (on the line) to where the lane runs straight to.
	func _keep_run(it: Item, r: BeltPaths.Route, at: Vector2) -> void:
		if r.run_d < 0 or is_nan(r.run_end):
			return
		var f: Vector2 = BeltPaths.AHEAD[r.run_d]
		it.run_z = f.x == 0.0
		var a := at.y if it.run_z else at.x
		var end := r.run_end * (f.y if it.run_z else f.x)  # f's component is 1 or -1
		it.run_min = minf(a, end) - ON_LANE
		it.run_max = maxf(a, end) + ON_LANE
		it.run_gen = gen

	## Out of sight under the ground (its path ends hidden: HIDDEN after an update began).
	static func _under(it: Item) -> bool:
		return not it.path.is_empty() and it.path[it.path.size() - 1] < 0.5

	## Whether an underground's entrance is within an update's travel in front of an item (it is
	## on one, or on the straight belts in front of one).
	func _entrance_ahead(it: Item) -> bool:
		var p := Vector2(it.from.x, it.from.z)
		var b: BeltPaths.Belt = state.graph.belt_at(p)
		if b == null or b.kind == BeltPaths.UG_IN:
			return b != null
		if b.kind != BeltPaths.STRAIGHT:
			return false
		var f: Vector2 = BeltPaths.AHEAD[b.d]
		var reach := it.speed * maxf(state.period, 1.0) + 1.0
		var k := 0.5
		while k <= reach:
			var o := state.graph.belt_at(p + f * k)
			if o == null or o.d != b.d or (o.kind != BeltPaths.STRAIGHT and o.kind != BeltPaths.UG_IN):
				return false
			if o.kind == BeltPaths.UG_IN:
				return true
			k += 1.0
		return false

	## An item missing from an update just before an underground's entrance went under (the mod
	## sends only what is inside a belt): it glides on into it at its speed, out of sight.
	func _carry_into_ground(it: Item) -> void:
		var g := state.graph
		it.run_gen = -1
		var r := g.advance(Vector2(it.from.x, it.from.z), it.hint, it.speed * maxf(state.period, 1.0))
		if r.kind != BeltPaths.PATH or BeltPaths.Graph.shows(r.belt, r.part):
			return
		it.step = Vector3(r.end.x - it.from.x, 0.0, r.end.y - it.from.z)
		it.path = g.points(r, it.from)
		it.segs = r.segs
		it.length = r.length
		it.hint = r.belt

	## An item under the ground isn't sent (it is outside every belt): it goes on at its speed
	## meanwhile, so it comes up at the exit when the game has it there, not all at once.
	func _carry_under(it: Item) -> void:
		var g := state.graph
		if it.hint == null or it.speed <= 0.0 or not g.alive(it.hint):
			return
		if it.under_s < 0.0:
			var at := g.locate(Vector2(it.from.x, it.from.z), it.hint)
			if at.is_empty() or at[0] != it.hint or int(at[2]) != 1:
				return
			it.under_lane = at[1]
			it.under_s = at[3]
		var pc := g.piece(it.hint, it.under_lane, 1)
		it.under_s = minf(it.under_s + it.speed * maxf(state.period, 1.0), pc[BeltPaths.P_LEN])
		var p := BeltPaths.Graph.piece_point(pc, it.under_s)
		it.from.x = p.x
		it.from.z = p.y

	## An item that doesn't glide (new, or put somewhere): onto its lane, and out of sight under
	## the ground.
	func _settle(it: Item) -> void:
		var g := state.graph
		it.run_gen = -1
		var p := Vector2(it.from.x, it.from.z)
		if not g.knows(p):
			return
		var at := g.locate(p, it.hint)
		if at.is_empty():
			it.hint = null
			return
		var b: BeltPaths.Belt = at[0]
		var q := g.point(b, int(at[1]), int(at[2]), float(at[3]))
		it.from.x = q.x
		it.from.z = q.y
		it.hint = b
		if not BeltPaths.Graph.shows(b, int(at[2])):
			it.path = hidden_path
			it.under_lane = at[1]
			it.under_s = at[3]

	func _place(it: Item) -> void:
		var kind: Kind = state.kinds.get(it.key)
		if kind == null:
			kind = Kind.new()
			state.kinds[it.key] = kind
		_put(kind, it)

	## Settings → Items in 3D: the model_cap items (stacks) nearest the square's
	## centre stay models, the others of items that have a model are drawn as their icons. Once an
	## update: items near the edge keep their look within CAP_SLACK, so they don't flip back and forth.
	func _cap_models() -> void:
		if model_cap < 0:
			for uid in state.items:
				var it: Item = state.items[uid]
				if it.key != it.item_id:
					_rekey(it, it.item_id)
			return
		var c := Vector2(state.square.x, state.square.y)
		var uids: Array = []
		var dists := PackedFloat32Array()
		for uid in state.items:
			var it: Item = state.items[uid]
			var look: Array = known.get(it.item_id, [])
			if not look.is_empty() and not bool(look[1]):
				if it.key != it.item_id:
					_rekey(it, it.item_id)  # no model: its icon kind is its own
				continue
			uids.append(uid)
			dists.append(c.distance_squared_to(Vector2(it.from.x, it.from.z)))
		if uids.is_empty():
			return
		# The distance (squared) within which model_cap items fit.
		var limit := INF
		if model_cap < dists.size():
			var order := dists.duplicate()
			order.sort()
			limit = order[maxi(model_cap - 1, 0)] if model_cap > 0 else -1.0
		var keep := limit if limit == INF or limit < 0.0 else pow(sqrt(limit) + CAP_SLACK, 2.0)
		for i in uids.size():
			var it: Item = state.items[uids[i]]
			var model := it.key == it.item_id
			var want := dists[i] <= (keep if model else limit)
			if want != model:
				_rekey(it, it.item_id if want else ItemCards.icon_key(it.item_id))

	func _rekey(it: Item, key: int) -> void:
		var n := it.count
		_unplace(it)
		it.key = key
		_place(it)
		it.count = 1
		_set_count(it, n)

	## An Item or a Layer into a free slot of its kind.
	func _put(kind: Kind, e) -> void:
		if kind.free.is_empty():
			e.slot = kind.slots.size()
			kind.slots.append(e)
		else:
			e.slot = kind.free.pop_back()
			kind.slots[e.slot] = e
		kind.fresh.append(e)

	## Takes an item and its pile's copies out of their kind (_set_count() puts the copies back).
	func _unplace(it: Item) -> void:
		var kind: Kind = state.kinds[it.key]
		for e in [it] + it.layers:
			kind.slots[e.slot] = null
			kind.free.append(e.slot)
			kind.emptied.append(e.slot)
			e.slot = -1
		it.layers = []

	## A new update begins. Items aren't looked at one by one: those the update changes are folded
	## where they are drawn as it comes (_fold()), those left out are found from the lanes it sends
	## (_missing_pass()). Only when the square moved are items outside the new one (`sq`) taken off
	## at once (lane icons take over there when this is drawn: G16), or kept for their chunk's icons.
	func _begin_frame(sq: Vector3) -> void:
		if state.tick < 0:
			state.frame += 1
			began = true
			return
		began = true
		updates += 1
		state.frame += 1
		state.seen_now = []
		state.sent_now = []
		state.held_chunks = {}  # found again below, for the items still kept
		var gone: Array = []
		for it: Item in state.kept.keys():
			it.kept += 1
			it.seen = state.frame
			it.missed = 0
			if not _wait_for_icons(it, _at(it, state.fold_tick)):
				gone.append(it.uid)
		if sq.z >= 0.0 and sq != state.square:
			var edge := sq.z + SQUARE_SLACK
			for uid in state.items:
				var it: Item = state.items[uid]
				if state.kept.has(it):
					continue
				var at := _at(it, state.fold_tick)
				if absf(at.x - sq.x) > edge or absf(at.z - sq.y) > edge:
					if _wait_for_icons(it, at):
						it.kept += 1
						it.seen = state.frame
						it.missed = 0
						_set_lane(it, 0)
						state.kept[it] = true
					else:
						gone.append(uid)
		for uid in gone:
			_remove(uid)

	## Writes the records: new slots whole, emptied ones hidden, items whose motion changed, and every
	## item along a path (the paths' texture is made again each job).
	func _write() -> void:
		var recs := state.records
		var tex := PackedFloat32Array()
		var texels := 0
		var room := PATH_WIDTH * MAX_ROWS
		_writes += 1
		var writing := _writes
		var batch: Array = []  # Items and Layers whose records are written
		# This job's plans arrive at its last update's tick; steady items go on past it. A job that
		# took longer than planned holds an update older than its fold tick, where its glides begin
		# and each item was folded: an item moving was put at its fold place a tick before that
		# update's tick and jumped (Zenith Test with jobs of 200 ms: 0.3-0.4 tiles, a hundred items in
		# a frame, some away from where the game had them). It glides on from its fold place instead,
		# to where it is a few ticks on at its pace (along its straight run), or to the update's
		# place on a path.
		var t_from := state.fold_tick
		var late := t_from + CATCH_TICKS - float(last_tick)
		var pathed := state.pathed
		for it: Item in state.dirty:
			if it.t_to < 0.0:
				it.t_from = t_from
				it.t_to = float(last_tick)
				if late > CATCH_TICKS - 1.0:
					it.t_to = t_from + CATCH_TICKS
					if it.path.is_empty() and it.vel != Vector3.ZERO and it.run_gen == gen:
						_carry_late(it, late)
				if it.path.is_empty() and it.step != Vector3.ZERO:
					_open(it)
			if it.path.is_empty():
				if not pathed.is_empty():
					pathed.erase(it)
			elif _hidden(it):
				pathed.erase(it)
			elif state.items.get(it.uid) == it:
				pathed[it] = true
		for it: Item in state.pathed:
			# A pile's copies share their item's path (written once a _write()).
			var path: PackedFloat32Array = it.path
			var k := path.size() / 4
			it.code = 0.0
			if texels + k <= room:
				it.code = 1.0 + texels * 64 + (k - 2)
				tex.append_array(path)
				texels += k
			it.code_at = writing
			_mark(it)
		for item_id in state.kinds:
			var kind: Kind = state.kinds[item_id]
			var look: Array = known.get(item_id, [])
			if full:
				kind.known = false  # the looks may have changed (Settings > Items in 3D)
			if not kind.known and not look.is_empty():
				kind.known = true
				kind.lift = look[0]
				kind.turns = look[1]
				kind.pile = float(look[2]) if look.size() > 2 else 0.07
				kind.fresh = kind.slots.filter(func(e) -> bool: return e != null)
			_compact(kind)
			var n := kind.slots.size()
			if n > kind.cap or kind.base < 0:
				var cap := BeltRecords.MIN_RUN
				while cap < maxi(n, kind.cap * 2):
					cap *= 2
				var base := recs.alloc(cap)
				if kind.base >= 0:
					recs.copy(kind.base, base, kind.cap)
					recs.release(kind.base, kind.cap)
				for i in range(kind.cap, cap):
					recs.hide(base + i)
				kind.base = base
				kind.cap = cap
			if not kind.known:
				unknown.append(item_id)
				continue
			for i in kind.emptied:
				if i < kind.cap:
					recs.hide(kind.base + i)
			kind.emptied.clear()
			for e in kind.fresh:
				if e.slot >= 0:
					batch.append(e)
			kind.fresh.clear()
			var told := Vector3i(kind.base, n, kind.cap)
			if full or told != kind.told:
				kind.told = told
				written.append([item_id, kind.base, n, kind.cap])
		for it: Item in state.dirty:
			it.dirty = false
			if it.slot < 0:
				continue
			var kind: Kind = state.kinds.get(it.key)
			if kind == null or not kind.known:
				continue
			batch.append(it)
			batch.append_array(it.layers)
		state.dirty = []
		_records(batch, writing)
		if texels > 0:
			var rows := 1
			while rows * PATH_WIDTH < texels:
				rows *= 2
			tex.resize(rows * PATH_WIDTH * 4)
			paths = Image.create_from_data(PATH_WIDTH, rows, false, Image.FORMAT_RGBAF, tex.to_byte_array())
		pages = recs.take_pages()

	## Slots' records: their item's motion, their own turn and lift (all in one go: the records'
	## array is out of `state.records` while written, so writing doesn't copy it).
	func _records(batch: Array, writing: int) -> void:
		var recs := state.records
		var d := recs.data
		recs.data = PackedFloat32Array()
		var base := recs.base
		var dirty := recs.dirty
		var n := 0
		for e in batch:
			if e.slot < 0 or e.stamp == writing:
				continue
			e.stamp = writing
			n += 1
			var it: Item = e if e is Item else (e as Layer).it
			var kind: Kind = state.kinds[it.key]
			var c := 1.0
			var s := 0.0
			var lift := kind.lift.y
			if e is Layer:
				lift += kind.pile * (e as Layer).k
				if kind.turns:
					c = (e as Layer).c
					s = (e as Layer).s
			elif kind.turns:
				c = it.c
				s = it.s
			var code := 0.0
			if not it.path.is_empty():
				code = BeltRecords.HIDDEN if _hidden(it) else it.code
			var r: int = kind.base + e.slot
			var o := r * BeltRecords.FLOATS
			d[o] = it.from.x
			d[o + 1] = it.from.y
			d[o + 2] = it.from.z
			d[o + 3] = it.t_from - base
			d[o + 4] = it.step.x
			d[o + 5] = it.step.y
			d[o + 6] = it.step.z
			d[o + 7] = it.t_to - base
			d[o + 8] = c
			d[o + 9] = s
			d[o + 10] = lift
			d[o + 11] = code
			dirty[r / BeltRecords.PER_PAGE] = true
		records_written += n
		recs.data = d

	## Out of sight under the ground for good (HIDDEN): no path to draw.
	static func _hidden(it: Item) -> bool:
		return _hidden_path(it.path)

	static func _hidden_path(path: PackedFloat32Array) -> bool:
		return path.size() == 8 and path[3] < 0.5 and path[7] < 0.5

	## A steady item (its glide as fast as the game moved it) goes on along its straight run past its
	## target, OPEN_UPDATES updates' worth or to the run's end, so the next updates that find it on its
	## way write nothing (KEEP_RECORD in _update()).
	func _open(it: Item) -> void:
		if it.run_gen != gen or it.vel == Vector3.ZERO or it.t_to <= it.t_from:
			return
		var speed := it.vel.length()
		# Only at a belt's own speed: a lane that goes stop and go (an inserter taking from a backed-up
		# lane) or an item whose place wobbled by a step has a pace from two updates that it doesn't
		# keep, and run on at it the item went past where it stopped, or crept on for hundreds of
		# ticks, and was pulled back or jumped when an update said where it was.
		if not _is_belt_speed(speed):
			return
		var end := it.from + it.step
		# Through the update's place at the belt's speed: from where it is drawn at the start, moved a
		# little if its glide there was a little faster or slower (it then goes on exactly).
		# A record ahead of where the item is drawn (it waited at its last place: the job came late)
		# catches up once (at most the glide it waited for: when jobs lag behind the drawn clock it
		# would jump there anyway), and from then on goes on without waiting.
		var start := end - it.vel * (it.t_to - it.t_from)
		var ahead := (start - it.from).dot(it.vel / speed)
		var aside := (start - it.from - it.vel / speed * ahead).length()
		if aside > OPEN_JUMP or ahead < -OPEN_JUMP or ahead > it.step.length() + OPEN_JUMP:
			return
		var room := 0.0
		if it.run_z:
			if absf(it.vel.x) > 1e-5:
				return
			room = (it.run_max - end.z) if it.vel.z > 0.0 else (end.z - it.run_min)
		else:
			if absf(it.vel.z) > 1e-5:
				return
			room = (it.run_max - end.x) if it.vel.x > 0.0 else (end.x - it.run_min)
		var extra := minf(room - ON_LANE, speed * OPEN_UPDATES * maxf(state.period, 6.0))
		if extra < 0.05:
			return
		it.from = start
		it.step = end + it.vel / speed * extra - start
		it.t_to += extra / speed
		it.open = true

	## An item's glide (straight, along its run) made `ticks` longer at its pace, short of its run's end.
	func _carry_late(it: Item, ticks: float) -> void:
		var end := it.from + it.step + it.vel * ticks
		if it.run_z:
			end.z = clampf(end.z, it.run_min, it.run_max)
			end.x = it.from.x + it.step.x
		else:
			end.x = clampf(end.x, it.run_min, it.run_max)
			end.z = it.from.z + it.step.z
		it.step = end - it.from

	static func _is_belt_speed(speed: float) -> bool:
		for b: float in BELT_SPEEDS:
			if absf(speed - b) < b * 0.03:
				return true
		return false

	## A speed from two updates' places, as Factorio's belt's when it is within 3% of one.
	static func _belt_speed(v: Vector3) -> Vector3:
		var speed := v.length()
		for b: float in BELT_SPEEDS:
			if absf(speed - b) < b * 0.03:
				return v * (b / speed)
		return v

	## Drops empty slots at the end, and packs a kind whose slots are mostly empty (a belt that
	## emptied), so the GPU doesn't draw thousands of hidden items.
	func _compact(kind: Kind) -> void:
		while not kind.slots.is_empty() and kind.slots.back() == null:
			kind.slots.pop_back()
		var n := kind.slots.size()
		if kind.free.size() > 64 and kind.free.size() * 2 > n:
			var packed := []
			for e in kind.slots:
				if e != null:
					e.slot = packed.size()
					packed.append(e)
			kind.slots = packed
			kind.fresh = packed.duplicate()
			kind.free.clear()
			kind.emptied.clear()
			return
		if kind.free.size() > 0:
			var kept: Array[int] = []
			for i in kind.free:
				if i < n:
					kept.append(i)
			kind.free = kept


var protos: ProtoDB:
	set(value):
		protos = value
		_cards.protos = value

## world.gd: the belts items ride come from its entity records (entities_changed says which chunks
## changed). Without it items glide in straight lines (tests).
var world: WorldMirror = null:
	set(value):
		if world != null and world.entities_changed.is_connected(_on_entities_changed):
			world.entities_changed.disconnect(_on_entities_changed)
		world = value
		if world != null:
			world.entities_changed.connect(_on_entities_changed)

var _cards := ItemCards.new()
var _state := State.new()
## belt_lanes.gd (main.gd sets it): the far icons this layer hands over to.
var lanes: Node = null
var _belt_dirty := {}  # Vector2i chunk -> true: its entities changed since it was indexed
var _indexed := {}  # Vector2i chunk -> whether its whole snapshot was indexed, as the job's graph has it
var _kinds_count := -1  # protos.entities.size() when the belt prototypes were last given to a job
var _given: Array = []  # index_chunk()'s chunks for the next job
var _paths: ImageTexture = null
## The records' texture array (BeltRecords pages, the global f3d_belt_records) and the tick its
## records' ticks are from.
var _records: Texture2DArray = null
var _record_pages := 0
var _clock_base := -1.0
var _paths_image: Image = null  # what _paths was last made from (tests)
var _inbox: Array = []  # messages waiting for the next job
## A big update comes in many parts, which the bridge's message handling may spread over frames
## (bridge.gd, its `messages` slice in frame_budget.gd). They go to a job together, once all have come (or the next update
## does): a job with only some of them stopped the other items until theirs came, a frame or two
## later, and then they jumped on, splitting full lanes apart (owner: "the odd moments they split").
var _parts: Array = []
var _parts_tick := -1
var _job: Job = null
var _task := -1
var _known := {}  # item id -> [lift, turns], kinds item_cards.gd has made
var _rewrite := false  # every slot written again on the next job
## Items glide on the game's clock (the messages' ticks, run on at the game's measured rate), one
## gap between updates behind it: each glide runs from the drawn tick when its update came in
## (_from_tick) to that update's tick (_to_tick). The gap is what the updates say (`p`), eased in
## when the mod is slowed down (`rate`), so items keep an even speed when updates come further apart
## or the server runs slow; they stop only if an update is late.
var _clock := GameClock.new()
var _drawn := -1.0
## Ticks from a job's start to its result being drawn (rising at once, falling slowly), and the
## margin items are drawn behind by for it, eased towards it (see JOB_MARGIN_MAX).
var _job_ticks := 1.0
var _margin := DRAW_MARGIN
var _from_tick := 0.0
var _to_tick := 1.0
var _count := 0
var _square := Vector3(0.0, 0.0, -1.0)
var _positions := {}  # unique id -> [from, step, path] for the ids position_of() asked about
var _watch := {}  # those ids
## Every item's position kept for position_of(), not only those asked for before (probes).
var watch_all := false
var _epoch := -1  # _cards.epoch when the buffers were last written
var _height_known := false
## --belt-items-sync: jobs run on the main thread at once (tests, comparing).
var _sync := false
## Replays (belt_path_replay.gd --fold-ahead): a synchronous job's glides begin this many ticks past
## the drawn clock, as when a job on the worker is drawn sooner than its fold tick said.
var sync_fold_ahead := 0.0
var _held_job: Job = null  # such a job, run, its result waiting for the drawn clock (HOLD_USEC)

## --item-bench: every 5 s, print frame times and this layer's own time (docs/RUNNING.md).
var _bench := false
var _bench_frames := 0
var _bench_time := 0.0
var _bench_worst := 0.0
var _bench_usec := 0
var _bench_worker_usec := 0
var _bench_jobs := 0
## Totals for probes: this layer's main-thread time, its jobs' time on the worker, and how items
## glided (Job.routes: not known, straight on a lane, along a path, snapped, moved too far).
var stats := {"frames": 0, "main_usec": 0, "jobs": 0, "worker_usec": 0, "worst_job_usec": 0, "routes": [0, 0, 0, 0, 0],
	"indexed": 0, "index_usec": 0, "write_usec": 0, "cached": 0, "fresh": 0, "missing": 0, "runs": 0, "walks": [0, 0, 0, 0, 0, 0, 0],
	"route_usec": 0, "fold_usec": 0, "end_usec": 0, "carry_usec": 0, "held": 0, "adopted": 0, "glided_in": 0, "groups": 0,
	"plain_moved": 0, "plain_usec": 0, "plains": 0, "kept_records": 0, "records_written": 0, "pages": 0, "upload_usec": 0}


func _ready() -> void:
	_clock.ease = 0.5  # drawn one gap behind: half speed while a longer gap is taken up
	_cards.name = "Cards"
	add_child(_cards)
	_bench = "--item-bench" in OS.get_cmdline_user_args()
	_sync = "--belt-items-sync" in OS.get_cmdline_user_args()
	if _bench:
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)


func _exit_tree() -> void:
	_wait(false)


func reset() -> void:
	_parts = []
	_parts_tick = -1
	_wait(false)
	var height := _state.height
	_state = State.new()
	_state.height = height
	_inbox.clear()
	_belt_dirty.clear()
	_indexed.clear()
	_kinds_count = -1
	_cards.reset()
	_known.clear()
	_positions.clear()
	_count = 0
	_square = Vector3(0.0, 0.0, -1.0)
	_clock = GameClock.new()
	_clock.ease = 0.5
	_drawn = -1.0
	_records = null
	_record_pages = 0
	_clock_base = -1.0


func count() -> int:
	return _count


## The square round which the items drawn now were read: centre x, y and half side in tiles, or
## z < 0 when the mod doesn't say. belt_lanes.gd draws lane icons from its edge, so the two hand
## over where the items stop, not round the camera, which runs ahead of them while panning.
func covered() -> Vector3:
	return _square


func handle(msg: Dictionary) -> void:
	_clock.heard(float(msg.get("k", 0)), float(msg.get("p", 0)))
	# What reading the update cost the server a tick (`w` work units over `p` ticks): Moving belt
	# items' Automatic keeps it within its share (belt_lanes.gd).
	if msg.has("w") and int(msg.get("part", 1)) == 1 and lanes != null:
		lanes.call("heard_work", float(msg["w"]) / maxf(1.0, float(msg.get("p", 1))))
	var parts := int(msg.get("parts", 1))
	if parts <= 1:
		_flush_parts()
		_inbox.append(msg)
		return
	var k := int(msg.get("k", 0))
	if k != _parts_tick:
		_flush_parts()  # an update a part never came for goes as it is
		_parts_tick = k
	_parts.append(msg)
	if _parts.size() >= parts:
		_flush_parts()


## The parts held so far to the next job.
func _flush_parts() -> void:
	if not _parts.is_empty():
		_inbox.append_array(_parts)
		_parts = []
	_parts_tick = -1


## Waits for the running job and draws what it made (`apply`), or drops it (leaving the tree, a
## reset: nothing is made for a world that is going).
func _wait(apply := true) -> void:
	if _held_job != null:
		if apply:
			_apply(_held_job)
		_held_job = null
	if _task < 0:
		return
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	if apply:
		_apply(_job)
	_job = null


func _process(delta: float) -> void:
	var start := Time.get_ticks_usec()
	_clock.advance(delta)
	var step := delta * _clock.rate
	if not _sync:
		var want := clampf(_job_ticks * margin_jobs + 1.0, DRAW_MARGIN, JOB_MARGIN_MAX)
		_margin = move_toward(_margin, want, step * (0.5 if want > _margin else 0.05))
	if _clock.tick >= 0.0:
		var drawn := _clock.tick - _clock.gap - _margin
		# The gap (eased in at half speed when the mod slows down: `rate`) and the margin (half speed
		# while jobs take longer) growing together stopped the drawn clock or ran it backwards
		# (Zenith Test with 24- to 48-tick updates: 0.6 ticks back over 15 frames), every item with
		# it; the margin grows more slowly instead. A jump of the game's clock is taken as it is.
		var least := _drawn + MIN_PACE * step
		if _drawn >= 0.0 and drawn < least and drawn > _drawn - 60.0 and least <= _clock.tick - _clock.gap:
			drawn = least
			_margin = _clock.tick - _clock.gap - drawn
		_drawn = drawn
	_cards.begin()
	if _epoch != _cards.epoch:
		_epoch = _cards.epoch
		_wait()
		_known.clear()
		_rewrite = true
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		var now := Time.get_ticks_usec()
		if _job.done_usec == 0:
			_job.done_usec = now
		if _drawn >= _job.fold_tick - FOLD_SLACK or now - _job.done_usec >= HOLD_USEC or _clock.tick < 0.0:
			_wait()
	if _held_job != null and (_drawn >= _held_job.fold_tick - FOLD_SLACK or _clock.tick < 0.0):
		var held := _held_job
		_held_job = null
		_apply(held)
	if _task < 0 and not _height_known:
		_find_height()
	if _task < 0 and _held_job == null and (not _inbox.is_empty() or _rewrite):
		_start(delta)
	if _clock_base >= 0.0:
		RenderingServer.global_shader_parameter_set("f3d_belt_clock", _drawn - _clock_base)
	var spent := Time.get_ticks_usec() - start
	stats["frames"] += 1
	stats["main_usec"] += spent
	if _bench:
		_bench_usec += spent
		_bench_report(delta)


func _on_entities_changed(c: Vector2i) -> void:
	_belt_dirty[c] = true


## Items moved from outside the mod's positions (a client-side belt flow, a replay): the item `uid`
## (any id the mod doesn't use: below -2^40, say) of item `item_id`, a stack of `count`, is at `at`
## on game tick `tick` and goes along the belts at `speed` tiles a tick to `stop` (the same place: it
## stands), where it stands until the next call. Its record is written once; the GPU moves it. A
## group or packed lane is the same call for each of its items with one speed and tick (the mod's
## own groups, `bi` bg and bm, are made into items in the job and written the same way).
func set_motion(uid: int, item_id: int, at: Vector3, tick: float, speed: float, stop: Vector3, count := 1) -> void:
	_inbox.append({"t": "motion", "u": uid, "i": item_id, "at": at, "k": tick, "v": speed, "stop": stop, "n": count})


func remove_item(uid: int) -> void:
	_inbox.append({"t": "motion", "u": uid, "gone": true})


## A chunk's entity records (WorldMirror.Rec) given directly, without world.gd (tests, probes).
func index_chunk(c: Vector2i, recs: Array, whole := true) -> void:
	_given.append([c, recs, whole])


## Chunks a job indexes at most: the first square on a busy base is 64 chunks, about 50 us each to
## hand over here; the rest follow with the next updates (items there glide straight meanwhile).
const INDEX_PER_JOB := 12


## The chunks round the square the items come from, for the job to index (new to it, or changed
## since: world.gd's entities_changed) or drop (gone from it).
func _index_belts(job: Job) -> void:
	if protos == null:
		return
	if protos.entities.size() != _kinds_count:
		_kinds_count = protos.entities.size()
		var kinds := {}
		for id in protos.entities:
			var t: int = BeltPaths.TYPES.get((protos.entities[id] as ProtoDB.EntityProto).type, -1)
			if t >= 0:
				kinds[id] = t
		job.kinds = kinds
		for c in _indexed:
			_belt_dirty[c] = true
	job.index.append_array(_given)
	_given.clear()
	if world == null:
		return
	var sq := _square
	for i in range(job.msgs.size() - 1, -1, -1):
		var m: Dictionary = job.msgs[i]
		if m.has("fr"):
			sq = Vector3(int(m.get("fx", 0)) / 256.0, int(m.get("fy", 0)) / 256.0, int(m.get("fr", 0)))
			break
	if sq.z < 0.0:
		return
	var r := sq.z + INDEX_MARGIN
	var lo := WorldMirror.chunk_of(Vector2(sq.x - r, sq.y - r))
	var hi := WorldMirror.chunk_of(Vector2(sq.x + r, sq.y + r))
	for c: Vector2i in _indexed.keys():
		if c.x < lo.x or c.x > hi.x or c.y < lo.y or c.y > hi.y or not world.chunks.has(c):
			job.drops.append(c)
			_indexed.erase(c)
	var todo: Array = []
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			var c := Vector2i(x, y)
			var cv = world.chunks.get(c)
			if cv == null:
				continue
			var whole: bool = cv.parts_expected >= 0 and not cv.is_incomplete()
			if not _indexed.has(c) or _indexed[c] != whole or _belt_dirty.has(c):
				todo.append([c, whole])
	if todo.size() > INDEX_PER_JOB:
		var mid := WorldMirror.chunk_of(Vector2(sq.x, sq.y))
		todo.sort_custom(func(a: Array, b: Array) -> bool: return (a[0] - mid).length_squared() < (b[0] - mid).length_squared())
		todo.resize(INDEX_PER_JOB)
	for e: Array in todo:
		var c: Vector2i = e[0]
		job.index.append([c, world.chunks[c].entities.values(), e[1]])
		_indexed[c] = e[1]
		_belt_dirty.erase(c)


## Items ride just above the belt surface: the top of the belt model, which differs between the
## procedural belt and the one converted from Wube's printable model. Asked for, not made here: the
## model is read on a worker thread (making it at start-up cost 5-15 ms on the main thread), and
## each update places its items at the height known then.
func _find_height() -> void:
	if not ModelLibrary.ready("transport-belt"):
		return
	_height_known = true
	var belt := ModelLibrary.mesh_for("transport-belt")
	if belt != null:
		_state.height = belt.get_aabb().end.y + 0.02


func _start(delta: float) -> void:
	var job := Job.new()
	job.state = _state
	job.msgs = _inbox
	_inbox = []
	job.full = _rewrite
	_rewrite = false
	job.known = _known.duplicate()
	job.model_cap = ItemCards.model_cap
	job.watch = _watch.keys()
	job.watch_all = watch_all
	_watch.clear()
	if lanes != null and is_instance_valid(lanes) and lanes.distance > 0:
		job.far_built = lanes.built_chunks()
	_index_belts(job)
	# Where the glide will be when this job's result is drawn: as many ticks from now as jobs have
	# taken lately, at least a frame (now when the job runs here and is drawn this frame).
	job.fold_tick = _drawn + (sync_fold_ahead if _sync else maxf(delta * _clock.rate, _job_ticks))
	job.started_usec = Time.get_ticks_usec()
	job.fold = _progress_at(job.fold_tick)
	_job = job
	if _sync:
		job.run()
		_job = null
		if sync_fold_ahead > 0.0:
			_held_job = job
		else:
			_apply(job)
	else:
		_task = WorkerThreadPool.add_task(job.run, false, "belt items")


## A finished job's buffers to the MultiMeshes; kinds whose looks weren't made yet are made now
## and written by the next job.
func _apply(job: Job) -> void:
	if not _sync and job.began and _clock.tick >= 0.0:
		if _drawn > job.fold_tick + FOLD_SLACK:
			stats["late"] = int(stats.get("late", 0)) + 1
			stats["late_ticks"] = float(stats.get("late_ticks", 0.0)) + _drawn - job.fold_tick
	_upload(job.pages)
	_clock_base = job.clock_base
	var sq := job.square
	var aabb := AABB(Vector3(sq.x - sq.z - INDEX_MARGIN, -16.0, sq.y - sq.z - INDEX_MARGIN), Vector3(2.0 * (sq.z + INDEX_MARGIN), 96.0, 2.0 * (sq.z + INDEX_MARGIN))) 		if sq.z >= 0.0 else AABB(Vector3(-1.0e5, -16.0, -1.0e5), Vector3(2.0e5, 96.0, 2.0e5))
	for w: Array in job.written:
		_cards.put_records(int(w[0]), int(w[1]), int(w[2]), int(w[3]), aabb)
	if sq != _square:
		_cards.set_bounds(aabb)
	for item_id in job.unknown:
		_cards.prepare(item_id)
		_known[item_id] = [_cards.lift(item_id), _cards.turns(item_id), _cards.pile_step(item_id)]
	_rewrite = _rewrite or not job.unknown.is_empty()
	_count = job.count
	_square = job.square
	if lanes != null and is_instance_valid(lanes):
		# The icons change in this frame too: the square they leave out, the chunks still held by
		# items waiting for them, and the kinds not drawn yet (their icons stay shown).
		var unknown_items := {}
		for key in job.unknown:
			unknown_items[ItemCards.item_of(int(key))] = true
		lanes.hand_over(job.square, job.held_chunks, unknown_items.keys())
	_positions = job.positions
	if job.paths != null:
		_paths_image = job.paths
		if _paths == null or _paths.get_width() != job.paths.get_width() or _paths.get_height() != job.paths.get_height():
			_paths = ImageTexture.create_from_image(job.paths)
			_cards.set_paths(_paths)
		else:
			_paths.update(job.paths)
	stats["jobs"] += 1
	stats["kept_records"] += job.kept_records
	stats["passed"] = int(stats.get("passed", 0)) + job.passed
	for k in ["handle_usec", "missing_usec", "adopt_usec", "cap_usec", "groups_usec"]:
		stats[k] = int(stats.get(k, 0)) + int(job.get(k))
	stats["records_written"] += job.records_written
	stats["worker_usec"] += job.usec
	stats["indexed"] += job.index.size()
	stats["index_usec"] += job.index_usec
	stats["write_usec"] += job.write_usec
	var routed := 0
	for k in 5:
		routed += job.routes[k]
	stats["cached"] += job.updated - routed - job.fresh
	stats["fresh"] += job.fresh
	stats["route_usec"] += job.route_usec
	stats["fold_usec"] += job.fold_usec
	stats["end_usec"] += job.end_usec
	stats["carry_usec"] += job.carry_usec
	stats["runs"] = _state.graph.runs
	stats["walks"] = Array(_state.graph.walks)
	stats["missing"] += job.missing
	stats["held"] += job.held
	stats["adopted"] += job.adopted
	stats["glided_in"] += job.glided_in
	stats["groups"] = job.groups
	stats["plain_moved"] += job.moved
	stats["drifted"] = int(stats.get("drifted", 0)) + job.drifted
	var lg: PackedInt32Array = stats.get("let_go", PackedInt32Array([0, 0, 0, 0]))
	for j in 4:
		lg[j] += job.let_go[j]
	stats["let_go"] = lg
	if not job.resend.is_empty():
		Bridge.send({"t": "bre", "l": job.resend})
	stats["plain_usec"] += job.plain_usec
	stats["chains_usec"] = int(stats.get("chains_usec", 0)) + job.chains_usec
	stats["plains"] = job.plains
	stats["worst_job_usec"] = maxi(stats["worst_job_usec"], job.usec)
	for k in 5:
		stats["routes"][k] += job.routes[k]
	_bench_worker_usec += job.usec
	_bench_jobs += 1
	if not _sync:
		# (Until it finished, not until it was drawn: a result held for the drawn clock would
		# otherwise lengthen the next jobs' fold and the margin, and hold them longer still.)
		var took := ((job.done_usec if job.done_usec > 0 else Time.get_ticks_usec()) - job.started_usec) / 1000000.0 * _clock.rate
		_job_ticks = took if took > _job_ticks else lerpf(_job_ticks, took, 0.1)
	if job.began:
		# The glide reaches the newest update's place when the drawn clock reaches its tick.
		_from_tick = minf(job.fold_tick, job.last_tick - 1.0)
		_to_tick = job.last_tick


## The record pages a job wrote, to the GPU: only those, or the whole texture array when it grew.
func _upload(p: Dictionary) -> void:
	var list: Array = p.get("pages", [])
	if list.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	if bool(p.get("all", false)) or _records == null:
		var images: Array[Image] = []
		for e: Array in list:
			images.append(e[1])
		_records = Texture2DArray.new()
		_records.create_from_images(images)
		_record_pages = images.size()
		RenderingServer.global_shader_parameter_set("f3d_belt_records", _records)
	else:
		for e: Array in list:
			_records.update_layer(e[1], int(e[0]))
	stats["pages"] += list.size()
	stats["upload_usec"] += Time.get_ticks_usec() - t0


## Where an item (by unique id) is drawn now, or null (quality_marks.gd puts its quality there;
## under the ground it isn't drawn). Asked for once, it is known from the next update on.
func position_of(uid: int) -> Variant:
	_watch[uid] = true
	var p: Array = _positions.get(uid, [])
	if p.is_empty():
		return null
	var path: PackedFloat32Array = p[2]
	var t0: float = p[3]
	var t1: float = p[4]
	var g := 0.0 if t1 < 0.0 else (1.0 if t1 <= t0 else clampf((_drawn - t0) / (t1 - t0), 0.0, 1.0))
	if path.is_empty():
		return (p[0] as Vector3) + (p[1] as Vector3) * g
	if Job._hidden_path(path):
		return null
	var o := BeltPaths.path_at(path, g)
	if o.w < 0.5:
		return null
	return (p[0] as Vector3) + Vector3(o.x, o.y, o.z)


## What the shaders draw for a kind now, worked out from its records as belt_path.gdshaderinc does:
## per slot [where (with its lift), cosine of its turn], or null where nothing is drawn (tests).
func drawn(key: int) -> Array:
	var out: Array = []
	var kind: Kind = _state.kinds.get(key)
	if kind == null or kind.base < 0 or _task >= 0:
		return out
	var recs := _state.records
	var t := _drawn - _clock_base
	for slot in kind.slots.size():
		var o := (kind.base + slot) * BeltRecords.FLOATS
		var d := recs.data
		var code := d[o + 11]
		if code < -0.5:
			out.append(null)
			continue
		var g := clampf((t - d[o + 3]) / (d[o + 7] - d[o + 3]), 0.0, 1.0) if d[o + 7] > d[o + 3] else 1.0
		var at := Vector3(d[o], d[o + 1], d[o + 2])
		if code < 0.5:
			at += Vector3(d[o + 4], d[o + 5], d[o + 6]) * g
		elif _paths_image != null:
			var c := int(code + 0.5) - 1
			var first := c / 64
			var pieces := c - first * 64 + 1
			var f := clampf(g, 0.0, 1.0) * pieces
			var i := mini(int(f), pieces - 1)
			var w := _paths_image.get_width()
			var p0 := _paths_image.get_pixel((first + i) % w, (first + i) / w)
			var p1 := _paths_image.get_pixel((first + i + 1) % w, (first + i + 1) / w)
			var p := p0.lerp(p1, f - i)
			if p.a < 0.5:
				out.append(null)
				continue
			at += Vector3(p.r, p.g, p.b)
		out.append([at + Vector3(0.0, d[o + 10], 0.0), d[o + 8]])
	return out


## How far items are along their glide from the last update to the next, 0 to 1.
func _progress() -> float:
	return _progress_at(_drawn)


func _progress_at(drawn: float) -> float:
	return clampf((drawn - _from_tick) / (_to_tick - _from_tick), 0.0, 1.0)


func _bench_report(delta: float) -> void:
	_bench_frames += 1
	_bench_time += delta
	_bench_worst = maxf(_bench_worst, delta)
	if _bench_time < 5.0:
		return
	var vp := get_viewport().get_viewport_rid()
	print("item-bench: %d items, %d kinds, frame %.2f ms avg, %.2f ms worst, %.0f FPS, belt items %.2f ms/frame, worker %.2f ms/job (%d jobs), render cpu %.2f ms, gpu %.2f ms" % [
		_count, _cards.kind_count(), _bench_time * 1000.0 / _bench_frames, _bench_worst * 1000.0,
		_bench_frames / _bench_time, _bench_usec / 1000.0 / _bench_frames,
		_bench_worker_usec / 1000.0 / maxi(_bench_jobs, 1), _bench_jobs,
		RenderingServer.viewport_get_measured_render_time_cpu(vp), RenderingServer.viewport_get_measured_render_time_gpu(vp)])
	_bench_frames = 0
	_bench_time = 0.0
	_bench_worst = 0.0
	_bench_usec = 0
	_bench_worker_usec = 0
	_bench_jobs = 0
