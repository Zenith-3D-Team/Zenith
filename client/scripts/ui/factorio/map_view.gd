extends Control
## Factorio's map view (M): the charted map over the whole window, north up, with the character's
## arrow, the map tags (icon and name) and the layers of Factorio's map view settings (electric and
## logistic networks, turret coverage, train stop names, worker robots, rail signals, recipe icons;
## map_layers.gd), switched in a panel at the top right like Factorio's. The game keeps running
## underneath; the quickbar and other windows stay on top, as in Factorio.
##
##   drag (left or middle) or WASD / arrows: move the map (Shift: faster); the map stops following
##       the character until it is opened again
##   wheel: zoom about the mouse, in steps of √2 between 1/4 and 8 GUI pixels per tile; zooming in
##       past the closest zoom goes into the world there (Factorio 2.0's remote view: zoom_to_world)
##   right click or double click: create a tag there; right click on a tag: edit or delete it
##   M or Esc: close (Esc closes the tag dialog first)
##
## Factorio's surface switcher sits at the top left: a button per planet and space platform the
## mod lists (`surfs`); the map then shows that surface's charts and tags, centred on a planet's
## cargo landing pad (H23; the mod answers `lpad`) or a platform's hub. Closing the map goes back to
## the character's surface, as Factorio does.
##
## Charts for what is visible are asked for through map_cache.gd, which spaces the requests out.
##
## A resource patch under the mouse is outlined in white and the entity info panel shows its total, an
## infinite resource's combined yield (L6, as Factorio's map view: ResourceEntityPrototype's
## resource_patch_search_radius groups the patch): asked of the bridge (`rpatch`) once the mouse rests on a
## tile outside the patch shown. --map-resource-info=off: none.

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const MapCache := preload("res://scripts/ui/factorio/map_cache.gd")
const MapTagDialog := preload("res://scripts/ui/factorio/map_tag_dialog.gd")
const MapLayers := preload("res://scripts/ui/factorio/map_layers.gd")
const UiSettings := preload("res://scripts/ui/ui_settings.gd")
const GuiAssets := preload("res://scripts/ui/factorio/gui_assets.gd")
const SpacePanels := preload("res://scripts/ui/factorio/space_panels.gd")
const LocaleNames := preload("res://scripts/world/locale_names.gd")
const MenuKit := preload("res://scripts/menu/menu_kit.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const Switches := preload("res://scripts/switches.gd")

## The Surfaces panel's list (GUI pixels), as Factorio's.
const SURFACES_WIDTH := 238

## Screen (GUI) pixels per tile.
const MIN_ZOOM := 0.25
const MAX_ZOOM := 8.0
const DEFAULT_ZOOM := 2.0
const ZOOM_STEP := 1.4142135
## Scrolling in past MAX_ZOOM fills an orange bar before entering 3D view.
const ENTER_3D_SCROLLS := 5
const ENTER_3D_HOLD_SEC := 0.75
const ENTER_3D_DECAY_PER_SEC := 1.5
## Seconds between asking again for the same area.
const REFRESH := 6.0
## L6: how long the mouse rests on a tile before its resource patch is asked for, and the outline's colour and width.
const PATCH_REST := 0.12
const PATCH_OUTLINE := Color(1, 1, 1, 0.95)
static var patch_info := Switches.on("--map-resource-info")
## The most chunks asked for at once around the middle of the view (the mod sends 240 a second).
const MAX_CHUNKS := 96
## Screen pixels a second WASD moves the map.
const PAN_SPEED := 700.0
## How far the layers (map_layers.gd) are drawn past the window's edges, and so how far the map
## moves before they are drawn again: while panning, not every frame.
const LAYERS_SHIFT_PX := 128.0

## Zoomed in past MAX_ZOOM at this point (tiles): factorio_ui.gd shows the world there.
signal zoom_to_world(at: Vector2)
## The "Space map" button under the surface switcher (Space Age).
signal space_map_requested
## A surface was picked in the Surfaces panel (its index; 0 the character's).
signal surface_chosen(si: int)

var cache: MapCache
var model
## Returns [position (tiles), heading (radians clockwise from north)] of the character.
var character: Callable
var dialog := MapTagDialog.new()
var layers := MapLayers.new()
## The map view settings: an icon button per layer (named by its option, "map-show_tags").
var panel := PanelContainer.new()
## The surface switcher (top left): a button per surface in model.map_surfaces.
var surfaces_panel := PanelContainer.new()
## platform_panel.gd (the force's platforms, `plat`), for the planet icons on platform rows.
var platforms: Control = null
## The space map is open: its row is the chosen one (set_space_open).
var space_open := false
var _surface_box := VBoxContainer.new()
## The "Space map" row, outside the scrolled list so it stays in view.
var _space_box := VBoxContainer.new()
var _surface_scroll: ScrollContainer
var _fit_key := ""
var settings = UiSettings.shared()

## Tiles in the middle of the window, and GUI pixels per tile (times Kit.scale on screen).
var centre := Vector2.ZERO
var zoom := DEFAULT_ZOOM
## The view follows the character until it is moved.
var following := true

var _hint := Label.new()
var _dragging := false
## The title bar's Search (Factorio's "Search the map"): the map's tags by name, a click looks at one.
var search_panel := PanelContainer.new()
var search_field := LineEdit.new()
var _search_list := VBoxContainer.new()
var _press_at := Vector2.INF  # where the left button went down (a click on a tag edits it)
var _tag_at := Vector2.ZERO  # where the dialog's new tag goes (tiles)
var _tag_editing := -1  # id of the tag being edited
## A left click on a building, train or vehicle opens its window, as in Factorio's remote view: factorio_ui.gd opens
## it (the mod's open checks the radar and roboport coverage). `proto_name` names a prototype id for the hover tooltip.
signal entity_picked(unit: int, proto_id: int, fixed: Vector2i)
var proto_name: Callable = Callable()
var _click_q := -1
var _hover_q := -1
var _pick_tile := Vector2i(1 << 30, 1 << 30)
var _pick_since := 0
var _hover_name := ""
var _tip: PanelContainer = null
var _tip_label: Label = null
var _unghost := {}  # unghost request id -> the screen point right-clicked
var _me := [Vector2.ZERO, 0.0]
var _redraw := true
var _layers_now := true  # opened: the layers drawn at once, around the view
## The landing pad asked for on switching to a planet (its ask's id; -1 none, or the view was moved).
var _pad_q := -1
## L6: the tile under the mouse and since when (msec), and the shown patch's outline as segment pairs (tiles).
var _hover_tile := Vector2i(1 << 30, 1 << 30)
var _hover_since := 0
var _patch_edges := PackedVector2Array()
## The alert bar (alerts.gd), set by factorio_ui.gd: its alerts are drawn on the map.
var alerts = null:
	set(a):
		alerts = a
		if a != null and not a.shown_changed.is_connected(_queue_alerts):
			a.shown_changed.connect(_queue_alerts)
## The alerts drawn last, [[kind, screen point], ...] (tests).
var alerts_placed: Array = []
var _blink_was := false
var _enter_3d_charge := 0.0
var _enter_3d_idle := 0.0
var _enter_3d_panel: PanelContainer = null
var _enter_3d_bar: ProgressBar = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	visible = false
	layers.model = model
	# Panning draws the layers again only every LAYERS_SHIFT_PX (they move with the map meanwhile).
	layers.shift_px = LAYERS_SHIFT_PX
	add_child(layers)
	_build_panel()
	_build_surfaces()
	model.map_surfaces_changed.connect(_on_surfaces_changed)
	model.unghost_answered.connect(_on_unghost)
	settings.changed.connect(func(key: String) -> void:
		if key.begins_with("map/"):
			_redraw = true)
	_hint.text = "Drag or WASD: move · Wheel: zoom · Right click: add or edit a tag · M or Esc: close"
	_hint.theme_type_variation = "FSmallLabel"
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hint.anchor_left = 1.0
	_hint.anchor_right = 1.0
	_hint.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_hint.offset_right = -Kit.px(12)
	_hint.offset_top = Kit.px(8)
	_hint.add_theme_font_size_override("font_size", Kit.px(13))
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.visible = false  # Factorio's remote view has no such line: F1's help says it
	add_child(_hint)
	_build_search()
	add_child(dialog)
	dialog.confirmed.connect(_on_tag_confirmed)
	dialog.deleted.connect(_on_tag_deleted)
	cache.updated.connect(func() -> void: _redraw = true)
	model.tags_changed.connect(func() -> void: _redraw = true)
	model.map_trains_changed.connect(func() -> void: _redraw = true)
	model.territories_changed.connect(func() -> void: _redraw = true)
	model.roboports_changed.connect(func() -> void: _redraw = true)
	model.landing_pad_found.connect(_on_landing_pad)
	model.picked.connect(_on_picked)
	_tip = PanelContainer.new()
	_tip.name = "EntityTip"
	_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip.visible = false
	_tip_label = Kit.label("")
	_tip.add_child(_tip_label)
	add_child(_tip)
	_build_enter_3d_bar()
	model.map_patch_changed.connect(func() -> void:
		_patch_edges = outline_edges(model.map_patch.get("o", []))
		_redraw = true)
	mouse_exited.connect(func() -> void:
		model.clear_patch()
		_clear_hover())


## The alert bar changed: draw its alerts again.
func _queue_alerts() -> void:
	_redraw = true


func is_open() -> bool:
	return visible


func open(on: bool, keep_surface := false) -> void:
	if on == visible:
		return
	visible = on
	dialog.close()
	search_panel.visible = false
	_dragging = false
	if on:
		following = true
		_me = _character()
		centre = _me[0]
		_redraw = true
		_layers_now = true
	elif not keep_surface and model.map_si != 0:
		model.set_map_surface(0)  # back to the character's surface, as in Factorio
	if not on:
		model.clear_patch()
	_reset_enter_3d()


func _build_enter_3d_bar() -> void:
	_enter_3d_panel = PanelContainer.new()
	_enter_3d_panel.name = "Enter3DBarPanel"
	_enter_3d_panel.theme_type_variation = "FFrame"
	_enter_3d_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_enter_3d_panel.visible = false
	_enter_3d_panel.anchor_left = 0.5
	_enter_3d_panel.anchor_right = 0.5
	_enter_3d_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_enter_3d_panel.offset_top = Kit.px(52)
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", Kit.px(4))
	var lbl := Kit.label("Scroll to enter 3D view", "FSmallLabel")
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(lbl)
	_enter_3d_bar = Kit.progress_bar(Kit.BAR_ORANGE)
	_enter_3d_bar.name = "Enter3DBar"
	_enter_3d_bar.custom_minimum_size = Vector2(Kit.px(160), Kit.px(10))
	_enter_3d_bar.max_value = 100.0
	_enter_3d_bar.value = 0.0
	box.add_child(_enter_3d_bar)
	_enter_3d_panel.add_child(box)
	add_child(_enter_3d_panel)


func _reset_enter_3d() -> void:
	_enter_3d_charge = 0.0
	_enter_3d_idle = 0.0
	if _enter_3d_bar != null:
		_enter_3d_bar.value = 0.0
	if _enter_3d_panel != null:
		_enter_3d_panel.visible = false


func _sync_enter_3d_bar() -> void:
	if _enter_3d_bar != null:
		_enter_3d_bar.value = _enter_3d_charge * 100.0
	if _enter_3d_panel != null:
		_enter_3d_panel.visible = _enter_3d_charge > 0.0
		_enter_3d_panel.reset_size()


static func map_auto_swap_enabled() -> bool:
	if Switches.has("--map-auto-swap=on"):
		return true
	if Switches.has("--map-auto-swap=off"):
		return false
	return bool(Settings.get_value("camera", "map_auto_swap"))


## Screen pixels per tile.
func scale_now() -> float:
	return zoom * Kit.scale


func screen_to_tiles(p: Vector2) -> Vector2:
	return centre + (p - size / 2.0) / scale_now()


func tiles_to_screen(t: Vector2) -> Vector2:
	return size / 2.0 + (t - centre) * scale_now()


## Zooms by `factor`, keeping the point under `at` (screen) where it is.
func zoom_by(factor: float, at: Vector2) -> void:
	var before := screen_to_tiles(at)
	if factor > 1.0 and zoom >= MAX_ZOOM - 0.001:
		# On another surface the mod streams that surface's world for the remote view (`view`).
		if map_auto_swap_enabled():
			_reset_enter_3d()
			zoom_to_world.emit(before)
			return
		_enter_3d_charge = minf(1.0, _enter_3d_charge + 1.0 / float(ENTER_3D_SCROLLS))
		_enter_3d_idle = 0.0
		if _enter_3d_charge >= 1.0 - 0.001:
			_reset_enter_3d()
			zoom_to_world.emit(before)
		else:
			_sync_enter_3d_bar()
		return
	if factor < 1.0 and _enter_3d_charge > 0.0:
		_reset_enter_3d()
	zoom = clampf(zoom * factor, MIN_ZOOM, MAX_ZOOM)
	if absf(zoom - 1.0) < 0.01:
		zoom = 1.0
	centre += before - screen_to_tiles(at)
	_pad_q = -1
	_redraw = true


func _character() -> Array:
	return character.call() if character.is_valid() else [Vector2.ZERO, 0.0]


func _process(delta: float) -> void:
	if not visible:
		return
	if _enter_3d_charge > 0.0:
		_enter_3d_idle += delta
		if _enter_3d_idle > ENTER_3D_HOLD_SEC:
			_enter_3d_charge = maxf(0.0, _enter_3d_charge - delta * ENTER_3D_DECAY_PER_SEC)
			if _enter_3d_charge <= 0.0:
				_reset_enter_3d()
			else:
				_sync_enter_3d_bar()
	var me := _character()
	if me[0] != _me[0] or me[1] != _me[1]:
		_me = me
		_redraw = true
	if following and model.map_si == 0:
		centre = _me[0]
	var pan := _pan_input()
	if pan != Vector2.ZERO:
		var speed := PAN_SPEED * Kit.scale * (3.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
		centre += pan * speed * delta / scale_now()
		following = false
		_pad_q = -1
		_redraw = true
	var scale := scale_now()
	var half := size / 2.0 / scale
	var chunks := MapCache.chunks_of(Rect2(centre - half, half * 2.0))
	# Beyond MAX_CHUNKS across, only the middle is asked for; the rest shows what was seen before.
	var middle := chunks.get_center()
	var cap := Vector2i(mini(chunks.size.x, MAX_CHUNKS), mini(chunks.size.y, MAX_CHUNKS))
	chunks = Rect2i(middle - cap / 2, cap)
	if Bridge.world_ready:
		cache.want(chunks, MapCache.resolution_for(scale), REFRESH)
		model.ask_map_trains()
		model.ask_roboports(model.shown_surface())
	cache.flush()
	_hover_patch()
	_hover_entity()
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST if scale >= 0.5 else CanvasItem.TEXTURE_FILTER_LINEAR
	if _alerts_blinked():
		_redraw = true
	if _redraw or not model.live_pings().is_empty():
		_redraw = false
		queue_redraw()
	# The layers draw again only what changed: their own data, or the view moved or zoomed.
	layers.character_at = _me[0]
	if _layers_now:
		_layers_now = false
		layers.redraw(centre, scale)
	else:
		layers.follow(centre, scale, false)


## L6: the resource patch under the mouse, asked for once it rests on a tile outside the one shown.
## The pick radius, in tiles: a few screen pixels, so a building is easy to hit when zoomed out.
func pick_radius() -> float:
	return maxf(0.1, Kit.px(4) / scale_now())


## The building under the mouse once it rests on a new tile: its name in a tooltip (Factorio's hover on the map).
func _hover_entity() -> void:
	if not Bridge.world_ready:
		return
	var mouse := get_local_mouse_position()
	if _dragging or dialog.is_open() or not Rect2(Vector2.ZERO, size).has_point(mouse) 			or get_viewport().gui_get_hovered_control() != self:
		_clear_hover()
		return
	var t := screen_to_tiles(mouse)
	var tile := Vector2i(floori(t.x), floori(t.y))
	var now := Time.get_ticks_msec()
	if tile != _pick_tile:
		_pick_tile = tile
		_pick_since = now
		_clear_hover()
		return
	if _hover_q < 0 and _hover_name == "" and now - _pick_since >= int(PATCH_REST * 1000.0):
		_hover_q = model.pick(t, pick_radius())
	if _tip.visible:
		_tip.position = mouse + Kit.pxv(14, 18)


func _clear_hover() -> void:
	_hover_q = -1
	_hover_name = ""
	if _tip != null:
		_tip.visible = false


func _on_picked(q: int, unit: int, proto_id: int, _fixed: Vector2i) -> void:
	if q == _click_q:
		_click_q = -1
		if unit > 0 and is_open():
			entity_picked.emit(unit, proto_id, _fixed)
	elif q == _hover_q:
		_hover_q = -1
		if unit > 0 and proto_name.is_valid() and is_open():
			_hover_name = Kit.entity_name(str(proto_name.call(proto_id)))
			_tip_label.text = _hover_name
			_tip.visible = _hover_name != ""
			_tip.position = get_local_mouse_position() + Kit.pxv(14, 18)
		else:
			_hover_name = "-"  # nothing there: not asked again on this tile


func _hover_patch() -> void:
	if not patch_info or not Bridge.world_ready:
		return
	var mouse := get_local_mouse_position()
	if _dragging or dialog.is_open() or not Rect2(Vector2.ZERO, size).has_point(mouse):
		return
	var t := screen_to_tiles(mouse)
	var tile := Vector2i(floori(t.x), floori(t.y))
	var now := Time.get_ticks_msec()
	if tile != _hover_tile:
		_hover_tile = tile
		_hover_since = now
		return
	if now - _hover_since < int(PATCH_REST * 1000.0) or model.patch_has(model.map_patch, tile):
		return
	model.ask_patch(tile)


## A patch's tiles (rows [y, x, length, ...]) as the segments round them, in pairs (tiles): each run's ends,
## and its top and bottom where the row above or below doesn't cover it.
static func outline_edges(rows: Array) -> PackedVector2Array:
	var spans := {}
	for row in rows:
		if not (row is Array) or row.size() < 3:
			continue
		var list: Array = []
		for i in range(1, row.size() - 1, 2):
			list.append(Vector2i(int(row[i]), int(row[i]) + int(row[i + 1])))
		spans[int(row[0])] = list
	var out := PackedVector2Array()
	for y in spans:
		for run: Vector2i in spans[y]:
			out.append_array([Vector2(run.x, y), Vector2(run.x, y + 1), Vector2(run.y, y), Vector2(run.y, y + 1)])
			for side in [[y, spans.get(y - 1, [])], [y + 1, spans.get(y + 1, [])]]:
				for piece: Vector2i in _uncovered(run, side[1]):
					out.append_array([Vector2(piece.x, side[0]), Vector2(piece.y, side[0])])
	return out


## The parts of `run` (x from, x to) that none of `others` covers.
static func _uncovered(run: Vector2i, others: Array) -> Array:
	var pieces: Array = [run]
	for o: Vector2i in others:
		var next: Array = []
		for p: Vector2i in pieces:
			if o.y <= p.x or o.x >= p.y:
				next.append(p)
				continue
			if o.x > p.x:
				next.append(Vector2i(p.x, o.x))
			if o.y < p.y:
				next.append(Vector2i(o.y, p.y))
		pieces = next
	return pieces


## The movement keys (WASD and the arrows unless rebound, as the help says), unless the tag dialog
## is being typed in.
func _pan_input() -> Vector2:
	if dialog.is_open() or search_field.has_focus():
		return Vector2.ZERO
	var v := Vector2.ZERO
	for a in [["move_left", Vector2.LEFT], ["move_right", Vector2.RIGHT], ["move_up", Vector2.UP], ["move_down", Vector2.DOWN]]:
		if InputMap.has_action(a[0]) and Input.is_action_pressed(a[0]):  # Shift (faster) held too
			v += a[1]
	return v.normalized()


## The alerts blink: true when the blink's phase flipped since the last call and there are alerts to
## draw (drawn again then, not every frame).
func _alerts_blinked() -> bool:
	var blink := MapCache.alerts_blink_on(Time.get_ticks_msec())
	if blink == _blink_was:
		return false
	_blink_was = blink
	if alerts == null:
		return false
	# Steady kinds (no_material, ...) look the same on both halves: no redraw for them alone.
	for mk in alerts.map_marks():
		if MapCache.alert_blinks(str(mk["kind"])):
			return true
	return false


func _draw() -> void:
	var area := Rect2(Vector2.ZERO, size)
	var scale := scale_now()
	draw_rect(area, Color8(17, 16, 14))  # uncharted: Factorio's near-black, not pure black
	cache.draw(self, area, centre, scale)
	var font := Kit.font("semibold")
	var font_size := Kit.px(14)
	var icon := float(Kit.px(24))
	if bool(settings.get_value("map/show_tags")):
		for tag in model.map_tags:
			var p := tiles_to_screen(tag["position"])
			if area.grow(icon + Kit.px(200)).has_point(p):
				MapCache.draw_tag(self, p, tag, icon, true, font, font_size)
	alerts_placed = MapCache.draw_alerts(self, alerts.map_marks(), tiles_to_screen, icon, area, model.shown_surface()) if alerts != null else []
	MapCache.draw_pings(self, model.live_pings(), tiles_to_screen, float(Kit.px(24)))
	if not _patch_edges.is_empty():
		var pts := PackedVector2Array()
		pts.resize(_patch_edges.size())
		for i in _patch_edges.size():
			pts[i] = tiles_to_screen(_patch_edges[i])
		draw_multiline(pts, PATCH_OUTLINE, maxf(1.0, Kit.px(2)))
	if model.map_si == 0:
		MapCache.draw_player(self, tiles_to_screen(_me[0]), float(_me[1]), float(Kit.px(20)))


## Factorio's surface switcher: planets first, then space platforms, the shown one pressed.
func _build_surfaces() -> void:
	surfaces_panel.name = "MapSurfaces"
	surfaces_panel.theme_type_variation = "FFrame"
	surfaces_panel.theme = MenuKit.theme()
	surfaces_panel.offset_left = Kit.px(12)
	surfaces_panel.offset_top = Kit.px(32)
	surfaces_panel.visible = false
	add_child(surfaces_panel)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", Kit.px(8))
	surfaces_panel.add_child(outer)
	outer.add_child(Kit.label("Surfaces", "FCaption"))
	var deep := Kit.panel("FDeepFrame")
	deep.custom_minimum_size.x = Kit.px(SURFACES_WIDTH)
	outer.add_child(deep)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 0)
	deep.add_child(inner)
	_space_box.add_theme_constant_override("separation", 0)
	inner.add_child(_space_box)
	# The list scrolls (the wheel scrolls it, not the map's zoom, while the mouse is over it); its height is
	# capped by fit_surfaces() so the panel stays above the weapon slots.
	_surface_scroll = ScrollContainer.new()
	_surface_scroll.name = "SurfaceScroll"
	_surface_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_surface_scroll.focus_mode = Control.FOCUS_NONE
	_surface_scroll.custom_minimum_size.x = Kit.px(SURFACES_WIDTH)
	inner.add_child(_surface_scroll)
	_surface_box.add_theme_constant_override("separation", 0)
	_surface_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_surface_scroll.add_child(_surface_box)


## Caps the Surfaces list's height so the panel's bottom stays at or above `limit_y` (screen pixels: the top
## of the weapon slots), from the panel's place, the window and the interface scale. Called each frame by
## remote_frame.gd; it only re-lays out when the numbers change. limit_y <= 0: no cap.
func fit_surfaces(limit_y: float) -> void:
	if _surface_scroll == null or not surfaces_panel.visible:
		return
	var content := _surface_box.get_combined_minimum_size().y
	var key := "%d|%d|%d|%d" % [roundi(limit_y), roundi(surfaces_panel.position.y), roundi(content), Kit.px(100)]
	if key == _fit_key:
		return
	_fit_key = key
	var h := content
	if limit_y > 0.0:
		var fixed := surfaces_panel.get_combined_minimum_size().y - _surface_scroll.custom_minimum_size.y
		var room := limit_y - surfaces_panel.position.y - fixed - Kit.px(4)
		h = minf(content, maxf(room, float(Kit.px(60))))
	_surface_scroll.custom_minimum_size.y = h
	surfaces_panel.reset_size()


func _on_surfaces_changed() -> void:
	_fit_key = ""
	for box in [_surface_box, _space_box]:
		for child in box.get_children():
			box.remove_child(child)
			child.queue_free()
	var list: Array = model.map_surfaces
	surfaces_panel.visible = list.size() >= 1
	_redraw = true
	if list.is_empty():
		return
	var planets: Array = list.filter(func(e: Dictionary) -> bool: return str(e["platform"]) == "" and str(e["planet"]) != "")
	var on_platforms: Array = list.filter(func(e: Dictionary) -> bool: return str(e["platform"]) != "")
	var others: Array = list.filter(func(e: Dictionary) -> bool: return str(e["platform"]) == "" and str(e["planet"]) == "")
	# Factorio's order: Space map, Planets, Platforms, the add button, then Other.
	var space := Button.new()
	space.name = "SpaceMap"
	space.text = "Space map"
	space.theme_type_variation = "FListItemSelected" if space_open else "FListItem"
	space.alignment = HORIZONTAL_ALIGNMENT_LEFT
	space.focus_mode = Control.FOCUS_NONE
	space.custom_minimum_size.y = Kit.px(30)
	space.pressed.connect(func() -> void: space_map_requested.emit())
	_space_box.add_child(space)
	_surface_box.add_child(_subheader("Planets"))
	for entry in planets:
		_surface_box.add_child(_surface_button(entry))
	_surface_box.add_child(_subheader("Platforms"))
	for entry in on_platforms:
		_surface_box.add_child(_surface_button(entry))
	var add := Button.new()
	add.name = "AddPlatform"
	add.text = "+ Add space platform"
	add.focus_mode = Control.FOCUS_NONE
	add.disabled = true
	add.tooltip_text = "Build a space platform starter pack from a rocket silo"
	add.custom_minimum_size.y = Kit.px(30)
	_surface_box.add_child(add)
	if not others.is_empty():
		_surface_box.add_child(_subheader("Other"))
		for entry in others:
			_surface_box.add_child(_surface_button(entry))


func _subheader(text: String) -> Control:
	var p := Kit.panel("FSubheader")
	p.add_child(Kit.label(text, "FHeading"))
	return p


func _surface_button(entry: Dictionary) -> Button:
	var b := Button.new()
	var si := int(entry["si"])
	var planet := str(entry["planet"])
	b.name = "Surface%d" % si
	var rich := _plain_name(str(entry["platform"]))
	var other := planet == "" and str(entry["platform"]) == ""
	b.text = LocaleNames.space_location(planet) if planet != "" else (str(entry["name"]) if other else rich[0])
	b.tooltip_text = b.text + ("  (you are here)" if si == model.character_si else "")
	if not other:
		b.icon = _surface_icon(planet) if planet != "" or rich[1] == "" else Kit.item_icon(rich[1])
	b.expand_icon = false
	b.add_theme_constant_override("icon_max_width", Kit.px(24))
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.theme_type_variation = "FListItemSelected" if si == model.shown_surface() and not space_open else "FListItem"
	# A platform's row shows the planet it is at (or going to) on the right, as Factorio's.
	var pf := int(entry.get("pf", 0))
	if pf != 0 and platforms != null and is_instance_valid(platforms) and platforms.platforms.has(pf):
		var p: Dictionary = platforms.platforms[pf]
		var at := TextureRect.new()
		at.name = "At"
		at.texture = _surface_icon(str(p.get("to", p.get("loc", ""))))
		at.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		at.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		at.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
		at.offset_left = -Kit.px(30)
		at.offset_right = -Kit.px(6)
		at.offset_top = Kit.px(3)
		at.offset_bottom = -Kit.px(3)
		at.mouse_filter = Control.MOUSE_FILTER_IGNORE
		at.texture_filter = Kit.ICON_FILTER
		b.add_child(at)
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(Kit.px(SURFACES_WIDTH), Kit.px(30))
	b.pressed.connect(func() -> void:
		show_surface(si)
		surface_chosen.emit(model.map_si))
	return b


## A platform name with Factorio's rich text ("[item=space-science-pack] run", "[planet=vulcanus]")
## as plain words, and the first item named in it ("" if none) for the button's icon.
static func _plain_name(name: String) -> Array:
	var re := RegEx.create_from_string("\\[(item|planet|space-location|fluid|virtual-signal|entity|recipe)=([^\\],]+)[^\\]]*\\]")
	var first := ""
	var out := name
	for m in re.search_all(name):
		var kind := m.get_string(1)
		var what := m.get_string(2)
		if first == "" and kind == "item":
			first = what
		var word := LocaleNames.space_location(what) if kind in ["planet", "space-location"] else Kit.pretty(what)
		out = out.replace(m.get_string(0), word)
	out = out.strip_edges()
	return [out if out != "" else name, first]


## A planet's icon (another mod's from the bridge's graphics list), or the platform hub's for a
## platform (or null).
static func _surface_icon(planet: String) -> Texture2D:
	if planet == "":
		return GuiAssets.data_sprite("space-age/graphics/icons/space-platform-hub.png")
	return SpacePanels.planet_icon(planet)


## Shows another surface's map (its index from model.map_surfaces), centred on its middle, or the
## character's again, centred on the character.
## Rebuilds the Surfaces panel (the platforms moved, or their data arrived).
func refresh_surfaces() -> void:
	_on_surfaces_changed()


func set_space_open(on: bool) -> void:
	if on != space_open:
		space_open = on
		_on_surfaces_changed()


## The platform the map shows (its `plat` record), or {}.
func shown_platform() -> Dictionary:
	if not visible or platforms == null or not is_instance_valid(platforms):
		return {}
	var si: int = model.shown_surface()
	for entry in model.map_surfaces:
		if int(entry["si"]) == si and int(entry.get("pf", 0)) != 0:
			return platforms.platforms.get(int(entry["pf"]), {})
	return {}


func show_surface(si: int, find_pad := true) -> void:
	_reset_enter_3d()
	model.set_map_surface(si)
	_on_surfaces_changed()
	dialog.close()
	_pad_q = -1
	if model.map_si == 0:
		following = true
		centre = _me[0]
	else:
		following = false
		centre = Vector2.ZERO  # a platform's hub; a planet's middle until its landing pad is known
		if find_pad and str(model.map_surface(model.map_si).get("planet", "")) != "":
			_pad_q = model.ask_landing_pad(model.map_si)
	_redraw = true


## The mod's answer: the planet's landing pad, where the view goes unless it was moved meanwhile.
func _on_landing_pad(si: int, q: int, at: Vector2, found: bool) -> void:
	if q != _pad_q:
		return
	_pad_q = -1
	if found and si == model.map_si and visible:
		centre = at
		_redraw = true


## Back from the remote view the map zoomed into (issue #4): the map on that surface (0 the
## character's), centred where the view was, optionally at its closest zoom.
func return_from_world(si: int, at: Vector2, set_max_zoom := true) -> void:
	look_at_on(si, at)
	if set_max_zoom:
		zoom = MAX_ZOOM


## The map on another surface (or the character's, 0), centred on `at` (tiles) and zoomed in: an
## alert's entity there.
func look_at_on(si: int, at: Vector2) -> void:
	show_surface(si, false)
	_pad_q = -1
	following = false
	centre = at
	zoom = maxf(zoom, DEFAULT_ZOOM * 2.0)
	_redraw = true


## Factorio's map view settings: under the side menu, a grid of its own icon buttons (the
## side-map-menu-buttons.png rows, read from the install) in its order, lit orange when on, each
## named by its option ("map-show_tags") with Factorio's name as its tooltip. Factorio's player
## names and pipelines switches aren't here: the map doesn't draw those yet.
const LAYER_BUTTONS := [["map/show_logistic", 0], ["map/show_electric", 1], ["map/show_turrets", 2],
	["map/show_pollution", 3], ["map/show_stops", 4], ["map/show_tags", 6], ["map/show_robots", 7],
	["map/show_signals", 8], ["map/show_recipes", 9]]
const LAYER_COLUMNS := 6


func _build_panel() -> void:
	panel.name = "MapViewSettings"
	panel.theme_type_variation = "FSlotWindow"
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.offset_right = -Kit.px(12)
	panel.offset_top = Kit.px(32)
	add_child(panel)
	var frame := Kit.panel("FDeepFrame")
	frame.add_theme_stylebox_override("panel", Kit.style_with_margins("deep", 0, 0, 0, 0))
	panel.add_child(frame)
	var grid := Kit.slot_grid(LAYER_COLUMNS)
	grid.name = "LayerGrid"
	frame.add_child(grid)
	var labels := {}
	for layer in UiSettings.MAP_LAYERS:
		labels[layer[0]] = layer[1]
	for spec in LAYER_BUTTONS:
		var key: String = spec[0]
		var b := Button.new()
		b.name = key.replace("/", "-")
		b.theme_type_variation = "FSideButton"
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Kit.pxv(Kit.SLOT, Kit.SLOT)
		b.icon = GuiAssets.core_region("icons/mip/side-map-menu-buttons.png", Rect2i(0, int(spec[1]) * 64, 64, 64))
		b.expand_icon = true
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.add_theme_constant_override("icon_max_width", Kit.px(32))
		if b.icon == null:
			b.text = str(labels.get(key, key)).substr(0, 2)
		b.tooltip_text = str(labels.get(key, key))
		b.button_pressed = bool(settings.get_value(key))
		b.toggled.connect(func(on: bool) -> void: settings.set_value(key, on))
		settings.changed.connect(func(k: String) -> void:
			if k == key:
				b.set_pressed_no_signal(bool(settings.get_value(key))))
		grid.add_child(b)
	for i in (LAYER_COLUMNS - LAYER_BUTTONS.size() % LAYER_COLUMNS) % LAYER_COLUMNS:
		grid.add_child(Kit.empty_cell())


## The tag drawn under a screen point, or {}.
func tag_at(p: Vector2) -> Dictionary:
	var best := {}
	var best_d := float(Kit.px(16)) ** 2
	if not bool(settings.get_value("map/show_tags")):
		return best  # hidden tags can't be clicked
	for tag in model.map_tags:
		var at := tiles_to_screen(tag["position"])
		if str(tag.get("icon_name", "")) == "":
			at.y -= Kit.px(12)  # the pin stands above its point
		var d := at.distance_squared_to(p)
		if d <= best_d:
			best_d = d
			best = tag
	return best


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null:
		if mb.pressed and dialog.is_open() and mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			if not mb.double_click:  # the second press of a double click on a tag must not close what the first opened
				dialog.close()
			accept_event()
			return
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					zoom_by(ZOOM_STEP, mb.position)
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					zoom_by(1.0 / ZOOM_STEP, mb.position)
			MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE:
				_dragging = mb.pressed
				if mb.button_index == MOUSE_BUTTON_LEFT:
					# A click (no drag) on a tag opens its properties, as Factorio's.
					if mb.pressed:
						_press_at = mb.position
					elif _press_at != Vector2.INF and mb.position.distance_to(_press_at) < Kit.px(4) and not tag_at(_press_at).is_empty() and not dialog.is_open():
						edit_tag_at(_press_at)
					elif _press_at != Vector2.INF and mb.position.distance_to(_press_at) < Kit.px(4) and not dialog.is_open() and not mb.double_click:
						click_entity(_press_at)
					if not mb.pressed:
						_press_at = Vector2.INF
				if mb.pressed and mb.double_click and mb.button_index == MOUSE_BUTTON_LEFT:
					_dragging = false
					edit_tag_at(mb.position)
			MOUSE_BUTTON_RIGHT:
				if mb.pressed:
					right_click(mb.position)
		accept_event()
		return
	var mm := event as InputEventMouseMotion
	if mm != null and _dragging and mm.button_mask & (MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_MIDDLE):
		centre -= mm.relative / scale_now()
		following = false
		_pad_q = -1
		_redraw = true
		accept_event()


## A click on the map: asks the mod for the building, train or vehicle there; entity_picked says which.
func click_entity(p: Vector2) -> void:
	_clear_hover()
	_click_q = model.pick(screen_to_tiles(p), pick_radius())


## Opens the tag dialog for the tag under a screen point, or to create one there.
## Right-click, as in Factorio: on a tag, edit it; else remove the ghost there, and where there is
## none, add a tag (the mod answers first: ghosts far away aren't in the client's world).
func right_click(p: Vector2) -> void:
	if not tag_at(p).is_empty():
		edit_tag_at(p)
		return
	_unghost[model.unghost(screen_to_tiles(p))] = p


func _on_unghost(q: int, n: int) -> void:
	var p = _unghost.get(q)
	_unghost.erase(q)
	if p is Vector2 and n == 0 and is_open():
		edit_tag_at(p)


func edit_tag_at(p: Vector2) -> void:
	var tag := tag_at(p)
	_tag_editing = int(tag["id"]) if not tag.is_empty() else -1
	_tag_at = tag["position"] if not tag.is_empty() else screen_to_tiles(p)
	dialog.open_at(p, tag)


func _on_tag_confirmed(text: String, icon_name: String) -> void:
	# There is no "change tag" command: an edit replaces the tag.
	if _tag_editing >= 0:
		model.remove_map_tag(_tag_editing)
	model.add_map_tag(_tag_at, text, (dialog.icon_type if dialog.icon_type != "" else "item") if icon_name != "" else "", icon_name)
	_tag_editing = -1


func _build_search() -> void:
	search_panel.theme_type_variation = "FFrame"
	search_panel.visible = false
	search_panel.anchor_left = 0.5
	search_panel.anchor_right = 0.5
	search_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	search_panel.offset_top = Kit.px(48)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Kit.px(6))
	search_panel.add_child(box)
	search_field.placeholder_text = "Search tags"
	search_field.custom_minimum_size = Vector2(Kit.px(320), Kit.px(28))
	MapTagDialog._style_textbox(search_field)
	search_field.text_changed.connect(func(_t: String) -> void: refresh_search())
	search_field.gui_input.connect(func(event: InputEvent) -> void:
		var key := event as InputEventKey
		if key != null and key.pressed and key.physical_keycode == KEY_ESCAPE:
			search_panel.visible = false
			search_field.release_focus()
			search_field.accept_event())
	box.add_child(search_field)
	box.add_child(_search_list)
	add_child(search_panel)


func toggle_search() -> void:
	search_panel.visible = visible and not search_panel.visible
	if search_panel.visible:
		search_field.text = ""
		refresh_search()
		search_field.grab_focus()
	else:
		search_field.release_focus()


## The tags whose text or icon matches the field, nearest the middle of the view first (at most 12).
func search_matches() -> Array:
	var needle := search_field.text.strip_edges().to_lower()
	var out: Array = []
	for tag in model.map_tags:
		var hay := (str(tag.get("text", "")) + " " + Kit.pretty(str(tag.get("icon_name", "")))).to_lower()
		if needle == "" or hay.contains(needle):
			out.append(tag)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["position"] as Vector2).distance_squared_to(centre) < (b["position"] as Vector2).distance_squared_to(centre))
	return out.slice(0, 12)


func refresh_search() -> void:
	for c in _search_list.get_children():
		_search_list.remove_child(c)
		c.queue_free()
	var found := search_matches()
	if found.is_empty():
		_search_list.add_child(Kit.label("Nothing found", "FSmallLabel"))
	for tag in found:
		var b := Button.new()
		b.theme_type_variation = "FBackButton"
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.focus_mode = Control.FOCUS_NONE
		var name := str(tag.get("text", ""))
		b.text = name if name != "" else Kit.pretty(str(tag.get("icon_name", "")))
		if str(tag.get("icon_name", "")) != "":
			b.icon = Kit.item_icon(str(tag["icon_name"]))
			b.expand_icon = true
			b.add_theme_constant_override("icon_max_width", Kit.px(20))
		b.pressed.connect(func() -> void:
			following = false
			centre = tag["position"]
			zoom = maxf(zoom, DEFAULT_ZOOM)
			_redraw = true
			_layers_now = true
			search_panel.visible = false)
		_search_list.add_child(b)
	search_panel.reset_size()


func _on_tag_deleted() -> void:
	if _tag_editing >= 0:
		model.remove_map_tag(_tag_editing)
	_tag_editing = -1


## Esc closes the dialog first, then the map. Returns true if it did something.
func escape() -> bool:
	if search_panel.visible:
		search_panel.visible = false
		search_field.release_focus()
		return true
	if dialog.is_open():
		dialog.close()
		return true
	if visible:
		open(false)
		return true
	return false
