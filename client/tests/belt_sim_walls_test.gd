extends SceneTree
## A lane leading out of what the bridge sends (`lm` next < 0): its front item is a wall that moves only
## to where the bridge's reads of it say (set_wall); the items ahead of the wall item run off, the line
## behind stands or follows. A lane that simply ends still lets its items run up to its end.
##
##   godot --headless --path client -s res://tests/belt_sim_walls_test.gd     (exit 1 on failure)

const BeltSim := preload("res://scripts/world/belt_sim.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


## Two straight lanes, 17 feeding 9 (west), items packed and standing 40 short of 9's exit.
var native := false


func _world(out: bool) -> Object:
	var sim: Object = ClassDB.instantiate("BeltSimNative") if native else BeltSim.new()
	sim.set("edge_mode", BeltSim.EDGE_STOP)
	sim.set_lane(9, BeltSim.STRAIGHT, 256, 8, Vector2i(0, 0), Vector2i(128, 0), Vector2i(256, 0), 0, 0)
	sim.set_lane(17, BeltSim.STRAIGHT, 256, 8, Vector2i(256, 0), Vector2i(384, 0), Vector2i(512, 0), 0, 0)
	sim.set_out_edge(9, out)
	var a := PackedInt64Array()
	for j in 4:
		a.append_array([100 + j, 1, 40 + 64 * j, 1])
	var b := PackedInt64Array()
	for j in 4:
		b.append_array([200 + j, 1, 40 + 64 * j, 1])
	sim.load_lane(9, 100, a)
	sim.load_lane(17, 100, b)
	if out:
		sim.set_wall(9, 100, 100, 40)
	sim.step_to(100)
	return sim


func _at(sim: Object) -> Dictionary:
	var st: Array = sim.items_state()
	var d := {}
	for i in (st[0] as PackedInt64Array).size():
		d[int(st[0][i])] = [int(st[1][i]), int(st[2][i])]
	return d


func _initialize() -> void:
	_run()
	if NativeLibrary.ensure():
		print("and BeltSimNative:")
		native = true
		_run()
	print("FAILS: %d" % fails)
	quit(1 if fails > 0 else 0)


func _run() -> void:
	# A lane that ends: the packed line runs up to its end.
	var ends: Object = _world(false)
	ends.step_to(130)
	var e := _at(ends)
	check(e[100] == [9, 0] and e[103] == [9, 192] and e[200] == [17, 0], "a lane that ends: its items run to its end: %s" % e)
	# Leading out, no newer read: the line stands where it was read.
	var sim: Object = _world(true)
	sim.step_to(130)
	var s := _at(sim)
	check(s[100] == [9, 40] and s[103] == [9, 232] and s[203] == [17, 232], "leading out: the line stands at its wall: %s" % s)
	# A read at 140 has the front 40 further on: by then the whole packed line has moved 40.
	sim.set_wall(9, 140, 100, 0)
	sim.step_to(140)
	s = _at(sim)
	check(s[100] == [9, 0] and s[101] == [9, 64] and s[200] == [17, 0] and s[203] == [17, 192],
		"the wall moved: the line followed, as far: %s" % s)
	# A read at 150 has item 101 as the front, at 0: 100 ran off, the line moved one more gap.
	sim.set_wall(9, 150, 101, 0)
	sim.step_to(150)
	s = _at(sim)
	check(not s.has(100) and s[101] == [9, 0] and s[103] == [9, 128] and s[200] == [9, 192] and s[201] == [17, 0],
		"items ahead of the wall item run off: %s" % s)
	# Empty at 180: what was on the lane at 150 ran off by then; the line behind moved on.
	sim.set_wall(9, 180, 0, 0)
	sim.step_to(180)
	s = _at(sim)
	check(not s.has(101) and not s.has(103) and not s.has(200) and s[201] == [9, 16], "an empty read: the lane's items run off: %s" % s)
	# No longer leading out: an ordinary end again.
	sim.set_out_edge(9, false)
	sim.step_to(260)
	s = _at(sim)
	check(s[201] == [9, 0] and s[202] == [9, 64], "no longer leading out: up to its end: %s" % s)
	# (dead_walls) A lane leading nowhere that the bridge didn't say leads out (it sent the belt but not the one
	# it feeds, lm next 0), its front standing short of its end in the game: two reads finding the front
	# where it was wall it there, so the line behind stands too; off (as before), or after a read finding
	# it elsewhere, its front runs up to its end.
	for dw in [true, false]:
		var de: Object = _world(false)
		de.set("dead_walls", dw)
		de.set_wall(9, 100, 100, 40)
		de.set_wall(9, 104, 100, 40)
		de.step_to(160)
		var dd := _at(de)
		if dw:
			check(dd.get(100) == [9, 40] and dd.get(103) == [9, 232] and dd.get(203) == [17, 232],
				"a dead end two reads walled: the line stands there: %s" % dd)
			de.set_wall(9, 170, 101, 0)
			de.step_to(200)
			dd = _at(de)
			check(dd.get(100) == [9, 0] and dd.get(200) == [17, 0], "... a read finding it moved: up to its end again: %s" % dd)
		else:
			check(dd.get(100) == [9, 0] and dd.get(103) == [9, 192], "dead walls off: a dead end's front runs to its end: %s" % dd)
	# A drift check (pc) of a packed lane: the same count, front and back, but other items (a whole gap
	# off) is a mismatch only by their ids (pu).
	var ok: Object = _world(true)
	ok.step_to(101)
	ok.check_lane(17, 102, 4, 40, 232, 200, 203)
	ok.check_lane(9, 102, 4, 40, 232, 101, 200)
	ok.step_to(103)
	var mm: Array = ok.take_changes()["mismatch"]
	check(mm.has(9) and not mm.has(17), "a packed lane's drift check: a mismatch by its items' ids only: %s" % [mm])
	# A read of one lane of a packed line that crept on a gap in the game: the line either side moves
	# with it (the item that crossed into the lane in front stays, the lane behind keeps its front).
	var cr: Object = _world(true)
	cr.set_lane(25, BeltSim.STRAIGHT, 256, 8, Vector2i(512, 0), Vector2i(640, 0), Vector2i(768, 0), 0, 0)
	var c25 := PackedInt64Array()
	for j in 4:
		c25.append_array([300 + j, 1, 40 + 64 * j, 1])
	cr.load_lane(25, 101, c25)
	cr.step_to(110)
	var c17 := PackedInt64Array()
	for j in 3:
		c17.append_array([201 + j, 1, 40 + 64 * j, 1])
	c17.append_array([300, 1, 232, 1])
	cr.load_lane(17, 120, c17)
	cr.step_to(120)  # (as the read is applied: the wall still has the line standing)
	var gone: PackedInt64Array = cr.take_changes()["gone"]
	var c := _at(cr)
	check(c.get(200) == [9, 232] and c.get(103) == [9, 168] and c.get(101) == [9, 40] and not gone.has(200),
		"a creeping packed line read in the middle: the lane in front moved with it: %s gone %s" % [c, gone])
	check(c.get(301) == [25, 40] and c.get(303) == [25, 168] and c.get(300) == [17, 232],
		"... and the lane behind too: %s" % c)
	# The lattice's speed for a lane (lane_fronts, belt_lattice.gd lane_speed): its front waits at the wall
	# while the items behind it close up. speed_of 0: its front item's (standing); 1: most of its items'.
	var sg: Object = _world(true)
	var g9 := PackedInt64Array()
	for it in [[100, 40], [101, 160], [102, 224]]:
		g9.append_array([it[0], 1, it[1], 1])
	sg.load_lane(9, 101, g9)
	sg.set_wall(9, 101, 100, 40)
	sg.step_to(102)
	var f0: PackedInt32Array = sg.lane_fronts(PackedInt64Array([9, 17]), 0)
	var f1: PackedInt32Array = sg.lane_fronts(PackedInt64Array([9, 17]), 1)
	check(f0[0] == 40 and f0[1] == 0 and f1[0] == 40 and f1[1] == 8 and f1[2] == 3 and f0[4] == 8 and f1[4] == 8,
		"a lane whose front waits while the items behind close up moves at the lane's speed: front %s, lane %s" % [f0, f1])
