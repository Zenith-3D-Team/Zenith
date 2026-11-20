extends SceneTree
## The inserter swing from events (scripts/world/inserter_swing.gd plan_events and the arms layer's
## event path, scripts/world/inserter_arms.gd) against a hand moved as Factorio moves it: the game
## hand of inserter_swing_test.gd, with the events the bridge would make of it (picked and dropped
## at the exact ticks with the hand's position, a sync first and mid-swing probes), read back at
## every tick: the hand's error, the item's tick, and the swing's ends. Then the arms layer itself
## fed the events as `ie` messages (each repeated over three messages, some lost, some out of
## order), with an uncertain pick dated back by the exact drop after it. Fast, offline, no scene:
##
##   godot --headless --path client -s res://tests/inserter_events_test.gd [-- --verbose]

const Swing := preload("res://scripts/world/inserter_swing.gd")
const Arms := preload("res://scripts/world/inserter_arms.gd")
const Anim := preload("res://scripts/world/anim.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const BurnerFx := preload("res://scripts/fx/burner_fx.gd")
const FactorioShader := preload("res://shaders/factorio_material.gdshader")

var failures := 0
var verbose := false


class Rec:
	var pos := Vector2.ZERO
	var proto_id := 1
	var dir := 0
	var extra := {}
	var unit := 0
	var key: Variant = 0  # (world.gd Rec: the entity's key, its unit for those with one)
	var chunk := Vector2i.ZERO


class StubWorld extends Node3D:
	signal entities_changed(chunk: Vector2i)
	var entities := {}
	var chunks := {}


class StubChunk:
	var entities := {}


func check(cond: bool, what: String) -> void:
	if cond:
		print("PASS ", what)
	else:
		failures += 1
		print("FAIL ", what)


## A game hand tick by tick ([angle, reach, item] from tick 0), as inserter_swing_test.gd's: from the
## pickup, waits `hold_pick`, takes `item` (at `grab`, [angle, reach], when given: a belt item short
## of the point), swings to the drop, waits `hold_drop`, drops, swings back. A hand taking on the
## axis (no `grab`) sweeps the other side each cycle, as the game's does (out and back over one side,
## the next cycle over the other); one taking a belt item off the axis the short way, so the same.
func game_hand(omega: float, v: float, pick: Array, drop: Array, hold_pick: int, hold_drop: int, item: int, ticks: int, grab: Array = []) -> Array:
	var out := []
	var angle: float = pick[0]
	var reach: float = pick[1]
	var held := 0
	var wait := hold_pick
	var target: Array = []
	var w := omega * TAU
	var t := 0
	var out_sign := 1.0  # the outbound half circle's sense this cycle (+: over the east side)
	while t < ticks:
		if target.is_empty():
			if wait > 0:
				out.append([angle, reach, held])
				wait -= 1
				t += 1
				continue
			if held == 0:
				held = item
				out.append([angle, reach, held])
				target = drop
				if grab.is_empty() and t > 0:
					out_sign = -out_sign
			else:
				held = 0
				out.append([angle, reach, held])
				target = grab if not grab.is_empty() else pick
				wait = hold_pick
			t += 1
			continue
		var da := wrapf(target[0] - angle, -PI, PI)
		if absf(absf(da) - PI) < 1e-6:
			da = out_sign * PI if held != 0 else -out_sign * PI  # (a half circle: out and back over one side)
		var dr: float = target[1] - reach
		var step_a := w * signf(da)
		var step_r := v * signf(dr)
		var arrived := true
		if absf(da) <= w * 2.0 + 1e-9 and absf(da) > w + 1e-9:
			angle = target[0]
		elif absf(da) <= w + 1e-9:
			angle = target[0]
		else:
			angle += step_a
			arrived = false
		if absf(dr) <= v * 2.0 + 1e-9:
			reach = target[1]
		else:
			reach += step_r
			arrived = false
		angle = wrapf(angle, -PI, PI)
		out.append([angle, reach, held])
		t += 1
		if arrived:
			target = []
			wait = hold_drop if held != 0 else hold_pick
	return out


## The bridge's events of a game hand: [tick, kind, count, item, angle, reach], a sync at `t0`, a
## pick or drop at every change, a probe mid-way on the first two legs.
func events_of(hand: Array, t0: int) -> Array:
	var out := []
	var legs := 0
	var probe_at := -1
	for t in range(t0, hand.size()):
		var h: Array = hand[t]
		if t == t0:
			out.append([float(t), Swing.Ev.SYNC, 1 if h[2] != 0 else 0, h[2], h[0], h[1], 0])
			continue
		var prev: Array = hand[t - 1]
		if h[2] != 0 and prev[2] == 0:
			out.append([float(t), Swing.Ev.PICKED, 1, h[2], h[0], h[1], 0])
			legs += 1
			if legs <= 2 or legs % 8 == 0:
				probe_at = t + 6
		elif h[2] == 0 and prev[2] != 0:
			out.append([float(t), Swing.Ev.DROPPED, 0, prev[2], h[0], h[1], 0])
		elif t == probe_at:
			out.append([float(t), Swing.Ev.SYNC, 1 if h[2] != 0 else 0, h[2], h[0], h[1], 0, true])
	return out


## The side each event's cycle sweeps over, as inserter_arms.gd _event_side has it: a probe (an event
## with an 8th element true) mid-way anchors its cycle, before or after the event; a cycle without
## one takes its neighbour's: the other side for a hand taking on the axis, the same for a belt
## item (`belt`).
func sides_of(evs: Array, pick: Array, drop: Array, belt: bool) -> Array:
	var cycle_of := []
	var anchors := []
	var last_count := 0
	var c := -1
	for e in evs:
		if e[1] == Swing.Ev.PICKED and last_count == 0:
			c += 1
			anchors.append(NAN)
		cycle_of.append(c)
		if e[1] == Swing.Ev.SYNC and e.size() > 7 and e[7] and c >= 0 and is_nan(anchors[c]) and Swing.on_side(e[4], pick, drop):
			anchors[c] = e[4]
		last_count = e[2]
	var flip := func(s: float) -> float: return s if belt else wrapf(2.0 * pick[0] - s, -PI, PI)
	var prev := NAN
	for k in anchors.size():
		if is_nan(anchors[k]) and not is_nan(prev):
			anchors[k] = flip.call(prev)
		prev = anchors[k]
	var nxt := NAN
	for k in range(anchors.size() - 1, -1, -1):
		if is_nan(anchors[k]) and not is_nan(nxt):
			anchors[k] = flip.call(nxt)
		nxt = anchors[k]
	var out := []
	for ci in cycle_of:
		if ci < 0:
			out.append(flip.call(anchors[0]) if not anchors.is_empty() and not is_nan(anchors[0]) else NAN)
		else:
			out.append(anchors[ci])
	return out


## The plans from the events read back at every tick against the game hand (the probes, mid-way
## positions, are no plan anchors, as in the arms layer).
func measure(hand: Array, evs: Array, pick: Array, drop: Array, omega: float, v: float, belt := false) -> Dictionary:
	var sides := sides_of(evs, pick, drop, belt)
	# (Before the first probe the side of a half circle is a guess: not measured, as the arms layer
	# draws 20-60 ticks behind the events and has the probe by then.)
	var from := 0.0
	for e in evs:
		if e.size() > 7 and e[7]:
			from = float(e[0])
			break
	var err_sum := 0.0
	var err_max := 0.0
	var n := 0
	var item_wrong := 0
	var ends_ok := true
	var arcs := []
	var last_turn := NAN
	var dir := 0.0
	for i in range(evs.size()):
		var e0: Array = evs[i]
		if e0.size() > 7 and e0[7]:
			continue  # a probe
		var j := i + 1
		while j < evs.size() and evs[j].size() > 7 and evs[j][7]:
			j += 1
		var e1: Array = evs[j] if j < evs.size() else []
		var keys := Swing.plan_events(e0, e1, pick, drop, omega, v, sides[i])
		var stop: int = int(e1[0]) if not e1.is_empty() else mini(hand.size(), int(e0[0]) + 200)
		for t in range(int(e0[0]), stop):
			if t < from:
				continue
			var pose := Swing.at(keys, float(t))
			var truth: Array = hand[t]
			var e := Swing.hand_pos(pose[0], pose[1]).distance_to(Swing.hand_pos(truth[0], truth[1]))
			err_sum += e
			err_max = maxf(err_max, e)
			n += 1
			if pose[2] != truth[2]:
				item_wrong += 1
			var a := wrapf(pose[0], -PI, PI)
			if not is_nan(last_turn):
				var d := wrapf(a - last_turn, -PI, PI)
				if absf(d) > 1e-6:
					var s := signf(d)
					if dir != 0.0 and s != dir:
						var at_end := absf(wrapf(last_turn - pick[0], -PI, PI)) < deg_to_rad(2.0) or absf(wrapf(last_turn - drop[0], -PI, PI)) < deg_to_rad(2.0)
						ends_ok = ends_ok and at_end
						arcs.append(last_turn)
					dir = s
			last_turn = a
	return {"pos_err": err_sum / maxi(n, 1), "pos_max": err_max, "item_wrong": item_wrong, "ticks": n, "ends": ends_ok, "turns": arcs.size()}


func _init() -> void:
	verbose = "--verbose" in OS.get_cmdline_user_args()
	var pick := [-PI / 2.0, 1.0]
	var drop := [PI / 2.0, 1.2]
	var kinds := {"inserter": [0.014, 0.035], "fast-inserter": [0.04, 0.1], "long-handed-inserter": [0.02, 0.05], "burner-inserter": [0.013, 0.035]}
	var long_pick := [-PI / 2.0, 2.0]
	var long_drop := [PI / 2.0, 2.2]
	for name in kinds:
		var omega: float = kinds[name][0]
		var v: float = kinds[name][1]
		var pk := long_pick if name == "long-handed-inserter" else pick
		var dp := long_drop if name == "long-handed-inserter" else drop
		for holds in [[0, 0], [10, 4], [40, 0]]:
			var hand := game_hand(omega, v, pk, dp, holds[0], holds[1], 7, 1500)
			for t0 in [0, 5, 17]:
				var m := measure(hand, events_of(hand, t0), pk, dp, omega, v)
				var tag := "%s (holds %d/%d, from tick %d)" % [name, holds[0], holds[1], t0]
				if verbose:
					print("  ", tag, ": ", m)
				# From exact events the hand is the game's to within a few hundredths (the snapped last
				# step and the sync's starting pose), the item exactly, every turn at an end.
				check(m["pos_err"] < 0.02 and m["pos_max"] < 0.25, "%s: the hand from events is within 0.02 tile of the game's on average (%.3f / %.3f)" % [tag, m["pos_err"], m["pos_max"]])
				check(m["item_wrong"] <= 1, "%s: the item is in the hand exactly when the game's is (%d ticks wrong)" % [tag, m["item_wrong"]])
				# (A hand taking on the axis goes on round at the pickup, the next cycle over the other
				# side: it turns at the drop only.)
				check(m["ends"] and m["turns"] >= 10, "%s: every drawn swing turns at an end (%d turns)" % [tag, m["turns"]])
	# A belt item taken short of the pickup point and off its axis: the hand goes to the nominal point,
	# reaches for the item where it takes it, and turns for the drop from there.
	var omega := 0.04
	var v := 0.1
	var grab := [-PI / 2.0 + 0.25, 0.8]
	var hand_belt := game_hand(omega, v, pick, drop, 0, 0, 7, 1200, grab)
	var mb := measure(hand_belt, events_of(hand_belt, 0), pick, drop, omega, v, true)
	if verbose:
		print("  belt grab: ", mb)
	check(mb["pos_err"] < 0.08 and mb["item_wrong"] <= 1, "a belt item taken off the pickup point: the hand reaches for it where it was taken, the item exact (error %.3f, item wrong %d)" % [mb["pos_err"], mb["item_wrong"]])
	# Past the last event the hand goes on to the end it is bound for and waits there.
	var keys := Swing.plan_events([100.0, Swing.Ev.PICKED, 1, 7, -PI / 2.0, 1.0], [], pick, drop, 0.014, 0.035, 0.0)
	var p_mid := Swing.at(keys, 118.0)
	var p_end := Swing.at(keys, 200.0)
	check(is_equal_approx(p_end[1], 1.2) and absf(wrapf(p_end[0] - PI / 2.0, -PI, PI)) < 1e-4 and p_end[2] == 7
		and absf(p_mid[0] - (-PI / 2.0 + 18.0 * 0.014 * TAU)) < 1e-4,
		"past the last event: on to the drop at its speeds (%.3f at 18 ticks), waiting there holding the item" % p_mid[0])
	# Collecting more at the pickup: between two picks the hand stays about where it is.
	var kc := Swing.plan_events([100.0, Swing.Ev.PICKED, 1, 7, -PI / 2.0, 1.0], [103.0, Swing.Ev.PICKED, 2, 7, -PI / 2.0 + 0.1, 0.9], pick, drop, 0.04, 0.1, 0.0)
	var pc := Swing.at(kc, 102.0)
	check(Swing.hand_pos(pc[0], pc[1]).distance_to(Swing.hand_pos(-PI / 2.0, 1.0)) < 0.2 and pc[2] == 7,
		"a bulk hand collecting stays at the pickup between its picks, holding from the first")
	# A status read mid-way: the hand goes straight to that position.
	var ks := Swing.plan_events([100.0, Swing.Ev.PICKED, 1, 7, -PI / 2.0, 1.0], [106.0, Swing.Ev.SYNC, 1, 7, -PI / 2.0 + 6.0 * 0.014 * TAU, 1.1], pick, drop, 0.014, 0.035, 0.0)
	var ps := Swing.at(ks, 103.0)
	# (The turn a step a tick to the read position; the stretch at its own speed, done in 2 ticks.)
	check(absf(ps[0] - (-PI / 2.0 + 3.0 * 0.014 * TAU)) < 1e-3 and absf(ps[1] - 1.1) < 1e-3, "a position read mid-way is reached straight (%.3f, %.3f at 3 of 6 ticks)" % [ps[0], ps[1]])

	_arms_layer()
	_held_at_grip()
	_burner_fx()
	_sprite_arms()
	print("inserter_events_test: %s (%d failure(s))" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(1 if failures > 0 else 0)


## The arms layer fed `ie` messages: a basic inserter (chest to chest, holds 10/4), each event in three
## messages two ticks apart as the bridge sends them, every third message lost and one pair swapped;
## the arm read at every tick 40 behind; then an uncertain pick dated back by the exact drop.
func _arms_layer() -> void:
	var protos := ProtoDB.new()
	var p := ProtoDB.EntityProto.new()
	p.id = 1
	p.name = "inserter"
	p.type = "inserter"
	protos.entities[1] = p
	var world := StubWorld.new()
	var rec := Rec.new()
	rec.pos = Vector2(10.5, 20.5)
	rec.dir = 0  # pickup north (ip (0, -1) turned by 0): angle -90 degrees
	world.entities[77] = rec
	Arms.belt_clock = true
	var arms := Arms.new()
	arms.protos = protos
	arms.world = world
	arms.eprops = {1: {"x": {"ip": [0, -1], "id": [0, 1.2], "rs": 0.014, "es": 0.035}}}
	root.add_child(world)
	root.add_child(arms)
	var pick := [-PI / 2.0, 1.0]
	var drop := [PI / 2.0, 1.2]
	var hand := game_hand(0.014, 0.035, pick, drop, 10, 4, 7, 900)
	var evs := events_of(hand, 0)
	# `ie` records: [kind, unit, tick, a, b, c, x, y (1/256), belt]; a sync's c is the status code.
	var recs := []
	for e in evs:
		var pos: Vector2 = (rec.pos + Swing.hand_pos(e[4], e[5])) * 256.0
		var c := 0
		recs.append([int(e[1]), 77, int(e[0]), int(e[2]), int(e[3]), c, roundi(pos.x), roundi(pos.y), 1 if e.size() > 7 and e[7] else 0])
	var msgs := []
	var k := 1
	while k < 900:
		var l := []
		for r in recs:
			if r[2] > k - 6 and r[2] <= k:
				l.append_array(r)
		msgs.append({"t": "ie", "k": k, "n": 6, "p": 2, "part": 1, "parts": 1, "l": l})
		k += 2
	# Every third message lost; messages 20 and 21 swapped.
	var fed := []
	for i in msgs.size():
		if i % 3 == 2:
			continue
		fed.append(msgs[i])
	var tmp = fed[20]
	fed[20] = fed[21]
	fed[21] = tmp
	var err_sum := 0.0
	var n := 0
	var item_wrong := 0
	var fi := 0
	for t in range(1, 900):
		while fi < fed.size() and fed[fi]["k"] <= t:
			arms.handle_events(fed[fi])
			fi += 1
		var drawn := t - 40
		if drawn < 1:
			continue
		var arm = arms._arms.get(77)
		if arm == null:
			continue
		arms._pose_at(arm, float(drawn))
		var truth: Array = hand[drawn]
		err_sum += Swing.hand_pos(arm.angle, arm.reach).distance_to(Swing.hand_pos(truth[0], truth[1]))
		n += 1
		if (arm.item_id != 0) != (truth[2] != 0):
			item_wrong += 1
	check(n > 800 and err_sum / maxi(n, 1) < 0.03 and item_wrong <= 2,
		"the arms layer from `ie` messages (a third lost, two swapped): hand within 0.03 tile on average (%.3f over %d ticks), item wrong %d ticks" % [err_sum / maxi(n, 1), n, item_wrong])
	check(arms.count() == 1 and arms._arms[77].bound and not is_nan(arms._arms[77].side),
		"the arm is bound to its record and learnt its sweep's side from the mid-swing syncs (side %.2f)" % arms._arms[77].side)
	# An uncertain pick (the mod checked 20 ticks apart) followed by an exact drop 35 ticks of swing
	# later: the pick is dated back to the drop minus the leg.
	var arms2 := Arms.new()
	arms2.protos = protos
	arms2.world = world
	arms2.eprops = arms.eprops
	root.add_child(arms2)
	var base := rec.pos
	var at_pick: Vector2 = (base + Swing.hand_pos(pick[0], pick[1])) * 256.0
	var at_drop: Vector2 = (base + Swing.hand_pos(drop[0], drop[1])) * 256.0
	arms2.handle_events({"t": "ie", "k": 1000, "n": 6, "p": 2, "part": 1, "parts": 1,
		"l": [Swing.Ev.SYNC, 77, 1000, 0, 0, 0, roundi(at_pick.x), roundi(at_pick.y), 0]})
	arms2.handle_events({"t": "ie", "k": 1030, "n": 6, "p": 2, "part": 1, "parts": 1,
		"l": [Swing.Ev.PICKED, 77, 1030, 1, 7, 19, roundi(at_pick.x), roundi(at_pick.y), 0]})
	arms2.handle_events({"t": "ie", "k": 1050, "n": 6, "p": 2, "part": 1, "parts": 1,
		"l": [Swing.Ev.DROPPED, 77, 1050, 0, 7, 0, roundi(at_drop.x), roundi(at_drop.y), 0]})
	var a2 = arms2._arms[77]
	check(a2.ev_ticks.size() == 3 and is_equal_approx(a2.ev_ticks[1], 1015.0) and a2.ev_c[1] == 0,
		"an uncertain pick is dated back by the exact drop after it: 1050 - 35 = 1015 (got %.0f)" % a2.ev_ticks[1])
	# Gone: the arm is dropped.
	arms2.handle_events({"t": "ie", "k": 1052, "n": 6, "p": 2, "part": 1, "parts": 1, "l": [Swing.Ev.GONE, 77, 1052, 0, 0, 0, 0, 0, 0]})
	check(arms2.count() == 0, "a gone event drops the arm")


## K8 (owner: "inserters should hold the item they have"): a modeller's rigged inserter (the test rig) fed a
## pick off a belt and a drop as `ie` events, drawn frame by frame on the belts' clock: no item in the hand
## before the pick; from the pick to the drop the item drawn once, its middle at the grip (between the pincers,
## the hand's place, no lower than the belt items drawn), the pincers closed; nothing after the drop. With the
## pose from the events the grip goes from the pickup to the drop; with the pose from the samples (the
## hand-off's `items` mode) the item follows the events all the same.
class StubBelts extends Node3D:
	var t := -1.0
	func drawn_tick() -> float:
		return t
	func item_height() -> float:
		return 0.27  # (a modeller's belt: Vasillo's tops are at 0.25)


func _held_at_grip() -> void:
	var ld = ModelLibrary.Load.new()
	ld.path = ProjectSettings.globalize_path("res://tests/fixtures/rig_inserter.glb")
	ld.rig_wanted = true
	ld.run()
	if ld.rig.is_empty():
		check(false, "K8: the test rig is read as an arm rig")
		return
	var rig: Dictionary = ModelLibrary._commit_rig(ld.rig, "test-inserter")
	var protos := ProtoDB.new()
	var p := ProtoDB.EntityProto.new()
	p.id = 1
	p.name = "test-inserter"
	p.type = "inserter"
	protos.entities[1] = p
	var world := StubWorld.new()
	var rec := Rec.new()
	rec.pos = Vector2(10.5, 20.5)
	world.entities[77] = rec
	var pick := [-PI / 2.0, 1.0]
	var drop := [PI / 2.0, 1.2]
	var at_pick: Vector2 = (rec.pos + Swing.hand_pos(pick[0], pick[1])) * 256.0
	var at_drop: Vector2 = (rec.pos + Swing.hand_pos(drop[0], drop[1])) * 256.0
	for from_events in [true, false]:
		Arms.belt_clock = true
		Arms.handoff = true
		Arms.events = true
		Arms.events_items = not from_events
		var arms := Arms.new()
		arms.protos = protos
		arms.world = world
		arms.eprops = {1: {"x": {"ip": [0, -1], "id": [0, 1.2], "rs": 0.014, "es": 0.035}}}
		var belts := StubBelts.new()
		arms.belts = belts
		arms._rigs["test-inserter"] = rig
		arms.handle_events({"t": "ie", "k": 100, "n": 6, "p": 2, "part": 1, "parts": 1,
			"l": [Swing.Ev.SYNC, 77, 100, 0, 0, 0, roundi(at_pick.x), roundi(at_pick.y), 0]})
		arms.handle_events({"t": "ie", "k": 110, "n": 6, "p": 2, "part": 1, "parts": 1,
			"l": [Swing.Ev.PICKED, 77, 110, 1, 5, 0, roundi(at_pick.x), roundi(at_pick.y), 3]})
		arms.handle_events({"t": "ie", "k": 150, "n": 6, "p": 2, "part": 1, "parts": 1,
			"l": [Swing.Ev.DROPPED, 77, 150, 0, 5, 0, roundi(at_drop.x), roundi(at_drop.y), 0]})
		var before := 0
		var after := 0
		var off_grip := 0.0
		var held := 0
		var low := INF
		var closed := 1.0
		var first_at := Vector3.ZERO
		var last_at := Vector3.ZERO
		for t in range(100, 170):
			belts.t = float(t)
			arms._process(1.0 / 60.0)
			var mmi: MultiMeshInstance3D = arms._cards._kinds.get(5)
			var n: int = mmi.multimesh.visible_instance_count if mmi != null else 0
			if t < 110:
				before += n
			elif t >= 150:
				after += n
			elif n != 1:
				off_grip = INF
			else:
				held += 1
				# (The instance as ItemCards wrote it: a headless renderer keeps no MultiMesh data to read back.)
				var buf: PackedFloat32Array = arms._cards._buffers.get(5, PackedFloat32Array())
				var origin := Vector3(buf[3], buf[7], buf[11]) if buf.size() >= 12 else Vector3.INF
				var at: Vector3 = origin - arms._cards.lift(5) + Vector3(0, arms._cards.pile_step(5) * 0.5, 0)
				off_grip = maxf(off_grip, at.distance_to(arms._grip_at))
				low = minf(low, at.y)
				if t >= 120:
					closed = minf(closed, arms._arms[77].close)
				if held == 1:
					first_at = at
				last_at = at
		var mode := "pose from the events" if from_events else "pose from the samples"
		check(before == 0 and after == 0 and held == 40 and off_grip < 0.001 and low >= 0.299 and closed > 0.99,
			"K8 (%s): a hand carrying an item draws it at its grip from the pick to the drop (%d of 40 ticks, %.4f off, lowest %.3f, pincers %.2f closed), none before (%d) or after (%d)" % [
			mode, held, off_grip, low, closed, before, after])
		if from_events:
			var near_pick := Vector2(first_at.x, first_at.z).distance_to(at_pick / 256.0)
			var near_drop := Vector2(last_at.x, last_at.z).distance_to(at_drop / 256.0)
			check(near_pick < 0.15 and near_drop < 0.15, "K8: the grip carries it from the pickup (%.3f off) to the drop (%.3f off)" % [near_pick, near_drop])
		for c in arms._cards.get_children():
			c.free()
		arms._cards.free()
		arms.free()
		belts.free()
	world.free()
	_rest_arms(rig)
	_burner_glow(rig)


## K12 (owner: "inserters are hiding their arms completely at distance"): the bridge sends hands only within
## its detail radius of the focus, so an inserter past it has no live arm: it draws one at rest, the hand at
## its pickup, a box arm in one MultiMesh, worked out when its chunk changes, not per frame. A live arm's
## inserter has no resting one; when its arm goes (gone, or out of the radius) the resting one comes at once.
## Zenith's own arm (a prototype without a rig) and a modeller's rigged one alike; --inserter-rest-arms=off: none.
func _rest_arms(rig: Dictionary) -> void:
	var protos := ProtoDB.new()
	for id in [1, 2]:
		var p := ProtoDB.EntityProto.new()
		p.id = id
		p.name = "test-arm" if id == 1 else "test-inserter"
		p.type = "inserter"
		p.color = Color(0.8, 0.5, 0.1)
		protos.entities[id] = p
	var world := StubWorld.new()
	var cv := StubChunk.new()
	world.chunks[Vector2i(0, 0)] = cv
	var units := {77: [1, Vector2(10.5, 20.5), 0], 78: [1, Vector2(12.5, 20.5), 4], 79: [2, Vector2(14.5, 20.5), 0]}
	for u: int in units:
		var rec := Rec.new()
		rec.unit = u
		rec.proto_id = units[u][0]
		rec.pos = units[u][1]
		rec.dir = units[u][2]
		world.entities[u] = rec
		cv.entities[u] = rec
	Arms.rest_arms = true
	var arms := Arms.new()
	arms.protos = protos
	arms.world = world
	var ends := {"x": {"ip": [0, -1], "id": [0, 1.2], "rs": 0.014, "es": 0.035}}
	arms.eprops = {1: ends, 2: ends}
	arms._rigs["test-inserter"] = rig
	var belts := StubBelts.new()
	belts.t = 100.0
	arms.belts = belts
	var at_pick: Vector2 = (Vector2(10.5, 20.5) + Swing.hand_pos(-PI / 2.0, 1.0)) * 256.0
	arms.handle_events({"t": "ie", "k": 100, "n": 6, "p": 2, "part": 1, "parts": 1,
		"l": [Swing.Ev.SYNC, 77, 100, 0, 0, 0, roundi(at_pick.x), roundi(at_pick.y), 0]})
	for f in 3:
		arms._process(1.0 / 60.0)
	# The hand boxes (every third instance) over the pickups: 78 faces east, its pickup a tile east; 79 north.
	var hands := []
	for k in arms.rest_count:
		var o := (k * 3 + 2) * 16
		hands.append(Vector2(arms.rest_buffer[o + 3], arms.rest_buffer[o + 11]))
	var want := [Vector2(13.5, 20.5), Vector2(14.5, 19.5)]
	var at_pickups: bool = hands.size() == 2 and (hands[0] as Vector2).distance_to(want[0]) < 0.01 and (hands[1] as Vector2).distance_to(want[1]) < 0.01
	check(arms.rest_count == 2 and at_pickups and arms._rest_mmi.visible and arms._rest_mmi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		"K12: inserters without a live arm draw one at rest, hands at their pickups (%d resting, hands %s), the live one none" % [arms.rest_count, hands])
	arms.handle_events({"t": "ie", "k": 110, "n": 6, "p": 2, "part": 1, "parts": 1, "l": [Swing.Ev.GONE, 77, 110, 0, 0, 0, 0, 0, 0]})
	arms._process(1.0 / 60.0)
	check(arms.rest_count == 3, "K12: a live arm that goes leaves its inserter resting at once, in the same frame (%d resting)" % arms.rest_count)
	# A chunk changing (built, mined): its arms worked out again, not every frame.
	cv.entities.erase(78)
	world.entities.erase(78)
	world.entities_changed.emit(Vector2i(0, 0))
	arms._process(1.0)
	check(arms.rest_count == 2, "K12: a chunk's change works its resting arms out again (%d resting)" % arms.rest_count)
	Arms.rest_arms = false
	arms._process(1.0 / 60.0)
	check(not arms._rest_mmi.visible, "K12: --inserter-rest-arms=off draws none")
	Arms.rest_arms = true
	for c in arms._cards.get_children():
		c.free()
	arms._cards.free()
	arms.free()
	belts.free()
	world.free()


## L4 (owner: "the burner inserter's burner stays lit while it's idle"): a modeller's burner inserter glows
## by its model's emissive material, which anim.gd lit while the entity worked, and inserters (the bridge sends
## them no `st`) counted as always working. Now an inserter's glow follows its drawn hand: lit while it turns
## or reaches and for MOVING_HOLD ticks after (the short waits at its ends), dark once it waits longer, and dark
## at once when its live arm goes (it rests). --inserter-glow=always: lit all along, as before.
class GlowWorld extends StubWorld:
	var animator: Node
	var working := {}  # the bridge's `st` (none for inserters)


class GlowChunk:
	var entities := {}
	var anim_groups: Array = []


func _burner_glow(rig: Dictionary) -> void:
	var protos := ProtoDB.new()
	var p := ProtoDB.EntityProto.new()
	p.id = 1
	p.name = "test-inserter"
	p.type = "inserter"
	protos.entities[1] = p
	var world := GlowWorld.new()
	var cv := GlowChunk.new()
	world.chunks[Vector2i(0, 0)] = cv
	var rec := Rec.new()
	rec.unit = 77
	rec.key = 77
	rec.pos = Vector2(10.5, 20.5)
	world.entities[77] = rec
	cv.entities[77] = rec
	var anim := Anim.new()
	anim.world = world
	world.animator = anim
	# Its base model's glowing instance, as chunk_view.gd hands it over (a glowing model: no part).
	var group := Anim.Group.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.instance_count = 1
	group.mm = mm
	group.keys.append(77)
	group.units.append(77)
	group.bases.append(Transform3D())
	group.stateful.append(Anim.state_source("inserter"))
	group.customs.append(Anim.custom_for(rec, 1.0))
	Anim.place(group, anim, {})
	cv.anim_groups.append(group)
	var glowing := func() -> bool:
		var flags := floori(-group.customs[0].b - 1.0)
		return flags & 4 != 0
	Arms.belt_clock = true
	Arms.events = true
	Arms.events_items = false
	var arms := Arms.new()
	arms.protos = protos
	arms.world = world
	arms.eprops = {1: {"x": {"ip": [0, -1], "id": [0, 1.2], "rs": 0.014, "es": 0.035}}}
	var belts := StubBelts.new()
	arms.belts = belts
	arms._rigs["test-inserter"] = rig
	var at_pick: Vector2 = (rec.pos + Swing.hand_pos(-PI / 2.0, 1.0)) * 256.0
	var at_drop: Vector2 = (rec.pos + Swing.hand_pos(PI / 2.0, 1.2)) * 256.0
	arms.handle_events({"t": "ie", "k": 100, "n": 6, "p": 2, "part": 1, "parts": 1,
		"l": [Swing.Ev.SYNC, 77, 100, 0, 0, 0, roundi(at_pick.x), roundi(at_pick.y), 0]})
	arms.handle_events({"t": "ie", "k": 140, "n": 6, "p": 2, "part": 1, "parts": 1,
		"l": [Swing.Ev.PICKED, 77, 140, 1, 5, 0, roundi(at_pick.x), roundi(at_pick.y), 0]})
	arms.handle_events({"t": "ie", "k": 180, "n": 6, "p": 2, "part": 1, "parts": 1,
		"l": [Swing.Ev.DROPPED, 77, 180, 0, 5, 0, roundi(at_drop.x), roundi(at_drop.y), 0]})
	var start_glow: bool = glowing.call()
	var lit_waiting := 0  # frames lit while the hand waits for its first item
	var dark_swinging := 0  # frames dark while it swings out and back
	var lit_after := 0  # frames lit once it has stood at the pickup past the hold
	var back_at := -1.0
	for t in range(100, 330):
		belts.t = float(t)
		arms._process(1.0 / 60.0)
		var lit: bool = anim.arm_working.has(77)
		var arm = arms._arms[77]
		var home := Swing.hand_pos(arm.angle, arm.reach).distance_to(Swing.hand_pos(-PI / 2.0, 1.0)) < 0.01
		if t >= 185 and back_at < 0.0 and home:
			back_at = t
		if t < 140:
			lit_waiting += 1 if lit else 0
		elif t > 142 and (back_at < 0.0 or t < back_at):
			dark_swinging += 0 if lit and glowing.call() else 1
		elif back_at >= 0.0 and t > back_at + Arms.MOVING_HOLD + 2:
			lit_after += 1 if lit or glowing.call() else 0
	check(not start_glow and lit_waiting == 0 and dark_swinging == 0 and back_at > 0.0 and lit_after == 0,
		"L4: a burner inserter's burner is dark while its hand waits for an item (%d frames lit), lit while it swings out and back (%d dark), dark again %d ticks after it stands at the pickup (back at %d, %d lit after)" % [
		lit_waiting, dark_swinging, int(Arms.MOVING_HOLD), int(back_at), lit_after])
	# Swinging again, then gone (out of the radius): dark at once, its arm resting.
	arms.handle_events({"t": "ie", "k": 340, "n": 6, "p": 2, "part": 1, "parts": 1,
		"l": [Swing.Ev.PICKED, 77, 340, 1, 5, 0, roundi(at_pick.x), roundi(at_pick.y), 0]})
	for t in range(330, 352):
		belts.t = float(t)
		arms._process(1.0 / 60.0)
	var lit_again: bool = anim.arm_working.has(77) and glowing.call()
	arms.handle_events({"t": "ie", "k": 352, "n": 6, "p": 2, "part": 1, "parts": 1, "l": [Swing.Ev.GONE, 77, 352, 0, 0, 0, 0, 0, 0]})
	belts.t = 352.0
	arms._process(1.0 / 60.0)
	check(lit_again and not anim.arm_working.has(77) and not glowing.call(),
		"L4: lit again when it swings, dark the frame its live arm goes")
	# --inserter-glow=always: inserters' glows follow nothing, lit all along (as before).
	Anim.arm_glow = false
	check(Anim.state_source("inserter") == 0 and Anim.state_source("furnace") == Anim.STATE_REPORTED,
		"L4: --inserter-glow=always leaves inserters always lit (state source %d), machines as they were" % Anim.state_source("inserter"))
	Anim.arm_glow = true
	for c in arms._cards.get_children():
		c.free()
	arms._cards.free()
	arms.free()
	belts.free()
	anim.free()
	world.free()


## The owner's burner effects (burner_fx.gd): while a modeller's burner inserter's burner is lit (its hand
## moving, L4's rule: anim.gd arm_working) it breathes like coals (the shader's glow_heat), a thin wisp of
## light smoke leaves its grille now and then near the listener, and a quiet fire crackle plays, at most
## MAX_SOUNDS at once. --burner-fx=off: none of it.
class StubSprites:
	var cards: Array = []

	func emit(sheet: String, pos: Vector3, width: float, life: float, color := Color.WHITE):
		var c := preload("res://scripts/fx/sprite_fx.gd").Card.new()
		c.pos = pos
		c.size0 = width
		c.life = life
		c.color = color
		cards.append([sheet, c])
		return c


static func _no_heat(mesh: Mesh) -> bool:
	var h: Variant = (mesh.surface_get_material(0) as ShaderMaterial).get_shader_parameter("glow_heat")
	return h == null or float(h) == 0.0


static func _glow_mesh(glows: bool) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var m := ShaderMaterial.new()
	m.shader = FactorioShader
	m.set_shader_parameter("activity_glow", glows)
	m.set_shader_parameter("emission", Color(1.0, 0.6, 0.2))
	m.set_shader_parameter("emission_energy", 5.0)
	mesh.surface_set_material(0, m)
	return mesh


func _burner_fx() -> void:
	BurnerFx.enabled()  # (the command line read once, before the tests set `on`)
	var burner := _glow_mesh(true)
	BurnerFx.prepare(burner, "burner-inserter@arg")
	var plain := _glow_mesh(false)
	BurnerFx.prepare(plain, "burner-inserter")
	var electric := _glow_mesh(true)
	BurnerFx.prepare(electric, "inserter")
	var heat: Variant = (burner.surface_get_material(0) as ShaderMaterial).get_shader_parameter("glow_heat")
	check(BurnerFx.burns(burner) and heat != null and float(heat) == BurnerFx.HEAT and not BurnerFx.burns(plain)
		and not BurnerFx.burns(electric) and _no_heat(electric),
		"burner fx: a glowing burner inserter's burner gets the coals' heat (%s), one without a glow and an electric inserter don't" % heat)
	# The pulse: 0.75 to 1.15 of the glow, a few changes a second, each instance out of phase.
	var lo := 9.0
	var hi := 0.0
	var turns := 0
	var last := 0.0
	var rising := true
	var apart := 0.0
	for i in 600:
		var t := i * 0.01
		var w := BurnerFx.heat_wave(t, 0.3)
		lo = minf(lo, w)
		hi = maxf(hi, w)
		if i > 0 and (w > last) != rising:
			rising = w > last
			turns += 1
		last = w
		apart = maxf(apart, absf(w - BurnerFx.heat_wave(t, 0.71)))
	check(lo >= 0.749 and hi <= 1.151 and hi - lo > 0.2 and turns >= 6 and turns <= 60 and apart > 0.05,
		"burner fx: the heat varies %.2f to %.2f of the glow, %d turns in 6 s, two burners apart by up to %.2f" % [lo, hi, turns, apart])
	# The shader with glow_heat compiles (its uniforms listed); a copy with an error in that sum doesn't.
	var inc := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshaderinc")
	var top := FileAccess.get_file_as_string("res://shaders/factorio_material.gdshader")
	var good := Shader.new()
	good.code = top.replace('#include "res://shaders/factorio_material.gdshaderinc"', inc)
	var bad := Shader.new()
	bad.code = good.code.replace("wave *= 1.0 + glow_heat * (-0.05 + 0.2 * n);", "wave *= 1.0 + glow_heat * (-0.05 + 0.2 * n) +;")
	var good_u: Array = good.get_shader_uniform_list().map(func(u: Dictionary) -> String: return str(u["name"]))
	check(good_u.has("glow_heat") and bad.code != good.code and bad.get_shader_uniform_list().is_empty(),
		"burner fx: the model shader with the heat compiles (%d uniforms); a broken copy doesn't" % good_u.size())
	# The world: burners whose hand moves, near the listener, smoke and crackle; far ones and idle ones don't.
	var entities := {}
	for u in [77, 78, 79]:
		var r := Rec.new()
		r.unit = u
		r.key = u
		r.pos = Vector2(10.5, 10.5) if u != 78 else Vector2(10.5 + BurnerFx.SMOKE_RANGE + 20.0, 10.5)
		entities[u] = r
	var mesh_of := func(_r) -> Mesh: return burner
	var vent_of := func(r) -> Vector3: return BurnerFx.vent_at(r.pos, 0.0)
	var fx := BurnerFx.new()
	var sprites := StubSprites.new()
	var sources: Array = []
	var focus := Vector2(12.0, 10.0)
	fx.scan(entities, {77: 1, 78: 1}, focus, 40.0, sources, mesh_of, vent_of)
	for i in 600:
		fx.step(sprites, 1.0 / 60.0)
	var at: Vector3 = sprites.cards[0][1].pos if not sprites.cards.is_empty() else Vector3.ZERO
	var expected := 10.0 * BurnerFx.SMOKE_RATE
	check(fx.burning.keys() == [77] and sprites.cards.size() >= expected * 0.5 and sprites.cards.size() <= expected * 1.6 + 1
		and sprites.cards.all(func(c: Array) -> bool: return c[0] == "smoke")
		and at.distance_to(Vector3(10.5, 0.0, 10.5) + BurnerFx.VENT) < 0.01,
		"burner fx: a burner working near the listener smokes %d wisps in 10 s (about %.0f), from its vent, one far off none (burning %s)" % [sprites.cards.size(), expected, fx.burning.keys()])
	check(sources.size() == 1 and sources[0]["path"] == BurnerFx.SOUND and int(sources[0]["per_group"]) == BurnerFx.MAX_SOUNDS
		and sources[0]["pos"] == vent_of.call(entities[77]),
		"burner fx: its crackle plays (%s), capped per group at %d" % [sources, BurnerFx.MAX_SOUNDS])
	# Dark (its hand waits): no smoke, no crackle.
	sources.clear()
	var before := sprites.cards.size()
	fx.scan(entities, {}, focus, 40.0, sources, mesh_of, vent_of)
	for i in 600:
		fx.step(sprites, 1.0 / 60.0)
	check(fx.burning.is_empty() and sprites.cards.size() == before and sources.is_empty(),
		"burner fx: dark, it neither smokes nor crackles")
	# Many burning at once: the nearest MAX_SOUNDS crackle, all smoke.
	var many := {}
	var working := {}
	for u in range(200, 208):
		var r := Rec.new()
		r.unit = u
		r.pos = focus + Vector2(u - 200, 0.0)
		many[u] = r
		working[u] = 1
	fx.scan(many, working, focus, 40.0, sources, mesh_of, vent_of)
	var keys: Array = sources.map(func(s: Dictionary) -> String: return str(s["key"]))
	check(sources.size() == BurnerFx.MAX_SOUNDS and keys == ["burner200", "burner201", "burner202"] and fx.burning.size() == 8,
		"burner fx: 8 burning, the nearest %d crackle (%s)" % [BurnerFx.MAX_SOUNDS, keys])
	# --burner-fx=off: no heat on a model, no smoke or crackle (as before).
	BurnerFx.on = false
	var off := _glow_mesh(true)
	BurnerFx.prepare(off, "burner-inserter")
	sources.clear()
	fx.scan(entities, {77: 1}, focus, 40.0, sources, mesh_of, vent_of)
	check(not BurnerFx.burns(off) and _no_heat(off)
		and fx.burning.is_empty() and sources.is_empty(),
		"burner fx: --burner-fx=off leaves the burner's glow steady, no smoke, no crackle")
	BurnerFx.on = true


## The Factorio pack's inserters (owner: "the cardboard-cutout look should hold"): with the Factorio pack winning
## for the inserter, its arm is Factorio's own pictures on cards (the hand base, the hand open while empty and
## closed while holding) in one MultiMesh per prototype and picture, no 3D arm; the hand card's grip is where the
## 3D arm's grip is for the same events (the hand's pose is the same whichever way it is drawn), seen along
## Factorio's camera; a long-handed inserter uses its own pictures and rests as pictures; with Placeholders
## (or Wube3DP, which has the inserters) winning the 3D arm is drawn as before. Needs the install (its pictures); skipped with a note without.
func _sprite_arms() -> void:
	const ModelPacks := preload("res://scripts/world/model_packs.gd")
	const ItemIcons := preload("res://scripts/world/item_icons.gd")
	const SpriteStandins := preload("res://scripts/world/sprite_standins.gd")
	if ItemIcons.factorio_data_dir() == "":
		print("NOTE no Factorio install here: the Factorio pack's inserter arms aren't checked")
		return
	var built := ModelPacks.builtin_packs()
	var off_others := ["builtin:fue5", "builtin:wube3dp"]
	ModelPacks.set_choices({})
	ModelPacks.use(ModelPacks.ordered(built, [ModelPacks.FACTORIO_ID, "builtin:placeholders"] + off_others, off_others))
	ModelLibrary.choices_changed([])
	var protos := ProtoDB.new()
	for id in [1, 2]:
		var p := ProtoDB.EntityProto.new()
		p.id = id
		p.name = "inserter" if id == 1 else "long-handed-inserter"
		p.type = "inserter"
		protos.entities[id] = p
	var world := StubWorld.new()
	var cv := StubChunk.new()
	world.chunks[Vector2i(0, 0)] = cv
	for u: int in [77, 78]:
		var rec := Rec.new()
		rec.unit = u
		rec.proto_id = 1 if u == 77 else 2
		rec.pos = Vector2(10.5, 20.5) if u == 77 else Vector2(14.5, 20.5)
		world.entities[u] = rec
		cv.entities[u] = rec
	var base: Vector2 = world.entities[77].pos
	var at_pick: Vector2 = (base + Swing.hand_pos(-PI / 2.0, 1.0)) * 256.0
	var at_drop: Vector2 = (base + Swing.hand_pos(PI / 2.0, 1.2)) * 256.0
	var pitch := deg_to_rad(SpriteStandins.FACTORIO_PITCH)
	var facing := Vector3(0.0, sin(pitch), cos(pitch))
	var poses := {}  # sprite arms on/off -> [[angle, reach, item], ...] per frame
	for sprites in [true, false]:
		Arms.belt_clock = true
		Arms.handoff = true
		Arms.events = true
		Arms.events_items = false
		Arms.rest_arms = true
		Arms.sprite_arms = sprites
		var arms := Arms.new()
		arms.protos = protos
		arms.world = world
		var ends := {"x": {"ip": [0, -1], "id": [0, 1.2], "rs": 0.014, "es": 0.035}}
		arms.eprops = {1: ends, 2: {"x": {"ip": [0, -2], "id": [0, 2.2], "rs": 0.02, "es": 0.05}}}
		var belts := StubBelts.new()
		arms.belts = belts
		arms._ready()  # (not in the tree yet under _init: its parts made here)
		arms.handle_events({"t": "ie", "k": 100, "n": 6, "p": 2, "part": 1, "parts": 1,
			"l": [Swing.Ev.SYNC, 77, 100, 0, 0, 0, roundi(at_pick.x), roundi(at_pick.y), 0]})
		arms.handle_events({"t": "ie", "k": 110, "n": 6, "p": 2, "part": 1, "parts": 1,
			"l": [Swing.Ev.PICKED, 77, 110, 1, 5, 0, roundi(at_pick.x), roundi(at_pick.y), 3]})
		arms.handle_events({"t": "ie", "k": 150, "n": 6, "p": 2, "part": 1, "parts": 1,
			"l": [Swing.Ev.DROPPED, 77, 150, 0, 5, 0, roundi(at_drop.x), roundi(at_drop.y), 0]})
		var seen: Array = []
		var wrong_hand := 0
		var grip_off := 0.0
		var boxes := 0
		for t in range(100, 170):
			belts.t = float(t)
			arms._process(1.0 / 60.0)
			var arm = arms._arms[77]
			seen.append([arm.angle, arm.reach, arm.item_id])
			for mmi: MultiMeshInstance3D in arms._parts:
				boxes += mmi.multimesh.visible_instance_count
			for pieces in arms._model_parts.values():
				if pieces != null:
					for mmi: MultiMeshInstance3D in pieces:
						boxes += mmi.multimesh.visible_instance_count
			if not sprites:
				continue
			if arm.sprite_xf.size() != 3:
				wrong_hand += 1
				continue
			var hand_xf: Transform3D = arm.sprite_xf[1]
			var piece: int = arm.sprite_xf[2]
			if piece != (Arms.SpritePiece.CLOSED if arm.item_id > 0 else Arms.SpritePiece.OPEN) or (t < 110 and piece != Arms.SpritePiece.OPEN) \
					or (t >= 112 and t < 150 and piece != Arms.SpritePiece.CLOSED) or (t >= 152 and piece != Arms.SpritePiece.OPEN):
				wrong_hand += 1
			# The card's grip: HAND_TIP short of its top. The 3D arm's: the grip height over the hand's place.
			var along := hand_xf.basis.y
			var card_grip := hand_xf.origin + along * 0.5 - along * Arms.HAND_TIP
			var out := Basis(Vector3.UP, -arm.angle) * Vector3.RIGHT
			var grip: Vector3 = Vector3(base.x, arms._grip_height(), base.y) + out * arm.reach
			grip_off = maxf(grip_off, (card_grip - grip).cross(facing).length())
		poses[sprites] = seen
		if sprites:
			var mmis: Array = arms._sprite_mmis.get("inserter", [])
			var drawn := 0
			for mmi: MultiMeshInstance3D in mmis:
				drawn += mmi.multimesh.visible_instance_count
			check(mmis.size() == 3 and drawn == 2 and boxes == 0,
				"Factorio pack: the inserter's arm is its pictures, the hand base and one hand card (%d cards, %d MultiMeshes), no 3D arm (%d box or piece instances)" % [drawn, mmis.size(), boxes])
			check(wrong_hand == 0, "Factorio pack: the hand open while empty, closed from the pick to the drop (%d frames wrong)" % wrong_hand)
			check(grip_off < 1e-3, "Factorio pack: the hand card's grip is the 3D arm's grip seen along Factorio's camera (%.5f off at most)" % grip_off)
			var files: Array = (Arms._sprite_pictures.get("inserter", {}) as Dictionary).get("files", [])
			var long_files: Array = (Arms._sprite_pictures.get("long-handed-inserter", {}) as Dictionary).get("files", [])
			check(files.size() == 3 and str(files[1]).ends_with("inserter/inserter-hand-open.png") and long_files.size() == 3
				and str(long_files[0]).ends_with("long-handed-inserter/long-handed-inserter-hand-base.png")
				and str(long_files[2]).ends_with("long-handed-inserter-hand-closed.png") and arms.sprite_rest_count == 1
				and arms._sprite_rest_mmis.has("long-handed-inserter"),
				"Factorio pack: the long-handed inserter (no live arm) rests as its own pictures (%s; %d resting as pictures)" % [long_files, arms.sprite_rest_count])
			var pose := Arms.sprite_arm_pose("inserter", Vector2(0.0, -1.0), true)
			check(pose.get("cards", false) and (pose["pieces"] as Array).size() == 2 and pose["pieces"][1][0] == Arms._sprite_pictures["inserter"]["meshes"][Arms.SpritePiece.CLOSED],
				"the Model packs viewer's pose: the base and the closed hand's cards")
		else:
			check(arms._sprite_mmis.is_empty() and boxes > 0, "--inserter-sprite-arms=off: the 3D arm as before (%d instances)" % boxes)
		for c in arms._cards.get_children():
			c.free()
		arms._cards.free()
		arms.free()
		belts.free()
	var most := 0.0
	for i in mini((poses[true] as Array).size(), (poses[false] as Array).size()):
		var a: Array = poses[true][i]
		var b: Array = poses[false][i]
		most = maxf(most, maxf(absf(angle_difference(a[0], b[0])), absf(a[1] - b[1])))
		if a[2] != b[2]:
			most = INF
	check(most < 1e-6, "the same events give the same hand drawn as pictures or as the 3D arm (%.7f off at most)" % most)
	# Wube3DP above Factorio (Placeholders has no inserter): its inserter model and the 3D arm, no pictures.
	Arms.sprite_arms = true
	ModelPacks.use(ModelPacks.ordered(built, ["builtin:wube3dp", ModelPacks.FACTORIO_ID, "builtin:placeholders", "builtin:fue5"], ["builtin:fue5"]))
	ModelLibrary.choices_changed([])
	var arms := Arms.new()
	arms.protos = protos
	arms.world = world
	arms.eprops = {1: {"x": {"ip": [0, -1], "id": [0, 1.2], "rs": 0.014, "es": 0.035}}}
	var belts := StubBelts.new()
	belts.t = 105.0
	arms.belts = belts
	arms._ready()
	arms.handle_events({"t": "ie", "k": 100, "n": 6, "p": 2, "part": 1, "parts": 1,
		"l": [Swing.Ev.SYNC, 77, 100, 0, 0, 0, roundi(at_pick.x), roundi(at_pick.y), 0]})
	var drawn := 0
	for i in 600:
		ModelLibrary.poll()
		arms._process(1.0 / 60.0)
		drawn = 0
		for mmi: MultiMeshInstance3D in arms._parts:
			drawn += mmi.multimesh.visible_instance_count
		for pieces in arms._model_parts.values():
			if pieces != null:
				for mmi: MultiMeshInstance3D in pieces:
					drawn += mmi.multimesh.visible_instance_count
		for rig: Dictionary in arms._rigs.values():
			for mmi in rig.get("mmis", []):
				if mmi != null:
					drawn += (mmi as MultiMeshInstance3D).multimesh.visible_instance_count
		if drawn > 0 and ModelLibrary.ready("inserter"):
			break
		OS.delay_msec(5)
	check(not ModelLibrary.draws_sprite("inserter") and arms._sprite_mmis.is_empty() and drawn > 0,
		"Wube3DP above Factorio: the inserter's 3D arm as before (%d instances), no pictures" % drawn)
	for c in arms._cards.get_children():
		c.free()
	arms._cards.free()
	arms.free()
	belts.free()
	world.free()
	ModelPacks.set_choices({})
	ModelPacks.use(ModelPacks.ordered(built, [], []))
	ModelLibrary.choices_changed([])
