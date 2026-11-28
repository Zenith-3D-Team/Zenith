extends RefCounted
## api.world: what this client knows of the game, read-only, from its own copy of the world. What
## it knows is what the bridge sends: buildings in the chunks drawn round the focus, moving things
## and trains within the entity distance of it (Settings → Graphics), the players' list. Positions
## are Godot's: x east and z south in tiles, y up (Factorio's (x, y) is (x, z) here).
##
## Moving things are named by the prototype types Factorio gives them: "locomotive", "cargo-wagon",
## "fluid-wagon", "artillery-wagon", "car", "spider-vehicle", "character" (other players; the
## client's own character is character()), "logistic-robot", "construction-robot",
## "combat-robot", "unit" (biters and spitters), "spider-unit", "rocket-silo-rocket", "cargo-pod"...
## Every function returns copies: changing them changes nothing.

const TRAIN_TYPES := ["locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon", "infinity-cargo-wagon"]
const ROBOT_TYPES := ["logistic-robot", "construction-robot", "combat-robot", "capture-robot"]
const StandHeight := preload("res://scripts/world/stand_height.gd")
const Switches := preload("res://scripts/switches.gd")
const ViewAhead := preload("res://scripts/world/view_ahead.gd")

var _host
## The add-on this copy belongs to (each add-on has its own, for hold_chunks); null for the host's.
var _api


func _init(host, api = null) -> void:
	_host = host
	_api = api


func in_game() -> bool:
	return _host.in_game()


## The client's own character: {unit, position (Vector3), forward (Vector3, flat), vehicle (the
## unit it drives, 0 none), visible}; {} outside a game.
func character() -> Dictionary:
	var avatar = _host.game_node("avatar")
	if not avatar is Node3D:
		return {}
	var a := avatar as Node3D
	var u: Variant = a.get("unit")
	var v: Variant = a.get("vehicle")
	return {"unit": int(u) if u != null else 0, "position": a.global_position, "forward": _forward(a),
		"vehicle": int(v) if v != null else 0, "visible": a.visible}


## The moving things of these types (all when empty) near the focus:
## [{unit, type, name, position (Vector3, as drawn), forward (Vector3, flat)}].
func movers(types: Array = []) -> Array:
	var layer = _host.game_node("movers")
	var out: Array = []
	if layer == null:
		return out
	var wanted: Array = types if not types.is_empty() else _all_types(layer)
	for type in wanted:
		for pair in layer.units_of_type(str(type)):
			var entry := _mover_entry(layer, int(pair[0]), str(type))
			if not entry.is_empty():
				out.append(entry)
	return out


## One moving thing as movers() gives it, or {} when it is gone (or too far to be sent).
func mover(unit: int) -> Dictionary:
	var layer = _host.game_node("movers")
	if layer == null:
		return {}
	var proto = layer.protos.entities_by_name.get(layer.proto_name_of(unit)) if layer.get("protos") != null else null
	return _mover_entry(layer, unit, str(proto.type) if proto != null else "")


## A mover where it is drawn now. Robots and walking creatures are drawn by the GPU from a record
## (mover_records.gd) and their node stays where they first appeared, so the place and facing come
## from movers.gd's position_of and yaw_of, not the node.
func _mover_entry(layer, unit: int, type: String) -> Dictionary:
	var at = layer.position_of(unit)
	if not at is Vector3:
		return {}
	var yaw: float = layer.yaw_of(unit)
	return {"unit": unit, "type": type, "name": layer.proto_name_of(unit), "position": at,
		"forward": Vector3(-sin(yaw), 0.0, -cos(yaw))}


## Trains with a carriage near the focus (sent about every half second):
## [{id, state (Factorio's train_state name), manual, speed (tiles a tick, negative backwards),
## station (unit of the stop it is at, 0 none), destination (stop name), carriages (units, front
## first)}].
func trains() -> Array:
	var model = _host.ui_model()
	var out: Array = []
	if model == null:
		return out
	for id in model.trains:
		var t: Dictionary = model.trains[id]
		out.append({"id": int(id), "state": str(t["state"]), "manual": bool(t["manual"]), "speed": float(t["speed"]),
			"station": int(t["station"]), "destination": str(t["dest"]), "carriages": (t["carriages"] as Array).duplicate()})
	return out


## The train a carriage belongs to, or 0.
func train_of(unit: int) -> int:
	var model = _host.ui_model()
	return int(model.train_of_unit.get(unit, 0)) if model != null else 0


## The players of the game: [{index, name, connected, color, unit (their character, 0 none),
## surface, me (the client's own)}].
func players() -> Array:
	var model = _host.ui_model()
	var out: Array = []
	if model == null:
		return out
	for p: Dictionary in model.players:
		out.append({"index": int(p["index"]), "name": str(p["name"]), "connected": bool(p["connected"]),
			"color": p["color"], "unit": int(p["unit"]), "surface": str(p["surface"]),
			"me": int(p["index"]) == int(model.me_player)})
	return out


## Rockets climbing from their silos now, as drawn: [Vector3].
func rockets() -> Array:
	var layer = _host.game_node("rockets")
	return layer.launch_positions() if layer != null and layer.has_method("launch_positions") else []


## The chunks drawn now (Vector2i, 32 tiles each).
func chunks() -> Array:
	var w = _host.game_node("world")
	return w.chunks.keys() if w != null else []


## The buildings (and trees, rocks...) of one drawn chunk, of these types (all when empty):
## [{unit, name, type, position (Vector2, tiles), direction (0-15), working (true, false, or null
## when unknown)}].
func entities_in_chunk(chunk: Vector2i, types: Array = []) -> Array:
	var w = _host.game_node("world")
	var out: Array = []
	if w == null or not w.chunks.has(chunk):
		return out
	var cv = w.chunks[chunk]
	for key in cv.entities:
		var r = cv.entities[key]
		var proto = w.protos.entity(r.proto_id)
		if proto == null or (not types.is_empty() and not types.has(proto.type)):
			continue
		var working = null
		if r.unit != 0 and w.working.has(r.unit):
			working = int(w.working[r.unit]) == 1
		out.append({"unit": r.unit, "name": proto.name, "type": proto.type, "position": r.pos, "direction": r.dir, "working": working})
	return out


## The same within `radius` tiles of a ground point.
func entities_near(point: Vector2, radius: float, types: Array = []) -> Array:
	var out: Array = []
	var c0 := Vector2i(floori((point.x - radius) / 32.0), floori((point.y - radius) / 32.0))
	var c1 := Vector2i(floori((point.x + radius) / 32.0), floori((point.y + radius) / 32.0))
	for cx in range(c0.x, c1.x + 1):
		for cy in range(c0.y, c1.y + 1):
			for e in entities_in_chunk(Vector2i(cx, cy), types):
				if (e["position"] as Vector2).distance_to(point) <= radius:
					out.append(e)
	return out


## (API 1.7) How high the character would stand at a ground point (tiles over the ground there): the
## drawn top of a belt, underground belt, splitter, loader, pipe-to-ground, heat pipe or ground rail
## there, the highest where several meet; 0 for bare ground and anything else (stand_height.gd). The
## whole answer: Zenith's own belt step-up takes the belt family alone, capped (avatar.gd STAND_MAX).
func stand_height_at(point: Vector2) -> float:
	return StandHeight.at(_host.game_node("world"), point)


## (API 1.6) Holds the chunks already drawn (on), or lets them go again (off): while on, chunks the
## camera leaves aren't unloaded, as they were when the bridge last sent them (it no longer updates
## them), and the chunks round the new focus still come; a screenshot of a long flight shows all of
## it. Capped by memory: at most world.gd HOLD_MAX_CHUNKS (1,600) chunks held past the view, fewer
## once the computer has under 1 GB free; past that the farthest go first, and the log says so once.
## Per add-on: chunks are held while any add-on asks. Switching the add-on off lets them go.
func hold_chunks(on: bool) -> void:
	_host.hold_chunks(_api, on)


## (API 1.6) Chunks are held now (by any add-on), and how many are held past the view.
func holding_chunks() -> bool:
	return _host.holding_chunks()


func held_chunks() -> int:
	var w = _host.game_node("world")
	return int(w.held_count()) if w != null and w.has_method("held_count") else 0


## (API 1.94) Announces where the camera will cut to, so what is drawn there is at its levels of detail
## when it does (models' levels, far chunks merged or whole, the cliff wall's levels), made under the
## usual budgets meanwhile, with no hitch at the cut. `position` is the camera, `look` what it looks at
## (Godot's axes: x east, y up, z south, in tiles). Kept `seconds` (at most 30) unless announced again
## (each frame for a moving one is fine: it is looked at again once it moves 8 tiles) or let go with
## release_view(); about a second ahead is enough. One viewpoint per add-on; switching the add-on off
## lets it go. Nothing with `--cut-lods=old`. Chunks must be loaded there: see hold_chunks().
func prepare_view(position: Vector3, look: Vector3, seconds := 2.0) -> void:
	ViewAhead.prepare(_api.id if _api != null else "?", position, look, seconds)


## (API 1.94) Lets the viewpoint announced with prepare_view go (after the cut).
func release_view() -> void:
	ViewAhead.release(_api.id if _api != null else "?")


## (API 1.94) Says the next frame is a cut: its levels of detail are picked without the frame budget and
## without cross-fades (one slower frame, hidden by the cut). A camera moving more than 32 tiles in one
## frame counts as a cut anyway.
func mark_cut() -> void:
	ViewAhead.mark_cut()


## The point the world is loaded round (tiles).
func focus() -> Vector2:
	var rig = _host.rig()
	return rig.focus_point() if rig != null else Vector2.ZERO


## (API 1.91) The game's tick (Factorio's game.tick) of the newest message the client has handled;
## -1 outside a game. It stands still while the game is paused and runs slower while the game does:
## what to time things on that must repeat the same way each run (a filmed scene), not the clock.
func tick() -> int:
	return Bridge.server_tick if in_game() else -1


## (API 1.91) The game's tick as moving things are timed, as a float that runs on smoothly between
## messages at the rate ticks arrive (game_clock.gd): for motion keyed to ticks. tick() until the
## first message of moving things; -1 outside a game.
func smooth_tick() -> float:
	if not in_game():
		return -1.0
	var movers = _host.game_node("movers")
	var clock = movers.get("clock") if movers != null else null
	var t: float = float(clock.tick) if clock != null else -1.0
	return t if t >= 0.0 else float(tick())


## (API 1.91) The cue tick: the game tick a filmed scene starts on, for every add-on to time its part
## from; -1 when none. (1.92) A cue the game sets while running (a mod's
## `remote.call("zenith", "set_cue", tick)`) replaces `--cue-tick=<game tick>` from Zenith's command
## line; api.cue_changed(tick) tells an add-on when it arrives or changes.
func cue_tick() -> int:
	var run := run_cue()
	return run if run >= 0 else cue_from_args(Switches.args())


static var run_cue_override := -2  # tests: anything but -2 stands in for the bridge's cue


## (API 1.92) The cue the game set while running, -1 none (cue_tick() falls back to --cue-tick).
static func run_cue() -> int:
	if run_cue_override != -2:
		return run_cue_override
	var tree := Engine.get_main_loop() as SceneTree
	var bridge = tree.root.get_node_or_null("Bridge") if tree != null else null
	return int(bridge.get("cue_tick")) if bridge != null and bridge.get("cue_tick") != null else -1


static var cue_override := -2  # tests: anything but -2 stands in for the command line


static func cue_from_args(args: PackedStringArray) -> int:
	if cue_override != -2:
		return cue_override
	for a: String in args:
		if a.begins_with("--cue-tick="):
			var v := a.substr(11).strip_edges()
			return int(v) if v.is_valid_int() and int(v) >= 0 else -1
	return -1


## The time of day as drawn: 0 noon, 0.5 midnight; and how dark it is, 0 to 0.85.
func daytime() -> float:
	var m = _host.main
	return float(m.get("_daytime")) if m != null and m.get("_daytime") != null else 0.0


func darkness() -> float:
	var m = _host.main
	return float(m.get("_darkness")) if m != null and m.get("_darkness") != null else 0.0


## The planet shown ("nauvis", "vulcanus"...), and whether it is a space platform.
func planet() -> String:
	var m = _host.main
	var sky = m.get("_planet_sky") if m != null else null
	return str(sky.planet) if sky != null else ""


func on_platform() -> bool:
	var m = _host.main
	return m != null and m.get("_space") == true


static func _forward(n: Node3D) -> Vector3:
	var f := -n.basis.z
	f.y = 0.0
	return f.normalized() if f.length() > 0.001 else Vector3.FORWARD


func _all_types(_layer) -> Array:
	return ["character", "car", "spider-vehicle", "cargo-pod", "rocket-silo-rocket", "unit", "spider-unit"] + TRAIN_TYPES + ROBOT_TYPES
