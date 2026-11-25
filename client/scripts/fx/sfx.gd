extends Node3D
## Plays Factorio's sounds by Factorio's rules (read from its prototypes by sound_bank.gd):
## positional one-shots (steps, shots, explosions, building) and the working loops of machines and
## vehicles near the listener, the windows' clicks, and, through ambience.gd, each planet's
## ambience and music.
##
## What it does as Factorio does:
## - each sound's own volume, a random variation (not the same one twice running) and pitch range;
## - distance: a sound fades out over the audible distance (AUDIBLE_DISTANCE tiles times its
##   `audible_distance_modifier`) along its attenuation curve, heard from the middle of the view,
##   and quieter the further the camera is zoomed out;
## - `aggregation`: at most `max_count` of one sound start at once (counting those still playing when
##   `count_already_playing`), the rest dropped (`remove`) or made quieter;
## - working loops: at most `max_sounds_per_prototype` machines of a kind heard at once (nearest and
##   loudest), faded in and out over the prototype's `fade_in_ticks`/`fade_out_ticks`, the idle
##   sound for idle machines;
## - a limit on sounds at once per category (CATEGORY_LIMITS), where a sound of higher `priority`
##   or a louder one takes the place of the weakest;
## - and, so a big base never clips, a limiter on the master output.
## The audible distance, the default curve and the category limits are the engine's, not in the
## data: the values here are chosen to sound like it.
##
## The UI calls the static helper: `Sfx.play_ui("gui-click")` (core/sound/<name>.ogg), with
## `const Sfx := preload("res://scripts/fx/sfx.gd")`. Without an instance or an install it does
## nothing.
##
## `--sfx-log` prints every sound started and, every 5 s, how many voices are busy, the loudest
## peaks, and sounds started over the same file.
##
## Kinds (API 1.7, addon_sound.gd): the character's steps, swings, shots, the windows' clicks, building,
## rotating, picking up and explosions are played with a kind ("step/grass", "shot/pistol"), which
## add-ons may replace or mute. Each kind keeps a stack: the last add-on to replace it wins, and when it
## stops the one before comes back. `--addon-sounds=off` ignores every replace and mute.

const SoundBank := preload("res://scripts/fx/sound_bank.gd")
const FxSettings := preload("res://scripts/fx/fx_settings.gd")
const Ambience := preload("res://scripts/fx/ambience.gd")
const Switches := preload("res://scripts/switches.gd")

const ONE_SHOT_VOICES := 24
const UI_VOICES := 4
const MAX_ADDON_LOOPS := 16
## One-shots playing at once per category (bus). Machine and vehicle loops have their own voices
## (Settings: max_voices).
const CATEGORY_LIMITS := {"Effects": 10, "Walking": 3, "Weapons": 6, "Explosions": 6, "Enemies": 6, "Environment": 6}
## The same with `--combat-sound-limit` on (the default): Factorio limits each sound by its own aggregation,
## not a few voices for a whole fight, so combat has room (the roar a crowd made is held back per sound
## by COMBAT_AGGREGATION instead).
const COMBAT_LIMITS := {"Effects": 10, "Walking": 3, "Weapons": 12, "Explosions": 10, "Enemies": 10, "Environment": 6}
## Combat sounds whose prototype has no `aggregation`: at most this many of one file in COMBAT_WINDOW_MSEC,
## each extra one quieter (volume_reduction_rate 1, as Factorio's own gun sounds do), none past
## COMBAT_HARD_MAX.
const COMBAT_BUSES := ["Weapons", "Explosions", "Enemies"]
const COMBAT_FREE := 3
const COMBAT_HARD_MAX := 8
const COMBAT_WINDOW_MSEC := 60
## The voice pool (`--sound-pool`, on by default; `--sound-pool=old` is the 24 voices above with
## CATEGORY_LIMITS/COMBAT_LIMITS). Before it, one-shots had 24 voices for limits that add up to 51 and
## machines and vehicles 12, so whichever sounds started first held the voices: the busy-scene probe
## (tests/sound_pool_test.gd) lost most near gunshots, steps and explosions for want of a voice.
## Now POOL_VOICES one-shot voices, each category guaranteed its POOL_BUDGETS share (they add up to the
## pool) and free to use idle voices beyond it. With every voice busy:
## - the player's own sounds (own steps, own gun; `own` in play_at/play_def) take the voice heard least
##   of everything but other own sounds, so they always play;
## - a category under its share takes the voice heard least of a category over its share;
## - a category at its share takes its own voice heard least, if the new sound outranks it (Factorio's
##   `priority` first, then loudness at the listener, where a playing sound's loudness falls as it plays out).
## A file still decoding (its first ask) plays another decoded variation of the same sound, or waits
## up to PENDING_MSEC for its decode. No per-file thinning silences a sound: combat sounds without an
## aggregation of their own are only made quieter, and the 40 ms repeat check drops only a true double
## (the same file at the same spot).
const POOL_VOICES := 96
const POOL_BUDGETS := {"Walking": 8, "Effects": 20, "Weapons": 28, "Explosions": 14, "Enemies": 14, "Environment": 12}
## Machine and vehicle loops' voices with the pool: Settings' "Machine sounds at once" (max_voices), at least.
const POOL_MIN_LOOPS := 8
## How long a sound waits for its file's decode before it is given up, and how many may wait.
const PENDING_MSEC := 300
const PENDING_MAX := 48
## Same file within REPEAT_MSEC closer than this (tiles) is a double with the pool on.
const REPEAT_SPOT := 1.0
## Categories where a new sound takes the oldest one's voice when they're all busy (I21: a step
## that came out quieter than the two still ringing was dropped, so running went quiet in patches).
const NEWEST_WINS := ["Walking"]
## Working loops of one prototype heard at once when its prototype doesn't say.
const DEFAULT_PER_PROTOTYPE := 4
## Tiles over which a sound with audible_distance_modifier 1 fades to nothing.
const AUDIBLE_DISTANCE := 40.0
## The camera distance (camera_rig.gd) of the default view: zooming out from it moves the
## listener up, away from everything, as zooming out quietens Factorio.
const DEFAULT_CAMERA_DISTANCE := 30.0
const LISTENER_HEIGHT := 3.0
## Same file again within this time is skipped when its definition has no aggregation (twenty
## biters dying in one tick).
const REPEAT_MSEC := 40
## A playing source keeps its voice unless another is this much louder, so voices don't hop
## between machines of about the same loudness.
const KEEP_BONUS := 1.4

static var instance = null  # the Sfx node, untyped so its own methods can be called

## The kinds an add-on can replace or mute (each also with a detail: "step/grass").
const KINDS := ["step", "rustle", "mine", "mined", "repair", "shot", "ui", "build", "rotate", "pickup", "explosion"]
## Add-ons' replaces and mutes: kind ("step" or "step/grass") -> its stack, the top last:
## {by (add-on id), mute, files (sound paths), volume (-1: the replaced sound's own)}.
static var kind_stack := {}
## Every add-on's api.sound (addon_sound.gd), and those whose `played` signal has a connection
## (refreshed each frame: a signal can't tell when it is connected).
static var listeners: Array = []
static var _hearing: Array = []
## Kinds are looked at at all: the one check a sound with a kind costs while no add-on uses them.
static var _kinds_on := false
## --addon-sounds=off: add-ons' replace() and mute() are ignored.
static var addon_sounds := Switches.on("--addon-sounds")
## --combat-sound-limit=old: the old category limits, no default combat aggregation (and fx.gd's old
## death and idle sounds).
static var combat_limits := not Switches.has("--combat-sound-limit=old")
## --sound-pool=old: the sound system's voices as before the pool (POOL_VOICES above).
static var pool := not Switches.has("--sound-pool=old")
## What became of each one-shot asked for, by bus: {bus: {asked, played, far, repeat, agg, thin, quieter,
## undecoded, waited, novoice, stolen, near, near_<what>}} ("near": heard at half volume or more;
## near_agg, near_novoice... what became of those), and of the working loops under "Loops" (asked:
## sources in hearing each scan, played: holding a voice, novoice: chosen but no voice, cut: over its
## prototype's max_sounds_per_prototype). Read by tests/sound_pool_test.gd and combat_sound_test.gd;
## cleared with reset_counts().
static var counts := {}


class LoopVoice:
	var player: AudioStreamPlayer3D
	var key = null  # whatever the caller identifies the source by; null when free
	var path := ""
	var group := ""
	var gain := 0.0  # the fade, 0 to 1
	var volume := 1.0
	var reach := 1.0
	var curve := ""
	var fade_in := 0.13
	var fade_out := 0.33
	var wanted := false


class Shot:
	var player: AudioStreamPlayer3D
	var path := ""
	var key := ""  # the sound definition, for aggregation
	var bus := "Effects"
	var priority := 127
	var volume := 1.0  # before distance
	var reach := 1.0
	var curve := ""
	var started := 0
	var length := 1.0
	var own := false  # the player's own (own steps, own gun): never taken by others


class AddonLoop:
	var id := 0
	var owner := ""
	var path := ""
	var given: AudioStream = null
	var bus := "Effects"
	var positional := false
	var pos := Vector3.ZERO
	var volume := 1.0
	var target_volume := 1.0
	var pitch := 1.0
	var reach := 1.0
	var fade_in := 0.35
	var fade_out := 0.35
	var gain := 0.0
	var stopping := false
	var started := false
	var player: Node = null


var listener := AudioListener3D.new()
var ambience := Ambience.new()
var _loops: Array = []  # LoopVoice
var _shots: Array = []  # Shot
var _ui: Array = []  # AudioStreamPlayer
var _ui_next := 0
var _addon_loops: Dictionary = {}  # id -> AddonLoop
var _next_addon_loop := 1
var _zoom_height := 0.0
var _last_played := {}  # path -> msec
var _last_spot := {}  # path -> where it last played (the pool's repeat check)
var _agg_victim: Shot = null  # _aggregate's: the voice a nearer sound of the same kind takes
var _pending: Array = []  # [msec, path, def, pos, volume, speed, bus, own]: waiting for a decode
var _log_timer := 0.0
var _counts := {}  # what played since the last log line, by path
## --sfx-log measurements over each 5 s: the most voices at once, the loudest peaks (dB) on the
## Effects bus and the master output, sounds started while the same file was already playing, and
## the most voices playing one file at once.
var _stat_voices := 0
var _stat_peak_fx := -200.0
var _stat_peak_master := -200.0
var _stat_peak_env := -200.0
var _stat_peak_amb := -200.0
var _stat_dups := 0
var _stat_same := 0
var _stat_dropped := 0


## A click or other window sound: "gui-click", "gui-tab", "inventory-move"... (Factorio's
## core/sound names), or a full path relative to Factorio's data folder. Its kind is "ui/<name>"
## unless given.
static func play_ui(sound: String, volume := 1.0, kind := "") -> void:
	if instance != null and is_instance_valid(instance):
		var path := sound if sound.ends_with(".ogg") else "core/sound/%s.ogg" % sound
		instance.play_flat(path, volume, kind if kind != "" else "ui/" + path.get_file().get_basename())


## An add-on's replace (`files` non-empty) or mute (`files` empty) of `kind`, on top of its stack.
## An add-on's earlier one for the same kind is taken out first.
static func push_kind(kind: String, by: String, files: PackedStringArray, volume := -1.0) -> void:
	var stack: Array = kind_stack.get(kind, [])
	stack = stack.filter(func(e: Dictionary) -> bool: return e["by"] != by)
	stack.append({"by": by, "mute": files.is_empty(), "files": files, "volume": volume})
	kind_stack[kind] = stack
	_update_kinds_on()


## Takes add-on `by`'s replaces and mutes out: of `kind`, or of every kind ("").
static func pop_kinds(by: String, kind := "") -> void:
	for k: String in kind_stack.keys():
		if kind != "" and k != kind:
			continue
		var stack: Array = kind_stack[k].filter(func(e: Dictionary) -> bool: return e["by"] != by)
		if stack.is_empty():
			kind_stack.erase(k)
		else:
			kind_stack[k] = stack
	_update_kinds_on()


## The entry that decides `kind` now: the top of its own stack, else of its base kind's; {} for none.
static func kind_entry(kind: String) -> Dictionary:
	var stack: Array = kind_stack.get(kind, [])
	if stack.is_empty() and "/" in kind:
		stack = kind_stack.get(kind.get_slice("/", 0), [])
	return stack.back() if not stack.is_empty() else {}


## The add-on API's key for one of Zenith's buses ("Walking" -> "walking"), as api.sound's `bus` option
## and volume() take it; "effects" for one not in FxSettings.BUSES.
static func bus_key(bus: String) -> String:
	for key: String in FxSettings.BUSES:
		if FxSettings.BUSES[key][0] == bus:
			return key
	return "effects"


## Which listeners' `played` has a connection now.
static func refresh_hearing() -> void:
	var hearing: Array = []
	for l in listeners:
		if l.played.has_connections():
			hearing.append(l)
	if hearing != _hearing:
		_hearing = hearing
		_update_kinds_on()


static func _update_kinds_on() -> void:
	_kinds_on = not kind_stack.is_empty() or not _hearing.is_empty()


func _ready() -> void:
	instance = self
	FxSettings.load_settings()
	SoundBank.prepare()
	add_child(listener)
	listener.make_current()
	for i in maxi(FxSettings.max_voices, POOL_MIN_LOOPS) if pool else (FxSettings.max_voices if FxSettings.voices_chosen() else 12):
		var v := LoopVoice.new()
		v.player = _player_3d()
		v.player.bus = "Environment"  # Factorio: machines and vehicles
		_loops.append(v)
	for i in POOL_VOICES if pool else ONE_SHOT_VOICES:
		var s := Shot.new()
		s.player = _player_3d()
		_shots.append(s)
	for i in UI_VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = "UI"
		add_child(p)
		_ui.append(p)
	ambience.name = "Ambience"
	add_child(ambience)
	if FxSettings.log_sounds:
		print("sfx: Factorio sounds %s, %d loop voices, volumes %s" % [
			"from " + SoundBank.data_dir() if SoundBank.available() else "not found (silent)", _loops.size(), FxSettings.volumes])


func _exit_tree() -> void:
	if instance == self:
		instance = null
	# Playbacks still running at quit would be reported as leaked.
	stop_all()
	for v: LoopVoice in _loops:
		v.player.stream = null
	for s: Shot in _shots:
		s.player.stream = null
	for p: AudioStreamPlayer in _ui:
		p.stream = null


func _player_3d() -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.bus = "Effects"
	# The distance fade is Factorio's (distance_gain), not Godot's.
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
	p.max_distance = 0.0
	p.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
	add_child(p)
	return p


## Hears from above the point the camera looks at, turned like the camera, so sounds pan with
## the view. Factorio hears from the middle of the screen. `camera_distance` (camera_rig.gd's) zooms.
func set_listener(focus: Vector2, camera: Camera3D, camera_distance := DEFAULT_CAMERA_DISTANCE) -> void:
	var basis := Basis.IDENTITY
	if camera != null:
		var forward := -camera.global_transform.basis.z
		forward.y = 0.0
		if forward.length() > 0.01:
			basis = Basis.looking_at(forward.normalized(), Vector3.UP)
	listener.global_transform = Transform3D(basis, Vector3(focus.x, LISTENER_HEIGHT, focus.y))
	_zoom_height = maxf(0.0, camera_distance - DEFAULT_CAMERA_DISTANCE) * 0.5
	ambience.zoom = 54.0 / maxf(camera_distance, 1.0)


func listener_position() -> Vector3:
	# Out of the tree (a test's effects, or while the scene closes) a global position is an error.
	return listener.global_position if listener.is_inside_tree() else listener.position


## How loud a sound at `pos` is heard, 0 to 1: Factorio's fade over the audible distance.
func distance_gain(pos: Vector3, reach := 1.0, curve := "") -> float:
	var here := listener_position()
	var flat := Vector2(pos.x - here.x, pos.z - here.z).length()
	var d := sqrt(flat * flat + _zoom_height * _zoom_height)
	var x := d / (AUDIBLE_DISTANCE * maxf(reach, 0.05))
	if x >= 1.0:
		return 0.0
	match curve:
		"none":
			return 1.0
		"exponential":
			return pow(1.0 - x, 3.0)
		"logarithmic":
			return 1.0 - log(1.0 + 9.0 * x) / log(10.0)
		"cosine":
			return 0.5 + 0.5 * cos(PI * x)
		"S-curve":
			return 1.0 - smoothstep(0.0, 1.0, x)
	return pow(1.0 - x, 1.5)


## A positional one-shot of a file. The file's definition in Factorio's prototypes, when found,
## decides its volume, variations' pitch, reach, aggregation and priority; `volume`,
## `pitch_spread` and `reach` are used for files it doesn't define. `bus` is the sound settings
## category (fx_settings.gd BUSES). `kind` ("step/grass") lets add-ons replace or mute it. Quietly
## does nothing for "" or a missing file. `own`: the player's own sound (own steps, own gun), which
## the voice pool always plays.
func play_at(path: String, pos: Vector3, volume := 1.0, pitch_spread := 0.0, reach := 1.0, bus := "Effects", kind := "", own := false) -> void:
	if path == "" or volume <= 0.0:
		return
	var def := SoundBank.sound_for_file(path)
	if def != null:
		var i := def.files.find(path)
		volume = def.volume_of(i) if i >= 0 else volume
	else:
		def = _plain(path, volume, pitch_spread, reach)
	if kind != "" and _kinds_on:
		_play_kind(kind, path, def, pos, volume, bus, own)
	else:
		_play(path, def, pos, volume, def.speed(), bus, null, own)


func _plain(path: String, volume: float, pitch_spread: float, reach: float) -> SoundBank.SoundDef:
	var plain := SoundBank.SoundDef.single(path, volume)
	plain.reach = reach
	plain.min_speed = 1.0 - pitch_spread
	plain.max_speed = 1.0 + pitch_spread
	return plain


## A sound of `kind`: Zenith's own (`path`), or the add-on's that replaced it, or nothing when muted;
## then the add-ons listening hear of it. `pos` null: not positional (the windows').
func _play_kind(kind: String, path: String, def: SoundBank.SoundDef, pos: Variant, volume: float, bus: String, own := false) -> void:
	var e := kind_entry(kind)
	var by := ""
	if not e.is_empty():
		by = str(e["by"])
		if e["mute"]:
			if FxSettings.log_sounds:
				print("sfx: %s muted by %s" % [kind, by])
			return
		var file := _ready_file(e["files"], pos == null)
		if file == "":
			return  # still decoding: it plays next time, as Zenith's own first sounds
		if FxSettings.log_sounds:
			print("sfx: %s replaced by %s" % [kind, by])
		if float(e["volume"]) >= 0.0:
			volume = float(e["volume"])
		var mine := SoundBank.SoundDef.single(file, volume)
		if def != null:
			mine.reach = def.reach
			mine.attenuation = def.attenuation
			mine.priority = def.priority
			mine.min_speed = def.min_speed
			mine.max_speed = def.max_speed
		path = file
		def = mine
	var ok := _flat(path, volume, bus) if pos == null else _play(path, def, pos, volume, def.speed(), bus, null, own)
	if ok and not _hearing.is_empty():
		var info := {"at": pos, "path": path, "by": by, "bus": bus_key(bus)}
		for l in _hearing:
			l.played.emit(kind, info)


## One of `files` that can be played now: decoded (`now`: decoded on the spot, for the windows'), the
## others started; "" while none is.
func _ready_file(files: PackedStringArray, now: bool) -> String:
	if now:
		return files[randi() % files.size()] if files.size() > 0 else ""
	var ready := PackedStringArray()
	for f in files:
		if SoundBank.stream_soon(f) != null:
			ready.append(f)
	return ready[randi() % ready.size()] if ready.size() > 0 else ""


## An add-on's own one-shot (api.sound.play): a file's path, or a stream it made. `pos` null: not
## positional. False when it didn't play: not decoded yet, out of hearing, or no voice free. A bus the
## player muted still plays it, silently, as Zenith's own.
func play_addon(sound: Variant, pos: Variant, volume: float, pitch_spread: float, reach: float, bus: String) -> bool:
	var path := str(sound) if sound is String else "(stream)"
	var given: AudioStream = sound if sound is AudioStream else null
	if volume <= 0.0 or (given == null and path == ""):
		return false
	if pos == null:
		return _flat(path, volume, bus, given)
	var def := SoundBank.sound_for_file(path) if given == null else null
	if def == null:
		def = _plain(path, volume, pitch_spread, reach)
	return _play(path, def, pos, volume, def.speed(), bus, given)


## An add-on's looping sound (api.sound.loop, API 1.8): starts decoding if needed and fades in once
## ready. Returns its positive handle, or 0 when full/invalid.
func start_addon_loop(owner: String, sound: Variant, pos: Variant, volume: float, pitch: float, reach: float, bus: String, fade_in: float) -> int:
	if _addon_loops.size() >= MAX_ADDON_LOOPS or owner == "":
		return 0
	var given: AudioStream = sound if sound is AudioStream else null
	var path := str(sound) if sound is String else "(stream)"
	if given == null and path == "":
		return 0
	if given is AudioStreamOggVorbis:
		(given as AudioStreamOggVorbis).loop = true
	var l := AddonLoop.new()
	l.id = _next_addon_loop
	_next_addon_loop += 1
	l.owner = owner
	l.path = path
	l.given = given
	l.bus = bus
	l.volume = clampf(volume, 0.0, 1.0)
	l.target_volume = l.volume
	l.pitch = clampf(pitch, 0.25, 4.0)
	l.reach = maxf(reach, 0.05)
	l.fade_in = maxf(fade_in, 0.02)
	if pos is Vector3:
		var p3 := _player_3d()
		p3.bus = bus
		p3.pitch_scale = l.pitch
		p3.volume_db = -80.0
		p3.global_position = pos
		l.positional = true
		l.pos = pos
		l.player = p3
	else:
		var p2 := AudioStreamPlayer.new()
		p2.bus = bus
		p2.pitch_scale = l.pitch
		p2.volume_db = -80.0
		add_child(p2)
		l.player = p2
	var stream := given if given != null else SoundBank.stream_soon(path, true)
	if stream != null:
		l.player.set("stream", stream)
		if given != null:
			l.player.call("play")
		else:
			l.player.call("play", randf() * maxf(0.0, stream.get_length() - 0.1))
		l.started = true
	_addon_loops[l.id] = l
	return l.id


func update_addon_loop(owner: String, id: int, options: Dictionary) -> bool:
	if not _addon_loops.has(id):
		return false
	var l: AddonLoop = _addon_loops[id]
	if l.owner != owner or l.stopping:
		return false
	if options.has("volume"):
		l.target_volume = clampf(float(options["volume"]), 0.0, 1.0)
	if options.has("pitch"):
		l.pitch = clampf(float(options["pitch"]), 0.25, 4.0)
	if options.has("reach"):
		l.reach = maxf(float(options["reach"]), 0.05)
	if l.positional and options.get("at") is Vector3:
		l.pos = options["at"]
		if l.player is AudioStreamPlayer3D:
			(l.player as AudioStreamPlayer3D).global_position = l.pos
	return true


func stop_addon_loop(owner: String, id: int, fade_out := 0.35) -> bool:
	if not _addon_loops.has(id):
		return false
	var l: AddonLoop = _addon_loops[id]
	if l.owner != owner:
		return false
	if fade_out <= 0.01:
		_free_addon_loop(l)
		_addon_loops.erase(id)
	else:
		l.stopping = true
		l.fade_out = maxf(fade_out, 0.02)
	return true


func stop_addon_loops(owner: String) -> void:
	for id in _addon_loops.keys():
		var l: AddonLoop = _addon_loops[id]
		if l.owner == owner:
			_free_addon_loop(l)
			_addon_loops.erase(id)


func addon_loop_count(owner := "") -> int:
	var n := 0
	for id in _addon_loops:
		var l: AddonLoop = _addon_loops[id]
		if not l.stopping and (owner == "" or l.owner == owner):
			n += 1
	return n


func _free_addon_loop(l: AddonLoop) -> void:
	if l.player != null and is_instance_valid(l.player):
		l.player.call("stop")
		l.player.set("stream", null)
		l.player.queue_free()
	l.player = null


## A positional one-shot of a whole definition: a random variation of it. `kind` and `own` as play_at's.
func play_def(def: SoundBank.SoundDef, pos: Vector3, bus := "Effects", scale := 1.0, kind := "", own := false) -> void:
	if def == null or def.files.is_empty():
		return
	var i := def.pick()
	if kind != "" and _kinds_on:
		_play_kind(kind, def.files[i], def, pos, def.volume_of(i) * scale, bus, own)
	else:
		_play(def.files[i], def, pos, def.volume_of(i) * scale, def.speed(), bus, null, own)


## True when it started. `given`: a stream to play instead of the file's (an add-on's own). `own` as
## play_at's. `waited`: a retry of a sound that waited for its decode (_pending).
func _play(path: String, def: SoundBank.SoundDef, pos: Vector3, volume: float, speed: float, bus: String, given: AudioStream = null, own := false, waited := false) -> bool:
	var gain := distance_gain(pos, def.reach, def.attenuation)
	var near := gain >= 0.5
	if not waited:
		_count(bus, "asked", near)
	if gain <= 0.0 or volume <= 0.0:
		_count(bus, "far", near)
		return false
	var now := Time.get_ticks_msec()
	if not waited and given == null and def.max_count <= 0 and not (combat_limits and bus in COMBAT_BUSES) and _repeat(path, pos, now):
		_stat_dropped += 1
		_count(bus, "repeat", near)
		return false
	_agg_victim = null
	var factor := _aggregate(def, now, volume * gain if pool and not own else -1.0)
	if factor <= 0.0:
		_count(bus, "agg", near)
	elif combat_limits and def.max_count <= 0 and given == null and bus in COMBAT_BUSES:
		factor = _combat_aggregate(path, now, def.key)
		if factor <= 0.0:
			_count(bus, "thin", near)
	if factor <= 0.0:
		_stat_dropped += 1
		return false
	if factor < 1.0:
		_count(bus, "quieter", false)
	volume *= factor
	var stream := given if given != null else SoundBank.stream_soon(path)
	if stream == null and given == null and pool and def.files.size() > 1:
		# The file asked for is still decoding (its first play): another variation of the same sound
		# that is ready plays instead, so a fight's first explosions and a walk's first steps aren't silent.
		var i0 := randi() % def.files.size()
		for k in def.files.size():
			var other: String = def.files[(i0 + k) % def.files.size()]
			stream = SoundBank.stream_soon(other)
			if stream != null:
				path = other
				break
	if stream == null:
		if pool and not waited and _pending.size() < PENDING_MAX:
			# None decoded yet: it waits for the decode the ask started (_process), as Factorio has it ready.
			_pending.append([now, path, def, pos, volume / factor, speed, bus, own])
			_count(bus, "waiting", near)
		else:
			_count(bus, "undecoded", near)
		return false
	var s: Shot = _agg_victim
	_agg_victim = null
	if s == null or s.own:
		s = _pool_voice(bus, def.priority, volume * gain, own, now) if pool else _shot_voice(bus, def.priority, volume * gain)
	if s == null:
		_stat_dropped += 1
		_count(bus, "novoice", near)
		return false
	if s.player.playing:
		_count(s.bus, "stolen", false)
	_count(bus, "played", false)
	if waited:
		_count(bus, "waited", false)
	_last_played[path] = now
	if pool:
		_last_spot[path] = pos
	if FxSettings.log_sounds and _playing_paths().has(path):
		_stat_dups += 1
	s.player.stop()
	s.player.stream = stream
	s.path = path
	s.key = def.key
	s.bus = bus
	s.priority = def.priority
	s.own = own
	s.volume = volume
	s.reach = def.reach
	s.curve = def.attenuation
	s.started = now
	s.length = maxf(stream.get_length(), 0.05) / maxf(speed, 0.05)
	s.player.global_position = pos
	s.player.volume_db = linear_to_db(maxf(volume * gain, 0.0001))
	s.player.pitch_scale = speed
	s.player.bus = bus
	s.player.play()
	_note(path, pos)
	return true


## The same file again within REPEAT_MSEC (twenty biters dying in one tick): a double to skip. With the
## pool only at the same spot, so two machines or two walkers using one file both play.
func _repeat(path: String, pos: Vector3, now: int) -> bool:
	if now - int(_last_played.get(path, -100000)) >= REPEAT_MSEC:
		return false
	if not pool:
		return true
	var at = _last_spot.get(path)
	return at is Vector3 and (at as Vector3).distance_to(pos) < REPEAT_SPOT


## Sounds that waited for their file's decode: played once it is ready, given up after PENDING_MSEC.
func _retry_pending() -> void:
	if _pending.is_empty():
		return
	var now := Time.get_ticks_msec()
	var keep: Array = []
	for p: Array in _pending:
		var path: String = p[1]
		if SoundBank.stream_soon(path) != null:
			_play(path, p[2], p[3], float(p[4]), float(p[5]), str(p[6]), null, bool(p[7]), true)
		elif now - int(p[0]) < PENDING_MSEC:
			keep.append(p)
		else:
			_count(str(p[6]), "undecoded", distance_gain(p[3], p[2].reach, p[2].attenuation) >= 0.5)
	_pending = keep


static func _count(bus: String, what: String, near: bool, n := 1) -> void:
	var c: Dictionary = counts.get(bus, {})
	if c.is_empty():
		counts[bus] = c
	c[what] = int(c.get(what, 0)) + n
	if near:
		var k := "near" if what == "asked" else "near_" + what
		c[k] = int(c.get(k, 0)) + n


static func reset_counts() -> void:
	counts.clear()


## Factorio's aggregation: the volume factor for one more of `def` now (0: don't play it).
## With the pool, `loudness` (>= 0: the new sound as heard) lets a nearer one take the place of the
## quietest counted one when `remove` would drop it (_agg_victim), so near beats far: ten turrets'
## shots kept the far ones' and dropped the near ones' only by which fired first.
func _aggregate(def: SoundBank.SoundDef, now: int, loudness := -1.0) -> float:
	if def.max_count <= 0:
		return 1.0
	var n := 0
	var quietest: Shot = null
	var quietest_now := 0.0
	for s: Shot in _shots:
		if s.key != def.key or not s.player.playing:
			continue
		if now - s.started <= 17 or (def.count_already_playing and (now - s.started) / 1000.0 / s.length < def.progress_threshold):
			n += 1  # started this tick, or still in its counted start
			if loudness >= 0.0 and not s.own:
				var heard := _heard_now(s, now)
				if quietest == null or heard < quietest_now:
					quietest = s
					quietest_now = heard
	if n < def.max_count:
		return 1.0
	if def.remove:
		if quietest != null and loudness > quietest_now * 1.25:
			_agg_victim = quietest
			return 1.0
		return 0.0
	return pow(n - def.max_count + 2.0, -def.volume_reduction_rate)


## Combat sounds without an aggregation of their own: how loud one more of `path` is now (0: skip it).
## With the pool (the default) counted over the whole sound (its definition, every variation) and
## never 0: the extra ones are only quieter, and the voice pool decides what is heard.
func _combat_aggregate(path: String, now: int, key := "") -> float:
	var n := 0
	for s: Shot in _shots:
		if (s.key == key if pool and key != "" else s.path == path) and s.player.playing and now - s.started <= COMBAT_WINDOW_MSEC:
			n += 1
	if n < COMBAT_FREE:
		return 1.0
	if n >= COMBAT_HARD_MAX and not pool:
		return 0.0
	return 1.0 / float(n - COMBAT_FREE + 2)


## A voice from the pool (POOL_VOICES) for a sound of `bus`, `priority` and `loudness` (as heard now),
## by the rules at POOL_BUDGETS; null when it doesn't get one.
func _pool_voice(bus: String, priority: int, loudness: float, own: bool, now: int) -> Shot:
	var budget: int = POOL_BUDGETS.get(bus, POOL_BUDGETS["Effects"])
	var used := {}
	var free: Shot = null
	for s: Shot in _shots:
		if s.player.playing:
			used[s.bus] = int(used.get(s.bus, 0)) + 1
		elif free == null:
			free = s
	if free != null:
		return free
	var in_bus := int(used.get(bus, 0))
	var weakest: Shot = null  # of all, but own sounds
	var weakest_now := 0.0
	var weakest_over: Shot = null  # of the categories over their share
	var weakest_over_now := 0.0
	var weakest_bus: Shot = null  # of this category
	var weakest_bus_now := 0.0
	for s: Shot in _shots:
		if s.own:
			continue
		var heard := _heard_now(s, now)
		if weakest == null or _gives_way(s, heard, weakest, weakest_now):
			weakest = s
			weakest_now = heard
		if s.bus == bus:
			if weakest_bus == null or _gives_way(s, heard, weakest_bus, weakest_bus_now):
				weakest_bus = s
				weakest_bus_now = heard
		elif int(used.get(s.bus, 0)) > int(POOL_BUDGETS.get(s.bus, POOL_BUDGETS["Effects"])):
			if weakest_over == null or _gives_way(s, heard, weakest_over, weakest_over_now):
				weakest_over = s
				weakest_over_now = heard
	if own:
		return weakest
	if in_bus < budget and weakest_over != null:
		return weakest_over
	if bus in NEWEST_WINS and weakest_bus != null and in_bus >= budget:
		return weakest_bus
	if weakest_bus == null:
		return null
	if priority < weakest_bus.priority or (priority == weakest_bus.priority and loudness > weakest_bus_now):
		return weakest_bus
	return null


## True when `a` (heard `a_now`) should give way before `b`: lower priority (higher number), else quieter.
static func _gives_way(a: Shot, a_now: float, b: Shot, b_now: float) -> bool:
	if a.priority != b.priority:
		return a.priority > b.priority
	return a_now < b_now


## How loud a playing one-shot is heard now: its loudness faded by how much of it has played (a shot's
## tail is quieter than its start; a stand-in for the file's own envelope).
func _heard_now(s: Shot, now: int) -> float:
	var progress := clampf((now - s.started) / 1000.0 / maxf(s.length, 0.05), 0.0, 1.0)
	return _heard(s) * (1.0 - progress)


## A voice for a one-shot in `bus`: a free one while the category has room, else the weakest
## of the category (or of all) if the new sound outranks it, else null.
func _shot_voice(bus: String, priority: int, loudness: float) -> Shot:
	var limit: int = (COMBAT_LIMITS if combat_limits else CATEGORY_LIMITS).get(bus, ONE_SHOT_VOICES)
	var in_bus := 0
	var oldest_bus: Shot = null
	var weakest_bus: Shot = null
	var weakest: Shot = null
	var free: Shot = null
	for s: Shot in _shots:
		if not s.player.playing:
			if free == null:
				free = s
			continue
		if s.bus == bus:
			in_bus += 1
			if oldest_bus == null or s.started < oldest_bus.started:
				oldest_bus = s
			if weakest_bus == null or _outranks(weakest_bus, s):
				weakest_bus = s
		if weakest == null or _outranks(weakest, s):
			weakest = s
	var victim: Shot = null
	if in_bus >= limit:
		if bus in NEWEST_WINS:
			return oldest_bus
		victim = weakest_bus
	elif free != null:
		return free
	else:
		victim = weakest
	if victim == null:
		return null
	if priority < victim.priority or (priority == victim.priority and loudness > _heard(victim)):
		return victim
	return null


## True when `b` should give way before `a`: lower priority (higher number), else quieter.
func _outranks(a: Shot, b: Shot) -> bool:
	if a.priority != b.priority:
		return a.priority < b.priority
	return _heard(a) > _heard(b)


func _heard(s: Shot) -> float:
	return s.volume * distance_gain(s.player.global_position, s.reach, s.curve)


## Not positional: the windows' sounds. `kind` ("ui/gui-click") lets add-ons replace or mute it.
func play_flat(path: String, volume := 1.0, kind := "") -> void:
	if kind != "" and _kinds_on:
		_play_kind(kind, path, null, null, volume, "UI")
	else:
		_flat(path, volume)


func _flat(path: String, volume: float, bus := "UI", given: AudioStream = null) -> bool:
	var stream := given if given != null else SoundBank.stream(path)
	if stream == null:
		return false
	var p: AudioStreamPlayer = _ui[_ui_next]
	_ui_next = (_ui_next + 1) % _ui.size()
	p.stream = stream
	p.bus = bus
	p.volume_db = linear_to_db(volume)
	p.play()
	_note(path, null)
	return true


## The working loops that should be playing now: one Dictionary per source in hearing range:
## {key, pos (Vector3), path, volume, reach, curve, group (the prototype), per_group (its
## max_sounds_per_prototype, 0: default), fade_in, fade_out (seconds), own (optional: the player's
## own vehicle)}. The loudest get the voices, at most per_group of each group; voices that lose their
## source fade out. With the pool the player's own come first, whatever plays louder.
func set_loops(sources: Array) -> void:
	var playing := {}
	for v: LoopVoice in _loops:
		if v.key != null and v.wanted:
			playing[v.key] = true
	var scored: Array = []
	for s: Dictionary in sources:
		var g := distance_gain(s["pos"], float(s.get("reach", 1.0)), str(s.get("curve", "")))
		if g <= 0.0:
			continue
		var loudness := float(s["volume"]) * g * (KEEP_BONUS if playing.has(s["key"]) else 1.0)
		if pool and bool(s.get("own", false)):
			loudness += 1000.0
		scored.append([loudness, s])
	scored.sort_custom(func(a, b): return a[0] > b[0])
	_count("Loops", "asked", false, scored.size())
	var chosen := {}
	var per_group := {}
	for entry in scored:
		if chosen.size() >= _loops.size():
			_count("Loops", "novoice", false)
			continue
		var s: Dictionary = entry[1]
		var group := str(s.get("group", s["path"]))
		var limit := int(s.get("per_group", 0))
		if limit <= 0:
			limit = DEFAULT_PER_PROTOTYPE
		var n: int = per_group.get(group, 0)
		if n >= limit and not (pool and bool(s.get("own", false))):
			_count("Loops", "cut", false)
			continue
		per_group[group] = n + 1
		chosen[s["key"]] = s
	for v: LoopVoice in _loops:
		v.wanted = v.key != null and chosen.has(v.key) and chosen[v.key]["path"] == v.path
		if v.wanted:
			var s: Dictionary = chosen[v.key]
			v.player.global_position = s["pos"]
			v.volume = float(s["volume"])
			chosen.erase(v.key)
	for key in chosen:
		var s: Dictionary = chosen[key]
		var voice := _free_voice()
		if voice == null:
			_count("Loops", "novoice", false)
			continue
		var stream := SoundBank.stream_soon(s["path"], true)
		if stream == null:
			_count("Loops", "undecoded", false)
			continue
		if FxSettings.log_sounds and _playing_paths().has(s["path"]):
			_stat_dups += 1
		voice.key = key
		voice.path = s["path"]
		voice.group = str(s.get("group", s["path"]))
		voice.volume = float(s["volume"])
		voice.reach = float(s.get("reach", 1.0))
		voice.curve = str(s.get("curve", ""))
		voice.fade_in = maxf(float(s.get("fade_in", 0.13)), 0.02)
		voice.fade_out = maxf(float(s.get("fade_out", 0.33)), 0.02)
		voice.wanted = true
		voice.gain = 0.0
		voice.player.stream = stream
		voice.player.global_position = s["pos"]
		voice.player.volume_db = -80.0
		# Start somewhere in the loop, so a row of machines doesn't play in unison.
		voice.player.play(randf() * maxf(0.0, stream.get_length() - 0.1))
		_note(voice.path + " (loop)", s["pos"])
	var held := 0
	for v: LoopVoice in _loops:
		if v.wanted:
			held += 1
	_count("Loops", "played", false, held)


func _free_voice() -> LoopVoice:
	var quietest: LoopVoice = null
	for v: LoopVoice in _loops:
		if v.key == null:
			return v
		if not v.wanted and (quietest == null or v.gain < quietest.gain):
			quietest = v
	if quietest != null:
		quietest.player.stop()
		quietest.key = null
	return quietest


func busy_loops() -> int:
	var n := 0
	for v: LoopVoice in _loops:
		if v.key != null:
			n += 1
	return n


func busy_shots() -> int:
	var n := 0
	for s: Shot in _shots:
		if s.player.playing:
			n += 1
	return n


func stop_all() -> void:
	for v: LoopVoice in _loops:
		v.player.stop()
		v.key = null
		v.gain = 0.0
	for s: Shot in _shots:
		s.player.stop()
	_pending.clear()
	for id in _addon_loops.keys():
		_free_addon_loop(_addon_loops[id])
	_addon_loops.clear()
	ambience.stop()


func _process(delta: float) -> void:
	if not listeners.is_empty():
		refresh_hearing()
	_retry_pending()
	for v: LoopVoice in _loops:
		if v.key == null:
			continue
		if v.wanted:
			v.gain = minf(1.0, v.gain + delta / v.fade_in)
		else:
			v.gain -= delta / v.fade_out
			if v.gain <= 0.0:
				v.player.stop()
				v.key = null
				continue
		var heard := v.gain * v.volume * distance_gain(v.player.global_position, v.reach, v.curve)
		v.player.volume_db = linear_to_db(maxf(heard, 0.0001))
	# One-shots follow the listener too (the view moves while an explosion rings out).
	for s: Shot in _shots:
		if s.player.playing:
			s.player.volume_db = linear_to_db(maxf(_heard(s), 0.0001))
	for id in _addon_loops.keys():
		var l: AddonLoop = _addon_loops[id]
		if l.player == null or not is_instance_valid(l.player):
			_addon_loops.erase(id)
			continue
		if not l.started and l.given == null and not l.stopping:
			var stream := SoundBank.stream_soon(l.path, true)
			if stream != null:
				l.player.set("stream", stream)
				l.player.call("play", randf() * maxf(0.0, stream.get_length() - 0.1))
				l.started = true
		if l.stopping:
			l.gain -= delta / l.fade_out
			if l.gain <= 0.0:
				_free_addon_loop(l)
				_addon_loops.erase(id)
				continue
		elif l.started:
			l.gain = minf(1.0, l.gain + delta / l.fade_in)
		l.volume = move_toward(l.volume, l.target_volume, delta * 3.0)
		var heard_loop := l.gain * l.volume * (distance_gain(l.pos, l.reach) if l.positional else 1.0)
		l.player.set("volume_db", linear_to_db(maxf(heard_loop, 0.0001)))
		l.player.set("pitch_scale", l.pitch)
	if FxSettings.log_sounds:
		_measure()
		_log_timer += delta
		if _log_timer >= 5.0:
			_log_timer = 0.0
			print("sfx: voices %d/%d loops, %d/%d one-shots; played %s" % [busy_loops(), _loops.size(), busy_shots(), _shots.size(), _counts])
			print("sfx: 5 s: at most %d voices, peak %.1f dB effects / %.1f dB master (machines %.1f, ambience %.1f), %d started over the same file, at most %d of one file, %d held back" % [
				_stat_voices, _stat_peak_fx, _stat_peak_master, _stat_peak_env, _stat_peak_amb, _stat_dups, _stat_same, _stat_dropped])
			_counts.clear()
			_stat_voices = 0
			_stat_peak_fx = -200.0
			_stat_peak_master = -200.0
			_stat_peak_env = -200.0
			_stat_peak_amb = -200.0
			_stat_dups = 0
			_stat_same = 0
			_stat_dropped = 0


## Paths of the voices playing now, with how many play each.
func _playing_paths() -> Dictionary:
	var out := {}
	for v: LoopVoice in _loops:
		if v.key != null and v.player.playing:
			out[v.path] = int(out.get(v.path, 0)) + 1
	for s: Shot in _shots:
		if s.player.playing:
			out[s.path] = int(out.get(s.path, 0)) + 1
	return out


func _measure() -> void:
	var playing := _playing_paths()
	var total := 0
	for path in playing:
		total += int(playing[path])
		_stat_same = maxi(_stat_same, int(playing[path]))
	_stat_voices = maxi(_stat_voices, total)
	_stat_peak_fx = maxf(_stat_peak_fx, _bus_peak("Effects"))
	_stat_peak_master = maxf(_stat_peak_master, _bus_peak("Master"))
	_stat_peak_env = maxf(_stat_peak_env, _bus_peak("Environment"))
	_stat_peak_amb = maxf(_stat_peak_amb, _bus_peak("Ambient"))


static func _bus_peak(bus: String) -> float:
	var i := AudioServer.get_bus_index(bus)
	if i < 0:
		return -200.0
	return maxf(AudioServer.get_bus_peak_volume_left_db(i, 0), AudioServer.get_bus_peak_volume_right_db(i, 0))


func _note(what: String, pos) -> void:
	if not FxSettings.log_sounds:
		return
	var short := what.get_file()
	_counts[short] = int(_counts.get(short, 0)) + 1
	if pos is Vector3:
		var p: Vector3 = pos
		print("sfx: play %s at (%.1f, %.1f), %.1f tiles away" % [what, p.x, p.z, p.distance_to(listener.global_position)])
	else:
		print("sfx: play %s" % what)
