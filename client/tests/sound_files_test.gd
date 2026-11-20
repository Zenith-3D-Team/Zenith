extends SceneTree
## Where a sound's file comes from (sound_bank.gd locate()): a stand-in install, a mod's zip in a
## stand-in mods folder, model packs' sounds/ folders (a folder, a zip, below the Factorio pack, off,
## a "sound:" choice, --pack-sounds off) and a file an add-on registered, each winning in its turn;
## the decoded sounds dropped when the packs or the mods found change (an add-on's file only its own
## entries); a mod's
## own mining sound found (it fell back to the default before); --mod-sounds=off; an Opus file in a
## pack giving way to the install's; decoding on a worker. The sounds are the test's own tones
## (sound_fixtures.gd).
##   godot --headless --audio-driver Dummy --path client -s res://tests/sound_files_test.gd
## Prints "SOUND FILES FAILS: 0" when all pass; quits with 1 otherwise.

const SoundBank := preload("res://scripts/fx/sound_bank.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const ModFiles := preload("res://scripts/world/mod_files.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
const Tones := preload("res://tests/sound_fixtures.gd")
const TestEnv := preload("res://tests/test_env.gd")

const TONE := "base/sound/tone.ogg"
const MOD := "zenith-sound-mod"
const MOD_TONE := MOD + "/sound/mine-1.ogg"
const SHORT := 0.05
const LONG := 0.25

var fails := 0


func check(ok: bool, what: String) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _initialize() -> void:
	TestEnv.isolate("sound-files-test")
	var root := ProjectSettings.globalize_path("user://sound-files")
	var install := root.path_join("install")
	var mods := root.path_join("mods")
	var models := root.path_join("models")
	var short := Tones.bytes(Tones.SHORT)
	var long := Tones.bytes(Tones.LONG)
	check(short.size() > 1000 and long.size() > 1000 and SoundBank._is_vorbis(short) and not SoundBank._is_vorbis(Tones.bytes(Tones.OPUS)),
		"the fixtures: two Vorbis tones and an Opus one")

	# The install stands in: base's tone, the short one.
	_write(install.path_join(TONE), short)
	_write(install.path_join("base/info.json"), '{"name": "base", "version": "2.1.0"}'.to_utf8_buffer())
	ItemIcons.data_dir = install
	# The packs here carry the stand-in install's own tones on purpose (which file wins): the copies
	# check (pack_check.gd, model_packs_test.gd's _copies) would refuse them, so it compares with nothing.
	ModelPacks.PackCheck.test_install = ""
	ItemIcons._searched = true
	# A mod's zip in a mods folder: its own mining sound, two variations, under a top folder of another name.
	_zip(mods.path_join(MOD + "_1.0.0.zip"), {"top/info.json": ('{"name": "%s", "version": "1.0.0"}' % MOD).to_utf8_buffer(),
		"top/sound/mine-1.ogg": long, "top/sound/mine-2.ogg": long})
	ModFiles.extra_dirs = [mods]
	_set_mods({MOD: "1.0.0", "base": "2.1.0"})
	ModelPacks.configure("", [], [])  # the built-in packs only: none carries a sound

	# 1. The install's file.
	var at := SoundBank.locate(TONE)
	check(at.get("from") == "install" and str(at.get("file")) == install.path_join(TONE), "the install's own file: %s" % [at])
	check(_length(SoundBank.stream(TONE)) < 0.1, "decoded from the install (the short tone)")
	check(SoundBank.locate("base/sound/nope.ogg").is_empty() and not SoundBank.exists("base/sound/nope.ogg"), "a file nowhere")

	# 2. A mod's file, from its zip (both path forms); a built-in mod's missing file isn't looked for in the mods folders.
	at = SoundBank.locate(MOD_TONE)
	check(at.get("from") == "mod" and SoundBank.locate("__%s__/sound/mine-1.ogg" % MOD).get("from") == "mod", "a mod's file from its zip: %s" % [at])
	check(_length(SoundBank.stream(MOD_TONE)) > 0.2, "decoded from the zip (the long tone)")
	check(SoundBank.variants(MOD + "/sound/mine") == PackedStringArray([MOD + "/sound/mine-1.ogg", MOD + "/sound/mine-2.ogg"]),
		"the mod's variations: %s" % [SoundBank.variants(MOD + "/sound/mine")])
	# fx.gd sound_for() and repair_sound_for() take an entity's own sound when variants() finds it (fx.gd
	# needs the Bridge autoload, so the UI test's _fx_movers checks them): it was empty before, the default played.

	# --mod-sounds=off: the mod's file isn't read, its default plays.
	SoundBank.mod_sounds = false
	SoundBank.clear_cache()
	check(SoundBank.locate(MOD_TONE).is_empty() and SoundBank.variants(MOD + "/sound/mine").is_empty(), "--mod-sounds=off: not found, the default as before")
	SoundBank.mod_sounds = true
	SoundBank.clear_cache()

	# 3. A folder pack's sounds/ (one folder down), on top: it wins over the install and over the mod.
	_write(models.path_join("Sound folder/inner/sounds/" + TONE), long)
	_write(models.path_join("Sound folder/inner/sounds/" + MOD_TONE), short)
	_write(models.path_join("Sound folder/inner/sounds/base/sound/pack-only.ogg"), short)
	var before := SoundBank.stream(TONE)
	var version := ModelPacks.sounds_version
	ModelPacks.configure(models, [], [])
	check(ModelPacks.sounds_version != version, "the packs changed: sounds_version moved")
	at = SoundBank.locate(TONE)
	check(at.get("from") == "pack" and str(at.get("file")).ends_with("inner/sounds/" + TONE), "the pack's file over the install's: %s" % [at])
	var after := SoundBank.stream(TONE)
	check(after != before and _length(after) > 0.2, "the decoded sound dropped and read again from the pack")
	check(SoundBank.locate(MOD_TONE).get("from") == "pack" and _length(SoundBank.stream(MOD_TONE)) < 0.1, "a pack's file over a mod's")

	# A sounds-only zip, above the folder: it wins; the order turned, the folder does.
	_zip(models.path_join("sound-zip.zip"), {"pack/pack.json": '{"name": "Zipped sounds"}'.to_utf8_buffer(),
		"pack/sounds/" + TONE: short})
	ModelPacks.configure(models, ["zip:sound-zip.zip", "dir:Sound folder"], [])
	ModelPacks.wait()
	var zp := _pack(ModelPacks.packs, "zip:sound-zip.zip")
	check(zp.get("problem", "?") == "" and int(zp.get("sound_count", 0)) == 1, "a zip of sounds alone is a pack: %s" % [zp])
	at = SoundBank.locate(TONE)
	check(at.get("from") == "pack" and ModelPacks.sound_pack(TONE).get("id") == "zip:sound-zip.zip" and _length(SoundBank.stream(TONE)) < 0.1,
		"the higher pack's (the zip's): %s" % [at])
	ModelPacks.configure(models, ["dir:Sound folder", "zip:sound-zip.zip"], [])
	ModelPacks.wait()
	check(ModelPacks.sound_pack(TONE).get("id") == "dir:Sound folder" and _length(SoundBank.stream(TONE)) > 0.2, "the order turned: the folder's")
	# A "sound:" choice takes the chosen pack's whatever the order.
	ModelPacks.set_choices({"sound:" + TONE: "zip:sound-zip.zip"})
	check(ModelPacks.sound_pack(TONE).get("id") == "zip:sound-zip.zip" and _length(SoundBank.stream(TONE)) < 0.1, "a sound: choice")
	ModelPacks.set_choices({})
	check(_length(SoundBank.stream(TONE)) > 0.2, "the choice undone: the order's again")

	# --pack-sounds off (or Settings' tick box): the install's.
	ModelPacks.set_sounds_on(false)
	check(SoundBank.locate(TONE).get("from") == "install" and _length(SoundBank.stream(TONE)) < 0.1, "packs' sounds off: the install's")
	ModelPacks.set_sounds_on(true)

	# A pack below the Factorio pack loses to the install; both packs off, the install's.
	ModelPacks.configure(models, [ModelPacks.FACTORIO_ID, "dir:Sound folder", "zip:sound-zip.zip"], [])
	ModelPacks.wait()
	check(SoundBank.locate(TONE).get("from") == "install", "packs below the Factorio pack: the install's")
	check(SoundBank.locate(MOD_TONE).get("from") == "mod", "and a mod's own file (Factorio's too) over theirs")
	check(SoundBank.locate("base/sound/pack-only.ogg").get("from") == "pack" and _length(SoundBank.stream("base/sound/pack-only.ogg")) > 0.0,
		"but a file Factorio hasn't: still the pack's")
	ModelPacks.configure(models, ["dir:Sound folder", "zip:sound-zip.zip"], ["dir:Sound folder", "zip:sound-zip.zip"])
	ModelPacks.wait()
	check(SoundBank.locate(TONE).get("from") == "install" and SoundBank.locate(MOD_TONE).get("from") == "mod", "the packs off: the install's and the mod's")

	# An Opus file in a pack gives way to the install's when decoded.
	_write(models.path_join("Opus pack/sounds/" + TONE), Tones.bytes(Tones.OPUS))
	ModelPacks.configure(models, ["dir:Opus pack"], ["dir:Sound folder", "zip:sound-zip.zip"])
	ModelPacks.wait()
	check(SoundBank.locate(TONE).get("from") == "pack", "the Opus pack's file found")
	var opus_fallback := SoundBank.stream(TONE)
	check(opus_fallback != null and _length(opus_fallback) < 0.1, "decoded: Opus isn't played, the install's instead")

	# 4. An add-on's registered file comes before everything.
	var addon_file := root.path_join("addon/boing.ogg")
	_write(addon_file, long)
	SoundBank.register_file(TONE, addon_file)
	SoundBank.register_file("addon:test/sounds/boing.ogg", addon_file)
	at = SoundBank.locate(TONE)
	check(at.get("from") == "addon" and _length(SoundBank.stream(TONE)) > 0.2, "an add-on's file first: %s" % [at])
	check(SoundBank.locate("addon:test/sounds/boing.ogg").get("from") == "addon", "an add-on's own file by its key")
	SoundBank.forget_files("addon:test/")
	check(SoundBank.locate("addon:test/sounds/boing.ogg").is_empty() and SoundBank.locate(TONE).get("from") == "addon", "forgotten by prefix, others kept")
	SoundBank.register_file(TONE, "")
	check(SoundBank.locate(TONE).get("from") == "pack" and _length(SoundBank.stream(TONE)) < 0.1, "unregistered: the pack's place again")
	# An add-on's file coming and going drops only that file's entries: Zenith's other decoded sounds stay.
	var kept := SoundBank.stream(MOD_TONE)
	var kept_at := SoundBank.locate(MOD_TONE)
	SoundBank.register_file("addon:test/sounds/other.ogg", addon_file)
	check(SoundBank.locate("addon:test/sounds/other.ogg").get("from") == "addon" and kept != null and SoundBank.stream(MOD_TONE) == kept
		and SoundBank._where.get(MOD_TONE) == kept_at, "an add-on's file registered: the other decoded sounds kept, not decoded again")
	SoundBank.forget_files("addon:test/")
	check(SoundBank.locate("addon:test/sounds/other.ogg").is_empty() and SoundBank.stream(MOD_TONE) == kept,
		"and forgotten: the add-on's gone, the others kept")

	# The mods found again (ModFiles.generation): caches dropped.
	ModelPacks.configure("", [], [])
	var cached := SoundBank.stream(MOD_TONE)
	check(cached == SoundBank.stream(MOD_TONE), "cached while nothing changes")
	_set_mods({MOD: "1.0.0"})
	check(SoundBank.stream(MOD_TONE) != cached and _length(SoundBank.stream(MOD_TONE)) > 0.2, "the mods found again: decoded anew")

	# Decoding on a worker (the world's sounds): from the mod's zip.
	SoundBank.clear_cache()
	var soon := SoundBank.stream_soon(MOD + "/sound/mine-2.ogg")
	var until := Time.get_ticks_msec() + 5000
	while soon == null and Time.get_ticks_msec() < until:
		OS.delay_msec(5)
		soon = SoundBank.stream_soon(MOD + "/sound/mine-2.ogg")
	check(soon != null and _length(soon) > 0.2, "decoded on a worker from the zip")

	SoundBank.clear_cache()
	ModFiles.close_all()
	ModFiles.extra_dirs = []
	ModelPacks.configure("", [], [])
	print("SOUND FILES FAILS: %d" % fails)
	TestEnv.clean()
	quit(1 if fails > 0 else 0)


static func _length(s: AudioStream) -> float:
	return s.get_length() if s != null else -1.0


static func _pack(list: Array, id: String) -> Dictionary:
	for p: Dictionary in list:
		if p["id"] == id:
			return p
	return {}


func _set_mods(mods: Dictionary) -> void:
	ModFiles.set_mods(mods)
	var until := Time.get_ticks_msec() + 5000
	while not ModFiles.is_ready() and Time.get_ticks_msec() < until:
		OS.delay_msec(2)


static func _write(path: String, bytes: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


static func _zip(path: String, files: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var zip := ZIPPacker.new()
	zip.open(path)
	for name: String in files:
		zip.start_file(name)
		zip.write_file(files[name])
		zip.close_file()
	zip.close()
