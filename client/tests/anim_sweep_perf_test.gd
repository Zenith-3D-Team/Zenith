extends SceneTree
## Headless check and bench for perf wave 3 (Animator spikes, SignalLights):
## 1. anim.gd's cleanup of states of entities gone: every CLEANUP_INTERVAL it walked every state in one
##    frame (a 4-6 ms Animator frame every five seconds on a big base). Now spread over frames within
##    SWEEP_USEC (`--anim-sweep=old` as before). Both ways must forget the same states, wounds and wound
##    groups; the spread one's slowest frame must be far under the one-frame sweep.
## 2. signal_lights.gd: a refresh whose inputs are all as last time keeps the glows it has
##    (`--signal-skip-same=off` walks every signal every refresh, as before); any state reported, signal
##    added, darkness or focus change refreshes in full, and one in SKIP_MAX_IN_A_ROW + 1 always does;
##    far lights switched off and on again redraw at once.
##
##   godot --headless --audio-driver Dummy --path client --log-file <abs> -s res://tests/anim_sweep_perf_test.gd

const TestEnv := preload("res://tests/test_env.gd")
const Anim := preload("res://scripts/world/anim.gd")
const ChunkView := preload("res://scripts/world/chunk_view.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")

var WorldMirror: Script
var SignalLights: Script

var passes := 0
var fails := 0
const N_STATES := 60000


func check(ok: bool, what: String) -> void:
	if ok:
		passes += 1
		print("PASS: ", what)
	else:
		fails += 1
		print("FAIL: ", what)


## A world with N_STATES animated entities, every third one gone (their keys left in the animator).
func _filled_world() -> Node:
	var w: Node = WorldMirror.new()
	root.add_child(w)
	w.set_process(false)
	var anim: Node = w.animator
	anim.set_process(false)
	for k in range(1, N_STATES + 1):
		w.entities[k] = null
		anim._state(k)
		if k % 50 == 0:
			anim._wounds[k] = -1.5
			anim._wound_groups[k] = []
	for k in range(1, N_STATES + 1, 3):
		w.entities.erase(k)
	return w


func _kept(anim: Node) -> Array:
	var keys: Array = anim._states.keys()
	keys.sort()
	var wk: Array = anim._wounds.keys()
	wk.sort()
	var gk: Array = anim._wound_groups.keys()
	gk.sort()
	return [keys, wk, gk]


func _test_anim_sweep() -> void:
	# The one-frame sweep, as before (--anim-sweep=old).
	var w_old := _filled_world()
	var a_old: Node = w_old.animator
	var t0 := Time.get_ticks_usec()
	a_old._cleanup_all()
	var old_usec := Time.get_ticks_usec() - t0
	var old_kept := _kept(a_old)
	check(a_old._state_keys.size() == a_old._states.size(), "old sweep keeps the key list in step (%d vs %d)" % [
		a_old._state_keys.size(), a_old._states.size()])

	# The spread sweep: one pass, SWEEP_USEC a frame.
	var w_new := _filled_world()
	var a_new: Node = w_new.animator
	a_new._sweep_at = 0
	a_new._sweep_stage = 0
	var frames := 0
	var worst := 0
	var total := 0
	var going := true
	while going and frames < 100000:
		var t1 := Time.get_ticks_usec()
		going = a_new.sweep_some(Anim.SWEEP_USEC)
		var spent := Time.get_ticks_usec() - t1
		worst = maxi(worst, spent)
		total += spent
		frames += 1
	var new_kept := _kept(a_new)
	check(not going, "spread sweep finishes (%d frames)" % frames)
	check(new_kept == old_kept, "spread sweep forgets the same states, wounds and wound groups (%d/%d/%d kept)" % [
		(new_kept[0] as Array).size(), (new_kept[1] as Array).size(), (new_kept[2] as Array).size()])
	check((old_kept[0] as Array).size() == N_STATES - (N_STATES + 2) / 3, "a third of the states forgotten (%d)" % (old_kept[0] as Array).size())
	check(a_new._state_keys.size() == a_new._states.size(), "spread sweep keeps the key list in step")
	check(worst < old_usec / 3, "spread sweep's slowest frame %d us vs one-frame sweep %d us" % [worst, old_usec])
	print("BENCH anim cleanup: one frame %.2f ms; spread worst frame %.3f ms over %d frames (total %.2f ms), %d states" % [
		old_usec / 1000.0, worst / 1000.0, frames, total / 1000.0, N_STATES])

	# The usual pass: nothing gone since the last one (40,000 states walked, none freed).
	t0 = Time.get_ticks_usec()
	a_old._cleanup_all()
	var old_steady := Time.get_ticks_usec() - t0
	a_new._sweep_at = 0
	var steady_frames: Array[int] = []
	worst = 0
	frames = 0
	going = true
	while going and frames < 100000:
		var t2 := Time.get_ticks_usec()
		going = a_new.sweep_some(Anim.SWEEP_USEC)
		var sp := Time.get_ticks_usec() - t2
		worst = maxi(worst, sp)
		steady_frames.append(sp)
		frames += 1
	steady_frames.sort()
	var median: int = steady_frames[steady_frames.size() / 2]
	var over := 0
	for sp2: int in steady_frames:
		if sp2 > Anim.SWEEP_USEC * 2:
			over += 1
	print("BENCH steady spread frames: median %d us, %d of %d over %d us" % [median, over, steady_frames.size(), Anim.SWEEP_USEC * 2])
	check(median <= Anim.SWEEP_USEC * 2, "steady spread pass's median frame %d us within twice SWEEP_USEC" % median)
	check(worst < old_steady, "steady spread pass's slowest frame %d us vs one-frame sweep %d us" % [worst, old_steady])
	print("BENCH anim cleanup, nothing gone: one frame %.2f ms; spread worst frame %.3f ms over %d frames" % [
		old_steady / 1000.0, worst / 1000.0, frames])

	# A state made mid-pass and one gone mid-pass: the pass still ends with the lists in step.
	a_new._state(N_STATES + 7)
	w_new.entities[N_STATES + 7] = null
	a_new._sweep_at = 0
	a_new.sweep_some(1)
	a_new._state(N_STATES + 8)  # not in the world: forgotten by this pass or the next
	while a_new.sweep_some(Anim.SWEEP_USEC):
		pass
	a_new._sweep_at = 0
	while a_new.sweep_some(0):
		pass
	check(a_new._states.has(N_STATES + 7) and not a_new._states.has(N_STATES + 8), "states made during a pass are kept or forgotten by the next")
	check(a_new._state_keys.size() == a_new._states.size(), "key list in step after a pass with new states")

	# _process drives it: the timer starts a pass, frames carry it on.
	a_new._cleanup_timer = Anim.CLEANUP_INTERVAL
	w_new.entities.erase(N_STATES + 7)
	var was_old: bool = Anim.sweep_old
	Anim.sweep_old = false
	for i in 400:
		a_new._process(0.016)
		if a_new._sweep_at < 0 and i > 0:
			break
	check(not a_new._states.has(N_STATES + 7), "_process's spread pass forgets a state of an entity gone")
	Anim.sweep_old = was_old

	# reset empties the key list too.
	a_new.reset()
	check(a_new._state_keys.is_empty() and a_new._sweep_at == -1, "reset clears the key list and the pass")
	w_old.queue_free()
	w_new.queue_free()


func _test_signal_skip() -> void:
	var off_was: bool = SignalLights.disabled_by_arg
	var skip_was: bool = SignalLights.skip_same
	SignalLights.disabled_by_arg = false
	GroundHeight.clear()
	var holder := Node3D.new()
	root.add_child(holder)
	var w: Node3D = WorldMirror.new()
	holder.add_child(w)
	w.set_process(false)
	w.animator.set_process(false)
	w.protos.add_entities([
		[6, "rail-signal", "rail-signal", -0.5, -0.5, 0.5, 0.5, 90, 160, 90, 1, 1],
		[7, "rail-chain-signal", "rail-chain-signal", -0.5, -0.5, 0.5, 0.5, 90, 160, 160, 1, 1],
	])
	w.chunks[Vector2i.ZERO] = ChunkView.new()
	var unit := 2000
	for y in 16:
		for x in 16:
			w._add([unit, 6 if (x + y) % 2 == 0 else 7, (x * 2) * 256 + 128, (y * 2) * 256 + 128, 0, {"sg": 1 + (x % 4)}])
			unit += 1
	var sigs: Node3D = SignalLights.new()
	sigs.protos = w.protos
	sigs.world = w
	holder.add_child(sigs)
	sigs.set_process(false)
	sigs._on_entities_changed(Vector2i.ZERO)
	sigs.darkness = 0.9

	SignalLights.skip_same = true
	sigs._process(SignalLights.REFRESH)
	var lit0: int = sigs.lit_count()
	var tints0: PackedColorArray = sigs._tints.duplicate()
	check(lit0 == 256, "all 256 signals glow (%d)" % lit0)
	var full0: int = sigs.refreshes
	sigs._process(SignalLights.REFRESH)
	check(sigs.refreshes == full0 and sigs.refreshes_kept == 1 and sigs.lit_count() == lit0, "an unchanged refresh keeps its glows")

	# A reported state (world.gd _apply_state -> animator.state_changed) refreshes in full.
	w._apply_state(2001, 1)
	sigs._process(SignalLights.REFRESH)
	check(sigs.refreshes == full0 + 1, "a reported state refreshes")
	var changed := false
	for i in sigs._tints.size():
		if i >= tints0.size() or sigs._tints[i] != tints0[i]:
			changed = true
	check(changed, "the reported state changes a signal's colour")
	sigs.darkness = 0.5
	sigs._process(SignalLights.REFRESH)
	check(sigs.refreshes == full0 + 2, "darkness changing refreshes")
	sigs.focus = Vector2(3.0, 4.0)
	sigs._process(SignalLights.REFRESH)
	check(sigs.refreshes == full0 + 3, "focus moving refreshes")
	w._add([unit, 6, 30 * 256 + 128, 30 * 256 + 128, 0, {"sg": 2}])
	sigs._on_entities_changed(Vector2i.ZERO)
	sigs._process(SignalLights.REFRESH)
	check(sigs.refreshes == full0 + 4 and sigs.lit_count() == 257, "a signal added refreshes (%d)" % sigs.lit_count())
	var before: int = sigs.refreshes
	for i in SignalLights.SKIP_MAX_IN_A_ROW + 1:
		sigs._process(SignalLights.REFRESH)
	check(sigs.refreshes == before + 1, "one refresh in SKIP_MAX_IN_A_ROW + 1 is done in full anyway")
	# Far lights off then on again with nothing else changed: the glows come back on the next refresh.
	sigs.set_far_lights_enabled(false)
	sigs._process(SignalLights.REFRESH)
	check(sigs.lit_count() == 0, "far lights off clears the glows (%d)" % sigs.lit_count())
	before = sigs.refreshes
	sigs.set_far_lights_enabled(true)
	sigs._process(SignalLights.REFRESH)
	check(sigs.refreshes == before + 1 and sigs.lit_count() == 257, "far lights back on redraws the glows at once (%d lit)" % sigs.lit_count())

	# Bench: a refresh walking every signal vs a kept one.
	var reps := 200
	SignalLights.skip_same = false
	var t0 := Time.get_ticks_usec()
	for i in reps:
		sigs._process(SignalLights.REFRESH)
	var full_us := float(Time.get_ticks_usec() - t0) / reps
	SignalLights.skip_same = true
	sigs._process(SignalLights.REFRESH)
	sigs._skipped = 0
	t0 = Time.get_ticks_usec()
	var kept_n := 0
	for i in reps:
		var k: int = sigs.refreshes_kept
		sigs._skipped = 0  # (bench the kept path alone)
		sigs._process(SignalLights.REFRESH)
		kept_n += sigs.refreshes_kept - k
	var kept_us := float(Time.get_ticks_usec() - t0) / reps
	check(kept_n == reps, "bench refreshes all kept (%d)" % kept_n)
	check(kept_us < full_us, "a kept refresh %.1f us vs full %.1f us" % [kept_us, full_us])
	print("BENCH signal refresh (257 signals): full %.1f us, kept %.1f us" % [full_us, kept_us])

	# Off: every refresh in full, as before.
	SignalLights.skip_same = false
	before = sigs.refreshes
	sigs._process(SignalLights.REFRESH)
	sigs._process(SignalLights.REFRESH)
	check(sigs.refreshes == before + 2, "--signal-skip-same=off refreshes every time")

	holder.queue_free()
	SignalLights.skip_same = skip_was
	SignalLights.disabled_by_arg = off_was


func _initialize() -> void:
	TestEnv.isolate("anim-sweep-perf-test")
	_run.call_deferred()


func _run() -> void:
	WorldMirror = load("res://scripts/world/world.gd")
	SignalLights = load("res://scripts/world/signal_lights.gd")
	_test_anim_sweep()
	_test_signal_skip()
	await process_frame
	await process_frame
	print("anim_sweep_perf_test: %d passed, %d failed (%s)" % [passes, fails, "PASS" if fails == 0 else "FAIL"])
	TestEnv.clean()
	quit(1 if fails > 0 else 0)
