extends Node3D
## What the player just built or turned, drawn at once before the game confirms it (the latency layer,
## after FFF #83: Factorio shows a player's own actions immediately and corrects them when the
## real state arrives).
##
## A build goes to the mod, which places it on its next tick and sends the entity back (`add`);
## until that entity is drawn in its chunk, this layer draws the model where it will stand. A
## prediction goes when its entity is drawn, or when the game has moved on without it (refused:
## out of reach, something in the way, none left), and is never drawn over something already
## there. Builds never touch the world mirror; a turn (turn()) turns the mirror's record in place
## until the game's `upd` replaces it, and turns it back if none comes.

const WorldMirror := preload("res://scripts/world/world.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const Visuals := preload("res://scripts/world/visuals.gd")

## Game ticks after the send with no entity: the mod answers on its next tick, so by then it was
## refused. Also at least this long in real time, for a server that stalls.
const REFUSED_TICKS := 20
const REFUSED_MSEC := 600
## Gone whatever happens after this (a lost message, the chunk never drawn).
const GIVE_UP_MSEC := 4000
## Types whose look the mod decides from what is round them (an underground's entrance or exit,
## a rail's piece, cargo frames), or that it moves (rolling stock onto rails): not predicted.
const NOT_PREDICTED := ["underground-belt", "straight-rail", "curved-rail-a", "curved-rail-b", "half-diagonal-rail",
	"elevated-straight-rail", "elevated-curved-rail-a", "elevated-curved-rail-b", "elevated-half-diagonal-rail",
	"rail-ramp", "rail-support", "locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon", "cargo-bay",
	"space-platform-hub", "cargo-landing-pad"]

var world: WorldMirror

class Pending:
	var proto: ProtoDB.EntityProto
	var pos := Vector2.ZERO
	var dir := 0
	var rect := Rect2()
	var node: Node3D
	var tick := 0
	var msec := 0
	var confirmed := false  # its entity is in the world; waiting for the chunk to draw it

var _pending: Array[Pending] = []
## Milliseconds from each build to its entity drawn, newest last (the wait this layer hides).
var waits: Array = []
var refused := 0


func _ready() -> void:
	world.entities_changed.connect(_on_entities_changed)


func reset() -> void:
	for p in _pending:
		p.node.queue_free()
	_pending.clear()
	_turns.clear()


func count() -> int:
	return _pending.size()


## Draws `proto` at `pos` (its footprint's centre, as sent to the mod), turned `dir`. False when it
## isn't predicted (a type the mod shapes, or something already drawn or predicted there).
func build(proto: ProtoDB.EntityProto, pos: Vector2, dir: int) -> bool:
	if proto == null or proto.type in NOT_PREDICTED:
		return false
	# Factorio puts a crafting machine down facing north while it has no recipe (2.1.24: an
	# assembler built turned east, south or west came back north), and a hand-built one has none.
	if proto.type == "assembling-machine":
		dir = 0
	# A model not made yet would be a grey box where the building is about to appear: nothing is
	# better (the first of a kind only; asking starts it loading).
	if not ModelLibrary.entity_ready(proto.name, proto.type, {}, dir):
		return false
	var rect := WorldMirror.selection_rect(proto, pos, dir).grow(-0.05)
	for p in _pending:
		if p.rect.intersects(rect):
			if p.proto == proto and p.pos.distance_squared_to(pos) < 0.01 and not p.confirmed:
				# Built again over itself (the belt where a drag turns): the mod turns it.
				p.dir = dir
				p.node.queue_free()
				p.node = _make_node(proto, pos, dir)
				add_child(p.node)
				return true
			return false
	if _taken(rect):
		return false  # a belt turned or replaced in place: the world's own update shows that
	var node := _make_node(proto, pos, dir)
	if node == null:
		return false
	var p := Pending.new()
	p.proto = proto
	p.pos = pos
	p.dir = dir
	p.rect = rect
	p.node = node
	p.tick = Bridge.server_tick
	p.msec = Time.get_ticks_msec()
	add_child(node)
	_pending.append(p)
	return true


## How many of `proto` are predicted and not drawn yet (their items may not have left the
## inventory the client shows).
func pending_of(proto: ProtoDB.EntityProto) -> int:
	var n := 0
	for p in _pending:
		if p.proto == proto and not p.confirmed:
			n += 1
	return n


## Something already drawn stands in `rect` (ore, ghosts and tile ghosts don't count).
func _taken(rect: Rect2) -> bool:
	var center := WorldMirror.chunk_of(rect.get_center())
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var cv = world.chunks.get(center + Vector2i(dx, dy))
			if cv == null:
				continue
			for r: WorldMirror.Rec in cv.entities.values():
				var other: ProtoDB.EntityProto = world.protos.entity(r.proto_id)
				if other == null or other.type in ["resource", "entity-ghost", "tile-ghost"]:
					continue
				if WorldMirror.selection_rect(other, r.pos, r.dir).intersects(rect):
					return true
	return false


func _make_node(proto: ProtoDB.EntityProto, pos: Vector2, dir: int) -> Node3D:
	var root := Node3D.new()
	var at := Vector3(pos.x, 0.0, pos.y)
	if ModelLibrary.entity_ready(proto.name, proto.type, {}, dir):
		var mesh := ModelLibrary.mesh_for_entity(proto.name, proto.type, {}, dir)
		if mesh != null:
			root.transform = ModelLibrary.placed(proto.name, proto.type, dir, {}, at)
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			root.add_child(mi)
			# Moving parts at rest: their meshes are in model space.
			for part: ModelLibrary.AnimPart in ModelLibrary.parts_for_entity(proto.name, proto.type, {}, dir):
				var part_mi := MeshInstance3D.new()
				part_mi.mesh = part.mesh
				root.add_child(part_mi)
			return root
	# No model yet (or none at all): the box the world would draw.
	var box := MeshInstance3D.new()
	box.mesh = Visuals.box_mesh()
	box.transform = Visuals.placeholder_transform(proto, pos, dir, Visuals.height_for(proto))
	box.material_override = Visuals.ghost_material(Color(0.6, 0.6, 0.6, 1.0))
	root.add_child(box)
	return root


func _on_entities_changed(c: Vector2i) -> void:
	if _pending.is_empty():
		return
	var cv = world.chunks.get(c)
	if cv == null:
		return
	for p in _pending:
		if p.confirmed or WorldMirror.chunk_of(p.pos) != c:
			continue
		for r: WorldMirror.Rec in cv.entities.values():
			if r.proto_id == p.proto.id and r.pos.distance_squared_to(p.pos) < 0.01:
				p.confirmed = true
				break


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if not _turns.is_empty():
		_check_turns(now)
	if _pending.is_empty():
		return
	var i := 0
	while i < _pending.size():
		var p := _pending[i]
		var age := now - p.msec
		var gone := false
		if p.confirmed:
			# Kept until the chunk has drawn the real one, so nothing blinks out in between.
			if world._drawn(WorldMirror.chunk_of(p.pos)):
				waits.append(age)
				if waits.size() > 64:
					waits.pop_front()
				gone = true
		elif Bridge.server_tick - p.tick >= REFUSED_TICKS and age >= REFUSED_MSEC:
			refused += 1
			gone = true
		if age >= GIVE_UP_MSEC:
			gone = true
		if gone:
			p.node.queue_free()
			_pending.remove_at(i)
		else:
			i += 1


## Types the game always turns on R (LuaEntity.rotate, as the mod calls it), so a turn can be shown
## before it answers. Measured in 2.1.23: square ones turn a quarter (back with Shift), ones longer
## one way than the other (splitters, loaders, pumps, boilers, combinators) half way round either
## way, an underground half way round as the other end (entrance and exit swap). Others may refuse
## (a crafting machine without fluid boxes, a steam engine) and wait for the game.
const TURNS := ["inserter", "transport-belt", "splitter", "lane-splitter", "loader", "loader-1x1", "pump",
	"pipe-to-ground", "underground-belt", "mining-drill", "boiler", "arithmetic-combinator", "decider-combinator",
	"selector-combinator"]

class Turn:
	var rec  # WorldMirror.Rec, turned in place until the game's own record replaces it
	var old_dir := 0
	var old_extra := {}
	var tick := 0
	var msec := 0

var _turns := {}  # entity key -> Turn


## Turns `rec` in the world mirror as R will (see TURNS), before the game's `upd`
## arrives; turned back if the game moves on without one. False when it isn't predicted.
func turn(rec: WorldMirror.Rec, reverse: bool) -> bool:
	if rec == null or rec.unit <= 0:
		return false
	var proto: ProtoDB.EntityProto = world.protos.entity(rec.proto_id)
	if proto == null or not proto.type in TURNS:
		return false
	var t: Turn = _turns.get(rec.key)
	if t == null or t.rec != rec:
		t = Turn.new()
		t.rec = rec
		t.old_dir = rec.dir
		t.old_extra = rec.extra
		_turns[rec.key] = t
	t.tick = Bridge.server_tick
	t.msec = Time.get_ticks_msec()
	if proto.type == "underground-belt":
		var e := rec.extra.duplicate()
		e["u"] = "i" if str(e.get("u", "i")) == "o" else "o"
		rec.extra = e
		rec.dir = posmod(rec.dir + 8, 16)
	elif proto.tile_size.x != proto.tile_size.y:
		rec.dir = posmod(rec.dir + 8, 16)
	else:
		rec.dir = posmod(rec.dir + (-4 if reverse else 4), 16)
	world.redraw(rec.chunk)
	return true


func _check_turns(now: int) -> void:
	for key in _turns.keys():
		var t: Turn = _turns[key]
		if world.entities.get(key) != t.rec:
			_turns.erase(key)  # the game's record came (or the entity went): it is the truth now
		elif Bridge.server_tick - t.tick >= REFUSED_TICKS and now - t.msec >= REFUSED_MSEC:
			t.rec.dir = t.old_dir
			t.rec.extra = t.old_extra
			world.redraw(t.rec.chunk)
			refused += 1
			_turns.erase(key)
