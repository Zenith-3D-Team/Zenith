extends RefCounted
## The native library (client/native/: BeltSimNative, BeltDrawNative, BeltLatticeNative and
## UdpSocketNative), loaded here on the platforms that have it, not by Godot at start-up. Godot loads
## every .gdextension its editor finds, and a .gdextension can't mark a platform's library optional:
## where it has none (Linux, macOS, ARM64) every run printed three ERROR lines, though belt_sim.gd and
## Godot's own UDP socket do the work there. client/native/.gdignore keeps the editor from finding it;
## an exported game has it and the DLL beside its program (tools/release/package.py). A checkout whose
## .godot/extension_list.cfg still names it (until its next import) has it loaded by Godot first.

const CONFIG := "res://native/belt_sim.gdextension"
const PROBE := "BeltSimNative"  # one of its classes: there once it is loaded

static var _tried := false


## Loads the library once if this platform has one; whether its classes are there. Only on the main
## thread (Bridge's _ready and belt_items.gd's State ask first, on it).
static func ensure() -> bool:
	if not _tried and OS.get_thread_caller_id() == OS.get_main_thread_id():
		_tried = true
		if not ClassDB.class_exists(PROBE):
			var config := config_path()
			if config != "" and library_path(config) != "":
				GDExtensionManager.load_extension(config)
			print("Native library: %s" % ("loaded" if ClassDB.class_exists(PROBE)
				else "none for %s, belt_sim.gd instead" % platform()))
	return ClassDB.class_exists(PROBE)


## The library's .gdextension: the project's, or the one beside an exported game's program.
static func config_path() -> String:
	if FileAccess.file_exists(CONFIG):
		return CONFIG
	var beside := OS.get_executable_path().get_base_dir().path_join(CONFIG.get_file())
	return beside if FileAccess.file_exists(beside) else ""


## The library a .gdextension names for this run, picked as Godot picks it (an entry whose tags are
## all features of this run, the most tags winning), when its file is there, else "". An exported
## game's is beside its program, where Godot looks for it too.
static func library_path(config: String) -> String:
	var cfg := ConfigFile.new()
	if cfg.load(config) != OK or not cfg.has_section("libraries"):
		return ""
	var best := ""
	var best_tags := 0
	for key: String in cfg.get_section_keys("libraries"):
		var tags := key.split(".")
		var met := true
		for tag in tags:
			met = met and OS.has_feature(tag.strip_edges())
		if met and tags.size() > best_tags:
			best = str(cfg.get_value("libraries", key))
			best_tags = tags.size()
	if best == "":
		return ""
	if not best.begins_with("res://") and best.is_relative_path():
		best = config.get_base_dir().path_join(best)
	if FileAccess.file_exists(best):
		return best
	var beside := OS.get_executable_path().get_base_dir().path_join(best.get_file())
	return beside if FileAccess.file_exists(beside) else ""


## As Godot names a platform in its GDExtension errors: linux.x86_64, windows.arm64...
static func platform() -> String:
	return OS.get_name().to_lower() + "." + Engine.get_architecture_name()
