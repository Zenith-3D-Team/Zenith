extends Node3D
## Items lying on the ground near the camera (`gi`): models, icon cards or blocks (item_cards.gd), at
## the positions the mod sends twice a second. They don't move, so each complete update simply
## replaces the last one. Each item can be found by where it lies (item_at), for the right button
## that picks one up (J18); one taken is hidden at once (take) until the next update says.

const ProtoDB := preload("res://scripts/world/protos.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")
const ItemModels := preload("res://scripts/world/item_models.gd")

## Just above the terrain, so the cards don't flicker into it.
const HEIGHT := 0.03
## Factorio's item-on-ground selection box is 0.17 tiles either way of where it lies.
const SELECT_HALF := 0.17

var protos: ProtoDB:
	set(value):
		protos = value
		_cards.protos = value

var _cards := ItemCards.new()
var _frame_tick := -1
var _groups := {}  # item id -> Array of Vector3, the update being received
var _yaws := {}  # item id -> Array of turns, by where each item lies
var _tiles := {}  # the update being received: Vector2i tile -> [[Vector2i fixed position, item id], ...]
var _drawn_tiles := {}  # the same for the update drawn, what item_at looks in
var _count := 0


func _ready() -> void:
	_cards.name = "Cards"
	_cards.contact = true  # a soft rim on the ground under each item (item_contact.gdshader)
	add_child(_cards)


func reset() -> void:
	_cards.reset()
	_groups.clear()
	_tiles.clear()
	_drawn_tiles.clear()
	_frame_tick = -1
	_count = 0


func count() -> int:
	return _count


## One part of an update: {t: "gi", k: tick, part, parts, l: [item id, x, y, ...]}. The parts of
## an update share k; it is drawn once its last part is in.
func handle(msg: Dictionary) -> void:
	var k := int(msg.get("k", 0))
	if k != _frame_tick:
		_frame_tick = k
		_groups = {}
		_yaws = {}
		_tiles = {}
	var list = msg.get("l")
	if list is Array:
		var i := 0
		while i + 2 < list.size():
			var item := int(list[i])
			var x := int(list[i + 1])
			var y := int(list[i + 2])
			# Its kind: the item with the variant of its model its place picks (ItemCards.variant_key).
			var id := _cards.variant_key(item, ItemModels.ModelPacks.variant_seed(Vector2i(x, y)))
			if not _groups.has(id):
				_groups[id] = []
				_yaws[id] = []
			_groups[id].append(Vector3(x / 256.0, HEIGHT, y / 256.0))
			_yaws[id].append(ItemCards.turn_for(x * 92821 + y))
			var tile := Vector2i(floori(x / 256.0), floori(y / 256.0))
			if not _tiles.has(tile):
				_tiles[tile] = []
			_tiles[tile].append([Vector2i(x, y), item])
			i += 3
	if int(msg.get("part", 1)) < int(msg.get("parts", 1)):
		return
	_drawn_tiles = _tiles
	_redraw()


func _redraw() -> void:
	_cards.draw(_groups, _yaws)
	_count = 0
	for id in _groups:
		_count += (_groups[id] as Array).size()


## The item lying under `p` (tiles), the nearest within its selection box: [Vector2i position in
## 1/256 tile, item id], or [] when none.
func item_at(p: Vector2) -> Array:
	var best: Array = []
	var best_d := INF
	var t := Vector2i(floori(p.x), floori(p.y))
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			for e: Array in _drawn_tiles.get(t + Vector2i(dx, dy), []):
				var at := Vector2(e[0]) / 256.0
				if absf(at.x - p.x) > SELECT_HALF or absf(at.y - p.y) > SELECT_HALF:
					continue
				var d := at.distance_squared_to(p)
				if d < best_d:
					best_d = d
					best = e
	return best


## Hides the item at `fixed` (1/256 tile) the moment the right button takes it; the next update
## shows it again if the game didn't let it go (out of reach, the inventory full).
func take(fixed: Vector2i) -> void:
	var tile := Vector2i(floori(fixed.x / 256.0), floori(fixed.y / 256.0))
	var list: Array = _drawn_tiles.get(tile, [])
	for i in list.size():
		if list[i][0] != fixed:
			continue
		var id := int(list[i][1])
		list.remove_at(i)
		var at := Vector3(fixed.x / 256.0, HEIGHT, fixed.y / 256.0)
		var spots: Array = _groups.get(id, [])
		for j in spots.size():
			if (spots[j] as Vector3).is_equal_approx(at):
				spots.remove_at(j)
				(_yaws[id] as Array).remove_at(j)
				break
		_redraw()
		return
