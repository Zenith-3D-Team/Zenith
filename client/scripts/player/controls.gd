extends RefCounted
## Every keyboard control, as Godot InputMap actions with Factorio's default keys, so Settings →
## Controls can rebind each one (settings.gd keeps the bindings). Settings → Controls names and
## groups them as Factorio does (controls_info.gd); the client's own camera controls come last.
##
## A key may carry modifiers (KEY_R | KEY_MASK_SHIFT is Shift+R). Controls are matched with
## exactly their modifiers (`pressed`), so R and Shift+R, or C and Ctrl+C, are different controls,
## as in Factorio. Mouse buttons aren't actions: building, mining, copying settings and the slot
## clicks are fixed (Settings lists them).
##
## Factorio's Z (drop item), X (swap quickbars) and V (flip) took the client's old camera keys:
## the camera now turns with , and . and Factorio's view moved to F6.
##
## Quality and book cycling are on the mouse wheel by default (Ctrl+wheel and Shift+wheel,
## player_input.gd); their actions here start without keys, so a key can be bound to them.

const Switches := preload("res://scripts/switches.gd")

## [action, its default keys: the first is the primary binding, the second the alternative].
const LIST := [
	["move_up", [KEY_W, KEY_UP]],
	["move_down", [KEY_S, KEY_DOWN]],
	["move_left", [KEY_A, KEY_LEFT]],
	["move_right", [KEY_D, KEY_RIGHT]],
	["open_screen", [KEY_E]],
	["open_technology", [KEY_T]],
	["toggle_map", [KEY_TAB, KEY_M]],
	["production_statistics", [KEY_P]],
	["kill_statistics", [KEY_K]],
	["logistic_networks", [KEY_L]],
	["toggle_factoriopedia", [KEY_F2]],
	["toggle_console", [KEY_QUOTELEFT, KEY_SLASH]],
	["shoot_enemies", [KEY_SPACE]],
	["shoot_cursor", [KEY_SPACE | KEY_MASK_SHIFT]],
	["next_gun", [KEY_C]],
	["enter_vehicle", [KEY_ENTER, KEY_KP_ENTER]],
	["pick_up", [KEY_F]],
	["rotate", [KEY_R]],
	["reverse_rotate", [KEY_R | KEY_MASK_SHIFT]],
	["flip_horizontal", [KEY_H]],
	["flip_vertical", [KEY_V]],
	["clear_cursor", [KEY_Q]],
	["pipette", [KEY_Q]],
	["drop_item", [KEY_Z]],
	["alt_mode", [KEY_ALT]],
	["copy", [KEY_C | KEY_MASK_CTRL]],
	["cut", [KEY_X | KEY_MASK_CTRL]],
	["paste", [KEY_V | KEY_MASK_CTRL]],
	["undo", [KEY_Z | KEY_MASK_CTRL]],
	["redo", [KEY_Y | KEY_MASK_CTRL]],
	["focus_search", [KEY_F | KEY_MASK_CTRL]],
	["give_blueprint", [KEY_B | KEY_MASK_ALT]],
	["blueprint_library", [KEY_B]],
	["cycle_quality_up", []],
	["cycle_quality_down", []],
	["cycle_blueprint_forwards", []],
	["cycle_blueprint_backwards", []],
	["give_deconstruction_planner", [KEY_D | KEY_MASK_ALT]],
	["give_upgrade_planner", [KEY_U | KEY_MASK_ALT]],
	["give_red_wire", [KEY_R | KEY_MASK_ALT]],
	["give_green_wire", [KEY_G | KEY_MASK_ALT]],
	["give_copper_wire", [KEY_C | KEY_MASK_ALT]],
	["toggle_personal_logistics", [KEY_L | KEY_MASK_ALT]],
	["toggle_personal_roboport", [KEY_F | KEY_MASK_ALT]],
	["toggle_equipment_movement_bonus", [KEY_E | KEY_MASK_ALT]],
	["toggle_players", []],
	["quickbar_1", [KEY_1]],
	["quickbar_2", [KEY_2]],
	["quickbar_3", [KEY_3]],
	["quickbar_4", [KEY_4]],
	["quickbar_5", [KEY_5]],
	["quickbar_6", [KEY_6]],
	["quickbar_7", [KEY_7]],
	["quickbar_8", [KEY_8]],
	["quickbar_9", [KEY_9]],
	["quickbar_10", [KEY_0]],
	["quickbar_page_1", [KEY_1 | KEY_MASK_SHIFT]],
	["quickbar_page_2", [KEY_2 | KEY_MASK_SHIFT]],
	["quickbar_page_3", [KEY_3 | KEY_MASK_SHIFT]],
	["quickbar_page_4", [KEY_4 | KEY_MASK_SHIFT]],
	["quickbar_page_5", [KEY_5 | KEY_MASK_SHIFT]],
	["quickbar_page_6", [KEY_6 | KEY_MASK_SHIFT]],
	["quickbar_page_7", [KEY_7 | KEY_MASK_SHIFT]],
	["quickbar_page_8", [KEY_8 | KEY_MASK_SHIFT]],
	["quickbar_page_9", [KEY_9 | KEY_MASK_SHIFT]],
	["quickbar_page_10", [KEY_0 | KEY_MASK_SHIFT]],
	["rotate_quickbars", [KEY_X]],
	["larger_tile_area", [KEY_KP_ADD]],
	["smaller_tile_area", [KEY_KP_SUBTRACT]],
	["toggle_rail_layer", [KEY_R | KEY_MASK_ALT]],
	["increase_ui_scale", [KEY_EQUAL | KEY_MASK_CTRL]],
	["decrease_ui_scale", [KEY_MINUS | KEY_MASK_CTRL]],
	["reset_ui_scale", [KEY_0 | KEY_MASK_CTRL]],
	["toggle_help", [KEY_F1]],
	["debug_line", [KEY_F4]],
	["camera_left", [KEY_COMMA]],
	["camera_right", [KEY_PERIOD]],
	["camera_tilt_up", [KEY_PAGEUP]],
	["camera_tilt_down", [KEY_PAGEDOWN]],
	["factorio_view", [KEY_F6]],
	["first_person", [KEY_F5]],
	["toggle_projection", [KEY_F7]],
	["show_factorio", [KEY_F9 | KEY_MASK_CTRL]],
	["debug_menu", [KEY_F12 | KEY_MASK_CTRL]],
	["addons_reload", [KEY_F5 | KEY_MASK_CTRL | KEY_MASK_SHIFT]],
]

## Factorio 1.1's defaults where 2.0 changed them (Wube's data/changelog.txt, 2.0.7: "Default control key
## for Map changed from M to Tab or M", "Next weapon changed from Tab to C", "Shoot selected changed from
## C to Shift+Space"), as Zenith 0.2.2 had them. LIST has 2.0's; Settings → Controls → "Zenith 0.2.2's keys"
## (or --keys-defaults=old for one run) puts these back (issue #26).
const OLD_DEFAULTS := {"toggle_map": [KEY_M], "next_gun": [KEY_TAB], "shoot_cursor": [KEY_C]}
## The saved setting behind old_defaults() (Settings' factorio section).
const OLD_KEYS_SETTING := "keys_0_2_2"
## Tests force old_defaults() one way (1) or the other (0); -1 reads the command line, then the setting.
static var old_defaults_override := -1


## Zenith 0.2.2's keys (issue #26's switch): OLD_DEFAULTS as the built-in defaults, and of Factorio's
## config.ini only the controls the player set (factorio_keys.gd's report(text, true)), so the arrows walk,
## / opens the console and Keypad Enter gets in as before. On with --keys-defaults=old (that run only)
## or the saved setting.
static func old_defaults() -> bool:
	if old_defaults_override != -1:
		return old_defaults_override == 1
	if old_defaults_forced():
		return true
	# settings.gd preloads this script, so it is loaded here when used.
	return bool(load("res://scripts/menu/settings.gd").get_value("factorio", OLD_KEYS_SETTING))


## --keys-defaults=old: the switch on for this run, whatever is saved.
static func old_defaults_forced() -> bool:
	return Switches.has("--keys-defaults=old")


## An action's default keys (LIST's, or OLD_DEFAULTS' with old_defaults()).
static func defaults_of(entry: Array) -> Array:
	var action: String = entry[0]
	if old_defaults() and OLD_DEFAULTS.has(action):
		return OLD_DEFAULTS[action]
	return entry[1]

const MODIFIERS := [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]

## Actions only dev builds have (Settings.dev_tools()): Settings.apply_bindings takes them away in a
## public one.
const DEV_ONLY := ["debug_menu"]

## Actions with their default key only in dev builds (Settings.dev_tools()): a public build lists them in
## Settings → Controls unbound, for the player to bind (nothing locked out). Issue #26: the debug line's F4 is
## a key many players gave a Factorio control (Factoriopedia), so both acted. A binding saved keeps its key.
const DEV_KEYS := ["debug_line"]


## An action's default keys in LIST as [primary, alternative] codes (0: none).
static func default_pair(action: String) -> Array:
	for entry in LIST:
		if entry[0] == action:
			var keys: Array = defaults_of(entry).duplicate()
			while keys.size() < 2:
				keys.append(0)
			return keys
	return [0, 0]

## Actions only an add-on author has: reloading the add-ons given with --addons (addon_host.gd), while
## one is given (and --addon-reload=off isn't). Settings.apply_bindings takes them away otherwise.
const ADDON_AUTHOR_ONLY := ["addons_reload"]
## Tests force addon_author() one way (1) or the other (0); -1 reads the command line.
static var addon_author_override := -1


static func addon_author() -> bool:
	if addon_author_override != -1:
		return addon_author_override == 1
	var args := Switches.args()
	if args.has("--addon-reload=off"):
		return false
	for arg in args:
		if arg.begins_with("--addons="):
			return true
	return false

## Pairs that share a key on purpose, as in Factorio: one press does whichever fits
## (player_input.gd). Q clears the cursor, or pipettes with nothing in it; the rail layer's key
## changes the layer with rails in hand, otherwise it does the other's: Factorio 2.1 binds G to both
## the rail layer and getting in a vehicle (its alternative), and Zenith's old Alt+R gave a red wire.
## Settings doesn't call them a clash.
const SHARED := [["clear_cursor", "pipette"], ["give_red_wire", "toggle_rail_layer"], ["enter_vehicle", "toggle_rail_layer"]]


## Adds the actions that aren't defined yet, with their default keys. Call once before the scene
## starts (main.gd, before Settings.apply_bindings), or from anything that needs them in a test.
static func define() -> void:
	for entry in LIST:
		var action: String = entry[0]
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for code in defaults_of(entry):
			InputMap.action_add_event(action, key_event(int(code)))


## An InputEventKey for a keycode with modifier masks (OS.get_keycode_string / find_keycode_from_string).
static func key_event(code: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code & KEY_CODE_MASK
	ev.shift_pressed = code & KEY_MASK_SHIFT != 0
	ev.ctrl_pressed = code & KEY_MASK_CTRL != 0
	ev.alt_pressed = code & KEY_MASK_ALT != 0
	ev.meta_pressed = code & KEY_MASK_META != 0
	return ev


## The two actions share a key by design (SHARED).
static func shared(a: String, b: String) -> bool:
	return SHARED.has([a, b]) or SHARED.has([b, a])


static func is_modifier(code: int) -> bool:
	return MODIFIERS.has(code & KEY_CODE_MASK)


## The event presses the action with exactly its modifiers. A modifier on its own (Alt-mode's Alt)
## arrives with its own flag set, so it matches loosely.
static func pressed(event: InputEvent, action: String) -> bool:
	if not InputMap.has_action(action):
		return false
	if event.is_action_pressed(action, false, true):
		return true
	var key := event as InputEventKey
	return key != null and is_modifier(key.physical_keycode) and event.is_action_pressed(action)


## The keys bound to an action, as text ("Shift+R / Q").
static func keys_text(action: String) -> String:
	var names: Array = []
	if InputMap.has_action(action):
		for ev in InputMap.action_get_events(action):
			if ev is InputEventKey:
				names.append(OS.get_keycode_string((ev as InputEventKey).get_physical_keycode_with_modifiers()))
	return " / ".join(names)
