extends CanvasLayer
## The debug menu's overlays (debug_menu.gd), each switched on there: a graph of the last frames'
## times with lines at 16.7 and 33.3 ms (60 and 30 fps), and counters of what is drawn and kept,
## twice a second: FPS, the renderer's draw calls, triangles and objects, nodes, chunks, entities,
## movers, items on belts and on the ground, and the 3D grass (decoratives.gd grass_stats(), what
## --grass-stats prints). Both read only what the engine and the layers count anyway.
## The spike log (--spike-log[=ms], or the debug menu's "Spike log"; off by default): every frame
## over the threshold (33 ms unless given) as one line in user://debug/spikes.log on this PC (nothing
## is sent anywhere): the frame split into scripts, deferred calls and freed nodes, the renderer's
## draw and the rest (presenting, input, physics), the 5 slowest scripts by the profiler's marks, and
## what happened in it (chunks built and filled from the disk cache, Distant Horizon palette
## refreshes, item models read, the slowest message, far merges, nodes made or freed, world.gd's
## slowest parts). It turns on the client's own timers while it runs (Probing.on, as --stutter-probe).
## The Addons bucket (the add-on host's node and every add-on's node under it) is split by add-on: a
## slow frame's line also says "addons <id> <ms>, ..." (the three slowest), each add-on's own node and
## what it runs under it in _process (its frame's work, the API calls it makes from there). Marks only
## exist while the spike log or the profiler is on.
## Each slow line also says what the renderer did (`render ...`): its draw calls (view and shadow passes) and
## the viewport's measured CPU and GPU times, and with Godot started with --gpu-profile (an engine option,
## before `--`) its stages' CPU/GPU ms (shadows, depth pre-pass, opaque, motion vectors, transparent, post,
## rest; the last frame the GPU finished, a frame or two behind). With "Render on a separate thread" (thread
## model 2) the draw runs on the render thread: the line has no draw bucket, and "wait for renderer" is the main
## thread waiting (RenderingServer.sync) for the render thread's last frame before it queues the next.
## `--spike-render=off`: neither, the line as before.

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const Probing := preload("res://scripts/debug/probing.gd")
const RenderStats := preload("res://scripts/debug/render_stats.gd")
const ChunkView := preload("res://scripts/world/chunk_view.gd")
const PerfLog := preload("res://scripts/world/perf_log.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")
const BeltItems := preload("res://scripts/world/belt_items.gd")
const Switches := preload("res://scripts/switches.gd")

const FRAMES := 300
const SCALE_MS := 50.0  # the graph's top
const COUNT_EVERY := 0.5
const SPIKE_PATH := "user://debug/spikes.log"
const SPIKE_DEFAULT_MS := 33.0
const SPIKE_MAX_BYTES := 8 * 1024 * 1024  # the log stops (one last line says so) past this
## `--spike-render=off`: no render stages or draw calls on a spike line, the draw bucket as before.
static var spike_render := Switches.on("--spike-render")
const MARK_RESCAN := 5.0  # seconds between looks for new children of main and the game to mark
## A mark's label for one add-on's own time ("addon " + its id); the spike line sums them back into Addons.
const ADDON_MARK := "addon "
## The add-on host's node (main.gd's child) and the prefix of its add-ons' nodes (addon_host.gd start()).
const ADDON_HOST_NAME := "Addons"
const ADDON_NODE_PREFIX := "Addon_"


class _ProcMark:
	extends Node
	var label := ""
	var target: Node = null

	func _process(_delta: float) -> void:
		if target != null and is_instance_valid(target):
			target._proc_mark_hit(label)


var main = null:
	set(v):
		main = v
		if profiler and _proc_marks.is_empty():
			_setup_proc_marks()
var graph := false:
	set(v):
		graph = v
		_update()
var counters := false:
	set(v):
		counters = v
		_update()
var profiler := false:
	set(v):
		if v == profiler:
			return
		profiler = v
		if profiler:
			_seed_net()
			_setup_proc_marks()
			_sync_belt_prof(true)
		else:
			if not spike_log:
				_clear_proc_marks()
			_sync_belt_prof(false)
		_sync_measure()
		_update()
## The spike log on or off (see the top); `spike_ms` its threshold.
var spike_log := false:
	set(v):
		if v == spike_log:
			return
		spike_log = v
		if spike_log:
			_spike_open()
			_setup_proc_marks()
		else:
			_spike_close()
			if not profiler:
				_clear_proc_marks()
		_sync_measure()
		_update()
var spike_ms := SPIKE_DEFAULT_MS
## Lines written since the log was switched on (tests).
var spike_lines := 0

var _times := PackedFloat32Array()
var _at := 0
var _last_usec := 0
var _plot := Control.new()
var _text := Label.new()
var _prof_panel := PanelContainer.new()
var _prof_text := Label.new()
var _count_left := 0.0
var _measured_here := false
var _prev_packets := 0
var _prev_bytes := 0
var _prev_net_msec := 0
var _pkt_rate := 0.0
var _kbps := 0.0

var _proc_marks: Array[Node] = []
var _proc_last_usec := 0
var _proc_frame: Dictionary = {}
var _proc_ema: Dictionary = {}
var _proc_total_ms := 0.0
var _proc_has_sample := false
## The scripts' own slowest frame (the marks' sum) in the last whole second, and in this one so far.
var _proc_peak_ms := 0.0
var _proc_peak_cur := 0.0
var _proc_peak_at := 0
var _marked := {}  # instance id -> true: nodes with a mark after them
var _rescan_left := MARK_RESCAN

var _spike_file: FileAccess = null
var _spike_started := 0
var _spike_prev_start := 0  # the last frame's __start__
var _spike_end := 0  # when its scripts ended (__end__)
var _spike_deferred := 0  # when its deferred calls ended
var _spike_pre := 0  # the renderer's frame_pre_draw and frame_post_draw after it
var _spike_post := 0
var _spike_scripts := {}  # its marks: label -> usec
var _spike_nodes := 0
var _spike_before := {}  # the counters at the last frame's start
var _probing_was_on := false


func _ready() -> void:
	layer = 115
	_times.resize(FRAMES)
	_plot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_plot.position = Kit.pxv(12, 260)
	_plot.size = Kit.pxv(360, 120)
	_plot.draw.connect(_draw_graph)
	add_child(_plot)
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text.position = Kit.pxv(12, 390)
	_text.add_theme_font_override("font", Kit.font("semibold"))
	_text.add_theme_font_size_override("font_size", Kit.px(14))
	_text.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_text.add_theme_constant_override("outline_size", Kit.px(4))
	add_child(_text)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.06, 0.07, 0.72)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.25, 0.25, 0.28, 0.85)
	sb.content_margin_left = Kit.px(8)
	sb.content_margin_right = Kit.px(8)
	sb.content_margin_top = Kit.px(6)
	sb.content_margin_bottom = Kit.px(6)
	_prof_panel.add_theme_stylebox_override("panel", sb)
	_prof_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_prof_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_prof_panel.offset_left = -Kit.px(12)
	_prof_panel.offset_right = -Kit.px(12)
	_prof_panel.offset_top = Kit.px(12)
	_prof_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prof_panel.visible = false
	_prof_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prof_text.add_theme_font_override("font", Kit.font("semibold"))
	_prof_text.add_theme_font_size_override("font_size", Kit.px(13))
	_prof_text.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_prof_text.add_theme_constant_override("outline_size", Kit.px(4))
	_prof_panel.add_child(_prof_text)
	add_child(_prof_panel)
	if profiler:
		_seed_net()
		_setup_proc_marks()
		_sync_belt_prof(true)
		_sync_measure()
	_update()


func _exit_tree() -> void:
	if spike_log:
		_spike_close()
	_clear_proc_marks(false)
	_sync_belt_prof(false)
	_disable_measure()


func _sync_measure() -> void:
	if not is_inside_tree():
		return
	if profiler or (spike_log and spike_render):
		var thread_model := int(ProjectSettings.get_setting("rendering/driver/threads/thread_model", 1))
		# Measured with the render thread too now its times are read on that thread (render_stats.gd).
		var can := thread_model != 2 or not RenderStats.old
		if not _measured_here and can and get_viewport() != null:
			RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
			_measured_here = true
	else:
		_disable_measure()


func _disable_measure() -> void:
	if not _measured_here:
		return
	_measured_here = false
	if not is_inside_tree() or get_viewport() == null:
		return
	var tree := get_tree()
	var bench_active := tree != null and tree.root != null and tree.root.find_child("Benchmark", true, false) != null
	if not bench_active:
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), false)


func _bridge_node() -> Node:
	if is_inside_tree():
		var tree := get_tree()
		if tree != null and tree.root != null:
			return tree.root.get_node_or_null(^"Bridge")
	var loop := Engine.get_main_loop() as SceneTree
	if loop != null and loop.root != null:
		return loop.root.get_node_or_null(^"Bridge")
	return null


func _seed_net() -> void:
	var br := _bridge_node()
	if br != null:
		var stats: Dictionary = br.get("stats") if br.get("stats") != null else {}
		_prev_packets = int(stats.get("packets", 0))
		_prev_bytes = int(stats.get("bytes", 0))
	else:
		_prev_packets = 0
		_prev_bytes = 0
	_prev_net_msec = Time.get_ticks_msec()


func _sample_net() -> void:
	var now_ms := Time.get_ticks_msec()
	var dt_ms := now_ms - _prev_net_msec
	var pkts := 0
	var bytes := 0
	var br := _bridge_node()
	if br != null:
		var stats: Dictionary = br.get("stats") if br.get("stats") != null else {}
		pkts = int(stats.get("packets", 0))
		bytes = int(stats.get("bytes", 0))
	if dt_ms > 0:
		var secs := dt_ms / 1000.0
		_pkt_rate = maxf(0.0, float(pkts - _prev_packets)) / secs
		_kbps = maxf(0.0, float(bytes - _prev_bytes)) / (1024.0 * secs)
	_prev_packets = pkts
	_prev_bytes = bytes
	_prev_net_msec = now_ms


func _sync_belt_prof(on: bool) -> void:
	if main != null and is_instance_valid(main):
		var bi: Variant = main.get("belt_items")
		if bi is Object and is_instance_valid(bi as Object) and (bi as Object).has_method("set_prof_detail"):
			(bi as Object).call("set_prof_detail", on)


func _create_mark(label: String, prio: int = 0) -> _ProcMark:
	var m := _ProcMark.new()
	m.name = "ProcMark_" + label.replace(" ", "_").replace("(", "").replace(")", "").replace("/", "_").replace(":", "_").replace(".", "_")
	m.label = label
	m.target = self
	m.process_priority = prio
	return m


func _setup_proc_marks() -> void:
	if not profiler and not spike_log:
		return
	if not _proc_marks.is_empty():
		return
	if main == null or not is_instance_valid(main) or main.world == null or not is_instance_valid(main.world):
		return

	# 1. self (prio -2000, "__start__")
	var m_start := _create_mark("__start__", -2000)
	add_child(m_start)
	_proc_marks.append(m_start)

	# 2. Bridge in tree.root ("Autoloads" before Bridge and "Bridge" after Bridge at Bridge.process_priority)
	var tree: SceneTree = get_tree() if is_inside_tree() else (Engine.get_main_loop() as SceneTree)
	var root: Node = tree.root if tree != null else null
	if root != null:
		var bridge_node: Node = root.get_node_or_null(^"Bridge")
		if bridge_node != null and bridge_node.get_parent() != null:
			var b_parent: Node = bridge_node.get_parent()
			var b_idx: int = bridge_node.get_index()
			var b_prio: int = int(bridge_node.process_priority)
			var m_auto := _create_mark("Autoloads", b_prio)
			b_parent.add_child(m_auto)
			b_parent.move_child(m_auto, b_idx)
			_proc_marks.append(m_auto)

			var m_bridge := _create_mark("Bridge", b_prio)
			b_parent.add_child(m_bridge)
			b_parent.move_child(m_bridge, bridge_node.get_index() + 1)
			_proc_marks.append(m_bridge)

	# 3. "Main" before main.get_child(0)
	if main.get_child_count() > 0:
		var m_main := _create_mark("Main", 0)
		main.add_child(m_main)
		main.move_child(m_main, 0)
		_proc_marks.append(m_main)

	# 4. each child of main and game = main.world.get_parent()
	var game: Node = main.world.get_parent() if main.world != null else null
	var parents: Array[Node] = []
	if main != null and is_instance_valid(main):
		parents.append(main)
	if game != null and is_instance_valid(game) and game != main:
		parents.append(game)
	for parent: Node in parents:
		var p: Node = parent
		var children: Array[Node] = p.get_children()
		for child: Node in children:
			if child is _ProcMark or str(child.name).begins_with("StutterMark") or str(child.name).begins_with("ProcMark_"):
				continue
			_marked[child.get_instance_id()] = true
			# The mark after the world counts its children after Animator (FarChunks, BehindCull,
			# the chunks' nodes...): its own bucket, so "World" is world.gd's _process alone (the
			# owner's spike log had World 27 ms with its timed parts 5).
			var label := "World children" if child == main.world else str(child.name)
			var mark := _create_mark(label, 0)
			p.add_child(mark)
			p.move_child(mark, child.get_index() + 1)
			_proc_marks.append(mark)

	# 4b. each add-on's node under the add-on host: its own bucket ("addon <id>")
	_mark_addons()

	# 5. "World" before and "Animator" after Animator in main.world
	if main.world != null and is_instance_valid(main.world):
		var w: Node = main.world
		for child: Node in w.get_children():
			if child.name == "Animator":
				var m_world := _create_mark("World", 0)
				w.add_child(m_world)
				w.move_child(m_world, child.get_index())
				_proc_marks.append(m_world)

				var m_anim := _create_mark("Animator", 0)
				w.add_child(m_anim)
				w.move_child(m_anim, child.get_index() + 1)
				_proc_marks.append(m_anim)

	# 6. priority brackets on self
	var brackets: Array = [
		[1, "rest (p0)"],
		[3, "FX (p2)"],
		[999, "Shadows/Veh (p10)"],
		[1001, "Late (p1000)"],
		[(1 << 20) + 1, "World post"],
		[(1 << 20) + 2, "__end__"],
	]
	for b: Array in brackets:
		var prio: int = int(b[0])
		var label: String = str(b[1])
		var mb := _create_mark(label, prio)
		add_child(mb)
		_proc_marks.append(mb)

	_sync_belt_prof(true)


## `detach`: the marks taken out of their parents now (the profiler switched off), not only freed at the
## frame's end. Leaving the tree (quit) they are only freed: their parents are busy removing their own
## children then (remove_child() errors), and a deferred remove_child ran after the parents had dropped
## them ("p_child->data.parent != this").
func _clear_proc_marks(detach := true) -> void:
	for m: Node in _proc_marks:
		if m != null and is_instance_valid(m):
			var parent := m.get_parent()
			if detach and parent != null and not parent.is_queued_for_deletion() and parent.is_inside_tree():
				parent.remove_child(m)
			m.queue_free()
	_proc_marks.clear()
	_marked.clear()
	_proc_has_sample = false
	_proc_total_ms = 0.0
	_proc_ema.clear()
	_proc_frame.clear()
	_proc_last_usec = 0


func _proc_mark_hit(label: String) -> void:
	var now: int = Time.get_ticks_usec()
	if label == "__start__":
		if spike_log:
			_spike_frame_start(now)
		_proc_last_usec = now
		_proc_frame.clear()
		return

	if _proc_last_usec <= 0:
		_proc_last_usec = now
		return

	var elapsed_usec: int = maxi(0, now - _proc_last_usec)
	_proc_last_usec = now

	if label != "__end__":
		_proc_frame[label] = int(_proc_frame.get(label, 0)) + elapsed_usec
	else:
		var total_usec: int = 0
		for k in _proc_frame:
			var u: int = int(_proc_frame[k])
			total_usec += u
			var bucket_ms: float = float(u) / 1000.0
			if not _proc_ema.has(k):
				_proc_ema[k] = bucket_ms
			else:
				_proc_ema[k] = lerpf(float(_proc_ema[k]), bucket_ms, 0.15)
		for k in _proc_ema.keys():
			if not _proc_frame.has(k):
				_proc_ema[k] = lerpf(float(_proc_ema[k]), 0.0, 0.15)
		var total_ms: float = float(total_usec) / 1000.0
		_note_peak(total_ms, now)
		if spike_log:
			_spike_end = now
			_spike_scripts = _proc_frame.duplicate()
			(func() -> void: _spike_deferred = Time.get_ticks_usec()).call_deferred()
		if not _proc_has_sample:
			_proc_total_ms = total_ms
			_proc_has_sample = true
		else:
			_proc_total_ms = lerpf(_proc_total_ms, total_ms, 0.15)


## The scripts' slowest frame, a whole second at a time (Godot's own "process" peak is the main
## thread's whole frame: scripts, deferred calls and the renderer's draw).
func _note_peak(total_ms: float, now: int) -> void:
	_proc_peak_cur = maxf(_proc_peak_cur, total_ms)
	if now - _proc_peak_at >= 1000000:
		_proc_peak_ms = _proc_peak_cur
		_proc_peak_cur = 0.0
		_proc_peak_at = now


## Marks for children of main and the game added since the marks were set up (added later in the
## join: rockets, add-ons' nodes), so the spike log names them too.
func _mark_new_children() -> void:
	if _proc_marks.is_empty() or main == null or not is_instance_valid(main) or main.world == null:
		return
	var game: Node = main.world.get_parent()
	for p: Node in [main, game]:
		if p == null or not is_instance_valid(p):
			continue
		for child: Node in p.get_children():
			if child is _ProcMark or _marked.has(child.get_instance_id()) or str(child.name).begins_with("StutterMark"):
				continue
			_marked[child.get_instance_id()] = true
			var mark := _create_mark(str(child.name), 0)
			p.add_child(mark)
			p.move_child(mark, child.get_index() + 1)
			_proc_marks.append(mark)
	_mark_addons()


## Marks round every add-on's node under the add-on host (main's "Addons"): one before it ("Addons": the
## host's own _process and its other children up to there) and one after it ("addon <id>": the add-on's
## node and its children). Add-ons started later are marked by the next rescan.
func _mark_addons() -> void:
	if main == null or not is_instance_valid(main):
		return
	var host: Node = main.get_node_or_null(NodePath(ADDON_HOST_NAME))
	if host == null:
		return
	for child: Node in host.get_children():
		if child is _ProcMark or _marked.has(child.get_instance_id()) or not str(child.name).begins_with(ADDON_NODE_PREFIX):
			continue
		if child.process_priority != 0 or child.process_mode == Node.PROCESS_MODE_DISABLED:
			continue  # runs out of the host's turn: left in whatever bucket it lands in
		_marked[child.get_instance_id()] = true
		var before := _create_mark(ADDON_HOST_NAME, 0)
		host.add_child(before)
		host.move_child(before, child.get_index())
		_proc_marks.append(before)
		var after := _create_mark(ADDON_MARK + addon_id_of(str(child.name)), 0)
		host.add_child(after)
		host.move_child(after, child.get_index() + 1)
		_proc_marks.append(after)


## An add-on's id from its node's name (addon_host.gd: "Addon_" + id with "-" as "_"): "terrain_elevation"
## back to "terrain-elevation" (ids are lower-case words joined by "-").
static func addon_id_of(node_name: String) -> String:
	return node_name.trim_prefix(ADDON_NODE_PREFIX).replace("_", "-")


# --- The spike log ------------------------------------------------------------------------------

## The threshold from --spike-log=<ms> (33 ms for --spike-log alone), or -1 when it isn't given.
static func spike_arg_ms(args: PackedStringArray = Switches.args()) -> float:
	for a: String in args:
		if a == "--spike-log":
			return SPIKE_DEFAULT_MS
		if a.begins_with("--spike-log="):
			var v := a.get_slice("=", 1)
			return clampf(float(v), 1.0, 10000.0) if v.is_valid_float() else SPIKE_DEFAULT_MS
	return -1.0


func _spike_open() -> void:
	DirAccess.make_dir_recursive_absolute(SPIKE_PATH.get_base_dir())
	if FileAccess.file_exists(SPIKE_PATH):
		_spike_file = FileAccess.open(SPIKE_PATH, FileAccess.READ_WRITE)
		if _spike_file != null:
			_spike_file.seek_end()
	else:
		_spike_file = FileAccess.open(SPIKE_PATH, FileAccess.WRITE)
	_probing_was_on = Probing.on
	Probing.on = true
	_spike_started = Time.get_ticks_usec()
	_spike_prev_start = 0
	_spike_before = _spike_counters()
	_spike_nodes = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	if not RenderingServer.frame_pre_draw.is_connected(_on_pre_draw):
		RenderingServer.frame_pre_draw.connect(_on_pre_draw)
		RenderingServer.frame_post_draw.connect(_on_post_draw)
	spike_lines = 0
	_spike_write("# spike log on: frames over %.0f ms (Zenith %s, Godot %s, thread model %d)" % [spike_ms,
		str(ProjectSettings.get_setting("application/config/version", "")), Engine.get_version_info().get("string", ""),
		int(ProjectSettings.get_setting("rendering/driver/threads/thread_model", 1))])
	if spike_render:
		_spike_write(spike_header(RenderStats.threaded(), RenderingServer.get_rendering_device() != null))


## The spike log's second line: what the render part and the buckets mean on this thread model.
static func spike_header(threaded: bool, has_rd: bool) -> String:
	var out := "# render: draw calls view/shadow, the viewport's measured cpu/gpu ms"
	out += ", stages cpu/gpu ms (the last frame the GPU finished)" if has_rd else ""
	out += " (stages need Godot started with --gpu-profile)" if has_rd else " (no renderer here: none)"
	if threaded:
		out += "; render thread on: no draw bucket, \"wait for renderer\" is the main thread waiting for the render thread's last frame"
	return out


func _spike_close() -> void:
	if RenderingServer.frame_pre_draw.is_connected(_on_pre_draw):
		RenderingServer.frame_pre_draw.disconnect(_on_pre_draw)
		RenderingServer.frame_post_draw.disconnect(_on_post_draw)
	if _spike_file != null:
		_spike_write("# spike log off (%d frames)" % spike_lines)
		_spike_file.close()
		_spike_file = null
	Probing.on = _probing_was_on


func _on_pre_draw() -> void:
	_spike_pre = Time.get_ticks_usec()


func _on_post_draw() -> void:
	_spike_post = Time.get_ticks_usec()


func _spike_write(line: String) -> void:
	if _spike_file == null:
		return
	if _spike_file.get_length() > SPIKE_MAX_BYTES:
		_spike_file.store_line("# spike log full (%d MB): stopped" % (SPIKE_MAX_BYTES >> 20))
		_spike_file.close()
		_spike_file = null
		return
	_spike_file.store_line(line)
	_spike_file.flush()


## The cumulative counters a frame's share is taken from.
func _spike_counters() -> Dictionary:
	var out := {"chunk": ChunkView.counters.duplicate(), "probe": Probing.counts.duplicate(), "pt": Probing.prof.duplicate()}
	if main != null and is_instance_valid(main) and main.world != null:
		out["world"] = (main.world.prof as Dictionary).duplicate()
	return out


## The last frame (from its __start__ to this one) written out when it was over the threshold.
func _spike_frame_start(now: int) -> void:
	var prev := _spike_prev_start
	_spike_prev_start = now
	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var after := _spike_counters()
	var threaded := spike_render and RenderStats.threaded()
	var rs := {}
	var steps: Array = []
	if threaded:  # asked every frame: the render thread answers a frame later
		rs = RenderStats.read(get_viewport().get_viewport_rid() if get_viewport() != null else RID())
		steps = RenderStats.steps()
	if prev > 0 and _spike_end > prev and float(now - prev) >= spike_ms * 1000.0:
		spike_lines += 1
		var render := ""
		if spike_render:
			if not threaded:
				rs = RenderStats.read(get_viewport().get_viewport_rid() if get_viewport() != null else RID())
				steps = RenderStats.steps()
			render = spike_render_part(rs, RenderStats.stages(steps[0], steps[1]) if steps.size() >= 2 else [])
		_spike_write(spike_line(now - prev, _spike_end - prev,
			spike_split(_spike_end, _spike_deferred, _spike_pre, _spike_post, now, threaded), _spike_scripts,
			_spike_deltas(_spike_before, after), nodes - _spike_nodes, (now - _spike_started) / 1000000.0, threaded, render))
	_spike_before = after
	_spike_nodes = nodes
	Probing.slowest_message = ["", 0]


## [deferred calls and frees, draw, the rest] in µs after the scripts ended (`end`); draw -1 when the
## renderer didn't draw (headless: the frees are then in the rest). `threaded` (the render thread on, the
## spike log's render part on): [deferred calls and frees, wait for renderer, the rest]: the draw runs on the
## render thread (frame_post_draw comes a frame later), and from the deferred calls' end to frame_pre_draw
## the main thread waits for the render thread's last frame (RenderingServer.sync); the wait is -1 when
## nothing was drawn (headless).
static func spike_split(end: int, deferred: int, pre: int, post: int, now: int, threaded := false) -> Array:
	var deferred_end := deferred if deferred > end and deferred <= now else end
	if threaded:
		if pre >= deferred_end and pre > end and pre <= now:
			return [deferred_end - end, pre - deferred_end, now - pre]
		return [deferred_end - end, -1, now - deferred_end]
	if pre > end and post > pre and post <= now:
		return [pre - end, post - pre, now - post]
	return [deferred_end - end, -1, now - deferred_end]


## A spike line's render part: `rs` RenderStats.read()'s numbers, `stages` RenderStats.stages() (empty
## without --gpu-profile).
static func spike_render_part(rs: Dictionary, stages: Array) -> String:
	var out := "render draws %d/%d" % [int(rs.get("view_draws", 0)), int(rs.get("shadow_draws", 0))]
	if rs.has("cpu_ms") or rs.has("gpu_ms"):
		out += ", viewport %.1f/%.1f" % [float(rs.get("cpu_ms", 0.0)), float(rs.get("gpu_ms", 0.0))]
	if not stages.is_empty():
		var parts := PackedStringArray()
		for st: Array in stages:
			parts.append("%s %.1f/%.1f" % [st[0], float(st[1]), float(st[2])])
		out += ", stages " + ", ".join(parts)
	return out


func _spike_deltas(a: Dictionary, b: Dictionary) -> Dictionary:
	var out := {}
	for group in b:
		var da: Dictionary = a.get(group, {})
		var db: Dictionary = b[group]
		for k in db:
			var d := int(db[k]) - int(da.get(k, 0))
			if d != 0:
				out["%s.%s" % [group, k]] = d
	return out


## One spike's line (static for the tests): times in µs, `scripts` label -> µs, `deltas` the
## counters' changes ("chunk.*", "probe.*" counts; "pt.*", "world.*" µs).
## `threaded`: split's middle is the wait for the renderer (spike_split); `render` the render part, after the
## counts ("" for none).
static func spike_line(frame_us: int, scripts_us: int, split: Array, scripts: Dictionary, deltas: Dictionary,
		nodes: int, at_s: float, threaded := false, render := "") -> String:
	var parts := PackedStringArray()
	parts.append("t %.1fs frame %.1f ms: scripts %.1f, deferred+frees %.1f, %s %s, rest %.1f" % [at_s,
		frame_us / 1000.0, scripts_us / 1000.0, int(split[0]) / 1000.0, "wait for renderer" if threaded else "draw",
		"-" if int(split[1]) < 0 else "%.1f" % (int(split[1]) / 1000.0), int(split[2]) / 1000.0])
	var top: Array = []
	var by_addon: Array = []
	var addons_us := 0
	for k in scripts:
		var key := str(k)
		if key.begins_with(ADDON_MARK):
			by_addon.append([key.trim_prefix(ADDON_MARK), int(scripts[k])])
			addons_us += int(scripts[k])
		elif key == ADDON_HOST_NAME:
			addons_us += int(scripts[k])
		else:
			top.append([key, int(scripts[k])])
	if addons_us > 0 or scripts.has(ADDON_HOST_NAME):
		top.append([ADDON_HOST_NAME, addons_us])  # the whole bucket, as before the split
	top.sort_custom(func(x: Array, y: Array) -> bool: return int(x[1]) > int(y[1]))
	var tops := PackedStringArray()
	for i in mini(5, top.size()):
		tops.append("%s %.1f" % [top[i][0], int(top[i][1]) / 1000.0])
	if not tops.is_empty():
		parts.append("top " + ", ".join(tops))
	by_addon.sort_custom(func(x: Array, y: Array) -> bool: return int(x[1]) > int(y[1]))
	var adds := PackedStringArray()
	for i in mini(3, by_addon.size()):
		if int(by_addon[i][1]) >= 100:
			adds.append("%s %.1f" % [by_addon[i][0], int(by_addon[i][1]) / 1000.0])
	if not adds.is_empty():
		parts.append("addons " + ", ".join(adds))
	var counts := PackedStringArray()
	var times: Array = []
	for k: String in deltas:
		var v := int(deltas[k])
		if k.begins_with("pt.") or k.begins_with("world.") or k.get_slice(".", 1).begins_with("us_"):
			if v >= 1000:
				times.append([k.get_slice(".", 1), v])
		else:
			counts.append("%s %d" % [k.get_slice(".", 1), v])
	times.sort_custom(func(x: Array, y: Array) -> bool: return int(x[1]) > int(y[1]))
	var ts := PackedStringArray()
	for i in mini(6, times.size()):
		ts.append("%s %.1f" % [times[i][0], int(times[i][1]) / 1000.0])
	if not ts.is_empty():
		parts.append("parts " + ", ".join(ts))
	counts.sort()
	counts.append("nodes %+d" % nodes)
	parts.append("counts " + ", ".join(counts))
	var msg := Probing.slowest_message
	if msg[0] != "":
		parts.append("slowest message %s %.1f" % [msg[0], int(msg[1]) / 1000.0])
	if render != "":
		parts.append(render)
	return " | ".join(parts)


func _top_scripts_line() -> String:
	var items: Array = []
	for k in _proc_ema:
		var ms: float = float(_proc_ema[k])
		if ms >= 0.05:
			items.append([str(k), ms])
	if items.is_empty():
		return ""
	items.sort_custom(func(a: Array, b: Array) -> bool:
		return float(a[1]) > float(b[1])
	)
	var count: int = mini(5, items.size())
	var parts := PackedStringArray()
	for i in count:
		var entry: Array = items[i]
		parts.append("%s %.1f" % [str(entry[0]), float(entry[1])])
	return "Top scripts (ms): " + " | ".join(parts)


func _update() -> void:
	if not is_inside_tree():
		return
	_plot.visible = graph
	_text.visible = counters
	_prof_panel.visible = profiler
	if profiler:
		_prof_text.text = profiler_text()
	var active := graph or counters or profiler or spike_log
	if not active:
		_last_usec = 0
	set_process(active)


func _process(delta: float) -> void:
	if (profiler or spike_log) and _proc_marks.is_empty():
		_setup_proc_marks()
	_rescan_left -= delta
	if _rescan_left <= 0.0:
		_rescan_left = MARK_RESCAN
		_mark_new_children()
	var now := Time.get_ticks_usec()
	if _last_usec > 0:
		_times[_at] = (now - _last_usec) / 1000.0
		_at = (_at + 1) % FRAMES
	_last_usec = now
	if graph:
		_plot.queue_redraw()
	_count_left -= delta
	if (counters or profiler) and _count_left <= 0.0:
		_count_left = COUNT_EVERY
		_sample_net()
		if counters:
			_text.text = counter_text()
		if profiler:
			_prof_text.text = profiler_text()


func _draw_graph() -> void:
	var size := _plot.size
	_plot.draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.55))
	for line in [[16.7, Color(0.49, 0.77, 0.42, 0.8)], [33.3, Color(0.95, 0.6, 0.18, 0.8)]]:
		var y := size.y * (1.0 - float(line[0]) / SCALE_MS)
		_plot.draw_line(Vector2(0, y), Vector2(size.x, y), line[1], 1.0)
	var points := PackedVector2Array()
	var sorted := PackedFloat32Array()
	for i in FRAMES:
		var ms := _times[(_at + i) % FRAMES]
		if ms <= 0.0:
			continue
		sorted.append(ms)
		points.append(Vector2(size.x * i / float(FRAMES - 1), size.y * (1.0 - minf(ms, SCALE_MS) / SCALE_MS)))
	if points.size() > 1:
		_plot.draw_polyline(points, Color(1.0, 0.9, 0.75), 1.5)
	if sorted.is_empty():
		return
	sorted.sort()
	var font := Kit.font("semibold")
	var text := "frame p50 %.1f  p99 %.1f  worst %.1f ms" % [sorted[sorted.size() / 2], sorted[mini(sorted.size() - 1, int(sorted.size() * 0.99))], sorted[-1]]
	_plot.draw_string(font, Vector2(Kit.px(6), Kit.px(16)), text, HORIZONTAL_ALIGNMENT_LEFT, -1, Kit.px(13), Color(1, 1, 1))


## The counters as lines of text (also for the UI test).
func counter_text() -> String:
	# The renderer's numbers without waiting for its thread (render_stats.gd): a frame or two old with it.
	var rs := RenderStats.read()
	var lines := [
		"%d fps | %.1f ms" % [Engine.get_frames_per_second(), 1000.0 / maxf(Engine.get_frames_per_second(), 1.0)],
		"draw calls %d | triangles %s | objects %d" % [int(rs.get("draws", 0)), _big(int(rs.get("prims", 0))), int(rs.get("objects", 0))],
		"nodes %d | video memory %.0f MB" % [int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), float(rs.get("vmem", 0)) / 1048576.0],
	]
	if main != null and main.world != null:
		lines.append("chunks %d loaded of %d | entities %d | view %d chunks, entities %d tiles" % [main.world.loaded_chunk_count(), main.world.chunks.size(),
			main.world.entity_count(), main.world.view_radius, main.world.focus_radius])
		lines.append("movers %d | belt items %d | on the ground %d" % [main.movers.count(), main.belt_items.count(), main.ground_items.count()])
		if main.decoratives != null:
			var g: Dictionary = main.decoratives.grass_stats()
			lines.append("3D grass: %d chunks, %s triangles (%s in view)" % [g["chunks"], _big(g["triangles"]), _big(g["view_triangles"])])
		var br := _bridge_node()
		var server_tick := int(br.get("server_tick")) if br != null else 0
		var waiting_count := int(br.call("waiting_count")) if (br != null and br.has_method("waiting_count")) else 0
		lines.append("server tick %d | messages waiting %d" % [server_tick, waiting_count])
	return "\n".join(PackedStringArray(lines))


## Detailed live profiler text for the top-right profiler overlay.
func profiler_text() -> String:
	var fps := Engine.get_frames_per_second()
	var frame_ms := 1000.0 / maxf(float(fps), 1.0)
	var vp: Viewport = get_viewport() if is_inside_tree() else null
	var vp_rid := vp.get_viewport_rid() if vp != null else RID()
	var thread_model := int(ProjectSettings.get_setting("rendering/driver/threads/thread_model", 1))
	var unmeasured := "render thread" if thread_model == 2 and RenderStats.old else "off"
	var gpu_str := unmeasured
	var rcpu_str := unmeasured
	var rs := RenderStats.read(vp_rid) if vp_rid.is_valid() else {}
	if _measured_here and vp_rid.is_valid():
		gpu_str = "%.2f ms" % float(rs.get("gpu_ms", 0.0))
		rcpu_str = "%.2f ms" % float(rs.get("cpu_ms", 0.0))
	# Godot's "process" time: the main thread's whole frame (scripts, deferred calls, the draw), its
	# slowest in the last second; the scripts' own peak is from the marks (_note_peak).
	var loop_peak_ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var scripts_str: String = ("Scripts %.1f ms (peak %.1f) | Main thread peak %.1f" % [_proc_total_ms,
		maxf(_proc_peak_ms, _proc_peak_cur), loop_peak_ms]) if _proc_has_sample else ("Scripts - | Main thread peak %.2f ms" % loop_peak_ms)
	var lines := PackedStringArray([
		"FPS %d (%.1f ms) | GPU %s | Render CPU %s | %s" % [fps, frame_ms, gpu_str, rcpu_str, scripts_str],
	])
	var top_line: String = _top_scripts_line()
	if top_line != "":
		lines.append(top_line)
	if main != null and is_instance_valid(main):
		var bi: Variant = main.get("belt_items")
		if bi is Object and is_instance_valid(bi as Object) and (bi as Object).has_method("prof_breakdown"):
			var b: String = str((bi as Object).call("prof_breakdown"))
			if b != "":
				lines.append("BeltItems (ms): " + b)
	if vp_rid.is_valid():
		var view_draws := int(rs.get("view_draws", 0))
		var view_prims := int(rs.get("view_prims", 0))
		var shad_draws := int(rs.get("shadow_draws", 0))
		var shad_prims := int(rs.get("shadow_prims", 0))
		lines.append("View %d draws, %s tris | Shadow %d draws, %s tris" % [
			view_draws, _big(view_prims), shad_draws, _big(shad_prims)])
	var br := _bridge_node()
	var loss_dict: Dictionary = br.get("loss") if (br != null and br.get("loss") != null) else {}
	var lost := int(loss_dict.get("lost", 0))
	var dgrams := int(loss_dict.get("datagrams", 0))
	var loss_pct := (100.0 * float(lost) / float(dgrams + lost)) if (dgrams + lost) > 0 else 0.0
	var update_rate := int(br.get("update_rate")) if br != null else 60
	var waiting_count := int(br.call("waiting_count")) if (br != null and br.has_method("waiting_count")) else 0
	lines.append("Net %.0f pkt/s, %.1f KB/s | loss %d (%.1f%%) | rate %d | queue %d | holds %d" % [
		_pkt_rate, _kbps, lost, loss_pct, update_rate, waiting_count, PerfLog.active().size()])
	if main != null and is_instance_valid(main):
		var ss: Variant = main.get("sun_shadows")
		var sun: Variant = main.get("_sun")
		if ss != null and is_instance_valid(ss):
			var split_str := "?"
			var sun_off := ""
			if sun != null and is_instance_valid(sun):
				var smode := _prop_int(sun, "directional_shadow_mode", -1)
				if smode == DirectionalLight3D.SHADOW_ORTHOGONAL:
					split_str = "1-map"
				elif smode == DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS:
					split_str = "2-split"
				elif smode == DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS:
					split_str = "4-split"
				if not _prop_bool(sun, "shadow_enabled", true):
					sun_off = " (off)"
			lines.append("Shadows %s%s | atlas %d | %.1f tex/t" % [
				split_str, sun_off, _prop_int(ss, "atlas"), _prop_float(ss, "texels")])
		var av: Variant = main.get("avatar")
		var rig: Variant = main.get("rig")
		var cam: Camera3D = vp.get_camera_3d() if vp != null else null
		var ref_pos := Vector3.ZERO
		var pos_parts := PackedStringArray()
		if av != null and is_instance_valid(av) and av.has_method("ground_position"):
			var gp: Vector2 = av.ground_position()
			ref_pos = Vector3(gp.x, 0.0, gp.y)
			pos_parts.append("Pos (%.1f, %.1f) ch(%d, %d)" % [gp.x, gp.y, floori(gp.x / 32.0), floori(gp.y / 32.0)])
		if rig != null and is_instance_valid(rig):
			if rig.has_method("focus_point"):
				var fp: Vector2 = rig.focus_point()
				ref_pos = Vector3(fp.x, 0.0, fp.y)
			pos_parts.append("Cam %.1ft %.0f°/%.0f°" % [
				_prop_float(rig, "distance"), _prop_float(rig, "pitch_degrees"), _prop_float(rig, "yaw_degrees")])
		if not pos_parts.is_empty():
			lines.append(" | ".join(pos_parts))
		var bi: Variant = main.get("belt_items")
		var bl: Variant = main.get("belt_lanes")
		if bi != null or bl != null:
			var lod_str := ItemCards.lod_mode
			if ItemCards.forced_lod_tier >= 0:
				lod_str = "forced LOD%d" % clampi(ItemCards.forced_lod_tier, 0, 2)
			elif ItemCards.lod_mode == "distance":
				lod_str = "dist (%s)" % ItemCards.lod_quality
			elif bi != null and is_instance_valid(bi) and bi.get("_cards") != null:
				var cards_obj: Variant = bi.get("_cards")
				lod_str = "global LOD%d" % _prop_int(cards_obj, "lod_tier")
			var vp_h := vp.get_visible_rect().size.y if vp != null else 1080.0
			var px_t := ItemCards.tile_pixels(cam, ref_pos, vp_h) if cam != null else 0.0
			var far_dist: float = _prop_float(bl, "far_3d_dist", 48.0) if (bl != null and is_instance_valid(bl)) else 48.0
			var far_3d_str := "all" if far_dist < 0.0 else ("off" if far_dist == 0.0 else "%.0ft" % far_dist)
			lines.append("Items %s | %.1f px/t | far3D %s | shad %.0ft" % [
				lod_str, px_t, far_3d_str, BeltItems.shadows_within])
		var dh: Variant = main.get("distant_horizon")
		var w: Variant = main.get("world")
		var fc: Variant = w.get("far_chunks") if (w != null and is_instance_valid(w)) else null
		if (dh != null and is_instance_valid(dh)) or (fc != null and is_instance_valid(fc)):
			var dh_str := "off"
			if dh != null and is_instance_valid(dh) and dh.has_method("stats"):
				var dh_stats: Dictionary = dh.stats()
				if bool(dh_stats.get("enabled", false)):
					dh_str = "%dch %d/%d sec %s tris" % [
						int(dh_stats.get("radius_chunks", 0)),
						int(dh_stats.get("visible_sections", 0)),
						int(dh_stats.get("sections", 0)),
						_big(int(dh_stats.get("triangles", 0)))]
			var far_str := "off"
			if fc != null and is_instance_valid(fc):
				var far_merged := _prop_int(fc, "_far_count")
				far_str = ("%d merged" % far_merged) if _prop_bool(fc, "enabled") else ("off (%d)" % far_merged)
			lines.append("Horizon %s | FarChunks %s" % [dh_str, far_str])
	return "\n".join(lines)


static func _prop_int(obj: Object, prop: String, fallback := 0) -> int:
	var v: Variant = obj.get(prop)
	return int(v) if v != null else fallback


static func _prop_float(obj: Object, prop: String, fallback := 0.0) -> float:
	var v: Variant = obj.get(prop)
	return float(v) if v != null else fallback


static func _prop_bool(obj: Object, prop: String, fallback := false) -> bool:
	var v: Variant = obj.get(prop)
	return bool(v) if v != null else fallback


static func _big(n: int) -> String:
	if n >= 1000000:
		return "%.2f M" % (n / 1000000.0)
	if n >= 1000:
		return "%.1f k" % (n / 1000.0)
	return str(n)
