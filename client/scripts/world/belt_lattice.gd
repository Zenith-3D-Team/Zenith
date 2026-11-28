extends RefCounted
## --belt-draw-lattice: lanes the game has packed are drawn packed (owner's concession). Items on a belt
## sit 0.25 tile apart, so a lane full of one kind drawn as a row of that item every 0.25 tile, at any
## phase, has each of the game's items within 0.125 tile of one drawn: such a lane needs no simulated
## positions or ids, only "full, kind X". (tools: the lattice job's rescore of the every-tick capture at
## -62,-26: 97% of the game's items were on lanes full of one kind, and 96% of what the simulation
## missed was on them; docs/BELT-SIM-PLAN.md.)
##
## Which lanes: those the bridge's last read of the lane (`sl`) found full of one kind, while its drift
## checks (`pc`) after say it is still full (full: as many items as whole gaps fit in its length, every gap
## at most 66). A lane read with gaps or two kinds, or checked short, is drawn from the simulation again.
## Underground lines under the ground, loaders and other lanes keep the simulation's items.
##
## How: each such lane in view gets a lattice: one record a slot, every 64 (1/256 tile) from the
## simulation's front item on the lane (its phase), sliding at that item's speed: the record's texel 3
## holds the lattice's period (ticks per gap) and the shader takes the drawn clock modulo it, so a
## moving lattice costs nothing until its speed changes (the simulation's front item standing or moving at
## two checks in a row: a stop-and-go lane is drawn as it was) or its phase drifts DRIFT off the
## simulation's. A speed change keeps the lattice where it is drawn, so it never jumps; any phase draws a
## full lane within 0.125 tile of the game's items, so the phase is only made again for a big drift.
## The simulation's items on those lanes stay simulated, but the shader hides every item record whose
## place falls in a cell of the lanes' mask (CELLS a tile, MASK cells a side, wrapping): a lane's
## centre line marks its cells, so an item gliding off a lattice lane onto a loose one shows again.
## The lattice has its own records (f3d_belt_lattice) and its own MultiMeshes (item_cards.gd with
## record_tex 1), the same for the GDScript and the C++ records paths: it is made in GDScript from the
## messages, the lane meta and BeltSim.lane_fronts (the C++ simulation's when loaded).
##
## Stacks: a lane's slots are piles as high as the stacks its last read (`sl`) found most often (a stack
## inserter's bus is stacks of 4 throughout): each slot has STACK records, the slot's own and a copy per
## step above it, the copies pointing at the slot's record as belt_items.gd's piles do (texel 3: the slot
## from the copy, its step k, the kind's pile step), so they slide with the slot and the mask never hides
## them; each copy turns PILE_TURN more than the one under it, cards and blocks too.
##
## Turns (K14, owner: "items change their orientation as they move on the belts"): a slot slides one gap
## and wraps back, the slot ahead taking its item on, so a turn kept per slot changed every item's turn
## each quarter tile. Each drawn item is someone instead (`who`): a lane's identity function, who the item
## at line position q is on tick t, is ln.who + (q + v (t - t0) - r0) / 64, so slot k starts at
## who + k and the shader adds the periods slid (texel 2: x who the slot's item was on its record's
## clock, y the run's seed; texel 3 z 2) and hashes both into the turn (ItemCards.lattice_turn, the same
## range and pile rule as every item's turn_for). A lane written again (a new speed or phase, its piles)
## keeps who its items are: each new slot takes the nearest old item's (_set_motion). A new lane takes
## its neighbour's, the drawn lane its items go on into or come from (so an item keeps its turn from belt
## to belt), else the map's along its exit's direction (_identify). CPU work only when a lane is written.
## --belt-draw-lattice-turns=slot: a turn per slot, as before (texel 2 its cosine and sine, texel 3 z 1).

const BeltRecords := preload("res://scripts/world/belt_records.gd")
const BeltSim := preload("res://scripts/world/belt_sim.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")

const GAP := 64
const CELLS := 4
const MASK := 2048
const MASK_TILE := 512
const MASK_GRID := 4
const MASK_TILES := 16
static var mask_tiled := true
## A drawn lattice whose phase is this far (1/256) off the simulation's front item, or whose speed
## differs, is made again.
const DRIFT := 24
## Checks in a row a new speed must be seen at before the lattice takes it.
const SPEED_CHECKS := 2
## Records hold this much below their item's lift, as the items' do (belt_items.gd LAYER_STEP).
const LAYER_STEP := 0.006
const LAYERS := 4
## Lanes longer than this (1/256) are never drawn as a lattice (a belt's lanes are at most 2 tiles; a
## message with another length is malformed: its slots and mask cells would run to millions).
const MAX_LENGTH := 1024
## Lanes are drawn when their middle is within the camera's view grown by VIEW_KEEP (tiles); that ground
## is planned again when the view leaves it.
const VIEW_KEEP := 12.0
## A drawn lattice's phase is checked against the simulation's every SLICES updates (a slice of the lanes
## each), and at once when the bridge reads or checks the lane.
const SLICES := 2
## As belt_items.gd's: a stack is at most this many, each copy above turned PILE_TURN more.
const MAX_STACK := 4
const PILE_TURN := 0.45
## Who a lattice's items are, and its runs' seeds, are kept modulo this (a float32 holds them exactly; the
## shader hashes only these bits: ItemCards.lattice_turn).
const IDS := 1 << 20

## --belt-draw-lattice=off: every lane drawn from the simulation (as before).
static var on := true
## On (the default; --belt-draw-lattice=sim: off): a straight lane's (and an underground's visible
## half's) lattice has the map's phase, a function of where its exit is and the tick alone (items at
## tau = v * t mod 64 along its way), so the lanes of a run agree whenever each was written and wherever
## the drawn clock is; curves and splitters keep the simulation's front item's phase. Live at -62,-26
## (2 runs each): 95.7 / 95.2% visible, 2.4 / 2.5% phantoms against the simulation's phase's 94.5 / 91.9%,
## 3.5 / 3.6% (its errors were at lane ends, neighbours' phases disagreeing).
static var world := true
## --belt-draw-lattice-world=all (the default; straight: as before): with `world`, a moving curve's or
## splitter's lattice takes the map's phase too, not the simulation's front item's. Any phase draws a
## full lane within 0.125 tile of the game's items, but a splitter's inputs overlap its outputs (the 51
## buffer) and a curve's last slot reaches past its entry, so where two lanes' lattices meet their
## phases must agree for every game item to have a slot of its own; the simulation's front on a
## balancer's lanes is often a tick or two off the game's (32-64 at turbo speed), which left one game
## item in three on splitter lanes at -62,-26 without a slot within 0.15 tile (section L: 10% of the
## items on splitter lanes missed, 7% of the slots phantoms).
static var world_all := true
## --belt-draw-lattice-standing=obs (the default; world: as before): a standing lattice (the simulation's
## front on the lane standing, or none there) takes its phase from the bridge's last read or check of the
## lane (its front item's position: `sl`, `pc`), not the map's (straight lanes) nor the simulation's front
## (others). A standing lane's items are exactly where the game last showed them; the map's phase was up
## to 0.125 tile off (a run backed up at phase 32 sat at the check's limit), and a standing lattice with a
## high phase had one slot too few for the lane's items.
static var standing_obs := true
## --belt-draw-lattice-pile=off: every slot one item, whatever the lane's stacks (as the first cut: a bus
## of stacks of 4 drawn flat).
static var piles := true
## (unison) On (the default): every drawn lane's speed is checked against the simulation's every job,
## and a new speed is taken at once, so the lanes of a run that starts or stops moving all change in the
## same job the simulation's own records do (the map's phase then keeps their lattices in step). Off
## (--belt-draw-lattice-unison=off, as before): a slice of the lanes a job (SLICES) and a new speed only
## at SPEED_CHECKS checks in a row, so neighbouring lanes changed speed jobs apart: at each lane boundary
## the sliding lane's slots opened and closed a gap of up to 0.25 tile against the standing one (the
## owner's "shimmer of small gaps" as a backed-up line starts moving), and at the run's ends the
## simulation's items moved away from the standing lattice for two jobs.
static var unison := true
## (settle) On (the default; --belt-draw-lattice-settle=off: as before): a standing lattice stays where it
## is while its lane closes a hole. An inserter's take from a backed-up line moves every item behind it one
## gap on and they stand again: a row of one kind a whole gap on is the same picture, but each lane's lattice
## took the new speed at once, at the map's phase (up to 0.125 tile from where it stood), slid for an update
## or two, stopped wherever that left it and was set again at the lane's next read or check: the whole line
## behind the hand jumped an eighth of a tile twice at every take (the owner, K19: "they all of a sudden jump
## around"). Now a standing lane only takes a new speed once the simulation has had it moving for more
## than two gaps' time (16 ticks on a yellow belt: a line that really flows), and a standing lane's phase is
## the simulation's standing front item's (the bridge's last read or check only where the simulation has no
## item there): a read made mid-way through the closing gave a phase part of a gap out until the next one.
## A lane that comes to be drawn while it moves waits as long before it is (it is drawn from the simulation
## meanwhile): made at once it slid at the map's phase for the rest of the closing, then stood and jumped.
## And the hole a take leaves in a standing lane (hole()) closes once the drawn clock is a gap's time past
## the take, the line having closed up: it stayed open for as long as the lane stood and stayed full.
static var settle := true
## (settle) A standing lane takes a new speed after this many gaps' time of it.
const SETTLE_GAPS := 2
## (settle) A standing lane's hole closes this many ticks after the take when the lane's speed isn't known
## (a yellow belt's gap); at its speed when the simulation has had it moving since.
const HOLE_TICKS := 8
## (creep) --belt-draw-lattice-creep=on (off by default: as before; flow, below: by the net flow): a standing lane the simulation keeps
## moving in steps slides at the speed it moves at on average. On a creeping lane (an inserter's pickup
## belt, a merge, a line behind one: its items move up a gap and stand, again and again) the front item
## waits at the exit while the items behind it close up, so its speed (the lattice's) was 0 at nearly every
## update, and with settle a standing lane takes a speed only after two gaps' time of steady motion: the
## whole lane stood for seconds while the game's items moved on (the owner: "items on belts sometimes hold
## in place for like 10 seconds or groups of items"; live at -62,-26 with consumers restarting, 23% of the
## items in view on lanes drawn standing while the game moved them). Each lane keeps a running share of
## the time the simulation has most of its items moving (BeltSim.lane_fronts speed_of 1, FLOW_ONE the whole,
## CREEP_TAU ticks); over CREEP_ON it slides on from where it is drawn (no jump) at that share of the belt's
## speed, and goes back to settle's rules below CREEP_OFF (standing on the simulation's front) or once the
## simulation has had it moving steadily CREEP_RUN_GAPS gaps' time (the belt's own speed). A single take's
## closing (a gap on, standing again: K19's case) moves it for a few ticks only, far below CREEP_ON.
## By the share alone, live at -62,-26 (consumers restarting) it took the lanes drawn standing while the game's
## moved from 23.2% of the items in view to 2.7%, but the simulation moves many lanes the game holds (into
## splitters, at reads), and those now slid: lanes drawn sliding while the game's stood 4.2% -> 16.5%,
## visible 97.1 -> 96.4%. It wanted a test that the lane's items really flow through it: creep_flow below
## (--belt-draw-lattice-creep=flow; on: by the share, as this first cut). Off by default (as before creep).
static var creep := false
const FLOW_ONE := 1024
const CREEP_TAU := 120
const CREEP_ON := 256
const CREEP_OFF := 102
const CREEP_RUN_GAPS := 4
## (creep_flow) --belt-draw-lattice-creep=flow (off by default; on: by the share above): a lane creeps by the net distance its
## items go on past its exit, not by the time they move. The simulation's front item on the lane
## (BeltSim.lane_fronts speed_of 2) changing to one the lane hasn't had in front is a gap on; to one it had (of
## its last FLOW_HIST fronts) a read putting the items back: a gap back for each front since. Its running rate
## (1/256 a tick, in FLOW_ONE, over CREEP_TAU) at CREEP_FLOW_ON or more has a standing lane slide on from where
## it is drawn at that rate (at least 1/256 a tick), below CREEP_FLOW_OFF on to the simulation's standing
## front's phase and stand. Its new motion starts at the drawn clock's tick, where it is drawn then (set at the
## simulation's tick, the lattice jumped by the change of speed times the drawn clock's lag). A lane the
## simulation has none on stands where it is drawn (creeping: at once; at the simulation's speed: after
## NONE_TICKS): it went on as it was for good. And a lane at the simulation's speed for FLOW_GATE_TICKS whose
## net rate is under FLOW_GATE (about a gap in 16 ticks) stands, and takes the simulation's speed again only
## with that rate: the simulation runs on lanes the game holds (at -62,-26 the lines into a balancer let go
## and read back again and again), the same fronts coming back with each read. Offline (the restart
## capture): lanes drawn standing while the game's moved 3.2% (settle alone 19.1%), sliding while the game's
## stood 3.2% (4.7%), no frozen span of 5 s or more (133).
static var creep_flow := true
const FLOW_HIST := 16
const CREEP_FLOW_ON := 300
const CREEP_FLOW_OFF := 100
const NONE_TICKS := 30
const FLOW_GATE := 1000
const FLOW_GATE_TICKS := 120
## (creep_step) --belt-draw-lattice-creep=step (off by default; creep stays off with it): a standing lane steps instead
## of creeping. It stays at the game's rest phase (settle, standing_obs) and stays a standing lane for the mask; each
## new front item on it (BeltSim.lane_fronts speed_of 2, its history as creep_flow's) is a gap its items went on past
## its exit, and queues a one-gap slide at the belt's speed (close's slide: slide_at, slide_v, slide_more), timed to
## the tick the items moved: from the new front's place while it moves, else between the last update and a slide's
## time before this one. Its net rate (creep_flow's flow_q) at half the belt's speed or more leaves it to the usual
## rules (they take the simulation's speed). A take close already slid the lane for (an `ie` hand ahead) isn't slid
## again when its front changes, nor the other way round (step_bal, within STEP_BAL_TICKS). A curve whose length
## isn't a whole number of gaps stands, as close has it.
static var creep_step := false
const STEP_BAL_TICKS := 90
## --belt-draw-lattice-turns=slot: each slot keeps a turn of its own (as before K14), so an item seen
## sliding along takes the next slot's turn every quarter tile. On (the default): a turn per item.
static var item_turns := true
## (turn_id) --belt-draw-turn-id=old (as before): a new lane's items were who its neighbour's or the map's formula
## said (_identify), a simulated item turned by its unique id, so an item changed its turn where a lattice lane met
## one drawn from the simulation (5098 on belt_bursts --feed --feed-loose 0.1, 4342 of them at such a join). On (the
## default): the simulation numbers each item along its run (belt_sim.gd _num, one behind the item ahead), a simulated
## item turns by its number (ItemCards.lattice_turn(number, TURN_RUN)), and a lane is seeded from the simulation's front
## item on it (_seed: slot k is item front + k) when it is written, and again when moving in step for SEED_AFTER its
## items' numbers have run ahead of its slots (a line a little more than a gap apart). Not a standing lane (settle and
## close stand it behind its run on purpose, its picture kept, K19) nor a ring (_ring: its numbers jump once round it).
## That run: 2150 changes, 233 at a join.
static var turn_id := true
## (edge_shut) --belt-draw-edge-shut=off (as before): a moving lane leading nowhere loaded (the square's edge) opened its
## exit like one beside a lane drawn from the simulation, so the simulation's items stopped at its end as a guess (EDGE_STOP)
## showed there, stacked, while the game's ran on (phantoms 1.36% -> 2.36% on belt_bursts --feed --feed-loose 0.1, most at
## the run's exit). On (the default): an exit opens only where its items go on (BeltSim.leads_on).
static var edge_shut := true
## (turn_id) The run seed every numbered item turns with (texel 2 y), the lattice's and the records' alike.
const TURN_RUN := 40503
## (turn_id) Ticks a lane moves in step before who its items are is checked against the simulation's.
const SEED_AFTER := 120
## (turn_id) How far (1/256) a lane at the map's phase (world) may be off the simulation's items for who they are to
## be told: clear of half a gap, where the nearest slot could be either.
const SEED_WL := 28
## (mask) --belt-draw-lattice-mask=ends (as before): a lane marked the mask's cells along its centre line from end
## to end, so where its entry's point lies on a cell's edge (a lane going west or north: the cell is the one
## above it) the cell it marked was the lane behind's first one: that lane's front item, standing at its exit, was
## hidden while that lane was drawn from the simulation (the owner, K19: a hand's take from a backed-up line, the
## take's lane given up for the simulation's items and its front item gone from view until it was a lattice
## again; tools/belt_build_mine.py's mine scene: the queue behind the gap). On (the default): a standing lane's
## entry point a 64th of a tile inside it. Its exit's point still marks the cell past it (a lane going east or
## south: the lane ahead's last one), and a moving lane marks end to end: with every cell past either end left
## unmarked, the restart capture at -62,-26 had 2.15% phantoms against 1.73% (the simulation's items just past
## a lattice's exit, where its slots draw the game's). A lane that starts or stops moving is marked again.
static var mask_inner := true
## (mask_own) --belt-draw-lattice-mask=entry (as before, with mask_inner): a lane's exit point marked the cell past
## it on a lane going east or south (the lane ahead's last one), and a moving lane's entry point the cell past it on
## a lane going west or north (the lane behind's first one). Where that lane was drawn from the simulation (a take's
## lane given up, a lane short of full) its items vanished in that cell as they went through it, a fixed one-item gap
## at the belts' join while the line moved (the owner: "after pulling items off a full backed up belt these gaps
## appear and items move past but the gap remains in the spot until it stops again"; tools/belt_bursts.py --mode take
## --f --east: 1.16% of the game's items undrawn against 0.76%, the join's cell 27 items in turn). On (the default):
## every lane's ends a 64th of a tile inside it, moving or standing, so it marks its own cells only (a lattice lane
## ahead or behind marks its own; where the simulation draws it, its items show). The same run going west: 0.57%
## undrawn against 0.42%, no more phantoms.
static var mask_own := true
## (mask_open) --belt-draw-lattice-open=off (as before): a moving lane marked all its own cells, whatever drew the
## lanes beside it. A moving lattice has the map's phase (world), and a line's items have whatever phase its history
## gave them, up to 0.125 tile off it; the lattice draws a slot every gap within its lane, so the game's item at its
## exit with its slot already past the end (the lattice ahead of the game's items), or at its entry with its slot not
## yet in (behind), is drawn by the lane on that side: a lattice there of the same phase has a slot for it, but a lane
## drawn from the simulation (read short of full: a gap of 67 or more somewhere, a line fed by inserters or a merge)
## draws the item where it is, under this lane's mask, hidden. Every item going through the join vanished for a few
## ticks, a gap standing in the moving line (the owner: "they don't just move in unison"; tools/belt_bursts.py --mode out
## --feed --feed-loose 0.1: 0.40% of the game's items mid-run undrawn against none packed tight). On (the default, with
## mask_own): a moving lane whose slots are more than OPEN_TOL ahead of the simulation's front item (its phase, the
## game's where the simulation follows it) leaves its exit's cell unmarked when the lane its items go on into isn't a
## lattice moving at its speed, and one behind it its entry's cell when no such lattice feeds it (`open`): the
## simulation's item, where the game's is, shows there beside the slots (in that cell a slot and an item are at most the
## phases' difference apart, 0.125 tile, a slot a little ahead or behind the item, never a gap). The other end, and a
## lattice in step, keep their cells: there the slots draw every item. A standing lane stands at the game's phase
## (standing_obs, settle) and keeps all its cells.
static var mask_open := true
const OPEN_EXIT := 1
const OPEN_ENTRY := 2
## (mask_open) A lattice this far (1/256) or less off the simulation's phase keeps its ends' cells: an item at most a
## tick without a slot on a yellow belt.
const OPEN_TOL := 4
## (handover) --belt-draw-handover=old (as before, with mask_open): in an open end's cell both the slot and the
## simulation's item were drawn, up to 0.125 tile apart (phantoms 1.36% -> 4.01% on a loose-fed moving line). On (the
## default): each item is drawn once through the handover. The slot whose gap reaches into an open end's cell hides
## while its item is the simulation's to draw there (`open_d`: the phases' difference at the simulation's front item,
## the slot that far ahead of or behind its item): at an open exit slot 0 from where its item comes into the cell (g =
## d / 64 of its period), at an open entry the last slot until its item leaves the cell. Its record's texel 3 y says so
## (_hand_code: -(1 + h) hidden from g h on, -(3 + h) hidden before g h; a slot's own record had 0 there, a pile's copy
## its step k > 0), as belt_path.gdshaderinc, the scorers and drawn_lattice read it. The item keeps its turn through
## the handover with turn_id (below).
static var handover := true
## (handover) The slot hides this much (1/256) later at an exit, shows this much sooner at an entry: a line's items are
## a few 256ths off one another's phase (a loose-fed line, the front item read a job ahead of the drawn clock), and an
## item further off than the front one had neither its slot nor its own copy drawn (belt_bursts --feed --feed-loose
## 0.1: undrawn 0.18% of item-ticks with none, 0.16% with 3, as with the handover off; doubled 1.28%, 1.39%).
const HAND_SLACK := 3
## (close) --belt-draw-lattice-close=off (as before): the lanes behind a take's hole in a standing lane stood
## while the game's line closed it up (with settle: a gap on is the same picture), and the take's own lane,
## drawn from the simulation once given up, slid alone (the owner, K19: "the items dont slide forward as a
## group to fill the space"). On (the default, with settle): a take on a standing lane has every drawn
## standing lane behind it (feeds, its straight run back) slide one gap from the take's tick at its belt's
## speed and stand again, as the game's packed line does: each slot's record as a moving lattice's with its
## clock held within [the take's tick, a period after] (texel 1 w that tick: belt_path.gdshaderinc), so it
## stands before and after, wherever the drawn clock is when it is written. The slots end a gap on, each
## the item that was behind it (who + 1). A lane whose standing slots aren't a moving lane's (a curve whose
## length isn't a whole number of gaps) stands as before; a second take while a lane slides closes after
## the first's (CLOSE_MORE more slides at most).
static var close := true
const CLOSE_MORE := 4
## (sim_full) --belt-draw-lattice-sim-full=off (as before): a moving lane stayed a lattice while the bridge's
## last read or check found it full, though the line behind it ended or was gone: a belt mined in a moving
## line left the belts in front of it drawn full and moving until the bridge's next check (the owner, K22:
## "the belt in front stays full as it moves forward instead of emptying immediately few seconds later it
## shows the empty spaces"), and a backed-up line let go drew its last belts full behind its tail (K16:
## "leaves some ghosts at the end where it is pulling forward from"). On (the default): a moving lane the
## simulation has items on but fewer than a full lane's is given up (drawn from the simulation, its full
## forgotten until the bridge's next read or check says so again), for FED_GONE_TICKS after a belt behind it
## was removed (feed_gone, belt_items.gd: the lanes its items went on into, on along their run). Elsewhere the
## bridge's word stands, as before: the simulation is often short of the game on packed lanes (the lattice draws
## them for that), and a lane fed from outside what is sent empties in it between the bridge's reads; with every
## lane the simulation had short given up, the restart capture at -62,-26 had 6.1% of the game's items in view
## missing (0.8% before), the far end of `tools/belt_build_mine.py --source` flapped every 24 ticks.
static var sim_full := true
const FED_GONE_TICKS := 1800
## (tail) --belt-draw-lattice-tail=off (as before): a moving lane a packed block had filled stayed a lattice after the
## block's tail had passed it, till the bridge's next read or check of it: on a ring with a packed block going round
## (the owner's ring, tools/belt_ring.py), the lanes it had left were drawn full for about 100 ticks more, 73% of the
## slots on them phantoms. On (the default): a moving lane the simulation has short of full, or any it has none on
## (a lattice whose simulated items have all gone stands), with nothing behind its
## entry for TAIL_NEED on lanes it knows all that feeds (BeltSim.lane_tails: not a lane fed from outside what is sent,
## which empties in the simulation between reads, sim_full's reason to wait), is given up as sim_full's are.
static var tail := true
const TAIL_NEED := 2 * GAP
## (start) --belt-draw-lattice-start=off (as before): with settle, a standing lane took a new speed only once the
## simulation had had it moving for two gaps' time, from the map's phase, and a moving one stood on the
## simulation's standing front at once: a belt built at a backed-up line's end had the line's packed belts stand
## for that long while their items ran on onto it (drawn from the simulation there), each belt's front slot left
## standing at its exit and a gap opening behind the new belt's items (the owner, K16: "a bit of a gap between the
## new belt items and the previous also leaves some ghosts at the end where it is pulling forward from"), and a
## stop jumped on to where the lattice would stand. On (the default, with settle): a drawn lane whose next lane is
## new (the simulation's links changed: a belt built in front of it) lets its straight run back go (released, for
## RELEASE_TICKS): each standing lane of it the simulation then has moving starts at once, from where it stands,
## on the tick its items started (its record's clock held there before: texel 1 w). Other starts wait as settle
## has them, from the map's phase (from where it stands they cost the restart capture at -62,-26 0.4% of the
## items missing and as many phantoms: its neighbours keep the map's phase). Stops: start_stops, below.
static var start := true
## (start) --belt-draw-lattice-start=stops (off by default): every moving lane the simulation has standing also
## goes on to the tick its lattice comes to the standing front's phase and stands there (its record's clock held
## after: texel 1 y the periods from its start), standing in the lane's state once the drawn clock is there; moving
## again before that, on from the tick its items went on (go_next). The restart capture at -62,-26 (the live
## cadence): lanes drawn standing while the game's moved 19.0 -> 13.4% of the item-seconds in view, frozen spans of
## 2 s or more 1546 -> 927, lattice hops 554 -> 264 a second, but sliding while the game's stood 4.9 -> 7.2%,
## phantoms 2.2 -> 2.3%, missing 0.8 -> 1.0% (the simulation runs on lanes the game holds, which the stop at once,
## ahead of the drawn clock, hid; and a stopping lane waits for the drawn clock before it takes a read).
static var start_stops := false
const RELEASE_TICKS := 120
## Intermediate Items-in-3D cap (`500..20000`) draws nearest full-band packed lanes in 3D up to the
## unified budget (--lattice-model-cap=off restores the binary all-3D-or-all-icon check).
static var model_cap_near := true
const BAND_STEP := ItemCards.BAND_STEP
const CAP_SLACK := 1.5
const CAP_EVERY := 30
const CAM_STEP := 2.0
const CAM_TURN := 0.996
const CAM_MARGIN := 3.0
const BAND_HYST := 1.5

class Lane:
	var item := 0
	var kind_key := 0
	var slots := PackedInt32Array()
	var r0 := 0  # its phase: the front slot's line position on tick t0
	var t0 := 0
	var v := 0
	var pend_v := -1  # a new speed seen at pend_n checks in a row
	var pend_n := 0
	var pend_t := 0  # (settle) the tick pend_v was first seen at
	var hole_at := -1  # (settle) the tick of the newest hole cut in it while it stands (-1: none open)
	var hole_v := 0  # (settle) the speed the simulation has had the lane at since
	var cells := PackedInt32Array()
	var stack := 1  # records a slot: ln.slots[k * stack + j] is slot k's copy j (0: its own record)
	var who := 0  # who the item at line position r0 is on tick t0 (modulo IDS)
	var run := 0  # its run's seed (modulo IDS)
	var next := 0  # the lane its items go on into when it was drawn (BeltSim.next_of), 0 none
	var flow_q := 0  # (creep) the running share of the time most of its items move, of FLOW_ONE
	var flow_t := -1  # (creep) the tick of its last share's update
	var run_t := -1  # (creep) the tick most of its items started moving, -1 while they stand
	var creeping := false  # (creep) sliding at its share of the belt's speed
	var fu := PackedInt32Array()  # (creep_flow) its recent front items' ids (low 31 bits), oldest first
	var none_t := -1  # (creep_flow) the tick the simulation was first seen with none on it, -1 while it has
	var gated := false  # (creep_flow) stood for want of net flow: takes the simulation's speed again only with it
	var slide_at := -1  # (close) the tick a one-gap slide starts (-1: none)
	var slide_v := 0  # (close) its speed (1/256 a tick; 0: set and written with the next update)
	var slide_more := 0  # (close) slides queued after it (takes ahead while it slides)
	var step_bal := 0  # (creep_step) slides its fronts queued (+) less those close queued (-), not yet matched
	var bal_t := -1  # (creep_step) the tick step_bal last changed
	var go_lo := -1  # (start) the tick its motion started from, its record's clock held there before (-1: none)
	var go_hi := -1  # (start) the tick its motion stops, its record's clock held there after (-1: none)
	var release_t := -1  # (start) the tick its run in front was extended (-1: none): its next start is at once
	var mark_moving := false  # (mask_inner) whether its mask cells are a moving lane's (end to end)
	var open := 0  # (mask_open) its end cells left unmarked: OPEN_EXIT, OPEN_ENTRY
	var open_d := 0  # (handover) how far (1/256) its slots are off its items at its open end (0: none, or handover old)
	var go_next := -1  # (start) stopping on go_hi: the tick it goes on again from there (-1: none)


class LKind:
	var base := -1
	var cap := 0
	var top := 0
	var free: Array[int] = []
	var told := Vector3i(-1, -1, -1)


var info := {}  # lane key -> [full (bool), item id (-1: none or mixed), stack (the read's most common), the front item's position at the last read or check (-1: none)]
var drawn := {}  # lane key -> Lane
var kinds := {}  # kind key -> LKind
var records := BeltRecords.new()
var mask_tiles: Array[Image] = []
var mask_n := PackedByteArray()  # lanes marking each cell
var mask_dirty_bits := 0
var mask_sent_all := false
var lanes_n := 0  # lanes drawn after the last update
var slots_n := 0
var want := {}  # lane key -> item: lanes to draw (full of one kind, in the planned ground)
var undrawn := {}  # lane keys wanted but not drawn yet (their look not known yet)
var dirty := {}  # lane keys read, checked or dropped since the last update
var mids := {}  # lane key -> Vector2: its middle (tiles)
var planned := Rect2()
var planned_all := false
var planned_any := false
var round_no := 0
var planned_cap := -2
## (settle) The drawn clock's tick (belt_items.gd sets it before update()): a standing lane's hole closes by it.
var drawn_tick := -1
var moving_since := {}  # (settle) lane key -> the tick it was first wanted while moving, not drawn yet
var feeds := {}  # lane key -> the drawn lane whose items go on into it (its `next` when drawn)
var fed_gone := {}  # (sim_full) lane key -> the tick a belt behind it was removed (feed_gone)
var links_seen := -1  # (start) the simulation's links_ver at the last update
## The drawn clock when this update's records are first drawn (belt_items.gd Job.fold_tick; -1: the update's
## tick). The drawn clock runs behind the simulation, so a lane that starts or stops is drawn jumping by its
## speed times that lag: who its items are is matched as both lattices are drawn then (matched at the
## simulation's tick, a stop handed each slot the item behind it, a jump of over half a gap seen).
var shown := -1.0
var tight_cull := true
var cap_anchor := Vector2.ZERO
var cap_anchor_set := false
var cap_cam_led := false
var cap_cam_pos := Vector3.ZERO
var cap_cam_dir := Vector3(0.0, 0.0, -1.0)
var cap_cam_planes: Array[Plane] = []
var cap_sim_d2 := PackedFloat32Array()
var cap_sim_dirty := false
var cap_round := 0
var capped_anchor := Vector2.INF
var capped_cam := false
var capped_cam_pos := Vector3.ZERO
var capped_cam_dir := Vector3(0.0, 0.0, -1.0)
var cap_3d_slots := 0
var cap_eligible_slots := 0
var cap_limit_d2 := INF
var lod_split := false
var lod_anchor := Vector3.ZERO
var lod_d1 := INF
var lod_d2 := INF
var lod_jit := Vector2.ZERO
var lod_band_at := Vector3.INF
var lod_d1_seen := INF
var lod_d2_seen := INF
var lod_split_seen := false
var lane_keys := {}  # lane key -> target kind_key (cap + distance band)


func set_tight_cull(v: bool) -> void:
	tight_cull = v


## Sets the focus anchor/frustum and current simulated-item squared distances for unified 3D capping.
func set_cap_anchor(anchor: Vector2, cam_led: bool, cam_pos: Vector3, cam_dir: Vector3,
		cam_planes: Array[Plane], sim_d2: PackedFloat32Array) -> void:
	cap_anchor = anchor
	cap_anchor_set = true
	cap_cam_led = cam_led
	cap_cam_pos = cam_pos
	cap_cam_dir = cam_dir
	cap_cam_planes = cam_planes
	if sim_d2.size() != cap_sim_d2.size():
		cap_sim_dirty = true
	cap_sim_d2 = sim_d2


## Configures distance-band MultiMesh bucketing parameters for packed lattice lanes.
func set_lod_bands(split: bool, anchor: Vector3, d1: float, d2: float, jit: Vector2) -> void:
	lod_split = split
	lod_anchor = anchor
	lod_d1 = d1
	lod_d2 = d2
	lod_jit = jit


## A lane read in full (`sl`): items as [uid, item id, pos, stack] four a lane item, front first.
func note_read(key: int, length: int, items: PackedInt64Array) -> void:
	var n := items.size() / 4
	if n == 0:
		info[key] = [false, -1, 1, -1]
		dirty[key] = true
		return
	dirty[key] = true
	var item := int(items[1])
	var front := int(items[2])
	var full := n >= maxi(1, length / GAP)
	var counts := PackedInt32Array()
	counts.resize(MAX_STACK + 1)
	for j in n:
		counts[clampi(int(items[j * 4 + 3]), 1, MAX_STACK)] += 1
		if j == 0:
			continue
		if int(items[j * 4 + 1]) != item:
			info[key] = [false, -1, 1, front]
			return
		if int(items[j * 4 + 2]) - int(items[j * 4 - 2]) > GAP + 2:
			full = false
	var stack := 1
	for c in range(2, MAX_STACK + 1):
		if counts[c] > counts[stack]:
			stack = c
	info[key] = [full, item, stack, front]


## A lane's drift check (`pc`): count, smallest and largest position.
func note_check(key: int, length: int, count: int, front: int, back: int) -> void:
	var e: Array = info.get(key, [false, -1, 1, -1])
	e[0] = count >= maxi(1, length / GAP) and count <= length / GAP + 2 and back - front <= (GAP + 2) * (count - 1)
	if e.size() < 4:
		e.append(-1)
	e[3] = front if count > 0 else -1
	info[key] = e
	dirty[key] = true


## (standing_obs) The front item's position at the bridge's last read or check of the lane, -1 none.
func _obs_front(key: int) -> int:
	var e: Array = info.get(key, [])
	return int(e[3]) if e.size() > 3 else -1


func drop(key: int) -> void:
	info.erase(key)
	fed_gone.erase(key)
	mids.erase(key)
	moving_since.erase(key)
	dirty[key] = true


## (sim_full) A belt behind lane `key` was removed on tick `tick` (a belt mined inside the square): what comes in
## at its back is what was on the run between, so the simulation's count of it holds for FED_GONE_TICKS.
func feed_gone(key: int, tick: int) -> void:
	fed_gone[key] = tick


## Whether any lane is drawn as a lattice now (belt_items.gd: the update runs while any is, the switch off too).
func has_drawn() -> bool:
	return not drawn.is_empty()


## The update after a job's simulation: lanes in or out of the lattice, phases made again. Returns
## {written: [[kind key, base, n, cap], ...], pages, mask (Image or null), unknown: [kind keys], added and
## removed: the lanes it began and stopped drawing (PackedInt64Array; belt_items.gd's records park and count
## the items they hide)}; with `dump`, dump_ids / dump_recs / dump_gone as belt_items.gd's --belt-draw-dump
## writes them.
func update(job_state, sim, tick: int, view: Rect2, view_all: bool, known: Dictionary, model_cap: int, full: bool,
		dump: bool) -> Dictionary:
	var lanes: Dictionary = job_state.lanes
	var res := {"written": [], "unknown": [], "dump_ids": PackedInt64Array(), "dump_recs": PackedFloat32Array(),
		"dump_gone": PackedInt64Array(), "mask_tiles": [], "mask_all": false, "dump_on": dump, "removed_keys": {}, "added_keys": {}}
	records.base = job_state.records.base
	# Which lanes to draw: all again when the planned ground or the look changed, else only those the
	# bridge said something about.
	var keep: float = clampf(maxf(view.size.x, view.size.y) * 0.15, 2.0, 8.0) if tight_cull else VIEW_KEEP
	var shrunk := tight_cull and not view_all and planned_any \
		and (planned.size.x > view.size.x + 2.0 * keep + 6.0 or planned.size.y > view.size.y + 2.0 * keep + 6.0)
	var replan := full or view_all != planned_all or not planned_any or (not view_all and (not planned.encloses(view) or shrunk)) \
		or model_cap != planned_cap
	var prev_cap := planned_cap
	var look_at: Array
	if replan:
		planned_cap = model_cap
		planned = view.grow(keep)
		planned_all = view_all
		planned_any = true
		want.clear()
		undrawn.clear()
		lane_keys.clear()
		look_at = info.keys()
		for key: int in drawn:
			if not info.has(key):
				look_at.append(key)
	else:
		look_at = dirty.keys()
	# (A lane's stacks change only with a read: a drawn lane checked for its phase alone keeps its own.)
	var heard := dirty
	dirty = {}
	var check := {}  # lanes to draw or check now
	for key: int in look_at:
		var item := _wanted(job_state, key, lanes)
		if item < 0:
			want.erase(key)
			undrawn.erase(key)
			lane_keys.erase(key)
		else:
			want[key] = item
			check[key] = true
			if not drawn.has(key):
				undrawn[key] = true
	var unknown := {}
	for key: int in (drawn.keys() if replan else look_at):
		if not drawn.has(key):
			continue
		var ln: Lane = drawn[key]
		if not want.has(key) or int(want[key]) != ln.item:
			_remove(key, res)
			if want.has(key):
				undrawn[key] = true
	cap_round += 1
	var anchor := cap_anchor if cap_anchor_set else (view.get_center() if not view_all else Vector2.ZERO)
	var cap_moved := replan or model_cap != prev_cap or cap_sim_dirty or not undrawn.is_empty() or cap_round >= CAP_EVERY \
		or (model_cap > 0 and model_cap_near and (cap_cam_led != capped_cam \
		or (cap_cam_led and (cap_cam_pos.distance_squared_to(capped_cam_pos) > CAM_STEP * CAM_STEP or cap_cam_dir.dot(capped_cam_dir) < CAM_TURN)) \
		or (not cap_cam_led and anchor.distance_squared_to(capped_anchor) > CAM_STEP * CAM_STEP)))
	var band_moved := replan or lod_split != lod_split_seen or not is_equal_approx(lod_d1, lod_d1_seen) \
		or not is_equal_approx(lod_d2, lod_d2_seen) \
		or (lod_split and (lod_band_at == Vector3.INF or lod_anchor.distance_squared_to(lod_band_at) > 16.0))
	if cap_moved or band_moved:
		if cap_moved:
			cap_round = 0
			cap_sim_dirty = false
			capped_cam = cap_cam_led
			capped_cam_pos = cap_cam_pos
			capped_cam_dir = cap_cam_dir
			capped_anchor = anchor
		if band_moved:
			lod_split_seen = lod_split
			lod_d1_seen = lod_d1
			lod_d2_seen = lod_d2
			lod_band_at = lod_anchor
		_plan_lane_keys(job_state, lanes, known, model_cap, anchor, check)
	else:
		for key_u: int in undrawn:
			var item_u := int(want.get(key_u, -1))
			if item_u >= 0 and not lane_keys.has(key_u):
				var mid_u := _lane_mid(job_state, key_u, lanes[key_u])
				var kk_u := _compute_lane_key(key_u, item_u, mid_u, job_state.height, known, model_cap, true)
				lane_keys[key_u] = kk_u
				check[key_u] = true
	# A slice of the drawn lanes has its phase checked against the simulation's each update.
	round_no += 1
	var slice := round_no % SLICES
	for key: int in drawn:
		if unison or posmod(key >> 3, SLICES) == slice:
			check[key] = true
	for key: int in undrawn:
		check[key] = true
	var keys := PackedInt64Array()
	for key: int in check:
		if want.has(key):
			keys.append(key)
	var fronts: PackedInt32Array = sim.lane_fronts(keys) if not keys.is_empty() else PackedInt32Array()
	# (turn_id) Each lane's front item's number.
	var nums: PackedInt32Array = sim.lane_fronts(keys, 3) if turn_id and item_turns and not keys.is_empty() else PackedInt32Array()
	# (tail) Whether a packed block's tail has gone onto each lane, nothing close behind it.
	var tails: PackedInt32Array = sim.lane_tails(keys, TAIL_NEED) if tail and not keys.is_empty() else PackedInt32Array()
	# (creep) The speed most of each lane's items move at.
	var lane_v: PackedInt32Array = sim.lane_fronts(keys, 2 if creep_flow or creep_step else 1) 		if (creep or creep_step) and not keys.is_empty() else PackedInt32Array()
	# (mask_open) The simulation's front item on each lane it has one on: where its items are.
	var front_at := {}
	if mask_open and mask_own:
		for q in keys.size():
			if fronts[q * 3 + 2] > 0:
				front_at[keys[q]] = fronts[q * 3]
	# (start) The simulation's links changed (lane_fronts linked them): a drawn lane whose next lane is new lets its
	# run back go.
	if start and settle and sim != null and int(sim.links_ver) != links_seen:
		links_seen = int(sim.links_ver)
		for key2: int in drawn.keys():
			var l2: Lane = drawn[key2]
			var nx := int(sim.next_of(key2))
			if nx == l2.next:
				continue
			if l2.next != 0 and feeds.get(l2.next, 0) == key2:
				feeds.erase(l2.next)
			l2.next = nx
			if nx != 0:
				feeds[nx] = key2
				_release_behind(key2, tick)
	var base: float = records.base
	for q in keys.size():
		var key := keys[q]
		var item: int = want[key]
		var m: PackedInt32Array = lanes[key]
		var ln: Lane = drawn.get(key)
		var kk: int = ln.kind_key if ln != null else int(lane_keys.get(key, _kind_key(item, model_cap)))
		var lk := _look_key(kk)
		var look: Array = known.get(lk, [])
		if look.is_empty():
			unknown[lk] = true
			continue
		if ln == null and kk >= 0 and not bool(look[1]) and ItemCards.band_of(kk) > 0:
			kk = item
			lane_keys[key] = kk
		var f := fronts[q * 3]
		var v := fronts[q * 3 + 1]
		var has := fronts[q * 3 + 2] > 0
		var wl := world and (m[0] == BeltSim.STRAIGHT or m[0] == BeltSim.UG_VISIBLE or world_all and (m[0] == BeltSim.CURVE
			or m[0] == BeltSim.SPLIT_IN or m[0] == BeltSim.SPLIT_OUT))
		# (standing_obs: the game's front on the lane at its last read or check, -1 none.)
		var obs := _obs_front(key) if standing_obs else -1
		var st := _stack_of(key) if ln == null or replan or heard.has(key) else ln.stack
		var short := fronts[q * 3 + 2] < maxi(1, m[1] / GAP)
		if ln != null and ((ln.v > 0 and short and has) or (BeltSim.take_sync and (not has or (ln.v > 0 and short)))) and sim_full and fed_gone.has(key) \
				and tick - int(fed_gone[key]) <= FED_GONE_TICKS \
				or tail and tails.size() > q and tails[q] == 1 and (not has or short and (ln == null or ln.v > 0)):
			# (sim_full) Moving, and the simulation has it short of full: the line behind it ended or is gone;
			# (tail) or a packed block's tail went onto it (or past it: none left there, the lattice standing then)
			# with nothing close behind.
			var e: Array = info.get(key, [])
			if not e.is_empty():
				e[0] = false
			want.erase(key)
			if ln != null:
				_remove(key, res)
			continue
		# (creep_step sees the lanes in this update's check: all of them with unison on, the default.)
		if creep_step and close and settle and ln != null and q * 3 + 2 < lane_v.size():
			_creep_step(ln, lane_v[q * 3 + 2], m[2], f, v, has, tick)
		if close and settle and ln != null and ln.slide_at >= 0:
			# (close) A slide a take ahead asked for: written at its belt's speed (a lane whose standing slots
			# aren't a moving lane's stands, as before); once the drawn clock is past it, standing a gap on.
			if ln.v > 0:
				_slide_clear(ln)
			elif ln.slide_v == 0:
				var n_stand := 0
				var qs := ln.r0
				while qs < m[1]:
					n_stand += 1
					qs += GAP
				if m[2] <= 0 or n_stand != maxi(1, ceili(float(m[1]) / GAP)):
					_slide_clear(ln)
				else:
					ln.slide_v = m[2]
					_write_lane(job_state, key, ln, m, look, base, res, ln.stack)
			elif drawn_tick >= ln.slide_at + _slide_ticks(ln):
				_slide_done(ln)
				_write_lane(job_state, key, ln, m, look, base, res, ln.stack)
		if start and settle and ln != null:
			if ln.release_t >= 0 and tick - ln.release_t > RELEASE_TICKS:
				ln.release_t = -1
			if ln.go_hi >= 0:
				# (start) Stopping on go_hi: standing on its phase then, once the drawn clock is there. Moving again
				# before that: on from the tick its items went on (go_next, from its phase at go_hi), or on as it was
				# when that is go_hi's (no stop at all: a stop-and-go lane's pause drawn, not run through).
				if has and v > 0 and ln.go_next < 0:
					var t_next := tick - roundi(float(posmod(_phase_at(ln, ln.go_hi) - f, GAP)) / float(v))
					if t_next <= ln.go_hi + 1 and v == ln.v:
						ln.go_hi = -1
						_write_lane(job_state, key, ln, m, look, base, res, ln.stack)
					else:
						ln.go_next = maxi(t_next, ln.go_hi + 1)
				if ln.go_hi >= 0:
					if drawn_tick >= ln.go_hi:
						var hi := ln.go_hi
						var nxt := ln.go_next
						_set_motion(ln, _phase_at(ln, hi), 0, hi)
						ln.go_next = -1
						if nxt >= 0 and has and v > 0:
							_set_motion(ln, ln.r0, v, nxt)
							ln.go_lo = nxt
							ln.pend_n = 0
							ln.pend_v = -1
						_write_lane(job_state, key, ln, m, look, base, res, ln.stack)
						if nxt >= 0 and has and v > 0:
							continue
					else:
						continue
		if settle and ln != null and ln.hole_at >= 0:
			# (The hole a take left: closed once the drawn clock is a gap's time past it.)
			if has and v > 0:
				ln.hole_v = v
			if ln.v > 0:
				ln.hole_at = -1  # (a moving lane's holes end with their slots' periods)
			elif drawn_tick >= ln.hole_at + (ceili(float(GAP) / float(ln.hole_v)) if ln.hole_v > 0 else HOLE_TICKS):
				ln.hole_at = -1
				_write_lane(job_state, key, ln, m, look, base, res, ln.stack)
		if close and settle and ln != null and ln.v == 0 and ln.slide_at >= 0:
			continue  # (close) Sliding: the simulation's front (or a read) mid-way through the closing says nothing new.
		# (A lane whose stacks changed is made again with its new piles, its phase as a new lane's.)
		if ln != null and ln.stack == st:
			if creep and creep_flow:
				# (creep_flow) A moving lane the simulation has had none on for NONE_TICKS (at once, creeping)
				# stands where it is drawn: it went on as it was for good.
				if has:
					ln.none_t = -1
				elif ln.v > 0:
					if ln.none_t < 0:
						ln.none_t = tick
					if tick - ln.none_t >= NONE_TICKS or (not has and ln.creeping):
						var td1 := _t_draw(tick)
						_creep_stop(ln, _phase_at(ln, td1), td1)
						_write_lane(job_state, key, ln, m, look, base, res, st)
						continue
			if not has:
				# (The simulation has none there: the lattice goes on as it was; a standing one is set to a
				# new observation of the lane.)
				if not (obs >= 0 and ln.v == 0 and heard.has(key) and posmod(obs, GAP) != ln.r0):
					continue
			else:
				var pred := posmod(ln.r0 - ln.v * (tick - ln.t0), GAP)
				if creep and q * 3 + 2 < lane_v.size():
					if (_creep_flow(ln, lane_v[q * 3 + 1], lane_v[q * 3 + 2], m[2], tick, pred, f) if creep_flow
							else _creep(ln, lane_v[q * 3 + 1], m[2], tick, pred, f)):
						_write_lane(job_state, key, ln, m, look, base, res, st)
						continue
					if ln.creeping:
						continue  # (sliding at its share: the simulation's stops and starts aren't taken)
					if creep_flow and ln.v > 0 and tick - ln.t0 >= FLOW_GATE_TICKS and ln.flow_q < FLOW_GATE:
						# (creep_flow) At the simulation's speed this long, its items hardly went on past its exit
						# (fronts it had coming back with reads): the simulation runs it where the game's stands.
						var td3 := _t_draw(tick)
						_set_motion(ln, _phase_at(ln, td3), 0, td3)
						ln.pend_v = -1
						ln.pend_n = 0
						ln.gated = true
						_write_lane(job_state, key, ln, m, look, base, res, st)
						continue
				if v != ln.v:
					if v == ln.pend_v:
						ln.pend_n += 1
					else:
						ln.pend_v = v
						ln.pend_n = 1
						ln.pend_t = tick
					if ln.pend_n < (1 if unison else SPEED_CHECKS):
						continue
					var released := start and settle and ln.v == 0 and v > 0 and ln.release_t >= 0 and ln.slide_at < 0
					if settle and ln.v == 0 and not released and (tick - ln.pend_t) * v <= SETTLE_GAPS * GAP:
						continue  # (a line closing a hole: a gap on it stands again, the same picture)
					if start and start_stops and settle and ln.v > 0 and v == 0 and not ln.creeping:
						# (start) Stopping: on to the tick its lattice comes to the simulation's standing front's phase.
						var over := posmod(ln.v * (tick - ln.t0) - (ln.r0 - f), GAP)
						var t_stop := tick - roundi(float(over) / float(ln.v))
						if t_stop > drawn_tick and t_stop > maxi(ln.t0, ln.go_lo):
							ln.pend_n = 0
							ln.pend_v = -1
							if ln.go_lo < 0:
								ln.go_lo = ln.t0
							ln.go_hi = t_stop
							_write_lane(job_state, key, ln, m, look, base, res, st)
							continue
					if ln.gated and ln.flow_q >= FLOW_GATE:
						ln.gated = false
					if ln.v == 0 and ln.gated:
						continue  # (creep_flow: stood for want of net flow; moves again with it)
					if released:
						# (start) Its run in front extended: on from where it stands, from the tick its items started
						# (the latest with the simulation's front where it is now). Its record's clock held there
						# before (go_lo), so the lattice doesn't run back from the update's tick to the drawn clock.
						var t_go := tick - roundi(float(posmod(ln.r0 - f, GAP)) / float(v))
						ln.pend_n = 0
						ln.pend_v = -1
						ln.release_t = -1
						_set_motion(ln, ln.r0, v, t_go)
						ln.go_lo = t_go
						_write_lane(job_state, key, ln, m, look, base, res, st)
						continue
					# (Its new speed from where it is drawn now; the map's phase at it, world. Stopping, it
					# keeps where it is drawn: the game's standing phase comes with the lane's next read or
					# check, obs; settle: it stands on the simulation's standing front at once.)
					ln.pend_n = 0
					ln.pend_v = -1
					_set_motion(ln, posmod(_world_phase(m) - v * tick, GAP) if wl and v > 0 else (posmod(f, GAP) if settle and v == 0 else pred),
						v, tick)
					_write_lane(job_state, key, ln, m, look, base, res, st)
					continue
				ln.pend_n = 0
				ln.pend_v = -1
				if settle and ln.v == 0:
					obs = f  # (the simulation's front stands on the lane: its phase, not a read's mid-way)
				if ln.v == 0 and obs >= 0:
					if posmod(obs, GAP) == ln.r0:
						continue  # (standing at the game's phase)
				else:
					var off := absi(pred - posmod(f, GAP))
					var in_step := mini(off, GAP - off) <= DRIFT
					if wl or in_step:  # (wl: the map's phase, nothing drifts)
						# (wl: its items up to half a gap off its slots; who they are is told while clear of the half.)
						in_step = mini(off, GAP - off) <= (SEED_WL if wl else DRIFT)
						# (turn_id) Moving in step, but who its items are off the simulation's (a line's items a little
						# more than a gap apart count up slower than its slots): seeded again, its slots written again.
						# (A standing lane isn't: settle and close stand it a gap or more behind its run on purpose, the
						# picture and its items' turns kept, K19, nor one moving for less than SEED_AFTER: started late on
						# purpose, its run already gone on. Nor one on a ring, whose numbers jump once round it.)
						if in_step and ln.v > 0 and tick - ln.t0 >= SEED_AFTER and not nums.is_empty() and has and nums[q * 3 + 2] >= 0 \
								and _seed_who(ln, f, nums[q * 3 + 2], tick) != ln.who and not _ring(sim, key) \
								and _seed(ln, f, nums[q * 3 + 2], tick):
							_write_lane(job_state, key, ln, m, look, base, res, st)
						continue
		var fresh := ln == null
		if fresh:
			if settle:
				# (Moving: drawn only once it has moved for longer than a line closing a hole does.)
				if has and v > 0:
					var since: int = moving_since.get(key, -1)
					if since < 0:
						moving_since[key] = tick
						continue
					if (tick - since) * v <= SETTLE_GAPS * GAP:
						continue
				moving_since.erase(key)
			ln = Lane.new()
			ln.item = item
			ln.kind_key = kk
			drawn[key] = ln
			undrawn.erase(key)
			_mark(job_state, key, ln, 1)
			res["added_keys"][key] = true
		var nv := 0
		var nr0 := 0
		if wl:
			nv = v if has else 0
			nr0 = posmod(_world_phase(m) - nv * tick, GAP)
		elif has:
			nr0 = posmod(f, GAP)
			nv = v
		else:
			nr0 = _world_phase(m)
		if settle and has and v == 0:
			obs = f
		if nv == 0 and obs >= 0:
			nr0 = posmod(obs, GAP)  # (standing: where the game last showed the lane's items)
		if fresh:
			ln.r0 = nr0
			ln.v = nv
			ln.t0 = tick
			_identify(job_state, sim, key, ln, m, tick)
		else:
			_set_motion(ln, nr0, nv, tick)
		# (turn_id: from the simulation's front item, but on a ring as before, carried from lane to lane.)
		if not nums.is_empty() and has and nums[q * 3 + 2] >= 0 and not _ring(sim, key):
			_seed(ln, f, nums[q * 3 + 2], tick)
		_write_lane(job_state, key, ln, m, look, base, res, st)
	for key: int in drawn:
		var ln: Lane = drawn[key]
		var target_kk: int = int(lane_keys.get(key, ln.kind_key))
		if target_kk == ln.kind_key:
			continue
		var lk := _look_key(target_kk)
		var look: Array = known.get(lk, [])
		if look.is_empty():
			unknown[lk] = true
			continue
		if target_kk >= 0 and not bool(look[1]) and ItemCards.band_of(target_kk) > 0:
			target_kk = ln.item
			lane_keys[key] = target_kk
			if target_kk == ln.kind_key:
				continue
		var m_rekey: PackedInt32Array = lanes.get(key, PackedInt32Array())
		if m_rekey.is_empty():
			continue
		_rekey_lane(key, ln, target_kk, res)
		_write_lane(job_state, key, ln, m_rekey, look, base, res, ln.stack)
	_open_ends(job_state, sim, known, base, res, front_at, tick)
	if tight_cull:
		for kk in kinds:
			_compact_kind(int(kk), kinds[kk] as LKind)
	for kk in kinds:
		var kd: LKind = kinds[kk]
		var told := Vector3i(kd.base, kd.top, kd.cap)
		if full or told != kd.told:
			kd.told = told
			res["written"].append([kk, kd.base, kd.top, kd.cap])
	res["unknown"] = unknown.keys()
	res["pages"] = records.take_pages()
	var dirty_tiles: Array = []
	var send_all := false
	if mask_dirty_bits != 0 and mask_tiles.size() == MASK_TILES:
		send_all = not mask_sent_all or not mask_tiled
		mask_sent_all = true
		var bits := 0xFFFF if send_all else mask_dirty_bits
		mask_dirty_bits = 0
		for ti in MASK_TILES:
			if (bits & (1 << ti)) != 0:
				dirty_tiles.append([ti, mask_tiles[ti]])
	res["mask_tiles"] = dirty_tiles
	res["mask_all"] = send_all
	lanes_n = drawn.size()
	slots_n = 0
	for kk in kinds:
		slots_n += (kinds[kk] as LKind).top - (kinds[kk] as LKind).free.size()
	# (A lane removed and drawn again in the same update, its kind changed, neither.)
	var removed_keys: Dictionary = res["removed_keys"]
	var del := PackedInt64Array()
	for key: int in removed_keys:
		if not drawn.has(key):
			del.append(key)
	var add := PackedInt64Array()
	for key: int in res["added_keys"]:
		if not removed_keys.has(key) and drawn.has(key):
			add.append(key)
	res["removed"] = del
	res["added"] = add
	res.erase("removed_keys")
	res.erase("added_keys")
	return res


## (mask_open) Each drawn lane's ends left unmarked for the lanes beside it and the simulation's phase now (`front_at`,
## its front item's position on the lanes it has one on): a lane whose ends changed is marked again, and written
## again, so the dump says so (ids column 7).
func _open_ends(job_state, sim, known: Dictionary, base: float, res: Dictionary, front_at: Dictionary, tick: int) -> void:
	var lanes: Dictionary = job_state.lanes
	for key: int in drawn:
		var ln: Lane = drawn[key]
		var o := 0
		if mask_open and mask_own and ln.v > 0 and front_at.has(key):
			# (Its slots less the simulation's items, -32..31: below 0 its slots are ahead, nearer the exit.)
			var off := posmod(_phase_at(ln, tick) - int(front_at[key]) + GAP / 2, GAP) - GAP / 2
			if off < -OPEN_TOL:
				var down: Lane = drawn.get(ln.next) if ln.next != 0 and ln.next != key else null
				if (down == null or down.v != ln.v) and (not edge_shut or sim == null or bool(sim.leads_on(key))):
					o = OPEN_EXIT
			elif off > OPEN_TOL:
				var up_key: int = feeds.get(key, 0)
				var up: Lane = drawn.get(up_key) if up_key != 0 and up_key != key else null
				if up == null or up.v != ln.v:
					o = OPEN_ENTRY
		# (handover) The phases' difference the open end's slot hides by.
		var od := 0
		if handover and o != 0:
			od = posmod(_phase_at(ln, tick) - int(front_at[key]) + GAP / 2, GAP) - GAP / 2
			od = -od if o == OPEN_EXIT else od
		if o == ln.open and od == ln.open_d or not lanes.has(key):
			continue
		ln.open_d = od
		if o != ln.open:
			_unmark(ln)
			ln.open = o
			_mark(job_state, key, ln, 0)
		var look: Array = known.get(_look_key(ln.kind_key), [])
		if not look.is_empty():
			_write_lane(job_state, key, ln, lanes[key], look, base, res, ln.stack)


## (handover) A moving lane's slot k's texel 3 y: where in its period it hides at its lane's open end, its item drawn
## by the simulation there (0: never). Slot k slides from 64 (k + 1) to 64 k; its item is open_d behind it at an open
## exit (shown by the simulation once in the cell [0, 64)), open_d ahead at an open entry (in the cell [length - 64,
## length)).
static func _hand_code(ln: Lane, k: int, length: int) -> float:
	if ln.open_d <= 0 or ln.v <= 0:
		return 0.0
	if ln.open & OPEN_EXIT:
		return -(1.0 + minf(1.0, float(ln.open_d + HAND_SLACK) / GAP)) if k == 0 else 0.0
	if ln.open & OPEN_ENTRY:
		var h := float(GAP * (k + 2) - length - ln.open_d - HAND_SLACK) / GAP
		return -(3.0 + minf(h, 1.0)) if h > 0.0 else 0.0
	return 0.0


## How high a lane's piles are drawn: its last read's most common stack (1 with --belt-draw-lattice-pile=off).
func _stack_of(key: int) -> int:
	if not piles:
		return 1
	var e: Array = info.get(key, [])
	return clampi(int(e[2]), 1, MAX_STACK) if e.size() > 2 else 1


## The item a lane is drawn as a lattice of, or -1: full of one kind, of a kind drawn so, in the planned
## ground.
func _wanted(job_state, key: int, lanes: Dictionary) -> int:
	if not on:
		return -1
	var e: Array = info.get(key, [])
	if e.is_empty() or not e[0] or int(e[1]) < 0:
		return -1
	var m: PackedInt32Array = lanes.get(key, PackedInt32Array())
	if m.is_empty() or not _drawn_kind(m[0]) or m[1] <= 0 or m[1] > MAX_LENGTH:
		return -1
	if not planned_all:
		var mid := _lane_mid(job_state, key, m)
		if not planned.has_point(mid):
			return -1
	return int(e[1])


func _lane_mid(job_state, key: int, m: PackedInt32Array) -> Vector2:
	if mids.has(key):
		return mids[key]
	var p := _point(job_state, key, m[1] * 0.5)
	var mid := Vector2(p.x, p.z)
	mids[key] = mid
	return mid


static func _look_key(kk: int) -> int:
	return kk if kk < 0 else (kk % BAND_STEP)


static func _hash_u32(x: int) -> float:
	var h := (x ^ (x >> 16)) & 0xFFFFFFFF
	h = (h * 0x45d9f3b) & 0xFFFFFFFF
	h = (h ^ (h >> 16)) & 0xFFFFFFFF
	return float(h & 0xFFFF) / 65536.0


static func _view_dist_sq(p: Vector3, cpos: Vector3, planes: Array[Plane], margin: float) -> float:
	for pl in planes:
		if pl.distance_to(p) > margin:
			return INF
	return cpos.distance_squared_to(p)


static func band_for_dist(id: int, d: float, d1: float, d2: float, jit: Vector2, cur_band: int) -> int:
	if d2 <= 0.0:
		return 2
	if not is_finite(d1):
		return 0
	var j := _hash_u32(id) - 0.5
	var t2 := (d2 + j * jit.y) if is_finite(d2) else INF
	if d1 <= 0.0:
		if cur_band < 1:
			return 1 if d < t2 else 2
		if cur_band == 1:
			return 2 if is_finite(t2) and d >= t2 + BAND_HYST else 1
		return 1 if is_finite(t2) and d < t2 - BAND_HYST else 2
	var t1 := d1 + j * jit.x
	if cur_band < 0:
		return 0 if d < t1 else (1 if d < t2 else 2)
	if cur_band == 0:
		if d < t1 + BAND_HYST:
			return 0
		return 1 if d < t2 else 2
	if cur_band == 1:
		if d < t1 - BAND_HYST:
			return 0
		if is_finite(t2) and d >= t2 + BAND_HYST:
			return 2
		return 1
	if d < t1 - BAND_HYST:
		return 0
	if is_finite(t2) and d < t2 - BAND_HYST:
		return 1
	return 2


func _band_for(key: int, mid: Vector2, h: float, cur_band: int) -> int:
	return band_for_dist(key, Vector3(mid.x, h, mid.y).distance_to(lod_anchor), lod_d1, lod_d2, lod_jit, cur_band)


func _compute_lane_key(key: int, item: int, mid: Vector2, h: float, known: Dictionary, _model_cap: int, is_3d: bool) -> int:
	if not is_3d:
		return ItemCards.icon_key(item)
	if not lod_split:
		return item
	var look: Array = known.get(item, [])
	if not look.is_empty() and not bool(look[1]):
		return item
	var ln: Lane = drawn.get(key)
	var cur_band := ItemCards.band_of(ln.kind_key) if ln != null and ln.kind_key >= 0 else -1
	return ItemCards.band_key(item, _band_for(key, mid, h, cur_band))


func _plan_lane_keys(job_state, lanes: Dictionary, known: Dictionary, model_cap: int, anchor: Vector2, check: Dictionary) -> void:
	cap_3d_slots = 0
	cap_eligible_slots = 0
	cap_limit_d2 = INF
	var h: float = job_state.height
	if model_cap == 0 or (model_cap > 0 and not model_cap_near):
		cap_limit_d2 = -1.0
		for key_v in want:
			var key := int(key_v)
			var item := int(want[key])
			var look: Array = known.get(item, [])
			var icon_only := not look.is_empty() and not bool(look[1])
			if not icon_only and lanes.has(key):
				var mv: PackedInt32Array = lanes[key]
				cap_eligible_slots += maxi(1, ceili(float(mv[1]) / float(GAP))) * _stack_of(key)
			var target := item if icon_only else ItemCards.icon_key(item)
			lane_keys[key] = target
			var ln: Lane = drawn.get(key)
			if ln != null and ln.kind_key != target:
				check[key] = true
		return
	if model_cap < 0:
		for key_v in want:
			var key := int(key_v)
			var item := int(want[key])
			if not lanes.has(key):
				continue
			var mv: PackedInt32Array = lanes[key]
			var look: Array = known.get(item, [])
			var icon_only := not look.is_empty() and not bool(look[1])
			if not icon_only:
				var sl := maxi(1, ceili(float(mv[1]) / float(GAP))) * _stack_of(key)
				cap_eligible_slots += sl
				cap_3d_slots += sl
			var mid := _lane_mid(job_state, key, mv)
			var target := _compute_lane_key(key, item, mid, h, known, model_cap, true)
			lane_keys[key] = target
			var ln: Lane = drawn.get(key)
			if ln != null and ln.kind_key != target:
				check[key] = true
		return
	var cands: Array = []
	for key_v in want:
		var key := int(key_v)
		if not lanes.has(key):
			continue
		var item := int(want[key])
		var mv: PackedInt32Array = lanes[key]
		var mid := _lane_mid(job_state, key, mv)
		var look: Array = known.get(item, [])
		if not look.is_empty() and not bool(look[1]):
			lane_keys[key] = item
			continue
		var sl := maxi(1, ceili(float(mv[1]) / float(GAP))) * _stack_of(key)
		cap_eligible_slots += sl
		var ln: Lane = drawn.get(key)
		var was_3d := ln != null and ln.kind_key >= 0
		var d2: float
		if cap_cam_led:
			d2 = _view_dist_sq(Vector3(mid.x, h, mid.y), cap_cam_pos, cap_cam_planes, CAM_MARGIN + (CAP_SLACK if was_3d else 0.0))
		else:
			d2 = anchor.distance_squared_to(mid)
		cands.append([d2, key, item, mid, sl, was_3d])
	cands.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var li := 0
	var si := 0
	var used := 0
	var limit_d2 := -1.0
	var all_within := true
	while li < cands.size() or si < cap_sim_d2.size():
		var cand_d2 := float((cands[li] as Array)[0]) if li < cands.size() else INF
		if cand_d2 == INF and si >= cap_sim_d2.size():
			break
		var take_lat := si >= cap_sim_d2.size() or (li < cands.size() and cand_d2 <= cap_sim_d2[si])
		if take_lat:
			if cand_d2 == INF:
				all_within = false
				break
			var sl := int((cands[li] as Array)[4])
			if used < model_cap:
				used += sl
				limit_d2 = cand_d2
				li += 1
			else:
				all_within = false
				break
		else:
			if used < model_cap:
				used += 1
				limit_d2 = cap_sim_d2[si]
				si += 1
			else:
				all_within = false
				break
	if all_within:
		limit_d2 = INF
	cap_limit_d2 = limit_d2
	var keep_d2 := limit_d2 if (limit_d2 == INF or limit_d2 < 0.0) else pow(sqrt(limit_d2) + CAP_SLACK, 2.0)
	for entry_v in cands:
		var entry: Array = entry_v
		var d2 := float(entry[0])
		var key := int(entry[1])
		var item := int(entry[2])
		var mid := entry[3] as Vector2
		var sl := int(entry[4])
		var was_3d := bool(entry[5])
		var want_3d := d2 < INF and d2 <= (keep_d2 if was_3d else limit_d2)
		if want_3d:
			cap_3d_slots += sl
		var target := _compute_lane_key(key, item, mid, h, known, model_cap, want_3d)
		lane_keys[key] = target
		var ln: Lane = drawn.get(key)
		if ln != null and ln.kind_key != target:
			check[key] = true


static func _drawn_kind(kind: int) -> bool:
	return kind == BeltSim.STRAIGHT or kind == BeltSim.CURVE or kind == BeltSim.UG_VISIBLE or kind == BeltSim.SPLIT_IN \
		or kind == BeltSim.SPLIT_OUT


## Its kind key as belt_items.gd's: the item, or its icon past an Items in 3D cap.
static func _kind_key(item: int, model_cap: int) -> int:
	return item if model_cap < 0 else ItemCards.icon_key(item)


## A lane the simulation has no item on: a lattice fixed to the map along its exit's direction, so the
## lanes of a straight run agree.
static func _world_phase(m: PackedInt32Array) -> int:
	return posmod(_world_tau(m), GAP)


## Where a lane's exit is along the way its items leave (1/256 tile; the next lane's exit is a belt further).
static func _world_tau(m: PackedInt32Array) -> int:
	var dx := m[3] - m[5]
	var dy := m[4] - m[6]
	if absi(dx) >= absi(dy):
		return m[3] if dx > 0 else -m[3]
	return m[4] if dy > 0 else -m[4]


## A run's seed from the map: its lane's place across the way its items leave, and that way, so the
## lanes of one run share it and the lanes beside it (the belt's other lane, the next belt) don't.
static func _world_run(m: PackedInt32Array) -> int:
	var dx := m[3] - m[5]
	var dy := m[4] - m[6]
	if absi(dx) >= absi(dy):
		return posmod(m[4] * 4 + (0 if dx > 0 else 1), IDS)
	return posmod(m[3] * 4 + (2 if dy > 0 else 3), IDS)


## a / b rounded down (integers).
static func _fdiv(a: int, b: int) -> int:
	return (a - posmod(a, b)) / b


## A drawn lane's new motion from `tick` (its phase r0 and speed v): who its items are carries over, each
## new slot taking the nearest old item's as both are drawn when the update is (the old lattice's identity
## function at the slot's place, rounded), so a lane that starts, stops or has its phase made again keeps
## its items' turns.
## (creep) The lane's running share of the time most of its items move (lv: their speed now, step the
## belt's), and whether it creeps: starts sliding at its share of the belt's speed from where it is drawn
## (pred), changes that speed by more than a quarter, or stops creeping: below CREEP_OFF with its items
## standing it slides on until its phase meets the simulation's standing front (f) and stands there (no
## jump); moving steadily, back to the usual rules (which take the simulation's speed). True when its
## motion was set and it is to be written again.
func _creep(ln: Lane, lv: int, step: int, tick: int, pred: int, f: int) -> bool:
	if ln.flow_t >= 0 and tick > ln.flow_t:
		var dt := tick - ln.flow_t
		ln.flow_q += ((FLOW_ONE if lv > 0 else 0) - ln.flow_q) * dt / (dt + CREEP_TAU)
	ln.flow_t = tick
	if lv <= 0:
		ln.run_t = -1
	elif ln.run_t < 0:
		ln.run_t = tick
	var cv := maxi(1, (ln.flow_q * maxi(1, step) + FLOW_ONE / 2) / FLOW_ONE)
	if ln.creeping:
		if ln.run_t >= 0 and (tick - ln.run_t) * lv > CREEP_RUN_GAPS * GAP:
			ln.creeping = false
			ln.pend_v = -1
			ln.pend_n = 0
			return false
		if ln.flow_q < CREEP_OFF:
			if lv > 0:
				return false  # (its items moving now: it stops once they stand)
			if posmod(pred - f, GAP) > ln.v:
				return false  # (on to the standing front's phase)
			ln.creeping = false
			ln.pend_v = -1
			ln.pend_n = 0
			_set_motion(ln, posmod(f, GAP), 0, tick)
			return true
		if absi(cv - ln.v) * 4 > ln.v:
			_set_motion(ln, pred, cv, tick)
			return true
		return false
	if ln.v == 0 and ln.flow_q >= CREEP_ON and not (ln.run_t >= 0 and (tick - ln.run_t) * lv > SETTLE_GAPS * GAP):
		ln.creeping = true
		_set_motion(ln, pred, cv, tick)
		return true
	return false


## (creep_flow) As _creep, by the net distance its items went on past its exit (u: the simulation's front
## item on it now, lv the speed most of its items move at, step the belt's).
func _creep_flow(ln: Lane, lv: int, u: int, step: int, tick: int, _pred: int, f: int) -> bool:
	_front_flow(ln, u, tick)
	if lv <= 0:
		ln.run_t = -1
	elif ln.run_t < 0:
		ln.run_t = tick
	var cv := clampi(_fdiv(ln.flow_q + FLOW_ONE / 2, FLOW_ONE), 1, maxi(1, step))
	# (Its new motion from the drawn clock's tick, where it is drawn then: set at the simulation's tick, the
	# lattice was drawn jumping by the change of speed times the drawn clock's lag behind it.)
	var td := _t_draw(tick)
	var pd := _phase_at(ln, td)
	if ln.creeping:
		if ln.run_t >= 0 and (tick - ln.run_t) * lv > CREEP_RUN_GAPS * GAP:
			ln.creeping = false
			ln.pend_v = -1
			ln.pend_n = 0
			return false
		if ln.flow_q < CREEP_FLOW_OFF:
			if lv > 0:
				return false  # (its items moving now: it stops once they stand)
			if posmod(pd - f, GAP) > ln.v:
				return false  # (on to the standing front's phase)
			ln.creeping = false
			ln.pend_v = -1
			ln.pend_n = 0
			_set_motion(ln, posmod(f, GAP), 0, td)
			return true
		if absi(cv - ln.v) * 4 > ln.v:
			_set_motion(ln, pd, cv, td)
			return true
		return false
	if ln.v == 0 and ln.flow_q >= CREEP_FLOW_ON and not (ln.run_t >= 0 and (tick - ln.run_t) * lv > SETTLE_GAPS * GAP):
		ln.creeping = true
		_set_motion(ln, pd, cv, td)
		return true
	return false


## (creep_flow, creep_step) The net distance (1/256) the lane's items went on past its exit since its last front
## (u: the simulation's front item on it now): a gap for a front it hasn't had, a gap back for each front since one it
## had (a read put the items back); its running rate flow_q updated with it, flow_t set to `tick`.
func _front_flow(ln: Lane, u: int, tick: int) -> int:
	var dd := 0
	var n := ln.fu.size()
	if n == 0 or ln.fu[n - 1] != u:
		var back := -1
		for j in range(n - 2, -1, -1):
			if ln.fu[j] == u:
				back = j
				break
		if back >= 0:
			dd = -GAP * (n - 1 - back)  # (a front it had: a read put the items back)
			ln.fu.resize(back + 1)
		else:
			if n > 0:
				dd = GAP
			ln.fu.append(u)
			if ln.fu.size() > FLOW_HIST:
				ln.fu.remove_at(0)
	if ln.flow_t >= 0 and tick > ln.flow_t:
		var dt := tick - ln.flow_t
		ln.flow_q = maxi(0, ln.flow_q + _fdiv(dd * FLOW_ONE - ln.flow_q * dt, dt + CREEP_TAU))
	elif ln.flow_t < 0 or tick == ln.flow_t:
		ln.flow_q = maxi(0, ln.flow_q + _fdiv(dd * FLOW_ONE, CREEP_TAU))
	ln.flow_t = tick
	return dd


## (creep_step) A new front item (u) on a standing lane queues a one-gap slide from the tick its items moved (f, fv:
## the simulation's front's place and speed; step the belt's speed), unless close slid it for that take already.
func _creep_step(ln: Lane, u: int, step: int, f: int, fv: int, has: bool, tick: int) -> void:
	if not has:
		return
	var prev_t := ln.flow_t
	var dd := _front_flow(ln, u, tick)
	if dd < 0:
		# (A read put the simulation's items back: slides not written yet are dropped. Owing the rest, so that the
		# simulation running on again slides nothing, measured: fewer slides while the game's items stood, more
		# frozen, as the game's own moves were owed too.)
		var nb := _fdiv(-dd, GAP)
		while nb > 0 and ln.slide_more > 0:
			ln.slide_more -= 1
			ln.step_bal = maxi(ln.step_bal - 1, 0)
			nb -= 1
		if nb > 0 and ln.slide_at >= 0 and ln.slide_v == 0:
			_slide_clear(ln)
			ln.step_bal = maxi(ln.step_bal - 1, 0)
			nb -= 1
		return
	if dd == 0 or ln.v != 0 or ln.creeping or step <= 0:
		return
	if ln.flow_q * 2 >= step * FLOW_ONE:
		return  # (at half the belt's speed or more: the usual rules take the simulation's speed)
	if ln.bal_t >= 0 and absi(tick - ln.bal_t) > STEP_BAL_TICKS:
		ln.step_bal = 0
	ln.bal_t = tick
	# Gaps the line went on since the last update: one a new front, more while its front still moves from more than
	# a gap behind its rest phase (takes since the last update the closing hasn't caught up with; a closing over by
	# this update counts one: the front's place no longer tells, nor does its id, the items between unknown).
	var k := 1
	var moved := posmod(ln.r0 - f, GAP)
	if fv > 0 and f > ln.r0:
		k = clampi(_fdiv(f - ln.r0 - 1, GAP) + 1, 1, CLOSE_MORE + 1)
		moved = ln.r0 + k * GAP - f
	while k > 0 and ln.step_bal < 0:
		ln.step_bal += 1  # (close slid it for this take)
		k -= 1
		moved = maxi(0, moved - GAP)
	if k <= 0:
		return
	ln.step_bal = mini(ln.step_bal + k, CLOSE_MORE)
	var t_s := 0
	if fv > 0:
		t_s = tick - _fdiv(2 * moved + fv, 2 * fv)  # (moving from k gaps behind its rest phase)
	else:
		t_s = tick - _fdiv(GAP + step - 1, step)  # (at rest again: moved since the last update)
		if prev_t >= 0 and prev_t < t_s:
			t_s = _fdiv(prev_t + t_s, 2)
	if ln.slide_at < 0:
		ln.slide_at = t_s
		ln.slide_v = 0
		ln.slide_more = mini(k - 1, CLOSE_MORE)
	else:
		ln.slide_more = mini(ln.slide_more + k, CLOSE_MORE)


## (creep_flow) The tick a creeping lane's new motion starts from: the drawn clock's (not before its last).
func _t_draw(tick: int) -> int:
	return drawn_tick if creep_flow and drawn_tick >= 0 and drawn_tick <= tick else tick


## A drawn lane's phase on tick t.
static func _phase_at(ln: Lane, t: int) -> int:
	return posmod(ln.r0 - ln.v * (_held_t(ln, t) - ln.t0) - _slide_moved(ln, t), GAP)


## (start) Tick t on a lane's held clock: not before its motion's start (go_lo), not after its stop (go_hi).
static func _held_t(ln: Lane, t: int) -> int:
	var c := t
	if ln.go_hi >= 0:
		c = mini(c, ln.go_hi)
	if ln.go_lo >= 0:
		c = maxi(c, ln.go_lo)
	return c


## (close) How far (1/256) a lane's slide has gone by tick t: 0 to a gap.
static func _slide_moved(ln: Lane, t: int) -> int:
	if ln.slide_at < 0 or ln.slide_v <= 0:
		return 0
	return clampi(ln.slide_v * (t - ln.slide_at), 0, GAP)


## (close) Ticks a lane's slide takes (whole ticks).
static func _slide_ticks(ln: Lane) -> int:
	return ceili(float(GAP) / float(maxi(1, ln.slide_v)))


## (close) A slide over: standing a gap on, each slot the item that was behind it; the next queued, if any.
func _slide_done(ln: Lane) -> void:
	ln.who = posmod(ln.who + 1, IDS)
	if ln.slide_more > 0:
		ln.slide_more -= 1
		ln.slide_at += _slide_ticks(ln)
	else:
		_slide_clear(ln)


func _slide_clear(ln: Lane) -> void:
	ln.slide_at = -1
	ln.slide_v = 0
	ln.slide_more = 0


## (start) Lane `key`'s next lane is new: it and its straight run back (feeds), each released for RELEASE_TICKS.
func _release_behind(key: int, tick: int) -> void:
	var k := key
	for _i in 4096:
		var l: Lane = drawn.get(k)
		if l == null:
			return
		l.release_t = tick
		var up: int = feeds.get(k, 0)
		if up == 0 or up == key:
			return
		var lu: Lane = drawn.get(up)
		if lu == null or lu.next != k:
			return
		k = up


## (close) A take on tick `at` from lane `key` (standing, or not drawn): the drawn standing lanes behind it,
## its straight run back (feeds), each a slide of a gap from then (written with the next update), or one more
## after the slide it has.
func _close_behind(key: int, at: int) -> void:
	var down := key
	for _i in 4096:
		var up_key: int = feeds.get(down, 0)
		if up_key == 0 or up_key == key:
			return
		var up: Lane = drawn.get(up_key)
		if up == null or up.next != down or up.v != 0 or up.creeping:
			return
		if creep_step:
			# (creep_step) Its front's change already slid it for this take: not again.
			if up.bal_t >= 0 and absi(at - up.bal_t) > STEP_BAL_TICKS:
				up.step_bal = 0
			up.bal_t = at
			if up.step_bal > 0:
				up.step_bal -= 1
				down = up_key
				continue
			up.step_bal = maxi(up.step_bal - 1, -CLOSE_MORE)
		if up.slide_at >= 0 and up.slide_v > 0 and up.slide_more == 0 and at >= up.slide_at + _slide_ticks(up):
			_slide_done(up)  # (its slide over by the take: standing a gap on)
		if up.slide_at < 0:
			up.slide_at = at
			up.slide_v = 0
			up.slide_more = 0
		else:
			up.slide_more = mini(up.slide_more + 1, CLOSE_MORE)
		dirty[up_key] = true
		down = up_key


## (creep) A lane no longer creeping, standing at phase r0 from `tick`, its share forgotten.
func _creep_stop(ln: Lane, r0: int, tick: int) -> void:
	ln.creeping = false
	ln.pend_v = -1
	ln.pend_n = 0
	ln.flow_q = 0
	ln.flow_t = -1
	ln.run_t = -1
	ln.fu.clear()
	_set_motion(ln, r0, 0, tick)


func _set_motion(ln: Lane, r0: int, v: int, tick: int) -> void:
	# (close: a slide's way so far counts as moved; the new motion replaces what is left of it.)
	ln.who = posmod(ln.who + _fdiv(r0 + ln.v * (_held_t(ln, tick) - ln.t0) + _slide_moved(ln, tick) - ln.r0 + _lag(ln.v - v, tick)
		+ GAP / 2, GAP), IDS)
	_slide_clear(ln)
	ln.go_lo = -1
	ln.go_hi = -1
	ln.go_next = -1
	ln.r0 = r0
	ln.v = v
	ln.t0 = tick


## How much further (1/256) a lane at speed `dv` more than another goes between the update's tick and when it
## is drawn (`shown`), rounded: what the matching of who items are adds for the drawn clock's lag.
func _lag(dv: int, tick: int) -> int:
	return roundi(float(dv) * (shown - float(tick))) if shown >= 0.0 and dv != 0 else 0


## Who a new lane's items are (its r0, v and t0 set): the drawn lane they go on into (`next`) or the drawn
## lane they come from, its identity function carried across their meeting so an item crossing keeps its
## turn; else the map's along the exit's direction (items at the map's phase are who they were wherever
## a lane of their run was written). Notes the lane as feeding its next.
func _identify(job_state, sim, key: int, ln: Lane, m: PackedInt32Array, tick: int) -> void:
	ln.next = int(sim.next_of(key)) if sim != null else 0
	var down: Lane = drawn.get(ln.next) if ln.next != 0 and ln.next != key else null
	var dm: PackedInt32Array = job_state.lanes.get(ln.next, PackedInt32Array()) if down != null else PackedInt32Array()
	var up_key: int = feeds.get(key, 0)
	var up: Lane = drawn.get(up_key) if up_key != 0 and up_key != key else null
	if down != null and dm.size() > 1:
		# (An item at this lane's q is at the next lane's q + its length.)
		ln.who = posmod(down.who + _fdiv(dm[1] + ln.r0 + down.v * (tick - down.t0) + _slide_moved(down, tick) - down.r0
			+ _lag(down.v - ln.v, tick) + GAP / 2, GAP), IDS)
		ln.run = down.run
	elif up != null:
		# (An item at the feeding lane's q is at this lane's q + this lane's length.)
		ln.who = posmod(up.who + _fdiv(up.v * (tick - up.t0) + _slide_moved(up, tick) - up.r0 - m[1] + ln.r0 + _lag(up.v - ln.v, tick)
			+ GAP / 2, GAP), IDS)
		ln.run = up.run
	else:
		ln.who = posmod(_fdiv(ln.r0 - _world_tau(m) + ln.v * tick + GAP / 2, GAP), IDS)
		ln.run = _world_run(m)
	if ln.next != 0:
		feeds[ln.next] = key


## (turn_id) Who a lane's items are from the simulation's front item on it, number `num` at lane position `at` on
## `tick`: the slot nearest it is that item, the slots behind it the numbers after. Whether that changed it.
func _seed(ln: Lane, at: int, num: int, tick: int) -> bool:
	var w := _seed_who(ln, at, num, tick)
	if w == ln.who and ln.run == TURN_RUN:
		return false
	ln.who = w
	ln.run = TURN_RUN
	return true


## (turn_id) Who the lane's item at r0 on t0 is, from item `num` at `at` on `tick`.
static func _seed_who(ln: Lane, at: int, num: int, tick: int) -> int:
	return posmod(num - _fdiv(at + ln.v * (_held_t(ln, tick) - ln.t0) + _slide_moved(ln, tick) - ln.r0 + GAP / 2, GAP), IDS)


## (turn_id) Whether lane `key` is on a ring of lanes (its items come back to it): the simulation's numbers jump once
## round a ring, so the lattice keeps the identity it carries from lane to lane there.
static func _ring(sim, key: int) -> bool:
	if sim == null:
		return false
	var k := int(sim.next_of(key))
	for i in 256:
		if k == key:
			return true
		if k == 0:
			return false
		k = int(sim.next_of(k))
	return false


func _rekey_lane(key: int, ln: Lane, new_kk: int, res: Dictionary) -> void:
	var old_kd: LKind = kinds.get(ln.kind_key)
	for i in ln.slots.size():
		if old_kd != null:
			records.hide(old_kd.base + ln.slots[i])
			old_kd.free.append(ln.slots[i])
		if i % ln.stack == 0:
			res["dump_gone"].append(_uid(key, i / ln.stack))
	ln.slots.clear()
	ln.kind_key = new_kk


func _remove(key: int, res: Dictionary) -> void:
	var ln: Lane = drawn[key]
	drawn.erase(key)
	if ln.next != 0 and feeds.get(ln.next, 0) == key:
		feeds.erase(ln.next)
	if res.has("removed_keys"):
		res["removed_keys"][key] = true
	var kd: LKind = kinds.get(ln.kind_key)
	for i in ln.slots.size():
		if kd != null:
			records.hide(kd.base + ln.slots[i])
			kd.free.append(ln.slots[i])
		if i % ln.stack == 0:
			res["dump_gone"].append(_uid(key, i / ln.stack))
	_unmark(ln)


static func _uid(key: int, k: int) -> int:
	return -(key * 8 + k + 1)


## The lane's slots: one record each, every GAP from its phase; sliding a gap a period, or standing.
## A moving lane's slot k cycles within its own gap of the lane, [64k, 64k + 64), so a lane's lattice
## never runs past its ends onto the next lane's (whose phase can differ): ceil(length / 64) slots, the
## last one's gap reaching past a curve's entry. A standing lane's slots stand on its phase.
## With stacks of `stack`, each slot is a pile: its record and stack - 1 copies pointing at it (written
## when placed: they follow the slot's record wherever it is written again).
func _write_lane(job_state, key: int, ln: Lane, m: PackedInt32Array, look: Array, base: float, res: Dictionary,
		stack := 1) -> void:
	var length := m[1]
	if length <= 0 or length > MAX_LENGTH:
		return
	var moving := ln.v > 0
	if mask_inner and not mask_own and moving != ln.mark_moving and not ln.cells.is_empty():
		# (mask_inner) Started or stopped moving: its mask cells a moving or a standing lane's.
		_unmark(ln)
		ln.mark_moving = moving
		_mark(job_state, key, ln, 0)
	var n := 0
	if moving:
		n = maxi(1, ceili(float(length) / GAP))
	else:
		var q := ln.r0
		while q < length:
			n += 1
			q += GAP
	# (close) Sliding a gap: a moving lane's slots on a clock held to the slide (its standing slots are those).
	var sliding := not moving and close and ln.slide_at >= 0 and ln.slide_v > 0 and n == maxi(1, ceili(float(length) / GAP))
	var kd: LKind = kinds.get(ln.kind_key)
	if kd == null:
		kd = LKind.new()
		kinds[ln.kind_key] = kd
	if stack != ln.stack:
		# (Its piles' height changed: every slot placed again.)
		while not ln.slots.is_empty():
			_drop_slot(key, ln, kd, res)
		ln.stack = stack
	var st := ln.stack
	while ln.slots.size() > n * st:
		_drop_slot(key, ln, kd, res)
	var placed := ln.slots.size()
	while ln.slots.size() < n * st:
		var s: int
		if not kd.free.is_empty():
			s = kd.free.pop_back()
		else:
			s = kd.top
			kd.top += 1
			if kd.top > kd.cap or kd.base < 0:
				var cap := BeltRecords.MIN_RUN
				while cap < kd.top:
					cap *= 2
				var nb := records.alloc(cap)
				if kd.base >= 0:
					records.copy(kd.base, nb, kd.cap)
					records.release(kd.base, kd.cap)
				for i in range(kd.cap, cap):
					records.hide(nb + i)
				kd.base = nb
				kd.cap = cap
		ln.slots.append(s)
	var lift: Vector3 = look[0]
	var pile_step := float(look[2]) if look.size() > 2 else 0.07
	var period := float(GAP) / float(ln.v) if moving else (float(GAP) / float(ln.slide_v) if sliding else 0.0)
	var ends := _ends(job_state, key, length)
	# (Its clock from where slot k is at 64k + r0 on tick t0: the shader's fract() starts at (64 - r0) / 64.)
	var t_start := float(ln.t0) - base
	var t_hold := 0.0
	var periods := 0.0  # (close, start) how long the held clock runs from t_hold (texel 1 y), 0: on and on
	# (start) A motion that started at once or stops: its clock held from its start (go_lo, else t0) and, stopping,
	# go_hi's periods after it, a 256th of a period on as a slide's.
	var held := moving and start and (ln.go_lo >= 0 or ln.go_hi >= 0)
	if moving:
		t_start -= float(GAP - ln.r0) / float(GAP) * period
		if held:
			var lo := ln.go_lo if ln.go_lo >= 0 else ln.t0
			t_start += period / 256.0
			t_hold = float(lo) - base
			if ln.go_hi >= 0:
				periods = float(ln.go_hi - lo) / period
	elif sliding:
		# (close) From the slide's start, where slot k stands at 64k + r0, a 256th of a period on (a slot on a
		# cell's edge, r0 0, starts and ends there, not a gap on); held from then to a period after (texel 1 w, y).
		t_hold = float(ln.slide_at) - base
		t_start = t_hold - float(GAP - ln.r0) / float(GAP) * period + period / 256.0
		periods = 1.0
	# (Taken out while written: written through a second reference, the whole array was copied each lane.)
	var d := records.data
	records.data = PackedFloat32Array()
	for k in n:
		var top := float(GAP * (k + 1)) if moving or sliding else float(ln.r0 + GAP * k)
		var p := _along(job_state, key, top, length, ends)
		var to := _along(job_state, key, float(GAP * k), length, ends) if moving or sliding else p
		var uid := _uid(key, k)
		# Turned as every item is, icon cards too: by who its item is (the shader adds the periods slid and
		# hashes it with the run, ItemCards.lattice_turn), or (slot turns) by the slot (ItemCards.turn_for).
		var c := float(posmod(ln.who + k, IDS)) if item_turns else cos(ItemCards.turn_for(uid))
		var s := float(ln.run) if item_turns else sin(ItemCards.turn_for(uid))
		var r := kd.base + ln.slots[k * st]
		var o := r * BeltRecords.FLOATS
		d[o] = p.x
		d[o + 1] = p.y
		d[o + 2] = p.z
		d[o + 3] = t_start
		if period > 0.0:
			d[o + 4] = to.x - p.x
			d[o + 5] = periods  # (a slot slides on the ground: texel 1 y is its held clock's run, belt_path.gdshaderinc)
			d[o + 6] = to.z - p.z
		else:
			d[o + 4] = 0.0
			d[o + 5] = 0.0
			d[o + 6] = 0.0
		d[o + 7] = t_hold if sliding or held else t_start
		d[o + 8] = c
		d[o + 9] = s
		d[o + 10] = lift.y + LAYER_STEP * (posmod(uid, LAYERS))
		d[o + 11] = 0.0 if p.w >= 0.5 else BeltRecords.HIDDEN
		d[o + 12] = 0.0
		d[o + 13] = _hand_code(ln, k, length) if moving else 0.0  # (handover) where it hides at an open end
		d[o + 14] = 2.0 if item_turns else 1.0  # a lattice slot (not masked); 2: texel 2 says who its item is
		d[o + 15] = period
		records.dirty[r / records.per_page] = true
		# Its pile's copies, when placed: PILE_TURN more each than the slot's turn, k pile steps up, read from
		# the slot's record by the shader (slot turns: their own, texel 2).
		for j in range(1, st):
			var i := k * st + j
			if i < placed:
				continue
			var rc := kd.base + ln.slots[i]
			var oc := rc * BeltRecords.FLOATS
			for q in BeltRecords.FLOATS:
				d[oc + q] = 0.0
			if not item_turns:
				var ca := ItemCards.turn_for(uid, j)
				d[oc + 8] = cos(ca)
				d[oc + 9] = sin(ca)
			d[oc + 12] = float(r - rc)
			d[oc + 13] = float(j)
			d[oc + 14] = pile_step
			records.dirty[rc / records.per_page] = true
		if bool(res["dump_on"]):
			res["dump_ids"].append_array(PackedInt64Array([uid, ln.item, st, key, ln.r0 + GAP * k, ln.t0, ln.v, ln.open]))
			res["dump_recs"].append_array(d.slice(o, o + BeltRecords.FLOATS))
	records.data = d


## (--inserter-handoff) A hand took the item at line position `pos` of lane `key` on tick `at`: a drawn
## lane's lattice gets the hole it leaves (each slot's own record, texel 3 x: hidden from that tick to the
## end of its period, the shader). A moving lane's slot k cycles within its own gap, so the hole is slot k
## from the take to its wrap, then slot k - 1 for a period, and so on to the lane's exit; a standing lane's
## stays at slot k. Until the lane is written again (a new phase or speed) or given up (the bridge's read
## after the take finds it not full: drawn from the simulation, which took the item off on the same tick).
## Returns {dump_ids, dump_recs} of the slots written, with `dump` (belt_items.gd --belt-draw-dump).
func hole(key: int, at: int, pos: int, dump: bool) -> Dictionary:
	var res := {"dump_ids": PackedInt64Array(), "dump_recs": PackedFloat32Array()}
	var ln: Lane = drawn.get(key)
	if close and settle and (ln == null or ln.v <= 0):
		# (close) The standing line behind closes the hole up; the take's lane, short of full now, is drawn from
		# the simulation (its items behind the hole move on, those ahead stand) until a read finds it full again.
		_close_behind(key, at)
		if ln != null:
			var e: Array = info.get(key, [])
			if not e.is_empty():
				e[0] = false
			dirty[key] = true
	elif BeltSim.take_sync and close and settle and ln != null and ln.v > 0:
		# (take_sync) A take on a moving packed lane exits it from the lattice and propagates fed_gone downstream
		# so the lane and those ahead don't refill the taken gap with phantoms until pc.
		var e: Array = info.get(key, [])
		if not e.is_empty():
			e[0] = false
		dirty[key] = true
		if sim_full:
			fed_gone[key] = at
			var nx: int = ln.next
			var guard := 0
			while nx != 0 and nx != key and guard < 256:
				fed_gone[nx] = at
				var nln: Lane = drawn.get(nx)
				nx = nln.next if nln != null else 0
				guard += 1
	if ln == null or records.base < 0.0:
		return res
	var kd: LKind = kinds.get(ln.kind_key)
	if kd == null or kd.base < 0:
		return res
	var n := ln.slots.size() / ln.stack
	if n <= 0:
		return res
	var base := records.base
	var d := records.data
	records.data = PackedFloat32Array()
	var sp := 0.0  # (close) the period of the slide it is in at the take, 0: none
	if close and ln.v <= 0 and ln.slide_at >= 0 and ln.slide_v > 0 and at >= ln.slide_at \
			and float(at) < float(ln.slide_at) + float(GAP) / float(ln.slide_v):
		sp = float(GAP) / float(ln.slide_v)
	if ln.v <= 0 and sp <= 0.0:
		var k := roundi(float(pos - ln.r0) / float(GAP))
		if k >= 0 and k < n:
			_hole_slot(key, ln, kd, d, k, float(at) - base, res, dump)
			ln.hole_at = maxi(ln.hole_at, at)
			ln.hole_v = 0
	elif ln.v <= 0:
		# (close) Taken while it slides: slot k until the slots wrap, then the one ahead, which keeps it to the
		# slide's end (its clock held there).
		var ts := float(ln.slide_at) - float(GAP - ln.r0) / float(GAP) * sp + sp / 256.0
		var q := (float(at) - ts) / sp
		var idx := floorf(q)
		var k := roundi((float(pos) - float(GAP) * (1.0 - (q - idx))) / float(GAP))
		for j in range(mini(k, n - 1), maxi(-1, k - 2 + int(idx)), -1):
			var h := float(at) if j == k else ts + (idx + float(k - j)) * sp + 0.01
			_hole_slot(key, ln, kd, d, j, h - base, res, dump)
		ln.hole_at = maxi(ln.hole_at, at)
		ln.hole_v = 0
	else:
		var period := float(GAP) / float(ln.v)
		var ts := float(ln.t0) - float(GAP - ln.r0) / float(GAP) * period
		var q := (float(at) - ts) / period
		var idx := floorf(q)
		var k := roundi((float(pos) - float(GAP) * (1.0 - (q - idx))) / float(GAP))
		for j in range(mini(k, n - 1), -1, -1):
			var h := float(at) if j == k else ts + (idx + float(k - j)) * period + 0.01
			_hole_slot(key, ln, kd, d, j, h - base, res, dump)
	records.data = d
	return res


func _hole_slot(key: int, ln: Lane, kd: LKind, d: PackedFloat32Array, k: int, h: float, res: Dictionary, dump: bool) -> void:
	var r := kd.base + ln.slots[k * ln.stack]
	var o := r * BeltRecords.FLOATS
	d[o + 12] = h
	records.dirty[r / records.per_page] = true
	if dump:
		res["dump_ids"].append_array(PackedInt64Array([_uid(key, k), ln.item, ln.stack, key, ln.r0 + GAP * k, ln.t0, ln.v, ln.open]))
		res["dump_recs"].append_array(d.slice(o, o + BeltRecords.FLOATS))


## The lane's last record let go (hidden, its slot free); a slot's own record's going is dumped.
func _drop_slot(key: int, ln: Lane, kd: LKind, res: Dictionary) -> void:
	var i := ln.slots.size() - 1
	var s := ln.slots[i]
	records.hide(kd.base + s)
	kd.free.append(s)
	if i % ln.stack == 0:
		res["dump_gone"].append(_uid(key, i / ln.stack))
	ln.slots.resize(i)


func _compact_kind(kk: int, kd: LKind) -> void:
	if kd == null or kd.base < 0 or kd.top <= 0 or kd.free.is_empty():
		return
	var live := 0
	var owned: Array = []
	for ln_var in drawn.values():
		var ln: Lane = ln_var
		if ln.kind_key == kk and not ln.slots.is_empty():
			live += ln.slots.size()
			owned.append(ln)
	if live > 0 and (kd.free.size() <= 16 or kd.free.size() * 2 <= kd.top):
		return
	var old_top := kd.top
	if live == 0:
		for i in range(old_top):
			records.hide(kd.base + i)
		kd.top = 0
		kd.free.clear()
		return
	var d: PackedFloat32Array = records.data
	records.data = PackedFloat32Array()
	var tmp := PackedFloat32Array()
	tmp.resize(live * BeltRecords.FLOATS)
	var next := 0
	for ln_var in owned:
		var ln: Lane = ln_var
		var st := maxi(ln.stack, 1)
		var slots: PackedInt32Array = ln.slots
		for i in range(slots.size()):
			var s_old := slots[i]
			var src_o := (kd.base + s_old) * BeltRecords.FLOATS
			var dst_o := next * BeltRecords.FLOATS
			for q in BeltRecords.FLOATS:
				tmp[dst_o + q] = d[src_o + q]
			var j := i % st
			if j > 0:
				tmp[dst_o + 12] = float(-j)
			slots[i] = next
			next += 1
		ln.slots = slots
	var base_o := kd.base * BeltRecords.FLOATS
	for k in tmp.size():
		d[base_o + k] = tmp[k]
	records.data = d
	for i in range(live, old_top):
		records.hide(kd.base + i)
	records._mark_range(kd.base, old_top)
	kd.top = live
	kd.free.clear()


## A lane's exit and entry and the way items go there: [exit, direction there, entry, direction there].
static func _ends(job_state, key: int, length: int) -> Array:
	var exit := _point(job_state, key, 0.0)
	var ahead := _point(job_state, key, minf(32.0, float(length)))
	var entry := _point(job_state, key, float(length))
	var behind := _point(job_state, key, maxf(0.0, float(length) - 32.0))
	return [exit, Vector2(exit.x - ahead.x, exit.z - ahead.z).normalized(), entry,
		Vector2(behind.x - entry.x, behind.z - entry.z).normalized()]


## _point, carried on straight past either end.
static func _along(job_state, key: int, pos: float, length: int, ends: Array) -> Vector4:
	if pos < 0.0:
		var e: Vector4 = ends[0]
		var dv: Vector2 = ends[1]
		return Vector4(e.x - dv.x * pos / 256.0, e.y, e.z - dv.y * pos / 256.0, e.w)
	if pos > float(length):
		var e: Vector4 = ends[2]
		var dv: Vector2 = ends[3]
		var past := (pos - float(length)) / 256.0
		return Vector4(e.x - dv.x * past, e.y, e.z - dv.y * past, e.w)
	return _point(job_state, key, pos)


## Where line position `pos` of lane `key` is: belt_items.gd's Job._point.
static func _point(job_state, key: int, pos: float) -> Vector4:
	var m: PackedInt32Array = job_state.lanes.get(key, PackedInt32Array())
	if m.is_empty():
		return Vector4(0.0, job_state.height, 0.0, 0.0)
	var f := clampf(pos / float(maxi(m[1], 1)), 0.0, 1.0)
	var x: float
	var y: float
	if m[0] == BeltSim.CURVE and job_state.arcs.has(key) and not (job_state.arcs[key] as PackedFloat64Array).is_empty():
		var arc: PackedFloat64Array = job_state.arcs[key]
		var a := arc[3] + arc[4] * f
		x = arc[0] + cos(a) * arc[2]
		y = arc[1] + sin(a) * arc[2]
	else:
		x = lerpf(float(m[3]), float(m[7]), f)
		y = lerpf(float(m[4]), float(m[8]), f)
	return Vector4(x / 256.0, job_state.height, y / 256.0, 0.0 if m[0] == BeltSim.UG_HIDDEN else 1.0)


## The mask's cells along a lane's centre line (sampled every 1/32 tile).
func _mark(job_state, key: int, ln: Lane, _add: int) -> void:
	if mask_tiles.size() != MASK_TILES:
		mask_tiles.resize(MASK_TILES)
		for ti in MASK_TILES:
			mask_tiles[ti] = Image.create(MASK_TILE, MASK_TILE, false, Image.FORMAT_R8)
		mask_n = PackedByteArray()
		mask_n.resize(MASK * MASK)
	var m: PackedInt32Array = job_state.lanes[key]
	var length := clampi(m[1], 0, MAX_LENGTH)
	var seen := {}
	var steps := maxi(1, length / 8)
	var inner := mask_own or mask_inner and not ln.mark_moving
	# (mask_open) Its open ends' cells (a gap at each) left out; a lane too short for both keeps its middle's.
	var lo := float(GAP) + 4.0 if ln.open & OPEN_EXIT else 4.0
	var hi := float(length) - (float(GAP) + 4.0 if ln.open & OPEN_ENTRY else 4.0)
	if ln.open != 0 and lo > hi:
		lo = float(length) * 0.5
		hi = lo
	for j in steps + 1:
		# (mask_inner, standing: its entry end's point a 64th of a tile inside, so it marks no cell of the lane behind;
		# mask_own: its exit's too, moving or standing)
		var at := float(length) * j / steps
		if inner:
			at = minf(at, float(length) - 4.0)
		if mask_own:
			at = clampf(at, lo, maxf(hi, lo))
		var p := _point(job_state, key, at)
		var cx := posmod(floori(p.x * CELLS), MASK)
		var cz := posmod(floori(p.z * CELLS), MASK)
		var c := cz * MASK + cx
		if seen.has(c):
			continue
		seen[c] = true
		ln.cells.append(c)
		if mask_n[c] < 255:
			mask_n[c] += 1
		if mask_n[c] == 1:
			var ti := (cz >> 9) * 4 + (cx >> 9)
			mask_tiles[ti].set_pixel(cx & 511, cz & 511, Color(1.0, 0.0, 0.0))
			mask_dirty_bits |= 1 << ti


func _unmark(ln: Lane) -> void:
	for c in ln.cells:
		if mask_n[c] > 0:
			mask_n[c] -= 1
			if mask_n[c] == 0:
				var cx := int(c) % MASK
				var cz := int(c) / MASK
				var ti := (cz >> 9) * 4 + (cx >> 9)
				mask_tiles[ti].set_pixel(cx & 511, cz & 511, Color(0.0, 0.0, 0.0))
				mask_dirty_bits |= 1 << ti
	ln.cells = PackedInt32Array()


## Every lane given up (the lattice switched off, a reset): records hidden, the mask cleared.
func clear(res_gone: PackedInt64Array) -> void:
	var res := {"dump_gone": res_gone}
	for key: int in drawn.keys():
		_remove(key, res)
	feeds.clear()
	lane_keys.clear()
	cap_3d_slots = 0
	cap_eligible_slots = 0
	cap_limit_d2 = INF
