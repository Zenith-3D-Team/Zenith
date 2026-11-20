extends RefCounted
## api.character (1.7): the client's own character, read-only: its state as drawn and as the bridge
## last said, its weapons, armour and hand, and its moments as signals. Everything comes from what
## the client already has (avatar.gd, character_anim.gd, ui_model.gd, the bridge's `me`, `shot`,
## `mnd`, `died`, `dead`, `guns`, `slots`): nothing is asked of the game.
##
## One per add-on (as api.camera), so switching an add-on off removes exactly its handlers. The
## reads read when called; the signals are fed by addon_watch.gd, which runs only once an add-on has
## read one of them (their getters below). Positions are Godot's (x east, z south, tiles).
##
## The signals' arguments are fixed for all of add-on API version 1 (Godot won't call a handler with
## fewer parameters than a signal sends, so none can be added): anything more is read from state().

## The signals themselves, read through the properties below: the first read tells Zenith to start
## watching for this add-on (addon_watch.gd), however late it comes or wherever api.character was kept;
## an add-on that only reads state() or sets a lift starts nothing. Connect them as any signal.
signal _footfall(foot: String, position: Vector3)
signal _took_off
signal _landed
signal _shot_fired(gun: String, ammo: String, target: Vector3)
signal _mined(name: String, position: Vector3, gone: bool)
signal _damaged(health_lost: int, shield_lost: int)
signal _died(position: Vector3)
signal _respawned
signal _vehicle_entered(unit: int)
signal _vehicle_left(unit: int)
signal _armor_changed(item: String)
signal _gun_selected(slot: int, gun: String)

## A foot came down in the drawn run cycle ("right" or "left"); `position` is the drawn place on
## the ground (`y` 0): the feet are state()'s `height` and `lift` above it. On the beat Zenith's own
## step sounds play. Not in a vehicle, in the air or dead.
var footfall: Signal:
	get:
		_want()
		return _footfall
## The drawn body left the ground (mech armour's take-off began), and came back down.
var took_off: Signal:
	get:
		_want()
		return _took_off
var landed: Signal:
	get:
		_want()
		return _landed
## One round from the character's own gun (not a stream, not a vehicle's guns): its gun and ammo,
## and the game's target on the ground.
var shot_fired: Signal:
	get:
		_want()
		return _shot_fired
## Hand-mining finished (`name` the prototype, "item-on-ground" for an item picked up with the
## mouse; `gone` false for a unit of ore from a patch still there); also each belt or pipe one of
## the character's own builds replaces.
var mined: Signal:
	get:
		_want()
		return _mined
## Health or shield went down since the last `me` (whole points, the frame's added up: coarse).
var damaged: Signal:
	get:
		_want()
		return _damaged
var died: Signal:
	get:
		_want()
		return _died
## The new character after a death (state().unit is new).
var respawned: Signal:
	get:
		_want()
		return _respawned
var vehicle_entered: Signal:
	get:
		_want()
		return _vehicle_entered
var vehicle_left: Signal:
	get:
		_want()
		return _vehicle_left
## The armour slot's item changed ("" taken off).
var armor_changed: Signal:
	get:
		_want()
		return _armor_changed
## The selected gun slot or the gun in it changed (not on each ammo count).
var gun_selected: Signal:
	get:
		_want()
		return _gun_selected

## The signals' public names (each one's own is "_" and the name).
const SIGNALS := ["footfall", "took_off", "landed", "shot_fired", "mined", "damaged", "died", "respawned",
	"vehicle_entered", "vehicle_left", "armor_changed", "gun_selected"]

const AddonWorld := preload("res://scripts/addons/addon_world.gd")

var _host
var _api: WeakRef  # the add-on's AddonApi, weak (it holds this part); null once switched off


func _init(host, api = null) -> void:
	_host = host
	_api = weakref(api) if api != null else null


## A signal was read: the add-on wants the character's events (once; nothing after it was switched off).
func _want() -> void:
	var api = _api.get_ref() if _api != null else null
	if api != null and _host != null:
		_host.watch.want_character(api)


## A living character whose state is known: in a game, a `me` heard since the last handshake, not
## dead. In a hub, a pod, a vehicle or with the remote view open it is still true.
func exists() -> bool:
	var avatar = _avatar()
	return avatar != null and bool(avatar.get("heard_me")) and not _dead()


## The character's state now, a copy (docs/ADDONS.md lists the keys); {} outside a game and before
## the first `me` of a handshake. While dead: the same keys, `dead` true, the rest as last known.
func state() -> Dictionary:
	var a = _avatar()
	if a == null or not bool(a.get("heard_me")):
		return {}
	var dead := _dead()
	var ride = _host.game_node("ride")
	var in_hub := ride != null and bool(ride.in_hub())
	var riding := ride != null and bool(ride.riding())
	var node := a as Node3D
	var at := node.global_position
	if dead:
		var died_at = _death_screen().get("died_at")
		if died_at is Vector2:
			at = Vector3(died_at.x, 0.0, died_at.y)
	var mining: bool = int(a.mining) >= 0 and not dead
	var mx: Vector2 = a.mining_at
	var rx: Vector2 = a.repair_at
	var ui = _ui()
	var shown_si = ui.get("viewing_si") if ui != null else null
	return {
		"unit": int(a.unit),
		"position": at,
		"forward": AddonWorld._forward(node),
		"height": float(a.drawn_lift()),
		# The add-ons' lifts and Zenith's belt step-up, as `height` has them both.
		"lift": a.lift_total() if a.has_method("lift_total") else Vector3.ZERO,
		"speed": 0.0 if dead else float(a.drawn_speed()),
		"stride": float(a.stride()),
		"walking": bool(a.walking) and not dead,
		"flying": bool(a.in_air()),
		"mining": mining,
		"mining_progress": int(a.mining) / 100.0 if mining else 0.0,
		"mining_at": Vector3(mx.x, 0.0, mx.y) if mining else null,
		"repairing": bool(a.repairing) and not dead,
		"repairing_at": Vector3(rx.x, 0.0, rx.y) if bool(a.repairing) and not dead else null,
		"firing": bool(a.firing) and not dead,
		"health": 0 if dead else int(a.health),
		"max_health": int(a.max_health),
		"shield": 0 if dead else int(a.shield),
		"max_shield": int(a.max_shield),
		"vehicle": int(a.vehicle),
		"vehicle_speed": roundi(float(a.vehicle_speed) * 1000.0 / (60.0 * 3.6)) / 1000.0,  # avatar.gd keeps km/h
		"in_hub": in_hub,
		"riding": riding,
		"dead": dead,
		"body_visible": bool(a.body_shown()) and not in_hub and not riding and not dead,
		"on_shown_surface": shown_si == null or int(shown_si) == 0,
	}


## The gun slots as the tool bar shows them: {selected (1-based), vehicle (whose guns: 0 the
## character's own), slots: [{gun, ammo, magazines, rounds, magazine_size}]}; {} before the first `guns`.
func weapons() -> Dictionary:
	var model = _host.ui_model()
	if model == null or (model.guns as Array).is_empty():
		return {}
	var slots: Array = []
	for g in model.guns:
		var e: Array = g if g is Array else []
		slots.append({"gun": str(e[0]) if e.size() > 0 else "", "ammo": str(e[1]) if e.size() > 1 else "",
			"magazines": int(e[2]) if e.size() > 2 else 0, "rounds": int(e[3]) if e.size() > 3 else -1,
			"magazine_size": int(e[4]) if e.size() > 4 else -1})
	return {"selected": int(model.selected_gun), "vehicle": int(model.guns_vehicle), "slots": slots}


## The item in the armour slot, "" for none or not known yet.
func armor() -> String:
	var model = _host.ui_model()
	return str(model.stack_at("armor", 1).get("item", "")) if model != null else ""


## What the hand holds: {item, quality}, {} for an empty hand. No count: Zenith's hand isn't
## Factorio's cursor stack.
func held() -> Dictionary:
	var input = _host.game_node("input")
	var item = input.get("cursor_item") if input != null else null
	if item == null or str(item) == "":
		return {}
	return {"item": str(item), "quality": str(input.get("cursor_quality"))}


## The character drawn `height` tiles up and `offset` across the ground (x east, z south; its y is
## ignored) from where the game has it, until changed. Drawn only: the game's character stays where
## it is, and reach, mining, building, what shots hit and what hits it are all the game's, on the
## ground. Several add-ons' lifts add up, capped at 16 tiles up and 1 across; not-a-number and a
## negative height count as 0. No easing: set it each frame for an arc. Not drawn in a vehicle or
## dead (kept, and drawn again after); gone when the add-on stops or the game ends. The camera stays
## still unless `camera` is true: then the first-person eye and the angled view's centre follow this
## lift too (Zenith's own belt step-up never moves them).
func set_lift(height: float, offset := Vector3.ZERO, camera := false) -> void:
	_host.character_lift(self, Vector3(offset.x, height, offset.z), camera)


func clear_lift() -> void:
	_host.character_lift(self, Vector3.ZERO)


## This add-on's own lift (y the height), Vector3.ZERO for none.
func lift() -> Vector3:
	return _host.lift_of(self)


## Keeps `node` at a bone or point (docs/ADDONS.md lists the names, frozen for API version 1), `offset`
## in its frame, drawn from this frame on: it follows the pose, the lift and the hills, hides with the
## body (a vehicle, first person) and falls with it. `view` is the first-person eye, shown only there.
## Drawn only. Kept across games; freed when the add-on stops. False for an unknown name or outside a game.
func attach(node: Node3D, to: String, offset := Transform3D.IDENTITY) -> bool:
	return _host.character_attach(self, node, to, offset)


## Hands `node` back out of the tree, not freed.
func detach(node: Node3D) -> void:
	_host.character_detach(self, node)


## A bone's or point's frame in the world as drawn now (pose, lift, hills); null for an unknown name or
## outside a game.
func frame(name: String):
	return _host.character_frame(name)


## {mech, height (head_top at rest, for scaling), bones, points}; {} outside a game.
func rig() -> Dictionary:
	return _host.character_rig()


## Zenith's muzzle flashes, beams and streams start at `at` in `node`'s frame while it is in the tree.
func set_muzzle(node: Node3D, at := Vector3.ZERO) -> void:
	_host.character_muzzle(self, node, at)


func clear_muzzle() -> void:
	_host.character_muzzle(self, null)


## Zenith's own pickaxe and gun not drawn while on (the add-on draws its own).
func hide_tools(on: bool) -> void:
	_host.character_tools(self, on)


## This add-on's pose layer, until changed: `turns` bone name -> Vector3 (radians, about the bone's
## joint in the model's axes at rest). Options: "weight" 0 to 1 (1), "replace" an Array of bones or
## true for all (Zenith's own turn fades out by the weight). Added over Zenith's animations, held to
## the joints' ranges, fading as the body falls dead. Drawn only.
func set_pose(turns: Dictionary, options := {}) -> void:
	_host.character_pose(self, turns, options)


func clear_pose() -> void:
	_host.character_pose(self, {})


## This add-on's own layer's turns ({} for none).
func pose() -> Dictionary:
	return _host.pose_of(self)


## Every handler still on this add-on's signals goes (it was switched off), and reading them no
## longer starts the watch.
func _clear() -> void:
	_api = null
	for s in SIGNALS:
		for c: Dictionary in get_signal_connection_list("_" + s):
			disconnect("_" + s, c["callable"])


func _avatar():
	var a = _host.game_node("avatar")
	return a if a is Node3D and a.has_method("drawn_speed") else null


func _ui():
	var hud = _host.game_node("hud")
	return hud.get("ui") if hud != null else null


func _death_screen() -> Object:
	var ui = _ui()
	var d = ui.get("death_screen") if ui != null else null
	return d if d is Object else RefCounted.new()


func _dead() -> bool:
	var left = _death_screen().get("left")
	return left != null and float(left) >= 0.0
