extends SceneTree
## Factorio's keys in Zenith (issues #14 and #26): factorio_keys.gd against fixture config.ini files
## in 2.1's form (config version 13: "; " lines for defaults, read under the set lines, -alternative
## and -controller lines), where config-path.cfg says config.ini is, Zenith's built-in defaults (2.0's
## Map, Next weapon, Shoot selected; --keys-defaults=old for 1.1's), the keys 2.1's defaults share and
## which action each press fires, and settings.gd's bindings: one saved in Zenith's settings over
## Factorio's, a slot left at its default following Factorio, a change in Factorio read again while
## running and what that costs when nothing changed, and "Copy keys from Factorio". Its own settings
## file and fixtures in user://, APPDATA pointed at its own folder for the search (the install's
## config-path.cfg may be read, never a player's config.ini). Run headless:
##   godot --headless --path client -s res://tests/factorio_keys_test.gd
## Prints "FACTORIO KEYS FAILS: 0" when all pass; quits with 1 otherwise.

const Settings := preload("res://scripts/menu/settings.gd")
const Controls := preload("res://scripts/player/controls.gd")
const FactorioKeys := preload("res://scripts/player/factorio_keys.gd")
const Paths := preload("res://scripts/menu/paths.gd")
const ControlsInfo := preload("res://scripts/menu/controls_info.gd")

## Factorio 2.1's own defaults for the controls whose keys moved since 1.1, and those they share a key
## with, as 2.1 writes them in config.ini's "; " lines (from public 2.1 config.ini files and the wiki;
## Map, Next weapon and Shoot selected also from Wube's changelog).
const DEFAULTS_21 := ["; toggle-map=TAB", "; toggle-map-alternative=M", "; next-weapon=C", "; shoot-selected=SHIFT + SPACE",
	"; shoot-enemy=SPACE", "; toggle-rail-layer=G", "; toggle-driving=RETURN", "; toggle-driving-alternative=G",
	"; undo=CONTROL + Z", "; redo=CONTROL + Y", "; redo-alternative=CONTROL + SHIFT + Z", "; drop-cursor=Z",
	"; increase-ui-scale=CONTROL + KP_PLUS", "; decrease-ui-scale=CONTROL + KP_MINUS", "; reset-ui-scale=CONTROL + KP_0",
	"; larger-terrain-building-area=KP_PLUS", "; smaller-terrain-building-area=KP_MINUS", "; copy=CONTROL + C",
	"; give-copper-wire=ALT + C", "; pick-items=F", "; toggle-personal-roboport=ALT + F", "; focus-search=CONTROL + F"]

var _fails := 0
var _dir := ""


func _check(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("FAIL: ", what)


func _write(file: String, lines: Array) -> void:
	DirAccess.make_dir_recursive_absolute(file.get_base_dir())
	var f := FileAccess.open(file, FileAccess.WRITE)
	f.store_string("\r\n".join(lines) + "\r\n")  # Factorio writes Windows line ends on Windows
	f.close()


## A config.ini as Factorio 2.1 writes one, with these set lines in [controls] among its defaults.
func _config(set_lines: Array) -> Array:
	var lines: Array = ["; version=13", "; This is INI file", "[path]", "read-data=__PATH__executable__/../../data",
		"write-data=__PATH__system-write-data__", "", "[input]", "; input-method=keyboard-and-mouse", "", "[controls]",
		"; move-up=W", "", "; move-up-alternative=", "", "; move-up-controller=", "", "; toggle-map=TAB", "",
		"; toggle-map-alternative=M", "", "; next-weapon=C", ""]
	lines.append_array(set_lines)
	lines.append_array(["", "[controller]", "; rotate=Y", "[sound]", "; master-volume=1"])
	return lines


func _initialize() -> void:
	_dir = ProjectSettings.globalize_path("user://factorio_keys_test")
	_wipe(_dir)
	DirAccess.make_dir_recursive_absolute(_dir)
	if Controls.old_defaults_forced():
		# Run with -- --keys-defaults=old: that switch alone (the rest assume the command line doesn't say it).
		_old_keys_forced()
		print("FACTORIO KEYS FAILS: %d" % _fails)
		quit(1 if _fails > 0 else 0)
		return
	_report()
	_where()
	_builtin()
	_bindings()
	_clashes()
	_refresh_cost()
	_same_second()
	_player()
	_where_more()
	_refresh_from_main()
	_debug_line()
	_old_keys()
	print("FACTORIO KEYS FAILS: %d" % _fails)
	quit(1 if _fails > 0 else 0)


## What config.ini's [controls] gives: rebinds, alternatives, modifiers, a cleared key, mouse
## buttons and the wheel, controller lines, controls Zenith hasn't, and the "; " defaults left alone.
func _report() -> void:
	var text := "\n".join(_config(["toggle-driving=TAB", "move-up=UP", "move-up-alternative=KP_8", "rotate-alternative=SHIFT + ALT + T",
		"next-weapon=", "pipette=mouse-button-3", "shoot-selected=CONTROL + mouse-button-1",
		"larger-terrain-building-area-alternative=SHIFT + ALT + mouse-wheel-up", "move-up-controller=controller-dpup",
		"connect-train=CONTROL + J", "copy=CONTROL + SHIFT + C", "toggle-console=GRAVE"]))
	var r: Dictionary = FactorioKeys.report(text)
	var keys: Dictionary = r["keys"]
	_check(keys == {"enter_vehicle": [KEY_TAB, -1], "move_up": [KEY_UP, KEY_KP_8], "rotate": [-1, KEY_T | KEY_MASK_SHIFT | KEY_MASK_ALT],
		"next_gun": [0, -1], "copy": [KEY_C | KEY_MASK_CTRL | KEY_MASK_SHIFT, -1], "toggle_console": [KEY_QUOTELEFT, -1],
		"toggle_map": [KEY_TAB, KEY_M]},
		"config.ini's set lines become Zenith's keys over its \"; \" defaults (Map's Tab and M from them): %s" % [keys])
	_check(r["defaults"] == [["toggle-map", "toggle_map", 0, KEY_TAB], ["toggle-map-alternative", "toggle_map", 1, KEY_M]],
		"defaults lists the \"; \" lines taken: a set line for the slot, a controller line or another section's leave theirs out: %s" % [r["defaults"]])
	var copied: Array = r["copied"]
	_check(copied.size() == 7 and copied.has(["next-weapon", "next_gun", 0, 0]),
		"copied lists each set line taken, a cleared one as 0: %s" % [copied])
	var why := {}
	for s in r["skipped"]:
		why[str(s[0])] = str(s[2])
	_check(why.size() == 5 and why["pipette"].contains("mouse button") and why["shoot-selected"].contains("mouse button")
		and why["larger-terrain-building-area-alternative"].contains("wheel") and why["move-up-controller"].contains("controller")
		and why["connect-train"].contains("no key"), "skipped lists mouse buttons, the wheel, controller lines and controls Zenith hasn't: %s" % [why])
	_check(FactorioKeys.report("")["keys"].is_empty() and FactorioKeys.report("[controls]\n; move-up=W\n")["copied"].is_empty(),
		"no file: nothing; only defaults: nothing copied")
	var only: Dictionary = FactorioKeys.report("[controls]\r\n; move-up=W\r\n; move-up-alternative=\r\n; pipette=mouse-button-3\r\n;comment\r\n")
	_check(only["keys"] == {"move_up": [KEY_W, 0]} and (only["skipped"] as Array).is_empty(),
		"a \"; \" default is taken (an empty one unbound, as in Factorio), one Zenith can't take left to Zenith without a word: %s" % [only["keys"]])
	var d21: Dictionary = FactorioKeys.report("\n".join(["[controls]"] + DEFAULTS_21))["keys"]
	_check(d21.get("shoot_cursor") == [KEY_SPACE | KEY_MASK_SHIFT, -1] and d21.get("toggle_rail_layer") == [KEY_G, -1]
		and d21.get("enter_vehicle") == [KEY_ENTER, KEY_G] and d21.get("redo") == [KEY_Y | KEY_MASK_CTRL, KEY_Z | KEY_MASK_CTRL | KEY_MASK_SHIFT]
		and d21.get("increase_ui_scale") == [KEY_KP_ADD | KEY_MASK_CTRL, -1] and d21.get("reset_ui_scale") == [KEY_KP_0 | KEY_MASK_CTRL, -1],
		"2.1's default lines read as Zenith's keys: %s" % [d21])


## Where config.ini is: the install's config-path.cfg, its placeholders, a folder of the player's
## own, and the zip's own folder.
func _where() -> void:
	var appdata := OS.get_environment("APPDATA").replace("\\", "/")
	var exe := _dir.path_join("install/bin/x64/factorio.exe")
	var cfg := _dir.path_join("install/config-path.cfg")
	# Steam's and the installer's file.
	_write(cfg, ["config-path=__PATH__system-write-data__/config", "", "#comment use-system-read-write-data-directories=false",
		"use-system-read-write-data-directories=true"])
	var steam: Array = FactorioKeys.candidates(exe)
	_check(appdata == "" or str(steam[0]) == appdata.path_join("Factorio/config/config.ini"),
		"Steam's config-path.cfg: %%APPDATA%%\\Factorio\\config first: %s" % [steam])
	# A folder of the player's own.
	var own_dir := _dir.path_join("elsewhere/my factorio config")
	_write(cfg, ["config-path=" + own_dir.replace("/", "\\"), "use-system-read-write-data-directories=true"])
	var custom: Array = FactorioKeys.candidates(exe)
	_check(str(custom[0]) == own_dir.path_join("config.ini"), "config-path.cfg pointing elsewhere is read first: %s" % [custom])
	_write(own_dir.path_join("config.ini"), _config(["toggle-driving=TAB"]))
	FactorioKeys.test_config = ""
	# The zip's: next to the executable, system folders after.
	_write(cfg, ["config-path=__PATH__executable__/../../config", "use-system-read-write-data-directories=false"])
	var zip: Array = FactorioKeys.candidates(exe)
	_check(str(zip[0]) == _dir.path_join("install/config/config.ini") and zip.count(zip[0]) == 1,
		"a zip install's config.ini is in its own config folder: %s" % [zip])
	# No config-path.cfg: the system folder, then the install's.
	DirAccess.remove_absolute(cfg)
	var none: Array = FactorioKeys.candidates(exe)
	_check(none.has(_dir.path_join("install/config/config.ini")) and (appdata == "" or str(none[0]).begins_with(appdata)),
		"without config-path.cfg: the system folder first: %s" % [none])
	_check(FactorioKeys.config_dir("config-path=__PATH__unknown__/x", "C:/f/bin/x64", "C:/a") == ""
		and FactorioKeys.config_dir("config-path=../../cfg", "C:/f/bin/x64", "C:/a") == "C:/f/cfg",
		"an unknown placeholder names nothing; a relative path is from the executable's folder")


## Zenith's own defaults (no config.ini, or the switch off): 2.0's for the three Wube's changelog names,
## 1.1's back with --keys-defaults=old.
func _builtin() -> void:
	var three := ["toggle_map", "next_gun", "shoot_cursor"]
	var events := func() -> Dictionary:
		var out := {}
		for action in three:
			var codes: Array = []
			for ev in InputMap.action_get_events(action):
				codes.append(Settings.event_code(ev as InputEventKey))
			out[action] = codes
		return out
	Controls.old_defaults_override = 1
	Controls.define()
	var old: Dictionary = events.call()
	_check(old == {"toggle_map": [KEY_M], "next_gun": [KEY_TAB], "shoot_cursor": [KEY_C]}, "--keys-defaults=old: 1.1's M, Tab, C: %s" % [old])
	for action in three:
		InputMap.erase_action(action)
	Controls.old_defaults_override = -1  # the command line, which doesn't say old
	Controls.define()
	var now: Dictionary = events.call()
	_check(now == {"toggle_map": [KEY_TAB, KEY_M], "next_gun": [KEY_C], "shoot_cursor": [KEY_SPACE | KEY_MASK_SHIFT]},
		"the built-in defaults are 2.0's: Map Tab or M, Next weapon C, Shoot selected Shift+Space: %s" % [now])


## settings.gd: Factorio's keys under Zenith's saved bindings, the button, a change read again.
func _bindings() -> void:
	Settings.path = _dir.path_join("settings.cfg")
	var ini := _dir.path_join("factorio/config/config.ini")
	_write(ini, _config(["toggle-driving=TAB", "move-up-alternative=KP_8", "pipette=mouse-button-3"]))
	FactorioKeys.test_config = ini
	Controls.define()
	Settings.apply_bindings()
	_check(Settings.keys_for("enter_vehicle")[0] == KEY_TAB and Settings.keys_for("move_up") == [KEY_W, KEY_KP_8]
		and Settings.keys_for("pipette")[0] == KEY_Q, "Factorio's changed keys are Zenith's defaults: %s %s" % [Settings.keys_for("enter_vehicle"), Settings.keys_for("move_up")])

	# Controls already saved in settings.cfg (a binding as every Zenith before 0.2.3 saved it: both
	# slots), and Zenith's own camera key changed: the saved one wins over Factorio's TAB.
	Settings.set_value("controls", "enter_vehicle", "Enter,Kp Enter")
	Settings.set_value("controls", "camera_left", "J,")
	_check(Settings.keys_for("enter_vehicle")[0] == KEY_ENTER, "a binding saved in Zenith wins over Factorio's")

	# Rebinding one slot leaves the other following the default (Factorio's when it changes).
	Settings.bind_slot("move_up", 1, KEY_I)
	_check(str(Settings.get_value("controls", "move_up")) == "default,I" and Settings.keys_for("move_up") == [KEY_W, KEY_I],
		"one slot rebound saves the other as \"default\": %s" % [Settings.get_value("controls", "move_up")])

	# Factorio's controls changed while Zenith runs: read again when asked (main.gd: the window back).
	_check(not Settings.refresh_factorio_keys(), "unchanged config.ini isn't read again")
	OS.delay_msec(1100)  # modified times are in seconds
	_write(ini, _config(["toggle-driving=TAB", "move-up=UP", "move-up-alternative=KP_8"]))
	var again := Settings.refresh_factorio_keys()
	_check(again and Settings.keys_for("move_up") == [KEY_UP, KEY_I] and Settings.keys_for("pipette")[0] == KEY_Q,
		"a change in Factorio is followed while running, in the slot left at default: %s %s" % [again, Settings.keys_for("move_up")])

	# Copy keys from Factorio: Factorio's over the saved ones, Zenith's own controls kept, and the
	# switch on even when it was off.
	Settings.set_value("factorio", "use_factorio_keys", false)
	Settings.reload_factorio_keys()
	_check(Settings.keys_for("enter_vehicle")[0] == KEY_ENTER and Settings.default_keys("enter_vehicle")[0] == KEY_ENTER,
		"with the switch off, Zenith's own keys")
	var r: Dictionary = Settings.copy_factorio_keys()
	_check(r["file"] == ini and (r["reset"] as Array).has("enter_vehicle") and (r["reset"] as Array).has("move_up")
		and not (r["reset"] as Array).has("camera_left"), "the copy reports its file and the bindings put back: %s" % [r["reset"]])
	_check(bool(Settings.get_value("factorio", "use_factorio_keys")) and Settings.keys_for("enter_vehicle")[0] == KEY_TAB
		and Settings.keys_for("move_up") == [KEY_UP, KEY_KP_8] and not Settings.has_value("controls", "enter_vehicle"),
		"after the copy Zenith answers Factorio's keys: %s %s" % [Settings.keys_for("enter_vehicle"), Settings.keys_for("move_up")])
	_check(Settings.keys_for("camera_left")[0] == KEY_J, "Zenith's own controls keep their saved keys")
	var saved := ConfigFile.new()
	saved.load(Settings.path)
	_check(not saved.has_section_key("controls", "enter_vehicle") and saved.get_value("controls", "camera_left", "") == "J,"
		and saved.get_value("factorio", "use_factorio_keys", false) == true, "and settings.cfg says so")
	var tab := false
	for ev in InputMap.action_get_events("enter_vehicle"):
		if ev is InputEventKey and (ev as InputEventKey).physical_keycode == KEY_TAB:
			tab = true
	_check(tab, "the input map has Factorio's TAB for Enter/leave vehicle")

	# A missing config.ini: nothing copied, nothing dropped.
	Settings.bind_slot("enter_vehicle", 0, KEY_G)
	FactorioKeys.test_config = _dir.path_join("nowhere/config.ini")
	var missing: Dictionary = Settings.copy_factorio_keys()
	_check(missing["file"] == "" and (missing["copied"] as Array).is_empty() and (missing["reset"] as Array).is_empty()
		and Settings.keys_for("enter_vehicle")[0] == KEY_G, "a missing config.ini copies nothing and keeps Zenith's bindings")
	var none_text: String = load("res://scripts/menu/settings_window.gd").copy_report_text(missing)
	_check(none_text.contains("wasn't found") and none_text.contains("nothing was copied") and Settings.has_value("controls", "enter_vehicle"),
		"a missing config.ini's message says nothing was copied: %s" % none_text)
	_check(Settings.refresh_factorio_keys() and Settings.default_keys("enter_vehicle")[0] == KEY_ENTER,
		"config.ini gone while running: Zenith's own defaults")
	FactorioKeys.test_config = ""
	for action in Settings.bindable_actions():
		Settings.bind(action, [])


## The keys 2.1's defaults share (with Factorio's "; " lines in effect, and Zenith's built-in ones): no
## clash Settings would show red, and a press fires only its own action (both keys of a pair pressed in
## turn). Then the actions left without any key.
func _clashes() -> void:
	var ini := _dir.path_join("defaults21/config.ini")
	_write(ini, ["; version=13", "[controls]"] + DEFAULTS_21)
	FactorioKeys.test_config = ini
	Settings.set_value("factorio", "use_factorio_keys", true)
	Settings.reload_factorio_keys()
	_check(Settings.keys_for("toggle_rail_layer")[0] == KEY_G and Settings.keys_for("enter_vehicle") == [KEY_ENTER, KEY_G]
		and Settings.keys_for("shoot_cursor")[0] == (KEY_SPACE | KEY_MASK_SHIFT) and Settings.factorio_keys_changed == 0,
		"with only Factorio's default lines, Zenith answers 2.1's keys: %s %s" % [Settings.keys_for("toggle_rail_layer"), Settings.keys_for("enter_vehicle")])
	_check(_all_clashes().is_empty(), "with 2.1's default lines no binding clashes: %s" % [_all_clashes()])
	# Each press against every action that could answer it: [key, the action it fires, the ones it mustn't].
	var presses := [
		[KEY_SPACE | KEY_MASK_SHIFT, "shoot_cursor", ["shoot_enemies"]], [KEY_SPACE, "shoot_enemies", ["shoot_cursor"]],
		[KEY_C, "next_gun", ["copy", "give_copper_wire"]], [KEY_C | KEY_MASK_CTRL, "copy", ["next_gun"]],
		[KEY_C | KEY_MASK_ALT, "give_copper_wire", ["next_gun", "copy"]],
		[KEY_KP_ADD | KEY_MASK_CTRL, "increase_ui_scale", ["larger_tile_area"]], [KEY_KP_ADD, "larger_tile_area", ["increase_ui_scale"]],
		[KEY_KP_SUBTRACT | KEY_MASK_CTRL, "decrease_ui_scale", ["smaller_tile_area"]], [KEY_KP_SUBTRACT, "smaller_tile_area", ["decrease_ui_scale"]],
		[KEY_Z | KEY_MASK_CTRL | KEY_MASK_SHIFT, "redo", ["undo", "drop_item"]], [KEY_Z | KEY_MASK_CTRL, "undo", ["redo", "drop_item"]],
		[KEY_Z, "drop_item", ["undo", "redo"]],
		[KEY_F, "pick_up", ["focus_search", "toggle_personal_roboport"]], [KEY_F | KEY_MASK_CTRL, "focus_search", ["pick_up"]],
		[KEY_F | KEY_MASK_ALT, "toggle_personal_roboport", ["pick_up", "focus_search"]]]
	for p in presses:
		var ev := Controls.key_event(int(p[0]))
		ev.pressed = true
		var wrong: Array = (p[2] as Array).filter(func(a: String) -> bool: return Controls.pressed(ev, a))
		_check(Controls.pressed(ev, str(p[1])) and wrong.is_empty() and ev.is_action(str(p[1]), true),
			"%s fires %s only (not %s)" % [Settings.key_text(int(p[0])), p[1], wrong])
	# The held ones (player_input.gd polls shooting and dropping with their exact modifiers): Shift+Space
	# held is shooting at the cursor, never at enemies; Ctrl+Shift+Z doesn't drop.
	var held := func(code: int, action: String) -> bool:
		var down := Controls.key_event(code)
		down.pressed = true
		Input.parse_input_event(down)
		Input.flush_buffered_events()
		var on := Input.is_action_pressed(action, true)
		var up := Controls.key_event(code)
		up.pressed = false
		Input.parse_input_event(up)
		Input.flush_buffered_events()
		return on
	_check(held.call(KEY_SPACE | KEY_MASK_SHIFT, "shoot_cursor") and not held.call(KEY_SPACE | KEY_MASK_SHIFT, "shoot_enemies")
		and held.call(KEY_SPACE, "shoot_enemies") and not held.call(KEY_SPACE, "shoot_cursor")
		and not held.call(KEY_Z | KEY_MASK_CTRL | KEY_MASK_SHIFT, "drop_item") and held.call(KEY_Z, "drop_item"),
		"held: Shift+Space shoots at the cursor only, Space at enemies only, Ctrl+Shift+Z doesn't drop")
	_held_pick_up()
	# G: the rail layer with rails in hand, else getting in (player_input.gd tries the rail layer first).
	var g := Controls.key_event(KEY_G)
	g.pressed = true
	_check(Controls.pressed(g, "toggle_rail_layer") and Controls.pressed(g, "enter_vehicle") and Controls.shared("enter_vehicle", "toggle_rail_layer")
		and Settings.conflicts("enter_vehicle", KEY_G).is_empty() and Settings.conflicts("toggle_rail_layer", KEY_G).is_empty(),
		"G is the rail layer's and getting in's, shared by design (rails in hand decide), not a clash")
	print("keyless with 2.1's default lines: %s" % [_keyless()])
	# Zenith's built-in defaults (the switch off) have no clash either.
	Settings.set_value("factorio", "use_factorio_keys", false)
	Settings.reload_factorio_keys()
	_check(_all_clashes().is_empty(), "Zenith's built-in defaults: no binding clashes: %s" % [_all_clashes()])
	print("keyless with Zenith's built-in defaults: %s" % [_keyless()])
	FactorioKeys.test_config = ""


## Pick up (F) held, as player_input.gd polls it (Input.is_action_pressed("pick_up", true)): F alone picks up,
## Ctrl+F (search) and Alt+F (the personal roboport) held don't. What an exact match does when the modifier and F
## overlap: Godot keeps whether F's own last event matched exactly, so a modifier let go with F still down doesn't
## start picking (F has to be pressed again), and a modifier pressed while F is held doesn't stop it.
func _held_pick_up() -> void:
	var send := func(code: int, down: bool, ctrl := false, alt := false) -> void:
		var ev := Controls.key_event(code)
		ev.pressed = down
		ev.ctrl_pressed = ctrl or ev.ctrl_pressed
		ev.alt_pressed = alt or ev.alt_pressed
		Input.parse_input_event(ev)
		Input.flush_buffered_events()
	var picks := func() -> bool: return Input.is_action_pressed("pick_up", true)
	send.call(KEY_F, true)
	var alone: bool = picks.call()
	send.call(KEY_F, false)
	_check(alone and not picks.call(), "held: F alone picks up, and stops when let go")
	for m in [[KEY_CTRL, "focus_search", true, false], [KEY_ALT, "toggle_personal_roboport", false, true]]:
		var mod := "Ctrl" if m[2] else "Alt"
		send.call(int(m[0]), true, m[2], m[3])
		send.call(KEY_F, true, m[2], m[3])
		var own := Input.is_action_just_pressed(str(m[1]), true)
		var under: bool = picks.call()
		var loose := Input.is_action_pressed("pick_up")  # the old poll (--pickup-exact=off) did pick up
		send.call(int(m[0]), false)
		var after: bool = picks.call()
		send.call(KEY_F, false)
		send.call(KEY_F, true)
		var again: bool = picks.call()
		send.call(int(m[0]), true, m[2], m[3])
		var kept: bool = picks.call()
		send.call(int(m[0]), false)
		send.call(KEY_F, false)
		_check(own and not under and loose and not after and again and kept and not picks.call(),
			"held: %s+F fires %s and doesn't pick up (the loose poll did: %s); %s let go with F still down doesn't start it (%s), F pressed again does (%s); %s pressed while F is held doesn't stop it (%s)"
			% [mod, m[1], loose, mod, after, again, mod, kept])


## Every [action, key, the others it clashes with] Settings → Controls would show red.
func _all_clashes() -> Array:
	var out: Array = []
	for action in Settings.bindable_actions():
		for code in Settings.keys_for(action):
			var c := Settings.conflicts(action, int(code))
			if not c.is_empty():
				out.append([action, Settings.key_text(int(code)), c])
	return out


## The actions with no key at all, Zenith's own (not Factorio's controls) marked.
func _keyless() -> Array:
	var factorio := {}
	for control in FactorioKeys.ACTIONS:
		factorio[FactorioKeys.ACTIONS[control]] = true
	var out: Array = []
	for action in Settings.bindable_actions():
		if Settings.keys_for(action).all(func(c: Variant) -> bool: return int(c) == 0):
			out.append(str(action) + ("" if factorio.has(action) else " (Zenith's own)"))
	return out


## What Zenith's window coming back costs (main.gd's focus-in): with config.ini unchanged, a file's
## modified time, no search for the install (no reg.exe, no Steam library list). A change is read without
## a search; a new install setting looks again; with none found, at most once a minute.
func _refresh_cost() -> void:
	var appdata := _dir.path_join("appdata")
	var real_appdata := OS.get_environment("APPDATA")
	OS.set_environment("APPDATA", appdata)
	var ini := appdata.path_join("Factorio/config/config.ini")
	_write(ini, _config(["toggle-driving=TAB"]))
	FactorioKeys.test_config = ""
	Settings.set_value("factorio", "executable", "")
	Settings.set_value("factorio", "use_factorio_keys", true)
	Settings.reload_factorio_keys()
	var searches := Paths.exe_searches
	var lookups := Settings.factorio_keys_lookups
	var file := FactorioKeys.config_path()
	_check(file == ini and Settings.keys_for("enter_vehicle")[0] == KEY_TAB, "the search finds the fixture's config.ini: %s" % file)
	var any := false
	for i in 20:
		any = Settings.refresh_factorio_keys() or any
	_check(not any and Paths.exe_searches == searches and Settings.factorio_keys_lookups == lookups,
		"20 focus-ins with config.ini unchanged: nothing read, %d install searches, %d lookups" % [Paths.exe_searches - searches, Settings.factorio_keys_lookups - lookups])
	var t := Time.get_ticks_usec()
	for i in 100:
		Settings.refresh_factorio_keys()
	print("an unchanged focus-in: %.1f us" % [(Time.get_ticks_usec() - t) / 100.0])
	OS.delay_msec(1100)  # modified times are in seconds
	_write(ini, _config(["toggle-driving=G"]))
	_check(Settings.refresh_factorio_keys() and Settings.keys_for("enter_vehicle")[0] == KEY_G and Paths.exe_searches == searches
		and Settings.factorio_keys_lookups == lookups, "a change in config.ini is read without a search")
	Settings.set_value("factorio", "executable", _dir.path_join("no-install"))
	Settings.refresh_factorio_keys()
	_check(Settings.factorio_keys_lookups == lookups + 1, "a new Factorio install setting looks again")
	Settings.set_value("factorio", "executable", "")
	Settings.refresh_factorio_keys()
	lookups = Settings.factorio_keys_lookups
	DirAccess.remove_absolute(ini)
	var gone := Settings.refresh_factorio_keys()
	_check(gone and Settings.factorio_keys_lookups == lookups + 1 and Settings.default_keys("enter_vehicle")[0] == KEY_ENTER,
		"config.ini gone: looked for once, Zenith's own keys")
	for i in 10:
		Settings.refresh_factorio_keys()
	_check(Settings.factorio_keys_lookups == lookups + 1, "none found: no new look within the minute (%d)" % [Settings.factorio_keys_lookups - lookups])
	var before := Paths.exe_searches
	Settings.copy_factorio_keys()
	_check(Paths.exe_searches == before + 1, "the copy button searches for the install afresh")
	Settings.set_value("factorio", "use_factorio_keys", false)
	Settings.reload_factorio_keys()
	OS.set_environment("APPDATA", real_appdata)


## The 36 controls a long-customised player changed in Factorio 2.1 (issue #26's report): keys,
## modifiers, alternatives, cleared ones, mouse buttons, the wheel, a controller line, controls
## Zenith hasn't, a key it doesn't know.
const PLAYER_SET := ["move-up=E", "move-down=D", "move-left=S", "move-right=F", "open-character-gui=I", "toggle-map=M",
	"toggle-map-alternative=", "open-technology-gui=Y", "rotate=W", "reverse-rotate=SHIFT + W", "pick-items=G",
	"pipette=mouse-button-3", "pipette-alternative=Q", "drop-cursor=V", "toggle-driving=RETURN",
	"shoot-selected=CONTROL + mouse-button-1", "next-weapon=TAB", "toggle-console=GRAVE", "quick-bar-button-1-alternative=KP_1",
	"quick-bar-button-2-alternative=KP_2", "quick-bar-button-3-alternative=KP_3",
	"larger-terrain-building-area=SHIFT + ALT + mouse-wheel-up", "redo=CONTROL + SHIFT + Z", "connect-train=CONTROL + J",
	"zoom-in-alternative=KP_PLUS", "production-statistics=F11", "clear-cursor=CAPSLOCK", "copy=CONTROL + SHIFT + C",
	"open-factoriopedia=F4", "cycle-quality-up=PAGEUP", "cycle-quality-down=PAGEDOWN", "move-up-controller=controller-dpup",
	"toggle-personal-roboport=CONTROL + F12", "flip-horizontal=AC_BACK", "give-blueprint=CONTROL + SHIFT + ALT + K",
	"logistic-networks="]
## The set lines above Zenith can't follow, and why (a word of factorio_keys.gd's reason).
const PLAYER_SKIPPED := {"pipette": "mouse button", "shoot-selected": "mouse button", "larger-terrain-building-area": "wheel",
	"connect-train": "no key", "zoom-in-alternative": "no key", "move-up-controller": "controller", "flip-horizontal": "doesn't know"}

## settings.cfg exactly as Zenith 0.2.1's own code (release 833f2cf4's settings.gd) wrote it for a player with
## the config.ini above who then changed, in Zenith's Settings > Controls: Enter/leave vehicle's key to G,
## Move up's alternative to I, the map's alternative to N, Rotate to R (both slots), and the camera's
## Rotate left and Factorio's view (Zenith's own). 0.2.1 saved both slots, Factorio's key of the day included.
const SETTINGS_021 := ["[meta]", "", "ssao_off=true", "belt_auto=true", "mod_anim_off=true", "full_screen_resolution=true",
	"grass_preset=true", "migrated=true", "", "[graphics]", "", "shadows=\"high\"", "", "[controls]", "",
	"enter_vehicle=\"G,Kp Enter\"", "move_up=\"E,I\"", "toggle_map=\"M,N\"", "rotate=\"R,\"", "camera_left=\"J,\"",
	"factorio_view=\"F8,\""]


## config.ini as 2.1 writes it: every control's default as a "; " line, the player's changes set in its place.
func _player_ini(set_lines: Array) -> Array:
	var lines: Array = ["; version=13", "; This is INI file : https://en.wikipedia.org/wiki/INI_file#Format",
		"[path]", "read-data=__PATH__executable__/../../data", "write-data=__PATH__system-write-data__", "", "[other]",
		"; check-updates=true", "", "[controls]"]
	for d in ["move-up=W", "toggle-map=TAB", "toggle-map-alternative=M", "rotate=R", "pipette=Q", "next-weapon=C",
			"shoot-selected=SHIFT + SPACE", "redo-alternative=CONTROL + SHIFT + Z", "toggle-rail-layer=G", "zoom-in=mouse-wheel-up"]:
		lines.append_array(["; " + d, ""])
	lines.append_array(set_lines)
	lines.append_array(["", "[controller]", "; rotate=controller-y", "", "[sound]", "; master-volume=1.000000", ""])
	return lines


## The tester's case: config.ini written again in the second it was read, so its modified time (whole
## seconds) is unchanged. The text's length and hash tell; once the time is a few seconds old, a
## focus-in reads only the time again.
func _same_second() -> void:
	var ini := _dir.path_join("same/config.ini")
	var pad: Array = []  # a real config.ini's size, about 30 KB of "; " lines
	for i in 900:
		pad.append_array(["; quick-bar-button-%d-alternative=CONTROL + %d" % [i, i % 10], ""])
	FactorioKeys.test_config = ini
	Settings.set_value("factorio", "use_factorio_keys", true)
	var same := false
	for attempt in 3:  # start just after a second turns, so both writes share it
		var t0 := int(Time.get_unix_time_from_system())
		while int(Time.get_unix_time_from_system()) == t0:
			OS.delay_msec(5)
		_write(ini, _config(pad + ["toggle-driving=TAB"]))
		Settings.reload_factorio_keys()
		var first := FileAccess.get_modified_time(ini)
		_write(ini, _config(pad + ["toggle-driving=Y"]))
		if FileAccess.get_modified_time(ini) == first:
			same = true
			break
	_check(same and FileAccess.get_file_as_bytes(ini).size() > 25000, "the fixture's two writes share a modified second (%d bytes)" % FileAccess.get_file_as_bytes(ini).size())
	_check(Settings.refresh_factorio_keys() and Settings.keys_for("enter_vehicle")[0] == KEY_Y,
		"a change written in the second it was read is read on the next focus-in: %s" % [Settings.keys_for("enter_vehicle")])
	var checks := Settings.factorio_keys_text_checks
	var t := Time.get_ticks_usec()
	var again := 0
	for i in 100:
		if Settings.refresh_factorio_keys():
			again += 1
	var fresh := (Time.get_ticks_usec() - t) / 100.0
	_check(again == 0 and Settings.factorio_keys_text_checks - checks == 100,
		"just after a write, an unchanged focus-in compares the text and reads nothing again (%d, %d)" % [again, Settings.factorio_keys_text_checks - checks])
	OS.delay_msec(Settings.FACTORIO_KEYS_SAME_SEC * 1000 + 100)
	Settings.refresh_factorio_keys()  # the check that settles it
	checks = Settings.factorio_keys_text_checks
	t = Time.get_ticks_usec()
	for i in 100:
		Settings.refresh_factorio_keys()
	var settled := (Time.get_ticks_usec() - t) / 100.0
	print("an unchanged focus-in: %.1f us within %d s of a write (the text compared), %.1f us after" % [fresh, Settings.FACTORIO_KEYS_SAME_SEC, settled])
	_check(Settings.factorio_keys_text_checks == checks, "settled: the modified time alone (%d text reads)" % [Settings.factorio_keys_text_checks - checks])
	_check(fresh < 2000.0 and settled < 500.0, "both cheap: %.1f us, %.1f us" % [fresh, settled])
	FactorioKeys.test_config = ""
	Settings.reload_factorio_keys()


## Issue #26's player: a long-customised config.ini and a settings.cfg written by 0.2.1. What Zenith
## uses before the button, then after Copy keys from Factorio: every keyboard control Factorio changed
## is Factorio's, the skips named, Zenith's own controls and other settings untouched; then the slot fix
## against a later change in Factorio.
func _player() -> void:
	var dir := _dir.path_join("player")
	var ini := dir.path_join("config.ini")
	_write(ini, _player_ini(PLAYER_SET))
	var cfg := dir.path_join("settings.cfg")
	_write(cfg, SETTINGS_021)
	Settings.path = cfg
	Settings._loaded = false
	Settings.set_value("factorio", "use_factorio_keys", true, false)
	FactorioKeys.test_config = ini
	Settings.reload_factorio_keys()

	# The upgrade: 0.2.1's file read as it was; loading rewrote none of its controls.
	var on_disk := ConfigFile.new()
	on_disk.load(cfg)
	_check(on_disk.get_value("controls", "enter_vehicle", "") == "G,Kp Enter" and on_disk.get_value("controls", "move_up", "") == "E,I"
		and on_disk.get_value("graphics", "shadows", "") == "high", "0.2.1's settings.cfg is kept as it was on reading")
	var before := {"enter_vehicle": [KEY_G, KEY_KP_ENTER], "move_up": [KEY_E, KEY_I], "toggle_map": [KEY_M, KEY_N],
		"rotate": [KEY_R, 0], "camera_left": [KEY_J, 0], "factorio_view": [KEY_F8, 0],
		# not saved in Zenith: Factorio's, or Zenith's where Factorio's can't be a key
		"move_down": [KEY_D, KEY_DOWN], "open_screen": [KEY_I, 0], "open_technology": [KEY_Y, 0], "reverse_rotate": [KEY_W | KEY_MASK_SHIFT, 0],
		"pick_up": [KEY_G, 0], "pipette": [KEY_Q, KEY_Q], "drop_item": [KEY_V, 0], "next_gun": [KEY_TAB, 0],
		# Shoot selected on a mouse button: Zenith's own key, 2.0's Shift+Space; redo's alternative from its "; " line
		"shoot_cursor": [KEY_SPACE | KEY_MASK_SHIFT, 0], "larger_tile_area": [KEY_KP_ADD, 0], "flip_horizontal": [KEY_H, 0],
		"redo": [KEY_Z | KEY_MASK_CTRL | KEY_MASK_SHIFT, KEY_Z | KEY_MASK_CTRL | KEY_MASK_SHIFT], "logistic_networks": [0, 0], "quickbar_1": [KEY_1, KEY_KP_1],
		"give_blueprint": [KEY_K | KEY_MASK_CTRL | KEY_MASK_SHIFT | KEY_MASK_ALT, 0], "camera_tilt_up": [KEY_PAGEUP, 0]}
	var wrong := []
	for a in before:
		if Settings.keys_for(a) != before[a]:
			wrong.append("%s %s (expected %s)" % [a, Settings.keys_for(a), before[a]])
	_check(wrong.is_empty(), "before the copy: 0.2.1's saved pairs win, the rest follow Factorio: %s" % [wrong])

	var r: Dictionary = Settings.copy_factorio_keys()
	var copied: Array = r["copied"]
	var skipped := {}
	for sk in r["skipped"]:
		skipped[str(sk[0])] = str(sk[2])
	_check(copied.size() == PLAYER_SET.size() - PLAYER_SKIPPED.size() and skipped.size() == PLAYER_SKIPPED.size(),
		"the copy: %d copied, %d skipped of %d set lines" % [copied.size(), skipped.size(), PLAYER_SET.size()])
	for control in PLAYER_SKIPPED:
		_check(skipped.has(control) and skipped[control].contains(PLAYER_SKIPPED[control]), "skipped %s: %s" % [control, skipped.get(control)])
	# Every keyboard control Factorio changed is now Factorio's, in its slot.
	wrong = []
	for line in PLAYER_SET:
		var control := str(line).get_slice("=", 0)
		var slot := 1 if control.ends_with("-alternative") else 0
		var name := control.trim_suffix("-alternative")
		if skipped.has(control) or not FactorioKeys.ACTIONS.has(name):
			continue
		var want := FactorioKeys.key_code(str(line).get_slice("=", 1))
		var got: int = Settings.keys_for(FactorioKeys.ACTIONS[name])[slot]
		if got != want:
			wrong.append("%s: %s, Factorio %s" % [control, got, want])
	_check(wrong.is_empty(), "after the copy every keyboard control changed in Factorio is Factorio's: %s" % [wrong])
	_check(Settings.keys_for("rotate") == [KEY_W, 0] and Settings.keys_for("enter_vehicle") == [KEY_ENTER, KEY_KP_ENTER]
		and Settings.keys_for("toggle_map") == [KEY_M, 0] and Settings.keys_for("move_up") == [KEY_E, KEY_UP],
		"saved pairs dropped: %s %s %s" % [Settings.keys_for("rotate"), Settings.keys_for("toggle_map"), Settings.keys_for("move_up")])
	var reset: Array = r["reset"]
	reset.sort()
	_check(reset == ["enter_vehicle", "move_up", "rotate", "toggle_map"], "the bindings put back: %s" % [reset])
	_check(Settings.keys_for("camera_left") == [KEY_J, 0] and Settings.keys_for("factorio_view") == [KEY_F8, 0]
		and Settings.keys_for("camera_tilt_up") == [KEY_PAGEUP, 0], "Zenith's own controls untouched")
	on_disk = ConfigFile.new()
	on_disk.load(cfg)
	_check(on_disk.get_value("graphics", "shadows", "") == "high" and on_disk.get_value("controls", "camera_left", "") == "J,"
		and on_disk.get_value("controls", "factorio_view", "") == "F8," and not on_disk.has_section_key("controls", "rotate"),
		"settings.cfg after the copy: other settings and Zenith's own controls kept")

	# The message (settings_window.gd's text): copied, skipped with why, how many put back, the file.
	var text: String = load("res://scripts/menu/settings_window.gd").copy_report_text(r)
	# Keys as Factorio shows them, skipped lines by Zenith's control names (Factorio's where Zenith has none).
	var name_of := func(a: String) -> String: return ControlsInfo.name_of(a)
	_check(text.contains("Copied (29):") and text.contains("Not copied (7):")
		and text.contains("  %s: Middle-click (a mouse button" % name_of.call("pipette"))
		and text.contains("  %s: Control + Left-click (a mouse button" % name_of.call("shoot_cursor"))
		and text.contains("  %s: Shift + Alt + Mouse wheel up (the mouse wheel" % name_of.call("larger_tile_area"))
		and text.contains("  %s (controller): controller-dpup" % name_of.call("move_up"))
		and text.contains("  connect-train: Control + J (Zenith has no key") and text.contains("  %s: AC_BACK (a key Zenith" % name_of.call("flip_horizontal"))
		and text.contains("  %s: `\n" % name_of.call("toggle_console")) and text.contains("  %s: Control + Shift + C\n" % name_of.call("copy"))
		and text.contains("  %s: Caps Lock\n" % name_of.call("clear_cursor")) and text.contains("  %s (alternative): Numpad 1\n" % name_of.call("quickbar_1"))
		and not text.contains("QuoteLeft") and not text.contains("Kp ") and text.contains("put back to Factorio's: 4")
		and text.contains("unbound, as in Factorio") and text.ends_with("Read from: " + ini), "the message: %s" % [text])
	# The copied keys one of Zenith's own controls also has: camera tilt's Page Up and Down, and in dev builds the
	# debug line's F4 and the debug menu's Control + F12 (a public build has no key on either; _debug_line).
	var clashes := {}
	for c in r["clashes"]:
		clashes[str(c[0])] = [int(c[1]), c[2]]
	var dev := Settings.dev_tools()
	_check(clashes.get("cycle_quality_up") == [KEY_PAGEUP, ["camera_tilt_up"]] and clashes.get("cycle_quality_down") == [KEY_PAGEDOWN, ["camera_tilt_down"]]
		and (clashes.get("toggle_factoriopedia") == [KEY_F4, ["debug_line"]]) == dev
		and (clashes.get("toggle_personal_roboport") == [KEY_F12 | KEY_MASK_CTRL, ["debug_menu"]]) == dev and clashes.size() == (4 if dev else 2),
		"clashes with Zenith's own controls (dev build %s): %s" % [dev, r["clashes"]])
	_check(text.contains("Also on one of Zenith's own controls")
		and text.contains("  Page Up: %s, also %s" % [name_of.call("cycle_quality_up"), name_of.call("camera_tilt_up")])
		and text.contains("  Control + F12: %s, also %s" % [name_of.call("toggle_personal_roboport"), name_of.call("debug_menu")]) == dev,
		"the message names the clashes")
	print("copy message: " + text.replace("\n", " | "))
	# No config.ini: the folder named the way each OS has it.
	var sw: GDScript = load("res://scripts/menu/settings_window.gd")
	_check(sw.copy_report_text({"file": ""}, "Windows").contains("%APPDATA%\\Factorio\\config")
		and sw.copy_report_text({"file": ""}, "Linux").contains("~/.factorio/config")
		and sw.copy_report_text({"file": ""}, "macOS").contains("~/Library/Application Support/factorio/config"),
		"the no-file message names each OS's folder: %s" % sw.copy_report_text({"file": ""}, "Linux"))
	# Factorio's names for keys whatever Godot calls them.
	var labels := {KEY_QUOTELEFT: "`", KEY_SPACE | KEY_MASK_SHIFT: "Shift + Spacebar", KEY_ENTER: "Enter", KEY_KP_ADD | KEY_MASK_CTRL: "Control + Numpad +",
		KEY_PAGEDOWN: "Page Down", KEY_K | KEY_MASK_CTRL | KEY_MASK_SHIFT | KEY_MASK_ALT: "Control + Shift + Alt + K", KEY_F11: "F11",
		KEY_BACKSLASH: "\\", KEY_EQUAL: "=", KEY_KP_PERIOD: "Numpad .", KEY_ESCAPE: "Escape", KEY_7: "7", 0: ""}
	var bad := []
	for code in labels:
		if FactorioKeys.key_label(code) != labels[code]:
			bad.append("%s -> %s" % [labels[code], FactorioKeys.key_label(code)])
	_check(bad.is_empty() and FactorioKeys.value_label("GRAVE") == "`" and FactorioKeys.value_label("mouse-button-5") == "Mouse button 5"
		and FactorioKeys.value_label("") == "unbound", "key labels as Factorio's: %s" % [bad])

	# The slot fix after the copy: rebinding the alternative leaves the primary following Factorio,
	# also after a later change in config.ini; rebinding to the key it already has saves nothing.
	Settings.bind_slot("move_up", 1, KEY_I)
	_check(str(Settings.get_value("controls", "move_up")) == "default,I", "one slot rebound: %s" % [Settings.get_value("controls", "move_up")])
	Settings.bind_slot("pick_up", 0, KEY_G)
	_check(not Settings.has_value("controls", "pick_up"), "rebinding to the key it has saves nothing")
	OS.delay_msec(1100)
	var later: Array = PLAYER_SET.duplicate()
	later[later.find("move-up=E")] = "move-up=UP"
	later[later.find("toggle-driving=RETURN")] = "toggle-driving=G"
	_write(ini, _player_ini(later))
	_check(Settings.refresh_factorio_keys() and Settings.keys_for("move_up") == [KEY_UP, KEY_I] and Settings.keys_for("enter_vehicle")[0] == KEY_G,
		"a later change in Factorio reaches the slot left at default: %s" % [Settings.keys_for("move_up")])
	# Factorio's move-up then on a mouse button: the slot goes back to Zenith's own W.
	OS.delay_msec(1100)
	later[later.find("move-up=UP")] = "move-up=mouse-button-4"
	_write(ini, _player_ini(later))
	Settings.refresh_factorio_keys()
	_check(Settings.keys_for("move_up") == [KEY_W, KEY_I], "a slot Factorio moved to a mouse button is Zenith's own: %s" % [Settings.keys_for("move_up")])

	# Not read again when nothing changed: the keys read stay the same object, and it's quick.
	Settings.factorio_keys["__untouched__"] = true
	var t := Time.get_ticks_usec()
	var again := 0
	for i in 200:
		if Settings.refresh_factorio_keys():
			again += 1
	var each := (Time.get_ticks_usec() - t) / 200.0
	print("refresh with nothing changed: %.1f us each" % each)
	_check(again == 0 and Settings.factorio_keys.has("__untouched__"), "an unchanged config.ini isn't read again (%d of 200)" % again)
	_check(each < 2000.0, "refresh with nothing changed is cheap: %.1f us" % each)
	Settings.factorio_keys.erase("__untouched__")
	# The switch off: no refresh at all, Zenith's own keys.
	Settings.set_value("factorio", "use_factorio_keys", false)
	Settings.reload_factorio_keys()
	OS.delay_msec(1100)
	_write(ini, _player_ini(PLAYER_SET))
	_check(not Settings.refresh_factorio_keys() and Settings.keys_for("rotate") == [KEY_R, 0], "with Use the keys set in Factorio off, no refresh")
	Settings.set_value("factorio", "use_factorio_keys", true)
	Settings.reload_factorio_keys()
	FactorioKeys.test_config = ""


## config-path.cfg's other forms, and config.ini with a byte order mark and Windows line ends. Reads
## no file of the machine's own: only fixtures under user://.
func _where_more() -> void:
	var exe := _dir.path_join("where2/Factorio/bin/x64/factorio.exe")
	var root := _dir.path_join("where2/Factorio")
	var cfg := root.path_join("config-path.cfg")
	var write := FactorioKeys.system_write_dir()
	var sys_ini := write.path_join("config/config.ini") if write != "" else ""
	# Steam/installer, Windows line ends.
	_write(cfg, ["config-path=__PATH__system-write-data__/config", "use-system-read-write-data-directories=true"])
	var c: Array = FactorioKeys.candidates(exe)
	_check(sys_ini == "" or (str(c[0]) == sys_ini and c.count(sys_ini) == 1 and c.has(root.path_join("config/config.ini"))),
		"Steam/installer: the system folder once, first: %s" % [c])
	# The zip: its own config folder first.
	_write(cfg, ["config-path=__PATH__executable__/../../config", "use-system-read-write-data-directories=false"])
	c = FactorioKeys.candidates(exe)
	_check(str(c[0]) == root.path_join("config/config.ini"), "zip/portable: its own folder first: %s" % [c])
	# A custom absolute folder (Windows separators), and a relative one.
	var mine := _dir.path_join("where2/My Config")
	_write(cfg, ["config-path=" + mine.replace("/", "\\"), "use-system-read-write-data-directories=true"])
	c = FactorioKeys.candidates(exe)
	_check(str(c[0]) == mine.path_join("config.ini"), "a custom absolute folder first: %s" % [c])
	_write(cfg, ["config-path=..\\..\\my-config", "use-system-read-write-data-directories=false"])
	c = FactorioKeys.candidates(exe)
	_check(str(c[0]) == root.path_join("my-config/config.ini"), "a relative folder, from the executable's: %s" % [c])
	# use-system... false with no config-path line: the install's own folder first.
	_write(cfg, ["use-system-read-write-data-directories=false"])
	c = FactorioKeys.candidates(exe)
	_check(str(c[0]) == root.path_join("config/config.ini"), "use-system-read-write-data-directories=false: the install's own first: %s" % [c])
	# A byte order mark before the first line (an editor saved it so).
	var f := FileAccess.open(cfg, FileAccess.WRITE)
	f.store_buffer(PackedByteArray([0xEF, 0xBB, 0xBF]))
	f.store_string("config-path=" + mine + "\r\nuse-system-read-write-data-directories=true\r\n")
	f.close()
	c = FactorioKeys.candidates(exe)
	_check(str(c[0]) == mine.path_join("config.ini"), "config-path.cfg with a byte order mark: %s" % [c])
	# Missing: the system folder, then the install's own.
	DirAccess.remove_absolute(cfg)
	c = FactorioKeys.candidates(exe)
	_check(c.has(root.path_join("config/config.ini")) and (sys_ini == "" or str(c[0]) == sys_ini), "no config-path.cfg: %s" % [c])
	# No install known: the system folder only.
	c = FactorioKeys.candidates("")
	_check(sys_ini == "" or str(c[0]) == sys_ini, "no install known: the system folder: %s" % [c])
	# config.ini with a byte order mark and Windows line ends, read through the file as Zenith does.
	var ini := _dir.path_join("where2/bom/config.ini")
	DirAccess.make_dir_recursive_absolute(ini.get_base_dir())
	f = FileAccess.open(ini, FileAccess.WRITE)
	f.store_buffer(PackedByteArray([0xEF, 0xBB, 0xBF]))
	f.store_string("[controls]\r\ntoggle-driving=TAB\r\n; move-up=W\r\nmove-up-alternative=KP_8\r\n")
	f.close()
	var k: Dictionary = FactorioKeys.keys_from(FileAccess.get_file_as_string(ini))
	_check(k.get("enter_vehicle", []) == [KEY_TAB, -1] and k.get("move_up", []) == [KEY_W, KEY_KP_8],
		"config.ini with a byte order mark on [controls]' own line, Windows line ends: %s" % [k])


## main.gd's own handler for the window getting the focus back: it reads Factorio's keys again, or with
## --factorio-keys-refresh=off it doesn't (run this test with -- --factorio-keys-refresh=off to check that way).
func _refresh_from_main() -> void:
	var ini := _dir.path_join("main/config.ini")
	_write(ini, _config(["toggle-driving=TAB"]))
	FactorioKeys.test_config = ini
	Settings.reload_factorio_keys()
	OS.delay_msec(1100)
	_write(ini, _config(["toggle-driving=Y"]))
	var main: Node = load("res://scripts/main.gd").new()
	main.notification(NOTIFICATION_APPLICATION_FOCUS_IN)
	main.free()
	var off := Settings.arg_value("--factorio-keys-refresh=") == "off"
	var key: int = Settings.default_keys("enter_vehicle")[0]
	_check(key == (KEY_TAB if off else KEY_Y), "main.gd on the focus back (refresh %s): Enter/leave vehicle %s" % ["off" if off else "on", key])
	FactorioKeys.test_config = ""


## The debug line's key by build (issue #26): F4 in a dev build; in a public one no key by default, still listed in
## Settings → Controls and bindable, so an F4 copied from Factorio (Factoriopedia) clashes with nothing. A binding
## saved keeps its key in both, and one made in a public build to F4 stays F4.
func _debug_line() -> void:
	var dir := _dir.path_join("debug_line")
	var ini := dir.path_join("config.ini")
	_write(ini, _config(["open-factoriopedia=F4"]))
	Settings.path = dir.path_join("settings.cfg")
	Settings._loaded = false
	Settings.set_value("factorio", "use_factorio_keys", false)
	FactorioKeys.test_config = ini
	var was := Settings.dev_tools_override
	var f4 := Controls.key_event(KEY_F4)
	f4.pressed = true
	var f3 := Controls.key_event(KEY_F3)
	f3.pressed = true
	for dev in [false, true]:
		var build := "dev" if dev else "public"
		Settings.dev_tools_override = 1 if dev else 0
		Controls.define()
		Settings.apply_bindings()
		_check(Settings.keys_for("debug_line") == ([KEY_F4, 0] if dev else [0, 0]) and Settings.default_keys("debug_line") == Settings.keys_for("debug_line")
			and Controls.pressed(f4, "debug_line") == dev, "%s: the debug line's default key %s" % [build, Settings.keys_for("debug_line")])
		_check(Settings.bindable_actions().has("debug_line") and ControlsInfo.name_of("debug_line") == "Debug line",
			"%s: Debug line listed in Settings > Controls" % build)
		var r: Dictionary = Settings.copy_factorio_keys()
		var fp := (r["clashes"] as Array).filter(func(c: Array) -> bool: return str(c[0]) == "toggle_factoriopedia")
		var text: String = load("res://scripts/menu/settings_window.gd").copy_report_text(r)
		_check(Settings.keys_for("toggle_factoriopedia")[0] == KEY_F4 and fp.is_empty() != dev and text.contains("  F4: ") == dev,
			"%s: Factoriopedia's F4 copied from Factorio %s the debug line: %s" % [build, "clashes with" if dev else "doesn't clash with", r["clashes"]])
		# Bound by the player: kept, in this build and the other.
		Settings.bind_slot("debug_line", 0, KEY_F3)
		_check(Settings.keys_for("debug_line") == [KEY_F3, 0] and Controls.pressed(f3, "debug_line") and not Controls.pressed(f4, "debug_line"),
			"%s: the debug line bound to F3: %s (saved %s)" % [build, Settings.keys_for("debug_line"), Settings.get_value("controls", "debug_line")])
		Settings.dev_tools_override = 0 if dev else 1
		Settings.apply_bindings()
		_check(Settings.keys_for("debug_line")[0] == KEY_F3 and Controls.pressed(f3, "debug_line"),
			"%s's F3 kept in the %s build: %s" % [build, "public" if dev else "dev", Settings.keys_for("debug_line")])
		Settings.bind("debug_line", [])
		Settings.set_value("factorio", "use_factorio_keys", false)
	# Bound to F4 in a public build: saved as F4, so a dev build keeps it too, and a public one answers it.
	Settings.dev_tools_override = 0
	Settings.apply_bindings()
	Settings.bind_slot("debug_line", 0, KEY_F4)
	var saved := str(Settings.get_value("controls", "debug_line"))
	_check(saved.begins_with("F4") and Controls.pressed(f4, "debug_line"), "public: F4 bound by the player is saved as F4: %s" % saved)
	Settings.dev_tools_override = 1
	Settings.apply_bindings()
	Settings.dev_tools_override = 0
	Settings.apply_bindings()
	_check(Settings.keys_for("debug_line")[0] == KEY_F4 and Controls.pressed(f4, "debug_line"), "public: the player's F4 kept after a dev build")
	Settings.bind("debug_line", [])
	Settings.dev_tools_override = was
	Settings.apply_bindings()
	FactorioKeys.test_config = ""


## Factorio 2.1's own "; " lines for the keys Zenith 0.2.2 had beyond Factorio's: no arrow walking, no
## console alternative (/), G (not Keypad Enter) to get in; and one control the player changed there.
func _ini_21() -> Array:
	return ["; version=13", "[controls]", "; move-up=W", "; move-up-alternative=", "; move-down=S", "; move-down-alternative=",
		"; move-left=A", "; move-left-alternative=", "; move-right=D", "; move-right-alternative=", "; toggle-console=GRAVE",
		"; toggle-console-alternative=", "rotate=T"] + DEFAULTS_21


## A press of this key (with modifiers) fires the action.
func _fires(code: int, action: String) -> bool:
	var ev := Controls.key_event(code)
	ev.pressed = true
	return Controls.pressed(ev, action)


## [the arrows walk, / opens the console, Keypad Enter gets in, Tab is Next weapon, C is Shoot selected,
## M alone opens the map]: all true with Zenith 0.2.2's keys.
func _old_presses() -> Array:
	return [_fires(KEY_UP, "move_up") and _fires(KEY_DOWN, "move_down") and _fires(KEY_LEFT, "move_left") and _fires(KEY_RIGHT, "move_right"),
		_fires(KEY_SLASH, "toggle_console"), _fires(KEY_KP_ENTER, "enter_vehicle"), _fires(KEY_TAB, "next_gun"),
		_fires(KEY_C, "shoot_cursor"), _fires(KEY_M, "toggle_map") and not _fires(KEY_TAB, "toggle_map")]


## Issue #26's switch, Settings → Controls → "Zenith 0.2.2's keys": off, Factorio 2.1's config.ini lines are
## followed (the arrows, / and Keypad Enter unbound); on, 0.2.2's built-in keys and only the controls the
## player set in Factorio; saved; switched while running; and "Copy keys from Factorio" in both modes.
func _old_keys() -> void:
	var dir := _dir.path_join("old_keys")
	var ini := dir.path_join("config.ini")
	_write(ini, _ini_21())
	Settings.path = dir.path_join("settings.cfg")
	Settings._loaded = false
	FactorioKeys.test_config = ini
	Controls.old_defaults_override = -1
	Settings.set_value("factorio", "use_factorio_keys", true)
	Controls.define()
	Settings.apply_bindings()
	var keys_of := func() -> Array:
		return [Settings.keys_for("move_up"), Settings.keys_for("toggle_console"), Settings.keys_for("enter_vehicle"),
			Settings.keys_for("next_gun"), Settings.keys_for("toggle_map"), Settings.keys_for("rotate")]
	_check(not Controls.old_defaults() and keys_of.call() == [[KEY_W, 0], [KEY_QUOTELEFT, 0], [KEY_ENTER, KEY_G], [KEY_C, 0], [KEY_TAB, KEY_M], [KEY_T, 0]],
		"off: Factorio 2.1's lines followed, the arrows, / and Keypad Enter unbound: %s" % [keys_of.call()])
	_check(_old_presses() == [false, false, false, false, false, false] and _fires(KEY_G, "enter_vehicle") and _fires(KEY_TAB, "toggle_map"),
		"off: the presses follow Factorio: %s" % [_old_presses()])
	var off_copy: Dictionary = Settings.copy_factorio_keys()
	var off_text: String = load("res://scripts/menu/settings_window.gd").copy_report_text(off_copy)
	_check(not bool(off_copy["old_keys"]) and (off_copy["defaults"] as Array).size() > 10 and off_text.contains("With Factorio's keys")
		and off_text.contains("Factorio's defaults taken for the rest"), "off: Copy keys from Factorio takes its defaults and says so: %s" % off_text)

	# Switched on while running: 0.2.2's keys at once, only the set line (rotate) from Factorio, and saved.
	Settings.set_value("factorio", Controls.OLD_KEYS_SETTING, true)
	_check(Controls.old_defaults() and keys_of.call() == [[KEY_W, KEY_UP], [KEY_QUOTELEFT, KEY_SLASH], [KEY_ENTER, KEY_KP_ENTER], [KEY_TAB, 0], [KEY_M, 0], [KEY_T, 0]]
		and Settings.keys_for("shoot_cursor") == [KEY_C, 0], "on: 0.2.2's keys, Factorio's changed Rotate kept: %s" % [keys_of.call()])
	_check(_old_presses() == [true, true, true, true, true, true] and not _fires(KEY_G, "enter_vehicle"),
		"on: the arrows walk, / opens the console, Keypad Enter gets in, Tab is Next weapon: %s" % [_old_presses()])
	var saved := ConfigFile.new()
	saved.load(Settings.path)
	_check(saved.get_value("factorio", Controls.OLD_KEYS_SETTING, false) == true, "on: saved in settings.cfg")
	var on_copy: Dictionary = Settings.copy_factorio_keys()
	var on_text: String = load("res://scripts/menu/settings_window.gd").copy_report_text(on_copy)
	_check(bool(on_copy["old_keys"]) and (on_copy["defaults"] as Array).is_empty() and (on_copy["copied"] as Array).size() == 1
		and on_text.contains("With Zenith 0.2.2's keys on") and not on_text.contains("Factorio's defaults taken")
		and _old_presses() == [true, true, true, true, true, true] and Settings.keys_for("rotate")[0] == KEY_T,
		"on: Copy keys from Factorio copies only the changed keys, keeps 0.2.2's and says so: %s" % on_text)

	# Read again from the file, as at the next start: still on.
	Settings._loaded = false
	Settings.apply_bindings()
	_check(Controls.old_defaults() and _old_presses() == [true, true, true, true, true, true], "on: still on after the settings are read again")
	# Factorio's keys off: Zenith's built-in keys, 0.2.2's with the switch.
	Settings.set_value("factorio", "use_factorio_keys", false)
	Settings.reload_factorio_keys()
	_check(_old_presses() == [true, true, true, true, true, true] and Settings.keys_for("rotate")[0] == KEY_R, "on, Factorio's keys off: 0.2.2's built-in keys")
	Settings.set_value("factorio", "use_factorio_keys", true)
	# And off again: back to following Factorio.
	Settings.set_value("factorio", Controls.OLD_KEYS_SETTING, false)
	_check(not Controls.old_defaults() and keys_of.call()[0] == [KEY_W, 0] and keys_of.call()[3] == [KEY_C, 0]
		and _old_presses() == [false, false, false, false, false, false], "off again: Factorio's keys: %s" % [keys_of.call()])
	FactorioKeys.test_config = ""
	Settings.set_value("factorio", "use_factorio_keys", false)
	Settings.apply_bindings()


## Run with -- --keys-defaults=old: the switch on for this run although settings.cfg says off, and shown so.
func _old_keys_forced() -> void:
	var dir := _dir.path_join("old_keys_forced")
	var ini := dir.path_join("config.ini")
	_write(ini, _ini_21())
	Settings.path = dir.path_join("settings.cfg")
	Settings._loaded = false
	FactorioKeys.test_config = ini
	Settings.set_value("factorio", "use_factorio_keys", true)
	Controls.define()
	Settings.apply_bindings()
	_check(Controls.old_defaults_override == -1 and not bool(Settings.get_value("factorio", Controls.OLD_KEYS_SETTING)) and Controls.old_defaults(),
		"--keys-defaults=old: on for this run, the saved setting off")
	_check(_old_presses() == [true, true, true, true, true, true] and Settings.keys_for("rotate")[0] == KEY_T,
		"--keys-defaults=old: the arrows walk, / opens the console, Keypad Enter gets in, Tab is Next weapon, Factorio's changed Rotate kept: %s" % [_old_presses()])
	var text: String = load("res://scripts/menu/settings_window.gd").copy_report_text(Settings.copy_factorio_keys())
	_check(text.contains("With Zenith 0.2.2's keys on"), "--keys-defaults=old: Copy keys from Factorio says the mode: %s" % text)
	FactorioKeys.test_config = ""


func _wipe(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)
	for sub in d.get_directories():
		_wipe(path.path_join(sub))
	DirAccess.remove_absolute(path)
