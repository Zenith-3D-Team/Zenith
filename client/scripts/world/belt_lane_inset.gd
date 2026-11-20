extends RefCounted
## A pack's belt may be narrower than Factorio's: pack.json "belt_lane_offset" is the distance (tiles) of an
## item lane from the belt's centre line (absent: Factorio's own, DEFAULT). Drawing only: belt_items.gd keeps
## the simulation's lane geometry as the bridge sent it and gives the drawing (the records, the lattice, the C++
## draw) the lane moved in to this offset, so no item's position along its lane changes.
## --belt-lane-offset=<tiles> overrides the pack (a test, a try-out); 0 or less is the key absent.

## Factorio's lane distance (belt_lanes.gd LANE, measured in 2.1.23).
const DEFAULT := 0.234
const TILE := 256.0  # lane meta's units a tile
const CURVE := 2  # BeltSim.CURVE (lane meta kind)

## The offset the packs in use ask for the belt (or DEFAULT), from the pack the belt model comes from.
static func wanted(pack: Dictionary) -> float:
	var v := _arg()
	if v <= 0.0:
		v = float((pack.get("info", {}) as Dictionary).get("belt_lane_offset", 0.0))
	return clampf(v, 0.05, DEFAULT) if v > 0.0 else DEFAULT


static func _arg() -> float:
	return _flag("--belt-lane-offset=")


## The height (tiles) of the belt surface the items rest on, from pack.json "belt_item_height" (a modeller's
## belt top, measured from the model's Belt_Surface); `top` + `lift` (Zenith's own: the model's top and a
## little over it) when the pack doesn't say. --belt-item-height=<tiles> overrides the pack (0 or less: not).
static func item_height(pack: Dictionary, top: float, lift: float) -> float:
	var v := _flag("--belt-item-height=")
	if v <= 0.0:
		v = float((pack.get("info", {}) as Dictionary).get("belt_item_height", 0.0))
	return v if v > 0.0 else top + lift


static func _flag(prefix: String) -> float:
	for a in OS.get_cmdline_args():
		if a.begins_with(prefix):
			return a.substr(len(prefix)).to_float()
	return 0.0


## Lane meta [kind, length, step, x0, y0, xm, ym, x1, y1] (1/256 tile) with the lane moved from DEFAULT to
## `offset` from its belt's centre line: a straight lane across its way towards the middle of its tile (a
## splitter's halves too: each lane lies inside one tile), a curve's about its corner towards the middle radius.
static func shifted(meta: PackedInt32Array, offset: float) -> PackedInt32Array:
	var d := (DEFAULT - offset) * TILE
	if d <= 0.0 or meta.size() < 9:
		return meta
	var out := meta.duplicate()
	if meta[0] == CURVE:
		var arc := _circle(meta)
		if arc.is_empty():
			return meta
		var k := 1.0 - signf(arc[2] - TILE * 0.5) * d / arc[2]
		for i in [3, 5, 7]:
			out[i] = roundi(arc[0] + (meta[i] - arc[0]) * k)
			out[i + 1] = roundi(arc[1] + (meta[i + 1] - arc[1]) * k)
		return out
	var dx := absi(meta[7] - meta[3])
	var dy := absi(meta[8] - meta[4])
	if dx == 0 and dy == 0:
		return meta
	# (Along x the lane's y is across the belt, and the other way about.)
	var across := 4 if dx >= dy else 3
	for i in [across, across + 2, across + 4]:
		var c := (floorf(meta[i] / TILE) + 0.5) * TILE
		out[i] = roundi(meta[i] + signf(c - meta[i]) * minf(d, absf(c - meta[i])))
	return out


## The circle through a curve lane's three points: [centre x, centre y, radius].
static func _circle(m: PackedInt32Array) -> PackedFloat64Array:
	var ax := float(m[3])
	var ay := float(m[4])
	var bx := float(m[5])
	var by := float(m[6])
	var cx := float(m[7])
	var cy := float(m[8])
	var d := 2.0 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
	if absf(d) < 1e-6:
		return PackedFloat64Array()
	var a2 := ax * ax + ay * ay
	var b2 := bx * bx + by * by
	var c2 := cx * cx + cy * cy
	var ux := (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / d
	var uy := (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d
	return PackedFloat64Array([ux, uy, Vector2(ax - ux, ay - uy).length()])
