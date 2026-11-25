extends "res://tests/ui_test_base.gd"
## UI test sections: build.

func _predictions(hud: Hud) -> void:
	var m: UiModel = hud.ui.model
	var world := WorldMirror.new()
	# What is under a point is looked up in each chunk's pick index, built in play a slice a frame
	# from the frame budget's "pick" share: after other sections spent it this frame, picks found
	# nothing (J23's pair, J24's marks and the underground's end failed only after other sections).
	world.pick_build_usec = 1 << 40
	world.protos.add_entities([
		[1, "wooden-chest", "container", -0.35, -0.35, 0.35, 0.35, 120, 90, 60, 1, 1],
		[2, "stone-furnace", "furnace", -0.9, -0.9, 0.9, 0.9, 120, 120, 120, 2, 2],
		[3, "underground-belt", "underground-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[4, "inserter", "inserter", -0.15, -0.15, 0.15, 0.15, 200, 180, 0, 1, 1],
		[5, "splitter", "splitter", -0.9, -0.4, 0.9, 0.4, 200, 180, 0, 2, 1],
	])
	world.protos.item_places = {"wooden-chest": "wooden-chest", "stone-furnace": "stone-furnace", "underground-belt": "underground-belt"}
	world.chunks[Vector2i.ZERO] = ChunkView.new()
	# A model not made yet isn't predicted (predicted.gd), and earlier sections' asking for these
	# only makes that likely: read them first.
	var until_models := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < until_models and not world.protos.entities_by_name.values().all(
			func(p: ProtoDB.EntityProto) -> bool: return ModelLibrary.entity_ready(p.name, p.type, {}, 0)):
		ModelLibrary.poll()
		await get_tree().process_frame
	var pred := Predicted.new()
	pred.world = world
	add_child(pred)
	var input := PlayerInput.new()
	input.world = world
	input.hud = hud
	input.predicted = pred
	input.drag.pi = input
	var had: Array = m.main_slots
	var had_slots := m.has_slots
	var had_counts: Dictionary = m.counts.duplicate()
	m.handle({"t": "slots", "l": {"main": [["wooden-chest", 2], ["stone-furnace", 5], ["underground-belt", 4]]}})
	var chest: ProtoDB.EntityProto = world.protos.entity(1)
	var tick0 := Bridge.server_tick
	# Clicked off the tile's centre: the mod snaps the point to the grid, and so does the prediction
	# (drawn at the click it stood up to half a tile off the game's and never matched it).
	input.drag.begin("wooden-chest", chest, Vector2(3.83, 3.21), false)
	input.drag.end()
	check(pred.count() == 1 and pred.get_child_count() == 1, "a chest built shows at once, before the game answers")
	check(pred.count() == 1 and pred._pending[0].pos == Vector2(3.5, 3.5), "a click off the tile's centre is shown on the tile, where the mod builds it")
	input.drag.begin("wooden-chest", chest, Vector2(5.5, 3.5), false)
	input.drag.end()
	input.drag.begin("wooden-chest", chest, Vector2(7.5, 3.5), false)
	input.drag.end()
	check(pred.count() == 2, "no more shown than the inventory holds (2 chests: the third may be refused)")
	input.drag.begin("underground-belt", world.protos.entity(3), Vector2(3.5, 8.5), false)
	input.drag.end()
	check(pred.count() == 2, "an underground isn't shown: the mod decides entrance or exit")
	world._add([70, 2, 10 * 256, 10 * 256, 0])  # a furnace already standing there
	input.drag.begin("stone-furnace", world.protos.entity(2), Vector2(10, 10), false)
	input.drag.end()
	check(pred.count() == 2, "nothing is shown over what is already there")
	# The game's chest arrives: kept until its chunk has drawn it, then the prediction goes.
	world._add([71, 1, 3 * 256 + 128, 3 * 256 + 128, 0])
	pred._on_entities_changed(Vector2i.ZERO)
	check(pred.pending_of(chest) == 1, "the game's chest confirms the prediction at its place")
	pred._process(0.0)
	check(pred.count() == 2, "while the chunk isn't drawn yet the prediction stays, so nothing blinks")
	var cv: ChunkView = world.chunks[Vector2i.ZERO]
	cv.loaded = true
	world._dirty.erase(Vector2i.ZERO)
	pred._process(0.0)
	check(pred.count() == 1 and pred.waits.size() == 1, "once drawn the prediction goes and its wait is recorded")
	# The other chest never comes back: the game moved on without it, so it was refused.
	Bridge.server_tick = tick0 + Predicted.REFUSED_TICKS
	pred._pending[0].msec -= Predicted.REFUSED_MSEC
	pred._process(0.0)
	check(pred.count() == 0 and pred.refused == 1, "a build the game moved on without (refused) disappears")
	Bridge.server_tick = tick0
	# R: an inserter turns at once in the world mirror, twice turns twice, and goes back if the game
	# moves on without turning it.
	world._add([80, 4, 12 * 256 + 128, 12 * 256 + 128, 0])
	var ins: WorldMirror.Rec = world.entities[80]
	world._dirty.erase(Vector2i.ZERO)
	check(pred.turn(ins, false) and ins.dir == 4 and world._dirty.has(Vector2i.ZERO), "R turns an inserter at once and redraws its chunk")
	pred.turn(ins, false)
	check(ins.dir == 8, "a second R before the game answers turns it on from there")
	Bridge.server_tick = tick0 + Predicted.REFUSED_TICKS
	pred._turns[80].msec -= Predicted.REFUSED_MSEC
	pred._process(0.0)
	check(ins.dir == 0 and pred._turns.is_empty(), "turned back to where it was when the game didn't turn it")
	Bridge.server_tick = tick0
	pred.turn(ins, true)
	world._add([80, 4, 12 * 256 + 128, 12 * 256 + 128, 12])  # the game's `upd`
	Bridge.server_tick = tick0 + Predicted.REFUSED_TICKS * 2
	pred._process(0.0)
	check((world.entities[80] as WorldMirror.Rec).dir == 12 and pred._turns.is_empty(), "the game's own record replaces the turn; nothing is turned back")
	check(not pred.turn(world.entities[70], false), "a furnace isn't turned ahead (Factorio may refuse)")
	# As 2.1.23 turns them: longer one way, half way round; an underground, half way round as its other end.
	world._add([81, 5, 15 * 256, 12 * 256 + 128, 0])
	var spl: WorldMirror.Rec = world.entities[81]
	pred.turn(spl, false)
	var after_r := spl.dir
	pred.turn(spl, true)
	check(after_r == 8 and spl.dir == 0, "a splitter flips half way round on R and on Shift+R, as Factorio turns it")
	world._add([82, 3, 18 * 256 + 128, 12 * 256 + 128, 4, {"u": "i"}])
	var ug: WorldMirror.Rec = world.entities[82]
	pred.turn(ug, false)
	check(ug.dir == 12 and str(ug.extra.get("u")) == "o", "an underground entrance turns into an exit facing back")
	# J23: R on one end of a pair turns the other with it, as Factorio does (2.1.24 flips both); one
	# rotate goes to the game, which sends both ends back.
	world._add([84, 3, 24 * 256 + 128, 12 * 256 + 128, 4, {"u": "i"}])
	world._add([85, 3, 27 * 256 + 128, 12 * 256 + 128, 4, {"u": "o"}])
	world._add([86, 3, 31 * 256 + 128, 12 * 256 + 128, 4, {"u": "o"}])  # an exit with no entrance in reach
	var had_under: Variant = m.eprops.get(3)
	m.eprops[3] = {"under": 5.0, "wire": 0.0, "supply": 0.0, "x": {}}
	input.tile_brush.pi = input
	input.cursor_item = ""
	input.hovered = world.entities[84]
	sent()
	input._rotate(false)
	var ug_in: WorldMirror.Rec = world.entities[84]
	var ug_out: WorldMirror.Rec = world.entities[85]
	var rotates: Array = sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "rotate")
	check(ug_in.dir == 12 and str(ug_in.extra.get("u")) == "o" and ug_out.dir == 12 and str(ug_out.extra.get("u")) == "i"
		and (world.entities[86] as WorldMirror.Rec).dir == 4 and rotates.size() == 1 and int(rotates[0].get("u", 0)) == 84,
		"J23: R on an underground's entrance shows its exit turned with it (entrance and exit swapped), one rotate sent: %s" % [rotates])
	check(UndergroundPairs.partner(world, ug_out, 5) == ug_in and UndergroundPairs.partner(world, world.entities[86], 5) == null,
		"J23: the pair is still a pair the other way round; a lone exit has no partner")
	input.hovered = null
	if had_under == null:
		m.eprops.erase(3)
	else:
		m.eprops[3] = had_under
	Bridge.server_tick = tick0
	sent()
	m.main_slots = had
	m.counts = had_counts
	m.has_slots = had_slots
	input.free()
	pred.queue_free()


## L2 (the owner's playtest, 7:52: a belt drag with 6 in hand showed about 17, the game refused 11):
## the game's `add` comes on its next tick but the inventory only with its report up to 30 ticks later,
## so builds it had made dropped out of the prediction's count while the inventory shown still had their
## items. Played here: a drag of chests with 6 in hand, the game answering each build two steps later
## and no inventory report during the drag. Now 6 are sent and drawn and the drag stops ("You have no");
## the inventory heard after the `add`s pays for them; a report in the middle of a drag counts right; a
## refused build spends nothing; building over the same building (a turn) spends nothing; the count at
## the cursor counts down (factorio_ui.gd cursor_count). --build-spend=off is the old drag, the bug.
## M2 (the owner: placing undergrounds over belts should remove the belts between them): Factorio mines the belts
## between an underground pair a build completes when every tile between holds a plain one (the pair's way,
## straight, fed by nothing from the side; pipes joined to nothing off the line), or none. A held underground marks
## them as Factorio does (underground_remove_belts: red-orange corner brackets and the yellow arrow; pipes without
## it) instead of its connection, and the build hides them at once (predicted.gd clear_run) until the game's `mnd`
## takes them, shown again if the game keeps them. --underground-clear=off: as before.


func _underground_clear(hud: Hud) -> void:
	var m: UiModel = hud.ui.model
	var world := WorldMirror.new()
	world.pick_build_usec = 1 << 40  # the whole pick index at once (see _predictions)
	world.protos.add_entities([
		[1, "transport-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[2, "underground-belt", "underground-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[3, "pipe", "pipe", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1],
		[4, "pipe-to-ground", "pipe-to-ground", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1],
		[5, "splitter", "splitter", -0.9, -0.4, 0.9, 0.4, 200, 180, 0, 2, 1],
	])
	world.protos.item_places = {"underground-belt": "underground-belt", "pipe-to-ground": "pipe-to-ground"}
	var had_eprops: Dictionary = m.eprops.duplicate(true)
	m.handle({"t": "eprops", "l": [[2, 5, 0, 0], [4, 10, 0, 0]]})
	world.chunks[Vector2i.ZERO] = ChunkView.new()
	var under: ProtoDB.EntityProto = world.protos.entity(2)
	var ptg: ProtoDB.EntityProto = world.protos.entity(4)
	var unit := [2000]
	var put := func(proto_id: int, x: float, y: float, dir: int, extra: Dictionary) -> WorldMirror.Rec:
		unit[0] += 1
		world._add([unit[0], proto_id, roundi(x * 256.0), roundi(y * 256.0), dir, extra])
		return world.entities.get(unit[0])
	var wipe := func() -> void:
		for key in world.chunks[Vector2i.ZERO].entities.keys():
			world._remove(key)
	# A run: an entrance at x 2.5, belts east from 3.5 to 6.5, the exit held at 7.5 (the belt there it replaces).
	var lay := func(y: float) -> Array:
		put.call(2, 2.5, y, 4, {"u": "i"})
		var run: Array = []
		for x in [3.5, 4.5, 5.5, 6.5]:
			run.append(put.call(1, x, y, 4, {"s": "s"}))
		put.call(1, 7.5, y, 4, {"s": "s"})
		return run
	var units := func(recs: Array) -> Array:
		return recs.map(func(r: WorldMirror.Rec) -> int: return r.unit)
	var kinds := func(marks: Array) -> Array:
		return marks.filter(func(k: Dictionary) -> bool: return k["k"] == "unbuilt" or k["k"] == "tunnel").map(
			func(k: Dictionary) -> Array: return [int(floorf((k["at"] as Vector2).x)), str(k["k"]), bool(k["arrow"])])
	var held := Vector2(7.5, 5.5)

	var run: Array = lay.call(5.5)
	var going: Array = UndergroundPairs.cleared(world, under, held, 4, 5)
	var marks: Array = kinds.call(UndergroundPairs.held_marks(world, under, held, 4, 5))
	check(units.call(going) == units.call(run), "M2: an exit held over a plain run would mine the four belts between: %s" % [units.call(going)])
	check(marks == [[3, "unbuilt", true], [4, "unbuilt", true], [5, "unbuilt", true], [6, "unbuilt", true]],
		"M2: those tiles show Factorio's underground_remove_belts (brackets and the arrow), not the connection: %s" % [marks])
	var overlay := CursorOverlay.new()
	overlay.show_marks(UndergroundPairs.held_marks(world, under, held, 4, 5))
	# Each tile: two arms in each of four corners and the arrow's three edges, 2 triangles each.
	check((overlay._mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() == 4 * 11 * 6,
		"M2: the overlay draws each tile's eight bracket arms and the arrow")
	overlay.free()
	check(UndergroundPairs.cleared(world, under, Vector2(9.5, 5.5), 4, 5).is_empty()
		and UndergroundPairs.cleared(world, under, held, 12, 5).is_empty(),
		"M2: past a belt the run isn't between (a gap); held facing the other way it joins nothing")
	# Not a plain run: nothing goes, the connection is drawn as before.
	var cases := {}
	var side: WorldMirror.Rec = put.call(1, 4.5, 4.5, 8, {"s": "s"})  # a belt side-loading into the second (from the north)
	cases["a belt side-loading into it"] = UndergroundPairs.cleared(world, under, held, 4, 5)
	world._remove(side.unit)
	var spl: WorldMirror.Rec = put.call(5, 6.0, 6.5, 0, {})  # a splitter below facing north: it puts out onto the last two
	cases["a splitter feeding it"] = UndergroundPairs.cleared(world, under, held, 4, 5)
	world._remove(spl.unit)
	(run[1] as WorldMirror.Rec).dir = 12
	cases["a belt the other way"] = UndergroundPairs.cleared(world, under, held, 4, 5)
	(run[1] as WorldMirror.Rec).dir = 4
	(run[2] as WorldMirror.Rec).extra = {"s": "l"}
	cases["a curve"] = UndergroundPairs.cleared(world, under, held, 4, 5)
	(run[2] as WorldMirror.Rec).extra = {"s": "s"}
	world._remove((run[3] as WorldMirror.Rec).unit)
	cases["a gap"] = UndergroundPairs.cleared(world, under, held, 4, 5)
	var ghost: WorldMirror.Rec = put.call(1, 6.5, 5.5, 4, {"gh": 1})
	cases["a ghost belt"] = UndergroundPairs.cleared(world, under, held, 4, 5)
	world._remove(ghost.unit)
	for name in cases:
		check((cases[name] as Array).is_empty(), "M2: %s keeps the run (none marked)" % name)
	var kept: Array = kinds.call(UndergroundPairs.held_marks(world, under, held, 4, 5))
	check(kept.all(func(k: Array) -> bool: return k[1] == "tunnel"), "M2: and the connection is drawn as before: %s" % [kept])
	wipe.call()
	# Pipes-to-ground over pipes: the same, without the arrow; a pipe with a branch keeps them.
	put.call(4, 2.5, 9.5, 12, {})
	var pipes: Array = []
	for x in [3.5, 4.5, 5.5, 6.5]:
		pipes.append(put.call(3, x, 9.5, 0, {"pc": 10}))
	var pipe_going: Array = UndergroundPairs.cleared(world, ptg, Vector2(7.5, 9.5), 4, 10)
	var pipe_marks: Array = kinds.call(UndergroundPairs.held_marks(world, ptg, Vector2(7.5, 9.5), 4, 10))
	var pipe_unbuilt := pipe_marks.filter(func(k: Array) -> bool: return k[1] == "unbuilt")
	check(units.call(pipe_going) == units.call(pipes) and pipe_unbuilt.size() == 4
		and pipe_unbuilt.all(func(k: Array) -> bool: return not k[2]) and pipe_marks.size() == 5,
		"M2: a pipe-to-ground held over pipes marks the four between, brackets only (and its furthest exit): %s" % [pipe_marks])
	(pipes[1] as WorldMirror.Rec).extra = {"pc": 11}  # joined north too: a branch
	check(UndergroundPairs.cleared(world, ptg, Vector2(7.5, 9.5), 4, 10).is_empty(), "M2: a pipe with a branch keeps them")
	wipe.call()

	# The build hides them at once; the game's `mnd` takes them; kept by the game, they come back.
	var until_models := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < until_models and not ModelLibrary.entity_ready("underground-belt", "underground-belt", {"u": "o"}, 4):
		ModelLibrary.poll()
		await get_tree().process_frame
	var pred := Predicted.new()
	pred.world = world
	add_child(pred)
	var input := PlayerInput.new()
	input.world = world
	input.hud = hud
	input.predicted = pred
	input.drag.pi = input
	# Held east: an underground's click goes as the button lets go (drag_build.gd end), while it is still held.
	input.cursor_item = "underground-belt"
	input.build_dir = 4
	var had: Array = m.main_slots
	var had_slots := m.has_slots
	var had_counts: Dictionary = m.counts.duplicate()
	m.handle({"t": "slots", "l": {"main": [["underground-belt", 10], ["pipe-to-ground", 10]]}})
	var tick0 := Bridge.server_tick
	sent()
	run = lay.call(5.5)
	world._dirty.erase(Vector2i.ZERO)
	input.drag.begin("underground-belt", under, held, false)
	input.drag.end()
	var cmds := sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "build")
	var hidden: bool = run.all(func(r: WorldMirror.Rec) -> bool: return r.extra.has("hid"))
	check(cmds.size() == 1 and hidden and world._dirty.has(Vector2i.ZERO) and world.pick(Vector2(4.5, 5.5)) == null,
		"M2: building the exit hides the four belts between at once (not picked, their chunk redrawn): %s" % [cmds])
	for r: WorldMirror.Rec in run:
		world.mined({"t": "mnd", "u": r.unit, "p": 1, "x": r.fixed.x, "y": r.fixed.y, "g": 1, "l": [["transport-belt", 1]]})
	Bridge.server_tick = tick0 + Predicted.REFUSED_TICKS
	for key in pred._removed:
		(pred._removed[key] as Predicted.Turn).msec -= Predicted.REFUSED_MSEC
	pred._process(0.0)
	check(pred._removed.is_empty() and pred.refused == 0 and run.all(func(r: WorldMirror.Rec) -> bool: return not world.entities.has(r.unit)),
		"M2: the game's `mnd`s take them; nothing comes back")
	Bridge.server_tick = tick0
	wipe.call()
	run = lay.call(5.5)
	input.drag.begin("underground-belt", under, held, false)
	input.drag.end()
	Bridge.server_tick = tick0 + Predicted.REFUSED_TICKS
	for key in pred._removed:
		(pred._removed[key] as Predicted.Turn).msec -= Predicted.REFUSED_MSEC
	pred._process(0.0)
	check(pred.refused == 4 and run.all(func(r: WorldMirror.Rec) -> bool: return not r.extra.has("hid")) and world.pick(Vector2(4.5, 5.5)) != null,
		"M2: when the game moves on without mining them they are shown again (refused %d)" % pred.refused)
	Bridge.server_tick = tick0
	# M2's leftover: a drag places both ends. The exit is sent before the entrance's `add` has come (the
	# world still holds the belt the entrance replaces): it pairs with the entrance just sent, so the run
	# between goes with the build, not with the game's `mnd` a tick later.
	wipe.call()
	pred.reset()
	pred.refused = 0
	var line: Array = []
	for x in [2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5]:
		line.append(put.call(1, x, 5.5, 4, {"s": "s"}))
	var between: Array = line.slice(1, 5)
	sent()
	input.drag.begin("underground-belt", under, Vector2(2.5, 5.5), false)
	for x in [3.5, 4.5, 5.5, 6.5, 7.5]:
		input.drag.update(Vector2(x, 5.5))
	var pair: Array = sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "build")
	var pair_at: Array = pair.map(func(c: Dictionary) -> Array: return [int(c["x"]) / 256.0, int(c["d"])])
	var no_add: bool = (world.pick(Vector2(2.5, 5.5)) as WorldMirror.Rec).proto_id == 1
	check(pair_at == [[2.5, 4], [7.5, 4]] and no_add and between.all(func(r: WorldMirror.Rec) -> bool: return r.extra.has("hid"))
		and not (line[0] as WorldMirror.Rec).extra.has("hid") and not (line[6] as WorldMirror.Rec).extra.has("hid"),
		"M2: a drag's exit sent before its entrance's `add` came hides the four belts between at once: %s hidden %s" % [pair_at,
			between.map(func(r: WorldMirror.Rec) -> bool: return r.extra.has("hid"))])
	var sent_now: Array = pred.sent_undergrounds()
	check(sent_now.size() == 2 and str((sent_now[0] as WorldMirror.Rec).extra.get("u")) == "i" and str((sent_now[1] as WorldMirror.Rec).extra.get("u")) == "o"
		and UndergroundPairs.held_join(world, under, Vector2(12.5, 5.5), 4, 5, sent_now).is_empty()
		and str(input.build_extra(under, Vector2(6.5, 5.5), 4).get("u")) == "o" and str(input.build_extra(under, Vector2(9.5, 5.5), 4).get("u")) == "i",
		"M2: the pieces on their way are an entrance and its exit: a piece held between them is drawn as an exit, past the exit as a new entrance")
	input.drag.end()
	# The game answers: the entrance and the exit stand, the run is mined. Nothing comes back, nothing is left over.
	world._remove((line[0] as WorldMirror.Rec).key)
	world._remove((line[5] as WorldMirror.Rec).key)
	put.call(2, 2.5, 5.5, 4, {"u": "i"})
	put.call(2, 7.5, 5.5, 4, {"u": "o"})
	for r: WorldMirror.Rec in between:
		world.mined({"t": "mnd", "u": r.unit, "p": 1, "x": r.fixed.x, "y": r.fixed.y, "g": 1, "l": [["transport-belt", 1]]})
	pred._process(0.0)
	check(pred.sent_undergrounds().is_empty() and pred._removed.is_empty() and pred.refused == 0,
		"M2: once both ends stand in the world the sent pieces are forgotten; the mined run leaves nothing behind")
	# A side-loaded run isn't plain: the drag's pair keeps it, as the game does.
	wipe.call()
	line.clear()
	for x in [2.5, 3.5, 4.5, 5.5, 6.5, 7.5]:
		line.append(put.call(1, x, 5.5, 4, {"s": "s"}))
	put.call(1, 4.5, 6.5, 0, {"s": "s"})
	input.drag.begin("underground-belt", under, Vector2(2.5, 5.5), false)
	for x in [3.5, 4.5, 5.5, 6.5, 7.5]:
		input.drag.update(Vector2(x, 5.5))
	input.drag.end()
	check(sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "build").size() == 2
		and line.all(func(r: WorldMirror.Rec) -> bool: return not r.extra.has("hid")),
		"M2: a drag's pair over a side-loaded run hides nothing")
	# The entrance refused (no `add`): it is forgotten after the refusal wait, and a later piece doesn't pair with it.
	Bridge.server_tick = tick0 + Predicted.REFUSED_TICKS
	for s in pred._sent_unders:
		(s as Predicted.SentUnder).msec -= Predicted.REFUSED_MSEC
	pred._process(0.0)
	check(pred.sent_undergrounds().is_empty(), "M2: a piece the game never built is forgotten after the refusal wait")
	Bridge.server_tick = tick0
	# Pipes-to-ground the same: the first connected back along the line, the second forward, the pipes between hidden.
	wipe.call()
	pred.reset()
	var drag_pipes: Array = []
	for x in [2.5, 3.5, 4.5, 5.5, 6.5]:
		drag_pipes.append(put.call(3, x, 9.5, 0, {"pc": 10}))
	input.cursor_item = "pipe-to-ground"
	m.handle({"t": "eprops", "l": [[2, 5, 0, 0], [4, 4, 0, 0]]})
	input.drag.begin("pipe-to-ground", ptg, Vector2(2.5, 9.5), false)
	for x in [3.5, 4.5, 5.5, 6.5]:
		input.drag.update(Vector2(x, 9.5))
	input.drag.end()
	var pipe_pair: Array = sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "build").map(
		func(c: Dictionary) -> Array: return [int(c["x"]) / 256.0, int(c["d"])])
	check(pipe_pair == [[2.5, 12], [6.5, 4]] and drag_pipes.slice(1, 4).all(func(r: WorldMirror.Rec) -> bool: return r.extra.has("hid")),
		"M2: a drag's pipe-to-ground pair hides the pipes between at once: %s" % [pipe_pair])
	# Placing a pipe-to-ground flips the held cursor 180 degrees to face its connecting end (both real and ghost).
	m.handle({"t": "eprops", "l": [[2, 5, 0, 0], [4, 10, 0, 0]]})
	wipe.call()
	pred.reset()
	sent()
	input.cursor_item = "pipe-to-ground"
	input.build_dir = 8
	input.drag.begin("pipe-to-ground", ptg, Vector2(10.5, 10.5), false)
	input.drag.end()
	var ptg_cmds: Array = sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "build")
	var ptg_join1 := UndergroundPairs.held_join(world, ptg, Vector2(10.5, 6.5), input.build_dir, 10, input._sent_unders())
	check(ptg_cmds.size() == 1 and int(ptg_cmds[0]["d"]) == 8 and input.build_dir == 0
		and not ptg_join1.is_empty() and int(ptg_join1["k"]) == 4 and not bool(ptg_join1["far"]),
		"placing a south pipe-to-ground flips held dir 180 to north and joins immediately on frame 0: cmds=%s dir=%d join=%s" % [ptg_cmds, input.build_dir, ptg_join1])
	input.drag.begin("pipe-to-ground", ptg, Vector2(10.5, 6.5), false)
	input.drag.end()
	var ptg_cmds2: Array = sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "build")
	check(ptg_cmds2.size() == 1 and int(ptg_cmds2[0]["d"]) == 0 and input.build_dir == 8,
		"placing the north partner flips held dir 180 back to south: cmds=%s dir=%d" % [ptg_cmds2, input.build_dir])
	# Ghost pipe-to-ground: flips 180, records frame-0 partner for held_join, and does not clear pipes against a ghost partner.
	wipe.call()
	pred.reset()
	sent()
	for y in [7.5, 8.5, 9.5]:
		put.call(3, 15.5, y, 0, {"pc": 5})
	input.build_dir = 8
	input.drag.begin("pipe-to-ground", ptg, Vector2(15.5, 10.5), true)
	input.drag.end()
	var ptg_ghost_cmds: Array = sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "build")
	var ptg_ghost_join := UndergroundPairs.held_join(world, ptg, Vector2(15.5, 6.5), input.build_dir, 10, input._sent_unders())
	check(ptg_ghost_cmds.size() == 1 and int(ptg_ghost_cmds[0]["d"]) == 8 and int(ptg_ghost_cmds[0].get("ghost", 0)) == 1
		and input.build_dir == 0 and not ptg_ghost_join.is_empty() and int(ptg_ghost_join["k"]) == 4 and not bool(ptg_ghost_join["far"])
		and UndergroundPairs.cleared(world, ptg, Vector2(15.5, 6.5), 0, 10, input._sent_unders()).is_empty(),
		"ghost pipe-to-ground flips 180, joins on frame 0, and keeps pipes between: cmds=%s dir=%d join=%s" % [ptg_ghost_cmds, input.build_dir, ptg_ghost_join])
	# Blocked or duplicate pipe-to-ground does not flip; fast-replacing a plain pipe does.
	wipe.call()
	pred.reset()
	sent()
	put.call(5, 20.0, 10.5, 0, {})
	input.build_dir = 8
	input.drag.begin("pipe-to-ground", ptg, Vector2(20.5, 10.5), false)
	input.drag.end()
	var kept_blocked: int = input.build_dir
	put.call(4, 22.5, 10.5, 8, {})
	input.build_dir = 8
	input.drag.begin("pipe-to-ground", ptg, Vector2(22.5, 10.5), false)
	input.drag.end()
	var kept_same: int = input.build_dir
	put.call(3, 24.5, 10.5, 0, {"pc": 5})
	input.build_dir = 8
	input.drag.begin("pipe-to-ground", ptg, Vector2(24.5, 10.5), false)
	input.drag.end()
	var flipped_replace: int = input.build_dir
	check(kept_blocked == 8 and kept_same == 8 and flipped_replace == 0,
		"pipe-to-ground does not flip when blocked (%d) or over same proto (%d), but flips replacing a pipe (%d)" % [kept_blocked, kept_same, flipped_replace])
	# Dragging pipe-to-ground leaves held dir opposite the last placed piece.
	wipe.call()
	pred.reset()
	sent()
	input.build_dir = 0
	input.drag.begin("pipe-to-ground", ptg, Vector2(2.5, 14.5), false)
	input.drag.update(Vector2(3.5, 14.5))
	input.drag.end()
	var dir_after_entrance: int = input.build_dir
	input.build_dir = 0
	input.drag.begin("pipe-to-ground", ptg, Vector2(2.5, 16.5), false)
	for x in range(3, 13):
		input.drag.update(Vector2(x + 0.5, 16.5))
	input.drag.end()
	var dir_after_exit: int = input.build_dir
	check(dir_after_entrance == 4 and dir_after_exit == 12,
		"dragging pipe-to-ground flips held dir opposite last placed piece (entrance->%d, exit->%d)" % [dir_after_entrance, dir_after_exit])
	# Underground-belt ghost click immediately flips preview (build_extra) to exit on frame 0 while keeping flow dir.
	wipe.call()
	pred.reset()
	sent()
	input.cursor_item = "underground-belt"
	input.build_dir = 8
	input.drag.begin("underground-belt", under, Vector2(12.5, 2.5), true)
	input.drag.end()
	var ug_ghost_extra := input.build_extra(under, Vector2(12.5, 5.5), 8)
	var ug_turn_out := ModelLibrary.turn_dir("underground-belt", 8, ug_ghost_extra)
	input.drag.begin("underground-belt", under, Vector2(12.5, 5.5), true)
	input.drag.end()
	var ug_after_exit := input.build_extra(under, Vector2(12.5, 7.5), 8)
	check(input.build_dir == 8 and ug_ghost_extra == {"u": "o"} and ug_turn_out == 0 and ug_after_exit == {"u": "i"},
		"ghost underground-belt flips preview to exit on frame 0 (%s, turn=%d) and returns to entrance past exit (%s)" % [ug_ghost_extra, ug_turn_out, ug_after_exit])
	sent()
	input.build_dir = 4
	# --underground-clear-sent=off: only what the world has counts, as before: the run waits for the game's `mnd`.
	wipe.call()
	pred.reset()
	input.cursor_item = "underground-belt"
	line.clear()
	for x in [2.5, 3.5, 4.5, 5.5, 6.5, 7.5]:
		line.append(put.call(1, x, 5.5, 4, {"s": "s"}))
	UndergroundPairs.sent_on = false
	input.drag.begin("underground-belt", under, Vector2(2.5, 5.5), false)
	for x in [3.5, 4.5, 5.5, 6.5, 7.5]:
		input.drag.update(Vector2(x, 5.5))
	input.drag.end()
	UndergroundPairs.sent_on = true
	check(sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "build").size() == 2
		and line.all(func(r: WorldMirror.Rec) -> bool: return not r.extra.has("hid")),
		"M2: --underground-clear-sent=off: a drag's pair hides nothing ahead, as before")
	wipe.call()
	pred.reset()
	run = lay.call(5.5)
	# --underground-clear=off: no marks, nothing hidden.
	UndergroundPairs.clear_on = false
	var off_marks: Array = kinds.call(UndergroundPairs.held_marks(world, under, held, 4, 5))
	input.drag.begin("underground-belt", under, held, false)
	input.drag.end()
	UndergroundPairs.clear_on = true
	check(off_marks.all(func(k: Array) -> bool: return k[1] == "tunnel") and run.all(func(r: WorldMirror.Rec) -> bool: return not r.extra.has("hid")),
		"M2: --underground-clear=off: the connection as before, nothing hidden: %s" % [off_marks])
	sent()
	m.main_slots = had
	m.counts = had_counts
	m.has_slots = had_slots
	m.eprops = had_eprops
	input.free()
	pred.queue_free()


func _build_spend(hud: Hud) -> void:
	var m: UiModel = hud.ui.model
	var world := WorldMirror.new()
	world.pick_build_usec = 1 << 40  # the whole pick index at once (see _predictions)
	world.protos.add_entities([[1, "wooden-chest", "container", -0.35, -0.35, 0.35, 0.35, 120, 90, 60, 1, 1]])
	world.protos.item_places = {"wooden-chest": "wooden-chest"}
	world.chunks[Vector2i.ZERO] = ChunkView.new()
	var until_models := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < until_models and not ModelLibrary.entity_ready("wooden-chest", "container", {}, 0):
		ModelLibrary.poll()
		await get_tree().process_frame
	var chest: ProtoDB.EntityProto = world.protos.entity(1)
	var pred := Predicted.new()
	pred.world = world
	add_child(pred)
	var input := PlayerInput.new()
	input.world = world
	input.hud = hud
	input.predicted = pred
	input.drag.pi = input
	m.inventory_changed.connect(pred.inventory_heard)
	var had: Array = m.main_slots
	var had_slots := m.has_slots
	var had_counts: Dictionary = m.counts.duplicate()
	var tick0 := Bridge.server_tick
	var unit := [900]
	# The game: builds the first `stock` sent (each two drag steps after it was sent), refuses the rest.
	var answer := func(upto: int, stock: int) -> void:
		var builds: Array = input.drag.sent
		for i in mini(upto, mini(builds.size(), stock)):
			var c: Dictionary = builds[i]
			if c.get("done", false):
				continue
			c["done"] = true
			unit[0] += 1
			var e := [unit[0], 1, int(c["x"]), int(c["y"]), 0]
			pred.heard_add(e)
			world._add(e)
		pred._on_entities_changed(Vector2i.ZERO)
	var drag := func(stock: int, tiles: int, report_at := -1, report_count := 0) -> void:
		Bridge.server_tick = tick0
		input.drag.begin("wooden-chest", chest, Vector2(0.5, 0.5), false)
		for x in range(1, tiles):
			input.drag.update(Vector2(x + 0.5, 0.5))
			answer.call(input.drag.sent.size() - 2, stock)
			if x == report_at:
				m.handle({"t": "slots", "l": {"main": [["wooden-chest", report_count]]}})
		input.drag.end()
	var reset := func(count: int) -> void:
		pred.reset()
		for c in world.chunks[Vector2i.ZERO].entities.keys():
			world._remove(c)
		m.handle({"t": "slots", "l": {"main": [["wooden-chest", count]]}})
		sent()
	# The video: 6 in hand, a drag 20 tiles long.
	reset.call(6)
	drag.call(6, 20)
	var real_sent: int = input.drag.sent.size()
	var drawn := pred.count()
	var left_during := input.items_left("wooden-chest")
	answer.call(99, 6)
	m.handle({"t": "slots", "l": {"main": [["wooden-chest", 0]]}})
	check(real_sent == 6 and drawn == 6 and left_during == 0 and pred.unpaid("wooden-chest") == 0 and input.items_left("wooden-chest") == 0,
		"L2: a drag with 6 in hand sends and shows 6 and stops, the game answering before its inventory report (sent %d, shown %d)" % [real_sent, drawn])
	# A report in the middle of the drag (after 5 sent and 3 built: 7 of 10 left): the 3 built are paid
	# for, the 2 in flight still count, and the drag goes on to 10, no further.
	reset.call(10)
	drag.call(10, 20, 4, 7)
	check(input.drag.sent.size() == 10 and pred.count() == 10,
		"L2: an inventory report during a drag pays for what was built and the drag builds all 10 (sent %d, shown %d)" % [input.drag.sent.size(), pred.count()])
	# A build the game refuses spends nothing once the game has moved on; a built one waits for the
	# inventory, then is paid; none outlives GIVE_UP_MSEC.
	reset.call(5)
	Bridge.server_tick = tick0
	input.drag.begin("wooden-chest", chest, Vector2(30.5, 0.5), false)
	input.drag.end()
	var one_spent := input.items_left("wooden-chest") == 4
	Bridge.server_tick = tick0 + Predicted.REFUSED_TICKS
	pred._spends[0].msec -= Predicted.REFUSED_MSEC
	pred._process(0.0)
	var refunded := input.items_left("wooden-chest") == 5
	input.drag.begin("wooden-chest", chest, Vector2(31.5, 0.5), false)
	input.drag.end()
	pred.heard_add([unit[0] + 50, 1, 31 * 256 + 128, 128, 0])
	pred._spends[0].msec -= Predicted.REFUSED_MSEC
	pred._process(0.0)
	var built_waits := input.items_left("wooden-chest") == 4
	pred._spends[0].msec -= Predicted.GIVE_UP_MSEC
	pred._process(0.0)
	check(one_spent and refunded and built_waits and pred.unpaid("wooden-chest") == 0,
		"L2: a refused build gives its item back to what is left; a built one waits for the inventory (or gives up after %d ms)" % Predicted.GIVE_UP_MSEC)
	# Over the same chest already standing there the game turns it: nothing spent.
	reset.call(3)
	world._add([unit[0] + 60, 1, 25 * 256 + 128, 4 * 256 + 128, 0])
	input.drag.begin("wooden-chest", chest, Vector2(25.5, 4.5), false)
	input.drag.end()
	check(input.drag.sent.size() == 1 and pred.unpaid("wooden-chest") == 0, "L2: building over the same building (the game turns it) spends nothing")
	# The count at the cursor counts down with what was sent (factorio_ui.gd cursor_count).
	reset.call(6)
	var stub := GDScript.new()
	stub.source_code = "extends Node\nvar cursor_item := \"wooden-chest\"\nvar cursor_slot := 0\nvar cursor_tool := \"\"\nvar predicted\n"
	stub.reload()
	var holder: Node = stub.new()
	holder.predicted = pred
	var player_was = hud.ui.player
	var hand_was: Dictionary = hud.ui.hand
	hud.ui.player = holder
	hud.ui.hand = {}
	Bridge.server_tick = tick0
	input.drag.begin("wooden-chest", chest, Vector2(10.5, 8.5), false)
	for x in range(11, 14):
		input.drag.update(Vector2(x + 0.5, 8.5))
	input.drag.end()
	var counted: int = hud.ui.cursor_count()
	hud.ui.player = player_was
	hud.ui.hand = hand_was
	holder.free()
	check(counted == 2, "L2: the count at the cursor counts down as the drag builds (6 held, 4 sent: %d)" % counted)
	# --build-spend=off: the drag as before, the bug.
	reset.call(6)
	Predicted.spend_fix = false
	drag.call(6, 20)
	var old_sent: int = input.drag.sent.size()
	var old_drawn := pred.count()
	Predicted.spend_fix = true
	check(old_sent > 6 and old_drawn > 6, "L2: --build-spend=off sends and shows past the 6 held (sent %d, shown %d)" % [old_sent, old_drawn])
	# A drag begun just past the cursor's reach, where the bridge still builds (its reach is to the
	# building's middle, plus 1.5): the first build has a red preview and no prediction, but the
	# game takes its item, so it is spent and the drag stops at the 6 held (seen in a window: 7).
	var body := Avatar.new()
	body.position = Vector3(0.5, 0.0, 0.5)
	input.avatar = body
	var edge_drag := func() -> int:
		reset.call(6)
		Bridge.server_tick = tick0
		input.drag.begin("wooden-chest", chest, Vector2(-8.5, -6.5), false)
		for x in range(-7, 9):
			input.drag.update(Vector2(x + 0.5, -6.5))
			answer.call(input.drag.sent.size() - 2, 6)
		input.drag.end()
		return input.drag.sent.size()
	var red_first: bool = not input._in_reach(Vector2(-8.5, -6.5), Vector2i.ONE) and input._bridge_reach(Vector2(-8.5, -6.5))
	var edge_sent: int = edge_drag.call()
	Predicted.spend_bridge_reach = false
	var edge_old: int = edge_drag.call()
	Predicted.spend_bridge_reach = true
	check(red_first and edge_sent == 6 and edge_old == 7,
		"L2: a drag begun at the edge of reach, where the bridge still builds, stops at the 6 held (sent %d; --build-spend-reach=cursor: %d)" % [edge_sent, edge_old])
	input.avatar = null
	body.free()
	m.inventory_changed.disconnect(pred.inventory_heard)
	Bridge.server_tick = tick0
	sent()
	m.main_slots = had
	m.counts = had_counts
	m.has_slots = had_slots
	input.free()
	pred.queue_free()


## K21: a building Factorio can't turn (a furnace, a chest), turned with R in the build cursor,
## stands turned once placed. The game puts it down facing north whatever was sent; its `add` takes
## the cursor's turn as a look-only one (visual_turns.gd), kept for the save, so it stays turned. A
## drag turns every one it places; one the game turns itself only sends its direction.


func _turned_previews(hud: Hud) -> void:
	var m: UiModel = hud.ui.model
	var world := WorldMirror.new()
	world.pick_build_usec = 1 << 40  # the whole pick index at once (see _predictions)
	world.protos.add_entities([
		[2, "stone-furnace", "furnace", -0.9, -0.9, 0.9, 0.9, 120, 120, 120, 2, 2],
		[4, "inserter", "inserter", -0.15, -0.15, 0.15, 0.15, 200, 180, 0, 1, 1],
		[6, "assembling-machine-2", "assembling-machine", -1.4, -1.4, 1.4, 1.4, 150, 150, 160, 3, 3],
		[7, "assembling-machine-1", "assembling-machine", -1.4, -1.4, 1.4, 1.4, 150, 150, 160, 3, 3],
	])
	world.protos.item_places = {"stone-furnace": "stone-furnace", "inserter": "inserter",
		"assembling-machine-2": "assembling-machine-2", "assembling-machine-1": "assembling-machine-1"}
	world.chunks[Vector2i.ZERO] = ChunkView.new()
	# The prediction of a turned assembler is drawn only once its model is made (predicted.gd).
	var until_models := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < until_models and not (ModelLibrary.entity_ready("assembling-machine-1", "assembling-machine", {}, 4)
			and ModelLibrary.entity_ready("stone-furnace", "furnace", {}, 4)):
		ModelLibrary.poll()
		await get_tree().process_frame
	var pred := Predicted.new()
	pred.world = world
	add_child(pred)
	var input := PlayerInput.new()
	input.world = world
	input.hud = hud
	input.predicted = pred
	input.drag.pi = input
	input.tile_brush.pi = input
	input.hovered = null
	var had: Array = m.main_slots
	var had_slots := m.has_slots
	var had_counts: Dictionary = m.counts.duplicate()
	var had_am2: Variant = m.eprops.get(6)
	m.eprops[6] = {"under": 0.0, "wire": 0.0, "supply": 0.0, "x": {"fb": [[0, -2, 0, "i"]]}}  # fluid boxes: Factorio turns it
	m.handle({"t": "slots", "l": {"main": [["stone-furnace", 10], ["inserter", 2], ["assembling-machine-2", 2], ["assembling-machine-1", 2]]}})
	var sid: String = Bridge.save_id
	var units := [301, 311, 312, 313, 314, 321, 331, 341, 351]
	for u in units:
		VisualTurns.forget(sid, u)
	VisualTurns._expected.clear()
	var furnace: ProtoDB.EntityProto = world.protos.entity(2)
	var yaw_of := func(r: WorldMirror.Rec) -> Basis:
		var p: ProtoDB.EntityProto = world.protos.entity(r.proto_id)
		return ModelLibrary.placed(p.name, p.type, r.dir, r.extra, Vector3(r.pos.x, 0.0, r.pos.y)).basis
	var builds := func() -> Array:
		return sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "build")

	# Hold a stone furnace, R once, place it: the game's `add` comes back facing north.
	input.cursor_item = "stone-furnace"
	input.build_dir = 0
	sent()
	input._rotate(false)
	check(input.build_dir == 4, "K21: R turns the held furnace's preview a quarter")
	input.drag.begin("stone-furnace", furnace, Vector2(10.2, 10.7), false)
	input.drag.end()
	var one: Array = builds.call()
	check(one.size() == 1 and int(one[0].get("d", -1)) == 4 and VisualTurns.expecting(),
		"K21: the furnace is sent turned and waits for its building: %s" % [one])
	check(pred.count() == 1 and pred._pending[0].dir == 4, "K21: its prediction is drawn turned")
	world.handle({"t": "add", "e": [301, 2, 10 * 256, 11 * 256, 0]})
	var placed: WorldMirror.Rec = world.entities.get(301)
	check(placed != null and placed.dir == 4 and (yaw_of.call(placed) as Basis).is_equal_approx(Basis(Vector3.UP, -TAU / 4.0))
		and VisualTurns.quarters(sid, 301) == 1 and not VisualTurns.expecting(),
		"K21: the furnace the game put down unturned is drawn a quarter turned, as the preview was, its look-only turn kept")
	world._add([301, 2, 10 * 256, 11 * 256, 0])  # the chunk sent again, or after a restart
	var cfg := ConfigFile.new()
	cfg.load(VisualTurns.PATH)
	check((world.entities[301] as WorldMirror.Rec).dir == 4 and int(cfg.get_value(sid if sid != "" else "unnamed", "301", 0)) == 1,
		"K21: it stays turned when the game sends it again, and the turn is in the save's file for the next start")

	# A drag places a row: every one turned.
	input.drag.begin("stone-furnace", furnace, Vector2(14.0, 24.0), false)
	input.drag.update(Vector2(20.0, 24.0))
	input.drag.end()
	var row: Array = builds.call()
	check(row.size() == 4 and row.all(func(c: Dictionary) -> bool: return int(c.get("d", -1)) == 4),
		"K21: a drag sends every furnace turned: %s" % [row])
	for i in 4:
		world.handle({"t": "add", "e": [314 - i, 2, (20 - 2 * i) * 256, 24 * 256, 0]})  # answered in any order
	var row_turned := 0
	for u in [311, 312, 313, 314]:
		var r: WorldMirror.Rec = world.entities.get(u)
		if r != null and r.dir == 4 and VisualTurns.quarters(sid, u) == 1:
			row_turned += 1
	check(row_turned == 4, "K21: each furnace of the drag stands turned once its `add` comes (%d of 4)" % row_turned)

	# Shift+R the other way round: three quarters.
	input._rotate(true)
	input._rotate(true)
	check(input.build_dir == 12, "Shift+R turns the preview back")
	input.drag.begin("stone-furnace", furnace, Vector2(4.0, 28.0), false)
	input.drag.end()
	builds.call()
	world.handle({"t": "add", "e": [321, 2, 4 * 256, 28 * 256, 0]})
	check((world.entities[321] as WorldMirror.Rec).dir == 12 and VisualTurns.quarters(sid, 321) == 3,
		"K21: turned back once, it is placed turned back (three quarters)")

	# An assembler without fluid boxes can't turn either: its prediction keeps the turn (a turnable
	# one is drawn north until it has a recipe), and so does the building.
	input.cursor_item = "assembling-machine-1"
	input.build_dir = 4
	input.drag.begin("assembling-machine-1", world.protos.entity(7), Vector2(26.5, 4.5), false)
	input.drag.end()
	builds.call()
	var am1 := pred._pending.filter(func(p) -> bool: return p.proto.id == 7)
	check(am1.size() == 1 and am1[0].dir == 4, "K21: an assembler Factorio can't turn is predicted turned")
	world.handle({"t": "add", "e": [331, 7, 26 * 256 + 128, 4 * 256 + 128, 0]})
	check((world.entities[331] as WorldMirror.Rec).dir == 4 and VisualTurns.quarters(sid, 331) == 1, "K21: and placed turned")

	# What Factorio turns itself gets its direction from the game, with no look-only turn.
	input.cursor_item = "inserter"
	input.build_dir = 4
	input.drag.begin("inserter", world.protos.entity(4), Vector2(28.5, 12.5), false)
	input.drag.end()
	var ins: Array = builds.call()
	check(ins.size() == 1 and int(ins[0].get("d", -1)) == 4 and not VisualTurns.expecting(), "an inserter is sent turned; nothing waits for it")
	world.handle({"t": "add", "e": [341, 4, 28 * 256 + 128, 12 * 256 + 128, 4]})
	check((world.entities[341] as WorldMirror.Rec).dir == 4 and VisualTurns.quarters(sid, 341) == 0, "the game's own turn, nothing added")
	input.cursor_item = "assembling-machine-2"
	input.drag.begin("assembling-machine-2", world.protos.entity(6), Vector2(26.5, 18.5), false)
	input.drag.end()
	builds.call()
	check(not VisualTurns.expecting(), "an assembler with fluid boxes (Factorio turns it) gets no look-only turn")
	# Ghosts are the game's: none waits. A build the game refused long ago doesn't turn one put there later.
	input.cursor_item = "stone-furnace"
	input.drag.begin("stone-furnace", furnace, Vector2(4.0, 4.0), true)
	input.drag.end()
	check(not VisualTurns.expecting(), "a ghost turned in the cursor waits for nothing")
	input.drag.begin("stone-furnace", furnace, Vector2(10.0, 30.0), false)
	input.drag.end()
	builds.call()
	check(VisualTurns._expected.size() == 1, "the furnace sent turned waits for its building")
	if not VisualTurns._expected.is_empty():
		VisualTurns._expected[0][3] = int(VisualTurns._expected[0][3]) - VisualTurns.EXPECT_MSEC - 1
	world.handle({"t": "add", "e": [351, 2, 10 * 256, 30 * 256, 0]})
	check((world.entities[351] as WorldMirror.Rec).dir == 0 and not VisualTurns.expecting(), "a build long refused turns nothing later")

	for u in units:
		VisualTurns.forget(sid, u)
	VisualTurns._expected.clear()
	if had_am2 == null:
		m.eprops.erase(6)
	else:
		m.eprops[6] = had_am2
	input.cursor_item = ""
	sent()
	m.main_slots = had
	m.counts = had_counts
	m.has_slots = had_slots
	input.free()
	pred.queue_free()


## Factorio's marks in the world: the build cursor's model ghost (its model, end and way, red where
## something's in the way) and belt arrows, hover marks (selection corners, inserter arrows, fluid
## connections, a drill's area and output), roboport areas, Alt-mode with no recipe, and clicking
## anywhere on a train.


func _world_marks(hud: Hud) -> void:
	var m: UiModel = hud.ui.model
	var world := WorldMirror.new()
	world.pick_build_usec = 1 << 40  # the whole pick index at once (see _predictions)
	world.protos.add_entities([
		[1, "transport-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[2, "underground-belt", "underground-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[3, "long-handed-inserter", "inserter", -0.5, -0.5, 0.5, 0.5, 200, 60, 60, 1, 1],
		[4, "roboport", "roboport", -2, -2, 2, 2, 120, 120, 120, 4, 4],
		[5, "electric-mining-drill", "mining-drill", -1.5, -1.5, 1.5, 1.5, 120, 120, 120, 3, 3],
		[6, "steam-engine", "generator", -1.5, -2.5, 1.5, 2.5, 120, 120, 120, 3, 5],
		[7, "locomotive", "locomotive", -1, -3, 1, 3, 120, 120, 120, 2, 6],
		[8, "assembling-machine-2", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 120, 120, 120, 3, 3],
		[9, "pipe-to-ground", "pipe-to-ground", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1],
	])
	m.handle({"t": "eprops", "l": [[2, 5, 0, 0], [3, 0, 0, 0, {"ip": [0, -2], "id": [0, 2.2]}], [4, 0, 0, 0, {"lr": 25, "cr": 55}],
		[5, 0, 0, 0, {"mr": 2.49, "vp": [0, -1.85], "fb": [[-1, 0, 12, "b"]], "fo": 1}],
		[6, 0, 0, 0, {"fb": [[0, 2, 8, "b"], [0, -2, 0, "b"]]}], [8, 0, 0, 0, {"fb": [[0, -1, 0, "i"], [0, 1, 8, "o"]], "fo": 1}]]})
	check(m.eprops[3]["x"].get("ip") == [0, -2] and m.eprops[2]["x"].is_empty(), "eprops' overlay is kept")
	world.chunks[Vector2i.ZERO] = ChunkView.new()
	var input := PlayerInput.new()
	input.world = world
	input.hud = hud

	# --- the build cursor: model, end, way, arrows ------------------------------------------------
	var belt: ProtoDB.EntityProto = world.protos.entity(1)
	check(ModelLibrary.mesh_for_entity("transport-belt", "transport-belt", input.build_extra(belt, Vector2(3.5, 3.5), 4), 4) != null,
		"a held belt is drawn as its model")
	var belt_marks := CursorOverlay.marks_for("transport-belt", {}, Vector2(3.5, 3.5), 4, true)
	check(belt_marks.size() == 1 and belt_marks[0]["dir"].is_equal_approx(Vector2(1, 0)), "a belt being placed east shows an arrow east")
	check(CursorOverlay.marks_for("transport-belt", {}, Vector2(3.5, 3.5), 4, false).is_empty(), "but not when hovered")
	var under: ProtoDB.EntityProto = world.protos.entity(2)
	check(input.build_extra(under, Vector2(10.5, 5.5), 4) == {"u": "i"}, "an underground with nothing behind it is an entrance")
	world._add([50, 2, 7 * 256 + 128, 5 * 256 + 128, 4, {"u": "i"}])
	check(input.build_extra(under, Vector2(10.5, 5.5), 4) == {"u": "o"}, "one ahead of an entrance facing the same way is its exit")
	check(input.build_extra(under, Vector2(10.5, 5.5), 12) == {"u": "i"}, "facing the other way it is an entrance")
	check(input.build_extra(under, Vector2(14.5, 5.5), 4) == {"u": "i"}, "out of reach it is an entrance")
	# J24: held, it shows Factorio's underground connection to the entrance it would join (its
	# underground_sprite on the tiles between) and, green, the furthest its exit may go; past that the
	# connection is red, too far; with nothing to join, the furthest its exit could go from it.
	var tunnel_of := func(marks: Array) -> Array:
		return marks.filter(func(k: Dictionary) -> bool: return k["k"] == "tunnel").map(
			func(k: Dictionary) -> Array: return [int(floorf((k["at"] as Vector2).x)), "g" if k["c"] == UndergroundPairs.MAX_REACH
				else ("r" if k["c"] == UndergroundPairs.TOO_FAR else "y")])
	var near_marks: Array = tunnel_of.call(UndergroundPairs.held_marks(world, under, Vector2(10.5, 5.5), 4, 5))
	var far_marks: Array = tunnel_of.call(UndergroundPairs.held_marks(world, under, Vector2(14.5, 5.5), 4, 5))
	var lone_marks: Array = tunnel_of.call(UndergroundPairs.held_marks(world, under, Vector2(10.5, 5.5), 12, 5))
	check(near_marks == [[8, "y"], [9, "y"], [12, "g"]] and far_marks == [[8, "r"], [9, "r"], [10, "r"], [11, "r"], [13, "r"], [12, "g"]]
		and lone_marks == [[5, "g"]],
		"J24: a held underground's connection, yellow in reach, red past it, its furthest exit green: %s %s %s" % [near_marks, far_marks, lone_marks])
	var ptg: ProtoDB.EntityProto = world.protos.entity(9)
	world._add([51, 9, 20 * 256 + 128, 9 * 256 + 128, 12])  # a pipe-to-ground connected back (west)
	var pipe_marks: Array = UndergroundPairs.held_marks(world, ptg, Vector2(24.5, 9.5), 4, 10)
	check(pipe_marks.size() == 4 and pipe_marks.all(func(k: Dictionary) -> bool: return not bool(k["arrow"]))
		and UndergroundPairs.held_join(world, ptg, Vector2(24.5, 9.5), 4, 10).get("k") == 4,
		"J24: a pipe-to-ground facing on from one facing back joins it (no arrows, as Factorio draws pipes): %s" % [pipe_marks])
	world._remove(51)
	var tunnel_overlay := CursorOverlay.new()
	tunnel_overlay.show_marks(UndergroundPairs.held_marks(world, under, Vector2(14.5, 5.5), 4, 5))
	# Each tile: 4 dashes and the arrow's 3 edges, 2 triangles each.
	check(tunnel_overlay._mesh.get_surface_count() == 1 and (tunnel_overlay._mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() == 6 * 7 * 6,
		"J24: the overlay draws each tunnel tile's dashes and arrow")
	tunnel_overlay.free()
	check(ModelLibrary.turn_dir("underground-belt", 4, {"u": "o"}) == 12 and ModelLibrary.turn_dir("underground-belt", 4, {"u": "i"}) == 4,
		"an exit's model is turned round (its direction is the way items go, its model faces its entrance)")
	check(ModelLibrary.turn_dir("furnace", 8, {}, "crusher") == 0 and ModelLibrary.turn_dir("furnace", 12, {}, "crusher") == 0
		and ModelLibrary.model_name("crusher", "furnace", {}, 8) == "crusher"
		and ModelLibrary.model_name("crusher", "furnace", {}, 4) == "crusher-east"
		and ModelLibrary.model_name("crusher", "furnace", {}, 12) == "crusher-east",
		"a crusher facing south looks like facing north, west like east: a model per picture, unturned")
	check(ModelLibrary.turn_dir("assembling-machine", 12, {}, "foundry") == 0, "a foundry looks the same every way round")
	# The burner drill's stand never turns in Factorio: a model per direction, drawn unturned, with
	# its auger, gears and rod moving while it works.
	var drill_kinds := {}
	for part: ModelLibrary.AnimPart in ModelLibrary.parts_for_entity("burner-mining-drill", "mining-drill", {}, 4):
		drill_kinds[part.kind] = true
	check(ModelLibrary.model_name("burner-mining-drill", "mining-drill", {}, 4) == "burner-mining-drill-east"
		and ModelLibrary.model_name("burner-mining-drill", "mining-drill", {}, 12) == "burner-mining-drill-west"
		and ModelLibrary.model_name("burner-mining-drill", "mining-drill", {}, 0) == "burner-mining-drill"
		and ModelLibrary.turn_dir("mining-drill", 8, {}, "burner-mining-drill") == 0
		and ModelLibrary.mesh_for_entity("burner-mining-drill", "mining-drill", {}, 8) != ModelLibrary.mesh_for("burner-mining-drill")
		and drill_kinds.has("spin_drill") and drill_kinds.has("gear_bmd_ns") and drill_kinds.has("gear_bmd_r_ew")
		and drill_kinds.has("slide_bmd_rod"),
		"the burner drill: a model per direction, unturned, its auger, gears and rod moving: %s" % [drill_kinds.keys()])
	# Steam power: Factorio renders each direction on its own, so Zenith's own models are one per
	# direction, unturned; the steam engine has one per axis, its east-west flywheel turning about
	# north-south. (FUE5's boiler and engine are one model turned: model_textures_test.gd.)
	var steam_models: Array[String] = ["boiler", "boiler-east", "boiler-south", "boiler-west", "steam-engine", "steam-engine-east"]
	_ours(steam_models)
	var engine_kinds := {}
	for part: ModelLibrary.AnimPart in ModelLibrary.parts_for_entity("steam-engine", "generator", {}, 12):
		engine_kinds[part.kind] = part.axis
	var pump_slides := []
	for part: ModelLibrary.AnimPart in ModelLibrary.parts_for_entity("offshore-pump", "offshore-pump", {}, 4):
		pump_slides.append(part.slide)
	check(ModelLibrary.model_name("boiler", "boiler", {}, 8) == "boiler-south"
		and ModelLibrary.model_name("steam-engine", "generator", {}, 8) == "steam-engine"
		and ModelLibrary.model_name("steam-engine", "generator", {}, 12) == "steam-engine-east"
		and ModelLibrary.turn_dir("generator", 12, {}, "steam-engine") == 0
		and ModelLibrary.turn_dir("offshore-pump", 4, {}, "offshore-pump") == 0
		and ModelLibrary.mesh_for_entity("boiler", "boiler", {}, 4) != ModelLibrary.mesh_for("boiler")
		and ModelLibrary.mesh_for_entity("burner-generator", "burner-generator", {}, 4) == ModelLibrary.mesh_for("steam-engine-east")
		and engine_kinds.get("spin_flywheel_ns", Vector3.ZERO) == Vector3.BACK
		and pump_slides.size() == 2 and pump_slides[0] == Vector3(0.16, 0.0, 0.0),
		"steam power: a model per direction, unturned, flywheel and pistons moving their way: %s %s" % [engine_kinds, pump_slides])
	_restore_models(steam_models)
	# FUE5's pack (above Placeholders) has one pipe-to-ground, turned to each direction (single_model):
	# its above-ground end reaches the tile edge the entity faces, as Factorio's pipe connection does.
	if _theirs_in_use("pipe-to-ground"):
		var ptg_mesh := ModelLibrary.mesh_for("pipe-to-ground")
		var ptg_faces := []
		for dir in [0, 4, 8, 12]:
			var turned := ModelLibrary.placed("pipe-to-ground", "pipe-to-ground", dir, {}, Vector3.ZERO) * ptg_mesh.get_aabb()
			var to := Vector2(turned.end.x, turned.end.z)
			var from := Vector2(turned.position.x, turned.position.z)
			# The edge it reaches (0.45 or more out) on the facing side only.
			ptg_faces.append([from.y <= -0.45, to.x >= 0.45, to.y >= 0.45, from.x <= -0.45])
		check(ModelLibrary.single_model("pipe-to-ground")
			and ModelLibrary.model_name("pipe-to-ground", "pipe-to-ground", {}, 4) == "pipe-to-ground"
			and ModelLibrary.turn_dir("pipe-to-ground", 12, {}, "pipe-to-ground") == 12
			and ptg_faces == [[true, false, false, false], [false, true, false, false], [false, false, true, false], [false, false, false, true]],
			"FUE5's pipe-to-ground: one model turned to each direction, its pipe end on the side it faces: %s" % [ptg_faces])
	# The valves (no FUE5 model) are drawn from Placeholders.
	for valve in ["one-way-valve", "overflow-valve", "top-up-valve"]:
		check(not _theirs_in_use(valve) and not _theirs_in_use(valve + "-south"), "%s: Placeholders' models" % valve)
	# Placeholders' pipe-to-ground pictures and the valves' plates aren't turned copies: a model each
	# way round.
	var ptg_models: Array[String] = ["pipe-to-ground", "pipe-to-ground-east", "pipe-to-ground-south", "pipe-to-ground-west"]
	_ours(ptg_models)
	check(ModelLibrary.model_name("pipe-to-ground", "pipe-to-ground", {}, 4) == "pipe-to-ground-east"
		and ModelLibrary.model_name("pipe-to-ground", "pipe-to-ground", {}, 0) == "pipe-to-ground"
		and ModelLibrary.turn_dir("pipe-to-ground", 12, {}, "pipe-to-ground") == 0
		and ModelLibrary.model_name("overflow-valve", "valve", {}, 8) == "overflow-valve-south"
		and ModelLibrary.turn_dir("valve", 8, {}, "overflow-valve") == 0,
		"pipe-to-ground (Placeholders) and valves: a model per direction, unturned")
	_restore_models(ptg_models)
	# Cargo bays frame the cargo area with Factorio's connection tileset, per 2x2 cell: a lone
	# cell's corner, a wall where a neighbour joins beside it, inner corners, nothing inside.
	check(ModelLibrary.cargo_pieces(56) == ["cargo-bay-corner-nw"] and ModelLibrary.cargo_pieces(248) == ["cargo-bay-wall-n"]
		and ModelLibrary.cargo_pieces(250) == ["cargo-bay-inner-nw", "cargo-bay-inner-ne"]
		and ModelLibrary.cargo_pieces(42) == ["cargo-bay-wall-w", "cargo-bay-inner-ne", "cargo-bay-inner-se"]
		and ModelLibrary.cargo_pieces(255).is_empty(), "cargo bays: the connection pieces follow Factorio's tileset")
	var cw := WorldMirror.new()
	cw.protos.add_entities([[1, "space-platform-hub", "space-platform-hub", -4, -4, 4, 4, 120, 120, 120, 8, 8],
		[2, "cargo-bay", "cargo-bay", -2, -2, 2, 2, 120, 120, 120, 4, 4]])
	for c in [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(-1, -1)]:
		cw.chunks[c] = ChunkView.new()
	cw._add([1, 2, 30 * 256, 20 * 256, 0])  # a lone bay: a corner in each cell
	var lone_cb := int(cw.entities[1].extra.get("cb", -1))
	cw._add([2, 1, 0, 0, 0])  # the hub, and two bays north of it: one in line, one half past its corner
	cw._add([3, 2, 0, -6 * 256, 0])
	cw._add([4, 2, 4 * 256, -6 * 256, 0])
	var cells := func(key) -> Array:
		var cb := int(cw.entities[key].extra.get("cb", -1))
		return [0, 1, 2, 3].map(func(k): return ModelLibrary.cargo_pieces((cb >> (8 * k)) & 255))
	var in_line: Array = cells.call(3)
	var past: Array = cells.call(4)
	check(lone_cb >= 0 and ModelLibrary.cargo_pieces(lone_cb & 255) == ["cargo-bay-corner-nw"]
		and ModelLibrary.cargo_pieces((lone_cb >> 24) & 255) == ["cargo-bay-corner-se"]
		and in_line == [["cargo-bay-corner-nw"], ["cargo-bay-wall-n"], ["cargo-bay-wall-w"], []]
		and past == [["cargo-bay-wall-n"], ["cargo-bay-corner-ne"], ["cargo-bay-inner-se"], ["cargo-bay-corner-se"]],
		"cargo bays: framed alone, joined to the hub and each other with no wall between: %s %s" % [in_line, past])
	cw._remove(3)
	check(cells.call(4)[0] == ["cargo-bay-corner-nw"], "cargo bays: a bay taken away opens its neighbour's side again")
	# Ghost bays (and the held bay's preview) are framed as they will be: joined to the hub and to
	# each other, while a built bay's frame doesn't open for a ghost beside it.
	cw.protos.add_entities([[3, "entity-ghost", "entity-ghost", -2, -2, 2, 2, 120, 120, 120, 4, 4]])
	var bay_proto: ProtoDB.EntityProto = cw.protos.entity(2)
	var before_ghost := int(cw.entities[4].extra.get("cb", -1))
	cw._add([5, 3, -6 * 256, -2 * 256, 0, {"gh": 2}])  # west of the hub
	cw._add([6, 3, -10 * 256, -2 * 256, 0, {"gh": 2}])  # west of that ghost
	cw._add([7, 3, 8 * 256, -6 * 256, 0, {"gh": 2}])  # east of the built bay 4
	var ghost_cells := func(x: float, y: float) -> Array:
		var cb := cw.cargo_mask(WorldMirror.cargo_rect(bay_proto, Vector2(x, y)), true)
		return [0, 1, 2, 3].map(func(k): return ModelLibrary.cargo_pieces((cb >> (8 * k)) & 255))
	var lone_ghost: Array = ghost_cells.call(30.0, 40.0)
	var by_hub: Array = ghost_cells.call(-6.0, -2.0)
	check(lone_ghost == [["cargo-bay-corner-nw"], ["cargo-bay-corner-ne"], ["cargo-bay-corner-sw"], ["cargo-bay-corner-se"]]
		and by_hub == [["cargo-bay-wall-n"], ["cargo-bay-wall-n"], ["cargo-bay-wall-s"], ["cargo-bay-wall-s"]]
		and int(cw.entities[4].extra.get("cb", -1)) == before_ghost
		and ModelLibrary.cargo_places(cw.cargo_mask(WorldMirror.cargo_rect(bay_proto, Vector2(30, 40))), Vector3(30, 0, 40))[3]
			== ["cargo-bay-corner-se", Vector3(31, 0, 41)],
		"cargo bays: a ghost is framed to its 4x4, joined to the hub and other ghosts, built bays unmoved: %s %s" % [lone_ghost, by_hub])
	cw._remove(6)
	check(ghost_cells.call(-6.0, -2.0)[0] == ["cargo-bay-corner-nw"], "cargo bays: a ghost taken away opens its neighbour ghost's side")
	cw.free()
	# Records leaving with their chunk (unloaded, or resent without them) leave the tables kept
	# beside `entities`, so nothing seen once stays there for good. A bay's area stays while its
	# chunk is away (the bay next door keeps its frame) and goes when the chunk comes back without it.
	var lw := WorldMirror.new()
	add_child(lw)
	lw.protos.add_entities([[1, "cargo-bay", "cargo-bay", -2, -2, 2, 2, 120, 120, 120, 4, 4],
		[2, "stone-furnace-remnants", "corpse", -1, -1, 1, 1, 120, 120, 120, 2, 2],
		[3, "pipe", "pipe", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1],
		[4, "entity-ghost", "entity-ghost", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1]])
	var new_chunk := func(c: Vector2i) -> void:
		var lcv := ChunkView.new()
		lcv.coord = c
		lw.chunks[c] = lcv
		lw.add_child(lcv)
	new_chunk.call(Vector2i(0, 0))
	new_chunk.call(Vector2i(1, 0))
	lw._add([11, 1, 30 * 256, 16 * 256, 0])  # a bay in chunk (0, 0)...
	lw._add([12, 1, 34 * 256, 16 * 256, 0])  # ...and one beside it in chunk (1, 0)
	lw._add([0, 2, 40 * 256 + 128, 5 * 256 + 128, 0])  # remnants
	lw._add([0, 3, 41 * 256 + 128, 8 * 256 + 128, 0])  # a pipe
	lw._add([13, 4, 42 * 256 + 128, 9 * 256 + 128, 0, {"gh": 3}])  # a pipe's ghost
	lw._add([0, 2, 10 * 256 + 128, 5 * 256 + 128, 0])  # remnants in chunk (0, 0)
	var joined := int(lw.entities[11].extra.get("cb", -1))
	lw._unload(Vector2i(1, 0))
	for f in 10:
		lw._free_unloaded()
	check(lw._remnants.size() == 1 and lw._pipes.is_empty() and lw._ghosts.is_empty() and lw.entities.size() == 2
		and lw._cargo.has(12) and lw._cargo_left.get(12) == Vector2i(1, 0) and int(lw.entities[11].extra.get("cb", -1)) == joined,
		"an unloaded chunk's records leave the remnants, pipes and ghosts; its bay's area stays, the bay next door framed as before")
	new_chunk.call(Vector2i(1, 0))
	lw.handle({"t": "chunk", "cx": 1, "cy": 0, "tiles": [], "parts": 0})  # back, the bay mined meanwhile
	var lone_cells: Array = [0, 1, 2, 3].map(func(k): return ModelLibrary.cargo_pieces((int(lw.entities[11].extra.get("cb", -1)) >> (8 * k)) & 255))
	check(not lw._cargo.has(12) and lw._cargo_left.is_empty()
		and lone_cells == [["cargo-bay-corner-nw"], ["cargo-bay-corner-ne"], ["cargo-bay-corner-sw"], ["cargo-bay-corner-se"]],
		"the chunk back without its bay: the bay next door is framed alone: %s" % [lone_cells])
	lw.handle({"t": "chunk", "cx": 0, "cy": 0, "tiles": [], "parts": 1})
	lw.handle({"t": "ents", "cx": 0, "cy": 0, "part": 1, "parts": 1, "e": [[11, 1, 30 * 256, 16 * 256, 0]]})
	check(lw._remnants.is_empty() and lw._cargo.has(11), "a chunk resent without its remnants forgets them")
	lw._add([0, 2, 10 * 256 + 128, 5 * 256 + 128, 0])
	lw.reset(true)
	check(lw._remnants.is_empty() and lw._cargo.is_empty() and lw._cargo_left.is_empty(), "a reset forgets remnants too")
	lw.queue_free()
	# Inserter platforms: Factorio's four renders sit a little differently, a model for each (ours and
	# Wube3DP's; FUE5's, above them by default, is one model turned: model_preview_test.gd).
	var ins_models: Array[String] = []
	for ins: String in ["burner-inserter", "inserter", "long-handed-inserter", "fast-inserter", "bulk-inserter", "stack-inserter"]:
		ins_models.append_array([ins, ins + "-east", ins + "-south", ins + "-west"])
	_ours(ins_models)
	var platforms_ok := true
	for ins in ["burner-inserter", "inserter", "long-handed-inserter", "fast-inserter", "bulk-inserter", "stack-inserter"]:
		platforms_ok = platforms_ok and ModelLibrary.model_name(ins, "inserter", {}, 4) == ins + "-east" \
			and ModelLibrary.model_name(ins, "inserter", {}, 8) == ins + "-south" \
			and ModelLibrary.turn_dir("inserter", 12, {}, ins) == 0 \
			and ModelLibrary.mesh_for_entity(ins, "inserter", {}, 12) is ArrayMesh \
			and ModelLibrary.mesh_for_entity(ins, "inserter", {}, 12) != ModelLibrary.mesh_for(ins)
	check(platforms_ok, "inserter platforms: a model per direction, drawn unturned")
	_restore_models(ins_models)
	# The pumpjack and the chemical plant too: every direction its own model, unturned, with the
	# pumpjack's beam rocking on its upright frame and the plant's light blinking in each.
	var facing_ok := true
	# FUE5's models (its pack) replace them in play with no upright beam or lamp: ours are
	# checked.
	var facing_models: Array[String] = []
	for base in ["pumpjack", "chemical-plant"]:
		for side in ["", "-east", "-south", "-west"]:
			if _theirs_in_use(base + side):
				facing_models.append(base + side)
	_ours(facing_models)
	for dir in [0, 4, 8, 12]:
		var jack := {}
		for part: ModelLibrary.AnimPart in ModelLibrary.parts_for_entity("pumpjack", "mining-drill", {}, dir):
			jack[part.kind] = part.upright
		var plant := ModelLibrary.mesh_for_entity("chemical-plant", "assembling-machine", {}, dir)
		facing_ok = facing_ok and jack.get("rock_beam", false) and jack.get("spin_crank", false) and jack.has("still") \
			and ModelLibrary.glows(plant) and ModelLibrary.turn_dir("mining-drill", dir, {}, "pumpjack") == 0 \
			and ModelLibrary.turn_dir("assembling-machine", dir, {}, "chemical-plant") == 0
	check(facing_ok and ModelLibrary.model_name("pumpjack", "mining-drill", {}, 8) == "pumpjack-south"
		and ModelLibrary.model_name("chemical-plant", "assembling-machine", {}, 4) == "chemical-plant-east"
		and ModelLibrary.mesh_for_entity("chemical-plant", "assembling-machine", {}, 12) != ModelLibrary.mesh_for("chemical-plant"),
		"the pumpjack and chemical plant: a model per direction, unturned, beam, crank and light moving in each")
	_restore_models(facing_models)
	world._add([51, 6, 20 * 256, 20 * 256 + 128, 0])
	check(input._blocked(belt, Vector2(20.5, 20.5), Vector2i.ONE), "something in the way blocks the build (the ghost turns red)")

	# --- hover: selection corners, inserters, fluids, drills, roboports ---------------------------
	var ins: ProtoDB.EntityProto = world.protos.entity(3)
	var marks := input.hover_marks(ins, Vector2(0.5, 0.5), 4)
	var corners: Array = marks.filter(func(k): return k["k"] == "brackets")
	check(corners.size() == 1 and corners[0]["at"] == Vector2(0.5, 0.5) and corners[0]["half"] == Vector2(0.5, 0.5), "hover shows the selection box's corners")
	var arrows: Array = marks.filter(func(k): return k["k"] == "arrow")
	check(arrows.size() == 2 and arrows[0]["at"].is_equal_approx(Vector2(2.5, 0.5)) and arrows[1]["at"].is_equal_approx(Vector2(-1.7, 0.5))
		and arrows[0]["dir"].is_equal_approx(Vector2(-1, 0)),
		"a long inserter facing east: pickup arrow 2 east, drop arrow 2.2 west, pointing west (as in 2.1.23): %s" % [arrows])
	var engine := input.hover_marks(world.protos.entity(6), Vector2(0, 0.5), 4).filter(func(k): return k["k"] == "arrow")
	check(engine.size() == 2 and engine[0]["both"] and engine[0]["at"].is_equal_approx(Vector2(-2.62, 0.5)),
		"a steam engine facing east: two-way fluid arrows past its west and east ends: %s" % [engine])
	check(input.hover_marks(world.protos.entity(8), Vector2(0.5, 0.5), 0).size() == 1,
		"an assembler's fluid connections stay hidden (they show only with a fluid recipe)")
	var drill := input.hover_marks(world.protos.entity(5), Vector2(0.5, 0.5), 8)
	var drill_area: Array = drill.filter(func(k): return k["k"] == "area")
	var drill_out: Array = drill.filter(func(k): return k["k"] == "arrow")
	check(drill_area.size() == 1 and drill_area[0]["rect"].size.is_equal_approx(Vector2(4.98, 4.98))
		and drill_out.size() == 1 and drill_out[0]["at"].is_equal_approx(Vector2(0.5, 2.35)) and drill_out[0]["dir"].is_equal_approx(Vector2(0, 1)),
		"a drill facing south: its mining area and its output arrow south of it")
	var robo := input.hover_marks(world.protos.entity(4), Vector2(10, 10), 0).filter(func(k): return k["k"] == "area")
	check(robo.size() == 2 and robo[0]["rect"] == Rect2(-45, -45, 110, 110) and robo[1]["rect"] == Rect2(-15, -15, 50, 50)
		and robo[1]["edge"] == CursorOverlay.LOGISTIC_EDGE and robo[0]["edge"] == CursorOverlay.CONSTRUCTION_EDGE,
		"a roboport shows its construction (green) and logistic (orange) areas")
	check(CursorOverlay.marks_for("roboport", m.eprops[4]["x"], Vector2(10, 10), 0, true).size() == 2, "and so does one being placed")
	# H14: roboports whose logistic squares meet are linked, and Factorio draws the lines between them
	# while one is hovered (the game's own links, hinfo rn; the rule until it answers) or held.
	var links := RoboportLinksScript.new(null)
	links._ports[Vector2i(0, 0)] = [[Vector2(10, 10), 4, 501]]
	links._ports[Vector2i(1, 0)] = [[Vector2(55, 10), 4, 502]]
	links._ports[Vector2i(4, 0)] = [[Vector2(140, 10), 4, 503]]
	var held_links: Array = links.held_lines(Vector2(100, 10), 25.0)
	check(RoboportLinksScript.linked(Vector2.ZERO, 25.0, Vector2(50, 0), 25.0) and not RoboportLinksScript.linked(Vector2.ZERO, 25.0, Vector2(51, 0), 25.0)
		and held_links.size() == 3 and links.hovered_lines(Vector2(10, 10), 25.0, 501, [Vector2(55, 10)]).size() == 1
		and links.hovered_lines(Vector2(10, 10), 25.0, 501, null) == [[Vector2(10, 10), Vector2(55, 10)]]
		and links.hovered_lines(Vector2(10, 10), 25.0, 501, []).is_empty(),
		"roboport links: the held one's to its neighbours and theirs to each other, a hovered one's from the game (H14): %s" % [held_links])
	const GroundHeightWM := preload("res://scripts/world/ground_height.gd")
	const MarkShaderWM := preload("res://shaders/ground_mark.gdshader")
	const OverlayShaderWM := preload("res://shaders/ground_overlay.gdshader")
	var overlay := CursorOverlay.new()
	add_child(overlay)
	overlay.show_marks(marks + robo + [CursorOverlay.cover([Rect2(0, 0, 5, 5)]), CursorOverlay.line(Vector2(10, 10), Vector2(55, 10))])
	var top_mat := overlay.material_override as ShaderMaterial
	var area_mat := overlay._areas.material_override as ShaderMaterial
	var areas_verts: PackedVector3Array = overlay._areas.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var all_flat_y := not areas_verts.is_empty()
	for v in areas_verts:
		if not is_equal_approx(v.y, CursorOverlay.AREA_LIFT):
			all_flat_y = false
			break
	check(overlay.visible and overlay.mesh.get_surface_count() == 1 and overlay._areas.visible
		and overlay._areas.mesh.get_surface_count() == 1
		and top_mat != null and top_mat.shader == OverlayShaderWM and top_mat.render_priority == 10
		and area_mat != null and area_mat.shader == MarkShaderWM and area_mat.render_priority == GroundHeightWM.AREA_PRIORITY
		and area_mat.render_priority > DecorativeLayer.SHEET_PRIORITY
		and area_mat.render_priority < DecorativeLayer._grass_priority("green-hairy-grass")
		and area_mat.render_priority < -1
		and all_flat_y,
		"area showcases draw on the ground under models and grass (priority %d, y %.2f), while brackets/arrows/lines stay over everything"
		% [area_mat.render_priority if area_mat != null else 0, CursorOverlay.AREA_LIFT])
	overlay.show_marks([CursorOverlay.cover([Rect2(0, 0, 5, 5)])])
	check(overlay.visible and overlay._areas.visible and overlay._areas.mesh.get_surface_count() == 1
		and overlay.mesh.get_surface_count() == 0, "area-only marks light up only the ground mesh")
	overlay.show_marks([CursorOverlay.brackets(Vector2.ZERO, Vector2.ONE)])
	check(overlay.visible and overlay.mesh.get_surface_count() == 1 and not overlay._areas.visible
		and overlay._areas.mesh.get_surface_count() == 0, "top-only marks keep the ground area mesh hidden")
	overlay.show_marks([])
	check(not overlay.visible and not overlay._areas.visible
		and overlay.mesh.get_surface_count() == 0 and overlay._areas.mesh.get_surface_count() == 0,
		"and hidden with none")
	var hill_img := Image.create(32, 32, false, Image.FORMAT_RF)
	hill_img.fill(Color(2.0, 0.0, 0.0))
	GroundHeightWM.set_field(hill_img, Vector2(-64, -64), 2.0)
	var robo_area := [CursorOverlay.area(Rect2(-45, -45, 110, 110), CursorOverlay.LOGISTIC_FILL, CursorOverlay.LOGISTIC_EDGE)]
	overlay.show_marks(robo_area)
	var hill_verts: PackedVector3Array = overlay._areas.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var all_hill_y := hill_verts.size() > 30
	for v in hill_verts:
		if not is_equal_approx(v.y, CursorOverlay.AREA_HILL_LIFT):
			all_hill_y = false
			break
	GroundHeightWM.clear()
	overlay.show_marks(robo_area)
	var cleared_verts: PackedVector3Array = overlay._areas.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var back_flat_y := cleared_verts.size() == 30
	for v in cleared_verts:
		if not is_equal_approx(v.y, CursorOverlay.AREA_LIFT):
			back_flat_y = false
			break
	check(all_hill_y and back_flat_y,
		"hills: a roboport area subdivides onto the terrain (%d verts) and rebuilds flat after clear (%d verts)" % [hill_verts.size(), cleared_verts.size()])
	overlay.queue_free()

	# --- Alt-mode (issue #9): icons ride on the records, kept per chunk; aiu changes them -------------
	var aw := WorldMirror.new()
	add_child(aw)
	aw.chunks[Vector2i.ZERO] = ChunkView.new()
	aw.chunks[Vector2i(1, 0)] = ChunkView.new()
	aw.handle({"t": "ents", "cx": 0, "cy": 0, "part": 1, "parts": 1, "e": [[123, 8, 5 * 256, 5 * 256, 0, {"ai": ["recipe", "iron-gear-wheel"]}],
		[124, 8, 9 * 256, 5 * 256, 0], [125, 8, 13 * 256, 5 * 256, 0, {"ai": ["recipe", ""]}]]})
	var acv: ChunkView = aw.chunks[Vector2i.ZERO]
	check(acv.alt.has(123) and not acv.alt.has(124) and WorldMirror.alt_icon(acv.alt[123]) == ["recipe", "iron-gear-wheel"]
		and WorldMirror.alt_icon(aw.entities[125]).is_empty(),
		"Alt-mode: a record's icon is kept in its chunk; nothing over a machine without one or with an empty recipe")
	aw.handle({"t": "aiu", "l": [[124, "item", "coal"], [123, ""], [999, "recipe", "x"]]})
	check(acv.alt.has(124) and not acv.alt.has(123) and WorldMirror.alt_icon(aw.entities[124]) == ["item", "coal"] and aw._dirty.size() <= 1,
		"aiu sets and clears icons (an unknown unit is skipped), without drawing the chunk again")
	aw.handle({"t": "del", "u": 124})
	check(acv.alt.is_empty(), "a machine removed takes its icon with it")
	aw.handle({"t": "add", "e": [126, 8, 40 * 256, 5 * 256, 0, {"ai": ["recipe", "copper-cable"]}]})
	aw.handle({"t": "chunk", "cx": 1, "cy": 0, "tiles": [], "parts": 1})
	check((aw.chunks[Vector2i(1, 0)] as ChunkView).alt.is_empty(), "a chunk sent again starts with no icons until its records come")
	aw.queue_free()

	# --- Alt-mode arrows (issue #9 part 2): Factorio's inserter, pump and machine arrows ---------------
	var ins_x := {"ip": [0, -1], "id": [0, 1.2]}
	var ins_arrows := AltArrowsScript.arrows_for("inserter", ins_x, Vector2(10.5, 10.5), 0, 0)
	check(ins_arrows.size() == 2 and ins_arrows[0][0] == AltArrowsScript.INDICATION and ins_arrows[0][1].is_equal_approx(Vector2(10.5, 9.5))
		and ins_arrows[1][1].is_equal_approx(Vector2(10.5, 11.7)) and ins_arrows[0][2].is_equal_approx(Vector2(0, 1)),
		"an inserter's arrows where it picks up and drops, pointing the way items go: %s" % [ins_arrows])
	# A chemical plant's connections: two inputs north, two outputs south (facing north).
	var chem_x := {"fb": [[-1, -1, 0, "i"], [1, -1, 0, "i"], [-1, 1, 8, "o"], [1, 1, 8, "o"]], "fo": 1}
	var chem_in := AltArrowsScript.arrows_for("assembling-machine", chem_x, Vector2(0, 0), 0, 1)
	var chem_both := AltArrowsScript.arrows_for("assembling-machine", chem_x, Vector2(0, 0), 0, 3)
	check(AltArrowsScript.arrows_for("assembling-machine", chem_x, Vector2(0, 0), 0, 0).is_empty() and chem_in.size() == 2
		and chem_in[0][1].is_equal_approx(Vector2(-1, -1.5)) and chem_in[0][2].is_equal_approx(Vector2(0, 1)) and chem_both.size() == 4
		and chem_both[3][2].is_equal_approx(Vector2(0, 1)), "a machine shows the connections its recipe uses, inputs pointing in, outputs out: %s" % [chem_in])
	var pump_arrows := AltArrowsScript.arrows_for("pump", {"fb": [[0, -0.5, 0, "o"], [0, 0.5, 8, "i"]]}, Vector2(0, 0), 4, 0)
	check(pump_arrows.size() == 1 and pump_arrows[0][0] == AltArrowsScript.FLUID and pump_arrows[0][2].is_equal_approx(Vector2(1, 0)),
		"a pump (facing east) shows the arrow where its fluid leaves: %s" % [pump_arrows])
	var rec_arrows := AltArrowsScript.arrows_for("furnace", {"vp": [0, -1.6]}, Vector2(0, 0), 4, 0)
	check(rec_arrows.size() == 1 and rec_arrows[0][0] == AltArrowsScript.INDICATION and rec_arrows[0][1].is_equal_approx(Vector2(1.6, 0)),
		"a recycler (facing east) shows its yellow arrow on its output side: %s" % [rec_arrows])
	var boiler_arrows := AltArrowsScript.arrows_for("boiler", {"fb": [[-1, 0.5, 12, "b"], [1, 0.5, 4, "b"], [0, -0.5, 0, "o"]]}, Vector2(0, 0), 0, 0)
	check(boiler_arrows.size() == 3 and boiler_arrows[0][0] == AltArrowsScript.FLUID_BOTH, "a boiler: its water both ways, steam out")
	var t_east := AltArrowsScript.transform(Vector2(3, 4), Vector2(1, 0))
	check((t_east.basis * Vector3(0, 0, -1)).is_equal_approx(Vector3(1, 0, 0)) and t_east.origin.is_equal_approx(Vector3(3, AltArrowsScript.LIFT, 4)),
		"an arrow's top points the way it goes")
	# The layer: per chunk, filled from the chunks in view, as the settings say.
	var arw := WorldMirror.new()
	add_child(arw)
	arw.protos.add_entities([[9902, "test-inserter", "inserter", -0.15, -0.15, 0.15, 0.15, 0, 0, 0, 1, 1],
		[9903, "test-chemical-plant", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 0, 0, 0, 3, 3]])
	arw.chunks[Vector2i.ZERO] = ChunkView.new()
	arw._add([801, 9902, 5 * 256 + 128, 5 * 256 + 128, 0])
	arw._add([802, 9903, 10 * 256 + 128, 10 * 256 + 128, 0, {"fa": 1}])
	var had_eprops := {}
	for k in [9902, 9903]:
		if m.eprops.has(k):
			had_eprops[k] = m.eprops[k]
	m.eprops[9902] = {"x": ins_x}
	m.eprops[9903] = {"x": chem_x}
	var layer := AltArrowsScript.new()
	layer.world = arw
	layer.model = m
	add_child(layer)
	var acam := Camera3D.new()
	add_child(acam)
	acam.position = Vector3(8, 30, 14)
	acam.look_at(Vector3(8, 0, 8))
	var was_ins = Settings.get_value("interface", "alt_inserter_arrows")
	Settings.set_value("interface", "alt_inserter_arrows", false, false)
	Settings.set_value("interface", "alt_machine_arrows", true, false)
	layer.refresh(acam)
	var only_machines: int = layer.drawn
	Settings.set_value("interface", "alt_inserter_arrows", true, false)
	layer._all_dirty = true
	layer.refresh(acam)
	var with_inserters: int = layer.drawn
	arw.handle({"t": "aiu", "l": [], "fa": [[802, 3]]})
	layer.refresh(acam)
	check(only_machines == 2 and with_inserters == 4 and layer.drawn == 6 and layer._layers[AltArrowsScript.FLUID].multimesh.visible_instance_count == 4,
		"Alt-mode arrows: machines' by default, inserters' when chosen, and a recipe change (aiu fa) redraws them: %d %d %d" % [only_machines, with_inserters, layer.drawn])
	Settings.set_value("interface", "alt_inserter_arrows", was_ins, false)
	for k in [9902, 9903]:
		if had_eprops.has(k):
			m.eprops[k] = had_eprops[k]
		else:
			m.eprops.erase(k)
	layer.queue_free()
	acam.queue_free()
	arw.queue_free()

	# --- clicking a train anywhere on it -------------------------------------------------------------
	var movers := MoverLayer.new()
	movers.protos = world.protos
	add_child(movers)
	movers.handle({"t": "mv", "k": 1, "l": [[900, 7, 50 * 256, 50 * 256, 250]]})  # a locomotive facing east
	movers._process(10.0)
	var down := Vector3(0, -1, 0)
	var hit := movers.pick_ray(Vector3(52.6, 20, 50.3), down, ["locomotive"])
	check(not hit.is_empty() and int(hit[0]) == 900, "a click near the end of a locomotive (east of its middle, it faces east) opens it")
	check(movers.pick_ray(Vector3(50.3, 20, 52.6), down, ["locomotive"]).is_empty(), "beside it, it doesn't")
	var slant := Vector3(0, -1, 2).normalized()  # meets the ground at (50, 53), two tiles past the loco
	check(not movers.pick_ray(Vector3(50, 20, 13), slant, ["locomotive"]).is_empty(),
		"a click on the loco's side, over ground behind it, opens it")
	check(movers.pick(Vector2(52.6, 50.3), 1.6, ["locomotive"]).is_empty(), "(the old pick by distance to the middle missed it)")

	# --- the remote view fogs over and hides what no radar sees (remote_fog.gd) -----------------------
	var fog := RemoteFog.new()
	add_child(fog)
	movers.fog = fog
	fog.world = world
	var fog_chunks := {}
	# A radar's chunk, one of its chunks still on its way, one next to its 7 x 7, one far off.
	for c in [Vector2i(10, 10), Vector2i(12, 10), Vector2i(14, 10), Vector2i(20, 20)]:
		var fcv := ChunkView.new()
		fcv.loaded = c != Vector2i(12, 10)  # (no tiles: counts as ground drawn)
		world.add_child(fcv)
		world.chunks[c] = fcv
		fog_chunks[c] = fcv
	fog.update(true, Vector2(50, 50))
	movers._process(0.016)
	check(not fog.hiding() and movers.node_of(900).visible, "remote view: until the mod says what radars see, nothing is hidden")
	fog.handle({"t": "cov", "si": 1, "l": [10, 10, 3], "x": -300 * 256, "y": 0, "cr": 96})
	fog.update(true, Vector2(50, 50))
	movers._process(0.016)
	var fog_quad: MeshInstance3D = fog.get_node("RemoteFog")
	check(fog.hiding() and fog_quad.visible and not movers.node_of(900).visible,
		"remote view: the fog pass is on and a locomotive neither the radar nor the character sees is hidden")
	check(fog.seen(Vector2(330, 330)) and fog.seen(Vector2(-200, 0)) and not fog.seen(Vector2(500, 0)) and not fog.seen(Vector2(100, 10)),
		"remote view: a radar's 7 x 7 chunks and the chunks whose middle is within 112 tiles of the character are seen, nothing else")
	check(fog._image.get_pixelv(Vector2i(10, 10) - fog._origin).r > 0.5 and fog._image.get_pixelv(Vector2i(20, 20) - fog._origin).r < 0.5,
		"remote view: the fog's texture marks the radar's chunks seen and others not")
	var on_its_way := Vector2i(12, 10) - fog._origin
	check(fog.seen(Vector2(12 * 32 + 5, 10 * 32 + 5)) and fog._image.get_pixelv(on_its_way).r < 0.5,
		"remote view: a seen chunk whose ground hasn't arrived stays under the fog (no bare background)")
	fog_chunks[Vector2i(12, 10)].loaded = true
	fog._hide_chunks()
	fog.update(true, Vector2(50, 50))
	check(fog._image.get_pixelv(on_its_way).r > 0.5, "remote view: once its ground is drawn the fog lifts off it")
	check(fog_chunks[Vector2i(10, 10)].visible and fog_chunks[Vector2i(14, 10)].visible
		and not fog_chunks[Vector2i(20, 20)].visible and not world.chunks[Vector2i.ZERO].visible and fog.hidden_chunks() == 2,
		"remote view: chunks wholly under the fog aren't drawn; a seen one and its neighbour (under the soft edge) are")
	# G18: wires starting in a chunk no radar sees are hidden under the fog too.
	var fog_wires := WireLayerScript.new()
	fog_wires.fog = fog
	var seen_wire := MeshInstance3D.new()
	var unseen_wire := MeshInstance3D.new()
	fog_wires.add_child(seen_wire)
	fog_wires.add_child(unseen_wire)
	fog_wires._meshes[Vector2i(10, 10)] = seen_wire
	fog_wires._meshes[Vector2i(20, 20)] = unseen_wire
	fog_wires._apply_fog()
	var wires_fogged := seen_wire.visible and not unseen_wire.visible
	fog.update(false, Vector2(50, 50))
	fog_wires._apply_fog()
	check(wires_fogged and unseen_wire.visible, "remote view: wires where no radar sees are hidden, and back on leaving it (G18)")
	fog_wires.free()
	fog.update(true, Vector2(50, 50))
	# H13: a roboport's construction area counts as seen too (the UI model's list from `mrp`): one at
	# 648 tiles reaching 55 holds the middles of chunks 19-21 each way, not chunk 22's.
	var rp_model := UiModel.new()
	fog.model = rp_model
	rp_model.handle({"t": "mrp", "si": 1, "q": 1, "part": 1, "last": 1, "l": [648 * 256, 648 * 256, 25 * 256, 55 * 256]})
	fog.handle({"t": "cov", "si": 1, "l": [10, 10, 3], "x": -300 * 256, "y": 0, "cr": 96})  # left and back: cov again
	fog.update(true, Vector2(50, 50))
	check(fog.seen(Vector2(20 * 32 + 5, 20 * 32 + 5)) and fog.seen(Vector2(21 * 32 + 5, 19 * 32 + 5)) and not fog.seen(Vector2(22 * 32 + 5, 20 * 32 + 5)),
		"remote view: a roboport's construction area counts as seen, past it doesn't (H13)")
	check(fog._image.get_pixelv(Vector2i(20, 20) - fog._origin).r > 0.5 and fog_chunks[Vector2i(20, 20)].visible,
		"remote view: the fog lifts there and the chunk is drawn again")
	fog.model = null
	fog._dirty = true
	fog.update(true, Vector2(50, 50))
	var fog_mat := fog_quad.material_override as ShaderMaterial
	check(fog_mat.render_priority > 2 and fog_mat.render_priority < 10 and not fog_mat.shader.code.contains("hint_screen_texture"),
		"remote view: the fog is drawn over ghosts, smoke and item cards, under the build preview, without copying the screen")
	fog.update(false, Vector2(50, 50))
	movers._process(0.016)
	check(not fog_quad.visible and movers.node_of(900).visible and fog.seen(Vector2(500, 0)), "leaving the remote view shows everything again")
	check(fog_chunks[Vector2i(20, 20)].visible and world.chunks[Vector2i.ZERO].visible and fog.hidden_chunks() == 0,
		"leaving the remote view draws the chunks the fog hid again")
	for c in fog_chunks:
		world.chunks.erase(c)
		fog_chunks[c].free()
	fog.queue_free()
	movers.fog = null
	movers.queue_free()
	input.free()
	world.chunks[Vector2i.ZERO].free()
	world.free()


## K11 (the owner: "blueprints don't show the models on hover"): a held blueprint shows its buildings'
## models at the cursor (blueprint_preview.gd: one MultiMesh per model, Factorio's ghost blue) where
## the mod is told to put them (#21's clipboard rule), turned with R, flipped with H, red over what is
## in the way as Factorio's build modes have it; a big blueprint is laid out a slice a frame and
## moving the cursor lays nothing out again; and a blueprint's tooltip (an inventory slot's, asked of
## the bridge as it opens; a library record's) has its picture under the title.


func _blueprint_preview(hud: Hud) -> void:
	PlayerInput.define_actions()
	var ui = hud.ui
	var m: UiModel = ui.model
	var pl = ui.planners
	check(GhostShader.get_shader_uniform_list().any(func(u: Dictionary) -> bool: return u["name"] == "instance_tint")
		and GhostShader.get_shader_uniform_list().any(func(u: Dictionary) -> bool: return u["name"] == "bad_tint"),
		"K11: ghost.gdshader has its per-instance red (instance_tint, bad_tint)")
	var world := WorldMirror.new()
	world.protos.add_entities([
		[1, "transport-belt", "transport-belt", -0.4, -0.4, 0.4, 0.4, 200, 180, 0, 1, 1],
		[2, "inserter", "inserter", -0.15, -0.15, 0.15, 0.15, 200, 180, 0, 1, 1],
		[3, "iron-chest", "container", -0.35, -0.35, 0.35, 0.35, 120, 120, 120, 1, 1],
		[4, "wooden-chest", "container", -0.35, -0.35, 0.35, 0.35, 150, 110, 60, 1, 1],
		[5, "tree-01", "tree", -0.4, -0.4, 0.4, 0.4, 40, 110, 40, 1, 1],
		[6, "small-lamp", "lamp", -0.15, -0.15, 0.15, 0.15, 120, 120, 120, 1, 1],
	])
	world.protos.add_tiles([[1, "stone-path", 120, 110, 100]])
	world.chunks[Vector2i.ZERO] = ChunkView.new()
	var input := PlayerInput.new()
	input.world = world
	input.hud = hud
	input.tile_brush.pi = input
	input.drag.pi = input
	var bp: Node3D = input.bp_preview
	bp.world = world
	bp.replace_groups = PlayerInput.REPLACE_GROUPS
	add_child(bp)
	var record := BpString.decode(FACTORIO_STRING)
	var had_slots: Array = m.main_slots
	var had_has := m.has_slots
	var had_counts: Dictionary = m.counts.duplicate()
	m.set_inventory_slots([["blueprint", 1], ["blueprint", 1]], 80)
	input.hold("blueprint", 1)
	pl.held_slot = 1
	pl.held_record = record
	input.has_ground = true
	input.ground = Vector2(10.3, 5.2)
	input.build_dir = 0
	sent()
	var settle := func() -> bool:
		var until := Time.get_ticks_msec() + 60000
		while Time.get_ticks_msec() < until:
			input._update_paste_preview()
			if bp.settled():
				return true
			ModelLibrary.poll()
			await get_tree().process_frame
		return false
	var settled: bool = await settle.call()
	var items: Array = bp.shown_items()
	var mesh_of := func(i: int) -> Mesh: return items[i][3] if i < items.size() else null
	var chest_mesh := ModelLibrary.mesh_for_entity("iron-chest", "container", {}, 0)
	var belt_mesh := ModelLibrary.mesh_for_entity("transport-belt", "transport-belt", {"s": "s"}, 4)
	check(settled and bp.visible and items.size() == 5 and bp.tile_count() == 2 and chest_mesh != null and belt_mesh != null
		and mesh_of.call(4) == chest_mesh and mesh_of.call(0) == belt_mesh and mesh_of.call(2) == belt_mesh
		and items.all(func(it: Array) -> bool: return it[3] != null and it[3] != Visuals.box_mesh())
		and bp.multimesh_of(belt_mesh).instance_count == 3 and bp.bad_count() == 0,
		"K11: a held blueprint is drawn as its buildings' models (three belts in one MultiMesh, the inserter, the iron chest) and its two tiles: %s" % [items.map(func(it: Array) -> String: return "%s %s" % [(it[0] as ProtoDB.EntityProto).name, it[3]])])
	# Where: the mouse moved as little as puts it on the grid, its middle sent to the mod as drawn.
	var where := func(i: int) -> Vector2:
		var o: Vector3 = bp.instance_transform(i).origin + bp.position
		return Vector2(o.x, o.z)
	# The chest's row in its MultiMesh's buffer, where the renderer keeps one (the dummy one may not).
	var chest_mm: MultiMesh = bp.multimesh_of(items[4][3])
	var chest_buf: PackedFloat32Array = chest_mm.buffer if chest_mm != null else PackedFloat32Array()
	var row_ok := chest_buf.size() != chest_mm.instance_count * 16 or Vector3(chest_buf[3], chest_buf[7], chest_buf[11]).is_equal_approx(
		bp.instance_transform(4).origin)
	print("K11: the chest's MultiMesh buffer %s" % ("checked" if chest_buf.size() == chest_mm.instance_count * 16 else "not kept by this renderer (%d floats)" % chest_buf.size()))
	var anchor: Vector2 = input.blueprint_anchor(input.ground)
	input.place_blueprint(anchor, 0)
	var placed := sent_one("blueprint")
	check(anchor.is_equal_approx(Vector2(10.5, 5.0)) and Vector2(bp.position.x, bp.position.z).is_equal_approx(anchor)
		and where.call(4).is_equal_approx(Vector2(12.5, 4.5)) and where.call(0).is_equal_approx(Vector2(8.5, 4.5))
		and placed.get("x") == 2688 and placed.get("y") == 1280 and row_ok,
		"K11: the preview's middle on the grid nearest the mouse, the chest at 12.5, 4.5, and the mod told that middle: %s %s %s" % [anchor, where.call(4), placed])
	# Moving the cursor moves the node; nothing is laid out again.
	var laid := int(bp.laid_out)
	input.ground = Vector2(11.4, 5.2)
	input._update_paste_preview()
	check(bp._stage == 0 and int(bp.laid_out) == laid and is_equal_approx(bp.position.x, 11.5),
		"K11: moving the cursor a tile moves the preview without laying it out again")
	input.ground = Vector2(10.3, 5.2)
	# R turns it a quarter clockwise round its middle, every entity turned with it.
	input._rotate(false)
	settled = await settle.call()
	items = bp.shown_items()
	var belt_turned: Transform3D = bp.instance_transform(0)
	check(settled and input.build_dir == 4 and (items[4][1] as Vector2).is_equal_approx(Vector2(0.5, 2.0))
		and belt_turned.basis.is_equal_approx(ModelLibrary.placed("transport-belt", "transport-belt", 8, {"s": "s"}, Vector3.ZERO).basis)
		and Vector2(bp.position.x, bp.position.z).is_equal_approx(input.blueprint_anchor(input.ground)),
		"K11: R turns the held blueprint: the chest from 2, -0.5 to %s, the belts east to south" % [items[4][1]])
	# H flips it east-west first (the mod's mirrored copy), then the turn.
	input._flip(false)
	settled = await settle.call()
	items = bp.shown_items()
	# The inserter faced west (12): mirrored east (4), turned south (8), Factorio's south picture
	# (or, where the inserter in use is one model turned, as FUE5's, that model).
	check(settled and input.build_mirror and (items[4][1] as Vector2).is_equal_approx(Vector2(0.5, -2.0))
		and items[3][3] == ModelLibrary.mesh_for_entity("inserter", "inserter", {}, 8)
		and (ModelLibrary.single_model("inserter") or items[3][3] != ModelLibrary.mesh_for_entity("inserter", "inserter", {}, 0)),
		"K11: H flips the held blueprint (the chest to %s, the inserter west to east, then turned south)" % [items[4][1]])
	input._flip(false)
	input._rotate(true)
	settled = await settle.call()
	# In the way: a lamp on the inserter's tile (not what an inserter replaces), a tree on the first
	# belt's; a wooden chest on the iron chest's is fast-replaced, as in Factorio.
	world._add([90, 6, 11 * 256 + 128, 4 * 256 + 128, 0])
	world._add([0, 5, 8 * 256 + 128, 4 * 256 + 128, 0])
	world._add([91, 4, 12 * 256 + 128, 4 * 256 + 128, 0])
	world.entities_changed.emit(Vector2i.ZERO)
	settled = await settle.call()
	items = bp.shown_items()
	var ins_mm: MultiMesh = bp.multimesh_of(items[3][3])
	# The red goes to the shader as the instance's custom data (not kept by the headless dummy renderer).
	var tinted := DisplayServer.get_name() == "headless" or is_equal_approx(ins_mm.get_instance_custom_data(int(items[3][4])).r, 1.0)
	check(settled and bp.is_bad(3) and bp.is_bad(0) and not bp.is_bad(4) and bp.bad_count() == 2 and tinted,
		"K11: red where it can't go: the inserter over a lamp and the belt over a tree, not the chest over a chest it replaces (%d red)" % bp.bad_count())
	# Shift (forced): the tree is marked for deconstruction instead; Ctrl+Shift: nothing stands in the way.
	var tiles: Array = pl.held_preview_tiles()
	var at_mode := func(mode: int) -> bool:
		var until := Time.get_ticks_msec() + 10000
		while Time.get_ticks_msec() < until:
			bp.show_blueprint(["bp", pl.preview_version], pl.held_preview(world.protos), tiles, anchor, 0, false, mode)
			if bp.settled():
				return true
			await get_tree().process_frame
		return false
	var forced_ok: bool = await at_mode.call(1)
	var forced := [bp.is_bad(0), bp.is_bad(3)]
	var super_ok: bool = await at_mode.call(2)
	check(forced_ok and super_ok and forced == [false, true] and bp.bad_count() == 0,
		"K11: Shift: the tree no longer red, the lamp still; Ctrl+Shift: none red (%s)" % [forced])
	world._remove(90)
	world.entities_changed.emit(Vector2i.ZERO)
	settled = await settle.call()
	check(settled and not bp.is_bad(3) and bp.is_bad(0), "K11: the lamp mined: the inserter no longer red")

	# A big blueprint: 4,000 entities laid out a slice a frame; then a tile's move only checks them.
	var ents: Array = []
	var kinds := ["transport-belt", "inserter", "iron-chest", "transport-belt"]
	for y in 50:
		for x in 80:
			ents.append({"entity_number": ents.size() + 1, "name": kinds[y % 4], "position": {"x": x + 0.5, "y": y + 0.5}, "direction": 4 if y % 4 != 1 else 8})
	pl.held_record = {"blueprint": {"item": "blueprint", "entities": ents}}
	var frames := 0
	var worst := 0
	var worst_preview := 0  # of that, blueprint_preview.gd's own slice (the rest: the entries listed, once)
	var until_big := Time.get_ticks_msec() + 60000
	var t_big := Time.get_ticks_msec()
	while Time.get_ticks_msec() < until_big:
		var t0 := Time.get_ticks_usec()
		var spent0: int = bp.usec_spent
		input._update_paste_preview()
		worst = maxi(worst, Time.get_ticks_usec() - t0)
		worst_preview = maxi(worst_preview, int(bp.usec_spent) - spent0)
		frames += 1
		if bp.settled():
			break
		await get_tree().process_frame
	var big_ms := Time.get_ticks_msec() - t_big
	var big_settled: bool = bp.settled()
	var big_items := (bp.shown_items() as Array).size()
	var move_frames := 0
	var move_worst := 0
	input.ground += Vector2(1, 0)
	while Time.get_ticks_msec() < until_big + 30000:
		var t0 := Time.get_ticks_usec()
		input._update_paste_preview()
		move_worst = maxi(move_worst, Time.get_ticks_usec() - t0)
		move_frames += 1
		if bp.settled():
			break
		await get_tree().process_frame
	print("K11 big blueprint: %d entities laid out and checked in %d frames (%d ms), the slowest frame's share %.1f ms (the preview's slice at most %.1f ms); a tile's move checked in %d frames, slowest %.1f ms" % [
		big_items, frames, big_ms, worst / 1000.0, worst_preview / 1000.0, move_frames, move_worst / 1000.0])
	check(big_settled and big_items == 4000 and frames > 1 and worst < 25000 and bp.settled() and move_worst < 25000,
		"K11: a 4,000-entity blueprint is laid out over %d frames (slowest %.1f ms), a tile's move checked over %d (slowest %.1f ms)" % [
			frames, worst / 1000.0, move_frames, move_worst / 1000.0])
	pl.held_record = record

	# The tooltip: the held stack's record at once, another inventory blueprint's once the bridge sends it.
	var tip_of := func(s: Control) -> Control:
		add_child(s)
		var tip: Control = s._make_custom_tooltip("")
		add_child(tip)
		return tip
	var held_slot := Slot.new()
	held_slot.slot_role = "main"
	held_slot.slot_index = 1
	held_slot.set_stack("blueprint", 1)
	held_slot.set_tip("Blueprint", [])
	var tip1: Control = tip_of.call(held_slot)
	await get_tree().process_frame
	var pic1 = tip1.find_child("BlueprintPicture", true, false) if tip1 != null else null
	check(pic1 != null and tip1.get_child(1) == pic1 and pic1.item_count() == 7 and pic1.custom_minimum_size.x > 0,
		"K11: an inventory blueprint's tooltip has its picture under the title (5 entities, 2 tiles)")
	sent()
	var other := Slot.new()
	other.slot_role = "main"
	other.slot_index = 2
	other.set_stack("blueprint", 1)
	other.set_tip("Blueprint", [])
	var tip2: Control = tip_of.call(other)
	await get_tree().process_frame
	var pic2 = tip2.find_child("BlueprintPicture", true, false) if tip2 != null else null
	var asks: Array = sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "bp_get" and c.get("i") == 2)
	var asked: Dictionary = asks[0] if not asks.is_empty() else {}
	var before := int(pic2.item_count()) if pic2 != null else -1
	m.handle({"t": "bp", "q": int(asked.get("q", 0)), "part": 1, "parts": 1, "s": FACTORIO_STRING, "item": "blueprint", "i": 2})
	await get_tree().process_frame
	check(pic2 != null and asked.get("i") == 2 and before == 0 and pic2.item_count() == 7,
		"K11: another inventory blueprint's picture is asked for as its tooltip opens (bp_get %s) and drawn when it comes" % [asked])
	var lib := PlannerSlot.new()
	lib.set_record(record)
	var tip3: Control = tip_of.call(lib)
	var pic3 = tip3.find_child("BlueprintPicture", true, false) if tip3 != null else null
	await get_tree().process_frame
	check(pic3 != null and pic3.item_count() == 7, "K11: a library record's tooltip has its picture")
	var plate := Slot.new()
	plate.slot_role = "main"
	plate.slot_index = 3
	plate.set_stack("iron-plate", 10)
	plate.set_tip("Iron plate", [])
	var tip4: Control = tip_of.call(plate)
	check(tip4 != null and tip4.find_child("BlueprintPicture", true, false) == null, "K11: an item's tooltip has none")
	for n in [held_slot, tip1, other, tip2, lib, tip3, plate, tip4]:
		if n != null:
			n.queue_free()

	input.hold("")
	input._update_paste_preview()
	check(not bp.visible, "K11: put away, the preview goes")
	bp.queue_free()
	input.free()
	world.chunks[Vector2i.ZERO].free()
	world.free()
	pl.held_record = {}
	pl.held_slot = 0
	m.main_slots = had_slots
	m.counts = had_counts
	m.has_slots = had_has
	sent()


## Tiles in the cursor, capsules, the rail planner and drag building (tile_brush.gd,
## capsule_aim.gd, rail_planner.gd, drag_build.gd), on a world of the test's own.
## N5: a wall drag follows the cursor's path round corners and fills a diagonal as a joined
## staircase (no line lock: Factorio locks belts alone); a belt drag still holds its line (J25).


func _wall_drag(hud: Hud) -> void:
	var world := WorldMirror.new()
	world.pick_build_usec = 1 << 40
	world.protos.add_entities([
		[1, "transport-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[2, "stone-wall", "wall", -0.5, -0.5, 0.5, 0.5, 200, 200, 200, 1, 1],
	])
	var input := PlayerInput.new()
	input.world = world
	input.hud = hud
	input.drag.pi = input
	input.build_dir = 0
	var wall: ProtoDB.EntityProto = world.protos.entity(2)
	var tiles := func() -> Array: return input.drag.sent.map(func(c): return Vector2i(int(c["x"]) / 256, int(c["y"]) / 256))
	var joined := func(path: Array) -> bool:
		for i in range(1, path.size()):
			var d: Vector2i = path[i] - path[i - 1]
			if absi(d.x) + absi(d.y) != 1:
				return false
		return true
	# A drag east, then south round a corner, then back west: a wall on every tile the cursor
	# crossed, none twice.
	input.drag.begin("stone-wall", wall, Vector2(10.5, 10.5), true)
	for at in [Vector2(13.5, 10.5), Vector2(13.5, 13.5), Vector2(11.5, 13.5)]:
		input.drag.update(at)
	var corner: Array = tiles.call()
	input.drag.end()
	check(corner == [Vector2i(10, 10), Vector2i(11, 10), Vector2i(12, 10), Vector2i(13, 10), Vector2i(13, 11), Vector2i(13, 12),
		Vector2i(13, 13), Vector2i(12, 13), Vector2i(11, 13)],
		"N5: a wall drag turns the corner with the cursor, a wall on each tile: %s" % [corner])
	# A diagonal in one jump and in small steps: every tile shares a side with the one before.
	input.drag.begin("stone-wall", wall, Vector2(20.5, 20.5), true)
	input.drag.update(Vector2(24.5, 24.5))
	var diag: Array = tiles.call()
	input.drag.end()
	input.drag.begin("stone-wall", wall, Vector2(30.5, 30.5), true)
	for k in range(1, 5):
		input.drag.update(Vector2(30.5 + k, 30.5 - k))
	var diag_slow: Array = tiles.call()
	input.drag.end()
	check(diag.size() == 9 and diag[-1] == Vector2i(24, 24) and joined.call(diag)
		and diag_slow.size() == 9 and diag_slow[-1] == Vector2i(34, 26) and joined.call(diag_slow),
		"N5: a diagonal wall drag leaves no gaps: %s %s" % [diag, diag_slow])
	# The old switch: along the first line only.
	DragBuildScript.walls_follow = false
	input.drag.begin("stone-wall", wall, Vector2(10.5, 10.5), true)
	input.drag.update(Vector2(13.5, 10.5))
	input.drag.update(Vector2(13.5, 13.5))
	var line: Array = tiles.call()
	input.drag.end()
	DragBuildScript.walls_follow = true
	check(line == [Vector2i(10, 10), Vector2i(11, 10), Vector2i(12, 10), Vector2i(13, 10)],
		"N5: --wall-drag=line holds a wall drag to its line: %s" % [line])
	# Belts keep J25's lock: the cursor off the line builds nothing.
	var lock_was: Variant = Settings.get_value("interface", "lock_belt_straight")
	Settings.set_value("interface", "lock_belt_straight", true, false)
	input.build_dir = 4
	input.drag.begin("transport-belt", world.protos.entity(1), Vector2(10.5, 10.5), true)
	input.drag.update(Vector2(13.5, 10.5))
	input.drag.update(Vector2(13.5, 13.5))
	var belts: Array = tiles.call()
	input.drag.end()
	Settings.set_value("interface", "lock_belt_straight", lock_was, false)
	check(belts == [Vector2i(10, 10), Vector2i(11, 10), Vector2i(12, 10), Vector2i(13, 10)],
		"N5: a belt drag still holds its line: %s" % [belts])
	input.free()
	sent()


func _build_tools(hud: Hud) -> void:
	PlayerInput.define_actions()
	var m: UiModel = hud.ui.model
	var world := WorldMirror.new()
	world.pick_build_usec = 1 << 40  # the whole pick index at once (see _predictions)
	world.protos.add_entities([
		[1, "transport-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[2, "underground-belt", "underground-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[3, "pipe", "pipe", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1],
		[4, "pipe-to-ground", "pipe-to-ground", -0.5, -0.5, 0.5, 0.5, 120, 120, 120, 1, 1],
		[5, "small-electric-pole", "electric-pole", -0.25, -0.25, 0.25, 0.25, 120, 90, 60, 1, 1],
		[6, "wooden-chest", "container", -0.5, -0.5, 0.5, 0.5, 150, 110, 60, 1, 1],
		[7, "straight-rail", "straight-rail", -1, -1, 1, 1, 130, 120, 110, 2, 2],
		[8, "stone-furnace", "furnace", -1, -1, 1, 1, 130, 120, 110, 2, 2],
	])
	world.protos.add_tiles([[1, "grass-1", 60, 90, 30], [2, "water", 50, 80, 120], [3, "concrete", 120, 120, 120]])
	var cv := ChunkView.new()
	world.chunks[Vector2i.ZERO] = cv
	cv.tile_ids.resize(ChunkView.SIZE * ChunkView.SIZE)
	cv.tile_ids.fill(1)
	cv.tile_ids[3 * ChunkView.SIZE + 5] = 2  # water at (5, 3)
	m.handle({"t": "eprops", "l": [[2, 5, 0, 0], [4, 10, 0, 0], [5, 0, 7.5, 2.5]]})
	m.handle({"t": "iuse", "part": 1, "parts": 1, "l": [["concrete", "t", "concrete", "", [1]],
		["hazard-concrete", "t", "hazard-concrete-left", "hazard-concrete-right", [1, 3]], ["grenade", "c", "throw", 15, 6.5],
		["rail", "r", "rail-support", 1], ["transport-belt", "b", "underground-belt"], ["pipe", "p", "pipe-to-ground"]]})
	check(m.item_uses["concrete"]["t"][2].has(1) and not m.item_uses["concrete"]["t"][2].has(2) and m.item_uses["grenade"]["c"][1] == 15.0
		and m.item_uses["rail"]["r"] == ["rail-support", 1] and m.item_uses["pipe"]["p"] == "pipe-to-ground", "iuse is read into item_uses")
	var had_slots: bool = m.has_slots
	m.has_slots = false
	hud.set_inventory([["concrete", 50], ["grenade", 5], ["rail", 100], ["rail-support", 5], ["transport-belt", 50],
		["underground-belt", 10], ["pipe", 50], ["pipe-to-ground", 10], ["small-electric-pole", 10], ["stone-furnace", 10]])
	var input := PlayerInput.new()
	input.world = world
	input.hud = hud
	for tool in [input.tile_brush, input.rail_planner, input.capsule_aim]:
		tool.pi = input
		add_child(tool)
	input.drag.pi = input
	sent()
	# Issue #10: the right button mines the train under the mouse by its unit number, not the rail
	# the world's pick finds under it (which the mod refused: "Can't mine that").
	var mine_movers := MoverLayer.new()
	mine_movers.protos = world.protos
	add_child(mine_movers)
	input.movers = mine_movers
	world.protos.add_entities([[9901, "test-locomotive", "locomotive", -1, -3, 1, 3, 0, 0, 0, 2, 6]])
	input.hovered = null
	input.hovered_mover = [900, 9901, Vector2i(60 * 256, 60 * 256), Vector2(60, 60), Vector2(1, 3), 0.0]
	input.has_ground = true
	input.ground = Vector2(60, 60)
	input._rmb_down = true
	input._mine_timer = 0.0
	input._update_mining(0.1)
	var train_mine := sent_one("mine")
	input._rmb_down = false
	input._update_mining(0.1)
	# Issue #13: Q over a train or wagon picks its item, turned the way it faces (a ghost cursor
	# when there are none); a blueprint's rolling stock faces by its orientation.
	world.protos.item_places["test-locomotive-item"] = "test-locomotive"
	input.hovered_mover = [900, 9901, Vector2i(60 * 256, 60 * 256), Vector2(60, 60), Vector2(1, 3), Visuals.orientation_yaw(0.25)]
	input._pipette_or_clear()
	var piped_item := input.cursor_item
	var piped_dir := input.build_dir
	hud.ui.clear_cursor()
	input.hold("")
	input.build_dir = 0
	world.protos.item_places.erase("test-locomotive-item")
	check(piped_item == "test-locomotive-item" and piped_dir == 4,
		"#13: Q over a locomotive picks its item, facing its way (east): %s %d" % [piped_item, piped_dir])
	check(PlayerInput.yaw_direction(Visuals.orientation_yaw(0.5)) == 8 and PlayerInput.yaw_direction(Visuals.orientation_yaw(0.875)) == 14
		and PLANNER_UI.entity_direction({"name": "cargo-wagon", "orientation": 0.25}) == 4
		and PLANNER_UI.entity_direction({"name": "cargo-wagon", "orientation": 0.5}) == 8
		and PLANNER_UI.entity_direction({"name": "inserter", "direction": 12}) == 12,
		"#13: movers' yaw and blueprint rolling stock's orientation give 16-way directions")
	# N2: Ctrl+click on a vehicle puts the held stack into it (or takes with an empty hand): the
	# vehicle goes by its unit number, where the world's pick found the ground under it and sent nothing.
	world.protos.add_entities([[9902, "test-car", "car", -1, -1.5, 1, 1.5, 0, 0, 0, 2, 3]])
	sent()
	input.hold("pipe")
	input.hovered_mover = [901, 9902, Vector2i(62 * 256, 60 * 256), Vector2(62, 60), Vector2(1, 1.5), 0.0]
	input.ground = Vector2(62, 60)
	input._fast_target = null
	input._fast_transfer(false)
	var car_put := sent_one("fast")
	input.hold("")
	input._fast_target = null
	input.hovered_mover = [900, 9901, Vector2i(60 * 256, 60 * 256), Vector2(60, 60), Vector2(1, 3), 0.0]
	input.ground = Vector2(60, 60)
	input._fast_transfer(true)
	var loco_take := sent_one("fast")
	input._fast_target = null
	check(int(car_put.get("u", 0)) == 901 and int(car_put.get("p", 0)) == 9902 and str(car_put.get("item", "")) == "pipe"
		and int(car_put.get("x", 0)) == 62 * 256 and int(loco_take.get("u", 0)) == 900 and not loco_take.has("item")
		and int(loco_take.get("half", 0)) == 1,
		"N2: Ctrl+click on a car sends the car with the held stack, Ctrl+right click on a locomotive takes half: %s %s" % [car_put, loco_take])
	input.hovered_mover = []
	input.movers = null
	mine_movers.queue_free()
	# J26: sweeping the mouse over belts with the button held sends each new one under it at once (it
	# waited for the next repeat, 0.15 s, so belts the sweep crossed went unsent), with where the cursor
	# is from the character for the bridge's sweep; over nothing, only where it is.
	world._add([9921, 1, 20 * 256 + 128, 28 * 256 + 128, 4])
	world._add([9922, 1, 21 * 256 + 128, 28 * 256 + 128, 4])
	sent()
	input.character_at_for_test = Vector2(18, 30)
	input._rmb_down = true
	input._mine_timer = 0.0
	for at in [Vector2(20.5, 28.5), Vector2(21.4, 28.6), Vector2(21.6, 28.4), Vector2(24.5, 28.5)]:
		input.ground = at
		input._update_mining(0.016)
	var sweep_mines: Array = sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "mine")
	input._rmb_down = false
	input._update_mining(0.016)
	var swept_stop := sent().any(func(c: Dictionary) -> bool: return c.get("t") == "mine_stop")
	input.character_at_for_test = Vector2.INF
	world._remove(9921)
	world._remove(9922)
	check(sweep_mines.size() == 3 and int(sweep_mines[0].get("u", 0)) == 9921 and int(sweep_mines[1].get("u", 0)) == 9922
		and int(sweep_mines[0].get("ox", 0)) == 640 and int(sweep_mines[0].get("oy", 0)) == -384
		and int(sweep_mines[2].get("n", 0)) == 1 and int(sweep_mines[2].get("ox", 0)) == 1664 and swept_stop,
		"J26: a sweep sends each new belt under the mouse at once with the cursor's offset, then where it is over nothing: %s" % [sweep_mines])
	check(int(train_mine.get("u", 0)) == 900 and int(train_mine.get("p", 0)) == 9901,
		"#10: the right button mines the locomotive under the mouse by its unit number: %s" % [train_mine])
	check(PlayerInput.MINEABLE_MOVERS.has("fluid-wagon") and PlayerInput.MINEABLE_MOVERS.has("cargo-wagon")
		and PlayerInput.MINEABLE_MOVERS.has("artillery-wagon") and PlayerInput.MINEABLE_MOVERS.has("car")
		and PlayerInput.MINEABLE_MOVERS.has("spider-vehicle"), "#10: every vehicle and wagon can be mined")
	# Issue #2: the rocket item is named like the rocket projectile, which it doesn't build. Q over
	# a turret's rockets with none in the inventory held a "rocket" to build, so clicks tried to
	# build it and the turret couldn't be opened. Neither the mod's "" nor an old mod's plain
	# record makes it buildable; Q then says there are none and leaves the cursor empty.
	world.protos.add_entities([[9902, "rocket", "projectile", -0.1, -0.1, 0.1, 0.1, 0, 0, 0, 1, 1]])
	world.protos.add_items([[9903, "rocket"]])
	var old_mod := world.protos.placed_entity("rocket")
	world.protos.add_items([[9903, "rocket", ""]])
	check(old_mod == null and world.protos.placed_entity("rocket") == null and world.protos.placed_entity("wooden-chest") != null,
		"#2: the rocket item builds nothing (not its projectile)")
	var hud_player = hud.ui.player
	hud.ui.player = input
	var slot := Hud.FactorioUi.Slot.new()
	slot.filter_item = "rocket"
	var piped: bool = hud.ui.pipette_slot(slot)
	check(piped and input.cursor_item == "",
		"#2: Q over a turret's rocket slot with no rockets holds nothing to build: %s '%s'" % [piped, input.cursor_item])
	slot.free()
	hud.ui.player = hud_player
	input.hold("")
	# Issue #12: held rolling stock is previewed where the mod builds it, on the nearest straight
	# rail (green there), not blocked by that rail; off the rails it is red with the reason.
	world._add([9911, 7, 11 * 256, 11 * 256, 0, {}])
	world._add([9912, 7, 21 * 256, 11 * 256, 4, {}])
	var on_ns := input.rolling_stock_spot(Vector2(12.2, 10.4), 8)
	var on_ew := input.rolling_stock_spot(Vector2(20.0, 12.5), 0)
	var off_rail := input.rolling_stock_spot(Vector2(16.0, 20.0), 0)
	check(on_ns.size() == 2 and on_ns[0] == Vector2(11, 11) and int(on_ns[1]) == 8
		and on_ew.size() == 2 and on_ew[0] == Vector2(21, 11) and int(on_ew[1]) == 4 and off_rail.is_empty(),
		"#12: rolling stock goes on the nearest rail, facing along it: %s %s %s" % [on_ns, on_ew, off_rail])
	var loco_proto: ProtoDB.EntityProto = world.protos.entity(9901)
	check(input._blocked(loco_proto, Vector2(11, 11), Vector2i(2, 6)) and PlayerInput.ROLLING_STOCK.has("locomotive")
		and PlayerInput.ROLLING_STOCK.has("fluid-wagon"),
		"#12: the rail is what _blocked sees under a train, so rolling stock skips that check (red over rails before)")
	world._remove(9911)
	world._remove(9912)
	sent()
	# D10: from the remote view an open asks the mod for remote use (rv); from the character's view not.
	hud.ui.remote = true
	input._request_open(77, {"t": "open", "u": 77, "p": 1, "x": 0, "y": 0})
	await get_tree().process_frame
	var remote_open := sent_one("open")
	hud.ui.remote = false
	input._request_open(77, {"t": "open", "u": 77, "p": 1, "x": 0, "y": 0})
	await get_tree().process_frame
	var near_open := sent_one("open")
	check(remote_open.get("rv") == 1 and not near_open.has("rv"), "opening from the remote view asks for remote use (rv, D10): %s %s" % [remote_open, near_open])
	hud.screen.close_local()
	sent()
	# F6: a module held and clicked on a building (or ghost) asks the mod for it (modreq), from the
	# remote view too; the click doesn't build or open anything.
	m.handle({"t": "iuse", "part": 2, "parts": 2, "l": [["speed-module", "m", "speed"]]})
	var machine := WorldMirror.Rec.new()
	machine.unit = 91
	machine.proto_id = 8
	machine.pos = Vector2(3, 3)
	machine.fixed = Vector2i(768, 768)
	input.cursor_item = "speed-module"
	input.hovered = machine
	input.has_ground = true
	input.ground = Vector2(3, 3)
	hud.ui.remote = true
	var mclick := InputEventMouseButton.new()
	mclick.button_index = MOUSE_BUTTON_LEFT
	mclick.pressed = true
	input._mouse_button(mclick)
	await get_tree().process_frame
	var mods_sent := sent()
	hud.ui.remote = false
	# By kind, not by count: a blueprint request from earlier is sent again after RETRY seconds (planner_model.gd; no game answers here), and can land in the same frame.
	var modreqs := mods_sent.filter(func(c: Dictionary) -> bool: return c.get("t") == "modreq")
	var click_also := mods_sent.filter(func(c: Dictionary) -> bool: return c.get("t") in ["build", "open", "ghost", "decon"])
	var modreq: Dictionary = modreqs[0] if modreqs.size() == 1 else {}
	check(modreq.get("item") == "speed-module" and int(modreq.get("u", 0)) == 91 and click_also.is_empty()
		and int(modreq.get("x", 0)) == 768 and not input._lmb_down, "a module clicked on a building asks for it (modreq, F6): %s" % [mods_sent])
	input.cursor_item = ""
	input.hovered = null
	# F6: the build preview is red over empty space (a platform's edge), with the reason.
	world.protos.add_tiles([[4, "empty-space", 0, 0, 0]])
	cv.tile_ids[3 * ChunkView.SIZE + 8] = 4  # empty space at (8, 3)
	check(input._on_void(Vector2(8.5, 3.5), Vector2i.ONE) and input._on_void(Vector2(8.0, 3.0), Vector2i(2, 2))
		and not input._on_void(Vector2(10.5, 3.5), Vector2i.ONE), "the build preview knows empty space under a footprint (F6)")
	cv.tile_ids[3 * ChunkView.SIZE + 8] = 1
	# F6: a ghost is picked by its entity's box (2.1.23's entity-ghost prototype has none), so a
	# module can be clicked onto a furnace's ghost anywhere on it.
	world.protos.add_entities([[9, "entity-ghost", "entity-ghost", 0, 0, 0, 0, 200, 200, 200, 1, 1]])
	world._add([95, 9, 7 * 256, 7 * 256, 0, {"gh": 8}])
	var picked: WorldMirror.Rec = world.pick(Vector2(7.7, 6.4))
	check(picked != null and picked.unit == 95 and world.pick(Vector2(8.2, 7.0)) == null, "a ghost is picked by its entity's box (F6)")
	world._remove(95)
	# G12: hovering a beacon asks the mod about it (hinfo); the entity info then lists its modules,
	# effectivity, the machines it reaches and what it hands on; a machine its beacons and effects.
	world.protos.add_entities([[10, "beacon", "beacon", -1.5, -1.5, 1.5, 1.5, 130, 120, 130, 3, 3],
		[11, "assembling-machine-2", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 110, 140, 170, 3, 3]])
	var brec := WorldMirror.Rec.new()
	brec.key = 96
	brec.unit = 96
	brec.proto_id = 10
	brec.fixed = Vector2i(2560, 768)
	var einfo = hud.ui.entity_info
	var einfo_player = einfo.player
	einfo.player = input
	sent()
	einfo.show_entity(brec)
	var hask := sent_one("hinfo")
	m.handle({"t": "hinfo", "q": int(hask.get("q", 0)), "u": 96, "eff": {"sp": 1500, "co": 2100, "q": -25}, "m": [["speed-module-3", 2]],
		"n": 3, "de": 1500})
	einfo.show_entity(brec)
	var btext := "|".join(PackedStringArray(_texts(einfo._lines))).replace(":| ", ": ")
	check(int(hask.get("u", 0)) == 96 and int(hask.get("x", 0)) == 2560 and btext.contains("Modules:") and btext.contains("x2")
		and btext.contains("Distribution effectivity: 150%") and btext.contains("Machines affected: 3")
		and btext.contains("Module effects:") and btext.contains("Speed: +150%") and btext.contains("Consumption: +210%") and btext.contains("Quality: -2.5%"),
		"hovering a beacon asks hinfo and shows what it hands on (G12): %s %s" % [hask, btext])
	einfo.show_entity(brec)
	check(sent_one("hinfo").is_empty(), "the same beacon isn't asked about again within a second")
	var arec := WorldMirror.Rec.new()
	arec.key = 97
	arec.unit = 97
	arec.proto_id = 11
	arec.fixed = Vector2i(768, 768)
	einfo.show_entity(arec)
	var aask := sent_one("hinfo")
	m.handle({"t": "hinfo", "q": int(aask.get("q", 0)) - 1, "u": 96, "eff": {"sp": 1}})
	check(m.hover_info.is_empty(), "an answer about an entity no longer hovered is dropped")
	m.handle({"t": "hinfo", "q": int(aask.get("q", 0)), "u": 97, "eff": {"sp": 3000, "co": 4200}, "b": 2})
	einfo.show_entity(arec)
	var atext := "|".join(PackedStringArray(_texts(einfo._lines))).replace(":| ", ": ")
	check(int(aask.get("u", 0)) == 97 and atext.contains("Beacons: 2") and atext.contains("Speed: +300%") and not atext.contains("Machines affected"),
		"hovering a machine shows the beacons reaching it and its effects (G12): %s" % atext)
	# H20: an electric machine's "Consumes electricity": Max. and Min. consumption from the mod's
	# hinfo (with its modules) and the Electricity bar from its buffer, at the panel's foot.
	m.pedia_pages["entity/assembling-machine-2"] = {"found": true, "d": {"etype": "electric", "energy": 150000.0, "drain": 5000.0, "hp": 350}}
	m.handle({"t": "hinfo", "q": m._hinfo_q, "u": 97, "eff": {"sp": 3000, "co": 4200}, "b": 2,
		"el": {"e": 2500, "b": 5000, "mx": 155000, "mn": 5000}})
	einfo.show_entity(arec)
	var etext := "|".join(PackedStringArray(_texts(einfo._lines))).replace(":| ", ": ")
	var ebar = einfo._lines.find_child("Electricity", true, false)
	check(etext.contains("Consumes electricity") and etext.contains("Max. consumption: 155 kW") and etext.contains("Min. consumption: 5.0 kW")
		and not etext.contains("Energy consumption") and ebar is ProgressBar and int(ebar.value) == 500
		and etext.find("Consumes electricity") > etext.find("Health"),
		"a powered machine's entity info ends with Consumes electricity and its Electricity bar (H20): %s" % etext)
	check(EntityInfoScript.power_text(217000.0) == "217 kW" and EntityInfoScript.power_text(7000.0) == "7.0 kW"
		and EntityInfoScript.power_text(1.2e6) == "1.2 MW", "power written as Factorio's entity info writes it")
	# J15: a crafting machine's ingredients and products a second (`hinfo` io), under their headings.
	m.handle({"t": "hinfo", "q": m._hinfo_q, "u": 97, "eff": {"sp": 3000, "co": 4200}, "b": 2,
		"io": {"i": [["item", "iron-plate", 2500]], "o": [["item", "iron-gear-wheel", 1250], ["fluid", "steam", 60000]]}})
	einfo.show_entity(arec)
	var iotext := "|".join(PackedStringArray(_texts(einfo._lines)))
	check(iotext.contains("Ingredients:") and iotext.contains("Products:") and iotext.contains("2.5/s") and iotext.contains("1.25/s")
		and iotext.contains("60/s") and iotext.find("Ingredients:") < iotext.find("Products:")
		and iotext.find("Products:") < iotext.find("Health"),
		"J15: hovering a machine shows its ingredients and products a second: %s" % iotext)
	check(EntityInfoScript.rate_text(2000) == "2/s" and EntityInfoScript.rate_text(750) == "0.75/s" and EntityInfoScript.rate_text(1500) == "1.5/s"
		and EntityInfoScript.rate_text(4) == "<0.01/s" and EntityInfoScript.rate_text(16667) == "16.67/s",
		"rates written as Factorio's tooltips write them: %s" % [[EntityInfoScript.rate_text(2000), EntityInfoScript.rate_text(750), EntityInfoScript.rate_text(16667)]])
	m.pedia_pages.erase("entity/assembling-machine-2")
	einfo.show_entity(null)
	einfo.player = einfo_player
	# B7: W walks the way the camera looks, at any angle (`a`, thousandths of a turn), with the
	# nearest of Factorio's 8 directions as `d` for mods without `a`; letting go stops.
	var walk_rig := CameraRig.new()
	add_child(walk_rig)
	walk_rig.rotation.y = 0.37
	await get_tree().process_frame
	input.rig = walk_rig
	get_viewport().gui_release_focus()  # a search box from the checks above would take the keys
	Input.action_press("move_up")
	input._update_walk(0.016)
	Input.action_release("move_up")
	await get_tree().process_frame
	var walk_go := sent_one("walk")
	input._update_walk(0.016)
	await get_tree().process_frame
	var walk_stop := sent_one("walk")
	var fwd := walk_rig.ground_forward()
	var want_turn := posmod(roundi(atan2(fwd.x, -fwd.z) / TAU * 1000.0), 1000)
	check(int(walk_go.get("a", -1)) == want_turn and want_turn % 125 != 0 and int(walk_go.get("d", -1)) == posmod(roundi(want_turn / 125.0), 8) * 2
		and int(walk_stop.get("d", 0)) == -1 and not walk_stop.has("a"),
		"WASD walks at the camera's angle (a) and stops on release (B7): %s %s, want %d" % [walk_go, walk_stop, want_turn])
	# The stick walks only for a pad Godot maps as a gamepad, once it was seen centred: the owner's
	# Thrustmaster sim pedals (unknown to Godot, axes resting at -1) walked the bridge's character
	# off for as long as the client ran, with no key pressed.
	var centred := {}
	var pedals := [{"id": 0, "known": false, "v": Vector2(-1, 1)}]
	var pad_rest := [{"id": 1, "known": true, "v": Vector2(0.03, -0.02)}]
	var pad_push := [{"id": 1, "known": true, "v": Vector2(0.9, 0.1)}]
	var stick_seen := [PlayerInput.stick_of(pedals, centred), PlayerInput.stick_of(pad_push, centred),
		PlayerInput.stick_of(pad_rest, centred), PlayerInput.stick_of(pad_push, centred),
		PlayerInput.stick_of(pedals, centred), PlayerInput.stick_of(pad_push, centred)]
	check(stick_seen == [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2(0.9, 0.1), Vector2.ZERO, Vector2.ZERO],
		"the stick walks only on a mapped gamepad once seen centred, never an unknown device's axes (sim pedals at -1), and starts unseen once unplugged: %s" % [stick_seen])
	input.joypads_for_test = pedals
	sent()
	for i in 20:
		input._update_walk(0.05)
	await get_tree().process_frame
	var pedal_walk := sent_one("walk")
	input.joypads_for_test = pad_rest
	input._update_walk(0.05)
	input.joypads_for_test = pad_push
	input._update_walk(0.05)
	input.joypads_for_test = pad_rest
	input._update_walk(0.05)
	await get_tree().process_frame
	var pad_walks := sent().filter(func(m): return m.get("t", "") == "walk")
	check(pedal_walk.is_empty() and pad_walks.size() == 2 and int(pad_walks[0].get("d", -1)) >= 0 and pad_walks[0].has("a")
		and int(pad_walks[1].get("d", 0)) == -1,
		"sim pedals plugged in send no walk with nothing pressed; a gamepad's stick walks and stops: %s %s" % [pedal_walk, pad_walks])
	input.joypads_for_test = null
	input.rig = null
	walk_rig.queue_free()

	# --- tiles --------------------------------------------------------------------------------------
	check(TileBrush.brush(Vector2(4.6, 3.6), 2) == [Vector2i(4, 3), Vector2i(5, 3), Vector2i(4, 4), Vector2i(5, 4)]
		and TileBrush.brush(Vector2(4.6, 3.6), 3)[0] == Vector2i(3, 2), "the brush: even sizes on the nearest corner, odd ones on the tile (as tiles.lua)")
	input.tile_brush.size = 2
	var states := input.tile_brush.tile_states("concrete", Vector2(4.6, 3.6), false)
	var by_tile := {}
	for st in states:
		by_tile[st[0]] = st[1]
	check(by_tile[Vector2i(5, 3)] == "bad" and by_tile[Vector2i(4, 3)] == "ok", "the brush is red on water (iuse's tiles it may go on), green elsewhere")
	input.cursor_item = "concrete"
	for code in [KEY_KP_ADD, KEY_KP_ADD, KEY_KP_SUBTRACT]:
		var ev := Controls.key_event(code)
		ev.pressed = true
		input._unhandled_input(ev)
	check(input.tile_brush.size == 3, "Numpad + / - make the tile area larger and smaller")
	input.tile_brush.size = 2
	input.tile_brush.paint("concrete", Vector2(4.6, 3.6), false, 0.016)
	await get_tree().process_frame
	var t := sent_one("tile")
	check(t.get("item") == "concrete" and int(t.get("n", 0)) == 2 and not t.has("ghost"), "holding the button paints: `tile` with the brush size")
	input.tile_brush.mine(Vector2(4.6, 3.6), 1.0)
	await get_tree().process_frame
	check(int(sent_one("tile_mine").get("n", 0)) == 2, "the right button mines the tiles under the brush")
	input.cursor_item = "hazard-concrete"
	input._rotate(false)
	input.tile_brush.paint("hazard-concrete", Vector2(8.5, 3.5), true, 1.0)
	await get_tree().process_frame
	t = sent_one("tile")
	check(int(t.get("r", 0)) == 1 and int(t.get("ghost", 0)) == 1, "R turns hazard concrete's stripes; Shift paints tile ghosts")
	input.tile_brush.update_preview("hazard-concrete", true, Vector2(8.5, 3.5), false, false)
	check(input.tile_brush.visible and input.tile_brush.preview_counts()["shown"] == 4, "the brush is drawn at the cursor")
	input.tile_brush.update_preview("transport-belt", true, Vector2(8.5, 3.5), false, false)
	check(not input.tile_brush.visible, "and not for other items")

	# --- capsules -----------------------------------------------------------------------------------
	input.capsule_aim.hold("grenade", Vector2(3, 3), 0.016)
	await get_tree().process_frame
	var th := sent_one("throw")
	check(th.get("item") == "grenade" and int(th.get("x", 0)) == 768, "a click throws the capsule at the cursor (`throw`)")
	input.capsule_aim.hold("grenade", Vector2(3, 3), 0.1)
	await get_tree().process_frame
	check(sent_one("throw").is_empty(), "held, it throws again only after the capsule's cooldown")

	# --- the rail planner ---------------------------------------------------------------------------
	world._add([60, 7, 1 * 256, 1 * 256, 0])  # a north-south straight rail on (1, 1): ends (1, 0) north, (1, 2) south
	var end_n := input.rail_planner.nearest_end(Vector2(1.4, -0.6))
	check(end_n.size() == 3 and end_n[0] == Vector2i(1, 0) and int(end_n[1]) == 0, "the rail end nearest the cursor is found: %s" % [end_n])
	var straight := RailPlanner.find_path(Vector2i(1, 0), 0, 0, Vector2(1, -10))
	check(straight.size() == 5 and straight.all(func(p): return p["name"] == "straight-rail"), "straight ahead the path is straight rails")
	var bend := RailPlanner.find_path(Vector2i(1, 0), 0, 0, Vector2(12, -20))
	var joined := true
	var at := Vector2i(1, 0)
	var dir := 0
	var ext: Dictionary = RailPlanner.data()["ext"]
	for p in bend:
		var found := false
		for e in ext[str(dir)]:
			if str(e[0]) == p["name"] and int(e[1]) == p["dir"] and at + Vector2i(int(e[2]), int(e[3])) == p["pos"]:
				found = true
		joined = joined and found
		at = p["end"][0]
		dir = p["end"][1]
	check(not bend.is_empty() and joined and Vector2(at).distance_to(Vector2(12, -20)) <= 1.2
		and bend.any(func(p): return str(p["name"]).begins_with("curved")), "a path that turns: each piece one of Factorio's extensions from the last end")
	var t0 := Time.get_ticks_usec()
	var far := RailPlanner.find_path(Vector2i(1, 0), 0, 0, Vector2(60, -70))
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	check(not far.is_empty() and ms < 100.0, "a long winding path is found quickly (%.1f ms, %d pieces)" % [ms, far.size()])
	input.cursor_item = "rail"
	# D2: Factorio's green arrows mark the free rail ends near the cursor before anchoring.
	input.rail_planner.update("rail", true, Vector2(2, 1), false)
	var free_arrows: Array = input.rail_planner.arrows.duplicate()
	check(not free_arrows.is_empty() and free_arrows.all(func(e): return e[3] == "free")
		and free_arrows.any(func(e): return e[0] == Vector2i(1, 0)) and input.rail_planner._arrows[0].visible,
		"holding rails shows Factorio's arrows at the free rail ends near the cursor (D2): %s" % [free_arrows])
	check(input.rail_planner.click("rail", Vector2(1.2, -0.4), false) and input.rail_planner.anchor["pos"] == Vector2i(1, 0),
		"a click by a free rail end anchors the planner there")
	input.rail_planner.update("rail", true, Vector2(1, -10), false)
	check(input.rail_planner.arrows.size() == 1 and input.rail_planner.arrows[0][3] == "anchored",
		"once anchored only the anchored end's arrow is drawn")
	check(input.rail_planner.path.size() == 5 and input.rail_planner.rails_needed() == 5, "the path to the cursor is planned (5 rails)")
	# Shift pressed or let go with the mouse still: the planned rails turn ghost blue and back at once.
	var states_of := func() -> Array: return input.rail_planner.path.map(func(p): return str(p["state"]))
	var paid_states: Array = states_of.call()
	input.rail_planner.update("rail", true, Vector2(1, -10), true)
	var shift_states: Array = states_of.call()
	input.rail_planner.update("rail", true, Vector2(1, -10), false)
	check(paid_states.has("ok") and shift_states.size() == 5 and shift_states.all(func(s): return s == "ghost") and states_of.call() == paid_states,
		"the rail planner's path follows Shift with the mouse still: %s, %s, %s" % [paid_states, shift_states, states_of.call()])
	input.rail_planner.click("rail", Vector2(1, -10), false)
	await get_tree().process_frame
	var rails := sent_one("rails")
	check(rails.get("item") == "rail" and (rails.get("l", []) as Array).size() == 5 and input.rail_planner.anchor["pos"] == Vector2i(1, -10),
		"a second click builds it (`rails`) and the planner carries on from its end")
	input.rail_planner.toggle_layer()
	input.rail_planner.update("rail", true, Vector2(1, -40), false)
	var names: Array = input.rail_planner.path.map(func(p): return str(p["name"]))
	check(names.has("rail-ramp") and names.has("rail-support") and names.has("elevated-straight-rail") and names[0] == "rail-support",
		"toggle rail layer: a ramp up, elevated rails, their supports listed first: %s" % [names])
	# Issue #26: G is Factorio 2.1's rail layer and its getting-in alternative (Controls.SHARED), pressed through
	# player_input: with rails in hand it changes the layer and gets in nothing; without, it gets in.
	var g := Controls.key_event(KEY_G)
	g.pressed = true
	var g_added: Array = []
	for action in ["toggle_rail_layer", "enter_vehicle"]:
		if not g.is_action_pressed(action, false, true):
			InputMap.action_add_event(action, g)
			g_added.append(action)
	sent()
	var layer_was: int = input.rail_planner.target_layer
	input._unhandled_input(g)
	var g_rails := [input.rail_planner.target_layer, sent_one("enter").is_empty()]
	input._unhandled_input(g)
	var g_back: int = input.rail_planner.target_layer
	input.cursor_item = ""
	var g_avatar_was: Avatar = input.avatar
	var g_body := Avatar.new()  # on foot, far from any rocket silo
	g_body.position = Vector3(500.5, 0.0, 500.5)
	input.avatar = g_body
	input._unhandled_input(g)
	var g_enter := [input.rail_planner.target_layer, sent_one("enter").is_empty()]
	input.avatar = g_avatar_was
	g_body.free()
	input.cursor_item = "rail"
	for action in g_added:
		InputMap.action_erase_event(action, g)
	check(g_rails == [1 - layer_was, true] and g_back == layer_was and g_enter == [layer_was, false],
		"#26: G with rails in hand toggles the rail layer (no vehicle entered), without them gets in: %s %s %s" % [g_rails, g_back, g_enter])
	input.rail_planner.clear()
	check(not input.rail_planner.click("rail", Vector2(20, 20), false), "away from a rail end a click builds a plain straight rail")
	# Issue #15: a line forks off an existing one. Two straight rails meet at (25, 26): no free end
	# there, but a click on the line anchors at that joint, and the path leaves it whichever way
	# along the line faces the cursor, turning off it.
	world._add([61, 7, 25 * 256, 25 * 256, 0])
	world._add([62, 7, 25 * 256, 27 * 256, 0])
	var joint_free := input.rail_planner.free_ends(Vector2(25, 26), 0.5)
	check(joint_free.is_empty() and input.rail_planner.click("rail", Vector2(25.3, 26.4), false)
		and input.rail_planner.anchor.get("pos") == Vector2i(25, 26) and input.rail_planner.anchor.get("fork", false),
		"#15: a click on a line where two rails meet anchors the planner there: %s %s" % [joint_free, input.rail_planner.anchor])
	input.rail_planner.update("rail", true, Vector2(38, 14), false)
	var fork_north: Array = input.rail_planner.path.duplicate()
	input.rail_planner.update("rail", true, Vector2(38, 40), false)
	var fork_south: Array = input.rail_planner.path.duplicate()
	var first_curves := func(p: Array) -> bool: return not p.is_empty() and str(p[0]["name"]).begins_with("curved")
	check(first_curves.call(fork_north) and first_curves.call(fork_south) and int(fork_north[0]["pos"].y) < 26 and int(fork_south[0]["pos"].y) > 26,
		"#15: from the joint the new line turns off towards the cursor, north or south: %s / %s" % [fork_north.slice(0, 1), fork_south.slice(0, 1)])
	input.rail_planner.update("rail", true, Vector2(38, 14), false)
	input.rail_planner.click("rail", Vector2(38, 14), false)
	await get_tree().process_frame
	var fork_cmd := sent_one("rails")
	check(not fork_north.is_empty() and (fork_cmd.get("l", []) as Array).size() == fork_north.size() and not input.rail_planner.anchor.get("fork", false),
		"#15: the fork is built (`rails`) and the planner carries on from its end")
	input.rail_planner.clear()
	world._remove(61)
	world._remove(62)

	# --- drag building ------------------------------------------------------------------------------
	var belt: ProtoDB.EntityProto = world.protos.entity(1)
	input.cursor_item = "transport-belt"
	var lock_was: Variant = Settings.get_value("interface", "lock_belt_straight")
	var belt_steps := func() -> Array: return input.drag.sent.map(func(c): return [int(c["x"]) / 256, int(c["y"]) / 256, int(c["d"])])
	var steps: Array
	# J25, the owner's motion through the build button: a belt held facing east (as an east drag
	# leaves it) dragged west builds the line backwards, every belt facing east, as Factorio does. It
	# built them facing west, the way of the drag.
	Settings.set_value("interface", "lock_belt_straight", true, false)
	input.build_dir = 4
	input.has_ground = true
	input._lmb_down = true
	for x in [40.5, 39.5, 37.6, 36.5]:
		input.ground = Vector2(x, 14.4)
		input._update_building()
	steps = belt_steps.call()
	input._lmb_down = false
	input.drag.end()
	check(steps == [[40, 14, 4], [39, 14, 4], [38, 14, 4], [37, 14, 4], [36, 14, 4]] and input.build_dir == 4,
		"J25: a belt held facing east dragged west builds the line backwards, facing east: %s" % [steps])
	# Factorio 2.x keeps the drag to the held belt's line: forward ahead of the start, backwards behind
	# it, nothing off the line, nothing going back over what was built.
	input.drag.begin("transport-belt", belt, Vector2(10.5, 10.5), false)
	input.drag.update(Vector2(13.5, 10.5))
	input.drag.update(Vector2(13.5, 7.5))
	input.drag.update(Vector2(11.5, 10.5))
	input.drag.update(Vector2(8.5, 11.2))
	steps = belt_steps.call()
	input.drag.end()
	check(steps == [[10, 10, 4], [11, 10, 4], [12, 10, 4], [13, 10, 4], [9, 10, 4], [8, 10, 4]],
		"J25: a locked belt drag goes along the held belt's line both ways, facing the held way, nothing off it or back over it: %s" % [steps])
	# R while dragging: the line turns at its last belt towards the cursor and is built out to it.
	# Forward the last belt turns the new way; backwards it stays and the new belts flow into it.
	input.drag.begin("transport-belt", belt, Vector2(40.5, 18.5), false)
	input.drag.update(Vector2(44.5, 18.5))
	input.ground = Vector2(44.5, 21.5)
	input.drag.update(input.ground)
	input._rotate(false)
	steps = belt_steps.call()
	var bent_dir := input.build_dir
	input.drag.end()
	check(steps.slice(5) == [[44, 18, 8], [44, 19, 8], [44, 20, 8], [44, 21, 8]] and steps.size() == 9 and bent_dir == 8,
		"J25: R while dragging east with the cursor south turns the last belt south and builds to the cursor: %s" % [steps])
	input.build_dir = 4
	input.drag.begin("transport-belt", belt, Vector2(60.5, 18.5), false)
	input.drag.update(Vector2(57.5, 18.5))
	input.ground = Vector2(57.5, 15.5)
	input._rotate(false)
	steps = belt_steps.call()
	bent_dir = input.build_dir
	input.drag.end()
	check(steps == [[60, 18, 4], [59, 18, 4], [58, 18, 4], [57, 18, 4], [57, 17, 8], [57, 16, 8], [57, 15, 8]] and bent_dir == 8,
		"J25: R in a backwards drag leaves the last belt and builds the new ones flowing into it: %s" % [steps])
	input.build_dir = 4
	input.drag.begin("transport-belt", belt, Vector2(60.5, 22.5), false)
	input.ground = Vector2(60.5, 22.5)
	input._rotate(true)
	steps = belt_steps.call()
	input.drag.end()
	check(steps == [[60, 22, 4], [60, 22, 0]] and input.build_dir == 0,
		"J25: with the cursor on the line Shift+R turns the first belt a quarter back: %s" % [steps])
	# Smart belt building backwards: the entrance goes past the obstacle (upstream), sent first, so the
	# one replacing the last belt before it becomes the exit.
	world._add([66, 6, 29 * 256 + 128, 6 * 256 + 128, 0])
	input.build_dir = 4
	input.drag.begin("transport-belt", belt, Vector2(31.5, 6.5), false)
	input.drag.update(Vector2(27.5, 6.5))
	steps = input.drag.sent.map(func(c): return [str(c["item"]), int(c["x"]) / 256, int(c["d"])])
	input.drag.end()
	world._remove(66)
	check(steps == [["transport-belt", 31, 4], ["transport-belt", 30, 4], ["underground-belt", 28, 4], ["underground-belt", 30, 4],
		["transport-belt", 27, 4]], "J25: a backwards drag jumps an obstacle with the entrance upstream: %s" % [steps])
	# "Lock belt building to straight line" off: Zenith's own drag round corners (I12).
	Settings.set_value("interface", "lock_belt_straight", false, false)
	input.build_dir = 4
	input.drag.begin("transport-belt", belt, Vector2(10.5, 10.5), false)
	input.drag.update(Vector2(13.5, 10.5))
	input.drag.update(Vector2(13.5, 7.5))
	steps = belt_steps.call()
	check(steps == [[10, 10, 4], [11, 10, 4], [12, 10, 4], [13, 10, 4], [13, 10, 0], [13, 9, 0], [13, 8, 0], [13, 7, 0]],
		"belts follow the cursor and turn the corner (the belt where it turns points the new way): %s" % [steps])
	input.drag.end()
	# Going back over the line changes nothing (J1's turning round is gone: Factorio doesn't).
	input.build_dir = 4
	input.drag.begin("transport-belt", belt, Vector2(10.5, 12.5), false)
	input.drag.update(Vector2(13.5, 12.5))
	input.drag.update(Vector2(9.5, 12.5))
	steps = belt_steps.call()
	input.drag.end()
	check(steps == [[10, 12, 4], [11, 12, 4], [12, 12, 4], [13, 12, 4]], "J25: following the cursor, going back over the line builds nothing: %s" % [steps])
	# Begun against the held way it goes backwards, round corners too, the new belts flowing in.
	input.build_dir = 4
	input.drag.begin("transport-belt", belt, Vector2(30.5, 12.5), false)
	input.drag.update(Vector2(28.5, 12.5))
	input.drag.update(Vector2(28.5, 9.5))
	steps = belt_steps.call()
	input.drag.end()
	check(steps == [[30, 12, 4], [29, 12, 4], [28, 12, 4], [28, 11, 8], [28, 10, 8], [28, 9, 8]],
		"J25: following the cursor, begun against the held way the belts face back along the drag: %s" % [steps])
	check(DragBuildScript.follow_step(Vector2i(-2, 0), Vector2i(1, 0)) == Vector2i.ZERO
		and DragBuildScript.follow_step(Vector2i(-2, 2), Vector2i(1, 0)) == Vector2i(0, 1),
		"following the cursor: back along the line no step, TURN_SLACK off it a corner")
	Settings.set_value("interface", "lock_belt_straight", lock_was, false)
	world._add([61, 6, 22 * 256 + 128, 10 * 256 + 128, 0])  # a chest in the way
	input.build_dir = 4
	input.drag.begin("transport-belt", belt, Vector2(20.5, 10.5), false)
	input.drag.update(Vector2(23.5, 10.5))
	steps = input.drag.sent.map(func(c): return [str(c["item"]), int(c["x"]) / 256, int(c["d"])])
	check(steps == [["transport-belt", 20, 4], ["transport-belt", 21, 4], ["underground-belt", 21, 4], ["underground-belt", 23, 4]],
		"smart belt building: the last belt before the chest becomes an underground, its exit past it: %s" % [steps])
	input.drag.end()
	world._add([62, 1, 4 * 256 + 128, 24 * 256 + 128, 0])  # a belt crossing the line (north)
	world._add([64, 1, 9 * 256 + 128, 24 * 256 + 128, 4])  # and one along it (east), which is replaced
	input.drag.begin("transport-belt", belt, Vector2(2.5, 24.5), false)
	input.drag.update(Vector2(6.5, 24.5))
	input.drag.update(Vector2(9.5, 24.5))
	steps = input.drag.sent.map(func(c): return [str(c["item"]), int(c["x"]) / 256])
	check(steps.slice(0, 5) == [["transport-belt", 2], ["transport-belt", 3], ["underground-belt", 3], ["underground-belt", 5],
		["transport-belt", 6]] and steps[-1] == ["transport-belt", 9], "a belt line crossing the way is jumped too; one along it is built over: %s" % [steps])
	input.drag.end()
	Settings.set_value("interface", "smart_belt_building", false, false)
	input.drag.begin("transport-belt", belt, Vector2(20.5, 16.5), false)
	world._add([65, 6, 22 * 256 + 128, 16 * 256 + 128, 0])
	input.drag.update(Vector2(24.5, 16.5))
	steps = input.drag.sent.map(func(c): return [str(c["item"]), int(c["x"]) / 256])
	check(steps == [["transport-belt", 20], ["transport-belt", 21], ["transport-belt", 23], ["transport-belt", 24]],
		"without smart belt building the obstacle is just skipped: %s" % [steps])
	Settings.set_value("interface", "smart_belt_building", true, false)
	input.drag.end()
	var pipe: ProtoDB.EntityProto = world.protos.entity(3)
	world._add([63, 6, 24 * 256 + 128, 28 * 256 + 128, 0])
	input.build_dir = 0
	input.drag.begin("pipe", pipe, Vector2(22.5, 28.5), false)
	input.drag.update(Vector2(26.5, 28.5))
	steps = input.drag.sent.map(func(c): return [str(c["item"]), int(c["x"]) / 256, int(c["d"])])
	check(steps.has(["pipe-to-ground", 23, 12]) and steps.has(["pipe-to-ground", 25, 4]) and steps[-1] == ["pipe", 26, 4],
		"pipes drag in a line; pipes-to-ground over the chest, facing back at the entrance and on at the exit: %s" % [steps])
	input.drag.end()
	var pole: ProtoDB.EntityProto = world.protos.entity(5)
	input.drag.begin("small-electric-pole", pole, Vector2(0.5, 20.5), false)
	for x in range(1, 17):
		input.drag.update(Vector2(x + 0.5, 20.5))
	steps = input.drag.sent.map(func(c): return int(c["x"]) / 256)
	check(steps == [0, 7, 14], "poles go along the line at the wire reach (7.5): %s" % [steps])
	input.drag.end()
	# P45: a pole already on the line carries the wire on, and a pole two tiles wide is measured
	# from the grid corner it stands on, not the cursor's tile.
	world.chunks[Vector2i(3, 3)] = ChunkView.new()
	world._add([64, 5, 101 * 256 + 128, 100 * 256 + 128, 0])
	input.drag.begin("small-electric-pole", pole, Vector2(96.5, 100.5), false)
	for x in range(97, 110):
		input.drag.update(Vector2(x + 0.5, 100.5))
	steps = input.drag.sent.map(func(c): return int(c["x"]) / 256)
	check(steps == [96, 108], "P45: an existing pole on the line counts as the last one: %s" % [steps])
	input.drag.end()
	world._remove(64)
	world.protos.add_entities([[9910, "test-big-pole", "electric-pole", -1, -1, 1, 1, 0, 0, 0, 2, 2],
		[9911, "test-underground", "underground-belt", -0.5, -0.5, 0.5, 0.5, 0, 0, 0, 1, 1],
		[9912, "test-pipe-to-ground", "pipe-to-ground", -0.5, -0.5, 0.5, 0.5, 0, 0, 0, 1, 1]])
	m.eprops[9910] = {"wire": 30.0, "under": 0.0, "x": {}}
	m.eprops[9911] = {"wire": 0.0, "under": 5.0, "x": {}}
	m.eprops[9912] = {"wire": 0.0, "under": 11.0, "x": {}}
	# In the inventory: a drag begun with none would build nothing (I5 stops it when they run out).
	hud.set_inventory([["test-big-pole", 10], ["test-underground", 10], ["test-pipe-to-ground", 10], ["stone-furnace", 10]])
	input.build_dir = 0
	input.drag.begin("test-big-pole", world.protos.entity(9910), Vector2(120.7, 100.4), false)
	# I13: the next pole goes once the cursor's path has passed the wire's reach, on its furthest
	# free tile still in reach: the cursor goes two tiles past it.
	for x in range(120, 87, -1):
		input.drag.update(Vector2(x + 0.5, 100.4))
	steps = input.drag.sent.map(func(c): return [float(c["x"]) / 256.0, float(c["y"]) / 256.0])
	check(steps.size() == 2 and steps[1] == [91.0, 100.0], "P45: a two-wide pole's line starts on its grid corner (121), the next at its reach: %s" % [steps])
	input.drag.end()
	var under_steps := func() -> Array: return input.drag.sent.map(func(c): return [int(c["x"]) / 256, int(c["d"])])
	input.build_dir = 0
	input.drag.begin("test-underground", world.protos.entity(9911), Vector2(96.5, 104.5), false)
	check(input.drag.sent.is_empty(), "P45: the first underground waits for the line's direction")
	for x in range(97, 110):
		input.drag.update(Vector2(x + 0.5, 104.5))
	check(under_steps.call() == [[96, 4], [101, 4], [102, 4], [107, 4], [108, 4]] and input.build_dir == 4,
		"P45: undergrounds drag in pairs at their reach, facing along the line: %s" % [under_steps.call()])
	input.drag.update(Vector2(98.5, 104.5))
	input.drag.update(Vector2(109.5, 104.5))
	check(input.drag.sent.size() == 5, "P45: the cursor going back and on again builds nothing more")
	input.drag.end()
	check(input.drag.sent.size() == 5, "P45: letting go after a drag sends nothing more")
	input.build_dir = 8
	# Held (an emptied hand builds nothing on letting go, I5).
	input.cursor_item = "test-underground"
	input.drag.begin("test-underground", world.protos.entity(9911), Vector2(96.5, 108.5), false)
	input.drag.end()
	input.cursor_item = ""
	check(under_steps.call() == [[96, 8]], "P45: a plain click builds one, as held: %s" % [under_steps.call()])
	world._add([65, 6, 111 * 256 + 128, 112 * 256 + 128, 0])  # a chest where the exit would go
	input.build_dir = 0
	input.drag.begin("test-pipe-to-ground", world.protos.entity(9912), Vector2(100.5, 112.5), false)
	for x in range(101, 114):
		input.drag.update(Vector2(x + 0.5, 112.5))
	check(under_steps.call() == [[100, 12], [110, 4], [112, 12]],
		"P45: pipes-to-ground too, the exit short of what is in the way and the next past it: %s" % [under_steps.call()])
	input.drag.end()
	world._remove(65)
	world.chunks.erase(Vector2i(3, 3))
	for id in [9910, 9911, 9912]:
		m.eprops.erase(id)
	var furnace: ProtoDB.EntityProto = world.protos.entity(8)
	input.drag.begin("stone-furnace", furnace, Vector2(0, 26), false)
	for x in range(1, 7):
		input.drag.update(Vector2(x, 26))
	steps = input.drag.sent.map(func(c): return float(c["x"]) / 256.0)
	check(steps == [0.0, 2.0, 4.0, 6.0], "other buildings go one footprint after another along the line: %s" % [steps])
	input.drag.end()
	# J4: a pole held shows the supply areas of the poles round it and its own, one tint where they
	# meet: two 5x5 areas three tiles apart (8 x 5) and the held one's 5 x 3 below them, no overlaps.
	world._add([66, 5, 4 * 256 + 128, 30 * 256 + 128, 0])
	world._add([67, 5, 7 * 256 + 128, 30 * 256 + 128, 0])
	var cover := PoleCoverageScript.new()
	cover.world = world
	var held: Array = cover.held_marks(5, "normal", Vector2(4.5, 33.5), m.eprops)
	var cover_rects: Array = held[0]["rects"] if held.size() == 1 and str(held[0]["k"]) == "cover" else []
	var covered := 0.0
	var overlaps := 0
	for i in cover_rects.size():
		covered += (cover_rects[i] as Rect2).get_area()
		for j in range(i + 1, cover_rects.size()):
			if (cover_rects[i] as Rect2).intersects(cover_rects[j]):
				overlaps += 1
	check(is_equal_approx(covered, 55.0) and overlaps == 0, "J4: the poles' areas and the held pole's, %s tiles in %d rectangles, %d overlapping" % [covered, cover_rects.size(), overlaps])
	check(is_equal_approx(PoleCoverageScript.supply_of(5, "rare", m.eprops), 4.5) and PoleCoverageScript.supply_of(1, "normal", m.eprops) == 0.0,
		"J4: a pole's supply area grows a tile each way per quality level; a belt supplies nothing")
	var hover_cover := cover.area_of(world.entities[66], m.eprops)
	check(hover_cover == Rect2(2, 28, 5, 5), "J4: a pole hovered shows its own area: %s" % [hover_cover])
	world._remove(66)
	world._remove(67)
	# J9: the build cursor shows a splitter over belts as buildable (it replaces them), not red; the
	# drag's own checks still see the belts.
	world.protos.add_entities([[9913, "test-splitter", "splitter", -1, -0.5, 1, 0.5, 0, 0, 0, 2, 1]])
	world._add([68, 1, 20 * 256 + 128, 2 * 256 + 128, 0])
	world._add([69, 1, 21 * 256 + 128, 2 * 256 + 128, 0])
	var splitter_proto: ProtoDB.EntityProto = world.protos.entity(9913)
	check(input._blocked(splitter_proto, Vector2(21, 2.5), Vector2i(2, 1)) and not input._blocked(splitter_proto, Vector2(21, 2.5), Vector2i(2, 1), true),
		"J9: belts under a splitter don't turn the build cursor red (it replaces them); the drag's checks still see them")
	world._remove(68)
	world._remove(69)
	# J9 (the splitter one tile over): the mod snaps what is sent (in 1/256 tile) exactly where the preview
	# snapped the cursor's point, on both sides of zero, for odd and even sizes. Cut towards zero, a point
	# just under a tile's edge or middle at negative coordinates was sent as the edge itself: one tile over.
	var mod_snap := func(fixed: int, size: int) -> float:  # building.lua snap(fixed / 256, size)
		var v := fixed / 256.0
		return floorf(v) + 0.5 if size % 2 == 1 else floorf(v + 0.5)
	var snap_points: Array[float] = []
	for base in [3.0, 0.0, -1.0, -3.0, -40.0]:
		for f in [0.0, 0.0005, 0.002, 0.25, 0.498, 0.4995, 0.5, 0.5005, 0.502, 0.75, 0.998, 0.9995]:
			snap_points.append(base + f)
	var count_off := func() -> int:
		var n := 0
		for v in snap_points:
			for size in [1, 2]:
				if not is_equal_approx(mod_snap.call(PlayerInput.wire(v), size), PlayerInput._snap(v, size)):
					n += 1
		return n
	var off_now: int = count_off.call()
	PlayerInput.wire_floor = false
	var off_before: int = count_off.call()
	var cut_cmd_x := PlayerInput.wire(-3.5005)
	PlayerInput.wire_floor = true
	check(off_now == 0 and off_before > 0 and cut_cmd_x == -896 and PlayerInput.wire(-3.5005) == -897 and PlayerInput.wire(3.4995) == 895,
		"J9: every cursor point is sent so the mod snaps it where the preview stood (%d of %d off; cut towards zero, as before, %d)" % [off_now,
			snap_points.size() * 2, off_before])
	# A splitter aimed just left of a belt's middle at x -3.5: the preview stands on the tile edge at -4
	# (over the belts at -4.5 and -3.5); what is sent must snap there too, not to -3.
	sent()
	input.build_dir = 0
	input.drag.begin("test-splitter", splitter_proto, Vector2(-3.5005, 2.5), true)
	input.drag.end()
	var split_cmd := sent_one("build")
	var split_preview := Vector2(PlayerInput._snap(-3.5005, 2), PlayerInput._snap(2.5, 1))
	check(split_cmd.has("x") and split_preview == Vector2(-4, 2.5)
		and is_equal_approx(mod_snap.call(int(split_cmd["x"]), 2), -4.0) and is_equal_approx(mod_snap.call(int(split_cmd["y"]), 1), 2.5),
		"J9: a splitter aimed a hair left of a belt's middle at negative x lands on the preview's tile edge (-4), not one over: %s" % [split_cmd])
	input.tile_brush.size = 1
	input.tile_brush.mine(Vector2(-3.0005, -7.002), 1.0)
	await get_tree().process_frame
	var mine_cmd := sent_one("tile_mine")
	var brush_tile: Vector2i = input.tile_brush.brush(Vector2(-3.0005, -7.002), 1)[0]
	check(mine_cmd.has("x") and brush_tile == Vector2i(-4, -8) and floori(int(mine_cmd["x"]) / 256.0) == -4 and floori(int(mine_cmd["y"]) / 256.0) == -8,
		"J9: the tile brush's point too: the mod's tile is the one the brush is drawn on: %s" % [mine_cmd])
	# J9, the testing agent's: a splitter clicked in all four directions, on both sides of zero on both axes, a hair
	# either side of a tile's edge and middle: the mod's snap of what is sent is the preview's snap, every time.
	var j9_points := [-40.5001, -3.5005, -3.4995, -3.0005, -2.9995, -0.5005, -0.0005, 0.0005, 0.4995, 2.9995, 3.0005, 3.4995, 3.5005]
	var j9_off := func() -> Array:
		var off := 0
		var tried := 0
		for d in [0, 4, 8, 12]:
			input.build_dir = d
			var size: Vector2i = DragBuildScript._snapped_size(splitter_proto, d)
			for px in j9_points:
				for py in [j9_points[1], j9_points[3], j9_points[8], j9_points[11]]:
					sent()
					input.drag.begin("test-splitter", splitter_proto, Vector2(px, py), true)
					input.drag.end()
					var c := sent_one("build")
					tried += 1
					if not c.has("x") or not is_equal_approx(mod_snap.call(int(c["x"]), size.x), PlayerInput._snap(px, size.x)) \
							or not is_equal_approx(mod_snap.call(int(c["y"]), size.y), PlayerInput._snap(py, size.y)):
						off += 1
		input.build_dir = 0
		return [off, tried]
	var j9_now: Array = j9_off.call()
	PlayerInput.wire_floor = false
	var j9_old: Array = j9_off.call()
	PlayerInput.wire_floor = true
	check(int(j9_now[0]) == 0 and int(j9_old[0]) > 0 and int(j9_now[1]) == 208,
		"J9: a splitter clicked facing N, E, S and W, either side of zero and of a tile's edge and middle, lands where its preview stood: %d of %d off (--build-wire=truncate: %d)"
			% [j9_now[0], j9_now[1], j9_old[0]])
	# J9, Ctrl+V's paste: Factorio snaps the point sent to the tile it is in, so it must be the tile under
	# the cursor on both sides of zero (cut towards zero, -3.0005 was sent as -3: a tile over).
	var clip_was: Array = m.clipboard
	var had_ground_was: bool = input.has_ground
	var ground_was: Vector2 = input.ground
	m.clipboard = [{"name": "wooden-chest", "x": 0, "y": 0}]
	input.has_ground = true
	var paste_off := func() -> Array:
		var off := 0
		var tried := 0
		for px in j9_points:
			for py in [j9_points[1], j9_points[3], j9_points[6], j9_points[8]]:
				sent()
				input.ground = Vector2(px, py)
				input._paste()
				var c := sent_one("paste")
				tried += 1
				if not c.has("x") or floori(int(c["x"]) / 256.0) != floori(px) or floori(int(c["y"]) / 256.0) != floori(py):
					off += 1
		return [off, tried]
	var paste_now: Array = paste_off.call()
	PlayerInput.wire_floor = false
	var paste_old: Array = paste_off.call()
	PlayerInput.wire_floor = true
	m.clipboard = clip_was
	input.has_ground = had_ground_was
	input.ground = ground_was
	sent()
	check(int(paste_now[0]) == 0 and int(paste_old[0]) > 0 and int(paste_now[1]) == 52,
		"J9: Ctrl+V's paste point is in the tile under the cursor either side of zero: %d of %d off (--build-wire=truncate: %d)"
			% [paste_now[0], paste_now[1], paste_old[0]])
	# J18: the right button over an item lying on the ground picks it up (`mine` gi, where it lies),
	# hiding it at once; an item is found only within its selection box.
	var gi_layer := GroundItemsScript.new()
	gi_layer.protos = world.protos
	add_child(gi_layer)
	gi_layer.handle({"t": "gi", "k": 5, "part": 1, "parts": 1, "l": [1, 30 * 256 + 64, 40 * 256 + 64, 1, 31 * 256, 40 * 256]})
	check(gi_layer.item_at(Vector2(30.3, 40.2)) == [Vector2i(30 * 256 + 64, 40 * 256 + 64), 1] and gi_layer.item_at(Vector2(30.6, 40.6)).is_empty(),
		"J18: an item on the ground is found under the mouse within its selection box: %s" % [gi_layer.item_at(Vector2(30.3, 40.2))])
	input.ground_items = gi_layer
	input.ground = Vector2(30.3, 40.2)
	input.has_ground = true
	input.hovered_mover = []
	sent()
	var took: bool = input._take_ground_item()
	var gi_mine := sent_one("mine")
	check(took and int(gi_mine.get("gi", 0)) == 1 and int(gi_mine.get("x", 0)) == 30 * 256 + 64 and int(gi_mine.get("y", 0)) == 40 * 256 + 64
		and gi_layer.item_at(Vector2(30.3, 40.2)).is_empty() and gi_layer.count() == 1,
		"J18: the right button sends mine with gi for it and hides it at once: %s" % [gi_mine])
	input.ground_items = null
	gi_layer.queue_free()
	sent()
	m.has_slots = had_slots
	for tool in [input.tile_brush, input.rail_planner, input.capsule_aim]:
		tool.queue_free()
	# PlayerInput's own previews, made before _ready (which a test doesn't run) adds them anywhere.
	for n in [input._ghost, input._drag_box, input._reach_lines, input._ghost_model, input._overlay]:
		n.free()
	input.free()
	cv.free()
	world.free()


## The map's layers (map_layers.gd) draw again only the layer whose data changed, into a SubViewport
## that renders once each time (the minimap had drawn every layer four times a second: 15-20 ms
## each on a big base, the stutter standing still); the map view still draws them.
