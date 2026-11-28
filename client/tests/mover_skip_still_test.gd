extends SceneTree
## M1 (--mover-skip-still): two movers layers (movers.gd) fed the same `mv` stream, one skipping the node
## movers that stand still (Mover.settled) and one working every mover out every frame as before
## (skip_still = false, what --mover-skip-still=off gives). Trains stop and start, one climbs a ramp onto
## elevated rails and parks there, one teleports, a car drives a curve and stops, rails are laid under a
## parked train (world entities_changed) and night falls: every node's transform and every wheel's must be
## equal in the two layers every frame (within SETTLE_ANGLE's slack), and the skipping layer must skip.
## Also prints both layers' _process_movers time. Headless, a stub world with world.gd's rail_height steps.
##
##   godot --headless --audio-driver Dummy --path client --log-file <abs> -s res://tests/mover_skip_still_test.gd

const Movers := preload("res://scripts/world/movers.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const Wire := preload("res://scripts/util/wire.gd")

const FRAMES := 900
const TOL := 0.002


class Chunk:
	var grid := {}


## world.gd's rail_height over a grid of [kind, at, reach squared | direction] (0 ground, 1 elevated,
## 2 ramp); a ramp gives its height along the slope (0 at the bottom, 3 at the top).
class StubWorld extends Node3D:
	signal entities_changed(chunk: Vector2i)
	const CHUNK := 32
	const RAIL_CELL := 4.0
	const RAMP_LENGTH := 16.0
	var entities := {}  # (movers.gd _paint reads it)
	var chunks := {}

	func add_rail(kind: int, at: Vector2, third: Variant) -> void:
		var entry := [kind, at, third]
		var reach := 2.8 if kind != 2 else RAMP_LENGTH * 0.5 + 1.0
		var lo := Vector2i(floori((at.x - reach) / RAIL_CELL), floori((at.y - reach) / RAIL_CELL))
		var hi := Vector2i(floori((at.x + reach) / RAIL_CELL), floori((at.y + reach) / RAIL_CELL))
		var ck := Vector2i(floori(at.x / CHUNK), floori(at.y / CHUNK))
		var cv: Chunk = chunks.get(ck)
		if cv == null:
			cv = Chunk.new()
			chunks[ck] = cv
		for cy in range(lo.y, hi.y + 1):
			for cx in range(lo.x, hi.x + 1):
				var cell := Vector2i(cx, cy)
				if not cv.grid.has(cell):
					cv.grid[cell] = []
				(cv.grid[cell] as Array).append(entry)

	func rail_height(point: Vector2, was: float) -> float:
		var ground := false
		var elevated := false
		var cell := Vector2i(floori(point.x / RAIL_CELL), floori(point.y / RAIL_CELL))
		var center := Vector2i(floori(point.x / CHUNK), floori(point.y / CHUNK))
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var c := center + Vector2i(dx, dy)
				var cv: Chunk = chunks.get(c)
				if cv == null:
					continue
				for e: Array in cv.grid.get(cell, []):
					var at: Vector2 = e[1]
					var kind := int(e[0])
					if kind == 2:
						var a := -Wire.direction_yaw(int(e[2]))
						var uphill := Vector2(sin(a), -cos(a))
						var d := point - at
						var along := d.dot(uphill)
						if absf(along) <= RAMP_LENGTH * 0.5 and absf(d.dot(Vector2(-uphill.y, uphill.x))) < 1.0:
							return (along / RAMP_LENGTH + 0.5) * 3.0
					elif point.distance_squared_to(at) <= float(e[2]):
						if kind == 1:
							elevated = true
						else:
							ground = true
		if elevated and (not ground or was > 1.5):
			return 3.0
		if ground:
			return 0.0
		return was


var world: StubWorld
var on_layer
var off_layer
var tick := 1000
var k := -1  # ticks of the script run (-1 while the models load: nothing moves)
var frame := 0
var wait_frames := 0
var started := false
var fails := 0
var worst := 0.0
var worst_at := ""
var skipped := 0
var compared := 0
var usec_on := 0
var usec_off := 0
## unit -> [proto id, x, y, orientation x 1000]
var stock := {}


func _initialize() -> void:
	ModelLibrary.configure_from_command_line()
	var protos := ProtoDB.new()
	var names := ["locomotive", "cargo-wagon", "car"]
	for i in names.size():
		var p := ProtoDB.EntityProto.new()
		p.id = i + 1
		p.name = names[i]
		p.type = names[i]
		protos.entities[p.id] = p
	world = StubWorld.new()
	# Ground rails along y = 10 (train A stops and starts) and y = 40 (train B parks; rails laid under it
	# later), a ramp going east at x 100..116 on y = 70 and elevated rails beyond it (train C climbs, parks).
	var x := -40.0
	while x < 400.0:
		world.add_rail(0, Vector2(x, 10.0), 2.8 * 2.8)
		world.add_rail(0 if x < 100.0 else 1, Vector2(x, 70.0), 2.8 * 2.8)
		x += 2.0
	world.add_rail(2, Vector2(108.0, 70.0), 4)  # east (direction 4 of 16)
	for u in 5:
		stock[100 + u] = [1 if u == 0 else 2, 40.0 - u * 7.0, 10.0, 250]
		stock[200 + u] = [1 if u == 0 else 2, 60.0 - u * 7.0, 40.0, 250]
		stock[300 + u] = [1 if u == 0 else 2, 80.0 - u * 7.0, 70.0, 250]
	stock[400] = [1, 20.0, 100.0, 250]  # teleports
	stock[500] = [3, 0.0, 130.0, 0]  # a car
	on_layer = _layer("On", protos, true)
	off_layer = _layer("Off", protos, false)
	root.add_child(world)
	process_frame.connect(_frame)


func _layer(n: String, protos: ProtoDB, skip: bool) -> Node:
	var l: Node = Movers.new()
	l.name = n
	l.protos = protos
	l.world = world
	l.skip_still = skip
	root.add_child(l)
	l.set_process(false)
	return l


## The script: what moves when (ticks after the start).
func _step() -> void:
	tick += 1
	if k < 0:
		_send()
		return
	k += 1
	# A: moves 0.5 a tick, stops 150..350, again 350..450.
	if k < 150 or (k >= 350 and k < 450):
		for u in 5:
			stock[100 + u][1] = float(stock[100 + u][1]) + 0.5
	# C: up the ramp onto the elevated rails, parks from tick 200.
	if k < 200:
		for u in 5:
			stock[300 + u][1] = float(stock[300 + u][1]) + 0.35
	# The teleport at 300.
	if k == 300:
		stock[400][1] = 160.0
	# The car: a curve to 120, then parked.
	if k < 120:
		var o := int(stock[500][3])
		stock[500][3] = (o + 3) % 1000
		var a := float(stock[500][3]) / 1000.0 * TAU
		stock[500][1] = float(stock[500][1]) + sin(a) * 0.3
		stock[500][2] = float(stock[500][2]) - cos(a) * 0.3
	_send()


func _send() -> void:
	if tick % 2 == 0:
		var list: Array = []
		for unit: int in stock:
			var s: Array = stock[unit]
			list.append([unit, s[0], int(float(s[1]) * 256.0), int(float(s[2]) * 256.0), s[3]])
		var msg := {"t": "mv", "k": tick, "p": 2, "l": list}
		on_layer.handle(msg.duplicate(true))
		off_layer.handle(msg.duplicate(true))


func _frame() -> void:
	for l: Node in [on_layer, off_layer]:
		if l.is_processing():
			l.set_process(false)
	ModelLibrary.poll()
	var delta := 1.0 / 60.0
	if not started:
		_step()
		on_layer._process_movers(delta)
		off_layer._process_movers(delta)
		wait_frames += 1
		if (on_layer._waiting.is_empty() and off_layer._waiting.is_empty() and wait_frames > 10) or wait_frames > 900:
			started = true
			var wheels := 0
			for m in on_layer._node_movers.values():
				wheels += m.wheels.size()
			print("mover_skip_still_test: ready after %d frames, %d node movers, %d wheels, %d waiting" % [
				wait_frames, on_layer._node_movers.size(), wheels, on_layer._waiting.size()])
			k = 0
		return
	frame += 1
	_step()
	if k == 500:
		# Rails change under parked train B, but world.gd's _rail_grid may answer from its old grid for up to
		# RAIL_REBUILD_FRAMES (120) frames: the elevated rails show up in rail_height 40 frames after the
		# signal, and B (woken, seeing nothing new at first) must still rise in both layers (perf-fix-r1).
		world.entities_changed.emit(Vector2i(1, 1))
	if k == 540:
		var x := 0.0
		while x < 90.0:
			world.add_rail(1, Vector2(x, 40.0), 2.8 * 2.8)
			x += 2.0
	# main.gd's _update_sky calls set_night every frame: it must not wake the settled movers (perf-fix-r1).
	var night := 1.0 if k >= 600 else 0.0
	on_layer.set_night(night)
	off_layer.set_night(night)
	var t0 := Time.get_ticks_usec()
	on_layer._process_movers(delta)
	var t1 := Time.get_ticks_usec()
	off_layer._process_movers(delta)
	usec_on += t1 - t0
	usec_off += Time.get_ticks_usec() - t1
	skipped += int(on_layer.still_skipped)
	if int(off_layer.still_skipped) != 0:
		_fail("frame %d: the off layer skipped %d" % [frame, off_layer.still_skipped])
	_compare()
	if frame == FRAMES:
		_finish()


func _compare() -> void:
	for unit: int in on_layer._node_movers:
		var a = on_layer._node_movers[unit]
		var b = off_layer._node_movers.get(unit)
		if b == null:
			_fail("frame %d: unit %d missing in the off layer" % [frame, unit])
			continue
		_diff(a.node.transform, b.node.transform, "unit %d node" % unit)
		if a.wheels.size() != b.wheels.size():
			_fail("frame %d: unit %d wheel count %d vs %d" % [frame, unit, a.wheels.size(), b.wheels.size()])
			continue
		for i in a.wheels.size():
			_diff((a.wheels[i][0] as Node3D).transform, (b.wheels[i][0] as Node3D).transform, "unit %d wheel %d" % [unit, i])
		compared += 1


func _diff(p: Transform3D, q: Transform3D, what: String) -> void:
	var d := p.origin.distance_to(q.origin)
	for i in 3:
		d = maxf(d, (p.basis[i] - q.basis[i]).length())
	if d > worst:
		worst = d
		worst_at = "frame %d %s" % [frame, what]
	if d > TOL:
		_fail("frame %d: %s differs by %.5f" % [frame, what, d])


func _fail(s: String) -> void:
	fails += 1
	if fails <= 20:
		print("FAIL ", s)


func _finish() -> void:
	var b_y: float = on_layer._node_movers[200].node.position.y
	var c_y: float = on_layer._node_movers[300].node.position.y
	if b_y < 2.9:
		_fail("train B did not rise onto the rails laid under it (y %.3f)" % b_y)
	if c_y < 2.9:
		_fail("train C is not on the elevated rails (y %.3f)" % c_y)
	var n: int = on_layer._node_movers.size()
	var still_share := skipped / float(FRAMES * n)
	if still_share < 0.3:
		_fail("only %.0f%% of mover-frames skipped" % (still_share * 100.0))
	print("mover_skip_still_test: %d frames, %d mover-frames compared, %d skipped (%.0f%%), worst difference %.6f at %s" % [
		FRAMES, compared, skipped, still_share * 100.0, worst, worst_at])
	print("mover_skip_still_test: _process_movers ms a frame: skip on %.4f, off %.4f" % [
		usec_on / float(FRAMES) / 1000.0, usec_off / float(FRAMES) / 1000.0])
	print("mover_skip_still_test: %s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
	quit(1 if fails > 0 else 0)
