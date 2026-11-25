extends SceneTree
## The "opposite key brakes and holds" option (settings.gd vehicle_brake_hold, Settings interface/vehicle_brake_hold):
##   godot --headless --audio-driver Dummy --path client -s res://tests/vehicle_brake_hold_test.gd
## The braking itself is the mod's (tools/mod_tests/test_bridge.py); this checks the client's switch.

const Settings := preload("res://scripts/menu/settings.gd")
const TestEnv := preload("res://tests/test_env.gd")

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _initialize() -> void:
	TestEnv.isolate("vehicle-brake-hold-test")
	_run.call_deferred()


func _run() -> void:
	check(Settings.DEFAULTS["interface"].has("vehicle_brake_hold"), "the setting exists")
	check(Settings.DEFAULTS["interface"]["vehicle_brake_hold"] == false, "off by default (Factorio's behaviour)")
	check(not Settings.vehicle_brake_hold(), "off with no switch and the default setting")
	var was: Variant = Settings.get_value("interface", "vehicle_brake_hold")
	Settings.set_value("interface", "vehicle_brake_hold", true, false)
	check(Settings.vehicle_brake_hold(), "on when the setting is on")
	Settings.set_value("interface", "vehicle_brake_hold", was, false)
	print("vehicle_brake_hold_test: %s" % ("PASS" if fails == 0 else "%d FAILED" % fails))
	quit(1 if fails > 0 else 0)
