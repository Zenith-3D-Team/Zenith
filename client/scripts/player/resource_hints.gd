extends RefCounted
## What Factorio shows while a mining drill or a pipe is held (owner's L8, placing pumpjacks on oil):
##
## - A drill whose prototype needs a resource under it (`eprops` rr: every drill in 2.1) is red where its
##   mining area holds none it can mine ("Pumpjack can only be built on resources", Factorio's
##   cant-build-reason; "... cannot mine this resource" over one of another category), as the game refuses it.
##   A resource is in the area when its position is (resource_searching_radius: a pumpjack's 0.49 is its
##   middle tile, an electric drill's 2.49 five by five), its category one of the drill's (`rk`).
## - A resource that needs fluid to be mined (uranium ore: its `eprops` rf) follows Factorio 2.1.24's rule, measured with
##   can_place_entity: a drill with a fluid input (`fb` not all outputs) over one is red until the force can mine with
##   fluid ("Uranium mining not researched.", `cinfo` mwf 0), even with other ore beside it; a drill without one (the
##   burner drill) can't mine it, so it counts as no resource ("... cannot mine this resource" over uranium alone).
## - The resources Factorio marks while such a drill is held (ResourceEntityPrototype::highlight: crude oil, and
##   Space Age's geysers, vents and brine; the bridge's `hl`) are outlined round the cursor, so the wells show.
## - A held pipe's preview joins what it would join, as Factorio draws the pipe it is about to build: the
##   pipes beside it, a pipe to ground facing it, and the fluid connections of the machines round it that
##   point at its tile (their record's own `fc`, else the prototype's `fb` turned with them; a crafting
##   machine's only those its recipe uses). It was always the lone pipe ("the pipes don't flip while placing
##   them").
##
## --resource-hints=off: none of the drill's; --fluid-mining-hints=off: resources needing fluid count as any other;
## --held-pipe-joins=off: the lone pipe, as before (docs/RUNNING.md).

const WorldMirror := preload("res://scripts/world/world.gd")
const CursorOverlay := preload("res://scripts/player/cursor_overlay.gd")
const Kit := preload("res://scripts/ui/factorio/kit.gd")
const Switches := preload("res://scripts/switches.gd")

static var drill_hints := Switches.on("--resource-hints")
static var pipe_joins := Switches.on("--held-pipe-joins")
static var fluid_mining_hints := Switches.on("--fluid-mining-hints")

## How far round the cursor highlighted resources are outlined (tiles).
const HIGHLIGHT_REACH := 48.0
const HIGHLIGHT_FILL := Color(1.0, 1.0, 1.0, 0.10)
const HIGHLIGHT_EDGE := Color(1.0, 1.0, 1.0, 0.75)
## The resources in a held drill's mining area (green) and, when there are none, the area itself.
const MINE_OK := Color(0.3, 0.95, 0.35, 0.8)
const CRAFTERS := ["assembling-machine", "furnace"]


static func _x(eprops: Dictionary, proto_id: int) -> Dictionary:
	return (eprops.get(proto_id, {}) as Dictionary).get("x", {})


## The resource categories a drill's `eprops` names ([] for none known).
static func _categories(x: Dictionary) -> Array:
	var rk = x.get("rk")
	return rk if rk is Array else []


## Each chunk's resources, made once a change (its content_rev): coordinate -> [the ChunkView, its content_rev (and eprops'),
## {tile -> [record, proto]}, [[record, proto], ...] of those Factorio highlights (`hl`)]. An ore chunk holds a
## thousand; held over it, a drill reads its few tiles from here instead of every record each frame.
static var _chunk_resources := {}


static func _resources_of(world, eprops: Dictionary, c: Vector2i) -> Array:
	var cv = world.chunks.get(c)
	if cv == null:
		_chunk_resources.erase(c)
		return [{}, []]
	var cached: Array = _chunk_resources.get(c, [])
	var rev := int(cv.content_rev) * 4096 + eprops.size()  # (the prototypes' `hl` come with eprops)
	if cached.size() == 4 and is_same(cached[0], cv) and int(cached[1]) == rev:
		return [cached[2], cached[3]]
	if _chunk_resources.size() > 512:
		_chunk_resources.clear()  # (chunks long left behind)
	var by_tile := {}
	var lit: Array = []
	for key in cv.entities:
		var rec: WorldMirror.Rec = cv.entities[key]
		var proto = world.protos.entity(rec.proto_id)
		if proto == null or proto.type != "resource":
			continue
		by_tile[Vector2i(floori(rec.pos.x), floori(rec.pos.y))] = [rec, proto]
		if _x(eprops, proto.id).has("hl"):
			lit.append([rec, proto])
	_chunk_resources[c] = [cv, rev, by_tile, lit]
	return [by_tile, lit]


## Resources whose position lies inside the square `r` round `pos`: [[record, its proto], ...].
static func resources_in(world, pos: Vector2, r: float, eprops := {}) -> Array:
	var out: Array = []
	for y in range(floori(pos.y - r), floori(pos.y + r) + 1):
		for x in range(floori(pos.x - r), floori(pos.x + r) + 1):
			var tile := Vector2i(x, y)
			var pair = (_resources_of(world, eprops, WorldMirror.chunk_of(Vector2(tile) + Vector2(0.5, 0.5)))[0] as Dictionary).get(tile)
			if pair != null:
				var rec: WorldMirror.Rec = pair[0]
				if absf(rec.pos.x - pos.x) <= r and absf(rec.pos.y - pos.y) <= r:
					out.append(pair)
	return out


## The resources Factorio highlights within `r` of `pos` (few: oil wells, Space Age's vents).
static func highlighted_in(world, eprops: Dictionary, pos: Vector2, r: float) -> Array:
	var out: Array = []
	var lo := WorldMirror.chunk_of(pos - Vector2(r, r))
	var hi := WorldMirror.chunk_of(pos + Vector2(r, r))
	for cy in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			for pair in _resources_of(world, eprops, Vector2i(cx, cy))[1]:
				var rec: WorldMirror.Rec = pair[0]
				if absf(rec.pos.x - pos.x) <= r and absf(rec.pos.y - pos.y) <= r:
					out.append(pair)
	return out


## Whether a drill's `eprops` names a fluid connection that takes fluid in (the electric drill's; not a pumpjack's
## output, and a burner drill has none).
static func _takes_fluid(x: Dictionary) -> bool:
	for c in x.get("fb", []):
		if c is Array and c.size() >= 4 and str(c[3]) != "o":
			return true
	return false


## Why the held drill can't go at `pos` ("" when it can, or when nothing says it needs resources). `mine_with_fluid`:
## whether the force may mine with fluid yet (`cinfo` mwf; true when the bridge doesn't say).
static func mining_refusal(world, eprops: Dictionary, proto, pos: Vector2, mine_with_fluid := true) -> String:
	if not drill_hints or proto == null or proto.type != "mining-drill":
		return ""
	var x := _x(eprops, proto.id)
	if not x.has("rr") or not x.has("mr"):
		return ""
	var cats := _categories(x)
	var r := float(x["mr"])
	var wet := _takes_fluid(x)
	var any := false
	var minable := false
	var needs_research := false
	for pair in resources_in(world, pos, r, eprops):
		any = true
		var rx := _x(eprops, (pair[1]).id)
		var cat := str(rx.get("rk", ""))
		if not (cats.is_empty() or cat == "" or cats.has(cat)):
			continue
		if fluid_mining_hints and rx.has("rf"):
			if not wet:
				continue  # (a drill without a fluid input can't mine it)
			if not mine_with_fluid:
				needs_research = true
		minable = true
	if needs_research:
		return "Uranium mining not researched."
	if minable:
		return ""
	return ("%s cannot mine this resource" if any else "%s can only be built on resources") % Kit.entity_name(proto.name)


## The marks while a drill is held at `pos`: the resources Factorio highlights for it round the cursor, and
## those its mining area takes in green.
static func drill_marks(world, eprops: Dictionary, proto, pos: Vector2) -> Array:
	var out: Array = []
	if not drill_hints or proto == null or proto.type != "mining-drill":
		return out
	var x := _x(eprops, proto.id)
	var cats := _categories(x)
	if cats.is_empty():
		return out
	var r := float(x.get("mr", 0.0))
	var taken := {}
	for pair in resources_in(world, pos, r, eprops):
		var rec: WorldMirror.Rec = pair[0]
		if cats.has(str(_x(eprops, (pair[1]).id).get("rk", ""))):
			taken[rec] = true
			out.append(CursorOverlay.area(WorldMirror.selection_rect(pair[1], rec.pos, 0), Color(MINE_OK, 0.12), MINE_OK))
	for pair in highlighted_in(world, eprops, pos, HIGHLIGHT_REACH):
		var rec: WorldMirror.Rec = pair[0]
		if not taken.has(rec) and cats.has(str(_x(eprops, (pair[1]).id).get("rk", ""))):
			out.append(CursorOverlay.area(WorldMirror.selection_rect(pair[1], rec.pos, 0), HIGHLIGHT_FILL, HIGHLIGHT_EDGE))
	return out


## The 4-bit join mask (north 1, east 2, south 4, west 8: world.gd's `pc`) of a pipe held over `tile`.
static func held_pipe_mask(world, eprops: Dictionary, tile: Vector2i, heat: bool) -> int:
	if not pipe_joins or world == null:
		return 0
	var mask := 0
	for i in 4:
		var step: Vector2i = WorldMirror.PIPE_STEPS[i]
		var next := tile + step
		var other: WorldMirror.Rec = world.entities.get(world._pipes.get(next, -1))
		if other != null:
			var t: String = world.protos.entity(other.proto_id).type
			if heat != (t == "heat-pipe"):
				continue
			# A pipe to ground joins only the pipe its open end faces (as world.gd's _connect_pipe).
			if t == "pipe-to-ground" and other.dir != ((i + 2) % 4) * 4:
				continue
			mask |= 1 << i
			continue
		if heat:
			continue
		var machine: WorldMirror.Rec = world.pick(Vector2(next) + Vector2(0.5, 0.5))
		if machine != null and _points_at(world, eprops, machine, tile):
			mask |= 1 << i
	return mask


## Whether one of `r`'s fluid connections leads onto `tile`.
static func _points_at(world, eprops: Dictionary, r: WorldMirror.Rec, tile: Vector2i) -> bool:
	var proto = world.protos.entity(r.proto_id)
	if proto == null or proto.type == "resource" or proto.type == "entity-ghost" or r.extra.has("gh"):
		return false
	var fc = r.extra.get("fc")
	if fc is Array and not (fc as Array).is_empty():
		for c in fc:
			if c is Array and c.size() >= 3:
				var at: Vector2 = r.pos + Vector2(float(c[0]), float(c[1])) + CursorOverlay.dir_vector(int(c[2]))
				if Vector2i(floori(at.x), floori(at.y)) == tile:
					return true
		return false
	var x := _x(eprops, r.proto_id)
	var fb = x.get("fb")
	if not (fb is Array):
		return false
	var fa := int(r.extra.get("fa", 0))
	var crafter: bool = CRAFTERS.has(proto.type)
	if x.has("fo") and not CursorOverlay.outputs_only(fb) and not (crafter and fa != 0):
		return false
	for c in fb:
		if not (c is Array) or c.size() < 4:
			continue
		var flow := str(c[3])
		if crafter and x.has("fo") and not ((flow == "i" and fa & 1) or (flow == "o" and fa & 2) or (flow == "b" and fa != 0)):
			continue
		var at: Vector2 = r.pos + CursorOverlay.turn(Vector2(float(c[0]), float(c[1])), r.dir) + CursorOverlay.dir_vector(int(c[2]) + r.dir)
		if Vector2i(floori(at.x), floori(at.y)) == tile:
			return true
	return false
