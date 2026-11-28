extends SceneTree
## (--native-inserter-swing, perf A2) InserterSwingNative (native/belt_sim/src/inserter_swing_core.h) against
## scripts/world/inserter_swing.gd, function by function: 20,000 random cases each (plan's every branch: standing
## still, the item changed with and without a belt pick, the reach-slack and turned-short cases, the half-turn carry,
## the waits; plan_events with every kind and status code; NAN sides, unknown ends), the keyframe counts equal and
## every value within TOL. The time of a plan both ways printed. Needs the native library (skips without it).
## Run: godot --headless --audio-driver Dummy --path client --log-file <abs> --script res://tests/inserter_swing_native_test.gd

const Swing := preload("res://scripts/world/inserter_swing.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")

const N := 20000
const TOL := 1e-9

var passes := 0
var fails := 0
var rng := RandomNumberGenerator.new()
var sw: RefCounted


func check(cond: bool, msg: String) -> void:
	if cond:
		passes += 1
	else:
		fails += 1
		print("FAIL: %s" % msg)


func _close(a: float, b: float) -> bool:
	if is_nan(a) or is_nan(b):
		return is_nan(a) and is_nan(b)
	return absf(a - b) <= TOL * maxf(1.0, absf(a))


func _end() -> Array:
	if rng.randf() < 0.08:
		return []
	return [rng.randf_range(-PI, PI), rng.randf_range(0.6, 2.6)]


func _speeds() -> Array:
	var table := [[0.013, 0.035], [0.014, 0.035], [0.02, 0.05], [0.04, 0.1], [0.04 * 2.5, 0.1 * 2.5]]
	if rng.randf() < 0.8:
		return table[rng.randi() % table.size()]
	return [rng.randf_range(0.005, 0.12), rng.randf_range(0.01, 0.3)]


func _side() -> float:
	return NAN if rng.randf() < 0.35 else rng.randf_range(-PI, PI)


## A pose about the base: at an end (exactly, or within its zone), between them, or anywhere.
func _pose(pick: Array, drop: Array) -> Array:
	var r := rng.randf()
	var e: Array = pick if rng.randf() < 0.5 else drop
	if e.is_empty():
		e = [rng.randf_range(-PI, PI), rng.randf_range(0.6, 2.6)]
	if r < 0.3:
		return [float(e[0]), float(e[1])]
	if r < 0.55:
		return [float(e[0]) + rng.randf_range(-0.15, 0.15), float(e[1]) + rng.randf_range(-0.2, 0.2)]
	if r < 0.8 and not pick.is_empty() and not drop.is_empty():
		var u := rng.randf()
		return [lerpf(pick[0], pick[0] + wrapf(drop[0] - pick[0], -PI, PI), u), lerpf(pick[1], drop[1], u)]
	return [rng.randf_range(-PI, PI), rng.randf_range(0.5, 2.6)]


# (Packed copies of the arrays, as the native takes them.)
static func _p(a: Array) -> PackedFloat64Array:
	return PackedFloat64Array(a)


func _cmp_keys(g: Array, n: PackedFloat64Array, what: String) -> bool:
	if g.size() * 4 != n.size():
		check(false, "%s: %d keyframes, native %d" % [what, g.size(), n.size() / 4])
		return false
	for i in g.size():
		var k: Array = g[i]
		if not (_close(k[0], n[i * 4]) and _close(k[1], n[i * 4 + 1]) and _close(k[2], n[i * 4 + 2]) and int(k[3]) == int(n[i * 4 + 3])):
			check(false, "%s: keyframe %d %s, native [%s, %s, %s, %s]" % [what, i, str(k), n[i * 4], n[i * 4 + 1], n[i * 4 + 2], n[i * 4 + 3]])
			return false
	return true


func _init() -> void:
	rng.seed = 20251
	if not (NativeLibrary.ensure() and ClassDB.class_exists("InserterSwingNative")):
		print("inserter_swing_native_test: SKIP (no InserterSwingNative in this build)")
		quit(0)
		return
	sw = ClassDB.instantiate("InserterSwingNative")
	_small_functions()
	_plans()
	_events()
	_timing()
	print("inserter_swing_native_test: %s (%d passed, %d failed)" % ["PASS" if fails == 0 else "FAIL", passes, fails])
	quit(1 if fails > 0 else 0)


func _small_functions() -> void:
	var bad := {}
	for _i in N:
		var sp := _speeds()
		var da := rng.randf_range(-7.0, 7.0) if rng.randf() < 0.9 else 0.0
		var dr := rng.randf_range(-2.0, 2.0) if rng.randf() < 0.9 else 0.0
		var cr := rng.randf() < 0.5
		var ce := rng.randf() < 0.5
		if Swing.travel_ticks(da, dr, sp[0], sp[1], cr, ce) != sw.travel_ticks(da, dr, sp[0], sp[1], cr, ce):
			bad["travel_ticks"] = bad.get("travel_ticks", 0) + 1
		var way := absf(da)
		if Swing._part_ticks(way, sp[1], cr) != sw.part_ticks(way, sp[1], cr):
			bad["part_ticks"] = bad.get("part_ticks", 0) + 1
		var j := float(rng.randi_range(0, 60)) if rng.randf() < 0.7 else rng.randf_range(0.0, 60.0)
		if not _close(Swing._part_at(da, dr, sp[0], j), sw.part_at(da, dr, sp[0], j)):
			bad["part_at"] = bad.get("part_at", 0) + 1
		var k0 := float(rng.randi_range(0, 1000))
		var k1 := k0 + (float(rng.randi_range(0, 40)) if rng.randf() < 0.8 else rng.randf_range(0.0, 40.0))
		var a0 := rng.randf_range(-PI, PI)
		var r0 := rng.randf_range(0.6, 2.5)
		var item := rng.randi_range(0, 3)
		var end_item := rng.randi_range(-1, 3)
		var comp := rng.randf() < 0.5
		var lg := Swing.leg(k0, a0, r0, k1, a0 + da, r0 + dr * 0.5, item, sp[0], sp[1], comp, end_item)
		if not _cmp_keys(lg, sw.leg(k0, a0, r0, k1, a0 + da, r0 + dr * 0.5, item, sp[0], sp[1], comp, end_item), "leg"):
			bad["leg"] = bad.get("leg", 0) + 1
		var hp := Swing.hand_pos(a0, r0)
		if hp != sw.hand_pos(a0, r0):
			bad["hand_pos"] = bad.get("hand_pos", 0) + 1
		var e := _end()
		var tol: float = [Swing.END_NEAR, Swing.STILL, 0.7, 1.0][rng.randi() % 4]
		var a1 := a0 + rng.randf_range(-0.4, 0.4) * (1.0 if rng.randf() < 0.5 else 8.0)
		if Swing.near(a1, r0, e, tol) != sw.near(a1, r0, _p(e), tol):
			bad["near"] = bad.get("near", 0) + 1
		var side := _side()
		var amb: float = Swing.AMBIGUOUS if rng.randf() < 0.6 else PI * 0.5
		var to := a0 + rng.randf_range(-PI, PI) * (1.0 if rng.randf() < 0.7 else 3.0)
		if not _close(Swing.delta(a0, to, side, amb), sw.delta(a0, to, side, amb)):
			bad["delta"] = bad.get("delta", 0) + 1
		var pick := _end()
		var drop := _end()
		if Swing.on_side(a1, pick, drop) != sw.on_side(a1, _p(pick), _p(drop)):
			bad["on_side"] = bad.get("on_side", 0) + 1
		var still := rng.randf() < 0.2
		var ticks := rng.randf_range(-2.0, 50.0)
		var ex := Swing.extrapolate(a0, r0, item, still, pick, drop, sp[0], sp[1], side, ticks)
		var exn: PackedFloat64Array = sw.extrapolate(a0, r0, item, still, _p(pick), _p(drop), sp[0], sp[1], side, ticks)
		if not (_close(ex[0], exn[0]) and _close(ex[1], exn[1]) and int(ex[2]) == int(exn[2])):
			bad["extrapolate"] = bad.get("extrapolate", 0) + 1
		# at: a random leg's plan read at a random tick round it.
		if not lg.is_empty():
			var t := rng.randf_range(k0 - 2.0, k1 + 2.0)
			var g := Swing.at(lg, t)
			var flat := PackedFloat64Array()
			for kf: Array in lg:
				flat.append_array(PackedFloat64Array([kf[0], kf[1], kf[2], kf[3]]))
			var nat: PackedFloat64Array = sw.at(flat, t)
			if not (_close(g[0], nat[0]) and _close(g[1], nat[1]) and int(g[2]) == int(nat[2])):
				bad["at"] = bad.get("at", 0) + 1
	for f in ["travel_ticks", "part_ticks", "part_at", "leg", "hand_pos", "near", "delta", "on_side", "extrapolate", "at"]:
		check(not bad.has(f), "%s: %d cases equal (%d differ)" % [f, N, bad.get(f, 0)])
	print("small functions: %d cases each, differing %s" % [N, str(bad)])


func _plans() -> void:
	var differ := 0
	var sizes := {}
	var slack_before := Swing.reach_slack
	for i in N:
		var pick := _end()
		var drop := _end()
		var sp := _speeds()
		var ka := float(rng.randi_range(0, 5000))
		var dt := float(rng.randi_range(1, 40)) if rng.randf() < 0.95 else float(rng.randi_range(-2, 0))
		var pa := _pose(pick, drop)
		var pb: Array = pa.duplicate() if rng.randf() < 0.12 else _pose(pick, drop)
		var ia := 0 if rng.randf() < 0.5 else rng.randi_range(1, 5)
		var ib := ia if rng.randf() < 0.5 else (0 if rng.randf() < 0.5 else rng.randi_range(1, 5))
		var side := _side()
		var belt := rng.randf() < 0.4
		var last := rng.randi_range(0, 5)
		var slack := 1.6 if rng.randf() < 0.7 else 1.0
		Swing.reach_slack = slack
		var g := Swing.plan(ka, pa[0], pa[1], ia, ka + dt, pb[0], pb[1], ib, pick, drop, sp[0], sp[1], side, belt, last)
		var n: PackedFloat64Array = sw.plan(PackedFloat64Array([ka, pa[0], pa[1], ia, ka + dt, pb[0], pb[1], ib]), _p(pick), _p(drop),
			sp[0], sp[1], side, belt, last, slack)
		sizes[g.size()] = sizes.get(g.size(), 0) + 1
		if not _cmp_keys(g, n, "plan case %d" % i):
			differ += 1
	Swing.reach_slack = slack_before
	check(differ == 0, "plan: %d cases equal (%d differ)" % [N, differ])
	print("plan: keyframe counts %s" % str(sizes))


func _event(pick: Array, drop: Array) -> Array:
	var kind := rng.randi_range(1, 5)
	var count := rng.randi_range(0, 4) if rng.randf() < 0.7 else 0
	var item := rng.randi_range(0, 5)
	var pose: Array = [NAN, NAN] if rng.randf() < 0.25 else _pose(pick, drop)
	var code := rng.randi_range(0, 9) if rng.randf() < 0.5 else 0
	return [float(rng.randi_range(0, 3000)), kind, count, item, pose[0], pose[1], code]


func _events() -> void:
	var differ := 0
	var sizes := {}
	for i in N:
		var pick := _end()
		var drop := _end()
		var sp := _speeds()
		var e0 := _event(pick, drop)
		var e1: Array = [] if rng.randf() < 0.2 else _event(pick, drop)
		if not e1.is_empty() and rng.randf() < 0.85:
			e1[0] = e0[0] + float(rng.randi_range(1, 50))
		var side := _side()
		var g := Swing.plan_events(e0, e1, pick, drop, sp[0], sp[1], side)
		var n: PackedFloat64Array = sw.plan_events(_p(e0), _p(e1), _p(pick), _p(drop), sp[0], sp[1], side)
		sizes[g.size()] = sizes.get(g.size(), 0) + 1
		if not _cmp_keys(g, n, "plan_events case %d" % i):
			differ += 1
	check(differ == 0, "plan_events: %d cases equal (%d differ)" % [N, differ])
	print("plan_events: keyframe counts %s" % str(sizes))


func _timing() -> void:
	var pick := [-PI * 0.5, 1.0]
	var drop := [PI * 0.5, 1.2]
	var cases := []
	for _i in 2000:
		var pa := _pose(pick, drop)
		var pb := _pose(pick, drop)
		cases.append([float(rng.randi_range(0, 5000)), pa, pb, rng.randi_range(0, 2), rng.randi_range(0, 2)])
	var t0 := Time.get_ticks_usec()
	for c: Array in cases:
		Swing.plan(c[0], c[1][0], c[1][1], c[3], c[0] + 6.0, c[2][0], c[2][1], c[4], pick, drop, 0.014, 0.035, 0.0, true, 3)
	var t1 := Time.get_ticks_usec()
	var pp := _p(pick)
	var pd := _p(drop)
	for c: Array in cases:
		sw.plan(PackedFloat64Array([c[0], c[1][0], c[1][1], c[3], c[0] + 6.0, c[2][0], c[2][1], c[4]]), pp, pd, 0.014, 0.035, 0.0, true, 3, 1.6)
	var t2 := Time.get_ticks_usec()
	print("timing: a plan %.2f us in GDScript, %.2f us native (the call and its arrays included)" % [
		float(t1 - t0) / cases.size(), float(t2 - t1) / cases.size()])
