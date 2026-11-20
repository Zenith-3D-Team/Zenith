extends SceneTree
## A modeller's belt surface lies on the ground with its return strip: the contact map (contact_shade.gd
## mask_of) must not take that underside for contact (owner: a dark pixelated patch with chevrons under the belt).
## The rails beside it still are.
##   godot --headless --audio-driver Dummy --path client -s res://tests/contact_belt_under_test.gd

const Contact := preload("res://scripts/world/contact_shade.gd")

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


## A flat rectangle's group at height y, its normal up or down, its material's name.
func _quad(name: String, x0: float, x1: float, z0: float, z1: float, y: float, ny: float) -> Array:
	var m := StandardMaterial3D.new()
	m.resource_name = name
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	m.albedo_texture = ImageTexture.create_from_image(img)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3(0, ny, 0), Vector3(0, ny, 0), Vector3(0, ny, 0), Vector3(0, ny, 0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	return [[[m, 0]], arrays, 0]


## The mask's texel at model (x, z).
func _at(mask: Array, x: float, z: float) -> int:
	var r: Rect2 = mask[0]
	var n := Contact.MASK_SIZE
	var tx := clampi(int((x - r.position.x) / r.size.x * n), 0, n - 1)
	var tz := clampi(int((z - r.position.y) / r.size.y * n), 0, n - 1)
	return (mask[1] as PackedByteArray)[tz * n + tx]


func _init() -> void:
	var rails := _quad("Belt_Base", -0.5, 0.5, 0.375, 0.41, 0.0, 1.0)
	var rails2 := _quad("Belt_Base", -0.5, 0.5, -0.41, -0.375, 0.0, 1.0)
	var under := _quad("Belt_Surface", -0.5, 0.5, -0.32, 0.32, 0.0065, -1.0)
	var top := _quad("Belt_Surface", -0.5, 0.5, -0.32, 0.32, 0.25, 1.0)
	var groups := [rails, rails2, under, top]
	var m := Contact.mask_of(groups, [], false)
	check(not m.is_empty(), "the belt has a contact map")
	if not m.is_empty():
		check(_at(m, 0.0, 0.0) > 100, "under a belt surface's return the ground isn't contact (%d)" % _at(m, 0.0, 0.0))
		check(_at(m, 0.0, 0.39) < 10, "the rail is (%d)" % _at(m, 0.0, 0.39))
	Contact.belt_under = true
	var old := Contact.mask_of(groups, [], false)
	check(_at(old, 0.0, 0.0) < 10, "--contact-belt-under=on: as before (%d)" % _at(old, 0.0, 0.0))
	Contact.belt_under = false
	print("CONTACT BELT UNDER FAILS: %d" % fails)
	quit(1 if fails > 0 else 0)
