extends Node
## The one place that notices what api.character's signals and api.camera.mode_changed say (1.7):
## it compares a few values each frame and looks at five of the bridge's message types, and emits
## on each wanting add-on's own api.character or api.camera.
##
## Off until an add-on wants it: an add-on wants the character by reading one of api.character's
## signals (each signal's getter calls want_character: reads and set_lift alone don't start it) and the
## mode by reading api.camera.mode_changed (its getter calls want_mode). Until
## then nothing here processes or is connected to anything; when the last wanting add-on stops it
## goes back to that.
##
## Runs after the avatar and the camera rig (process_priority), so a footfall's signal comes in the
## frame it is drawn. Message-time events come as the message is handled, connected after main.gd's
## own handler (the avatar and the death screen are already up to date).

var _host
var _main = null
## Add-ons' AddonApi objects that want the character's events, and the camera's mode.
var _char_apis: Array = []
var _mode_apis: Array = []
var _on := false

var _mode := ""  # the mode last reported ("" not known yet: the next one is the baseline)

# The character's last values, the baseline for "it changed" (_have false: the next `me` sets it).
var _have := false
var _unit := 0
var _health := 0
var _shield := 0
var _max_shield := 0
var _vehicle := 0
var _died := false  # died fired; the next `me` is the respawned character
var _hurt := Vector2i.ZERO  # health and shield lost by this frame's `me`s
var _footfalls := -1
var _air := false
var _air_known := false
var _armor = null  # the armour's item, null until the bridge said what the slot holds
var _gun = null  # [selected slot, its gun, the vehicle], null before the first `guns`


func _init(host) -> void:
	_host = host
	name = "Watch"
	process_priority = 1000  # after the avatar and the rig have moved this frame
	set_process(false)


## An add-on read one of api.character's signals: it wants the character's events.
func want_character(api) -> void:
	if not _char_apis.has(api):
		_char_apis.append(api)
		_update()


## An add-on read api.camera.mode_changed (first touch).
func want_mode(api) -> void:
	if not _mode_apis.has(api):
		_mode_apis.append(api)
		if _mode_apis.size() == 1:
			_mode = ""  # nobody was comparing: the mode now is the baseline, not a change
			_check_mode()
		_update()


## The add-on stopped: no more of its events, and off when it was the last.
func forget(api) -> void:
	_char_apis.erase(api)
	_mode_apis.erase(api)
	_update()


## A game's nodes are there (addon_host.gd's game_started).
func attach(main_node) -> void:
	detach()
	_main = main_node
	_update()


## Before the game's nodes go: off them, and what was last seen forgotten (the next game's first
## values are its baseline). Add-ons that want events keep wanting them.
func detach() -> void:
	_set_on(false)
	_main = null
	_mode = ""
	_reset_character()
	_died = false
	_armor = null
	_gun = null


## Watching at all (for tests): processing or connected to anything.
func is_on() -> bool:
	return _on


func _update() -> void:
	_set_on(_main != null and (not _char_apis.is_empty() or not _mode_apis.is_empty()))


func _set_on(on: bool) -> void:
	var chars := on and not _char_apis.is_empty()
	var was := Bridge.message_received.is_connected(_on_message)
	_connect(Bridge.message_received, _on_message, chars)
	_connect(Bridge.welcomed, _on_welcome, chars)
	var model = _host.ui_model() if _main != null else null
	if model != null:
		_connect(model.inventory_changed, _on_inventory, chars)
		_connect(model.guns_changed, _on_guns, chars)
	if chars and not was:
		_armor = _read_armor()  # what is worn and held now is the baseline, not a change
		_gun = _read_gun()
	if not chars:
		_footfalls = -1
		_air_known = false
	if _mode_apis.is_empty():
		_mode = ""
	_on = on
	set_process(on)


func _connect(s: Signal, f: Callable, on: bool) -> void:
	if on and not s.is_connected(f):
		s.connect(f)
	elif not on and s.is_connected(f):
		s.disconnect(f)


func _process(_delta: float) -> void:
	if not _mode_apis.is_empty():
		_check_mode()
	if _char_apis.is_empty():
		return
	if _hurt != Vector2i.ZERO:
		var hurt := _hurt
		_hurt = Vector2i.ZERO
		_emit("damaged", [hurt.x, hurt.y])
	var avatar = _host.game_node("avatar")
	if not avatar is Node3D or not avatar.has_method("footfalls"):
		return
	var air: bool = avatar.in_air()
	if _air_known and air != _air:
		_emit("took_off" if air else "landed", [])
	_air = air
	_air_known = true
	var count: int = avatar.footfalls()
	if _footfalls >= 0 and count > _footfalls and int(avatar.vehicle) == 0 and not air and not _died:
		# A slow frame that spanned two: both, in order, the feet alternating up to the last.
		var at := (avatar as Node3D).global_position
		var n := count - _footfalls
		var right: bool = avatar.foot_right()
		for i in n:
			var this_right := right if (n - 1 - i) % 2 == 0 else not right
			_emit("footfall", ["right" if this_right else "left", at])
	_footfalls = count


func _check_mode() -> void:
	var rig = _host.rig()
	if rig == null:
		return
	var now := str(rig.view_mode())
	if _mode != "" and now != _mode:
		var before := _mode
		_mode = now
		for api in _mode_apis.duplicate():
			api.camera._mode_changed.emit(now, before)
	_mode = now


func _on_welcome(_msg: Dictionary) -> void:
	_reset_character()  # a new handshake: the next `me` is the baseline (a respawn's comes with one)


func _reset_character() -> void:
	_have = false
	_hurt = Vector2i.ZERO


func _on_message(msg: Dictionary) -> void:
	match str(msg.get("t", "")):
		"me":
			_on_me(msg)
		"shot":
			var avatar = _host.game_node("avatar")
			if avatar != null and int(msg.get("u", 0)) == int(avatar.get("unit")) and int(msg.get("u", 0)) != 0:
				_emit("shot_fired", [str(msg.get("g", "")), str(msg.get("a", "")), _ground(msg)])
		"mnd":
			_emit("mined", [_mined_name(msg), _ground(msg), int(msg.get("g", 0)) == 1])
		"died":
			if _have and int(msg.get("u", 0)) != 0 and int(msg.get("u", 0)) == _unit:
				_death(_ground(msg))
		"dead":
			if _have:
				_death(_ground(msg))


func _on_me(msg: Dictionary) -> void:
	var unit := int(msg.get("u", _unit))
	var health := int(msg.get("hp", _health))
	var shield := int(msg.get("sd", 0))
	var max_shield := int(msg.get("msd", 0))
	var vehicle := int(msg.get("v", 0))
	if _died:
		_died = false
		_emit("respawned", [])
		_have = false
	if not _have or unit != _unit:
		_have = true  # nothing fires for what was already so
	else:
		if msg.has("hp") and health < _health:
			_hurt.x += _health - health
		# Shields lost, not shields taken off: `sd` comes only while the armour has shields, so a
		# missing one or a lower maximum (armour or equipment swapped) is a new baseline, as health's.
		if msg.has("sd") and max_shield >= _max_shield and shield < _shield:
			_hurt.y += _shield - shield
		if vehicle != _vehicle:
			if _vehicle != 0:
				_emit("vehicle_left", [_vehicle])
			if vehicle != 0:
				_emit("vehicle_entered", [vehicle])
	_unit = unit
	_health = health
	_shield = shield
	_max_shield = max_shield
	_vehicle = vehicle


## The first `died` naming the character or `dead` after it was alive: once per death.
func _death(at: Vector3) -> void:
	if _died:
		return
	_died = true
	_hurt = Vector2i.ZERO
	_emit("died", [at])


func _on_inventory() -> void:
	var item = _read_armor()
	if item == null:
		return
	if _armor != null and item != _armor:
		_emit("armor_changed", [item])
	_armor = item


func _on_guns() -> void:
	var now = _read_gun()
	if now == null:
		return
	if _gun != null and now != _gun:
		_emit("gun_selected", [now[0], now[1]])
	_gun = now


## The armour's item ("" none), or null while the bridge hasn't said what the slot holds.
func _read_armor():
	var model = _host.ui_model()
	if model == null or not model.knows_slots("armor"):
		return null
	return str(model.stack_at("armor", 1).get("item", ""))


## [selected slot, its gun, the vehicle whose guns], or null before the first `guns`.
func _read_gun():
	var model = _host.ui_model()
	if model == null or (model.guns as Array).is_empty():
		return null
	var sel := int(model.selected_gun)
	var list: Array = model.guns
	var entry = list[sel - 1] if sel >= 1 and sel <= list.size() else null
	var gun := str(entry[0]) if entry is Array and (entry as Array).size() > 0 else ""
	return [sel, gun, int(model.guns_vehicle)]


func _mined_name(msg: Dictionary) -> String:
	if int(msg.get("gi", 0)) == 1:
		return "item-on-ground"
	var world = _host.game_node("world")
	var protos = world.get("protos") if world != null else null
	var p = protos.entity(int(msg.get("p", 0))) if protos != null else null
	return str(p.name) if p != null else ""


static func _ground(msg: Dictionary) -> Vector3:
	return Vector3(int(msg.get("x", 0)) / 256.0, 0.0, int(msg.get("y", 0)) / 256.0)


func _emit(sig: String, args: Array) -> void:
	for api in _char_apis.duplicate():
		var part = api.get("_character")
		if part != null:
			part.callv("emit_signal", ["_" + sig] + args)
