extends SceneTree
## sound_bank.gd's background decodes against the freeze the owner's game had joining a big base: a
## dump showed every low-priority worker of the pool (4 of 16) blocked in a sound decode on
## sound_bank.gd's lock, which the main thread owned, while the main thread waited for the engine's
## own low-priority task (a render pipeline's compile) queued behind them: neither could go on.
## Here the main thread holds every lock sound_bank.gd has, asks for more sounds than the pool has
## workers, then waits for a low-priority task of its own as the engine did. The decodes must not
## need any lock the main thread can hold. A watchdog thread ends a deadlock as a crash (a non-zero
## exit; the main thread can't answer any more). Needs no Factorio install: a missing file is
## decoded to null all the same, through the same worker. Run headless:
##   godot --headless --path client -s res://tests/sound_decode_test.gd
## The asks go through every way Zenith decodes a sound, with the test's own tones (sound_fixtures.gd)
## where they need files: a missing file, the install's, a model pack's (and an Opus one there, its
## warning handed back to the main thread), api.sound (an add-on's own file and a mod's, as
## preload_sounds() asks), and a mod zip's steps and plants' rustle as step_sounds.gd lists them. The
## locks held are sound_bank.gd's and those of the scripts a decode reached before (mod_files.gd,
## model_packs.gd): a decode now reads only what the main thread found for it.
## Then the cap on decodes at once (sound_bank.gd DECODES_AT_ONCE): never more running, every ask
## of 40 decoded, stream() on a queued ask, clear_cache() with decodes queued and running. Last, with
## the locks let go, a worker must get each of them after the main thread's asks (_unlock_probe).
## Prints "SOUND DECODE FAILS: 0" when all pass; quits with 1 otherwise.

const SoundBank := preload("res://scripts/fx/sound_bank.gd")
const ModFiles := preload("res://scripts/world/mod_files.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const StepSounds := preload("res://scripts/fx/step_sounds.gd")
const AddonSound := preload("res://scripts/addons/addon_sound.gd")
const Tones := preload("res://tests/sound_fixtures.gd")
const TestEnv := preload("res://tests/test_env.gd")

## The main thread's wait, then the decodes taken in: well under a second when nothing is stuck.
const LIMIT_MSEC := 20000
## How long the decodes get to finish with the locks held (40 short decodes, 2 at once: well under 1 s).
const HELD_MSEC := 10000
## How long the main thread asks while a worker takes the locks (_unlock_probe).
const PROBE_MSEC := 400
## sound_bank.gd's locks: the one the dump found, by name, and every other static Mutex its source
## declares (found by reading it, so a lock that comes back under another name is held too).
const LOCKS := ["_stream_lock", "_lock"]
const SOURCE := "res://scripts/fx/sound_bank.gd"
## Other scripts' locks a decode took before (located on the worker): held too.
const OTHER_LOCKS := [[ModFiles, "_mutex"], [ModelPacks, "_mutex"]]
## The sound the dump's blocked worker was decoding: decoded for real when the install is there.
const REAL := "core/sound/deconstruct-small.ogg"
## The fixtures: a model pack's sound, an Opus one in it (not played: null, and warned about), a mod's zip.
const PACK_SOUND := "base/sound/zenith-decode-pack.ogg"
const PACK_OPUS := "base/sound/zenith-decode-opus.ogg"
const MOD := "zenith-decode-mod"
const ADDON_ID := "decode-test"

var _fails := 0
var _done := false
var _watch := Thread.new()
var _keys: Array[String] = []
var _until := 0
var _phase := 0
var _most_running := 0
var _t0 := 0
var _paths := {}  # the new ways' sounds: path -> what asked for it
var _root := ""


func _check(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("FAIL: ", what)


func _initialize() -> void:
	TestEnv.isolate("sound-decode-test")
	_watch.start(_watchdog)
	_fixtures()
	var script: Script = SoundBank
	var held := _locks()
	for m in held:
		m.lock()
	# The new ways first (packs', add-ons', mods', steps'), so their decodes are the first to start.
	_ask_new_ways()
	# More decodes than the pool has threads at all, so every low-priority one is taken.
	var n := maxi(32, OS.get_processor_count() * 2)
	for i in n:
		_keys.append("base/sound/zenith-test-missing-%d.ogg" % i)
	var installed := SoundBank.exists(REAL)
	if installed:
		_keys.append(REAL)
	for path in _keys:
		_check(SoundBank.stream_soon(path) == null, "a sound's first ask is null (decoded on a worker): " + path)
	# Decodes that finish meanwhile are taken in at the next ask, and the queue's next started.
	var asked := _keys.size() + _paths.size()
	var taken := 0
	for path in _keys + Array(_paths.keys()):
		if (script.get("_streams") as Dictionary).has("%s|0" % path):
			taken += 1
	_check(_running_now() == mini(asked - taken, _cap()), "%d decodes at once" % _cap())
	_check(_queued_now() + _running_now() + taken == asked, "the rest wait in the queue (%d queued, %d running, %d done of %d asks)"
		% [_queued_now(), _running_now(), taken, asked])
	var t0 := Time.get_ticks_msec()
	var engine := WorkerThreadPool.add_task(func() -> void: pass, false, "stand-in for the engine's pipeline compile")
	WorkerThreadPool.wait_for_task_completion(engine)
	print("the main thread's wait for a low-priority task, with %d decodes asked for and %d locks held (sound_bank.gd's, mod_files.gd's, model_packs.gd's): %d ms"
		% [asked, held.size(), Time.get_ticks_msec() - t0])
	# With the cap a decode stuck on a lock no longer fills the pool, so the wait above can pass with
	# one stuck: every decode must also finish while the locks are still held.
	t0 = Time.get_ticks_msec()
	while _pending() > 0 and Time.get_ticks_msec() - t0 < HELD_MSEC:
		SoundBank.stream_soon(_keys[0])  # takes finished decodes in and starts the queued ones
		_running_now()
		OS.delay_msec(2)
	_check(_pending() == 0, "every decode finished with the locks still held (%d left after %d ms): none waits for a lock"
		% [_pending(), Time.get_ticks_msec() - t0])
	print("every decode finished with the locks held: %d ms" % [Time.get_ticks_msec() - t0])
	for m in held:
		m.unlock()
	if not installed:
		print("skip a real sound's decode: no Factorio install")
	_until = Time.get_ticks_msec() + LIMIT_MSEC


## Every lock a decode could meet: sound_bank.gd's (LOCKS and every other static Mutex its source
## declares, found by reading it, so a lock that comes back under another name counts too) and
## OTHER_LOCKS.
func _locks() -> Array[Mutex]:
	var script: Script = SoundBank
	var out: Array[Mutex] = []
	var names: Array[String] = []
	names.assign(LOCKS)
	var re := RegEx.create_from_string("(?m)^static var (\\w+)\\b[^\\n]*\\bMutex\\b")
	for m in re.search_all(FileAccess.get_file_as_string(SOURCE)):
		if not names.has(m.get_string(1)):
			names.append(m.get_string(1))
	for name: String in names:
		var m = script.get(name)
		if m is Mutex:
			out.append(m)
	for other: Array in OTHER_LOCKS:
		var m = (other[0] as Script).get(str(other[1]))
		if m is Mutex:
			out.append(m)
	return out


## An unbalanced unlock (main's old _located() unlocked _stream_lock twice) left the lock owned by the
## main thread (the dump: a recursion count of -13), and every worker that took it after blocked for
## good; while the main thread holds the locks itself nothing shows it. Godot 4.7's Mutex shrugs off an
## extra unlock nobody else is near (tried: no worker blocked after); it breaks when another thread has the
## lock at that moment. So with the locks let go, a worker takes and gives back each lock over and over
## (try_lock, never waiting) while the main thread asks through every way (exists(), stream(), and
## stream_soon() with its worker's decode taken in), then a worker must get each lock. A main thread
## stuck in a lock() instead ends as the watchdog's crash.
func _unlock_probe() -> void:
	var paths: Array[String] = [REAL, "base/sound/zenith-test-probe-missing.ogg"]
	for path: String in _paths:
		paths.append(path)
	var locks := _locks()
	var stop := [false]
	var turns := [0]
	var contend := func() -> void:
		while not stop[0]:
			for m: Mutex in locks:
				if m.try_lock():
					m.unlock()
			turns[0] += 1
	var rival := WorkerThreadPool.add_task(contend, false, "unlock probe: a worker on the locks")
	var t0 := Time.get_ticks_msec()
	var rounds := 0
	while rounds < 3 or Time.get_ticks_msec() - t0 < PROBE_MSEC:
		for path in paths:
			SoundBank.exists(path)
			SoundBank.stream(path)
			SoundBank.stream_soon(path, true)  # looped: a worker's decode the first round
		rounds += 1
	stop[0] = true
	WorkerThreadPool.wait_for_task_completion(rival)
	t0 = Time.get_ticks_msec()
	while _pending() > 0 and Time.get_ticks_msec() - t0 < HELD_MSEC:
		SoundBank.stream_soon(paths[0], true)  # takes finished decodes in
		OS.delay_msec(2)
	_check(_pending() == 0, "the probe's decodes finished (%d left)" % _pending())
	var got := []
	got.resize(locks.size())
	got.fill(false)
	var probe := func() -> void:
		for i in locks.size():
			if locks[i].try_lock():
				got[i] = true
				locks[i].unlock()
	WorkerThreadPool.wait_for_task_completion(WorkerThreadPool.add_task(probe, false, "unlock probe"))
	print("unlock probe: %d rounds of asks against a worker's %d turns on the locks" % [rounds, turns[0]])
	for i in locks.size():
		_check(bool(got[i]), "a worker gets lock %d of %d after the main thread's asks: no unbalanced unlock left it owned"
			% [i + 1, locks.size()])
	print("unlock probe: a worker got %d of %d locks after %d paths asked every way" % [got.count(true), locks.size(), paths.size()])


## sound_bank.gd's DECODES_AT_ONCE, read so this file still compiles against a sound_bank.gd without it
## (the old one, which deadlocks here).
func _cap() -> int:
	return int((SoundBank as Script).get_script_constant_map().get("DECODES_AT_ONCE", 4))


## A model pack (a folder), a mod's zip and an add-on's folder in this run's own user folder.
func _fixtures() -> void:
	_root = ProjectSettings.globalize_path("user://sound-decode")
	var long := Tones.bytes(Tones.LONG)
	_write(_root.path_join("models/Decode pack/sounds/" + PACK_SOUND), long)
	_write(_root.path_join("models/Decode pack/sounds/" + PACK_OPUS), Tones.bytes(Tones.OPUS))
	_write(_root.path_join("addon/sounds/boing.ogg"), long)
	var zip := ZIPPacker.new()
	DirAccess.make_dir_recursive_absolute(_root.path_join("mods"))
	zip.open(_root.path_join("mods/%s_1.0.0.zip" % MOD))
	var files := {"top/info.json": ('{"name": "%s", "version": "1.0.0"}' % MOD).to_utf8_buffer(),
		"top/sound/step-1.ogg": long, "top/sound/step-2.ogg": long, "top/sound/rustle.ogg": long, "top/sound/boom.ogg": long}
	for name: String in files:
		zip.start_file(name)
		zip.write_file(files[name])
		zip.close_file()
	zip.close()
	ModFiles.extra_dirs = [_root.path_join("mods")]
	ModFiles.set_mods({MOD: "1.0.0", "base": "2.1.0"})
	var until := Time.get_ticks_msec() + 5000
	while not ModFiles.is_ready() and Time.get_ticks_msec() < until:
		OS.delay_msec(2)
	ModelPacks.configure(_root.path_join("models"), [], [])
	ModelPacks.wait()
	_check(SoundBank.locate(PACK_SOUND).get("from") == "pack" and SoundBank.locate(MOD + "/sound/step-1.ogg").get("from") == "mod",
		"the fixtures found: the pack's sound %s, the mod's %s" % [SoundBank.locate(PACK_SOUND), SoundBank.locate(MOD + "/sound/step-1.ogg")])


## Asked on the main thread with the locks held, as each way asks in the game.
func _ask_new_ways() -> void:
	# api.sound first (registering an add-on's file drops the decodes under way, sound_bank.gd
	# _drop_addon_entries, to be asked again): an add-on's own file (registered as "addon:<id>/...")
	# and a mod's, as preload_sounds() and play() ask.
	var api := AddonSound.new(null, {"id": ADDON_ID, "dir": _root.path_join("addon")})
	api.preload_sounds(["sounds/boing", "__%s__/sound/boom.ogg" % MOD])
	_paths["addon:%s/sounds/boing.ogg" % ADDON_ID] = "api.sound, the add-on's own file"
	_paths["__%s__/sound/boom.ogg" % MOD] = "api.sound, a mod's file"
	for path in [PACK_SOUND, PACK_OPUS]:
		_check(SoundBank.stream_soon(path) == null, "a pack's sound's first ask is null: " + path)
		_paths[path] = "a model pack"
	# Steps and plants' rustle as the bridge's `steps` list gives them (step_sounds.gd), played through
	# sfx.gd play_def -> SoundBank.stream_soon.
	var steps := StepSounds.new()
	steps.handle({"t": "steps", "s": [[MOD + "/sound/step", 100, 2], [MOD + "/sound/rustle", 80, 1]], "tl": [[7, 1]], "dl": [[3, 2]]})
	for which: Array in [[steps.tiles, 7, "a step"], [steps.decoratives, 3, "a plant's rustle"]]:
		var d: Variant = steps.lookup(which[0], int(which[1]))
		_check(d is SoundBank.SoundDef, "%s's sound listed and found" % which[2])
		if d is SoundBank.SoundDef:
			for f in (d as SoundBank.SoundDef).files:
				SoundBank.stream_soon(f)
				_paths[f] = which[2]
	_check(_paths.size() == 7, "seven sounds asked the new ways: %s" % [_paths.keys()])


## Each new way's sound decoded on a worker: the tone (0.25 s), the Opus file null and warned about.
func _check_new_ways() -> void:
	var script: Script = SoundBank
	for path: String in _paths:
		var s := SoundBank.stream_soon(path)
		if path == PACK_OPUS:
			_check(s == null and (script.get("_warned") as Dictionary).has(_root.path_join("models/Decode pack/sounds/" + PACK_OPUS)),
				"an Opus file in a pack: not played, warned about on the main thread")
		else:
			_check(s != null and s.get_length() > 0.2, "%s decoded on a worker: %s (%s)" % [_paths[path], path, s])


static func _write(path: String, bytes: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


## Decodes with a task (running, or done and not taken in yet): never more than the cap.
func _running_now() -> int:
	var script: Script = SoundBank
	var n := 0
	for job: Array in (script.get("_decoding") as Dictionary).values():
		if not job.is_empty():
			n += 1
	_most_running = maxi(_most_running, n)
	return n


func _queued_now() -> int:
	var script: Script = SoundBank
	return (script.get("_queued") as Array).size()


func _pending() -> int:
	var script: Script = SoundBank
	return (script.get("_decoding") as Dictionary).size()


func _process(_delta: float) -> bool:
	_running_now()
	if _pending() > 0 and Time.get_ticks_msec() < _until:
		SoundBank.stream_soon(_keys[0])  # the main thread takes finished decodes in when asked
		_running_now()
		return false
	if _phase == 0:
		_first_done()
		_check_new_ways()
		_queued_ask()
		_phase = 1
		return false
	_check(_pending() == 0, "all 40 asks finished and taken in")
	var script: Script = SoundBank
	var streams: Dictionary = script.get("_streams")
	var decoded := 0
	for path in _keys:
		if streams.has("%s|0" % path):
			decoded += 1
	_check(decoded == _keys.size(), "every one of the %d asks decoded (%d were)" % [_keys.size(), decoded])
	var real := 0
	for path in _keys:
		if not path.contains("zenith-test-missing") and streams.get("%s|0" % path) != null:
			real += 1
	print("40 asks (%d real Factorio sounds) decoded, at most %d at once: %d ms" % [real, _most_running, Time.get_ticks_msec() - _t0])
	_check(_most_running <= _cap(), "never more than %d decodes at once (saw %d)" % [_cap(), _most_running])
	_check(_running_now() == 0 and _queued_now() == 0, "nothing left running or queued")
	SoundBank.clear_cache()
	_unlock_probe()
	SoundBank.clear_cache()
	SoundBank.forget_files("addon:%s/" % ADDON_ID)
	ModFiles.close_all()
	ModFiles.extra_dirs = []
	TestEnv.clean()
	_done = true
	_watch.wait_to_finish()
	print("SOUND DECODE FAILS: ", _fails)
	quit(1 if _fails > 0 else 0)
	return true


## stream() on an ask still in the queue, then clear_cache() with decodes queued and running, then
## 40 asks (real sounds when the install is there, as at a join) left to finish.
func _queued_ask() -> void:
	SoundBank.clear_cache()
	# 40 asks to finish later: real sounds (footsteps, then machines) when the install is there, as at a join.
	_keys.clear()
	var dir := SoundBank.data_dir()
	for sub in ["base/sound/walking", "base/sound"]:
		if dir == "" or not DirAccess.dir_exists_absolute(dir.path_join(sub)):
			continue
		for f in DirAccess.get_files_at(dir.path_join(sub)):
			if f.ends_with(".ogg") and _keys.size() < 40:
				_keys.append(sub.path_join(f))
	var asks: Array[String] = []
	for i in 40:
		asks.append("base/sound/zenith-test-queued-%d.ogg" % i)
	# The running ones real sounds (the install's, else the test's own Vorbis fixtures), so the
	# queued ask stays queued until stream() pulls it and clear_cache() has a decode to wait for.
	var busy_sounds: Array[String] = []
	if not _keys.is_empty():
		for i in mini(_keys.size(), _cap()):
			busy_sounds.append(_keys[_keys.size() - 1 - i])
	else:
		busy_sounds = [PACK_SOUND, MOD + "/sound/step-1.ogg", MOD + "/sound/step-2.ogg", MOD + "/sound/rustle.ogg"]
	for i in mini(busy_sounds.size(), _cap()):
		asks[i] = busy_sounds[i]
	var queued_key := REAL if SoundBank.exists(REAL) else asks[asks.size() - 1]
	asks[asks.size() - 1] = queued_key
	for path in asks:
		SoundBank.stream_soon(path)
	var script: Script = SoundBank
	var done := (script.get("_streams") as Dictionary).size()  # finished meanwhile, taken in at the next ask
	_check(_pending() + done == 40 and _running_now() == _cap() and _queued_now() == 40 - _cap() - done,
		"40 asks: %d running, the rest queued (%d pending, %d running, %d queued, %d done)" % [_cap(), _pending(), _running_now(), _queued_now(), done])
	var queued_before := _queued_now()
	var s := SoundBank.stream(queued_key)
	if SoundBank.exists(REAL):
		_check(s != null, "stream() on a queued real sound decodes it on the spot")
	var key := "%s|0" % queued_key
	_check(not (script.get("_decoding") as Dictionary).has(key) and (script.get("_streams") as Dictionary).has(key),
		"stream() on a queued ask: cached, no longer pending")
	var still_queued := false
	for ask: Array in script.get("_queued"):
		if str(ask[0]) == key:
			still_queued = true
	_check(not still_queued and _queued_now() <= queued_before - 1, "stream() on a queued ask drops it from the queue")
	_check(SoundBank.stream_soon(queued_key) == s, "and stream_soon() then hands out the same stream")
	var t := Time.get_ticks_msec()
	var running := _running_now()
	var queued := _queued_now()
	SoundBank.clear_cache()
	print("clear_cache() with %d decodes running and %d queued: %d ms" % [running, queued, Time.get_ticks_msec() - t])
	_check(_pending() == 0 and _queued_now() == 0 and (script.get("_streams") as Dictionary).is_empty() and (script.get("_running") as Array).is_empty(),
		"clear_cache() with decodes queued and running leaves nothing behind")
	var pad := 0
	while _keys.size() < 40:
		_keys.append("base/sound/zenith-test-missing-many-%d.ogg" % pad)
		pad += 1
	_most_running = 0
	_t0 = Time.get_ticks_msec()
	for path in _keys:
		SoundBank.stream_soon(path)
	_running_now()
	_until = Time.get_ticks_msec() + LIMIT_MSEC


func _first_done() -> void:
	var pending = (SoundBank as Script).get("_decoding")
	_check(pending is Dictionary and (pending as Dictionary).is_empty(), "every decode finished and taken in")
	var missing_null := true
	for path in _keys:
		if path != REAL and SoundBank.stream_soon(path) != null:
			missing_null = false
	_check(missing_null, "a missing file's decode is cached as null (not asked for again)")
	if SoundBank.exists(REAL):
		var s := SoundBank.stream_soon(REAL)
		_check(s != null and SoundBank.stream(REAL) == s, "the real sound decoded on the worker is the one stream() hands out")
	_check(_most_running <= _cap(), "never more than %d decodes at once (saw %d)" % [_cap(), _most_running])


func _watchdog() -> void:
	var end := Time.get_ticks_msec() + LIMIT_MSEC * 2
	while not _done:
		if Time.get_ticks_msec() > end:
			print("FAIL: deadlocked: the main thread never got its low-priority task back (the pool's workers stuck on a lock it holds)")
			print("SOUND DECODE FAILS: ", _fails + 1)
			OS.crash("sound decode deadlock")
		OS.delay_msec(100)
