extends RefCounted
## Entity, tile and item prototypes from the mod's dictionaries, looked up by the small ids
## that world messages use.


class EntityProto:
	var id := 0
	var name := ""
	var type := ""
	## Selection box in tiles, relative to the entity position, for the north-facing entity.
	## x is east, y is south (Factorio's axes).
	var box_min := Vector2.ZERO
	var box_max := Vector2.ZERO
	var color := Color.GRAY
	var tile_size := Vector2i.ONE

	func size() -> Vector2:
		return box_max - box_min

	func center() -> Vector2:
		return (box_min + box_max) * 0.5


var entities := {}  # id -> EntityProto
var entities_by_name := {}  # name -> EntityProto
var tile_colors := PackedColorArray()
var tile_names := PackedStringArray()
## Per tile id: 1 water, 2 empty space (a space platform's surroundings: nothing to draw), else 0.
var tile_is_water := PackedByteArray()
var _water_list := -1  # the graphics list (ModGraphics.generation) tile_is_water was worked out with
var item_names := {}  # id -> name
var fluid_names := {}  # id -> name
var fluid_colors := {}  # name -> Color
var item_places := {}  # item name -> the entity it builds, when that has another name (rail); "" none
## Entity types no item builds. An item named like one (the rocket and its projectile) builds
## nothing: picking it with Q put a "rocket" to build in the cursor, so clicks built (and failed)
## instead of opening the turret (issue #2). The mod also says so (iprotos' "" third value).
const NEVER_PLACED := {"projectile": true, "artillery-projectile": true, "explosion": true, "smoke-with-trigger": true,
	"sticker": true, "stream": true, "fire": true, "beam": true, "particle-source": true, "corpse": true,
	"character-corpse": true, "speech-bubble": true, "flying-text": true, "highlight-box": true}


func clear() -> void:
	entities.clear()
	entities_by_name.clear()
	item_names.clear()
	fluid_names.clear()
	fluid_colors.clear()
	item_places.clear()
	tile_colors = PackedColorArray()
	tile_names = PackedStringArray()
	tile_is_water = PackedByteArray()


## [id, name, type, x1, y1, x2, y2, r, g, b, tile_width, tile_height]
func add_entities(list: Array) -> void:
	for rec in list:
		if not (rec is Array) or rec.size() < 12:
			continue
		var p := EntityProto.new()
		p.id = int(rec[0])
		p.name = str(rec[1])
		p.type = str(rec[2])
		p.box_min = Vector2(float(rec[3]), float(rec[4]))
		p.box_max = Vector2(float(rec[5]), float(rec[6]))
		p.color = Color8(int(rec[7]), int(rec[8]), int(rec[9]))
		p.tile_size = Vector2i(int(rec[10]), int(rec[11]))
		entities[p.id] = p
		entities_by_name[p.name] = p


## [id, name, r, g, b]
func add_tiles(list: Array) -> void:
	for rec in list:
		if not (rec is Array) or rec.size() < 5:
			continue
		var id := int(rec[0])
		if tile_colors.size() <= id:
			tile_colors.resize(id + 1)
			tile_names.resize(id + 1)
			tile_is_water.resize(id + 1)
		var tile_name := str(rec[1])
		tile_colors[id] = Color8(int(rec[2]), int(rec[3]), int(rec[4]))
		tile_names[id] = tile_name
		tile_is_water[id] = _water_kind(tile_name)
	_water_list = _mod_graphics().generation


## Water again once a graphics list is applied: a mod's water tile is water by the list's record,
## and the list comes after `tprotos` (read from the cache or the bridge). True when a tile changed
## (world.gd then meshes the ground again).
func refresh_water() -> bool:
	var generation: int = _mod_graphics().generation
	if generation == _water_list:
		return false
	_water_list = generation
	var changed := false
	for id in tile_names.size():
		var kind := _water_kind(tile_names[id]) if tile_names[id] != "" else 0
		if kind != tile_is_water[id]:
			tile_is_water[id] = kind
			changed = true
	return changed


## Empty space first: it carries `water_tile` in its collision mask, and isn't water.
static func _water_kind(tile_name: String) -> int:
	return 2 if tile_name.ends_with("empty-space") else (1 if _terrain().is_water_tile(tile_name) else 0)


static func _mod_graphics() -> GDScript:
	return load("res://scripts/world/mod_graphics.gd")


## Water by its collision mask in Factorio's definitions (Gleba's wetlands, Aquilo's ocean), not
## only by name. Loaded, not preloaded: terrain_textures.gd preloads visuals.gd, which preloads this.
static func _terrain() -> GDScript:
	return load("res://scripts/world/terrain_textures.gd")


## [id, name] or [id, name, the entity it builds]
func add_items(list: Array) -> void:
	for rec in list:
		if rec is Array and rec.size() >= 2:
			item_names[int(rec[0])] = str(rec[1])
			if rec.size() >= 3:
				item_places[str(rec[1])] = str(rec[2])


## The entity an item builds, or null.
func placed_entity(item: String) -> EntityProto:
	var proto: EntityProto = entities_by_name.get(item_places.get(item, item))
	if proto != null and NEVER_PLACED.has(proto.type):
		return null
	return proto


## [id, name, r, g, b]: the fluid's base colour.
func add_fluids(list: Array) -> void:
	for rec in list:
		if rec is Array and rec.size() >= 5:
			fluid_names[int(rec[0])] = str(rec[1])
			fluid_colors[str(rec[1])] = Color8(int(rec[2]), int(rec[3]), int(rec[4]))


func fluid_name(id: int) -> String:
	return fluid_names.get(id, "")


func item_name(id: int) -> String:
	return item_names.get(id, "")


func entity(id: int) -> EntityProto:
	return entities.get(id)


func tile_color(id: int) -> Color:
	if id >= 0 and id < tile_colors.size():
		return tile_colors[id]
	return Color.MAGENTA


func is_water(id: int) -> bool:
	return id >= 0 and id < tile_is_water.size() and tile_is_water[id] == 1


func is_void(id: int) -> bool:
	return id >= 0 and id < tile_is_water.size() and tile_is_water[id] == 2
