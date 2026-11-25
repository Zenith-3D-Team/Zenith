extends SceneTree
## Headless verification for DebugOverlay profiler:
## - ProcMark lifecycle (_setup_proc_marks, _clear_proc_marks, retry in _process)
## - Script breakdown line sorting, capping at 5, and filtering (< 0.05 ms)
## - Frame script sum EMA lerping and _proc_total_ms tracking
## - Live profiler_text output and BeltItems breakdown integration
## - The spike log (--spike-log): its argument, its line, a slow frame written to user://debug/spikes.log,
##   and the scripts' own peak beside Godot's whole main-thread frame
##   godot --headless --audio-driver Dummy --path client -s res://tests/profiler_overlay_test.gd

const DebugOverlay := preload("res://scripts/debug/debug_overlay.gd")
const TestEnv := preload("res://tests/test_env.gd")
const Probing := preload("res://scripts/debug/probing.gd")

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)
	else:
		print("PASS: ", what)


class FakeBeltItems:
	extends Node
	var prof_detail_calls: Array[bool] = []
	var breakdown_str := "update 1.2 | lanes 0.5"

	func set_prof_detail(on: bool) -> void:
		prof_detail_calls.append(on)

	func prof_breakdown() -> String:
		return breakdown_str


class FakeWorldNode:
	extends Node
	var chunks := {}
	var prof := {}

	func loaded_chunk_count() -> int:
		return 0

	func entity_count() -> int:
		return 0


## An add-on's node whose _process takes `ms` (the add-on host's child, as addon_host.gd start()).
class SlowAddonNode:
	extends Node
	var ms := 0

	func _process(_delta: float) -> void:
		if ms > 0:
			OS.delay_msec(ms)


class FakeMainNode:
	extends Node
	var world: FakeWorldNode
	var belt_items: FakeBeltItems
	var movers = null
	var ground_items = null
	var decoratives = null


func _test_proc_mark_lifecycle() -> void:
	var main := FakeMainNode.new()
	var world := FakeWorldNode.new()
	world.name = "World"
	main.world = world
	main.add_child(world)

	var animator := Node.new()
	animator.name = "Animator"
	world.add_child(animator)

	var bi := FakeBeltItems.new()
	bi.name = "BeltItems"
	main.belt_items = bi
	main.add_child(bi)

	root.add_child(main)

	var overlay: DebugOverlay = DebugOverlay.new()
	root.add_child(overlay)

	# 1. Overlay without main does not create marks
	overlay.profiler = true
	check(overlay._proc_marks.is_empty(), "ProcMarks empty when main is null")
	overlay.profiler = false

	# 2. Enabling profiler with main and world creates _ProcMark instances
	overlay.main = main
	overlay.profiler = true
	check(not overlay._proc_marks.is_empty(), "ProcMarks created when profiler = true")
	check(bi.prof_detail_calls.size() > 0 and bi.prof_detail_calls.back() == true,
		"set_prof_detail(true) called on BeltItems when profiler enabled")

	# Verify mark types and names
	var has_start := false
	var has_end := false
	var has_animator := false
	var has_world := false
	for m: Node in overlay._proc_marks:
		check(m is DebugOverlay._ProcMark, "Mark node is _ProcMark instance (%s)" % m.name)
		var label: String = (m as DebugOverlay._ProcMark).label
		if label == "__start__":
			has_start = true
		elif label == "__end__":
			has_end = true
		elif label == "Animator":
			has_animator = true
		elif label == "World":
			has_world = true
	check(has_start, "Marks include __start__")
	check(has_end, "Marks include __end__")
	check(has_animator, "Marks include Animator")
	check(has_world, "Marks include World")

	# 3. Disabling profiler cleanly frees marks
	var old_marks := overlay._proc_marks.duplicate()
	overlay.profiler = false
	check(overlay._proc_marks.is_empty(), "ProcMarks array emptied when profiler = false")
	check(bi.prof_detail_calls.back() == false, "set_prof_detail(false) called when profiler disabled")
	for m: Node in old_marks:
		check(m.get_parent() == null and m.is_queued_for_deletion(),
			"Old mark removed from parent and queued for deletion immediately (%s)" % m.name)

	# 4. Test retry from _process when main.world is attached later
	var delayed_main := FakeMainNode.new()
	overlay.main = delayed_main
	overlay.profiler = true
	check(overlay._proc_marks.is_empty(), "ProcMarks empty while world is null")
	delayed_main.world = FakeWorldNode.new()
	delayed_main.world.name = "World"
	delayed_main.add_child(delayed_main.world)
	overlay._process(0.016)
	check(not overlay._proc_marks.is_empty(), "ProcMarks populated on _process retry after world attached")

	overlay.profiler = false
	overlay.free()
	animator.free()
	bi.free()
	world.free()
	main.free()
	delayed_main.world.free()
	delayed_main.free()


func _test_top_scripts_and_sum() -> void:
	var overlay: DebugOverlay = DebugOverlay.new()
	root.add_child(overlay)

	# 1. Test _top_scripts_line sorting, capping at 5, and filtering < 0.05
	overlay._proc_ema = {
		"alpha": 0.1,
		"beta": 0.5,
		"tiny": 0.04,
		"huge": 1.2,
		"medium": 0.8,
		"border": 0.05,
		"gamma": 0.3,
	}
	var line: String = overlay._top_scripts_line()
	check(line == "Top scripts (ms): huge 1.2 | medium 0.8 | beta 0.5 | gamma 0.3 | alpha 0.1",
		"_top_scripts_line sorts descending, caps at 5, and filters < 0.05: %s" % line)

	overlay._proc_ema = {"sub_threshold": 0.049}
	check(overlay._top_scripts_line() == "", "_top_scripts_line returns empty when all buckets < 0.05")

	# 2. Test _proc_total_ms sums bucket times across __start__ -> buckets -> __end__
	overlay._proc_has_sample = false
	overlay._proc_total_ms = 0.0
	overlay._proc_mark_hit("__start__")
	overlay._proc_frame = {
		"Main": 2000,
		"World": 3500,
		"BeltItems": 1500,
	}
	overlay._proc_mark_hit("__end__")
	check(overlay._proc_has_sample, "_proc_has_sample set to true after __end__")
	check(is_equal_approx(overlay._proc_total_ms, 7.0),
		"_proc_total_ms sums bucket times directly on first sample: %.2f ms" % overlay._proc_total_ms)
	check(is_equal_approx(float(overlay._proc_ema.get("Main", 0.0)), 2.0), "Main EMA initialized to 2.0 ms")
	check(is_equal_approx(float(overlay._proc_ema.get("World", 0.0)), 3.5), "World EMA initialized to 3.5 ms")

	overlay._proc_frame = {
		"Main": 3000,
		"World": 3500,
		"BeltItems": 3500,
	}
	overlay._proc_mark_hit("__end__")
	var expected_total: float = lerpf(7.0, 10.0, 0.15)
	check(is_equal_approx(overlay._proc_total_ms, expected_total),
		"_proc_total_ms applies lerp EMA (expected %.3f, got %.3f)" % [expected_total, overlay._proc_total_ms])

	overlay.free()


func _test_profiler_text_and_belt_items() -> void:
	var main := FakeMainNode.new()
	var bi := FakeBeltItems.new()
	bi.breakdown_str = "update 1.2 | lanes 0.5"
	main.belt_items = bi
	root.add_child(main)

	var overlay: DebugOverlay = DebugOverlay.new()
	overlay.main = main
	root.add_child(overlay)

	# 1. Before first sample: Scripts %.2f ms (no peak)
	overlay._proc_has_sample = false
	var text_unsampled: String = overlay.profiler_text()
	check(text_unsampled.contains("FPS "), "profiler_text contains FPS")
	check(text_unsampled.contains("GPU "), "profiler_text contains GPU")
	check(text_unsampled.contains("Render CPU "), "profiler_text contains Render CPU")
	check(text_unsampled.contains("Scripts "), "profiler_text contains Scripts")
	check(not text_unsampled.contains("(peak "), "profiler_text does not contain (peak before sample")
	check(text_unsampled.contains("BeltItems (ms): update 1.2 | lanes 0.5"),
		"profiler_text appends BeltItems (ms): breakdown")

	# 2. Once sampled: Scripts %.1f ms (peak %.1f)
	overlay._proc_has_sample = true
	overlay._proc_total_ms = 4.2
	var text_sampled: String = overlay.profiler_text()
	check(text_sampled.contains("Scripts 4.2 ms (peak "),
		"profiler_text contains 'Scripts 4.2 ms (peak ' once sampled: %s" % text_sampled.split("\n")[0])

	# 3. BeltItems breakdown omitted when prof_breakdown() returns empty string
	bi.breakdown_str = ""
	var text_empty_bi: String = overlay.profiler_text()
	check(not text_empty_bi.contains("BeltItems (ms):"),
		"profiler_text omits BeltItems (ms): when prof_breakdown returns empty")

	# 4. _exit_tree cleans up marks and calls set_prof_detail(false)
	overlay.profiler = true
	overlay._exit_tree()
	check(bi.prof_detail_calls.back() == false, "set_prof_detail(false) called on _exit_tree")
	check(overlay._proc_marks.is_empty(), "_proc_marks cleared on _exit_tree")

	overlay.free()
	bi.free()
	main.free()


func _test_spike_log() -> void:
	check(DebugOverlay.spike_arg_ms(PackedStringArray(["--spike-log"])) == 33.0, "--spike-log: 33 ms")
	check(DebugOverlay.spike_arg_ms(PackedStringArray(["--x", "--spike-log=20"])) == 20.0, "--spike-log=20: 20 ms")
	check(DebugOverlay.spike_arg_ms(PackedStringArray(["--spike-logx"])) < 0.0, "no --spike-log: off")

	var line := DebugOverlay.spike_line(48200, 31000, [2100, -1, 15100],
		{"World": 18200, "BeltItems": 5100, "Bridge": 3000, "Movers": 2000, "Hud": 1500, "Tiny": 100},
		{"probe.dh_palette": 1, "chunk.new_chunk": 2, "world.x_optimistic": 9100, "pt.gi_model_load": 400}, -340, 12.3)
	check(line.begins_with("t 12.3s frame 48.2 ms: scripts 31.0, deferred+frees 2.1, draw -, rest 15.1"), "spike line: the split, draw - headless: %s" % line)
	check(line.contains("top World 18.2, BeltItems 5.1, Bridge 3.0, Movers 2.0, Hud 1.5") and not line.contains("Tiny"), "spike line: top 5 scripts")
	check(line.contains("parts x_optimistic 9.1") and not line.contains("gi_model_load"), "spike line: parts over 1 ms")
	check(line.contains("counts dh_palette 1, new_chunk 2, nodes -340"), "spike line: counts and nodes")

	# A frame over the threshold, through the marks, written to the log.
	var main := FakeMainNode.new()
	var world := FakeWorldNode.new()
	world.name = "World"
	main.world = world
	main.add_child(world)
	root.add_child(main)
	var overlay: DebugOverlay = DebugOverlay.new()
	overlay.main = main
	root.add_child(overlay)
	var was_on := Probing.on
	overlay.spike_ms = 2.0
	overlay.spike_log = true
	check(Probing.on and not overlay._proc_marks.is_empty(), "the spike log turns the client's timers and the marks on")
	overlay._proc_mark_hit("__start__")
	overlay._proc_frame = {"World": 1500}
	overlay._proc_mark_hit("__end__")
	overlay._proc_mark_hit("__start__")  # a fast frame: nothing written
	check(overlay.spike_lines == 0, "a frame under the threshold isn't written")
	Probing.count("item_models")
	OS.delay_msec(4)
	overlay._proc_frame = {"World": 3000, "Hud": 500}
	overlay._proc_mark_hit("__end__")
	overlay._proc_mark_hit("__start__")
	check(overlay.spike_lines == 1, "a frame over the threshold is written (%d)" % overlay.spike_lines)
	check(overlay._proc_peak_cur >= 3.5 or overlay._proc_peak_ms >= 3.5, "the scripts' own peak from the marks")
	overlay._proc_has_sample = true
	var pt := overlay.profiler_text()
	check(pt.contains("Main thread peak"), "Godot's figure is labelled as the main thread's frame: %s" % pt.split("\n")[0])
	overlay.spike_log = false
	check(overlay._proc_marks.is_empty() and Probing.on == was_on, "off: marks gone, timers as they were")
	var text := FileAccess.get_file_as_string(DebugOverlay.SPIKE_PATH)
	check(text.contains("# spike log on") and text.contains("top World 3.0, Hud 0.5") and text.contains("item_models 1")
		and text.contains("# spike log off (1 frames)"), "the log file: %s" % text.right(300))
	overlay.free()
	world.free()
	main.free()


## The Addons bucket split by add-on: the spike line's "addons" part, and real marks round add-on nodes.
func _test_addon_split() -> void:
	var line := DebugOverlay.spike_line(300000, 290000, [1000, -1, 9000],
		{"Addons": 1000, "addon terrain-elevation": 270400, "addon immersive-weather": 3100, "addon cinematic-camera": 800,
			"addon immersive-enemies": 50, "World": 3000}, {}, 0, 5.0)
	check(line.contains("top Addons 275.4, World 3.0"), "spike line: Addons stays the whole bucket: %s" % line)
	check(line.contains("addons terrain-elevation 270.4, immersive-weather 3.1, cinematic-camera 0.8")
		and not line.contains("immersive-enemies"), "spike line: the three slowest add-ons: %s" % line)
	check(not DebugOverlay.spike_line(40000, 30000, [0, -1, 0], {"World": 30000}, {}, 0, 1.0).contains("addons"),
		"spike line: no add-ons part without add-ons")
	check(DebugOverlay.addon_id_of("Addon_terrain_elevation") == "terrain-elevation", "an add-on's id from its node's name")

	# Marks round the add-on host's children, measured over real frames.
	var main := FakeMainNode.new()
	var world := FakeWorldNode.new()
	world.name = "World"
	main.world = world
	main.add_child(world)
	var host := Node.new()
	host.name = "Addons"
	main.add_child(host)
	var slow := SlowAddonNode.new()
	slow.name = "Addon_terrain_elevation"
	slow.ms = 30
	host.add_child(slow)
	var quick := SlowAddonNode.new()
	quick.name = "Addon_immersive_weather"
	host.add_child(quick)
	root.add_child(main)
	var overlay: DebugOverlay = DebugOverlay.new()
	overlay.main = main
	root.add_child(overlay)
	var was_on := Probing.on
	overlay.spike_ms = 20.0
	overlay.spike_log = true
	var labels := []
	for m: Node in overlay._proc_marks:
		labels.append(str(m.get("label")))
	check(labels.has("addon terrain-elevation") and labels.has("addon immersive-weather"), "a mark after each add-on: %s" % str(labels))
	var late := SlowAddonNode.new()
	late.name = "Addon_late_one"
	host.add_child(late)
	overlay._mark_new_children()
	var late_marked := false
	for m: Node in overlay._proc_marks:
		late_marked = late_marked or str(m.get("label")) == "addon late-one"
	check(late_marked, "an add-on started later is marked by the rescan")
	for i in 4:
		await process_frame
	check(overlay.spike_lines >= 1, "the slow add-on's frames are written (%d)" % overlay.spike_lines)
	var slow_us := int(overlay._spike_scripts.get("addon terrain-elevation", 0))
	var quick_us := int(overlay._spike_scripts.get("addon immersive-weather", 0))
	check(slow_us >= 28000 and quick_us < 5000, "the slow add-on's own time (%d us; the quick one %d us)" % [slow_us, quick_us])
	overlay.spike_log = false
	check(overlay._proc_marks.is_empty() and Probing.on == was_on, "off: the add-ons' marks gone too")
	var names := []
	for c: Node in host.get_children():
		names.append(str(c.name))
	check(names == ["Addon_terrain_elevation", "Addon_immersive_weather", "Addon_late_one"], "the host's children as they were: %s" % str(names))
	var text := FileAccess.get_file_as_string(DebugOverlay.SPIKE_PATH)
	check(text.contains("addons terrain-elevation 3"), "the log names the add-on: %s" % text.right(300))
	overlay.free()
	main.free()


func _initialize() -> void:
	TestEnv.isolate("profiler-overlay-test")
	_run.call_deferred()


func _run() -> void:
	# Wait one frame so root and its children are inside the SceneTree (matching _clear_proc_marks's detach contract).
	await process_frame
	_test_proc_mark_lifecycle()
	_test_top_scripts_and_sum()
	_test_profiler_text_and_belt_items()
	_test_spike_log()
	await _test_addon_split()

	await process_frame
	print("profiler_overlay_test: %s" % ("PASS" if fails == 0 else "%d FAILED" % fails))
	TestEnv.clean()
	quit(1 if fails > 0 else 0)
