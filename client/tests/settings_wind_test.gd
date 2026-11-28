extends SceneTree
## settings.gd's one-time Wind volume migration (rel-031-fix2, S5): 0.3.0's Ambient slider covered the
## wind; a 0.3.0 file with Ambient turned down (or muted) and no Wind gets that for Wind once, not full
## volume. A file that has Wind keeps its own; a fresh file gets the default; a Wind changed after the
## migration stays.
##   godot --headless --audio-driver Dummy --path client -s res://tests/settings_wind_test.gd
## Prints "SETTINGS WIND FAILS: 0" when all pass; quits with 1 otherwise.

const Settings := preload("res://scripts/menu/settings.gd")

var _fails := 0


func _check(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("FAIL: ", what)


func _file(name: String) -> String:
	return ProjectSettings.globalize_path("user://settings-wind-test-%s.cfg" % name)


func _initialize() -> void:
	# A 0.3.0 file: Ambient at 0.3 and muted, no Wind (0.3.0 had none), every earlier migration done.
	var old := ConfigFile.new()
	for key in ["migrated", "ssao_off", "belt_auto", "mod_anim_off", "full_screen_resolution", "grass_preset",
			"dual_distance_migrated"]:
		old.set_value("meta", key, true)
	old.set_value("sound", "ambient", 0.3)
	old.set_value("sound", "ambient_on", false)
	var p030 := _file("030")
	old.save(p030)
	Settings.use_file(p030)
	var wind := float(Settings.get_value("sound", "wind"))
	var wind_on: Variant = Settings.get_value("sound", "wind_on")
	_check(is_equal_approx(wind, 0.3) and wind_on == false,
		"a 0.3.0 file's Ambient volume and mute carry over to Wind (%s, %s)" % [wind, wind_on])
	var saved := ConfigFile.new()
	saved.load(p030)
	_check(saved.get_value("meta", "wind_volume", false) == true and is_equal_approx(float(saved.get_value("sound", "wind", -1.0)), 0.3),
		"the migration is saved with its [meta] flag")
	# Once: Wind set to full afterwards stays full on the next start, Ambient still at 0.3.
	Settings.set_value("sound", "wind", 1.0)
	Settings.use_file(p030)
	_check(is_equal_approx(float(Settings.get_value("sound", "wind")), 1.0)
		and is_equal_approx(float(Settings.get_value("sound", "ambient")), 0.3),
		"once only: a Wind chosen after the migration is kept")
	# A file that already has its own Wind keeps it.
	var own := ConfigFile.new()
	own.set_value("meta", "migrated", true)
	own.set_value("sound", "ambient", 0.2)
	own.set_value("sound", "wind", 0.7)
	var p_own := _file("own")
	own.save(p_own)
	Settings.use_file(p_own)
	_check(is_equal_approx(float(Settings.get_value("sound", "wind")), 0.7), "a file with its own Wind keeps it")
	# A fresh file: Wind's default.
	var p_new := _file("new")
	DirAccess.remove_absolute(p_new)
	Settings.use_file(p_new)
	_check(is_equal_approx(float(Settings.get_value("sound", "wind")), float(Settings.DEFAULTS["sound"]["wind"])),
		"a fresh file has Wind's default")
	for p in [p030, p_own, p_new]:
		DirAccess.remove_absolute(p)
	print("SETTINGS WIND FAILS: ", _fails)
	quit(1 if _fails > 0 else 0)
