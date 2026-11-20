extends Node3D
## The decorative layer (scripts/world/decoratives.gd) fed `dprotos` and `dec` as the mod sends
## them, with a picture made here and a stand-in index (nothing of Factorio's), then malformed
## lists. Exits 1 if a check fails; CI also fails on any SCRIPT ERROR in the output.
##
##   godot --headless --path client res://tests/decor_test.tscn

const Decoratives := preload("res://scripts/world/decoratives.gd")
const DecorSheetBaker := preload("res://scripts/world/decor_sheet_baker.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
const ModGraphics := preload("res://scripts/world/mod_graphics.gd")
const SettingsFile := preload("res://scripts/menu/settings.gd")
const Protos := preload("res://scripts/world/protos.gd")

var fails := 0


## Stands in for camera_rig.gd: what the camera follows.
class FakeRig:
	extends Node
	var target: Node3D


## Stands in for world.gd: the chunks still loaded.
class FakeWorld:
	extends Node
	var chunks := {}


## Stands in for world.gd with what the mask of floors and buildings reads: prototypes, each chunk's
## tiles and records, and its change signals.
class MaskWorld:
	extends Node
	signal entities_changed(chunk: Vector2i)
	signal tiles_changed(chunk: Vector2i)
	var chunks := {}
	var protos = Protos.new()


## A chunk_view.gd's tiles, records and change count.
class FakeChunk:
	extends RefCounted
	var tile_ids := PackedInt32Array()
	var entities := {}
	var content_rev := 0


## A world.gd record: what the mask reads of it.
class FakeRec:
	extends RefCounted
	var pos := Vector2.ZERO
	var dir := 0
	var proto_id := 0


func check(cond: bool, what: String) -> void:
	if not cond:
		fails += 1
		print("FAIL: ", what)


func _ready() -> void:
	# A 64x32 sheet with two 32x32 variants, in a stand-in data folder.
	var dir := OS.get_user_data_dir().path_join("decor_test")
	DirAccess.make_dir_recursive_absolute(dir.path_join("base/graphics/decorative"))
	var image := Image.create(64, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.2, 0.6, 0.2, 1.0))
	image.save_png(dir.path_join("base/graphics/decorative/test.png"))
	ItemIcons.data_dir = dir
	ItemIcons._searched = true
	Decoratives._index = {
		"green-carpet-grass": {"layer": "decals", "box": [-0.5, -0.5, 0.5, 0.5],
			"pics": [["base/graphics/decorative/test.png", 0, 0, 32, 32, 0.5, 0, 0], ["base/graphics/decorative/test.png", 32, 0, 32, 32, 0.5, 0, 0]]},
		"small-rock": {"layer": "object", "box": [-0.5, -0.5, 0.5, 0.5],
			"pics": [["base/graphics/decorative/test.png", 0, 0, 32, 32, 0.5, 0.1, 0]]},
		"no-pictures": {"layer": "decorative", "box": [-0.5, -0.5, 0.5, 0.5], "pics": [["base/graphics/decorative/missing.png", 0, 0, 8, 8, 1, 0, 0]]},
	}
	Decoratives._index_generation = ModGraphics.generation
	var world := FakeWorld.new()
	add_child(world)
	world.chunks[Vector2i(0, 0)] = true
	world.chunks[Vector2i(1, 0)] = true
	var d: Node3D = Decoratives.new()
	d.world = world
	add_child(d)

	d.handle({"t": "dprotos", "part": 1, "parts": 1, "l": [[1, "green-carpet-grass"], [2, "small-rock"], [3, "no-pictures"]]})
	var l := []
	for i in 100:
		l.append_array([1, i % 32, i / 32, 1])
	l.append_array([2, 5, 5, 2, 3, 6, 6, 1])
	# Two parts: nothing is drawn until the second arrives.
	d.handle({"t": "dec", "cx": 0, "cy": 0, "part": 1, "parts": 2, "l": l.slice(0, 200)})
	check(_instances(d) == 0, "a chunk is drawn only when all its parts arrived")
	d.handle({"t": "dec", "cx": 0, "cy": 0, "part": 2, "parts": 2, "l": l.slice(200)})
	# Built on a worker thread: shown once the job is done (finish_jobs waits for it).
	check(_instances(d) == 0, "the chunk isn't built on the spot (a worker thread does it)")
	d.finish_jobs()
	check(d.count() == 102, "the chunk's decoratives are kept: %d" % d.count())
	check(_instances(d) == 101, "one instance per grass and rock; a decorative without pictures draws nothing: %d" % _instances(d))
	check(_meshes(d) == 2, "one MultiMesh per decorative in the chunk: %d" % _meshes(d))
	# Flat ones are blended (cut-outs crawled and sparkled as the view moved), in a fixed order by
	# Factorio's layer so overlapping ones never swap; standing ones stay cut out.
	var flat: ShaderMaterial = null
	var upright: ShaderMaterial = null
	for inst in _all(d):
		var m := inst.material_override as ShaderMaterial
		if m.shader == Decoratives.SHADER_FLAT:
			flat = m
		elif m.shader == Decoratives.SHADER:
			upright = m
	Decoratives._flat_order = {}
	Decoratives._index = {"a-decal": {"layer": "decals"}, "b-floor": {"layer": "floor"}, "c-plant": {"layer": "decorative"},
		"d-standing": {"layer": "object"}}
	Decoratives._index_generation = ModGraphics.generation
	var order := [Decoratives._flat_priority("a-decal"), Decoratives._flat_priority("b-floor"), Decoratives._flat_priority("c-plant")]
	check(flat != null and upright != null and order[0] < order[1] and order[1] < order[2] and order[2] < 0
		and order[0] >= Material.RENDER_PRIORITY_MIN,
		"flat decoratives blended in a fixed order by Factorio's layer, under other see-through things; standing ones cut out (%s)" % [order])
	Decoratives._flat_order = {}
	Decoratives._index = {
		"green-carpet-grass": {"layer": "decals", "box": [-0.5, -0.5, 0.5, 0.5],
			"pics": [["base/graphics/decorative/test.png", 0, 0, 32, 32, 0.5, 0, 0], ["base/graphics/decorative/test.png", 32, 0, 32, 32, 0.5, 0, 0]]},
		"small-rock": {"layer": "object", "box": [-0.5, -0.5, 0.5, 0.5],
			"pics": [["base/graphics/decorative/test.png", 0, 0, 32, 32, 0.5, 0.1, 0]]},
		"no-pictures": {"layer": "decorative", "box": [-0.5, -0.5, 0.5, 0.5], "pics": [["base/graphics/decorative/missing.png", 0, 0, 8, 8, 1, 0, 0]]},
	}
	Decoratives._index_generation = ModGraphics.generation

	d.set_options(true, 0.5)
	d.finish_jobs()
	var half := _instances(d)
	check(half > 30 and half < 75, "density 0.5 keeps about half: %d" % half)
	d.set_options(true, 0.5)
	d.finish_jobs()
	check(_instances(d) == half, "and the same ones each time")
	d.set_options(true, 1.0)
	d.finish_jobs()
	check(_instances(d) == 101, "back to all of them: %d" % _instances(d))

	d.handle({"t": "dec", "cx": 0, "cy": 0, "part": 1, "parts": 1, "l": {}})
	check(_instances(d) == 0, "an empty list (Factorio's {}) clears the chunk")

	# Malformed lists and messages must not stop the layer.
	d.handle({"t": "dec", "cx": 1, "cy": 0, "part": 1, "parts": 1, "l": [1, 2, 3]})
	d.handle({"t": "dec", "cx": "x", "cy": null, "part": "a", "parts": -5, "l": "nope"})
	d.handle({"t": "dec", "cx": 1, "cy": 0, "part": 1, "parts": 1, "l": [99, 1, 1, 1, 1, 400, -3, 1]})
	d.handle({"t": "dprotos", "l": [[], ["x"], 5, null]})
	d.handle({"t": "dec", "cx": 1, "cy": 0, "part": 1, "parts": 1, "l": [1, 2, 3, 4]})
	d.finish_jobs()
	check(_instances(d) == 1, "a good list after bad ones draws: %d" % _instances(d))

	# Another surface of the same game: the mod sends no `dprotos` for it, so the names stay.
	d.reset(true)
	d.handle({"t": "dec", "cx": 1, "cy": 0, "part": 1, "parts": 1, "l": [1, 2, 3, 4]})
	d.finish_jobs()
	check(_instances(d) == 1, "after a surface change the decoratives' names stay: %d" % _instances(d))
	# A build still running when the world is dropped never shows on the new one, even over a chunk
	# at the same place that has nothing.
	d.handle({"t": "dec", "cx": 0, "cy": 0, "part": 1, "parts": 1, "l": [1, 3, 3, 1]})
	d.reset(true)
	d.handle({"t": "dec", "cx": 0, "cy": 0, "part": 1, "parts": 1, "l": {}})
	d.finish_jobs()
	check(_instances(d) == 0, "an old build doesn't show after a reset: %d" % _instances(d))
	# A new game forgets the names until its own `dprotos`.
	d.reset()
	d.handle({"t": "dec", "cx": 1, "cy": 0, "part": 1, "parts": 1, "l": [1, 2, 3, 4]})
	d.finish_jobs()
	check(_instances(d) == 0, "a new game's ids aren't the last game's")
	d.handle({"t": "dprotos", "l": [[1, "green-carpet-grass"]]})
	d.handle({"t": "dec", "cx": 1, "cy": 0, "part": 1, "parts": 1, "l": [1, 2, 3, 4]})
	d.finish_jobs()
	check(_instances(d) == 1, "then its own: %d" % _instances(d))

	# A chunk the world no longer has is dropped.
	world.chunks.erase(Vector2i(1, 0))
	d._sweep = 10.0
	d._process(0.0)
	await get_tree().process_frame
	check(_instances(d) == 0 and d.count() == 0, "an unloaded chunk's decoratives go")

	_stale_list_checks()
	await _grass_checks(d, world, dir)
	await _mask_checks()
	_parallel_load_checks()
	await _sheet_checks(dir)

	print("decor test: %s" % ("all passed" if fails == 0 else "%d failed" % fails))
	get_tree().quit(1 if fails > 0 else 0)


## A build started before a new graphics list (mod_graphics.gd) finishes with the old list's pictures:
## the Kind made from them is used again, not made a second time from their spent atlas (which logged
## "Invalid image: null" and kept a Kind without a picture for the session); the new list's pictures
## make their own.
func _stale_list_checks() -> void:
	Decoratives._kind_data.erase("small-rock")
	var old: Decoratives.KindData = Decoratives._kind_data_for("small-rock")
	var first: Decoratives.Kind = Decoratives._kind("small-rock", old)
	Decoratives._kind_data.erase("small-rock")  # what a new list does (index())
	var late: Decoratives.Kind = Decoratives._kind("small-rock", old)  # a build from before it, finishing now
	var fresh: Decoratives.Kind = Decoratives._kind("small-rock", Decoratives._kind_data_for("small-rock"))
	check(first != null and late == first and late.material.get_shader_parameter("atlas") is Texture2D
		and fresh != null and fresh != first and fresh.material.get_shader_parameter("atlas") is Texture2D,
		"a build from before a new graphics list keeps its own pictures; the new list's make their own")


## 3D grass: which decoratives rise, where a tuft's root is, the budget, the range.
func _grass_checks(d: Node3D, world: FakeWorld, dir: String) -> void:
	check(Decoratives.is_grass("green-hairy-grass", "decorative") and Decoratives.is_grass("green-croton", "decorative")
		and not Decoratives.is_grass("small-rock", "decorative") and not Decoratives.is_grass("lichen-decal", "decorative")
		and not Decoratives.is_grass("green-carpet-grass", "decals") and not Decoratives.is_grass("green-pita", "object"),
		"plants on the decorative layer rise; rocks, decals and standing cards don't")
	# A thin blade on the left of the picture and a black baked shadow on its right: the root is the blade's.
	var tuft := Image.create(64, 32, false, Image.FORMAT_RGBA8)
	for y in 32:
		for x in range(12, 16):
			tuft.set_pixel(x, y, Color(0.3, 0.6, 0.2, 1.0))
		for x in range(40, 64):
			tuft.set_pixel(x, y, Color(0.0, 0.0, 0.0, 0.5))
	var plant := Decoratives._plant_of(tuft)
	check(plant.x > 0.15 and plant.x < 0.3 and plant.z < Decoratives.GRASS_BUSH_COVER, "a tuft's root and cover leave its baked shadow out: %s" % plant)
	tuft.save_png(dir.path_join("base/graphics/decorative/tuft.png"))
	Decoratives._index["green-hairy-grass"] = {"layer": "decorative", "box": [-1, -1, 1, 1],
		"pics": [["base/graphics/decorative/tuft.png", 0, 0, 64, 32, 0.5, 0, 0]]}
	d.handle({"t": "dprotos", "l": [[5, "green-hairy-grass"]]})
	var c := Vector2i(0, 0)
	world.chunks[c] = true
	var focus := Node3D.new()
	add_child(focus)
	focus.position = Vector3(16.0, 0.0, 16.0)
	var rig := FakeRig.new()
	rig.target = focus
	add_child(rig)
	d.rig = rig
	d.set_grass("normal")
	d._process(0.0)
	var l := []
	for i in 30:
		l.append_array([5, i, 3, 1])
	d.handle({"t": "dec", "cx": 0, "cy": 0, "part": 1, "parts": 1, "l": l})
	d.finish_jobs()
	var stats: Dictionary = d.grass_stats()
	check(stats["instances"] == 30 and stats["multimeshes"] == 1 and stats["triangles"] == 30 * 32, "a chunk in range rises, a grid of 32 triangles a tuft: %s" % stats)
	var inst: MultiMeshInstance3D = d._grass[c].get_child(0)
	var material := inst.material_override as ShaderMaterial
	check(inst.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and material.shader == Decoratives.SHADER_GRASS and material.get_shader_parameter("tuft") == true,
		"raised plants cast no shadows, and a thin picture is a tuft")
	check(material.render_priority > Decoratives._flat_priority("green-hairy-grass") and material.render_priority < 0,
		"raised plants are drawn after every flat picture, before other see-through things")

	# Over the budget: the same share of each kind rises, and only those darken on the ground.
	var job := Decoratives.BuildJob.new()
	job.chunk = c
	job.names = {5: "green-hairy-grass"}
	job.density = 1.0
	var many := Decoratives.GRASS_CHUNK_TRIANGLES / 32 * 5 / 4
	for i in many:
		job.list.append_array([5, i % 32, i / 32, 1])
	Decoratives._run_job(job)
	var g: Array = job.groups[0]
	var buffer: PackedFloat32Array = g[1]
	check(int(g[4]) * 32 <= Decoratives.GRASS_CHUNK_TRIANGLES and int(g[4]) > many / 2 and int(g[2]) == many, "a chunk's raised plants stay in the budget: %d of %d" % [int(g[4]), many])
	check(buffer[(int(g[4]) - 1) * Decoratives.STRIDE + 15] > 0.5 and buffer[int(g[4]) * Decoratives.STRIDE + 15] == 0.0, "the flat pictures know which rise")

	_real_meadow_checks(dir)

	# Out of range they go, back in range they come, one chunk a frame; off frees them.
	focus.position = Vector3(400.0, 0.0, 16.0)
	d._process(0.0)
	check(d._grass.is_empty(), "a chunk well out of range has no raised plants")
	focus.position = Vector3(16.0, 0.0, 16.0)
	d._process(0.0)
	check(d._grass.has(c), "and back in range it does")
	d.set_grass("short")
	check(is_equal_approx(d.grass_range, 30.0) and not d.grass_wind, "the short setting has less range and no wind")
	d.set_grass("off")
	d._process(0.0)
	await get_tree().process_frame
	check(d._grass.is_empty() and d.grass_stats()["triangles"] == 0, "off leaves none")

	# Settings: off in Low; a file saved on Low before 3D grass existed keeps Low's.
	check(SettingsFile.PRESETS["low"]["grass_3d"] == "off" and SettingsFile.PRESETS["high"]["grass_3d"] == SettingsFile.DEFAULTS["graphics"]["grass_3d"],
		"3D grass is off in the Low preset and High's is the default")
	var kept: ConfigFile = SettingsFile._cfg
	SettingsFile._cfg = ConfigFile.new()
	for key in SettingsFile.PRESETS["low"]:
		if key != "grass_3d":
			SettingsFile._cfg.set_value("graphics", key, SettingsFile.PRESETS["low"][key])
	SettingsFile._grass_preset_once()
	check(SettingsFile._cfg.get_value("graphics", "grass_3d", "") == "off", "a file on the Low preset from before stays without 3D grass")
	SettingsFile._cfg = kept


## Nauvis's own decoratives, by their real names, layers and picture sizes (client/data/decoratives.json),
## at the density of a real meadow: chunk (-1, -1) of a seed-123456 map in Factorio 2.1 has 1,300
## decoratives. Its plants rise (the first budget raised one in fourteen there, which looked flat),
## tufts and bushes all of them, carpets from what is left, rocks none, within the budget.
func _real_meadow_checks(dir: String) -> void:
	var real: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Decoratives.INDEX))
	var rising := ["green-hairy-grass", "brown-hairy-grass", "green-small-grass", "green-carpet-grass", "brown-carpet-grass",
		"white-carpet-grass", "brown-fluff", "brown-fluff-dry", "red-croton", "green-croton", "brown-asterisk", "green-asterisk",
		"red-asterisk", "green-bush-mini", "green-desert-bush", "red-desert-bush", "green-pita-mini"]
	var bad := []
	for n: String in rising:
		if not real.has(n) or not Decoratives.is_grass(n, str(real[n].get("layer", ""))):
			bad.append(n)
	for n: String in ["garballo", "green-pita", "red-pita", "fuchsia-pita"]:
		if not real.has(n) or str(real[n].get("layer", "")) != Decoratives.UPRIGHT_LAYER:
			bad.append(n)
	for n: String in ["small-rock", "tiny-rock", "medium-rock", "sand-decal", "red-desert-decal"]:
		if not real.has(n) or Decoratives.is_grass(n, str(real[n].get("layer", ""))):
			bad.append(n)
	check(bad.is_empty(), "Nauvis's grass, carpets, fluff, crotons, asterisks and bushes rise; garballo and pitas stand as cards; rocks and decals stay flat: %s" % [bad])

	# A stand-in picture in each real decorative's own size, so carpets are told from tufts as in the game.
	var blades := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	for y in 256:
		for x in 256:
			if (x / 6) % 3 == 0:
				blades.set_pixel(x, y, Color(0.3, 0.55, 0.2, 1.0))
	blades.save_png(dir.path_join("base/graphics/decorative/blades.png"))
	var counts := {"green-carpet-grass": 405, "brown-hairy-grass": 206, "brown-fluff": 161, "brown-carpet-grass": 135,
		"green-hairy-grass": 128, "red-croton": 127, "tiny-rock": 82, "medium-rock": 49, "small-rock": 47}
	var job := Decoratives.BuildJob.new()
	job.chunk = Vector2i(-1, -1)
	job.density = 1.0
	var id := 40
	for n: String in counts:
		var pic: Array = real[n]["pics"][0]
		Decoratives._index[n] = {"layer": real[n]["layer"], "box": real[n]["box"],
			"pics": [["base/graphics/decorative/blades.png", 0, 0, mini(int(pic[3]), 256), mini(int(pic[4]), 256), float(pic[5]), 0, 0]]}
		Decoratives._kind_data.erase(n)
		job.names[id] = n
		for i in int(counts[n]):
			job.list.append_array([id, (i * 7) % 32, (i * 13 / 32) % 32, 1])
		id += 1
	Decoratives._run_job(job)
	var triangles := 0
	var out := {}
	for g: Array in job.groups:
		var data: Decoratives.KindData = g[3]
		triangles += int(g[4]) * data.grass_triangles
		out[str(g[0])] = [int(g[4]), int(g[2]), data.grass_carpet]
	var stand_ok := true
	for n: String in ["brown-hairy-grass", "brown-fluff", "green-hairy-grass", "red-croton"]:
		stand_ok = stand_ok and out[n][0] == out[n][1] and not out[n][2]
	check(stand_ok, "on a real meadow every tuft and bush rises: %s" % out)
	var carpets: int = out["green-carpet-grass"][0] + out["brown-carpet-grass"][0]
	check(out["green-carpet-grass"][2] and out["brown-carpet-grass"][2] and carpets > 540 * 3 / 4,
		"carpets are told from tufts by their size and nearly all rise from what the budget has left: %d of 540" % carpets)
	check(out["small-rock"][0] == 0 and out["tiny-rock"][0] == 0 and out["medium-rock"][0] == 0, "rocks stay flat")
	check(triangles <= Decoratives.GRASS_CHUNK_TRIANGLES and triangles > Decoratives.GRASS_CHUNK_TRIANGLES * 3 / 4,
		"a real meadow's chunk fills its budget and stays in it: %d triangles" % triangles)

	# Carpets stand as clumps of blades cut from their own picture: crossed cards where it has plant,
	# none where it is bare or only baked shadow, none rooted outside the decorative's box (Factorio
	# clears that box where things are built), half-tile cards about 0.5 tile tall.
	var data: Decoratives.KindData = Decoratives._kind_data_for("green-carpet-grass")
	var cells := data.carpet_cells
	var used := 0
	var inside := true
	var piece_ok := true
	for x in cells.get_width():
		var p := cells.get_pixel(x, 0)
		if p.b <= 0.0:
			continue
		used += 1
		var root := data.shifts[0] + (Vector2(p.r + 0.5 * p.b, p.g + p.a) - Vector2(0.5, 0.5)) * data.sizes[0]
		inside = inside and Decoratives._box_of(real["green-carpet-grass"]).grow(0.25).has_point(root)
		piece_ok = piece_ok and (absf(p.b * data.sizes[0].x - Decoratives.CARPET_CLUMP.x) < 0.02 or p.r + p.b > 0.999)
	check(used > 4 and used <= Decoratives.CARPET_CLUMPS and data.carpet_clumps == cells.get_width() and data.grass_triangles == data.carpet_clumps * 4,
		"a carpet's picture becomes clumps, at most CARPET_CLUMPS, two cards each: %d" % used)
	check(inside and piece_ok, "its clumps are half-tile pieces of the picture, rooted in the decorative's box")
	check(data.grass_height >= 0.3 and data.grass_height <= 0.6, "carpet blades stand 0.3-0.6 tile: %.2f" % data.grass_height)
	var kind: Decoratives.Kind = Decoratives._kind("green-carpet-grass", data)
	check(kind.grass_material.shader == Decoratives.SHADER_CARPET and kind.grass_mesh.get_faces().size() / 3 == data.grass_triangles
		and kind.grass_material.get_shader_parameter("cells") is ImageTexture and kind.grass_material.get_shader_parameter("wind_noise") is NoiseTexture2D
		and is_equal_approx(float(kind.material.get_shader_parameter("raised_shade")), Decoratives.CARPET_SHADE),
		"a carpet is drawn with the carpet shader, its mesh the clumps' cards: %d triangles" % [kind.grass_mesh.get_faces().size() / 3])
	# A picture with plant only in its top left quarter: its clumps are there and nowhere else.
	var corner := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			corner.set_pixel(x, y, Color(0.3, 0.6, 0.2, 1.0) if (x + y) % 3 == 0 else Color(0.0, 0.0, 0.0, 0.6))
	var images: Array[Image] = [corner]
	var probe := Decoratives.KindData.new()
	probe.sizes = [Vector2(4.0, 4.0)]
	probe.shifts = [Vector2.ZERO]
	Decoratives._carpet_cells(probe, [["x", 0, 0, 128, 128, 1.0, 0, 0]], images, Rect2(-2, -2, 4, 4))
	var where_ok := probe.carpet_clumps > 0
	for x in probe.carpet_cells.get_width():
		var p := probe.carpet_cells.get_pixel(x, 0)
		where_ok = where_ok and p.b > 0.0 and p.r < 0.5 and p.g < 0.5
	check(where_ok, "clumps only where the picture has plant, not its bare ground or baked shadow: %d" % probe.carpet_clumps)
	probe = Decoratives.KindData.new()
	probe.sizes = [Vector2(4.0, 4.0)]
	probe.shifts = [Vector2.ZERO]
	Decoratives._carpet_cells(probe, [["x", 0, 0, 128, 128, 1.0, 0, 0]], images, Rect2(0.5, 0.5, 1.5, 1.5))
	check(probe.carpet_cells.get_pixel(0, 0).b == 0.0, "and none rooted outside the decorative's box")


## Nothing on concrete or under a building (owner): a chunk with a strip of concrete, a floor an item
## lays (`iuse`), a rocket silo, a silo over the edge into the next chunk and an ore patch; grass
## everywhere. None is drawn on the floors or the silos, all of it elsewhere; a tuft by a silo stays
## flat; the shaders' mask has the same tiles; mining a silo or laying concrete changes it.
func _mask_checks() -> void:
	Decoratives._index["test-decal"] = {"layer": "decals", "box": [-0.5, -0.5, 0.5, 0.5],
		"pics": [["base/graphics/decorative/test.png", 0, 0, 32, 32, 0.5, 0, 0]]}
	Decoratives._index["test-tuft-grass"] = {"layer": "decorative", "box": [-0.5, -0.5, 0.5, 0.5],
		"pics": [["base/graphics/decorative/tuft.png", 0, 0, 64, 32, 0.5, 0, 0]]}
	for n: String in ["test-decal", "test-tuft-grass"]:
		Decoratives._kind_data.erase(n)
	var world := MaskWorld.new()
	add_child(world)
	world.protos.add_tiles([[1, "grass-1", 60, 90, 30], [2, "concrete", 120, 120, 120], [3, "fancy-tiles", 90, 90, 90]])
	world.protos.add_entities([[10, "rocket-silo", "rocket-silo", -4.5, -4.5, 4.5, 4.5, 200, 200, 200, 9, 9],
		[11, "iron-ore", "resource", -0.5, -0.5, 0.5, 0.5, 100, 100, 200, 1, 1]])
	var a := FakeChunk.new()
	var b := FakeChunk.new()
	for cv: FakeChunk in [a, b]:
		cv.tile_ids.resize(1024)
		cv.tile_ids.fill(1)
	for i in 128:
		a.tile_ids[i] = 2  # rows 0-3 concrete
	a.tile_ids[28 * 32 + 28] = 3  # laid by an item, with no floor-like name
	var silo := FakeRec.new()
	silo.proto_id = 10
	silo.pos = Vector2(16.5, 16.5)  # tiles 12-20
	var edge_silo := FakeRec.new()
	edge_silo.proto_id = 10
	edge_silo.pos = Vector2(31.5, 10.5)  # tiles 27-35 across, 6-14 down: into the next chunk
	var ore := FakeRec.new()
	ore.proto_id = 11
	ore.pos = Vector2(5.5, 10.5)
	a.entities = {1: silo, 2: edge_silo, 3: ore}
	world.chunks[Vector2i(0, 0)] = a
	world.chunks[Vector2i(1, 0)] = b
	var d: Node3D = Decoratives.new()
	d.world = world
	add_child(d)
	d.handle({"t": "iuse", "part": 1, "parts": 1, "l": [["fancy-tile", "t", "fancy-tiles", "", []], ["grenade", "c", "throw", 15, 6.5]]})
	d.handle({"t": "dprotos", "l": [[1, "test-decal"], [2, "test-tuft-grass"]]})
	check(Decoratives.is_floor("refined-hazard-concrete-left", {}) and Decoratives.is_floor("stone-path", {})
		and Decoratives.is_floor("landfill", {}) and Decoratives.is_floor("space-platform-foundation", {})
		and Decoratives.is_floor("artificial-yumako-soil", {}) and not Decoratives.is_floor("natural-yumako-soil", {})
		and not Decoratives.is_floor("grass-1", {}) and Decoratives.is_floor("fancy-tiles", {"fancy-tiles": true}),
		"floors: tiles an item lays, else concrete, paths, landfill, foundations and artificial soils by name")
	var full := []
	for i in 1024:
		full.append_array([1, i % 32, i / 32, 1])
	d.handle({"t": "dec", "cx": 0, "cy": 0, "part": 1, "parts": 1, "l": full})
	d.handle({"t": "dec", "cx": 1, "cy": 0, "part": 1, "parts": 1, "l": full})
	d.finish_jobs()
	d._process(0.0)  # the neighbour reached by the edge silo is built again
	d.finish_jobs()
	d._process(0.0)
	var blocked := {}
	for y in 4:
		for x in 32:
			blocked[Vector2i(x, y)] = true
	blocked[Vector2i(28, 28)] = true
	for y in range(12, 21):
		for x in range(12, 21):
			blocked[Vector2i(x, y)] = true
	for y in range(6, 15):
		for x in range(27, 36):
			blocked[Vector2i(x, y)] = true
	var mask_ok := true
	for x in range(0, 64):
		for y in range(0, 32):
			mask_ok = mask_ok and d.blocked_at(x, y) == blocked.has(Vector2i(x, y))
	check(mask_ok, "the mask is the concrete, the laid floor and the silos' tiles, over the chunk's edge too; not the ore")
	var roots := _roots(d, full)
	var on_blocked := 0
	for t: Vector2i in roots:
		if blocked.has(t):
			on_blocked += 1
	check(on_blocked == 0 and roots.size() == 2048 - blocked.size() and _instances(d) == roots.size(),
		"no decorative on concrete, a floor or under a silo, all of them elsewhere: %d drawn (%d instances), %d on blocked tiles"
		% [roots.size(), _instances(d), on_blocked])
	# The texture the shaders read: concrete's row all set, a grass row by the silo only under it.
	var slot := Decoratives._mask_slot(Vector2i(0, 0))
	var row0: int = d._mask_bytes[(slot.y * 32 * Decoratives.MASK_CHUNKS + slot.x) * 4]
	var o16 := ((slot.y * 32 + 16) * Decoratives.MASK_CHUNKS + slot.x) * 4
	var row16: int = d._mask_bytes[o16] | (d._mask_bytes[o16 + 1] << 8) | (d._mask_bytes[o16 + 2] << 16) | (d._mask_bytes[o16 + 3] << 24)
	check(row0 == 255 and row16 == ((1 << 9) - 1) << 12 and d._mask_texture != null,
		"the shaders' mask texture has the same tiles (row 0 %d, row 16 %x)" % [row0, row16])

	# A tuft beside the silo stays flat (its picture reaches under it); one in the open rises.
	var job := Decoratives.BuildJob.new()
	job.chunk = Vector2i(0, 0)
	job.names = {2: "test-tuft-grass"}
	job.density = 1.0
	job.list = [2, 11, 16, 1, 2, 5, 25, 1]
	d._mask_inputs(Vector2i(0, 0), job)
	Decoratives._run_job(job)
	var g: Array = job.groups[0] if not job.groups.is_empty() else [null, PackedFloat32Array(), 0, null, 0]
	var buffer: PackedFloat32Array = g[1]
	check(int(g[2]) == 2 and int(g[4]) == 1 and buffer.size() == 2 * Decoratives.STRIDE and floori(buffer[3]) == 5
		and buffer[Decoratives.STRIDE + 15] == 0.0, "a tuft reaching under a building stays flat, one in the open rises: %s" % [g.slice(2)])

	# Mined: the silo's ground grows again. Concrete laid: it goes there.
	a.entities.erase(1)
	a.content_rev += 1
	world.entities_changed.emit(Vector2i(0, 0))
	a.tile_ids[25 * 32 + 5] = 2
	a.content_rev += 1
	world.tiles_changed.emit(Vector2i(0, 0))
	d._process(0.0)
	d.finish_jobs()
	roots = _roots(d, full)
	check(not d.blocked_at(16, 16) and roots.has(Vector2i(16, 16)) and d.blocked_at(5, 25) and not roots.has(Vector2i(5, 25))
		and _instances(d) == 2048 - blocked.size() + 81 - 1,
		"mining a building or laying concrete changes the chunk's mask and what grows there: %d instances" % _instances(d))
	# A change that leaves the ground as it was (an inserter turned) builds the mask, not the nodes.
	var node: Node3D = d._chunks[Vector2i(0, 0)]
	a.content_rev += 1
	world.entities_changed.emit(Vector2i(0, 0))
	d._process(0.0)
	d.finish_jobs()
	check(d._chunks[Vector2i(0, 0)] == node, "a change that leaves the mask as it was keeps the chunk's clutter")
	d.queue_free()
	world.queue_free()


## Fast RGBA8 byte reads match RGBA8/RGBAF get_pixel(), carpet_texture is pre-created on workers,
## and per-decorative locks let index() and other kinds proceed while one kind is locked.
func _parallel_load_checks() -> void:
	var img8 := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			img8.set_pixel(x, y, Color(0.35, 0.7, 0.25, 0.85) if (x + y) % 2 == 0 else Color(0.0, 0.0, 0.0, 0.5))
	var imgf := img8.duplicate()
	imgf.convert(Image.FORMAT_RGBAF)
	var p8 := Decoratives._plant_of(img8)
	var pf := Decoratives._plant_of(imgf)
	check(p8.distance_to(pf) < 0.01, "RGBA8 fast _plant_of matches RGBAF fallback (%s vs %s)" % [p8, pf])

	var k8 := Decoratives.KindData.new()
	k8.sizes = [Vector2(4.0, 4.0)]
	k8.shifts = [Vector2.ZERO]
	Decoratives._carpet_cells(k8, [["x", 0, 0, 128, 128, 1.0, 0, 0]], [img8] as Array[Image], Rect2(-2, -2, 4, 4))
	var kf := Decoratives.KindData.new()
	kf.sizes = [Vector2(4.0, 4.0)]
	kf.shifts = [Vector2.ZERO]
	Decoratives._carpet_cells(kf, [["x", 0, 0, 128, 128, 1.0, 0, 0]], [imgf] as Array[Image], Rect2(-2, -2, 4, 4))
	var cells_match := k8.carpet_clumps == kf.carpet_clumps and k8.carpet_cells.get_width() == kf.carpet_cells.get_width()
	if cells_match:
		for x in k8.carpet_cells.get_width():
			if not k8.carpet_cells.get_pixel(x, 0).is_equal_approx(kf.carpet_cells.get_pixel(x, 0)):
				cells_match = false
				break
	check(cells_match and k8.carpet_clumps > 0, "RGBA8 fast _carpet_cells matches RGBAF fallback (%d clumps)" % k8.carpet_clumps)

	# Simulate a worker holding small-rock's per-decorative lock: another kind and index() don't block.
	Decoratives._kind_data.erase("green-hairy-grass")
	Decoratives._kind_data.erase("small-rock")
	var rock_lock: Mutex = Decoratives._kind_locks.get("small-rock")
	if rock_lock == null:
		rock_lock = Mutex.new()
		Decoratives._kind_locks["small-rock"] = rock_lock
	rock_lock.lock()
	var grass_data: Decoratives.KindData = Decoratives._kind_data_for("green-hairy-grass")
	var prev_index := Decoratives._index.duplicate()
	var prev_gen := Decoratives._index_generation
	var prev_mod_gen := ModGraphics.generation
	ModGraphics.generation += 1
	var swapped := Decoratives.index()
	ModGraphics.generation = prev_mod_gen
	Decoratives._index = prev_index
	Decoratives._index_generation = prev_gen
	rock_lock.unlock()
	check(grass_data != null and swapped is Dictionary, "per-decorative lock does not block other kinds or index() swap")

	# Carpet texture pre-created on worker when texture_thread is enabled, consumed by _kind().
	Decoratives._index["test-carpet-grass"] = {"layer": "decorative", "box": [-2, -2, 2, 2],
		"pics": [["base/graphics/decorative/blades.png", 0, 0, 256, 256, 0.5, 0, 0]]}
	Decoratives._kind_data.erase("test-carpet-grass")
	var carpet_data: Decoratives.KindData = Decoratives._kind_data_for("test-carpet-grass")
	var pre_tex := carpet_data != null and (not Decoratives.texture_thread or carpet_data.carpet_texture != null)
	var carpet_kind: Decoratives.Kind = Decoratives._kind("test-carpet-grass", carpet_data)
	check(pre_tex and carpet_kind != null and carpet_data.carpet_texture == null and carpet_data.carpet_cells != null,
		"carpet_texture pre-created on KindData and consumed without dropping carpet_cells")


## The tiles of the decoratives the two chunks' builds keep, read from their instance buffers (the
## headless renderer keeps no MultiMesh transforms to read back).
func _roots(d: Node, list: Array) -> Dictionary:
	var out := {}
	for c: Vector2i in [Vector2i(0, 0), Vector2i(1, 0)]:
		var job := Decoratives.BuildJob.new()
		job.chunk = c
		job.names = {1: "test-decal"}
		job.density = 1.0
		job.list = list
		d._mask_inputs(c, job)
		Decoratives._run_job(job)
		for g: Array in job.groups:
			var buffer: PackedFloat32Array = g[1]
			for i in int(g[2]):
				out[Vector2i(floori(buffer[i * Decoratives.STRIDE + 3]), floori(buffer[i * Decoratives.STRIDE + 11]))] = true
	return out


func _instances(d: Node) -> int:
	var n := 0
	for inst in _all(d):
		# A world left is hidden at once and freed over the next frames (decoratives.gd _freeing).
		if not inst.is_queued_for_deletion() and not inst.get_parent().is_queued_for_deletion() and not d._freeing.has(inst.get_parent()):
			n += inst.multimesh.instance_count
	return n


func _meshes(d: Node) -> int:
	var n := 0
	for inst in _all(d):
		if not inst.get_parent().is_queued_for_deletion():
			n += 1
	return n


func _all(node: Node) -> Array:
	var out := []
	for child in node.get_children():
		if child is MultiMeshInstance3D:
			out.append(child)
		out.append_array(_all(child))
	return out


func _sheet_checks(_dir: String) -> void:
	# 1. Overhanging edge detection on worker jobs: interior flat decorative stays chunk-local while
	# an edge carpet reports cardinal/diagonal neighbor bits and its transform buffer.
	Decoratives._index["test-carpet-grass"] = {"layer": "decorative", "box": [-2, -2, 2, 2],
		"pics": [["base/graphics/decorative/blades.png", 0, 0, 256, 256, 0.5, 0, 0]]}
	Decoratives._index["small-rock"] = {"layer": "object", "box": [-0.5, -0.5, 0.5, 0.5],
		"pics": [["base/graphics/decorative/test.png", 0, 0, 32, 32, 0.5, 0, 0]]}
	Decoratives._index_generation = ModGraphics.generation
	Decoratives._kind_data.erase("test-carpet-grass")
	var job := Decoratives.BuildJob.new()
	job.chunk = Vector2i(0, 0)
	job.names = {1: "test-carpet-grass", 2: "small-rock"}
	job.density = 1.0
	job.list = [1, 10, 10, 1, 1, 31, 31, 1, 2, 31, 31, 1]
	Decoratives._run_job(job)
	var want_bits := Decoratives._dir_bit(1, 0) | Decoratives._dir_bit(0, 1) | Decoratives._dir_bit(1, 1)
	check(job.edge_groups.size() == 1 and int(job.edge_groups[0][2]) == 1 and job.edge_dirs == want_bits,
		"only edge-overhanging flat decoratives mark adjacent neighbor bits: groups=%d dirs=%d" % [job.edge_groups.size(), job.edge_dirs])

	# 2. Tier sizing and hysteresis band around transitions.
	var c0 := Vector2i(0, 0)
	var far_at := func(dist: float) -> Vector2: return Vector2(32.0 + dist, 16.0)
	var near_sz := Decoratives.sheet_size_for(c0, far_at.call(10.0), 0, true)
	var stay_near := Decoratives.sheet_size_for(c0, far_at.call(32.0), near_sz, true)
	var mid_sz := Decoratives.sheet_size_for(c0, far_at.call(45.0), near_sz, true)
	var mid_plain := Decoratives.sheet_size_for(c0, far_at.call(45.0), near_sz, false)
	var far_sz := Decoratives.sheet_size_for(c0, far_at.call(100.0), mid_sz, true)
	check(near_sz == Decoratives.SHEET_SIZE_NEAR and stay_near == Decoratives.SHEET_SIZE_NEAR
		and mid_sz == Decoratives.SHEET_SIZE_MID_COMPRESSED and mid_plain == Decoratives.SHEET_SIZE_MID_PLAIN
		and far_sz == Decoratives.SHEET_SIZE_FAR,
		"sheet tiers and hysteresis match compressed/plain budgets (%s %s %s %s %s)" % [near_sz, stay_near, mid_sz, mid_plain, far_sz])

	# 3. Readback post-processing: empty detection, BGRA->RGBA swap, edge dilation, mipmaps.
	var empty_job := DecorSheetBaker.PostJob.new()
	empty_job.width = 4
	empty_job.height = 4
	empty_job.bytes = PackedByteArray()
	empty_job.bytes.resize(4 * 4 * 4)
	empty_job.bytes.fill(0)
	empty_job.upload_on_worker = false
	DecorSheetBaker.post_process(empty_job)
	check(empty_job.empty and empty_job.image == null, "post_process drops fully transparent sheets")

	var bgra_bytes := PackedByteArray()
	bgra_bytes.resize(8 * 8 * 4)
	bgra_bytes.fill(0)
	bgra_bytes[0] = 200  # B
	bgra_bytes[1] = 100  # G
	bgra_bytes[2] = 50   # R
	bgra_bytes[3] = 255  # A
	var ok_job := DecorSheetBaker.PostJob.new()
	ok_job.width = 8
	ok_job.height = 8
	ok_job.bgra = true
	ok_job.bytes = bgra_bytes
	ok_job.compress = false
	ok_job.upload_on_worker = false
	DecorSheetBaker.post_process(ok_job)
	var px0 := ok_job.image.get_pixel(0, 0) if ok_job.image != null else Color.BLACK
	var px1 := ok_job.image.get_pixel(1, 0) if ok_job.image != null else Color.BLACK
	check(not ok_job.empty and ok_job.image != null and ok_job.image.has_mipmaps()
		and is_equal_approx(px0.r, 50.0 / 255.0) and is_equal_approx(px0.b, 200.0 / 255.0) and px1.b > 0.1 and px1.a == 0.0,
		"post_process swaps BGRA->RGBA, dilates transparent edges and builds mipmaps: px0=%s px1=%s" % [px0, px1])

	# 3b. Replication benchmark on a 2048x2048 sheet: GPU-swapped/dilated post_process avoids the
	# >80 ms GDScript BGRA loop and CPU fix_alpha_edges().
	var big_bytes := PackedByteArray()
	big_bytes.resize(2048 * 2048 * 4)
	big_bytes.fill(0)
	big_bytes[0] = 200
	big_bytes[1] = 100
	big_bytes[2] = 50
	big_bytes[3] = 255
	var old_job := DecorSheetBaker.PostJob.new()
	old_job.width = 2048
	old_job.height = 2048
	old_job.bgra = true
	old_job.gpu_dilated = false
	old_job.bytes = big_bytes
	old_job.upload_on_worker = false
	var t_old0 := Time.get_ticks_usec()
	DecorSheetBaker.post_process(old_job)
	var old_ms := (Time.get_ticks_usec() - t_old0) / 1000.0
	var fast_job := DecorSheetBaker.PostJob.new()
	fast_job.width = 2048
	fast_job.height = 2048
	fast_job.bgra = false
	fast_job.gpu_dilated = true
	fast_job.bytes = big_bytes
	fast_job.upload_on_worker = false
	var t_fast0 := Time.get_ticks_usec()
	DecorSheetBaker.post_process(fast_job)
	var fast_ms := (Time.get_ticks_usec() - t_fast0) / 1000.0
	check(not fast_job.empty and fast_job.image != null and fast_job.image.has_mipmaps()
		and fast_ms < 25.0 and fast_ms * 4.0 < old_ms,
		"2048x2048 post_process with GPU swap+dilate (%.1f ms) avoids the slow GDScript BGRA path (%.1f ms)" % [fast_ms, old_ms])
	print("decor sheet 2048x2048 post_process: old BGRA+CPU dilate %.1f ms -> GPU swap+dilate %.1f ms (%.1fx faster)" % [old_ms, fast_ms, old_ms / maxf(fast_ms, 0.01)])

	# 4. _apply_sheet replaces flat MultiMeshes, preserves upright MultiMeshes, survives _cull_one and hills toggle.
	var sworld := FakeWorld.new()
	sworld.chunks[Vector2i(0, 0)] = true
	sworld.chunks[Vector2i(1, 0)] = true
	add_child(sworld)
	var sd: Node3D = Decoratives.new()
	sd.world = sworld
	sd.set_grass("normal")
	add_child(sd)
	sd.handle({"t": "dprotos", "l": [[1, "test-carpet-grass"], [2, "small-rock"]]})
	sd.handle({"t": "dec", "cx": 0, "cy": 0, "part": 1, "parts": 1, "l": [1, 31, 31, 1, 2, 10, 10, 1]})
	sd.handle({"t": "dec", "cx": 1, "cy": 0, "part": 1, "parts": 1, "l": {}})
	sd.finish_jobs()
	var n10_sources: Array = sd._collect_sheet_sources(Vector2i(1, 0))
	check(n10_sources.size() == 1 and int(n10_sources[0][3]) == 1,
		"empty neighbor chunk collects overhanging flat instances from adjacent chunk: %d" % n10_sources.size())

	var tex := ImageTexture.create_from_image(ok_job.image)
	var gen := int(sd._sheet_gen.get(Vector2i(0, 0), 0))
	sd._apply_sheet(Vector2i(0, 0), gen, 512, tex, false)
	var chunk_node: Node3D = sd._chunks.get(Vector2i(0, 0))
	var sheets := 0
	var uprights := 0
	var flats := 0
	var sheet_mat: ShaderMaterial = null
	var sheet_inst: MeshInstance3D = null
	if chunk_node != null:
		for ch in chunk_node.get_children():
			if ch is MeshInstance3D and not (ch is MultiMeshInstance3D):
				sheets += 1
				sheet_inst = ch
				sheet_mat = ch.material_override as ShaderMaterial
			elif ch is MultiMeshInstance3D:
				if ch.get_meta(Decoratives.META_FLAT, false):
					flats += 1
				else:
					uprights += 1
	check(sheets == 1 and uprights == 1 and flats == 0 and sheet_mat != null and sheet_mat.shader == Decoratives.SHADER_SHEET
		and sheet_mat.render_priority == Decoratives.SHEET_PRIORITY
		and sheet_inst.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		and sheet_inst.layers == Visuals.GROUND_LAYER
		and is_equal_approx(float(sheet_mat.get_shader_parameter(&"raised_shade")), Decoratives.CARPET_SHADE),
		"_apply_sheet swaps flat MultiMeshes for one lit sheet while keeping upright MultiMeshes (sheets=%d flat=%d up=%d)" % [sheets, flats, uprights])

	sd._bake_dirty.clear()
	sd._cull_one(Vector2i(0, 0), chunk_node, Vector2(140.0, 16.0))
	check(sd._bake_dirty.has(Vector2i(0, 0)), "_cull_one tolerates FlatSheet MeshInstance3D and queues tier resize")

	# 4b. Rebuilding a chunk that already has a FlatSheet keeps it in place without re-spawning
	# raw flat MultiMeshInstance3Ds, and _apply_sheet updates that same MeshInstance3D in place.
	sd.handle({"t": "dec", "cx": 0, "cy": 0, "part": 1, "parts": 1, "l": [1, 31, 31, 1, 1, 20, 20, 1, 2, 10, 10, 1]})
	sd.finish_jobs()
	var rebuilt_node: Node3D = sd._chunks.get(Vector2i(0, 0))
	var kept_sheets := 0
	var rebuilt_flats := 0
	var kept_same_inst := false
	if rebuilt_node != null:
		for ch in rebuilt_node.get_children():
			if ch == sheet_inst:
				kept_same_inst = true
			if ch is MeshInstance3D and not (ch is MultiMeshInstance3D):
				kept_sheets += 1
			elif ch is MultiMeshInstance3D and ch.get_meta(Decoratives.META_FLAT, false):
				rebuilt_flats += 1
	var gen2 := int(sd._sheet_gen.get(Vector2i(0, 0), 0))
	sd._apply_sheet(Vector2i(0, 0), gen2, 256, tex, false)
	check(kept_sheets == 1 and rebuilt_flats == 0 and kept_same_inst and is_instance_valid(sheet_inst)
		and sheet_inst.get_parent() == rebuilt_node and int(sd._sheet_size.get(Vector2i(0, 0), 0)) == 256,
		"rebuilding an already-baked chunk keeps FlatSheet in place (%s, flats=%d) and _apply_sheet updates it in place" % [kept_same_inst, rebuilt_flats])

	var was_hills := GroundHeight._on
	GroundHeight._on = true
	sd._sync_sheet_hills()
	var hills_mesh_ok := sheet_inst.mesh == Decoratives._sheet_mesh(true)
	GroundHeight._on = was_hills
	sd._sync_sheet_hills()
	check(hills_mesh_ok and sheet_inst.mesh == Decoratives._sheet_mesh(was_hills),
		"sheet swaps cleanly between flat and hill-subdivided planes when GroundHeight toggles")

	# 5. Phase 2 decorative sheet optimizations: decor_blocked before texture(sheet), <=1024 near cap,
	# skipping 100%-blocked chunks & sparse self-contained chunks, and freezing resize re-bakes while moving.
	var sheet_src := FileAccess.get_file_as_string("res://shaders/decorative_sheet.gdshader")
	var blocked_at := sheet_src.find("decor_blocked(ground_at)")
	var sample_at := sheet_src.find("texture(sheet, UV)")
	check(blocked_at > 0 and sample_at > blocked_at,
		"decorative_sheet.gdshader checks decor_blocked() before sampling sheet texture")
	check(Decoratives.SHEET_SIZE_NEAR <= 1024,
		"SHEET_SIZE_NEAR capped at <=1024 (%d)" % Decoratives.SHEET_SIZE_NEAR)

	var full_mask := PackedInt32Array()
	full_mask.resize(Decoratives.CHUNK)
	full_mask.fill(-1)
	sd._masks[Vector2i(1, 0)] = full_mask
	check(sd._chunk_fully_blocked(Vector2i(1, 0)), "_chunk_fully_blocked detects 100%-masked concrete chunks")
	sd._bake_dirty.erase(Vector2i(1, 0))
	sd._mark_overhang_neighbors(Vector2i(0, 0), Decoratives._dir_bit(1, 0))
	check(not sd._bake_dirty.has(Vector2i(1, 0)), "100%-masked chunks are not queued for sheet baking from neighbor overhangs")

	# Sparse self-contained chunk (< SHEET_MIN_FLAT, no overhangs) skips baking a full-chunk sheet.
	sworld.chunks[Vector2i(5, 5)] = true
	sd.handle({"t": "dec", "cx": 5, "cy": 5, "part": 1, "parts": 1, "l": [1, 16, 16, 1]})
	sd.finish_jobs()
	check(not sd._bake_dirty.has(Vector2i(5, 5)),
		"sparse self-contained chunk (< SHEET_MIN_FLAT, no overhangs) skips full-chunk sheet bake")

	# Fast focus movement freezes resize-only re-bakes while still allowing content-dirty / initial bakes.
	var move_focus := Node3D.new()
	add_child(move_focus)
	move_focus.position = Vector3(0.0, 0.0, 0.0)
	var move_rig := FakeRig.new()
	move_rig.target = move_focus
	add_child(move_rig)
	sd.rig = move_rig
	sd._culled_at = Vector2(0.0, 0.0)
	sd._sheet_move_pos = Vector2(0.0, 0.0)
	move_focus.position = Vector3(2.0, 0.0, 0.0)  # 20 tiles/sec over 0.1 s > SHEET_MOVE_FREEZE_SPEED
	sd._update_sheet_move(0.1)
	sd._bake_dirty.clear()
	sd._sheet_content_dirty.clear()
	sd._bake_dirty[Vector2i(0, 0)] = true  # resize-only (has _sheet_size, not in _sheet_content_dirty)
	check(sd._sheet_move_hold > 0.0 and not sd._has_eligible_bake(),
		"fast movement freezes resize-only sheet re-bakes")
	sd._sheet_content_dirty[Vector2i(0, 0)] = true
	check(sd._has_eligible_bake(), "content-dirty sheet bakes still run while moving")
	sd._sheet_content_dirty.erase(Vector2i(0, 0))
	sd._update_sheet_move(Decoratives.SHEET_MOVE_SETTLE_SEC + 0.1)
	check(sd._sheet_move_hold <= 0.0 and sd._has_eligible_bake(),
		"resize-only sheet re-bakes resume once movement settles")
	move_rig.queue_free()
	move_focus.queue_free()

	sd.reset()
	await get_tree().process_frame
	check(sd._bake_dirty.is_empty() and sd._flat_groups.is_empty() and sd._sheet_size.is_empty(),
		"reset clears all sheet state")
	sd.queue_free()
	sworld.queue_free()
	await get_tree().process_frame
