extends RefCounted
## Procedural water splash & wet-spray audio for vehicles driving through puddles.
##
## Synthesizes all 16-bit PCM AudioStreamWAV buffers once on a WorkerThreadPool worker:
## - `spray_loop`: 4.5 s stereo seamless loop (circularly double-pass filtered hiss + churn body
##   with wrapped droplet-patter amplitude modulation).
## - `impacts_heavy`: 3 x 0.55 s mono one-shots (thump + water-sheet splash + droplet tail).
## - `impacts_light`: 3 x 0.40 s mono one-shots (crisp hydroplane slap + bright spray burst).

const RATE := 22050
const SPRAY_SECONDS := 4.5
const HEAVY_SECONDS := 0.55
const LIGHT_SECONDS := 0.40
const IMPACT_VARIANTS := 3
const SHARED_STEREO := 0.35
const SPRAY_TARGET_RMS := 0.18
const IMPACT_TARGET_PEAK := 0.88
const MAX_PEAK := 0.95
const IMPACT_COOLDOWN_MS := 220

var api = null

## Synthesized streams (null / empty until ready()).
var spray_loop: AudioStreamWAV = null
var impacts_heavy: Array[AudioStreamWAV] = []
var impacts_light: Array[AudioStreamWAV] = []

var _task: int = -1
var _seed: int = 0
var _made_spray: AudioStreamWAV = null
var _made_heavy: Array[AudioStreamWAV] = []
var _made_light: Array[AudioStreamWAV] = []

var _spray_id: int = 0
var _spray_pitch: float = 1.0
var _spray_opts: Dictionary = {"at": Vector3.ZERO, "volume": 0.0, "pitch": 1.0}
var _last_impact_ms: int = -1000
var _last_heavy_idx: int = -1
var _last_light_idx: int = -1
var _pick_rng := RandomNumberGenerator.new()


func _init(a = null, rng_seed: int = 0) -> void:
	api = a
	_seed = rng_seed if rng_seed != 0 else int(Time.get_ticks_usec() & 0x7fffffff)
	if _seed == 0:
		_seed = 0x517cc1b7
	_pick_rng.seed = _seed + 17


## Attaches or updates the add-on API handle.
func setup(a) -> void:
	api = a


## Starts synthesizing all splash & spray buffers once on a worker thread.
func start() -> void:
	if _task >= 0 or spray_loop != null:
		return
	_task = WorkerThreadPool.add_task(_make, false, "puddle splash audio")


## True once all buffers are ready (collects the worker task on the main thread).
func ready() -> bool:
	if spray_loop != null:
		return true
	if _task < 0:
		return false
	if not WorkerThreadPool.is_task_completed(_task):
		return false
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	_commit_made()
	return spray_loop != null


## Blocks until any active worker synthesis task completes.
func finish() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_commit_made()


## Synthesizes all buffers synchronously on the calling thread (for tests).
func make_now() -> void:
	if spray_loop != null:
		return
	if _task >= 0:
		finish()
		return
	_make()
	_commit_made()


func _commit_made() -> void:
	spray_loop = _made_spray
	impacts_heavy = _made_heavy
	impacts_light = _made_light


func _make() -> void:
	_made_spray = make_spray_loop(_seed + 101)
	var heavy: Array[AudioStreamWAV] = []
	var light: Array[AudioStreamWAV] = []
	for i in IMPACT_VARIANTS:
		heavy.append(make_heavy_impact(_seed + 201 + i * 37, i))
		light.append(make_light_impact(_seed + 401 + i * 53, i))
	_made_heavy = heavy
	_made_light = light


## Updates or stops the single positional continuous wet-spray loop.
func update_spray(
		active: bool, pos: Vector3, intensity: float,
		speed_norm: float, heavy: bool, gain: float) -> void:
	if api == null:
		return
	var sp := clampf(speed_norm, 0.0, 1.0)
	var lvl := clampf(intensity, 0.0, 1.5) * clampf(gain, 0.0, 1.0)
	var vol := clampf(lvl * (0.35 + 0.65 * sp), 0.0, 1.0)
	if not active or vol <= 0.005:
		_stop_spray(0.25)
		return
	start()
	if not ready():
		return
	var target_pitch := (0.78 + 0.24 * sp) if heavy else (0.94 + 0.31 * sp)
	target_pitch = clampf(target_pitch, 0.78, 1.25)
	if _spray_id > 0:
		_spray_pitch = clampf(lerpf(_spray_pitch, target_pitch, 0.35), 0.78, 1.25)
		_spray_opts["at"] = pos
		_spray_opts["volume"] = vol
		_spray_opts["pitch"] = _spray_pitch
		if bool(api.sound.update_loop(_spray_id, _spray_opts)):
			return
		_spray_id = 0
	_spray_pitch = target_pitch
	_spray_id = int(api.sound.loop(spray_loop, {
		"at": pos,
		"bus": "effects",
		"volume": vol,
		"pitch": _spray_pitch,
		"reach": 1.15,
		"fade_in": 0.18,
	}))
	if _spray_id < 0:
		_spray_id = 0


## Plays a rate-limited, non-repeating positional water-impact one-shot.
func play_impact(pos: Vector3, strength: float, heavy: bool, gain: float) -> bool:
	if not ready() or api == null:
		return false
	var now_ms := Time.get_ticks_msec()
	if now_ms - _last_impact_ms < IMPACT_COOLDOWN_MS:
		return false
	var vol := clampf(clampf(strength, 0.0, 1.5) * clampf(gain, 0.0, 1.0), 0.0, 1.0)
	if vol <= 0.01:
		return false
	var pool: Array[AudioStreamWAV] = impacts_heavy if heavy else impacts_light
	if pool.is_empty():
		return false
	var last_idx := _last_heavy_idx if heavy else _last_light_idx
	var idx := _pick_non_repeat(pool.size(), last_idx)
	var chosen: AudioStreamWAV = pool[idx]
	var played := bool(api.sound.play(chosen, {
		"at": pos,
		"bus": "effects",
		"volume": vol,
		"pitch_spread": 0.10,
		"reach": 1.25,
	}))
	if not played:
		return false
	_last_impact_ms = now_ms
	if heavy:
		_last_heavy_idx = idx
	else:
		_last_light_idx = idx
	return true


## Stops the active spray loop immediately with a short fade.
func stop_all() -> void:
	_stop_spray(0.25)


## Stops playback and joins any running synthesis worker.
func shutdown() -> void:
	stop_all()
	finish()


func _stop_spray(fade_out: float) -> void:
	if _spray_id > 0:
		if api != null:
			api.sound.stop_loop(_spray_id, fade_out)
		_spray_id = 0


func _pick_non_repeat(size: int, last_idx: int) -> int:
	if size <= 1:
		return 0
	var idx := _pick_rng.randi() % size
	if idx == last_idx:
		idx = (idx + 1 + (_pick_rng.randi() % (size - 1))) % size
	return idx


## Generates the seamless 4.5 s stereo wet-spray loop (circular double-pass filtered).
static func make_spray_loop(rng_seed: int) -> AudioStreamWAV:
	var n := int(SPRAY_SECONDS * RATE)
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var shared := PackedFloat32Array()
	shared.resize(n)
	for i in n:
		shared[i] = rng.randf() * 2.0 - 1.0
	var out_l := _spray_channel(n, RATE, rng, shared)
	var out_r := _spray_channel(n, RATE, rng, shared)
	var sum := 0.0
	var peak := 0.0
	for i in n:
		sum += out_l[i] * out_l[i] + out_r[i] * out_r[i]
		peak = maxf(peak, maxf(absf(out_l[i]), absf(out_r[i])))
	var rms := sqrt(sum / float(2 * n))
	var k := SPRAY_TARGET_RMS / maxf(rms, 1e-9)
	if peak * k > MAX_PEAK:
		k = MAX_PEAK / peak
	var data := PackedByteArray()
	data.resize(n * 4)
	for i in n:
		data.encode_s16(i * 4, int(clampf(out_l[i] * k, -1.0, 1.0) * 32767.0))
		data.encode_s16(i * 4 + 2, int(clampf(out_r[i] * k, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.stereo = true
	w.mix_rate = RATE
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = n
	return w


static func _spray_channel(
		n: int, rate: int, rng: RandomNumberGenerator,
		shared: PackedFloat32Array) -> PackedFloat32Array:
	var x := PackedFloat32Array()
	x.resize(n)
	var own := 1.0 - SHARED_STEREO
	for i in n:
		x[i] = shared[i] * SHARED_STEREO + (rng.randf() * 2.0 - 1.0) * own

	# Circular droplet-patter envelope: sparse random bursts smoothed twice around the ring.
	var patter_raw := PackedFloat32Array()
	patter_raw.resize(n)
	var drop_count := int(SPRAY_SECONDS * 68.0)
	for _d in drop_count:
		var idx := rng.randi() % n
		patter_raw[idx] += rng.randf_range(0.35, 1.0)
	var env := PackedFloat32Array()
	env.resize(n)
	var a_fast := exp(-TAU * 75.0 / rate)
	var a_slow := exp(-TAU * 11.0 / rate)
	var ef := 0.0
	var es := 0.0
	for _pass in 2:
		for i in n:
			ef = patter_raw[i] * (1.0 - a_fast) + ef * a_fast
			es = (ef + 0.15 * absf(x[i])) * (1.0 - a_slow) + es * a_slow
			env[i] = ef * 0.55 + es * 0.45
	var env_sum := 0.0
	for i in n:
		env_sum += env[i]
	var env_mean := maxf(env_sum / float(n), 1e-6)

	# Band 1: wet spray hiss (900 - 4800 Hz, 2-stage HP + 2-stage LP, circular double-pass).
	var hp_hiss := exp(-TAU * 900.0 / rate)
	var lp_hiss := exp(-TAU * 4800.0 / rate)
	var hs1 := 0.0
	var hs2 := 0.0
	var ls1 := 0.0
	var ls2 := 0.0

	# Band 2: lower water-churn body (180 - 650 Hz, 2-stage HP + 2-stage LP, circular double-pass).
	var hp_body := exp(-TAU * 180.0 / rate)
	var lp_body := exp(-TAU * 650.0 / rate)
	var hb1 := 0.0
	var hb2 := 0.0
	var lb1 := 0.0
	var lb2 := 0.0

	var y := PackedFloat32Array()
	y.resize(n)
	for _pass in 2:
		for i in n:
			var xi := x[i]
			# Spray hiss band
			hs1 = xi * (1.0 - hp_hiss) + hs1 * hp_hiss
			var h1 := xi - hs1
			hs2 = h1 * (1.0 - hp_hiss) + hs2 * hp_hiss
			var h2 := h1 - hs2
			ls1 = h2 * (1.0 - lp_hiss) + ls1 * lp_hiss
			ls2 = ls1 * (1.0 - lp_hiss) + ls2 * lp_hiss

			# Churn body band
			hb1 = xi * (1.0 - hp_body) + hb1 * hp_body
			var b1 := xi - hb1
			hb2 = b1 * (1.0 - hp_body) + hb2 * hp_body
			var b2 := b1 - hb2
			lb1 = b2 * (1.0 - lp_body) + lb1 * lp_body
			lb2 = lb1 * (1.0 - lp_body) + lb2 * lp_body

			var p_norm := clampf(env[i] / env_mean, 0.2, 2.2)
			var mod_hiss := 0.60 + 0.42 * p_norm
			var mod_body := 0.78 + 0.22 * p_norm
			y[i] = ls2 * 0.74 * mod_hiss + lb2 * 0.62 * mod_body
	return y


## Generates one heavy (tank / spidertron) 0.55 s water impact one-shot.
static func make_heavy_impact(rng_seed: int, variant: int) -> AudioStreamWAV:
	var n := int(HEAVY_SECONDS * RATE)
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var buf := PackedFloat32Array()
	buf.resize(n)

	# 1. Low hydraulic thump (85 - 240 Hz pitch-drop body + low-band displacement noise).
	var f0 := rng.randf_range(190.0, 238.0) - float(variant) * 8.0
	var f1 := rng.randf_range(86.0, 108.0)
	var thump_phase := 0.0
	var hp_thump := exp(-TAU * 85.0 / RATE)
	var lp_thump := exp(-TAU * 240.0 / RATE)
	var th_hp := 0.0
	var th_lp1 := 0.0
	var th_lp2 := 0.0

	# 2. Swelling broadband water-sheet splash (380 - 5200 Hz).
	var hp_splash := exp(-TAU * 380.0 / RATE)
	var lp_splash := exp(-TAU * 5200.0 / RATE)
	var sp_hp1 := 0.0
	var sp_hp2 := 0.0
	var sp_lp1 := 0.0
	var sp_lp2 := 0.0
	var slosh_hz := rng.randf_range(14.0, 21.0)
	var slosh_ph := rng.randf_range(0.0, TAU)

	var tail_fade_start := HEAVY_SECONDS - 0.020
	for i in n:
		var t := float(i) / float(RATE)
		var noise := rng.randf() * 2.0 - 1.0

		# Hydraulic thump
		var freq := f1 + (f0 - f1) * exp(-t / 0.032)
		thump_phase += TAU * freq / float(RATE)
		var thump_env := smoothstep(0.0, 0.004, t) * exp(-t / 0.088)
		th_hp = noise * (1.0 - hp_thump) + th_hp * hp_thump
		var th_n := noise - th_hp
		th_lp1 = th_n * (1.0 - lp_thump) + th_lp1 * lp_thump
		th_lp2 = th_lp1 * (1.0 - lp_thump) + th_lp2 * lp_thump
		var thump := (sin(thump_phase) * 0.55 + th_lp2 * 1.9) * thump_env

		# Swelling water-sheet splash
		sp_hp1 = noise * (1.0 - hp_splash) + sp_hp1 * hp_splash
		var sh1 := noise - sp_hp1
		sp_hp2 = sh1 * (1.0 - hp_splash) + sp_hp2 * hp_splash
		var sh2 := sh1 - sp_hp2
		sp_lp1 = sh2 * (1.0 - lp_splash) + sp_lp1 * lp_splash
		sp_lp2 = sp_lp1 * (1.0 - lp_splash) + sp_lp2 * lp_splash
		var swell := (1.0 - exp(-t / 0.022)) * exp(-t / 0.145)
		var slosh := 0.78 + 0.22 * sin(TAU * slosh_hz * t + slosh_ph)
		var splash := sp_lp2 * swell * slosh * 1.55

		var tail_env := 1.0 - smoothstep(tail_fade_start, HEAVY_SECONDS, t)
		buf[i] = (thump * 0.85 + splash) * tail_env

	# 3. Sparse resonant falling-droplet ticks in the tail (0.16 - 0.50 s).
	var drop_count := 8 + (variant % 3) * 2
	for d in drop_count:
		var t0 := rng.randf_range(0.16, 0.46) + float(d) * 0.004
		if t0 >= HEAVY_SECONDS - 0.03:
			continue
		var start_idx := int(t0 * float(RATE))
		var drop_len := mini(n - start_idx, int(0.034 * float(RATE)))
		var f_drop := rng.randf_range(950.0, 2550.0)
		var amp := rng.randf_range(0.10, 0.24)
		var tau_d := rng.randf_range(0.006, 0.012)
		var d_phase := 0.0
		for j in drop_len:
			var dt := float(j) / float(RATE)
			var f_now := f_drop * (1.0 + 0.28 * (1.0 - exp(-dt / 0.008)))
			d_phase += TAU * f_now / float(RATE)
			var d_env := smoothstep(0.0, 0.0012, dt) * exp(-dt / tau_d)
			var tail_env := 1.0 - smoothstep(tail_fade_start, HEAVY_SECONDS, t0 + dt)
			buf[start_idx + j] += sin(d_phase) * amp * d_env * tail_env

	return _finalize_mono_wav(buf, RATE)


## Generates one light (car) 0.40 s hydroplane slap + bright spray burst one-shot.
static func make_light_impact(rng_seed: int, variant: int) -> AudioStreamWAV:
	var n := int(LIGHT_SECONDS * RATE)
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var buf := PackedFloat32Array()
	buf.resize(n)

	# 1. Crisp hydroplane slap (220 - 540 Hz pulse + 500 - 3800 Hz short slap transient).
	var slap_f0 := rng.randf_range(340.0, 440.0) + float(variant) * 15.0
	var slap_f1 := rng.randf_range(160.0, 210.0)
	var slap_phase := 0.0
	var hp_slap := exp(-TAU * 480.0 / RATE)
	var lp_slap := exp(-TAU * 3600.0 / RATE)
	var sl_hp := 0.0
	var sl_lp := 0.0

	# 2. Bright water spray burst (650 - 6200 Hz).
	var hp_spray := exp(-TAU * 650.0 / RATE)
	var lp_spray := exp(-TAU * 6200.0 / RATE)
	var sp_hp1 := 0.0
	var sp_hp2 := 0.0
	var sp_lp1 := 0.0
	var sp_lp2 := 0.0
	var mod_hz := rng.randf_range(24.0, 34.0)
	var mod_ph := rng.randf_range(0.0, TAU)

	var tail_fade_start := LIGHT_SECONDS - 0.018
	for i in n:
		var t := float(i) / float(RATE)
		var noise := rng.randf() * 2.0 - 1.0

		var f_slap := slap_f1 + (slap_f0 - slap_f1) * exp(-t / 0.012)
		slap_phase += TAU * f_slap / float(RATE)
		var slap_env := smoothstep(0.0, 0.0015, t) * exp(-t / 0.028)
		sl_hp = noise * (1.0 - hp_slap) + sl_hp * hp_slap
		sl_lp = (noise - sl_hp) * (1.0 - lp_slap) + sl_lp * lp_slap
		var slap := (sin(slap_phase) * 0.42 + sl_lp * 1.4) * slap_env

		sp_hp1 = noise * (1.0 - hp_spray) + sp_hp1 * hp_spray
		var sh1 := noise - sp_hp1
		sp_hp2 = sh1 * (1.0 - hp_spray) + sp_hp2 * hp_spray
		var sh2 := sh1 - sp_hp2
		sp_lp1 = sh2 * (1.0 - lp_spray) + sp_lp1 * lp_spray
		sp_lp2 = sp_lp1 * (1.0 - lp_spray) + sp_lp2 * lp_spray
		var burst_env := smoothstep(0.0, 0.008, t) * exp(-t / 0.095)
		var flutter := 0.80 + 0.20 * sin(TAU * mod_hz * t + mod_ph)
		var spray := sp_lp2 * burst_env * flutter * 1.45

		var tail_env := 1.0 - smoothstep(tail_fade_start, LIGHT_SECONDS, t)
		buf[i] = (slap * 0.90 + spray) * tail_env

	# Light droplet ticks in the tail.
	var drop_count := 4 + (variant % 2) * 2
	for d in drop_count:
		var t0 := rng.randf_range(0.12, 0.33) + float(d) * 0.004
		if t0 >= LIGHT_SECONDS - 0.025:
			continue
		var start_idx := int(t0 * float(RATE))
		var drop_len := mini(n - start_idx, int(0.024 * float(RATE)))
		var f_drop := rng.randf_range(1400.0, 3200.0)
		var amp := rng.randf_range(0.07, 0.16)
		var tau_d := rng.randf_range(0.004, 0.008)
		var d_phase := 0.0
		for j in drop_len:
			var dt := float(j) / float(RATE)
			var f_now := f_drop * (1.0 + 0.25 * (1.0 - exp(-dt / 0.006)))
			d_phase += TAU * f_now / float(RATE)
			var d_env := smoothstep(0.0, 0.001, dt) * exp(-dt / tau_d)
			var tail_env := 1.0 - smoothstep(tail_fade_start, LIGHT_SECONDS, t0 + dt)
			buf[start_idx + j] += sin(d_phase) * amp * d_env * tail_env

	return _finalize_mono_wav(buf, RATE)


static func _finalize_mono_wav(buf: PackedFloat32Array, rate: int) -> AudioStreamWAV:
	var n := buf.size()
	var peak := 0.0
	for i in n:
		peak = maxf(peak, absf(buf[i]))
	var k := IMPACT_TARGET_PEAK / maxf(peak, 1e-9)
	if peak * k > MAX_PEAK:
		k = MAX_PEAK / peak
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		data.encode_s16(i * 2, int(clampf(buf[i] * k, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.stereo = false
	w.mix_rate = rate
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_DISABLED
	return w
