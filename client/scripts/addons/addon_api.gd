extends RefCounted
## The one object an add-on gets (its entry script's addon_start(api)); docs/ADDONS.md is the
## reference for add-on authors. Versioned: `version` is the add-on API this Zenith offers
## (AddonLoader.API_VERSION) and `level` the exact one with its additions (AddonLoader.API_LEVEL,
## 1.7); an add-on whose addon.json asks for a newer one isn't loaded.
## Everything here only reads the game or changes what this client shows, except `game`: an add-on
## changes the game only through a Factorio mod of its own that everyone in that game has (api.game).
##
##   camera    take the camera and hand it back (addon_camera.gd)
##   keys      the add-on's own controls, in Settings â†’ Controls (addon_keys.gd)
##   world     what the client knows of the game, read-only (addon_world.gd)
##   events    a train leaving, a rocket launching, a fight starting... as signals (addon_events.gd)
##   view      hide the interface, save frames, hold the time of day; (1.6) full detail and
##             screenshots (addon_view.gd)
##   ui        windows in Zenith's style, messages, an overlay layer (addon_ui.gd)
##   updates   ask the bridge for lighter updates (addon_updates.gd)
##   storage   the add-on's data, per save and for all saves (addon_storage.gd)
##   settings  (1.1) settings shown on the add-on's page of the Add-ons menu (addon_settings.gd)
##   terrain   (1.2) hills under the flat world, drawn only (addon_terrain.gd)
##   shaders   (1.3) looks and full-screen shader passes, drawn only (addon_shaders.gd)
##   character (1.7) the client's own character: its state, gear and moments (addon_character.gd)
##   sound     (1.7) its own sounds, and Zenith's replaced or muted by kind (addon_sound.gd)
##   game      (1.7) messages to and from a Factorio mod of the add-on's own (addon_game.gd)
##   weather   (1.8) atmosphere, sky, cloud, wind, and wet/puddle surface overrides (addon_weather.gd)
##   creatures (1.9) enemy damage/death hooks, ragdoll node/limb helpers, blood puddles, live overrides (addon_creatures.gd)

const AddonLoader := preload("res://scripts/addons/addon_loader.gd")
const AddonCamera := preload("res://scripts/addons/addon_camera.gd")
const AddonKeys := preload("res://scripts/addons/addon_keys.gd")
const AddonView := preload("res://scripts/addons/addon_view.gd")
const AddonUi := preload("res://scripts/addons/addon_ui.gd")
const AddonUpdates := preload("res://scripts/addons/addon_updates.gd")
const AddonStorage := preload("res://scripts/addons/addon_storage.gd")
const AddonSettings := preload("res://scripts/addons/addon_settings.gd")
const AddonTerrain := preload("res://scripts/addons/addon_terrain.gd")
const AddonShaders := preload("res://scripts/addons/addon_shaders.gd")
const AddonWorld := preload("res://scripts/addons/addon_world.gd")
const AddonCharacter := preload("res://scripts/addons/addon_character.gd")
const AddonSound := preload("res://scripts/addons/addon_sound.gd")
const AddonGame := preload("res://scripts/addons/addon_game.gd")
const AddonWeather := preload("res://scripts/addons/addon_weather.gd")
const AddonCreatures := preload("res://scripts/addons/addon_creatures.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")
const NATIVE_CLASSES := ["BiterRagdollNative", "BiterGoreNative", "AcidGooNative", "BiterAnimNative"]

## A game started (the world is being received) or ended (back to the menu).
signal game_started
signal game_ended
## (1.92) The game set a filmed scene's cue (a mod's remote.call("zenith", "set_cue", tick)): the new
## cue tick, -1 when cleared. api.world.cue_tick() returns it from then on.
signal cue_changed(tick: int)

## The add-on API this Zenith offers.
var version := AddonLoader.API_VERSION
## The add-on API with its additions within the version (1.1: settings, view.keep_drawing; 1.2:
## terrain; 1.3: shaders; 1.6: world.hold_chunks, view.full_detail, view.screenshot; 1.7: character,
## camera.mode, game, addons, sound; 1.8: weather; 1.9: creatures; 1.91: world.tick, smooth_tick, cue_tick; 1.92: cue_changed, a cue set by the game). Check it before using a newer call to keep working on a Zenith with 1.0:
## `if api.get("level") != null and api.level >= 1.1`.
var level := AddonLoader.API_LEVEL
## Zenith's own version, for messages.
var zenith_version := "Zenith %s" % str(ProjectSettings.get_setting("application/config/version", "(development build)"))
## The add-on's id, name, version and folder, from its addon.json.
var id := ""
var name := ""
var addon_version := ""
var dir := ""

var camera: AddonCamera
var keys: AddonKeys
var world  # addon_world.gd, one per add-on (its reads are the same for all)
var events  # addon_events.gd, shared by every add-on
var view: AddonView
var ui: AddonUi
var updates: AddonUpdates
var storage: AddonStorage
var settings: AddonSettings
var terrain: AddonTerrain
var shaders: AddonShaders
var sound: AddonSound
## (1.7) The client's own character (addon_character.gd), one per add-on. Made on first read. Zenith
## starts watching it for this add-on's signals (addon_watch.gd) when one of them is first read, also
## through a copy kept for later: reads and set_lift alone cost nothing each frame.
var character: AddonCharacter:
	get:
		if _character == null and _host != null:
			_character = AddonCharacter.new(_host, self)
		return _character

var _character: AddonCharacter

var addons = preload("res://scripts/addons/addon_addons.gd").new(self)  # (1.7) other add-ons: version(id) (addon_addons.gd)
var game: AddonGame
var weather: AddonWeather
var creatures: AddonCreatures

var _host  # addon_host.gd


func _setup(host, manifest: Dictionary) -> void:
	_host = host
	id = str(manifest["id"])
	name = str(manifest["name"])
	addon_version = str(manifest["version"])
	dir = str(manifest["dir"])
	camera = AddonCamera.new(host, self)
	keys = AddonKeys.new(host, self)
	world = AddonWorld.new(host, self)  # its own: hold_chunks is per add-on
	events = host.events
	view = AddonView.new(host, self)
	ui = AddonUi.new(host, self)
	updates = AddonUpdates.new(host, self)
	storage = AddonStorage.new(host, self)
	settings = AddonSettings.new(host, self)
	terrain = AddonTerrain.new(host, self)
	shaders = AddonShaders.new(host, self)
	sound = AddonSound.new(host, self)
	game = AddonGame.new(host, self)
	weather = AddonWeather.new(host, self)
	creatures = AddonCreatures.new(host, self)


## Everything the add-on set up through the API, taken away again (it was switched off).
func _teardown() -> void:
	camera.release()
	camera.clear_modifier()
	keys._remove_all()
	ui._close_all()
	updates.clear()
	view._release()
	_host.hold_chunks(self, false)
	settings._remove_all()
	terrain.clear()
	shaders.clear()
	sound._release()
	game._close_all()
	weather.clear()
	creatures.clear()
	camera._clear_mode()
	if _character != null:
		_character._clear()
		_character.clear_lift()
		_host.character_release(_character)  # its nodes freed, its pose, muzzle and tools gone
	_host.watch.forget(self)


## After _teardown, once the host has let go of this object too (addon_host.gd stop): each part holds
## this object, and this object them; the cycle broken, both are freed once the add-on's own
## references go.
func _let_go() -> void:
	camera = null
	keys = null
	world = null
	events = null
	view = null
	ui = null
	updates = null
	storage = null
	settings = null
	terrain = null
	shaders = null
	addons = null
	game = null
	_character = null
	sound = null
	weather = null
	creatures = null
	_host = null


## (1.93) An instance of one of Zenith's native (C++) classes, for an add-on's hot loops: only
## `BiterRagdollNative`, `BiterGoreNative`, `AcidGooNative` and `BiterAnimNative` are given out; null for any other
## name, for a class this Zenith's library lacks, where the library is not there (Linux, macOS, ARM64) or
## `--enemies-native=off`. Main thread only. The add-on keeps its own GDScript for null.
func native_class(cls: String) -> Object:
	if cls not in NATIVE_CLASSES:
		return null
	if "--enemies-native=off" in OS.get_cmdline_user_args():
		return null
	if not NativeLibrary.ensure() or not ClassDB.class_exists(cls):
		return null
	return ClassDB.instantiate(cls)


## A game is on (the world may still be arriving).
func in_game() -> bool:
	return _host != null and _host.in_game()


## A line in Zenith's log (the console it was started from), marked with the add-on's id.
func note(text: String) -> void:
	print("[%s] %s" % [id, text])


## One of the add-on's own scripts, by its path in the add-on's folder ("modes/orbit.gd").
func load_script(relative: String) -> Script:
	return load(dir.path_join(relative)) as Script
