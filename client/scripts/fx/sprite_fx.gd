extends Node3D
## Pooled sprite-sheet cards for effects: one MultiMesh per sheet, rewritten each frame from a
## flat buffer, so hundreds of puffs cost a few draw calls. The sheets are Factorio's own
## (smoke, explosions, muzzle flash, sparks, scorch marks), read from the player's install;
## without one each sheet is a soft procedural blob.

const SoundBank := preload("res://scripts/fx/sound_bank.gd")
const MomentHold := preload("res://scripts/world/moment_hold.gd")
const Switches := preload("res://scripts/switches.gd")
const MIX_SHADER := preload("res://shaders/fx_sprite.gdshader")
const ADD_SHADER := preload("res://shaders/fx_sprite_add.gdshader")
static var _EMPTY_BUF := PackedFloat32Array()

## `--fx-opt=off`: keeps the legacy FIFO pool overwrite and per-frame MomentHold buffer updates.
static var fx_opt := Switches.on("--fx-opt")

## name: [file under data/base/graphics/entity, frame width, height, frames, additive, cyclic,
## card capacity, flat on the ground, fade-in and fade-out (fractions of the card's life)].
## Frame sizes and counts are as in Factorio's prototypes (explosion-animations.lua, smoke.lua).
const SHEETS := {
	"smoke": ["smoke/smoke.png", 152, 120, 60, false, true, 400, false, 0.15, 0.6],
	"dust": ["smoke-fast/smoke-fast.png", 50, 50, 16, false, false, 160, false, 0.0, 0.5],
	"explosion": ["medium-explosion/medium-explosion-1.png", 124, 224, 30, false, false, 24, false, 0.0, 0.15],
	"small-explosion": ["small-explosion/small-explosion-1.png", 88, 178, 24, false, false, 32, false, 0.0, 0.15],
	"hit": ["explosion/explosion-1.png", 48, 42, 17, true, false, 48, false, 0.0, 0.2],
	"muzzle": ["explosion-gunshot/explosion-gunshot.png", 34, 38, 2, true, false, 16, false, 0.0, 0.3],
	"sparks": ["sparks/sparks-01.png", 39, 34, 19, true, false, 64, false, 0.0, 0.2],
	"roboport-charge": ["roboport/roboport-recharging.png", 37, 35, 16, true, true, 128, false, 0.08, 0.2],
	"scorch": ["scorchmark/small-scorchmark.png", 256, 182, 4, false, false, 240, true, 0.02, 0.25],
	# Turrets and vehicle guns (turrets.gd): a bullet's hit, the artillery's muzzle flash, the
	# flamethrower's stream particles and the fire at its nozzle.
	"bullet-hit": ["explosion-hit/explosion-hit.png", 34, 38, 13, false, false, 96, false, 0.0, 0.2],
	"artillery-flash": ["artillery-cannon-muzzle-flash/muzzle-flash.png", 276, 382, 21, false, false, 8, false, 0.0, 0.2],
	"flame-stream": ["flamethrower-fire-stream/flamethrower-explosion.png", 124, 108, 36, false, false, 400, false, 0.05, 0.25],
	"flame-muzzle": ["flamethrower-turret/flamethrower-turret-muzzle-fire.png", 16, 30, 32, true, true, 24, false, 0.0, 0.3],
	# A rocket launch (rockets.gd), its cards held in place. The hole's pictures are squared up to
	# lie flat on the ground.
	"rocket-jet": ["rocket-silo/rocket-jet.png", 290, 288, 8, true, true, 8, false, 0.0, 0.0],
	"rocket-glare": ["rocket-silo/03-rocket-over-glare.png", 481, 481, 1, true, false, 8, false, 0.0, 0.0],
	"silo-hole": ["rocket-silo/01-rocket-silo-hole.png", 400, 400, 1, false, false, 8, true, 0.0, 0.0],
	"silo-hole-light": ["rocket-silo/01-rocket-silo-hole-light.png", 400, 400, 1, true, false, 8, true, 0.0, 0.0],
	"rocket-smoke": ["rocket-silo/12-rocket-smoke.png", 80, 286, 24, false, true, 20, false, 0.0, 0.0],
	"silo-light": ["rocket-silo/07-red-lights-back/red-light.png", 32, 32, 1, true, false, 44, false, 0.0, 0.0],
}


class Card:
	var pos := Vector3.ZERO
	var vel := Vector3.ZERO
	var age := 0.0
	var life := 1.0
	var size0 := 1.0
	var size1 := 1.0
	var spin := 0.0
	var spin_rate := 0.0
	var color := Color.WHITE
	var frame := 0.0  # first frame; cyclic sheets play on from it at `fps`
	var fps := 15.0
	var rise := 0.0  # upward acceleration (smoke) or gravity when negative
	var drag := 0.0
	var angle := 0.0  # on the ground (decals)


class Pool:
	var mmi := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	var material := ShaderMaterial.new()
	var cards: Array[Card] = []
	var frames := 1
	var aspect := 1.0
	var cyclic := false
	var additive := false
	var flat := false
	var capacity := 64
	var fade_in := 0.0
	var fade_out := 0.3
	var glow := false  # draws itself lit: not dimmed at night (Factorio's draw_as_glow)
	var buffer := PackedFloat32Array()
	var shown := 0  # cards drawn after the last _step
	var brightness := -1.0  # the material's brightness as last set
	var cursor := 0  # O(1) ring overwrite cursor when at capacity
	var dirty := false


var _pools := {}  # name -> Pool
var _pool_list: Array[Pool] = []
var _dirty := false
var _quad: QuadMesh
## 0 by day, 1 at night: smoke dims with the light, flashes don't.
var night := 0.0


func _ready() -> void:
	_quad = QuadMesh.new()
	_quad.size = Vector2.ONE
	for name in SHEETS:
		var spec: Array = SHEETS[name]
		var pool := Pool.new()
		pool.additive = spec[4]
		pool.cyclic = spec[5]
		pool.capacity = spec[6]
		pool.flat = spec[7]
		pool.fade_in = spec[8]
		pool.fade_out = spec[9]
		pool.aspect = float(spec[2]) / float(spec[1])
		var grid := Vector2.ONE
		var texture := _load_sheet(spec[0])
		if texture != null:
			pool.frames = int(spec[3])
			grid = Vector2(floorf(texture.get_width() / float(spec[1])), ceilf(texture.get_height() / float(spec[2])))
		else:
			texture = _blob(name)
			pool.aspect = 1.0
		_configure_pool(pool, texture, grid, name)
		_pools[name] = pool
		_pool_list.append(pool)


func _configure_pool(pool: Pool, texture: Texture2D, grid: Vector2, node_name: String) -> void:
	if _quad == null:
		_quad = QuadMesh.new()
		_quad.size = Vector2.ONE
	pool.material.shader = ADD_SHADER if pool.additive else MIX_SHADER
	pool.material.set_shader_parameter("atlas", texture)
	pool.material.set_shader_parameter("grid", grid)
	pool.material.set_shader_parameter("billboard", not pool.flat)
	# Decals draw before the smoke and flashes above them.
	pool.material.render_priority = -1 if pool.flat else (1 if pool.additive else 0)
	pool.mm.transform_format = MultiMesh.TRANSFORM_3D
	pool.mm.use_colors = true
	pool.mm.use_custom_data = true
	pool.mm.mesh = _quad
	pool.mm.instance_count = pool.capacity
	pool.mm.visible_instance_count = 0
	pool.mmi.multimesh = pool.mm
	pool.mmi.material_override = pool.material
	pool.mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pool.mmi.name = node_name
	pool.buffer.resize(pool.capacity * 20)
	pool.buffer.fill(0.0)
	var one_idx := 6 if pool.flat else 10
	for k in pool.capacity:
		pool.buffer[k * 20 + one_idx] = 1.0
	add_child(pool.mmi)


## A new card on sheet `sheet` at `pos` (its centre), `width` tiles wide (the sheet's frame
## shape sets its height). Returns it to tweak, or null for an unknown sheet. When the pool is
## full the oldest card makes way.
func emit(sheet: String, pos: Vector3, width: float, life: float, color := Color.WHITE) -> Card:
	var pool: Pool = _pools.get(sheet)
	if pool == null:
		return null
	var c := Card.new()
	c.pos = pos
	c.size0 = width
	c.size1 = width
	c.life = maxf(life, 0.01)
	c.color = color
	if pool.cyclic:
		c.frame = randi() % pool.frames
	var cards: Array[Card] = pool.cards
	if cards.size() >= pool.capacity:
		if fx_opt:
			if pool.cursor >= cards.size():
				pool.cursor = 0
			cards[pool.cursor] = c
			pool.cursor += 1
			if pool.cursor >= pool.capacity:
				pool.cursor = 0
		else:
			cards.pop_front()
			cards.append(c)
	else:
		cards.append(c)
	pool.dirty = true
	return c


## A pool for a sheet made at runtime (weapon_fx.gd cuts Factorio's explosion, projectile and
## fire animations into atlases): `grid` frames across and down, `aspect` a frame's height over
## its width. Does nothing if the name is taken.
func add_pool(sheet: String, texture: Texture2D, grid: Vector2, frames: int, aspect: float, additive: bool,
		cyclic: bool, flat: bool, capacity: int, glow := false, fade_in := 0.0, fade_out := 0.15) -> void:
	if _pools.has(sheet):
		return
	var pool := Pool.new()
	pool.additive = additive
	pool.cyclic = cyclic
	pool.flat = flat
	pool.glow = glow
	pool.capacity = maxi(capacity, 1)
	pool.fade_in = fade_in
	pool.fade_out = fade_out
	pool.aspect = aspect
	pool.frames = maxi(frames, 1)
	_configure_pool(pool, texture, grid, sheet.validate_node_name())
	_pools[sheet] = pool
	_pool_list.append(pool)


func has_pool(sheet: String) -> bool:
	return _pools.has(sheet)


## Takes a card out at once (a projectile that hit, a fire that went out).
func kill(card: Card) -> void:
	card.age = card.life
	_dirty = true


func frame_count(sheet: String) -> int:
	var pool: Pool = _pools.get(sheet)
	return pool.frames if pool != null else 1


func count() -> int:
	var n := 0
	for pool in _pool_list:
		n += pool.cards.size()
	return n


func clear() -> void:
	for pool in _pool_list:
		pool.cards.clear()
		pool.cursor = 0
		pool.dirty = false
		pool.mm.visible_instance_count = 0
		pool.shown = 0
	_dirty = false


## The last frame's _process time, microseconds (--stutter-probe).
var process_usec := 0


func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	var brightness := lerpf(1.0, 0.3, night)
	var held := MomentHold.on
	var step_delta := 0.0 if held else delta
	for pool in _pool_list:
		# Set only when it changes: each set queues the material's uniforms to be sent again.
		if not pool.additive and not pool.glow and pool.brightness != brightness:
			pool.brightness = brightness
			pool.material.set_shader_parameter("brightness", brightness)
		if held and fx_opt and not _dirty and not pool.dirty:
			continue
		if pool.cards.is_empty() and pool.shown == 0:
			pool.dirty = false
			continue
		_step(pool, step_delta)  # a screenshot's moment: effects hold where they are
		pool.dirty = false
	_dirty = false
	process_usec = Time.get_ticks_usec() - t0


func _step(pool: Pool, delta: float) -> void:
	var cards: Array[Card] = pool.cards
	var n := cards.size()
	if n == 0:
		if pool.shown != 0:
			pool.mm.visible_instance_count = 0
			pool.shown = 0
		return
	var aspect := pool.aspect
	var cyclic := pool.cyclic
	var flat := pool.flat
	var fade_in := pool.fade_in
	var fade_in_cut := fade_in if fade_in > 0.0 else -1.0
	var inv_fade_in := 1.0 / fade_in if fade_in > 0.0 else 0.0
	var fade_out := pool.fade_out
	var fade_out_start := 1.0 - fade_out if fade_out > 0.0 else 2.0
	var inv_fade_out := 1.0 / fade_out if fade_out > 0.0 else 0.0
	var frames_f := float(pool.frames)
	var max_frame := frames_f - 1.0
	var move := delta > 0.0
	var buf := pool.buffer
	pool.buffer = _EMPTY_BUF
	var i := 0
	var o := 0
	while i < n:
		var c: Card = cards[i]
		var age := c.age + delta
		var life := c.life
		if age >= life:
			c.age = age
			n -= 1
			if i < n:
				cards[i] = cards[n]
			cards.pop_back()
			continue
		c.age = age
		var pos := c.pos
		var spin := c.spin
		if move:
			var vel := c.vel
			var rise := c.rise
			var drag := c.drag
			if rise != 0.0 or drag > 0.0:
				if rise != 0.0:
					vel.y += rise * delta
				if drag > 0.0:
					vel *= maxf(0.0, 1.0 - drag * delta)
				c.vel = vel
			if vel != Vector3.ZERO:
				pos += vel * delta
				c.pos = pos
			var sr := c.spin_rate
			if sr != 0.0:
				spin += sr * delta
				c.spin = spin
		var t := age / life
		var w := lerpf(c.size0, c.size1, t)
		var h := w * aspect
		var col := c.color
		var a := col.a
		if t < fade_in_cut:
			a *= t * inv_fade_in
		if t > fade_out_start:
			a *= (1.0 - t) * inv_fade_out
		var frame: float
		if cyclic:
			frame = fmod(c.frame + age * c.fps, frames_f)
		elif flat:
			frame = c.frame
		else:
			frame = minf(max_frame, t * frames_f)
		if flat:
			var ang := c.angle
			var cs := cos(ang)
			var sn := sin(ang)
			buf[o] = cs * w
			buf[o + 1] = -sn * h
			buf[o + 3] = pos.x
			buf[o + 7] = pos.y
			buf[o + 8] = -sn * w
			buf[o + 9] = -cs * h
			buf[o + 11] = pos.z
		else:
			buf[o] = w
			buf[o + 3] = pos.x
			buf[o + 5] = h
			buf[o + 7] = pos.y
			buf[o + 11] = pos.z
		buf[o + 12] = col.r
		buf[o + 13] = col.g
		buf[o + 14] = col.b
		buf[o + 15] = a
		buf[o + 16] = frame
		buf[o + 18] = spin
		i += 1
		o += 20
	pool.buffer = buf
	if n > 0:
		pool.mm.buffer = buf
		pool.mm.visible_instance_count = n
		pool.shown = n
	elif pool.shown != 0:
		pool.mm.visible_instance_count = 0
		pool.shown = 0


static func _load_sheet(file: String) -> Texture2D:
	var dir := SoundBank.data_dir()
	if dir == "":
		return null
	var path := dir.path_join("base/graphics/entity").path_join(file)
	if not FileAccess.file_exists(path):
		return null
	var image := Image.load_from_file(path)
	if image == null:
		return null
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


## A soft round blob in place of a missing sheet: white (tinted per card) for smoke and dust, a
## hot core for flashes, dark for scorch marks.
static func _blob(name: String) -> Texture2D:
	var size := 64
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var hot := name in ["hit", "muzzle", "sparks", "explosion", "small-explosion"]
	for y in size:
		for x in size:
			var d := Vector2(x + 0.5 - size * 0.5, y + 0.5 - size * 0.5).length() / (size * 0.5)
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a * (3.0 - 2.0 * a)
			var c := Color(1, 1, 1, a)
			if hot:
				c = Color(1.0, lerpf(0.95, 0.45, d), lerpf(0.7, 0.1, d), a)
			elif name == "roboport-charge":
				c = Color(lerpf(0.95, 0.25, d), lerpf(1.0, 0.78, d), 1.0, a)
			elif name == "scorch":
				c = Color(0.08, 0.07, 0.06, a * 0.8)
			image.set_pixel(x, y, c)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)
