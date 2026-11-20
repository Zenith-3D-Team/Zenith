extends SceneTree
## Night vision's feedback (night_vision_overlay.gd, night_vision_icon.gd, step_sounds.gd's `nv`): the edge
## and the icon follow the 0..1 level they are given, the two settings turn them off (the sound's
## prototype data parses; `--night-vision-fx=off`'s one switch covers all three).
##   godot --headless --audio-driver Dummy --path client -s res://tests/night_vision_test.gd

const Overlay := preload("res://scripts/ui/night_vision_overlay.gd")
const Icon := preload("res://scripts/ui/factorio/night_vision_icon.gd")
const StepSounds := preload("res://scripts/fx/step_sounds.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const TestEnv := preload("res://tests/test_env.gd")

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _initialize() -> void:
	TestEnv.isolate("night-vision-test")
	var edge := Overlay.new()
	var icon := Icon.new()
	root.add_child(edge)
	root.add_child(icon)
	await process_frame  # _ready (the settings' listeners, the picture) runs with the tree's first frame
	check(not edge.visible and not icon.visible, "both hidden at level 0")
	check(not Overlay.forced_off, "no --night-vision-fx=off here")
	edge.level = 0.5
	icon.level = 0.5
	check(edge.visible and is_equal_approx(float(edge.material.get_shader_parameter("level")), 0.5), "edge follows the level")
	check(icon.visible and is_equal_approx(icon.modulate.a, 0.5) and icon.texture != null, "icon follows the level and has its picture")
	edge.level = 1.0
	icon.level = 1.0
	check(is_equal_approx(float(edge.material.get_shader_parameter("level")), 1.0) and is_equal_approx(icon.modulate.a, 1.0), "full at 1")
	Settings.set_value("interface", "night_vision_edge", false, false)
	check(not edge.visible, "edge setting off hides it at once")
	check(icon.visible, "the indicator setting is its own")
	Settings.set_value("interface", "night_vision_indicator", false, false)
	check(not icon.visible, "indicator setting off hides it")
	edge.level = 0.7
	icon.level = 0.7
	check(not edge.visible and not icon.visible, "still hidden while the level moves with both off")
	Settings.set_value("interface", "night_vision_edge", true, false)
	Settings.set_value("interface", "night_vision_indicator", true, false)
	check(edge.visible and icon.visible, "both back on")
	edge.level = 0.0
	icon.level = 0.0
	check(not edge.visible and not icon.visible, "hidden again at 0")
	check(Overlay.sound_enabled(), "sound on without the switch")

	var steps := StepSounds.new()
	steps.handle({"part": 1, "parts": 1, "s": [["base/sound/nightvision-on", 50, 1], ["base/sound/nightvision-off", 50, 1]], "nv": [1, 2]})
	check(steps.night_vision == [1, 2], "the list's nv is kept: %s" % [steps.night_vision])
	var on: Variant = steps.night_vision_sound(true)
	check(on == null or on.files[0].ends_with("nightvision-on.ogg"), "the on sound is the equipment's own (or null where Factorio's files aren't)")
	steps.handle({"part": 1, "parts": 1, "s": [["base/sound/nightvision-on", 50, 1]]})
	check(steps.night_vision == [0, 0] and steps.night_vision_sound(true) == null, "a list without nv plays nothing")
	steps.reset()
	check(steps.night_vision_sound(false) == null, "no list: null")
	print("NIGHT VISION FAILS: %d" % fails)
	TestEnv.clean()
	quit(1 if fails > 0 else 0)

