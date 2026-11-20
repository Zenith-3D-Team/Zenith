extends RefCounted
## One building drawn with another pack's model (the in-game model chooser, model_chooser.gd: the
## Model button in a building's window). Nothing goes to the game. A choice is kept per save (the
## bridge's welcome `sid`, Bridge.save_id) and building (its unit number) in
## user://building_models.cfg, put on the building's record as it arrives (world.gd _add: extra
## ModelLibrary.PACK_KEY, the pack's id), and forgotten when the game says the building is gone
## (`del`: mined or destroyed), so one built again is drawn as every other of its kind. A pack gone
## or off since is no choice (model_library.gd draws the usual model then) but kept, for when it
## comes back. A choice saved with the bundled pack's old id (Default) is read as Zenith's.

const ModelPacks := preload("res://scripts/world/model_packs.gd")

const PATH := "user://building_models.cfg"

static var _cfg: ConfigFile = null
static var _section := ""
static var _packs := {}  # unit -> pack id, the current save's


## The pack a building of this save is drawn from ("" the usual).
static func pack_for(sid: String, unit: int) -> String:
	if unit <= 0:
		return ""
	_use(sid)
	return str(_packs.get(unit, ""))


## Whether this save has any building drawn from a pack of its own (world.gd skips the lookup otherwise).
static func any(sid: String) -> bool:
	_use(sid)
	return not _packs.is_empty()


## Draws a building from `pack` ("" back to the usual) and keeps it.
static func choose(sid: String, unit: int, pack: String) -> void:
	if unit <= 0:
		return
	_use(sid)
	if pack == "":
		_packs.erase(unit)
		if _cfg.has_section_key(_section, str(unit)):
			_cfg.erase_section_key(_section, str(unit))
	else:
		_packs[unit] = pack
		_cfg.set_value(_section, str(unit), pack)
	_cfg.save(PATH)


## The building is gone from the game: its choice goes with it.
static func forget(sid: String, unit: int) -> void:
	if unit <= 0:
		return
	_use(sid)
	if not _packs.has(unit):
		return
	choose(sid, unit, "")


## Every building of this save drawn from a pack of its own: unit -> pack id (tests, the window).
static func all(sid: String) -> Dictionary:
	_use(sid)
	return _packs.duplicate()


## Read again from the file (tests: another user folder).
static func reload() -> void:
	_cfg = null
	_section = ""
	_packs = {}


static func _use(sid: String) -> void:
	var section := sid if sid != "" else "unnamed"
	if _cfg == null:
		_cfg = ConfigFile.new()
		_cfg.load(PATH)  # none yet: empty
		_section = ""
	if section == _section:
		return
	_section = section
	_packs = {}
	if _cfg.has_section(section):
		for key in _cfg.get_section_keys(section):
			var pack := ModelPacks.canonical_id(str(_cfg.get_value(section, key, "")))
			if pack != "" and int(key) > 0:
				_packs[int(key)] = pack
