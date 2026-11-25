extends SceneTree
## Nauvis's cliffs as one generated wall (cliff_wall.gd, --cliff-wall=on): off by default; neighbours weld
## (a straight run, outer and inner corners, a chain's ends: the vertices on their shared edge are the same
## from both cells at every level of detail); deterministic by position (a cell built twice, or among other
## cells in another order, gives the same triangles; another position another wall); the levels get coarser;
## which cliffs it covers.
##   godot --headless --audio-driver Dummy --path client -s res://tests/cliff_wall_test.gd

const CliffWall := preload("res://scripts/world/cliff_wall.gd")
const Settings := preload("res://scripts/menu/settings.gd")

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


## A cliff's cell at `pos` (Factorio's cliffs sit at even x and y + 0.5).
static func _cell(pos: Vector2, co: String) -> Array:
	return CliffWall.cell(pos, Vector2i(roundi(pos.x * 256.0), roundi(pos.y * 256.0)), co)


static func _verts(cells: Array, level: int) -> PackedVector3Array:
	var out := CliffWall.Builder.new()
	for c: Array in cells:
		CliffWall.build_cell(out, c, level)
	return out.verts


## The vertices lying on the plane x = at (axis 0) or z = at (axis 2), as rounded keys.
static func _on_plane(verts: PackedVector3Array, axis: int, at: float, shift := Vector3.ZERO) -> Dictionary:
	var out := {}
	for v in verts:
		if absf(v[axis] - at) < 1e-4:
			var p := v + shift
			out[Vector3i(roundi(p.x * 1000.0), roundi(p.y * 1000.0), roundi(p.z * 1000.0))] = true
	return out


static func _same(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a:
		if not b.has(k):
			return false
	return true


func _weld(name: String, a: Array, b: Array, axis: int, at: float) -> void:
	for level in CliffWall.LEVELS:
		var pa := _on_plane(_verts([a], level), axis, at)
		var pb := _on_plane(_verts([b], level), axis, at)
		check(pa.size() >= CliffWall.PROFILE.size(), "%s level %d: %d vertices on the shared edge" % [name, level, pa.size()])
		check(_same(pa, pb), "%s level %d: the shared edge differs (%d vs %d vertices)" % [name, level, pa.size(), pb.size()])


func _initialize() -> void:
	# On by default: no switch on the command line, the setting on; --cliff-wall=off (or the setting off) gives the pieces.
	check(CliffWall.on and not CliffWall.arg_off, "the wall is on without --cliff-wall=off")
	var defaults: Dictionary = Settings.DEFAULTS
	if defaults.has("graphics"):
		check(defaults["graphics"].get("cliff_wall", false) == true, "Settings' cliff_wall is on by default")
	CliffWall.set_on(false)
	check(not CliffWall.covers("cliff", {"co": "west-to-east"}), "off: no cliff covered")

	# Welds. A straight run west to east: (2, 2.5) and (6, 2.5) meet at x = 4.
	var a := _cell(Vector2(2.0, 2.5), "west-to-east")
	_weld("straight run", a, _cell(Vector2(6.0, 2.5), "west-to-east"), 0, 4.0)
	# An outer corner (turning left, west to north) after it, and the run going on north from it (z = 0.5).
	var outer := _cell(Vector2(6.0, 2.5), "west-to-north")
	_weld("into an outer corner", a, outer, 0, 4.0)
	_weld("out of an outer corner", outer, _cell(Vector2(6.0, -1.5), "south-to-north"), 2, 0.5)
	# An inner corner (turning right, west to south) and on south from it (z = 4.5).
	var inner := _cell(Vector2(6.0, 2.5), "west-to-south")
	_weld("into an inner corner", a, inner, 0, 4.0)
	_weld("out of an inner corner", inner, _cell(Vector2(6.0, 6.5), "north-to-south"), 2, 4.5)
	# A chain's ends: an entrance before it (x = 0), an exit after it.
	_weld("from an entrance", _cell(Vector2(-2.0, 2.5), "none-to-east"), a, 0, 0.0)
	_weld("into an exit", a, _cell(Vector2(6.0, 2.5), "west-to-none"), 0, 4.0)
	# The other facings: north to south (x = 0 cells, y edges), east to west.
	_weld("north to south", _cell(Vector2(0.0, 0.5), "north-to-south"), _cell(Vector2(0.0, 4.5), "north-to-south"), 2, 2.5)
	_weld("east to west", _cell(Vector2(6.0, 2.5), "east-to-west"), _cell(Vector2(2.0, 2.5), "east-to-west"), 0, 4.0)
	# The check can fail: a cell 4 tiles further on has an edge of its own (seeded by its own position).
	var far_edge := _on_plane(_verts([_cell(Vector2(10.0, 2.5), "west-to-east")], 0), 0, 8.0, Vector3(-4.0, 0.0, 0.0))
	check(not _same(_on_plane(_verts([a], 0), 0, 4.0), far_edge), "an unshared edge differs (the weld check means something)")

	# Deterministic by position, independent of neighbours and order.
	var once := _verts([a], 0)
	check(once == _verts([a], 0), "a cell built twice is the same")
	var b := _cell(Vector2(6.0, 2.5), "west-to-east")
	var ab := _verts([a, b], 0)
	var ba := _verts([b, a], 0)
	var sa := {}
	var sb := {}
	for v in ab:
		sa[Vector3i(roundi(v.x * 1000.0), roundi(v.y * 1000.0), roundi(v.z * 1000.0))] = true
	for v in ba:
		sb[Vector3i(roundi(v.x * 1000.0), roundi(v.y * 1000.0), roundi(v.z * 1000.0))] = true
	check(ab.size() == ba.size() and _same(sa, sb), "a chunk's cells in another order give the same wall")
	var shifted := _verts([_cell(Vector2(10.0, 2.5), "west-to-east")], 0)
	var moved := PackedVector3Array()
	for v in shifted:
		moved.append(v - Vector3(8.0, 0.0, 0.0))
	check(moved != once, "another position gives another wall (variety)")

	# Levels get coarser; each level has every cell.
	var tris := []
	for level in CliffWall.LEVELS:
		tris.append(_verts([a], level).size() / 3)
	print("triangles a cell, levels 0-2: ", tris, "  outer corner: ", _verts([outer], 0).size() / 3)
	check(tris[0] > tris[1] and tris[1] > tris[2] and tris[2] > 0, "levels coarser in turn")

	# Nothing taller than the rock, nothing far below its ground (the deck's back lip, -0.3, the lowest), nothing past the cell's reach.
	var lo := INF
	var hi := -INF
	for v in once:
		lo = minf(lo, v.y)
		hi = maxf(hi, v.y)
	check(hi <= CliffWall.HEIGHT * 1.25 and lo >= -0.35, "heights within the rock (%.2f to %.2f)" % [lo, hi])

	# Which cliffs it covers once on: Nauvis's with a known orientation; not other planets', not unknown ones.
	CliffWall.on = true
	check(CliffWall.covers("cliff", {"co": "west-to-east"}), "on: Nauvis's cliff covered")
	check(not CliffWall.covers("cliff-vulcanus", {"co": "west-to-east"}), "on: Vulcanus's cliffs keep their pieces")
	check(not CliffWall.covers("cliff", {"co": "sideways"}), "on: an unknown orientation keeps its piece")
	check(_cell(Vector2(2.0, 2.5), "none-to-none").is_empty(), "none-to-none is no cell")
	CliffWall.on = false
	# A whole job off the main thread's way (as a chunk's): three levels of arrays.
	var job := CliffWall.Job.new()
	job.cells = [a, b, outer]
	CliffWall.run_job(job)
	check(job.arrays.size() == CliffWall.LEVELS and not (job.arrays[0] as Array).is_empty(), "a job builds every level")
	print("job: %d triangles, %.2f ms" % [job.triangles, job.usec / 1000.0])

	print("CLIFF WALL FAILS: %d" % fails)
	quit(1 if fails > 0 else 0)
