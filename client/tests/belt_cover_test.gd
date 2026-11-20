extends SceneTree
## The covered space under a belt's top run (belt_return.gd cover; the shader's belt_cover): a straight's top
## run gives its lowest y and its |x| range, a curve's the distance range from its centre, nothing without a
## top run, and --belt-cover=off gives none. Shaded in the shader: the rollers and the return strip, not the rails.
##   godot --headless --path client -s res://tests/belt_cover_test.gd

const BeltReturn := preload("res://scripts/world/belt_return.gd")

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _arrays(verts: PackedVector3Array, normal: Vector3) -> Array:
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = verts
	var n := PackedVector3Array()
	for _v in verts:
		n.append(normal)
	a[Mesh.ARRAY_NORMAL] = n
	return a


func _init() -> void:
	var top := _arrays(PackedVector3Array([Vector3(-0.35, 0.25, -0.5), Vector3(0.35, 0.25, -0.5), Vector3(0.35, 0.26, 0.5), Vector3(-0.35, 0.26, 0.5)]), Vector3.UP)
	var c := BeltReturn.cover(top, 0)
	check(c.w == 1.0 and is_equal_approx(c.x, 0.25) and is_equal_approx(c.y, 0.0) and is_equal_approx(c.z, 0.35), "straight: lowest y and |x| range (%s)" % c)
	var chamfer := _arrays(PackedVector3Array([Vector3(-0.35, 0.23, -0.5), Vector3(-0.32, 0.25, -0.5), Vector3(0.32, 0.25, -0.5), Vector3(0.35, 0.23, -0.5)]), Vector3.UP)
	var cc := BeltReturn.cover(chamfer, 0)
	check(cc.y == 0.0 and is_equal_approx(cc.z, 0.35) and is_equal_approx(cc.x, 0.23), "straight, chamfered edges, no middle verts: band starts at the axis (%s)" % cc)
	var curve := BeltReturn.cover(_arrays(PackedVector3Array([Vector3(-0.5, 0.25, -0.5 + 0.3), Vector3(-0.5, 0.25, -0.5 + 0.7), Vector3(0.0, 0.25, 0.0)]), Vector3.UP), 1)
	check(curve.w == 1.0 and curve.y < curve.z, "curve: a radial range (%s)" % curve)
	check(BeltReturn.cover(_arrays(PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)]), Vector3.DOWN), 0) == Vector4.ZERO, "no top run, no cover")
	BeltReturn.cover_on = false
	check(BeltReturn.cover(top, 0) == Vector4.ZERO, "--belt-cover=off: none")
	BeltReturn.cover_on = true
	print("BELT COVER FAILS: %d" % fails)
	quit(1 if fails > 0 else 0)
