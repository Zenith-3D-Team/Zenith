extends RefCounted
## Model packs: every model Zenith draws comes from one, found by file name (<prototype-name>.glb
## or .gltf). Zenith's own are three built-in packs in res://assets/models/packs/, by default in
## this order (FUE5: FUE5's textured models; Wube3DP: Wube's printable models converted;
## Placeholders: Zenith's own, built from Factorio's sprites), then Factorio (FACTORIO_ID: the
## player's install itself, nothing of it in this repo: each entity's own picture on a card facing
## Factorio's camera, sprite_standins.gd; each item its icon card; the install's icons). The models
## folder beside Zenith
## (model_library.gd custom_models_dir) holds the rest:
##
## - the .glb and .gltf files at its top, one pack ("Loose models");
## - each folder in it, a pack, its models anywhere inside, in any layout;
## - each .zip in it, a pack the same way, read without the player unpacking it: Zenith unpacks it
##   once into user://model-packs/<zip name>-<size>-<modified>/ (so a .gltf's own files, the levels
##   of detail and everything else that wants a file path work as from a folder), again only when
##   the zip changes, and removes the copies of zips changed or gone. That runs on a worker thread
##   from start-up; model_library.gd's ready() says no until it is done, so nothing waits on it.
##   A download's Zenith.zip is one: Vasillo's models (tools/release/package.py --models). It was
##   Default.zip before: an old Default.zip is read as Zenith (BUNDLED_ID), and left out when a
##   Zenith.zip is beside it; saved ids naming it are read as Zenith's (canonical_id).
##
## A pack may hold a pack.json ({"name", "version", "author", "licence", "description"}; "short_name",
## the name in "<pack>'s" lines, "FUE5" for "FUE5 (Adapted)": `short`, else the name) at its top
## or one folder down, shown in the Model packs window (model_packs_window.gd), which orders the
## packs and turns them off (settings.cfg [model_packs] `order` and `off`, by id: "builtin:<folder>",
## "loose", "dir:<folder>", "zip:<file>"; a new pack of the folder's goes on top, on; a built-in one
## not saved yet in its place under them, BUILTIN's order). The higher pack wins when two have a
## model of one name. Every pack moves and switches off, Placeholders and Factorio too: an entity no
## pack in use has a model for is drawn as Factorio's picture (the Factorio pack on, the install
## found), else as Zenith's box in its map colour, so nothing goes invisible. A saved order without
## Factorio (from before it was a pack) puts it last, under Placeholders, where its pictures stood in
## before (the sprite stand-ins for entities no pack had); Placeholders keeps its saved place. In one
## pack the model nearest its top wins, then .glb over .gltf. A model's family (family(): a
## prototype's model with its direction, curve, piece and pose variants) can be taken from a pack
## of the player's choice whatever the order (settings.cfg [model_packs] `choices`, family ->
## pack id; choice()). --models=<dir> is one more pack, on top for that run, which only fills in
## entities no other pack has a model for unless --models-first; --no-custom-models leaves the
## folder's packs out, the built-in ones stay (model_library.gd configure_from_command_line).
##
## pack.json's "shading" says how the pack's textured materials are drawn (shading()): "pbr" as their
## files say (glTF's PBR, as Godot's own material draws it, with the look's fill and metal share on top:
## factorio_material.gdshaderinc modeller_tex), "factorio" (or no key) with Zenith's Factorio-style
## balance as before. FUE5, Wube3DP and Placeholders use "pbr" (--fue5-pbr=off / --wube3dp-pbr=off /
## --placeholder-pbr=off keep them on "factorio"); Factorio stays "factorio". --pack-shading=factorio, or Settings >
## Graphics > Advanced > Packs' own shading, Factorio's everywhere, draws every pack the old way (looks.gd).
##
## A pack may also carry icons that replace Factorio's in Zenith's UI (item_icons.gd asks icon_file()
## first): an `icons/` folder at its top or one folder down, `icons/<name>.png` for the prototype of
## that name whatever its kind, `icons/<kind>/<name>.png` for one kind only ("item", "entity",
## "fluid", "recipe", "technology", "virtual-signal" or "signal", "space-location", "item-group"),
## square, any size. They go by the same order and switches as the models; a choice for one icon is
## kept in `choices` as "icon:<name>" -> pack id; below every pack, the install's own icon. The
## models folder's own top `icons/` is the loose pack's. A pack of icons alone is a pack too.
##
## A pack may carry sounds too, file for file in place of Factorio's (sound_bank.gd locate() asks
## sound_file() before the install): a `sounds/` folder at its top or one folder down, under it the
## file's Factorio path ("sounds/core/sound/gui-click.ogg", "sounds/base/sound/walking/grass-3.ogg",
## "sounds/<mod>/..." for a mod's), Ogg Vorbis only. The sound's rules (volume, variations, pitch)
## stay Factorio's. Same order and switches as the icons, a choice kept as "sound:<path>"; a pack
## below the Factorio pack loses to the install. Packs carry their authors' own sounds, never
## Factorio's. A pack of sounds alone is a pack too. --pack-sounds=off, or Settings > Sound's
## "Sounds from model packs" off, leaves every pack's sounds out (sounds_on).
##
## A pack may carry ground textures too, in place of Factorio's (terrain_textures.gd asks
## tile_source() first): a `tiles/` folder at its top or one folder down (the models folder's own
## top `tiles/` is the loose pack's), `<tile-name>.png` (or .webp, .jpg, .jpeg), in subfolders
## (`tiles/nauvis/grass-1.png`), or numbered variants in a folder named for the tile
## (`tiles/grass-1/1.png`, `2.png`). Companion `-normal`, `-height`/`-bump`, and `-roughness` maps
## (e.g. `dirt-1-normal.png`, `dirt-1-height.png`) layer onto Factorio's or the pack's own albedo.
## Same order and switches as the icons, a choice kept as "tile:<name>"; a pack below the Factorio
## pack gives only what Factorio and mods lack. Packs carry their authors' own pictures, never
## Factorio's. A pack of tiles alone is a pack too. --pack-tiles=off, or Settings > Graphics' "Ground
## textures from model packs" off, leaves them out (tiles_on); --pack-tile-pbr=off disables only the
## companion PBR maps.
##
## A pack may carry decoratives and grass too, in a `decoratives/` folder at its top or one folder
## down (loose packs use top `decoratives/`): flat ground clutter, upright plants, and 3D raised
## grass tufts/bushes/carpets (`decoratives.gd`), with variants (`<name>-1.png` or `<name>/1.png`)
## and optional `pack.json` `"decoratives"` overrides (`scale`, `size`, `shift`, `layer`, `grass`,
## `grass_height`, `grass_style`, `hide`). Same order and switches as tiles, a choice kept as
## "decor:<name>". --pack-decoratives=off, or Settings > Graphics' "Decoratives from model packs" off,
## leaves them out (decor_on).
##
## A pack that holds a copy of any of the install's own files is refused whole, its card red saying
## why (pack_check.gd; the owner's rule). A new or changed pack is checked on the worker first and is
## not in use until it is clean, the way a zip being unpacked isn't (`checking`); an unchanged one
## takes its kept answer at once. Without an install nothing can be compared: packs load, `unchecked`.
##
## Item models (items on belts, on the ground, in inserter hands: item_models.gd) come from the
## packs too: a folder called `items` anywhere in a pack (the models folder's own `items/` for its
## loose models) holds <item-name>.glb or .gltf, apart from the pack's entity models, so an item
## and a building of one name don't clash. They follow the same order and switches; a choice for
## one item is kept in `choices` as "item:<name>" (ITEM_PREFIX). Placeholders has an item model for
## every item Zenith made one for (tools/models/items.py), so every such item keeps one. A pack of
## item models alone is a pack too.

const ModFiles := preload("res://scripts/world/mod_files.gd")
const ModGraphics := preload("res://scripts/world/mod_graphics.gd")
const PackCheck := preload("res://scripts/world/pack_check.gd")
const SafeDelete := preload("res://scripts/safe_delete.gd")  # never through a link
const Switches := preload("res://scripts/switches.gd")

const MODEL_EXTS := ["glb", "gltf"]
const INFO_FILE := "pack.json"
const LOOSE_ID := "loose"
## A pack's folder of item models, and the key of an item's choice in `choices`.
const ITEMS_DIR := "items"
const ITEM_PREFIX := "item:"
const ARG_ID := "arg"
## The built-in packs (res://assets/models/packs/<folder>/), in their default order from the top
## (the owner's: FUE5, Wube3DP, Placeholders, Factorio), under the models folder's packs. "factorio"
## has no folder: it is the player's install (FACTORIO_ID).
const BUILTIN_DIR := "res://assets/models/packs/"
const BUILTIN := ["fue5", "wube3dp", "placeholders", "factorio"]
const BUILTIN_PREFIX := "builtin:"
## FUE5's adapted models (built-in top pack in default order).
const FUE5_ID := "builtin:fue5"
## Wube's adapted 3D-printable models.
const WUBE3DP_ID := "builtin:wube3dp"
## Zenith's own models from the sprites (once pinned last; it moves and switches like the rest now).
const LAST_ID := "builtin:placeholders"
## The Factorio pack: virtual, its content read from the player's install at run time (nothing of
## Wube's committed or shipped). Models: every entity with a resting picture (the bridge's graphics
## list, mod_graphics.gd, in a game; else res://data/sprite_projection.json's frames, read from the
## install), drawn as sprite_standins.gd's card; items: their icon cards; icons: the install's own.
## Without an install it is listed with the reason and gives nothing.
const FACTORIO_FOLDER := "factorio"
const FACTORIO_ID := "builtin:factorio"
const FACTORIO_LOGO := "factorio:data/core/graphics/factorio-icon.png"
const PROJECTION_DATA := "res://data/sprite_projection.json"
## The downloads' bundled pack (Vasillo's models, tools/release/package.py): models/Zenith.zip,
## called "Zenith". Its old names, from before it was renamed, are read as it: a models folder
## still holding Default.zip, and settings.cfg's `order`, `off`, `choices` and
## building_models.cfg's choices saved with "zip:Default.zip".
const BUNDLED_FILE := "Zenith.zip"
const BUNDLED_ID := "zip:Zenith.zip"
const BUNDLED_TITLE := "Zenith"
const OLD_BUNDLED_FILES := ["default.zip"]
## A family's variants (model_library.gd model_name's suffixes): taken off a name to find its
## family, longest first, when what is left is a model of some pack too (pipe and wall shapes,
## end pieces, poses). ALWAYS_SUFFIXES are taken off whatever is left: an underground's ends and
## a cliff's pieces have no model of the bare name.
const SUFFIXES := ["-straight-vertical-single", "-straight-horizontal", "-corner-down-right", "-straight-vertical",
	"-corner-down-left", "-corner-up-right", "-corner-up-left", "-gate-single-n", "-gate-single-e", "-gate-single-s", "-gate-single-w", "-ending-right", "-ending-down", "-ending-left",
	"-curve-right", "-curve-left", "-ending-up", "-t-right", "-t-down", "-t-left", "-gate-ns", "-gate-ew", "-gate-n", "-gate-e", "-gate-s", "-gate-w", "-sparse", "-attack", "-corpse",
	"-window", "-cross", "-pylon", "-start", "-south", "-t-up", "-east", "-west", "-rich", "-fill", "-wet", "-nesw", "-nes", "-nsw",
	"-esw", "-new", "-old", "-end", "-ne", "-nw", "-ns", "-es", "-ew", "-sw", "-n", "-e", "-s", "-w", "-1", "-2", "-3"]
const ALWAYS_SUFFIXES := ["-entrance", "-output", "-input", "-sides", "-outer", "-inner", "-exit"]
## Parts with names of their own that belong to a building's family (the Model packs window lists
## them under it, a choice for it takes them too): name prefix -> family. A cargo bay's edge pieces;
## an inserter arm's parts under the inserter its set is named for (inserter_arms.gd ARM_FAMILIES:
## the basic set is the burner and fast inserters' arm too, one model shared, so it follows the
## inserter's choice); the character's armour looks, gun and corpse; a demolisher's head, segments
## and tail (one family for the three sizes, which scale the same models).
const PREFIX_FAMILIES := {"cargo-bay-": "cargo-bay", "inserter-arm-basic-": "inserter", "inserter-arm-long-": "long-handed-inserter",
	"inserter-arm-bulk-": "bulk-inserter", "inserter-arm-stack-": "stack-inserter", "character-": "character",
	"demolisher-": "demolisher"}
## Whole models of a building's part, pose or remains: name -> family. The silo's rocket, the landed
## cargo pod, the stompers' shells (their corpses).
const PART_FAMILIES := {"rocket-silo-rocket": "rocket-silo", "cargo-pod-container": "cargo-pod",
	"small-stomper-shell": "small-stomper-pentapod", "medium-stomper-shell": "medium-stomper-pentapod",
	"big-stomper-shell": "big-stomper-pentapod"}
## Variants, the one rule for every model, item model (`items/`) and icon: `<name>-<n>` (n = 1, 2, 3...)
## and `<name>` itself are the variants of `<name>` (variant_base, variants_in), whatever the number and
## whether or not a pack has the plain one; the Model packs window shows them as one entry. A numbered
## name that is a prototype of its own in Factorio (`assembling-machine-2`, `speed-module-3`, `tree-04`,
## `uranium-235`: NUMBERED_PROTOS, from data/icons.json) is never a variant. Each placed entity or
## ground item draws one of them at random but the same every time (variant_seed: from its position);
## an ore's numbered models are its scattered rocks (model_library.gd ore_rocks), its tiles keep their
## stages' models. A pack.json's "aliases" names its files for Factorio's names (alias_name).
const VARIANT_MAX := 99
## Ores, whose stage models count as theirs too (provides(): ORE_SUFFIXES).
const NUMBERED_FAMILIES := ["iron-ore", "copper-ore", "coal", "stone", "uranium-ore"]
## The models besides its own that an ore is drawn by (provides()): its stages, its first rock.
const ORE_SUFFIXES := ["-rich", "-sparse", "-1"]
## The prototype index read for NUMBERED_PROTOS.
const PROTO_INDEX := "res://data/icons.json"
const COUNT_KEYS := {"models": "count", "items": "item_count", "icons": "icon_count", "tiles": "tile_count", "decoratives": "decor_count"}
## How deep a pack's folders are searched for models.
const MAX_DEPTH := 12
## A half-unpacked copy (".part-<process>") older than this, in seconds, was left by a Zenith that
## stopped; a newer one may be another Zenith's at work.
const PART_AGE := 3600
## --pack-cache-keep=<days>: an unpacked copy of a zip this folder doesn't have (another launcher's, a
## pack removed) is kept until unused this many days (its USED_SUFFIX stamp, touched whenever a client
## finds its zip), so switching between launchers doesn't unpack 2 GB again each time; 0 removes it at
## once, as before. A copy of a zip of the same name in this folder, changed since, goes at once.
const PACK_CACHE_KEEP_DAYS := 7
const USED_SUFFIX := ".used"
static var pack_cache_keep := _keep_days()
## How long a worker thread waits for the main thread to take the unpacked packs in (ms).
const WORKER_WAIT := 60000
## A pack's icons: the folder's name, the files read, the choices' key prefix, and kind folders
## named otherwise than Zenith asks for them.
const ICONS_DIR := "icons"
const ICON_EXTS := ["png"]
const ICON_PREFIX := "icon:"
const ICON_KIND_ALIASES := {"signal": "virtual-signal"}
## A pack's sounds: the folder's name, the files read, the choices' key prefix.
const SOUNDS_DIR := "sounds"
const SOUND_EXTS := ["ogg"]
const SOUND_PREFIX := "sound:"
## A pack's ground tiles: the folder's name, the picture formats read, the choices' key prefix, and
## how deep under tiles/ folders are walked.
const TILES_DIR := "tiles"
const TILE_EXTS := ["png", "webp", "jpg", "jpeg"]
const TILE_PREFIX := "tile:"
const TILE_DEPTH := 4
## A pack's decoratives and grass: the folder's name, formats, choices' key prefix, and walk depth.
const DECOR_DIR := "decoratives"
const DECOR_IMAGE_EXTS := ["png", "webp", "jpg", "jpeg"]
const DECOR_MODEL_EXTS := ["glb", "gltf"]
const DECOR_EXTS := ["glb", "gltf", "png", "webp", "jpg", "jpeg"]
const DECOR_PREFIX := "decor:"
const DECOR_DEPTH := 4
const NOTHING_IN_IT := "it has no models, icons, sounds, tiles or decoratives in it"
## How deep under sounds/ a file may be (<mod>/sound/<folders>/<name>.ogg).
const SOUND_DEPTH := 8

## Where zips are unpacked (follows user://; tests move user:// itself).
static var cache_root := "user://model-packs"
## The models folder (Settings lists its packs), and the one the packs in use were found in: the
## same, or "" with --no-custom-models.
static var folder := ""
static var models_dir := ""
## Every pack found at start-up, in the order they are used (the --models one first). A pack is
## {id, kind ("builtin", "loose", "folder", "zip", "arg"), title, info (pack.json's fields), source
## (its folder or zip), root (where its models are: a zip's unpacked copy), models (name -> file),
## count, on, replaces (its models go by the order, else only fill in what no pack has), problem
## ("" or why it is left out), unpacking, cache (a zip's copy), checking (being checked for copies of
## the install's files, not in use yet), copies (those files' paths in the pack: refused, `problem`
## REFUSED), unchecked (no install to compare with), check_stamp}.
static var packs: Array = []
## Goes up whenever the packs in use change (model_library.gd's generation follows it).
static var version := 0
## Goes up whenever the icons in use may have changed (the order, a switch, an "icon:" choice):
## item_icons.gd drops its cache on it.
static var icons_version := 0
## The same for the sounds in use (the order, a switch, a "sound:" choice, sounds_on): sound_bank.gd
## drops its decoded sounds on it.
static var sounds_version := 0
## Whether packs' sounds are used at all (--pack-sounds=off; Settings > Sound, fx_settings.gd sets it).
static var sounds_on := arg_on("--pack-sounds")
## Goes up whenever the ground tiles in use may have changed (the order, a switch, a "tile:" choice,
## tiles_on, tile_pbr_on): terrain_textures.gd drops and reloads its layers on it.
static var tiles_version := 0
## Whether packs' ground textures are used at all (--pack-tiles=off; Settings > Graphics sets it).
static var tiles_on := arg_on("--pack-tiles")
## Whether companion -normal / -height / -roughness maps in tiles/ are used (--pack-tile-pbr=off).
static var tile_pbr_on := arg_on("--pack-tile-pbr")
## Goes up whenever the decoratives in use may have changed (the order, a switch, a "decor:" choice,
## decor_on): decoratives.gd drops and reloads its pictures and 3D grass on it.
static var decor_version := 0
## Whether packs' decoratives and grass are used at all (--pack-decoratives=off; Settings > Graphics sets it).
static var decor_on := arg_on("--pack-decoratives")
## Whether 3D decorative models (.glb/.gltf in decoratives/) are used (--decor-models=off; Settings > Graphics sets it).
static var decor_models_on := arg_on("--decor-models")
## --fue5-pbr=off: draw FUE5 with Factorio shading instead of its pack.json PBR shading.
static var fue5_pbr := Switches.on("--fue5-pbr")
## --wube3dp-pbr=off: draw Wube3DP with Factorio shading instead of its pack.json PBR shading.
static var wube3dp_pbr := Switches.on("--wube3dp-pbr")
## --placeholder-pbr=off: draw Placeholders with Factorio shading instead of its pack.json PBR shading.
static var placeholder_pbr := Switches.on("--placeholder-pbr")
## Built-in assembling machines 1-3 prefer rebuilt Placeholders over Wube3DP/FUE5 unless --assembler-models=old.
const PREFERRED_PLACEHOLDERS := {
	"assembling-machine-1": true,
	"assembling-machine-2": true,
	"assembling-machine-3": true,
}
static var prefer_builtin_assemblers := not Switches.has("--assembler-models=old")
## The packs chosen for model families whatever the order (the Model packs window): family -> pack
## id. Replaced, never changed in place (read on workers); set_choices().
static var choices := {}
## Per-pack and per-model PBR shading overrides set in the Model packs window
## (settings.cfg [model_packs] pbr_packs / pbr_models). Replaced wholesale, never changed in place.
static var pbr_packs := {}  # canonical pack id -> bool (true: "pbr", false: "factorio")
static var pbr_models := {}  # "<canonical pack id>|<family or item:<name>>" -> bool
static var _active: Array = []  # the packs models are taken from, in order: on, read, unpacked
static var _names := {}  # every model name any pack has (family() reads it on workers): replaced, not changed
## Factorio's prototypes whose names end in a number (variant_base leaves them alone): name -> true.
## Read once when the script loads, never changed (read on workers).
static var NUMBERED_PROTOS := _read_numbered_protos()
static var _builtin: Array = []  # the built-in packs as found once (they don't change while Zenith runs)
static var _configured := false  # configure() or use() ran (active() starts with the built-in packs otherwise)
static var _mutex := Mutex.new()
static var _task := -1
static var _busy := false  # zips being unpacked, or unpacked and not yet taken in
static var _finished := true  # the worker has put its results in _results
static var _results: Array = []
static var _progress := {}  # a zip's id -> [files unpacked, files in it], while the worker unpacks it
## The Factorio pack's pictures: entity name -> true (replaced, never changed in place: read on
## workers). From sprite_projection.json (with an install) and the bridge's graphics list.
static var _sprites := {}
static var _sprites_generation := -2  # ModGraphics.generation the set was made from
static var _projection_names: Array = []  # sprite_projection.json's entities a card can show
static var _projection_skip := {}  # and those drawn round the turn, which keep their models
static var _projection_read := false
static var _install_found := false  # a Factorio install was found (when the pictures were last listed)


## Finds the packs in `dir` (the models folder; with `use_folder` false none of them), the built-in
## ones and `extra` (--models=), puts them in the saved `order` (ids, top first) with those in `off`
## off, and starts unpacking the zips that need it and checking the packs new or changed since their
## last check for copies of Factorio's files (_check_job) on a worker.
static func configure(dir: String, order: Array, off: Array, extra := "", extra_first := false, use_folder := true) -> void:
	wait()
	_configured = true
	folder = _norm(dir)
	models_dir = folder if use_folder else ""
	packs = []
	if extra != "":
		packs.append(folder_pack(_norm(extra), extra_first))
	packs.append_array(ordered(scan(models_dir) + builtin_packs(), order, off))
	var install := PackCheck.install_dir()
	var install_stamp := PackCheck.install_stamp(install)
	var jobs: Array = []
	for p: Dictionary in packs:
		var job := _check_job(p, install, install_stamp)
		if not job.is_empty():
			jobs.append(job)
	var keep := {}
	var here := {}  # the zip names of every zip in the folder, refused or not (_stale_copies)
	for p: Dictionary in packs:
		if p["kind"] == "zip" and p.has("cache"):
			here[_copy_zip_name(str(p["cache"]).get_file())] = true
		if p["kind"] != "zip" or p["problem"] != "":
			continue
		var cache := str(p["cache"])
		keep[cache.get_file()] = true
		if not bool(p["on"]):
			continue
		var items := {}
		var models: Dictionary = _index(cache, MAX_DEPTH, items) if DirAccess.dir_exists_absolute(cache) else {}
		var icons: Dictionary = _index_icons(cache, 1) if DirAccess.dir_exists_absolute(cache) else {}
		var sounds: Dictionary = _index_sounds(cache, 1) if DirAccess.dir_exists_absolute(cache) else {}
		var tile_maps := {}
		var tiles: Dictionary = _index_tiles(cache, 1, tile_maps) if DirAccess.dir_exists_absolute(cache) else {}
		var decor: Dictionary = _index_decoratives(cache, 1) if DirAccess.dir_exists_absolute(cache) else {}
		if not models.is_empty() or not items.is_empty() or not icons.is_empty() or not sounds.is_empty() \
				or not tiles.is_empty() or not tile_maps.is_empty() or not decor.is_empty() \
				or (DirAccess.dir_exists_absolute(cache) and _has_decor_hide(p.get("info", {}))):
			_take_models(p, models, items)
			_take_icons(p, icons)
			_take_sounds(p, sounds)
			_take_tiles(p, tiles, tile_maps)
			_take_decoratives(p, decor)
			if bool(p["checking"]):
				jobs.append({"id": p["id"], "files": PackCheck.pack_files(cache), "check": p["check_stamp"], "install": install,
					"install_stamp": install_stamp})
		else:
			p["unpacking"] = true
			jobs.append({"id": p["id"], "zip": p["source"], "cache": cache, "check": p["check_stamp"] if bool(p["checking"]) else "",
				"install": install, "install_stamp": install_stamp})
	for p: Dictionary in packs:
		if refused(p):
			push_warning(refusal_line(p))
		elif p["problem"] != "":
			push_warning("[models] %s (%s) left out: %s" % [p["title"], where(p), p["problem"]])
	var stale: Array = _stale_copies(keep, here) if models_dir != "" else []
	for name: String in keep:
		_touch_used(name)
	for job: Dictionary in jobs:
		if job.has("zip") and DirAccess.dir_exists_absolute(str(job["cache"])):
			stale.append(job["cache"])  # a copy emptied since: unpacked again
	_activate()
	if jobs.is_empty() and stale.is_empty():
		return
	_busy = true
	_finished = false
	_results = []
	_task = WorkerThreadPool.add_task(_unpack_all.bind(jobs, stale), false, "model packs")


## Whether a pack can be used as far as the copies check goes, its kept answer taken (refused: its
## `problem` set) or, new or changed and on, marked `checking` (a folder's job for the worker back;
## a zip's check goes with its unpacking in configure()). Without an install: `unchecked`.
static func _check_job(p: Dictionary, install: String, install_stamp: String) -> Dictionary:
	if p["problem"] != "" or not PackCheck.checks(str(p["id"])):
		return {}
	if install_stamp == "":
		p["unchecked"] = true
		return {}
	var files := {}
	var stamp := ""
	if p["kind"] == "zip":
		stamp = str(p["cache"]).get_file()
	else:
		files = PackCheck.pack_files(str(p["root"]), p["kind"] == "loose")
		stamp = PackCheck.folder_stamp(files, str(ProjectSettings.get_setting("application/config/version", "")) if is_builtin(p) else "")
	p["check_stamp"] = stamp
	var copies: Variant = PackCheck.known(str(p["id"]), stamp, install_stamp)
	if copies is Array:
		_take_copies(p, copies)
		return {}
	if not bool(p["on"]):
		return {}  # checked when it is turned on
	p["checking"] = true
	if p["kind"] == "zip":
		return {}
	return {"id": p["id"], "files": files, "check": stamp, "install": install, "install_stamp": install_stamp}


## A pack refused for holding copies of the install's files: the paths of those in it.
static func _take_copies(p: Dictionary, copies: Array) -> void:
	p["copies"] = copies
	if not copies.is_empty():
		p["problem"] = PackCheck.REFUSED


## Whether a pack is refused for holding copies of Factorio's files (pack_check.gd).
static func refused(p: Dictionary) -> bool:
	return not (p.get("copies", []) as Array).is_empty()


## The log's line for a refused pack.
static func refusal_line(p: Dictionary) -> String:
	return "[models] %s (%s) not loaded, it contains Factorio's own files: %s" % [p["title"], where(p), PackCheck.detail(p["copies"])]


## The packs in a models folder, unordered: its loose models, its folders with models in them and
## its zips (also those that can't be read, which say why).
static func scan(dir: String) -> Array:
	var out: Array = []
	if dir == "" or not DirAccess.dir_exists_absolute(dir):
		return out
	var loose := _index(dir, 0)
	var loose_items := {}
	for sub: String in DirAccess.get_directories_at(dir):
		if sub.to_lower() == ITEMS_DIR:
			_walk(dir.path_join(sub), 1, MAX_DEPTH, loose_items, null)
	var loose_icons := _index_icons(dir, 0)
	var loose_sounds := _index_sounds(dir, 0)
	var loose_tile_maps := {}
	var loose_tiles := _index_tiles(dir, 0, loose_tile_maps)
	var loose_decor := _index_decoratives(dir, 0)
	var loose_info := _read_info(dir, 0)
	if not loose.is_empty() or not loose_items.is_empty() or not loose_icons.is_empty() or not loose_sounds.is_empty() \
			or not loose_tiles.is_empty() or not loose_tile_maps.is_empty() or not loose_decor.is_empty() or _has_decor_hide(loose_info):
		var p := _pack(LOOSE_ID, "loose", "Loose models", dir, dir, loose)
		_take_models(p, loose, _ranked(loose_items))
		_take_icons(p, loose_icons)
		_take_sounds(p, loose_sounds)
		_take_tiles(p, loose_tiles, loose_tile_maps)
		_take_decoratives(p, loose_decor)
		_take_info(p, loose_info)
		out.append(p)
	var subs := Array(DirAccess.get_directories_at(dir))
	subs.sort_custom(func(a: String, b: String) -> bool: return a.naturalnocasecmp_to(b) < 0)
	for sub: String in subs:
		if sub.begins_with(".") or sub == "__MACOSX" or sub.to_lower() in [ICONS_DIR, ITEMS_DIR, SOUNDS_DIR, TILES_DIR, DECOR_DIR]:
			continue  # the folder's own icons/, items/, sounds/, tiles/ and decoratives/ are the loose pack's
		var root := dir.path_join(sub)
		var items := {}
		var models := _index(root, MAX_DEPTH, items)
		var icons := _index_icons(root, 1)
		var sounds := _index_sounds(root, 1)
		var tile_maps := {}
		var tiles := _index_tiles(root, 1, tile_maps)
		var decor := _index_decoratives(root, 1)
		var info := _read_info(root, 1)
		if models.is_empty() and items.is_empty() and icons.is_empty() and sounds.is_empty() \
				and tiles.is_empty() and tile_maps.is_empty() and decor.is_empty() and not _has_decor_hide(info):
			continue  # a .gltf's textures beside the loose models, or an empty folder
		var p := _pack("dir:" + sub, "folder", sub, root, root, models)
		_take_models(p, models, items)
		_take_icons(p, icons)
		_take_sounds(p, sounds)
		_take_tiles(p, tiles, tile_maps)
		_take_decoratives(p, decor)
		_take_info(p, info)
		out.append(p)
	var files := Array(DirAccess.get_files_at(dir))
	files.sort_custom(func(a: String, b: String) -> bool: return a.naturalnocasecmp_to(b) < 0)
	var has_bundled := files.any(func(f: String) -> bool: return f.to_lower() == BUNDLED_FILE.to_lower())
	for f: String in files:
		if f.get_extension().to_lower() != "zip":
			continue
		if has_bundled and f.to_lower() in OLD_BUNDLED_FILES:
			continue  # an old Default.zip beside its Zenith.zip: the same pack, once
		out.append(zip_pack(dir.path_join(f)))
	return out


## Zenith's own packs (res://assets/models/packs/<folder>/, BUILTIN), unordered copies. In an exported
## game their .glb files are there as they are (addons/zenith_export); an imported model without its
## file is found by its .import (model_library.gd loads its scene).
static func builtin_packs() -> Array:
	if _builtin.is_empty():
		for sub: String in BUILTIN:
			if sub == FACTORIO_FOLDER:
				_builtin.append(_factorio_pack())
				continue
			var root := BUILTIN_DIR + sub
			var items := {}
			var p := _pack(BUILTIN_PREFIX + sub, "builtin", sub, root, root, _index(root, MAX_DEPTH, items))
			_take_models(p, p["models"], items)
			_take_icons(p, _index_icons(root, 0))  # none ship any (Factorio's are read from the install)
			_take_sounds(p, _index_sounds(root, 0))  # nor sounds
			var builtin_tmaps := {}
			_take_tiles(p, _index_tiles(root, 0, builtin_tmaps), builtin_tmaps)  # nor tiles
			_take_decoratives(p, _index_decoratives(root, 0))  # Placeholders ships 3D models for raised decoratives
			_take_info(p, _read_info(root, 0))
			_builtin.append(p)
	var out: Array = []
	for p: Dictionary in _builtin:
		out.append(p.duplicate())
	return out


## Whether a pack is one of Zenith's own (the Factorio pack counts: it is no modeller's).
static func is_builtin(p: Dictionary) -> bool:
	return str(p.get("kind", "")) == "builtin"


## Whether a pack (or a pack id) is the Factorio pack: pictures and icons from the install, no model
## files. The Model packs window and its preview (model_preview.gd) draw its entities with
## SpriteStandins.picture / card(..., true) and its items with SpriteStandins.item_card.
static func is_sprite_pack(p: Variant) -> bool:
	if p is Dictionary:
		return str((p as Dictionary).get("id", "")) == FACTORIO_ID
	return canonical_id(str(p)) == FACTORIO_ID


## The Factorio pack's entities with a picture (name -> true): not to be changed.
static func sprite_names() -> Dictionary:
	return _sprites


## Whether the Factorio pack is in use: on, with an install or a game's graphics list to draw from
## (a list's pictures are the mods' own files, found in the mods folders without an install too).
static func factorio_on() -> bool:
	return factorio_usable() and not pack(FACTORIO_ID).is_empty()


## Whether the Factorio pack has anything to give (else the Model packs window lists it greyed, why
## in its row).
static func factorio_usable() -> bool:
	return _install_found or ModGraphics.fingerprint != ""


const NO_INSTALL := "Factorio isn't found on this PC (--factorio-data=<dir>)"


## Whether entity model `file` (a prototype's or a variant's name, "@pack" off) is drawn as Factorio's
## picture instead of a model: the Factorio pack in use has a picture of its family, and it is asked
## of it (`pack_id`, a building's own pack), chosen for the family, or the first pack by the order
## that draws the family (its model; `base`, a creature tier's family model; `tier`, a tier's base
## model). Safe on a worker.
static func sprite_wins(file: String, pack_id := "", base := "", tier := "") -> bool:
	var sprites := _sprites
	if sprites.is_empty():
		return false
	var key := file.to_lower()
	var fam := family(key)
	if not sprites.has(fam) and not sprites.has(key):
		return false
	if not factorio_on():
		return false
	if pack_id != "":
		return canonical_id(pack_id) == FACTORIO_ID
	var c := choice(key)
	if c != "":
		return c == FACTORIO_ID
	for p: Dictionary in active():
		if not bool(p["replaces"]):
			continue
		if p["id"] == FACTORIO_ID:
			return true
		var m: Dictionary = p["models"]
		if m.has(key) or m.has(fam) or (base != "" and m.has(base)) or (tier != "" and m.has(tier)):
			return false
	return false


## Once a frame (world.gd): the Factorio pack's pictures follow the bridge's graphics list (a game's
## list names every entity's picture, mods' too). True when that may change what the world draws: the
## Factorio pack in use above another pack (its models made again, world.gd models_changed).
static func follow_sprites() -> bool:
	if _sprites_generation == ModGraphics.generation:
		return false
	var before := _sprites
	_rebuild_sprites()
	if before.hash() == _sprites.hash():
		return false
	for list: Array in [_builtin, packs]:
		for p: Dictionary in list:
			if p["id"] == FACTORIO_ID:
				p["count"] = _sprites.size()
	version += 1
	var act := active()
	for i in act.size():
		if (act[i] as Dictionary)["id"] == FACTORIO_ID:
			return i < act.size() - 1
	return false


## The player's Factorio data folder, "" without an install (item_icons.gd finds it; loaded, not
## preloaded: item_icons.gd preloads this script).
static func _install() -> String:
	return load("res://scripts/world/item_icons.gd").factorio_data_dir()


static func _factorio_pack() -> Dictionary:
	_rebuild_sprites()
	var p := _pack(FACTORIO_ID, "builtin", "Factorio", "", "factorio:", {})
	p["virtual"] = true
	_take_info(p, {"name": "Factorio", "author": "Wube Software", "icon_image": FACTORIO_LOGO,
		"credit": "© Wube Software · from your install",
		"description": "Factorio's own pictures, read from your install: buildings, belts and trees as their sprites on cards (cardboard cutouts), items as their icons. Nothing of Wube's is copied into Zenith."})
	p["count"] = _sprites.size()
	return p


## The Factorio pack's pictures again: sprite_projection.json's entities (with an install) and the
## graphics list's. Characters, vehicles and creatures (pictures round the turn) are left out: they
## keep their models.
static func _rebuild_sprites() -> void:
	_sprites_generation = ModGraphics.generation
	_read_projection()
	_install_found = _install() != ""
	var out := {}
	if _install_found:
		for name: String in _projection_names:
			out[name] = true
	for name in ModGraphics.ents:
		var key := str(name).to_lower()
		if not _projection_skip.has(key):
			out[key] = true
	_sprites = out


## sprite_projection.json's entities, read once.
static func _read_projection() -> void:
	if _projection_read:
		return
	_projection_read = true
	if not FileAccess.file_exists(PROJECTION_DATA):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PROJECTION_DATA))
	if not parsed is Dictionary:
		return
	for name: String in parsed:
		var entry: Variant = parsed[name]
		if entry is Dictionary and str((entry as Dictionary).get("mode", "")) == "rotation":
			_projection_skip[name] = true
		else:
			_projection_names.append(name)


## A folder as a pack of its own (--models=<dir>, and tests): its models anywhere inside.
static func folder_pack(dir: String, replaces: bool) -> Dictionary:
	var items := {}
	var models: Dictionary = _index(dir, MAX_DEPTH, items) if DirAccess.dir_exists_absolute(dir) else {}
	var p := _pack(ARG_ID, "arg", dir.get_file(), dir, dir, models)
	_take_models(p, models, items)
	p["replaces"] = replaces
	_take_icons(p, _index_icons(dir, 1) if DirAccess.dir_exists_absolute(dir) else {})
	_take_sounds(p, _index_sounds(dir, 1) if DirAccess.dir_exists_absolute(dir) else {})
	var tmaps := {}
	var t := _index_tiles(dir, 1, tmaps) if DirAccess.dir_exists_absolute(dir) else {}
	_take_tiles(p, t, tmaps)
	_take_decoratives(p, _index_decoratives(dir, 1) if DirAccess.dir_exists_absolute(dir) else {})
	_take_info(p, _read_info(dir, 1))
	return p


## A zip as a pack, read from its directory (its models counted, its pack.json read); its models'
## files come once it is unpacked into `cache`.
static func zip_pack(path: String) -> Dictionary:
	var name := path.get_file()
	var p := _pack("zip:" + name, "zip", name.get_basename(), path, "", {})
	var length := 0
	var f := FileAccess.open(path, FileAccess.READ)
	if f != null:
		length = f.get_length()
		f.close()
	var cache := ProjectSettings.globalize_path(cache_root).path_join("%s-%d-%d" % [name.get_basename().validate_filename(),
		length, FileAccess.get_modified_time(path)])
	p["cache"] = cache
	p["root"] = cache
	var entries := ModFiles.zip_entries(path)
	if entries.is_empty():
		p["problem"] = "it can't be read as a zip"
		return p
	var names := {}
	var item_names := {}
	var icons := 0
	var sounds := 0
	var tile_names := {}
	var decor_map_names := {}
	var info_entry := ""
	for entry: String in entries:
		var rel := safe_entry(entry)
		if rel == "" or rel.ends_with("/"):
			continue
		if rel.get_extension().to_lower() in ICON_EXTS and _in_icons_dir(rel):
			icons += 1
		elif rel.get_extension().to_lower() in SOUND_EXTS and _in_sounds_dir(rel):
			sounds += 1
		elif rel.get_extension().to_lower() in TILE_EXTS and _in_tiles_dir(rel):
			var tname := _zip_tile_name(rel)
			if tname != "":
				tile_names[tname] = true
		elif rel.get_extension().to_lower() in DECOR_EXTS and _in_decor_dir(rel):
			var dname := _zip_decor_name(rel)
			if dname != "":
				decor_map_names[dname] = true
		elif rel.get_extension().to_lower() in MODEL_EXTS:
			var dirs := Array(rel.to_lower().split("/")).slice(0, -1)
			var into: Dictionary = item_names if dirs.has(ITEMS_DIR) else names
			into[rel.get_file().get_basename().to_lower()] = true
		elif rel.get_file().to_lower() == INFO_FILE and rel.count("/") <= 1 and (info_entry == "" or rel.count("/") < info_entry.count("/")):
			info_entry = entry
	p["count"] = names.size()
	p["item_count"] = item_names.size()
	p["icon_count"] = icons
	p["sound_count"] = sounds
	p["tile_count"] = tile_names.size()
	p["decor_count"] = decor_map_names.size()
	if info_entry != "":
		var zf := FileAccess.open(path, FileAccess.READ)
		if zf != null:
			_take_info(p, _parse_info(ModFiles.zip_entry(zf, entries[info_entry]).get_string_from_utf8()))
			zf.close()
	var aliases: Variant = (p.get("info", {}) as Dictionary).get("aliases")
	if aliases is Dictionary and not (aliases as Dictionary).is_empty():
		var alias_map: Dictionary = aliases
		var mapped_tiles := {}
		for k: String in tile_names:
			mapped_tiles[str(alias_map.get(k, k))] = true
		tile_names = mapped_tiles
		p["tile_count"] = tile_names.size()
		var mapped_decor := {}
		for k: String in decor_map_names:
			mapped_decor[str(alias_map.get(k, k))] = true
		decor_map_names = mapped_decor
	for k: String in _explicit_hidden_decor_names(p):
		decor_map_names[k] = true
	p["decor_count"] = decor_map_names.size()
	if names.is_empty() and item_names.is_empty() and icons == 0 and sounds == 0 and tile_names.is_empty() \
			and decor_map_names.is_empty() and not _has_decor_hide(p.get("info", {})):
		p["problem"] = NOTHING_IN_IT
	if name.to_lower() in OLD_BUNDLED_FILES:
		p["id"] = BUNDLED_ID  # the bundled pack under its old name (its pack.json may say "Default")
		p["title"] = BUNDLED_TITLE
		p["short"] = BUNDLED_TITLE
	return p


## A saved pack id as the packs are called now: the bundled pack's old id ("zip:Default.zip") is
## Zenith's.
static func canonical_id(id: String) -> String:
	if id.begins_with("zip:") and id.trim_prefix("zip:").to_lower() in OLD_BUNDLED_FILES:
		return BUNDLED_ID
	return id


## `found` in the saved order (ids, top first), copies of them: packs not in it go on top, by
## name, but built-in ones, which go under the rest in BUILTIN's order (an order saved before the
## Factorio pack puts it last); every pack is on unless `off` has it.
static func ordered(found: Array, order: Array, off: Array) -> Array:
	var by_id := {}
	for p: Dictionary in found:
		by_id[p["id"]] = p
	var listed := {}
	for id in order:
		listed[canonical_id(str(id))] = true
	var added: Array = []
	var builtin_added: Array = []
	for p: Dictionary in found:
		if listed.has(p["id"]):
			continue
		if is_builtin(p):
			builtin_added.append(p)
		else:
			added.append(p)
	added.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["title"]).naturalnocasecmp_to(str(b["title"])) < 0)
	builtin_added.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return BUILTIN.find(str(a["id"]).trim_prefix(BUILTIN_PREFIX)) < BUILTIN.find(str(b["id"]).trim_prefix(BUILTIN_PREFIX)))
	var out: Array = []
	var seen := {}
	for p: Dictionary in added:
		out.append(p.duplicate())
		seen[p["id"]] = true
	for id in order:
		var key := canonical_id(str(id))
		if by_id.has(key) and not seen.has(key):
			out.append((by_id[key] as Dictionary).duplicate())
			seen[key] = true
	for p: Dictionary in builtin_added:
		out.append(p.duplicate())
	var off_ids := {}
	for id in off:
		off_ids[canonical_id(str(id))] = true
	for p: Dictionary in out:
		p["on"] = not off_ids.has(p["id"])
	return out


## Whether a pack keeps its place and stays on (a --models pack, for its run).
static func fixed(p: Dictionary) -> bool:
	return p["kind"] == "arg"


## The packs as Settings > Graphics > Model packs lists them: the --models one, then those in `dir`
## now, in the saved `order` with those in `off` off. A pack found since the start has "new"; one
## this run is unpacking, or found it can't use, says so.
static func listed(dir: String, order: Array, off: Array) -> Array:
	var out: Array = []
	var running := {}
	for p: Dictionary in packs:
		running[p["id"]] = p
		if p["kind"] == "arg":
			out.append(p.duplicate())
	for p: Dictionary in ordered(scan(_norm(dir)) + builtin_packs(), order, off):
		var now: Dictionary = running.get(p["id"], {})
		p["new"] = now.is_empty() and models_dir != ""
		if not now.is_empty():
			p["unpacking"] = now["unpacking"]
			for key: String in ["checking", "copies", "unchecked"]:
				p[key] = now[key]
			if now["problem"] != "":
				p["problem"] = now["problem"]
			# A zip's models are known once unpacked (its directory gives only their count): this
			# run's copy has them.
			if not bool(now["unpacking"]) and (p["models"] as Dictionary).is_empty() and (p["items"] as Dictionary).is_empty() \
					and not ((now["models"] as Dictionary).is_empty() and (now["items"] as Dictionary).is_empty()):
				_take_models(p, now["models"], now["items"])
				p["root"] = now["root"]
			if not bool(now["unpacking"]) and (p["icons"] as Dictionary).is_empty() and not (now["icons"] as Dictionary).is_empty():
				_take_icons(p, now["icons"])
				p["root"] = now["root"]
			if not bool(now["unpacking"]) and (p["sounds"] as Dictionary).is_empty() and not (now["sounds"] as Dictionary).is_empty():
				_take_sounds(p, now["sounds"])
				p["root"] = now["root"]
			if not bool(now["unpacking"]) and (p["tiles"] as Dictionary).is_empty() and (p.get("tile_maps", {}) as Dictionary).is_empty() \
					and not ((now["tiles"] as Dictionary).is_empty() and (now.get("tile_maps", {}) as Dictionary).is_empty()):
				_take_tiles(p, now["tiles"], now.get("tile_maps", {}))
				p["root"] = now["root"]
			if not bool(now["unpacking"]) and (p["decoratives"] as Dictionary).is_empty() and not (now["decoratives"] as Dictionary).is_empty():
				_take_decoratives(p, now["decoratives"])
				p["root"] = now["root"]
		if p["id"] == FACTORIO_ID:
			p["count"] = _sprites.size()
			if not factorio_usable():
				p["problem"] = NO_INSTALL  # greyed in the window, why in its row
		out.append(p)
	return out


## The ids of the folder's packs (those found at start-up, or `list`), top first, as settings.cfg
## keeps them.
static func saved_order(list: Variant = null) -> Array:
	var out: Array = []
	var of: Array = packs if list == null else list
	for p: Dictionary in of:
		if p["kind"] != "arg":
			out.append(str(p["id"]))
	return out


## The ids of the folder's packs that are off.
static func saved_off(list: Variant = null) -> Array:
	var out: Array = []
	var of: Array = packs if list == null else list
	for p: Dictionary in of:
		if p["kind"] != "arg" and not bool(p["on"]):
			out.append(str(p["id"]))
	return out


## The packs to take models from, in order (tests), with the built-in ones under them when the list
## has none. Nothing is unpacked.
static func use(list: Array) -> void:
	wait()
	_configured = true
	packs = list
	if not list.any(func(p: Dictionary) -> bool: return is_builtin(p)):
		packs = list + ordered(builtin_packs(), [], [])
	_activate()


## The packs models are taken from now, in order: not to be changed (it is replaced, never changed in
## place, so a reader on a worker keeps a whole list; model_name() asks per entity, no copy is made).
## Before configure() (a test script, a tool) the built-in ones in their default order.
static func active() -> Array:
	_mutex.lock()  # reentrant: _activate() takes it again
	if not _configured:
		_configured = true
		packs = ordered(builtin_packs(), [], [])
		_activate()
	var out := _active
	_mutex.unlock()
	return out


## Returns the built-in Placeholders pack when `file` prefers it over FUE5/Wube3DP and it is active & replacing.
static func preferred_placeholder_pack(file: String) -> Dictionary:
	var key := file.to_lower()
	if not prefer_builtin_assemblers or not PREFERRED_PLACEHOLDERS.has(key):
		return {}
	for p: Dictionary in active():
		if str(p["id"]) == LAST_ID and bool(p["replaces"]) and (p["models"] as Dictionary).has(key):
			return p
	return {}


## The file of model `file` (a prototype's name, or a piece's as "transport-belt-start") in the
## highest pack in use that has one, among those that go by the order (`replacing`) or those that
## only fill in; "" if none has it.
static func find(file: String, replacing: bool) -> String:
	var key := file.to_lower()
	var pref := preferred_placeholder_pack(key) if replacing else {}
	if not pref.is_empty():
		for p: Dictionary in active():
			if bool(p["replaces"]) and not is_builtin(p):
				var custom: String = (p["models"] as Dictionary).get(key, "")
				if custom != "":
					return custom
		return str((pref["models"] as Dictionary).get(key, ""))
	for p: Dictionary in active():
		if bool(p["replaces"]) == replacing:
			var path: String = (p["models"] as Dictionary).get(key, "")
			if path != "":
				return path
	return ""


## The file of model `file` in the pack in use `id`, "" if it isn't in use or hasn't one.
static func find_in(id: String, file: String) -> String:
	var p := pack(id)
	return str((p["models"] as Dictionary).get(file.to_lower(), "")) if not p.is_empty() else ""


## Whether pack `p` provides model `name`: has it, or for an ore (NUMBERED_FAMILIES) any of the models
## it is drawn by: its stages (`-rich`, `-sparse`) or its first scattered rock (`iron-ore-1`,
## model_library.gd ore_rocks). The one rule for which packs have an ore: the order's first that has
## it draws it (ore_scatter_names), the Model packs window lists it on the ore's card.
## Any other model too: a pack with only its numbered variants (`rock-big-1`) provides it.
static func provides(p: Dictionary, name: String) -> bool:
	if p.is_empty():
		return false
	var models: Dictionary = p["models"]
	var key := name.to_lower()
	if models.has(key):
		return true
	if models.has(key + "-1") and not NUMBERED_PROTOS.has(key + "-1"):
		return true
	if not NUMBERED_FAMILIES.has(key):
		return false
	for sfx: String in ORE_SUFFIXES:
		if models.has(key + sfx):
			return true
	return false


## The name a numbered variant is a variant of (`coal-2` -> `coal`, `rock-big-3` -> `rock-big`), "" for
## a name that isn't one (no number at its end, or a prototype of its own: NUMBERED_PROTOS).
static func variant_base(name: String) -> String:
	var f := name.to_lower()
	var slash := f.rfind("/")  # an icon's "<kind>/<name>"
	var at := f.rfind("-")
	if at <= slash + 1 or at == f.length() - 1:
		return ""
	var number := f.substr(at + 1)
	for c in number:
		if c < "0" or c > "9":
			return ""
	if NUMBERED_PROTOS.has(f.substr(slash + 1)):
		return ""
	return f.substr(0, at)


## The variants of `name` among `names` (a pack's models, items or icons: name -> file): `name` if it
## is there, then `name-1`, `name-2`... in order; [] for none. Numbered from 1: without `name-1` only
## the plain one counts, unless `gaps` (ores' scattered rocks, any of 1 to VARIANT_MAX).
static func variants_in(names: Dictionary, name: String, gaps := false) -> Array:
	var key := name.to_lower()
	var out: Array = []
	if names.has(key):
		out.append(key)
	if not gaps and not names.has(key + "-1"):
		return out
	for i in range(1, VARIANT_MAX + 1):
		var v := "%s-%d" % [key, i]
		if names.has(v) and not NUMBERED_PROTOS.has(v.substr(v.rfind("/") + 1)):
			out.append(v)
	return out


## The seed of a placed thing's variant (variant_pick): a hash of its position (1/256 tiles, as the
## game sends it), as ore rocks' places are (model_library.gd ore_rock_places), or of its unit number
## where it has no position. The same on every load and in every view.
static func variant_seed(fixed: Vector2i, unit := 0) -> int:
	return hash([fixed, "variant"]) if unit == 0 else hash([unit, "variant"])


## Which of `count` variants a seed picks (0 for none or one).
static func variant_pick(count: int, seed: int) -> int:
	return 0 if count < 2 else ((seed >> 4) & 0xffff) % count


## What a pack's file `name` is called for its pack.json's "aliases" (`{"coal-ore": "coal"}`: the
## pack's name -> Factorio's): `coal-ore-2` -> `coal-2`, `coal-ore-rich` -> `coal-rich`, an icon's
## `item/coal-ore` -> `item/coal`; the longest alias that fits. Unchanged without one.
static func alias_name(name: String, aliases: Dictionary) -> String:
	if aliases.is_empty():
		return name
	var slash := name.rfind("/")
	var kind := name.substr(0, slash + 1)
	var bare := name.substr(slash + 1)
	var best := ""
	for from: String in aliases:
		if (bare == from or bare.begins_with(from + "-")) and from.length() > best.length():
			best = from
	return name if best == "" else kind + str(aliases[best]) + bare.substr(best.length())


## `names` (name -> file) with the aliases' names: a name the pack also has under its own file keeps
## that file.
static func _aliased(names: Dictionary, aliases: Dictionary) -> Dictionary:
	if aliases.is_empty():
		return names
	var out := {}
	for name: String in names:
		var to := alias_name(name, aliases)
		if to != name and names.has(to):
			to = name
		if not out.has(to):
			out[to] = names[name]
	return out


## The pack's models, item models and icons under its aliases' names (pack.json "aliases"), from
## the files as they were found (kept in `found_*`, so taking the info again changes nothing).
static func _apply_aliases(p: Dictionary) -> void:
	var aliases: Dictionary = (p.get("info", {}) as Dictionary).get("aliases", {})
	for key in ["models", "items", "icons", "tiles", "tile_maps", "decoratives"]:
		if p.has("found_" + key):  # (a zip's listing has only its counts until it is unpacked)
			p[key] = _aliased(p["found_" + key], aliases)
			if COUNT_KEYS.has(key):
				p[COUNT_KEYS[key]] = (p[key] as Dictionary).size()
	if p.has("found_tiles") or p.has("found_tile_maps"):
		var seen_tiles := {}
		for k in (p.get("tiles", {}) as Dictionary):
			seen_tiles[k] = true
		for k in (p.get("tile_maps", {}) as Dictionary):
			seen_tiles[k] = true
		p["tile_count"] = seen_tiles.size()
	if p.has("found_decoratives"):
		var seen_decor := {}
		for k in (p.get("decoratives", {}) as Dictionary):
			seen_decor[k] = true
		for k: String in _explicit_hidden_decor_names(p):
			seen_decor[k] = true
		p["decor_count"] = seen_decor.size()


static func _read_numbered_protos() -> Dictionary:
	var out := {}
	var f := FileAccess.open(PROTO_INDEX, FileAccess.READ)
	if f == null:
		return out
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK or not json.data is Dictionary:
		return out
	for kind in (json.data as Dictionary):
		var names: Variant = json.data[kind]
		if kind == "recipe" or kind == "technology" or not names is Dictionary:
			continue
		for name: String in (names as Dictionary):
			var at := name.rfind("-")
			if at > 0 and name.substr(at + 1).is_valid_int():
				out[name] = true
	return out


## provides() for the pack in use `id`.
static func provides_in(id: String, name: String) -> bool:
	return provides(pack(id), name)


## The pack in use of this id, {} if it isn't one (off, left out or gone).
static func pack(id: String) -> Dictionary:
	id = canonical_id(id)
	for p: Dictionary in active():
		if p["id"] == id:
			return p
	return {}


## The pack chosen for model `file`'s family (the Model packs window), "" for the order's; only a
## pack in use counts.
static func choice(file: String) -> String:
	var c := choices
	if c.is_empty():
		return ""
	var id := str(c.get(family(file), ""))
	return id if id != "" and not pack(id).is_empty() else ""


## The packs chosen for families (family -> pack id; an empty id or a pack of the order's own
## choosing is no choice). Model library and drawn chunks follow at once: model_library.gd
## choices_changed().
static func set_choices(map: Dictionary) -> void:
	var out := {}
	for k in map:
		if str(map[k]) != "":
			out[str(k)] = canonical_id(str(map[k]))
	if _icon_choices(out) != _icon_choices(choices):
		icons_version += 1
	if _icon_choices(out, SOUND_PREFIX) != _icon_choices(choices, SOUND_PREFIX):
		sounds_version += 1
	if _icon_choices(out, TILE_PREFIX) != _icon_choices(choices, TILE_PREFIX):
		tiles_version += 1
	if _icon_choices(out, DECOR_PREFIX) != _icon_choices(choices, DECOR_PREFIX):
		decor_version += 1
	choices = out
	version += 1


## Key in `pbr_models` for one entity family or item inside `pack_id`.
static func pbr_model_key(pack_id: String, name: String, is_item := false) -> String:
	var pid := canonical_id(pack_id)
	var mkey := (ITEM_PREFIX + name.to_lower()) if is_item else family(name.to_lower())
	return pid + "|" + mkey


## Applies per-pack and per-model PBR overrides (settings.cfg [model_packs] pbr_packs / pbr_models).
## Replaces both tables wholesale so worker threads can read them safely without locks.
static func set_pbr_overrides(packs_map: Dictionary, models_map: Dictionary) -> void:
	var out_packs := {}
	for k in packs_map:
		var pid := canonical_id(str(k))
		if pid != "":
			out_packs[pid] = bool(packs_map[k])
	var out_models := {}
	for k in models_map:
		var raw := str(k)
		var sep := raw.find("|")
		if sep > 0:
			var pid := canonical_id(raw.substr(0, sep))
			var mkey := raw.substr(sep + 1).to_lower()
			if pid != "" and mkey != "":
				out_models[pid + "|" + mkey] = bool(models_map[k])
	pbr_packs = out_packs
	pbr_models = out_models
	version += 1


## A model's family: the model of the prototype it draws (or the piece's whole) without its
## direction, curve, end piece, shape, richness or pose: "inserter" for "inserter-east",
## "transport-belt" for "transport-belt-curve-left", "underground-belt" for "underground-belt-input",
## "stone-wall" for "stone-wall-es-fill", "big-biter" for "big-biter-corpse-2", "inserter" for
## "inserter-arm-basic-upper" (PREFIX_FAMILIES, PART_FAMILIES). A name without
## such a variant is its own family.
static func family(name: String) -> String:
	var f := name.to_lower()
	for prefix: String in PREFIX_FAMILIES:
		if f.begins_with(prefix):
			return str(PREFIX_FAMILIES[prefix])
	if PART_FAMILIES.has(f):
		return str(PART_FAMILIES[f])
	# A numbered variant is of its plain name's family (`coal-2` coal's, `rock-big-3` rock-big's,
	# `transport-belt-curve-left-2` the belt's), unless it is a prototype of its own (variant_base).
	var base := variant_base(f)
	if base != "":
		f = base
	_mutex.lock()
	var names := _names
	_mutex.unlock()
	var again := true
	while again:
		again = false
		for s: String in ALWAYS_SUFFIXES:
			if f.ends_with(s) and f.length() > s.length():
				f = f.substr(0, f.length() - s.length())
				again = true
				break
		if again:
			continue
		for s: String in SUFFIXES:
			if f.ends_with(s) and names.has(f.substr(0, f.length() - s.length())):
				f = f.substr(0, f.length() - s.length())
				again = true
				break
	return f


## The model names of a family the packs have, sorted (`of` the packs to look in: every pack found).
static func family_names(fam: String, of: Variant = null) -> Array:
	var out := {}
	var list: Array = packs if of == null else of
	for p: Dictionary in list:
		for name: String in p["models"]:
			if family(name) == fam:
				out[name] = true
	var names := out.keys()
	names.sort()
	return names


## The families a pack has, each with its model names: family -> sorted names.
static func families_of(p: Dictionary) -> Dictionary:
	var out := {}
	for name: String in p["models"]:
		var f := family(name)
		if not out.has(f):
			out[f] = []
		(out[f] as Array).append(name)
	for f in out:
		(out[f] as Array).sort()
	return out


static func pbr_override_off(p: Dictionary) -> bool:
	var id := str(p.get("id", ""))
	return (id == LAST_ID and not placeholder_pbr) or (id == FUE5_ID and not fue5_pbr) or (id == WUBE3DP_ID and not wube3dp_pbr)


## A pack's own default shading from pack.json ("pbr" or "factorio"), ignoring user overrides.
static func pack_default_shading(p: Dictionary) -> String:
	if p.is_empty() or is_sprite_pack(p) or pbr_override_off(p):
		return "factorio"
	return "pbr" if str((p.get("info", {}) as Dictionary).get("shading", "")) == "pbr" else "factorio"


## One model's default shading from pack.json's "shading_models" over `base` (the pack's own default,
## pack_default_shading(p), unless the user's pack-level PBR toggle gives another).
static func pack_default_model_shading(p: Dictionary, name: String, is_item := false, base := "") -> String:
	var fallback := base if base != "" else pack_default_shading(p)
	if p.is_empty() or is_sprite_pack(p) or pbr_override_off(p):
		return fallback
	var per: Variant = (p.get("info", {}) as Dictionary).get("shading_models", null)
	if not (per is Dictionary) or (per as Dictionary).is_empty():
		return fallback
	if is_item:
		var f_item := name.to_lower()
		while f_item != "":
			var hit := _shading_match(per as Dictionary, ITEMS_DIR + "/" + f_item)
			if hit != "":
				return hit
			f_item = variant_base(f_item)
	var f := name.to_lower()
	while f != "":
		var hit := _shading_match(per as Dictionary, f)
		if hit != "":
			return hit
		f = variant_base(f)
	return fallback


## How a pack's textured materials are drawn: user pack PBR override over its pack.json ("pbr" vs
## "factorio"; the Factorio pack always; --fue5-pbr=off / --wube3dp-pbr=off / --placeholder-pbr=off
## keep them on "factorio").
static func shading(p: Dictionary) -> String:
	if p.is_empty() or is_sprite_pack(p) or pbr_override_off(p):
		return "factorio"
	var pp := pbr_packs
	var pid := canonical_id(str(p.get("id", "")))
	if pid != "" and pp.has(pid):
		return "pbr" if bool(pp[pid]) else "factorio"
	return pack_default_shading(p)


## Whether a model's (or an item model's) file uses "pbr" shading under user overrides and pack.json.
static func pbr(path: String) -> bool:
	var p := _pack_at(path, active())
	if p.is_empty():
		p = _pack_at(path, packs)
	if p.is_empty() or is_sprite_pack(p) or pbr_override_off(p):
		return false
	var root := str(p["root"])
	var rel_dir := path.substr(root.length() + 1).get_base_dir().to_lower() if path.begins_with(root + "/") else ""
	var is_item := path.get_base_dir().get_file().to_lower() == ITEMS_DIR or ITEMS_DIR in rel_dir.split("/", false)
	return model_shading(p, path.get_file().get_basename(), is_item) == "pbr"


## One model's shading in a pack: user per-model PBR override (`pbr_models`), then pack.json's
## "shading_models", then the pack's default: the user's pack-level PBR toggle (`pbr_packs`) over pack.json's "shading".
static func model_shading(p: Dictionary, name: String, is_item := false) -> String:
	if p.is_empty() or is_sprite_pack(p) or pbr_override_off(p):
		return "factorio"
	var pm := pbr_models
	var pid := canonical_id(str(p.get("id", "")))
	if pid != "" and not pm.is_empty():
		if is_item:
			var f_item := name.to_lower()
			while f_item != "":
				var ik := pid + "|" + ITEM_PREFIX + f_item
				if pm.has(ik):
					return "pbr" if bool(pm[ik]) else "factorio"
				f_item = variant_base(f_item)
		else:
			var exact_k := pid + "|" + name.to_lower()
			if pm.has(exact_k):
				return "pbr" if bool(pm[exact_k]) else "factorio"
			var fam_k := pid + "|" + family(name.to_lower())
			if pm.has(fam_k):
				return "pbr" if bool(pm[fam_k]) else "factorio"
	# The pack-level toggle only sets the pack's default: pack.json's "shading_models" entries (a fixed pack's
	# belts and splitters as "factorio", say) still win over it.
	var pp := pbr_packs
	if pid != "" and pp.has(pid):
		return pack_default_model_shading(p, name, is_item, "pbr" if bool(pp[pid]) else "factorio")
	return pack_default_model_shading(p, name, is_item)


## Shading for an entity family inside pack `p`, picking a present family member (e.g. `iron-ore-1`
## when the pack omits `iron-ore`) so wildcard rules in pack.json match accurately.
static func family_shading(p: Dictionary, fam: String) -> String:
	if p.is_empty() or is_sprite_pack(p) or pbr_override_off(p):
		return "factorio"
	var rep := fam
	var models: Variant = p.get("models")
	if models is Dictionary:
		var mdict: Dictionary = models
		if not mdict.has(fam):
			var names := mdict.keys()
			names.sort()
			for n: Variant in names:
				var ns := str(n)
				if family(ns) == fam:
					rep = ns
					break
	return model_shading(p, rep, false)


## True when `pack_id` has a user pack-level or per-model PBR override.
static func has_pack_pbr_overrides(pack_id: String) -> bool:
	var pid := canonical_id(pack_id)
	if pid == "":
		return false
	if pbr_packs.has(pid):
		return true
	var prefix := pid + "|"
	var pm := pbr_models
	for k: Variant in pm:
		if str(k).begins_with(prefix):
			return true
	return false


## True when `(pack_id, name, is_item)` has an explicit user per-model PBR override.
static func has_model_pbr_override(pack_id: String, name: String, is_item := false) -> bool:
	var pm := pbr_models
	return pm.has(pbr_model_key(pack_id, name, is_item))


## Pack PBR summary for UI: "on", "off", or "mixed".
static func pack_pbr_state(p: Dictionary) -> String:
	if p.is_empty() or is_sprite_pack(p) or pbr_override_off(p):
		return "off"
	var pid := canonical_id(str(p.get("id", "")))
	var pm := pbr_models
	var base_on := shading(p) == "pbr"
	var prefix := pid + "|"
	for k: Variant in pm:
		if str(k).begins_with(prefix) and bool(pm[k]) != base_on:
			return "mixed"
	# pack.json's "shading_models" entries win over the pack toggle, so any that differ from the pack's
	# base shading make it mixed.
	var per: Variant = (p.get("info", {}) as Dictionary).get("shading_models", {})
	if pid != "" and per is Dictionary:
		for v: Variant in (per as Dictionary).values():
			if (str(v) == "pbr") != base_on:
				return "mixed"
	return "on" if base_on else "off"


static func _shading_match(per: Dictionary, f: String) -> String:
	if per.has(f):
		return str(per[f])
	for pattern: String in per:
		if pattern.contains("*") and f.match(pattern):
			return str(per[pattern])
	return ""


## The pack in use a model's file comes from, {} for none.
static func pack_of(path: String) -> Dictionary:
	return _pack_at(path, active())


static func _pack_at(path: String, list: Array) -> Dictionary:
	if path.begins_with("gltf:"):
		path = path.substr(5)
	elif path.begins_with("scene:"):
		path = path.substr(6)
	for p: Dictionary in list:
		var root := str(p["root"])
		if p["kind"] == "loose":
			var sub_rel := path.substr(root.length() + 1).to_lower() if path.begins_with(root + "/") else ""
			if path.get_base_dir() == root or sub_rel.begins_with(ITEMS_DIR + "/") or sub_rel.begins_with(TILES_DIR + "/") \
					or sub_rel.begins_with(DECOR_DIR + "/") or sub_rel.begins_with(ICONS_DIR + "/") or sub_rel.begins_with(SOUNDS_DIR + "/"):
				return p
		elif path.begins_with(root + "/"):
			return p
	return {}


## True when a model's file comes from a pack that isn't Zenith's own: a modeller's (model_library.gd:
## its vertex colours, its one model per direction).
static func owns(path: String) -> bool:
	var p := pack_of(path)
	return not p.is_empty() and not is_builtin(p)


## Each model name the packs in use have -> the pack it is taken from: the one chosen for its family,
## else the first that goes by the order, else the first that fills in.
static func in_use() -> Dictionary:
	var out := {}
	if not choices.is_empty():
		for p: Dictionary in active():
			for name: String in p["models"]:
				if choice(name) == p["id"]:
					out[name] = p
	if prefer_builtin_assemblers:
		for name: String in PREFERRED_PLACEHOLDERS:
			if out.has(name):
				continue
			var pref := preferred_placeholder_pack(name)
			if pref.is_empty():
				continue
			for p: Dictionary in active():
				if bool(p["replaces"]) and not is_builtin(p) and (p["models"] as Dictionary).has(name):
					out[name] = p
					break
			if not out.has(name):
				out[name] = pref
	for replacing in [true, false]:
		for p: Dictionary in active():
			if bool(p["replaces"]) != replacing:
				continue
			for name: String in p["models"]:
				if not out.has(name):
					out[name] = p
	return out


## How many models the packs in use give.
static func model_count() -> int:
	return in_use().size()


## The file of the icon a pack gives for prototype `name` of `kind` ("item", "entity", "fluid",
## "recipe", "technology", "virtual-signal"...): the pack chosen for it ("icon:<name>"), else the
## first pack in use with one (those that go by the order, then those that fill in); "" for none,
## Factorio's own then. Safe on a worker (active() and choices are replaced, never changed).
static func icon_file(kind: String, name: String) -> String:
	var key := name.to_lower()
	var c := choices
	if not c.is_empty():
		var id := str(c.get(ICON_PREFIX + key, ""))
		if id != "":
			if canonical_id(id) == FACTORIO_ID and factorio_on():
				return ""  # Factorio's own, chosen
			var chosen := icon_in(pack(id), kind, key)
			if chosen != "":
				return chosen
	var act := active()
	for replacing in [true, false]:
		for p: Dictionary in act:
			if bool(p["replaces"]) == replacing:
				if p["id"] == FACTORIO_ID:
					if factorio_usable():
						return ""  # Factorio above the rest: the install's own icon
					continue
				var path := icon_in(p, kind, key)
				if path != "":
					return path
	return ""


## The pack in use whose icon icon_file() gives, {} for none.
static func icon_pack(kind: String, name: String) -> Dictionary:
	var path := icon_file(kind, name)
	if path == "":
		return {}
	for p: Dictionary in active():
		if (p["icons"] as Dictionary).values().has(path):
			return p
	return {}


## Pack `p`'s icon file for `name` of `kind`: its `<kind>/<name>` one, else its bare `<name>`; "". Of
## its variants (`<name>-1.png`, ...: variants_in), the one its name picks.
static func icon_in(p: Dictionary, kind: String, name: String) -> String:
	if p.is_empty():
		return ""
	var icons: Dictionary = p.get("icons", {})
	if icons.is_empty():
		return ""
	var key := name.to_lower()
	for k in [kind.to_lower() + "/" + key, key]:
		var found := variants_in(icons, k)
		if not found.is_empty():
			# An icon has no place: its variant is picked by its name, the same one everywhere.
			return str(icons[found[variant_pick(found.size(), hash(k))]])
	return ""


## A pack's icons, sorted: keys "<name>" (any kind) and "<kind>/<name>", an icon's variants
## (`item/sulfur-1`, `item/sulfur-2`: variants_in) one key, the plain name's.
static func icon_names(p: Dictionary) -> Array:
	var grouped := {}
	for key: String in (p.get("icons", {}) as Dictionary):
		var base := variant_base(key)
		grouped[base if base != "" else key] = true
	var names: Array = grouped.keys()
	names.sort()
	return names


## The pack chosen for icon `name`, "" for the order's; only a pack in use counts.
static func icon_choice(name: String) -> String:
	var id := str(choices.get(ICON_PREFIX + name.to_lower(), ""))
	return id if id != "" and not pack(id).is_empty() else ""


## An icon file as a square picture (the middle square of one that isn't), or null.
static func icon_image(path: String) -> Image:
	var image: Image = null
	if path.begins_with("res://") and not FileAccess.file_exists(path):
		var tex := load(path) as Texture2D  # imported only, in an exported game
		if tex != null:
			image = tex.get_image()
	else:
		image = Image.load_from_file(path)
	if image == null or image.is_empty():
		return null
	if image.is_compressed():
		image.decompress()
	image.convert(Image.FORMAT_RGBA8)
	var side := mini(image.get_width(), image.get_height())
	if image.get_width() != side or image.get_height() != side:
		image = image.get_region(Rect2i((image.get_width() - side) / 2, (image.get_height() - side) / 2, side, side))
	return image


## How many of `choices` are models' families (the rest are "icon:", "item:", "sound:", "tile:"
## and "decor:" ones).
static func model_choice_count() -> int:
	var n := 0
	for k in choices:
		var ks := str(k)
		if not ks.begins_with(ICON_PREFIX) and not ks.begins_with(ITEM_PREFIX) and not ks.begins_with(SOUND_PREFIX) \
				and not ks.begins_with(TILE_PREFIX) and not ks.begins_with(DECOR_PREFIX):
			n += 1
	return n


static func _icon_choices(map: Dictionary, prefix := ICON_PREFIX) -> Dictionary:
	var out := {}
	for k in map:
		if str(k).begins_with(prefix):
			out[k] = map[k]
	return out


## The file a pack gives in place of Factorio's sound `path` ("core/sound/gui-click.ogg", as
## sound_bank.gd names them): the pack chosen for it ("sound:<path>"), else the first pack in use
## with one (those that go by the order, then those that fill in); "" for none, the install's own
## then, and when the Factorio pack comes first: Factorio's own file wins, and sound_bank.gd asks
## again `past_factorio` (the packs under it) only when Factorio has none. "" for everything with
## sounds_on false. Safe on a worker (active() and choices are replaced, never changed).
static func sound_file(path: String, past_factorio := false) -> String:
	if not sounds_on:
		return ""
	var key := path.to_lower()
	var c := choices
	if not c.is_empty():
		var id := str(c.get(SOUND_PREFIX + key, ""))
		if id != "":
			if canonical_id(id) == FACTORIO_ID and not pack(id).is_empty():
				return ""  # Factorio's own, chosen
			var chosen := sound_in(pack(id), key)
			if chosen != "":
				return chosen
	var act := active()
	for replacing in [true, false]:
		for p: Dictionary in act:
			if bool(p["replaces"]) == replacing:
				if p["id"] == FACTORIO_ID:
					if not past_factorio:
						return ""  # Factorio above the rest: its own sound, if it has one
					continue
				var file := sound_in(p, key)
				if file != "":
					return file
	return ""


## The pack in use whose sound sound_file() gives, {} for none.
static func sound_pack(path: String) -> Dictionary:
	var file := sound_file(path)
	if file == "":
		return {}
	for p: Dictionary in active():
		if (p.get("sounds", {}) as Dictionary).values().has(file):
			return p
	return {}


## Pack `p`'s file for Factorio's sound `path`, "".
static func sound_in(p: Dictionary, path: String) -> String:
	if p.is_empty():
		return ""
	return str((p.get("sounds", {}) as Dictionary).get(path.to_lower(), ""))


## A pack's sounds, sorted: their Factorio paths ("base/sound/walking/grass-3.ogg").
static func sound_names(p: Dictionary) -> Array:
	var names: Array = (p.get("sounds", {}) as Dictionary).keys()
	names.sort()
	return names


## The pack chosen for sound `path`, "" for the order's; only a pack in use counts.
static func sound_choice(path: String) -> String:
	var id := str(choices.get(SOUND_PREFIX + path.to_lower(), ""))
	return id if id != "" and not pack(id).is_empty() else ""


## Packs' sounds on or off (Settings > Sound's "Sounds from model packs"; --pack-sounds=off wins for
## the run, fx_settings.gd). sound_bank.gd drops its decoded sounds when it changes.
static func set_sounds_on(on: bool) -> void:
	if on != sounds_on:
		sounds_on = on
		sounds_version += 1


## Packs' ground textures on or off (Settings > Graphics' "Ground textures from model packs";
## --pack-tiles=off wins for the run). terrain_textures.gd reloads its layers when it changes.
static func set_tiles_on(on: bool) -> void:
	if on != tiles_on:
		tiles_on = on
		tiles_version += 1


## Companion tile PBR maps (-normal, -height, -roughness) on or off (--pack-tile-pbr=off).
static func set_tile_pbr_on(on: bool) -> void:
	if on != tile_pbr_on:
		tile_pbr_on = on
		tiles_version += 1


## The tile picture files a pack gives for `tile_name` (one file or a sorted array of variant files),
## [] when it has none.
static func tile_in(p: Dictionary, tile_name: String) -> Array:
	if p.is_empty():
		return []
	var tiles: Variant = p.get("tiles")
	if not tiles is Dictionary:
		return []
	var found: Variant = (tiles as Dictionary).get(tile_name.to_lower())
	return (found as Array).duplicate() if found is Array else []


## Companion PBR maps a pack gives for `tile_name` ({"normal": [...], "height": [...], "roughness": [...]}),
## {} when it has none.
static func tile_maps_in(p: Dictionary, tile_name: String) -> Dictionary:
	if p.is_empty():
		return {}
	var tmaps: Variant = p.get("tile_maps")
	if not tmaps is Dictionary:
		return {}
	var found: Variant = (tmaps as Dictionary).get(tile_name.to_lower())
	return (found as Dictionary).duplicate(true) if found is Dictionary else {}


static func _match_spec(cfg_root: Variant, item_name: String) -> Dictionary:
	if not cfg_root is Dictionary or (cfg_root as Dictionary).is_empty():
		return {}
	var map := cfg_root as Dictionary
	var key := item_name.to_lower()
	var wilds: Array = []
	for pat: Variant in map:
		var ps := str(pat)
		if ps.contains("*") and key.match(ps):
			wilds.append(ps)
	var by_specificity := func(a: String, b: String) -> bool:
		return (a.length() < b.length()) if a.length() != b.length() else (a < b)
	wilds.sort_custom(by_specificity)
	var out := {}
	for pat: String in wilds:
		if map[pat] is Dictionary:
			out.merge(map[pat] as Dictionary, true)
	if map.has(key) and map[key] is Dictionary:
		out.merge(map[key] as Dictionary, true)
	return out


## Per-tile overrides from pack.json's "tiles" section (`size`, `count`, `roughness`, `specular`,
## `normal_strength`, `height_strength`, `normal_flip_x`, `normal_flip_y`), matching `*` wildcards
## (shortest first) then the exact tile name; {} for none.
static func tile_spec(p: Dictionary, tile_name: String) -> Dictionary:
	if p.is_empty():
		return {}
	return _match_spec((p.get("info", {}) as Dictionary).get("tiles"), tile_name)


## The ground texture source a pack gives for `tile_name`: {"files", "maps", "pack", "spec"}, or {}
## for Factorio's/mod's own. Follows the pack order and "tile:<name>" choices; Factorio's own wins
## above packs below it unless `past_factorio` is true (Factorio and mods have no picture). Note
## that a higher pack providing albedo alone returns maps={} (never mixes lower packs' maps onto
## its albedo), while a PBR-only pack returns files=[] and non-empty maps so TerrainTextures layers
## them onto Factorio's/mod's albedo. Safe on a worker.
static func tile_source(tile_name: String, past_factorio := false) -> Dictionary:
	if not tiles_on:
		return {}
	var key := tile_name.to_lower()
	var c := choices
	if not c.is_empty():
		var id := str(c.get(TILE_PREFIX + key, ""))
		if id != "":
			if canonical_id(id) == FACTORIO_ID and not pack(id).is_empty():
				return {}
			var chosen_p := pack(id)
			var chosen_files := tile_in(chosen_p, key)
			var chosen_maps := tile_maps_in(chosen_p, key) if tile_pbr_on else {}
			if not chosen_files.is_empty() or not chosen_maps.is_empty():
				return {"files": chosen_files, "maps": chosen_maps, "pack": chosen_p, "spec": tile_spec(chosen_p, key)}
	var act := active()
	for replacing in [true, false]:
		for p: Dictionary in act:
			if bool(p["replaces"]) == replacing:
				if p["id"] == FACTORIO_ID:
					if not past_factorio and factorio_usable():
						return {}
					continue
				var files := tile_in(p, key)
				var maps := tile_maps_in(p, key) if tile_pbr_on else {}
				if not files.is_empty() or not maps.is_empty():
					return {"files": files, "maps": maps, "pack": p, "spec": tile_spec(p, key)}
	return {}


## The files a pack gives for `tile_name`, [] for none.
static func tile_files(tile_name: String, past_factorio := false) -> Array:
	var src := tile_source(tile_name, past_factorio)
	var files: Variant = src.get("files")
	return files if files is Array else []


## The first file a pack gives for `tile_name`, "" for none.
static func tile_file(tile_name: String, past_factorio := false) -> String:
	var files := tile_files(tile_name, past_factorio)
	return str(files[0]) if not files.is_empty() else ""


## The pack in use whose tile tile_source() gives, {} for none.
static func tile_pack(tile_name: String, past_factorio := false) -> Dictionary:
	var src := tile_source(tile_name, past_factorio)
	var p: Variant = src.get("pack")
	return p if p is Dictionary else {}


## A pack's tiles, sorted ("grass-1", "concrete"...), including tiles with only PBR maps.
static func tile_names(p: Dictionary) -> Array:
	var seen := {}
	var tiles: Variant = p.get("tiles")
	if tiles is Dictionary:
		for k in (tiles as Dictionary):
			seen[k] = true
	var tmaps: Variant = p.get("tile_maps")
	if tmaps is Dictionary:
		for k in (tmaps as Dictionary):
			seen[k] = true
	var names: Array = seen.keys()
	names.sort()
	return names


## The pack chosen for tile `tile_name`, "" for the order's; only a pack in use counts.
static func tile_choice(tile_name: String) -> String:
	var id := str(choices.get(TILE_PREFIX + tile_name.to_lower(), ""))
	return id if id != "" and not pack(id).is_empty() else ""


## Packs' decoratives and 3D grass on or off (Settings > Graphics' "Decoratives from model packs";
## --pack-decoratives=off wins for the run). decoratives.gd reloads when it changes.
static func set_decor_on(on: bool) -> void:
	if on != decor_on:
		decor_on = on
		decor_version += 1


## 3D decorative models (.glb/.gltf in decoratives/) on or off (Settings > Graphics' "3D decorative models";
## --decor-models=off falls back to 2D pictures/shaders). decoratives.gd reloads when it changes.
static func set_decor_models_on(on: bool) -> void:
	if on != decor_models_on:
		decor_models_on = on
		decor_version += 1


static func is_decor_model(path: String) -> bool:
	return path.get_extension().to_lower() in DECOR_MODEL_EXTS


## The decorative picture or model files a pack gives for `decor_name`, [] when it has none.
static func decor_in(p: Dictionary, decor_name: String) -> Array:
	if p.is_empty():
		return []
	var decor: Variant = p.get("decoratives")
	if not decor is Dictionary:
		return []
	var found: Variant = (decor as Dictionary).get(decor_name.to_lower())
	return (found as Array).duplicate() if found is Array else []


static func decor_images_in(p: Dictionary, decor_name: String) -> Array:
	var out: Array = []
	for f: Variant in decor_in(p, decor_name):
		var s := str(f)
		if not is_decor_model(s):
			out.append(s)
	return out


static func decor_models_in(p: Dictionary, decor_name: String) -> Array:
	var out: Array = []
	for f: Variant in decor_in(p, decor_name):
		var s := str(f)
		if is_decor_model(s):
			out.append(s)
	return out


## Per-decorative overrides from pack.json's "decoratives" section (`scale`, `size`, `shift`,
## `layer`, `grass`, `grass_height`, `grass_style`, `hide`), matching `*` wildcards then exact name.
static func decor_spec(p: Dictionary, decor_name: String) -> Dictionary:
	if p.is_empty():
		return {}
	return _match_spec((p.get("info", {}) as Dictionary).get("decoratives"), decor_name)


## Whether pack `p` replaces or hides `decor_name`.
static func decor_has(p: Dictionary, decor_name: String) -> bool:
	if p.is_empty():
		return false
	if not decor_in(p, decor_name).is_empty():
		return true
	return bool(decor_spec(p, decor_name).get("hide", false))


static func _decor_usable_in(p: Dictionary, decor_name: String) -> bool:
	if p.is_empty():
		return false
	if not decor_images_in(p, decor_name).is_empty():
		return true
	if decor_models_on and not decor_models_in(p, decor_name).is_empty():
		return true
	return bool(decor_spec(p, decor_name).get("hide", false))


## The decorative source a pack gives for `decor_name`: {"files", "models", "pack", "spec"}, or {} for
## Factorio's/mod's own. Follows the pack order and "decor:<name>" choices. Safe on a worker.
static func decor_source(decor_name: String, past_factorio := false) -> Dictionary:
	if not decor_on:
		return {}
	var key := decor_name.to_lower()
	var c := choices
	if not c.is_empty():
		var id := str(c.get(DECOR_PREFIX + key, ""))
		if id != "":
			if canonical_id(id) == FACTORIO_ID and not pack(id).is_empty():
				return {}
			var chosen_p := pack(id)
			if _decor_usable_in(chosen_p, key):
				return {"files": decor_images_in(chosen_p, key), "models": decor_models_in(chosen_p, key) if decor_models_on else [],
					"pack": chosen_p, "spec": decor_spec(chosen_p, key)}
	var act := active()
	for replacing in [true, false]:
		for p: Dictionary in act:
			if bool(p["replaces"]) == replacing:
				if p["id"] == FACTORIO_ID:
					if not past_factorio and factorio_usable():
						return {}
					continue
				if _decor_usable_in(p, key):
					return {"files": decor_images_in(p, key), "models": decor_models_in(p, key) if decor_models_on else [],
						"pack": p, "spec": decor_spec(p, key)}
	return {}


## The files a pack gives for `decor_name`, [] for none.
static func decor_files(decor_name: String, past_factorio := false) -> Array:
	var src := decor_source(decor_name, past_factorio)
	var files: Variant = src.get("files")
	return files if files is Array else []


## The pack in use whose decorative decor_source() gives, {} for none.
static func decor_pack(decor_name: String, past_factorio := false) -> Dictionary:
	var src := decor_source(decor_name, past_factorio)
	var p: Variant = src.get("pack")
	return p if p is Dictionary else {}


## A pack's decoratives, sorted ("green-hairy-grass", "small-rock"...), including explicit hidden ones.
static func decor_names(p: Dictionary) -> Array:
	var seen := {}
	var decor: Variant = p.get("decoratives")
	if decor is Dictionary:
		for k in (decor as Dictionary):
			seen[k] = true
	for k: String in _explicit_hidden_decor_names(p):
		seen[k] = true
	var names: Array = seen.keys()
	names.sort()
	return names


## The pack chosen for decorative `decor_name`, "" for the order's; only a pack in use counts.
static func decor_choice(decor_name: String) -> String:
	var id := str(choices.get(DECOR_PREFIX + decor_name.to_lower(), ""))
	return id if id != "" and not pack(id).is_empty() else ""


## Whether any active pack provides usable decoratives or decorative hide overrides when decor_on is true.
static func has_any_decoratives() -> bool:
	if not decor_on:
		return false
	for p: Dictionary in active():
		if _has_decor_hide(p.get("info", {})):
			return true
		var decor: Variant = p.get("decoratives")
		if decor is Dictionary:
			if decor_models_on and not (decor as Dictionary).is_empty():
				return true
			for files: Variant in (decor as Dictionary).values():
				if files is Array:
					for f: Variant in (files as Array):
						if not is_decor_model(str(f)):
							return true
	return false


static func _has_decor_hide(info: Variant) -> bool:
	if not info is Dictionary:
		return false
	var cfg: Variant = (info as Dictionary).get("decoratives")
	if not cfg is Dictionary:
		return false
	for v: Variant in (cfg as Dictionary).values():
		if v is Dictionary and bool((v as Dictionary).get("hide", false)):
			return true
	return false


static func _explicit_hidden_decor_names(p: Dictionary) -> Array:
	var out: Array = []
	var cfg: Variant = (p.get("info", {}) as Dictionary).get("decoratives")
	if not cfg is Dictionary:
		return out
	for k: Variant in (cfg as Dictionary):
		var ks := str(k)
		var entry: Variant = (cfg as Dictionary)[k]
		if not ks.contains("*") and entry is Dictionary and bool((entry as Dictionary).get("hide", false)):
			out.append(ks)
	return out


## False when the command line says `<flag>=off` (read once, at load).
static func arg_on(flag: String) -> bool:
	return not Switches.has(flag + "=off")


## The file of item `name`'s model (items on belts, the ground, inserter hands): the pack chosen for
## it (item_choice) if it has one, else the highest pack in use that goes by the order, else the
## first that fills in; "" when no pack has one or the Factorio pack comes first (its icon card).
## `variant`: which of its variants (item_source's "variants"; 0 the first, as before: the plain one if
## the pack has it).
static func item_model_path(name: String, variant := 0) -> String:
	var src := item_source(name)
	var list: Array = src.get("variants", [])
	return str(list[variant % list.size()]) if not list.is_empty() else str(src.get("path", ""))


## How many variants item `name`'s model has in the pack that draws it (0 for none).
static func item_variant_count(name: String) -> int:
	return (item_source(name).get("variants", []) as Array).size()


## Item `name`'s model as item_model_path finds it: {path, pack, variants (its variants' files, the
## first `path`)}, {} for none; path "" (and no variants) with the Factorio pack when its icon card wins.
static func item_source(name: String) -> Dictionary:
	var key := name.to_lower()
	var chosen := item_choice(key)
	if chosen != "":
		var p := pack(chosen)
		if p["id"] == FACTORIO_ID and factorio_usable():
			return {"path": "", "pack": p}
		var found := item_files(p, key)
		if not found.is_empty():
			return {"path": found[0], "pack": p, "variants": found}
	for replacing in [true, false]:
		for p: Dictionary in active():
			if bool(p["replaces"]) == replacing:
				if p["id"] == FACTORIO_ID:
					if factorio_usable():
						return {"path": "", "pack": p}  # Factorio above the rest: the item's icon card
					continue
				var found := item_files(p, key)
				if not found.is_empty():
					return {"path": found[0], "pack": p, "variants": found}
	return {}


## The files of item `key`'s variants (variants_in) in pack `p`, [] for none.
static func item_files(p: Dictionary, key: String) -> Array:
	var items: Dictionary = p["items"]
	var out: Array = []
	for name: String in variants_in(items, key):
		out.append(str(items[name]))
	return out


## The pack chosen for item `name` (choices' "item:<name>"), "" for the order's; only a pack in use
## counts.
static func item_choice(name: String) -> String:
	var c := choices
	if c.is_empty():
		return ""
	var id := str(c.get(ITEM_PREFIX + name.to_lower(), ""))
	return id if id != "" and not pack(id).is_empty() else ""


## A pack's item models, sorted by name, an item's variants (variants_in: `sulfur-1`, `sulfur-2`) one
## entry: [{name, path (its first variant's), variants (how many)}, ...].
static func items(p: Dictionary) -> Array:
	var map: Dictionary = p.get("items", {})
	var grouped := {}
	for n: String in map:
		var base := variant_base(n)
		grouped[base if base != "" else n] = true
	var names := grouped.keys()
	names.sort()
	return names.map(func(n: String) -> Dictionary:
		var files := item_files(p, n)
		return {"name": n, "path": files[0] if not files.is_empty() else "", "variants": files.size()})


## Each item the packs in use have a model of -> the pack it is taken from (as item_model_path).
static func items_in_use() -> Dictionary:
	var out := {}
	for p: Dictionary in active():
		for name: String in p.get("items", {}):
			if not out.has(name):
				out[name] = item_source(name)["pack"]
	return out


## False while zips are being unpacked. On the main thread, once they are, takes them in.
static func is_ready() -> bool:
	if not _busy:
		return true
	if not _finished or OS.get_thread_caller_id() != OS.get_main_thread_id():
		return false
	_take_in()
	return true


## Waits for the unpacking: a model asked for straight away, before it is done (and configure()).
## On a worker, until the main thread has taken them in (at most WORKER_WAIT).
static func wait() -> void:
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		if _busy:
			_take_in()
		return
	var until := Time.get_ticks_msec() + WORKER_WAIT
	while _busy and Time.get_ticks_msec() < until:
		OS.delay_msec(2)


## How far the worker is with zip pack `id`: [files unpacked, files in it], [0, 0] before it starts.
static func progress(id: String) -> Array:
	_mutex.lock()
	var out: Array = (_progress.get(id, [0, 0]) as Array).duplicate()
	_mutex.unlock()
	return out


static func _take_in() -> void:
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	_apply()
	_busy = false


## The start-up log's lines: where the models come from, the packs off or being unpacked, and
## (`problems`; configure() warns of them) those left out.
static func summary(problems := false) -> PackedStringArray:
	var lines := PackedStringArray()
	var used := in_use()
	var per := {}  # pack id -> models it gives
	for name: String in used:
		var id := str((used[name] as Dictionary)["id"])
		per[id] = int(per.get(id, 0)) + 1
	var replacing := PackedStringArray()
	var filling := PackedStringArray()
	var count := 0
	for p: Dictionary in active():
		var gives := int(per.get(p["id"], 0))
		if gives == 0:
			continue
		count += 1
		var text := "%s (%s, %d)" % [p.get("short", p["title"]), where(p), gives]  # "FUE5 (built in, 39)", not "FUE5 (Adapted) (built in, 39)"
		if bool(p["replaces"]):
			replacing.append(text)
		else:
			filling.append(text)
	if not used.is_empty():
		var parts := PackedStringArray()
		if not replacing.is_empty():
			parts.append("the higher winning: " + ", ".join(replacing))
		if not filling.is_empty():
			parts.append("filling in entities no other pack has a model for: " + ", ".join(filling))
		var chosen := model_choice_count()
		if chosen > 0:
			parts.append("%d famil%s from a pack chosen for it" % [chosen, "y" if chosen == 1 else "ies"])
		lines.append("[models] %d model(s) from %d pack%s, %s" % [used.size(), count, "" if count == 1 else "s", "; ".join(parts)])
	var items_used := items_in_use()
	if not items_used.is_empty():
		var per_item := {}
		for name: String in items_used:
			var ip: Dictionary = items_used[name]
			var t := str(ip.get("short", ip["title"]))
			per_item[t] = int(per_item.get(t, 0)) + 1
		var bits := PackedStringArray()
		for t: String in per_item:
			bits.append("%s %d" % [t, per_item[t]])
		lines.append("[models] %d item model(s): %s" % [items_used.size(), ", ".join(bits)])
	for p: Dictionary in packs:
		if p["problem"] != "":
			if problems:
				lines.append("[models] %s (%s) left out: %s" % [p["title"], where(p), p["problem"]])
		elif bool(p["unpacking"]):
			lines.append("[models] %s (%s): %d model(s), being unpacked into %s" % [p["title"], where(p), p["count"], p["cache"]])
		elif bool(p["checking"]):
			lines.append("[models] %s (%s): being checked for copies of Factorio's files, used once it is clean" % [p["title"], where(p)])
		elif not bool(p["on"]):
			lines.append("[models] %s (%s) is off (the Model packs window)" % [p["title"], where(p)])
	var act := active()
	for i in act.size():
		if (act[i] as Dictionary)["id"] == FACTORIO_ID and i < act.size() - 1:
			lines.append("[models] Factorio (your install, %d pictures) above %d pack(s): its pictures drawn where it comes first"
				% [_sprites.size(), act.size() - 1 - i])
	for p: Dictionary in act:
		if p["id"] == LAST_ID or p["id"] == FACTORIO_ID:
			continue  # Zenith's own: most of its models are a higher pack's, as they should be
		var covered := PackedStringArray()
		for name: String in p["models"]:
			if str((used[name] as Dictionary)["id"]) != str(p["id"]):
				covered.append(name)
		if not covered.is_empty():
			covered.sort()
			lines.append("[models] %d of %s's models are another pack's: %s%s" % [covered.size(), p.get("short", p["title"]),
				", ".join(covered.slice(0, 8)), ", ..." if covered.size() > 8 else ""])
	return lines


## Where a pack is, for the log and the window: "Zenith.zip", "belts/", "--models", "built in",
## "the folder's top".
static func where(p: Dictionary) -> String:
	match str(p["kind"]):
		"zip":
			return str(p["source"]).get_file()
		"folder":
			return str(p["source"]).get_file() + "/"
		"arg":
			return "--models"
		"builtin":
			return "your Factorio install" if p["id"] == FACTORIO_ID else "built in"
	return "the folder's top"


## Every model the packs give and the pack it comes from, then the packs left out (the debug
## menu's Model packs).
static func report() -> String:
	if packs.is_empty():
		return "No model packs (Zenith didn't look for them)"
	var lines := PackedStringArray(Array(summary(true)).map(func(l: String) -> String: return l.trim_prefix("[models] ")))
	var used := in_use()
	var names := used.keys()
	names.sort()
	for name: String in names:
		lines.append("%s: %s" % [name, (used[name] as Dictionary)["title"]])
	return "\n".join(lines)


static func _pack(id: String, kind: String, title: String, source: String, root: String, models: Dictionary) -> Dictionary:
	return {"id": id, "kind": kind, "title": title, "short": title, "info": {}, "source": source, "root": root, "models": models,
		"count": models.size(), "items": {}, "item_count": 0, "icons": {}, "icon_count": 0, "sounds": {}, "sound_count": 0,
		"tiles": {}, "tile_maps": {}, "tile_count": 0, "decoratives": {}, "decor_count": 0,
		"on": true, "replaces": true, "problem": "", "unpacking": false, "cache": "", "checking": false, "copies": [], "unchecked": false, "check_stamp": ""}


static func _take_models(p: Dictionary, models: Dictionary, items: Variant = null) -> void:
	p["found_models"] = models
	if items is Dictionary:
		p["found_items"] = items
	_apply_aliases(p)


static func _take_icons(p: Dictionary, icons: Dictionary) -> void:
	p["found_icons"] = icons
	_apply_aliases(p)


static func _take_sounds(p: Dictionary, sounds: Dictionary) -> void:
	p["sounds"] = sounds
	p["sound_count"] = sounds.size()


static func _take_tiles(p: Dictionary, tiles: Dictionary, tile_maps: Dictionary = {}) -> void:
	p["found_tiles"] = tiles
	p["found_tile_maps"] = tile_maps
	_apply_aliases(p)


static func _take_decoratives(p: Dictionary, decor: Dictionary) -> void:
	p["found_decoratives"] = decor
	_apply_aliases(p)


static func _take_info(p: Dictionary, info: Dictionary) -> void:
	p["info"] = info
	if info.has("aliases") or info.has("decoratives"):
		_apply_aliases(p)
	if str(info.get("name", "")) != "":
		p["title"] = str(info["name"])
		p["short"] = p["title"]
	if str(info.get("short_name", "")) != "":
		p["short"] = str(info["short_name"])


static func _activate() -> void:
	var act: Array = []
	var names := {}
	for p: Dictionary in packs:
		for name: String in p["models"]:
			names[name] = true
		if bool(p["on"]) and p["problem"] == "" and not bool(p["unpacking"]) and not bool(p["checking"]):
			act.append(p)
	_mutex.lock()
	_active = act
	_names = names
	_mutex.unlock()
	version += 1
	icons_version += 1
	sounds_version += 1
	tiles_version += 1
	decor_version += 1


## The worker's results taken in, on the main thread.
static func _apply() -> void:
	_mutex.lock()
	var results := _results
	_results = []
	_mutex.unlock()
	for r: Dictionary in results:
		for p: Dictionary in packs:
			if p["id"] != r["id"]:
				continue
			if r.has("models"):
				p["unpacking"] = false
			if r.has("copies"):
				p["checking"] = false
				if r["problem"] == "":
					PackCheck.remember(str(p["id"]), str(r["check"]), str(r["install_stamp"]), r["copies"])
					_take_copies(p, r["copies"])
					if refused(p):
						push_warning(refusal_line(p))
						continue
			if not r.has("models"):
				continue  # a folder's check alone
			p["problem"] = r["problem"]
			if r["problem"] == "":
				_take_models(p, r["models"], r["items"])
				_take_icons(p, r["icons"])
				_take_sounds(p, r["sounds"])
				_take_tiles(p, r["tiles"], r.get("tile_maps", {}))
				_take_decoratives(p, r.get("decoratives", {}))
				var with_items := ", %d item model(s)" % p["item_count"] if int(p["item_count"]) > 0 else ""
				var with_sounds := ", %d sound(s)" % p["sound_count"] if int(p["sound_count"]) > 0 else ""
				var with_tiles := ", %d tile(s)" % p["tile_count"] if int(p["tile_count"]) > 0 else ""
				var with_decor := ", %d decorative(s)" % p["decor_count"] if int(p["decor_count"]) > 0 else ""
				print("[models] %s (%s) unpacked: %d model(s)%s, %d icon(s)%s%s%s in %.1f s" % [p["title"], where(p), p["count"], with_items,
					p["icon_count"], with_sounds, with_tiles, with_decor, float(r["msec"]) / 1000.0])
			else:
				push_warning("[models] %s (%s) left out: %s" % [p["title"], where(p), r["problem"]])
	_activate()


## On a worker: removes the copies of zips changed or gone, then unpacks and indexes each zip.
static func _unpack_all(jobs: Array, stale: Array) -> void:
	for dir: String in stale:
		SafeDelete.remove_tree(dir)
		if FileAccess.file_exists(dir + USED_SUFFIX):
			DirAccess.remove_absolute(dir + USED_SUFFIX)
	var results: Array = []
	for job: Dictionary in jobs:
		if not job.has("zip"):
			var copies := PackCheck.find_copies(job["files"], str(job["install"]))
			results.append({"id": job["id"], "problem": "", "copies": copies, "check": job["check"], "install_stamp": job["install_stamp"]})
			continue
		var t0 := Time.get_ticks_msec()
		var why := unzip(str(job["zip"]), str(job["cache"]), str(job["id"]))
		var models := {}
		var items := {}
		var icons := {}
		var sounds := {}
		var tiles := {}
		var tile_maps := {}
		var decor := {}
		if why == "":
			models = _index(str(job["cache"]), MAX_DEPTH, items)
			icons = _index_icons(str(job["cache"]), 1)
			sounds = _index_sounds(str(job["cache"]), 1)
			tiles = _index_tiles(str(job["cache"]), 1, tile_maps)
			decor = _index_decoratives(str(job["cache"]), 1)
			if models.is_empty() and items.is_empty() and icons.is_empty() and sounds.is_empty() \
					and tiles.is_empty() and tile_maps.is_empty() and decor.is_empty():
				var raw_info := _read_info(str(job["cache"]), 1)
				if not _has_decor_hide(raw_info):
					why = NOTHING_IN_IT
		var r := {"id": job["id"], "problem": why, "models": models, "items": items, "icons": icons, "sounds": sounds,
			"tiles": tiles, "tile_maps": tile_maps, "decoratives": decor, "msec": Time.get_ticks_msec() - t0}
		if str(job.get("check", "")) != "":
			r["copies"] = PackCheck.find_copies(PackCheck.pack_files(str(job["cache"])), str(job["install"])) if why == "" else []
			r["check"] = job["check"]
			r["install_stamp"] = job["install_stamp"]
		results.append(r)
	_mutex.lock()
	_results = results
	_progress = {}
	_finished = true
	_mutex.unlock()


## Unpacks a zip into `dest` (through a folder of its own first, renamed when whole, so a Zenith
## stopped half way leaves no half copy). "" when done, else why not. `id`: the pack whose
## progress() it counts.
static func unzip(zip: String, dest: String, id := "") -> String:
	var entries := ModFiles.zip_entries(zip)
	if entries.is_empty():
		return "it can't be read as a zip"
	var done := 0
	var of := 0
	for name: String in entries:
		if not name.ends_with("/"):
			of += 1
	var part := "%s.part-%d" % [dest, OS.get_process_id()]
	SafeDelete.remove_tree(part)
	DirAccess.make_dir_recursive_absolute(part)
	var f := FileAccess.open(zip, FileAccess.READ)
	if f == null:
		return "it can't be opened"
	var why := ""
	for name: String in entries:
		var rel := safe_entry(name)
		if rel == "":
			continue
		var target := part.path_join(rel)
		if rel.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(target)
			continue
		var entry: PackedInt64Array = entries[name]
		var bytes := ModFiles.zip_entry(f, entry)
		if bytes.size() != entry[3]:
			why = "%s in it can't be read (damaged, or packed in a way Zenith doesn't read: use plain zip)" % rel
			break
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var out := FileAccess.open(target, FileAccess.WRITE)
		if out == null:
			why = "it can't be unpacked to %s" % part
			break
		out.store_buffer(bytes)
		out.close()
		done += 1
		if id != "":
			_mutex.lock()
			_progress[id] = [done, of]
			_mutex.unlock()
	f.close()
	if why != "":
		SafeDelete.remove_tree(part)
		return why
	if DirAccess.dir_exists_absolute(dest):
		SafeDelete.remove_tree(part)  # another Zenith unpacked it meanwhile
		return ""
	if DirAccess.rename_absolute(part, dest) != OK:
		SafeDelete.remove_tree(part)
		return "it can't be unpacked to %s" % dest
	return ""


## A zip entry's path inside its pack, or "" to leave it out: absolute paths, drive letters and
## ".." (which would write outside the pack's copy), and macOS' __MACOSX folder.
static func safe_entry(name: String) -> String:
	var rel := name.replace("\\", "/")
	if rel.begins_with("/") or rel.contains(":") or rel.begins_with("__MACOSX/"):
		return ""
	for piece in rel.split("/"):
		if piece == "..":
			return ""
	return rel


## The unpacked copies to remove: every folder in the cache but those of the zips found
## (`keep`, by folder name) and another Zenith's unpacking now; with pack_cache_keep days, a copy
## of a zip not in this folder only once unused that long (last_used); a copy of a zip of this folder
## (`here`, by zip name) not kept, changed since or refused (it may hold Factorio's files), at once.
## Stamps left without their copy go too.
static func _stale_copies(keep: Dictionary, here := {}) -> Array:
	var root := ProjectSettings.globalize_path(cache_root)
	var out: Array = []
	if not DirAccess.dir_exists_absolute(root):
		return out
	var now := int(Time.get_unix_time_from_system())
	var old := now - PART_AGE
	var kept_zips := here.duplicate()
	for d: String in keep:
		kept_zips[_copy_zip_name(d)] = true
	var dirs := DirAccess.get_directories_at(root)
	for d in dirs:
		if keep.has(d):
			continue
		if d.contains(".part-"):
			if FileAccess.get_modified_time(root.path_join(d)) > old:
				continue
		elif pack_cache_keep > 0 and not kept_zips.has(_copy_zip_name(d)) \
				and last_used(root.path_join(d)) > now - pack_cache_keep * 86400:
			continue
		out.append(root.path_join(d))
	for f in DirAccess.get_files_at(root):
		if f.ends_with(USED_SUFFIX) and not dirs.has(f.trim_suffix(USED_SUFFIX)):
			DirAccess.remove_absolute(root.path_join(f))
	return out


## The zip's name part of a copy's folder name ("<zip name>-<size>-<modified>").
static func _copy_zip_name(d: String) -> String:
	var parts := d.rsplit("-", true, 2)
	return parts[0] if parts.size() == 3 and parts[1].is_valid_int() and parts[2].is_valid_int() else d


## When an unpacked copy (its folder) was last used: the time in its stamp (Unix seconds), else the
## folder's own modified time.
static func last_used(copy: String) -> int:
	var stamp := FileAccess.get_file_as_string(copy + USED_SUFFIX).strip_edges() if FileAccess.file_exists(copy + USED_SUFFIX) else ""
	if stamp.is_valid_int():
		return stamp.to_int()
	return int(FileAccess.get_modified_time(copy))


## Marks the copy `name` (a folder in the cache, perhaps not unpacked yet) used now.
static func _touch_used(name: String) -> void:
	var root := ProjectSettings.globalize_path(cache_root)
	if not DirAccess.dir_exists_absolute(root):
		DirAccess.make_dir_recursive_absolute(root)
	var f := FileAccess.open(root.path_join(name + USED_SUFFIX), FileAccess.WRITE)
	if f != null:
		f.store_string(str(int(Time.get_unix_time_from_system())))
		f.close()


static func _keep_days() -> int:
	for a: String in Switches.args():
		if a.begins_with("--pack-cache-keep="):
			return maxi(0, a.trim_prefix("--pack-cache-keep=").to_int())
	return PACK_CACHE_KEEP_DAYS


## A folder's models (`depth` folders down at most): name -> file, the one nearest the top first,
## then .glb over .gltf. Folders called `items` hold item models, not entities': left out, or with
## `items` (a Dictionary) put there the same way.
static func _index(root: String, depth: int, items: Variant = null) -> Dictionary:
	var found := {}  # name -> [depth, extension's rank, file]
	var item_found := {}
	_walk(root, 0, depth, found, item_found)
	if items is Dictionary:
		(items as Dictionary).merge(_ranked(item_found), true)
	return _ranked(found)


static func _ranked(found: Dictionary) -> Dictionary:
	var out := {}
	for name: String in found:
		out[name] = (found[name] as Array)[2]
	return out


## `items`: where models in a folder called `items` go (null: inside one already, they are its).
static func _walk(dir: String, d: int, depth: int, found: Dictionary, items: Variant) -> void:
	for f in DirAccess.get_files_at(dir):
		if dir.begins_with("res://") and (f.ends_with(".import") or f.ends_with(".remap")):
			f = f.get_basename()  # a built-in model exported as its imported scene alone
		var rank := MODEL_EXTS.find(f.get_extension().to_lower())
		if rank < 0:
			continue
		var name := f.get_basename().to_lower()
		var here := [d, rank, dir.path_join(f)]
		var have: Array = found.get(name, [])
		if have.is_empty() or _nearer(here, have):
			found[name] = here
	if d >= depth:
		return
	for sub in DirAccess.get_directories_at(dir):
		if sub.begins_with(".") or sub == "__MACOSX":
			continue
		if items is Dictionary and d <= 1 and sub.to_lower() == DECOR_DIR:
			continue  # decoratives/*.glb are indexed separately by _index_decoratives()
		if items is Dictionary and sub.to_lower() == ITEMS_DIR:
			_walk(dir.path_join(sub), d + 1, depth, items, null)
		else:
			_walk(dir.path_join(sub), d + 1, depth, found, items)


## A pack's icons, from its `icons/` folder at `root` or (`depth` 1) one folder down, the top's
## first: "<name>" -> file for icons/<name>.png, "<kind>/<name>" -> file for icons/<kind>/<name>.png.
static func _index_icons(root: String, depth: int) -> Dictionary:
	var dir := _icons_dir(root)
	if dir == "" and depth > 0 and DirAccess.dir_exists_absolute(root):
		var subs := Array(DirAccess.get_directories_at(root))
		subs.sort()
		for sub: String in subs:
			if sub.begins_with(".") or sub == "__MACOSX":
				continue
			dir = _icons_dir(root.path_join(sub))
			if dir != "":
				break
	var out := {}
	if dir == "":
		return out
	for f: String in _icon_files(dir):
		out[f.get_basename().to_lower()] = dir.path_join(f)
	for sub: String in DirAccess.get_directories_at(dir):
		var kind := sub.to_lower()
		kind = str(ICON_KIND_ALIASES.get(kind, kind))
		for f: String in _icon_files(dir.path_join(sub)):
			out[kind + "/" + f.get_basename().to_lower()] = dir.path_join(sub).path_join(f)
	return out


## `root`'s icons/ folder (any case), "" without one.
static func _icons_dir(root: String) -> String:
	if not DirAccess.dir_exists_absolute(root):
		return ""
	for sub in DirAccess.get_directories_at(root):
		if sub.to_lower() == ICONS_DIR:
			return root.path_join(sub)
	return ""


## The icon pictures in a folder (built-in ones also by their .import, in an exported game).
static func _icon_files(dir: String) -> Array:
	var out := {}
	for f in DirAccess.get_files_at(dir):
		if dir.begins_with("res://") and (f.ends_with(".import") or f.ends_with(".remap")):
			f = f.get_basename()
		if f.get_extension().to_lower() in ICON_EXTS:
			out[f] = true
	return out.keys()


## Whether a zip entry is an icon's: under icons/ at its top or one folder down.
static func _in_icons_dir(rel: String) -> bool:
	var parts := rel.split("/")
	for i in mini(2, parts.size() - 1):
		if parts[i].to_lower() == ICONS_DIR:
			return parts.size() - i <= 3  # icons/<name>.png or icons/<kind>/<name>.png
	return false


## A pack's sounds, from its `sounds/` folder at `root` or (`depth` 1) one folder down, the top's
## first: Factorio's path, lower case ("core/sound/gui-click.ogg") -> file.
# A pack with a copy of the install's own file is refused whole (pack_check.gd), not one file skipped.
static func _index_sounds(root: String, depth: int) -> Dictionary:
	var dir := _sounds_dir(root)
	if dir == "" and depth > 0 and DirAccess.dir_exists_absolute(root):
		var subs := Array(DirAccess.get_directories_at(root))
		subs.sort()
		for sub: String in subs:
			if sub.begins_with(".") or sub == "__MACOSX":
				continue
			dir = _sounds_dir(root.path_join(sub))
			if dir != "":
				break
	var out := {}
	if dir != "":
		_walk_sounds(dir, "", 0, out)
	return out


static func _walk_sounds(dir: String, rel: String, d: int, out: Dictionary) -> void:
	for f in DirAccess.get_files_at(dir):
		if d > 0 and f.get_extension().to_lower() in SOUND_EXTS:  # at sounds/'s top: no Factorio path (<mod>/...)
			out[(rel + f).to_lower()] = dir.path_join(f)
	if d >= SOUND_DEPTH:
		return
	for sub in DirAccess.get_directories_at(dir):
		if not sub.begins_with(".") and sub != "__MACOSX":
			_walk_sounds(dir.path_join(sub), rel + sub + "/", d + 1, out)


## `root`'s sounds/ folder (any case), "" without one.
static func _sounds_dir(root: String) -> String:
	if not DirAccess.dir_exists_absolute(root):
		return ""
	for sub in DirAccess.get_directories_at(root):
		if sub.to_lower() == SOUNDS_DIR:
			return root.path_join(sub)
	return ""


## Whether a zip entry is a sound's: under sounds/ at its top or one folder down, with a Factorio
## path under it (<mod>/<file> at least).
static func _in_sounds_dir(rel: String) -> bool:
	var parts := rel.split("/")
	for i in mini(2, parts.size() - 1):
		if parts[i].to_lower() == SOUNDS_DIR:
			return parts.size() - i >= 3
	return false


static func _is_digits(s: String) -> bool:
	if s.is_empty():
		return false
	for i in s.length():
		var c := s.unicode_at(i)
		if c < 48 or c > 57:
			return false
	return true


static func _split_tile_map(stem: String) -> Array:
	for pair: Array in [
		["-normal", "normal"], ["_normal", "normal"],
		["-height", "height"], ["_height", "height"],
		["-bump", "height"], ["_bump", "height"],
		["-roughness", "roughness"], ["_roughness", "roughness"],
	]:
		var suffix := str(pair[0])
		if stem.ends_with(suffix) and stem.length() > suffix.length():
			return [stem.substr(0, stem.length() - suffix.length()), str(pair[1])]
	return [stem, ""]


## A pack's ground tiles, from its `tiles/` folder at `root` or (`depth` 1) one folder down,
## the top's first: `<tile-name>` -> sorted Array of picture file paths. If `tile_maps` is a
## Dictionary, companion PBR maps (`-normal`, `-height`/`-bump`, `-roughness`) go there as
## `<tile-name>` -> {kind -> sorted Array of file paths}.
static func _index_tiles(root: String, depth: int, tile_maps: Variant = null) -> Dictionary:
	var dir := _tiles_dir(root)
	if dir == "" and depth > 0 and DirAccess.dir_exists_absolute(root):
		var subs := Array(DirAccess.get_directories_at(root))
		subs.sort()
		for sub: String in subs:
			if sub.begins_with(".") or sub == "__MACOSX":
				continue
			dir = _tiles_dir(root.path_join(sub))
			if dir != "":
				break
	if dir == "":
		return {}
	var singles := {}      # tile_name -> [depth, ext_rank, path]
	var groups := {}       # tile_name -> [depth, dir_path, {stem -> [ext_rank, path]}]
	var map_singles := {}  # kind -> {tile_name -> [depth, ext_rank, path]}
	var map_groups := {}   # kind -> {tile_name -> [depth, dir_path, {stem -> [ext_rank, path]}]}
	_walk_tiles(dir, "", 0, singles, groups, map_singles, map_groups)
	var out := {}
	var sort_variants := func(a: Array, b: Array) -> bool:
		var sa := str(a[0])
		var sb := str(b[0])
		var ia := int(sa)
		var ib := int(sb)
		if ia != ib:
			return ia < ib
		if sa.length() != sb.length():
			return sa.length() < sb.length()
		return sa < sb
	var collect_kind := func(s_dict: Dictionary, g_dict: Dictionary) -> Dictionary:
		var res := {}
		var all_names := {}
		for k in s_dict:
			all_names[k] = true
		for k in g_dict:
			all_names[k] = true
		for tname: String in all_names:
			var has_s := s_dict.has(tname)
			var has_g := g_dict.has(tname)
			var use_group := has_g and (not has_s or int((g_dict[tname] as Array)[0]) <= int((s_dict[tname] as Array)[0]))
			if use_group:
				var files_map: Dictionary = (g_dict[tname] as Array)[2]
				var items: Array = []
				for stem: String in files_map:
					items.append([stem, str((files_map[stem] as Array)[1])])
				items.sort_custom(sort_variants)
				var paths: Array = []
				for it: Array in items:
					paths.append(it[1])
				res[tname] = paths
			elif has_s:
				res[tname] = [str((s_dict[tname] as Array)[2])]
		return res
	out = collect_kind.call(singles, groups)
	if tile_maps is Dictionary:
		var maps_out := tile_maps as Dictionary
		for kind: String in ["normal", "height", "roughness"]:
			var ms: Dictionary = map_singles.get(kind, {})
			var mg: Dictionary = map_groups.get(kind, {})
			if ms.is_empty() and mg.is_empty():
				continue
			var per_kind: Dictionary = collect_kind.call(ms, mg)
			for tname: String in per_kind:
				if not maps_out.has(tname):
					maps_out[tname] = {}
				(maps_out[tname] as Dictionary)[kind] = per_kind[tname]
	return out


static func _put_tile_group(g_dict: Dictionary, tname: String, d: int, dir: String, vkey: String, rank: int, full: String) -> void:
	if not g_dict.has(tname):
		g_dict[tname] = [d, dir, {}]
	var grp: Array = g_dict[tname]
	if d < int(grp[0]) or (d == int(grp[0]) and dir.naturalnocasecmp_to(str(grp[1])) < 0):
		grp[0] = d
		grp[1] = dir
		grp[2] = {}
	if str(grp[1]) == dir:
		var fmap: Dictionary = grp[2]
		var cur: Variant = fmap.get(vkey)
		if cur == null or rank < int((cur as Array)[0]):
			fmap[vkey] = [rank, full]


static func _walk_tiles(dir: String, parent_name: String, d: int, singles: Dictionary, groups: Dictionary,
		map_singles: Dictionary, map_groups: Dictionary) -> void:
	var seen := {}
	for f in DirAccess.get_files_at(dir):
		if dir.begins_with("res://") and (f.ends_with(".import") or f.ends_with(".remap")):
			f = f.get_basename()
		seen[f] = true
	for f: String in seen:
		var rank := TILE_EXTS.find(f.get_extension().to_lower())
		if rank < 0:
			continue
		var stem := f.get_basename().to_lower()
		var full := dir.path_join(f)
		if d >= 1 and parent_name != "" and stem in ["normal", "height", "bump", "roughness"]:
			var kind := "height" if stem == "bump" else stem
			if not map_singles.has(kind):
				map_singles[kind] = {}
			var ks: Dictionary = map_singles[kind]
			var here := [d, rank, full]
			var have: Array = ks.get(parent_name, [])
			if have.is_empty() or _nearer(here, have):
				ks[parent_name] = here
			continue
		var sp := _split_tile_map(stem)
		var base := str(sp[0])
		var kind := str(sp[1])
		if kind != "":
			if d >= 1 and parent_name != "" and _is_digits(base):
				if not map_groups.has(kind):
					map_groups[kind] = {}
				_put_tile_group(map_groups[kind], parent_name, d, dir, base, rank, full)
			else:
				if not map_singles.has(kind):
					map_singles[kind] = {}
				var ks: Dictionary = map_singles[kind]
				var here := [d, rank, full]
				var have: Array = ks.get(base, [])
				if have.is_empty() or _nearer(here, have):
					ks[base] = here
		elif d >= 1 and parent_name != "" and _is_digits(stem):
			_put_tile_group(groups, parent_name, d, dir, stem, rank, full)
		else:
			var here := [d, rank, full]
			var have: Array = singles.get(stem, [])
			if have.is_empty() or _nearer(here, have):
				singles[stem] = here
	if d >= TILE_DEPTH:
		return
	var subs := Array(DirAccess.get_directories_at(dir))
	subs.sort_custom(func(a: String, b: String) -> bool: return a.naturalnocasecmp_to(b) < 0)
	for sub: String in subs:
		if not sub.begins_with(".") and sub != "__MACOSX":
			_walk_tiles(dir.path_join(sub), sub.to_lower(), d + 1, singles, groups, map_singles, map_groups)


## `root`'s tiles/ folder (any case), "" without one.
static func _tiles_dir(root: String) -> String:
	if not DirAccess.dir_exists_absolute(root):
		return ""
	for sub in DirAccess.get_directories_at(root):
		if sub.to_lower() == TILES_DIR:
			return root.path_join(sub)
	return ""


## Whether a zip entry is a ground tile's: under tiles/ at its top or one folder down, up to TILE_DEPTH.
static func _in_tiles_dir(rel: String) -> bool:
	return _zip_tile_name(rel) != ""


## Logical tile name for a zip entry inside tiles/, "" if outside tiles/ or too deep/hidden.
static func _zip_tile_name(rel: String) -> String:
	var parts := rel.split("/")
	for i in mini(2, parts.size() - 1):
		if parts[i].to_lower() == TILES_DIR:
			var d := parts.size() - i - 2
			if d < 0 or d > TILE_DEPTH:
				return ""
			for j in range(i + 1, parts.size() - 1):
				if parts[j].begins_with(".") or parts[j] == "__MACOSX":
					return ""
			var stem := rel.get_file().get_basename().to_lower()
			if d >= 1 and stem in ["normal", "height", "bump", "roughness"]:
				return parts[parts.size() - 2].to_lower()
			var sp := _split_tile_map(stem)
			var base := str(sp[0])
			var kind := str(sp[1])
			if kind != "":
				if d >= 1 and _is_digits(base):
					return parts[parts.size() - 2].to_lower()
				return base
			if d >= 1 and _is_digits(stem):
				return parts[parts.size() - 2].to_lower()
			return stem
	return ""


static func _decor_variant_key(stem: String) -> Array:
	var at := stem.rfind("-")
	if at > 0 and _is_digits(stem.substr(at + 1)):
		return [stem.substr(0, at), stem.substr(at + 1)]
	return [stem, ""]


## A pack's decoratives and grass, from its `decoratives/` folder at `root` or (`depth` 1) one
## folder down, the top's first: `<decor-name>` -> sorted Array of picture file paths.
static func _index_decoratives(root: String, depth: int) -> Dictionary:
	var dir := _decor_dir(root)
	if dir == "" and depth > 0 and DirAccess.dir_exists_absolute(root):
		var subs := Array(DirAccess.get_directories_at(root))
		subs.sort()
		for sub: String in subs:
			if sub.begins_with(".") or sub == "__MACOSX":
				continue
			dir = _decor_dir(root.path_join(sub))
			if dir != "":
				break
	if dir == "":
		return {}
	var groups := {}  # decor_name -> {"0:" + vkey -> image, "1:" + vkey -> model}
	_walk_decoratives(dir, "", 0, groups)
	var out := {}
	var sort_variants := func(a: Array, b: Array) -> bool:
		var sa := str(a[0])
		var sb := str(b[0])
		var ka := sa.substr(2) if sa.length() >= 2 else sa
		var kb := sb.substr(2) if sb.length() >= 2 else sb
		var ma := sa.left(2)
		var mb := sb.left(2)
		if ma != mb:
			return ma > mb  # models ("1:") listed first, then images ("0:")
		if ka == "" or kb == "":
			return ka < kb
		var ia := int(ka)
		var ib := int(kb)
		if ia != ib:
			return ia < ib
		if ka.length() != kb.length():
			return ka.length() < kb.length()
		return ka < kb
	for dname: String in groups:
		var vmap: Dictionary = groups[dname]
		var items: Array = []
		for vkey: String in vmap:
			items.append([vkey, str((vmap[vkey] as Array)[2])])
		items.sort_custom(sort_variants)
		var paths: Array = []
		for it: Array in items:
			paths.append(it[1])
		out[dname] = paths
	return out


static func _walk_decoratives(dir: String, parent_name: String, d: int, groups: Dictionary) -> void:
	var seen := {}
	for f in DirAccess.get_files_at(dir):
		if dir.begins_with("res://") and (f.ends_with(".import") or f.ends_with(".remap")):
			f = f.get_basename()
		seen[f] = true
	for f: String in seen:
		var rank := DECOR_EXTS.find(f.get_extension().to_lower())
		if rank < 0:
			continue
		var stem := f.get_basename().to_lower()
		var full := dir.path_join(f)
		var dname := ""
		var vkey := ""
		if d >= 1 and parent_name != "" and _is_digits(stem):
			dname = parent_name
			vkey = stem
		else:
			var sp := _decor_variant_key(stem)
			dname = str(sp[0])
			vkey = str(sp[1])
		if dname == "":
			continue
		var key_prefix := "1:" if is_decor_model(full) else "0:"
		var vslot := key_prefix + vkey
		if not groups.has(dname):
			groups[dname] = {}
		var vmap: Dictionary = groups[dname]
		var here := [d, rank, full]
		var have: Array = vmap.get(vslot, [])
		if have.is_empty() or _nearer(here, have):
			vmap[vslot] = here
	if d >= DECOR_DEPTH:
		return
	var subs := Array(DirAccess.get_directories_at(dir))
	subs.sort_custom(func(a: String, b: String) -> bool: return a.naturalnocasecmp_to(b) < 0)
	for sub: String in subs:
		if not sub.begins_with(".") and sub != "__MACOSX":
			_walk_decoratives(dir.path_join(sub), sub.to_lower(), d + 1, groups)


static func _decor_dir(root: String) -> String:
	if not DirAccess.dir_exists_absolute(root):
		return ""
	for sub in DirAccess.get_directories_at(root):
		if sub.to_lower() == DECOR_DIR:
			return root.path_join(sub)
	return ""


static func _in_decor_dir(rel: String) -> bool:
	return _zip_decor_name(rel) != ""


static func _zip_decor_name(rel: String) -> String:
	var parts := rel.split("/")
	for i in mini(2, parts.size() - 1):
		if parts[i].to_lower() == DECOR_DIR:
			var d := parts.size() - i - 2
			if d < 0 or d > DECOR_DEPTH:
				return ""
			for j in range(i + 1, parts.size() - 1):
				if parts[j].begins_with(".") or parts[j] == "__MACOSX":
					return ""
			var stem := rel.get_file().get_basename().to_lower()
			if d >= 1 and _is_digits(stem):
				return parts[parts.size() - 2].to_lower()
			return str(_decor_variant_key(stem)[0])
	return ""


static func _nearer(a: Array, b: Array) -> bool:
	if int(a[0]) != int(b[0]):
		return int(a[0]) < int(b[0])
	if int(a[1]) != int(b[1]):
		return int(a[1]) < int(b[1])
	return str(a[2]).naturalnocasecmp_to(str(b[2])) < 0


## A pack's pack.json, at its top or (`depth` 1) one folder down, as {name, version, author,
## licence, description}; {} without one.
static func _read_info(root: String, depth: int) -> Dictionary:
	if FileAccess.file_exists(root.path_join(INFO_FILE)):
		return _parse_info(FileAccess.get_file_as_string(root.path_join(INFO_FILE)))
	if depth > 0 and DirAccess.dir_exists_absolute(root):
		var subs := Array(DirAccess.get_directories_at(root))
		subs.sort()
		for sub: String in subs:
			if FileAccess.file_exists(root.path_join(sub).path_join(INFO_FILE)):
				return _parse_info(FileAccess.get_file_as_string(root.path_join(sub).path_join(INFO_FILE)))
	return {}


static func _parse_info(text: String) -> Dictionary:
	var json := JSON.new()  # an instance: a broken pack.json is left out quietly, not an engine error
	if text == "" or json.parse(text) != OK or not json.data is Dictionary:
		return {}
	var data: Dictionary = json.data
	var out := {}
	# "icon": the model shown for the pack in the Model packs window (else pack.png, else its first);
	# "credit": the one line over the Model packs window's preview ("© Vasillo · used with permission"), as it is;
	# "icon_image": a picture shown instead, a file in the pack or "factorio:<path in the install>".
	for key in ["name", "short_name", "version", "author", "description", "icon", "icon_image", "credit"]:
		if data.has(key) and data[key] != null:
			out[key] = str(data[key])
	# "ore_scatter": false, a pack's numbered ore models left alone (model_library.gd ore_rocks).
	if data.get("ore_scatter") is bool:
		out["ore_scatter"] = data["ore_scatter"]
	# "shading": "pbr", the pack's textured materials drawn as their files say; "factorio" (or none), with
	# Zenith's Factorio-style balance (shading()).
	if data.get("shading") is String:
		out["shading"] = str(data["shading"]).strip_edges().to_lower()
	# "shading_models": {"<prototype name, * allowed>": "pbr" | "factorio"}, per model over "shading" (model_shading()).
	if data.get("shading_models") is Dictionary:
		var per := {}
		for k: Variant in (data["shading_models"] as Dictionary):
			var v := str((data["shading_models"] as Dictionary)[k]).strip_edges().to_lower()
			if v == "pbr" or v == "factorio":
				per[str(k).strip_edges().to_lower()] = v
		if not per.is_empty():
			out["shading_models"] = per
	# "belt_lane_offset", "belt_item_height" (tiles): where the pack's belt carries its items (belt_lane_inset.gd).
	# (Left out of this list before, the keys never reached the client: lanes stayed at Factorio's 0.234.)
	for key in ["belt_lane_offset", "belt_item_height"]:
		if data.get(key) is float or data.get(key) is int:
			out[key] = float(data[key])
	# "aliases": {"coal-ore": "coal"}, the pack's names for Factorio's (alias_name): its coal-ore-1.glb is coal-1.
	if data.get("aliases") is Dictionary:
		var aliases := {}
		for from in (data["aliases"] as Dictionary):
			var to: Variant = data["aliases"][from]
			if to is String and str(from).strip_edges() != "" and str(to).strip_edges() != "":
				aliases[str(from).strip_edges().to_lower()] = str(to).strip_edges().to_lower()
		if not aliases.is_empty():
			out["aliases"] = aliases
	# "tiles": {"<tile pattern, * allowed>": {"size": 2 | [w, h], "count": n, "roughness": r, "specular": s}}
	if data.get("tiles") is Dictionary:
		var tiles_cfg := {}
		for k: Variant in (data["tiles"] as Dictionary):
			var pat := str(k).strip_edges().to_lower()
			var raw_val: Variant = (data["tiles"] as Dictionary)[k]
			if pat == "" or not (raw_val is Dictionary):
				continue
			var entry := raw_val as Dictionary
			var spec := {}
			var sv: Variant = entry.get("size")
			if sv is int or sv is float:
				var s := int(sv)
				if s >= 1 and s <= 16:
					spec["size"] = [s, s]
			elif sv is Array and (sv as Array).size() >= 2:
				var sa := sv as Array
				if (sa[0] is int or sa[0] is float) and (sa[1] is int or sa[1] is float):
					var w := int(sa[0])
					var h := int(sa[1])
					if w >= 1 and w <= 32 and h >= 1 and h <= 16:
						spec["size"] = [w, h]
			var cv: Variant = entry.get("count")
			if cv is int or cv is float:
				var cnt := int(cv)
				if cnt >= 1 and cnt <= 64:
					spec["count"] = cnt
			var rv: Variant = entry.get("roughness")
			if rv is int or rv is float:
				spec["roughness"] = clampf(float(rv), 0.01, 1.0)
			var spv: Variant = entry.get("specular")
			if spv is int or spv is float:
				spec["specular"] = clampf(float(spv), 0.0, 0.99)
			var nsv: Variant = entry.get("normal_strength")
			if nsv is int or nsv is float:
				spec["normal_strength"] = clampf(float(nsv), 0.0, 4.0)
			var hsv: Variant = entry.get("height_strength")
			if hsv is int or hsv is float:
				spec["height_strength"] = clampf(float(hsv), 0.0, 4.0)
			if entry.get("normal_flip_x") is bool:
				spec["normal_flip_x"] = entry["normal_flip_x"]
			if entry.get("normal_flip_y") is bool:
				spec["normal_flip_y"] = entry["normal_flip_y"]
			if not spec.is_empty():
				tiles_cfg[pat] = spec
		if not tiles_cfg.is_empty():
			out["tiles"] = tiles_cfg
	# "decoratives": {"<decor pattern, * allowed>": {"scale": f, "size": f | [w, h], "shift": [dx, dy],
	#   "layer": str, "grass": bool, "grass_height": f, "grass_style": "auto"|"tuft"|"bush"|"carpet", "hide": bool}}
	if data.get("decoratives") is Dictionary:
		var decor_cfg := {}
		for k: Variant in (data["decoratives"] as Dictionary):
			var pat := str(k).strip_edges().to_lower()
			var raw_val: Variant = (data["decoratives"] as Dictionary)[k]
			if pat == "" or not (raw_val is Dictionary):
				continue
			var entry := raw_val as Dictionary
			var spec := {}
			var scv: Variant = entry.get("scale")
			if scv is int or scv is float:
				spec["scale"] = clampf(float(scv), 0.05, 8.0)
			var dsv: Variant = entry.get("size")
			if dsv is int or dsv is float:
				var s := clampf(float(dsv), 0.05, 32.0)
				spec["size"] = [s, s]
			elif dsv is Array and (dsv as Array).size() >= 2:
				var sa := dsv as Array
				if (sa[0] is int or sa[0] is float) and (sa[1] is int or sa[1] is float):
					spec["size"] = [clampf(float(sa[0]), 0.05, 32.0), clampf(float(sa[1]), 0.05, 32.0)]
			var shv: Variant = entry.get("shift")
			if shv is Array and (shv as Array).size() >= 2:
				var sha := shv as Array
				if (sha[0] is int or sha[0] is float) and (sha[1] is int or sha[1] is float):
					spec["shift"] = [clampf(float(sha[0]), -16.0, 16.0), clampf(float(sha[1]), -16.0, 16.0)]
			if entry.get("layer") is String:
				var lyr := str(entry["layer"]).strip_edges().to_lower()
				if lyr in ["decals", "ground-layer-1", "ground-layer-2", "ground-layer-3",
						"ground-layer-4", "ground-layer-5", "floor", "decorative", "object"]:
					spec["layer"] = lyr
			if entry.get("grass") is bool:
				spec["grass"] = entry["grass"]
			var ghv: Variant = entry.get("grass_height")
			if ghv is int or ghv is float:
				spec["grass_height"] = clampf(float(ghv), 0.05, 2.0)
			if entry.get("grass_style") is String:
				var st := str(entry["grass_style"]).strip_edges().to_lower()
				if st in ["auto", "tuft", "bush", "carpet"]:
					spec["grass_style"] = st
			if entry.get("hide") is bool:
				spec["hide"] = entry["hide"]
			if not spec.is_empty():
				decor_cfg[pat] = spec
		if not decor_cfg.is_empty():
			out["decoratives"] = decor_cfg
	var licence: Variant = data.get("licence", data.get("license"))
	if licence != null:
		out["licence"] = str(licence)
	return out


static func _norm(path: String) -> String:
	return path.replace("\\", "/").trim_suffix("/")
