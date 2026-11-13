extends RefCounted
## Contact shading: the dark rim on the ground round each building's foot that Factorio's sprites
## have painted in (shaders/contact_shade.gdshader has the profile, measured from the sprites). One
## ring per building, drawn as one MultiMesh per chunk beside the chunk's models (chunk_view.gd
## build_entities collects them, apply() fills the chunk's node), multiplied over the ground.
##
## Each ring sits round one of the model's feet: the box of a connected piece of its lowest vertices,
## found on the model loader's worker thread (feet_of(), model_library.gd Load) and kept as META on
## the mesh; a model without them (a mod's picture card has no ring) uses its prototype's box. How strong
## the rim is depends on the type (STYLE_OF): none under rails, trees and anything that moves; a
## light band along belts, pipes and walls (a run of them one ring, joined()); small under poles and
## inserters; faint under chests, as in Factorio; a broad
## patch under big machines; the full rim under the rest, mods' buildings included. A side facing
## another building's rim across a narrow gap is halved (NEIGHBOUR_GAP), so two rims meeting there
## darken it about as much as one would instead of stacking into black.
##
## Settings > Graphics > Contact shading (on in every preset) shows or hides them (set_enabled).

## Meta on a model's mesh: feet_of()'s feet, [[Rect2 of a foot in model space (x, z), its corners'
## radius], ...] in tiles; [] when it floats.
const META := &"f3d_contact"
## The grid feet are found on (tiles), the most pieces kept apart, and the smallest a foot is drawn.
const FOOT_CELL := 0.25
const MAX_FEET := 8
const MIN_FOOT := 0.12
## Vertices this close to the model's lowest one (tiles) count as its foot.
const FOOT_HEIGHT := 0.05
## A model whose lowest vertex is higher than this doesn't stand on the ground (no rim).
const FLOATING := 0.12
## How far out a ring reaches (tiles): the rim's own end, and the patch's for those with one.
const REACH := 0.27
const PATCH_REACH := 0.55
## Rims of two buildings closer than this (tiles) halve the sides that face each other.
const NEIGHBOUR_GAP := 2.0 * REACH
## Inner ring ticks along each side: long sides follow the hills in steps of a tile or so.
const TICKS := 8

## The belts' rim strength (STYLES).
const BELT_RIM := 0.8
## Pipes' and walls' (STYLES).
const LINE_RIM := 0.6
## [rim strength, patch strength] per type; types not listed get DEFAULT_STYLE, those in NONE none.
const NONE := {"straight-rail": true, "curved-rail-a": true, "curved-rail-b": true,
	"half-diagonal-rail": true, "legacy-straight-rail": true, "legacy-curved-rail": true, "rail-ramp": true,
	"elevated-straight-rail": true, "elevated-curved-rail-a": true, "elevated-curved-rail-b": true,
	"elevated-half-diagonal-rail": true, "rail-support": true, "tree": true, "plant": true, "simple-entity": true,
	"resource": true, "fish": true, "cliff": true, "land-mine": true, "item-entity": true, "corpse": true,
	"character-corpse": true, "rail-remnants": true, "turret": true, "unit": true, "unit-spawner": true,
	"spider-leg": true, "segmented-unit": true, "segment": true, "car": true, "locomotive": true,
	"cargo-wagon": true, "fluid-wagon": true, "artillery-wagon": true, "infinity-cargo-wagon": true,
	"spider-vehicle": true, "character": true, "combat-robot": true, "construction-robot": true,
	"logistic-robot": true, "capture-robot": true, "asteroid": true, "fire": true, "sticker": true,
	"explosion": true, "projectile": true, "space-platform-hub": true,
	"cargo-pod": true, "temporary-container": true}
const STYLES := {
	"container": [0.25, 0.0], "logistic-container": [0.25, 0.0], "infinity-container": [0.25, 0.0],
	"linked-container": [0.25, 0.0],
	"electric-pole": [0.55, 0.0], "inserter": [0.55, 0.0], "lamp": [0.55, 0.0], "rail-signal": [0.55, 0.0],
	"rail-chain-signal": [0.55, 0.0], "power-switch": [0.6, 0.0], "programmable-speaker": [0.55, 0.0],
	"constant-combinator": [0.6, 0.0], "display-panel": [0.4, 0.0], "lightning-attractor": [0.55, 0.0],
	"mining-drill": [1.0, 0.16], "lab": [1.0, 0.16], "radar": [1.0, 0.16],
	# Belts: Factorio's belt sprites have a dark band along their side rails, about 45% dark and 0.06
	# tiles wide on the side away from its sun (measured on the HR transport-belt sheet, 64 px a tile);
	# Zenith's sun casts that side's own shadow, so the band here is lighter and on both sides. A
	# straight run's tiles are joined into one ring (joined()), so its joints don't darken twice.
	"transport-belt": [BELT_RIM, 0.0, true], "underground-belt": [BELT_RIM, 0.0, true],
	"splitter": [BELT_RIM, 0.0, true], "lane-splitter": [BELT_RIM, 0.0, true], "loader": [BELT_RIM, 0.0, true],
	"loader-1x1": [BELT_RIM, 0.0, true], "linked-belt": [BELT_RIM, 0.0, true],
	# Pipes and walls (owner: "pipes never show"): Factorio's pipe and wall sprites are darkened at
	# their foot too; a lighter band, a straight run one ring, so a wall or pipeline doesn't bead.
	"pipe": [LINE_RIM, 0.0, true], "pipe-to-ground": [LINE_RIM, 0.0, true], "heat-pipe": [LINE_RIM, 0.0, true],
	"infinity-pipe": [LINE_RIM, 0.0, true], "wall": [LINE_RIM, 0.0, true], "gate": [LINE_RIM, 0.0, true],
}
## Rings of the styles with a third entry, true, that line up along a run of tiles are one ring; this
## much gap (tiles) still joins them.
const JOIN_SLACK := 0.03
## By name, before the type (a centrifuge is an assembling machine).
const NAME_STYLES := {"centrifuge": [1.0, 0.16], "biolab": [1.0, 0.16], "pumpjack": [1.0, 0.12],
	"oil-refinery": [1.0, 0.12], "nuclear-reactor": [1.0, 0.12]}
const DEFAULT_STYLE := [1.0, 0.0]

const SHADER := preload("res://shaders/contact_shade.gdshader")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const AoZoom := preload("res://scripts/world/ao_zoom.gd")

static var enabled := true
static var _material: ShaderMaterial
static var _ring: ArrayMesh


## A model's feet from its merged surfaces ([keys, arrays, formats] as Load makes them): the
## vertices within FOOT_HEIGHT of its lowest, and the edges between them, marked on a grid of
## FOOT_CELL tiles and split into connected pieces, so a machine's base is one foot and a gantry's
## or a lattice pole's legs are a foot each (a box round all of them drew a rim on the bare ground
## between). Per foot [its x-z box, its corners' radius]: a round foot (a lab's dome, a tank) leaves
## its box's corners bare, and the radius is how far its vertices stay from them (a rounded box's
## corner is 0.414 r from its box's). More than MAX_FEET pieces: one box round them all. [] when the
## model floats. Worker-thread safe.
static func feet_of(groups: Array) -> Array:
	var low := INF
	for g: Array in groups:
		var v: PackedVector3Array = (g[1] as Array)[Mesh.ARRAY_VERTEX]
		for p in v:
			low = minf(low, p.y)
	if low > FLOATING or low == INF:
		return []
	var top := low + FOOT_HEIGHT
	var points := PackedVector2Array()  # the foot's vertices, and points along its edges
	for g: Array in groups:
		var a: Array = g[1]
		var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var on_ground := PackedByteArray()
		on_ground.resize(v.size())
		var any := false
		for i in v.size():
			if v[i].y <= top:
				on_ground[i] = 1
				any = true
				points.append(Vector2(v[i].x, v[i].z))
		var idx = a[Mesh.ARRAY_INDEX]
		if not any or not idx is PackedInt32Array:
			continue
		var ix: PackedInt32Array = idx
		for t in range(0, ix.size() - 2, 3):
			if on_ground[ix[t]] + on_ground[ix[t + 1]] + on_ground[ix[t + 2]] < 2:
				continue
			for e in 3:
				var i0 := ix[t + e]
				var i1 := ix[t + (e + 1) % 3]
				if on_ground[i0] == 0 or on_ground[i1] == 0:
					continue
				var p0 := v[i0]
				var p1 := v[i1]
				var a2 := Vector2(p0.x, p0.z)
				var b2 := Vector2(p1.x, p1.z)
				var steps := int(a2.distance_to(b2) / (FOOT_CELL * 0.5))
				for k in range(1, steps):
					points.append(a2.lerp(b2, float(k) / float(steps)))
	if points.is_empty():
		return []
	# Cells with foot in them, then their 8-connected pieces.
	var cells := {}  # Vector2i -> piece (-1 not yet)
	for q in points:
		cells[Vector2i(floori(q.x / FOOT_CELL), floori(q.y / FOOT_CELL))] = -1
	var pieces := 0
	for start in cells.keys():
		if int(cells[start]) >= 0:
			continue
		var stack: Array[Vector2i] = [start]
		cells[start] = pieces
		while not stack.is_empty():
			var c: Vector2i = stack.pop_back()
			for dx in [-1, 0, 1]:
				for dy in [-1, 0, 1]:
					var n := c + Vector2i(dx, dy)
					if cells.has(n) and int(cells[n]) < 0:
						cells[n] = pieces
						stack.append(n)
		pieces += 1
	var by_piece: Array[PackedVector2Array] = []
	if pieces > MAX_FEET:
		by_piece.append(points)
	else:
		by_piece.resize(pieces)
		for q in points:
			var k: int = cells[Vector2i(floori(q.x / FOOT_CELL), floori(q.y / FOOT_CELL))]
			by_piece[k].append(q)
	var out: Array = []
	for foot in by_piece:
		var lo := Vector2.INF
		var hi := -Vector2.INF
		for q in foot:
			lo = lo.min(q)
			hi = hi.max(q)
		var gaps := 0.0
		for c in [lo, Vector2(hi.x, lo.y), Vector2(lo.x, hi.y), hi]:
			var near := INF
			for q in foot:
				near = minf(near, q.distance_squared_to(c))
			gaps += sqrt(near)
		var half := (hi - lo) * 0.5
		out.append([Rect2(lo, hi - lo), clampf(gaps * 0.25 / (1.0 - 1.0 / sqrt(2.0)), 0.02, maxf(minf(half.x, half.y), 0.02))])
	return out


## [rim, patch] for an entity, or [] for none.
static func style_for(proto_name: String, proto_type: String) -> Array:
	if NAME_STYLES.has(proto_name):
		return NAME_STYLES[proto_name]
	if NONE.has(proto_type):
		return []
	return STYLES.get(proto_type, DEFAULT_STYLE)


## Adds the rings of an entity drawn with `mesh` at `xform` to `out` ([centre x, centre z, half x,
## half z, rim, patch, corner radius] each, world-aligned), when its type has one: one per foot
## (feet_of(), the mesh's META), or its prototype's box (`box_min`/`box_max`, tiles round its
## position) for a model without them.
static func collect(out: Array, proto_name: String, proto_type: String, mesh: Mesh, xform: Transform3D,
		box_min: Vector2, box_max: Vector2) -> void:
	var style := style_for(proto_name, proto_type)
	if style.is_empty():
		return
	if mesh == null or not mesh.has_meta(META):
		var at := Vector2(xform.origin.x, xform.origin.z)
		_add(out, Rect2(at + box_min, box_max - box_min), 0.08, style)
		return
	for foot: Array in mesh.get_meta(META):
		var r: Rect2 = foot[0]
		# The box's corners turned and moved as the model is (quarter turns keep it a box).
		var lo := Vector2.INF
		var hi := -Vector2.INF
		for c in [r.position, Vector2(r.end.x, r.position.y), Vector2(r.position.x, r.end.y), r.end]:
			var w := xform * Vector3(c.x, 0.0, c.y)
			lo = lo.min(Vector2(w.x, w.z))
			hi = hi.max(Vector2(w.x, w.z))
		_add(out, Rect2(lo, hi - lo), float(foot[1]), style)


static func _add(out: Array, r: Rect2, corner: float, style: Array) -> void:
	# A foot thinner than this (a pole's lone vertex) gets a small square round it instead.
	r = r.grow_individual(maxf(0.0, (MIN_FOOT - r.size.x) * 0.5), maxf(0.0, (MIN_FOOT - r.size.y) * 0.5),
		maxf(0.0, (MIN_FOOT - r.size.x) * 0.5), maxf(0.0, (MIN_FOOT - r.size.y) * 0.5))
	var c := r.get_center()
	out.append([c.x, c.y, r.size.x * 0.5, r.size.y * 0.5, float(style[0]), float(style[1]), minf(corner, minf(r.size.x, r.size.y) * 0.5),
		style.size() > 2 and bool(style[2])])


## Joins rings that run on from one another (belts: JOINS in their style) into one per straight run:
## the same width across, the same strength, touching or overlapping along the run. Each tile's own
## ring stacked two rims at every joint, a dark bead a tile apart along every belt.
static func joined(rings: Array) -> Array:
	var out: Array = []
	var runs := {}  # [axis, across centre, across half, rim] (snapped) -> rings
	for g: Array in rings:
		if g.size() < 8 or not bool(g[7]):
			out.append(g)
			continue
		# Along z when the ring is longer that way (or square: both are tried by the key below).
		var axis := 1 if float(g[3]) >= float(g[2]) else 0
		var key := [axis, roundi(float(g[1 - axis]) * 64.0), roundi(float(g[3 - axis]) * 64.0), roundi(float(g[4]) * 64.0)]
		if not runs.has(key):
			runs[key] = []
		(runs[key] as Array).append(g)
	for key: Array in runs:
		var axis: int = key[0]
		var list: Array = runs[key]
		list.sort_custom(func(a: Array, b: Array) -> bool: return float(a[axis]) < float(b[axis]))
		var cur: Array = (list[0] as Array).duplicate()
		for i in range(1, list.size()):
			var g: Array = list[i]
			var cur_end := float(cur[axis]) + float(cur[2 + axis])
			var g_start := float(g[axis]) - float(g[2 + axis])
			if g_start <= cur_end + JOIN_SLACK:
				var lo := float(cur[axis]) - float(cur[2 + axis])
				var hi := maxf(cur_end, float(g[axis]) + float(g[2 + axis]))
				cur[axis] = (lo + hi) * 0.5
				cur[2 + axis] = (hi - lo) * 0.5
				cur[6] = minf(float(cur[6]), float(g[6]))
			else:
				out.append(cur)
				cur = g.duplicate()
		out.append(cur)
	return out


## Fills (or makes, or frees) the chunk's ring MultiMesh from what collect() gathered. Returns the
## node to keep (null when there are none).
static func apply(parent: Node3D, node: MultiMeshInstance3D, rings: Array) -> MultiMeshInstance3D:
	if rings.is_empty():
		if node != null:
			node.queue_free()
		return null
	if node == null:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = ring_mesh()
		node = MultiMeshInstance3D.new()
		node.name = "ContactShade"
		node.multimesh = mm
		node.material_override = material()
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		parent.add_child(node)
	node.visible = enabled
	rings = joined(rings)
	var sides := _sides(rings)
	var mm := node.multimesh
	if mm.instance_count != rings.size():
		mm.instance_count = rings.size()
	var lo := Vector2.INF
	var hi := -Vector2.INF
	for i in rings.size():
		var g: Array = rings[i]
		var patch := float(g[5])
		var reach := PATCH_REACH if patch > 0.0 else REACH
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(g[0], 0.0, g[1])))
		mm.set_instance_custom_data(i, Color(g[2], g[3], g[6], patch))
		mm.set_instance_color(i, sides[i])
		lo = lo.min(Vector2(g[0] - g[2] - reach, g[1] - g[3] - reach))
		hi = hi.max(Vector2(g[0] + g[2] + reach, g[1] + g[3] + reach))
	# The vertex shader places the corners: the bounds are the rings' own (grown by the hills).
	var box := AABB(Vector3(lo.x, 0.0, lo.y), Vector3(hi.x - lo.x, 0.05, hi.y - lo.y))
	node.custom_aabb = box
	GroundHeight.cull_box(node, box)
	return node


## Each ring's rim strength per side (east, west, south, north as r, g, b, a): its style's, halved
## on a side another ring's rectangle faces within NEIGHBOUR_GAP (found through a grid of tiles).
static func _sides(rings: Array) -> Array[Color]:
	var grid := {}  # Vector2i tile -> ring indices touching it (grown by the gap)
	for i in rings.size():
		var g: Array = rings[i]
		var gx: float = g[0]
		var gz: float = g[1]
		var hx: float = g[2]
		var hz: float = g[3]
		for x in range(floori(gx - hx - NEIGHBOUR_GAP), floori(gx + hx + NEIGHBOUR_GAP) + 1):
			for y in range(floori(gz - hz - NEIGHBOUR_GAP), floori(gz + hz + NEIGHBOUR_GAP) + 1):
				var t := Vector2i(x, y)
				if not grid.has(t):
					grid[t] = []
				(grid[t] as Array).append(i)
	var out: Array[Color] = []
	out.resize(rings.size())
	for i in rings.size():
		var g: Array = rings[i]
		var gx: float = g[0]
		var gz: float = g[1]
		var hx: float = g[2]
		var hz: float = g[3]
		var s: float = g[4]
		var side := PackedFloat32Array([s, s, s, s])  # east, west, south, north
		var seen := {}
		for x in range(floori(gx - hx), floori(gx + hx) + 1):
			for y in range(floori(gz - hz), floori(gz + hz) + 1):
				for j: int in grid.get(Vector2i(x, y), []):
					if j == i or seen.has(j):
						continue
					seen[j] = true
					var o: Array = rings[j]
					var ox: float = o[0]
					var oz: float = o[1]
					# The gaps between the two rectangles along x and z (< 0: they overlap that way).
					var dx := absf(ox - gx) - float(o[2]) - hx
					var dz := absf(oz - gz) - float(o[3]) - hz
					if dx < NEIGHBOUR_GAP and dz < 0.0:
						var k := 0 if ox > gx else 1
						side[k] = minf(side[k], s * (0.5 + 0.5 * clampf(dx / NEIGHBOUR_GAP, 0.0, 1.0)))
					elif dz < NEIGHBOUR_GAP and dx < 0.0:
						var k := 2 if oz > gz else 3
						side[k] = minf(side[k], s * (0.5 + 0.5 * clampf(dz / NEIGHBOUR_GAP, 0.0, 1.0)))
		out[i] = Color(side[0], side[1], side[2], side[3])
	return out


## The ring every building shares: an 11 x 11 grid of which only the outer band is drawn. Its
## vertices' x and z say where along the inner rectangle (-1 to 1, the shader scales them to the
## building), UV says which are on the outer edge (-1 or 1; 0 inside).
static func ring_mesh() -> ArrayMesh:
	if _ring != null:
		return _ring
	var cols: Array = []  # [inner place, outer flag]
	cols.append([-1.0, -1.0])
	for k in TICKS + 1:
		cols.append([-1.0 + 2.0 * float(k) / float(TICKS), 0.0])
	cols.append([1.0, 1.0])
	var n := cols.size()
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	for zi in n:
		for xi in n:
			verts.append(Vector3(cols[xi][0], 0.0, cols[zi][0]))
			uvs.append(Vector2(cols[xi][1], cols[zi][1]))
	var idx := PackedInt32Array()
	for zi in n - 1:
		for xi in n - 1:
			if xi != 0 and xi != n - 2 and zi != 0 and zi != n - 2:
				continue  # under the building
			var a := zi * n + xi
			idx.append_array([a, a + 1, a + n, a + 1, a + n + 1, a + n])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	_ring = ArrayMesh.new()
	_ring.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return _ring


static func material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = SHADER
		# Faded by how close the view is, by ao_zoom.gd's thresholds (the one place for them).
		_material.set_shader_parameter("fade_from", AoZoom.RIM_FULL)
		_material.set_shader_parameter("fade_to", AoZoom.RIM_GONE)
		# After the decoratives (-128 to -2: grass at a building's foot darkens too), before ghosts,
		# smoke and icons.
		_material.render_priority = -1
	return _material


## Settings > Graphics > Contact shading: shows or hides every chunk's rings (chunk views: `chunks`).
static func set_enabled(on: bool, chunks: Array) -> void:
	enabled = on
	for cv in chunks:
		var node = cv.get("contact_node")
		if node is MultiMeshInstance3D and is_instance_valid(node):
			(node as MultiMeshInstance3D).visible = on

