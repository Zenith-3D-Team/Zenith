extends RefCounted
## The keys the player has in Factorio's own controls (issues #14, #26), read from Factorio's config.ini
## so Zenith uses them too: settings.gd takes them as the defaults (a binding changed in Zenith's
## Settings → Controls still wins). Off with Settings → Controls → "Use the keys set in Factorio".
##
## config.ini's [controls] section has a line per control Factorio's own default was changed for,
## `toggle-driving=TAB`, and `<control>-alternative=...` for its alternative binding; every other control
## is written as a "; " comment with Factorio's default, `; toggle-map=TAB`. Both are read: the comments
## are this player's defaults for their Factorio version and keyboard layout (AZERTY's differ), the set
## lines go over them. A binding is Factorio's key sequence (CustomInputPrototype's
## key_sequence): modifiers CONTROL, SHIFT, ALT, COMMAND joined to one key by " + ", as in
## "CONTROL + C"; keys by their SDL names (A, 1, RETURN, TAB, KP_ENTER, F5...) or a mouse button,
## which Zenith's key controls can't take, so those are skipped. "" is unbound. 2.1 (config
## version 13) also writes `<control>-controller=` and `-controller-alternative=` lines: skipped.
##
## Where config.ini is: the install's config-path.cfg says (`config-path=__PATH__system-write-data__/config`,
## Steam's and the installer's: %APPDATA%\Factorio\config, ~/.factorio/config;
## `__PATH__executable__/../../config`, the zip's; or a folder of the player's own). --factorio-config=<file>
## points at one (tests).

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

## Keys as Factorio's Settings → Controls names them (English; core.cfg's [control-keys]) where Godot's
## name differs ("QuoteLeft", "Kp Add"); letters, digits and F-keys are the same in both.
const KEY_LABELS := {
	KEY_ENTER: "Enter", KEY_ESCAPE: "Escape", KEY_BACKSPACE: "Backspace", KEY_TAB: "Tab", KEY_SPACE: "Spacebar",
	KEY_CAPSLOCK: "Caps Lock", KEY_PRINT: "Print Screen", KEY_SCROLLLOCK: "Scroll Lock", KEY_PAUSE: "Pause",
	KEY_INSERT: "Insert", KEY_HOME: "Home", KEY_PAGEUP: "Page Up", KEY_DELETE: "Delete", KEY_END: "End",
	KEY_PAGEDOWN: "Page Down", KEY_RIGHT: "Right", KEY_LEFT: "Left", KEY_DOWN: "Down", KEY_UP: "Up",
	KEY_NUMLOCK: "Num Lock", KEY_KP_DIVIDE: "Numpad /", KEY_KP_MULTIPLY: "Numpad *", KEY_KP_SUBTRACT: "Numpad -",
	KEY_KP_ADD: "Numpad +", KEY_KP_ENTER: "Numpad Enter", KEY_KP_PERIOD: "Numpad .", KEY_KP_0: "Numpad 0",
	KEY_KP_1: "Numpad 1", KEY_KP_2: "Numpad 2", KEY_KP_3: "Numpad 3", KEY_KP_4: "Numpad 4", KEY_KP_5: "Numpad 5",
	KEY_KP_6: "Numpad 6", KEY_KP_7: "Numpad 7", KEY_KP_8: "Numpad 8", KEY_KP_9: "Numpad 9", KEY_MENU: "Menu",
	KEY_QUOTELEFT: "`", KEY_MINUS: "-", KEY_EQUAL: "=", KEY_BRACKETLEFT: "[", KEY_BRACKETRIGHT: "]",
	KEY_BACKSLASH: "\\", KEY_SEMICOLON: ";", KEY_APOSTROPHE: "'", KEY_COMMA: ",", KEY_PERIOD: ".", KEY_SLASH: "/",
	KEY_CTRL: "Control", KEY_SHIFT: "Shift", KEY_ALT: "Alt",
}
## The mouse as Factorio names it ([control-keys]), for the bindings Zenith can't take.
const MOUSE_LABELS := {"mouse-button-1": "Left-click", "mouse-button-2": "Right-click", "mouse-button-3": "Middle-click",
	"mouse-wheel-up": "Mouse wheel up", "mouse-wheel-down": "Mouse wheel down", "mouse-wheel-left": "Mouse wheel left",
	"mouse-wheel-right": "Mouse wheel right"}

## A slot Factorio binds to something no key control can take (a mouse button): left as Zenith's.
const SKIP := -1


## action -> [primary, alternative] key codes (with KEY_MASK_* modifiers; 0 unbound, SKIP left as
## Zenith's default) for each control set in Factorio's config.ini, or {} without one.
static func read() -> Dictionary:
	var file := config_path()
	if file == "":
		return {}
	return keys_from(FileAccess.get_file_as_string(file))


## The same from config.ini's text (`set_only`: as report's).
static func keys_from(text: String, set_only := false) -> Dictionary:
	return report(text, set_only)["keys"]


## What config.ini's [controls] lines give Zenith, for the keys and for Settings → Controls' "Copy keys
## from Factorio" message:
##   keys: action -> [primary, alternative] (as keys_from): Factorio's defaults (the "; " lines), the set
##     lines (the ones changed in Factorio) over them;
##   copied: [[control, action, slot, code]] for the set lines (code 0: cleared in Factorio, so unbound
##     here too);
##   defaults: [[control, action, slot, code]] for the default lines taken (a set line for the same slot
##     leaves its default out);
##   skipped: [[control, value, why]] for set lines Zenith can't follow (default lines it can't are left
##     out without a word: Zenith keeps its own default there).
## `set_only` reads the set lines alone, as Zenith 0.2.2 did (Settings → Controls → "Zenith 0.2.2's keys",
## Controls.old_defaults()): Zenith's own defaults for the rest, so its extra keys (the arrows, /, Keypad
## Enter) aren't unbound by Factorio's empty default lines.
static func report(text: String, set_only := false) -> Dictionary:
	var out := {}
	var copied: Array = []
	var defaults: Array = []
	var skipped: Array = []
	var set_lines := parse(text)
	var default_lines := {} if set_only else parse(text, true)
	for line_name in default_lines:
		if set_lines.has(line_name):
			continue
		var name: String = line_name
		var slot := 0
		if name.ends_with("-alternative"):
			name = name.trim_suffix("-alternative")
			slot = 1
		if not ACTIONS.has(name):
			continue
		var code := key_code(str(default_lines[line_name]))
		if code == SKIP:
			continue
		var action: String = ACTIONS[name]
		var keys: Array = out.get(action, [SKIP, SKIP])
		keys[slot] = code
		out[action] = keys
		defaults.append([line_name, action, slot, code])
	for line_name in set_lines:
		var name: String = line_name
		var value := str(set_lines[line_name])
		var slot := 0
		if name.ends_with("-alternative"):
			name = name.trim_suffix("-alternative")
			slot = 1
		if name.ends_with("-controller"):
			skipped.append([line_name, value, "a game controller binding"])
			continue
		if not ACTIONS.has(name):
			skipped.append([line_name, value, "Zenith has no key for this control yet"])
			continue
		var action: String = ACTIONS[name]
		var code := key_code(value)
		if code == SKIP:
			skipped.append([line_name, value, skip_reason(value)])
			continue
		var keys: Array = out.get(action, [SKIP, SKIP])
		keys[slot] = code
		out[action] = keys
		copied.append([line_name, action, slot, code])
	return {"keys": out, "copied": copied, "defaults": defaults, "skipped": skipped}


## Why a binding Factorio has can't be a Zenith key.
static func skip_reason(value: String) -> String:
	var v := value.to_lower()
	if v.contains("mouse-button"):
		return "a mouse button: Zenith's controls take keys only"
	if v.contains("mouse-wheel"):
		return "the mouse wheel: Zenith's controls take keys only"
	if v.contains("controller-"):
		return "a game controller button"
	return "a key Zenith doesn't know"


## config.ini's [controls] lines that are set (not "; " comments): name -> value. With `defaults`, the
## "; name=value" comments instead: Factorio's own default for each control left alone.
static func parse(text: String, defaults := false) -> Dictionary:
	var out := {}
	var in_controls := false
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("["):
			in_controls = line == "[controls]"
			continue
		if not in_controls or line == "" or line.begins_with("#"):
			continue
		if line.begins_with(";") != defaults:
			continue
		if defaults:
			line = line.substr(1).strip_edges()
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


## A key code (with KEY_MASK_* modifiers) as Factorio shows a binding: "Control + Shift + Page Up".
static func key_label(code: int) -> String:
	if code <= 0:
		return ""
	var parts: Array = []
	for m in [[KEY_MASK_CTRL, "Control"], [KEY_MASK_SHIFT, "Shift"], [KEY_MASK_ALT, "Alt"]]:
		if code & int(m[0]):
			parts.append(m[1])
	var key := code & KEY_CODE_MASK
	parts.append(KEY_LABELS.get(key, OS.get_keycode_string(key)))
	return " + ".join(parts)


## A config.ini value ("CONTROL + mouse-button-1", "GRAVE") as Factorio shows it; a part it can't name
## (a controller button, a key Zenith doesn't know) as written.
static func value_label(value: String) -> String:
	if value.strip_edges() == "":
		return "unbound"
	var code := key_code(value)
	if code > 0:
		return key_label(code)
	var parts: Array = []
	for part in value.split("+"):
		var p := part.strip_edges()
		var up := p.to_upper()
		if MODIFIER_MASKS.has(up):
			parts.append(up.capitalize())
		elif MOUSE_LABELS.has(p.to_lower()):
			parts.append(MOUSE_LABELS[p.to_lower()])
		elif p.to_lower().begins_with("mouse-button-"):
			parts.append("Mouse button " + p.substr(13))
		elif KEYS.has(up):
			parts.append(key_label(int(KEYS[up])))
		else:
			parts.append(p)
	return " + ".join(parts)


## Where Steam's and the installer's Factorio keep config.ini on this OS, as a player would type it.
static func system_config_text(os_name := OS.get_name()) -> String:
	match os_name:
		"Windows":
			return "%APPDATA%\\Factorio\\config"
		"macOS":
			return "~/Library/Application Support/factorio/config"
	return "~/.factorio/config"


## A config.ini in place of the search, as --factorio-config= gives one (tests; "" searches).
static var test_config := ""


## Factorio's config.ini for the install Zenith uses, or "" when there is none. `search_again` looks
## for the install afresh (paths.gd remembers what it found).
static func config_path(search_again := false) -> String:
	var arg := Settings.arg_value("--factorio-config=")
	if test_config != "":
		arg = test_config
	if arg != "":
		return arg if FileAccess.file_exists(arg) else ""
	for c in candidates(Paths.factorio_exe(search_again)):
		if FileAccess.file_exists(c):
			return c
	return ""


## Where config.ini may be: where the install's config-path.cfg says first (its `config-path=`, with
## Factorio's __PATH__system-write-data__ and __PATH__executable__ placeholders), then the system's
## folder and the install's own config folder in the order use-system-read-write-data-directories gives.
static func candidates(exe: String) -> Array[String]:
	var system: Array[String] = []
	var write_dir := system_write_dir()
	if write_dir != "":
		system.append(write_dir.path_join("config/config.ini"))
	var home := OS.get_environment("HOME").replace("\\", "/")
	if home != "":
		for other in [home.path_join(".factorio/config/config.ini"), home.path_join("Library/Application Support/factorio/config/config.ini")]:
			if not system.has(other):
				system.append(other)
	if exe == "":
		return system
	var root := exe.get_base_dir().path_join("../..").simplify_path()
	if exe.contains(".app/Contents/MacOS"):
		root = exe.get_base_dir().path_join("../../..").simplify_path()
	var own: Array[String] = [root.path_join("config/config.ini")]
	var cfg := root.path_join("config-path.cfg")
	if exe.contains(".app/Contents/MacOS"):
		var in_app := exe.get_base_dir().path_join("../config-path.cfg").simplify_path()
		if FileAccess.file_exists(in_app):
			cfg = in_app
	var uses_system := true
	var out: Array[String] = []
	if FileAccess.file_exists(cfg):
		var text := FileAccess.get_file_as_string(cfg)
		var said := config_dir(text, exe.get_base_dir(), write_dir)
		if said != "":
			out.append(said.path_join("config.ini"))
		uses_system = cfg_value(text, "use-system-read-write-data-directories") != "false"
	for c in (system + own if uses_system else own + system):
		if not out.has(c):
			out.append(c)
	return out


## config-path.cfg's `key=value` (the last one; "" when it isn't there; # lines are comments).
static func cfg_value(text: String, key: String) -> String:
	var found := ""
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("#") or line.begins_with(";"):
			continue
		var eq := line.find("=")
		if eq > 0 and line.substr(0, eq).strip_edges() == key:
			found = line.substr(eq + 1).strip_edges()
	return found


## The folder config-path.cfg's `config-path=` names, its placeholders filled in ("" when it
## names none, or one Zenith can't fill).
static func config_dir(cfg_text: String, exe_dir: String, write_dir: String) -> String:
	var said := cfg_value(cfg_text, "config-path").replace("\\", "/")
	if said == "":
		return ""
	if said.contains("__PATH__system-write-data__"):
		if write_dir == "":
			return ""
		said = said.replace("__PATH__system-write-data__", write_dir)
	said = said.replace("__PATH__executable__", exe_dir)
	if said.contains("__PATH__"):
		return ""
	if said.is_relative_path():
		said = exe_dir.path_join(said)
	return said.simplify_path()


## Factorio's system write-data folder (%APPDATA%\Factorio, ~/.factorio, macOS's Application
## Support), "" when the environment doesn't say.
static func system_write_dir() -> String:
	var appdata := OS.get_environment("APPDATA")
	if appdata != "":
		return appdata.replace("\\", "/").path_join("Factorio")
	var home := OS.get_environment("HOME").replace("\\", "/")
	if home == "":
		return ""
	if OS.get_name() == "macOS":
		return home.path_join("Library/Application Support/factorio")
	return home.path_join(".factorio")
