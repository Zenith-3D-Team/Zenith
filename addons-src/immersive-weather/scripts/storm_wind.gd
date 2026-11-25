extends RefCounted
## Storm wind (0.3.2): a broad roar with gusts that never repeat the same way, in place of the
## whistle loop ("WE Heavy Wind Whistle 7": one ~540 Hz tone 56-73 dB over the rest of its
## spectrum, mono, 5.6 dB of movement, pitched up with the wind) the storms used to play.
##
## Two noise layers are made once, on a worker thread, as looping AudioStreamWAVs (no files):
## - ROAR: brown-ish noise, 50 Hz to ~500 Hz, the body of the storm;
## - RUSH: band-passed noise round ~650 Hz, the "whoosh" of a gust.
## Left and right are separate noise (40% shared), each layer a different length, filtered
## circularly so the seam is not there. A gust controller (Gusts) then drives, a frame at a time and
## smoothed twice, the layers' volumes and a small pitch shift of the rush (on noise that is a moving
## band, like a filter's cutoff opening in a gust, not a rising tone); the old whistle stays only as a
## quiet layer at the top of the strongest gusts. Nothing is allocated per frame.

const RATE_ROAR := 11025
const RATE_RUSH := 22050
const SECONDS_ROAR := 13.0
const SECONDS_RUSH := 11.0
const SHARED := 0.4  # left/right shared part of the noise (the rest is each side's own)
const TARGET_RMS := 0.16  # each generated layer's level (about -16 dBFS, as the old loop)

## Layer gains under the wind's gain (tuned so a storm's new wind is about as loud as the old loop
## and wind + heavy rain + close thunder stay under full scale: preview in report, art-src).
const K_ROAR := 1.3
const K_RUSH := 1.15
const K_WHISTLE := 0.2

## The made layers (null until ready()).
var roar: AudioStreamWAV = null
var rush: AudioStreamWAV = null
var _task := -1
var _seed := 0

## Per-frame outputs of step() (read, never reallocated).
var roar_vol := 0.0
var rush_vol := 0.0
var whistle_vol := 0.0
var roar_pitch := 1.0
var rush_pitch := 1.0
var gust := 0.0  # the gust level 0-1 (for tests and the preview)

var gusts := Gusts.new()


func _init(rng_seed := 0) -> void:
	_seed = rng_seed if rng_seed != 0 else int(Time.get_ticks_usec() & 0x7fffffff)
	gusts.seed_with(_seed + 7)


## Starts making the layers on a worker thread (once). ready() says when they are in.
func start() -> void:
	if _task >= 0 or roar != null:
		return
	_task = WorkerThreadPool.add_task(_make, false, "storm wind layers")


## True once both layers are made (collects the worker's task on the main thread).
func ready() -> bool:
	if roar != null:
		return true
	if _task < 0:
		return false
	if not WorkerThreadPool.is_task_completed(_task):
		return false
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	roar = _made_roar
	rush = _made_rush
	return roar != null


## Waits for a running task (the add-on stopping).
func finish() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		roar = _made_roar
		rush = _made_rush


## Makes both layers now, on this thread (the preview; a test).
func make_now() -> void:
	_make()
	roar = _made_roar
	rush = _made_rush


var _made_roar: AudioStreamWAV = null
var _made_rush: AudioStreamWAV = null


func _make() -> void:
	_made_roar = make_layer(0, SECONDS_ROAR, RATE_ROAR, _seed)
	_made_rush = make_layer(1, SECONDS_RUSH, RATE_RUSH, _seed + 1)


## One frame: `wind_amt` the state's wind_audio (0-1.2), `gain` the wind's gain (master x wind volume).
## Sets roar_vol, rush_vol, whistle_vol, roar_pitch, rush_pitch.
func step(delta: float, wind_amt: float, gain: float) -> void:
	# The storm's share, crossfaded with the gentle breeze as the old gusty loop was.
	var share := smoothstep(0.32, 0.95, wind_amt)
	# How stormy: depth of the gusts and the loudness rise from overcast wind to a severe storm.
	var depth := smoothstep(0.45, 1.1, wind_amt)
	var level := share * (0.72 + 0.28 * depth) * gain
	var g := gusts.step(delta, depth)
	# Shallow gusts in a steady overcast wind, full ones in a storm.
	var ge := lerpf(0.35, g, 0.35 + 0.65 * depth)
	gust = ge
	roar_vol = clampf(level * K_ROAR * (0.3 + 0.7 * ge), 0.0, 1.0)
	rush_vol = clampf(level * K_RUSH * (0.06 + 0.94 * ge * sqrt(ge)), 0.0, 1.0)
	whistle_vol = clampf(level * K_WHISTLE * depth * smoothstep(0.72, 1.0, ge), 0.0, 1.0)
	roar_pitch = 0.95 + 0.1 * ge
	rush_pitch = 0.84 + 0.3 * ge


## A looping stereo layer: kind 0 the roar, 1 the rush. Filtered twice round the buffer and the
## second pass kept, so the filters' state at the end is the one at the start (no seam).
static func make_layer(kind: int, seconds: float, rate: int, rng_seed: int) -> AudioStreamWAV:
	var n := int(seconds * rate)
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var shared := PackedFloat32Array()
	shared.resize(n)
	for i in n:
		shared[i] = rng.randf() * 2.0 - 1.0
	var out_l := _channel(kind, n, rate, rng, shared)
	var out_r := _channel(kind, n, rate, rng, shared)
	# Same level for every layer and seed.
	var sum := 0.0
	var peak := 0.0
	for i in n:
		sum += out_l[i] * out_l[i] + out_r[i] * out_r[i]
		peak = maxf(peak, maxf(absf(out_l[i]), absf(out_r[i])))
	var rms := sqrt(sum / float(2 * n))
	var k := TARGET_RMS / maxf(rms, 1e-9)
	if peak * k > 0.97:
		k = 0.97 / peak
	var data := PackedByteArray()
	data.resize(n * 4)
	for i in n:
		data.encode_s16(i * 4, int(clampf(out_l[i] * k, -1.0, 1.0) * 32767.0))
		data.encode_s16(i * 4 + 2, int(clampf(out_r[i] * k, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.stereo = true
	w.mix_rate = rate
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = n
	return w


static func _channel(kind: int, n: int, rate: int, rng: RandomNumberGenerator, shared: PackedFloat32Array) -> PackedFloat32Array:
	var x := PackedFloat32Array()
	x.resize(n)
	var own := 1.0 - SHARED
	for i in n:
		x[i] = shared[i] * SHARED + (rng.randf() * 2.0 - 1.0) * own
	var y := PackedFloat32Array()
	y.resize(n)
	if kind == 0:
		# Roar: low-pass 150 Hz (brown above it), low-pass 520 Hz, high-pass 50 Hz.
		var a1 := exp(-TAU * 150.0 / rate)
		var a2 := exp(-TAU * 520.0 / rate)
		var a3 := exp(-TAU * 50.0 / rate)
		var s1 := 0.0
		var s2 := 0.0
		var s3 := 0.0
		for _pass in 2:
			for i in n:
				s1 = x[i] * (1.0 - a1) + s1 * a1
				s2 = s1 * (1.0 - a2) + s2 * a2
				s3 = s2 * (1.0 - a3) + s3 * a3
				y[i] = s2 - s3
	else:
		# Rush: band-pass round 650 Hz (RBJ, Q 0.7), then a low-pass at 2.6 kHz to take the hiss off.
		var w0 := TAU * 650.0 / rate
		var alpha := sin(w0) / (2.0 * 0.7)
		var a0 := 1.0 + alpha
		var b0 := alpha / a0
		var b2 := -alpha / a0
		var c1 := -2.0 * cos(w0) / a0
		var c2 := (1.0 - alpha) / a0
		var lp := exp(-TAU * 2600.0 / rate)
		var x1 := 0.0
		var x2 := 0.0
		var y1 := 0.0
		var y2 := 0.0
		var s := 0.0
		for _pass in 2:
			for i in n:
				var xi := x[i]
				var yi := b0 * xi + b2 * x2 - c1 * y1 - c2 * y2
				x2 = x1
				x1 = xi
				y2 = y1
				y1 = yi
				s = yi * (1.0 - lp) + s * lp
				y[i] = s
	return y


## The gust level, 0-1: lulls and gusts at random times and heights (never the same twice), each
## approached through two smoothing stages (no corners, no zipper), plus a small quick flutter.
class Gusts:
	var rng := RandomNumberGenerator.new()
	var target := 0.3
	var mid := 0.3
	var level := 0.3
	var tau := 2.0
	var timer := 0.0
	var gusting := false
	var flutter := 0.0
	var flutter_target := 0.0
	var flutter_timer := 0.0

	func seed_with(s: int) -> void:
		rng.seed = s

	## Next frame's gust level; `depth` (0-1) how stormy.
	func step(delta: float, depth: float) -> float:
		timer -= delta
		if timer <= 0.0:
			gusting = not gusting
			if gusting:
				# A gust: up to 0.55-1.0 in about 0.7-2 s, held 1-3.5 s.
				target = rng.randf_range(0.55, 1.0)
				tau = rng.randf_range(0.3, 0.9)
				timer = rng.randf_range(1.2, 4.0)
				# Now and then a double gust (a short lull only).
				if rng.randf() < 0.25:
					timer *= 0.5
			else:
				# A lull: down to 0-0.35 over 1.2-3 s, lasting 1.5-7 s (shorter in a strong storm).
				target = rng.randf_range(0.0, 0.35)
				tau = rng.randf_range(0.6, 1.5)
				timer = rng.randf_range(1.5, 7.0) * (1.0 - 0.3 * depth)
		var k := 1.0 - exp(-delta / maxf(tau, 0.05))
		mid += (target - mid) * k
		level += (mid - level) * k
		flutter_timer -= delta
		if flutter_timer <= 0.0:
			flutter_target = rng.randf_range(-1.0, 1.0)
			flutter_timer = rng.randf_range(0.25, 0.7)
		flutter += (flutter_target - flutter) * (1.0 - exp(-delta / 0.18))
		return clampf(level + 0.07 * flutter * (0.4 + 0.6 * level), 0.0, 1.0)
