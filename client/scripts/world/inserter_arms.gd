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
## --inserter-rest-arms=on (the default) | off: an inserter the bridge sends no hand for draws its arm at rest,
## the hand empty at its pickup (Factorio's idle hand waits there). The bridge sends hands only within its
## detail radius of the focus (`f3d-detail-radius`, 24 tiles by default) and no model carries an arm, so past
## that every inserter stood without one (owner, K12). Cheap: three plain boxes in the arm's paint (ARM_TINTS),
## riding the hills (item.gdshader), every resting arm in one MultiMesh without shadows; worked out per chunk
## when its entities change (for at most REST_USEC of a frame) or one of its inserters' live arms comes or goes
## (at once), put together at most every REST_REFRESH seconds (at once for a live arm), never per frame. Off:
## as before.
static var rest_arms := true
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
		elif a.begins_with("--inserter-rest-arms="):
			rest_arms = a.substr(21) != "off"
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
	if handoff and not events:
		# (The hand-off needs the events: the pose stays the samples', the held item follows the events.)
		events = true
		events_items = true


static func flags_text() -> String:
	return "arms clock %s, events %s, handoff %s, grip %s, rest arms %s" % ["belt" if belt_clock else "wall", "off" if not wants_events() else ("items" if events_items else "on"),
		"on" if wants_handoff() else "off", "on" if held_grip else "off", "on" if rest_arms else "off"]


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
	_arms.clear()
	_missing.clear()
	_seen.clear()
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
	if _rest_mmi != null and _rest_mmi.multimesh != null:
		_rest_mmi.multimesh.visible_instance_count = 0
	_rest_put = true
	if world != null:
		for c in world.chunks:
			_rest_dirty[c] = true


func count() -> int:
	return _arms.size()


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
		arm = Arm.new()
		arm.angle = rel.angle()
		arm.reach = rel.length()
		arm.path_angle = arm.angle
		arm.path_reach = arm.reach
		_arms[unit] = arm
	_bind(arm, rec)
	if belt_clock:
		if _add_sample(arm, float(k), rel, item_id) and arm.ticks.size() >= 2 \
				and not (arm.preplanned if quick_apply else _preplan.has(arm)):
			arm.preplanned = true
			_preplan.append(arm)
		return
	arm.item_id = item_id
	arm.from_angle = arm.path_angle
	arm.from_reach = arm.path_reach
	arm.to_angle = rel.angle()
	arm.to_reach = rel.length()


## The arm's record: its base, prototype (colour, model, family), end poses and speeds. Each update
## (the record can change: rotated, upgraded), or when its record first comes (events).
func _bind(arm: Arm, rec) -> void:
	var pack := ModelLibrary.entity_pack(rec.extra)
	if quick_apply and arm.bound_rec == rec and arm.bound_dir == rec.dir and arm.bound_proto == rec.proto_id \
			and arm.base == rec.pos and arm.bound_pack == pack and arm.bound_gen == ModelLibrary.generation \
			and arm.bound_ver == ModelLibrary.ModelPacks.version:
		if belt_clock and not arm.ends_tried:
			_learn_ends(arm, rec, protos.entity(rec.proto_id) if protos != null else null)
		return
	var proto: ProtoDB.EntityProto = protos.entity(rec.proto_id) if protos != null else null
	arm.color = proto.color if proto != null else Color.GOLDENROD
	arm.proto_name = proto.name if proto != null else ""
	arm.base = rec.pos
	arm.dir = rec.dir
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
	arm.bound_gen = ModelLibrary.generation
	arm.bound_ver = ModelLibrary.ModelPacks.version
	if belt_clock and not arm.ends_tried:
		_learn_ends(arm, rec, proto)


## A sample (the hand `rel` to its base at tick `k`) into the arm's ring; true when it was new.
func _add_sample(arm: Arm, k: float, rel: Vector2, item_id: int) -> bool:
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
			_arms.erase(unit)
			_missing.erase(unit)
			continue
		var arm: Arm = _arms.get(unit)
		if arm == null:
			arm = Arm.new()
			_arms[unit] = arm
		var rec = world.entities.get(unit) if world != null else null
		if rec != null and not arm.bound:
			_bind(arm, rec)
		var x: float = v[6] / 256.0
		var y: float = v[7] / 256.0
		if not arm.add_event(float(v[2]), kind, v[3], v[4], v[5], x, y, v[8]):
			continue
		if kind == Swing.Ev.SYNC and arm.bound:
			# (Its position: a sample too, the fallback when the status says it doesn't move as its
			# speeds say, and the sweep's side when it was read mid-swing.)
			_add_sample(arm, float(v[2]), Vector2(x, y) - arm.base, v[4] if v[3] > 0 else 0)
		if v[5] == 0 and (kind == Swing.Ev.PICKED or kind == Swing.Ev.DROPPED) and arm.bound:
			_backdate(arm, float(v[2]))
	if _newest_event - _swept >= 60.0:
		_swept = _newest_event
		for unit in _arms.keys():
			var arm: Arm = _arms[unit]
			if arm.last_heard >= 0.0 and arm.last_heard < _newest_event - STALE_TICKS:
				_arms.erase(unit)


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


static func _vec(v) -> Vector2:
	return Vector2(float(v[0]), float(v[1])) if v is Array and v.size() >= 2 else Vector2.ZERO


## A north-facing vector turned to a 16-way direction (as cursor_overlay.gd turn).
static func _turn(v: Vector2, dir: int) -> Vector2:
	return v.rotated(-Wire.direction_yaw(dir))


## Whether a belt (transport belt, underground, splitter, loader) stands at this position.
func _belt_at(pos: Vector2) -> bool:
	if world == null or protos == null:
		return false
	var cv = world.chunks.get(Vector2i(floori(pos.x / 32.0), floori(pos.y / 32.0)))  # (world.gd chunk_of)
	if cv == null:
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
	for unit in _arms.keys():
		if _seen.has(unit) or (_arms[unit] as Arm).ev_ticks.size() > 0:
			_missing.erase(unit)  # (an arm with events goes when the events say: gone, or stale)
		else:
			var n: int = _missing.get(unit, 0) + 1
			if n >= MISSING_FRAMES:
				_arms.erase(unit)
				_missing.erase(unit)
			else:
				_missing[unit] = n
	_seen.clear()


## (belt clock) The arm's pose at game tick `t`: from its events when it has them for that tick (and
## its status then says it moves as its speeds say), else between the two samples round it as the
## swing model says, held before its first sample, played on past its newest.
func _pose_at(arm: Arm, t: float) -> void:
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
		_item_from_events(arm, t)


## (--inserter-events=items) The held item at `t` from the events: what the last event at or before
## `t` says the hand holds, unless the next pick or drop is an uncertain one (the mod saw it `c` ticks
## after its check) that may already have happened by `t`: then the samples' own guess stands.
func _item_from_events(arm: Arm, t: float) -> void:
	var n := arm.ev_ticks.size()
	if n == 0 or t < arm.ev_ticks[0]:
		return
	var i := arm.ev_ticks.bsearch(t, false) - 1
	if arm.ev_kind[i] == Swing.Ev.GONE:
		return
	var j := i + 1
	while j < n and arm.ev_kind[j] != Swing.Ev.PICKED and arm.ev_kind[j] != Swing.Ev.DROPPED:
		j += 1
	if j < n and arm.ev_c[j] > 0 and t >= arm.ev_ticks[j] - arm.ev_c[j]:
		return
	arm.item_id = arm.ev_item[i] if arm.ev_count[i] > 0 else 0


## The plan between samples `a` and `a + 1` (made when the drawn tick reaches them, or ahead by
## preplan: the inputs are all there once both samples are).
func _plan_pair(arm: Arm, a: int) -> Array:
	var side := _side_at(arm, a)
	var plan := Swing.plan(arm.ticks[a], arm.angles[a], arm.reaches[a], arm.items[a],
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
		if not _preplan.is_empty():
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
		var pack_ver := ModelLibrary.ModelPacks.version
		var model_ver: int = ModelLibrary.generation
		if arm.mode == Arm.Mode.NONE or arm.mode_pack_ver != pack_ver or arm.mode_model_ver != model_ver:
			var cards := _sprite_set_for(arm.model_name)
			var rig = {} if not cards.is_empty() else _rig_for(arm.proto_name)
			if rig == null:
				continue  # its model is still being read: neither base nor arm is drawn yet
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
					continue  # its pieces are still being read
				arm.mode = Arm.Mode.BASIC
				arm.mode_cards = {}
				arm.mode_rig = {}
			arm.mode_pack_ver = pack_ver
			arm.mode_model_ver = model_ver
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
		_run_native(held, held_yaws)
		_cards.draw(held, held_yaws)
		_update_rest(live, delta)
		if animator != null and not animator.arm_working.is_empty():
			_stop_unseen(animator, live)
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


## What an arm holds, queued for ItemCards.draw: the kind it is drawn as, where it hangs (held_at, with the
## grip _gripped/_grip_at the arm's drawing left) and how it is turned.
func _hold(arm: Arm, unit: int, wrist: Vector3, held: Dictionary, held_yaws: Dictionary) -> void:
	if arm.held_key == 0 or ItemCards.item_of(arm.held_key) != arm.item_id:
		arm.held_key = _cards.variant_key(arm.item_id, hash([unit, arm.grabs]))
	var key := arm.held_key
	if not held.has(key):
		held[key] = []
		held_yaws[key] = []
	held[key].append(held_at(arm, wrist))
	# (--inserter-grip) A model sits square in the grip, turned with the hand; an icon card keeps its
	# slight turn (an icon turned with the hand would stand on its head on the way back).
	held_yaws[key].append(-arm.angle if _gripped and _cards.turns(key) else ItemCards.turn_for(unit))


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
			match m:
				0:
					var lengths: Array = ARM_LENGTHS[ARM_FAMILIES.get(arm.proto_name, "basic")]
					var w: Array = arm.mode_cards["widths"]
					r = _native.sprite_arms(b.inp, _caps_of(_sprite_mmis.get(key)), PackedFloat32Array([gh, MODEL_SHOULDER,
						lengths[0], lengths[1], lengths[2], CLAW_DEFAULT, SpriteStandins.FACTORIO_PITCH, HAND_TIP, SPRITE_DEPTH,
						SPRITE_HAND_DEPTH, w[0], w[1], w[2], ITEM_DROP]))
				1:
					var rig_entry: Variant = _rigs.get(key)
					r = _native.rig_arms(b.inp, _caps_of((rig_entry as Dictionary).get("mmis") if rig_entry is Dictionary else null),
						_rig_params(arm.mode_rig, gh))
					if float(r[5]) > 1.0 and not _stretched.has(key):
						_stretched[key] = true
						var lengths: Array = arm.mode_rig["lengths"]
						print("[inserters] %s: the model's arm (%.3f) is shorter than the hand's reach: stretched to reach (x%.3f)" % [
							key, float(lengths[0]) + float(lengths[1]), float(r[5])])
				2:
					var lengths: Array = ARM_LENGTHS[ARM_FAMILIES.get(arm.proto_name, "basic")]
					var stretch: float = lengths[2]
					r = _native.model_arms(b.inp, _caps_of(_model_parts.get(key)), PackedFloat32Array([MODEL_SHOULDER, HAND_HEIGHT,
						float(lengths[0]) * stretch, float(lengths[1]) * stretch, lengths[0], lengths[1], 1.0 if held_grip else 0.0,
						gh, _claw.get(arm.proto_name, 1.0), ITEM_DROP]))
				3:
					r = _native.basic_arms(b.inp, _caps_of(_parts), PackedFloat32Array([Visuals.HEIGHTS.get("inserter", 0.3),
						SHOULDER_HEIGHT, HAND_HEIGHT, UPPER_ARM, FOREARM, TURNTABLE.x, TURNTABLE.y, TURNTABLE.z, SHOULDER.x,
						SHOULDER.y, SHOULDER.z, HAND_SIZE.x, HAND_SIZE.y, HAND_SIZE.z, FINGER_SIZE.x, FINGER_SIZE.y, FINGER_SIZE.z,
						ARM_THICKNESS, STEEL.r, STEEL.g, STEEL.b, DARK_STEEL.r, DARK_STEEL.g, DARK_STEEL.b]))
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


## (rest arms) Every resting arm's box in one MultiMesh (16 floats an instance: the transform's rows, the
## colour); per chunk its arms' instances; the chunks to work out again (entities changed: a few a frame; a live
## arm came or went: at once), the arms drawn live last frame (unit -> chunk), and what was last put together.
## A chunk whose inserter waits for its model is tried again on the next frames.
var _rest_mmi: MultiMeshInstance3D = null
var _rest_box_mesh: BoxMesh = null
var _rest_box_mat: ShaderMaterial = null
var _rest := {}  # chunk -> PackedFloat32Array
var _rest_chunk_mmis := {}  # (chunked rest arms) Vector2i chunk -> MultiMeshInstance3D
var _rest_chunk_counts := {}  # (chunked rest arms) Vector2i chunk -> instance count
var _rest_upload := {}  # Vector2i chunk -> true (needs MMI upload/erase)
var _rest_total_instances := 0
var rest_chunk_uploads := 0  # (tests) per-chunk rest MMI uploads/removals performed
var _rest_sprites := {}  # (sprite arms) chunk -> {model name -> [PackedFloat32Array per SpritePiece]}
var sprite_rest_count := 0  # (tests) resting arms drawn as pictures
var _rest_dirty := {}  # chunk -> true
var _rest_now := {}  # chunk -> true
var _rest_live := {}  # unit -> chunk
var _rest_put := false
var _rest_wait := 0.0
var _rest_eprops := -1
var _rest_hooked := false
var _is_inserter := {}  # proto id -> bool
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
var rest_count := 0  # (tests, probes) resting arms drawn


## (rest arms) After the live arms are drawn: the chunks whose inserters changed, or whose live arms came or
## went, worked out again, and the boxes put together when any did.
func _update_rest(live: Dictionary, delta: float) -> void:
	if not rest_arms or world == null:
		if _rest_mmi != null and _rest_mmi.visible:
			_rest_mmi.visible = false
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
	for mmis: Array in _sprite_rest_mmis.values():
		for mmi in mmis:
			(mmi as MultiMeshInstance3D).visible = true
	for u in live:
		if not _rest_live.has(u):
			_rest_now[live[u]] = true
	for u in _rest_live:
		if not live.has(u):
			_rest_now[_rest_live[u]] = true
	_rest_live = live
	if eprops.size() != _rest_eprops:
		_rest_eprops = eprops.size()
		for c in world.chunks:
			_rest_dirty[c] = true
	var at_once := not _rest_now.is_empty()
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
		if not _rest_sprites.is_empty() or not _sprite_rest_mmis.is_empty():
			_put_rest_sprites()
		else:
			sprite_rest_count = 0


## (chunked rest arms) Upload only dirty chunks into per-chunk MultiMesh children of _rest_mmi.
var _rest_behind_connected: Object = null


func _rest_behind_hidden(c: Vector2i) -> bool:
	if not ViewPriority.tight_cull or world == null or not is_instance_valid(world):
		return false
	var bc: Variant = world.get("behind_cull")
	return bc != null and is_instance_valid(bc) and bc.is_active() and bc.hidden(c)


func _on_rest_behind_visibility(c: Vector2i, drawn: bool) -> void:
	var mmi: MultiMeshInstance3D = _rest_chunk_mmis.get(c)
	if mmi != null and is_instance_valid(mmi):
		mmi.visible = drawn or not _rest_behind_hidden(c)


func _flush_rest_chunks() -> void:
	if world != null and is_instance_valid(world):
		var bc: Variant = world.get("behind_cull")
		if bc != _rest_behind_connected and bc != null and is_instance_valid(bc):
			_rest_behind_connected = bc
			if bc.has_signal("chunk_visibility_changed"):
				bc.chunk_visibility_changed.connect(_on_rest_behind_visibility)
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


## (rest arms) Chunk c's resting arms worked out again: every inserter in it not drawn live. False when one
## waits for its model (to be tried again).
func _rest_chunk(c: Vector2i) -> bool:
	var cv = world.chunks.get(c)
	_rest_put = true
	_rest_upload[c] = true
	if cv == null:
		_rest.erase(c)
		_rest_sprites.erase(c)
		return true
	var buf := PackedFloat32Array()
	var sprites := {}  # model name -> [PackedFloat32Array per SpritePiece]
	var done := true
	for rec in cv.entities.values():
		var ins = _is_inserter.get(rec.proto_id)
		var proto: ProtoDB.EntityProto = protos.entity(rec.proto_id) if protos != null else null
		if ins == null:
			ins = proto != null and proto.type == "inserter"
			_is_inserter[rec.proto_id] = ins
		if not ins or _rest_live.has(rec.unit):
			continue
		var pack := ModelLibrary.entity_pack(rec.extra)
		var model := proto.name + ("@" + pack if pack != "" else "")
		var pictures := _sprite_set_for(model)
		if not pictures.is_empty():
			if not sprites.has(model):
				sprites[model] = [PackedFloat32Array(), PackedFloat32Array(), PackedFloat32Array()]
			var x: Dictionary = (eprops.get(rec.proto_id, {}) as Dictionary).get("x", {})
			var pick := _vec(x["ip"]) if x.has("ip") else Vector2(0.0, -2.0 if ARM_FAMILIES.get(proto.name, "") == "long" else -1.0)
			pick = _turn(pick, rec.dir)
			var lift := _platform_lift(proto.name, rec.dir)
			var xf := sprite_cards(proto.name, pictures, rec.pos, Vector3(rec.pos.x + pick.x, _grip_height(), rec.pos.y + pick.y),
				0.0 if is_nan(lift) else lift)
			_rest_xf(sprites[model][SpritePiece.BASE], xf[0])
			_rest_xf(sprites[model][SpritePiece.OPEN], xf[1])
			continue
		var rig = _rig_for(proto.name)
		if rig == null:
			done = false  # (its model is still being read)
			continue
		_rest_arm(buf, rec, proto, rig)
	if buf.is_empty():
		_rest.erase(c)
	else:
		_rest[c] = buf
	if sprites.is_empty():
		_rest_sprites.erase(c)
	else:
		_rest_sprites[c] = sprites
	return done


static func _rest_xf(buf: PackedFloat32Array, t: Transform3D) -> void:
	var b := t.basis
	buf.append_array([b.x.x, b.y.x, b.z.x, t.origin.x, b.x.y, b.y.y, b.z.y, t.origin.y, b.x.z, b.y.z, b.z.z, t.origin.z])


## (rest arms) One inserter's arm at rest into `buf`: from its shoulder (a rig's, or the base's top) through the
## elbow the IK gives to its grip over the pickup point (eprops `ip`, turned by its direction).
func _rest_arm(buf: PackedFloat32Array, rec, proto: ProtoDB.EntityProto, rig: Dictionary) -> void:
	var x: Dictionary = (eprops.get(rec.proto_id, {}) as Dictionary).get("x", {})
	var pick := _vec(x["ip"]) if x.has("ip") else Vector2(0.0, -2.0 if ARM_FAMILIES.get(proto.name, "") == "long" else -1.0)
	pick = _turn(pick, rec.dir)
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


## The arm rig of an inserter prototype's model with its MultiMeshes, made once its model is read;
## {} when the model has none (Wube's pieces then), null while the model is still being read.
func _rig_for(proto_name: String):
	if _rigs.has(proto_name):
		return _rigs[proto_name]
	if proto_name == "" or not ModelLibrary.rig_name(proto_name):
		_rigs[proto_name] = {}
		return _rigs[proto_name]
	if not ModelLibrary.ready(proto_name):
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
		if not ModelLibrary.ready("inserter-arm-%s-%s%s" % [family, piece, pack]):
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
