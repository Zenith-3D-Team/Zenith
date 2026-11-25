extends SceneTree
## Model packs (model_packs.gd) on fixture packs made in the test's own user folder: the models
## folder's loose models, a folder pack with its models deep inside and a pack.json, a zip pack with
## a model of the same name (the saved order decides), a pack turned off, a new pack going on top,
## --models filling in or (--models-first) replacing, the zip unpacked once on a worker and again
## when it changes (the old copy removed), a .gltf in a zip reading its .bin beside it, a zip that
## isn't one and a damaged one left out with a warning, zip entries that would write outside the copy;
## the downloads' Zenith.zip (Vasillo's models) on top, and its old name Default.zip read as it.
##   godot --headless --path client -s res://tests/model_packs_test.gd
## Prints "MODEL PACKS FAILS: 0" when all pass; quits with 1 otherwise.

const ModelPacks := preload("res://scripts/world/model_packs.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModFiles := preload("res://scripts/world/mod_files.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
const TerrainTextures := preload("res://scripts/world/terrain_textures.gd")
const Decoratives := preload("res://scripts/world/decoratives.gd")
const TestEnv := preload("res://tests/test_env.gd")
const Tones := preload("res://tests/sound_fixtures.gd")

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _initialize() -> void:
	TestEnv.isolate("model-packs-test")
	_unit()
	_builtin()
	_packs()
	_cache_keep()
	_choices()
	_bundled()
	_icons()
	_sounds()
	_tiles()
	_decoratives()
	_items()
	_item_pictures()
	_pack_shading()
	_item_kinds_follow()
	_numbered_ores()
	_variants()
	_cliffs()
	_gate_model()
	_factorio()
	_copies()
	_builtin_copies()
	ModelPacks.set_choices({})
	ModelPacks.configure("", [], [])
	print("MODEL PACKS FAILS: %d" % fails)
	TestEnv.clean()
	quit(1 if fails > 0 else 0)


func _unit() -> void:
	check(ModelPacks.safe_entry("pack/a/b.glb") == "pack/a/b.glb" and ModelPacks.safe_entry("pack\\b.glb") == "pack/b.glb",
		"a zip entry's path is kept, its backslashes turned")
	for bad in ["../x.glb", "pack/../../x.glb", "/abs/x.glb", "C:/x.glb", "__MACOSX/pack/._x.glb"]:
		check(ModelPacks.safe_entry(bad) == "", "a zip entry outside the pack's copy is left out: %s" % bad)
	var a := {"id": "a", "title": "Alpha"}
	var b := {"id": "b", "title": "beta"}
	var c := {"id": "c", "title": "Gamma"}
	var listed := ModelPacks.ordered([a, b, c], ["c", "a", "c", "gone"], ["a"])
	check(listed.map(func(p: Dictionary) -> String: return p["id"]) == ["b", "c", "a"],
		"a new pack goes on top, the rest in the saved order (a twice or one gone don't count): %s" % [listed.map(func(p: Dictionary) -> String: return p["id"])])
	check(not bool(listed[2]["on"]) and bool(listed[0]["on"]) and not a.has("on"), "the saved ones off, on copies")


func _packs() -> void:
	var dir := ProjectSettings.globalize_path("user://models")
	var chest := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path("res://assets/models/packs/wube3dp/wooden-chest.glb"))
	check(chest.size() > 1000, "the fixture model was read")
	# The folder's top: loose models, and a file that isn't one.
	_write(dir.path_join("iron-chest.glb"), chest)
	_write(dir.path_join("README.txt"), "not a model".to_utf8_buffer())
	# A folder pack: its models anywhere inside, the one nearest its top winning; its pack.json.
	_write(dir.path_join("Folder belts/pack.json"), JSON.stringify({"name": "Belts in a folder", "version": "2.0",
		"author": "Tester", "license": "CC0", "description": "Belts for the test."}).to_utf8_buffer())
	_write(dir.path_join("Folder belts/belts/deep/transport-belt.glb"), chest)
	_write(dir.path_join("Folder belts/wooden-chest.glb"), chest)
	_write(dir.path_join("Folder belts/old/wooden-chest.glb"), chest)
	# A folder without models (a .gltf's textures beside the loose ones) is no pack.
	_write(dir.path_join("textures/grain.png"), PackedByteArray([1, 2, 3]))
	# A pack turned off.
	_write(dir.path_join("Off pack/iron-chest.glb"), chest)
	# A zip pack: a model of the folder pack's name, and a .gltf whose buffer is a file of its own.
	var gltf := _triangle_gltf("data/triangle.bin")
	var zip_path := dir.path_join("zip-pack.zip")
	_zip(zip_path, {"zip-pack/pack.json": JSON.stringify({"name": "Zipped models", "licence": "CC BY 4.0"}).to_utf8_buffer(),
		"zip-pack/wooden-chest.glb": chest, "zip-pack/stone-furnace.gltf": gltf[0], "zip-pack/data/triangle.bin": gltf[1]})
	# Something that isn't a zip.
	_write(dir.path_join("broken.zip"), "not a zip".to_utf8_buffer())

	var found := ModelPacks.scan(dir)
	var ids: Array = found.map(func(p: Dictionary) -> String: return p["id"])
	ids.sort()
	check(ids == ["dir:Folder belts", "dir:Off pack", "loose", "zip:broken.zip", "zip:zip-pack.zip"],
		"the loose models, each folder with models and each zip are packs (no textures folder, no README): %s" % [ids])
	var folder := _pack(found, "dir:Folder belts")
	check(folder.get("title") == "Belts in a folder" and folder["info"].get("version") == "2.0" and folder["info"].get("author") == "Tester"
		and folder["info"].get("licence") == "CC0" and folder["info"].get("description") == "Belts for the test." and int(folder["count"]) == 2,
		"a folder pack's pack.json (its \"license\" as licence) and its two models: %s" % [folder])
	var zipped := _pack(found, "zip:zip-pack.zip")
	check(zipped.get("title") == "Zipped models" and zipped["info"].get("licence") == "CC BY 4.0" and int(zipped["count"]) == 2
		and zipped["problem"] == "", "a zip pack read from its directory, before it is unpacked: %s" % [zipped])
	check(str(_pack(found, "zip:broken.zip").get("problem", "")).contains("can't be read"), "a file that isn't a zip says so")

	# The zip first, the pack off: unpacked on a worker; until taken in, none of its models are used.
	var order := ["zip:zip-pack.zip", "dir:Folder belts", "loose", "dir:Off pack", "zip:broken.zip"]
	ModelPacks.configure(dir, order, ["dir:Off pack"])
	check(ModelPacks._busy and bool(_pack(ModelPacks.packs, "zip:zip-pack.zip")["unpacking"]) and ModelPacks.find("stone-furnace", true).begins_with(ModelPacks.BUILTIN_DIR),
		"the zip is unpacked on a worker; its models wait for it (the built-in one meanwhile)")
	ModelPacks.wait()
	check(ModelPacks.is_ready() and not ModelPacks._busy, "unpacked and taken in")
	var cache := str(_pack(ModelPacks.packs, "zip:zip-pack.zip")["cache"])
	var zip_chest := cache.path_join("zip-pack/wooden-chest.glb")
	check(cache.begins_with(ProjectSettings.globalize_path("user://model-packs")) and FileAccess.file_exists(zip_chest),
		"the zip is unpacked into user://model-packs/<name>-<size>-<modified>: %s" % cache)
	check(ModelPacks.find("wooden-chest", true) == zip_chest, "the higher pack's model wins: %s" % ModelPacks.find("wooden-chest", true))
	check(ModelPacks.find("transport-belt", true) == dir.path_join("Folder belts/belts/deep/transport-belt.glb"), "a model deep in a folder pack is found")
	check(ModelPacks.find("iron-chest", true) == dir.path_join("iron-chest.glb"), "the pack turned off isn't used: %s" % ModelPacks.find("iron-chest", true))
	check(ModelPacks.find("Wooden-Chest", true) == zip_chest, "names are found whatever their case")
	check(ModelPacks.find("wooden-chest", false) == "" and ModelPacks.find("nothing-like-it", true) == "", "the folder's packs replace, none fills in")
	check(ModelPacks.pack_of(ModelLibrary.GLTF_SOURCE + zip_chest).get("id") == "zip:zip-pack.zip" and ModelPacks.owns(dir.path_join("iron-chest.glb"))
		and ModelPacks.pack_of(dir.path_join("Folder belts/wooden-chest.glb")).get("id") == "dir:Folder belts"
		and not ModelPacks.owns(dir.path_join("Off pack/iron-chest.glb")) and not ModelPacks.owns("res://assets/models/packs/wube3dp/wooden-chest.glb"),
		"each file's pack: the zip's copy, the loose models, a folder; not the pack off; Zenith's own isn't a modeller's")
	check(str(_pack(ModelPacks.packs, "zip:broken.zip")["problem"]) != "" and ModelPacks.active().all(func(p: Dictionary) -> bool: return p["id"] != "zip:broken.zip"),
		"the broken zip is left out")
	var lines := ModelPacks.summary()
	check(lines.size() > 0 and lines[0].begins_with("[models] %d model(s) from 6 packs, the higher winning: Zipped models (zip-pack.zip, 2), Belts in a folder (Folder belts/, 1), Loose models (the folder's top, 1), FUE5 (built in, " % ModelPacks.in_use().size())
		and lines[0].contains("), Wube3DP (built in, ") and lines[0].find("Wube3DP (built in, ") < lines[0].find("Placeholders (built in, "), "the log says how many models from how many packs, the built-in ones under the folder's: %s" % [lines])
	check(Array(lines).any(func(l: String) -> bool: return l.contains("Off pack") and l.contains("is off"))
		and Array(lines).any(func(l: String) -> bool: return l.contains("1 of Belts in a folder's models are another pack's: wooden-chest")),
		"and which pack is off, and which models a higher pack covers: %s" % [lines])
	check(not Array(lines).any(func(l: String) -> bool: return l.contains("broken")) and ModelPacks.summary(true).size() == lines.size() + 1,
		"the broken zip is warned of, apart from the summary (which the debug menu's report adds it to)")
	var report := ModelPacks.report()
	check(report.contains("wooden-chest: Zipped models") and report.contains("transport-belt: Belts in a folder") and report.contains("iron-chest: Loose models"),
		"the debug menu's report says each model's pack: %s" % report)

	# Model library: a pack's model replaces Zenith's own, read as a modeller's; a .gltf's .bin found beside it.
	ModelLibrary._sources.clear()
	var furnace := ModelLibrary._source("stone-furnace")
	check(furnace == ModelLibrary.GLTF_SOURCE + cache.path_join("zip-pack/stone-furnace.gltf"), "the zip's .gltf replaces Zenith's stone furnace: %s" % furnace)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	check(doc.append_from_file(furnace.substr(ModelLibrary.GLTF_SOURCE.length()), state) == OK and state.get_meshes().size() == 1,
		"the unpacked .gltf reads its buffer from data/triangle.bin beside it")
	var load := ModelLibrary.Load.new()
	load.path = furnace.substr(ModelLibrary.GLTF_SOURCE.length())
	load.modeller = ModelPacks.owns(load.path)
	load.run()
	check(load.modeller and load.ok and not load.groups.is_empty(), "and the model library reads it as a modeller's model")
	check(not ModelLibrary._source("assembling-machine-1").contains(dir) and not ModelLibrary._source("assembling-machine-1").contains(cache),
		"a model no pack has is Zenith's own")

	# The other order, the pack on: the zip's copy is used again, not unpacked again.
	ModelPacks.configure(dir, ["dir:Folder belts", "zip:zip-pack.zip", "dir:Off pack", "loose", "zip:broken.zip"], [])
	check(not ModelPacks.pack("zip:zip-pack.zip").is_empty() and ModelPacks.find("stone-furnace", true) == cache.path_join("zip-pack/stone-furnace.gltf"),
		"an unchanged zip's copy is used at once")
	if ModelPacks.PackCheck.install_dir() != "":
		# The pack off until now was never checked for copies of Factorio's files: it waits for it.
		check(ModelPacks._busy and ModelPacks.pack("dir:Off pack").is_empty(), "a pack turned on for the first time waits for its check")
		ModelPacks.wait()
	check(ModelPacks.find("wooden-chest", true) == dir.path_join("Folder belts/wooden-chest.glb"), "the folder pack above the zip wins: %s" % ModelPacks.find("wooden-chest", true))
	check(ModelPacks.find("iron-chest", true) == dir.path_join("Off pack/iron-chest.glb"), "the pack turned on, above the loose models, wins")

	# New packs go on top, by name; the rest keep their saved order.
	ModelPacks.configure(dir, ["loose"], [])
	check(ModelPacks.saved_order() == ["dir:Folder belts", "zip:broken.zip", "dir:Off pack", "zip:zip-pack.zip", "loose", "builtin:fue5", "builtin:wube3dp", "builtin:placeholders", "builtin:factorio"],
		"packs not in the saved order go on top, the built-in ones not saved yet under them: %s" % [ModelPacks.saved_order()])

	# --models: one more pack on top, only filling in unless --models-first.
	var extra := ProjectSettings.globalize_path("user://more-models")
	_write(extra.path_join("wooden-chest.glb"), chest)
	_write(extra.path_join("sub/zz-test-entity.glb"), chest)
	ModelPacks.configure(dir, order, [], extra, false)
	ModelPacks.wait()  # a new pack: checked for copies of Factorio's files first
	check(ModelPacks.packs[0]["kind"] == "arg" and ModelPacks.find("zz-test-entity", false) == extra.path_join("sub/zz-test-entity.glb")
		and ModelPacks.find("wooden-chest", true) == zip_chest and not ModelPacks.saved_order().has("arg"),
		"--models fills in entities without a model (and isn't saved in the order)")
	ModelLibrary._sources.clear()
	check(ModelLibrary._source("zz-test-entity") == ModelLibrary.GLTF_SOURCE + extra.path_join("sub/zz-test-entity.glb")
		and ModelLibrary._source("iron-chest") == ModelLibrary.GLTF_SOURCE + dir.path_join("iron-chest.glb"),
		"the model library takes a fill-in pack's model only where nothing else has one")
	ModelPacks.configure(dir, order, [], extra, true)
	check(ModelPacks.find("wooden-chest", true) == extra.path_join("wooden-chest.glb"), "--models-first: it replaces, above the folder's packs")

	# The zip changed: unpacked again into a new copy, the old one removed.
	_zip(zip_path, {"zip-pack/wooden-chest.glb": chest, "zip-pack/steel-chest.glb": chest})
	ModelPacks.configure(dir, order, [])
	var cache2 := str(_pack(ModelPacks.packs, "zip:zip-pack.zip")["cache"])
	check(cache2 != cache and ModelPacks._busy, "a changed zip gets a new copy")
	ModelPacks.wait()
	check(ModelPacks.find("steel-chest", true) == cache2.path_join("zip-pack/steel-chest.glb") and ModelPacks.find("stone-furnace", true).begins_with(ModelPacks.BUILTIN_DIR)
		and not DirAccess.dir_exists_absolute(cache), "its new models are used, the old copy is gone")
	check(_pack(ModelPacks.packs, "zip:zip-pack.zip")["title"] == "zip-pack", "without a pack.json a zip's title is its name")

	# A zip turned off: its models aren't used, its copy kept for when it is turned on again.
	ModelPacks.configure(dir, order, ["zip:zip-pack.zip"])
	check(not ModelPacks._busy and ModelPacks.find("steel-chest", true).begins_with(ModelPacks.BUILTIN_DIR) and DirAccess.dir_exists_absolute(cache2),
		"a zip turned off isn't used, its copy kept")
	_remove_tree(cache2)
	ModelPacks.configure(dir, order, ["zip:zip-pack.zip"])
	check(not ModelPacks._busy and not DirAccess.dir_exists_absolute(cache2), "a zip turned off isn't unpacked")

	# A damaged zip (its deflated data changed): left out with a warning once it fails to unpack.
	var damaged := dir.path_join("damaged.zip")
	_zip(damaged, {"damaged/wooden-chest.glb": chest})
	var entries := ModFiles.zip_entries(damaged)
	var entry: PackedInt64Array = entries.get("damaged/wooden-chest.glb", PackedInt64Array())
	if entry.size() == 5 and entry[0] == 8:
		var bytes := FileAccess.get_file_as_bytes(damaged)
		var data_at := entry[4] + 30 + bytes.decode_u16(entry[4] + 26) + bytes.decode_u16(entry[4] + 28)
		for i in 16:
			bytes[data_at + (entry[2] >> 1) + i] ^= 0x5a
		_write(damaged, bytes)
		ModelPacks.configure(dir, ["zip:damaged.zip"], ["zip:zip-pack.zip"])
		ModelPacks.wait()
		var hurt := _pack(ModelPacks.packs, "zip:damaged.zip")
		check(str(hurt["problem"]).contains("can't be read") and not bool(hurt["unpacking"]) and ModelPacks.find("wooden-chest", true) == dir.path_join("Folder belts/wooden-chest.glb"),
			"a damaged zip is left out once unpacking finds it, the next pack's model used: %s" % [hurt])
		var left := Array(DirAccess.get_directories_at(ProjectSettings.globalize_path("user://model-packs")))
		check(not DirAccess.dir_exists_absolute(str(hurt["cache"])) and not left.any(func(d: String) -> bool: return d.begins_with("damaged")),
			"and leaves no half copy behind: %s" % [left])
	else:
		print("NOTE the damaged zip's entry isn't deflated (%s): not checked" % [entry])


## The unpacked copies of zips another launcher's folder has (not this one's) are kept until unused
## --pack-cache-keep days (their stamp), so switching launchers doesn't unpack them again; 0 removes
## them at once, as before; a changed zip's old copy (the same zip name) goes at once either way.
func _cache_keep() -> void:
	var dir := ProjectSettings.globalize_path("user://models-keep")
	var chest := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path("res://assets/models/packs/wube3dp/wooden-chest.glb"))
	var zip_path := dir.path_join("keep-pack.zip")
	DirAccess.make_dir_recursive_absolute(dir)
	_zip(zip_path, {"keep-pack/wooden-chest.glb": chest})
	var root := ProjectSettings.globalize_path(ModelPacks.cache_root)
	var other := root.path_join("Other-123-456")  # another launcher's zip
	var old_used := root.path_join("Older-123-456")  # and one unused for longer than kept
	var mine_old := root.path_join("keep-pack-1-2")  # this folder's zip, changed since
	for d in [other, old_used, mine_old]:
		_write(d.path_join("pack/wooden-chest.glb"), chest)
	var now := int(Time.get_unix_time_from_system())
	_write(old_used + ModelPacks.USED_SUFFIX, str(now - (ModelPacks.PACK_CACHE_KEEP_DAYS + 1) * 86400).to_utf8_buffer())
	_write(root.path_join("Gone-1-2" + ModelPacks.USED_SUFFIX), str(now).to_utf8_buffer())  # a stamp without its copy
	var saved := ModelPacks.pack_cache_keep
	ModelPacks.pack_cache_keep = ModelPacks.PACK_CACHE_KEEP_DAYS
	ModelPacks.configure(dir, ["zip:keep-pack.zip"], [])
	ModelPacks.wait()
	var cache := str(_pack(ModelPacks.packs, "zip:keep-pack.zip")["cache"])
	check(DirAccess.dir_exists_absolute(cache) and DirAccess.dir_exists_absolute(other) and FileAccess.file_exists(other.path_join("pack/wooden-chest.glb")),
		"another launcher's unpacked copy is kept (used lately)")
	check(not DirAccess.dir_exists_absolute(old_used) and not FileAccess.file_exists(old_used + ModelPacks.USED_SUFFIX),
		"a copy unused for longer than --pack-cache-keep days is removed with its stamp")
	check(not DirAccess.dir_exists_absolute(mine_old), "this folder's changed zip's old copy is removed at once")
	check(not FileAccess.file_exists(root.path_join("Gone-1-2" + ModelPacks.USED_SUFFIX)), "a stamp left without its copy is removed")
	check(ModelPacks.last_used(cache) >= now and ModelPacks.last_used(cache) <= now + 60, "the copy in use is stamped used now: %d" % ModelPacks.last_used(cache))
	check(ModelPacks._copy_zip_name("Zenith-1663000000-1763000000") == "Zenith" and ModelPacks._copy_zip_name("my-pack-v2-12-34") == "my-pack-v2"
		and ModelPacks._copy_zip_name("odd") == "odd", "a copy's zip name read from its folder's name")
	# --pack-cache-keep=0: as before, every copy this folder has no zip for goes.
	ModelPacks.pack_cache_keep = 0
	ModelPacks.configure(dir, ["zip:keep-pack.zip"], [])
	ModelPacks.wait()
	check(not DirAccess.dir_exists_absolute(other) and DirAccess.dir_exists_absolute(cache), "--pack-cache-keep=0: another launcher's copy is removed at once")
	ModelPacks.pack_cache_keep = saved
	_remove_tree(dir)


## M7: Zenith's own models are three built-in packs (res://assets/models/packs/), and the Factorio
## pack (the install's pictures): under the models folder's in their default order, Factorio last;
## Placeholders moves and switches off as any pack.
func _builtin() -> void:
	var found := ModelPacks.builtin_packs()
	var by_id := {}
	for p: Dictionary in found:
		by_id[p["id"]] = p
	check(found.size() == 4 and by_id.has("builtin:wube3dp") and by_id.has("builtin:fue5") and by_id.has("builtin:placeholders")
		and by_id.has(ModelPacks.FACTORIO_ID), "three built-in packs and Factorio's: %s" % [by_id.keys()])
	var counts: Array = [int(by_id.get("builtin:wube3dp", {}).get("count", 0)), int(by_id.get("builtin:fue5", {}).get("count", 0)),
		int(by_id.get("builtin:placeholders", {}).get("count", 0))]
	check(counts == [94, 142, 377], "Wube3DP 94 models, FUE5 142, Placeholders 377 (613): %s" % [counts])
	check(by_id.get("builtin:wube3dp", {}).get("title") == "Wube3DP (Adapted)" and by_id.get("builtin:fue5", {}).get("title") == "FUE5 (Adapted)"
		and by_id.get("builtin:wube3dp", {}).get("short") == "Wube3DP" and by_id.get("builtin:fue5", {}).get("short") == "FUE5"
		and by_id.get("builtin:placeholders", {}).get("title") == "Placeholders"
		and str(by_id.get("builtin:fue5", {}).get("info", {}).get("licence", "")) == "CC BY-NC-SA 3.0",
		"their names (Adapted: other people's models converted), short names and licences from their pack.json")
	var all_there := true
	for p: Dictionary in found:
		for name: String in p["models"]:
			all_there = all_there and FileAccess.file_exists(str(p["models"][name]))
	check(all_there, "every built-in model's file is there")
	var default := ModelPacks.ordered(found, [], [])
	check(default.map(func(p: Dictionary) -> String: return p["id"]) == ["builtin:fue5", "builtin:wube3dp", "builtin:placeholders", ModelPacks.FACTORIO_ID],
		"their default order (the owner's): FUE5, Wube3DP, Placeholders, Factorio")
	var zip := {"id": "zip:Zenith.zip", "title": "Zenith", "kind": "zip"}
	var saved := ModelPacks.ordered(found + [zip], ["builtin:placeholders", "builtin:wube3dp"], ["builtin:placeholders", "builtin:wube3dp"])
	check(saved.map(func(p: Dictionary) -> String: return p["id"]) == ["zip:Zenith.zip", "builtin:placeholders", "builtin:wube3dp", "builtin:fue5", ModelPacks.FACTORIO_ID]
		and not bool(saved[1]["on"]) and not bool(saved[2]["on"]) and bool(saved[3]["on"]) and not ModelPacks.fixed(saved[1]),
		"a new zip on top, the saved order kept (Placeholders first and off as saved: it moves now), the built-in ones not saved under them, Factorio last: %s" % [saved.map(func(p: Dictionary) -> String: return "%s %s" % [p["id"], p["on"]])])
	# Before any configure() (a test script, a tool): the built-in ones in their default order. The
	# Factorio pack is among them with or without an install (on, no problem); without one (CI) it
	# has nothing to give: factorio_on() is false, so it draws nothing.
	ModelPacks._configured = false
	check(ModelPacks.active().size() == 4 and (ItemIcons.factorio_data_dir() != "" or not ModelPacks.factorio_on()) and ModelPacks.find("assembling-machine-1", true).begins_with(ModelPacks.BUILTIN_DIR + "wube3dp/")
		and ModelPacks.find("wooden-chest", true).begins_with(ModelPacks.BUILTIN_DIR + "fue5/")
		and ModelPacks.find("locomotive", true).begins_with(ModelPacks.BUILTIN_DIR + "fue5/")
		and ModelPacks.find("assembling-machine-2", true).begins_with(ModelPacks.BUILTIN_DIR + "placeholders/"),
		"the default order's winners: FUE5's chest over Wube3DP's, Wube3DP's assembler and FUE5's locomotive over Placeholders'")
	ModelLibrary._sources.clear()
	check(ModelLibrary._source("locomotive") == ModelLibrary.GLTF_SOURCE + ModelPacks.BUILTIN_DIR + "fue5/locomotive.glb"
		and not ModelPacks.owns(ModelPacks.BUILTIN_DIR + "fue5/locomotive.glb"), "the model library reads the built-in packs, not as a modeller's")
	# Families: a prototype's model with its variants.
	var cases := {"inserter-east": "inserter", "transport-belt-curve-left": "transport-belt", "underground-belt-input": "underground-belt",
		"stone-wall-es-fill": "stone-wall", "stone-wall-gate-s": "stone-wall", "stone-wall-gate-single-e": "stone-wall", "stone-wall-gate-ew": "stone-wall", "big-biter-corpse-2": "big-biter", "pipe-straight-horizontal": "pipe", "pipe-to-ground-west": "pipe-to-ground",
		"straight-rail-ne": "straight-rail", "cargo-bay-wall-n": "cargo-bay", "inserter-arm-long-hand-open": "long-handed-inserter",
		"inserter-arm-basic-upper": "inserter", "inserter-arm-bulk-hand-closed": "bulk-inserter", "inserter-arm-stack-upper": "stack-inserter",
		"character-armor-2": "character", "character-corpse": "character", "demolisher-segment": "demolisher",
		"rocket-silo-rocket": "rocket-silo", "big-stomper-shell": "big-stomper-pentapod", "cargo-pod-container": "cargo-pod",
		"assembling-machine-1": "assembling-machine-1", "crash-site-chest-2": "crash-site-chest-2", "cliff-fulgora-sides": "cliff-fulgora",
		"iron-ore-rich": "iron-ore", "fast-transport-belt": "fast-transport-belt",
		# Scattered ore's numbered rocks, whatever the number; window pipes; a drill's fluid part (model_library.gd).
		"coal-4": "coal", "stone-12": "stone", "uranium-ore-7": "uranium-ore", "iron-ore-1": "iron-ore", "copper-ore-9": "copper-ore",
		"pipe-straight-vertical-window": "pipe", "pipe-straight-horizontal-window": "pipe",
		"electric-mining-drill-wet": "electric-mining-drill", "stone-wall": "stone-wall", "stone-furnace": "stone-furnace"}
	var wrong: Array = []
	for n: String in cases:
		if ModelPacks.family(n) != cases[n]:
			wrong.append("%s -> %s" % [n, ModelPacks.family(n)])
	check(wrong.is_empty(), "each model's family: %s" % [wrong])
	check(ModelPacks.family_names("inserter") == ["inserter", "inserter-arm-basic-hand-closed", "inserter-arm-basic-hand-open",
		"inserter-arm-basic-upper", "inserter-east", "inserter-south", "inserter-west"],
		"a family's names in the packs, its arm's parts with them: %s" % [ModelPacks.family_names("inserter")])
	# The owner: "inserter arm and stuff should all be in the inserter, not separate". No pack lists
	# a part on its own: Wube3DP's arms, character looks; Placeholders' demolisher pieces, shells, rocket.
	var parts_alone: Array = []
	for p: Dictionary in found:
		for fam: String in ModelPacks.families_of(p):
			if fam.begins_with("inserter-arm") or fam.begins_with("character-") or fam.begins_with("demolisher-") \
					or fam.ends_with("-shell") or fam == "rocket-silo-rocket" or fam == "cargo-pod-container":
				parts_alone.append("%s: %s" % [p["id"], fam])
	check(parts_alone.is_empty(), "no part listed as a family of its own: %s" % [parts_alone])
	var wube_fams := ModelPacks.families_of(_pack(found, "builtin:wube3dp"))
	check((wube_fams["inserter"] as Array).has("inserter-arm-basic-upper") and (wube_fams["character"] as Array).has("character-gun")
		and (wube_fams["long-handed-inserter"] as Array).has("inserter-arm-long-hand-open"),
		"Wube3DP's inserter lists its arm, the character its gun")


## M7, M8: a family taken from a chosen pack whatever the order (settings.cfg `choices`), and a
## building from a pack of its own (`name@pack`, PACK_KEY): that pack's model, its tier's base
## recoloured when it has only that, the usual model when it has neither.
func _choices() -> void:
	ModelPacks.configure("", [], [])
	ModelLibrary._sources.clear()
	ModelLibrary._cache.clear()
	check(ModelLibrary._source("wooden-chest").contains("/packs/fue5/"), "FUE5's chest by the order")
	check(ModelLibrary.single_model("boiler") and ModelLibrary._source("boiler").contains("/packs/fue5/"),
		"FUE5's boiler by the order (above Placeholders): one model turned")
	ModelPacks.set_choices({"wooden-chest": "builtin:wube3dp", "inserter": "builtin:placeholders", "boiler": "builtin:placeholders"})
	ModelLibrary.choices_changed(["wooden-chest", "inserter", "boiler"])
	check(ModelPacks.choice("wooden-chest") == "builtin:wube3dp" and ModelLibrary._source("wooden-chest").contains("/packs/wube3dp/"),
		"a family chosen from Wube3DP: its chest")
	check(ModelPacks.choice("inserter-east") == "builtin:placeholders" and ModelLibrary._source("inserter-east").contains("/packs/wube3dp/"),
		"a pack chosen without the model: the order's (Placeholders has no inserters)")
	check(ModelPacks.choice("inserter-arm-basic-upper") == "builtin:placeholders" and ModelPacks.choice("inserter-arm-long-upper") == "",
		"the inserter's choice covers its arm's parts, not the long-handed one's")
	ModelPacks.set_choices({"inserter": "builtin:wube3dp"})
	ModelLibrary.choices_changed(["inserter"])
	check(ModelLibrary._alias_of("inserter-arm-basic-hand-open") == "inserter-arm-basic-hand-open@builtin:wube3dp"
		and ModelLibrary._source("inserter-arm-basic-hand-open@builtin:wube3dp").contains("/packs/wube3dp/"),
		"Wube3DP chosen for the inserter: its arm drawn from Wube3DP")
	ModelPacks.set_choices({"wooden-chest": "builtin:wube3dp", "inserter": "builtin:placeholders", "boiler": "builtin:placeholders"})
	ModelLibrary.choices_changed(["wooden-chest", "inserter", "boiler"])
	check(not ModelLibrary.single_model("boiler") and ModelLibrary._source("boiler").contains("/packs/placeholders/")
		and ModelLibrary.model_name("boiler", "boiler", {}, 4) == "boiler-east",
		"Placeholders' boiler chosen: a model per direction again")
	check(ModelPacks.in_use()["wooden-chest"]["id"] == "builtin:wube3dp", "the chosen pack is the one in use")
	ModelPacks.set_choices({})
	ModelLibrary.choices_changed([])
	check(ModelLibrary._source("wooden-chest").contains("/packs/fue5/") and ModelLibrary.single_model("boiler"),
		"no choice: the order again")
	# A building's own pack (PACK_KEY), as the in-game chooser sets it.
	var key := ModelLibrary.PACK_KEY
	check(ModelLibrary.entity_models("wooden-chest", "container", {key: "builtin:wube3dp"}) == ["wooden-chest@builtin:wube3dp"]
		and ModelLibrary.entity_models("transport-belt", "transport-belt", {"s": "l", key: "builtin:wube3dp"}) == ["transport-belt-curve-left@builtin:wube3dp", "transport-belt@builtin:wube3dp"],
		"a building's models asked of its pack")
	check(ModelLibrary._source("wooden-chest@builtin:wube3dp").contains("/packs/wube3dp/") and ModelLibrary._source("wooden-chest@builtin:placeholders").contains("/packs/fue5/"),
		"its pack's model, else the usual one")
	var wube_chest := ModelLibrary.mesh_for_entity("wooden-chest", "container", {key: "builtin:wube3dp"})
	var usual := ModelLibrary.mesh_for_entity("wooden-chest", "container", {})
	check(wube_chest != null and usual != null and wube_chest != usual and ModelLibrary.mesh_for("wooden-chest@builtin:placeholders") == usual,
		"drawn with a mesh of its own; a pack without it shares the usual mesh")
	check(ModelLibrary._source("fast-transport-belt@builtin:wube3dp") == "" and ModelLibrary._alias_of("fast-transport-belt@builtin:wube3dp") == ""
		and ModelLibrary._tier_base("fast-transport-belt@builtin:wube3dp") == "transport-belt@builtin:wube3dp",
		"a tier its pack has only the base of: that base recoloured")
	check(ModelLibrary.model_name("boiler", "boiler", {key: "builtin:placeholders"}, 4) == "boiler-east" and ModelLibrary.model_name("boiler", "boiler", {}, 4) == "boiler"
		and ModelLibrary.turn_dir("boiler", 4, {key: "builtin:placeholders"}, "boiler") == 0 and ModelLibrary.turn_dir("boiler", 4, {}, "boiler") == 4,
		"a boiler drawn from Placeholders: its east model unturned; the others FUE5's one model turned")
	ModelLibrary._sources.clear()
	ModelLibrary._cache.clear()
	ModelLibrary._parts.clear()


## The downloads' bundled pack, Zenith.zip (it was Default.zip, "Default"): listed as Zenith on top;
## an old Default.zip alone is Zenith; both give one Zenith pack; settings and building choices
## saved with "zip:Default.zip" apply to it.
func _bundled() -> void:
	var BuildingModels := preload("res://scripts/world/building_models.gd")
	var chest := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path("res://assets/models/packs/wube3dp/wooden-chest.glb"))
	var dir := ProjectSettings.globalize_path("user://models-bundled")
	_remove_tree(dir)
	var zenith := dir.path_join("Zenith.zip")
	var old := dir.path_join("Default.zip")
	DirAccess.make_dir_recursive_absolute(dir)
	_zip(zenith, {"pack.json": JSON.stringify({"name": "Zenith", "author": "Vasillo"}).to_utf8_buffer(), "wooden-chest.glb": chest})
	var found := ModelPacks.scan(dir)
	var listed := ModelPacks.ordered(found + ModelPacks.builtin_packs(), [], [])
	check(found.size() == 1 and found[0]["id"] == ModelPacks.BUNDLED_ID and found[0]["title"] == "Zenith"
		and listed.map(func(p: Dictionary) -> String: return p["id"]) == ["zip:Zenith.zip", "builtin:fue5", "builtin:wube3dp", "builtin:placeholders", "builtin:factorio"],
		"Zenith.zip is listed as Zenith, on top: %s" % [listed.map(func(p: Dictionary) -> String: return "%s %s" % [p["id"], p["title"]])])
	# An old Default.zip alone (its pack.json still says Default): Zenith, under Zenith's id.
	DirAccess.remove_absolute(zenith)
	_zip(old, {"pack.json": JSON.stringify({"name": "Default", "author": "Vasillo"}).to_utf8_buffer(), "wooden-chest.glb": chest})
	found = ModelPacks.scan(dir)
	check(found.size() == 1 and found[0]["id"] == ModelPacks.BUNDLED_ID and found[0]["title"] == "Zenith"
		and ModelPacks.where(found[0]) == "Default.zip", "an old Default.zip alone is shown as Zenith: %s" % [found.map(func(p: Dictionary) -> String: return "%s %s" % [p["id"], p["title"]])])
	# Both: one Zenith pack, Zenith.zip's.
	_zip(zenith, {"pack.json": JSON.stringify({"name": "Zenith", "author": "Vasillo"}).to_utf8_buffer(), "wooden-chest.glb": chest})
	found = ModelPacks.scan(dir)
	check(found.size() == 1 and found[0]["id"] == ModelPacks.BUNDLED_ID and ModelPacks.where(found[0]) == "Zenith.zip",
		"Zenith.zip and an old Default.zip: one Zenith pack, Zenith.zip's: %s" % [found.map(func(p: Dictionary) -> String: return ModelPacks.where(p))])
	# Saved with the old id: the order and the switch apply to Zenith.
	listed = ModelPacks.ordered(found + ModelPacks.builtin_packs(), ["builtin:wube3dp", "zip:Default.zip", "builtin:fue5"], ["zip:Default.zip"])
	check(listed.map(func(p: Dictionary) -> String: return p["id"]) == ["builtin:wube3dp", "zip:Zenith.zip", "builtin:fue5", "builtin:placeholders", "builtin:factorio"]
		and not bool(listed[1]["on"]), "a saved order and off naming Default apply to Zenith: %s" % [listed.map(func(p: Dictionary) -> String: return "%s %s" % [p["id"], p["on"]])])
	check(ModelPacks.saved_order(listed) == ["builtin:wube3dp", "zip:Zenith.zip", "builtin:fue5", "builtin:placeholders", "builtin:factorio"]
		and ModelPacks.saved_off(listed) == ["zip:Zenith.zip"], "saved again under Zenith's id")
	# A family chosen from Default: Zenith's model.
	ModelPacks.configure(dir, ["zip:Default.zip"], [])
	ModelPacks.wait()
	ModelPacks.set_choices({"wooden-chest": "zip:Default.zip"})
	check(ModelPacks.choices.get("wooden-chest") == ModelPacks.BUNDLED_ID and ModelPacks.choice("wooden-chest") == ModelPacks.BUNDLED_ID
		and ModelPacks.find_in("zip:Default.zip", "wooden-chest") != "" and ModelPacks.pack("zip:Default.zip").get("title") == "Zenith",
		"a family chosen from Default is taken from Zenith")
	ModelPacks.set_choices({})
	# A building drawn from Default (user://building_models.cfg): Zenith's.
	var cfg := ConfigFile.new()
	cfg.set_value("bundled-save", "77", "zip:Default.zip")
	cfg.save(BuildingModels.PATH)
	BuildingModels.reload()
	check(BuildingModels.pack_for("bundled-save", 77) == ModelPacks.BUNDLED_ID, "a building's choice of Default is Zenith's: %s" % BuildingModels.pack_for("bundled-save", 77))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(BuildingModels.PATH))
	BuildingModels.reload()
	ModelPacks.configure("", [], [])
	_remove_tree(dir)


## The Factorio pack (the install's pictures, nothing committed) and Placeholders moving like any pack:
## Factorio above Placeholders draws an entity as its picture's card and an item as its icon card,
## Placeholders above Factorio its model, both off the box (no model, no card); an order saved before
## the Factorio pack puts it last; a choice of it, and a building's own pack, draw the picture.
func _factorio() -> void:
	const SpriteStandins := preload("res://scripts/world/sprite_standins.gd")
	const ItemModels := preload("res://scripts/world/item_models.gd")
	var built := ModelPacks.builtin_packs()
	var fp := _pack(built, ModelPacks.FACTORIO_ID)
	check(fp.get("title") == "Factorio" and ModelPacks.is_sprite_pack(fp) and ModelPacks.is_sprite_pack(ModelPacks.FACTORIO_ID)
		and not ModelPacks.is_sprite_pack(_pack(built, "builtin:placeholders")) and ModelPacks.is_builtin(fp)
		and str(fp["info"].get("icon_image", "")) == ModelPacks.FACTORIO_LOGO and str(fp["info"].get("credit", "")).contains("Wube Software")
		and ModelPacks.where(fp) == "your Factorio install", "the Factorio pack: built in, its logo and credit from the install")
	var old := ModelPacks.ordered(built, ["builtin:wube3dp", "builtin:fue5", "builtin:placeholders"], [])
	check(old.map(func(p: Dictionary) -> String: return p["id"]) == ["builtin:wube3dp", "builtin:fue5", "builtin:placeholders", ModelPacks.FACTORIO_ID]
		and old.all(func(p: Dictionary) -> bool: return bool(p["on"])), "an order saved before the Factorio pack: it goes last, under Placeholders")
	if ItemIcons.factorio_data_dir() == "":
		var listed := ModelPacks.listed("", [], [])
		check(str(_pack(listed, ModelPacks.FACTORIO_ID).get("problem", "")) != "", "without an install the Factorio pack is listed with the reason")
		print("NOTE no Factorio install here: the Factorio pack's pictures aren't checked")
		return
	check(int(fp["count"]) > 300 and ModelPacks.sprite_names().has("assembling-machine-1") and not ModelPacks.sprite_names().has("character")
		and not ModelPacks.sprite_names().has("car"), "its pictures: %d entities, not the character's or a car's (pictures round the turn)" % int(fp["count"]))
	var off_others := ["builtin:fue5", "builtin:wube3dp"]
	# Factorio above Placeholders.
	ModelPacks.set_choices({})
	ModelPacks.use(ModelPacks.ordered(built, [ModelPacks.FACTORIO_ID, "builtin:placeholders"] + off_others, off_others))
	ModelLibrary.choices_changed([])
	check(ModelPacks.factorio_on() and ModelLibrary.draws_sprite("assembling-machine-1") and ModelLibrary.ready("assembling-machine-1")
		and ModelLibrary.mesh_for("assembling-machine-1") == null and ModelLibrary.mesh_for_entity("assembling-machine-2", "assembling-machine", {}) == null,
		"Factorio above Placeholders: assemblers have no model (their picture instead)")
	check(ModelPacks.item_model_path("iron-plate") == "" and ModelPacks.item_source("iron-plate")["pack"]["id"] == ModelPacks.FACTORIO_ID,
		"and an iron plate no item model: its icon card")
	var card: Mesh = null
	for i in 400:
		card = SpriteStandins.card("assembling-machine-1", 0, Vector2(3, 3), "assembling-machine")
		if card != null or not SpriteStandins.coming("assembling-machine-1", 0):
			break
		OS.delay_msec(5)
		SpriteStandins.poll()
	check(card is QuadMesh, "assembling-machine-1 drawn as its sprite card (from sprite_projection.json's frame, the install's sheet)")
	var pic := SpriteStandins.picture("assembling-machine-1")
	check(pic.get("texture") is Texture2D and pic.get("card") == card and (pic["size"] as Vector2).x > 2.5 and (pic["size"] as Vector2).x < 4.5
		and absf(float(pic["px_per_tile"]) - SpriteStandins.PX) < 0.5, "the preview's picture: %s" % [pic.get("size")])
	check(SpriteStandins.item_card("iron-plate") is PlaneMesh and SpriteStandins.item_picture("iron-plate") != null, "the preview's item card")
	# Placeholders above Factorio.
	ModelPacks.use(ModelPacks.ordered(built, ["builtin:placeholders", ModelPacks.FACTORIO_ID] + off_others, off_others))
	ModelLibrary.choices_changed([])
	check(not ModelLibrary.draws_sprite("assembling-machine-2") and ModelLibrary.mesh_for("assembling-machine-2") != null
		and ModelPacks.item_model_path("iron-plate") == ItemModels.DIR + "iron-plate.glb", "Placeholders above Factorio: its assembler and iron plate models")
	check(ModelLibrary.draws_sprite("assembling-machine-1") and ModelLibrary.mesh_for("assembling-machine-1") == null,
		"an entity no pack in use has a model of (Wube3DP's assembler 1, off) falls to Factorio's picture: no model, its card")
	ModelPacks.set_choices({"assembling-machine-2": ModelPacks.FACTORIO_ID})
	ModelLibrary.choices_changed([])
	check(ModelLibrary.draws_sprite("assembling-machine-2") and ModelLibrary.mesh_for("assembling-machine-2") == null, "Factorio chosen for a family: its picture")
	ModelPacks.set_choices({})
	ModelLibrary.choices_changed([])
	check(ModelLibrary.draws_sprite("assembling-machine-2@" + ModelPacks.FACTORIO_ID) and not ModelLibrary.draws_sprite("assembling-machine-2"),
		"a building's own pack Factorio (the model chooser): its picture")
	# Placeholders moved and switched off, Factorio off: the box.
	ModelPacks.use(ModelPacks.ordered(built, [ModelPacks.FACTORIO_ID, "builtin:placeholders"] + off_others,
		[ModelPacks.FACTORIO_ID, "builtin:placeholders"] + off_others))
	ModelLibrary.choices_changed([])
	SpriteStandins.clear()
	check(not ModelPacks.factorio_on() and not ModelLibrary.draws_sprite("assembling-machine-2") and ModelLibrary.mesh_for("assembling-machine-2") == null
		and SpriteStandins.card("assembling-machine-2", 0, Vector2(3, 3), "assembling-machine") == null and not SpriteStandins.in_use()
		and not ModelPacks.fixed(_pack(ModelPacks.packs, "builtin:placeholders")),
		"Placeholders and Factorio both off: no model and no card (the box)")
	ModelPacks.use(ModelPacks.ordered(built, [], []))
	ModelLibrary.choices_changed([])


static func _pack(list: Array, id: String) -> Dictionary:
	for p: Dictionary in list:
		if p["id"] == id:
			return p
	return {}


## Packs' icons (item_icons.gd asks model_packs.gd icon_file() first): a folder pack of icons alone
## and a zip pack, the order deciding between them, a kind's own folder, "signal" read as
## "virtual-signal", a picture that isn't square cut to its middle, a pack off and a name no pack has
## falling back to the install's (or nothing without one), an "icon:" choice, the cache dropped on
## each change.
func _icons() -> void:
	ModelPacks.set_choices({})
	var dir := ProjectSettings.globalize_path("user://icon-models")
	_write(dir.path_join("Icon folder/icons/iron-plate.png"), _png(8, 8, Color.RED))
	_write(dir.path_join("Icon folder/icons/fluid/water.png"), _png(8, 8, Color.GREEN))
	_write(dir.path_join("Icon folder/icons/signal/signal-A.png"), _png(4, 4, Color.WHITE))
	_zip(dir.path_join("icon-zip.zip"), {"pack/pack.json": JSON.stringify({"name": "Zipped icons"}).to_utf8_buffer(),
		"pack/icons/iron-plate.png": _png(16, 16, Color.BLUE), "pack/icons/item/copper-plate.png": _png(16, 8, Color.YELLOW)})
	var found := ModelPacks.scan(dir)
	var folder := _pack(found, "dir:Icon folder")
	var zipped := _pack(found, "zip:icon-zip.zip")
	check(int(folder.get("icon_count", 0)) == 3 and int(folder.get("count", -1)) == 0 and zipped.get("problem", "?") == ""
		and int(zipped.get("icon_count", 0)) == 2, "a folder of icons alone and a zip of icons are packs: %s / %s" % [folder, zipped])
	check(ModelPacks.icon_names(folder) == ["fluid/water", "iron-plate", "virtual-signal/signal-a"], "its icons by name and kind: %s" % [ModelPacks.icon_names(folder)])

	var stone_before := _pixels(ItemIcons.install_texture("stone"))
	ModelPacks.configure(dir, ["zip:icon-zip.zip", "dir:Icon folder"], [])
	ModelPacks.wait()
	check(ModelPacks.is_ready() and int(_pack(ModelPacks.packs, "zip:icon-zip.zip")["icon_count"]) == 2, "the zip's icons taken in once unpacked")
	check(_colour(ItemIcons.texture_for("iron-plate")) == Color.BLUE, "the higher pack's icon (the zip's) for an item")
	check(_colour(ItemIcons.texture_for_kind("fluid", "water")) == Color.GREEN, "a kind's own icon, the only pack with one")
	check(ModelPacks.icon_file("recipe", "water") == "" and ModelPacks.icon_file("item", "water") == "", "a kind's icon isn't another kind's")
	check(_colour(ItemIcons.texture_for_kind("virtual-signal", "signal-A")) == Color.WHITE, "icons/signal/ is the virtual signals' folder, names in any case")
	var copper := ItemIcons.texture_for("copper-plate")
	check(copper != null and copper.get_width() == 8 and copper.get_height() == 8 and _colour(copper) == Color.YELLOW,
		"a picture that isn't square cut to its middle square")
	check(copper != null and copper.get_image().has_mipmaps(), "mipmapped, as the UI scales it")
	check(_pixels(ItemIcons.texture_for("stone")) == stone_before, "a name no pack has an icon for: as before")

	ModelPacks.configure(dir, ["dir:Icon folder", "zip:icon-zip.zip"], [])
	ModelPacks.wait()
	check(_colour(ItemIcons.texture_for("iron-plate")) == Color.RED, "the order turned: the folder's icon, the cache dropped")
	check(ModelPacks.icon_pack("item", "iron-plate").get("id") == "dir:Icon folder", "and its pack")
	ModelPacks.set_choices({"icon:iron-plate": "zip:icon-zip.zip"})
	check(_colour(ItemIcons.texture_for("iron-plate")) == Color.BLUE and ModelPacks.icon_choice("iron-plate") == "zip:icon-zip.zip",
		"an icon: choice takes the chosen pack's whatever the order")
	check(ModelPacks.model_choice_count() == 0 and ModelPacks.choice("iron-plate") == "", "an icon's choice is no model family's")
	ModelPacks.set_choices({})
	check(_colour(ItemIcons.texture_for("iron-plate")) == Color.RED, "the choice undone: the order's again")

	var install := _pixels(ItemIcons.install_texture("iron-plate"))
	ModelPacks.configure(dir, ["dir:Icon folder", "zip:icon-zip.zip"], ["dir:Icon folder", "zip:icon-zip.zip"])
	ModelPacks.wait()
	check(ModelPacks.icon_file("item", "iron-plate") == "" and _pixels(ItemIcons.texture_for("iron-plate")) == install,
		"both packs off: Factorio's icon from the install (none without one: %s)" % ("found" if install.size() > 0 else "no install"))
	ModelPacks.configure("", [], [])
	check(ModelPacks.icon_file("item", "iron-plate") == "", "the built-in packs carry no icons")


## Packs' sounds (sound_bank.gd locate() asks sound_file() before the install): a folder pack with its
## sounds/ one folder down, a zip of sounds alone (a pack), the loose pack's own sounds/, the order
## deciding, a pack off, packs below the Factorio pack (sound_file() "" until asked past it), a
## "sound:" choice (no model family's), sounds_on off, sounds_version moving on each change.
func _sounds() -> void:
	ModelPacks.set_choices({})
	var tone := Tones.bytes(Tones.SHORT)
	var dir := ProjectSettings.globalize_path("user://sound-models")
	const GRASS := "base/sound/walking/grass-3.ogg"
	_write(dir.path_join("Sound folder/inner/sounds/" + GRASS), tone)
	_write(dir.path_join("Sound folder/inner/sounds/core/sound/GUI-Click.ogg"), tone)
	_write(dir.path_join("Sound folder/inner/sounds/core/sound/notes.txt"), "not a sound".to_utf8_buffer())
	_write(dir.path_join("sounds/core/sound/gui-tab.ogg"), tone)
	_zip(dir.path_join("sound-zip.zip"), {"pack/pack.json": JSON.stringify({"name": "Zipped sounds"}).to_utf8_buffer(),
		"pack/sounds/" + GRASS: tone, "pack/sounds/mod-x/sound/beep.ogg": tone, "pack/sounds/stray.ogg": tone})
	var found := ModelPacks.scan(dir)
	var folder := _pack(found, "dir:Sound folder")
	var zipped := _pack(found, "zip:sound-zip.zip")
	var loose := _pack(found, ModelPacks.LOOSE_ID)
	check(int(folder.get("sound_count", 0)) == 2 and int(folder.get("count", -1)) == 0 and folder.get("problem", "?") == "",
		"a folder of sounds alone is a pack (sounds/ one folder down, .ogg only): %s" % [folder])
	check(ModelPacks.sound_names(folder) == ["base/sound/walking/grass-3.ogg", "core/sound/gui-click.ogg"], "its sounds by Factorio path, lower case: %s" % [ModelPacks.sound_names(folder)])
	check(zipped.get("problem", "?") == "" and int(zipped.get("sound_count", 0)) == 2, "a zip of sounds alone is a pack, a file outside <mod>/ not counted: %s" % [zipped])
	check(int(loose.get("sound_count", 0)) == 1 and not found.any(func(p: Dictionary) -> bool: return p["id"] == "dir:sounds"),
		"the folder's own sounds/ is the loose pack's, not a pack of its own")

	var v := ModelPacks.sounds_version
	ModelPacks.configure(dir, ["zip:sound-zip.zip", "dir:Sound folder"], [])
	ModelPacks.wait()
	check(ModelPacks.sounds_version != v, "sounds_version moved with the packs")
	check(int(_pack(ModelPacks.packs, "zip:sound-zip.zip")["sound_count"]) == 2 and ModelPacks.sound_pack(GRASS).get("id") == "zip:sound-zip.zip",
		"the zip's sounds taken in once unpacked; the higher pack's file")
	check(ModelPacks.sound_file("core/sound/gui-click.ogg").ends_with("GUI-Click.ogg"), "a file only the lower pack has, its name in any case")
	check(ModelPacks.sound_file("base/sound/walking/grass-1.ogg") == "", "a file no pack has: none (the install's)")
	ModelPacks.configure(dir, ["dir:Sound folder", "zip:sound-zip.zip"], [])
	ModelPacks.wait()
	check(ModelPacks.sound_pack(GRASS).get("id") == "dir:Sound folder", "the order turned: the folder's")
	v = ModelPacks.sounds_version
	ModelPacks.set_choices({ModelPacks.SOUND_PREFIX + GRASS: "zip:sound-zip.zip"})
	check(ModelPacks.sound_pack(GRASS).get("id") == "zip:sound-zip.zip" and ModelPacks.sound_choice(GRASS) == "zip:sound-zip.zip"
		and ModelPacks.sounds_version != v, "a sound: choice takes the chosen pack's whatever the order")
	check(ModelPacks.model_choice_count() == 0 and ModelPacks.choice(GRASS) == "", "a sound's choice is no model family's")
	v = ModelPacks.sounds_version
	ModelPacks.set_choices({})
	check(ModelPacks.sound_pack(GRASS).get("id") == "dir:Sound folder" and ModelPacks.sounds_version != v, "the choice undone: the order's again")

	v = ModelPacks.sounds_version
	ModelPacks.set_sounds_on(false)
	check(ModelPacks.sound_file(GRASS) == "" and ModelPacks.sound_file(GRASS, true) == "" and ModelPacks.sounds_version != v,
		"packs' sounds off (--pack-sounds=off, Settings): none")
	ModelPacks.set_sounds_on(true)

	ModelPacks.configure(dir, ["dir:Sound folder", "zip:sound-zip.zip"], ["dir:Sound folder"])
	ModelPacks.wait()
	check(ModelPacks.sound_pack(GRASS).get("id") == "zip:sound-zip.zip" and ModelPacks.sound_file("core/sound/gui-click.ogg") == "",
		"a pack off gives nothing: the other pack's, else none")
	ModelPacks.configure(dir, [ModelPacks.FACTORIO_ID, "dir:Sound folder", "zip:sound-zip.zip"], [])
	ModelPacks.wait()
	check(ModelPacks.sound_file(GRASS) == "" and ModelPacks.sound_file(GRASS, true).contains("Sound folder"),
		"packs below the Factorio pack: Factorio's own first, theirs only past it")
	ModelPacks.configure("", [], [])
	check(ModelPacks.sound_file(GRASS) == "" and ModelPacks.active().all(func(p: Dictionary) -> bool: return int(p["sound_count"]) == 0),
		"the built-in packs carry no sounds")


## Packs' ground textures (terrain_textures.gd asks tile_source() first): folder, zip and loose packs
## of tiles alone, subfolders, numbered variant subfolders without stripping -1 from tile names,
## aliases and pack.json "tiles" overrides (size, count, roughness, specular), template sheets,
## seamless tile repeat, order/choice/on-off switches, and live TerrainTextures reload.
func _tiles() -> void:
	ModelPacks.set_choices({})
	ModelPacks.set_tiles_on(true)
	ModelPacks.set_tile_pbr_on(true)
	var dir := ProjectSettings.globalize_path("user://tile-models")
	_write(dir.path_join("Tile folder/inner/tiles/nauvis/grass-1.png"), _png(64, 64, Color(1, 0, 0)))
	_write(dir.path_join("Tile folder/inner/tiles/nauvis/grass-1.jpg"), _png_or_jpg(64, 64, Color(0, 1, 0)))
	_write(dir.path_join("Tile folder/inner/tiles/dirt-1-normal.png"), _png(64, 64, Color(0.5, 0.5, 1.0)))
	_write(dir.path_join("Tile folder/inner/tiles/dirt-1-height.png"), _png(64, 64, Color(0.8, 0.8, 0.8)))
	_write(dir.path_join("Tile folder/inner/tiles/concrete/10.png"), _png(64, 64, Color(0.1, 0.1, 0.8)))
	_write(dir.path_join("Tile folder/inner/tiles/concrete/2.png"), _png(64, 64, Color(0.1, 0.8, 0.1)))
	_write(dir.path_join("Tile folder/inner/tiles/concrete/1.png"), _png(64, 64, Color(0.8, 0.1, 0.1)))
	_write(dir.path_join("Tile folder/inner/tiles/notes.txt"), "not a tile".to_utf8_buffer())
	_write(dir.path_join("tiles/sand-1.png"), _png(64, 64, Color(0.9, 0.8, 0.2)))
	var strip := Image.create(128, 64, false, Image.FORMAT_RGBA8)
	strip.fill_rect(Rect2i(0, 0, 64, 64), Color(0.2, 0.4, 0.8))
	strip.fill_rect(Rect2i(64, 0, 64, 64), Color(0.8, 0.4, 0.2))
	var template_img := Image.create(1024, 576, false, Image.FORMAT_RGBA8)
	template_img.fill(Color(0.3, 0.6, 0.3))
	# Template normal sheet whose 2x2 strip (y=128..255) has a 1px black Sobel gap edge along y=128.
	var template_nrm := Image.create(1024, 576, false, Image.FORMAT_RGBA8)
	template_nrm.fill(Color(0.5, 0.5, 1.0))
	template_nrm.fill_rect(Rect2i(0, 128, 1024, 1), Color(0, 0, 0, 1))
	var zip_info := {
		"name": "Zipped tiles",
		"aliases": {"my-mud": "dirt-1"},
		"tiles": {
			"*": {"roughness": 0.9},
			"grass-*": {"size": 2, "normal_flip_x": true, "normal_strength": 1.5, "height_strength": 0.75},
			"concrete": {"count": 2, "roughness": 0.65, "specular": 0.25},
		},
	}
	_zip(dir.path_join("tile-zip.zip"), {
		"pack/pack.json": JSON.stringify(zip_info).to_utf8_buffer(),
		"pack/tiles/grass-1.png": _png(128, 128, Color(0, 0, 1)),
		"pack/tiles/grass-1-normal.png": _png(128, 128, Color(0.25, 0.75, 1.0)),
		"pack/tiles/grass-1-roughness.png": _png(128, 128, Color(0.35, 0.35, 0.35)),
		"pack/tiles/my-mud.png": _png(64, 64, Color(0.5, 0.3, 0.1)),
		"pack/tiles/concrete.png": strip.save_png_to_buffer(),
		"pack/tiles/sand-2.png": template_img.save_png_to_buffer(),
		"pack/tiles/sand-2-normal.png": template_nrm.save_png_to_buffer(),
	})
	var found := ModelPacks.scan(dir)
	var folder := _pack(found, "dir:Tile folder")
	var zipped := _pack(found, "zip:tile-zip.zip")
	var loose := _pack(found, ModelPacks.LOOSE_ID)
	check(int(folder.get("tile_count", 0)) == 3 and int(folder.get("count", -1)) == 0 and folder.get("problem", "?") == "",
		"a folder of tiles and PBR maps is a pack (subfolders, multi-variant folders, and PBR-only stems counted): %s" % [folder])
	check(ModelPacks.tile_names(folder) == ["concrete", "dirt-1", "grass-1"], "tile_names includes PBR-only stems and keeps -1 suffixes intact: %s" % [ModelPacks.tile_names(folder)])
	check(ModelPacks.tile_maps_in(folder, "dirt-1").has("normal") and ModelPacks.tile_maps_in(folder, "dirt-1").has("height"),
		"tile_maps_in parses -normal and -height companion maps: %s" % [ModelPacks.tile_maps_in(folder, "dirt-1")])
	check(ModelPacks.tile_in(folder, "grass-1").size() == 1 and str(ModelPacks.tile_in(folder, "grass-1")[0]).ends_with(".png"),
		"png beats jpg for the same tile stem: %s" % [ModelPacks.tile_in(folder, "grass-1")])
	var con_files := ModelPacks.tile_in(folder, "concrete")
	check(con_files.size() == 3 and str(con_files[0]).ends_with("/1.png") and str(con_files[1]).ends_with("/2.png") and str(con_files[2]).ends_with("/10.png"),
		"numbered tile variants sorted naturally (1, 2, 10): %s" % [con_files])
	check(zipped.get("problem", "?") == "" and int(zipped.get("tile_count", 0)) == 4,
		"a zip of tiles and PBR maps is a pack: %s" % [zipped])
	check(int(loose.get("tile_count", 0)) == 1 and not found.any(func(p: Dictionary) -> bool: return p["id"] == "dir:tiles"),
		"the folder's own tiles/ is the loose pack's, not a pack of its own")

	var v := ModelPacks.tiles_version
	ModelPacks.configure(dir, ["zip:tile-zip.zip", "dir:Tile folder"], [])
	ModelPacks.wait()
	check(ModelPacks.tiles_version != v, "tiles_version moved with the packs")
	var z_live := _pack(ModelPacks.packs, "zip:tile-zip.zip")
	check(int(z_live["tile_count"]) == 4 and ModelPacks.tile_pack("grass-1").get("id") == "zip:tile-zip.zip",
		"the zip's tiles taken in once unpacked; the higher pack wins")
	check(ModelPacks.tile_file("dirt-1").ends_with("my-mud.png") and ModelPacks.tile_file("my-mud") == "",
		"pack.json aliases rename tiles too: %s" % ModelPacks.tile_file("dirt-1"))
	var spec := ModelPacks.tile_spec(z_live, "grass-1")
	check(is_equal_approx(float(spec.get("roughness", 0.0)), 0.9) and spec.get("size") == [2, 2]
		and bool(spec.get("normal_flip_x", false)) and is_equal_approx(float(spec.get("normal_strength", 0.0)), 1.5)
		and is_equal_approx(float(spec.get("height_strength", 0.0)), 0.75),
		"tile_spec merges wildcards, size, and PBR rules: %s" % [spec])

	# Load into TerrainTextures and verify packed pixels, PBR companion array, flip_x, template clamping, and live reload.
	var was_disabled := TerrainTextures.disabled
	TerrainTextures.disabled = false
	var loaded_names := ["grass-1", "concrete", "sand-2"]
	for tn in loaded_names:
		TerrainTextures.lookup(tn)
	var until := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < until:
		TerrainTextures.poll()
		if loaded_names.all(func(tn: String) -> bool: return TerrainTextures.peek(tn) != null):
			break
		OS.delay_msec(5)
	var g_grass: TerrainTextures.TileGfx = TerrainTextures.peek("grass-1")
	var g_con: TerrainTextures.TileGfx = TerrainTextures.peek("concrete")
	var g_sand: TerrainTextures.TileGfx = TerrainTextures.peek("sand-2")
	check(g_grass != null and g_grass.layer >= 0 and g_grass.material == Vector2i(2, 2) and g_grass.material_count == 1,
		"grass-1 packed as 2x2 single material: %s" % [g_grass.material if g_grass != null else Vector2i.ZERO])
	if g_grass != null and g_grass.layer >= 0:
		var px0 := _layer_pixel(TerrainTextures._images[g_grass.layer], 0, 0)
		var px_wrap := _layer_pixel(TerrainTextures._images[g_grass.layer], 128, 128)
		check(px0.b > 0.8 and px0.r < 0.2 and px_wrap.b > 0.8 and px_wrap.r < 0.2,
			"grass-1 seamless blue block repeated across layer: %s / %s" % [px0, px_wrap])
		check(is_equal_approx(g_grass.surface, TerrainTextures.surface_code(Vector2(0.9, TerrainTextures.surface_of("grass-1").y))),
			"grass-1 takes pack.json * roughness 0.9: %s" % g_grass.surface)
		var gm: Color = TerrainTextures._pbr_metas[g_grass.layer]
		var gpbr_idx := int(roundf(gm.r))
		check(TerrainTextures._pbr_array != null and gpbr_idx >= 0 and int(roundf(gm.g)) == 5
			and is_equal_approx(gm.b, 1.5) and is_equal_approx(gm.a, 0.75),
			"grass-1 companion PBR metadata uploaded with normal+roughness flags (5) and strengths: %s" % [gm])
		if gpbr_idx >= 0:
			var gppx := TerrainTextures._pbr_images[gpbr_idx].get_pixel(10, 10)
			check(gppx.r > 0.7 and gppx.g > 0.7 and absf(gppx.b - 0.35) < 0.03,
				"grass-1 PBR normal_flip_x flips R (0.25 -> ~0.75) and B stores roughness ~0.35: %s" % [gppx])
	check(g_con != null and g_con.layer >= 0 and g_con.material_count == 2 and g_con.material == Vector2i(1, 1),
		"concrete strip sliced into 2 variants: %s / %s" % [g_con.material if g_con != null else Vector2i.ZERO, g_con.material_count if g_con != null else -1])
	if g_con != null and g_con.layer >= 0:
		var c0 := _layer_pixel(TerrainTextures._images[g_con.layer], 16, 16)
		var c1 := _layer_pixel(TerrainTextures._images[g_con.layer], 64 + 16, 16)
		check(c0.b > 0.6 and c0.r < 0.4 and c1.r > 0.6 and c1.b < 0.4,
			"concrete strip variants packed into slots 0 and 1: %s / %s" % [c0, c1])
		check(is_equal_approx(g_con.surface, TerrainTextures.surface_code(Vector2(0.65, 0.25))),
			"concrete takes pack.json roughness/specular: %s" % g_con.surface)
	check(g_sand != null and g_sand.layer >= 0 and g_sand.sizes.size() >= 3,
		"sand-2 1024x576 template sheet unpacked into 4x4/2x2/1x1 variants: %s" % [g_sand.sizes if g_sand != null else []])
	if g_sand != null and g_sand.layer >= 0:
		var sm: Color = TerrainTextures._pbr_metas[g_sand.layer]
		var spbr_idx := int(roundf(sm.r))
		check(spbr_idx >= 0 and int(roundf(sm.g)) == 1, "sand-2 template normal map uploaded with flag 1: %s" % [sm])
		if spbr_idx >= 0:
			var dst2: Vector2i = TerrainTextures._slot_px(2, 0)
			var edge_px := TerrainTextures._pbr_images[spbr_idx].get_pixel(dst2.x + 8, dst2.y)
			check(edge_px.r > 0.4 and edge_px.g > 0.4,
				"sand-2 _clamp_template_slot_borders replaces 1px black Sobel spike at y=128: %s" % [edge_px])

	# Order swap triggers live TerrainTextures reload, and albedo-only pack isolates lower PBR maps.
	var layout_before := TerrainTextures.layout
	ModelPacks.configure(dir, ["dir:Tile folder", "zip:tile-zip.zip"], [])
	ModelPacks.wait()
	var grass_src := ModelPacks.tile_source("grass-1")
	check(grass_src.get("pack", {}).get("id") == "dir:Tile folder" and (grass_src.get("maps", {}) as Dictionary).is_empty(),
		"higher albedo-only pack does not mix lower pack's PBR maps: %s" % [grass_src])
	TerrainTextures.poll()
	check(TerrainTextures.layout > layout_before and TerrainTextures.peek("grass-1") == null,
		"changing tile packs reloads TerrainTextures and bumps layout")
	TerrainTextures.lookup("grass-1")
	until = Time.get_ticks_msec() + 5000
	while TerrainTextures.peek("grass-1") == null and Time.get_ticks_msec() < until:
		TerrainTextures.poll()
		OS.delay_msec(5)
	var g_red: TerrainTextures.TileGfx = TerrainTextures.peek("grass-1")
	if g_red != null and g_red.layer >= 0:
		var px_red := _layer_pixel(TerrainTextures._images[g_red.layer], 0, 0)
		check(px_red.r > 0.8 and px_red.b < 0.2, "after order swap, folder pack's red grass-1 loads: %s" % px_red)

	# PBR-only source & preview swatch, plus --pack-tile-pbr=off / set_tiles_on(false).
	ModelPacks.configure(dir, ["dir:Tile folder"], ["zip:tile-zip.zip"])
	ModelPacks.wait()
	var dirt_src := ModelPacks.tile_source("dirt-1")
	var dirt_preview := TerrainTextures.pack_preview_image([], {}, dirt_src.get("maps", {}))
	check((dirt_src.get("files", []) as Array).is_empty() and not (dirt_src.get("maps", {}) as Dictionary).is_empty()
		and dirt_preview != null and not dirt_preview.is_empty(),
		"PBR-only tile pack exposes companion maps and generates a preview swatch: %s" % [dirt_src])
	v = ModelPacks.tiles_version
	ModelPacks.set_tile_pbr_on(false)
	check(ModelPacks.tiles_version != v and ModelPacks.tile_source("dirt-1").is_empty(),
		"set_tile_pbr_on(false) leaves companion PBR maps out")
	ModelPacks.set_tile_pbr_on(true)
	ModelPacks.configure(dir, ["dir:Tile folder", "zip:tile-zip.zip"], [])
	ModelPacks.wait()

	v = ModelPacks.tiles_version
	ModelPacks.set_choices({ModelPacks.TILE_PREFIX + "grass-1": "zip:tile-zip.zip"})
	check(ModelPacks.tile_pack("grass-1").get("id") == "zip:tile-zip.zip" and ModelPacks.tile_choice("grass-1") == "zip:tile-zip.zip"
		and ModelPacks.tiles_version != v, "a tile: choice takes the chosen pack's whatever the order")
	check(ModelPacks.model_choice_count() == 0 and ModelPacks.choice("grass-1") == "", "a tile's choice is no model family's")
	v = ModelPacks.tiles_version
	ModelPacks.set_choices({})
	check(ModelPacks.tile_pack("grass-1").get("id") == "dir:Tile folder" and ModelPacks.tiles_version != v, "the choice undone: the order's again")

	v = ModelPacks.tiles_version
	ModelPacks.set_tiles_on(false)
	TerrainTextures.poll()
	check(ModelPacks.tile_file("grass-1") == "" and ModelPacks.tile_file("grass-1", true) == "" and ModelPacks.tiles_version != v
		and TerrainTextures._pbr_array == null and TerrainTextures._pbr_images.is_empty(),
		"packs' tiles off (--pack-tiles=off, Settings): none and clears PBR array")
	ModelPacks.set_tiles_on(true)

	ModelPacks.configure(dir, ["dir:Tile folder", "zip:tile-zip.zip"], ["dir:Tile folder"])
	ModelPacks.wait()
	check(ModelPacks.tile_pack("grass-1").get("id") == "zip:tile-zip.zip" and ModelPacks.tile_pack("concrete").get("id") == "zip:tile-zip.zip",
		"a pack off gives nothing: the other pack's")
	ModelPacks.configure(dir, [ModelPacks.FACTORIO_ID, "dir:Tile folder", "zip:tile-zip.zip"], [])
	ModelPacks.wait()
	if ModelPacks.factorio_usable():
		check(ModelPacks.tile_file("grass-1") == "" and ModelPacks.tile_file("grass-1", true).contains("Tile folder"),
			"packs below the Factorio pack: Factorio's own first, theirs only past it")
	ModelPacks.configure("", [], [])
	check(ModelPacks.tile_file("grass-1") == "" and ModelPacks.active().all(func(p: Dictionary) -> bool: return int(p["tile_count"]) == 0),
		"the built-in packs carry no tiles")
	TerrainTextures.disabled = was_disabled
	TerrainTextures.poll()


func _decoratives() -> void:
	ModelPacks.set_choices({})
	ModelPacks.set_decor_on(true)
	var dir := ProjectSettings.globalize_path("user://decor-models")
	# Folder pack with subfolder, -1/-2 variants, .png beating .jpg, and digit-variant folder sorted naturally.
	_write(dir.path_join("Decor folder/inner/decoratives/nauvis/green-hairy-grass-2.png"), _png(32, 32, Color(0, 0.9, 0.2)))
	_write(dir.path_join("Decor folder/inner/decoratives/nauvis/green-hairy-grass-1.png"), _png(32, 32, Color(0.1, 0.7, 0.1)))
	_write(dir.path_join("Decor folder/inner/decoratives/nauvis/green-hairy-grass-1.jpg"), _png_or_jpg(32, 32, Color(0.9, 0, 0)))
	_write(dir.path_join("Decor folder/inner/decoratives/small-rock/10.png"), _png(24, 24, Color(0.2, 0.2, 0.9)))
	_write(dir.path_join("Decor folder/inner/decoratives/small-rock/2.png"), _png(24, 24, Color(0.5, 0.5, 0.5)))
	_write(dir.path_join("Decor folder/inner/decoratives/small-rock/1.png"), _png(24, 24, Color(0.8, 0.2, 0.2)))
	_write(dir.path_join("Decor folder/inner/decoratives/notes.txt"), "not a decorative".to_utf8_buffer())
	# Loose decoratives/ in models root + hide-only pack with pack.json rules only.
	_write(dir.path_join("decoratives/red-desert-bush.png"), _png(32, 32, Color(0.9, 0.2, 0.1)))
	var hide_info := {"name": "Hide shrubs", "decoratives": {"small-rock": {"hide": true}}}
	_write(dir.path_join("HideOnly/pack.json"), JSON.stringify(hide_info).to_utf8_buffer())
	var zip_info := {
		"name": "Zipped decor",
		"aliases": {"my-fern": "brown-carpet-grass"},
		"decoratives": {
			"*": {"scale": 0.75},
			"green-hairy-grass": {"size": [1.5, 1.5], "shift": [0.1, -0.2], "layer": "decals", "grass": true, "grass_height": 0.42, "grass_style": "bush"},
			"brown-carpet-grass": {"hide": true},
		},
	}
	_zip(dir.path_join("decor-zip.zip"), {
		"pack/pack.json": JSON.stringify(zip_info).to_utf8_buffer(),
		"pack/decoratives/green-hairy-grass.png": _png(48, 48, Color(0.0, 0.2, 0.95)),
		"pack/decoratives/my-fern.png": _png(32, 32, Color(0.6, 0.4, 0.2)),
	})
	var found := ModelPacks.scan(dir)
	var folder := _pack(found, "dir:Decor folder")
	var zipped := _pack(found, "zip:decor-zip.zip")
	var hider := _pack(found, "dir:HideOnly")
	var loose := _pack(found, ModelPacks.LOOSE_ID)
	check(int(folder.get("decor_count", 0)) == 2 and int(folder.get("count", -1)) == 0 and folder.get("problem", "?") == "",
		"a folder of decoratives alone is a pack (subfolders and variants grouped): %s" % [folder])
	check(ModelPacks.decor_names(folder) == ["green-hairy-grass", "small-rock"],
		"decor_names strips -1/-2 variant suffixes and groups folders: %s" % [ModelPacks.decor_names(folder)])
	var grass_files := ModelPacks.decor_in(folder, "green-hairy-grass")
	check(grass_files.size() == 2 and str(grass_files[0]).ends_with("green-hairy-grass-1.png") and str(grass_files[1]).ends_with("green-hairy-grass-2.png"),
		"numbered decorative variants sorted and png beats jpg: %s" % [grass_files])
	var rock_files := ModelPacks.decor_in(folder, "small-rock")
	check(rock_files.size() == 3 and str(rock_files[0]).ends_with("/1.png") and str(rock_files[1]).ends_with("/2.png") and str(rock_files[2]).ends_with("/10.png"),
		"digit-folder decorative variants sorted naturally (1, 2, 10): %s" % [rock_files])
	check(zipped.get("problem", "?") == "" and int(zipped.get("decor_count", 0)) == 2,
		"a zip of decoratives alone is a pack: %s" % [zipped])
	check(hider.get("problem", "?") == "" and int(hider.get("decor_count", 0)) >= 1,
		"a pack with only pack.json decoratives hide rules counts as a pack: %s" % [hider])
	check(int(loose.get("decor_count", 0)) == 1 and not found.any(func(p: Dictionary) -> bool: return p["id"] == "dir:decoratives"),
		"the folder's own decoratives/ is the loose pack's, not a pack of its own")

	var v := ModelPacks.decor_version
	ModelPacks.configure(dir, ["zip:decor-zip.zip", "dir:Decor folder"], [])
	ModelPacks.wait()
	check(ModelPacks.decor_version != v, "decor_version moved with the packs")
	var z_live := _pack(ModelPacks.packs, "zip:decor-zip.zip")
	check(ModelPacks.decor_pack("green-hairy-grass").get("id") == "zip:decor-zip.zip"
		and ModelPacks.decor_has(z_live, "brown-carpet-grass"),
		"higher zip pack wins and exposes aliased hidden decorative: %s" % [ModelPacks.decor_names(z_live)])
	var gspec := ModelPacks.decor_spec(z_live, "green-hairy-grass")
	check(is_equal_approx(float(gspec.get("scale", 0.0)), 0.75) and gspec.get("size") == [1.5, 1.5]
		and gspec.get("shift") == [0.1, -0.2] and str(gspec.get("layer", "")) == "decals"
		and bool(gspec.get("grass", false)) and is_equal_approx(float(gspec.get("grass_height", 0.0)), 0.42)
		and str(gspec.get("grass_style", "")) == "bush",
		"decor_spec merges wildcard + exact pack.json fields: %s" % [gspec])
	var preview := Decoratives.pack_preview_image(ModelPacks.decor_in(z_live, "green-hairy-grass"))
	check(preview != null and not preview.is_empty(), "Decoratives.pack_preview_image returns swatch image")

	# Decoratives._kind_data_for loads custom pack image + raised 3D grass, and respects hide: true.
	var saved_idx := Decoratives._index.duplicate(true)
	var saved_gen := Decoratives._index_generation
	Decoratives._index = {}
	Decoratives._index_generation = -999
	Decoratives._sync_packs()
	var kd: Decoratives.KindData = Decoratives._kind_data_for("green-hairy-grass")
	check(kd != null and kd.atlas != null and kd.grass_height > 0.35 and not kd.grass_carpet and kd.sizes.size() == 1 and kd.sizes[0].is_equal_approx(Vector2(1.5, 1.5)),
		"Decoratives._kind_data_for loads pack replacement, size override, and 3D bush grass_height")
	if kd != null and kd.atlas != null:
		var cpx := kd.atlas.get_pixel(24, 24)
		check(cpx.b > 0.8 and cpx.r < 0.2, "Decoratives._kind_data_for drew the zip pack's blue decorative: %s" % [cpx])
	var hidden_kd: Decoratives.KindData = Decoratives._kind_data_for("brown-carpet-grass")
	check(hidden_kd == null, "Decoratives._kind_data_for returns null when pack.json sets hide: true")

	# Choices, disabling, Factorio barrier, and restoration.
	v = ModelPacks.decor_version
	ModelPacks.set_choices({ModelPacks.DECOR_PREFIX + "green-hairy-grass": "dir:Decor folder"})
	check(ModelPacks.decor_pack("green-hairy-grass").get("id") == "dir:Decor folder"
		and ModelPacks.decor_choice("green-hairy-grass") == "dir:Decor folder"
		and ModelPacks.decor_version != v and ModelPacks.model_choice_count() == 0,
		"decor:<name> choice overrides pack order without counting as a model family choice")
	ModelPacks.set_choices({})

	v = ModelPacks.decor_version
	ModelPacks.set_decor_on(false)
	check(ModelPacks.decor_source("green-hairy-grass").is_empty() and ModelPacks.decor_source("green-hairy-grass", true).is_empty()
		and ModelPacks.decor_version != v,
		"set_decor_on(false) disables pack decoratives and bumps decor_version")
	ModelPacks.set_decor_on(true)

	ModelPacks.configure(dir, ["dir:HideOnly", "dir:Decor folder"], ["zip:decor-zip.zip"])
	ModelPacks.wait()
	check(bool(ModelPacks.decor_source("small-rock").get("spec", {}).get("hide", false))
		and ModelPacks.decor_source("green-hairy-grass").get("pack", {}).get("id") == "dir:Decor folder",
		"hide-only pack hides targeted decorative without blocking other decoratives below")

	ModelPacks.configure(dir, [ModelPacks.FACTORIO_ID, "zip:decor-zip.zip"], ["dir:Decor folder", "dir:HideOnly"])
	ModelPacks.wait()
	if ModelPacks.factorio_usable():
		check(ModelPacks.decor_source("green-hairy-grass").is_empty()
			and ModelPacks.decor_source("green-hairy-grass", true).get("pack", {}).get("id") == "zip:decor-zip.zip",
			"packs below Factorio only supply past_factorio decoratives")

	# Built-in Placeholders 3D decorative models (.glb) + decor_models_on switch + custom image override above Placeholders.
	var was_dm := ModelPacks.decor_models_on
	ModelPacks.set_decor_models_on(true)
	ModelPacks.configure("", [], [])
	var ph := _pack(ModelPacks.active(), "builtin:placeholders")
	var ph_decor := ModelPacks.decor_names(ph)
	# (The 48 placeholder 3D decoratives were removed by the owner, 2a52be70: a pack's own still work.)
	check(ph_decor.is_empty() and ModelPacks.decor_models_in(ph, "green-hairy-grass").is_empty(),
		"builtin:placeholders ships no 3D decorative models: %d" % [ph_decor.size()])
	var all_decor_glbs_ok := true
	for dn: String in ph_decor:
		var mpaths := ModelPacks.decor_models_in(ph, dn)
		all_decor_glbs_ok = all_decor_glbs_ok and not mpaths.is_empty() and FileAccess.file_exists(str(mpaths[0]))
	check(all_decor_glbs_ok, "every built-in decorative GLB file exists on disk")
	ModelPacks.configure(dir, ["dir:Decor folder", "builtin:placeholders", ModelPacks.FACTORIO_ID], ["zip:decor-zip.zip", "dir:HideOnly"])
	ModelPacks.wait()
	var custom_wins := ModelPacks.decor_source("green-hairy-grass")
	check(custom_wins.get("pack", {}).get("id") == "dir:Decor folder"
		and (custom_wins.get("models", []) as Array).is_empty() and not (custom_wins.get("files", []) as Array).is_empty(),
		"a custom pack's 2D decoratives override Placeholders' 3D models cleanly: %s" % [custom_wins])
	ModelPacks.configure("", [], [])
	ModelPacks.set_decor_models_on(false)
	var ph_src_off := ModelPacks.decor_source("green-hairy-grass", true)
	check(ph_src_off.is_empty(), "set_decor_models_on(false) skips .glb-only decoratives so Factorio 2D fallback applies")
	ModelPacks.set_decor_models_on(was_dm)

	Decoratives._index = saved_idx
	Decoratives._index_generation = saved_gen
	ModelPacks.set_choices({})
	ModelPacks.configure("", [], [])
	Decoratives._sync_packs()
	_remove_tree(dir)


static func _png_or_jpg(w: int, h: int, colour: Color) -> PackedByteArray:
	var image := Image.create(w, h, false, Image.FORMAT_RGB8)
	image.fill(colour)
	return image.save_jpg_to_buffer()


static func _layer_pixel(img: Image, x: int, y: int) -> Color:
	var copy := img.duplicate() as Image
	if copy.is_compressed():
		copy.decompress()
	return copy.get_pixel(x, y)


static func _png(w: int, h: int, colour: Color) -> PackedByteArray:
	var image := Image.create(w, h, false, Image.FORMAT_RGBA8)
	image.fill(colour)
	return image.save_png_to_buffer()


## A texture's top-left pixel at full size, or black for none.
static func _colour(texture: Texture2D) -> Color:
	if texture == null:
		return Color.BLACK
	return texture.get_image().get_pixel(0, 0)


static func _pixels(texture: Texture2D) -> PackedByteArray:
	return texture.get_image().get_data() if texture != null else PackedByteArray()


## Item models in packs (a pack's items/ folder): Placeholders has every one the old assets/models/items/
## held; a folder pack's and a zip pack's items, apart from their entity models; the order decides, a
## pack off falls back, an "item:" choice picks one; item_models.gd reads a pack's file as it is.
func _items() -> void:
	const ItemModels := preload("res://scripts/world/item_models.gd")
	var placeholders := _pack(ModelPacks.builtin_packs(), "builtin:placeholders")
	var held: Dictionary = placeholders.get("items", {})
	var missing: Array = []
	for f in DirAccess.get_files_at(ItemModels.DIR):
		if f.get_extension() == "import" and not held.has(f.get_basename().get_basename()):
			missing.append(f)
	check(held.size() == 198 and int(placeholders["item_count"]) == 198 and missing.is_empty(),
		"Placeholders' items/ has the 198 item models the old folder had: %d, missing %s" % [held.size(), missing])
	check(not (placeholders["models"] as Dictionary).has("iron-plate") and int(placeholders["count"]) == 377
		and int(placeholders.get("decor_count", 0)) == 0
		and (placeholders["models"] as Dictionary).has("accumulator") and held.has("accumulator")
		and str(held["accumulator"]) != str(placeholders["models"]["accumulator"]),
		"its items aren't entity models (377 still; the accumulator entity and item each its own file)")
	check(ModelPacks.builtin_packs().all(func(p: Dictionary) -> bool: return p["id"] == "builtin:placeholders" or (p["items"] as Dictionary).is_empty()),
		"only Placeholders has item models built in")

	var coal := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(ItemModels.DIR + "coal.glb"))
	var chest := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path("res://assets/models/packs/wube3dp/wooden-chest.glb"))
	check(coal.size() > 100, "the fixture item model was read")
	var dir := ProjectSettings.globalize_path("user://models-items")
	_remove_tree(dir)
	_write(dir.path_join("Item folder/pack.json"), JSON.stringify({"name": "Items in a folder"}).to_utf8_buffer())
	_write(dir.path_join("Item folder/items/iron-plate.glb"), coal)
	_write(dir.path_join("Item folder/items/copper-plate.glb"), coal)
	var gltf := _triangle_gltf("data/tri.bin")
	_zip(dir.path_join("item-zip.zip"), {"pack/pack.json": JSON.stringify({"name": "Zipped items"}).to_utf8_buffer(),
		"pack/wooden-chest.glb": chest, "pack/items/iron-plate.glb": coal, "pack/items/gear.gltf": gltf[0], "pack/items/data/tri.bin": gltf[1]})
	_zip(dir.path_join("only-items.zip"), {"items/coal.glb": coal})
	_write(dir.path_join("items/stone.glb"), coal)  # the folder's own items/: the loose models' items

	var found := ModelPacks.scan(dir)
	var ids: Array = found.map(func(p: Dictionary) -> String: return p["id"])
	ids.sort()
	check(ids == ["dir:Item folder", "loose", "zip:item-zip.zip", "zip:only-items.zip"],
		"a pack of items alone is a pack; the folder's items/ is the loose models', not a pack: %s" % [ids])
	var folder := _pack(found, "dir:Item folder")
	check(int(folder["count"]) == 0 and int(folder["item_count"]) == 2 and ModelPacks.items(folder).map(func(e: Dictionary) -> String: return e["name"]) == ["copper-plate", "iron-plate"],
		"a folder pack's items, none of them counted as entity models: %s" % [ModelPacks.items(folder)])
	var zipped := _pack(found, "zip:item-zip.zip")
	check(int(zipped["count"]) == 1 and int(zipped["item_count"]) == 2 and zipped["problem"] == "",
		"a zip's items counted apart from its models before it is unpacked: %d, %d" % [zipped["count"], zipped["item_count"]])
	check((_pack(found, "loose")["items"] as Dictionary).has("stone"), "the folder's items/ holds the loose items")

	var order := ["zip:item-zip.zip", "dir:Item folder", "zip:only-items.zip", "loose"]
	ModelPacks.configure(dir, order, [])
	ModelPacks.wait()
	check(ModelPacks.is_ready(), "the item zips unpacked")
	var zip_cache := str(_pack(ModelPacks.packs, "zip:item-zip.zip")["cache"])
	check(ModelPacks.item_model_path("iron-plate") == zip_cache.path_join("pack/items/iron-plate.glb"),
		"the higher pack's item model wins: %s" % ModelPacks.item_model_path("iron-plate"))
	check(ModelPacks.item_model_path("copper-plate") == dir.path_join("Item folder/items/copper-plate.glb")
		and ModelPacks.item_model_path("coal").begins_with(str(_pack(ModelPacks.packs, "zip:only-items.zip")["cache"]))
		and ModelPacks.item_model_path("stone") == dir.path_join("items/stone.glb")
		and ModelPacks.item_model_path("advanced-circuit") == ItemModels.DIR + "advanced-circuit.glb"
		and ModelPacks.item_model_path("no-such-item") == "",
		"an item no higher pack has comes from the next, Placeholders' last; none for an item without one")
	check(ModelPacks.find("iron-plate", true) == "" and ModelPacks.find("wooden-chest", true) == zip_cache.path_join("pack/wooden-chest.glb"),
		"item models aren't entity models, and the zip's entity model still is one")
	ModelPacks.configure(dir, ["dir:Item folder", "zip:item-zip.zip", "zip:only-items.zip", "loose"], [])
	ModelPacks.wait()
	check(ModelPacks.item_model_path("iron-plate") == dir.path_join("Item folder/items/iron-plate.glb"), "the order decides: the folder above the zip")
	ModelPacks.configure(dir, order, ["zip:item-zip.zip", "dir:Item folder"])
	ModelPacks.wait()
	check(ModelPacks.item_model_path("iron-plate") == ItemModels.DIR + "iron-plate.glb", "both packs off: Placeholders' item")
	ModelPacks.configure(dir, order, [])
	ModelPacks.wait()
	ModelPacks.set_choices({"item:iron-plate": "dir:Item folder", "iron-plate": "builtin:placeholders"})
	check(ModelPacks.item_choice("iron-plate") == "dir:Item folder" and ModelPacks.item_model_path("iron-plate") == dir.path_join("Item folder/items/iron-plate.glb"),
		"an item: choice picks its pack whatever the order (an entity choice of the same name doesn't)")
	ModelPacks.set_choices({"item:gear": "builtin:placeholders"})
	check(ModelPacks.item_model_path("gear").ends_with("pack/items/gear.gltf"), "a choice of a pack without the item: the order's")
	ModelPacks.set_choices({"item:iron-plate": "builtin:placeholders"})
	check(ModelPacks.item_model_path("iron-plate") == ItemModels.DIR + "iron-plate.glb" and ModelPacks.items_in_use()["iron-plate"]["id"] == "builtin:placeholders",
		"Placeholders chosen for an item over the order")
	check(Array(ModelPacks.summary()).any(func(l: String) -> bool: return l.contains("item model(s)")) , "the log counts the item models: %s" % [ModelPacks.summary()])
	# item_models.gd: a pack's file read as it is (a .gltf without vertex colours given its material's), and
	# again when the packs change.
	ItemModels._cache.clear()
	ItemModels._paths.clear()
	var own := ItemModels.mesh_for("iron-plate")
	var gear := ItemModels.mesh_for("gear")
	check(own != null and gear != null and gear.get_surface_count() == 1 and gear.surface_get_arrays(0)[Mesh.ARRAY_COLOR] != null,
		"item models read from a pack's file, given vertex colours when they have none")
	ModelPacks.set_choices({})
	var zip_plate := ItemModels.mesh_for("iron-plate")
	check(zip_plate != null and zip_plate != own and ItemModels._paths["iron-plate"] == zip_cache.path_join("pack/items/iron-plate.glb")
		and ItemModels.mesh_for("gear") == gear, "the packs changed: only the items whose file changed are read again")
	ItemModels._cache.clear()
	ItemModels._paths.clear()
	_remove_tree(dir)


## Packs holding copies of the install's files are refused whole (pack_check.gd), against a stand-in
## install the test writes (no file of Factorio's): a copy at the install's own path (sounds/<mod>/...)
## and one under another name (found by its size, then its hash), a copy under 1 KB and a file of the
## same size with other bytes left alone; a clean pack loads once checked; new packs wait, unchanged
## ones take their kept answer without hashing, a changed one is checked again; zips and folders;
## without an install nothing is refused, with the note; Factorio and Wube3DP aren't checked.
func _copies() -> void:
	const PackCheck := preload("res://scripts/world/pack_check.gd")
	var root := ProjectSettings.globalize_path("user://copies")
	var data := root.path_join("install/data")
	var dir := root.path_join("models")
	var sound := _noise(3000, 1)
	var picture := _noise(5000, 2)
	var tiny := _noise(600, 3)
	_write(data.path_join("base/info.json"), '{"name": "base", "version": "2.1.0"}'.to_utf8_buffer())
	_write(data.path_join("base/sound/walking/grass-1.ogg"), sound)
	_write(data.path_join("base/graphics/entity/chest/chest.png"), picture)
	_write(data.path_join("base/graphics/terrain/grass-1.png"), _noise(4500, 4))
	_write(data.path_join("base/graphics/decorative/green-hairy-grass/green-hairy-grass-13.png"), _noise(4600, 5))
	_write(data.path_join("core/graphics/tiny.png"), tiny)
	var chest := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path("res://assets/models/packs/wube3dp/wooden-chest.glb"))
	# A pack with two copies (one at the install's path, one renamed), a small copy and a look-alike.
	_write(dir.path_join("Copies/zz-copied-entity.glb"), chest)
	_write(dir.path_join("Copies/sounds/base/sound/walking/grass-1.ogg"), sound)
	_write(dir.path_join("Copies/icons/zz-copied-entity.png"), picture)
	_write(dir.path_join("Copies/tiles/grass-1.png"), _noise(4500, 4))
	_write(dir.path_join("Copies/decoratives/green-hairy-grass-13.png"), _noise(4600, 5))
	_write(dir.path_join("Copies/tiny.png"), tiny)
	var other := picture.duplicate()
	other[100] = other[100] ^ 0xff
	_write(dir.path_join("Clean/textures/same-size.png"), other)
	_write(dir.path_join("Clean/zz-clean-entity.glb"), chest)
	_zip(dir.path_join("copied.zip"), {"copied/zz-zipped-entity.glb": chest, "copied/art/chest.png": picture})
	_zip(dir.path_join("clean.zip"), {"clean/zz-clean-zip-entity.glb": chest})
	PackCheck.test_install = data
	PackCheck.forget()
	var hashed := PackCheck.hashed
	var order := ["dir:Copies", "dir:Clean", "zip:copied.zip", "zip:clean.zip"]
	ModelPacks.configure(dir, order, [])
	var waiting := ["dir:Copies", "dir:Clean", "zip:copied.zip", "zip:clean.zip"].all(func(id: String) -> bool:
		return bool(_pack(ModelPacks.packs, id).get("checking", false)) and ModelPacks.pack(id).is_empty())
	check(waiting and ModelPacks._busy, "new packs wait for their check, none in use yet (as a zip being unpacked: is_ready() says no till then)")
	check(ModelPacks.find("zz-clean-entity", true) == "" and ModelPacks.summary().has(
		"[models] Clean (Clean/): being checked for copies of Factorio's files, used once it is clean"), "nothing of a pack being checked is drawn")
	ModelPacks.wait()
	var copies := _pack(ModelPacks.packs, "dir:Copies")
	check(ModelPacks.refused(copies) and copies["copies"] == ["decoratives/green-hairy-grass-13.png", "icons/zz-copied-entity.png", "sounds/base/sound/walking/grass-1.ogg", "tiles/grass-1.png"]
		and copies["problem"] == PackCheck.REFUSED,
		"the pack with copies refused: the one at the install's path and the renamed ones, not the small one: %s" % [copies.get("copies")])
	check(ModelPacks.pack("dir:Copies").is_empty() and ModelPacks.find("zz-copied-entity", true) == ""
		and ModelPacks.icon_file("item", "zz-copied-entity") == "" and ModelPacks.sound_file("base/sound/walking/grass-1.ogg") == ""
		and ModelPacks.tile_file("grass-1") == "" and ModelPacks.decor_pack("green-hairy-grass").get("id", "") != "dir:Copies",
		"nothing of a refused pack is used: no model, icon, sound, tile or decorative")
	check(PackCheck.detail(copies["copies"]).begins_with("4 of its files are copies of files from your Factorio install, for example decoratives/green-hairy-grass-13.png. ")
		and not PackCheck.detail(copies["copies"]).contains(root),
		"the card's words: the count and an example path in the pack, never the user's folder")
	# The wording the manager approved (docs/leads/mods.md, 23), whole; one copy: "a copy of a file".
	var rest := (" Factorio's graphics and sounds are Wube Software's, and Zenith doesn't load packs that pass them on, so none of this"
		+ " pack is used. Zenith already reads them from your own install. Ask the pack's author for a version without them.")
	check(PackCheck.detail(["sounds/base/sound/walking/grass-1.ogg", "b.png", "c.png"]) == "3 of its files are copies of files from your Factorio install,"
		+ " for example sounds/base/sound/walking/grass-1.ogg." + rest, "the approved detail, whole: %s" % PackCheck.detail(["sounds/base/sound/walking/grass-1.ogg", "b.png", "c.png"]))
	check(PackCheck.detail(["a.ogg"]) == "1 of its files is a copy of a file from your Factorio install, for example a.ogg." + rest,
		"one copy: \"1 of its files is a copy of a file from your Factorio install\": %s" % PackCheck.detail(["a.ogg"]))
	check(PackCheck.REFUSED == "Not loaded: this pack contains Factorio's own files" and PackCheck.CHECKING == "Checking for copies of Factorio's files…",
		"the card's title and the checking line, as approved")
	check(ModelPacks.refusal_line(copies).contains("Copies (Copies/) not loaded") and not ModelPacks.refusal_line(copies).contains(root),
		"the log's one line: %s" % ModelPacks.refusal_line(copies))
	var clean := _pack(ModelPacks.packs, "dir:Clean")
	check(not ModelPacks.refused(clean) and clean["problem"] == "" and ModelPacks.find("zz-clean-entity", true) == dir.path_join("Clean/zz-clean-entity.glb"),
		"a clean pack (a file of a copy's size, other bytes) loads once checked")
	var zipped := _pack(ModelPacks.packs, "zip:copied.zip")
	check(zipped.get("copies") == ["copied/art/chest.png"] and ModelPacks.find("zz-zipped-entity", true) == ""
		and ModelPacks.find("zz-clean-zip-entity", true).ends_with("zz-clean-zip-entity.glb"),
		"a zip with a copy refused, a clean zip used: %s" % [zipped.get("copies")])
	var listed := ModelPacks.listed(dir, order, [])
	check(ModelPacks.refused(_pack(listed, "dir:Copies")) and ModelPacks.refused(_pack(listed, "zip:copied.zip"))
		and not ModelPacks.refused(_pack(listed, "dir:Clean")), "the Model packs window's list has the refusals")
	check(ModelPacks.PackCheck.checks("builtin:placeholders") and not PackCheck.checks(ModelPacks.FACTORIO_ID) and not PackCheck.checks("builtin:wube3dp")
		and str(_pack(ModelPacks.packs, "builtin:wube3dp").get("check_stamp")) == "" and str(_pack(ModelPacks.packs, "builtin:placeholders").get("check_stamp")) != ""
		and not ModelPacks.refused(_pack(ModelPacks.packs, "builtin:fue5")) and not ModelPacks.refused(_pack(ModelPacks.packs, "builtin:placeholders")),
		"Factorio and Wube3DP not checked; FUE5 and Placeholders are, and pass")
	check(PackCheck.hashed > hashed, "the check hashed files whose size matched")
	# Unchanged: the kept answers, nothing hashed, nothing waits.
	hashed = PackCheck.hashed
	ModelPacks.configure(dir, order, [])
	# (The worker only removes the refused zip's unpacked copy: it holds the install's file.)
	var none_waits := func() -> bool: return not ModelPacks.packs.any(func(p: Dictionary) -> bool: return bool(p["checking"]))
	check(none_waits.call() and PackCheck.hashed == hashed and ModelPacks.refused(_pack(ModelPacks.packs, "dir:Copies"))
		and ModelPacks.find("zz-clean-entity", true) != "", "unchanged packs: their kept answers at once, no hashing")
	ModelPacks.wait()
	check(not DirAccess.dir_exists_absolute(str(_pack(ModelPacks.packs, "zip:copied.zip")["cache"])), "a refused zip's copy removed")
	# The kept answers survive a restart (read from user://pack-check).
	PackCheck._answers_read = false
	PackCheck._answers = {}
	ModelPacks.configure(dir, order, [])
	check(none_waits.call() and ModelPacks.refused(_pack(ModelPacks.packs, "zip:copied.zip")), "the answers kept on disk")
	# Changed: checked again (the copy taken out: now it loads).
	DirAccess.remove_absolute(dir.path_join("Copies/decoratives/green-hairy-grass-13.png"))
	DirAccess.remove_absolute(dir.path_join("Copies/icons/zz-copied-entity.png"))
	DirAccess.remove_absolute(dir.path_join("Copies/sounds/base/sound/walking/grass-1.ogg"))
	DirAccess.remove_absolute(dir.path_join("Copies/tiles/grass-1.png"))
	ModelPacks.configure(dir, order, [])
	check(bool(_pack(ModelPacks.packs, "dir:Copies").get("checking")) and not bool(_pack(ModelPacks.packs, "dir:Clean").get("checking")),
		"a changed pack is checked again, an unchanged one not")
	ModelPacks.wait()
	check(not ModelPacks.refused(_pack(ModelPacks.packs, "dir:Copies")) and ModelPacks.find("zz-copied-entity", true) != "",
		"the pack without its copies loads")
	# A pack already passed (its answer kept) that gains a copy: not drawn while it is checked again, not even
	# for a frame (configure() takes it out at once), then refused.
	_write(dir.path_join("Clean/textures/late.png"), picture)
	ModelPacks.configure(dir, order, [])
	check(bool(_pack(ModelPacks.packs, "dir:Clean").get("checking")) and ModelPacks.find("zz-clean-entity", true) == ""
		and ModelPacks.pack("dir:Clean").is_empty(), "a passed pack that gains a copy: none of it used while it is checked again")
	ModelPacks.wait()
	check(ModelPacks.refused(_pack(ModelPacks.packs, "dir:Clean")) and _pack(ModelPacks.packs, "dir:Clean").get("copies") == ["textures/late.png"]
		and ModelPacks.find("zz-clean-entity", true) == "", "then refused: %s" % [_pack(ModelPacks.packs, "dir:Clean").get("copies")])
	DirAccess.remove_absolute(dir.path_join("Clean/textures/late.png"))
	ModelPacks.configure(dir, order, [])
	ModelPacks.wait()
	# A copy in a __mod__/ folder at the install's path (the layout's second form), found by its path.
	_write(dir.path_join("Modded/__base__/graphics/entity/chest/chest.png"), picture)
	_write(dir.path_join("Modded/zz-modded-entity.glb"), chest)
	ModelPacks.configure(dir, order + ["dir:Modded"], [])
	ModelPacks.wait()
	check(_pack(ModelPacks.packs, "dir:Modded").get("copies") == ["__base__/graphics/entity/chest/chest.png"], "a __base__/ copy refused: %s"
		% [_pack(ModelPacks.packs, "dir:Modded").get("copies")])
	_remove_tree(dir.path_join("Modded"))
	ModelPacks.configure(dir, order, [])
	ModelPacks.wait()
	# No install: nothing to compare with, the packs load at once with the note.
	_write(dir.path_join("Copies/icons/zz-copied-entity.png"), picture)
	PackCheck.test_install = ""
	ModelPacks.configure(dir, order, [])
	var plain := _pack(ModelPacks.packs, "dir:Copies")
	check(none_waits.call() and not ModelPacks.refused(plain) and bool(plain["unchecked"]) and ModelPacks.find("zz-copied-entity", true) != "",
		"no install: the pack loads at once, not checked (the note)")
	ModelPacks.wait()
	check(PackCheck.UNCHECKED == "Not checked for copies of Factorio's files: no Factorio install was found.", "the note's words")
	PackCheck.test_install = null
	PackCheck.forget()
	ModelPacks.configure("", [], [])
	ModelPacks.wait()
	_remove_tree(root)


## The real built-in packs against the real install, when there is one: FUE5 and Placeholders pass.
## Prints the cost: a first run (the install's sizes listed) and an unchanged one.
func _builtin_copies() -> void:
	const PackCheck := preload("res://scripts/world/pack_check.gd")
	if PackCheck.install_dir() == "":
		print("NOTE no Factorio install: the built-in packs aren't checked against one")
		return
	PackCheck.test_install = ""
	var b0 := Time.get_ticks_usec()
	ModelPacks.configure("", [], [])  # the same start without the check, to compare
	var base := Time.get_ticks_usec() - b0
	PackCheck.test_install = null
	PackCheck.forget()
	PackCheck.hashed = 0
	PackCheck.looked_at = 0
	var t0 := Time.get_ticks_usec()
	ModelPacks.configure("", [], [])
	var t1 := Time.get_ticks_usec()
	ModelPacks.wait()
	var t2 := Time.get_ticks_usec()
	ModelPacks.configure("", [], [])
	var t3 := Time.get_ticks_usec()
	for id: String in ["builtin:fue5", "builtin:placeholders"]:
		var p := _pack(ModelPacks.packs, id)
		check(not ModelPacks.refused(p) and p["problem"] == "" and not ModelPacks.pack(id).is_empty(),
			"%s holds no copy of the install's files: %s" % [id, p.get("copies")])
	check(not ModelPacks._busy, "the second start takes the kept answers")
	print("NOTE copies check, real install: configure() %.0f ms without it; first run %.0f ms on the main thread + %.0f ms on the worker (%d files looked at, %d hashed); unchanged %.0f ms"
		% [base / 1000.0, (t1 - t0) / 1000.0, (t2 - t1) / 1000.0, PackCheck.looked_at, PackCheck.hashed, (t3 - t2) / 1000.0])
	# A pack holding a real file of the install (read from it now, written only into this test's own user folder
	# and removed after): a step sound at its Factorio path, and a picture renamed. Refused, nothing of it used.
	var data := PackCheck.install_dir()
	var real_sound := FileAccess.get_file_as_bytes(data.path_join("base/sound/walking/grass-1.ogg"))
	var real_icon := FileAccess.get_file_as_bytes(data.path_join("base/graphics/icons/iron-chest.png"))
	if real_sound.size() > 1024 and real_icon.size() > 1024:
		var dir := ProjectSettings.globalize_path("user://real-copies")
		_write(dir.path_join("Real/zz-real-entity.glb"), FileAccess.get_file_as_bytes(ProjectSettings.globalize_path("res://assets/models/packs/wube3dp/wooden-chest.glb")))
		_write(dir.path_join("Real/sounds/base/sound/walking/grass-1.ogg"), real_sound)
		_write(dir.path_join("Real/textures/my-chest.png"), real_icon)
		var r0 := Time.get_ticks_usec()
		ModelPacks.configure(dir, ["dir:Real"], [])
		check(ModelPacks.find("zz-real-entity", true) == "", "a pack with the install's real files: not drawn while checked")
		ModelPacks.wait()
		var real := _pack(ModelPacks.packs, "dir:Real")
		check(ModelPacks.refused(real) and real.get("copies") == ["sounds/base/sound/walking/grass-1.ogg", "textures/my-chest.png"]
			and ModelPacks.find("zz-real-entity", true) == "" and ModelPacks.sound_file("base/sound/walking/grass-1.ogg") == "",
			"the install's real step sound and a renamed real icon: refused whole: %s" % [real.get("copies")])
		print("NOTE real copies: a new pack of 3 files checked in %.0f ms" % ((Time.get_ticks_usec() - r0) / 1000.0))
		_remove_tree(dir)
		ModelPacks.configure("", [], [])
		ModelPacks.wait()


## Bytes that are nobody's: a test file of `size`, from `seed`.
static func _noise(size: int, seed_value: int) -> PackedByteArray:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var out := PackedByteArray()
	out.resize(size)
	for i in size:
		out[i] = rng.randi() & 0xff
	return out


## A modeller's item model with a base-colour picture and no vertex colours (Vasillo's plates): read
## with its picture, drawn by a material of its own shared by every instance (item_cards.gd's MultiMeshes,
## belt_lanes.gd's far ones, the preview's); Placeholders' items unchanged; --item-pictures=off.
func _item_pictures() -> void:
	const ItemModels := preload("res://scripts/world/item_models.gd")
	const ItemCards := preload("res://scripts/world/item_cards.gd")
	var BeltLanes: GDScript = load("res://scripts/world/belt_lanes.gd")  # its autoloads known by now
	const ProtoDB := preload("res://scripts/world/protos.gd")
	var dir := ProjectSettings.globalize_path("user://models-pictures")
	_remove_tree(dir)
	_write(dir.path_join("Pictured/items/pictured-plate.glb"), _pictured_glb())
	ModelPacks.configure(dir, ["dir:Pictured"], [])
	ModelPacks.wait()
	ModelPacks.set_choices({})
	ItemModels._cache.clear()
	ItemModels._paths.clear()
	check(ModelPacks.item_model_path("pictured-plate") == dir.path_join("Pictured/items/pictured-plate.glb"), "the pictured item is the pack's")
	var mesh := ItemModels.mesh_for("pictured-plate")
	var tex := ItemModels.picture(mesh)
	check(mesh != null and mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR] != null and tex != null
		and tex.get_image().get_pixel(0, 0).is_equal_approx(Color(1, 0, 0)),
		"a modeller's item with a base-colour picture is read with it (and its material's colour as vertex colours)")
	var own := ItemModels.material_for(mesh)
	check(own != ItemModels.material() and own.get_shader_parameter("picture") == tex and own.get_shader_parameter("use_picture") == true
		and is_equal_approx(float(own.get_shader_parameter("exposure")), 1.0) and ItemModels.material_for(mesh) == own,
		"its material is its own, with its picture, one for the model")
	var plain := ItemModels.mesh_for("copper-plate")
	check(plain != null and ItemModels.picture(plain) == null and ItemModels.material_for(plain) == ItemModels.material()
		and ItemModels.material().get_shader_parameter("use_picture") != true
		and ItemModels.material().get_shader_parameter("picture") == null,
		"Placeholders' items (vertex colours, no picture) keep the one shared material")
	# Items on belts near, on the ground and in hands (item_cards.gd): each kind's MultiMesh.
	var protos := ProtoDB.new()
	protos.item_names = {1: "pictured-plate", 2: "copper-plate"}
	var mats: Array = []
	for n in 2:
		var cards := ItemCards.new()
		cards.protos = protos
		root.add_child(cards)
		cards.prepare(1)
		cards.prepare(2)
		var pictured: MultiMeshInstance3D = cards._kinds[1]
		var built_in: MultiMeshInstance3D = cards._kinds[2]
		check(pictured.multimesh.mesh == mesh and pictured.material_override == own
			and built_in.material_override == ItemModels.material(),
			"item cards %d: the pictured item's MultiMesh has its material and picture, the built-in item the shared one" % n)
		mats.append(pictured.material_override)
		cards.free()
	check(mats[0] == mats[1], "one material for the model, shared by every MultiMesh drawing it")
	# Far items on belts (belt_lanes.gd): their own lane material, with the picture.
	var lanes: Node3D = BeltLanes.new()
	var far: ShaderMaterial = lanes.call("_model_material", 1, mesh)
	var far_plain: ShaderMaterial = lanes.call("_model_material", 2, plain)
	check(far.get_shader_parameter("picture") == tex and far.get_shader_parameter("use_picture") == true
		and far_plain.get_shader_parameter("picture") == null and is_equal_approx(float(far_plain.get_shader_parameter("exposure")), ItemModels.EXPOSURE),
		"far items on belts: the pictured model's lane material has its picture, a built-in one's none")
	lanes.free()
	var standard := ItemModels.plain_material(mesh)
	check(standard.albedo_texture == tex and standard.vertex_color_use_as_albedo and ItemModels.plain_material(plain).albedo_texture == null,
		"the preview's material has the picture too")
	# --item-pictures=off: the old way, its colours alone.
	ItemModels.pictures = false
	ItemModels._cache.clear()
	ItemModels._paths.clear()
	var off := ItemModels.mesh_for("pictured-plate")
	check(off != null and ItemModels.picture(off) == null and ItemModels.material_for(off) == ItemModels.material(),
		"--item-pictures=off: the picture left out, the shared material")
	ItemModels.pictures = true
	ItemModels._cache.clear()
	ItemModels._paths.clear()
	ModelPacks.configure("", [], [])
	_remove_tree(dir)


## 0.2.2: pack.json's "shading" (model_packs.gd shading()): "pbr" draws a pack's textured models and
## pictured items as their files say; "factorio", none or another word keeps Factorio's balance; Zenith's
## own packs are always "factorio". A pbr pack's pictured item takes the lit path (item_pbr.gdshaderinc)
## near, far on belts and in the preview; the Model packs window's card says the pack's shading.
func _pack_shading() -> void:
	const ItemModels := preload("res://scripts/world/item_models.gd")
	const Looks := preload("res://scripts/world/looks.gd")
	const Settings := preload("res://scripts/menu/settings.gd")
	var BeltLanes: GDScript = load("res://scripts/world/belt_lanes.gd")
	var Window: GDScript = load("res://scripts/menu/model_packs_window.gd")
	var dir := ProjectSettings.globalize_path("user://models-shading")
	_remove_tree(dir)
	var infos := {"Pbr": "{\"name\": \"Pbr\", \"shading\": \"pbr\"}", "Fact": "{\"name\": \"Fact\", \"shading\": \"factorio\"}",
		"Odd": "{\"name\": \"Odd\", \"shading\": \"glossy\"}", "None": ""}
	for name: String in infos:
		_write(dir.path_join(name + "/stone-furnace.glb"), _pictured_glb())
		_write(dir.path_join(name + "/items/pictured-plate.glb"), _pictured_glb())
		if str(infos[name]) != "":
			_write(dir.path_join(name + "/pack.json"), str(infos[name]).to_utf8_buffer())
	ModelPacks.configure(dir, ["dir:Pbr", "dir:Fact", "dir:Odd", "dir:None"], [])
	ModelPacks.wait()
	var got := {}
	for name: String in infos:
		got[name] = ModelPacks.shading(ModelPacks.pack("dir:" + name))
	check(got == {"Pbr": "pbr", "Fact": "factorio", "Odd": "factorio", "None": "factorio"},
		"pack shading: pack.json's \"pbr\" read, \"factorio\", another word and none are Factorio's: %s" % [got])
	check(ModelPacks.pbr(dir.path_join("Pbr/stone-furnace.glb")) and ModelPacks.pbr(dir.path_join("Pbr/items/pictured-plate.glb"))
		and not ModelPacks.pbr(dir.path_join("Fact/stone-furnace.glb")) and not ModelPacks.pbr(dir.path_join("None/stone-furnace.glb")),
		"pack shading: a model's and an item's file are pbr only in the pbr pack")
	var builtin_shading := {}
	for p: Dictionary in ModelPacks.builtin_packs():
		builtin_shading[str(p.get("id", ""))] = ModelPacks.shading(p)
	var fue5_pack := ModelPacks.pack(ModelPacks.FUE5_ID)
	var saved_fue5_pbr := ModelPacks.fue5_pbr
	ModelPacks.fue5_pbr = false
	var fue5_off := ModelPacks.shading(fue5_pack)
	var fue5_pbr_off_model := ModelPacks.pbr("res://assets/models/packs/fue5/wooden-chest.glb")
	ModelPacks.fue5_pbr = saved_fue5_pbr
	var wube_pack := ModelPacks.pack(ModelPacks.WUBE3DP_ID)
	var saved_wube_pbr := ModelPacks.wube3dp_pbr
	ModelPacks.wube3dp_pbr = false
	var wube_off := ModelPacks.shading(wube_pack)
	var wube_pbr_off_model := ModelPacks.pbr("res://assets/models/packs/wube3dp/wooden-chest.glb")
	ModelPacks.wube3dp_pbr = saved_wube_pbr
	var ph_pack := ModelPacks.pack(ModelPacks.LAST_ID)
	var saved_ph_pbr := ModelPacks.placeholder_pbr
	ModelPacks.placeholder_pbr = false
	var ph_off := ModelPacks.shading(ph_pack)
	ModelPacks.placeholder_pbr = saved_ph_pbr
	var factorio_forged := ModelPacks.pack(ModelPacks.FACTORIO_ID).duplicate() as Dictionary
	var forged_info := (factorio_forged["info"] as Dictionary).duplicate() as Dictionary
	forged_info["shading"] = "pbr"
	factorio_forged["info"] = forged_info
	check(builtin_shading.get("builtin:fue5") == ("pbr" if saved_fue5_pbr else "factorio")
		and fue5_off == "factorio" and not fue5_pbr_off_model
		and ModelPacks.pbr("res://assets/models/packs/fue5/wooden-chest.glb") == saved_fue5_pbr
		and builtin_shading.get("builtin:wube3dp") == ("pbr" if saved_wube_pbr else "factorio")
		and wube_off == "factorio" and not wube_pbr_off_model
		and builtin_shading.get(ModelPacks.FACTORIO_ID) == "factorio"
		and builtin_shading.get(ModelPacks.LAST_ID) == ("pbr" if saved_ph_pbr else "factorio")
		and ph_off == "factorio"
		and ModelPacks.shading(factorio_forged) == "factorio" and ModelPacks.shading({}) == "factorio",
		"pack shading: built-in packs (Factorio factorio, FUE5/Wube3DP/Placeholders pbr unless --*-pbr=off): %s" % [builtin_shading])
	const WUBE_DIR := "res://assets/models/packs/wube3dp/"
	check(ModelPacks.pbr(WUBE_DIR + "wooden-chest.glb") == saved_wube_pbr
		and ModelPacks.pbr(WUBE_DIR + "assembling-machine-1.glb") == saved_wube_pbr
		and ModelPacks.pbr(WUBE_DIR + "inserter-arm-basic-upper.glb") == saved_wube_pbr
		and not ModelPacks.pbr(WUBE_DIR + "big-biter.glb")
		and not ModelPacks.pbr(WUBE_DIR + "character.glb")
		and not ModelPacks.pbr(WUBE_DIR + "transport-belt.glb")
		and not ModelPacks.pbr(WUBE_DIR + "underground-belt-input.glb"),
		"pack shading: Wube3DP's per-model PBR rules separate baked models from rigged creatures/character and belts")
	const PH_DIR := "res://assets/models/packs/placeholders/"
	check(ModelPacks.pbr(PH_DIR + "assembling-machine-2.glb") == saved_ph_pbr
		and not ModelPacks.pbr(PH_DIR + "burner-mining-drill.glb")
		and not ModelPacks.pbr(PH_DIR + "burner-mining-drill-east.glb")
		and not ModelPacks.pbr(PH_DIR + "character-mech-armor.glb")
		and ModelPacks.pbr(PH_DIR + "items/pipe.glb") == saved_ph_pbr
		and not ModelPacks.pbr(PH_DIR + "items/iron-plate.glb")
		and ModelPacks.pbr(PH_DIR + "items/tungsten-plate.glb") == saved_ph_pbr,
		"pack shading: Placeholders' per-model PBR rules separate baked models from Zenith/rigged and items/")
	var saved_packs_ov := ModelPacks.pbr_packs.duplicate()
	var saved_models_ov := ModelPacks.pbr_models.duplicate()
	ModelPacks.set_pbr_overrides({ModelPacks.WUBE3DP_ID: true, ModelPacks.LAST_ID: true}, {})
	check(not ModelPacks.pbr(WUBE_DIR + "big-biter.glb")
		and not ModelPacks.pbr(WUBE_DIR + "biter-spawner.glb")
		and not ModelPacks.pbr(PH_DIR + "big-worm-turret.glb")
		and not ModelPacks.pbr(PH_DIR + "items/iron-plate.glb")
		and ModelPacks.pbr(WUBE_DIR + "wooden-chest.glb") == saved_wube_pbr
		and ModelPacks.pbr(PH_DIR + "assembling-machine-2.glb") == saved_ph_pbr
		and ModelPacks.pack_pbr_state(wube_pack) == ("mixed" if saved_wube_pbr else "off")
		and ModelPacks.pack_pbr_state(ph_pack) == ("mixed" if saved_ph_pbr else "off"),
		"pack shading: pack-level PBR ON keeps pack.json shading_models Factorio exclusions for untextured creatures and items")
	ModelPacks.set_pbr_overrides({ModelPacks.WUBE3DP_ID: false}, {})
	check(not ModelPacks.pbr(WUBE_DIR + "wooden-chest.glb") and ModelPacks.pack_pbr_state(wube_pack) == "off",
		"pack shading: pack-level PBR OFF disables PBR across the pack")
	ModelPacks.set_pbr_overrides(saved_packs_ov, saved_models_ov)
	# Items: the pbr pack's pictured plate takes the lit path; the others' the picture alone.
	var pbr_mesh := ItemModels.read(dir.path_join("Pbr/items/pictured-plate.glb"))
	var fact_mesh := ItemModels.read(dir.path_join("Fact/items/pictured-plate.glb"))
	var near := ItemModels.material_for(pbr_mesh)
	var near_fact := ItemModels.material_for(fact_mesh)
	check(ItemModels.pbr_material(pbr_mesh) != null and near.get_shader_parameter("pbr") == true
		and near.get_shader_parameter("use_picture") == true and ItemModels.pbr_material(fact_mesh) == null
		and near_fact.get_shader_parameter("pbr") != true,
		"pack shading: a pbr pack's pictured item is drawn lit (item.gdshader pbr), a factorio pack's as before")
	var lanes: Node3D = BeltLanes.new()
	var far: ShaderMaterial = lanes.call("_model_material", 1, pbr_mesh)
	var far_fact: ShaderMaterial = lanes.call("_model_material", 2, fact_mesh)
	check(far.get_shader_parameter("pbr") == true and far_fact.get_shader_parameter("pbr") != true,
		"pack shading: far items on belts the same (belt_lane_model.gdshader)")
	lanes.free()
	var was = Settings.get_value("graphics", "pack_shading")
	Settings.set_value("graphics", "pack_shading", "pack")
	var preview := ItemModels.plain_material(pbr_mesh)
	var preview_fact := ItemModels.plain_material(fact_mesh)
	Settings.set_value("graphics", "pack_shading", "factorio")
	var preview_off := ItemModels.plain_material(pbr_mesh)
	Settings.set_value("graphics", "pack_shading", was)
	check(not preview.vertex_color_use_as_albedo and preview.albedo_texture != null and preview != ItemModels.pbr_material(pbr_mesh)
		and preview_fact.vertex_color_use_as_albedo and preview_off.vertex_color_use_as_albedo,
		"pack shading: the preview draws a pbr pack's item by its file's own material, others (and with it off) as before")
	for src in ["res://shaders/item_body.gdshaderinc", "res://shaders/belt_lane_model.gdshaderinc"]:
		var text := FileAccess.get_file_as_string(src)
		check(text.contains("#include \"res://shaders/item_pbr.gdshaderinc\"") and text.contains("if (item_pbr_on()) {"),
			"pack shading: %s has the lit path" % src.get_file())
	var lines := {}
	for name: String in infos:
		lines[name] = Window.call("shading_line", ModelPacks.pack("dir:" + name))
	check(str(lines["Pbr"]).begins_with("Shading: as its files say") and str(lines["Fact"]) == "Shading: Factorio's"
		and str(lines["None"]) == "Shading: Factorio's" and str(Window.call("shading_line", ModelPacks.pack(ModelPacks.FACTORIO_ID))) == "",
		"pack shading: the Model packs window's card line says each pack's: %s" % [lines])
	check(Looks.pack_shading(PackedStringArray(["--pack-shading=factorio"])) == false, "pack shading: the switch read")
	_test_shading_models(dir)


## Items already drawn follow a change of the packs (the owner's copper plates stayed Placeholders' slabs
## while his iron plates, dropped later, showed his model): an item kind made under the built-in packs is
## made again with a pack's model put on top: on the ground, near belts and in hands (item_cards.gd) and
## far belts (belt_lanes.gd); `--item-kinds-follow=off` keeps the old kind.
func _item_kinds_follow() -> void:
	const ItemModels := preload("res://scripts/world/item_models.gd")
	const ItemCards := preload("res://scripts/world/item_cards.gd")
	var BeltLanes: GDScript = load("res://scripts/world/belt_lanes.gd")
	const ProtoDB := preload("res://scripts/world/protos.gd")
	var coal := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(ItemModels.DIR + "coal.glb"))
	var dir := ProjectSettings.globalize_path("user://models-kinds")
	_remove_tree(dir)
	_write(dir.path_join("Plates/items/copper-plate.glb"), coal)  # a copper plate shaped as coal
	# The kinds made again at once: a pack's file read here (--item-models-later=off). With the reads on
	# workers (the default) the kind waits a frame or two for its model: checked at the end.
	var saved_later := ItemModels.later
	ItemModels.later = false
	ModelPacks.set_choices({})
	ModelPacks.configure(dir, ["dir:Plates"], ["dir:Plates"])  # A: the pack off, Placeholders' plate
	ModelPacks.wait()
	ItemModels._cache.clear()
	ItemModels._paths.clear()
	var builtin_size := ItemModels.read(ItemModels.DIR + "copper-plate.glb").get_aabb().size
	var pack_mesh := ItemModels.read(dir.path_join("Plates/items/copper-plate.glb"))
	var pack_size := pack_mesh.get_aabb().size
	var far_pack_size := ItemModels.lod_mesh(pack_mesh).get_aabb().size
	check(not builtin_size.is_equal_approx(pack_size), "the fixture plate's shape differs from Placeholders' (%s, %s)" % [builtin_size, pack_size])
	var protos := ProtoDB.new()
	protos.item_names = {1: "copper-plate"}
	var cards := ItemCards.new()
	cards.protos = protos
	root.add_child(cards)
	var lanes: Node3D = BeltLanes.new()
	lanes.set("protos", protos)
	lanes.set("sync", true)
	lanes.set("focus", Vector2(100.0, 40.0))
	lanes.call("_follow_models")
	var at := {1: [Vector3.ZERO]}
	var lane_msg := {"t": "bfar", "cx": 3, "cy": 1, "l": [100 * 256, 40 * 256, 4, 1, 0]}
	var kind_size := func() -> Vector3:
		var mmi: MultiMeshInstance3D = cards._kinds.get(1)
		return mmi.multimesh.mesh.get_aabb().size if mmi != null and mmi.multimesh.mesh != null else Vector3.ZERO
	var far_size := func() -> Vector3:
		var chunk: Node3D = (lanes.get("_chunks") as Dictionary).get(Vector2i(3, 1))
		if chunk == null or chunk.get_child_count() == 0:
			return Vector3.ZERO
		var mesh := (chunk.get_child(0) as MultiMeshInstance3D).multimesh.mesh
		return mesh.get_aabb().size if mesh != null else Vector3.ZERO
	cards.draw(at)
	lanes.call("handle", lane_msg)
	var a_near: Vector3 = kind_size.call()
	var a_far: Vector3 = far_size.call()
	check(a_near.is_equal_approx(builtin_size) and a_far.is_equal_approx(builtin_size),
		"A: copper plates drawn under the built-in packs are Placeholders' (near %s, far %s)" % [a_near, a_far])
	# B: the pack turned on, above Placeholders; drawn again.
	var epoch := cards.epoch
	ModelPacks.configure(dir, ["dir:Plates"], [])
	ModelPacks.wait()
	cards.draw(at)
	lanes.call("_follow_models")
	var b_near: Vector3 = kind_size.call()
	var b_far: Vector3 = far_size.call()
	check(b_near.is_equal_approx(pack_size) and cards.epoch != epoch,
		"B: ground, near belt and hand items made again with the pack's plate on top (%s, want %s)" % [b_near, pack_size])
	check(b_far.is_equal_approx(far_pack_size) and not b_far.is_equal_approx(builtin_size),
		"B: far belt lanes made again with the pack's plate (%s, want %s)" % [b_far, far_pack_size])
	epoch = cards.epoch
	cards.draw(at)
	lanes.call("_follow_models")
	check(cards.epoch == epoch, "nothing changed: the kinds are kept (no remaking every frame)")
	# A choice of a pack for the item is a change too.
	ModelPacks.set_choices({"item:copper-plate": "builtin:placeholders"})
	cards.draw(at)
	lanes.call("_follow_models")
	check((kind_size.call() as Vector3).is_equal_approx(builtin_size) and (far_size.call() as Vector3).is_equal_approx(builtin_size),
		"a choice of Placeholders for the item: its kinds made again with Placeholders' plate")
	# --item-kinds-follow=off: the old way, the kind kept until a restart.
	ItemModels.kinds_follow = false
	ModelPacks.set_choices({})
	cards.draw(at)
	lanes.call("_follow_models")
	check((kind_size.call() as Vector3).is_equal_approx(builtin_size) and (far_size.call() as Vector3).is_equal_approx(builtin_size),
		"--item-kinds-follow=off: items already drawn keep their model")
	ItemModels.kinds_follow = true
	# Read on a worker (the default): not ready at once, then the pack's plate once its read is in.
	ItemModels.later = true
	ModelPacks.configure(dir, ["dir:Plates"], ["dir:Plates"])
	ModelPacks.wait()
	ItemModels.ready("copper-plate")
	ModelPacks.configure(dir, ["dir:Plates"], [])
	ModelPacks.wait()
	var first := ItemModels.ready("copper-plate")
	var waited := 0
	while not ItemModels.ready("copper-plate") and waited < 5000:
		RenderingServer.force_sync()  # (the worker's mesh calls wait for the main thread's frame)
		OS.delay_msec(5)
		waited += 5
	var later_mesh := ItemModels.mesh_for("copper-plate")
	check(not first and later_mesh != null and later_mesh.get_aabb().size.is_equal_approx(pack_size) and waited < 5000,
		"read on a worker: the pack's plate in once read (%s, want %s, %d ms)" % [later_mesh.get_aabb().size if later_mesh != null else Vector3.ZERO, pack_size, waited])
	# Quit with a read still on a worker (main.gd's _exit_tree): waited for, not hung on.
	ItemModels._cache.clear()
	ItemModels._paths.clear()
	ItemModels._all_ready.clear()
	var queued := not ItemModels.ready("copper-plate") and not ItemModels._jobs.is_empty()
	var tq := Time.get_ticks_msec()
	ItemModels.wait_all()
	check(queued and ItemModels._jobs.is_empty() and ItemModels._orphans.is_empty() and Time.get_ticks_msec() - tq < 10000,
		"wait_all: a read on a worker waited for at quit (%s, %d ms)" % [queued, Time.get_ticks_msec() - tq])
	ItemModels.later = saved_later
	cards.free()
	lanes.free()
	ItemModels._cache.clear()
	ItemModels._paths.clear()
	ModelPacks.configure("", [], [])
	_remove_tree(dir)


## A pack with only an ore's numbered rocks (iron-ore-1..3, as Vasillo's) provides that ore: listed for
## it, drawing it when first in the order and not when Placeholders is, and when chosen for it.
func _numbered_ores() -> void:
	var rock := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path("res://assets/models/packs/placeholders/big-rock.glb"))
	if rock.is_empty():
		rock = FileAccess.get_file_as_bytes(ProjectSettings.globalize_path("res://assets/models/packs/placeholders/copper-ore-rich.glb"))
	check(rock.size() > 100, "the fixture rock model was read")
	var dir := ProjectSettings.globalize_path("user://models-ores")
	_remove_tree(dir)
	for i in [1, 2, 3]:
		_write(dir.path_join("Rocks/iron-ore-%d.glb" % i), rock)
	var placeholders := "builtin:placeholders"
	ModelPacks.configure(dir, ["dir:Rocks", placeholders], [])
	ModelPacks.wait()
	ModelPacks.set_choices({})
	ModelLibrary.choices_changed([])
	var rocks := ModelPacks.pack("dir:Rocks")
	check(not rocks.is_empty() and ModelPacks.provides(rocks, "iron-ore") and ModelPacks.provides_in("dir:Rocks", "IRON-ORE")
		and not ModelPacks.provides(rocks, "copper-ore") and not ModelPacks.provides(rocks, "iron-ore-4")
		and ModelPacks.provides(ModelPacks.pack(placeholders), "iron-ore"),
		"a pack of iron-ore-1..3 provides iron-ore (not copper ore); Placeholders does too: %s" % [ModelPacks.active().map(func(p: Dictionary) -> String: return str(p["id"]))])
	var found := ModelLibrary.ore_scatter_names("iron-ore")
	check(str((found[0] as Dictionary).get("id", "")) == "dir:Rocks" and (found[1] as Array).size() == 3,
		"first in the order, it draws iron ore, scattered as its 3 rocks: %s" % [found[1]])
	ModelPacks.configure(dir, [placeholders, "dir:Rocks"], [])
	ModelPacks.wait()
	found = ModelLibrary.ore_scatter_names("iron-ore")
	check(str((found[0] as Dictionary).get("id", "")) == placeholders, "Placeholders above it: Placeholders' ore: %s" % found[0].get("id", ""))
	ModelPacks.set_choices({"iron-ore": "dir:Rocks"})
	found = ModelLibrary.ore_scatter_names("iron-ore")
	check(ModelPacks.choice("iron-ore-2") == "dir:Rocks" and str((found[0] as Dictionary).get("id", "")) == "dir:Rocks"
		and (found[1] as Array).size() == 3, "chosen for iron ore whatever the order: its rocks scattered")
	ModelPacks.set_choices({})
	ModelPacks.configure("", [], [])
	ModelLibrary.choices_changed([])
	_remove_tree(dir)


## The one variant rule (ModelPacks.variant_base, variants_in): `<name>-<n>` and `<name>` are variants of
## `<name>` for entity models, item models and icons; numbered prototypes (assembling-machine-2) aren't;
## a placed entity's pick is stable and spreads over them; pack.json "aliases"; ores as they were.
func _variants() -> void:
	const ItemModels := preload("res://scripts/world/item_models.gd")
	var rock := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path("res://assets/models/packs/placeholders/big-rock.glb"))
	var coal := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(ItemModels.DIR + "coal.glb"))
	check(rock.size() > 100 and coal.size() > 100, "the fixture models were read")
	var dir := ProjectSettings.globalize_path("user://models-variants")
	_remove_tree(dir)
	_write(dir.path_join("Vars/rock-big.glb"), rock)
	for i in [1, 2, 3]:
		_write(dir.path_join("Vars/rock-big-%d.glb" % i), rock)
		_write(dir.path_join("Vars/sulfur-%d.glb" % i), rock)
		_write(dir.path_join("Vars/coal-ore-%d.glb" % i), rock)
		_write(dir.path_join("Vars/items/sulfur-%d.glb" % i), coal)
	_write(dir.path_join("Vars/assembling-machine-2.glb"), rock)
	_write(dir.path_join("Vars/assembling-machine-3.glb"), rock)
	_write(dir.path_join("Vars/icons/item/coal-1.png"), _png(8, 8, Color.RED))
	_write(dir.path_join("Vars/icons/item/coal-2.png"), _png(8, 8, Color.GREEN))
	_write(dir.path_join("Vars/icons/item/coal-3.png"), _png(8, 8, Color.BLUE))
	_write(dir.path_join("Vars/pack.json"), JSON.stringify({"name": "Variants", "aliases": {"coal-ore": "coal"}}).to_utf8_buffer())
	ModelPacks.configure(dir, ["dir:Vars", "builtin:placeholders"], [])
	ModelPacks.wait()
	ModelPacks.set_choices({})
	ModelLibrary.choices_changed([])
	var p := ModelPacks.pack("dir:Vars")
	check(not p.is_empty(), "the variants pack is in use")
	if p.is_empty():
		return

	# The window's one entry per family (families_of, as the Model packs window lists them).
	var fams := ModelPacks.families_of(p)
	var keys := fams.keys()
	keys.sort()
	check(keys == ["assembling-machine-2", "assembling-machine-3", "coal", "rock-big", "sulfur"]
		and (fams["rock-big"] as Array).size() == 4 and (fams["sulfur"] as Array).size() == 3,
		"x-1..3 shown with x (sulfur-1..3 with no plain one too); numbered prototypes kept apart: %s" % [fams])
	check(ModelPacks.family("speed-module-3") == "speed-module-3" and ModelPacks.family("tree-04") == "tree-04"
		and ModelPacks.family("uranium-235") == "uranium-235" and ModelPacks.family("rock-big-12") == "rock-big",
		"prototypes ending in a number are no variants; any number is one")
	check(ModelPacks.provides(p, "sulfur") and ModelPacks.provides(p, "rock-big") and not ModelPacks.provides(p, "assembling-machine")
		and ModelPacks.variants_in(p["models"], "rock-big") == ["rock-big", "rock-big-1", "rock-big-2", "rock-big-3"],
		"a pack provides a name by its numbered variants alone; its variants in order")

	# The alias: the pack's coal-ore-1..3 are coal-1..3, and coal's scattered rocks.
	check((p["models"] as Dictionary).has("coal-2") and not (p["models"] as Dictionary).has("coal-ore-2")
		and ModelPacks.alias_name("coal-ore-rich", {"coal-ore": "coal"}) == "coal-rich"
		and ModelPacks.alias_name("item/coal-ore-1", {"coal-ore": "coal"}) == "item/coal-1"
		and ModelPacks.alias_name("coal-orence", {"coal-ore": "coal"}) == "coal-orence",
		"pack.json aliases name its files for Factorio's: %s" % [(p["models"] as Dictionary).keys()])
	var ore := ModelLibrary.ore_scatter_names("coal")
	check(str((ore[0] as Dictionary).get("id", "")) == "dir:Vars" and ore[1] == ["coal-1@dir:Vars", "coal-2@dir:Vars", "coal-3@dir:Vars"],
		"the aliased rocks scatter coal: %s" % [ore[1]])

	# The pick: stable, spread over the four, none without a seed, off with --model-variants=off.
	var counts := {}
	var stable := true
	for x in 40:
		for y in 10:
			var extra := {ModelLibrary.VARIANT_KEY: ModelPacks.variant_seed(Vector2i(x * 256 + 128, y * 256 + 128))}
			var first: String = ModelLibrary.entity_models("rock-big", "simple-entity", extra)[0]
			stable = stable and first == ModelLibrary.entity_models("rock-big", "simple-entity", extra.duplicate())[0]
			counts[first] = int(counts.get(first, 0)) + 1
	var spread := counts.size() == 4 and counts.values().all(func(n: int) -> bool: return n >= 60)
	check(stable and spread and counts.has("rock-big-3@dir:Vars") and counts.has("rock-big@dir:Vars"),
		"400 placed rocks: each the same every time, spread over the 4 variants: %s" % [counts])
	check(ModelPacks.variant_seed(Vector2i(512, 256)) == ModelPacks.variant_seed(Vector2i(512, 256))
		and ModelPacks.variant_seed(Vector2i(512, 256)) != ModelPacks.variant_seed(Vector2i(256, 512)),
		"the seed is the position's")
	check(ModelLibrary.entity_models("rock-big", "simple-entity", {}) == ["rock-big"], "no seed (a preview): the plain model, as before")
	var drawn := ModelLibrary.entity_models("sulfur", "simple-entity", {ModelLibrary.VARIANT_KEY: 7})
	check(drawn.size() == 2 and str(drawn[0]).begins_with("sulfur-") and str(drawn[0]).ends_with("@dir:Vars"),
		"numbered variants alone are drawn: %s" % [drawn])
	check(ModelLibrary.entity_models("assembling-machine-2", "assembling-machine", {ModelLibrary.VARIANT_KEY: 7}) == ["assembling-machine-2"],
		"a numbered prototype is drawn by its own name")
	ModelLibrary.model_variants = false
	check(ModelLibrary.entity_models("rock-big", "simple-entity", {ModelLibrary.VARIANT_KEY: 7}) == ["rock-big"], "--model-variants=off: the plain model")
	ModelLibrary.model_variants = true

	# Ores unchanged: a tile is its stage model, never a picked rock.
	for a in [100, 1000, 5000]:
		var tile := ModelLibrary.entity_models("coal", "resource", {"a": a, ModelLibrary.VARIANT_KEY: 12345})
		check(not str(tile[0]).contains("@") and not str(tile[0]).ends_with("-1") and not str(tile[0]).ends_with("-2"),
			"an ore tile keeps its stage model: %s" % [tile])

	# An item's variants: one entry, each its own file, the first by default.
	var items := ModelPacks.items(p)
	check(items.size() == 1 and items[0]["name"] == "sulfur" and int(items[0]["variants"]) == 3,
		"the Items tab's one entry for sulfur-1..3: %s" % [items])
	check(ModelPacks.item_variant_count("sulfur") == 3 and ModelPacks.item_model_path("sulfur").ends_with("sulfur-1.glb")
		and ModelPacks.item_model_path("sulfur", 2).ends_with("sulfur-3.glb")
		and ItemModels.mesh_for("sulfur", 1) != null and ItemModels.mesh_for("sulfur", 1) != ItemModels.mesh_for("sulfur"),
		"an item's variants: each read from its own file")

	# An icon's variants: one entry, the same one picked every time, from the set.
	var icon := ModelPacks.icon_file("item", "coal")
	check(ModelPacks.icon_names(p) == ["item/coal"] and icon.get_file().begins_with("coal-") and icon == ModelPacks.icon_file("item", "coal"),
		"an icon's variants: one entry, one picked, stable: %s %s" % [ModelPacks.icon_names(p), icon])

	ModelPacks.set_choices({})
	ModelPacks.configure("", [], [])
	ModelLibrary.choices_changed([])
	_remove_tree(dir)


## The Placeholders gate (tools/models/railway.py): the new model and the old one (`gate-old`, drawn by
## `--gate-model=old`, never a variant) both keep the sinking door part anim.gd opens, and the new one
## a frame that stays (more than the old one's low rails) with an emissive warning light.
func _gate_model() -> void:
	ModelPacks.configure("", [], [])
	ModelPacks.wait()
	ModelPacks.set_choices({})
	ModelLibrary.choices_changed([])
	var placeholders := ModelPacks.pack("builtin:placeholders")
	check(not placeholders.is_empty() and placeholders["models"].has("gate") and placeholders["models"].has("gate-old"),
		"gate: the new and the old model are in the Placeholders pack")
	if placeholders.is_empty():
		return
	check(ModelPacks.family("gate-old") == "gate" and ModelPacks.variants_in(placeholders["models"], "gate") == ["gate"],
		"gate: the old model is the gate's family and never one of its variants")
	var was := ModelLibrary.gate_model_old
	ModelLibrary.gate_model_old = false
	var now := ModelLibrary.model_name("gate", "gate", {})
	ModelLibrary.gate_model_old = true
	var old := ModelLibrary.model_name("gate", "gate", {})
	ModelLibrary.gate_model_old = was
	check(now == "gate" and old == "gate-old", "gate: --gate-model=old draws gate-old (%s, %s)" % [now, old])
	for name: String in ["gate", "gate-old"]:
		var doors := 0
		for p: ModelLibrary.AnimPart in ModelLibrary.parts_for(name):
			if p.kind == "gate_door":
				doors += 1
		check(doors == 1, "gate: %s has its sinking door part (%d)" % [name, doors])
	var heights := {}
	var lit := {}
	for name: String in ["gate", "gate-old"]:
		var path := ModelPacks.find_in("builtin:placeholders", name)
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		check(path != "" and doc.append_from_file(path, state) == OK, "gate: %s reads" % name)
		heights[name] = 0.0
		lit[name] = false
		var meshes := state.get_meshes()
		for node: GLTFNode in state.get_nodes():
			if node.resource_name != "body" or node.mesh < 0:
				continue
			var arr: ImporterMesh = meshes[node.mesh].mesh
			for s in arr.get_surface_count():
				var verts: PackedVector3Array = arr.get_surface_arrays(s)[Mesh.ARRAY_VERTEX]
				for v: Vector3 in verts:
					heights[name] = maxf(float(heights[name]), v.y)
				var mat := arr.get_surface_material(s)
				if mat is StandardMaterial3D and (mat as StandardMaterial3D).emission_enabled:
					lit[name] = true
	check(float(heights["gate"]) > float(heights["gate-old"]) + 0.1 and bool(lit["gate"]),
		"gate: the frame that stays stands taller than the old rails and has a warning light (%s, %s)" % [heights, lit])


## A .glb of one triangle with UVs and a base-colour picture (a 2x2 PNG, red at its first pixel), no
## vertex colours.
## Nauvis's cliffs (tools/models/nature/cliffs.py): the five pieces' variants are found, the old
## pieces (`cliff-<piece>-old`) are never one of them and `--cliff-pieces=old` draws them, and every
## piece and variant has the same cross-section where it meets its cell's edge, so any joins any.
func _cliffs() -> void:
	ModelPacks.configure("", [], [])
	ModelPacks.wait()
	ModelPacks.set_choices({})
	ModelLibrary.choices_changed([])
	var placeholders := ModelPacks.pack("builtin:placeholders")
	check(not placeholders.is_empty(), "cliffs: the Placeholders pack is in use")
	if placeholders.is_empty():
		return
	var counts := {"sides": 4, "outer": 3, "inner": 3, "exit": 2, "entrance": 2}
	for piece: String in counts:
		var found := ModelPacks.variants_in(placeholders["models"], "cliff-" + piece)
		var want: Array = ["cliff-" + piece]
		for i in range(1, int(counts[piece])):
			want.append("cliff-%s-%d" % [piece, i])
		check(found == want, "cliffs: %s's variants found: %s" % [piece, found])
		check(placeholders["models"].has("cliff-%s-old" % piece), "cliffs: the old %s kept" % piece)
		check(ModelPacks.family("cliff-%s-old" % piece) == "cliff" and ModelPacks.family("cliff-%s-1" % piece) == "cliff",
			"cliffs: the old %s and its variants are the cliff's family" % piece)
		check(ModelPacks.variants_in(placeholders["models"], "cliff-%s-old" % piece) == ["cliff-%s-old" % piece],
			"cliffs: the old %s has no variants of its own" % piece)
	var was := ModelLibrary.cliff_pieces_old
	ModelLibrary.cliff_pieces_old = false
	var seen := {}
	for x in range(0, 64, 4):
		var extra := {"co": "west-to-east", ModelLibrary.VARIANT_KEY: ModelPacks.variant_seed(Vector2i(x * 256, 128))}
		seen[str(ModelLibrary.entity_models("cliff", "cliff", extra)[0])] = true
	var keys := seen.keys()
	keys.sort()
	check(keys.size() >= 3 and keys.all(func(k: String) -> bool: return k.begins_with("cliff-sides") and not k.contains("-old")),
		"cliffs: a straight run draws several variants, never the old piece: %s" % [keys])
	ModelLibrary.cliff_pieces_old = true
	var old_models := ModelLibrary.entity_models("cliff", "cliff", {"co": "north-to-east", ModelLibrary.VARIANT_KEY: 12345})
	check(ModelLibrary.model_name("cliff", "cliff", {"co": "west-to-east"}) == "cliff-sides-old"
		and str(old_models[0]) == "cliff-outer-old"
		and ModelLibrary.model_name("cliff-vulcanus", "cliff", {"co": "west-to-east"}) == "cliff-vulcanus-sides",
		"cliffs: --cliff-pieces=old draws Nauvis's old pieces, other planets' as before: %s" % [old_models])
	ModelLibrary.cliff_pieces_old = was
	# The cross-sections at the cell's edges, as (offset towards the face, height) in the edge's own
	# frame: [plane axis (0 x, 2 z), plane value, inward sign, right axis, right sign].
	var starts := [0, -2.0, 1.0, 2, 1.0]
	var ends := {"sides": [0, 2.0, -1.0, 2, 1.0], "entrance": [0, 2.0, -1.0, 2, 1.0],
		"outer": [2, -2.0, 1.0, 0, 1.0], "inner": [2, 2.0, -1.0, 0, -1.0]}
	var canonical: Array = []
	for piece: String in counts:
		for i in range(int(counts[piece])):
			var name := "cliff-" + piece + ("" if i == 0 else "-%d" % i)
			var points := _cliff_points(str(placeholders["models"][name]))
			check(points.size() > 100, "cliffs: %s read (%d points)" % [name, points.size()])
			var edges: Array = []
			if piece != "entrance":
				edges.append(starts)
			if ends.has(piece):
				edges.append(ends[piece])
			for e: Array in edges:
				var section := {}
				var beyond := 0.0
				for v: Vector3 in points:
					var d: float = (v[int(e[0])] - float(e[1])) * float(e[2])
					beyond = maxf(beyond, -d)
					if absf(d) < 0.002:
						section["%.2f,%.2f" % [v[int(e[3])] * float(e[4]), v.y]] = true
				var list := section.keys()
				list.sort()
				if canonical.is_empty():
					canonical = list
				check(list == canonical and list.size() >= 10, "cliffs: %s's edge cross-section is the shared one (%d points): %s" % [name, list.size(), list])
				check(beyond < 0.005, "cliffs: nothing of %s past its cell's edge (%.3f)" % [name, beyond])


## A model's vertices, every mesh in the scene's own frame.
static func _cliff_points(path: String) -> Array:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		return []
	var out: Array = []
	var nodes := state.get_nodes()
	for i in nodes.size():
		var node: GLTFNode = nodes[i]
		if node.mesh < 0:
			continue
		var xf := Transform3D.IDENTITY
		var at := i
		while at >= 0:
			xf = (nodes[at] as GLTFNode).xform * xf
			at = (nodes[at] as GLTFNode).parent
		var mesh: ImporterMesh = (state.get_meshes()[node.mesh] as GLTFMesh).mesh
		for s in mesh.get_surface_count():
			for v: Vector3 in mesh.get_surface_arrays(s)[Mesh.ARRAY_VERTEX]:
				out.append(xf * v)
	return out


static func _pictured_glb() -> PackedByteArray:
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 1))
	img.set_pixel(0, 0, Color(1, 0, 0))
	var png := img.save_png_to_buffer()
	var bin := PackedByteArray()
	bin.resize(104)
	var at := 0
	for v in [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, -1.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0,
			0.0, 0.0, 1.0, 0.0, 0.0, 1.0]:
		bin.encode_float(at, v)
		at += 4
	for i in [0, 1, 2]:
		bin.encode_u16(at, i)
		at += 2
	bin.append_array(png)
	while bin.size() % 4 != 0:
		bin.append(0)
	var gltf := {"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0, "name": "plate"}],
		"meshes": [{"primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2}, "indices": 3, "material": 0}]}],
		"materials": [{"name": "Plate", "pbrMetallicRoughness": {"baseColorTexture": {"index": 0}}}],
		"textures": [{"source": 0, "sampler": 0}], "samplers": [{"magFilter": 9729, "minFilter": 9987}],
		"images": [{"bufferView": 4, "mimeType": "image/png"}],
		"buffers": [{"byteLength": bin.size()}],
		"bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 36, "target": 34962},
			{"buffer": 0, "byteOffset": 36, "byteLength": 36, "target": 34962},
			{"buffer": 0, "byteOffset": 72, "byteLength": 24, "target": 34962},
			{"buffer": 0, "byteOffset": 96, "byteLength": 6, "target": 34963},
			{"buffer": 0, "byteOffset": 104, "byteLength": png.size()}],
		"accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, -1], "max": [1, 0, 0]},
			{"bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3"},
			{"bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC2"},
			{"bufferView": 3, "componentType": 5123, "count": 3, "type": "SCALAR"}]}
	var json := JSON.stringify(gltf).to_utf8_buffer()
	while json.size() % 4 != 0:
		json.append(0x20)
	var out := PackedByteArray()
	out.resize(12)
	out.encode_u32(0, 0x46546C67)
	out.encode_u32(4, 2)
	out.encode_u32(8, 12 + 8 + json.size() + 8 + bin.size())
	var head := PackedByteArray()
	head.resize(8)
	head.encode_u32(0, json.size())
	head.encode_u32(4, 0x4E4F534A)
	out.append_array(head)
	out.append_array(json)
	head.encode_u32(0, bin.size())
	head.encode_u32(4, 0x004E4942)
	out.append_array(head)
	out.append_array(bin)
	return out


static func _write(path: String, bytes: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


static func _zip(path: String, files: Dictionary) -> void:
	var zip := ZIPPacker.new()
	zip.open(path)
	for name: String in files:
		zip.start_file(name)
		zip.write_file(files[name])
		zip.close_file()
	zip.close()


## A .gltf of one triangle whose buffer is a file of its own (`bin`, relative to the .gltf):
## [the .gltf's bytes, the buffer's].
static func _triangle_gltf(bin: String) -> Array:
	var buffer := PackedByteArray()
	buffer.resize(78)
	var at := 0
	for v in [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, -1.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0]:
		buffer.encode_float(at, v)
		at += 4
	for i in [0, 1, 2]:
		buffer.encode_u16(at, i)
		at += 2
	var gltf := {"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0, "name": "body"}],
		"meshes": [{"primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1}, "indices": 2}]}],
		"buffers": [{"uri": bin, "byteLength": 78}],
		"bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 36, "target": 34962},
			{"buffer": 0, "byteOffset": 36, "byteLength": 36, "target": 34962},
			{"buffer": 0, "byteOffset": 72, "byteLength": 6, "target": 34963}],
		"accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3", "min": [0, 0, -1], "max": [1, 0, 0]},
			{"bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3"},
			{"bufferView": 2, "componentType": 5123, "count": 3, "type": "SCALAR"}]}
	return [JSON.stringify(gltf).to_utf8_buffer(), buffer]


static func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for d in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(d))
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)


## pack.json's "shading_models": single models over the pack's "shading" (model_packs.gd model_shading()).
func _test_shading_models(dir: String) -> void:
	var info := "{\"name\": \"Mix\", \"shading\": \"pbr\", \"shading_models\": {\"stone-furnace\": \"factorio\", \"iron-ore-*\": \"factorio\", \"coal-2\": \"pbr\", \"bad\": \"glossy\"}}"
	var info2 := "{\"name\": \"Mix2\", \"shading\": \"factorio\", \"shading_models\": {\"stone-*\": \"pbr\", \"stone-furnace\": \"factorio\", \"coal\": \"pbr\"}}"
	for pair in [["Mix", info], ["Mix2", info2]]:
		for f in ["stone-furnace", "stone-wall", "iron-ore", "iron-ore-3", "coal", "coal-2", "coal-3", "steel-furnace", "items/iron-ore", "items/stone-wall"]:
			_write(dir.path_join(str(pair[0]) + "/" + f + ".glb"), _pictured_glb())
		_write(dir.path_join(str(pair[0]) + "/pack.json"), str(pair[1]).to_utf8_buffer())
	ModelPacks.configure(dir, ["dir:Mix", "dir:Mix2"], [])
	ModelPacks.wait()
	var a: Dictionary = ModelPacks.pack("dir:Mix")
	var got := {}
	for f in ["stone-furnace", "steel-furnace", "iron-ore", "iron-ore-3", "coal", "coal-2", "coal-3", "items/iron-ore"]:
		got[f] = ModelPacks.pbr(dir.path_join("Mix/" + f + ".glb"))
	check(got == {"stone-furnace": false, "steel-furnace": true, "iron-ore": true, "iron-ore-3": false, "coal": true,
		"coal-2": true, "coal-3": true, "items/iron-ore": true},
		"shading_models: exact names, wildcards, variants following their base, items/ copies, a named variant: %s" % [got])
	check(not (a["info"]["shading_models"] as Dictionary).has("bad"), "shading_models: a value that is neither pbr nor factorio is dropped")
	var got2 := {}
	for f in ["stone-furnace", "stone-wall", "coal", "items/stone-wall", "steel-furnace"]:
		got2[f] = ModelPacks.pbr(dir.path_join("Mix2/" + f + ".glb"))
	check(got2 == {"stone-furnace": false, "stone-wall": true, "coal": true, "items/stone-wall": true, "steel-furnace": false},
		"shading_models: the first pattern that fits wins unless the name is exact (stone-furnace is 'factorio' exact): %s" % [got2])
	# The Model packs window's pack-level PBR toggle only sets the pack's default: pack.json's shading_models entries win.
	var keep_packs := ModelPacks.pbr_packs.duplicate()
	var keep_models := ModelPacks.pbr_models.duplicate()
	var mix_id := str(a["id"])
	var mix2_id := str((ModelPacks.pack("dir:Mix2") as Dictionary)["id"])
	var names := ["stone-furnace", "steel-furnace", "coal-2", "stone-wall", "coal"]
	var pbr_of := func(pack: String) -> Dictionary:
		var out := {}
		for f: String in names:
			out[f] = ModelPacks.pbr(dir.path_join(pack + "/" + f + ".glb"))
		return out
	ModelPacks.set_pbr_overrides({mix_id: false, mix2_id: true}, {})
	var mix_off: Dictionary = pbr_of.call("Mix")
	var mix2_on: Dictionary = pbr_of.call("Mix2")
	ModelPacks.set_pbr_overrides({mix_id: true, mix2_id: false}, {})
	var mix_on: Dictionary = pbr_of.call("Mix")
	var mix2_off: Dictionary = pbr_of.call("Mix2")
	ModelPacks.set_pbr_overrides({mix_id: true}, {mix_id + "|stone-furnace": true})
	var mix_model_wins: bool = ModelPacks.pbr(dir.path_join("Mix/stone-furnace.glb"))
	ModelPacks.set_pbr_overrides(keep_packs, keep_models)
	check(not mix_off["stone-furnace"] and mix_off["coal-2"] and not mix_off["steel-furnace"] and not mix_off["stone-wall"]
		and not mix2_on["stone-furnace"] and mix2_on["steel-furnace"] and mix2_on["stone-wall"]
		and not mix_on["stone-furnace"] and mix_on["steel-furnace"]
		and not mix2_off["stone-furnace"] and mix2_off["stone-wall"] and mix2_off["coal"] and not mix2_off["steel-furnace"]
		and mix_model_wins,
		"pack toggle: pack.json's shading_models entries win over the pack-level PBR toggle (it only moves the pack default), a per-model override over both: %s %s %s %s" % [mix_off, mix2_on, mix_on, mix2_off])
