extends SceneTree
## A pack's belt_lane_offset (belt_lane_inset.gd): the pack's key read (absent: Factorio's), straight lanes
## (x and y ways, both sides, a splitter's halves) and curve lanes moved in to the offset and no further, the
## simulation's raw meta untouched, and a lane at the offset (or none asked) left as it is. Both lanes of a belt
## move in towards its centre line, never the same way: straights each way (and west and north of the map's
## origin), undergrounds, splitters' halves, loaders, curves each way (the far lanes' icons: ui_test.gd _belt_lane_inset_far, belt_lanes.gd needs Bridge);
## the keys read from a pack.json as the client reads it (model_packs.gd, which once dropped them).
##   godot --headless --audio-driver Dummy --path client -s res://tests/belt_lane_inset_test.gd

const Inset := preload("res://scripts/world/belt_lane_inset.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const BeltItems := preload("res://scripts/world/belt_items.gd")

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _m(kind: int, pts: Array) -> PackedInt32Array:
	var out := PackedInt32Array([kind, 256, 8])
	for v: int in pts:
		out.append(v)
	return out


func _init() -> void:
	check(is_equal_approx(Inset.wanted({}), Inset.DEFAULT), "no pack: Factorio's own")
	check(is_equal_approx(Inset.wanted({"info": {"shading": "pbr"}}), Inset.DEFAULT), "key absent: Factorio's own")
	check(is_equal_approx(Inset.wanted({"info": {"belt_lane_offset": 0.21}}), 0.21), "key read")
	check(is_equal_approx(Inset.wanted({"info": {"belt_lane_offset": 0.9}}), Inset.DEFAULT), "never further out than Factorio's")
	check(Inset.wanted({"info": {"belt_lane_offset": -1}}) == Inset.DEFAULT, "nonsense: Factorio's own")
	# belt_item_height: the pack's key, else the model's top and Zenith's lift.
	check(is_equal_approx(Inset.item_height({}, 0.25, 0.02), 0.27), "no key: top + lift")
	check(is_equal_approx(Inset.item_height({"info": {"shading": "pbr"}}, 0.25, 0.03), 0.28), "key absent: top + lift")
	check(is_equal_approx(Inset.item_height({"info": {"belt_item_height": 0.25}}, 0.25, 0.02), 0.25), "key read")
	check(is_equal_approx(Inset.item_height({"info": {"belt_item_height": 0.0}}, 0.3, 0.02), 0.32), "zero: absent")
	var d := Inset.DEFAULT * 256.0
	var o := 0.21 * 256.0
	# Straight north-south belt on tile 3 (centre x 3.5 = 896): right lane at +d, left at -d.
	var cx := 896
	for side in [-1, 1]:
		var x := cx + roundi(side * d)
		var raw := _m(1, [x, 1000, x, 1128, x, 1256])
		var got := Inset.shifted(raw, 0.21)
		check(absi(absi(got[3] - cx) - roundi(o)) <= 1 and signi(got[3] - cx) == side, "straight y-way side %d: %d" % [side, got[3]])
		check(got[3] == got[5] and got[5] == got[7], "straight stays straight")
		check(got[4] == 1000 and got[8] == 1256 and got[1] == 256 and got[2] == 8, "along-lane points and length untouched")
		check(raw[3] == x, "raw meta not changed")
	# East-west belt on row 5 (centre y 5.5 = 1408).
	for side in [-1, 1]:
		var y := 1408 + roundi(side * d)
		var got2 := Inset.shifted(_m(1, [100, y, 228, y, 356, y]), 0.21)
		check(absi(absi(got2[4] - 1408) - roundi(o)) <= 1 and signi(got2[4] - 1408) == side and got2[3] == 100, "straight x-way side %d" % side)
	# A splitter's half whose tile is the next one over (centre x 4.5 = 1152).
	var sp := Inset.shifted(_m(5, [1152 + roundi(d), 0, 1152 + roundi(d), 128, 1152 + roundi(d), 256]), 0.21)
	check(absi(sp[3] - 1152 - roundi(o)) <= 1, "splitter half moves about its own tile's middle")
	# Default offset or a lane already inside it: unchanged.
	var same := _m(1, [cx + 60, 0, cx + 60, 128, cx + 60, 256])
	check(Inset.shifted(same, Inset.DEFAULT) == same, "default offset: unchanged")
	check(Inset.shifted(same, 0.05)[3] == cx + roundi(0.05 * 256.0), "far in: lands on the offset")
	# Curve about the corner (0, 0) of tile 0 turning, centre radius 128: the lanes at radius 128 +- d, a quarter circle.
	for r in [128.0 - d, 128.0 + d]:
		var raw3 := _m(2, [roundi(r), 0, roundi(r * 0.7071), roundi(r * 0.7071), 0, roundi(r)])
		var got3 := Inset.shifted(raw3, 0.21)
		var want := 128.0 + signf(r - 128.0) * o
		for i in [3, 5, 7]:
			var rr := Vector2(got3[i], got3[i + 1]).length()
			check(absf(rr - want) <= 1.5, "curve point %d radius %.1f wants %.1f" % [i, rr, want])
		check(got3[0] == 2, "curve kind kept")
		# Its direction about the corner is kept.
		check(absf(atan2(got3[6], got3[5]) - PI / 4.0) < 0.01, "curve middle stays on its ray")
	_pack_json()
	_both_lanes()
	_kept_by_reset()
	print("BELT LANE INSET FAILS: %d" % fails)
	quit(1 if fails > 0 else 0)


## The keys as a pack.json gives them, through the client's own reading of it.
func _pack_json() -> void:
	var info := ModelPacks._parse_info('{"shading": "pbr", "belt_lane_offset": 0.21, "belt_item_height": 0.25}')
	check(is_equal_approx(Inset.wanted({"info": info}), 0.21), "pack.json belt_lane_offset read: %s" % str(info))
	check(is_equal_approx(Inset.item_height({"info": info}, 0.3, 0.02), 0.25), "pack.json belt_item_height read")
	var none := ModelPacks._parse_info('{"belt_lane_offset": "wide"}')
	check(not none.has("belt_lane_offset") and is_equal_approx(Inset.wanted({"info": none}), Inset.DEFAULT), "pack.json nonsense: absent")


## A belt's two lanes (Factorio's, DEFAULT either side of its centre line) at the offset: each on its own side,
## both nearer the middle. `c` the centre line across the belt's way (1/256 tile), `along` the lane's way.
func _pair(kind: int, c: float, along_x: bool, a0: int, what: String) -> void:
	var d := Inset.DEFAULT * 256.0
	var o := 0.21 * 256.0
	for side in [-1, 1]:
		var at := roundi(c + side * d)
		var pts := [a0, at, a0 + 128, at, a0 + 256, at] if along_x else [at, a0, at, a0 + 128, at, a0 + 256]
		var got := Inset.shifted(_m(kind, pts), 0.21)
		var across := got[4] if along_x else got[3]
		check(signf(across - c) == side and absf(absf(across - c) - o) <= 1.0,
			"%s lane %d: %.1f from the middle, wants %.1f on its side" % [what, side, (across - c), side * o])


func _both_lanes() -> void:
	for tile in [-63, -1, 0, 3]:
		var c: float = (tile + 0.5) * 256.0
		for kind in [1, 3, 4, 5, 6, 7, 8]:
			_pair(kind, c, false, tile * 256, "kind %d north-south tile %d" % [kind, tile])
			_pair(kind, c, true, tile * 256, "kind %d east-west tile %d" % [kind, tile])
	# A splitter (two tiles wide, its middle on a tile edge): each half's two lanes about its own tile's middle.
	for half in [-0.5, 0.5]:
		_pair(5, (10.0 + half) * 256.0, false, 0, "splitter half %.1f" % half)
	# Curves each way about each corner: the inner lane outwards, the outer inwards, to the middle radius +- the offset.
	var d := Inset.DEFAULT * 256.0
	var o := 0.21 * 256.0
	for corner in [Vector2(0, 0), Vector2(-768, 512), Vector2(1280, -256)]:
		for q in 4:
			var a0 := q * PI / 2.0
			for r in [128.0 - d, 128.0 + d]:
				var pts := []
				for f in [0.0, 0.5, 1.0]:
					var a: float = a0 + f * PI / 2.0
					pts.append_array([roundi(corner.x + cos(a) * r), roundi(corner.y + sin(a) * r)])
				var got := Inset.shifted(_m(2, pts), 0.21)
				var want := 128.0 + signf(r - 128.0) * o
				for i in [3, 5, 7]:
					var rr: float = (Vector2(got[i], got[i + 1]) - corner).length()
					check(absf(rr - want) <= 1.5, "curve at %s quarter %d radius %.1f: %.1f wants %.1f" % [str(corner), q, r, rr, want])



## The game calls BeltItems.reset() on connecting (main.gd) after the pack's offset was read once (_find_height):
## the offset has to survive it (it was lost: the menu's background, never reset, drew it, the game didn't).
func _kept_by_reset() -> void:
	var layer := BeltItems.new()
	layer._set_lane_inset(0.15)
	check(is_equal_approx(layer._state.lane_inset, 0.15), "offset set")
	layer.reset()
	check(is_equal_approx(layer._state.lane_inset, 0.15), "offset kept by reset(): %f" % layer._state.lane_inset)
	layer.free()
