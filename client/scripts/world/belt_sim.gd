extends RefCounted
## The client's copy of Factorio's belts (docs/BELT-SIM-PLAN.md): a port of tools/belt_sim/sim.py,
## the reference that matches the game item for item (docs/BELT-RULES.md §8), stepped tick by tick
## from what the bridge sends (`bs`: lane meta, lanes read in full, drift checks, belts switched off).
## Runs on a worker thread; nothing here touches the scene.
##
## The rules are sim.py's, in whole 1/256 steps: lanes are the game's transport lines, joined by
## geometry (a lane goes on into the lane whose entry is at its exit; side-loads; splitters) or by
## the next lane the bridge names; each tick lanes are stepped front first (a ring started anywhere,
## the lane in front not stepped yet counting as having moved its step); an item moves its step but
## never closes the gap to the item in front below 64 nor below what it already was; onto a belt of
## another speed by time, rounded down.
##
## For speed it doesn't step items one by one (FFF #176). Lanes are joined into lines: straight runs
## of one speed and direction, each lane the only feeder of the next. A line's items are its front
## position and the gaps behind it; each tick an item moves as far as the item ahead did plus the
## slack of its gap over 64, up to its step, so a line moves by its front alone, and a blocked line
## only shrinks its first loose gap. Lines whose motion is known ahead aren't stepped at all: a line
## flowing freely translates (only its front position changes, worked out when asked), a blocked one
## shrinks one gap, and one that can't move sleeps; each has the tick at which it must be stepped
## again (its front reaches its end, the item ahead could hold it), and changes ahead wake the lines
## behind (each line's back is a promise: where it will be, how fast).
##
## Output (take_changes()): an item's motion only when it changes: its lane and line position at a
## tick and its speed from then (steps a tick, 0 standing), and how far it can go at that speed
## along its straight run before it must change at the latest. The drawing writes one GPU record per
## change (belt_records.gd). Also the items gone and the lanes whose drift check failed (`bre`).

const GAP := 64
const SPLIT_BUFFER := 51  # a splitter input's end lies this far into its outputs
const FAR := -1000000000
const WALK := 4096  # how far ahead (1/256) a line looks for the item in front
const NEVER := 1 << 40

## Lane kinds (`lm`).
const STRAIGHT := 1
const CURVE := 2
const UG_VISIBLE := 3
const UG_HIDDEN := 4
const SPLIT_IN := 5
const SPLIT_OUT := 6
const LOADER := 7
const OTHER := 8

## What a lane leading nowhere does with its front item: runs off (gone), stops at its end, or
## follows `oracle` (the replay test: the game's own positions next tick, as sim.py's free mode).
const EDGE_RUN_OFF := 0
const EDGE_STOP := 1
const EDGE_ORACLE := 2

var edge_mode := EDGE_RUN_OFF
## uid -> [lane key, line position] the next tick (EDGE_ORACLE, and splitters' first turn).
var oracle: Dictionary = {}
## Items whose place the oracle gave this tick (not the simulation's): uid -> true.
var given: Dictionary = {}
## Off: no changes are collected (tests).
var emit_changes := true
## On: a lane that led nowhere loaded and now leads on has its line's lanes listed in take_changes()'s
## `mismatch` (to be asked for again: what ran off it meanwhile was guessed). The client sets it.
var ask_on_link := false
## Off: a head item's change says the step it was given and items leaving a line aren't emitted (the
## records as they were; --belt-draw-head-move=off). The rules are the same either way.
var head_move := true
## On: a read never leaves an item past its line's back end (where no lane of the line is: in the game
## such an item is on a feeder still): what the packed run a read moves back, the items it pushes back
## out of its lane and those it spaces out leave past it is carried back onto the feeder's line
## (_carry_back); before, it piled up there, overlapping, held the line behind and was never sent again
## (seen at -62,-26). The client sets it (--belt-sim-read-apply=off: as before). n_past_back (probes):
## items that went instead (no single feeder, no room).
var read_bound := true
var n_past_back := 0
var n_carried := 0  # (probes) items carried back onto a feeder's line (_carry_back)
const CARRY_HOPS := 8
## A read takes off only the items the game no longer has between its own (inserters' takes): those
## the line has in the read lane behind or ahead of the read's items go out of the lane that way
## (_rescue), what goes past a back end is carried back up to CARRY_HOPS_CONSERVE lines (a balancer's
## lanes are a line each) and never onto a splitter input nothing feeds (_carry_input). Against
## recordings 89% of the items reads took off were still on the belts (belt_bs_replay --read-probe).
## Off: as before.
var read_conserve := true
const CARRY_HOPS_CONSERVE := 32
## A read's lane at the front of its line (a splitter's input, a lane whose next is another line): the
## items the line had ahead of the read's items that the read hasn't went on in the game (across the
## splitter, into the next lane) where the simulation still held them (an `sh` hold, a crossing a tick
## late): they are carried on into that line (_carry_forward: a splitter's output as its turn says, where
## there is room; the next lane behind its hindmost item) instead of going. Against the every-tick
## recording at -62,-26 such drops were 47% of the items reads took off that the game still had (1,898
## of 4,042 in 600 ticks), and a packed bus never fills a hole again until the lane is read again.
## n_forward / n_forward_gone (probes): carried / gone for want of a next or room. Off: as before.
var read_forward := true
var n_forward := 0
var n_forward_gone := 0
## A read's packed-run shift (_shift_packed) stops at an item outside the lane that the shift would bring
## into it where the read hasn't it: the item stays where the simulation had it (in the game 81% of such
## items were still on the belts, ahead or behind, against the every-tick recording at -62,-26: 814 of the
## 4,042 items reads took off in 600 ticks). Off: it goes, and the run's shift goes on past it, as before.
var shift_keep := true
## A read that finds the lane exactly as the simulation has it (every item at its place, none else) changes
## nothing: skipped (--belt-sim-read-skip-same), its items only noted fresh and a splitter output's holds
## kept, as a full apply would leave them. Off: applied as before, which rebuilt the line and wrote every
## item's record again (half the reads at -62,-26 were such). n_same (probes): reads skipped.
var read_skip_same := true
var n_same := 0
const TURN_FOLLOW := 8  # (_turns_from_read) lanes followed on from a splitter's other output

## The tick the state is at (-1: not started).
var tick := -1
## Lines stepped one tick at a time so far (probes).
var n_line_steps := 0
## Counters (probes): [unused x5, steps every tick, rings, oracle edges]; with `profile`, step_us: time in
## line steps [lines leading out of the square under EDGE_ORACLE (the replay's), all others].
var prof := PackedInt64Array([0, 0, 0, 0, 0, 0, 0, 0])
var profile := false
## Lines stepped next tick, by why: [-, waiting to side-load or split, -, following a slower item, an item
## arrived (a ring), front crossing its exit, other, held by a standing item not 64 away, a gap closing].
var why_tick := PackedInt64Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
## Time (us) step_to() spent relinking, applying queued loads and checks, and stepping.
var us_relink := 0
var us_queue := 0
var us_step := 0
var step_us := PackedInt64Array([0, 0])

# --- lanes (struct of arrays, by index; free indices reused) ---
var _key_idx := {}  # key -> index
var l_key := PackedInt64Array()
var l_kind := PackedInt32Array()
var l_len := PackedInt32Array()
var l_step := PackedInt32Array()
var l_extra := PackedInt32Array()
var l_x0 := PackedInt32Array()  # exit (line position 0)
var l_y0 := PackedInt32Array()
var l_x1 := PackedInt32Array()  # entry (line position length)
var l_y1 := PackedInt32Array()
var l_seq := PackedInt64Array()  # when it was set: sim.py's lane order
var l_xnext := PackedInt64Array()  # the bridge's next lane key (0: by geometry)
var l_next := PackedInt32Array()
var l_side := PackedInt32Array()  # the lane it side-loads onto
var l_side_at := PackedInt32Array()
var l_sp0 := PackedInt32Array()  # a splitter input's outputs: its own half's, the other's
var l_sp1 := PackedInt32Array()
var l_off := PackedByteArray()
var l_alive := PackedByteArray()
var l_line := PackedInt32Array()
var l_base := PackedInt32Array()  # its exit's position in its line
var l_run := PackedInt32Array()  # straight run left beyond its exit (-1 not known)
var l_feeders: Array = []  # PackedInt32Array: lanes whose next it is
var l_sideins: Array = []  # PackedInt32Array: lanes side-loading onto it
var _free_lanes := PackedInt32Array()
var _seq := 0
var _entry_grid := {}  # Vector2i (entry // 32) -> PackedInt32Array, in set order
var _side_grid := {}  # Vector2i (entry // 512) -> PackedInt32Array: side-load targets
var _exit_grid := {}  # Vector2i (exit // 1024) -> PackedInt32Array
var _xnext_wait := {}  # key -> PackedInt32Array: lanes naming it as their next
var _units_off := {}  # unit -> true

# --- lines ---
class Line:
	var id := 0
	var alive := true
	var lanes := PackedInt32Array()  # front first
	var base := PackedInt32Array()  # each lane's exit in line positions
	var total := 0
	var s := 8
	var ord := 0
	var off := false
	var uid := PackedInt64Array()  # items, front first
	var itm := PackedInt32Array()
	var stk := PackedInt32Array()
	var gap := PackedInt32Array()  # gap[i]: item i's distance behind item i - 1 (gap[0] unused)
	var f := 0  # the front item's position at tick ft
	var span := 0  # sum of the gaps: back = f + span
	var ft := 0
	var mode := 0  # 0 stepped (or asleep: due -1), 1 flowing (all move s), 2 front standing, gap ck shrinks s a tick
	var ck := 0
	var due := -1  # the tick it must be stepped at
	var lp := 1  # gaps 1 .. lp - 1 are tight (<= 64)
	var lp2_from := 1 << 30  # and gaps lp2_from .. lp2 - 1
	var lp2 := 0
	var bp := 0  # the back item's position before tick bp_tick (set when stepped or given an item)
	var bp_tick := -1
	var arr := 0  # items at the back that arrived this tick, already moved (a ring)
	var arr_tick := -1
	var done_tick := -1
	var rs := PackedInt32Array()  # records: runs of items (start index) ...
	var rv := PackedInt32Array()  # ... and the speed their record has (-1 none)
	var pr_has := false  # the promise to the lines behind: the back at pr_t, moving pr_v a tick
	var pr_pos := 0
	var pr_t := 0
	var pr_v := 0
	## Items a splitter's priority input put in closer than 64 to the one in front: they stand till 64.
	var holds := {}


## A splitter's state and rules (docs/BELT-RULES.md section 6; sim.py's Splitter). Halves 0 (lines
## 1-2 in, 5-6 out) and 1 (lines 3-4, 7-8); sides 0 (lines 1, 3, 5, 7) and 1. Per side two turns:
## out_turn, the half whose output the next item goes to; in_turn, the half whose input goes first.
## A lane splitter is one side of one: its lines 1 and 2 the inputs (halves 0, 1), 3 and 4 the outputs.
class Splitter:
	var unit := 0
	var ins := PackedInt32Array([-1, -1, -1, -1])  # [half * 2 + side] -> lane
	var outs := PackedInt32Array([-1, -1, -1, -1])
	var out_turn := PackedInt32Array([-1, -1])
	var in_turn := PackedInt32Array([-1, -1])
	var in_prio := -1  # the half an input priority names
	var out_prio := -1
	var filter := 0  # item id
	var crossed := 0
	var node := 0  # its place among the stepping order's nodes
	var done_tick := -1


var _splitters := {}  # unit -> Splitter

var _lines: Array = []  # Line or null
var _free_lines := PackedInt32Array()
var _uid_line := {}  # uid -> line id
var _bucket := {}  # tick -> Array of line ids due
var _heap := PackedInt64Array()
var _cur_t := -1
var _cur_ord := -1
var _in_step := false

var _dirty := {}  # lane index -> true: relink
var _dirty_any := false
var _order_dirty := false
var _lane_pos := PackedInt32Array()  # each lane's place in the stepping order
var _run_dirty := false
var _pending: Array = []  # [lane, pos in lane, uid, item, stack] from dissolved lines
## Lanes leading out of what the bridge sends (`lm` next -1: the game's next lane isn't sent): lane
## key -> true. While one has no next here its front item is a wall the bridge moves: each `sl` of it
## (set_wall) says which item was its front at that tick and where; up to that tick the line moves on
## at most that far, and the items ahead of that one run off. Between reads, then, the line behind
## stands or flows as the game's did (a packed line standing behind something outside the square
## used to be pulled up to the lane's end).
var _out_keys := {}
## lane key -> [[tick, front uid (0: the lane was empty, everything runs off), its position], ...]
var _walls := {}
## Splitter inputs the bridge saw stand as their last read left them (`sh`): lane index -> the tick from
## which their items don't cross into the outputs, until the lane's next read (hold_inputs).
var _in_holds := {}
var hold_inputs := true
## split_wake: a splitter side that let an item through a tick or two ago (three, while its other output
## moves) is awake in the game and takes its turn before the belts that start moving this tick: an
## output that stood last tick and has room only once its items moved on this tick takes nothing from
## it then (docs/BELT-RULES.md section 6). _ob1/_ob2: each splitter output's hindmost item's position
## in it at the end of the tick before and the one before that (-1: none); _side_x: unit * 2 + side ->
## the tick an item last crossed there.
var split_wake := true
var _ob1 := {}
var _ob2 := {}
var _side_x := {}
var n_woke := 0  # (probes) crossings split_wake held back
var n_held := 0  # (probes) crossings held back
var _queue: Dictionary = {}  # tick -> Array of [tick, seq, kind, data] (by the tick they apply at: see _apply_queue)
var _qseq := 0
## Items a read set this tick: another read at the same tick doesn't move them (_shift_packed).
var _fresh := {}
var _fresh_tick := -1
## How far packed items' gaps may be over 64 and still shift with their line.
const PACK_SLACK := 8
var n_shifted := 0  # (probes) items moved with a read of a lane beside them
## (probes, belt_bs_replay --read-probe) each lane read's items against where the simulation had them just
## before it: key -> [items, exact, same line elsewhere, on another line, not simulated, reads].
var probe_reads := false
var read_probe := {}
## (probes) items a read took off: name -> count (dropped in the read's lane ahead of / behind / between the
## read's items in the line's order, or with none of them in the line; crowded; between; past the back).
var gone_probe := {}
var drop_log: Array = []  # (probes) [tick, uid, lane key, why] of the items a read took off

# --- output ---
var out_uid := PackedInt64Array()
var out_item := PackedInt32Array()
var out_stack := PackedInt32Array()
var out_key := PackedInt64Array()
var out_pos := PackedInt32Array()
var out_tick := PackedInt64Array()
var out_speed := PackedInt32Array()
var out_reach := PackedInt32Array()
var out_run := PackedInt32Array()
var out_gone := PackedInt64Array()
var out_gone_tick := PackedInt64Array()  # the tick it went on
var out_gone_at := PackedInt32Array()  # the changes before it (in out_uid): the order of the two
var out_mismatch := PackedInt64Array()

# Scratch for a step's movement runs.
var _seg_i := PackedInt32Array()
var _seg_v := PackedInt32Array()


# ======================================================================== API

## A lane (`lm`): key = belt unit * 8 + line index. p0, pm, p1: its exit, middle and entry on the
## map (1/256 tile). next_key: the lane items go on into, when the bridge says (0: by geometry).
func set_lane(key: int, kind: int, length: int, step: int, p0: Vector2i, _pm: Vector2i, p1: Vector2i,
		extra: int, next_key: int = 0) -> void:
	_marking = "set_lane"
	var i: int = _key_idx.get(key, -1)
	if i >= 0:
		if l_kind[i] == kind and l_len[i] == length and l_step[i] == step and l_x0[i] == p0.x \
				and l_y0[i] == p0.y and l_x1[i] == p1.x and l_y1[i] == p1.y and l_extra[i] == extra \
				and l_xnext[i] == next_key:
			return
		_marking = "set_lane changed k%d n%d" % [int(l_kind[i] != kind), int(l_xnext[i] != next_key)]
		_mark_near(i)
		_grid_remove(i)
	else:
		_marking = "set_lane new"
		i = _new_lane()
		_key_idx[key] = i
		l_key[i] = key
		l_seq[i] = _seq
		_seq += 1
		l_line[i] = -1
		l_next[i] = -1
		l_side[i] = -1
		l_sp0[i] = -1
		l_sp1[i] = -1
		l_feeders[i] = PackedInt32Array()
		l_sideins[i] = PackedInt32Array()
		var w: Variant = _xnext_wait.get(key)
		if w != null:
			for j in w:
				_mark(j)
	l_kind[i] = kind
	l_len[i] = length
	l_step[i] = step
	l_extra[i] = extra
	l_x0[i] = p0.x
	l_y0[i] = p0.y
	l_x1[i] = p1.x
	l_y1[i] = p1.y
	if l_xnext[i] != next_key:
		_wait_remove(i)
		l_xnext[i] = next_key
		if next_key != 0:
			var lst: PackedInt32Array = _xnext_wait.get(next_key, PackedInt32Array())
			lst.append(i)
			_xnext_wait[next_key] = lst
	l_off[i] = 1 if _units_off.has(_unit(key)) else 0
	l_alive[i] = 1
	_grid_add(i)
	_mark_near(i)


## A lane's meta as of `at_tick` (the tick of its first read in the same update): set_lane() and
## set_out_edge() then, in the queue's order. A lane that comes with the update leads nothing on before
## its first read: set at once, the line behind it moved on into it, empty, from wherever the
## simulation stood till its read (seen at -62,-26: a standing line ran on three ticks into lanes loaded
## ahead of it and its read moved it all back, past its back end).
func set_lane_at(at_tick: int, key: int, kind: int, length: int, step: int, p0: Vector2i, pm: Vector2i, p1: Vector2i,
		extra: int, next_key: int, out_edge: bool) -> void:
	if out_edge:
		set_out_edge(key, true)  # (now too: the walls the same update gives it are kept)
	if at_tick <= tick:
		set_lane(key, kind, length, step, p0, pm, p1, extra, next_key)
		set_out_edge(key, out_edge)
		return
	_enqueue(at_tick, 3, [key, kind, length, step, p0, pm, p1, extra, next_key, out_edge])


## The lane is no longer sent: its items go.
func drop_lane(key: int) -> void:
	_marking = "drop_lane"
	var i: int = _key_idx.get(key, -1)
	if i < 0:
		return
	_mark_near(i)
	_dissolve_line(l_line[i])
	# Its items (now pending) go.
	var keep: Array = []
	for p in _pending:
		if p[0] == i:
			_uid_line.erase(p[2])
			_gone(p[2])
		else:
			keep.append(p)
	_pending = keep
	_grid_remove(i)
	_wait_remove(i)
	_unlink(i)
	_out_keys.erase(key)
	_walls.erase(key)
	_in_holds.erase(i)
	l_alive[i] = 0
	_key_idx.erase(key)
	_free_lanes.append(i)
	_dirty.erase(i)


## The lane's items are exactly these at `tick` (`sl`: [uid, item, pos, stack] * n, front first).
func load_lane(key: int, at_tick: int, items: PackedInt64Array) -> void:
	_enqueue(at_tick, 0, [key, items])


## A drift check (`pc`): at `tick` the game had `count` items, front and back at those positions
## (and for a packed lane, `pu`, the front and back items' unique ids: 0 when not given).
func check_lane(key: int, at_tick: int, count: int, front: int, back: int, front_uid := 0, back_uid := 0) -> void:
	_enqueue(at_tick, 1, [key, count, front, back, front_uid, back_uid])


## A lane leads out of what is sent (`lm` next -1), or no longer does.
func set_out_edge(key: int, on: bool) -> void:
	if on:
		_out_keys[key] = true
	else:
		_out_keys.erase(key)
		_walls.erase(key)


## A lane leading out: at `at_tick` its front item was `uid` (0: none) at line position `pos` (the
## lane's `sl`, set as its items are handled, before stepping to that tick).
func set_wall(key: int, at_tick: int, uid: int, pos: int) -> void:
	if not _out_keys.has(key):
		return
	var w: Array = _walls.get(key, [])
	var j := w.size()
	while j > 0 and int(w[j - 1][0]) > at_tick:
		j -= 1
	if j > 0 and int(w[j - 1][0]) == at_tick:
		w[j - 1] = [at_tick, uid, pos]
	else:
		w.insert(j, [at_tick, uid, pos])
	_walls[key] = w
	var i: int = _key_idx.get(key, -1)
	if i >= 0 and l_line[i] >= 0 and _lines[l_line[i]] != null:
		_wake(_lines[l_line[i]])


## The wall in effect stepping to tick t: the first at or after t, else the last (it holds); older
## ones go. null: none.
func _wall_at(key: int, t: int) -> Variant:
	var w: Variant = _walls.get(key)
	if w == null or (w as Array).is_empty():
		return null
	var a: Array = w
	while a.size() > 1 and int(a[1][0]) <= t:
		a.pop_front()
	if int(a[0][0]) >= t or a.size() == 1:
		return a[0]
	return a[1]


## Whether no wall comes after tick t (the line can stand still at its wall).
func _wall_settled(key: int, t: int) -> bool:
	var w: Variant = _walls.get(key)
	return w == null or (w as Array).is_empty() or int((w as Array)[(w as Array).size() - 1][0]) <= t


## A belt switched off (1) or on (0) by the circuit network: a wall, its items and those behind stand.
func set_off(unit: int, off: bool, at_tick: int = -1) -> void:
	_enqueue(at_tick if at_tick >= 0 else tick, 2, [unit, off])


## Steps every line up to `to_tick`, applying what was queued at each tick on the way.
## `sh`: at `at_tick` the bridge found splitter input `key` as its last read left it (`items`, kept by
## the caller; empty: not known). The lane is put back as that read had it where the simulation has it
## otherwise, and from then on its items don't cross into the outputs until its next read: the game's
## own update order holds a backed-up balancer's input a tick or more where the rules let it go
## (docs/BELT-RULES.md section 6), and a watched lane is sent again only when the game's changes.
func hold_input(key: int, at_tick: int, items := PackedInt64Array()) -> void:
	if hold_inputs:
		_enqueue(at_tick, 4, [key, items])


func step_to(to_tick: int) -> void:
	if tick < 0:
		tick = to_tick
		_apply_queue(tick)
		_relink()
		return
	var c0 := Time.get_ticks_usec()
	_apply_queue(tick)
	us_queue += Time.get_ticks_usec() - c0
	while tick < to_tick:
		c0 = Time.get_ticks_usec()
		_step_tick()
		var c1 := Time.get_ticks_usec()
		us_step += c1 - c0
		_apply_queue(tick)
		us_queue += Time.get_ticks_usec() - c1
	c0 = Time.get_ticks_usec()
	_relink()
	us_relink += Time.get_ticks_usec() - c0


## Jumps to `to_tick` without stepping (a client too far behind to catch up: its items stand where
## they are until their lanes are loaded again); what was queued on the way is applied as it was.
func skip_to(to_tick: int) -> void:
	if tick < 0 or to_tick <= tick:
		step_to(to_tick)
		return
	_relink()
	for L in _lines:
		if L == null:
			continue
		_materialize(L, tick)
		L.mode = 0
		L.ft = to_tick
		L.due = -1
		if not L.uid.is_empty():
			_rec_set_range(L, 0, L.uid.size(), -1)
	_bucket.clear()
	tick = to_tick
	_apply_queue(tick)
	for L in _lines:
		if L != null and not L.uid.is_empty():
			L.pr_t = tick
			L.pr_v = 0
			_set_due(L, tick + 1)


## Puts an item on a lane now (at line position `pos` of that lane), taking it from wherever it is.
func put_item(key: int, uid: int, item: int, stack: int, pos: int) -> void:
	if _uid_line.has(uid):
		take_item(uid, false)
	_relink()
	var i: int = _key_idx.get(key, -1)
	if i < 0:
		return
	var L: Line = _lines[l_line[i]]
	_materialize(L, tick)
	_insert(L, l_base[i] + pos, uid, item, stack, -1)
	_touched(L, tick)


## Takes an item off the belts now.
func take_item(uid: int, gone := true) -> void:
	var id: int = _uid_line.get(uid, -1)
	if id < 0:
		return
	_relink()
	id = _uid_line.get(uid, -1)
	if id < 0:
		return
	var L: Line = _lines[id]
	_materialize(L, tick)
	var j := L.uid.find(uid)
	if j >= 0:
		_remove_at(L, j)
	_uid_line.erase(uid)
	L.holds.erase(uid)
	if gone:
		_gone(uid)
	_touched(L, tick)


## Changes since the last call: per change parallel arrays uid, item, stack, key (lane), pos (line
## position on that lane at `tick`), tick, speed (1/256 a tick from then; 0 standing), reach (how far
## it can go at that speed before its motion must change: along its straight run of one speed);
## `gone`: uids that left, `gone_tick` the tick each went on and `gone_at` how many of the changes
## came before it (an item can go and come back, or come and go, between two calls); `mismatch`:
## lanes whose drift check failed (for `bre`).
func take_changes() -> Dictionary:
	var d := {"uid": out_uid, "item": out_item, "stack": out_stack, "key": out_key, "pos": out_pos,
		"tick": out_tick, "speed": out_speed, "reach": out_reach, "run": out_run, "gone": out_gone,
		"gone_tick": out_gone_tick, "gone_at": out_gone_at, "mismatch": out_mismatch}
	out_uid = PackedInt64Array()
	out_item = PackedInt32Array()
	out_stack = PackedInt32Array()
	out_key = PackedInt64Array()
	out_pos = PackedInt32Array()
	out_tick = PackedInt64Array()
	out_speed = PackedInt32Array()
	out_reach = PackedInt32Array()
	out_run = PackedInt32Array()
	out_gone = PackedInt64Array()
	out_gone_tick = PackedInt64Array()
	out_gone_at = PackedInt32Array()
	out_mismatch = PackedInt64Array()
	return d


## The lane items leaving lane `key` at its exit go on into (by geometry or the bridge's next), or 0:
## none (it leads nowhere loaded, side-loads, or is a splitter's input). For the drawing, to follow an
## item along its line (`reach`).
func next_of(key: int) -> int:
	_relink()
	var i: int = _key_idx.get(key, -1)
	if i < 0 or l_next[i] < 0:
		return 0
	return l_key[l_next[i]]


## How far the straight run of one speed and direction goes on past lane `key`'s exit (1/256; 0 for a
## lane that isn't a straight belt): for the drawing, as take_changes()'s `run` less the position.
func run_of(key: int) -> int:
	_relink()
	var i: int = _key_idx.get(key, -1)
	if i < 0 or l_kind[i] != STRAIGHT or l_run[i] < 0:
		return 0
	return l_run[i]


## For the drawing's packed lanes (belt_items.gd, --belt-draw-lattice): each lane's front item now, three
## integers a key: its position on the lane (-1 and 0 0 when the lane has none), its speed (1/256 a tick:
## its line's when the line flows, its record's otherwise) and the lane's items. Reads only: nothing is
## worked out ahead (materialized), so asking changes nothing in the simulation.
func lane_fronts(keys: PackedInt64Array) -> PackedInt32Array:
	_relink()
	var out := PackedInt32Array()
	out.resize(keys.size() * 3)
	var by_line := {}  # line id -> [q, lane index, ...]
	for q in keys.size():
		out[q * 3] = -1
		var i: int = _key_idx.get(keys[q], -1)
		if i < 0 or l_line[i] < 0:
			continue
		if not by_line.has(l_line[i]):
			by_line[l_line[i]] = PackedInt32Array()
		var want: PackedInt32Array = by_line[l_line[i]]
		want.append(q)
		want.append(i)
		by_line[l_line[i]] = want
	for id: int in by_line:
		var L: Line = _lines[id]
		if L == null or L.uid.is_empty():
			continue
		var nl := L.lanes.size()
		var first := PackedInt32Array()
		first.resize(nl)
		var fv := PackedInt32Array()
		fv.resize(nl)
		var cnt := PackedInt32Array()
		cnt.resize(nl)
		var d := maxi(tick - L.ft, 0)
		var pos := L.f - (L.s * d if L.mode == 1 else 0)
		var li := 0
		var r := 0
		for j in L.uid.size():
			if j > 0:
				pos += L.gap[j]
				if L.mode == 2 and j == L.ck:
					pos -= L.s * d
			while li + 1 < nl and pos >= L.base[li + 1]:
				li += 1
			cnt[li] += 1
			if cnt[li] == 1:
				first[li] = pos - L.base[li]
				var v := 0
				if L.mode == 1:
					v = L.s
				elif L.mode == 2:
					v = L.s if j >= L.ck else 0
				else:
					while r + 1 < L.rs.size() and L.rs[r + 1] <= j:
						r += 1
					v = maxi(L.rv[r], 0) if r < L.rv.size() else 0
				fv[li] = v
		var want: PackedInt32Array = by_line[id]
		for w in range(0, want.size(), 2):
			var q := want[w]
			var li2 := L.lanes.find(want[w + 1])
			if li2 < 0 or cnt[li2] == 0:
				continue
			out[q * 3] = first[li2]
			out[q * 3 + 1] = fv[li2]
			out[q * 3 + 2] = cnt[li2]
	return out


## Every item now: [uids (PackedInt64Array), lane keys (PackedInt64Array), positions on them].
func items_state() -> Array:
	_relink()
	var u := PackedInt64Array()
	var k := PackedInt64Array()
	var p := PackedInt32Array()
	for L in _lines:
		if L == null or L.uid.is_empty():
			continue
		var n: int = L.uid.size()
		_materialize(L, tick)
		var pos: int = L.f
		var li := 0
		for i in n:
			if i > 0:
				pos += L.gap[i]
			while li + 1 < L.lanes.size() and pos >= L.base[li + 1]:
				li += 1
			u.append(L.uid[i])
			k.append(l_key[L.lanes[li]])
			p.append(pos - L.base[li])
	return [u, k, p]


## How many items and lines (for tests and probes).
func stats() -> Dictionary:
	var lines := 0
	var asleep := 0
	var flowing := 0
	var items := 0
	for L in _lines:
		if L == null:
			continue
		lines += 1
		items += L.uid.size()
		if L.due < 0:
			asleep += 1
		elif L.mode == 1:
			flowing += 1
	return {"lanes": _key_idx.size(), "lines": lines, "items": items, "asleep": asleep, "flowing": flowing}


# ======================================================================== queue

func _enqueue(at_tick: int, kind: int, data: Array) -> void:
	if not _queue.has(at_tick):
		_queue[at_tick] = []
	_queue[at_tick].append([at_tick, _qseq, kind, data])
	_qseq += 1


## Applies what was queued for ticks up to `now`, in the order it was queued (seq). Queued by tick: it
## used to scan (and rebuild) one list of every queued event each tick.
func _apply_queue(now: int) -> void:
	if _queue.is_empty():
		return
	var due: Array = []
	for t in _queue.keys():
		if int(t) <= now:
			due.append_array(_queue[t])
			_queue.erase(t)
	if due.is_empty():
		return
	due.sort_custom(func(a: Array, b: Array) -> bool: return a[1] < b[1])
	for q in due:
		var data: Array = q[3]
		match int(q[2]):
			0:
				_apply_load(int(data[0]), data[1])
			1:
				_apply_check(int(data[0]), int(data[1]), int(data[2]), int(data[3]), int(data[4]), int(data[5]))
			2:
				_apply_off(int(data[0]), bool(data[1]))
			3:
				set_lane(int(data[0]), int(data[1]), int(data[2]), int(data[3]), data[4], data[5], data[6], int(data[7]), int(data[8]))
				set_out_edge(int(data[0]), bool(data[9]))
			4:
				_apply_hold(int(data[0]), data[1])


## (hold_input) Put back as its last read had it, if the simulation has it otherwise; then held.
func _apply_hold(key: int, items: PackedInt64Array) -> void:
	var i: int = _key_idx.get(key, -1)
	if i < 0 or l_kind[i] != SPLIT_IN:
		return
	if not items.is_empty() and not _lane_is(i, items):
		_apply_load(key, items)
	_in_holds[i] = tick


## Whether lane i holds exactly these items ([uid, item, pos, stack, ...]) at their places now.
func _lane_is(i: int, items: PackedInt64Array) -> bool:
	_relink()
	var id := l_line[i]
	if id < 0 or _lines[id] == null:
		return false
	var L: Line = _lines[id]
	_materialize(L, tick)
	var lo := l_base[i]
	var hi := lo + l_len[i]
	var nl := items.size() / 4
	var pos := L.f
	var m := 0
	for j in L.uid.size():
		if j > 0:
			pos += L.gap[j]
		if pos < lo:
			continue
		if pos >= hi:
			break
		if m >= nl or L.uid[j] != items[m * 4] or pos - lo != int(items[m * 4 + 2]):
			return false
		m += 1
	return m == nl


## A read replaces the lane's items. A packed line shifts whole in the game (docs/BELT-RULES.md): when
## the lane's items are the simulation's moved on (or back) by one distance, the packed items either
## side of the lane that the read doesn't cover move with them, so the lane's neighbours aren't torn
## (an item that crossed into the lane in front was dropped as gone, one from the lane behind pulled
## out of it, leaving holes that let the simulation's line flow where the game's stands).
func _apply_load(key: int, items: PackedInt64Array) -> void:
	_relink()
	var i: int = _key_idx.get(key, -1)
	if i < 0:
		return
	if not _in_holds.is_empty() and _in_holds.erase(i) and l_line[i] >= 0 and _lines[l_line[i]] != null:
		_wake(_lines[l_line[i]])
	var L: Line = _lines[l_line[i]]
	_materialize(L, tick)
	if _fresh_tick != tick:
		_fresh.clear()
		_fresh_tick = tick
	if read_skip_same and _lane_is(i, items):
		n_same += 1
		for k in items.size() / 4:
			_fresh[items[k * 4]] = true
		if l_kind[i] == SPLIT_OUT:
			for jj in range(1, L.uid.size()):
				if L.gap[jj] < GAP:
					L.holds[L.uid[jj]] = true
		return
	var lo := l_base[i]
	var hi := lo + l_len[i]
	var n := L.uid.size()
	var total: int = L.base[L.base.size() - 1] + l_len[L.lanes[L.lanes.size() - 1]] if read_bound else -1
	# Each item's position now and its record's speed.
	var P := PackedInt32Array()
	P.resize(n)
	var RV := PackedInt32Array()
	RV.resize(n)
	var idx := {}
	var pos := L.f
	for j in n:
		if j > 0:
			pos += L.gap[j]
		P[j] = pos
		idx[L.uid[j]] = j
	for r in L.rs.size():
		var en: int = L.rs[r + 1] if r + 1 < L.rs.size() else n
		for j in range(L.rs[r], en):
			RV[j] = L.rv[r]
	var nl := items.size() / 4
	if probe_reads:
		var pr: Array = read_probe.get(key, [0, 0, 0, 0, 0, 0])
		pr[5] += 1
		for k in nl:
			var u: int = items[k * 4]
			pr[0] += 1
			var j: int = idx.get(u, -1)
			if j >= 0:
				if P[j] == lo + int(items[k * 4 + 2]):
					pr[1] += 1
				else:
					pr[2] += 1
			elif _uid_line.has(u):
				pr[3] += 1
				if l_kind[i] == SPLIT_IN or l_kind[i] == SPLIT_OUT:
					var O: Line = _lines[_uid_line[u]]
					_materialize(O, tick)
					var mo := O.uid.find(u)
					var why := "?"
					if mo >= 0:
						var q := O.f
						for x in range(1, mo + 1):
							q += O.gap[x]
						var ol: int = O.lanes[_lane_at(O, q)]
						if _unit(l_key[ol]) == _unit(key):
							why = "same splitter %s" % ("input" if l_kind[ol] == SPLIT_IN else "output")
							if l_kind[ol] == SPLIT_OUT and l_kind[i] == SPLIT_OUT:
								why += ", same half" if (l_key[ol] - 1) % 8 / 2 == (key - 1) % 8 / 2 else ", other half"
						elif l_feeders[i].has(ol) or _split_inputs_of(i).has(ol) if l_kind[i] == SPLIT_OUT else l_feeders[i].has(ol):
							why = "its feeder"
						elif l_next[i] == ol:
							why = "its next"
						else:
							why = "elsewhere (kind %d)" % l_kind[ol]
					var w2 := "kind %d other line: %s" % [l_kind[i], why]
					gone_probe[w2] = int(gone_probe.get(w2, 0)) + 1
			else:
				pr[4] += 1
		read_probe[key] = pr
	var between := PackedInt32Array()
	if nl > 0 and n > 1:
		between = _shift_packed(L, P, RV, idx, items, lo, hi)
	if nl > 0 and n > 0:
		between.append_array(_push_back(L, P, RV, idx, items, lo, hi))
	var gone_between := {}
	for j in between:
		gone_between[j] = true
	if read_conserve and n > 0:
		_rescue(L, P, RV, idx, items, lo, hi, gone_between)
	var past: Array = []  # (read_bound) [uid, item, stack, how far past the back end]: carried back
	if total >= 0:
		for j in n:
			if P[j] > total and not gone_between.has(j):
				past.append([L.uid[j], L.itm[j], L.stk[j], P[j] - total])
	var loaded := {}
	for k in nl:
		loaded[items[k * 4]] = true
	# (read_forward) The items _rescue put out past the line's front (lo 0: the lane is the line's first):
	# [uid, item, stack, how far past the exit], carried on (_carry_forward).
	var fwd: Array = []
	var fwd_j := {}
	if read_forward and read_conserve and lo == 0 and nl > 0:
		for j in n:
			if P[j] < 0 and not gone_between.has(j) and not loaded.has(L.uid[j]):
				fwd.append([L.uid[j], L.itm[j], L.stk[j], -P[j]])
				fwd_j[j] = true
	# Off with what the lane has now; the read's items come from wherever they are.
	var drop := PackedInt64Array()
	var keep := PackedInt32Array()
	for j in n:
		var q := P[j]
		if fwd_j.has(j):
			continue  # (in `fwd`)
		if total >= 0 and q > total and not gone_between.has(j):
			continue  # (in `past`, or read)
		if q < hi and (q >= lo or lo == 0 and q < 0) or gone_between.has(j):
			drop.append(L.uid[j])
		elif not loaded.has(L.uid[j]):
			keep.append(j)
	var U := PackedInt64Array()
	var I := PackedInt32Array()
	var S := PackedInt32Array()
	var Q := PackedInt32Array()
	var V := PackedInt32Array()
	for j in keep:
		U.append(L.uid[j])
		I.append(L.itm[j])
		S.append(L.stk[j])
		Q.append(P[j])
		V.append(RV[j])
	for j in n:
		_uid_line.erase(L.uid[j])
	for j in keep:
		_uid_line[L.uid[j]] = L.id
	if l_kind[i] == SPLIT_OUT:
		_turns_from_read(i, items)
	for k in nl:
		var u: int = items[k * 4]
		var other: int = _uid_line.get(u, -1)
		if other >= 0 and other != L.id:
			var O: Line = _lines[other]
			_materialize(O, tick)
			var m := O.uid.find(u)
			if m >= 0:
				_remove_at(O, m)
			_uid_line.erase(u)
			_touched(O, tick)
		U.append(u)
		I.append(int(items[k * 4 + 1]))
		S.append(int(items[k * 4 + 3]))
		Q.append(lo + int(items[k * 4 + 2]))
		V.append(-1)
		_uid_line[u] = L.id
		_fresh[u] = true
	var crowded := _space_out(U, I, S, Q, V, total, past)
	_rebuild(L, U, I, S, Q, V)
	for u in crowded:
		_uid_line.erase(u)
		_gone(u)
		L.holds.erase(u)
	if probe_reads:
		var rmin := n
		var rmax := -1
		for k in nl:
			var jj: int = idx.get(items[k * 4], -1)
			if jj >= 0:
				rmin = mini(rmin, jj)
				rmax = maxi(rmax, jj)
		for u in drop:
			if loaded.has(u):
				continue
			var jd: int = idx.get(u, -1)
			var why := "drop, none of the read's in the line" if rmax < 0 else ("drop, ahead" if jd < rmin else ("drop, behind" if jd > rmax else "drop, between"))
			if gone_between.has(jd):
				why = "between (shift)"
			gone_probe[why] = int(gone_probe.get(why, 0)) + 1
			drop_log.append([tick, u, key, why])
		gone_probe["crowded"] = int(gone_probe.get("crowded", 0)) + crowded.size()
		for u in crowded:
			drop_log.append([tick, u, key, "read crowded"])
	for u in drop:
		if not loaded.has(u):
			_gone(u)
			L.holds.erase(u)
	if not past.is_empty():
		var carry: Array = []
		for e in past:
			L.holds.erase(e[0])
			if not loaded.has(e[0]):
				carry.append(e)
		carry.sort_custom(func(x: Array, y: Array) -> bool: return x[3] < y[3] or x[3] == y[3] and x[0] < y[0])
		_carry_back(L.lanes[L.lanes.size() - 1], carry, L.id)
	if not fwd.is_empty():
		for e in fwd:
			L.holds.erase(e[0])
		# (The furthest past the exit first: it was in front.)
		fwd.sort_custom(func(x: Array, y: Array) -> bool: return x[3] > y[3] or x[3] == y[3] and x[0] < y[0])
		_carry_forward(L.lanes[0], fwd)
	if l_kind[i] == SPLIT_OUT:
		for jj in range(1, L.uid.size()):
			if L.gap[jj] < GAP:
				L.holds[L.uid[jj]] = true
	_touched(L, tick)


## (_apply_load, read_forward) Items a read of lane l0, its line's first, left past its exit ([uid, item,
## stack, how far past], the furthest first): in the game they went on. Across a splitter they go into the
## output its turn (or priority, or filter) says, where there is room, else the other, as a crossing does
## (the side's turns move on as for one); into a plain next lane they go behind its hindmost item, where
## its place is. Where the lane leads nowhere that is sent, or no output or the next has room, they go.
func _carry_forward(l0: int, ex: Array) -> void:
	var nx := l_next[l0]
	var sp: Splitter = _splitters.get(_unit(l_key[l0])) if l_kind[l0] == SPLIT_IN else null
	for e in ex:
		var uid: int = e[0]
		var ok := false
		if sp != null:
			ok = _forward_split(sp, l0, uid, int(e[1]), int(e[2]), int(e[3]))
		elif l_side[l0] < 0 and nx >= 0 and l_line[nx] >= 0 and _lines[l_line[nx]] != null:
			var X: Line = _lines[l_line[nx]]
			_materialize(X, tick)
			var en := l_base[nx] + l_len[nx]
			var at := en - int(e[3])
			if not X.uid.is_empty():
				at = maxi(at, X.f + X.span + GAP)
			if at < en:
				var jj := _insert(X, at, uid, int(e[1]), int(e[2]), -1)
				if jj == X.uid.size() - 1:
					X.bp = at
					X.bp_tick = tick
				_wake(X)
				_touched_promise(X, tick)
				ok = true
		if ok:
			n_forward += 1
		else:
			if probe_reads:
				var why := "forward gone: " + ("splitter full" if sp != null else ("side-load" if l_side[l0] >= 0 else ("no next" if nx < 0 else "next full")))
				gone_probe[why] = int(gone_probe.get(why, 0)) + 1
				drop_log.append([tick, uid, l_key[l0], why])
			_uid_line.erase(uid)
			_gone(uid)
			n_forward_gone += 1


## (_carry_forward) An item `over` past splitter input l0's exit goes into an output as _split_put would
## put it, but held by nothing: the game made the crossing. Returns whether it found room.
func _forward_split(sp: Splitter, l0: int, uid: int, item: int, stk: int, over: int) -> bool:
	var half := l_sp0[l0]
	var side := l_sp1[l0]
	var tries := PackedInt32Array()
	if sp.filter != 0:
		var fh := sp.out_prio if sp.out_prio >= 0 else 0
		tries.append(sp.outs[(fh if item == sp.filter else 1 - fh) * 2 + side])
	elif sp.out_prio >= 0:
		tries.append(sp.outs[sp.out_prio * 2 + side])
		tries.append(sp.outs[(1 - sp.out_prio) * 2 + side])
	else:
		var tt := maxi(sp.out_turn[side], 0)
		tries.append(sp.outs[tt * 2 + side])
		tries.append(sp.outs[(1 - tt) * 2 + side])
	for o in tries:
		if o < 0 or l_line[o] < 0 or _lines[l_line[o]] == null:
			continue
		var X: Line = _lines[l_line[o]]
		_materialize(X, tick)
		var olen := l_len[o]
		var at := maxi(olen - SPLIT_BUFFER - over, 0)
		if not X.uid.is_empty():
			at = maxi(at, X.f + X.span - l_base[o] + GAP)
		if at >= olen:
			continue
		var jj := _insert(X, l_base[o] + at, uid, item, stk, -1)
		if jj == X.uid.size() - 1:
			X.bp = l_base[o] + at
			X.bp_tick = tick
		sp.crossed += 1
		_side_x[sp.unit * 2 + side] = tick
		sp.out_turn[side] = 1 - (0 if o == sp.outs[side] else 1)
		sp.in_turn[side] = 1 - half
		_wake(X)
		_touched_promise(X, tick)
		return true
	return false


## (_apply_load) The items the line has in the read lane that the read hasn't: in the game (seen against
## recordings) nearly all are still on the belts, behind the lane (the simulation ran them on into it) or
## ahead of it. Those behind the read's items in the line's order (or all, when none of the read's items
## are in the line) go back out of the lane behind it, those ahead of them out of it in front, keeping
## their order; _space_out and _carry_back then place them (P, RV changed). Only items between the read's
## own are left to go (taken).
func _rescue(L: Line, P: PackedInt32Array, RV: PackedInt32Array, idx: Dictionary, items: PackedInt64Array,
		lo: int, hi: int, skip: Dictionary) -> void:
	var nl := items.size() / 4
	var n := L.uid.size()
	var rmin := n
	var rmax := -1
	var loaded := {}
	for k in nl:
		loaded[items[k * 4]] = true
		var j: int = idx.get(items[k * 4], -1)
		if j >= 0:
			rmin = mini(rmin, j)
			rmax = maxi(rmax, j)
	var ahead := PackedInt32Array()
	var r := 0
	for j in n:
		var q := P[j]
		if skip.has(j) or loaded.has(L.uid[j]) or not (q < hi and (q >= lo or lo == 0 and q < 0)):
			continue
		if rmax < 0 or j > rmax:
			P[j] = maxi(q, hi + r)
			RV[j] = -1
			r += 1
		elif j < rmin and nl > 0:
			ahead.append(j)
	if ahead.is_empty():
		return
	var front := lo + int(items[2])
	var m := ahead.size()
	for x in m:
		var j := ahead[x]
		var t := mini(front - GAP * (m - x), lo - 1 - GAP * (m - 1 - x))
		if t < P[j]:
			P[j] = t
			RV[j] = -1


## (_apply_load) A read of a splitter's output with an item the simulation still had on one of that
## splitter's inputs: the game let it cross. The hindmost such sets the side's turns as that crossing
## did (docs/BELT-RULES.md section 6): the other input goes first next, the other output takes the next
## item. The game shows no turn to a script, so this is how the simulation's turns come to match it.
## With read_bound, an item the simulation sent into the side's other output counts too (its turn was
## wrong: a crossing whose output was read too late, or not at all), setting the output's turn alone
## (which input it came from the simulation no longer knows); items it sent so stood on the wrong side
## of the balancer from then on.
func _turns_from_read(o: int, items: PackedInt64Array) -> void:
	var sp: Splitter = _splitters.get(_unit(l_key[o]))
	if sp == null:
		return
	var oi := sp.outs.find(o)
	if oi < 0:
		return
	var best := -1
	var best_half := -1
	# (The side's other output and the lanes it leads on into, a few: where the simulation sent it.)
	var other := {}
	var x0 := sp.outs[(1 - oi / 2) * 2 + oi % 2]
	if read_bound:
		for _n in TURN_FOLLOW:
			if x0 < 0 or other.has(x0):
				break
			other[x0] = true
			x0 = l_next[x0]
	for k in items.size() / 4:
		var u: int = items[k * 4]
		var id: int = _uid_line.get(u, -1)
		if id < 0 or id == l_line[o] or _lines[id] == null:
			continue
		var O: Line = _lines[id]
		_materialize(O, tick)
		var m := O.uid.find(u)
		if m < 0:
			continue
		var q := O.f
		for x in range(1, m + 1):
			q += O.gap[x]
		var lane: int = O.lanes[_lane_at(O, q)]
		var half := -1
		if l_kind[lane] == SPLIT_IN and _unit(l_key[lane]) == sp.unit:
			half = l_sp0[lane]
		elif other.has(lane):
			half = 2  # (crossed into the other output: the input not known)
		else:
			continue
		var p := int(items[k * 4 + 2])
		if p > best:
			best = p
			best_half = half
	if best_half < 0:
		return
	if best_half < 2:
		sp.in_turn[oi % 2] = 1 - best_half
	sp.out_turn[oi % 2] = 1 - oi / 2


## (_apply_load) No two items closer than a gap after a read. Items a read set this tick (this one or
## another) stay where they are; any other item closer than a gap behind the one in front goes back to a
## gap behind it, and those behind it with it, unless that brings it within a gap of a fixed item behind:
## then it goes; past `bound` (the line's back end; -1: none) it leaves too, into `past` ([uid, item,
## stack, how far past]). Changes the arrays in place; returns the items that go.
func _space_out(U: PackedInt64Array, I: PackedInt32Array, S: PackedInt32Array, Q: PackedInt32Array,
		V: PackedInt32Array, bound: int = -1, past: Array = []) -> PackedInt64Array:
	var n := U.size()
	var out := PackedInt64Array()
	if n < 2:
		return out
	var order := []
	order.resize(n)
	for k in n:
		order[k] = k
	order.sort_custom(func(x: int, y: int) -> bool: return Q[x] < Q[y] or Q[x] == Q[y] and U[x] < U[y])
	# The nearest fixed item behind each place in that order.
	var nf := PackedInt32Array()
	nf.resize(n)
	var f := 1 << 30
	for r in range(n - 1, -1, -1):
		nf[r] = f
		if _fresh.has(U[order[r]]):
			f = Q[order[r]]
	var gone := {}
	var have := false
	var prev := 0
	for r in n:
		var o: int = order[r]
		if _fresh.has(U[o]):
			prev = Q[o]
			have = true
			continue
		if have and Q[o] < prev + GAP:
			var np := prev + GAP
			if np + GAP > nf[r]:
				gone[o] = true
				out.append(U[o])
				continue
			if bound >= 0 and np > bound:
				gone[o] = true  # (carried back: _carry_back)
				past.append([U[o], I[o], S[o], np - bound])
				continue
			Q[o] = np
			V[o] = -1
		prev = Q[o]
		have = true
	if gone.is_empty():
		return out
	var w := 0
	for k in n:
		if gone.has(k):
			continue
		U[w] = U[k]
		I[w] = I[k]
		S[w] = S[k]
		Q[w] = Q[k]
		V[w] = V[k]
		w += 1
	U.resize(w)
	I.resize(w)
	S.resize(w)
	Q.resize(w)
	V.resize(w)
	return out


## (_apply_load) The distance most of the read's items moved from where the simulation has them; the
## packed items outside the lane, either side, joined to those items, move by it too (P, RV changed).
## Returns the items the simulation has between the read's items that the read hasn't: in the game
## they are no longer there (items keep their order along a line), wherever the simulation has them.
func _shift_packed(L: Line, P: PackedInt32Array, RV: PackedInt32Array, idx: Dictionary,
		items: PackedInt64Array, lo: int, hi: int) -> PackedInt32Array:
	var nl := items.size() / 4
	var n := L.uid.size()
	var dj := {}  # index -> its move
	var gp := {}  # index -> where the read puts it
	var cnt := {}
	for k in nl:
		var j: int = idx.get(items[k * 4], -1)
		if j < 0:
			continue
		gp[j] = lo + int(items[k * 4 + 2])
		if _fresh.has(items[k * 4]):
			continue  # (set by another read this tick: already where the game has it)
		var d := lo + int(items[k * 4 + 2]) - P[j]
		dj[j] = d
		cnt[d] = int(cnt.get(d, 0)) + 1
	var d := 0
	var best := 0
	for c in cnt:
		if int(cnt[c]) > best or int(cnt[c]) == best and absi(c) < absi(d):
			best = cnt[c]
			d = c
	if best == 0:
		return PackedInt32Array()
	var a := n
	var b := -1
	for j in dj:
		if dj[j] == d:
			a = mini(a, j)
			b = maxi(b, j)
	var between := PackedInt32Array()
	for j in range(a + 1, b):
		if not gp.has(j):
			between.append(j)
	if d == 0:
		return between
	# In front.
	var front := PackedInt32Array()
	var prev := P[a]
	var j := a - 1
	while j >= 0:
		if dj.has(j) and dj[j] == d:
			prev = P[j]
			j -= 1
			continue
		if gp.has(j) or _fresh.has(L.uid[j]):
			break
		var np := P[j] + d
		if np < hi and (np >= lo or lo == 0):
			# The game hasn't it where the move puts it (taken, or the simulation's order is wrong): if it
			# lies outside the lane it goes too, and the run goes on past it (shift_keep: the run ends at it
			# instead, and it stays where it is).
			if _stays_at(L, P, gp, j, lo, hi) == FAR or shift_keep:
				break
			between.append(j)
			j -= 1
			continue
		if prev - P[j] <= GAP + PACK_SLACK or d < 0 and prev + d - P[j] < GAP:
			front.append(j)
			prev = P[j]
			j -= 1
		else:
			break
	var df := d
	if not front.is_empty() and j >= 0:
		var sp := _stays_at(L, P, gp, j, lo, hi)
		if sp != FAR and d < 0:
			df = mini(maxi(d, sp + GAP - P[front[front.size() - 1]]), 0)
	if df != 0:
		for f in front:
			P[f] += df
			RV[f] = -1
	# Behind.
	var back := PackedInt32Array()
	prev = P[b]
	j = b + 1
	while j < n:
		if dj.has(j) and dj[j] == d:
			prev = P[j]
			j += 1
			continue
		if gp.has(j) or _fresh.has(L.uid[j]):
			break
		var np := P[j] + d
		if np < hi and (np >= lo or lo == 0):
			if _stays_at(L, P, gp, j, lo, hi) == FAR or shift_keep:
				break
			between.append(j)
			j += 1
			continue
		if P[j] - prev <= GAP + PACK_SLACK or d > 0 and P[j] - prev - d < GAP:
			back.append(j)
			prev = P[j]
			j += 1
		else:
			break
	var db := d
	if not back.is_empty() and j < n:
		var sp := _stays_at(L, P, gp, j, lo, hi)
		if sp != FAR and d > 0:
			db = maxi(mini(d, sp - GAP - P[back[back.size() - 1]]), 0)
	if db != 0:
		for f in back:
			P[f] += db
			RV[f] = -1
	n_shifted += front.size() + back.size()
	return between


## (_apply_load) When none of a read's items are on the lane's line and some are on another (the
## simulation ran them on ahead: past a splitter, or off the lane's end into the next line), the items
## the line has in the lane are ones the game still has behind it: they are pushed back behind the
## read's last item and out of the lane, with the packed run behind them, rather than dropped. Those
## that would reach items another read set this tick go (that read has the lane behind, without them).
## Returns those to drop.
func _push_back(L: Line, P: PackedInt32Array, RV: PackedInt32Array, idx: Dictionary,
		items: PackedInt64Array, lo: int, hi: int) -> PackedInt32Array:
	var pulled := 0
	var back := lo
	for k in items.size() / 4:
		var u: int = items[k * 4]
		if idx.has(u):
			return PackedInt32Array()
		var other: int = _uid_line.get(u, -1)
		if other >= 0 and other != L.id:
			pulled += 1
		back = maxi(back, lo + int(items[k * 4 + 2]))
	var moved := PackedInt32Array()
	if pulled == 0:
		return moved
	var prev := back
	var started := false
	for j in L.uid.size():
		var q := P[j]
		var inside := q < hi and (q >= lo or lo == 0 and q < 0)
		if not started:
			if not inside:
				continue
			started = true
		if _fresh.has(L.uid[j]):
			var drop := PackedInt32Array()
			for m in range(moved.size() - 1, -1, -1):
				if P[moved[m]] + GAP <= P[j]:
					break
				drop.append(moved[m])
			return drop
		var np := maxi(q, prev + GAP)
		if inside:
			np = maxi(np, hi)
		if np == q:
			break
		P[j] = np
		RV[j] = -1
		prev = np
		moved.append(j)
		n_shifted += 1
	return PackedInt32Array()


## (_apply_load, read_bound) Items a read leaves past the back end of lane z's line ([uid, item, stack, how
## far past], front first): in the game they haven't left the lane feeding z yet (the simulation ran them
## on into z's line, and the packed run behind them with them, where the game's stood). They go back onto
## the feeder's line that far past its exit, in front of its own items, which go back to a gap behind
## them as far as needed (they had run on alike); what that leaves past that line's back end goes on into
## its feeder's, up to CARRY_HOPS lines. Past a splitter's output they go back onto the input on that side
## with more room in front (the simulation doesn't know which one the game's would have come from), the
## item's place there as _split_put maps it, and the side's turns are put back as they were before such a
## crossing. Where a lane has no single feeder, or an item would come within a gap of one another read set
## this tick, the items go instead (n_past_back), as a read's crowded items do: never two items closer
## than a gap, nothing piled up.
func _carry_back(z: int, ex: Array, origin: int) -> void:
	var seen := {origin: true}
	var hops := 0
	while not ex.is_empty():
		var f := -1
		var add := 0  # (a splitter's input: how far an output's place past its back end is on it)
		var split := false
		if hops < (CARRY_HOPS_CONSERVE if read_conserve else CARRY_HOPS):
			var fe: PackedInt32Array = l_feeders[z]
			if fe.size() == 1:
				f = fe[0]
			elif fe.is_empty() and l_kind[z] == SPLIT_OUT:
				f = _carry_input(z)
				add = SPLIT_BUFFER
				split = true
		var F: Line = null
		if f >= 0 and l_line[f] >= 0:
			F = _lines[l_line[f]]
			if F == null or seen.has(F.id) or F.lanes[0] != f or F.off:
				F = null
		if F == null:
			if probe_reads:
				var fe2: PackedInt32Array = l_feeders[z]
				var why := "carry gone: hops" if hops >= CARRY_HOPS else ("carry gone: %d feeders, kind %d, sideins %d" % [mini(fe2.size(), 2), l_kind[z], mini(l_sideins[z].size(), 1)] if f < 0 else "carry gone: feeder not a line front / seen / off")
				gone_probe[why] = int(gone_probe.get(why, 0)) + ex.size()
				for e in ex:
					drop_log.append([tick, e[0], l_key[z], why])
			for e in ex:
				_uid_line.erase(e[0])
				_gone(e[0])
				n_past_back += 1
			return
		if split:
			# (The crossing taken back: the next item from that input goes into that output again.)
			var sp: Splitter = _splitters.get(_unit(l_key[z]))
			var oi := sp.outs.find(z)
			if oi >= 0 and sp.out_prio < 0 and sp.filter == 0:
				sp.out_turn[oi % 2] = oi / 2
			if oi >= 0 and sp.in_prio < 0:
				sp.in_turn[oi % 2] = l_sp0[f]
		seen[F.id] = true
		hops += 1
		_materialize(F, tick)
		var total: int = F.base[F.base.size() - 1] + l_len[F.lanes[F.lanes.size() - 1]]
		# The carried items first (they were in front), then F's own, front first.
		var U := PackedInt64Array()
		var I := PackedInt32Array()
		var S := PackedInt32Array()
		var Q := PackedInt32Array()
		var V := PackedInt32Array()
		var fresh := PackedByteArray()
		for e in ex:
			U.append(e[0])
			I.append(e[1])
			S.append(e[2])
			Q.append(int(e[3]) + add)
			V.append(-1)
			fresh.append(0)
		var pos := F.f
		var r := 0
		for j in F.uid.size():
			if j > 0:
				pos += F.gap[j]
			while r + 1 < F.rs.size() and F.rs[r + 1] <= j:
				r += 1
			U.append(F.uid[j])
			I.append(F.itm[j])
			S.append(F.stk[j])
			Q.append(pos)
			V.append(F.rv[r])
			fresh.append(1 if _fresh.has(F.uid[j]) else 0)
		var m := U.size()
		# The nearest item another read set this tick behind each.
		var nf := PackedInt32Array()
		nf.resize(m)
		var fpos := 1 << 30
		for x in range(m - 1, -1, -1):
			nf[x] = fpos
			if fresh[x] == 1:
				fpos = Q[x]
		var keep := PackedByteArray()
		keep.resize(m)
		keep.fill(1)
		var have := false
		var prev := 0
		for x in m:
			if fresh[x] == 0:
				var q := Q[x]
				if have and q < prev + GAP:
					q = prev + GAP
				if q + GAP > nf[x]:
					keep[x] = 0
					continue
				if q != Q[x]:
					Q[x] = q
					V[x] = -1
			prev = Q[x]
			have = true
		var nex: Array = []
		var KU := PackedInt64Array()
		var KI := PackedInt32Array()
		var KS := PackedInt32Array()
		var KQ := PackedInt32Array()
		var KV := PackedInt32Array()
		for x in m:
			if keep[x] == 0:
				if probe_reads:
					gone_probe["carry gone: crowded"] = int(gone_probe.get("carry gone: crowded", 0)) + 1
					drop_log.append([tick, U[x], l_key[F.lanes[0]], "carry gone: crowded"])
				_uid_line.erase(U[x])
				_gone(U[x])
				F.holds.erase(U[x])
				n_past_back += 1
			elif Q[x] > total:
				_uid_line.erase(U[x])
				F.holds.erase(U[x])
				nex.append([U[x], I[x], S[x], Q[x] - total])
			else:
				KU.append(U[x])
				KI.append(I[x])
				KS.append(S[x])
				KQ.append(Q[x])
				KV.append(V[x])
				_uid_line[U[x]] = F.id
		_rebuild(F, KU, KI, KS, KQ, KV)
		_touched(F, tick)
		n_carried += ex.size()
		ex = nex
		z = F.lanes[F.lanes.size() - 1]


## (_carry_back) Of the inputs on a splitter output's side, the one with more room in front (its front
## item furthest from its end; -1: none).
func _carry_input(o: int) -> int:
	var best := -1
	var room := -1
	var ins := _split_inputs_of(o)
	var fed := false
	if read_conserve:
		for x in ins:
			if not (l_feeders[x] as PackedInt32Array).is_empty() or not (l_sideins[x] as PackedInt32Array).is_empty():
				fed = true
	for x in ins:
		if l_line[x] < 0 or _lines[l_line[x]] == null:
			continue
		if fed and (l_feeders[x] as PackedInt32Array).is_empty() and (l_sideins[x] as PackedInt32Array).is_empty():
			continue  # (an input nothing feeds: none of the game's items came from it)
		var X: Line = _lines[l_line[x]]
		_materialize(X, tick)
		var fr: int = (1 << 30) if X.uid.is_empty() else X.f
		if fr > room:
			room = fr
			best = x
	return best


## (_shift_packed) Where item j of the line will be after the read (FAR: it goes).
func _stays_at(L: Line, P: PackedInt32Array, gp: Dictionary, j: int, lo: int, hi: int) -> int:
	if gp.has(j):
		return gp[j]
	if P[j] < hi and (P[j] >= lo or lo == 0 and P[j] < 0):
		return FAR
	return P[j]


## A line's items set anew from parallel arrays (any order), records kept per item.
func _rebuild(L: Line, U: PackedInt64Array, I: PackedInt32Array, S: PackedInt32Array, Q: PackedInt32Array,
		V: PackedInt32Array) -> void:
	var n := U.size()
	var order: Array = range(n)
	order.sort_custom(func(x: int, y: int) -> bool: return Q[x] < Q[y] or Q[x] == Q[y] and U[x] < U[y])
	L.uid = PackedInt64Array()
	L.itm = PackedInt32Array()
	L.stk = PackedInt32Array()
	L.gap = PackedInt32Array()
	L.rs = PackedInt32Array()
	L.rv = PackedInt32Array()
	L.span = 0
	L.lp = 1
	L.lp2_from = 1 << 30
	if L.mode == 2:
		L.mode = 0
	var last := 0
	for k in n:
		var o: int = order[k]
		L.uid.append(U[o])
		L.itm.append(I[o])
		L.stk.append(S[o])
		if k == 0:
			L.f = Q[o]
			L.gap.append(0)
		else:
			L.gap.append(Q[o] - last)
			L.span += Q[o] - last
		last = Q[o]
		if L.rv.is_empty() or L.rv[L.rv.size() - 1] != V[o]:
			L.rs.append(k)
			L.rv.append(V[o])


func _apply_check(key: int, count: int, front: int, back: int, front_uid := 0, back_uid := 0) -> void:
	_relink()
	var i: int = _key_idx.get(key, -1)
	if i < 0:
		return
	var L: Line = _lines[l_line[i]]
	var lo := l_base[i]
	var hi := lo + l_len[i]
	_materialize(L, tick)
	var pos := L.f
	var c := 0
	var f := -1
	var b := -1
	var fu := 0
	var bu := 0
	for j in L.uid.size():
		if j > 0:
			pos += L.gap[j]
		if pos >= hi:
			break
		if pos >= lo or (lo == 0 and pos < 0):
			if c == 0:
				f = pos - lo
				fu = L.uid[j]
			b = pos - lo
			bu = L.uid[j]
			c += 1
	# (A packed lane a whole gap off has the same count, front and back: its items' ids tell.)
	if c != count or f != front or b != back or (front_uid != 0 and (fu != front_uid or bu != back_uid)):
		out_mismatch.append(key)


func _apply_off(unit: int, off: bool) -> void:
	_marking = "set_off"
	if off:
		_units_off[unit] = true
	else:
		_units_off.erase(unit)
	for line in range(1, 9):
		var i: int = _key_idx.get(unit * 8 + line, -1)
		if i >= 0 and (l_off[i] == 1) != off:
			l_off[i] = 1 if off else 0
			# (No link changes: only the lines round it are made again; belts that a circuit switches
			# on and off every few ticks made the whole stepping order again each time.)
			_relines[i] = true
			_dirty_any = true


# ======================================================================== lanes and topology

static func _unit(key: int) -> int:
	return (key - 1) >> 3


static func _lnum(key: int) -> int:
	return ((key - 1) & 7) + 1


func _new_lane() -> int:
	if not _free_lanes.is_empty():
		var i: int = _free_lanes[_free_lanes.size() - 1]
		_free_lanes.resize(_free_lanes.size() - 1)
		l_xnext[i] = 0
		l_off[i] = 0
		l_run[i] = -1
		l_base[i] = 0
		return i
	var i := l_key.size()
	l_key.resize(i + 1)
	l_seq.resize(i + 1)
	l_xnext.resize(i + 1)
	l_kind.resize(i + 1)
	l_len.resize(i + 1)
	l_step.resize(i + 1)
	l_extra.resize(i + 1)
	l_x0.resize(i + 1)
	l_y0.resize(i + 1)
	l_x1.resize(i + 1)
	l_y1.resize(i + 1)
	l_next.resize(i + 1)
	l_side.resize(i + 1)
	l_side_at.resize(i + 1)
	l_sp0.resize(i + 1)
	l_sp1.resize(i + 1)
	l_line.resize(i + 1)
	l_base.resize(i + 1)
	l_run.resize(i + 1)
	l_off.resize(i + 1)
	l_alive.resize(i + 1)
	l_run[i] = -1
	l_feeders.append(PackedInt32Array())
	l_sideins.append(PackedInt32Array())
	return i


static func _floordiv(a: int, b: int) -> int:
	var q := a / b
	if (a % b != 0) and ((a < 0) != (b < 0)):
		q -= 1
	return q


func _grid_add(i: int) -> void:
	var c := Vector2i(_floordiv(l_x1[i], 32), _floordiv(l_y1[i], 32))
	var a: PackedInt32Array = _entry_grid.get(c, PackedInt32Array())
	a.append(i)
	_entry_grid[c] = a
	c = Vector2i(_floordiv(l_x0[i], 1024), _floordiv(l_y0[i], 1024))
	a = _exit_grid.get(c, PackedInt32Array())
	a.append(i)
	_exit_grid[c] = a
	if (l_kind[i] == STRAIGHT or l_kind[i] == CURVE) and l_len[i] == 256 or l_kind[i] == UG_VISIBLE:
		c = Vector2i(_floordiv(l_x1[i], 512), _floordiv(l_y1[i], 512))
		a = _side_grid.get(c, PackedInt32Array())
		a.append(i)
		_side_grid[c] = a


func _grid_remove(i: int) -> void:
	for g in [[_entry_grid, Vector2i(_floordiv(l_x1[i], 32), _floordiv(l_y1[i], 32))],
			[_exit_grid, Vector2i(_floordiv(l_x0[i], 1024), _floordiv(l_y0[i], 1024))],
			[_side_grid, Vector2i(_floordiv(l_x1[i], 512), _floordiv(l_y1[i], 512))]]:
		var grid: Dictionary = g[0]
		var c: Vector2i = g[1]
		var a: Variant = grid.get(c)
		if a == null:
			continue
		var arr: PackedInt32Array = a
		var k := arr.find(i)
		if k >= 0:
			arr.remove_at(k)
			if arr.is_empty():
				grid.erase(c)
			else:
				grid[c] = arr


func _wait_remove(i: int) -> void:
	var k := l_xnext[i]
	if k == 0:
		return
	var w: Variant = _xnext_wait.get(k)
	if w == null:
		return
	var arr: PackedInt32Array = w
	var j := arr.find(i)
	if j >= 0:
		arr.remove_at(j)
	if arr.is_empty():
		_xnext_wait.erase(k)
	else:
		_xnext_wait[k] = arr


var why_mark := {}  # (probes) what marked lanes for relinking: name -> count
var _marking := ""


func _mark(i: int) -> void:
	if not _dirty.has(i):
		why_mark[_marking] = int(why_mark.get(_marking, 0)) + 1
	_dirty[i] = true
	_dirty_any = true


## The lane and every lane whose links it can change: those whose exit is near its entry or exit
## (next, side-loads), those naming it as next, those of its belt (splitters), those feeding it.
func _mark_near(i: int) -> void:
	_mark(i)
	for p in [Vector2i(l_x0[i], l_y0[i]), Vector2i(l_x1[i], l_y1[i])]:
		var cx := _floordiv(p.x, 1024)
		var cy := _floordiv(p.y, 1024)
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var a: Variant = _exit_grid.get(Vector2i(cx + dx, cy + dy))
				if a == null:
					continue
				for j in a:
					if absi(l_x0[j] - p.x) <= 700 and absi(l_y0[j] - p.y) <= 700:
						_mark(j)
	var w: Variant = _xnext_wait.get(l_key[i])
	if w != null:
		for j in w:
			_mark(j)
	var u := _unit(l_key[i])
	for line in range(1, 9):
		var j: int = _key_idx.get(u * 8 + line, -1)
		if j >= 0:
			_mark(j)
	for j in l_feeders[i]:
		_mark(j)


func _unlink(i: int) -> void:
	var n := l_next[i]
	if n >= 0:
		var f: PackedInt32Array = l_feeders[n]
		var k := f.find(i)
		if k >= 0:
			f.remove_at(k)
			l_feeders[n] = f
	var s := l_side[i]
	if s >= 0:
		var f2: PackedInt32Array = l_sideins[s]
		var k2 := f2.find(i)
		if k2 >= 0:
			f2.remove_at(k2)
			l_sideins[s] = f2
	l_next[i] = -1
	l_side[i] = -1
	l_sp0[i] = -1
	l_sp1[i] = -1


static func _near(ax: int, ay: int, bx: int, by: int) -> bool:
	return absi(ax - bx) <= 4 and absi(ay - by) <= 4


## sim.py's build() for one lane: its next (the bridge's, or the lane whose entry is at its exit:
## the last found, as sim.py), a splitter input's outputs, else where it side-loads.
## An underground exit's lines 3-4: unused by the belt (docs/BELT-RULES.md section 3), they lie over
## the hidden lane's end. Linked by geometry they gave the exit's lane a second feeder, its line going
## back through an empty phantom lane that items pushed back by a read and items out of the tunnel met in.
func _ug_back_half(i: int) -> bool:
	if l_kind[i] != OTHER:
		return false
	var v: int = _key_idx.get(_unit(l_key[i]) * 8 + 1, -1)
	return v >= 0 and l_kind[v] == UG_VISIBLE


func _link(a: int) -> void:
	var nxt := -1
	var kind := l_kind[a]
	if _ug_back_half(a):
		l_next[a] = -1
		return
	if l_xnext[a] != 0:
		nxt = _key_idx.get(l_xnext[a], -1)
	else:
		var cx := _floordiv(l_x0[a], 32)
		var cy := _floordiv(l_y0[a], 32)
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				var arr: Variant = _entry_grid.get(Vector2i(cx + dx, cy + dy))
				if arr == null:
					continue
				for b in arr:
					# (Only an entrance's own visible half feeds its hidden line, which the bridge names
					# as its next; an exit's lines 3-4 take nothing from the belt.)
					if b != a and l_kind[b] != UG_HIDDEN and not _ug_back_half(b) and _near(l_x0[a], l_y0[a], l_x1[b], l_y1[b]):
						nxt = b
	if kind == SPLIT_IN:
		nxt = -1
	l_next[a] = nxt
	if nxt >= 0:
		var f: PackedInt32Array = l_feeders[nxt]
		f.append(a)
		l_feeders[nxt] = f
	if nxt >= 0 or kind == SPLIT_IN:
		return  # (a splitter's outputs side-load like belts; its inputs go into its outputs)
	# Side-loads: a lane whose exit is level with the middle of a straight lane in front, across it.
	var best_d := 0.0
	var best := -1
	var best_at := 0
	var cands := PackedInt32Array()
	var sx := _floordiv(l_x0[a], 512)
	var sy := _floordiv(l_y0[a], 512)
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			var arr: Variant = _side_grid.get(Vector2i(sx + dx, sy + dy))
			if arr != null:
				cands.append_array(arr)
	if cands.size() > 1:
		var order: Array = Array(cands)
		order.sort_custom(func(x: int, y: int) -> bool: return l_seq[x] < l_seq[y])
		cands = PackedInt32Array(order)
	var unit := _unit(l_key[a])
	for b in cands:
		if _unit(l_key[b]) == unit or not (l_len[b] == 256 and l_kind[b] <= CURVE or l_kind[b] == UG_VISIBLE):
			continue  # (a straight belt, or an underground's visible half)
		var ex := l_x0[b]
		var ey := l_y0[b]
		var nx := l_x1[b]
		var ny := l_y1[b]
		var vx := ex - nx
		var vy := ey - ny
		var n2 := vx * vx + vy * vy
		if n2 == 0:
			continue
		var u := float((l_x0[a] - nx) * vx + (l_y0[a] - ny) * vy) / float(n2)
		if not (0.05 < u and u < 0.95):
			continue
		var px := float(nx) + float(vx) * u
		var py := float(ny) + float(vy) * u
		var d := sqrt((float(l_x0[a]) - px) ** 2 + (float(l_y0[a]) - py) ** 2)
		if d < 140.0 and (best < 0 or d < best_d):
			best_d = d
			best = b
			best_at = _round_half_even(float(l_len[b] - 1) * (1.0 - u))
	if best >= 0:
		l_side[a] = best
		l_side_at[a] = best_at
		var f2: PackedInt32Array = l_sideins[best]
		f2.append(a)
		l_sideins[best] = f2


static func _round_half_even(x: float) -> int:
	var r := roundf(x)
	if absf(x - floorf(x) - 0.5) < 1e-12:
		var fl := int(floorf(x))
		return fl if fl % 2 == 0 else fl + 1
	return int(r)


## Each splitter unit's Splitter (its turns kept across rebuilds).
func _build_splitters() -> void:
	var units := {}
	for i in l_key.size():
		if l_alive[i] == 1 and (l_kind[i] == SPLIT_IN or l_kind[i] == SPLIT_OUT):
			units[_unit(l_key[i])] = true
	var old := _splitters
	_splitters = {}
	for u in units:
		var sp: Splitter = old.get(u, Splitter.new())
		sp.unit = u
		sp.ins = PackedInt32Array([-1, -1, -1, -1])
		sp.outs = PackedInt32Array([-1, -1, -1, -1])
		var lane_split := false
		for line in range(1, 9):
			var j: int = _key_idx.get(u * 8 + line, -1)
			if j >= 0 and l_kind[j] == SPLIT_OUT and line <= 4:
				lane_split = true
		var slots := {}  # the splitter line each lane plays -> lane
		for line in range(1, 9):
			var j: int = _key_idx.get(u * 8 + line, -1)
			if j < 0:
				continue
			var k := line
			if lane_split:
				k = {1: 1, 2: 3, 3: 5, 4: 7}.get(line, 0)
				if k == 0:
					continue
			slots[k] = j
			if k <= 4:
				sp.ins[((k - 1) / 2) * 2 + (k - 1) % 2] = j
				l_sp0[j] = (k - 1) / 2  # half
				l_sp1[j] = (k - 1) % 2  # side
			else:
				sp.outs[((k - 5) / 2) * 2 + (k - 5) % 2] = j
		var any_lane: int = slots.values()[0]
		var ex := l_extra[any_lane]
		var inp := ex % 3
		var outp := (ex / 3) % 3
		sp.filter = ex / 9
		var left := 0
		var o5: int = slots.get(5, -1)
		var o7: int = slots.get(7, -1)
		if o5 >= 0 and o7 >= 0:
			var vx := l_x0[o5] - l_x1[o5]
			var vy := l_y0[o5] - l_y1[o5]
			var lx := vy
			var ly := -vx
			left = 0 if (l_x0[o5] * lx + l_y0[o5] * ly) > (l_x0[o7] * lx + l_y0[o7] * ly) else 1
		sp.in_prio = -1 if inp == 0 else (left if inp == 1 else 1 - left)
		sp.out_prio = -1 if outp == 0 else (left if outp == 1 else 1 - left)
		_splitters[u] = sp


## The splitter inputs on the same side as an output lane (they wait for room in it).
func _split_inputs_of(out_lane: int) -> PackedInt32Array:
	var r := PackedInt32Array()
	var sp: Splitter = _splitters.get(_unit(l_key[out_lane]))
	if sp == null:
		return r
	for k in 4:
		if sp.outs[k] == out_lane:
			var side := k % 2
			for x in [sp.ins[side], sp.ins[2 + side]]:
				if x >= 0:
					r.append(x)
	return r


## Relinks the lanes marked since the last time and rebuilds the lines round them.
var _relines := {}  # lane index -> true: lanes whose lines are made again (no link changes)


func _relink() -> void:
	if not _dirty_any:
		return
	_dirty_any = false
	if _dirty.is_empty():
		_reline()
		return
	for i in _relines:
		_dirty[i] = true
	_relines.clear()
	var lanes: Array = _dirty.keys()
	_dirty.clear()
	var touched := {}
	for i in lanes:
		if l_alive[i] == 0:
			continue
		touched[i] = true
		for x in [l_next[i], l_side[i]]:
			if x >= 0:
				touched[x] = true
	var was_open := {}  # lanes that led nowhere before this relink
	for i in lanes:
		if l_alive[i] == 1:
			if l_next[i] < 0 and l_side[i] < 0 and l_kind[i] != SPLIT_IN:
				was_open[i] = true
			_unlink(i)
	# (Links in sim.py's lane order, so ties fall the same way.)
	lanes = lanes.filter(func(i: int) -> bool: return l_alive[i] == 1)
	lanes.sort_custom(func(x: int, y: int) -> bool: return l_seq[x] < l_seq[y])
	for i in lanes:
		_link(i)
		for x in [l_next[i], l_side[i]]:
			if x >= 0:
				touched[x] = true
	_build_splitters()
	# Lines change where links did: the lines of every lane touched and of the lanes feeding them.
	var dis := {}
	for i in touched:
		if l_alive[i] == 0:
			continue
		dis[l_line[i]] = true
		for f in l_feeders[i]:
			dis[l_line[f]] = true
		for f in l_sideins[i]:
			dis[l_line[f]] = true
	for id in dis:
		_dissolve_line(id)
	_order_dirty = true
	_run_dirty = true
	_order()  # (lanes first: rings are cut where sim.py starts them)
	_build_lines()
	for L in _lines:
		if L != null:
			L.ord = _lane_pos[L.lanes[0]]
	if _run_dirty:
		_runs()
	if ask_on_link:
		# A lane that led nowhere loaded and now leads on: its items (and those behind it) ran off
		# or stood at its end meanwhile, where the game's stood behind what is in front: asked for again.
		var asked := {}
		for i in was_open:
			if l_alive[i] == 0 or (l_next[i] < 0 and l_side[i] < 0) or l_line[i] < 0:
				continue
			var L: Line = _lines[l_line[i]]
			if L == null or L.uid.is_empty() or asked.has(L.id):
				continue
			asked[L.id] = true
			for x in L.lanes:
				out_mismatch.append(l_key[x])


## Lines made again round lanes switched off or on: their own and those feeding them.
func _reline() -> void:
	var dis := {}
	for i in _relines:
		if l_alive[i] == 0:
			continue
		dis[l_line[i]] = true
		for f in l_feeders[i]:
			dis[l_line[f]] = true
		var nx := l_next[i]
		if nx >= 0:
			dis[l_line[nx]] = true
	_relines.clear()
	for id in dis:
		_dissolve_line(id)
	_build_lines()
	for L in _lines:
		if L != null and L.due == maxi(tick, 0) + 1 and L.lanes.size() > 0:
			L.ord = _lane_pos[L.lanes[0]]


## A line's items go to _pending (by lane) and its lanes are freed.
func _dissolve_line(id: int) -> void:
	if id < 0 or id >= _lines.size() or _lines[id] == null:
		return
	var L: Line = _lines[id]
	var t := tick
	_materialize(L, maxi(t, L.ft))
	var pos := L.f
	var li := 0
	for j in L.uid.size():
		if j > 0:
			pos += L.gap[j]
		while li + 1 < L.lanes.size() and pos >= L.base[li + 1]:
			li += 1
		var lane: int = L.lanes[li]
		_pending.append([lane, pos - L.base[li], L.uid[j], L.itm[j], L.stk[j], L.holds.has(L.uid[j])])
		_uid_line.erase(L.uid[j])
	for lane in L.lanes:
		l_line[lane] = -1
	L.alive = false
	_lines[id] = null
	_free_lines.append(id)


func _joinable(a: int, b: int) -> bool:
	if b < 0 or a == b or l_next[a] != b:
		return false
	# Belts, curves and undergrounds of one speed (splitters, loaders and the rest are lines of their own).
	if l_kind[a] > UG_HIDDEN or l_kind[b] > UG_HIDDEN or l_step[a] != l_step[b]:
		return false
	if l_off[a] == 1 or l_off[b] == 1:
		return false
	return (l_feeders[b] as PackedInt32Array).size() == 1 and (l_sideins[b] as PackedInt32Array).is_empty()


func _build_lines() -> void:
	var free_lanes: Array = []
	for i in l_key.size():
		if l_alive[i] == 1 and l_line[i] < 0:
			free_lanes.append(i)
	# (Twice over: a ring is cut into two lines below, and when the lane past the cut was walked
	# already, the second pass gives it its line.)
	for i in free_lanes + free_lanes:
		if l_line[i] >= 0:
			continue
		# Go to the front of its line.
		var front: int = i
		var guard := 0
		while _joinable(front, l_next[front]) and l_line[l_next[front]] < 0 and guard < 100000:
			front = l_next[front]
			guard += 1
			if front == i:
				# A ring: its front is the lane sim.py steps first (it sees the lane in front not
				# stepped yet), so the ring goes as sim.py's does.
				var x0 := l_next[i]
				while x0 != i:
					if _lane_pos[x0] < _lane_pos[front]:
						front = x0
					x0 = l_next[x0]
				break
		var L := _new_line()
		L.s = l_step[front]
		var x := front
		var b := 0
		while true:
			L.lanes.append(x)
			L.base.append(b)
			l_line[x] = L.id
			l_base[x] = b
			if l_off[x] == 1:
				L.off = true
			b += l_len[x]
			var nb := -1
			for f in l_feeders[x]:
				if _joinable(f, x) and l_line[f] < 0:
					nb = f
			# (A ring of lanes is cut into two lines: one never feeds itself.)
			if nb < 0 or nb == l_next[front]:
				break
			x = nb
		L.total = b
	# Their items back, by line.
	var per: Dictionary = {}
	for p in _pending:
		var lane: int = p[0]
		if l_alive[lane] == 0 or l_line[lane] < 0:
			_gone(p[2])
			continue
		var id: int = l_line[lane]
		if not per.has(id):
			per[id] = []
		per[id].append([l_base[lane] + int(p[1]), p[2], p[3], p[4], p[5]])
	_pending = []
	for id in per:
		var L: Line = _lines[id]
		var lst: Array = per[id]
		lst.sort_custom(func(a: Array, c: Array) -> bool: return a[0] < c[0] or a[0] == c[0] and a[1] < c[1])
		for e in lst:
			_append_sorted_build(L, int(e[0]), int(e[1]), int(e[2]), int(e[3]))
			if e[4]:
				L.holds[int(e[1])] = true


func _new_line() -> Line:
	var L := Line.new()
	if not _free_lines.is_empty():
		L.id = _free_lines[_free_lines.size() - 1]
		_free_lines.resize(_free_lines.size() - 1)
		_lines[L.id] = L
	else:
		L.id = _lines.size()
		_lines.append(L)
	L.ft = maxi(tick, 0)
	L.due = -1
	L.done_tick = _cur_t if _in_step else -1
	_set_due(L, maxi(tick, 0) + 1)
	return L


func _append_sorted_build(L: Line, pos: int, uid: int, item: int, stack: int) -> void:
	if L.uid.is_empty():
		L.f = pos
		L.span = 0
		L.gap.append(0)
	else:
		var g := pos - (L.f + L.span)
		L.gap.append(g)
		L.span += g
	L.uid.append(uid)
	L.itm.append(item)
	L.stk.append(stack)
	_rec_append(L, -1)
	_uid_line[uid] = L.id
	L.lp = 1


## sim.py's order: lanes depth first after the lanes their items go on into, splitter inputs
## together; a line goes where its front lane does.
func _order() -> void:
	if not _order_dirty:
		return
	_order_dirty = false
	var nl := l_key.size()
	var all: Array = []
	for i in nl:
		if l_alive[i] == 1:
			all.append(i)
	all.sort_custom(func(x: int, y: int) -> bool: return l_seq[x] < l_seq[y])
	# Nodes: lanes, then splitters (in the order of their first lane), as sim.py's build().
	var sps: Array = []
	var seen := {}
	var outs := {}  # unit -> its outputs in lane order
	for i in all:
		if l_kind[i] == SPLIT_IN or l_kind[i] == SPLIT_OUT:
			var u := _unit(l_key[i])
			if not seen.has(u) and _splitters.has(u):
				seen[u] = true
				var sp: Splitter = _splitters[u]
				sp.node = nl + sps.size()
				sps.append(sp)
			if l_kind[i] == SPLIT_OUT:
				if not outs.has(u):
					outs[u] = []
				outs[u].append(i)
	var roots: Array = all.duplicate()
	for sp in sps:
		roots.append(sp.node)
	var state := PackedByteArray()
	state.resize(nl + sps.size())
	var order := PackedInt32Array()
	var stack_x := PackedInt32Array()
	var stack_i := PackedInt32Array()
	for r in roots:
		if state[r] != 0:
			continue
		stack_x.append(r)
		stack_i.append(0)
		while not stack_x.is_empty():
			var top := stack_x.size() - 1
			var x: int = stack_x[top]
			var k: int = stack_i[top]
			stack_x.resize(top)
			stack_i.resize(top)
			if k == 0:
				if state[x] != 0:
					continue
				state[x] = 1
			var deps: Array
			if x >= nl:
				deps = outs.get((sps[x - nl] as Splitter).unit, [])
			elif l_next[x] >= 0:
				deps = [l_next[x]]
			elif l_side[x] >= 0:
				deps = [l_side[x]]
			elif l_kind[x] == SPLIT_IN and _splitters.has(_unit(l_key[x])):
				deps = [(_splitters[_unit(l_key[x])] as Splitter).node]
			else:
				deps = []
			if k < deps.size():
				stack_x.append(x)
				stack_i.append(k + 1)
				var y: int = deps[k]
				if state[y] == 0:
					stack_x.append(y)
					stack_i.append(0)
			else:
				state[x] = 2
				order.append(x)
	# A splitter's inputs aren't in the order themselves: their splitter is, after its outputs, and
	# steps them (their lines share its place).
	var pos := PackedInt32Array()
	pos.resize(nl)
	var n := 0
	for x in order:
		if x >= nl:
			var sp2: Splitter = sps[x - nl]
			for j in sp2.ins:
				if j >= 0:
					pos[j] = n
			n += 1
		elif l_kind[x] != SPLIT_IN:
			pos[x] = n
			n += 1
	_lane_pos = pos


## Each straight lane's run beyond its exit: straight lanes of its speed and direction in a row.
func _runs() -> void:
	_run_dirty = false
	for i in l_key.size():
		l_run[i] = -1
	for i in l_key.size():
		if l_alive[i] == 0 or l_run[i] >= 0:
			continue
		var chain := PackedInt32Array()
		var x := i
		while true:
			chain.append(x)
			var nx := l_next[x]
			if l_kind[x] != STRAIGHT or nx < 0 or l_kind[nx] != STRAIGHT or l_step[nx] != l_step[x] \
					or l_off[nx] == 1 or signi(l_x0[x] - l_x1[x]) != signi(l_x0[nx] - l_x1[nx]) \
					or signi(l_y0[x] - l_y1[x]) != signi(l_y0[nx] - l_y1[nx]) or chain.size() > 100000:
				break
			if l_run[nx] >= 0:
				break
			if chain.has(nx):
				break
			x = nx
		# Back from the last of them.
		var last: int = chain[chain.size() - 1]
		var acc := 0
		var nl := l_next[last]
		var cont := nl >= 0 and l_kind[last] == STRAIGHT and l_kind[nl] == STRAIGHT and l_step[nl] == l_step[last] \
				and l_off[nl] == 0 and l_run[nl] >= 0 \
				and signi(l_x0[last] - l_x1[last]) == signi(l_x0[nl] - l_x1[nl]) \
				and signi(l_y0[last] - l_y1[last]) == signi(l_y0[nl] - l_y1[nl])
		if cont:
			acc = l_run[nl] + l_len[nl]
		for k in range(chain.size() - 1, -1, -1):
			var c: int = chain[k]
			l_run[c] = acc if l_kind[c] == STRAIGHT else 0
			acc = l_run[c] + l_len[c] if l_kind[c] == STRAIGHT else 0


# ======================================================================== stepping

func _set_due(L: Line, d: int) -> void:
	L.due = d
	if d < 0:
		return
	if _in_step and d == _cur_t:
		_heap_push((L.ord << 24) | L.id)
		return
	var b: Variant = _bucket.get(d)
	if b == null:
		_bucket[d] = [L.id]
	else:
		(b as Array).append(L.id)


## Something changed this line or ahead of it: step it at the first tick that can still see it.
func _wake(L: Line) -> void:
	if _in_step:
		var t := _cur_t
		if L.done_tick != t and L.ord > _cur_ord:
			if L.due != t:
				_set_due(L, t)
		elif L.due < 0 or L.due > t + 1:
			_set_due(L, t + 1)
	else:
		var t2 := tick + 1
		if L.due < 0 or L.due > t2:
			_set_due(L, t2)


func _heap_push(v: int) -> void:
	var h := _heap
	h.append(v)
	var i := h.size() - 1
	while i > 0:
		var p := (i - 1) >> 1
		if h[p] <= v:
			break
		h[i] = h[p]
		i = p
	h[i] = v


func _heap_pop() -> int:
	var h := _heap
	var top := h[0]
	var last := h[h.size() - 1]
	h.resize(h.size() - 1)
	var n := h.size()
	if n == 0:
		return top
	var i := 0
	while true:
		var c := 2 * i + 1
		if c >= n:
			break
		if c + 1 < n and h[c + 1] < h[c]:
			c += 1
		if h[c] >= last:
			break
		h[i] = h[c]
		i = c
	h[i] = last
	return top


func _step_tick() -> void:
	var r0 := Time.get_ticks_usec()
	_relink()
	us_relink += Time.get_ticks_usec() - r0
	var t := tick + 1
	given.clear()
	if split_wake and not _splitters.is_empty():
		_note_outputs()
	_in_step = true
	_cur_t = t
	_cur_ord = -1
	var b: Variant = _bucket.get(t)
	_bucket.erase(t)
	if b != null:
		for id in b:
			var L: Line = _lines[id] if id < _lines.size() else null
			if L != null and L.due == t:
				_heap_push((L.ord << 24) | id)
	while not _heap.is_empty():
		var v := _heap_pop()
		var id := v & 0xFFFFFF
		var L: Line = _lines[id] if id < _lines.size() else null
		if L == null or L.due != t or L.done_tick == t:
			continue
		_cur_ord = L.ord
		var l0: int = L.lanes[0]
		if l_kind[l0] == SPLIT_IN and _splitters.has(_unit(l_key[l0])):
			var sp: Splitter = _splitters[_unit(l_key[l0])]
			if sp.done_tick != t:
				sp.done_tick = t
				var c1 := Time.get_ticks_usec() if profile else 0
				_step_side(sp, 0, t)
				_step_side(sp, 1, t)
				if profile:
					step_us[1] += Time.get_ticks_usec() - c1
			continue
		L.done_tick = t
		if profile:
			var c0 := Time.get_ticks_usec()
			_step_line(L, t)
			var edge := l_next[l0] < 0 and not _is_sidesplit(l0) and edge_mode == EDGE_ORACLE
			step_us[0 if edge else 1] += Time.get_ticks_usec() - c0
		else:
			_step_line(L, t)
	_in_step = false
	tick = t


## (split_wake) Each splitter output's hindmost item where it is now (the end of the tick before the
## one about to be stepped), the last one's kept.
func _note_outputs() -> void:
	for sp: Splitter in _splitters.values():
		for o in sp.outs:
			if o < 0:
				continue
			_ob2[o] = _ob1.get(o, -1)
			var b := -1
			var id := l_line[o]
			if id >= 0 and _lines[id] != null:
				var X: Line = _lines[id]
				if not X.uid.is_empty():
					_materialize(X, tick)
					var q := X.f + X.span - l_base[o]
					if q >= 0 and q < l_len[o]:
						b = q
			_ob1[o] = b


func _step_input(lane: int, t: int) -> void:
	if lane < 0 or l_line[lane] < 0:
		return
	var L: Line = _lines[l_line[lane]]
	if L == null or L.due != t or L.done_tick == t:
		return
	L.done_tick = t
	_step_line(L, t)


## A splitter side's two inputs, in the order its in_turn says. While that isn't known (the replay's
## first ticks), both orders are tried and the one that does what the game did is kept (sim.py).
func _step_side(sp: Splitter, side: int, t: int) -> void:
	if sp.in_turn[side] >= 0 or sp.in_prio >= 0 or edge_mode != EDGE_ORACLE:
		var first := sp.in_prio if sp.in_prio >= 0 else maxi(sp.in_turn[side], 0)
		_step_input(sp.ins[first * 2 + side], t)
		_step_input(sp.ins[(1 - first) * 2 + side], t)
		return
	var lanes := [sp.ins[side], sp.ins[2 + side], sp.outs[side], sp.outs[2 + side]]
	var lines: Array = []
	for x in lanes:
		if x >= 0 and l_line[x] >= 0 and not lines.has(l_line[x]):
			lines.append(l_line[x])
	var saved: Array = []
	for id in lines:
		saved.append(_snap(_lines[id]))
	var out_turn := sp.out_turn.duplicate()
	var outs_n := out_uid.size()
	var gone_n := out_gone.size()
	var before := sp.crossed
	for first in 2:
		if first == 1:
			for k in lines.size():
				_unsnap(_lines[lines[k]], saved[k])
			sp.out_turn = out_turn.duplicate()
			_trim_out(outs_n, gone_n)
		sp.in_turn[side] = first
		before = sp.crossed
		_step_input(sp.ins[first * 2 + side], t)
		_step_input(sp.ins[(1 - first) * 2 + side], t)
		var ok := true
		for id in lines:
			var L: Line = _lines[id]
			_materialize(L, t)
			var q := L.f
			for j in L.uid.size():
				if j > 0:
					q += L.gap[j]
				var g: Variant = oracle.get(L.uid[j])
				if g != null:
					var li := _lane_at(L, q)
					if int(g[0]) != l_key[L.lanes[li]] or int(g[1]) != q - L.base[li]:
						ok = false
						break
			if not ok:
				break
		if ok:
			break
	if sp.crossed == before:
		sp.in_turn[side] = -1  # (nothing crossed: still not known)


func _snap(L: Line) -> Array:
	return [L.uid.duplicate(), L.itm.duplicate(), L.stk.duplicate(), L.gap.duplicate(), L.f, L.span, L.ft,
		L.mode, L.ck, L.due, L.lp, L.lp2_from, L.lp2, L.bp, L.bp_tick, L.arr, L.arr_tick, L.done_tick,
		L.rs.duplicate(), L.rv.duplicate(), L.pr_has, L.pr_pos, L.pr_t, L.pr_v, L.holds.duplicate()]


func _unsnap(L: Line, a: Array) -> void:
	L.uid = a[0]
	L.itm = a[1]
	L.stk = a[2]
	L.gap = a[3]
	L.f = a[4]
	L.span = a[5]
	L.ft = a[6]
	L.mode = a[7]
	L.ck = a[8]
	L.due = a[9]
	L.lp = a[10]
	L.lp2_from = a[11]
	L.lp2 = a[12]
	L.bp = a[13]
	L.bp_tick = a[14]
	L.arr = a[15]
	L.arr_tick = a[16]
	L.done_tick = a[17]
	L.rs = a[18]
	L.rv = a[19]
	L.pr_has = a[20]
	L.pr_pos = a[21]
	L.pr_t = a[22]
	L.pr_v = a[23]
	L.holds = a[24]
	for u in L.uid:
		_uid_line[u] = L.id


func _trim_out(n: int, ng: int) -> void:
	out_uid.resize(mini(out_uid.size(), n))
	out_item.resize(mini(out_item.size(), n))
	out_stack.resize(mini(out_stack.size(), n))
	out_key.resize(mini(out_key.size(), n))
	out_pos.resize(mini(out_pos.size(), n))
	out_tick.resize(mini(out_tick.size(), n))
	out_speed.resize(mini(out_speed.size(), n))
	out_reach.resize(mini(out_reach.size(), n))
	out_run.resize(mini(out_run.size(), n))
	out_gone.resize(mini(out_gone.size(), ng))
	out_gone_tick.resize(mini(out_gone_tick.size(), ng))
	out_gone_at.resize(mini(out_gone_at.size(), ng))


## Items closer than 64 behind the one in front on a splitter's output can only be a priority input's,
## standing till they are 64 behind (sim.py does this when it loads the game's state).
func mark_split_holds() -> void:
	_relink()
	for L in _lines:
		if L == null or l_kind[L.lanes[0]] != SPLIT_OUT:
			continue
		for j in range(1, L.uid.size()):
			if L.gap[j] < GAP:
				L.holds[L.uid[j]] = true


func _materialize(L: Line, t: int) -> void:
	if t <= L.ft:
		return
	var d := t - L.ft
	if L.mode == 1:
		L.f -= L.s * d
	elif L.mode == 2:
		L.gap[L.ck] -= L.s * d
		L.span -= L.s * d
	L.ft = t


func _front_at(L: Line, t: int) -> int:
	if L.mode == 1 and t > L.ft:
		return L.f - L.s * (t - L.ft)
	return L.f


func _back_at(L: Line, t: int) -> int:
	var b := L.f + L.span
	if L.mode != 0 and t > L.ft:
		b -= L.s * (t - L.ft)
	return b


func _done(X: Line, t: int) -> bool:
	return X.done_tick == t or X.ord < _cur_ord


## sim.py's ahead_limit from a line's front: [0, new, old] the hindmost item in front (in this line's
## positions: now and before this tick's move), [1, limit] a dead end there, [2] nothing near.
var _ah_new := 0
var _ah_old := 0
var _still := false  # the line just stepped moved nothing


func _ahead(A: Line, t: int) -> int:
	var x := l_next[A.lanes[0]]
	var off := 0
	while x >= 0 and off <= WALK:
		if l_off[x] == 1:
			_ah_new = -off
			return 1
		var X: Line = _lines[l_line[x]]
		if not X.uid.is_empty():
			var bn: int
			var bo: int
			if _done(X, t):
				bn = _back_at(X, t)
				if X.bp_tick == t:
					bo = X.bp
				elif X.mode != 0:
					bo = bn + X.s
				else:
					bo = bn
			else:
				bo = _back_at(X, t - 1)
				bn = bo - X.s
			var e := l_base[x] + l_len[x]
			_ah_new = bn - e - off
			_ah_old = bo - e - off
			return 0
		off += l_base[x] + l_len[x]
		x = l_next[X.lanes[0]]
	if x < 0:
		_ah_new = -off
		return 1
	return 2


func _is_sidesplit(l0: int) -> bool:
	return l_side[l0] >= 0 or l_kind[l0] == SPLIT_IN


## One tick of a line, exactly sim.py's lane steps for its lanes.
func _step_line(A: Line, t: int) -> void:
	n_line_steps += 1
	_materialize(A, t - 1)
	var n := A.uid.size()
	if n == 0:
		A.mode = 0
		A.due = -1
		A.ft = t
		_promise(A, t)
		return
	if A.off:
		A.mode = 0
		A.ft = t
		A.bp = A.f + A.span
		A.bp_tick = t
		_emit_pattern(A, t, 0)
		A.due = -1
		_promise(A, t)
		return
	var s := A.s
	var l0: int = A.lanes[0]
	var len0 := l_len[l0]
	var nx := l_next[l0]
	var sidesplit := _is_sidesplit(l0)
	var n_eff := n
	if A.arr_tick == t:
		n_eff = n - A.arr
	var F := A.f
	var back_old := F + A.span
	# The front item's limit.
	var lk := 0  # 0 tuple (la new, lo old), 1 scalar la
	var la := 0
	var lo := 0
	var in0 := F < len0
	# A lane leading out: its wall (set_wall). wall_i: the wall item's index when items run off ahead of it.
	var wall_i := -1
	var wall_p := 0
	var wall_on := nx < 0 and not sidesplit and not _out_keys.is_empty() and _out_keys.has(l_key[l0])
	if wall_on:
		lk = 1
		var w: Variant = _wall_at(l_key[l0], t)
		if w == null:
			la = F  # (none yet: it stands)
		elif int(w[1]) == 0:
			la = FAR
		else:
			var iw := A.uid.find(int(w[1]))
			if iw > 0:
				la = FAR
				wall_i = iw
				wall_p = int(w[2])
			else:
				la = int(w[2])  # (the item itself, or not here: the front stops there)
	elif in0 and sidesplit:
		lk = 1
		la = FAR
	elif in0 and nx < 0:
		lk = 1
		if edge_mode == EDGE_ORACLE:
			var u: int = A.uid[0]
			given[u] = true
			var g: Variant = oracle.get(u)
			if g != null and int(g[0]) == l_key[l0]:
				la = int(g[1])
			else:
				la = FAR
		elif edge_mode == EDGE_STOP:
			la = 0
		else:
			la = FAR
	else:
		var r := _ahead(A, t)
		if r == 0:
			la = _ah_new
			lo = _ah_old
		elif r == 1:
			lk = 1
			la = _ah_new
		else:
			lk = 1
			la = FAR
	var spd_change := nx >= 0 and l_step[nx] != s
	var ns := l_step[nx] if nx >= 0 else s
	_seg_i.resize(0)
	_seg_v.resize(0)
	# --- the head: items processed one by one (crossing the exit, or in a side/split lane 0) ---
	var hb := s
	if sidesplit:
		hb = maxi(hb, len0)
	var holds := A.holds
	var held := not holds.is_empty()
	if held:
		hb = 1 << 40  # (items held by a splitter's priority input: all one by one)
	# A lane leading out of the square (the replay): the item behind one that left follows the game.
	var open_front := nx < 0 and not sidesplit and edge_mode == EDGE_ORACLE
	var hp := PackedInt32Array()  # old positions
	var hm := PackedInt32Array()  # moves
	var p := F
	var m_prev := 0
	var i := 0
	while i < n_eff:
		var follow := false
		if i > 0:
			p += A.gap[i]
			follow = open_front and p < len0 and hp[i - 1] - hm[i - 1] < 0
			if p >= hb and not follow and i > wall_i:
				break
		var mf := s
		if p - s < 0 and spd_change and s > 0:
			mf = p + ((s - p) * ns) / s
		var m: int
		if i == 0:
			if lk == 1:
				m = mf if la == FAR else maxi(0, mini(mf, p - la))
			elif held and holds.has(A.uid[0]):
				m = maxi(0, mini(mf, (lo - la) + (p - lo) - GAP))
			else:
				m = maxi(0, mini(mf, (lo - la) + maxi(0, (p - lo) - GAP)))
		elif held and holds.has(A.uid[i]):
			m = maxi(0, mini(mf, m_prev + A.gap[i] - GAP))
		else:
			m = maxi(0, mini(mf, m_prev + maxi(0, A.gap[i] - GAP)))
		if i == wall_i:
			m = maxi(0, mini(m, p - wall_p))
		if follow:
			var g: Variant = oracle.get(A.uid[i])
			if g != null and int(g[0]) == l_key[l0]:
				m = maxi(0, mini(mf, p - int(g[1])))
				given[A.uid[i]] = true
		hp.append(p)
		hm.append(m)
		m_prev = m
		i += 1
	var h := i  # items 0 .. h-1 are the head
	# New head positions; what leaves at the exit.
	var hn := PackedInt32Array()
	hn.resize(h)
	for k in h:
		hn[k] = hp[k] - hm[k]
	var keep := PackedByteArray()  # 1 stays, 0 left
	keep.resize(h)
	keep.fill(1)
	var removed := 0
	var gone_front := false
	if sidesplit:
		# sim.py: the lane-0 items moved; past the exit they join the other lane or the splitter's
		# outputs where there is room, else wait at 0; behind one that waited they stand a gap back.
		for k in h:
			if hn[k] < 0:
				var ok: bool
				if l_side[l0] >= 0:
					ok = _side_put(A, k, l0, hn[k], hp[k], t)
				else:
					ok = _split_put(A, k, l0, hn[k], t, hp, hn, h)
				if ok:
					keep[k] = 0
					removed += 1
				else:
					hn[k] = 0
		var lim := FAR
		for k in h:
			if keep[k] == 0:
				continue
			if lim > FAR and hn[k] < lim:
				hn[k] = lim
			lim = hn[k] + GAP
	else:
		for k in h:
			if hn[k] >= 0:
				break
			if nx >= 0:
				if head_move:
					_emit_left(A, k, t, hp, hn)
				_transfer(A, k, nx, hn[k], hp[k], t)
				keep[k] = 0
				removed += 1
			elif edge_mode == EDGE_RUN_OFF or wall_on:
				if head_move:
					_emit_left(A, k, t, hp, hn)
				keep[k] = 0
				removed += 1
				_uid_line.erase(A.uid[k])
				holds.erase(A.uid[k])
				_gone(A.uid[k])
			# (EDGE_ORACLE: it stays, past the end, as in sim.py.)
	# --- the tail: tight gaps carry the move, loose gaps take up the slack ---
	var m_tail := s
	var tail_first_new := 0
	if h < n_eff:
		var p_h := p  # old position of item h (computed when the head loop stopped)
		var m_h: int
		if sidesplit:
			# The first item behind lane 0: limited by lane 0's hindmost item as it is now, or the end.
			var lastk := -1
			for k in range(h - 1, -1, -1):
				if keep[k] == 1:
					lastk = k
					break
			var mf2 := s
			if lastk >= 0:
				m_h = maxi(0, mini(mf2, (hp[lastk] - hn[lastk]) + maxi(0, (p_h - hp[lastk]) - GAP)))
			else:
				m_h = clampi(p_h - 0, 0, mf2)
		elif h == 0:
			m_h = 0  # (unreachable: the head always holds item 0)
		else:
			m_h = maxi(0, mini(s, hm[h - 1] + maxi(0, A.gap[h] - GAP)))
		_seg_push(h, m_h)
		tail_first_new = p_h - m_h
		m_tail = _tail(A, h + 1, m_h, n_eff)
	elif h < n:
		tail_first_new = p + A.gap[h]  # (the first arrived item: it stays where it is)
	# (No head when every item arrived this tick, into a ring's line not stepped yet: they stand.)
	var m_last := m_tail if h < n_eff else (hm[h - 1] if h > 0 else 0)
	# --- write the line back ---
	# Head records: compare and emit before indices shift.
	_emit_head(A, t, h, hp, hm, hn, keep)
	# Remove the head items that left, rewrite the head's positions.
	var new_head := PackedInt32Array()
	var idx_keep := PackedInt32Array()
	for k in h:
		if keep[k] == 1:
			new_head.append(hn[k])
			idx_keep.append(k)
	var arrived := A.arr_tick == t and A.arr > 0
	_compact_head(A, h, idx_keep, new_head, tail_first_new, n_eff)
	n = A.uid.size()
	A.ft = t
	A.mode = 0
	if n == 0:
		A.due = -1
		_promise(A, t)
		_put_self_side(A, t)
		return
	# The back: the arrived items' (they didn't move), the tail's, or the last head item's.
	if arrived:
		A.span = back_old - A.f
	elif h < n_eff:
		A.span = back_old - m_last - A.f
	else:
		A.span = new_head[new_head.size() - 1] - A.f
	if arrived:
		# The arrived items didn't move: the gap in front of the first of them took the move.
		var fa := n - A.arr
		if h < n_eff and fa >= 1:
			A.gap[fa] += m_last
	elif h < n_eff:
		A.bp = back_old
		A.bp_tick = t
	else:
		A.bp = hp[idx_keep[idx_keep.size() - 1]]
		A.bp_tick = t
	_emit_tail(A, t, h - removed)
	# Did anything move? (Side-loads and splitters waiting for room here look again only then.)
	var moved := removed > 0
	if not moved:
		for k in h:
			if hn[k] != hp[k]:
				moved = true
				break
	if not moved:
		for v in _seg_v:
			if v != 0:
				moved = true
				break
	if moved:
		_wake_waiting(A)
	_still = not moved
	_schedule(A, t)
	_put_self_side(A, t)


## The side-loads and splitter inputs that put items onto this line: they wait for room in it.
func _wake_waiting(A: Line) -> void:
	var back: int = A.lanes[A.lanes.size() - 1]
	for f in l_sideins[back]:
		var id := l_line[f]
		if id >= 0 and _lines[id] != null:
			_wake(_lines[id])
	if l_kind[back] == SPLIT_OUT:
		for j in _split_inputs_of(back):
			if l_line[j] >= 0 and _lines[l_line[j]] != null:
				_wake(_lines[l_line[j]])


func _split_outs_asleep(in_lane: int) -> bool:
	var sp: Splitter = _splitters.get(_unit(l_key[in_lane]))
	if sp == null:
		return true
	var side := l_sp1[in_lane]
	return _asleep(sp.outs[side]) and _asleep(sp.outs[2 + side])


func _asleep(lane: int) -> bool:
	if lane < 0 or l_line[lane] < 0:
		return true
	var X: Line = _lines[l_line[lane]]
	return X == null or X.mode == 0 and X.due < 0


func _min_gap(A: Line) -> int:
	var g := A.gap
	var m := 1 << 30
	for j in range(1, g.size()):
		if g[j] < m:
			m = g[j]
	return m


## Pushes a movement run (index, speed) for the emitter.
func _seg_push(i: int, v: int) -> void:
	var n := _seg_v.size()
	if n > 0 and _seg_v[n - 1] == v:
		return
	_seg_i.append(i)
	_seg_v.append(v)


## Items i0 .. n_eff - 1 behind one that moved m: tight gaps carry m, loose ones take up the slack.
func _tail(A: Line, i0: int, m: int, n_eff: int) -> int:
	var s := A.s
	var i := i0
	while m < s:
		var k := _next_loose(A, i, n_eff)
		if k >= n_eff:
			break
		var mk := mini(s, m + A.gap[k] - GAP)
		A.gap[k] -= mk - m
		A.span -= mk - m
		_seg_push(k, mk)
		m = mk
		i = k + 1
	return m


func _next_loose(A: Line, from: int, lim: int) -> int:
	var g := A.gap
	var k := from
	if from <= A.lp:
		k = A.lp
		while k < lim and g[k] <= GAP:
			k += 1
		A.lp = k
		return k
	if from >= A.lp2_from and from <= A.lp2:
		k = A.lp2
		while k < lim and g[k] <= GAP:
			k += 1
		A.lp2 = k
		return k
	while k < lim and g[k] <= GAP:
		k += 1
	A.lp2_from = from
	A.lp2 = k
	return k


## The head items that stay keep their new positions; those gone are cut; the gap behind the head
## is set from the first tail item's new position (the tail's gaps are already updated).
func _compact_head(A: Line, h: int, idx_keep: PackedInt32Array, new_head: PackedInt32Array,
		tail_first_new: int, n_eff: int) -> void:
	var n := A.uid.size()
	var removed := h - idx_keep.size()
	if removed == 0 and h == 1:
		A.f = new_head[0]
		if n > 1:
			A.gap[1] = tail_first_new - new_head[0]
			if A.gap[1] > GAP:
				A.lp = 1
		return
	var has_tail := h < n
	# Positions: head explicit; the tail from tail_first_new by its gaps (from h + 1 on).
	if removed > 0:
		# Records: drop the removed indices from the runs.
		var drop := PackedInt32Array()
		var kk := 0
		for k in h:
			if kk < idx_keep.size() and idx_keep[kk] == k:
				kk += 1
			else:
				drop.append(k)
		for k in range(drop.size() - 1, -1, -1):
			_rec_remove(A, drop[k])
		# Arrays.
		var nu := PackedInt64Array()
		var ni := PackedInt32Array()
		var nk := PackedInt32Array()
		for k in idx_keep:
			nu.append(A.uid[k])
			ni.append(A.itm[k])
			nk.append(A.stk[k])
		nu.append_array(A.uid.slice(h))
		ni.append_array(A.itm.slice(h))
		nk.append_array(A.stk.slice(h))
		var ng := PackedInt32Array()
		ng.resize(idx_keep.size())
		ng.append_array(A.gap.slice(h))
		A.uid = nu
		A.itm = ni
		A.stk = nk
		A.gap = ng
		A.lp = maxi(1, A.lp - removed)
		if A.lp2_from < (1 << 29):
			A.lp2_from = maxi(1, A.lp2_from - removed)
			A.lp2 = maxi(A.lp2_from, A.lp2 - removed)
	var hk := idx_keep.size()
	n = A.uid.size()
	if n == 0:
		A.f = 0
		A.span = 0
		return
	# Head positions.
	var span := 0
	if hk > 0:
		A.f = new_head[0]
		for k in range(1, hk):
			A.gap[k] = new_head[k] - new_head[k - 1]
			if A.gap[k] > GAP and k < A.lp:
				A.lp = k
		if has_tail:
			A.gap[hk] = tail_first_new - new_head[hk - 1]
			if A.gap[hk] > GAP and hk < A.lp:
				A.lp = hk
	else:
		A.f = tail_first_new
	A.gap[0] = 0
	A.lp = maxi(1, mini(A.lp, n))


# ---------------------------------------------------------------- moving items between lines

## An item past a line's exit goes on into the next lane (at its back), as sim.py.
func _transfer(A: Line, k: int, nx: int, new_pos: int, old_pos: int, t: int) -> void:
	var X: Line = _lines[l_line[nx]]
	var u: int = A.uid[k]
	var e := l_base[nx] + l_len[nx]
	var done := _done(X, t)
	_materialize(X, t if done else t - 1)
	var at := e + new_pos
	var j := _insert(X, at, u, A.itm[k], A.stk[k], -1)
	if A.holds.has(u):
		A.holds.erase(u)
		X.holds[u] = true
	if not done and j == X.uid.size() - 1:
		if X.arr_tick != t:
			X.arr_tick = t
			X.arr = 0
		X.arr += 1
	if j == X.uid.size() - 1:
		X.bp = e + old_pos
		X.bp_tick = t
	# Records: an item going on along its run at its speed in a line flowing the same keeps its record.
	if X.mode != 0 and done:
		_rec_set_one(X, j, X.s)
		_emit_one(u, X.itm[j], X.stk[j], nx, at - l_base[nx], t, X.s, at)
	if X.mode == 0 or not done:
		_wake(X)
	_touched_promise(X, t)


## sim.py's side-load: onto the other lane a step past the point level with this lane's exit, where
## there is room (64 to the item in front, 61 to the one behind), else it waits.
func _side_put(A: Line, k: int, l0: int, new_pos: int, _old_pos: int, t: int) -> bool:
	var b := l_side[l0]
	var X: Line = _lines[l_line[b]]
	var jj0 := l_side_at[l0]
	# (A step past the point level with the side lane: 59 for 68 moving 8.)
	var at := jj0 - 1 + new_pos
	var u: int = A.uid[k]
	if X == A:
		# Onto its own back lane (a loop whose end side-loads onto its start; one on Aquilo crashed the
		# C++ twin): the line is being stepped, its head and item count taken before the move, so the
		# item can't go in yet. Whether it fits is judged on the lane as the line stands; it goes in
		# once the step has written the line back, as into a line stepped already (_put_self_side).
		var fit := _side_at(A, b, at)
		if fit > jj0 + 60 or fit >= l_len[b]:
			return false
		_self_side.append([A, u, A.itm[k], A.stk[k], A.holds.has(u), b, at])
		A.holds.erase(u)
		return true
	var done := _done(X, t)
	_materialize(X, t if done else t - 1)
	# Behind what is in the way on the other lane, but never further back than the side lane's own
	# width (60 past the point), else it waits.
	at = _side_at(X, b, at)
	if at > jj0 + 60 or at >= l_len[b]:
		return false
	_side_insert(X, b, at, u, A.itm[k], A.stk[k], A.holds.has(u), t)
	A.holds.erase(u)
	return true


## Where an item side-loaded at `at` on lane b of line X goes: where an item of that lane (after its
## move this tick) is in the way, 64 behind it instead, and behind the next if that is in the way
## too (_side_put says how far back is too far).
func _side_at(X: Line, b: int, at: int) -> int:
	var lo := l_base[b]
	var hi := lo + l_len[b]
	var n := X.uid.size()
	if n > 0:
		# The first item of lane b (from the back).
		var q := X.f + X.span
		var j := n - 1
		while j > 0 and q - X.gap[j] >= lo:
			q -= X.gap[j]
			j -= 1
		if q >= lo or lo == 0:
			while j < n:
				if q >= hi:
					break
				var ql := q - lo
				if at - GAP < ql and ql < at + GAP - 3:
					at = ql + GAP
				j += 1
				if j < n:
					q += X.gap[j]
	return at


## A side-loaded item into lane b of line X at `at`.
func _side_insert(X: Line, b: int, at: int, u: int, item: int, stack: int, held: bool, t: int) -> void:
	var lo := l_base[b]
	var jj := _insert(X, lo + at, u, item, stack, -1)
	if held:
		X.holds[u] = true
	if jj == X.uid.size() - 1:
		X.bp = lo + at
		X.bp_tick = t
	_wake(X)
	_touched_promise(X, t)


## Side-loads onto a line's own back lane, made while it was stepped (_side_put): [line, uid, item,
## stack, held, lane, at].
var _self_side: Array = []


## The side-loads line A made onto its own back lane during its step, put in now that the step has
## written it back (A.ft is t): where they fit on the lane as it is now, at worst its back end.
func _put_self_side(A: Line, t: int) -> void:
	if _self_side.is_empty():
		return
	var later: Array = []
	for e: Array in _self_side:
		if e[0] != A:
			later.append(e)  # (another line's: left for the end of its own step)
			continue
		var b: int = e[5]
		var at := mini(_side_at(A, b, int(e[6])), l_len[b] - 1)
		_side_insert(A, b, at, int(e[1]), int(e[2]), int(e[3]), bool(e[4]), t)
	_self_side = later


var _sp_newpos := 0  # (an item's new position, as _fallback_ok may change it)


## sim.py's splitter: into the output its turn says (or its priority, or its filter), where there is
## room, else the other (with an output priority, only as _fallback_ok allows); else it waits. (Kept
## apart so measured splitter rules can replace it.)
func _split_put(A: Line, k: int, l0: int, new_pos: int, t: int, hp: PackedInt32Array,
		hn: PackedInt32Array, h: int) -> bool:
	_sp_newpos = new_pos
	var sp: Splitter = _splitters.get(_unit(l_key[l0]))
	if sp == null:
		return false
	if not _in_holds.is_empty() and _in_holds.has(l0) and t > int(_in_holds[l0]):
		n_held += 1
		return false
	var half := l_sp0[l0]
	var side := l_sp1[l0]
	var uid: int = A.uid[k]
	var item: int = A.itm[k]
	if sp.out_turn[side] < 0 and sp.out_prio < 0 and sp.filter == 0:
		# Its turn not known yet: the way the game sent this item says it (the replay).
		var g: Variant = oracle.get(uid)
		if g != null:
			for hh in 2:
				var o0: int = sp.outs[hh * 2 + side]
				if o0 >= 0 and l_key[o0] == int(g[0]):
					sp.out_turn[side] = hh
	var tries := PackedInt32Array()
	if sp.filter != 0:
		var fh := sp.out_prio if sp.out_prio >= 0 else 0
		tries.append(sp.outs[(fh if item == sp.filter else 1 - fh) * 2 + side])
	elif sp.out_prio >= 0:
		tries.append(sp.outs[sp.out_prio * 2 + side])
		tries.append(sp.outs[(1 - sp.out_prio) * 2 + side])
	else:
		var tt := maxi(sp.out_turn[side], 0)
		tries.append(sp.outs[tt * 2 + side])
		tries.append(sp.outs[(1 - tt) * 2 + side])
	for ti in tries.size():
		var o: int = tries[ti]
		if o < 0:
			continue
		if ti == 1 and sp.out_prio >= 0 and tries[0] >= 0 and not _fallback_ok(A, k, l0, tries[0], hp, hn, h, t):
			break
		var X: Line = _lines[l_line[o]]
		_materialize(X, t)
		var olen := l_len[o]
		var empty := X.uid.is_empty()
		var back_l := X.f + X.span - l_base[o]
		var at := olen - SPLIT_BUFFER + _sp_newpos
		if not empty:
			at = maxi(at, back_l + GAP)
			if split_wake and at < olen and sp.in_prio < 0 and sp.out_prio < 0 and sp.filter == 0:
				var b1: int = _ob1.get(o, -1)
				if b1 >= 0 and b1 + GAP >= olen and b1 == int(_ob2.get(o, -1)):
					var lx: int = t - int(_side_x.get(sp.unit * 2 + side, -100))
					var oo: int = sp.outs[(1 if o == sp.outs[side] else 0) * 2 + side]
					if lx >= 1 and (lx <= 2 or lx == 3 and oo >= 0 and int(_ob1.get(oo, -1)) != int(_ob2.get(oo, -1))):
						n_woke += 1
						continue
		var hold := false
		if at >= olen and sp.in_prio == half and (empty or back_l < olen - 1):
			# The priority input's item goes in anyway, at the output's back, however close the item
			# in front, and stands there until it is 64 behind it.
			at = olen - 1
			hold = true
		if at < olen:
			var jj := _insert(X, l_base[o] + at, uid, item, A.stk[k], -1)
			A.holds.erase(uid)
			if hold:
				X.holds[uid] = true
			if jj == X.uid.size() - 1:
				X.bp = l_base[o] + at
				X.bp_tick = t
			sp.crossed += 1
			_side_x[sp.unit * 2 + side] = t
			sp.out_turn[side] = 1 - (0 if o == sp.outs[side] else 1)
			sp.in_turn[side] = 1 - half
			_wake(X)
			_touched_promise(X, t)
			return true
	return false


## With an output priority, may an item the priority output has no room for go into the other one
## this tick? Only when nothing follows it on its input's line; or the item behind it stood 64
## behind it all last tick; or, the priority output's back being further off than 64, the item behind
## comes within 64 of it this tick (it then goes just far enough). (sim.py's fallback_ok.)
func _fallback_ok(A: Line, k: int, l0: int, prio: int, hp: PackedInt32Array, hn: PackedInt32Array,
		h: int, t: int) -> bool:
	if h > 1 and k != 1:
		if hp[1] - hp[k] <= GAP:
			return true
		var X: Line = _lines[l_line[prio]]
		_materialize(X, t)
		if not X.uid.is_empty() and X.f + X.span - l_base[prio] + GAP > l_len[prio] and hn[1] - GAP < 0:
			_sp_newpos = hn[1] - GAP
			return true
		return false
	var x := l0
	for _i in 64:
		var f: PackedInt32Array = l_feeders[x]
		if f.size() != 1:
			break
		x = f[0]
		if _lane_has_items(x, t):
			return false
	return true


func _lane_has_items(x: int, t: int) -> bool:
	var id := l_line[x]
	if id < 0 or _lines[id] == null:
		return false
	var L: Line = _lines[id]
	if L.uid.is_empty():
		return false
	_materialize(L, maxi(L.ft, t - 1) if not _done(L, t) else t)
	var lo := l_base[x]
	var hi := lo + l_len[x]
	var q := L.f
	for j in L.uid.size():
		if j > 0:
			q += L.gap[j]
		if q >= hi:
			return false
		if q >= lo or lo == 0:
			return true
	return false


## Inserts an item at line position `pos` (sorted; after items at the same place with a lower uid).
## Returns its index. The line must be materialized at the current tick.
func _insert(X: Line, pos: int, uid: int, item: int, stack: int, rv: int) -> int:
	var n := X.uid.size()
	_uid_line[uid] = X.id
	if n == 0:
		X.uid.append(uid)
		X.itm.append(item)
		X.stk.append(stack)
		X.gap.append(0)
		X.f = pos
		X.span = 0
		X.lp = 1
		X.rs = PackedInt32Array([0])
		X.rv = PackedInt32Array([rv])
		return 0
	var back := X.f + X.span
	if pos > back or pos == back and uid > X.uid[n - 1]:
		X.uid.append(uid)
		X.itm.append(item)
		X.stk.append(stack)
		X.gap.append(pos - back)
		X.span += pos - back
		_rec_append(X, rv)
		if pos - back > GAP and n < X.lp:
			X.lp = n
		return n
	# In the middle (or in front): find its place.
	var q := X.f
	var j := 0
	while j < n:
		if j > 0:
			q += X.gap[j]
		if q > pos or q == pos and X.uid[j] > uid:
			break
		j += 1
	# j: the first item behind it; q its position.
	if j == 0:
		X.uid.insert(0, uid)
		X.itm.insert(0, item)
		X.stk.insert(0, stack)
		X.gap.insert(1, q - pos)
		X.gap[0] = 0
		X.f = pos
		X.span += q - pos
	else:
		var prev := q - X.gap[j]
		X.uid.insert(j, uid)
		X.itm.insert(j, item)
		X.stk.insert(j, stack)
		X.gap.insert(j, pos - prev)
		X.gap[j + 1] = q - pos
	_rec_insert(X, j, rv)
	X.lp = 1
	X.lp2_from = 1 << 30
	if X.mode == 2:
		X.mode = 0  # (its shrinking gap moved: the line is stepped next, see the callers)
	return j


func _remove_at(X: Line, j: int) -> void:
	var n := X.uid.size()
	if n == 1:
		X.uid.resize(0)
		X.itm.resize(0)
		X.stk.resize(0)
		X.gap.resize(0)
		X.span = 0
		X.rs = PackedInt32Array()
		X.rv = PackedInt32Array()
		return
	if j == 0:
		X.f += X.gap[1]
		X.span -= X.gap[1]
		X.gap.remove_at(1)
		X.gap[0] = 0
	elif j == n - 1:
		X.span -= X.gap[j]
		X.gap.remove_at(j)
	else:
		X.gap[j + 1] += X.gap[j]
		X.gap.remove_at(j)
	X.uid.remove_at(j)
	X.itm.remove_at(j)
	X.stk.remove_at(j)
	_rec_remove(X, j)
	X.lp = 1
	X.lp2_from = 1 << 30
	if X.mode == 2 and X.ck >= j:
		X.mode = 0


## A line changed outside its step (an item put on or taken off): step it next tick, tell those behind.
func _touched(L: Line, _t: int) -> void:
	L.mode = 0
	L.ft = tick
	_wake(L)
	_wake_waiting(L)
	_promise(L, tick)


func _touched_promise(X: Line, t: int) -> void:
	_promise(X, t)


# ---------------------------------------------------------------- scheduling and promises

## After a step: how the line goes on (flowing, its front standing, asleep, or stepped next tick)
## and the tick it must be stepped at.
func _schedule(A: Line, t: int) -> void:
	var n := A.uid.size()
	var s := A.s
	var F := A.f
	A.ft = t
	var l0: int = A.lanes[0]
	var len0 := l_len[l0]
	var nx := l_next[l0]
	var sidesplit := _is_sidesplit(l0)
	if s <= 0:
		# (A belt of no speed (tests): nothing on it ever moves.)
		_enter_mode(A, t, 0, 0)
		A.due = -1
		_promise(A, t)
		return
	var K := NEVER
	if F < 0:
		K = 0
	else:
		K = F / s
	if nx < 0 and edge_mode == EDGE_ORACLE and not sidesplit:
		K = mini(K, (F - len0) / s + 1 if F >= len0 else 0)
	elif sidesplit and F < len0 and (not A.holds.is_empty() or _min_gap(A) < GAP):
		# (Its last lane's gaps under 64 are put back to 64 every tick: stepped every tick then.
		# Otherwise its front flows on to its end like any line's.)
		K = 0
	elif sidesplit:
		K = mini(K, (F - len0) / s + 1 if F >= len0 else NEVER)
		if K == 0 and not sidesplit:
			prof[7] += 1
	if A.arr_tick == t and A.arr > 0:
		K = 0
	# The item in front (its promise: where it is now, how fast its back goes on).
	var has := false
	var D0 := 0
	var v := 0
	var ahead_ok := true
	if not (F < len0 and (sidesplit or nx < 0)):
		var x := nx
		var off := 0
		while x >= 0 and off <= WALK:
			if l_off[x] == 1:
				break
			var X: Line = _lines[l_line[x]]
			if not X.uid.is_empty():
				if not _done(X, t):
					ahead_ok = false
					break
				var e := l_base[x] + l_len[x]
				# (Its promise, not where it is: what it wakes us on.)
				var a := X.pr_pos - X.pr_v * (t - X.pr_t) - e - off
				has = true
				D0 = F - a
				v = X.pr_v
				break
			off += l_base[x] + l_len[x]
			x = l_next[X.lanes[0]]
	if not ahead_ok:
		K = 0
		prof[6] += 1
	elif has:
		var Ka := NEVER
		if D0 >= GAP:
			if D0 + v < GAP + s:
				Ka = 0
			elif v >= s:
				Ka = NEVER
			else:
				Ka = (D0 + v - GAP - s) / (s - v) + 1
		else:
			Ka = NEVER if v >= s else 0
		K = mini(K, Ka)
	# A lane leading out (set_wall): stepped every tick until its front stands at a wall no later one moves.
	var wall_lane := nx < 0 and not sidesplit and not _out_keys.is_empty() and _out_keys.has(l_key[l0])
	var wall_blocked := false
	if wall_lane:
		K = 0
		var w: Variant = _wall_at(l_key[l0], t + 1)
		wall_blocked = n > 0 and _wall_settled(l_key[l0], t) and (w == null or int(w[1]) == A.uid[0] and F == int(w[2]))
	if K >= 1:
		_enter_mode(A, t, 1, 0)
		_set_due(A, t + K + 1 if K < NEVER else -1)
	else:
		var blocked := false
		if has and v == 0 and D0 <= GAP:
			blocked = true
		elif wall_lane:
			blocked = wall_blocked
		elif F == 0 and nx < 0 and not sidesplit and edge_mode == EDGE_STOP:
			blocked = true
		if blocked and not sidesplit and not (nx < 0 and edge_mode == EDGE_ORACLE and F < len0) \
				and not (A.arr_tick == t and A.arr > 0):
			var k := _next_loose(A, 1, n)
			if k >= n:
				_enter_mode(A, t, 0, 0)
				A.due = -1
			else:
				var K2 := (A.gap[k] - GAP) / s
				if K2 >= 1:
					_enter_mode(A, t, 2, k)
					_set_due(A, t + K2 + 1)
				else:
					why_tick[8] += 1
					A.mode = 0
					_set_due(A, t + 1)
		elif sidesplit and _still and F < len0 and (l_side[l0] >= 0 and _asleep(l_side[l0]) 				or l_kind[l0] == SPLIT_IN and _split_outs_asleep(l0)):
			# Waiting for room where nothing moves: asleep until the other line moves, its items' records
			# standing (one still saying it moves would be drawn moving on while it waits).
			_enter_mode(A, t, 0, 0)
			A.due = -1
		else:
			prof[5] += 1
			# (Why it is stepped next tick: probes.)
			var why := 6
			if A.arr_tick == t and A.arr > 0:
				why = 4
			elif sidesplit:
				why = 1
			elif F < s:
				why = 5
			elif has and v > 0:
				why = 3
			elif has:
				why = 7
			why_tick[why] += 1
			A.mode = 0
			_set_due(A, t + 1)
	_promise(A, t)


## The line goes on lazily from tick t: mode 1 (all move s), 2 (front standing, items from ck on
## moving s), 0 with no due (all stand). Items whose record says otherwise get a new one at t.
func _enter_mode(A: Line, t: int, mode: int, ck: int) -> void:
	A.mode = mode
	A.ck = ck
	A.ft = t
	if mode == 1:
		_emit_pattern(A, t, A.s)
	elif mode == 2:
		_emit_pattern2(A, t, ck)
	else:
		_emit_pattern(A, t, 0)


## Its back as a promise to the lines behind; wakes them when the new one is worse for them (its
## back further behind than promised, or slower), and those waiting behind it when it moved at all.
func _promise(A: Line, t: int) -> void:
	var has := not A.uid.is_empty()
	var pos := 0
	var v := 0
	if has:
		pos = _back_at(A, t)
		if A.mode != 0:
			v = A.s
		elif A.due == t + 1 and A.bp_tick == t:
			# Stepped every tick: its back goes on as it went this tick until its next step says
			# otherwise (and wakes the lines behind if it is worse).
			v = maxi(0, A.bp - pos)
	var worse := false
	var changed := false
	if has != A.pr_has:
		changed = true
		worse = has
	elif has:
		var pred := A.pr_pos - A.pr_v * (t - A.pr_t)
		if pos > pred or v < A.pr_v:
			worse = true
		if pos != pred or v != A.pr_v:
			changed = true
	A.pr_has = has
	A.pr_pos = pos
	A.pr_t = t
	A.pr_v = v
	if changed:
		_wake_readers(A, worse)


## The lines behind this one: feeding its back lane, side-loading onto it, a splitter's inputs.
func _wake_readers(A: Line, worse: bool, depth: int = 0) -> void:
	var back: int = A.lanes[A.lanes.size() - 1]
	for f in l_feeders[back]:
		_wake_one(l_line[f], worse, depth)
	for f in l_sideins[back]:
		_wake_one(l_line[f], worse, depth)
	if l_kind[back] == SPLIT_OUT:
		for j in _split_inputs_of(back):
			_wake_one(l_line[j], worse, depth)


func _wake_one(id: int, worse: bool, depth: int) -> void:
	if id < 0:
		return
	var R: Line = _lines[id]
	if R == null:
		return
	if R.uid.is_empty():
		if depth < 12:
			_wake_readers(R, worse, depth + 1)
		return
	if not worse and R.mode == 1:
		return
	_wake(R)


# ---------------------------------------------------------------- records (output)

func _gone(uid: int) -> void:
	if emit_changes:
		out_gone.append(uid)
		out_gone_tick.append(_cur_t if _in_step else tick)
		out_gone_at.append(out_uid.size())


func _emit_one(uid: int, item: int, stack: int, lane: int, pos: int, t: int, v: int, line_pos: int) -> void:
	if not emit_changes:
		return
	out_uid.append(uid)
	out_item.append(item)
	out_stack.append(stack)
	out_key.append(l_key[lane])
	out_pos.append(pos)
	out_tick.append(t)
	out_speed.append(v)
	out_reach.append(line_pos if v > 0 else 0)
	out_run.append(pos + (l_run[lane] if l_kind[lane] == STRAIGHT and l_run[lane] >= 0 else 0) if v > 0 else 0)


## The lane of a line position.
func _lane_at(L: Line, pos: int) -> int:
	if L.lanes.size() == 1 or pos < 0:
		return 0
	var k := L.base.bsearch(pos, false) - 1
	return clampi(k, 0, L.lanes.size() - 1)


func _rec_append(X: Line, v: int) -> void:
	var n := X.uid.size() - 1  # its index (already appended)
	var r := X.rv.size()
	if r > 0 and X.rv[r - 1] == v:
		return
	X.rs.append(n)
	X.rv.append(v)


## The run index holding item j.
func _rec_index(X: Line, j: int) -> int:
	var k := X.rs.bsearch(j, false) - 1
	return maxi(k, 0)


func _rec_insert(X: Line, j: int, v: int) -> void:
	# Items from j on shift by one; item j gets its own run. (X.uid holds it already.)
	var old_n := X.uid.size() - 1
	var nrs := PackedInt32Array()
	var nrv := PackedInt32Array()
	var placed := false
	for k in X.rs.size():
		var st: int = X.rs[k]
		var en: int = X.rs[k + 1] if k + 1 < X.rs.size() else old_n
		var vv: int = X.rv[k]
		if en <= j:
			nrs.append(st)
			nrv.append(vv)
		elif st >= j:
			if not placed:
				nrs.append(j)
				nrv.append(v)
				placed = true
			nrs.append(st + 1)
			nrv.append(vv)
		else:
			nrs.append(st)
			nrv.append(vv)
			nrs.append(j)
			nrv.append(v)
			nrs.append(j + 1)
			nrv.append(vv)
			placed = true
	if not placed:
		nrs.append(j)
		nrv.append(v)
	X.rs = nrs
	X.rv = nrv
	_rec_norm(X)


func _rec_remove(X: Line, j: int) -> void:
	var nrs := PackedInt32Array()
	var nrv := PackedInt32Array()
	var n := X.uid.size()  # after the removal
	for k in X.rs.size():
		var st: int = X.rs[k]
		var en: int = X.rs[k + 1] if k + 1 < X.rs.size() else n + 1
		var ns := st if st <= j else st - 1
		var ne := en if en <= j else en - 1
		if ne > ns:
			nrs.append(ns)
			nrv.append(X.rv[k])
	X.rs = nrs
	X.rv = nrv
	_rec_norm(X)


func _rec_set_one(X: Line, j: int, v: int) -> void:
	var r := _rec_index(X, j)
	if X.rv[r] == v:
		return
	var st: int = X.rs[r]
	var en: int = X.rs[r + 1] if r + 1 < X.rs.size() else X.uid.size()
	var nrs := X.rs.slice(0, r)
	var nrv := X.rv.slice(0, r)
	if st < j:
		nrs.append(st)
		nrv.append(X.rv[r])
	nrs.append(j)
	nrv.append(v)
	if j + 1 < en:
		nrs.append(j + 1)
		nrv.append(X.rv[r])
	nrs.append_array(X.rs.slice(r + 1))
	nrv.append_array(X.rv.slice(r + 1))
	X.rs = nrs
	X.rv = nrv
	_rec_norm(X)


func _rec_norm(X: Line) -> void:
	var n := X.uid.size()
	var nrs := PackedInt32Array()
	var nrv := PackedInt32Array()
	for k in X.rs.size():
		var st: int = X.rs[k]
		if st >= n:
			break
		if not nrs.is_empty() and nrv[nrv.size() - 1] == X.rv[k]:
			continue
		if not nrs.is_empty() and nrs[nrs.size() - 1] == st:
			nrv[nrv.size() - 1] = X.rv[k]
			continue
		nrs.append(st)
		nrv.append(X.rv[k])
	if nrs.is_empty() and n > 0:
		nrs.append(0)
		nrv.append(-1)
	elif not nrs.is_empty():
		nrs[0] = 0
	X.rs = nrs
	X.rv = nrv


## Emits the head items whose move this tick isn't their record's (as their position before the
## tick, at t - 1, and this move): before the head is rewritten. The move is where it went (hn), not
## the step it was given (hm): a side-load or splitter input's items that found no room wait at 0 and
## those behind a gap back, less than their step. Items that left the line too (it gets them as far
## as its exit; where they went says the rest): one a read put here last tick, its record not made
## yet, was drawn where it was before the read.
func _emit_head(A: Line, t: int, h: int, hp: PackedInt32Array, hm: PackedInt32Array,
		hn: PackedInt32Array, keep: PackedByteArray) -> void:
	for k in h:
		if not head_move:
			# (As before: the step it was given, items that left not emitted.)
			if keep[k] == 0:
				continue
			var r := _rec_index(A, k)
			if A.rv[r] != hm[k]:
				var li := _lane_at(A, hp[k])
				_emit_one(A.uid[k], A.itm[k], A.stk[k], A.lanes[li], hp[k] - A.base[li], t - 1, hm[k], hp[k])
				_rec_set_one(A, k, hm[k])
			continue
		_emit_left(A, k, t, hp, hn)


## (_emit_head) Item k of the head, its move this tick if that isn't its record's. One leaving the
## line into the next or off its end is emitted before it goes (what the next line or the drawing
## makes of it comes after).
func _emit_left(A: Line, k: int, t: int, hp: PackedInt32Array, hn: PackedInt32Array) -> void:
	var m := hp[k] - hn[k]
	var r := _rec_index(A, k)
	if m < 0:
		# Pushed back (a gap behind an item waiting at a splitter or side-load): standing where it went.
		var lb := _lane_at(A, hn[k])
		_emit_one(A.uid[k], A.itm[k], A.stk[k], A.lanes[lb], hn[k] - A.base[lb], t, 0, hn[k])
		_rec_set_one(A, k, 0)
		return
	if A.rv[r] != m:
		var li := _lane_at(A, hp[k])
		var lane: int = A.lanes[li]
		_emit_one(A.uid[k], A.itm[k], A.stk[k], lane, hp[k] - A.base[li], t - 1, m, hp[k])
		_rec_set_one(A, k, m)


## Emits tail items whose move this tick (the runs in _seg_i/_seg_v, in pre-removal indices from
## the head's end) isn't their record's. `shift`: head items removed.
func _emit_tail(A: Line, t: int, hk: int) -> void:
	if _seg_i.is_empty():
		return
	var n := A.uid.size()
	var removed_shift := 0
	# _seg_i holds old indices; the head (old 0..h-1) became 0..hk-1, so old index i >= h maps to
	# i - (h - hk). _seg_i[0] is h.
	var h_old: int = _seg_i[0]
	removed_shift = h_old - hk
	var pos := -1
	var pos_i := -1
	for si in _seg_i.size():
		var a: int = _seg_i[si] - removed_shift
		var b: int = (_seg_i[si + 1] - removed_shift) if si + 1 < _seg_i.size() else n
		if A.arr_tick == t:
			b = mini(b, n - A.arr)
		var v: int = _seg_v[si]
		if a >= b:
			continue
		# Find the record runs over [a, b) that differ.
		var r := _rec_index(A, a)
		var j := a
		var differs := false
		while j < b:
			var en: int = A.rs[r + 1] if r + 1 < A.rs.size() else n
			var e2 := mini(en, b)
			if A.rv[r] != v:
				differs = true
				# Emit items j .. e2 - 1.
				if pos_i < 0 or pos_i > j:
					pos = A.f
					pos_i = 0
				while pos_i < j:
					pos_i += 1
					pos += A.gap[pos_i]
				var q := pos
				var qi := pos_i
				while qi < e2:
					var old := q + v
					var li := _lane_at(A, old)
					var lane: int = A.lanes[li]
					_emit_one(A.uid[qi], A.itm[qi], A.stk[qi], lane, old - A.base[li], t - 1, v, old)
					qi += 1
					if qi < n:
						q += A.gap[qi]
			j = e2
			r += 1
		if differs:
			_rec_set_range(A, a, b, v)


func _rec_set_range(X: Line, a: int, b: int, v: int) -> void:
	if a >= b:
		return
	var n := X.uid.size()
	var nrs := PackedInt32Array()
	var nrv := PackedInt32Array()
	var placed := false
	for k in X.rs.size():
		var st: int = X.rs[k]
		var en: int = X.rs[k + 1] if k + 1 < X.rs.size() else n
		if en <= a or st >= b:
			if st >= b and not placed:
				nrs.append(a)
				nrv.append(v)
				placed = true
			nrs.append(st)
			nrv.append(X.rv[k])
			continue
		if st < a:
			nrs.append(st)
			nrv.append(X.rv[k])
		if not placed:
			nrs.append(a)
			nrv.append(v)
			placed = true
		if en > b:
			nrs.append(b)
			nrv.append(X.rv[k])
	if not placed:
		nrs.append(a)
		nrv.append(v)
	X.rs = nrs
	X.rv = nrv
	_rec_norm(X)


## Entering a lazy mode at t: items whose record isn't `v` get one (their place at t).
func _emit_pattern(A: Line, t: int, v: int) -> void:
	_emit_range_if(A, t, 0, A.uid.size(), v)


func _emit_pattern2(A: Line, t: int, ck: int) -> void:
	_emit_range_if(A, t, 0, ck, 0)
	_emit_range_if(A, t, ck, A.uid.size(), A.s)


func _emit_range_if(A: Line, t: int, a: int, b: int, v: int) -> void:
	if a >= b or A.rv.size() == 1 and A.rv[0] == v:
		return
	var n := A.uid.size()
	var r := _rec_index(A, a)
	var j := a
	var pos := A.f
	var pi := 0
	var any := false
	while j < b:
		var en: int = A.rs[r + 1] if r + 1 < A.rs.size() else n
		var e2 := mini(en, b)
		if A.rv[r] != v:
			any = true
			while pi < j:
				pi += 1
				pos += A.gap[pi]
			var q := pos
			var qi := pi
			while qi < e2:
				var li := _lane_at(A, q)
				_emit_one(A.uid[qi], A.itm[qi], A.stk[qi], A.lanes[li], q - A.base[li], t, v, q)
				qi += 1
				if qi < n:
					q += A.gap[qi]
		j = e2
		r += 1
	if any:
		_rec_set_range(A, a, b, v)


## How the lanes are joined (debugging): lanes with a next, side-loading, splitter inputs, leading nowhere.
func debug_links() -> Dictionary:
	_relink()
	var d := {"next": 0, "side": 0, "split": 0, "none": 0}
	for i in l_key.size():
		if l_alive[i] == 0:
			continue
		if l_next[i] >= 0:
			d["next"] += 1
		elif l_side[i] >= 0:
			d["side"] += 1
		elif l_kind[i] == SPLIT_IN:
			d["split"] += 1
		else:
			d["none"] += 1
	return d


## The line holding an item, for debugging: its lanes, mode, due tick and items.
func debug_item(uid: int) -> Dictionary:
	var id: int = _uid_line.get(uid, -1)
	if id < 0:
		return {}
	var L: Line = _lines[id]
	var keys := PackedInt64Array()
	for x in L.lanes:
		keys.append(l_key[x])
	return {"lanes": keys, "base": L.base, "mode": L.mode, "due": L.due, "ft": L.ft, "f": L.f,
		"span": L.span, "gap": L.gap, "uid": L.uid, "lp": L.lp, "ck": L.ck, "ord": L.ord,
		"pr": [L.pr_has, L.pr_pos, L.pr_t, L.pr_v], "done": L.done_tick}
