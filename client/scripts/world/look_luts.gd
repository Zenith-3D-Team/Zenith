extends RefCounted
## Factorio's colour lookups (its LUTs) for the Factorio look: per planet, by the time of day, as
## Factorio grades its picture (utility-constants.lua daytime_color_lookup, and each Space Age
## planet's day_night_cycle_color_lookup in planet.lua, Factorio 2.1.24), read from the player's
## install and given to the environment's colour correction (applied after tonemapping, in sRGB).
##
## Factorio's night LUTs also darken the picture, which Zenith already does with its light (so lamps
## still light the ground): each LUT is brought back to its own white's brightness, keeping only its
## colour, and eased out as the night comes (weight 1 - night). Nauvis by day is Factorio's identity.

const ItemIcons := preload("res://scripts/world/item_icons.gd")

## [daytime, file under the data folder, "" for identity]; a planet not listed uses Nauvis'.
const KEYS := {
	"nauvis": [[0.0, ""], [0.2, ""], [0.45, "core/graphics/color_luts/lut-night.png"],
		[0.55, "core/graphics/color_luts/lut-night.png"], [0.8, ""]],
	"vulcanus": [[0.0, "space-age/graphics/lut/vulcanus-1-day.png"], [0.2, "space-age/graphics/lut/vulcanus-1-day.png"],
		[0.45, "space-age/graphics/lut/vulcanus-2-night.png"], [0.55, "space-age/graphics/lut/vulcanus-2-night.png"],
		[0.8, "space-age/graphics/lut/vulcanus-1-day.png"]],
	"gleba": [[0.0, "space-age/graphics/lut/gleba-1-noon.png"], [0.15, "space-age/graphics/lut/gleba-2-afternoon.png"],
		[0.25, "space-age/graphics/lut/gleba-3-late-afternoon.png"], [0.35, "space-age/graphics/lut/gleba-4-sunset.png"],
		[0.45, "space-age/graphics/lut/gleba-5-after-sunset.png"], [0.55, "space-age/graphics/lut/gleba-6-before-dawn.png"],
		[0.65, "space-age/graphics/lut/gleba-7-dawn.png"], [0.75, "space-age/graphics/lut/gleba-8-morning.png"]],
	"fulgora": [[0.0, "space-age/graphics/lut/fulgora-1-noon.png"], [0.2, "space-age/graphics/lut/fulgora-1-noon.png"],
		[0.3, "space-age/graphics/lut/fulgora-2-afternoon.png"], [0.4, "space-age/graphics/lut/fulgora-3-after-sunset.png"],
		[0.6, "space-age/graphics/lut/fulgora-4-before-dawn.png"], [0.7, "space-age/graphics/lut/fulgora-5-morning.png"]],
}
## The texture's size: Factorio's LUTs are 16 x 16 x 16.
const N := 16
## A new lookup is made when the wanted one moved this much, at most every MIN_GAP seconds.
const STEP := 0.02
const MIN_GAP := 0.5

static var _files := {}  # path -> PackedFloat32Array (16^3 x 3) or empty when missing

var _tex: ImageTexture3D
var _key := ""  # what the current texture is: "a|b|t|w"
var _task := -1
var _result: Array = []  # [Image...] from the worker
var _result_key := ""
var _lock := Mutex.new()
var _last := -100.0
var _on := false


## Takes the colour lookup off the environment.
func clear(env: Environment) -> void:
	_on = false
	_key = ""
	if env != null:
		env.adjustment_color_correction = null
		_enable(env)


## Settings set the adjustments again: puts the lookup back.
func reapply(env: Environment) -> void:
	if _on and _tex != null:
		env.adjustment_color_correction = _tex
	_enable(env)


func _enable(env: Environment) -> void:
	env.adjustment_enabled = env.adjustment_color_correction != null or env.adjustment_brightness != 1.0 \
		or env.adjustment_contrast != 1.0 or env.adjustment_saturation != 1.0


## The lookup for a planet at a time of day, made on a worker when it changed enough.
func update(env: Environment, planet: String, daytime: float, night: float) -> void:
	_on = true
	_lock.lock()
	var done := _result
	var done_key := _result_key
	_result = []
	_lock.unlock()
	if not done.is_empty():
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		var slices: Array[Image] = []
		slices.assign(done)
		if _tex == null:
			_tex = ImageTexture3D.new()
			_tex.create(Image.FORMAT_RGB8, N, N, N, false, slices)
		else:
			_tex.update(slices)
		_key = done_key
		env.adjustment_color_correction = _tex
		_enable(env)
	var keys: Array = KEYS.get(planet, KEYS["nauvis"])
	var at := _between(keys, fposmod(daytime, 1.0))
	var weight := 1.0 - clampf(night, 0.0, 1.0)
	var a := str(at[0])
	var b := str(at[1])
	var t := float(at[2])
	if a == "" and b == "" or weight < 0.01:
		if env.adjustment_color_correction != null:
			env.adjustment_color_correction = null
			_key = ""
			_enable(env)
		return
	var want := "%s|%s|%.2f|%.2f" % [a, b, snappedf(t, STEP), snappedf(weight, STEP)]
	var now := Time.get_ticks_msec() / 1000.0
	if want == _key or _task != -1 or now - _last < MIN_GAP:
		return
	_last = now
	var data := ItemIcons.factorio_data_dir()
	if data == "":
		return
	var job := func() -> void:
		var imgs := _build(data, a, b, snappedf(t, STEP), snappedf(weight, STEP))
		_lock.lock()
		_result = imgs
		_result_key = want
		_lock.unlock()
	_task = WorkerThreadPool.add_task(job, false, "Factorio colour lookup")


## [file a, file b, how far from a to b] for a daytime between a planet's keys (they wrap round).
static func _between(keys: Array, daytime: float) -> Array:
	var n := keys.size()
	for i in n:
		var k0: Array = keys[i]
		var k1: Array = keys[(i + 1) % n]
		var t0 := float(k0[0])
		var t1 := float(k1[0]) if i + 1 < n else float(k1[0]) + 1.0
		var d := daytime if daytime >= t0 else daytime + 1.0
		if d >= t0 and d <= t1:
			return [k0[1], k1[1], (d - t0) / maxf(t1 - t0, 1e-4)]
	return ["", "", 0.0]


## One of Factorio's LUT strips (256 x 16: blue slices side by side, red across, green down) as
## 16^3 RGB floats, red fastest then green then blue; empty when it can't be read.
static func _read(data: String, rel: String) -> PackedFloat32Array:
	if _files.has(rel):
		return _files[rel]
	var out := PackedFloat32Array()
	var img := Image.load_from_file(data.path_join(rel)) if FileAccess.file_exists(data.path_join(rel)) else null
	if img != null and img.get_width() == N * N and img.get_height() == N:
		img.convert(Image.FORMAT_RGB8)
		out.resize(N * N * N * 3)
		for b in N:
			for g in N:
				for r in N:
					var c := img.get_pixel(b * N + r, g)
					var i := ((b * N + g) * N + r) * 3
					out[i] = c.r
					out[i + 1] = c.g
					out[i + 2] = c.b
	_files[rel] = out
	return out


static func _sample(lut: PackedFloat32Array, c: Vector3) -> Vector3:
	if lut.is_empty():
		return c
	var p := c.clamp(Vector3.ZERO, Vector3.ONE) * float(N - 1)
	var i0 := Vector3i(floori(p.x), floori(p.y), floori(p.z)).clamp(Vector3i.ZERO, Vector3i(N - 2, N - 2, N - 2))
	var f := p - Vector3(i0)
	var out := Vector3.ZERO
	for dz in 2:
		for dy in 2:
			for dx in 2:
				var w := (f.x if dx else 1.0 - f.x) * (f.y if dy else 1.0 - f.y) * (f.z if dz else 1.0 - f.z)
				var k := (((i0.z + dz) * N + (i0.y + dy)) * N + (i0.x + dx)) * 3
				out += w * Vector3(lut[k], lut[k + 1], lut[k + 2])
	return out


## The lookup Zenith uses: a blended from a to b by t, brought to its white's brightness, mixed
## with the identity by weight. Texel i holds the colour for input (i + 0.5) / N, as Godot samples
## the texture at the colour itself.
static func _build(data: String, a: String, b: String, t: float, weight: float) -> Array:
	var la := _read(data, a) if a != "" else PackedFloat32Array()
	var lb := _read(data, b) if b != "" else PackedFloat32Array()
	var white := _sample(la, Vector3.ONE).lerp(_sample(lb, Vector3.ONE), t)
	var norm := maxf(0.05, white.dot(Vector3(0.2126, 0.7152, 0.0722)))
	var imgs: Array[Image] = []
	for z in N:
		var bytes := PackedByteArray()
		bytes.resize(N * N * 3)
		for y in N:
			for x in N:
				var c := (Vector3(x, y, z) + Vector3(0.5, 0.5, 0.5)) / float(N)
				var v := _sample(la, c).lerp(_sample(lb, c), t) / norm
				v = c.lerp(v, weight).clamp(Vector3.ZERO, Vector3.ONE)
				var i := (y * N + x) * 3
				bytes[i] = int(round(v.x * 255.0))
				bytes[i + 1] = int(round(v.y * 255.0))
				bytes[i + 2] = int(round(v.z * 255.0))
		imgs.append(Image.create_from_data(N, N, false, Image.FORMAT_RGB8, bytes))
	return imgs
