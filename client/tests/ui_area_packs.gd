extends "res://tests/ui_test_base.gd"
## UI test sections: packs.

func _model_packs_factorio(w: Node, models: Node) -> void:
	var ModelPacks = ModelLibrary.ModelPacks
	if ItemIcons.factorio_data_dir() == "" or ModelPacks.pack(ModelPacks.FACTORIO_ID).is_empty():
		print("NOTE no Factorio install: the Factorio pack's Models, Items and Icons tabs aren't checked")
		return
	var SpriteStandins = load("res://scripts/world/sprite_standins.gd")
	var fid: String = ModelPacks.FACTORIO_ID
	var preview = w._preview
	var settle := func() -> void:
		var until := Time.get_ticks_msec() + 20000
		while not preview.settled() and Time.get_ticks_msec() < until:
			await get_tree().process_frame
		await get_tree().process_frame
	w.open_tab("models")
	w.select_pack(fid)
	w.finish_fill()
	var listed: Array = models.get_children().filter(func(c: Node) -> bool: return c is Button).map(func(c: Node) -> String: return str(c.name).trim_prefix("model-"))
	check(listed.has("assembling-machine-1") and listed.has("stone-furnace") and listed.size() >= 100
		and listed.size() == ModelPacksWindow._families_of(ModelPacks.pack(fid)).size(),
		"the Factorio pack's Models lists its pictures by family: %d" % listed.size())
	(models.find_child("model-assembling-machine-1", true, false) as Button).pressed.emit()
	await settle.call()
	var card := preview.shown_mesh as QuadMesh
	var tex: Texture2D = (card.material as ShaderMaterial).get_shader_parameter("picture") if card != null else null
	var box: Rect2 = preview.box_on_screen(0.0)
	var view := Vector2(preview.viewport.size)
	check(preview.is_picture() and preview.shown_sprite()[0] == "assembling-machine-1" and tex != null
		and preview.box_in_view(0.0) and maxf(box.size.x / view.x, box.size.y / view.y) > 0.6,
		"the assembler's picture on its card, framed: %s, %s of %s" % [preview.model, box.size, view])
	await get_tree().process_frame
	var play_button := w.find_child("PlayAnim", true, false) as Button
	check(play_button.disabled and play_button.tooltip_text == "A picture, not a model", "Play greyed for a picture: %s" % play_button.tooltip_text)
	var card_of := func(id: String) -> Control:
		return w.find_child("version-" + id.replace(":", "_"), true, false) as Control
	var tagged: Array = (w.find_child("Versions", true, false) as Node).get_children().filter(func(c: Node) -> bool:
		return c.find_child("InUseTag", true, false) != null).map(func(c: Node) -> String: return str(c.get_meta("pack")))
	var in_use := str(ModelPacksWindow._pack_in_use("assembling-machine-1").get("id", ""))
	var other := ""
	for c: Node in (w.find_child("Versions", true, false) as Node).get_children():
		if str(c.get_meta("pack")) != fid and other == "":
			other = str(c.get_meta("pack"))
	check(card_of.call(fid) != null and other != "" and tagged == [in_use],
		"the Factorio card beside another pack's (%s), the one in use tagged by the order: %s, %s" % [other, tagged, in_use])
	(w.find_child("show-" + other.replace(":", "_"), true, false) as Button).pressed.emit()
	await settle.call()
	check(preview.model == "assembling-machine-1@" + other and not preview.is_picture(), "View on that card shows its model: %s" % preview.model)
	(w.find_child("show-builtin_factorio", true, false) as Button).pressed.emit()
	await settle.call()
	check(preview.is_picture(), "View on the Factorio card shows the picture again: %s" % preview.model)
	(w.find_child("use-builtin_factorio", true, false) as Button).pressed.emit()
	var words := (card_of.call(fid) as Node).find_child("words", true, false) as Label
	check(str(ModelPacks.choices.get("assembling-machine-1", "")) == fid and ModelLibrary.draws_sprite("assembling-machine-1")
		and words != null and words.text == "In use (chosen)",
		"Select on the Factorio card draws its picture in the game whatever the order")
	(w.find_child("UseOrder", true, false) as Button).pressed.emit()
	check(not ModelPacks.choices.has("assembling-machine-1"), "Use the pack order gives it back")
	# A picture with directions: the four in the variant picker.
	var turned := ""
	for fam: String in ["inserter", "electric-mining-drill", "arithmetic-combinator", "splitter"]:
		if listed.has(fam) and SpriteStandins.directions(fam).size() == 4:
			turned = fam
			break
	check(turned != "", "a Factorio picture with four directions found")
	if turned != "":
		w.select_family(turned, fid)
		await settle.call()
		var choice := w._info.find_child("VariantChoice", true, false) as OptionButton
		var labels: Array = []
		for i in (choice.item_count if choice != null else 0):
			labels.append(choice.get_item_text(i))
		check(labels == ["North", "East", "South", "West"], "%s's picture: its four directions in the picker: %s" % [turned, labels])
		(w._info.find_child("VariantNext", true, false) as Button).pressed.emit()
		await settle.call()
		check(preview.shown_sprite() == [turned, 4] and preview.shown_mesh != null, "the next arrow shows it facing east: %s" % preview.model)
	if SpriteStandins.directions("inserter").size() != 4:
		print("  NOTE the inserter's picture has one direction here (no game's graphics list): %s checked instead" % turned)
	# Items: the install's items as icon cards.
	w.open_tab("items")
	w.finish_fill()
	check(models.find_child("item-iron-plate", true, false) != null and models.find_child("EmptyNote", true, false) == null,
		"the Factorio pack's Items lists the install's items")
	(models.find_child("item-iron-plate", true, false) as Button).pressed.emit()
	await settle.call()
	var plate := preview.shown_mesh as PlaneMesh
	check(preview.model == "card:iron-plate" and plate != null and (plate.material as StandardMaterial3D).albedo_texture != null
		and preview.box_in_view(0.0), "a click shows iron plate's icon card lying face up: %s" % preview.model)
	# Icons: the install's, over frames.
	w.open_tab("icons")
	var first: int = models.get_child_count()
	var keys: Array = ModelPacksWindow.factorio_icon_keys()
	var frames := 0
	while w.filling() and frames < 2000:
		await get_tree().process_frame
		frames += 1
	check(keys.size() > 1000 and first < keys.size() and frames > 1 and models.get_child_count() == keys.size()
		and models.find_child("icon-iron-plate", true, false) != null and models.find_child("icon-fluid_water", true, false) != null,
		"the install's %d icons fill over %d frames" % [keys.size(), frames])
	w.load_icons_now()
	var plate_icon := models.find_child("icon-iron-plate", true, false) as Button
	check(plate_icon.icon != null and plate_icon.icon != ModelPacksWindow.blank_icon(), "an icon button wears Factorio's icon")
	plate_icon.pressed.emit()
	var pack_pic := w.find_child("PackIcon", true, false) as TextureRect
	check(pack_pic.texture != null and not (w.find_child("FactorioIcon", true, false) as Control).get_parent().visible
		and w.find_child("version-builtin_factorio", true, false) != null,
		"Factorio's icon shown large alone, its card under it")
	w.select_icon("")
	w.open_tab("models")
	w.select_family("")
	w.select_pack("builtin:placeholders")
	w.finish_fill()


## An ore a pack has only as numbered rocks (iron-ore-1..3, as Vasillo's new models): its card is listed
## on the ore's family beside Placeholders', tagged in use when it is first in the order (its rocks are
## scattered) and not when Placeholders is; Select on it takes the ore from it whatever the order.


func _model_packs_ores(w: Node) -> void:
	var ModelPacks = ModelLibrary.ModelPacks
	var saved: Array = ModelPacks.packs
	var rock := Vector3(0.36, 0.14, 0.31)
	var dir := _fixture_packs("ui-test-model-packs-ores", {"Rocks": {"iron-ore-1": rock, "iron-ore-2": rock, "iron-ore-3": rock}},
		["dir:Rocks", "builtin:placeholders"])
	var cards := func() -> Dictionary:
		var out := {}
		for c: Node in (w.find_child("Versions", true, false) as Node).get_children():
			out[str(c.get_meta("pack"))] = c.find_child("InUseTag", true, false) != null
		return out
	w.select_family("iron-ore")
	var listed: Dictionary = cards.call()
	check(listed.has("dir:Rocks") and listed.has("builtin:placeholders") and bool(listed["dir:Rocks"]) and not bool(listed["builtin:placeholders"]),
		"iron ore's cards: the pack of iron-ore-1..3 beside Placeholders, in use first in the order: %s" % [listed])
	# Its preview: the pack's first rock once it is read (asked for here the first time), without picking a
	# variant; `iron-ore@dir:Rocks` was drawn as the usual iron ore, Placeholders', the picker at 0 / 3.
	var preview = w._preview
	var until := Time.get_ticks_msec() + 10000
	while not preview.settled() and Time.get_ticks_msec() < until:
		await get_tree().process_frame
	await get_tree().process_frame
	var count := w.find_child("VariantCount", true, false) as Label
	var rock_mesh := ModelLibrary.mesh_for("iron-ore-1@dir:Rocks")
	check(preview.model == "iron-ore-1@dir:Rocks" and preview.shown_mesh != null and preview.shown_mesh == rock_mesh
		and rock_mesh != ModelLibrary.mesh_for("iron-ore") and count != null and count.text == "1 / 3",
		"iron ore opened: the rocks' pack's first rock turning once read, no variant picked: %s, %s" % [preview.model,
		count.text if count != null else "no picker"])
	ModelPacks.configure(dir, ["builtin:placeholders", "dir:Rocks"], [])
	ModelPacks.wait()
	ModelLibrary.choices_changed([])
	w.select_family("iron-ore")
	listed = cards.call()
	check(listed.has("dir:Rocks") and not bool(listed["dir:Rocks"]) and bool(listed.get("builtin:placeholders", false)),
		"Placeholders above it: Placeholders' iron ore in use, the rocks' card still listed: %s" % [listed])
	(w.find_child("use-dir_Rocks", true, false) as Button).pressed.emit()
	listed = cards.call()
	check(str(ModelPacks.choices.get("iron-ore", "")) == "dir:Rocks" and bool(listed["dir:Rocks"])
		and str(ModelLibrary.ore_scatter_names("iron-ore")[0].get("id", "")) == "dir:Rocks",
		"Select on the rocks' card: its rocks draw iron ore whatever the order: %s" % [listed])
	(w.find_child("UseOrder", true, false) as Button).pressed.emit()
	check(not ModelPacks.choices.has("iron-ore"), "Use the pack order gives iron ore back")
	w.select_family("")
	_saved_packs = saved
	_fixture_packs_done()
	# A frame for the window's corner buttons (_update_play_row, each frame), as after the sections before.
	await get_tree().process_frame


## The Model packs window's Items tab, on Placeholders listed: its items with their icons and names,
## the search box, an item turning in the preview framed whole, a card per pack with it (the fixture
## Belts pack's iron plate above Placeholders'), View and Select (an "item:" choice), the order again.


func _model_packs_items(w: Node, models: Node, dir: String) -> void:
	var ModelPacks = ModelLibrary.ModelPacks
	(w.find_child("TabItems", true, false) as Button).pressed.emit()
	w.finish_fill()
	var items: Array = models.get_children().filter(func(c: Node) -> bool: return c is Button)
	var placeholders: Dictionary = ModelPacks.pack("builtin:placeholders")
	check(w.current_tab() == "items" and items.size() == (placeholders["items"] as Dictionary).size() and items.size() >= 198
		and models.find_child("item-iron-plate", true, false) != null and models.find_child("EmptyNote", true, false) == null,
		"the Items tab lists Placeholders' item models: %d" % items.size())
	var plate := models.find_child("item-iron-plate", true, false) as Button
	check(plate.text.to_lower().contains("iron plate") and plate.get_meta("item", false) and plate.get_meta("family") == "iron-plate"
		and plate.get_theme_color("font_color") == Kit.DISABLED_TEXT,
		"an item's button: its name, its icon (queued), greyed when another pack's is in use (Belts'): %s" % plate.text)
	var search := w.find_child("Search", true, false) as LineEdit
	search.text = "copper-pl"
	search.text_changed.emit("copper-pl")
	w.finish_fill()
	check(models.get_children().filter(func(c: Node) -> bool: return c is Button).size() == 1 and models.find_child("item-copper-plate", true, false) != null,
		"the search box filters the items")
	search.text = ""
	search.text_changed.emit("")
	w.finish_fill()
	(models.find_child("item-iron-plate", true, false) as Button).pressed.emit()
	var preview = w._preview
	var until := Time.get_ticks_msec() + 10000
	while not preview.settled() and Time.get_ticks_msec() < until:
		await get_tree().process_frame
	await get_tree().process_frame
	var plate_file := str(placeholders["items"]["iron-plate"])
	check(w.selected_item == "iron-plate" and w.selected_family == "" and preview.shown_item() == "iron-plate" and preview.shown_mesh != null
		and preview.model.ends_with(plate_file), "a click shows Placeholders' iron plate turning (the listed pack's): %s" % preview.model)
	var fits := true
	for k in 8:
		fits = fits and preview.box_in_view(k * TAU / 8.0)
	var box: Rect2 = preview.box_on_screen(0.0)
	var view := Vector2(preview.viewport.size)
	check(fits and box.size.x > view.x * 0.3, "the small item is framed whole as it turns, filling the picture: %s of %s" % [box.size, view])
	var cards := w.find_child("Versions", true, false)
	var belts_card := cards.find_child("version-dir_Belts", true, false) if cards != null else null
	var own_card := cards.find_child("version-builtin_placeholders", true, false) if cards != null else null
	check(belts_card != null and own_card != null and belts_card.find_child("InUseTag", true, false) != null
		and own_card.find_child("InUseTag", true, false) == null and (own_card.find_child("show-builtin_placeholders", true, false) as Button).button_pressed,
		"a card per pack with the item, Belts' in use by the order, Placeholders' shown")
	(belts_card.find_child("show-dir_Belts", true, false) as Button).pressed.emit()
	check(preview.model.ends_with(dir.path_join("Belts/items/iron-plate.glb")) and w.selected_item == "iron-plate", "View shows Belts' version: %s" % preview.model)
	(w.find_child("Versions", true, false).find_child("use-builtin_placeholders", true, false) as Button).pressed.emit()
	w.finish_fill()
	var chosen: Dictionary = Settings.get_value("model_packs", "choices")
	check(chosen.get("item:iron-plate") == "builtin:placeholders" and ModelPacks.item_model_path("iron-plate") == plate_file
		and not chosen.has("iron-plate") and preload("res://scripts/world/item_models.gd").mesh_for("iron-plate") != null
		and (w.find_child("Versions", true, false).find_child("version-builtin_placeholders", true, false).find_child("InUseTag", true, false) != null)
		and (models.find_child("item-iron-plate", true, false) as Button).text.begins_with("✔"),
		"Select saves an item: choice and draws Placeholders' plate whatever the order: %s" % [chosen])
	(w.find_child("UseOrder", true, false) as Button).pressed.emit()
	check(not (Settings.get_value("model_packs", "choices") as Dictionary).has("item:iron-plate")
		and ModelPacks.item_model_path("iron-plate") == dir.path_join("Belts/items/iron-plate.glb"), "Use the pack order gives it back")
	w.select_family("")
	check(w.selected_item == "" and preview.shown_item() == "", "picking no family clears the item")


func _model_packs_window() -> void:
	var ModelPacks = ModelLibrary.ModelPacks
	var dir := OS.get_user_data_dir().path_join("ui-test-model-packs")
	var chest := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(_own_glb("wooden-chest")))
	var write := func(path: String, bytes: PackedByteArray) -> void:
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(bytes)
		f.close()
	write.call(dir.path_join("iron-chest.glb"), chest)
	write.call(dir.path_join("Belts/pack.json"), JSON.stringify({"name": "Test belts", "version": "2.0", "author": "Tester",
		"icon_image": "art/logo.png"}).to_utf8_buffer())
	var logo := Image.create(6, 4, false, Image.FORMAT_RGBA8)
	logo.fill(Color(0.2, 0.6, 0.9))
	write.call(dir.path_join("Belts/art/logo.png"), logo.save_png_to_buffer())
	# The loose models' pack.json names a picture that isn't there: the model picture stays.
	write.call(dir.path_join("pack.json"), JSON.stringify({"icon_image": "missing.png"}).to_utf8_buffer())
	write.call(dir.path_join("Belts/belts/transport-belt.glb"), chest)
	# (and one of its variants, for the variant picker: a left curve, no right one)
	write.call(dir.path_join("Belts/belts/transport-belt-curve-left.glb"), chest)
	# (and two icons for the Icons tab: an item's and a fluid's)
	var icon_image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	icon_image.fill(Color(0, 0, 1))
	write.call(dir.path_join("Belts/icons/transport-belt.png"), icon_image.save_png_to_buffer())
	write.call(dir.path_join("Belts/icons/fluid/water.png"), icon_image.save_png_to_buffer())
	# (and an item model, for the Items tab: Placeholders has one of the name too)
	write.call(dir.path_join("Belts/items/iron-plate.glb"), FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(
		preload("res://scripts/world/item_models.gd").DIR + "copper-plate.glb")))
	var zip := ZIPPacker.new()
	zip.open(dir.path_join("zipped.zip"))
	zip.start_file("zipped/wooden-chest.glb")
	zip.write_file(chest)
	zip.close_file()
	zip.close()
	var saved_packs: Array = ModelPacks.packs
	var saved_folder: String = ModelPacks.folder
	var saved_dir: String = ModelPacks.models_dir
	var saved_choices: Dictionary = ModelPacks.choices
	var order_was: Variant = Settings.get_value("model_packs", "order")
	var off_was: Variant = Settings.get_value("model_packs", "off")
	var choices_was: Variant = Settings.get_value("model_packs", "choices")
	Settings.set_value("model_packs", "order", ["loose", "dir:Belts"])
	Settings.set_value("model_packs", "off", ["dir:Belts"])
	Settings.set_value("model_packs", "choices", {})
	ModelPacks.set_choices({})
	ModelPacks.configure(dir, ["loose", "dir:Belts"], ["dir:Belts"])
	ModelPacks.wait()
	ModelLibrary.choices_changed([])
	ModelPacksWindow.sound_choice = true  # a new session's
	var w: Node = ModelPacksWindow.new()
	(w as Control).theme = MenuKit.theme()  # as in the game, where the root has the menus' theme
	add_child(w)
	await get_tree().process_frame
	var titles := func(list: String) -> Array:
		var out: Array = []
		for row in w.find_child(list, true, false).get_children():
			if row.has_meta("pack"):
				out.append((row.find_child("title", true, false) as Label).text)
		return out
	var row_of := func(list: String, id: String) -> Node:
		for row in w.find_child(list, true, false).get_children():
			if str(row.get_meta("pack", "")) == id:
				return row
		return null
	# The Factorio pack: Selected's last with an install, greyed in Available with the reason without one.
	var installed := ItemIcons.factorio_data_dir() != ""
	var fac: Array = ["Factorio"] if installed else []
	check(titles.call("Available") == ["Test belts"] + ([] if installed else ["Factorio"])
		and titles.call("Selected") == ["zipped", "Loose models", "FUE5 (Adapted)", "Wube3DP (Adapted)", "Placeholders"] + fac,
		"Available has the pack off, Selected the rest: the new zip on top, the built-in packs under the folder's, Factorio last: %s | %s"
		% [titles.call("Available"), titles.call("Selected")])
	var ph_row: Node = row_of.call("Selected", "builtin:placeholders")
	var last: Node = row_of.call("Selected", ModelPacks.FACTORIO_ID if installed else "builtin:placeholders")
	var top_row: Node = row_of.call("Selected", "zip:zipped.zip")
	check(ph_row != null and ph_row.find_child("fixed", true, false) == null and ph_row.find_child("remove", true, false) != null
		and (ph_row.find_child("down", true, false) as Button).disabled == not installed
		and (last.find_child("down", true, false) as Button).disabled and (top_row.find_child("up", true, false) as Button).disabled
		and not (top_row.find_child("down", true, false) as Button).disabled,
		"Placeholders has arrows as any pack; the last one can't go down; the top one can't go up")
	if installed:
		var fac_row: Node = row_of.call("Selected", ModelPacks.FACTORIO_ID)
		var fac_image := fac_row.find_child("image", true, false) as TextureRect
		check(fac_image != null and fac_image.texture != null and fac_row.tooltip_text.contains("your Factorio install")
			and ModelPacksWindow.credit_line(ModelPacks.pack(ModelPacks.FACTORIO_ID)).contains("Wube Software"),
			"the Factorio pack's picture is the install's logo, its credit Wube's")
	else:
		var fac_row: Node = row_of.call("Available", ModelPacks.FACTORIO_ID)
		check(fac_row != null and fac_row.find_child("problem", true, false) != null and (fac_row.find_child("add", true, false) as Button).disabled,
			"without an install the Factorio pack is greyed with the reason")
		print("NOTE no Factorio install: the Factorio pack's order isn't checked in the window")
	# pack.json's icon_image: a picture in the pack; a missing one falls back to the model picture.
	var belts_image := (row_of.call("Available", "dir:Belts") as Node).find_child("image", true, false) as TextureRect
	check(belts_image != null and belts_image.texture.get_size() == Vector2(6, 4)
		and (row_of.call("Available", "dir:Belts") as Node).find_child("picture", true, false) == null,
		"a pack.json's icon_image is the pack's picture: %s" % belts_image)
	check((row_of.call("Selected", "loose") as Node).find_child("picture", true, false) != null
		and (row_of.call("Selected", "loose") as Node).find_child("image", true, false) == null,
		"an icon_image that isn't there keeps the model picture")
	var fue5_image := (row_of.call("Selected", "builtin:fue5") as Node).find_child("image", true, false) as TextureRect
	check(fue5_image != null and fue5_image.texture.get_size() == Vector2(256, 256),
		"the built-in FUE5 pack's picture is its logo.png: %s" % fue5_image)
	check(ModelPacksWindow.pack_image({"info": {"icon_image": "../outside.png"}, "root": dir.path_join("Belts"), "kind": "folder", "source": ""}) == null
		and ModelPacksWindow.pack_image({"info": {"icon_image": "factorio:../x.png"}, "root": "", "kind": "builtin", "source": ""}) == null,
		"icon_image can't reach outside the pack or the install")
	# A zip pack's models (its directory gave only their count; they are read from its unpacked copy).
	w.select_pack("zip:zipped.zip")
	var zip_models: Node = w.find_child("Models", true, false)
	check(zip_models.find_child("model-wooden-chest", true, false) != null and zip_models.get_child_count() == 1,
		"a zip pack's models listed from its unpacked copy, not \"No models read yet.\": %s" % [zip_models.get_children().map(func(c: Node) -> String: return str(c.name))])
	w.select_family("wooden-chest")
	check(w.find_child("show-zip_zipped*", true, false) != null, "a zip pack's version of a model to look at")
	w.select_family("")
	# A row says its count; pack.json's lines are whole in its tooltip and in the details on the right.
	var belts_row: Control = row_of.call("Available", "dir:Belts")
	var count := (belts_row.find_child("count", true, false) as Label).text
	var line := belts_row.tooltip_text
	check(count == "2 models" and line.contains("2 models") and line.contains("Belts/") and line.contains("version 2.0") and line.contains("by Tester"),
		"a pack's model count under its name, pack.json's lines in its tooltip: %s | %s" % [count, line])
	w.select_pack("dir:Belts")
	var facts := w.find_child("PackDetails", true, false)
	var facts_text := (facts.find_child("Facts", true, false) as Label).text if facts != null else ""
	check(facts_text.contains("Belts/") and facts_text.contains("Version: 2.0") and facts_text.contains("Author: Tester"),
		"with no model chosen, the listed pack's details beside its models: %s" % facts_text)
	# ▶: on top of Selected, saved and used at once.
	(row_of.call("Available", "dir:Belts").find_child("add", true, false) as Button).pressed.emit()
	check(titles.call("Selected")[0] == "Test belts" and Settings.get_value("model_packs", "off") == []
		and str(Settings.get_value("model_packs", "order")[0]) == "dir:Belts"
		and ModelPacks.find("transport-belt", true) == dir.path_join("Belts/belts/transport-belt.glb"),
		"a pack added goes on top of Selected and is used at once: %s %s" % [titles.call("Selected"), ModelPacks.find("transport-belt", true)])
	# ◀: back to Available.
	(row_of.call("Selected", "zip:zipped.zip").find_child("remove", true, false) as Button).pressed.emit()
	check(titles.call("Available") == ["zipped"] + ([] if installed else ["Factorio"]) and Settings.get_value("model_packs", "off") == ["zip:zipped.zip"]
		and ModelPacks.find("wooden-chest", true).begins_with(ModelPacks.BUILTIN_DIR),
		"a pack taken out is off and its models aren't used: %s %s" % [titles.call("Available"), ModelPacks.find("wooden-chest", true)])
	# ▲ ▼: Wube3DP over FUE5, and its chest wins.
	(row_of.call("Selected", "builtin:wube3dp").find_child("up", true, false) as Button).pressed.emit()
	ModelLibrary._sources.erase("wooden-chest")
	check(titles.call("Selected") == ["Test belts", "Loose models", "Wube3DP (Adapted)", "FUE5 (Adapted)", "Placeholders"] + fac
		and ModelLibrary._source("wooden-chest").contains("/packs/wube3dp/"),
		"up moves a pack over the one above, used at once: %s %s" % [titles.call("Selected"), ModelLibrary._source("wooden-chest")])
	(row_of.call("Selected", "builtin:wube3dp").find_child("down", true, false) as Button).pressed.emit()
	check(titles.call("Selected") == ["Test belts", "Loose models", "FUE5 (Adapted)", "Wube3DP (Adapted)", "Placeholders"] + fac
		and ModelLibrary._source("wooden-chest").contains("/packs/fue5/"), "and down back: %s" % [titles.call("Selected")])
	# Placeholders moves and switches off; Factorio above it draws an assembler 2 as its picture, under it its model.
	var order_before: Variant = Settings.get_value("model_packs", "order")
	var off_before: Variant = Settings.get_value("model_packs", "off")
	if installed:
		check(not ModelLibrary.draws_sprite("assembling-machine-2"), "Placeholders above Factorio: its assembler 2 model")
		(row_of.call("Selected", "builtin:placeholders").find_child("down", true, false) as Button).pressed.emit()
		check(titles.call("Selected").slice(-2) == ["Factorio", "Placeholders"] and ModelLibrary.draws_sprite("assembling-machine-2")
			and ModelLibrary.mesh_for("assembling-machine-2") == null,
			"Placeholders moved under Factorio: the assembler 2 is Factorio's picture: %s" % [titles.call("Selected")])
	(row_of.call("Selected", "builtin:placeholders").find_child("remove", true, false) as Button).pressed.emit()
	check(titles.call("Available").has("Placeholders") and (Settings.get_value("model_packs", "off") as Array).has("builtin:placeholders")
		and ModelPacks.pack("builtin:placeholders").is_empty() and ModelPacks.find("assembling-machine-2", true) == "",
		"Placeholders switched off: its models aren't used")
	Settings.set_value("model_packs", "order", order_before)
	Settings.set_value("model_packs", "off", off_before)
	ModelLibrary.apply_packs()
	w._refresh()
	check(titles.call("Selected") == ["Test belts", "Loose models", "FUE5 (Adapted)", "Wube3DP (Adapted)", "Placeholders"] + fac,
		"the order put back: %s" % [titles.call("Selected")])
	# A pack's models, by family, and the search box.
	w.select_pack("builtin:fue5")
	w.finish_fill()
	var models: Node = w.find_child("Models", true, false)
	var fue5_buildings := ModelPacks.families_of(ModelPacks.pack("builtin:fue5")).keys()
	check(models.find_child("model-locomotive", true, false) != null and models.find_child("model-wooden-chest", true, false) != null
		and models.get_child_count() == fue5_buildings.size(),
		"FUE5's models listed, one a family: %d" % models.get_child_count())
	var search := w.find_child("Search", true, false) as LineEdit
	search.text = "loco"
	search.text_changed.emit("loco")
	check(models.get_child_count() == 1 and models.find_child("model-locomotive", true, false) != null, "the search box keeps the models it names")
	search.text = ""
	search.text_changed.emit("")
	# The middle column's tabs: Models, Items, Icons, Other, the pack's name before them.
	var tab_bar := w.find_child("Tabs", true, false) as Control
	var tab_names: Array = []
	for c in tab_bar.get_children():
		if c is Button:
			tab_names.append((c as Button).text)
	var models_tab := w.find_child("TabModels", true, false) as Button
	check(tab_names == ["Models", "Items", "Icons", "Tiles", "Decoratives", "Other"] and models_tab.button_pressed and w.current_tab() == "models"
		and (w.find_child("PackName", true, false) as Label).text == "FUE5:" and w.has_method("_fill_items_tab") and w.has_method("_fill_icons_tab") and w.has_method("_fill_tiles_tab") and w.has_method("_fill_decoratives_tab"),
		"six tabs in order, Models open, the pack's name before them: %s %s" % [tab_names, (w.find_child("PackName", true, false) as Label).text])
	# Placeholders' 348 families come in a slice a frame, "Loading... N / M" in the list's corner
	# until they are whole; no slice past the budget (the window holds no frame for half a second).
	var tab_list := func() -> Array:
		return models.get_children().filter(func(c: Node) -> bool: return c is Button).map(func(c: Node) -> String: return str(c.name).trim_prefix("model-"))
	var ph_families: Dictionary = ModelPacks.families_of(ModelPacks.pack("builtin:placeholders"))
	var loading := w.find_child("ModelsLoading", true, false) as Label
	w.fill_slice_max_usec = 0
	var pick_at := Time.get_ticks_usec()
	w.select_pack("builtin:placeholders")
	var pick_usec := Time.get_ticks_usec() - pick_at
	var first_count: int = tab_list.call().size()
	check(w.filling() and loading.visible and loading.is_visible_in_tree() and loading.text.begins_with("Loading... ")
		and loading.text.ends_with(" / %d" % ph_families.size()) and first_count > 0 and first_count < ph_families.size(),
		"a long list fills over frames, its loading line shown: %s, %d of %d at first" % [loading.text, first_count, ph_families.size()])
	# Another pack picked mid-fill: the old fill is dropped, nothing of Placeholders' left.
	w.select_pack("builtin:fue5")
	w.finish_fill()
	var fue5_now: Array = tab_list.call()
	check(not w.filling() and not loading.visible and fue5_now.size() == fue5_buildings.size()
		and fue5_now.all(func(f: String) -> bool: return fue5_buildings.has(f)),
		"a pack picked mid-fill drops the old fill: %d listed, %d FUE5's" % [fue5_now.size(), fue5_buildings.size()])
	# Each slice timed alone (one a frame: fill_slice_max_usec cleared before each). The typical slice
	# (the median) is judged against the budget closely and the worst only loosely: on a busy PC the
	# scheduler can stretch any one slice (7.7-10.7 ms measured), but not most of them. And no slice
	# holds half the fill's time: a fill done in one go (34 ms here, 514 ms before the families were
	# cached) is its own longest slice however the PC is loaded.
	w.fill_slice_max_usec = 0
	w.select_pack("builtin:placeholders")
	var slices: Array[int] = [w.fill_slice_max_usec]
	var frames := 1
	var longest_frame := 0
	var frame_at := Time.get_ticks_usec()
	while w.filling() and frames < 600:
		w.fill_slice_max_usec = 0
		await get_tree().process_frame
		slices.append(w.fill_slice_max_usec)
		longest_frame = maxi(longest_frame, Time.get_ticks_usec() - frame_at)
		frame_at = Time.get_ticks_usec()
		frames += 1
	var sorted_slices := slices.duplicate()
	sorted_slices.sort()
	var median_slice: int = sorted_slices[sorted_slices.size() / 2]
	var worst_slice: int = sorted_slices[-1]
	var fill_total := 0
	for u: int in slices:
		fill_total += u
	var in_models: Array = tab_list.call()
	print("  Placeholders' list: the pick %.1f ms, %d frames to fill, slices median %.1f ms, longest %.1f ms, the longest frame %.1f ms"
		% [pick_usec / 1000.0, frames, median_slice / 1000.0, worst_slice / 1000.0, longest_frame / 1000.0])
	check(frames > 2 and not w.filling() and not loading.visible and in_models.size() == ph_families.size(),
		"the list whole after %d frames, the loading line gone: %d of %d" % [frames, in_models.size(), ph_families.size()])
	check(median_slice < ModelPacksWindow.FILL_BUDGET_USEC + 5000 and worst_slice < 50000 and worst_slice * 2 < fill_total,
		"the fill's slices keep to its %.1f ms budget: median %.1f ms (under %.1f), the longest %.1f ms (under 50, and under half the fill's %.1f)"
		% [ModelPacksWindow.FILL_BUDGET_USEC / 1000.0, median_slice / 1000.0, (ModelPacksWindow.FILL_BUDGET_USEC + 5000) / 1000.0,
			worst_slice / 1000.0, fill_total / 1000.0])
	# Every entity model is in Models: buildings, and trees, rocks, ore, cliffs and creatures with them.
	var others := ["tree-01", "big-rock", "huge-rock", "iron-ore", "cliff", "big-worm-turret", "big-stomper-pentapod", "gleba-spawner", "fish", "crude-oil", "stone", "small-biter"]
	var buildings := ["assembling-machine-2", "beacon", "locomotive", "pipe", "straight-rail", "gun-turret", "rocket-silo", "stone-furnace"]
	var present := (others + buildings).filter(func(f: String) -> bool: return ph_families.has(f))
	check(present.size() >= 14 and present.all(func(f: String) -> bool: return in_models.has(f)) and in_models.has("tree-01") and in_models.has("big-rock"),
		"Models lists every family, trees, rocks and creatures with the buildings: %s of %s" % [present.filter(func(f: String) -> bool: return in_models.has(f)), present])
	# Other: kept for kinds of pack content to come, its note and no families.
	(w.find_child("TabOther", true, false) as Button).pressed.emit()
	var other_note := models.find_child("EmptyNote", true, false) as Label
	check(w.current_tab() == "other" and (w.find_child("TabOther", true, false) as Button).button_pressed and not models_tab.button_pressed
		and tab_list.call().is_empty() and other_note != null and other_note.text == "Nothing here yet: room for other kinds of pack content."
		and other_note.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER and not w.filling() and not loading.visible,
		"Other is empty for now, its note centred: %s" % [other_note.text if other_note != null else "none"])
	w.open_tab("models")
	search.text = "tree"
	search.text_changed.emit("tree")
	w.finish_fill()
	var trees: Array = tab_list.call()
	check(not trees.is_empty() and trees.size() < in_models.size() and trees.has("tree-01") and not trees.has("big-rock"),
		"the search box filters within the open tab: %s" % [trees])
	search.text = ""
	search.text_changed.emit("")
	w.finish_fill()
	await _model_packs_items(w, models, dir)
	await _model_packs_factorio(w, models)
	await _model_packs_ores(w)
	# Built-in Placeholders' 48 3D decoratives were removed (owner, 2a52be70): its Decoratives tab has none.
	w.select_pack("builtin:placeholders")
	(w.find_child("TabDecoratives", true, false) as Button).pressed.emit()
	w.finish_fill()
	var ph_dec_btns: Array = tab_list.call()
	check(models.find_child("decor-garballo", true, false) == null,
		"Placeholders' Decoratives tab lists none of the removed 3D decorative models: %d entries" % [ph_dec_btns.size()])
	# Empty-tab hooks: FUE5 has no tiles, no decoratives, and no icons.
	w.select_pack("builtin:fue5")
	for tab: Array in [["TabTiles", "tiles", "No tiles in this pack."], ["TabDecoratives", "decoratives", "No decoratives in this pack."], ["TabIcons", "icons", "No icons in this pack."]]:
		(w.find_child(tab[0], true, false) as Button).pressed.emit()
		var note := models.find_child("EmptyNote", true, false) as Label
		check(w.current_tab() == tab[1] and tab_list.call().is_empty() and note != null and note.text == tab[2]
			and note.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER,
			"the %s tab's hook shows its note: %s" % [tab[1], note.text if note != null else "none"])
	# The tab stays open as another pack is listed.
	w.select_pack("builtin:fue5")
	check(w.current_tab() == "icons" and (models.find_child("EmptyNote", true, false) as Label).text == "No icons in this pack.",
		"the open tab is kept when another pack is listed")
	# A pack's icons: a grid of them, one shown large beside Factorio's, Select and the order.
	w.select_pack("dir:Belts")
	var belt_icon := models.find_child("icon-transport-belt", true, false) as Button
	check(belt_icon != null and models.find_child("icon-fluid_water", true, false) != null and belt_icon.icon != null
		and belt_icon.icon.get_size() == Vector2(8, 8) and belt_icon.text != "",
		"the Icons tab lists the pack's icons, each its picture and name: %s" % [models.get_children().map(func(c: Node) -> String: return str(c.name))])
	var blue := ItemIcons.texture_for("transport-belt")
	check(blue != null and blue.get_image().get_pixel(0, 0) == Color(0, 0, 1), "the pack on top draws its icon in the UI")
	belt_icon.pressed.emit()
	var compare := w.find_child("IconCompare", true, false) as Control
	var pack_pic := w.find_child("PackIcon", true, false) as TextureRect
	check(compare != null and compare.visible and pack_pic.texture != null and pack_pic.texture.get_size() == Vector2(8, 8)
		and w.find_child("version-dir_Belts", true, false) != null and not (w.find_child("PreviewTools", true, false) as Control).visible,
		"a click shows the icon large in the preview, a flat picture beside Factorio's, its pack's card")
	(w.find_child("use-dir_Belts", true, false) as Button).pressed.emit()
	check(str((Settings.get_value("model_packs", "choices") as Dictionary).get("icon:transport-belt", "")) == "dir:Belts"
		and ModelPacks.icon_choice("transport-belt") == "dir:Belts" and not (w.find_child("UseOrder", true, false) as Button).disabled,
		"Select keeps the icon's choice as icon:<name>")
	(w.find_child("UseOrder", true, false) as Button).pressed.emit()
	check(not (Settings.get_value("model_packs", "choices") as Dictionary).has("icon:transport-belt") and ModelPacks.icon_choice("transport-belt") == "",
		"Use the pack order gives it back")
	w.open_tab("models")
	check(not compare.visible, "the other tabs hide the icons' picture")
	w.select_pack("builtin:fue5")
	# The listed pack's row in Factorio's selected orange, one at a time, moving on a click.
	var marked := func() -> Array:
		var out: Array = []
		for list: String in ["Available", "Selected"]:
			for row in w.find_child(list, true, false).get_children():
				if bool(row.get_meta("selected", false)):
					out.append(str(row.get_meta("pack")))
		return out
	var lit: StyleBox = ModelPacksWindow._row_style("selected")
	# The family grid's selected button: the row must draw what it draws (the same pictures, or
	# without the install the same flat colour) with its text colour. The old copy of a LayeredStyle
	# had no layers and drew nothing: only the text went dark.
	# One this pack draws (a dimmed one, another pack's, has its own grey text).
	var fam_button: Button = null
	for b in models.get_children():
		if b is Button and str(b.name).begins_with("model-") and not (b as Button).has_theme_color_override("font_color"):
			fam_button = b as Button
			break
	w.select_family(str(fam_button.name).trim_prefix("model-"))
	var button_style := fam_button.get_theme_stylebox("normal")
	var button_text := fam_button.get_theme_color("font_color")
	var same_look := func(a: StyleBox, b: StyleBox) -> bool:
		if a == null or b == null or a.get_class() != b.get_class() or a.get_script() != b.get_script():
			return false
		if a is StyleBoxFlat:
			return (a as StyleBoxFlat).bg_color == (b as StyleBoxFlat).bg_color
		if a.get_script() != null:
			var la: Array = a.get("layers")
			var lb: Array = b.get("layers")
			return not la.is_empty() and la.size() == lb.size() and la.all(func(l: StyleBox) -> bool: return lb.has(l))
		return a is StyleBoxTexture and (a as StyleBoxTexture).texture == (b as StyleBoxTexture).texture \
			and (a as StyleBoxTexture).region_rect == (b as StyleBoxTexture).region_rect
	var label_color := func(row: Control, key: String) -> Color:
		return (row.find_child(key, true, false) as Label).get_theme_color("font_color")
	var fue5_row := row_of.call("Selected", "builtin:fue5") as PanelContainer
	var wube_lit := row_of.call("Selected", "builtin:wube3dp") as PanelContainer
	check(fam_button.theme_type_variation == "FListItemSelected" and same_look.call(fue5_row.get_theme_stylebox("panel"), button_style)
		and label_color.call(fue5_row, "title") == button_text and label_color.call(fue5_row, "count") == button_text,
		"the listed pack's row draws the selected family button's style (%s, %s) and its text colour %s" % [button_style.get_class(),
			button_style.get("layers").size() if button_style.get_script() != null else -1, button_text])
	check(marked.call() == ["builtin:fue5"] and fue5_row.get_theme_stylebox("panel") == lit
		and wube_lit.get_theme_stylebox("panel") == ModelPacksWindow._row_style("normal")
		and not same_look.call(wube_lit.get_theme_stylebox("panel"), button_style)
		and label_color.call(wube_lit, "title") != button_text and label_color.call(wube_lit, "count") == Kit.DISABLED_TEXT,
		"the listed pack's row has the selected highlight, only it, the others plain: %s" % [marked.call()])
	# Drawn: a pixel of the lit row orange (only where headless renders; the dummy renderer has no picture).
	# The cause: a copied LayeredStyle (the install's pictures) kept no layers; headless has no atlas.
	var layered: StyleBox = (load("res://scripts/ui/factorio/layered_style.gd") as GDScript).new()
	(layered.get("layers") as Array).append(StyleBoxFlat.new())
	check((layered.duplicate() as StyleBox).get("layers").size() == 1, "a copied LayeredStyle keeps its layers")
	var shot: Image = null
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		shot = get_viewport().get_texture().get_image()
	if shot != null and not shot.is_empty():
		var at := Vector2i(fue5_row.get_global_rect().get_center()) + Vector2i(0, int(fue5_row.size.y * 0.3))
		at = at.clamp(Vector2i.ZERO, shot.get_size() - Vector2i.ONE)
		var px := shot.get_pixelv(at)
		check(px.r > 0.6 and px.g > 0.3 and px.b < 0.3, "the lit row drawn orange: %s at %s" % [px, at])
	# Hover: orange with dark text as a list's rows, back when the mouse leaves.
	wube_lit.mouse_entered.emit()
	check(wube_lit.get_theme_stylebox("panel") == ModelPacksWindow._row_style("hover") and label_color.call(wube_lit, "title") == Kit.BLACK,
		"a row under the mouse lit as the lists' rows are")
	wube_lit.mouse_exited.emit()
	check(wube_lit.get_theme_stylebox("panel") == ModelPacksWindow._row_style("normal") and label_color.call(wube_lit, "count") == Kit.DISABLED_TEXT,
		"and plain again once the mouse leaves")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	wube_lit.gui_input.emit(click)
	check(marked.call() == ["builtin:wube3dp"] and wube_lit.get_theme_stylebox("panel") == lit
		and label_color.call(wube_lit, "title") == button_text
		and fue5_row.get_theme_stylebox("panel") != lit and label_color.call(fue5_row, "count") == Kit.DISABLED_TEXT
		and w.selected_pack == "builtin:wube3dp",
		"a click on another pack moves the highlight: %s" % [marked.call()])
	var zip_row := row_of.call("Available", "zip:zipped.zip") as PanelContainer
	zip_row.gui_input.emit(click)
	check(marked.call() == ["zip:zipped.zip"] and same_look.call(zip_row.get_theme_stylebox("panel"), button_style),
		"in Available too: %s" % [marked.call()])
	w.select_pack("builtin:wube3dp")
	w.finish_fill()
	check(models.find_child("model-inserter", true, false) != null and (models.find_child("model-inserter", true, false) as Button).text.contains("(7)"),
		"a family's variants counted: the inserter's four directions and its arm's three parts")
	# Factorio's icons by the families' names, from the install (the same cache as the UI's).
	# (The window here is at its smallest, a list too narrow for icons: at a screen's size for these.)
	var small_size: Vector2 = (w as Control).size
	(w as Control).size = Vector2(1600, 900)
	await get_tree().process_frame
	await get_tree().process_frame
	w.load_icons_now()
	var no_icon := Button.new()
	w._set_family_icon(no_icon, "zz-not-a-prototype")
	w.load_icons_now()
	check(no_icon.icon == ModelPacksWindow.blank_icon() and str(no_icon.get_meta("family_icon")) == ""
		and ModelPacksWindow.blank_icon().get_width() == Kit.px(ModelPacksWindow.FAMILY_ICON)
		and no_icon.get_theme_constant("icon_max_width") == Kit.px(ModelPacksWindow.FAMILY_ICON),
		"a family that isn't a prototype keeps its text, behind a clear square as wide as an icon, so the names line up")
	no_icon.free()
	if ItemIcons.find_data_dir() == "":
		print("  (no Factorio install found: the family buttons' icons aren't checked)")
	else:
		var with_icons: Array = []
		for fam: String in ["inserter", "transport-belt", "iron-chest"]:
			var b := models.find_child("model-" + fam, true, false) as Button
			if b != null and b.icon != null and b.icon != ModelPacksWindow.blank_icon() and str(b.get_meta("family_icon", "")) == fam 					and b.icon == ModelPacksWindow.family_icon(fam):
				with_icons.append(fam)
		var listed := ["inserter", "transport-belt", "iron-chest"].filter(func(f: String) -> bool: return models.find_child("model-" + f, true, false) != null)
		check(not listed.is_empty() and with_icons == listed, "Wube3DP's families wear Factorio's icons by their names: %s of %s" % [with_icons, listed])
		check(ModelPacksWindow.family_icon("big-biter") != null and ModelPacksWindow.family_icon("tree-01") != null,
			"an entity without an item of its name (a biter, a tree) has its own icon")
	(w as Control).size = small_size
	await get_tree().process_frame
	var hidden_ok := true
	for b in models.get_children():
		if b is Button and (b as Button).icon != null:
			hidden_ok = false
	check(not w._icons_hidden or hidden_ok, "in a list too narrow for a name and its icon the icons step aside, the names whole")
	var arm_rows: Array = []
	for b in models.get_children():
		if str(b.name).begins_with("model-inserter-arm") or str(b.name).begins_with("model-character-"):
			arm_rows.append(str(b.name))
	check(arm_rows.is_empty(), "Wube3DP's list has no inserter arm or character part of its own: %s" % [arm_rows])
	w.select_family("inserter", "builtin:wube3dp")  # Wube3DP's, not FUE5's (one model with a rig) in use
	var arm_names: Array = []
	var inserter_choice := w._info.find_child("VariantChoice", true, false) as OptionButton
	if inserter_choice != null:
		for i in inserter_choice.item_count:
			arm_names.append(inserter_choice.get_item_text(i))
	check(inserter_choice != null and arm_names.has("Arm (upper)") and arm_names.has("Main model")
		and str(w.find_child("Preview", true, false).model).begins_with("inserter@"),
		"the inserter picked: the inserter shown, its arm's parts among its variants: %s" % [arm_names])
	w.select_family("")
	# The variant picker: a belt's main model first, the arrows and the dropdown show each variant.
	var vpreview = w.find_child("Preview", true, false)
	var picker_state := func() -> Array:
		var choice := w._info.find_child("VariantChoice", true, false) as OptionButton
		var n := w._info.find_child("VariantCount", true, false) as Label
		return [str(vpreview.model), choice.get_item_text(choice.selected) if choice != null else "", n.text if n != null else "",
			choice.tooltip_text if choice != null else ""]
	w.select_family("transport-belt", "builtin:wube3dp")
	check(picker_state.call() == ["transport-belt@builtin:wube3dp", "Main model", "1 / 3", "transport-belt"],
		"a belt's variant picker: its main model first, 1 of 3: %s" % [picker_state.call()])
	(w._info.find_child("VariantNext", true, false) as Button).pressed.emit()
	check(picker_state.call() == ["transport-belt-curve-left@builtin:wube3dp", "Curve left", "2 / 3", "transport-belt-curve-left"],
		"the next arrow previews the left curve, its readable name, its file's in the tooltip: %s" % [picker_state.call()])
	(w._info.find_child("VariantPrev", true, false) as Button).pressed.emit()
	(w._info.find_child("VariantPrev", true, false) as Button).pressed.emit()
	check(picker_state.call()[0] == "transport-belt-curve-right@builtin:wube3dp" and picker_state.call()[2] == "3 / 3",
		"the previous arrow goes round to the last: %s" % [picker_state.call()])
	var vchoice := w._info.find_child("VariantChoice", true, false) as OptionButton
	vchoice.select(1)
	vchoice.item_selected.emit(1)
	check(picker_state.call()[0] == "transport-belt-curve-left@builtin:wube3dp" and picker_state.call()[1] == "Curve left",
		"the dropdown previews the variant picked: %s" % [picker_state.call()])
	(w._info.find_child("show-dir_Belts", true, false) as Button).pressed.emit()
	check(picker_state.call() == ["transport-belt-curve-left@dir:Belts", "Curve left", "2 / 2", "transport-belt-curve-left"],
		"View on another pack with the variant keeps it: %s" % [picker_state.call()])
	(w._info.find_child("show-builtin_wube3dp", true, false) as Button).pressed.emit()
	(w._info.find_child("VariantNext", true, false) as Button).pressed.emit()
	(w._info.find_child("show-dir_Belts", true, false) as Button).pressed.emit()
	check(picker_state.call()[0] == "transport-belt@dir:Belts" and picker_state.call()[1] == "Main model",
		"View on a pack without the variant (no right curve) shows its main model: %s" % [picker_state.call()])
	check(str(ModelPacks.choices.get("transport-belt", "")) == "",
		"looking at variants chooses nothing")
	w.select_family("wooden-chest", "builtin:wube3dp")
	check(w._info.find_child("VariantPicker", true, false) == null, "a family of one model has no variant picker")
	w.select_family("")
	# A model turning in its preview, from the pack listed; every pack's version to look at.
	w.select_pack("builtin:wube3dp")
	# From Wube3DP's list the chest in use (FUE5's) comes first; Wube3DP's shown by its button.
	w.select_family("wooden-chest", "builtin:wube3dp")
	var preview = w.find_child("Preview", true, false)
	for i in 600:
		if preview.settled():
			break
		await get_tree().process_frame
	check(preview.model == "wooden-chest@builtin:wube3dp" and preview.shown_mesh != null and preview.shown_mesh == ModelLibrary.mesh_for("wooden-chest@builtin:wube3dp"),
		"the preview shows the pack's model, read on a worker: %s" % preview.model)
	# Play animation and the speaker in the preview's top right corner: a chest has nothing to play,
	# greyed with a reason.
	await get_tree().process_frame
	var play_button := w.find_child("PlayAnim", true, false) as Button
	var speaker := w.find_child("Speaker", true, false) as Button
	var tools := w.find_child("PreviewTools", true, false) as Control
	check(play_button != null and play_button.disabled and play_button.tooltip_text != "" and speaker != null
		and speaker.disabled and speaker.tooltip_text != "" and tools != null and tools.visible
		and tools.get_parent() == (preview as Control).get_parent() and play_button.mouse_filter == Control.MOUSE_FILTER_STOP
		and tools.mouse_filter == Control.MOUSE_FILTER_IGNORE and (tools.get_child(0) as Control).mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"a chest's Play animation and speaker, over the preview, greyed with a reason: %s | %s" % [play_button.tooltip_text if play_button != null else "none",
		speaker.tooltip_text if speaker != null else "none"])
	# The shown pack's credit in the preview's top left, over the picture, short of the corner's buttons,
	# taking no mouse; it follows View to another pack.
	var credit := w.find_child("Credit", true, false) as Label
	var credit_box := w.find_child("PreviewCredit", true, false) as Control
	var credit_in := func() -> bool:
		var pv := (preview as Control).get_global_rect().grow(0.5)
		var r := credit.get_global_rect()
		return (credit_box.visible and pv.encloses(credit_box.get_global_rect()) and not r.intersects(tools.get_global_rect())
			and r.position.x - pv.position.x <= Kit.px(16) and r.position.y - pv.position.y <= Kit.px(12))
	check(credit != null and credit.text == "© Wube Software · CC BY-NC · adapted" and credit_box.get_parent() == (preview as Control).get_parent()
		and credit_in.call() and credit.mouse_filter == Control.MOUSE_FILTER_IGNORE and credit_box.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and (credit_box.get_child(0) as Control).mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"Wube3DP's credit in the preview's top left, clear of Play and the speaker, taking no mouse: %s %s" % [credit.text if credit != null else "none",
		credit.get_global_rect() if credit != null else Rect2()])
	(w.find_child("show-builtin_fue5", true, false) as Button).pressed.emit()
	await get_tree().process_frame
	check(credit.text == "FUE5 (Hurricane and Nuke) · CC BY-NC-SA 3.0 · adapted" and credit_in.call(), "View FUE5's: its credit: %s" % credit.text)
	check(ModelPacksWindow.credit_line(ModelPacks.pack("builtin:placeholders")) == "Zenith · GPL-3.0"
		and ModelPacksWindow.credit_line({"info": {"author": "Vasillo", "licence": "© David (Vasillo), used in Zenith with his permission; not under Zenith's GPL licence"}}) == "© Vasillo · used with permission"
		and ModelPacksWindow.credit_line({"info": {"author": "Vasillo", "credit": "© Vasillo · used with permission"}}) == "© Vasillo · used with permission"
		and ModelPacksWindow.credit_line(w._pack_by_id("dir:Belts")) == "Tester" and w._pack_by_id("zip:zipped.zip").has("info") and ModelPacksWindow.credit_line(w._pack_by_id("zip:zipped.zip")) == ""
		and ModelPacksWindow.credit_line({"info": {}}) == "",
		"the credits: Placeholders', an older Zenith.zip's from its licence, an author alone, none without either")
	w.select_family("")
	await get_tree().process_frame
	check(not credit_box.visible, "no credit with no model shown")
	w.select_family("wooden-chest", "builtin:wube3dp")
	w.select_family("pumpjack", "builtin:placeholders")
	for i in 600:
		if preview.settled():
			break
		await get_tree().process_frame
	await get_tree().process_frame
	check(preview.model == "pumpjack@builtin:placeholders" and not play_button.disabled and play_button.tooltip_text == "Play animation",
		"a pumpjack can play: %s %s" % [preview.model, play_button.tooltip_text])
	play_button.pressed.emit()
	check(preview.is_playing() and play_button.tooltip_text == "Stop animation", "pressed it plays, the button says Stop animation")
	play_button.pressed.emit()
	check(not preview.is_playing() and play_button.tooltip_text == "Play animation", "pressed again it stops")
	if preview.sound_reason() == "":
		# The speaker is on by default: the pumpjack's working sound starts with its animation, the
		# speaker untouched.
		check(not speaker.disabled and speaker.button_pressed and preview.sounding_on() and speaker.tooltip_text.begins_with("Building sound on"),
			"the speaker on by default: %s" % speaker.tooltip_text)
		play_button.pressed.emit()
		for i in 600:
			if preview.sound_playing():
				break
			await get_tree().process_frame
		check(preview.sound_playing(), "playing, its working sound starts without pressing the speaker")
		speaker.button_pressed = false
		await get_tree().process_frame
		check(not preview.sounding_on() and not preview.sound_playing() and speaker.tooltip_text.begins_with("Building sound off"),
			"the speaker off: the sound stops: %s" % speaker.tooltip_text)
		play_button.pressed.emit()
		# Off holds for the next model while the window is open (and for the session).
		w.select_family("wooden-chest", "builtin:wube3dp")
		w.select_family("pumpjack", "builtin:placeholders")
		for i in 600:
			if preview.settled():
				break
			await get_tree().process_frame
		await get_tree().process_frame
		check(not speaker.button_pressed and not preview.sounding_on(), "off holds for the next model")
		speaker.button_pressed = true
		await get_tree().process_frame
		check(preview.sounding_on() and ModelPacksWindow.sound_choice, "the speaker on again")
	w.select_family("wooden-chest", "builtin:wube3dp")
	for i in 600:
		if preview.settled():
			break
		await get_tree().process_frame
	# A card per pack with a version: its picture, name, View and Select, the one in use tagged.
	var card_of := func(id: String) -> Control:
		return w.find_child("version-" + id.replace(":", "_"), true, false) as Control
	var tag_of := func(id: String) -> String:
		var card: Control = card_of.call(id)
		var words: Label = card.find_child("words", true, false) as Label if card != null else null
		return words.text if words != null else ""
	var cards_whole := true
	for id: String in ["builtin:wube3dp", "builtin:fue5"]:
		var card: Control = card_of.call(id)
		cards_whole = (cards_whole and card != null and (card.find_child("image", true, false) != null or card.find_child("picture", true, false) != null)
			and card.find_child("show-" + id.replace(":", "_"), true, false) is Button and card.find_child("use-" + id.replace(":", "_"), true, false) is Button)
	check(cards_whole and card_of.call("builtin:placeholders") == null
		and tag_of.call("builtin:fue5") == "In use (by the order)" and tag_of.call("builtin:wube3dp") == ""
		and (w.find_child("UseOrder", true, false) as Button).disabled,
		"a card for every pack with a version of it (picture, View, Select), FUE5's in use by the order: %s" % tag_of.call("builtin:fue5"))
	(w.find_child("use-builtin_wube3dp", true, false) as Button).pressed.emit()
	w.finish_fill()
	var selected := w.find_child("use-builtin_wube3dp", true, false) as Button
	check(Settings.get_value("model_packs", "choices") == {"wooden-chest": "builtin:wube3dp"} and ModelLibrary._source("wooden-chest").contains("/packs/wube3dp/")
		and (w.find_child("model-wooden-chest", true, false) as Button).text.begins_with("✔")
		and tag_of.call("builtin:wube3dp") == "In use (chosen)" and tag_of.call("builtin:fue5") == ""
		and selected.disabled and selected.text == "Selected" and not (w.find_child("UseOrder", true, false) as Button).disabled,
		"Select takes the model from that pack whatever the order, at once, its card tagged chosen: %s" % [Settings.get_value("model_packs", "choices")])
	(w.find_child("show-builtin_fue5", true, false) as Button).pressed.emit()
	check(preview.model == "wooden-chest@builtin:fue5" and (w.find_child("show-builtin_fue5", true, false) as Button).button_pressed
		and Settings.get_value("model_packs", "choices") == {"wooden-chest": "builtin:wube3dp"} and tag_of.call("builtin:wube3dp") == "In use (chosen)",
		"View shows another pack's version without changing what is in use: %s" % preview.model)
	# The shown card (its View pressed) in the left list's selected look and text colour, the others
	# plain (their "In use" green), and it follows View.
	var card_lit := func(id: String) -> bool:
		var card := card_of.call(id) as PanelContainer
		return card != null and card.get_theme_stylebox("panel") == ModelPacksWindow._row_style("selected", true) and same_look.call(card.get_theme_stylebox("panel"), button_style) \
			and label_color.call(card, "title") == button_text
	var card_plain := func(id: String) -> bool:
		var card := card_of.call(id) as PanelContainer
		return card != null and card.get_theme_stylebox("panel") == ModelPacksWindow._row_style("normal", true) and label_color.call(card, "title") != button_text
	check(card_lit.call("builtin:fue5") and card_plain.call("builtin:wube3dp") and label_color.call(card_of.call("builtin:wube3dp"), "words") == Kit.GREEN_TEXT,
		"the shown card draws the selected family button's style and text colour, the other plain")
	(w.find_child("show-builtin_wube3dp", true, false) as Button).pressed.emit()
	check(card_lit.call("builtin:wube3dp") and card_plain.call("builtin:fue5") and label_color.call(card_of.call("builtin:wube3dp"), "words") == button_text,
		"the selected look follows View, the shown card's In use in its text colour")
	(w.find_child("UseOrder", true, false) as Button).pressed.emit()
	check(Settings.get_value("model_packs", "choices") == {} and ModelLibrary._source("wooden-chest").contains("/packs/fue5/")
		and tag_of.call("builtin:fue5") == "In use (by the order)" and (w.find_child("UseOrder", true, false) as Button).disabled,
		"Use the pack order gives it back")
	w.choose_pack("inserter", "builtin:wube3dp")
	w.choose_pack("pipe", "builtin:placeholders")
	check((Settings.get_value("model_packs", "choices") as Dictionary).size() == 2 and not (w.find_child("ResetChoices", true, false) as Button).disabled,
		"two models chosen")
	(w.find_child("ResetChoices", true, false) as Button).pressed.emit()
	check(Settings.get_value("model_packs", "choices") == {} and ModelPacks.choices.is_empty() and (w.find_child("ResetChoices", true, false) as Button).disabled,
		"Reset choices clears them")
	# Opened from another pack's list, a model shows the version in use first, its pack's View pressed.
	w.select_pack("builtin:placeholders")
	w.select_family("beacon")
	var fue5_button := w.find_child("show-builtin_fue5", true, false) as Button
	var ph_button := w.find_child("show-builtin_placeholders", true, false) as Button
	check(preview.model == "beacon@builtin:fue5" and fue5_button != null and fue5_button.button_pressed
		and ph_button != null and not ph_button.button_pressed and tag_of.call("builtin:fue5") == "In use (by the order)",
		"a model opened from Placeholders' list shows FUE5's, the one in use, its View pressed: %s" % preview.model)
	ph_button.pressed.emit()
	check(preview.model == "beacon@builtin:placeholders" and (w.find_child("show-builtin_placeholders", true, false) as Button).button_pressed,
		"the other pack's View still shows its version: %s" % preview.model)
	# Clicked in a pack's own list, a model shows that pack's version, the one in use marked apart
	# (the owner: Wube3DP's burner inserter showed Zenith's).
	w.select_pack("builtin:placeholders")
	w.finish_fill()
	(w.find_child("model-beacon", true, false) as Button).pressed.emit()
	ph_button = w.find_child("show-builtin_placeholders", true, false) as Button
	fue5_button = w.find_child("show-builtin_fue5", true, false) as Button
	check(preview.model == "beacon@builtin:placeholders" and tag_of.call("builtin:fue5") == "In use (by the order)" and tag_of.call("builtin:placeholders") == ""
		and ph_button.button_pressed and not bool(ph_button.get_meta("in_use"))
		and not fue5_button.button_pressed and bool(fue5_button.get_meta("in_use")),
		"clicked in Placeholders' list, its beacon shown, FUE5's marked in use: %s" % preview.model)
	fue5_button.pressed.emit()
	fue5_button = w.find_child("show-builtin_fue5", true, false) as Button
	check(preview.model == "beacon@builtin:fue5" and fue5_button.button_pressed and bool(fue5_button.get_meta("in_use"))
		and Settings.get_value("model_packs", "choices") == {} and ModelPacks.choices.is_empty()
		and tag_of.call("builtin:fue5") == "In use (by the order)",
		"another pack's View shows its version without changing what is in use: %s" % preview.model)
	(w.find_child("show-builtin_placeholders", true, false) as Button).pressed.emit()
	check(preview.model == "beacon@builtin:placeholders" and Settings.get_value("model_packs", "choices") == {}
		and bool((w.find_child("show-builtin_fue5", true, false) as Button).get_meta("in_use")),
		"and back, still FUE5's in use: %s" % preview.model)
	# The preview fits the whole model in view whatever its shape: a flat resource off the tile's
	# middle, a wide cliff, a tall chimney, a tiny one.
	for fam: String in ["copper-ore", "cliff", "huge-rock", "beacon"]:
		w.select_family(fam)
		for i in 600:
			if preview.settled():
				break
			await get_tree().process_frame
		await get_tree().process_frame
		var seen := preview.shown_mesh != null
		for k in 8:
			seen = seen and preview.box_in_view(k * TAU / 8.0)
		check(seen, "the preview shows all of %s at every turn: %s, box %s" % [fam, preview.model, preview.model_box() if preview.shown_mesh != null else "none"])
	# And in a narrow card or a short strip, the model filling the picture's narrower side.
	for shape: Vector2 in [Vector2(120, 260), Vector2(600, 90)]:
		var card: Node = preview.get_script().new()
		card.size = shape
		add_child(card)
		for name: String in ["copper-ore@builtin:placeholders", "cliff-entrance@builtin:placeholders", "beacon"]:
			card.show_model(name)
			for i in 600:
				if card.settled():
					break
				await get_tree().process_frame
			await get_tree().process_frame
			var fits := card.shown_mesh != null
			var span := 0.0
			for k in 8:
				fits = fits and card.box_in_view(k * TAU / 8.0)
				var r: Rect2 = card.box_on_screen(k * TAU / 8.0)
				span = maxf(span, maxf(r.size.x / shape.x, r.size.y / shape.y))
			check(fits and span > 0.7, "a %dx%d preview shows all of %s, filling %.0f%% of it" % [shape.x, shape.y, name, span * 100.0])
		card.queue_free()
	# A zip being unpacked when its models are asked for: "Unpacking ...", then its models once in.
	var later := ZIPPacker.new()
	later.open(dir.path_join("later.zip"))
	later.start_file("later/pack.json")
	later.write_file(JSON.stringify({"name": "Later"}).to_utf8_buffer())
	later.close_file()
	later.start_file("later/iron-chest.glb")
	later.write_file(chest)
	later.close_file()
	later.close()
	ModelPacks.configure(dir, ModelLibrary._pack_ids(Settings, "order"), ModelLibrary._pack_ids(Settings, "off"))
	w._refresh()
	w.select_pack("zip:later.zip")
	var unpacking := w.find_child("Unpacking", true, false) as Label
	check(unpacking != null and unpacking.text.begins_with("Unpacking Later..."), "a zip being unpacked says so: %s" % (unpacking.text if unpacking != null else "none"))
	for i in 300:
		if w.find_child("model-iron-chest", true, false) != null:
			break
		await get_tree().process_frame
	check(w.find_child("model-iron-chest", true, false) != null and w.find_child("Unpacking", true, false) == null,
		"its models listed once it is unpacked, without opening the window again")
	# The downloads' bundled pack under its old name: an old Default.zip (pack.json "Default") saved
	# on top as "zip:Default.zip" is listed as Zenith in its place (over the saved packs; only Later,
	# new and not saved, above it), and saved again under Zenith's id.
	var old := ZIPPacker.new()
	old.open(dir.path_join("Default.zip"))
	old.start_file("pack.json")
	old.write_file(JSON.stringify({"name": "Default", "author": "Vasillo"}).to_utf8_buffer())
	old.close_file()
	old.start_file("steel-chest.glb")
	old.write_file(chest)
	old.close_file()
	old.close()
	var old_order: Array = ["zip:Default.zip"] + ModelLibrary._pack_ids(Settings, "order")
	Settings.set_value("model_packs", "order", old_order)
	ModelPacks.configure(dir, old_order, ModelLibrary._pack_ids(Settings, "off"))
	w._refresh()
	check(titles.call("Selected").slice(0, 3) == ["Later", "Zenith", "Test belts"] and row_of.call("Selected", ModelPacks.BUNDLED_ID) != null
		and not titles.call("Selected").has("Default") and not titles.call("Available").has("Default")
		and ModelPacks.saved_order().slice(0, 2) == ["zip:later.zip", ModelPacks.BUNDLED_ID] and not ModelPacks.saved_order().has("zip:Default.zip"),
		"an old Default.zip saved on top is the Zenith pack, in its place: %s %s" % [titles.call("Selected"), ModelPacks.saved_order()])
	ModelPacks.wait()
	# Variants (ModelPacks.variant_base): a pack's sulfur-1..3 one entry "Sulfur (3)", rock-big with its -1, -2 one
	# "(3)", numbered prototypes their own; its items/sulfur-1..2 one item, its icons/item/coal-1..2 one icon.
	for f in ["Varied/sulfur-1.glb", "Varied/sulfur-2.glb", "Varied/sulfur-3.glb", "Varied/rock-big.glb", "Varied/rock-big-1.glb",
			"Varied/rock-big-2.glb", "Varied/assembling-machine-2.glb", "Varied/items/sulfur-1.glb", "Varied/items/sulfur-2.glb"]:
		write.call(dir.path_join(f), chest)
	for f in ["Varied/icons/item/coal-1.png", "Varied/icons/item/coal-2.png"]:
		write.call(dir.path_join(f), icon_image.save_png_to_buffer())
	ModelPacks.configure(dir, ModelLibrary._pack_ids(Settings, "order"), ModelLibrary._pack_ids(Settings, "off"))
	ModelPacks.wait()
	w._refresh()
	w.select_pack("dir:Varied")
	(w.find_child("TabModels", true, false) as Button).pressed.emit()
	w.finish_fill()
	var varied := w.find_child("Models", true, false) as Node
	var listed_names := varied.get_children().map(func(c: Node) -> String: return str(c.name))
	var sulfur := varied.find_child("model-sulfur", true, false) as Button
	var rocks := varied.find_child("model-rock-big", true, false) as Button
	check(sulfur != null and sulfur.text.contains("(3)") and rocks != null and rocks.text.contains("(3)")
		and varied.find_child("model-sulfur-1", true, false) == null and varied.find_child("model-rock-big-2", true, false) == null
		and varied.find_child("model-assembling-machine-2", true, false) != null,
		"a pack's numbered variants one entry each: %s" % [listed_names])
	(w.find_child("TabItems", true, false) as Button).pressed.emit()
	w.finish_fill()
	check(varied.find_child("item-sulfur", true, false) != null and varied.find_child("item-sulfur-1", true, false) == null,
		"an item's variants one entry: %s" % [varied.get_children().map(func(c: Node) -> String: return str(c.name))])
	(w.find_child("TabIcons", true, false) as Button).pressed.emit()
	w.finish_fill()
	var coal_icon := varied.find_child("icon-item_coal", true, false) as Button
	check(coal_icon != null and coal_icon.icon != null and varied.find_child("icon-item_coal-1", true, false) == null,
		"an icon's variants one entry, its picture one of them: %s" % [varied.get_children().map(func(c: Node) -> String: return str(c.name))])
	(w.find_child("TabModels", true, false) as Button).pressed.emit()
	for f in ["Varied/sulfur-1.glb", "Varied/sulfur-2.glb", "Varied/sulfur-3.glb", "Varied/rock-big.glb", "Varied/rock-big-1.glb",
			"Varied/rock-big-2.glb", "Varied/assembling-machine-2.glb", "Varied/items/sulfur-1.glb", "Varied/items/sulfur-2.glb",
			"Varied/icons/item/coal-1.png", "Varied/icons/item/coal-2.png"]:
		DirAccess.remove_absolute(dir.path_join(f))
	for d in ["Varied/icons/item", "Varied/icons", "Varied/items", "Varied"]:
		DirAccess.remove_absolute(dir.path_join(d))
	ModelPacks.configure(dir, ModelLibrary._pack_ids(Settings, "order"), ModelLibrary._pack_ids(Settings, "off"))
	ModelPacks.wait()
	w._refresh()
	# Tiles & Decoratives tabs: list pack tiles (including PBR-only companion maps) and decoratives, show swatches, Select saves tile:/decor:<name>.
	var tile_img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	tile_img.fill(Color(0.2, 0.7, 0.25))
	var tile_bytes := tile_img.save_png_to_buffer()
	var nrm_img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	nrm_img.fill(Color(0.5, 0.5, 1.0))
	var hgt_img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	hgt_img.fill(Color(0.75, 0.75, 0.75))
	var dec_img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	dec_img.fill(Color(0.15, 0.8, 0.3))
	var dec_bytes := dec_img.save_png_to_buffer()
	write.call(dir.path_join("TilePack/tiles/grass-1.png"), tile_bytes)
	write.call(dir.path_join("TilePack/tiles/concrete/1.png"), tile_bytes)
	write.call(dir.path_join("TilePack/tiles/dirt-1-normal.png"), nrm_img.save_png_to_buffer())
	write.call(dir.path_join("TilePack/tiles/dirt-1-height.png"), hgt_img.save_png_to_buffer())
	write.call(dir.path_join("TilePack/decoratives/green-hairy-grass-1.png"), dec_bytes)
	write.call(dir.path_join("TilePack/decoratives/green-hairy-grass-2.png"), dec_bytes)
	write.call(dir.path_join("TilePack/decoratives/small-rock.png"), dec_bytes)
	ModelPacks.configure(dir, ModelLibrary._pack_ids(Settings, "order"), ModelLibrary._pack_ids(Settings, "off"))
	ModelPacks.wait()
	w._refresh()
	w.select_pack("dir:TilePack")
	(w.find_child("TabTiles", true, false) as Button).pressed.emit()
	w.finish_fill()
	var tile_grass := models.find_child("tile-grass-1", true, false) as Button
	var tile_concrete := models.find_child("tile-concrete", true, false) as Button
	var tile_dirt_pbr := models.find_child("tile-dirt-1", true, false) as Button
	check(w.current_tab() == "tiles" and tile_grass != null and tile_concrete != null and tile_dirt_pbr != null
		and tile_grass.icon != null and tile_grass.icon.get_size() == Vector2(8, 8) and tile_dirt_pbr.icon != null,
		"the Tiles tab lists the pack's tiles, digit-variant folders, and PBR-only tiles with swatches: %s" % [models.get_children().map(func(c: Node) -> String: return str(c.name))])
	if tile_grass != null:
		tile_grass.pressed.emit()
		check(compare != null and compare.visible and pack_pic.texture != null and pack_pic.texture.get_size() == Vector2(8, 8)
			and w.find_child("version-dir_TilePack", true, false) != null,
			"a clicked tile shows its swatch beside Factorio's and its pack's card")
		(w.find_child("use-dir_TilePack", true, false) as Button).pressed.emit()
		check(str((Settings.get_value("model_packs", "choices") as Dictionary).get("tile:grass-1", "")) == "dir:TilePack"
			and ModelPacks.tile_choice("grass-1") == "dir:TilePack" and not (w.find_child("UseOrder", true, false) as Button).disabled,
			"Select keeps the tile's choice as tile:<name>")
		(w.find_child("UseOrder", true, false) as Button).pressed.emit()
		check(not (Settings.get_value("model_packs", "choices") as Dictionary).has("tile:grass-1") and ModelPacks.tile_choice("grass-1") == "",
			"Use the pack order gives the tile back")
	(w.find_child("TabDecoratives", true, false) as Button).pressed.emit()
	w.finish_fill()
	var decor_grass := models.find_child("decor-green-hairy-grass", true, false) as Button
	var decor_rock := models.find_child("decor-small-rock", true, false) as Button
	check(w.current_tab() == "decoratives" and decor_grass != null and decor_rock != null and decor_grass.icon != null and decor_rock.icon != null,
		"the Decoratives tab groups numbered variants and lists pack decoratives with swatches: %s" % [models.get_children().map(func(c: Node) -> String: return str(c.name))])
	if decor_grass != null:
		decor_grass.pressed.emit()
		check(compare != null and compare.visible and pack_pic.texture != null and w.find_child("version-dir_TilePack", true, false) != null,
			"a clicked decorative shows its swatch beside Factorio's and its pack's card")
		(w.find_child("use-dir_TilePack", true, false) as Button).pressed.emit()
		check(str((Settings.get_value("model_packs", "choices") as Dictionary).get("decor:green-hairy-grass", "")) == "dir:TilePack"
			and ModelPacks.decor_choice("green-hairy-grass") == "dir:TilePack" and not (w.find_child("UseOrder", true, false) as Button).disabled,
			"Select keeps the decorative's choice as decor:<name>")
		(w.find_child("UseOrder", true, false) as Button).pressed.emit()
		check(not (Settings.get_value("model_packs", "choices") as Dictionary).has("decor:green-hairy-grass") and ModelPacks.decor_choice("green-hairy-grass") == "",
			"Use the pack order gives the decorative back")
	(w.find_child("TabModels", true, false) as Button).pressed.emit()
	for f in ["TilePack/tiles/grass-1.png", "TilePack/tiles/concrete/1.png", "TilePack/tiles/dirt-1-normal.png", "TilePack/tiles/dirt-1-height.png",
			"TilePack/decoratives/green-hairy-grass-1.png", "TilePack/decoratives/green-hairy-grass-2.png", "TilePack/decoratives/small-rock.png"]:
		DirAccess.remove_absolute(dir.path_join(f))
	for d in ["TilePack/tiles/concrete", "TilePack/tiles", "TilePack/decoratives", "TilePack"]:
		DirAccess.remove_absolute(dir.path_join(d))
	ModelPacks.configure(dir, ModelLibrary._pack_ids(Settings, "order"), ModelLibrary._pack_ids(Settings, "off"))
	ModelPacks.wait()
	w._refresh()
	# A pack holding a copy of the install's file (a stand-in install the test writes): "Checking..." while
	# it waits, then red with why and "Show the files" (pack_check.gd).
	var fake_data := _copy_fixture(dir.path_join("Copied/art/borrowed.png"), dir.get_base_dir().path_join("ui-test-fake-install"))
	write.call(dir.path_join("Copied/copied-chest.glb"), chest)
	ModelPacks.PackCheck.test_install = fake_data
	ModelPacks.configure(dir, ModelLibrary._pack_ids(Settings, "order"), ModelLibrary._pack_ids(Settings, "off"))
	w._refresh()
	var waiting_row: Node = row_of.call("Selected", "dir:Copied")
	var waiting_label := waiting_row.find_child("checking", true, false) as Label if waiting_row != null else null
	check(waiting_label != null and waiting_label.text == "Checking for copies of Factorio's files…",
		"a new pack's card says it is being checked: %s" % [waiting_label.text if waiting_label != null else waiting_row])
	ModelPacks.wait()
	w._refresh()
	var red_row: Node = row_of.call("Available", "dir:Copied")
	var card := red_row.find_child("refused", true, false) as Control if red_row != null else null
	var head := card.find_child("problem", true, false) as Label if card != null else null
	var why := card.find_child("why", true, false) as Label if card != null else null
	var files := card.find_child("files", true, false) as Label if card != null else null
	var show := card.find_child("show-files", true, false) as Button if card != null else null
	check(head != null and head.text == "Not loaded: this pack contains Factorio's own files" and head.get_theme_color("font_color") == Kit.RED_TEXT
		and why != null and why.text.begins_with("1 of its files is a copy of a file from your Factorio install, for example art/borrowed.png.")
		and why.get_theme_color("font_color") == Kit.RED_TEXT and (red_row.find_child("add", true, false) as Button).disabled,
		"the refused pack's card: in Available, red, why, its count and example, it can't be added: %s" % [why.text if why != null else red_row])
	check(show != null and show.text == "Show the files" and not files.visible, "the copies' list folded under \"Show the files\"")
	if show != null:
		show.button_pressed = true
		check(files.visible and files.text == "art/borrowed.png" and show.text == "Hide the files", "\"Show the files\" lists every copy, paths in the pack")
	w.select_pack("dir:Copied")
	check(w.find_child("Refused", true, false) != null and (w.find_child("Models", true, false) as Node).find_child("model-copied-chest", true, false) == null,
		"none of a refused pack's models listed")
	ModelPacks.PackCheck.test_install = null
	ModelPacks.PackCheck.forget()
	for f in ["Copied/art/borrowed.png", "Copied/copied-chest.glb"]:
		DirAccess.remove_absolute(dir.path_join(f))
	for d in ["Copied/art", "Copied"]:
		DirAccess.remove_absolute(dir.path_join(d))
	w.queue_free()
	await get_tree().process_frame
	await _model_packs_layout()
	await get_tree().process_frame
	Settings.set_value("model_packs", "order", order_was)
	Settings.set_value("model_packs", "off", off_was)
	Settings.set_value("model_packs", "choices", choices_was)
	ModelPacks.set_choices(saved_choices)
	ModelPacks.use(saved_packs)
	ModelPacks.folder = saved_folder
	ModelPacks.models_dir = saved_dir
	ModelLibrary.choices_changed([])
	for f in ["iron-chest.glb", "pack.json", "Belts/pack.json", "Belts/art/logo.png", "Belts/belts/transport-belt.glb", "Belts/belts/transport-belt-curve-left.glb", "zipped.zip", "later.zip", "Default.zip"]:
		DirAccess.remove_absolute(dir.path_join(f))


## The model preview draws a pack's belt, underground and splitter as the world draws a lone one: with
## the pack's `-start` and `-end` pieces where belt_end_places puts them (a belt both, an entrance its
## back, an exit its front, a splitter four), framed with them; a pack without the pieces, the model alone.


func _belt_preview_ends() -> void:
	var ModelPacks = ModelLibrary.ModelPacks
	var dir := OS.get_user_data_dir().path_join("ui-test-belt-ends")
	var write := func(path: String, from: String) -> void:
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(_own_glb(from))))
		f.close()
	var files := {"transport-belt": "transport-belt", "transport-belt-start": "wooden-chest", "transport-belt-end": "iron-chest",
		"splitter": "splitter", "underground-belt-input": "underground-belt-input", "underground-belt-output": "underground-belt-output",
		"transport-belt-curve-left": "transport-belt-curve-left", "transport-belt-curve-right": "transport-belt-curve-right"}
	for f: String in files:
		write.call(dir.path_join("Ends/%s.glb" % f), files[f])
	var saved_packs: Array = ModelPacks.packs
	var saved_folder: String = ModelPacks.folder
	var saved_dir: String = ModelPacks.models_dir
	ModelPacks.configure(dir, ["dir:Ends"], [])
	ModelPacks.wait()
	ModelLibrary.choices_changed([])
	var preview: Node = load("res://scripts/ui/factorio/model_preview.gd").new()
	preview.size = Vector2(240, 200)
	add_child(preview)
	var start_mesh := ModelLibrary.mesh_for("transport-belt-start@dir:Ends")
	var end_mesh := ModelLibrary.mesh_for("transport-belt-end@dir:Ends")
	var facing := Basis(Vector3.UP, PI / 2.0)  # the pieces run east as made: turned onto a north-facing belt
	for case: Array in [["transport-belt@dir:Ends", 2], ["underground-belt-input@dir:Ends", 1],
			["underground-belt-output@dir:Ends", 1], ["splitter@dir:Ends", 4], ["transport-belt@builtin:wube3dp", 0],
			# A curve none: Factorio has no lone curve (its entry is always fed from the side), so the curve alone,
			# as the world draws it inside a line, with no piece standing in its footprint.
			["transport-belt-curve-left@dir:Ends", 0], ["transport-belt-curve-right@dir:Ends", 0]]:
		preview.show_model(case[0])
		for i in 600:
			if preview.settled():
				break
			await get_tree().process_frame
		await get_tree().process_frame
		var got: Array = preview.find_children("BeltEnd*", "MeshInstance3D", true, false)
		var meshes := got.map(func(n: MeshInstance3D) -> Mesh: return n.mesh)
		var origins := got.map(func(n: MeshInstance3D) -> Vector3: return n.transform.origin.snapped(Vector3.ONE * 0.001))
		var fits: bool = preview.shown_mesh != null
		for k in 8:
			fits = fits and preview.box_in_view(k * TAU / 8.0)
		check(got.size() == case[1] and fits, "%s: %d end pieces, all in view as it turns: %d %s" % [case[0], case[1], got.size(), origins])
		if got.size() != case[1]:
			continue
		if str(case[0]).contains("-curve-"):
			check(preview.shown_mesh != null and preview.shown_mesh == ModelLibrary.mesh_for(case[0])
				and preview.find_children("BeltEnd*", "", true, false).is_empty(), "%s: the pack's curve alone, no end piece or its roller" % case[0])
		match str(case[0]).get_slice("@", 0):
			"transport-belt":
				if case[1] > 0:
					check(meshes.has(start_mesh) and meshes.has(end_mesh) and origins.all(func(o: Vector3) -> bool: return o == Vector3.ZERO)
						and got.all(func(n: MeshInstance3D) -> bool: return n.transform.basis.is_equal_approx(facing)),
						"a lone belt: its start and end piece on its tile, turned onto it as in the world")
			"underground-belt-input":
				check(meshes == [start_mesh] and origins == [Vector3.ZERO] and (got[0] as Node3D).transform.basis.is_equal_approx(facing),
					"an entrance: the start piece on its open back")
			"underground-belt-output":
				# The exit's model is turned round in the world (turn_dir), its open end ahead: the piece faces back in its space.
				check(meshes == [end_mesh] and (got[0] as Node3D).transform.basis.is_equal_approx(Basis(Vector3.UP, PI) * facing),
					"an exit: the end piece on its open front, turned against the model as in the world")
			"splitter":
				check(meshes.count(start_mesh) == 2 and meshes.count(end_mesh) == 2
					and origins.count(Vector3(-0.5, 0, 0)) == 2 and origins.count(Vector3(0.5, 0, 0)) == 2,
					"a lone splitter: a start and an end on each half: %s" % [origins])
	preview.queue_free()
	await get_tree().process_frame
	# The Model packs window's variant picker: a belt's family without its start and end pieces (the
	# world adds them; nobody builds one), its curves kept; other families as they are.
	var PacksWindow = load("res://scripts/menu/model_packs_window.gd")
	var family: Array = ModelPacks.family_names("transport-belt", [ModelPacks.pack("dir:Ends")])
	var picked: Array = PacksWindow.picker_variants("transport-belt", family)
	check(family.has("transport-belt-start") and family.has("transport-belt-end") and picked.has("transport-belt")
		and picked.has("transport-belt-curve-left") and picked.has("transport-belt-curve-right")
		and not picked.has("transport-belt-start") and not picked.has("transport-belt-end"),
		"the variant picker lists a belt's main model and curves, not its start and end pieces: %s of %s (pack %s, curve family %s)" % [picked, family, ModelPacks.pack("dir:Ends").get("models", {}).keys(), ModelPacks.family("transport-belt-curve-left")])
	for fam: String in ["express-transport-belt", "turbo-transport-belt"]:
		check(PacksWindow.picker_variants(fam, [fam, fam + "-curve-left", fam + "-start", fam + "-end"]) == [fam, fam + "-curve-left"],
			"%s: the picker without its pieces" % fam)
	var under := ["underground-belt-input", "underground-belt-output"]
	check(PacksWindow.picker_variants("underground-belt", under) == under, "an underground's picker keeps its entrance and exit")
	ModelPacks.use(saved_packs)
	# Pipes, heat pipes and walls: their sixteen shapes as Straight, Corner, T and Cross after the main
	# model, in every pack that has the kit (each label the shape's, each entry that file).
	var kits := {"pipe": ["pipe-straight-horizontal", "pipe-corner-up-right", "pipe-t-up", "pipe-cross"],
		"heat-pipe": ["heat-pipe-straight-horizontal", "heat-pipe-corner-up-right", "heat-pipe-t-up", "heat-pipe-cross"],
		"stone-wall": ["stone-wall-ew", "stone-wall-ne", "stone-wall-new", "stone-wall-nesw"]}
	var kits_seen := 0
	for pack_id: String in ["builtin:fue5", "builtin:placeholders", "builtin:wube3dp"]:
		for fam: String in kits:
			var names: Array = ModelPacks.family_names(fam, [ModelPacks.pack(pack_id)])
			if names.size() < 16:
				continue
			kits_seen += 1
			var list: Array = PacksWindow.picker_variants(fam, names)
			var labels := list.map(func(n: String) -> String: return PacksWindow.variant_label(fam, n))
			check(list == [fam] + kits[fam] and labels == ["Main model", "Straight", "Corner", "T", "Cross"],
				"%s in %s: the picker lists the main model, Straight, Corner, T, Cross (of %d files): %s %s" % [fam, pack_id, names.size(), list, labels])
	check(kits_seen >= 5, "pipes, heat pipes and walls found in FUE5, Placeholders and Wube3DP: %d kits" % kits_seen)
	check(PacksWindow.variant_label("straight-rail", "straight-rail-ne") != "Corner", "a rail's diagonal keeps its own label")
	ModelPacks.folder = saved_folder
	ModelPacks.models_dir = saved_dir
	ModelLibrary.choices_changed([])
	for f: String in files:
		DirAccess.remove_absolute(dir.path_join("Ends/%s.glb" % f))


## The Model packs window's layout, as the front end shows it (an overlay's centre, in a viewport of the
## screen's size): about 90% of the screen and inside it at 1280x720, 1920x1080 and 2560x1440, UI
## scale 1 and 1.5 (a live scale is the root's content scale: the window lays itself out in
## screen / scale); three columns, packs left, models middle, the preview widest on the right; every
## Selected row in view without scrolling at 1080p, and at every size each one in view once its list
## is scrolled to it, its list inside the window; no text cut off or outside the window, with the
## pack's details and with a model and its packs' buttons shown. Its own models folder: five packs in
## use over the three built in (more than a player with the downloads' Default.zip has) and one off,
## so it doesn't hang on what the models folder holds when the section runs alone.


func _model_packs_layout() -> void:
	var ModelPacks = ModelLibrary.ModelPacks
	var dir := OS.get_user_data_dir().path_join("ui-test-model-packs-layout")
	var chest := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(_own_glb("wooden-chest")))
	var fixture: Array = []
	for i in 6:
		var file := dir.path_join("Pack %d/wooden-chest.glb" % (i + 1))
		DirAccess.make_dir_recursive_absolute(file.get_base_dir())
		var f := FileAccess.open(file, FileAccess.WRITE)
		f.store_buffer(chest)
		f.close()
		fixture.append(file)
	var saved_folder: String = ModelPacks.folder
	var order_was: Variant = Settings.get_value("model_packs", "order")
	var off_was: Variant = Settings.get_value("model_packs", "off")
	Settings.set_value("model_packs", "order", [])
	Settings.set_value("model_packs", "off", ["dir:Pack 6"])
	# A seventh pack refused for a copy of the (stand-in) install's file: its red card in Available.
	var copy_file := dir.path_join("Pack 7/art/borrowed.png")
	var fake_data := _copy_fixture(copy_file, dir.path_join("fake-install"))
	var pack7 := dir.path_join("Pack 7/wooden-chest.glb")
	var f7 := FileAccess.open(pack7, FileAccess.WRITE)
	f7.store_buffer(chest)
	f7.close()
	ModelPacks.PackCheck.test_install = fake_data
	ModelPacks.configure(dir, [], ["dir:Pack 6"])
	ModelPacks.wait()
	ModelPacks.folder = dir
	var sizes := [Vector2(1280, 720), Vector2(1920, 1080), Vector2(2560, 1440)]
	for ui_scale: float in [1.0, 1.5]:
		for screen: Vector2 in sizes:
			var room := (screen * Kit.scale / ui_scale).floor()
			for fam: String in ["", "wooden-chest"]:
				var vp := SubViewport.new()
				vp.size = Vector2i(room)
				vp.disable_3d = false
				add_child(vp)
				var o := MenuKit.overlay(0.35)
				vp.add_child(o)
				var w: Node = ModelPacksWindow.new()
				w.selected_pack = "builtin:fue5"
				w.selected_family = fam
				MenuKit.overlay_center(o).add_child(w)
				for i in 4:
					await get_tree().process_frame
				var at := "%dx%d at %.1f%s" % [screen.x, screen.y, ui_scale, ", " + fam if fam != "" else ""]
				var red_card := w.find_child("refused", true, false) as Control
				var show_files := red_card.find_child("show-files", true, false) as Button if red_card != null else null
				if show_files != null:
					show_files.button_pressed = true  # the list of copies open: no text of the card cut off either
					for i in 2:
						await get_tree().process_frame
					var red_row := red_card.get_parent().get_parent().get_parent() as Control
					var card_in := true
					for part: String in ["problem", "why", "show-files", "files"]:
						card_in = card_in and red_row.get_global_rect().grow(0.5).encloses((red_card.find_child(part, true, false) as Control).get_global_rect())
					check(card_in, "the refused pack's card, its button and its list inside its row, %s" % at)
				else:
					check(false, "the refused pack's red card in the window, %s" % at)
				var win := (w as Control).get_global_rect()
				check(Rect2(Vector2.ZERO, room).grow(0.5).encloses(win), "the window inside the screen, %s: %s in %s" % [at, win, room])
				if fam == "" and ui_scale == 1.0 and screen == Vector2(1920, 1080):
					var share := win.size / room
					check(share.x > 0.87 and share.x < 0.93 and share.y > 0.87 and share.y < 0.93 and win.get_center().distance_to(room / 2.0) < 2.0,
						"the window takes about 90%% of a 1920x1080 screen, centred: %s" % share)
					var packs := (w.find_child("PacksColumn", true, false) as Control).get_global_rect()
					var models := (w.find_child("ModelsColumn", true, false) as Control).get_global_rect()
					var right := (w.find_child("PreviewColumn", true, false) as Control).get_global_rect()
					var preview := (w.find_child("Preview", true, false) as Control).get_global_rect()
					check(packs.end.x <= models.position.x and models.end.x <= right.position.x and packs.size.x < right.size.x
						and models.size.x < right.size.x and preview.size.x > 0.3 * room.x and preview.size.y > 0.45 * room.y,
						"packs, models and the preview side by side, the preview widest and large: %s %s %s, preview %s" % [packs.size, models.size, right.size, preview.size])
					var selected := w.find_child("Selected", true, false) as Control
					var scroll := selected.get_parent() as ScrollContainer
					var shown := scroll.get_global_rect().grow(0.5)
					var rows := 0
					var all_in := scroll.get_v_scroll_bar().max_value <= scroll.size.y + 1.0
					for row in selected.get_children():
						if row.has_meta("pack"):
							rows += 1
							all_in = all_in and shown.encloses((row as Control).get_global_rect())
					check(rows >= 8 and all_in, "every Selected row (%d, five packs over the three built in) in view without scrolling at 1080p" % rows)
					var grid := w.find_child("Models", true, false) as GridContainer
					check(grid.columns >= 2, "the models in columns as wide as fit: %d" % grid.columns)
				var sel := w.find_child("Selected", true, false) as Control
				var sel_scroll := sel.get_parent() as ScrollContainer
				var reach := sel_scroll.get_global_rect()
				var reached := win.grow(0.5).encloses(reach) and reach.size.y >= Kit.px(96) - 0.5
				var count := 0
				for row in sel.get_children():
					if row.has_meta("pack"):
						count += 1
						sel_scroll.ensure_control_visible(row as Control)
						await get_tree().process_frame
						reached = reached and reach.grow(0.5).encloses((row as Control).get_global_rect())
				sel_scroll.scroll_vertical = 0
				check(count >= 8 and reached, "each Selected row (%d) in view once scrolled to, its list (%s) in the window, %s" % [count, reach, at])
				var cut := _cut_text(w as Control)
				check(cut.is_empty(), "no text cut off in the Model packs window, %s: %s" % [at, cut])
				# The longest names on two lines where one column is too narrow for them, only those.
				var model_buttons: Array = (w.find_child("Models", true, false) as Node).get_children().filter(func(n: Node) -> bool: return n is Button)
				var wrapped: Array = model_buttons.filter(func(n: Node) -> bool: return (n as Button).autowrap_mode != TextServer.AUTOWRAP_OFF)
				if ui_scale == 1.5 and screen == Vector2(1280, 720):
					var high_ok := true
					for n: Node in wrapped:
						high_ok = high_ok and (n as Control).size.y > Kit.px(28) + 1.0
					check(not wrapped.is_empty() and wrapped.size() < model_buttons.size() and high_ok,
						"the longest names wrapped onto two lines, their buttons taller, the rest one line, %s: %d of %d" % [at, wrapped.size(), model_buttons.size()])
				elif ui_scale == 1.0:
					check(wrapped.is_empty(), "no name wrapped where it fits on one line, %s: %d" % [at, wrapped.size()])
				var middle := (w.find_child("ModelsColumn", true, false) as Control).get_global_rect().grow(0.5)
				var tabs_in := true
				for tab_name: String in ["PackName", "TabModels", "TabItems", "TabIcons", "TabTiles", "TabDecoratives", "TabOther"]:
					var tab_control := w.find_child(tab_name, true, false) as Control
					tabs_in = tabs_in and tab_control != null and tab_control.is_visible_in_tree() and middle.encloses(tab_control.get_global_rect())
				var lit_rows: Array = (w.find_child("Selected", true, false) as Node).get_children().filter(func(r: Node) -> bool: return bool(r.get_meta("selected", false)))
				check(tabs_in and lit_rows.size() == 1 and str(lit_rows[0].get_meta("pack")) == "builtin:fue5" and not w.filling()
					and not (w.find_child("ModelsLoading", true, false) as Control).visible,
					"the pack's name and the six tabs whole in the middle column, the listed pack's row lit, %s" % at)
				# The tabs spaced apart, not touching (those on one line).
				var tab_list: Array = (w._tab_buttons as Dictionary).values()
				var tabs_apart := tab_list.size() == 6
				for i in range(1, tab_list.size()):
					var prev := (tab_list[i - 1] as Control).get_global_rect()
					var next := (tab_list[i] as Control).get_global_rect()
					if absf(prev.position.y - next.position.y) < 1.0:
						tabs_apart = tabs_apart and next.position.x - prev.end.x >= Kit.px(2) - 0.5
				check(tabs_apart, "a gap between the middle column's tabs, %s" % at)
				# The pack rows' arrows off the row's right edge.
				var arrows_in := true
				for row in sel.get_children():
					var arrows := (row as Node).find_child("arrows", true, false) as Control
					if arrows != null:
						arrows_in = arrows_in and (row as Control).get_global_rect().end.x - arrows.get_global_rect().end.x >= Kit.px(2) - 0.5
				check(arrows_in, "the pack rows' arrows inside their row's margin, %s" % at)
				if ui_scale == 1.0:
					check(not w._icons_hidden, "the families' icons drawn beside their names, %s" % at)
				if fam != "":
					var pv_rect := (w.find_child("Preview", true, false) as Control).get_global_rect()
					var corner := w.find_child("PreviewTools", true, false) as Control
					var corner_rect := corner.get_global_rect()
					check(corner.visible and pv_rect.grow(0.5).encloses(corner_rect) and pv_rect.end.x - corner_rect.end.x <= Kit.px(12)
						and corner_rect.position.y - pv_rect.position.y <= Kit.px(12) and corner_rect.size.x < pv_rect.size.x * 0.5,
						"Play animation and the speaker in the preview's top right corner, %s: %s in %s" % [at, corner_rect, pv_rect])
					var credit_box := w.find_child("PreviewCredit", true, false) as Control
					var credit_rect := (w.find_child("Credit", true, false) as Control).get_global_rect()
					check(not credit_box.visible or (pv_rect.grow(0.5).encloses(credit_box.get_global_rect())
						and credit_rect.end.x <= corner_rect.position.x and credit_rect.position.x - pv_rect.position.x <= Kit.px(16)),
						"the pack's credit in the preview's top left, short of its buttons, %s: %s" % [at, credit_rect])
					var versions := w.find_child("Versions", true, false) as Control
					var cards_in := versions != null and versions.get_child_count() >= 2
					for card: Node in versions.get_children() if versions != null else []:
						var key := str(card.get_meta("pack", "")).replace(":", "_")
						cards_in = (cards_in and card.find_child("show-" + key, true, false) != null
							and card.find_child("use-" + key, true, false) != null)
					check(cards_in, "a card with View and Select for each pack with a chest (%d), %s" % [versions.get_child_count() if versions != null else 0, at])
					# Each card's buttons inside its margin and clear of its name and tag, at every width.
					var pad: float = Kit.px(w.CARD_PAD) - 0.5
					var cards_fit := versions != null
					var cards_bad := ""
					for card: Node in versions.get_children() if versions != null else []:
						var inner := (card as Control).get_global_rect().grow(-pad)
						var key := str(card.get_meta("pack", "")).replace(":", "_")
						for b_name: String in ["show-" + key, "use-" + key]:
							var b_rect := (card.find_child(b_name, true, false) as Control).get_global_rect()
							var ok := inner.encloses(b_rect)
							for l_name: String in ["title", "words"]:
								var l := card.find_child(l_name, true, false) as Control
								if l != null and l.get_global_rect().grow(-0.5).intersects(b_rect):
									ok = false
							if not ok:
								cards_fit = false
								cards_bad = "%s %s in %s" % [b_name, b_rect, (card as Control).get_global_rect()]
					check(cards_fit, "every card's View and Select inside its margin, no text under them, %s %s" % [at, cards_bad])
				vp.queue_free()
				await get_tree().process_frame
	ModelPacks.folder = saved_folder
	ModelPacks.PackCheck.test_install = null
	ModelPacks.PackCheck.forget()
	for file: String in [copy_file, pack7]:
		DirAccess.remove_absolute(file)
	DirAccess.remove_absolute(copy_file.get_base_dir())
	DirAccess.remove_absolute(pack7.get_base_dir())
	Settings.set_value("model_packs", "order", order_was)
	Settings.set_value("model_packs", "off", off_was)
	for file: String in fixture:
		DirAccess.remove_absolute(file)
		DirAccess.remove_absolute(file.get_base_dir())


## A stand-in install's data folder (`install`/data) with one file over 1 KB, and `copy` a copy of it
## (no file of Factorio's: bytes the test makes). Returns the data folder.


static func _copy_fixture(copy: String, install: String) -> String:
	var data := install.path_join("data")
	var bytes := PackedByteArray()
	bytes.resize(3000)
	for i in bytes.size():
		bytes[i] = (i * 31 + 7) % 251
	for path: String in [data.path_join("base/graphics/entity/borrowed.png"), copy]:
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(bytes)
		f.close()
	var info := FileAccess.open(data.path_join("base/info.json"), FileAccess.WRITE)
	info.store_string('{"name": "base", "version": "2.1.0"}')
	info.close()
	return data


## The labels and buttons under `root` whose text is cut off: outside `root` (or its scroll box's
## sides), wider than they are without wrapping, or with lines hidden when wrapping.


func _cut_text(root: Control) -> Array:
	var out: Array = []
	var bounds := root.get_global_rect().grow(0.5)
	for n in root.find_children("*", "Control", true, false):
		var c := n as Control
		if not c.is_visible_in_tree() or not (c is Label or c is Button):
			continue
		var text := str(c.get("text"))
		if text == "":
			continue
		var r := c.get_global_rect()
		var scroll: ScrollContainer = null
		var up := c.get_parent()
		while up != null and up != root:
			if up is ScrollContainer:
				scroll = up
				break
			up = up.get_parent()
		if scroll != null:
			var sr := scroll.get_global_rect().grow(0.5)
			if r.position.x < sr.position.x or r.end.x > sr.end.x:
				out.append("%s outside its list" % text.left(30))
		elif not bounds.encloses(r):
			out.append("%s outside the window" % text.left(30))
		var font := c.get_theme_font("font")
		var font_size := c.get_theme_font_size("font_size")
		if c is Label:
			var l := c as Label
			if l.autowrap_mode != TextServer.AUTOWRAP_OFF:
				if l.get_visible_line_count() < l.get_line_count():
					out.append("%s: %d of %d lines" % [text.left(30), l.get_visible_line_count(), l.get_line_count()])
			elif l.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING and font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > l.size.x + 1.0:
				out.append("%s: %.0f wide in %.0f" % [text.left(30), font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x, l.size.x])
		else:
			var b := c as Button
			var need: float = ModelPacksWindow.button_text_width(b) - 2.0
			if b.icon != null:
				var drawn := float(b.icon.get_width())
				if b.get_theme_constant("icon_max_width") > 0:
					drawn = minf(drawn, b.get_theme_constant("icon_max_width"))
				need += drawn + (b.get_theme_constant("h_separation") if b.text != "" else 0)
			if b.autowrap_mode != TextServer.AUTOWRAP_OFF:
				# A wrapped name: every line within the room beside its icon, all lines within its height.
				var one := ModelPacksWindow.button_text_width(b)
				var room := b.size.x - (need - one + 2.0)
				var style := b.get_theme_stylebox("normal")
				var high := b.size.y - (style.get_margin(SIDE_TOP) + style.get_margin(SIDE_BOTTOM) if style != null else 0.0)
				var text_room := room - (one - font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
				var lines := font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, text_room, font_size, -1,
					TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE)
				if lines.x > text_room + 1.0 or lines.y > high + 1.0:
					out.append("%s: %.0fx%.0f in %.0fx%.0f (wrapped)" % [text.left(30), lines.x, lines.y, text_room, high])
			elif need > b.size.x + 1.0:
				out.append("%s: %.0f wide in %.0f" % [text.left(30), need, b.size.x])
	return out


## M8: the model chooser (model_chooser.gd), from the Model button in a building's window: a card for
## every pack in use with a model of it, each with its preview; "This one" draws that building with
## the pack's model at once (its record's PACK_KEY, its chunk's MultiMesh of that model), kept for the
## save when the chunk comes again, the other chests unchanged; "Every one" takes the model for every
## one of its kind; mined, the choice is forgotten; Esc closes it.


func _model_chooser(hud) -> void:
	var ui = hud.ui
	var ModelPacks = ModelLibrary.ModelPacks
	var BuildingModels := preload("res://scripts/world/building_models.gd")
	var choices_was: Variant = Settings.get_value("model_packs", "choices")
	var saved_choices: Dictionary = ModelPacks.choices
	Settings.set_value("model_packs", "choices", {})
	ModelPacks.set_choices({})
	ModelLibrary.choices_changed(["wooden-chest"])
	var w := WorldMirror.new()
	add_child(w)
	w.protos = ProtoDB.new()
	w.protos.add_entities([[1, "wooden-chest", "container", -0.35, -0.35, 0.35, 0.35, 200, 180, 0, 1, 1]])
	var c := Vector2i(0, 0)
	var cv := ChunkView.new()
	cv.coord = c
	w.chunks[c] = cv
	w.add_child(cv)
	var unit := 9501
	BuildingModels.forget(Bridge.save_id, unit)
	w._add([unit, 1, 10 * 256 + 128, 10 * 256 + 128, 0, {}])
	w._add([unit + 1, 1, 12 * 256 + 128, 10 * 256 + 128, 0, {}])
	var usual := ModelLibrary.mesh_for_entity("wooden-chest", "container", {})
	var wube := ModelLibrary.mesh_for_entity("wooden-chest", "container", {ModelLibrary.PACK_KEY: "builtin:wube3dp"})
	cv.build_entities(w.protos, {}, null)
	check(usual != null and wube != null and usual != wube and cv._nodes.has(usual) and not cv._nodes.has(wube), "two chests, both the usual model")
	# The Model button in the building's window opens the chooser for it.
	var opened: Array = []
	var open_was: Callable = ui.screen.open_model
	var protos_was = ui.screen.protos
	var unit_was: int = ui.screen.unit
	var name_was: String = ui.screen.proto_name
	ui.screen.protos = w.protos
	ui.screen.unit = unit
	ui.screen.proto_name = "wooden-chest"
	ui.screen.open_model = func(u: int, n: String, t: String) -> void: opened.append([u, n, t])
	var button: Button = ui.screen.find_child("ModelButton", true, false)
	check(button != null and button.get_parent().get_child(button.get_parent().get_child_count() - 1) is Button, "the building's window has a Model button in its title bar")
	if button != null:
		button.pressed.emit()
	check(opened == [[unit, "wooden-chest", "container"]], "the Model button opens the chooser for the building: %s" % [opened])
	ui.screen.open_model = open_was
	ui.screen.protos = protos_was
	ui.screen.unit = unit_was
	ui.screen.proto_name = name_was
	var chooser = ui.model_chooser
	chooser.open(unit, "wooden-chest", "container", w)
	await get_tree().process_frame
	var card := func(id: String) -> Node: return chooser.find_child("card-" + id.replace(":", "_"), true, false)
	check(chooser.visible and card.call("builtin:wube3dp") != null and card.call("builtin:fue5") != null and card.call("builtin:placeholders") == null,
		"a card for every pack with a wooden chest (FUE5, Wube3DP; Placeholders has none)")
	var previews: Array = chooser.find_children("Preview", "", true, false)
	check(previews.size() == 2 and previews.any(func(p) -> bool: return p.model == "wooden-chest@builtin:wube3dp"), "each card previews its pack's model")
	check(previews.all(func(p) -> bool: return not p.sounding_on() and not p.sound_playing()), "the chooser's small previews stay silent")
	check((card.call("builtin:fue5").find_child("Marks", true, false) as Label).text.contains("this building"), "the one this building uses is marked")
	# This one: that building alone, at once.
	(card.call("builtin:wube3dp").find_child("ThisOne", true, false) as Button).pressed.emit()
	var rec = w.entities[unit]
	check(str(rec.extra.get(ModelLibrary.PACK_KEY, "")) == "builtin:wube3dp" and BuildingModels.pack_for(Bridge.save_id, unit) == "builtin:wube3dp"
		and w._dirty.has(c), "This one: the building's record takes Wube3DP, kept for the save, its chunk to be built again")
	cv.build_entities(w.protos, {}, null)
	check(cv._nodes.has(wube) and cv._nodes.has(usual), "drawn in Wube3DP's model's MultiMesh, the other chest still the usual")
	check((card.call("builtin:wube3dp").find_child("Marks", true, false) as Label).text.contains("this building")
		and (card.call("builtin:fue5").find_child("Marks", true, false) as Label).text.contains("every other one"),
		"the cards say which this building and the others use")
	# The chunk comes again (a reload of the chunk): the building keeps its model.
	cv.clear_entities()
	w.entities.clear()
	w._add([unit, 1, 10 * 256 + 128, 10 * 256 + 128, 0, {}])
	w._add([unit + 1, 1, 12 * 256 + 128, 10 * 256 + 128, 0, {}])
	cv.build_entities(w.protos, {}, null)
	check(str(w.entities[unit].extra.get(ModelLibrary.PACK_KEY, "")) == "builtin:wube3dp" and cv._nodes.has(wube), "kept when the chunk comes again")
	# Every one: the other chest too.
	(card.call("builtin:wube3dp").find_child("EveryOne", true, false) as Button).pressed.emit()
	cv.build_entities(w.protos, {}, null)
	check(Settings.get_value("model_packs", "choices") == {"wooden-chest": "builtin:wube3dp"} and cv._nodes.has(ModelLibrary.mesh_for_entity("wooden-chest", "container", {}))
		and ModelLibrary.mesh_for_entity("wooden-chest", "container", {}) == ModelLibrary.mesh_for("wooden-chest@builtin:wube3dp") and not cv._nodes.has(usual),
		"Every one: every chest from Wube3DP")
	(chooser.find_child("ByOrder", true, false) as Button).pressed.emit()
	(chooser.find_child("Usual", true, false) as Button).pressed.emit()
	var back := ModelLibrary.mesh_for_entity("wooden-chest", "container", {})
	cv.build_entities(w.protos, {}, null)
	check(Settings.get_value("model_packs", "choices") == {} and not w.entities[unit].extra.has(ModelLibrary.PACK_KEY) and cv._nodes.has(back)
		and back != ModelLibrary.mesh_for("wooden-chest@builtin:wube3dp") and BuildingModels.pack_for(Bridge.save_id, unit) == "",
		"By the order and Usual model give both back")
	# Mined: forgotten.
	(card.call("builtin:wube3dp").find_child("ThisOne", true, false) as Button).pressed.emit()
	w.handle({"t": "del", "u": unit})
	check(BuildingModels.pack_for(Bridge.save_id, unit) == "" and not w.entities.has(unit), "mined: its model goes with it")
	w._add([unit, 1, 10 * 256 + 128, 10 * 256 + 128, 0, {}])
	check(not w.entities[unit].extra.has(ModelLibrary.PACK_KEY), "one built again on its spot is drawn as every other")
	check(ui.escape() and not chooser.visible, "Esc closes the chooser")
	w.queue_free()
	await get_tree().process_frame
	Settings.set_value("model_packs", "choices", choices_was)
	ModelPacks.set_choices(saved_choices)
	ModelLibrary.choices_changed(["wooden-chest"])


## N8: the entity info's pack symbol. The pack that draws the hovered building, its picture on a frame
## action button in the title bar, its tooltip "Model: <pack>" and its credit; a building drawn by the
## order's pack, one with its own pack (the model chooser's, PACK_KEY) and one with no model (the Factorio
## pack's card, or nothing without an install). A click opens the Model packs window on that pack with the
## building's family shown (front_end.gd open_model_packs). The panel holds its building while the mouse
## is on it or heads for it, lets go as it turns away; --entity-info-pack=off: no symbol.


func _entity_info_pack(hud) -> void:
	var ui = hud.ui
	var ModelPacks = ModelLibrary.ModelPacks
	var EntityInfo := preload("res://scripts/ui/factorio/entity_info.gd")
	var choices_was: Variant = Settings.get_value("model_packs", "choices")
	var saved_choices: Dictionary = ModelPacks.choices
	Settings.set_value("model_packs", "choices", {})
	ModelPacks.set_choices({})
	ModelLibrary.choices_changed(["wooden-chest"])
	ui.close_all()
	var w := WorldMirror.new()
	add_child(w)
	w.protos = ProtoDB.new()
	w.protos.add_entities([[1, "wooden-chest", "container", -0.35, -0.35, 0.35, 0.35, 200, 180, 0, 1, 1],
		[2, "zz-no-model-chest", "container", -0.35, -0.35, 0.35, 0.35, 200, 180, 0, 1, 1]])
	var stand := GDScript.new()
	stand.source_code = "extends Node\nvar world\nvar combat\n"
	stand.reload()
	var p: Node = stand.new()
	p.world = w
	add_child(p)
	var rec := func(unit: int, proto: int, extra: Dictionary):
		var r := WorldMirror.Rec.new()
		r.key = unit
		r.unit = unit
		r.proto_id = proto
		r.fixed = Vector2i(unit * 256, 0)
		r.extra = extra
		w.entities[unit] = r  # the panel looks a held building up in the world again
		return r
	var chest = rec.call(9601, 1, {})
	var own = rec.call(9602, 1, {ModelLibrary.PACK_KEY: "builtin:wube3dp"})
	var none = rec.call(9603, 2, {})
	var einfo = ui.entity_info
	var player_was = einfo.player
	var open_was: Callable = einfo.open_pack
	einfo.player = p
	var button: Button = einfo.find_child("PackSymbol", true, false)
	einfo.show_entity(chest)
	await get_tree().process_frame
	einfo.player = p  # the HUD gives the panel its player every frame
	einfo.show_entity(chest)
	check(button != null and button.visible and einfo.pack_id == "builtin:fue5" and einfo.pack_family == "wooden-chest"
		and button.get_child_count() == 1 and button.mouse_filter == Control.MOUSE_FILTER_STOP,
		"N8: a wooden chest drawn by the order's FUE5: its pack symbol in the title bar, FUE5's picture: %s %s" % [einfo.pack_id, einfo.pack_family])
	check(button != null and button.tooltip_text.begins_with("Model: FUE5 (Adapted)") and button.tooltip_text.contains("CC BY-NC-SA 3.0"),
		"N8: its tooltip names the pack and its credit: %s" % (button.tooltip_text if button != null else ""))
	einfo.show_entity(own)
	check(button.visible and einfo.pack_id == "builtin:wube3dp" and button.tooltip_text.begins_with("Model: Wube3DP (Adapted)"),
		"N8: a chest with its own pack (the model chooser's) shows that pack: %s" % einfo.pack_id)
	einfo.show_entity(none)
	var factorio: String = str(ModelPacks.pack(ModelPacks.FACTORIO_ID).get("id", "")) if ModelPacks.factorio_usable() else ""
	check(einfo.pack_id == factorio and button.visible == (factorio != ""),
		"N8: a building no pack has a model of: the Factorio pack when it draws its card, else no symbol (%s)" % [einfo.pack_id])
	# The click: the entity info asks the HUD, the HUD the menus' window.
	var asked: Array = []
	einfo.open_pack = func(pack: String, fam: String) -> void: asked.append([pack, fam])
	einfo.show_entity(chest)
	button.pressed.emit()
	check(asked == [["builtin:fue5", "wooden-chest"]], "N8: a click asks for the Model packs window on FUE5, the wooden chest's family: %s" % [asked])
	var show_was: Callable = ui.show_model_packs
	var through: Array = []
	ui.show_model_packs = func(pack: String, fam: String) -> void: through.append([pack, fam])
	einfo.open_pack = open_was
	button.pressed.emit()
	check(through == [["builtin:fue5", "wooden-chest"]], "N8: and the HUD hands it to the menus (front_end.gd open_model_packs): %s" % [through])
	ui.show_model_packs = show_was
	var fe: Node = FrontEndScript.new()
	add_child(fe)
	await get_tree().process_frame
	fe.open_model_packs("builtin:fue5", "wooden-chest")
	await get_tree().process_frame
	var window: Node = fe._overlays.back().find_child("ModelPacksWindow", true, false) if not fe._overlays.is_empty() else null
	if window != null:
		window.finish_fill()
	var fam_button: Button = window.find_child("model-wooden-chest", true, false) if window != null else null
	check(window != null and window.selected_pack == "builtin:fue5" and window.selected_family == "wooden-chest" and window._shown_pack == "builtin:fue5"
		and fam_button != null and fam_button.theme_type_variation == "FListItemSelected",
		"N8: the Model packs window opens on FUE5's models, the wooden chest selected and shown in FUE5's version")
	fe._clear_overlays()
	fe.queue_free()
	await get_tree().process_frame
	einfo.player = p
	# Reaching it: the panel holds the chest while the mouse is on it or heads for it.
	einfo.show_entity(chest, Vector2(10, 300))
	await get_tree().process_frame
	einfo.player = p
	einfo.show_entity(chest, Vector2(10, 300))
	var rect: Rect2 = einfo.get_global_rect()
	var toward := rect.get_center()
	var start := Vector2(rect.position.x - 400.0, toward.y)
	einfo.show_entity(chest, start)
	einfo.show_entity(none, start.lerp(toward, 0.3))
	var held_on_way: bool = einfo.visible and is_same(einfo._seen_rec, chest) and einfo.pack_id == "builtin:fue5"
	einfo.show_entity(null, start.lerp(toward, 0.6))
	var held_null: bool = einfo.visible and is_same(einfo._seen_rec, chest)
	einfo.show_entity(none, toward)
	var held_on: bool = einfo.visible and is_same(einfo._seen_rec, chest)
	check(held_on_way and held_null and held_on, "N8: the chest held while the mouse crosses the world to the panel and rests on it: %s %s %s %s" % [held_on_way, held_null, held_on, rect])
	einfo.show_entity(none, Vector2(rect.position.x - 50.0, rect.end.y + 300.0))
	einfo.show_entity(none, Vector2(rect.position.x - 150.0, rect.end.y + 400.0))
	check(is_same(einfo._seen_rec, none), "N8: leaving it, away from it: the panel shows what is under the mouse again")
	einfo.show_entity(chest, start)
	einfo.show_entity(none, start + Vector2(0, 200))
	check(is_same(einfo._seen_rec, none), "N8: a mouse going elsewhere from the chest isn't held")
	# --entity-info-pack=off: no symbol, nothing held.
	EntityInfo.show_pack = false
	einfo._pack_seen = ""
	einfo.show_entity(chest, start)
	einfo.show_entity(none, start.lerp(toward, 0.3))
	check(not button.visible and einfo.pack_id == "" and is_same(einfo._seen_rec, none), "N8: --entity-info-pack=off: no pack symbol, nothing held")
	einfo.show_entity(chest)
	check(not button.visible, "N8: off, the chest's panel has no symbol")
	EntityInfo.show_pack = true
	einfo._pack_seen = ""
	# What has no unit number (a resource, a tree, a ghost without one): its key is its place, a String
	# (world.gd static_key). The pack line works for those too, no "String formatting error" every frame.
	w.protos.add_entities([[3, "iron-ore", "resource", -0.4, -0.4, 0.4, 0.4, 0, 0, 0, 1, 1],
		[4, "tree-01", "tree", -0.4, -0.4, 0.4, 0.4, 0, 0, 0, 1, 1],
		[5, "entity-ghost", "entity-ghost", -0.35, -0.35, 0.35, 0.35, 0, 0, 0, 1, 1]])
	var placed := func(proto: int, x: int, extra: Dictionary):
		var r := WorldMirror.Rec.new()
		r.key = WorldMirror.static_key(proto, x * 256, 512)
		r.unit = 0
		r.proto_id = proto
		r.fixed = Vector2i(x * 256, 512)
		r.extra = extra
		w.entities[r.key] = r
		return r
	for c in [[placed.call(3, 40, {"a": 300}), "iron-ore", "resource"], [placed.call(4, 41, {}), "tree-01", "tree"],
			[placed.call(5, 42, {"gh": 1}), "wooden-chest", "container"]]:
		var r = c[0]
		einfo.show_entity(r)
		var want := str(ModelLibrary.drawing_pack(c[1], c[2], r.extra, r.dir).get("id", ""))
		check(einfo._pack_seen.begins_with(str(r.key) + "|") and einfo.pack_id == want and button.visible == (want != "")
			and is_same(einfo._seen_rec, r),
			"N8: %s (key %s, no unit number): its pack line worked out, %s shown (%s)" % [c[1], r.key, want, einfo._pack_seen])
	# Pack preview reuse & static freeze (hovering between 2D PNG and 3D-thumbnail packs never recreates the SubViewport).
	var ph = placed.call(4, 41, {})  # tree-01 -> builtin:placeholders (no pack.png)
	einfo.player = p
	einfo.show_entity(ph)
	var pv1 = einfo._pack_preview
	for i in 120:
		await get_tree().process_frame
		einfo.player = p
		einfo.show_entity(ph)
		if pv1 != null and pv1.model != "" and pv1.settled() and not pv1.is_processing():
			break
	check(pv1 != null and pv1.visible and button.get_child_count() == 1
		and pv1.viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"N8 cache: a pack without a PNG uses the persistent thumbnail preview and freezes it once settled (pv=%s vis=%s ch=%d mode=%d proc=%s settled=%s model=%s sz=%s rsz=%s still=%d)"
		% [pv1 != null, pv1.visible if pv1 else false, button.get_child_count(), pv1.viewport.render_target_update_mode if pv1 else -1,
		pv1.is_processing() if pv1 else false, pv1.settled() if pv1 else false, pv1.model if pv1 else "",
		pv1.viewport.size if pv1 else Vector2i.ZERO, pv1._rendered_size if pv1 else Vector2i.ZERO, pv1._still_renders if pv1 else -1])
	einfo.show_entity(chest)  # chest -> builtin:fue5, whose logo.png is bundled (wube3dp's wube-logo.png needs a Factorio install)
	check(is_same(einfo._pack_preview, pv1) and not pv1.visible
		and pv1.viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"N8 cache: switching to a PNG pack hides and pauses the reusable preview without freeing it")
	einfo.show_entity(ph)
	check(is_same(einfo._pack_preview, pv1) and pv1.visible and button.get_child_count() == 1
		and pv1.viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"N8 cache: switching back to the already-rendered pack keeps the same preview and stays frozen (mode=%d proc=%s still=%d sz=%s rsz=%s)"
		% [pv1.viewport.render_target_update_mode, pv1.is_processing(), pv1._still_renders, pv1.viewport.size, pv1._rendered_size])
	# hinfo in-flight throttle: at most one un-answered hover query in flight at a time.
	if ui.model._hinfo_pending:
		ui.model.handle({"t": "hinfo", "q": ui.model._hinfo_q, "u": ui.model._hinfo_unit})
	sent()
	ui.model.ask_hover_info(9901, 1, Vector2i(256, 256))
	var first_hask := sent_one("hinfo")
	ui.model.ask_hover_info(9902, 1, Vector2i(512, 256))
	var throttled_hask := sent_one("hinfo")
	ui.model.handle({"t": "hinfo", "q": int(first_hask.get("q", 0)), "u": 9901})
	ui.model.ask_hover_info(9902, 1, Vector2i(512, 256))
	var resumed_hask := sent_one("hinfo")
	if not resumed_hask.is_empty():
		ui.model.handle({"t": "hinfo", "q": int(resumed_hask.get("q", 0)), "u": 9902})
	check(int(first_hask.get("u", 0)) == 9901 and throttled_hask.is_empty() and int(resumed_hask.get("u", 0)) == 9902,
		"N8 hinfo throttle: second entity waits while the first query is in flight (%s, %s, %s; pending=%s unit=%d msec=%d now=%d)"
		% [first_hask, throttled_hask, resumed_hask, ui.model._hinfo_pending, ui.model._hinfo_unit, ui.model._hinfo_msec, Time.get_ticks_msec()])
	# Fast-motion hover gate: whipping past an entity skips panel rebuilds until motion slows.
	einfo.show_entity(chest, Vector2(10, 10), false)
	var after_chest := is_same(einfo._seen_rec, chest)
	sent()
	einfo.show_entity(own, Vector2(500, 10), true)
	var skipped_fast: bool = is_same(einfo._seen_rec, chest) and sent_one("hinfo").is_empty()
	einfo.show_entity(own, Vector2(502, 10), false)
	check(skipped_fast and is_same(einfo._seen_rec, own) and einfo.pack_id == "builtin:wube3dp",
		"N8 fast gate: fast camera/mouse skips transient hover switches and catches up once slow (after_chest=%s skipped=%s own=%s pack=%s vis=%s)"
		% [after_chest, skipped_fast, is_same(einfo._seen_rec, own), einfo.pack_id, einfo.visible])
	einfo.show_entity(null)
	einfo.player = player_was
	einfo.open_pack = open_was
	p.queue_free()
	w.queue_free()
	await get_tree().process_frame
	Settings.set_value("model_packs", "choices", choices_was)
	ModelPacks.set_choices(saved_choices)
	ModelLibrary.choices_changed(["wooden-chest"])
	sent()


## N8, the testing agent's cases: a pack switched off, a zip pack (also while it is still unpacking), the
## held building's chunk rebuilt or the building mined while the panel holds it, the panel's empty area
## leaving clicks to the world (only the symbol takes the mouse), a real click on the symbol, the hold
## timing out at HOLD_MSEC, a captured mouse (first person) and the map's patch, a second building
## crossed on the way, Esc closing the window the symbol opened.
## Spikes part B: while the character runs, the hover panel is rebuilt at most every RUN_REBUILD_MSEC (a new entity
## under the cursor waits, the last one shown); standing, or with --hover-rate=off, at once as before.


func _hover_run_rate(hud) -> void:
	var ui = hud.ui
	ui.close_all()
	var w := WorldMirror.new()
	add_child(w)
	w.protos = ProtoDB.new()
	w.protos.add_entities([[1, "wooden-chest", "container", -0.35, -0.35, 0.35, 0.35, 200, 180, 0, 1, 1],
		[2, "iron-chest", "container", -0.35, -0.35, 0.35, 0.35, 200, 180, 0, 1, 1]])
	var stand := GDScript.new()
	stand.source_code = "extends Node\nvar world\nvar combat\n"
	stand.reload()
	var p: Node = stand.new()
	p.world = w
	add_child(p)
	var rec := func(unit: int, proto: int):
		var r := WorldMirror.Rec.new()
		r.key = unit
		r.unit = unit
		r.proto_id = proto
		r.fixed = Vector2i(unit * 256, 0)
		w.entities[unit] = r
		return r
	var a = rec.call(9801, 1)
	var b = rec.call(9802, 2)
	var einfo = ui.entity_info
	var player_was = einfo.player
	var rate_was: bool = EntityInfoScript.run_rate
	EntityInfoScript.run_rate = true
	einfo.player = p
	einfo.show_entity(a, Vector2.INF, false, true)
	var built: int = einfo.rebuilds
	check(einfo.visible and einfo._seen_rec == a, "hover rate: the first entity while running is shown at once")
	einfo.show_entity(b, Vector2.INF, false, true)
	check(einfo._seen_rec == a and einfo.rebuilds == built and einfo.held_backs >= 1,
		"hover rate: running, a new entity within %d ms waits, the last one shown" % einfo.RUN_REBUILD_MSEC)
	einfo._rebuilt_msec -= einfo.RUN_REBUILD_MSEC + 1
	einfo.show_entity(b, Vector2.INF, false, true)
	check(einfo._seen_rec == b and einfo.rebuilds == built + 1, "hover rate: once the time is up it is rebuilt for the new one")
	einfo.show_entity(a, Vector2.INF, false, false)
	check(einfo._seen_rec == a and einfo.rebuilds == built + 2, "hover rate: standing, rebuilt at once as before")
	EntityInfoScript.run_rate = false
	einfo.show_entity(b, Vector2.INF, false, true)
	check(einfo._seen_rec == b and einfo.rebuilds == built + 3, "hover rate: --hover-rate=off, rebuilt at once while running too")
	EntityInfoScript.run_rate = rate_was
	einfo.show_entity(null)
	einfo.player = player_was
	p.queue_free()
	w.queue_free()
	await get_tree().process_frame


func _entity_info_pack_edges(hud) -> void:
	var ui = hud.ui
	var ModelPacks = ModelLibrary.ModelPacks
	var EntityInfo := preload("res://scripts/ui/factorio/entity_info.gd")
	var saved_packs: Array = ModelPacks.packs
	var saved_folder: String = ModelPacks.folder
	var saved_dir: String = ModelPacks.models_dir
	var saved_choices: Dictionary = ModelPacks.choices
	var choices_was: Variant = Settings.get_value("model_packs", "choices")
	Settings.set_value("model_packs", "choices", {})
	ModelPacks.set_choices({})
	ModelLibrary.choices_changed(["wooden-chest"])
	ui.close_all()
	var w := WorldMirror.new()
	add_child(w)
	w.protos = ProtoDB.new()
	w.protos.add_entities([[1, "wooden-chest", "container", -0.35, -0.35, 0.35, 0.35, 200, 180, 0, 1, 1],
		[2, "iron-chest", "container", -0.35, -0.35, 0.35, 0.35, 200, 180, 0, 1, 1]])
	var cv := ChunkView.new()
	cv.coord = Vector2i(0, 0)
	w.chunks[Vector2i(0, 0)] = cv
	w.add_child(cv)
	var stand := GDScript.new()
	stand.source_code = "extends Node\nvar world\nvar combat\n"
	stand.reload()
	var p: Node = stand.new()
	p.world = w
	add_child(p)
	var unit := 9701
	w._add([unit, 1, 10 * 256 + 128, 10 * 256 + 128, 0, {}])
	w._add([unit + 1, 2, 14 * 256 + 128, 10 * 256 + 128, 0, {}])
	var einfo = ui.entity_info
	var player_was = einfo.player
	var open_was: Callable = einfo.open_pack
	var button: Button = einfo.find_child("PackSymbol", true, false)
	var show := func(r, mouse := Vector2.INF) -> void:
		einfo.player = p  # the HUD gives the panel its player every frame
		einfo.show_entity(r, mouse)
	show.call(w.entities[unit])
	await get_tree().process_frame
	show.call(w.entities[unit])
	var usual: String = einfo.pack_id
	check(usual != "", "edges: the chest's pack before the changes: %s" % usual)

	# A pack switched off: the symbol follows the pack that draws it now, and a building's own pack
	# that is off isn't claimed.
	var order: Array = ModelLibrary._pack_ids(Settings, "order")
	ModelPacks.configure(ModelPacks.models_dir, order, [usual])
	ModelPacks.wait()
	ModelLibrary.choices_changed([])
	show.call(w.entities[unit])
	var after_off: String = einfo.pack_id
	var mesh_now = ModelLibrary.mesh_for_entity("wooden-chest", "container", {})
	check(after_off != usual and after_off != "" and button.visible and button.tooltip_text.begins_with("Model: " + str(ModelPacks.pack(after_off).get("title", "?"))),
		"edges: %s switched off: the symbol shows the pack drawing the chest now, %s" % [usual, after_off])
	w.entities[unit].extra[ModelLibrary.PACK_KEY] = usual
	show.call(w.entities[unit])
	check(einfo.pack_id != usual and ModelLibrary.mesh_for_entity("wooden-chest", "container", {ModelLibrary.PACK_KEY: usual}) == mesh_now,
		"edges: a chest whose own pack (%s) is off is drawn by the order, and the symbol says so: %s" % [usual, einfo.pack_id])
	w.entities[unit].extra.erase(ModelLibrary.PACK_KEY)

	# A zip pack on top: its picture, its name, its id for the window; also while still unpacking.
	var dir := OS.get_user_data_dir().path_join("ui-test-einfo-packs")
	DirAccess.make_dir_recursive_absolute(dir)
	var chest := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(_own_glb("wooden-chest")))
	var zip := ZIPPacker.new()
	zip.open(dir.path_join("einfo.zip"))
	zip.start_file("einfo/pack.json")
	zip.write_file(JSON.stringify({"name": "Zipped chests", "author": "Tester", "licence": "CC0"}).to_utf8_buffer())
	zip.close_file()
	zip.start_file("einfo/wooden-chest.glb")
	zip.write_file(chest)
	zip.close_file()
	zip.close()
	ModelPacks.configure(dir, ["zip:einfo.zip"] + order, [])
	show.call(w.entities[unit])
	var while_unpacking: String = einfo.pack_id
	ModelPacks.wait()
	ModelLibrary.choices_changed([])
	show.call(w.entities[unit])
	check(einfo.pack_id == "zip:einfo.zip" and button.visible and button.tooltip_text.begins_with("Model: Zipped chests") and button.get_child_count() == 1,
		"edges: a chest drawn by a zip pack shows it (unpacking: '%s'): %s | %s" % [while_unpacking, einfo.pack_id, button.tooltip_text])
	var asked: Array = []
	einfo.open_pack = func(pack: String, fam: String) -> void: asked.append([pack, fam])
	button.pressed.emit()
	check(asked == [["zip:einfo.zip", "wooden-chest"]], "edges: the zip pack's symbol opens the window on it: %s" % [asked])
	var fe: Node = FrontEndScript.new()
	add_child(fe)
	await get_tree().process_frame
	fe.open_model_packs("zip:einfo.zip", "wooden-chest")
	await get_tree().process_frame
	var window: Node = fe._overlays.back().find_child("ModelPacksWindow", true, false) if not fe._overlays.is_empty() else null
	if window != null:
		window.finish_fill()
	check(window != null and window.selected_pack == "zip:einfo.zip" and window.selected_family == "wooden-chest"
		and window.find_child("model-wooden-chest", true, false) != null,
		"edges: the Model packs window opens on the zip pack, the chest's family listed and selected")
	# Esc closes the window the symbol opened (its own Esc, as from the menus).
	if window != null:
		var esc := InputEventKey.new()
		esc.pressed = true
		esc.physical_keycode = KEY_ESCAPE
		esc.keycode = KEY_ESCAPE
		window._unhandled_input(esc)
	await get_tree().process_frame
	check(fe._overlays.is_empty(), "edges: Esc closes the Model packs window opened from the symbol")
	fe._clear_overlays()
	fe.queue_free()
	await get_tree().process_frame
	einfo.open_pack = open_was
	ModelPacks.configure(saved_dir, order, ModelLibrary._pack_ids(Settings, "off"))
	ModelPacks.wait()
	ModelPacks.use(saved_packs)
	ModelPacks.folder = saved_folder
	ModelPacks.models_dir = saved_dir
	ModelLibrary.choices_changed([])
	DirAccess.remove_absolute(dir.path_join("einfo.zip"))

	# The hold, measured on the panel where it is drawn.
	show.call(w.entities[unit], Vector2(1, 1))
	await get_tree().process_frame
	show.call(w.entities[unit], Vector2(1, 1))
	var rect: Rect2 = einfo.get_global_rect()
	var view: Rect2 = get_viewport().get_visible_rect()
	print("edges: panel ", rect, " view ", view)
	var on := rect.get_center() + Vector2(0, rect.size.y * 0.3)  # the panel's body, away from the title bar
	var start := Vector2(rect.position.x - 400.0, on.y)

	# The chunk comes again while the panel holds the chest: the held record is the old one.
	show.call(w.entities[unit], start)
	show.call(null, on)
	var old_rec = w.entities[unit]
	w.entities.clear()
	w._add([unit, 1, 10 * 256 + 128, 10 * 256 + 128, 0, {ModelLibrary.PACK_KEY: "builtin:wube3dp"}])
	w._add([unit + 1, 2, 14 * 256 + 128, 10 * 256 + 128, 0, {}])
	show.call(null, on)
	check(einfo.visible and (is_same(einfo._seen_rec, w.entities[unit]) or einfo.pack_id == "builtin:wube3dp"),
		"edges: the chest's chunk built again while the panel holds it: the panel follows its new record (Wube3DP now): held %s, pack %s"
		% ["the old record" if is_same(einfo._seen_rec, old_rec) else "the new record", einfo.pack_id])
	# Mined while held: the panel lets it go.
	w.handle({"t": "del", "u": unit})
	show.call(null, on)
	check(not w.entities.has(unit) and not (einfo.visible and is_same(einfo._seen_rec, old_rec)) and not (einfo.visible and einfo._seen_rec != null and einfo._seen_rec.unit == unit),
		"edges: the chest mined while the mouse rests on the panel: the panel no longer shows it (visible %s)" % einfo.visible)
	w._add([unit, 1, 10 * 256 + 128, 10 * 256 + 128, 0, {}])
	show.call(null, Vector2(1, 1))

	# A second building crossed on the way: still the first, held.
	show.call(w.entities[unit], start)
	show.call(w.entities[unit + 1], start.lerp(on, 0.5))
	check(is_same(einfo._seen_rec, w.entities[unit]), "edges: the mouse crossing an iron chest on its way to the panel keeps the wooden chest")
	show.call(w.entities[unit + 1], start.lerp(on, 0.5) + Vector2(0, 300))
	show.call(w.entities[unit + 1], start.lerp(on, 0.5) + Vector2(-100, 400))
	check(is_same(einfo._seen_rec, w.entities[unit + 1]) and einfo.visible, "edges: turning away onto the iron chest shows the iron chest")

	# The hold times out: heading for the panel but never reaching it.
	show.call(w.entities[unit], start)
	var t0 := Time.get_ticks_msec()
	var at := start
	var held_mid := true
	while Time.get_ticks_msec() - t0 < 900:
		at = at.move_toward(on, 2.0)
		show.call(null, at)
		if Time.get_ticks_msec() - t0 < EntityInfo.HOLD_MSEC - 150:
			held_mid = held_mid and is_same(einfo._seen_rec, w.entities[unit])
		await get_tree().create_timer(0.05).timeout
	check(held_mid and not rect.has_point(at), "edges: held while heading slowly for the panel within %d ms" % EntityInfo.HOLD_MSEC)
	check(not einfo.visible, "edges: let go once %d ms pass without reaching it (visible %s after %d ms)" % [EntityInfo.HOLD_MSEC, einfo.visible, Time.get_ticks_msec() - t0])

	# Resting on the panel holds for good (no time limit there).
	show.call(w.entities[unit], start)
	show.call(null, on)
	await get_tree().create_timer(0.8).timeout
	show.call(null, on)
	check(is_same(einfo._seen_rec, w.entities[unit]), "edges: resting on the panel past %d ms still holds" % EntityInfo.HOLD_MSEC)

	# A captured mouse (first person's crosshair): mouse INF, nothing held.
	show.call(w.entities[unit], Vector2.INF)
	show.call(null, Vector2.INF)
	check(not einfo.visible, "edges: first person (mouse captured, no position): the panel follows the crosshair, nothing held")
	# The map's resource patch: a patch under the mouse away from the panel shows the patch.
	var patch_was: Dictionary = ui.model.map_patch
	show.call(w.entities[unit], start)
	ui.model.map_patch = {"n": "iron-ore", "a": 1234, "o": []}
	show.call(null, start + Vector2(0, 300))
	show.call(null, start + Vector2(-100, 400))
	check(einfo.visible and not einfo._pack_button.visible and einfo._seen_rec == null, "edges: the map view's patch away from the panel: the patch's panel, no symbol")
	ui.model.map_patch = patch_was
	show.call(null, Vector2(1, 1))

	# The mouse itself: over the panel's empty area the GUI takes nothing (clicks go to the world), over
	# the symbol the symbol does, and a real click on it opens the window. The headless window is 64 x 64,
	# so the panel is moved for this to put its symbol in the window's middle (the HUD lays it out again
	# next frame).
	show.call(w.entities[unit], Vector2(1, 1))
	einfo.global_position += Vector2(32, 32) - button.get_global_rect().get_center()
	var bc: Vector2 = button.get_global_rect().get_center()
	on = bc + Vector2(0, 18)  # under the title bar, on the panel's lines
	rect = einfo.get_global_rect()
	var motion := InputEventMouseMotion.new()
	motion.position = on
	motion.global_position = on
	get_viewport().push_input(motion)
	var over_body: Control = get_viewport().gui_get_hovered_control()
	check(view.has_point(on) and rect.has_point(on) and (over_body == null or not einfo.is_ancestor_of(over_body)),
		"edges: the mouse on the panel's lines: no control of the panel takes it (the world gets the click): %s %s %s"
		% [einfo.get_path_to(over_body) if over_body != null and einfo.is_ancestor_of(over_body) else over_body, on, rect])
	# The title bar left of the symbol (its name): moved to the window's middle the same way.
	einfo.global_position += Vector2(32, 32) - (bc - Vector2(Kit.px(120), 0))
	var on_title: Vector2 = Vector2(32, 32)
	motion = InputEventMouseMotion.new()
	motion.position = on_title
	motion.global_position = on_title
	get_viewport().push_input(motion)
	var over_title: Control = get_viewport().gui_get_hovered_control()
	# Not a check: the title bar (Kit.panel, a PanelContainer left at MOUSE_FILTER_STOP, as on main) takes
	# the mouse there while the lines below let it through; printed for the record.
	print("edges: the title bar beside the symbol takes the mouse: %s" % [over_title != null and einfo.is_ancestor_of(over_title)])
	einfo.global_position -= Vector2(32, 32) - (bc - Vector2(Kit.px(120), 0))
	motion = InputEventMouseMotion.new()
	motion.position = bc
	motion.global_position = bc
	get_viewport().push_input(motion)
	show.call(null, bc)
	var over_button: Control = get_viewport().gui_get_hovered_control()
	check(over_button == button and ui.mouse_over_gui() and button.tooltip_text.begins_with("Model: "),
		"edges: the mouse on the symbol: the symbol takes it, the HUD counts it over the interface, its tooltip: %s" % [over_button])
	asked.clear()
	einfo.open_pack = func(pack: String, fam: String) -> void: asked.append([pack, fam])
	for down in [true, false]:
		var mb := InputEventMouseButton.new()
		mb.button_index = MOUSE_BUTTON_LEFT
		mb.pressed = down
		mb.position = bc
		mb.global_position = bc
		get_viewport().push_input(mb)
	check(asked.size() == 1 and str(asked[0][1]) == "wooden-chest", "edges: a real click on the symbol opens the window: %s" % [asked])
	einfo.open_pack = open_was
	motion = InputEventMouseMotion.new()
	motion.position = Vector2(1, 1)
	get_viewport().push_input(motion)

	show.call(null)
	einfo.player = player_was
	p.queue_free()
	w.queue_free()
	await get_tree().process_frame
	Settings.set_value("model_packs", "choices", choices_was)
	ModelPacks.set_choices(saved_choices)
	ModelLibrary.choices_changed(["wooden-chest"])
	sent()


## The twelfth play-test list. M3: a recipe among a technology's Effects (the research window's details
## and its Factoriopedia page) has Factorio's recipe tooltip, "<name> (Recipe)" with its ingredients, time,
## products and Total raw, from its Factoriopedia page asked for as the mouse comes on it, nothing red;
## a tooltip opened before the page came no longer leaves Total raw out once it has (total_raw kept the
## empty answer); --research-effect-tips=old: the name and "Unlocked by this technology" as before. M4:
## the Show in Factorio button is the HUD's (Factorio's mod button flow), so every window is drawn over
## it and takes the mouse there: the technology screen's "Research queue" title, under it at the top
## left, isn't covered; --mod-button=over keeps it over them as before.


func _twelfth_list(hud: Hud) -> void:
	var ui = hud.ui
	var m = ui.model
	var r = ui.research
	var saved_techs: Dictionary = m.techs.duplicate(true)
	ui.close_all()
	await get_tree().process_frame
	m.set_recipe_details([
		{"name": "copper-cable", "energy": 0.5, "ingredients": [["copper-plate", 1]], "products": [["copper-cable", 2]]},
		{"name": "electronic-circuit", "energy": 0.5, "ingredients": [["iron-plate", 1], ["copper-cable", 3]], "products": [["electronic-circuit", 1]]}])
	var pack := [["automation-science-pack", 1], ["logistic-science-pack", 1]]
	m.handle({"t": "techs", "part": 1, "parts": 1, "l": [["m3-armor", "a", [], pack, 100, 30, 1, "", [["unlock-recipe", "modular-armor"]], 1, 1, [], 0, "", 1]]})
	m.handle({"t": "rs", "cur": "", "pr": 0, "q": []})
	m.pedia_pages.erase("recipe/modular-armor")
	m._pedia_asked.erase("recipe/modular-armor")
	ui.open_research(true)
	r.select("m3-armor")
	for i in 3:
		await get_tree().process_frame
	var title := Kit.recipe_name("modular-armor") + " (Recipe)"
	var effect: Slot = _find_slot_tip(r._details, title)
	sent()
	if effect != null:
		effect.mouse_entered.emit()
	var asked := sent().filter(func(c: Dictionary) -> bool: return c.get("t") == "pedia" and c.get("kind") == "recipe" and c.get("name") == "modular-armor")
	check(effect != null and effect.tip_fn.is_valid() and asked.size() == 1,
		"M3: the effect's slot is the recipe's, \"%s\", its Factoriopedia page asked for as the mouse comes on it (%d asks)" % [title, asked.size()])
	var early: Array = effect.tip_fn.call() if effect != null else []
	m.handle({"t": "pedia", "kind": "recipe", "name": "modular-armor", "found": 1,
		"d": {"ing": [["item", "electronic-circuit", 30], ["item", "steel-plate", 50]], "prod": [["item", "modular-armor", 1]], "time": 15}})
	var lines: Array = effect.tip_fn.call() if effect != null else []
	var texts: Array = lines.map(func(l: Array) -> String: return str(l[0]))
	var red: Array = lines.filter(func(l: Array) -> bool: return l.size() > 2 and l[2] is Color and (l[2] as Color).is_equal_approx(Kit.RED_TEXT))
	check(early.is_empty() and texts.has("Ingredients:") and texts.has("30 × Electronic circuit") and texts.has("50 × Steel plate")
		and texts.any(func(t: String) -> bool: return t.ends_with(" 15.0 s Crafting time")) and texts.has("Products:") and texts.has("1 × Modular armor") and red.is_empty()
		and not texts.has("Unlocked by this technology") and effect._make_custom_tooltip("") != null,
		"M3: hovering it shows Factorio's recipe tooltip: what it takes, the time, what it makes, nothing red: %s" % [texts])
	var raw_at := texts.find("Total raw:")
	check(raw_at >= 0 and texts.has("30 × Iron plate") and texts.has("45 × Copper plate") and texts.has("50 × Steel plate"),
		"M3: and Total raw, down through the hand recipes, though the tooltip had been opened before the page came: %s" % [texts.slice(maxi(raw_at, 0))])
	# Factoriopedia's technology page: its Unlocks recipes slots the same.
	ui.open_pedia("technology", "m3-armor")
	m.handle({"t": "pedia", "kind": "technology", "name": "m3-armor", "found": 1,
		"d": {"effects": [["unlock-recipe", "modular-armor"]], "cost": [["automation-science-pack", 1]], "count": 100, "time": 30}})
	for i in 3:
		await get_tree().process_frame
	var link: Node = _find_slot_tip(ui.pedia._page, title)
	var link_texts: Array = (link.tip_fn.call() as Array).map(func(l: Array) -> String: return str(l[0])) if link != null and link.tip_fn.is_valid() else []
	check(link != null and link_texts.has("30 × Electronic circuit") and link_texts.has("Total raw:") and link._make_custom_tooltip("") != null,
		"M3: Factoriopedia's technology page, its Unlocks recipes slot the same: %s" % [link_texts])
	ui.pedia.open(false)
	ResearchWindow.effect_recipe_tips = false
	r._details_sig = ""
	r.refresh()
	var old: Slot = _find_slot_tip(r._details, Kit.recipe_name("modular-armor"))
	check(old != null and not old.tip_fn.is_valid() and str(old.tip_lines[0][0]) == "Unlocked by this technology",
		"M3: --research-effect-tips=old: the name and \"Unlocked by this technology\", as before")
	ResearchWindow.effect_recipe_tips = true
	r._details_sig = ""
	r.refresh()

	# --- M4: the technology screen over the Show in Factorio button ----------------------------------
	var show_was: Callable = ui.show_factorio
	ui.show_factorio = func() -> void: pass
	for i in 3:
		await get_tree().process_frame
	var button: Button = ui.factorio_button
	var caption: Control = null
	for l in r.find_children("*", "Label", true, false):
		if (l as Label).text == "Research queue":
			caption = l
	var b_rect := button.get_global_rect()
	var windows: Array = [ui.window, ui.research, ui.stats, ui.trains_window, ui.players_window, ui.networks, ui.pedia, ui.death_screen,
		ui.bonuses, ui.alerts_config, ui.achievements, ui.permissions, ui.tips, ui.planners, ui.picker]
	var under: Array = windows.filter(func(w: Control) -> bool: return w.get_index() < button.get_index()).map(func(w: Control) -> String: return w.name)
	check(button.visible and r.visible and caption != null and caption.get_global_rect().intersects(b_rect) and under.is_empty()
		and button.get_index() > ui.remote_frame.get_index() and button.get_index() > ui.map_view.get_index(),
		"M4: the button, at the top left where \"Research queue\" begins (%s, %s), is drawn under every window, over the map view and the Remote view frame (windows under it: %s)"
		% [b_rect, caption.get_global_rect() if caption != null else Rect2(), under])
	var motion := InputEventMouseMotion.new()
	motion.position = b_rect.get_center()
	get_viewport().push_input(motion)
	await get_tree().process_frame
	var hovered := get_viewport().gui_get_hovered_control()
	check(hovered != null and (hovered == r or r.is_ancestor_of(hovered)),
		"M4: the mouse there is the technology screen's, not the button's: %s" % [hovered])
	ui.close_all()
	await get_tree().process_frame
	check(button.visible and button.position.is_equal_approx(Kit.pxv(8, 8)), "M4: the button is back in the corner with the screen closed")
	ui.show_factorio = show_was
	m.techs = saved_techs
	m.handle({"t": "rs", "cur": "", "pr": 0, "q": []})
	await get_tree().process_frame


## P49: a recipe's tooltip breaks its intermediates down to what can't be crafted by hand.
