extends MeshInstance3D
## Factorio's selection and placement marks, drawn flat just above the ground and over everything
## (no depth test, like Factorio's overlays on its sprites): the selection box's corner brackets
## round the hovered entity or vehicle; the yellow arrows of inserters (where they pick up and
## drop), of belts, splitters, undergrounds and loaders being placed (the way they run), of mining
## drills (where they drop) and of fluid connections (in, out, or both ways); and the areas of
## roboports (logistic orange, construction green) and mining drills; the lines between linked
## roboports (H14, roboport_links.gd); electric poles' supply areas in Factorio's blue, one tint
## where several meet (J4, pole_coverage.gd); and a held underground's connection and reach (J24,
## underground_pairs.gd). A crafting machine's connections with its record's `fc` (L10: which fluid goes in or
## out where, read by the bridge) get the fluid's icon at each, as Factorio draws it on a machine selected
## (PipeConnectionDefinition::hide_connection_info); --fluid-icons=off draws the prototype's arrows alone, as before.
##
## marks_for() works the marks out as plain data from the mod's `eprops` overlay (ui_model.eprops
## "x"), so the UI test can check them; show_marks() draws a list of marks.

const GroundHeight := preload("res://scripts/world/ground_height.gd")
const Kit := preload("res://scripts/ui/factorio/kit.gd")

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
const BELT_TYPES := ["transport-belt", "underground-belt", "splitter", "lane-splitter", "loader", "loader-1x1", "linked-belt"]
## A fluid's icon at a connection (tiles across), on the connection's own tile just inside the machine's edge.
const FLUID_ICON := 0.55
## L10: on unless --fluid-icons=off (docs/RUNNING.md).
static var fluid_icons := not ("--fluid-icons=off" in OS.get_cmdline_user_args())

var _mesh := ImmediateMesh.new()
## Pictures drawn flat (fluid icons): a pool of quads, one material a picture.
var _icon_quads: Array[MeshInstance3D] = []
var _icon_materials := {}


func _ready() -> void:
	mesh = _mesh
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Unshaded, see-through, over everything, and lifted onto the hills (ground_height.gd).
	material_override = GroundHeight.overlay_material(10)


## A Factorio vector (x east, y south) turned clockwise by a 16-way direction.
static func turn(v: Vector2, dir: int) -> Vector2:
	return v.rotated(float(dir) / 16.0 * TAU)


## The unit vector a 16-way direction points along (north is (0, -1)).
static func dir_vector(dir: int) -> Vector2:
	return turn(Vector2(0, -1), dir)


static func arrow(at: Vector2, towards: Vector2, both := false, color := YELLOW) -> Dictionary:
	return {"k": "arrow", "at": at, "dir": towards.normalized(), "both": both, "c": color}


## A picture lying flat at `at` (tiles), `size` across: an item's or fluid's icon by name.
static func icon(at: Vector2, name: String, size := FLUID_ICON) -> Dictionary:
	return {"k": "icon", "at": at, "name": name, "size": size}


static func area(rect: Rect2, fill: Color, edge: Color) -> Dictionary:
	return {"k": "area", "rect": rect, "fill": fill, "edge": edge}


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


## A straight line on the ground from `a` to `b` (tiles): roboport links.
static func line(a: Vector2, b: Vector2, color := LINK, width := LINK_WIDTH) -> Dictionary:
	return {"k": "line", "a": a, "b": b, "c": color, "w": width}


## Corner brackets round a box: `centre` and `half` size in tiles, turned by `yaw` (Godot's, about
## the up axis: a mover's rotation.y).
static func brackets(centre: Vector2, half: Vector2, yaw := 0.0, color := SELECTION) -> Dictionary:
	return {"k": "brackets", "at": centre, "half": half, "yaw": yaw, "c": color}


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
	_mesh.clear_surfaces()
	visible = not marks.is_empty()
	_show_icons(marks)
	if marks.is_empty():
		return
	var drawn := 0
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for m: Dictionary in marks:
		if str(m["k"]) != "icon":
			drawn += 1
		match str(m["k"]):
			"area":
				var r: Rect2 = m["rect"]
				_quad(r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y), m["fill"], LIFT * 0.5)
				var w := clampf(r.size.x * 0.004, 0.06, 0.2)
				_frame(r, w, m["edge"])
			"cover":
				for r: Rect2 in m["rects"]:
					_quad(r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y), m["c"], LIFT * 0.5)
			"brackets":
				_brackets(m["at"], m["half"], float(m["yaw"]), m["c"])
			"arrow":
				_arrow(m["at"], m["dir"], bool(m["both"]), m["c"])
			"line":
				var a: Vector2 = m["a"]
				var b: Vector2 = m["b"]
				var side := (b - a).normalized().orthogonal() * float(m["w"]) * 0.5
				_quad(a + side, b + side, b - side, a - side, m["c"])
			"tunnel":
				_tunnel(m["at"], m["dir"], m["c"], bool(m.get("arrow", true)))
			"unbuilt":
				_unbuilt(m["at"], m["dir"], m["c"], m["ca"], bool(m.get("arrow", true)))
	if drawn == 0:  # (only pictures: a surface can't be empty)
		_tri(Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Color(0, 0, 0, 0))
	_mesh.surface_end()


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


func _frame(r: Rect2, w: float, c: Color) -> void:
	var a := r.position
	var b := r.end
	_quad(a, Vector2(b.x, a.y), Vector2(b.x, a.y + w), Vector2(a.x, a.y + w), c)
	_quad(Vector2(a.x, b.y - w), Vector2(b.x, b.y - w), b, Vector2(a.x, b.y), c)
	_quad(a, Vector2(a.x + w, a.y), Vector2(a.x + w, b.y), Vector2(a.x, b.y), c)
	_quad(Vector2(b.x - w, a.y), Vector2(b.x, a.y), b, Vector2(b.x - w, b.y), c)


## Factorio's selection corners: an L in each corner, a third of the shorter side long at most.
func _brackets(centre: Vector2, half: Vector2, yaw: float, c: Color) -> void:
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
			_quad(turned.call(corner), turned.call(corner + along_x), turned.call(corner + along_x + in_y), turned.call(corner + in_y), c)
			_quad(turned.call(corner), turned.call(corner + along_y), turned.call(corner + along_y + in_x), turned.call(corner + in_x), c)


## An arrow centred on `at` pointing along `d` (a unit vector); `both`: a head at each end.
func _arrow(at: Vector2, d: Vector2, both: bool, c: Color) -> void:
	var side := Vector2(-d.y, d.x)
	var half_len := ARROW.x * (0.75 if both else 0.5)
	var head := ARROW.x * (0.4 if both else 0.5)
	var shaft := ARROW.y * 0.32
	var tip := at + d * half_len
	var base := tip - d * head
	_tri(tip, base + side * ARROW.y * 0.5, base - side * ARROW.y * 0.5, c)
	var tail := at - d * half_len
	if both:
		var base2 := tail + d * head
		_tri(tail, base2 - side * ARROW.y * 0.5, base2 + side * ARROW.y * 0.5, c)
		tail = base2
	_quad(tail + side * shaft * 0.5, base + side * shaft * 0.5, base - side * shaft * 0.5, tail - side * shaft * 0.5, c)


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
	for p in [a, b, c]:
		_mesh.surface_set_color(color)
		_mesh.surface_add_vertex(Vector3(p.x, lift, p.y))


func _quad(a: Vector2, b: Vector2, c: Vector2, d: Vector2, color: Color, lift := LIFT) -> void:
	_tri(a, b, c, color, lift)
	_tri(a, c, d, color, lift)
