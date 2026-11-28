extends SceneTree
## MoversNative (movers_native.cpp) against its GDScript twins, on 5,000 random records of every kind
## (plain robots and creatures on the odd and even clocks, simulated robots on leg 1, leg 2, standing and
## orbiting, short and zero spans): write_xforms against MoverRecords.write_xform, positions against
## MoverRecords.position (M3, exactly), any_active against robot_swarm.gd _slot_active (M3). Then two
## movers layers sweep the same simulated robots for 600 frames, one with --native-mover-sweep and one
## without: targets and the robot grid must be equal every frame. Headless, no scene.
##
##   godot --headless --audio-driver Dummy --path client --log-file <abs> -s res://tests/movers_native_test.gd

const Movers := preload("res://scripts/world/movers.gd")
const MoverRecords := preload("res://scripts/world/mover_records.gd")
const RobotSwarm := preload("res://scripts/world/robot_swarm.gd")

const RECORDS := 5000
const ROBOTS := 300
const FRAMES := 600

var _fails := 0
var _rng := RandomNumberGenerator.new()


func _initialize() -> void:
	_rng.seed = 90210
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
		if _fails <= 20:
			print("FAIL: ", what)


func _run() -> void:
	var nat := MoverRecords.native()
	if nat == null or not nat.has_method("positions"):
		print("movers_native_test: MoversNative.positions missing (DLL not rebuilt, or --native-movers=off)")
		quit(1)
		return
	var recs := MoverRecords.new()
	recs.frame(1000.0, 60.0, 0.0)
	var slots := PackedInt32Array()
	for i in RECORDS:
		var s := recs.alloc()
		_randomize(recs, s, recs.tick)
		slots.push_back(s)
	for step in 6:
		var tick := 1000.0 + step * 37.3 + _rng.randf() * 5.0
		var rate: float = [60.0, 30.0, 0.5, 60.0, 120.0, 60.0][step]
		recs.frame(tick, rate, 0.016)
		_compare(nat, recs, slots, "step %d" % step)
	_sweep_parity()
	print("movers_native_test: %d failures" % _fails)
	quit(1 if _fails > 0 else 0)


## Random record floats (MoverRecords' layout: A..D at 0-7, their ticks 8-11, flags 12, height 13, yaws
## 14/16/17, write tick 15, orbit 21-23, blend/lag 24-28), around `now`.
func _randomize(recs: MoverRecords, slot: int, now: float) -> void:
	var o := slot * MoverRecords.FLOATS
	var d := recs.data
	for k in MoverRecords.FLOATS:
		d[o + k] = _rng.randf_range(-50.0, 50.0)
	var kinds := [0, MoverRecords.ODD, MoverRecords.SIMULATED, MoverRecords.SIMULATED | MoverRecords.ODD,
		MoverRecords.SIMULATED | MoverRecords.SIM_ORBIT, MoverRecords.SIMULATED | MoverRecords.SIM_ORBIT | MoverRecords.ODD,
		MoverRecords.ANIMATED | MoverRecords.CARGO, MoverRecords.SIMULATED | MoverRecords.SIM_WORKING]
	var flags: int = kinds[_rng.randi() % kinds.size()]
	var cl := recs.clocks()
	var c := cl.y if (flags & MoverRecords.ODD) != 0 else cl.x
	var t0 := c + _rng.randf_range(-300.0, 100.0)
	var ticks := [t0]
	for k in 3:
		var gap: float = [0.0, 0.00005, 1.0, 5.0, 40.0][_rng.randi() % 5]
		ticks.append(float(ticks[k]) + gap)
	for k in 4:
		d[o + 8 + k] = ticks[k]
	d[o + 12] = flags
	d[o + 13] = _rng.randf_range(0.0, 4.0)
	d[o + 15] = c + _rng.randf_range(-200.0, 5.0)
	d[o + 14] = _rng.randf_range(-7.0, 7.0)
	d[o + 16] = _rng.randf_range(-7.0, 7.0)
	d[o + 17] = d[o + 14] if _rng.randf() < 0.2 else _rng.randf_range(-7.0, 7.0)
	d[o + 21] = _rng.randf_range(0.5, 4.0)
	d[o + 22] = _rng.randf_range(-0.2, 0.2)
	d[o + 23] = _rng.randf_range(0.0, 2.0) if (flags & MoverRecords.SIMULATED) == 0 else _rng.randf_range(-7.0, 7.0)
	d[o + 24] = _rng.randf_range(0.0, 8.0)
	d[o + 25] = _rng.randf_range(0.5, 6.0)
	d[o + 26] = _rng.randf_range(0.5, 6.0)
	d[o + 27] = _rng.randf_range(0.0, 4.0)
	d[o + 28] = _rng.randf_range(0.01, 1.0)
	if _rng.randf() < 0.3:
		d[o + 6] = 0.0
		d[o + 7] = 0.0
	recs.data = d


func _compare(nat: RefCounted, recs: MoverRecords, slots: PackedInt32Array, label: String) -> void:
	var cl := recs.clocks()
	var c_even := MoverRecords._f32(cl.x)
	var c_odd := MoverRecords._f32(cl.y)
	var inv_rate := 1.0 / maxf(recs.rate, 1.0)
	var n := slots.size()
	# positions (M3)
	var t0 := Time.get_ticks_usec()
	var want: Array[Vector3] = []
	for s in slots:
		want.append(recs.position(s))
	var t_gd := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	var got: PackedVector3Array = nat.call("positions", recs.data, slots, n, cl.x, cl.y, recs.rate)
	var t_nat := Time.get_ticks_usec() - t0
	var pos_diff := 0
	for i in n:
		if want[i] != got[i]:
			pos_diff += 1
			_check(false, "%s positions: slot %d flags %d: %s vs %s" % [label, slots[i], int(recs.data[slots[i] * MoverRecords.FLOATS + 12]), want[i], got[i]])
	# any_active (M3), one record at a time and the whole list
	var act_diff := 0
	var any := false
	for i in n:
		var one := PackedInt32Array([slots[i]])
		var a := RobotSwarm._slot_active(recs, slots[i], c_even, c_odd, inv_rate)
		any = any or a
		if bool(nat.call("any_active", recs.data, one, 1, c_even, c_odd, inv_rate)) != a:
			act_diff += 1
			_check(false, "%s any_active: slot %d" % [label, slots[i]])
	_check(bool(nat.call("any_active", recs.data, slots, n, c_even, c_odd, inv_rate)) == any, "%s any_active over all" % label)
	_check(not bool(nat.call("any_active", recs.data, PackedInt32Array([-1, -1]), 2, c_even, c_odd, inv_rate)), "%s no records" % label)
	# write_xforms (the existing motion-vector path)
	var buf := PackedFloat32Array()
	buf.resize(n * 16)
	var out: PackedFloat32Array = nat.call("write_xforms", recs.data, slots, n, buf, c_even, c_odd, inv_rate, 0)
	var ref := PackedFloat32Array()
	ref.resize(n * 16)
	var xf_diff := 0
	for i in n:
		recs.write_xform(slots[i], ref, i * 16, c_even, c_odd, inv_rate)
		for k in 12:
			if absf(ref[i * 16 + k] - out[i * 16 + k]) > 1e-4:
				xf_diff += 1
				_check(false, "%s write_xforms: slot %d float %d: %f vs %f" % [label, slots[i], k, ref[i * 16 + k], out[i * 16 + k]])
				break
	print("%s: positions %d differ (GDScript %.2f us, native %.3f us a record), any_active %d differ, write_xforms %d differ" \
			% [label, pos_diff, float(t_gd) / n, float(t_nat) / n, act_diff, xf_diff])


## Two movers layers, the same simulated robots in each (their own Mover objects on one shared record
## store), swept for FRAMES frames: native positions vs MoverRecords.position per robot.
func _sweep_parity() -> void:
	var a: Movers = Movers.new()
	var b: Movers = Movers.new()
	a.native_sweep = true
	b.native_sweep = false
	b.records = a.records
	var recs := a.records
	recs.frame(500.0, 60.0, 0.0)
	var units: Array[int] = []
	for i in ROBOTS:
		var unit := 1000 + i
		var s := recs.alloc()
		_randomize(recs, s, recs.tick)
		for layer: Movers in [a, b]:
			var m := Movers.Mover.new()
			m.unit = unit
			m.sim = true
			m.slot = s
			m.recorded = i % 17 != 0
			m.bot = RobotSwarm.Bot.new()
			m.sim_heard_tick = 1.0e9
			layer._sim_movers[unit] = m
		units.append(unit)
	var t_a := 0
	var t_b := 0
	var cells_diff := 0
	for f in FRAMES:
		recs.frame(500.0 + f * 0.9, 60.0, 0.016)
		# Every 50 frames some robots get a new flight.
		if f % 50 == 25:
			for k in 20:
				_randomize(recs, a._sim_movers[units[_rng.randi() % ROBOTS]].slot, recs.tick)
		var t0 := Time.get_ticks_usec()
		a._sim_grid_sweep()
		t_a += Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		b._sim_grid_sweep()
		t_b += Time.get_ticks_usec() - t0
		for unit in units:
			var ma: Movers.Mover = a._sim_movers[unit]
			var mb: Movers.Mover = b._sim_movers[unit]
			if ma.target != mb.target or ma.cell != mb.cell:
				cells_diff += 1
				_check(false, "sweep frame %d unit %d: %s %s vs %s %s" % [f, unit, ma.target, ma.cell, mb.target, mb.cell])
		if a._robot_grid.size() != b._robot_grid.size():
			cells_diff += 1
			_check(false, "sweep frame %d: grid cells %d vs %d" % [f, a._robot_grid.size(), b._robot_grid.size()])
	_check(a._robot_grid.size() > 10, "robots spread over the grid (%d cells)" % a._robot_grid.size())
	print("sweep: %d frames x %d robots, %d differ; native %.1f us a frame, GDScript %.1f us (%d robots a sweep)" \
			% [FRAMES, ROBOTS, cells_diff, float(t_a) / FRAMES, float(t_b) / FRAMES, Movers.SIM_GRID_SLICE])
	a.free()
	b.free()
