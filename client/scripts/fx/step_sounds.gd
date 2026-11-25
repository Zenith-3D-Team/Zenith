extends RefCounted
## The character's steps as Factorio's prototypes give them (step 5 task 3a): the bridge's `steps` message
## (its data stage's zenith-step-sounds, step_sounds.lua) lists each tile's, rail's, resource's and
## decorative's walking_sound, the belts' and heat pipes' utility sounds and armours' step sounds. fx.gd
## asks here first and plays the answer with sfx.play_def, at the prototype's volume and variations, mods'
## files too (sound_bank.gd finds them in their folder or zip). It falls back to its own name table when
## there is no list (an older bridge, or the bridge's data stage couldn't make it), when a sound's files
## aren't on this PC (a server elsewhere with mods this PC hasn't), or with `--steps=table`.
##
## A tile the list knows without a walking sound (deep water, lava, empty space) is walked on in silence.
## Armours' sounds are kept but not played yet (task 3b waits for a listen in Factorio).

const SoundBank := preload("res://scripts/fx/sound_bank.gd")
const Switches := preload("res://scripts/switches.gd")
const Wire := preload("res://scripts/util/wire.gd")

## `--steps=table`: the name table as before, whatever the bridge sends.
static var use_table := Switches.has("--steps=table")

## What a lookup gives for a sound that is listed as none.
const SILENT := 0

## [key (prefix String or Array of files), volume x 100, count] per sound, from 1 (index 0 unused).
var _sounds: Array = [null]
var tiles := {}  # tile id -> sound
var entities := {}  # entity prototype id -> sound (rails, resources)
var decoratives := {}  # decorative id -> sound
var armor := {}  # item id -> [steps sound, moving sound]
var utility: Array = [0, 0]  # [metal (belts), heat pipe]
var night_vision: Array = [0, 0]  # [activate, deactivate] of the night vision equipment
## True once a whole list came.
var listed := false
var _gathering: Dictionary = {}
var _defs := {}  # sound -> SoundDef, or null when its files aren't here
var _defs_gen := -1


func reset() -> void:
	_sounds = [null]
	tiles.clear()
	entities.clear()
	decoratives.clear()
	armor.clear()
	utility = [0, 0]
	night_vision = [0, 0]
	listed = false
	_gathering = {}
	_defs.clear()


## A `steps` part. The list in use changes only once its last part is in.
func handle(msg: Dictionary) -> void:
	var part := int(msg.get("part", 1))
	if part == 1 or _gathering.is_empty():
		_gathering = {"s": [null], "tl": {}, "el": {}, "dl": {}, "al": {}, "u": [0, 0], "nv": [0, 0]}
	for e in Wire.array(msg.get("s")):
		_gathering["s"].append(e if e is Array and e.size() >= 3 else null)
	for key in ["tl", "el", "dl"]:
		var into: Dictionary = _gathering[key]
		for rec in Wire.array(msg.get(key)):
			if rec is Array and rec.size() >= 2:
				into[int(rec[0])] = int(rec[1])
	for rec in Wire.array(msg.get("al")):
		if rec is Array and rec.size() >= 3:
			_gathering["al"][int(rec[0])] = [int(rec[1]), int(rec[2])]
	var u = msg.get("u")
	if u is Array and u.size() >= 2:
		_gathering["u"] = [int(u[0]), int(u[1])]
	var nv = msg.get("nv")
	if nv is Array and nv.size() >= 2:
		_gathering["nv"] = [int(nv[0]), int(nv[1])]
	if part < int(msg.get("parts", 1)):
		return
	_sounds = _gathering["s"]
	tiles = _gathering["tl"]
	entities = _gathering["el"]
	decoratives = _gathering["dl"]
	armor = _gathering["al"]
	utility = _gathering["u"]
	night_vision = _gathering["nv"]
	_gathering = {}
	_defs.clear()
	listed = true


## What to play for `id` in `map` (tiles, entities, decoratives): a SoundDef, SILENT, or null when the
## list doesn't say (or says a sound whose files aren't here): the table's then.
func lookup(map: Dictionary, id: int) -> Variant:
	if use_table or not listed or not map.has(id):
		return null
	return sound(int(map[id]))


## Sound number `i` as a SoundDef (null when its files aren't here); SILENT for 0.
func sound(i: int) -> Variant:
	if i == 0:
		return SILENT
	if use_table or i < 0 or i >= _sounds.size() or _sounds[i] == null:
		return null
	var gen := SoundBank.generation()
	if gen != _defs_gen:
		_defs.clear()
		_defs_gen = gen
	if not _defs.has(i):
		_defs[i] = _make_def(_sounds[i])
	return _defs[i]


## A utility sound (0 metal, 1 heat pipe), or null.
func utility_sound(which: int) -> Variant:
	if use_table or not listed:
		return null
	var d: Variant = sound(int(utility[which]))
	return d if d is SoundBank.SoundDef else null


## The night vision equipment's own sound as it turns on (`on`) or off, or null (no list, no sound, or its
## file isn't on this PC: Factorio's 2.1 prototype has both, nightvision-on and -off).
func night_vision_sound(on: bool) -> Variant:
	if use_table or not listed:
		return null
	var d: Variant = sound(int(night_vision[0 if on else 1]))
	return d if d is SoundBank.SoundDef else null


## The files of a listed sound that are found, at its volume; with the rules Factorio's prototypes give
## its first file (priority, reach, pitch, aggregation) when the sound bank knows them. Null when none is found.
static func _make_def(e: Array) -> SoundBank.SoundDef:
	var files := files_of(e)
	var found := PackedStringArray()
	for f in files:
		if f.ends_with(".ogg") and SoundBank.exists(f):
			found.append(f)
	if found.is_empty():
		return null
	var volume := clampf(float(e[1]) / 100.0, 0.0, 4.0)
	var d := SoundBank.SoundDef.new()
	d.files = found
	d.key = found[0]
	var known := SoundBank.sound_for_file(found[0])
	if known != null:
		d.reach = known.reach
		d.attenuation = known.attenuation
		d.priority = known.priority
		d.min_speed = known.min_speed
		d.max_speed = known.max_speed
		d.max_count = known.max_count
		d.remove = known.remove
		d.count_already_playing = known.count_already_playing
		d.progress_threshold = known.progress_threshold
		d.volume_reduction_rate = known.volume_reduction_rate
		d.allow_random_repeat = known.allow_random_repeat
	for i in found.size():
		d.min_volumes.append(volume)
		d.max_volumes.append(volume)
	return d


## A listed sound's files: its list, or its prefix's numbered variations (one: prefix.ogg, else prefix-1.ogg).
static func files_of(e: Array) -> PackedStringArray:
	var out := PackedStringArray()
	if e[0] is Array:
		for f in e[0]:
			out.append(str(f))
		return out
	var prefix := str(e[0])
	var n := int(e[2])
	if n <= 1:
		out.append(prefix + ".ogg" if SoundBank.exists(prefix + ".ogg") else prefix + "-1.ogg")
		return out
	for i in range(1, n + 1):
		out.append("%s-%d.ogg" % [prefix, i])
	return out


## The name a step's kind gives it (`step/<name>`): its first file's, without the variation's number.
## The add-on kind a plant's rustle plays as ("rustle/plant"): its own, so an add-on replacing "step"
## doesn't also replace the rustle on top of it (one footfall, two of the add-on's sounds).
static func rustle_kind(d: SoundBank.SoundDef) -> String:
	return "rustle/" + name_of(d)


static func name_of(d: SoundBank.SoundDef) -> String:
	var f := d.files[0].get_file().get_basename() if d != null and not d.files.is_empty() else ""
	var dash := f.rfind("-")
	if dash > 0 and f.substr(dash + 1).is_valid_int():
		f = f.substr(0, dash)
	return f
