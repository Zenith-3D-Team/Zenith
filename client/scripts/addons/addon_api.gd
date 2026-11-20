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

## A game started (the world is being received) or ended (back to the menu).
signal game_started
signal game_ended

## The add-on API this Zenith offers.
var version := AddonLoader.API_VERSION
## The add-on API with its additions within the version (1.1: settings, view.keep_drawing; 1.2:
## terrain; 1.3: shaders; 1.6: world.hold_chunks, view.full_detail, view.screenshot; 1.7: character,
## camera.mode, game, addons, sound). Check it before using a 1.1 call to keep working on a Zenith with 1.0:
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
	_host = null


## A game is on (the world may still be arriving).
func in_game() -> bool:
	return _host != null and _host.in_game()


## A line in Zenith's log (the console it was started from), marked with the add-on's id.
func note(text: String) -> void:
	print("[%s] %s" % [id, text])


## One of the add-on's own scripts, by its path in the add-on's folder ("modes/orbit.gd").
func load_script(relative: String) -> Script:
	return load(dir.path_join(relative)) as Script
