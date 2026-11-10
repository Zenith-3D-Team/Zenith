extends RefCounted
## The keys the player set in Factorio's own controls (issue #14), read from Factorio's config.ini
## so Zenith uses them too: settings.gd takes them as the defaults (a binding changed in Zenith's
## Settings → Controls still wins). Off with Settings → Controls → "Use the keys set in Factorio".
##
## config.ini's [controls] section has a line per control Factorio's own default was changed for
## (the rest are written as "; " comments): `toggle-driving=TAB`, and `<control>-alternative=...`
## for its alternative binding. A binding is Factorio's key sequence (CustomInputPrototype's
## key_sequence): modifiers CONTROL, SHIFT, ALT, COMMAND joined to one key by " + ", as in
## "CONTROL + C"; keys by their SDL names (A, 1, RETURN, TAB, KP_ENTER, F5...) or a mouse button,
## which Zenith's key controls can't take, so those are skipped. "" is unbound.
##
## Where config.ini is: the install's config-path.cfg says (`__PATH__system-write-data__`, Steam's
## and the installer's: %APPDATA%\Factorio\config, ~/.factorio/config; otherwise the install's own
## config folder). --factorio-config=<file> points at one (tests).

const Paths := preload("res://scripts/menu/paths.gd")
const Settings := preload("res://scripts/menu/settings.gd")

## Factorio's control -> Zenith's action (controls.gd), for every control Zenith has as a key.
const ACTIONS := {
	"move-up": "move_up", "move-down": "move_down", "move-left": "move_left", "move-right": "move_right",
	"open-character-gui": "open_screen", "open-technology-gui": "open_technology", "toggle-map": "toggle_map",
	"production-statistics": "production_statistics", "kill-statistics": "kill_statistics",
	"logistic-networks": "logistic_networks", "open-factoriopedia": "toggle_factoriopedia",
	"toggle-console": "toggle_console", "shoot-enemy": "shoot_enemies", "shoot-selected": "shoot_cursor",
	"next-weapon": "next_gun", "toggle-driving": "enter_vehicle", "pick-items": "pick_up",
	"rotate": "rotate", "reverse-rotate": "reverse_rotate", "flip-horizontal": "flip_horizontal",
	"flip-vertical": "flip_vertical", "clear-cursor": "clear_cursor", "pipette": "pipette",
	"drop-cursor": "drop_item", "show-info": "alt_mode", "copy": "copy", "cut": "cut", "paste": "paste",
	"undo": "undo", "redo": "redo", "focus-search": "focus_search", "toggle-blueprint-library": "blueprint_library",
	"cycle-quality-up": "cycle_quality_up", "cycle-quality-down": "cycle_quality_down",
	"cycle-blueprint-forwards": "cycle_blueprint_forwards", "cycle-blueprint-backwards": "cycle_blueprint_backwards",
	"rotate-active-quick-bars": "rotate_quickbars", "larger-terrain-building-area": "larger_tile_area",
	"smaller-terrain-building-area": "smaller_tile_area", "toggle-rail-layer": "toggle_rail_layer",
	"increase-ui-scale": "increase_ui_scale", "decrease-ui-scale": "decrease_ui_scale", "reset-ui-scale": "reset_ui_scale",
	# The base mod's custom inputs (base/prototypes/custom-inputs.lua), behind the shortcut bar.
	"give-blueprint": "give_blueprint", "give-deconstruction-planner": "give_deconstruction_planner",
	"give-upgrade-planner": "give_upgrade_planner", "give-red-wire": "give_red_wire",
	"give-green-wire": "give_green_wire", "give-copper-wire": "give_copper_wire",
	"toggle-personal-logistic-requests": "toggle_personal_logistics", "toggle-personal-roboport": "toggle_personal_roboport",
	"toggle-equipment-movement-bonus": "toggle_equipment_movement_bonus",
	"quick-bar-button-1": "quickbar_1", "quick-bar-button-2": "quickbar_2", "quick-bar-button-3": "quickbar_3",
	"quick-bar-button-4": "quickbar_4", "quick-bar-button-5": "quickbar_5", "quick-bar-button-6": "quickbar_6",
	"quick-bar-button-7": "quickbar_7", "quick-bar-button-8": "quickbar_8", "quick-bar-button-9": "quickbar_9",
	"quick-bar-button-10": "quickbar_10",
	"action-bar-select-page-1": "quickbar_page_1", "action-bar-select-page-2": "quickbar_page_2",
	"action-bar-select-page-3": "quickbar_page_3", "action-bar-select-page-4": "quickbar_page_4",
	"action-bar-select-page-5": "quickbar_page_5", "action-bar-select-page-6": "quickbar_page_6",
	"action-bar-select-page-7": "quickbar_page_7", "action-bar-select-page-8": "quickbar_page_8",
	"action-bar-select-page-9": "quickbar_page_9", "action-bar-select-page-10": "quickbar_page_10",
}

## Factorio's (SDL's) key names that aren't Godot's own spelling of the key.
const KEYS := {
	"RETURN": KEY_ENTER, "RETURN2": KEY_ENTER, "ESCAPE": KEY_ESCAPE, "BACKSPACE": KEY_BACKSPACE, "TAB": KEY_TAB,
	"SPACE": KEY_SPACE, "MINUS": KEY_MINUS, "EQUALS": KEY_EQUAL, "LEFTBRACKET": KEY_BRACKETLEFT,
	"RIGHTBRACKET": KEY_BRACKETRIGHT, "BACKSLASH": KEY_BACKSLASH, "NONUSHASH": KEY_BACKSLASH,
	"SEMICOLON": KEY_SEMICOLON, "APOSTROPHE": KEY_APOSTROPHE, "GRAVE": KEY_QUOTELEFT, "COMMA": KEY_COMMA,
	"PERIOD": KEY_PERIOD, "SLASH": KEY_SLASH, "CAPSLOCK": KEY_CAPSLOCK, "PRINTSCREEN": KEY_PRINT,
	"SCROLLLOCK": KEY_SCROLLLOCK, "PAUSE": KEY_PAUSE, "INSERT": KEY_INSERT, "HOME": KEY_HOME,
	"PAGEUP": KEY_PAGEUP, "DELETE": KEY_DELETE, "END": KEY_END, "PAGEDOWN": KEY_PAGEDOWN,
	"RIGHT": KEY_RIGHT, "LEFT": KEY_LEFT, "DOWN": KEY_DOWN, "UP": KEY_UP, "NUMLOCKCLEAR": KEY_NUMLOCK,
	"KP_DIVIDE": KEY_KP_DIVIDE, "KP_MULTIPLY": KEY_KP_MULTIPLY, "KP_MINUS": KEY_KP_SUBTRACT,
	"KP_PLUS": KEY_KP_ADD, "KP_ENTER": KEY_KP_ENTER, "KP_PERIOD": KEY_KP_PERIOD, "KP_DECIMAL": KEY_KP_PERIOD,
	"KP_0": KEY_KP_0, "KP_1": KEY_KP_1, "KP_2": KEY_KP_2, "KP_3": KEY_KP_3, "KP_4": KEY_KP_4,
	"KP_5": KEY_KP_5, "KP_6": KEY_KP_6, "KP_7": KEY_KP_7, "KP_8": KEY_KP_8, "KP_9": KEY_KP_9,
	"APPLICATION": KEY_MENU, "MENU": KEY_MENU, "HELP": KEY_HELP, "CLEAR": KEY_CLEAR,
	"LCTRL": KEY_CTRL, "RCTRL": KEY_CTRL, "LSHIFT": KEY_SHIFT, "RSHIFT": KEY_SHIFT, "LALT": KEY_ALT,
	"RALT": KEY_ALT, "LGUI": KEY_META, "RGUI": KEY_META,
}

const MODIFIER_MASKS := {"CONTROL": KEY_MASK_CTRL, "COMMAND": KEY_MASK_CTRL, "SHIFT": KEY_MASK_SHIFT, "ALT": KEY_MASK_ALT}

## A slot Factorio binds to something no key control can take (a mouse button): left as Zenith's.
const SKIP := -1


## action -> [primary, alternative] key codes (with KEY_MASK_* modifiers; 0 unbound, SKIP left as
## Zenith's default) for each control set in Factorio's config.ini, or {} without one.
static func read() -> Dictionary:
	var file := config_path()
	if file == "":
		return {}
	return keys_from(FileAccess.get_file_as_string(file))


## The same from config.ini's text.
static func keys_from(text: String) -> Dictionary:
	var out := {}
	var set_lines := parse(text)
	for line_name in set_lines:
		var name: String = line_name
		var slot := 0
		if name.ends_with("-alternative"):
			name = name.trim_suffix("-alternative")
			slot = 1
		if not ACTIONS.has(name):
			continue
		var action: String = ACTIONS[name]
		var keys: Array = out.get(action, [SKIP, SKIP])
		keys[slot] = key_code(str(set_lines[line_name]))
		out[action] = keys
	for action in out.keys():
		if out[action] == [SKIP, SKIP]:
			out.erase(action)
	return out


## config.ini's [controls] lines that are set (not "; " comments): name -> value.
static func parse(text: String) -> Dictionary:
	var out := {}
	var in_controls := false
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("["):
			in_controls = line == "[controls]"
			continue
		if not in_controls or line == "" or line.begins_with(";") or line.begins_with("#"):
			continue
		var eq := line.find("=")
		if eq <= 0:
			continue
		out[line.substr(0, eq).strip_edges()] = line.substr(eq + 1).strip_edges()
	return out


## A Factorio key sequence ("CONTROL + C", "TAB", "") as a Godot key code with modifier masks:
## 0 for unbound, SKIP for a mouse button, controller button or a key not known.
static func key_code(seq: String) -> int:
	seq = seq.strip_edges()
	if seq == "":
		return 0
	var code := 0
	var key := KEY_NONE
	for part in seq.split("+"):
		var p := part.strip_edges().to_upper()
		if p == "":
			# "CONTROL + +" can't be written: "+" is KP_PLUS or EQUALS. An empty part is a typo.
			return SKIP
		if MODIFIER_MASKS.has(p):
			code |= int(MODIFIER_MASKS[p])
		elif key != KEY_NONE:
			return SKIP  # one key only
		elif KEYS.has(p):
			key = KEYS[p]
		elif p.length() == 1 and (p >= "A" and p <= "Z" or p >= "0" and p <= "9"):
			key = OS.find_keycode_from_string(p)
		elif p.begins_with("F") and p.substr(1).is_valid_int() and int(p.substr(1)) in range(1, 25):
			key = KEY_F1 + int(p.substr(1)) - 1
		else:
			return SKIP  # mouse-button-1, mouse-wheel-up, controller-a, media keys
	if key == KEY_NONE:
		return SKIP
	return code | key


## Factorio's config.ini for the install Zenith uses, or "" when there is none.
static func config_path() -> String:
	var arg := Settings.arg_value("--factorio-config=")
	if arg != "":
		return arg if FileAccess.file_exists(arg) else ""
	for c in candidates(Paths.factorio_exe()):
		if FileAccess.file_exists(c):
			return c
	return ""


## Where config.ini may be, the install's own choice (config-path.cfg) first.
static func candidates(exe: String) -> Array[String]:
	var system: Array[String] = []
	var appdata := OS.get_environment("APPDATA")
	if appdata != "":
		system.append(appdata.replace("\\", "/").path_join("Factorio/config/config.ini"))
	var home := OS.get_environment("HOME")
	if home != "":
		system.append(home.path_join(".factorio/config/config.ini"))
		system.append(home.path_join("Library/Application Support/factorio/config/config.ini"))
	if exe == "":
		return system
	var root := exe.get_base_dir().path_join("../..").simplify_path()
	if exe.contains(".app/Contents/MacOS"):
		root = exe.get_base_dir().path_join("../../..").simplify_path()
	var own: Array[String] = [root.path_join("config/config.ini")]
	var cfg := root.path_join("config-path.cfg")
	var uses_system := true
	if FileAccess.file_exists(cfg):
		var text := FileAccess.get_file_as_string(cfg)
		uses_system = text.contains("__PATH__system-write-data__") or text.contains("use-system-read-write-data-directories=true")
	return system + own if uses_system else own + system
