extends SceneTree
## A lane leading out of what the bridge sends (`lm` next < 0): its front item is a wall that moves only
## to where the bridge's reads of it say (set_wall); the items ahead of the wall item run off, the line
## behind stands or follows. A lane that simply ends still lets its items run up to its end.
##
##   godot --headless --path client -s res://tests/belt_sim_walls_test.gd     (exit 1 on failure)

const BeltSim := preload("res://scripts/world/belt_sim.gd")

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
	if ClassDB.class_exists("BeltSimNative"):
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
