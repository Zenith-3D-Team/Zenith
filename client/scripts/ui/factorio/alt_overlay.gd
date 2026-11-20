extends Control
## Factorio's Alt-mode (Alt): over each machine in view the icon of what it is set to make or let
## through (an assembler's or furnace's recipe, an inserter's, splitter's or storage chest's
## filter), from its record's `extra.ai` (issue #9: every machine the client has loaded, kept per
## chunk in ChunkView.alt and changed by `aiu`), over each chest without such an icon what it holds
## most of (world.gd's alt_contents from `ac`, J6: up to four kinds in a grid, as Factorio's Alt-mode
## shows container contents), in rows over machines their modules, over labs their science packs,
## over ammo turrets their ammo, over cargo wagons their most-stacked kinds and over locomotives their fuel (off unless asked)
## (world.gd's alt_machines from `am`, K1, K2), and on every pipe, underground pipe, pump and
## tank the icon of the fluid in it (fluids_power.gd's `fl`). Where each goes is Factorio's own: an
## entity's icon by its prototype's icon_draw_specification (`eprops` ids: a shift from its centre
## and a scale), the rows by its icons_positioning (`eprops` isq, sequence_cells). As in Factorio the icons have no
## disc behind them, only a soft dark shadow, and are drawn flat over the world at the entity's
## position projected through the camera, sized with the zoom. Only chunks in the camera's view
## are looked at. Where icons overlap on the screen the one nearest the camera is drawn in front
## (`icon_order`): each icon goes into the first layer after every farther icon it overlaps, and each
## layer draws its shadows, then its icons picture by picture, so the canvas still batches them (a
## shadow between two icons would split every batch); icons that overlap nothing are all in the first.
##
## factorio_ui.gd sets `player` (player_input.gd: its world mirror and camera rig).

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const Slot := preload("res://scripts/ui/factorio/slot.gd")
const WorldMirror := preload("res://scripts/world/world.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const DepthIcon := preload("res://shaders/billboard_icon_depth.gdshader")
const GroundHeight := preload("res://scripts/world/ground_height.gd")

## The icon is this many tiles across (measured on Factorio's alt-mode over assemblers).
const ICON_TILES := 1.2
## Over a chest: Factorio scales a chest's icons by its prototype's icon_draw_specification, 0.7 on
## every chest of the base game (wooden to steel, the five logistic chests).
const CHEST_TILES := ICON_TILES * 0.7
const CHEST_TYPES := ["container", "logistic-container", "infinity-container", "linked-container"]
## A fluid's icon on a pipe.
const FLUID_TILES := 0.55
const FLUID_TYPES := ["pipe", "pipe-to-ground", "pump", "storage-tank", "infinity-pipe"]
## Plain pipes carry the icon only now and then, as Factorio's Alt-mode (owner's P50: one on every
## pipe covered a run). One tile in this many, on a slanted lattice (`pipe_shows_icon`).
const PIPE_ICON_EVERY := 5
const SPARSE_FLUID_TYPES := ["pipe", "infinity-pipe"]
const SHADOW := Color(0, 0, 0, 0.6)
## A module's or science pack's icon at its row's scale 1 is this many tiles across. Factorio's own
## rows fit at 1: Space Age's lab puts six packs a row at scale 0.5 and separation 1/1.1 over its
## three tiles, with its modules' row under them (larger, the rows would overflow and overlap).
const SEQUENCE_TILE := 1.0
## Its quality's mark, at the icon's bottom left, this share of its side (as in a slot).
const QUALITY_SHARE := 0.4
## Beacons draw their modules only while the mouse is on them (Factorio 2.1.8's changelog).
const HOVER_ONLY_TYPES := ["beacon"]
## --alt-icon-spec=off: every machine's own icon centred at ICON_TILES as before K1 (eprops ids unread).
static var use_spec := true
## --alt-ammo-fuel=off: no ammo over turrets, fuel over locomotives or cargo over wagons, as before (isq's "a", "f" and "c" rows unread).
## Locomotives' fuel is off by default (owner: only the wagons' cargo matters); --loco-fuel-icons=on (Bridge.loco_fuel_icons) brings it back.
static var ammo_fuel := true
## --alt-icon-order=old: every shadow first, then the icons picture by picture in the order they were
## found, whichever is nearer (an icon further off could cover a nearer one: the owner's column of
## assemblers' recipes, the farthest in front); in first person a machine's own cells at one depth.
static var icon_order := true
## First person: each cell of a machine's icons sorts this much nearer the camera than the one
## before (sorting_offset), so the transparent sort puts its lower rows in front.
const QUAD_STEP := 0.001
## The inventory a row's kind shows (`eprops` isq): which of an `am` entry's two lists.
const KIND_LIST := {"m": 0, "l": 1, "a": 1, "f": 1, "c": 1}
const STOCK_KINDS := ["a", "f", "c"]
static var _args_read := false

var model
var player: Node = null
var on := false

var _shadow: Texture2D
## First person: the icons as 3D quads with the depth test on, so buildings in front hide them
## (from above, nothing stands between the camera and an icon). Pooled; a material per picture.
var _quads: Array[MeshInstance3D] = []
var _quad_holder: Node3D
var _quad_materials := {}  # Texture2D -> ShaderMaterial
var _quads_used := 0
## First person, this frame: each machine's (its icons' point across the ground) [distance its
## cells sort at, cells placed so far].
var _quad_machines := {}
## The remote view's fog (the player's remote_fog): no icons for what no radar sees (G18).
var _fog: Node = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = Kit.ICON_FILTER
	# Factorio's icon shadow: a soft dark blur, darkest in the middle.
	var g := Gradient.new()
	g.set_color(0, SHADOW)
	g.set_color(1, Color(0, 0, 0, 0))
	g.add_point(0.55, Color(0, 0, 0, SHADOW.a * 0.75))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 64
	t.height = 64
	_shadow = t


func _process(_delta: float) -> void:
	if on:
		queue_redraw()
	elif _quads_used > 0 or (not _quads.is_empty() and _quads[0].visible):
		_quads_used = 0
		_hide_quads()


func _draw() -> void:
	collect()
	if icon_order:
		if not _layers_now:
			return
		if _flat:
			for i in _order:
				draw_texture_rect(_shadow, _e_shadow[i], false)
			for i in _order:  # each mark with its icon, so a farther one's stays under a nearer icon
				draw_texture_rect(_e_tex[i], _e_rect[i], false)
				if _e_mark[i] != null:
					draw_texture_rect(_e_mark[i], _e_mark_rect[i], false)
			return
		for l in _layers_used:
			var layer: Array = _layers[l]
			for i in layer[0]:
				draw_texture_rect(_shadow, _e_shadow[i], false)
			for texture in layer[1]:
				for i in layer[1][texture]:
					draw_texture_rect(texture, _e_rect[i], false)
			for i in layer[0]:
				if _e_mark[i] != null:
					draw_texture_rect(_e_mark[i], _e_mark_rect[i], false)
		return
	for rect in _shadows:
		draw_texture_rect(_shadow, rect, false)
	for texture in _icons:
		for rect in _icons[texture]:
			draw_texture_rect(texture, rect, false)
	for texture in _marks:
		for rect in _marks[texture]:
			draw_texture_rect(texture, rect, false)


## Works out this frame's icons (first person: places the quads) into _shadows, _icons and _marks.
func collect() -> void:
	_read_args()
	_quads_used = 0
	_marks_3d = 0
	_shadows.clear()
	_icons.clear()
	_marks.clear()
	_e_sum = 0.0
	_e_hash = 0
	_quad_machines.clear()
	_layers_now = false
	_e_depth.clear()
	_e_shadow.clear()
	_e_rect.clear()
	_e_tex.clear()
	_e_mark.clear()
	_e_mark_rect.clear()
	drawn = 0
	if not on or model == null or player == null:
		_hide_quads()
		return
	var world = player.get("world")
	var rig = player.get("rig")
	if world == null or rig == null:
		_hide_quads()
		return
	var camera: Camera3D = rig.camera
	_in_3d = bool(rig.get("first_person"))
	_fog = player.get("remote_fog")
	var planes := camera.get_frustum()
	for c in world.chunks:
		var cv = world.chunks[c]
		if cv.alt.is_empty() or not _chunk_in_view(c, planes):
			continue
		for key in cv.alt:
			var r: WorldMirror.Rec = cv.alt[key]
			var icon := WorldMirror.alt_icon(r)
			if icon.is_empty():
				continue
			var textures: Array[Texture2D] = []
			for i in range(1, icon.size()):  # a filter inserter's filters, every one
				textures.append(Kit.item_icon(str(icon[i])))
			var spec := _spec_for(r)
			var tiles: float = ICON_TILES * spec[1] if not spec.is_empty() else _tiles_for(world, r)
			_draw_icon(world, camera, r, textures, tiles, spec[0] if not spec.is_empty() else Vector2.ZERO)
	_draw_contents(world, camera, planes)
	_draw_sequences(world, camera, planes)
	var parent: Node = world.get_parent()
	var fluids_layer = parent.get_node_or_null("FluidsPower") if parent != null else null
	if fluids_layer != null:
		_draw_fluids(world, camera, fluids_layer)
	if icon_order and not _in_3d:
		_build_layers(camera)
	drawn = _shadows.size() + _quads_used - _marks_3d
	_hide_quads()


static func _read_args() -> void:
	if _args_read:
		return
	_args_read = true
	use_spec = not OS.get_cmdline_user_args().has("--alt-icon-spec=off")
	ammo_fuel = not OS.get_cmdline_user_args().has("--alt-ammo-fuel=off")
	icon_order = not OS.get_cmdline_user_args().has("--alt-icon-order=old")


## [shift (tiles from the centre, right and down), scale] of the entity's own icon from its
## prototype's icon_draw_specification (`eprops` ids), or [] when the bridge sent none (the default,
## or a bridge from before K1).
func _spec_for(r: WorldMirror.Rec) -> Array:
	if not use_spec or model == null:
		return []
	var ids = (_overlay_of(r.proto_id)).get("ids")
	if not (ids is Array) or ids.size() < 3:
		return []
	return [Vector2(float(ids[0]), float(ids[1])), maxf(float(ids[2]), 0.05)]


func _overlay_of(proto_id: int) -> Dictionary:
	var ep = model.eprops.get(proto_id)
	if not (ep is Dictionary):
		return {}
	var x = ep.get("x")
	return x if x is Dictionary else {}


## Whether a chunk's box (the ground up to 8 tiles) is at least partly inside the camera's frustum.
static func _chunk_in_view(c: Vector2i, planes: Array[Plane]) -> bool:
	# An add-on's hills (ground_height.gd) lift the icons with the buildings under them, by no more
	# than the field's range.
	var lift := GroundHeight.lift_range()
	var lo := Vector3(c.x * 32.0, -1.0 + lift.x, c.y * 32.0)
	var hi := lo + Vector3(32.0, 9.0 + lift.y - lift.x, 32.0)
	for plane in planes:
		# The box's corner furthest into the frustum (against the plane's outward normal).
		var n := plane.normal
		var p := Vector3(lo.x if n.x > 0.0 else hi.x, lo.y if n.y > 0.0 else hi.y, lo.z if n.z > 0.0 else hi.z)
		if plane.distance_to(p) > 0.0:
			return false
	return true


## A chest's icons are smaller than a machine's (CHEST_TILES).
static func _tiles_for(world, r: WorldMirror.Rec) -> float:
	var proto = world.protos.entity(r.proto_id)
	return CHEST_TILES if proto != null and CHEST_TYPES.has(proto.type) else ICON_TILES


## The chests' contents (J6) over those in view without an icon of their own (a requester's requests
## and a storage chest's filter come first, as in Factorio).
func _draw_contents(world, camera: Camera3D, planes: Array[Plane]) -> void:
	if not world.has_method("alt_contents_now"):
		return
	var contents: Dictionary = world.alt_contents_now()
	if contents.is_empty():
		return
	var in_view := {}  # chunk -> whether it is, this frame
	for unit in contents:
		var r: WorldMirror.Rec = world.entities.get(unit)
		if r == null or not WorldMirror.alt_icon(r).is_empty():
			continue
		if not in_view.has(r.chunk):
			in_view[r.chunk] = _chunk_in_view(r.chunk, planes)
		if not bool(in_view[r.chunk]):
			continue
		var textures: Array[Texture2D] = []
		for item in contents[unit]:
			textures.append(Kit.item_icon(str(item)))
		var spec := _spec_for(r)
		_draw_icon(world, camera, r, textures, ICON_TILES * spec[1] if not spec.is_empty() else CHEST_TILES,
			spec[0] if not spec.is_empty() else Vector2.ZERO)


## The modules in machines, the science packs in labs (K1, K2), the ammo in ammo turrets and the
## fuel in locomotives, in rows laid out by their prototype's icons_positioning (`eprops` isq); a
## beacon's only while the mouse is on it. A locomotive is a mover, not a record: its icons are
## drawn where it is drawn now.
func _draw_sequences(world, camera: Camera3D, planes: Array[Plane]) -> void:
	if not world.has_method("alt_machines_now"):
		return
	var shown: Dictionary = world.alt_machines_now()
	if shown.is_empty():
		return
	var hovered = player.get("hovered")
	var movers = player.get("movers")
	var in_view := {}
	for unit in shown:
		var r: WorldMirror.Rec = world.entities.get(unit)
		var proto_id := 0
		var chunk := Vector2i.ZERO
		var moving = null  # a mover's place as drawn (Vector3)
		if r != null:
			proto_id = r.proto_id
			chunk = r.chunk
		elif movers != null and movers.has_method("proto_id_of"):
			proto_id = movers.proto_id_of(unit)
			moving = movers.position_of(unit) if proto_id > 0 else null
			if not (moving is Vector3) or movers.is_fogged(unit):
				continue
			chunk = Vector2i(floori(moving.x / 32.0), floori(moving.z / 32.0))
		else:
			continue
		var proto = world.protos.entity(proto_id)
		if proto == null or (HOVER_ONLY_TYPES.has(proto.type) and hovered != r):
			continue
		var isq = _overlay_of(proto_id).get("isq")
		if not (isq is Array):
			continue
		if not in_view.has(chunk):
			in_view[chunk] = _chunk_in_view(chunk, planes)
		if not bool(in_view[chunk]):
			continue
		var lists: Array = shown[unit]
		var spec := _spec_for(r) if r != null else []
		var ref: float = ICON_TILES * (spec[1] if not spec.is_empty() else 1.0)
		for row in isq:
			if not (row is Array) or row.size() < 8:
				continue
			var kind := str(row[0])
			if not KIND_LIST.has(kind) or (STOCK_KINDS.has(kind) and not ammo_fuel) or (kind == "f" and not Bridge.loco_fuel_icons):
				continue
			var items: Array = lists[int(KIND_LIST[kind])]
			if items.is_empty():
				continue
			var cells := sequence_cells(items.size(), row)
			var textures: Array[Texture2D] = []
			var qualities: Array[String] = []
			for i in cells.size():
				textures.append(Kit.item_icon(str(items[i][0])))
				qualities.append(str(items[i][1]))
			if r != null:
				_draw_cells(world, camera, r, textures, cells, ref, qualities)
			else:
				var at: Vector3 = moving
				_draw_cells_at(world, camera, Vector2(at.x, at.z), at.y + Visuals.height_for(proto), textures, cells, ref, qualities)


## Where Factorio's IconSequencePositioning `row` ([kind, shift x, shift y, scale, icons a row, rows,
## separation, first row's lift], `eprops` isq) puts `n` icons: [[centre (tiles from the entity's
## centre, right and down), side (tiles)], ...], at most a row's icons times its rows. Rows of up to
## `icons a row` from the top, each centred on the shift, one `scale x separation` apart both ways; a
## last row not full is centred; with several rows the first is lifted by `first row's lift` per row
## after it (the docs give the parameters, not the rule: rebuilt from 2.1's numbers, its labs and
## beacons, not measured on Factorio's screen).
static func sequence_cells(n: int, row: Array) -> Array:
	var shift := Vector2(float(row[1]), float(row[2]))
	var scale := float(row[3])
	var per_row := maxi(1, int(row[4]))
	var rows_max := maxi(1, int(row[5]))
	var step := scale * float(row[6]) * SEQUENCE_TILE
	n = mini(n, per_row * rows_max)
	var rows := ceili(float(n) / per_row)
	var top := shift.y + float(row[7]) * (rows - 1)
	var out := []
	for i in n:
		var r := i / per_row
		var in_row := mini(per_row, n - r * per_row)
		var col := i % per_row
		out.append([Vector2(shift.x + (col - (in_row - 1) * 0.5) * step, top + r * step), scale * SEQUENCE_TILE])
	return out


func _draw_fluids(world, camera: Camera3D, fluids_layer) -> void:
	for unit in fluids_layer.fluids:
		var r: WorldMirror.Rec = world.entities.get(unit)
		if r == null:
			continue
		var proto = world.protos.entity(r.proto_id)
		if proto == null or not FLUID_TYPES.has(proto.type):
			continue
		if SPARSE_FLUID_TYPES.has(proto.type) and not pipe_shows_icon(Vector2i(r.pos.floor())):
			continue
		var boxes: Array = fluids_layer.fluids[unit]
		for b in boxes:
			var fluid := str(b.get("fluid", ""))
			if fluid != "" and float(b.get("amount", 0.0)) > 0.0:
				_draw_icon(world, camera, r, [Kit.item_icon(fluid)], FLUID_TILES)
				break


## Whether a plain pipe on this tile shows its fluid. Decided by the tile alone, so an icon never
## moves when pipes are built or mined beside it; x + 2y puts one in every PIPE_ICON_EVERY tiles of
## a straight run either way, and a staircase of pipes crosses it too (x + y would miss some).
static func pipe_shows_icon(tile: Vector2i) -> bool:
	return posmod(tile.x + 2 * tile.y, PIPE_ICON_EVERY) == 0


## Cells of a grid for `n` icons in a square of side 1 (top-left corners and the cell's side), as
## Factorio fits a filter inserter's filters into the one icon's room: 2 side by side, 3 and 4 in a
## 2 x 2 square, 5 in 3 + 2; a last row that isn't full is centred.
static func grid(n: int) -> Array:
	var cols := ceili(sqrt(float(n)))
	var rows := ceili(float(n) / cols)
	var cell := 1.0 / maxi(cols, rows)
	var top := (1.0 - rows * cell) * 0.5
	var out := []
	for i in n:
		var row := i / cols
		var in_row := mini(cols, n - row * cols)
		var left := (1.0 - in_row * cell) * 0.5
		out.append([Vector2(left + (i % cols) * cell, top + row * cell), cell])
	return out


## The icons in the one icon's square of side `tiles` (grid: a filter inserter's filters, a chest's
## kinds), centred `shift` tiles from the entity's centre (its icon_draw_specification).
func _draw_icon(world, camera: Camera3D, r: WorldMirror.Rec, textures: Array[Texture2D], tiles: float, shift := Vector2.ZERO) -> void:
	if r == null or textures.is_empty():
		return
	var cells := []
	for c in grid(textures.size()):
		var side: float = float(c[1])
		cells.append([shift + ((c[0] as Vector2) + Vector2(side, side) * 0.5 - Vector2(0.5, 0.5)) * tiles, side * tiles])
	_draw_cells(world, camera, r, textures, cells, tiles)


## Draws `textures` at `cells` ([[centre (tiles from the entity's icon point, right and down on the
## screen), side (tiles)], ...]), with `qualities`' marks where not normal. `ref` is the size of the
## entity's own icon: its size on screen is held between 8 and 80 pixels, and every cell scales with it.
func _draw_cells(world, camera: Camera3D, r: WorldMirror.Rec, textures: Array[Texture2D], cells: Array, ref: float,
		qualities: Array[String] = []) -> void:
	if r == null or textures.is_empty():
		return
	var proto = world.protos.entity(r.proto_id)
	if proto == null:
		return
	_draw_cells_at(world, camera, WorldMirror.selection_rect(proto, r.pos, r.dir).get_center(), Visuals.height_for(proto),
		textures, cells, ref, qualities)


## The same over the point `c` (tiles) at `height` over the ground: a record's selection box's
## middle at its model's height, or a mover's place now.
func _draw_cells_at(world, camera: Camera3D, c: Vector2, height: float, textures: Array[Texture2D], cells: Array, ref: float,
		qualities: Array[String] = []) -> void:
	if textures.is_empty():
		return
	if _fog != null and not _fog.seen(c):
		return
	var at := Vector3(c.x, height, c.y)
	if _in_3d:
		# Lifted onto the hills by the quads' shader.
		_place_quads(world, camera, at + Vector3(0, ref * 0.5, 0), textures, cells, qualities)
		return
	# Over the building where an add-on's hills put it, not on the flat ground under the hill.
	at.y += GroundHeight.at(at.x, at.z)
	if camera.is_position_behind(at):
		return
	var p := camera.unproject_position(at)
	var edge := camera.unproject_position(at + camera.global_basis.x * ref * 0.5)
	var half := clampf(p.distance_to(edge), Kit.px(4), Kit.px(40))
	var per_tile := half * 2.0 / ref
	# How far ahead of the camera, along its view: which icon is in front where they overlap.
	var depth := -camera.global_basis.z.dot(at - camera.global_position)
	for i in mini(textures.size(), cells.size()):
		if textures[i] == null:
			continue
		var side: float = float(cells[i][1]) * per_tile
		var mid: Vector2 = p + (cells[i][0] as Vector2) * per_tile
		var s := side * 0.65
		_shadows.append(Rect2(mid - Vector2(s, s), Vector2(s, s) * 2.0))
		var rects: Array = _icons.get(textures[i], [])
		if rects.is_empty():
			_icons[textures[i]] = rects
		var rect := Rect2(mid - Vector2(side, side) * 0.5, Vector2(side, side))
		rects.append(rect)
		var mark: Texture2D = Slot.quality_icon(qualities[i]) if i < qualities.size() else null
		var mark_rect := Rect2()
		if mark != null:
			var qs := side * QUALITY_SHARE
			var marks: Array = _marks.get(mark, [])
			if marks.is_empty():
				_marks[mark] = marks
			mark_rect = Rect2(mid + Vector2(-side * 0.5, side * 0.5 - qs), Vector2(qs, qs))
			marks.append(mark_rect)
		_e_depth.append(depth)
		_e_shadow.append(_shadows[_shadows.size() - 1])
		_e_rect.append(rect)
		_e_tex.append(textures[i])
		_e_mark.append(mark)
		_e_mark_rect.append(mark_rect)
		# A cheap fingerprint of the list, so an unchanged view keeps last frame's layers.
		_e_sum += (rect.position.x + rect.position.y * 1.618 + rect.size.x * 2.414 + depth * 3.1416
			) * (1.0 + _e_tex.size() * 0.0001)
		_e_hash = _e_hash * 1000003 ^ textures[i].get_instance_id()
		_e_hash = _e_hash * 1000003 ^ (0 if mark == null else mark.get_instance_id())


var _in_3d := false
## This frame's icons one by one, in the order found: their depth ahead of the camera, shadow's and
## icon's rectangles, picture, quality mark (or null) and its rectangle.
var _e_depth := PackedFloat32Array()
var _e_shadow: Array[Rect2] = []
var _e_rect: Array[Rect2] = []
var _e_tex: Array[Texture2D] = []
var _e_mark: Array = []
var _e_mark_rect: Array[Rect2] = []
var _e_sum := 0.0
## The list's pictures and marks, by their whole ids (wrapping 64-bit).
var _e_hash := 0
## The layers drawn in turn (icon_order): [entries (indices into the _e_ arrays, in sorted order),
## {Texture2D: [entry, ...]}]. No icon overlaps another of its layer. Over layer_cap icons one list
## of every entry, farthest first (`_flat`).
var _layers: Array = []
var _layers_used := 0
## Whether the layers are this frame's (collect made them, or kept last frame's).
var _layers_now := false
var _flat := false
## The screen's grid for finding overlaps, cells this many pixels square (at UI scale 1).
const LAYER_CELL := 64
## Over this many icons in view (Factorio's view zoomed out over a big base) they are drawn farthest
## first without layers: the shadows all first, the icons in that order, each with its quality mark
## (the canvas batches icons next to each other with one picture): layering costs about 3 microseconds an icon each time the
## view or the icons change (1.6-1.9 ms for 600, headless), the flat order 0.1 ms a thousand.
static var layer_cap := 600
## What last frame's layers were made for: the camera, the viewport and the list's fingerprint.
var _layers_key := []
## Reused between frames.
var _keys := PackedInt64Array()
var _order := PackedInt32Array()
var _layer_of := PackedInt32Array()
var _grid := {}  # int (cell) -> [entry, ...]
var _grid_used: Array[int] = []


## Sorts this frame's icons farthest first (a machine's own cells, at one depth, in their order: its
## lower rows after the upper, as Factorio lays its rows down the picture) and puts each in the first
## layer after every icon sorted before it that it overlaps (its shadow's square is its footprint).
## Kept as they are while the camera, the viewport and the icons stay the same.
func _build_layers(camera: Camera3D) -> void:
	var n := _e_tex.size()
	var key := [camera.global_transform, camera.projection, camera.size, camera.fov, get_viewport_rect().size, n, _e_sum, _e_hash]
	_layers_now = true
	if key == _layers_key:
		return
	_layers_key = key
	_layers_used = 0
	_flat = false
	if n == 0:
		return
	_keys.resize(n)
	for i in n:
		var q := clampi(int(_e_depth[i] * 256.0), -(1 << 30), 1 << 30)
		_keys[i] = (((1 << 30) - q) << 21) | i
	_keys.sort()
	_order.resize(n)
	for k in n:
		_order[k] = int(_keys[k] & ((1 << 21) - 1))
	if n > layer_cap:
		_flat = true
		return
	for g in _grid_used:
		(_grid[g] as Array).clear()
	_grid_used.clear()
	var cell := float(maxi(Kit.px(LAYER_CELL), 1))
	_layer_of.resize(n)
	for i in _order:
		var fp: Rect2 = _e_shadow[i]
		var x0 := floori(fp.position.x / cell)
		var x1 := floori(fp.end.x / cell)
		var y0 := floori(fp.position.y / cell)
		var y1 := floori(fp.end.y / cell)
		var layer := 0
		for gx in range(x0, x1 + 1):
			for gy in range(y0, y1 + 1):
				var g := (gx << 20) + gy
				var list = _grid.get(g)
				if list == null:
					list = []
					_grid[g] = list
				if (list as Array).is_empty():
					_grid_used.append(g)
				for j in list:
					if _layer_of[j] >= layer and _e_shadow[j].intersects(fp):
						layer = _layer_of[j] + 1
				list.append(i)
		_layer_of[i] = layer
		while _layers_used <= layer:
			if _layers_used == _layers.size():
				_layers.append([[], {}])
			var fresh: Array = _layers[_layers_used]
			(fresh[0] as Array).clear()
			(fresh[1] as Dictionary).clear()
			_layers_used += 1
		var into: Array = _layers[layer]
		(into[0] as Array).append(i)
		var by_tex: Dictionary = into[1]
		var same: Array = by_tex.get(_e_tex[i], [])
		if same.is_empty():
			by_tex[_e_tex[i]] = same
		same.append(i)


## What _draw draws, in its order: [["s" (a shadow), "i" (an icon) or "m" (a quality mark), texture,
## rect, depth ahead of the camera (icons only, else -1)], ...] (tests).
func paint_list() -> Array:
	var out := []
	if icon_order:
		if not _layers_now:
			return out
		if _flat:
			for i in _order:
				out.append(["s", _shadow, _e_shadow[i], -1.0])
			for i in _order:
				out.append(["i", _e_tex[i], _e_rect[i], _e_depth[i]])
				if _e_mark[i] != null:
					out.append(["m", _e_mark[i], _e_mark_rect[i], -1.0])
			return out
		for l in _layers_used:
			var layer: Array = _layers[l]
			for i in layer[0]:
				out.append(["s", _shadow, _e_shadow[i], -1.0])
			for texture in layer[1]:
				for i in layer[1][texture]:
					out.append(["i", texture, _e_rect[i], _e_depth[i]])
			for i in layer[0]:
				if _e_mark[i] != null:
					out.append(["m", _e_mark[i], _e_mark_rect[i], -1.0])
		return out
	for rect in _shadows:
		out.append(["s", _shadow, rect, -1.0])
	for texture in _icons:
		for i in _e_tex.size():
			if _e_tex[i] == texture:
				out.append(["i", texture, _e_rect[i], _e_depth[i]])
	for texture in _marks:
		for rect in _marks[texture]:
			out.append(["m", texture, rect, -1.0])
	return out


## This frame's icons: their shadows, their rectangles by picture and their quality marks by picture
## (drawn in that order under --alt-icon-order=old).
var _shadows: Array[Rect2] = []
var _icons := {}  # Texture2D -> [Rect2, ...]
var _marks := {}  # Texture2D -> [Rect2, ...]
## First person: the quads this frame used for quality marks (not counted as icons).
var _marks_3d := 0
## Icons drawn in the last frame (tests, the stutter probe).
var drawn := 0


## First person: the icons over `top` as camera-facing quads in the world, at the same cells
## (tiles right and down from `top`), their quality marks a little in front.
func _place_quads(world, camera: Camera3D, top: Vector3, textures: Array[Texture2D], cells: Array,
		qualities: Array[String] = []) -> void:
	if _quad_holder == null or not is_instance_valid(_quad_holder):
		_quad_holder = Node3D.new()
		_quad_holder.name = "AltIcons3D"
		(world as Node).get_parent().add_child(_quad_holder)
		_quads.clear()
	var right := camera.global_basis.x
	var up := camera.global_basis.y
	var toward := camera.global_basis.z
	# Godot's transparent pass sorts by the distance from the camera to each quad (ortho: its depth)
	# less its sorting_offset: every cell sorts at its machine's, a step nearer per cell, so a
	# machine's lower rows are drawn over its upper whichever way the camera looks at them.
	var ortho := camera.projection == Camera3D.PROJECTION_ORTHOGONAL
	# A machine's rows come in calls of their own (its icon, then its modules, its packs): the
	# first's distance and the steps carry on across them, so its later rows sort nearer.
	var machine := Vector2(top.x, top.z)
	var state: Array = _quad_machines.get(machine, [])
	if state.is_empty():
		state = [_sort_distance(camera, top, ortho), 0]
		_quad_machines[machine] = state
	var base: float = state[0]
	for i in mini(textures.size(), cells.size()):
		if textures[i] == null:
			continue
		var side: float = float(cells[i][1])
		var mid: Vector2 = cells[i][0]
		var at := top + right * mid.x - up * mid.y
		state[1] = int(state[1]) + 1
		var step := QUAD_STEP * int(state[1])
		_quad(at, side, textures[i], _sort_distance(camera, at, ortho) - base + step if icon_order else 0.0)
		var mark: Texture2D = Slot.quality_icon(qualities[i]) if i < qualities.size() else null
		if mark != null:
			var qs := side * QUALITY_SHARE
			var mark_at := at + right * (qs - side) * 0.5 - up * (side - qs) * 0.5 + toward * 0.02
			_quad(mark_at, qs, mark, _sort_distance(camera, mark_at, ortho) - base + step + QUAD_STEP * 0.5 if icon_order else 0.0)
			_marks_3d += 1


## What Godot's transparent pass sorts a quad at `p` by (before its sorting_offset).
static func _sort_distance(camera: Camera3D, p: Vector3, ortho: bool) -> float:
	if ortho:
		return -camera.global_basis.z.dot(p - camera.global_position)
	return camera.global_position.distance_to(p)


func _quad(at: Vector3, side: float, texture: Texture2D, sort_offset := 0.0) -> void:
	if _quads_used >= _quads.size():
		var q := MeshInstance3D.new()
		var mesh := QuadMesh.new()
		mesh.size = Vector2.ONE
		q.mesh = mesh
		q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_quad_holder.add_child(q)
		_quads.append(q)
	var q := _quads[_quads_used]
	_quads_used += 1
	q.position = at
	q.sorting_offset = sort_offset
	q.scale = Vector3(side, side, side)
	q.material_override = _quad_material(texture)
	q.visible = true


func _quad_material(texture: Texture2D) -> ShaderMaterial:
	var m: ShaderMaterial = _quad_materials.get(texture)
	if m == null:
		m = ShaderMaterial.new()
		m.shader = DepthIcon
		m.set_shader_parameter("icon", texture)
		_quad_materials[texture] = m
	return m


## Hides the quads this frame didn't use (all of them out of first person).
func _hide_quads() -> void:
	for i in range(_quads_used, _quads.size()):
		_quads[i].visible = false
