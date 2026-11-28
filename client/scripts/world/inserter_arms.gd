extends Node3D
## Inserter arms near the camera. The mod sends each inserter's hand position and held item a
## few times a second (`ih`, every `p` game ticks, each update stamped with its tick `k`); the
## inserter's base is the static entity with the same unit number.
##
## Two clocks (--inserter-arms-clock=belt|wall, read_flags):
## - belt (the default): arms are drawn at the game tick the belt items are drawn at
##   (belt_items.gd drawn_tick: some way behind the newest update, so there are samples on both sides
##   of the drawn moment), or when no belts are drawn at the arms' own game clock two updates behind
##   (game_clock.gd). Each arm keeps its last seconds of samples by tick, and between the two round
##   the drawn tick the hand is played as Factorio moves it (inserter_swing.gd): straight in angle
##   and reach at the prototype's speeds (eprops `rs`/`es` times its quality, else a table), out to
##   the pickup and drop points (eprops `ip`/`id` turned by the inserter's direction) and back, waiting
##   only there, the item changing hands as it leaves; a belt pickup is solved for where and when the
##   hand met the item. So a fast inserter's whole 12-tick swing shows, reaching both ends, and the
##   hand closes on a belt item the tick the belt loses it. Past the newest sample (the drawn tick
##   caught up) the hand goes on to the end it is bound for and waits.
## - wall: as before. Each arm swings (angle and reach around its base) from where it is drawn to
##   the new hand position over the time until the next update (measured on the wall clock from the
##   update's arrival), so the hand follows an arc rather than cutting across, and the drawn arm then
##   follows that path with a little smoothing, so updates arriving early or late don't make it stop
##   and start. About 10 ticks behind the game, and 6-tick samples of a 12-tick swing never reach the
##   ends; kept to compare (tools/inserter_check.py).
##
## The arm is two pieces of Wube's printable inserter (tools/models/wube_recipes.py,
## `inserter-arm-<family>-*`): the upper arm, rising from the shoulder on the base to an elbow,
## and the hand, reaching down from the elbow to the wrist over the belt (two-bone IK, solved per
## frame), open, or closed while it holds an item. Each inserter has its family's pieces (basic,
## long, bulk, stack) in its own colour (ARM_TINTS, picked from its sprites), stretched along
## their length to its reach. Without those models: a placeholder turntable, two boxes and a
## hand with two fingers. Everything is instanced: one MultiMesh per part (and per prototype).
##
## Events (--inserter-events=on|off, on; the hello asks for `ie` with the belt clock): instead of
## samples the mod sends what each hand did as it happened (inserters.lua: picked {tick, count, item,
## where}, dropped {tick, remaining, where}, a status change, a position now and then and once or
## twice mid-swing, gone), each a few times over the next ticks so a lost datagram loses none. From
## the last event at or before the drawn tick the swing follows (inserter_swing.gd plan_events): a
## hand that took goes to the drop at its speeds and waits there until it dropped, one that dropped
## goes back and reaches for the item it takes next where it takes it. So the pickup and drop ticks
## are the game's own (not solved from samples 6 ticks apart), a bulk hand shows its first item at
## the grab, and the sweep's side comes from the mid-swing positions. A hand without power, frozen or
## disabled (the status says) is drawn from its positions as samples. Without events (an older mod,
## the menu's recorded stream, `wall`) the samples alone, as before.
##
## A modeller's inserter rigged as an arm (model_rig.gd: joints Base, Rotation, Lower Arm, Upper Arm,
## Pincer1, Pincer2) replaces Wube's pieces for its prototype: its turntable yaws to the hand, its
## lower and upper arm come from the same two-bone IK with the rig's own joints and lengths, and its
## pincers turn about their joints to close while the hand holds an item. Its own materials, no tint.
##
## Drawn by the Factorio pack (model_packs.gd FACTORIO_ID winning for the inserter: ModelLibrary.draws_sprite),
## whose platform is its own picture on a card (sprite_standins.gd), the arm is Factorio's too: the prototype's
## hand_base_picture from the shoulder to the elbow and hand_open_picture (empty) or hand_closed_picture (holding)
## from the elbow to the grip, read from the install (`__base__` / `__space-age__`
## graphics/entity/<name>/<name>-hand-*.png), each a strip stretched along its piece and laid in Factorio's camera
## plane as the platform's card is (FACTORIO_PITCH), just in front of it. The joints are the 3D arm's (the same
## shoulder, IK elbow and grip, projected along the camera onto that plane), so the hand is where the 3D arm's
## would be, and the held item is drawn in its grip as before; one MultiMesh per prototype and picture, the
## resting arms' too. An inserter whose pictures aren't found (no install, a mod's) keeps the 3D arm.
## --inserter-sprite-arms=off: the 3D arm as before. The shadows' pictures aren't drawn (the cards cast their own).
##
## --inserter-arms-trace=<file>: a line per frame with each drawn hand (unit, x, y in tiles, held
## item), the game tick the arms stand for, the belts' drawn tick and the frame's arm cost, for
## tools/inserter_check.py against the bridge's /f3d-ih trace.

const ProtoDB := preload("res://scripts/world/protos.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")
const Swing := preload("res://scripts/world/inserter_swing.gd")
const GameClock := preload("res://scripts/world/game_clock.gd")
const BeltSimConst := preload("res://scripts/world/belt_sim.gd")
## (rest arms) Plain vertex-coloured boxes on the hills: the loose items' shader (no record: belt_base -1).
const RestShader := preload("res://shaders/item.gdshader")
const SpriteStandins := preload("res://scripts/world/sprite_standins.gd")
const ModFiles := preload("res://scripts/world/mod_files.gd")
const ViewPriority := preload("res://scripts/world/view_priority.gd")
const Probing := preload("res://scripts/debug/probing.gd")

## An arm missing from this many updates in a row (the inserter left the radius, or was mined) is
## dropped. Every update is the full list, so this counts updates (`k` changes), not ticks.
const MISSING_FRAMES := 2
## (belt clock) Samples older than this many ticks before the newest are forgotten: the drawn tick
## is at most --belt-draw-margin (120) plus a gap behind.
const RING_TICKS := 300
## The placeholder base is Visuals.HEIGHTS["inserter"] tall; the arm stands on it.
const SHOULDER_HEIGHT := 0.5
const HAND_HEIGHT := 0.36  # wrist height: the hand's fingers reach down to the items
const UPPER_ARM := 0.62
const FOREARM := 0.62
const ARM_THICKNESS := 0.065
const TURNTABLE := Vector3(0.3, 0.08, 0.3)
const SHOULDER := Vector3(0.14, 0.14, 0.16)
const HAND_SIZE := Vector3(0.14, 0.05, 0.2)
const FINGER_SIZE := Vector3(0.025, 0.12, 0.05)
const ITEM_DROP := 0.14  # how far below the wrist the held item hangs
## (wall clock) Smoothing of the drawn arm towards the interpolated path, per second.
const FOLLOW_RATE := 30.0
const STEEL := Color(0.52, 0.52, 0.5)
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const ModelRig := preload("res://scripts/world/model_rig.gd")
const Switches := preload("res://scripts/switches.gd")
const Wire := preload("res://scripts/util/wire.gd")
## A rig's grip (between its pincers) goes where the held item is drawn.
const GRIP_HEIGHT := HAND_HEIGHT - ITEM_DROP
## (--inserter-grip) The grip rides this far above where belt items are drawn when that is higher (a modeller's
## belts are taller: Vasillo's tops are at 0.25, Zenith's 0.2), so the hand closes on a belt item where it is.
const GRIP_ABOVE_BELT := 0.03
## How far a rig's arm may straighten before it is stretched to reach (a modeller's arm shorter than
## the inserter's reach); stretched, the arm is longer than modelled.
const RIG_REACH := 0.98
## Pincers close and open in this much of a second.
const CLOSE_TIME := 0.12
## Inserter prototype -> arm family (inserter-arm-<family>-*.glb); anything else is basic.
const ARM_FAMILIES := {"long-handed-inserter": "long", "bulk-inserter": "bulk", "stack-inserter": "stack"}
## Arm paint per prototype: [upper arm, hand], from its sprites (hand-base.png, hand-open.png)
## as tools/models/part_colors.py turns a sprite's colour into an albedo (the densest colour of
## the paint, divided by the light Factorio painted in from above, exposure and saturation). The
## upper arm is darker than the hand in every tier. The stack inserter's upper arm is worn steel
## round a yellow inset (their mean), its hand's paint the bright yellow of its forearms.
const ARM_TINTS := {
	"burner-inserter": [Color("56514e"), Color("5d453b")], "inserter": [Color("9a5206"), Color("cb7000")],
	"long-handed-inserter": [Color("93221f"), Color("d2431f")], "fast-inserter": [Color("0a6597"), Color("5581bc")],
	"bulk-inserter": [Color("487c01"), Color("628728")], "stack-inserter": [Color("816347"), Color("be8f00")],
}
const ARM_EDGE_WEAR := 0.12
## Per family: upper arm (shoulder to elbow) and hand (elbow to wrist) as modelled, in tiles,
## and how much both are stretched so the hand reaches the inserter's drop position.
const ARM_LENGTHS := {
	"basic": [0.792, 0.604, 1.0], "long": [1.152, 0.964, 1.07],
	"bulk": [0.792, 0.504, 1.05], "stack": [0.792, 0.584, 1.02],
}
## The Wube base's top, where the arm's tab plugs in.
const MODEL_SHOULDER := 0.38
enum ArmPiece { UPPER, OPEN, CLOSED }
const DARK_STEEL := Color(0.3, 0.3, 0.3)
## The belt-like types a pickup point on one makes a belt pickup (inserter_swing.gd belt_pick).
const BELT_TYPES := ["transport-belt", "underground-belt", "linked-belt", "splitter", "lane-splitter", "loader", "loader-1x1"]

## Part meshes in draw order; each is a unit-ish box (or cylinder) scaled per instance.
enum Part { TURNTABLE, SHOULDER, UPPER, FOREARM, HAND, FINGERS }

## --inserter-arms-clock=belt (the default) | wall: see the top.
static var belt_clock := true
## --inserter-events=off (the default) | items | on: `on` asks the mod for `ie` (with the belt clock)
## and draws the swing from the events; `items` asks for both (hello `ie` 2) and draws the swing from
## the samples as before, the held item alone following the events (exact picks and drops; the
## sampled positions follow the game's lifted item mid-swing, which the events can't); `off`: samples.
static var events := false
static var events_items := false
## --inserter-handoff=on (the default) | off: the belt items an inserter takes leave the drawn belt as its
## hand closes on them, and those it puts appear where and when it lets go. The hello asks for `ie` (with
## `items` when --inserter-events is off: the pose from the samples, the held item from the events) and
## for the items' ids (`ho`: inserters.lua's placed records); belt_items.gd hands each pick from a belt
## and each put to its simulation on the event's tick (BeltSim.take_at, put_at: the item nearest the
## hand taken off the lane then, its record hidden from that tick; the put item on its lane then), and
## the arms here steer the hand onto the item's drawn place over the last STEER_IN ticks before the
## grab (and the drop's place before it lets go), easing back over STEER_OUT ticks after.
static var handoff := true
## --inserter-grip=on (the default) | off: the item a hand carries is drawn in its grip: its middle between a
## rig's pincers (half way along them), which close onto its sides (ModelRig.HELD_HALF) instead of meeting
## through it, or between the fingers of Wube's claw, whose middle the arm now reaches the hand's place with
## (the wrist reached it, the claw ending 0.15-0.3 tiles past); a model turned with the hand; the grip no lower
## than the belt items drawn (GRIP_ABOVE_BELT). Off, as before: the item's base at the grip (a rig) or ITEM_DROP
## below the wrist, the pincers closed till they met, so a rig's closed pincers hid the item (owner, K8).
static var held_grip := true
## Up to this many items drawn stacked in one inserter hand (matching belt stacks).
const MAX_HELD_STACK := 4
## --inserter-hand-stack=on (the default) | off: when an inserter holds more than one item, stack them vertically
## in its hand like a belt pile; off draws a single item as before.
static var hand_stack := true
## --inserter-rest-arms=on (the default) | off | box: an inserter the bridge sends no hand for draws its
## arm at rest, the hand empty at its pickup (Factorio's idle hand waits there). The bridge sends hands only
## within its detail radius of the focus (`f3d-detail-radius`, 24 tiles by default), so past that every
## resting 3D inserter draws its active pack's 3D arm model in its static pickup pose via batched per-chunk
## MultiMeshInstance3Ds (or Factorio's pictures for sprite packs), worked out per chunk when its entities
## change (for at most REST_USEC of a frame) or one of its inserters' live arms comes or goes (at once), put
## together at most every REST_REFRESH seconds (at once for a live arm), never per frame.
## --inserter-rest-arms=box forces the cheap 3-BoxMesh stick fallback for all 3D resting arms; off draws none.
static var rest_arms := not (Switches.has("--inserter-rest-arms=off"))
static var rest_box_fallback := Switches.has("--inserter-rest-arms=box")
## (rel-031-restarms) --rest-arm-shadows=live (the default) | tier: a resting 3D arm casts its shadow wherever a live
## arm would (a live arm's MultiMeshes always cast): in every chunk whose shadows can reach the ground in view
## (shadow tiers NEAR and FAR) at every Level of detail. `tier`: as before, a resting arm in a FAR chunk casts only on
## High/Ultra (--inserter-shadows), like the inserter's body under --shadow-small. Costs about one shadow-pass draw
## per FAR chunk with resting arms per arm mesh (a rig's 4, Wube's pieces 2) on Low/Medium.
static var rest_shadows_live := not Switches.has("--rest-arm-shadows=tier")
## (rel-031-restarms) --rest-arm-basic=live (the default) | stick: an inserter with no arm model (no rig, no Wube
## pieces: a mod's) rests drawn as its live arm is (Mode.BASIC: turntable, shoulder post, upper arm, forearm, hand,
## two fingers, the prototype's colours, Visuals.instance_material, shadows as above) in the per-chunk 3D MultiMeshes.
## `stick`: as before, a thin 3-box stick in RestShader without a shadow.
static var rest_basic_live := not Switches.has("--rest-arm-basic=stick")
## (rel-031-restbatch) --rest-arms-region=<n>|off (2; 4x4 drew more triangles in the second PC's bench): the resting 3D arms of n x n chunks (2: 64 x 64 tiles) drawn by
## one MultiMeshInstance3D per arm mesh, not one per chunk. The per-chunk work is as before (a chunk's buffers worked out
## when its entities or live arms change); only the upload joins the region's chunk buffers (concatenated, nothing per
## arm) into the region's MultiMeshes when any of its chunks changed. Same meshes, layouts, materials and transforms; a
## region casts shadows if any of its chunks would (`_rest_3d_cast_shadow`, so --rest-arm-shadows=tier per region the
## same way) and shows if any of its chunks shows; bounds worked out by Godot from its instances. off (or 1): one per
## chunk as before.
static var rest_region := _rest_region_size()
## --rest-arms-chunked=off: fall back to rebuilding the single global resting-arms MultiMesh.
static var rest_arms_chunked := true
## --inserter-sprite-arms=on (the default) | off: see the top (an inserter drawn by the Factorio pack).
static var sprite_arms := true
## --ih-apply=quick (the default) | old: a hand update (`ih`) binds an arm to its record again only when the
## record, its direction, position or pack, or the models in use changed (_bind looked its model's placement
## up for every hand of every update, most of the handling's time), and an arm's place in the preplan queue
## is a flag, not a search of the queue; a new arm's belt at its pickup (_belt_at) is looked for only among what
## stands within a tile. Old: as before. What is drawn is the same either way.
static var quick_apply := true
## --inserter-fast-upload=on (the default) | off: bulk upload transforms and colors via
## RenderingServer.multimesh_set_buffer instead of per-instance set_instance_transform / color.
static var fast_upload := Switches.on("--inserter-fast-upload")
## --native-inserters=on (the default) | off: the arms' geometry (every arm's pieces, their transforms written
## straight into the MultiMesh buffers) worked out by InserterArmsNative (native/belt_sim/src/inserter_arms_native.cpp)
## when the native library has it; off, or without it: the GDScript below, the same arms.
static var native_inserters := Switches.on("--native-inserters")
## --rest-arms-index=on (the default) | off: each chunk's inserters and belts kept in an index (RestIndex, made by
## one walk of the chunk, dropped when its entities change), so a resting arms' rebuild walks only its inserters
## and a new arm's belt at its pickup (_belt_at) looks only at the cells round it; the resting arms' 3D and picture
## transforms worked out by InserterArmsNative a model at a time (the box arms and the no-native case stay in
## GDScript); the resting arms' shadow settings looked at 32 chunks a frame in turn. Off: every one as before
## (the chunk's every entity walked, each resting arm posed in GDScript, every chunk's shadow every frame).
static var rest_index := not Switches.has("--rest-arms-index=off")
## --native-inserter-swing=on (the default) | off: the plans between two samples (_plan_pair) made by InserterSwingNative
## (native/belt_sim/src/inserter_swing_core.h, a line-for-line twin of inserter_swing.gd) when the native library has it.
## Off, or without it: Swing.plan as before. (Only the GDScript pose below uses it: see --native-inserter-pose.)
static var native_swing := not Switches.has("--native-inserter-swing=off")
## --native-inserter-pose=on (the default) | off: the live arms' samples, events, plans and pose kept and worked out by
## InserterPoseNative (native/belt_sim/src/inserter_pose_native.cpp: Arm's samples and events, _add_sample, _backdate,
## _preplan_some, _plan_pair, _pose_at and _item_from_events), one call a frame for every arm (pose_all), the loop
## below reading each arm's pose from its arrays. Belt clock only, with the pose from the samples (the default, and
## --inserter-events=off/items): --inserter-events=on and --inserter-arms-clock=wall keep the GDScript. Off, or without
## the native class: the GDScript as before, the same poses.
static var native_pose := not Switches.has("--native-inserter-pose=off")
## --native-inserter-loop=on (the default) | off: with the native pose, the rest of the per-arm loop in InserterPoseNative
## too (frame_check, frame_draw): which arms' records are there, the pincers' easing, the L4 moving state, the held
## item's grabs, every arm's geometry by batch (InserterArmsNative's, the same functions) and the live set's changes,
## one call a frame; the GDScript sees only what changed (arms to bind or decide a mode for, hands steered onto a belt
## item, holding arms, moving told to the animator, arms that came or left). Not with --inserter-arms-trace, the tests'
## keep_sprite_xf, or an arm without a native slot (that frame runs the loop below). Off: the loop below every frame.
static var native_loop := not Switches.has("--native-inserter-loop=off")
const REST_SHADOW_CHUNKS := 32
const REST_REGION_DEFAULT := 2
const REST_USEC := 300
const REST_REFRESH := 0.25
const REST_UPPER := 0.07  # the boxes' thickness: upper arm, forearm
const REST_FORE := 0.055
const REST_HAND := Vector3(0.12, 0.05, 0.16)
## (rest arms) Wube's claw's middle along the hand before its model is read (the basic hand's: 1.24).
const CLAW_DEFAULT := 1.24
## The `ie` kinds (inserter_swing.gd Ev) belt_items.gd reads, and placed (the hello's `ho`: an item an
## inserter put on a belt, [6, unit, tick, lane, line position, uid, item, stack, belt]), for belt_items.gd.
const EV_PICKED := 1
const EV_GONE := 5
const EV_PLACED := 6
## (handoff) Ticks before a grab or drop the hand is steered onto the item's drawn place, and after it
## eased back to its own swing.
const STEER_IN := 4.0
const STEER_OUT := 3.0
## An arm nothing was heard of (an event or a sample) for this many ticks is dropped: the mod
## sends every hand's position at least every 300.
const STALE_TICKS := 1200
## How many plans between samples are made ahead each frame (spreading the ~35 an update's tick
## would otherwise cost in one frame): at least this many, else a quarter of what waits.
const PREPLAN_MIN := 4
## (events) An arm keeps at least this many cycles of events, however old (the mod probes the
## sweep's side once in 8 legs: 4 cycles).
const KEEP_CYCLES := 6
## (L4) A hand counts as moving (anim.gd arm_moving: a modeller's burner inserter's burner lit) from a frame it
## is drawn turning or reaching until it has stood still this many game ticks: a hand working a steady line
## waits only a few ticks at each end, so its burner stays lit through them; one waiting for items goes dark.
const MOVING_HOLD := 30.0
const STILL := 1e-4  # radians and tiles a frame under which a hand stands still
## (sprite arms) The pictures, in SpritePiece order, as `<name>-hand-<piece>.png`; the mods looked in; the
## pictures' scale (Factorio's high-resolution 0.25: 128 px a tile); how far the claw's picture runs past the
## grip (a share of the hand's length: the item sits between its fingers); how far in front of the platform's
## card the base piece and the hand are laid (tiles, along the card's facing).
enum SpritePiece { BASE, OPEN, CLOSED }
const SPRITE_FILES := ["base", "open", "closed"]
const SPRITE_MODS := ["base", "space-age"]
const SPRITE_SCALE := 0.25
const HAND_TIP := 0.2
const SPRITE_DEPTH := 0.03
const SPRITE_HAND_DEPTH := 0.05


class Arm:
	var base := Vector2.ZERO  # tiles
	var proto_name := ""
	var color := Color.WHITE
	var item_id := 0  # what the hand is drawn holding
	var item_count := 0  # how many items the hand holds (0 empty; stacked up to MAX_HELD_STACK)
	## The kind it is drawn as (ItemCards.variant_key: its model's variant), picked each time the hand takes
	## something new (grabs counts them, with what it held) and kept while it holds it.
	var held_key := 0
	var held_was := 0
	var grabs := 0
	var angle := 0.0  # where it is drawn
	var reach := 0.0
	var seen_angle := NAN  # (L4) where it was drawn the frame before, and the tick it last moved then
	var seen_reach := NAN
	var moved_at := -INF
	var placed := Transform3D.IDENTITY  # the base model's transform (ModelLibrary.placed)
	var dir := 0
	var model_name := ""  # its prototype's model name, `name@pack` for a building's own pack (sprite arms)
	var card_lift := NAN  # (sprite arms) its platform card's lift towards the camera, NAN until known
	var sprite_xf: Array = []  # (sprite arms, tests) the base's and hand's transforms drawn last, and the hand's SpritePiece
	var close := 0.0  # a rig's pincers: 0 open, 1 closed on an item
	# (wall clock) The update interpolation: from the pose the path had when the update came to the
	# new sample, and where the path is now.
	var from_angle := 0.0
	var to_angle := 0.0
	var from_reach := 0.0
	var to_reach := 0.0
	var path_angle := 0.0
	var path_reach := 0.0
	# (belt clock) Samples by game tick, oldest first (the last RING_TICKS), and the swing model's
	# knowledge of this inserter: its end poses [angle, reach] ([] unknown), speeds, the sweep's side
	# (NAN unknown), whether it takes from a belt, the last item it held; the plan between the two
	# samples round the drawn tick, by its first sample's tick.
	var ticks := PackedFloat64Array()
	var angles := PackedFloat32Array()
	var reaches := PackedFloat32Array()
	var items := PackedInt32Array()
	# Per sample: the angle of the nearest sample at or before it holding something clear of the
	# ends, and of any sample clear of the ends (NAN none): the sweep's side for a plan from it.
	var side_out := PackedFloat32Array()
	var side_any := PackedFloat32Array()
	var pick: Array = []
	var drop: Array = []
	var ends_tried := false
	var belt_pick := false
	var omega := 0.014
	var v := 0.035
	var side := NAN
	var last_item := 0
	var plan_ka := -1.0
	var plan: Array = []
	var plan_still_until := -1.0  # the plan's end when it stands still (most arms, most of the time)
	var plans := {}  # plans made ahead (preplan), by their first sample's tick
	var bound := false  # its record (base, prototype) known
	# (quick_apply) What _bind last read: the record, its direction, prototype and pack, and the models' versions.
	var bound_rec: Object = null
	var bound_dir := 0
	var bound_proto := -1
	var bound_pack := ""
	var bound_gen := -1
	var bound_ver := -1
	# (render dispatch cache) Mode and model version when the arm's draw dispatch was determined.
	enum Mode { NONE, SPRITE, RIG, MODEL, BASIC }
	var mode := Mode.NONE
	var mode_pack_ver := -1
	var mode_model_ver := -1
	var mode_cards: Dictionary = {}
	var mode_rig: Dictionary = {}
	var preplanned := false  # (quick_apply) in _preplan
	## (--native-inserter-pose) Its slot in InserterPoseNative (-1: the GDScript keeps its samples and events), and
	## whether it has had an event (its events are kept there).
	var slot := -1
	var unit := 0  # (--native-inserter-loop) its unit, and its record's chunk (_bind)
	var chunk := Vector2i.ZERO
	var loop_in := false  # counted in _loop_chunks, under loop_chunk
	var loop_chunk := Vector2i.ZERO
	var ev_any := false
	var last_heard := -1.0  # the newest event's or sample's tick
	# (events) By tick, oldest first: kind (Swing.Ev), count, item, c (PICKED/DROPPED: how many
	# ticks before it may have happened; STATUS/SYNC: the status code), the hand's position (tiles,
	# absolute; NAN unknown), the belt (unit) the item came from or went to (0: none), and the
	# status code as of the event. The plan from the event at or before the drawn tick (eplan), for
	# event index eplan_i; eplan_open: made without a next event (on past it).
	var ev_ticks := PackedFloat64Array()
	var ev_kind := PackedInt32Array()
	var ev_count := PackedInt32Array()
	var ev_item := PackedInt32Array()
	var ev_c := PackedInt32Array()
	var ev_x := PackedFloat32Array()
	var ev_y := PackedFloat32Array()
	var ev_belt := PackedInt32Array()
	var ev_code := PackedInt32Array()
	var ev_start := PackedByteArray()  # 1: a pick with the hand empty before it (a cycle's start)
	var cycles := 0  # cycle starts kept
	var eplan: Array = []
	var eplan_i := -1
	var eplan_open := false
	var eplan_still_until := -1.0
	## (handoff) Where the hand meets a belt item: [tick, uid (0: none), x, z (tiles, where the item is
	## then), taken (true) or put], oldest first.
	var meets: Array = []

	## An event, kept by tick (the mod sends each a few times: the same tick, kind and count is one).
	func add_event(k: float, kind: int, count: int, item: int, c: int, x: float, y: float, belt: int) -> bool:
		var n := ev_ticks.size()
		var i := n
		while i > 0 and ev_ticks[i - 1] >= k:
			if ev_ticks[i - 1] == k and ev_kind[i - 1] == kind and ev_count[i - 1] == count:
				return false
			i -= 1
		var code := ev_code[i - 1] if i > 0 else 0
		if kind == Swing.Ev.STATUS or kind == Swing.Ev.SYNC:
			code = c
		ev_ticks.insert(i, k)
		ev_kind.insert(i, kind)
		ev_count.insert(i, count)
		ev_item.insert(i, item)
		ev_c.insert(i, c)
		ev_x.insert(i, x)
		ev_y.insert(i, y)
		ev_belt.insert(i, belt)
		ev_code.insert(i, code)
		var starts := 1 if kind == Swing.Ev.PICKED and (i == 0 or ev_count[i - 1] == 0) else 0
		ev_start.insert(i, starts)
		cycles += starts
		if i < n:
			# (Out of order: the codes after it follow from it when they were inherited.)
			for j in range(i + 1, n + 1):
				if ev_kind[j] != Swing.Ev.STATUS and ev_kind[j] != Swing.Ev.SYNC:
					ev_code[j] = ev_code[j - 1]
		if eplan_i >= i:
			eplan_i = -1  # (the plan's events moved, or a new one came within it)
		elif eplan_open:
			eplan_i = -1
		if item != 0 and count > 0:
			last_item = item
		last_heard = maxf(last_heard, k)
		# (Old events go, but the last KEEP_CYCLES cycles stay however old: the sweep's side of a cycle
		# follows from a probe within the last few, inserter_arms.gd _event_side.)
		while ev_ticks.size() > 2 and ev_ticks[0] < k - RING_TICKS and cycles > KEEP_CYCLES:
			cycles -= ev_start[0]
			ev_start.remove_at(0)
			ev_ticks.remove_at(0)
			ev_kind.remove_at(0)
			ev_count.remove_at(0)
			ev_item.remove_at(0)
			ev_c.remove_at(0)
			ev_x.remove_at(0)
			ev_y.remove_at(0)
			ev_belt.remove_at(0)
			ev_code.remove_at(0)
			eplan_i -= 1
		return true

	func add_sample(k: float, a: float, r: float, item: int, clear_of_ends: bool) -> void:
		last_heard = maxf(last_heard, k)
		var n := ticks.size()
		if n > 0 and k <= ticks[n - 1]:
			return
		ticks.append(k)
		angles.append(a)
		reaches.append(r)
		items.append(item)
		side_out.append(a if clear_of_ends and item != 0 else (side_out[n - 1] if n > 0 else NAN))
		side_any.append(a if clear_of_ends else (side_any[n - 1] if n > 0 else NAN))
		if item != 0:
			last_item = item
		while ticks.size() > 1 and ticks[0] < k - RING_TICKS:
			plans.erase(ticks[0])
			ticks.remove_at(0)
			angles.remove_at(0)
			reaches.remove_at(0)
			items.remove_at(0)
			side_out.remove_at(0)
			side_any.remove_at(0)


var protos: ProtoDB:
	set(value):
		protos = value
		_cards.protos = value
## The world mirror, for each inserter's position and prototype.
var world: Node3D
## The belt item layer (belt_items.gd), whose drawn tick the arms follow (belt clock); null without.
var belts: Node3D
## The build cursor's prototype properties (ui_model.gd eprops: proto id -> {"x": {"ip", "id", "rs",
## "es", ...}}), for the end poses and speeds; the Dictionary itself, filled as the handshake comes.
var eprops := {}

var _cards := ItemCards.new()
var _arms := {}  # unit -> Arm
var _missing := {}
var _seen := {}
var _frame_tick := -1
var _prev_frame_tick := -1
var _frame_msec := 0
var _frame_length := 0.1
var _period := 6.0  # the updates' `p`, ticks between them
var _clock := GameClock.new()  # (belt clock) the arms' own game clock, for when no belts are drawn
var _drawn := -1.0  # (belt clock) the game tick the arms are drawn at
var _parts: Array[MultiMeshInstance3D] = []
## Prototype name -> [MultiMeshInstance3D per ArmPiece], or null when its models are missing.
var _model_parts := {}
var _parts_packs := -1  # ModelPacks.version the pieces were made under
## Prototype name -> its model's arm rig (ModelLibrary.rig_for) with "mmis" (a MultiMeshInstance3D per
## ModelRig.Part, null for a part it lacks), or {} without one.
var _rigs := {}
## Prototypes whose rig had to be stretched to reach (said once).
var _stretched := {}
var _trace: FileAccess
var _frames := 0
var _preplan: Array = []  # arms whose newest pair of samples has no plan yet (planned a few a frame)
var _newest_event := -1.0  # the newest `ie` message's tick
var _swept := -1.0  # (events) when stale arms were last dropped
var _events_heard := false  # an `ie` has come: the events say which arms there are
var steered := 0  # (handoff, probes) hands steered onto a belt item, frames x arms
## (--inserter-arms-trace with --inserter-handoff) Each meeting as it comes: {"meet": [inserter, tick, uid,
## x, z, why]} (tools/inserter_check.py).
var trace_meets := true
var _upload_bufs := {}  # RID -> PackedFloat32Array
var _scratch_lists := []
var _scratch_colors: Array[Color] = []
var _scratch_held := {}
var _scratch_held_yaws := {}
var _scratch_model_lists := {}
var _scratch_rig_lists := {}
var _scratch_sprite_lists := {}
var _scratch_live := {}
const NativeLibrary := preload("res://scripts/native_library.gd")
## (--native-inserters) The native geometry, null when off or missing; tried once, on the first frame.
var _native: RefCounted = null
var _native_tried := false
var _pn: RefCounted = null  # (--native-inserter-pose) InserterPoseNative
var _pn_tried := false
var _pn_loop := false  # (--native-inserter-loop) _pn has frame_check and frame_draw
var _pn_counts := false  # (_pn has counts() and 5-element pose_one / 12-element hold)
var _sw: RefCounted = null  # (--native-inserter-swing) InserterSwingNative
## (--native-inserter-loop) Arms by native slot, how many arms have one, the arms with meets (handoff steering), the
## batch keys ([batch mode, key, prototype, cards, rig] each, by index; "mode:key" -> index), the chunks arms stand in,
## sprite arms whose card lift isn't known yet, whether the last frame ran natively, the models' versions it saw, and
## the animator's moving count it left (-1 unknown).
var _slot_arms: Array = []
var _slot_count := 0
var _meet_arms := {}
var _loop_keys: Array = []
var _loop_key_index := {}
var _loop_chunks := {}  # chunk -> how many bound arms stand in it (_loop_chunk_set)
var _lift_wait := {}
var _loop_was := false
var _loop_pack_ver := -1
var _loop_model_ver := -1
var _loop_moving := -1
var loop_frames := 0  # (tests) frames the native loop ran
var _sw_tried := false
## (tests) Keep each sprite arm's transforms in Arm.sprite_xf with the native path too.
var keep_sprite_xf := false
## One mode's arms of one key (model name or prototype) this frame, for the native batch: its inputs and the
## order slots (_ord_*) their wrists and grips are put back in.
class NBatch:
	var inp := PackedFloat32Array()
	var slots := PackedInt32Array()
	var first: Arm = null
	var arms: Array = []  # (tests, keep_sprite_xf) the sprite arms in order
## Native batches by mode (0 sprite, 1 rig, 2 model, 3 basic), each key -> NBatch, and the arms in the order drawn:
## the arm, its unit, and (once the batches ran) its wrist, grip and whether it grips.
var _nb: Array = [{}, {}, {}, {}]
var _ord_arms: Array = []
var _ord_units := PackedInt64Array()
var _ord_wrist := PackedVector3Array()
var _ord_grip := PackedVector3Array()
var _ord_gripped := PackedByteArray()
var _nres: Array = [{}, {}, {}, null]  # per mode: key -> the native result


static func read_flags(args: PackedStringArray) -> void:
	for a in args:
		if a.begins_with("--inserter-arms-clock="):
			belt_clock = a.substr(22) != "wall"
		elif a.begins_with("--inserter-events="):
			var v := a.substr(18)
			events = v == "on" or v == "items"
			events_items = v == "items"
		elif a.begins_with("--inserter-handoff="):
			handoff = a.substr(19) != "off"
		elif a.begins_with("--inserter-grip="):
			held_grip = a.substr(16) != "off"
		elif a.begins_with("--inserter-hand-stack="):
			hand_stack = a.substr(22) != "off"
		elif a.begins_with("--inserter-rest-arms="):
			var v := a.substr(21)
			rest_arms = v != "off"
			rest_box_fallback = v == "box"
		elif a.begins_with("--rest-arm-shadows="):
			rest_shadows_live = a.substr(19) != "tier"
		elif a.begins_with("--rest-arm-basic="):
			rest_basic_live = a.substr(17) != "stick"
		elif a.begins_with("--rest-arms-chunked="):
			rest_arms_chunked = a.substr(20) != "off"
		elif a.begins_with("--inserter-sprite-arms="):
			sprite_arms = a.substr(23) != "off"
		elif a.begins_with("--ih-apply="):
			quick_apply = a.substr(11) != "old"
		elif a.begins_with("--inserter-fast-upload="):
			fast_upload = a.substr(23) != "off"
		elif a.begins_with("--native-inserters="):
			native_inserters = a.substr(19) != "off"
		elif a.begins_with("--rest-arms-index="):
			rest_index = a.substr(18) != "off"
		elif a.begins_with("--native-inserter-swing="):
			native_swing = a.substr(24) != "off"
		elif a.begins_with("--native-inserter-pose="):
			native_pose = a.substr(23) != "off"
		elif a.begins_with("--native-inserter-loop="):
			native_loop = a.substr(23) != "off"
	if handoff and not events:
		# (The hand-off needs the events: the pose stays the samples', the held item follows the events.)
		events = true
		events_items = true


static func flags_text() -> String:
	var rest_text := "off" if not rest_arms else ("box" if rest_box_fallback else "on")
	return "arms clock %s, events %s, handoff %s, grip %s, rest arms %s" % ["belt" if belt_clock else "wall", "off" if not wants_events() else ("items" if events_items else "on"),
		"on" if wants_handoff() else "off", "on" if held_grip else "off", rest_text]


## Whether the hello should ask for the items inserters put on belts (`ho`), for the hand-off.
static func wants_handoff() -> bool:
	return handoff and wants_events()


## Whether the hello should ask the mod for `ie` (events) instead of `ih` (samples).
static func wants_events() -> bool:
	return events and belt_clock


## What the hello says: 0 samples, 1 events, 2 both (the item from the events, the pose from samples).
static func hello_ie() -> int:
	if not wants_events():
		return 0
	return 2 if events_items else 1


func _ready() -> void:
	read_flags(Switches.args())
	for a in Switches.args():
		if a.begins_with("--inserter-arms-trace="):
			_trace = FileAccess.open(a.substr(22), FileAccess.WRITE)
	_cards.name = "HeldItems"
	add_child(_cards)
	_scratch_lists.clear()
	for p in Part.size():
		_scratch_lists.append([])
		var mesh: Mesh
		if p == Part.TURNTABLE or p == Part.SHOULDER:
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.5
			cyl.bottom_radius = 0.5
			cyl.height = 1.0
			cyl.radial_segments = 12
			cyl.rings = 1
			mesh = cyl
		else:
			var box := BoxMesh.new()
			box.size = Vector3.ONE
			mesh = box
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = mesh
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = Visuals.instance_material()
		add_child(mmi)
		_parts.append(mmi)


func reset() -> void:
	_cards.reset()
	_native_ingest(INGEST_RESET)
	_arms.clear()
	_unbound.clear()
	if _pn != null:
		_pn.clear()
	_slot_arms.clear()
	_slot_count = 0
	_meet_arms.clear()
	_lift_wait.clear()
	_loop_keys.clear()
	_loop_key_index.clear()
	_loop_chunks.clear()
	_loop_was = false
	_loop_moving = -1
	_missing.clear()
	_seen.clear()
	_watch.clear()
	_frame_tick = -1
	_prev_frame_tick = -1
	_clock = GameClock.new()
	_drawn = -1.0
	_preplan.clear()
	_newest_event = -1.0
	_swept = -1.0
	_events_heard = false
	_upload_bufs.clear()
	for a in _scratch_lists:
		(a as Array).clear()
	_scratch_colors.clear()
	_scratch_held.clear()
	_scratch_held_yaws.clear()
	_scratch_model_lists.clear()
	_scratch_rig_lists.clear()
	_scratch_sprite_lists.clear()
	_scratch_live.clear()
	_rest.clear()
	_rest_sprites.clear()
	_rest_now.clear()
	_rest_live.clear()
	_rest_upload.clear()
	_rest_chunk_counts.clear()
	_rest_total_instances = 0
	rest_chunk_uploads = 0
	rest_count = 0
	_rest_buffer_cache = PackedFloat32Array()
	for mmi in _rest_chunk_mmis.values():
		var node := mmi as MultiMeshInstance3D
		if node != null and is_instance_valid(node):
			node.queue_free()
	_rest_chunk_mmis.clear()
	_clear_rest_3d_mmis()
	_rest_pack_rigs.clear()
	_rest_pack_meshes.clear()
	_rest_index.clear()
	_shadow_keys.clear()
	_shadow_at = 0
	if _rest_mmi != null and _rest_mmi.multimesh != null:
		_rest_mmi.multimesh.visible_instance_count = 0
	_rest_put = true
	if world != null:
		for c in world.chunks:
			_rest_dirty[c] = true


func count() -> int:
	return _arms.size()


## (--native-inserter-pose) InserterPoseNative when it draws the pose (picked at the first arm), else null. Not
## when the pose comes from events (--inserter-events=on: events without events_items; `from_events`, the first arm
## made by an `ie` then: _pose_at draws from events whenever events_items is off). (A layer that picked it from `ih`
## and is sent `ie` anyway with events_items off keeps the pose from the samples: the mod sends no `ie` then.)
func _pose_native(from_events := false) -> RefCounted:
	if not _pn_tried:
		_pn_tried = true
		if native_pose and belt_clock and (events_items or not (events or from_events)) and NativeLibrary.ensure() \
				and ClassDB.class_exists("InserterPoseNative"):
			_pn = ClassDB.instantiate("InserterPoseNative")
			_pn_loop = _pn.has_method("frame_draw")  # (a library built before --native-inserter-loop: the loop below)
			_pn_counts = _pn.has_method("counts")
	return _pn


## (--native-inserter-swing) InserterSwingNative when it makes the plans, else null.
func _swing_native() -> RefCounted:
	if not _sw_tried:
		_sw_tried = true
		if native_swing and NativeLibrary.ensure() and ClassDB.class_exists("InserterSwingNative"):
			_sw = ClassDB.instantiate("InserterSwingNative")
	return _sw


## A new live arm (a slot in InserterPoseNative when it draws the pose).
func _new_arm(unit: int, from_events := false) -> Arm:
	var arm := Arm.new()
	arm.unit = unit
	Probing.count("arm_new")
	var pn := _pose_native(from_events)
	if pn != null:
		arm.slot = pn.add_arm()
		while _slot_arms.size() <= arm.slot:
			_slot_arms.append(null)
		_slot_arms[arm.slot] = arm
		_slot_count += 1
		_push_draw(arm)  # (its unit: frame_check looks for its record)
	_arms[unit] = arm
	_unbound[unit] = arm
	return arm


## (--native-inserter-ingest, perf A5) The `ih` hands and `ie` events of known, bound arms applied by
## InserterIngestNative straight into InserterPoseNative, _end_frame's missing count and the stale sweep's last_heard
## worked out there too; what it can't take (unknown or unbound arms, a new record, gone) comes back as plain rows for
## the GDScript above. True when it took the work. Only with the native pose, the belt clock and quick_apply.
static var native_ingest := not Switches.has("--native-inserter-ingest=off")
## --arm-bind-layout=on|off (on): an arm's bind (_bind: base, colour, model name, ModelLibrary.placed) is redone when
## the packs' version or ModelLibrary.layout_generation changes, not whenever any model finishes (ModelLibrary.generation,
## which goes up every frame a model is made while a base loads: each bump sent every arm's next hand through the full
## bind and InserterIngestNative's unbind_all). placed()/turn_dir() don't depend on a model being ready. off: as before.
static var bind_layout := not Switches.has("--arm-bind-layout=off")


## The models' stamp an arm's bind is good for (--arm-bind-layout).
static func _bind_gen() -> int:
	return ModelLibrary.layout_generation if bind_layout else ModelLibrary.generation


## --arm-model-watch=on|off (on): the arms' draw modes (_decide_mode, _push_draw, the native loop's clear_modes) and the
## resting arms (dirty_all, the per-chunk index stamp) follow a stamp of this layer's own (_model_ver) instead of
## ModelLibrary.generation, which goes up whenever any model finishes (every frame while a base loads: each bump
## re-decided every live arm's mode and rebuilt every chunk's resting arms). The names the lookups asked
## ModelLibrary.ready for and were told "not yet" (_model_ready: rigs, pack rigs, Wube's arm pieces) are kept; on a
## generation change they are asked again and the stamp goes up only when one became ready. A safety net takes the
## raw generation anyway once a generation has stayed unaccepted for WATCH_NET_MSEC (trailing: the first bump after a
## quiet spell isn't taken at once). The stamp is latched for the frame (every arm decided against the same one).
## off: ModelLibrary.generation, as before.
static var model_watch := not Switches.has("--arm-model-watch=off")
const WATCH_NET_MSEC := 2000
var _watch := {}  # model name -> true: asked by a lookup and not ready then
var _watch_gen := -1  # ModelLibrary.generation the watched names were last asked at
var _watch_acc_gen := -1  # the generation the stamp last took
var _watch_pending := false  # a generation not yet taken (since _watch_pend_msec)
var _watch_pend_msec := 0
var _ver_frame := -1  # the frame _ver_latched is for
var _ver_latched := 0
var _model_stamp := 0
var watch_bumps := 0  # (tests) the stamp's rises: a watched name became ready
var watch_nets := 0  # (tests) the safety net's


## ModelLibrary.ready(name) (a test's fake readiness overrides it).
func _ask_ready(name: String) -> bool:
	return ModelLibrary.ready(name)


## _ask_ready, the name kept while it isn't ready (--arm-model-watch).
func _model_ready(name: String) -> bool:
	var r := _ask_ready(name)
	if not r and model_watch:
		_watch[name] = true
	return r


## The models' version the arms' draw modes and resting arms are good for (--arm-model-watch): worked out once a frame
## (a model finishing mid-frame doesn't give arms decided in one frame two stamps, nor cost a clock read an arm).
func _model_ver() -> int:
	if not model_watch:
		return ModelLibrary.generation
	var fr := _frame_now()
	if fr != _ver_frame:
		_ver_frame = fr
		_ver_latched = _model_ver_now()
	return _ver_latched


## The frame the stamp is latched for (a test's simulated frames override it).
func _frame_now() -> int:
	return Engine.get_process_frames()


func _model_ver_now() -> int:
	var g: int = ModelLibrary.generation
	if g == _watch_acc_gen:
		_watch_pending = false
		return _model_stamp
	var now := Time.get_ticks_msec()
	if not _watch_pending:
		_watch_pending = true
		_watch_pend_msec = now
	if g != _watch_gen:
		_watch_gen = g
		var hit := false
		for name: String in _watch.keys():
			if _ask_ready(name):
				_watch.erase(name)
				hit = true
		if hit:
			watch_bumps += 1
			return _watch_accept(g)
	if now - _watch_pend_msec >= WATCH_NET_MSEC:
		watch_nets += 1
		return _watch_accept(g)
	return _model_stamp


func _watch_accept(g: int) -> int:
	_watch_acc_gen = g
	_watch_gen = g
	_watch_pending = false
	_model_stamp += 1
	return _model_stamp

const INGEST_HANDS := 0
const INGEST_EVENTS := 1
const INGEST_END := 2
const INGEST_HEARD := 3
const INGEST_RESET := 4
const INGEST_SWEEP := 5
## --native-inserter-ingest2=on|off (on, perf wave 4 T3): with --native-inserter-ingest, _drop_arm tells
## InserterIngestNative of each arm it drops, so its hands check only their record (not the arm too); _end_frame's
## missing count walks the native's own entries plus _unbound (the arms it has no entry for) instead of every arm's
## key and value, touching _missing only when it has to; the stale sweep asks the native for its stale entries
## (sweep) and walks _unbound only. off, or a library without end_frame2: as before.
static var native_ingest2 := not Switches.has("--native-inserter-ingest2=off")
var _ing2 := false
var _unbound := {}  # unit -> Arm: the live arms with no InserterIngestNative entry (bind_arm takes them out)
var _ing: RefCounted = null
var _ing_rest: Variant = null
var _ing_world: Object = null
var _ing_forget := Callable()
var _ing_stamp := Vector2i(-1, -1)


func _native_ingest(op: int, list: Variant = null, deltas := false, k := 0) -> bool:
	if op == INGEST_RESET:
		if _ing != null:
			_ing.clear()
		return false
	if not native_ingest or _pn == null or not belt_clock or not quick_apply or world == null:
		return false
	if _ing == null:
		if not ClassDB.class_exists("InserterIngestNative"):
			return false
		_ing = ClassDB.instantiate("InserterIngestNative")
		_ing.set_pose(_pn)
		_ing2 = native_ingest2 and _ing.has_method("end_frame2")
		if _ing2:
			_ing.set_trust(true)
		_ing_forget = Callable(_ing, "forget_chunk")
	if _ing_world != world:
		if _ing_world != null and is_instance_valid(_ing_world) and _ing_world.is_connected("entities_changed", _ing_forget):
			_ing_world.disconnect("entities_changed", _ing_forget)
		_ing_world = world
		_ing.clear()
		_unbound = _arms.duplicate()  # (no entry left)
		if world.has_signal("entities_changed"):
			world.connect("entities_changed", _ing_forget)
	match op:
		INGEST_HANDS:
			var stamp := Vector2i(_bind_gen(), ModelLibrary.ModelPacks.version)
			if stamp != _ing_stamp:
				_ing_stamp = stamp
				_ing.unbind_all()  # (every arm through _bind again)
				Probing.count("arm_unbind_all")
			var rest: PackedInt64Array = _ing.add_hands(list, deltas, k, world.entities, _arms)
			if Probing.on and not rest.is_empty():
				Probing.count("ih_back", rest.size() / 4)
			for i in range(0, rest.size(), 4):
				var unit := rest[i]
				_update(unit, Vector2(rest[i + 1], rest[i + 2]) / 256.0, rest[i + 3], k)
				var arm: Arm = _arms.get(unit)
				var rec = world.entities.get(unit)
				if arm != null and arm.slot >= 0 and arm.ends_tried and rec != null and arm.bound_rec == rec:
					_ing.bind_arm(unit, arm.slot, arm, rec, arm.base, rec.chunk, arm.ev_any, arm.last_heard)
					_unbound.erase(unit)
		INGEST_EVENTS:
			_ing_rest = _ing.add_events(list, deltas, _arms)
			for unit in _ing.take_first_events():
				var arm: Arm = _arms.get(unit)
				if arm != null:
					arm.ev_any = true
		INGEST_END:
			var drops: PackedInt64Array
			if _ing2:
				drops = _ing.end_frame2(_seen, _missing, _unbound)
			else:
				drops = _ing.end_frame(_arms, _seen, _missing)
			for unit in drops:
				_drop_arm(unit)
			_seen.clear()
		INGEST_SWEEP:
			if not _ing2:
				return false
			var threshold := float(list)
			for unit in _ing.sweep(threshold):
				_drop_arm(unit)
			for unit in _unbound.keys():
				var arm: Arm = _unbound[unit]
				if arm.last_heard >= 0.0 and arm.last_heard < threshold:
					_drop_arm(unit)
		INGEST_HEARD:
			var h: PackedFloat64Array = _ing.heard(_arms)
			for i in range(0, h.size(), 2):
				var arm: Arm = _arms.get(int(h[i]))
				if arm != null:
					arm.last_heard = maxf(arm.last_heard, h[i + 1])
	return true


## (--native-inserter-loop) Counts the arm in its chunk's entry of _loop_chunks (on) or takes it out (off, or
## counted under another chunk); a chunk with no arm left is erased, so the behind-view check walks only chunks
## that hold bound arms now.
func _loop_chunk_set(arm: Arm, on: bool) -> void:
	if arm.loop_in and (not on or arm.loop_chunk != arm.chunk):
		var left := int(_loop_chunks.get(arm.loop_chunk, 0)) - 1
		if left > 0:
			_loop_chunks[arm.loop_chunk] = left
		else:
			_loop_chunks.erase(arm.loop_chunk)
		arm.loop_in = false
	if on and not arm.loop_in:
		_loop_chunks[arm.chunk] = int(_loop_chunks.get(arm.chunk, 0)) + 1
		arm.loop_chunk = arm.chunk
		arm.loop_in = true


## An arm no longer drawn live: gone, stale or missing.
func _drop_arm(unit: int) -> void:
	if _ing2 and _ing != null:
		_ing.drop(unit)  # (also for a unit with no arm here: the native may still hold an entry for it)
	var arm: Arm = _arms.get(unit)
	if arm == null:
		return
	if arm.slot >= 0 and _pn != null:
		_pn.remove_arm(arm.slot)
		if arm.slot < _slot_arms.size():
			_slot_arms[arm.slot] = null
		_slot_count -= 1
		arm.slot = -1
	_meet_arms.erase(arm)
	_lift_wait.erase(arm)
	_unbound.erase(unit)
	_loop_chunk_set(arm, false)
	if _loop_was and _rest_live.has(unit):
		# (--native-inserter-loop) It leaves the live set now: the loop below would have found it gone next frame.
		_rest_now[_rest_live[unit]] = true
		_rest_live.erase(unit)
	_arms.erase(unit)


## The game tick the arms are drawn at (belt clock), -1 before the first update.
func drawn_tick() -> float:
	return _drawn


## One part of an update: {t: "ih", k: tick, p: ticks between updates, part, parts, l: [unit, hand x,
## hand y, item id, ...]}
func handle(msg: Dictionary) -> void:
	var k := int(msg.get("k", 0))
	var p := float(msg.get("p", 0))
	if p > 0.0:
		_period = p
	if k != _frame_tick:
		_end_frame()
		if _frame_tick >= 0 and k > _frame_tick:
			# Averaged, so one late packet doesn't change how fast every arm moves. Up to a second:
			# a slowed-down mod (`rate` 3) sends hands every 12 ticks, or 24 with a long interval.
			var length := clampf((k - _frame_tick) / 60.0, 1.0 / 60.0, 1.0)
			_frame_length = lerpf(_frame_length, length, 0.5)
		_prev_frame_tick = _frame_tick if _frame_tick >= 0 else k
		_frame_tick = k
		_frame_msec = Time.get_ticks_msec()
		_clock.heard(float(k), p)
	var list = msg.get("l")
	# (A binary frame's hands come packed, whole: wire_decode.gd, never delta-coded.)
	if not (list is Array or list is PackedInt32Array or list is PackedInt64Array):
		return
	# z = 1: every number is the difference from the hand before it (see belt_items.gd).
	var deltas := int(msg.get("z", 0)) == 1
	if _native_ingest(INGEST_HANDS, list, deltas, k):
		return
	var unit := 0
	var x := 0
	var y := 0
	var item := 0
	var i := 0
	var n: int = list.size()
	while i + 3 < n:
		if deltas:
			unit += int(list[i])
			x += int(list[i + 1])
			y += int(list[i + 2])
			item += int(list[i + 3])
		else:
			unit = int(list[i])
			x = int(list[i + 1])
			y = int(list[i + 2])
			item = int(list[i + 3])
		_update(unit, Vector2(x, y) / 256.0, item, k)
		i += 4


func _update(unit: int, hand: Vector2, item_id: int, k: int) -> void:
	var rec = world.entities.get(unit) if world != null else null
	if rec == null:
		return  # its chunk isn't loaded
	_seen[unit] = true
	var rel: Vector2 = hand - rec.pos
	var arm: Arm = _arms.get(unit)
	if arm == null:
		arm = _new_arm(unit)
		arm.angle = rel.angle()
		arm.reach = rel.length()
		arm.path_angle = arm.angle
		arm.path_reach = arm.reach
		if arm.slot >= 0 and _pn_loop:
			_pn.set_pose(arm.slot, arm.angle, arm.reach)
	_bind(arm, rec)
	if belt_clock:
		if arm.slot >= 0:
			_add_sample(arm, float(k), rel, item_id, true)  # (into the native preplan queue there)
			return
		if _add_sample(arm, float(k), rel, item_id) and arm.ticks.size() >= 2 \
				and not (arm.preplanned if quick_apply else _preplan.has(arm)):
			arm.preplanned = true
			_preplan.append(arm)
		return
	arm.item_id = item_id
	arm.item_count = 1 if item_id > 0 else 0
	arm.from_angle = arm.path_angle
	arm.from_reach = arm.path_reach
	arm.to_angle = rel.angle()
	arm.to_reach = rel.length()


## The arm's record: its base, prototype (colour, model, family), end poses and speeds. Each update
## (the record can change: rotated, upgraded), or when its record first comes (events).
func _bind(arm: Arm, rec) -> void:
	var pack := ModelLibrary.entity_pack(rec.extra)
	if quick_apply and arm.bound_rec == rec and arm.bound_dir == rec.dir and arm.bound_proto == rec.proto_id \
			and arm.base == rec.pos and arm.bound_pack == pack and arm.bound_gen == _bind_gen() \
			and arm.bound_ver == ModelLibrary.ModelPacks.version:
		if belt_clock and not arm.ends_tried:
			_learn_ends(arm, rec, protos.entity(rec.proto_id) if protos != null else null)
		return
	var proto: ProtoDB.EntityProto = protos.entity(rec.proto_id) if protos != null else null
	arm.color = proto.color if proto != null else Color.GOLDENROD
	arm.proto_name = proto.name if proto != null else ""
	arm.base = rec.pos
	arm.dir = rec.dir
	if arm.slot >= 0:
		_pn.set_base(arm.slot, arm.base)
	var model := arm.proto_name + ("@" + pack if pack != "" else "")
	if model != arm.model_name:
		arm.model_name = model
		arm.card_lift = NAN
		arm.mode = Arm.Mode.NONE
	if proto != null:
		arm.placed = ModelLibrary.placed(proto.name, proto.type, rec.dir, rec.extra, Vector3(rec.pos.x, 0.0, rec.pos.y))
	arm.bound = true
	# (A record whose prototype isn't known yet is looked at again next time.)
	arm.bound_rec = rec if proto != null else null
	arm.bound_dir = rec.dir
	arm.bound_proto = rec.proto_id
	arm.bound_pack = pack
	arm.bound_gen = _bind_gen()
	arm.bound_ver = ModelLibrary.ModelPacks.version
	arm.chunk = rec.chunk
	if arm.loop_in:
		_loop_chunk_set(arm, true)  # (it may have moved chunk)
	if arm.slot >= 0 and native_loop and _pn_loop:
		_push_draw(arm)
	if belt_clock and not arm.ends_tried:
		_learn_ends(arm, rec, proto)


## A sample (the hand `rel` to its base at tick `k`) into the arm's ring; true when it was new.
func _add_sample(arm: Arm, k: float, rel: Vector2, item_id: int, queue := false) -> bool:
	if arm.slot >= 0:
		if not _pn.add_sample(arm.slot, k, rel.angle(), rel.length(), item_id, queue):
			return false
		arm.last_heard = maxf(arm.last_heard, k)
		return true
	var n := arm.ticks.size()
	if n > 0 and k <= arm.ticks[n - 1]:
		return false
	var a := rel.angle()
	var clear := Swing.on_side(a, arm.pick, arm.drop)
	arm.add_sample(k, a, rel.length(), item_id, clear)
	if clear:
		arm.side = a
	return true


## One `ie` message: {t: "ie", k: tick, n: the ticks its events cover (each event is sent in every
## message of the next n ticks), p: ticks between messages, l: [kind, unit, tick, a, b, c, hand x,
## hand y (1/256), belt, ...] flat (docs/PROTOCOL.md): picked (a count, b item, c ticks it may be
## late by), dropped (a remaining, b item, c), status (a count, b item, c the code), sync (the
## same, a position read), gone.
func handle_events(msg: Dictionary) -> void:
	var k := float(msg.get("k", 0))
	var list = msg.get("l")
	if not (list is Array):
		return
	_events_heard = true
	if k > _newest_event:
		_newest_event = k
		_clock.heard(k, float(msg.get("p", 2)))
	var deltas := int(msg.get("z", 0)) == 1
	if _native_ingest(INGEST_EVENTS, list, deltas):
		list = _ing_rest  # (what InserterIngestNative left: plain rows)
		deltas = false
	var v := [0, 0, 0, 0, 0, 0, 0, 0, 0]
	var i := 0
	while i + 8 < list.size():
		for j in 9:
			v[j] = v[j] + int(list[i + j]) if deltas else int(list[i + j])
		i += 9
		var unit: int = v[1]
		var kind: int = v[0]
		if kind == EV_PLACED:
			continue  # (for belt_items.gd)
		if kind == Swing.Ev.GONE:
			_drop_arm(unit)
			_missing.erase(unit)
			continue
		var arm: Arm = _arms.get(unit)
		if arm == null:
			arm = _new_arm(unit, true)
		var rec = world.entities.get(unit) if world != null else null
		if rec != null and not arm.bound:
			_bind(arm, rec)
		var x: float = v[6] / 256.0
		var y: float = v[7] / 256.0
		if arm.slot >= 0:
			if not _pn.add_event(arm.slot, float(v[2]), kind, v[3], v[4], v[5], x, y, v[8]):
				continue
			arm.ev_any = true
			arm.last_heard = maxf(arm.last_heard, float(v[2]))
		elif not arm.add_event(float(v[2]), kind, v[3], v[4], v[5], x, y, v[8]):
			continue
		if kind == Swing.Ev.SYNC and arm.bound:
			# (Its position: a sample too, the fallback when the status says it doesn't move as its
			# speeds say, and the sweep's side when it was read mid-swing.)
			_add_sample(arm, float(v[2]), Vector2(x, y) - arm.base, v[4] if v[3] > 0 else 0)
		if v[5] == 0 and (kind == Swing.Ev.PICKED or kind == Swing.Ev.DROPPED) and arm.bound:
			if arm.slot >= 0:
				_pn.backdate(arm.slot, float(v[2]))
			else:
				_backdate(arm, float(v[2]))
	if _newest_event - _swept >= 60.0:
		_swept = _newest_event
		_sweep_stale()


## Arms not heard for STALE_TICKS (no hand, no event) dropped: once a second of events.
func _sweep_stale() -> void:
	if _native_ingest(INGEST_SWEEP, _newest_event - STALE_TICKS):
		return
	_native_ingest(INGEST_HEARD)
	for unit in _arms.keys():
		var arm: Arm = _arms[unit]
		if arm.last_heard >= 0.0 and arm.last_heard < _newest_event - STALE_TICKS:
			_drop_arm(unit)


## An exact take or drop at tick `k` dates the uncertain one before it (a hand woken from a long
## wait: the mod says how many ticks before its check it may have happened): the leg between them
## takes what the speeds say, so the earlier one was that long before, within what the mod allowed.
func _backdate(arm: Arm, k: float) -> void:
	var i := arm.ev_ticks.bsearch(k, true)
	while i < arm.ev_ticks.size() and arm.ev_ticks[i] == k and arm.ev_kind[i] != Swing.Ev.PICKED and arm.ev_kind[i] != Swing.Ev.DROPPED:
		i += 1
	if i >= arm.ev_ticks.size() or arm.ev_ticks[i] != k:
		return
	var j := i - 1
	while j >= 0 and arm.ev_kind[j] != Swing.Ev.PICKED and arm.ev_kind[j] != Swing.Ev.DROPPED:
		j -= 1
	if j < 0 or arm.ev_c[j] <= 0 or is_nan(arm.ev_x[j]) or is_nan(arm.ev_x[i]):
		return
	var from := Vector2(arm.ev_x[j], arm.ev_y[j]) - arm.base
	var to := Vector2(arm.ev_x[i], arm.ev_y[i]) - arm.base
	var t := Swing.travel_ticks(Swing.delta(from.angle(), to.angle(), arm.side), to.length() - from.length(), arm.omega, arm.v)
	var kj := arm.ev_ticks[j]
	var moved := clampf(k - t, kj - arm.ev_c[j], kj)
	arm.ev_c[j] = 0
	if moved < kj and (j == 0 or arm.ev_ticks[j - 1] < moved):
		arm.ev_ticks[j] = moved
		arm.eplan_i = -1


## The inserter's end poses, speeds and whether it takes from a belt, from its prototype's eprops
## (ip/id turned by its direction: the vectors are for one facing north; rs/es at normal quality)
## and the world round it. Tried again each update until the eprops have come.
func _learn_ends(arm: Arm, rec, proto: ProtoDB.EntityProto) -> void:
	var x: Dictionary = (eprops.get(rec.proto_id, {}) as Dictionary).get("x", {})
	if proto == null or not x.has("ip") or not x.has("id"):
		return
	arm.ends_tried = true
	var pick_rel := _turn(_vec(x["ip"]), rec.dir)
	var drop_rel := _turn(_vec(x["id"]), rec.dir)
	arm.pick = [pick_rel.angle(), pick_rel.length()]
	arm.drop = [drop_rel.angle(), drop_rel.length()]
	var speeds := Swing.speeds(x, proto.name, str(rec.extra.get("q", "normal")))
	arm.omega = speeds[0]
	arm.v = speeds[1]
	arm.belt_pick = _belt_at(rec.pos + pick_rel)
	if arm.slot >= 0:
		_pn.set_ends(arm.slot, arm.pick[0], arm.pick[1], arm.drop[0], arm.drop[1], arm.omega, arm.v, arm.belt_pick)


static func _vec(v) -> Vector2:
	return Vector2(float(v[0]), float(v[1])) if v is Array and v.size() >= 2 else Vector2.ZERO


## A north-facing vector turned to a 16-way direction (as cursor_overlay.gd turn).
static func _turn(v: Vector2, dir: int) -> Vector2:
	return v.rotated(-Wire.direction_yaw(dir))


## Whether a belt (transport belt, underground, splitter, loader) stands at this position.
func _belt_at(pos: Vector2) -> bool:
	if world == null or protos == null:
		return false
	var c := Vector2i(floori(pos.x / 32.0), floori(pos.y / 32.0))  # (world.gd chunk_of)
	var cv = world.chunks.get(c)
	if cv == null:
		return false
	if rest_index:
		# (--rest-arms-index) Only the cells within a tile of the point: a belt nearer than 1 tile stands in one.
		var belts_at: Dictionary = _index_for(c, cv).belts
		if belts_at.is_empty():
			return false
		var cx := floori(pos.x)
		var cy := floori(pos.y)
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var pts: Variant = belts_at.get(Vector2i(cx + dx, cy + dy))
				if pts == null:
					continue
				var p := pts as PackedFloat32Array
				for i in range(0, p.size(), 3):
					if Vector2(p[i], p[i + 1]).distance_to(pos) < p[i + 2]:
						return true
		return false
	for r in cv.entities.values():
		# (quick_apply) Only what stands within a tile is looked up: a busy chunk's thousands of records each
		# looked up and their type searched for took 0.3 ms an inserter, most of a hand update's time.
		if quick_apply and r.pos.distance_squared_to(pos) >= 1.0:
			continue
		var p: ProtoDB.EntityProto = protos.entity(r.proto_id)
		if p == null or not BELT_TYPES.has(p.type):
			continue
		if r.pos.distance_to(pos) < (1.0 if p.type == "splitter" or p.type == "lane-splitter" else 0.6):
			return true
	return false


func _end_frame() -> void:
	if _frame_tick < 0:
		return
	if _native_ingest(INGEST_END):
		return
	for unit in _arms.keys():
		if _seen.has(unit) or (_arms[unit] as Arm).ev_any or (_arms[unit] as Arm).ev_ticks.size() > 0:
			_missing.erase(unit)  # (an arm with events goes when the events say: gone, or stale)
		else:
			var n: int = _missing.get(unit, 0) + 1
			if n >= MISSING_FRAMES:
				_drop_arm(unit)
				_missing.erase(unit)
			else:
				_missing[unit] = n
	_seen.clear()


## (belt clock) The arm's pose at game tick `t`: from its events when it has them for that tick (and
## its status then says it moves as its speeds say), else between the two samples round it as the
## swing model says, held before its first sample, played on past its newest.
func _pose_at(arm: Arm, t: float) -> void:
	if arm.slot >= 0:
		# (--native-inserter-pose) This one arm's pose from InserterPoseNative (the frame's loop reads pose_all's).
		var p: PackedFloat64Array = _pn.pose_one(arm.slot, t, events_items, Swing.reach_slack)
		if p[0] == 1.0:
			arm.angle = p[1]
			arm.reach = p[2]
			arm.item_id = int(p[3])
			arm.item_count = int(p[4]) if p.size() > 4 else (1 if arm.item_id > 0 else 0)
		elif p[0] == 2.0:
			arm.item_id = int(p[3])
			arm.item_count = int(p[4]) if p.size() > 4 else (1 if arm.item_id > 0 else 0)
		return
	if not events_items and _pose_events(arm, t):
		return
	var n := arm.ticks.size()
	if n == 0:
		return
	if t < arm.plan_still_until and t >= arm.plan_ka:
		if events_items:
			_item_from_events(arm, t)
		return  # standing: the pose set when the plan was made holds
	var pose: Array
	if t <= arm.ticks[0]:
		pose = [arm.angles[0], arm.reaches[0], arm.items[0]]
	else:
		var i := arm.ticks.bsearch(t, true)  # the first sample at or after t
		var a := i if i < n and arm.ticks[i] == t else i - 1
		if a >= n - 1:
			var still := n >= 2 and Swing.hand_pos(arm.angles[n - 2], arm.reaches[n - 2]).distance_to(
				Swing.hand_pos(arm.angles[n - 1], arm.reaches[n - 1])) < Swing.STILL
			pose = Swing.extrapolate(arm.angles[n - 1], arm.reaches[n - 1], arm.items[n - 1], still, arm.pick, arm.drop,
				arm.omega, arm.v, arm.side, t - arm.ticks[n - 1])
		else:
			if arm.plan_ka != arm.ticks[a] or arm.plan.is_empty():
				arm.plan = arm.plans.get(arm.ticks[a], []) as Array
				if arm.plan.is_empty():
					arm.plan = _plan_pair(arm, a)
				arm.plan_ka = arm.ticks[a]
				var k0: Array = arm.plan[0]
				var kn: Array = arm.plan[arm.plan.size() - 1]
				arm.plan_still_until = kn[0] if arm.plan.size() == 2 and k0[1] == kn[1] and k0[2] == kn[2] and k0[3] == kn[3] else -1.0
			pose = Swing.at(arm.plan, t)
	arm.angle = wrapf(pose[0], -PI, PI)
	arm.reach = pose[1]
	arm.item_id = pose[2]
	if events_items:
		if not _item_from_events(arm, t):
			arm.item_count = _count_for_sample(arm, t, arm.item_id)
	else:
		arm.item_count = 1 if arm.item_id > 0 else 0


## (--inserter-events=items) The held item at `t` from the events: what the last event at or before
## `t` says the hand holds, unless the next pick or drop is an uncertain one (the mod saw it `c` ticks
## after its check) that may already have happened by `t`: then the samples' own guess stands.
func _item_from_events(arm: Arm, t: float) -> bool:
	var n := arm.ev_ticks.size()
	if n == 0 or t < arm.ev_ticks[0]:
		return false
	var i := arm.ev_ticks.bsearch(t, false) - 1
	if arm.ev_kind[i] == Swing.Ev.GONE:
		return false
	var j := i + 1
	while j < n and arm.ev_kind[j] != Swing.Ev.PICKED and arm.ev_kind[j] != Swing.Ev.DROPPED:
		j += 1
	if j < n and arm.ev_c[j] > 0 and t >= arm.ev_ticks[j] - arm.ev_c[j]:
		return false
	arm.item_id = arm.ev_item[i] if arm.ev_count[i] > 0 else 0
	arm.item_count = arm.ev_count[i] if arm.item_id > 0 else 0
	return true


## Fallback held count when _item_from_events deferred to the sample guess (e.g. inside an uncertain window).
func _count_for_sample(arm: Arm, t: float, sample_item: int) -> int:
	if sample_item <= 0:
		return 0
	var n := arm.ev_ticks.size()
	if n == 0 or t < arm.ev_ticks[0]:
		return 1
	var i := arm.ev_ticks.bsearch(t, false) - 1
	if arm.ev_kind[i] == Swing.Ev.GONE:
		return 1
	if arm.ev_count[i] > 0 and arm.ev_item[i] == sample_item:
		return arm.ev_count[i]
	var j := i + 1
	while j < n and arm.ev_kind[j] != Swing.Ev.PICKED and arm.ev_kind[j] != Swing.Ev.DROPPED:
		j += 1
	if j < n and arm.ev_c[j] > 0 and t >= arm.ev_ticks[j] - arm.ev_c[j] and arm.ev_count[j] > 0 and arm.ev_item[j] == sample_item:
		return arm.ev_count[j]
	return 1


## The plan between samples `a` and `a + 1` (made when the drawn tick reaches them, or ahead by
## preplan: the inputs are all there once both samples are).
func _plan_pair(arm: Arm, a: int) -> Array:
	var side := _side_at(arm, a)
	var plan: Array
	var sw := _swing_native()
	if sw != null:
		# (--native-inserter-swing) The same plan from InserterSwingNative, 4 numbers a keyframe.
		var flat: PackedFloat64Array = sw.plan(PackedFloat64Array([arm.ticks[a], arm.angles[a], arm.reaches[a], arm.items[a],
			arm.ticks[a + 1], arm.angles[a + 1], arm.reaches[a + 1], arm.items[a + 1]]), PackedFloat64Array(arm.pick),
			PackedFloat64Array(arm.drop), arm.omega, arm.v, side, arm.belt_pick, arm.last_item, Swing.reach_slack)
		for i in range(0, flat.size(), 4):
			plan.append([flat[i], flat[i + 1], flat[i + 2], int(flat[i + 3])])
	else:
		plan = Swing.plan(arm.ticks[a], arm.angles[a], arm.reaches[a], arm.items[a],
			arm.ticks[a + 1], arm.angles[a + 1], arm.reaches[a + 1], arm.items[a + 1],
			arm.pick, arm.drop, arm.omega, arm.v, side, arm.belt_pick, arm.last_item)
	if is_nan(side) and is_nan(arm.side) and plan.size() >= 2:
		# Which side the arm sweeps over isn't known until a sample lands on it: the first
		# half-circle turn's own choice stands until then, so the legs agree.
		var first: Array = plan[0]
		var last: Array = plan[plan.size() - 1]
		if absf(last[1] - first[1]) > Swing.AMBIGUOUS:
			arm.side = wrapf((first[1] + last[1]) * 0.5, -PI, PI)
	return plan


## (events) The pose at `t` from the arm's events: true when they say. False before its first event,
## or when its status as of the last event says it doesn't move as its speeds say (low power, no
## power, frozen, disabled): then the samples (every SYNC is one) draw it.
func _pose_events(arm: Arm, t: float) -> bool:
	var n := arm.ev_ticks.size()
	if n == 0 or t < arm.ev_ticks[0] or not arm.bound:
		return false
	var i := arm.ev_ticks.bsearch(t, false) - 1  # the last event at or before t
	if Swing.SLOW.has(arm.ev_code[i]):
		return false
	# The plan runs between anchors: picks and drops, status changes, positions read at an end (a
	# sync mid-way only says which side the hand sweeps over: the game's position then is the item
	# as drawn, lifted, not where the arm is).
	while i > 0 and not _anchor(arm, i):
		i -= 1
	if arm.eplan_i == i and not arm.eplan.is_empty() and not (arm.eplan_open and i < n - 1):
		if t < arm.eplan_still_until:
			arm.item_count = arm.ev_count[i] if arm.item_id > 0 else 0
			return true  # standing
	else:
		var j := i + 1
		while j < n and not _anchor(arm, j):
			j += 1
		var e0 := _event_pose(arm, i)
		var e1: Array = _event_pose(arm, j) if j < n else []
		arm.eplan = Swing.plan_events(e0, e1, arm.pick, arm.drop, arm.omega, arm.v, _event_side(arm, i))
		arm.eplan_i = i
		arm.eplan_open = e1.is_empty()
		var k0: Array = arm.eplan[0]
		var kn: Array = arm.eplan[arm.eplan.size() - 1]
		arm.eplan_still_until = kn[0] if arm.eplan.size() == 2 and k0[1] == kn[1] and k0[2] == kn[2] and k0[3] == kn[3] else -1.0
	var pose := Swing.at(arm.eplan, t)
	arm.angle = wrapf(pose[0], -PI, PI)
	arm.reach = pose[1]
	arm.item_id = pose[2]
	arm.item_count = arm.ev_count[i] if arm.item_id > 0 else 0
	return true


## (events) The side the hand sweeps over in the cycle event `i` belongs to (an angle on it; NAN
## unknown). A cycle runs from a pick with the hand empty before it to the next; out and back go
## over the same side. A cycle's side comes from a position the mod read mid-swing in it (a sync
## marked as a probe, before or after `i`: at an end the game's position is the lifted item, so only
## those count), else from the cycle before or after: a hand taking from a belt sweeps the same side
## again (107 of 110 cycles in the owner's save), one taking from a chest or machine (a half circle
## either way) the other side (184 of 187), so the neighbour's side mirrored about the axis; with
## none known, what the samples taught (Arm.side).
func _event_side(arm: Arm, i: int) -> float:
	var n := arm.ev_ticks.size()
	var cycle_of := PackedInt32Array()
	var anchors := PackedFloat32Array()  # per cycle: a probe's angle, NAN
	var pre := NAN  # a probe before the first pick
	var last_count := 0
	var c := -1
	for j in n:
		var kind := arm.ev_kind[j]
		if kind == Swing.Ev.PICKED and last_count == 0:
			c += 1
			anchors.append(NAN)
		cycle_of.append(c)
		if kind == Swing.Ev.SYNC and arm.ev_belt[j] == 1 and not is_nan(arm.ev_x[j]) and (c < 0 and is_nan(pre) or c >= 0 and is_nan(anchors[c])):
			var a := (Vector2(arm.ev_x[j], arm.ev_y[j]) - arm.base).angle()
			if Swing.on_side(a, arm.pick, arm.drop):
				if c < 0:
					pre = a
				else:
					anchors[c] = a
		if kind != Swing.Ev.GONE:
			last_count = arm.ev_count[j]
	var m := anchors.size()
	if m == 0:
		return pre if not is_nan(pre) else arm.side
	var sides := PackedFloat32Array()
	sides.resize(m)
	var prev := pre
	for k in m:
		var sd := anchors[k]
		if is_nan(sd) and not is_nan(prev):
			sd = _next_side(arm, prev)
		sides[k] = sd
		prev = sd
	var nxt := NAN
	for k in range(m - 1, -1, -1):
		if is_nan(sides[k]) and not is_nan(nxt):
			sides[k] = _next_side(arm, nxt)  # (the mirror is its own inverse)
		nxt = sides[k]
	var ci := cycle_of[i]
	var out: float
	if ci < 0:
		out = pre if not is_nan(pre) else (_next_side(arm, sides[0]) if not is_nan(sides[0]) else NAN)
	else:
		out = sides[ci]
	return out if not is_nan(out) else arm.side


## The side the cycle after (or before) one over side `s` sweeps: the same for a hand taking from a
## belt, the other side (mirrored about the axis) for one taking from a chest or machine.
func _next_side(arm: Arm, s: float) -> float:
	if arm.belt_pick or arm.pick.is_empty():
		return s
	return wrapf(2.0 * arm.pick[0] - s, -PI, PI)


## Whether event `j` is one the plan runs between: a pick or a drop, the first event, one whose
## count differs from the event before's (a change the checks missed), or a position (a sync, a
## status) read at an end. Not one read mid-way (the sweep's side only).
func _anchor(arm: Arm, j: int) -> bool:
	var kind := arm.ev_kind[j]
	if kind == Swing.Ev.PICKED or kind == Swing.Ev.DROPPED:
		return true
	if kind == Swing.Ev.GONE:
		return false
	if j == 0 or arm.ev_count[j] != arm.ev_count[j - 1]:
		return true
	if kind == Swing.Ev.SYNC and arm.ev_belt[j] == 2:
		return true  # (on its way, later than its pick or drop said: the leg starts from here)
	if is_nan(arm.ev_x[j]):
		return false
	# (A status change or a position mid-way is no anchor: the game's position there is the lifted
	# item, and a hand that waits does so at an end.)
	var rel := Vector2(arm.ev_x[j], arm.ev_y[j]) - arm.base
	return Swing.near(rel.angle(), rel.length(), arm.pick, PICK_ZONE) or Swing.near(rel.angle(), rel.length(), arm.drop, DROP_ZONE)


## A pick's position further than this (tiles) from the nominal pickup point, or a drop's further
## than DROP_ZONE from the drop point, is the item as the game draws it, lifted (a fast inserter's
## hand is drawn raised as it arrives): the nominal point stands in. A belt item is taken anywhere
## in its tile, within PICK_ZONE.
const PICK_ZONE := 0.7
const DROP_ZONE := 0.5


## Event `i` as plan_events takes it: [tick, kind, count, item, angle, reach, status code] about the
## base, a pick's or drop's position far from its end replaced by the end (see PICK_ZONE).
func _event_pose(arm: Arm, i: int) -> Array:
	var a := NAN
	var r := 0.0
	if not is_nan(arm.ev_x[i]):
		var rel := Vector2(arm.ev_x[i], arm.ev_y[i]) - arm.base
		a = rel.angle()
		r = rel.length()
		var kind := arm.ev_kind[i]
		if kind == Swing.Ev.PICKED and not arm.pick.is_empty() and not Swing.near(a, r, arm.pick, PICK_ZONE):
			a = arm.pick[0]
			r = arm.pick[1]
		elif kind == Swing.Ev.DROPPED and not arm.drop.is_empty() and not Swing.near(a, r, arm.drop, DROP_ZONE):
			a = arm.drop[0]
			r = arm.drop[1]
	return [arm.ev_ticks[i], arm.ev_kind[i], arm.ev_count[i], arm.ev_item[i], a, r, arm.ev_code[i]]


## Plans made ahead: a few arms a frame of those whose newest pair of samples isn't planned yet.
func _preplan_some() -> void:
	var n := mini(_preplan.size(), maxi(PREPLAN_MIN, _preplan.size() / 4))
	for _i in n:
		var arm: Arm = _preplan.pop_front()
		arm.preplanned = false
		var m := arm.ticks.size()
		if m < 2 or not arm.ends_tried:
			continue
		var ka := arm.ticks[m - 2]
		if not arm.plans.has(ka):
			arm.plans[ka] = _plan_pair(arm, m - 2)


## The side the arm sweeps over for the plan from sample `a`: the game's hand swings out to the drop
## and back to the pickup over the same side within a cycle, and the next cycle's side is the same or
## the other (seen in the owner's save: both, by inserter), so the nearest sample at or before `a`
## that was holding something clear of the ends says (Arm.side_out); failing one, any sample clear
## of the ends, else what the arm learnt (NAN until a half-circle turn chose).
func _side_at(arm: Arm, a: int) -> float:
	if not is_nan(arm.side_out[a]):
		return arm.side_out[a]
	return arm.side_any[a] if not is_nan(arm.side_any[a]) else arm.side


func _process(delta: float) -> void:
	var usec := Time.get_ticks_usec()
	var t := clampf((Time.get_ticks_msec() - _frame_msec) / (_frame_length * 1000.0), 0.0, 1.0)
	var follow := 1.0 - exp(-delta * FOLLOW_RATE)
	var own := _clock.advance(delta)
	if belt_clock:
		# The belts' drawn tick, when belts are drawn; else the arms' own clock, two updates behind.
		var belt_tick: float = belts.drawn_tick() if belts != null and belts.has_method("drawn_tick") else -1.0
		_drawn = belt_tick if belt_tick >= 0.0 else own
		if _pn != null:
			_pn.preplan_some(Swing.reach_slack)
		elif not _preplan.is_empty():
			_preplan_some()
		if handoff and belts != null and belts.has_method("take_hands"):
			_take_meets(belts.take_hands())
	while _scratch_lists.size() < Part.size():
		_scratch_lists.append([])
	for p in Part.size():
		(_scratch_lists[p] as Array).clear()
	_scratch_colors.clear()
	_scratch_held.clear()
	_scratch_held_yaws.clear()
	_scratch_live.clear()
	for arrs in _scratch_model_lists.values():
		for a in (arrs as Array):
			(a as Array).clear()
	for arrs in _scratch_rig_lists.values():
		for a in (arrs as Array):
			(a as Array).clear()
	for arrs in _scratch_sprite_lists.values():
		for a in (arrs as Array):
			(a as Array).clear()
	var lists: Array = _scratch_lists
	var colors: Array[Color] = _scratch_colors
	var held: Dictionary = _scratch_held
	var held_yaws: Dictionary = _scratch_held_yaws
	var model_lists: Dictionary = _scratch_model_lists
	var rig_lists: Dictionary = _scratch_rig_lists
	var sprite_lists: Dictionary = _scratch_sprite_lists
	var live: Dictionary = _scratch_live
	if not _native_tried:
		_native_tried = true
		if native_inserters and NativeLibrary.ensure() and ClassDB.class_exists("InserterArmsNative"):
			_native = ClassDB.instantiate("InserterArmsNative")
	if _native != null:
		for m in 4:
			for b: NBatch in (_nb[m] as Dictionary).values():
				b.inp.clear()
				b.slots.clear()
				b.arms.clear()
		_ord_arms.clear()
		_ord_units.clear()
	# (L4) The game tick the hands are drawn at, for how long one has stood still; the world's animator lights
	# a modeller's burner while its hand moves.
	var now: float = _drawn if belt_clock and _drawn >= 0.0 else Time.get_ticks_msec() * 0.06
	var animator = world.get("animator") if world != null else null
	var bc: Variant = world.get("behind_cull") if world != null else null
	var check_behind: bool = ViewPriority.tight_cull and bc != null and is_instance_valid(bc) and bc.is_active()
	# (--native-inserter-pose) Every arm's pose at the drawn tick in one call; the loop reads its own.
	var pose_flags := PackedByteArray()
	var pose_angles := PackedFloat64Array()
	var pose_reaches := PackedFloat64Array()
	var pose_items := PackedInt32Array()
	var pose_counts := PackedInt32Array()
	# (--stutter-probe) The frame's parts: ia_pre (preplans, meets), ia_pose (pose_all), ia_loop (the per-arm loop),
	# ia_batches (the native geometry and held items' places), ia_cards, ia_rest, ia_stop.
	var tp := 0
	if Probing.on:
		Probing.add("ia_pre", usec)
		tp = Time.get_ticks_usec()
	# (--native-inserter-loop) This frame's loop natively, when every arm has a slot (see native_loop); its state handed
	# over when the frame before ran the other loop.
	var loop_native := native_loop and _pn_loop and _pn != null and _native != null and belt_clock and world != null and _drawn >= 0.0 \
			and _slot_count == _arms.size() and not keep_sprite_xf and _trace == null
	if loop_native and not _loop_was:
		for unit in _arms:
			var arm: Arm = _arms[unit]
			_push_draw(arm)
			_pn.set_state(arm.slot, PackedFloat64Array([arm.angle, arm.reach, arm.item_id, arm.close, arm.seen_angle,
				arm.seen_reach, arm.moved_at, arm.held_was, arm.grabs, 1.0 if _rest_live.has(unit) else 0.0,
				arm.item_count]))
			if not arm.meets.is_empty():
				_meet_arms[arm] = true
		_loop_pack_ver = -1
		_loop_moving = -1
	elif not loop_native and _loop_was:
		sync_arms()
	_loop_was = loop_native
	if _pn != null and belt_clock and _drawn >= 0.0 and not _arms.is_empty():
		_pn.pose_all(_drawn, events_items, Swing.reach_slack)
		pose_flags = _pn.flags()
		pose_angles = _pn.angles()
		pose_reaches = _pn.reaches()
		pose_items = _pn.items()
		if _pn_counts:
			pose_counts = _pn.counts()
	if Probing.on:
		Probing.add("ia_pose", tp)
		tp = Time.get_ticks_usec()
	if loop_native:
		_process_native_loop(delta, now, animator, bc, check_behind, held, held_yaws)
		return
	for unit in _arms:
		if world != null and not world.entities.has(unit):
			continue  # mined since the last update, or its chunk not here yet (events)
		if check_behind and world != null:
			var rec_chk = world.entities[unit]
			if bc.hidden(rec_chk.chunk):
				live[unit] = rec_chk.chunk
				continue
		var arm: Arm = _arms[unit]
		if not arm.bound:
			if world == null:
				continue
			_bind(arm, world.entities[unit])
		if belt_clock:
			if _drawn >= 0.0:
				if arm.slot >= 0:
					var pf: int = pose_flags[arm.slot] if arm.slot < pose_flags.size() else 0
					if pf == 1:
						arm.angle = pose_angles[arm.slot]
						arm.reach = pose_reaches[arm.slot]
						arm.item_id = pose_items[arm.slot]
						arm.item_count = pose_counts[arm.slot] if _pn_counts and arm.slot < pose_counts.size() else (1 if arm.item_id > 0 else 0)
					elif pf == 2:
						arm.item_id = pose_items[arm.slot]
						arm.item_count = pose_counts[arm.slot] if _pn_counts and arm.slot < pose_counts.size() else (1 if arm.item_id > 0 else 0)
				else:
					_pose_at(arm, _drawn)
				if not arm.meets.is_empty():
					_steer(arm, _drawn)
		else:
			arm.path_angle = lerp_angle(arm.from_angle, arm.to_angle, t)
			arm.path_reach = lerpf(arm.from_reach, arm.to_reach, t)
			arm.angle = lerp_angle(arm.angle, arm.path_angle, follow)
			arm.reach = lerpf(arm.reach, arm.path_reach, follow)
		var wrist: Vector3
		_gripped = false
		if not _decide_mode(arm):
			continue  # its model (or its pieces) still being read: neither base nor arm is drawn yet
		if _native != null:
			# (--native-inserters) Batched by mode and key; run once after the loop.
			var slot := -1
			if arm.item_id > 0:
				slot = _ord_arms.size()
				_ord_arms.append(arm)
				_ord_units.append(unit)
			match arm.mode:
				Arm.Mode.SPRITE:
					if is_nan(arm.card_lift):
						arm.card_lift = _platform_lift(arm.proto_name, arm.dir)
					_nb_add(0, arm.model_name, arm, slot)
				Arm.Mode.RIG:
					arm.close = ease_close(arm.close, arm.item_id > 0, delta)
					_nb_add(1, arm.proto_name, arm, slot)
				Arm.Mode.MODEL:
					_nb_add(2, arm.proto_name, arm, slot)
				Arm.Mode.BASIC:
					_nb_add(3, "basic", arm, slot)
		else:
			match arm.mode:
				Arm.Mode.SPRITE:
					if not sprite_lists.has(arm.model_name):
						sprite_lists[arm.model_name] = [[], [], []]
					wrist = _draw_sprite_arm(arm, arm.mode_cards, sprite_lists[arm.model_name])
				Arm.Mode.RIG:
					if not rig_lists.has(arm.proto_name):
						rig_lists[arm.proto_name] = [[], [], [], [], []]
					arm.close = ease_close(arm.close, arm.item_id > 0, delta)
					wrist = _draw_rig_arm(arm, arm.mode_rig, rig_lists[arm.proto_name])
				Arm.Mode.MODEL:
					if not model_lists.has(arm.proto_name):
						model_lists[arm.proto_name] = [[], [], []]
					wrist = _draw_model_arm(arm, model_lists[arm.proto_name])
				Arm.Mode.BASIC:
					wrist = _draw_arm(arm, lists)
					colors.append(arm.color)
		if world != null:
			live[unit] = world.entities[unit].chunk
			if animator != null:
				animator.arm_moving(world.entities[unit], _moving(arm, now))
		if arm.item_id != arm.held_was:
			arm.held_was = arm.item_id
			if arm.item_id > 0:
				arm.grabs += 1
				arm.held_key = 0
		if _native == null and arm.item_id > 0:
			_hold(arm, unit, wrist, held, held_yaws)
	if _native != null:
		if Probing.on:
			Probing.add("ia_loop", tp)
			tp = Time.get_ticks_usec()
		_run_native(held, held_yaws)
		if Probing.on:
			Probing.add("ia_batches", tp)
			tp = Time.get_ticks_usec()
		_cards.draw(held, held_yaws)
		if Probing.on:
			Probing.add("ia_cards", tp)
			tp = Time.get_ticks_usec()
		_update_rest(live, delta)
		if Probing.on:
			Probing.add("ia_rest", tp)
			tp = Time.get_ticks_usec()
		if animator != null and not animator.arm_working.is_empty():
			_stop_unseen(animator, live)
		if Probing.on:
			Probing.add("ia_stop", tp)
		_frames += 1
		if _trace != null and not _arms.is_empty():
			_write_trace(Time.get_ticks_usec() - usec, t)
		return
	for p in _parts.size():
		var mm: MultiMesh = _parts[p].multimesh
		var per_arm := 2 if p == Part.FINGERS else 1
		_fill_xforms_colored(mm, lists[p], colors, per_arm, p)
	for proto_name in _model_parts:
		var pieces = _model_parts[proto_name]
		if pieces == null:
			continue
		var per_piece: Array = model_lists.get(proto_name, [[], [], []])
		for p in ArmPiece.size():
			_fill_xforms((pieces[p] as MultiMeshInstance3D).multimesh, per_piece[p])
	for proto_name in _rigs:
		var rig_entry: Variant = _rigs[proto_name]
		if not (rig_entry is Dictionary):
			continue
		var mmis: Array = (rig_entry as Dictionary).get("mmis", [])
		var per_part: Array = rig_lists.get(proto_name, [[], [], [], [], []])
		for p in mmis.size():
			if mmis[p] == null:
				continue
			_fill_xforms((mmis[p] as MultiMeshInstance3D).multimesh, per_part[p])
	for model in _sprite_mmis:
		var mmis: Array = _sprite_mmis[model]
		var per_piece: Array = sprite_lists.get(model, [[], [], []])
		for p in mmis.size():
			_fill_xforms((mmis[p] as MultiMeshInstance3D).multimesh, per_piece[p])
	_cards.draw(held, held_yaws)
	_update_rest(live, delta)
	if animator != null and not animator.arm_working.is_empty():
		_stop_unseen(animator, live)
	_frames += 1
	if _trace != null and not _arms.is_empty():
		_write_trace(Time.get_ticks_usec() - usec, t)


## How the arm is drawn (Arm.Mode: its sprite cards, its model's rig, Wube's pieces or the boxes), decided again when the
## packs or models changed; false while its model (or its pieces) is still being read.
func _decide_mode(arm: Arm) -> bool:
	var pack_ver := ModelLibrary.ModelPacks.version
	var model_ver := _model_ver()
	if arm.mode == Arm.Mode.NONE or arm.mode_pack_ver != pack_ver or arm.mode_model_ver != model_ver:
		var cards := _sprite_set_for(arm.model_name)
		var rig = {} if not cards.is_empty() else _rig_for(arm.proto_name)
		if rig == null:
			return false
		if not cards.is_empty():
			arm.mode = Arm.Mode.SPRITE
			arm.mode_cards = cards
			arm.mode_rig = {}
		elif not (rig as Dictionary).is_empty():
			arm.mode = Arm.Mode.RIG
			arm.mode_cards = {}
			arm.mode_rig = rig as Dictionary
		elif _pieces_for(arm.proto_name) != null:
			arm.mode = Arm.Mode.MODEL
			arm.mode_cards = {}
			arm.mode_rig = {}
		else:
			if not _model_parts.has(arm.proto_name):
				return false
			arm.mode = Arm.Mode.BASIC
			arm.mode_cards = {}
			arm.mode_rig = {}
		arm.mode_pack_ver = pack_ver
		arm.mode_model_ver = model_ver
	return true


## (--native-inserter-loop) The arm's record and drawing into its native slot: its batch (mode and key, -1 while its
## mode isn't decided for these packs and models), its base model's transform, colour and card lift.
func _push_draw(arm: Arm) -> void:
	if arm.slot < 0 or _pn == null or not _pn_loop:
		return
	var m := -1
	var k := -1
	if arm.mode != Arm.Mode.NONE and arm.mode_pack_ver == ModelLibrary.ModelPacks.version \
			and arm.mode_model_ver == _model_ver():
		var key := ""
		match arm.mode:
			Arm.Mode.SPRITE:
				m = 0
				key = arm.model_name
				if is_nan(arm.card_lift):
					arm.card_lift = _platform_lift(arm.proto_name, arm.dir)
				if is_nan(arm.card_lift):
					_lift_wait[arm] = true
			Arm.Mode.RIG:
				m = 1
				key = arm.proto_name
			Arm.Mode.MODEL:
				m = 2
				key = arm.proto_name
			_:
				m = 3
				key = "basic"
		var ik := "%d:%s" % [m, key]
		var e := [m, key, arm.proto_name, arm.mode_cards, arm.mode_rig]
		if _loop_key_index.has(ik):
			k = int(_loop_key_index[ik])
			_loop_keys[k] = e
		else:
			k = _loop_keys.size()
			_loop_key_index[ik] = k
			_loop_keys.append(e)
	var p := arm.placed
	_loop_chunk_set(arm, arm.bound)
	_pn.set_draw(arm.slot, arm.unit, arm.chunk, arm.bound, m, k, PackedFloat32Array([p.basis.x.x, p.basis.x.y, p.basis.x.z,
		p.basis.y.x, p.basis.y.y, p.basis.y.z, p.basis.z.x, p.basis.z.y, p.basis.z.z, p.origin.x, p.origin.y, p.origin.z]),
		arm.color, arm.card_lift)


## (--native-inserters) One batch's constants for InserterArmsNative (mode 0 sprite, 1 rig, 2 model, 3 basic), from an
## arm of that batch's prototype, cards and rig.
func _batch_params(m: int, proto_name: String, cards: Dictionary, rig: Dictionary, gh: float) -> PackedFloat32Array:
	match m:
		0:
			var lengths: Array = ARM_LENGTHS[ARM_FAMILIES.get(proto_name, "basic")]
			var w: Array = cards["widths"]
			return PackedFloat32Array([gh, MODEL_SHOULDER, lengths[0], lengths[1], lengths[2], CLAW_DEFAULT,
				SpriteStandins.FACTORIO_PITCH, HAND_TIP, SPRITE_DEPTH, SPRITE_HAND_DEPTH, w[0], w[1], w[2], ITEM_DROP])
		1:
			return _rig_params(rig, gh)
		2:
			var lengths: Array = ARM_LENGTHS[ARM_FAMILIES.get(proto_name, "basic")]
			var stretch: float = lengths[2]
			return PackedFloat32Array([MODEL_SHOULDER, HAND_HEIGHT, float(lengths[0]) * stretch, float(lengths[1]) * stretch,
				lengths[0], lengths[1], 1.0 if held_grip else 0.0, gh, _claw.get(proto_name, 1.0), ITEM_DROP])
	return PackedFloat32Array([Visuals.HEIGHTS.get("inserter", 0.3), SHOULDER_HEIGHT, HAND_HEIGHT, UPPER_ARM, FOREARM,
		TURNTABLE.x, TURNTABLE.y, TURNTABLE.z, SHOULDER.x, SHOULDER.y, SHOULDER.z, HAND_SIZE.x, HAND_SIZE.y, HAND_SIZE.z,
		FINGER_SIZE.x, FINGER_SIZE.y, FINGER_SIZE.z, ARM_THICKNESS, STEEL.r, STEEL.g, STEEL.b, DARK_STEEL.r, DARK_STEEL.g,
		DARK_STEEL.b])


## (--native-inserters) A batch's MultiMeshes' capacities (mode 0 sprite: by model name; 1 rig, 2 model: prototype).
func _batch_caps(m: int, key: String) -> PackedInt32Array:
	match m:
		0:
			return _caps_of(_sprite_mmis.get(key))
		1:
			var rig_entry: Variant = _rigs.get(key)
			return _caps_of((rig_entry as Dictionary).get("mmis") if rig_entry is Dictionary else null)
		2:
			return _caps_of(_model_parts.get(key))
	return _caps_of(_parts)


## A rig batch's arms stretched to reach (said once a prototype).
func _say_stretched(key: String, rig: Dictionary, stretch: float) -> void:
	if stretch > 1.0 and not _stretched.has(key):
		_stretched[key] = true
		var lengths: Array = rig["lengths"]
		print("[inserters] %s: the model's arm (%.3f) is shorter than the hand's reach: stretched to reach (x%.3f)" % [
			key, float(lengths[0]) + float(lengths[1]), stretch])


## (--native-inserter-loop) Every slotted arm's state copied back from InserterPoseNative onto its Arm (the pose drawn,
## pincers, moving state, grabs), as the loop below would have left it: before that loop runs again, and for the tests.
func sync_arms() -> void:
	if not _loop_was or _pn == null:
		return
	for unit in _arms:
		var arm: Arm = _arms[unit]
		if arm.slot < 0:
			continue
		var st: PackedFloat64Array = _pn.draw_state(arm.slot)
		if st.size() < 10:
			continue
		arm.angle = st[0]
		arm.reach = st[1]
		arm.item_id = int(st[2])
		arm.close = st[3]
		arm.seen_angle = st[4]
		arm.seen_reach = st[5]
		arm.moved_at = st[6]
		arm.held_was = int(st[7])
		arm.grabs = int(st[8])
		arm.item_count = int(st[14]) if st.size() >= 15 else (1 if arm.item_id > 0 else 0)


static func _loop_hidden_has(hidden: PackedInt32Array, c: Vector2i) -> bool:
	for i in range(0, hidden.size(), 2):
		if hidden[i] == c.x and hidden[i + 1] == c.y:
			return true
	return false


## (--native-inserter-loop) The frame from the native slots (the loop below's twin; see native_loop). After pose_all.
func _process_native_loop(delta: float, now: float, animator, bc: Variant, check_behind: bool, held: Dictionary,
		held_yaws: Dictionary) -> void:
	var tp := Time.get_ticks_usec()
	var pack_ver := ModelLibrary.ModelPacks.version
	var model_ver := _model_ver()
	if pack_ver != _loop_pack_ver or model_ver != _loop_model_ver:
		_loop_pack_ver = pack_ver
		_loop_model_ver = model_ver
		_pn.clear_modes()
		Probing.count("arm_modes_cleared")
	if animator != null and _loop_moving >= 0 and animator.arm_working.size() != _loop_moving:
		_pn.forget_reports()  # (someone else changed the animator's hands: tell each again)
	var hidden := PackedInt32Array()
	if check_behind:
		for c: Vector2i in _loop_chunks:
			if bc.hidden(c):
				hidden.append(c.x)
				hidden.append(c.y)
	var want: PackedInt32Array = _pn.frame_check(world.entities, hidden)
	var more_hidden := false
	for s in want:
		var arm: Arm = _slot_arms[s] if s < _slot_arms.size() else null
		if arm == null:
			continue
		if not arm.bound:
			_bind(arm, world.entities[arm.unit])
			if check_behind and bc.hidden(arm.chunk):
				if not _loop_hidden_has(hidden, arm.chunk):
					hidden.append(arm.chunk.x)
					hidden.append(arm.chunk.y)
					more_hidden = true
				continue  # (behind the view: live, neither posed nor its mode decided, as the loop below)
			_pn.apply_pose(s)  # (the loop below poses an arm once bound, unless it is behind the view)
		_decide_mode(arm)
		_push_draw(arm)
	if more_hidden:
		_pn.set_hidden(hidden)
	for arm: Arm in _lift_wait.keys():
		arm.card_lift = _platform_lift(arm.proto_name, arm.dir)
		if not is_nan(arm.card_lift):
			_lift_wait.erase(arm)
			_push_draw(arm)
	# (handoff) The hands meeting a belt item, steered as the loop below steers them.
	for arm: Arm in _meet_arms.keys():
		if arm.slot < 0 or arm.meets.is_empty():
			_meet_arms.erase(arm)
			continue
		var rec = world.entities.get(arm.unit)
		if rec == null or not arm.bound or (check_behind and bc.hidden(rec.chunk)):
			continue
		var pz: PackedFloat64Array = _pn.get_pose(arm.slot)
		arm.angle = pz[0]
		arm.reach = pz[1]
		_steer(arm, _drawn)
		_pn.set_pose(arm.slot, arm.angle, arm.reach)
	var gh := _grip_height()
	var keys := []
	keys.resize(_loop_keys.size())
	for k in _loop_keys.size():
		var e: Array = _loop_keys[k]
		var m: int = e[0]
		keys[k] = [m, _batch_caps(m, e[1]), _batch_params(m, e[2], e[3], e[4], gh)]
	var out: Array = _pn.frame_draw(PackedFloat64Array([now, delta / CLOSE_TIME, 1.0 if animator != null else 0.0, STILL,
		MOVING_HOLD]), keys)
	if Probing.on:
		Probing.add("ia_loop", tp)
		tp = Time.get_ticks_usec()
	var results: Array = out[0]
	for m in 3:
		(_nres[m] as Dictionary).clear()
	_nres[3] = null
	for k in results.size():
		var r: Variant = results[k]
		if r == null:
			continue
		var e: Array = _loop_keys[k]
		var m: int = e[0]
		if m == 3:
			_nres[3] = r
		else:
			(_nres[m] as Dictionary)[e[1]] = r
			if m == 1:
				_say_stretched(e[1], e[4], float(r[5]))
	var hold: PackedFloat64Array = out[1]
	var stride := 12 if _pn_counts else 11
	for i in range(0, hold.size(), stride):
		var arm: Arm = _slot_arms[int(hold[i])]
		arm.angle = hold[i + 1]
		arm.item_id = int(hold[i + 2])
		arm.item_count = int(hold[i + 11]) if stride == 12 else (1 if arm.item_id > 0 else 0)
		var g := int(hold[i + 3])
		if g != arm.grabs:
			arm.grabs = g
			arm.held_key = 0
		arm.held_was = arm.item_id
		_gripped = hold[i + 10] == 1.0
		_grip_at = Vector3(hold[i + 7], hold[i + 8], hold[i + 9])
		_hold(arm, arm.unit, Vector3(hold[i + 4], hold[i + 5], hold[i + 6]), held, held_yaws)
	_native_fill()
	if Probing.on:
		Probing.add("ia_batches", tp)
		tp = Time.get_ticks_usec()
	var moving: PackedInt32Array = out[2]
	if animator != null:
		for i in range(0, moving.size(), 2):
			var arm: Arm = _slot_arms[moving[i]]
			animator.arm_moving(world.entities[arm.unit], moving[i + 1] == 1)
	for s in (out[3] as PackedInt32Array):
		var arm: Arm = _slot_arms[s]
		var c: Vector2i = world.entities[arm.unit].chunk
		_rest_live[arm.unit] = c
		_rest_now[c] = true
	for s in (out[4] as PackedInt32Array):
		var arm: Arm = _slot_arms[s]
		if _rest_live.has(arm.unit):
			_rest_now[_rest_live[arm.unit]] = true
			_rest_live.erase(arm.unit)
	_cards.draw(held, held_yaws)
	if Probing.on:
		Probing.add("ia_cards", tp)
		tp = Time.get_ticks_usec()
	_update_rest(_rest_live, delta, true)
	if Probing.on:
		Probing.add("ia_rest", tp)
		tp = Time.get_ticks_usec()
	if animator != null and not animator.arm_working.is_empty():
		_stop_unseen(animator, _rest_live)
	if animator != null:
		_loop_moving = _pn.moving_count()
	if Probing.on:
		Probing.add("ia_stop", tp)
	loop_frames += 1
	_frames += 1


## What an arm holds, queued for ItemCards.draw: the kind it is drawn as, where it hangs (held_at, with the
## grip _gripped/_grip_at the arm's drawing left) and how it is turned.
func _hold(arm: Arm, unit: int, wrist: Vector3, held: Dictionary, held_yaws: Dictionary) -> void:
	if arm.held_key == 0 or ItemCards.item_of(arm.held_key) != arm.item_id:
		arm.held_key = _cards.variant_key(arm.item_id, hash([unit, arm.grabs]))
	var key := arm.held_key
	if not held.has(key):
		held[key] = []
		held_yaws[key] = []
	var base_pos := held_at(arm, wrist)
	# (--inserter-grip) A model sits square in the grip, turned with the hand; an icon card keeps its
	# slight turn (an icon turned with the hand would stand on its head on the way back).
	var base_yaw: float = -arm.angle if _gripped and _cards.turns(key) else ItemCards.turn_for(unit)
	var copies := clampi(arm.item_count, 1, MAX_HELD_STACK) if hand_stack else 1
	var positions: Array = held[key]
	var yaws: Array = held_yaws[key]
	if copies <= 1:
		positions.append(base_pos)
		yaws.append(base_yaw)
		return
	_cards.prepare(key)
	var step := _cards.pile_step(key)
	for c in copies:
		positions.append(base_pos + Vector3(0.0, step * float(c), 0.0))
		yaws.append(base_yaw + ItemCards.PILE_TURN * float(c))


## (--native-inserters) Queues `arm` for its mode's native batch under `key` (0 sprite: model name; 1 rig, 2 model:
## prototype; 3 basic): its drawn pose and what the geometry needs of it. `slot` is its place in _ord_* (-1: it
## holds nothing, its wrist isn't needed).
func _nb_add(mode: int, key: String, arm: Arm, slot: int) -> void:
	var batches: Dictionary = _nb[mode]
	var b: NBatch = batches.get(key)
	if b == null:
		b = NBatch.new()
		batches[key] = b
	if b.slots.is_empty():
		b.first = arm
	b.slots.append(slot)
	var inp := b.inp
	inp.push_back(arm.base.x)
	inp.push_back(arm.base.y)
	inp.push_back(arm.angle)
	inp.push_back(arm.reach)
	match mode:
		0:
			inp.push_back(1.0 if arm.item_id > 0 else 0.0)
			inp.push_back(arm.card_lift)
			if keep_sprite_xf:
				b.arms.append(arm)
		1:
			inp.push_back(arm.close)
			var p := arm.placed
			inp.push_back(p.basis.x.x)
			inp.push_back(p.basis.x.y)
			inp.push_back(p.basis.x.z)
			inp.push_back(p.basis.y.x)
			inp.push_back(p.basis.y.y)
			inp.push_back(p.basis.y.z)
			inp.push_back(p.basis.z.x)
			inp.push_back(p.basis.z.y)
			inp.push_back(p.basis.z.z)
			inp.push_back(p.origin.x)
			inp.push_back(p.origin.y)
			inp.push_back(p.origin.z)
		2:
			inp.push_back(1.0 if arm.item_id > 0 else 0.0)
		3:
			inp.push_back(arm.color.r)
			inp.push_back(arm.color.g)
			inp.push_back(arm.color.b)
			inp.push_back(arm.color.a)


static func _caps_of(mmis: Variant) -> PackedInt32Array:
	var caps := PackedInt32Array()
	if mmis is Array:
		for mmi in (mmis as Array):
			caps.append(0 if mmi == null else (mmi as MultiMeshInstance3D).multimesh.instance_count)
	return caps


## (--native-inserters) Runs the queued batches, puts the wrists and grips back, queues the held items and fills
## the MultiMeshes (every one: those with no arm this frame show none).
func _run_native(held: Dictionary, held_yaws: Dictionary) -> void:
	_native_batches()
	for s in _ord_arms.size():
		_gripped = _ord_gripped[s] == 1
		_grip_at = _ord_grip[s]
		_hold(_ord_arms[s], _ord_units[s], _ord_wrist[s], held, held_yaws)
	_native_fill()


## (--native-inserters) The batches themselves: native results into _nres, wrists and grips into their slots.
func _native_batches() -> void:
	var gh := _grip_height()
	var n := _ord_arms.size()
	_ord_wrist.resize(n)
	_ord_grip.resize(n)
	_ord_gripped.resize(n)
	for m in 3:
		(_nres[m] as Dictionary).clear()
	_nres[3] = null
	for m in 4:
		for key: String in (_nb[m] as Dictionary):
			var b: NBatch = _nb[m][key]
			if b.slots.is_empty():
				continue
			var arm := b.first
			var r: Array
			var caps := _batch_caps(m, key)
			var params := _batch_params(m, arm.proto_name, arm.mode_cards, arm.mode_rig, gh)
			match m:
				0:
					r = _native.sprite_arms(b.inp, caps, params)
				1:
					r = _native.rig_arms(b.inp, caps, params)
					_say_stretched(key, arm.mode_rig, float(r[5]))
				2:
					r = _native.model_arms(b.inp, caps, params)
				3:
					r = _native.basic_arms(b.inp, caps, params)
			if m == 3:
				_nres[3] = r
			else:
				(_nres[m] as Dictionary)[key] = r
			var wr: PackedFloat32Array = r[2]
			var gr: PackedFloat32Array = r[3]
			var gripped: int = 1 if r[4] else 0
			for i in b.slots.size():
				var s := b.slots[i]
				if s >= 0:
					_ord_wrist[s] = Vector3(wr[i * 3], wr[i * 3 + 1], wr[i * 3 + 2])
					_ord_grip[s] = Vector3(gr[i * 3], gr[i * 3 + 1], gr[i * 3 + 2])
					_ord_gripped[s] = gripped
			if m == 0 and keep_sprite_xf:
				var bufs: Array = r[0]
				var next := [0, 0, 0]
				for i in b.arms.size():
					var a: Arm = b.arms[i]
					var hand: int = SpritePiece.CLOSED if a.item_id > 0 else SpritePiece.OPEN
					a.sprite_xf = [_buf_xf(bufs[0], i * 12), _buf_xf(bufs[hand], next[hand] * 12), hand]
					next[hand] += 1


## (--native-inserters) Every arm MultiMesh filled from the batches' results (those with no arm this frame show none).
func _native_fill() -> void:
	for p in _parts.size():
		_fill_native(_parts[p].multimesh, _nres[3], p, 16)
	for proto_name in _model_parts:
		var pieces = _model_parts[proto_name]
		if pieces == null:
			continue
		for p in ArmPiece.size():
			_fill_native((pieces[p] as MultiMeshInstance3D).multimesh, (_nres[2] as Dictionary).get(proto_name), p, 12)
	for proto_name in _rigs:
		var rig_entry: Variant = _rigs[proto_name]
		if not (rig_entry is Dictionary):
			continue
		var mmis: Array = (rig_entry as Dictionary).get("mmis", [])
		for p in mmis.size():
			if mmis[p] != null:
				_fill_native((mmis[p] as MultiMeshInstance3D).multimesh, (_nres[1] as Dictionary).get(proto_name), p, 12)
	for model in _sprite_mmis:
		var mmis: Array = _sprite_mmis[model]
		for p in mmis.size():
			_fill_native((mmis[p] as MultiMeshInstance3D).multimesh, (_nres[0] as Dictionary).get(model), p, 12)


static func _buf_xf(buf: PackedFloat32Array, o: int) -> Transform3D:
	return Transform3D(Basis(Vector3(buf[o], buf[o + 4], buf[o + 8]), Vector3(buf[o + 1], buf[o + 5], buf[o + 9]),
		Vector3(buf[o + 2], buf[o + 6], buf[o + 10])), Vector3(buf[o + 3], buf[o + 7], buf[o + 11]))


## (--native-inserters) Puts piece `p` of a native result (null: none) into `mm`, as _fill_xforms does the lists.
func _fill_native(mm: MultiMesh, r: Variant, p: int, stride: int) -> void:
	var count := 0
	var buf := PackedFloat32Array()
	if r != null:
		count = (r[1] as PackedInt32Array)[p]
		buf = (r[0] as Array)[p]
	if mm.instance_count < count:
		mm.instance_count = maxi(count, maxi(mm.instance_count * 2, 16))
	mm.visible_instance_count = count
	if count == 0:
		return
	var needed := mm.instance_count * stride
	if buf.size() != needed:
		buf.resize(needed)
	RenderingServer.multimesh_set_buffer(mm.get_rid(), buf)


## (--native-inserters) _draw_rig_arm's constants for one rig, as inserter_arms_native.h lists them.
func _rig_params(rig: Dictionary, gh: float) -> PackedFloat32Array:
	var hinge: Vector3 = rig["hinge"]
	var pivot: Vector3 = rig["pivot"]
	var shoulder: Vector3 = rig["shoulder"]
	var elbow: Vector3 = rig["elbow"]
	var grip: Vector3 = rig["grip"]
	var lengths: Array = rig["lengths"]
	var heads: Array = rig["heads"]
	var axes: Array = rig["axes"]
	var angles: Array = rig.get("grip_angles", rig["angles"]) if held_grip else rig["angles"]
	var out := PackedFloat32Array([hinge.x, hinge.y, hinge.z, pivot.x, pivot.y, pivot.z, shoulder.x, shoulder.y, shoulder.z,
		elbow.x, elbow.y, elbow.z, grip.x, grip.y, grip.z, lengths[0], lengths[1], 1.0 if held_grip else 0.0, gh, ITEM_DROP, RIG_REACH,
		1.0 if heads[ModelRig.Part.TURNTABLE] != null else 0.0])
	for p in [ModelRig.Part.PINCER_A, ModelRig.Part.PINCER_B]:
		if heads[p] == null or angles[p] == null:
			out.append_array(PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]))
		else:
			var head: Vector3 = heads[p]
			var axis: Vector3 = axes[p]
			out.append_array(PackedFloat32Array([1.0, head.x, head.y, head.z, axis.x, axis.y, axis.z, float(angles[p])]))
	return out


## A rig's pincers `delta` seconds on: closing onto a held item, opening once it is let go, over CLOSE_TIME.
static func ease_close(close: float, holding: bool, delta: float) -> float:
	return move_toward(close, 1.0 if holding else 0.0, delta / CLOSE_TIME)


## (L4) Whether an arm's hand is moving: drawn turning or reaching this frame, or within MOVING_HOLD ticks of
## it (`now`, the tick the hands are drawn at).
static func _moving(arm: Arm, now: float) -> bool:
	if absf(angle_difference(arm.seen_angle, arm.angle)) > STILL or absf(arm.reach - arm.seen_reach) > STILL:
		arm.moved_at = now  # (NAN the first frame: not moving)
	arm.seen_angle = arm.angle
	arm.seen_reach = arm.reach
	return now - arm.moved_at < MOVING_HOLD and now >= arm.moved_at


## (L4) Hands no longer drawn live (left the bridge's radius, gone, mined) stop: their arms rest.
func _stop_unseen(animator, live: Dictionary) -> void:
	for unit: int in animator.arm_working.keys():
		if live.has(unit):
			continue
		var rec = world.entities.get(unit)
		if rec == null:
			animator.arm_working.erase(unit)
		else:
			animator.arm_moving(rec, false)


## (rest arms) Real 3D resting arm meshes per chunk (Mode.RIG and Mode.MODEL) and box fallback when
## --inserter-rest-arms=box or no 3D/sprite model exists for a prototype; per chunk its arms' instances;
## the chunks to work out again (entities changed: a few a frame; a live arm came or went: at once), the
## arms drawn live last frame (unit -> chunk), and what was last put together.
var _rest_mmi: MultiMeshInstance3D = null
var _rest_box_mesh: BoxMesh = null
var _rest_box_mat: ShaderMaterial = null
var _rest := {}  # chunk -> PackedFloat32Array
var _rest_chunk_mmis := {}  # (chunked rest arms) Vector2i chunk -> MultiMeshInstance3D
var _rest_chunk_counts := {}  # (chunked rest arms) Vector2i chunk -> instance count
var _rest_upload := {}  # Vector2i chunk -> true (needs MMI upload/erase)
var _rest_total_instances := 0
var rest_chunk_uploads := 0  # (tests) per-chunk rest MMI uploads/removals performed
var _rest_3d_root: Node3D = null
var _rest_3d_mmis := {}  # _rest_3d_key(chunk) (chunk or region) -> {Mesh -> MultiMeshInstance3D}
var _rest_3d_pending := {}  # Vector2i chunk -> {Mesh -> PackedFloat32Array}
var _rest_3d_upload := {}  # Vector2i chunk -> true
var _rest_3d_shadow := {}  # _rest_3d_key(chunk) -> GeometryInstance3D.ShadowCastingSetting
var _rest_3d_counts := {}  # Vector2i chunk -> [rig_arms, model_arms, basic_arms]
## (--rest-arms-region) _rest_3d_mmis and _rest_3d_shadow are keyed by _rest_3d_key(chunk): the chunk itself when off,
## its region (Vector2i of floor(chunk / rest_region)) when on.
var _rest_3d_bufs := {}  # (region) Vector2i chunk -> {Mesh -> PackedFloat32Array}, kept after its upload to join again
var _rest_3d_region_chunks := {}  # (region) Vector2i region -> {Vector2i chunk: true} with buffers
var _rest_3d_region_size := -1  # (region) the size the keys above were made with
var rest_3d_region_usec := 0  # (tests, probes) the last regions' upload's time, µs
var rest_3d_region_uploads := 0  # (tests) region MultiMesh sets put together
var _rest_pack_rigs := {}  # model ("proto@pack") -> rig dict or {}
var _rest_pack_meshes := {}  # model ("proto@pack") -> Array of meshes
var _rest_scratch_arm: Arm = Arm.new()
var _rest_rig_lists := [[], [], [], [], []]
var _rest_model_lists := [[], [], []]
var _rest_basic_lists := [[], [], [], [], [], []]  # (rest_basic_live) Part -> Array[Transform3D]
var _rest_basic_meshes := {}  # (rest_basic_live) the live BASIC parts' meshes (_parts) -> Part: drawn 16 floats an instance
var _rest_basic_seen := true
var rest_basic_count := 0  # (tests, probes) resting arms drawn as the live placeholder arm (rest_basic_live)
var rest_3d_count := 0  # (tests, probes) resting 3D arms drawn (rig + Wube model)
var rest_rig_count := 0
var rest_model_count := 0
var rest_3d_chunk_uploads := 0
var _rest_sprites := {}  # (sprite arms) chunk -> {model name -> [PackedFloat32Array per SpritePiece]}
var sprite_rest_count := 0  # (tests) resting arms drawn as pictures
var _rest_dirty := {}  # chunk -> true
var _rest_now := {}  # chunk -> true
var _rest_live := {}  # unit -> chunk
var _rest_put := false
var _rest_wait := 0.0
var _rest_eprops := -1
var _rest_pack_ver := -1
var _rest_model_gen := -1
var _rest_grip_h := NAN
var _rest_box_fallback_seen := false
var _rest_hooked := false
var _is_inserter := {}  # proto id -> bool
## (--rest-arms-index) A chunk's inserters (their records, in the chunk's order) and belts (tile cell ->
## PackedFloat32Array of x, y, how near counts (0.6; 1 for a splitter) per belt), made by one walk of its
## entities under its content_rev and the prototypes' version; dropped when world.entities_changed says so.
class RestIndex:
	var rev := -1
	var pver := -1
	var inserters: Array = []
	var belts := {}
	## (native) Per inserter (unit) drawn by the native: [mode, model, proto name, rig/pictures/meshes, its inputs,
	## its batch's key],
	## worked out once under `stamp` (what they depend on: _rest_stamp), not for every rebuild of the chunk.
	var stamp: Array = []
	var rows := {}
var _rest_index := {}  # Vector2i chunk -> RestIndex
var _index_world: Object = null  # the world whose entities_changed drops them
var rest_index_builds := 0  # (tests) indexes made
var _shadow_keys: Array = []  # (--rest-arms-index) the chunks whose shadows are looked at, a slice a frame
var _shadow_at := 0
var _rest_buffer_cache := PackedFloat32Array()
var rest_buffer: PackedFloat32Array:  # (tests) the instances last put together
	get:
		if not rest_arms_chunked:
			return _rest_buffer_cache
		var combined := PackedFloat32Array()
		for c: Vector2i in _rest:
			combined.append_array(_rest[c])
		return combined
	set(v):
		_rest_buffer_cache = v
var rest_count := 0  # (tests, probes) resting box arms drawn
static var _shadow_small := not Switches.has("--shadow-small=old")
static var _keep_inserter_shadows := not Switches.has("--inserter-shadows=old")


## (rest arms) After the live arms are drawn: the chunks whose inserters changed, or whose live arms came or
## went, worked out again, and the resting arms put together when any did.
func _update_rest(live: Dictionary, delta: float, live_kept := false) -> void:
	if not rest_arms or world == null:
		if _rest_mmi != null and _rest_mmi.visible:
			_rest_mmi.visible = false
		if _rest_3d_root != null and _rest_3d_root.visible:
			_rest_3d_root.visible = false
		for mmis: Array in _sprite_rest_mmis.values():
			for mmi in mmis:
				(mmi as MultiMeshInstance3D).visible = false
		return
	if not _rest_hooked and world.has_signal("entities_changed"):
		_rest_hooked = true
		world.entities_changed.connect(func(c: Vector2i) -> void: _rest_dirty[c] = true)
		for c in world.chunks:
			_rest_dirty[c] = true
	if _rest_mmi == null:
		_rest_box_mesh = BoxMesh.new()
		_rest_box_mesh.size = Vector3.ONE
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = _rest_box_mesh
		_rest_box_mat = ShaderMaterial.new()
		_rest_box_mat.shader = RestShader
		_rest_box_mat.set_shader_parameter("roughness", 0.6)
		_rest_mmi = MultiMeshInstance3D.new()
		_rest_mmi.name = "RestingArms"
		_rest_mmi.multimesh = mm
		_rest_mmi.material_override = _rest_box_mat
		_rest_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_rest_mmi)
	_rest_mmi.visible = true
	if _rest_3d_root != null:
		_rest_3d_root.visible = true
	for mmis: Array in _sprite_rest_mmis.values():
		for mmi in mmis:
			(mmi as MultiMeshInstance3D).visible = true
	if not live_kept:  # (--native-inserter-loop keeps _rest_live itself, marking the chunks arms came to or left)
		for u in live:
			if not _rest_live.has(u):
				_rest_now[live[u]] = true
		for u in _rest_live:
			if not live.has(u):
				_rest_now[_rest_live[u]] = true
		_rest_live = live.duplicate()
	var dirty_all := false
	if eprops.size() != _rest_eprops:
		_rest_eprops = eprops.size()
		dirty_all = true
	var pack_ver := ModelLibrary.ModelPacks.version
	if _rest_pack_ver != pack_ver:
		if _rest_pack_ver >= 0:
			_rest_pack_rigs.clear()
			_rest_pack_meshes.clear()
			_watch.clear()  # (the names asked again by the lookups made anew)
			_clear_rest_3d_mmis()
			dirty_all = true
		_rest_pack_ver = pack_ver
	var model_gen := _model_ver()
	if _rest_model_gen != model_gen:
		if _rest_model_gen >= 0:
			dirty_all = true
		_rest_model_gen = model_gen
	var gh := _grip_height()
	if is_nan(_rest_grip_h) or not is_equal_approx(_rest_grip_h, gh):
		if not is_nan(_rest_grip_h):
			dirty_all = true
		_rest_grip_h = gh
	if rest_box_fallback != _rest_box_fallback_seen:
		_rest_box_fallback_seen = rest_box_fallback
		dirty_all = true
	if rest_basic_live != _rest_basic_seen:
		_rest_basic_seen = rest_basic_live
		dirty_all = true
	if dirty_all:
		Probing.count("arm_rest_all")
		for c in world.chunks:
			_rest_dirty[c] = true
	var at_once := dirty_all or not _rest_now.is_empty()
	for c: Vector2i in _rest_now.keys():
		if _rest_chunk(c):
			_rest_now.erase(c)
			_rest_dirty.erase(c)
	var t0 := Time.get_ticks_usec()
	for c: Vector2i in _rest_dirty.keys():
		if _rest_chunk(c):
			_rest_dirty.erase(c)
		if Time.get_ticks_usec() - t0 > REST_USEC:
			break
	_rest_wait -= delta
	if _rest_put and (at_once or _rest_wait <= 0.0):
		_rest_put = false
		_rest_wait = REST_REFRESH
		if rest_arms_chunked:
			_flush_rest_chunks()
		else:
			var all := PackedFloat32Array()
			for c in _rest:
				all.append_array(_rest[c])
			var count := all.size() / 16
			var mm := _rest_mmi.multimesh
			if mm.instance_count < count or mm.instance_count > maxi(64, count * 4):
				mm.visible_instance_count = 0
				mm.instance_count = maxi(64, count + count / 2)
			all.resize(mm.instance_count * 16)  # (the rest scaled to nothing, and not drawn)
			_rest_buffer_cache = all
			mm.buffer = all
			mm.visible_instance_count = count
			rest_count = count / 3
		_flush_rest_3d_chunks()
		if not _rest_sprites.is_empty() or not _sprite_rest_mmis.is_empty():
			_put_rest_sprites()
		else:
			sprite_rest_count = 0
	if not _rest_3d_mmis.is_empty():
		_sync_rest_3d_shadows()


## (chunked rest arms) Upload only dirty chunks into per-chunk MultiMesh children of _rest_mmi.
var _rest_behind_connected: Object = null


func _rest_behind_hidden(c: Vector2i) -> bool:
	if not ViewPriority.tight_cull or world == null or not is_instance_valid(world):
		return false
	var bc: Variant = world.get("behind_cull")
	return bc != null and is_instance_valid(bc) and bc.is_active() and bc.hidden(c)


func _connect_rest_behind() -> void:
	if world != null and is_instance_valid(world):
		var bc: Variant = world.get("behind_cull")
		if bc != _rest_behind_connected and bc != null and is_instance_valid(bc):
			_rest_behind_connected = bc
			if bc.has_signal("chunk_visibility_changed"):
				bc.chunk_visibility_changed.connect(_on_rest_behind_visibility)


func _on_rest_behind_visibility(c: Vector2i, drawn: bool) -> void:
	var vis := drawn or not _rest_behind_hidden(c)
	var mmi: MultiMeshInstance3D = _rest_chunk_mmis.get(c)
	if mmi != null and is_instance_valid(mmi):
		mmi.visible = vis
	var key := _rest_3d_key(c)
	# Regions on: the region shows while any other chunk of it does (chunks round the origin are their own key).
	if rest_region > 1:
		vis = vis or _rest_3d_region_shows(key, c)
	var chunk_mmis: Variant = _rest_3d_mmis.get(key)
	if chunk_mmis is Dictionary:
		for m: MultiMeshInstance3D in (chunk_mmis as Dictionary).values():
			if m != null and is_instance_valid(m):
				m.visible = vis and m.multimesh != null and m.multimesh.visible_instance_count > 0


func _flush_rest_chunks() -> void:
	_connect_rest_behind()
	if _rest_mmi != null and _rest_mmi.multimesh != null:
		_rest_mmi.multimesh.visible_instance_count = 0
	for c: Vector2i in _rest_upload.keys():
		_rest_upload.erase(c)
		var buf: PackedFloat32Array = _rest.get(c, PackedFloat32Array())
		var count := buf.size() / 16
		var prev: int = _rest_chunk_counts.get(c, 0)
		_rest_total_instances += count - prev
		var mmi: MultiMeshInstance3D = _rest_chunk_mmis.get(c)
		if count == 0:
			_rest_chunk_counts.erase(c)
			if mmi != null:
				_rest_chunk_mmis.erase(c)
				mmi.queue_free()
				rest_chunk_uploads += 1
			continue
		_rest_chunk_counts[c] = count
		if mmi == null:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.mesh = _rest_box_mesh
			mmi = MultiMeshInstance3D.new()
			mmi.name = "RestChunk_%d_%d" % [c.x, c.y]
			mmi.multimesh = mm
			mmi.material_override = _rest_box_mat
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_rest_mmi.add_child(mmi)
			_rest_chunk_mmis[c] = mmi
		var cmm := mmi.multimesh
		if cmm.instance_count < count or cmm.instance_count > maxi(16, count * 2):
			cmm.visible_instance_count = 0
			cmm.instance_count = maxi(16, count + count / 2)
		var padded := buf
		if padded.size() != cmm.instance_count * 16:
			padded = buf.duplicate()
			padded.resize(cmm.instance_count * 16)
		cmm.buffer = padded
		cmm.visible_instance_count = count
		mmi.visible = not _rest_behind_hidden(c)
		rest_chunk_uploads += 1
	rest_count = _rest_total_instances / 3


func _clear_rest_3d_mmis() -> void:
	for chunk_mmis: Variant in _rest_3d_mmis.values():
		if chunk_mmis is Dictionary:
			for mmi: Variant in (chunk_mmis as Dictionary).values():
				var node := mmi as MultiMeshInstance3D
				if node != null and is_instance_valid(node):
					node.queue_free()
	_rest_3d_mmis.clear()
	_rest_3d_pending.clear()
	_rest_3d_upload.clear()
	_rest_3d_shadow.clear()
	_rest_3d_counts.clear()
	_rest_3d_bufs.clear()
	_rest_3d_region_chunks.clear()
	_rest_3d_region_size = -1
	rest_rig_count = 0
	rest_model_count = 0
	rest_3d_count = 0
	rest_basic_count = 0
	rest_3d_chunk_uploads = 0


## A chunk's resting 3D arms' shadow casting: as a live arm's (always on) where it can show (rest_shadows_live), off in
## a SHADOWS_NONE chunk (no ground in view its shadow could fall on: the live arm's there is drawn for nothing).
func _rest_3d_cast_shadow(c: Vector2i) -> GeometryInstance3D.ShadowCastingSetting:
	if world == null or not is_instance_valid(world):
		return GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var cv: Variant = world.chunks.get(c)
	if cv == null:
		return GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var tier: Variant = cv.get("shadow_tier")
	if tier == null:
		return GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var t := int(tier)
	if t == 0:
		return GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if t == 1:
		var keep := rest_shadows_live or (_keep_inserter_shadows and (ModelLods.quality_name == "high" or ModelLods.quality_name == "ultra"))
		if _shadow_small and not keep:
			return GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return GeometryInstance3D.SHADOW_CASTING_SETTING_ON


func _sync_rest_3d_shadows() -> void:
	if rest_index:
		# (--rest-arms-index) REST_SHADOW_CHUNKS chunks a frame in turn (a chunk just uploaded was set then).
		if _shadow_at >= _shadow_keys.size():
			_shadow_keys = _rest_3d_mmis.keys()
			_shadow_at = 0
		var end := mini(_shadow_at + REST_SHADOW_CHUNKS, _shadow_keys.size())
		if rest_region > 1:
			# (region) REST_SHADOW_CHUNKS of the regions' chunks a frame, a region whole.
			var budget := 0
			var i := _shadow_at
			while i < _shadow_keys.size() and budget < REST_SHADOW_CHUNKS:
				var rk: Vector2i = _shadow_keys[i]
				if _rest_3d_mmis.has(rk):
					var members: Variant = _rest_3d_region_chunks.get(rk)
					budget += maxi(1, (members as Dictionary).size() if members is Dictionary else 1)
					_sync_rest_3d_shadow(rk)
				i += 1
			_shadow_at = i
			return
		for i in range(_shadow_at, end):
			var k: Vector2i = _shadow_keys[i]
			if _rest_3d_mmis.has(k):
				_sync_rest_3d_shadow(k)
		_shadow_at = end
		return
	for c: Vector2i in _rest_3d_mmis:
		_sync_rest_3d_shadow(c)


func _sync_rest_3d_shadow(c: Vector2i) -> void:
	var want := _rest_3d_key_cast(c)
	if want == int(_rest_3d_shadow.get(c, -1)):
		return
	_rest_3d_shadow[c] = want
	var chunk_mmis: Dictionary = _rest_3d_mmis[c]
	for mmi: Variant in chunk_mmis.values():
		var node := mmi as MultiMeshInstance3D
		if node != null and is_instance_valid(node):
			node.cast_shadow = want


static func _rest_region_size() -> int:
	var v := Switches.value("--rest-arms-region", str(REST_REGION_DEFAULT)).to_lower()
	if v == "off" or not v.is_valid_int():
		return 0
	var n := clampi(int(v), 0, 64)
	return 0 if n <= 1 else n


## (--rest-arms-region) The key a chunk's resting 3D MultiMeshes are kept under: the chunk (off) or its region.
func _rest_3d_key(c: Vector2i) -> Vector2i:
	if rest_region <= 1:
		return c
	return Vector2i(floori(float(c.x) / rest_region), floori(float(c.y) / rest_region))


## A key's shadow casting: the chunk's (off), or ON if any of the region's chunks with arms would cast.
func _rest_3d_key_cast(k: Vector2i) -> GeometryInstance3D.ShadowCastingSetting:
	if rest_region <= 1:
		return _rest_3d_cast_shadow(k)
	var members: Variant = _rest_3d_region_chunks.get(k)
	if not (members is Dictionary):
		return _rest_3d_cast_shadow(k)
	for c: Vector2i in members:
		if _rest_3d_cast_shadow(c) != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			return GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## (region) Whether any of region k's chunks (but `except`, told apart by the caller) shows.
func _rest_3d_region_shows(k: Vector2i, except := Vector2i(0x7fffffff, 0)) -> bool:
	var members: Variant = _rest_3d_region_chunks.get(k)
	if not (members is Dictionary):
		return false
	for c: Vector2i in members:
		if c != except and not _rest_behind_hidden(c):
			return true
	return false


func _flush_rest_3d_chunks() -> void:
	if _rest_3d_upload.is_empty():
		return
	_connect_rest_behind()
	if _rest_3d_root == null:
		_rest_3d_root = Node3D.new()
		_rest_3d_root.name = "RestingArms3D"
		add_child(_rest_3d_root)
	_rest_3d_root.visible = rest_arms
	if rest_region > 1 or _rest_3d_region_size > 1:
		if _rest_3d_region_size != rest_region:
			_rekey_rest_3d()
		if rest_region > 1:
			_flush_rest_3d_regions()
			_count_rest_3d()
			return
	for c: Vector2i in _rest_3d_upload.keys():
		_rest_3d_upload.erase(c)
		var pending: Dictionary = _rest_3d_pending.get(c, {})
		_rest_3d_pending.erase(c)
		var chunk_mmis: Dictionary = _rest_3d_mmis.get(c, {})
		if pending.is_empty():
			if not chunk_mmis.is_empty():
				for mmi: Variant in chunk_mmis.values():
					var node := mmi as MultiMeshInstance3D
					if node != null and is_instance_valid(node):
						node.queue_free()
				_rest_3d_mmis.erase(c)
				_rest_3d_shadow.erase(c)
				rest_3d_chunk_uploads += 1
			continue
		var vis := not _rest_behind_hidden(c)
		var cast := _rest_3d_cast_shadow(c)
		_rest_3d_shadow[c] = cast
		for mesh_key: Variant in chunk_mmis.keys():
			if not pending.has(mesh_key):
				var old_mmi := chunk_mmis[mesh_key] as MultiMeshInstance3D
				if old_mmi != null and is_instance_valid(old_mmi):
					if old_mmi.multimesh != null:
						old_mmi.multimesh.visible_instance_count = 0
					old_mmi.visible = false
		for mesh_key: Variant in pending:
			var mesh := mesh_key as Mesh
			var buf: PackedFloat32Array = pending[mesh_key]
			# (rest_basic_live) The live placeholder arm's parts carry a colour: 16 floats an instance.
			var basic := _rest_basic_meshes.has(mesh)
			var stride := 16 if basic else 12
			var count := buf.size() / stride
			if count == 0 or mesh == null:
				continue
			var mmi: MultiMeshInstance3D = chunk_mmis.get(mesh)
			if mmi == null or not is_instance_valid(mmi):
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.use_colors = basic
				mm.mesh = mesh
				mmi = MultiMeshInstance3D.new()
				mmi.name = "Rest3D_%d_%d" % [c.x, c.y]
				mmi.multimesh = mm
				if basic:
					mmi.material_override = Visuals.instance_material()  # (as the live _parts')
				_rest_3d_root.add_child(mmi)
				chunk_mmis[mesh] = mmi
			var cmm := mmi.multimesh
			if cmm.instance_count < count or cmm.instance_count > maxi(16, count * 2):
				cmm.visible_instance_count = 0
				cmm.instance_count = maxi(16, count + count / 2)
			var padded := buf
			if padded.size() != cmm.instance_count * stride:
				padded = buf.duplicate()
				padded.resize(cmm.instance_count * stride)
			cmm.buffer = padded
			cmm.visible_instance_count = count
			mmi.cast_shadow = cast
			mmi.visible = vis
		_rest_3d_mmis[c] = chunk_mmis
		rest_3d_chunk_uploads += 1
	_count_rest_3d()


## (region) The size changed (a test, or the switch flipped at run time): every MultiMesh dropped, every chunk with
## arms uploaded again under the new keys (the chunks' kept buffers, or a fresh work-out when off kept none).
func _rekey_rest_3d() -> void:
	for chunk_mmis: Variant in _rest_3d_mmis.values():
		if chunk_mmis is Dictionary:
			for mmi: Variant in (chunk_mmis as Dictionary).values():
				var node := mmi as MultiMeshInstance3D
				if node != null and is_instance_valid(node):
					node.queue_free()
	_rest_3d_mmis.clear()
	_rest_3d_shadow.clear()
	_rest_3d_region_chunks.clear()
	for c: Vector2i in _rest_3d_bufs:
		if not _rest_3d_pending.has(c):
			_rest_3d_pending[c] = _rest_3d_bufs[c]
		_rest_3d_upload[c] = true
	_rest_3d_bufs.clear()
	for c: Vector2i in _rest_3d_counts:
		if not _rest_3d_pending.has(c):
			_rest_dirty[c] = true  # (off kept no buffers: worked out again)
	_rest_3d_region_size = rest_region


## (--rest-arms-region) The changed chunks' buffers kept, and each region holding one put together: per mesh the
## chunks' buffers joined (no per-arm work) into the region's MultiMesh, as _flush_rest_3d_chunks does per chunk.
func _flush_rest_3d_regions() -> void:
	var t0 := Time.get_ticks_usec()
	var regions := {}
	for c: Vector2i in _rest_3d_upload.keys():
		_rest_3d_upload.erase(c)
		var k := _rest_3d_key(c)
		regions[k] = true
		var pending: Dictionary = _rest_3d_pending.get(c, {})
		_rest_3d_pending.erase(c)
		var members: Dictionary = _rest_3d_region_chunks.get(k, {})
		if pending.is_empty():
			_rest_3d_bufs.erase(c)
			members.erase(c)
		else:
			_rest_3d_bufs[c] = pending
			members[c] = true
		if members.is_empty():
			_rest_3d_region_chunks.erase(k)
		else:
			_rest_3d_region_chunks[k] = members
	for k: Vector2i in regions:
		var chunk_mmis: Dictionary = _rest_3d_mmis.get(k, {})
		var members: Variant = _rest_3d_region_chunks.get(k)
		if not (members is Dictionary):
			if not chunk_mmis.is_empty():
				for mmi: Variant in chunk_mmis.values():
					var node := mmi as MultiMeshInstance3D
					if node != null and is_instance_valid(node):
						node.queue_free()
				_rest_3d_mmis.erase(k)
				_rest_3d_shadow.erase(k)
				rest_3d_chunk_uploads += 1
			continue
		var parts := {}  # Mesh -> Array of the chunks' PackedFloat32Array
		var vis := false
		for c: Vector2i in members:
			if not vis and not _rest_behind_hidden(c):
				vis = true
			var bufs: Dictionary = _rest_3d_bufs[c]
			for mesh_key: Variant in bufs:
				if parts.has(mesh_key):
					(parts[mesh_key] as Array).append(bufs[mesh_key])
				else:
					parts[mesh_key] = [bufs[mesh_key]]
		var joined := {}  # Mesh -> PackedFloat32Array
		for mesh_key: Variant in parts:
			var out := PackedFloat32Array()
			for b: PackedFloat32Array in parts[mesh_key]:
				out.append_array(b)
			joined[mesh_key] = out
		var cast := _rest_3d_key_cast(k)
		_rest_3d_shadow[k] = cast
		for mesh_key: Variant in chunk_mmis.keys():
			if not joined.has(mesh_key):
				var old_mmi := chunk_mmis[mesh_key] as MultiMeshInstance3D
				if old_mmi != null and is_instance_valid(old_mmi):
					if old_mmi.multimesh != null:
						old_mmi.multimesh.visible_instance_count = 0
					old_mmi.visible = false
		for mesh_key: Variant in joined:
			var mesh := mesh_key as Mesh
			var buf: PackedFloat32Array = joined[mesh_key]
			var basic := _rest_basic_meshes.has(mesh)
			var stride := 16 if basic else 12
			var count := buf.size() / stride
			if mesh == null:
				continue
			var mmi: MultiMeshInstance3D = chunk_mmis.get(mesh)
			if count == 0:
				if mmi != null and is_instance_valid(mmi):
					mmi.multimesh.visible_instance_count = 0
					mmi.visible = false
				continue
			if mmi == null or not is_instance_valid(mmi):
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.use_colors = basic
				mm.mesh = mesh
				mmi = MultiMeshInstance3D.new()
				mmi.name = "Rest3DRegion_%d_%d" % [k.x, k.y]
				mmi.multimesh = mm
				if basic:
					mmi.material_override = Visuals.instance_material()  # (as the live _parts')
				_rest_3d_root.add_child(mmi)
				chunk_mmis[mesh] = mmi
			var cmm := mmi.multimesh
			if cmm.instance_count < count or cmm.instance_count > maxi(16, count * 2):
				cmm.visible_instance_count = 0
				cmm.instance_count = maxi(16, count + count / 2)
			buf.resize(cmm.instance_count * stride)  # (joined is ours: padded in place)
			cmm.buffer = buf
			cmm.visible_instance_count = count
			mmi.cast_shadow = cast
			mmi.visible = vis
		_rest_3d_mmis[k] = chunk_mmis
		rest_3d_chunk_uploads += 1
		rest_3d_region_uploads += 1
	rest_3d_region_usec = Time.get_ticks_usec() - t0


func _count_rest_3d() -> void:
	var rigs_total := 0
	var models_total := 0
	var basic_total := 0
	for counts: Array in _rest_3d_counts.values():
		rigs_total += int(counts[0])
		models_total += int(counts[1])
		if counts.size() > 2:
			basic_total += int(counts[2])
	rest_rig_count = rigs_total
	rest_model_count = models_total
	rest_basic_count = basic_total
	rest_3d_count = rigs_total + models_total


## (sprite arms) The resting arms drawn as pictures put together, one MultiMesh per model and picture.
func _put_rest_sprites() -> void:
	if _rest_sprites.is_empty() and _sprite_rest_mmis.is_empty():
		sprite_rest_count = 0
		return
	var all := {}  # model -> [PackedFloat32Array per SpritePiece]
	for c in _rest_sprites:
		for model: String in _rest_sprites[c]:
			if not all.has(model):
				all[model] = [PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()]
			for p in SpritePiece.size():
				var into: PackedFloat32Array = all[model][p]
				into.append_array(_rest_sprites[c][model][p])
				all[model][p] = into
	sprite_rest_count = 0
	for model: String in all:
		if not _sprite_rest_mmis.has(model):
			var pictures := _sprite_set_for(model)
			if pictures.is_empty():
				continue
			_sprite_rest_mmis[model] = _sprite_instances(model, pictures, "_rest")
	for model: String in _sprite_rest_mmis:
		var per: Array = all.get(model, [PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()])
		for p in SpritePiece.size():
			var buf: PackedFloat32Array = per[p]
			var count := buf.size() / 12
			var mm: MultiMesh = (_sprite_rest_mmis[model][p] as MultiMeshInstance3D).multimesh
			if mm.instance_count < count or mm.instance_count > maxi(16, count * 4):
				mm.visible_instance_count = 0
				mm.instance_count = maxi(16, count + count / 2)
			buf.resize(mm.instance_count * 12)
			mm.buffer = buf
			mm.visible_instance_count = count
			if p == SpritePiece.BASE:
				sprite_rest_count += count


## (--rest-arms-index) Chunk c's index (cv its ChunkView), made again when its content_rev or the prototypes
## moved on or world.entities_changed dropped it.
func _index_for(c: Vector2i, cv) -> RestIndex:
	if _index_world != world and world != null and world.has_signal("entities_changed"):
		if _index_world != null and is_instance_valid(_index_world) and _index_world.is_connected("entities_changed", _on_index_changed):
			_index_world.disconnect("entities_changed", _on_index_changed)
		_index_world = world
		_rest_index.clear()
		world.entities_changed.connect(_on_index_changed)
	var rev_v: Variant = cv.get("content_rev")
	var rev: int = int(rev_v) if rev_v != null else -1
	var pver: int = protos.version if protos != null else -1
	var idx: RestIndex = _rest_index.get(c)
	if idx != null and idx.rev == rev and idx.pver == pver:
		return idx
	idx = RestIndex.new()
	idx.rev = rev
	idx.pver = pver
	rest_index_builds += 1
	if protos != null:
		for rec in cv.entities.values():
			var proto: ProtoDB.EntityProto = protos.entity(rec.proto_id)
			if proto == null:
				continue
			var ins = _is_inserter.get(rec.proto_id)
			if ins == null:
				ins = proto.type == "inserter"
				_is_inserter[rec.proto_id] = ins
			if ins:
				idx.inserters.append(rec)
			elif BELT_TYPES.has(proto.type):
				var cell := Vector2i(floori(rec.pos.x), floori(rec.pos.y))
				var pts: PackedFloat32Array = idx.belts.get(cell, PackedFloat32Array())
				pts.append(rec.pos.x)
				pts.append(rec.pos.y)
				pts.append(1.0 if proto.type == "splitter" or proto.type == "lane-splitter" else 0.6)
				idx.belts[cell] = pts
	_rest_index[c] = idx
	return idx


func _on_index_changed(c: Vector2i) -> void:
	_rest_index.erase(c)


## (--rest-arms-index) One model's resting arms worked out by InserterArmsNative: mode 0 pictures, 1 rig, 2 Wube
## pieces; `b` is [mode, proto name, the rig or the pictures or the meshes, inputs as _nb_add's]. Returns
## the native result's pieces, each cut to its count.
func _rest_native(b: Array, gh: float) -> Array:
	var mode: int = b[0]
	var proto_name: String = b[1]
	var inp: PackedFloat32Array = b[3]
	var lengths: Array = ARM_LENGTHS[ARM_FAMILIES.get(proto_name, "basic")]
	var r: Array
	match mode:
		0:
			var w: Array = (b[2] as Dictionary)["widths"]
			r = _native.sprite_arms(inp, PackedInt32Array([0, 0, 0]), PackedFloat32Array([gh, MODEL_SHOULDER,
				lengths[0], lengths[1], lengths[2], CLAW_DEFAULT, SpriteStandins.FACTORIO_PITCH, HAND_TIP, SPRITE_DEPTH,
				SPRITE_HAND_DEPTH, w[0], w[1], w[2], ITEM_DROP]))
		1:
			r = _native.rig_arms(inp, PackedInt32Array([0, 0, 0, 0, 0]), _rig_params(b[2] as Dictionary, gh))
			if float(r[5]) > 1.0 and not _stretched.has(proto_name):
				_stretched[proto_name] = true
				var rl: Array = (b[2] as Dictionary)["lengths"]
				print("[inserters] %s: the model's arm (%.3f) is shorter than the hand's reach: stretched to reach (x%.3f)" % [
					proto_name, float(rl[0]) + float(rl[1]), float(r[5])])
		_:
			var stretch: float = lengths[2]
			r = _native.model_arms(inp, PackedInt32Array([0, 0, 0]), PackedFloat32Array([MODEL_SHOULDER, HAND_HEIGHT,
				float(lengths[0]) * stretch, float(lengths[1]) * stretch, lengths[0], lengths[1], 1.0 if held_grip else 0.0,
				gh, _claw.get(proto_name, 1.0), ITEM_DROP]))
	var bufs: Array = r[0]
	var counts: PackedInt32Array = r[1]
	var out: Array = []
	for p in bufs.size():
		var buf: PackedFloat32Array = bufs[p]
		var n := counts[p] * 12
		out.append(buf if buf.size() == n else buf.slice(0, n))
	return out


## (rest arms) Chunk c's resting arms worked out again: every inserter in it not drawn live. False when one
## waits for its model (to be tried again).
func _rest_chunk(c: Vector2i) -> bool:
	var cv = world.chunks.get(c)
	_rest_put = true
	_rest_upload[c] = true
	if cv == null:
		_rest.erase(c)
		_rest_sprites.erase(c)
		_rest_3d_pending.erase(c)
		_rest_3d_counts.erase(c)
		_rest_3d_upload[c] = true
		return true
	var buf := PackedFloat32Array()
	var sprites := {}  # model name -> [PackedFloat32Array per SpritePiece]
	var mesh_xfs := {}  # Mesh -> Array[Transform3D]
	var rig_arms := 0
	var model_arms := 0
	var basic_arms := 0
	var basic_bufs := {}  # (rest_basic_live) Mesh -> PackedFloat32Array, 16 floats an instance (transform, colour)
	var done := true
	var saved_gripped := _gripped
	var saved_grip_at := _grip_at
	# (--rest-arms-index) The chunk's inserters only; their 3D and picture arms batched per model for the native.
	var indexed := rest_index
	var index: RestIndex = _index_for(c, cv) if indexed else null
	var recs: Array = index.inserters if indexed else cv.entities.values()
	var nat := indexed and _native != null
	var batches := {}  # (nat) "mode:model" -> [mode, proto name, rig/pictures/meshes, inputs]
	if nat:
		var stamp := _rest_stamp()
		if index.stamp != stamp:
			index.stamp = stamp
			index.rows.clear()
	for rec in recs:
		var proto: ProtoDB.EntityProto = protos.entity(rec.proto_id) if protos != null else null
		if not indexed:
			var ins = _is_inserter.get(rec.proto_id)
			if ins == null:
				ins = proto != null and proto.type == "inserter"
				_is_inserter[rec.proto_id] = ins
			if not ins:
				continue
		if proto == null or _rest_live.has(rec.unit):
			continue
		if nat:
			var row: Variant = index.rows.get(rec.unit)
			if row != null:
				var nb: Variant = batches.get(row[5])
				if nb == null:
					nb = [row[0], row[2], row[3], PackedFloat32Array()]
					batches[row[5]] = nb
				var inp: PackedFloat32Array = nb[3]
				inp.append_array(row[4])
				nb[3] = inp
				if row[0] == 1:
					rig_arms += 1
				elif row[0] == 2:
					model_arms += 1
				continue
		var pack := ModelLibrary.entity_pack(rec.extra)
		var model := proto.name + ("@" + pack if pack != "" else "")
		var pictures := _sprite_set_for(model)
		if not pictures.is_empty():
			var pick := _rest_pick_vec(rec, proto)
			var lift := _platform_lift(proto.name, rec.dir)
			if nat:
				_rest_row(index, batches, rec.unit, 0, model, proto.name, pictures, PackedFloat32Array([rec.pos.x, rec.pos.y,
					pick.angle(), pick.length(), 0.0, 0.0 if is_nan(lift) else lift]))
				continue
			if not sprites.has(model):
				sprites[model] = [PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()]
			var xf := sprite_cards(proto.name, pictures, rec.pos, Vector3(rec.pos.x + pick.x, _grip_height(), rec.pos.y + pick.y),
				0.0 if is_nan(lift) else lift)
			_rest_xf(sprites[model][SpritePiece.BASE], xf[0])
			_rest_xf(sprites[model][SpritePiece.OPEN], xf[1])
			continue
		if rest_box_fallback:
			var box_rig: Variant = _rest_rig_for(proto.name, pack)
			if box_rig == null:
				done = false
				continue
			_rest_arm(buf, rec, proto, box_rig if box_rig is Dictionary else {})
			continue
		var rig: Variant = _rest_rig_for(proto.name, pack)
		if rig == null:
			done = false  # (its model is still being read)
			continue
		if rig is Dictionary and _rig_has_meshes(rig as Dictionary):
			var rig_dict := rig as Dictionary
			var pick := _rest_pick_vec(rec, proto)
			if nat:
				var placed := ModelLibrary.placed(proto.name, proto.type, rec.dir, rec.extra, Vector3(rec.pos.x, 0.0, rec.pos.y))
				var pb := placed.basis
				_rest_row(index, batches, rec.unit, 1, model, proto.name, rig_dict, PackedFloat32Array([rec.pos.x, rec.pos.y,
					pick.angle(), pick.length(), 0.0, pb.x.x, pb.x.y, pb.x.z, pb.y.x, pb.y.y, pb.y.z, pb.z.x, pb.z.y, pb.z.z,
					placed.origin.x, placed.origin.y, placed.origin.z]))
				rig_arms += 1
				continue
			_rest_scratch_arm.proto_name = proto.name
			_rest_scratch_arm.base = rec.pos
			_rest_scratch_arm.dir = rec.dir
			_rest_scratch_arm.angle = pick.angle()
			_rest_scratch_arm.reach = pick.length()
			_rest_scratch_arm.close = 0.0
			_rest_scratch_arm.item_id = 0
			_rest_scratch_arm.placed = ModelLibrary.placed(proto.name, proto.type, rec.dir, rec.extra, Vector3(rec.pos.x, 0.0, rec.pos.y))
			for p in ModelRig.Part.size():
				(_rest_rig_lists[p] as Array).clear()
			_draw_rig_arm(_rest_scratch_arm, rig_dict, _rest_rig_lists)
			var meshes: Array = rig_dict["meshes"]
			for p in mini(meshes.size(), ModelRig.Part.size()):
				var m: Variant = meshes[p]
				if not (m is Mesh):
					continue
				var part_xfs: Array = _rest_rig_lists[p]
				if part_xfs.is_empty():
					continue
				var mesh := m as Mesh
				if not mesh_xfs.has(mesh):
					mesh_xfs[mesh] = []
				(mesh_xfs[mesh] as Array).append_array(part_xfs)
			rig_arms += 1
			continue
		var model_meshes := _rest_model_meshes_for(proto.name, pack)
		if model_meshes.size() >= 2 and model_meshes[ArmPiece.UPPER] is Mesh and model_meshes[ArmPiece.OPEN] is Mesh:
			var pick := _rest_pick_vec(rec, proto)
			if nat:
				_rest_row(index, batches, rec.unit, 2, model, proto.name, model_meshes, PackedFloat32Array([rec.pos.x, rec.pos.y,
					pick.angle(), pick.length(), 0.0]))
				model_arms += 1
				continue
			_rest_scratch_arm.proto_name = proto.name
			_rest_scratch_arm.base = rec.pos
			_rest_scratch_arm.dir = rec.dir
			_rest_scratch_arm.angle = pick.angle()
			_rest_scratch_arm.reach = pick.length()
			_rest_scratch_arm.close = 0.0
			_rest_scratch_arm.item_id = 0
			for p in ArmPiece.size():
				(_rest_model_lists[p] as Array).clear()
			_draw_model_arm(_rest_scratch_arm, _rest_model_lists)
			for p in [ArmPiece.UPPER, ArmPiece.OPEN]:
				var part_xfs: Array = _rest_model_lists[p]
				if part_xfs.is_empty():
					continue
				var mesh := model_meshes[p] as Mesh
				if not mesh_xfs.has(mesh):
					mesh_xfs[mesh] = []
				(mesh_xfs[mesh] as Array).append_array(part_xfs)
			model_arms += 1
			continue
		if rest_basic_live and _rest_basic_ready():
			_rest_basic_arm(basic_bufs, rec, proto)
			basic_arms += 1
			continue
		_rest_arm(buf, rec, proto, rig if rig is Dictionary else {})
	_gripped = saved_gripped
	_grip_at = saved_grip_at
	var native_bufs := {}  # (nat) Mesh -> [PackedFloat32Array, ...] the native's transforms for it
	if not batches.is_empty():
		var gh := _grip_height()
		for key: String in batches:
			var nb: Array = batches[key]
			var pieces := _rest_native(nb, gh)
			match int(nb[0]):
				0:
					sprites[key.substr(2)] = [pieces[SpritePiece.BASE], pieces[SpritePiece.OPEN], PackedFloat32Array()]
				1:
					var meshes: Array = (nb[2] as Dictionary)["meshes"]
					for p in mini(mini(meshes.size(), ModelRig.Part.size()), pieces.size()):
						if meshes[p] is Mesh and not (pieces[p] as PackedFloat32Array).is_empty():
							_rest_mesh_buf(native_bufs, meshes[p], pieces[p])
				_:
					var model_meshes: Array = nb[2]
					for p in [ArmPiece.UPPER, ArmPiece.OPEN]:
						if not (pieces[p] as PackedFloat32Array).is_empty():
							_rest_mesh_buf(native_bufs, model_meshes[p], pieces[p])
	if buf.is_empty():
		_rest.erase(c)
	else:
		_rest[c] = buf
	if sprites.is_empty():
		_rest_sprites.erase(c)
	else:
		_rest_sprites[c] = sprites
	if mesh_xfs.is_empty() and native_bufs.is_empty() and basic_bufs.is_empty():
		_rest_3d_pending.erase(c)
		_rest_3d_counts.erase(c)
		if _rest_3d_mmis.has(c) or _rest_3d_bufs.has(c):
			_rest_3d_upload[c] = true
	else:
		var packed := {}
		for mesh_key: Variant in mesh_xfs:
			packed[mesh_key] = _pack_xforms_12(mesh_xfs[mesh_key] as Array)
		for mesh_key: Variant in native_bufs:
			var parts: Array = native_bufs[mesh_key]
			var into: PackedFloat32Array = packed.get(mesh_key, PackedFloat32Array())
			for part: PackedFloat32Array in parts:
				into.append_array(part)
			packed[mesh_key] = into
		for mesh_key: Variant in basic_bufs:
			packed[mesh_key] = basic_bufs[mesh_key]
		_rest_3d_pending[c] = packed
		_rest_3d_counts[c] = [rig_arms, model_arms, basic_arms]
		_rest_3d_upload[c] = true
	return done


## (--rest-arms-index) What a resting arm's native inputs depend on besides its record (the same as
## _update_rest's "every chunk again"): the packs, the models read, the eprops, the grip's height and the switches.
func _rest_stamp() -> Array:
	return [ModelLibrary.ModelPacks.version, _model_ver(), eprops.size(), _grip_height(), rest_box_fallback,
		sprite_arms, held_grip, _sprite_version]


## (--rest-arms-index) One resting arm's native inputs `row` kept in the index and put in its batch.
func _rest_row(index: RestIndex, batches: Dictionary, unit: int, mode: int, model: String, proto_name: String, what: Variant,
		row: PackedFloat32Array) -> void:
	var nb := _rest_batch(batches, mode, model, proto_name, what)
	index.rows[unit] = [mode, model, proto_name, what, row, "%d:%s" % [mode, model]]
	var inp: PackedFloat32Array = nb[3]
	inp.append_array(row)
	nb[3] = inp


## (--rest-arms-index) The batch of one model's resting arms of one mode, made when missing.
static func _rest_batch(batches: Dictionary, mode: int, model: String, proto_name: String, what: Variant) -> Array:
	var key := "%d:%s" % [mode, model]
	var nb: Variant = batches.get(key)
	if nb == null:
		nb = [mode, proto_name, what, PackedFloat32Array()]
		batches[key] = nb
	return nb


static func _rest_mesh_buf(bufs: Dictionary, mesh: Mesh, part: PackedFloat32Array) -> void:
	if not bufs.has(mesh):
		bufs[mesh] = []
	(bufs[mesh] as Array).append(part)


func _rest_pick_vec(rec, proto: ProtoDB.EntityProto) -> Vector2:
	var x: Dictionary = (eprops.get(rec.proto_id, {}) as Dictionary).get("x", {})
	var pick := _vec(x["ip"]) if x.has("ip") else Vector2(0.0, -2.0 if ARM_FAMILIES.get(proto.name, "") == "long" else -1.0)
	return _turn(pick, rec.dir)


static func _rig_has_meshes(rig: Dictionary) -> bool:
	var meshes: Variant = rig.get("meshes")
	if not (meshes is Array):
		return false
	for m: Variant in (meshes as Array):
		if m is Mesh:
			return true
	return false


func _rest_rig_for(proto_name: String, pack: String):
	if pack == "":
		return _rig_for(proto_name)
	var model := proto_name + "@" + pack
	if _rest_pack_rigs.has(model):
		return _rest_pack_rigs[model]
	if proto_name == "" or not ModelLibrary.rig_name(proto_name):
		_rest_pack_rigs[model] = {}
		return _rest_pack_rigs[model]
	if not _model_ready(model):
		return null
	ModelLibrary.mesh_for(model)
	var rig := ModelLibrary.rig_for(model)
	_rest_pack_rigs[model] = rig
	return rig


func _rest_model_meshes_for(proto_name: String, pack: String) -> Array:
	if pack == "" and not ModelLibrary.rig_name(proto_name) and not ModelLibrary.ModelPacks._configured:
		return []
	if pack == "":
		var pieces: Variant = _pieces_for(proto_name)
		if pieces == null:
			return []
		var out: Array = []
		for mmi: Variant in (pieces as Array):
			out.append((mmi as MultiMeshInstance3D).multimesh.mesh)
		return out
	var model := proto_name + "@" + pack
	if _rest_pack_meshes.has(model):
		return _rest_pack_meshes[model]
	var meshes: Variant = _arm_meshes(proto_name, "@" + pack)
	if meshes == null:
		return []
	_rest_pack_meshes[model] = meshes
	return meshes as Array


static func _pack_xforms_12(xforms: Array) -> PackedFloat32Array:
	var buf := PackedFloat32Array()
	buf.resize(xforms.size() * 12)
	var o := 0
	for i in xforms.size():
		var t: Transform3D = xforms[i]
		var b := t.basis
		buf[o] = b.x.x
		buf[o + 1] = b.y.x
		buf[o + 2] = b.z.x
		buf[o + 3] = t.origin.x
		buf[o + 4] = b.x.y
		buf[o + 5] = b.y.y
		buf[o + 6] = b.z.y
		buf[o + 7] = t.origin.y
		buf[o + 8] = b.x.z
		buf[o + 9] = b.y.z
		buf[o + 10] = b.z.z
		buf[o + 11] = t.origin.z
		o += 12
	return buf


static func _rest_xf(buf: PackedFloat32Array, t: Transform3D) -> void:
	var b := t.basis
	buf.append_array([b.x.x, b.y.x, b.z.x, t.origin.x, b.x.y, b.y.y, b.z.y, t.origin.y, b.x.z, b.y.z, b.z.z, t.origin.z])


## (rest arms) One inserter's arm at rest into `buf`: from its shoulder (a rig's, or the base's top) through the
## elbow the IK gives to its grip over the pickup point (eprops `ip`, turned by its direction).
func _rest_arm(buf: PackedFloat32Array, rec, proto: ProtoDB.EntityProto, rig: Dictionary) -> void:
	var pick := _rest_pick_vec(rec, proto)
	var turn := Basis(Vector3.UP, -pick.angle())
	var out := turn * Vector3.RIGHT
	var grip_at := Vector3(rec.pos.x, _grip_height(), rec.pos.y) + out * pick.length()
	var shoulder: Vector3
	var upper: float
	var fore: float
	if not rig.is_empty():
		var placed := ModelLibrary.placed(proto.name, proto.type, rec.dir, rec.extra, Vector3(rec.pos.x, 0.0, rec.pos.y))
		shoulder = placed * (rig["shoulder"] as Vector3)
		upper = float(rig["lengths"][0])
		fore = float(rig["lengths"][1])
	else:
		var lengths: Array = ARM_LENGTHS[ARM_FAMILIES.get(proto.name, "basic")]
		shoulder = Vector3(rec.pos.x, MODEL_SHOULDER, rec.pos.y)
		upper = float(lengths[0]) * float(lengths[2])
		fore = float(lengths[1]) * float(lengths[2]) * float(_claw.get(proto.name, CLAW_DEFAULT))
	var elbow := _elbow(shoulder, grip_at, out, upper, fore)
	var tints: Array = ARM_TINTS.get(proto.name, [proto.color.darkened(0.2), proto.color])
	_rest_box(buf, _segment(shoulder, elbow, turn, REST_UPPER), tints[0])
	_rest_box(buf, _segment(elbow, grip_at, turn, REST_FORE), tints[1])
	_rest_box(buf, Transform3D(turn * Basis.from_scale(REST_HAND), grip_at + Vector3(0.0, REST_HAND.y * 0.5, 0.0)), tints[1])


static func _rest_box(buf: PackedFloat32Array, t: Transform3D, c: Color) -> void:
	var b := t.basis
	var lin := c.srgb_to_linear()
	buf.append_array([b.x.x, b.y.x, b.z.x, t.origin.x, b.x.y, b.y.y, b.z.y, t.origin.y, b.x.z, b.y.z, b.z.z, t.origin.z,
		lin.r, lin.g, lin.b, 1.0])


## (rest_basic_live) Whether the live placeholder arm's part MultiMeshes (_parts, made in _ready) are there to share
## their meshes; their meshes noted (Mesh -> Part) for the 3D flush.
func _rest_basic_ready() -> bool:
	if _parts.size() != Part.size():
		return false
	if _rest_basic_meshes.size() != Part.size():
		_rest_basic_meshes.clear()
		for p in Part.size():
			_rest_basic_meshes[(_parts[p] as MultiMeshInstance3D).multimesh.mesh] = p
	return true


## (rest_basic_live) One resting arm with no arm model drawn as its live arm is (_draw_arm, Mode.BASIC) at its pickup,
## the hand empty: each part's transform and colour (_part_color of the prototype's colour, as _fill_xforms_colored
## writes them) added to `bufs` under the live part's mesh.
func _rest_basic_arm(bufs: Dictionary, rec, proto: ProtoDB.EntityProto) -> void:
	var pick := _rest_pick_vec(rec, proto)
	_rest_scratch_arm.proto_name = proto.name
	_rest_scratch_arm.base = rec.pos
	_rest_scratch_arm.dir = rec.dir
	_rest_scratch_arm.angle = pick.angle()
	_rest_scratch_arm.reach = pick.length()
	_rest_scratch_arm.close = 0.0
	_rest_scratch_arm.item_id = 0
	for p in Part.size():
		(_rest_basic_lists[p] as Array).clear()
	_draw_arm(_rest_scratch_arm, _rest_basic_lists)
	for p in Part.size():
		var mesh := (_parts[p] as MultiMeshInstance3D).multimesh.mesh
		var c := _part_color(p, proto.color)
		var into: PackedFloat32Array = bufs.get(mesh, PackedFloat32Array())
		for t: Transform3D in (_rest_basic_lists[p] as Array):
			var b := t.basis
			into.append_array([b.x.x, b.y.x, b.z.x, t.origin.x, b.x.y, b.y.y, b.z.y, t.origin.y, b.x.z, b.y.z, b.z.z,
				t.origin.z, c.r, c.g, c.b, c.a])
		bufs[mesh] = into


## (handoff) The simulation's takes and puts (belt_items.gd take_hands: [why, inserter, tick, uid, x, z]):
## each taken or put item a meeting for its inserter's hand.
func _take_meets(list: Array) -> void:
	for h: Array in list:
		var why := int(h[0])
		if why != BeltSimConst.HAND_TAKEN and why != BeltSimConst.HAND_PUT:
			continue
		var arm: Arm = _arms.get(int(h[1]))
		if arm == null or is_nan(float(h[4])):
			continue
		var m := [float(h[2]), int(h[3]), float(h[4]), float(h[5]), why == BeltSimConst.HAND_TAKEN]
		var i := arm.meets.size()
		while i > 0 and float(arm.meets[i - 1][0]) > m[0]:
			i -= 1
		arm.meets.insert(i, m)
		_meet_arms[arm] = true
		while arm.meets.size() > 8:
			arm.meets.pop_front()
		if trace_meets and _trace != null:
			_trace.store_line('{"meet":[%d,%d,%d,%.3f,%.3f,%d]}' % [int(h[1]), int(h[2]), int(h[3]), float(h[4]), float(h[5]), why])


## (handoff) The hand at `t` steered onto the item it meets within STEER_IN ticks (its drawn place while
## it is on the belt, else where the simulation had it then), and eased back over STEER_OUT ticks after.
func _steer(arm: Arm, t: float) -> void:
	while not arm.meets.is_empty() and float(arm.meets[0][0]) < t - STEER_OUT - 60.0:
		arm.meets.pop_front()
	var best: Array = []
	var w := 0.0
	for m: Array in arm.meets:
		var mt: float = m[0]
		var wm := 0.0
		if t <= mt and t >= mt - STEER_IN:
			wm = 1.0 - (mt - t) / STEER_IN
		elif t > mt and t < mt + STEER_OUT:
			wm = 1.0 - (t - mt) / STEER_OUT
		if wm > w:
			w = wm
			best = m
	if best.is_empty() or w <= 0.0:
		return
	var target := Vector2(best[2], best[3])
	if bool(best[4]) and t < float(best[0]) and int(best[1]) != 0 and belts.has_method("position_of"):
		# (Still on the belt: where it is drawn now.)
		var at = belts.position_of(int(best[1]))
		if at is Vector3:
			target = Vector2((at as Vector3).x, (at as Vector3).z)
	w = w * w * (3.0 - 2.0 * w)
	var hand := Swing.hand_pos(arm.angle, arm.reach).lerp(target - arm.base, w)
	arm.angle = hand.angle()
	arm.reach = hand.length()
	steered += 1


## (--inserter-arms-trace) This frame: {"f": frame, "ms": wall msec, "T": the game tick the arms stand
## for (belt clock: the drawn tick; wall clock: where the update interpolation is between the last two
## updates' ticks), "B": the belts' drawn tick or -1, "us": the arms' cost this frame, "a": [unit, hand
## x, hand y (tiles), held item, ...]}.
func _write_trace(usec: int, t: float) -> void:
	var stands: float
	if belt_clock:
		stands = _drawn
	else:
		stands = lerpf(float(_prev_frame_tick), float(_frame_tick), t) if _frame_tick >= 0 else -1.0
	var belt_tick: float = belts.drawn_tick() if belts != null and belts.has_method("drawn_tick") else -1.0
	var parts := PackedStringArray()
	for unit in _arms:
		var arm: Arm = _arms[unit]
		var hand := arm.base + Swing.hand_pos(arm.angle, arm.reach)
		parts.append("%d,%.3f,%.3f,%d" % [unit, hand.x, hand.y, arm.item_id])
	_trace.store_line('{"f":%d,"ms":%d,"T":%.2f,"B":%.2f,"us":%d,"a":[%s]}' % [
		_frames, Time.get_ticks_msec(), stands, belt_tick, usec, ",".join(parts)])


var _rigs_packs := -1


## The arm rig of an inserter prototype's model with its MultiMeshes, made once its model is read;
## {} when the model has none (Wube's pieces then), null while the model is still being read.
func _rig_for(proto_name: String):
	if _rigs_packs < 0:
		_rigs_packs = ModelLibrary.ModelPacks.version
	elif _rigs_packs != ModelLibrary.ModelPacks.version:
		_rigs_packs = ModelLibrary.ModelPacks.version
		_scratch_rig_lists.clear()
		for rig_entry: Variant in _rigs.values():
			if rig_entry is Dictionary:
				for mmi: Variant in (rig_entry as Dictionary).get("mmis", []):
					if mmi is Node and is_instance_valid(mmi):
						(mmi as Node).queue_free()
		_rigs.clear()
		_watch.clear()  # (the names asked again by the lookups made anew)
	if _rigs.has(proto_name):
		return _rigs[proto_name]
	if proto_name == "" or not ModelLibrary.rig_name(proto_name):
		_rigs[proto_name] = {}
		return _rigs[proto_name]
	if not _model_ready(proto_name):
		return null
	ModelLibrary.mesh_for(proto_name)
	var rig := ModelLibrary.rig_for(proto_name)
	if rig.is_empty():
		_rigs[proto_name] = {}
		return _rigs[proto_name]
	var entry := rig.duplicate()
	var mmis: Array = []
	var meshes: Array = rig["meshes"]
	for p in ModelRig.Part.size():
		if meshes[p] == null:
			mmis.append(null)
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = meshes[p]
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.name = "%s_rig_%d" % [proto_name, p]
		add_child(mmi)
		mmis.append(mmi)
	entry["mmis"] = mmis
	_rigs[proto_name] = entry
	return entry


## (--inserter-grip) Set by the arm drawn last: its grip, where a held item's middle goes (a rig's between its
## pincers, Wube's claw's middle), when it has one.
var _gripped := false
var _grip_at := Vector3.ZERO
## (--inserter-grip) Prototype -> how far along Wube's hand piece its claw's middle is, in hand lengths (the
## wrist at 1; the claw reaches on past it), from the closed hand's model.
var _claw := {}


## The grip's height: GRIP_HEIGHT, or with --inserter-grip GRIP_ABOVE_BELT over the belt items drawn when
## that is higher.
func _grip_height() -> float:
	if not held_grip or belts == null or not belts.has_method("item_height"):
		return GRIP_HEIGHT
	return maxf(GRIP_HEIGHT, float(belts.item_height()) + GRIP_ABOVE_BELT)


## Where a held item's base goes (ItemCards.draw adds the kind's lift): its middle in the grip of the arm just
## drawn (--inserter-grip), else ITEM_DROP below its wrist, as before.
func held_at(arm: Arm, wrist: Vector3) -> Vector3:
	if _gripped:
		var key := arm.held_key if ItemCards.item_of(arm.held_key) == arm.item_id else arm.item_id
		_cards.prepare(key)  # (its look known, its height with it, from its first frame)
		return _grip_at - Vector3(0.0, _cards.pile_step(key) * 0.5, 0.0)
	return wrist - Vector3(0.0, ITEM_DROP, 0.0)


## Adds one arm's rig part transforms to `lists` (indexed by ModelRig.Part); returns where the held
## item hangs from (as the other arms' wrists). Each part's mesh is relative to its joint in the rest
## pose, so a part is drawn turned from its rest direction to where the IK puts it, about its joint.
func _draw_rig_arm(arm: Arm, rig: Dictionary, lists: Array) -> Vector3:
	var turn := Basis(Vector3.UP, -arm.angle)
	var out := turn * Vector3.RIGHT
	var across := turn * Vector3.BACK
	var hinge: Vector3 = rig["hinge"]
	var pivot_rest: Vector3 = rig["pivot"]
	var shoulder_rest: Vector3 = rig["shoulder"]
	var elbow_rest: Vector3 = rig["elbow"]
	var grip_rest: Vector3 = rig["grip"]
	var lengths: Array = rig["lengths"]
	var heads: Array = rig["heads"]
	# The turntable yaws about its joint, where the base model has it, to face the hand.
	var table := aim(Vector3.UP, hinge, Vector3.UP, across)
	var pivot := arm.placed * pivot_rest
	var shoulder := pivot + table * (shoulder_rest - pivot_rest)
	var grip := Vector3(arm.base.x, _grip_height(), arm.base.y) + out * arm.reach
	var upper: float = lengths[0]
	var fore: float = lengths[1]
	var stretch := 1.0
	var need := shoulder.distance_to(grip)
	if need > (upper + fore) * RIG_REACH:
		stretch = need / ((upper + fore) * RIG_REACH)
		if not _stretched.has(arm.proto_name):
			_stretched[arm.proto_name] = true
			print("[inserters] %s: the model's arm (%.3f) is shorter than the hand's reach (%.3f): stretched to reach" % [
				arm.proto_name, upper + fore, need])
	var elbow := _elbow(shoulder, grip, out, upper * stretch, fore * stretch)
	var lower_dir := elbow_rest - shoulder_rest
	var upper_dir := grip_rest - elbow_rest
	var lower_turn := aim(lower_dir, hinge, elbow - shoulder, across) * along(lower_dir, stretch)
	var upper_turn := aim(upper_dir, hinge, grip - elbow, across) * along(upper_dir, stretch)
	if heads[ModelRig.Part.TURNTABLE] != null:
		lists[ModelRig.Part.TURNTABLE].append(Transform3D(table, pivot))
	lists[ModelRig.Part.LOWER].append(Transform3D(lower_turn, shoulder))
	lists[ModelRig.Part.UPPER].append(Transform3D(upper_turn, elbow))
	var axes: Array = rig["axes"]
	# (--inserter-grip) Closed onto the held item's sides, not till they meet through it.
	var angles: Array = rig.get("grip_angles", rig["angles"]) if held_grip else rig["angles"]
	for p in [ModelRig.Part.PINCER_A, ModelRig.Part.PINCER_B]:
		if heads[p] == null or angles[p] == null:
			continue
		var head: Vector3 = heads[p]
		var shut := Basis(axes[p] as Vector3, float(angles[p]) * arm.close)
		lists[p].append(Transform3D(upper_turn * shut, elbow + upper_turn * (head - elbow_rest)))
	_gripped = held_grip
	_grip_at = grip
	return grip + Vector3(0.0, ITEM_DROP, 0.0)


## The turn taking a part whose bone points along `rest_dir`, bending about `rest_hinge`, to point
## along `dir` bending about `hinge` (both frames: bone, hinge made square to it, and their cross).
static func aim(rest_dir: Vector3, rest_hinge: Vector3, dir: Vector3, hinge: Vector3) -> Basis:
	return _frame(dir, hinge) * _frame(rest_dir, rest_hinge).inverse()


static func _frame(dir: Vector3, hinge: Vector3) -> Basis:
	var y := dir.normalized()
	var z := (hinge - y * hinge.dot(y)).normalized()
	return Basis(y.cross(z), y, z)


## A stretch by `s` along `dir` (and none across it).
static func along(dir: Vector3, s: float) -> Basis:
	if is_equal_approx(s, 1.0):
		return Basis.IDENTITY
	var d := dir.normalized()
	var k := s - 1.0
	return Basis(Vector3.RIGHT + d * (d.x * k), Vector3.UP + d * (d.y * k), Vector3.BACK + d * (d.z * k))


## (sprite arms) Each prototype's pictures, read once: proto name -> {"meshes": [a unit QuadMesh per SpritePiece
## wearing its picture], "widths": [tiles], "files": [the files]}, or {} when one isn't found (the 3D arm then).
static var _sprite_pictures := {}
## (sprite arms) Whether model name draws its arm as pictures, under ModelPacks.version _sprite_version; and the
## MultiMeshes per model name (live arms, resting arms), [MultiMeshInstance3D per SpritePiece].
var _sprite_known := {}
var _sprite_version := -1
var _sprite_mmis := {}
var _sprite_rest_mmis := {}


## (sprite arms) The pictures an inserter model (`name`, `name@pack`) draws its arm with: those of its prototype
## when the Factorio pack draws it (ModelLibrary.draws_sprite) and they are found, else {} (the 3D arm).
func _sprite_set_for(name: String) -> Dictionary:
	if _sprite_version != ModelLibrary.ModelPacks.version:
		_sprite_version = ModelLibrary.ModelPacks.version
		_sprite_known.clear()
		_scratch_sprite_lists.clear()
		for list: Dictionary in [_sprite_mmis, _sprite_rest_mmis]:
			for mmis: Array in list.values():
				for mmi in mmis:
					(mmi as Node).queue_free()
			list.clear()
		if world != null:
			for c in world.chunks:
				_rest_dirty[c] = true
	var got = _sprite_known.get(name)
	if got == null:
		got = sprite_set(name)
		_sprite_known[name] = got
		if not (got as Dictionary).is_empty():
			_sprite_mmis[name] = _sprite_instances(name, got, "")
	return got


## (sprite arms, the model preview too) An inserter model's arm pictures (see _sprite_set_for), {} when it isn't
## drawn by the Factorio pack or they can't be read.
## `force` (the preview's, for a name of the Factorio pack's own): whether or not that pack is in use.
static func sprite_set(name: String, force := false) -> Dictionary:
	if not sprite_arms or name == "" or not (ModelLibrary.draws_sprite(name) or force):
		return {}
	var proto := ModelLibrary.file_of(name)
	if not _sprite_pictures.has(proto):
		_sprite_pictures[proto] = _read_sprite_pictures(proto)
	return _sprite_pictures[proto]


static func _read_sprite_pictures(proto: String) -> Dictionary:
	var meshes: Array = []
	var widths: Array = []
	var files: Array = []
	for piece: String in SPRITE_FILES:
		var image: Image = null
		var file := ""
		for mod: String in SPRITE_MODS:
			file = "__%s__/graphics/entity/%s/%s-hand-%s.png" % [mod, proto, proto, piece]
			image = ModFiles.load_image(file)
			if image != null:
				break
		if image == null:
			return {}
		image.convert(Image.FORMAT_RGBA8)
		image.fix_alpha_edges()
		image.generate_mipmaps()
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE
		var mat := ShaderMaterial.new()
		mat.shader = SpriteStandins.CARD_SHADER  # cut out, both sides, on the hills: the platform's
		mat.set_shader_parameter("picture", ImageTexture.create_from_image(image))
		quad.material = mat
		meshes.append(quad)
		widths.append(image.get_width() * SPRITE_SCALE / 32.0)
		files.append(file)
	return {"meshes": meshes, "widths": widths, "files": files}


func _sprite_instances(name: String, pictures: Dictionary, tag: String) -> Array:
	var out: Array = []
	for p in SpritePiece.size():
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = pictures["meshes"][p]
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.name = "%s_sprite%s_%s" % [name.replace("@", "_").replace(":", "_"), tag, SPRITE_FILES[p]]
		add_child(mmi)
		out.append(mmi)
	return out


## (sprite arms) The platform card's lift towards the camera (sprite_standins.gd _card_mesh), NAN until made.
static func _platform_lift(proto: String, dir: int, force := false) -> float:
	var card := SpriteStandins.card(proto, dir, Vector2.ONE, "inserter", force)
	return (card as QuadMesh).center_offset.z if card is QuadMesh else NAN


## (sprite arms) Adds one arm's cards to `lists` (by SpritePiece); returns where the held item hangs from (its
## grip is set, as Wube's arm's: the item's middle there).
func _draw_sprite_arm(arm: Arm, pictures: Dictionary, lists: Array) -> Vector3:
	if is_nan(arm.card_lift):
		arm.card_lift = _platform_lift(arm.proto_name, arm.dir)
	var out := Basis(Vector3.UP, -arm.angle) * Vector3.RIGHT
	var grip := Vector3(arm.base.x, _grip_height(), arm.base.y) + out * arm.reach
	var hand: int = SpritePiece.CLOSED if arm.item_id > 0 else SpritePiece.OPEN
	var xf := sprite_cards(arm.proto_name, pictures, arm.base, grip, 0.0 if is_nan(arm.card_lift) else arm.card_lift, hand)
	lists[SpritePiece.BASE].append(xf[0])
	lists[hand].append(xf[1])
	arm.sprite_xf = [xf[0], xf[1], hand]
	_gripped = true
	_grip_at = grip
	return grip + Vector3(0.0, ITEM_DROP, 0.0)


## (sprite arms) Factorio's two pictures for an arm on the inserter at `base` (tiles) with its grip at `grip`:
## [the base piece's Transform3D, the hand's] for unit quads, from the 3D arm's shoulder through its IK elbow to
## the grip (the claw's picture HAND_TIP on past it), projected along Factorio's camera onto the platform card's
## plane, each piece the picture's width across and in front of the card by `lift` and SPRITE_DEPTH /
## SPRITE_HAND_DEPTH (more where a piece would reach under the ground). Its picture's top at the far end.
static func sprite_cards(proto: String, pictures: Dictionary, base: Vector2, grip: Vector3, lift: float, hand: int = SpritePiece.OPEN) -> Array:
	var lengths: Array = ARM_LENGTHS[ARM_FAMILIES.get(proto, "basic")]
	var shoulder := Vector3(base.x, MODEL_SHOULDER, base.y)
	var flat := grip - shoulder
	var out := Vector3(flat.x, 0.0, flat.z).normalized() if Vector2(flat.x, flat.z).length() > 0.001 else Vector3.RIGHT
	var elbow := _elbow(shoulder, grip, out, float(lengths[0]) * float(lengths[2]), float(lengths[1]) * float(lengths[2]) * CLAW_DEFAULT)
	var pitch := deg_to_rad(SpriteStandins.FACTORIO_PITCH)
	var up := Vector3(0.0, cos(pitch), -sin(pitch))
	var facing := Vector3(0.0, sin(pitch), cos(pitch))
	var centre := Vector3(base.x, 0.0, base.y)
	var s := _on_card(shoulder, centre, up)
	var e := _on_card(elbow, centre, up)
	var g := _on_card(grip, centre, up)
	var tip := g + (g - e) * (HAND_TIP / (1.0 - HAND_TIP))
	var widths: Array = pictures["widths"]
	# (Both pieces kept above the ground: the lowest corner, along the facing, which lifts as it comes forward.)
	var low := INF
	for piece: Array in [[s, e, float(widths[SpritePiece.BASE])], [e, tip, float(widths[hand])]]:
		var across: Vector3 = _across(piece[1] - piece[0], facing) * (float(piece[2]) * 0.5)
		for end: Vector3 in [piece[0], piece[1]]:
			low = minf(low, minf((end + across).y, (end - across).y))
	var d := maxf(lift, (0.02 - low) / sin(pitch))
	return [_card_xf(s, e, float(widths[SpritePiece.BASE]), facing, d + SPRITE_DEPTH),
		_card_xf(e, tip, float(widths[hand]), facing, d + SPRITE_HAND_DEPTH)]


## A point moved along Factorio's camera onto the card plane through `centre` (the entity's middle on the ground).
static func _on_card(p: Vector3, centre: Vector3, up: Vector3) -> Vector3:
	var d := p - centre
	return centre + Vector3(d.x, 0.0, 0.0) + up * d.dot(up)


static func _across(along: Vector3, facing: Vector3) -> Vector3:
	var a := along.cross(facing)
	return a.normalized() if a.length() > 1e-5 else Vector3.RIGHT


## A unit quad from `a` (its picture's bottom) to `b` (its top), `width` across, facing the camera, `depth` in
## front of the plane.
static func _card_xf(a: Vector3, b: Vector3, width: float, facing: Vector3, depth: float) -> Transform3D:
	var along := b - a
	if along.length() < 0.01:
		along = Vector3(0.0, 0.01, 0.0)
	return Transform3D(Basis(_across(along, facing) * width, along, facing), (a + b) * 0.5 + facing * depth)


## (The model preview, M7) Inserter model `name` (`name@builtin:factorio`, or one the Factorio pack wins for)'s
## arm as Factorio's pictures with its hand at `hand` (tiles from its middle, facing north: x east, y south),
## `holding` an item: posed_pieces' form ({"pieces": [[QuadMesh, Transform3D], ...], "grip", "gripped", "wrist",
## "turn"}, "cards": true), in the entity's space (its middle on the ground at the origin, as
## SpriteStandins.picture's card drawn with transform(Vector2.ZERO)); {} when it isn't drawn that way. `dir`
## (16-way) is the platform's picture it stands in front of (the hand is where it is, already turned).
static func sprite_arm_pose(name: String, hand: Vector2, holding: bool, dir := 0) -> Dictionary:
	# (Shown from the Factorio pack in the preview whether or not that pack is in use.)
	var pictures := sprite_set(name, name.ends_with("@" + ModelLibrary.ModelPacks.FACTORIO_ID))
	if pictures.is_empty():
		return {}
	var proto := ModelLibrary.file_of(name)
	var lift := _platform_lift(proto, dir, true)
	var grip := Vector3(hand.x, GRIP_HEIGHT, hand.y)
	var piece: int = SpritePiece.CLOSED if holding else SpritePiece.OPEN
	var xf := sprite_cards(proto, pictures, Vector2.ZERO, grip, 0.0 if is_nan(lift) else lift, piece)
	return {"pieces": [[pictures["meshes"][SpritePiece.BASE], xf[0]], [pictures["meshes"][piece], xf[1]]], "grip": grip,
		"gripped": true, "wrist": grip + Vector3(0.0, ITEM_DROP, 0.0), "turn": Basis(Vector3.UP, -hand.angle()), "cards": true}


## Fills a MultiMesh with `xforms`, growing it as needed.
static func _fill(mm: MultiMesh, xforms: Array) -> void:
	if mm.instance_count < xforms.size():
		mm.instance_count = maxi(xforms.size(), mm.instance_count * 2)
	mm.visible_instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])


## Fills a MultiMesh with `xforms`, using fast bulk buffer upload or per-instance fallback.
func _fill_xforms(mm: MultiMesh, xforms: Array) -> void:
	if mm.instance_count < xforms.size():
		mm.instance_count = maxi(xforms.size(), maxi(mm.instance_count * 2, 16))
	mm.visible_instance_count = xforms.size()
	if xforms.is_empty():
		return
	if not fast_upload:
		for i in xforms.size():
			mm.set_instance_transform(i, xforms[i] as Transform3D)
		return
	var rid := mm.get_rid()
	var needed := mm.instance_count * 12
	var buf: PackedFloat32Array = _upload_bufs.get(rid, PackedFloat32Array())
	if buf.size() != needed:
		buf.resize(needed)
	var o := 0
	for i in xforms.size():
		var t: Transform3D = xforms[i]
		var b := t.basis
		buf[o] = b.x.x
		buf[o + 1] = b.y.x
		buf[o + 2] = b.z.x
		buf[o + 3] = t.origin.x
		buf[o + 4] = b.x.y
		buf[o + 5] = b.y.y
		buf[o + 6] = b.z.y
		buf[o + 7] = t.origin.y
		buf[o + 8] = b.x.z
		buf[o + 9] = b.y.z
		buf[o + 10] = b.z.z
		buf[o + 11] = t.origin.z
		o += 12
	_upload_bufs[rid] = buf
	RenderingServer.multimesh_set_buffer(rid, buf)


## Fills a MultiMesh with `xforms` and `colors` (stride 16), using fast bulk buffer upload or fallback.
func _fill_xforms_colored(mm: MultiMesh, xforms: Array, colors: Array[Color], per_arm: int, part: int = -1) -> void:
	if mm.instance_count < xforms.size():
		mm.instance_count = maxi(xforms.size(), maxi(mm.instance_count * 2, 16))
	mm.visible_instance_count = xforms.size()
	if xforms.is_empty():
		return
	if not fast_upload:
		for i in xforms.size():
			var arm_col: Color = colors[i if per_arm == 1 else i >> 1]
			var c: Color = _part_color(part, arm_col) if part >= 0 else arm_col
			mm.set_instance_transform(i, xforms[i] as Transform3D)
			mm.set_instance_color(i, c)
		return
	var rid := mm.get_rid()
	var needed := mm.instance_count * 16
	var buf: PackedFloat32Array = _upload_bufs.get(rid, PackedFloat32Array())
	if buf.size() != needed:
		buf.resize(needed)
	var o := 0
	for i in xforms.size():
		var t: Transform3D = xforms[i]
		var b := t.basis
		var arm_col: Color = colors[i if per_arm == 1 else i >> 1]
		var c: Color = _part_color(part, arm_col) if part >= 0 else arm_col
		buf[o] = b.x.x
		buf[o + 1] = b.y.x
		buf[o + 2] = b.z.x
		buf[o + 3] = t.origin.x
		buf[o + 4] = b.x.y
		buf[o + 5] = b.y.y
		buf[o + 6] = b.z.y
		buf[o + 7] = t.origin.y
		buf[o + 8] = b.x.z
		buf[o + 9] = b.y.z
		buf[o + 10] = b.z.z
		buf[o + 11] = t.origin.z
		buf[o + 12] = c.r
		buf[o + 13] = c.g
		buf[o + 14] = c.b
		buf[o + 15] = c.a
		o += 16
	_upload_bufs[rid] = buf
	RenderingServer.multimesh_set_buffer(rid, buf)


## The arm pieces of an inserter prototype, made on first use; null without the models.
func _pieces_for(proto_name: String):
	# A pack chosen for an inserter's family (the Model packs window, the building's Model button)
	# takes its arm too (ModelPacks.PREFIX_FAMILIES): the pieces are made again from the new models.
	if _parts_packs != ModelLibrary.ModelPacks.version:
		_parts_packs = ModelLibrary.ModelPacks.version
		_scratch_model_lists.clear()
		for pieces in _model_parts.values():
			if pieces != null:
				for mmi in pieces:
					(mmi as Node).queue_free()
		_model_parts.clear()
	if _model_parts.has(proto_name):
		return _model_parts[proto_name]
	var meshes = _arm_meshes(proto_name)
	if meshes == null:
		return null
	var out := []
	for i in (meshes as Array).size():
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = meshes[i]
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.name = "%s_%s" % [proto_name, ARM_PIECE_NAMES[i]]
		add_child(mmi)
		out.append(mmi)
	_model_parts[proto_name] = out if not out.is_empty() else null
	return _model_parts[proto_name]


const ARM_PIECE_NAMES := ["upper", "hand-open", "hand-closed"]


## Wube's arm pieces for an inserter prototype, [upper, hand open, hand closed] (ArmPiece) in its paint, the
## models named with `pack` ("@pack", the model preview's; "" the world's, the packs' order); sets its claw's
## length. Null while one is still being read (on a worker), [] without them.
func _arm_meshes(proto_name: String, pack := ""):
	var family: String = ARM_FAMILIES.get(proto_name, "basic")
	# Made on worker threads (reading one here cost 2-4 ms a piece): the plain arm stands in until then.
	# Every piece is asked for before waiting, so the three are read side by side, not one after another.
	var waiting := false
	for piece: String in ARM_PIECE_NAMES:
		if not _model_ready("inserter-arm-%s-%s%s" % [family, piece, pack]):
			waiting = true
	if waiting:
		return null
	var out := []
	for piece: String in ARM_PIECE_NAMES:
		var mesh := ModelLibrary.mesh_for("inserter-arm-%s-%s%s" % [family, piece, pack])
		if not (mesh is ArrayMesh):
			return []
		if piece == "hand-closed":
			# (The piece points north from the elbow, the wrist at its modelled length; the claw beyond.)
			var hand_length: float = (ARM_LENGTHS[family] as Array)[1]
			_claw[proto_name] = maxf(1.0, (hand_length - mesh.get_aabb().position.z) * 0.5 / hand_length)
		if ARM_TINTS.has(proto_name):
			mesh = ModelLibrary._tinted(mesh as ArrayMesh, ARM_TINTS[proto_name][0 if piece == "upper" else 1])
			# The arm pieces are thin: nearly every face is a bevel or rim to the weathering, which
			# chipped them all to bare steel. The sprites' arms are painted with a little wear.
			ModelLibrary.set_named(mesh as ArrayMesh, ModelLibrary.TIER_MATERIAL, "edge_wear", ARM_EDGE_WEAR)
		out.append(mesh)
	return out


## (The model preview, M7 and M8) An inserter's pickup and drop points (facing north, tiles from its middle)
## and hand speeds: from its prototype's eprops overlay `x` when a game has sent them, else Factorio 2.1's base
## values (pickup_position {0, -1}, insert_position {0, 1.2}; long-handed {0, -2}, {0, 2.2}; Swing.SPEEDS).
## {"pick", "drop": Vector2, "omega": turns a tick, "v": tiles a tick}.
static func cycle_of(proto_name: String, x := {}) -> Dictionary:
	var long: bool = ARM_FAMILIES.get(proto_name, "") == "long"
	var pick := _vec(x["ip"]) if x.has("ip") else Vector2(0.0, -2.0 if long else -1.0)
	var drop := _vec(x["id"]) if x.has("id") else Vector2(0.0, 2.2 if long else 1.2)
	var speeds := Swing.speeds(x, proto_name, "normal")
	return {"pick": pick, "drop": drop, "omega": speeds[0], "v": speeds[1]}


## (The model preview) Inserter model `name` (`name@pack`)'s arm as the world draws an idle one: the resting
## arm's pose (_rest_arm: the hand open over the pickup, at the grip's height). [[mesh, Transform3D in the base
## model's space], ...]; [] for a model that isn't an inserter, null while its models are read.
static func resting_pieces(name: String):
	var arms = new_posing()
	var posed = arms.posed_pieces(name, cycle_of(ModelLibrary.file_of(name))["pick"], 0.0, false)
	_free_scratch(arms)
	return posed if posed == null else (posed as Dictionary).get("pieces", [])


## A scratch instance for posed_pieces (never in the tree), kept while a preview plays; _free_scratch frees it.
static func new_posing():
	return (load("res://scripts/world/inserter_arms.gd") as GDScript).new()


## (The model preview) Inserter model `name`'s arm drawn as the world draws a live one (the same _draw_* calls),
## its hand at `hand` (tiles from its middle, facing north: x east, y south), its pincers `close` (0 open, 1
## closed: ease_close) and `holding` an item (Wube's pieces: the closed hand). {"pieces": [[mesh, Transform3D in
## the base model's space], ...], "grip": where a held item's middle goes, "gripped": whether it has a grip
## (else the item hangs ITEM_DROP under "wrist"), both in model space, "turn": a held item's turn there}; {} for a
## model that isn't an inserter,
## null while its models are read. `dir`: a picture arm's platform's direction (sprite_arm_pose).
func posed_pieces(name: String, hand: Vector2, close: float, holding: bool, dir := 0):
	var proto_name := ModelLibrary.file_of(name)
	if not ModelLibrary.rig_name(proto_name) or proto_name.begins_with("inserter-arm-"):
		return {}
	var cards := sprite_arm_pose(name, hand, holding, dir)
	if not cards.is_empty():
		return cards  # (the Factorio pack's: its pictures, in the entity's space)
	if not ModelLibrary.ready(name):
		return null
	ModelLibrary.mesh_for(name)  # (its rig made with it)
	var arm := Arm.new()
	arm.proto_name = proto_name
	arm.angle = hand.angle()
	arm.reach = hand.length()
	arm.close = close
	arm.item_id = 1 if holding else 0
	arm.placed = ModelLibrary.placed(proto_name, "inserter", 0, {}, Vector3.ZERO)
	var to_model := arm.placed.affine_inverse()
	var out := []
	var wrist: Vector3
	_gripped = false
	var rig := ModelLibrary.rig_for(name)
	if not rig.is_empty():
		var lists := [[], [], [], [], []]
		wrist = _draw_rig_arm(arm, rig, lists)
		for p in lists.size():
			for t: Transform3D in lists[p]:
				out.append([rig["meshes"][p], to_model * t])
		return {"pieces": out, "grip": to_model * _grip_at, "gripped": _gripped, "wrist": to_model * wrist,
			"turn": to_model.basis * Basis(Vector3.UP, -arm.angle)}
	var at := name.find("@")
	var meshes = _posed_meshes.get(name)  # (made once: _arm_meshes tints a new copy each time)
	if meshes == null:
		meshes = _arm_meshes(proto_name, "" if at < 0 else name.substr(at))
	if meshes == null:
		return null
	_posed_meshes[name] = meshes
	if not (meshes as Array).is_empty():
		var lists := [[], [], []]
		wrist = _draw_model_arm(arm, lists)
		for p in lists.size():
			for t: Transform3D in lists[p]:
				out.append([meshes[p], to_model * t])
	else:
		var proto_color: Color = (ARM_TINTS[proto_name][1] as Color) if ARM_TINTS.has(proto_name) else Color.GOLDENROD
		arm.color = proto_color
		var lists := []
		for p in Part.size():
			lists.append([])
		wrist = _draw_arm(arm, lists)
		for p in lists.size():
			var mesh: PrimitiveMesh = _box_meshes.get(p)
			if mesh == null:
				mesh = CylinderMesh.new() if p == Part.TURNTABLE or p == Part.SHOULDER else BoxMesh.new()
				if mesh is CylinderMesh:
					(mesh as CylinderMesh).top_radius = 0.5
					(mesh as CylinderMesh).bottom_radius = 0.5
					(mesh as CylinderMesh).height = 1.0
				else:
					(mesh as BoxMesh).size = Vector3.ONE
				var material := StandardMaterial3D.new()
				material.albedo_color = _part_color(p, proto_color)
				mesh.material = material
				_box_meshes[p] = mesh
			for t: Transform3D in lists[p]:
				out.append([mesh, to_model * t])
	return {"pieces": out, "grip": to_model * _grip_at, "gripped": _gripped, "wrist": to_model * wrist,
			"turn": to_model.basis * Basis(Vector3.UP, -arm.angle)}


var _box_meshes := {}  # (posed_pieces) the plain arm's part meshes, made once per scratch instance
var _posed_meshes := {}  # (posed_pieces) model name -> its Wube pieces, made once per scratch instance


## Frees an instance made only to work out a pose (resting_pieces, the tests): never in the tree, so its
## held items' node was never its child.
static func _free_scratch(arms) -> void:
	if arms._cards.get_parent() == null:
		arms._cards.free()
	arms.free()


## Adds one arm's piece transforms (Wube's models) to `lists` (indexed by ArmPiece); returns
## the wrist position.
func _draw_model_arm(arm: Arm, lists: Array) -> Vector3:
	var lengths: Array = ARM_LENGTHS[ARM_FAMILIES.get(arm.proto_name, "basic")]
	var stretch: float = lengths[2]
	var upper: float = lengths[0] * stretch
	var fore: float = lengths[1] * stretch
	var turn := Basis(Vector3.UP, -arm.angle)
	var out := turn * Vector3.RIGHT
	var shoulder := Vector3(arm.base.x, MODEL_SHOULDER, arm.base.y)
	var wrist := Vector3(arm.base.x, HAND_HEIGHT, arm.base.y) + out * arm.reach
	var elbow: Vector3
	if held_grip:
		# (--inserter-grip) The claw's middle reaches the hand's place at the grip's height, as a rig's grip does:
		# the IK to it with the hand as long as that, the wrist on the way.
		var claw: float = _claw.get(arm.proto_name, 1.0)
		var g := Vector3(arm.base.x, _grip_height(), arm.base.y) + out * arm.reach
		elbow = _elbow(shoulder, g, out, upper, fore * claw)
		wrist = elbow + (g - elbow) / claw
		_gripped = true
		_grip_at = g
	else:
		elbow = _elbow(shoulder, wrist, out, upper, fore)
		_gripped = false
	lists[ArmPiece.UPPER].append(_piece(shoulder, elbow, turn, lengths[0]))
	var hand := ArmPiece.CLOSED if arm.item_id > 0 else ArmPiece.OPEN
	lists[hand].append(_piece(elbow, wrist, turn, lengths[1]))
	return wrist


## A model piece (joint at its origin, pointing north, lying flat) from joint a to joint b,
## stretched from its modelled `length`.
func _piece(a: Vector3, b: Vector3, turn: Basis, length: float) -> Transform3D:
	var along := b - a
	var d := maxf(along.length(), 0.01)
	var z := -along / d
	var x := turn * Vector3.BACK
	var y := z.cross(x).normalized()
	if y.y < 0.0:
		y = -y
	x = y.cross(z).normalized()
	# The piece lies on y = 0 with its joints about half its thickness up.
	return Transform3D(Basis(x, y, z * (d / length)), a - y * 0.05)


## Adds one arm's part transforms to `lists` (indexed by Part); returns the wrist position.
func _draw_arm(arm: Arm, lists: Array) -> Vector3:
	_gripped = false  # (the placeholder's item hangs ITEM_DROP below its wrist, as before)
	var base_top := Visuals.HEIGHTS.get("inserter", 0.3) as float
	# Factorio's angle is clockwise from east on screen (y points south); Godot's yaw is
	# counter-clockwise seen from above, so the arm turns by -angle.
	var turn := Basis(Vector3.UP, -arm.angle)
	var out := turn * Vector3.RIGHT  # horizontal, towards the hand
	var shoulder := Vector3(arm.base.x, SHOULDER_HEIGHT, arm.base.y)
	var wrist := Vector3(arm.base.x, HAND_HEIGHT, arm.base.y) + out * arm.reach
	var elbow := _elbow(shoulder, wrist, out, UPPER_ARM, FOREARM)

	var table_y := base_top + TURNTABLE.y * 0.5
	lists[Part.TURNTABLE].append(Transform3D(turn * Basis.from_scale(TURNTABLE), Vector3(arm.base.x, table_y, arm.base.y)))
	var post := Vector3(SHOULDER.x, SHOULDER_HEIGHT - base_top, SHOULDER.z)
	lists[Part.SHOULDER].append(Transform3D(turn * Basis.from_scale(post), Vector3(arm.base.x, (base_top + SHOULDER_HEIGHT) * 0.5 + 0.02, arm.base.y)))
	lists[Part.UPPER].append(_segment(shoulder, elbow, turn, ARM_THICKNESS * 1.3))
	lists[Part.FOREARM].append(_segment(elbow, wrist, turn, ARM_THICKNESS))
	# The hand stays level, across the arm; two fingers hang from its sides.
	var hand_at := wrist + Vector3(0.0, HAND_SIZE.y * 0.5, 0.0)
	lists[Part.HAND].append(Transform3D(turn * Basis.from_scale(HAND_SIZE), hand_at))
	var across := turn * Vector3.BACK
	for side: float in [-1.0, 1.0]:
		var finger: Vector3 = wrist + across * (side * (HAND_SIZE.z * 0.5 - FINGER_SIZE.z * 0.5)) - Vector3(0.0, FINGER_SIZE.y * 0.5, 0.0)
		lists[Part.FINGERS].append(Transform3D(turn * Basis.from_scale(FINGER_SIZE), finger))
	return wrist


## Where the elbow goes: two-bone IK in the arm's vertical plane, bending upwards.
static func _elbow(shoulder: Vector3, wrist: Vector3, out: Vector3, upper: float, fore: float) -> Vector3:
	var to_wrist := wrist - shoulder
	var d := clampf(to_wrist.length(), 0.05, upper + fore - 0.001)
	var horizontal := Vector2(to_wrist.x, to_wrist.z).dot(Vector2(out.x, out.z))
	var dir_angle := atan2(to_wrist.y, horizontal)  # of the shoulder-wrist line, from level
	var cos_a := (upper * upper + d * d - fore * fore) / (2.0 * upper * d)
	var lift := dir_angle + acos(clampf(cos_a, -1.0, 1.0))
	return shoulder + out * (cos(lift) * upper) + Vector3.UP * (sin(lift) * upper)


## A box from a to b, `thickness` square, turned with the arm.
func _segment(a: Vector3, b: Vector3, turn: Basis, thickness: float) -> Transform3D:
	var along := b - a
	var length := maxf(along.length(), 0.01)
	var x := along / length
	var z := turn * Vector3.BACK
	var y := z.cross(x).normalized()
	z = x.cross(y)
	var basis := Basis(x * length, y * thickness, z * thickness)
	return Transform3D(basis, (a + b) * 0.5)


func _part_color(part: int, color: Color) -> Color:
	match part:
		Part.TURNTABLE:
			return color.darkened(0.2)
		Part.UPPER:
			return color.darkened(0.1)
		Part.HAND:
			return color.darkened(0.35)
		Part.FINGERS, Part.SHOULDER:
			return DARK_STEEL
	return STEEL
