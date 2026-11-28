extends Control
## Blueprints and planners in the UI: owns the blueprint library window (B), the blueprint window,
## the book window and the deconstruction / upgrade planner window, the import and export string
## box, and connects them to the game through planner_model.gd and to the cursor through
## player_input.gd. factorio_ui.gd creates it and asks it is_open / close_all. As in Factorio, the
## book, planner and library windows are the right half of one window with the character's
## inventory (character_window.gd show_side); the blueprint window is a frame of its own.
##
## Where a record goes and comes from:
##   the library (bp_library.gd, user://) -> the cursor: written into the mod's cursor stack
##     (`bp_set` -1) and held from there, as Factorio's library records are held without being in
##     the inventory;
##   the game's and the player's library tabs -> the cursor: `bp_rec` with to = -1 (no round trip);
##   an inventory stack -> its window: `bp_get`, and Save writes it back with `bp_set`;
##   Alt+B's selection: the new blueprint's window opens, as Factorio's setup window does.
## Also here: the cached record of the held planner (book pages for cycling, a planner's filters
## for the selection highlight), and handing the mod's undo entries to player_input.gd.
##
## Debug options (after `--`): --ui=library opens the library after 2 s (--ui-library-tab=game or
## player picks a tab); --ui-import=<file> imports the exchange string in that file into My
## blueprints at start; --ui-take=<n> takes My blueprints' n-th record into the cursor after 4 s;
## --ui-planner=<slot> opens the window of the planner in that inventory slot after 4 s;
## --ui-game-record=<n> opens the game library's record n (the mock's 2 is a book) after 4 s;
## --ui-place clicks the held blueprint down where the mouse is after 7 s.

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const MenuKit := preload("res://scripts/menu/menu_kit.gd")
const BpString := preload("res://scripts/ui/factorio/bp_string.gd")
const BpLibrary := preload("res://scripts/ui/factorio/bp_library.gd")
const LibraryWindow := preload("res://scripts/ui/factorio/library_window.gd")
const BlueprintWindow := preload("res://scripts/ui/factorio/blueprint_window.gd")
const PlannerWindow := preload("res://scripts/ui/factorio/planner_window.gd")
const BookWindow := preload("res://scripts/ui/factorio/book_window.gd")
const BlueprintPicture := preload("res://scripts/ui/factorio/blueprint_picture.gd")
const Switches := preload("res://scripts/switches.gd")

const PLANNER_ITEMS := ["blueprint", "blueprint-book", "deconstruction-planner", "upgrade-planner"]

## factorio_ui.gd (its model, player, picker, hand and messages). Untyped: no preload cycle.
var ui
var model  # planner_model.gd (ui.model.planners)
var library := BpLibrary.new()
var library_window := LibraryWindow.new()
var bp_window := BlueprintWindow.new()
var planner_window := PlannerWindow.new()
var book_window := BookWindow.new()
## The held planner's record (slot it came from: -1 the cursor's stack, else the main slot), {}
## until the mod has sent it.
var held_record := {}
var held_slot := 0

var _preview_of := {}
## The prototypes _preview was made with: another game's (or a test's other world) makes it again.
var _preview_protos: Object = null
var _preview: Array = []
var _preview_tiles: Array = []
var _preview_shift := Vector2.ZERO
## Goes up whenever held_preview's list is made again (blueprint_preview.gd lays it out again).
var preview_version := 0
## Inventory blueprints' records for their tooltips' pictures (K11), asked of the bridge as a
## tooltip opens: slot -> [what the slot held then, the record ({} until it comes)].
var _slot_records := {}

var _string_box: Control
var _string_text: TextEdit
var _string_title: Label
var _string_ok: Button
var _string_mode := ""
## Select new contents in progress: the blueprint's slot (-1 the library one) and where it came
## from, so its window opens again on what was selected.
var _reselect_slot := 0
var _reselect_source := {}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	model = ui.model.planners
	library_window.model = model
	library_window.library = library
	library_window.close_requested.connect(func() -> void: library_window.open(false))
	library_window.closed.connect(func() -> void: ui.window.hide_side(library_window))
	library_window.take_requested.connect(take)
	library_window.open_requested.connect(open_source)
	library_window.add_held_requested.connect(add_held)
	add_child(library_window)
	for w in [bp_window, planner_window, book_window]:
		if "picker" in w:
			w.picker = ui.picker
		w.close_requested.connect(w.close)
		w.saved.connect(_on_saved)
		w.deleted.connect(_on_deleted)
		w.export_requested.connect(func(r: Dictionary) -> void: show_string("export", BpString.encode(r)))
		w.copy_requested.connect(func(r: Dictionary) -> void:
			take_record_of(r)
			ui.hud_message("Copied %s into the cursor" % BpString.title(r)))
		add_child(w)
	for w in [planner_window, book_window]:
		w.closed.connect(func() -> void: ui.window.hide_side(w))
	bp_window.add_to_library.connect(func(r: Dictionary) -> void:
		library.add([], r)
		ui.hud_message("Added to My blueprints"))
	bp_window.reselect_requested.connect(reselect)
	for w in [bp_window, book_window]:
		w.upgrade_requested.connect(func() -> void: _with_upgrade_planner(func(planner: Dictionary) -> void:
			var n: int = w.apply_upgrade(planner)
			ui.hud_message("Upgraded %d entities with %s" % [n, BpString.title(planner)])))
	book_window.add_held_page.connect(_add_held_page)
	book_window.page_taken.connect(func(page: Dictionary) -> void:
		book_window.flush()  # the book loses the page at once, as the cursor gets it
		take_record_of(page))
	book_window.page_open_requested.connect(func(page: Dictionary, i: int) -> void:
		edit(page, {"kind": "page", "page": i, "book": book_window.source, "book_record": book_window.record.duplicate(true)}))
	_build_string_box()
	model.stack_written.connect(_on_stack_written)
	model.history_added.connect(func(h: int, what: String) -> void:
		if ui.player != null and ui.player.has_method("remember_mod"):
			ui.player.remember_mod(h, what))
	_debug_options()


func _debug_options() -> void:
	for arg in Switches.args():
		var value := arg.get_slice("=", 1)
		if arg == "--ui=library":
			get_tree().create_timer(2.0).timeout.connect(func() -> void: open_library(true))
		elif arg.begins_with("--ui-library-tab="):
			get_tree().create_timer(2.5).timeout.connect(func() -> void: library_window.show_tab(value))
		elif arg.begins_with("--ui-import="):
			import_string(FileAccess.get_file_as_string(value))
		elif arg.begins_with("--ui-take="):
			get_tree().create_timer(4.0).timeout.connect(func() -> void: take({"kind": "library", "path": [int(value) - 1]}))
		elif arg == "--ui-place":
			get_tree().create_timer(7.0).timeout.connect(func() -> void:
				if ui.player != null and ui.player.has_ground:
					ui.player.place_blueprint(ui.player.blueprint_anchor(ui.player.ground), 1))
		elif arg.begins_with("--ui-planner="):
			get_tree().create_timer(4.0).timeout.connect(func() -> void: open_slot(int(value)))
		elif arg.begins_with("--ui-game-record="):
			get_tree().create_timer(4.0).timeout.connect(func() -> void: open_source({"kind": "game", "ix": int(value)}))


func _process(_delta: float) -> void:
	model.poll()


func is_open() -> bool:
	return library_window.is_open() or bp_window.is_open() or planner_window.is_open() or book_window.is_open() \
		or _string_box.visible


func close_all() -> void:
	library_window.open(false)
	bp_window.close()
	planner_window.close()
	book_window.close()
	_string_box.visible = false


## Esc: the topmost of these first.
func escape() -> bool:
	if _string_box.visible:
		_string_box.visible = false
	elif bp_window.is_open():
		bp_window.close()
	elif planner_window.is_open():
		planner_window.close()
	elif book_window.is_open():
		book_window.close()
	elif library_window.is_open():
		library_window.open(false)
	else:
		return false
	return true


func toggle_library() -> void:
	open_library(not library_window.is_open())


## The library joins the character's inventory as Factorio's window does.
func open_library(on: bool) -> void:
	if on:
		bp_window.close()
		library_window.open(true)
		ui.window.show_side(library_window, library_window.title_text())
	else:
		library_window.open(false)


# --- the cursor -------------------------------------------------------------------------------

## A library record (or a game / player library record) into the cursor.
func take(source: Dictionary) -> void:
	var hold_it := func(_r: Dictionary, _t: String, info: Dictionary) -> void:
		if str(info.get("item", "")) != "" and ui.player != null:
			ui.hand = {}
			ui.player.hold(str(info["item"]), -1)
	match str(source.get("kind", "")):
		"library":
			var r := library.record_at(source["path"])
			if not r.is_empty():
				model.write(-1, r, hold_it)
		"game", "player":
			model.take_record(str(source["kind"]), int(source["ix"]), hold_it)


## A new empty planner in the cursor (the upgrade planner shortcut without one in the inventory).
func give_new(kind: String) -> void:
	take_record_of(model.empty(kind))


func take_record_of(r: Dictionary) -> void:
	model.write(-1, r, func(_r: Dictionary, _t: String, info: Dictionary) -> void:
		if ui.player != null:
			ui.player.hold(str(info.get("item", "")), -1))


## The player picked up or put down a planner: fetches its record (book pages, filters).
func held_changed(item: String, slot: int) -> void:
	held_record = {}
	held_slot = slot
	if not PLANNER_ITEMS.has(item) or slot == 0:
		return
	model.export_stack(slot, func(r: Dictionary, _t: String, _info: Dictionary) -> void:
		if held_slot == slot:
			held_record = r)


## Shift+mouse wheel with a book held: the next (or previous) page becomes the active one.
func cycle_book(slot: int, step: int) -> void:
	if BpString.kind(held_record) != "blueprint_book" or slot == 0:
		return
	var pages := BpString.pages(held_record)
	if pages.is_empty():
		return
	var b := BpString.body(held_record)
	var at := 0
	for i in pages.size():
		if int(pages[i][0]) == int(b.get("active_index", 0)):
			at = i
	at = posmod(at + step, pages.size())
	b["active_index"] = int(pages[at][0])
	model.set_page(slot, at + 1)
	ui.hud_message("%s: %d / %d  %s" % [BpString.title(held_record), at + 1, pages.size(), BpString.title(pages[at][1])])


## The active page of the held book, or the held blueprint itself: {} when not known.
func held_blueprint() -> Dictionary:
	if BpString.kind(held_record) == "blueprint_book":
		var active := int(BpString.body(held_record).get("active_index", 0))
		for p in BpString.pages(held_record):
			if int(p[0]) == active:
				return p[1]
		return {}
	return held_record


## The held blueprint's snapping: {} without snap to grid, else {"grid": size, "absolute": bool,
## "offset": position-relative-to-grid} (Vector2s, tiles).
func held_snap() -> Dictionary:
	var b := BpString.body(held_blueprint())
	var snap = b.get("snap-to-grid")
	if not (snap is Dictionary):
		return {}
	var rel = b.get("position-relative-to-grid")
	return {"grid": Vector2(maxf(1.0, float(snap.get("x", 1))), maxf(1.0, float(snap.get("y", 1)))),
		"absolute": bool(b.get("absolute-snapping", false)),
		"offset": Vector2(float(rel.get("x", 0)), float(rel.get("y", 0))) if rel is Dictionary else Vector2.ZERO}


## How far a drag moves between two placements of the held blueprint (tiles, turned with the
## cursor's direction): its snap grid, else the size of what it holds, as Factorio's drag-building
## of blueprints spaces them.
func held_step(protos, dir: int) -> Vector2i:
	var size := Vector2i.ZERO
	var snap := held_snap()
	if not snap.is_empty():
		size = Vector2i(snap["grid"])
	else:
		var lo := Vector2(INF, INF)
		var hi := -lo
		for e in held_preview(protos):
			var proto = protos.entity(int(e["p"]))
			var half := Vector2(proto.tile_size) * 0.5 if proto != null else Vector2(0.5, 0.5)
			if int(e["d"]) % 8 == 4:
				half = Vector2(half.y, half.x)
			lo = lo.min(e["at"] - half)
			hi = hi.max(e["at"] + half)
		if lo.x == INF:
			return Vector2i.ZERO
		size = Vector2i((hi - lo).round())
	if posmod(dir, 8) == 4:
		size = Vector2i(size.y, size.x)
	return size


## A blueprint entity's direction (16-way). Rolling stock has an orientation instead (0-1,
## clockwise from north), so without this every train in a blueprint faced north (issue #13).
static func entity_direction(e: Dictionary) -> int:
	if e.has("orientation") and not e.has("direction"):
		return posmod(roundi(float(e["orientation"]) * 16.0), 16)
	return int(e.get("direction", 0))


## The held blueprint's (or book's active page's) entities for the cursor's preview
## (blueprint_preview.gd), as the clipboard's (ui_actions.lua send_clip): [{"p": proto id, "at":
## offset from the middle of what it covers (tiles), "d", "x": the model's extra (an underground's
## end), "f": Factorio's `mirror` on a machine}, ...], every entity. The middle is that of the
## entities' footprints and the tiles together, where Factorio holds a blueprint at the cursor
## (#21's clipboard measured in 2.1.23; tiles counted too, not measured).
func held_preview(protos) -> Array:
	var bp := held_blueprint()
	if bp.is_empty():
		return []
	if (is_same(bp, _preview_of) or bp == _preview_of) and is_same(protos, _preview_protos):
		return _preview
	_preview_of = bp
	_preview_protos = protos
	_preview = []
	_preview_tiles = []
	_preview_shift = Vector2.ZERO
	preview_version += 1
	var b := BpString.body(bp)
	var found: Array = []
	var lo := Vector2(INF, INF)
	var hi := -lo
	var plo := lo  # the entities' positions alone: where the absolute snapping's middle was taken
	var phi := hi
	for e in BpString._list(b.get("entities")):
		var proto = protos.entities_by_name.get(str(e.get("name", "")))
		var p = e.get("position")
		if proto == null or not (p is Dictionary):
			continue
		var at := Vector2(float(p.get("x", 0)), float(p.get("y", 0)))
		var d := entity_direction(e)
		var half := Vector2(proto.tile_size) * 0.5
		if posmod(roundi(d / 4.0), 2) == 1:
			half = Vector2(half.y, half.x)
		lo = lo.min(at - half)
		hi = hi.max(at + half)
		plo = plo.min(at)
		phi = phi.max(at)
		found.append([proto, at, d, e])
	var corners: Array = []
	for t in BpString._list(b.get("tiles")):
		var p = t.get("position")
		if not (p is Dictionary):
			continue
		var at := Vector2(float(p.get("x", 0)), float(p.get("y", 0)))
		lo = lo.min(at)
		hi = hi.max(at + Vector2.ONE)
		corners.append(at)
	if lo.x == INF:
		return _preview
	var mid := (lo + hi) * 0.5
	if plo.x != INF:
		_preview_shift = mid - ((plo + phi) * 0.5).round()
	for f in found:
		var e: Dictionary = f[3]
		var entry := {"p": f[0].id, "at": (f[1] as Vector2) - mid, "d": f[2]}
		var extra := {}
		if f[0].type == "underground-belt" or f[0].type == "linked-belt":
			extra["u"] = "o" if str(e.get("type", "input")) == "output" else "i"
		for key: String in ["recipe", "filters", "filter", "request_filters", "items"]:
			if e.has(key) and e[key] != null:
				extra[key] = e[key]
		if not extra.is_empty():
			entry["x"] = extra
		if bool(e.get("mirror", false)):
			entry["f"] = true
		_preview.append(entry)
	for c in corners:
		_preview_tiles.append((c as Vector2) - mid)
	return _preview


## The held blueprint's tiles for the preview: their corners, offsets from the middle (held_preview
## first).
func held_preview_tiles() -> Array:
	return _preview_tiles


## With absolute snapping (player_input.gd blueprint_preview_centre): how far the middle held_preview's
## offsets are from lies from the one its anchor was worked out for (the entities' positions' middle,
## rounded), so the preview stands where it stood before K11.
func held_shift() -> Vector2:
	return _preview_shift


## A blueprint's or book's picture for an inventory or quickbar slot's tooltip (slot.gd
## picture_for, K11): the inventory stack's record (a quickbar pin's: the first stack of its item),
## drawn once the bridge has sent it; null for slots elsewhere (a chest's: no export for them).
func tip_picture(s) -> Control:
	var index := 0
	if str(s.slot_role) == "main":
		index = int(s.slot_index)
	elif str(s.slot_role) == "":
		index = _first_slot_of(str(s.item))
	if index <= 0:
		return null
	var picture := BlueprintPicture.new()
	picture.protos = ui._protos()
	picture.source = func() -> Dictionary: return slot_record(index)
	return picture


## The record of the blueprint or book in main slot `index` (1-based), or {} until the bridge has
## sent it: asked once per stack the slot holds (kept until the slot holds another, or the bridge
## says it was written).
func slot_record(index: int) -> Dictionary:
	var slots: Array = ui.model.main_slots
	if index < 1 or index > slots.size() or not (slots[index - 1] is Dictionary):
		return {}
	var stack: Dictionary = slots[index - 1]
	if not PLANNER_ITEMS.has(str(stack.get("item", ""))):
		return {}
	if held_slot == index and not held_record.is_empty():
		return held_record
	var held_now := "%s|%s|%s" % [stack.get("item", ""), stack.get("count", 0), str(stack.get("icons", []))]
	var got: Array = _slot_records.get(index, [])
	if not got.is_empty() and str(got[0]) == held_now:
		return got[1]
	_slot_records[index] = [held_now, {}]
	model.export_stack(index, func(r: Dictionary, _t: String, _info: Dictionary) -> void:
		var now: Array = _slot_records.get(index, [])
		if not now.is_empty() and str(now[0]) == held_now:
			_slot_records[index] = [held_now, r])
	return {}


func _first_slot_of(item: String) -> int:
	var slots: Array = ui.model.main_slots
	for i in slots.size():
		if slots[i] is Dictionary and str((slots[i] as Dictionary).get("item", "")) == item:
			return i + 1
	return 0


# --- windows ----------------------------------------------------------------------------------

## Right click on an inventory planner (or after Alt+B): its window, with what the mod exports.
func open_slot(slot: int) -> void:
	model.export_stack(slot, func(r: Dictionary, _t: String, info: Dictionary) -> void:
		if r.is_empty():
			ui.hud_message(str(info.get("err", "Nothing to open")))
		else:
			edit(r, {"kind": "slot", "slot": slot}))


func open_source(source: Dictionary) -> void:
	match str(source.get("kind", "")):
		"library":
			edit(library.record_at(source["path"]), source)
		"game", "player":
			model.export_record(str(source["kind"]), int(source["ix"]), func(r: Dictionary, _t: String, info: Dictionary) -> void:
				if r.is_empty():
					ui.hud_message(str(info.get("err", "That record can't be read")))
				else:
					edit(r, source))


func edit(r: Dictionary, source: Dictionary) -> void:
	if ui.window == null:
		return
	if bp_window.protos == null:
		bp_window.protos = ui._protos()
	match BpString.kind(r):
		"blueprint":
			# Over the book (a page) or on its own.
			if str(source.get("kind", "")) != "page":
				planner_window.close()
				book_window.close()
			bp_window.edit(r, source)
		"blueprint_book":
			bp_window.close()
			planner_window.close()
			book_window.edit(r, source)
			ui.window.show_side(book_window, book_window.title_text())
		"deconstruction_planner", "upgrade_planner":
			bp_window.close()
			if str(source.get("kind", "")) == "page":
				# The book's changes so far go with the page's (see _on_saved).
				book_window.flush()
				source["book_record"] = book_window.record.duplicate(true)
			book_window.close()
			planner_window.edit(r, source)
			ui.window.show_side(planner_window, planner_window.title_text())


func _on_saved(r: Dictionary, source: Dictionary) -> void:
	match str(source.get("kind", "")):
		"slot":
			var slot := int(source["slot"])
			model.write(slot, r)
			if slot == held_slot:
				held_record = r
		"library":
			library.set_record(source["path"], r)
		"page":
			# A book's page: into the open book, or into the book's record written back.
			var i := int(source["page"])
			if book_window.is_open() and book_window.source == source.get("book"):
				book_window.set_page(i, r)
			else:
				var book: Dictionary = source.get("book_record", {})
				var list: Array = BpString.pages(book).map(func(p: Array) -> Dictionary: return p[1])
				if i >= 0 and i < list.size():
					list[i] = r
					BpString.set_pages(book, list)
					_on_saved(book, source.get("book", {}))
		_:
			# The game's and the player's tabs can be read but not written through the API: keep a copy.
			library.add([], r)
			ui.hud_message("Saved a copy to My blueprints")


func _on_deleted(source: Dictionary) -> void:
	match str(source.get("kind", "")):
		"library":
			var path: Array = source["path"]
			library.remove(path.slice(0, path.size() - 1), int(path[-1]))
		"slot":
			# Factorio's red trash button destroys the item.
			model.delete(int(source["slot"]))


## The mod wrote a stack. A fresh one (Alt+B's selection made a blueprint, or Select new contents
## filled one) opens its window.
func _on_stack_written(_q: int, slot: int, item: String, fresh: bool) -> void:
	_slot_records.erase(slot)
	if fresh and slot != 0 and item == "blueprint":
		if slot == _reselect_slot and not _reselect_source.is_empty():
			var from := _reselect_source
			_reselect_slot = 0
			_reselect_source = {}
			model.export_stack(slot, func(r: Dictionary, _t: String, _info: Dictionary) -> void:
				if not r.is_empty():
					edit(r, from))
		elif slot > 0:
			open_slot(slot)
	if slot == held_slot and slot != 0:
		held_changed(item, slot)


## Factorio's "Select new contents": the blueprint goes into the cursor as the blueprint tool, and
## the area dragged becomes its contents (`copy` with `to`); its window then opens again. A
## blueprint that isn't in the inventory goes through the library stack (-1).
func reselect(r: Dictionary, source: Dictionary) -> void:
	bp_window.close()
	if ui.player == null:
		return
	var start := func(slot: int) -> void:
		_reselect_slot = slot
		_reselect_source = source
		ui.close_all()
		ui.player.hold_tool("blueprint")
		ui.player.reselect_slot = slot
		ui.hud_message("Select the new contents for %s" % BpString.title(r))
	if str(source.get("kind", "")) == "slot":
		start.call(int(source["slot"]))
	else:
		model.write(-1, r, func(_r: Dictionary, _t: String, _info: Dictionary) -> void: start.call(-1))


## The upgrade planner for "Upgrade items and entities": the one in the cursor, else the first in
## the inventory.
func _with_upgrade_planner(then: Callable) -> void:
	if BpString.kind(held_record) == "upgrade_planner":
		then.call(held_record)
		return
	var slot := 0
	for i in ui.model.main_slots.size():
		if ui.model.main_slots[i].get("item", "") == "upgrade-planner":
			slot = i + 1
			break
	if slot == 0:
		ui.hud_message("No upgrade planner: hold one or keep one in the inventory")
		return
	model.export_stack(slot, func(r: Dictionary, _t: String, _info: Dictionary) -> void:
		if BpString.kind(r) == "upgrade_planner":
			then.call(r))


## The slot of the planner in the cursor: the clipboard (-2), the library's (-1), the one picked
## up, or the first of that item; 0 for none.
func cursor_slot() -> int:
	var p = ui.player
	if p == null:
		return 0
	var tool = p.get("cursor_tool")
	if tool != null and str(tool) == "paste":
		return -2
	if tool != null and str(tool) != "":
		return 0
	if not PLANNER_ITEMS.has(str(p.cursor_item)):
		return 0
	var held = p.get("cursor_slot")
	if held != null and int(held) != 0:
		return int(held)
	if not ui.hand.is_empty() and ui.hand["role"] == "main":
		return int(ui.hand["index"])
	for i in ui.model.main_slots.size():
		if ui.model.main_slots[i].get("item", "") == p.cursor_item:
			return i + 1
	return 0


## Saves the clipboard's copied selection (Ctrl+C) into main inventory slot `to` (0: first empty
## slot) as a blueprint item, playing the inventory sound and clearing the cursor.
func save_clipboard(to := 0) -> bool:
	if cursor_slot() != -2:
		return false
	var on_saved := func(_r: Dictionary, _t: String, info: Dictionary) -> void:
		var err := str(info.get("err", ""))
		if err != "":
			ui.hud_message(err)
	model.save_stack(-2, to, on_saved)
	ui._play_move_sfx("blueprint")
	ui._drop_hand()
	return true


## A click on the library's grid: the held planner is added there (a copy).
func add_held(path: Array) -> void:
	var slot := cursor_slot()
	if slot == 0:
		return
	var was_paste := slot == -2
	var on_exported := func(r: Dictionary, _t: String, _info: Dictionary) -> void:
		if not r.is_empty():
			library.add(path, r)
			ui.hud_message("Added %s to the library" % BpString.title(r))
			if was_paste:
				ui._play_move_sfx("blueprint")
				if ui.player != null and str(ui.player.get("cursor_tool")) == "paste":
					ui._drop_hand()
	model.export_stack(slot, on_exported)


func _add_held_page() -> void:
	var slot := cursor_slot()
	if slot == 0 or (slot != -2 and str(ui.player.cursor_item) != "blueprint"):
		return
	var was_paste := slot == -2
	var on_exported := func(r: Dictionary, _t: String, _info: Dictionary) -> void:
		if BpString.kind(r) == "blueprint":
			book_window.add_page(r)
			if was_paste:
				ui._play_move_sfx("blueprint")
				if ui.player != null and str(ui.player.get("cursor_tool")) == "paste":
					ui._drop_hand()
	model.export_stack(slot, on_exported)


# --- import and export strings ----------------------------------------------------------------

func _build_string_box() -> void:
	var w: Array = MenuKit.window("Import string", true)
	_string_box = w[0]
	_string_box.name = "StringBox"
	_string_box.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_string_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_string_box.grow_vertical = Control.GROW_DIRECTION_BOTH
	_string_box.z_index = 10
	_string_box.visible = false
	_string_title = (w[1] as VBoxContainer).get_child(0).get_child(0)
	(w[2] as Button).pressed.connect(func() -> void: _string_box.visible = false)
	_string_text = TextEdit.new()
	_string_text.custom_minimum_size = Kit.pxv(520, 220)
	_string_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	(w[1] as VBoxContainer).add_child(_string_text)
	var buttons: Array = MenuKit.dialog_buttons("Cancel", "Import")
	(buttons[1] as Button).pressed.connect(func() -> void: _string_box.visible = false)
	_string_ok = buttons[2]
	_string_ok.name = "Import"
	_string_ok.pressed.connect(_on_string_ok)
	(w[1] as VBoxContainer).add_child(buttons[0])
	add_child(_string_box)


## "import": an empty box for a string; "export": the string, selected and copied.
func show_string(mode: String, text: String) -> void:
	_string_mode = mode
	_string_title.text = "Import string" if mode == "import" else "Export string"
	_string_ok.text = "Import" if mode == "import" else "Close"
	_string_text.text = text
	_string_text.editable = mode == "import"
	_string_box.visible = true
	_string_box.reset_size()
	if mode == "export":
		DisplayServer.clipboard_set(text)
		_string_text.select_all()
		ui.hud_message("Copied to the clipboard")
	_string_text.grab_focus.call_deferred()


func _on_string_ok() -> void:
	if _string_mode == "import":
		import_to_cursor(_string_text.text)
	_string_box.visible = false


## Factorio's Import string (the shortcut): the blueprint, book or planner goes into the cursor.
func import_to_cursor(text: String) -> bool:
	var r := BpString.decode(text)
	if r.is_empty():
		ui.hud_message("That isn't a blueprint string")
		return false
	if BpString.version_of(r) != 0:
		model.version = maxi(model.version, BpString.version_of(r))
	take_record_of(r)
	return true


## Adds a pasted exchange string to My blueprints, where the library shows (--ui-import).
func import_string(text: String) -> bool:
	var r := BpString.decode(text)
	if r.is_empty():
		ui.hud_message("That isn't a blueprint string")
		return false
	if BpString.version_of(r) != 0:
		model.version = maxi(model.version, BpString.version_of(r))
	var path: Array = library_window.path if library_window.tab == "mine" else []
	library.add(path, r)
	if library_window.tab != "mine":
		library_window.show_tab("mine")
	ui.hud_message("Imported %s" % BpString.title(r))
	return true
