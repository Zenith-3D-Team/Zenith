extends SceneTree
## Cliffs seated in their terrace (--cliff-fit): GroundHeight.cliff_lift, the CPU twin of the shaders'
## ground_lift_cliff (ground_height.gdshaderinc), on the Placeholders pack's real straight piece over a
## synthetic two-channel field with Terrain Elevation 0.1.7's hard step, for the three facings (each
## has its own phase against the field's 2-tile texels). And the field's images: a three-channel one
## (blue: how near a cliff, the ground's tint there) accepted, two- and one-channel ones as before.
##   godot --headless --audio-driver Dummy --path client -s res://tests/cliff_fit_test.gd

const GroundHeight := preload("res://scripts/world/ground_height.gd")
const AddonTerrain := preload("res://scripts/addons/addon_terrain.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const Visuals := preload("res://scripts/world/visuals.gd")

const STEP := 2.0
const SIZE := 128
const ORIGIN := Vector2(-128.0, -128.0)  # texel centres at odd tiles, as Terrain Elevation's
## [orientation, the cliff's position, unit towards its high side]. Factorio's cliffs sit at even x
## and y + 0.5.
const FACINGS := [
	["west-to-east", Vector2(0.0, 0.5), Vector2(0.0, -1.0)],
	["east-to-west", Vector2(0.0, 0.5), Vector2(0.0, 1.0)],
	["north-to-south", Vector2(0.0, 0.0), Vector2(1.0, 0.0)],
	["south-to-north", Vector2(0.0, 0.5), Vector2(-1.0, 0.0)],
]
## Corners (Terrain Elevation 0.1.8 steps round them on the rock's own quarter circle, round the cell's
## corner between the edges it joins): [orientation, position, the cell corner, high inside the arc].
const CORNERS := [
	["west-to-north", Vector2(0.0, 0.5), Vector2(-2.0, -1.5), true],
	["north-to-east", Vector2(0.0, 0.5), Vector2(2.0, -1.5), true],
	["east-to-south", Vector2(0.0, 0.5), Vector2(2.0, 2.5), true],
	["south-to-west", Vector2(0.0, 0.5), Vector2(-2.0, 2.5), true],
	["west-to-south", Vector2(0.0, 0.5), Vector2(-2.0, 2.5), false],
	["north-to-west", Vector2(0.0, 0.5), Vector2(-2.0, -1.5), false],
	["east-to-north", Vector2(0.0, 0.5), Vector2(2.0, -1.5), false],
	["south-to-east", Vector2(0.0, 0.5), Vector2(2.0, 2.5), false],
]

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


## The low ground: a gentle slope, so nothing passes by being at 0.
static func _hills(p: Vector2) -> float:
	return 0.4 + 0.01 * p.x - 0.006 * p.y


## A two-channel field: red the ground with a terrace `d` tiles high on the high side of a straight
## line through `at` (Terrain Elevation 0.1.7's step, -0.2 to 0.2 tiles across it), green without.
static func _field(at: Vector2, up: Vector2, d: float, channels := 2, side_of := Callable()) -> Image:
	var fmt := Image.FORMAT_RGBF if channels == 3 else Image.FORMAT_RGF
	var img := Image.create(SIZE, SIZE, false, fmt)
	for j in SIZE:
		for i in SIZE:
			var c := ORIGIN + (Vector2(i, j) + Vector2(0.5, 0.5)) * STEP
			var low := _hills(c)
			var side: float = side_of.call(c) if side_of.is_valid() else (c - at).dot(up)
			var high := low + d * smoothstep(-0.2, 0.2, side)
			var near := 1.0 - smoothstep(1.5, 6.0, absf(side))
			img.set_pixel(i, j, Color(high, low, near if channels == 3 else 0.0))
	return img


## The piece's vertices in its own space (the model's nodes' transforms applied).
static func _piece(name: String) -> PackedVector3Array:
	var out := PackedVector3Array()
	var scene := load("res://assets/models/packs/placeholders/%s.glb" % name) as PackedScene
	if scene == null:
		return out
	var root := scene.instantiate()
	var stack: Array = [[root, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var e: Array = stack.pop_back()
		var node: Node = e[0]
		var xf: Transform3D = e[1]
		if node is Node3D and node != root:
			xf = xf * (node as Node3D).transform
		if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			var mesh := (node as MeshInstance3D).mesh
			for s in mesh.get_surface_count():
				for v: Vector3 in mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
					out.append(xf * v)
		for c in node.get_children():
			stack.append([c, xf])
	root.free()
	return out


func _init() -> void:
	var verts := _piece("cliff-sides")
	check(verts.size() > 100, "the Placeholders pack's cliff-sides piece has its vertices (%d)" % verts.size())
	for fa in FACINGS:
		_facing(verts, str(fa[0]), fa[1], fa[2])
	for co in CORNERS:
		var piece := _piece("cliff-%s" % ("outer" if co[3] else "inner"))
		check(piece.size() > 100, "the %s corner piece has its vertices" % co[0])
		_corner(piece, str(co[0]), co[1], co[2], co[3])
	_normals()
	_images()
	print("cliff_fit_test: %s" % ("PASS" if fails == 0 else "FAILS %d" % fails))
	quit(1 if fails else 0)


## Each vertex of the piece placed as world.gd turns it (ModelLibrary.CLIFF_PIECES), then lifted.
func _facing(verts: PackedVector3Array, orientation: String, at: Vector2, up: Vector2) -> void:
	var dir := int(ModelLibrary.CLIFF_PIECES[orientation][1])
	var place := Transform3D(Basis(Vector3.UP, Visuals.direction_yaw(dir)), Vector3(at.x, 0.0, at.y))
	var face_dir := place.basis * Vector3(0, 0, 1)  # the model's face looks +z (south) before turning
	check(Vector2(face_dir.x, face_dir.z).dot(up) < -0.99, "%s: the piece's face looks away from the high side" % orientation)
	for d in [2.2, 6.0, 0.0]:
		GroundHeight.set_field(_field(at, up, d), ORIGIN, STEP)
		var top := -INF
		var top_old := -INF
		var under := 0.0  # the most any vertex stands under the drawn ground
		var foot_off := 0.0  # the most a vertex a tile or more out is moved off the low ground + its height
		var clamped := 0  # vertices in front of the line, above the model's ground, raised by "never under the high ground"
		var clamp_max := 0.0
		var clamp_far := 0.0  # the furthest out in front of the line such a vertex is
		var face_top := -INF  # the highest of the face in front of the line, over the drawn ground there
		var flat_err := 0.0
		for v in verts:
			var w := place * v
			var p := Vector2(w.x, w.z)
			var out := -(p - at).dot(up)  # tiles in front of the line (the low side)
			var y := GroundHeight.cliff_lift(w.x, w.y, w.z)
			var g := GroundHeight.at3(w.x, w.z)
			top = maxf(top, y)
			top_old = maxf(top_old, w.y + g.y)
			under = maxf(under, g.x - y)
			var free := g.y + w.y * maxf(1.0, GroundHeight.terrace_near(w.x, w.z) * 0.5)
			if out >= 1.0 and w.y >= 0.0:
				foot_off = maxf(foot_off, absf(y - free) + absf(g.x - g.y))
			if out > 0.0 and w.y >= 0.0 and y > free + 0.01:
				clamped += 1
				clamp_max = maxf(clamp_max, y - free)
				clamp_far = maxf(clamp_far, out)
			if out >= 0.3:
				face_top = maxf(face_top, y - g.x)
			if d == 0.0:
				flat_err = maxf(flat_err, absf(y - (w.y + g.y)))
		var low_at := _hills(at)
		var what := "%s, terrace %.1f" % [orientation, d]
		print("%s: top %.2f over the low ground (as before %.2f), face %.2f over the ground in front, %d front vertices raised (at most %.2f, up to %.2f tiles out)" % [
			what, top - low_at, top_old - low_at, face_top, clamped, clamp_max, clamp_far])
		check(under <= 0.1 + 1e-4, "%s: no vertex more than 0.1 tile under the ground (%.3f)" % [what, under])
		if orientation != "east-to-west":
			# (A north-facing cliff's field ramps a tile onto its low side: texel phase. Its face looks
			# away from the camera; the clamp there stands its feet on that ramp instead.)
			check(foot_off < 0.01, "%s: a tile or more out the rock stands on the low ground, the drawn ground (%.3f off)" % [what, foot_off])
		if d == 0.0:
			check(flat_err < 1e-4, "%s: no terrace: low ground + height, as before (%.5f)" % [what, flat_err])
			continue
		check(top >= low_at + d - 0.05, "%s: the rock reaches the terrace behind it (top %.2f, terrace %.2f)" % [what, top - low_at, d])
		check(top - low_at >= 2.5, "%s: never smaller than Factorio's (top %.2f)" % [what, top - low_at])
		if d > 4.0:
			check(top - low_at > top_old - low_at + 1.0, "%s: grown with the taller terrace (%.2f, was %.2f)" % [what, top - low_at, top_old - low_at])
		# On east-to-west (north-facing), the 2-tile texel phase ramps g.x up onto the low side and
		# the fused wall's shorter front blocks + scree apron clear it by ~1.08 tiles on terrace 2.2.
		var min_face := 1.0 if orientation == "east-to-west" else 1.2
		check(face_top >= min_face, "%s: the face stands clear of the ground in front (%.2f)" % [what, face_top])
	# --cliff-fit=off: on the low ground at its own height, as before.
	GroundHeight.set_field(_field(at, up, 2.2), ORIGIN, STEP)
	GroundHeight.cliff_fit = false
	var err := 0.0
	for v in verts:
		var w := place * v
		err = maxf(err, absf(GroundHeight.cliff_lift(w.x, w.y, w.z) - (w.y + GroundHeight.at3(w.x, w.z).y)))
	check(err < 1e-4, "%s: --cliff-fit=off is the low ground + height (%.5f)" % [orientation, err])
	GroundHeight.cliff_fit = true
	GroundHeight.clear()


## Which side of a corner's quarter circle (radius 2 round `corner`) a point is, + the high side.
static func _arc_side(p: Vector2, corner: Vector2, high_inside: bool) -> float:
	var r := p.distance_to(corner)
	return (2.0 - r) if high_inside else (r - 2.0)


## A corner piece over a field stepping on its own quarter circle: the rock seated (nothing more than
## 0.1 under the ground, its foot never standing over the ground in front, which would leave a groove
## under it, its top on the terrace), for every corner Factorio has. (Where the field's 2-tile texels
## put the step's ramp a tile or so onto the low side, the clamp stands the front feet on it: printed.)
func _corner(verts: PackedVector3Array, orientation: String, at: Vector2, corner: Vector2, high_inside: bool) -> void:
	var dir := int(ModelLibrary.CLIFF_PIECES[orientation][1])
	var place := Transform3D(Basis(Vector3.UP, Visuals.direction_yaw(dir)), Vector3(at.x, 0.0, at.y))
	var side_of := func(p: Vector2) -> float: return _arc_side(p, corner, high_inside)
	var d := 2.2
	GroundHeight.set_field(_field(at, Vector2.ZERO, d, 2, side_of), ORIGIN, STEP)
	var under := 0.0
	var foot_off := 0.0
	var top := -INF
	var arc_err := 0.0  # how far the rock's crest line (its highest points) lies from the arc
	var over := 0.0  # the most a foot vertex in front stands over the drawn ground
	for v in verts:
		var w := place * v
		var p := Vector2(w.x, w.z)
		var out := -_arc_side(p, corner, high_inside)
		var y := GroundHeight.cliff_lift(w.x, w.y, w.z)
		var g := GroundHeight.at3(w.x, w.z)
		under = maxf(under, g.x - y)
		top = maxf(top, y - _hills(p))
		var free := g.y + w.y * maxf(1.0, GroundHeight.terrace_near(w.x, w.z) * 0.5)
		if out >= 1.0 and w.y >= 0.0:
			foot_off = maxf(foot_off, absf(y - free) + absf(g.x - g.y))
		if w.y > 2.5 * 0.6:
			arc_err = maxf(arc_err, absf(out))
		if out >= 0.5 and w.y <= 0.05:
			over = maxf(over, y - g.x)
	var what := "%s (%s corner)" % [orientation, "outer" if high_inside else "inner"]
	print("%s: top %.2f over the low ground, the crest within %.2f tiles of the arc, feet at most %.3f over the ground in front, %.2f off the low ground a tile out" % [
		what, top, arc_err, over, foot_off])
	check(arc_err < 1.0, "%s: the rock's crest on the arc the field steps on (%.2f tiles off)" % [what, arc_err])
	check(under <= 0.1 + 1e-4, "%s: no vertex more than 0.1 tile under the ground (%.3f)" % [what, under])
	check(over <= 0.06, "%s: the rock's feet on the ground in front, no groove under them (%.3f over)" % [what, over])
	check(top >= d - 0.05, "%s: the rock reaches the terrace behind it (top %.2f)" % [what, top])
	GroundHeight.clear()


## The ground's shading normal in front of a cliff (GroundHeight.normal, the shaders' ground_n): flat
## ground a tile or two out from the rock is shaded flat; read a texel out (--cliff-ground-normal=old)
## it took the step's slope (21 degrees here for a 2.5-tile terrace, more on the add-on's own field).
func _normals() -> void:
	for fa in FACINGS:
		var at: Vector2 = fa[1]
		var up: Vector2 = fa[2]
		GroundHeight.set_field(_field(at, up, 2.5), ORIGIN, STEP)
		var flat := Vector3(-0.01, 1.0, 0.006).normalized()  # _hills' own slope
		var least_new := 1.0
		var least_old := 1.0
		for k in range(3, 11):  # 0.75 to 2.5 tiles out on the low side
			for along in [-1.0, 0.3, 1.7]:
				var p: Vector2 = at - up * (k * 0.25) + Vector2(up.y, -up.x) * along
				# Only where the drawn ground is flat (a north-facing cliff's ramp lies a tile onto its low side).
				var g0 := GroundHeight.at3(p.x - up.x * 0.6, p.y - up.y * 0.6)
				var g1 := GroundHeight.at3(p.x + up.x * 0.6, p.y + up.y * 0.6)
				if absf((g1.x - g1.y) - (g0.x - g0.y)) > 1e-3:
					continue
				GroundHeight.cliff_normal = true
				least_new = minf(least_new, GroundHeight.normal(p.x, p.y).dot(flat))
				GroundHeight.cliff_normal = false
				least_old = minf(least_old, GroundHeight.normal(p.x, p.y).dot(flat))
		GroundHeight.cliff_normal = true
		print("%s: flat ground in front shaded %.1f degrees off (old %.1f)" % [fa[0], rad_to_deg(acos(least_new)), rad_to_deg(acos(least_old))])
		check(least_new > 0.9999, "%s: flat ground in front of the rock shaded flat (%.4f)" % [fa[0], least_new])
		check(least_old < 0.95, "%s: --cliff-ground-normal=old shaded it as the step's slope (%.4f)" % [fa[0], least_old])
	# No terraces: the normal as it was, from the ground's own slope.
	var one := Image.create(SIZE, SIZE, false, Image.FORMAT_RF)
	for j in SIZE:
		for i in SIZE:
			one.set_pixel(i, j, Color(_hills(ORIGIN + (Vector2(i, j) + Vector2(0.5, 0.5)) * STEP), 0, 0))
	GroundHeight.set_field(one, ORIGIN, STEP)
	var n1 := GroundHeight.normal(3.0, 5.0)
	check(n1.is_equal_approx(Vector3(-0.01, 1.0, 0.006).normalized()), "a one-channel field: its own slope (%s)" % str(n1))
	GroundHeight.clear()
	check(GroundHeight.normal(3.0, 5.0) == Vector3.UP, "no field: up")
	var inc := FileAccess.get_file_as_string("res://shaders/ground_height.gdshaderinc")
	check(inc.contains("GROUND_N_TERRACE") and inc.contains("f3d_cliff_normal"), "the shaders' ground_n reads the terraces' slope where it is")
	check(FileAccess.get_file_as_string("res://project.godot").contains("f3d_cliff_normal={"), "the shaders' f3d_cliff_normal is declared")


func _images() -> void:
	var at := Vector2(0.0, 0.5)
	var up := Vector2(0.0, -1.0)
	var p := Vector2(3.0, 2.0)
	# Three channels: kept as they are, green the low ground, blue how near a cliff.
	var img3 := _field(at, up, 2.2, 3)
	GroundHeight.set_field(img3, ORIGIN, STEP)
	check(GroundHeight._has_low(GroundHeight._image) and GroundHeight._image.get_format() == Image.FORMAT_RGBF,
		"a three-channel field is kept as it is, its green the low ground")
	var g := GroundHeight.at3(p.x, p.y)
	check(g.z > 0.5 and g.z <= 1.0, "a three-channel field's blue read (%.2f)" % g.z)
	check(absf(g.x - GroundHeight.at(p.x, p.y)) < 1e-5 and g.y < g.x + 1e-5, "and its red and green as before (%s)" % str(g))
	check(is_equal_approx(GroundHeight.cliff_near(p.x, p.y), g.z), "cliff_near reads blue")
	var tiny := Image.create(2, 2, false, Image.FORMAT_RGBF)
	tiny.fill(Color(1.0, 0.5, 9.0))
	var r := GroundHeight._range_of(tiny.get_data(), 3)
	check(r == Vector2(0.0, 1.0), "the lift's range from red and green only, not blue (%s)" % str(r))
	# (The headless renderer keeps no global uniforms to read back: the defaults are checked in the project.)
	check(GroundHeight.cliff_tint and GroundHeight.cliff_fit, "the switches on by default")
	var proj := FileAccess.get_file_as_string("res://project.godot")
	check(proj.contains("f3d_cliff_fit={") and proj.contains("f3d_cliff_tint={"), "the shaders' cliff globals are declared")
	# Two channels: as before, no blue.
	GroundHeight.set_field(_field(at, up, 2.2, 2), ORIGIN, STEP)
	var g2 := GroundHeight.at3(p.x, p.y)
	check(g2.z == 0.0 and absf(g2.x - g.x) < 1e-5 and absf(g2.y - g.y) < 1e-5, "a two-channel field as before, blue 0 (%s)" % str(g2))
	# One channel: its height for both, and cliffs seated on it as before (nothing to seat in).
	var one := Image.create(SIZE, SIZE, false, Image.FORMAT_RF)
	one.fill(Color(1.5, 0, 0))
	GroundHeight.set_field(one, ORIGIN, STEP)
	var g1 := GroundHeight.at3(p.x, p.y)
	check(is_equal_approx(g1.x, 1.5) and is_equal_approx(g1.y, 1.5) and g1.z == 0.0, "a one-channel field: its height twice, blue 0 (%s)" % str(g1))
	check(is_equal_approx(GroundHeight.cliff_lift(p.x, 0.7, p.y), 2.2), "a cliff on a one-channel field: ground + height")
	GroundHeight.clear()
	check(GroundHeight.cliff_lift(p.x, 0.7, p.y) == 0.7, "no field: as drawn")
	# api.terrain says it reads three channels (the add-on asks before giving them).
	var t := AddonTerrain.new(null, null)
	check(t.has_method("channels") and t.channels() == 3, "api.terrain.channels() is 3")
