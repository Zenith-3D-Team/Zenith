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
## inserters; faint under chests, as in Factorio; a faint patch under big machines (kept to their
## footprint: PATCH_EDGE); the full rim under the rest, mods' buildings included. A side facing
## another building's rim across a narrow gap is halved (NEIGHBOUR_GAP), so two rims meeting there
## darken it about as much as one would instead of stacking into black.
##
## Settings > Graphics > Contact shading (on in every preset) shows or hides them (set_enabled).
##
## Shaped by the model itself: the rings follow boxes, and a box is dark where the model has no part (owner: "still
## looks broken on many things": dark patches beside a drill's body, a blob off a burner drill's legs, dark ground under
## an underground belt's hood and outside a curve). So each model's contact map is made from its own mesh once, on the
## loader's worker thread (mask_of(), model_library.gd Load): its triangles within MASK_HEIGHT of the ground, seen from
## above, the lower the darker, turned into how far each point is from that contact (a distance field, MASK_SIZE
## texels square over the contact plus MASK_MARGIN). The masks share one atlas (_atlas_put()) and the rings' shader:
## the same profile, speckle, strengths and side halving, drawn over a quad per building (turns and mirrors are its
## transform). Models without one (a mod's picture card) keep the rings. `--contact-shape=box`: the rings for all, as before.

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
## The patch fades out this far past its foot (tiles; the shader's patch_reach), and its foot is clamped
## to the building's footprint first. It used to fade over PATCH_REACH past a foot that, on a drill,
## already reaches the tile edge: a dark band a third to half a tile wide all round every drill (owner:
## "a dark border around the drills"), where Factorio's drill sprite has none past its body, only its
## shadow dropped to one side. `--contact-patch=wide`: as before.
const PATCH_EDGE := 0.1
static var wide_patch := OS.get_cmdline_user_args().has("--contact-patch=wide")
## The clamp moves the patch alone: the rim stays round the model's real feet. Clamping the whole ring put the
## rim of a machine whose base overhangs its tiles (Wube3DP's electric drill by 0.11 tiles, Vasillo's by 0.08)
## under the model, where none of it shows (owner: "the dark contact shading ... is gone again"). Such a foot
## gets two rings, the rim's on the foot and the patch's on its tiles. `--contact-rim=clamped`: one clamped ring,
## as the drill-border fix first had it.
static var rim_clamped := OS.get_cmdline_user_args().has("--contact-rim=clamped")
## Under the foot the rim and patch fade out over this much (tiles; the shader's inner_fade, its `inset`), gone
## before the ring's hole. They were drawn at full darkness from the foot's box in to the hole and cut off there:
## hidden under a solid base, but where a body doesn't fill its feet's box (Wube3DP's drill between its rear legs,
## 0.38 tiles deep, its round foot's corners 1.1 tiles) a dark band with a sharp inner edge lay on the bare ground
## (owner: "a dark rectangular band along its right and bottom edges, past the body"). `--contact-inner=hard`: as before.
const INNER_FADE := 0.05
static var inner_hard := OS.get_cmdline_user_args().has("--contact-inner=hard")
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

## Meta on a model's mesh: its contact map, [Rect2 the mask covers (model x, z, tiles), its atlas slot, the slot of
## its joined variant or -1] (commit_mask()).
const MASK_META := &"f3d_contact_mask"
## Texels a side, the tiles past the contact it covers (the rim's end and a little), the distance its 255 means
## (tiles; past it nothing), and how high a part still darkens the ground (tiles over the lowest vertex).
const MASK_SIZE := 64
const MASK_MARGIN := 0.3
const MASK_RANGE := 0.4
const MASK_HEIGHT := 0.25
## A part MASK_HEIGHT * h up darkens as (1 - h)^2 of a part on the ground: its distance is pushed out by
## MASK_FALLOFF * ln(1 / that), the shader's rim falloff, so a raised part's rim is as dark as that.
const MASK_FALLOFF := 0.06
## Masks a row of the atlas, and the most rows (the atlas's height, at most 16384).
const MASK_COLS := 16
const MASK_ROWS_MAX := 256
## Small models (belts, pipes, walls: the joined styles) whose contact reaches within this of a half-tile line
## also get a joined variant: the contact carried on past that line and the mask cut there, so a run's neighbours
## meet in one straight rim instead of each rounding its end (two rims doubled into a bead at every joint).
const JOIN_EDGE := 0.15
const JOIN_MAX := 2.6
## mask_wanted() and join_wanted()'s names.
const NO_MASK_NAMES := ["rail", "tree", "-rock", "-ore", "coal", "cliff", "fish", "remnants", "corpse", "locomotive", "wagon",
	"spidertron", "character", "robot", "-asteroid", "explosion", "decorative"]
const JOIN_NAMES := ["belt", "splitter", "loader", "pipe", "wall", "gate"]
static var box_shape := OS.get_cmdline_user_args().has("--contact-shape=box")
static var _atlas: Image
static var _atlas_tex: ImageTexture
static var _atlas_count := 0
static var _atlas_dirty := false
static var _atlas_resized := false
static var _atlas_slots := {}  # mask bytes -> slot (the same model loaded again shares one)
static var _quad: ArrayMesh

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
## model floats. Only vertices a triangle uses count: a skinned model's still body keeps its moving
## part's vertices unused (model_library.gd _split_baked moves only their triangles to `anim_baked`),
## and a burner drill's bit 0.3 below its base made its feet a speck under the bit. Worker-thread safe.
static func feet_of(groups: Array) -> Array:
	var low := INF
	var used_by: Array[PackedByteArray] = []  # per group, 1 for each vertex a triangle uses
	for g: Array in groups:
		var a: Array = g[1]
		var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var used := PackedByteArray()
		used.resize(v.size())
		var idx = a[Mesh.ARRAY_INDEX]
		if idx is PackedInt32Array:
			for i in (idx as PackedInt32Array):
				used[i] = 1
		else:
			used.fill(1)
		used_by.append(used)
		for i in v.size():
			if used[i] == 1:
				low = minf(low, v[i].y)
	if low > FLOATING or low == INF:
		return []
	var top := low + FOOT_HEIGHT
	var points := PackedVector2Array()  # the foot's vertices, and points along its edges
	for gi in groups.size():
		var a: Array = (groups[gi] as Array)[1]
		var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var used := used_by[gi]
		var on_ground := PackedByteArray()
		on_ground.resize(v.size())
		var any := false
		for i in v.size():
			if used[i] == 1 and v[i].y <= top:
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


## A face counts as facing down for mask_of() when its normal's y is under minus this.
const UNDER := 0.5
## --contact-belt-under=on: a belt surface's underside counts as contact, as before.
static var belt_under := OS.get_cmdline_user_args().has("--contact-belt-under=on")
const BeltReturn := preload("res://scripts/world/belt_return.gd")


## Whether a group (Load's [keys, arrays, formats]) is a modeller's textured belt surface.
static func _belt_surface(g: Array) -> bool:
	var keys: Array = g[0]
	return keys.size() == 1 and BeltReturn.is_surface((keys[0] as Array)[0])


## A model's contact map from its still body's groups and its moving parts' (`parts`, as Load has them: in model
## space, in their rest pose), [] when it floats: [Rect2 covered (model x, z), the mask (MASK_SIZE squared bytes, row
## by row along z: the distance to the contact, 0 on it, 255 at MASK_RANGE or more), the joined variant's bytes or
## empty]. Ground is the still body's lowest vertex a triangle uses (as feet_of(): a burner drill's bit below it is
## on the ground). Triangles are drawn from above with their edges too, so a wall standing upright, flat seen from
## above, still counts. Worker-thread safe.
static func mask_of(groups: Array, parts: Array = [], joins := true) -> Array:
	var low := INF
	for g: Array in groups:
		var a: Array = g[1]
		var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var idx = a[Mesh.ARRAY_INDEX]
		if idx is PackedInt32Array:
			for i in (idx as PackedInt32Array):
				low = minf(low, v[i].y)
		else:
			for p in v:
				low = minf(low, p.y)
	if low > FLOATING or low == INF:
		return []
	var all: Array = groups.duplicate()
	for p: Array in parts:
		all.append_array(p[2])
	# The triangles reaching below MASK_HEIGHT, [x, z, height] for each corner, and the box of them and of the feet.
	var tris := PackedFloat32Array()
	var lo := Vector2.INF
	var hi := -Vector2.INF
	var foot_lo := Vector2.INF
	var foot_hi := -Vector2.INF
	var top := low + MASK_HEIGHT
	var foot_top := low + FOOT_HEIGHT
	for g: Array in all:
		var a: Array = g[1]
		var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var idx = a[Mesh.ARRAY_INDEX]
		var ix: PackedInt32Array = idx if idx is PackedInt32Array else PackedInt32Array(range(v.size()))
		# Each vertex's place once: below MASK_HEIGHT or not, and the boxes.
		# A modeller's belt surface lies on the ground with its return strip (and the slab's underside): drawn
		# (belt_return.gd), it sits over the ring's dark, which is no contact: its down-facing triangles don't count.
		var norms: Variant = a[Mesh.ARRAY_NORMAL]
		var skip_under := not belt_under and _belt_surface(g) and norms is PackedVector3Array and (norms as PackedVector3Array).size() == v.size()
		var near := PackedByteArray()
		near.resize(v.size())
		for i in v.size():
			var p := v[i]
			if p.y <= top:
				near[i] = 1
		for t in range(0, ix.size() - 2, 3):
			var i0 := ix[t]
			var i1 := ix[t + 1]
			var i2 := ix[t + 2]
			if near[i0] + near[i1] + near[i2] == 0:
				continue
			if skip_under and ((norms as PackedVector3Array)[i0].y + (norms as PackedVector3Array)[i1].y + (norms as PackedVector3Array)[i2].y) / 3.0 < -UNDER:
				continue
			for i in [i0, i1, i2]:
				var p := v[i]
				lo.x = minf(lo.x, p.x)
				lo.y = minf(lo.y, p.z)
				hi.x = maxf(hi.x, p.x)
				hi.y = maxf(hi.y, p.z)
				if p.y <= foot_top:
					foot_lo.x = minf(foot_lo.x, p.x)
					foot_lo.y = minf(foot_lo.y, p.z)
					foot_hi.x = maxf(foot_hi.x, p.x)
					foot_hi.y = maxf(foot_hi.y, p.z)
				tris.push_back(p.x)
				tris.push_back(p.z)
				tris.push_back(p.y - low)
	if tris.is_empty():
		return []
	var region := Rect2(lo - Vector2(MASK_MARGIN, MASK_MARGIN), hi - lo + Vector2(MASK_MARGIN, MASK_MARGIN) * 2.0)
	var n := MASK_SIZE
	var cell := region.size / float(n)
	var ox := region.position.x
	var oz := region.position.y
	# Each texel's weight: 1 under a part on the ground, falling to 0 at MASK_HEIGHT.
	var w := PackedFloat32Array()
	w.resize(n * n)
	for t in range(0, tris.size(), 9):
		# In texels (texel i's centre at i), and heights.
		var ax := (tris[t] - ox) / cell.x - 0.5
		var az := (tris[t + 1] - oz) / cell.y - 0.5
		var ah := tris[t + 2]
		var bx := (tris[t + 3] - ox) / cell.x - 0.5
		var bz := (tris[t + 4] - oz) / cell.y - 0.5
		var bh := tris[t + 5]
		var cx := (tris[t + 6] - ox) / cell.x - 0.5
		var cz := (tris[t + 7] - oz) / cell.y - 0.5
		var ch := tris[t + 8]
		var den := (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
		if absf(den) >= 2.0:
			# Big enough to hold texel centres: filled.
			var x0 := maxi(ceili(minf(ax, minf(bx, cx))), 0)
			var x1 := mini(floori(maxf(ax, maxf(bx, cx))), n - 1)
			var y0 := maxi(ceili(minf(az, minf(bz, cz))), 0)
			var y1 := mini(floori(maxf(az, maxf(bz, cz))), n - 1)
			var inv := 1.0 / den
			for y in range(y0, y1 + 1):
				for x in range(x0, x1 + 1):
					var b0 := ((bz - cz) * (x - cx) + (cx - bx) * (y - cz)) * inv
					var b1 := ((cz - az) * (x - cx) + (ax - cx) * (y - cz)) * inv
					var b2 := 1.0 - b0 - b1
					if b0 < -1e-4 or b1 < -1e-4 or b2 < -1e-4:
						continue
					var i := y * n + x
					var f := 1.0 - clampf((b0 * ah + b1 * bh + b2 * ch) / MASK_HEIGHT, 0.0, 1.0)
					w[i] = maxf(w[i], f * f)
			continue
		# Thinner than a texel seen from above (an upright wall, a small part): its edges marked instead.
		for e in 3:
			var px := ax if e == 0 else (bx if e == 1 else cx)
			var pz := az if e == 0 else (bz if e == 1 else cz)
			var ph := ah if e == 0 else (bh if e == 1 else ch)
			var qx := bx if e == 0 else (cx if e == 1 else ax)
			var qz := bz if e == 0 else (cz if e == 1 else az)
			var qh := bh if e == 0 else (ch if e == 1 else ah)
			var steps := ceili(maxf(absf(qx - px), absf(qz - pz)) * 2.0) + 1
			for k in steps + 1:
				var f := float(k) / float(steps)
				var x := roundi(lerpf(px, qx, f))
				var y := roundi(lerpf(pz, qz, f))
				if x >= 0 and y >= 0 and x < n and y < n:
					var hh := 1.0 - clampf(lerpf(ph, qh, f) / MASK_HEIGHT, 0.0, 1.0)
					w[y * n + x] = maxf(w[y * n + x], hh * hh)
	var out: Array = [region, _distances(w, n, cell, {})]
	# The joined variant (JOIN_EDGE): the sides whose contact reaches a half-tile line, carried on past it and cut there.
	var cuts := {}
	if joins and foot_lo.x < INF and minf(foot_hi.x - foot_lo.x, foot_hi.y - foot_lo.y) <= JOIN_MAX:
		var ends := {0: foot_lo.x, 1: foot_hi.x, 2: foot_lo.y, 3: foot_hi.y}
		for side: int in ends:
			var line := roundf(float(ends[side]) * 2.0) * 0.5
			if absf(float(ends[side]) - line) <= JOIN_EDGE:
				var axis := 0 if side < 2 else 1
				# In texels: the line's place, texel centres past it are cut.
				cuts[side] = (line - (region.position.x if axis == 0 else region.position.y)) / (cell.x if axis == 0 else cell.y) - 0.5
	out.append(_distances(w, n, cell, cuts) if not cuts.is_empty() else PackedByteArray())
	return out


## Whether a model file gets a contact map at all: not those whose types never have contact shading (NONE: rails,
## trees, rocks, ores, vehicles...), by name, as the loader knows only that. One missed costs only load time; one
## wrongly skipped keeps the ring round its feet.
static func mask_wanted(file: String) -> bool:
	for k: String in NO_MASK_NAMES:
		if file.contains(k):
			return file.contains("rail-signal") or file.contains("rail-chain-signal")
	return true


## Whether it may be a joined style's (STYLES' third entry: belts, pipes, walls): those get the joined variant.
static func join_wanted(file: String) -> bool:
	for k: String in JOIN_NAMES:
		if file.contains(k):
			return true
	return false


## The mask's bytes from the texels' weights: each texel's distance (tiles) to the contact, a raised part's pushed
## out by MASK_FALLOFF * ln(1 / its weight), by passing each texel's nearest seed on to its neighbours (a sweep
## each way). `cuts` {side (0 -x, 1 +x, 2 -z, 3 +z): the line in texels}: the weights next to the line carried on
## past it first, and everything past it none after.
static func _distances(w_in: PackedFloat32Array, n: int, cell: Vector2, cuts: Dictionary) -> PackedByteArray:
	var w := w_in
	if not cuts.is_empty():
		w = w_in.duplicate()
		for side: int in cuts:
			var line: float = cuts[side]
			var edge := clampi(floori(line) if side % 2 == 1 else ceili(line), 0, n - 1)  # the last texel inside
			for k in n:
				for m in n:
					var past := (m > line) if side % 2 == 1 else (m < line)
					if not past:
						continue
					if side < 2:
						w[k * n + m] = maxf(w[k * n + m], w_in[k * n + edge])
					else:
						w[m * n + k] = maxf(w[m * n + k], w_in[edge * n + k])
	var cost := PackedFloat32Array()
	cost.resize(n * n)
	var seed := PackedInt32Array()
	seed.resize(n * n)
	var dist := PackedFloat32Array()
	dist.resize(n * n)
	for i in n * n:
		seed[i] = -1
		cost[i] = INF
		if w[i] > 0.0:
			var c := -MASK_FALLOFF * log(w[i])
			if c < MASK_RANGE:
				cost[i] = c
				seed[i] = i
		dist[i] = cost[i]
	var cx2 := cell.x * cell.x
	var cz2 := cell.y * cell.y
	# The neighbours each sweep has already passed: (dx, dy) pairs.
	var forward := PackedInt32Array([-1, 0, -1, -1, 0, -1, 1, -1])
	var backward := PackedInt32Array([1, 0, 1, 1, 0, 1, -1, 1])
	for sweep in 2:
		var back := sweep == 1
		var offs := backward if back else forward
		for yy in n:
			var y := n - 1 - yy if back else yy
			for xx in n:
				var x := n - 1 - xx if back else xx
				var i := y * n + x
				var best := dist[i]
				if best == 0.0:
					continue  # on the ground: nothing is nearer
				var bs := seed[i]
				for k in range(0, 8, 2):
					var nx := x + offs[k]
					var ny := y + offs[k + 1]
					if nx < 0 or ny < 0 or nx >= n or ny >= n:
						continue
					var s := seed[ny * n + nx]
					if s < 0 or s == bs:
						continue
					var ddx := x - s % n
					var ddy := y - s / n
					var d := sqrt(float(ddx * ddx) * cx2 + float(ddy * ddy) * cz2) + cost[s]
					if d < best:
						best = d
						bs = s
				dist[i] = best
				seed[i] = bs
	var out := PackedByteArray()
	out.resize(n * n)
	var scale := 255.0 / MASK_RANGE
	for i in n * n:
		out[i] = mini(roundi(dist[i] * scale), 255) if dist[i] < MASK_RANGE else 255
	for side: int in cuts:
		var line: float = cuts[side]
		for k in n:
			for m in n:
				if (m > line) if side % 2 == 1 else (m < line):
					out[k * n + m if side < 2 else m * n + k] = 255
	return out


## Puts a model's mask (mask_of()) in the atlas, on the main thread: [its Rect2, its slot, the joined variant's slot
## or -1] for MASK_META; [] when the atlas is full.
static func commit_mask(mask: Array) -> Array:
	var slot := _atlas_put(mask[1])
	if slot < 0:
		return []
	var joined_bytes: PackedByteArray = mask[2]
	return [mask[0], slot, _atlas_put(joined_bytes) if not joined_bytes.is_empty() else -1]


static func _atlas_put(bytes: PackedByteArray) -> int:
	if _atlas_slots.has(bytes):
		return _atlas_slots[bytes]
	var slot := _atlas_count
	var rows := slot / MASK_COLS + 1
	if rows > MASK_ROWS_MAX:
		return -1
	if _atlas == null or rows * MASK_SIZE > _atlas.get_height():
		var grown := Image.create_empty(MASK_COLS * MASK_SIZE, mini(maxi(rows * 2, 4), MASK_ROWS_MAX) * MASK_SIZE, false, Image.FORMAT_R8)
		grown.fill(Color.WHITE)
		if _atlas != null:
			grown.blit_rect(_atlas, Rect2i(Vector2i.ZERO, _atlas.get_size()), Vector2i.ZERO)
		_atlas = grown
		_atlas_resized = true
	var img := Image.create_from_data(MASK_SIZE, MASK_SIZE, false, Image.FORMAT_R8, bytes)
	_atlas.blit_rect(img, Rect2i(0, 0, MASK_SIZE, MASK_SIZE), Vector2i((slot % MASK_COLS) * MASK_SIZE, (slot / MASK_COLS) * MASK_SIZE))
	_atlas_count += 1
	_atlas_slots[bytes] = slot
	_atlas_dirty = true
	return slot


## The atlas sent to the shader when masks were added since (apply(), before it draws).
static func _flush_atlas() -> void:
	if not _atlas_dirty:
		return
	_atlas_dirty = false
	if _atlas_tex == null or _atlas_resized:
		_atlas_tex = ImageTexture.create_from_image(_atlas)
		material().set_shader_parameter("mask_atlas", _atlas_tex)
		_atlas_resized = false
	else:
		_atlas_tex.update(_atlas)


## The bytes in the atlas's memory (masks and the image), for the cost probe.
static func atlas_bytes() -> int:
	return _atlas.get_data_size() if _atlas != null else 0


static func atlas_count() -> int:
	return _atlas_count


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
## position) for a model without them. A type with a patch has its feet clamped to `footprint` (its
## tiles, in model space round its position; zero: not clamped), so the patch stays on them.
static func collect(out: Array, proto_name: String, proto_type: String, mesh: Mesh, xform: Transform3D,
		box_min: Vector2, box_max: Vector2, footprint := Vector2.ZERO) -> void:
	var style := style_for(proto_name, proto_type)
	if style.is_empty():
		return
	if not box_shape and mesh != null and mesh.has_meta(MASK_META):
		var m: Array = mesh.get_meta(MASK_META)
		if not m.is_empty():
			var joins := style.size() > 2 and bool(style[2]) and int(m[2]) >= 0
			_add_mask(out, m[0], int(m[2]) if joins else int(m[1]), xform, style, joins)
			return
	if mesh == null or not mesh.has_meta(META):
		var at := Vector2(xform.origin.x, xform.origin.z)
		_add(out, Rect2(at + box_min, box_max - box_min), 0.08, style)
		return
	var tiles := Rect2(-footprint * 0.5, footprint)
	var clamped := not wide_patch and float(style[1]) > 0.0 and footprint.x > 0.0 and footprint.y > 0.0
	for foot: Array in mesh.get_meta(META):
		var r: Rect2 = foot[0]
		if clamped:
			var kept := r.intersection(tiles) if r.intersects(tiles) else Rect2(r.get_center().clamp(tiles.position, tiles.end), Vector2.ZERO)
			if not rim_clamped and not kept.is_equal_approx(r):
				# The rim round the real foot, the patch on the tiles (rim_clamped).
				_add(out, _placed(r, xform), float(foot[1]), [style[0], 0.0])
				_add(out, _placed(kept, xform), float(foot[1]), [0.0, style[1]])
				continue
			r = kept
		_add(out, _placed(r, xform), float(foot[1]), style)


## A building's mask (MASK_META's `region`, atlas `slot`) placed by `xform` (flattened: its turn and mirror, no
## tilt or height): [the contact's world-aligned box (centre x, z, half x, z) for _sides(), rim, patch, 0, not joined,
## the quad's Transform3D (from -1..1 to the region), the slot, whether it is a joined variant].
static func _add_mask(out: Array, region: Rect2, slot: int, xform: Transform3D, style: Array, joins := false) -> void:
	var b := xform.basis
	var flat := Transform3D(Basis(Vector3(b.x.x, 0.0, b.x.z), Vector3.UP, Vector3(b.z.x, 0.0, b.z.z)), Vector3(xform.origin.x, 0.0, xform.origin.z))
	var c := region.get_center()
	var quad := flat * Transform3D(Basis.from_scale(Vector3(region.size.x * 0.5, 1.0, region.size.y * 0.5)), Vector3(c.x, 0.0, c.y))
	var inner := _placed(region.grow(-MASK_MARGIN), flat)
	var ic := inner.get_center()
	out.append([ic.x, ic.y, inner.size.x * 0.5, inner.size.y * 0.5, float(style[0]), float(style[1]), 0.0, false, quad, slot, joins])


## A foot's box (model space x, z) placed as the model is, world-aligned: its corners turned and moved
## (quarter turns keep it a box).
static func _placed(r: Rect2, xform: Transform3D) -> Rect2:
	var lo := Vector2.INF
	var hi := -Vector2.INF
	for c in [r.position, Vector2(r.end.x, r.position.y), Vector2(r.position.x, r.end.y), r.end]:
		var w := xform * Vector3(c.x, 0.0, c.y)
		lo = lo.min(Vector2(w.x, w.z))
		hi = hi.max(Vector2(w.x, w.z))
	return Rect2(lo, hi - lo)


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
	var all_sides := _sides(rings)
	# The masks (collect(): those with a quad) on a MultiMesh of their own under the rings' node.
	var masks: Array = []
	var mask_sides: Array[Color] = []
	var boxes: Array = []
	var sides: Array[Color] = []
	for i in rings.size():
		var g: Array = rings[i]
		if g.size() > 8:
			masks.append(g)
			mask_sides.append(all_sides[i])
		else:
			boxes.append(g)
			sides.append(all_sides[i])
	_apply_masks(node, masks, mask_sides)
	rings = boxes
	var mm := node.multimesh
	if mm.instance_count != rings.size():
		mm.instance_count = rings.size()
	var lo := Vector2.INF
	var hi := -Vector2.INF
	if rings.is_empty():
		lo = Vector2.ZERO
		hi = Vector2.ZERO
	for i in rings.size():
		var g: Array = rings[i]
		var patch := float(g[5])
		var reach := patch_ring_reach() if patch > 0.0 else REACH
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


## The chunk's masks (collect()'s entries with a quad) on the ring node's child MultiMesh, made, filled or freed.
static func _apply_masks(parent: MultiMeshInstance3D, masks: Array, sides: Array[Color]) -> void:
	var node := parent.get_node_or_null("ContactMasks") as MultiMeshInstance3D
	if masks.is_empty():
		if node != null:
			node.queue_free()
		return
	_flush_atlas()
	if node == null:
		var made := MultiMesh.new()
		made.transform_format = MultiMesh.TRANSFORM_3D
		made.use_colors = true
		made.use_custom_data = true
		made.mesh = quad_mesh()
		node = MultiMeshInstance3D.new()
		node.name = "ContactMasks"
		node.multimesh = made
		node.material_override = material()
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		parent.add_child(node)
	var mm := node.multimesh
	if mm.instance_count != masks.size():
		mm.instance_count = masks.size()
	var lo := Vector2.INF
	var hi := -Vector2.INF
	for i in masks.size():
		var g: Array = masks[i]
		var t: Transform3D = g[8]
		mm.set_instance_transform(i, t)
		mm.set_instance_custom_data(i, Color(-1.0 - float(g[9]), 0.0, 0.0, float(g[5])))
		mm.set_instance_color(i, sides[i])
		for c: Vector3 in [Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(-1, 0, 1), Vector3(1, 0, 1)]:
			var w := t * c
			lo = lo.min(Vector2(w.x, w.z))
			hi = hi.max(Vector2(w.x, w.z))
	var box := AABB(Vector3(lo.x, 0.0, lo.y), Vector3(hi.x - lo.x, 0.05, hi.y - lo.y))
	node.custom_aabb = box
	GroundHeight.cull_box(node, box)


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
					if float(o[4]) <= 0.0:
						continue  # a patch's own ring (collect): no rim to meet, and it lies under its rim's
					var ox: float = o[0]
					var oz: float = o[1]
					# The gaps between the two rectangles along x and z (< 0: they overlap that way).
					var dx := absf(ox - gx) - float(o[2]) - hx
					var dz := absf(oz - gz) - float(o[3]) - hz
					if g.size() > 10 and o.size() > 10 and bool(g[10]) and bool(o[10]) and dx < JOIN_SLACK and dz < JOIN_SLACK:
						continue  # the next piece of a belt's (pipe's, wall's) run: its joined mask meets this one's
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


## The quad a mask is drawn on: -1 to 1 in x and z, in a grid so it follows the hills.
static func quad_mesh() -> ArrayMesh:
	if _quad != null:
		return _quad
	var n := TICKS + 1
	var verts := PackedVector3Array()
	for zi in n:
		for xi in n:
			verts.append(Vector3(-1.0 + 2.0 * float(xi) / float(TICKS), 0.0, -1.0 + 2.0 * float(zi) / float(TICKS)))
	var idx := PackedInt32Array()
	for zi in TICKS:
		for xi in TICKS:
			var a := zi * n + xi
			idx.append_array([a, a + 1, a + n, a + 1, a + n + 1, a + n])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	_quad = ArrayMesh.new()
	_quad.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return _quad


## How far out a ring with a patch reaches: the rim's own reach, PATCH_REACH under --contact-patch=wide.
static func patch_ring_reach() -> float:
	return PATCH_REACH if wide_patch else maxf(REACH, PATCH_EDGE)


static func material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = SHADER
		# Faded by how close the view is, by ao_zoom.gd's thresholds (the one place for them).
		_material.set_shader_parameter("fade_from", AoZoom.RIM_FULL)
		_material.set_shader_parameter("fade_to", AoZoom.RIM_GONE)
		_material.set_shader_parameter("ring_reach", REACH)
		_material.set_shader_parameter("ring_patch_reach", patch_ring_reach())
		_material.set_shader_parameter("patch_reach", PATCH_REACH - 0.05 if wide_patch else PATCH_EDGE)
		_material.set_shader_parameter("inner_fade", 0.0 if inner_hard else INNER_FADE)
		_material.set_shader_parameter("mask_cell", float(MASK_SIZE))
		_material.set_shader_parameter("mask_cols", float(MASK_COLS))
		_material.set_shader_parameter("mask_range", MASK_RANGE)
		_material.set_shader_parameter("mask_margin", MASK_MARGIN)
		if _atlas_tex != null:
			_material.set_shader_parameter("mask_atlas", _atlas_tex)
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

