extends RefCounted
## Underground belts' and pipes-to-ground's pairs, found in the world mirror as Factorio pairs them:
## the piece one is connected to (J23: R turns both ends), and the piece a held one would join, with
## Factorio's marks for it (J24).
##
## An underground belt's direction is the way items go, an exit's too (its model is turned round).
## An entrance (`extra` "u" "i") looks ahead that way for the nearest underground belt of its own
## kind (or a ghost of it) facing the same way, up to the prototype's max_distance (`eprops` "under"):
## an exit there is its other end, another entrance cuts it off. Other kinds, and pieces facing
## another way, are passed over (Factorio lets them braid), as the mod's underground_type does. An
## exit looks back for its entrance. A pipe-to-ground's direction is its pipe connection, so its
## underground side is behind it: it looks back for one of its kind facing the other way (one
## facing its own way on the line cuts it off).

const WorldMirror := preload("res://scripts/world/world.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const CursorOverlay := preload("res://scripts/player/cursor_overlay.gd")
const Switches := preload("res://scripts/switches.gd")

## Factorio's underground_sprite (core/graphics/arrows/underground-lines.png): the lane's edges orange
## to yellow, its arrow yellow. Where the furthest exit can go it is tinted green (the utility
## constants' underground_belt_max_distance_tint); past that, too far to connect, red (the red of its
## underground-lines-remove sprite).
const TUNNEL := Color(1.0, 0.75, 0.0, 0.95)
const MAX_REACH := Color(0.0, 1.0, 0.016, 0.95)
const TOO_FAR := Color(1.0, 0.0, 0.14, 0.95)

## M2 (the owner: placing undergrounds over belts should remove the belts between them). Factorio mines the belts
## between a pair a player's build completes when every tile between holds a plain one: a belt going the pair's way,
## straight, fed by nothing from the side; a pipe joined to nothing off the line (its tips and tricks, "Fast replace
## belt & underground belt"; its developers' "simple" belts). Else none go. The bridge does it (building.lua
## clear_between, on the game's own connections); here the cursor marks them as Factorio does, with its
## underground_remove_belts sprite (underground-lines-remove.png: red-orange corner brackets round each tile, the
## belts' frame with the yellow arrow), and the build hides them at once (predicted.gd clear_run).
## `--underground-clear=off`: neither (the bridge's own switch is `/f3d-perf under_clear`).
static var clear_on := Switches.on("--underground-clear")
const REMOVE := Color(1.0, 0.3, 0.03, 0.95)
const REMOVE_ARROW := Color(1.0, 1.0, 0.0, 0.95)
## M2's leftover: the pieces just sent to be built count as standing (`sent` below: predicted.gd
## sent_undergrounds, records of their own, not in the world): a drag's exit sent before its entrance's
## `add` came pairs with that entrance, so its run is hidden with the build, not when the game's `mnd`
## comes a tick later, and the cursor marks it meanwhile. `--underground-clear-sent=off`: only what the
## world has, as before.
static var sent_on := Switches.on("--underground-clear-sent")


static func is_underground(type: String) -> bool:
	return type == "underground-belt" or type == "pipe-to-ground"


## The unit vector of a 16-way direction (north is (0, -1)).
static func _vec(dir: int) -> Vector2:
	return CursorOverlay.dir_vector(dir).round()


## The prototype a piece is of: its own, or a ghost's entity's.
static func _kind(r: WorldMirror.Rec) -> int:
	return int(r.extra["gh"]) if r.extra.has("gh") else r.proto_id


## The first piece of `kind` along `step` from `pos`, within `reach` tiles, facing one of `dirs`
## (others on the line are passed over): [rec, tiles away], or [] for none. `sent`: pieces just sent
## to be built (see sent_on), each found on its tile where the world has no such piece yet (the belt
## it replaces may still stand there).
static func _first_on_line(world: WorldMirror, kind: int, pos: Vector2, step: Vector2, dirs: Array, reach: int, sent: Array = []) -> Array:
	for k in range(1, reach + 1):
		var at := pos + step * k
		var r: WorldMirror.Rec = world.pick(at)
		if r != null and _kind(r) == kind and dirs.has(r.dir):
			return [r, k]
		var s := _sent_at(sent, at)
		if s != null and s.proto_id == kind and dirs.has(s.dir):
			return [s, k]
	return []


## The piece just sent to the tile at `at`, or null.
static func _sent_at(sent: Array, at: Vector2) -> WorldMirror.Rec:
	if not sent_on:
		return null
	for s: WorldMirror.Rec in sent:
		if s.pos.distance_squared_to(at) < 0.01:
			return s
	return null


## The other end of `rec` (an underground belt or pipe-to-ground) as Factorio connects them, or null.
static func partner(world: WorldMirror, rec: WorldMirror.Rec, reach: int) -> WorldMirror.Rec:
	if rec == null or reach <= 0:
		return null
	var kind := _kind(rec)
	var proto: ProtoDB.EntityProto = world.protos.entity(kind)
	if proto == null:
		return null
	if proto.type == "underground-belt":
		var entrance := str(rec.extra.get("u", "i")) == "i"
		var found := _first_on_line(world, kind, rec.pos, _vec(rec.dir) * (1.0 if entrance else -1.0), [rec.dir], reach)
		if found.is_empty():
			return null
		var other: WorldMirror.Rec = found[0]
		return other if (str(other.extra.get("u", "i")) == "i") != entrance else null
	if proto.type == "pipe-to-ground":
		var back := posmod(rec.dir + 8, 16)
		var found := _first_on_line(world, kind, rec.pos, -_vec(rec.dir), [rec.dir, back], reach)
		if found.is_empty():
			return null
		var other: WorldMirror.Rec = found[0]
		return other if other.dir == back else null
	return null


## What a held underground of `proto` at `pos` facing `dir` would join: {"partner": Rec, "k": tiles
## between their centres, "far": true when that is past `reach`, too far to connect (looked for up
## to twice the reach)}, or {} when there is nothing to join (it would be a new entrance).
static func held_join(world: WorldMirror, proto: ProtoDB.EntityProto, pos: Vector2, dir: int, reach: int, sent: Array = []) -> Dictionary:
	if proto == null or reach <= 0 or not is_underground(proto.type):
		return {}
	var back := -_vec(dir)
	var found: Array
	if proto.type == "underground-belt":
		# An entrance facing the same way: this would be its exit. An exit there ends the search.
		found = _first_on_line(world, proto.id, pos, back, [dir], reach * 2, sent)
		if found.is_empty() or str((found[0] as WorldMirror.Rec).extra.get("u", "i")) != "i":
			return {}
	else:
		var other := posmod(dir + 8, 16)
		found = _first_on_line(world, proto.id, pos, back, [dir, other], reach * 2, sent)
		if found.is_empty() or (found[0] as WorldMirror.Rec).dir != other:
			return {}
	return {"partner": found[0], "k": found[1], "far": int(found[1]) > reach}


## Factorio's marks for a held underground: its underground_sprite on every tile between the piece
## it would join and it, and on the furthest tile its exit may go, green; red from the piece once it
## is past that, too far to connect. With nothing to join, the furthest its exit could go, green.
## Pipes-to-ground have no arrow, as Factorio draws their connection. `clears`: a real build, which mines a plain run
## between (M2; a ghost's doesn't). `sent`: the pieces just sent to be built (see sent_on).
static func held_marks(world: WorldMirror, proto: ProtoDB.EntityProto, pos: Vector2, dir: int, reach: int, clears := true,
		sent: Array = []) -> Array:
	if proto == null or reach <= 0 or not is_underground(proto.type):
		return []
	var belt := proto.type == "underground-belt"
	var join := held_join(world, proto, pos, dir, reach, sent)
	if join.is_empty():
		# A new entrance: where its exit could go at most (a pipe-to-ground's is behind it).
		return [tunnel(pos + _vec(dir) * (reach if belt else -reach), _vec(dir), MAX_REACH, belt)]
	var r: WorldMirror.Rec = join["partner"]
	var k: int = join["k"]
	var way := (pos - r.pos).normalized().round()
	var flow := _vec(dir) if belt else way
	var colour := TOO_FAR if bool(join["far"]) else TUNNEL
	# M2: what the build would mine, marked as Factorio marks it, instead of the connection.
	var going := clears and not cleared(world, proto, pos, dir, reach, sent).is_empty()
	var out: Array = []
	for i in range(1, k):
		if going:
			out.append(removed(r.pos + way * i, flow, belt))
		elif i != reach:
			out.append(tunnel(r.pos + way * i, flow, colour, belt))
	if reach != k:
		out.append(tunnel(r.pos + way * reach, flow, MAX_REACH, belt))
	return out


## M2: the belts (pipes) the build of a held underground of `proto` at `pos` facing `dir` would mine, as Factorio
## mines them (see clear_on): the records on every tile between it and the piece it joins, or [] when there is none
## between, it joins nothing (or too far) or anything breaks the run. `sent`: the pieces just sent to be built (see
## sent_on): one of them may be the piece it joins; one on a tile between breaks the run (no plain belt will be there).
static func cleared(world: WorldMirror, proto: ProtoDB.EntityProto, pos: Vector2, dir: int, reach: int, sent: Array = []) -> Array:
	if not clear_on or world == null:
		return []
	var join := held_join(world, proto, pos, dir, reach, sent)
	if join.is_empty() or bool(join["far"]):
		return []
	var r: WorldMirror.Rec = join["partner"]
	if r.extra.has("gh"):
		return []
	var k: int = join["k"]
	var way := (pos - r.pos).normalized().round()
	var belt := proto.type == "underground-belt"
	var out: Array = []
	for i in range(1, k):
		var at := r.pos + way * i
		var b: WorldMirror.Rec = world.pick(at)
		if b == null or b.extra.has("gh") or b.extra.has("tg") or b.pos.distance_squared_to(at) > 0.01 or _sent_at(sent, at) != null:
			return []
		var bp: ProtoDB.EntityProto = world.protos.entity(b.proto_id)
		if bp == null:
			return []
		if belt:
			if bp.type != "transport-belt" or b.dir != dir or str(b.extra.get("s", "s")) != "s" or _fed_from_side(world, at, way):
				return []
		else:
			# The mod's connection mask (`pc`: 1 north, 2 east, 4 south, 8 west): nothing across the line.
			var across := 5 if way.y == 0.0 else 10
			if bp.type != "pipe" or (int(b.extra.get("pc", 0)) & across) != 0:
				return []
		out.append(b)
	return out


## Whether something beside the tile at `at` of a run going `way` puts items onto it from the side (a side-load: the
## belt isn't Factorio's "simple" one any more).
static func _fed_from_side(world: WorldMirror, at: Vector2, way: Vector2) -> bool:
	var side := Vector2(-way.y, way.x)
	for s: float in [1.0, -1.0]:
		var n: WorldMirror.Rec = world.pick(at + side * s)
		if n == null or n.extra.has("gh") or n.extra.has("tg"):
			continue
		var np: ProtoDB.EntityProto = world.protos.entity(n.proto_id)
		if np == null:
			continue
		var f := _vec(n.dir)
		match np.type:
			"transport-belt", "lane-splitter":
				if (n.pos + f).distance_squared_to(at) < 0.01:
					return true
			"underground-belt":
				if str(n.extra.get("u", "i")) == "o" and (n.pos + f).distance_squared_to(at) < 0.01:
					return true
			"splitter":
				var across := Vector2(-f.y, f.x) * 0.5
				if (n.pos + f + across).distance_squared_to(at) < 0.01 or (n.pos + f - across).distance_squared_to(at) < 0.01:
					return true
			"loader", "loader-1x1", "linked-belt":
				# Its belt end facing this tile (a loader's half a tile further out).
				var d := at - n.pos
				if d.length() < 1.6 and d.normalized().distance_squared_to(f) < 0.01:
					return true
	return false


## One tile of Factorio's underground connection at `at` (the tile's centre) for things going `flow`:
## the lane's edges as dashes and, for belts, a hollow arrow (cursor_overlay.gd draws it).
static func tunnel(at: Vector2, flow: Vector2, colour: Color, arrow := true) -> Dictionary:
	return {"k": "tunnel", "at": at, "dir": flow, "c": colour, "arrow": arrow}


## M2: one tile the build would mine, as Factorio's underground_remove_belts (pipes: underground_remove_pipes)
## draws it: red-orange corner brackets round the tile and, for belts, the yellow arrow (cursor_overlay.gd).
static func removed(at: Vector2, flow: Vector2, arrow := true) -> Dictionary:
	return {"k": "unbuilt", "at": at, "dir": flow, "c": REMOVE, "ca": REMOVE_ARROW, "arrow": arrow}
