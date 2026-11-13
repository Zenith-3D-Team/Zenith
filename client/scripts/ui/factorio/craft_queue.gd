extends HBoxContainer
## Factorio's crafting queue in the bottom-left corner: one crafting_queue_slot per queue entry
## with the recipe's icon and count, the first with the orange progress pie, the slots touching;
## the tooltip is Factorio's recipe tooltip. Click cancels one craft, right click five,
## Shift+click the whole entry; the ingredients come back. Needs the mod's
## `cq` (ui_model.craft_queue); with only the queue length (`me.q`) it shows nothing.
##
## `cq` says how far the first craft is six times a second, so the pie is moved every frame by the
## recipe's time and the character's crafting speed, at the game's measured tick rate, and each
## `cq` only corrects it (owner's P47: it stepped along). A craft asked for shows here at once
## (ui_model `craft`, P48), its pie already moving.

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const Slot := preload("res://scripts/ui/factorio/slot.gd")
const UiModel := preload("res://scripts/ui/factorio/ui_model.gd")
const CraftingPanel := preload("res://scripts/ui/factorio/crafting_panel.gd")

## Entries shown at most (Factorio wraps; this many fill a row at 1280x720 beside the weapons).
const MAX_SHOWN := 12
## An update further than this from the drawn pie is a new craft: it jumps there instead of easing.
const PIE_SNAP := 0.4
## How fast the drawn pie closes on what `cq` said (per second).
const PIE_EASE := 8.0
## With no `cq` for this long the game is paused or gone: the pie waits.
const PIE_WAIT_MS := 700

var model: UiModel
var _slots: Array[Slot] = []
## The first craft's drawn progress (-1: nothing crafting), what is left to correct, the recipe and
## how many remain, and when and at which game tick the last `cq` came.
var _pie := -1.0
var _pie_gap := 0.0
var _pie_recipe := ""
var _pie_count := 0
var _pie_at_ms := 0
var _pie_tick := 0
var _ticks_per_s := 60.0


func _ready() -> void:
	anchor_top = 1.0
	anchor_bottom = 1.0
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	offset_left = Kit.px(8)
	offset_bottom = -Kit.px(8)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 0)  # crafting_queue_slots touch, as in Factorio
	model.queue_changed.connect(refresh)
	refresh()


func refresh() -> void:
	var entries: Array = []
	for e in model.craft_queue:
		if e is Dictionary and int(e.get("count", 0)) > 0:
			entries.append(e)
	entries = entries.slice(0, MAX_SHOWN)
	while _slots.size() < entries.size():
		_slots.append(_new_slot(_slots.size()))
	for i in _slots.size():
		var s := _slots[i]
		s.visible = i < entries.size()
		if not s.visible:
			continue
		var e: Dictionary = entries[i]
		var recipe := str(e.get("recipe", ""))
		var r := model.recipe(recipe)
		s.set_stack(_icon_item(recipe, r), int(e.get("count", 1)))
		if i == 0:
			_pie_update(recipe, int(e.get("count", 1)), float(e.get("progress", 0.0)))
			s.set_progress(_pie)
		else:
			s.set_progress(-1.0)
		s.set_meta("index", 0 if e.get("predicted", false) else int(e.get("index", i + 1)))
		s.set_meta("count", int(e.get("count", 1)))
		s.set_tip("%s (Recipe)" % Kit.recipe_name(recipe), CraftingPanel.recipe_tip_lines(model, r))
	if entries.is_empty():
		_pie = -1.0
		_pie_recipe = ""


## A `cq` (or the same craft shown again): measures the game's tick rate and corrects the drawn pie.
func _pie_update(recipe: String, count: int, progress: float) -> void:
	var now := Time.get_ticks_msec()
	var tick: int = Bridge.server_tick
	if _pie_at_ms > 0 and now > _pie_at_ms and tick > _pie_tick:
		var measured := float(tick - _pie_tick) * 1000.0 / float(now - _pie_at_ms)
		_ticks_per_s = lerpf(_ticks_per_s, clampf(measured, 1.0, 120.0), 0.2)
	_pie_at_ms = now
	_pie_tick = tick
	var gap := progress - _pie
	gap -= roundf(gap)  # 0.98 drawn and 0.02 sent: the craft came round, 0.04 ahead
	if recipe != _pie_recipe or _pie < 0.0 or absf(gap) > PIE_SNAP:
		_pie = progress
		_pie_gap = 0.0
	else:
		_pie_gap = gap
	_pie_recipe = recipe
	_pie_count = count


func _process(delta: float) -> void:
	model.expire_predicted_crafts()
	if _pie < 0.0 or _slots.is_empty() or not _slots[0].visible:
		return
	if Time.get_ticks_msec() - _pie_at_ms < PIE_WAIT_MS:
		_pie += _pie_rate() * delta
	var ease_by := _pie_gap * (1.0 - exp(-delta * PIE_EASE))
	_pie += ease_by
	_pie_gap -= ease_by
	if _pie >= 1.0:
		# A craft done: on to the next if there is one, else full until the game says it is gone.
		_pie = fmod(_pie, 1.0) if _pie_count > 1 else 0.999
	_pie = maxf(_pie, 0.0)
	_slots[0].set_progress(_pie)


## How much of the first craft a second makes: 0 when the recipe's details aren't known.
func _pie_rate() -> float:
	var energy := float(model.recipe(_pie_recipe).get("energy", -1.0))
	if energy <= 0.0:
		return 0.0
	# `cinfo` craft: the character's crafting speed in thousandths.
	var speed := float(model.character_info.get("craft", 1000)) / 1000.0
	return speed / energy * _ticks_per_s / 60.0


func _new_slot(_i: int) -> Slot:
	var s := Slot.new()
	s.theme_type_variation = "FQueueSlot"
	var on_click := func(button_index: int, shift: bool) -> void:
		if button_index == MOUSE_BUTTON_MIDDLE or int(s.get_meta("index", 0)) <= 0:
			return  # no index: shown ahead of the game, which hasn't numbered it yet
		var n := 5 if button_index == MOUSE_BUTTON_RIGHT else 1
		if shift:
			n = int(s.get_meta("count", 1))
		model.cancel_craft(int(s.get_meta("index", 1)), n)
	s.clicked.connect(on_click)
	add_child(s)
	return s


static func _icon_item(recipe: String, r: Dictionary) -> String:
	var products: Array = r.get("products", [])
	if products.size() == 1 and products[0] is Array:
		return str(products[0][0])
	return recipe
