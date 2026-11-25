extends RefCounted
## api.sound (1.7): an add-on plays its own sounds, and replaces or mutes the sounds Zenith plays by
## kind (sfx.gd KINDS: "step/grass", "shot/pistol", "ui/gui-click"...). Everything goes through Zenith's
## own players and buses: an add-on never gets a bus or a player of its own, so the player's sliders,
## tick boxes, --mute and the master limiter always apply. The add-on's files are found through
## SoundBank (register_file, keys "addon:<id>/<path>") and decoded on workers as Zenith's own.
## Undone when the add-on stops (_release). docs/ADDONS.md is the reference.

const Sfx := preload("res://scripts/fx/sfx.gd")
const SoundBank := preload("res://scripts/fx/sound_bank.gd")
const FxSettings := preload("res://scripts/fx/fx_settings.gd")
const ModFiles := preload("res://scripts/world/mod_files.gd")

## Zenith played a sound of `kind` ("step/grass"): info {at (Vector3, or null for the windows'), path
## (the file played), by (the add-on whose replacement it was, "" for Zenith's own), bus}. Emitted only
## while something is connected; not for a muted kind. (A property over the signal `_played`: the
## first time it is read, to connect, this add-on joins Sfx.listeners, so an add-on that never listens
## costs Zenith's sounds nothing.)
var played: Signal:
	get:
		if not _listening:
			_listening = true
			Sfx.listeners.append(self)
		return _played

signal _played(kind: String, info: Dictionary)

var _api
var _listening := false
var _loops: Array[int] = []


func _init(_host, api) -> void:
	_api = api


## A one-shot. `sound`: a file in the add-on's folder ("sounds/boing.ogg"), a Factorio path
## ("__base__/sound/car-door-open.ogg"), either without ".ogg" for its numbered variations (a random
## one), or an AudioStream. Options: `at` (a Vector3; absent: not positional, as the windows'), `bus`
## ("effects"), `volume` (0 to 1), `pitch_spread`, `reach` (times the audible distance). False when it
## didn't play: no game's sound running, a file not found, still decoding (preload_sounds() first), out of
## hearing, or no voice free.
func play(sound: Variant, options := {}) -> bool:
	var sfx = Sfx.instance
	if sfx == null or not is_instance_valid(sfx):
		return false
	var bus := _bus(str(options.get("bus", "effects")))
	var loud := clampf(float(options.get("volume", 1.0)), 0.0, 1.0)
	var at: Variant = options.get("at")
	if at != null and not (at is Vector3):
		push_warning("[%s] api.sound.play: `at` must be a Vector3" % _api.id)
		return false
	var what: Variant = sound
	if not (sound is AudioStream):
		var files := _files(sound)
		if files.is_empty():
			return false
		what = files[randi() % files.size()]
		# Decoded on a worker, positional or not: a long file decoded on the spot stalls a frame
		# (110-340 ms for a first decode). False until it is in (preload_sounds() avoids that); then
		# play_addon's SoundBank.stream() finds it decoded.
		if SoundBank.stream_soon(what) == null:
			return false
	return sfx.play_addon(what, at, loud, float(options.get("pitch_spread", 0.0)), float(options.get("reach", 1.0)), bus)


## Starts decoding these sounds (as play() takes them; one or an Array), so their first play isn't lost.
func preload_sounds(sounds: Variant) -> void:
	for f in _files(sounds):
		SoundBank.stream_soon(f)


## (1.8) Starts a looping sound (a path in the add-on's folder, a Factorio path, or an
## AudioStream). Options: `at` (Vector3; absent: non-positional), `bus` ("effects", "ambient"...),
## `volume` (0 to 1), `pitch` (0.25 to 4), `reach`, `fade_in` (seconds). Returns a positive handle,
## or 0 on failure / voice cap.
func loop(sound: Variant, options := {}) -> int:
	var sfx = Sfx.instance
	if sfx == null or not is_instance_valid(sfx):
		return 0
	var at: Variant = options.get("at")
	if at != null and not (at is Vector3):
		push_warning("[%s] api.sound.loop: `at` must be a Vector3" % _api.id)
		return 0
	var bus := _bus(str(options.get("bus", "effects")))
	var loud := clampf(float(options.get("volume", 1.0)), 0.0, 1.0)
	var pitch := clampf(float(options.get("pitch", 1.0)), 0.25, 4.0)
	var reach := maxf(float(options.get("reach", 1.0)), 0.05)
	var fade_in := maxf(float(options.get("fade_in", 0.35)), 0.02)
	var what: Variant = sound
	if not (sound is AudioStream):
		var files := _files(sound)
		if files.is_empty():
			return 0
		what = files[randi() % files.size()]
	var handle: int = int(sfx.start_addon_loop(str(_api.id), what, at, loud, pitch, reach, bus, fade_in))
	if handle > 0:
		_loops.append(handle)
	return handle


## (1.8) Updates an active loop's `volume` (0 to 1), `pitch` (0.25 to 4), `reach`, or `at` (Vector3).
func update_loop(handle: int, options := {}) -> bool:
	var sfx = Sfx.instance
	if sfx == null or not is_instance_valid(sfx) or handle <= 0:
		return false
	return bool(sfx.update_addon_loop(str(_api.id), handle, options))


## (1.8) Fades out and stops a loop started by loop() (0 stops immediately).
func stop_loop(handle: int, fade_out := 0.35) -> bool:
	_loops.erase(handle)
	var sfx = Sfx.instance
	if sfx == null or not is_instance_valid(sfx) or handle <= 0:
		return false
	return bool(sfx.stop_addon_loop(str(_api.id), handle, fade_out))


## Zenith plays these (as play() takes them, one or an Array; a random one each time) where it would
## play `kind`. Options: `volume` (0 to 1; absent: the replaced sound's own). The last add-on to replace
## a kind wins; when it restores or stops, the one before comes back. False when refused (an unknown
## kind, no file found, or --addon-sounds=off).
func replace(kind: String, sounds: Variant, options := {}) -> bool:
	if not _kind_ok(kind, "replace"):
		return false
	var files := _files(sounds)
	if files.is_empty():
		push_warning("[%s] api.sound.replace(%s): no sound file found" % [_api.id, kind])
		return false
	var loud := clampf(float(options["volume"]), 0.0, 1.0) if options.has("volume") else -1.0
	Sfx.push_kind(kind, _api.id, files, loud)
	for f in files:
		SoundBank.stream_soon(f)
	return true


## Nothing plays for `kind` (the last add-on to replace or mute a kind wins). False when refused.
func mute(kind: String) -> bool:
	if not _kind_ok(kind, "mute"):
		return false
	Sfx.push_kind(kind, _api.id, PackedStringArray())
	return true


## Undoes this add-on's replace and mute of `kind`, or of every kind ("").
func restore(kind := "") -> void:
	Sfx.pop_kinds(_api.id, kind)


## The kinds Zenith plays (each also with a detail: "step/grass", "shot/pistol").
func kinds() -> PackedStringArray:
	return PackedStringArray(Sfx.KINDS)


## The player's volume for a bus (0 to 1; 0 while its tick box is off). Read-only.
func volume(bus: String) -> float:
	if not FxSettings.volumes.has(bus):
		return 0.0
	return float(FxSettings.volumes[bus]) if bool(FxSettings.enabled.get(bus, true)) else 0.0


## The add-on stopped: its replaces, mutes and loops go, its files are forgotten.
func _release() -> void:
	Sfx.pop_kinds(_api.id)
	Sfx.listeners.erase(self)
	_listening = false
	Sfx.refresh_hearing()
	if Sfx.instance != null and is_instance_valid(Sfx.instance):
		Sfx.instance.stop_addon_loops(str(_api.id))
	_loops.clear()
	SoundBank.forget_files("addon:%s/" % _api.id)


func _kind_ok(kind: String, call: String) -> bool:
	if not kind.get_slice("/", 0) in Sfx.KINDS:
		push_warning("[%s] api.sound.%s: no kind \"%s\" (api.sound.kinds())" % [_api.id, call, kind])
		return false
	if not Sfx.addon_sounds:
		if FxSettings.log_sounds:
			print("sfx: %s %s by %s ignored (--addon-sounds=off)" % [kind, call, _api.id])
		return false
	return true


## The bus for a volume key (fx_settings.gd BUSES, not "master"); "Effects" for any other.
func _bus(key: String) -> String:
	if key == "master" or not FxSettings.BUSES.has(key):
		push_warning("[%s] api.sound: no bus \"%s\", effects used" % [_api.id, key])
		return "Effects"
	return str(FxSettings.BUSES[key][0])


## SoundBank's paths for what play() takes: the add-on's own files registered under "addon:<id>/".
func _files(sounds: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	var list: Array = sounds if sounds is Array else (Array(sounds) if sounds is PackedStringArray else [sounds])
	for s in list:
		if not (s is String) or str(s) == "":
			continue
		var name := str(s)
		if name.begins_with("__"):
			out.append_array(_factorio(name))
		else:
			out.append_array(_own(name))
	return out


## "__base__/sound/x.ogg" -> SoundBank's "base/sound/x.ogg" (the install's mods by folder; another
## mod's stays "__mod__/...", read from its folder or zip).
func _factorio(name: String) -> PackedStringArray:
	if ".." in name.replace("\\", "/").split("/"):
		push_warning("[%s] api.sound: \"%s\" leaves the mod's folder" % [_api.id, name])
		return PackedStringArray()
	var mod := name.substr(2, name.find("__", 2) - 2)
	var path := name
	if mod in ModFiles.BUILT_IN:
		path = mod + name.substr(name.find("__", 2) + 2)
	if path.ends_with(".ogg"):
		return PackedStringArray([path]) if SoundBank.exists(path) else PackedStringArray()
	return SoundBank.variants(path)


## A file (or numbered variations) in the add-on's own folder, registered with SoundBank.
func _own(name: String) -> PackedStringArray:
	# Either separator, folded first: "sounds\..\..\x" must not pass a check that splits on "/" only.
	var rel := name.replace("\\", "/").simplify_path()
	if rel.begins_with("/") and not rel.begins_with("//"):
		rel = rel.trim_prefix("/")  # "/sounds/x": the add-on's folder is the root
	if rel == "" or rel == "." or rel == ".." or rel.begins_with("../") or rel.is_absolute_path():
		push_warning("[%s] api.sound: \"%s\" is outside the add-on's folder" % [_api.id, name])
		return PackedStringArray()
	var out := PackedStringArray()
	var names := [rel] if rel.ends_with(".ogg") else [rel + ".ogg"]
	if not rel.ends_with(".ogg") and not FileAccess.file_exists(str(_api.dir).path_join(rel + ".ogg")):
		names = []
		for i in range(1, 25):
			var n := "%s-%d.ogg" % [rel, i]
			if not FileAccess.file_exists(str(_api.dir).path_join(n)):
				break
			names.append(n)
	for n: String in names:
		var file := str(_api.dir).path_join(n)
		if not FileAccess.file_exists(file):
			push_warning("[%s] api.sound: no file %s" % [_api.id, n])
			continue
		var key := "addon:%s/%s" % [_api.id, n]
		if SoundBank.locate(key).get("file", "") != file:
			SoundBank.register_file(key, file)
		out.append(key)
	return out
