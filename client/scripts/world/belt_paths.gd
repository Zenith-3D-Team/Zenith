extends RefCounted
## Paths of items on belts that don't go in a straight line (curves, undergrounds): points the same
## distance apart along their lanes, an offset from the item's place and 1 where it shows (0 under
## the ground). belt_items.gd makes them from the simulated lanes; belt_path.gdshaderinc draws them
## from the paths' texture, and path_at() works out the same on the CPU.


## Where along its path's points an item is at t (0 to 1), as belt_path.gdshaderinc works it out:
## x, y, z from its place, w 1 where it shows.
static func path_at(path: PackedFloat32Array, t: float) -> Vector4:
	var pieces := path.size() / 4 - 1
	var f := clampf(t, 0.0, 1.0) * pieces
	var i := mini(int(f), pieces - 1)
	var u := f - i
	var a := i * 4
	return Vector4(lerpf(path[a], path[a + 4], u), lerpf(path[a + 1], path[a + 5], u),
		lerpf(path[a + 2], path[a + 6], u), lerpf(path[a + 3], path[a + 7], u))
