extends AudioStreamPlayer
## The Model packs window's preview's speaker (model_preview.gd set_sounding): the previewed
## entity's working sound looping, as the world plays a working machine's (fx.gd's loops: the
## prototype's working_sound from the player's install, sound_bank.gd, a variation at its volume),
## but not placed in the world: on the Effects bus, so Settings > Sound's effects volume holds.
## Stopped when switched off, when another model is shown and when the preview leaves the tree.

const SoundBank := preload("res://scripts/fx/sound_bank.gd")
const BurnerFx := preload("res://scripts/fx/burner_fx.gd")

## The entity whose sound is wanted ("" none) and whether it should sound now. `crackle`: a burning
## burner inserter's model (burner_fx.gd), whose sound is the world's crackle, not a working sound.
var entity := ""
var wanted := false
var crackle := false
## The file playing ("" none).
var path := ""


func _init() -> void:
	name = "Sound"
	bus = &"Effects" if AudioServer.get_bus_index(&"Effects") >= 0 else &"Master"


## Why `name` can't sound ("" it can): no install, its sounds still being read, none for it.
static func reason(name: String, burner := false) -> String:
	if not SoundBank.available():
		return "No Factorio install found: the sounds are read from it"
	SoundBank.prepare()
	if not SoundBank.ready():
		return "Reading Factorio's sounds..."
	if burner:
		return ""
	if name == "" or SoundBank.working_sound(name) == null:
		return "This has no working sound"
	return ""


## Plays (or stops) `name`'s working sound (`burner`: its crackle); a file still decoding starts once it
## is (update()).
func set_wanted(name: String, on: bool, burner := false) -> void:
	if name != entity or burner != crackle:
		halt()
	entity = name
	crackle = burner
	wanted = on and name != ""
	update()


## Called each frame by the preview: starts the loop once its file is decoded, stops it when unwanted.
func update() -> void:
	if not wanted:
		halt()
		return
	if path != "" or reason(entity, crackle) != "":
		return
	if crackle:
		var fire := SoundBank.stream_soon(BurnerFx.SOUND, true)
		if fire == null:
			return
		path = BurnerFx.SOUND
		stream = fire
		volume_db = linear_to_db(BurnerFx.SOUND_VOLUME)
		pitch_scale = 1.0
		play()
		return
	var loop: SoundBank.Loop = SoundBank.working_sound(entity)
	var i := loop.sound.pick()
	var file := loop.sound.files[i]
	var s := SoundBank.stream_soon(file, true)
	if s == null:
		return
	path = file
	stream = s
	volume_db = linear_to_db(maxf(loop.sound.volume_of(i), 0.001))
	pitch_scale = loop.sound.speed()
	play()


func halt() -> void:
	if playing:
		stop()
	stream = null
	path = ""


func sounding() -> bool:
	return path != "" and playing


func _notification(what: int) -> void:
	if what == NOTIFICATION_EXIT_TREE:
		wanted = false
		halt()
