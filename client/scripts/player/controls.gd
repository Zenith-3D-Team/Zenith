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

## [action, its default keys: the first is the primary binding, the second the alternative].
const LIST := [
	["move_up", [KEY_W, KEY_UP]],
	["move_down", [KEY_S, KEY_DOWN]],
	["move_left", [KEY_A, KEY_LEFT]],
	["move_right", [KEY_D, KEY_RIGHT]],
	["open_screen", [KEY_E]],
	["open_technology", [KEY_T]],
	["toggle_map", [KEY_M]],
	["production_statistics", [KEY_P]],
	["kill_statistics", [KEY_K]],
	["logistic_networks", [KEY_L]],
	["toggle_factoriopedia", [KEY_F2]],
	["toggle_console", [KEY_QUOTELEFT, KEY_SLASH]],
	["shoot_enemies", [KEY_SPACE]],
	["shoot_cursor", [KEY_C]],
	["next_gun", [KEY_TAB]],
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
]

const MODIFIERS := [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]

## Actions only dev builds have (Settings.dev_tools()): Settings.apply_bindings takes them away in a
## public one.
const DEV_ONLY := ["debug_menu"]

## Pairs that share a key on purpose, as in Factorio: one press does whichever fits
## (player_input.gd). Q clears the cursor, or pipettes with nothing in it; Alt+R changes the rail
## layer with rails in hand, otherwise it gives a red wire. Settings doesn't call them a clash.
const SHARED := [["clear_cursor", "pipette"], ["give_red_wire", "toggle_rail_layer"]]


## Adds the actions that aren't defined yet, with their default keys. Call once before the scene
## starts (main.gd, before Settings.apply_bindings), or from anything that needs them in a test.
static func define() -> void:
	for entry in LIST:
		var action: String = entry[0]
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for code in entry[1]:
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
