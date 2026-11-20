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
## until the game's `upd` replaces it, and turns it back if none comes; a ghost removed by a right
## click (remove_ghost()) is hidden until the game's `del` takes it, and shown again if none comes; so are the belts
## between an underground pair built over them, which the game mines with the build (clear_run(), M2).

const WorldMirror := preload("res://scripts/world/world.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")

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

## L2 (the owner's playtest: a belt drag with 6 belts in hand showed about 17, and the game took 11
## of them away again): a build was predicted while the inventory shown held the item and the ones
## predicted before weren't confirmed yet. But the game's `add` comes on its next tick and the
## inventory only with its report, up to 30 ticks later: the builds it had made (confirmed, no longer
## counted) hadn't left the inventory shown yet, so a drag went on sending and predicting past what
## the hand held. Now every build sent spends an item until the first inventory heard after its
## building came has paid for it (or the game refused it, or GIVE_UP_MSEC): drag_build.gd sends and
## predicts nothing past what is left (player_input.gd items_left), as Factorio places nothing then.
## `--build-spend=off`: as before.
static var spend_fix := not ("--build-spend=off" in OS.get_cmdline_user_args())
## Whether a build spends is judged by the bridge's own reach (building.lua: the build distance plus
## 1.5 tiles to the building's middle), not the cursor's (to the footprint's edge): a small building
## up to a tile past the cursor's reach has a red preview and the bridge still builds it, so a drag
## begun there sent one or two more than the hand held, shown and taken away again (seen in a
## window with 6 belts: 7 drawn). `--build-spend-reach=cursor`: the cursor's reach, as before.
static var spend_bridge_reach := not ("--build-spend-reach=cursor" in OS.get_cmdline_user_args())

class Spend:
	var item := ""
	var proto: ProtoDB.EntityProto
	var pos := Vector2.ZERO  # its footprint's centre, snapped as the mod snaps it
	var tick := 0
	var msec := 0
	var built := false  # its building's `add` came: the next inventory heard has paid for it

var _spends: Array[Spend] = []
## Bumped whenever _spends gains or loses one: unpaid_all()'s answer is kept until then (the cursor,
## the slots and the quickbar ask for it up to three times a frame).
var _spends_ver := 0
var _unpaid_ver := -1
var _unpaid := {}

## M2's leftover: the undergrounds (pipes-to-ground) just sent to be built that the world doesn't have
## yet, each a record of its own (never in the world: its key is ""), an underground belt's with the
## end the bridge will make it (`extra` "u"). underground_pairs.gd pairs a held or just-built piece
## with them as with the world's: a drag's exit sent before its entrance's `add` came hides its run
## with the build. One goes when its building stands in the world, or once the game has moved on
## without it (refused).
class SentUnder:
	var rec: WorldMirror.Rec
	var tick := 0
	var msec := 0

var _sent_unders: Array[SentUnder] = []


func _ready() -> void:
	world.entities_changed.connect(_on_entities_changed)


func reset() -> void:
	for p in _pending:
		p.node.queue_free()
	_pending.clear()
	_turns.clear()
	_removed.clear()
	_spends.clear()
	_spends_ver += 1
	_sent_unders.clear()


## L2: a real build of `item` (placing `proto` at `pos`, snapped) just sent: one of it is spent until
## the inventory shown has lost it. Not when the game won't take one: the same building already
## stands there (the mod turns it) or was just sent there (a drag's corner turned again).
func spend(item: String, proto: ProtoDB.EntityProto, pos: Vector2) -> void:
	if not spend_fix or proto == null:
		return
	for s in _spends:
		if s.proto == proto and s.pos.distance_squared_to(pos) < 0.01:
			return
	var r: WorldMirror.Rec = world.pick(pos) if world != null else null
	if r != null and r.proto_id == proto.id and not r.extra.has("gh") and r.pos.distance_squared_to(pos) < 0.01:
		return
	var s := Spend.new()
	s.item = item
	s.proto = proto
	s.pos = pos
	s.tick = Bridge.server_tick
	s.msec = Time.get_ticks_msec()
	_spends.append(s)
	_spends_ver += 1


## How many of `item` were sent to be built that the inventory shown still holds (0 with the fix off).
func unpaid(item: String) -> int:
	var n := 0
	for s in _spends:
		if s.item == item:
			n += 1
	return n


## Every item with builds sent that the inventory shown still holds: item -> how many (ui_model.gd
## set_spent: the slots and the quickbar count them out at once, as the cursor does).
## The same Dictionary until a build is added or goes: not to be changed by the caller.
func unpaid_all() -> Dictionary:
	if _unpaid_ver == _spends_ver:
		return _unpaid
	var out := {}
	for s in _spends:
		out[s.item] = int(out.get(s.item, 0)) + 1
	_unpaid = out
	_unpaid_ver = _spends_ver
	return out


## An `add` from the game (main.gd, before the world takes it): the build it answers is made, and
## the inventory heard after it has paid for it (the bridge sends both reliably, the `add` first).
func heard_add(e) -> void:
	if _spends.is_empty() or not (e is Array) or e.size() < 4:
		return
	if e.size() > 5 and e[5] is Dictionary and ((e[5] as Dictionary).has("gh") or (e[5] as Dictionary).has("tg")):
		return
	var id := int(e[1])
	var at := Vector2(int(e[2]), int(e[3])) / 256.0
	for s in _spends:
		if not s.built and s.proto.id == id and s.pos.distance_squared_to(at) < 0.01:
			s.built = true
			return


## The inventory shown changed (ui_model.gd inventory_changed): builds whose `add` came before it
## are in it now.
func inventory_heard() -> void:
	var i := 0
	while i < _spends.size():
		if _spends[i].built:
			_spends.remove_at(i)
			_spends_ver += 1
		else:
			i += 1


## Builds the game moved on without (refused: none left, in the way) spent nothing; and none is kept
## past GIVE_UP_MSEC (an inventory that came back to the same count sends nothing).
func _check_spends(now: int) -> void:
	var i := 0
	while i < _spends.size():
		var s := _spends[i]
		var age := now - s.msec
		if age >= GIVE_UP_MSEC or (not s.built and Bridge.server_tick - s.tick >= REFUSED_TICKS and age >= REFUSED_MSEC):
			_spends.remove_at(i)
			_spends_ver += 1
		else:
			i += 1


func count() -> int:
	return _pending.size()


## Draws `proto` at `pos` (its footprint's centre, as sent to the mod), turned `dir`. False when it
## isn't predicted (a type the mod shapes, or something already drawn or predicted there).
## `look_turned`: one Factorio can't turn, built turned for the look (K21, visual_turns.gd), drawn so.
func build(proto: ProtoDB.EntityProto, pos: Vector2, dir: int, look_turned := false) -> bool:
	if proto == null or proto.type in NOT_PREDICTED:
		return false
	# Factorio puts a crafting machine down facing north while it has no recipe (2.1.24: an
	# assembler built turned east, south or west came back north), and a hand-built one has none.
	# One it can't turn at all keeps the cursor's turn in Zenith (K21).
	if proto.type == "assembling-machine" and not look_turned:
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
	box.material_override = GroundHeight.mark_material(Color(0.6, 0.6, 0.6, 1.0), false)  # on the hills, as models are
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
	if not _spends.is_empty():
		_check_spends(now)
	if not _sent_unders.is_empty():
		_check_sent_unders(now)
	if not _turns.is_empty():
		_check_turns(now)
	if not _removed.is_empty():
		_check_removed(now)
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


## Ghosts removed by a right click (I6), hidden at once: entity key -> Turn (its record, and when).
var _removed := {}


## Hides a ghost (or tile ghost) the player just removed, before the game's `del` arrives: its
## record gets `hid` (ghosts.gd draws it not, world.pick passes it by); shown again if the game moves
## on without removing it. False when it isn't a ghost.
func remove_ghost(rec: WorldMirror.Rec) -> bool:
	if rec == null or not (rec.extra.has("gh") or rec.extra.has("tg")) or rec.extra.has("hid"):
		return false
	var t := Turn.new()
	t.rec = rec
	t.old_extra = rec.extra
	t.tick = Bridge.server_tick
	t.msec = Time.get_ticks_msec()
	_removed[rec.key] = t
	var e := rec.extra.duplicate()
	e["hid"] = 1
	rec.extra = e
	world.hide_record(rec)
	return true


## M2: the belts (pipes) between an underground pair the player just built over them, which the game mines with the
## build (underground_pairs.gd cleared): hidden at once, as remove_ghost() hides a ghost, until their `mnd` or `del`
## takes them; shown again if the game moves on without (it kept them: the build refused, or the run not plain after
## all). How many it hid.
func clear_run(recs: Array) -> int:
	var n := 0
	for rec: WorldMirror.Rec in recs:
		if rec == null or rec.extra.has("hid") or rec.extra.has("gh") or rec.extra.has("tg"):
			continue
		var t := Turn.new()
		t.rec = rec
		t.old_extra = rec.extra
		t.tick = Bridge.server_tick
		t.msec = Time.get_ticks_msec()
		_removed[rec.key] = t
		var e := rec.extra.duplicate()
		e["hid"] = 1
		rec.extra = e
		world.redraw(rec.chunk)  # (chunk_view.gd and far_chunks.gd draw no `hid` record)
		n += 1
	return n


## M2: an underground of `proto` was just sent to be built at `pos` (snapped) facing `dir`, where the
## client's own check says the game takes it; `entrance`: the end an underground belt will be (as
## the bridge's underground_type decides it: an exit when it joins an entrance behind it).
func sent_underground(proto: ProtoDB.EntityProto, pos: Vector2, dir: int, entrance: bool) -> void:
	if proto == null:
		return
	for s in _sent_unders:
		if s.rec.pos.distance_squared_to(pos) < 0.01:
			_sent_unders.erase(s)
			break
	var r := WorldMirror.Rec.new()
	r.key = ""
	r.proto_id = proto.id
	r.pos = pos
	r.fixed = Vector2i(roundi(pos.x * 256.0), roundi(pos.y * 256.0))
	r.dir = dir
	r.chunk = WorldMirror.chunk_of(pos)
	if proto.type == "underground-belt":
		r.extra = {"u": "i" if entrance else "o"}
	r.extra[ModelLibrary.VARIANT_KEY] = ModelLibrary.ModelPacks.variant_seed(r.fixed)  # as the game's record will be (world.gd)
	var s := SentUnder.new()
	s.rec = r
	s.tick = Bridge.server_tick
	s.msec = Time.get_ticks_msec()
	_sent_unders.append(s)


## Those still on their way: [WorldMirror.Rec, ...] (not the world's records).
func sent_undergrounds() -> Array:
	var out: Array = []
	for s in _sent_unders:
		out.append(s.rec)
	return out


func _check_sent_unders(now: int) -> void:
	var i := 0
	while i < _sent_unders.size():
		var s := _sent_unders[i]
		var r: WorldMirror.Rec = world.pick(s.rec.pos) if world != null else null
		var stands := r != null and r.proto_id == s.rec.proto_id and not r.extra.has("gh") and r.pos.distance_squared_to(s.rec.pos) < 0.01
		if stands or (Bridge.server_tick - s.tick >= REFUSED_TICKS and now - s.msec >= REFUSED_MSEC) or now - s.msec >= GIVE_UP_MSEC:
			_sent_unders.remove_at(i)
		else:
			i += 1


func _check_removed(now: int) -> void:
	for key in _removed.keys():
		var t: Turn = _removed[key]
		if world.entities.get(key) != t.rec:
			_removed.erase(key)  # its `del` came (or another record): the game agrees
		elif Bridge.server_tick - t.tick >= REFUSED_TICKS and now - t.msec >= REFUSED_MSEC:
			t.rec.extra = t.old_extra
			if t.old_extra.has("gh") or t.old_extra.has("tg"):
				world.hide_record(t.rec)
			else:
				world.redraw(t.rec.chunk)
			refused += 1
			_removed.erase(key)


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
