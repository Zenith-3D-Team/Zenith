extends MeshInstance3D
## Factorio's selection and placement marks: brackets, arrows, fluid icons, roboport links and
## underground tunnel marks draw flat over everything (no depth test, ground_overlay.gdshader),
## while ground area showcases ("area" and "cover": mining drill radius, roboport logistic and
## construction coverage, electric pole supply range, resource highlights, tile buildability rules,
## spidertron waypoints) draw on the ground under 3D models (ground_mark.gdshader at
## GroundHeight.AREA_PRIORITY), riding on hills as the terrain does.
##
## marks_for() works the marks out as plain data from the mod's `eprops` overlay (ui_model.eprops
## "x"), so the UI test can check them; show_marks() draws a list of marks.

const GroundHeight := preload("res://scripts/world/ground_height.gd")
const Kit := preload("res://scripts/ui/factorio/kit.gd")
const Switches := preload("res://scripts/switches.gd")
const Wire := preload("res://scripts/util/wire.gd")

const YELLOW := Color(1.0, 0.8, 0.1, 0.95)
const SELECTION := Color(1.0, 0.86, 0.3, 0.95)
const LOGISTIC_FILL := Color(1.0, 0.5, 0.05, 0.06)
const LOGISTIC_EDGE := Color(1.0, 0.5, 0.05, 0.85)
const CONSTRUCTION_FILL := Color(0.3, 0.85, 0.3, 0.04)
const CONSTRUCTION_EDGE := Color(0.3, 0.85, 0.3, 0.75)
const MINING_FILL := Color(0.55, 0.8, 1.0, 0.16)
const MINING_EDGE := Color(0.55, 0.8, 1.0, 0.6)
## A link between two roboports of one logistic network: the logistic area's orange, and how wide (tiles).
const LINK := Color(1.0, 0.53, 0.0, 0.9)
const LINK_WIDTH := 0.12
## Electric poles' supply areas (J4): the colour of Factorio's electric-pole-radius-visualization.png,
## see-through.
const SUPPLY := Color(55.0 / 255.0, 85.0 / 255.0, 217.0 / 255.0, 0.28)
## Arrows are this long and wide (tiles).
const ARROW := Vector2(0.5, 0.42)
const LIFT := 0.06
## Ground area showcases sit just over the terrain (below ground items and 3D models), slightly
## higher on curved Terrain Elevation hills, subdivided up to HILL_MAX_CELLS per side on hills.
const AREA_LIFT := 0.02
const AREA_HILL_LIFT := 0.04
const HILL_MAX_CELLS := 32
const BELT_TYPES := ["transport-belt", "underground-belt", "splitter", "lane-splitter", "loader", "loader-1x1", "linked-belt"]
## A fluid's icon at a connection (tiles across), on the connection's own tile just inside the machine's edge.
const FLUID_ICON := 0.55
## L10: on unless --fluid-icons=off (docs/RUNNING.md).
static var fluid_icons := Switches.on("--fluid-icons")

var _mesh := ImmediateMesh.new()
## Ground-level area marks ("area" and "cover"), depth-tested under models at AREA_PRIORITY.
var _areas := MeshInstance3D.new()
var _areas_mesh := ImmediateMesh.new()
var _last_area_marks: Array = []
var _last_hills_ver := -2
## Pictures drawn flat (fluid icons): a pool of quads, one material a picture.
var _icon_quads: Array[MeshInstance3D] = []
var _icon_materials := {}


func _init() -> void:
	_areas.mesh = _areas_mesh
	_areas.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_areas.material_override = GroundHeight.mark_material(Color.WHITE, true, GroundHeight.AREA_PRIORITY)
	_areas.visible = false
	add_child(_areas)


func _ready() -> void:
	mesh = _mesh
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Unshaded, see-through, over everything, and lifted onto the hills (ground_height.gd).
	material_override = GroundHeight.overlay_material(10)


## A Factorio vector (x east, y south) turned clockwise by a 16-way direction.
static func turn(v: Vector2, dir: int) -> Vector2:
	return v.rotated(-Wire.direction_yaw(dir))


## The unit vector a 16-way direction points along (north is (0, -1)).
static func dir_vector(dir: int) -> Vector2:
	return turn(Vector2(0, -1), dir)


static func arrow(at: Vector2, towards: Vector2, both := false, color := YELLOW, y := 0.0) -> Dictionary:
	var m := {"k": "arrow", "at": at, "dir": towards.normalized(), "both": both, "c": color}
	if y != 0.0:
		m["y"] = y
	return m


## A picture lying flat at `at` (tiles), `size` across: an item's or fluid's icon by name.
static func icon(at: Vector2, name: String, size := FLUID_ICON) -> Dictionary:
	return {"k": "icon", "at": at, "name": name, "size": size}


## A filled + framed rectangle. By default (`over = false, y = 0`) draws on `_areas` at
## GroundHeight.AREA_PRIORITY (-32) under grass/buildings (drill/roboport ranges). Pass `over = true`
## or a non-zero `y` (e.g. ModelLibrary.ELEVATED_TRACK) for placement tile outlines drawn over grass,
## rail ballast, and elevated decks.
static func area(rect: Rect2, fill: Color, edge: Color, y := 0.0, over := false) -> Dictionary:
	var m := {"k": "area", "rect": rect, "fill": fill, "edge": edge}
	if y != 0.0:
		m["y"] = y
	if over:
		m["over"] = true
	return m


## Areas filled in one colour and no edge, `rects` not overlapping (union_rects), so where several
## meet the tint doesn't stack: poles' supply areas.
static func cover(rects: Array, fill := SUPPLY) -> Dictionary:
	return {"k": "cover", "rects": rects, "c": fill}


## The union of rectangles as rectangles that don't overlap: the bands between their top and bottom
## edges, each band's spans merged, a span carried down while the next band has the same one.
static func union_rects(rects: Array) -> Array:
	var ys := {}
	for r: Rect2 in rects:
		ys[r.position.y] = true
		ys[r.end.y] = true
	var edges: Array = ys.keys()
	edges.sort()
	var by_top := rects.duplicate()
	by_top.sort_custom(func(a: Rect2, b: Rect2) -> bool: return a.position.y < b.position.y)
	var out: Array = []
	var open := {}  # span (Vector2 x0, x1) of the band above -> its rectangle's index in `out`
	var active: Array = []
	var next := 0
	for i in range(edges.size() - 1):
		var y0: float = edges[i]
		var y1: float = edges[i + 1]
		while next < by_top.size() and (by_top[next] as Rect2).position.y <= y0:
			active.append(by_top[next])
			next += 1
		var spans: Array = []
		var still: Array = []
		for r: Rect2 in active:
			if r.end.y > y0:
				still.append(r)
				spans.append(Vector2(r.position.x, r.end.x))
		active = still
		var now := {}
		for s: Vector2 in _merged(spans):
			if open.has(s):
				var k: int = open[s]
				var grown: Rect2 = out[k]
				grown.size.y = y1 - grown.position.y
				out[k] = grown
				now[s] = k
			else:
				now[s] = out.size()
				out.append(Rect2(s.x, y0, s.y - s.x, y1 - y0))
		open = now
	return out


## `r` less what `cut` covers, as rectangles that don't overlap.
static func minus(r: Rect2, cut: Array) -> Array:
	var clipped: Array = []
	for c: Rect2 in cut:
		var i := r.intersection(c)
		if i.has_area():
			clipped.append(i)
	if clipped.is_empty():
		return [r]
	var ys := {r.position.y: true, r.end.y: true}
	for c: Rect2 in clipped:
		ys[c.position.y] = true
		ys[c.end.y] = true
	var edges: Array = ys.keys()
	edges.sort()
	var out: Array = []
	for i in range(edges.size() - 1):
		var y0: float = edges[i]
		var y1: float = edges[i + 1]
		var spans: Array = []
		for c: Rect2 in clipped:
			if c.position.y <= y0 and c.end.y >= y1:
				spans.append(Vector2(c.position.x, c.end.x))
		var x := r.position.x
		for s: Vector2 in _merged(spans):
			if s.x > x:
				out.append(Rect2(x, y0, s.x - x, y1 - y0))
			x = maxf(x, s.y)
		if x < r.end.x:
			out.append(Rect2(x, y0, r.end.x - x, y1 - y0))
	return out


## Spans (Vector2 x0, x1) sorted and joined where they touch or overlap.
static func _merged(spans: Array) -> Array:
	spans.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	var out: Array = []
	for s: Vector2 in spans:
		if not out.is_empty() and s.x <= (out[-1] as Vector2).y:
			var last: Vector2 = out[-1]
			last.y = maxf(last.y, s.y)
			out[-1] = last
		else:
			out.append(s)
	return out


## A straight line from `a` to `b` (tiles): roboport links, rail block overlays. Optional `y` (and
## `y_end` for ramps) lifts the line above ground (e.g. ModelLibrary.ELEVATED_TRACK).
static func line(a: Vector2, b: Vector2, color := LINK, width := LINK_WIDTH, y := 0.0, y_end := NAN) -> Dictionary:
	var m := {"k": "line", "a": a, "b": b, "c": color, "w": width}
	if y != 0.0:
		m["y"] = y
	if not is_nan(y_end) and y_end != y:
		m["y2"] = y_end
	return m


## Corner brackets round a box: `centre` and `half` size in tiles, turned by `yaw` (Godot's, about
## the up axis: a mover's rotation.y), optionally lifted by `y` tiles above ground.
static func brackets(centre: Vector2, half: Vector2, yaw := 0.0, color := SELECTION, y := 0.0) -> Dictionary:
	var m := {"k": "brackets", "at": centre, "half": half, "yaw": yaw, "c": color}
	if y != 0.0:
		m["y"] = y
	return m


## The marks for an entity of `type` at `pos` facing `dir`, from its `eprops` overlay `x`; with
## `placing`, also what only shows while it is being placed (a belt's way). `fc`: the record's live fluid
## connections with their fluids (L10, world frame), drawn in place of the prototype's.
static func marks_for(type: String, x: Dictionary, pos: Vector2, dir: int, placing: bool, fc: Array = []) -> Array:
	var out: Array = []
	if placing and BELT_TYPES.has(type):
		out.append(arrow(pos, dir_vector(dir)))
	if x.has("ip") and x.has("id"):
		var pick := turn(_vec(x["ip"]), dir)
		var drop := turn(_vec(x["id"]), dir)
		var flow := drop - pick
		out.append(arrow(pos + pick, flow))
		out.append(arrow(pos + drop, flow))
	if x.has("lr"):
		var c := float(x.get("cr", 0.0))
		if c > 0.0:
			out.append(area(Rect2(pos - Vector2(c, c), Vector2(c, c) * 2.0), CONSTRUCTION_FILL, CONSTRUCTION_EDGE))
		var l := float(x["lr"])
		out.append(area(Rect2(pos - Vector2(l, l), Vector2(l, l) * 2.0), LOGISTIC_FILL, LOGISTIC_EDGE))
	if x.has("mr"):
		var r := float(x["mr"])
		out.append(area(Rect2(pos - Vector2(r, r), Vector2(r, r) * 2.0), MINING_FILL, MINING_EDGE))
		# A pumpjack's {0, 0} isn't a drop: its oil leaves by its fluid connection (L8).
		if x.has("vp") and _vec(x["vp"]) != Vector2.ZERO:
			out.append(arrow(pos + turn(_vec(x["vp"]), dir), dir_vector(dir)))
	if fluid_icons and not fc.is_empty():
		out.append_array(connection_marks(pos, fc))
	elif x.has("fb") and (not x.has("fo") or outputs_only(x["fb"])):
		for c in x["fb"]:
			if not (c is Array) or c.size() < 4:
				continue
			var way := dir_vector(int(c[2]) + dir)
			var at := pos + turn(Vector2(float(c[0]), float(c[1])), dir) + way * 0.62
			var flow := str(c[3])
			out.append(arrow(at, -way if flow == "i" else way, flow == "b"))
	return out


## A record's live connections (`fc`: [dx, dy, way, flow, fluid]) as Factorio marks a selected machine's: the
## arrow past the edge, in or out, and the fluid's icon on the connection's tile.
static func connection_marks(pos: Vector2, fc: Array) -> Array:
	var out: Array = []
	for c in fc:
		if not (c is Array) or c.size() < 5:
			continue
		var way := dir_vector(int(c[2]))
		var tile := pos + Vector2(float(c[0]), float(c[1]))
		var flow := str(c[3])
		out.append(arrow(tile + way * 0.62, -way if flow == "i" else way, flow == "b"))
		if str(c[4]) != "":
			out.append(icon(tile - way * 0.05, str(c[4])))
	return out


## True when every connection only lets fluid out (a pumpjack's): `fo` (shown only while a recipe or resource
## needs fluid) doesn't hide those (L8; a bridge from before marked every drill so).
static func outputs_only(fb) -> bool:
	if not (fb is Array) or (fb as Array).is_empty():
		return false
	for c in fb:
		if not (c is Array) or c.size() < 4 or str(c[3]) != "o":
			return false
	return true


static func _vec(v) -> Vector2:
	return Vector2(float(v[0]), float(v[1])) if v is Array and v.size() >= 2 else Vector2.ZERO


## Draws these marks (replacing the last ones); an empty list hides them.
func show_marks(marks: Array) -> void:
	visible = not marks.is_empty()
	_show_icons(marks)
	if marks.is_empty():
		_mesh.clear_surfaces()
		_clear_areas()
		return
	var area_marks: Array = []
	var top_areas: Array = []
	var top_marks: Array = []
	for m: Dictionary in marks:
		var kind := str(m["k"])
		if kind == "area":
			if bool(m.get("over", false)) or not is_zero_approx(float(m.get("y", 0.0))):
				if (m["rect"] as Rect2).has_area():
					top_areas.append(m)
			else:
				area_marks.append(m)
		elif kind == "cover":
			area_marks.append(m)
		elif kind != "icon":
			top_marks.append(m)
	_mesh.clear_surfaces()
	if not top_areas.is_empty() or not top_marks.is_empty():
		var hills_on := GroundHeight.is_on()
		_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
		for m: Dictionary in top_areas:
			var r: Rect2 = m["rect"]
			var lift := LIFT + float(m.get("y", 0.0))
			var fill: Color = m["fill"]
			var edge: Color = m["edge"]
			_area_rect_on(_mesh, r, fill, lift, hills_on)
			var w := clampf(r.size.x * 0.004, 0.06, 0.2)
			_area_frame_on(_mesh, r, w, edge, lift, hills_on)
		for m: Dictionary in top_marks:
			match str(m["k"]):
				"brackets":
					_brackets(m["at"], m["half"], float(m["yaw"]), m["c"], LIFT + float(m.get("y", 0.0)))
				"arrow":
					_arrow(m["at"], m["dir"], bool(m["both"]), m["c"], LIFT + float(m.get("y", 0.0)))
				"line":
					var a: Vector2 = m["a"]
					var b: Vector2 = m["b"]
					var side := (b - a).normalized().orthogonal() * float(m["w"]) * 0.5
					var y0 := LIFT + float(m.get("y", 0.0))
					var y1 := LIFT + float(m.get("y2", m.get("y", 0.0)))
					if is_equal_approx(y0, y1):
						_quad(a + side, b + side, b - side, a - side, m["c"], y0)
					else:
						_quad_sloped(a + side, y0, b + side, y1, b - side, y1, a - side, y0, m["c"])
				"tunnel":
					_tunnel(m["at"], m["dir"], m["c"], bool(m.get("arrow", true)))
				"unbuilt":
					_unbuilt(m["at"], m["dir"], m["c"], m["ca"], bool(m.get("arrow", true)))
		_mesh.surface_end()
	_show_areas(area_marks)


func _clear_areas() -> void:
	_areas_mesh.clear_surfaces()
	_areas.visible = false
	_last_area_marks = []
	_last_hills_ver = -2


func _show_areas(area_marks: Array) -> void:
	if area_marks.is_empty():
		_clear_areas()
		return
	var hills_on := GroundHeight.is_on()
	var hills_ver := GroundHeight.version() if hills_on else -1
	if hills_ver == _last_hills_ver and area_marks == _last_area_marks:
		_areas.visible = _areas_mesh.get_surface_count() > 0
		return
	_areas_mesh.clear_surfaces()
	var has_any := false
	for m: Dictionary in area_marks:
		var k := str(m["k"])
		if k == "area":
			if (m["rect"] as Rect2).has_area():
				has_any = true
				break
		elif k == "cover":
			for r: Rect2 in m["rects"]:
				if r.has_area():
					has_any = true
					break
			if has_any:
				break
	if has_any:
		var lift := AREA_HILL_LIFT if hills_on else AREA_LIFT
		_areas_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
		for m: Dictionary in area_marks:
			var k := str(m["k"])
			if k == "area":
				var r: Rect2 = m["rect"]
				if r.has_area():
					var fill: Color = m["fill"]
					var edge: Color = m["edge"]
					_area_rect(r, fill, lift, hills_on)
					var w := clampf(r.size.x * 0.004, 0.06, 0.2)
					_area_frame(r, w, edge, lift, hills_on)
			elif k == "cover":
				var col: Color = m["c"]
				var rects: Array = m["rects"]
				for r: Rect2 in rects:
					if r.has_area():
						_area_rect(r, col, lift, hills_on)
		_areas_mesh.surface_end()
	_areas.visible = _areas_mesh.get_surface_count() > 0
	_last_hills_ver = hills_ver
	_last_area_marks = _copy_area_marks(area_marks)


static func _copy_area_marks(marks: Array) -> Array:
	var out: Array = []
	for m: Dictionary in marks:
		var copy := m.duplicate()
		if copy.has("rects") and copy["rects"] is Array:
			copy["rects"] = (copy["rects"] as Array).duplicate()
		out.append(copy)
	return out


## The marks' pictures on quads of their own (the mesh above has colours, no textures).
func _show_icons(marks: Array) -> void:
	var i := 0
	for m: Dictionary in marks:
		if str(m["k"]) != "icon":
			continue
		var name := str(m["name"])
		if not _icon_materials.has(name):
			var texture := Kit.item_icon(name)
			_icon_materials[name] = GroundHeight.overlay_material(10, texture) if texture != null else null
		var material: Material = _icon_materials[name]
		if material == null:
			continue
		if i == _icon_quads.size():
			var mi := MeshInstance3D.new()
			var quad := QuadMesh.new()
			quad.orientation = PlaneMesh.FACE_Y
			mi.mesh = quad
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(mi)
			_icon_quads.append(mi)
		var q := _icon_quads[i]
		var side := Vector2.ONE * float(m["size"])
		if (q.mesh as QuadMesh).size != side:
			(q.mesh as QuadMesh).size = side
		q.material_override = material
		var at: Vector2 = m["at"]
		# The parent sits at the origin: the quad is placed in the world's frame, a little over the arrows.
		q.transform = Transform3D(Basis.IDENTITY, Vector3(at.x, LIFT * 1.5, at.y))
		q.visible = true
		i += 1
	for j in range(i, _icon_quads.size()):
		_icon_quads[j].visible = false


func _area_rect(r: Rect2, color: Color, lift: float, hills_on: bool) -> void:
	_area_rect_on(_areas_mesh, r, color, lift, hills_on)


static func _area_rect_on(target: ImmediateMesh, r: Rect2, color: Color, lift: float, hills_on: bool) -> void:
	if not r.has_area():
		return
	var nx := 1
	var ny := 1
	if hills_on:
		var base := clampf(GroundHeight.tile_step(), 1.0, 2.0)
		var step := maxf(base, maxf(r.size.x, r.size.y) / float(HILL_MAX_CELLS))
		nx = clampi(int(ceilf(r.size.x / step)), 1, HILL_MAX_CELLS)
		ny = clampi(int(ceilf(r.size.y / step)), 1, HILL_MAX_CELLS)
	var dx := r.size.x / float(nx)
	var dy := r.size.y / float(ny)
	for iy in ny:
		var y0 := r.position.y + dy * float(iy)
		var y1 := r.end.y if iy == ny - 1 else r.position.y + dy * float(iy + 1)
		for ix in nx:
			var x0 := r.position.x + dx * float(ix)
			var x1 := r.end.x if ix == nx - 1 else r.position.x + dx * float(ix + 1)
			_quad_on(target, Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1), Vector2(x0, y1), color, lift)


func _area_frame(r: Rect2, w: float, color: Color, lift: float, hills_on: bool) -> void:
	_area_frame_on(_areas_mesh, r, w, color, lift, hills_on)


static func _area_frame_on(target: ImmediateMesh, r: Rect2, w: float, color: Color, lift: float, hills_on: bool) -> void:
	var bw := minf(w, minf(r.size.x, r.size.y) * 0.5)
	if bw <= 0.0:
		return
	_area_rect_on(target, Rect2(r.position.x, r.position.y, r.size.x, bw), color, lift, hills_on)
	_area_rect_on(target, Rect2(r.position.x, r.end.y - bw, r.size.x, bw), color, lift, hills_on)
	if r.size.y > bw * 2.0:
		_area_rect_on(target, Rect2(r.position.x, r.position.y + bw, bw, r.size.y - bw * 2.0), color, lift, hills_on)
		_area_rect_on(target, Rect2(r.end.x - bw, r.position.y + bw, bw, r.size.y - bw * 2.0), color, lift, hills_on)


## Factorio's selection corners: an L in each corner, a third of the shorter side long at most.
func _brackets(centre: Vector2, half: Vector2, yaw: float, c: Color, lift := LIFT) -> void:
	var arm := clampf(minf(half.x, half.y) * 0.6, 0.15, 0.5)
	var w := 0.07
	var turned := func(p: Vector2) -> Vector2:
		var v := Vector3(p.x, 0.0, p.y).rotated(Vector3.UP, yaw)
		return centre + Vector2(v.x, v.z)
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var corner := Vector2(half.x * sx, half.y * sy)
			var along_x := Vector2(-sx * arm, 0.0)
			var along_y := Vector2(0.0, -sy * arm)
			var in_x := Vector2(-sx * w, 0.0)
			var in_y := Vector2(0.0, -sy * w)
			_quad(turned.call(corner), turned.call(corner + along_x), turned.call(corner + along_x + in_y), turned.call(corner + in_y), c, lift)
			_quad(turned.call(corner), turned.call(corner + along_y), turned.call(corner + along_y + in_x), turned.call(corner + in_x), c, lift)


## An arrow centred on `at` pointing along `d` (a unit vector); `both`: a head at each end.
func _arrow(at: Vector2, d: Vector2, both: bool, c: Color, lift := LIFT) -> void:
	var side := Vector2(-d.y, d.x)
	var half_len := ARROW.x * (0.75 if both else 0.5)
	var head := ARROW.x * (0.4 if both else 0.5)
	var shaft := ARROW.y * 0.32
	var tip := at + d * half_len
	var base := tip - d * head
	_tri(tip, base + side * ARROW.y * 0.5, base - side * ARROW.y * 0.5, c, lift)
	var tail := at - d * half_len
	if both:
		var base2 := tail + d * head
		_tri(tail, base2 - side * ARROW.y * 0.5, base2 + side * ARROW.y * 0.5, c, lift)
		tail = base2
	_quad(tail + side * shaft * 0.5, base + side * shaft * 0.5, base - side * shaft * 0.5, tail - side * shaft * 0.5, c, lift)


## One tile of an underground connection (J24, underground_pairs.gd), as Factorio's
## underground-lines.png draws it on a 64-pixel tile pointing up: the lane's two edges as dashes 10
## pixels wide (rows 10-26 and 42-58), and for belts a hollow arrow (apex at row 24, base at row 40,
## 34 pixels wide), all in `c`.
func _tunnel(at: Vector2, flow: Vector2, c: Color, arrow: bool) -> void:
	var f := flow.normalized()
	var side := Vector2(-f.y, f.x)
	var bar := 10.0 / 64.0
	for s: float in [-1.0, 1.0]:
		var mid: Vector2 = at + side * s * (0.5 - bar * 0.5)
		for dash: Vector2 in [Vector2(0.094, 0.344), Vector2(-0.406, -0.156)]:
			var a := mid + f * dash.x
			var b := mid + f * dash.y
			var w := side * bar * 0.5
			_quad(a - w, b - w, b + w, a + w, c)
	if not arrow:
		return
	var apex := at + f * 0.125
	var left := at - f * 0.125 - side * 0.27
	var right := at - f * 0.125 + side * 0.27
	for edge: Array in [[apex, left], [left, right], [right, apex]]:
		var p: Vector2 = edge[0]
		var q: Vector2 = edge[1]
		var n := (q - p).normalized().orthogonal() * 0.025
		_quad(p - n, q - n, q + n, p + n, c)


## M2: one tile an underground's build would mine (underground_pairs.gd removed), as Factorio's
## underground-lines-remove.png draws it on a 64-pixel tile pointing up: an L in each corner 20 pixels along
## each edge and 9 thick (red-orange; Factorio's round their outer corners), and for belts the hollow arrow of its other
## frame (apex at row 23, base at row 42, 36 pixels wide, 4 thick) in `arrow_c`.
func _unbuilt(at: Vector2, flow: Vector2, c: Color, arrow_c: Color, arrow: bool) -> void:
	var f := flow.normalized()
	var side := Vector2(-f.y, f.x)
	var arm := 20.0 / 64.0
	var w := 9.0 / 64.0
	for sf: float in [-1.0, 1.0]:
		for ss: float in [-1.0, 1.0]:
			var corner := at + f * (0.5 * sf) + side * (0.5 * ss)
			var back_f := -f * sf
			var back_s := -side * ss
			_quad(corner, corner + back_f * arm, corner + back_f * arm + back_s * w, corner + back_s * w, c)
			_quad(corner, corner + back_s * arm, corner + back_s * arm + back_f * w, corner + back_f * w, c)
	if not arrow:
		return
	var apex := at + f * (9.0 / 64.0)
	var left := at - f * (10.0 / 64.0) - side * (18.0 / 64.0)
	var right := at - f * (10.0 / 64.0) + side * (18.0 / 64.0)
	for edge: Array in [[apex, left], [left, right], [right, apex]]:
		var p: Vector2 = edge[0]
		var q: Vector2 = edge[1]
		var n := (q - p).normalized().orthogonal() * (2.0 / 64.0)
		_quad(p - n, q - n, q + n, p + n, arrow_c)


func _tri(a: Vector2, b: Vector2, c: Vector2, color: Color, lift := LIFT) -> void:
	_tri_on(_mesh, a, b, c, color, lift)


func _quad(a: Vector2, b: Vector2, c: Vector2, d: Vector2, color: Color, lift := LIFT) -> void:
	_quad_on(_mesh, a, b, c, d, color, lift)


func _quad_sloped(a: Vector2, ya: float, b: Vector2, yb: float, c: Vector2, yc: float, d: Vector2, yd: float, color: Color) -> void:
	_tri_3d(_mesh, Vector3(a.x, ya, a.y), Vector3(b.x, yb, b.y), Vector3(c.x, yc, c.y), color)
	_tri_3d(_mesh, Vector3(a.x, ya, a.y), Vector3(c.x, yc, c.y), Vector3(d.x, yd, d.y), color)


static func _tri_3d(target: ImmediateMesh, a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	for p: Vector3 in [a, b, c]:
		target.surface_set_color(color)
		target.surface_add_vertex(p)


static func _tri_on(target: ImmediateMesh, a: Vector2, b: Vector2, c: Vector2, color: Color, lift: float) -> void:
	for p in [a, b, c]:
		target.surface_set_color(color)
		target.surface_add_vertex(Vector3(p.x, lift, p.y))


static func _quad_on(target: ImmediateMesh, a: Vector2, b: Vector2, c: Vector2, d: Vector2, color: Color, lift: float) -> void:
	_tri_on(target, a, b, c, color, lift)
	_tri_on(target, a, c, d, color, lift)
