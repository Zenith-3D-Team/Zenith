extends SceneTree
## perf-world-8: FluidsPower's windows (fluids_power.gd, --fluid-windows-index) and the burner inserters'
## scan (burner_fx.gd, --burner-scan), each with the switch on and off over the same busy world: the same
## windows and the same burning burners either way, the indexed ways do less (a complete `fl` that moves no
## windowed unit draws nothing again; only the inserters near the listener are looked at). Prints the time
## of each way and of fx.gd _scan's parts (fx_machines, fx_burners, fx_movers, fx_loops).
## Headless, a real world.gd with ChunkViews unbuilt (no models: windowed pipes find no mesh and draw no
## column, as in a test without packs; tanks draw, with --tank-window's switch held on).
##
##   godot --headless --audio-driver Dummy --path client --log-file <abs> -s res://tests/fluids_burner_scan_test.gd

const TestEnv := preload("res://tests/test_env.gd")
const ChunkView := preload("res://scripts/world/chunk_view.gd")
const BurnerFx := preload("res://scripts/fx/burner_fx.gd")
const Probing := preload("res://scripts/debug/probing.gd")

## The busy world: CHUNKS x CHUNKS chunks round the origin, each with these.
const CHUNKS := 15
const PIPES := 40  # straight pipes in a row, every second one windowed (`pw`)
const TANKS := 1
const MACHINES := 20  # assemblers with two fluid boxes each, working
const INSERTERS := 40  # of which BURNERS are burner inserters; every hand moving
const BURNERS := 6
const RUNS := 15

var _fails := 0
var _unit := 1000
## Loaded at run time: world.gd and fx.gd name the Bridge autoload, not there yet when a -s script compiles.
var WorldScript: Script
var FluidsPower: Script
var FxScript: Script


func _check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		_fails += 1


func _initialize() -> void:
	TestEnv.isolate("fluids-burner-scan-test")
	create_timer(240.0).timeout.connect(func() -> void:
		print("FAIL fluids_burner_scan_test: timed out")
		quit(1))
	_run.call_deferred()


func _next() -> int:
	_unit += 1
	return _unit


func _run() -> void:
	WorldScript = load("res://scripts/world/world.gd")
	FluidsPower = load("res://scripts/world/fluids_power.gd")
	FxScript = load("res://scripts/fx/fx.gd")
	var w = WorldScript.new()
	root.add_child(w)
	w.protos.add_entities([
		[1, "storage-tank", "storage-tank", -1.5, -1.5, 1.5, 1.5, 100, 100, 100, 3, 3],
		[2, "pipe", "pipe", -0.5, -0.5, 0.5, 0.5, 100, 100, 100, 1, 1],
		[3, "assembling-machine-2", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 150, 150, 150, 3, 3],
		[4, "inserter", "inserter", -0.15, -0.15, 0.15, 0.15, 150, 150, 50, 1, 1],
		[5, "burner-inserter", "inserter", -0.15, -0.15, 0.15, 0.15, 150, 100, 50, 1, 1],
	])
	w.protos.fluid_colors["water"] = Color(0.2, 0.4, 1.0)
	w.protos.fluid_colors["crude-oil"] = Color(0.1, 0.1, 0.1)
	var fl: Array = []  # a complete `fl`'s list
	var tanks: Array = []
	var plain: Array = []  # units in `fl` that show no window (machines, unwindowed pipes)
	var inserters := {}
	var burner_units := {}
	var half := CHUNKS / 2
	for cy in range(-half, half + 1):
		for cx in range(-half, half + 1):
			var c := Vector2i(cx, cy)
			w.chunks[c] = ChunkView.new()
			var ox := cx * 32
			var oy := cy * 32
			for i in PIPES:
				var u := _next()
				var x := ox + 1 + (i % 30)
				var y := oy + 2 + (i / 30)
				var extra := {"pc": 10, "pc_mod": 1}
				if (x + y) % 2 == 0:
					extra["pw"] = 1
				else:
					plain.append(u)
				w._add([u, 2, x * 256 + 128, y * 256 + 128, 0, extra])
				fl.append_array([u, 0, 0, 50, 100, 15])
			for i in TANKS:
				var u := _next()
				w._add([u, 1, (ox + 5) * 256 + 128, (oy + 8) * 256 + 128, 0])
				tanks.append(u)
				fl.append_array([u, 0, 0, 12000, 25000, 15])
			for i in MACHINES:
				var u := _next()
				w._add([u, 3, (ox + 2 + (i % 8) * 4) * 256 + 128, (oy + 12 + (i / 8) * 4) * 256 + 128, 0])
				fl.append_array([u, 0, 0, 20, 100, 15, u, 1, 1, 10, 100, 15])
				plain.append(u)
				w.working[u] = 1
				if not w._stated.has(c):
					w._stated[c] = {}
				w._stated[c][u] = true
			for i in INSERTERS:
				var u := _next()
				var burner := i < BURNERS
				w._add([u, 5 if burner else 4, (ox + 1 + i % 30) * 256 + 128, (oy + 26 + i / 30) * 256 + 128, 0])
				inserters[u] = 1
				if burner:
					burner_units[u] = true
	# fluid_name(id): the test's ids 0 water, 1 crude oil.
	w.protos.fluid_names[0] = "water"
	w.protos.fluid_names[1] = "crude-oil"
	await process_frame
	print("world: %d entities, %d fluid boxes, %d inserters (%d burner)" % [w.entities.size(), fl.size() / 6,
		inserters.size(), burner_units.size()])
	await _fluids(w, fl, tanks, plain)
	await _burners(w, inserters, burner_units)
	await _fx_scan(w, inserters)
	w.queue_free()
	await process_frame
	print("fluids_burner_scan_test: %s (%d failures)" % ["ok" if _fails == 0 else "FAIL", _fails])
	quit(1 if _fails > 0 else 0)


static func _fl_msg(k: int, list: Array) -> Dictionary:
	return {"t": "fl", "k": k, "part": 1, "parts": 1, "l": list}


## A copy of `fl` with unit `u`'s first box's amount set to `amount`.
static func _with_amount(fl: Array, u: int, amount: int) -> Array:
	var out := fl.duplicate()
	var i := 0
	while i + 5 < out.size():
		if int(out[i]) == u:
			out[i + 3] = amount
			return out
		i += 6
	return out


## The tank windows drawn, as sorted strings (order is the walk's, not the drawing's).
static func _spots(fp) -> Array:
	var out: Array = []
	var xf: Array = fp.window_spots[0]
	var col: Array = fp.window_spots[1]
	for i in xf.size():
		out.append("%s %s" % [str(xf[i]), str(col[i])])
	out.sort()
	return out


func _make_fp(w, index: bool):
	FluidsPower.windows_index = index
	var fp = FluidsPower.new()
	fp.world = w
	root.add_child(fp)
	await process_frame
	fp.reset()
	fp._process(0.0)
	return fp


func _fluids(w, fl: Array, tanks: Array, plain: Array) -> void:
	var was_index: bool = FluidsPower.windows_index
	var was_tanks: bool = FluidsPower.tank_windows
	FluidsPower.tank_windows = true
	var results := {}
	for index: bool in [false, true]:
		var fp = await _make_fp(w, index)
		var tag := "index" if index else "old"
		fp.handle(_fl_msg(1, fl))
		var r0: int = fp.window_rebuilds
		fp._process(0.0)
		_check(fp.window_rebuilds == r0 + 1, "%s: the first fl draws the windows" % tag)
		var first := _spots(fp)
		first.append("pipe columns %d" % fp.pipe_fluid_spots.size())
		# An `fl` that moves only boxes no window shows (a machine's, an unwindowed pipe's).
		var quiet := _with_amount(_with_amount(fl, int(plain[0]), 77), int(plain[1]), 33)
		var r1: int = fp.window_rebuilds
		fp.handle(_fl_msg(2, quiet))
		fp._process(0.0)
		if index:
			_check(fp.window_rebuilds == r1 and fp.fl_skips == 1,
				"index: an fl that changes no windowed unit draws nothing again (rebuilds %d -> %d, skips %d)"
				% [r1, fp.window_rebuilds, fp.fl_skips])
		else:
			_check(fp.window_rebuilds == r1 + 1, "old: every complete fl draws the windows again")
		# A tank's level moves: drawn again, in both.
		var moved := _with_amount(quiet, int(tanks[3]), 24000)
		var r2: int = fp.window_rebuilds
		fp.handle(_fl_msg(3, moved))
		fp._process(0.0)
		_check(fp.window_rebuilds == r2 + 1, "%s: a tank's level moving draws the windows again" % tag)
		var second := _spots(fp)
		second.append("pipe columns %d" % fp.pipe_fluid_spots.size())
		_check(second != first, "%s: the moved tank's window changed" % tag)
		# A chunk without windows changes (the world's entities_changed): nothing drawn in the indexed way.
		var r3: int = fp.window_rebuilds
		w.entities_changed.emit(Vector2i(99, 99))
		fp._process(0.0)
		_check(fp.window_rebuilds == r3, "%s: an empty chunk's change draws nothing again" % tag)
		# A chunk with a tank changes: drawn again in both.
		w.entities_changed.emit(Vector2i(0, 0))
		fp._process(0.0)
		_check(fp.window_rebuilds == r3 + 1, "%s: a tank's chunk changing draws the windows again" % tag)
		var third := _spots(fp)
		third.append("pipe columns %d" % fp.pipe_fluid_spots.size())
		_check(third == second, "%s: and the same windows" % tag)
		# Time: a complete `fl` that moves one machine's box, handled and drawn (or not).
		var times: Array = []
		var r_t: int = fp.window_rebuilds
		for run in RUNS:
			var msg := _fl_msg(10 + run, _with_amount(fl, int(plain[run % plain.size()]), 1 + run))
			fp.handle(msg)
			var t0 := Time.get_ticks_usec()
			fp._process(0.0)
			times.append(Time.get_ticks_usec() - t0)
		times.sort()
		print("%s: %d of %d fl's drew the windows again" % [tag, fp.window_rebuilds - r_t, RUNS])
		# And _update_windows itself, forced (the walk: every fluid box, or the windowed ones).
		var walks: Array = []
		for run in RUNS:
			var t0 := Time.get_ticks_usec()
			fp._update_windows()
			walks.append(Time.get_ticks_usec() - t0)
		walks.sort()
		print("%s: fl's _process median %.2f ms (max %.2f), _update_windows median %.2f ms" % [tag,
			times[RUNS / 2] / 1000.0, times[RUNS - 1] / 1000.0, walks[RUNS / 2] / 1000.0])
		results[index] = [first, second]
		fp.queue_free()
		await process_frame
	_check(results[true][0] == results[false][0] and results[true][1] == results[false][1],
		"index and old draw the same tank windows and pipe columns (%d)" % (results[true][0] as Array).size())
	print("pipe columns drawn: %s" % str((results[true][0] as Array).back()))
	_check((results[true][0] as Array).size() - 1 == 2 * CHUNKS * CHUNKS * TANKS,
		"every tank drew its glass and level (%d)" % (results[true][0] as Array).size())
	FluidsPower.windows_index = was_index
	FluidsPower.tank_windows = was_tanks


func _burners(w, inserters: Dictionary, burner_units: Dictionary) -> void:
	var was: bool = BurnerFx.near_scan
	var mesh := BoxMesh.new()
	BurnerFx._burners[mesh] = BurnerFx.VENT
	var mesh_of := func(rec) -> Mesh:
		return mesh if burner_units.has(int(rec.unit)) else null
	var vent_of := func(rec) -> Vector3: return BurnerFx.vent_at(rec.pos, 0.0)
	var focus := Vector2(10.0, 20.0)
	var got := {}
	for near: bool in [false, true]:
		BurnerFx.near_scan = near
		var b := BurnerFx.new()
		b.follow(w)
		var times: Array = []
		var sources: Array = []
		for run in RUNS:
			sources = []
			var t0 := Time.get_ticks_usec()
			b.scan(w.entities, inserters, focus, 40.0, sources, mesh_of, vent_of, w)
			times.append(Time.get_ticks_usec() - t0)
		times.sort()
		var keys: Array = b.burning.keys()
		keys.sort()
		var heard: Array = []
		for s: Dictionary in sources:
			heard.append(str(s["key"]))
		heard.sort()
		got[near] = [keys, heard]
		print("burner scan %s: median %.3f ms (max %.3f), %d hands looked at, %d burning" % [
			"near" if near else "old", times[RUNS / 2] / 1000.0, times[RUNS - 1] / 1000.0, b.looked, keys.size()])
		if near:
			_check(b.looked < inserters.size() / 4, "near: only the near chunks' hands looked at (%d of %d)"
				% [b.looked, inserters.size()])
			# A chunk changes: its inserters are read again (one more burner placed there is found).
			var u := _next()
			w._add([u, 5, 12 * 256 + 128, 21 * 256 + 128, 0])
			inserters[u] = 1
			burner_units[u] = true
			w.entities_changed.emit(w.chunk_of(Vector2(12.5, 21.5)))
			b.scan(w.entities, inserters, focus, 40.0, [], mesh_of, vent_of, w)
			_check(b.burning.has(u), "near: a burner added to a changed chunk burns")
			b.burning.erase(u)
			inserters.erase(u)
			burner_units.erase(u)
		b.follow(null)
	_check(got[true][0] == got[false][0] and not (got[true][0] as Array).is_empty(),
		"near and old find the same burning burners (%d)" % (got[true][0] as Array).size())
	_check(got[true][1] == got[false][1], "near and old play the same crackles (%s)" % str(got[true][1]))
	BurnerFx._burners.erase(mesh)
	BurnerFx.near_scan = was


## fx.gd _scan in the busy world, each way, with its parts (Probing).
func _fx_scan(w, inserters: Dictionary) -> void:
	var was: bool = BurnerFx.near_scan
	var mesh := BoxMesh.new()
	BurnerFx._burners[mesh] = BurnerFx.VENT  # any(): the burners' walk runs, as with Vasillo's pack
	var fx = FxScript.new()
	fx.world = w
	root.add_child(fx)
	await process_frame
	for u in inserters:
		w.animator.arm_working[u] = 1
	var was_probe := Probing.on
	Probing.on = true
	for near: bool in [false, true]:
		BurnerFx.near_scan = near
		Probing.prof.clear()
		var times: Array = []
		for run in RUNS:
			var t0 := Time.get_ticks_usec()
			fx._scan(0.25)
			times.append(Time.get_ticks_usec() - t0)
		times.sort()
		var parts := ""
		for key in ["fx_machines", "fx_burners", "fx_movers", "fx_loops"]:
			parts += " %s %.3f" % [key, float(Probing.prof.get(key, 0)) / RUNS / 1000.0]
		print("fx _scan (%s): median %.3f ms; parts per scan:%s" % ["near" if near else "old",
			times[RUNS / 2] / 1000.0, parts])
	Probing.on = was_probe
	Probing.prof.clear()
	for u in inserters:
		w.animator.arm_working.erase(u)
	fx.burners.follow(null)
	fx.queue_free()
	await process_frame
	BurnerFx._burners.erase(mesh)
	BurnerFx.near_scan = was
