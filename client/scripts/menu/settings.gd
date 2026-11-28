extends RefCounted
## Every setting of the client, in one file: `user://settings.cfg` (on Windows
## `%APPDATA%\Godot\app_userdata\Zenith\settings.cfg`), changed in the Settings window
## (settings_window.gd). The sections follow Factorio's settings tabs: [graphics], [sound],
## [interface], [map] (minimap and map view), [controls] (rebound keys only), [camera],
## [factorio] (paths, ports, the server's autosave) and [new_game] (the map generator's last
## choices). ui_settings.gd ([map]) and fx_settings.gd ([sound]) are views of it.
## The older `ui.cfg` and `audio.cfg` are read into this file once (the keys it doesn't have yet)
## and then left alone.
##
## Command-line options win over the file for that run and aren't saved: --ui-scale (kit.gd),
## --camera=... (camera_rig.gd), --factorio-data (item_icons.gd), the sound options
## (fx_settings.gd), and --factorio=<factorio.exe> --server-data=<dir> --saves-dir=<dir>
## --port-base=<port> (here). --settings-file=<path> uses another file, so tests and screenshots
## leave the player's own settings alone.
##
## Whoever shows something a setting changes calls `listen(callable)`; `set_value` saves and calls
## every listener with (section, key), so most settings apply at once.

const ItemCards := preload("res://scripts/world/item_cards.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const Kit := preload("res://scripts/ui/factorio/kit.gd")
const Controls := preload("res://scripts/player/controls.gd")
const Upscalers := preload("res://scripts/menu/upscalers.gd")
const DlssHost := preload("res://scripts/menu/dlss_host.gd")
const FsrHost := preload("res://scripts/menu/fsr_host.gd")
const Switches := preload("res://scripts/switches.gd")

const PATH := "user://settings.cfg"
## [meta]: set once add-ons found under an earlier Zenith were kept on (addon_loader.gd _migrate_once).
const ADDONS_OFF_BY_DEFAULT := "addons_off_by_default"
## [model_packs] `choices` for a settings file that has none: the owner's own picks (0.3.1), so a new
## player sees what the owner sees: Placeholders' rigged biters, spitters and spawners over Wube3DP's,
## FUE5's lab and pumpjack whatever pack comes above. `--default-model-choices=off`: none, as before.
const DEFAULT_MODEL_CHOICES := {
	"big-biter": "builtin:placeholders",
	"big-spitter": "builtin:placeholders",
	"biter-spawner": "builtin:placeholders",
	"lab": "builtin:fue5",
	"pumpjack": "builtin:fue5",
}

const DEFAULTS := {
	"graphics": {
		"window_mode": "borderless",  # windowed, borderless, fullscreen
		"resolution": "",  # "1920x1080"; "" keeps the window's size, or in full screen the monitor's
		"screen": -1,  # Factorio's preferred screen; -1: the primary one
		"minimize_on_focus_loss": false,  # in full screen
		"vsync": true,
		"fps_cap": 0,  # 0: unlimited
		"render_scale": 0.8,
		# 3D upscaler (scaling_mode_for; --upscaler=bilinear|fsr1|fsr2|fsr3|fsr4|dlss|auto): "bilinear", "fsr1" (FSR 1.0,
		# spatial, works with MSAA/SMAA) or "fsr2" (AMD FSR 2.2, temporal: Godot 4.7's Viewport.SCALING_3D_MODE_FSR2,
		# replaces TAA/MSAA/SMAA while it is on); "fsr4" (AMD FSR 4.1, Radeon RX 6000+), "fsr3" (AMD FSR 3.1, any GPU), "dlss" (NVIDIA
		# DLSS) and "auto" need a vendor runtime this build doesn't have yet (upscalers.gd): FSR 2.2 runs instead.
		"upscaler": "fsr2",
		# The player's OK for NVIDIA DLSS (alt/dlss-s7c): NVIDIA's driver runs its own updater (nvngx_update.exe, may go
		# online) once DLSS starts, so DLSS asks first; off until they say yes, withdrawn under Upscaling
		# (set_dlss_consent; --dlss-consent=yes / no for one run).
		"dlss_consent": false,
		# 0.0 softest .. 1.0 sharpest (fsr_sharpness_value maps it to Godot's 2 softest .. 0 sharpest);
		# 0.575 is the 0.85 FSR_SHARPNESS Zenith has always used.
		"upscaler_sharpness": 0.575,
		# off, fxaa, smaa, taa, msaa2, msaa4, msaa8. SMAA: sharper than FXAA for about 0.3 ms more GPU
		# at 4K on the owner's desktop (a run with the PC in use had it cheaper, 10.7 against 11.4 ms
		# standing), and it works under every look, where MSAA doesn't under a look with its own passes
		# (MSAA_UNDER_LOOK). Under TAA it is left out (screen_space_aa_for).
		"antialiasing": "smaa",
		# How the world is lit and graded (looks.gd): "factorio" (matched to Factorio's pictures),
		# "classic" (Zenith's look before 0.1.4), or an add-on's look
		"look": "factorio",
		"look_before": "factorio",  # what an add-on's look replaced, back when the add-on goes
		# Packs' own shading (looks.gd pack_shading, model_packs.gd shading()): "pack" (each pack as its pack.json
		# says: a "pbr" pack's textured models drawn as their files say) or "factorio" (Factorio's everywhere, as
		# before 0.2.2; --pack-shading=factorio)
		"pack_shading": "pack",
		"pack_tiles": true,  # ground textures from model packs (model_packs.gd tiles_on; --pack-tiles=off)
		"pack_decoratives": true,  # decoratives and 3D grass from model packs (model_packs.gd decor_on; --pack-decoratives=off)
		"decor_models": false,  # off: the placeholder 3D decoratives were removed (owner); a pack's own 3D .glb/.gltf decorative models vs 2D sprites (model_packs.gd decor_models_on; --decor-models=off)
		"shadows": "high",  # off, low, medium, high, ultra (sun_shadows.gd)
		"shadow_distance": 0,  # tiles the shadows may reach from the camera; 0: the quality's (sun_shadows.gd)
		# high, medium, low: how soon far-away models and their shadows simplify (model_lods.gd); the
		# models near the character stay whole at every level
		"lod_quality": "medium",
		# Custom distance (tiles) where LODs start falling off; 0 follows lod_quality (Auto).
		# Models, belts, items, far merged chunks, and lights auto-adjust from this distance.
		"lod_distance": 0,
		# Far chunks' buildings drawn as one simplified mesh each (far_chunks.gd): far fewer draws
		"merge_far": true,
		# Nauvis's cliffs as one generated wall a chunk instead of the pack's pieces (cliff_wall.gd; --cliff-wall=off: the pieces)
		"cliff_wall": true,
		# Bullet tracers: a short streak from the muzzle to the hit per shot, the ammo's colour (weapon_fx.gd;
		# a look of ours, Factorio draws none; --bullet-tracers=off)
		"bullet_tracers": true,
		# How strongly fights light their surroundings at night: muzzle flashes, explosions, flamethrowers and
		# their fires (combat_lights.gd), 0 none to 2; --combat-lights=old the older lights
		"combat_light_strength": 1.0,
		# Detailed 3D lamp/machine light budget tied to Level of detail plus a 2D world lightmap beyond (lamp_lights.gd)
		"far_lights": true,
		# Persist visited chunk snapshots to user://chunk-cache/ (Zstd compressed regions) so revisiting areas loads immediately
		"chunk_disk_cache": true,
		"animate_mod_buildings": false,  # off by the owner (their card animations looked wrong); a setting still
		# Each model drawn as one surface with one material (material_rows.gd): fewer draws and less
		# render CPU, but its per-pixel table reads cost GPU time (laptop at Ultra: 1-2 ms more
		# standing), so off unless the CPU is the limit. Read when models load: after a restart.
		"merged_materials": false,
		# Screen-space ambient occlusion (apply_ssao), on in High and Ultra. Its own step is cheap, but
		# it makes Godot's depth pre-pass write every pixel's normal and roughness: 6-7 ms of GPU on the
		# laptop before the weathering left that pass (PERFORMANCE-AUDIT.md, item 2), about 0.7 ms on
		# the desktop since. Only drawn zoomed in: ao_zoom.gd fades it out with the zoom and switches it
		# off past that, about 140 tiles off at 1080p (185 at 1440p, 280 at 4K). Godot's own fade
		# (SSAO_FADE) has hidden it by 140 tiles from the camera, so between there and the switch, at
		# 1440p and 4K, it is still paid for where none of it shows.
		"ssao": true,
		# The dark rim on the ground round each building's foot that Factorio's sprites have
		# (contact_shade.gd): one MultiMesh per chunk, on in every preset.
		"contact_shading": true,
		# Godot's renderer on a thread of its own: walking the Zenith Test bus 58 -> 63-73 FPS (stutter-live),
		# once nothing reads the renderer every frame (render_stats.gd, item_models.gd's CPU arrays, Alt-mode's
		# icons kept on the CPU); quitting waits for the workers and a drawn frame, exit_guard.gd ends a stuck
		# one. Off: the main thread, as before 0.3.x. Read at start-up from ENGINE_OVERRIDES, so it applies after
		# a restart (sync_engine_overrides writes it at start when it differs).
		"render_thread": true,
		# Godot's rendering driver on Windows: "d3d12" (default since 0.3.1; the overnight soak measured the client
		# at 4.3-4.5 GB against Vulkan's 8.2-8.6 GB on the same world) or "vulkan" (as before 0.3.1). Godot picks
		# the driver before any script runs, so it is written to ENGINE_OVERRIDES and applies after a restart;
		# project.godot falls back to Vulkan when Direct3D 12 can't start. `--rendering-driver vulkan` on the
		# command line wins over both. Other systems ignore it (Vulkan / Metal as before).
		"renderer": "d3d12",
		"view_radius": 4,  # chunks around the camera (inner full radius in dual-slider default; or total seamless Render distance in unified mode)
		"distant_horizon": 96,  # extreme LOD horizon radius in chunks (0 off, up to 512; distant_horizon.gd)
		"distant_horizon_manual": true,  # on (default): separate View distance (full) & Distant horizon sliders; off: unified Render distance slider + Level of detail
		"distant_horizon_quality": "medium",  # minimal, low, medium, high, ultra cell size & progressive detail per LOD ring
		"distant_horizon_dropoff": "balanced",  # near, balanced, far ring transition distances
		"distant_horizon_glow": true,  # emissive factory silhouette clusters at night on distant LODs
		"distant_horizon_shots": true,  # let Distant Horizon cover the far horizon for wide screenshots
		"entity_radius": 128,  # tiles around the camera where moving things and machine states are shown (doubled from 96)
		# Items on belts are drawn out to belt_distance (0 off): moving, from the character outwards, as
		# far as belt_updates allows (the most items and lanes the server reads an update), and past
		# that each lane as icons of what it carries (owner: one distance and a cap, not two distances).
		"belt_distance": 128,
		"belt_updates": -1,  # -1: Automatic (belt_lanes.gd follows the room there is); 0: Unlimited, every item within belt_distance moves
		"belt_smooth": true,  # belt items read in one tick, every update (smooth on curves) rather than spread over ticks
		"decorative_distance": 192,  # tiles out to which ground clutter is drawn, thinner far away (B9)
		# While the game runs under 60 UPS, ask the bridge for less (distances, minimap refreshes,
		# frame rate) below these settings, and give it back when it recovers (ups_governor.gd)
		"hold_ups": true,
		# With the server on this PC, the client's process runs at below-normal priority, so Factorio's
		# tick gets a core first when all are busy (main.gd _apply_priority; --server-first=off)
		"server_first": true,
		"item_icons": true,  # Factorio's icons on items on belts and on the ground
		"item_models_max": 20500,  # Items in 3D: the most belt items drawn as models, nearest first; 0 icons only; ITEM_MODELS_ALL every one
		"effects": true,  # Factorio's "Show all smoke" and "Show particles": smoke, dust, flashes, explosions
		"belt_step": true,  # the character drawn on top of belts it walks over (avatar.gd; drawn only, owner)
		"clouds": true,  # clouds in the sky and their shadows on the ground, planets' haze (scripts/world/sky.gd)
		"decoratives": true,  # grass, flowers and small rocks from Factorio (scripts/world/decoratives.gd)
		"decorative_density": 1.0,  # the share of them drawn, 0.1 to 1
		"grass_3d": "normal",  # grass and low plants near the character in 3D: off, short, normal, far (decoratives.gd)
		"smog": 0.0,  # smog off by default; how thick the volumetric smog over polluted ground and sky is, 0 (none) to 1 (pollution.gd, shaders/smog.gdshader)
		"god_rays": 0.5,  # volumetric sunbeams through clouds, silhouettes, and smog, 0 (off) to 1 (god_rays.gd, shaders/god_rays.gdshader)
		"brightness": 1.0,  # 0.5 to 1.5, as Factorio's sliders
		"contrast": 1.0,
		"saturation": 1.25,
		"color_filter": "none",  # color_filter.gd FILTERS
	},
	"sound": {
		# Linear volumes, 0 to 1 (fx_settings.gd); "<name>_on" false mutes that slider.
		"master": 0.8, "effects": 1.0, "music": 0.0, "ui": 1.0,
		"walking": 1.0, "environment": 1.0, "weapons": 1.0, "explosions": 1.0, "enemies": 1.0,
		"ambient": 1.0,  # each planet's base background loops (fx/ambience.gd)
		"wind": 1.0,  # the wind and the planet's semi-persistent sounds (fx/ambience.gd)
		"alerts": 1.0,  # the alert beep (ui/factorio/alerts.gd)
		"max_voices": 32,  # machine and vehicle loops playing at once (12 before the sound pool)
		"output_device": "Default",
		"pack_sounds": true,  # sounds from model packs (model_packs.gd sounds_on; --pack-sounds=off)
	},
	"interface": {
		"ui_scale": "auto",  # auto, 0.75 ... 2.0
		"mod_windows": false,  # mods' windows drawn in Zenith (off: not usable yet, owner; use Factorio with Ctrl+F9)
		"mod_clicks": true,  # a mod's button pressed in Zenith clicks it in Factorio's own window (hybrid, Windows)
		"mod_click_mode": "focus",  # focus: Factorio comes forward for the click; post: window messages only
		"show_help": false,  # Factorio's "Show mouse and keyboard control hints"; Factorio shows no help panel
		"debug_overlay": false,
		"tooltip_delay": 0.5,  # seconds before a tooltip shows
		"message_delay": 4.0,  # seconds a message stays (Factorio's "Chat message delay")
		"alt_mode": false,  # Alt-mode, remembered between games like Factorio's
		# "A new version is available" (update_check.gd; --update-check=off): "Auto check on open" (off: nothing is
		# requested until the main menu's "Check for updates" is clicked), when it last asked (unix seconds), the
		# newest release seen, and the one "Don't show again" was pressed for
		"update_check": false,
		"update_checked_at": 0,
		"update_seen": "",
		"update_seen_url": "",
		"update_skip": "",
		# Factorio's Interface > Alt-mode arrows (issue #9), with its defaults (seen in 2.1.23 with a fresh
		# config: machines' and pumps' arrows show, inserters' don't)
		"alt_inserter_arrows": false,
		"alt_pump_arrows": true,
		"alt_machine_arrows": true,
		"entity_info": true,  # the entity info panel on the right
		"shortcut_bar": true,  # the shortcut bar right of the quickbar
		"research_progress": true,  # the research in progress, top right
		"alerts": true,  # alert icons over the shortcut bar
		"night_vision_indicator": true,  # the equipment's icon over the shortcut bar while night vision is on (night_vision_icon.gd; --night-vision-fx=off)
		"night_vision_edge": true,  # a green vignette at the screen's edges while it is on (night_vision_overlay.gd)
		"perf_warning": true,  # the warning icon top left while settings are held back for UPS (perf_warning.gd; --perf-warning=off)
		"smart_belt_building": true,  # Factorio's: dragged belts jump obstacles with undergrounds
		# Factorio's "Lock belt building to straight line": on, belts drag along the held belt's line as
		# Factorio 2.x always does (it dropped the setting); off, Zenith's own drag round corners
		"lock_belt_straight": true,
		# off: Factorio's driving, the opposite key brakes and then reverses; on: it brakes to a stop and holds
		# there until let go (settings.gd vehicle_brake_hold, sent by player_input.gd; --vehicle-brake-hold=on|off)
		"vehicle_brake_hold": false,
		# Auto-sort character main inventory and other inventories (trash, open chests, cargo, trunks)
		"auto_sort_inventory": true,
		"auto_sort_containers": true,
		# Factorio 2.1's fluid pipeline visualization (N9, pipeline_marks.gd): with a fluid entity held, in
		# Alt-mode, every pipeline in view; and the hovered entity's pipelines
		"fluid_vis": true,
		"fluid_vis_selected": true,
		# The main menu's backdrop (menu_background.gd): "default", Zenith's built-in factory, or the id of a
		# view recorded in a game (backdrop_recorder.gd, the Esc menu; listed in user://backdrops/,
		# backdrop_list.gd; "snapshot": the one file before 0.2.2); --menu-backdrop=default overrules it
		"backdrop": "default",
	},
	"camera": {
		"default_view": "angled",  # angled, factorio, first_person
		# Gone from Settings (issue #17: the camera is always on the character, hills too); read only by
		# --camera-focus=off's old camera, which rose and fell with an add-on's hills when it was on
		"follow_hills": false,
		"look_sensitivity": 1.0,
		"invert_y": false,
		"orthographic": false,  # the angled view's projection; Factorio's view (F6) is always orthographic
		"map_orthographic": true,  # the remote view's, from the map (F7 switches the view in use)
		"first_person_orthographic": false,  # first person's (owner's I19: each view keeps its own; F7 switches)
		"max_zoom": 140,  # how far the wheel zooms out, in tiles from the focus
		"map_auto_swap": false,  # wheel zoom swaps between the 2D map and 3D remote view
		"map_zoom_out": 240,  # the map's remote view: how far out before the map comes back (tiles)
		# add-ons' camera modifiers (bob, sway, shake) scaled to this percentage, 0: none drawn
		"addon_motion": 100,
	},
	"factorio": {
		"executable": "",  # factorio.exe or the install folder; "" finds it
		"server_data": "",  # "": Paths.default_server_data_dir() (server/data, or the user folder in a download)
		"saves": "",  # "": Paths.default_saves_dir()
		"port_base": 34500,  # launched servers take free ports from here up
		"autosave_interval": 10,  # minutes, 0: never (server-settings.json)
		"autosave_slots": 5,
		"verbose_logging": false,
		# the keys set in Factorio's own controls (its config.ini) are Zenith's defaults (issue #14)
		"use_factorio_keys": true,
		# Zenith 0.2.2's keys (issue #26): its old built-in defaults, and only the keys changed in Factorio
		# (Controls.old_defaults; --keys-defaults=old for one run)
		"keys_0_2_2": false,
		# so are the sound, graphics and interface settings set there (factorio_settings.gd)
		"use_factorio_settings": true,
		# Ctrl+F9 swapping: Factorio's window minimised while Zenith is in front (game_swap.gd)
		"minimize_factorio": true,
		# the main menu's Connect to address: what was typed last (a server on another PC's relay)
		"last_address": "",
	},
	# action -> "<primary>,<alternative>" key names (OS.get_keycode_string, with modifiers such as
	# "Shift+R"; an empty slot is unbound). Only rebound actions are written.
	"controls": {},
	# alert kinds (Factorio's names) switched off or muted in the alerts settings window
	"alerts": {
		"disabled": [],
		"muted": [],
	},
	# The Model packs window (model_packs.gd, model_packs_window.gd): the packs by id
	# ("builtin:<folder>", "loose", "dir:<folder>", "zip:<file>"), top first, and those turned off.
	# A pack of the models folder not listed goes on top, a built-in one in its place under them.
	# `choices`: a model family -> the pack it is taken from whatever the order. A file without
	# `choices` gets DEFAULT_MODEL_CHOICES (the owner's picks, 0.3.1; `--default-model-choices=off`:
	# none, as before); a saved one, `{}` too (the window's reset), stays the player's.
	# `pbr_packs`: canonical pack id -> bool overriding the pack's PBR shading.
	# `pbr_models`: "<pack id>|<family or item:<name>>" -> bool overriding one model/item's PBR shading.
	"model_packs": {
		"order": [],
		"off": [],
		"choices": DEFAULT_MODEL_CHOICES,
		"pbr_packs": {},
		"pbr_models": {},
	},
}

## Resolutions offered besides the screen's own.
const RESOLUTIONS := ["1280x720", "1600x900", "1920x1080", "2560x1440", "3840x2160"]
## Project settings read before the game starts (project.godot's
## application/config/project_settings_override): the render thread setting is written here.
const ENGINE_OVERRIDES := "user://engine.cfg"
## Godot's thread models: the renderer on the main thread, or on its own.
const THREAD_SAFE := 1
const THREAD_SEPARATE := 2
## The Windows rendering drivers the Renderer setting offers (the first is the default).
const RENDERERS := ["d3d12", "vulkan"]


## At start: ENGINE_OVERRIDES written again when the thread model running now isn't the setting's (a new default,
## or no file yet), so the next start follows it. Only for the player's own settings file in a window: tests and
## probes (--settings-file, headless) never write the owner's.
static func sync_engine_overrides() -> void:
	load_settings()
	if path != PATH or DisplayServer.get_name() == "headless":
		return
	var want := THREAD_SEPARATE if bool(get_value("graphics", "render_thread")) else THREAD_SAFE
	var has_threads_arg := arg_value("--worker-threads=") != ""
	var want_threads := worker_threads_cap()
	if int(ProjectSettings.get_setting("rendering/driver/threads/thread_model", THREAD_SAFE)) != want \
			or str(ProjectSettings.get_setting("rendering/rendering_device/driver.windows", "")) != renderer() \
			or (not has_threads_arg and int(ProjectSettings.get_setting("threading/worker_pool/max_threads", -1)) != want_threads):
		write_engine_overrides()


## Maximum WorkerThreadPool threads written to ENGINE_OVERRIDES so background shader/asset jobs leave
## cores free for the OS, DWM, and other apps (`--worker-threads=all|<n>` overrides).
static func worker_threads_cap(cores: int = -1) -> int:
	if cores <= 0:
		cores = OS.get_processor_count()
	var raw := arg_value("--worker-threads=").strip_edges().to_lower()
	if raw == "all" or raw == "-1":
		return -1
	if raw.is_valid_int():
		return clampi(int(raw), 1, maxi(1, cores))
	if cores <= 2:
		return 1
	return clampi(cores - maxi(2, cores / 3), 1, 16)


## The Renderer setting (Windows' rendering driver), one of RENDERERS.
static func renderer() -> String:
	var r := str(get_value("graphics", "renderer")).to_lower()
	return r if RENDERERS.has(r) else str(RENDERERS[0])


## Writes ENGINE_OVERRIDES from the settings; Godot reads it at the next start.
static func write_engine_overrides() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("rendering", "driver/threads/thread_model", THREAD_SEPARATE if bool(get_value("graphics", "render_thread")) else THREAD_SAFE)
	cfg.set_value("rendering", "rendering_device/driver.windows", renderer())
	cfg.set_value("threading", "worker_pool/max_threads", worker_threads_cap())
	cfg.save(ENGINE_OVERRIDES)


## Graphics presets (Settings > Graphics > Preset): the settings each sets together, from cheapest to
## dearest. High is the defaults; every setting stays its own, and the preset shows "Custom" once
## any of these differs from all of them (preset_now()). High and Ultra have SSAO since its tuned form
## (apply_ssao) measured about 0.7 ms of GPU at the mock's busy base on a desktop card
## (PERFORMANCE-AUDIT.md), and ao_zoom.gd fades it out zoomed out. Anti-aliasing isn't a preset's:
## SMAA (the default) costs a little more than FXAA (about 0.3 ms at 4K on the owner's desktop).
const PRESETS := {
	"low": {"shadows": "low", "ssao": false, "lod_quality": "low", "view_radius": 5, "entity_radius": 96,
		"belt_updates": 2000, "belt_distance": 64, "decorative_distance": 96, "decorative_density": 0.5, "grass_3d": "off",
		"clouds": false, "contact_shading": true, "god_rays": 0.0},
	"medium": {"shadows": "medium", "ssao": false, "lod_quality": "medium", "view_radius": 7, "entity_radius": 128,
		"belt_updates": 4000, "belt_distance": 96, "decorative_distance": 128, "decorative_density": 0.75, "grass_3d": "short",
		"clouds": true, "contact_shading": true, "god_rays": 0.25},
	"high": {"shadows": "high", "ssao": true, "lod_quality": "medium", "view_radius": 4, "entity_radius": 128,
		"belt_updates": -1, "belt_distance": 128, "decorative_distance": 192, "decorative_density": 1.0, "grass_3d": "normal",
		"clouds": true, "contact_shading": true, "god_rays": 0.5},
	"ultra": {"shadows": "ultra", "ssao": true, "lod_quality": "ultra", "view_radius": 14, "entity_radius": 256,
		"belt_updates": -1, "belt_distance": 320, "decorative_distance": 256, "decorative_density": 1.0, "grass_3d": "far",
		"clouds": true, "contact_shading": true, "god_rays": 0.5},
}


## Sets every graphics setting of a preset (PRESETS), writing the file once.
static func apply_preset(preset: String) -> void:
	var values: Dictionary = PRESETS.get(preset, {})
	var keys := values.keys()
	for i in keys.size():
		set_value("graphics", keys[i], values[keys[i]], i == keys.size() - 1)


## The preset to recommend for this PC (Settings > Graphics > Recommended). From the hardware: an
## integrated GPU gets Low or Medium, a discrete one High, a recent big one with 16 threads or more
## Ultra. Then, from what was measured in a game (`fps`: the slowest tenth of frames as a rate,
## `ups`: the game's ticks a second; 0 when not measured), one preset lower for every way it falls
## short of a steady 60: the aim is 60 UPS and 60 FPS, not the most detail.
static func recommended_preset(cores: int, adapter: String, fps := 0.0, ups := 0.0, now := "") -> String:
	var order := ["low", "medium", "high", "ultra"]
	var name := adapter.to_lower()
	var integrated := name.contains("intel") or name.contains("uhd") or name.contains("iris") 		or (name.contains("radeon") and not name.contains("rx")) or name.contains("vega") or name.contains("llvmpipe")
	var big := name.contains("rtx 40") or name.contains("rtx 50") or name.contains("rx 7") or name.contains("rx 9")
	var pick := 2
	if integrated:
		pick = 1 if cores >= 8 else 0
	elif cores < 8:
		pick = 1
	elif big and cores >= 16:
		pick = 3
	if fps > 0.0:
		# Measured in a game at the preset in use: start from it rather than the guess.
		if order.has(now):
			pick = order.find(now)
		if fps < 50.0:
			pick -= 2 if fps < 35.0 else 1
		elif fps > 90.0 and ups >= 59.0:
			pick += 1
		if ups > 0.0 and ups < 57.0:
			pick -= 1
	return order[clampi(pick, 0, order.size() - 1)]


## Settings > Graphics > Merged materials, for the models made from now on (at start-up, before
## any: a change in a game applies after a restart, as models already made keep their surfaces).
## --merged-materials / --no-merged-materials win.
static func apply_merged_materials() -> void:
	if not has_arg("--no-merged-materials") and not has_arg("--merged-materials"):
		ModelLibrary.merge_materials = bool(get_value("graphics", "merged_materials"))


## Whether Settings > Graphics > Recommended turns merged materials on: a big recent discrete GPU
## (the GPU has room for the table reads), and, when a game was measured, a frame the GPU isn't
## holding up (`gpu_ms` the GPU's share of `frame_ms`; 0: not measured).
static func recommended_merged_materials(adapter: String, frame_ms := 0.0, gpu_ms := 0.0) -> bool:
	var name := adapter.to_lower()
	var big := name.contains("rtx 40") or name.contains("rtx 50") or name.contains("rx 7") or name.contains("rx 9")
	if not big or name.contains("laptop"):
		return false
	return frame_ms <= 0.0 or gpu_ms < frame_ms * 0.7


## The preset the graphics settings match now, or "custom".
static func preset_now() -> String:
	for preset in PRESETS:
		var values: Dictionary = PRESETS[preset]
		var same := true
		for key in values:
			var now: Variant = get_value("graphics", key)
			same = same and (is_equal_approx(float(now), float(values[key])) if values[key] is float else now == values[key])
		if same:
			return preset
	return "custom"


## Directional shadow atlas size per quality (sun_shadows.gd QUALITY sets it in a game; the menu's
## background and whether the sun casts shadows at all read it here).
const SHADOW_SIZES := {"low": 2048, "medium": 4096, "high": 4096, "ultra": 8192}
const MSAA := {"msaa2": Viewport.MSAA_2X, "msaa4": Viewport.MSAA_4X, "msaa8": Viewport.MSAA_8X}
## Screen-space anti-aliasing: SMAA keeps edges and fine detail sharper than FXAA, and unlike TAA
## doesn't soften what moves (Godot has no motion vectors for belts' scrolling surfaces).
const SCREEN_SPACE_AA := {"fxaa": Viewport.SCREEN_SPACE_AA_FXAA, "smaa": Viewport.SCREEN_SPACE_AA_SMAA}

## The file in use: PATH, --settings-file=<path>, or a test's (use_file()).
static var path := ""
## The older files read into this one once: file -> {their section: our section}.
static var legacy := {
	"user://ui.cfg": {"map": "map", "interface": "interface"},
	"user://audio.cfg": {"audio": "sound"},
}

static var _cfg := ConfigFile.new()
static var _loaded := false
## The look in use asks for temporal anti-aliasing (looks.gd), whatever the setting says.
static var look_taa := false
static var _listeners: Array[Callable] = []
## Values held for a while over the player's own without touching the file (full_detail.gd: every
## distance and level at its most for a screenshot): section -> {key: value}. get_value returns them
## first; hold() and release() tell the listeners once for the lot.
static var _held := {}
## The rebindable actions' defaults as player_input.gd defines them: action -> [primary, alternative]
## key codes (0: none), in its order.
static var _default_keys := {}
## Zenith's own default keys (controls.gd), before Factorio's (apply_factorio_keys).
static var _own_keys := {}
## The keys read from Factorio's config.ini (factorio_keys.gd), action -> [primary, alternative].
static var factorio_keys := {}
## How many of factorio_keys' controls were changed in Factorio (its config.ini's set lines); the rest
## are Factorio's defaults (its "; " lines).
static var factorio_keys_changed := 0
## The config.ini factorio_keys came from and its modified time, so a change made in Factorio while
## Zenith runs is read again when Zenith's window comes back (refresh_factorio_keys).
static var _factorio_keys_file := ""
static var _factorio_keys_time := 0
## Modified times are whole seconds (two on FAT): a write in the second it was read leaves the time as
## it was. So until a focus-in comes FACTORIO_KEYS_SAME_SEC past the file's time, refresh_factorio_keys
## also compares the text's length and hash (String.hash, 32 bits) with these; after one that matches
## that late, the time alone tells (`_factorio_keys_settled`).
static var _factorio_keys_length := 0
static var _factorio_keys_hash := 0
static var _factorio_keys_settled := false
## How many times refresh_factorio_keys read the text to compare it (tests: a settled file is never read).
static var factorio_keys_text_checks := 0
## What the file was looked for with (--factorio=, the executable setting, a test's config.ini) and
## when (msec): refresh_factorio_keys looks again only when one of those changed, or, with none
## found, a minute after the last look.
static var _factorio_keys_source := ""
static var _factorio_keys_looked := 0
## How many times config.ini was looked for (the full search: tests check a focus-in does none).
static var factorio_keys_lookups := 0
## The settings read from Factorio's config.ini (factorio_settings.gd), {section: {key: value}}:
## the defaults for those keys, in place of DEFAULTS'. {} when off.
static var factorio_values := {}

## The build's channel (tools/release/package.py --channel): the public downloads carry no testing
## tools, development downloads and a checkout do (owner). A dev export has the custom feature tag
## DEV_FEATURE, baked into its .pck by package.py, so the build itself says what it is: no file
## beside the program to lose, copy or forge.
const DEV_FEATURE := "zenith_dev"
## Tests force dev_tools() one way (1) or the other (0); -1 asks the build.
static var dev_tools_override := -1


## The testing tools are here: the main menu's Performance test and --perf-test, the debug menu
## (Ctrl+F12) and its overlays. True in a dev build and when running from source (the editor, or
## `godot --path client`), unless started with `-- --public-build` to see what players get.
static func dev_tools() -> bool:
	if dev_tools_override != -1:
		return dev_tools_override == 1
	if OS.has_feature(DEV_FEATURE) or has_arg("--dev-tools"):
		return true  # --dev-tools: a public download with the testing tools (owner: one download, no separate dev build)
	return not OS.has_feature("template") and not has_arg("--public-build")


static func load_settings() -> void:
	if _loaded:
		return
	_loaded = true
	if path == "":
		path = arg_value("--settings-file=")
		if path == "":
			path = PATH
	if path == PATH:
		copy_old_user_folder()
	_cfg = ConfigFile.new()
	# A file there that can't be read (cut short, damaged) still came from an earlier Zenith: only a
	# missing one is fresh, so its add-ons go through the migration instead of all turning off.
	var fresh := not FileAccess.file_exists(path)
	var existed := _cfg.load(path) == OK
	if not existed:
		_cfg = ConfigFile.new()
	var renamed := _rename_values()
	var reset := _ssao_off_once()
	var belt_auto := _belt_auto_once()
	var still_cards := _mod_anim_off_once()
	var full_res := _full_screen_resolution_once()
	var grass := _grass_preset_once()
	var dual := _dual_distance_once()
	var wind := _wind_volume_once()
	if fresh:
		# Add-ons are off until switched on; a new file has none to keep on (addon_loader.gd _migrate_once).
		_cfg.set_value("meta", ADDONS_OFF_BY_DEFAULT, true)
	if _migrate() or renamed or reset or belt_auto or still_cards or full_res or grass or dual or wind or not existed:
		_cfg.save(path)


## Values that were renamed: an older name of the angled view's setting is read as it. True when one changed.
static func _rename_values() -> bool:
	var changed := false
	if str(_cfg.get_value("camera", "default_view", "")) == "zomboid":
		_cfg.set_value("camera", "default_view", "angled")
		changed = true
	# "Belt items far away" became the one Belt item distance; "Belt items in full" gave way to
	# Belt updates (how far items move follows from it).
	if _cfg.has_section_key("graphics", "belt_far_distance"):
		if not _cfg.has_section_key("graphics", "belt_distance"):
			_cfg.set_value("graphics", "belt_distance", _cfg.get_value("graphics", "belt_far_distance"))
		_cfg.erase_section_key("graphics", "belt_far_distance")
		changed = true
	if _cfg.has_section_key("graphics", "belt_near_distance"):
		_cfg.erase_section_key("graphics", "belt_near_distance")
		changed = true
	# Items on belts (3D models or icons) became Items in 3D's 0.
	if _cfg.has_section_key("graphics", "item_models"):
		var models: Variant = _cfg.get_value("graphics", "item_models")
		if models is bool and not models:
			_cfg.set_value("graphics", "item_models_max", 0)
		_cfg.erase_section_key("graphics", "item_models")
		changed = true
	# Smooth belt items and item icons left the menu in 0.1.3 and stay on (owner); a file from 0.1.2
	# with either switched off kept it off, with nothing left to switch it back (coloured blocks
	# instead of icons, belt items read over several ticks).
	for key in ["belt_smooth", "item_icons"]:
		var on: Variant = _cfg.get_value("graphics", key, true)
		if not (on is bool and on):
			_cfg.erase_section_key("graphics", key)
			changed = true
	# The Model look's "Factorio sprite projected" is gone (owner): models always wear Factorio's
	# colours. A file that chose it says "colours" from now on (so an older Zenith reads that too).
	if _cfg.has_section_key("graphics", "model_look") and str(_cfg.get_value("graphics", "model_look")) != "colours":
		_cfg.set_value("graphics", "model_look", "colours")
		changed = true
	return changed


## SSAO was on by default and in the High and Ultra presets until it measured 6-7 ms of GPU a
## frame; it was turned off once in files saved before then (this flag). Retuned (about 0.7 ms, faded
## out with the zoom) it is on by default and in High and Ultra again; files that already have the
## flag keep the player's choice. True when changed.
static func _ssao_off_once() -> bool:
	if bool(_cfg.get_value("meta", "ssao_off", false)):
		return false
	_cfg.set_value("meta", "ssao_off", true)
	if _cfg.has_section_key("graphics", "ssao"):
		_cfg.set_value("graphics", "ssao", false)
	return true


## Modded buildings' cards were animated by default in 0.1.3; the owner turned that off. Once, in
## files saved before, the setting goes off; turned on again it stays on. True when the file changed.
static func _mod_anim_off_once() -> bool:
	if bool(_cfg.get_value("meta", "mod_anim_off", false)):
		return false
	_cfg.set_value("meta", "mod_anim_off", true)
	if _cfg.has_section_key("graphics", "animate_mod_buildings"):
		_cfg.set_value("graphics", "animate_mod_buildings", false)
	return true


## Resolution did nothing in full screen until it came to scale the picture to the monitor. Once, in
## files saved before: one in full screen drops the size left over from a window, so the game doesn't
## turn blurry by itself; picked again it stays. True when the file needs saving.
static func _full_screen_resolution_once() -> bool:
	if bool(_cfg.get_value("meta", "full_screen_resolution", false)):
		return false
	_cfg.set_value("meta", "full_screen_resolution", true)
	if str(_cfg.get_value("graphics", "window_mode", "windowed")) != "windowed" and _cfg.has_section_key("graphics", "resolution"):
		_cfg.erase_section_key("graphics", "resolution")
	return true


## 0.1.2's High and Ultra presets wrote Moving belt items (then Belt updates) as 6,000 and 12,000;
## since 0.1.3 both presets, and the default, are Automatic. A file left on one of those presets
## kept the fixed cap and its Preset read Custom. Once, in files saved before: one whose graphics
## are all that preset's but this cap gets Automatic. True when the file needs saving.
static func _belt_auto_once() -> bool:
	if bool(_cfg.get_value("meta", "belt_auto", false)):
		return false
	_cfg.set_value("meta", "belt_auto", true)
	var caps := {"high": 6000, "ultra": 12000}
	var cap: Variant = _cfg.get_value("graphics", "belt_updates", -1)
	for preset in caps:
		if cap is int and cap == caps[preset] and _stored_preset(preset, "belt_updates"):
			_cfg.set_value("graphics", "belt_updates", -1)
	return true


## 3D grass is new, and its default is High's. Once, in files saved before: one on the Low or Medium
## preset takes that preset's value, so a slower PC doesn't get it unasked. True when the file needs saving.
static func _grass_preset_once() -> bool:
	if bool(_cfg.get_value("meta", "grass_preset", false)):
		return false
	_cfg.set_value("meta", "grass_preset", true)
	for preset in ["low", "medium"]:
		if _stored_preset(preset, "grass_3d"):
			_cfg.set_value("graphics", "grass_3d", PRESETS[preset]["grass_3d"])
	return true


## 0.3.0's Ambient slider covered the wind too; since then Wind is a slider of its own (default full).
## Once, in files saved before: one with an Ambient volume (or mute) and no Wind takes the Ambient
## one for Wind, so a player who turned Ambient down doesn't get the wind back at full volume.
## True when the file needs saving.
static func _wind_volume_once() -> bool:
	if bool(_cfg.get_value("meta", "wind_volume", false)):
		return false
	_cfg.set_value("meta", "wind_volume", true)
	if _cfg.has_section_key("sound", "ambient") and not _cfg.has_section_key("sound", "wind"):
		_cfg.set_value("sound", "wind", _cfg.get_value("sound", "ambient"))
	if _cfg.has_section_key("sound", "ambient_on") and not _cfg.has_section_key("sound", "wind_on"):
		_cfg.set_value("sound", "wind_on", _cfg.get_value("sound", "ambient_on"))
	return true


## Unified Render distance mode used a single `view_radius` (up to 512) with `distant_horizon_manual = false`.
## Once, when migrating back to separate View distance (full) and Distant horizon sliders:
## switch `distant_horizon_manual` to true, and if `view_radius` exceeds VIEW_RADIUS_MAX, preserve the outer
## distance in `distant_horizon` and map `view_radius` back to a safe full-chunk radius from `lod_quality`.
static func _dual_distance_once() -> bool:
	if bool(_cfg.get_value("meta", "dual_distance_migrated", false)):
		return false
	_cfg.set_value("meta", "dual_distance_migrated", true)
	_cfg.set_value("graphics", "distant_horizon_manual", true)
	var vr := int(_cfg.get_value("graphics", "view_radius", DEFAULTS["graphics"]["view_radius"]))
	if vr > VIEW_RADIUS_MAX:
		var dh := clampi(int(_cfg.get_value("graphics", "distant_horizon", 0)), 0, RENDER_DISTANCE_MAX)
		_cfg.set_value("graphics", "distant_horizon", maxi(dh, clampi(vr, 0, RENDER_DISTANCE_MAX)))
		var lod := str(_cfg.get_value("graphics", "lod_quality", DEFAULTS["graphics"]["lod_quality"])).to_lower()
		var safe_vr := 9
		match lod:
			"low":
				safe_vr = 6
			"high":
				safe_vr = 14
			"ultra":
				safe_vr = 16
			_:
				safe_vr = 9
		_cfg.set_value("graphics", "view_radius", safe_vr)
	return true


## Whether the file's graphics settings (the defaults where it has none) are a preset's, leaving
## out `skip`.
static func _stored_preset(preset: String, skip: String) -> bool:
	var values: Dictionary = PRESETS[preset]
	for key in values:
		if key == skip:
			continue
		var now: Variant = _cfg.get_value("graphics", key, DEFAULTS["graphics"].get(key))
		if values[key] is float:
			if not (now is float or now is int) or not is_equal_approx(float(now), float(values[key])):
				return false
		elif typeof(now) != typeof(values[key]) or now != values[key]:
			return false
	return true


## The project was renamed from "Factorio 3D" to "Zenith", which moved Godot's user folder
## (app_userdata/<project name>). Once, while the new folder has no settings yet, the player's
## files from the old one are copied over: settings, quickbar, blueprint library, sound.
static func copy_old_user_folder() -> void:
	var here := OS.get_user_data_dir()
	var old := here.get_base_dir().path_join("Factorio 3D")
	if FileAccess.file_exists(here.path_join("settings.cfg")) or not DirAccess.dir_exists_absolute(old):
		return
	var dir := DirAccess.open(old)
	if dir == null:
		return
	DirAccess.make_dir_recursive_absolute(here)
	for f in dir.get_files():
		if (f.ends_with(".cfg") or f.ends_with(".json")) and not f.contains("test") and not f.begins_with("probe-"):
			DirAccess.copy_absolute(old.path_join(f), here.path_join(f))


## Uses another file from now on (tests), forgetting what was loaded.
static func use_file(file: String) -> void:
	path = file
	_loaded = false
	load_settings()


## Reads the older ui.cfg and audio.cfg into this file, once: the keys it doesn't have yet.
## True when the file needs saving.
static func _migrate() -> bool:
	if bool(_cfg.get_value("meta", "migrated", false)):
		return false
	for old_path in legacy:
		var old := ConfigFile.new()
		if old.load(old_path) != OK:
			continue
		var sections: Dictionary = legacy[old_path]
		for section in old.get_sections():
			var target := str(sections.get(section, ""))
			if target == "":
				continue
			for key in old.get_section_keys(section):
				if not _cfg.has_section_key(target, key):
					_cfg.set_value(target, key, old.get_value(section, key))
		# audio.cfg's [effects] enabled is the graphics tab's smoke and particles.
		if old.has_section_key("effects", "enabled") and not _cfg.has_section_key("graphics", "effects"):
			_cfg.set_value("graphics", "effects", bool(old.get_value("effects", "enabled")))
	_cfg.set_value("meta", "migrated", true)
	return true


static func get_value(section: String, key: String) -> Variant:
	load_settings()
	if not _held.is_empty() and _held.has(section) and (_held[section] as Dictionary).has(key):
		return _held[section][key]
	var fallback = factorio_values.get(section, {}).get(key, DEFAULTS.get(section, {}).get(key))
	if section == "model_packs" and key == "choices" and not Switches.on("--default-model-choices"):
		fallback = {}  # no default choices: the pack order alone, as before 0.3.1
	return _cfg.get_value(section, key, fallback)


## What a setting is when Zenith's file doesn't have it: Factorio's (factorio_values), else null.
static func factorio_default(section: String, key: String) -> Variant:
	load_settings()
	return factorio_values.get(section, {}).get(key)


## Reads Factorio's settings again (the switch was turned, or at start-up) and tells the listeners
## about every setting whose default that changed. Only for the player's own settings file, or
## with --factorio-config=<file>, so tests with --settings-file aren't shaped by the machine's
## Factorio.
static func reload_factorio_settings() -> void:
	load_settings()
	var before := factorio_values
	var own := path == PATH or arg_value("--factorio-config=") != ""
	factorio_values = load("res://scripts/menu/factorio_settings.gd").read() if own and bool(get_value("factorio", "use_factorio_settings")) else {}
	for values in [before, factorio_values]:
		for section in values:
			for key in values[section]:
				if not _cfg.has_section_key(section, key):
					_notify(section, key)


## Changes a setting, writes the file (unless `persist` is false: a slider being dragged) and
## tells the listeners.
static func set_value(section: String, key: String, value: Variant, persist := true) -> void:
	load_settings()
	_cfg.set_value(section, key, value)
	if persist:
		_cfg.save(path)
	if section == "interface" and key == "tooltip_delay":
		apply_interface()
	if section == "graphics" and key == "item_models_max":
		apply_item_look()
	if section == "graphics" and (key == "render_thread" or key == "renderer") and persist:
		write_engine_overrides()
	if section == "factorio" and key == Controls.OLD_KEYS_SETTING and not _default_keys.is_empty():
		apply_old_defaults()
		reload_factorio_keys()
	if section == "interface" and key == "ui_scale":
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null:
			apply_ui_scale(tree.root)
	_notify(section, key)


## Holds these values of a section over the player's own (`{key: value}`), not saved; the listeners
## hear of it once (the last key). release() gives the player's back.
static func hold(section: String, values: Dictionary) -> void:
	load_settings()
	if values.is_empty():
		return
	var mine: Dictionary = _held.get(section, {})
	mine.merge(values, true)
	_held[section] = mine
	_held_changed(section, values.keys())


static func release(section: String) -> void:
	if not _held.has(section):
		return
	var keys: Array = (_held[section] as Dictionary).keys()
	_held.erase(section)
	_held_changed(section, keys)


static func held(section: String, key: String) -> bool:
	return _held.has(section) and (_held[section] as Dictionary).has(key)


static func _held_changed(section: String, keys: Array) -> void:
	if section == "graphics" and keys.has("item_models_max"):
		apply_item_look()
	_notify(section, str(keys[-1]))


static func save() -> void:
	load_settings()
	_cfg.save(path)


static func has_value(section: String, key: String) -> bool:
	load_settings()
	return _cfg.has_section_key(section, key)


## Puts a setting back to its default.
static func reset_value(section: String, key: String) -> void:
	load_settings()
	if _cfg.has_section_key(section, key):
		_cfg.erase_section_key(section, key)
		_cfg.save(path)
	_notify(section, key)


static func _notify(section: String, key: String) -> void:
	for f in _listeners.duplicate():
		if f.is_valid():
			f.call(section, key)
		else:
			_listeners.erase(f)


static func listen(f: Callable) -> void:
	if not _listeners.has(f):
		_listeners.append(f)


static func unlisten(f: Callable) -> void:
	_listeners.erase(f)


static func arg_value(prefix: String) -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.substr(prefix.length())
	return ""


static func has_arg(prefix: String) -> bool:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return true
	return false


# --- startup ---------------------------------------------------------------------------------

## Settings that must be in place before anything is built: the UI scale, merged materials,
## icons on items, the tooltip delay. Called first thing by main.gd.
static func apply_startup(window_height: float) -> void:
	load_settings()
	sync_engine_overrides()
	var ui_scale := str(get_value("interface", "ui_scale"))
	if ui_scale != "auto" and not has_arg("--ui-scale="):
		Kit.scale = clampf(float(ui_scale), 0.5, 4.0)
		Kit._scale_set = true
	Kit.configure(window_height)
	apply_merged_materials()
	ItemCards.use_icons = bool(get_value("graphics", "item_icons"))
	apply_item_look()
	ItemCards.configure_from_command_line()
	apply_interface()


## Settings → Graphics → Items in 3D: the slider's top end draws every item as a model.
const ITEM_MODELS_ALL := 20500

## Settings → Graphics → View distance, in chunks round the camera: the slider stops at
## VIEW_RADIUS_SLIDER_MAX (10) and allows custom typing up to VIEW_RADIUS_MAX (50, world.gd
## MAX_VIEW_RADIUS, the bridge's world.lua MAX_RADIUS), turning red past the slider max.
## Distant horizon's slider stops at DISTANT_HORIZON_SLIDER_MAX (256) and allows typing up to
## RENDER_DISTANCE_MAX (512), turning red past 256.
const VIEW_RADIUS_SLIDER_MAX := 10
const VIEW_RADIUS_MAX := 50
const DISTANT_HORIZON_SLIDER_MAX := 256
const RENDER_DISTANCE_MAX := 512
const VIEW_RADIUS_DEAR := 10
const VIEW_RADIUS_DEAREST := 20


static func models_cap(value: Variant) -> int:
	var v := int(value)
	return -1 if v >= ITEM_MODELS_ALL else maxi(v, 0)


## Items in 3D at 0 draws every item as its icon (on belts, the ground and in hands), as the old
## Items on belts: Icons did; above 0 items have their models, belt items up to the cap.
static func apply_item_look() -> void:
	var cap := models_cap(get_value("graphics", "item_models_max"))
	ItemCards.use_models = cap != 0
	ItemCards.model_cap = cap


## The UI scales Factorio offers (Settings → Interface, Ctrl+= / Ctrl+- step through them), as
## the settings file stores them.
const UI_SCALES := ["0.75", "1.0", "1.25", "1.5", "1.75", "2.0"]


## The scale the interface is drawn at for a UI scale setting, in a window this many lines high with
## this full_screen_ratio(): the setting means what it would at the picked resolution ("auto" follows
## that many lines, as Factorio does), and the interface is that much larger on the monitor's own
## pixels, so it takes the room it would there and stays sharp.
static func ui_scale_for(value: String, window_height: float, ratio: float) -> float:
	var at_resolution := Kit.scale_for(window_height * ratio) if value == "auto" else clampf(float(value), 0.5, 4.0)
	return at_resolution / ratio


## The UI scale the settings ask for now, in screen pixels.
static func wanted_ui_scale() -> float:
	if has_arg("--ui-scale="):
		return clampf(float(arg_value("--ui-scale=")), 0.5, 4.0)
	return ui_scale_for(str(get_value("interface", "ui_scale")), DisplayServer.window_get_size().y, full_screen_ratio())


## The UI scale as the player knows it: at the picked resolution, what Settings and Ctrl+= speak of.
static func chosen_ui_scale() -> float:
	if has_arg("--ui-scale="):
		return wanted_ui_scale()
	return ui_scale_for(str(get_value("interface", "ui_scale")), DisplayServer.window_get_size().y * full_screen_ratio(), 1.0)


## Changes the UI scale without a restart. The UI is built in GUI pixels times Kit.scale, the
## scale it started with; the root window's content scale makes up the difference, so every
## window, the HUD and the menus grow or shrink at once and lay themselves out again for the
## smaller or larger room (the 3D view keeps its full resolution). The next start builds at the
## new scale directly, so text is as sharp as ever then.
static func apply_ui_scale(root: Window) -> void:
	if root == null or DisplayServer.get_name() == "headless":
		return
	var factor := wanted_ui_scale() / Kit.scale
	if not is_equal_approx(root.content_scale_factor, factor):
		root.content_scale_factor = factor


## One step up or down Factorio's list of UI scales (Ctrl+= / Ctrl+-), from the scale in use.
static func step_ui_scale(steps: int) -> void:
	var now := chosen_ui_scale()
	var i := 0
	for k in UI_SCALES.size():
		if absf(float(UI_SCALES[k]) - now) < absf(float(UI_SCALES[i]) - now):
			i = k
	set_value("interface", "ui_scale", UI_SCALES[clampi(i + steps, 0, UI_SCALES.size() - 1)])


## Settings of the interface that apply at once: the tooltip delay (Godot reads it for each
## tooltip).
static func apply_interface() -> void:
	ProjectSettings.set_setting("gui/timers/tooltip_delay_sec", clampf(float(get_value("interface", "tooltip_delay")), 0.0, 5.0))


## The UPS governor's frame rate cap while it holds one (0: none); main.gd sets it.
static var fps_hold := 0


## The frame rate cap to use: the player's, or the governor's when that is lower (0: unlimited).
## In the front end (no game running) the frame rate is held at MENU_FPS at most (owner: the menu at 60 FPS
## max); --menu-fps=0 leaves the menu uncapped, as before. main.gd sets in_menu on start_game/end_game.
const MENU_FPS := 60
static var in_menu := true
static var menu_fps := _menu_fps_arg()


static func _menu_fps_arg() -> int:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--menu-fps="):
			return maxi(int(a.get_slice("=", 1)), 0)
	return MENU_FPS


static func fps_limit() -> int:
	var cap := int(get_value("graphics", "fps_cap"))
	if in_menu and menu_fps > 0:
		cap = menu_fps if cap <= 0 else mini(cap, menu_fps)
	if fps_hold > 0:
		return fps_hold if cap <= 0 else mini(cap, fps_hold)
	return cap


## Whether temporal anti-aliasing is on: picked here, or asked for by the look in use.
static func taa_on() -> bool:
	return str(get_value("graphics", "antialiasing")) == "taa" or look_taa


## MSAA under a look that draws full-screen passes (the Cinematic shaders' grade, or any add-on's
## look or api.shaders pass; Zenith's own Factorio and Classic looks have none) is switched to SMAA in
## the settings (owner: "it should be on SMAA"). A pass reads the depth texture, and with MSAA Godot
## resolves that by averaging each pixel's samples (renderer_rd/shaders/effects/resolve.glsl,
## MODE_RESOLVE_DEPTH): along every silhouette the depth is half the building's and half the ground's
## or the sky's, a place that isn't there. The grade's sky test (depth 0), its clouds and their
## shadows, the sharpening faded by distance and the far softening all go wrong on those pixels, so
## every edge gets a fringe; and the pass writes one colour into all of a pixel's samples anyway, so
## MSAA's own edges are lost under it. It also multiplies what the look adds (SSAO's and SSIL's
## buffers, TAA's) for nothing (docs/SHADER-PERFORMANCE-PLAN.md). The MSAA choices stay greyed out
## while such a look is on (settings_window.gd _grey_msaa).
const MSAA_UNDER_LOOK := "smaa"
const BUILT_IN_LOOKS := ["factorio", "classic"]


## Whether the look in use now draws passes of its own (or an add-on's pass is over every look).
static func look_draws_passes() -> bool:
	var looks_script = load("res://scripts/world/looks.gd")
	if not (looks_script.extras as Dictionary).is_empty():
		return true
	var id := str(get_value("graphics", "look"))
	if looks_script.active != null:
		id = str(looks_script.active.current)
	var spec: Dictionary = (looks_script.looks as Dictionary).get(id, {})
	if spec.is_empty():
		# Not registered: before the add-ons start, an add-on's look is taken to have passes (it will);
		# after, an id nobody registered falls back to Factorio's look, which has none.
		return not BUILT_IN_LOOKS.has(id) and not _addons_started
	return not (spec.get("passes", []) as Array).is_empty()


## Set by main.gd once the add-ons switched on have started (their looks are registered by then).
static var _addons_started := false


## The anti-aliasing drawn: the setting, or SMAA in place of an MSAA not switched yet under a look
## with passes (switch_msaa_for_look() saves it).
static func antialiasing_in_effect() -> String:
	var aa := str(get_value("graphics", "antialiasing"))
	return MSAA_UNDER_LOOK if MSAA.has(aa) and look_draws_passes() else aa


## The name of the look in use when it sets `what` itself, so that Settings > Graphics' own row for it
## does nothing while the look is on (greyed out, settings_window.gd): "ssao" (its environment's
## ssao_enabled, the Cinematic look's Ambient occlusion) or "clouds" (own_clouds false: its own clouds,
## its own Clouds slider). "" when the setting applies.
static func look_overrides(what: String) -> String:
	var looks_script = load("res://scripts/world/looks.gd")
	var id := str(get_value("graphics", "look"))
	if looks_script.active != null:
		id = str(looks_script.active.current)
	var spec: Dictionary = (looks_script.looks as Dictionary).get(id, {})
	var own := false
	match what:
		"ssao":
			own = (spec.get("environment", {}) as Dictionary).has("ssao_enabled")
		"clouds":
			own = spec.has("own_clouds") and not bool(spec["own_clouds"])
	return str(spec.get("name", id)) if own else ""


## Under a look with passes a saved MSAA becomes SMAA in the settings, saved, so Settings shows what is
## drawn. True when it changed something.
static func switch_msaa_for_look() -> bool:
	if MSAA.has(str(get_value("graphics", "antialiasing"))) and look_draws_passes():
		set_value("graphics", "antialiasing", MSAA_UNDER_LOOK)
		return true
	return false


## What Settings > Graphics > Anti-aliasing adds to its note under a look with passes: why MSAA is
## greyed out. "" under Zenith's own looks.
static func antialiasing_look_note() -> String:
	if look_draws_passes():
		return "MSAA is off under the look in use: its full-screen passes read a depth that MSAA blurs at every edge."
	return ""


## Once the add-ons switched on have started (main.gd): their looks are known, so a saved MSAA under a
## look with passes becomes SMAA and the anti-aliasing is applied, before the first frame is drawn.
static func settle_antialiasing(root: Window) -> void:
	_addons_started = true
	switch_msaa_for_look()
	apply_antialiasing(root)


## MSAA, screen-space anti-aliasing and TAA on the window from the settings. The look's TAA over the
## setting's SMAA drops SMAA (screen_space_aa_for); FXAA stays with it.
static func apply_antialiasing(root: Window) -> void:
	if root == null or DisplayServer.get_name() == "headless":
		return
	var looks_script = load("res://scripts/world/looks.gd")
	if fsr2_active(root):
		# FSR 2.2 does its own temporal anti-aliasing from motion vectors: MSAA, SMAA/FXAA and TAA
		# would fight it (and TAA is what it replaces), so all three stay off while it is on.
		root.msaa_3d = Viewport.MSAA_DISABLED
		root.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
		root.use_taa = false
		_smaa_held = false
		if looks_script.active != null:
			looks_script.active.sync_pre_aa(root)
		sync_temporal_uniforms(root)
		return
	var aa := antialiasing_in_effect()
	var msaa: int = MSAA.get(aa, Viewport.MSAA_DISABLED)
	if root.msaa_3d != msaa:
		root.msaa_3d = msaa as Viewport.MSAA
	var ss := screen_space_aa_for(aa, taa_on())
	_smaa_held = aa == "smaa" and ss != Viewport.SCREEN_SPACE_AA_SMAA
	if root.screen_space_aa != ss:
		root.screen_space_aa = ss as Viewport.ScreenSpaceAA
	root.use_taa = taa_on()
	if looks_script.active != null:
		looks_script.active.sync_pre_aa(root)
	sync_temporal_uniforms(root)


## Pre-grade directional AA strength for full-screen look passes (look_pass.gdshaderinc):
## active when MSAA and TAA are off and screen-space AA (FXAA/SMAA) is enabled, so edges are
## smoothed before Cinematic's sharpening, contrast, aberration and film grain run.
static func look_pre_aa_for(vp: Viewport) -> float:
	if vp == null or vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR2:
		return 0.0  # FSR 2.2 resolves the edges itself
	if vp.msaa_3d != Viewport.MSAA_DISABLED or vp.use_taa:
		return 0.0
	if vp.screen_space_aa == Viewport.SCREEN_SPACE_AA_FXAA:
		return 1.0
	if vp.screen_space_aa == Viewport.SCREEN_SPACE_AA_SMAA:
		return 0.75
	return 0.0


## `--msaa-with-smaa=on`: restore stacking SMAA on top of active MSAA (2x/4x/8x).
static var msaa_with_smaa := Switches.on("--msaa-with-smaa", false)


## The screen-space anti-aliasing drawn for an anti-aliasing choice: none under TAA in place of SMAA,
## and none stacked over active MSAA (`--msaa-with-smaa=on` restores pairing SMAA with MSAA).
## TAA already resolves the edges, and SMAA's three full-screen passes kept running over it: 0.37-0.40 ms
## of GPU at 4K under the Cinematic look with its TAA on (measured on the owner's desktop) for nothing.
static func screen_space_aa_for(aa: String, taa: bool) -> int:
	if aa == "smaa" and taa:
		return Viewport.SCREEN_SPACE_AA_DISABLED
	if MSAA.has(aa):
		return Viewport.SCREEN_SPACE_AA_SMAA if (msaa_with_smaa and not taa) else Viewport.SCREEN_SPACE_AA_DISABLED
	return int(SCREEN_SPACE_AA.get(aa, Viewport.SCREEN_SPACE_AA_DISABLED))


## SMAA left out because TAA is on, to come back when TAA goes.
static var _smaa_held := false


## A look's TAA turned on or off in a running game (looks.gd): SMAA goes with it and comes back after,
## and nothing else changes until apply_antialiasing (a saved MSAA under a look waits for the next
## start: settle_antialiasing).
static func follow_taa(vp: Viewport) -> void:
	if vp == null:
		return
	if vp.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR2:
		# FSR 2.2 replaces TAA and SMAA: nothing to follow while it is on.
		vp.use_taa = false
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
		var fsr_looks = load("res://scripts/world/looks.gd")
		if fsr_looks.active != null:
			fsr_looks.active.sync_pre_aa(vp)
		sync_temporal_uniforms(vp)
		return
	vp.use_taa = taa_on()
	if vp.use_taa and vp.screen_space_aa == Viewport.SCREEN_SPACE_AA_SMAA:
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
		_smaa_held = true
	elif not vp.use_taa and _smaa_held:
		_smaa_held = false
		if vp.screen_space_aa == Viewport.SCREEN_SPACE_AA_DISABLED:
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_SMAA
	var looks_script = load("res://scripts/world/looks.gd")
	if looks_script.active != null:
		looks_script.active.sync_pre_aa(vp)
	sync_temporal_uniforms(vp)


## A Resolution setting ("1920x1080") as a size; (0, 0) for none or one too small to use.
static func parse_resolution(res: String) -> Vector2i:
	if res.contains("x"):
		var wanted := Vector2i(int(res.get_slice("x", 0)), int(res.get_slice("x", 1)))
		if wanted.x >= 320 and wanted.y >= 240:
			return wanted
	return Vector2i.ZERO


## How much of a monitor's resolution a Resolution setting comes to in full screen, where the window
## is the monitor: the fraction of its pixels each way that holds the picked size whole. The world
## always fills the monitor undistorted, so a size of another shape keeps its rows or columns and
## shows a little more the other way. Never above 1: a size past the monitor (a saved one, after
## moving to a smaller screen) is the monitor's own; Game render scaling is there to go beyond it.
static func resolution_ratio(res: String, monitor: Vector2i) -> float:
	var wanted := parse_resolution(res)
	if wanted == Vector2i.ZERO or monitor.x <= 0 or monitor.y <= 0:
		return 1.0
	return minf(1.0, maxf(float(wanted.x) / monitor.x, float(wanted.y) / monitor.y))


## The 3D scale for Game render scaling and a resolution_ratio(): they multiply. 0.1 is Godot's floor.
static func render_scale_for(render_scale: float, ratio: float) -> float:
	return clampf(clampf(render_scale, 0.25, 2.0) * ratio, 0.1, 2.0)


## FSR 1 sharpness when upscaling below native resolution (Godot 4.x range 0 sharpest .. 2 softest:
## 0.85 preserves edge anti-aliasing instead of re-sharpening SMAA/FXAA edges into jaggies).
const FSR_SHARPNESS := 0.85


## The Upscaling choice (one of Upscalers.VALUES, aliases resolved): --upscaler=bilinear|fsr|fsr1|fsr2|fsr2.1|
## fsr2.2|fsr3|fsr3.1|fsr4|fsr4.1|dlss|auto wins over the setting for one run (fsr is FSR 1; fsr2.1 and fsr2.2 are FSR 2 under
## Godot's one implementation; fsr3 is AMD FSR 3.1, fsr4 AMD FSR 4.1); an unknown value is "fsr1".
static func upscaler_choice() -> String:
	var arg := arg_value("--upscaler=").strip_edges()
	if arg == "":
		arg = str(get_value("graphics", "upscaler"))
	return Upscalers.normalize(arg)


## The upscaler in use: "bilinear", "fsr1", "fsr2" (AMD FSR 2.2, Godot 4.7's SCALING_3D_MODE_FSR2), or "fsr4" / "fsr3" /
## "dlss" once a build can run them. Automatic is picked here (Upscalers.auto_pick), and a vendor upscaler this
## PC or build can't run draws with FSR 2.2 for the run (FSR 4.1 or DLSS: FSR 3.1
## when that can run), the saved choice kept (said once in the log).
static func upscaler_in_effect() -> String:
	var choice := upscaler_choice()
	var now := Upscalers.resolve(choice)
	if Upscalers.VENDOR.has(choice) and now != choice and _upscaler_fallback_said != choice:
		_upscaler_fallback_said = choice
		print("Upscaling: %s can't run here (%s): %s this run" % [choice, Upscalers.unavailable_reason(choice), "FSR 3.1" if now == "fsr3" else "FSR 2.2"])
	return now


static var _upscaler_fallback_said := ""


## Gives or withdraws the player's OK for NVIDIA's updater (the Upscaling prompt, the Withdraw button): saved, the
## capabilities asked again (Upscalers.caps follows it), and the window's upscaler applied again, so withdrawing
## stops DLSS at once (a saved dlss / Automatic then draws with FSR 3.1 / 2.2, the saved choice kept). Streamline,
## once loaded, stays loaded in the process until Zenith closes; nothing more is asked of it.
static func set_dlss_consent(yes: bool) -> void:
	_upscaler_fallback_said = ""
	set_value("graphics", "dlss_consent", yes)
	print("Upscaling: the player's OK for NVIDIA's updater %s" % ("given" if yes else "withdrawn"))
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.root != null:
		apply_window(tree.root)


## The Upscaler sharpness setting (0 softest .. 1 sharpest) as Godot's fsr_sharpness (2 softest .. 0
## sharpest): the default 0.575 is FSR_SHARPNESS, 0.85.
static func fsr_sharpness_value() -> float:
	var s := clampf(float(get_value("graphics", "upscaler_sharpness")), 0.0, 1.0)
	return clampf((1.0 - s) * 2.0, 0.0, 2.0)


## Whether the FSR 2.2 pipeline fixes (LookPass reactive clear, pre-resolve sharpen/grain/aberration
## suppression, and orthographic camera fallback) are enabled (`--fsr2-fixes=old` rolls back).
static func fsr2_fixes_enabled() -> bool:
	return not has_arg("--fsr2-fixes=old")


## Test/CLI overrides for temporal motion vectors and belt reactive mask (-1 auto, 0 off, 1 on).
static var temporal_mv_override := -1
static var belt_reactive_override := -1
static var _mv_arg := -2
static var _reactive_arg := -2


static func _read_mv_arg() -> int:
	if _mv_arg == -2:
		_mv_arg = 0 if has_arg("--temporal-motion-vectors=off") else (1 if has_arg("--temporal-motion-vectors=on") else -1)
	return _mv_arg


static func _read_reactive_arg() -> int:
	if _reactive_arg == -2:
		_reactive_arg = 0 if has_arg("--belt-reactive-mask=off") else (1 if has_arg("--belt-reactive-mask=on") else -1)
	return _reactive_arg


## Whether native MultiMesh per-instance motion vectors are allowed (`--temporal-motion-vectors=off` disables).
static func temporal_motion_vectors_enabled() -> bool:
	return temporal_mv_override != 0 and _read_mv_arg() != 0


## Whether temporal AA (TAA, or a temporal upscaler: FSR 2.2, AMD FSR 4.1/3.1, DLSS) is active and MultiMesh
## motion vectors should be driven (belt_mv.gd's gate, creatures, robots).
static func temporal_aa_active(vp: Viewport = null) -> bool:
	if temporal_mv_override == 0 or _read_mv_arg() == 0:
		return false
	if temporal_mv_override == 1 or _read_mv_arg() == 1:
		return true
	if vp == null:
		var loop := Engine.get_main_loop()
		if loop is SceneTree:
			vp = (loop as SceneTree).root
	if vp != null:
		return vp.use_taa or temporal_upscaler_active(vp)
	return taa_on() or temporal_upscaler_wanted()


## Whether the FSR 2.2 belt-surface reactive mask is enabled (`--belt-reactive-mask=off` or `--fsr2-fixes=old` disables).
static func belt_reactive_mask_enabled() -> bool:
	return fsr2_fixes_enabled() and belt_reactive_override != 0 and _read_reactive_arg() != 0


## Whether the FSR 2.2 belt-surface reactive mask is active for `vp` now.
static func belt_reactive_mask_active(vp: Viewport = null) -> bool:
	return belt_reactive_mask_enabled() and (belt_reactive_override == 1 or _read_reactive_arg() == 1 or fsr2_active(vp))


## Syncs the global belt reactive uniform and ModelLibrary's reactive `next_pass` attachment.
static func sync_temporal_uniforms(vp: Viewport = null) -> void:
	var reactive := belt_reactive_mask_active(vp)
	RenderingServer.global_shader_parameter_set(&"f3d_belt_reactive", 1.0 if reactive else 0.0)
	var ml = load("res://scripts/world/model_library.gd")
	if ml != null and ml.has_method("sync_belt_reactive"):
		ml.sync_belt_reactive(reactive)


## Set while the in-game camera is in an orthographic projection (Factorio view F6, F7, or Remote map),
## so FSR 2.2 falls back cleanly until perspective resumes.
static var camera_orthographic := false


static func set_camera_orthographic(ortho: bool, root: Window = null) -> void:
	if camera_orthographic == ortho:
		return
	camera_orthographic = ortho
	if root != null:
		apply_window_scales(root)


## Upscaler for 3D render scaling: FSR 1 when drawing below native resolution (sharper than bilinear,
## works with MSAA and needs no motion vectors), plain bilinear at or above 1.0 (or with
## --upscaler=bilinear), and FSR 2.2 (temporal, from motion vectors: sharper than FSR 1 but replaces
## TAA/MSAA, and it can't draw above native) at 1.0 and below. Orthographic views temporarily fall
## back to FSR 1 / bilinear because FSR 2.2 depth clip/reprojection assume perspective. `upscaler` ""
## is upscaler_in_effect().
static func scaling_mode_for(scale_3d: float, upscaler := "") -> Viewport.Scaling3DMode:
	if upscaler == "":
		upscaler = upscaler_in_effect()
	match upscaler:
		"bilinear":
			return Viewport.SCALING_3D_MODE_BILINEAR
		"fsr2", "fsr4", "fsr3", "dlss":
			# fsr4/fsr3/dlss only get here once a build runs them. AMD FSR (FsrHost.can_run) and NVIDIA DLSS
			# (DlssHost.can_run, only with the player's OK for NVIDIA's updater) draw in the engine hook's own (custom)
			# mode when they can run this run; otherwise they take FSR 2.2's slot. Orthographic views keep FSR 2.2's
			# fallback.
			if camera_orthographic and fsr2_fixes_enabled():
				return Viewport.SCALING_3D_MODE_FSR if scale_3d < 0.999 else Viewport.SCALING_3D_MODE_BILINEAR
			if scale_3d > 1.001:
				return Viewport.SCALING_3D_MODE_BILINEAR
			if upscaler == "dlss" and DlssHost.can_run():
				return DlssHost.SCALING_3D_MODE_CUSTOM as Viewport.Scaling3DMode
			if (upscaler == "fsr4" or upscaler == "fsr3") and FsrHost.can_run():
				return FsrHost.SCALING_3D_MODE_CUSTOM as Viewport.Scaling3DMode
			return Viewport.SCALING_3D_MODE_FSR2
	return Viewport.SCALING_3D_MODE_FSR if scale_3d < 0.999 else Viewport.SCALING_3D_MODE_BILINEAR


## Whether the settings (Upscaling, Game render scaling, Resolution) ask for a temporal upscaler (FSR 2.2, AMD
## FSR Upscaling or DLSS) right now, which apply_window_scales then sets: Settings > Graphics greys out the
## anti-aliasing choice for it regardless of temporary orthographic views (F6/F7/Map).
static func temporal_upscaler_wanted() -> bool:
	var scale_3d := render_scale_for(float(get_value("graphics", "render_scale")), full_screen_ratio())
	return Upscalers.TEMPORAL.has(upscaler_in_effect()) and scale_3d <= 1.001


## The old name of temporal_upscaler_wanted (FSR 2.2 was the only temporal upscaler).
static func fsr2_wanted() -> bool:
	return temporal_upscaler_wanted()


## True while a vendor upscaler (AMD FSR through FsrHost, NVIDIA DLSS through DlssHost) draws the main window
## (apply_window_scales sets it).
static var vendor_upscaler_running := false


## Whether a temporal upscaler (FSR 2.2, or a vendor one) is the 3D scaling of a viewport/window now (the main
## one without `root`): it takes over anti-aliasing (apply_antialiasing) and needs motion vectors.
static func temporal_upscaler_active(root: Viewport = null) -> bool:
	if root == null:
		var tree := Engine.get_main_loop() as SceneTree
		if tree == null:
			return false
		root = tree.root
	return root != null and (root.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR2 or vendor_upscaler_running)


## The old name of temporal_upscaler_active.
static func fsr2_active(root: Viewport = null) -> bool:
	return temporal_upscaler_active(root)


## The resolution_ratio() in use now: 1 unless the window really is full screen. VR draws for the
## headset, whatever the desktop window is. --scale-like-full-screen does the sums with the window
## as the monitor, so a test can see the scaling without taking the screen over.
static func full_screen_ratio() -> float:
	if DisplayServer.get_name() == "headless" or has_arg("--vr"):
		return 1.0
	var res := str(get_value("graphics", "resolution"))
	if has_arg("--scale-like-full-screen"):
		return resolution_ratio(res, DisplayServer.window_get_size())
	if str(get_value("graphics", "window_mode")) == "windowed" or DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED:
		return 1.0
	# The screen's size, not the window's: it stays right while the window is minimised.
	return resolution_ratio(res, DisplayServer.screen_get_size(DisplayServer.window_get_current_screen()))


## The 3D scale and the interface's for the window as it is now. In full screen the world is drawn at
## the Resolution and scaled up through scaling_3d_scale, while the interface is drawn on the
## monitor's own pixels: only the 3D buffer changes size, so screen coordinates, mouse picking and
## screenshots work as at any render scale. Also called when the window's size changes.
static func apply_window_scales(root: Window) -> void:
	if root == null or DisplayServer.get_name() == "headless":
		return
	var scale_3d := render_scale_for(float(get_value("graphics", "render_scale")), full_screen_ratio())
	var mode := scaling_mode_for(scale_3d)
	var was_fsr2 := root.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR2
	var was_vendor := vendor_upscaler_running
	# AMD FSR / NVIDIA DLSS (custom mode): its host attaches it, which sets the mode; if it can't, FSR 2.2 this run.
	# Only one of them draws a window: the other is stopped first.
	var vendor := upscaler_in_effect() if int(mode) == FsrHost.SCALING_3D_MODE_CUSTOM else ""
	if vendor != "dlss":
		DlssHost.stop(root)
	if vendor != "fsr4" and vendor != "fsr3":
		FsrHost.stop(root)
	if vendor == "dlss":
		if not DlssHost.use(root, scale_3d):
			mode = Viewport.SCALING_3D_MODE_FSR2
		else:
			# At most the DLSS mode's own render size (a larger one draws black, DlssHost.fit_scale).
			scale_3d = DlssHost.fit_scale(root, scale_3d)
	elif vendor != "":
		if not FsrHost.use(root, vendor, scale_3d, float(get_value("graphics", "upscaler_sharpness"))):
			mode = Viewport.SCALING_3D_MODE_FSR2
	vendor_upscaler_running = FsrHost.running(root) or DlssHost.running(root)
	if root.scaling_3d_mode != mode:
		root.scaling_3d_mode = mode
	if mode == Viewport.SCALING_3D_MODE_FSR or mode == Viewport.SCALING_3D_MODE_FSR2:
		var sharp := fsr_sharpness_value()
		if not is_equal_approx(root.fsr_sharpness, sharp):
			root.fsr_sharpness = sharp
	if not is_equal_approx(root.scaling_3d_scale, scale_3d):
		root.scaling_3d_scale = scale_3d
	if was_fsr2 != (mode == Viewport.SCALING_3D_MODE_FSR2) or was_vendor != vendor_upscaler_running:
		apply_antialiasing(root)
	else:
		sync_temporal_uniforms(root)
	apply_ui_scale(root)


## The screen the Preferred screen setting means.
static func chosen_screen() -> int:
	var screen := int(get_value("graphics", "screen"))
	if screen < 0 or screen >= DisplayServer.get_screen_count():
		screen = DisplayServer.get_primary_screen()
	return screen


## Settings > Graphics > Resolution's items for a monitor, [label, value]: windowed, the window sizes
## that fit on it; in full screen the monitor's own and the common sizes it can scale up from.
static func resolution_choices(monitor: Vector2i, full_screen: bool) -> Array:
	var own := default_window_size()
	var choices: Array = [["%d × %d (default)" % [monitor.x, monitor.y] if full_screen else "%d × %d (default)" % [own.x, own.y], ""]]
	var listed: Array = RESOLUTIONS.duplicate()
	var native := "%dx%d" % [monitor.x, monitor.y]
	if not full_screen and not listed.has(native):
		listed.append(native)
	for r in listed:
		var size := parse_resolution(str(r))
		if size.x <= monitor.x and size.y <= monitor.y and (not full_screen or resolution_ratio(str(r), monitor) < 1.0):
			choices.append(["%d × %d" % [size.x, size.y], r])
	return choices


## The window's size when Zenith starts with no Resolution set (project.godot's).
static func default_window_size() -> Vector2i:
	return Vector2i(int(ProjectSettings.get_setting("display/window/size/viewport_width", 1600)),
		int(ProjectSettings.get_setting("display/window/size/viewport_height", 900)))


## Resolution's Default picked in a window: the window goes back to default_window_size() (a size
## left empty otherwise keeps the window as it is, dragged bigger or not).
static func restore_default_window_size() -> void:
	if DisplayServer.get_name() == "headless" or str(get_value("graphics", "window_mode")) != "windowed" or has_arg("--screenshot="):
		return
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		return
	var size := default_window_size()
	var area := DisplayServer.screen_get_usable_rect(chosen_screen())
	size = Vector2i(mini(size.x, area.size.x), mini(size.y, area.size.y))
	DisplayServer.window_set_size(size)
	DisplayServer.window_set_position(area.position + (area.size - size) / 2)


## Window mode, size, screen, vsync, FPS cap, render scale and anti-aliasing. The window's mode
## and size are skipped for screenshots (--screenshot), so they keep the project's window.
static func apply_window(root: Window) -> void:
	if DisplayServer.get_name() == "headless":
		return
	Engine.max_fps = fps_limit()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if bool(get_value("graphics", "vsync")) else DisplayServer.VSYNC_DISABLED)
	apply_window_scales(root)
	apply_antialiasing(root)
	# --borderless: a window without a frame, for screenshot runs that shouldn't look like the game opening.
	if has_arg("--borderless"):
		# Dropping the frame keeps the outer rectangle, which would grow the picture by the frame's
		# size: keep the size asked for (--resolution 1920x1080 for UI reference shots).
		var before := DisplayServer.window_get_size()
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
		DisplayServer.window_set_size(before)
	if not has_arg("--screenshot="):
		_apply_window_mode()
	apply_window_scales(root)


## The window's mode, size and screen from the settings.
static func _apply_window_mode() -> void:
	var screen := chosen_screen()
	var on_screen := DisplayServer.window_get_current_screen() == screen
	match str(get_value("graphics", "window_mode")):
		"borderless", "fullscreen":
			if not on_screen:
				if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
					DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
				DisplayServer.window_set_current_screen(screen)
			var exclusive := str(get_value("graphics", "window_mode")) == "fullscreen"
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN if exclusive else DisplayServer.WINDOW_MODE_FULLSCREEN)
		_:
			if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			var size := DisplayServer.window_get_size()
			var wanted := parse_resolution(str(get_value("graphics", "resolution")))
			if wanted != Vector2i.ZERO:
				size = wanted
			if size != DisplayServer.window_get_size() or not on_screen:
				DisplayServer.window_set_size(size)
				var area := DisplayServer.screen_get_usable_rect(screen)
				DisplayServer.window_set_position(area.position + (area.size - size) / 2)


## Brightness, contrast and saturation on a 3D environment (the game's and the menu's).
static func apply_environment(env: Environment) -> void:
	if env == null:
		return
	var b := clampf(float(get_value("graphics", "brightness")), 0.5, 1.5)
	var c := clampf(float(get_value("graphics", "contrast")), 0.5, 1.5)
	var s := clampf(float(get_value("graphics", "saturation")), 0.0, 2.0)
	# A look's colour lookup (look_luts.gd) needs the adjustments on too.
	env.adjustment_enabled = b != 1.0 or c != 1.0 or s != 1.0 or env.adjustment_color_correction != null
	env.adjustment_brightness = b
	env.adjustment_contrast = c
	env.adjustment_saturation = s


## Screen-space ambient occlusion as Zenith's own looks draw it (Settings > Graphics > Ambient
## occlusion): tight, as Factorio's sprites shade corners (a small radius, no detail pass), half
## size, darkening direct light 0.85 of the way on the models (Factorio paints its occlusion in, lit or
## not; the ground takes its own share, terrain.gdshader ssao_on_sunlight), faded out SSAO_FADE tiles
## from the camera. Godot gives a surface max(its AO_LIGHT_AFFECT, ssao_light_affect) of SSAO on direct
## light only as far as ssao_ao_channel_affect says: at 0.5 it was 0.4 on the models (0.3 their own)
## and 0.25 on the ground, so in sunlight SSAO hardly showed. A look's own ssao_* values (the Cinematic
## look's) go over these while it is on (looks.gd lift()/settle() round this). `on` null: the setting's.
const SSAO_FACTORIO := {"ssao_radius": 0.7, "ssao_intensity": 1.6, "ssao_power": 1.5, "ssao_detail": 0.0,
	"ssao_light_affect": 0.85, "ssao_ao_channel_affect": 1.0}
const SSAO_FADE := Vector2(60.0, 140.0)


## `--ssao=off` / `--ssao=on` among `args` (the command line wins over the setting for one run): "off",
## "on", or "" without one.
static func ssao_arg(args: PackedStringArray) -> String:
	var out := ""
	for arg in args:
		if arg.begins_with("--ssao="):
			var v := arg.get_slice("=", 1).to_lower()
			if v == "off" or v == "false" or v == "0" or v == "no":
				out = "off"
			elif v == "on" or v == "true" or v == "1" or v == "yes":
				out = "on"
	return out


static func apply_ssao(env: Environment, on: Variant = null) -> void:
	if env == null:
		return
	if on == null:
		var arg := ssao_arg(OS.get_cmdline_user_args())
		on = (arg == "on") if arg != "" else bool(get_value("graphics", "ssao"))
	env.ssao_enabled = bool(on)
	for key in SSAO_FACTORIO:
		env.set(key, SSAO_FACTORIO[key])
	RenderingServer.environment_set_ssao_quality(RenderingServer.ENV_SSAO_QUALITY_MEDIUM, true, 0.5, 2, SSAO_FADE.x, SSAO_FADE.y)
	RenderingServer.environment_set_ssil_quality(RenderingServer.ENV_SSIL_QUALITY_MEDIUM, true, 0.5, 2, SSAO_FADE.x, SSAO_FADE.y)


## The shadow atlas for a quality; "off" turns the sun's shadows off (main.gd).
static func shadow_size() -> int:
	return int(SHADOW_SIZES.get(str(get_value("graphics", "shadows")), 0))


# --- key bindings ----------------------------------------------------------------------------
# Like Factorio, each control has a primary and an alternative binding, each a key with any
# modifiers (Shift, Ctrl, Alt). Controls are matched with exactly their modifiers (Controls.pressed,
# and Input.is_action_pressed(action, true) for shooting, dropping and picking up), so R and Shift+R, Space
# and Shift+Space, F and Ctrl+F, Keypad + and Ctrl+Keypad + are different controls, as in Factorio. Walking
# answers whatever else is held (Shift, Ctrl and Alt keep the character walking in Factorio too).

## Remembers player_input.gd's default keys (its first key is the primary binding, the second the
## alternative), then applies the saved bindings over them. Call after PlayerInput.define_actions()
## and after any other script has added its actions.
static func apply_bindings() -> void:
	for action in InputMap.get_actions():
		var name := str(action)
		if name.begins_with("ui_") or _default_keys.has(name):
			continue
		var keys: Array = []
		for ev in InputMap.action_get_events(action):
			if ev is InputEventKey and keys.size() < 2:
				keys.append(event_code(ev as InputEventKey))
		while keys.size() < 2:
			keys.append(0)
		_default_keys[name] = keys
		_own_keys[name] = keys.duplicate()
	# The debug line: its F4 in dev builds, no key by default in a public one (issue #26). Set on every
	# call, as the input map may already hold a binding applied over the default.
	for name in Controls.DEV_KEYS:
		if _default_keys.has(name):
			var keys: Array = Controls.default_pair(name) if dev_tools() else [0, 0]
			_default_keys[name] = keys
			_own_keys[name] = keys.duplicate()
	apply_old_defaults()
	if not dev_tools():
		# A public build has no key for the testing tools, in Settings → Controls or anywhere.
		for name in Controls.DEV_ONLY:
			_default_keys.erase(name)
			_own_keys.erase(name)
			if InputMap.has_action(name):
				InputMap.erase_action(name)
	if not Controls.addon_author():
		# Reloading add-ons is for the add-ons given with --addons: no key, and no row in Controls, without.
		for name in Controls.ADDON_AUTHOR_ONLY:
			_default_keys.erase(name)
			_own_keys.erase(name)
			if InputMap.has_action(name):
				InputMap.erase_action(name)
	reload_factorio_keys()


## Zenith's own defaults of the controls 2.0 changed (Controls.OLD_DEFAULTS): 0.2.2's with
## Controls.old_defaults(), Factorio 2.1's without. Set on every call, as the switch can change while Zenith runs.
static func apply_old_defaults() -> void:
	for name in Controls.OLD_DEFAULTS:
		if _own_keys.has(name):
			var keys: Array = Controls.default_pair(name)
			_default_keys[name] = keys
			_own_keys[name] = keys.duplicate()


## factorio_keys.gd, loaded when used: it preloads this script (and paths.gd, which does too).
static func _factorio_keys_script() -> GDScript:
	return load("res://scripts/player/factorio_keys.gd")


## Issue #14: the keys set in Factorio's own controls (factorio_keys.gd: action -> [primary,
## alternative], -1 (FactorioKeys.SKIP) where Zenith's stays) become the defaults; bindings changed in
## Zenith's Settings still win. {} goes back to Zenith's own defaults.
static func apply_factorio_keys(keys: Dictionary) -> void:
	factorio_keys = keys
	for action in _own_keys:
		var merged: Array = (_own_keys[action] as Array).duplicate()
		var theirs: Array = keys.get(action, [])
		for slot in mini(2, theirs.size()):
			if int(theirs[slot]) != -1:  # FactorioKeys.SKIP
				merged[slot] = int(theirs[slot])
		_default_keys[action] = merged
	for action in _default_keys:
		_set_keys(action, keys_for(action))


## Reads Factorio's controls again (the setting was switched, or Factorio's changed), looking for
## config.ini afresh (`search_again`: past paths.gd's remembered install too, as the copy button does).
static func reload_factorio_keys(search_again := false) -> void:
	var on := bool(get_value("factorio", "use_factorio_keys"))
	_factorio_keys_source = _factorio_keys_lookup_source()
	_factorio_keys_looked = Time.get_ticks_msec()
	factorio_keys_lookups += 1
	_read_factorio_keys(_factorio_keys_script().config_path(search_again) if on else "")


## Factorio's controls from this config.ini ("": none, Zenith's own defaults).
static func _read_factorio_keys(file: String) -> void:
	_factorio_keys_file = file
	_factorio_keys_time = FileAccess.get_modified_time(file) if file != "" else 0
	var text := FileAccess.get_file_as_string(file) if file != "" else ""
	_factorio_keys_length = text.length()
	_factorio_keys_hash = text.hash()
	_factorio_keys_settled = _factorio_keys_time_settled()
	var r: Dictionary = _factorio_keys_script().report(text, Controls.old_defaults()) if file != "" else {"keys": {}, "copied": []}
	factorio_keys_changed = (r["copied"] as Array).size()
	apply_factorio_keys(r["keys"])


## What config.ini is looked for with: a change here means looking again.
static func _factorio_keys_lookup_source() -> String:
	return "%s|%s|%s|%s" % [arg_value("--factorio="), get_value("factorio", "executable"), arg_value("--factorio-config="),
		_factorio_keys_script().test_config]


## Issue #26: reads Factorio's controls again when its config.ini changed (or appeared) since they
## were read: main.gd asks when Zenith's window gets the focus back, so a key changed in Factorio
## meanwhile is followed without a restart. True when they were read again. Costs a file's modified
## time when nothing changed (plus reading and hashing its text in the few seconds after a write, as a
## write in the same second leaves the time as it was): config.ini is looked for again (paths.gd's search, Steam's libraries)
## only when where to look changed (Settings → Factorio install, --factorio=), when the file went, or
## with none found, at most once a minute.
static func refresh_factorio_keys() -> bool:
	if _default_keys.is_empty() or not bool(get_value("factorio", "use_factorio_keys")):
		return false
	var same_source := _factorio_keys_lookup_source() == _factorio_keys_source
	if same_source and _factorio_keys_file != "":
		var time := FileAccess.get_modified_time(_factorio_keys_file) if FileAccess.file_exists(_factorio_keys_file) else 0
		if time == _factorio_keys_time and (_factorio_keys_settled or not _factorio_keys_text_changed()):
			return false
		if time != 0:
			_read_factorio_keys(_factorio_keys_file)
			_notify("controls", "")
			return true
	elif same_source and Time.get_ticks_msec() - _factorio_keys_looked < FACTORIO_KEYS_LOOK_MSEC:
		return false
	var before := _factorio_keys_file
	reload_factorio_keys()
	if _factorio_keys_file == "" and before == "":
		return false
	_notify("controls", "")
	return true


## With no config.ini found, how often a focus-in looks for one again.
const FACTORIO_KEYS_LOOK_MSEC := 60000
## Seconds past config.ini's modified time after which a write would have moved it (FAT's two-second
## times, and a second either way between the file system's clock and the system's).
const FACTORIO_KEYS_SAME_SEC := 3


static func _factorio_keys_time_settled() -> bool:
	return Time.get_unix_time_from_system() >= _factorio_keys_time + FACTORIO_KEYS_SAME_SEC


## The modified time is the one read: was config.ini written again within that second? Reads its text
## (about 30 KB) only in the seconds after a write; settles once a check that late finds it the same.
static func _factorio_keys_text_changed() -> bool:
	var settled := _factorio_keys_time_settled()
	factorio_keys_text_checks += 1
	var text := FileAccess.get_file_as_string(_factorio_keys_file)
	if text.length() != _factorio_keys_length or text.hash() != _factorio_keys_hash:
		return true
	_factorio_keys_settled = settled
	return false


## Issue #26, Settings → Controls → "Copy keys from Factorio": looks for config.ini afresh and reads
## it, switches "Use the keys set in Factorio" on, and drops Zenith's saved binding of every action
## Factorio has, so each follows Factorio's: the key changed there, else Factorio's default from
## config.ini's "; " lines (Zenith's own default only where config.ini has neither). Zenith's own
## controls (the camera, the views) keep theirs. Returns factorio_keys.gd's report plus `file` (the
## config.ini read, "" when none was found), `reset` (the actions whose saved binding went) and
## `clashes`: [[action, code, [Zenith-only actions]]] for each copied key that one of Zenith's own
## controls (Factorio has none of them: camera tilt's Page Up, the debug line's F4 and the debug menu's
## Control + F12 in dev builds, an add-on's) also has, so the message can say so.
static func copy_factorio_keys() -> Dictionary:
	var fk := _factorio_keys_script()
	var file: String = fk.config_path(true)
	var out: Dictionary = fk.report(FileAccess.get_file_as_string(file) if file != "" else "", Controls.old_defaults())
	out["file"] = file
	out["old_keys"] = Controls.old_defaults()
	var reset: Array = []
	if file == "":
		out["reset"] = reset
		return out
	set_value("factorio", "use_factorio_keys", true, false)
	reload_factorio_keys()  # the search above was afresh: this finds the same file
	var theirs := {}
	for control in fk.ACTIONS:
		theirs[fk.ACTIONS[control]] = true
	for action in _default_keys.keys():
		if theirs.has(action) and _cfg.has_section_key("controls", action):
			_cfg.erase_section_key("controls", action)
			reset.append(action)
		_set_keys(action, keys_for(action))
	_cfg.save(path)
	_notify("controls", "")
	out["reset"] = reset
	var clashes: Array = []
	for c in out["copied"]:
		var code := int(c[3])
		if code <= 0 or keys_for(str(c[1]))[int(c[2])] != code:
			continue
		var own: Array = conflicts(str(c[1]), code).filter(func(a: String) -> bool: return not theirs.has(a))
		if not own.is_empty():
			clashes.append([str(c[1]), code, own])
	out["clashes"] = clashes
	return out


## A key event's code with its modifiers (KEY_MASK_SHIFT...), as OS.get_keycode_string names it.
static func event_code(ev: InputEventKey) -> int:
	var code := int(ev.physical_keycode if ev.physical_keycode != KEY_NONE else ev.keycode)
	if code in [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]:
		return code
	if ev.shift_pressed:
		code |= KEY_MASK_SHIFT
	if ev.ctrl_pressed:
		code |= KEY_MASK_CTRL
	if ev.alt_pressed:
		code |= KEY_MASK_ALT
	if ev.meta_pressed:
		code |= KEY_MASK_META
	return code


## The actions that can be rebound, in the order they were defined.
static func bindable_actions() -> Array:
	return _default_keys.keys()


## [primary, alternative] key codes bound to an action (0: none): saved ones, or the defaults.
static func keys_for(action: String) -> Array:
	load_settings()
	var saved := str(_cfg.get_value("controls", action, "\u0001"))
	if saved == "\u0001":
		return default_keys(action)
	var names := saved.split(",")
	var keys: Array = []
	var defaults := default_keys(action)
	for i in 2:
		var name := names[i].strip_edges() if i < names.size() else ""
		if name == DEFAULT_SLOT:
			keys.append(defaults[i])
		else:
			keys.append(OS.find_keycode_from_string(name) if name != "" else 0)
	return keys


## A saved binding's slot left at the default ("Shift+H,default"): it follows the default (Factorio's
## key when that changes), like the slot Factorio leaves alone; issue #26. Before, rebinding one slot
## saved the other as it was then, so a change in Factorio never reached it again.
const DEFAULT_SLOT := "default"


static func default_keys(action: String) -> Array:
	return (_default_keys.get(action, [0, 0]) as Array).duplicate()


## Binds one slot (0 primary, 1 alternative) of an action to a key code with modifiers; 0
## unbinds it.
static func bind_slot(action: String, slot: int, code: int) -> void:
	var keys := keys_for(action)
	keys[clampi(slot, 0, 1)] = code
	bind(action, keys)


## Binds an action to [primary, alternative] (a shorter list leaves the rest unbound); [] puts the
## defaults back.
static func bind(action: String, keys: Array) -> void:
	load_settings()
	var codes: Array = [0, 0]
	for i in mini(2, keys.size()):
		codes[i] = int(keys[i])
	if keys.is_empty() or codes == default_keys(action):
		if _cfg.has_section_key("controls", action):
			_cfg.erase_section_key("controls", action)
			_cfg.save(path)
		_notify("controls", action)
	else:
		var names: Array = []
		var defaults := default_keys(action)
		for i in 2:
			var code: int = codes[i]
			if code == int(defaults[i]):
				names.append(DEFAULT_SLOT)
			else:
				names.append(OS.get_keycode_string(code) if code != 0 else "")
		set_value("controls", action, ",".join(names))
	_set_keys(action, keys_for(action))


## The key bound to a slot, as Factorio writes it ("Shift + R"), or "" when unbound.
static func key_name(action: String, slot: int) -> String:
	var code: int = keys_for(action)[clampi(slot, 0, 1)]
	return key_text(code)


static func key_text(code: int) -> String:
	return OS.get_keycode_string(code).replace("+", " + ") if code != 0 else ""


## Both bindings, "W / Up", for help texts.
static func key_names(action: String) -> String:
	var names: Array = []
	for code in keys_for(action):
		if code != 0:
			names.append(key_text(code))
	return " / ".join(names) if not names.is_empty() else "(none)"


## The other actions using this key code (with the same modifiers) where both work.
static func conflicts(action: String, code: int) -> Array:
	var out: Array = []
	if code == 0:
		return out
	for other in _default_keys:
		if other != action and keys_for(other).has(code) and _meet(action, other):
			out.append(other)
	return out


## Where an add-on's action works (scripts/addons/addon_keys.gd): "global" (always, like Zenith's
## own controls) or "<add-on id>:camera" (only while that add-on has the camera and Zenith's own
## controls are off, so it may reuse their keys). Zenith's own actions aren't listed.
static var contexts := {}


## Two actions can both fire: then a shared key clashes. Pairs that share a key by design
## (Controls.SHARED) never both fire.
static func _meet(a: String, b: String) -> bool:
	if Controls.shared(a, b):
		return false
	var ca := str(contexts.get(a, ""))
	var cb := str(contexts.get(b, ""))
	return ca == cb or ca == "global" or cb == "global"


## An add-on's action with its default keys ([primary, alternative] codes) and where it works;
## the saved binding (if any) applies over them, and it shows in Settings → Controls.
static func add_action(action: String, keys: Array, context := "global") -> void:
	contexts[action] = context
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var codes: Array = [0, 0]
	for i in mini(2, keys.size()):
		codes[i] = int(keys[i])
	_default_keys[action] = codes
	_set_keys(action, keys_for(action))
	_notify("controls", action)  # the help (F1) lists it


## Takes an add-on's action away again (the add-on was switched off); its saved binding stays.
static func remove_action(action: String) -> void:
	_default_keys.erase(action)
	contexts.erase(action)
	if InputMap.has_action(action):
		InputMap.erase_action(action)
	_notify("controls", action)


static func _set_keys(action: String, keys: Array) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey:
			InputMap.action_erase_event(action, ev)
	for code in keys:
		if int(code) == 0:
			continue
		var ev := InputEventKey.new()
		ev.physical_keycode = int(code) & KEY_CODE_MASK
		ev.shift_pressed = int(code) & KEY_MASK_SHIFT != 0
		ev.ctrl_pressed = int(code) & KEY_MASK_CTRL != 0
		ev.alt_pressed = int(code) & KEY_MASK_ALT != 0
		ev.meta_pressed = int(code) & KEY_MASK_META != 0
		InputMap.action_add_event(action, ev)


## Whether the key opposite to the vehicle's motion brakes it to a stop and holds it there until let go
## (a departure from Factorio, which brakes and then reverses): `--vehicle-brake-hold=on|off` for one run,
## else Settings > Interface > Interaction (off by default). The mod does the braking (driving.lua `h`).
static func vehicle_brake_hold() -> bool:
	for arg in OS.get_cmdline_user_args():
		if arg == "--vehicle-brake-hold=on":
			return true
		if arg == "--vehicle-brake-hold=off":
			return false
	return bool(get_value("interface", "vehicle_brake_hold"))
