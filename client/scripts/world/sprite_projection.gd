extends RefCounted
## Factorio's own sprite frame of an entity, cut from the player's install at runtime (like item
## icons; nothing of Wube's is copied into this repo), for drawing it flat in the UI: the blueprint
## window's preview (blueprint_window.gd). res://data/sprite_projection.json says which frame of
## which sheet belongs to which entity and where its anchor is (written by
## tools/models/sprite_projection.py, format in assets/models/README.md; the model tools read it
## too). Models used to wear these frames projected onto them (the "sprite" model look); that look
## is gone, so nothing here touches a model.
##
## Factorio draws an entity's sprite 32 / scale pixels per tile, the frame's centre at the entity's
## position plus its shift. A sheet's cells (one per direction it can face, or one per variation)
## go side by side in one atlas texture, each with its anchor's pixel position.

const ItemIcons := preload("res://scripts/world/item_icons.gd")

const DATA := "res://data/sprite_projection.json"
const MAX_CELLS := 8
## Pixels round each cell, so blurred (mipmapped) lookups don't pick up the next cell.
const PAD := 32
const MODES := {"direction": 1, "variation": 2, "rotation": 3}

static var _entries := {}
static var _loaded := false
static var _sheets := {}  # file -> Image, while building one entity's sheet


class SpriteSheet:
	var texture: ImageTexture
	var mode := 0  # 0: one cell, 1: a cell per direction (N, E, S, W), 2: a cell per variation,
	# 3: a frame per step round the turn (vehicles: not cut here)
	var cells := 1
	var anchors := PackedVector2Array()  # each cell's anchor in atlas pixels
	var atlas_size := Vector2.ONE
	var px_per_tile := 64.0


## An entity's sheet for drawing it flat in the UI (the blueprint window's preview): null without
## an entry or a Factorio install, and for vehicles (their frames round the turn aren't cut here).
static var _flat_cache := {}


static func for_flat(name: String) -> SpriteSheet:
	if _flat_cache.has(name):
		return _flat_cache[name]
	_load()
	var p: SpriteSheet = null
	var entry: Dictionary = _entries.get(name, {})
	if not entry.is_empty() and MODES.get(str(entry.get("mode", "")), 0) != 3 and ItemIcons.factorio_data_dir() != "":
		p = _build(entry)
		_sheets.clear()
	_flat_cache[name] = p
	return p


static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(DATA):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(DATA))
	if parsed is Dictionary:
		_entries = parsed


static func _build(entry: Dictionary) -> SpriteSheet:
	var p := SpriteSheet.new()
	p.mode = MODES.get(str(entry.get("mode", "")), 0)
	var cells: Array = entry.get("cells", [])
	if cells.is_empty() or cells.size() > MAX_CELLS:
		return null
	# Each cell: its layers stacked on one canvas, and where the anchor is on it.
	var canvases: Array[Image] = []
	var anchors: Array[Vector2] = []
	var slot := Vector2i.ZERO
	var scale := float(entry.get("atlas_scale", 1.0))
	for cell in cells:
		var layers: Array = cell
		var composed := _compose(layers)
		if composed.is_empty():
			return null
		if scale != 1.0:
			var c: Image = composed[0]
			c.resize(maxi(1, int(c.get_width() * scale)), maxi(1, int(c.get_height() * scale)), Image.INTERPOLATE_BILINEAR)
			composed[1] *= scale
			composed[2] *= scale
		canvases.append(composed[0])
		anchors.append(composed[1])
		p.px_per_tile = composed[2]
		slot.x = maxi(slot.x, composed[0].get_width() + 2 * PAD)
		slot.y = maxi(slot.y, composed[0].get_height() + 2 * PAD)
	var atlas := Image.create(slot.x * canvases.size(), slot.y, false, Image.FORMAT_RGBA8)
	for i in canvases.size():
		var canvas := canvases[i]
		var at := Vector2i(slot.x * i + PAD, PAD)
		atlas.blend_rect(canvas, Rect2i(Vector2i.ZERO, canvas.get_size()), at)
		p.anchors.append(Vector2(at) + anchors[i])
	p.cells = canvases.size()
	p.atlas_size = Vector2(atlas.get_size())
	# Transparent pixels take their neighbours' colour, so filtering doesn't darken the outline.
	atlas.fix_alpha_edges()
	atlas.generate_mipmaps()
	p.texture = ImageTexture.create_from_image(atlas)
	return p


## [canvas Image, anchor position on it (pixels), pixels per tile], or [] if a sheet is missing.
static func _compose(layers: Array) -> Array:
	var frames: Array[Image] = []
	var offsets: Array[Vector2] = []
	var ppt := 64.0
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for item in layers:
		var layer: Dictionary = item
		var frame := _frame(layer)
		if frame == null:
			return []
		ppt = 32.0 / float(layer.get("scale", 0.5))
		var shift: Array = layer.get("shift", [0, 0])
		# The frame's centre is the anchor plus the shift (util.by_pixel units: 1/32 tile).
		var centre := Vector2(float(shift[0]), float(shift[1])) * ppt / 32.0
		var size := Vector2(frame.get_size())
		frames.append(frame)
		offsets.append(centre - size / 2.0)
		lo = lo.min(centre - size / 2.0)
		hi = hi.max(centre + size / 2.0)
	var canvas := Image.create(int(ceil(hi.x - lo.x)), int(ceil(hi.y - lo.y)), false, Image.FORMAT_RGBA8)
	for i in frames.size():
		var at := Vector2i((offsets[i] - lo).round())
		canvas.blend_rect(frames[i], Rect2i(Vector2i.ZERO, frames[i].get_size()), at)
	return [canvas, -lo, ppt]


## The frame's rectangle on its sheet: `xy` (pixels) when given, else `index` in a grid of
## `line` frames a row. `sheet_width` is needed only when `line` is 0 (as many as fit).
static func _frame_rect(layer: Dictionary, sheet_width: int) -> Rect2i:
	var size: Array = layer.get("frame", [0, 0])
	var w := int(size[0])
	var h := int(size[1])
	if layer.has("xy"):
		var xy: Array = layer["xy"]
		return Rect2i(int(xy[0]), int(xy[1]), w, h)
	var line := int(layer.get("line", 0))
	if line <= 0:
		line = maxi(1, sheet_width / maxi(w, 1))
	var index := int(layer.get("index", 0))
	return Rect2i((index % line) * w, (index / line) * h, w, h)


static func _frame(layer: Dictionary) -> Image:
	var sheet := _sheet(str(layer.get("file", "")))
	if sheet == null:
		return null
	var rect := _frame_rect(layer, sheet.get_width())
	if rect.size.x <= 0 or rect.size.y <= 0 or not Rect2i(Vector2i.ZERO, sheet.get_size()).encloses(rect):
		return null
	var frame := sheet.get_region(rect)
	if layer.has("tint"):
		_tint(frame, layer["tint"])
	return frame


static func _sheet(file: String) -> Image:
	if _sheets.has(file):
		return _sheets[file]
	var path := ItemIcons.factorio_data_dir().path_join(file)
	var image: Image = null
	if FileAccess.file_exists(path):
		image = Image.load_from_file(path)
		if image != null:
			image.convert(Image.FORMAT_RGBA8)
	_sheets[file] = image
	return image


## Multiplies the colour (as the game tints a tree's leaves).
static func _tint(image: Image, tint: Array) -> void:
	var data := image.get_data()
	var t := [float(tint[0]), float(tint[1]), float(tint[2])]
	for i in range(0, data.size(), 4):
		data[i] = int(data[i] * t[0])
		data[i + 1] = int(data[i + 1] * t[1])
		data[i + 2] = int(data[i + 2] * t[2])
	image.set_data(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8, data)
