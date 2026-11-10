extends RefCounted
## Buildings Zenith has no model of (a mod's), drawn with their own Factorio picture instead of a
## coloured box: the picture the bridge's list names for the entity at rest (mod_graphics.gd, `ents`)
## is composed from its layers, read from the mod's files (mod_files.gd), on a worker thread, and put
## on a card that faces Factorio's camera (pitched FACTORIO_PITCH down, from the south), squashed
## north-south as the ground is in that view, so from Factorio's view (F6) and the default camera it
## reads as Factorio's sprite over the building's footprint; the card casts the shadow. Each direction
## the list has gets its own card.
##
## Animated buildings (Settings > Graphics > Animate modded buildings): the part of the picture that
## moves (the animated layers and what a machine adds while working) is drawn at MAX_FRAMES evenly
## spaced moments of Factorio's loop into an atlas, at half size when it would be big, and the card's
## shader steps through it at Factorio's speed while the machine works (chunk_view.gd passes that in
## each instance's colour). The still picture is kept once.

const ModFiles := preload("res://scripts/world/mod_files.gd")
const ModGraphics := preload("res://scripts/world/mod_graphics.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")

const PX := 64.0  # pixels a tile in the composed picture (Factorio's high-resolution 0.5 scale)
const FACTORIO_PITCH := 48.0  # camera_rig.gd's
## Largest picture composed, in pixels each way (bigger ones are scaled down).
const MAX_PX := 2048
const DIR_KEYS := ["n", "e", "s", "w"]
const CARD_SHADER := preload("res://shaders/sprite_card.gdshader")
const GHOST_SHADER := preload("res://shaders/ghost_card.gdshader")
## Frames kept of an animation (evenly spaced over Factorio's loop, which keeps its speed).
const MAX_FRAMES := 16
## An atlas bigger than this at full size is kept at half size.
const HALF_ABOVE := 6 * 1024 * 1024
## Types that animate only while they work (the game's working state); others always do.
const WORKING_TYPES := {"assembling-machine": true, "furnace": true, "mining-drill": true, "lab": true,
	"boiler": true, "generator": true, "burner-generator": true, "reactor": true, "rocket-silo": true,
	"fusion-reactor": true, "fusion-generator": true, "agricultural-tower": true, "beacon": true}

const STILL_TYPES := {"tree": true, "simple-entity": true, "resource": true, "fish": true}
## Settings > Graphics > Animate modded buildings (settings.gd): off, cards are their still picture.
static var animate := true
## Bytes of the animation atlases made so far (measured by the tests and probes).
static var atlas_bytes := 0
static var _cleared := false

## Goes up when cards were made (world.gd draws chunks with placeholders again).
static var generation := 0
static var _cards := {}  # "name|n" -> Mesh, or null when it has no picture
static var _jobs := {}  # "name|n" -> [task id, the list's generation it was made from]
static var _made := {}  # "name|n" -> [Image, centre px] or null, written by workers
static var _mutex := Mutex.new()
static var _list_generation := -1


## Whether a graphics list is in use: chunk_view.gd then draws no boxes or cones, only pictures.
static func in_use() -> bool:
	return ModGraphics.fingerprint != ""


## The card for an entity facing a 16-way direction, or null: no picture, still being made
## (coming() says which), or its picture couldn't be read. An entity the list has no picture for
## shows its icon instead, standing on its footprint (`size`, in tiles).
static func card(name: String, direction: int, size := Vector2.ONE, type := "") -> Mesh:
	_follow_list()
	var rec = ModGraphics.ents.get(name)
	if not rec is Dictionary:
		return _icon_card(name, size) if in_use() else null
	var dir_key := _dir_key(rec, direction)
	var key := name + "|" + dir_key
	if _cards.has(key):
		return _cards[key]
	if not _jobs.has(key):
		var layers = rec.get(dir_key, rec.get("n"))  # a direction may differ only in its working layers
		if not layers is Array:
			_cards[key] = null
			return null
		var work = rec.get("k" + dir_key, rec.get("kn", []))
		ModFiles.prepare()
		# Trees and rocks stay still (their frames are variations, not motion).
		var moves := animate and not STILL_TYPES.has(type)
		_jobs[key] = [WorkerThreadPool.add_task(_compose.bind(key, layers, work if work is Array else [], moves)), _list_generation]
	return null


## Whether a card for it is being made (the chunk waits for it rather than drawing a box first).
static func coming(name: String, direction: int) -> bool:
	var rec = ModGraphics.ents.get(name)
	return rec is Dictionary and _jobs.has(name + "|" + _dir_key(rec, direction))


## Once a frame: turns finished pictures into cards. True when any were made.
static func poll() -> bool:
	var made := _follow_list() or _cleared  # a new list or a cleared cache: chunks ask for their cards again
	_cleared = false
	for key: String in _jobs.keys():
		var task: int = _jobs[key][0]
		if not WorkerThreadPool.is_task_completed(task):
			continue
		WorkerThreadPool.wait_for_task_completion(task)
		var stale: bool = _jobs[key][1] != _list_generation
		_jobs.erase(key)
		_mutex.lock()
		var got = _made.get(key)
		_made.erase(key)
		_mutex.unlock()
		if not stale:  # made from a list since replaced: asked for again from the new one
			_cards[key] = _card_mesh(got[0], got[1], got[2], got[3]) if got is Array else null
		made = true
	if made:
		generation += 1
	return made


## The direction key the list has for a 16-way direction (e, s, w only where they differ from n, in
## the picture or in what it adds while working).
static func _dir_key(rec: Dictionary, direction: int) -> String:
	var k: String = DIR_KEYS[posmod(int(round(direction / 4.0)), 4)]
	return k if rec.has(k) or rec.has("k" + k) else "n"


## A new list: cards made from the old one go.
static func _follow_list() -> bool:
	if _list_generation == ModGraphics.generation:
		return false
	_list_generation = ModGraphics.generation
	_cards.clear()
	generation += 1
	return true


## Worker thread: the layers [file, x, y, w, h, scale, shift x, shift y, tint, anim?] drawn into one
## picture at PX pixels a tile, each centred on the entity's centre moved by its shift, as Factorio
## draws them; and, for an animated building, its moving part at MAX_FRAMES moments of its loop.
static func _compose(key: String, layers: Array, work: Array, with_anim: bool) -> void:
	var t0 := Time.get_ticks_msec()
	var sheets := {}
	var placed: Array = []  # [layer, top-left (px, from the entity's centre), size px, while working]
	var lo := Vector2(INF, INF)
	var hi := -Vector2(INF, INF)
	var px := PX  # pixels a tile here: less for a picture bigger than MAX_PX, which is scaled to fit
	for attempt in 2:
		placed.clear()
		lo = Vector2(INF, INF)
		hi = -Vector2(INF, INF)
		for list in [[layers, false], [work if with_anim else [], true]]:
			for layer in list[0]:
				if not layer is Array or (layer as Array).size() < 8:
					continue
				var k := float(layer[5]) * px / 32.0  # source pixels to ours: 32 px a tile at scale 1
				var size := Vector2i(maxi(1, roundi(float(layer[3]) * k)), maxi(1, roundi(float(layer[4]) * k)))
				var at := Vector2(float(layer[6]), float(layer[7])) * px - Vector2(size) * 0.5
				placed.append([layer, at, size, list[1]])
				lo = lo.min(at)
				hi = hi.max(at + Vector2(size))
		var extent := maxf(hi.x - lo.x, hi.y - lo.y)
		if placed.is_empty() or extent <= MAX_PX:
			break
		px = PX * MAX_PX / extent
	var got = null
	if not placed.is_empty():
		var w := mini(ceili(hi.x - lo.x), MAX_PX)
		var h := mini(ceili(hi.y - lo.y), MAX_PX)
		var canvas := Image.create_empty(maxi(w, 1), maxi(h, 1), false, Image.FORMAT_RGBA8)
		var drew := false
		for p in placed:
			if not p[3]:
				drew = _draw_layer(canvas, p, -lo, str(p[0][0]), int(p[0][1]), int(p[0][2]), sheets) or drew
		if drew:
			var anim = _animate(placed, lo, canvas.get_size(), sheets) if with_anim else null
			canvas.fix_alpha_edges()
			canvas.generate_mipmaps()
			got = [canvas, -lo, anim, px]  # the entity's centre in the picture, in pixels
			if anim is Dictionary:
				var atlas: Image = anim.atlas
				print_verbose("Stand-in: %s animated, %d frames, %d x %d, %d KB, %d ms" % [key, anim.frames, atlas.get_width(), atlas.get_height(),
					atlas.get_data().size() / 1024, Time.get_ticks_msec() - t0])
	_mutex.lock()
	_made[key] = got
	_mutex.unlock()


## One layer's region of its sheet (file, x, y) drawn into `into` at the layer's place moved by `by`.
static func _draw_layer(into: Image, p: Array, by: Vector2, file: String, x: int, y: int, sheets: Dictionary, scale := 1.0) -> bool:
	var sheet: Image = sheets.get(file)
	if sheet == null:
		sheet = ModFiles.load_image(file)
		if sheet == null:
			return false
		sheet.convert(Image.FORMAT_RGBA8)
		sheets[file] = sheet
	var layer: Array = p[0]
	var r := Rect2i(x, y, int(layer[3]), int(layer[4])).intersection(Rect2i(Vector2i.ZERO, sheet.get_size()))
	if r.size.x <= 0 or r.size.y <= 0:
		return false
	var img := sheet.get_region(r)
	var size := Vector2i(maxi(1, roundi(p[2].x * scale)), maxi(1, roundi(p[2].y * scale)))
	if size != img.get_size():
		img.resize(size.x, size.y, Image.INTERPOLATE_BILINEAR)
	if layer.size() > 8 and layer[8] is Array:
		_tint(img, layer[8])
	var at: Vector2 = (p[1] + by) * scale
	into.blend_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i(roundi(at.x), roundi(at.y)))
	return true


## The moving part's atlas, or null when nothing moves: {atlas, rect (in the picture, 0-1), cols,
## rows, frames, loop (seconds)}. Every layer is drawn into each frame within the rectangle that
## the animated layers cover, so their order with the still ones is kept.
static func _animate(placed: Array, lo: Vector2, canvas_size: Vector2i, sheets: Dictionary):
	var rect := Rect2()
	var speed := 0.0
	for p in placed:
		var a = _anim(p[0])
		if a == null and not p[3]:
			continue
		var r := Rect2(p[1] - lo, Vector2(p[2]))
		rect = r if rect.size == Vector2.ZERO else rect.merge(r)
		if a != null and speed <= 0.0 and not p[3]:
			speed = float(a.get("s", 1.0))
	if rect.size == Vector2.ZERO:
		return null
	rect = rect.intersection(Rect2(Vector2.ZERO, Vector2(canvas_size)))
	if rect.size.x < 1.0 or rect.size.y < 1.0:
		return null
	if speed <= 0.0:
		for p in placed:
			var a = _anim(p[0])
			if a != null:
				speed = float(a.get("s", 1.0))
				break
	if speed <= 0.0:
		speed = 1.0
	# The loop: the longest layer's, in the main animation's frames.
	var cycle := 1
	for p in placed:
		var a = _anim(p[0])
		if a != null:
			cycle = maxi(cycle, roundi(_steps(a) * speed / maxf(float(a.get("s", 1.0)), 0.001)))
	cycle = mini(cycle, 1024)
	var n := mini(MAX_FRAMES, cycle)
	if n <= 1:
		return null
	var size := Vector2i(ceili(rect.size.x), ceili(rect.size.y))
	var scale := 0.5 if size.x * size.y * n * 4 > HALF_ABOVE else 1.0
	var fsize := Vector2i(maxi(1, ceili(size.x * scale)), maxi(1, ceili(size.y * scale)))
	var cols := ceili(sqrt(float(n)))
	var rows := ceili(float(n) / cols)
	var atlas := Image.create_empty(cols * fsize.x, rows * fsize.y, false, Image.FORMAT_RGBA8)
	for i in n:
		var g := int(floor(float(i) * cycle / n))
		var frame := Image.create_empty(fsize.x, fsize.y, false, Image.FORMAT_RGBA8)
		for p in placed:
			var layer: Array = p[0]
			var a = _anim(layer)
			var src := [str(layer[0]), int(layer[1]), int(layer[2])]
			if a != null:
				src = _frame_src(layer, a, int(floor(g * float(a.get("s", 1.0)) / speed)))
			_draw_layer(frame, p, -lo - rect.position, src[0], src[1], src[2], sheets, scale)
		atlas.blit_rect(frame, Rect2i(Vector2i.ZERO, fsize), Vector2i((i % cols) * fsize.x, (i / cols) * fsize.y))
	atlas.fix_alpha_edges()
	atlas.generate_mipmaps()
	_mutex.lock()
	atlas_bytes += atlas.get_data().size()
	_mutex.unlock()
	var cs := Vector2(canvas_size)
	return {"atlas": atlas, "rect": Rect2(rect.position / cs, rect.size / cs), "cols": cols, "rows": rows,
		"frames": n, "loop": float(cycle) / (60.0 * speed)}


static func _anim(layer: Array):
	return layer[9] if layer.size() > 9 and layer[9] is Dictionary else null


## Frames in one run of a layer's animation (forward-then-backward plays back without its ends).
static func _steps(a: Dictionary) -> int:
	var steps := (a.q as Array).size() if a.get("q") is Array else maxi(1, int(a.get("f", 1)))
	if str(a.get("m", "")) == "forward-then-backward":
		return maxi(1, steps * 2 - 2)
	return steps


## Where frame `g` of a layer's loop lies: [file, x, y].
static func _frame_src(layer: Array, a: Dictionary, g: int) -> Array:
	var steps := (a.q as Array).size() if a.get("q") is Array else maxi(1, int(a.get("f", 1)))
	var i := posmod(g, _steps(a))
	match str(a.get("m", "")):
		"forward-then-backward":
			if i >= steps:
				i = _steps(a) - i
		"backward":
			i = steps - 1 - i
	var frame := int(a.q[i]) - 1 if a.get("q") is Array else i
	var index := int(a.get("o", 0)) + frame
	var w := int(layer[3])
	var h := int(layer[4])
	var line := int(a.get("l", 0))
	if a.get("fs") is Array:
		var fs: Array = a.fs
		if line <= 0:
			line = maxi(1, int(a.get("f", 1)))
		var per := line * maxi(1, int(a.get("p", 1)))
		var local := index % per
		return [str(fs[mini(index / per, fs.size() - 1)]), (local % line) * w, (local / line) * h]
	if a.get("st") is Array:
		var local := index
		for st in a.st:
			var across := maxi(1, int(st[1]))
			var count := across * maxi(1, int(st[2]))
			if local < count:
				return [str(st[0]), int(st[3]) + (local % across) * w, int(st[4]) + (local / across) * h]
			local -= count
		var last: Array = a.st[a.st.size() - 1]
		return [str(last[0]), int(last[3]), int(last[4])]
	if line <= 0:
		return [str(layer[0]), int(a.get("x", 0)) + index * w, int(a.get("y", 0))]
	return [str(layer[0]), int(a.get("x", 0)) + (index % line) * w, int(a.get("y", 0)) + (index / line) * h]


## The entity's icon (its item's, or the list's entity icon) on a card as wide as the smaller side
## of its footprint, standing on its middle.
static func _icon_card(name: String, size: Vector2) -> Mesh:
	var key := name + "|icon"
	if _cards.has(key):
		return _cards[key]
	var tex := ItemIcons.texture_for(name)
	if tex == null:
		tex = ItemIcons.texture_for_kind("entity", name)
	var mesh: Mesh = null
	if tex != null:
		var img := tex.get_image()
		if img != null and not img.is_empty():
			img = img.duplicate()
			img.clear_mipmaps()
			img.convert(Image.FORMAT_RGBA8)
			var px := maxi(16, roundi(clampf(minf(size.x, size.y), 0.5, 4.0) * 0.9 * PX))
			img.resize(px, px, Image.INTERPOLATE_LANCZOS)
			img.generate_mipmaps()
			mesh = _card_mesh(img, Vector2(px * 0.5, px * 0.85), null, PX)
	_cards[key] = mesh
	return mesh


## Factorio's tint: the picture multiplied by it.
static func _tint(img: Image, t: Array) -> void:
	var c := Color(float(t[0]), float(t[1]), float(t[2]), float(t[3]) if t.size() > 3 else 1.0)
	var data := img.get_data()
	var k := [c.r, c.g, c.b, c.a]
	for i in data.size():
		data[i] = mini(255, int(data[i] * k[i % 4]))
	img.set_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8, data)


## The card: a quad facing Factorio's camera through the entity's centre on the ground, moved
## towards the camera along its own facing (which Factorio's view doesn't see) so none of it is
## under the ground. Its picture's rows are squashed by sin(pitch), as the ground's are.
static func _card_mesh(image: Image, centre: Vector2, anim, px: float) -> Mesh:
	var squash := sin(deg_to_rad(FACTORIO_PITCH))
	var size := Vector2(image.get_width(), image.get_height()) / px
	var quad := QuadMesh.new()
	quad.size = Vector2(size.x, size.y * squash)
	var offset := Vector2(size.x * 0.5 - centre.x / px, (centre.y / px - size.y * 0.5) * squash)
	var bottom := offset.y - quad.size.y * 0.5
	var pitch := deg_to_rad(FACTORIO_PITCH)
	var lift := maxf(0.0, (0.02 - bottom * cos(pitch)) / sin(pitch))
	quad.center_offset = Vector3(offset.x, offset.y, lift)
	var mat := ShaderMaterial.new()
	mat.shader = CARD_SHADER  # cut out, both sides, lifted onto an add-on's hills
	mat.set_shader_parameter("picture", ImageTexture.create_from_image(image))
	if anim is Dictionary:
		var r: Rect2 = anim.rect
		mat.set_shader_parameter("frames", ImageTexture.create_from_image(anim.atlas))
		mat.set_shader_parameter("frames_rect", Vector4(r.position.x, r.position.y, r.size.x, r.size.y))
		mat.set_shader_parameter("frames_grid", Vector3(anim.cols, anim.rows, anim.frames))
		mat.set_shader_parameter("frames_loop", float(anim.loop))
		mat.set_shader_parameter("animated", true)
	quad.material = mat
	return quad


## The transform a card is drawn with: at the entity's centre, turned to face Factorio's camera
## whatever the entity's direction (the direction picks the picture).
static func transform(pos: Vector2) -> Transform3D:
	return Transform3D(Basis(Vector3.RIGHT, -deg_to_rad(FACTORIO_PITCH)), Vector3(pos.x, 0.0, pos.y))


## Whether a card steps through frames (chunk_view.gd tells it when, per instance).
static func is_animated(card: Mesh) -> bool:
	var mat := (card as PrimitiveMesh).material as ShaderMaterial if card is PrimitiveMesh else null
	return mat != null and mat.get_shader_parameter("animated") == true


## An instance's colour for the card's shader: red 1 while it animates, green its phase in the
## loop (so a row of machines doesn't move in step), from where it stands.
static func instance_color(running: bool, pos: Vector2) -> Color:
	return Color(1.0 if running else 0.0, float(hash(pos) & 0xffff) / 65536.0, 0.0, 1.0)


## Forgets every card (tests, and when Animate modded buildings is switched).
static func clear() -> void:
	for job in _jobs.values():
		WorkerThreadPool.wait_for_task_completion(job[0])
	_jobs.clear()
	_made.clear()
	_cards.clear()
	_ghost_materials.clear()
	_cleared = true


## A card drawn as a ghost or the build preview (ghosts.gd, player_input.gd): its picture in the
## ghost's translucent `tint`, one material per card and tint.
static var _ghost_materials := {}  # [card, tint] -> ShaderMaterial
static func ghost_material(card: Mesh, tint: Color) -> ShaderMaterial:
	var key := [card, tint]
	var m: ShaderMaterial = _ghost_materials.get(key)
	if m == null:
		m = ShaderMaterial.new()
		m.shader = GHOST_SHADER
		var source := (card as PrimitiveMesh).material as ShaderMaterial if card is PrimitiveMesh else null
		if source != null:
			m.set_shader_parameter("picture", source.get_shader_parameter("picture"))
		m.set_shader_parameter("tint", tint)
		_ghost_materials[key] = m
	return m
