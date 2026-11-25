extends SceneTree
## Verifies that every `"--<name>"` CLI switch literal in `res://scripts/` is
## registered in `Switches.REGISTRY` (excluding passthrough engine flags and `--ui-*`),
## and checks `Switches.is_known`, `Switches.unknown_args`, and `register_addon_switch`.
##
## Run headless:
##   godot --headless --audio-driver Dummy --path client -s res://tests/switches_test.gd

const Switches := preload("res://scripts/switches.gd")
const Wire := preload("res://scripts/util/wire.gd")

var _fails := 0


func _check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		_fails += 1


func _collect_gd_files(dir_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var full := dir_path.path_join(entry)
			if dir.current_is_dir():
				_collect_gd_files(full, out)
			elif entry.ends_with(".gd"):
				out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()


func _is_passthrough(flag: String) -> bool:
	if Switches.PASSTHROUGH_FLAGS.has(flag):
		return true
	for prefix: String in Switches.PASSTHROUGH_PREFIXES:
		if flag.begins_with(prefix):
			return true
	return false


func _initialize() -> void:
	var files: Array[String] = []
	_collect_gd_files("res://scripts", files)
	_check(files.size() > 50, "scanned res://scripts/ (%d .gd files)" % files.size())

	var re := RegEx.new()
	re.compile("\"(--[a-zA-Z0-9_-]+)")
	var missing: Array[String] = []
	var seen_flags: Dictionary = {}
	for path: String in files:
		if path.ends_with("/switches.gd"):
			continue
		var txt := FileAccess.get_file_as_string(path)
		for m: RegExMatch in re.search_all(txt):
			var flag: String = m.get_string(1)
			if seen_flags.has(flag):
				continue
			seen_flags[flag] = true
			if _is_passthrough(flag):
				continue
			if not Switches.REGISTRY.has(flag):
				missing.append("%s (%s)" % [flag, path])

	if not missing.is_empty():
		print("Missing switches in REGISTRY: ", missing)
	_check(missing.is_empty(), "every non-passthrough switch in res://scripts/ is in Switches.REGISTRY (%d checked)" % seen_flags.size())

	# Known & unknown flag checks
	var sample := PackedStringArray([
		"--factorio-port=34200",
		"--clean-shot",
		"--ui-test",
		"--headless",
		"--start-server",
		"--definitely-not-a-real-flag",
		"positional-arg",
	])
	var unknown := Switches.unknown_args(sample)
	_check(unknown.size() == 1 and unknown[0] == "--definitely-not-a-real-flag",
		"unknown_args flags --definitely-not-a-real-flag and accepts known/passthrough/ui flags")
	_check(Switches.is_known("--factorio-port=34200"), "is_known accepts --factorio-port=34200")
	_check(Switches.is_known("--clean-shot"), "is_known accepts --clean-shot")
	_check(Switches.is_known("--ui-test"), "is_known accepts --ui-test")
	_check(not Switches.is_known("--definitely-not-a-real-flag"), "is_known rejects --definitely-not-a-real-flag")

	# Add-on registration
	Switches.register_addon_switch("--test-addon-flag=1")
	_check(Switches.is_known("--test-addon-flag"), "register_addon_switch registers --test-addon-flag")
	_check(Switches.is_known("--test-addon-flag=abc"), "register_addon_switch accepts value form")

	# Switches CLI helpers (has, value, on, cache)
	Switches.set_test_args(PackedStringArray([
		"--clean-shot",
		"--laser-origin=old",
		"--warm-rings=4",
		"--empty-val=",
		"--bare",
		"--off-flag=off",
		"--false-flag=false",
		"--zero-flag=0",
		"--on-flag=on",
		"--true-flag=true",
		"--one-flag=1",
		"--dup=on",
		"--dup=off",
		"--dup2=off",
		"--dup2=on",
	]))
	_check(Switches.args().size() == 15, "Switches.args returns cached test args")
	_check(Switches.has("--clean-shot"), "Switches.has matches bare flag")
	_check(Switches.has("--laser-origin=old"), "Switches.has matches exact flag=val")
	_check(not Switches.has("--laser-origin"), "Switches.has does not match bare prefix when flag=val")
	_check(not Switches.has("--missing-flag"), "Switches.has returns false for absent flag")
	_check(Switches.value("--warm-rings") == "4", "Switches.value extracts --flag=val")
	_check(Switches.value("--empty-val", "fallback") == "", "Switches.value returns empty string when value is empty")
	_check(Switches.value("--missing-val", "fallback") == "fallback", "Switches.value returns default when absent")
	_check(Switches.value("--missing-val") == "", "Switches.value defaults to empty string")
	_check(Switches.on("--absent-on"), "Switches.on defaults to true when absent")
	_check(not Switches.on("--absent-off", false), "Switches.on respects default_val=false when absent")
	_check(Switches.on("--bare", false), "Switches.on treats bare flag as true")
	_check(not Switches.on("--off-flag"), "Switches.on respects =off")
	_check(not Switches.on("--false-flag"), "Switches.on respects =false")
	_check(not Switches.on("--zero-flag"), "Switches.on respects =0")
	_check(Switches.on("--on-flag", false), "Switches.on respects =on")
	_check(Switches.on("--true-flag", false), "Switches.on respects =true")
	_check(Switches.on("--one-flag", false), "Switches.on respects =1")
	_check(not Switches.on("--dup"), "Switches.on last =off overrides earlier =on")
	_check(Switches.on("--dup2", false), "Switches.on last =on overrides earlier =off")
	Switches.set_test_args(PackedStringArray())
	_check(Switches.args().is_empty(), "Switches.set_test_args caches empty PackedStringArray")
	Switches.reset_cache()

	# Wire helpers
	var arr: Array = Wire.array([1, "two", 3])
	_check(arr.size() == 3 and arr[1] == "two", "Wire.array preserves Array")
	_check(Wire.array({}).is_empty(), "Wire.array turns Dictionary into []")
	_check(Wire.array(null).is_empty(), "Wire.array turns null into []")
	_check(Wire.array("abc").is_empty(), "Wire.array turns String into []")
	_check(is_equal_approx(Wire.direction_yaw(0), 0.0), "Wire.direction_yaw(0) == 0")
	_check(is_equal_approx(Wire.direction_yaw(4), -TAU * 0.25), "Wire.direction_yaw(4) is -TAU/4")
	_check(is_equal_approx(-Wire.direction_yaw(4), TAU * 0.25), "-Wire.direction_yaw(4) is +TAU/4")
	_check(is_equal_approx(Wire.direction_yaw(8), -PI), "Wire.direction_yaw(8) is -PI")
	_check(is_equal_approx(Wire.direction_yaw(-4), TAU * 0.25), "Wire.direction_yaw(-4) is +TAU/4")
	_check(is_equal_approx(Wire.orientation_yaw(0.0), 0.0), "Wire.orientation_yaw(0.0) == 0")
	_check(is_equal_approx(Wire.orientation_yaw(0.25), -TAU * 0.25), "Wire.orientation_yaw(0.25) is -TAU/4")
	_check(is_equal_approx(Wire.orientation_yaw(0.5), -PI), "Wire.orientation_yaw(0.5) is -PI")
	_check(is_equal_approx(Wire.tile(0), 0.0), "Wire.tile(0) == 0")
	_check(is_equal_approx(Wire.tile(256), 1.0), "Wire.tile(256) == 1.0")
	_check(is_equal_approx(Wire.tile(-128), -0.5), "Wire.tile(-128) == -0.5")

	print("SWITCHES FAILS: %d" % _fails)
	quit(1 if _fails > 0 else 0)
