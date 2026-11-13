extends Node3D
## Builds the scene: lighting, the world mirror, movers, belt items, items on the ground,
## inserter arms, lamps, fluids and power, wires, ghosts, combat (health bars, deaths, shots), the player's avatar,
## the camera, the HUD and input, sound and effects (scripts/fx), and routes the bridge's messages to them.
## The sun and sky follow the game's time of day ("sky" messages): scripts/world/sky.gd draws each
## planet's sky, clouds and their shadows. On a space platform the
## backdrop is space (shaders/space_sky.gdshader), with the planet the platform is stopped at, and
## a panel shows the platform (scripts/ui/factorio/platform_panel.gd).
##
## The program starts in the menu (scripts/menu/front_end.gd: main menu, world selection, the
## server it launches, settings); the game's nodes are built by start_game() when a world is
## entered and freed by end_game() on the way back. Options that only make sense in a game
## (--factorio-port, --port, --open, --ui..., --camera..., --fx-demo, --no-menu) skip the menu and
## connect to 127.0.0.1:<--factorio-port, 34200> straight away, as before the menu existed.
##
## Command-line options (after `--`): --factorio-port=34200 --port=34201 --models=<dir> --addons=<dir>
## (scripts/addons/addon_loader.gd)
## --factorio-data=<Factorio's data folder, for item icons> --open=<unit> (player_input.gd)
## --review-shots=<dir>[@seconds] saves model review shots and quits (scripts/debug/review_shots.gd).
## --screenshot=<file.png>[@seconds] saves the window once, after that many seconds (default 10);
## with --clean-shot the HUD and the character are hidden first.
## --full-shot=<file.png or folder>[@seconds][,<width>x<height>] takes one the way add-ons do
## (api.view.screenshot: full detail, settled, the game held), after that many seconds (default 10).
## --plat-board=<platform index>@<seconds> sends plat_board then (0: down to the planet), to try
## a surface change without clicking. --ride=<platform index>@<seconds> rides the rocket of the
## nearest silo up to that platform, and --land=<seconds> goes down from the hub, without clicking
## (scripts/world/ride.gd).
## Sound options (--volume, --sfx-volume, --music-volume, --mute, --sfx-log...): fx_settings.gd.
## Settings (user://settings.cfg) and the menu's own options: scripts/menu/settings.gd, front_end.gd.

const ModelLods := preload("res://scripts/world/model_lods.gd")
const WorldMirror := preload("res://scripts/world/world.gd")
const MomentHold := preload("res://scripts/world/moment_hold.gd")
const UpsGovernor := preload("res://scripts/world/ups_governor.gd")
const MoverLayer := preload("res://scripts/world/movers.gd")
const RemoteFog := preload("res://scripts/world/remote_fog.gd")
const BeltItemLayer := preload("res://scripts/world/belt_items.gd")
const BeltLaneLayer := preload("res://scripts/world/belt_lanes.gd")
const GroundItemLayer := preload("res://scripts/world/ground_items.gd")
const DecorativeLayer := preload("res://scripts/world/decoratives.gd")
const InserterArmLayer := preload("res://scripts/world/inserter_arms.gd")
const LampLayer := preload("res://scripts/world/lamp_lights.gd")
const FluidsPowerLayer := preload("res://scripts/world/fluids_power.gd")
const WireLayer := preload("res://scripts/world/wires.gd")
const GhostLayer := preload("res://scripts/world/ghosts.gd")
const Predicted := preload("res://scripts/world/predicted.gd")
const CombatLayer := preload("res://scripts/world/combat.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
const ModFiles := preload("res://scripts/world/mod_files.gd")
const SpriteStandins := preload("res://scripts/world/sprite_standins.gd")
const Avatar := preload("res://scripts/player/avatar.gd")
const CameraRig := preload("res://scripts/player/camera_rig.gd")
const PlayerInput := preload("res://scripts/player/player_input.gd")
const Hud := preload("res://scripts/ui/hud.gd")
const LocaleNames := preload("res://scripts/world/locale_names.gd")
const Fx := preload("res://scripts/fx/fx.gd")
const TurretLayer := preload("res://scripts/world/turrets.gd")
const ReviewShots := preload("res://scripts/debug/review_shots.gd")
const AnimShots := preload("res://scripts/debug/anim_shots.gd")
const WorkingGlow := preload("res://scripts/world/working_glow.gd")
const FxSettings := preload("res://scripts/fx/fx_settings.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const ContactShade := preload("res://scripts/world/contact_shade.gd")
const AoZoom := preload("res://scripts/world/ao_zoom.gd")
const FrontEnd := preload("res://scripts/menu/front_end.gd")
const RocketLayer := preload("res://scripts/world/rockets.gd")
const CollectorLayer := preload("res://scripts/world/collectors.gd")
const Ride := preload("res://scripts/world/ride.gd")
const GameSwap := preload("res://scripts/menu/game_swap.gd")
const TerritoryLayer := preload("res://scripts/world/territories.gd")
const DemolisherLayer := preload("res://scripts/world/demolishers.gd")
const GuiAssets := preload("res://scripts/ui/factorio/gui_assets.gd")
const QualityMarks := preload("res://scripts/world/quality_marks.gd")
const AltArrows := preload("res://scripts/world/alt_arrows.gd")
const SunShadows := preload("res://scripts/world/sun_shadows.gd")
const AddonHost := preload("res://scripts/addons/addon_host.gd")
const InterfaceState := preload("res://scripts/ui/interface_state.gd")
const ViewPriority := preload("res://scripts/world/view_priority.gd")

## Options that start a game at once, without the menu.
const DIRECT_OPTIONS := ["--factorio-port=", "--port=", "--open=", "--ui=", "--ui-sample", "--ui-hold=",
	"--ui-craft=", "--ui-hover=", "--ui-press=", "--camera=", "--fx-demo", "--no-menu"]
const PlatformPanel := preload("res://scripts/ui/factorio/platform_panel.gd")
const PlayerTags := preload("res://scripts/world/player_tags.gd")
const PlanetSky := preload("res://scripts/world/sky.gd")
const PlanetSpin := preload("res://scripts/world/planet_spin.gd")
const Looks := preload("res://scripts/world/looks.gd")
const BeltBlur := preload("res://scripts/world/belt_blur.gd")
const VrSession := preload("res://scripts/vr/vr_session.gd")
const SPACE_SKY := preload("res://shaders/space_sky.gdshader")
## Roughly each planet's colour from orbit, for the space backdrop.
const PLANET_COLORS := {
	"nauvis": Color(0.26, 0.42, 0.52), "vulcanus": Color(0.62, 0.32, 0.16), "gleba": Color(0.42, 0.5, 0.28),
	"fulgora": Color(0.5, 0.38, 0.42), "aquilo": Color(0.62, 0.76, 0.86),
}

var world: WorldMirror
var movers: MoverLayer
var remote_fog: RemoteFog
var belt_items: BeltItemLayer
var belt_lanes: BeltLaneLayer
var ground_items: GroundItemLayer
var decoratives: DecorativeLayer
var arms: InserterArmLayer
var lamps: LampLayer
var working_glow: WorkingGlow
var fluids_power: FluidsPowerLayer
var wires: WireLayer
var ghosts: GhostLayer
var predicted: Predicted
var combat: CombatLayer
var avatar: Avatar
var rig: CameraRig
var hud: Hud
var input: PlayerInput
var fx: Fx
var turrets: TurretLayer
var front_end: FrontEnd
## Everything of a game, freed as one on the way back to the menu.
var _game: Node3D = null
## `bs` parts that came before the world was ready (`--belt-early-bs=off`: dropped, as before). The bridge
## loads lanes from the hello on and sends each lane's meta (`lm`) once: a part dropped here left its lanes
## read (`sl`) and checked (`pc`) but never placed, a whole underground at -62,-26 empty for good. They are
## handed over, in order, once the world is ready (prototypes known, so their items get icons).
var _early_bs: Array = []
const EARLY_BS_MAX := 4096
var platform_panel: PlatformPanel
var player_tags: PlayerTags
## Night vision equipment's light, 0..1 (it turns on by itself when dark, as in Factorio).
var _night_vision := 0.0
## Rockets leaving, cargo pods landing, asteroid chunks (Space Age).
var rockets: RocketLayer
## Asteroid collectors' arms catching chunks.
var collectors: CollectorLayer
var demolishers: DemolisherLayer
## Riding a rocket up to a platform's hub, life in the hub, a cargo pod down.
var ride: Ride
var quality_marks: QualityMarks
var alt_arrows: AltArrows
## Holds the game at 60 UPS by asking the bridge for less while the game runs slow.
var ups_governor: UpsGovernor
## Add-ons, for the whole run (menus too).
var addons: AddonHost

var _status_timer := 0.0
var _packets_before := 0
## The game's updates per second for the debug line: server ticks per real second, smoothed.
var _tick_before := -1
var _ups := 0.0
var _headless := DisplayServer.get_name() == "headless"
var _log_timer := 0.0
var _env: Environment
var ao_zoom: AoZoom
## The sun's shadow biases (Light3D.shadow_bias, shadow_normal_bias): see where the sun is made.
const SUN_SHADOW_BIAS := 0.05
const SUN_SHADOW_NORMAL_BIAS := 1.5
var _sun: DirectionalLight3D
var sun_shadows: SunShadows
## The look in use (Settings > Graphics > Look; add-ons add their own): light, tonemapping, grading.
var looks: Looks
## Time of day as drawn, eased towards the latest "sky" message. Daytime 0 is noon.
var _daytime := 0.15
var _darkness := 0.0
var _sky_daytime := 0.15
var _sky_darkness := 0.0
## On a space platform: space instead of the planet's sky.
var _space := false
var _space_material: ShaderMaterial
var _planet_sky: PlanetSky
var _planet_sky_res: Sky
var _space_sky: Sky
var _sky_planet := ""     # the planet drawn in space
var _sky_u := 0.0         # where along its way, drawn (planet_offset)
var _sky_goal := 0.0      # ... and as `plat` last said, when, and how fast it has been going a second
var _sky_goal_msec := 0
var _sky_rate := 0.0
## How far round each planet in the sky has turned (one turn per its day, from `plat` `days`).
var planet_spin := PlanetSpin.new()
## The solar system (`smap`) was asked for, to tell another mod's planets from other places.
var _asked_space_map := false


func _ready() -> void:
	# Factorio's own settings are the defaults (factorio_settings.gd), so they are read before any
	# is applied; the install is found the same way the graphics are (--factorio-data first).
	ItemIcons.configure_from_command_line()
	Settings.reload_factorio_settings()
	Settings.apply_startup(DisplayServer.window_get_size().y)
	Settings.apply_window(get_tree().root)
	FxSettings.load_settings()
	ModelLibrary.configure_from_command_line()
	ModFiles.configure_from_command_line()
	# Names in the language set in Factorio, unless --factorio-locale says otherwise.
	var locale = Settings.factorio_default("general", "locale")
	if locale != null:
		LocaleNames.language = str(locale)
	LocaleNames.configure_from_command_line()
	PlayerInput.define_actions()
	Settings.apply_bindings()
	Settings.listen(_on_setting_changed)
	# "Automatic" UI scale follows the window's height and full screen's Resolution scales to the
	# monitor, so a resize (or the window going to another monitor) can change them.
	get_tree().root.size_changed.connect(func() -> void: Settings.apply_window_scales(get_tree().root))
	Settings.apply_window_scales(get_tree().root)

	Bridge.welcomed.connect(_on_welcome)
	Bridge.message_received.connect(_on_message)
	Bridge.connection_lost.connect(_on_connection_lost)
	# Console answers as soon as they are read, ahead of the messages waiting their turn (the debug menu).
	var answer := func(msg: Dictionary) -> void:
		if hud != null:
			hud.ui.model.answer_read(msg)
	Bridge.answer_read.connect(answer)

	# VR (--vr with --xr-mode on): the headset, controllers and the HUD on a panel.
	if VrSession.requested():
		var vr := VrSession.new()
		vr.name = "VR"
		vr.main = self
		add_child(vr)

	front_end = FrontEnd.new()
	front_end.main = self
	add_child(front_end)
	# Add-ons (scripts/addons/, docs/ADDONS.md), after the menu: they get input before it does.
	addons = AddonHost.new()
	addons.main = self
	add_child(addons)
	# Their looks are registered now: a saved MSAA under a look with passes becomes SMAA, before anything
	# is drawn (Settings.MSAA_UNDER_LOOK).
	Settings.settle_antialiasing(get_tree().root)
	_forward_while_joining()
	var direct := false
	for option in DIRECT_OPTIONS:
		if Settings.has_arg(option):
			direct = true
	if direct:
		start_game()
		Bridge.connect_to("127.0.0.1", Bridge.factorio_port, Bridge.listen_port)
		front_end.open_direct("127.0.0.1:%d" % Bridge.factorio_port)
	else:
		front_end.open_menu()

	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--screenshot="):
			var spec := arg.get_slice("=", 1)
			var delay := 10.0
			if spec.contains("@"):
				delay = float(spec.get_slice("@", 1))
				spec = spec.get_slice("@", 0)
			_save_screenshot_later(spec, delay)
		elif arg.begins_with("--full-shot="):
			_full_shot_later(arg.get_slice("=", 1))
		elif arg.begins_with("--plat-board="):
			var spec := arg.get_slice("=", 1)
			_board_later(int(spec.get_slice("@", 0)), float(spec.get_slice("@", 1)) if spec.contains("@") else 5.0)
		elif arg.begins_with("--ride="):
			var spec := arg.get_slice("=", 1)
			_ride_later(int(spec.get_slice("@", 0)), float(spec.get_slice("@", 1)) if spec.contains("@") else 8.0)
		elif arg.begins_with("--land="):
			_land_later(float(arg.get_slice("=", 1)))


func _board_later(index: int, delay: float) -> void:
	await get_tree().create_timer(delay).timeout
	Bridge.send({"t": "plat_board", "i": index})


## Opens the silo nearest the character and rides its rocket to platform `index`, as the Ride
## button does.
func _ride_later(index: int, delay: float) -> void:
	await get_tree().create_timer(delay).timeout
	if world == null:
		return
	var best: WorldMirror.Rec = null
	for key in world.entities:
		var r: WorldMirror.Rec = world.entities[key]
		var p = world.protos.entity(r.proto_id)
		if p != null and p.type == "rocket-silo" and (best == null or r.pos.distance_to(avatar.ground_position()) < best.pos.distance_to(avatar.ground_position())):
			best = r
	if best == null:
		print("--ride: no rocket silo in the world")
		return
	Bridge.send({"t": "open", "u": best.unit, "p": best.proto_id, "x": best.fixed.x, "y": best.fixed.y})
	await get_tree().create_timer(0.5).timeout
	Bridge.send({"t": "ride", "u": best.unit, "to": index})
	Bridge.send({"t": "close"})


func _land_later(delay: float) -> void:
	await get_tree().create_timer(delay).timeout
	Bridge.send({"t": "land"})


## A console command from the chat (/...): over RCON when this client started the server.
func _run_command(command: String) -> String:
	if not _has_rcon():
		return "Commands need RCON: start the server from this client's menu"
	return await front_end.launcher.rcon.run(get_tree(), command)


func _has_rcon() -> bool:
	var launcher = front_end.launcher if front_end != null else null
	return launcher != null and launcher.is_running() and launcher.rcon.is_open()


func in_game() -> bool:
	return _game != null


## Builds the game's nodes: the world mirror and its layers, the avatar, camera, HUD, input, sound.
func start_game() -> void:
	if _game != null:
		return
	_game = Node3D.new()
	_game.name = "Game"
	add_child(_game)
	move_child(_game, 0)
	_build_environment()

	world = WorldMirror.new()
	world.name = "World"
	world.sun = _sun
	_game.add_child(world)

	movers = MoverLayer.new()
	movers.name = "Movers"
	movers.protos = world.protos
	movers.world = world
	_game.add_child(movers)

	ups_governor = UpsGovernor.new()
	ups_governor.name = "UpsGovernor"
	ups_governor.changed.connect(_apply_game_settings)
	ups_governor.budget_changed.connect(Bridge.set_work_budget)
	_game.add_child(ups_governor)

	remote_fog = RemoteFog.new()
	remote_fog.name = "RemoteFog"
	_game.add_child(remote_fog)
	movers.fog = remote_fog
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--robot-probe="):
			var probe: Node = preload("res://scripts/debug/robot_probe.gd").new()
			probe.movers = movers
			probe.out_path = arg.get_slice("=", 1)
			add_child(probe)
		elif arg.begins_with("--ao-probe="):
			var ao_probe: Node = preload("res://scripts/debug/ao_probe.gd").new()
			var aspec := arg.get_slice("=", 1).split("@")
			ao_probe.main = self
			ao_probe.out_path = aspec[0]
			if aspec.size() > 1:
				ao_probe.seconds = float(aspec[1])
			add_child(ao_probe)
		elif arg.begins_with("--settings-probe="):
			var settings_probe: Node = preload("res://scripts/debug/settings_probe.gd").new()
			var sspec := arg.get_slice("=", 1).split("@")
			settings_probe.main = self
			settings_probe.out_dir = sspec[0]
			if sspec.size() > 1:
				settings_probe.seconds = float(sspec[1])
			add_child(settings_probe)
		elif arg.begins_with("--glide-probe="):
			var glide: Node = preload("res://scripts/debug/glide_probe.gd").new()
			glide.main = self
			glide.out_path = arg.get_slice("=", 1)
			add_child(glide)
		elif arg.begins_with("--belt-path-probe="):
			var belts: Node = preload("res://scripts/debug/belt_path_probe.gd").new()
			belts.main = self
			belts.out_path = arg.get_slice("=", 1)
			add_child(belts)
		elif arg.begins_with("--quit-probe="):
			var quitter: Node = preload("res://scripts/debug/quit_probe.gd").new()
			quitter.main = self
			quitter.seconds = float(arg.get_slice("=", 1))
			add_child(quitter)
		elif arg.begins_with("--soak-probe="):
			var soak: Node = preload("res://scripts/debug/soak_probe.gd").new()
			var spec := arg.get_slice("=", 1).split("@")
			soak.main = self
			soak.out_path = spec[0]
			if spec.size() > 1:
				soak.minutes = float(spec[1])
			add_child(soak)
		elif arg.begins_with("--predict-probe="):
			var predict: Node = preload("res://scripts/debug/predict_probe.gd").new()
			var pspec := arg.get_slice("=", 1).split("@")
			predict.main = self
			predict.out_path = pspec[0]
			if pspec.size() > 1:
				predict.builds = int(pspec[1])
			add_child(predict)
		elif arg.begins_with("--ups-probe="):
			var ups_probe: Node = preload("res://scripts/debug/ups_probe.gd").new()
			ups_probe.main = self
			ups_probe.out_path = arg.substr(arg.find("=") + 1)
			add_child(ups_probe)
	remote_fog.world = world

	belt_items = BeltItemLayer.new()
	belt_items.name = "BeltItems"
	belt_items.protos = world.protos
	belt_items.world = world
	_game.add_child(belt_items)
	belt_items.old_bridge.connect(func() -> void:
		hud.show_message("The bridge mod (%s) is older than this Zenith and sends belt items the old way: items on belts near you aren't drawn. Update the mod." % Bridge.mod_version))
	belt_lanes = BeltLaneLayer.new()
	belt_lanes.name = "BeltLanes"
	belt_lanes.protos = world.protos
	belt_lanes.world = world
	belt_lanes.distance = clampi(int(Settings.get_value("graphics", "belt_distance")), 0, 640)
	belt_lanes.near = mini(belt_lanes.distance, BeltLaneLayer.MOVING_MAX)
	belt_lanes.cap = BeltLaneLayer.cap_of(float(Settings.get_value("graphics", "belt_updates")))
	_game.add_child(belt_lanes)
	belt_items.lanes = belt_lanes

	ground_items = GroundItemLayer.new()
	ground_items.name = "GroundItems"
	ground_items.protos = world.protos
	_game.add_child(ground_items)

	decoratives = DecorativeLayer.new()
	decoratives.name = "Decoratives"
	decoratives.world = world
	_game.add_child(decoratives)

	arms = InserterArmLayer.new()
	arms.name = "InserterArms"
	arms.protos = world.protos
	arms.world = world
	_game.add_child(arms)

	lamps = LampLayer.new()
	lamps.name = "Lamps"
	lamps.protos = world.protos
	lamps.world = world
	_game.add_child(lamps)
	working_glow = WorkingGlow.new()
	working_glow.name = "WorkingGlow"
	working_glow.world = world
	_game.add_child(working_glow)

	fluids_power = FluidsPowerLayer.new()
	fluids_power.name = "FluidsPower"
	fluids_power.world = world
	_game.add_child(fluids_power)
	lamps.power = fluids_power

	wires = WireLayer.new()
	wires.name = "Wires"
	wires.world = world
	_game.add_child(wires)
	lamps.fog = remote_fog
	wires.fog = remote_fog

	ghosts = GhostLayer.new()
	ghosts.name = "Ghosts"
	ghosts.world = world
	_game.add_child(ghosts)

	predicted = Predicted.new()
	predicted.name = "Predicted"
	predicted.world = world
	_game.add_child(predicted)

	avatar = Avatar.new()
	avatar.name = "Avatar"
	_game.add_child(avatar)

	combat = CombatLayer.new()
	combat.name = "Combat"
	combat.world = world
	combat.movers = movers
	combat.avatar = avatar
	_game.add_child(combat)

	rig = CameraRig.new()
	rig.name = "CameraRig"
	rig.target = avatar
	decoratives.rig = rig
	_game.add_child(rig)
	if ReviewShots.requested():
		var shots := ReviewShots.new()
		shots.rig = rig
		shots.avatar = avatar
		shots.game = _game
		_game.add_child(shots)
	if AnimShots.requested():
		var clip := AnimShots.new()
		clip.game = _game
		_game.add_child(clip)

	hud = Hud.new()
	hud.name = "Hud"
	_game.add_child(hud)
	hud.screen.protos = world.protos
	hud.ui.run_command = _run_command
	hud.ui.has_rcon = _has_rcon
	hud.ui.debug_menu.main = self  # its benchmarks and tests drive the world, camera and probes
	remote_fog.model = hud.ui.model  # roboports reveal under the remote view's fog too (H13)

	rockets = RocketLayer.new()
	rockets.name = "Rockets"
	rockets.movers = movers
	rockets.model = hud.ui.model
	var territories := TerritoryLayer.new()
	territories.name = "Territories"
	territories.model = hud.ui.model
	_game.add_child(territories)
	demolishers = DemolisherLayer.new()
	demolishers.name = "Demolishers"
	demolishers.model = hud.ui.model
	demolishers.protos = world.protos
	_game.add_child(demolishers)
	_game.add_child(rockets)
	collectors = CollectorLayer.new()
	collectors.name = "Collectors"
	collectors.model = hud.ui.model
	collectors.world = world
	_game.add_child(collectors)
	world.animator.collectors = collectors
	quality_marks = QualityMarks.new()
	quality_marks.name = "QualityMarks"
	quality_marks.world = world
	quality_marks.belt_items = belt_items
	quality_marks.model = hud.ui.model
	quality_marks.alt_mode = hud.ui.alt_mode
	hud.ui.alt_mode_changed.connect(func(on: bool) -> void: quality_marks.alt_mode = on)
	_game.add_child(quality_marks)
	alt_arrows = AltArrows.new()
	alt_arrows.name = "AltArrows"
	alt_arrows.world = world
	alt_arrows.model = hud.ui.model
	alt_arrows.fog = remote_fog
	alt_arrows.alt_mode = hud.ui.alt_mode
	hud.ui.alt_mode_changed.connect(func(on: bool) -> void: alt_arrows.alt_mode = on)
	_game.add_child(alt_arrows)

	platform_panel = PlatformPanel.new()
	platform_panel.name = "PlatformPanel"
	hud.add_child(platform_panel)
	hud.move_child(platform_panel, 0)  # under the windows, as Factorio's HUD panels are
	hud.ui.platform_panel = platform_panel  # under the minimap, top right (factorio_ui.gd layout)
	# Mech armour changes how the character is drawn (avatar.set_armor).
	var armor_changed := func() -> void:
		avatar.set_armor(str(hud.ui.model.stack_at("armor", 1).get("item", "")))
	hud.ui.model.inventory_changed.connect(armor_changed)
	# Other players' characters wear their armour's look too (`pl` says what each wears).
	var looks_changed := func() -> void:
		var looks := {}
		for p: Dictionary in hud.ui.model.players:
			if int(p["unit"]) != 0 and str(p.get("armor", "")) != "":
				looks[int(p["unit"])] = Avatar.look_for(str(p["armor"]))
		movers.creatures.set_looks(looks)
	hud.ui.model.players_changed.connect(looks_changed)
	# Lightning rods and collectors glow where a strike lands (anim.gd).
	hud.ui.model.lightning_struck.connect(world.animator.strike)
	# And the sky flashes with each strike (the bolt itself is fx.gd's, from the same `lt`).
	var sky_flash := func(at: Vector2, _caught: bool) -> void:
		if _planet_sky != null:
			_planet_sky.strike_flash(at.distance_to(Vector2(avatar.position.x, avatar.position.z)))
	hud.ui.model.lightning_struck.connect(sky_flash)
	# Another mod's planet goes in a platform's sky once the solar system says it is one.
	hud.ui.model.space_map_changed.connect(func() -> void: _show_planet_for(platform_panel.current()))

	player_tags = PlayerTags.new()
	player_tags.name = "PlayerTags"
	player_tags.movers = movers
	player_tags.model = hud.ui.model
	_game.add_child(player_tags)

	input = PlayerInput.new()
	input.name = "Input"
	input.world = world
	input.remote_fog = remote_fog
	input.rig = rig
	input.hud = hud
	input.combat = combat
	input.avatar = avatar
	input.movers = movers
	input.wires = wires
	input.predicted = predicted
	_game.add_child(input)
	fluids_power.input = input

	fx = Fx.new()
	fx.name = "Fx"
	fx.world = world
	fx.movers = movers
	fx.combat = combat
	fx.avatar = avatar
	fx.rig = rig
	_game.add_child(fx)
	turrets = TurretLayer.new()
	turrets.name = "Turrets"
	turrets.movers = movers
	turrets.fx = fx
	rockets.fx = fx
	turrets.world = world
	_game.add_child(turrets)
	world.animator.turrets = turrets
	world.animator.rockets = rockets
	movers.vehicles.model = hud.ui.model
	movers.vehicles.turrets = turrets
	movers.vehicles.sprites = fx.sprites
	ride = Ride.new()
	ride.name = "Ride"
	ride.avatar = avatar
	ride.rig = rig
	ride.rockets = rockets
	ride.ui = hud.ui
	ride.input = input
	_game.add_child(ride)
	_apply_game_settings()
	addons.game_started()


## Frees the game's nodes and disconnects (the menu takes over).
func end_game() -> void:
	Bridge.disconnect_from()
	if _game == null:
		return
	addons.game_ended()  # while the game's nodes are still there
	if rig != null and rig.first_person:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_game.queue_free()
	_game = null
	world = null
	movers = null
	belt_items = null
	ground_items = null
	decoratives = null
	arms = null
	lamps = null
	fluids_power = null
	wires = null
	ghosts = null
	predicted = null
	combat = null
	avatar = null
	rig = null
	hud = null
	platform_panel = null
	player_tags = null
	rockets = null
	collectors = null
	ride = null
	quality_marks = null
	input = null
	fx = null
	turrets = null
	_env = null
	ao_zoom = null
	_sun = null
	# The space sky belonged to the freed environment.
	_space_material = null
	_space = false
	_planet_sky = null
	_planet_sky_res = null
	_space_sky = null
	planet_spin = PlanetSpin.new()


## Input to the game on or off (off while a menu covers it): walking, mining, keys.
func set_game_input(on: bool) -> void:
	if input == null:
		return
	input.set_process(on)
	input.set_process_unhandled_input(on)
	hud.ui.set_process_unhandled_input(on)
	if not on:
		Bridge.send({"t": "walk", "d": -1})
		Bridge.send({"t": "shoot", "m": -1, "x": 0, "y": 0})


func loaded_chunks() -> int:
	return world.loaded_chunk_count() if world != null else 0


## Factorio's UI scale keys work everywhere, in the menus too (Ctrl+= / Ctrl+- / Ctrl+0).
func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return
	if _game != null and hud.ui.typing():
		return
	if event.is_action("increase_ui_scale", true):
		Settings.step_ui_scale(1)
	elif event.is_action("decrease_ui_scale", true):
		Settings.step_ui_scale(-1)
	elif event.is_action("reset_ui_scale", true):
		Settings.set_value("interface", "ui_scale", "auto")
	else:
		return
	get_viewport().set_input_as_handled()
	if _game != null:
		hud.show_message("UI scale %d%%" % roundi(Settings.chosen_ui_scale() * 100.0))


func _on_setting_changed(section: String, _key: String) -> void:
	if section in ["graphics", "interface", "camera"]:
		_apply_game_settings()


## Zenith's clouds: the Clouds setting, unless the look in use draws its own.
## A look with passes switched on in a running game: a saved MSAA becomes SMAA (Settings.MSAA_UNDER_LOOK)
## and is applied, and a message says so.
func _note_look_antialiasing(_look := "") -> void:
	if not Settings._addons_started or not Settings.switch_msaa_for_look():
		return
	Settings.apply_antialiasing(get_tree().root)
	if hud != null:
		hud.show_message("Anti-aliasing: SMAA in place of MSAA, which the look in use breaks at every edge.")


func _apply_clouds(_look := "") -> void:
	if _planet_sky != null and looks != null:
		_planet_sky.set_clouds(bool(Settings.get_value("graphics", "clouds")) and looks.own_clouds())


## Settings that apply to a running game: shadows, ambient occlusion, brightness, contrast and
## saturation, view distance, help, F4.
func _apply_game_settings() -> void:
	if _game == null:
		return
	looks.lift()
	Settings.apply_environment(_env)
	_sun.shadow_enabled = Settings.shadow_size() > 0
	if _sun.shadow_enabled:
		# Atlas, splits, distance (fitted to the view), blending and filter by quality (sun_shadows.gd).
		sun_shadows.distance_cap = clampf(float(Settings.get_value("graphics", "shadow_distance")), 0.0, 1000.0)
		sun_shadows.apply_quality(str(Settings.get_value("graphics", "shadows")))
	Settings.apply_ssao(_env)
	ContactShade.set_enabled(bool(Settings.get_value("graphics", "contact_shading")), world.chunks.values())
	looks.settle(str(Settings.get_value("graphics", "look")))
	_apply_clouds()
	# Every distance the bridge works for in the game's tick, under the player's own setting while the
	# UPS governor holds it back (ups_governor.gd).
	var held := ups_governor
	world.view_radius = clampi(int(held.limit("view", float(Settings.get_value("graphics", "view_radius")))), 1, WorldMirror.MAX_VIEW_RADIUS)
	ModelLods.apply_quality(str(Settings.get_value("graphics", "lod_quality")), get_viewport())
	world.far_chunks.enabled = bool(Settings.get_value("graphics", "merge_far"))
	var animate_cards := bool(Settings.get_value("graphics", "animate_mod_buildings"))
	if SpriteStandins.animate != animate_cards:
		SpriteStandins.animate = animate_cards
		SpriteStandins.clear()  # the cards are made again, still or moving
	belt_lanes.distance = clampi(int(held.limit("far", float(Settings.get_value("graphics", "belt_distance")))), 0, 640)
	# Items move as far out as the cap allows, within the distance (an add-on may ask for less: near).
	belt_lanes.near = clampi(int(held.limit("near", float(belt_lanes.distance))), 0, BeltLaneLayer.MOVING_MAX)
	belt_lanes.cap = BeltLaneLayer.cap_of(held.limit("updates", BeltLaneLayer.cap_wanted(float(Settings.get_value("graphics", "belt_updates")))))
	# Automatic: belt_lanes.gd moves its own cap with the room there is, under the governor's hold.
	belt_lanes.auto = int(Settings.get_value("graphics", "belt_updates")) == BeltLaneLayer.AUTO
	belt_lanes.updates_hold = held.limit("updates", BeltLaneLayer.UNLIMITED)
	belt_lanes.governor = held
	belt_lanes.smooth = bool(Settings.get_value("graphics", "belt_smooth")) and held.limit("smooth", 1.0) >= 1.0
	decoratives.set_options(bool(Settings.get_value("graphics", "decoratives")), float(Settings.get_value("graphics", "decorative_density")))
	decoratives.distance = clampf(float(Settings.get_value("graphics", "decorative_distance")), 32.0, 320.0)
	decoratives.set_grass(str(Settings.get_value("graphics", "grass_3d")))
	Bridge.decoratives = decoratives.enabled
	Bridge.mod_windows = bool(Settings.get_value("interface", "mod_windows"))
	world.set_focus_radius(clampi(int(held.limit("entity", float(Settings.get_value("graphics", "entity_radius")))), 16, 256))
	hud.ui.map_cache.refresh_scale = held.limit("map", 1.0)
	Bridge.set_update_rate(int(held.limit("rate", 0.0)))
	Settings.fps_hold = int(held.limit("fps", 0.0))
	Engine.max_fps = Settings.fps_limit()
	if Bridge.world_ready:
		_apply_priority()
	hud.help.visible = bool(Settings.get_value("interface", "show_help"))
	hud.ui.debug_overlay = bool(Settings.get_value("interface", "debug_overlay"))
	rig.apply_settings()


## Screenshots saved so far (--screenshot): reading the frame back and encoding the PNG stalls that
## frame half a second, which --stutter-probe marks (`shot`) so tools leave those frames out.
static var screenshots := 0


func _save_screenshot_later(path: String, delay: float) -> void:
	await get_tree().create_timer(delay).timeout
	# A still picture shows nothing moving: belts drawn without their motion smear.
	BeltBlur.sharp_frames(4)
	# --clean-shot: just the world, for model screenshots (the character stands on the model).
	if OS.get_cmdline_user_args().has("--clean-shot") and _game != null:
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
		InterfaceState.set_hidden(&"clean_shot", true, get_tree())  # the icons over entities too
		hud.visible = false
		avatar.visible = false
		await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var err := get_viewport().get_texture().get_image().save_png(path)
	screenshots += 1
	print("screenshot %s: %s" % [path, error_string(err)])


## --full-shot: a screenshot through the add-on host, as F12 in the Cinematic camera takes one.
func _full_shot_later(spec: String) -> void:
	var options := {}
	if spec.contains(","):
		var wh := spec.get_slice(",", 1).split("x")
		spec = spec.get_slice(",", 0)
		if wh.size() == 2:
			options["size"] = Vector2i(int(wh[0]), int(wh[1]))
	var delay := 10.0
	if spec.contains("@"):
		delay = float(spec.get_slice("@", 1))
		spec = spec.get_slice("@", 0)
	await get_tree().create_timer(delay).timeout
	if addons != null:
		print("full-shot: %s" % addons.screenshot(spec if spec != "" else null, options))


var _came_from_factorio := false


## Started by Ctrl+F9 in Factorio: joining a big save takes a while, so the window comes forward
## at once with its loading screen, or the key looks dead meanwhile. Factorio stays as it is until
## the welcome (it is minimised then), in case Zenith can't join.
func _forward_while_joining() -> void:
	if not "--from-factorio" in OS.get_cmdline_user_args() or DisplayServer.get_name() == "headless":
		return
	await get_tree().process_frame
	await get_tree().process_frame
	if not _came_from_factorio:
		GameSwap.show_client(false)


## Settings > Graphics > Give the server the CPU first (`--server-first=on|off`, on): with the server on
## this PC (connected to 127.0.0.1, localhost or ::1), the client's process runs at below-normal priority
## from the welcome on, so Factorio's tick gets a core first whenever every core is busy. Measured on
## the owner's 4-core PC at -62,-26 (tmp_ups probe, docs/RUNNING.md): the join's first 75 s (the bridge's
## first load, the client's chunks and movers; Godot's main thread at 85% of a core, the four cores at 90%)
## ran the game at 34 UPS median at normal priority and 56 below; steady 59-60 either way, the client's
## frame rate unchanged (60, vsync). Hold 60 UPS then steps the bridge down less during the join.
## Windows: wmic (below normal 16384, normal 32); elsewhere renice. Off puts it back to normal.
var _priority_low := false


func _apply_priority() -> void:
	var want := bool(Settings.get_value("graphics", "server_first")) and Settings.arg_value("--server-first=") != "off" \
		and Bridge.factorio_host in ["127.0.0.1", "localhost", "::1"]
	if want == _priority_low:
		return
	_priority_low = want
	var pid := OS.get_process_id()
	if OS.get_name() == "Windows":
		OS.create_process("wmic", ["process", "where", "processid=%d" % pid, "call", "setpriority", "16384" if want else "32"], false)
	else:
		OS.create_process("renice", ["-n", "5" if want else "0", "-p", str(pid)], false)
	print("server on this PC: the client's process priority %s (Settings > Graphics > Give the server the CPU first)"
		% ("below normal" if want else "back to normal"))


func _on_welcome(msg: Dictionary) -> void:
	if _game == null:
		return
	_apply_priority()
	# Started by Ctrl+F9 in Factorio (server/factorio-with-zenith.ps1): come to the front over it.
	if "--from-factorio" in OS.get_cmdline_user_args() and not _came_from_factorio:
		_came_from_factorio = true
		GameSwap.show_client(bool(Settings.get_value("factorio", "minimize_factorio")))
	world.reset()
	world.surface_index = int(msg.get("si", -1))
	world.replay_dec = decoratives.handle
	movers.reset()
	belt_items.reset()
	_early_bs.clear()
	belt_lanes.reset()
	ground_items.reset()
	decoratives.reset()
	arms.reset()
	working_glow.reset()
	fluids_power.reset()
	wires.reset()
	ghosts.reset()
	predicted.reset()
	combat.reset()
	fx.reset()
	turrets.reset()
	rockets.reset()
	collectors.reset()
	quality_marks.reset()
	hud.reset()
	avatar.unit = int(msg.get("u", 0))
	movers.puppet_unit = avatar.unit
	avatar.snap_to(Vector2(int(msg.get("x", 0)), int(msg.get("y", 0))) / 256.0)
	rig.global_position = avatar.global_position
	world.set_focus(avatar.ground_position())
	hud.ui.model.set_character_surface(int(msg.get("si", 0)))
	platform_panel.reset()
	# From the start, not only after a trip: launches on other planets aren't drawn on this one.
	rockets.surface = str(msg.get("surface", ""))
	platform_panel.surface_changed(int(msg.get("pf", 0)), str(msg.get("planet", "")))
	_planet_sky.set_planet(str(msg.get("planet", "nauvis")))
	fx.set_planet(str(msg.get("planet", "nauvis")), int(msg.get("pf", 0)) > 0)
	_set_space(int(msg.get("pf", 0)) > 0)
	var mode := "server" if msg.get("mp", false) else "single-player"
	hud.show_message("Connected to Factorio (%s, surface %s)" % [mode, str(msg.get("surface", "?"))])


## The character is on another surface now (a space platform or back): drop the world, keep
## the prototypes, inventory and the rest of the UI, and let the world subscribe around it again.
func _on_surface(msg: Dictionary) -> void:
	world.reset(true, int(msg.get("si", -1)))
	world.surface_index = int(msg.get("si", -1))
	movers.reset()
	belt_items.reset()
	belt_lanes.reset()
	ground_items.reset()
	decoratives.reset(true)  # the ids stay: no `dprotos` for a surface
	arms.reset()
	working_glow.reset()
	fluids_power.reset()
	wires.reset()
	ghosts.reset()
	predicted.reset()
	combat.reset()
	fx.reset()
	turrets.reset(true)  # the bridge still sends the game's beams (`pj`)
	rockets.reset()
	rockets.surface = str(msg.get("surface", ""))
	collectors.reset()
	quality_marks.reset()
	hud.screen.close_local()
	hud.set_mining(-1)
	hud.ui.map_cache.reset()
	var at := Vector2(int(msg.get("x", 0)), int(msg.get("y", 0))) / 256.0
	# `view`: the remote view looks at another surface; the character stays where it is, unseen.
	var viewing := int(msg.get("view", 0)) == 1
	avatar.visible = not viewing
	if viewing:
		hud.ui.model.set_map_surface(int(msg.get("si", 0)))
		world.set_focus(at)
	else:
		hud.ui.model.set_character_surface(int(msg.get("si", 0)))
		avatar.snap_to(at)
		# Riding a pod the camera follows the ride (ride.gd), which fades over the change.
		if not ride.riding():
			rig.global_position = avatar.global_position
		world.set_focus(avatar.ground_position())
	var pf := int(msg.get("pf", 0))
	platform_panel.surface_changed(pf, str(msg.get("planet", "")))
	_planet_sky.set_planet(str(msg.get("planet", "nauvis")))
	fx.set_planet(str(msg.get("planet", "nauvis")), pf > 0)
	_set_space(pf > 0)
	hud.show_message("Now on %s" % (str(msg.get("surface", "?")) if pf > 0 else LocaleNames.space_location(str(msg.get("planet", msg.get("surface", "?"))))))


func _on_message(msg: Dictionary) -> void:
	if _game == null:
		return
	fx.handle(msg)  # first: it looks up entities and movers before they are removed
	match str(msg.get("t", "")):
		"me":
			avatar.update_from(ride.handle_me(msg))
			movers.puppet_unit = avatar.unit
			hud.set_mining(avatar.mining)
			hud.set_health(avatar.health, avatar.max_health)
			hud.set_shield(int(msg.get("sd", 0)), int(msg.get("msd", 0)))
			hud.ui.death_screen.alive()
		"mv":
			movers.handle(msg)
		# Live state is sent at once, but on a real game the prototype dictionaries take several
		# ticks to arrive; an item drawn before its name is known would never get its icon.
		"bs":
			if Bridge.world_ready:
				if not _early_bs.is_empty():
					var early := _early_bs
					_early_bs = []
					for m: Dictionary in early:
						belt_items.handle(m)
				belt_items.handle(msg)
			elif _early_bs.size() < EARLY_BS_MAX and Settings.arg_value("--belt-early-bs=") != "off":
				_early_bs.append(msg)
		# (A bridge mod from before `bs` (0.1.4) answers our hello with `bi`, which nothing draws now:
		# belt_items.gd says so once, old_bridge, and the player is told.)
		"bi":
			if Bridge.world_ready:
				belt_items.handle(msg)
		"bfar":
			if Bridge.world_ready:
				belt_lanes.handle(msg)
		"ih":
			if Bridge.world_ready:
				arms.handle(msg)
		"gi":
			if Bridge.world_ready:
				ground_items.handle(msg)
		"dprotos", "dec":
			decoratives.handle(msg)
			if str(msg.get("t", "")) == "dec":
				world.keep_dec(msg)
		"iuse":
			decoratives.handle(msg)  # the tiles items lay: floors nothing grows on
			hud.ui.model.handle(msg)
		"hp":
			combat.handle_health(msg)
		"tf":
			turrets.handle_fire(msg)
		"ts":
			turrets.handle_states(msg)
			fx.weapons.prewarm_fights()  # turrets in view: their effects made before the first shot
			movers.creatures.prewarm()
		"acol":
			collectors.handle(msg)
		"pj":
			turrets.handle_projectiles(msg)  # fx.gd's weapon_fx.gd draws them too (fx.handle above)
		"shot", "gf":
			pass  # fx.gd (weapon_fx.gd) draws them
		"died":
			combat.handle_died(msg)
			var dead = world.protos.entity(int(msg.get("p", 0)))
			if dead != null:
				movers.creatures.died_at(dead.name, Vector3(int(msg.get("x", 0)) / 256.0, 0.0, int(msg.get("y", 0)) / 256.0))
		"en":
			movers.creatures.handle_attacks(msg)
			fx.weapons.prewarm_fights()
			movers.creatures.prewarm()
		"guns":
			hud.set_guns(int(msg.get("sel", 1)), _array(msg.get("l")))
		"fl", "pw", "ht":
			if Bridge.world_ready:
				fluids_power.handle(msg)
		"surface":
			_on_surface(msg)
		"raise":
			GameSwap.show_client(bool(Settings.get_value("factorio", "minimize_factorio")))
		"cov":
			remote_fog.handle(msg)
		"plat":
			platform_panel.handle(msg)
			if msg.has("k"):
				planet_spin.heard(float(msg["k"]), _array(msg.get("days")))
			_show_planet_for(platform_panel.current())
		"sky":
			_sky_daytime = int(msg.get("d", 0)) / 1000.0
			_sky_darkness = int(msg.get("n", 0)) / 1000.0
		"inv":
			hud.set_inventory(_array(msg.get("l")))
		"recipes":
			hud.set_recipes(_array(msg.get("l")))
		"gui":
			hud.screen.handle(msg)
		"msg":
			# A research notification names the technology, so it can be shown in the player's language.
			if msg.has("tech"):
				hud.show_message("Research completed: %s" % LocaleNames.technology(str(msg["tech"])))
			else:
				hud.show_message(str(msg.get("text", "")))
		_:
			if not hud.ui.model.handle(msg):  # UI data (scripts/ui/factorio/ui_model.gd)
				world.handle(msg)


func _on_connection_lost() -> void:
	if hud == null:
		return
	hud.show_message("Lost connection to Factorio")
	hud.set_mining(-1)


func _process(delta: float) -> void:
	if _game == null:
		return
	world.set_focus(rig.focus_point())
	belt_lanes.focus = rig.focus_point()
	belt_lanes.covered = belt_items.covered()
	# An add-on's camera, first person, the remote view: the models go to what that camera sees.
	belt_items.view_led = ViewPriority.camera_led(rig)
	# Factorio's remote view: dark fog where no radar sees, and nothing drawn there.
	world.set_remote_view(hud.ui.remote)
	remote_fog.update(hud.ui.remote, rig.focus_point())
	_update_sky(delta)
	_update_planet(delta)
	_sync_sky_view()
	_status_timer += delta
	if _status_timer >= 0.5:
		_update_status(_status_timer)
		_status_timer = 0.0
	# Headless runs have no HUD to look at, so the status goes to stdout instead.
	_log_timer += delta
	if _headless and _log_timer >= 5.0:
		_log_timer = 0.0
		print(hud.status.text.replace("\n", " | "))


## --ups-overlay[=note]: the game's UPS (as the F4 line measures it) in big bold type at the top left, for recording
## B-roll; the note, if given, under it. Off unless asked for, there or in the debug menu (its Tests tab).
var ups_overlay_on := Settings.has_arg("--ups-overlay") or Settings.has_arg("--ups-overlay=")
var _ups_label: Label = null
var _ups_note: Label = null
var _ups_times := PackedFloat64Array()  # real seconds
var _ups_ticks := PackedFloat64Array()  # the server tick then (past 2^24: 64-bit, not a Vector2)


func _ups_overlay() -> void:
	if _ups_label != null:
		_ups_label.get_parent().visible = ups_overlay_on
		if not ups_overlay_on:
			return
	if _ups_label == null:
		if not ups_overlay_on:
			return
		var Kit = load("res://scripts/ui/factorio/kit.gd")
		var k := get_viewport().get_visible_rect().size.y / 1080.0  # sized for the window: big on a 4K screen too
		var layer := CanvasLayer.new()
		layer.layer = 120
		add_child(layer)
		_ups_label = Label.new()
		_ups_label.label_settings = LabelSettings.new()
		_ups_label.label_settings.font = Kit.font("bold")
		_ups_label.label_settings.font_size = int(96 * k)
		_ups_label.label_settings.outline_size = int(18 * k)
		_ups_label.label_settings.outline_color = Color(0.05, 0.05, 0.05, 0.9)
		_ups_label.position = Vector2(56, 120) * k
		layer.add_child(_ups_label)
		var note := Settings.arg_value("--ups-overlay=")
		if note != "":
			_ups_note = Label.new()
			_ups_note.label_settings = LabelSettings.new()
			_ups_note.label_settings.font = Kit.font("semibold")
			_ups_note.label_settings.font_size = int(40 * k)
			_ups_note.label_settings.font_color = Color(1.0, 0.9, 0.75)
			_ups_note.label_settings.outline_size = int(12 * k)
			_ups_note.label_settings.outline_color = Color(0.05, 0.05, 0.05, 0.9)
			_ups_note.position = Vector2(62, 250) * k
			_ups_note.text = note
			layer.add_child(_ups_note)
	if not Bridge.world_ready:
		_ups_label.text = ""
		_ups_times.clear()
		_ups_ticks.clear()
		return
	# Ticks over the last 2 s of real time: steadier than the F4 line's half-second reading, and never above 60 (it is
	# for recordings at game speed 1, where a reading over 60 is only arrival jitter between two readings).
	var now := Time.get_ticks_msec() / 1000.0
	_ups_times.append(now)
	_ups_ticks.append(float(Bridge.newest_tick))
	while _ups_times.size() > 2 and now - _ups_times[0] > 2.0:
		_ups_times.remove_at(0)
		_ups_ticks.remove_at(0)
	var span := _ups_times[-1] - _ups_times[0]
	if span < 1.0:
		return
	var ups := minf(60.0, (_ups_ticks[-1] - _ups_ticks[0]) / span)
	_ups_label.text = "%.1f UPS" % ups
	# Factorio's own colours: green holding 60, orange slipping, red well under.
	_ups_label.label_settings.font_color = Color(0.49, 0.77, 0.42) if ups >= 58.5 else (Color(0.95, 0.6, 0.18) if ups >= 45.0 else Color(0.9, 0.3, 0.25))


func _update_status(elapsed: float) -> void:
	var packets: int = Bridge.stats["packets"]
	var rate := (packets - _packets_before) / elapsed
	_packets_before = packets
	# The newest tick read, not the last handled (Bridge.newest_tick): handling runs behind at a low frame rate.
	var tick := Bridge.newest_tick
	if _tick_before >= 0 and tick >= _tick_before:
		var ups := (tick - _tick_before) / elapsed
		_ups = lerpf(_ups, ups, 0.5) if _ups > 0.0 else ups
	_tick_before = tick
	_ups_overlay()
	if Bridge.bind_error != OK:
		hud.status.text = "Can't open UDP port %d. Is another client already running?" % Bridge.listen_port
	elif not Bridge.connected:
		hud.status.text = "Waiting for Factorio on %s:%d\nStart it with --enable-lua-udp %d and the factorio-3d-bridge mod (see docs/RUNNING.md)" % [Bridge.factorio_host, Bridge.factorio_port, Bridge.factorio_port]
	elif not Bridge.world_ready:
		hud.status.text = "Connected. Loading prototypes..."
	else:
		hud.status.text = "tick %d · %d chunks · %d entities · %d moving · %d on belts · %d on the ground · %d arms · %d lamps lit · %d wires · %d ghosts · %d packets/s · %d gaps · %.1f UPS · %d FPS\nhealth %d · crafting %d · %s" % [
			Bridge.server_tick, world.loaded_chunk_count(), world.entity_count(), movers.count(), belt_items.count(), ground_items.count(), arms.count(), lamps.lit_count(), wires.span_count(), ghosts.ghost_count(),
			int(rate), int(Bridge.stats["gaps"]), _ups, int(Engine.get_frames_per_second()), avatar.health, avatar.craft_queue, fx.status()]
		var held := ups_governor.status()
		if held != "":
			hud.status.text += "\n" + held
		var merged := world.far_chunks.status()
		if merged != "":
			hud.status.text += "\n" + merged
		if world.held_count() > 0:
			hud.status.text += "\n%d chunks held past the view (api.world.hold_chunks)" % world.held_count()


func _build_environment() -> void:
	var env := Environment.new()
	_planet_sky = PlanetSky.new()
	_planet_sky.name = "Sky"
	_game.add_child(_planet_sky)
	_planet_sky_res = Sky.new()
	_planet_sky_res.sky_material = _planet_sky.sky_material
	# Reflections only need a rough picture of the sky, refreshed a little each frame.
	_planet_sky_res.radiance_size = Sky.RADIANCE_SIZE_32
	_planet_sky_res.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	env.background_mode = Environment.BG_SKY
	env.sky = _planet_sky_res
	env.background_color = Color(0.55, 0.62, 0.68)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.78, 0.82)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	Settings.apply_ssao(env)
	_env = env
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	_game.add_child(world_env)
	ao_zoom = AoZoom.new()
	ao_zoom.name = "AoZoom"
	ao_zoom.env = env
	ao_zoom.process_priority = 100  # after the looks and the sky have set this frame's environment
	_game.add_child(ao_zoom)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	# Under Godot's 0.1 and 2.0 a belt (0.25 tiles tall), a pipe or a rail cast a thinned shadow or
	# none: the depth bias scales with the shadow map's depth range, a few tenths of a tile here. These
	# keep low things' shadows without acne on the models' and items' tops (measured on a 0.25-tile box
	# at 8 and 30 tiles, with and without the Cinematic look's soft shadows).
	sun.shadow_bias = SUN_SHADOW_BIAS
	sun.shadow_normal_bias = SUN_SHADOW_NORMAL_BIAS
	sun.directional_shadow_max_distance = 150.0
	_game.add_child(sun)
	_sun = sun
	sun_shadows = SunShadows.new()
	sun_shadows.name = "SunShadows"
	sun_shadows.sun = sun
	_game.add_child(sun_shadows)
	looks = Looks.new()
	_game.add_child(looks)
	looks.look_changed.connect(_apply_clouds)
	looks.look_changed.connect(_note_look_antialiasing)
	looks.attach(env, sun)


## The planet straight below a stopped platform (space_sky.gdshader's planet_radius, radians: its
## edge 38 degrees under the horizon, so it fills the view's lower part), and how much
## of a route it takes to fall away or come near.
const PLANET_RADIUS := 0.9
const PLANET_FADE := 0.12
## At the far end of that part: how many times further off it is, how far from straight below
## (radians) its far edge stands ahead of the platform, and it stands behind (platforms fly north).
const PLANET_FAR := 40.0
const PLANET_EDGE_AHEAD := 1.17
const PLANET_TILT_BEHIND := 0.5
## How fast the planet drawn catches up with where the platform is (per second).
const PLANET_EASE := 3.0


## Space behind a platform, or the planet's sky.
func _set_space(on: bool) -> void:
	_space = on
	if on:
		if _space_material == null:
			_space_material = ShaderMaterial.new()
			_space_material.shader = SPACE_SKY
			_space_sky = Sky.new()
			_space_sky.sky_material = _space_material
			# The turning planet changes it every frame: its reflections are made over several.
			_space_sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
		_env.sky = _space_sky
		_sky_planet = "\n"  # none yet: the first update places it without gliding
		_show_planet_for(platform_panel.current())
	else:
		_env.sky = _planet_sky_res


## The planet in the platform's sky: the one it is stopped at; while travelling, the one it left
## falling away over the first part of the route and the next one growing over the last,
## nothing in between. `plat` comes once a second: the planet drawn glides between them.
func _show_planet_for(rec: Dictionary) -> void:
	var shown := planet_offset(rec)
	var location: String = shown[0]
	var u: float = shown[1]
	var now := Time.get_ticks_msec()
	if location != _sky_planet:
		_sky_planet = location
		_sky_u = u
		_sky_rate = 0.0
	elif rec.get("to") == null or str(rec.get("to")) == "":
		_sky_rate = 0.0
	elif now > _sky_goal_msec + 50:
		_sky_rate = lerpf(_sky_rate, (u - _sky_goal) * 1000.0 / (now - _sky_goal_msec), 0.5)
	_sky_goal = u
	_sky_goal_msec = now
	_show_planet(location)
	_pose_planet()


## Each frame in space: the planet moves on at the pace it has been going, easing into each update,
## and turns as its day goes (planet_spin.gd), lit from the deck's sun.
func _update_planet(delta: float) -> void:
	planet_spin.advance(delta)
	if not _space or _space_material == null or _sky_planet == "":
		return
	var want := _sky_goal + _sky_rate * minf((Time.get_ticks_msec() - _sky_goal_msec) / 1000.0, 2.0)
	if _sky_goal <= 0.0:
		want = minf(want, 0.0)  # it may stop there: only an update takes it past
	_sky_u = lerpf(_sky_u, want, 1.0 - exp(-delta * PLANET_EASE))
	_pose_planet()
	_space_material.set_shader_parameter("planet_spin", planet_spin.turns(_sky_planet))
	_space_material.set_shader_parameter("planet_cloud_spin", planet_spin.cloud_turns(_sky_planet))
	if _sun != null:
		_space_material.set_shader_parameter("planet_sun", _sun.global_transform.basis.z.normalized())


func _pose_planet() -> void:
	if _space_material == null:
		return
	var pose := planet_pose(_sky_u)
	_space_material.set_shader_parameter("planet_radius", pose[0])
	_space_material.set_shader_parameter("planet_dir", pose[1])
	_space_material.set_shader_parameter("planet_alpha", pose[2])


## [location, offset] of the planet in a platform's sky: the offset is 0 at the planet, towards -1 on
## the way to it and +1 on the way from it, where it goes out of sight.
static func planet_offset(rec: Dictionary) -> Array:
	var shown := planet_in_sky(rec)
	if rec.get("to") == null or str(rec.get("to")) == "":
		return [shown[0], 0.0]
	var leaving := clampf(float(rec.get("d", 0)) / 1000.0, 0.0, 1.0) < 0.5
	return [shown[0], (1.0 - float(shown[1])) * (1.0 if leaving else -1.0)]


## [radius (radians), direction, alpha] of a planet at that offset. It shrinks as a thing does going
## away, evenly on a log scale. Ahead of the platform its far edge moves steadily, so it comes down
## the view as it grows instead of leaving at the bottom and coming back; behind, it sinks away.
static func planet_pose(u: float) -> Array:
	var a := absf(u)
	var radius := asin(sin(PLANET_RADIUS) / pow(PLANET_FAR, a))
	var tilt := PLANET_TILT_BEHIND * pow(a, 1.5) if u > 0.0 else lerpf(PLANET_RADIUS, PLANET_EDGE_AHEAD, a) - radius
	var north := -1.0 if u <= 0.0 else 1.0
	return [radius, Vector3(0.0, -cos(tilt), north * sin(tilt)), 1.0 - smoothstep(0.85, 1.0, a)]


## [location, size 0-1] of the planet a platform's `plat` record puts in its sky ("" for none).
## `d` is how far along the route in thousandths (`len` is the route's length in km, F4: reading
## d / len kept every route in its first 12%, so the planet left never went away).
static func planet_in_sky(rec: Dictionary) -> Array:
	if rec.get("to") == null or str(rec.get("to")) == "":
		return [str(rec.get("loc", "")) if rec.get("loc") != null else "", 1.0]
	var t := clampf(float(rec.get("d", 0)) / 1000.0, 0.0, 1.0)
	var near := PlatformPanel.planet_nearness(t, PLANET_FADE)
	if near <= 0.0:
		return ["", 0.0]
	return [str(rec.get("from", "")) if t < 0.5 else str(rec.get("to", "")), near]



func _show_planet(location: String) -> void:
	if _space_material == null:
		return
	# The real planet: Factorio's star map picture of it, where the install has one.
	var tex := planet_picture(location)
	# Another mod's planet has no colour here: it shows as its picture, if it is a planet at all
	# (platforms also stop at places that aren't, such as the solar system's edge).
	var shown := PLANET_COLORS.has(location) or (tex != null and _is_planet(location))
	_space_material.set_shader_parameter("planet_on", 1.0 if shown else 0.0)
	if PLANET_COLORS.has(location):
		var c: Color = PLANET_COLORS[location]
		_space_material.set_shader_parameter("planet_color", Vector3(c.r, c.g, c.b))
	_space_material.set_shader_parameter("planet_tex_on", 1.0 if tex != null else 0.0)
	if tex != null:
		_space_material.set_shader_parameter("planet_tex", tex)
	# Its whole surface on a sphere once the maps are loaded (on a worker: 2048 x 1024 each).
	var maps := planet_maps_soon(location)
	_space_material.set_shader_parameter("planet_map_on", 1.0 if maps.has("map") else 0.0)
	_space_material.set_shader_parameter("planet_clouds_on", 1.0 if maps.has("clouds") else 0.0)
	_space_material.set_shader_parameter("planet_emission_on", 1.0 if maps.has("emission") else 0.0)
	for key in maps:
		_space_material.set_shader_parameter("planet_" + str(key), maps[key])


static var _planet_maps := {}  # location -> {"map", "clouds"?, "emission"?: Texture2D}, {} without
static var _planet_images := {}  # location -> {key: Image}, from the worker
static var _planet_tasks := {}  # location -> WorkerThreadPool task id
static var _planet_lock := Mutex.new()


## Factorio's maps of a planet's surface (space-age/graphics/space/<planet>.png, its clouds and
## emission), as textures, once loaded: {} until then (asked again with the next `plat`) and for
## places without them. They are read and mipmapped on a worker thread.
static func planet_maps_soon(location: String) -> Dictionary:
	if location == "":
		return {}
	if _planet_maps.has(location):
		return _planet_maps[location]
	if _planet_tasks.has(location):
		var task: int = _planet_tasks[location]
		if not WorkerThreadPool.is_task_completed(task):
			return {}
		WorkerThreadPool.wait_for_task_completion(task)
		_planet_tasks.erase(location)
		_planet_lock.lock()
		var images: Dictionary = _planet_images.get(location, {})
		_planet_images.erase(location)
		_planet_lock.unlock()
		var out := {}
		for key in images:
			out[key] = ImageTexture.create_from_image(images[key])
		_planet_maps[location] = out
		return out
	var dir := ItemIcons.find_data_dir()
	var base := dir.path_join("space-age/graphics/space/%s" % location) if dir != "" else ""
	if base == "" or not FileAccess.file_exists(base + ".png"):
		_planet_maps[location] = {}
		return {}
	_planet_tasks[location] = WorkerThreadPool.add_task(_load_planet_maps.bind(location, base), false, "planet maps")
	return {}


static func _load_planet_maps(location: String, base: String) -> void:
	var images := {}
	for pair in [["map", ""], ["clouds", "-cloud"], ["emission", "-emission"]]:
		var path: String = base + str(pair[1]) + ".png"
		if not FileAccess.file_exists(path):
			continue
		var image := Image.load_from_file(path)
		if image == null or image.is_empty():
			continue
		image.generate_mipmaps()
		images[pair[0]] = image
	_planet_lock.lock()
	_planet_images[location] = images
	_planet_lock.unlock()


## Factorio's picture of a planet (its star map sprite), else its icon from the bridge's graphics
## list (another mod's planet), or null.
static func planet_picture(location: String) -> Texture2D:
	if location == "":
		return null
	for path in ["space-age/graphics/icons/starmap-planet-%s.png", "base/graphics/icons/starmap-planet-%s.png"]:
		var t := GuiAssets.data_sprite(path % location)
		if t != null:
			return t
	return ItemIcons.texture_for_kind("space-location", location)


## Whether the solar system (`smap`) lists `location` as a planet. Until it has come it is asked
## for once, and the sky is drawn again when it arrives.
func _is_planet(location: String) -> bool:
	var model = hud.ui.model
	for loc: Dictionary in model.space_locations:
		if loc["name"] == location:
			return loc["type"] == "planet"
	if model.space_locations.is_empty() and not _asked_space_map:
		_asked_space_map = true
		model.request_space_map()
	return false


## Eases towards the game's time of day (it only arrives once a second) and lights the scene
## for it: the sun's height and colour, ambient light and sky, the character's light, lamps.
func _update_sky(delta: float) -> void:
	# A screenshot's moment: the time of day and the sky stand still.
	if MomentHold.on:
		delta = 0.0
	var blend := minf(1.0, delta * 2.0)
	_daytime = fposmod(_daytime + wrapf(_sky_daytime - _daytime, -0.5, 0.5) * blend, 1.0)
	_darkness = lerpf(_darkness, _sky_darkness, blend)
	if _planet_sky.forced_daytime >= 0.0:  # --sky=<planet>@<daytime>, for screenshots
		_daytime = _planet_sky.forced_daytime
		_darkness = PlanetSky.darkness_at(_daytime)
	var night := clampf(_darkness / 0.85, 0.0, 1.0)
	_planet_sky.twilight = looks.twilight()
	_planet_sky.sky_twilight = looks.sky_twilight()
	_planet_sky.apply(_env, _sun, _daytime, night, delta, _space)
	looks.apply(_daytime, night, _planet_sky.planet, _space, _planet_sky.state)
	# Night vision equipment: Factorio's turns on past half darkness while it has power and lifts
	# the night with its colour lookup (a brighter, greener picture).
	var nv_on := bool(hud.ui.model.grid("char").get("night_vision", false)) and _darkness >= 0.5
	_night_vision = move_toward(_night_vision, 1.0 if nv_on else 0.0, delta * 2.0)
	if _night_vision > 0.0:
		_env.ambient_light_energy += 1.4 * _night_vision
		_env.ambient_light_color = _env.ambient_light_color.lerp(Color(0.62, 0.86, 0.62), 0.6 * _night_vision)
	avatar.set_night(night)
	movers.set_night(night)
	lamps.darkness = _darkness
	lamps.focus = rig.focus_point()


## A screenshot drawn off screen at a size of its own (addon_host.gd): its camera and size for the
## sky shaders while it is drawn, so an orthographic sky fits its shape.
var shot_camera: Camera3D
var shot_size := Vector2.ZERO


## The camera, for the sky shaders (sky_view.gdshaderinc): under an orthographic camera Godot's sky
## rays come out nearly 180° wide, so the shaders are given the real orientation and field of view
##. The planet below a platform stays put (space_sky.gdshader's planet_dir, F4).
func _sync_sky_view() -> void:
	var cam := get_viewport().get_camera_3d()
	var size := get_viewport().get_visible_rect().size
	if shot_camera != null and is_instance_valid(shot_camera):
		cam = shot_camera
		size = shot_size
	if cam == null:
		return
	var ortho := cam.projection == Camera3D.PROJECTION_ORTHOGONAL
	var t := tan(deg_to_rad(cam.fov) * 0.5)
	var view_tan := Vector2(t * size.x / maxf(size.y, 1.0), t)
	if cam.keep_aspect == Camera3D.KEEP_WIDTH:
		view_tan = Vector2(t, t * size.y / maxf(size.x, 1.0))
	for m: ShaderMaterial in [_planet_sky.sky_material, _space_material]:
		if m == null:
			continue
		m.set_shader_parameter("view_ortho", 1.0 if ortho else 0.0)
		if ortho:
			m.set_shader_parameter("view_basis", cam.global_transform.basis.orthonormalized())
			m.set_shader_parameter("view_tan", view_tan)


static func _array(v) -> Array:
	return v if v is Array else []
